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

/// Whether a set of throughput samples (higher is better) clears a floor.
///
/// The fastest sample is compared, not the median. Contention on a shared
/// runner can only slow a run down, in bursts that can cover most of a short
/// sequence, so the fastest run is the least noisy estimate of what the code
/// can do; a real regression slows every run, the fastest included. A floor of
/// zero disables the check.
pub fn fastestClearsFloor(samples: anytype, floor: f64) bool {
    if (floor <= 0) return true;
    const fastest = max(samples) orelse return false;
    return asF64(fastest) >= floor;
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

// Throughput in MB/s, in run order, 4 MiB per run on windows-2025 runners
// (the slowest class gives about 68 for ASCII and scroll). Provenance is noted
// per sequence.
test "issue121-bench-stats the fastest run clears a floor that contention cannot move" {
    const testing = std.testing;
    const ascii_floor = 50;
    const scroll_floor = 50;

    // The three blocks the median-of-five gate at 50 MB/s failed in the bench
    // job's own log (2026-10-23 and 24). Each holds a run above 50, though only
    // the scroll block's best is near speed: the two ASCII bests are 0.84x and
    // 0.76x of the slowest class's 67.7, so those jobs were depressed for the
    // whole block, and the 51.25 clears the floor by 2.5%. The runners' CPU
    // class was not recorded (the scroll job's other workloads point to an
    // EPYC 7763; inferred).
    const main_ascii = [_]f64{ 41.97, 56.85, 31.78, 35.82, 27.6 };
    const pr_ascii = [_]f64{ 51.25, 43.46, 47.95, 36.75, 48.24 };
    const main_scroll = [_]f64{ 24.43, 35.01, 45.32, 65.3, 60.64 };
    try testing.expect(fastestClearsFloor(main_ascii[0..], ascii_floor));
    try testing.expect(fastestClearsFloor(pr_ascii[0..], ascii_floor));
    try testing.expect(fastestClearsFloor(main_scroll[0..], scroll_floor));

    // From a 60-run experiment on 28 runners (2026-10-25, not a gate run): an
    // episode on one EPYC 7763 runner, 20 consecutive scroll runs (about 1.7 s)
    // with none above 57 MB/s on a class that otherwise gives 68.
    const episode = [_]f64{
        53.9, 50.0, 48.5, 49.9, 49.1, 40.7, 46.4, 49.9, 47.3, 37.6,
        43.2, 43.1, 55.6, 48.9, 53.4, 56.9, 56.3, 51.3, 40.4, 54.6,
    };
    try testing.expect(fastestClearsFloor(episode[0..], scroll_floor));
}

test "issue121-bench-stats a real regression still fails the floor" {
    const testing = std.testing;

    // Synthetic: the slowest runner class at half speed, every run and the
    // fastest too.
    const half_speed = [_]f64{ 33.9, 34.2, 34.0, 33.5, 34.4, 34.1, 33.8 };
    try testing.expect(!fastestClearsFloor(half_speed[0..], 50));

    // Synthetic: the slowest runner class slowed uniformly by 1.4x (the gate
    // needs about 1.34x on that class), 67.7 / 1.4 = 48.4 at the fastest.
    const slowed_1_4x = [_]f64{ 48.4, 47.9, 48.1, 46.3, 48.0, 47.5, 48.2 };
    try testing.expect(!fastestClearsFloor(slowed_1_4x[0..], 50));

    // Synthetic: Debug-linked dependencies make the benchmark 25-46x slower.
    const debug_linked = [_]f64{ 2.6, 2.7, 2.6, 2.5, 2.7 };
    try testing.expect(!fastestClearsFloor(debug_linked[0..], 50));
    try testing.expect(!fastestClearsFloor(debug_linked[0..], 3));

    // A floor is reached, not exceeded.
    const at_floor = [_]f64{ 49.99, 50.0 };
    try testing.expect(fastestClearsFloor(at_floor[0..], 50));
    const under_floor = [_]f64{ 49.98, 49.99 };
    try testing.expect(!fastestClearsFloor(under_floor[0..], 50));

    // A floor of zero disables the check, with or without samples; no samples
    // cannot clear a real floor.
    const none = [_]f64{};
    try testing.expect(fastestClearsFloor(debug_linked[0..], 0));
    try testing.expect(fastestClearsFloor(none[0..], 0));
    try testing.expect(!fastestClearsFloor(none[0..], 3));
}
