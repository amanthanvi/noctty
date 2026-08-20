const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const cli_action = @import("cli/action.zig");
const cli_ghostty_action = @import("cli/ghostty_action.zig");
const process_shared = @import("process_shared.zig");
const state = &@import("global.zig").state;

pub const std_options: std.Options = process_shared.std_options;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const action = cli_action.detectArgs(cli_ghostty_action.Action, alloc) catch |err| {
        defer posix.exit(1);
        try process_shared.reportStateInitError(err);
    };

    if (action == null) {
        spawnGuiProcess(alloc) catch |err| {
            defer posix.exit(1);
            try reportGuiLaunchFailure(err);
        };
        return;
    }

    state.init() catch |err| {
        defer posix.exit(1);
        try process_shared.reportStateInitError(err);
    };
    defer state.deinit();

    posix.exit(process_shared.runCliAction(action.?, state.alloc));
}

fn spawnGuiProcess(alloc: Allocator) !void {
    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);

    const dir = std.fs.path.dirname(self_path) orelse return error.FileNotFound;
    const gui_path = try std.fs.path.join(alloc, &.{ dir, "noctty.exe" });
    defer alloc.free(gui_path);

    var argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(alloc);

    try child_argv.append(alloc, gui_path);
    if (argv.len > 1) try child_argv.appendSlice(alloc, argv[1..]);

    var child = std.process.Child.init(child_argv.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
}

fn reportGuiLaunchFailure(err: anyerror) !void {
    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print("noctty command launcher could not start noctty.exe: {}\n", .{err});
    try stderr.flush();
}
