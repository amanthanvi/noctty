//! One monotonic clock for render pacing and the renderer's wake-notify
//! stamp: QueryPerformanceCounter on Windows. GetTickCount64 advances in
//! 15.6 ms steps, too coarse to measure a 34 ms present interval with, and
//! the wall clock steps.

const std = @import("std");
const builtin = @import("builtin");

/// Monotonic nanoseconds from an arbitrary start.
pub fn nowNs() u64 {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        return nsFromCounter(windows.QueryPerformanceCounter(), windows.QueryPerformanceFrequency());
    }
    const ts = (std.time.Instant.now() catch return 0).timestamp;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// A performance counter reading in nanoseconds.
fn nsFromCounter(counter: u64, frequency: u64) u64 {
    return @intCast(@as(u128, counter) * std.time.ns_per_s / frequency);
}

test "nsFromCounter keeps whole-millisecond QPC precision and does not overflow at 2^56 counts" {
    // Whole milliseconds equal counter * 1000 / frequency (the u128 math
    // must not wrap).
    const cases = [_][2]u64{
        .{ 0, 10_000_000 },
        .{ 1, 10_000_000 },
        .{ 9_999, 10_000_000 },
        .{ 123_456_789_012, 10_000_000 },
        .{ 987_654_321, 3_579_545 },
        .{ 3_579_544, 3_579_545 },
        .{ 1 << 56, 10_000_000 },
        .{ (1 << 55) + 12_345, 2_433_331 },
    };
    for (cases) |case| {
        const counter, const frequency = case;
        const ms_reference: u64 = @intCast(@as(u128, counter) * std.time.ms_per_s / frequency);
        try std.testing.expectEqual(ms_reference, nsFromCounter(counter, frequency) / std.time.ns_per_ms);
    }
}
