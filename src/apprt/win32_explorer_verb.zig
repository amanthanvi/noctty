//! Explorer "Open winghostty here" classic verbs (C13).
//!
//! Writes HKCU Directory / Directory\Background shell verbs pointing at
//! the current executable. Installer copies the same keys for per-machine
//! installs; this path covers portable / first-run.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

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

const verb_name = "winghostty";
const verb_label = "Open winghostty here";

const directory_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\Directory\\shell\\winghostty");
const directory_cmd_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\Directory\\shell\\winghostty\\command");
const background_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\Directory\\Background\\shell\\winghostty");
const background_cmd_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\Directory\\Background\\shell\\winghostty\\command");

/// Command line for a Directory verb (`%1` is the folder).
pub fn directoryCommand(exe_path: []const u8) [512]u8 {
    return formatCommand(exe_path, "%1");
}

/// Command line for a Directory\\Background verb (`%V` is the folder).
pub fn backgroundCommand(exe_path: []const u8) [512]u8 {
    return formatCommand(exe_path, "%V");
}

fn formatCommand(exe_path: []const u8, placeholder: []const u8) [512]u8 {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "\"{s}\" --working-directory=\"{s}\"", .{ exe_path, placeholder }) catch {
        buf[0] = 0;
        return buf;
    };
    if (text.len + 1 < buf.len) buf[text.len] = 0;
    return buf;
}

pub fn register(exe_path: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    registerInner(exe_path) catch |err| {
        std.log.debug("explorer verb register failed err={}", .{err});
    };
}

fn registerInner(exe_path: []const u8) !void {
    const dir_cmd = directoryCommand(exe_path);
    const bg_cmd = backgroundCommand(exe_path);
    try writeKey(directory_key, verb_label, exe_path);
    try writeDefault(directory_cmd_key, std.mem.sliceTo(&dir_cmd, 0));
    try writeKey(background_key, verb_label, exe_path);
    try writeDefault(background_cmd_key, std.mem.sliceTo(&bg_cmd, 0));
}

fn writeKey(subkey: [*:0]const u16, label: []const u8, icon: []const u8) !void {
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
    try writeSz(key, null, label);
    try writeSz(key, std.unicode.utf8ToUtf16LeStringLiteral("Icon"), icon);
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
    try writeSz(key, null, value);
}

fn writeSz(key: HKEY, name: ?[*:0]const u16, value: []const u8) !void {
    var wbuf: [1024]u16 = undefined;
    const wlen = try std.unicode.utf8ToUtf16Le(&wbuf, value);
    wbuf[wlen] = 0;
    const bytes = (wlen + 1) * 2;
    const data: [*]const u8 = @ptrCast(&wbuf);
    if (RegSetValueExW(key, name, 0, REG_SZ, data, @intCast(bytes)) != ERROR_SUCCESS)
        return error.RegSetFailed;
}

test "explorer verb command lines quote exe and placeholder" {
    const testing = std.testing;
    const dir = directoryCommand("C:\\Tools\\winghostty\\winghostty.exe");
    const text = std.mem.sliceTo(&dir, 0);
    try testing.expect(std.mem.indexOf(u8, text, "\"C:\\Tools\\winghostty\\winghostty.exe\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "--working-directory=\"%1\"") != null);

    const bg = backgroundCommand("C:\\Tools\\winghostty\\winghostty.exe");
    try testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&bg, 0), "--working-directory=\"%V\"") != null);
}
