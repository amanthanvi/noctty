const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const assert = @import("../quirks.zig").inlineAssert;
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const actionpkg = @import("action.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const Config = configpkg.Config;

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

/// The `edit-config` command opens the noctty configuration file in the
/// editor specified by the `$VISUAL` or `$EDITOR` environment variables.
///
/// IMPORTANT: This command will not reload the configuration after
/// editing. You will need to manually reload the configuration using the
/// application menu, configured keybind, or by restarting noctty. We
/// plan to auto-reload in the future, but noctty isn't capable of
/// this yet.
///
/// The filepath opened is the default user-specific configuration
/// file for noctty.
///
/// This command prefers the `$VISUAL` environment variable over `$EDITOR`,
/// if both are set. On Windows, if neither are set, the configuration file
/// will be opened with the associated editor.
pub fn run(alloc: Allocator) !u8 {
    // Implementation note (by @mitchellh): I do proper memory cleanup
    // throughout this command, even though we plan on doing `exec`.
    // I do this out of good hygiene in case we ever change this to
    // not using `exec` anymore and because this command isn't performance
    // critical where setting up the defer cleanup is a problem.

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const result = runInner(alloc, stderr);
    // Flushing *shouldn't* fail but...
    stderr.flush() catch {};
    return result;
}

fn runInner(alloc: Allocator, stderr: *std.Io.Writer) !u8 {
    // We load the configuration once because that will write our
    // default configuration files to disk. We don't use the config.
    var config = try Config.load(alloc);
    defer config.deinit();

    // Get our editor
    const get_env_: ?internal_os.GetEnvResult = env: {
        // VISUAL vs. EDITOR: https://unix.stackexchange.com/questions/4859/visual-vs-editor-what-s-the-difference
        if (try internal_os.getenv(alloc, "VISUAL")) |v| {
            if (v.value.len > 0) break :env v;
            v.deinit(alloc);
        }

        if (try internal_os.getenv(alloc, "EDITOR")) |v| {
            if (v.value.len > 0) break :env v;
            v.deinit(alloc);
        }

        break :env null;
    };
    defer if (get_env_) |v| v.deinit(alloc);
    const editor: []const u8 = if (get_env_) |v| v.value else "";

    // Find the preferred path.
    const path = try configpkg.preferredDefaultFilePath(alloc);
    defer alloc.free(path);

    if (comptime builtin.os.tag == .windows) {
        if (editor.len > 0) {
            return launchWindowsEditor(alloc, editor, path, stderr, std.process.Child.spawnAndWait);
        }

        openPathWithShell(alloc, path) catch |err| {
            try stderr.print("Failed to open the configuration in the associated editor: {s}.\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }

    // If we don't have `$EDITOR` set then we can't do anything
    // but we can still print a helpful message.
    if (editor.len == 0) {
        try stderr.print(
            \\The $EDITOR or $VISUAL environment variable is not set or is empty.
            \\This environment variable is required to edit the noctty configuration
            \\via this CLI command.
            \\
            \\Please set the environment variable to your preferred terminal
            \\text editor and try again.
            \\
            \\If you prefer to edit the configuration file another way,
            \\you can find the configuration file at the following path:
            \\
            \\
        ,
            .{},
        );

        // Output the path using the OSC8 sequence so that it is linked.
        try stderr.print(
            "\x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
            .{ path, path },
        );

        return 1;
    }

    const command = command: {
        var buffer: std.io.Writer.Allocating = .init(alloc);
        defer buffer.deinit();
        const writer = &buffer.writer;
        try writer.writeAll(editor);
        try writer.writeByte(' ');
        {
            var sh: internal_os.ShellEscapeWriter = .init(writer);
            try sh.writer.writeAll(path);
            try sh.writer.flush();
        }
        try writer.flush();
        break :command try buffer.toOwnedSliceSentinel(0);
    };
    defer alloc.free(command);

    // We require libc because we want to use std.c.environ for envp
    // and not have to build that ourselves. We can remove this
    // limitation later but Ghostty already heavily requires libc
    // so this is not a big deal.
    comptime assert(builtin.link_libc);

    const err = std.posix.execvpeZ(
        "/bin/sh",
        &.{ "/bin/sh", "-c", command },
        std.c.environ,
    );

    // If we reached this point then exec failed.
    try stderr.print(
        \\Failed to execute the editor. Error code={}.
        \\
        \\This is usually due to the executable path not existing, invalid
        \\permissions, or the shell environment not being set up
        \\correctly.
        \\
        \\Editor: {s}
        \\Path: {s}
        \\
    , .{ err, editor, path });
    return 1;
}

fn launchWindowsEditor(
    alloc: Allocator,
    editor: []const u8,
    path: []const u8,
    stderr: *std.Io.Writer,
    comptime spawn_and_wait: fn (*std.process.Child) anyerror!std.process.Child.Term,
) !u8 {
    const argv = windowsEditorArgv(alloc, editor, path) catch |err| {
        try stderr.print("Failed to parse the editor command: {s}. Check VISUAL or EDITOR.\n", .{@errorName(err)});
        return 1;
    };
    defer freeEditorArgv(alloc, argv);
    var child = std.process.Child.init(argv, alloc);
    // Inherit the caller's terminal so console editors run inline. Waiting also
    // honors explicit GUI wait flags such as `code --wait`. Zig's Child handles
    // PATHEXT and .cmd shims, with the appropriate batch-file quoting.
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = spawn_and_wait(&child) catch |err| {
        try stderr.print("Failed to execute the editor: {s}. Check VISUAL or EDITOR.\n", .{@errorName(err)});
        return 1;
    };
    switch (term) {
        .Exited => |code| {
            if (code == 0) return 0;
            try stderr.print("The editor exited with code {d}.\n", .{code});
        },
        else => try stderr.writeAll("The editor terminated before completing successfully.\n"),
    }
    return 1;
}

fn windowsEditorArgv(alloc: Allocator, editor: []const u8, path: []const u8) ![]const []const u8 {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, std.mem.trim(u8, editor, " \t"));
    defer alloc.free(wide);
    var iter = try std.process.ArgIteratorWindows.init(alloc, wide);
    defer iter.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| alloc.free(arg);
        argv.deinit(alloc);
    }
    while (iter.next()) |arg| {
        const copy = try alloc.dupe(u8, arg);
        errdefer alloc.free(copy);
        try argv.append(alloc, copy);
    }
    if (argv.items.len == 0 or argv.items[0].len == 0) return error.EmptyEditor;
    {
        const path_copy = try alloc.dupe(u8, path);
        errdefer alloc.free(path_copy);
        try argv.append(alloc, path_copy);
    }
    return argv.toOwnedSlice(alloc);
}

fn freeEditorArgv(alloc: Allocator, argv: []const []const u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

test "PKG61 editor argv preserves quoted Windows executable and arguments" {
    const alloc = std.testing.allocator;
    const path = "C:\\config folder\\config.ghostty";
    const argv = try windowsEditorArgv(alloc, "\"C:\\Program Files\\Notepad++\\notepad++.exe\" -multiInst", path);
    defer freeEditorArgv(alloc, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\Notepad++\\notepad++.exe", argv[0]);
    try std.testing.expectEqualStrings("-multiInst", argv[1]);
    try std.testing.expectEqualStrings(path, argv[2]);
}

test "PKG61 editor argv preserves backslashes empty args and literal metacharacters" {
    const alloc = std.testing.allocator;
    const argv = try windowsEditorArgv(alloc, "nvim \"\" \"C:\\a b\\\\\" \"a\\\"b\" %VALUE% & literal", "C:\\a & b\\config.ghostty");
    defer freeEditorArgv(alloc, argv);
    const expected: []const []const u8 = &.{ "nvim", "", "C:\\a b\\", "a\"b", "%VALUE%", "&", "literal", "C:\\a & b\\config.ghostty" };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, actual| try std.testing.expectEqualStrings(want, actual);
    try std.testing.expectError(error.EmptyEditor, windowsEditorArgv(alloc, " \t ", "config.ghostty"));
    try std.testing.expectError(error.EmptyEditor, windowsEditorArgv(alloc, "\"\"", "config.ghostty"));
}

test "PKG61 editor launch inherits stdio and reports failures without environment values" {
    const Fake = struct {
        fn success(child: *std.process.Child) !std.process.Child.Term {
            try std.testing.expectEqual(std.process.Child.StdIo.Inherit, child.stdin_behavior);
            try std.testing.expectEqual(std.process.Child.StdIo.Inherit, child.stdout_behavior);
            try std.testing.expectEqual(std.process.Child.StdIo.Inherit, child.stderr_behavior);
            try std.testing.expectEqual(@as(usize, 3), child.argv.len);
            try std.testing.expectEqualStrings("stand-in.exe", child.argv[0]);
            try std.testing.expectEqualStrings("--wait", child.argv[1]);
            try std.testing.expectEqualStrings("C:\\config folder\\config.ghostty", child.argv[2]);
            return .{ .Exited = 0 };
        }
        fn failedExit(_: *std.process.Child) !std.process.Child.Term {
            return .{ .Exited = 7 };
        }
        fn failedSpawn(_: *std.process.Child) !std.process.Child.Term {
            return error.FileNotFound;
        }
    };
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(u8, 0), try launchWindowsEditor(alloc, "stand-in.exe --wait", "C:\\config folder\\config.ghostty", &writer, Fake.success));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expectEqual(@as(u8, 1), try launchWindowsEditor(alloc, "stand-in.exe --secret=sentinel", "secret-path", &writer, Fake.failedExit));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "code 7") != null);
    try std.testing.expectEqual(@as(u8, 1), try launchWindowsEditor(alloc, "stand-in.exe --secret=sentinel", "secret-path", &writer, Fake.failedSpawn));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "FileNotFound") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "sentinel") == null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "secret-path") == null);
}

fn openPathWithShell(
    alloc: Allocator,
    path: []const u8,
) !void {
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const verb_w = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const result = ShellExecuteW(
        null,
        verb_w.ptr,
        path_w.ptr,
        null,
        null,
        1,
    );
    if (@intFromPtr(result) <= 32) return error.OpenConfigFailed;
}

extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?windows.LPCWSTR,
    lpFile: ?windows.LPCWSTR,
    lpParameters: ?windows.LPCWSTR,
    lpDirectory: ?windows.LPCWSTR,
    nShowCmd: windows.INT,
) callconv(.winapi) ?windows.HINSTANCE;
