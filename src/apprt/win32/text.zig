const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub fn appendOwnedString(
    alloc: Allocator,
    target: *?[:0]const u8,
    value: ?[]const u8,
) !void {
    if (value) |next_value| {
        if (target.*) |existing| {
            if (std.mem.eql(u8, existing, next_value)) return;
        }
    } else if (target.* == null) {
        return;
    }

    // Allocate first, then free the old slot. Reversing the order
    // means that (a) an OOM leaves `*target` holding a still-valid
    // previous allocation instead of a dangling freed pointer, and
    // (b) a caller passing a `value` that aliases the current slot
    // is copied to fresh storage before the free, avoiding UAF.
    const next: ?[:0]const u8 = if (value) |v| try alloc.dupeZ(u8, v) else null;
    if (target.*) |existing| alloc.free(existing);
    target.* = next;
}

pub fn ownedStringEquals(current: ?[:0]const u8, value: []const u8) bool {
    return if (current) |existing|
        std.mem.eql(u8, existing, value)
    else
        false;
}

pub fn ownedBytesEquals(current: ?[]const u8, value: []const u8) bool {
    return if (current) |existing|
        std.mem.eql(u8, existing, value)
    else
        false;
}

pub fn optionalOwnedStringEquals(current: ?[:0]const u8, value: ?[]const u8) bool {
    return if (value) |existing|
        ownedStringEquals(current, existing)
    else
        current == null;
}

/// The longest prefix of `text` that fits `limit` bytes without splitting
/// a UTF-8 sequence.
///
/// For UI Automation names, which are converted to a `BSTR` and rejected
/// outright if the conversion fails: a name that overflows its caller's
/// buffer has to come back shortened, never empty, because the caller is
/// usually a live region that is about to be announced.
///
/// Deliberately simpler than the back-off in `buildConfirmPreview`, which
/// must not drag its cut through orphan continuation bytes because it is
/// showing arbitrary payload bytes and reports how many it showed. Names
/// come from strings this process built, so a plain walk is enough.
pub fn utf8BoundedPrefix(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    // A UTF-8 sequence is at most 4 bytes, so the lead byte is at most 3
    // positions back.
    var steps: usize = 0;
    while (steps < 4 and end > 0) : (steps += 1) {
        if ((text[end] & 0xC0) != 0x80) break;
        end -= 1;
    }
    return text[0..end];
}

test "bounded UTF-16 long ASCII and BMP text preserve buffer guards" {
    // 300 copies of U+65E5 is 300 units; 200 would fit the 256-unit buffer.
    const cases = .{ "a" ** 300, "\u{65e5}" ** 300 };
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

test "win32 utf8BoundedPrefix never splits a codepoint" {
    try std.testing.expectEqualStrings("abc", utf8BoundedPrefix("abc", 8));
    try std.testing.expectEqualStrings("abc", utf8BoundedPrefix("abc", 3));
    try std.testing.expectEqualStrings("ab", utf8BoundedPrefix("abc", 2));
    try std.testing.expectEqualStrings("", utf8BoundedPrefix("abc", 0));

    // "aé" is 3 bytes; a 2-byte limit lands mid-sequence and has to back
    // off to 1 rather than hand back half a codepoint.
    const accented = "a\u{e9}b";
    try std.testing.expectEqualStrings("a", utf8BoundedPrefix(accented, 2));
    try std.testing.expectEqualStrings("a\u{e9}", utf8BoundedPrefix(accented, 3));

    // A 4-byte sequence, cut at every interior offset.
    const emoji = "x\u{1f600}y";
    try std.testing.expectEqualStrings("x", utf8BoundedPrefix(emoji, 2));
    try std.testing.expectEqualStrings("x", utf8BoundedPrefix(emoji, 3));
    try std.testing.expectEqualStrings("x", utf8BoundedPrefix(emoji, 4));
    try std.testing.expectEqualStrings("x\u{1f600}", utf8BoundedPrefix(emoji, 5));

    // Every result is valid UTF-8, which is what the BSTR conversion needs.
    for (0..emoji.len + 2) |limit| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(utf8BoundedPrefix(emoji, limit)));
    }
}

test "win32 appendOwnedString replaces existing value and frees old allocation" {
    const testing = std.testing;
    var target: ?[:0]const u8 = null;
    try appendOwnedString(testing.allocator, &target, "alpha");
    try testing.expect(target != null);
    try testing.expectEqualStrings("alpha", target.?);

    try appendOwnedString(testing.allocator, &target, "beta");
    try testing.expect(target != null);
    try testing.expectEqualStrings("beta", target.?);

    try appendOwnedString(testing.allocator, &target, null);
    try testing.expect(target == null);
}

test "win32 appendOwnedString skips exact same-value reallocation" {
    const testing = std.testing;
    var target: ?[:0]const u8 = null;
    defer if (target) |value| testing.allocator.free(value);

    try appendOwnedString(testing.allocator, &target, "alpha");
    const before = target.?.ptr;
    try appendOwnedString(testing.allocator, &target, "alpha");
    try testing.expect(target != null);
    try testing.expect(target.?.ptr == before);

    try appendOwnedString(testing.allocator, &target, null);
    try testing.expect(target == null);
    try appendOwnedString(testing.allocator, &target, null);
    try testing.expect(target == null);
}

test "win32 appendOwnedString leaves target untouched on OOM" {
    // OOM must leave `target.*` pointing at the existing allocation.
    const testing = std.testing;
    var arena: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&arena);
    const alloc = fixed.allocator();

    var target: ?[:0]const u8 = null;
    try appendOwnedString(alloc, &target, "warm-up");
    try testing.expectEqualStrings("warm-up", target.?);

    // Force an allocation failure with a value too large to fit.
    const huge = "x" ** 512;
    const before = target.?.ptr;
    try testing.expectError(error.OutOfMemory, appendOwnedString(alloc, &target, huge));
    try testing.expect(target != null);
    try testing.expect(target.?.ptr == before);
    try testing.expectEqualStrings("warm-up", target.?);
}

test "win32 optionalOwnedStringEquals handles present and null values" {
    try std.testing.expect(optionalOwnedStringEquals(null, null));
    try std.testing.expect(!optionalOwnedStringEquals(null, "pwsh"));
    try std.testing.expect(optionalOwnedStringEquals("pwsh", "pwsh"));
    try std.testing.expect(!optionalOwnedStringEquals("pwsh", "cmd"));
    try std.testing.expect(!optionalOwnedStringEquals("pwsh", null));
}

test "win32 ownedBytesEquals handles present and missing values" {
    try std.testing.expect(!ownedBytesEquals(null, "v1.2.3"));
    try std.testing.expect(ownedBytesEquals("v1.2.3", "v1.2.3"));
    try std.testing.expect(!ownedBytesEquals("v1.2.3", "v1.2.4"));
}
