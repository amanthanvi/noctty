const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const cli = @import("cli.zig");
const state = &@import("global.zig").state;

/// Enable Ctrl+C in children of the Windows GUI before any are started.
///
/// Windows-subsystem processes have no console when created, but still inherit
/// the launcher's Ctrl+C ignore attribute. Reset it once, before GUI startup,
/// rather than toggling process-wide state around concurrent child launches.
/// CLI actions can attach to a console and must exit before reaching this call.
/// Windows Terminal makes the same reset in its GUI entrypoint:
/// https://github.com/microsoft/terminal/blob/3b8c5606ee1866e7bf5c4e84e962798492282097/src/cascadia/WindowsTerminal/main.cpp#L97-L102
pub fn enableGuiChildCtrlC() !void {
    if (comptime builtin.os.tag != .windows) return;
    try windows.SetConsoleCtrlHandler(null, false);
}

test "GUI child Ctrl+C reset clears inherited ignore and is idempotent" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    // Only the test oracle reads this field; production uses the documented
    // API. Restore the runner's original ignore policy even if an assertion
    // fails, so this test cannot affect a later console-control test.
    const flags = &windows.peb().ProcessParameters.ConsoleFlags;
    const before = flags.*;
    defer windows.SetConsoleCtrlHandler(null, before & 1 != 0) catch unreachable;

    try windows.SetConsoleCtrlHandler(null, true);
    try std.testing.expect(flags.* & 1 != 0);
    try enableGuiChildCtrlC();
    try std.testing.expectEqual(before & ~@as(windows.ULONG, 1), flags.*);

    // An already enabled parent follows the same path, without a toggle or
    // a second per-launch state change.
    try enableGuiChildCtrlC();
    try std.testing.expectEqual(before & ~@as(windows.ULONG, 1), flags.*);
}

/// Give CLI output somewhere to go.
///
/// koreterm.exe is a Windows-subsystem binary, so a shell that launches it
/// directly (`koreterm.exe +version`) hands it no console and no standard
/// handles: every write fails and the action reports `WriteFailed` without
/// printing anything. Attaching to the launching process's console and binding
/// the missing handles to it makes CLI actions behave like a console program.
///
/// Handles that already work (a real console via koreterm.com, or a redirection
/// such as `koreterm.exe +version > out.txt`) are left exactly as they are.
pub fn attachParentConsole() void {
    if (comptime builtin.os.tag != .windows) return;

    const std_in = -10;
    const std_out = -11;
    const std_err = -12;

    // ATTACH_PARENT_PROCESS. Fails when the launcher has no console (started
    // from Explorer, a service, or a detached process), which is fine. A GUI
    // child can inherit valid console handles without being attached; attach
    // even then so console control events reach forwarded CLI actions.
    if (AttachConsole(0xFFFFFFFF) == 0) return;

    if (!stdHandleUsable(std_in)) bindStdHandleToConsole(std_in, "CONIN$");
    if (!stdHandleUsable(std_out)) bindStdHandleToConsole(std_out, "CONOUT$");
    if (!stdHandleUsable(std_err)) bindStdHandleToConsole(std_err, "CONOUT$");
}

/// Both helpers below are only ever reached from attachParentConsole, which has
/// already established that this is Windows.
fn stdHandleUsable(id: i32) bool {
    const handle = GetStdHandle(id);
    if (handle == null or handle == windows.INVALID_HANDLE_VALUE) return false;
    // FILE_TYPE_UNKNOWN (0) is both the error return and a legitimate answer
    // for a valid handle whose type Windows cannot classify. `GetFileType`
    // documents the difference as "clear the last error first; on success it
    // is left at NO_ERROR", so a device redirection we cannot classify must
    // stay untouched rather than be replaced with CONOUT$.
    SetLastError(0);
    if (GetFileType(handle.?) != 0) return true;
    return GetLastError() == 0;
}

fn bindStdHandleToConsole(id: i32, comptime name: []const u8) void {
    const path = std.unicode.utf8ToUtf16LeStringLiteral(name);
    const handle = CreateFileW(
        path,
        0x80000000 | 0x40000000, // GENERIC_READ | GENERIC_WRITE
        0x00000001 | 0x00000002, // FILE_SHARE_READ | FILE_SHARE_WRITE
        null,
        3, // OPEN_EXISTING
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return;
    _ = SetStdHandle(id, handle);
}

extern "kernel32" fn AttachConsole(dwProcessId: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetStdHandle(nStdHandle: i32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetStdHandle(nStdHandle: i32, hHandle: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetFileType(hFile: windows.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn SetLastError(dwErrCode: u32) callconv(.winapi) void;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

pub fn reportStateInitError(err: anyerror) !void {
    attachParentConsole();
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
                "All valid CLI actions can be listed with `koreterm +help`\n",
            .{},
        ),

        else => try stderr.print("invalid CLI invocation err={}\n", .{err}),
    }

    try stderr.flush();
}

pub fn runCliAction(action: cli.ghostty.Action, alloc: std.mem.Allocator) u8 {
    attachParentConsole();
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
                "koreterm +{s} could not write help text. Launch it from Command Prompt, PowerShell, or Windows Terminal, or redirect the output to a file.\n",
                .{@tagName(action)},
            ) catch "koreterm CLI action failed.\n";
        }
    }

    return std.fmt.bufPrint(
        buf,
        "koreterm +{s} failed: {s}\n",
        .{ @tagName(action), @errorName(err) },
    ) catch "koreterm CLI action failed.\n";
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

    const caption = std.unicode.utf8ToUtf16LeStringLiteral("koreterm CLI action failed");
    const fallback = std.unicode.utf8ToUtf16LeStringLiteral("koreterm CLI action failed.");

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

/// The application's panic handler (the thin console launcher uses no_panic).
/// Debug and ReleaseSafe keep Zig's
/// default: the message and a symbolized stack trace. ReleaseFast and
/// ReleaseSmall print the message and trap, because the default handler pulls
/// std.debug's whole PDB/DWARF symbolizer into any image that keeps debug
/// info (-Dstrip=false, which is how the release symbols zip is built): about
/// 114 KB of .text that a stripped build replaces with "Unable to dump stack
/// trace: debug info stripped". The trap raises an exception, so the minidump
/// filter still writes a dump, and the dump is what the symbols zip reads.
pub const panic = switch (builtin.mode) {
    .Debug, .ReleaseSafe => std.debug.FullPanic(std.debug.defaultPanic),
    .ReleaseFast, .ReleaseSmall => std.debug.FullPanic(releasePanic),
};

fn releasePanic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    const stderr = std.fs.File.stderr();
    stderr.writeAll("panic: ") catch {};
    stderr.writeAll(msg) catch {};
    stderr.writeAll("\n") catch {};
    @trap();
}

// The attach must never disturb a handle that already works, or redirection
// (`koreterm.exe +version > out.txt`) and the koreterm.com launcher would break.
// The test runner's own stdout is a live handle, so it stands in for both.
test "cli console attach leaves working std handles alone" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const std_out = -11;
    try std.testing.expect(stdHandleUsable(std_out));

    const before = GetStdHandle(std_out);
    attachParentConsole();
    try std.testing.expectEqual(before, GetStdHandle(std_out));
}

test "cli help output failures get a text output hint" {
    var buffer: [512]u8 = undefined;
    const message = formatCliActionFailureMessage(&buffer, .version, error.ActionHelpOutputUnavailable);

    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, message, "+version") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "write help text") != null);
    } else {
        try std.testing.expectEqualStrings(
            "koreterm +version failed: ActionHelpOutputUnavailable\n",
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
