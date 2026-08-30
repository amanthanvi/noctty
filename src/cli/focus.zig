const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const apprt = @import("../apprt.zig");
const args = @import("args.zig");

pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    /// Select a custom single-instance namespace.
    class: ?[:0]const u8 = null,
    /// Response timeout in milliseconds, from 0 through 10000.
    timeout: u64 = 10_000,
    /// Nonzero pane ID from `+list-windows`.
    @"surface-id": ?u64 = null,
    /// Nonzero window ID from `+list-windows`.
    @"window-id": ?u32 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
    pub fn help(_: Options) !void {
        return actionpkg.help_error;
    }
};

/// Select a window or pane in a running local noctty instance. Exactly one of
/// `--surface-id=<id>` or `--window-id=<id>` is required. `--class=<class>`
/// selects an instance namespace and `--timeout=<ms>` sets the 0..10000 ms
/// response timeout (default 10000). Foreground activation is best-effort.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    var buf: [1024]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const result = runArgs(alloc, &iter, &writer.interface);
    try writer.interface.flush();
    return result;
}

fn runArgs(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer) !u8 {
    return runArgsWithFocus(alloc, iter, stderr, focusAutomationTarget);
}

const FocusFn = *const fn (Allocator, apprt.ipc.Target, apprt.ipc.AutomationTarget, u64) anyerror!bool;

fn report(stderr: *std.Io.Writer, code: u8, message: []const u8) !u8 {
    try stderr.writeAll(message);
    return code;
}

fn runArgsWithFocus(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer, hook: FocusFn) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    args.parse(Options, alloc, &opts, iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => return report(stderr, 1, "Invalid +focus arguments.\n"),
    };
    if (opts.timeout > 10_000) return report(stderr, 1, "Invalid --timeout.\n");
    const target: apprt.ipc.AutomationTarget = if (opts.@"surface-id") |id| target: {
        if (id == 0 or opts.@"window-id" != null) return report(stderr, 1, "+focus requires exactly one nonzero target.\n");
        break :target .{ .surface_id = id };
    } else if (opts.@"window-id") |id| target: {
        if (id == 0) return report(stderr, 1, "+focus requires exactly one nonzero target.\n");
        break :target .{ .window_id = id };
    } else return report(stderr, 1, "+focus requires exactly one nonzero target.\n");

    const ok = hook(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        target,
        opts.timeout,
    ) catch |err| switch (err) {
        error.InvalidAutomationTarget => return report(stderr, 1, "Invalid automation target.\n"),
        error.AutomationTargetNotFound, error.NoAutomationTarget => return report(stderr, 3, "Automation target not found.\n"),
        else => return report(stderr, 5, "Automation focus IPC failed.\n"),
    };
    return if (ok) 0 else report(stderr, 2, "No matching noctty instance.\n");
}

fn focusAutomationTarget(alloc: Allocator, instance: apprt.ipc.Target, target: apprt.ipc.AutomationTarget, timeout: u64) !bool {
    return apprt.App.focusAutomationTarget(alloc, instance, target, timeout);
}

fn testRun(line: []const u8, hook: FocusFn) !u8 {
    var iter = try std.process.ArgIteratorGeneral(.{}).init(std.testing.allocator, line);
    defer iter.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    return runArgsWithFocus(std.testing.allocator, &iter, &stderr.writer, hook);
}

test "automation focus cli contract" {
    const testing = std.testing;
    const Forward = struct {
        var window = false;
        fn call(_: Allocator, instance: apprt.ipc.Target, target: apprt.ipc.AutomationTarget, timeout: u64) !bool {
            if (window) {
                try testing.expectEqual(apprt.ipc.Target.detect, instance);
                try testing.expectEqual(std.math.maxInt(u32), target.window_id);
                try testing.expectEqual(@as(u64, 10_000), timeout);
            } else {
                try testing.expectEqualStrings("lane9", instance.class);
                try testing.expectEqual(std.math.maxInt(u64), target.surface_id);
                try testing.expectEqual(@as(u64, 0), timeout);
            }
            return true;
        }
    };
    for ([_][]const u8{
        "--class=lane9 --timeout=0 --surface-id=18446744073709551615",
        "--window-id=4294967295",
    }, 0..) |line, i| {
        Forward.window = i == 1;
        try testing.expectEqual(@as(u8, 0), try testRun(line, &Forward.call));
    }

    const Invalid = struct {
        var called = false;
        fn call(_: Allocator, _: apprt.ipc.Target, _: apprt.ipc.AutomationTarget, _: u64) !bool {
            called = true;
            return true;
        }
    };
    for ([_][]const u8{
        "",
        "extra",
        "--surface-id=1 --window-id=2",
        "--surface-id=0",
        "--surface-id=18446744073709551616",
        "--window-id=0",
        "--window-id=4294967296",
        "--timeout=10001 --surface-id=1",
        "--timeout=18446744073709551616 --surface-id=1",
    }) |line| {
        Invalid.called = false;
        try testing.expectEqual(@as(u8, 1), try testRun(line, &Invalid.call));
        try testing.expect(!Invalid.called);
    }

    const Exit = struct {
        var outcome: u8 = 0;
        fn call(_: Allocator, _: apprt.ipc.Target, _: apprt.ipc.AutomationTarget, _: u64) !bool {
            return switch (outcome) {
                1 => error.InvalidAutomationTarget,
                2 => false,
                3 => error.AutomationTargetNotFound,
                5 => error.IPCFailed,
                else => true,
            };
        }
    };
    for ([_]u8{ 0, 1, 2, 3, 5 }) |code| {
        Exit.outcome = code;
        try testing.expectEqual(code, try testRun("--surface-id=1", &Exit.call));
    }
}
