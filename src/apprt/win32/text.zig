const std = @import("std");

/// Write a terminated prefix without allocating or splitting surrogate pairs.
/// Invalid UTF-8 anywhere in src produces empty output, including past the cap.
pub fn utf8ToUtf16LeBounded(dest: []u16, src: []const u8) usize {
    if (dest.len == 0) return 0;
    dest[0] = 0;
    const view = std.unicode.Utf8View.init(src) catch return 0;
    var iter = view.iterator();
    var n: usize = 0;
    while (iter.nextCodepoint()) |cp| {
        const units: usize = if (cp < 0x10000) 1 else 2;
        if (units > dest.len - 1 - n) break;
        if (units == 1) {
            dest[n] = std.mem.nativeToLittle(u16, @intCast(cp));
        } else {
            const value = cp - 0x10000;
            dest[n] = std.mem.nativeToLittle(u16, @intCast(0xd800 + (value >> 10)));
            dest[n + 1] = std.mem.nativeToLittle(u16, @intCast(0xdc00 + (value & 0x3ff)));
        }
        n += units;
    }
    dest[n] = 0;
    return n;
}

pub fn replaceCachedUtf16(alloc: std.mem.Allocator, target: *?[:0]const u16, text: []const u8) !void {
    const replacement = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    if (target.*) |old| alloc.free(old);
    target.* = replacement;
}

test "bounded UTF-16 long ASCII and BMP text preserve buffer guards" {
    const cases = .{ "a" ** 300, "\u{65e5}" ** 200 };
    inline for (cases) |src| {
        var guarded = [_]u16{0xabcd} ** 258;
        const n = utf8ToUtf16LeBounded(guarded[1..257], src);
        try std.testing.expectEqual(@min(try std.unicode.calcUtf16LeLen(src), 255), n);
        try std.testing.expectEqual(@as(u16, 0), guarded[1 + n]);
        try std.testing.expectEqual(@as(u16, 0xabcd), guarded[0]);
        try std.testing.expectEqual(@as(u16, 0xabcd), guarded[257]);
    }
}

test "bounded UTF-16 preserves supplementary pairs at capacity" {
    var buf: [256]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 254), utf8ToUtf16LeBounded(&buf, "a" ** 254 ++ "\u{1f600}"));
    try std.testing.expectEqual(@as(u16, 0), buf[254]);
    try std.testing.expectEqual(@as(usize, 255), utf8ToUtf16LeBounded(&buf, "a" ** 253 ++ "\u{1f600}"));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\u{1f600}"), buf[253..255]);
    try std.testing.expectEqual(@as(u16, 0), buf[255]);
}

test "bounded UTF-16 handles empty tiny exact and invalid inputs" {
    var empty: [0]u16 = .{};
    try std.testing.expectEqual(@as(usize, 0), utf8ToUtf16LeBounded(&empty, "a"));
    var tiny = [_]u16{123};
    try std.testing.expectEqual(@as(usize, 0), utf8ToUtf16LeBounded(&tiny, "\u{1f600}"));
    try std.testing.expectEqual(@as(u16, 0), tiny[0]);
    var buf: [256]u16 = undefined;
    inline for (.{ 0, 255, 256, 257 }) |len| {
        try std.testing.expectEqual(@min(len, 255), utf8ToUtf16LeBounded(&buf, "a" ** len));
        try std.testing.expectEqual(@as(u16, 0), buf[@min(len, 255)]);
    }
    inline for (.{ "ok\xff", "a" ** 300 ++ "\xff", "\xed\xa0\x80", "\xf0\x9f\x98" }) |src| {
        try std.testing.expectEqual(@as(usize, 0), utf8ToUtf16LeBounded(&buf, src));
        try std.testing.expectEqual(@as(u16, 0), buf[0]);
    }
}

test "replaceCachedUtf16 retains old allocation on OOM and permits retry and teardown" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var cache: ?[:0]const u16 = null;
    try replaceCachedUtf16(alloc, &cache, "old\u{1f600}");
    const old = cache.?;
    const freed_before = failing.freed_bytes;
    // Clean up on an assertion failure without freeing an already-freed cache.
    defer if (failing.freed_bytes == freed_before) alloc.free(old);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, replaceCachedUtf16(alloc, &cache, "replacement"));
    try std.testing.expectEqual(freed_before, failing.freed_bytes);
    try std.testing.expectEqual(old.ptr, cache.?.ptr);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("old\u{1f600}"), cache.?);
    failing.fail_index = std.math.maxInt(usize);
    try replaceCachedUtf16(alloc, &cache, "new");
    alloc.free(cache.?);
    cache = null;
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "replaceCachedUtf16 preserves cache on invalid input and replaces with empty text" {
    const alloc = std.testing.allocator;
    var cache: ?[:0]const u16 = null;
    try replaceCachedUtf16(alloc, &cache, "old");
    defer if (cache) |value| alloc.free(value);
    const old = cache.?.ptr;
    try std.testing.expectError(error.InvalidUtf8, replaceCachedUtf16(alloc, &cache, "\xff"));
    try std.testing.expectEqual(old, cache.?.ptr);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("old"), cache.?);
    try replaceCachedUtf16(alloc, &cache, "");
    try std.testing.expectEqual(@as(usize, 0), cache.?.len);
    try std.testing.expectEqual(@as(u16, 0), cache.?[0]);
}
