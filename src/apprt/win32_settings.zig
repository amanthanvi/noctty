//! Native Win32 settings window.
//!
//! Singleton top-level HWND owned by `App`. The `open_config` action
//! routes here; the Advanced section keeps the text-editor escape hatch
//! for config keys that do not have native controls. `App` invokes this
//! module via a thin handle so the module doesn't need to know `Host`,
//! `Surface`, or the other win32 apprt internals.
//!
//! Lifecycle:
//!   * `SettingsWindow.open(app)` — creates the HWND if absent,
//!     otherwise `SetForegroundWindow`s the existing one. Idempotent.
//!   * `SettingsWindow.close(self)` — called from WM_CLOSE; hides
//!     the HWND (kept around so reopen is cheap) and nulls `open`.
//!   * `SettingsWindow.destroy(self)` — called from App.terminate;
//!     `DestroyWindow` + free the struct.
//!
//! The editable draft is a shallow-cloned `Config` saved atomically
//! through `AppHandle.saveAndReload`. Per AGENTS.md:49, the clone MUST
//! NOT deinit an inherited `command` override.

const std = @import("std");
const windows = std.os.windows;
const Config = @import("../config/Config.zig");
const cli_help = @import("../cli/help.zig");
const win32_types = @import("win32_types.zig");

/// Minimal set of Win32 aliases + externs we need here. Shared ABI structs
/// live in `win32_types.zig` so this module stays free of an `*App` type
/// dependency without duplicating layout-sensitive declarations.
const HWND = win32_types.HWND;
const HINSTANCE = win32_types.HINSTANCE;
const HBRUSH = win32_types.HBRUSH;
const HCURSOR = win32_types.HCURSOR;
const HDC = win32_types.HDC;
const HGDIOBJ = win32_types.HGDIOBJ;
const HMENU = win32_types.HMENU;
const LPCWSTR = win32_types.LPCWSTR;
const UINT = win32_types.UINT;
const LRESULT = win32_types.LRESULT;
const WPARAM = win32_types.WPARAM;
const LPARAM = win32_types.LPARAM;
const BOOL = win32_types.BOOL;
const LONG_PTR = win32_types.LONG_PTR;
const ATOM = win32_types.ATOM;
const COLORREF = win32_types.COLORREF;
const RECT = win32_types.RECT;

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_MAXIMIZEBOX: u32 = 0x00010000;
const WS_EX_APPWINDOW: u32 = 0x00040000;
const SW_HIDE: i32 = 0;
const SW_SHOWNORMAL: i32 = 1;
const SW_RESTORE: i32 = 9;
const GWLP_USERDATA: i32 = -21;
const CS_HREDRAW: u32 = 0x2;
const CS_VREDRAW: u32 = 0x1;
const IDC_ARROW: usize = 32512;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

const WM_CLOSE: UINT = 0x0010;
const WM_NCCREATE: UINT = 0x0081;
const WM_PAINT: UINT = 0x000F;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_NCDESTROY: UINT = 0x0082;
const WM_COMMAND: UINT = 0x0111;
const WM_SIZE: UINT = 0x0005;
const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_TABSTOP: u32 = 0x00010000;
const BS_PUSHBUTTON: u32 = 0x0;
const BS_OWNERDRAW: u32 = 0xB;
const BTN_OPEN_EDITOR: usize = 101;
const BTN_SECTION_APPEARANCE: usize = 201;
const BTN_SECTION_TERMINAL: usize = 202;
const BTN_SECTION_SHELL: usize = 203;
const BTN_SECTION_KEYBINDINGS: usize = 204;
const BTN_SECTION_ADVANCED: usize = 205;
const BTN_SAVE: usize = 301;
const BTN_KEYBINDINGS_EDITOR: usize = 302;
const EDIT_SCROLLBACK: usize = 401;
const EDIT_FONT_SIZE: usize = 402;
const COMBO_CONFIRM_CLOSE: usize = 403;
const COMBO_COPY_ON_SELECT: usize = 404;
const COMBO_WINDOW_THEME: usize = 405;
const COMBO_SHELL_INTEG: usize = 406;
const CHK_TRIM_TRAIL: usize = 407;
const EDIT_BG_OPACITY: usize = 408;
const COMBO_CURSOR_STYLE: usize = 409;
const CHK_BG_BLUR: usize = 410;
const COMBO_PAD_BALANCE: usize = 411;
const EDIT_FONT_FAMILY: usize = 412;
const EDIT_THEME: usize = 413;
const EDIT_COMMAND: usize = 414;
const EDIT_PAD_X: usize = 415;
const EDIT_PAD_Y: usize = 416;
const CHK_DESKTOP_NOTIFICATIONS: usize = 417;
const CHK_APP_NOTIFY_CLIPBOARD: usize = 418;
const CHK_APP_NOTIFY_CONFIG: usize = 419;
const COMBO_AUTO_UPDATE: usize = 420;
const COMBO_AUTO_UPDATE_CHANNEL: usize = 421;
const COMBO_CLIPBOARD_READ: usize = 422;
const COMBO_CLIPBOARD_WRITE: usize = 423;
const COMBO_LINK_URL: usize = 424;
const COMBO_LINK_PREVIEWS: usize = 425;
const ES_NUMBER: u32 = 0x2000;
const ES_AUTOHSCROLL: u32 = 0x80;
const EN_CHANGE: u16 = 0x0300;
const EN_KILLFOCUS: u16 = 0x0200;
const CBN_SELCHANGE: u16 = 0x0001;
const BN_CLICKED: u16 = 0x0000;
const WM_SETTEXT: UINT = 0x000C;
const EM_LIMITTEXT: UINT = 0x00C5;
const BS_AUTOCHECKBOX: u32 = 0x3;
const BM_SETCHECK: UINT = 0x00F1;
const BM_GETCHECK: UINT = 0x00F0;
const BST_CHECKED: usize = 1;
const BST_UNCHECKED: usize = 0;
const CB_ADDSTRING: UINT = 0x0143;
const CB_SETCURSEL: UINT = 0x014E;
const CB_GETCURSEL: UINT = 0x0147;
const CB_RESETCONTENT: UINT = 0x014B;
const CBS_DROPDOWNLIST: u32 = 0x3;
const CBS_HASSTRINGS: u32 = 0x200;

/// Sections on the left rail. Section-specific controls (e.g. the
/// "Open in default editor" button in Advanced) are shown / hidden on
/// the active section; non-specific controls stay visible across
/// sections.
pub const Section = enum(u32) {
    appearance,
    terminal,
    shell,
    keybindings,
    advanced,

    fn fromButtonId(id: usize) ?Section {
        return switch (id) {
            BTN_SECTION_APPEARANCE => .appearance,
            BTN_SECTION_TERMINAL => .terminal,
            BTN_SECTION_SHELL => .shell,
            BTN_SECTION_KEYBINDINGS => .keybindings,
            BTN_SECTION_ADVANCED => .advanced,
            else => null,
        };
    }

    fn label(self: Section) [*:0]const u16 {
        return switch (self) {
            .appearance => std.unicode.utf8ToUtf16LeStringLiteral("Appearance"),
            .terminal => std.unicode.utf8ToUtf16LeStringLiteral("Terminal"),
            .shell => std.unicode.utf8ToUtf16LeStringLiteral("Shell"),
            .keybindings => std.unicode.utf8ToUtf16LeStringLiteral("Keybindings"),
            .advanced => std.unicode.utf8ToUtf16LeStringLiteral("Advanced"),
        };
    }

    fn headerText(self: Section) []const u8 {
        return switch (self) {
            .appearance => "Appearance",
            .terminal => "Terminal",
            .shell => "Shell",
            .keybindings => "Keybindings",
            .advanced => "Advanced",
        };
    }

    fn placeholderText(self: Section) []const u8 {
        return switch (self) {
            .appearance => "Font family, size, theme, opacity, cursor, padding, and background blur.",
            .terminal => "Scrollback, close confirmation, copy behavior, OSC 52 clipboard policy, link opening, and notifications.",
            .shell => "Default shell command and shell integration detection mode.",
            .keybindings => "Open the config file for keybind edits; list defaults, actions, and docs from the CLI.",
            .advanced => "Updater defaults plus the text editor escape hatch for config keys that do not yet have native controls.",
        };
    }
};

fn backgroundBlurFromCheckbox(
    current: Config.BackgroundBlur,
    checked: bool,
) Config.BackgroundBlur {
    if (!checked) return .false;

    return switch (current) {
        .radius => |radius| if (radius > 0) current else .true,
        .false, .true => .true,
    };
}

const PaddingAxis = enum { x, y };
const AppNotificationField = enum { clipboard, config };

fn keybindingsHelpText() []const u8 {
    return "Useful commands:\n" ++
        cli_help.keybinding_discovery_hint ++
        "\n" ++
        "Config syntax:\n" ++
        "  keybind = ctrl+shift+c=copy_to_clipboard\n" ++
        "  keybind = ctrl+a>n=new_window\n" ++
        "  keybind = chain=goto_split:left";
}

fn clipboardAccessFromComboIndex(idx: LRESULT) ?Config.ClipboardAccess {
    return switch (idx) {
        0 => .ask,
        1 => .allow,
        2 => .deny,
        else => null,
    };
}

fn comboIndexFromClipboardAccess(value: Config.ClipboardAccess) usize {
    return switch (value) {
        .ask => 0,
        .allow => 1,
        .deny => 2,
    };
}

fn linkUrlFromComboIndex(idx: LRESULT) ?bool {
    return switch (idx) {
        0 => true,
        1 => false,
        else => null,
    };
}

fn comboIndexFromLinkUrl(value: bool) usize {
    return if (value) 0 else 1;
}

fn linkPreviewsFromComboIndex(idx: LRESULT) ?Config.LinkPreviews {
    return switch (idx) {
        0 => .true,
        1 => .osc8,
        2 => .false,
        else => null,
    };
}

fn comboIndexFromLinkPreviews(value: Config.LinkPreviews) usize {
    return switch (value) {
        .true => 0,
        .osc8 => 1,
        .false => 2,
    };
}

extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
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
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: i32) callconv(.winapi) BOOL;
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) HCURSOR;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: i32, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: i32) callconv(.winapi) LONG_PTR;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn IsWindow(hWnd: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: i32) callconv(.winapi) i32;
extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "gdi32" fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;
extern "gdi32" fn GetStockObject(i: i32) callconv(.winapi) HGDIOBJ;
extern "gdi32" fn SetDCBrushColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SetTextColor(hdc: HDC, color: COLORREF) callconv(.winapi) COLORREF;
extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.winapi) i32;
extern "user32" fn DrawTextW(hDC: HDC, lpchText: LPCWSTR, cchText: i32, lprc: *RECT, format: UINT) callconv(.winapi) i32;

const DC_BRUSH: i32 = 18;
const TRANSPARENT: i32 = 1;
const DT_CENTER: UINT = 0x1;
const DT_VCENTER: UINT = 0x4;
const DT_SINGLELINE: UINT = 0x20;
const DT_NOPREFIX: UINT = 0x800;

const PAINTSTRUCT = win32_types.PAINTSTRUCT;
const CREATESTRUCTW = win32_types.CREATESTRUCTW;
const WNDCLASSEXW = win32_types.WNDCLASSEXW;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("winghostty.win32.settings");
const edit_text_max_code_units: usize = 4096;
const edit_text_max_utf8: usize = edit_text_max_code_units * 3;

/// Error set returned from `AppHandle.saveAndReload`. The settings
/// window surfaces these inline so users can re-try without losing
/// edits.
pub const SaveError = error{
    PathResolveFailed,
    TempCreateFailed,
    SerializeFailed,
    ReplaceFailed,
    ReloadFailed,
    OutOfMemory,
    /// Write + reload both succeeded, but at least one GUI-edited
    /// field is masked by a later layer (included `config-file`,
    /// subsequent `--config-file`, `--config-default-files=false`
    /// with no remaining base). The persisted bytes on disk are
    /// correct; the effective runtime value doesn't match. UI
    /// should surface this as a distinct warning, NOT as a
    /// generic write failure.
    SavedButMasked,
};

/// Minimal hook into the apprt `App` so the settings module can fetch
/// the chrome brush colors without pulling in the whole app type.
pub const AppHandle = struct {
    ctx: *anyopaque,
    /// Allocator used for `Config.shallowClone` on the pending draft.
    /// The clone's `_arena` is owned by this allocator; `Config.deinit`
    /// on the clone frees it.
    alloc: std.mem.Allocator,
    /// HINSTANCE used for window class registration + creation.
    hinstance: HINSTANCE,
    /// Chrome background color (COLORREF) to paint into the settings
    /// content pane. Queried per paint so theme swaps propagate.
    chromeBg: *const fn (ctx: *anyopaque) COLORREF,
    /// Primary text color.
    textPrimary: *const fn (ctx: *anyopaque) COLORREF,
    /// Fire-and-forget shell-out to the OS default text editor with
    /// the resolved `ghostty.conf` path. Used by the Advanced-pane
    /// escape hatch.
    openInEditor: *const fn (ctx: *anyopaque) void,
    /// Snapshot the currently-active Config. The returned pointer is
    /// only valid until the next config reload; the settings window
    /// holds it as `original` for the duration of the pending-clone
    /// session.
    currentConfig: *const fn (ctx: *anyopaque) *const Config,
    /// Serialise `pending` to disk (atomic-rename via `ReplaceFileW`
    /// where supported, falling back to `MoveFileExW`) and refresh
    /// the live app config + all surfaces. `original` is the
    /// snapshot captured when the settings window opened; the save
    /// path diffs pending against it (NOT against `App.config`) so
    /// an external `reload_config` or file edit that fires while the
    /// window is open doesn't get silently reverted by our save.
    /// Caller owns both.
    saveAndReload: *const fn (
        ctx: *anyopaque,
        pending: *const Config,
        original: *const Config,
    ) SaveError!void,
    /// Fire-and-forget success toast for the app-level in-app stack
    /// (e.g. "Settings saved"). Borrowed title + body — caller must
    /// keep them alive only for the duration of the call; the stack
    /// copies internally.
    notifySuccess: *const fn (ctx: *anyopaque, title: []const u8, body: []const u8) void,
    /// Fired after the settings window's HWND is destroyed. Lets the
    /// app re-evaluate its quit-timer policy (the settings HWND
    /// participates in the "has live UI windows" count so closing
    /// the last terminal while settings is open does not auto-quit;
    /// once settings itself closes the timer can kick in).
    onClosed: *const fn (ctx: *anyopaque) void,
};

pub const SettingsWindow = struct {
    handle: AppHandle,
    hwnd: ?HWND = null,
    btn_open_editor: ?HWND = null,
    btn_section_appearance: ?HWND = null,
    btn_section_terminal: ?HWND = null,
    btn_section_shell: ?HWND = null,
    btn_section_keybindings: ?HWND = null,
    btn_section_advanced: ?HWND = null,
    btn_save: ?HWND = null,
    btn_keybindings_editor: ?HWND = null,
    edit_scrollback: ?HWND = null,
    edit_font_family: ?HWND = null,
    edit_font_size: ?HWND = null,
    edit_theme: ?HWND = null,
    edit_bg_opacity: ?HWND = null,
    edit_command: ?HWND = null,
    edit_pad_x: ?HWND = null,
    edit_pad_y: ?HWND = null,
    combo_confirm_close: ?HWND = null,
    combo_copy_on_select: ?HWND = null,
    combo_window_theme: ?HWND = null,
    combo_shell_integ: ?HWND = null,
    chk_trim_trail: ?HWND = null,
    chk_desktop_notifications: ?HWND = null,
    chk_app_notify_clipboard: ?HWND = null,
    chk_app_notify_config: ?HWND = null,
    combo_clipboard_read: ?HWND = null,
    combo_clipboard_write: ?HWND = null,
    combo_link_url: ?HWND = null,
    combo_link_previews: ?HWND = null,
    combo_cursor_style: ?HWND = null,
    chk_bg_blur: ?HWND = null,
    combo_pad_balance: ?HWND = null,
    combo_auto_update: ?HWND = null,
    combo_auto_update_channel: ?HWND = null,
    active_section: Section = .appearance,
    /// Class atom lazily registered the first time `open` runs.
    class_atom: ATOM = 0,

    /// Frozen snapshot of the config at the moment the window last
    /// opened. Owned by this struct via `Config.shallowClone` so an
    /// external `reload_config` that fires while the window is open
    /// does not mutate our diff baseline. Only valid while
    /// `pending != null`.
    original: ?Config = null,
    /// Editable draft owned by `handle.alloc`. Created on open via
    /// `Config.shallowClone(handle.alloc)`; freed on close/save. Per
    /// AGENTS.md:49, we must NOT deinit an inherited `command` field
    /// on this clone — `Config.deinit` already honours that because
    /// the clone owns only its `_arena`, not the inherited pointers.
    pending: ?Config = null,
    /// Guard flag so the EN_CHANGE handler doesn't fire a cascade
    /// when we programmatically set the EDIT text on open.
    suppress_edit_events: bool = false,

    pub fn init(handle: AppHandle) SettingsWindow {
        return .{ .handle = handle };
    }

    pub fn deinit(self: *SettingsWindow) void {
        if (self.hwnd) |h| {
            if (IsWindow(h) != 0) _ = DestroyWindow(h);
        }
        self.hwnd = null;
        self.btn_open_editor = null;
        self.btn_section_appearance = null;
        self.btn_section_terminal = null;
        self.btn_section_shell = null;
        self.btn_section_keybindings = null;
        self.btn_section_advanced = null;
        self.btn_save = null;
        self.btn_keybindings_editor = null;
        self.edit_scrollback = null;
        self.edit_font_family = null;
        self.edit_font_size = null;
        self.edit_theme = null;
        self.edit_bg_opacity = null;
        self.edit_command = null;
        self.edit_pad_x = null;
        self.edit_pad_y = null;
        self.combo_confirm_close = null;
        self.combo_copy_on_select = null;
        self.combo_window_theme = null;
        self.combo_shell_integ = null;
        self.chk_trim_trail = null;
        self.chk_desktop_notifications = null;
        self.chk_app_notify_clipboard = null;
        self.chk_app_notify_config = null;
        self.combo_clipboard_read = null;
        self.combo_clipboard_write = null;
        self.combo_link_url = null;
        self.combo_link_previews = null;
        self.combo_cursor_style = null;
        self.chk_bg_blur = null;
        self.combo_pad_balance = null;
        self.combo_auto_update = null;
        self.combo_auto_update_channel = null;
        self.clearPending();
    }

    /// Drop the pending draft (if any) and its arena. Safe to call
    /// multiple times. Called from close paths and after Save so the
    /// next `open` starts with a fresh clone of the (possibly just-
    /// reloaded) app config.
    fn clearPending(self: *SettingsWindow) void {
        if (self.pending) |*p| p.deinit();
        self.pending = null;
        if (self.original) |*o| o.deinit();
        self.original = null;
    }

    /// Null out child HWND references + drop pending. Called from
    /// both WM_CLOSE and WM_NCDESTROY so the next `open()` recreates
    /// fresh children and clones.
    fn clearChildRefs(self: *SettingsWindow) void {
        self.hwnd = null;
        self.btn_open_editor = null;
        self.btn_section_appearance = null;
        self.btn_section_terminal = null;
        self.btn_section_shell = null;
        self.btn_section_keybindings = null;
        self.btn_section_advanced = null;
        self.btn_save = null;
        self.btn_keybindings_editor = null;
        self.edit_scrollback = null;
        self.edit_font_family = null;
        self.edit_font_size = null;
        self.edit_theme = null;
        self.edit_bg_opacity = null;
        self.edit_command = null;
        self.edit_pad_x = null;
        self.edit_pad_y = null;
        self.combo_confirm_close = null;
        self.combo_copy_on_select = null;
        self.combo_window_theme = null;
        self.combo_shell_integ = null;
        self.chk_trim_trail = null;
        self.chk_desktop_notifications = null;
        self.chk_app_notify_clipboard = null;
        self.chk_app_notify_config = null;
        self.combo_clipboard_read = null;
        self.combo_clipboard_write = null;
        self.combo_link_url = null;
        self.combo_link_previews = null;
        self.combo_cursor_style = null;
        self.chk_bg_blur = null;
        self.combo_pad_balance = null;
        self.combo_auto_update = null;
        self.combo_auto_update_channel = null;
        self.clearPending();
    }

    fn sectionButton(self: *const SettingsWindow, section: Section) ?HWND {
        return switch (section) {
            .appearance => self.btn_section_appearance,
            .terminal => self.btn_section_terminal,
            .shell => self.btn_section_shell,
            .keybindings => self.btn_section_keybindings,
            .advanced => self.btn_section_advanced,
        };
    }

    fn setActiveSection(self: *SettingsWindow, next: Section) void {
        if (self.active_section == next and self.hwnd != null) return;
        self.active_section = next;
        self.applySectionVisibility();
        if (self.hwnd) |h| _ = InvalidateRect(h, null, 1);
    }

    fn applySectionVisibility(self: *SettingsWindow) void {
        const show_advanced: i32 = if (self.active_section == .advanced) SW_SHOWNORMAL else SW_HIDE;
        const show_terminal: i32 = if (self.active_section == .terminal) SW_SHOWNORMAL else SW_HIDE;
        const show_appearance: i32 = if (self.active_section == .appearance) SW_SHOWNORMAL else SW_HIDE;
        const show_shell: i32 = if (self.active_section == .shell) SW_SHOWNORMAL else SW_HIDE;
        const show_keybindings: i32 = if (self.active_section == .keybindings) SW_SHOWNORMAL else SW_HIDE;

        if (self.btn_open_editor) |btn| _ = ShowWindow(btn, show_advanced);
        if (self.btn_keybindings_editor) |btn| _ = ShowWindow(btn, show_keybindings);
        if (self.edit_scrollback) |e| _ = ShowWindow(e, show_terminal);
        if (self.combo_confirm_close) |e| _ = ShowWindow(e, show_terminal);
        if (self.combo_copy_on_select) |e| _ = ShowWindow(e, show_terminal);
        if (self.chk_trim_trail) |e| _ = ShowWindow(e, show_terminal);
        if (self.chk_desktop_notifications) |e| _ = ShowWindow(e, show_terminal);
        if (self.chk_app_notify_clipboard) |e| _ = ShowWindow(e, show_terminal);
        if (self.chk_app_notify_config) |e| _ = ShowWindow(e, show_terminal);
        if (self.combo_clipboard_read) |e| _ = ShowWindow(e, show_terminal);
        if (self.combo_clipboard_write) |e| _ = ShowWindow(e, show_terminal);
        if (self.combo_link_url) |e| _ = ShowWindow(e, show_terminal);
        if (self.combo_link_previews) |e| _ = ShowWindow(e, show_terminal);
        if (self.edit_font_family) |e| _ = ShowWindow(e, show_appearance);
        if (self.edit_font_size) |e| _ = ShowWindow(e, show_appearance);
        if (self.edit_theme) |e| _ = ShowWindow(e, show_appearance);
        if (self.edit_bg_opacity) |e| _ = ShowWindow(e, show_appearance);
        if (self.combo_window_theme) |e| _ = ShowWindow(e, show_appearance);
        if (self.combo_cursor_style) |e| _ = ShowWindow(e, show_appearance);
        if (self.edit_pad_x) |e| _ = ShowWindow(e, show_appearance);
        if (self.edit_pad_y) |e| _ = ShowWindow(e, show_appearance);
        if (self.chk_bg_blur) |e| _ = ShowWindow(e, show_appearance);
        if (self.combo_pad_balance) |e| _ = ShowWindow(e, show_appearance);
        if (self.edit_command) |e| _ = ShowWindow(e, show_shell);
        if (self.combo_shell_integ) |e| _ = ShowWindow(e, show_shell);
        if (self.combo_auto_update) |e| _ = ShowWindow(e, show_advanced);
        if (self.combo_auto_update_channel) |e| _ = ShowWindow(e, show_advanced);
    }

    /// Read the current EDIT text and write the parsed integer into
    /// the pending draft. Called from EN_CHANGE. Swallows parse
    /// errors silently — ES_NUMBER style means the text is already
    /// digits-only, but the empty-string case needs to map to 0 (or
    /// be ignored).
    fn syncScrollbackFromEdit(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const edit = self.edit_scrollback orelse return;

        var buf_w: [32]u16 = undefined;
        const n = GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
        if (n <= 0) return;
        var utf8_buf: [64]u8 = undefined;
        const utf8 = std.unicode.utf16LeToUtf8(&utf8_buf, buf_w[0..@intCast(n)]) catch return;
        const trimmed = std.mem.trim(u8, utf8_buf[0..utf8], " \t");
        if (trimmed.len == 0) return;
        const parsed = std.fmt.parseInt(usize, trimmed, 10) catch return;
        p.*.@"scrollback-limit" = parsed;
    }

    fn displayScrollbackInEdit(self: *SettingsWindow) void {
        const edit = self.edit_scrollback orelse return;
        const p = self.pending orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d}", .{p.@"scrollback-limit"}) catch return;
        var buf_w: [32]u16 = undefined;
        const w = utf8ToW(&buf_w, text);
        self.suppress_edit_events = true;
        _ = SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
        self.suppress_edit_events = false;
    }

    fn syncFontFamilyFromEdit(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const arena = p.*._arena.?.allocator();
        const edit = self.edit_font_family orelse return;
        var text_buf: [edit_text_max_utf8]u8 = undefined;
        const text = readEditUtf8(edit, &text_buf) orelse return;
        p.*.@"font-family" = parseFontFamilyEditText(arena, text) catch return;
    }

    fn displayFontFamilyInEdit(self: *SettingsWindow) void {
        const edit = self.edit_font_family orelse return;
        const p = self.pending orelse return;
        var buf: [edit_text_max_utf8]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        for (p.@"font-family".list.items, 0..) |family, i| {
            if (i != 0) writer.writeAll(", ") catch break;
            writer.writeAll(family) catch break;
        }
        setEditText(edit, writer.buffered(), &self.suppress_edit_events);
    }

    fn syncFontSizeFromEdit(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const edit = self.edit_font_size orelse return;
        var buf_w: [32]u16 = undefined;
        const n = GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
        if (n <= 0) return;
        var utf8_buf: [64]u8 = undefined;
        const utf8 = std.unicode.utf16LeToUtf8(&utf8_buf, buf_w[0..@intCast(n)]) catch return;
        const trimmed = std.mem.trim(u8, utf8_buf[0..utf8], " \t");
        if (trimmed.len == 0) return;
        const parsed = std.fmt.parseFloat(f32, trimmed) catch return;
        // Range-clamp: Ghostty Config default is 12 pt; our range is
        // the same the GUI spinner catalogue will offer (6..72).
        if (parsed < 6.0 or parsed > 72.0) return;
        p.*.@"font-size" = parsed;
    }

    fn displayFontSizeInEdit(self: *SettingsWindow) void {
        const edit = self.edit_font_size orelse return;
        const p = self.pending orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.1}", .{p.@"font-size"}) catch return;
        var buf_w: [32]u16 = undefined;
        const w = utf8ToW(&buf_w, text);
        self.suppress_edit_events = true;
        _ = SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
        self.suppress_edit_events = false;
    }

    fn syncThemeFromEdit(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const arena = p.*._arena.?.allocator();
        const edit = self.edit_theme orelse return;
        var text_buf: [edit_text_max_utf8]u8 = undefined;
        const text = readEditUtf8(edit, &text_buf) orelse return;
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) {
            p.*.theme = null;
            return;
        }
        var theme: Config.Theme = undefined;
        theme.parseCLI(arena, trimmed) catch return;
        p.*.theme = theme;
    }

    fn displayThemeInEdit(self: *SettingsWindow) void {
        const edit = self.edit_theme orelse return;
        const p = self.pending orelse return;
        var buf: [edit_text_max_utf8]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        if (p.theme) |theme| {
            if (std.mem.eql(u8, theme.light, theme.dark)) {
                writer.writeAll(theme.light) catch {};
            } else {
                writer.print("light:{s},dark:{s}", .{ theme.light, theme.dark }) catch {};
            }
        }
        setEditText(edit, writer.buffered(), &self.suppress_edit_events);
    }

    fn syncBgOpacityFromEdit(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const edit = self.edit_bg_opacity orelse return;
        var buf_w: [32]u16 = undefined;
        const n = GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
        if (n <= 0) return;
        var utf8_buf: [64]u8 = undefined;
        const utf8 = std.unicode.utf16LeToUtf8(&utf8_buf, buf_w[0..@intCast(n)]) catch return;
        const trimmed = std.mem.trim(u8, utf8_buf[0..utf8], " \t");
        if (trimmed.len == 0) return;
        const parsed = std.fmt.parseFloat(f64, trimmed) catch return;
        if (parsed < 0.0 or parsed > 1.0) return;
        p.*.@"background-opacity" = parsed;
    }

    fn displayBgOpacityInEdit(self: *SettingsWindow) void {
        const edit = self.edit_bg_opacity orelse return;
        const p = self.pending orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.2}", .{p.@"background-opacity"}) catch return;
        var buf_w: [32]u16 = undefined;
        const w = utf8ToW(&buf_w, text);
        self.suppress_edit_events = true;
        _ = SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
        self.suppress_edit_events = false;
    }

    fn syncCommandFromEdit(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const arena = p.*._arena.?.allocator();
        const edit = self.edit_command orelse return;
        var text_buf: [edit_text_max_utf8]u8 = undefined;
        const text = readEditUtf8(edit, &text_buf) orelse return;
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) {
            p.*.command = null;
            return;
        }
        var command: Config.Command = undefined;
        command.parseCLI(arena, trimmed) catch return;
        p.*.command = command;
    }

    fn displayCommandInEdit(self: *SettingsWindow) void {
        const edit = self.edit_command orelse return;
        const p = self.pending orelse return;
        var buf: [edit_text_max_utf8]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        if (p.command) |command| writeCommandForEdit(&writer, command) catch {};
        setEditText(edit, writer.buffered(), &self.suppress_edit_events);
    }

    fn syncPaddingFromEdit(self: *SettingsWindow, axis: PaddingAxis) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const edit = switch (axis) {
            .x => self.edit_pad_x,
            .y => self.edit_pad_y,
        } orelse return;
        var text_buf: [64]u8 = undefined;
        const text = readEditUtf8(edit, &text_buf) orelse return;
        const parsed = Config.WindowPadding.parseCLI(std.mem.trim(u8, text, " \t")) catch return;
        switch (axis) {
            .x => p.*.@"window-padding-x" = parsed,
            .y => p.*.@"window-padding-y" = parsed,
        }
    }

    fn displayPaddingInEdit(self: *SettingsWindow, axis: PaddingAxis) void {
        const edit = switch (axis) {
            .x => self.edit_pad_x,
            .y => self.edit_pad_y,
        } orelse return;
        const p = self.pending orelse return;
        const padding = switch (axis) {
            .x => p.@"window-padding-x",
            .y => p.@"window-padding-y",
        };
        var buf: [64]u8 = undefined;
        const text = if (padding.top_left == padding.bottom_right)
            std.fmt.bufPrint(&buf, "{d}", .{padding.top_left}) catch return
        else
            std.fmt.bufPrint(&buf, "{d},{d}", .{ padding.top_left, padding.bottom_right }) catch return;
        setEditText(edit, text, &self.suppress_edit_events);
    }

    fn syncTrimTrailFromCheckbox(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const chk = self.chk_trim_trail orelse return;
        const state = SendMessageW(chk, BM_GETCHECK, 0, 0);
        p.*.@"clipboard-trim-trailing-spaces" = (state == BST_CHECKED);
    }

    fn displayTrimTrailInCheckbox(self: *SettingsWindow) void {
        const chk = self.chk_trim_trail orelse return;
        const p = self.pending orelse return;
        self.suppress_edit_events = true;
        _ = SendMessageW(
            chk,
            BM_SETCHECK,
            if (p.@"clipboard-trim-trailing-spaces") BST_CHECKED else BST_UNCHECKED,
            0,
        );
        self.suppress_edit_events = false;
    }

    fn syncDesktopNotificationsFromCheckbox(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const chk = self.chk_desktop_notifications orelse return;
        p.*.@"desktop-notifications" = SendMessageW(chk, BM_GETCHECK, 0, 0) == BST_CHECKED;
    }

    fn displayDesktopNotificationsInCheckbox(self: *SettingsWindow) void {
        const chk = self.chk_desktop_notifications orelse return;
        const p = self.pending orelse return;
        self.suppress_edit_events = true;
        _ = SendMessageW(
            chk,
            BM_SETCHECK,
            if (p.@"desktop-notifications") BST_CHECKED else BST_UNCHECKED,
            0,
        );
        self.suppress_edit_events = false;
    }

    fn syncAppNotificationsFromCheckbox(self: *SettingsWindow, field: AppNotificationField) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const chk = switch (field) {
            .clipboard => self.chk_app_notify_clipboard,
            .config => self.chk_app_notify_config,
        } orelse return;
        const enabled = SendMessageW(chk, BM_GETCHECK, 0, 0) == BST_CHECKED;
        switch (field) {
            .clipboard => p.*.@"app-notifications".@"clipboard-copy" = enabled,
            .config => p.*.@"app-notifications".@"config-reload" = enabled,
        }
    }

    fn displayAppNotificationsInCheckbox(self: *SettingsWindow, field: AppNotificationField) void {
        const chk = switch (field) {
            .clipboard => self.chk_app_notify_clipboard,
            .config => self.chk_app_notify_config,
        } orelse return;
        const p = self.pending orelse return;
        const enabled = switch (field) {
            .clipboard => p.@"app-notifications".@"clipboard-copy",
            .config => p.@"app-notifications".@"config-reload",
        };
        self.suppress_edit_events = true;
        _ = SendMessageW(chk, BM_SETCHECK, if (enabled) BST_CHECKED else BST_UNCHECKED, 0);
        self.suppress_edit_events = false;
    }

    /// Enum combo helpers. `fromIndex` maps combobox selection to
    /// config enum value; `toIndex` goes the other direction for
    /// initial display.
    fn syncConfirmCloseFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_confirm_close orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"confirm-close-surface" = switch (idx) {
            0 => .false,
            1 => .true,
            2 => .always,
            else => return,
        };
    }

    fn displayConfirmCloseInCombo(self: *SettingsWindow) void {
        const combo = self.combo_confirm_close orelse return;
        const p = self.pending orelse return;
        const idx: usize = switch (p.@"confirm-close-surface") {
            .false => 0,
            .true => 1,
            .always => 2,
        };
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncCopyOnSelectFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_copy_on_select orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"copy-on-select" = switch (idx) {
            0 => .false,
            1 => .true,
            2 => .clipboard,
            else => return,
        };
    }

    fn displayCopyOnSelectInCombo(self: *SettingsWindow) void {
        const combo = self.combo_copy_on_select orelse return;
        const p = self.pending orelse return;
        const idx: usize = switch (p.@"copy-on-select") {
            .false => 0,
            .true => 1,
            .clipboard => 2,
        };
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncClipboardAccessFromCombo(self: *SettingsWindow, comptime field_name: []const u8, combo_opt: ?HWND) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = combo_opt orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        @field(p.*, field_name) = clipboardAccessFromComboIndex(idx) orelse return;
    }

    fn displayClipboardAccessInCombo(self: *SettingsWindow, comptime field_name: []const u8, combo_opt: ?HWND) void {
        const combo = combo_opt orelse return;
        const p = self.pending orelse return;
        const idx = comboIndexFromClipboardAccess(@field(p, field_name));
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncLinkUrlFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_link_url orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"link-url" = linkUrlFromComboIndex(idx) orelse return;
    }

    fn displayLinkUrlInCombo(self: *SettingsWindow) void {
        const combo = self.combo_link_url orelse return;
        const p = self.pending orelse return;
        const idx = comboIndexFromLinkUrl(p.@"link-url");
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncLinkPreviewsFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_link_previews orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"link-previews" = linkPreviewsFromComboIndex(idx) orelse return;
    }

    fn displayLinkPreviewsInCombo(self: *SettingsWindow) void {
        const combo = self.combo_link_previews orelse return;
        const p = self.pending orelse return;
        const idx = comboIndexFromLinkPreviews(p.@"link-previews");
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncWindowThemeFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_window_theme orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"window-theme" = switch (idx) {
            0 => .auto,
            1 => .system,
            2 => .light,
            3 => .dark,
            4 => .ghostty,
            else => return,
        };
    }

    fn displayWindowThemeInCombo(self: *SettingsWindow) void {
        const combo = self.combo_window_theme orelse return;
        const p = self.pending orelse return;
        const idx: usize = switch (p.@"window-theme") {
            .auto => 0,
            .system => 1,
            .light => 2,
            .dark => 3,
            .ghostty => 4,
        };
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncShellIntegFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_shell_integ orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"shell-integration" = switch (idx) {
            0 => .none,
            1 => .detect,
            2 => .bash,
            3 => .elvish,
            4 => .fish,
            5 => .nushell,
            6 => .zsh,
            else => return,
        };
    }

    fn displayShellIntegInCombo(self: *SettingsWindow) void {
        const combo = self.combo_shell_integ orelse return;
        const p = self.pending orelse return;
        const idx: usize = switch (p.@"shell-integration") {
            .none => 0,
            .detect => 1,
            .bash => 2,
            .elvish => 3,
            .fish => 4,
            .nushell => 5,
            .zsh => 6,
        };
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncCursorStyleFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_cursor_style orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"cursor-style" = switch (idx) {
            0 => .bar,
            1 => .block,
            2 => .underline,
            3 => .block_hollow,
            else => return,
        };
    }

    fn displayCursorStyleInCombo(self: *SettingsWindow) void {
        const combo = self.combo_cursor_style orelse return;
        const p = self.pending orelse return;
        const idx: usize = switch (p.@"cursor-style") {
            .bar => 0,
            .block => 1,
            .underline => 2,
            .block_hollow => 3,
        };
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    /// background-blur is a union (false / true / { radius: u8 }). The
    /// GUI exposes only the boolean path, so keep an existing numeric
    /// radius intact while the checkbox remains enabled.
    fn syncBgBlurFromCheckbox(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const chk = self.chk_bg_blur orelse return;
        const state = SendMessageW(chk, BM_GETCHECK, 0, 0);
        p.*.@"background-blur" = backgroundBlurFromCheckbox(
            p.*.@"background-blur",
            state == BST_CHECKED,
        );
    }

    fn displayBgBlurInCheckbox(self: *SettingsWindow) void {
        const chk = self.chk_bg_blur orelse return;
        const p = self.pending orelse return;
        const enabled = p.@"background-blur".win32SystemBackdropEnabled();
        self.suppress_edit_events = true;
        _ = SendMessageW(
            chk,
            BM_SETCHECK,
            if (enabled) BST_CHECKED else BST_UNCHECKED,
            0,
        );
        self.suppress_edit_events = false;
    }

    fn syncPadBalanceFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_pad_balance orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"window-padding-balance" = switch (idx) {
            0 => .false,
            1 => .true,
            2 => .equal,
            else => return,
        };
    }

    fn displayPadBalanceInCombo(self: *SettingsWindow) void {
        const combo = self.combo_pad_balance orelse return;
        const p = self.pending orelse return;
        const idx: usize = switch (p.@"window-padding-balance") {
            .false => 0,
            .true => 1,
            .equal => 2,
        };
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncAutoUpdateFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_auto_update orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"auto-update" = switch (idx) {
            0 => null,
            1 => .off,
            2 => .check,
            3 => .download,
            else => return,
        };
    }

    fn displayAutoUpdateInCombo(self: *SettingsWindow) void {
        const combo = self.combo_auto_update orelse return;
        const p = self.pending orelse return;
        const idx: usize = if (p.@"auto-update") |value| switch (value) {
            .off => 1,
            .check => 2,
            .download => 3,
        } else 0;
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncAutoUpdateChannelFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_auto_update_channel orelse return;
        const idx = SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"auto-update-channel" = switch (idx) {
            0 => null,
            1 => .stable,
            2 => .tip,
            else => return,
        };
    }

    fn displayAutoUpdateChannelInCombo(self: *SettingsWindow) void {
        const combo = self.combo_auto_update_channel orelse return;
        const p = self.pending orelse return;
        const idx: usize = if (p.@"auto-update-channel") |value| switch (value) {
            .stable => 1,
            .tip => 2,
        } else 0;
        self.suppress_edit_events = true;
        _ = SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    /// Refresh every control from the pending draft. Called after
    /// `adoptCurrentConfig` and after a successful save.
    fn refreshAllControls(self: *SettingsWindow) void {
        self.displayScrollbackInEdit();
        self.displayFontFamilyInEdit();
        self.displayFontSizeInEdit();
        self.displayThemeInEdit();
        self.displayBgOpacityInEdit();
        self.displayCommandInEdit();
        self.displayPaddingInEdit(.x);
        self.displayPaddingInEdit(.y);
        self.displayTrimTrailInCheckbox();
        self.displayDesktopNotificationsInCheckbox();
        self.displayAppNotificationsInCheckbox(.clipboard);
        self.displayAppNotificationsInCheckbox(.config);
        self.displayConfirmCloseInCombo();
        self.displayCopyOnSelectInCombo();
        self.displayClipboardAccessInCombo("clipboard-read", self.combo_clipboard_read);
        self.displayClipboardAccessInCombo("clipboard-write", self.combo_clipboard_write);
        self.displayLinkUrlInCombo();
        self.displayLinkPreviewsInCombo();
        self.displayWindowThemeInCombo();
        self.displayShellIntegInCombo();
        self.displayCursorStyleInCombo();
        self.displayBgBlurInCheckbox();
        self.displayPadBalanceInCombo();
        self.displayAutoUpdateInCombo();
        self.displayAutoUpdateChannelInCombo();
    }

    fn save(self: *SettingsWindow) void {
        self.syncCommandFromEdit();
        const p = self.pending orelse return;
        const o = self.original orelse return;
        const result = self.handle.saveAndReload(self.handle.ctx, &p, &o);
        if (result) |_| {
            // Success path: refresh baseline so subsequent edits
            // diff correctly against the new saved state.
            self.clearPending();
            self.adoptCurrentConfig();
            self.refreshAllControls();
            self.handle.notifySuccess(self.handle.ctx, "Settings saved", "");
        } else |err| switch (err) {
            error.SavedButMasked => {
                // Persisted bytes are correct but a later config
                // layer is masking one or more edits. Same baseline
                // refresh as success since the file IS written.
                // The toast copy tells the user the bytes made it
                // to disk but the effective value differs.
                self.clearPending();
                self.adoptCurrentConfig();
                self.refreshAllControls();
                self.handle.notifySuccess(
                    self.handle.ctx,
                    "Settings saved — some values are masked by a later config-file layer",
                    "Check the log for which fields.",
                );
            },
            else => {
                // Write failed. DO NOT discard `pending` — the user's
                // edits are still in memory; losing them on every
                // transient disk error (permission denied, sharing
                // violation when another editor has the file open)
                // would be destructive. Leave `pending` alone so
                // the user can retry Save once the underlying issue
                // is fixed, or close the window to discard.
                std.log.warn("settings: save failed err={}; draft preserved", .{err});
            },
        }
    }

    fn adoptCurrentConfig(self: *SettingsWindow) void {
        const current = self.handle.currentConfig(self.handle.ctx);
        // Two independent shallow clones so each struct has its own
        // arena. The `original` clone is a frozen baseline for the
        // save-path diff; the `pending` clone is the editable draft.
        // Mutations to `pending` go through its arena; `original`
        // stays byte-identical to the config at window-open time
        // even if `App.config` mutates via an external reload.
        self.original = current.shallowClone(self.handle.alloc);
        self.pending = current.shallowClone(self.handle.alloc);
    }

    /// Bring the settings window up. Idempotent: a subsequent open
    /// with a live HWND brings the existing window to the foreground
    /// instead of duplicating it.
    pub fn open(self: *SettingsWindow) !void {
        if (self.hwnd) |h| {
            if (IsWindow(h) != 0) {
                if (IsIconic(h) != 0) _ = ShowWindow(h, SW_RESTORE) else _ = ShowWindow(h, SW_SHOWNORMAL);
                _ = SetForegroundWindow(h);
                return;
            }
            self.hwnd = null;
        }

        // Fresh pending clone of the live config. Discarded on close
        // or refreshed after a successful save.
        self.clearPending();
        self.adoptCurrentConfig();

        if (self.class_atom == 0) {
            const wc: WNDCLASSEXW = .{
                .cbSize = @sizeOf(WNDCLASSEXW),
                .style = CS_HREDRAW | CS_VREDRAW,
                .lpfnWndProc = &wndProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = self.handle.hinstance,
                .hIcon = null,
                .hCursor = LoadCursorW(null, @ptrFromInt(IDC_ARROW)),
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = class_name,
                .hIconSm = null,
            };
            self.class_atom = RegisterClassExW(&wc);
            if (self.class_atom == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
        }

        const title = std.unicode.utf8ToUtf16LeStringLiteral("winghostty settings");
        const hwnd = CreateWindowExW(
            WS_EX_APPWINDOW,
            class_name,
            title,
            WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            960,
            720,
            null,
            null,
            self.handle.hinstance,
            self,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        self.hwnd = hwnd;

        const btn_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");

        // Left-rail section buttons. Clicks arrive via WM_COMMAND on
        // the parent; the id maps back to a `Section` via
        // `Section.fromButtonId`.
        self.btn_section_appearance = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.appearance);
        self.btn_section_terminal = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.terminal);
        self.btn_section_shell = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.shell);
        self.btn_section_keybindings = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.keybindings);
        self.btn_section_advanced = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.advanced);

        // "Open in default editor" button — escape hatch for users
        // who prefer text-editing the config file directly. Lives
        // in the Advanced section; hidden when another section is
        // active.
        const btn_label = std.unicode.utf8ToUtf16LeStringLiteral("Open in default editor");
        self.btn_open_editor = CreateWindowExW(
            0,
            btn_class,
            btn_label,
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            220,
            32,
            hwnd,
            @ptrFromInt(BTN_OPEN_EDITOR),
            self.handle.hinstance,
            null,
        );
        // "Save" button — always visible; writes `pending` to disk
        // and fires a hard reload. Save errors are logged and the draft
        // remains in memory for retry.
        const btn_save_label = std.unicode.utf8ToUtf16LeStringLiteral("Save");
        self.btn_save = CreateWindowExW(
            0,
            btn_class,
            btn_save_label,
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            90,
            32,
            hwnd,
            @ptrFromInt(BTN_SAVE),
            self.handle.hinstance,
            null,
        );

        const btn_keybind_label = std.unicode.utf8ToUtf16LeStringLiteral("Open config for keybinds");
        self.btn_keybindings_editor = CreateWindowExW(
            0,
            btn_class,
            btn_keybind_label,
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            220,
            32,
            hwnd,
            @ptrFromInt(BTN_KEYBINDINGS_EDITOR),
            self.handle.hinstance,
            null,
        );

        // Scrollback limit EDIT. Lives in the Terminal section. Digit-
        // only input via ES_NUMBER; EN_CHANGE syncs into `pending`.
        self.edit_scrollback = makeEdit(hwnd, self.handle.hinstance, EDIT_SCROLLBACK, 200, ES_NUMBER);

        // font-family EDIT. Comma-separated fallback families.
        self.edit_font_family = makeEdit(hwnd, self.handle.hinstance, EDIT_FONT_FAMILY, 300, 0);

        // font-size EDIT. Appearance section. We accept floats via a
        // plain EDIT (not ES_NUMBER — which rejects '.') and validate
        // on EN_CHANGE.
        self.edit_font_size = makeEdit(hwnd, self.handle.hinstance, EDIT_FONT_SIZE, 160, 0);

        // theme EDIT. Accepts a built-in/custom name or light/dark pair.
        self.edit_theme = makeEdit(hwnd, self.handle.hinstance, EDIT_THEME, 300, 0);

        // background-opacity EDIT. Appearance section. 0.0..1.0.
        self.edit_bg_opacity = makeEdit(hwnd, self.handle.hinstance, EDIT_BG_OPACITY, 160, 0);

        self.edit_command = makeEdit(hwnd, self.handle.hinstance, EDIT_COMMAND, 360, 0);

        self.edit_pad_x = makeEdit(hwnd, self.handle.hinstance, EDIT_PAD_X, 160, 0);

        self.edit_pad_y = makeEdit(hwnd, self.handle.hinstance, EDIT_PAD_Y, 160, 0);

        // clipboard-trim-trailing-spaces checkbox. Terminal section.
        self.chk_trim_trail = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_TRIM_TRAIL,
            std.unicode.utf8ToUtf16LeStringLiteral("Trim trailing spaces on copy"),
            260,
        );

        self.chk_desktop_notifications = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_DESKTOP_NOTIFICATIONS,
            std.unicode.utf8ToUtf16LeStringLiteral("Allow terminal desktop notifications"),
            320,
        );

        self.chk_app_notify_clipboard = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_APP_NOTIFY_CLIPBOARD,
            std.unicode.utf8ToUtf16LeStringLiteral("Notify when clipboard copy completes"),
            320,
        );

        self.chk_app_notify_config = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_APP_NOTIFY_CONFIG,
            std.unicode.utf8ToUtf16LeStringLiteral("Notify after config reload"),
            320,
        );

        // Comboboxes for enum fields.
        self.combo_confirm_close = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CONFIRM_CLOSE,
            160,
            &.{ "false", "true", "always" },
        );

        self.combo_copy_on_select = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_COPY_ON_SELECT,
            160,
            &.{ "false", "true", "clipboard" },
        );

        self.combo_clipboard_read = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CLIPBOARD_READ,
            160,
            &.{ "ask", "allow", "deny" },
        );

        self.combo_clipboard_write = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CLIPBOARD_WRITE,
            160,
            &.{ "ask", "allow", "deny" },
        );

        self.combo_link_url = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_LINK_URL,
            160,
            &.{ "enabled", "disabled" },
        );

        self.combo_link_previews = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_LINK_PREVIEWS,
            160,
            &.{ "all links", "OSC 8 only", "disabled" },
        );

        self.combo_window_theme = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_WINDOW_THEME,
            180,
            &.{ "auto", "system", "light", "dark", "ghostty" },
        );

        self.combo_shell_integ = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_SHELL_INTEG,
            200,
            &.{ "none", "detect", "bash", "elvish", "fish", "nushell", "zsh" },
        );

        self.combo_cursor_style = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CURSOR_STYLE,
            160,
            &.{ "bar", "block", "underline", "block_hollow" },
        );

        self.chk_bg_blur = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_BG_BLUR,
            std.unicode.utf8ToUtf16LeStringLiteral("Enable background blur"),
            260,
        );

        self.combo_pad_balance = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_PAD_BALANCE,
            160,
            &.{ "false", "true", "equal" },
        );

        self.combo_auto_update = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_AUTO_UPDATE,
            160,
            &.{ "default", "off", "check", "download" },
        );

        self.combo_auto_update_channel = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_AUTO_UPDATE_CHANNEL,
            140,
            &.{ "default", "stable", "tip" },
        );

        self.refreshAllControls();

        self.applySectionVisibility();

        _ = ShowWindow(hwnd, SW_SHOWNORMAL);
        layoutChildren(self);
    }
};

fn populateCombo(combo_opt: ?HWND, items: []const []const u8) void {
    const combo = combo_opt orelse return;
    _ = SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    for (items) |item| {
        var buf_w: [64]u16 = undefined;
        const w = utf8ToW(&buf_w, item);
        _ = SendMessageW(combo, CB_ADDSTRING, 0, @bitCast(@intFromPtr(w)));
    }
}

fn makeEdit(
    parent: HWND,
    hinstance: HINSTANCE,
    id: usize,
    width: i32,
    extra_style: u32,
) ?HWND {
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const edit = CreateWindowExW(
        0,
        edit_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL | extra_style,
        0,
        0,
        width,
        28,
        parent,
        @ptrFromInt(id),
        hinstance,
        null,
    );
    if (edit) |e| _ = SendMessageW(e, EM_LIMITTEXT, edit_text_max_code_units - 1, 0);
    return edit;
}

fn makeCheckbox(
    parent: HWND,
    hinstance: HINSTANCE,
    id: usize,
    label: LPCWSTR,
    width: i32,
) ?HWND {
    const btn_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
    return CreateWindowExW(
        0,
        btn_class,
        label,
        WS_CHILD | WS_TABSTOP | BS_AUTOCHECKBOX,
        0,
        0,
        width,
        24,
        parent,
        @ptrFromInt(id),
        hinstance,
        null,
    );
}

fn makeCombo(
    parent: HWND,
    hinstance: HINSTANCE,
    id: usize,
    height: i32,
    items: []const []const u8,
) ?HWND {
    const combo_class = std.unicode.utf8ToUtf16LeStringLiteral("COMBOBOX");
    const combo = CreateWindowExW(
        0,
        combo_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_TABSTOP | CBS_DROPDOWNLIST | CBS_HASSTRINGS,
        0,
        0,
        200,
        height,
        parent,
        @ptrFromInt(id),
        hinstance,
        null,
    );
    populateCombo(combo, items);
    return combo;
}

fn makeSectionButton(
    parent: HWND,
    hinstance: HINSTANCE,
    class: LPCWSTR,
    section: Section,
) ?HWND {
    const id: usize = switch (section) {
        .appearance => BTN_SECTION_APPEARANCE,
        .terminal => BTN_SECTION_TERMINAL,
        .shell => BTN_SECTION_SHELL,
        .keybindings => BTN_SECTION_KEYBINDINGS,
        .advanced => BTN_SECTION_ADVANCED,
    };
    return CreateWindowExW(
        0,
        class,
        section.label(),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        0,
        0,
        100,
        36,
        parent,
        @ptrFromInt(id),
        hinstance,
        null,
    );
}

const left_rail_width: i32 = 200;
const section_btn_height: i32 = 36;
const section_btn_top_pad: i32 = 16;
const section_btn_gap: i32 = 4;
const side_pad: i32 = 16;

fn layoutChildren(self: *SettingsWindow) void {
    const hwnd = self.hwnd orelse return;
    var rect: RECT = undefined;
    if (GetClientRect(hwnd, &rect) == 0) return;

    // Left rail — stack section buttons top-down.
    const btn_x: i32 = side_pad;
    const btn_w: i32 = left_rail_width - side_pad - side_pad;
    var y: i32 = section_btn_top_pad;
    for ([_]?HWND{
        self.btn_section_appearance,
        self.btn_section_terminal,
        self.btn_section_shell,
        self.btn_section_keybindings,
        self.btn_section_advanced,
    }) |btn_opt| {
        if (btn_opt) |btn| {
            _ = MoveWindow(btn, btn_x, y, btn_w, section_btn_height, 1);
        }
        y += section_btn_height + section_btn_gap;
    }

    const pane_left = left_rail_width + side_pad;
    const pane_top = section_btn_top_pad;
    const row_gap: i32 = 48;

    // Terminal section stack. All rows share this section and are
    // hidden by `applySectionVisibility` when another section is
    // active. Layout is a single-column flow from the content-pane
    // header down.
    {
        var ty: i32 = pane_top + 72;
        if (self.edit_scrollback) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 28, 1);
            ty += row_gap;
        }
        if (self.combo_confirm_close) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.combo_copy_on_select) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.combo_clipboard_read) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.combo_clipboard_write) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.combo_link_url) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.combo_link_previews) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.chk_trim_trail) |e| {
            _ = MoveWindow(e, pane_left, ty, 260, 24, 1);
            ty += row_gap;
        }
        if (self.chk_desktop_notifications) |e| {
            _ = MoveWindow(e, pane_left, ty, 320, 24, 1);
            ty += row_gap;
        }
        if (self.chk_app_notify_clipboard) |e| {
            _ = MoveWindow(e, pane_left, ty, 320, 24, 1);
            ty += row_gap;
        }
        if (self.chk_app_notify_config) |e| {
            _ = MoveWindow(e, pane_left, ty, 320, 24, 1);
        }
    }

    // Appearance section stack.
    {
        var ty: i32 = pane_top + 72;
        if (self.edit_font_family) |e| {
            _ = MoveWindow(e, pane_left, ty, 300, 28, 1);
            ty += row_gap;
        }
        if (self.edit_font_size) |e| {
            _ = MoveWindow(e, pane_left, ty, 160, 28, 1);
            ty += row_gap;
        }
        if (self.edit_theme) |e| {
            _ = MoveWindow(e, pane_left, ty, 300, 28, 1);
            ty += row_gap;
        }
        if (self.edit_bg_opacity) |e| {
            _ = MoveWindow(e, pane_left, ty, 160, 28, 1);
            ty += row_gap;
        }
        if (self.combo_window_theme) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 180, 1);
            ty += row_gap;
        }
        if (self.combo_cursor_style) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.edit_pad_x) |e| {
            _ = MoveWindow(e, pane_left, ty, 160, 28, 1);
            ty += row_gap;
        }
        if (self.edit_pad_y) |e| {
            _ = MoveWindow(e, pane_left, ty, 160, 28, 1);
            ty += row_gap;
        }
        if (self.combo_pad_balance) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.chk_bg_blur) |e| {
            _ = MoveWindow(e, pane_left, ty, 260, 24, 1);
        }
    }

    // Shell section.
    {
        var ty: i32 = pane_top + 72;
        if (self.edit_command) |e| {
            _ = MoveWindow(e, pane_left, ty, 360, 28, 1);
            ty += row_gap;
        }
        if (self.combo_shell_integ) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 200, 1);
        }
    }

    if (self.btn_keybindings_editor) |btn| {
        _ = MoveWindow(btn, pane_left, pane_top + 72, 220, 32, 1);
    }

    // Advanced-section "Open in default editor" button — anchored
    // under the content-pane header.
    {
        var ty: i32 = pane_top + 72;
        if (self.combo_auto_update) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 160, 1);
            ty += row_gap;
        }
        if (self.combo_auto_update_channel) |e| {
            _ = MoveWindow(e, pane_left, ty, 200, 140, 1);
            ty += row_gap;
        }
        if (self.btn_open_editor) |btn| {
            const w: i32 = 220;
            const h: i32 = 32;
            _ = MoveWindow(
                btn,
                pane_left,
                ty,
                w,
                h,
                1,
            );
        }
    }

    // Save button — always-visible, bottom-right of window.
    if (self.btn_save) |btn| {
        const w: i32 = 90;
        const h: i32 = 32;
        _ = MoveWindow(
            btn,
            rect.right - w - side_pad,
            rect.bottom - h - side_pad,
            w,
            h,
            1,
        );
    }
}

extern "user32" fn MoveWindow(
    hWnd: HWND,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    bRepaint: BOOL,
) callconv(.winapi) BOOL;

fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (msg == WM_NCCREATE) {
        const cs: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
        if (cs.lpCreateParams) |ptr| {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(ptr)));
        }
    }

    const owner = recoverOwner(hwnd);
    switch (msg) {
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            if (owner) |o| paint(hwnd, o);
            return 0;
        },
        WM_SIZE => {
            if (owner) |o| layoutChildren(o);
            return 0;
        },
        WM_COMMAND => {
            const id: usize = wParam & 0xFFFF;
            const notify: u16 = @intCast((wParam >> 16) & 0xFFFF);
            if (id == BTN_OPEN_EDITOR) {
                if (owner) |o| o.handle.openInEditor(o.handle.ctx);
                return 0;
            }
            if (id == BTN_KEYBINDINGS_EDITOR) {
                if (owner) |o| o.handle.openInEditor(o.handle.ctx);
                return 0;
            }
            if (id == BTN_SAVE) {
                if (owner) |o| o.save();
                return 0;
            }
            if (id == EDIT_SCROLLBACK and notify == EN_CHANGE) {
                if (owner) |o| o.syncScrollbackFromEdit();
                return 0;
            }
            // These parse into pending._arena; defer from EN_CHANGE to
            // EN_KILLFOCUS so we don't accumulate per-keystroke allocations.
            if (id == EDIT_FONT_FAMILY and notify == EN_KILLFOCUS) {
                if (owner) |o| o.syncFontFamilyFromEdit();
                return 0;
            }
            if (id == EDIT_FONT_SIZE and notify == EN_CHANGE) {
                if (owner) |o| o.syncFontSizeFromEdit();
                return 0;
            }
            if (id == EDIT_THEME and notify == EN_KILLFOCUS) {
                if (owner) |o| o.syncThemeFromEdit();
                return 0;
            }
            if (id == EDIT_BG_OPACITY and notify == EN_CHANGE) {
                if (owner) |o| o.syncBgOpacityFromEdit();
                return 0;
            }
            if (id == EDIT_COMMAND and notify == EN_KILLFOCUS) {
                if (owner) |o| o.syncCommandFromEdit();
                return 0;
            }
            if (id == EDIT_PAD_X and notify == EN_CHANGE) {
                if (owner) |o| o.syncPaddingFromEdit(.x);
                return 0;
            }
            if (id == EDIT_PAD_Y and notify == EN_CHANGE) {
                if (owner) |o| o.syncPaddingFromEdit(.y);
                return 0;
            }
            if (id == CHK_TRIM_TRAIL and notify == BN_CLICKED) {
                if (owner) |o| o.syncTrimTrailFromCheckbox();
                return 0;
            }
            if (id == CHK_DESKTOP_NOTIFICATIONS and notify == BN_CLICKED) {
                if (owner) |o| o.syncDesktopNotificationsFromCheckbox();
                return 0;
            }
            if (id == CHK_APP_NOTIFY_CLIPBOARD and notify == BN_CLICKED) {
                if (owner) |o| o.syncAppNotificationsFromCheckbox(.clipboard);
                return 0;
            }
            if (id == CHK_APP_NOTIFY_CONFIG and notify == BN_CLICKED) {
                if (owner) |o| o.syncAppNotificationsFromCheckbox(.config);
                return 0;
            }
            if (id == COMBO_CONFIRM_CLOSE and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncConfirmCloseFromCombo();
                return 0;
            }
            if (id == COMBO_COPY_ON_SELECT and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncCopyOnSelectFromCombo();
                return 0;
            }
            if (id == COMBO_CLIPBOARD_READ and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncClipboardAccessFromCombo("clipboard-read", o.combo_clipboard_read);
                return 0;
            }
            if (id == COMBO_CLIPBOARD_WRITE and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncClipboardAccessFromCombo("clipboard-write", o.combo_clipboard_write);
                return 0;
            }
            if (id == COMBO_LINK_URL and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncLinkUrlFromCombo();
                return 0;
            }
            if (id == COMBO_LINK_PREVIEWS and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncLinkPreviewsFromCombo();
                return 0;
            }
            if (id == COMBO_WINDOW_THEME and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncWindowThemeFromCombo();
                return 0;
            }
            if (id == COMBO_SHELL_INTEG and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncShellIntegFromCombo();
                return 0;
            }
            if (id == COMBO_CURSOR_STYLE and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncCursorStyleFromCombo();
                return 0;
            }
            if (id == CHK_BG_BLUR and notify == BN_CLICKED) {
                if (owner) |o| o.syncBgBlurFromCheckbox();
                return 0;
            }
            if (id == COMBO_PAD_BALANCE and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncPadBalanceFromCombo();
                return 0;
            }
            if (id == COMBO_AUTO_UPDATE and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncAutoUpdateFromCombo();
                return 0;
            }
            if (id == COMBO_AUTO_UPDATE_CHANNEL and notify == CBN_SELCHANGE) {
                if (owner) |o| o.syncAutoUpdateChannelFromCombo();
                return 0;
            }
            if (Section.fromButtonId(id)) |section| {
                if (owner) |o| o.setActiveSection(section);
                return 0;
            }
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_CLOSE => {
            _ = ShowWindow(hwnd, SW_HIDE);
            if (owner) |o| {
                o.clearChildRefs();
                // Let the app re-evaluate its quit-timer policy. If
                // we were the last live UI window, the timer kicks in
                // now; otherwise this is a no-op.
                o.handle.onClosed(o.handle.ctx);
            }
            _ = DestroyWindow(hwnd);
            return 0;
        },
        WM_NCDESTROY => {
            // Clear back-pointer; the settings wndproc will no longer
            // dereference a freed owner even if a late paint slips
            // through. `onClosed` already fired from WM_CLOSE in the
            // user-initiated close path; avoid firing again here so
            // `App.deinit → settings_window.deinit` (which destroys
            // the HWND without the user closing it) doesn't re-enter
            // the quit-timer path during teardown.
            if (owner) |o| o.clearChildRefs();
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            return DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        else => return DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn recoverOwner(hwnd: HWND) ?*SettingsWindow {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(raw)));
}

const DT_LEFT: UINT = 0x0;
const DT_WORDBREAK: UINT = 0x10;
const DT_TOP: UINT = 0x0;
const DT_CALCRECT: UINT = 0x400;

fn paint(hwnd: HWND, owner: *SettingsWindow) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);

    var rect: RECT = undefined;
    if (GetClientRect(hwnd, &rect) == 0) return;

    const bg = owner.handle.chromeBg(owner.handle.ctx);
    const fg = owner.handle.textPrimary(owner.handle.ctx);

    const brush = GetStockObject(DC_BRUSH);
    _ = SetDCBrushColor(hdc, bg);
    _ = FillRect(hdc, &rect, brush);

    // Left rail gets a subtle tint so the section buttons visually
    // separate from the content pane. We darken `bg` toward black;
    // in light mode this becomes a slightly darker shade, in dark
    // mode a slightly lighter one (from the DCBrushColor clamp).
    var rail_rect = rect;
    rail_rect.right = left_rail_width;
    _ = SetDCBrushColor(hdc, tintBg(bg));
    _ = FillRect(hdc, &rail_rect, brush);

    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(hdc, fg);

    // Content pane: header + section summary.
    const pane_left = left_rail_width + side_pad;
    const pane_right = rect.right - side_pad;
    const pane_top = section_btn_top_pad;

    // Section header at top-left of the content pane.
    var header_buf_w: [128]u16 = undefined;
    const header_w = utf8ToW(&header_buf_w, owner.active_section.headerText());
    var header_rect: RECT = .{
        .left = pane_left,
        .top = pane_top,
        .right = pane_right,
        .bottom = pane_top + 40,
    };
    _ = DrawTextW(
        hdc,
        header_w,
        -1,
        &header_rect,
        DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX,
    );

    // Section summary below the header.
    var body_buf_w: [256]u16 = undefined;
    const body_w = utf8ToW(&body_buf_w, owner.active_section.placeholderText());
    var body_rect: RECT = .{
        .left = pane_left,
        .top = pane_top + 48,
        .right = pane_right,
        .bottom = pane_top + 68,
    };
    _ = DrawTextW(
        hdc,
        body_w,
        -1,
        &body_rect,
        DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX,
    );

    // Per-field labels painted just above each control. Labels are
    // only drawn for the active section's controls to avoid clutter.
    // The y-values match the layout stack in `layoutChildren` minus
    // the label_pad.
    const label_pad: i32 = 18;
    const row_gap: i32 = 48;
    switch (owner.active_section) {
        .terminal => {
            const labels = [_][]const u8{
                "Scrollback limit (rows, 0 = unlimited)",
                "Close confirmation",
                "Copy on select",
                "OSC 52 clipboard read requests",
                "OSC 52 clipboard write requests",
                "Clickable URL opening",
                "Link preview popups",
                "Clipboard trimming",
                "Terminal notifications",
                "Clipboard-copy notification",
                "Config-reload notification",
            };
            var ly: i32 = pane_top + 72;
            for (labels) |lbl| {
                drawLabel(hdc, pane_left, ly - label_pad, pane_right, lbl);
                ly += row_gap;
            }
        },
        .appearance => {
            const labels = [_][]const u8{
                "Font family fallbacks (comma-separated)",
                "Font size (pt)",
                "Terminal theme name, absolute path, or light/dark pair",
                "Background opacity (0.0 .. 1.0)",
                "Window theme",
                "Cursor style",
                "Window padding X (left/right or single value)",
                "Window padding Y (top/bottom or single value)",
                "Window padding balance",
                "Background blur",
            };
            var ly: i32 = pane_top + 72;
            for (labels) |lbl| {
                drawLabel(hdc, pane_left, ly - label_pad, pane_right, lbl);
                ly += row_gap;
            }
        },
        .shell => {
            drawLabel(hdc, pane_left, pane_top + 72 - label_pad, pane_right, "Default command (blank = auto-detect)");
            drawLabel(hdc, pane_left, pane_top + 72 + row_gap - label_pad, pane_right, "Shell integration");
        },
        .keybindings => {
            drawLabel(hdc, pane_left, pane_top + 72 - label_pad, pane_right, "Keybind configuration");
            drawHelpBlock(
                hdc,
                pane_left,
                pane_top + 72 + row_gap,
                pane_right,
                keybindingsHelpText(),
            );
        },
        .advanced => {
            drawLabel(hdc, pane_left, pane_top + 72 - label_pad, pane_right, "Auto-update mode");
            drawLabel(hdc, pane_left, pane_top + 72 + row_gap - label_pad, pane_right, "Auto-update channel");
            drawLabel(hdc, pane_left, pane_top + 72 + row_gap * 2 - label_pad, pane_right, "Full config editor");
        },
    }
}

fn drawLabel(hdc: ?*anyopaque, x: i32, y: i32, right: i32, text: []const u8) void {
    var buf: [128]u16 = undefined;
    const w = utf8ToW(&buf, text);
    var rect: RECT = .{ .left = x, .top = y, .right = right, .bottom = y + 16 };
    _ = DrawTextW(hdc, w, -1, &rect, DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX);
}

fn drawHelpBlock(hdc: ?*anyopaque, x: i32, y: i32, right: i32, text: []const u8) void {
    var buf: [1024]u16 = undefined;
    const w = utf8ToW(&buf, text);
    const flags = DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX;
    var rect: RECT = .{ .left = x, .top = y, .right = right, .bottom = y };
    _ = DrawTextW(hdc, w, -1, &rect, flags | DT_CALCRECT);
    _ = DrawTextW(hdc, w, -1, &rect, DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX);
}

fn readEditUtf8(edit: HWND, buf: []u8) ?[]const u8 {
    var buf_w: [edit_text_max_code_units]u16 = undefined;
    const n = GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
    const written = std.unicode.utf16LeToUtf8(buf, buf_w[0..@intCast(n)]) catch return null;
    return buf[0..written];
}

fn setEditText(edit: HWND, text: []const u8, suppress: *bool) void {
    var buf_w: [edit_text_max_code_units]u16 = undefined;
    const w = utf8ToW(&buf_w, text);
    suppress.* = true;
    _ = SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
    suppress.* = false;
}

fn parseFontFamilyEditText(alloc: std.mem.Allocator, text: []const u8) !Config.RepeatableString {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return .{};

    var next: Config.RepeatableString = .{};
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part| {
        const family = std.mem.trim(u8, part, " \t");
        if (family.len == 0) continue;
        try next.parseCLI(alloc, family);
    }
    return next;
}

fn writeCommandForEdit(writer: *std.Io.Writer, value: Config.Command) !void {
    switch (value) {
        .shell => |v| try writer.writeAll(v),
        .direct => |v| {
            try writer.writeAll("direct:");
            for (v, 0..) |arg, i| {
                if (i != 0) try writer.writeByte(' ');
                try Config.Command.writeDirectArg(writer, arg);
            }
        },
    }
}

fn utf8ToW(buf: []u16, text: []const u8) [*:0]const u16 {
    const written = std.unicode.utf8ToUtf16Le(buf, text) catch buf.len;
    const n: usize = @min(written, buf.len - 1);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// Lighten (in dark mode) or darken (in light mode) a COLORREF by a
/// fixed delta. Used for the left-rail tint. Color is packed as
/// 0x00BBGGRR (COLORREF) so we decompose and recompose per channel.
fn tintBg(color: COLORREF) COLORREF {
    const r: u32 = color & 0xFF;
    const g: u32 = (color >> 8) & 0xFF;
    const b: u32 = (color >> 16) & 0xFF;
    // Heuristic: if the average channel is bright, darken; else lighten.
    const avg = (r + g + b) / 3;
    if (avg > 128) {
        return packColor(sat8(r, -16), sat8(g, -16), sat8(b, -16));
    }
    return packColor(sat8(r, 16), sat8(g, 16), sat8(b, 16));
}

fn sat8(ch: u32, delta: i32) u32 {
    const signed: i32 = @intCast(ch);
    const out = signed + delta;
    if (out < 0) return 0;
    if (out > 255) return 255;
    return @intCast(out);
}

fn packColor(r: u32, g: u32, b: u32) COLORREF {
    return r | (g << 8) | (b << 16);
}

test "settings background blur checkbox preserves enabled radius" {
    try std.testing.expectEqual(
        Config.BackgroundBlur{ .radius = 42 },
        backgroundBlurFromCheckbox(.{ .radius = 42 }, true),
    );
    try std.testing.expectEqual(
        .true,
        backgroundBlurFromCheckbox(.false, true),
    );
    try std.testing.expectEqual(
        .true,
        backgroundBlurFromCheckbox(.{ .radius = 0 }, true),
    );
}

test "settings background blur checkbox can disable any variant" {
    try std.testing.expectEqual(
        .false,
        backgroundBlurFromCheckbox(.true, false),
    );
    try std.testing.expectEqual(
        .false,
        backgroundBlurFromCheckbox(.{ .radius = 42 }, false),
    );
}

test "settings policy combo mappings round trip" {
    try std.testing.expectEqual(Config.ClipboardAccess.ask, clipboardAccessFromComboIndex(0).?);
    try std.testing.expectEqual(Config.ClipboardAccess.allow, clipboardAccessFromComboIndex(1).?);
    try std.testing.expectEqual(Config.ClipboardAccess.deny, clipboardAccessFromComboIndex(2).?);
    try std.testing.expectEqual(@as(?Config.ClipboardAccess, null), clipboardAccessFromComboIndex(3));
    try std.testing.expectEqual(@as(usize, 0), comboIndexFromClipboardAccess(.ask));
    try std.testing.expectEqual(@as(usize, 1), comboIndexFromClipboardAccess(.allow));
    try std.testing.expectEqual(@as(usize, 2), comboIndexFromClipboardAccess(.deny));

    try std.testing.expectEqual(true, linkUrlFromComboIndex(0).?);
    try std.testing.expectEqual(false, linkUrlFromComboIndex(1).?);
    try std.testing.expectEqual(@as(?bool, null), linkUrlFromComboIndex(2));
    try std.testing.expectEqual(@as(usize, 0), comboIndexFromLinkUrl(true));
    try std.testing.expectEqual(@as(usize, 1), comboIndexFromLinkUrl(false));

    try std.testing.expectEqual(Config.LinkPreviews.true, linkPreviewsFromComboIndex(0).?);
    try std.testing.expectEqual(Config.LinkPreviews.osc8, linkPreviewsFromComboIndex(1).?);
    try std.testing.expectEqual(Config.LinkPreviews.false, linkPreviewsFromComboIndex(2).?);
    try std.testing.expectEqual(@as(?Config.LinkPreviews, null), linkPreviewsFromComboIndex(3));
    try std.testing.expectEqual(@as(usize, 0), comboIndexFromLinkPreviews(.true));
    try std.testing.expectEqual(@as(usize, 1), comboIndexFromLinkPreviews(.osc8));
    try std.testing.expectEqual(@as(usize, 2), comboIndexFromLinkPreviews(.false));
}

test "win32_settings: font-family edit text builds repeatable list" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try parseFontFamilyEditText(
        arena.allocator(),
        " JetBrains Mono, Cascadia Code , , Symbols Nerd Font ",
    );
    try testing.expectEqual(@as(usize, 3), parsed.list.items.len);
    try testing.expectEqualStrings("JetBrains Mono", parsed.list.items[0]);
    try testing.expectEqualStrings("Cascadia Code", parsed.list.items[1]);
    try testing.expectEqualStrings("Symbols Nerd Font", parsed.list.items[2]);
}

test "win32_settings: direct command edit text quotes argv boundaries" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var source: Config.Command = undefined;
    try source.parseCLI(arena.allocator(), "direct:cmd.exe /c \"echo hello\" \"C:\\Program Files\\winghostty\"");

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeCommandForEdit(&writer, source);
    try testing.expectEqualStrings(
        "direct:cmd.exe /c \"echo hello\" \"C:\\Program Files\\winghostty\"",
        writer.buffered(),
    );

    var round_trip: Config.Command = undefined;
    try round_trip.parseCLI(arena.allocator(), writer.buffered());
    try testing.expect(round_trip == .direct);
    try testing.expectEqual(@as(usize, 4), round_trip.direct.len);
    try testing.expectEqualStrings("echo hello", round_trip.direct[2]);
    try testing.expectEqualStrings("C:\\Program Files\\winghostty", round_trip.direct[3]);
}

test "win32_settings: keybinding help points to discoverability commands" {
    const text = keybindingsHelpText();

    try std.testing.expect(text.len < 1024);
    try std.testing.expect(std.mem.indexOfScalar(u8, text, 0) == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+list-keybinds --default") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+list-keybinds --docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+list-actions --docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "+explain-config --keybind=<action>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "keybind = ctrl+a>n=new_window") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "keybind = chain=goto_split:left") != null);
}
