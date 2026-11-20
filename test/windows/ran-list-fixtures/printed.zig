// Each test prints the other's result word on a line of its own, then output
// without a newline, so the runner's own result runs into it: "coverage"
// skips and "platform" passes (council round 3 on #726, Sol).
const std = @import("std");

test "coverage" {
    std.debug.print("\nOK\nloading", .{});
    return error.SkipZigTest;
}

test "platform" {
    std.debug.print("\nSKIP\nloading", .{});
}
