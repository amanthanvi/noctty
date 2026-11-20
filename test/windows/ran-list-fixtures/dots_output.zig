//! A test whose output starts on the runner's header line and holds "...":
//! its name cannot be told from its output, so the capture refuses the log.
const std = @import("std");

test "loads" {
    std.debug.print("Loading...\n", .{});
}
