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

/// Register `Open noctty here` in the current user's classic Explorer
/// context menus for folders, folder backgrounds, and drives.
///
/// The action writes only to `HKCU\Software\Classes`. It is idempotent and
/// points every verb at the `noctty.exe` next to the current launcher.
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
    const self_path = std.fs.selfExePathAlloc(alloc) catch |err| {
        try stderr.print(
            "Failed to register Explorer shell menu: executable path unavailable ({s}).\n",
            .{@errorName(err)},
        );
        return 1;
    };
    defer alloc.free(self_path);

    const exe_path = shell_menu.executablePathAlloc(alloc, self_path) catch |err| {
        try stderr.print(
            "Failed to register Explorer shell menu: noctty.exe path unavailable ({s}).\n",
            .{@errorName(err)},
        );
        return 1;
    };
    defer alloc.free(exe_path);

    std.fs.accessAbsolute(exe_path, .{}) catch |err| {
        try stderr.print(
            "Failed to register Explorer shell menu: GUI executable not found at {s} ({s}).\n",
            .{ exe_path, @errorName(err) },
        );
        return 1;
    };

    const registration = shell_menu.register(alloc, exe_path) catch |err| {
        try stderr.print(
            "Failed to register Explorer shell menu ({s}).\n",
            .{@errorName(err)},
        );
        return 1;
    };

    switch (registration) {
        .success => {
            for (shell_menu.register_key_paths) |path| {
                try stdout.print("Registered HKCU\\{s}\n", .{path});
            }
            return 0;
        },
        .failure => |failure| {
            try writeRegistryFailure(stderr, failure);
            // Earlier verbs may already be registered; tell the user how to
            // get back to a clean state rather than leaving a half-installed
            // Explorer menu behind silently.
            try stderr.print(
                "Some verbs may already be registered; run `noctty +unregister-shell-menu` to remove them.\n",
                .{},
            );
            return 1;
        },
    }
}

fn writeRegistryFailure(
    stderr: *std.Io.Writer,
    failure: shell_menu.RegistryFailure,
) !void {
    if (failure.operation == .create_key and failure.status == ERROR_ACCESS_DENIED) {
        try stderr.print(
            "Failed to register Explorer shell menu at HKCU\\{s} during create_key: access denied; per-user registry writes may be blocked by policy or the process may have a restricted token (Win32 status 5).\n",
            .{failure.key_path},
        );
        return;
    }

    try stderr.print(
        "Failed to register Explorer shell menu at HKCU\\{s} during {s} (Win32 status {d}).\n",
        .{ failure.key_path, @tagName(failure.operation), failure.status },
    );
}

test "shell-menu access denied explains per-user policy causes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeRegistryFailure(&output.writer, .{
        .operation = .create_key,
        .key_path = "Software\\Classes\\Directory\\shell\\noctty",
        .status = ERROR_ACCESS_DENIED,
    });

    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "per-user registry writes may be blocked by policy",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.written(),
        "restricted token",
    ) != null);
}
