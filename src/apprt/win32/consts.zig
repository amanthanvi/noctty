//! Win32 API constants used by the Windows application runtime.

const win32_types = @import("../win32_types.zig");

const INTRESOURCE = win32_types.INTRESOURCE;
const LPARAM = win32_types.LPARAM;
const WPARAM = win32_types.WPARAM;
const UINT = win32_types.UINT;
const UINT_PTR = win32_types.UINT_PTR;
const DWORD = win32_types.DWORD;
const LRESULT = win32_types.LRESULT;
const WORD = win32_types.WORD;

pub const CS_OWNDC = 0x0020;
pub const CW_USEDEFAULT = @as(i32, @bitCast(@as(u32, 0x80000000)));
pub const GWLP_USERDATA = -21;
pub const GWLP_WNDPROC = -4;
pub const GWL_STYLE = -16;
pub const GWL_EXSTYLE = -20;
pub const IDC_ARROW = @as(INTRESOURCE, @ptrFromInt(32512));
pub const ID_ICON_GHOSTTY = 1;
pub const IMAGE_ICON = 1;
pub const LR_SHARED = 0x00008000;
pub const SM_CXICON = 11;
pub const SM_CYICON = 12;
pub const SM_CXSMICON = 49;
pub const SM_CYSMICON = 50;
pub const WM_SETICON = 0x0080;
pub const ICON_SMALL = 0;
pub const ICON_BIG = 1;
pub const HTNOWHERE = 0;
pub const HTCLIENT = 1;
pub const HTCAPTION = 2;
pub const HTSYSMENU = 3;
pub const HTMINBUTTON = 8;
pub const HTMAXBUTTON = 9;
pub const HTLEFT = 10;
pub const HTRIGHT = 11;
pub const HTTOP = 12;
pub const HTTOPLEFT = 13;
pub const HTTOPRIGHT = 14;
pub const HTBOTTOM = 15;
pub const HTBOTTOMLEFT = 16;
pub const HTBOTTOMRIGHT = 17;
pub const HTCLOSE = 20;
pub const HTTRANSPARENT: LRESULT = -1;

pub const SW_SHOW = 5;
pub const SW_SHOWNOACTIVATE = 4;
pub const SW_RESTORE = 9;
pub const SW_MAXIMIZE = 3;
pub const SW_HIDE = 0;
const WM_APP = 0x8000;
pub const WM_ACTIVATE = 0x0006;
pub const WA_INACTIVE = 0;
pub const WM_COMMAND = 0x0111;
pub const WM_CAPTURECHANGED = 0x0215;
pub const WM_CLOSE = 0x0010;
pub const WM_DESTROY = 0x0002;
pub const WM_DRAWITEM = 0x002B;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_GETMINMAXINFO = 0x0024;
pub const WM_CHAR = 0x0102;
pub const WM_DEADCHAR = 0x0103;
pub const WM_HOTKEY = 0x0312;
pub const WM_IME_SETCONTEXT = 0x0281;
pub const WM_IME_STARTCOMPOSITION = 0x010D;
pub const WM_IME_ENDCOMPOSITION = 0x010E;
pub const WM_IME_COMPOSITION = 0x010F;
pub const GCS_COMPSTR: u32 = 0x0008;
pub const GCS_RESULTSTR: u32 = 0x0800;
pub const CFS_POINT: u32 = 0x0002;
pub const CFS_EXCLUDE: u32 = 0x0080;
pub const ISC_SHOWUICOMPOSITIONWINDOW: LPARAM = 0x80000000;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_POINTERHWHEEL = 0x024F;
pub const WM_POINTERWHEEL = 0x024E;
pub const WM_NCCREATE = 0x0081;
pub const WM_NCCALCSIZE = 0x0083;
pub const WM_NCHITTEST = 0x0084;
pub const WM_NCMOUSEMOVE = 0x00A0;
pub const WM_NCLBUTTONDOWN = 0x00A1;
pub const WM_NCLBUTTONUP = 0x00A2;
pub const WM_NCMOUSELEAVE = 0x02A2;
pub const WM_SYSCOMMAND = 0x0112;
pub const SC_CLOSE: WPARAM = 0xF060;
pub const SC_MINIMIZE: WPARAM = 0xF020;
pub const SC_MAXIMIZE: WPARAM = 0xF030;
pub const SC_RESTORE: WPARAM = 0xF120;
pub const WM_PAINT = 0x000F;
pub const WM_QUIT = 0x0012;
pub const WM_TIMER = 0x0113;
pub const WM_CTLCOLOREDIT = 0x0133;
pub const WM_CTLCOLORBTN = 0x0135;
pub const WM_CTLCOLORSTATIC = 0x0138;
pub const WM_GETOBJECT: UINT = 0x003D;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const XBUTTON1: WORD = 0x0001;
pub const XBUTTON2: WORD = 0x0002;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_SETCURSOR = 0x0020;
pub const WM_SETFOCUS = 0x0007;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_SIZE = 0x0005;
pub const WM_SHOWWINDOW = 0x0018;
pub const WM_WINDOWPOSCHANGED = 0x0047;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub const SIZE_MAXIMIZED: u32 = 2;
pub const SIZE_MINIMIZED: u32 = 1;
pub const SIZE_RESTORED: u32 = 0;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_SYSCHAR = 0x0106;
pub const WM_SYSDEADCHAR = 0x0107;
pub const WM_WINHOSTTY_WAKE = WM_APP + 1;
pub const WM_WINHOSTTY_UPDATE = WM_APP + 2;
pub const WM_WINHOSTTY_TOAST_ACTIVATION = WM_APP + 3;
pub const WM_WINHOSTTY_HOST_NEW_TAB = WM_APP + 4;
pub const WM_WINHOSTTY_UIA_DISCONNECT = WM_APP + 5;
pub const WM_WINHOSTTY_UIA_QUERY_REFRESH = WM_APP + 6;
pub const WM_WINHOSTTY_TERMINAL_HANDOFF = WM_APP + 7;

pub const PM_NOREMOVE: UINT = 0x0000;
pub const PM_REMOVE: UINT = 0x0001;
pub const WS_OVERLAPPED = 0x00000000;
pub const WS_CHILD = 0x40000000;
pub const WS_CLIPCHILDREN = 0x02000000;
pub const WS_CLIPSIBLINGS = 0x04000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_TABSTOP = 0x00010000;

pub const WS_POPUP = 0x80000000;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const MOD_ALT = 0x0001;
pub const MOD_CONTROL = 0x0002;
pub const MOD_SHIFT = 0x0004;
pub const MOD_WIN = 0x0008;
pub const TO_UNICODE_NO_STATE_CHANGE: UINT = 0x0004;
pub const MAPVK_VK_TO_VSC: UINT = 0;
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_FRAMECHANGED = 0x0020;
pub const RDW_INVALIDATE: UINT = 0x0001;
pub const RDW_INTERNALPAINT: UINT = 0x0002;
pub const RDW_ERASE: UINT = 0x0004;
pub const RDW_NOCHILDREN: UINT = 0x0040;
pub const RDW_ALLCHILDREN: UINT = 0x0080;
pub const RDW_UPDATENOW: UINT = 0x0100;
pub const RDW_FRAME: UINT = 0x0400;
pub const MONITOR_DEFAULTTONEAREST = 0x00000002;
pub const MONITOR_DEFAULTTOPRIMARY = 0x00000001;
pub const MONITORINFOF_PRIMARY = 0x00000001;
pub const COLOR_WINDOW = 5;
pub const CF_UNICODETEXT = 13;

pub const GMEM_MOVEABLE = 0x0002;
pub const GMEM_ZEROINIT = 0x0040;
pub const LWA_COLORKEY = 0x00000001;
pub const LWA_ALPHA = 0x00000002;
pub const TRANSPARENT = 1;
pub const OPAQUE = 2;
pub const MB_OK = 0x00000000;
pub const MB_ICONERROR = 0x00000010;
pub const MB_ICONINFORMATION = 0x00000040;
pub const MB_SETFOREGROUND = 0x00010000;
pub const MK_CONTROL = 0x0008;
pub const MK_LBUTTON = 0x0001;
pub const MK_MBUTTON = 0x0010;
pub const MK_RBUTTON = 0x0002;

pub const MK_SHIFT = 0x0004;
pub const MK_XBUTTON1 = 0x0020;
pub const MK_XBUTTON2 = 0x0040;
pub const EN_CHANGE = 0x0300;
pub const BS_OWNERDRAW = 0x0000000B;
pub const SS_RIGHT = 0x00000002;
pub const SS_CENTERIMAGE = 0x00000200;
pub const SS_OWNERDRAW = 0x0000000D;
pub const ES_AUTOHSCROLL = 0x0080;
pub const BN_CLICKED = 0;
pub const BN_SETFOCUS = 6;
pub const BN_KILLFOCUS = 7;
pub const EM_SETSEL = 0x00B1;
pub const EM_GETSEL = 0x00B0;
pub const EM_CHARFROMPOS = 0x00D7;
pub const EM_SETMARGINS = 0x00D3;
pub const EM_SETCUEBANNER = 0x1501;
pub const EC_LEFTMARGIN: usize = 0x0001;
pub const EC_RIGHTMARGIN: usize = 0x0002;
pub const ODT_BUTTON = 4;
pub const ODT_STATIC = 5;
pub const ODS_SELECTED = 0x0001;
pub const ODS_DISABLED = 0x0004;
pub const ODS_FOCUS = 0x0010;
pub const TME_LEAVE = 0x00000002;
pub const TME_NONCLIENT = 0x00000010;
pub const DT_CENTER = 0x00000001;
pub const DT_VCENTER = 0x00000004;
pub const DT_SINGLELINE = 0x00000020;
pub const DT_NOPREFIX = 0x00000800;
pub const DT_END_ELLIPSIS = 0x00008000;
pub const DT_LEFT = 0x00000000;

pub const WM_THEMECHANGED = 0x031A;
pub const WM_SYSCOLORCHANGE = 0x0015;
pub const WM_DWMCOLORIZATIONCOLORCHANGED: UINT = 0x0320;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const DWMSBT_NONE: u32 = 1;

pub const DWMSBT_TABBEDWINDOW: u32 = 4;
pub const OS_BUILD_WIN10_22H2: u32 = 19045;
pub const OS_BUILD_WIN11_21H2: u32 = 22000;
pub const OS_BUILD_WIN11_22H2: u32 = 22621;
pub const DC_BRUSH: i32 = 18;
pub const DC_PEN: i32 = 19;

pub const SPI_GETHIGHCONTRAST: UINT = 0x0042;
pub const SPI_GETNONCLIENTMETRICS: UINT = 0x0029;
pub const SPI_GETCLIENTAREAANIMATION: UINT = 0x1042;

/// See src/apprt/win32_tween.zig for the scheduler contract.
pub const TWEEN_TIMER_ID: UINT_PTR = 0x77684701; // "whgT1" in 32-bit hex
pub const TWEEN_TIMER_INTERVAL_MS: UINT = 16;
pub const SEARCH_TIMER_ID: UINT_PTR = 0x77684702; // "whgT2" in 32-bit hex
pub const SEARCH_TIMER_INTERVAL_MS: UINT = 20;
pub const SCROLLBAR_TIMER_ID: UINT_PTR = 0x77684703; // "whgT3" in 32-bit hex
pub const SCROLLBAR_TIMER_INTERVAL_MS: UINT = 16;
pub const RESIZE_SETTLE_TIMER_ID: UINT_PTR = 0x77684704; // "whgT4" in 32-bit hex
pub const RESIZE_SETTLE_TIMER_INTERVAL_MS: UINT = 16;
pub const TERMINAL_UIA_TIMER_ID: UINT_PTR = 0x77684705; // "whgT5" in 32-bit hex
pub const RESIZE_SETTLE_REPAINT_TICKS: u8 = 12;
pub const FW_NORMAL: i32 = 400;
pub const DEFAULT_CHARSET: u8 = 1;
pub const OUT_DEFAULT_PRECIS: u8 = 0;
pub const CLIP_DEFAULT_PRECIS: u8 = 0;
pub const CLEARTYPE_QUALITY: u8 = 5;
pub const DEFAULT_PITCH: u8 = 0;
pub const FF_DONTCARE: u8 = 0;
pub const LF_FACESIZE = 32;
pub const HCF_HIGHCONTRASTON: DWORD = 0x00000001;
pub const COLOR_WINDOWTEXT = 8;
pub const COLOR_WINDOWFRAME = 6;
pub const COLOR_BTNFACE = 15;
pub const COLOR_BTNTEXT = 18;
pub const COLOR_GRAYTEXT = 17;
pub const COLOR_HIGHLIGHT = 13;
pub const COLOR_HIGHLIGHTTEXT = 14;
pub const HKEY_CURRENT_USER: usize = 0x80000001;
pub const KEY_READ: DWORD = 0x20019;
pub const REG_DWORD: DWORD = 4;
pub const ERROR_SUCCESS: i32 = 0;
pub const ERROR_MOD_NOT_FOUND: DWORD = 126;
pub const PFD_DRAW_TO_WINDOW = 0x00000004;
pub const PFD_SUPPORT_OPENGL = 0x00000020;
pub const PFD_DOUBLEBUFFER = 0x00000001;
pub const PFD_TYPE_RGBA = 0;
pub const PFD_MAIN_PLANE = 0;
pub const SEM_FAILCRITICALERRORS: DWORD = 0x0001;
pub const SEM_NOOPENFILEERRORBOX: DWORD = 0x8000;

pub const MF_STRING: UINT = 0x00000000;
pub const MF_SEPARATOR: UINT = 0x00000800;
pub const MF_GRAYED: UINT = 0x00000001;
pub const TPM_LEFTALIGN: UINT = 0x0000;
pub const TPM_TOPALIGN: UINT = 0x0000;
pub const TPM_RETURNCMD: UINT = 0x0100;
pub const TPM_RIGHTBUTTON: UINT = 0x0002;
pub const WM_NULL: UINT = 0x0000;
pub const WM_SETFONT: UINT = 0x0030;
pub const CTX_COPY: usize = 4001;
pub const CTX_PASTE: usize = 4002;
pub const CTX_SELECT_ALL: usize = 4003;
pub const CTX_FIND: usize = 4004;
pub const CTX_COMMAND_PALETTE: usize = 4005;
pub const CTX_NEW_TAB: usize = 4006;
pub const CTX_SPLIT_RIGHT: usize = 4007;
pub const CTX_NEW_WINDOW: usize = 4008;
pub const CTX_INSPECTOR: usize = 4009;
pub const CTX_SPLIT_DOWN: usize = 4010;
pub const CTX_SPLIT_LEFT: usize = 4011;
pub const CTX_SPLIT_UP: usize = 4012;
pub const CTX_TAB_RENAME: usize = 4020;
pub const CTX_TAB_CLOSE: usize = 4021;
pub const CTX_TAB_CLOSE_OTHERS: usize = 4022;
pub const CTX_TAB_MOVE_LEFT: usize = 4023;
pub const CTX_TAB_MOVE_RIGHT: usize = 4024;
pub const CTX_PROFILE_BASE: usize = 4100; // profile dropdown items: CTX_PROFILE_BASE + index
pub const SEARCH_BG_ID: usize = 2100;
pub const SEARCH_EDIT_ID: usize = 2101;
pub const SEARCH_PREV_ID: usize = 2102;
pub const SEARCH_NEXT_ID: usize = 2103;
pub const SEARCH_REGEX_ID: usize = 2104;
pub const SEARCH_CASE_ID: usize = 2105;
pub const SEARCH_WORD_ID: usize = 2106;
pub const SEARCH_RESULTS_ID: usize = 2107;
pub const SEARCH_CLOSE_ID: usize = 2108;
pub const MF_POPUP: UINT = 0x00000010;
pub const MF_CHECKED: UINT = 0x00000008;

pub const VK_BACK = 0x08;
pub const VK_TAB = 0x09;
pub const VK_RETURN = 0x0D;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_PAUSE = 0x13;
pub const VK_CAPITAL = 0x14;
pub const VK_ESCAPE = 0x1B;
pub const VK_SPACE = 0x20;
pub const VK_PRIOR = 0x21;
pub const VK_NEXT = 0x22;
pub const VK_END = 0x23;
pub const VK_HOME = 0x24;
pub const VK_LEFT = 0x25;
pub const VK_UP = 0x26;
pub const VK_RIGHT = 0x27;
pub const VK_DOWN = 0x28;
pub const VK_SNAPSHOT = 0x2C;
pub const VK_INSERT = 0x2D;
pub const VK_DELETE = 0x2E;
pub const VK_0 = 0x30;
pub const VK_9 = 0x39;
pub const VK_A = 0x41;
pub const VK_Z = 0x5A;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;
pub const VK_APPS = 0x5D;
pub const VK_NUMPAD0 = 0x60;
pub const VK_NUMPAD9 = 0x69;
pub const VK_MULTIPLY = 0x6A;
pub const VK_ADD = 0x6B;
pub const VK_SEPARATOR = 0x6C;
pub const VK_SUBTRACT = 0x6D;
pub const VK_DECIMAL = 0x6E;
pub const VK_DIVIDE = 0x6F;
pub const VK_F1 = 0x70;
pub const VK_F3 = 0x72;
pub const VK_F2 = 0x71;
pub const VK_F24 = 0x87;
pub const VK_NUMLOCK = 0x90;
pub const VK_SCROLL = 0x91;
pub const VK_LSHIFT = 0xA0;
pub const VK_RSHIFT = 0xA1;
pub const VK_LCONTROL = 0xA2;
pub const VK_RCONTROL = 0xA3;
pub const VK_LMENU = 0xA4;
pub const VK_RMENU = 0xA5;
pub const VK_OEM_1 = 0xBA;
pub const VK_OEM_PLUS = 0xBB;
pub const VK_OEM_COMMA = 0xBC;
pub const VK_OEM_MINUS = 0xBD;
pub const VK_OEM_PERIOD = 0xBE;
pub const VK_OEM_2 = 0xBF;
pub const VK_OEM_3 = 0xC0;
pub const VK_OEM_4 = 0xDB;
pub const VK_OEM_5 = 0xDC;
pub const VK_OEM_6 = 0xDD;
pub const VK_OEM_7 = 0xDE;
pub const VK_OEM_102 = 0xE2;
pub const VK_PACKET = 0xE7;

pub const KF_EXTENDED = 1 << 24;
pub const KF_REPEAT = 1 << 30;
pub const SPI_GETWHEELSCROLLLINES = 0x0068;
pub const SPI_GETWHEELSCROLLCHARS = 0x006C;
pub const WHEEL_DELTA = 120;
pub const WHEEL_PAGESCROLL = 0xFFFF_FFFF;
pub const ERROR_FILE_NOT_FOUND = 2;
pub const PIPE_READMODE_BYTE = 0x00000000;
pub const PIPE_ACCESS_DUPLEX = 0x00000003;
pub const PIPE_UNLIMITED_INSTANCES = 255;

/// Refuse pipe clients that arrive over SMB from another machine. Named
/// pipes are reachable as `\\<host>\pipe\<name>` by default, so the
/// single-instance IPC pipe must opt out explicitly.
pub const PIPE_REJECT_REMOTE_CLIENTS = 0x00000008;

/// Token access and info classes used to resolve the current user's SID and
/// integrity level for the IPC pipe security descriptor.
pub const TOKEN_QUERY = 0x0008;
pub const TokenUser = 1;
pub const TokenIntegrityLevel = 25;

/// Least privilege that still permits `OpenProcessToken` on another
/// process, used to authenticate the IPC pipe server. Deliberately NOT
/// `PROCESS_QUERY_INFORMATION`, which additionally grants access this check
/// has no use for.
pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

/// Security quality-of-service flags for `CreateFileW` on a named pipe.
///
/// A named-pipe server impersonates at `SecurityImpersonation` BY DEFAULT.
/// Passing `SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION` lets the server
/// learn who we are but not act as us: `ImpersonateNamedPipeClient`'s
/// documented rule is that impersonation is permitted when "the requested
/// impersonation level of the token is less than SecurityImpersonation, such
/// as SecurityIdentification" -- the resulting token can be queried but not
/// used to open objects on our behalf.
pub const SECURITY_SQOS_PRESENT = 0x00100000;
pub const SECURITY_IDENTIFICATION = 0x00010000;

/// Relative identifier of the medium mandatory integrity level
/// (`S-1-16-8192`). Windows treats an object with no mandatory label as
/// medium integrity, so a label ACE is only worth adding above this.
pub const SECURITY_MANDATORY_MEDIUM_RID = 0x2000;

/// `S-1-16-4096`. The lowest level any interactive or service token
/// carries, used only as a sanity floor in tests.
pub const SECURITY_MANDATORY_LOW_RID = 0x1000;

/// SDDL string revision accepted by
/// `ConvertStringSecurityDescriptorToSecurityDescriptorW` and
/// `ConvertSecurityDescriptorToStringSecurityDescriptorW`.
pub const SDDL_REVISION_1 = 1;

/// `SECURITY_INFORMATION` bits used when reading the IPC pipe descriptor back
/// as SDDL. `LABEL_SECURITY_INFORMATION` selects the mandatory-label ACE in
/// the SACL without needing `SeSecurityPrivilege`.
pub const DACL_SECURITY_INFORMATION = 0x00000004;
pub const LABEL_SECURITY_INFORMATION = 0x00000010;
pub const OWNER_SECURITY_INFORMATION = 0x00000001;

/// `SE_OBJECT_TYPE.SE_KERNEL_OBJECT`, for reading a named pipe's descriptor
/// back off the live handle with `GetSecurityInfo`.
pub const SE_KERNEL_OBJECT = 6;

/// Main-thread COM apartment for in-process STA clients (settings path
/// picker, WinRT toast factory, OLE drag-drop targets). `S_FALSE` means
/// the desired STA already exists. `RPC_E_CHANGED_MODE` means the thread
/// is already in a different apartment and is not safe for STA-only work.
pub const COINIT_APARTMENTTHREADED: u32 = 0x2;
pub const RPC_E_CHANGED_MODE: i32 = @bitCast(@as(u32, 0x80010106));

/// Fallback when the target doesn't yet exist (first-time save). Unlike
/// `ReplaceFileW`, `MoveFileExW` works on a missing target.
pub const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;

pub const WM_DROPFILES: UINT = 0x0233;
