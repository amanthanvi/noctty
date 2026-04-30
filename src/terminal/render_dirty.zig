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

fn packedStructDirty(value: anytype) bool {
    const T = @TypeOf(value);
    const Int = @typeInfo(T).@"struct".backing_integer.?;
    return @as(Int, @bitCast(value)) != 0;
}

test "needsRendererWake tracks visible terminal dirtiness" {
    const testing = @import("std").testing;

    var term = try terminalpkg.Terminal.init(testing.allocator, .{
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
