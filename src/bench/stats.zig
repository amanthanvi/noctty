//! Small statistics helpers for benchmark sample slices.
//!
//! `median` and `percentile` require samples sorted in ascending order.
//! An even-sized median is the arithmetic mean of the two middle samples.
//! Percentiles use nearest-rank: for percentile `p`, select rank
//! `ceil(p / 100 * N)`, with p0 explicitly selecting the minimum. Empty
//! slices return null from every helper.

const std = @import("std");

pub fn mean(samples: anytype) ?f64 {
    if (samples.len == 0) return null;

    var sum: f64 = 0;
    for (samples) |sample| sum += asF64(sample);
    return sum / @as(f64, @floatFromInt(samples.len));
}

pub fn median(sorted_samples: anytype) ?f64 {
    if (sorted_samples.len == 0) return null;

    const middle = sorted_samples.len / 2;
    if (sorted_samples.len % 2 == 1) return asF64(sorted_samples[middle]);
    return (asF64(sorted_samples[middle - 1]) + asF64(sorted_samples[middle])) / 2;
}

/// Return a nearest-rank percentile from an ascending sample slice.
///
/// `p` is inclusive in the range 0...100. p0 returns the first sample and
/// p100 returns the last sample.
pub fn percentile(sorted_samples: anytype, p: f64) ?sampleType(@TypeOf(sorted_samples)) {
    std.debug.assert(std.math.isFinite(p));
    std.debug.assert(p >= 0 and p <= 100);
    if (sorted_samples.len == 0) return null;
    if (p == 0) return sorted_samples[0];

    const rank_float = @ceil(
        p / 100 * @as(f64, @floatFromInt(sorted_samples.len)),
    );
    const rank: usize = @intFromFloat(rank_float);
    return sorted_samples[rank - 1];
}

pub fn min(samples: anytype) ?sampleType(@TypeOf(samples)) {
    if (samples.len == 0) return null;

    var result = samples[0];
    for (samples[1..]) |sample| result = @min(result, sample);
    return result;
}

pub fn max(samples: anytype) ?sampleType(@TypeOf(samples)) {
    if (samples.len == 0) return null;

    var result = samples[0];
    for (samples[1..]) |sample| result = @max(result, sample);
    return result;
}

fn sampleType(comptime Slice: type) type {
    return switch (@typeInfo(Slice)) {
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| array.child,
            else => pointer.child,
        },
        else => @compileError("benchmark statistics require a sample slice"),
    };
}

fn asF64(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => @compileError("benchmark statistics require numeric samples"),
    };
}

test "issue121-bench-stats empty and single samples" {
    const testing = std.testing;
    const empty = [_]u64{};
    try testing.expectEqual(null, mean(empty[0..]));
    try testing.expectEqual(null, median(empty[0..]));
    try testing.expectEqual(null, percentile(empty[0..], 95));
    try testing.expectEqual(null, min(empty[0..]));
    try testing.expectEqual(null, max(empty[0..]));

    const single = [_]u64{42};
    try testing.expectEqual(@as(f64, 42), mean(single[0..]));
    try testing.expectEqual(@as(f64, 42), median(single[0..]));
    try testing.expectEqual(@as(u64, 42), percentile(single[0..], 0).?);
    try testing.expectEqual(@as(u64, 42), percentile(single[0..], 100).?);
    try testing.expectEqual(@as(u64, 42), min(single[0..]).?);
    try testing.expectEqual(@as(u64, 42), max(single[0..]).?);
}

test "issue121-bench-stats even odd and nearest-rank percentiles" {
    const testing = std.testing;

    const even = [_]u64{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(f64, 2.5), median(even[0..]));
    try testing.expectEqual(@as(f64, 2.5), mean(even[0..]));

    const odd = [_]u64{ 1, 3, 9 };
    try testing.expectEqual(@as(f64, 3), median(odd[0..]));

    const ranks = [_]u64{
        1,  2,  3,  4,  5,
        6,  7,  8,  9,  10,
        11, 12, 13, 14, 15,
        16, 17, 18, 19, 20,
    };
    try testing.expectEqual(@as(u64, 1), percentile(ranks[0..], 0).?);
    try testing.expectEqual(@as(u64, 10), percentile(ranks[0..], 50).?);
    try testing.expectEqual(@as(u64, 19), percentile(ranks[0..], 95).?);
    try testing.expectEqual(@as(u64, 20), percentile(ranks[0..], 100).?);

    const unsorted = [_]u64{ 7, 2, 11, 4 };
    try testing.expectEqual(@as(u64, 2), min(unsorted[0..]).?);
    try testing.expectEqual(@as(u64, 11), max(unsorted[0..]).?);
}
