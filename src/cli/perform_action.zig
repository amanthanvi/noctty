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
    /// default local winghostty instance.
    class: ?[:0]const u8 = null,

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
/// running local winghostty instance.
///
/// The action uses the same syntax as `keybind` values, for example:
///
///   * `winghostty +perform-action new_tab`
///   * `winghostty +perform-action --surface-id=42 toggle_fullscreen`
///
/// The default target is the focused surface for surface-scoped actions and the
/// app for app-scoped actions. `--surface-id` accepts pane IDs from
/// `winghostty +list-windows` and is only valid for surface-scoped actions.
///
/// To keep this automation surface bounded, terminal-input and arbitrary file
/// helper actions such as `text`, `csi`, `esc`, `paste_from_clipboard`,
/// `write_screen_file`, and `crash` are rejected by the running instance. New
/// action variants are denied until explicitly added to the automation
/// allowlist.
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
            opts.@"surface-id" = std.fmt.parseInt(u64, raw, 10) catch {
                try stderr.print("Invalid --surface-id value: {s}\n", .{raw});
                return 1;
            };
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
    ) catch |err| switch (err) {
        error.InvalidAutomationTarget => {
            try stderr.print("Invalid automation target for action: {s}\n", .{action});
            return 1;
        },
        error.NoAutomationTarget => {
            try stderr.print("No matching automation target for action: {s}\n", .{action});
            return 1;
        },
        error.InvalidAutomationAction => {
            try stderr.print("Invalid action for +perform-action: {s}\n", .{action});
            return 1;
        },
        error.UnsafeAutomationAction => {
            try stderr.print("Unsafe action rejected for +perform-action: {s}\n", .{action});
            return 1;
        },
        error.IPCFailed => {
            try stderr.print("Performing automation action via IPC failed.\n", .{});
            return 1;
        },
        error.InvalidIpcResponse => {
            try stderr.print("Performing automation action via IPC failed: invalid response from the target instance.\n", .{});
            return 1;
        },
        else => return err,
    };

    if (ok) return 0;

    try stderr.print("No matching winghostty instance is listening for automation actions.\n", .{});
    return 1;
}

fn performAutomationAction(
    alloc: Allocator,
    target: apprt.ipc.Target,
    action_target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
) !bool {
    return try apprt.App.performAutomationAction(
        alloc,
        target,
        action_target,
        action_text,
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
            return true;
        }
    };
    defer if (Hook.seen_class) |value| testing.allocator.free(value);
    defer if (Hook.seen_action) |value| testing.allocator.free(value);

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--class=lane9 --surface-id=42 new_tab",
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

    try testing.expectEqual(@as(u8, 1), exit_code);
    try testing.expectEqualStrings(
        "Performing automation action via IPC failed: invalid response from the target instance.\n",
        stderr_buf.written(),
    );
}
