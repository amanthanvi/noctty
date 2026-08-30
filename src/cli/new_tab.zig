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
    @"window-id": ?u32 = null,
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
/// Create a tab in the focused/`--window-id` window with only a safe `--working-directory` override.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    var buf: [512]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const result = runArgs(alloc, &iter, &writer.interface);
    try writer.interface.flush();
    return result;
}
const NewTabFn = *const fn (Allocator, apprt.ipc.Target, apprt.ipc.AutomationTarget, ?[]const u8, u64) anyerror!bool;
fn runArgs(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer) !u8 {
    return runArgsWithNewTab(alloc, iter, stderr, newAutomationTab);
}
fn fail(stderr: *std.Io.Writer, code: u8) !u8 {
    try stderr.writeAll("+new-tab failed.\n");
    return code;
}
fn runArgsWithNewTab(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer, hook: NewTabFn) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    args.parse(Options, alloc, &opts, iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => return fail(stderr, 1),
    };
    if (opts.timeout > 10_000 or (opts.@"window-id" orelse 1) == 0 or
        (opts._working_directory_seen and opts.@"working-directory" == null)) return fail(stderr, 1);
    const cwd = opts.@"working-directory";
    if (cwd) |path| if (!working_directory.allowed(path)) return fail(stderr, 1);
    const ok = hook(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        if (opts.@"window-id") |id| .{ .window_id = id } else .focused,
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
fn newAutomationTab(alloc: Allocator, instance: apprt.ipc.Target, target: apprt.ipc.AutomationTarget, cwd: ?[]const u8, timeout: u64) !bool {
    return apprt.App.newAutomationTab(alloc, instance, target, cwd, timeout);
}
test "automation new-tab cli contract" {
    const testing = std.testing;
    const Hook = struct {
        var called = false;
        var expected_cwd: ?[]const u8 = null;
        var window = false;
        var outcome: u8 = 0;
        fn call(_: Allocator, instance: apprt.ipc.Target, target: apprt.ipc.AutomationTarget, cwd: ?[]const u8, timeout: u64) !bool {
            called = true;
            if (expected_cwd) |expected| try testing.expectEqualStrings(expected, cwd.?) else try testing.expect(cwd == null);
            if (window) {
                try testing.expectEqualStrings("lane9", instance.class);
                try testing.expectEqual(std.math.maxInt(u32), target.window_id);
                try testing.expectEqual(@as(u64, 0), timeout);
            } else {
                try testing.expectEqual(apprt.ipc.Target.detect, instance);
                try testing.expectEqual(apprt.ipc.AutomationTarget.focused, target);
                try testing.expectEqual(@as(u64, 10_000), timeout);
            }
            return working_directory.testOutcome(outcome);
        }
    };
    for ([_]struct { cwd: ?[]const u8, argv: []const []const u8, window: bool = false }{
        .{ .cwd = null, .argv = &.{} },                                                                                                           .{ .cwd = "home", .argv = &.{"--working-directory=home"} },
        .{ .cwd = "inherit", .argv = &.{"--working-directory=inherit"} },                                                                         .{ .cwd = "~", .argv = &.{"--working-directory=~"} },
        .{ .cwd = "~/x", .argv = &.{"--working-directory=~/x"} },                                                                                 .{ .cwd = "~\\x", .argv = &.{"--working-directory=~\\x"} },
        .{ .cwd = "C:\\x", .argv = &.{ "--class=lane9", "--timeout=0", "--window-id=4294967295", "--working-directory=C:\\x" }, .window = true },
    }) |case| {
        Hook.expected_cwd = case.cwd;
        Hook.window = case.window;
        Hook.outcome = 0;
        try testing.expectEqual(@as(u8, 0), try working_directory.testRun(runArgsWithNewTab, case.argv, &Hook.call));
    }
    const Reject = struct {
        var called = false;
        fn call(_: Allocator, _: apprt.ipc.Target, _: apprt.ipc.AutomationTarget, _: ?[]const u8, _: u64) !bool {
            called = true;
            return true;
        }
    };
    for ([_][]const []const u8{
        &.{"--window-id=0"},                 &.{"--window-id=4294967296"},              &.{"--timeout=10001"},                  &.{"--timeout=18446744073709551616"},
        &.{"--working-directory="},          &.{"--working-directory=\\\\host\\share"}, &.{"--working-directory=//host/share"}, &.{"--working-directory=\\\\?\\C:\\x"},
        &.{"--working-directory=relative"},  &.{"--working-directory=C:relative"},      &.{"-e"},                               &.{"--title=x"},
        &.{"--working-directory=C:\\x\x00"}, &.{"--working-directory=C:\\x\xFF"},       &.{"--command=x"},                      &.{"positional"},
    }) |argv| {
        Reject.called = false;
        try testing.expectEqual(@as(u8, 1), try working_directory.testRun(runArgsWithNewTab, argv, &Reject.call));
        try testing.expect(!Reject.called);
    }
    Hook.expected_cwd = null;
    Hook.window = false;
    for ([_]u8{ 0, 1, 2, 3, 4, 5 }) |code| {
        Hook.outcome = code;
        try testing.expectEqual(code, try working_directory.testRun(runArgsWithNewTab, &.{}, &Hook.call));
    }
}
