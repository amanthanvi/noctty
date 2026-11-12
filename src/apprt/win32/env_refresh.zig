//! The environment Windows gives a newly started program, read again when
//! it changes: `setx` and the System Properties dialog write the registry
//! and broadcast `WM_SETTINGCHANGE` "Environment". Explorer and Windows
//! Terminal then rebuild their own environment; koreterm does the same
//! (`refresh`), so the next tab or split a profile starts sees the change.
//! A shell already running keeps its own copy, as on Windows anywhere.
//!
//! A variable the registry no longer sets is left as it is in koreterm's
//! environment, and one koreterm set itself, or was started with, stays
//! unless the registry sets the same name. Nothing here logs a name or a
//! value.
const std = @import("std");
const windows = std.os.windows;

const log = std.log.scoped(.win32_env_refresh);

extern "advapi32" fn OpenProcessToken(process: windows.HANDLE, access: u32, token: *?windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "userenv" fn CreateEnvironmentBlock(block: *?[*]u16, token: ?windows.HANDLE, inherit: windows.BOOL) callconv(.winapi) windows.BOOL;
extern "userenv" fn DestroyEnvironmentBlock(block: [*]u16) callconv(.winapi) windows.BOOL;

const TOKEN_QUERY: u32 = 0x0008;
const TOKEN_DUPLICATE: u32 = 0x0002;
const TOKEN_IMPERSONATE: u32 = 0x0004;

/// Whether a `WM_SETTINGCHANGE` names the environment.
pub fn namesEnvironment(name: ?[:0]const u16) bool {
    const text = name orelse return false;
    return std.mem.eql(u16, text, std.unicode.utf8ToUtf16LeStringLiteral("Environment"));
}

/// Set every variable of the registry's current environment for this user
/// in koreterm's own environment, which new panes inherit. Returns how many
/// were set, or null when Windows could not build the environment.
pub fn refresh() ?usize {
    var token: ?windows.HANDLE = null;
    if (OpenProcessToken(windows.GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_IMPERSONATE, &token) == 0) {
        log.warn("environment refresh: no process token", .{});
        return null;
    }
    defer windows.CloseHandle(token.?);
    var block: ?[*]u16 = null;
    if (CreateEnvironmentBlock(&block, token, 0) == 0 or block == null) {
        log.warn("environment refresh: Windows built no environment", .{});
        return null;
    }
    defer _ = DestroyEnvironmentBlock(block.?);
    var it = Entries{ .at = block.? };
    var count: usize = 0;
    while (it.next()) |entry| {
        if (windows.kernel32.SetEnvironmentVariableW(entry.name, entry.value) != 0) count += 1;
    }
    log.info("environment refresh: variables={d}", .{count});
    return count;
}

/// The `NAME=VALUE` strings of an environment block, each split in place.
/// A name starting with `=` (a drive's current directory) is skipped.
const Entries = struct {
    at: [*]u16,
    name_buf: [256]u16 = undefined,

    const Entry = struct { name: [*:0]const u16, value: [*:0]const u16 };

    fn next(self: *Entries) ?Entry {
        while (true) {
            const line = std.mem.span(@as([*:0]u16, @ptrCast(self.at)));
            if (line.len == 0) return null;
            self.at += line.len + 1;
            if (line[0] == '=') continue;
            const eq = std.mem.indexOfScalar(u16, line, '=') orelse continue;
            if (eq >= self.name_buf.len) continue;
            @memcpy(self.name_buf[0..eq], line[0..eq]);
            self.name_buf[eq] = 0;
            const value: [*:0]const u16 = @ptrCast(line.ptr + eq + 1);
            return .{ .name = @ptrCast(&self.name_buf), .value = value };
        }
    }
};

test "env refresh: an environment block splits into names and values" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var block = L("=C:=C:\\x\x00PATH=C:\\bin\x00A=b=c\x00\x00").*;
    var it = Entries{ .at = @ptrCast(&block) };
    const first = it.next().?;
    try std.testing.expectEqualSlices(u16, L("PATH"), std.mem.span(first.name));
    try std.testing.expectEqualSlices(u16, L("C:\\bin"), std.mem.span(first.value));
    const second = it.next().?;
    try std.testing.expectEqualSlices(u16, L("A"), std.mem.span(second.name));
    try std.testing.expectEqualSlices(u16, L("b=c"), std.mem.span(second.value));
    try std.testing.expect(it.next() == null);
}

test "env refresh: only the Environment setting names it" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(namesEnvironment(L("Environment")));
    try std.testing.expect(!namesEnvironment(L("ImmersiveColorSet")));
    try std.testing.expect(!namesEnvironment(null));
}
