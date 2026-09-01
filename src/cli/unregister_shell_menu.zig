const std = @import("std");
const Allocator = std.mem.Allocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const shell_menu = @import("../apprt.zig").win32_shell_menu;

const ERROR_ACCESS_DENIED: i32 = 5;

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

/// Remove the current user's `Open noctty here` classic Explorer verbs for
/// folders, folder backgrounds, and drives.
///
/// The action removes only noctty's six owned keys under
/// `HKCU\Software\Classes` and succeeds when they are already absent.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const result = runInner(alloc, stdout, stderr);
    try stdout.flush();
    try stderr.flush();
    return result;
}

fn runInner(
    alloc: Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const results = shell_menu.unregister(alloc) catch |err| {
        try stderr.print(
            "Failed to unregister Explorer shell menu ({s}).\n",
            .{@errorName(err)},
        );
        return 1;
    };

    var failed = false;
    for (shell_menu.unregister_key_paths, results) |path, result| {
        switch (result) {
            .removed => try stdout.print("Removed HKCU\\{s}\n", .{path}),
            .absent => try stdout.print("Already absent HKCU\\{s}\n", .{path}),
            .failed => |status| {
                failed = true;
                try stderr.print(
                    "Failed to unregister Explorer shell menu at HKCU\\{s} during delete_key (Win32 status {d}).\n",
                    .{ path, status },
                );
                // The delete is deliberately non-recursive so foreign subkeys
                // survive, which means a key someone else extended reports the
                // same status as a policy denial. Say so, because the register
                // action teaches that 5 means policy or a restricted token.
                if (status == ERROR_ACCESS_DENIED) {
                    try stderr.print(
                        "  Status 5 here can also mean the key contains subkeys noctty did not create; unregister never deletes those. Inspect the key and remove them first.\n",
                        .{},
                    );
                }
            },
        }
    }
    return if (failed) 1 else 0;
}
