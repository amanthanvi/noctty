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
    _ = entrypoint;
}
