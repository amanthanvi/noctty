//! Taskbar jump list of recent working directories (C12).
//!
//! Best-effort: COM failures log and return. Recent paths are owned by
//! the caller; this module only builds IShellLink entries.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const win32_aumid = @import("win32_aumid.zig");

const HRESULT = windows.HRESULT;
const DWORD = windows.DWORD;
const ULONG = windows.ULONG;
const GUID = windows.GUID;

const S_OK: HRESULT = 0;
const CLSCTX_INPROC_SERVER: DWORD = 0x1;
const COINIT_APARTMENTTHREADED: DWORD = 0x2;
const SLGP_RAWPATH: DWORD = 0x4;

const CLSID_DestinationList = GUID{
    .Data1 = 0x77f10cf0,
    .Data2 = 0x3db5,
    .Data3 = 0x4966,
    .Data4 = .{ 0xb5, 0x20, 0xb7, 0xc5, 0x4f, 0xd3, 0x5e, 0xd6 },
};
const IID_ICustomDestinationList = GUID{
    .Data1 = 0x6332debf,
    .Data2 = 0x87b5,
    .Data3 = 0x4670,
    .Data4 = .{ 0x90, 0xc0, 0x5e, 0x57, 0xb4, 0x08, 0xa4, 0x9e },
};
const CLSID_EnumerableObjectCollection = GUID{
    .Data1 = 0x2d3468c1,
    .Data2 = 0x36a7,
    .Data3 = 0x43b6,
    .Data4 = .{ 0xac, 0x24, 0xd3, 0xf0, 0x2f, 0xd9, 0x60, 0x7a },
};
const IID_IObjectCollection = GUID{
    .Data1 = 0x5632b1a4,
    .Data2 = 0xe38a,
    .Data3 = 0x400a,
    .Data4 = .{ 0x92, 0x8a, 0xd4, 0xcd, 0x63, 0x23, 0x02, 0x95 },
};
const IID_IObjectArray = GUID{
    .Data1 = 0x92ca9dcd,
    .Data2 = 0x5622,
    .Data3 = 0x4bba,
    .Data4 = .{ 0xa8, 0x05, 0x5e, 0x9f, 0x54, 0x1b, 0xd8, 0xc9 },
};
const CLSID_ShellLink = GUID{
    .Data1 = 0x00021401,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const IID_IShellLinkW = GUID{
    .Data1 = 0x000214f9,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const IID_IUnknown = GUID{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IUnknown = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IUnknown) callconv(.winapi) ULONG,
        Release: *const fn (*IUnknown) callconv(.winapi) ULONG,
    };
};

extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: DWORD,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub const max_recent = 10;

/// Pure MRU helper: newest first, case-insensitive path match, cap `max`.
pub fn rememberPath(store: [][]u8, count: *usize, alloc: std.mem.Allocator, path: []const u8, max: usize) !void {
    var i: usize = 0;
    while (i < count.*) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(store[i], path)) {
            const existing = store[i];
            var j = i;
            while (j > 0) : (j -= 1) store[j] = store[j - 1];
            store[0] = existing;
            return;
        }
    }

    const owned = try alloc.dupe(u8, path);
    if (count.* == max) {
        alloc.free(store[max - 1]);
        count.* -= 1;
    }
    var j = count.*;
    while (j > 0) : (j -= 1) store[j] = store[j - 1];
    store[0] = owned;
    count.* += 1;
}

pub fn publish(exe_path: []const u8, recent: []const []const u8) void {
    publishCategories(exe_path, recent, &.{});
}

pub fn publishCategories(
    exe_path: []const u8,
    recent: []const []const u8,
    layouts: []const []const u8,
) void {
    if (comptime builtin.os.tag != .windows) return;
    if (recent.len == 0 and layouts.len == 0) return;
    publishInner(exe_path, recent, layouts) catch |err| {
        std.log.debug("jump list publish failed err={}", .{err});
    };
}

fn publishInner(
    exe_path: []const u8,
    recent: []const []const u8,
    layouts: []const []const u8,
) !void {
    var dest_ptr: ?*anyopaque = null;
    var hr = CoCreateInstance(&CLSID_DestinationList, null, CLSCTX_INPROC_SERVER, &IID_ICustomDestinationList, &dest_ptr);
    if (hr != S_OK or dest_ptr == null) return error.CoCreateFailed;
    const dest: *IUnknown = @ptrCast(@alignCast(dest_ptr.?));
    defer _ = dest.vtbl.Release(dest);

    // ICustomDestinationList vtable after IUnknown: SetAppID, BeginList,
    // AppendCategory, AppendKnownCategory, AddUserTasks, CommitList, ...
    const dest_vtbl: *const DestVtbl = @ptrCast(dest.vtbl);

    const aumid = std.unicode.utf8ToUtf16LeStringLiteral(win32_aumid.aumid_utf8);
    hr = dest_vtbl.SetAppID(dest, aumid);
    if (hr != S_OK) return error.SetAppIdFailed;

    var min_slots: u32 = 0;
    var removed: ?*anyopaque = null;
    hr = dest_vtbl.BeginList(dest, &min_slots, &IID_IObjectArray, &removed);
    if (hr != S_OK) return error.BeginListFailed;
    if (removed) |ptr| {
        const unk: *IUnknown = @ptrCast(@alignCast(ptr));
        _ = unk.vtbl.Release(unk);
    }

    var exe_w_buf: [32768]u16 = undefined;
    const exe_w_len = try std.unicode.utf8ToUtf16Le(&exe_w_buf, exe_path);
    exe_w_buf[exe_w_len] = 0;
    const exe_w = exe_w_buf[0..exe_w_len :0];

    if (recent.len > 0) {
        try appendLinkCategory(dest, dest_vtbl, exe_w, recent, "Recent directories", createDirLink);
    }
    if (layouts.len > 0) {
        try appendLinkCategory(dest, dest_vtbl, exe_w, layouts, "Layouts", createLayoutLink);
    }
    hr = dest_vtbl.CommitList(dest);
    if (hr != S_OK) return error.CommitListFailed;
}

const DestVtbl = extern struct {
    unknown: IUnknown.Vtbl,
    SetAppID: *const fn (*IUnknown, [*:0]const u16) callconv(.winapi) HRESULT,
    BeginList: *const fn (*IUnknown, *u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AppendCategory: *const fn (*IUnknown, [*:0]const u16, *IUnknown) callconv(.winapi) HRESULT,
    AppendKnownCategory: *const fn (*IUnknown, u32) callconv(.winapi) HRESULT,
    AddUserTasks: *const fn (*IUnknown, *IUnknown) callconv(.winapi) HRESULT,
    CommitList: *const fn (*IUnknown) callconv(.winapi) HRESULT,
};

fn appendLinkCategory(
    dest: *IUnknown,
    dest_vtbl: *const DestVtbl,
    exe_w: [:0]const u16,
    items: []const []const u8,
    category_utf8: []const u8,
    make_link: *const fn ([:0]const u16, []const u8) anyerror!*IUnknown,
) !void {
    var coll_ptr: ?*anyopaque = null;
    var hr = CoCreateInstance(&CLSID_EnumerableObjectCollection, null, CLSCTX_INPROC_SERVER, &IID_IObjectCollection, &coll_ptr);
    if (hr != S_OK or coll_ptr == null) return error.CollectionFailed;
    const coll: *IUnknown = @ptrCast(@alignCast(coll_ptr.?));
    defer _ = coll.vtbl.Release(coll);

    const CollVtbl = extern struct {
        unknown: IUnknown.Vtbl,
        GetCount: *const fn (*IUnknown, *u32) callconv(.winapi) HRESULT,
        GetAt: *const fn (*IUnknown, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddObject: *const fn (*IUnknown, *IUnknown) callconv(.winapi) HRESULT,
        AddFromArray: *const fn (*IUnknown, *IUnknown) callconv(.winapi) HRESULT,
        RemoveObjectAt: *const fn (*IUnknown, u32) callconv(.winapi) HRESULT,
        Clear: *const fn (*IUnknown) callconv(.winapi) HRESULT,
    };
    const coll_vtbl: *const CollVtbl = @ptrCast(coll.vtbl);

    for (items) |item| {
        const link = make_link(exe_w, item) catch continue;
        defer _ = link.vtbl.Release(link);
        _ = coll_vtbl.AddObject(coll, link);
    }

    var cat_w: [64]u16 = undefined;
    const cat_len = try std.unicode.utf8ToUtf16Le(&cat_w, category_utf8);
    cat_w[cat_len] = 0;
    hr = dest_vtbl.AppendCategory(dest, @ptrCast(&cat_w), coll);
    if (hr != S_OK) return error.AppendCategoryFailed;
}

fn createDirLink(exe_w: [:0]const u16, dir: []const u8) !*IUnknown {
    var args_buf: [1024]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "--working-directory={s}", .{dir});
    return createArgLink(exe_w, args, dir, true);
}

fn createLayoutLink(exe_w: [:0]const u16, name: []const u8) !*IUnknown {
    var args_buf: [160]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "--apply-layout={s}", .{name});
    return createArgLink(exe_w, args, name, false);
}

fn createArgLink(exe_w: [:0]const u16, args: []const u8, desc: []const u8, set_cwd: bool) !*IUnknown {
    var link_ptr: ?*anyopaque = null;
    const hr = CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, &link_ptr);
    if (hr != S_OK or link_ptr == null) return error.ShellLinkFailed;
    const link: *IUnknown = @ptrCast(@alignCast(link_ptr.?));
    errdefer _ = link.vtbl.Release(link);

    const LinkVtbl = extern struct {
        unknown: IUnknown.Vtbl,
        GetPath: *const fn (*IUnknown, [*]u16, i32, ?*anyopaque, DWORD) callconv(.winapi) HRESULT,
        GetIDList: *const fn (*IUnknown, *?*anyopaque) callconv(.winapi) HRESULT,
        SetIDList: *const fn (*IUnknown, ?*anyopaque) callconv(.winapi) HRESULT,
        GetDescription: *const fn (*IUnknown, [*]u16, i32) callconv(.winapi) HRESULT,
        SetDescription: *const fn (*IUnknown, [*:0]const u16) callconv(.winapi) HRESULT,
        GetWorkingDirectory: *const fn (*IUnknown, [*]u16, i32) callconv(.winapi) HRESULT,
        SetWorkingDirectory: *const fn (*IUnknown, [*:0]const u16) callconv(.winapi) HRESULT,
        GetArguments: *const fn (*IUnknown, [*]u16, i32) callconv(.winapi) HRESULT,
        SetArguments: *const fn (*IUnknown, [*:0]const u16) callconv(.winapi) HRESULT,
        GetHotkey: *const fn (*IUnknown, *u16) callconv(.winapi) HRESULT,
        SetHotkey: *const fn (*IUnknown, u16) callconv(.winapi) HRESULT,
        GetShowCmd: *const fn (*IUnknown, *i32) callconv(.winapi) HRESULT,
        SetShowCmd: *const fn (*IUnknown, i32) callconv(.winapi) HRESULT,
        GetIconLocation: *const fn (*IUnknown, [*]u16, i32, *i32) callconv(.winapi) HRESULT,
        SetIconLocation: *const fn (*IUnknown, [*:0]const u16, i32) callconv(.winapi) HRESULT,
        SetRelativePath: *const fn (*IUnknown, [*:0]const u16, DWORD) callconv(.winapi) HRESULT,
        Resolve: *const fn (*IUnknown, ?*anyopaque, DWORD) callconv(.winapi) HRESULT,
        SetPath: *const fn (*IUnknown, [*:0]const u16) callconv(.winapi) HRESULT,
    };
    const link_vtbl: *const LinkVtbl = @ptrCast(link.vtbl);

    _ = link_vtbl.SetPath(link, exe_w.ptr);
    _ = link_vtbl.SetIconLocation(link, exe_w.ptr, 0);

    var args_w: [1024]u16 = undefined;
    const args_w_len = try std.unicode.utf8ToUtf16Le(&args_w, args);
    args_w[args_w_len] = 0;
    _ = link_vtbl.SetArguments(link, @ptrCast(&args_w));

    var desc_w: [260]u16 = undefined;
    const desc_len = try std.unicode.utf8ToUtf16Le(&desc_w, desc);
    desc_w[desc_len] = 0;
    _ = link_vtbl.SetDescription(link, @ptrCast(&desc_w));
    if (set_cwd) _ = link_vtbl.SetWorkingDirectory(link, @ptrCast(&desc_w));

    return link;
}

test "rememberPath moves existing to front and caps" {
    const testing = std.testing;
    var store: [4][]u8 = undefined;
    var count: usize = 0;

    try rememberPath(&store, &count, testing.allocator, "C:\\a", 3);
    try rememberPath(&store, &count, testing.allocator, "C:\\b", 3);
    try rememberPath(&store, &count, testing.allocator, "C:\\c", 3);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("C:\\c", store[0]);

    try rememberPath(&store, &count, testing.allocator, "C:\\a", 3);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("C:\\a", store[0]);
    try testing.expectEqualStrings("C:\\c", store[1]);

    try rememberPath(&store, &count, testing.allocator, "C:\\d", 3);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("C:\\d", store[0]);
    try testing.expectEqualStrings("C:\\a", store[1]);

    var i: usize = 0;
    while (i < count) : (i += 1) testing.allocator.free(store[i]);
}
