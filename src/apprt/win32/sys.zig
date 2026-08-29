//! Central Win32 ABI declarations used by the Windows application runtime.

const std = @import("std");
const windows = std.os.windows;
const win32_types = @import("../win32_types.zig");
const c = @import("consts.zig");

const ATOM = win32_types.ATOM;
const LPCWSTR = win32_types.LPCWSTR;
const HBRUSH = win32_types.HBRUSH;
const HCURSOR = win32_types.HCURSOR;
const HDC = win32_types.HDC;
const HGLRC = win32_types.HGLRC;
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
const BOOL = win32_types.BOOL;
pub const HWND = win32_types.HWND;
const HINSTANCE = win32_types.HINSTANCE;
const INTRESOURCE = win32_types.INTRESOURCE;
const COLORREF = win32_types.COLORREF;
const HANDLE = windows.HANDLE;
const SIZE_T = windows.SIZE_T;
const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
const GUID = windows.GUID;
const HRESULT = windows.HRESULT;
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

pub const WINDOWPLACEMENT = extern struct {
    length: UINT,
    flags: UINT,
    showCmd: UINT,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};

pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: *WINDOWPOS,
};

pub const WNDCLASSEXW = win32_types.WNDCLASSEXW;
pub const CREATESTRUCTW = win32_types.CREATESTRUCTW;

pub const MONITORINFO = extern struct {
    cbSize: u32,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: u32,
};

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
    lfFaceName: [c.LF_FACESIZE]u16 = [_]u16{0} ** c.LF_FACESIZE,
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

pub extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.winapi) BOOL;

pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) BOOL;

pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;

pub extern "user32" fn GetWindowPlacement(hWnd: HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.winapi) BOOL;

pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) i32;

pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;

pub extern "user32" fn IsWindow(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(.winapi) ?HMONITOR;

pub extern "user32" fn EnumDisplayMonitors(hdc: HDC, lprcClip: ?*const RECT, lpfnEnum: *const fn (HMONITOR, HDC, *RECT, LPARAM) callconv(.winapi) BOOL, dwData: LPARAM) callconv(.winapi) BOOL;

pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;

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

pub extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn MoveWindow(hWnd: HWND, X: i32, Y: i32, nWidth: i32, nHeight: i32, bRepaint: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;

pub extern "user32" fn PostThreadMessageW(idThread: DWORD, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;

pub extern "user32" fn PostQuitMessage(nExitCode: i32) callconv(.winapi) void;

pub extern "user32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(.winapi) i32;

pub extern "user32" fn RegisterHotKey(hWnd: ?HWND, id: i32, fsModifiers: UINT, vk: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn RedrawWindow(hWnd: HWND, lprcUpdate: ?*const RECT, hrgnUpdate: ?*anyopaque, flags: UINT) callconv(.winapi) BOOL;

pub extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: UINT_PTR, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(.winapi) UINT_PTR;

pub extern "user32" fn SetCursor(hCursor: HCURSOR) callconv(.winapi) HCURSOR;

pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;

pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;

pub extern "user32" fn GetCaretPos(lpPoint: *POINT) callconv(.winapi) BOOL;

pub extern "user32" fn MonitorFromPoint(pt: POINT, dwFlags: DWORD) callconv(.winapi) ?HMONITOR;

pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: u32, bAlpha: BYTE, dwFlags: u32) callconv(.winapi) BOOL;

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

pub extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: i32, y: i32, nReserved: i32, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) BOOL;

pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;

pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;

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

pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub extern "kernel32" fn SetThreadErrorMode(dwNewMode: DWORD, lpOldMode: ?*DWORD) callconv(.winapi) BOOL;

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

pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) HMODULE;

pub extern "kernel32" fn SetCurrentDirectoryW(lpPathName: LPCWSTR) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalLock(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "kernel32" fn GlobalUnlock(hMem: ?*anyopaque) callconv(.winapi) BOOL;

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

pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) HGDIOBJ;

pub extern "gdi32" fn GetStockObject(i: i32) callconv(.winapi) HGDIOBJ;

pub extern "gdi32" fn SetDCBrushColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;

pub extern "gdi32" fn SetDCPenColor(hdc: HDC, color: u32) callconv(.winapi) u32;

pub extern "gdi32" fn RoundRect(hdc: HDC, left: i32, top: i32, right: i32, bottom: i32, width: i32, height: i32) callconv(.winapi) BOOL;

pub extern "advapi32" fn RegOpenKeyExW(hKey: HKEY, lpSubKey: LPCWSTR, ulOptions: DWORD, samDesired: REGSAM, phkResult: *HKEY) callconv(.winapi) i32;

pub extern "advapi32" fn RegQueryValueExW(hKey: HKEY, lpValueName: LPCWSTR, lpReserved: ?*DWORD, lpType: ?*DWORD, lpData: ?*u8, lpcbData: ?*DWORD) callconv(.winapi) i32;

pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

pub extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;

pub extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;

pub extern "opengl32" fn wglGetCurrentContext() callconv(.winapi) HGLRC;

pub extern "opengl32" fn wglGetCurrentDC() callconv(.winapi) HDC;

pub extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

pub extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) BOOL;

pub extern "dwmapi" fn DwmDefWindowProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM, plResult: *LRESULT) callconv(.winapi) BOOL;

pub extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(.winapi) ?*anyopaque;

pub extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: ?*anyopaque) callconv(.winapi) BOOL;

pub extern "imm32" fn ImmGetCompositionStringW(hIMC: *anyopaque, dwIndex: u32, lpBuf: ?[*]u16, dwBufLen: u32) callconv(.winapi) i32;

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

pub extern "shell32" fn DragQueryFileW(hDrop: *anyopaque, iFile: UINT, lpszFile: ?[*]u16, cch: UINT) callconv(.winapi) UINT;

pub extern "shell32" fn DragFinish(hDrop: *anyopaque) callconv(.winapi) void;

pub extern "user32" fn EnableWindow(hWnd: HWND, bEnable: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn GetParent(hWnd: HWND) callconv(.winapi) ?HWND;

pub extern "user32" fn IsChild(hWndParent: HWND, hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn IsWindowEnabled(hWnd: HWND) callconv(.winapi) BOOL;

pub extern "user32" fn SetScrollRange(hWnd: HWND, nBar: c_int, nMinPos: c_int, nMaxPos: c_int, bRedraw: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn SetScrollPos(hWnd: HWND, nBar: c_int, nPos: c_int, bRedraw: BOOL) callconv(.winapi) c_int;

pub extern "user32" fn ShowScrollBar(hWnd: HWND, wBar: c_int, bShow: BOOL) callconv(.winapi) BOOL;

pub extern "user32" fn SetWindowRgn(hWnd: HWND, hRgn: ?HRGN, bRedraw: BOOL) callconv(.winapi) c_int;

pub extern "user32" fn NotifyWinEvent(event: u32, hwnd: HWND, idObject: i32, idChild: i32) callconv(.winapi) void;

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
    lpValueName: LPCWSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const u8,
    cbData: DWORD,
) callconv(.winapi) i32;
