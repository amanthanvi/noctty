//! A test that logs at error level still reports OK; the runner reports the
//! error count after its closing line and exits 1.
const std = @import("std");

test "logs an error" {
    std.log.err("fixture error line", .{});
}

test "fine" {}
