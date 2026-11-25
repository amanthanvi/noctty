const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");

pub const Options = struct {
    _arena: ?std.heap.ArenaAllocator = null,

    /// If set, connect to a custom noctty instance namespace.
    class: ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// Toggle the quick terminal in a running noctty instance on Windows.
/// The command uses the instance's local IPC pipe and requires a running instance.
///
/// Flags:
///
///   * `--class=<class>`: Select a custom instance namespace. The default
///     connects to the default local instance.
///
/// Available since: 1.4.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    return runArgs(alloc, &iter, stderr, performToggle);
}

fn runArgs(
    alloc: Allocator,
    iter: anytype,
    stderr: *std.Io.Writer,
    perform: *const fn (Allocator, apprt.ipc.Target) anyerror!bool,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();
    args.parse(Options, alloc, &opts, iter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing +toggle-quick-terminal arguments: {}\n", .{err});
            return 1;
        },
    };

    if (perform(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
    ) catch |err| {
        try stderr.print("Toggling the quick terminal via IPC failed: {}\n", .{err});
        return 1;
    }) return 0;

    try stderr.writeAll("No matching noctty instance is listening for IPC.\n");
    return 1;
}

fn performToggle(alloc: Allocator, target: apprt.ipc.Target) !bool {
    return apprt.App.performIpc(
        alloc,
        target,
        .toggle_quick_terminal,
        {},
        // noctty's performIpc takes a response timeout; this is the
        // default `+new-window --timeout` uses.
        10_000,
    );
}

test "toggle-quick-terminal CLI selects the requested instance" {
    const testing = std.testing;
    const Hooks = struct {
        fn custom(_: Allocator, target: apprt.ipc.Target) !bool {
            try testing.expect(target == .class);
            try testing.expectEqualStrings("lane9", target.class);
            return true;
        }

        fn default(_: Allocator, target: apprt.ipc.Target) !bool {
            try testing.expect(target == .detect);
            return false;
        }
    };

    var buf: [128]u8 = undefined;
    var stderr: std.Io.Writer = .fixed(&buf);
    var custom = args.sliceIterator(&.{"--class=lane9"});
    try testing.expectEqual(@as(u8, 0), try runArgs(testing.allocator, &custom, &stderr, Hooks.custom));
    try testing.expectEqualStrings("", stderr.buffered());

    var default = args.sliceIterator(&.{});
    try testing.expectEqual(@as(u8, 1), try runArgs(testing.allocator, &default, &stderr, Hooks.default));
    try testing.expectEqualStrings("No matching noctty instance is listening for IPC.\n", stderr.buffered());
}
