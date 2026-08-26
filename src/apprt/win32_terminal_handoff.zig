//! Default-terminal registration (`ITerminalHandoff`) plumbing (C11).
//!
//! Writes the COM LocalServer32 + ProgID keys so winghostty can appear
//! as a default-terminal candidate. Does **not** set
//! `HKCU\Console\%%Startup\DelegationTerminal` automatically — that
//! would capture Explorer/IDE consoles before pipe-attach exists.
//!
//! ponytail: full ITerminalHandoff pipe attach (route the handed-off
//! HPCON into a new tab) is the remaining M slice. Registering
//! DelegationTerminal before that lands would spawn empty windows.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const clsid_utf8 = "{8F1E2C10-6A4B-4D3E-9C7A-2B11E4A90C11}";
pub const prog_id = "winghostty.TerminalHandoff";
pub const display_name = "Ghostty (winghostty)";

const HKEY = *opaque {};
const REGSAM = u32;
const DWORD = windows.DWORD;
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_WRITE: REGSAM = 0x20006;
const REG_OPTION_NON_VOLATILE: DWORD = 0;
const REG_SZ: DWORD = 1;
const ERROR_SUCCESS: i32 = 0;

extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const u16,
    Reserved: DWORD,
    lpClass: ?[*:0]const u16,
    dwOptions: DWORD,
    samDesired: REGSAM,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.winapi) i32;

extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: ?[*:0]const u16,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const u8,
    cbData: DWORD,
) callconv(.winapi) i32;

extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

const clsid_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\CLSID\\" ++ clsid_utf8);
const local_server_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\CLSID\\" ++ clsid_utf8 ++ "\\LocalServer32");
const progid_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\CLSID\\" ++ clsid_utf8 ++ "\\ProgID");
const progid_clsid_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\" ++ prog_id ++ "\\CLSID");

pub fn localServerCommand(exe_path: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, "\"{s}\" --terminal-handoff", .{exe_path});
}

pub fn delegationKey() []const u8 {
    return "Software\\Microsoft\\Windows\\CurrentVersion\\Console\\%%Startup";
}

pub fn clsidKey() []const u8 {
    return "Software\\Classes\\CLSID\\" ++ clsid_utf8;
}

/// Opt-in COM advertisement only. Callers that want to become the OS
/// default must also write DelegationTerminal after pipe-attach ships.
pub fn registerLocalServer(exe_path: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    registerInner(exe_path) catch |err| {
        std.log.debug("terminal handoff COM register failed err={}", .{err});
    };
}

fn registerInner(exe_path: []const u8) !void {
    var cmd_buf: [512]u8 = undefined;
    const cmd = try localServerCommand(exe_path, &cmd_buf);
    try writeDefault(clsid_key, display_name);
    try writeDefault(local_server_key, cmd);
    try writeDefault(progid_key, prog_id);
    try writeDefault(progid_clsid_key, clsid_utf8);
    std.log.info("terminal handoff COM advertised clsid={s} (DelegationTerminal not set)", .{clsid_utf8});
}

fn writeDefault(subkey: [*:0]const u16, value: []const u8) !void {
    var key: HKEY = undefined;
    if (RegCreateKeyExW(
        HKEY_CURRENT_USER,
        subkey,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE,
        null,
        &key,
        null,
    ) != ERROR_SUCCESS) return error.RegCreateFailed;
    defer _ = RegCloseKey(key);

    var wbuf: [1024]u16 = undefined;
    const wlen = try std.unicode.utf8ToUtf16Le(&wbuf, value);
    wbuf[wlen] = 0;
    const bytes = (wlen + 1) * 2;
    const data: [*]const u8 = @ptrCast(&wbuf);
    if (RegSetValueExW(key, null, 0, REG_SZ, data, @intCast(bytes)) != ERROR_SUCCESS)
        return error.RegSetFailed;
}

test "localServerCommand points at handoff switch" {
    var buf: [256]u8 = undefined;
    const cmd = try localServerCommand("C:\\apps\\winghostty\\winghostty.exe", &buf);
    try std.testing.expectEqualStrings("\"C:\\apps\\winghostty\\winghostty.exe\" --terminal-handoff", cmd);
    try std.testing.expect(std.mem.indexOf(u8, clsidKey(), clsid_utf8) != null);
}
