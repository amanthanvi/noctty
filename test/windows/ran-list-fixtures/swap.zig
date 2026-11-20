//! Each test prints the other's result word before returning its own, so a
//! parser that takes the first result-shaped line swaps them (council round 1
//! on #726, Sol). The capture must refuse this log as ambiguous.
const std = @import("std");

test "coverage" {
    std.debug.print("OK\n", .{});
    return error.SkipZigTest;
}

test "platform" {
    std.debug.print("SKIP\n", .{});
}
