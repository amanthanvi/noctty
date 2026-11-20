//! A quiet-looking header: the test prints "Loading..." without a newline,
//! so the runner's OK lands on the same line (council round 2 on #726,
//! Opus L5).
const std = @import("std");

test "loads" {
    std.debug.print("Loading...", .{});
}
