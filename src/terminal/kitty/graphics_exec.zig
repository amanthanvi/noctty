const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;

const Terminal = @import("../Terminal.zig");
const command = @import("graphics_command.zig");
const image = @import("graphics_image.zig");
const Command = command.Command;
const Response = command.Response;
const LoadingImage = image.LoadingImage;
const Image = image.Image;
const ImageStorage = @import("graphics_storage.zig").ImageStorage;

const log = std.log.scoped(.kitty_gfx);

/// Execute a Kitty graphics command against the given terminal. This
/// will never fail, but the response may indicate an error and the
/// terminal state may not be updated to reflect the command. This will
/// never put the terminal in an unrecoverable state, however.
///
/// The allocator must be the same allocator that was used to build
/// the command.
pub fn execute(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) ?Response {
    // If storage is disabled then we disable the full protocol. This means
    // we don't even respond to queries so the terminal completely acts as
    // if this feature is not supported.
    if (!terminal.screens.active.kitty_images.enabled()) {
        log.debug("kitty graphics requested but disabled", .{});
        return null;
    }

    log.debug("executing kitty graphics command: quiet={} control={}", .{
        cmd.quiet,
        cmd.control,
    });

    // The quiet settings used to control the response. We have to make this
    // a var because in certain special cases (namely chunked transmissions)
    // this can change.
    var quiet = cmd.quiet;

    // The protocol makes i and I mutually exclusive for every action, so this
    // must happen before dispatch and before an action can mutate storage.
    // https://sw.kovidgoyal.net/kitty/graphics-protocol/#requesting-image-ids-from-the-terminal
    const identifiers = cmd.control.identifiers();
    if (identifiers.image_id > 0 and identifiers.image_number > 0) {
        const resp: Response = .{
            .id = identifiers.image_id,
            .image_number = identifiers.image_number,
            .placement_id = identifiers.placement_id,
            .message = "EINVAL: image ID and number are mutually exclusive",
        };
        log.warn("erroneous kitty graphics response: {s}", .{resp.message});

        return switch (quiet) {
            .no => resp,
            .ok => resp,
            .failures => null,
        };
    }

    const resp_: ?Response = switch (cmd.control) {
        .query => query(alloc, cmd),
        .display => display(alloc, terminal, cmd),
        .delete => delete(alloc, terminal, cmd),

        .transmit, .transmit_and_display => resp: {
            // If we're transmitting, then our `q` setting value is complicated.
            // The `q` setting inherits the value from the starting command
            // unless `q` is set >= 1 on this command. If it is, then we save
            // that as the new `q` setting.
            const storage = &terminal.screens.active.kitty_images;
            if (storage.loading) |loading| switch (cmd.quiet) {
                // q=0 we use whatever the start command value is
                .no => quiet = loading.quiet,

                // q>=1 we use the new value, but we should already be set to it
                inline .ok, .failures => |tag| {
                    assert(quiet == tag);
                    loading.quiet = tag;
                },
            };

            break :resp transmit(alloc, terminal, cmd);
        },

        .transmit_animation_frame,
        .control_animation,
        .compose_animation,
        => .{ .message = "ERROR: unimplemented action" },
    };

    // Handle the quiet settings
    if (resp_) |resp| {
        if (!resp.ok()) {
            log.warn("erroneous kitty graphics response: {s}", .{resp.message});
        }

        return switch (quiet) {
            .no => if (resp.empty()) null else resp,
            .ok => if (resp.ok()) null else resp,
            .failures => null,
        };
    }

    return null;
}

/// Execute a "query" command.
///
/// This command is used to attempt to load an image and respond with
/// success/error but does not persist any of the command to the terminal
/// state.
fn query(alloc: Allocator, cmd: *const Command) Response {
    const t = cmd.control.query;

    // Query requires image ID. We can't actually send a response without
    // an image ID either but we return an error and this will be logged
    // downstream.
    if (t.image_id == 0) {
        return .{ .message = "EINVAL: image ID required" };
    }

    // Build a partial response to start
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };

    // Attempt to load the image. If we cannot, then set an appropriate error.
    var loading = LoadingImage.init(alloc, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    loading.deinit(alloc);

    return result;
}

/// Transmit image data.
///
/// This loads the image, validates it, and puts it into the terminal
/// screen storage. It does not display the image.
fn transmit(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const t = cmd.transmission().?;
    var result: Response = .{
        .id = t.image_id,
        .image_number = t.image_number,
        .placement_id = t.placement_id,
    };

    const load = loadAndAddImage(alloc, terminal, cmd) catch |err| {
        encodeError(&result, err);
        return result;
    };
    errdefer load.image.deinit(alloc);

    // If we're also displaying, then do that now. This function does
    // both transmit and transmit and display. The display might also be
    // deferred if it is multi-chunk.
    if (load.display) |d| {
        assert(!load.more);
        var d_copy = d;
        d_copy.image_id = load.image.id;
        result = display(alloc, terminal, &.{
            .control = .{ .display = d_copy },
            .quiet = cmd.quiet,
        });
    }

    // If there are more chunks expected we do not respond.
    if (load.more) return .{};

    // If the loaded image was assigned its ID automatically, not based
    // on a number or explicitly specified ID, then we don't respond.
    if (load.image.implicit_id) return .{};

    // After the image is added, set the ID in case it changed.
    // The resulting image number and placement ID never change.
    result.id = load.image.id;

    return result;
}

/// Display a previously transmitted image.
fn display(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const d = cmd.display().?;

    // Display requires image ID or number.
    if (d.image_id == 0 and d.image_number == 0) {
        return .{ .message = "EINVAL: image ID or number required" };
    }

    // Build up our response
    var result: Response = .{
        .id = d.image_id,
        .image_number = d.image_number,
        .placement_id = d.placement_id,
    };

    // Verify the requested image exists if we have an ID
    const storage = &terminal.screens.active.kitty_images;
    const img_: ?Image = if (d.image_id != 0)
        storage.imageById(d.image_id)
    else
        storage.imageByNumber(d.image_number);
    const img = img_ orelse {
        result.message = "ENOENT: image not found";
        return result;
    };

    // Make sure our response has the image id in case we looked up by number
    result.id = img.id;

    // Location where the placement will go.
    const location: ImageStorage.Placement.Location = location: {
        // Virtual placements are not tracked
        if (d.virtual_placement) {
            if (d.parent_id > 0) {
                result.message = "EINVAL: virtual placement cannot refer to a parent";
                return result;
            }

            break :location .{ .virtual = {} };
        }

        // Track a new pin for our cursor. The cursor is always tracked but we
        // don't want this one to move with the cursor.
        const pin = terminal.screens.active.pages.trackPin(
            terminal.screens.active.cursor.page_pin.*,
        ) catch |err| {
            log.warn("failed to create pin for Kitty graphics err={}", .{err});
            result.message = "EINVAL: failed to prepare terminal state";
            return result;
        };
        break :location .{ .pin = pin };
    };

    // Add the placement
    const p: ImageStorage.Placement = .{
        .location = location,
        .x_offset = d.x_offset,
        .y_offset = d.y_offset,
        .source_x = d.x,
        .source_y = d.y,
        .source_width = d.width,
        .source_height = d.height,
        .columns = d.columns,
        .rows = d.rows,
        .z = d.z,
    };
    storage.addPlacement(
        alloc,
        terminal.screens.active,
        img.id,
        result.placement_id,
        p,
    ) catch |err| {
        p.deinit(terminal.screens.active);
        encodeError(&result, err);
        return result;
    };

    // Apply cursor movement setting. This only applies to pin placements.
    switch (p.location) {
        .virtual => {},
        .pin => |pin| switch (d.cursor_movement) {
            .none => {},
            .after => {
                // We use terminal.index to properly handle scroll regions.
                const screen = terminal.screens.active;
                const size = p.gridSize(img, terminal);

                // A scroll below can move this placement off the screen,
                // which deletes it and frees its pin, so read the column
                // first.
                const target_x = @as(usize, pin.x) +| @as(usize, size.cols);
                const wraps = target_x >= @as(usize, terminal.cols);
                const requested_rows =
                    (@as(usize, size.rows) -| 1) +| @intFromBool(wraps);

                // The row count comes from the application and can be as
                // large as u32, and one terminal.index call per row would
                // keep this thread busy for a very long time. A cursor at or
                // above the bottom of the scroll region (above the region
                // too) moves down to that bottom, and each call after that
                // scrolls the region. So allow the calls that reach the
                // bottom, then one screen of scrolling: past that the region
                // is blank and the protocol leaves the position undefined.
                // A cursor below the region or outside its left and right
                // margins never scrolls, so the budget only bounds moves.
                const region = terminal.scrolling_region;
                const rows_before_scroll: usize = if (screen.cursor.y <= region.bottom)
                    @as(usize, region.bottom - screen.cursor.y)
                else
                    0;
                const rows_to_move: usize = @min(
                    requested_rows,
                    rows_before_scroll +| @as(usize, terminal.rows),
                );
                for (0..rows_to_move) |_| terminal.index() catch |err| {
                    log.warn("failed to move cursor: {}", .{err});
                    break;
                };

                // Kitty wraps once when the movement reaches the right edge;
                // otherwise it leaves the cursor immediately to the right of
                // the placement.
                screen.cursor.pending_wrap = false;
                screen.cursorHorizontalAbsolute(
                    if (wraps) 0 else @intCast(target_x),
                );
            },
        },
    }

    return result;
}

/// Display a previously transmitted image.
fn delete(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) Response {
    const storage = &terminal.screens.active.kitty_images;
    storage.delete(alloc, terminal, cmd.control.delete.action);

    // Delete never responds on success
    return .{};
}

fn loadAndAddImage(
    alloc: Allocator,
    terminal: *Terminal,
    cmd: *const Command,
) !struct {
    image: Image,
    more: bool = false,
    display: ?command.Display = null,
} {
    const t = cmd.transmission().?;
    const storage = &terminal.screens.active.kitty_images;

    // Determine our image. This also handles chunking and early exit.
    var loading: LoadingImage = if (storage.loading) |loading| loading: {
        // Note: we do NOT want to call "cmd.toOwnedData" here because
        // we're _copying_ the data. We want the command data to be freed.
        try loading.addData(alloc, cmd.data);

        // If we have more then we're done
        if (t.more_chunks) return .{ .image = loading.image, .more = true };

        // We have no more chunks. We're going to be completing the
        // image so we want to destroy the pointer to the loading
        // image and copy it out.
        defer {
            alloc.destroy(loading);
            storage.loading = null;
        }

        break :loading loading.*;
    } else try .init(alloc, cmd);

    // We only want to deinit on error. If we're chunking, then we don't
    // want to deinit at all. If we're not chunking, then we'll deinit
    // after we've copied the image out.
    errdefer loading.deinit(alloc);

    // If the image has no ID, we assign one
    if (loading.image.id == 0) {
        loading.image.id = storage.next_image_id;
        storage.next_image_id +%= 1;

        // If the image also has no number then its auto-ID is "implicit".
        // See the doc comment on the Image.implicit_id field for more detail.
        if (loading.image.number == 0) loading.image.implicit_id = true;
    }

    // If this is chunked, this is the beginning of a new chunked transmission.
    // (We checked for an in-progress chunk above.)
    if (t.more_chunks) {
        // We allocate the pointer on the heap because its rare and we
        // don't want to always pay the memory cost to keep it around.
        const loading_ptr = try alloc.create(LoadingImage);
        errdefer alloc.destroy(loading_ptr);
        loading_ptr.* = loading;
        storage.loading = loading_ptr;
        return .{ .image = loading.image, .more = true };
    }

    // Dump the image data before it is decompressed
    // loading.debugDump() catch unreachable;

    // Validate and store our image
    var img = try loading.complete(alloc);
    errdefer img.deinit(alloc);
    try storage.addImage(alloc, terminal.screens.active, img);

    // Get our display settings
    const display_ = loading.display;

    // Ensure we deinit the loading state because we're done. The image
    // won't be deinit because of "complete" above.
    loading.deinit(alloc);

    return .{ .image = img, .display = display_ };
}

const EncodeableError = Image.Error || Allocator.Error;

/// Encode an error code into a message for a response.
fn encodeError(r: *Response, err: EncodeableError) void {
    switch (err) {
        error.OutOfMemory => r.message = "ENOMEM: out of memory",
        error.InternalError => r.message = "EINVAL: internal error",
        error.InvalidData => r.message = "EINVAL: invalid data",
        error.DecompressionFailed => r.message = "EINVAL: decompression failed",
        error.FilePathTooLong => r.message = "EINVAL: file path too long",
        error.TemporaryFileNotInTempDir => r.message = "EINVAL: temporary file not in temp dir",
        error.TemporaryFileNotNamedCorrectly => r.message = "EINVAL: temporary file not named correctly",
        error.UnsupportedFormat => r.message = "EINVAL: unsupported format",
        error.UnsupportedMedium => r.message = "EINVAL: unsupported medium",
        error.UnsupportedDepth => r.message = "EINVAL: unsupported pixel depth",
        error.DimensionsRequired => r.message = "EINVAL: dimensions required",
        error.DimensionsTooLarge => r.message = "EINVAL: dimensions too large",
    }
}

test "kittygfx image id and number are mutually exclusive for every action" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const inputs = [_][]const u8{
        "a=q,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=t,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=T,f=24,s=1,v=1,i=1,I=2,p=3;AAAA",
        "a=p,i=1,I=2,p=3",
        "a=d,d=a,i=1,I=2,p=3",
        "a=f,i=1,I=2,p=3;AAAA",
        "a=a,i=1,I=2,p=3",
        "a=c,i=1,I=2,p=3",
    };

    for (inputs) |input| {
        const cmd = try command.Parser.parseString(alloc, input);
        defer cmd.deinit(alloc);

        const resp = execute(alloc, &t, &cmd) orelse return error.TestExpectedResponse;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 3), resp.placement_id);
        try testing.expectEqualStrings(
            "EINVAL: image ID and number are mutually exclusive",
            resp.message,
        );

        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try resp.encode(&writer);
        try testing.expectEqualStrings(
            "\x1b_Gi=1,I=2,p=3;EINVAL: image ID and number are mutually exclusive\x1b\\",
            writer.buffered(),
        );
    }

    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.images.count());
    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.placements.count());
}

test "kittygfx conflicting identifiers are rejected before mutation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;

    // Store an image so a buggy put would succeed and mutate placement state.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,s=1,v=1,i=1;/wAA",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd) orelse return error.TestExpectedResponse;
        try testing.expect(resp.ok());
    }

    // Directly constructed commands must receive the same validation as
    // commands produced by the parser.
    {
        const cmd: Command = .{ .control = .{ .display = .{
            .image_id = 1,
            .image_number = 2,
            .placement_id = 7,
            .cursor_movement = .none,
        } } };
        const resp = execute(alloc, &t, &cmd) orelse return error.TestExpectedResponse;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(u32, 1), resp.id);
        try testing.expectEqual(@as(u32, 2), resp.image_number);
        try testing.expectEqual(@as(u32, 7), resp.placement_id);
        try testing.expectEqual(@as(usize, 0), storage.placements.count());
    }

    // Add a real placement so a buggy delete would remove it.
    {
        const cmd = try command.Parser.parseString(alloc, "a=p,i=1,p=7,C=1");
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd) orelse return error.TestExpectedResponse;
        try testing.expect(resp.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd) orelse return error.TestExpectedResponse;
        try testing.expect(!resp.ok());
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }

    // q=2 suppresses the required error response but not the validation.
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=d,d=i,i=1,I=2,p=7,q=2",
        );
        defer cmd.deinit(alloc);
        try testing.expect(execute(alloc, &t, &cmd) == null);
        try testing.expectEqual(@as(usize, 1), storage.placements.count());
    }
}

test "kittygfx more chunks with q=1" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=1
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,i=1,s=1,v=2,c=10,r=1,m=1,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk has no q but should respect initial
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx more chunks with q=0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=0
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk has no q so should respond OK
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd).?;
        try testing.expect(resp.ok());
    }
}

test "kittygfx more chunks with chunk increasing q" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Initial chunk has q=0
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,m=1,i=1,q=0;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd);
        try testing.expect(resp == null);
    }

    // Subsequent chunk sets q=1 so should not respond
    {
        const cmd = try command.Parser.parseString(
            alloc,
            "m=0,q=1;////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx query of an over-long file path answers file path too long" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const path = try alloc.alloc(u8, 40000);
    @memset(path, 'a');
    var cmd: Command = .{
        .control = .{ .query = .{ .medium = .file, .image_id = 31 } },
        .data = path,
    };
    defer cmd.deinit(alloc);

    const resp = execute(alloc, &t, &cmd) orelse return error.TestExpectedResponse;
    try testing.expectEqual(@as(u32, 31), resp.id);
    try testing.expectEqualStrings("EINVAL: file path too long", resp.message);
}

test "kittygfx default format is rgba" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=t,t=d,i=1,s=1,v=2,c=10,r=1;///////////",
    );
    defer cmd.deinit(alloc);
    const resp = execute(alloc, &t, &cmd).?;
    try testing.expect(resp.ok());

    const storage = &t.screens.active.kitty_images;
    const img = storage.imageById(1).?;
    try testing.expectEqual(command.Transmission.Format.rgba, img.format);
}

test "kittygfx test valid u32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=4294967295",
    );
    defer cmd.deinit(alloc);
    const resp = execute(alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}

test "kittygfx test valid i32 (expect invalid image ID)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=p,i=1,z=-2147483648",
    );
    defer cmd.deinit(alloc);
    const resp = execute(alloc, &t, &cmd).?;
    try testing.expect(!resp.ok());
    try testing.expectEqual(resp.message, "ENOENT: image not found");
}

test "kittygfx no response with no image ID or number" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=t,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx no response with no image ID or number load and display" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    {
        const cmd = try command.Parser.parseString(
            alloc,
            "a=T,f=24,t=d,s=1,v=2,c=10,r=1,i=0,I=0;////////",
        );
        defer cmd.deinit(alloc);
        const resp = execute(alloc, &t, &cmd);
        try testing.expect(resp == null);
    }
}

test "kittygfx placement at the cursor after a full reset is drawn and kept" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // RIS: the page reset marks every tracked pin garbage, the cursor's
    // included, and display() tracks a copy of the cursor pin.
    t.fullReset();

    const storage = &t.screens.active.kitty_images;
    const cmds = [_][]const u8{
        // Transmit and display at the home position. C=1 keeps the cursor
        // there, so the second placement copies the same cursor pin.
        "a=T,f=24,t=d,i=1,p=1,s=1,v=2,c=1,r=1,C=1,q=2;////////",
        "a=p,i=1,p=2,c=1,r=1,C=1,q=2",
    };
    for (cmds, 1..) |str, expected| {
        const cmd = try command.Parser.parseString(alloc, str);
        defer cmd.deinit(alloc);
        try testing.expect(execute(alloc, &t, &cmd) == null);

        // Every placement so far must have a rect (be drawn) and survive
        // the garbage sweep in the next addPlacement.
        try testing.expectEqual(expected, storage.placements.count());
        const img = storage.imageById(1).?;
        var it = storage.placements.iterator();
        while (it.next()) |entry| {
            try testing.expect(entry.value_ptr.rect(img, &t) != null);
        }
    }
}

test "kittygfx placement bounds cursor movement for untrusted dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // q=2 keeps the response null, so nothing below unwraps an optional.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=4294967295,r=4294967295,q=2;////",
    );
    defer cmd.deinit(alloc);

    try testing.expect(execute(alloc, &t, &cmd) == null);
    try testing.expectEqual(@as(usize, 1), t.screens.active.kitty_images.placements.count());

    // Reaching the bottom takes four rows, then scrolling is capped at one
    // screen (five rows), and the image reaches the right edge, so the
    // cursor wraps to the first column.
    try testing.expectEqual(@as(usize, 10), t.screens.active.pages.scrollbar().total);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}

test "kittygfx placement moves cursor past a tall image" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Load a one-pixel RGB image, then place it over the full width and eight
    // rows. Eight rows are taller than the screen but still within Kitty's
    // scroll budget. q=2 keeps every response null.
    const cmds = [_][]const u8{
        "a=t,t=d,f=24,i=1,s=1,v=1,q=2;////",
        "a=p,i=1,p=1,c=5,r=8,q=2",

        // A subsequent placement begins immediately after the first one
        // instead of overlapping its last row.
        "a=p,i=1,p=2,C=1,q=2",
    };
    for (cmds) |str| {
        const cmd = try command.Parser.parseString(alloc, str);
        defer cmd.deinit(alloc);
        try testing.expect(execute(alloc, &t, &cmd) == null);
    }

    const storage = &t.screens.active.kitty_images;
    const first = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) orelse return error.TestExpectedPlacement;
    const second = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) orelse return error.TestExpectedPlacement;
    const pages = &t.screens.active.pages;
    const first_y = pages.pointFromPin(.screen, first.location.pin.*).?.screen.y;
    const second_y = pages.pointFromPin(.screen, second.location.pin.*).?.screen.y;
    try testing.expectEqual(first_y + 8, second_y);
    try testing.expectEqual(@as(usize, 0), second.location.pin.x);
}

test "kittygfx placement scrolls at most one screen past a tall image" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct {
        cmd: []const u8,
        total: usize,
        // The row after the image's last row the cursor ends on, if it
        // reaches it: 0 for the last row, 1 when the image wraps.
        after: ?usize,
    }{
        // Eight full-width rows on a five-row screen: seven moves down and
        // the wrap make four moves to the bottom and four scrolls. That is
        // within the bound, and the cursor ends below the image.
        .{ .cmd = "a=T,t=d,f=24,i=1,s=1,v=1,c=5,r=8,q=2;////", .total = 9, .after = 1 },

        // The tallest one-column image the bound leaves alone: four moves
        // and five scrolls end on its last row.
        .{ .cmd = "a=T,t=d,f=24,i=1,s=1,v=1,c=1,r=10,q=2;////", .total = 10, .after = 0 },

        // A thousand rows stop at the same nine calls.
        .{ .cmd = "a=T,t=d,f=24,i=1,s=1,v=1,c=1,r=1000,q=2;////", .total = 10, .after = null },
    };

    for (cases) |case| {
        var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
        defer t.deinit(alloc);

        const cmd = try command.Parser.parseString(alloc, case.cmd);
        defer cmd.deinit(alloc);
        try testing.expect(execute(alloc, &t, &cmd) == null);
        const screen = t.screens.active;
        try testing.expectEqual(@as(usize, 1), screen.kitty_images.placements.count());
        try testing.expectEqual(case.total, screen.pages.scrollbar().total);

        if (case.after) |after| {
            var it = screen.kitty_images.placements.iterator();
            const placement = it.next().?.value_ptr;
            const img = screen.kitty_images.imageById(1).?;
            const top = screen.pages.pointFromPin(.screen, placement.location.pin.*).?.screen.y;
            const cursor = screen.pages.pointFromPin(.screen, screen.cursor.page_pin.*).?.screen.y;
            try testing.expectEqual(top + placement.gridSize(img, &t).rows - 1 + after, cursor);
        }
    }
}

test "kittygfx cursor movement after its own placement scrolled away" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A one-row screen without scrollback: a full-width image wraps the
    // cursor to the next row, which scrolls the image's only row off the
    // screen, deletes the placement and releases its pin.
    var t = try Terminal.init(alloc, .{ .rows = 1, .cols = 5 });
    defer t.deinit(alloc);
    try t.switchScreenMode(.@"1049", true);
    const tracked = t.screens.active.pages.countTrackedPins();

    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=5,r=1,q=2;////",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(alloc, &t, &cmd) == null);
    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}

test "kittygfx a one-row image leaves the cursor on its row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Kitty moves the cursor down rows minus one, so an image on the bottom
    // row scrolls nothing.
    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.setCursorPos(5, 1);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=2,r=1,q=2;////",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(alloc, &t, &cmd) == null);
    try testing.expectEqual(@as(usize, 5), t.screens.active.pages.scrollbar().total);
    try testing.expectEqual(@as(usize, 4), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
}

test "kittygfx placement above the scroll region scrolls the region" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // Text in a scroll region on the last two rows. Setting the margins
    // homes the cursor, above the region.
    t.setCursorPos(4, 1);
    try t.printString("AAAAA");
    t.setCursorPos(5, 1);
    try t.printString("BBBBB");
    t.setTopAndBottomMargin(4, 5);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // An eight-row image: the cursor moves down into the region and on to
    // its bottom, and the rest scrolls the region empty.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=1,r=8,q=2;////",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(alloc, &t, &cmd) == null);

    const str = try t.plainString(alloc);
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "kittygfx cursor movement after a placement with the maximum column count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1,c=4294967295,r=1,q=2;////",
    );
    defer cmd.deinit(alloc);

    try testing.expect(execute(alloc, &t, &cmd) == null);
    try testing.expectEqual(@as(usize, 1), t.screens.active.kitty_images.placements.count());

    // The image reaches the right edge, so the cursor wraps to the next
    // row's first column.
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
}

test "kittygfx stays disabled after a full reset with a zero storage limit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    // `image-storage-limit = 0`, applied to every screen as Termio does.
    var it = t.screens.all.iterator();
    while (it.next()) |entry| {
        const screen = entry.value.*;
        try screen.kitty_images.setLimit(alloc, screen, 0);
    }

    // RIS (`ESC c`).
    t.fullReset();

    // A disabled protocol answers nothing and stores nothing.
    const cmd = try command.Parser.parseString(
        alloc,
        "a=T,t=d,f=24,i=1,s=1,v=1;////",
    );
    defer cmd.deinit(alloc);
    try testing.expect(execute(alloc, &t, &cmd) == null);
    try testing.expectEqual(@as(usize, 0), t.screens.active.kitty_images.images.count());
}

test "kittygfx retransmit same id removes existing placements" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t = try Terminal.init(alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    const storage = &t.screens.active.kitty_images;
    const tracked = t.screens.active.pages.countTrackedPins();

    // q=1 answers only failures, so every command below returns null.
    const Run = struct {
        fn run(term: *Terminal, str: []const u8) !void {
            const a = std.testing.allocator;
            const cmd = try command.Parser.parseString(a, str);
            defer cmd.deinit(a);
            try std.testing.expect(execute(a, term, &cmd) == null);
        }
    };

    // Transmit and display an image, then add an anonymous and a named
    // placement. Several anonymous placements of one image are valid.
    try Run.run(&t, "a=T,t=d,f=24,i=1,s=1,v=2,C=1,q=1;////////");
    try Run.run(&t, "a=p,i=1,C=1,q=1");
    try Run.run(&t, "a=p,i=1,p=7,C=1,q=1");
    try testing.expectEqual(@as(usize, 3), storage.placements.count());
    try testing.expectEqual(tracked + 3, t.screens.active.pages.countTrackedPins());

    // Retransmitting replaces the image and deletes every placement it
    // had. a=t creates none of its own.
    try Run.run(&t, "a=t,t=d,f=24,i=1,s=1,v=2,q=1;AAAAAAAA");
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    try testing.expect(storage.imageById(1) != null);

    // a=T deletes the previous image and its placements before it adds
    // one, so a program that draws every frame this way keeps one.
    try Run.run(&t, "a=T,t=d,f=24,i=1,s=1,v=2,C=1,q=1;////////");
    try Run.run(&t, "a=T,t=d,f=24,i=1,s=1,v=2,C=1,q=1;AAAAAAAA");
    try testing.expectEqual(@as(usize, 1), storage.placements.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}
