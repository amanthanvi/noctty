const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const input = @import("../input.zig");
const lib = @import("../lib/main.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, query a custom single-instance namespace instead of the
    /// default local noctty instance.
    class: ?[:0]const u8 = null,

    /// How long to wait for the running instance to respond.
    timeout: u64 = 10_000,

    /// If set, perform the action against a specific surface from
    /// `+list-windows` instead of the focused surface.
    @"surface-id": ?u64 = null,

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

/// The `perform-action` command forwards one safe keybinding action to a
/// running local noctty instance.
///
/// The action uses the same syntax as `keybind` values, for example:
///
///   * `noctty +perform-action new_tab`
///   * `noctty +perform-action --surface-id=42 toggle_fullscreen`
///
/// The default target is the focused surface for surface-scoped actions and the
/// app for app-scoped actions. `--surface-id` accepts pane IDs from
/// `noctty +list-windows` and is only valid for surface-scoped actions.
///
/// To keep this automation surface bounded, terminal-input and arbitrary file
/// helper actions such as `text`, `csi`, `esc`, `paste_from_clipboard`,
/// `write_screen_file`, and `crash` are rejected by the running instance. New
/// action variants are denied until explicitly added to the automation
/// allowlist.
///
/// Flags:
///
///   * `--class=<class>`: Select a custom instance namespace.
///
///   * `--surface-id=<id>`: Target a nonzero pane ID from `+list-windows`.
///
///   * `--timeout=<ms>`: Response timeout in milliseconds, from 0 through
///     10000. The default is 10000.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    try stderr.flush();
    return result;
}

fn runArgs(
    alloc: Allocator,
    args_iter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    return runArgsWithPerform(
        alloc,
        args_iter,
        stderr,
        performAutomationAction,
    );
}

const PerformAutomationActionFn = *const fn (
    alloc: Allocator,
    target: apprt.ipc.Target,
    action_target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
    timeout_ms: u64,
) anyerror!bool;

fn runArgsWithPerform(
    alloc: Allocator,
    args_iter: anytype,
    stderr: *std.Io.Writer,
    performAutomationActionFn: PerformAutomationActionFn,
) !u8 {
    var opts: Options = .{};
    opts._arena = ArenaAllocator.init(alloc);
    defer opts.deinit();
    const opts_alloc = opts._arena.?.allocator();

    var action_text: ?[]const u8 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "+perform-action") or
            std.mem.eql(u8, arg, "perform-action"))
        {
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return actionpkg.help_error;
        }
        if (lib.cutPrefix(u8, arg, "--class=")) |class| {
            opts.class = try opts_alloc.dupeZ(u8, std.mem.trim(u8, class, &std.ascii.whitespace));
            continue;
        }
        if (lib.cutPrefix(u8, arg, "--surface-id=")) |raw| {
            const id = std.fmt.parseInt(u64, raw, 10) catch {
                try stderr.print("Invalid --surface-id value: {s}\n", .{raw});
                return 1;
            };
            if (id == 0) {
                try stderr.print("--surface-id must be nonzero.\n", .{});
                return 1;
            }
            opts.@"surface-id" = id;
            continue;
        }
        if (lib.cutPrefix(u8, arg, "--timeout=")) |raw| {
            opts.timeout = std.fmt.parseInt(u64, raw, 10) catch {
                try stderr.print("Invalid --timeout value: {s}\n", .{raw});
                return 1;
            };
            if (opts.timeout > 10_000) {
                try stderr.print("--timeout must be between 0 and 10000 milliseconds.\n", .{});
                return 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("Unknown option for +perform-action: {s}\n", .{arg});
            return 1;
        }
        if (action_text != null) {
            try stderr.print("+perform-action accepts exactly one action.\n", .{});
            return 1;
        }
        action_text = arg;
    }

    const action = action_text orelse {
        try stderr.print("+perform-action requires an action, for example: new_tab\n", .{});
        return 1;
    };

    const parsed_action = input.Binding.Action.parse(action) catch |err| switch (err) {
        error.InvalidAction, error.InvalidFormat => {
            try stderr.print("Invalid action for +perform-action: {s}\n", .{action});
            return 1;
        },
        else => return err,
    };

    if (opts.@"surface-id" != null and parsed_action.scope() == .app) {
        try stderr.print(
            "--surface-id is only valid for surface-scoped actions; '{s}' is app-scoped.\n",
            .{action},
        );
        return 1;
    }

    const ok = performAutomationActionFn(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        if (opts.@"surface-id") |id| .{ .surface_id = id } else .focused,
        action,
        opts.timeout,
    ) catch |err| switch (err) {
        error.InvalidAutomationTarget => {
            try stderr.print("Invalid automation target for action: {s}\n", .{action});
            return 1;
        },
        error.NoAutomationTarget => {
            try stderr.print("No matching automation target for action: {s}\n", .{action});
            return 3;
        },
        error.InvalidAutomationAction => {
            try stderr.print("Invalid action for +perform-action: {s}\n", .{action});
            return 1;
        },
        error.UnsafeAutomationAction => {
            try stderr.print("Unsafe action rejected for +perform-action: {s}\n", .{action});
            return 4;
        },
        else => {
            try stderr.print("Performing automation action via IPC failed: {}\n", .{err});
            return 5;
        },
    };

    if (ok) return 0;

    try stderr.print("No matching noctty instance is listening for automation actions.\n", .{});
    return 2;
}

fn performAutomationAction(
    alloc: Allocator,
    target: apprt.ipc.Target,
    action_target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
    timeout_ms: u64,
) !bool {
    return try apprt.App.performAutomationAction(
        alloc,
        target,
        action_target,
        action_text,
        timeout_ms,
    );
}

test "automation-action cli forwards class surface and action" {
    const testing = std.testing;

    const Hook = struct {
        var seen_class: ?[]u8 = null;
        var seen_surface_id: ?u64 = null;
        var seen_action: ?[]u8 = null;

        fn perform(
            _: Allocator,
            target: apprt.ipc.Target,
            action_target: apprt.ipc.AutomationActionTarget,
            action_text: []const u8,
            timeout_ms: u64,
        ) !bool {
            seen_class = switch (target) {
                .class => |class| try testing.allocator.dupe(u8, class),
                .detect => return error.UnexpectedTarget,
            };
            seen_surface_id = switch (action_target) {
                .surface_id => |id| id,
                .focused => return error.UnexpectedTarget,
            };
            seen_action = try testing.allocator.dupe(u8, action_text);
            try testing.expectEqual(@as(u64, 0), timeout_ms);
            return true;
        }
    };
    defer if (Hook.seen_class) |value| testing.allocator.free(value);
    defer if (Hook.seen_action) |value| testing.allocator.free(value);

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--class=lane9 --surface-id=42 --timeout=0 new_tab",
    );
    defer iter.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithPerform(
        testing.allocator,
        &iter,
        &stderr_buf.writer,
        &Hook.perform,
    );

    try testing.expectEqual(@as(u8, 0), exit_code);
    try testing.expectEqualStrings("", stderr_buf.written());
    try testing.expectEqualStrings("lane9", Hook.seen_class.?);
    try testing.expectEqual(@as(u64, 42), Hook.seen_surface_id.?);
    try testing.expectEqualStrings("new_tab", Hook.seen_action.?);
}

test "automation-action cli rejects invalid action before ipc" {
    const testing = std.testing;

    const Hook = struct {
        fn perform(
            _: Allocator,
            _: apprt.ipc.Target,
            _: apprt.ipc.AutomationActionTarget,
            _: []const u8,
            _: u64,
        ) !bool {
            return error.UnexpectedIpc;
        }
    };

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "definitely_not_an_action",
    );
    defer iter.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithPerform(
        testing.allocator,
        &iter,
        &stderr_buf.writer,
        &Hook.perform,
    );

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings(
        "Invalid action for +perform-action: definitely_not_an_action\n",
        stderr_buf.written(),
    );
}

test "automation-action cli rejects app action with surface id before ipc" {
    const testing = std.testing;

    const Hook = struct {
        fn perform(
            _: Allocator,
            _: apprt.ipc.Target,
            _: apprt.ipc.AutomationActionTarget,
            _: []const u8,
            _: u64,
        ) !bool {
            return error.UnexpectedIpc;
        }
    };

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--surface-id=42 quit",
    );
    defer iter.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithPerform(
        testing.allocator,
        &iter,
        &stderr_buf.writer,
        &Hook.perform,
    );

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings(
        "--surface-id is only valid for surface-scoped actions; 'quit' is app-scoped.\n",
        stderr_buf.written(),
    );
}

test "automation-action cli reports invalid ipc response" {
    const testing = std.testing;

    const Hook = struct {
        fn perform(
            _: Allocator,
            _: apprt.ipc.Target,
            _: apprt.ipc.AutomationActionTarget,
            _: []const u8,
            _: u64,
        ) !bool {
            return error.InvalidIpcResponse;
        }
    };

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "new_tab",
    );
    defer iter.deinit();

    var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer stderr_buf.deinit();

    const exit_code = try runArgsWithPerform(
        testing.allocator,
        &iter,
        &stderr_buf.writer,
        &Hook.perform,
    );

    try testing.expectEqual(@as(u8, 5), exit_code);
    try testing.expect(std.mem.startsWith(u8, stderr_buf.written(), "Performing automation action via IPC failed:"));
}

test "automation-action cli rejects invalid arguments before ipc" {
    const testing = std.testing;

    const Hook = struct {
        var called = false;

        fn perform(_: Allocator, _: apprt.ipc.Target, _: apprt.ipc.AutomationActionTarget, _: []const u8, _: u64) !bool {
            called = true;
            return true;
        }
    };

    for ([_][]const u8{
        "--surface-id=0 new_tab",
        "--surface-id=18446744073709551616 new_tab",
        "--timeout=10001 new_tab",
        "--timeout=18446744073709551616 new_tab",
        "",
        "new_tab close_tab",
    }) |command_line| {
        Hook.called = false;
        var iter = try std.process.ArgIteratorGeneral(.{}).init(testing.allocator, command_line);
        defer iter.deinit();

        var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
        defer stderr_buf.deinit();

        try testing.expectEqual(@as(u8, 1), try runArgsWithPerform(
            testing.allocator,
            &iter,
            &stderr_buf.writer,
            &Hook.perform,
        ));
        try testing.expect(!Hook.called);
    }
}

test "automation-action cli maps stable runtime exit codes" {
    const testing = std.testing;

    const Hook = struct {
        var outcome: u8 = 0;

        fn perform(_: Allocator, _: apprt.ipc.Target, _: apprt.ipc.AutomationActionTarget, _: []const u8, timeout_ms: u64) !bool {
            try testing.expectEqual(@as(u64, 10_000), timeout_ms);
            return switch (outcome) {
                1 => error.InvalidAutomationTarget,
                2 => false,
                3 => error.NoAutomationTarget,
                4 => error.UnsafeAutomationAction,
                5 => error.IPCFailed,
                else => true,
            };
        }
    };

    for ([_]u8{ 1, 2, 3, 4, 5 }) |expected| {
        Hook.outcome = expected;
        var iter = try std.process.ArgIteratorGeneral(.{}).init(testing.allocator, "new_tab");
        defer iter.deinit();

        var stderr_buf = std.Io.Writer.Allocating.init(testing.allocator);
        defer stderr_buf.deinit();

        try testing.expectEqual(expected, try runArgsWithPerform(
            testing.allocator,
            &iter,
            &stderr_buf.writer,
            &Hook.perform,
        ));
    }
}
