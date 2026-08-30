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
//!   * `WM_CLOSE` — closes immediately when clean or surfaces the
//!     settings-owned inline dirty-close confirmation.
//!   * `SettingsWindow.deinit(self)` — called from App termination;
//!     destroys the HWND and releases owned snapshots/providers.
//!
//! The editable draft is a deeply owned `Config` snapshot saved atomically
//! through `AppHandle.saveAndReload`.

const std = @import("std");
const windows = std.os.windows;
const Config = @import("../config/Config.zig");
const cli_help = @import("../cli/help.zig");
const win32_types = @import("win32_types.zig");
const win32_theme = @import("win32_theme.zig");
const win32_uia = @import("win32_uia/mod.zig");
const settings_transaction = @import("win32_settings_transaction.zig");
const sys = @import("win32/sys.zig");
const SetFocus = sys.SetFocus;

/// Minimal set of Win32 aliases + externs we need here. Shared ABI structs
/// live in `win32_types.zig` so this module stays free of an `*App` type
/// dependency without duplicating layout-sensitive declarations.
const HWND = win32_types.HWND;
const HINSTANCE = win32_types.HINSTANCE;
const HBRUSH = win32_types.HBRUSH;
const HCURSOR = win32_types.HCURSOR;
const HDC = win32_types.HDC;
const HGDIOBJ = win32_types.HGDIOBJ;
const HRGN = *anyopaque;
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
const GUID = windows.GUID;
const HRESULT = windows.HRESULT;
const HMONITOR = sys.HMONITOR;

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_MAXIMIZEBOX: u32 = 0x00010000;
const WS_EX_APPWINDOW: u32 = 0x00040000;
const WS_EX_CLIENTEDGE: u32 = 0x00000200;
const WS_VSCROLL: u32 = 0x00200000;
const SW_HIDE: i32 = 0;
const SW_SHOWNORMAL: i32 = 1;
const SW_RESTORE: i32 = 9;
const DT_WORDBREAK: u32 = 0x0010;
const DT_CALCRECT: u32 = 0x0400;
const DT_NOPREFIX: u32 = 0x0800;
const DT_SINGLELINE: u32 = 0x0020;
const DT_VCENTER: u32 = 0x0004;
const GWLP_USERDATA: i32 = -21;
const GWLP_WNDPROC: i32 = -4;
const GWL_STYLE: i32 = -16;
const CS_HREDRAW: u32 = 0x2;
const CS_VREDRAW: u32 = 0x1;
const IDC_ARROW: usize = 32512;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

const WM_CLOSE: UINT = 0x0010;
const WM_NCCREATE: UINT = 0x0081;
const WM_PAINT: UINT = 0x000F;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_NCDESTROY: UINT = 0x0082;
const WM_GETOBJECT: UINT = 0x003D;
const WM_COMMAND: UINT = 0x0111;
const WM_SIZE: UINT = 0x0005;
const WM_SETFOCUS: UINT = 0x0007;
const WM_KILLFOCUS: UINT = 0x0008;
const WM_VSCROLL: UINT = 0x0115;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_MOUSELEAVE: UINT = 0x02A3;
const WM_GETMINMAXINFO: UINT = 0x0024;
const WM_DPICHANGED: UINT = 0x02E0;
const WM_SETFONT: UINT = 0x0030;
const WM_GETFONT: UINT = 0x0031;
const WM_SETTINGCHANGE: UINT = 0x001A;
const WM_SYSCOLORCHANGE: UINT = 0x0015;
const WM_THEMECHANGED: UINT = 0x031A;
const WM_CTLCOLORMSGBOX: UINT = 0x0132;
const WM_CTLCOLOREDIT: UINT = 0x0133;
const WM_CTLCOLORLISTBOX: UINT = 0x0134;
const WM_CTLCOLORBTN: UINT = 0x0135;
const WM_CTLCOLORDLG: UINT = 0x0136;
const WM_CTLCOLORSTATIC: UINT = 0x0138;
const WM_APP: UINT = 0x8000;
// Keep Settings-private window messages out of the App pump's reserved
// WM_APP+1..+6 range; the pump consumes those before DispatchMessageW.
const WM_SETTINGS_CLOSE_NOW: UINT = WM_APP + 0x100;
const WM_SETTINGS_PROOF_VIEWPORT_TOP: UINT = WM_APP + 0x101;
const WM_SETTINGS_PROOF_VIEWPORT_BOTTOM: UINT = WM_APP + 0x102;
const WM_SETTINGS_PROOF_KILLFOCUS_COUNT: UINT = WM_APP + 0x103;
const WM_SETTINGS_PROOF_REDRAW_SUCCEEDED: UINT = WM_APP + 0x104;
const WM_SETTINGS_PROOF_UPDATE_PENDING: UINT = WM_APP + 0x105;
const WM_SETTINGS_PROOF_LIVE_FOCUS_RING: UINT = WM_APP + 0x106;
const WM_SETTINGS_PROOF_CHILD: UINT = WM_APP + 0x107;
const WM_SETTINGS_PROOF_SET_FOCUS: UINT = WM_APP + 0x108;
const WM_SETTINGS_PROOF_PAINT_COUNT: UINT = WM_APP + 0x109;
const WM_SETTINGS_PROOF_LAYOUT_REDRAW_SUCCEEDED: UINT = WM_APP + 0x10A;
const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_TABSTOP: u32 = 0x00010000;
const WS_GROUP: u32 = 0x00020000;
const BS_PUSHBUTTON: u32 = 0x0;
const BS_AUTORADIOBUTTON: u32 = 0x9;
const BS_PUSHLIKE: u32 = 0x1000;
const BS_OWNERDRAW: u32 = 0xB;
const SS_LEFT: u32 = 0x0000;
const SS_NOPREFIX: u32 = 0x0080;
const BTN_OPEN_EDITOR: usize = 101;
const BTN_SECTION_APPEARANCE: usize = 201;
const BTN_SECTION_TERMINAL: usize = 202;
const BTN_SECTION_SHELL: usize = 203;
const BTN_SECTION_KEYBINDINGS: usize = 204;
const BTN_SECTION_ADVANCED: usize = 205;
const BTN_SECTION_PRIVACY: usize = 206;
const BTN_SECTION_UPDATES: usize = 207;
const BTN_SAVE: usize = 301;
const BTN_KEYBINDINGS_EDITOR: usize = 302;
const BTN_CONFLICT_KEEP: usize = 303;
const BTN_CONFLICT_USE_DISK: usize = 304;
const BTN_CLOSE_SAVE: usize = 305;
const BTN_CLOSE_DISCARD: usize = 306;
// IsDialogMessageW maps Escape to the conventional cancel control ID,
// including when focus is inside an EDIT or COMBO child.
const BTN_CLOSE_KEEP_EDITING: usize = 2;
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
const EN_SETFOCUS: u16 = 0x0100;
const CBN_SETFOCUS: u16 = 0x0003;
const BN_SETFOCUS: u16 = 0x0006;
const BN_KILLFOCUS: u16 = 0x0007;
const WM_SETTEXT: UINT = 0x000C;
const EM_LIMITTEXT: UINT = 0x00C5;
const BS_AUTOCHECKBOX: u32 = 0x3;
const BM_SETCHECK: UINT = 0x00F1;
const BM_GETCHECK: UINT = 0x00F0;
const BM_GETSTATE: UINT = 0x00F2;
const BM_SETSTATE: UINT = 0x00F3;
const BST_CHECKED: usize = 1;
const BST_UNCHECKED: usize = 0;
const BST_PUSHED: usize = 0x0004;
const CB_ADDSTRING: UINT = 0x0143;
const CB_SETCURSEL: UINT = 0x014E;
const CB_GETCURSEL: UINT = 0x0147;
const CB_RESETCONTENT: UINT = 0x014B;
const CB_SETITEMHEIGHT: UINT = 0x0153;
const CBS_DROPDOWNLIST: u32 = 0x3;
const CBS_HASSTRINGS: u32 = 0x200;
const OBJID_CLIENT: u32 = @bitCast(@as(i32, -4));
const CHILDID_SELF: u32 = 0;
const PROPID_ACC_NAME = GUID.parse("{608D3DF8-8128-4AA7-A428-F55E49267291}");
const CLSID_ACC_PROP_SERVICES = GUID.parse("{B5F8350B-0548-48B1-A6EE-88BD00B4A5E7}");
const IID_IACC_PROP_SERVICES = GUID.parse("{6E26E776-04F0-495D-80E4-3330352E3169}");
const CLSCTX_INPROC_SERVER: u32 = 0x1;
const EVENT_OBJECT_NAMECHANGE: u32 = 0x800C;
const SPI_GETWORKAREA: UINT = 0x0030;
const MONITOR_DEFAULTTONEAREST: u32 = 2;
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOREDRAW: UINT = 0x0008;
const SWP_NOACTIVATE: UINT = 0x0010;
const SB_VERT: c_int = 1;
const SB_LINEUP: usize = 0;
const SB_LINEDOWN: usize = 1;
const SB_PAGEUP: usize = 2;
const SB_PAGEDOWN: usize = 3;
const SB_THUMBPOSITION: usize = 4;
const SB_THUMBTRACK: usize = 5;
const SB_TOP: usize = 6;
const SB_BOTTOM: usize = 7;
const SIF_RANGE: u32 = 0x0001;
const SIF_PAGE: u32 = 0x0002;
const SIF_POS: u32 = 0x0004;
const SIF_TRACKPOS: u32 = 0x0010;
const TME_LEAVE: u32 = 0x00000002;
const RDW_INVALIDATE: u32 = 0x0001;
const RDW_ERASE: u32 = 0x0004;
const RDW_ALLCHILDREN: u32 = 0x0080;
const RDW_UPDATENOW: u32 = 0x0100;

/// Sections on the left rail. Section-specific controls (e.g. the
/// "Open in default editor" button in Advanced) are shown / hidden on
/// the active section; non-specific controls stay visible across
/// sections.
pub const Section = enum(u32) {
    appearance,
    terminal,
    shell,
    privacy,
    updates,
    keybindings,
    advanced,

    fn fromButtonId(id: usize) ?Section {
        return switch (id) {
            BTN_SECTION_APPEARANCE => .appearance,
            BTN_SECTION_TERMINAL => .terminal,
            BTN_SECTION_SHELL => .shell,
            BTN_SECTION_PRIVACY => .privacy,
            BTN_SECTION_UPDATES => .updates,
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
            .privacy => std.unicode.utf8ToUtf16LeStringLiteral("Privacy"),
            .updates => std.unicode.utf8ToUtf16LeStringLiteral("Updates"),
            .keybindings => std.unicode.utf8ToUtf16LeStringLiteral("Keybindings"),
            .advanced => std.unicode.utf8ToUtf16LeStringLiteral("Advanced"),
        };
    }

    fn headerText(self: Section) []const u8 {
        return switch (self) {
            .appearance => "Appearance",
            .terminal => "Terminal",
            .shell => "Shell",
            .privacy => "Privacy",
            .updates => "Updates",
            .keybindings => "Keybindings",
            .advanced => "Advanced",
        };
    }

    fn placeholderText(self: Section) []const u8 {
        return switch (self) {
            .appearance => "Font family, size, theme, opacity, cursor, padding, and background blur.",
            .terminal => "Scrollback, close confirmation, copy behavior, and clipboard trimming.",
            .shell => "Default shell command and shell integration detection mode.",
            .privacy => "Clipboard access, link handling, and notification privacy controls.",
            .updates => "Automatic update policy and release channel.",
            .keybindings => "Open the config file for keybind edits; list defaults, actions, and docs from the CLI.",
            .advanced => "Updater defaults plus the text editor escape hatch for config keys that do not yet have native controls.",
        };
    }
};
const section_count = std.enums.values(Section).len;
comptime {
    if (section_count != win32_uia.widgets.settings_section_count) {
        @compileError("settings section UIA provider count must match Section");
    }
}

fn clickedButton(id: usize, notify: u16, expected_id: usize) bool {
    return id == expected_id and notify == BN_CLICKED;
}

fn clickedSection(id: usize, notify: u16) ?Section {
    if (notify != BN_CLICKED) return null;
    return Section.fromButtonId(id);
}

fn validatedSectionClickFocusTarget(source: ?HWND, expected: ?HWND) ?HWND {
    const source_hwnd = source orelse return null;
    const expected_hwnd = expected orelse return null;
    return if (source_hwnd == expected_hwnd) source_hwnd else null;
}

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

/// Ownership-safe native settings tracked by the transaction model. The three
/// arena-backed edit fields use a parallel tracker below because transaction
/// values must not borrow slices from replaceable Config snapshots.
pub const SettingField = enum {
    scrollback_limit,
    font_size,
    background_opacity,
    window_padding_x,
    window_padding_y,
    trim_trailing_spaces,
    desktop_notifications,
    app_notify_clipboard,
    app_notify_config,
    confirm_close,
    copy_on_select,
    clipboard_read,
    clipboard_write,
    link_url,
    link_previews,
    window_theme,
    shell_integration,
    cursor_style,
    background_blur,
    padding_balance,
    auto_update,
    auto_update_channel,
};

const OwnedSettingField = enum {
    font_family,
    theme,
    command,

    fn label(self: OwnedSettingField) []const u8 {
        return switch (self) {
            .font_family => "Font family",
            .theme => "Terminal theme",
            .command => "Default command",
        };
    }
};

const owned_setting_field_count = std.enums.values(OwnedSettingField).len;

/// Scalar EDIT controls whose raw text can temporarily be invalid and
/// therefore cannot yet be represented by the typed settings transaction.
const RawScalarField = enum {
    scrollback_limit,
    font_size,
    background_opacity,
    window_padding_x,
    window_padding_y,
};

const raw_scalar_field_count = std.enums.values(RawScalarField).len;

const SettingsStatus = union(enum) {
    raw_validation: RawScalarField,
    owned_validation: HWND,
    conflict: SettingField,
    owned_conflict: OwnedSettingField,
    none,
};

pub const SettingValue = union(SettingField) {
    scrollback_limit: @FieldType(Config, "scrollback-limit"),
    font_size: @FieldType(Config, "font-size"),
    background_opacity: @FieldType(Config, "background-opacity"),
    window_padding_x: @FieldType(Config, "window-padding-x"),
    window_padding_y: @FieldType(Config, "window-padding-y"),
    trim_trailing_spaces: @FieldType(Config, "clipboard-trim-trailing-spaces"),
    desktop_notifications: @FieldType(Config, "desktop-notifications"),
    app_notify_clipboard: bool,
    app_notify_config: bool,
    confirm_close: @FieldType(Config, "confirm-close-surface"),
    copy_on_select: @FieldType(Config, "copy-on-select"),
    clipboard_read: @FieldType(Config, "clipboard-read"),
    clipboard_write: @FieldType(Config, "clipboard-write"),
    link_url: @FieldType(Config, "link-url"),
    link_previews: @FieldType(Config, "link-previews"),
    window_theme: @FieldType(Config, "window-theme"),
    shell_integration: @FieldType(Config, "shell-integration"),
    cursor_style: @FieldType(Config, "cursor-style"),
    background_blur: @FieldType(Config, "background-blur"),
    padding_balance: @FieldType(Config, "window-padding-balance"),
    auto_update: @FieldType(Config, "auto-update"),
    auto_update_channel: @FieldType(Config, "auto-update-channel"),
};

fn settingValueEql(a: SettingValue, b: SettingValue) bool {
    return std.meta.eql(a, b);
}

const SettingsTransaction = settings_transaction.Transaction(SettingField, SettingValue, settingValueEql);
const setting_field_count = std.enums.values(SettingField).len;

pub const ConflictResolution = SettingsTransaction.Resolution;
pub const ApplyId = SettingsTransaction.ApplyId;

pub const SaveCompletion = union(enum) {
    succeeded: u64,
    failed: SaveError,
};

fn settingValue(config: *const Config, field: SettingField) SettingValue {
    return switch (field) {
        .scrollback_limit => .{ .scrollback_limit = config.@"scrollback-limit" },
        .font_size => .{ .font_size = config.@"font-size" },
        .background_opacity => .{ .background_opacity = config.@"background-opacity" },
        .window_padding_x => .{ .window_padding_x = config.@"window-padding-x" },
        .window_padding_y => .{ .window_padding_y = config.@"window-padding-y" },
        .trim_trailing_spaces => .{ .trim_trailing_spaces = config.@"clipboard-trim-trailing-spaces" },
        .desktop_notifications => .{ .desktop_notifications = config.@"desktop-notifications" },
        .app_notify_clipboard => .{ .app_notify_clipboard = config.@"app-notifications".@"clipboard-copy" },
        .app_notify_config => .{ .app_notify_config = config.@"app-notifications".@"config-reload" },
        .confirm_close => .{ .confirm_close = config.@"confirm-close-surface" },
        .copy_on_select => .{ .copy_on_select = config.@"copy-on-select" },
        .clipboard_read => .{ .clipboard_read = config.@"clipboard-read" },
        .clipboard_write => .{ .clipboard_write = config.@"clipboard-write" },
        .link_url => .{ .link_url = config.@"link-url" },
        .link_previews => .{ .link_previews = config.@"link-previews" },
        .window_theme => .{ .window_theme = config.@"window-theme" },
        .shell_integration => .{ .shell_integration = config.@"shell-integration" },
        .cursor_style => .{ .cursor_style = config.@"cursor-style" },
        .background_blur => .{ .background_blur = config.@"background-blur" },
        .padding_balance => .{ .padding_balance = config.@"window-padding-balance" },
        .auto_update => .{ .auto_update = config.@"auto-update" },
        .auto_update_channel => .{ .auto_update_channel = config.@"auto-update-channel" },
    };
}

fn setSettingValue(config: *Config, value: SettingValue) void {
    switch (value) {
        .scrollback_limit => |v| config.@"scrollback-limit" = v,
        .font_size => |v| config.@"font-size" = v,
        .background_opacity => |v| config.@"background-opacity" = v,
        .window_padding_x => |v| config.@"window-padding-x" = v,
        .window_padding_y => |v| config.@"window-padding-y" = v,
        .trim_trailing_spaces => |v| config.@"clipboard-trim-trailing-spaces" = v,
        .desktop_notifications => |v| config.@"desktop-notifications" = v,
        .app_notify_clipboard => |v| config.@"app-notifications".@"clipboard-copy" = v,
        .app_notify_config => |v| config.@"app-notifications".@"config-reload" = v,
        .confirm_close => |v| config.@"confirm-close-surface" = v,
        .copy_on_select => |v| config.@"copy-on-select" = v,
        .clipboard_read => |v| config.@"clipboard-read" = v,
        .clipboard_write => |v| config.@"clipboard-write" = v,
        .link_url => |v| config.@"link-url" = v,
        .link_previews => |v| config.@"link-previews" = v,
        .window_theme => |v| config.@"window-theme" = v,
        .shell_integration => |v| config.@"shell-integration" = v,
        .cursor_style => |v| config.@"cursor-style" = v,
        .background_blur => |v| config.@"background-blur" = v,
        .padding_balance => |v| config.@"window-padding-balance" = v,
        .auto_update => |v| config.@"auto-update" = v,
        .auto_update_channel => |v| config.@"auto-update-channel" = v,
    }
}

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

// Win32 entry points used by this module. `win32/sys.zig` owns the shared
// declarations; the few below it does not export stay local.

const RegisterClassExW = sys.RegisterClassExW;
const CreateWindowExW = sys.CreateWindowExW;
const DefWindowProcW = sys.DefWindowProcW;
const CallWindowProcW = sys.CallWindowProcW;
const ShowWindow = sys.ShowWindow;
const EnableWindow = sys.EnableWindow;
const SetForegroundWindow = sys.SetForegroundWindow;
const GetFocus = sys.GetFocus;
const GetParent = sys.GetParent;
const IsChild = sys.IsChild;
const IsWindowVisible = sys.IsWindowVisible;
const IsWindowEnabled = sys.IsWindowEnabled;
const PostMessageW = sys.PostMessageW;
const DestroyWindow = sys.DestroyWindow;
const GetClientRect = sys.GetClientRect;
const GetWindowRect = sys.GetWindowRect;
const ScreenToClient = sys.ScreenToClient;
const GetDpiForWindow = sys.GetDpiForWindow;
const SetWindowPos = sys.SetWindowPos;
const SystemParametersInfoW = sys.SystemParametersInfoW;
const MonitorFromWindow = sys.MonitorFromWindow;
const GetMonitorInfoW = sys.GetMonitorInfoW;
const LoadCursorW = sys.LoadCursorW;
const SetWindowLongPtrW = sys.SetWindowLongPtrW;
const GetWindowLongPtrW = sys.GetWindowLongPtrW;
const BeginPaint = sys.BeginPaint;
const EndPaint = sys.EndPaint;
const GetDC = sys.GetDC;
const ReleaseDC = sys.ReleaseDC;
const DrawTextW = sys.DrawTextW;
const IsWindow = sys.IsWindow;
const IsIconic = sys.IsIconic;
const InvalidateRect = sys.InvalidateRect;
const RedrawWindow = sys.RedrawWindow;
const GetWindowTextW = sys.GetWindowTextW;
const SendMessageW = sys.SendMessageW;
const ShowScrollBar = sys.ShowScrollBar;
const TrackMouseEvent = sys.TrackMouseEvent;
const SetWindowRgn = sys.SetWindowRgn;
const GetSysColor = sys.GetSysColor;
const NotifyWinEvent = sys.NotifyWinEvent;
const EnumChildWindows = sys.EnumChildWindows;
const CreateFontW = sys.CreateFontW;
const DeleteObject = sys.DeleteObject;
const SelectObject = sys.SelectObject;
const CreateRectRgn = sys.CreateRectRgn;
const FillRect = sys.FillRect;
const GetStockObject = sys.GetStockObject;
const SetDCBrushColor = sys.SetDCBrushColor;
const CreateSolidBrush = sys.CreateSolidBrush;
const SetBkColor = sys.SetBkColor;
const SetTextColor = sys.SetTextColor;
const SetBkMode = sys.SetBkMode;
const MoveWindow = sys.MoveWindow;

extern "user32" fn AdjustWindowRectExForDpi(lpRect: *RECT, dwStyle: u32, bMenu: BOOL, dwExStyle: u32, dpi: UINT) callconv(.winapi) BOOL;
extern "user32" fn GetUpdateRect(hWnd: HWND, lpRect: ?*RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn SetScrollInfo(hWnd: HWND, nBar: c_int, lpsi: *const SCROLLINFO, redraw: BOOL) callconv(.winapi) c_int;
extern "user32" fn GetScrollInfo(hWnd: HWND, nBar: c_int, lpsi: *SCROLLINFO) callconv(.winapi) BOOL;
extern "user32" fn FrameRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.winapi) i32;
extern "gdi32" fn EnumFontFamiliesExW(
    hdc: HDC,
    logfont: *LOGFONTW,
    callback: *const fn (*const LOGFONTW, ?*const anyopaque, u32, LPARAM) callconv(.winapi) c_int,
    lParam: LPARAM,
    flags: u32,
) callconv(.winapi) c_int;
const DC_BRUSH: i32 = 18;
const TRANSPARENT: c_int = 1;
const COLOR_WINDOW: c_int = 5;
const COLOR_WINDOWTEXT: c_int = 8;
const COLOR_BTNFACE: c_int = 15;
const COLOR_GRAYTEXT: c_int = 17;
const COLOR_BTNTEXT: c_int = 18;
const COLOR_HIGHLIGHT: c_int = 13;
const COLOR_HIGHLIGHTTEXT: c_int = 14;

const PAINTSTRUCT = win32_types.PAINTSTRUCT;
const CREATESTRUCTW = win32_types.CREATESTRUCTW;
const WNDCLASSEXW = win32_types.WNDCLASSEXW;
const POINT = win32_types.POINT;
const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
const MONITORINFO = sys.MONITORINFO;
const TRACKMOUSEEVENT = sys.TRACKMOUSEEVENT;
const LOGFONTW = sys.LOGFONTW;
const SCROLLINFO = extern struct {
    cbSize: u32,
    fMask: u32,
    nMin: i32,
    nMax: i32,
    nPage: u32,
    nPos: i32,
    nTrackPos: i32,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.settings");
const edit_text_max_code_units: usize = 4096;
const edit_text_max_utf8: usize = edit_text_max_code_units * 3;

const settings_label_specs = [_][]const u8{
    "Scrollback limit (rows, 0 = unlimited)",
    "Close confirmation",
    "Copy on select",
    "Font family fallbacks (comma-separated)",
    "Font size (pt)",
    "Terminal theme name, absolute path, or light/dark pair",
    "Background opacity (0.0 .. 1.0)",
    "Window theme",
    "Cursor style",
    "Window padding X (left/right or single value)",
    "Window padding Y (top/bottom or single value)",
    "Window padding balance",
    "Default command (blank = auto-detect)",
    "Shell integration",
    "OSC 52 clipboard read requests",
    "OSC 52 clipboard write requests",
    "Clickable URL opening",
    "Link preview popups",
    "Notifications",
    "Auto-update mode",
    "Auto-update channel",
    "Keybind configuration",
    "Full config editor",
};

const settings_text_count = 5 + settings_label_specs.len;
const SettingsControlRole = win32_uia.SettingsControlProvider.Role;
const settings_control_specs = [_]struct { role: SettingsControlRole, name: []const u8 }{
    .{ .role = .edit, .name = "Scrollback limit" },
    .{ .role = .combo_box, .name = "Close confirmation" },
    .{ .role = .combo_box, .name = "Copy on select" },
    .{ .role = .check_box, .name = "Clipboard trimming" },
    .{ .role = .edit, .name = "Font family fallbacks" },
    .{ .role = .edit, .name = "Font size" },
    .{ .role = .edit, .name = "Terminal theme" },
    .{ .role = .edit, .name = "Background opacity" },
    .{ .role = .combo_box, .name = "Window theme" },
    .{ .role = .combo_box, .name = "Cursor style" },
    .{ .role = .edit, .name = "Window padding X" },
    .{ .role = .edit, .name = "Window padding Y" },
    .{ .role = .combo_box, .name = "Window padding balance" },
    .{ .role = .check_box, .name = "Background blur" },
    .{ .role = .edit, .name = "Default command" },
    .{ .role = .combo_box, .name = "Shell integration" },
    .{ .role = .combo_box, .name = "OSC 52 clipboard read requests" },
    .{ .role = .combo_box, .name = "OSC 52 clipboard write requests" },
    .{ .role = .combo_box, .name = "Clickable URL opening" },
    .{ .role = .combo_box, .name = "Link preview popups" },
    .{ .role = .check_box, .name = "Terminal notifications" },
    .{ .role = .check_box, .name = "Clipboard-copy notification" },
    .{ .role = .check_box, .name = "Config-reload notification" },
    .{ .role = .combo_box, .name = "Auto-update mode" },
    .{ .role = .combo_box, .name = "Auto-update channel" },
    .{ .role = .button, .name = "Keybind configuration" },
    .{ .role = .button, .name = "Full config editor" },
    .{ .role = .button, .name = "Save" },
    .{ .role = .button, .name = "Keep mine" },
    .{ .role = .button, .name = "Use disk" },
    .{ .role = .button, .name = "Save and close" },
    .{ .role = .button, .name = "Discard changes" },
    .{ .role = .button, .name = "Keep editing" },
};
const settings_control_count = settings_control_specs.len;
const settings_mutable_control_count = 25;
// Save, conflict resolution, and dirty-close actions remain fixed in the
// action bar; only the leading content controls are clipped to the viewport.
const settings_header_control_count = 6;
const settings_clipped_control_count = settings_control_count - settings_header_control_count;

const FormItem = struct {
    control_index: usize,
    label_index: ?usize = null,
    checkbox: bool = false,
};
const terminal_form_items = [_]FormItem{
    .{ .control_index = 0, .label_index = 0 },
    .{ .control_index = 1, .label_index = 1 },
    .{ .control_index = 2, .label_index = 2 },
    .{ .control_index = 3, .checkbox = true },
};
const appearance_form_items = [_]FormItem{
    .{ .control_index = 4, .label_index = 3 },
    .{ .control_index = 5, .label_index = 4 },
    .{ .control_index = 6, .label_index = 5 },
    .{ .control_index = 7, .label_index = 6 },
    .{ .control_index = 8, .label_index = 7 },
    .{ .control_index = 9, .label_index = 8 },
    .{ .control_index = 10, .label_index = 9 },
    .{ .control_index = 11, .label_index = 10 },
    .{ .control_index = 12, .label_index = 11 },
    .{ .control_index = 13, .checkbox = true },
};
const shell_form_items = [_]FormItem{
    .{ .control_index = 14, .label_index = 12 },
    .{ .control_index = 15, .label_index = 13 },
};
const privacy_form_items = [_]FormItem{
    .{ .control_index = 16, .label_index = 14 },
    .{ .control_index = 17, .label_index = 15 },
    .{ .control_index = 18, .label_index = 16 },
    .{ .control_index = 19, .label_index = 17 },
    .{ .control_index = 20, .label_index = 18, .checkbox = true },
    .{ .control_index = 21, .checkbox = true },
    .{ .control_index = 22, .checkbox = true },
};
const updates_form_items = [_]FormItem{
    .{ .control_index = 23, .label_index = 19 },
    .{ .control_index = 24, .label_index = 20 },
};
const keybindings_form_items = [_]FormItem{.{ .control_index = 25, .label_index = 21 }};
const advanced_form_items = [_]FormItem{.{ .control_index = 26, .label_index = 22 }};
fn formItemsForSection(section: Section) []const FormItem {
    return switch (section) {
        .terminal => &terminal_form_items,
        .appearance => &appearance_form_items,
        .shell => &shell_form_items,
        .privacy => &privacy_form_items,
        .updates => &updates_form_items,
        .keybindings => &keybindings_form_items,
        .advanced => &advanced_form_items,
    };
}

const settings_max_form_items = appearance_form_items.len;

fn controlIndexIsCheckbox(index: usize) bool {
    for (std.enums.values(Section)) |section| for (formItemsForSection(section)) |item| {
        if (item.control_index == index) return item.checkbox;
    };
    return false;
}

fn labelIndexIsCheckbox(index: usize) bool {
    for (std.enums.values(Section)) |section| for (formItemsForSection(section)) |item| {
        if (item.label_index == index) return item.checkbox;
    };
    return false;
}

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

pub const SaveReloadOutcome = union(enum) {
    completed,
    completed_masked,
    failed: SaveError,
};

pub fn saveReloadOutcome(result: SaveError!void) SaveReloadOutcome {
    result catch |err| return switch (err) {
        error.SavedButMasked => .completed_masked,
        else => .{ .failed = err },
    };
    return .completed;
}

const SettingsThemeAdapter = struct {
    colors: win32_theme.SettingsColors = win32_theme.settingsColors(
        win32_theme.lightTheme(),
        .{
            .window = 0,
            .window_text = 0,
            .button_face = 0,
            .button_text = 0,
            .gray_text = 0,
            .highlight = 0,
            .highlight_text = 0,
        },
        false,
    ),
    window_brush: HBRUSH = null,
    rail_brush: HBRUSH = null,
    edit_brush: HBRUSH = null,
    button_brush: HBRUSH = null,
    applying: bool = false,

    fn deinit(self: *SettingsThemeAdapter) void {
        self.deleteBrushes();
    }

    fn deleteBrushes(self: *SettingsThemeAdapter) void {
        if (self.window_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.rail_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.edit_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.button_brush) |brush| _ = sys.DeleteObject(brush);
        self.window_brush = null;
        self.rail_brush = null;
        self.edit_brush = null;
        self.button_brush = null;
    }

    fn apply(
        self: *SettingsThemeAdapter,
        hwnd: HWND,
        colors: win32_theme.SettingsColors,
    ) void {
        if (self.applying) return;
        self.applying = true;
        defer self.applying = false;
        self.deleteBrushes();
        self.colors = colors;
        self.window_brush = sys.CreateSolidBrush(colors.window_bg);
        self.rail_brush = sys.CreateSolidBrush(colors.rail_bg);
        self.edit_brush = sys.CreateSolidBrush(colors.edit_bg);
        self.button_brush = sys.CreateSolidBrush(colors.button_bg);

        win32_theme.WindowThemeAdapter.applySettings(hwnd, colors);
        applyNativeControlTheme(hwnd, colors);
        _ = sys.EnumChildWindows(
            hwnd,
            applyNativeControlThemeToChild,
            @bitCast(@intFromPtr(&self.colors)),
        );
        _ = sys.InvalidateRect(hwnd, null, 1);
        _ = sys.EnumChildWindows(hwnd, invalidateThemeChild, 0);
    }

    fn controlBrush(self: *const SettingsThemeAdapter, message: UINT) HBRUSH {
        return switch (message) {
            WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX => self.edit_brush,
            WM_CTLCOLORBTN => self.button_brush,
            WM_CTLCOLORMSGBOX, WM_CTLCOLORDLG, WM_CTLCOLORSTATIC => self.window_brush,
            else => null,
        };
    }
};

fn applyNativeControlTheme(hwnd: HWND, colors: win32_theme.SettingsColors) void {
    win32_theme.WindowThemeAdapter.applyNativeControl(hwnd, colors);
}

fn applyNativeControlThemeToChild(hwnd: HWND, lParam: LPARAM) callconv(.winapi) BOOL {
    const colors: *const win32_theme.SettingsColors =
        @ptrFromInt(@as(usize, @bitCast(lParam)));
    applyNativeControlTheme(hwnd, colors.*);
    return 1;
}

fn invalidateThemeChild(hwnd: HWND, _: LPARAM) callconv(.winapi) BOOL {
    _ = sys.InvalidateRect(hwnd, null, 1);
    return 1;
}

fn pointerLresult(pointer: anytype) LRESULT {
    return @bitCast(@intFromPtr(pointer));
}

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
    ownerWindow: ?*const fn (ctx: *anyopaque) ?HWND = null,
    /// Chrome background color (COLORREF) to paint into the settings
    /// content pane. Queried per paint so theme swaps propagate.
    chromeBg: *const fn (ctx: *anyopaque) COLORREF,
    /// Primary text color.
    textPrimary: *const fn (ctx: *anyopaque) COLORREF,
    /// Full resolved app palette and High Contrast state for native Settings
    /// theming. Optional defaults retain compatibility with model-only tests.
    themeColors: ?*const fn (ctx: *anyopaque) win32_theme.ThemeColors = null,
    highContrast: ?*const fn (ctx: *anyopaque) bool = null,
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
    /// Optional monotonic revision of the effective config. When absent, the
    /// settings window maintains a local revision for compatibility.
    configRevision: ?*const fn (ctx: *anyopaque) u64 = null,
    /// Optional live-preview hook for ownership-safe fields. Effects are
    /// idempotent: apply `value` as the current preview for `field`.
    previewField: ?*const fn (ctx: *anyopaque, field: SettingField, value: SettingValue) void = null,
    /// Optional conflict notification. The UI model retains the draft until
    /// `resolveConflict` is called with keep-mine or use-disk.
    notifyConflict: ?*const fn (ctx: *anyopaque, field: SettingField) void = null,
    /// Optional asynchronous two-phase persistence hook. The receiver must
    /// eventually call `SettingsWindow.completeSave` with the same `apply_id`.
    /// When absent, `saveAndReload` remains the synchronous compatibility path.
    requestSave: ?*const fn (
        ctx: *anyopaque,
        pending: *const Config,
        original: *const Config,
        apply_id: ApplyId,
        expected_revision: u64,
    ) void = null,
    /// Fire-and-forget success toast for the app-level in-app stack
    /// (e.g. "Settings saved"). Borrowed title + body — caller must
    /// keep them alive only for the duration of the call; the stack
    /// copies internally.
    notifySuccess: *const fn (ctx: *anyopaque, title: []const u8, body: []const u8) void,
    /// Custom UIA providers touch HWND state and therefore require the UI
    /// thread's confirmed STA initialization. When unavailable, native Win32
    /// providers remain the safe fallback.
    customUiaProvidersEnabled: ?*const fn (ctx: *anyopaque) bool = null,
    /// Queue UIA provider disconnect/release outside synchronous window
    /// teardown. UiaDisconnectProvider may reject COM callouts from
    /// WM_NCDESTROY with RPC_E_CANTCALLOUT_ININPUTSYNCCALL.
    deferUiaDisconnect: ?*const fn (
        ctx: *anyopaque,
        provider_ctx: *anyopaque,
        disconnect: *const fn (*anyopaque) win32_uia.HRESULT,
        release: *const fn (*anyopaque) void,
    ) void = null,
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
    btn_section_privacy: ?HWND = null,
    btn_section_updates: ?HWND = null,
    btn_section_keybindings: ?HWND = null,
    btn_section_advanced: ?HWND = null,
    section_button_prev_proc: ?*const anyopaque = null,
    section_hovered: ?HWND = null,
    section_uia_group: ?*win32_uia.SettingsSectionGroupProvider = null,
    section_uia_providers: [section_count]?*win32_uia.SettingsSectionProvider = [_]?*win32_uia.SettingsSectionProvider{null} ** section_count,
    btn_save: ?HWND = null,
    btn_keybindings_editor: ?HWND = null,
    btn_conflict_keep: ?HWND = null,
    btn_conflict_use_disk: ?HWND = null,
    btn_close_save: ?HWND = null,
    btn_close_discard: ?HWND = null,
    btn_close_keep_editing: ?HWND = null,
    text_header: ?HWND = null,
    text_summary: ?HWND = null,
    text_status: ?HWND = null,
    text_close_prompt: ?HWND = null,
    text_help: ?HWND = null,
    field_labels: [settings_label_specs.len]?HWND = [_]?HWND{null} ** settings_label_specs.len,
    text_uia_prev_proc: ?*const anyopaque = null,
    text_uia_providers: [settings_text_count]?*win32_uia.SettingsControlProvider = [_]?*win32_uia.SettingsControlProvider{null} ** settings_text_count,
    control_uia_prev_procs: [settings_control_count]?*const anyopaque = [_]?*const anyopaque{null} ** settings_control_count,
    control_uia_providers: [settings_control_count]?*win32_uia.SettingsControlProvider = [_]?*win32_uia.SettingsControlProvider{null} ** settings_control_count,
    ui_font: HGDIOBJ = null,
    secondary_font: HGDIOBJ = null,
    emphasis_font: HGDIOBJ = null,
    header_font: HGDIOBJ = null,
    theme_adapter: SettingsThemeAdapter = .{},
    close_prompt_measure_width: i32 = -1,
    close_prompt_measure_dpi: u32 = 0,
    close_prompt_measure_saving: bool = false,
    close_prompt_measure_height: i32 = 0,
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
    dpi: u32 = 96,
    /// Class atom lazily registered the first time `open` runs.
    class_atom: ATOM = 0,

    /// Frozen snapshot of the config at the moment the window last
    /// opened. Independently owned via `Config.clone` so an
    /// external `reload_config` that fires while the window is open
    /// does not mutate our diff baseline. Only valid while
    /// `pending != null`.
    original: ?Config = null,
    /// Latest effective config snapshot used for preview rollback and
    /// three-way external-edit resolution.
    current: ?Config = null,
    /// Editable draft owned by `handle.alloc`. Created on open via a
    /// deep `Config.clone(handle.alloc)` and freed on close/save.
    pending: ?Config = null,
    transaction_storage: [setting_field_count]SettingsTransaction.Entry = undefined,
    transaction: ?SettingsTransaction = null,
    local_revision: u64 = 1,
    save_in_flight: bool = false,
    close_prompt_visible: bool = false,
    close_after_save: bool = false,
    close_posted: bool = false,
    close_notified: bool = false,
    close_prior_focus: ?HWND = null,
    validation_control: ?HWND = null,
    owned_validation_control: ?HWND = null,
    owned_validation_message: ?[]const u8 = null,
    owned_text_changed: [owned_setting_field_count]bool = [_]bool{false} ** owned_setting_field_count,
    owned_dirty: [owned_setting_field_count]bool = [_]bool{false} ** owned_setting_field_count,
    owned_conflict: [owned_setting_field_count]bool = [_]bool{false} ** owned_setting_field_count,
    /// Raw scalar text that has not parsed successfully yet. Keep this
    /// separate from the typed transaction so invalid/empty edits still
    /// participate in dirty-close confirmation and survive config reloads.
    raw_scalar_dirty: [raw_scalar_field_count]bool = [_]bool{false} ** raw_scalar_field_count,
    /// Borrowed static validation messages for each unparsed scalar field.
    raw_scalar_error: [raw_scalar_field_count]?[]const u8 = [_]?[]const u8{null} ** raw_scalar_field_count,
    active_raw_validation: ?RawScalarField = null,
    active_conflict_field: ?SettingField = null,
    active_owned_conflict_field: ?OwnedSettingField = null,
    content_scroll_y: i32 = 0,
    content_scroll_max: i32 = 0,
    proof_viewport_top: i32 = 0,
    proof_viewport_bottom: i32 = 0,
    proof_killfocus_count: u32 = 0,
    proof_redraw_succeeded: bool = false,
    proof_update_pending: bool = false,
    proof_paint_count: u32 = 0,
    proof_layout_redraw_succeeded: bool = false,
    /// Guard flag so the EN_CHANGE handler doesn't fire a cascade
    /// when we programmatically set the EDIT text on open.
    suppress_edit_events: bool = false,

    pub fn init(handle: AppHandle) SettingsWindow {
        return .{ .handle = handle };
    }

    fn canInitializeCustomUiaProviders(self: *const SettingsWindow) bool {
        const enabled = if (self.handle.customUiaProvidersEnabled) |probe|
            probe(self.handle.ctx)
        else
            false;
        return confirmedStaAllowsCustomUiaProviders(enabled);
    }

    fn px(self: *const SettingsWindow, logical: i32) i32 {
        return scaleForDpi(logical, self.dpi);
    }

    fn deleteUiFont(self: *SettingsWindow) void {
        if (self.ui_font) |font| _ = sys.DeleteObject(font);
        self.ui_font = null;
        if (self.secondary_font) |font| _ = DeleteObject(font);
        self.secondary_font = null;
        if (self.emphasis_font) |font| _ = DeleteObject(font);
        self.emphasis_font = null;
        if (self.header_font) |font| _ = DeleteObject(font);
        self.header_font = null;
    }

    pub fn deinit(self: *SettingsWindow) void {
        if (self.hwnd) |h| {
            if (sys.IsWindow(h) != 0) _ = sys.DestroyWindow(h);
        }
        self.releaseSectionUiaProviders();
        self.releaseTextUiaProviders();
        self.releaseControlUiaProviders();
        self.hwnd = null;
        self.deleteUiFont();
        self.theme_adapter.deinit();
        self.btn_open_editor = null;
        self.btn_section_appearance = null;
        self.btn_section_terminal = null;
        self.btn_section_shell = null;
        self.btn_section_privacy = null;
        self.btn_section_updates = null;
        self.btn_section_keybindings = null;
        self.btn_section_advanced = null;
        self.section_button_prev_proc = null;
        self.section_hovered = null;
        self.text_uia_prev_proc = null;
        self.btn_save = null;
        self.btn_keybindings_editor = null;
        self.btn_conflict_keep = null;
        self.btn_conflict_use_disk = null;
        self.btn_close_save = null;
        self.btn_close_discard = null;
        self.btn_close_keep_editing = null;
        self.text_close_prompt = null;
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
        self.resetClosePromptState();
        self.clearPending();
    }

    /// Drop the pending draft (if any) and its arena. Safe to call
    /// multiple times. Called from close paths and after Save so the
    /// next `open` starts with a fresh clone of the (possibly just-
    /// reloaded) app config.
    fn clearPending(self: *SettingsWindow) void {
        if (self.transaction) |*transaction| {
            var effects: [setting_field_count]SettingsTransaction.Effect = undefined;
            if (transaction.dispatch(.revert, &effects)) |emitted| {
                self.dispatchEffects(emitted);
            } else |err| switch (err) {
                // An asynchronous save owns the preview until its completion
                // callback settles the transaction.
                error.ApplyAlreadyPending => {},
                else => std.log.warn("settings: preview rollback failed err={}", .{err}),
            }
        }
        self.transaction = null;
        self.save_in_flight = false;
        self.validation_control = null;
        self.owned_validation_control = null;
        self.owned_validation_message = null;
        self.owned_text_changed = [_]bool{false} ** owned_setting_field_count;
        self.owned_dirty = [_]bool{false} ** owned_setting_field_count;
        self.owned_conflict = [_]bool{false} ** owned_setting_field_count;
        self.raw_scalar_dirty = [_]bool{false} ** raw_scalar_field_count;
        self.raw_scalar_error = [_]?[]const u8{null} ** raw_scalar_field_count;
        self.active_raw_validation = null;
        self.active_conflict_field = null;
        self.active_owned_conflict_field = null;
        if (self.pending) |*p| p.deinit();
        self.pending = null;
        if (self.original) |*o| o.deinit();
        self.original = null;
        if (self.current) |*c| c.deinit();
        self.current = null;
        self.setStatus("");
        self.updateSaveEnabled();
    }

    fn currentRevision(self: *const SettingsWindow) u64 {
        if (self.handle.configRevision) |get_revision| {
            return get_revision(self.handle.ctx);
        }
        return self.local_revision;
    }

    fn initTransaction(self: *SettingsWindow) void {
        const current = self.current orelse return;
        var initial: [setting_field_count]SettingsTransaction.FieldValue = undefined;
        for (std.enums.values(SettingField), 0..) |field, i| {
            initial[i] = .{ .field = field, .value = settingValue(&current, field) };
        }
        self.transaction = SettingsTransaction.init(
            &self.transaction_storage,
            &initial,
            self.currentRevision(),
        ) catch |err| {
            std.log.err("settings: transaction initialization failed err={}", .{err});
            return;
        };
    }

    fn dispatchEffects(self: *SettingsWindow, effects: []const SettingsTransaction.Effect) void {
        for (effects) |effect| switch (effect) {
            .set_preview => |change| if (self.handle.previewField) |preview| {
                preview(self.handle.ctx, change.field, change.value);
            },
            .conflict_detected => |field| if (self.handle.notifyConflict) |notify| {
                notify(self.handle.ctx, field);
            },
            .apply_requested, .persist_field => {},
        };
    }

    fn trackEdit(self: *SettingsWindow, field: SettingField, live_preview: bool) void {
        const pending = self.pending orelse return;
        const transaction = &(self.transaction orelse return);
        var effects: [1]SettingsTransaction.Effect = undefined;
        const emitted = transaction.dispatch(.{ .edit = .{
            .field = field,
            .value = settingValue(&pending, field),
            .live_preview = live_preview,
        } }, &effects) catch |err| {
            std.log.warn("settings: edit transaction failed field={s} err={}", .{ @tagName(field), err });
            return;
        };
        self.dispatchEffects(emitted);
        self.refreshNativeSectionText();
        self.updateSaveEnabled();
    }

    fn hasPendingChanges(self: *const SettingsWindow) bool {
        for (self.raw_scalar_dirty) |dirty| if (dirty) return true;
        for (self.owned_text_changed, self.owned_dirty, self.owned_conflict) |text_changed, dirty, conflict| {
            if (text_changed or dirty or conflict) return true;
        }
        const transaction = &(self.transaction orelse return false);
        for (transaction.entries) |entry| if (entry.dirty or entry.conflict) return true;
        return false;
    }

    fn updateSaveEnabled(self: *SettingsWindow) void {
        const enabled = !self.save_in_flight and
            self.validation_control == null and
            !self.hasRawScalarEdits() and
            self.conflictCount() == 0 and
            self.hasPendingChanges();
        if (self.btn_save) |button| _ = sys.EnableWindow(button, @intFromBool(enabled));
        self.updateClosePromptActions();
    }

    fn hasRawScalarEdits(self: *const SettingsWindow) bool {
        for (self.raw_scalar_dirty) |dirty| if (dirty) return true;
        return false;
    }

    fn markRawScalarEdit(self: *SettingsWindow, field: RawScalarField) void {
        self.raw_scalar_dirty[@intFromEnum(field)] = true;
    }

    fn finishRawScalarEdit(self: *SettingsWindow, field: RawScalarField) void {
        const index = @intFromEnum(field);
        self.raw_scalar_dirty[index] = false;
        self.raw_scalar_error[index] = null;
        if (self.active_raw_validation == field) {
            self.active_raw_validation = null;
            self.surfaceNextValidation(true);
        }
    }

    fn shouldRefreshRawScalar(self: *const SettingsWindow, field: RawScalarField) bool {
        return !self.raw_scalar_dirty[@intFromEnum(field)];
    }

    fn setValidationError(self: *SettingsWindow, control: HWND, message: []const u8) void {
        self.owned_validation_control = control;
        self.owned_validation_message = message;
        self.surfaceNextValidation(false);
    }

    fn clearValidationError(self: *SettingsWindow, control: HWND) void {
        if (self.owned_validation_control != control) return;
        self.owned_validation_control = null;
        self.owned_validation_message = null;
        if (self.validation_control == control) self.surfaceNextValidation(false);
    }

    fn setRawScalarValidationError(
        self: *SettingsWindow,
        field: RawScalarField,
        control: HWND,
        message: []const u8,
    ) void {
        self.raw_scalar_error[@intFromEnum(field)] = message;
        self.active_raw_validation = field;
        self.validation_control = control;
        self.setStatus(message);
        self.updateSaveEnabled();
    }

    fn nextRawScalarValidation(self: *const SettingsWindow) ?RawScalarField {
        if (self.active_raw_validation) |field| {
            if (self.raw_scalar_error[@intFromEnum(field)] != null) return field;
        }
        for (std.enums.values(RawScalarField)) |field| {
            if (self.raw_scalar_error[@intFromEnum(field)] != null) return field;
        }
        return null;
    }

    fn nextStatus(self: *const SettingsWindow) SettingsStatus {
        if (self.nextRawScalarValidation()) |field| return .{ .raw_validation = field };
        if (self.owned_validation_control) |control| return .{ .owned_validation = control };
        if (self.active_conflict_field) |field| return .{ .conflict = field };
        if (self.active_owned_conflict_field) |field| return .{ .owned_conflict = field };
        return .none;
    }

    fn rawScalarDestination(self: *const SettingsWindow, field: RawScalarField) struct { section: Section, hwnd: ?HWND } {
        return switch (field) {
            .scrollback_limit => .{ .section = .terminal, .hwnd = self.edit_scrollback },
            .font_size => .{ .section = .appearance, .hwnd = self.edit_font_size },
            .background_opacity => .{ .section = .appearance, .hwnd = self.edit_bg_opacity },
            .window_padding_x => .{ .section = .appearance, .hwnd = self.edit_pad_x },
            .window_padding_y => .{ .section = .appearance, .hwnd = self.edit_pad_y },
        };
    }

    fn surfaceNextValidation(self: *SettingsWindow, focus: bool) void {
        const visibility_changed = self.syncConflictControls();
        switch (self.nextStatus()) {
            .raw_validation => |field| {
                const destination = self.rawScalarDestination(field);
                self.active_raw_validation = field;
                self.validation_control = destination.hwnd;
                self.setStatus(self.raw_scalar_error[@intFromEnum(field)].?);
                if (focus) if (destination.hwnd) |control| {
                    self.setActiveSection(destination.section);
                    self.ensureControlVisible(control);
                    _ = SetFocus(control);
                };
            },
            .owned_validation => |control| {
                self.active_raw_validation = null;
                self.validation_control = control;
                self.setStatus(self.owned_validation_message orelse "A settings value is invalid.");
                if (focus) {
                    if (self.controlIndex(control)) |index| {
                        if (self.controlSection(index)) |section| self.setActiveSection(section);
                    }
                    self.ensureControlVisible(control);
                    _ = SetFocus(control);
                }
            },
            .conflict => |field| {
                self.active_raw_validation = null;
                self.validation_control = null;
                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{s} also changed on disk. Choose Keep mine or Use disk.", .{@tagName(field)}) catch "A setting also changed on disk.";
                self.setStatus(text);
            },
            .owned_conflict => |field| {
                self.active_raw_validation = null;
                self.validation_control = null;
                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{s} also changed on disk. Choose Keep mine or Use disk.", .{field.label()}) catch "A setting also changed on disk.";
                self.setStatus(text);
            },
            .none => {
                self.active_raw_validation = null;
                self.validation_control = null;
                self.setStatus("");
            },
        }
        self.syncStatusFont();
        if (visibility_changed) layoutChildren(self);
        self.updateSaveEnabled();
    }

    fn markOwnedTextChanged(self: *SettingsWindow, field: OwnedSettingField, control: HWND) void {
        if (self.suppress_edit_events) return;
        self.owned_text_changed[@intFromEnum(field)] = true;
        self.clearValidationError(control);
        self.updateSaveEnabled();
    }

    fn trackOwnedEdit(self: *SettingsWindow, field: OwnedSettingField) void {
        const current = &(self.current orelse return);
        const original = &(self.original orelse return);
        const pending = &(self.pending orelse return);
        const index = @intFromEnum(field);
        self.owned_text_changed[index] = false;

        if (ownedSettingEql(pending, original, field)) {
            self.owned_dirty[index] = false;
            self.owned_conflict[index] = false;
            if (!ownedSettingEql(current, original, field)) {
                copyOwnedSetting(original, current, field) catch |err| {
                    std.log.warn("settings: owned baseline adoption failed field={s} err={}", .{ @tagName(field), err });
                    return;
                };
                copyOwnedSetting(pending, current, field) catch |err| {
                    std.log.warn("settings: owned draft adoption failed field={s} err={}", .{ @tagName(field), err });
                    return;
                };
                self.refreshOwnedControl(field);
            }
        } else if (ownedSettingEql(pending, current, field)) {
            copyOwnedSetting(original, current, field) catch |err| {
                std.log.warn("settings: owned baseline convergence failed field={s} err={}", .{ @tagName(field), err });
                return;
            };
            self.owned_dirty[index] = false;
            self.owned_conflict[index] = false;
        } else {
            self.owned_dirty[index] = true;
            self.owned_conflict[index] = !ownedSettingEql(current, original, field);
        }
        self.surfaceNextValidation(false);
        self.refreshNativeSectionText();
        self.updateSaveEnabled();
    }

    fn refreshOwnedControl(self: *SettingsWindow, field: OwnedSettingField) void {
        switch (field) {
            .font_family => self.displayFontFamilyInEdit(),
            .theme => self.displayThemeInEdit(),
            .command => self.displayCommandInEdit(),
        }
    }

    fn syncOwnedControl(self: *SettingsWindow, field: OwnedSettingField) void {
        switch (field) {
            .font_family => self.syncFontFamilyFromEdit(),
            .theme => self.syncThemeFromEdit(),
            .command => self.syncCommandFromEdit(),
        }
    }

    fn setSaveInFlight(self: *SettingsWindow, in_flight: bool) void {
        if (in_flight and !self.save_in_flight) self.moveFocusBeforeDisablingMutableControls();
        self.save_in_flight = in_flight;
        self.setMutableControlsEnabled(!in_flight);
        if (self.close_prompt_visible and in_flight) {
            self.syncClosePromptText(true);
            layoutChildren(self);
        }
        self.updateSaveEnabled();
    }

    fn mutableControls(self: *const SettingsWindow) [settings_mutable_control_count]?HWND {
        return .{
            self.edit_scrollback,
            self.edit_font_family,
            self.edit_font_size,
            self.edit_theme,
            self.edit_bg_opacity,
            self.edit_command,
            self.edit_pad_x,
            self.edit_pad_y,
            self.combo_confirm_close,
            self.combo_copy_on_select,
            self.combo_window_theme,
            self.combo_shell_integ,
            self.chk_trim_trail,
            self.chk_desktop_notifications,
            self.chk_app_notify_clipboard,
            self.chk_app_notify_config,
            self.combo_clipboard_read,
            self.combo_clipboard_write,
            self.combo_link_url,
            self.combo_link_previews,
            self.combo_cursor_style,
            self.chk_bg_blur,
            self.combo_pad_balance,
            self.combo_auto_update,
            self.combo_auto_update_channel,
        };
    }

    fn moveFocusBeforeDisablingMutableControls(self: *SettingsWindow) void {
        const focused = sys.GetFocus() orelse return;
        var should_move = false;
        for (self.mutableControls()) |control| {
            if (control != null and (control.? == focused or sys.IsChild(control.?, focused) != 0)) {
                should_move = true;
                break;
            }
        }
        if (!should_move) {
            for ([_]?HWND{
                self.btn_save,
                self.btn_close_save,
                self.btn_close_discard,
            }) |control| {
                if (control != null and control.? == focused) {
                    should_move = true;
                    break;
                }
            }
        }
        if (!should_move) return;
        const target = if (self.close_prompt_visible)
            self.btn_close_keep_editing
        else
            self.sectionButton(self.active_section);
        if (target) |hwnd| _ = sys.SetFocus(hwnd);
    }

    fn setMutableControlsEnabled(self: *SettingsWindow, enabled: bool) void {
        for (self.mutableControls()) |control| {
            if (control) |hwnd| _ = sys.EnableWindow(hwnd, @intFromBool(enabled));
        }
    }

    /// Merge a newly-reloaded effective config into the open settings session.
    /// Disjoint disk changes advance both staged baselines; overlapping edits
    /// retain the user's draft and become explicit conflicts.
    pub fn externalConfigChanged(self: *SettingsWindow, config: *const Config, revision: u64) void {
        const transaction = &(self.transaction orelse return);
        for (std.enums.values(OwnedSettingField)) |field| {
            if (self.owned_text_changed[@intFromEnum(field)]) self.syncOwnedControl(field);
        }
        var replacement = config.clone(self.handle.alloc) catch |err| {
            std.log.warn("settings: external config snapshot failed revision={d} err={}", .{ revision, err });
            return;
        };
        var replacement_owned = true;
        defer if (replacement_owned) replacement.deinit();
        var changes: [setting_field_count]SettingsTransaction.FieldValue = undefined;
        for (std.enums.values(SettingField), 0..) |field, i| {
            changes[i] = .{ .field = field, .value = settingValue(&replacement, field) };
        }
        var effects: [setting_field_count]SettingsTransaction.Effect = undefined;
        const emitted = transaction.dispatch(.{ .external_update = .{
            .revision = revision,
            .changes = &changes,
        } }, &effects) catch |err| {
            if (err == error.ApplyAlreadyPending) return;
            std.log.warn("settings: external update rejected revision={d} err={}", .{ revision, err });
            return;
        };
        self.dispatchEffects(emitted);
        if (self.handle.configRevision == null) {
            self.local_revision = @max(self.local_revision, revision);
        }

        const previous_current = &(self.current orelse return);
        const original = &(self.original orelse return);
        const pending = &(self.pending orelse return);
        for (std.enums.values(OwnedSettingField)) |field| {
            if (ownedSettingEql(previous_current, &replacement, field)) continue;
            const index = @intFromEnum(field);
            if (self.owned_dirty[index] or self.owned_text_changed[index]) {
                self.owned_conflict[index] =
                    !ownedSettingEql(original, &replacement, field) and
                    !ownedSettingEql(pending, &replacement, field);
                if (ownedSettingEql(pending, &replacement, field)) {
                    copyOwnedSetting(original, &replacement, field) catch |err| {
                        std.log.warn("settings: failed to advance owned baseline field={s} err={}", .{ @tagName(field), err });
                        continue;
                    };
                    self.owned_dirty[index] = false;
                    self.owned_text_changed[index] = false;
                    self.owned_conflict[index] = false;
                }
            } else {
                copyOwnedSetting(original, &replacement, field) catch |err| {
                    std.log.warn("settings: failed to merge owned baseline field={s} err={}", .{ @tagName(field), err });
                    continue;
                };
                copyOwnedSetting(pending, &replacement, field) catch |err| {
                    std.log.warn("settings: failed to merge owned draft field={s} err={}", .{ @tagName(field), err });
                    continue;
                };
            }
        }

        if (self.current) |*old| old.deinit();
        self.current = replacement;
        replacement_owned = false;

        for (transaction.entries) |entry| {
            if (entry.dirty or entry.conflict) continue;
            setSettingValue(original, entry.current);
            setSettingValue(pending, entry.current);
        }
        if (self.handle.previewField) |preview| {
            for (transaction.entries) |entry| {
                if (entry.dirty and entry.previewed) {
                    preview(self.handle.ctx, entry.field, entry.draft);
                }
            }
        }
        self.refreshAllControls();
        self.surfaceNextValidation(false);
        self.updateSaveEnabled();
    }

    pub fn conflictCount(self: *const SettingsWindow) usize {
        const transaction = &(self.transaction orelse return 0);
        var count = transaction.conflictCount();
        for (self.owned_conflict) |conflict| count += @intFromBool(conflict);
        return count;
    }

    fn pendingDiffText(self: *const SettingsWindow, buf: []u8) []const u8 {
        const transaction = &(self.transaction orelse return "No pending source changes.");
        var writer: std.Io.Writer = .fixed(buf);
        var count: usize = 0;
        for (transaction.entries) |entry| {
            if (!entry.dirty) continue;
            writer.print("{s}: {any} -> {any}\n", .{
                @tagName(entry.field),
                entry.baseline,
                entry.draft,
            }) catch break;
            count += 1;
        }
        if (self.original) |*original| if (self.pending) |*pending| {
            count += writeOwnedSettingDiffs(
                &writer,
                original,
                pending,
                self.owned_dirty,
                self.owned_conflict,
            ) catch 0;
        };
        return if (count == 0) "No pending source changes." else writer.buffered();
    }

    pub fn hasConflict(self: *const SettingsWindow, field: SettingField) bool {
        const transaction = &(self.transaction orelse return false);
        const entry = transaction.entryConst(field) orelse return false;
        return entry.conflict;
    }

    pub fn resolveConflict(
        self: *SettingsWindow,
        field: SettingField,
        resolution: ConflictResolution,
    ) void {
        const transaction = &(self.transaction orelse return);
        var effects: [1]SettingsTransaction.Effect = undefined;
        const emitted = transaction.dispatch(.{ .resolve_conflict = .{
            .field = field,
            .resolution = resolution,
        } }, &effects) catch |err| {
            std.log.warn("settings: conflict resolution failed field={s} err={}", .{ @tagName(field), err });
            return;
        };
        self.dispatchEffects(emitted);
        const entry = transaction.entryConst(field).?;
        if (self.original) |*original| setSettingValue(original, entry.current);
        if (resolution == .use_disk) {
            if (self.pending) |*pending| setSettingValue(pending, entry.current);
            self.refreshAllControls();
        }
        self.updateSaveEnabled();
        self.surfaceNextValidation(false);
    }

    fn syncConflictControls(self: *SettingsWindow) bool {
        const transaction = &(self.transaction orelse return false);
        var next: ?SettingField = null;
        for (transaction.entries) |entry| if (entry.conflict) {
            next = entry.field;
            break;
        };
        self.active_conflict_field = next;
        var next_owned: ?OwnedSettingField = null;
        if (next == null) for (std.enums.values(OwnedSettingField)) |field| {
            if (self.owned_conflict[@intFromEnum(field)]) {
                next_owned = field;
                break;
            }
        };
        self.active_owned_conflict_field = next_owned;
        const focused = sys.GetFocus();
        const conflict_button_focused = focused != null and
            (focused == self.btn_conflict_keep or focused == self.btn_conflict_use_disk);
        const show: i32 = if (!self.close_prompt_visible and (next != null or next_owned != null)) SW_SHOWNORMAL else SW_HIDE;
        const visibility_changed = if (self.btn_conflict_keep) |button|
            (IsWindowVisible(button) != 0) != (show != SW_HIDE)
        else
            false;
        if (self.btn_conflict_keep) |button| _ = ShowWindow(button, show);
        if (self.btn_conflict_use_disk) |button| _ = ShowWindow(button, show);
        if (show == SW_HIDE and conflict_button_focused) self.focusAfterConflictResolution();
        return visibility_changed;
    }

    fn focusAfterConflictResolution(self: *SettingsWindow) void {
        const validation = if (self.validation_control) |control|
            if (sys.IsWindowVisible(control) != 0 and sys.IsWindowEnabled(control) != 0) control else null
        else
            null;
        const save_hwnd = if (self.btn_save) |button|
            if (sys.IsWindowVisible(button) != 0 and sys.IsWindowEnabled(button) != 0) button else null
        else
            null;
        const section = self.sectionButton(self.active_section);
        const target = switch (conflictFocusTarget(validation != null, save_hwnd != null, section != null)) {
            .validation => validation,
            .save => save_hwnd,
            .section => section,
            .none => null,
        };
        if (target) |control| _ = sys.SetFocus(control);
    }

    fn resolveOwnedConflict(self: *SettingsWindow, field: OwnedSettingField, resolution: ConflictResolution) void {
        const index = @intFromEnum(field);
        if (resolution == .keep_mine and self.owned_text_changed[index]) {
            self.syncOwnedControl(field);
            if (self.owned_text_changed[index]) return;
        }
        const current = &(self.current orelse return);
        const original = &(self.original orelse return);
        const pending = &(self.pending orelse return);
        copyOwnedSetting(original, current, field) catch |err| {
            std.log.warn("settings: conflict baseline copy failed field={s} err={}", .{ @tagName(field), err });
            self.setStatus("Could not resolve the settings conflict; your draft is preserved.");
            return;
        };
        if (resolution == .use_disk) {
            copyOwnedSetting(pending, current, field) catch |err| {
                std.log.warn("settings: conflict draft copy failed field={s} err={}", .{ @tagName(field), err });
                self.setStatus("Could not adopt the disk value; your draft is preserved.");
                return;
            };
            self.refreshOwnedControl(field);
        }
        self.owned_text_changed[index] = false;
        self.owned_dirty[index] = !ownedSettingEql(pending, original, field);
        self.owned_conflict[index] = false;
        self.updateSaveEnabled();
        self.surfaceNextValidation(false);
    }

    /// Surface an external-edit conflict inline without stealing focus.
    pub fn promptConflict(self: *SettingsWindow, field: SettingField) void {
        self.active_conflict_field = field;
        self.surfaceNextValidation(false);
        self.updateSaveEnabled();
    }

    /// Null out child HWND references + drop pending. Called from
    /// both WM_CLOSE and WM_NCDESTROY so the next `open()` recreates
    /// fresh children and clones.
    fn clearChildRefs(self: *SettingsWindow) void {
        self.theme_adapter.deinit();
        self.releaseSectionUiaProviders();
        self.releaseTextUiaProviders();
        self.releaseControlUiaProviders();
        self.hwnd = null;
        self.text_header = null;
        self.text_summary = null;
        self.text_status = null;
        self.text_close_prompt = null;
        self.text_help = null;
        self.field_labels = [_]?HWND{null} ** settings_label_specs.len;
        self.deleteUiFont();
        self.btn_open_editor = null;
        self.btn_section_appearance = null;
        self.btn_section_terminal = null;
        self.btn_section_shell = null;
        self.btn_section_privacy = null;
        self.btn_section_updates = null;
        self.btn_section_keybindings = null;
        self.btn_section_advanced = null;
        self.section_button_prev_proc = null;
        self.section_hovered = null;
        self.btn_save = null;
        self.btn_keybindings_editor = null;
        self.btn_conflict_keep = null;
        self.btn_conflict_use_disk = null;
        self.btn_close_save = null;
        self.btn_close_discard = null;
        self.btn_close_keep_editing = null;
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
        self.resetClosePromptState();
        self.clearPending();
    }

    fn releaseSectionUiaProviders(self: *SettingsWindow) void {
        const group = self.section_uia_group;
        self.section_uia_group = null;
        if (group) |provider| provider.detach();
        for (&self.section_uia_providers) |*slot| {
            const provider = slot.* orelse continue;
            slot.* = null;
            provider.detach();
            self.deferProviderDisconnect(
                @ptrCast(provider),
                settingsSectionDisconnect,
                settingsSectionRelease,
            );
        }
        if (group) |provider| {
            self.deferProviderDisconnect(
                @ptrCast(provider),
                settingsSectionGroupDisconnect,
                settingsSectionGroupRelease,
            );
        }
    }

    fn releaseTextUiaProviders(self: *SettingsWindow) void {
        for (&self.text_uia_providers) |*slot| {
            const provider = slot.* orelse continue;
            slot.* = null;
            provider.detach();
            self.deferProviderDisconnect(
                @ptrCast(provider),
                settingsControlDisconnect,
                settingsControlRelease,
            );
        }
    }

    fn textHwnd(self: *const SettingsWindow, index: usize) ?HWND {
        return switch (index) {
            0 => self.text_header,
            1 => self.text_summary,
            2 => self.text_status,
            3 => self.text_close_prompt,
            4 => self.text_help,
            else => if (index - 5 < self.field_labels.len) self.field_labels[index - 5] else null,
        };
    }

    fn textIndex(self: *const SettingsWindow, hwnd: HWND) ?usize {
        for (0..settings_text_count) |index| {
            if (self.textHwnd(index)) |text| {
                if (text == hwnd) return index;
            }
        }
        return null;
    }

    fn initializeTextUiaProviders(self: *SettingsWindow) void {
        self.releaseTextUiaProviders();
        self.text_uia_prev_proc = null;
        if (!self.canInitializeCustomUiaProviders()) return;
        for (0..settings_text_count) |index| {
            const text = self.textHwnd(index) orelse continue;
            const provider = win32_uia.SettingsControlProvider.create(std.heap.page_allocator, text, .text, null) catch |err| {
                std.log.warn("settings text UIA provider unavailable index={} err={}", .{ index, err });
                continue;
            };
            const previous = sys.SetWindowLongPtrW(
                text,
                GWLP_WNDPROC,
                @as(LONG_PTR, @intCast(@intFromPtr(&settingsTextProc))),
            );
            if (previous == 0) {
                _ = win32_uia.SettingsControlProvider.Release(&provider.base);
                continue;
            }
            const proc: *const anyopaque = @ptrFromInt(@as(usize, @intCast(previous)));
            if (self.text_uia_prev_proc) |existing| {
                if (existing != proc) {
                    _ = sys.SetWindowLongPtrW(text, GWLP_WNDPROC, previous);
                    _ = win32_uia.SettingsControlProvider.Release(&provider.base);
                    continue;
                }
            } else {
                self.text_uia_prev_proc = proc;
            }
            self.text_uia_providers[index] = provider;
        }
    }

    fn releaseControlUiaProviders(self: *SettingsWindow) void {
        for (&self.control_uia_providers) |*slot| {
            const provider = slot.* orelse continue;
            slot.* = null;
            provider.detach();
            self.deferProviderDisconnect(
                @ptrCast(provider),
                settingsControlDisconnect,
                settingsControlRelease,
            );
        }
        self.control_uia_prev_procs = [_]?*const anyopaque{null} ** settings_control_count;
    }

    fn deferProviderDisconnect(
        self: *SettingsWindow,
        provider_ctx: *anyopaque,
        disconnect: *const fn (*anyopaque) win32_uia.HRESULT,
        release: *const fn (*anyopaque) void,
    ) void {
        if (self.handle.deferUiaDisconnect) |defer_disconnect| {
            defer_disconnect(self.handle.ctx, provider_ctx, disconnect, release);
            return;
        }
        const hr = disconnect(provider_ctx);
        if (hr != win32_uia.S_OK) {
            std.log.warn("settings UIA immediate disconnect failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
        }
        release(provider_ctx);
    }

    fn controlHwnd(self: *const SettingsWindow, index: usize) ?HWND {
        return switch (index) {
            0 => self.edit_scrollback,
            1 => self.combo_confirm_close,
            2 => self.combo_copy_on_select,
            3 => self.chk_trim_trail,
            4 => self.edit_font_family,
            5 => self.edit_font_size,
            6 => self.edit_theme,
            7 => self.edit_bg_opacity,
            8 => self.combo_window_theme,
            9 => self.combo_cursor_style,
            10 => self.edit_pad_x,
            11 => self.edit_pad_y,
            12 => self.combo_pad_balance,
            13 => self.chk_bg_blur,
            14 => self.edit_command,
            15 => self.combo_shell_integ,
            16 => self.combo_clipboard_read,
            17 => self.combo_clipboard_write,
            18 => self.combo_link_url,
            19 => self.combo_link_previews,
            20 => self.chk_desktop_notifications,
            21 => self.chk_app_notify_clipboard,
            22 => self.chk_app_notify_config,
            23 => self.combo_auto_update,
            24 => self.combo_auto_update_channel,
            25 => self.btn_keybindings_editor,
            26 => self.btn_open_editor,
            27 => self.btn_save,
            28 => self.btn_conflict_keep,
            29 => self.btn_conflict_use_disk,
            30 => self.btn_close_save,
            31 => self.btn_close_discard,
            32 => self.btn_close_keep_editing,
            else => null,
        };
    }

    fn controlIndex(self: *const SettingsWindow, hwnd: HWND) ?usize {
        for (0..settings_control_count) |index| {
            if (self.controlHwnd(index)) |control| {
                if (control == hwnd) return index;
            }
        }
        return null;
    }

    fn formItems(self: *const SettingsWindow) []const FormItem {
        return formItemsForSection(self.active_section);
    }

    fn controlSection(self: *const SettingsWindow, control_index: usize) ?Section {
        _ = self;
        for (std.enums.values(Section)) |section| for (formItemsForSection(section)) |item| {
            if (item.control_index == control_index) return section;
        };
        return null;
    }

    fn initializeControlUiaProviders(self: *SettingsWindow) void {
        self.releaseControlUiaProviders();
        if (!self.canInitializeCustomUiaProviders()) return;
        for (settings_control_specs, 0..) |spec, index| {
            const control = self.controlHwnd(index) orelse continue;
            const provider = win32_uia.SettingsControlProvider.create(
                std.heap.page_allocator,
                control,
                spec.role,
                spec.name,
            ) catch |err| {
                std.log.warn("settings control UIA provider unavailable index={} err={}", .{ index, err });
                continue;
            };
            const previous = sys.SetWindowLongPtrW(
                control,
                GWLP_WNDPROC,
                @as(LONG_PTR, @intCast(@intFromPtr(&settingsControlProc))),
            );
            if (previous == 0) {
                _ = win32_uia.SettingsControlProvider.Release(&provider.base);
                continue;
            }
            self.control_uia_prev_procs[index] = @ptrFromInt(@as(usize, @intCast(previous)));
            self.control_uia_providers[index] = provider;
        }
    }

    fn sectionButton(self: *const SettingsWindow, section: Section) ?HWND {
        return switch (section) {
            .appearance => self.btn_section_appearance,
            .terminal => self.btn_section_terminal,
            .shell => self.btn_section_shell,
            .privacy => self.btn_section_privacy,
            .updates => self.btn_section_updates,
            .keybindings => self.btn_section_keybindings,
            .advanced => self.btn_section_advanced,
        };
    }

    fn sectionProvider(self: *const SettingsWindow, section: Section) ?*win32_uia.SettingsSectionProvider {
        return self.section_uia_providers[@intFromEnum(section)];
    }

    fn sectionForButton(self: *const SettingsWindow, hwnd: HWND) ?Section {
        for (std.enums.values(Section)) |section| {
            if (self.sectionButton(section)) |button| {
                if (button == hwnd) return section;
            }
        }
        return null;
    }

    fn initializeSectionUiaProviders(self: *SettingsWindow) void {
        self.releaseSectionUiaProviders();
        if (!self.canInitializeCustomUiaProviders()) return;
        const parent = self.hwnd orelse return;
        const group = win32_uia.SettingsSectionGroupProvider.create(
            std.heap.page_allocator,
            parent,
        ) catch |err| {
            std.log.warn("settings section UIA group unavailable err={}", .{err});
            return;
        };
        self.section_uia_group = group;
        for (std.enums.values(Section)) |section| {
            const button = self.sectionButton(section) orelse continue;
            const provider = win32_uia.SettingsSectionProvider.create(
                std.heap.page_allocator,
                button,
                section.headerText(),
                @intFromEnum(section),
                group,
            ) catch |err| {
                std.log.warn("settings section UIA provider unavailable section={s} err={}", .{ section.headerText(), err });
                continue;
            };
            self.section_uia_providers[@intFromEnum(section)] = provider;
            group.setSection(@intFromEnum(section), provider);
        }
        group.setSelected(@intFromEnum(self.active_section));
    }

    fn subclassSectionButtons(self: *SettingsWindow) void {
        self.section_button_prev_proc = null;
        for (std.enums.values(Section)) |section| {
            const button = self.sectionButton(section) orelse continue;
            const previous = SetWindowLongPtrW(
                button,
                GWLP_WNDPROC,
                @as(LONG_PTR, @intCast(@intFromPtr(&settingsSectionButtonProc))),
            );
            if (previous == 0) continue;
            const proc: *const anyopaque = @ptrFromInt(@as(usize, @intCast(previous)));
            if (self.section_button_prev_proc) |existing| {
                if (existing != proc) {
                    _ = SetWindowLongPtrW(button, GWLP_WNDPROC, previous);
                    continue;
                }
            } else {
                self.section_button_prev_proc = proc;
            }
        }
    }

    fn setActiveSection(self: *SettingsWindow, next: Section) void {
        const changed = self.active_section != next;
        self.active_section = next;
        if (self.section_uia_group) |group| group.setSelected(@intFromEnum(next));
        self.content_scroll_y = 0;
        self.applySectionVisibility();
        self.refreshNativeSectionText();
        layoutChildren(self);
        if (changed) {
            if (self.sectionProvider(next)) |provider| provider.raiseSelected();
            if (self.hwnd) |h| _ = sys.InvalidateRect(h, null, 1);
        }
    }

    fn setContentScroll(self: *SettingsWindow, next: i32) void {
        const clamped = std.math.clamp(next, 0, self.content_scroll_max);
        if (clamped == self.content_scroll_y) return;
        self.content_scroll_y = clamped;
        layoutChildren(self);
        if (self.hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 1);
    }

    fn refreshNativeSectionText(self: *SettingsWindow) void {
        setWindowTextUtf8(self.text_header, self.active_section.headerText());
        setWindowTextUtf8(self.text_summary, self.active_section.placeholderText());
        var diff_buf: [2048]u8 = undefined;
        const help = switch (self.active_section) {
            .keybindings => keybindingsHelpText(),
            .advanced => self.pendingDiffText(&diff_buf),
            else => "",
        };
        setWindowTextUtf8(self.text_help, help);
    }

    fn setStatus(self: *SettingsWindow, text: []const u8) void {
        const status = self.text_status orelse return;
        if (!setWindowTextUtf8IfChanged(status, text)) return;
        sys.NotifyWinEvent(EVENT_OBJECT_NAMECHANGE, status, @bitCast(OBJID_CLIENT), @bitCast(CHILDID_SELF));
    }

    fn recreateUiFont(self: *SettingsWindow) void {
        const hwnd = self.hwnd orelse return;
        const variable_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Variable Text");
        const fallback_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        const face = if (fontFaceAvailable(hwnd, variable_face)) variable_face else fallback_face;
        const next = createSettingsFont(self.dpi, 13, 400, face) orelse return;
        const next_secondary = createSettingsFont(self.dpi, 12, 400, face) orelse {
            _ = DeleteObject(next);
            return;
        };
        const next_emphasis = createSettingsFont(self.dpi, 13, 600, face) orelse {
            _ = DeleteObject(next_secondary);
            _ = DeleteObject(next);
            return;
        };
        const next_header = createSettingsFont(self.dpi, 16, 600, face) orelse {
            _ = DeleteObject(next_emphasis);
            _ = DeleteObject(next_secondary);
            _ = DeleteObject(next);
            return;
        };
        const previous = self.ui_font;
        const previous_secondary = self.secondary_font;
        const previous_emphasis = self.emphasis_font;
        const previous_header = self.header_font;
        self.ui_font = next;
        self.secondary_font = next_secondary;
        self.emphasis_font = next_emphasis;
        self.header_font = next_header;
        self.close_prompt_measure_width = -1;
        self.close_prompt_measure_height = 0;
        _ = EnumChildWindows(hwnd, applyChildFont, @bitCast(@intFromPtr(next)));
        if (self.text_header) |header| _ = SendMessageW(header, WM_SETFONT, @intFromPtr(next_header), 1);
        if (self.text_summary) |text| _ = SendMessageW(text, WM_SETFONT, @intFromPtr(next_secondary), 1);
        for (self.field_labels) |label| {
            if (label) |control| _ = SendMessageW(control, WM_SETFONT, @intFromPtr(next_secondary), 1);
        }
        for (0..settings_clipped_control_count) |index| if (controlIndexIsCheckbox(index)) {
            if (self.controlHwnd(index)) |control| _ = SendMessageW(control, WM_SETFONT, @intFromPtr(next_secondary), 1);
        };
        if (self.text_close_prompt) |prompt| _ = SendMessageW(prompt, WM_SETFONT, @intFromPtr(next_emphasis), 1);
        self.syncStatusFont();
        if (previous) |font| _ = DeleteObject(font);
        if (previous_secondary) |font| _ = DeleteObject(font);
        if (previous_emphasis) |font| _ = DeleteObject(font);
        if (previous_header) |font| _ = DeleteObject(font);
        self.updateComboMetrics();
    }

    fn syncStatusFont(self: *SettingsWindow) void {
        const status = self.text_status orelse return;
        const font = switch (self.nextStatus()) {
            .conflict, .owned_conflict => self.emphasis_font,
            .raw_validation, .owned_validation, .none => self.secondary_font,
        };
        if (font) |value| {
            const current: LRESULT = @bitCast(@intFromPtr(value));
            if (SendMessageW(status, WM_GETFONT, 0, 0) != current) {
                _ = SendMessageW(status, WM_SETFONT, @intFromPtr(value), 1);
            }
        }
    }

    fn comboControls(self: *const SettingsWindow) [12]?HWND {
        return .{
            self.combo_confirm_close,
            self.combo_copy_on_select,
            self.combo_window_theme,
            self.combo_shell_integ,
            self.combo_clipboard_read,
            self.combo_clipboard_write,
            self.combo_link_url,
            self.combo_link_previews,
            self.combo_cursor_style,
            self.combo_pad_balance,
            self.combo_auto_update,
            self.combo_auto_update_channel,
        };
    }

    fn updateComboMetrics(self: *SettingsWindow) void {
        const field_height: LPARAM = self.px(settings_control_height);
        const item_height: LPARAM = self.px(settings_combo_item_height);
        for (self.comboControls()) |combo| if (combo) |control| {
            _ = SendMessageW(control, CB_SETITEMHEIGHT, std.math.maxInt(WPARAM), field_height);
            _ = SendMessageW(control, CB_SETITEMHEIGHT, 0, item_height);
            win32_theme.WindowThemeAdapter.applyNativeCombo(control, self.theme_adapter.colors);
        };
    }

    pub fn themeChanged(self: *SettingsWindow) void {
        if (self.hwnd) |hwnd| {
            self.theme_adapter.apply(hwnd, self.resolveThemeColors());
        }
        self.recreateUiFont();
        layoutChildren(self);
        if (self.hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 1);
    }

    fn resolveThemeColors(self: *const SettingsWindow) win32_theme.SettingsColors {
        var theme = if (self.handle.themeColors) |resolve|
            resolve(self.handle.ctx)
        else
            win32_theme.lightTheme();
        if (self.handle.themeColors == null) {
            theme.chrome_bg = self.handle.chromeBg(self.handle.ctx);
            theme.text_primary = self.handle.textPrimary(self.handle.ctx);
        }
        const high_contrast = if (self.handle.highContrast) |probe|
            probe(self.handle.ctx)
        else
            false;
        return win32_theme.settingsColors(
            theme,
            .{
                .window = GetSysColor(COLOR_WINDOW),
                .window_text = GetSysColor(COLOR_WINDOWTEXT),
                .button_face = GetSysColor(COLOR_BTNFACE),
                .button_text = GetSysColor(COLOR_BTNTEXT),
                .gray_text = GetSysColor(COLOR_GRAYTEXT),
                .highlight = GetSysColor(COLOR_HIGHLIGHT),
                .highlight_text = GetSysColor(COLOR_HIGHLIGHTTEXT),
            },
            high_contrast,
        );
    }

    fn ensureControlVisible(self: *SettingsWindow, control: HWND) void {
        var is_form_control = false;
        for (self.formItems()) |item| {
            if (self.controlHwnd(item.control_index) == control) {
                is_form_control = true;
                break;
            }
        }
        if (!is_form_control) return;
        const hwnd = self.hwnd orelse return;
        var child_rect: RECT = undefined;
        var client_rect: RECT = undefined;
        if (sys.GetWindowRect(control, &child_rect) == 0 or
            sys.GetClientRect(hwnd, &client_rect) == 0) return;
        var child_origin: POINT = .{ .x = child_rect.left, .y = child_rect.top };
        if (sys.ScreenToClient(hwnd, &child_origin) == 0) return;
        const top = child_origin.y;
        const bottom = top + child_rect.bottom - child_rect.top;
        const viewport_top = settingsContentViewportTop(self, client_rect);
        const viewport_bottom = settingsContentViewportBottom(self, client_rect);
        if (top < viewport_top) {
            self.setContentScroll(self.content_scroll_y - (viewport_top - top));
        } else if (bottom > viewport_bottom) {
            self.setContentScroll(self.content_scroll_y + (bottom - viewport_bottom));
        }
    }

    fn applySectionVisibility(self: *SettingsWindow) void {
        for (std.enums.values(Section)) |section| {
            if (self.sectionButton(section)) |button| {
                _ = sys.SendMessageW(
                    button,
                    BM_SETCHECK,
                    if (section == self.active_section) BST_CHECKED else BST_UNCHECKED,
                    0,
                );
                const style: u32 = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(button, GWL_STYLE))));
                const next_style = if (section == self.active_section) style | WS_TABSTOP else style & ~WS_TABSTOP;
                if (next_style != style) _ = sys.SetWindowLongPtrW(button, GWL_STYLE, @intCast(next_style));
            }
        }
        for (0..settings_clipped_control_count) |index| if (self.controlHwnd(index)) |control| {
            _ = ShowWindow(control, SW_HIDE);
        };
        for (self.field_labels) |label| {
            if (label) |control| _ = ShowWindow(control, SW_HIDE);
        }
        for (self.formItems()) |item| {
            if (self.controlHwnd(item.control_index)) |control| _ = ShowWindow(control, SW_SHOWNORMAL);
            if (item.label_index) |index| {
                if (self.field_labels[index]) |label| _ = ShowWindow(label, SW_SHOWNORMAL);
            }
        }
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
        self.markRawScalarEdit(.scrollback_limit);

        var buf_w: [32]u16 = undefined;
        const n = sys.GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
        if (n <= 0) return self.setRawScalarValidationError(.scrollback_limit, edit, "Scrollback limit is required.");
        var utf8_buf: [64]u8 = undefined;
        const utf8 = std.unicode.utf16LeToUtf8(&utf8_buf, buf_w[0..@intCast(n)]) catch
            return self.setRawScalarValidationError(.scrollback_limit, edit, "Scrollback limit contains invalid text.");
        const trimmed = std.mem.trim(u8, utf8_buf[0..utf8], " \t");
        if (trimmed.len == 0) return self.setRawScalarValidationError(.scrollback_limit, edit, "Scrollback limit is required.");
        const parsed = std.fmt.parseInt(usize, trimmed, 10) catch
            return self.setRawScalarValidationError(.scrollback_limit, edit, "Scrollback limit must be a non-negative whole number.");
        self.finishRawScalarEdit(.scrollback_limit);
        p.*.@"scrollback-limit" = parsed;
        self.trackEdit(.scrollback_limit, false);
    }

    fn displayScrollbackInEdit(self: *SettingsWindow) void {
        if (!self.shouldRefreshRawScalar(.scrollback_limit)) return;
        const edit = self.edit_scrollback orelse return;
        const p = self.pending orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d}", .{p.@"scrollback-limit"}) catch return;
        var buf_w: [32]u16 = undefined;
        const w = utf8ToW(&buf_w, text);
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
        self.suppress_edit_events = false;
    }

    fn syncFontFamilyFromEdit(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const arena = p.*._arena.?.allocator();
        const edit = self.edit_font_family orelse return;
        var text_buf: [edit_text_max_utf8]u8 = undefined;
        const text = readEditUtf8(edit, &text_buf) orelse
            return self.setValidationError(edit, "Font family text could not be read.");
        p.*.@"font-family" = parseFontFamilyEditText(arena, text) catch
            return self.setValidationError(edit, "Font family list is invalid.");
        self.clearValidationError(edit);
        self.trackOwnedEdit(.font_family);
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
        self.markRawScalarEdit(.font_size);
        var buf_w: [32]u16 = undefined;
        const n = sys.GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
        if (n <= 0) return self.setRawScalarValidationError(.font_size, edit, "Font size is required.");
        var utf8_buf: [64]u8 = undefined;
        const utf8 = std.unicode.utf16LeToUtf8(&utf8_buf, buf_w[0..@intCast(n)]) catch
            return self.setRawScalarValidationError(.font_size, edit, "Font size contains invalid text.");
        const trimmed = std.mem.trim(u8, utf8_buf[0..utf8], " \t");
        if (trimmed.len == 0) return self.setRawScalarValidationError(.font_size, edit, "Font size is required.");
        const parsed = std.fmt.parseFloat(f32, trimmed) catch
            return self.setRawScalarValidationError(.font_size, edit, "Font size must be a number from 6 through 72.");
        // Range-clamp: Ghostty Config default is 12 pt; our range is
        // the same the GUI spinner catalogue will offer (6..72).
        if (parsed < 6.0 or parsed > 72.0) return self.setRawScalarValidationError(.font_size, edit, "Font size must be from 6 through 72 points.");
        self.finishRawScalarEdit(.font_size);
        p.*.@"font-size" = parsed;
        self.trackEdit(.font_size, true);
    }

    fn displayFontSizeInEdit(self: *SettingsWindow) void {
        if (!self.shouldRefreshRawScalar(.font_size)) return;
        const edit = self.edit_font_size orelse return;
        const p = self.pending orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.1}", .{p.@"font-size"}) catch return;
        var buf_w: [32]u16 = undefined;
        const w = utf8ToW(&buf_w, text);
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
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
            self.clearValidationError(edit);
            self.trackOwnedEdit(.theme);
            return;
        }
        var theme: Config.Theme = undefined;
        theme.parseCLI(arena, trimmed) catch
            return self.setValidationError(edit, "Terminal theme must be a valid name, path, or light/dark pair.");
        p.*.theme = theme;
        self.clearValidationError(edit);
        self.trackOwnedEdit(.theme);
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
        self.markRawScalarEdit(.background_opacity);
        var buf_w: [32]u16 = undefined;
        const n = sys.GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
        if (n <= 0) return self.setRawScalarValidationError(.background_opacity, edit, "Background opacity is required.");
        var utf8_buf: [64]u8 = undefined;
        const utf8 = std.unicode.utf16LeToUtf8(&utf8_buf, buf_w[0..@intCast(n)]) catch
            return self.setRawScalarValidationError(.background_opacity, edit, "Background opacity contains invalid text.");
        const trimmed = std.mem.trim(u8, utf8_buf[0..utf8], " \t");
        if (trimmed.len == 0) return self.setRawScalarValidationError(.background_opacity, edit, "Background opacity is required.");
        const parsed = std.fmt.parseFloat(f64, trimmed) catch
            return self.setRawScalarValidationError(.background_opacity, edit, "Background opacity must be a number from 0 through 1.");
        if (parsed < 0.0 or parsed > 1.0) return self.setRawScalarValidationError(.background_opacity, edit, "Background opacity must be from 0 through 1.");
        self.finishRawScalarEdit(.background_opacity);
        p.*.@"background-opacity" = parsed;
        self.trackEdit(.background_opacity, true);
    }

    fn displayBgOpacityInEdit(self: *SettingsWindow) void {
        if (!self.shouldRefreshRawScalar(.background_opacity)) return;
        const edit = self.edit_bg_opacity orelse return;
        const p = self.pending orelse return;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d:.2}", .{p.@"background-opacity"}) catch return;
        var buf_w: [32]u16 = undefined;
        const w = utf8ToW(&buf_w, text);
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
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
            self.clearValidationError(edit);
            self.trackOwnedEdit(.command);
            return;
        }
        var command: Config.Command = undefined;
        command.parseCLI(arena, trimmed) catch
            return self.setValidationError(edit, "Default command syntax is invalid.");
        p.*.command = command;
        self.clearValidationError(edit);
        self.trackOwnedEdit(.command);
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
        const raw_field: RawScalarField = switch (axis) {
            .x => .window_padding_x,
            .y => .window_padding_y,
        };
        const edit = switch (axis) {
            .x => self.edit_pad_x,
            .y => self.edit_pad_y,
        } orelse return;
        self.markRawScalarEdit(raw_field);
        var text_buf: [64]u8 = undefined;
        const text = readEditUtf8(edit, &text_buf) orelse
            return self.setRawScalarValidationError(raw_field, edit, switch (axis) {
                .x => "Window padding X could not be read.",
                .y => "Window padding Y could not be read.",
            });
        const parsed = Config.WindowPadding.parseCLI(std.mem.trim(u8, text, " \t")) catch
            return self.setRawScalarValidationError(raw_field, edit, switch (axis) {
                .x => "Window padding X must be one number or a comma-separated pair.",
                .y => "Window padding Y must be one number or a comma-separated pair.",
            });
        self.finishRawScalarEdit(raw_field);
        switch (axis) {
            .x => {
                p.*.@"window-padding-x" = parsed;
                self.trackEdit(.window_padding_x, true);
            },
            .y => {
                p.*.@"window-padding-y" = parsed;
                self.trackEdit(.window_padding_y, true);
            },
        }
    }

    fn displayPaddingInEdit(self: *SettingsWindow, axis: PaddingAxis) void {
        const raw_field: RawScalarField = switch (axis) {
            .x => .window_padding_x,
            .y => .window_padding_y,
        };
        if (!self.shouldRefreshRawScalar(raw_field)) return;
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
        const state = sys.SendMessageW(chk, BM_GETCHECK, 0, 0);
        p.*.@"clipboard-trim-trailing-spaces" = (state == BST_CHECKED);
        self.trackEdit(.trim_trailing_spaces, false);
    }

    fn displayTrimTrailInCheckbox(self: *SettingsWindow) void {
        const chk = self.chk_trim_trail orelse return;
        const p = self.pending orelse return;
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(
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
        p.*.@"desktop-notifications" = sys.SendMessageW(chk, BM_GETCHECK, 0, 0) == BST_CHECKED;
        self.trackEdit(.desktop_notifications, false);
    }

    fn displayDesktopNotificationsInCheckbox(self: *SettingsWindow) void {
        const chk = self.chk_desktop_notifications orelse return;
        const p = self.pending orelse return;
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(
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
        const enabled = sys.SendMessageW(chk, BM_GETCHECK, 0, 0) == BST_CHECKED;
        switch (field) {
            .clipboard => {
                p.*.@"app-notifications".@"clipboard-copy" = enabled;
                self.trackEdit(.app_notify_clipboard, false);
            },
            .config => {
                p.*.@"app-notifications".@"config-reload" = enabled;
                self.trackEdit(.app_notify_config, false);
            },
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
        _ = sys.SendMessageW(chk, BM_SETCHECK, if (enabled) BST_CHECKED else BST_UNCHECKED, 0);
        self.suppress_edit_events = false;
    }

    /// Enum combo helpers. `fromIndex` maps combobox selection to
    /// config enum value; `toIndex` goes the other direction for
    /// initial display.
    fn syncConfirmCloseFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_confirm_close orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"confirm-close-surface" = switch (idx) {
            0 => .false,
            1 => .true,
            2 => .always,
            else => return,
        };
        self.trackEdit(.confirm_close, false);
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
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncCopyOnSelectFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_copy_on_select orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"copy-on-select" = switch (idx) {
            0 => .false,
            1 => .true,
            2 => .clipboard,
            else => return,
        };
        self.trackEdit(.copy_on_select, false);
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
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncClipboardAccessFromCombo(self: *SettingsWindow, comptime field_name: []const u8, combo_opt: ?HWND) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = combo_opt orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        @field(p.*, field_name) = clipboardAccessFromComboIndex(idx) orelse return;
        if (comptime std.mem.eql(u8, field_name, "clipboard-read")) {
            self.trackEdit(.clipboard_read, false);
        } else if (comptime std.mem.eql(u8, field_name, "clipboard-write")) {
            self.trackEdit(.clipboard_write, false);
        }
    }

    fn displayClipboardAccessInCombo(self: *SettingsWindow, comptime field_name: []const u8, combo_opt: ?HWND) void {
        const combo = combo_opt orelse return;
        const p = self.pending orelse return;
        const idx = comboIndexFromClipboardAccess(@field(p, field_name));
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncLinkUrlFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_link_url orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"link-url" = linkUrlFromComboIndex(idx) orelse return;
        self.trackEdit(.link_url, false);
    }

    fn displayLinkUrlInCombo(self: *SettingsWindow) void {
        const combo = self.combo_link_url orelse return;
        const p = self.pending orelse return;
        const idx = comboIndexFromLinkUrl(p.@"link-url");
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncLinkPreviewsFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_link_previews orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"link-previews" = linkPreviewsFromComboIndex(idx) orelse return;
        self.trackEdit(.link_previews, false);
    }

    fn displayLinkPreviewsInCombo(self: *SettingsWindow) void {
        const combo = self.combo_link_previews orelse return;
        const p = self.pending orelse return;
        const idx = comboIndexFromLinkPreviews(p.@"link-previews");
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncWindowThemeFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_window_theme orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"window-theme" = switch (idx) {
            0 => .auto,
            1 => .system,
            2 => .light,
            3 => .dark,
            4 => .ghostty,
            else => return,
        };
        self.trackEdit(.window_theme, true);
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
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncShellIntegFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_shell_integ orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
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
        self.trackEdit(.shell_integration, false);
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
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncCursorStyleFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_cursor_style orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"cursor-style" = switch (idx) {
            0 => .bar,
            1 => .block,
            2 => .underline,
            3 => .block_hollow,
            else => return,
        };
        self.trackEdit(.cursor_style, true);
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
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    /// background-blur is a union (false / true / { radius: u8 }). The
    /// GUI exposes only the boolean path, so keep an existing numeric
    /// radius intact while the checkbox remains enabled.
    fn syncBgBlurFromCheckbox(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const chk = self.chk_bg_blur orelse return;
        const state = sys.SendMessageW(chk, BM_GETCHECK, 0, 0);
        p.*.@"background-blur" = backgroundBlurFromCheckbox(
            p.*.@"background-blur",
            state == BST_CHECKED,
        );
        self.trackEdit(.background_blur, true);
    }

    fn displayBgBlurInCheckbox(self: *SettingsWindow) void {
        const chk = self.chk_bg_blur orelse return;
        const p = self.pending orelse return;
        const enabled = p.@"background-blur".win32SystemBackdropEnabled();
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(
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
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"window-padding-balance" = switch (idx) {
            0 => .false,
            1 => .true,
            2 => .equal,
            else => return,
        };
        self.trackEdit(.padding_balance, true);
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
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncAutoUpdateFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_auto_update orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"auto-update" = switch (idx) {
            0 => null,
            1 => .off,
            2 => .check,
            3 => .download,
            else => return,
        };
        self.trackEdit(.auto_update, false);
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
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    fn syncAutoUpdateChannelFromCombo(self: *SettingsWindow) void {
        if (self.suppress_edit_events) return;
        const p = &(self.pending orelse return);
        const combo = self.combo_auto_update_channel orelse return;
        const idx = sys.SendMessageW(combo, CB_GETCURSEL, 0, 0);
        if (idx < 0) return;
        p.*.@"auto-update-channel" = switch (idx) {
            0 => null,
            1 => .stable,
            2 => .tip,
            else => return,
        };
        self.trackEdit(.auto_update_channel, false);
    }

    fn displayAutoUpdateChannelInCombo(self: *SettingsWindow) void {
        const combo = self.combo_auto_update_channel orelse return;
        const p = self.pending orelse return;
        const idx: usize = if (p.@"auto-update-channel") |value| switch (value) {
            .stable => 1,
            .tip => 2,
        } else 0;
        self.suppress_edit_events = true;
        _ = sys.SendMessageW(combo, CB_SETCURSEL, idx, 0);
        self.suppress_edit_events = false;
    }

    /// Refresh every control from the pending draft. Called after
    /// `adoptCurrentConfig` and after a successful save.
    fn refreshAllControls(self: *SettingsWindow) void {
        self.displayScrollbackInEdit();
        if (!self.owned_text_changed[@intFromEnum(OwnedSettingField.font_family)]) self.displayFontFamilyInEdit();
        self.displayFontSizeInEdit();
        if (!self.owned_text_changed[@intFromEnum(OwnedSettingField.theme)]) self.displayThemeInEdit();
        self.displayBgOpacityInEdit();
        if (!self.owned_text_changed[@intFromEnum(OwnedSettingField.command)]) self.displayCommandInEdit();
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
        self.updateSaveEnabled();
    }

    fn save(self: *SettingsWindow) void {
        self.syncScrollbackFromEdit();
        self.syncFontFamilyFromEdit();
        self.syncFontSizeFromEdit();
        self.syncThemeFromEdit();
        self.syncBgOpacityFromEdit();
        self.syncCommandFromEdit();
        self.syncPaddingFromEdit(.x);
        self.syncPaddingFromEdit(.y);
        if (self.validation_control) |control| {
            _ = sys.SetFocus(control);
            self.ensureControlVisible(control);
            return;
        }
        if (self.conflictCount() != 0) {
            self.surfaceNextValidation(false);
            return;
        }
        const p = self.pending orelse return;
        const o = self.original orelse return;

        var apply_id: ?ApplyId = null;
        var expected_revision: u64 = self.currentRevision();
        if (self.transaction) |*transaction| {
            var effects: [setting_field_count + 1]SettingsTransaction.Effect = undefined;
            const emitted = transaction.dispatch(.apply, &effects) catch |err| {
                std.log.warn("settings: save transaction rejected err={}; draft preserved", .{err});
                self.setStatus("Resolve settings conflicts or invalid fields before saving.");
                return;
            };
            for (emitted) |effect| switch (effect) {
                .apply_requested => |request| {
                    apply_id = request.apply_id;
                    expected_revision = request.expected_current_revision;
                },
                .set_preview, .conflict_detected, .persist_field => {},
            };
        }

        if (apply_id) |id| if (self.handle.requestSave) |request_save| {
            // Config pointers are borrowed for the callback duration. An
            // asynchronous implementation must take its own snapshots before
            // returning, then report completion with this token.
            self.setSaveInFlight(true);
            request_save(self.handle.ctx, &p, &o, id, expected_revision);
            return;
        };

        switch (saveReloadOutcome(self.handle.saveAndReload(self.handle.ctx, &p, &o))) {
            .completed => self.completeSynchronousSave(apply_id, false),
            .completed_masked => {
                // Persisted bytes are correct but a later config
                // layer is masking one or more edits. Same baseline
                // refresh as success since the file IS written.
                // The toast copy tells the user the bytes made it
                // to disk but the effective value differs.
                self.completeSynchronousSave(apply_id, true);
            },
            .failed => |err| {
                // Write failed. DO NOT discard `pending` — the user's
                // edits are still in memory; losing them on every
                // transient disk error (permission denied, sharing
                // violation when another editor has the file open)
                // would be destructive. Leave `pending` alone so
                // the user can retry Save once the underlying issue
                // is fixed, or close the window to discard.
                if (apply_id) |id| if (!self.failApply(id)) return;
                std.log.warn("settings: save failed err={}; draft preserved", .{err});
                self.setStatus("Save failed. Your edits are preserved; check permissions or another editor and retry.");
                self.updateSaveEnabled();
            },
        }
    }

    fn resetClosePromptState(self: *SettingsWindow) void {
        self.close_prompt_visible = false;
        self.close_after_save = false;
        self.close_posted = false;
        self.close_prior_focus = null;
    }

    fn updateClosePromptActions(self: *SettingsWindow) void {
        const actions = closePromptActions(self.close_prompt_visible, self.save_in_flight, self.close_posted);
        if (self.btn_close_save) |button| _ = sys.EnableWindow(button, @intFromBool(actions.save));
        if (self.btn_close_discard) |button| _ = sys.EnableWindow(button, @intFromBool(actions.discard));
        if (self.btn_close_keep_editing) |button| {
            _ = sys.EnableWindow(button, @intFromBool(actions.keep_editing));
        }
    }

    fn syncClosePromptText(self: *SettingsWindow, announce: bool) void {
        const text = self.text_close_prompt orelse return;
        setWindowTextUtf8(text, closePromptText(self.save_in_flight));
        if (announce) {
            sys.NotifyWinEvent(EVENT_OBJECT_NAMECHANGE, text, @bitCast(OBJID_CLIENT), @bitCast(CHILDID_SELF));
        }
    }

    fn showClosePrompt(self: *SettingsWindow) void {
        if (self.close_prompt_visible) {
            if (self.btn_close_keep_editing) |button| _ = sys.SetFocus(button);
            return;
        }
        self.close_prompt_visible = true;
        // A close request made while persistence is already in flight still
        // carries close intent. The prompt remains visible so the user can
        // keep editing, but successful completion must honor the request.
        self.close_after_save = self.save_in_flight;
        self.close_prior_focus = sys.GetFocus();
        if (self.text_status) |text| _ = sys.ShowWindow(text, SW_HIDE);
        if (self.btn_conflict_keep) |button| _ = sys.ShowWindow(button, SW_HIDE);
        if (self.btn_conflict_use_disk) |button| _ = sys.ShowWindow(button, SW_HIDE);
        if (self.btn_save) |button| _ = sys.ShowWindow(button, SW_HIDE);
        if (self.text_close_prompt) |text| _ = sys.ShowWindow(text, SW_SHOWNORMAL);
        if (self.btn_close_save) |button| _ = sys.ShowWindow(button, SW_SHOWNORMAL);
        if (self.btn_close_discard) |button| _ = sys.ShowWindow(button, SW_SHOWNORMAL);
        if (self.btn_close_keep_editing) |button| _ = sys.ShowWindow(button, SW_SHOWNORMAL);
        self.syncClosePromptText(true);
        self.updateClosePromptActions();
        layoutChildren(self);
        // Conservative default: closing must never be the result of an
        // accidental Enter after the window-close gesture.
        if (self.btn_close_keep_editing) |button| _ = sys.SetFocus(button);
    }

    fn cancelClosePrompt(self: *SettingsWindow) void {
        if (!closePromptCanCancel(self.close_prompt_visible, self.close_posted)) return;
        const prior_focus = self.close_prior_focus;
        self.close_prompt_visible = false;
        self.close_after_save = false;
        self.close_prior_focus = null;
        if (self.text_close_prompt) |text| _ = ShowWindow(text, SW_HIDE);
        if (self.btn_close_save) |button| _ = ShowWindow(button, SW_HIDE);
        if (self.btn_close_discard) |button| _ = ShowWindow(button, SW_HIDE);
        if (self.btn_close_keep_editing) |button| _ = ShowWindow(button, SW_HIDE);
        if (self.text_status) |text| _ = ShowWindow(text, SW_SHOWNORMAL);
        if (self.btn_save) |button| _ = ShowWindow(button, SW_SHOWNORMAL);
        _ = self.syncConflictControls();
        self.updateSaveEnabled();
        layoutChildren(self);

        if (prior_focus) |control| {
            const belongs_to_settings = if (self.hwnd) |settings_hwnd|
                control == settings_hwnd or sys.IsChild(settings_hwnd, control) != 0
            else
                false;
            if (belongs_to_settings and sys.IsWindow(control) != 0 and sys.IsWindowVisible(control) != 0 and sys.IsWindowEnabled(control) != 0) {
                _ = sys.SetFocus(control);
                return;
            }
        }
        if (self.sectionButton(self.active_section)) |button| _ = sys.SetFocus(button);
    }

    fn saveAndClose(self: *SettingsWindow) void {
        if (!self.close_prompt_visible or self.save_in_flight or self.close_posted) return;
        self.close_after_save = true;
        self.save();
        if (self.save_in_flight or self.close_posted) {
            self.updateClosePromptActions();
            return;
        }
        if (!self.hasPendingChanges()) {
            self.postCloseNow();
            return;
        }
        // Validation, a conflict, or synchronous persistence failure needs
        // the normal inline status and its owning control to be visible.
        self.cancelClosePrompt();
        if (self.validation_control != null or self.conflictCount() != 0) {
            self.surfaceNextValidation(true);
        }
    }

    fn discardAndClose(self: *SettingsWindow) void {
        if (!self.close_prompt_visible or self.save_in_flight or self.close_posted) return;
        self.close_after_save = false;
        self.postCloseNow();
    }

    fn postCloseNow(self: *SettingsWindow) void {
        if (self.close_posted or self.close_notified) return;
        const hwnd = self.hwnd orelse return;
        self.close_posted = true;
        self.updateClosePromptActions();
        if (sys.PostMessageW(hwnd, WM_SETTINGS_CLOSE_NOW, 0, 0) == 0) {
            self.close_posted = false;
            self.updateClosePromptActions();
            self.setStatus("Could not close the settings window; your edits are preserved.");
            self.cancelClosePrompt();
        }
    }

    fn closeNow(self: *SettingsWindow, hwnd: HWND) void {
        if (self.close_notified) return;
        self.close_notified = true;
        _ = sys.ShowWindow(hwnd, SW_HIDE);
        if (sys.DestroyWindow(hwnd) == 0) {
            self.close_notified = false;
            self.close_posted = false;
            _ = sys.ShowWindow(hwnd, SW_SHOWNORMAL);
            self.updateClosePromptActions();
            self.setStatus("Could not close the settings window; your edits are preserved.");
            self.cancelClosePrompt();
            return;
        }
        self.handle.onClosed(self.handle.ctx);
    }

    fn nextSuccessfulRevision(self: *SettingsWindow) u64 {
        if (self.handle.configRevision) |get_revision| {
            return get_revision(self.handle.ctx);
        }
        self.local_revision +%= 1;
        return self.local_revision;
    }

    fn succeedApply(self: *SettingsWindow, apply_id: ApplyId, revision: u64) bool {
        const transaction = &(self.transaction orelse return false);
        _ = transaction.dispatch(.{ .apply_succeeded = .{
            .apply_id = apply_id,
            .revision = revision,
        } }, &.{}) catch |err| {
            std.log.err("settings: save completion rejected apply_id={d} err={}", .{ apply_id, err });
            return false;
        };
        return true;
    }

    fn failApply(self: *SettingsWindow, apply_id: ApplyId) bool {
        const transaction = &(self.transaction orelse return false);
        _ = transaction.dispatch(.{ .apply_failed = .{ .apply_id = apply_id } }, &.{}) catch |err| {
            std.log.err("settings: save failure completion rejected apply_id={d} err={}", .{ apply_id, err });
            return false;
        };
        return true;
    }

    fn finishSuccessfulSave(self: *SettingsWindow, masked: bool) void {
        const should_close = self.close_after_save;
        self.adoptCurrentConfig() catch |err| {
            std.log.err("settings: failed to refresh saved config snapshot err={}", .{err});
            if (should_close) self.cancelClosePrompt();
            return;
        };
        self.refreshAllControls();
        self.setStatus(if (masked) "Saved, but a later config layer masks one or more values." else "Settings saved.");
        self.updateSaveEnabled();
        if (masked) {
            self.handle.notifySuccess(
                self.handle.ctx,
                "Settings saved — some values are masked by a later config-file layer",
                "Check the log for which fields.",
            );
        } else {
            self.handle.notifySuccess(self.handle.ctx, "Settings saved", "");
        }
        if (should_close and self.close_after_save) {
            self.postCloseNow();
        } else if (self.close_prompt_visible and !self.hasPendingChanges()) {
            self.cancelClosePrompt();
        }
    }

    fn completeSynchronousSave(self: *SettingsWindow, apply_id: ?ApplyId, masked: bool) void {
        const revision = self.nextSuccessfulRevision();
        if (apply_id) |id| {
            if (!self.succeedApply(id, revision)) return;
        }
        self.finishSuccessfulSave(masked);
    }

    /// Settle an asynchronous request emitted by `requestSave`. Stale or
    /// duplicate tokens are rejected without discarding the staged draft.
    pub fn completeSave(self: *SettingsWindow, apply_id: ApplyId, completion: SaveCompletion) void {
        switch (completion) {
            .succeeded => |revision| {
                if (!self.succeedApply(apply_id, revision)) return;
                self.setSaveInFlight(false);
                if (self.handle.configRevision == null) self.local_revision = revision;
                self.finishSuccessfulSave(false);
            },
            .failed => |err| {
                if (!self.failApply(apply_id)) return;
                self.setSaveInFlight(false);
                std.log.warn("settings: asynchronous save failed err={}; draft preserved", .{err});
                self.setStatus("Save failed. Your edits are preserved; retry when the underlying problem is resolved.");
                self.updateSaveEnabled();
                if (self.close_after_save) self.cancelClosePrompt();
            },
        }
    }

    fn adoptCurrentConfig(self: *SettingsWindow) !void {
        const current = self.handle.currentConfig(self.handle.ctx);
        var original = try current.clone(self.handle.alloc);
        errdefer original.deinit();
        var current_snapshot = try current.clone(self.handle.alloc);
        errdefer current_snapshot.deinit();
        var pending = try current.clone(self.handle.alloc);
        errdefer pending.deinit();

        self.clearPending();
        self.original = original;
        self.current = current_snapshot;
        self.pending = pending;
        self.initTransaction();
    }

    /// Open settings at the exact native control that owns `field`.
    pub fn openField(self: *SettingsWindow, field: SettingField) !void {
        try self.open();
        const destination: struct { section: Section, hwnd: ?HWND } = switch (field) {
            .font_size => .{ .section = .appearance, .hwnd = self.edit_font_size },
            .background_opacity => .{ .section = .appearance, .hwnd = self.edit_bg_opacity },
            .window_padding_x => .{ .section = .appearance, .hwnd = self.edit_pad_x },
            .window_padding_y => .{ .section = .appearance, .hwnd = self.edit_pad_y },
            .window_theme => .{ .section = .appearance, .hwnd = self.combo_window_theme },
            .cursor_style => .{ .section = .appearance, .hwnd = self.combo_cursor_style },
            .background_blur => .{ .section = .appearance, .hwnd = self.chk_bg_blur },
            .padding_balance => .{ .section = .appearance, .hwnd = self.combo_pad_balance },
            .scrollback_limit => .{ .section = .terminal, .hwnd = self.edit_scrollback },
            .trim_trailing_spaces => .{ .section = .terminal, .hwnd = self.chk_trim_trail },
            .desktop_notifications => .{ .section = .privacy, .hwnd = self.chk_desktop_notifications },
            .app_notify_clipboard => .{ .section = .privacy, .hwnd = self.chk_app_notify_clipboard },
            .app_notify_config => .{ .section = .privacy, .hwnd = self.chk_app_notify_config },
            .confirm_close => .{ .section = .terminal, .hwnd = self.combo_confirm_close },
            .copy_on_select => .{ .section = .terminal, .hwnd = self.combo_copy_on_select },
            .clipboard_read => .{ .section = .privacy, .hwnd = self.combo_clipboard_read },
            .clipboard_write => .{ .section = .privacy, .hwnd = self.combo_clipboard_write },
            .link_url => .{ .section = .privacy, .hwnd = self.combo_link_url },
            .link_previews => .{ .section = .privacy, .hwnd = self.combo_link_previews },
            .shell_integration => .{ .section = .shell, .hwnd = self.combo_shell_integ },
            .auto_update => .{ .section = .updates, .hwnd = self.combo_auto_update },
            .auto_update_channel => .{ .section = .updates, .hwnd = self.combo_auto_update_channel },
        };
        self.setActiveSection(destination.section);
        if (destination.hwnd) |control| {
            self.ensureControlVisible(control);
            _ = SetFocus(control);
        }
    }

    /// Bring the settings window up. Idempotent: a subsequent open
    /// with a live HWND brings the existing window to the foreground
    /// instead of duplicating it.
    pub fn open(self: *SettingsWindow) !void {
        if (self.hwnd) |h| {
            if (sys.IsWindow(h) != 0) {
                switch (pendingCloseReopenAction(self.close_posted, self.close_after_save)) {
                    .none => {},
                    .cancel_saved_close => {
                        self.close_posted = false;
                        self.close_after_save = false;
                    },
                    .cancel_discard_close => {
                        // The user already chose Discard. A reopen that wins
                        // the posted-close race must not resurrect that draft.
                        try self.adoptCurrentConfig();
                        self.refreshAllControls();
                        self.close_posted = false;
                        self.close_after_save = false;
                    },
                }
                self.cancelClosePrompt();
                if (sys.IsIconic(h) != 0) _ = sys.ShowWindow(h, SW_RESTORE) else _ = sys.ShowWindow(h, SW_SHOWNORMAL);
                _ = sys.SetForegroundWindow(h);
                return;
            }
            self.hwnd = null;
        }
        self.resetClosePromptState();
        self.close_notified = false;

        // Fresh owned snapshots of the live config. Discarded on close
        // or atomically refreshed after a successful save.
        try self.adoptCurrentConfig();

        if (self.class_atom == 0) {
            const wc: WNDCLASSEXW = .{
                .cbSize = @sizeOf(WNDCLASSEXW),
                .style = CS_HREDRAW | CS_VREDRAW,
                .lpfnWndProc = &wndProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = self.handle.hinstance,
                .hIcon = null,
                .hCursor = sys.LoadCursorW(null, @ptrFromInt(IDC_ARROW)),
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = class_name,
                .hIconSm = null,
            };
            self.class_atom = sys.RegisterClassExW(&wc);
            if (self.class_atom == 0) {
                return windows.unexpectedError(windows.kernel32.GetLastError());
            }
        }

        const title = std.unicode.utf8ToUtf16LeStringLiteral("noctty settings");
        const window_style = (WS_OVERLAPPEDWINDOW & ~WS_MAXIMIZEBOX) | WS_VSCROLL;
        const initial_outer = settingsOuterSizeForClient(960, 640, 96, window_style, WS_EX_APPWINDOW);
        const owner_hwnd = if (self.handle.ownerWindow) |get_owner| get_owner(self.handle.ctx) else null;
        const hwnd = sys.CreateWindowExW(
            WS_EX_APPWINDOW,
            class_name,
            title,
            window_style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            initial_outer.x,
            initial_outer.y,
            // Keep settings independent from terminal lifetime. The owner HWND
            // is used only to choose/center on the originating monitor below;
            // an owned top-level window is destroyed when its owner dies and
            // would bypass dirty-close confirmation.
            null,
            null,
            self.handle.hinstance,
            self,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        self.hwnd = hwnd;
        self.dpi = normalizedDpi(sys.GetDpiForWindow(hwnd));

        // PerMonitorV2 coordinates are physical pixels. Start at the intended
        // logical size, capped to the current work area, so a high-DPI monitor
        // does not receive a tiny and immediately overlapping first frame.
        var work_area: RECT = undefined;
        var have_work_area = false;
        if (owner_hwnd) |owner| if (sys.MonitorFromWindow(owner, MONITOR_DEFAULTTONEAREST)) |monitor| {
            var info: MONITORINFO = .{
                .cbSize = @sizeOf(MONITORINFO),
                .rcMonitor = undefined,
                .rcWork = undefined,
                .dwFlags = 0,
            };
            if (sys.GetMonitorInfoW(monitor, &info) != 0) {
                work_area = info.rcWork;
                have_work_area = true;
            }
        };
        if (!have_work_area) have_work_area = sys.SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0) != 0;
        if (have_work_area) {
            const work_width = work_area.right - work_area.left;
            const work_height = work_area.bottom - work_area.top;
            const intended = settingsOuterSizeForClient(960, 640, self.dpi, window_style, WS_EX_APPWINDOW);
            const width = @min(intended.x, work_width);
            const height = @min(intended.y, work_height);
            _ = SetWindowPos(
                hwnd,
                null,
                work_area.left + @divTrunc(work_width - width, 2),
                work_area.top + @divTrunc(work_height - height, 2),
                width,
                height,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }

        const btn_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
        self.text_header = makeStatic(hwnd, self.handle.hinstance, "Appearance");
        self.text_summary = makeStatic(hwnd, self.handle.hinstance, Section.appearance.placeholderText());
        self.text_status = makeStatic(hwnd, self.handle.hinstance, "");
        self.text_close_prompt = makeStatic(hwnd, self.handle.hinstance, "Save changes before closing?");
        if (self.text_close_prompt) |text| _ = sys.ShowWindow(text, SW_HIDE);
        self.text_help = makeStatic(hwnd, self.handle.hinstance, "");
        for (settings_label_specs, 0..) |spec, i| {
            self.field_labels[i] = makeStatic(hwnd, self.handle.hinstance, spec);
        }
        self.initializeTextUiaProviders();

        // Left-rail section buttons. Clicks arrive via WM_COMMAND on
        // the parent; the id maps back to a `Section` via
        // `Section.fromButtonId`.
        self.btn_section_appearance = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.appearance);
        self.btn_section_terminal = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.terminal);
        self.btn_section_shell = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.shell);
        self.btn_section_privacy = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.privacy);
        self.btn_section_updates = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.updates);
        self.btn_section_keybindings = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.keybindings);
        self.btn_section_advanced = makeSectionButton(hwnd, self.handle.hinstance, btn_class, Section.advanced);
        self.subclassSectionButtons();
        self.initializeSectionUiaProviders();

        // "Open in default editor" button — escape hatch for users
        // who prefer text-editing the config file directly. Lives
        // in the Advanced section; hidden when another section is
        // active.
        const btn_label = std.unicode.utf8ToUtf16LeStringLiteral("Open in default editor");
        self.btn_open_editor = sys.CreateWindowExW(
            0,
            btn_class,
            btn_label,
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            settings_field_max_width,
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
        self.btn_save = sys.CreateWindowExW(
            0,
            btn_class,
            btn_save_label,
            WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            96,
            32,
            hwnd,
            @ptrFromInt(BTN_SAVE),
            self.handle.hinstance,
            null,
        );
        self.btn_conflict_keep = sys.CreateWindowExW(
            0,
            btn_class,
            std.unicode.utf8ToUtf16LeStringLiteral("Keep mine"),
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            112,
            32,
            hwnd,
            @ptrFromInt(BTN_CONFLICT_KEEP),
            self.handle.hinstance,
            null,
        );
        self.btn_conflict_use_disk = sys.CreateWindowExW(
            0,
            btn_class,
            std.unicode.utf8ToUtf16LeStringLiteral("Use disk"),
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            112,
            32,
            hwnd,
            @ptrFromInt(BTN_CONFLICT_USE_DISK),
            self.handle.hinstance,
            null,
        );
        self.btn_close_save = sys.CreateWindowExW(
            0,
            btn_class,
            std.unicode.utf8ToUtf16LeStringLiteral("Save and close"),
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            120,
            32,
            hwnd,
            @ptrFromInt(BTN_CLOSE_SAVE),
            self.handle.hinstance,
            null,
        );
        self.btn_close_discard = sys.CreateWindowExW(
            0,
            btn_class,
            std.unicode.utf8ToUtf16LeStringLiteral("Discard changes"),
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            128,
            32,
            hwnd,
            @ptrFromInt(BTN_CLOSE_DISCARD),
            self.handle.hinstance,
            null,
        );
        self.btn_close_keep_editing = sys.CreateWindowExW(
            0,
            btn_class,
            std.unicode.utf8ToUtf16LeStringLiteral("Keep editing"),
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            112,
            32,
            hwnd,
            @ptrFromInt(BTN_CLOSE_KEEP_EDITING),
            self.handle.hinstance,
            null,
        );

        const btn_keybind_label = std.unicode.utf8ToUtf16LeStringLiteral("Open config for keybinds");
        self.btn_keybindings_editor = sys.CreateWindowExW(
            0,
            btn_class,
            btn_keybind_label,
            WS_CHILD | WS_TABSTOP | BS_PUSHBUTTON,
            0,
            0,
            settings_field_max_width,
            32,
            hwnd,
            @ptrFromInt(BTN_KEYBINDINGS_EDITOR),
            self.handle.hinstance,
            null,
        );

        // Scrollback limit EDIT. Lives in the Terminal section. Digit-
        // only input via ES_NUMBER; EN_CHANGE syncs into `pending`.
        self.edit_scrollback = makeEdit(hwnd, self.handle.hinstance, EDIT_SCROLLBACK, ES_NUMBER);

        // font-family EDIT. Comma-separated fallback families.
        self.edit_font_family = makeEdit(hwnd, self.handle.hinstance, EDIT_FONT_FAMILY, 0);

        // font-size EDIT. Appearance section. We accept floats via a
        // plain EDIT (not ES_NUMBER — which rejects '.') and validate
        // on EN_CHANGE.
        self.edit_font_size = makeEdit(hwnd, self.handle.hinstance, EDIT_FONT_SIZE, 0);

        // theme EDIT. Accepts a built-in/custom name or light/dark pair.
        self.edit_theme = makeEdit(hwnd, self.handle.hinstance, EDIT_THEME, 0);

        // background-opacity EDIT. Appearance section. 0.0..1.0.
        self.edit_bg_opacity = makeEdit(hwnd, self.handle.hinstance, EDIT_BG_OPACITY, 0);

        self.edit_command = makeEdit(hwnd, self.handle.hinstance, EDIT_COMMAND, 0);

        self.edit_pad_x = makeEdit(hwnd, self.handle.hinstance, EDIT_PAD_X, 0);

        self.edit_pad_y = makeEdit(hwnd, self.handle.hinstance, EDIT_PAD_Y, 0);

        // clipboard-trim-trailing-spaces checkbox. Terminal section.
        self.chk_trim_trail = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_TRIM_TRAIL,
            std.unicode.utf8ToUtf16LeStringLiteral("Trim trailing spaces on copy"),
        );

        self.chk_desktop_notifications = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_DESKTOP_NOTIFICATIONS,
            std.unicode.utf8ToUtf16LeStringLiteral("Allow terminal desktop notifications"),
        );

        self.chk_app_notify_clipboard = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_APP_NOTIFY_CLIPBOARD,
            std.unicode.utf8ToUtf16LeStringLiteral("Notify when clipboard copy completes"),
        );

        self.chk_app_notify_config = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_APP_NOTIFY_CONFIG,
            std.unicode.utf8ToUtf16LeStringLiteral("Notify after config reload"),
        );

        // Comboboxes for enum fields.
        self.combo_confirm_close = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CONFIRM_CLOSE,
            settings_combo_popup_height,
            &.{ "false", "true", "always" },
        );

        self.combo_copy_on_select = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_COPY_ON_SELECT,
            settings_combo_popup_height,
            &.{ "false", "true", "clipboard" },
        );

        self.combo_clipboard_read = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CLIPBOARD_READ,
            settings_combo_popup_height,
            &.{ "ask", "allow", "deny" },
        );

        self.combo_clipboard_write = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CLIPBOARD_WRITE,
            settings_combo_popup_height,
            &.{ "ask", "allow", "deny" },
        );

        self.combo_link_url = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_LINK_URL,
            settings_combo_popup_height,
            &.{ "enabled", "disabled" },
        );

        self.combo_link_previews = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_LINK_PREVIEWS,
            settings_combo_popup_height,
            &.{ "all links", "OSC 8 only", "disabled" },
        );

        self.combo_window_theme = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_WINDOW_THEME,
            settings_combo_popup_height,
            &.{ "auto", "system", "light", "dark", "ghostty" },
        );

        self.combo_shell_integ = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_SHELL_INTEG,
            settings_combo_popup_height,
            &.{ "none", "detect", "bash", "elvish", "fish", "nushell", "zsh" },
        );

        self.combo_cursor_style = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_CURSOR_STYLE,
            settings_combo_popup_height,
            &.{ "bar", "block", "underline", "block_hollow" },
        );

        self.chk_bg_blur = makeCheckbox(
            hwnd,
            self.handle.hinstance,
            CHK_BG_BLUR,
            std.unicode.utf8ToUtf16LeStringLiteral("Enable background blur"),
        );

        self.combo_pad_balance = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_PAD_BALANCE,
            settings_combo_popup_height,
            &.{ "false", "true", "equal" },
        );

        self.combo_auto_update = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_AUTO_UPDATE,
            settings_combo_popup_height,
            &.{ "default", "off", "check", "download" },
        );

        self.combo_auto_update_channel = makeCombo(
            hwnd,
            self.handle.hinstance,
            COMBO_AUTO_UPDATE_CHANNEL,
            settings_combo_popup_height,
            &.{ "default", "stable", "tip" },
        );

        // Painted field labels keep the native dark visual treatment, while
        // MSAA annotations give the existing EDIT/COMBO HWNDs stable names
        // through the UI Automation bridge. Values remain owned by the native
        // controls and are not conflated with their accessible names.
        annotateAccessibleControls(self);
        self.initializeControlUiaProviders();

        self.refreshAllControls();
        self.refreshNativeSectionText();
        self.theme_adapter.apply(hwnd, self.resolveThemeColors());
        self.recreateUiFont();

        layoutChildren(self);
        self.applySectionVisibility();
        _ = sys.ShowWindow(hwnd, SW_SHOWNORMAL);
        _ = sys.SetForegroundWindow(hwnd);
        if (self.sectionButton(self.active_section)) |button| _ = sys.SetFocus(button);
    }
};

const IAccPropServicesVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    SetPropValue: *const anyopaque,
    SetPropServer: *const anyopaque,
    ClearProps: *const anyopaque,
    SetHwndProp: *const anyopaque,
    SetHwndPropStr: *const fn (
        *anyopaque,
        HWND,
        u32,
        u32,
        GUID,
        LPCWSTR,
    ) callconv(.winapi) HRESULT,
};

const IAccPropServices = extern struct {
    vtbl: *const IAccPropServicesVtbl,

    fn asRaw(self: *IAccPropServices) *anyopaque {
        return @ptrCast(self);
    }

    fn release(self: *IAccPropServices) void {
        _ = self.vtbl.Release(self.asRaw());
    }

    fn setName(self: *IAccPropServices, hwnd: HWND, comptime name: []const u8) HRESULT {
        return self.vtbl.SetHwndPropStr(
            self.asRaw(),
            hwnd,
            OBJID_CLIENT,
            CHILDID_SELF,
            PROPID_ACC_NAME,
            std.unicode.utf8ToUtf16LeStringLiteral(name),
        );
    }
};

fn createAccPropServices() ?*IAccPropServices {
    var raw: ?*anyopaque = null;
    const hr = sys.CoCreateInstance(
        &CLSID_ACC_PROP_SERVICES,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IACC_PROP_SERVICES,
        &raw,
    );
    if (hr < 0 or raw == null) return null;
    return @ptrCast(@alignCast(raw.?));
}

fn setAccessibleName(service: *IAccPropServices, hwnd_opt: ?HWND, comptime name: []const u8) void {
    const hwnd = hwnd_opt orelse return;
    const hr = service.setName(hwnd, name);
    if (hr < 0) {
        std.log.warn("settings: failed to set accessible name '{s}' hr=0x{x}", .{
            name,
            @as(u32, @bitCast(hr)),
        });
    }
}

fn annotateAccessibleControls(self: *SettingsWindow) void {
    const service = createAccPropServices() orelse {
        std.log.warn("settings: accessibility annotation service unavailable", .{});
        return;
    };
    defer service.release();

    setAccessibleName(service, self.edit_scrollback, "Scrollback limit");
    setAccessibleName(service, self.combo_confirm_close, "Close confirmation");
    setAccessibleName(service, self.combo_copy_on_select, "Copy on select");
    setAccessibleName(service, self.edit_font_family, "Font family fallbacks");
    setAccessibleName(service, self.edit_font_size, "Font size");
    setAccessibleName(service, self.edit_theme, "Terminal theme");
    setAccessibleName(service, self.edit_bg_opacity, "Background opacity");
    setAccessibleName(service, self.combo_window_theme, "Window theme");
    setAccessibleName(service, self.combo_cursor_style, "Cursor style");
    setAccessibleName(service, self.edit_pad_x, "Window padding X");
    setAccessibleName(service, self.edit_pad_y, "Window padding Y");
    setAccessibleName(service, self.combo_pad_balance, "Window padding balance");
    setAccessibleName(service, self.edit_command, "Default command");
    setAccessibleName(service, self.combo_shell_integ, "Shell integration");
    setAccessibleName(service, self.combo_clipboard_read, "OSC 52 clipboard read requests");
    setAccessibleName(service, self.combo_clipboard_write, "OSC 52 clipboard write requests");
    setAccessibleName(service, self.combo_link_url, "Clickable URL opening");
    setAccessibleName(service, self.combo_link_previews, "Link preview popups");
    setAccessibleName(service, self.combo_auto_update, "Auto-update mode");
    setAccessibleName(service, self.combo_auto_update_channel, "Auto-update channel");
    setAccessibleName(service, self.btn_close_save, "Save and close");
    setAccessibleName(service, self.btn_close_discard, "Discard changes");
    setAccessibleName(service, self.btn_close_keep_editing, "Keep editing");
}

fn populateCombo(combo_opt: ?HWND, items: []const []const u8) void {
    const combo = combo_opt orelse return;
    _ = sys.SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    for (items) |item| {
        var buf_w: [64]u16 = undefined;
        const w = utf8ToW(&buf_w, item);
        _ = sys.SendMessageW(combo, CB_ADDSTRING, 0, @bitCast(@intFromPtr(w)));
    }
}

fn makeStatic(parent: HWND, hinstance: HINSTANCE, text: []const u8) ?HWND {
    var text_w: [2048]u16 = undefined;
    return sys.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        utf8ToW(&text_w, text),
        WS_CHILD | WS_VISIBLE | SS_LEFT | SS_NOPREFIX,
        0,
        0,
        1,
        1,
        parent,
        null,
        hinstance,
        null,
    );
}

fn setWindowTextUtf8(hwnd_opt: ?HWND, text: []const u8) void {
    const hwnd = hwnd_opt orelse return;
    var text_w: [2048]u16 = undefined;
    _ = sys.SendMessageW(hwnd, WM_SETTEXT, 0, @bitCast(@intFromPtr(utf8ToW(&text_w, text))));
}

fn setWindowTextUtf8IfChanged(hwnd: HWND, text: []const u8) bool {
    var current: [2048]u16 = undefined;
    const current_len: usize = @intCast(@max(0, sys.GetWindowTextW(hwnd, &current, @intCast(current.len))));
    var desired: [2048]u16 = undefined;
    const desired_z = utf8ToW(&desired, text);
    const desired_slice = std.mem.span(desired_z);
    if (std.mem.eql(u16, current[0..current_len], desired_slice)) return false;
    _ = sys.SendMessageW(hwnd, WM_SETTEXT, 0, @bitCast(@intFromPtr(desired_z)));
    return true;
}

fn applyChildFont(hwnd: HWND, lParam: LPARAM) callconv(.winapi) BOOL {
    _ = sys.SendMessageW(hwnd, WM_SETFONT, @as(WPARAM, @bitCast(lParam)), 1);
    return 1;
}

fn fontProbeCallback(_: *const LOGFONTW, _: ?*const anyopaque, _: u32, lParam: LPARAM) callconv(.winapi) c_int {
    const found: *bool = @ptrFromInt(@as(usize, @bitCast(lParam)));
    found.* = true;
    return 0;
}

fn fontFaceAvailable(hwnd: HWND, face: [*:0]const u16) bool {
    const hdc = GetDC(hwnd) orelse return false;
    defer _ = ReleaseDC(hwnd, hdc);
    var query: LOGFONTW = .{};
    const name = std.mem.span(face);
    const copy_len = @min(name.len, query.lfFaceName.len - 1);
    @memcpy(query.lfFaceName[0..copy_len], name[0..copy_len]);
    var found = false;
    _ = EnumFontFamiliesExW(
        hdc,
        &query,
        &fontProbeCallback,
        @bitCast(@intFromPtr(&found)),
        0,
    );
    return found;
}

fn createSettingsFont(dpi: u32, logical_height: i32, weight: i32, face: [*:0]const u16) HGDIOBJ {
    return CreateFontW(
        -scaleForDpi(logical_height, dpi),
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        1,
        0,
        0,
        5,
        0,
        face,
    );
}

fn makeEdit(
    parent: HWND,
    hinstance: HINSTANCE,
    id: usize,
    extra_style: u32,
) ?HWND {
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const edit = CreateWindowExW(
        WS_EX_CLIENTEDGE,
        edit_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL | extra_style,
        0,
        0,
        settings_field_max_width,
        settings_control_height,
        parent,
        @ptrFromInt(id),
        hinstance,
        null,
    );
    if (edit) |e| _ = sys.SendMessageW(e, EM_LIMITTEXT, edit_text_max_code_units - 1, 0);
    return edit;
}

fn makeCheckbox(
    parent: HWND,
    hinstance: HINSTANCE,
    id: usize,
    label: LPCWSTR,
) ?HWND {
    const btn_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
    return sys.CreateWindowExW(
        0,
        btn_class,
        label,
        WS_CHILD | WS_TABSTOP | BS_AUTOCHECKBOX,
        0,
        0,
        settings_field_max_width,
        settings_control_height,
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
    const combo = sys.CreateWindowExW(
        0,
        combo_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_TABSTOP | CBS_DROPDOWNLIST | CBS_HASSTRINGS,
        0,
        0,
        settings_field_max_width,
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
        .privacy => BTN_SECTION_PRIVACY,
        .updates => BTN_SECTION_UPDATES,
        .keybindings => BTN_SECTION_KEYBINDINGS,
        .advanced => BTN_SECTION_ADVANCED,
    };
    const group_style: u32 = if (section == .appearance) WS_GROUP | WS_TABSTOP else 0;
    return sys.CreateWindowExW(
        0,
        class,
        section.label(),
        WS_CHILD | WS_VISIBLE | group_style | BS_AUTORADIOBUTTON | BS_PUSHLIKE,
        0,
        0,
        100,
        settings_rail_item_height,
        parent,
        @ptrFromInt(id),
        hinstance,
        null,
    );
}

const settings_metrics: win32_theme.ThemeMetrics = .{};
const settings_rail_width: i32 = 184;
const settings_rail_padding_x: i32 = settings_metrics.space_4;
const settings_rail_top_padding: i32 = settings_metrics.space_6;
const settings_rail_item_height: i32 = settings_metrics.space_9;
const settings_rail_item_gap: i32 = settings_metrics.space_2;
const compact_section_btn_height: i32 = 28;
const compact_section_btn_top_pad: i32 = settings_metrics.space_4;
const compact_section_btn_gap: i32 = settings_metrics.space_1;
const settings_pane_padding: i32 = settings_metrics.space_6;
const settings_header_title_height: i32 = settings_metrics.space_8;
const settings_header_summary_top: i32 = settings_header_title_height + settings_metrics.space_2;
const settings_header_summary_height: i32 = 36;
const settings_header_separator_y: i32 = settings_header_summary_top + settings_header_summary_height + settings_metrics.space_5;
const settings_form_viewport_top: i32 = settings_header_separator_y + settings_metrics.space_4;
const settings_prose_max_width: i32 = 560;
const settings_action_bar_height: i32 = 64;
const settings_action_padding: i32 = settings_metrics.space_6;
const settings_action_gap: i32 = settings_metrics.space_4;
const settings_field_label_height: i32 = settings_metrics.space_6;
const settings_label_control_gap: i32 = settings_metrics.space_2;
const settings_field_label_offset: i32 = settings_metrics.space_7;
const settings_control_height: i32 = settings_metrics.space_9;
const settings_combo_item_height: i32 = settings_metrics.space_9;
const settings_field_group_gap: i32 = settings_metrics.space_5;
const settings_field_row_pitch: i32 = 64;
const settings_column_gap: i32 = settings_metrics.space_8;
const settings_column_min_width: i32 = 320;
const settings_two_column_min_width: i32 = 664;
const settings_field_max_width: i32 = 360;
const settings_combo_popup_height: i32 = 160;
const settings_content_bottom_padding: i32 = settings_metrics.space_6;

const RailGeometry = struct {
    top_pad: i32,
    button_height: i32,
    gap: i32,
};

fn sectionRailGeometry(client_height: i32, dpi: u32) RailGeometry {
    const regular: RailGeometry = .{
        .top_pad = scaleForDpi(settings_rail_top_padding, dpi),
        .button_height = scaleForDpi(settings_rail_item_height, dpi),
        .gap = scaleForDpi(settings_rail_item_gap, dpi),
    };
    const button_count: i32 = @intCast(section_count);
    const regular_bottom = regular.top_pad + button_count * regular.button_height + (button_count - 1) * regular.gap;
    if (regular_bottom <= client_height) return regular;
    const compact: RailGeometry = .{
        .top_pad = scaleForDpi(compact_section_btn_top_pad, dpi),
        .button_height = scaleForDpi(compact_section_btn_height, dpi),
        .gap = scaleForDpi(compact_section_btn_gap, dpi),
    };
    const compact_bottom = compact.top_pad + button_count * compact.button_height + (button_count - 1) * compact.gap;
    if (compact_bottom <= client_height) return compact;

    // Work areas can be shorter than the nominal minimum at large DPI. Keep
    // every navigation target reachable rather than placing the last buttons
    // below the client edge. This only compresses below the compact geometry.
    const bounded_height = @max(button_count, client_height);
    const top_pad = @min(compact.top_pad, @max(0, bounded_height - button_count));
    const remaining = bounded_height - top_pad;
    const gap = @min(
        compact.gap,
        @max(0, @divTrunc(remaining - button_count, @max(1, button_count - 1))),
    );
    return .{
        .top_pad = top_pad,
        .button_height = @max(1, @divTrunc(remaining - (button_count - 1) * gap, button_count)),
        .gap = gap,
    };
}

const ActionRowGeometry = struct {
    first_x: i32,
    first_width: i32,
    second_x: i32,
    second_y: i32,
    second_width: i32,
    third_x: i32,
    third_y: i32,
    third_width: i32,
    button_height: i32,
    stacked: bool,
};

fn closeActionRowGeometry(available_width: i32, available_height: i32, dpi: u32) ActionRowGeometry {
    const gap = scaleForDpi(settings_action_gap, dpi);
    const preferred_first = scaleForDpi(120, dpi);
    const preferred_second = scaleForDpi(128, dpi);
    const preferred_third = scaleForDpi(112, dpi);
    const preferred_height = scaleForDpi(settings_control_height, dpi);
    const preferred_total = preferred_first + preferred_second + preferred_third + 2 * gap;
    if (available_width >= preferred_total) return .{
        .first_x = available_width - preferred_total,
        .first_width = preferred_first,
        .second_x = available_width - preferred_total + preferred_first + gap,
        .second_y = 0,
        .second_width = preferred_second,
        .third_x = available_width - preferred_third,
        .third_y = 0,
        .third_width = preferred_third,
        .button_height = @min(preferred_height, @max(0, available_height)),
        .stacked = false,
    };

    const width = @max(0, available_width);
    const height = @max(0, available_height);
    const vertical_gap = @min(scaleForDpi(6, dpi), @divTrunc(@max(0, height - 3), 2));
    const button_height = @min(preferred_height, @divTrunc(@max(0, height - 2 * vertical_gap), 3));
    return .{
        .first_x = 0,
        .first_width = width,
        .second_x = 0,
        .second_y = button_height + vertical_gap,
        .second_width = width,
        .third_x = 0,
        .third_y = 2 * (button_height + vertical_gap),
        .third_width = width,
        .button_height = button_height,
        .stacked = true,
    };
}

const NormalActionRowGeometry = struct {
    status_right: i32,
    keep_mine_x: i32,
    keep_mine_y: i32,
    keep_mine_width: i32,
    use_disk_x: i32,
    use_disk_y: i32,
    use_disk_width: i32,
    save_x: i32,
    save_y: i32,
    save_width: i32,
    button_height: i32,
    stacked: bool,
};

fn normalActionRowGeometry(pane_width: i32, available_height: i32, conflict: bool, dpi: u32) NormalActionRowGeometry {
    const gap = scaleForDpi(settings_action_gap, dpi);
    const preferred_save_width = scaleForDpi(96, dpi);
    const preferred_conflict_width = scaleForDpi(112, dpi);
    const preferred_height = scaleForDpi(settings_control_height, dpi);
    const width = @max(0, pane_width);
    const height = @max(0, available_height);
    if (!conflict) {
        const save_width = @min(preferred_save_width, width);
        const save_x = width - save_width;
        return .{
            .status_right = @max(0, save_x - gap),
            .keep_mine_x = 0,
            .keep_mine_y = 0,
            .keep_mine_width = 0,
            .use_disk_x = 0,
            .use_disk_y = 0,
            .use_disk_width = 0,
            .save_x = save_x,
            .save_y = 0,
            .save_width = save_width,
            .button_height = @min(preferred_height, height),
            .stacked = false,
        };
    }

    const preferred_total = preferred_save_width + 2 * preferred_conflict_width + 2 * gap;
    if (width >= preferred_total) {
        const save_x = width - preferred_save_width;
        const use_disk_x = save_x - gap - preferred_conflict_width;
        const keep_mine_x = use_disk_x - gap - preferred_conflict_width;
        return .{
            .status_right = @max(0, keep_mine_x - gap),
            .keep_mine_x = keep_mine_x,
            .keep_mine_y = 0,
            .keep_mine_width = preferred_conflict_width,
            .use_disk_x = use_disk_x,
            .use_disk_y = 0,
            .use_disk_width = preferred_conflict_width,
            .save_x = save_x,
            .save_y = 0,
            .save_width = preferred_save_width,
            .button_height = @min(preferred_height, height),
            .stacked = false,
        };
    }

    const vertical_gap = @min(scaleForDpi(6, dpi), @divTrunc(@max(0, height - 3), 2));
    const button_height = @min(preferred_height, @divTrunc(@max(0, height - 2 * vertical_gap), 3));
    return .{
        .status_right = 0,
        .keep_mine_x = 0,
        .keep_mine_y = 0,
        .keep_mine_width = width,
        .use_disk_x = 0,
        .use_disk_y = button_height + vertical_gap,
        .use_disk_width = width,
        .save_x = 0,
        .save_y = 2 * (button_height + vertical_gap),
        .save_width = width,
        .button_height = button_height,
        .stacked = true,
    };
}

const ConflictFocusTarget = enum { validation, save, section, none };

fn conflictFocusTarget(has_validation: bool, save_enabled: bool, has_section: bool) ConflictFocusTarget {
    if (has_validation) return .validation;
    if (save_enabled) return .save;
    if (has_section) return .section;
    return .none;
}

const CloseRequestAction = enum { close_now, show_prompt, focus_prompt, ignore };
const PendingCloseReopenAction = enum { none, cancel_saved_close, cancel_discard_close };
const ClosePromptActions = struct {
    save: bool,
    discard: bool,
    keep_editing: bool,
};

fn closeRequestAction(has_pending: bool, prompt_visible: bool, close_posted: bool) CloseRequestAction {
    if (close_posted) return .ignore;
    if (!has_pending) return .close_now;
    if (prompt_visible) return .focus_prompt;
    return .show_prompt;
}

fn closePromptActions(visible: bool, save_in_flight: bool, close_posted: bool) ClosePromptActions {
    const can_choose = visible and !close_posted;
    return .{
        .save = can_choose and !save_in_flight,
        .discard = can_choose and !save_in_flight,
        .keep_editing = can_choose,
    };
}

fn closePromptCanCancel(visible: bool, close_posted: bool) bool {
    return visible and !close_posted;
}

fn closePromptText(save_in_flight: bool) []const u8 {
    return if (save_in_flight)
        "Saving changes. Settings will close when saving finishes. Choose Keep editing to keep it open."
    else
        "Save changes before closing?";
}

fn pendingCloseReopenAction(close_posted: bool, close_after_save: bool) PendingCloseReopenAction {
    if (!close_posted) return .none;
    return if (close_after_save) .cancel_saved_close else .cancel_discard_close;
}

fn saveCommandCanDispatch(
    prompt_visible: bool,
    save_in_flight: bool,
    close_posted: bool,
    button_enabled: bool,
    button_visible: bool,
) bool {
    return !prompt_visible and !save_in_flight and !close_posted and button_enabled and button_visible;
}

test "settings dirty close transition is conservative and idempotent" {
    try std.testing.expectEqual(CloseRequestAction.close_now, closeRequestAction(false, false, false));
    try std.testing.expectEqual(CloseRequestAction.show_prompt, closeRequestAction(true, false, false));
    try std.testing.expectEqual(CloseRequestAction.focus_prompt, closeRequestAction(true, true, false));
    try std.testing.expectEqual(CloseRequestAction.ignore, closeRequestAction(true, true, true));
    try std.testing.expectEqual(CloseRequestAction.ignore, closeRequestAction(false, false, true));
}

test "settings close prompt uses one display and measurement text source" {
    try std.testing.expectEqualStrings("Save changes before closing?", closePromptText(false));
    try std.testing.expectEqualStrings(
        "Saving changes. Settings will close when saving finishes. Choose Keep editing to keep it open.",
        closePromptText(true),
    );
}

test "settings dirty close actions prevent discard during save" {
    try std.testing.expectEqual(
        ClosePromptActions{ .save = true, .discard = true, .keep_editing = true },
        closePromptActions(true, false, false),
    );
    try std.testing.expectEqual(
        ClosePromptActions{ .save = false, .discard = false, .keep_editing = true },
        closePromptActions(true, true, false),
    );
    try std.testing.expectEqual(
        ClosePromptActions{ .save = false, .discard = false, .keep_editing = false },
        closePromptActions(true, false, true),
    );
    try std.testing.expect(closePromptCanCancel(true, false));
    try std.testing.expect(!closePromptCanCancel(true, true));
    try std.testing.expect(!closePromptCanCancel(false, false));
}

test "settings reopen cancels posted close without restoring discarded draft" {
    try std.testing.expectEqual(
        PendingCloseReopenAction.none,
        pendingCloseReopenAction(false, false),
    );
    try std.testing.expectEqual(
        PendingCloseReopenAction.cancel_saved_close,
        pendingCloseReopenAction(true, true),
    );
    try std.testing.expectEqual(
        PendingCloseReopenAction.cancel_discard_close,
        pendingCloseReopenAction(true, false),
    );
}

test "settings save command rechecks dispatch state" {
    try std.testing.expect(saveCommandCanDispatch(false, false, false, true, true));
    try std.testing.expect(!saveCommandCanDispatch(true, false, false, true, true));
    try std.testing.expect(!saveCommandCanDispatch(false, true, false, true, true));
    try std.testing.expect(!saveCommandCanDispatch(false, false, true, true, true));
    try std.testing.expect(!saveCommandCanDispatch(false, false, false, false, true));
    try std.testing.expect(!saveCommandCanDispatch(false, false, false, true, false));
}

fn windowWorkArea(hwnd: HWND, work_area: *RECT) bool {
    if (sys.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)) |monitor| {
        var info: MONITORINFO = .{
            .cbSize = @sizeOf(MONITORINFO),
            .rcMonitor = undefined,
            .rcWork = undefined,
            .dwFlags = 0,
        };
        if (sys.GetMonitorInfoW(monitor, &info) != 0) {
            work_area.* = info.rcWork;
            return true;
        }
    }
    return sys.SystemParametersInfoW(SPI_GETWORKAREA, 0, work_area, 0) != 0;
}

fn cappedMinimum(logical: i32, dpi: u32, work_extent: i32) i32 {
    return @min(scaleForDpi(logical, dpi), work_extent);
}

fn normalizedDpi(dpi: u32) u32 {
    return if (dpi == 0) 96 else dpi;
}

fn scaleForDpi(logical: i32, dpi: u32) i32 {
    const effective: i64 = @intCast(normalizedDpi(dpi));
    return @intCast(@divTrunc(@as(i64, logical) * effective + 48, 96));
}

fn settingsOuterSizeForClient(client_width: i32, client_height: i32, dpi: u32, style: u32, ex_style: u32) POINT {
    var rect: RECT = .{
        .left = 0,
        .top = 0,
        .right = scaleForDpi(client_width, dpi),
        .bottom = scaleForDpi(client_height, dpi),
    };
    _ = AdjustWindowRectExForDpi(&rect, style, 0, ex_style, normalizedDpi(dpi));
    return .{ .x = rect.right - rect.left, .y = rect.bottom - rect.top };
}

fn settingsColumnCount(pane_width: i32, dpi: u32) usize {
    return if (pane_width >= scaleForDpi(settings_two_column_min_width, dpi)) 2 else 1;
}

test "settings logical geometry scales with monitor DPI" {
    try std.testing.expectEqual(@as(i32, 20), scaleForDpi(20, 0));
    try std.testing.expectEqual(@as(i32, 20), scaleForDpi(20, 96));
    try std.testing.expectEqual(@as(i32, 30), scaleForDpi(20, 144));
    try std.testing.expectEqual(@as(i32, 40), scaleForDpi(20, 192));
}

test "settings conflict focus fallback never targets a hidden action" {
    try std.testing.expectEqual(ConflictFocusTarget.validation, conflictFocusTarget(true, true, true));
    try std.testing.expectEqual(ConflictFocusTarget.save, conflictFocusTarget(false, true, true));
    try std.testing.expectEqual(ConflictFocusTarget.section, conflictFocusTarget(false, false, true));
    try std.testing.expectEqual(ConflictFocusTarget.none, conflictFocusTarget(false, false, false));
}

test "settings status priority survives validation and conflict mutations" {
    var settings: SettingsWindow = .{ .handle = undefined };
    const raw_control: HWND = @ptrFromInt(0x101);
    const owned_control: HWND = @ptrFromInt(0x102);
    settings.edit_font_size = raw_control;

    settings.setRawScalarValidationError(.font_size, raw_control, "Font size is required.");
    settings.setValidationError(owned_control, "Terminal theme is invalid.");
    settings.active_conflict_field = .background_opacity;
    try std.testing.expectEqual(
        SettingsStatus{ .raw_validation = .font_size },
        settings.nextStatus(),
    );
    try std.testing.expectEqual(raw_control, settings.validation_control.?);

    settings.raw_scalar_error[@intFromEnum(RawScalarField.font_size)] = null;
    settings.active_raw_validation = null;
    settings.surfaceNextValidation(false);
    try std.testing.expectEqual(
        SettingsStatus{ .owned_validation = owned_control },
        settings.nextStatus(),
    );
    try std.testing.expectEqual(owned_control, settings.validation_control.?);

    settings.clearValidationError(owned_control);
    try std.testing.expectEqual(
        SettingsStatus{ .conflict = .background_opacity },
        settings.nextStatus(),
    );
    try std.testing.expect(settings.validation_control == null);

    settings.active_conflict_field = null;
    try std.testing.expectEqual(SettingsStatus.none, settings.nextStatus());
}

test "settings save reload outcome treats masked persistence as completed" {
    try std.testing.expect(std.meta.activeTag(saveReloadOutcome({})) == .completed);
    try std.testing.expect(std.meta.activeTag(saveReloadOutcome(error.SavedButMasked)) == .completed_masked);
    const failed = saveReloadOutcome(error.ReloadFailed);
    try std.testing.expect(std.meta.activeTag(failed) == .failed);
    try std.testing.expectEqual(error.ReloadFailed, failed.failed);
}

test "settings invalid raw scalar edits require dirty close confirmation" {
    var settings: SettingsWindow = .{ .handle = undefined };

    for (std.enums.values(RawScalarField)) |field| {
        settings.markRawScalarEdit(field);
        try std.testing.expect(settings.hasPendingChanges());
        try std.testing.expect(settings.hasRawScalarEdits());

        // A successful parse transfers the edit to the typed transaction (or
        // discovers that it equals the baseline), so raw dirtiness is done.
        settings.finishRawScalarEdit(field);
        try std.testing.expect(!settings.hasPendingChanges());
        try std.testing.expect(!settings.hasRawScalarEdits());
    }

    for (std.enums.values(RawScalarField)) |field| settings.markRawScalarEdit(field);
    settings.clearPending();
    try std.testing.expect(!settings.hasPendingChanges());
    try std.testing.expect(!settings.hasRawScalarEdits());
}

test "settings external reload preserves every unparsed scalar edit" {
    var settings: SettingsWindow = .{ .handle = undefined };

    for (std.enums.values(RawScalarField)) |field| {
        try std.testing.expect(settings.shouldRefreshRawScalar(field));
        settings.markRawScalarEdit(field);
        // externalConfigChanged ends in refreshAllControls; each scalar
        // display path consults this predicate before replacing EDIT text.
        try std.testing.expect(!settings.shouldRefreshRawScalar(field));
        settings.finishRawScalarEdit(field);
        try std.testing.expect(settings.shouldRefreshRawScalar(field));
    }
}

test "settings fixing one of two invalid scalars surfaces the other" {
    var settings: SettingsWindow = .{ .handle = undefined };
    const font_size_control: HWND = @ptrFromInt(0x101);
    const opacity_control: HWND = @ptrFromInt(0x102);
    settings.edit_font_size = font_size_control;
    settings.edit_bg_opacity = opacity_control;

    settings.markRawScalarEdit(.font_size);
    settings.setRawScalarValidationError(.font_size, font_size_control, "Font size is required.");
    settings.markRawScalarEdit(.background_opacity);
    settings.setRawScalarValidationError(.background_opacity, opacity_control, "Background opacity is required.");
    try std.testing.expectEqual(RawScalarField.background_opacity, settings.active_raw_validation.?);
    try std.testing.expectEqual(opacity_control, settings.validation_control.?);

    settings.finishRawScalarEdit(.background_opacity);
    try std.testing.expect(settings.hasPendingChanges());
    try std.testing.expect(settings.hasRawScalarEdits());
    try std.testing.expectEqual(RawScalarField.font_size, settings.active_raw_validation.?);
    try std.testing.expectEqual(font_size_control, settings.validation_control.?);
    try std.testing.expectEqualStrings(
        "Font size is required.",
        settings.raw_scalar_error[@intFromEnum(RawScalarField.font_size)].?,
    );
    try std.testing.expect(settings.raw_scalar_error[@intFromEnum(RawScalarField.background_opacity)] == null);
}

test "settings minimum track size caps to target monitor work area" {
    try std.testing.expectEqual(@as(i32, 720), cappedMinimum(720, 96, 1920));
    try std.testing.expectEqual(@as(i32, 1000), cappedMinimum(720, 144, 1000));
    try std.testing.expectEqual(@as(i32, 780), cappedMinimum(520, 144, 900));
}

test "settings field geometry keeps labels clear of adjacent controls" {
    for ([_]u32{ 96, 120, 144, 168, 192, 288 }) |dpi| {
        const field = settingsFieldRects(0, scaleForDpi(664, dpi), dpi);
        const next = settingsFieldRects(2, scaleForDpi(664, dpi), dpi);
        try std.testing.expect(field.label.bottom + scaleForDpi(settings_label_control_gap, dpi) <= field.control.top);
        try std.testing.expect(field.control.bottom + scaleForDpi(settings_field_group_gap, dpi) <= next.label.top);
        try std.testing.expectEqual(field.control.right, next.control.right);
    }
}

test "settings two-column breakpoint preserves readable lane width" {
    for ([_]u32{ 96, 120, 144, 168, 192, 288 }) |dpi| {
        const breakpoint = scaleForDpi(settings_two_column_min_width, dpi);
        try std.testing.expectEqual(@as(usize, 1), settingsColumnCount(breakpoint - 1, dpi));
        try std.testing.expectEqual(@as(usize, 2), settingsColumnCount(breakpoint, dpi));
        const left = settingsFieldRects(0, breakpoint, dpi).control;
        const right = settingsFieldRects(1, breakpoint, dpi).control;
        try std.testing.expect(left.right <= right.left);
        try std.testing.expectEqual(scaleForDpi(settings_column_min_width, dpi), left.right - left.left);
        try std.testing.expectEqual(left.right - left.left, right.right - right.left);
    }
    const capped = settingsFieldRects(0, 1000, 96).control;
    const capped_right = settingsFieldRects(1, 1000, 96).control;
    try std.testing.expectEqual(@as(i32, settings_field_max_width), capped.right - capped.left);
    try std.testing.expectEqual(@as(i32, settings_column_gap), capped_right.left - capped.right);
}

test "settings rail compacts before high DPI work areas clip sections" {
    for ([_]u32{ 96, 120, 144, 168, 192, 288 }) |dpi| {
        const regular_height = scaleForDpi(320, dpi);
        const regular = sectionRailGeometry(regular_height, dpi);
        try std.testing.expectEqual(scaleForDpi(settings_rail_item_height, dpi), regular.button_height);
        const short_height = @max(@as(i32, section_count), scaleForDpi(190, dpi));
        const compact = sectionRailGeometry(short_height, dpi);
        const bottom = compact.top_pad + @as(i32, section_count) * compact.button_height +
            (@as(i32, section_count) - 1) * compact.gap;
        try std.testing.expect(compact.button_height > 0);
        try std.testing.expect(bottom <= short_height);
    }
}

test "settings close actions stack inside narrow high DPI panes" {
    for ([_]u32{ 96, 120, 144, 168, 192, 288 }) |dpi| {
        const available = scaleForDpi(344, dpi);
        const geometry = closeActionRowGeometry(available, scaleForDpi(108, dpi), dpi);
        try std.testing.expect(geometry.stacked);
        try std.testing.expect(geometry.first_width > 0);
        try std.testing.expect(geometry.second_width > 0);
        try std.testing.expect(geometry.third_width > 0);
        try std.testing.expectEqual(available, geometry.first_width);
        try std.testing.expectEqual(@as(i32, 0), geometry.first_x);
        try std.testing.expectEqual(@as(i32, 0), geometry.second_x);
        try std.testing.expect(geometry.second_y > 0);
        try std.testing.expect(geometry.third_y > geometry.second_y);
    }

    const tiny = closeActionRowGeometry(1, scaleForDpi(108, 288), 288);
    try std.testing.expectEqual(@as(i32, 1), tiny.first_width);
    try std.testing.expectEqual(@as(i32, 1), tiny.third_width);

    const wide = closeActionRowGeometry(500, settings_control_height, 96);
    try std.testing.expect(!wide.stacked);
    try std.testing.expectEqual(@as(i32, 500), wide.third_x + wide.third_width);
    try std.testing.expect(wide.first_x >= 0);
}

test "settings action bar pins normal conflict prompt and stacked actions" {
    for ([_]u32{ 96, 120, 144, 168, 192, 288 }) |dpi| {
        const pane_width = scaleForDpi(560, dpi);
        const action_height = scaleForDpi(settings_control_height, dpi);
        const stack_height = scaleForDpi(3 * settings_control_height + 2 * 6, dpi);
        const normal = normalActionRowGeometry(pane_width, action_height, false, dpi);
        const conflict = normalActionRowGeometry(pane_width, action_height, true, dpi);
        try std.testing.expectEqual(pane_width, normal.save_x + scaleForDpi(96, dpi));
        try std.testing.expect(conflict.keep_mine_x >= 0);
        try std.testing.expect(conflict.keep_mine_x + scaleForDpi(112, dpi) + scaleForDpi(settings_action_gap, dpi) <= conflict.use_disk_x);
        try std.testing.expect(conflict.use_disk_x + scaleForDpi(112, dpi) + scaleForDpi(settings_action_gap, dpi) <= conflict.save_x);

        const narrow_width = scaleForDpi(320, dpi);
        const narrow = normalActionRowGeometry(narrow_width, stack_height, true, dpi);
        try std.testing.expect(narrow.stacked);
        try std.testing.expect(narrow.keep_mine_x >= 0);
        try std.testing.expect(narrow.use_disk_x >= 0);
        try std.testing.expect(narrow.save_x >= 0);
        try std.testing.expect(narrow.keep_mine_x + narrow.keep_mine_width <= narrow_width);
        try std.testing.expect(narrow.use_disk_x + narrow.use_disk_width <= narrow_width);
        try std.testing.expect(narrow.save_x + narrow.save_width <= narrow_width);

        const tiny_normal = normalActionRowGeometry(1, action_height, false, dpi);
        try std.testing.expect(tiny_normal.save_x >= 0);
        try std.testing.expect(tiny_normal.save_x + tiny_normal.save_width <= 1);

        var settings: SettingsWindow = .{ .handle = undefined, .dpi = dpi };
        const client_height = scaleForDpi(520, dpi);
        const normal_bar = closePromptLayoutGeometry(&settings, pane_width, client_height);
        try std.testing.expectEqual(scaleForDpi(settings_action_bar_height, dpi), normal_bar.bar_height);
        settings.close_prompt_visible = true;
        const prompt_bar = closePromptLayoutGeometry(&settings, pane_width, client_height);
        try std.testing.expect(!prompt_bar.actions.stacked);
        try std.testing.expect(prompt_bar.bar_height >= normal_bar.bar_height);
        const stacked = closePromptLayoutGeometry(&settings, scaleForDpi(320, dpi), client_height);
        try std.testing.expect(stacked.actions.stacked);
        try std.testing.expect(stacked.bar_height > prompt_bar.bar_height);
        try std.testing.expect(stacked.actions_top + stacked.actions.third_y + stacked.actions.button_height <= stacked.bar_height);

        const short_height = scaleForDpi(100, dpi);
        const short = closePromptLayoutGeometry(&settings, scaleForDpi(320, dpi), short_height);
        try std.testing.expect(short.bar_height <= short_height);
        try std.testing.expect(short.actions_top + short.actions.third_y + short.actions.button_height <= short.bar_height);
    }

    // The real minimum client size is DPI-scaled: `WM_GETMINMAXINFO` sets
    // `ptMinTrackSize` from `px(720)` / `px(520)`. Assert a *positive* form
    // viewport at that actual floor for every DPI — `top <= bottom` alone is
    // satisfied by an empty viewport, which would clip every control to an
    // empty region.
    for ([_]u32{ 96, 120, 144, 168, 192, 288 }) |dpi| {
        var floor: SettingsWindow = .{
            .handle = undefined,
            .dpi = dpi,
            .close_prompt_visible = true,
        };
        const enforced: RECT = .{
            .left = 0,
            .top = 0,
            .right = scaleForDpi(720, dpi),
            .bottom = scaleForDpi(520, dpi),
        };
        try std.testing.expect(
            settingsContentViewportTop(&floor, enforced) <
                settingsContentViewportBottom(&floor, enforced),
        );
    }

    // Degenerate probe: a client smaller than the enforced minimum (only
    // reachable if `cappedMinimum` clamps to a very short work area) must
    // still not invert the viewport.
    var minimum: SettingsWindow = .{ .handle = undefined, .dpi = 288, .close_prompt_visible = true };
    const client: RECT = .{ .left = 0, .top = 0, .right = 720, .bottom = 520 };
    const pane = paneBounds(&minimum, client);
    try std.testing.expect(closePromptLayoutGeometry(&minimum, pane.width, client.bottom).actions.stacked);
    try std.testing.expect(settingsContentViewportTop(&minimum, client) <= settingsContentViewportBottom(&minimum, client));
}

test "settings checkbox and label classification agrees with form model" {
    var controls = [_]bool{false} ** settings_clipped_control_count;
    var labels = [_]bool{false} ** settings_label_specs.len;
    for (std.enums.values(Section)) |section| for (formItemsForSection(section)) |item| {
        try std.testing.expect(!controls[item.control_index]);
        controls[item.control_index] = true;
        try std.testing.expectEqual(settings_control_specs[item.control_index].role == .check_box, item.checkbox);
        if (item.label_index) |index| {
            try std.testing.expect(!labels[index]);
            labels[index] = true;
            try std.testing.expectEqual(item.checkbox, labelIndexIsCheckbox(index));
        }
    };
    for (controls) |seen| try std.testing.expect(seen);
    for (labels) |seen| try std.testing.expect(seen);
}

const SettingsFieldRects = struct { label: RECT, control: RECT };

fn settingsFieldRects(index: usize, pane_width: i32, dpi: u32) SettingsFieldRects {
    const columns = settingsColumnCount(pane_width, dpi);
    const gap = scaleForDpi(settings_column_gap, dpi);
    const available_lane_width = @divTrunc(pane_width - (if (columns == 2) gap else 0), @as(i32, @intCast(columns)));
    const lane_width = @min(available_lane_width, scaleForDpi(settings_field_max_width, dpi));
    const column: i32 = @intCast(index % columns);
    const row: i32 = @intCast(index / columns);
    const left = column * (lane_width + gap);
    const label_top = row * scaleForDpi(settings_field_row_pitch, dpi);
    const control_top = label_top + scaleForDpi(settings_field_label_offset, dpi);
    return .{
        .label = .{
            .left = left,
            .top = label_top,
            .right = left + lane_width,
            .bottom = label_top + scaleForDpi(settings_field_label_height, dpi),
        },
        .control = .{
            .left = left,
            .top = control_top,
            .right = left + lane_width,
            .bottom = control_top + scaleForDpi(settings_control_height, dpi),
        },
    };
}

fn settingsFormItemRects(items: []const FormItem, pane_width: i32, dpi: u32, output: []SettingsFieldRects) void {
    std.debug.assert(output.len >= items.len);
    const columns = settingsColumnCount(pane_width, dpi);
    const row_pitch = scaleForDpi(settings_field_row_pitch, dpi);
    const control_height = scaleForDpi(settings_control_height, dpi);
    const checkbox_pitch = control_height + scaleForDpi(settings_metrics.space_2, dpi);
    const group_gap = scaleForDpi(settings_field_group_gap, dpi);
    var top: i32 = 0;
    var start: usize = 0;
    while (start < items.len) {
        var end = start + 1;
        while (end < items.len and items[end].checkbox == items[start].checkbox) : (end += 1) {}
        if (items[start].checkbox) {
            const lane = settingsFieldRects(0, pane_width, dpi);
            const control_top = top + if (items[start].label_index != null) scaleForDpi(settings_field_label_offset, dpi) else 0;
            for (start..end) |index| {
                const item_top = control_top + @as(i32, @intCast(index - start)) * checkbox_pitch;
                output[index] = .{
                    .label = .{ .left = lane.label.left, .top = top, .right = lane.label.right, .bottom = top + scaleForDpi(settings_field_label_height, dpi) },
                    .control = .{ .left = lane.control.left, .top = item_top, .right = lane.control.right, .bottom = item_top + control_height },
                };
            }
            top = control_top + @as(i32, @intCast(end - start - 1)) * checkbox_pitch + control_height + group_gap;
        } else {
            for (start..end) |index| {
                output[index] = settingsFieldRects(index - start, pane_width, dpi);
                output[index].label.top += top;
                output[index].label.bottom += top;
                output[index].control.top += top;
                output[index].control.bottom += top;
            }
            top += @as(i32, @intCast((end - start + columns - 1) / columns)) * row_pitch;
        }
        start = end;
    }
}

fn settingsContentExtent(rects: []const RECT, bottom_padding: i32) i32 {
    var bottom: i32 = 0;
    for (rects) |rect| bottom = @max(bottom, rect.bottom);
    return bottom + @max(0, bottom_padding);
}

const SettingsScrollGeometry = struct {
    max_position: i32,
    page: u32,
    nmax: i32,
};

fn settingsScrollGeometry(content_extent: i32, viewport_height: i32) SettingsScrollGeometry {
    const extent = @max(0, content_extent);
    const viewport = @max(1, viewport_height);
    const page_i32 = @min(viewport, @max(1, extent));
    return .{
        .max_position = if (extent > viewport) extent - viewport else 0,
        .page = @intCast(page_i32),
        .nmax = if (extent > 0) extent - 1 else 0,
    };
}

fn confirmedStaAllowsCustomUiaProviders(confirmed_sta: bool) bool {
    return confirmed_sta;
}

fn viewportRegionIsFullyClipped(width: i32, clip_top: i32, clip_bottom: i32) bool {
    return width == 0 or clip_top == clip_bottom;
}

test "settings viewport exposes partially clipped controls as onscreen" {
    try std.testing.expect(viewportRegionIsFullyClipped(100, 20, 20));
    try std.testing.expect(viewportRegionIsFullyClipped(0, 0, 10));
    try std.testing.expect(!viewportRegionIsFullyClipped(100, 20, 21));
    try std.testing.expect(!viewportRegionIsFullyClipped(100, 0, 40));
}

test "settings custom UIA providers require confirmed STA initialization" {
    try std.testing.expect(!confirmedStaAllowsCustomUiaProviders(false));
    try std.testing.expect(confirmedStaAllowsCustomUiaProviders(true));
}

fn clipChildToViewport(parent: HWND, child: ?HWND, viewport_top: i32, viewport_bottom: i32) bool {
    const hwnd = child orelse return true;
    var rect: RECT = undefined;
    if (sys.GetWindowRect(hwnd, &rect) == 0) return false;
    var origin: POINT = .{ .x = rect.left, .y = rect.top };
    if (sys.ScreenToClient(parent, &origin) == 0) return false;
    const width = @max(0, rect.right - rect.left);
    const height = @max(0, rect.bottom - rect.top);
    const clip_top = std.math.clamp(viewport_top - origin.y, 0, height);
    const clip_bottom = std.math.clamp(viewport_bottom - origin.y, clip_top, height);
    if (clip_top == 0 and clip_bottom == height) {
        _ = SetWindowRgn(hwnd, null, 0);
        return false;
    }
    const fully_clipped = viewportRegionIsFullyClipped(width, clip_top, clip_bottom);
    const region = CreateRectRgn(0, clip_top, width, clip_bottom) orelse return false;
    if (SetWindowRgn(hwnd, region, 0) == 0) {
        _ = DeleteObject(region);
        return false;
    }
    return fully_clipped;
}

test "settings scrollbar thumb and maximum cover real extents" {
    const rects = [_]RECT{
        .{ .left = 0, .top = 0, .right = 320, .bottom = 16 },
        .{ .left = 0, .top = 20, .right = 320, .bottom = 52 },
        .{ .left = 0, .top = 84, .right = 320, .bottom = 244 },
    };
    const extent = settingsContentExtent(&rects, settings_content_bottom_padding);
    try std.testing.expectEqual(@as(i32, 260), extent);
    for ([_]i32{ 0, 1, 64, extent, 1024 }) |content| for ([_]i32{ 1, 32, 128, 512, 2048 }) |viewport| {
        const scroll = settingsScrollGeometry(content, viewport);
        const page: i32 = @intCast(scroll.page);
        try std.testing.expectEqual(@max(0, content - 1), scroll.nmax);
        try std.testing.expectEqual(@min(viewport, @max(1, content)), page);
        try std.testing.expectEqual(@max(0, content - viewport), scroll.max_position);
        try std.testing.expect(scroll.max_position + page >= content);
    };
}

fn closePromptMeasuredHeight(self: *SettingsWindow, pane_width: i32) i32 {
    const minimum = self.px(20);
    if (!self.close_prompt_visible) return minimum;
    if (self.close_prompt_measure_width == pane_width and
        self.close_prompt_measure_dpi == self.dpi and
        self.close_prompt_measure_saving == self.save_in_flight and
        self.close_prompt_measure_height > 0)
    {
        return self.close_prompt_measure_height;
    }
    const hwnd = self.hwnd orelse return minimum;
    const hdc = GetDC(hwnd) orelse return minimum;
    defer _ = ReleaseDC(hwnd, hdc);
    const previous_font = if (self.emphasis_font) |font| SelectObject(hdc, font) else null;
    defer {
        if (previous_font) |font| _ = sys.SelectObject(hdc, font);
    }

    var text_w: [256]u16 = undefined;
    const text = std.mem.span(utf8ToW(&text_w, closePromptText(self.save_in_flight)));
    var measure = RECT{
        .left = 0,
        .top = 0,
        .right = @max(1, pane_width),
        .bottom = 0,
    };
    _ = sys.DrawTextW(
        hdc,
        text.ptr,
        @intCast(text.len),
        &measure,
        DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX,
    );
    const height = @max(minimum, measure.bottom - measure.top);
    self.close_prompt_measure_width = pane_width;
    self.close_prompt_measure_dpi = self.dpi;
    self.close_prompt_measure_saving = self.save_in_flight;
    self.close_prompt_measure_height = height;
    return height;
}

const ClosePromptLayoutGeometry = struct {
    actions: ActionRowGeometry,
    normal_actions: NormalActionRowGeometry,
    prompt_height: i32,
    bar_height: i32,
    prompt_top: i32,
    actions_top: i32,
};

fn closePromptLayoutGeometry(self: *SettingsWindow, pane_width: i32, client_height: i32) ClosePromptLayoutGeometry {
    const available_height = @max(0, client_height);
    const desired_padding = self.px(settings_action_padding);
    if (!self.close_prompt_visible) {
        const conflict_visible = self.active_conflict_field != null or self.active_owned_conflict_field != null;
        const preferred_actions = normalActionRowGeometry(
            pane_width,
            self.px(3 * settings_control_height + 2 * 6),
            conflict_visible,
            self.dpi,
        );
        const preferred_span = preferred_actions.save_y + preferred_actions.button_height;
        const bar_height = @min(
            available_height,
            @max(self.px(settings_action_bar_height), 2 * desired_padding + preferred_span),
        );
        const padding = @min(desired_padding, @divTrunc(bar_height, 4));
        const normal_actions = normalActionRowGeometry(
            pane_width,
            @max(0, bar_height - 2 * padding),
            conflict_visible,
            self.dpi,
        );
        return .{
            .actions = closeActionRowGeometry(pane_width, 0, self.dpi),
            .normal_actions = normal_actions,
            .prompt_height = 0,
            .bar_height = bar_height,
            .prompt_top = padding,
            .actions_top = padding,
        };
    }

    const padding = @min(desired_padding, @divTrunc(available_height, 4));
    const actions = closeActionRowGeometry(
        pane_width,
        @max(0, available_height - 2 * padding),
        self.dpi,
    );
    const action_span = if (actions.stacked)
        actions.third_y + actions.button_height
    else
        actions.button_height;
    const prompt_width = if (actions.stacked)
        pane_width
    else
        @max(1, actions.first_x - self.px(settings_action_gap));
    const measured_prompt_height = closePromptMeasuredHeight(self, prompt_width);
    if (actions.stacked) {
        const remaining = @max(0, available_height - 2 * padding - action_span);
        const prompt_height = @min(measured_prompt_height, @max(0, remaining - self.px(settings_action_gap)));
        const prompt_gap = if (prompt_height > 0) @min(self.px(settings_action_gap), remaining - prompt_height) else 0;
        const actions_top = padding + prompt_height + prompt_gap;
        return .{
            .actions = actions,
            .normal_actions = normalActionRowGeometry(pane_width, 0, false, self.dpi),
            .prompt_height = prompt_height,
            .bar_height = actions_top + action_span + padding,
            .prompt_top = padding,
            .actions_top = actions_top,
        };
    }
    const prompt_height = @min(measured_prompt_height, @max(0, available_height - 2 * padding));
    const row_height = @max(actions.button_height, prompt_height);
    return .{
        .actions = actions,
        .normal_actions = normalActionRowGeometry(pane_width, 0, false, self.dpi),
        .prompt_height = prompt_height,
        .bar_height = @min(available_height, 2 * padding + row_height),
        .prompt_top = padding + @divTrunc(row_height - prompt_height, 2),
        .actions_top = padding + @divTrunc(row_height - actions.button_height, 2),
    };
}

fn settingsContentViewportTop(self: *SettingsWindow, client_rect: RECT) i32 {
    const rail = sectionRailGeometry(client_rect.bottom - client_rect.top, self.dpi);
    return rail.top_pad + self.px(settings_form_viewport_top);
}

const PaneBounds = struct { left: i32, right: i32, width: i32 };

fn paneBounds(self: *const SettingsWindow, client_rect: RECT) PaneBounds {
    const client_width = @max(0, client_rect.right - client_rect.left);
    const padding = self.px(settings_pane_padding);
    const left = @min(self.px(settings_rail_width) + padding, client_width);
    const right = @max(left, client_width - @min(padding, client_width));
    return .{ .left = left, .right = right, .width = right - left };
}

fn settingsContentViewportBottom(self: *SettingsWindow, client_rect: RECT) i32 {
    const pane = paneBounds(self, client_rect);
    const action_bar = closePromptLayoutGeometry(self, pane.width, client_rect.bottom - client_rect.top);
    return @max(settingsContentViewportTop(self, client_rect), client_rect.bottom - action_bar.bar_height - self.px(settings_pane_padding));
}

fn measureStaticTextHeight(self: *SettingsWindow, text_opt: ?HWND, width: i32) i32 {
    const text = text_opt orelse return 0;
    var buffer: [2048:0]u16 = undefined;
    const length = GetWindowTextW(text, &buffer, @intCast(buffer.len));
    if (length <= 0) return 0;
    const parent = self.hwnd orelse return 0;
    const hdc = GetDC(parent) orelse return 0;
    defer _ = ReleaseDC(parent, hdc);
    const previous = if (self.ui_font) |font| SelectObject(hdc, font) else null;
    defer {
        if (previous) |font| _ = SelectObject(hdc, font);
    }
    var measure: RECT = .{ .left = 0, .top = 0, .right = @max(1, width), .bottom = 0 };
    _ = DrawTextW(hdc, &buffer, length, &measure, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
    return @max(self.px(20), measure.bottom - measure.top);
}

fn isComboControl(self: *const SettingsWindow, hwnd: HWND) bool {
    for (self.comboControls()) |combo| if (combo == hwnd) return true;
    return false;
}

fn layoutChildren(self: *SettingsWindow) void {
    const hwnd = self.hwnd orelse return;
    var rect: RECT = undefined;
    if (GetClientRect(hwnd, &rect) == 0) return;
    const position_flags = SWP_NOREDRAW | SWP_NOZORDER | SWP_NOACTIVATE;

    const rail_width = self.px(settings_rail_width);
    const rail_padding = self.px(settings_rail_padding_x);
    const pane_padding = self.px(settings_pane_padding);
    const rail_geometry = sectionRailGeometry(rect.bottom - rect.top, self.dpi);
    var rail_y = rail_geometry.top_pad;
    for (std.enums.values(Section)) |section| {
        if (self.sectionButton(section)) |button| {
            _ = SetWindowPos(button, null, rail_padding, rail_y, rail_width - 2 * rail_padding, rail_geometry.button_height, position_flags);
        }
        rail_y += rail_geometry.button_height + rail_geometry.gap;
    }

    const pane = paneBounds(self, rect);
    const pane_left = pane.left;
    const pane_width = pane.width;
    const pane_top = rail_geometry.top_pad;
    const action_bar = closePromptLayoutGeometry(self, pane_width, rect.bottom - rect.top);
    const action_bar_top = rect.bottom - action_bar.bar_height;
    const viewport_top = pane_top + self.px(settings_form_viewport_top);
    const viewport_bottom = @max(viewport_top, action_bar_top - pane_padding);
    self.proof_viewport_top = viewport_top;
    self.proof_viewport_bottom = viewport_bottom;
    const viewport_height = @max(0, viewport_bottom - viewport_top);

    const prose_width = @min(pane_width, self.px(settings_prose_max_width));
    if (self.text_header) |text| _ = SetWindowPos(text, null, pane_left, pane_top, prose_width, self.px(settings_header_title_height), position_flags);
    if (self.text_summary) |text| _ = SetWindowPos(text, null, pane_left, pane_top + self.px(settings_header_summary_top), prose_width, self.px(settings_header_summary_height), position_flags);

    const form_items = self.formItems();
    var item_rects: [settings_max_form_items]SettingsFieldRects = undefined;
    var extent_rects: [settings_max_form_items * 2 + 1]RECT = undefined;
    var extent_count: usize = 0;
    settingsFormItemRects(form_items, pane_width, self.dpi, item_rects[0..form_items.len]);
    for (form_items, 0..) |item, index| {
        if (self.controlHwnd(item.control_index) == null) continue;
        if (item.label_index != null) {
            extent_rects[extent_count] = item_rects[index].label;
            extent_count += 1;
        }
        extent_rects[extent_count] = item_rects[index].control;
        extent_count += 1;
    }

    var help_rect: ?RECT = null;
    if (self.active_section == .keybindings or self.active_section == .advanced) {
        const help_top = self.px(settings_field_row_pitch);
        const help_width = @min(pane_width, self.px(settings_prose_max_width));
        const help_height = measureStaticTextHeight(self, self.text_help, help_width);
        if (help_height > 0) {
            help_rect = .{ .left = 0, .top = help_top, .right = help_width, .bottom = help_top + help_height };
            extent_rects[extent_count] = help_rect.?;
            extent_count += 1;
        }
    }
    const content_extent = settingsContentExtent(extent_rects[0..extent_count], self.px(settings_content_bottom_padding));
    const scroll_geometry = settingsScrollGeometry(content_extent, viewport_height);
    self.content_scroll_max = scroll_geometry.max_position;
    self.content_scroll_y = std.math.clamp(self.content_scroll_y, 0, self.content_scroll_max);
    const scroll_info: SCROLLINFO = .{
        .cbSize = @sizeOf(SCROLLINFO),
        .fMask = SIF_RANGE | SIF_PAGE | SIF_POS,
        .nMin = 0,
        .nMax = scroll_geometry.nmax,
        .nPage = scroll_geometry.page,
        .nPos = self.content_scroll_y,
        .nTrackPos = 0,
    };
    _ = SetScrollInfo(hwnd, SB_VERT, &scroll_info, 1);
    _ = ShowScrollBar(hwnd, SB_VERT, @intFromBool(self.content_scroll_max > 0));

    for (form_items, 0..) |item, index| {
        const control = self.controlHwnd(item.control_index) orelse continue;
        const geometry = item_rects[index];
        if (item.label_index) |label_index| if (self.field_labels[label_index]) |label| {
            _ = SetWindowPos(
                label,
                null,
                pane_left + geometry.label.left,
                viewport_top + geometry.label.top - self.content_scroll_y,
                geometry.label.right - geometry.label.left,
                geometry.label.bottom - geometry.label.top,
                position_flags,
            );
        };
        _ = SetWindowPos(
            control,
            null,
            pane_left + geometry.control.left,
            viewport_top + geometry.control.top - self.content_scroll_y,
            geometry.control.right - geometry.control.left,
            if (isComboControl(self, control)) self.px(settings_combo_popup_height) else self.px(settings_control_height),
            position_flags,
        );
    }
    if (help_rect) |help| if (self.text_help) |text| {
        _ = SetWindowPos(
            text,
            null,
            pane_left + help.left,
            viewport_top + help.top - self.content_scroll_y,
            help.right - help.left,
            help.bottom - help.top,
            position_flags,
        );
    };
    if (self.text_help) |text| _ = ShowWindow(text, if (help_rect != null) SW_SHOWNORMAL else SW_HIDE);

    const row_top = action_bar_top + action_bar.actions_top;
    const action_gap = self.px(settings_action_gap);
    const normal_actions = action_bar.normal_actions;
    if (self.btn_save) |button| _ = SetWindowPos(button, null, pane_left + normal_actions.save_x, row_top + normal_actions.save_y, normal_actions.save_width, normal_actions.button_height, position_flags);
    if (self.btn_conflict_keep) |button| _ = SetWindowPos(button, null, pane_left + normal_actions.keep_mine_x, row_top + normal_actions.keep_mine_y, normal_actions.keep_mine_width, normal_actions.button_height, position_flags);
    if (self.btn_conflict_use_disk) |button| _ = SetWindowPos(button, null, pane_left + normal_actions.use_disk_x, row_top + normal_actions.use_disk_y, normal_actions.use_disk_width, normal_actions.button_height, position_flags);
    if (self.text_status) |text| _ = SetWindowPos(text, null, pane_left, row_top + self.px(6), @max(0, normal_actions.status_right), self.px(20), position_flags);

    const close_actions = action_bar.actions;
    const close_top = action_bar_top + action_bar.actions_top;
    const prompt_width = if (close_actions.stacked) pane_width else @max(0, close_actions.first_x - action_gap);
    if (self.text_close_prompt) |text| _ = SetWindowPos(text, null, pane_left, action_bar_top + action_bar.prompt_top, prompt_width, action_bar.prompt_height, position_flags);
    if (self.btn_close_save) |button| _ = SetWindowPos(button, null, pane_left + close_actions.first_x, close_top, close_actions.first_width, close_actions.button_height, position_flags);
    if (self.btn_close_discard) |button| _ = SetWindowPos(button, null, pane_left + close_actions.second_x, close_top + close_actions.second_y, close_actions.second_width, close_actions.button_height, position_flags);
    if (self.btn_close_keep_editing) |button| _ = SetWindowPos(button, null, pane_left + close_actions.third_x, close_top + close_actions.third_y, close_actions.third_width, close_actions.button_height, position_flags);

    var active_clipped_controls = [_]bool{false} ** settings_clipped_control_count;
    for (form_items) |item| active_clipped_controls[item.control_index] = true;
    for (0..settings_clipped_control_count) |index| {
        const control = self.controlHwnd(index);
        const region_fully_clipped = clipChildToViewport(hwnd, control, viewport_top, viewport_bottom);
        const fully_clipped = !active_clipped_controls[index] or region_fully_clipped;
        if (self.control_uia_providers[index]) |provider| provider.setViewportFullyClipped(fully_clipped);
    }
    const help_region_fully_clipped = clipChildToViewport(hwnd, self.text_help, viewport_top, viewport_bottom);
    const help_fully_clipped = help_rect == null or help_region_fully_clipped;
    if (self.text_uia_providers[4]) |provider| provider.setViewportFullyClipped(help_fully_clipped);
    var active_labels = [_]bool{false} ** settings_label_specs.len;
    for (form_items) |item| {
        if (item.label_index) |index| active_labels[index] = true;
    }
    for (self.field_labels, 0..) |label, index| {
        const region_fully_clipped = clipChildToViewport(hwnd, label, viewport_top, viewport_bottom);
        const fully_clipped = !active_labels[index] or region_fully_clipped;
        if (self.text_uia_providers[index + 5]) |provider| provider.setViewportFullyClipped(fully_clipped);
    }
    self.proof_layout_redraw_succeeded = RedrawWindow(hwnd, null, null, RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_ERASE) != 0;
}

fn settingsTextProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const owner = if (sys.GetParent(hwnd)) |parent| recoverOwner(parent) else null;
    if (owner) |settings| {
        const previous = settings.text_uia_prev_proc;
        if (settings.textIndex(hwnd)) |index| {
            if (msg == WM_GETOBJECT) {
                if (settings.text_uia_providers[index]) |provider| {
                    if (win32_uia.returnSettingsControlProvider(hwnd, wParam, lParam, provider)) |result| return result;
                }
            }
            if (msg == WM_NCDESTROY) {
                if (settings.text_uia_providers[index]) |provider| provider.detach();
                if (previous) |proc| {
                    _ = sys.SetWindowLongPtrW(hwnd, GWLP_WNDPROC, @as(LONG_PTR, @intCast(@intFromPtr(proc))));
                    return sys.CallWindowProcW(proc, hwnd, msg, wParam, lParam);
                }
            }
        }
        if (previous) |proc| return sys.CallWindowProcW(proc, hwnd, msg, wParam, lParam);
    }
    return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn settingsControlProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const owner = if (sys.GetParent(hwnd)) |parent| recoverOwner(parent) else null;
    if (owner) |settings| {
        if (settings.controlIndex(hwnd)) |index| {
            const previous = settings.control_uia_prev_procs[index];
            if (msg == WM_GETOBJECT) {
                if (settings.control_uia_providers[index]) |provider| {
                    if (win32_uia.returnSettingsControlProvider(hwnd, wParam, lParam, provider)) |result| return result;
                }
            }
            if (msg == WM_NCDESTROY) {
                if (settings.control_uia_providers[index]) |provider| provider.detach();
                if (previous) |proc| {
                    _ = sys.SetWindowLongPtrW(hwnd, GWLP_WNDPROC, @as(LONG_PTR, @intCast(@intFromPtr(proc))));
                    return sys.CallWindowProcW(proc, hwnd, msg, wParam, lParam);
                }
            }
            if (previous) |proc| {
                const result = sys.CallWindowProcW(proc, hwnd, msg, wParam, lParam);
                if (msg == WM_SETFOCUS) {
                    if (settings.control_uia_providers[index]) |provider| provider.raiseFocusChanged();
                }
                return result;
            }
        }
    }
    return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn shouldDrawSettingsSectionFocusRing(selected: bool, focused: bool) bool {
    _ = selected;
    return focused;
}

test "settings section focus ring follows focus, not selection" {
    try std.testing.expect(!shouldDrawSettingsSectionFocusRing(true, false));
    try std.testing.expect(shouldDrawSettingsSectionFocusRing(false, true));
}

fn paintSettingsSectionButton(hwnd: HWND, settings: *SettingsWindow) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);
    var rect: RECT = undefined;
    if (GetClientRect(hwnd, &rect) == 0) return;
    const colors = settings.theme_adapter.colors;
    const selected = SendMessageW(hwnd, BM_GETCHECK, 0, 0) == BST_CHECKED;
    const pressed = (SendMessageW(hwnd, BM_GETSTATE, 0, 0) & BST_PUSHED) != 0;
    const hovered = settings.section_hovered == hwnd;
    const focused = shouldDrawSettingsSectionFocusRing(selected, GetFocus() == hwnd);
    const fill_color = if (selected or pressed)
        colors.selection_bg
    else if (hovered and !colors.high_contrast)
        colors.button_bg
    else
        colors.rail_bg;
    const fill_brush = CreateSolidBrush(fill_color) orelse return;
    defer _ = DeleteObject(fill_brush);
    _ = FillRect(hdc, &rect, fill_brush);

    if (selected) {
        if (colors.high_contrast) {
            const border = CreateSolidBrush(colors.selection_text) orelse return;
            defer _ = DeleteObject(border);
            _ = FrameRect(hdc, &rect, border);
        } else {
            const pill_width = @max(1, settings.px(settings_metrics.stroke_emphasis));
            const pill_height = @min(rect.bottom - rect.top, settings.px(settings_metrics.space_6));
            const pill_top = rect.top + @divTrunc(rect.bottom - rect.top - pill_height, 2);
            const accent = CreateSolidBrush(colors.accent) orelse return;
            defer _ = DeleteObject(accent);
            const pill: RECT = .{ .left = rect.left, .top = pill_top, .right = rect.left + pill_width, .bottom = pill_top + pill_height };
            _ = FillRect(hdc, &pill, accent);
        }
    }

    var label: [64:0]u16 = undefined;
    const label_len = GetWindowTextW(hwnd, &label, @intCast(label.len));
    var text_rect = rect;
    text_rect.left += settings.px(settings_pane_padding);
    const font = if (selected) settings.emphasis_font else settings.ui_font;
    const previous_font = if (font) |value| SelectObject(hdc, value) else null;
    defer {
        if (previous_font) |value| _ = SelectObject(hdc, value);
    }
    _ = SetBkMode(hdc, TRANSPARENT);
    _ = SetTextColor(
        hdc,
        if (selected or pressed) colors.selection_text else if (colors.high_contrast) colors.edit_text else colors.text,
    );
    if (label_len > 0) _ = DrawTextW(hdc, &label, label_len, &text_rect, DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX);

    if (focused) {
        const ring_color = if (colors.high_contrast and selected) colors.selection_text else colors.focus_ring;
        const ring = CreateSolidBrush(ring_color) orelse return;
        defer _ = DeleteObject(ring);
        var focus_rect = rect;
        const inset = settings.px(settings_metrics.space_1);
        focus_rect.left += inset;
        focus_rect.top += inset;
        focus_rect.right -= inset;
        focus_rect.bottom -= inset;
        var layer: i32 = 0;
        while (layer < @max(1, settings.px(settings_metrics.stroke_focus)) and focus_rect.right > focus_rect.left and focus_rect.bottom > focus_rect.top) : (layer += 1) {
            _ = FrameRect(hdc, &focus_rect, ring);
            focus_rect.left += 1;
            focus_rect.top += 1;
            focus_rect.right -= 1;
            focus_rect.bottom -= 1;
        }
    }
}

fn settingsSectionButtonProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const owner = if (sys.GetParent(hwnd)) |parent| recoverOwner(parent) else null;
    if (owner) |settings| {
        const previous = settings.section_button_prev_proc;
        if (previous == null) return DefWindowProcW(hwnd, msg, wParam, lParam);
        if (settings.sectionForButton(hwnd)) |section| {
            if (msg == WM_GETOBJECT) {
                if (settings.sectionProvider(section)) |provider| {
                    if (win32_uia.returnSettingsSectionProvider(hwnd, wParam, lParam, provider)) |result| return result;
                }
            }
            if (msg == WM_NCDESTROY) {
                if (settings.sectionProvider(section)) |provider| provider.detach();
                if (previous) |proc| {
                    _ = sys.SetWindowLongPtrW(hwnd, GWLP_WNDPROC, @as(LONG_PTR, @intCast(@intFromPtr(proc))));
                    return sys.CallWindowProcW(proc, hwnd, msg, wParam, lParam);
                }
            }
        }
        switch (msg) {
            WM_SETTINGS_PROOF_KILLFOCUS_COUNT => return @intCast(settings.proof_killfocus_count),
            WM_SETTINGS_PROOF_REDRAW_SUCCEEDED => return @intFromBool(settings.proof_redraw_succeeded),
            WM_SETTINGS_PROOF_UPDATE_PENDING => return @intFromBool(settings.proof_update_pending),
            WM_SETTINGS_PROOF_LIVE_FOCUS_RING => return @intFromBool(GetFocus() == hwnd),
            WM_ERASEBKGND => return 1,
            WM_PAINT => {
                paintSettingsSectionButton(hwnd, settings);
                return 0;
            },
            WM_MOUSEMOVE => {
                if (settings.section_hovered != hwnd) {
                    if (settings.section_hovered) |previous_hover| _ = InvalidateRect(previous_hover, null, 0);
                    settings.section_hovered = hwnd;
                    _ = InvalidateRect(hwnd, null, 0);
                    var tracking: TRACKMOUSEEVENT = .{
                        .cbSize = @sizeOf(TRACKMOUSEEVENT),
                        .dwFlags = TME_LEAVE,
                        .hwndTrack = hwnd,
                        .dwHoverTime = 0,
                    };
                    _ = TrackMouseEvent(&tracking);
                }
            },
            WM_MOUSELEAVE => {
                if (settings.section_hovered == hwnd) settings.section_hovered = null;
                _ = InvalidateRect(hwnd, null, 0);
            },
            BM_SETCHECK, BM_SETSTATE => {
                if (previous) |proc| {
                    const result = CallWindowProcW(proc, hwnd, msg, wParam, lParam);
                    _ = InvalidateRect(hwnd, null, 0);
                    return result;
                }
            },
            WM_SETFOCUS, WM_KILLFOCUS => {
                if (previous) |proc| {
                    const result = CallWindowProcW(proc, hwnd, msg, wParam, lParam);
                    if (msg == WM_KILLFOCUS) {
                        settings.proof_killfocus_count +%= 1;
                        settings.proof_redraw_succeeded = RedrawWindow(hwnd, null, null, RDW_INVALIDATE | RDW_UPDATENOW) != 0;
                        var update_rect: RECT = undefined;
                        settings.proof_update_pending = GetUpdateRect(hwnd, &update_rect, 0) != 0;
                    } else _ = InvalidateRect(hwnd, null, 0);
                    if (msg == WM_SETFOCUS) if (settings.sectionForButton(hwnd)) |section| {
                        if (settings.sectionProvider(section)) |provider| provider.raiseFocusChanged();
                    };
                    return result;
                }
            },
            else => {},
        }
        if (previous) |proc| {
            return CallWindowProcW(proc, hwnd, msg, wParam, lParam);
        }
    }
    return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn wndProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (msg == WM_NCCREATE) {
        const cs: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
        if (cs.lpCreateParams) |ptr| {
            _ = sys.SetWindowLongPtrW(hwnd, GWLP_USERDATA, @intCast(@intFromPtr(ptr)));
        }
    }

    const owner = recoverOwner(hwnd);
    switch (msg) {
        WM_SETTINGS_PROOF_VIEWPORT_TOP => {
            if (owner) |o| return @intCast(o.proof_viewport_top);
            return 0;
        },
        WM_SETTINGS_PROOF_VIEWPORT_BOTTOM => {
            if (owner) |o| return @intCast(o.proof_viewport_bottom);
            return 0;
        },
        WM_SETTINGS_PROOF_SET_FOCUS => {
            if (owner != null and wParam != 0) {
                const target: HWND = @ptrFromInt(wParam);
                if (IsChild(hwnd, target) != 0) {
                    _ = SetFocus(target);
                    return @intFromBool(GetFocus() == target);
                }
            }
            return 0;
        },
        WM_SETTINGS_PROOF_PAINT_COUNT => {
            if (owner) |o| return @intCast(o.proof_paint_count);
            return 0;
        },
        WM_SETTINGS_PROOF_LAYOUT_REDRAW_SUCCEEDED => {
            if (owner) |o| return @intFromBool(o.proof_layout_redraw_succeeded);
            return 0;
        },
        WM_SETTINGS_PROOF_CHILD => {
            if (owner) |o| {
                const index: usize = @intCast(wParam);
                const child = switch (lParam) {
                    0 => if (index < settings_clipped_control_count) o.controlHwnd(index) else null,
                    1 => if (index < o.field_labels.len) o.field_labels[index] else null,
                    2 => o.text_help,
                    else => null,
                };
                if (child) |value| return @intCast(@intFromPtr(value));
            }
            return 0;
        },
        WM_GETOBJECT => {
            if (owner) |o| {
                if (o.section_uia_group) |provider| {
                    if (win32_uia.returnSettingsSectionGroupProvider(hwnd, wParam, lParam, provider)) |result| return result;
                }
            }
            return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            if (owner) |o| {
                o.proof_paint_count +%= 1;
                paint(hwnd, o);
            }
            return 0;
        },
        WM_CTLCOLORMSGBOX,
        WM_CTLCOLOREDIT,
        WM_CTLCOLORLISTBOX,
        WM_CTLCOLORBTN,
        WM_CTLCOLORDLG,
        WM_CTLCOLORSTATIC,
        => {
            if (owner) |o| {
                const hdc: HDC = @ptrFromInt(wParam);
                const child: ?HWND = if (lParam == 0)
                    null
                else
                    @ptrFromInt(@as(usize, @bitCast(lParam)));
                const colors = o.theme_adapter.colors;
                const edit_like = msg == WM_CTLCOLOREDIT or msg == WM_CTLCOLORLISTBOX;
                const background = if (edit_like) colors.edit_bg else if (msg == WM_CTLCOLORBTN)
                    colors.button_bg
                else
                    colors.window_bg;
                const foreground = if (child) |control|
                    if (sys.IsWindowEnabled(control) == 0)
                        colors.disabled_text
                    else if (edit_like)
                        colors.edit_text
                    else if (control == o.text_status)
                        switch (o.nextStatus()) {
                            .raw_validation, .owned_validation => colors.error_text,
                            .conflict, .owned_conflict => colors.text,
                            .none => colors.secondary_text,
                        }
                    else if (msg == WM_CTLCOLORBTN)
                        if (o.controlIndex(control)) |index|
                            if (controlIndexIsCheckbox(index)) colors.secondary_text else colors.button_text
                        else
                            colors.button_text
                    else if (control == o.text_summary or (o.textIndex(control) orelse 0) >= 5)
                        colors.secondary_text
                    else
                        colors.text
                else
                    colors.text;
                _ = sys.SetTextColor(hdc, foreground);
                _ = sys.SetBkColor(hdc, background);
                if (msg == WM_CTLCOLORSTATIC) _ = sys.SetBkMode(hdc, TRANSPARENT);
                if (o.theme_adapter.controlBrush(msg)) |brush| {
                    return pointerLresult(brush);
                }
            }
            return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_DPICHANGED => {
            if (owner) |o| {
                o.dpi = normalizedDpi(@intCast(wParam & 0xFFFF));
                const suggested: *const RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                _ = sys.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                );
                o.recreateUiFont();
                layoutChildren(o);
                _ = sys.InvalidateRect(hwnd, null, 1);
            }
            return 0;
        },
        WM_SETTINGCHANGE, WM_SYSCOLORCHANGE, WM_THEMECHANGED => {
            if (owner) |o| o.themeChanged();
            return 0;
        },
        WM_GETMINMAXINFO => {
            if (owner) |o| {
                const info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
                var min_width = o.px(720);
                var min_height = o.px(520);
                var work_area: RECT = undefined;
                if (windowWorkArea(hwnd, &work_area)) {
                    min_width = cappedMinimum(720, o.dpi, work_area.right - work_area.left);
                    min_height = cappedMinimum(520, o.dpi, work_area.bottom - work_area.top);
                }
                info.ptMinTrackSize.x = min_width;
                info.ptMinTrackSize.y = min_height;
            }
            return 0;
        },
        WM_SIZE => {
            if (owner) |o| layoutChildren(o);
            return 0;
        },
        WM_MOUSEWHEEL => {
            if (owner) |o| {
                const delta: i16 = @bitCast(@as(u16, @truncate(wParam >> 16)));
                const steps = @divTrunc(@as(i32, delta), 120);
                if (steps != 0) o.setContentScroll(o.content_scroll_y - steps * o.px(64));
            }
            return 0;
        },
        WM_VSCROLL => {
            if (owner) |o| {
                const code = wParam & 0xFFFF;
                var client: RECT = undefined;
                const viewport_height = if (GetClientRect(hwnd, &client) != 0)
                    @max(1, settingsContentViewportBottom(o, client) - settingsContentViewportTop(o, client))
                else
                    o.px(240);
                const page = @max(1, viewport_height - o.px(settings_control_height));
                var tracking: SCROLLINFO = .{
                    .cbSize = @sizeOf(SCROLLINFO),
                    .fMask = SIF_TRACKPOS,
                    .nMin = 0,
                    .nMax = 0,
                    .nPage = 0,
                    .nPos = 0,
                    .nTrackPos = o.content_scroll_y,
                };
                if (code == SB_THUMBPOSITION or code == SB_THUMBTRACK) _ = GetScrollInfo(hwnd, SB_VERT, &tracking);
                const next = switch (code) {
                    SB_LINEUP => o.content_scroll_y - o.px(32),
                    SB_LINEDOWN => o.content_scroll_y + o.px(32),
                    SB_PAGEUP => o.content_scroll_y - page,
                    SB_PAGEDOWN => o.content_scroll_y + page,
                    SB_THUMBPOSITION, SB_THUMBTRACK => tracking.nTrackPos,
                    SB_TOP => 0,
                    SB_BOTTOM => o.content_scroll_max,
                    else => o.content_scroll_y,
                };
                o.setContentScroll(next);
            }
            return 0;
        },
        WM_COMMAND => {
            const id: usize = wParam & 0xFFFF;
            const notify: u16 = @intCast((wParam >> 16) & 0xFFFF);
            // IsDialogMessageW maps Escape to IDCANCEL as a synthetic
            // command with no originating control HWND. Do not treat the
            // button's BN_SETFOCUS notification as cancellation, or the
            // conservative default focus immediately dismisses the prompt.
            if (id == BTN_CLOSE_KEEP_EDITING and lParam == 0) {
                if (owner) |o| o.cancelClosePrompt();
                return 0;
            }
            if (lParam != 0 and (notify == EN_SETFOCUS or notify == CBN_SETFOCUS or notify == BN_SETFOCUS)) {
                if (owner) |o| o.ensureControlVisible(@ptrFromInt(@as(usize, @bitCast(lParam))));
            }
            if (clickedButton(id, notify, BTN_OPEN_EDITOR)) {
                if (owner) |o| o.handle.openInEditor(o.handle.ctx);
                return 0;
            }
            if (clickedButton(id, notify, BTN_KEYBINDINGS_EDITOR)) {
                if (owner) |o| o.handle.openInEditor(o.handle.ctx);
                return 0;
            }
            if (clickedButton(id, notify, BTN_SAVE)) {
                if (owner) |o| {
                    const button_enabled = if (o.btn_save) |button| sys.IsWindowEnabled(button) != 0 else false;
                    const button_visible = if (o.btn_save) |button| sys.IsWindowVisible(button) != 0 else false;
                    if (saveCommandCanDispatch(
                        o.close_prompt_visible,
                        o.save_in_flight,
                        o.close_posted,
                        button_enabled,
                        button_visible,
                    )) o.save();
                }
                return 0;
            }
            if (clickedButton(id, notify, BTN_CLOSE_SAVE)) {
                if (owner) |o| o.saveAndClose();
                return 0;
            }
            if (clickedButton(id, notify, BTN_CLOSE_DISCARD)) {
                if (owner) |o| o.discardAndClose();
                return 0;
            }
            if (clickedButton(id, notify, BTN_CLOSE_KEEP_EDITING)) {
                if (owner) |o| o.cancelClosePrompt();
                return 0;
            }
            if (id == BTN_CONFLICT_KEEP and notify == BN_CLICKED) {
                if (owner) |o| {
                    if (o.active_conflict_field) |field| {
                        o.resolveConflict(field, .keep_mine);
                    } else if (o.active_owned_conflict_field) |field| {
                        o.resolveOwnedConflict(field, .keep_mine);
                    }
                }
                return 0;
            }
            if (id == BTN_CONFLICT_USE_DISK and notify == BN_CLICKED) {
                if (owner) |o| {
                    if (o.active_conflict_field) |field| {
                        o.resolveConflict(field, .use_disk);
                    } else if (o.active_owned_conflict_field) |field| {
                        o.resolveOwnedConflict(field, .use_disk);
                    }
                }
                return 0;
            }
            if (id == EDIT_SCROLLBACK and notify == EN_CHANGE) {
                if (owner) |o| o.syncScrollbackFromEdit();
                return 0;
            }
            // These parse into pending._arena; record raw dirtiness immediately
            // so closing a focused edit cannot silently discard text, then
            // defer allocation to EN_KILLFOCUS/Save.
            if (id == EDIT_FONT_FAMILY and notify == EN_CHANGE) {
                if (owner) |o| if (o.edit_font_family) |edit| o.markOwnedTextChanged(.font_family, edit);
                return 0;
            }
            if (id == EDIT_FONT_FAMILY and notify == EN_KILLFOCUS) {
                if (owner) |o| o.syncFontFamilyFromEdit();
                return 0;
            }
            if (id == EDIT_FONT_SIZE and notify == EN_CHANGE) {
                if (owner) |o| o.syncFontSizeFromEdit();
                return 0;
            }
            if (id == EDIT_THEME and notify == EN_CHANGE) {
                if (owner) |o| if (o.edit_theme) |edit| o.markOwnedTextChanged(.theme, edit);
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
            if (id == EDIT_COMMAND and notify == EN_CHANGE) {
                if (owner) |o| if (o.edit_command) |edit| o.markOwnedTextChanged(.command, edit);
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
            if (clickedSection(id, notify)) |section| {
                if (owner) |o| {
                    const source: ?HWND = if (lParam == 0)
                        null
                    else
                        @ptrFromInt(@as(usize, @bitCast(lParam)));
                    if (validatedSectionClickFocusTarget(
                        source,
                        o.sectionButton(section),
                    )) |button| {
                        _ = SetFocus(button);
                    }
                    o.setActiveSection(section);
                }
                return 0;
            }
            return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_CLOSE => {
            if (owner) |o| {
                switch (closeRequestAction(o.hasPendingChanges(), o.close_prompt_visible, o.close_posted)) {
                    .close_now => o.closeNow(hwnd),
                    .show_prompt, .focus_prompt => o.showClosePrompt(),
                    .ignore => {},
                }
            }
            return 0;
        },
        WM_SETTINGS_CLOSE_NOW => {
            if (owner) |o| {
                if (o.close_posted) o.closeNow(hwnd);
            }
            return 0;
        },
        WM_NCDESTROY => {
            // Clear back-pointer; the settings wndproc will no longer
            // dereference a freed owner even if a late paint slips
            // through. `onClosed` fires from closeNow in the
            // user-initiated close path; avoid firing here so
            // `App.deinit → settings_window.deinit` (which destroys
            // the HWND without the user closing it) doesn't re-enter
            // the quit-timer path during teardown.
            if (owner) |o| o.clearChildRefs();
            _ = sys.SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        else => return sys.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn recoverOwner(hwnd: HWND) ?*SettingsWindow {
    const raw = sys.GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(raw)));
}

fn settingsSectionDisconnect(ctx: *anyopaque) win32_uia.HRESULT {
    return (@as(*win32_uia.SettingsSectionProvider, @ptrCast(@alignCast(ctx)))).disconnect();
}

fn settingsSectionRelease(ctx: *anyopaque) void {
    const provider: *win32_uia.SettingsSectionProvider = @ptrCast(@alignCast(ctx));
    _ = win32_uia.SettingsSectionProvider.Release(&provider.base);
}

fn settingsSectionGroupDisconnect(ctx: *anyopaque) win32_uia.HRESULT {
    return (@as(*win32_uia.SettingsSectionGroupProvider, @ptrCast(@alignCast(ctx)))).disconnect();
}

fn settingsSectionGroupRelease(ctx: *anyopaque) void {
    const provider: *win32_uia.SettingsSectionGroupProvider = @ptrCast(@alignCast(ctx));
    _ = win32_uia.SettingsSectionGroupProvider.Release(&provider.base);
}

fn settingsControlDisconnect(ctx: *anyopaque) win32_uia.HRESULT {
    return (@as(*win32_uia.SettingsControlProvider, @ptrCast(@alignCast(ctx)))).disconnect();
}

fn settingsControlRelease(ctx: *anyopaque) void {
    const provider: *win32_uia.SettingsControlProvider = @ptrCast(@alignCast(ctx));
    _ = win32_uia.SettingsControlProvider.Release(&provider.base);
}

fn paint(hwnd: HWND, owner: *SettingsWindow) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = sys.BeginPaint(hwnd, &ps);
    defer _ = sys.EndPaint(hwnd, &ps);

    var rect: RECT = undefined;
    if (sys.GetClientRect(hwnd, &rect) == 0) return;

    const colors = owner.theme_adapter.colors;
    const fallback_brush = sys.GetStockObject(DC_BRUSH);
    const window_brush = owner.theme_adapter.window_brush orelse fallback_brush;
    if (owner.theme_adapter.window_brush == null) {
        _ = sys.SetDCBrushColor(hdc, colors.window_bg);
    }
    _ = sys.FillRect(hdc, &rect, window_brush);

    var rail_rect = rect;
    rail_rect.right = owner.px(settings_rail_width);
    const rail_brush = owner.theme_adapter.rail_brush orelse fallback_brush;
    if (owner.theme_adapter.rail_brush == null) {
        _ = sys.SetDCBrushColor(hdc, colors.rail_bg);
    }
    _ = FillRect(hdc, &rail_rect, rail_brush);

    const rail_separator_brush = CreateSolidBrush(colors.rail_separator) orelse return;
    defer _ = DeleteObject(rail_separator_brush);
    const pane_separator_brush = CreateSolidBrush(colors.pane_separator) orelse return;
    defer _ = DeleteObject(pane_separator_brush);
    const separator_width = @max(1, owner.px(settings_metrics.stroke_hairline));
    const pane = paneBounds(owner, rect);
    const rail_separator: RECT = .{
        .left = owner.px(settings_rail_width) - separator_width,
        .top = rect.top,
        .right = owner.px(settings_rail_width),
        .bottom = rect.bottom,
    };
    _ = FillRect(hdc, &rail_separator, rail_separator_brush);
    const rail_geometry = sectionRailGeometry(rect.bottom - rect.top, owner.dpi);
    const header_separator: RECT = .{
        .left = pane.left,
        .top = rail_geometry.top_pad + owner.px(settings_header_separator_y),
        .right = pane.right,
        .bottom = rail_geometry.top_pad + owner.px(settings_header_separator_y) + separator_width,
    };
    _ = FillRect(hdc, &header_separator, pane_separator_brush);
    const action_bar = closePromptLayoutGeometry(owner, pane.width, rect.bottom - rect.top);
    const action_separator: RECT = .{
        .left = pane.left,
        .top = rect.bottom - action_bar.bar_height,
        .right = pane.right,
        .bottom = rect.bottom - action_bar.bar_height + separator_width,
    };
    _ = FillRect(hdc, &action_separator, pane_separator_brush);
}

fn readEditUtf8(edit: HWND, buf: []u8) ?[]const u8 {
    var buf_w: [edit_text_max_code_units]u16 = undefined;
    const n = sys.GetWindowTextW(edit, &buf_w, @intCast(buf_w.len));
    const written = std.unicode.utf16LeToUtf8(buf, buf_w[0..@intCast(n)]) catch return null;
    return buf[0..written];
}

fn setEditText(edit: HWND, text: []const u8, suppress: *bool) void {
    var buf_w: [edit_text_max_code_units]u16 = undefined;
    const w = utf8ToW(&buf_w, text);
    suppress.* = true;
    _ = sys.SendMessageW(edit, WM_SETTEXT, 0, @bitCast(@intFromPtr(w)));
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

fn commandEql(a: Config.Command, b: Config.Command) bool {
    return switch (a) {
        .shell => |a_value| switch (b) {
            .shell => |b_value| std.mem.eql(u8, a_value, b_value),
            .direct => false,
        },
        .direct => |a_args| switch (b) {
            .shell => false,
            .direct => |b_args| args: {
                if (a_args.len != b_args.len) break :args false;
                for (a_args, b_args) |a_arg, b_arg| {
                    if (!std.mem.eql(u8, a_arg, b_arg)) break :args false;
                }
                break :args true;
            },
        },
    };
}

fn optionalThemeEql(a: ?Config.Theme, b: ?Config.Theme) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.light, b.?.light) and
        std.mem.eql(u8, a.?.dark, b.?.dark);
}

fn optionalCommandEql(a: ?Config.Command, b: ?Config.Command) bool {
    if (a == null or b == null) return a == null and b == null;
    return commandEql(a.?, b.?);
}

fn ownedSettingEql(a: *const Config, b: *const Config, field: OwnedSettingField) bool {
    return switch (field) {
        .font_family => a.@"font-family".equal(b.@"font-family"),
        .theme => optionalThemeEql(a.theme, b.theme),
        .command => optionalCommandEql(a.command, b.command),
    };
}

fn copyOwnedSetting(target: *Config, source: *const Config, field: OwnedSettingField) !void {
    const alloc = target._arena.?.allocator();
    switch (field) {
        .font_family => target.@"font-family" = try source.@"font-family".clone(alloc),
        .theme => target.theme = if (source.theme) |*value| try value.clone(alloc) else null,
        .command => target.command = if (source.command) |*value| try value.clone(alloc) else null,
    }
}

fn writeOwnedSettingValue(writer: *std.Io.Writer, config: *const Config, field: OwnedSettingField) !void {
    switch (field) {
        .font_family => {
            if (config.@"font-family".list.items.len == 0) return writer.writeAll("<default>");
            for (config.@"font-family".list.items, 0..) |family, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.writeAll(family);
            }
        },
        .theme => if (config.theme) |theme| {
            if (std.mem.eql(u8, theme.light, theme.dark)) {
                try writer.writeAll(theme.light);
            } else {
                try writer.print("light:{s},dark:{s}", .{ theme.light, theme.dark });
            }
        } else try writer.writeAll("<default>"),
        .command => if (config.command) |command| {
            try writeCommandForEdit(writer, command);
        } else try writer.writeAll("<auto-detect>"),
    }
}

fn writeOwnedSettingDiffs(
    writer: *std.Io.Writer,
    original: *const Config,
    pending: *const Config,
    dirty: [owned_setting_field_count]bool,
    conflict: [owned_setting_field_count]bool,
) !usize {
    var count: usize = 0;
    for (std.enums.values(OwnedSettingField)) |field| {
        const index = @intFromEnum(field);
        if (!dirty[index] and !conflict[index]) continue;
        try writer.print("{s}: ", .{field.label()});
        try writeOwnedSettingValue(writer, original, field);
        try writer.writeAll(" -> ");
        try writeOwnedSettingValue(writer, pending, field);
        if (conflict[index]) try writer.writeAll(" (conflict)");
        try writer.writeByte('\n');
        count += 1;
    }
    return count;
}

fn utf8ToW(buf: []u16, text: []const u8) [*:0]const u16 {
    std.debug.assert(buf.len > 0);
    if (!std.unicode.utf8ValidateSlice(text)) {
        buf[0] = 0;
        return @ptrCast(buf.ptr);
    }

    const capacity = buf.len - 1;
    var byte_end: usize = 0;
    var utf16_len: usize = 0;
    while (byte_end < text.len) {
        const scalar_len = std.unicode.utf8ByteSequenceLength(text[byte_end]) catch unreachable;
        const codepoint = std.unicode.utf8Decode(text[byte_end .. byte_end + scalar_len]) catch unreachable;
        const unit_len: usize = if (codepoint <= 0xFFFF) 1 else 2;
        if (utf16_len + unit_len > capacity) break;
        utf16_len += unit_len;
        byte_end += scalar_len;
    }

    const written = std.unicode.utf8ToUtf16Le(buf[0..capacity], text[0..byte_end]) catch unreachable;
    std.debug.assert(written == utf16_len);
    buf[written] = 0;
    return @ptrCast(buf.ptr);
}

test "win32_settings: utf8ToW rejects invalid input without a partial prefix" {
    var buf = [_]u16{0xAAAA} ** 8;
    const converted = utf8ToW(&buf, "valid\xFFinvalid");

    try std.testing.expectEqual(@as(usize, 0), std.mem.len(converted));
    try std.testing.expectEqual(@as(u16, 0), buf[0]);
}

test "win32_settings: utf8ToW truncates ASCII for the terminator" {
    var buf: [5]u16 = undefined;
    const converted = utf8ToW(&buf, "abcdef");

    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 'd' }, converted[0..4]);
    try std.testing.expectEqual(@as(u16, 0), buf[4]);
}

test "win32_settings: utf8ToW never splits a supplementary scalar" {
    var too_small = [_]u16{0xAAAA} ** 2;
    const omitted = utf8ToW(&too_small, "🚀");
    try std.testing.expectEqual(@as(usize, 0), std.mem.len(omitted));
    try std.testing.expectEqual(@as(u16, 0), too_small[0]);

    var fits: [3]u16 = undefined;
    const converted = utf8ToW(&fits, "🚀");
    try std.testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("🚀"),
        converted[0..2],
    );
    try std.testing.expectEqual(@as(u16, 0), fits[2]);
}

test "settings pointer result preserves high-bit handle bits" {
    const pointer: *anyopaque = @ptrFromInt(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(LRESULT, -1), pointerLresult(pointer));
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

test "settings action and section buttons activate only on click" {
    try std.testing.expect(clickedButton(BTN_SAVE, BN_CLICKED, BTN_SAVE));
    try std.testing.expect(!clickedButton(BTN_SAVE, BN_SETFOCUS, BTN_SAVE));
    try std.testing.expect(!clickedButton(BTN_SAVE, BN_KILLFOCUS, BTN_SAVE));
    try std.testing.expect(!clickedButton(BTN_OPEN_EDITOR, BN_CLICKED, BTN_SAVE));

    try std.testing.expectEqual(Section.appearance, clickedSection(BTN_SECTION_APPEARANCE, BN_CLICKED).?);
    try std.testing.expectEqual(@as(?Section, null), clickedSection(BTN_SECTION_APPEARANCE, BN_SETFOCUS));
    try std.testing.expectEqual(@as(?Section, null), clickedSection(BTN_SECTION_APPEARANCE, BN_KILLFOCUS));

    const section_hwnd: HWND = @ptrFromInt(1);
    const other_hwnd: HWND = @ptrFromInt(2);
    try std.testing.expectEqual(
        section_hwnd,
        validatedSectionClickFocusTarget(section_hwnd, section_hwnd).?,
    );
    try std.testing.expectEqual(
        @as(?HWND, null),
        validatedSectionClickFocusTarget(null, section_hwnd),
    );
    try std.testing.expectEqual(
        @as(?HWND, null),
        validatedSectionClickFocusTarget(other_hwnd, section_hwnd),
    );
}

test "win32_settings: every tracked field maps to its matching config value" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    var copy = config.shallowClone(std.testing.allocator);
    defer copy.deinit();

    for (std.enums.values(SettingField)) |field| {
        const value = settingValue(&config, field);
        try std.testing.expectEqual(field, std.meta.activeTag(value));
        setSettingValue(&copy, value);
        try std.testing.expect(settingValueEql(value, settingValue(&copy, field)));
    }
}

test "win32_settings: owned snapshots survive source config deinit" {
    var source = try Config.default(std.testing.allocator);
    const source_alloc = source._arena.?.allocator();
    source.command = .{ .shell = try source_alloc.dupeZ(u8, "pwsh.exe -NoLogo") };

    var snapshot = try source.clone(std.testing.allocator);
    defer snapshot.deinit();
    source.deinit();

    const command_value = snapshot.command orelse return error.TestUnexpectedResult;
    const command = switch (command_value) {
        .shell => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("pwsh.exe -NoLogo", command);
}

test "win32_settings: arena-backed settings copy without borrowing source storage" {
    var source = try Config.default(std.testing.allocator);
    const source_alloc = source._arena.?.allocator();
    source.@"font-family" = try parseFontFamilyEditText(source_alloc, "Cascadia Mono, Symbols Nerd Font");
    var theme: Config.Theme = undefined;
    try theme.parseCLI(source_alloc, "light:Day,dark:Night");
    source.theme = theme;
    var command: Config.Command = undefined;
    try command.parseCLI(source_alloc, "direct:pwsh.exe -NoLogo");
    source.command = command;

    var target = try Config.default(std.testing.allocator);
    defer target.deinit();
    for (std.enums.values(OwnedSettingField)) |field| {
        try copyOwnedSetting(&target, &source, field);
        try std.testing.expect(ownedSettingEql(&target, &source, field));
    }
    source.deinit();

    try std.testing.expectEqualStrings("Cascadia Mono", target.@"font-family".list.items[0]);
    try std.testing.expectEqualStrings("Day", target.theme.?.light);
    try std.testing.expectEqualStrings("Night", target.theme.?.dark);
    try std.testing.expect(target.command.? == .direct);
    try std.testing.expectEqualStrings("pwsh.exe", target.command.?.direct[0]);
}

test "win32_settings: arena-backed equality compares semantic content" {
    var a = try Config.default(std.testing.allocator);
    defer a.deinit();
    var b = try Config.default(std.testing.allocator);
    defer b.deinit();

    a.command = .{ .shell = try a._arena.?.allocator().dupeZ(u8, "pwsh.exe") };
    b.command = .{ .shell = try b._arena.?.allocator().dupeZ(u8, "pwsh.exe") };
    try std.testing.expect(ownedSettingEql(&a, &b, .command));
    b.command = .{ .shell = try b._arena.?.allocator().dupeZ(u8, "cmd.exe") };
    try std.testing.expect(!ownedSettingEql(&a, &b, .command));
}

test "win32_settings: advanced diff includes arena-backed-only edits" {
    var original = try Config.default(std.testing.allocator);
    defer original.deinit();
    var pending = try Config.default(std.testing.allocator);
    defer pending.deinit();

    const original_alloc = original._arena.?.allocator();
    original.@"font-family" = try parseFontFamilyEditText(original_alloc, "Cascadia Mono");
    var original_theme: Config.Theme = undefined;
    try original_theme.parseCLI(original_alloc, "Old Theme");
    original.theme = original_theme;
    original.command = .{ .shell = try original_alloc.dupeZ(u8, "cmd.exe") };

    const pending_alloc = pending._arena.?.allocator();
    pending.@"font-family" = try parseFontFamilyEditText(pending_alloc, "JetBrains Mono, Symbols Nerd Font");
    var pending_theme: Config.Theme = undefined;
    try pending_theme.parseCLI(pending_alloc, "light:Day,dark:Night");
    pending.theme = pending_theme;
    var pending_command: Config.Command = undefined;
    try pending_command.parseCLI(pending_alloc, "direct:pwsh.exe -NoLogo");
    pending.command = pending_command;

    const dirty = [_]bool{true} ** owned_setting_field_count;
    var conflict = [_]bool{false} ** owned_setting_field_count;
    conflict[@intFromEnum(OwnedSettingField.theme)] = true;
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try std.testing.expectEqual(
        @as(usize, 3),
        try writeOwnedSettingDiffs(&writer, &original, &pending, dirty, conflict),
    );
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "Font family: Cascadia Mono -> JetBrains Mono, Symbols Nerd Font") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Terminal theme: Old Theme -> light:Day,dark:Night (conflict)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Default command: cmd.exe -> direct:pwsh.exe -NoLogo") != null);
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
    try source.parseCLI(arena.allocator(), "direct:cmd.exe /c \"echo hello\" \"C:\\Program Files\\noctty\"");

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeCommandForEdit(&writer, source);
    try testing.expectEqualStrings(
        "direct:cmd.exe /c \"echo hello\" \"C:\\Program Files\\noctty\"",
        writer.buffered(),
    );

    var round_trip: Config.Command = undefined;
    try round_trip.parseCLI(arena.allocator(), writer.buffered());
    try testing.expect(round_trip == .direct);
    try testing.expectEqual(@as(usize, 4), round_trip.direct.len);
    try testing.expectEqualStrings("echo hello", round_trip.direct[2]);
    try testing.expectEqualStrings("C:\\Program Files\\noctty", round_trip.direct[3]);
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
