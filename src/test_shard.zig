//! Which tests one shard of a Zig test executable runs (`--shard=K/N`, read by
//! src/test_runner.zig). Test `i` of a shard is the executable's test
//! `index + i * count`, so the shards of one count partition the tests and
//! neighbouring tests, often one file's slow ones, land in different shards.
//!
//! Its own file because the runner's module is not the tested module: a test
//! block in src/test_runner.zig is never compiled into the executable (a
//! `-Dtest-filter=test_runner` run counted the 72 tests of a filter that matches
//! nothing). build.zig tests this file on its own in the `test` step.
const std = @import("std");

pub const Shard = struct {
    /// Zero-based: `--shard=1/N` is index 0.
    index: u32 = 0,
    count: u32 = 1,

    /// Parses `K/N`, 1 <= K <= N.
    pub fn parse(text: []const u8) ?Shard {
        const slash = std.mem.indexOfScalar(u8, text, '/') orelse return null;
        const k = std.fmt.parseUnsigned(u32, text[0..slash], 10) catch return null;
        const n = std.fmt.parseUnsigned(u32, text[slash + 1 ..], 10) catch return null;
        if (n == 0 or k == 0 or k > n) return null;
        return .{ .index = k - 1, .count = n };
    }

    /// How many of `total` tests this shard runs.
    pub fn len(s: Shard, total: usize) usize {
        if (s.index >= total) return 0;
        return (total - s.index + s.count - 1) / s.count;
    }

    /// The executable's index of the shard's test `i`.
    pub fn testIndex(s: Shard, i: usize) usize {
        return s.index + i * s.count;
    }
};

test "a shard argument is K/N with 1 <= K <= N" {
    try std.testing.expectEqual(Shard{ .index = 0, .count = 1 }, Shard.parse("1/1").?);
    try std.testing.expectEqual(Shard{ .index = 2, .count = 4 }, Shard.parse("3/4").?);
    try std.testing.expectEqual(Shard{ .index = 3, .count = 4 }, Shard.parse("4/4").?);
    for ([_][]const u8{ "", "1", "/", "0/4", "5/4", "1/0", "-1/4", "1/4/2", "a/4", "1/ 4", " 1/4", "1/4 " }) |bad| {
        try std.testing.expectEqual(@as(?Shard, null), Shard.parse(bad));
    }
}

test "the shards of one count run every test exactly once" {
    // Counts above and below the number of tests, and a suite's size.
    for ([_]usize{ 0, 1, 2, 7, 70, 6771 }) |total| {
        for (1..10) |count| {
            var seen: [6771]u8 = @splat(0);
            var sum: usize = 0;
            for (0..count) |k| {
                const s: Shard = .{ .index = @intCast(k), .count = @intCast(count) };
                const n = s.len(total);
                sum += n;
                for (0..n) |i| seen[s.testIndex(i)] += 1;
            }
            try std.testing.expectEqual(total, sum);
            for (seen[0..total]) |times| try std.testing.expectEqual(@as(u8, 1), times);
        }
    }
}

test "the default shard is every test, in order" {
    const all: Shard = .{};
    try std.testing.expectEqual(@as(usize, 6771), all.len(6771));
    for (0..6771) |i| try std.testing.expectEqual(i, all.testIndex(i));
}
