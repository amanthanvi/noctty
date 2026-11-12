//! "Create shortcuts": a noctty.lnk on the Desktop and in the Start menu's
//! Programs folder, pointing at the running noctty.exe (a portable copy's
//! own path), with its icon, its folder as the working directory, and
//! noctty's AppUserModelID so the taskbar groups its windows under it.

const std = @import("std");
const windows = std.os.windows;
const win32_aumid = @import("../win32_aumid.zig");
const sys = @import("sys.zig");

const GUID = windows.GUID;
const HRESULT = windows.HRESULT;

const CLSCTX_INPROC_SERVER: u32 = 0x1;
const CLSID_ShellLink = GUID.parse("{00021401-0000-0000-C000-000000000046}");
const IID_IShellLinkW = GUID.parse("{000214F9-0000-0000-C000-000000000046}");
const IID_IPersistFile = GUID.parse("{0000010B-0000-0000-C000-000000000046}");
const IID_IPropertyStore = GUID.parse("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}");
const FOLDERID_Desktop = GUID.parse("{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}");
const FOLDERID_Programs = GUID.parse("{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}");

const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };
const PKEY_AppUserModel_ID = PROPERTYKEY{ .fmtid = GUID.parse("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"), .pid = 5 };
const PROPVARIANT = extern struct {
    vt: u16,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    value: extern union { pwsz: [*:0]const u16, raw: [2]usize },
};
const VT_LPWSTR: u16 = 31;

const Unknown = *const fn (*anyopaque) callconv(.winapi) u32;
const QueryInterface = *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT;
const Slot = *const anyopaque;

const IShellLinkWVtbl = extern struct {
    QueryInterface: QueryInterface,
    AddRef: Unknown,
    Release: Unknown,
    GetPath: Slot,
    GetIDList: Slot,
    SetIDList: Slot,
    GetDescription: Slot,
    SetDescription: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetWorkingDirectory: Slot,
    SetWorkingDirectory: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetArguments: Slot,
    SetArguments: Slot,
    GetHotkey: Slot,
    SetHotkey: Slot,
    GetShowCmd: Slot,
    SetShowCmd: Slot,
    GetIconLocation: Slot,
    SetIconLocation: *const fn (*anyopaque, [*:0]const u16, i32) callconv(.winapi) HRESULT,
    SetRelativePath: Slot,
    Resolve: Slot,
    SetPath: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
};

const IPersistFileVtbl = extern struct {
    QueryInterface: QueryInterface,
    AddRef: Unknown,
    Release: Unknown,
    GetClassID: Slot,
    IsDirty: Slot,
    Load: Slot,
    Save: *const fn (*anyopaque, [*:0]const u16, windows.BOOL) callconv(.winapi) HRESULT,
    SaveCompleted: Slot,
    GetCurFile: Slot,
};

const IPropertyStoreVtbl = extern struct {
    QueryInterface: QueryInterface,
    AddRef: Unknown,
    Release: Unknown,
    GetCount: Slot,
    GetAt: Slot,
    GetValue: Slot,
    SetValue: *const fn (*anyopaque, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
    Commit: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

fn Com(comptime Vtbl: type) type {
    return extern struct {
        vtbl: *const Vtbl,
        fn raw(self: *@This()) *anyopaque {
            return @ptrCast(self);
        }
        fn release(self: *@This()) void {
            _ = self.vtbl.Release(self.raw());
        }
    };
}

extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: u32, token: ?*anyopaque, path: *?[*:0]u16) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;

pub const Where = enum { desktop, start_menu };

/// The shortcut's full path in `where`, or null when Windows gives no folder.
fn linkPath(alloc: std.mem.Allocator, where: Where) !?[:0]u16 {
    var folder: ?[*:0]u16 = null;
    const id = switch (where) {
        .desktop => &FOLDERID_Desktop,
        .start_menu => &FOLDERID_Programs,
    };
    if (SHGetKnownFolderPath(id, 0, null, &folder) < 0 or folder == null) return null;
    defer CoTaskMemFree(folder);
    const dir = std.mem.span(folder.?);
    const name = std.unicode.utf8ToUtf16LeStringLiteral("\\noctty.lnk");
    const out = try alloc.allocSentinel(u16, dir.len + name.len, 0);
    @memcpy(out[0..dir.len], dir);
    @memcpy(out[dir.len..], name);
    return out;
}

/// Write noctty.lnk in `where`, replacing one already there.
pub fn create(alloc: std.mem.Allocator, where: Where) !void {
    // The UI thread has an apartment already; this only makes sure.
    _ = CoInitializeEx(null, 0x2);

    var exe_buf: [32768]u16 = undefined;
    const exe_len = windows.kernel32.GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    if (exe_len == 0 or exe_len >= exe_buf.len) return error.NoExecutablePath;
    exe_buf[exe_len] = 0;
    const exe: [:0]const u16 = exe_buf[0..exe_len :0];
    var dir_buf: [32768]u16 = undefined;
    const slash = std.mem.lastIndexOfScalar(u16, exe, '\\') orelse return error.NoExecutablePath;
    @memcpy(dir_buf[0..slash], exe[0..slash]);
    dir_buf[slash] = 0;
    const dir: [:0]const u16 = dir_buf[0..slash :0];

    const target = (try linkPath(alloc, where)) orelse return error.NoFolder;
    defer alloc.free(target);

    var raw: ?*anyopaque = null;
    if (sys.CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &raw) < 0 or raw == null)
        return error.ShellLinkUnavailable;
    const link: *Com(IShellLinkWVtbl) = @ptrCast(@alignCast(raw.?));
    defer link.release();
    if (link.vtbl.SetPath(link.raw(), exe.ptr) < 0) return error.ShellLinkFailed;
    _ = link.vtbl.SetWorkingDirectory(link.raw(), dir.ptr);
    _ = link.vtbl.SetIconLocation(link.raw(), exe.ptr, 0);
    _ = link.vtbl.SetDescription(link.raw(), std.unicode.utf8ToUtf16LeStringLiteral("noctty terminal"));

    var store_raw: ?*anyopaque = null;
    if (link.vtbl.QueryInterface(link.raw(), &IID_IPropertyStore, &store_raw) >= 0 and store_raw != null) {
        const store: *Com(IPropertyStoreVtbl) = @ptrCast(@alignCast(store_raw.?));
        defer store.release();
        const aumid = std.unicode.utf8ToUtf16LeStringLiteral(win32_aumid.aumid_utf8);
        const value: PROPVARIANT = .{ .vt = VT_LPWSTR, .value = .{ .pwsz = aumid } };
        if (store.vtbl.SetValue(store.raw(), &PKEY_AppUserModel_ID, &value) >= 0) _ = store.vtbl.Commit(store.raw());
    }

    var file_raw: ?*anyopaque = null;
    if (link.vtbl.QueryInterface(link.raw(), &IID_IPersistFile, &file_raw) < 0 or file_raw == null)
        return error.ShellLinkFailed;
    const file: *Com(IPersistFileVtbl) = @ptrCast(@alignCast(file_raw.?));
    defer file.release();
    if (file.vtbl.Save(file.raw(), target.ptr, windows.TRUE) < 0) return error.SaveFailed;
}

test "the COM vtables keep the slots they call at Windows' offsets" {
    const p = @sizeOf(usize);
    try std.testing.expectEqual(20 * p, @offsetOf(IShellLinkWVtbl, "SetPath"));
    try std.testing.expectEqual(17 * p, @offsetOf(IShellLinkWVtbl, "SetIconLocation"));
    try std.testing.expectEqual(9 * p, @offsetOf(IShellLinkWVtbl, "SetWorkingDirectory"));
    try std.testing.expectEqual(6 * p, @offsetOf(IPersistFileVtbl, "Save"));
    try std.testing.expectEqual(6 * p, @offsetOf(IPropertyStoreVtbl, "SetValue"));
}
