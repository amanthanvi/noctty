//! The main entrypoint for the `ghostty` application.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const build_config = @import("build_config.zig");
const apprt = @import("apprt.zig");
const process_shared = @import("process_shared.zig");

const App = @import("App.zig");
const state = &@import("global.zig").state;

/// The return type for main() depends on the build artifact. The retained
/// non-app artifacts can still call "main" in order to run CLI actions,
/// but they do not provide the native Win32 application entrypoint.
const MainReturn = switch (build_config.artifact) {
    .lib => noreturn,
    else => void,
};

pub fn main() !MainReturn {
    const dll_search_error = if (comptime builtin.target.os.tag == .windows and
        build_config.artifact == .exe and
        build_config.app_runtime == .win32)
        apprt.win32.setDefaultDllDirectories()
    else
        null;

    if (comptime builtin.target.os.tag == .windows and
        build_config.artifact == .exe and
        build_config.app_runtime == .win32)
    {
        apprt.win32.captureProcessOrigin();
    }

    // We first start by initializing our global process state.
    state.init() catch |err| {
        defer posix.exit(1);
        try process_shared.reportStateInitError(err);
    };
    defer state.deinit();
    const alloc = state.alloc;

    if (dll_search_error) |err| {
        std.log.warn(
            "failed to restrict default DLL search directories win32_error={d}",
            .{@intFromEnum(err)},
        );
    }

    if (comptime builtin.mode == .Debug) {
        std.log.warn("This is a debug build. Performance will be very poor.", .{});
        std.log.warn("You should only use a debug build for developing noctty.", .{});
        std.log.warn("Otherwise, please rebuild in a release mode.", .{});
    }

    // Execute our action if we have one
    if (state.action) |action| {
        std.log.info("executing noctty CLI action={}", .{action});
        posix.exit(process_shared.runCliAction(action, alloc));
    }

    // Create our app state
    const app: *App = try App.create(alloc);
    defer app.destroy();

    // Create our runtime app
    var app_runtime: apprt.App = undefined;
    if (comptime builtin.target.os.tag == .windows and
        build_config.artifact == .exe and
        build_config.app_runtime == .win32)
    {
        var loader_dialogs = apprt.win32.suppressStartupLoaderErrorDialogs();
        defer loader_dialogs.restore();
        try app_runtime.init(app, .{ .safe_mode = state.safe_mode });
    } else {
        try app_runtime.init(app, .{});
    }
    defer app_runtime.terminate();

    // Run the GUI event loop
    try app_runtime.run();
}

pub export fn WinMain(
    _: ?*anyopaque,
    _: ?*anyopaque,
    _: ?[*:0]u8,
    _: c_int,
) callconv(.winapi) c_int {
    if (comptime builtin.target.os.tag != .windows) {
        return 1;
    }

    main() catch |err| {
        std.log.err("WinMain failed error={}", .{err});
        apprt.win32.reportStartupFailure(err);
        return 1;
    };
    return 0;
}

pub const std_options: std.Options = process_shared.std_options;

test {
    _ = @import("pty.zig");
    _ = @import("Command.zig");
    // Not part of the app; rooted here only so the spike's hermetic
    // accept/select tests run with the suite.
    _ = @import("conpty_host.zig");
    _ = @import("font/main.zig");
    _ = @import("apprt.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");
    _ = @import("cli.zig");
    _ = @import("surface_mouse.zig");

    // Libraries
    _ = @import("tripwire.zig");
    _ = @import("benchmark/main.zig");
    _ = @import("bench/palette_match.zig");
    _ = @import("crash/main.zig");
    _ = @import("datastruct/main.zig");
    _ = @import("inspector/main.zig");
    _ = @import("lib/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("terminfo/main.zig");
    _ = @import("simd/main.zig");
    _ = @import("synthetic/main.zig");
    _ = @import("unicode/main.zig");
    _ = @import("unicode/props_uucode.zig");
    _ = @import("unicode/symbols_uucode.zig");

    // Extra
    _ = @import("extra/bash.zig");
    _ = @import("extra/fish.zig");
    _ = @import("extra/sublime.zig");
    _ = @import("extra/vim.zig");
    _ = @import("extra/zsh.zig");
}
