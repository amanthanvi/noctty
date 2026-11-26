const std = @import("std");
const build_config = @import("build_config.zig");

/// See build_config.ExeEntrypoint for why we do this.
const entrypoint = switch (build_config.exe_entrypoint) {
    .ghostty => @import("main_ghostty.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_ghostty_1 => @import("build/mdgen/main_ghostty_1.zig"),
    .mdgen_ghostty_5 => @import("build/mdgen/main_ghostty_5.zig"),
    .webgen_config => @import("build/webgen/main_config.zig"),
    .webgen_actions => @import("build/webgen/main_actions.zig"),
    .webgen_commands => @import("build/webgen/main_commands.zig"),
};

/// The main entrypoint for the program.
pub const main = entrypoint.main;

/// Standard options such as logger overrides.
pub const std_options: std.Options = if (@hasDecl(entrypoint, "std_options"))
    entrypoint.std_options
else
    .{};

comptime {
    // Force-reference our memset override so its export is emitted.
    // See quirks_memset.zig for details on why this exists.
    _ = @import("quirks_memset.zig");
}

/// noctty.exe's panic handler (see process_shared.panic). The other
/// entrypoints are build-time tools and keep Zig's default.
pub const panic = if (build_config.exe_entrypoint == .ghostty)
    @import("process_shared.zig").panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

// The thread-role layer's isolated-child dispatch (sync/isolated.zig), which
// must be the executable's first test: builtin.test_functions lists this root
// file's tests first, in declaration order, so this one runs before any other
// in a child the test exe starts, and as an unnamed test it survives every
// -Dtest-filter, so a filtered child still dispatches instead of running its
// parent's test again. Keep every other test below it.
test {
    if (build_config.exe_entrypoint == .ghostty) {
        @import("sync/isolated.zig").runChildIfRequested();
    }
}

// This only verifies the early child-mode hook; transport is covered by the
// opt-in parent probe in pty_transport_probe.zig.
test "ConPTY transport probe child dispatch only" {
    if (build_config.exe_entrypoint == .ghostty) {
        const probe = @import("pty_transport_probe.zig");
        probe.runChildIfRequested();
        try probe.runParentIfRequested();
    }
}

// -Dtest-filter keeps a named test only if its fully qualified name (file
// path, ".test.", then the test name) contains a token, and what only a
// dropped test referenced is never analysed. An unnamed test is exempt, so
// this one keeps the tree reachable and a filtered run executes the tests
// that match instead of none. pty_transport_probe.zig stays reachable only
// through the named test above, so its two probe tests run only when the
// filter also matches that one (use ConPTY).
test {
    // Zig 0.16.0 has made test logging more strict. Now, *anything* that gets
    // printed to stderr results in a "failed command" message, even if the
    // tests ultimately passed. To reduce confusion here (and honestly, test
    // log spam in general), we bump the default testing log level to error.
    std.testing.log_level = std.log.Level.err;
    _ = entrypoint;
    _ = @import("quirks_memset.zig");
}
