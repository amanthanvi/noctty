const std = @import("std");
const terminalpkg = @import("main.zig");

pub fn needsRendererWake(t: *const terminalpkg.Terminal) bool {
    const screen = t.screens.active;

    if (packedStructDirty(t.flags.dirty)) return true;
    if (packedStructDirty(screen.dirty)) return true;
    if (screen.kitty_images.dirty) return true;

    var row_it = screen.pages.rowIterator(.left_up, .{ .viewport = .{} }, null);
    while (row_it.next()) |pin| {
        if (pin.isDirty()) return true;
    }

    return false;
}

/// What output can change in a frame without marking anything dirty: where
/// the cursor is and how it looks, and the default colors. Moving the cursor
/// within its row (BS, CUB, CUF, CHA, or CUP to the same row), changing its
/// shape, visibility or blinking, or setting a color with OSC 10, 11 or 12
/// marks nothing dirty. The renderer keeps this snapshot as of its last frame
/// update (`renderer.State.drawn_undirtied`), and a terminal that no longer
/// matches it needs a frame just as a dirty one does.
pub const Undirtied = struct {
    screen: terminalpkg.ScreenSet.Key,
    cursor_x: terminalpkg.size.CellCountInt,
    cursor_y: terminalpkg.size.CellCountInt,
    cursor_style: terminalpkg.CursorStyle,
    cursor_visible: bool,
    cursor_blinking: bool,
    foreground: ?terminalpkg.color.RGB,
    background: ?terminalpkg.color.RGB,
    cursor_color: ?terminalpkg.color.RGB,

    pub fn init(t: *const terminalpkg.Terminal) Undirtied {
        const cursor = &t.screens.active.cursor;
        return .{
            .screen = t.screens.active_key,
            .cursor_x = cursor.x,
            .cursor_y = cursor.y,
            .cursor_style = cursor.cursor_style,
            .cursor_visible = t.modes.get(.cursor_visible),
            .cursor_blinking = t.modes.get(.cursor_blinking),
            .foreground = t.colors.foreground.get(),
            .background = t.colors.background.get(),
            .cursor_color = t.colors.cursor.get(),
        };
    }
};

/// Whether the terminal holds anything the last frame update did not draw:
/// dirty state, or undirtied state that differs from `drawn` (null before
/// the first frame update).
pub fn needsFrame(t: *const terminalpkg.Terminal, drawn: ?Undirtied) bool {
    if (needsRendererWake(t)) return true;
    const last = drawn orelse return true;
    return !std.meta.eql(last, Undirtied.init(t));
}

fn packedStructDirty(value: anytype) bool {
    const T = @TypeOf(value);
    const Int = @typeInfo(T).@"struct".backing_integer.?;
    return @as(Int, @bitCast(value)) != 0;
}

test "needsRendererWake tracks visible terminal dirtiness" {
    const testing = @import("std").testing;

    var term = try terminalpkg.Terminal.init(std.testing.io, testing.allocator, .{
        .cols = 4,
        .rows = 3,
    });
    defer term.deinit(testing.allocator);

    try testing.expect(!needsRendererWake(&term));

    term.flags.dirty.palette = true;
    try testing.expect(needsRendererWake(&term));
    term.flags.dirty = .{};

    term.screens.active.kitty_images.dirty = true;
    try testing.expect(needsRendererWake(&term));
    term.screens.active.kitty_images.dirty = false;

    try term.printString("x");
    try testing.expect(needsRendererWake(&term));
}

test "output that only moves the cursor or sets a color still needs a frame" {
    const testing = std.testing;

    var term = try terminalpkg.Terminal.init(std.testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    defer term.deinit(testing.allocator);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("abc");

    // Before the first frame update, everything needs one.
    try testing.expect(needsFrame(&term, null));

    const cases = [_][]const u8{
        "\x08", // BS, the echo of Left in a line editor
        "\x1b[D", // CUB
        "\x1b[C", // CUF
        "\x1b[1G", // CHA
        "\x1b[1;3H", // CUP within the cursor's row
        "\x1b[5 q", // DECSCUSR: blinking bar
        "\x1b[?25l", // DECTCEM: hide
        "\x1b]11;rgb:10/20/30\x1b\\", // OSC 11: background
    };
    for (cases) |output| {
        // As the renderer leaves it after a frame update.
        term.screens.active.pages.clearDirty();
        const drawn: Undirtied = .init(&term);
        try testing.expect(!needsFrame(&term, drawn));

        stream.nextSlice(output);
        try testing.expect(!needsRendererWake(&term));
        try testing.expect(needsFrame(&term, drawn));

        // Until a frame draws it, later output that changes nothing (a
        // synchronized-output end in a read of its own) keeps it pending.
        stream.nextSlice("\x1b[?2026h\x1b[?2026l");
        try testing.expect(!needsRendererWake(&term));
        try testing.expect(needsFrame(&term, drawn));
    }

    // A move to another row marks rows dirty, as text does.
    term.screens.active.pages.clearDirty();
    stream.nextSlice("\x1b[2;1H");
    try testing.expect(needsRendererWake(&term));
}
