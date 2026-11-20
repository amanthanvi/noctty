//! Names the parser and the compare have to keep apart: a quiet test whose
//! name holds "...", named tests called test_0 and test_1, unnamed blocks
//! (named <file>.test_<n> by Zig), and a test in a nested container.
const std = @import("std");

test "wait...done" {}

test "test_0" {}

test "test_1" {}

test {
    _ = Inner;
}

test {}

const Inner = struct {
    test "nested" {}

    test {}
};
