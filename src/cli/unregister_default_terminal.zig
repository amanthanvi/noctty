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

/// Remove noctty's current-user COM registration and restore the terminal
/// selection saved by `+register-default-terminal` when noctty is still active.
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;
    // The exit code carries the result. The uninstaller runs this from a
    // process with no console, where every write fails, and a failed write
    // must not turn a finished unregistration into an error dialog.
    const result = handoff.unregisterDefaultTerminal(alloc) catch |err| {
        if (err == error.MissingRestoreState) {
            stderr.writeAll(
                "Cannot unregister noctty while it is selected: the saved previous terminal value is missing, so the registry was left unchanged.\n",
            ) catch {};
        } else if (err == error.MissingProxyRestoreState) {
            stderr.writeAll(
                "Cannot unregister noctty safely: a shared Interface value still points to noctty but its saved previous value is missing, so the registry was left unchanged.\n",
            ) catch {};
        } else {
            stderr.print("Default-terminal unregistration failed: {}\n", .{err}) catch {};
        }
        stderr.flush() catch {};
        return 1;
    };

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    if (result.selection_restored) {
        stdout.writeAll("Restored the default-terminal selection saved before noctty was registered.\n") catch {};
    } else if (result.newer_selection_preserved) {
        stdout.writeAll("A different default terminal is selected; preserved it and removed noctty's COM registration.\n") catch {};
    } else if (result.class_removed) {
        stdout.writeAll("Removed noctty's COM registration; no terminal selection needed restoration.\n") catch {};
    } else {
        stdout.writeAll("noctty was already unregistered; no registry values changed.\n") catch {};
    }
    stdout.flush() catch {};
    return 0;
}
