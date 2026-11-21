// Win32 externs, the same on Zig 0.15.2 and 0.17.1 (std's file and environment APIs differ between them).
pub const HANDLE = *anyopaque;
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
pub extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, read: ?*u32, ov: ?*anyopaque) callconv(.winapi) i32;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

pub const FILE_APPEND_DATA: u32 = 0x0004;
pub const GENERIC_READ: u32 = 0x80000000;
pub const FILE_SHARE_READ: u32 = 1;
pub const FILE_SHARE_WRITE: u32 = 2;
pub const OPEN_ALWAYS: u32 = 4;
pub const OPEN_EXISTING: u32 = 3;
pub const INVALID: usize = @as(usize, @bitCast(@as(isize, -1)));

/// The value of an environment variable (ASCII names), or null.
pub fn env(comptime name: []const u8, buf: []u16) ?[]u16 {
    const w = comptime blk: {
        var a: [name.len:0]u16 = undefined;
        for (name, 0..) |c, i| a[i] = c;
        a[name.len] = 0;
        break :blk a;
    };
    const n = GetEnvironmentVariableW(&w, buf.ptr, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return null;
    return buf[0..n];
}

pub fn imageBase() usize {
    return @intFromPtr(GetModuleHandleW(null).?);
}
