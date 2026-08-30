const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const actionpkg = @import("action.zig");
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const lib = @import("../lib/main.zig");
const paste_protection = @import("../apprt/win32_paste_protection.zig");
const test_support = @import("automation_test_support.zig");

/// Maximum text payload accepted by the automation protocol.
const max_text_len = 16 * 1024;

/// Parsed options for the `+send-text` command.
pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Select a custom single-instance namespace.
    class: ?[:0]const u8 = null,

    /// Response timeout in milliseconds, from 0 through 10000.
    timeout: u64 = 10_000,

    /// Required nonzero pane ID from `+list-windows`.
    @"surface-id": ?u64 = null,

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

/// Send printable UTF-8 to `--surface-id`; control input is refused and never prompts.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buf: [1024]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    const result = runArgs(alloc, &iter, &writer.interface);

    try writer.interface.flush();
    return result;
}

/// Dispatches parsed arguments through the production IPC implementation.
fn runArgs(alloc: Allocator, iter: anytype, stderr: *std.Io.Writer) !u8 {
    return runArgsWithSend(alloc, iter, stderr, sendAutomationText);
}

/// Injected IPC seam used by the command and its unit tests.
const SendFn = *const fn (
    Allocator,
    apprt.ipc.Target,
    apprt.ipc.AutomationTarget,
    []const u8,
    u64,
) anyerror!bool;

/// Result of validating a prospective automation text payload.
const TextPolicy = enum {
    allowed,
    invalid,
    refused,
};

/// Writes a stable diagnostic before returning an exit code.
fn report(stderr: *std.Io.Writer, code: u8, message: []const u8) !u8 {
    try stderr.writeAll(message);
    return code;
}

/// Parses and validates `+send-text` before invoking the injected IPC seam.
fn runArgsWithSend(
    alloc: Allocator,
    iter: anytype,
    stderr: *std.Io.Writer,
    hook: SendFn,
) !u8 {
    var opts: Options = .{ ._arena = ArenaAllocator.init(alloc) };
    defer opts.deinit();
    const arena = opts._arena.?.allocator();

    var text: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return actionpkg.help_error;
        }

        if (lib.cutPrefix(u8, arg, "--class=")) |value| {
            opts.class = try arena.dupeZ(u8, std.mem.trim(u8, value, &std.ascii.whitespace));
        } else if (lib.cutPrefix(u8, arg, "--surface-id=")) |value| {
            if (opts.@"surface-id" != null) {
                return report(stderr, 1, "Invalid +send-text arguments.\n");
            }
            opts.@"surface-id" = std.fmt.parseInt(u64, value, 10) catch return report(stderr, 1, "Invalid --surface-id.\n");
        } else if (lib.cutPrefix(u8, arg, "--timeout=")) |value| {
            opts.timeout = std.fmt.parseInt(u64, value, 10) catch return report(stderr, 1, "Invalid --timeout.\n");
        } else if (std.mem.startsWith(u8, arg, "-") or text != null) {
            return report(stderr, 1, "Invalid +send-text arguments.\n");
        } else {
            text = arg;
        }
    }

    const id = opts.@"surface-id" orelse return report(stderr, 1, "+send-text requires --surface-id.\n");
    const value = text orelse return report(stderr, 1, "+send-text requires one text argument.\n");
    if (id == 0 or opts.timeout > 10_000) {
        return report(stderr, 1, "Invalid +send-text arguments.\n");
    }

    switch (automationTextPolicy(value)) {
        .allowed => {},
        .invalid => return report(stderr, 1, "Invalid automation text.\n"),
        .refused => return report(stderr, 4, "Automation control input refused.\n"),
    }

    const ok = hook(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        .{ .surface_id = id },
        value,
        opts.timeout,
    ) catch |err| switch (err) {
        error.InvalidAutomationTarget, error.InvalidAutomationText => return report(stderr, 1, "Invalid automation text request.\n"),
        error.AutomationTargetNotFound, error.NoAutomationTarget => return report(stderr, 3, "Automation target not found.\n"),
        error.AutomationPolicyRefused => return report(stderr, 4, "Automation text refused.\n"),
        else => return report(stderr, 5, "Automation text IPC failed.\n"),
    };

    return if (ok) 0 else report(stderr, 2, "No matching noctty instance.\n");
}

/// Applies the CLI-side text policy before any IPC connection is attempted.
fn automationTextPolicy(text: []const u8) TextPolicy {
    if (text.len == 0 or text.len > max_text_len) {
        return .invalid;
    }

    const view = std.unicode.Utf8View.init(text) catch return .invalid;
    var iter = view.iterator();

    while (iter.nextCodepoint()) |cp| {
        if (cp <= 0x1F or cp == 0x7F or (cp >= 0x80 and cp <= 0x9F)) {
            return .refused;
        }
    }

    if (paste_protection.inspect(text).severity == .control_chars) {
        return .refused;
    }
    return .allowed;
}

/// Sends validated automation text to the matching running instance.
fn sendAutomationText(
    alloc: Allocator,
    instance: apprt.ipc.Target,
    target: apprt.ipc.AutomationTarget,
    text: []const u8,
    timeout: u64,
) !bool {
    return apprt.App.sendAutomationText(alloc, instance, target, text, timeout);
}

test "automation send-text cli contract and policy" {
    const testing = std.testing;

    const Hook = struct {
        var called = false;
        var expected: ?[]const u8 = null;
        var outcome: u8 = 0;

        fn call(
            _: Allocator,
            instance: apprt.ipc.Target,
            target: apprt.ipc.AutomationTarget,
            text: []const u8,
            timeout: u64,
        ) !bool {
            called = true;
            try testing.expectEqualStrings(expected.?, text);
            try testing.expectEqual(@as(u64, 42), target.surface_id);
            if (std.mem.eql(u8, text, "caf\xc3\xa9 \xe2\x98\x95")) {
                try testing.expectEqualStrings("lane9", instance.class);
                try testing.expectEqual(@as(u64, 0), timeout);
            } else {
                try testing.expectEqual(@as(u64, 10_000), timeout);
            }
            return test_support.testOutcome(outcome);
        }
    };

    for ([_][]const u8{
        "caf\xc3\xa9 \xe2\x98\x95",
        "echo $env:Path; whoami | more",
        "please visit https://example.com right now",
    }, 0..) |value, i| {
        Hook.expected = value;
        Hook.outcome = 0;
        const argv: []const []const u8 = if (i == 0)
            &.{ "--class=lane9", "--timeout=0", "--surface-id=42", value }
        else
            &.{ "--surface-id=42", value };
        try testing.expectEqual(@as(u8, 0), try test_support.testRun(runArgsWithSend, argv, &Hook.call));
    }

    const Invalid = struct {
        var called = false;

        fn call(
            _: Allocator,
            _: apprt.ipc.Target,
            _: apprt.ipc.AutomationTarget,
            _: []const u8,
            _: u64,
        ) !bool {
            called = true;
            return true;
        }
    };

    for ([_][]const []const u8{
        &.{},
        &.{"text"},
        &.{"--surface-id=1"},
        &.{ "--surface-id=1", "one", "two" },
        &.{ "--surface-id=0", "text" },
        &.{ "--surface-id=18446744073709551616", "text" },
        &.{ "--timeout=10001", "--surface-id=1", "text" },
        &.{ "--timeout=18446744073709551616", "--surface-id=1", "text" },
    }) |argv| {
        Invalid.called = false;
        try testing.expectEqual(@as(u8, 1), try test_support.testRun(runArgsWithSend, argv, &Invalid.call));
        try testing.expect(!Invalid.called);
    }

    for ([_][]const u8{
        "before\r",
        "before\n",
        "before\t",
        "before\x00",
        "before\x1B",
        "before\x7F",
        "before\xC2\x80",
    }) |value| {
        Invalid.called = false;
        try testing.expectEqual(@as(u8, 4), try test_support.testRun(runArgsWithSend, &.{ "--surface-id=1", value }, &Invalid.call));
        try testing.expect(!Invalid.called);
    }

    const oversized = try testing.allocator.alloc(u8, max_text_len + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');

    for ([_][]const u8{ "", "\xFF", oversized }) |value| {
        try testing.expectEqual(@as(u8, 1), try test_support.testRun(runArgsWithSend, &.{ "--surface-id=1", value }, &Invalid.call));
        try testing.expect(!Invalid.called);
    }

    Hook.expected = "text";
    for ([_]u8{ 0, 1, 2, 3, 4, 5 }) |code| {
        Hook.outcome = code;
        try testing.expectEqual(code, try test_support.testRun(runArgsWithSend, &.{ "--surface-id=42", "text" }, &Hook.call));
    }
}
