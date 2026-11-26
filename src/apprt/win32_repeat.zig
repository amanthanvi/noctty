//! `"s" ** N` for string literals, which Zig 0.17 removed. `repeat` is the same
//! comptime value: a sentinel-terminated string of `unit` repeated `count`
//! times, so every context that took the literal still takes it.

const std = @import("std");

/// `unit` repeated `count` times, as a literal-typed (`*const [N:0]u8`) value.
pub fn repeat(comptime unit: []const u8, comptime count: usize) *const [unit.len * count:0]u8 {
    return comptime blk: {
        @setEvalBranchQuota(100 * (unit.len * count) + 10_000);
        var out: [unit.len * count:0]u8 = undefined;
        if (unit.len == 1) {
            @memset(&out, unit[0]);
        } else {
            for (0..count) |i| @memcpy(out[i * unit.len ..][0..unit.len], unit);
        }
        out[out.len] = 0;
        const final = out;
        break :blk &final;
    };
}

test "repeat is the literal repeated" {
    try std.testing.expectEqualStrings("", repeat("ab", 0));
    try std.testing.expectEqualStrings("a", repeat("a", 1));
    try std.testing.expectEqualStrings("ababab", repeat("ab", 3));
    // A multi-byte unit stays whole.
    try std.testing.expectEqualStrings("\u{e9}\u{e9}\u{e9}", repeat("\u{e9}", 3));
    // The result is a sentinel-terminated literal type.
    try std.testing.expectEqual(@as(u8, 0), repeat("xy", 2)[4]);
    const long = repeat("x", 4094);
    try std.testing.expectEqual(@as(usize, 4094), long.len);
    for (long) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
    // It concatenates and coerces to a slice as a literal does.
    const joined = "#" ++ repeat("x", 3) ++ "\n";
    try std.testing.expectEqualStrings("#xxx\n", joined);
    const slice: []const u8 = repeat("ab", 2);
    try std.testing.expectEqualStrings("abab", slice);
}
