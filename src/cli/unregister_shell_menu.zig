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

/// Remove the current user's `Open koreterm here` classic Explorer verbs for
/// folders, folder backgrounds, and drives.
///
/// The action removes only koreterm's six owned keys under
/// `HKCU\Software\Classes` and succeeds when they are already absent. The
/// installer's all-users entries (HKLM) are not its to remove, so when they
/// exist it says they remain.
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
    return report(stdout, stderr, results, shell_menu.machineVerbsPresent(alloc));
}

fn report(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    results: [shell_menu.unregister_key_paths.len]shell_menu.DeleteResult,
    machine_verbs: bool,
) !u8 {
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
                        "  Status 5 here can also mean the key contains subkeys koreterm did not create; unregister never deletes those. Inspect the key and remove them first.\n",
                        .{},
                    );
                }
            },
        }
    }
    // The installer registers the same entries for all users, and "Already
    // absent" above is about this user's only.
    if (machine_verbs) {
        try stdout.writeAll(
            "Note: the koreterm installer also registered \"Open koreterm here\" for all users (HKLM\\Software\\Classes). " ++
                "This action removes only the current user's entries and cannot remove those; uninstalling koreterm does.\n",
        );
    }
    return if (failed) 1 else 0;
}

test "unregister reports the installer's all-users entries that it cannot remove" {
    var out_buf: [2048]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    const absent: [shell_menu.unregister_key_paths.len]shell_menu.DeleteResult = @splat(.absent);

    // Nothing of this user's was there, and the all-users entries are: the
    // "Already absent" lines alone would read as the menu being gone.
    try std.testing.expectEqual(@as(u8, 0), try report(&out, &err, absent, true));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Already absent HKCU\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "for all users (HKLM") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "uninstalling koreterm does") != null);

    out = .fixed(&out_buf);
    try std.testing.expectEqual(@as(u8, 0), try report(&out, &err, absent, false));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "HKLM") == null);

    // A failure still exits 1, and the note still comes out.
    var failed = absent;
    failed[0] = .{ .failed = ERROR_ACCESS_DENIED };
    out = .fixed(&out_buf);
    try std.testing.expectEqual(@as(u8, 1), try report(&out, &err, failed, true));
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "Win32 status 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "for all users (HKLM") != null);
}
