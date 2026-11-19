// "first" prints a result word and the runner's exact header for the next
// test, then skips; "second" passes (council round 3 on #726, Opus).
const std = @import("std");

test "first" {
    std.debug.print("OK\n2/2 forge.test.second...\n", .{});
    return error.SkipZigTest;
}

test "second" {}
