const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const cli = @import("cli.zig");
const state = &@import("global.zig").state;

pub fn reportStateInitError(err: anyerror) !void {
    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const ErrSet = @TypeOf(err) || error{Unknown};
    switch (@as(ErrSet, @errorCast(err))) {
        error.MultipleActions => try stderr.print(
            "Error: multiple CLI actions specified. You must specify only one\n" ++
                "action starting with the `+` character.\n",
            .{},
        ),

        error.InvalidAction => try stderr.print(
            "Error: unknown CLI action specified. CLI actions are specified with\n" ++
                "the '+' character.\n\n" ++
                "All valid CLI actions can be listed with `noctty +help`\n",
            .{},
        ),

        else => try stderr.print("invalid CLI invocation err={}\n", .{err}),
    }

    try stderr.flush();
}

pub fn runCliAction(action: cli.ghostty.Action, alloc: std.mem.Allocator) u8 {
    return cli.ghostty.run(action, alloc) catch |err| err: {
        reportCliActionFailure(action, err);
        break :err 1;
    };
}

pub fn reportCliActionFailure(action: cli.ghostty.Action, err: anyerror) void {
    var message_buf: [512]u8 = undefined;
    const message = formatCliActionFailureMessage(&message_buf, action, err);
    if (writePlainStderr(message)) return;
    showWindowsCliFailureDialog(message);
}

fn formatCliActionFailureMessage(
    buf: []u8,
    action: cli.ghostty.Action,
    err: anyerror,
) []const u8 {
    if (comptime builtin.os.tag == .windows) {
        if (err == error.ActionHelpOutputUnavailable) {
            return std.fmt.bufPrint(
                buf,
                "noctty +{s} could not write help text. Launch it from Command Prompt, PowerShell, or Windows Terminal, or redirect the output to a file.\n",
                .{@tagName(action)},
            ) catch "noctty CLI action failed.\n";
        }
    }

    return std.fmt.bufPrint(
        buf,
        "noctty +{s} failed: {s}\n",
        .{ @tagName(action), @errorName(err) },
    ) catch "noctty CLI action failed.\n";
}

fn writePlainStderr(message: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;
    stderr.writeAll(message) catch return false;
    stderr.flush() catch return false;
    return true;
}

fn showWindowsCliFailureDialog(message: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;

    const caption = std.unicode.utf8ToUtf16LeStringLiteral("noctty CLI action failed");
    const fallback = std.unicode.utf8ToUtf16LeStringLiteral("noctty CLI action failed.");

    const message_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, message) catch {
        _ = MessageBoxW(null, fallback, caption, MB_OK | MB_ICONERROR);
        return;
    };
    defer std.heap.page_allocator.free(message_w);

    _ = MessageBoxW(null, message_w, caption, MB_OK | MB_ICONERROR);
}

const MB_OK: u32 = 0x0000;
const MB_ICONERROR: u32 = 0x0010;

extern "user32" fn MessageBoxW(
    hwnd: ?windows.HWND,
    text: [*:0]const u16,
    caption: [*:0]const u16,
    flags: u32,
) callconv(.winapi) c_int;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    stderr: {
        if (comptime builtin.mode != .Debug and level == .debug) break :stderr;
        if (!state.logging.stderr) break :stderr;

        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buf);
        defer std.debug.unlockStderrWriter();

        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch break :stderr;
        nosuspend stderr.flush() catch break :stderr;
    }
}

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
    .logFn = logFn,
};

test "cli help output failures get a text output hint" {
    var buffer: [512]u8 = undefined;
    const message = formatCliActionFailureMessage(&buffer, .version, error.ActionHelpOutputUnavailable);

    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, message, "+version") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "write help text") != null);
    } else {
        try std.testing.expectEqualStrings(
            "noctty +version failed: ActionHelpOutputUnavailable\n",
            message,
        );
    }
}

test "cli invalid handle errors stay generic" {
    const actions = [_]cli.ghostty.Action{
        .@"list-keybinds",
        .@"list-themes",
        .@"list-colors",
    };

    for (actions) |action| {
        var buffer: [256]u8 = undefined;
        const message = formatCliActionFailureMessage(&buffer, action, error.InvalidHandle);

        try std.testing.expect(std.mem.indexOf(u8, message, @tagName(action)) != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "InvalidHandle") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "interactive terminal") == null);
    }
}

test "cli generic failures still mention action and error name" {
    var buffer: [256]u8 = undefined;
    const message = formatCliActionFailureMessage(&buffer, .help, error.AccessDenied);

    try std.testing.expect(std.mem.indexOf(u8, message, "+help") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "AccessDenied") != null);
}
