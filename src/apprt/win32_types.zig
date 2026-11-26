//! Shared Win32 ABI types used by multiple apprt modules.

const std = @import("std");
const win32_types = @import("win32_types.zig");
const windows = std.os.windows;
const geometry = @import("win32_geometry.zig");

pub const HWND = windows.HWND;
pub const HINSTANCE = windows.HINSTANCE;
pub const LPCWSTR = [*:0]const u16;
pub const UINT = u32;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const HRESULT = i32;
pub const GUID = windows.GUID;
/// The Win32 `BOOL`: a plain `int`, the SDK's own type. Std's `win32_types.BOOL` is
/// an integer on Zig 0.15.2 and an enum on 0.17, so fork externs never name it
/// (PLAN decision 13).
pub const BOOL = c_int;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
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
pub const HGDIOBJ = ?*anyopaque;
pub const HGLRC = ?*anyopaque;
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

pub const WINDOWPLACEMENT = extern struct {
    length: UINT,
    flags: UINT,
    showCmd: UINT,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};

pub const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

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

// Win32 constants that Zig 0.17 removed from `std.os.windows`, kept as the
// untyped integers std had so every use site still coerces as before.
pub const GENERIC_READ = 0x80000000;
pub const GENERIC_WRITE = 0x40000000;
pub const FILE_READ_DATA = 0x00000001;
pub const FILE_WRITE_DATA = 0x00000002;
pub const FILE_APPEND_DATA = 0x00000004;
pub const FILE_READ_ATTRIBUTES = 0x00000080;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const CREATE_NEW = 1;
pub const CREATE_ALWAYS = 2;
pub const OPEN_EXISTING = 3;
pub const FILE_ATTRIBUTE_READONLY = 0x1;
pub const FILE_ATTRIBUTE_HIDDEN = 0x2;
pub const FILE_ATTRIBUTE_DIRECTORY = 0x10;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
pub const FILE_ATTRIBUTE_OFFLINE = 0x1000;
pub const FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x40000;
pub const FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x400000;
pub const FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
// NT-level options and codes, still passed to std's ntdll calls on 0.15.2.
pub const FILE_OPEN = 1;
pub const FILE_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
pub const FILE_DIRECTORY_FILE = 0x00000001;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
pub const OBJ_INHERIT = 0x00000002;
pub const FILE_DEVICE_FILE_SYSTEM = 0x00000009;
pub const FSCTL_GET_REPARSE_POINT: DWORD = 0x900a8;
pub const FSCTL_SET_REPARSE_POINT: DWORD = 0x900a4;
pub const IO_REPARSE_TAG_MOUNT_POINT: ULONG = 0xa0000003;
pub const IO_REPARSE_TAG_SYMLINK: ULONG = 0xa000000c;
pub const PIPE_ACCESS_INBOUND = 0x00000001;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const WAIT_OBJECT_0 = 0x00000000;
pub const WAIT_ABANDONED_0 = 0x00000080;
pub const MAXIMUM_WAIT_OBJECTS = 64;
pub const WAIT_ABANDONED = 0x00000080;
pub const WAIT_TIMEOUT = 0x00000102;
pub const WAIT_FAILED = 0xFFFFFFFF;
pub const INFINITE = 4294967295;
pub const EVENT_ALL_ACCESS = 0x1F0003;
pub const CREATE_EVENT_MANUAL_RESET = 0x00000001;
pub const STD_INPUT_HANDLE = std.math.maxInt(DWORD) - 10 + 1;
pub const STD_OUTPUT_HANDLE = std.math.maxInt(DWORD) - 11 + 1;
pub const STD_ERROR_HANDLE = std.math.maxInt(DWORD) - 12 + 1;
pub const KEY_READ = 0x20019;
pub const SYNCHRONIZE = 0x00100000;

/// `RegGetValueW`'s `dwFlags`.
pub const RRF = struct {
    pub const RT_ANY: DWORD = 0x0000ffff;
    pub const RT_DWORD: DWORD = 0x00000018;
    pub const RT_QWORD: DWORD = 0x00000048;
    pub const RT_REG_BINARY: DWORD = 0x00000008;
    pub const RT_REG_DWORD: DWORD = 0x00000010;
    pub const RT_REG_EXPAND_SZ: DWORD = 0x00000004;
    pub const RT_REG_MULTI_SZ: DWORD = 0x00000020;
    pub const RT_REG_NONE: DWORD = 0x00000001;
    pub const RT_REG_QWORD: DWORD = 0x00000040;
    pub const RT_REG_SZ: DWORD = 0x00000002;
    pub const NOEXPAND: DWORD = 0x10000000;
    pub const ZEROONFAILURE: DWORD = 0x20000000;
    pub const SUBKEY_WOW6464KEY: DWORD = 0x00010000;
    pub const SUBKEY_WOW6432KEY: DWORD = 0x00020000;
};

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

/// ntifs.h `OBJECT_ATTRIBUTES`, natural packing. `ObjectName` is std's
/// `UNICODE_STRING` (a `STRING(WCHAR)` of the same layout on 0.17).
pub const OBJECT_ATTRIBUTES = extern struct {
    Length: ULONG,
    RootDirectory: ?*anyopaque,
    ObjectName: *std.os.windows.UNICODE_STRING,
    Attributes: ULONG,
    SecurityDescriptor: ?*anyopaque,
    SecurityQualityOfService: ?*anyopaque,
};

/// winternl.h `FILE_BASIC_INFORMATION`, natural packing.
pub const FILE_BASIC_INFORMATION = extern struct {
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    FileAttributes: ULONG,
};

/// ntifs.h `FILE_ATTRIBUTE_TAG_INFORMATION` (`FileAttributeTagInformation`).
pub const FILE_ATTRIBUTE_TAG_INFO = extern struct {
    FileAttributes: DWORD,
    ReparseTag: DWORD,
};

/// winternl.h `UNICODE_STRING`, natural packing.
pub const UNICODE_STRING = extern struct {
    Length: u16,
    MaximumLength: u16,
    Buffer: ?[*]u16,
};

/// minwinbase.h `OVERLAPPED`, natural packing.
pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?*anyopaque,
    },
    hEvent: ?*anyopaque,
};

/// fileapi.h `BY_HANDLE_FILE_INFORMATION`, natural packing.
pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
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
    try testing.expectEqual(@as(usize, 8), @offsetOf(PAINTSTRUCT, "fErase"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(PAINTSTRUCT, "rcPaint"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(PAINTSTRUCT, "fRestore"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(PAINTSTRUCT, "fIncUpdate"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(PAINTSTRUCT, "rgbReserved"));

    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(CREATESTRUCTW));
    try testing.expectEqual(@as(usize, 80), @sizeOf(CREATESTRUCTW));
    try testing.expectEqual(@as(usize, 0), @offsetOf(CREATESTRUCTW, "lpCreateParams"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(CREATESTRUCTW, "hInstance"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(CREATESTRUCTW, "hMenu"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(CREATESTRUCTW, "hwndParent"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(CREATESTRUCTW, "cy"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(CREATESTRUCTW, "cx"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(CREATESTRUCTW, "y"));
    try testing.expectEqual(@as(usize, 44), @offsetOf(CREATESTRUCTW, "x"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(CREATESTRUCTW, "style"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(CREATESTRUCTW, "lpszName"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(CREATESTRUCTW, "lpszClass"));
    try testing.expectEqual(@as(usize, 72), @offsetOf(CREATESTRUCTW, "dwExStyle"));

    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(WNDCLASSEXW));
    try testing.expectEqual(@as(usize, 80), @sizeOf(WNDCLASSEXW));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WNDCLASSEXW, "cbSize"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(WNDCLASSEXW, "style"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(WNDCLASSEXW, "lpfnWndProc"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(WNDCLASSEXW, "cbClsExtra"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(WNDCLASSEXW, "cbWndExtra"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(WNDCLASSEXW, "hInstance"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(WNDCLASSEXW, "hIcon"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(WNDCLASSEXW, "hCursor"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(WNDCLASSEXW, "hbrBackground"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(WNDCLASSEXW, "lpszMenuName"));
    try testing.expectEqual(@as(usize, 64), @offsetOf(WNDCLASSEXW, "lpszClassName"));
    try testing.expectEqual(@as(usize, 72), @offsetOf(WNDCLASSEXW, "hIconSm"));

    // winuser.h declares both outside its pshpack2 block: natural packing.
    try testing.expectEqual(@as(usize, 44), @sizeOf(WINDOWPLACEMENT));
    try testing.expectEqual(@as(usize, 0), @offsetOf(WINDOWPLACEMENT, "length"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(WINDOWPLACEMENT, "flags"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(WINDOWPLACEMENT, "showCmd"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(WINDOWPLACEMENT, "ptMinPosition"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(WINDOWPLACEMENT, "ptMaxPosition"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(WINDOWPLACEMENT, "rcNormalPosition"));

    try testing.expectEqual(@as(usize, 40), @sizeOf(MONITORINFO));
    try testing.expectEqual(@as(usize, 0), @offsetOf(MONITORINFO, "cbSize"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(MONITORINFO, "rcMonitor"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(MONITORINFO, "rcWork"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(MONITORINFO, "dwFlags"));

    // BOOL is the SDK's `int`, and its integer constants are not std's.
    try testing.expectEqual(@as(usize, 4), @sizeOf(BOOL));
    try testing.expect(@typeInfo(BOOL).int.signedness == .signed);
    try testing.expectEqual(@as(BOOL, 1), TRUE);
    try testing.expectEqual(@as(BOOL, 0), FALSE);

    // minwinbase.h and fileapi.h declare both outside any pshpack block: natural packing.
    try testing.expectEqual(@as(usize, 8), @sizeOf(FILETIME));
    try testing.expectEqual(@as(usize, 0), @offsetOf(FILETIME, "dwLowDateTime"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(FILETIME, "dwHighDateTime"));
    try testing.expectEqual(@alignOf(?*anyopaque), @alignOf(OVERLAPPED));
    try testing.expectEqual(@as(usize, @sizeOf(usize) * 4), @sizeOf(OVERLAPPED));
    try testing.expectEqual(@as(usize, 0), @offsetOf(OVERLAPPED, "Internal"));
    try testing.expectEqual(@as(usize, @sizeOf(usize)), @offsetOf(OVERLAPPED, "InternalHigh"));
    try testing.expectEqual(@as(usize, @sizeOf(usize) * 2), @offsetOf(OVERLAPPED, "DUMMYUNIONNAME"));
    try testing.expectEqual(@as(usize, @sizeOf(usize) * 3), @offsetOf(OVERLAPPED, "hEvent"));
    // OVERLAPPED's nested union and the offset pair inside it (council S3/P4):
    // a swap of Offset and OffsetHigh fails here. An extern union's members
    // all start at 0 (Zig has no @offsetOf for a union), so its members'
    // sizes are pinned instead.
    const OverlappedUnion = @FieldType(OVERLAPPED, "DUMMYUNIONNAME");
    const OverlappedOffsets = @FieldType(OverlappedUnion, "DUMMYSTRUCTNAME");
    try testing.expectEqual(@as(usize, 8), @sizeOf(OverlappedUnion));
    try testing.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(@FieldType(OverlappedUnion, "Pointer")));
    try testing.expectEqual(@as(usize, 8), @sizeOf(OverlappedOffsets));
    try testing.expectEqual(@as(usize, 0), @offsetOf(OverlappedOffsets, "Offset"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(OverlappedOffsets, "OffsetHigh"));
    try testing.expectEqual(@as(usize, 52), @sizeOf(BY_HANDLE_FILE_INFORMATION));
    try testing.expectEqual(@as(usize, 0), @offsetOf(BY_HANDLE_FILE_INFORMATION, "dwFileAttributes"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(BY_HANDLE_FILE_INFORMATION, "ftCreationTime"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(BY_HANDLE_FILE_INFORMATION, "ftLastAccessTime"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(BY_HANDLE_FILE_INFORMATION, "ftLastWriteTime"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(BY_HANDLE_FILE_INFORMATION, "dwVolumeSerialNumber"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(BY_HANDLE_FILE_INFORMATION, "nFileSizeHigh"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(BY_HANDLE_FILE_INFORMATION, "nFileSizeLow"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(BY_HANDLE_FILE_INFORMATION, "nNumberOfLinks"));
    try testing.expectEqual(@as(usize, 44), @offsetOf(BY_HANDLE_FILE_INFORMATION, "nFileIndexHigh"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(BY_HANDLE_FILE_INFORMATION, "nFileIndexLow"));

    // winternl.h declares it outside any pshpack block: natural packing.
    try testing.expectEqual(@as(usize, @alignOf(?[*]u16) + @sizeOf(usize)), @sizeOf(UNICODE_STRING));
    try testing.expectEqual(@as(usize, 0), @offsetOf(UNICODE_STRING, "Length"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(UNICODE_STRING, "MaximumLength"));
    try testing.expectEqual(@as(usize, @alignOf(?[*]u16)), @offsetOf(UNICODE_STRING, "Buffer"));

    // ntifs.h and winternl.h declare these outside any pshpack block: natural packing.
    const ptr = @sizeOf(usize);
    try testing.expectEqual(@as(usize, ptr * 6), @sizeOf(OBJECT_ATTRIBUTES));
    try testing.expectEqual(@as(usize, 0), @offsetOf(OBJECT_ATTRIBUTES, "Length"));
    try testing.expectEqual(@as(usize, ptr), @offsetOf(OBJECT_ATTRIBUTES, "RootDirectory"));
    try testing.expectEqual(@as(usize, ptr * 2), @offsetOf(OBJECT_ATTRIBUTES, "ObjectName"));
    try testing.expectEqual(@as(usize, ptr * 3), @offsetOf(OBJECT_ATTRIBUTES, "Attributes"));
    try testing.expectEqual(@as(usize, ptr * 4), @offsetOf(OBJECT_ATTRIBUTES, "SecurityDescriptor"));
    try testing.expectEqual(@as(usize, ptr * 5), @offsetOf(OBJECT_ATTRIBUTES, "SecurityQualityOfService"));
    try testing.expectEqual(@as(usize, 40), @sizeOf(FILE_BASIC_INFORMATION));
    try testing.expectEqual(@as(usize, 0), @offsetOf(FILE_BASIC_INFORMATION, "CreationTime"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(FILE_BASIC_INFORMATION, "LastAccessTime"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(FILE_BASIC_INFORMATION, "LastWriteTime"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(FILE_BASIC_INFORMATION, "ChangeTime"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(FILE_BASIC_INFORMATION, "FileAttributes"));
    try testing.expectEqual(@as(usize, 8), @sizeOf(FILE_ATTRIBUTE_TAG_INFO));
    try testing.expectEqual(@as(usize, 0), @offsetOf(FILE_ATTRIBUTE_TAG_INFO, "FileAttributes"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(FILE_ATTRIBUTE_TAG_INFO, "ReparseTag"));
}
