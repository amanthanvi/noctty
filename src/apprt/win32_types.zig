//! Shared Win32 ABI types used by multiple apprt modules.

const std = @import("std");
const windows = std.os.windows;
const geometry = @import("win32_geometry.zig");

pub const HWND = windows.HWND;
pub const HINSTANCE = windows.HINSTANCE;
pub const LPCWSTR = [*:0]const u16;
pub const UINT = u32;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const HRESULT = windows.HRESULT;
pub const GUID = windows.GUID;
pub const BOOL = windows.BOOL;
pub const ATOM = u16;
pub const LONG_PTR = isize;
pub const UINT_PTR = usize;
pub const DWORD = u32;
pub const ULONG = u32;
pub const ULONGLONG = u64;
pub const WORD = u16;
pub const BYTE = u8;
pub const COLORREF = u32;
pub const HBRUSH = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HDC = ?*anyopaque;
pub const HFONT = ?*anyopaque;
pub const HGDIOBJ = ?*anyopaque;
pub const HGLRC = ?*anyopaque;
pub const HGLOBAL = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HMONITOR = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const HMODULE = ?*anyopaque;
pub const HPEN = ?*anyopaque;
pub const HRGN = ?*anyopaque;
pub const INTRESOURCE = ?*const anyopaque;

pub const POINT = geometry.Point;
pub const POINTL = geometry.PointL;
pub const RECT = geometry.Rect;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: HINSTANCE,
    hMenu: HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: u32,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32,
    style: u32,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?LPCWSTR,
    lpszClassName: LPCWSTR,
    hIconSm: HICON,
};

test "shared Win32 type layouts" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 8), @sizeOf(POINT));
    try testing.expectEqual(@as(usize, 8), @sizeOf(POINTL));
    try testing.expectEqual(@as(usize, 16), @sizeOf(RECT));
    try testing.expectEqual(@as(usize, 4), @sizeOf(HRESULT));
    try testing.expectEqual(@as(usize, 16), @sizeOf(GUID));
    try testing.expectEqual(@as(usize, 4), @sizeOf(ULONG));
    try testing.expectEqual(@as(usize, 8), @sizeOf(ULONGLONG));
    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(PAINTSTRUCT));
    try testing.expectEqual(@as(usize, 72), @sizeOf(PAINTSTRUCT));
    try testing.expectEqual(@as(usize, 0), @offsetOf(PAINTSTRUCT, "hdc"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(PAINTSTRUCT, "rcPaint"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(PAINTSTRUCT, "rgbReserved"));

    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(CREATESTRUCTW));
    try testing.expectEqual(@as(usize, 80), @sizeOf(CREATESTRUCTW));
    try testing.expectEqual(@as(usize, 0), @offsetOf(CREATESTRUCTW, "lpCreateParams"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(CREATESTRUCTW, "hInstance"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(CREATESTRUCTW, "lpszName"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(CREATESTRUCTW, "lpszClass"));

    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(WNDCLASSEXW));
    try testing.expectEqual(@as(usize, 80), @sizeOf(WNDCLASSEXW));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WNDCLASSEXW, "cbSize"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(WNDCLASSEXW, "style"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(WNDCLASSEXW, "lpfnWndProc"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(WNDCLASSEXW, "hInstance"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(WNDCLASSEXW, "hIcon"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(WNDCLASSEXW, "hCursor"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(WNDCLASSEXW, "hbrBackground"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(WNDCLASSEXW, "lpszMenuName"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(WNDCLASSEXW, "lpszClassName"));
}
