const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const working_directory = @import("automation_working_directory.zig");
pub const Options = struct {
    _arena: ?ArenaAllocator = null,
    _working_directory_seen: bool = false,
    class: ?[:0]const u8 = null,
    timeout: u64 = 10_000,
    @"surface-id": ?u64 = null,
    direction: apprt.ipc.AutomationSplitDirection = .right,
    @"working-directory": ?[:0]const u8 = null,
    pub fn parseManuallyHook(self: *Options, _: Allocator, arg: []const u8, _: anytype) !bool {
        if (std.mem.startsWith(u8, arg, "--working-directory=")) self._working_directory_seen = true;
        return true;
    }
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
    pub fn help(_: Options) !void {
        return actionpkg.help_error;
    }
};
/// Split the focused/`--surface-id` pane by direction with only a safe working-directory override.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    var buf: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const result = runArgs(alloc, &iter, &writer.interface);
    try writer.interface.flush();
    return result;
}
const NewSplitFn = *const fn (Allocator, apprt.ipc.Target, apprt.ipc.AutomationTarget, apprt.ipc.AutomationSplitDirection, ?[]const u8, u64) anyerror!bool;
fn runArgs(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer) !u8 {
    return runArgsWithNewSplit(alloc, iter, stderr, newAutomationSplit);
}
fn fail(stderr: *std.Io.Writer, code: u8) !u8 {
    try stderr.writeAll("+new-split failed.\n");
    return code;
}
fn runArgsWithNewSplit(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer, hook: NewSplitFn) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    args.parse(Options, alloc, &opts, iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => return fail(stderr, 1),
    };
    if (opts.timeout > 10_000 or (opts.@"surface-id" orelse 1) == 0 or
        (opts._working_directory_seen and opts.@"working-directory" == null)) return fail(stderr, 1);
    const cwd = opts.@"working-directory";
    if (cwd) |path| if (!working_directory.allowed(path)) return fail(stderr, 1);
    const ok = hook(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        if (opts.@"surface-id") |id| .{ .surface_id = id } else .focused,
        opts.direction,
        cwd,
        opts.timeout,
    ) catch |err| switch (err) {
        error.InvalidAutomationTarget, error.InvalidWorkingDirectory => return fail(stderr, 1),
        error.AutomationTargetNotFound, error.NoAutomationTarget => return fail(stderr, 3),
        error.AutomationPolicyRefused => return fail(stderr, 4),
        else => return fail(stderr, 5),
    };
    return if (ok) 0 else fail(stderr, 2);
}
fn newAutomationSplit(alloc: Allocator, instance: apprt.ipc.Target, target: apprt.ipc.AutomationTarget, direction: apprt.ipc.AutomationSplitDirection, cwd: ?[]const u8, timeout: u64) !bool {
    return apprt.App.newAutomationSplit(alloc, instance, target, direction, cwd, timeout);
}
test "automation new-split cli contract" {
    const testing = std.testing;
    const Hook = struct {
        var expected = apprt.ipc.AutomationSplitDirection.right;
        var exact = false;
        var outcome: u8 = 0;
        fn call(_: Allocator, instance: apprt.ipc.Target, target: apprt.ipc.AutomationTarget, direction: apprt.ipc.AutomationSplitDirection, cwd: ?[]const u8, timeout: u64) !bool {
            try testing.expectEqual(expected, direction);
            if (exact) {
                try testing.expectEqualStrings("lane9", instance.class);
                try testing.expectEqual(std.math.maxInt(u64), target.surface_id);
                try testing.expectEqualStrings("C:\\x", cwd.?);
                try testing.expectEqual(@as(u64, 0), timeout);
            } else {
                try testing.expectEqual(apprt.ipc.Target.detect, instance);
                try testing.expectEqual(apprt.ipc.AutomationTarget.focused, target);
                try testing.expect(cwd == null);
                try testing.expectEqual(@as(u64, 10_000), timeout);
            }
            return working_directory.testOutcome(outcome);
        }
    };
    for ([_]apprt.ipc.AutomationSplitDirection{ .right, .left, .up, .down }) |direction| {
        Hook.expected = direction;
        Hook.exact = direction == .right;
        Hook.outcome = 0;
        const argv: []const []const u8 = if (direction == .right) &.{ "--class=lane9", "--timeout=0", "--surface-id=18446744073709551615", "--working-directory=C:\\x" } else switch (direction) {
            .left => &.{"--direction=left"},
            .up => &.{"--direction=up"},
            .down => &.{"--direction=down"},
            .right => unreachable,
        };
        try testing.expectEqual(@as(u8, 0), try working_directory.testRun(runArgsWithNewSplit, argv, &Hook.call));
    }
    const Reject = struct {
        var called = false;
        fn call(_: Allocator, _: apprt.ipc.Target, _: apprt.ipc.AutomationTarget, _: apprt.ipc.AutomationSplitDirection, _: ?[]const u8, _: u64) !bool {
            called = true;
            return true;
        }
    };
    for ([_][]const []const u8{
        &.{"--surface-id=0"},                 &.{"--surface-id=18446744073709551616"}, &.{"--timeout=10001"},                     &.{"--timeout=18446744073709551616"},
        &.{"--working-directory="},           &.{"--direction=diagonal"},              &.{"--working-directory=\\\\host\\share"}, &.{"--working-directory=relative"},
        &.{"--working-directory=C:relative"}, &.{"-e"},                                &.{"--title=x"},                           &.{"--command=x"},
        &.{"positional"},
    }) |argv| {
        Reject.called = false;
        try testing.expectEqual(@as(u8, 1), try working_directory.testRun(runArgsWithNewSplit, argv, &Reject.call));
        try testing.expect(!Reject.called);
    }
    Hook.expected = .right;
    Hook.exact = false;
    for ([_]u8{ 0, 1, 2, 3, 4, 5 }) |code| {
        Hook.outcome = code;
        try testing.expectEqual(code, try working_directory.testRun(runArgsWithNewSplit, &.{}, &Hook.call));
    }
}
