//! The windows Settings shows to import connections from a Terminals export
//! (`terminals_import.zig`): the file picker (`pickFile`) and a modal dialog
//! that lists the connections with a check box each (`choose`).
//!
//! Neither logs a path or anything the export holds.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");

const BOOL = win32_types.BOOL;
const DWORD = win32_types.DWORD;
const HINSTANCE = win32_types.HINSTANCE;
const HWND = win32_types.HWND;
const LPARAM = win32_types.LPARAM;
const LPCWSTR = win32_types.LPCWSTR;
const LRESULT = win32_types.LRESULT;
const POINT = win32_types.POINT;
const UINT = win32_types.UINT;
const WORD = win32_types.WORD;
const WPARAM = win32_types.WPARAM;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

// commdlg.h packs OPENFILENAMEW at 1 only for 32-bit targets: natural
// alignment on x64 (152 bytes, pinned below).
const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: ?HWND,
    hInstance: ?HINSTANCE,
    lpstrFilter: ?LPCWSTR,
    lpstrCustomFilter: ?[*]u16,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: [*]u16,
    nMaxFile: DWORD,
    lpstrFileTitle: ?[*]u16,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: ?LPCWSTR,
    lpstrTitle: ?LPCWSTR,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: ?LPCWSTR,
    lCustData: LPARAM,
    lpfnHook: ?*anyopaque,
    lpTemplateName: ?LPCWSTR,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};

const OFN_HIDEREADONLY: DWORD = 0x4;
const OFN_NOCHANGEDIR: DWORD = 0x8;
const OFN_PATHMUSTEXIST: DWORD = 0x800;
const OFN_FILEMUSTEXIST: DWORD = 0x1000;
const OFN_EXPLORER: DWORD = 0x80000;

extern "comdlg32" fn GetOpenFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;

const DLGPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize;
extern "user32" fn DialogBoxIndirectParamW(hInstance: ?HINSTANCE, template: *const anyopaque, parent: ?HWND, proc: DLGPROC, init: LPARAM) callconv(.winapi) isize;
extern "user32" fn EndDialog(hDlg: HWND, result: isize) callconv(.winapi) BOOL;
extern "user32" fn GetDlgItem(hDlg: HWND, id: i32) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

const INITCOMMONCONTROLSEX = extern struct { dwSize: DWORD, dwICC: DWORD };
const ICC_LISTVIEW_CLASSES: DWORD = 0x1;
extern "comctl32" fn InitCommonControlsEx(init: *const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;

/// The path of the file the person picked, or null when they cancelled (or
/// the dialog failed). `buf` holds it.
pub fn pickFile(owner: ?HWND, buf: []u16) ?[:0]const u16 {
    return pickFileWith(owner, buf, L("Terminals export (*.xml)\x00*.xml\x00All files (*.*)\x00*.*\x00"), L("Import profiles from a Terminals export"));
}

/// `pickFile` with its own filter (`Name\0pattern\0...\0`) and title.
pub fn pickFileWith(owner: ?HWND, buf: []u16, filter: LPCWSTR, title: LPCWSTR) ?[:0]const u16 {
    std.debug.assert(buf.len > 1);
    buf[0] = 0;
    var ofn: OPENFILENAMEW = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = filter;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = buf.ptr;
    ofn.nMaxFile = @intCast(@min(buf.len, std.math.maxInt(DWORD)));
    ofn.lpstrTitle = title;
    // NOCHANGEDIR: the app's current directory stays where it was.
    ofn.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR;
    if (GetOpenFileNameW(&ofn) == 0) return null;
    const len = std.mem.indexOfScalar(u16, buf, 0) orelse return null;
    if (len == 0) return null;
    return buf[0..len :0];
}

const OFN_OVERWRITEPROMPT: DWORD = 0x2;
extern "comdlg32" fn GetSaveFileNameW(ofn: *OPENFILENAMEW) callconv(.winapi) BOOL;

/// The path the person picked to save to, or null when they cancelled.
/// `buf` holds it and starts as `default_name`. `filter` is a
/// double-NUL-terminated filter list; `ext` is added when typed without one.
pub fn pickSaveFile(owner: ?HWND, buf: []u16, title: [*:0]const u16, filter: [*:0]const u16, ext: [*:0]const u16, default_name: []const u16) ?[:0]const u16 {
    std.debug.assert(buf.len > default_name.len);
    @memcpy(buf[0..default_name.len], default_name);
    buf[default_name.len] = 0;
    var ofn: OPENFILENAMEW = std.mem.zeroes(OPENFILENAMEW);
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = filter;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = buf.ptr;
    ofn.nMaxFile = @intCast(@min(buf.len, std.math.maxInt(DWORD)));
    ofn.lpstrTitle = title;
    ofn.lpstrDefExt = ext;
    ofn.Flags = OFN_EXPLORER | OFN_PATHMUSTEXIST | OFN_HIDEREADONLY | OFN_NOCHANGEDIR | OFN_OVERWRITEPROMPT;
    if (GetSaveFileNameW(&ofn) == 0) return null;
    const len = std.mem.indexOfScalar(u16, buf, 0) orelse return null;
    if (len == 0) return null;
    return buf[0..len :0];
}

/// A connection as the dialog lists it.
pub const Item = struct {
    name: []const u8,
    kind: []const u8,
    server: []const u8,
    /// Why it cannot be imported, or that it is a profile already.
    note: []const u8,
    /// It can be checked.
    selectable: bool,
    /// In: checked when the dialog opens. Out: checked when Import was
    /// pressed.
    checked: bool,
};

const id_intro: u16 = 100;
const id_list: u16 = 101;
const id_toggle: u16 = 102;
const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;

const DWLP_MSGRESULT: i32 = 0;
const DWLP_USER: i32 = @sizeOf(usize) * 2;

const WM_INITDIALOG: UINT = 0x0110;
const WM_COMMAND: UINT = 0x0111;
const WM_NOTIFY: UINT = 0x004E;
const WM_CLOSE: UINT = 0x0010;

const LVM_FIRST: UINT = 0x1000;
const LVM_SETITEMSTATE: UINT = LVM_FIRST + 43;
const LVM_GETITEMSTATE: UINT = LVM_FIRST + 44;
const LVM_SETCOLUMNWIDTH: UINT = LVM_FIRST + 30;
const LVM_SETEXTENDEDLISTVIEWSTYLE: UINT = LVM_FIRST + 54;
const LVM_INSERTITEMW: UINT = LVM_FIRST + 77;
const LVM_INSERTCOLUMNW: UINT = LVM_FIRST + 97;
const LVM_SETITEMTEXTW: UINT = LVM_FIRST + 116;
const LVS_EX_CHECKBOXES: usize = 0x4;
const LVS_EX_FULLROWSELECT: usize = 0x20;
const LVS_EX_DOUBLEBUFFER: usize = 0x10000;
const LVIF_TEXT: UINT = 0x1;
const LVIF_STATE: UINT = 0x8;
const LVIS_FOCUSED: UINT = 0x1;
const LVIS_SELECTED: UINT = 0x2;
const LVIS_STATEIMAGEMASK: UINT = 0xF000;
const LVCF_WIDTH: UINT = 0x2;
const LVCF_TEXT: UINT = 0x4;
const LVCF_SUBITEM: UINT = 0x8;
const LVSCW_AUTOSIZE_USEHEADER: isize = -2;
const LVN_ITEMCHANGING: u32 = @bitCast(@as(i32, -100));

const LVCOLUMNW = extern struct {
    mask: UINT = 0,
    fmt: i32 = 0,
    cx: i32 = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iSubItem: i32 = 0,
    iImage: i32 = 0,
    iOrder: i32 = 0,
    cxMin: i32 = 0,
    cxDefault: i32 = 0,
    cxIdeal: i32 = 0,
};

const LVITEMW = extern struct {
    mask: UINT = 0,
    iItem: i32 = 0,
    iSubItem: i32 = 0,
    state: UINT = 0,
    stateMask: UINT = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = 0,
    lParam: LPARAM = 0,
    iIndent: i32 = 0,
    iGroupId: i32 = 0,
    cColumns: UINT = 0,
    puColumns: ?*UINT = null,
    piColFmt: ?*i32 = null,
    iGroup: i32 = 0,
};

const NMHDR = extern struct { hwndFrom: ?HWND, idFrom: usize, code: u32 };
const NMLISTVIEW = extern struct {
    hdr: NMHDR,
    iItem: i32,
    iSubItem: i32,
    uNewState: UINT,
    uOldState: UINT,
    uChanged: UINT,
    ptAction: POINT,
    lParam: LPARAM,
};

fn stateImage(checked: bool) UINT {
    return (@as(UINT, if (checked) 2 else 1)) << 12;
}

const State = struct {
    alloc: Allocator,
    items: []Item,
    intro: []const u8,
    /// Set by the dialog while it fills the list: the check boxes it sets
    /// are not the person's.
    filling: bool = false,
};

/// The dialog: `intro` above the list, the connections in `items`, and
/// Select all, Import and Cancel. Returns whether Import was pressed; each
/// item's `checked` then says whether it was checked.
pub fn choose(alloc: Allocator, owner: ?HWND, items: []Item, intro: []const u8) Allocator.Error!bool {
    const icc: INITCOMMONCONTROLSEX = .{ .dwSize = @sizeOf(INITCOMMONCONTROLSEX), .dwICC = ICC_LISTVIEW_CLASSES };
    _ = InitCommonControlsEx(&icc);
    const template = try buildTemplate(alloc);
    defer alloc.free(template);
    var state: State = .{ .alloc = alloc, .items = items, .intro = intro };
    const result = DialogBoxIndirectParamW(GetModuleHandleW(null), template.ptr, owner, dialogProc, @bitCast(@intFromPtr(&state)));
    return result == IDOK;
}

/// An in-memory DLGTEMPLATE (DS_SETFONT, Segoe UI 9) with its five items,
/// in dialog units.
fn buildTemplate(alloc: Allocator) Allocator.Error![]align(4) u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(alloc);
    const T = struct {
        fn int(list: *std.ArrayListUnmanaged(u8), a: Allocator, comptime I: type, value: I) Allocator.Error!void {
            var buf: [@sizeOf(I)]u8 = undefined;
            std.mem.writeInt(I, &buf, value, .little);
            try list.appendSlice(a, &buf);
        }
        fn wstr(list: *std.ArrayListUnmanaged(u8), a: Allocator, text: []const u16) Allocator.Error!void {
            for (text) |unit| try int(list, a, u16, unit);
            try int(list, a, u16, 0);
        }
        fn alignTo4(list: *std.ArrayListUnmanaged(u8), a: Allocator) Allocator.Error!void {
            while (list.items.len % 4 != 0) try list.append(a, 0);
        }
        fn item(list: *std.ArrayListUnmanaged(u8), a: Allocator, style: u32, ex: u32, x: i16, y: i16, cx: i16, cy: i16, id: u16, class: union(enum) { atom: u16, name: []const u16 }, title: []const u16) Allocator.Error!void {
            try alignTo4(list, a);
            try int(list, a, u32, style);
            try int(list, a, u32, ex);
            try int(list, a, i16, x);
            try int(list, a, i16, y);
            try int(list, a, i16, cx);
            try int(list, a, i16, cy);
            try int(list, a, u16, id);
            switch (class) {
                .atom => |atom| {
                    try int(list, a, u16, 0xFFFF);
                    try int(list, a, u16, atom);
                },
                .name => |name| try wstr(list, a, name),
            }
            try wstr(list, a, title);
            try int(list, a, u16, 0);
        }
    };
    const WS_CHILD: u32 = 0x40000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_TABSTOP: u32 = 0x00010000;
    const WS_GROUP: u32 = 0x00020000;
    const WS_BORDER: u32 = 0x00800000;
    const child = WS_CHILD | WS_VISIBLE;
    const DS_SETFONT: u32 = 0x40;
    const DS_MODALFRAME: u32 = 0x80;
    const DS_CENTER: u32 = 0x800;
    const WS_POPUP: u32 = 0x80000000;
    const WS_CAPTION: u32 = 0x00C00000;
    const WS_SYSMENU: u32 = 0x00080000;
    const LVS_REPORT: u32 = 0x1;
    const LVS_SINGLESEL: u32 = 0x4;
    const LVS_SHOWSELALWAYS: u32 = 0x8;
    const LVS_NOSORTHEADER: u32 = 0x8000;
    const BS_DEFPUSHBUTTON: u32 = 0x1;
    const button_atom: u16 = 0x0080;
    const static_atom: u16 = 0x0082;

    const w: i16 = 400;
    const h: i16 = 250;
    try T.int(&bytes, alloc, u32, WS_POPUP | WS_CAPTION | WS_SYSMENU | DS_MODALFRAME | DS_SETFONT | DS_CENTER);
    try T.int(&bytes, alloc, u32, 0);
    try T.int(&bytes, alloc, u16, 5);
    try T.int(&bytes, alloc, i16, 0);
    try T.int(&bytes, alloc, i16, 0);
    try T.int(&bytes, alloc, i16, w);
    try T.int(&bytes, alloc, i16, h);
    try T.int(&bytes, alloc, u16, 0); // no menu
    try T.int(&bytes, alloc, u16, 0); // the dialog class
    try T.wstr(&bytes, alloc, L("Import from Terminals"));
    try T.int(&bytes, alloc, u16, 9);
    try T.wstr(&bytes, alloc, L("Segoe UI"));

    try T.item(&bytes, alloc, child, 0, 7, 7, w - 14, 26, id_intro, .{ .atom = static_atom }, L(""));
    try T.item(&bytes, alloc, child | WS_TABSTOP | WS_GROUP | WS_BORDER | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS | LVS_NOSORTHEADER, 0, 7, 36, w - 14, h - 64, id_list, .{ .name = L("SysListView32") }, L(""));
    try T.item(&bytes, alloc, child | WS_TABSTOP | WS_GROUP, 0, 7, h - 21, 70, 14, id_toggle, .{ .atom = button_atom }, L("Select &all"));
    try T.item(&bytes, alloc, child | WS_TABSTOP | WS_GROUP | BS_DEFPUSHBUTTON, 0, w - 7 - 60 - 4 - 60, h - 21, 60, 14, IDOK, .{ .atom = button_atom }, L("&Import"));
    try T.item(&bytes, alloc, child | WS_TABSTOP, 0, w - 7 - 60, h - 21, 60, 14, IDCANCEL, .{ .atom = button_atom }, L("Cancel"));

    const out = try alloc.alignedAlloc(u8, .@"4", bytes.items.len);
    @memcpy(out, bytes.items);
    return out;
}

fn stateOf(hwnd: HWND) ?*State {
    const raw = GetWindowLongPtrW(hwnd, DWLP_USER);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn dialogProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
    switch (msg) {
        WM_INITDIALOG => {
            _ = SetWindowLongPtrW(hwnd, DWLP_USER, lparam);
            const state = stateOf(hwnd) orelse return 1;
            fill(hwnd, state) catch {};
            if (GetDlgItem(hwnd, id_list)) |list| _ = SetFocus(list);
            return 0; // the focus is set
        },
        WM_NOTIFY => {
            const state = stateOf(hwnd) orelse return 0;
            const hdr: *const NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (hdr.idFrom != id_list or hdr.code != LVN_ITEMCHANGING or state.filling) return 0;
            const change: *const NMLISTVIEW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (change.iItem < 0) return 0;
            const index: usize = @intCast(change.iItem);
            if (index >= state.items.len or state.items[index].selectable) return 0;
            // A connection that cannot be imported keeps its box empty.
            if (change.uNewState & LVIS_STATEIMAGEMASK == stateImage(true)) {
                _ = SetWindowLongPtrW(hwnd, DWLP_MSGRESULT, 1);
                return 1;
            }
            return 0;
        },
        WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            const state = stateOf(hwnd) orelse return 0;
            const list = GetDlgItem(hwnd, id_list) orelse return 0;
            switch (id) {
                IDOK => {
                    for (state.items, 0..) |*item, i| {
                        const raw = SendMessageW(list, LVM_GETITEMSTATE, i, LVIS_STATEIMAGEMASK);
                        const bits: UINT = @truncate(@as(usize, @bitCast(raw)));
                        item.checked = item.selectable and bits & LVIS_STATEIMAGEMASK == stateImage(true);
                    }
                    _ = EndDialog(hwnd, IDOK);
                    return 1;
                },
                IDCANCEL => {
                    _ = EndDialog(hwnd, IDCANCEL);
                    return 1;
                },
                id_toggle => {
                    // Every importable connection checked, or, when they all
                    // are, none.
                    var all = true;
                    for (state.items, 0..) |item, i| {
                        if (!item.selectable) continue;
                        const raw = SendMessageW(list, LVM_GETITEMSTATE, i, LVIS_STATEIMAGEMASK);
                        const bits: UINT = @truncate(@as(usize, @bitCast(raw)));
                        if (bits & LVIS_STATEIMAGEMASK != stateImage(true)) all = false;
                    }
                    for (state.items, 0..) |item, i| {
                        if (!item.selectable) continue;
                        setCheck(list, i, !all);
                    }
                    return 1;
                },
                else => return 0,
            }
        },
        WM_CLOSE => {
            _ = EndDialog(hwnd, IDCANCEL);
            return 1;
        },
        else => return 0,
    }
}

fn setCheck(list: HWND, index: usize, checked: bool) void {
    var lvi: LVITEMW = .{ .stateMask = LVIS_STATEIMAGEMASK, .state = stateImage(checked) };
    _ = SendMessageW(list, LVM_SETITEMSTATE, index, @bitCast(@intFromPtr(&lvi)));
}

fn fill(hwnd: HWND, state: *State) Allocator.Error!void {
    const a = state.alloc;
    if (GetDlgItem(hwnd, id_intro)) |intro| {
        const text = std.unicode.utf8ToUtf16LeAllocZ(a, state.intro) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return,
        };
        defer a.free(text);
        _ = SetWindowTextW(intro, text.ptr);
    }
    const list = GetDlgItem(hwnd, id_list) orelse return;
    state.filling = true;
    defer state.filling = false;
    const ex = LVS_EX_CHECKBOXES | LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER;
    _ = SendMessageW(list, LVM_SETEXTENDEDLISTVIEWSTYLE, ex, @bitCast(ex));
    const columns = [_][:0]const u16{ L("Name"), L("Type"), L("Server"), L("Note") };
    for (columns, 0..) |title, i| {
        var col: LVCOLUMNW = .{ .mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM, .cx = 120, .pszText = title.ptr, .iSubItem = @intCast(i) };
        _ = SendMessageW(list, LVM_INSERTCOLUMNW, i, @bitCast(@intFromPtr(&col)));
    }
    for (state.items, 0..) |item, i| {
        const cells = [_][]const u8{ item.name, item.kind, item.server, item.note };
        for (cells, 0..) |cell, sub| {
            const text = std.unicode.utf8ToUtf16LeAllocZ(a, cell) catch try a.allocSentinel(u16, 0, 0);
            defer a.free(text);
            var lvi: LVITEMW = .{ .mask = LVIF_TEXT, .iItem = @intCast(i), .iSubItem = @intCast(sub), .pszText = text.ptr };
            if (sub == 0) {
                _ = SendMessageW(list, LVM_INSERTITEMW, 0, @bitCast(@intFromPtr(&lvi)));
            } else {
                _ = SendMessageW(list, LVM_SETITEMTEXTW, i, @bitCast(@intFromPtr(&lvi)));
            }
        }
        setCheck(list, i, item.selectable and item.checked);
    }
    for (0..columns.len) |i| _ = SendMessageW(list, LVM_SETCOLUMNWIDTH, i, LVSCW_AUTOSIZE_USEHEADER);
    if (state.items.len != 0) {
        var lvi: LVITEMW = .{ .stateMask = LVIS_SELECTED | LVIS_FOCUSED, .state = LVIS_SELECTED | LVIS_FOCUSED };
        _ = SendMessageW(list, LVM_SETITEMSTATE, 0, @bitCast(@intFromPtr(&lvi)));
    }
}

extern "user32" fn SetWindowTextW(hWnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;

test "terminals import dialog: Win32 struct sizes match the SDK" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(OPENFILENAMEW));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(LVITEMW));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(LVCOLUMNW));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(NMLISTVIEW));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(NMLISTVIEW, "iItem"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(NMLISTVIEW, "lParam"));
}

test "terminals import dialog: the template is DWORD aligned and holds five items" {
    const template = try buildTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(template.ptr) % 4);
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, template[8..10], .little));
}
