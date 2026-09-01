const std = @import("std");
const args = @import("args.zig");
const actionpkg = @import("action.zig");
const handoff = @import("../apprt/win32_terminal_handoff.zig");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

/// Register noctty as the current user's default terminal. A compatible
/// Windows Terminal/OpenConsole console delegation must already be selected.
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;
    const exe_path = handoff.currentNocttyExePath(alloc) catch |err| {
        try stderr.print("Could not resolve the sibling noctty.exe path: {}\n", .{err});
        try stderr.flush();
        return 1;
    };
    defer alloc.free(exe_path);

    const result = handoff.registerDefaultTerminal(alloc, exe_path) catch |err| {
        switch (err) {
            error.CompatibleConsoleHandoffMissing => try stderr.writeAll(
                "Cannot register noctty as the default terminal: HKCU\\Console\\%%Startup\\DelegationConsole is missing or selects the inbox console host. Select Windows Terminal 1.24 or newer as your default terminal first, so its OpenConsole provides the console half of the handoff.\n",
            ),
            error.InvalidConsoleHandoff => try stderr.writeAll(
                "Cannot register noctty as the default terminal: DelegationConsole is not a valid CLSID.\n",
            ),
            error.MissingRestoreState => try stderr.writeAll(
                "Cannot repair the current noctty selection because its saved previous terminal value is missing; no registry values were changed.\n",
            ),
            error.MissingProxyRestoreState => try stderr.writeAll(
                "Cannot repair noctty's terminal proxy registration because a shared Interface value already points to noctty but its saved previous value is missing; no shared Interface values were changed.\n",
            ),
            error.ProxyDllMissing => try stderr.print(
                "Cannot register noctty as the default terminal: {s} is missing or unreadable. Reinstall noctty so the proxy DLL is beside noctty.exe.\n",
                .{handoff.proxy_filename},
            ),
            else => try stderr.print("Default-terminal registration failed: {}\n", .{err}),
        }
        try stderr.flush();
        return 1;
    };

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    if (result.selection_changed) {
        try stdout.print("Registered and selected noctty as the current user's default terminal: {s}\n", .{exe_path});
    } else {
        try stdout.print("noctty was already selected; refreshed its current-user COM registration: {s}\n", .{exe_path});
    }
    try stdout.flush();
    return 0;
}
