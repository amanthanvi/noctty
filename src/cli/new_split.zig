const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const test_support = @import("automation_test_support.zig");
const working_directory = @import("automation_working_directory.zig");

/// Parsed options for the `+new-split` command.
pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Tracks an explicitly supplied empty working-directory value.
    _working_directory_seen: bool = false,

    /// Tracks an explicitly supplied empty surface target.
    _surface_id_seen: bool = false,

    /// Select a custom single-instance namespace.
    class: ?[:0]const u8 = null,

    /// Response timeout in milliseconds, from 0 through 10000.
    timeout: u64 = 10_000,

    /// Optional nonzero pane ID from `+list-windows`.
    @"surface-id": ?u64 = null,

    /// Direction of the new split, defaulting to right.
    direction: apprt.ipc.AutomationSplitDirection = .right,

    /// Optional receiver-validated working-directory override.
    @"working-directory": ?[:0]const u8 = null,

    /// Records whether the working-directory flag appeared before parsing.
    pub fn parseManuallyHook(self: *Options, _: Allocator, arg: []const u8, _: anytype) !bool {
        if (std.mem.startsWith(u8, arg, "--working-directory=")) {
            self._working_directory_seen = true;
        }
        if (std.mem.startsWith(u8, arg, "--surface-id=")) {
            self._surface_id_seen = true;
        }
        return true;
    }

    /// Releases memory owned by the parsed options.
    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
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

/// Injected IPC seam used by the command and its unit tests.
const NewSplitFn = *const fn (
    Allocator,
    apprt.ipc.Target,
    apprt.ipc.AutomationTarget,
    apprt.ipc.AutomationSplitDirection,
    ?[]const u8,
    u64,
) anyerror!bool;

/// Dispatches parsed arguments through the production IPC implementation.
fn runArgs(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer) !u8 {
    return runArgsWithNewSplit(alloc, iter, stderr, newAutomationSplit);
}

/// Writes the stable command diagnostic before returning an exit code.
fn fail(stderr: *std.Io.Writer, code: u8) !u8 {
    try stderr.writeAll("+new-split failed.\n");
    return code;
}

/// Parses and validates `+new-split` before invoking the injected IPC seam.
fn runArgsWithNewSplit(
    alloc: Allocator,
    iter: anytype,
    stderr: *std.Io.Writer,
    hook: NewSplitFn,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc, &opts, iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => return fail(stderr, 1),
    };

    if (opts.timeout > 10_000 or (opts.@"surface-id" orelse 1) == 0 or
        (opts._surface_id_seen and opts.@"surface-id" == null) or
        (opts._working_directory_seen and opts.@"working-directory" == null))
    {
        return fail(stderr, 1);
    }

    const cwd = opts.@"working-directory";
    if (cwd) |path| {
        if (!working_directory.allowed(path)) {
            return fail(stderr, 1);
        }
    }

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

/// Requests a new split relative to the selected running-instance surface.
fn newAutomationSplit(
    alloc: Allocator,
    instance: apprt.ipc.Target,
    target: apprt.ipc.AutomationTarget,
    direction: apprt.ipc.AutomationSplitDirection,
    cwd: ?[]const u8,
    timeout: u64,
) !bool {
    return apprt.App.newAutomationSplit(alloc, instance, target, direction, cwd, timeout);
}

test "automation new-split cli contract" {
    const testing = std.testing;

    const Hook = struct {
        var expected = apprt.ipc.AutomationSplitDirection.right;
        var exact = false;
        var outcome: u8 = 0;

        fn call(
            _: Allocator,
            instance: apprt.ipc.Target,
            target: apprt.ipc.AutomationTarget,
            direction: apprt.ipc.AutomationSplitDirection,
            cwd: ?[]const u8,
            timeout: u64,
        ) !bool {
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
            return test_support.testOutcome(outcome);
        }
    };

    for ([_]apprt.ipc.AutomationSplitDirection{ .right, .left, .up, .down }) |direction| {
        Hook.expected = direction;
        Hook.exact = direction == .right;
        Hook.outcome = 0;
        const argv: []const []const u8 = if (direction == .right)
            &.{ "--class=lane9", "--timeout=0", "--surface-id=18446744073709551615", "--working-directory=C:\\x" }
        else switch (direction) {
            .left => &.{"--direction=left"},
            .up => &.{"--direction=up"},
            .down => &.{"--direction=down"},
            .right => unreachable,
        };
        try testing.expectEqual(@as(u8, 0), try test_support.testRun(runArgsWithNewSplit, argv, &Hook.call));
    }

    const Reject = struct {
        var called = false;

        fn call(
            _: Allocator,
            _: apprt.ipc.Target,
            _: apprt.ipc.AutomationTarget,
            _: apprt.ipc.AutomationSplitDirection,
            _: ?[]const u8,
            _: u64,
        ) !bool {
            called = true;
            return true;
        }
    };

    for ([_][]const []const u8{
        &.{"--surface-id=0"},
        &.{"--surface-id="},
        &.{"--surface-id=18446744073709551616"},
        &.{"--timeout=10001"},
        &.{"--timeout=18446744073709551616"},
        &.{"--working-directory="},
        &.{"--direction=diagonal"},
        &.{"--working-directory=\\\\host\\share"},
        &.{"--working-directory=relative"},
        &.{"--working-directory=C:relative"},
        &.{"-e"},
        &.{"--title=x"},
        &.{"--command=x"},
        &.{"positional"},
    }) |argv| {
        Reject.called = false;
        try testing.expectEqual(@as(u8, 1), try test_support.testRun(runArgsWithNewSplit, argv, &Reject.call));
        try testing.expect(!Reject.called);
    }

    Hook.expected = .right;
    Hook.exact = false;
    for ([_]u8{ 0, 1, 2, 3, 4, 5 }) |code| {
        Hook.outcome = code;
        try testing.expectEqual(code, try test_support.testRun(runArgsWithNewSplit, &.{}, &Hook.call));
    }
}
