const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const apprt = @import("../apprt.zig");
const args = @import("args.zig");

const Format = enum { json };

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, query a custom single-instance namespace instead of the
    /// default local noctty instance.
    class: ?[:0]const u8 = null,

    /// How long to wait for the running instance to respond.
    timeout: u64 = 10_000,

    /// The stable output format. JSON is the only supported value.
    format: Format = .json,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

/// The `list-windows` command prints a read-only automation snapshot for the
/// matching local noctty instance as JSON.
///
/// The current schema exposes instance metadata, stable host/tab/pane
/// identifiers, titles, last-known working directories, focus state,
/// active-pane state, and structural counts. It never exposes terminal text,
/// scrollback, selection, clipboard data, or pending shell input.
///
/// Flags:
///
///   * `--class=<class>`: Query a custom instance namespace instead of the
///     default local noctty instance.
///
///   * `--timeout=<ms>`: Response timeout in milliseconds, from 0 through
///     10000. The default is 10000.
///
///   * `--format=json`: Select the stable JSON output contract. JSON is the
///     default and only supported format.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stdout, stderr);
    try stdout.flush();
    try stderr.flush();
    return result;
}

fn runArgs(
    alloc: Allocator,
    args_iter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    return runArgsWithQuery(
        alloc,
        args_iter,
        stdout,
        stderr,
        queryAutomationWindowList,
    );
}

const QueryAutomationWindowListFn = *const fn (
    alloc: Allocator,
    target: apprt.ipc.Target,
    timeout_ms: u64,
) anyerror!?[]u8;

fn runArgsWithQuery(
    alloc: Allocator,
    args_iter: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    queryAutomationWindowListFn: QueryAutomationWindowListFn,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    args.parse(Options, alloc, &opts, args_iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing +list-windows arguments: {}\n", .{err});
            return 1;
        },
    };
    if (opts.timeout > 10_000) {
        try stderr.print("--timeout must be between 0 and 10000 milliseconds.\n", .{});
        return 1;
    }

    const payload = queryAutomationWindowListFn(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        opts.timeout,
    ) catch |err| {
        try stderr.print("Listing automation windows via IPC failed: {}\n", .{err});
        return 5;
    };
    defer if (payload) |bytes| alloc.free(bytes);

    const json = payload orelse {
        try stderr.print("No matching noctty instance is listening for automation queries.\n", .{});
        return 2;
    };

    try stdout.writeAll(json);
    try stdout.writeByte('\n');
    return 0;
}

fn queryAutomationWindowList(
    alloc: Allocator,
    target: apprt.ipc.Target,
    timeout_ms: u64,
) !?[]u8 {
    return try apprt.App.queryAutomationWindowList(alloc, target, timeout_ms);
}

test "automation-window-list cli prints json payload" {
    const testing = std.testing;

    const Hook = struct {
        var seen_class: ?[]u8 = null;

        fn query(alloc: Allocator, target: apprt.ipc.Target, timeout_ms: u64) !?[]u8 {
            try testing.expectEqual(@as(u64, 42), timeout_ms);
            seen_class = switch (target) {
                .class => |class| try testing.allocator.dupe(u8, class),
                .detect => return error.UnexpectedTarget,
            };
            return try alloc.dupe(u8, "{\"schema\":\"noctty.windows.v3\",\"api_version\":3,\"instance\":{\"pid\":1,\"version\":\"test\",\"class\":\"lane9\"},\"windows\":[]}");
        }
    };
    defer if (Hook.seen_class) |value| testing.allocator.free(value);

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--class=lane9 --timeout=42 --format=json",
    );
    defer iter.deinit();

    var stdout_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithQuery(
        testing.allocator,
        &iter,
        &stdout_buf.writer,
        &stderr_buf.writer,
        &Hook.query,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings(
        "{\"schema\":\"noctty.windows.v3\",\"api_version\":3,\"instance\":{\"pid\":1,\"version\":\"test\",\"class\":\"lane9\"},\"windows\":[]}\n",
        stdout_buf.written(),
    );
    try testing.expectEqualStrings("", stderr_buf.written());
    try testing.expect(Hook.seen_class != null);
    try testing.expectEqualStrings("lane9", Hook.seen_class.?);
}

test "automation-window-list cli reports ipc failure" {
    const testing = std.testing;

    const Hook = struct {
        fn query(_: Allocator, _: apprt.ipc.Target, _: u64) !?[]u8 {
            return error.IPCFailed;
        }
    };

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "",
    );
    defer iter.deinit();

    var stdout_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithQuery(
        testing.allocator,
        &iter,
        &stdout_buf.writer,
        &stderr_buf.writer,
        &Hook.query,
    );

    try testing.expectEqual(@as(u8, 5), exit_code);
    try testing.expectEqualStrings("", stdout_buf.written());
    try testing.expect(std.mem.startsWith(u8, stderr_buf.written(), "Listing automation windows via IPC failed:"));
}

test "automation-window-list cli reports invalid ipc response" {
    const testing = std.testing;

    const Hook = struct {
        fn query(_: Allocator, _: apprt.ipc.Target, _: u64) !?[]u8 {
            return error.InvalidIpcResponse;
        }
    };

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "",
    );
    defer iter.deinit();

    var stdout_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithQuery(
        testing.allocator,
        &iter,
        &stdout_buf.writer,
        &stderr_buf.writer,
        &Hook.query,
    );

    try testing.expectEqual(@as(u8, 5), exit_code);
    try testing.expectEqualStrings("", stdout_buf.written());
    try testing.expect(std.mem.startsWith(u8, stderr_buf.written(), "Listing automation windows via IPC failed:"));
}

test "automation-window-list cli reports missing instance" {
    const testing = std.testing;

    const Hook = struct {
        fn query(_: Allocator, target: apprt.ipc.Target, timeout_ms: u64) !?[]u8 {
            try testing.expectEqual(apprt.ipc.Target.detect, target);
            try testing.expectEqual(@as(u64, 10_000), timeout_ms);
            return null;
        }
    };

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "",
    );
    defer iter.deinit();

    var stdout_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithQuery(
        testing.allocator,
        &iter,
        &stdout_buf.writer,
        &stderr_buf.writer,
        &Hook.query,
    );

    try testing.expectEqual(@as(u8, 2), exit_code);
    try testing.expectEqualStrings("", stdout_buf.written());
    try testing.expectEqualStrings(
        "No matching noctty instance is listening for automation queries.\n",
        stderr_buf.written(),
    );
}

test "automation-window-list cli rejects invalid arguments before ipc" {
    const testing = std.testing;

    const Hook = struct {
        var called = false;

        fn query(_: Allocator, _: apprt.ipc.Target, _: u64) !?[]u8 {
            called = true;
            return null;
        }
    };

    for ([_][]const u8{
        "--format=text",
        "--timeout=10001",
        "--timeout=18446744073709551616",
        "unexpected",
    }) |command_line| {
        Hook.called = false;
        var iter = try std.process.ArgIteratorGeneral(.{}).init(testing.allocator, command_line);
        defer iter.deinit();

        var stdout_buf = std.Io.Writer.Allocating.init(testing.allocator);
        defer stdout_buf.deinit();
        var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
        defer stderr_buf.deinit();

        try testing.expectEqual(@as(u8, 1), try runArgsWithQuery(
            testing.allocator,
            &iter,
            &stdout_buf.writer,
            &stderr_buf.writer,
            &Hook.query,
        ));
        try testing.expect(!Hook.called);
        try testing.expectEqualStrings("", stdout_buf.written());
    }
}
