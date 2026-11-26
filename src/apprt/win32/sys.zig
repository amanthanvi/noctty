//! Central Win32 ABI declarations used by the Windows application runtime.

const std = @import("std");
const windows = std.os.windows;
const win32_types = @import("../win32_types.zig");
const prefixed_path = @import("../win32_prefixed_path.zig");
const c = @import("consts.zig");
const ole = @import("../win32_ole.zig");

const ATOM = win32_types.ATOM;
const LPCWSTR = win32_types.LPCWSTR;
const HBRUSH = win32_types.HBRUSH;
const HCURSOR = win32_types.HCURSOR;
const HDC = win32_types.HDC;
const HGDIOBJ = win32_types.HGDIOBJ;
const HPEN = win32_types.HPEN;
const HMODULE = win32_types.HMODULE;
const HMENU = win32_types.HMENU;
const HICON = win32_types.HICON;
pub const LPARAM = win32_types.LPARAM;
pub const WPARAM = win32_types.WPARAM;
const LRESULT = win32_types.LRESULT;
const LONG_PTR = win32_types.LONG_PTR;
pub const UINT = win32_types.UINT;
const UINT_PTR = win32_types.UINT_PTR;
const DWORD = win32_types.DWORD;
const WORD = win32_types.WORD;
const BYTE = win32_types.BYTE;
const ULONG = win32_types.ULONG;
const OVERLAPPED = win32_types.OVERLAPPED;
const BOOL = win32_types.BOOL;
pub const HWND = win32_types.HWND;
const HINSTANCE = win32_types.HINSTANCE;
const INTRESOURCE = win32_types.INTRESOURCE;
const COLORREF = win32_types.COLORREF;
const HANDLE = windows.HANDLE;
const SIZE_T = windows.SIZE_T;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const GUID = windows.GUID;
const HRESULT = win32_types.HRESULT;
pub const HMONITOR = *opaque {};
pub const HKEY = windows.HKEY;
const HRGN = *anyopaque;
const REGSAM = DWORD;
const SHORT = i16;

pub const POINT = win32_types.POINT;
pub const RECT = win32_types.RECT;
pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD,
    nVersion: WORD,
    dwFlags: u32,
    iPixelType: BYTE,
    cColorBits: BYTE,
    cRedBits: BYTE,
    cRedShift: BYTE,
    cGreenBits: BYTE,
    cGreenShift: BYTE,
    cBlueBits: BYTE,
    cBlueShift: BYTE,
    cAlphaBits: BYTE,
    cAlphaShift: BYTE,
    cAccumBits: BYTE,
    cAccumRedBits: BYTE,
    cAccumGreenBits: BYTE,
    cAccumBlueBits: BYTE,
    cAccumAlphaBits: BYTE,
    cDepthBits: BYTE,
    cStencilBits: BYTE,
    cAuxBuffers: BYTE,
    iLayerType: BYTE,
    bReserved: BYTE,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: u32,
    pt: POINT,
    lPrivate: u32,
};

pub const PAINTSTRUCT = win32_types.PAINTSTRUCT;

pub const DRAWITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemAction: UINT,
    itemState: UINT,
    hwndItem: HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};

pub const WINDOWPOS = extern struct {
    hwnd: HWND,
    hwndInsertAfter: ?HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: UINT,
};

pub const WINDOWPLACEMENT = win32_types.WINDOWPLACEMENT;

pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: *WINDOWPOS,
};

pub const WNDCLASSEXW = win32_types.WNDCLASSEXW;
pub const CREATESTRUCTW = win32_types.CREATESTRUCTW;

pub const MONITORINFO = win32_types.MONITORINFO;

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = c.FW_NORMAL,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = c.DEFAULT_CHARSET,
    lfOutPrecision: u8 = c.OUT_DEFAULT_PRECIS,
    lfClipPrecision: u8 = c.CLIP_DEFAULT_PRECIS,
    lfQuality: u8 = c.CLEARTYPE_QUALITY,
    lfPitchAndFamily: u8 = c.DEFAULT_PITCH | c.FF_DONTCARE,
    lfFaceName: [c.LF_FACESIZE]u16 = @as([c.LF_FACESIZE]u16, @splat(0)),
};

pub const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT,
    iBorderWidth: i32,
    iScrollWidth: i32,
    iScrollHeight: i32,
    iCaptionWidth: i32,
    iCaptionHeight: i32,
    lfCaptionFont: LOGFONTW,
    iSmCaptionWidth: i32,
    iSmCaptionHeight: i32,
    lfSmCaptionFont: LOGFONTW,
    iMenuWidth: i32,
    iMenuHeight: i32,
    lfMenuFont: LOGFONTW,
    lfStatusFont: LOGFONTW,
    lfMessageFont: LOGFONTW,
    iPaddedBorderWidth: i32,
};

/// RTL_OSVERSIONINFOW for `RtlGetVersion`. `GetVersionExW` shims are
/// manifest-gated and lie about build numbers on anything newer than
/// Win8.1 unless the exe carries a Win10 application-manifest GUID.
/// `RtlGetVersion` is unshimmed and returns the real kernel build.
pub const RTL_OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: u32,
    dwMajorVersion: u32,
    dwMinorVersion: u32,
    dwBuildNumber: u32,
    dwPlatformId: u32,
    szCSDVersion: [128]u16,
};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: u32,
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const JOBOBJECTINFOCLASS = enum(i32) {
    basic_limit_information = 2,
    basic_process_id_list = 3,
    extended_limit_information = 9,
    _,
};

pub extern "user32" fn RegisterClipboardFormatW(lpszFormat: [*:0]const u16) callconv(.winapi) UINT;

pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;

pub extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: HINSTANCE) callconv(.winapi) BOOL;

pub extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: LPCWSTR,
    lpWindowName: LPCWSTR,
    dwStyle: u32,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;

pub extern "user32" fn CallWindowProcW(lpPrevWndFunc: ?*const anyopaque, hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn DrawTextW(hDC: HDC, lpchText: [*:0]const u16, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;

pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;

pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;

pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) i32;

pub extern "user32" fn MessageBoxW(hwnd: ?HWND, text: LPCWSTR, caption: LPCWSTR, flags: UINT) callconv(.winapi) c_int;

pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;

pub extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) SHORT;

pub extern "user32" fn GetAsyncKeyState(vKey: i32) callconv(.winapi) SHORT;

pub extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.winapi) BOOL;

pub extern "user32" fn SetKeyboardState(lpKeyState: *const [256]u8) callconv(.winapi) BOOL;

/// Returns the HKL for the thread. Callers inspect either the full HKL or its
/// language identifier as appropriate, so this is typed as an integer.
pub extern "user32" fn GetKeyboardLayout(idThread: DWORD) callconv(.winapi) usize;

pub extern "user32" fn GetKeyboardLayoutList(nBuff: i32, lpList: ?[*]usize) callconv(.winapi) i32;

pub extern "user32" fn LoadKeyboardLayoutW(pwszKLID: LPCWSTR, Flags: UINT) callconv(.winapi) usize;

pub extern "user32" fn ActivateKeyboardLayout(hkl: usize, Flags: UINT) callconv(.winapi) usize;

pub extern "user32" fn UnloadKeyboardLayout(hkl: usize) callconv(.winapi) BOOL;

pub extern "user32" fn MapVirtualKeyW(uCode: UINT, uMapType: UINT) callconv(.winapi) UINT;

pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) BOOL;

pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;

pub extern "user32" fn GetWindowPlacement(hWnd: HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowPlacement(hWnd: HWND, lpwndpl: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;

pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) i32;

pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;

pub extern "user32" fn IsWindow(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(.winapi) ?HMONITOR;

pub extern "user32" fn EnumDisplayMonitors(hdc: HDC, lprcClip: ?*const RECT, lpfnEnum: *const fn (HMONITOR, HDC, *RECT, LPARAM) callconv(.winapi) BOOL, dwData: LPARAM) callconv(.winapi) BOOL;

pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetCapture() callconv(.winapi) ?HWND;

pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;

pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;

pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;

pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;

pub extern "user32" fn GetDC(hWnd: HWND) callconv(.winapi) HDC;

pub extern "gdi32" fn RectVisible(hdc: HDC, lprc: *const RECT) callconv(.winapi) BOOL;

pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;

pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;

pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;

pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?*anyopaque;

pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: INTRESOURCE) callconv(.winapi) HCURSOR;

pub extern "user32" fn LoadImageW(hInst: HINSTANCE, name: INTRESOURCE, @"type": UINT, cx: i32, cy: i32, fuLoad: UINT) callconv(.winapi) ?*anyopaque;

pub extern "user32" fn GetSystemMetrics(nIndex: i32) callconv(.winapi) i32;
pub extern "user32" fn GetSystemMetricsForDpi(nIndex: i32, dpi: UINT) callconv(.winapi) i32;

pub extern "user32" fn SetThreadDpiAwarenessContext(dpiContext: isize) callconv(.winapi) isize;

pub extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;

// Update-region readback. Only the placement regression tests need this:
// they assert that repositioning a chrome child leaves it invalidated.
pub extern "user32" fn GetUpdateRect(hWnd: HWND, lpRect: ?*RECT, bErase: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn ValidateRect(hWnd: HWND, lpRect: ?*const RECT) callconv(.winapi) BOOL;

pub extern "user32" fn MoveWindow(hWnd: HWND, X: i32, Y: i32, nWidth: i32, nHeight: i32, bRepaint: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;

pub extern "user32" fn PostThreadMessageW(idThread: DWORD, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;

pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;

pub extern "user32" fn MsgWaitForMultipleObjectsEx(nCount: DWORD, pHandles: ?[*]const HANDLE, dwMilliseconds: DWORD, dwWakeMask: DWORD, dwFlags: DWORD) callconv(.winapi) DWORD;

pub extern "user32" fn AllowSetForegroundWindow(dwProcessId: DWORD) callconv(.winapi) BOOL;

pub extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.winapi) i32;

pub extern "user32" fn RegisterHotKey(hWnd: ?HWND, id: i32, fsModifiers: UINT, vk: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn RedrawWindow(hWnd: HWND, lprcUpdate: ?*const RECT, hrgnUpdate: ?*anyopaque, flags: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: UINT_PTR, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(.winapi) UINT_PTR;

pub extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(.winapi) HCURSOR;

pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;

pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn SetActiveWindow(hWnd: HWND) callconv(.winapi) ?HWND;

pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;

pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;

pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;

pub extern "user32" fn GetMessageTime() callconv(.winapi) i32;

pub extern "user32" fn WindowFromPoint(point: POINT) callconv(.winapi) ?HWND;

pub extern "user32" fn GetCaretPos(lpPoint: *POINT) callconv(.winapi) BOOL;

pub extern "user32" fn MonitorFromPoint(pt: POINT, dwFlags: DWORD) callconv(.winapi) ?HMONITOR;

pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: u32, bAlpha: BYTE, dwFlags: u32) callconv(.winapi) BOOL;

pub extern "user32" fn GetLayeredWindowAttributes(hwnd: HWND, pcrKey: ?*u32, pbAlpha: ?*BYTE, pdwFlags: ?*u32) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;

pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?*anyopaque, X: i32, Y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;

pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;

pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) LONG_PTR;

pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;

pub extern "user32" fn SystemParametersInfoW(uiAction: UINT, uiParam: UINT, pvParam: ?*anyopaque, fWinIni: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn GetSysColor(nIndex: i32) callconv(.winapi) COLORREF;

pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;

pub extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;

pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?LPCWSTR) callconv(.winapi) BOOL;

pub extern "user32" fn GetSystemMenu(hWnd: HWND, bRevert: BOOL) callconv(.winapi) HMENU;

pub extern "user32" fn EnableMenuItem(hMenu: HMENU, uIDEnableItem: UINT, uEnable: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn SetMenuDefaultItem(hMenu: HMENU, uItem: UINT, fByPos: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) BOOL;

pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;

pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;

pub extern "user32" fn ChildWindowFromPointEx(hWndParent: HWND, pt: POINT, uFlags: UINT) callconv(.winapi) ?HWND;

pub extern "user32" fn ToUnicode(
    wVirtKey: UINT,
    wScanCode: UINT,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]u16,
    cchBuff: i32,
    wFlags: UINT,
) callconv(.winapi) i32;

pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;

pub extern "user32" fn IsDialogMessageW(hDlg: HWND, lpMsg: *MSG) callconv(.winapi) BOOL;

pub extern "user32" fn UnregisterHotKey(hWnd: ?HWND, id: i32) callconv(.winapi) BOOL;

pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: UINT_PTR) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) HINSTANCE;

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) i32;

pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

pub extern "ole32" fn OleInitialize(pvReserved: ?*anyopaque) callconv(.winapi) i32;
pub extern "ole32" fn OleUninitialize() callconv(.winapi) void;
pub extern "ole32" fn RegisterDragDrop(hwnd: HWND, target: *anyopaque) callconv(.winapi) i32;
pub extern "ole32" fn RevokeDragDrop(hwnd: HWND) callconv(.winapi) i32;
pub extern "ole32" fn ReleaseStgMedium(medium: *ole.STGMEDIUM) callconv(.winapi) void;

pub extern "ntdll" fn RtlGetVersion(lpVersionInformation: *RTL_OSVERSIONINFOW) callconv(.winapi) i32;

/// Atomic replace of an existing file. Used by the settings save path
/// so a crash between write + rename can't corrupt `ghostty.conf`.
/// Returns non-zero on success. `dwReplaceFlags = 0` gives the default
/// (non-write-through) behaviour, which is fine for a user config file.
pub extern "kernel32" fn ReplaceFileW(
    lpReplacedFileName: LPCWSTR,
    lpReplacementFileName: LPCWSTR,
    lpBackupFileName: ?LPCWSTR,
    dwReplaceFlags: DWORD,
    lpExclude: ?*anyopaque,
    lpReserved: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: LPCWSTR,
    lpNewFileName: ?LPCWSTR,
    dwFlags: u32,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFinalPathNameByHandleW(
    hFile: HANDLE,
    lpszFilePath: [*]u16,
    cchFilePath: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub extern "kernel32" fn SetProcessShutdownParameters(dwLevel: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn RegisterApplicationRestart(pwzCommandline: ?LPCWSTR, dwFlags: DWORD) callconv(.winapi) HRESULT;
pub extern "kernel32" fn UnregisterApplicationRestart() callconv(.winapi) HRESULT;

pub extern "kernel32" fn SetThreadErrorMode(dwNewMode: DWORD, lpOldMode: ?*DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetDefaultDllDirectories(directory_flags: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
) callconv(.winapi) windows.HANDLE;

pub extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetEvent(hEvent: windows.HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*SECURITY_ATTRIBUTES,
    bInitialOwner: BOOL,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn ReleaseMutex(hMutex: windows.HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetNamedPipeHandleState(
    hNamedPipe: windows.HANDLE,
    lpMode: ?*DWORD,
    lpMaxCollectionCount: ?*DWORD,
    lpCollectDataTimeout: ?*DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetNamedPipeServerProcessId(Pipe: windows.HANDLE, ServerProcessId: *DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;

/// `SID_AND_ATTRIBUTES`/`TOKEN_USER` as returned by `GetTokenInformation`
/// with `TokenUser`. Only the SID pointer is used; the SID itself lives in
/// the caller-provided buffer.
pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: *anyopaque,
    Attributes: DWORD,
};

pub const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

/// `TOKEN_MANDATORY_LABEL` as returned by `GetTokenInformation` with
/// `TokenIntegrityLevel`. `Label.Sid` is an `S-1-16-<rid>` integrity SID.
pub const TOKEN_MANDATORY_LABEL = extern struct {
    Label: SID_AND_ATTRIBUTES,
};

pub extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: *HANDLE,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn EqualSid(
    pSid1: *anyopaque,
    pSid2: *anyopaque,
) callconv(.winapi) BOOL;

/// Byte length of a well-formed SID. Returns 0 if the SID is malformed.
pub extern "advapi32" fn GetLengthSid(
    pSid: *anyopaque,
) callconv(.winapi) DWORD;

pub extern "advapi32" fn GetTokenInformation(
    TokenHandle: HANDLE,
    TokenInformationClass: DWORD,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: DWORD,
    ReturnLength: *DWORD,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn ConvertSidToStringSidW(
    Sid: *anyopaque,
    StringSid: *?[*:0]u16,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: [*:0]const u16,
    StringSDRevision: DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*u32,
) callconv(.winapi) BOOL;

/// Read the security descriptor attached to a kernel object. Returns a
/// Win32 error code (0 == ERROR_SUCCESS), not a BOOL. The out-descriptor is
/// LocalAlloc'd; free it with `LocalFree`.
pub extern "advapi32" fn GetSecurityInfo(
    handle: HANDLE,
    ObjectType: DWORD,
    SecurityInfo: DWORD,
    ppsidOwner: ?*?*anyopaque,
    ppsidGroup: ?*?*anyopaque,
    ppDacl: ?*?*anyopaque,
    ppSacl: ?*?*anyopaque,
    ppSecurityDescriptor: *?*anyopaque,
) callconv(.winapi) DWORD;

pub extern "advapi32" fn ConvertSecurityDescriptorToStringSecurityDescriptorW(
    SecurityDescriptor: *anyopaque,
    RequestedStringSDRevision: DWORD,
    SecurityInformation: DWORD,
    StringSecurityDescriptor: *?[*:0]u16,
    StringSecurityDescriptorLen: ?*u32,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) HMODULE;

pub extern "kernel32" fn SetCurrentDirectoryW(lpPathName: LPCWSTR) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) BOOL;

pub extern "kernel32" fn GlobalSize(hMem: ?*anyopaque) callconv(.winapi) usize;

pub extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;

pub extern "gdi32" fn DescribePixelFormat(hdc: HDC, format: i32, size: UINT, ppfd: *PIXELFORMATDESCRIPTOR) callconv(.winapi) i32;

pub extern "gdi32" fn GetPixelFormat(hdc: HDC) callconv(.winapi) i32;

pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) HBRUSH;

pub extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) BOOL;

pub extern "user32" fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;

pub extern "gdi32" fn SetBkColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;

pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;

pub extern "gdi32" fn SetPixelFormat(hdc: HDC, format: i32, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;

pub extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;

pub extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;

pub extern "gdi32" fn TextOutW(hdc: HDC, x: i32, y: i32, lpString: LPCWSTR, c: i32) callconv(.winapi) BOOL;

pub extern "gdi32" fn CreateFontIndirectW(lplf: *const LOGFONTW) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn AddFontMemResourceEx(pFileView: *anyopaque, cjSize: DWORD, pvReserved: ?*anyopaque, pNumFonts: *DWORD) callconv(.winapi) ?HANDLE;
pub extern "gdi32" fn GetGlyphIndicesW(hdc: HDC, lpstr: [*]const u16, c: i32, pgi: [*]u16, fl: DWORD) callconv(.winapi) DWORD;
pub extern "gdi32" fn GetTextFaceW(hdc: HDC, c: i32, lpName: ?[*]u16) callconv(.winapi) i32;
pub extern "gdi32" fn CreateCompatibleDC(hdc: HDC) callconv(.winapi) HDC;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;

pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) HGDIOBJ;

pub extern "gdi32" fn GetStockObject(i: i32) callconv(.winapi) HGDIOBJ;

pub extern "gdi32" fn SetDCBrushColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;

pub extern "gdi32" fn SetDCPenColor(hdc: HDC, color: u32) callconv(.winapi) u32;

pub extern "gdi32" fn RoundRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(.winapi) BOOL;

pub extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: LPCWSTR, ulOptions: DWORD, samDesired: REGSAM, phkResult: *HKEY) callconv(.winapi) i32;

pub extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: LPCWSTR, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?*u8, lpcbData: ?*DWORD) callconv(.winapi) i32;

pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

const wgl = @import("wgl.zig");
pub const wglCreateContext = wgl.wglCreateContext;
pub const wglDeleteContext = wgl.wglDeleteContext;
pub const wglGetCurrentContext = wgl.wglGetCurrentContext;
pub const wglGetCurrentDC = wgl.wglGetCurrentDC;
pub const wglGetProcAddress = wgl.wglGetProcAddress;
pub const wglMakeCurrent = wgl.wglMakeCurrent;

pub const BPBF_TOPDOWNDIB: u32 = 2;
pub const SRCCOPY: u32 = 0x00CC0020;

pub extern "uxtheme" fn BufferedPaintInit() callconv(.winapi) i32;

pub extern "gdi32" fn SaveDC(hdc: HDC) callconv(.winapi) c_int;

pub extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;

pub extern "gdi32" fn RestoreDC(hdc: HDC, saved: c_int) callconv(.winapi) BOOL;

pub extern "uxtheme" fn BufferedPaintUnInit() callconv(.winapi) i32;

pub extern "gdi32" fn BitBlt(dst: HDC, x: i32, y: i32, width: i32, height: i32, src: HDC, src_x: i32, src_y: i32, rop: u32) callconv(.winapi) BOOL;

pub extern "uxtheme" fn BeginBufferedPaint(hdcTarget: HDC, prcTarget: *const RECT, dwFormat: u32, pPaintParams: ?*const anyopaque, phdc: *HDC) callconv(.winapi) ?*anyopaque;

pub extern "uxtheme" fn EndBufferedPaint(hBufferedPaint: *anyopaque, fUpdateTarget: BOOL) callconv(.winapi) i32;

pub extern "uxtheme" fn GetBufferedPaintBits(hBufferedPaint: *anyopaque, ppbBuffer: *?[*]u32, pcxRow: *i32) callconv(.winapi) i32;

pub extern "uxtheme" fn GetBufferedPaintTargetRect(hBufferedPaint: *anyopaque, prc: *RECT) callconv(.winapi) i32;

pub const DWM_BB_ENABLE: u32 = 0x1;
pub const DWM_BB_BLURREGION: u32 = 0x2;

/// dwmapi.h declares it under `pshpack1.h`: 20 bytes, no tail padding.
pub const DWM_BLURBEHIND = extern struct {
    dwFlags: u32 align(1),
    fEnable: BOOL align(1),
    hRgnBlur: ?HRGN align(1),
    fTransitionOnMaximized: BOOL align(1),
};

pub extern "dwmapi" fn DwmEnableBlurBehindWindow(hwnd: HWND, pBlurBehind: *const DWM_BLURBEHIND) callconv(.winapi) i32;

pub extern "dwmapi" fn DwmDefWindowProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, plResult: *LRESULT) callconv(.winapi) BOOL;

pub extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(.winapi) ?*anyopaque;

pub extern "imm32" fn ImmGetVirtualKey(hWnd: HWND) callconv(.winapi) UINT;

pub extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: ?*anyopaque) callconv(.winapi) BOOL;

pub extern "imm32" fn ImmGetCompositionStringW(hIMC: *anyopaque, dwIndex: u32, lpBuf: ?*anyopaque, dwBufLen: u32) callconv(.winapi) i32;

pub extern "imm32" fn ImmSetCompositionWindow(hIMC: *anyopaque, lpCompForm: *const COMPOSITIONFORM) callconv(.winapi) BOOL;

pub extern "imm32" fn ImmSetCandidateWindow(hIMC: *anyopaque, lpCandidate: *const CANDIDATEFORM) callconv(.winapi) BOOL;

pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?LPCWSTR,
    lpFile: LPCWSTR,
    lpParameters: ?LPCWSTR,
    lpDirectory: ?LPCWSTR,
    nShowCmd: i32,
) callconv(.winapi) ?*anyopaque;

pub extern "shell32" fn DragAcceptFiles(hWnd: HWND, fAccept: BOOL) callconv(.winapi) void;

pub extern "shlwapi" fn AssocIsDangerous(pszAssoc: LPCWSTR) callconv(.winapi) BOOL;

pub extern "shell32" fn DragQueryFileW(hDrop: *anyopaque, iFile: UINT, lpszFile: ?[*]u16, cch: UINT) callconv(.winapi) UINT;

pub extern "shell32" fn DragFinish(hDrop: *anyopaque) callconv(.winapi) void;

pub extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn GetParent(hWnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetDlgCtrlID(hWnd: HWND) callconv(.winapi) i32;
pub extern "user32" fn GetWindow(hWnd: HWND, uCmd: UINT) callconv(.winapi) ?HWND;
/// The window at the top of `hWnd`'s children, or of the desktop's top-level
/// windows when null; null when there is none.
pub extern "user32" fn GetTopWindow(hWnd: ?HWND) callconv(.winapi) ?HWND;
/// `MDT_EFFECTIVE_DPI` is 0. Windows 8.1 and later.
pub extern "shcore" fn GetDpiForMonitor(hmonitor: HMONITOR, dpiType: u32, dpiX: *u32, dpiY: *u32) callconv(.winapi) i32;
/// Returns the previous parent, or null on failure.
pub extern "user32" fn SetParent(hWndChild: HWND, hWndNewParent: ?HWND) callconv(.winapi) ?HWND;

pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;

pub extern "user32" fn IsChild(hWndParent: HWND, hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsWindowEnabled(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn SetScrollRange(hWnd: HWND, nBar: c_int, nMinPos: c_int, nMaxPos: c_int, bRedraw: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn SetScrollPos(hWnd: HWND, nBar: c_int, nPos: c_int, bRedraw: BOOL) callconv(.winapi) c_int;

pub extern "user32" fn ShowScrollBar(hWnd: HWND, wBar: c_int, bShow: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowRgn(hWnd: HWND, hRgn: ?HRGN, bRedraw: BOOL) callconv(.winapi) c_int;

pub extern "user32" fn NotifyWinEvent(event: u32, hwnd: HWND, idObject: i32, idChild: i32) callconv(.winapi) void;

pub extern "user32" fn GetClassNameW(hwnd: HWND, name: [*]u16, count: c_int) callconv(.winapi) c_int;
pub extern "user32" fn AdjustWindowRectExForDpi(rect: *RECT, style: u32, menu: BOOL, ex_style: u32, dpi: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn EnumChildWindows(hWndParent: HWND, lpEnumFunc: *const fn (HWND, LPARAM) callconv(.winapi) BOOL, lParam: LPARAM) callconv(.winapi) BOOL;

pub extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: LPCWSTR,
) callconv(.winapi) HGDIOBJ;

pub extern "gdi32" fn CreateRectRgn(x1: i32, y1: i32, x2: i32, y2: i32) callconv(.winapi) ?HRGN;

pub extern "kernel32" fn MulDiv(nNumber: i32, nNumerator: i32, nDenominator: i32) callconv(.winapi) i32;

pub extern "ole32" fn CoCreateInstance(
    class_id: *const GUID,
    outer: ?*anyopaque,
    context: u32,
    interface_id: *const GUID,
    result: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub extern "gdi32" fn CreatePen(style: i32, width: i32, color: u32) callconv(.winapi) HPEN;

pub extern "gdi32" fn MoveToEx(hdc: HDC, x: i32, y: i32, lp: ?*POINT) callconv(.winapi) i32;

pub extern "gdi32" fn LineTo(hdc: HDC, x: i32, y: i32) callconv(.winapi) i32;

pub extern "gdi32" fn Ellipse(hdc: HDC, x1: i32, y1: i32, x2: i32, y2: i32) callconv(.winapi) i32;

pub extern "gdi32" fn Arc(
    hdc: HDC,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    xr1: i32,
    yr1: i32,
    xr2: i32,
    yr2: i32,
) callconv(.winapi) i32;

pub extern "gdi32" fn Rectangle(hdc: HDC, x1: i32, y1: i32, x2: i32, y2: i32) callconv(.winapi) i32;

pub extern "gdi32" fn Polygon(hdc: HDC, points: [*]const POINT, count: i32) callconv(.winapi) i32;

pub extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) HMODULE;

pub extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInfoClass: JOBOBJECTINFOCLASS,
    lpJobObjectInfo: *const anyopaque,
    cbJobObjectInfoLength: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn QueryInformationJobObject(
    hJob: HANDLE,
    JobObjectInfoClass: JOBOBJECTINFOCLASS,
    lpJobObjectInfo: *anyopaque,
    cbJobObjectInfoLength: DWORD,
    lpReturnLength: ?*DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: HANDLE,
    hProcess: HANDLE,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;

pub extern "user32" fn GetAncestor(hwnd: HWND, flags: u32) callconv(.winapi) ?HWND;

pub extern "user32" fn SendMessageTimeoutW(
    HWND,
    UINT,
    WPARAM,
    LPARAM,
    UINT,
    UINT,
    *usize,
) callconv(.winapi) isize;

pub extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(AppID: LPCWSTR) callconv(.winapi) HRESULT;

pub extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    Reserved: DWORD,
    lpClass: ?LPCWSTR,
    dwOptions: DWORD,
    samDesired: REGSAM,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.winapi) i32;

pub extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    // Optional: null names the key's default value.
    lpValueName: ?LPCWSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const u8,
    cbData: DWORD,
) callconv(.winapi) i32;

// kernel32 and advapi32 declarations that Zig 0.17 removed from `std.os.windows`,
// written against the SDK prototypes. `BOOL` is the SDK's `int`
// (`win32_types.BOOL`); a function that signals failure with NULL returns an
// optional handle, and one that signals it with INVALID_HANDLE_VALUE returns
// `HANDLE` (PLAN decision 13, section 7.4).

pub const VECTORED_EXCEPTION_HANDLER = *const fn (ExceptionInfo: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long;
pub const HANDLER_ROUTINE = *const fn (dwCtrlType: DWORD) callconv(.winapi) BOOL;

/// Returns the handler's registration, or NULL on failure.
pub extern "kernel32" fn AddVectoredExceptionHandler(First: ULONG, Handler: ?VECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;

/// Fails with INVALID_HANDLE_VALUE, not NULL.
pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: HANDLE,
    hSourceHandle: HANDLE,
    hTargetProcessHandle: HANDLE,
    lpTargetHandle: *HANDLE,
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwOptions: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn ExitProcess(uExitCode: UINT) callconv(.winapi) noreturn;

pub extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;

/// A pseudo handle, never NULL.
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;

pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFileAttributesW(lpFileName: LPCWSTR) callconv(.winapi) DWORD;

pub extern "kernel32" fn GetModuleFileNameW(hModule: HMODULE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;

pub extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.winapi) BOOL;

/// NULL when the process has no such handle, INVALID_HANDLE_VALUE on failure.
pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GetSystemDirectoryW(lpBuffer: [*]u16, uSize: UINT) callconv(.winapi) UINT;

pub extern "kernel32" fn LoadLibraryExW(lpLibFileName: LPCWSTR, hFile: ?HANDLE, dwFlags: DWORD) callconv(.winapi) HMODULE;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: *anyopaque,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?HANDLER_ROUTINE, Add: BOOL) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetLastError(dwErrCode: DWORD) callconv(.winapi) void;

pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitForMultipleObjects(
    nCount: DWORD,
    lpHandle: [*]const HANDLE,
    bWaitAll: BOOL,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;

/// NULL when the event cannot be created.
pub extern "kernel32" fn CreateEventExW(
    lpEventAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?LPCWSTR,
    dwFlags: DWORD,
    dwDesiredAccess: DWORD,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn WaitForSingleObjectEx(hHandle: HANDLE, dwMilliseconds: DWORD, bAlertable: BOOL) callconv(.winapi) DWORD;

pub extern "kernel32" fn WaitForMultipleObjectsEx(
    nCount: DWORD,
    lpHandles: [*]const HANDLE,
    bWaitAll: BOOL,
    dwMilliseconds: DWORD,
    bAlertable: BOOL,
) callconv(.winapi) DWORD;

/// `CreateEventExW` with std's former error mapping.
pub fn createEventExW(attributes: ?*SECURITY_ATTRIBUTES, name: ?LPCWSTR, flags: DWORD, desired_access: DWORD) error{Unexpected}!HANDLE {
    return CreateEventExW(attributes, name, flags, desired_access) orelse
        windows.unexpectedError(windows.GetLastError());
}

pub const WaitForSingleObjectError = error{ WaitAbandoned, WaitTimeOut, Unexpected };

/// `WaitForSingleObjectEx` with std's former result mapping.
pub fn waitForSingleObjectEx(handle: HANDLE, milliseconds: DWORD, alertable: bool) WaitForSingleObjectError!void {
    switch (WaitForSingleObjectEx(handle, milliseconds, @intFromBool(alertable))) {
        win32_types.WAIT_ABANDONED => return error.WaitAbandoned,
        win32_types.WAIT_OBJECT_0 => return,
        win32_types.WAIT_TIMEOUT => return error.WaitTimeOut,
        win32_types.WAIT_FAILED => return windows.unexpectedError(windows.GetLastError()),
        else => return error.Unexpected,
    }
}

/// `WaitForMultipleObjectsEx` with std's former result mapping: the index of
/// the signalled handle.
pub fn waitForMultipleObjectsEx(handles: []const HANDLE, wait_all: bool, milliseconds: DWORD, alertable: bool) WaitForSingleObjectError!u32 {
    std.debug.assert(handles.len > 0 and handles.len <= win32_types.MAXIMUM_WAIT_OBJECTS);
    const count: DWORD = @intCast(handles.len);
    switch (WaitForMultipleObjectsEx(count, handles.ptr, @intFromBool(wait_all), milliseconds, @intFromBool(alertable))) {
        win32_types.WAIT_OBJECT_0...win32_types.WAIT_OBJECT_0 + win32_types.MAXIMUM_WAIT_OBJECTS => |n| {
            const index = n - win32_types.WAIT_OBJECT_0;
            std.debug.assert(index < count);
            return index;
        },
        win32_types.WAIT_ABANDONED_0...win32_types.WAIT_ABANDONED_0 + win32_types.MAXIMUM_WAIT_OBJECTS => return error.WaitAbandoned,
        win32_types.WAIT_TIMEOUT => return error.WaitTimeOut,
        win32_types.WAIT_FAILED => return windows.unexpectedError(windows.GetLastError()),
        else => return error.Unexpected,
    }
}

pub const TerminateProcessError = error{ AccessDenied, Unexpected };

/// `TerminateProcess` with std's former error mapping.
pub fn terminateProcess(process: HANDLE, exit_code: UINT) TerminateProcessError!void {
    if (TerminateProcess(process, exit_code) == 0) {
        switch (windows.GetLastError()) {
            .ACCESS_DENIED => return error.AccessDenied,
            else => |err| return windows.unexpectedError(err),
        }
    }
}

/// `WaitForSingleObject` with std's former result mapping.
pub fn waitForSingleObject(handle: HANDLE, milliseconds: DWORD) WaitForSingleObjectError!void {
    return waitForSingleObjectEx(handle, milliseconds, false);
}

/// `SetConsoleCtrlHandler` with std's former error mapping.
pub fn setConsoleCtrlHandler(handler: ?HANDLER_ROUTINE, add: bool) error{Unexpected}!void {
    if (SetConsoleCtrlHandler(handler, if (add) win32_types.TRUE else win32_types.FALSE) == win32_types.FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

pub const WriteFileError = error{
    SystemResources,
    OperationAborted,
    BrokenPipe,
    NotOpenForWriting,
    /// Another process has locked a portion of the file.
    LockViolation,
    /// The specified network name is no longer available.
    ConnectionResetByPeer,
    AccessDenied,
    Unexpected,
};

/// `WriteFile` with std's former error mapping. A non-null `offset` writes at
/// that file position through an `OVERLAPPED`.
pub fn writeFile(handle: HANDLE, bytes: []const u8, offset: ?u64) WriteFileError!usize {
    var bytes_written: DWORD = undefined;
    var overlapped_data: OVERLAPPED = undefined;
    const overlapped: ?*OVERLAPPED = if (offset) |off| blk: {
        overlapped_data = .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{ .DUMMYSTRUCTNAME = .{
                .Offset = @truncate(off),
                .OffsetHigh = @truncate(off >> 32),
            } },
            .hEvent = null,
        };
        break :blk &overlapped_data;
    } else null;
    const adjusted_len = std.math.cast(u32, bytes.len) orelse std.math.maxInt(u32);
    if (WriteFile(handle, bytes.ptr, adjusted_len, &bytes_written, overlapped) == 0) {
        switch (windows.GetLastError()) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.OperationAborted,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .IO_PENDING => unreachable,
            .NO_DATA => return error.BrokenPipe,
            .INVALID_HANDLE => return error.NotOpenForWriting,
            .LOCK_VIOLATION => return error.LockViolation,
            .NETNAME_DELETED => return error.ConnectionResetByPeer,
            .ACCESS_DENIED => return error.AccessDenied,
            .WORKING_SET_QUOTA => return error.SystemResources,
            else => |err| return windows.unexpectedError(err),
        }
    }
    return bytes_written;
}

pub const LoadLibraryError = error{ FileNotFound, Unexpected };

/// `LoadLibraryW` with std's former error mapping; the module is never NULL.
pub fn loadLibraryW(name: [*:0]const u16) LoadLibraryError!*anyopaque {
    return LoadLibraryW(name) orelse {
        switch (windows.GetLastError()) {
            .FILE_NOT_FOUND => return error.FileNotFound,
            .PATH_NOT_FOUND => return error.FileNotFound,
            .MOD_NOT_FOUND => return error.FileNotFound,
            else => |err| return windows.unexpectedError(err),
        }
    };
}

/// `FreeLibrary` of a module `loadLibraryW` returned. Failure is a bug.
pub fn freeLibrary(module: *anyopaque) void {
    std.debug.assert(FreeLibrary(module) != 0);
}

/// `GetModuleFileNameW` with std's former error mapping: the path written, as
/// a slice of the buffer.
pub fn getModuleFileNameW(module: HMODULE, buf_ptr: [*]u16, buf_len: DWORD) error{Unexpected}![:0]u16 {
    const rc = GetModuleFileNameW(module, buf_ptr, buf_len);
    if (rc == 0) return windows.unexpectedError(windows.GetLastError());
    return buf_ptr[0..rc :0];
}

pub const GetFileAttributesError = error{ FileNotFound, AccessDenied, Unexpected };

/// `GetFileAttributesW` with std's former error mapping.
pub fn getFileAttributesW(name: LPCWSTR) GetFileAttributesError!DWORD {
    const rc = GetFileAttributesW(name);
    if (rc == windows.INVALID_FILE_ATTRIBUTES) {
        switch (windows.GetLastError()) {
            .FILE_NOT_FOUND => return error.FileNotFound,
            .PATH_NOT_FOUND => return error.FileNotFound,
            .ACCESS_DENIED => return error.AccessDenied,
            else => |err| return windows.unexpectedError(err),
        }
    }
    return rc;
}

/// `GetFileAttributesW` of a WTF-8 path, as std's `GetFileAttributes` did.
pub fn getFileAttributes(filename: []const u8) (GetFileAttributesError || prefixed_path.Error)!DWORD {
    const filename_w = try prefixed_path.sliceToPrefixedFileW(filename);
    return getFileAttributesW(filename_w.span().ptr);
}

/// `CreateEventExW` of a WTF-8 name, as std's `CreateEventEx` did.
pub fn createEventEx(attributes: ?*SECURITY_ATTRIBUTES, name: []const u8, flags: DWORD, desired_access: DWORD) (error{Unexpected} || prefixed_path.Error)!HANDLE {
    const name_w = try prefixed_path.sliceToPrefixedFileW(name);
    return createEventExW(attributes, name_w.span().ptr, flags, desired_access);
}

pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;

pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;

/// The counter's value. "On systems that run Windows XP or later, the function
/// will always succeed."
pub fn queryPerformanceCounter() u64 {
    var result: i64 = undefined;
    std.debug.assert(QueryPerformanceCounter(&result) != 0);
    // The kernel treats this integer as unsigned.
    return @bitCast(result);
}

pub fn queryPerformanceFrequency() u64 {
    var result: i64 = undefined;
    std.debug.assert(QueryPerformanceFrequency(&result) != 0);
    return @bitCast(result);
}

pub extern "ntdll" fn RtlEqualUnicodeString(String1: *const win32_types.UNICODE_STRING, String2: *const win32_types.UNICODE_STRING, CaseInSensitive: u8) callconv(.winapi) u8;

/// Whether two WTF-16 strings are equal ignoring case, by the system's
/// uppercase table, as std's `eqlIgnoreCaseWTF16` compared them on Windows.
pub fn eqlIgnoreCaseWtf16(a: []const u16, b: []const u16) bool {
    const a_bytes: u16 = @intCast(a.len * 2);
    const a_string: win32_types.UNICODE_STRING = .{ .Length = a_bytes, .MaximumLength = a_bytes, .Buffer = @constCast(a.ptr) };
    const b_bytes: u16 = @intCast(b.len * 2);
    const b_string: win32_types.UNICODE_STRING = .{ .Length = b_bytes, .MaximumLength = b_bytes, .Buffer = @constCast(b.ptr) };
    return RtlEqualUnicodeString(&a_string, &b_string, 1) != 0;
}

/// `NtCreateFile` over the fork's `OBJECT_ATTRIBUTES`; the flag words are the
/// SDK's `ULONG`s.
pub extern "ntdll" fn NtCreateFile(
    FileHandle: *HANDLE,
    DesiredAccess: u32,
    ObjectAttributes: *const win32_types.OBJECT_ATTRIBUTES,
    IoStatusBlock: *windows.IO_STATUS_BLOCK,
    AllocationSize: ?*const i64,
    FileAttributes: u32,
    ShareAccess: u32,
    CreateDisposition: u32,
    CreateOptions: u32,
    EaBuffer: ?*const anyopaque,
    EaLength: u32,
) callconv(.winapi) windows.NTSTATUS;

pub const OpenError = error{
    IsDir,
    NotDir,
    FileNotFound,
    NoDevice,
    AccessDenied,
    PipeBusy,
    PathAlreadyExists,
    Unexpected,
    NameTooLong,
    WouldBlock,
    NetworkNotFound,
    AntivirusInterference,
    BadPathName,
};

pub const OpenFileOptions = struct {
    access_mask: u32,
    dir: ?HANDLE = null,
    sa: ?*SECURITY_ATTRIBUTES = null,
    share_access: u32 = win32_types.FILE_SHARE_WRITE | win32_types.FILE_SHARE_READ | win32_types.FILE_SHARE_DELETE,
    creation: u32,
    /// If true, tries to open path as a directory. Defaults to false.
    filter: Filter = .file_only,
    /// If false, tries to open path as a reparse point without dereferencing it.
    follow_symlinks: bool = true,

    pub const Filter = enum {
        /// `OpenFile` returns `error.IsDir` if the opened handle would be a directory.
        file_only,
        /// `OpenFile` returns `error.NotDir` if the opened handle would be a file.
        dir_only,
        /// `OpenFile` does not discriminate between files and directories.
        any,
    };
};

/// Whether `path` is rooted or drive-absolute, as std's former
/// `isAbsoluteWindowsWTF16` read it: a leading separator, or a drive letter
/// and colon followed by a separator.
fn isAbsoluteWtf16(path: []const u16) bool {
    if (path.len < 1) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    if (path.len < 3) return false;
    if (path[1] == ':') return path[2] == '/' or path[2] == '\\';
    return false;
}

/// `NtCreateFile` of `sub_path_w` with std's former `OpenFile` mapping of
/// statuses to errors, flags and retry on a pending delete.
pub fn openFile(sub_path_w: []const u16, options: OpenFileOptions) OpenError!HANDLE {
    if (std.mem.eql(u16, sub_path_w, &[_]u16{'.'}) and options.filter == .file_only) return error.IsDir;
    if (std.mem.eql(u16, sub_path_w, &[_]u16{ '.', '.' }) and options.filter == .file_only) return error.IsDir;

    var result: HANDLE = undefined;

    const path_len_bytes = std.math.cast(u16, sub_path_w.len * 2) orelse return error.NameTooLong;
    var nt_name = windows.UNICODE_STRING{
        .Length = path_len_bytes,
        .MaximumLength = path_len_bytes,
        .Buffer = @constCast(sub_path_w.ptr),
    };
    var attr = win32_types.OBJECT_ATTRIBUTES{
        .Length = @sizeOf(win32_types.OBJECT_ATTRIBUTES),
        .RootDirectory = if (isAbsoluteWtf16(sub_path_w)) null else options.dir,
        // OBJ_CASE_INSENSITIVE is deliberately not set.
        .Attributes = if (options.sa) |ptr| blk: {
            const inherit: u32 = if (@backingInt(ptr.bInheritHandle) == win32_types.TRUE) win32_types.OBJ_INHERIT else 0;
            break :blk inherit;
        } else 0,
        .ObjectName = &nt_name,
        .SecurityDescriptor = if (options.sa) |ptr| ptr.lpSecurityDescriptor else null,
        .SecurityQualityOfService = null,
    };
    var io: windows.IO_STATUS_BLOCK = undefined;
    const blocking_flag: u32 = win32_types.FILE_SYNCHRONOUS_IO_NONALERT;
    const file_or_dir_flag: u32 = switch (options.filter) {
        .file_only => win32_types.FILE_NON_DIRECTORY_FILE,
        .dir_only => win32_types.FILE_DIRECTORY_FILE,
        .any => 0,
    };
    // Not following symlinks must not carry a synchronization flag.
    const flags: u32 = if (options.follow_symlinks) file_or_dir_flag | blocking_flag else file_or_dir_flag | win32_types.FILE_OPEN_REPARSE_POINT;

    while (true) {
        const rc = NtCreateFile(
            &result,
            options.access_mask,
            &attr,
            &io,
            null,
            win32_types.FILE_ATTRIBUTE_NORMAL,
            options.share_access,
            options.creation,
            flags,
            null,
            0,
        );
        switch (rc) {
            .SUCCESS => return result,
            .OBJECT_NAME_INVALID => return error.BadPathName,
            .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
            .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .BAD_NETWORK_PATH => return error.NetworkNotFound, // \\server was not found
            .BAD_NETWORK_NAME => return error.NetworkNotFound, // \\server was found but \\server\share wasn't
            .NO_MEDIA_IN_DEVICE => return error.NoDevice,
            .INVALID_PARAMETER => unreachable,
            .SHARING_VIOLATION => return error.AccessDenied,
            .ACCESS_DENIED => return error.AccessDenied,
            .PIPE_BUSY => return error.PipeBusy,
            .PIPE_NOT_AVAILABLE => return error.NoDevice,
            .OBJECT_PATH_SYNTAX_BAD => unreachable,
            .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
            .FILE_IS_A_DIRECTORY => return error.IsDir,
            .NOT_A_DIRECTORY => return error.NotDir,
            .USER_MAPPED_FILE => return error.AccessDenied,
            .INVALID_HANDLE => unreachable,
            .DELETE_PENDING => {
                // A file was here and is deleted, but the OS has not finished:
                // retry the creation once it has. (Zig 0.15's
                // `std.Thread.sleep(std.time.ns_per_ms)`, which was `Sleep(1)`.)
                Sleep(1);
                continue;
            },
            .VIRUS_INFECTED, .VIRUS_DELETED => return error.AntivirusInterference,
            else => return windows.unexpectedStatus(rc),
        }
    }
}

pub const DeviceIoControlError = error{
    AccessDenied,
    /// The volume does not contain a recognized file system.
    UnrecognizedVolume,
    Unexpected,
};

/// `NtDeviceIoControlFile` or `NtFsControlFile`, whichever the code asks for,
/// with std's former `DeviceIoControl` mapping of statuses.
pub fn deviceIoControl(h: HANDLE, io_control_code: u32, in: ?[]const u8, out: ?[]u8) DeviceIoControlError!void {
    const is_fsctl = (io_control_code >> 16) == win32_types.FILE_DEVICE_FILE_SYSTEM;

    var io: windows.IO_STATUS_BLOCK = undefined;
    const in_ptr = if (in) |i| i.ptr else null;
    const in_len = if (in) |i| @as(u32, @intCast(i.len)) else 0;
    const out_ptr = if (out) |o| o.ptr else null;
    const out_len = if (out) |o| @as(u32, @intCast(o.len)) else 0;

    const rc = blk: {
        if (is_fsctl) {
            break :blk windows.ntdll.NtFsControlFile(h, null, null, null, &io, @bitCast(io_control_code), in_ptr, in_len, out_ptr, out_len);
        } else {
            break :blk windows.ntdll.NtDeviceIoControlFile(h, null, null, null, &io, @bitCast(io_control_code), in_ptr, in_len, out_ptr, out_len);
        }
    };
    switch (rc) {
        .SUCCESS => {},
        .PRIVILEGE_NOT_HELD => return error.AccessDenied,
        .ACCESS_DENIED => return error.AccessDenied,
        .INVALID_DEVICE_REQUEST => return error.AccessDenied, // Not supported by the underlying filesystem
        .INVALID_PARAMETER => unreachable,
        .UNRECOGNIZED_VOLUME => return error.UnrecognizedVolume,
        else => return windows.unexpectedStatus(rc),
    }
}

pub const GetFinalPathNameByHandleError = error{
    AccessDenied,
    BadPathName,
    FileNotFound,
    NameTooLong,
    UnrecognizedVolume,
    Unexpected,
};

/// The path of `handle` as it was opened, with a DOS volume name and no `\\?\`
/// prefix (`C:\dir\file`, `\\server\share\file`), written into `out_buffer`:
/// the form std 0.15.2's `GetFinalPathNameByHandle(.{})` returned.
///
/// **The flags.** `FILE_NAME_OPENED | VOLUME_NAME_DOS` (0x8). Std read the name
/// the handle was opened by (`NtQueryObject`'s object name) and only mapped its
/// volume to a drive letter, so an 8.3 short name and the case the caller
/// spelled stay as opened. Flags 0 would be `FILE_NAME_NORMALIZED`, which
/// expands short names and takes the on-disk case: a caller that compares the
/// result with the path it opened (`lockedHandleMatchesPath` in
/// update/github_releases.zig) would read the same file as another, and on an
/// SMB share normalization can fail with ACCESS_DENIED where the open worked.
///
/// **Where it differs from std.** For a volume with a drive letter or a UNC
/// share it gives std's answer, the opened spelling. A volume mounted only at a
/// folder has no DOS volume name: `VOLUME_NAME_DOS` then fails with
/// ERROR_PATH_NOT_FOUND (it gives no `\\?\Volume{GUID}\` path), which is
/// `error.FileNotFound`, the error std itself returned when it found no DOS
/// name at all, while std asked the mount manager again and returned the mount
/// folder's path. The two differ in result there (a path against an error),
/// never in a wrong path.
pub fn getFinalPathNameByHandle(handle: HANDLE, out_buffer: []u16) GetFinalPathNameByHandleError![]u16 {
    const file_name_opened = 0x8;
    const volume_name_dos = 0x0;
    const capacity: DWORD = @intCast(@min(out_buffer.len, std.math.maxInt(DWORD)));
    const written = GetFinalPathNameByHandleW(handle, out_buffer.ptr, capacity, file_name_opened | volume_name_dos);
    if (written == 0) {
        return switch (windows.GetLastError()) {
            .INVALID_HANDLE, .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .INVALID_NAME => error.BadPathName,
            else => |err| windows.unexpectedError(err),
        };
    }
    // Too small: the call returns the size it needs, terminator included.
    if (written >= capacity) return error.NameTooLong;
    return dosPathFromFinal(out_buffer[0..written]);
}

/// `path`, a final path as `GetFinalPathNameByHandleW` writes it, in std's DOS
/// form, rewritten inside its own storage:
///
///   - `\\?\C:\a\b` becomes `C:\a\b`;
///   - `\\?\UNC\server\share\a` becomes `\\server\share\a`;
///   - a path already in one of those two forms is returned unchanged;
///   - anything else (`\\?\Volume{...}\a`, a bare name, an empty path) has no DOS
///     name here and is `error.FileNotFound`, never a different path.
fn dosPathFromFinal(path: []u16) error{FileNotFound}![]u16 {
    const unc_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\UNC\\");
    const verbatim_prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\");
    if (std.mem.startsWith(u16, path, unc_prefix)) {
        const rest_len = path.len - unc_prefix.len;
        if (rest_len == 0) return error.FileNotFound;
        // `\\?\UNC\server\share` is `\\server\share`: the last two characters of
        // the prefix become the leading `\\`, so the rest stays where it is.
        const out = path[unc_prefix.len - 2 ..];
        out[0] = '\\';
        out[1] = '\\';
        std.mem.copyForwards(u16, path[0..out.len], out);
        return path[0..out.len];
    }
    if (std.mem.startsWith(u16, path, verbatim_prefix)) {
        const rest = path[verbatim_prefix.len..];
        if (!startsWithDrive(rest)) return error.FileNotFound;
        std.mem.copyForwards(u16, path[0..rest.len], rest);
        return path[0..rest.len];
    }
    if (startsWithDrive(path)) return path;
    if (path.len > 2 and path[0] == '\\' and path[1] == '\\' and path[2] != '?' and path[2] != '.') return path;
    return error.FileNotFound;
}

/// A drive letter, a colon, and a separator or the end.
fn startsWithDrive(path: []const u16) bool {
    if (path.len < 2 or path[1] != ':') return false;
    const letter = path[0];
    if (!((letter >= 'A' and letter <= 'Z') or (letter >= 'a' and letter <= 'z'))) return false;
    return path.len == 2 or path[2] == '\\';
}

pub extern "kernel32" fn SetEnvironmentVariableW(lpName: LPCWSTR, lpValue: ?LPCWSTR) callconv(.winapi) BOOL;

/// The fork's one declaration (the link opener's alias tests use it too).
pub extern "kernel32" fn GetShortPathNameW(lpszLongPath: LPCWSTR, lpszShortPath: [*]u16, cchBuffer: DWORD) callconv(.winapi) DWORD;

/// `SetLastError` taking std's `Win32Error`, which every caller names its
/// codes with; the extern itself takes the SDK's `DWORD`.
pub fn setLastError(err: windows.Win32Error) void {
    SetLastError(@backingInt(err));
}

pub const LockFileError = error{ SystemResources, WouldBlock, Unexpected };

/// `NtLockFile` with std's former status mapping.
pub fn lockFile(
    file_handle: HANDLE,
    event: ?HANDLE,
    apc_routine: ?*align(2) const windows.IO_APC_ROUTINE,
    apc_context: ?*anyopaque,
    io_status_block: *windows.IO_STATUS_BLOCK,
    byte_offset: *const windows.LARGE_INTEGER,
    length: *const windows.LARGE_INTEGER,
    key: ?*const ULONG,
    fail_immediately: u8,
    exclusive_lock: u8,
) LockFileError!void {
    const rc = windows.ntdll.NtLockFile(
        file_handle,
        event,
        apc_routine,
        apc_context,
        io_status_block,
        byte_offset,
        length,
        key,
        @fromBackingInt(@intCast(fail_immediately)),
        @fromBackingInt(@intCast(exclusive_lock)),
    );
    switch (rc) {
        .SUCCESS => return,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .LOCK_NOT_GRANTED => return error.WouldBlock,
        .ACCESS_VIOLATION => unreachable, // bad io_status_block pointer
        else => return windows.unexpectedStatus(rc),
    }
}

pub const UnlockFileError = error{ RangeNotLocked, Unexpected };

/// `NtUnlockFile` with std's former status mapping. `key` is the ULONG the
/// call documents (Zig 0.15's binding declared a pointer, passed as null).
pub fn unlockFile(
    file_handle: HANDLE,
    io_status_block: *windows.IO_STATUS_BLOCK,
    byte_offset: *const windows.LARGE_INTEGER,
    length: *const windows.LARGE_INTEGER,
    key: ULONG,
) UnlockFileError!void {
    const rc = windows.ntdll.NtUnlockFile(file_handle, io_status_block, byte_offset, length, key);
    switch (rc) {
        .SUCCESS => return,
        .RANGE_NOT_LOCKED => return error.RangeNotLocked,
        .ACCESS_VIOLATION => unreachable, // bad io_status_block pointer
        else => return windows.unexpectedStatus(rc),
    }
}

pub const GetOverlappedResultError = error{ WouldBlock, Unexpected };

/// `GetOverlappedResult` with std's former error mapping: `WouldBlock` when the
/// operation is still pending and `wait` is false.
pub fn getOverlappedResult(h: HANDLE, overlapped: *OVERLAPPED, wait: bool) GetOverlappedResultError!DWORD {
    var bytes: DWORD = undefined;
    if (GetOverlappedResult(h, overlapped, &bytes, @intFromBool(wait)) == 0) {
        switch (windows.GetLastError()) {
            .IO_INCOMPLETE => if (!wait) return error.WouldBlock else unreachable,
            else => |err| return windows.unexpectedError(err),
        }
    }
    return bytes;
}

pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: ?LPCWSTR,
    lpValue: ?LPCWSTR,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) i32;

test "event and wait helpers keep std's result mapping" {
    const event = try createEventExW(null, null, win32_types.CREATE_EVENT_MANUAL_RESET, win32_types.EVENT_ALL_ACCESS);
    defer windows.CloseHandle(event);
    try std.testing.expectError(error.WaitTimeOut, waitForSingleObjectEx(event, 0, false));
    try std.testing.expect(SetEvent(event) != 0);
    try waitForSingleObjectEx(event, 0, false);

    const handles = [_]HANDLE{ event, event };
    try std.testing.expectEqual(@as(u32, 0), try waitForMultipleObjectsEx(&handles, false, 0, false));
}

test "the re-homed process and module helpers keep std's error mapping" {
    // A handle to this process that grants only SYNCHRONIZE: terminating it is
    // refused, and the refusal maps to the error std gave.
    var limited: HANDLE = undefined;
    try std.testing.expect(DuplicateHandle(GetCurrentProcess(), GetCurrentProcess(), GetCurrentProcess(), &limited, win32_types.SYNCHRONIZE, win32_types.FALSE, 0) != 0);
    defer windows.CloseHandle(limited);
    try std.testing.expectError(error.AccessDenied, terminateProcess(limited, 1));
    // The process is still running: waiting on it times out.
    try std.testing.expectError(error.WaitTimeOut, waitForSingleObject(limited, 0));

    const kernel = try loadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll"));
    defer freeLibrary(kernel);
    var path: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const name = try getModuleFileNameW(kernel, &path, path.len);
    try std.testing.expect(name.len > 0 and name.len < path.len);
    try std.testing.expectError(error.FileNotFound, loadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("noctty-no-such-module.dll")));
}

test "the re-homed file helpers keep std's error mapping" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "present.txt", .data = "x" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPathFile(io, ".", &buf)];
    var present_buf: [std.fs.max_path_bytes]u8 = undefined;
    const present = try std.fmt.bufPrint(&present_buf, "{s}\\present.txt", .{dir});
    var missing_buf: [std.fs.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&missing_buf, "{s}\\absent.txt", .{dir});

    const attributes = try getFileAttributes(present);
    try std.testing.expect(attributes & win32_types.FILE_ATTRIBUTE_DIRECTORY == 0);
    try std.testing.expect((try getFileAttributes(dir)) & win32_types.FILE_ATTRIBUTE_DIRECTORY != 0);
    try std.testing.expectError(error.FileNotFound, getFileAttributes(missing));

    // `writeFile` writes at a given position through an OVERLAPPED.
    const file = try tmp.dir.createFile(io, "positioned.bin", .{ .read = true });
    defer file.close(io);
    try std.testing.expectEqual(@as(usize, 3), try writeFile(file.handle, "abc", null));
    try std.testing.expectEqual(@as(usize, 2), try writeFile(file.handle, "XY", 1));
    var back: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try file.readPositionalAll(io, &back, 0));
    try std.testing.expectEqualStrings("aXY", &back);
}

test "case-insensitive WTF-16 comparison follows the system table" {
    const w = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expect(eqlIgnoreCaseWtf16(w("Noctty.EXE"), w("noctty.exe")));
    try std.testing.expect(eqlIgnoreCaseWtf16(w("\u{00e9}cole"), w("\u{00c9}COLE")));
    try std.testing.expect(!eqlIgnoreCaseWtf16(w("noctty"), w("noctty.exe")));
    try std.testing.expect(!eqlIgnoreCaseWtf16(w("a"), w("b")));
    try std.testing.expect(eqlIgnoreCaseWtf16(w(""), w("")));
}

test "the performance counter ticks at a fixed rate" {
    const first = queryPerformanceCounter();
    const second = queryPerformanceCounter();
    try std.testing.expect(second >= first);
    try std.testing.expect(queryPerformanceFrequency() > 0);
}

test "openFile keeps std's status mapping and flags" {
    const w = std.unicode.utf8ToUtf16LeStringLiteral;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "present.txt", .data = "x" });
    try tmp.dir.createDir(io, "folder", .default_dir);

    const read = win32_types.GENERIC_READ | win32_types.SYNCHRONIZE;
    // A file opens through a directory handle, with a relative name.
    const file = try openFile(w("present.txt"), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN });
    windows.CloseHandle(file);

    // A name that is not there, in a folder that is or is not.
    try std.testing.expectError(error.FileNotFound, openFile(w("absent.txt"), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN }));
    try std.testing.expectError(error.FileNotFound, openFile(w("no-folder\\absent.txt"), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN }));

    // The filter tells files and folders apart, and `.` and `..` are folders.
    try std.testing.expectError(error.IsDir, openFile(w("folder"), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN }));
    try std.testing.expectError(error.NotDir, openFile(w("present.txt"), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN, .filter = .dir_only }));
    try std.testing.expectError(error.IsDir, openFile(w("."), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN }));
    try std.testing.expectError(error.IsDir, openFile(w(".."), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN }));
    const folder = try openFile(w("folder"), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN, .filter = .dir_only });
    windows.CloseHandle(folder);
    const either = try openFile(w("folder"), .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN, .filter = .any });
    windows.CloseHandle(either);

    // A sharing violation is an access error, as std mapped it.
    const held = try openFile(w("present.txt"), .{ .access_mask = read, .dir = tmp.dir.handle, .share_access = 0, .creation = win32_types.FILE_OPEN });
    defer windows.CloseHandle(held);
    try std.testing.expectError(error.AccessDenied, openFile(w("present.txt"), .{ .access_mask = win32_types.GENERIC_WRITE | win32_types.SYNCHRONIZE, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN }));

    // A name longer than a UNICODE_STRING holds.
    var long: [40000]u16 = @splat('a');
    try std.testing.expectError(error.NameTooLong, openFile(&long, .{ .access_mask = read, .dir = tmp.dir.handle, .creation = win32_types.FILE_OPEN }));

    // An absolute NT name ignores the directory: `\Device\Null` opens.
    const nul = try openFile(w("\\Device\\Null"), .{ .access_mask = win32_types.GENERIC_WRITE | win32_types.SYNCHRONIZE, .dir = tmp.dir.handle, .creation = win32_types.OPEN_EXISTING, .filter = .any });
    windows.CloseHandle(nul);
}

test "deviceIoControl maps a refused control code the way std did" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "plain.txt", .{ .read = true });
    defer file.close(std.testing.io);
    // A file that is no reparse point: STATUS_NOT_A_REPARSE_POINT, which std
    // reported as `error.Unexpected` (with its NTSTATUS trace).
    var buffer: [windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = @splat(0);
    try std.testing.expectError(error.Unexpected, deviceIoControl(file.handle, win32_types.FSCTL_GET_REPARSE_POINT, null, &buffer));
}

test "the final path name is std's DOS form" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "present.txt", .data = "x" });
    const file = try tmp.dir.openFile(io, "present.txt", .{});
    defer file.close(io);
    var system_dir = try std.Io.Dir.openDirAbsolute(io, "C:\\Windows", .{});
    defer system_dir.close(io);

    // std's own `realpath` reads the DOS form of the same handles (it is the
    // oracle: std's DOS-form final path, drive prefix stripped).
    var file_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_real = file_real_buf[0..try tmp.dir.realPathFile(io, "present.txt", &file_real_buf)];
    var dir_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_real = dir_real_buf[0..try tmp.dir.realPathFile(io, ".", &dir_real_buf)];
    var system_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const system_real = system_real_buf[0..try system_dir.realPathFile(io, ".", &system_real_buf)];

    const handles = [_]HANDLE{ file.handle, tmp.dir.handle, system_dir.handle };
    const expected = [_][]const u8{ file_real, dir_real, system_real };
    for (handles, expected) |handle, want| {
        var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
        const got = try getFinalPathNameByHandle(handle, &buf);
        var utf8: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.unicode.utf16LeToUtf8(&utf8, got);
        try std.testing.expectEqualStrings(want, utf8[0..n]);
        // No `\\?\` prefix, and an absolute drive path.
        try std.testing.expect(got.len > 3 and got[1] == ':' and got[2] == '\\');
    }

    var small: [4]u16 = undefined;
    try std.testing.expectError(error.NameTooLong, getFinalPathNameByHandle(file.handle, &small));
    var any: [windows.PATH_MAX_WIDE]u16 = undefined;
    try std.testing.expectError(error.FileNotFound, getFinalPathNameByHandle(windows.INVALID_HANDLE_VALUE, &any));
}

test "the final path name is the spelling the handle was opened by: a case variant and an 8.3 alias" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    // In the temp folder, through `GetShortPathNameW`: the checkout's drive may
    // make no 8.3 names (a ReFS Dev Drive, a CI work volume), and a hand-made
    // alias may name nothing (NTFS hashes some short bases).
    var tmp = try @import("../../os/TempDir.zig").init();
    defer tmp.deinit();
    const folder = "noctty final path folder";
    const leaf = "present file.txt";
    try tmp.dir.createDir(io, folder, .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = folder ++ "\\" ++ leaf, .data = "x" });
    const long = try tmp.dir.realPathFileAlloc(io, folder ++ "\\" ++ leaf, alloc);
    defer alloc.free(long);

    // The file's name in other case: normalization would give the on-disk case.
    const variant = try alloc.dupe(u8, long);
    defer alloc.free(variant);
    for (variant[variant.len - leaf.len ..]) |*ch| ch.* = std.ascii.toUpper(ch.*);
    try std.testing.expect(!std.mem.eql(u8, variant, long));
    try expectFinalPathAsOpened(variant);

    // The 8.3 alias, which normalization would expand.
    const long_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, long);
    defer alloc.free(long_w);
    var short_w: [windows.PATH_MAX_WIDE]u16 = undefined;
    const short_len = GetShortPathNameW(long_w.ptr, &short_w, short_w.len);
    try std.testing.expect(short_len != 0 and short_len < short_w.len);
    const short = try std.unicode.wtf16LeToWtf8Alloc(alloc, short_w[0..short_len]);
    defer alloc.free(short);
    if (std.mem.eql(u8, short, long)) {
        std.log.warn("no 8.3 alias for the fixture; 8.3 names are off on this volume", .{});
        return error.SkipZigTest;
    }
    try expectFinalPathAsOpened(short);
}

/// Opens `path` and checks `getFinalPathNameByHandle` gives that spelling back,
/// as std's own `realPath` of the handle does (std 0.17 still reads the object
/// name, as 0.15.2's did).
fn expectFinalPathAsOpened(path: []const u8) !void {
    const io = std.testing.io;
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const got = try getFinalPathNameByHandle(file.handle, &buf);
    var got_utf8: [std.fs.max_path_bytes]u8 = undefined;
    errdefer std.debug.print("opened {s}\n", .{path});
    try std.testing.expectEqualStrings(path, got_utf8[0..std.unicode.wtf16LeToWtf8(&got_utf8, got)]);
    var real: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(path, real[0..try file.realPath(io, &real)]);
}

test "lockFile and unlockFile keep std's status mapping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try tmp.dir.createFile(std.testing.io, "locked.bin", .{ .read = true });
    defer first.close(std.testing.io);
    const second = try tmp.dir.openFile(std.testing.io, "locked.bin", .{});
    defer second.close(std.testing.io);

    var io: windows.IO_STATUS_BLOCK = undefined;
    const offset: windows.LARGE_INTEGER = 0;
    const length: windows.LARGE_INTEGER = 1;
    try lockFile(first.handle, null, null, null, &io, &offset, &length, null, win32_types.TRUE, win32_types.TRUE);
    // The same range, from another handle, without waiting.
    try std.testing.expectError(error.WouldBlock, lockFile(second.handle, null, null, null, &io, &offset, &length, null, win32_types.TRUE, win32_types.TRUE));
    try unlockFile(first.handle, &io, &offset, &length, 0);
    try std.testing.expectError(error.RangeNotLocked, unlockFile(first.handle, &io, &offset, &length, 0));
    try lockFile(second.handle, null, null, null, &io, &offset, &length, null, win32_types.TRUE, win32_types.TRUE);
}

test "setLastError writes the thread's last error" {
    setLastError(.ACCESS_DENIED);
    try std.testing.expectEqual(windows.Win32Error.ACCESS_DENIED, windows.GetLastError());
    setLastError(.SUCCESS);
    try std.testing.expectEqual(windows.Win32Error.SUCCESS, windows.GetLastError());
}

fn expectDosForm(final: []const u8, expected: []const u8) !void {
    var buf: [128]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&buf, final);
    const got = try dosPathFromFinal(buf[0..len]);
    var utf8: [128]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&utf8, got);
    try std.testing.expectEqualStrings(expected, utf8[0..n]);
}

fn expectNoDosForm(final: []const u8) !void {
    var buf: [128]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&buf, final);
    try std.testing.expectError(error.FileNotFound, dosPathFromFinal(buf[0..len]));
}

test "dosPathFromFinal strips the verbatim prefix and keeps UNC paths whole" {
    // A drive path loses `\\?\`.
    try expectDosForm("\\\\?\\C:\\a\\b", "C:\\a\\b");
    try expectDosForm("\\\\?\\c:\\", "c:\\");
    try expectDosForm("\\\\?\\D:", "D:");
    // A UNC path keeps its two leading backslashes: stripping only `\\?\` would
    // leave `UNC\server\share`, a path to a different place.
    try expectDosForm("\\\\?\\UNC\\s\\sh\\a", "\\\\s\\sh\\a");
    try expectDosForm("\\\\?\\UNC\\server\\share", "\\\\server\\share");
    // A path already in DOS form is unchanged.
    try expectDosForm("C:\\a\\b", "C:\\a\\b");
    try expectDosForm("\\\\server\\share\\a", "\\\\server\\share\\a");
    // Without a drive letter there is no DOS name: an error, never another path.
    try expectNoDosForm("\\\\?\\Volume{383da0b0-717f-41b6-8c36-00500992b58d}\\a");
    try expectNoDosForm("\\\\?\\Volume{383da0b0-717f-41b6-8c36-00500992b58d}");
    try expectNoDosForm("\\\\?\\GLOBALROOT\\Device\\HarddiskVolume1\\a");
    try expectNoDosForm("\\\\?\\1:\\a");
    try expectNoDosForm("\\\\?\\UNC\\");
    try expectNoDosForm("\\\\?\\");
    try expectNoDosForm("\\\\.\\C:\\a");
    try expectNoDosForm("relative\\a");
    try expectNoDosForm("");
}
