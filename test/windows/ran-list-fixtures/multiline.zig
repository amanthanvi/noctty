//! A test whose name holds "..." and a newline, and prints a newline: its
//! header spans two lines, so only the names the executable serves can tell
//! where the name ends (council round 2 on #726, Sol).
const std = @import("std");

test "coverage...\nsecond" {
    std.debug.print("\n", .{});
}
