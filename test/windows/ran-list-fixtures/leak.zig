//! A test that leaks still reports OK; the runner reports the leak only
//! after its closing line and exits 1.
const std = @import("std");

test "leaks one byte" {
    _ = try std.testing.allocator.alloc(u8, 1);
}

test "fine" {}
