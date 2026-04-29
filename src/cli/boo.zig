const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const actionpkg = @import("action.zig");
const Allocator = std.mem.Allocator;
const os_env = @import("../os/env.zig");
const vaxis = @import("vaxis");

const framedata = @import("framedata").compressed;

const vxfw = vaxis.vxfw;
const ghostty_style: vaxis.Style = .{};
const outline_style: vaxis.Style = .{ .fg = .{ .index = 4 } };

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

pub const Boo = struct {
    displayed_frame: ?usize,
    animation_start: std.time.Instant,
    frames: []const [frame_cell_count]vaxis.Cell,
    auto_exit_after_ns: ?u64,
    tick_count: u64,
    frame_change_count: u64,
    render_call_count: u64,
    rendered_byte_count: u64,
    last_tick_elapsed_ns: ?u64,
    last_render_elapsed_ns: ?u64,
    max_tick_gap_ns: u64,
    max_render_gap_ns: u64,
    max_tick_gap_ended_at_ns: u64,
    max_render_gap_ended_at_ns: u64,
    // We know the size of this at compile time, but we heap allocate the slice to prevent the
    // binary from increasing too much in size
    buffer: [frame_cell_count]vaxis.Cell = undefined,

    // Width of a single frame
    const frame_width = 100;
    // Height of a single frame
    const frame_height = 41;
    pub const frame_cell_count = frame_width * frame_height;
    const animation_fps = 30;
    const animation_frame_ns = std.time.ns_per_s / animation_fps;
    // The shared vxfw app loop uses a sleep-based poll. On this Win32 stack,
    // sleeping 16 ms often lands near 31 ms, while 8-12 ms lands near 16 ms.
    // Running the app loop at 120 Hz keeps timer delivery close to 60 Hz
    // without changing animation speed, which is still clock-synced below.
    const app_poll_fps = 120;
    // Poll at half-frame cadence so coarse Windows sleepers still service
    // our next frame on the following app-loop iteration.
    const tick_poll_ms = @as(u32, @intCast(@max(
        @as(u64, 1),
        @divFloor(animation_frame_ns, 2 * std.time.ns_per_ms),
    )));

    pub fn init(frames: []const [frame_cell_count]vaxis.Cell, auto_exit_after_ns: ?u64) Boo {
        var boo: Boo = .{
            .displayed_frame = null,
            .animation_start = std.time.Instant.now() catch unreachable,
            .frames = frames,
            .auto_exit_after_ns = auto_exit_after_ns,
            .tick_count = 0,
            .frame_change_count = 0,
            .render_call_count = 0,
            .rendered_byte_count = 0,
            .last_tick_elapsed_ns = null,
            .last_render_elapsed_ns = null,
            .max_tick_gap_ns = 0,
            .max_render_gap_ns = 0,
            .max_tick_gap_ended_at_ns = 0,
            .max_render_gap_ended_at_ns = 0,
        };
        @memset(&boo.buffer, .{});
        return boo;
    }

    fn widget(self: *Boo) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Boo.typeErasedEventHandler,
            .drawFn = Boo.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Boo = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init,
            => {
                const elapsed_ns = self.elapsedNs();
                ctx.redraw = self.syncFrameForElapsedNs(elapsed_ns);
                if (self.shouldAutoExitAfterElapsedNs(elapsed_ns)) {
                    ctx.quit = true;
                    return;
                }
                return ctx.tick(tick_poll_ms, self.widget());
            },
            .tick => {
                const elapsed_ns = self.elapsedNs();
                self.recordTick(elapsed_ns);
                ctx.redraw = self.syncFrameForElapsedNs(elapsed_ns);
                if (self.shouldAutoExitAfterElapsedNs(elapsed_ns)) {
                    ctx.quit = true;
                    return;
                }
                return ctx.tick(tick_poll_ms, self.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.escape, .{}))
                {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Boo = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        // Warn for screen size
        if (max.width < frame_width or max.height < frame_height) {
            const text: vxfw.Text = .{ .text = "Screen must be at least 100w x 41h" };
            const center: vxfw.Center = .{ .child = text.widget() };
            return center.draw(ctx);
        }

        // Calculate x and y offsets to center the animation frame
        const offset_y = (max.height - frame_height) / 2;
        const offset_x = (max.width - frame_width) / 2;

        // Create the animation surface
        const child: vxfw.Surface = .{
            .size = .{ .width = @intCast(frame_width), .height = @intCast(frame_height) },
            .widget = self.widget(),
            .buffer = &self.buffer,
            .children = &.{},
        };

        // Allocate a slice of child surfaces
        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{
            .origin = .{ .row = @intCast(offset_y), .col = @intCast(offset_x) },
            .surface = child,
        };

        return .{
            .size = max,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }

    fn elapsedNs(self: *const Boo) u64 {
        const now = std.time.Instant.now() catch unreachable;
        return now.since(self.animation_start);
    }

    fn shouldAutoExitAfterElapsedNs(self: *const Boo, elapsed_ns: u64) bool {
        const deadline_ns = self.auto_exit_after_ns orelse return false;
        return elapsed_ns >= deadline_ns;
    }

    fn recordTick(self: *Boo, elapsed_ns: u64) void {
        self.tick_count += 1;
        if (self.last_tick_elapsed_ns) |previous_ns| {
            const gap_ns = elapsed_ns - previous_ns;
            if (gap_ns > self.max_tick_gap_ns) {
                self.max_tick_gap_ns = gap_ns;
                self.max_tick_gap_ended_at_ns = elapsed_ns;
            }
        }
        self.last_tick_elapsed_ns = elapsed_ns;
    }

    fn syncFrameForElapsedNs(self: *Boo, elapsed_ns: u64) bool {
        // Derive the visible frame from monotonic elapsed time so coarse
        // tick delivery changes our poll rate, not the animation speed.
        const frame = frameIndexForElapsedNs(elapsed_ns, self.frames.len);
        if (self.displayed_frame == frame) return false;

        self.buffer = self.frames[frame.?];
        self.displayed_frame = frame;
        self.frame_change_count += 1;
        return true;
    }

    fn recordRender(self: *Boo, elapsed_ns: u64, byte_count: usize) void {
        self.render_call_count += 1;
        self.rendered_byte_count += byte_count;
        if (self.last_render_elapsed_ns) |previous_ns| {
            const gap_ns = elapsed_ns - previous_ns;
            if (gap_ns > self.max_render_gap_ns) {
                self.max_render_gap_ns = gap_ns;
                self.max_render_gap_ended_at_ns = elapsed_ns;
            }
        }
        self.last_render_elapsed_ns = elapsed_ns;
    }
};

/// The `boo` command is used to display the project animation in the terminal.
pub fn run(gpa: Allocator) !u8 {
    // Disable on non-desktop systems.
    switch (builtin.os.tag) {
        .windows, .macos, .linux, .freebsd => {},
        else => return 1,
    }

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(gpa);
        defer iter.deinit();
        try args.parse(Options, gpa, &opts, &iter);
    }

    var frame_cache = try FrameCache.init(gpa);
    defer frame_cache.deinit(gpa);

    const trace_state_path = traceStatePathFromEnv(gpa);
    defer if (trace_state_path) |path| gpa.free(path);

    if (builtin.os.tag == .windows and !builtin.is_test) {
        return runWindows(gpa, frame_cache.rendered_frames, trace_state_path);
    }

    var app = try vxfw.App.init(gpa);
    var app_deinited = false;
    defer if (!app_deinited) app.deinit();

    var boo = Boo.init(frame_cache.rendered_frames, autoExitAfterNsFromEnv(gpa));
    const command_start = std.time.Instant.now() catch unreachable;

    writeTraceSnapshot(trace_state_path, "before_app_run", &boo, 0, null);
    try app.run(boo.widget(), .{ .framerate = Boo.app_poll_fps });
    const run_elapsed_ns = elapsedSince(command_start);
    writeTraceSnapshot(trace_state_path, "after_app_run", &boo, run_elapsed_ns, null);
    app.deinit();
    app_deinited = true;
    writeTraceSnapshot(trace_state_path, "after_app_deinit", &boo, run_elapsed_ns, elapsedSince(command_start));

    return 0;
}

fn runWindows(
    gpa: Allocator,
    frames: []const [Boo.frame_cell_count]vaxis.Cell,
    trace_state_path: ?[]const u8,
) !u8 {
    var tty_buffer: [1024]u8 = undefined;
    var tty = try vaxis.tty.WindowsTty.init(&tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(gpa, .{
        .system_clipboard_allocator = gpa,
    });
    var vx_deinited = false;
    defer if (!vx_deinited) vx.deinit(gpa, tty.writer());
    try vx.resize(gpa, tty.writer(), try currentWindowsWinsize(&tty));
    try vx.enterAltScreen(tty.writer());

    vxfw.DrawContext.init(vx.screen.width_method);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var render_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer render_buffer.deinit();

    var parser: vaxis.Parser = .{};
    var event_state: vaxis.tty.WindowsTty.EventState = .{};

    var boo = Boo.init(frames, autoExitAfterNsFromEnv(gpa));
    const command_start = std.time.Instant.now() catch unreachable;

    writeTraceSnapshot(trace_state_path, "before_app_run", &boo, 0, null);

    const tick_ms: u64 = @divFloor(std.time.ms_per_s, Boo.app_poll_fps);
    var next_frame_ms: u64 = @intCast(std.time.milliTimestamp());
    var redraw = boo.syncFrameForElapsedNs(0);
    var quit = false;

    while (!quit) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        if (now_ms >= next_frame_ms) {
            next_frame_ms = now_ms + tick_ms;
        } else {
            std.Thread.sleep((next_frame_ms - now_ms) * std.time.ns_per_ms);
            next_frame_ms += tick_ms;
        }

        var resized = false;
        while (try tryNextWindowsEvent(&tty, &parser, &event_state)) |event| {
            switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true }) or
                        key.matches(vaxis.Key.escape, .{}))
                    {
                        quit = true;
                    }
                },
                .winsize => {
                    try vx.resize(gpa, tty.writer(), try currentWindowsWinsize(&tty));
                    resized = true;
                },
                else => {},
            }
        }

        if (quit) break;

        const elapsed_ns = boo.elapsedNs();
        boo.recordTick(elapsed_ns);
        if (boo.syncFrameForElapsedNs(elapsed_ns)) redraw = true;
        if (boo.shouldAutoExitAfterElapsedNs(elapsed_ns)) break;
        if (resized) redraw = true;
        if (!redraw) continue;

        redraw = false;
        _ = arena.reset(.free_all);

        const surface = try boo.widget().draw(.{
            .arena = arena.allocator(),
            .min = .{ .width = 0, .height = 0 },
            .max = .{
                .width = @intCast(vx.screen.width),
                .height = @intCast(vx.screen.height),
            },
            .cell_size = .{
                .width = if (vx.screen.width > 0) vx.screen.width_pix / vx.screen.width else 0,
                .height = if (vx.screen.height > 0) vx.screen.height_pix / vx.screen.height else 0,
            },
        });
        const rendered_bytes = try renderSurfaceWithoutSynchronizedOutput(
            &vx,
            tty.writer(),
            &render_buffer,
            surface,
            boo.widget(),
        );
        boo.recordRender(elapsed_ns, rendered_bytes);
    }

    const run_elapsed_ns = elapsedSince(command_start);
    writeTraceSnapshot(trace_state_path, "after_app_run", &boo, run_elapsed_ns, null);
    vx.deinit(gpa, tty.writer());
    vx_deinited = true;
    writeTraceSnapshot(trace_state_path, "after_app_deinit", &boo, run_elapsed_ns, elapsedSince(command_start));
    return 0;
}

fn autoExitAfterNsFromEnv(gpa: Allocator) ?u64 {
    const raw = (os_env.getEnvVarOwnedTrimmedNotEmpty(
        gpa,
        "WINGHOSTTY_BOO_AUTO_EXIT_MS",
    ) catch return null) orelse return null;
    defer gpa.free(raw);

    const ms = std.fmt.parseUnsigned(u64, raw, 10) catch return null;
    return std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64);
}

fn traceStatePathFromEnv(gpa: Allocator) ?[]const u8 {
    return os_env.getEnvVarOwnedTrimmedNotEmpty(
        gpa,
        "WINGHOSTTY_BOO_STATE_FILE",
    ) catch null;
}

fn elapsedSince(start: std.time.Instant) u64 {
    const now = std.time.Instant.now() catch return 0;
    return now.since(start);
}

fn writeTraceSnapshot(
    path: ?[]const u8,
    phase: []const u8,
    boo: *const Boo,
    run_elapsed_ns: u64,
    total_elapsed_ns: ?u64,
) void {
    const trace_path = path orelse return;
    const file = std.fs.createFileAbsolute(trace_path, .{ .truncate = true }) catch |err| {
        std.log.warn("failed to open WINGHOSTTY_BOO_STATE_FILE path={s}: {}", .{ trace_path, err });
        return;
    };
    defer file.close();

    var buffer: [512]u8 = undefined;
    var writer = file.writer(&buffer);
    const stream = &writer.interface;
    stream.print("{f}", .{std.json.fmt(.{
        .phase = phase,
        .tick_count = boo.tick_count,
        .frame_change_count = boo.frame_change_count,
        .render_call_count = boo.render_call_count,
        .rendered_byte_count = boo.rendered_byte_count,
        .max_tick_gap_ms = @divFloor(boo.max_tick_gap_ns, std.time.ns_per_ms),
        .max_render_gap_ms = @divFloor(boo.max_render_gap_ns, std.time.ns_per_ms),
        .max_tick_gap_ended_at_ms = @divFloor(boo.max_tick_gap_ended_at_ns, std.time.ns_per_ms),
        .max_render_gap_ended_at_ms = @divFloor(boo.max_render_gap_ended_at_ns, std.time.ns_per_ms),
        .run_elapsed_ms = @divFloor(run_elapsed_ns, std.time.ns_per_ms),
        .total_elapsed_ms = if (total_elapsed_ns) |ns| @divFloor(ns, std.time.ns_per_ms) else null,
    }, .{})}) catch |err| {
        std.log.warn("failed to write WINGHOSTTY_BOO_STATE_FILE path={s}: {}", .{ trace_path, err });
        return;
    };
    stream.flush() catch |err| {
        std.log.warn("failed to flush WINGHOSTTY_BOO_STATE_FILE path={s}: {}", .{ trace_path, err });
        return;
    };
}

fn renderSurfaceWithoutSynchronizedOutput(
    vx: *vaxis.Vaxis,
    tty_writer: *std.Io.Writer,
    render_buffer: *std.Io.Writer.Allocating,
    surface: vxfw.Surface,
    focused_widget: vxfw.Widget,
) !usize {
    const win = vx.window();
    win.clear();
    win.hideCursor();
    win.setCursorShape(.default);

    const root_win = win.child(.{
        .width = surface.size.width,
        .height = surface.size.height,
    });
    surface.render(root_win, focused_widget);

    render_buffer.clearRetainingCapacity();
    // Nested under ConPTY, the tiny diff-only writes from vaxis can batch for
    // hundreds of milliseconds. Force a full refresh for this animation so
    // each frame emits a real VT frame instead of a handful of bytes.
    vx.queueRefresh();
    try vx.render(&render_buffer.writer);
    return try writeAllWithoutSynchronizedOutput(tty_writer, render_buffer.written());
}

fn writeAllWithoutSynchronizedOutput(tty_writer: *std.Io.Writer, bytes: []const u8) !usize {
    const sync_set = "\x1b[?2026h";
    const sync_reset = "\x1b[?2026l";

    var cursor: usize = 0;
    var written: usize = 0;
    while (cursor < bytes.len) {
        if (std.mem.startsWith(u8, bytes[cursor..], sync_set)) {
            cursor += sync_set.len;
            continue;
        }
        if (std.mem.startsWith(u8, bytes[cursor..], sync_reset)) {
            cursor += sync_reset.len;
            continue;
        }

        var next = bytes.len;
        if (std.mem.indexOfPos(u8, bytes, cursor, sync_set)) |idx| next = @min(next, idx);
        if (std.mem.indexOfPos(u8, bytes, cursor, sync_reset)) |idx| next = @min(next, idx);
        try tty_writer.writeAll(bytes[cursor..next]);
        written += next - cursor;
        cursor = next;
    }

    try tty_writer.flush();
    return written;
}

fn currentWindowsWinsize(tty: *vaxis.tty.WindowsTty) !vaxis.Winsize {
    var console_info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(tty.stdout, &console_info) == 0) {
        return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
    }

    const window_rect = console_info.srWindow;
    const width = window_rect.Right - window_rect.Left + 1;
    const height = window_rect.Bottom - window_rect.Top + 1;
    return .{
        .cols = @intCast(width),
        .rows = @intCast(height),
        .x_pixel = 0,
        .y_pixel = 0,
    };
}

fn tryNextWindowsEvent(
    tty: *vaxis.tty.WindowsTty,
    parser: *vaxis.Parser,
    state: *vaxis.tty.WindowsTty.EventState,
) !?vaxis.Event {
    while (true) {
        std.os.windows.WaitForSingleObject(tty.stdin, 0) catch |err| switch (err) {
            error.WaitTimeOut => return null,
            else => return err,
        };

        var event_count: u32 = 0;
        var input_record: vaxis.tty.WindowsTty.INPUT_RECORD = undefined;
        if (vaxis.tty.WindowsTty.ReadConsoleInputW(tty.stdin, &input_record, 1, &event_count) == 0) {
            return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
        }
        if (event_count == 0) return null;

        if (try tty.eventFromRecord(&input_record, state, parser, null)) |event| {
            return event;
        }
    }
}

pub const FrameCache = struct {
    decompressed_data: []const u8,
    rendered_frames: []const [Boo.frame_cell_count]vaxis.Cell,

    pub fn init(gpa: Allocator) !FrameCache {
        const decompressed_data = try decompressFrameData(gpa);
        errdefer gpa.free(decompressed_data);

        const frames = try splitFrames(gpa, decompressed_data);
        defer gpa.free(frames);

        const rendered_frames = try renderFrames(gpa, frames);
        errdefer gpa.free(rendered_frames);

        return .{
            .decompressed_data = decompressed_data,
            .rendered_frames = rendered_frames,
        };
    }

    pub fn deinit(self: *FrameCache, gpa: Allocator) void {
        gpa.free(self.rendered_frames);
        gpa.free(self.decompressed_data);
    }
};

fn decompressFrameData(gpa: Allocator) ![]const u8 {
    var src: std.Io.Reader = .fixed(framedata);

    var decompress: std.compress.flate.Decompress = .init(&src, .raw, &.{});

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try decompress.reader.streamRemaining(&out.writer);
    return try out.toOwnedSlice();
}

fn splitFrames(gpa: Allocator, decompressed_data: []const u8) ![]const []const u8 {
    var frame_list: std.ArrayList([]const u8) = try .initCapacity(gpa, 235);
    errdefer frame_list.deinit(gpa);

    var frame_iter = std.mem.splitScalar(u8, decompressed_data, '\x01');
    while (frame_iter.next()) |frame| {
        try frame_list.append(gpa, frame);
    }
    return try frame_list.toOwnedSlice(gpa);
}

fn renderFrames(
    gpa: Allocator,
    frames: []const []const u8,
) ![]const [Boo.frame_cell_count]vaxis.Cell {
    const rendered_frames = try gpa.alloc([Boo.frame_cell_count]vaxis.Cell, frames.len);
    errdefer gpa.free(rendered_frames);

    for (frames, rendered_frames) |frame, *rendered| {
        try decodeFrame(frame, rendered[0..]);
    }

    return rendered_frames;
}

fn decodeFrame(frame: []const u8, buffer: []vaxis.Cell) !void {
    const State = enum {
        normal,
        span,
        in_tag,
        in_closing_tag,
    };

    var cell_idx: usize = 0;

    var line_iter = std.mem.splitScalar(u8, frame, '\n');
    while (line_iter.next()) |line| {
        var state: State = .normal;
        var style = ghostty_style;
        var cp_iter: std.unicode.Utf8Iterator = .{ .bytes = line, .i = 0 };
        while (cp_iter.nextCodepointSlice()) |char| {
            switch (state) {
                .normal => if (std.mem.eql(u8, "<", char)) {
                    state = .in_tag;
                    style = outline_style;
                    continue;
                },
                .span => if (std.mem.eql(u8, "<", char)) {
                    state = .in_tag;
                    style = ghostty_style;
                    continue;
                },
                .in_tag => {
                    if (std.mem.eql(u8, "/", char))
                        state = .in_closing_tag
                    else if (std.mem.eql(u8, ">", char))
                        state = .span;
                    continue;
                },
                .in_closing_tag => {
                    if (std.mem.eql(u8, ">", char)) state = .normal;
                    continue;
                },
            }

            if (cell_idx >= buffer.len) return error.InvalidFrameData;
            buffer[cell_idx] = .{
                .char = .{
                    .grapheme = char,
                    .width = 1,
                },
                .style = style,
            };
            cell_idx += 1;
        }
    }

    if (cell_idx != buffer.len) return error.InvalidFrameData;
}

fn frameIndexForElapsedNs(elapsed_ns: u64, frame_count: usize) ?usize {
    if (frame_count == 0) return null;
    return @as(usize, @intCast((elapsed_ns / Boo.animation_frame_ns) % frame_count));
}

fn legacyFrameCountForCoarsePoll(
    total_ms: u64,
    poll_ms: u64,
    tick_ms: u64,
) usize {
    var frame_count: usize = 1;
    var now_ms: u64 = 0;
    var next_tick_ms = tick_ms;

    while (true) {
        now_ms += poll_ms;
        if (now_ms > total_ms) break;
        if (now_ms < next_tick_ms) continue;
        frame_count += 1;
        next_tick_ms = now_ms + tick_ms;
    }

    return frame_count;
}

fn clockSyncedFrameCountForCoarsePoll(
    total_ms: u64,
    poll_ms: u64,
    frame_count: usize,
) usize {
    var displayed: ?usize = null;
    var shown: usize = 0;
    var now_ms: u64 = 0;

    while (now_ms <= total_ms) : (now_ms += poll_ms) {
        const frame = frameIndexForElapsedNs(now_ms * std.time.ns_per_ms, frame_count);
        if (displayed == frame) continue;
        displayed = frame;
        shown += 1;
    }

    return shown;
}

test "decodeFrame applies span styling and preserves cell count" {
    var buffer: [4]vaxis.Cell = undefined;
    try decodeFrame("A<span>BC</span>D", buffer[0..]);

    try std.testing.expectEqualStrings("A", buffer[0].char.grapheme);
    try std.testing.expect(vaxis.Cell.Style.eql(buffer[0].style, ghostty_style));
    try std.testing.expectEqualStrings("B", buffer[1].char.grapheme);
    try std.testing.expect(vaxis.Cell.Style.eql(buffer[1].style, outline_style));
    try std.testing.expectEqualStrings("C", buffer[2].char.grapheme);
    try std.testing.expect(vaxis.Cell.Style.eql(buffer[2].style, outline_style));
    try std.testing.expectEqualStrings("D", buffer[3].char.grapheme);
    try std.testing.expect(vaxis.Cell.Style.eql(buffer[3].style, ghostty_style));
}

test "FrameCache renders boo frames once" {
    var cache = try FrameCache.init(std.testing.allocator);
    defer cache.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 235), cache.rendered_frames.len);
    try std.testing.expectEqualStrings(" ", cache.rendered_frames[0][0].char.grapheme);
}

test "Boo syncFrameForElapsedNs advances and wraps on frame boundaries" {
    var frames = [_][Boo.frame_cell_count]vaxis.Cell{
        [_]vaxis.Cell{.{}} ** Boo.frame_cell_count,
        [_]vaxis.Cell{.{}} ** Boo.frame_cell_count,
    };
    frames[0][0].char.grapheme = "A";
    frames[1][0].char.grapheme = "B";

    var boo = Boo.init(frames[0..], null);
    try std.testing.expect(boo.syncFrameForElapsedNs(0));
    try std.testing.expectEqualStrings("A", boo.buffer[0].char.grapheme);
    try std.testing.expectEqual(@as(?usize, 0), boo.displayed_frame);

    try std.testing.expect(!boo.syncFrameForElapsedNs(Boo.animation_frame_ns - 1));
    try std.testing.expect(boo.syncFrameForElapsedNs(Boo.animation_frame_ns));
    try std.testing.expectEqualStrings("B", boo.buffer[0].char.grapheme);
    try std.testing.expectEqual(@as(?usize, 1), boo.displayed_frame);

    try std.testing.expect(boo.syncFrameForElapsedNs(Boo.animation_frame_ns * 2));
    try std.testing.expectEqualStrings("A", boo.buffer[0].char.grapheme);
    try std.testing.expectEqual(@as(?usize, 0), boo.displayed_frame);
}

test "Boo auto-exit triggers at configured deadline" {
    var frames = [_][Boo.frame_cell_count]vaxis.Cell{
        [_]vaxis.Cell{.{}} ** Boo.frame_cell_count,
    };

    var boo = Boo.init(frames[0..], 500 * std.time.ns_per_ms);
    try std.testing.expect(!boo.shouldAutoExitAfterElapsedNs(499 * std.time.ns_per_ms));
    try std.testing.expect(boo.shouldAutoExitAfterElapsedNs(500 * std.time.ns_per_ms));
}

test "boo cached frame selection matches reparsed frames" {
    const testing = std.testing;

    const decompressed_data = try decompressFrameData(testing.allocator);
    defer testing.allocator.free(decompressed_data);

    const frames = try splitFrames(testing.allocator, decompressed_data);
    defer testing.allocator.free(frames);

    const rendered_frames = try renderFrames(testing.allocator, frames);
    defer testing.allocator.free(rendered_frames);

    var boo = Boo.init(rendered_frames, null);
    var buffer: [Boo.frame_cell_count]vaxis.Cell = undefined;
    for (0..frames.len) |i| {
        _ = boo.syncFrameForElapsedNs(i * Boo.animation_frame_ns);
        try decodeFrame(frames[i], buffer[0..]);
        try testing.expectEqualDeep(buffer, boo.buffer);
    }
}

test "boo clock-synced polling avoids missing every other frame on coarse windows timers" {
    const coarse_poll_ms = 31;
    const legacy_tick_ms = 1000 / Boo.animation_fps;
    const duration_ms = 1000;

    const legacy_frames = legacyFrameCountForCoarsePoll(
        duration_ms,
        coarse_poll_ms,
        legacy_tick_ms,
    );
    const clock_synced_frames = clockSyncedFrameCountForCoarsePoll(
        duration_ms,
        coarse_poll_ms,
        235,
    );

    try std.testing.expect(legacy_frames < 20);
    try std.testing.expect(clock_synced_frames >= 29);
}
