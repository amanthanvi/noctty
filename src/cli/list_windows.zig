const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const apprt = @import("../apprt.zig");
const args = @import("args.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, query a custom single-instance namespace instead of the
    /// default local winghostty instance.
    class: ?[:0]const u8 = null,

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
/// matching local winghostty instance as JSON.
///
/// The current schema exposes only stable host/tab/pane identifiers, focus
/// state, active-pane state, and structural counts. It does not expose
/// terminal text, shell input, working directories, or any write/control
/// actions.
///
/// Flags:
///
///   * `--class=<class>`: Query a custom instance namespace instead of the
///     default local winghostty instance.
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
    try args.parse(Options, alloc, &opts, args_iter);

    const payload = queryAutomationWindowListFn(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
    ) catch |err| switch (err) {
        error.IPCFailed => {
            try stderr.print("Listing automation windows via IPC failed.\n", .{});
            return 1;
        },
        error.InvalidIpcResponse => {
            try stderr.print("Listing automation windows via IPC failed: invalid response from the target instance.\n", .{});
            return 1;
        },
        else => return err,
    };
    defer if (payload) |bytes| alloc.free(bytes);

    const json = payload orelse {
        try stderr.print("No matching winghostty instance is listening for automation queries.\n", .{});
        return 1;
    };

    try stdout.writeAll(json);
    try stdout.writeByte('\n');
    return 0;
}

fn queryAutomationWindowList(
    alloc: Allocator,
    target: apprt.ipc.Target,
) !?[]u8 {
    return try apprt.App.queryAutomationWindowList(alloc, target);
}

test "automation-window-list cli prints json payload" {
    const testing = std.testing;

    const Hook = struct {
        var seen_class: ?[]u8 = null;

        fn query(alloc: Allocator, target: apprt.ipc.Target) !?[]u8 {
            seen_class = switch (target) {
                .class => |class| try testing.allocator.dupe(u8, class),
                .detect => return error.UnexpectedTarget,
            };
            return try alloc.dupe(u8, "{\"schema\":\"winghostty.windows.v2\",\"api_version\":2,\"windows\":[]}");
        }
    };
    defer if (Hook.seen_class) |value| testing.allocator.free(value);

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--class=lane9",
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
        "{\"schema\":\"winghostty.windows.v2\",\"api_version\":2,\"windows\":[]}\n",
        stdout_buf.written(),
    );
    try testing.expectEqualStrings("", stderr_buf.written());
    try testing.expect(Hook.seen_class != null);
    try testing.expectEqualStrings("lane9", Hook.seen_class.?);
}

test "automation-window-list cli reports ipc failure" {
    const testing = std.testing;

    const Hook = struct {
        fn query(_: Allocator, _: apprt.ipc.Target) !?[]u8 {
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

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_buf.written());
    try testing.expectEqualStrings(
        "Listing automation windows via IPC failed.\n",
        stderr_buf.written(),
    );
}

test "automation-window-list cli reports invalid ipc response" {
    const testing = std.testing;

    const Hook = struct {
        fn query(_: Allocator, _: apprt.ipc.Target) !?[]u8 {
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

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_buf.written());
    try testing.expectEqualStrings(
        "Listing automation windows via IPC failed: invalid response from the target instance.\n",
        stderr_buf.written(),
    );
}

test "automation-window-list cli reports missing instance" {
    const testing = std.testing;

    const Hook = struct {
        fn query(_: Allocator, target: apprt.ipc.Target) !?[]u8 {
            try testing.expectEqual(apprt.ipc.Target.detect, target);
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

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings("", stdout_buf.written());
    try testing.expectEqualStrings(
        "No matching winghostty instance is listening for automation queries.\n",
        stderr_buf.written(),
    );
}
