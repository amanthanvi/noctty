const std = @import("std");
const win32_types = @import("win32_types.zig");
const ProfileKind = @import("../config/windows_shell_types.zig").ProfileKind;

/// Pack r/g/b bytes into a Win32 COLORREF (0x00BBGGRR).
pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

// ── Overlay mode ────────────────────────────────────────────────────────

pub const HostOverlayMode = enum {
    none,
    command_palette,
    profile,
    search,
    surface_title,
    tab_title,
    tab_overview,
    /// Non-modal Accept/Cancel prompt. Carried by `Host.confirm_payload`
    /// which owns the title / body / button labels / severity and the
    /// accept + cancel callbacks. Replaces the previous `MessageBoxW`
    /// pump-blocking confirms (close-surface, paste-protection).
    confirm,
};

// ── Structs ─────────────────────────────────────────────────────────────

pub const ButtonColors = struct {
    bg: u32,
    border: u32,
    fg: u32,
};

pub const ThemeColors = struct {
    // Chrome surfaces
    chrome_bg: u32,
    chrome_border: u32,
    overlay_bg: u32,
    overlay_border: u32,
    edit_bg: u32,
    edit_frame_bg: u32,
    inspector_bg: u32,

    // Text
    text_primary: u32,
    text_secondary: u32,
    text_disabled: u32,
    edit_fg: u32,
    overlay_label_fg: u32,
    info_fg: u32,
    error_fg: u32,

    // Accent
    accent: u32,
    accent_hover: u32,
    chrome_accent_idle: u32,
    edit_border_unfocused: u32,

    // Buttons - idle
    button_bg: u32,
    button_border: u32,
    button_fg: u32,

    // Buttons - overlay variant
    button_overlay_bg: u32,
    button_overlay_border: u32,
    button_overlay_fg: u32,
    button_chrome_fg: u32,

    // Buttons - active
    button_active_bg: u32,
    button_active_border: u32,
    button_active_fg: u32,

    // Buttons - accept
    button_accept_bg: u32,
    button_accept_border: u32,
    button_accept_fg: u32,

    // Buttons - disabled
    button_disabled_bg: u32,
    button_disabled_border: u32,
    button_disabled_fg: u32,

    // Focus rings
    button_focus_ring: u32,
    button_overlay_focus_ring: u32,
    button_active_focus_ring: u32,
    button_accept_focus_ring: u32,

    // Pane dividers
    pane_divider: u32,
    pane_divider_focused: u32,

    // Whether this is a dark theme (for DWM)
    is_dark: bool,
};

pub const SettingsSystemColors = struct {
    window: u32,
    window_text: u32,
    button_face: u32,
    button_text: u32,
    gray_text: u32,
    highlight: u32,
    highlight_text: u32,
};

pub const SettingsColors = struct {
    window_bg: u32,
    rail_bg: u32,
    text: u32,
    secondary_text: u32,
    disabled_text: u32,
    rail_separator: u32,
    pane_separator: u32,
    accent: u32,
    selection_bg: u32,
    selection_text: u32,
    focus_ring: u32,
    error_text: u32,
    edit_bg: u32,
    edit_text: u32,
    /// The resting frame of a text field (Settings paints its own field
    /// frames; see `win32_settings.paintFieldFrame`).
    field_border: u32,
    button_bg: u32,
    button_text: u32,
    /// Text that acts when clicked, on the pane: the Edit, Copy and Open
    /// actions of an open All settings or Keybindings row. The accent
    /// itself is for indicators (3:1); in the light theme it is under the
    /// 4.5:1 text needs on the pane.
    action_text: u32,
    /// A toggle switch that is on: the track's fill and its thumb
    /// (`win32_settings.paintToggle`). The thumb is cut out in the pane's
    /// colour, which keeps 3:1 against the accent in both app themes.
    toggle_on_track: u32,
    toggle_on_thumb: u32,
    /// A toggle switch that is off: the track's outline and its thumb.
    toggle_off: u32,
    /// The opacity trackbar's channel and thumb (`win32_settings`'s
    /// `sliderCustomDraw`): the channel in the text fields' resting frame
    /// colour, the thumb in the accent. High Contrast keeps the stock
    /// trackbar, in system colours.
    slider_rail: u32,
    slider_thumb: u32,
    is_dark: bool,
    high_contrast: bool,
};

/// Every pair of Settings colours that Settings itself draws one on the
/// other, or hands Windows for a control through `WM_CTLCOLOR*`, with the
/// contrast it needs (DESIGN.md): 4.5:1 for text, 3:1 for a control's
/// boundary, a state cue or a focus indicator. Exempt, and so not listed:
/// disabled text, and the separators (`rail_separator`, `pane_separator`, a
/// list row's rule), which are decoration and carry no state. Themed controls (`DarkMode_Explorer`, `DarkMode_CFD`) draw in their own
/// colours, which these do not cover. Read off every `SetTextColor`, fill
/// and stroke in `win32_settings.zig`; a new one adds its pair here.
pub const settings_contrast_pairs = [_]struct {
    foreground: []const u8,
    background: []const u8,
    minimum: f64,
    /// Whether High Contrast draws the pair too.
    high_contrast: bool = true,
}{
    // Text: labels, statics and the rail on the pane and the rail; the
    // status line; a selected rail button and an open list row's title;
    // fields and their lists; buttons; the list rows' actions.
    .{ .foreground = "text", .background = "window_bg", .minimum = 4.5 },
    .{ .foreground = "text", .background = "rail_bg", .minimum = 4.5 },
    .{ .foreground = "secondary_text", .background = "window_bg", .minimum = 4.5 },
    .{ .foreground = "secondary_text", .background = "rail_bg", .minimum = 4.5 },
    .{ .foreground = "secondary_text", .background = "edit_bg", .minimum = 4.5 },
    .{ .foreground = "error_text", .background = "window_bg", .minimum = 4.5 },
    .{ .foreground = "selection_text", .background = "selection_bg", .minimum = 4.5 },
    .{ .foreground = "edit_text", .background = "edit_bg", .minimum = 4.5 },
    // High Contrast's rail labels.
    .{ .foreground = "edit_text", .background = "rail_bg", .minimum = 4.5 },
    .{ .foreground = "button_text", .background = "button_bg", .minimum = 4.5 },
    .{ .foreground = "action_text", .background = "window_bg", .minimum = 4.5 },
    // A rail button under the pointer; High Contrast does not fill it.
    .{ .foreground = "text", .background = "button_bg", .minimum = 4.5, .high_contrast = false },
    .{ .foreground = "secondary_text", .background = "button_bg", .minimum = 4.5, .high_contrast = false },
    // Focus rings.
    .{ .foreground = "focus_ring", .background = "window_bg", .minimum = 3.0 },
    .{ .foreground = "focus_ring", .background = "rail_bg", .minimum = 3.0 },
    .{ .foreground = "focus_ring", .background = "button_bg", .minimum = 3.0 },
    // On a selected rail button; High Contrast draws it in the selection's
    // text colour there.
    .{ .foreground = "focus_ring", .background = "selection_bg", .minimum = 3.0, .high_contrast = false },
    // The changed-field marker beside a row.
    .{ .foreground = "accent", .background = "window_bg", .minimum = 3.0 },
    // The selected rail button's pill; High Contrast frames the button in
    // its text colour instead.
    .{ .foreground = "accent", .background = "selection_bg", .minimum = 3.0, .high_contrast = false },
    // The rail's unsaved dot and invalid disc (its "!" is the button's own
    // background on the disc) on each background a rail button has; High
    // Contrast draws them in the text colours.
    .{ .foreground = "accent", .background = "rail_bg", .minimum = 3.0, .high_contrast = false },
    .{ .foreground = "accent", .background = "button_bg", .minimum = 3.0, .high_contrast = false },
    .{ .foreground = "error_text", .background = "rail_bg", .minimum = 3.0, .high_contrast = false },
    .{ .foreground = "error_text", .background = "selection_bg", .minimum = 3.0, .high_contrast = false },
    .{ .foreground = "error_text", .background = "button_bg", .minimum = 3.0, .high_contrast = false },
    // The invalid disc's "!" is text, in the pane's colour on the disc
    // (`win32_settings.sectionMarkerGlyph`). High Contrast draws it in the
    // button's own background, whose pair with the disc's text colour is
    // the text pair above (text on the rail, or the selection's).
    .{ .foreground = "window_bg", .background = "error_text", .minimum = 4.5, .high_contrast = false },
    // A text field's frame: at rest, focused and invalid, on both sides.
    .{ .foreground = "field_border", .background = "window_bg", .minimum = 3.0 },
    .{ .foreground = "field_border", .background = "edit_bg", .minimum = 3.0 },
    .{ .foreground = "accent", .background = "edit_bg", .minimum = 3.0 },
    .{ .foreground = "error_text", .background = "edit_bg", .minimum = 3.0 },
    // Toggle switches.
    .{ .foreground = "toggle_on_track", .background = "window_bg", .minimum = 3.0 },
    .{ .foreground = "toggle_on_thumb", .background = "toggle_on_track", .minimum = 3.0 },
    .{ .foreground = "toggle_off", .background = "window_bg", .minimum = 3.0 },
    // The trackbar's channel shows its range and its thumb the value; High
    // Contrast draws the stock trackbar.
    .{ .foreground = "slider_rail", .background = "window_bg", .minimum = 3.0, .high_contrast = false },
    .{ .foreground = "slider_thumb", .background = "window_bg", .minimum = 3.0, .high_contrast = false },
};

/// Resolve semantic Settings colors. High Contrast deliberately ignores every
/// app-theme token and maps directly to the corresponding Windows system role.
pub fn settingsColors(
    theme: ThemeColors,
    system: SettingsSystemColors,
    high_contrast: bool,
) SettingsColors {
    if (high_contrast) {
        return .{
            .window_bg = system.button_face,
            .rail_bg = system.window,
            .text = system.button_text,
            .secondary_text = system.button_text,
            .disabled_text = system.gray_text,
            // The rail sits on COLOR_WINDOW while panes sit on COLOR_BTNFACE.
            // Use each background's matching system text role for contrast.
            .rail_separator = system.window_text,
            .pane_separator = system.button_text,
            .accent = system.highlight,
            .selection_bg = system.highlight,
            .selection_text = system.highlight_text,
            .focus_ring = system.highlight,
            .error_text = system.button_text,
            .edit_bg = system.window,
            .edit_text = system.window_text,
            .field_border = system.window_text,
            .button_bg = system.button_face,
            .button_text = system.button_text,
            .action_text = system.button_text,
            // High Contrast draws a plain check box, not a switch; these
            // keep the system pairs all the same.
            .toggle_on_track = system.highlight,
            .toggle_on_thumb = system.highlight_text,
            .toggle_off = system.button_text,
            .slider_rail = system.button_text,
            .slider_thumb = system.highlight,
            .is_dark = false,
            .high_contrast = true,
        };
    }
    return .{
        .window_bg = theme.overlay_bg,
        .rail_bg = theme.chrome_bg,
        .text = theme.text_primary,
        .secondary_text = theme.text_secondary,
        .disabled_text = theme.text_disabled,
        .rail_separator = theme.overlay_border,
        .pane_separator = theme.overlay_border,
        .accent = theme.accent,
        .selection_bg = theme.button_active_bg,
        .selection_text = theme.button_active_fg,
        .focus_ring = theme.button_focus_ring,
        .error_text = theme.error_fg,
        .edit_bg = theme.edit_bg,
        .edit_text = theme.edit_fg,
        .field_border = theme.edit_border_unfocused,
        .button_bg = theme.button_bg,
        .button_text = theme.button_fg,
        .action_text = theme.info_fg,
        .toggle_on_track = theme.accent,
        .toggle_on_thumb = theme.overlay_bg,
        .toggle_off = theme.text_secondary,
        .slider_rail = theme.edit_border_unfocused,
        .slider_thumb = theme.accent,
        .is_dark = theme.is_dark,
        .high_contrast = false,
    };
}

pub fn settingsDwmDarkModeValue(colors: SettingsColors) u32 {
    return if (!colors.high_contrast and colors.is_dark) 1 else 0;
}

const HWND = win32_types.HWND;
const E_INVALIDARG: i32 = @bitCast(@as(u32, 0x80070057));
const DWMWA_USE_IMMERSIVE_DARK_MODE_V1: u32 = 19;
const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;
const DWMWA_BORDER_COLOR: u32 = 34;
const DWMWA_CAPTION_COLOR: u32 = 35;
const DWMWA_TEXT_COLOR: u32 = 36;
const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;
const DWMSBT_AUTO: u32 = 0;
const DWMSBT_NONE: u32 = 1;
const DWMSBT_MAINWINDOW: u32 = 2;
const DWMSBT_TRANSIENTWINDOW: u32 = 3;
const DWMSBT_TABBEDWINDOW: u32 = 4;

extern "dwmapi" fn DwmSetWindowAttribute(HWND, u32, *const anyopaque, u32) callconv(.winapi) i32;
extern "uxtheme" fn SetWindowTheme(HWND, ?[*:0]const u16, ?[*:0]const u16) callconv(.winapi) i32;

const WindowKind = enum { host, settings };
const NativeControlTheme = enum { system, explorer_light, explorer_dark };
pub const dwm_color_default: u32 = 0xffff_ffff;
const dwm_color_none: u32 = 0xffff_fffe;

const WindowThemePolicy = struct {
    immersive_dark: u32,
    caption_color: u32,
    text_color: u32,
    backdrop_type: u32,
    native_controls: NativeControlTheme,
};

/// Shared window-kind-aware DWM/native policy. HWND resource ownership and
/// invalidation remain with each window, but Host and Settings cannot diverge
/// on Dark/High Contrast reset semantics.
fn windowThemePolicy(
    kind: WindowKind,
    is_dark: bool,
    high_contrast: bool,
    caption_color: u32,
    text_color: u32,
    backdrop_type: u32,
) WindowThemePolicy {
    if (high_contrast) return .{
        .immersive_dark = 0,
        .caption_color = dwm_color_default,
        .text_color = dwm_color_default,
        .backdrop_type = DWMSBT_NONE,
        .native_controls = .system,
    };
    return .{
        .immersive_dark = @intFromBool(is_dark),
        .caption_color = caption_color,
        .text_color = text_color,
        .backdrop_type = backdrop_type,
        .native_controls = switch (kind) {
            .host => .system,
            .settings => if (is_dark) .explorer_dark else .explorer_light,
        },
    };
}

pub const WindowThemeAdapter = struct {
    pub fn applyHost(
        hwnd: HWND,
        theme: ThemeColors,
        high_contrast: bool,
        caption_color: u32,
        text_color: u32,
        backdrop_type: u32,
        supports_backdrop: bool,
    ) void {
        applyWindow(hwnd, windowThemePolicy(
            .host,
            theme.is_dark,
            high_contrast,
            caption_color,
            text_color,
            backdrop_type,
        ), supports_backdrop);
    }

    /// Show or hide the border Windows 11 draws around a framed window. An
    /// undecorated host keeps the frame for its resize edges and shadow, but
    /// `window-decoration = none` promises no border.
    pub fn setHostBorderVisible(hwnd: HWND, visible: bool) void {
        const color = if (visible) dwm_color_default else dwm_color_none;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, @ptrCast(&color), @sizeOf(u32));
    }

    pub fn applySettings(hwnd: HWND, colors: SettingsColors) void {
        applyWindow(hwnd, windowThemePolicy(
            .settings,
            colors.is_dark,
            colors.high_contrast,
            colors.window_bg,
            colors.text,
            DWMSBT_NONE,
        ), true);
    }

    pub fn applyNativeControl(hwnd: HWND, colors: SettingsColors) void {
        const policy = windowThemePolicy(
            .settings,
            colors.is_dark,
            colors.high_contrast,
            colors.window_bg,
            colors.text,
            DWMSBT_NONE,
        );
        const theme: ?[*:0]const u16 = switch (policy.native_controls) {
            .system => null,
            .explorer_light => std.unicode.utf8ToUtf16LeStringLiteral("Explorer"),
            .explorer_dark => std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        };
        _ = SetWindowTheme(hwnd, theme, null);
    }

    pub fn applyNativeCombo(hwnd: HWND, colors: SettingsColors) void {
        const theme: ?[*:0]const u16 = if (colors.high_contrast)
            null
        else if (colors.is_dark)
            std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_CFD")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Explorer");
        _ = SetWindowTheme(hwnd, theme, null);
    }

    fn applyWindow(hwnd: HWND, policy: WindowThemePolicy, supports_backdrop: bool) void {
        const hr = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            @ptrCast(&policy.immersive_dark),
            @sizeOf(u32),
        );
        if (hr == E_INVALIDARG) _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE_V1,
            @ptrCast(&policy.immersive_dark),
            @sizeOf(u32),
        );
        _ = DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, @ptrCast(&policy.caption_color), @sizeOf(u32));
        _ = DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, @ptrCast(&policy.text_color), @sizeOf(u32));
        if (supports_backdrop) _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            @ptrCast(&policy.backdrop_type),
            @sizeOf(u32),
        );
    }
};

pub const ProfileChromeAccent = struct {
    idle_bg: u32,
    idle_border: u32,
    hover_bg: u32,
    hover_border: u32,
    pressed_bg: u32,
    active_bg: u32,
    active_border: u32,
    focus: u32,
};

// ── Design tokens (metrics, motion, typography) ─────────────────────────
//
// These three structs give the Win32 apprt a shared source of truth for
// chrome sizing, animation cadence, and typography. They sit alongside
// `ThemeColors` and are consumed via the same `Theme` aggregate (see
// `Theme` at the bottom of this file).
//
// All pixel values are logical (96 DPI). At paint time, every call site
// that consumes a metric is responsible for `MulDiv(value, dpi, 96)`
// scaling. We deliberately keep these `u16` so DPI scaling expands to
// `i32` in the same expression — no sub-pixel strokes, no float rounding
// at paint time.
//
// The component layer (values that are unique to exactly one widget,
// e.g. `host_overlay_label_width = 110`) is intentionally NOT promoted
// here — those stay as named `const`s on their owning module.

pub const ThemeMetrics = struct {
    // Spacing scale (px @ 96 DPI). 4 px baseline with a 2 px micro step.
    space_0: u16 = 0,
    space_1: u16 = 2, // hairline, focus-ring inset
    space_2: u16 = 4, // control padding
    space_3: u16 = 6, // tight row gap
    space_4: u16 = 8, // default gap
    space_5: u16 = 12, // card padding, overlay row gap
    space_6: u16 = 16, // section separation
    space_7: u16 = 20, // major gutter
    space_8: u16 = 24, // dialog padding
    space_9: u16 = 32, // vertical rhythm for settings
    space_10: u16 = 48, // empty-state breathing room

    // Corner radius (px). Never above 8 — stays orthogonal to the cell grid.
    radius_none: u16 = 0,
    radius_sm: u16 = 2, // focus ring, list row hover
    radius_md: u16 = 4, // buttons, overlay inputs
    radius_lg: u16 = 6, // overlay container, palette card
    radius_xl: u16 = 8, // dialogs

    // Stroke widths (px).
    stroke_hairline: u16 = 1, // all control borders
    stroke_divider: u16 = 2, // split divider
    stroke_focus: u16 = 2, // focus ring
    stroke_emphasis: u16 = 3, // HC mode only

    // Chrome heights (px). These replace the file-scope constants at the
    // top of src/apprt/win32.zig (host_tab_height, host_overlay_height).
    // Keep those aliases until the consumers migrate.
    height_tab: u16 = 32, // separate tab bar (Win10 / native mode)
    height_tab_integrated: u16 = 40, // tabs-in-caption (Win11 default)
    height_titlebar: u16 = 40, // integrated titlebar total
    height_overlay: u16 = 58, // command palette / search
    height_inspector: u16 = 42,
    height_search_bar: u16 = 40, // docked search row

    // Overlay geometry (px).
    overlay_padding: u16 = 12,
    overlay_label_width: u16 = 110,
    overlay_row_height: u16 = 24,
    overlay_accept_width: u16 = 70,
    overlay_cancel_width: u16 = 80,

    // Tab geometry (px).
    tab_min_width: u16 = 108,
    tab_max_width: u16 = 220,
    tab_close_zone: u16 = 22,
    tab_small_button_width: u16 = 34,
    tab_overflow_button_width: u16 = 34,
    tab_label_max_width: u16 = 24, // display cells, not pixels

    // Pane divider (px).
    pane_divider: u16 = 2,

    // Caption buttons (integrated titlebar, Win11 default).
    caption_button_w: u16 = 46,
    caption_button_h: u16 = 40,

    /// The metrics value used when HC mode is active. Borders bump to the
    /// emphasis stroke; radii collapse to 0 so boundaries are pixel-sharp.
    pub fn highContrast() ThemeMetrics {
        var m: ThemeMetrics = .{};
        m.stroke_hairline = m.stroke_emphasis;
        m.stroke_divider = m.stroke_emphasis;
        m.stroke_focus = m.stroke_emphasis;
        m.radius_sm = 0;
        m.radius_md = 0;
        m.radius_lg = 0;
        m.radius_xl = 0;
        return m;
    }
};

pub const ThemeMotion = struct {
    // Durations (ms). `instant` is 0 so reduced-motion can collapse
    // everything to it via the `reduced` helper.
    duration_instant_ms: u16 = 0,
    duration_quick_ms: u16 = 120, // hover, press, focus appear
    duration_standard_ms: u16 = 180, // tab-switch, toast slide
    duration_emphasized_ms: u16 = 240, // palette open, settings swap
    duration_decelerate_ms: u16 = 320, // quick-terminal slide

    // Cubic-Bézier easing (x1, y1, x2, y2). Fluent-aligned.
    easing_standard: [4]f32 = .{ 0.33, 0.00, 0.67, 1.00 },
    easing_decelerate: [4]f32 = .{ 0.10, 0.90, 0.20, 1.00 },
    easing_accelerate: [4]f32 = .{ 0.70, 0.00, 1.00, 0.50 },
    easing_emphasized: [4]f32 = .{ 0.30, 0.00, 0.10, 1.00 },

    /// Collapse every duration to 0 and every easing to linear.
    /// Triggered by SPI_GETCLIENTAREAANIMATION = FALSE and implicitly
    /// by High Contrast.
    pub fn reduced() ThemeMotion {
        return .{
            .duration_instant_ms = 0,
            .duration_quick_ms = 0,
            .duration_standard_ms = 0,
            .duration_emphasized_ms = 0,
            .duration_decelerate_ms = 0,
            .easing_standard = .{ 0.0, 0.0, 1.0, 1.0 },
            .easing_decelerate = .{ 0.0, 0.0, 1.0, 1.0 },
            .easing_accelerate = .{ 0.0, 0.0, 1.0, 1.0 },
            .easing_emphasized = .{ 0.0, 0.0, 1.0, 1.0 },
        };
    }
};

pub const ChromeType = struct {
    // Family + fallback. `caption` and `body` live on Segoe UI Variable
    // on Win11; collapse to Segoe UI on Win10 via the probe in
    // recreateChromeFonts.
    caption_family: []const u8 = "Segoe UI Variable Small",
    caption_family_fallback: []const u8 = "Segoe UI",
    caption_size_pt: u8 = 12,
    caption_weight: u16 = 400,
    caption_leading_px: u16 = 16,

    body_family: []const u8 = "Segoe UI Variable Text",
    body_family_fallback: []const u8 = "Segoe UI",
    body_size_pt: u8 = 14,
    body_weight: u16 = 400,
    body_leading_px: u16 = 20,
    body_strong_weight: u16 = 600,

    subtitle_family: []const u8 = "Segoe UI Variable Display",
    subtitle_family_fallback: []const u8 = "Segoe UI",
    subtitle_size_pt: u8 = 16,
    subtitle_weight: u16 = 600,
};

/// Aggregate theme record. Keep `ThemeColors` shape unchanged so every
/// current consumer compiles unchanged; metrics/motion/type get added
/// via the optional companion fields.
///
/// New call sites that need metrics should consume `Theme.metrics` /
/// `.motion` / `.type` directly. Old call sites that read individual
/// `ThemeColors` fields keep working via `Theme.colors`.
pub const Theme = struct {
    colors: ThemeColors,
    metrics: ThemeMetrics = .{},
    motion: ThemeMotion = .{},
    chrome_type: ChromeType = .{},
};

// ── Theme palettes ──────────────────────────────────────────────────────

pub fn darkTheme() ThemeColors {
    return .{
        .chrome_bg = rgb(32, 32, 32),
        .chrome_border = rgb(48, 48, 48),
        .overlay_bg = rgb(26, 26, 28),
        .overlay_border = rgb(48, 48, 48),
        .edit_bg = rgb(20, 20, 22),
        .edit_frame_bg = rgb(18, 18, 20),
        .inspector_bg = rgb(22, 22, 24),

        .text_primary = rgb(220, 220, 224),
        .text_secondary = rgb(158, 158, 164),
        .text_disabled = rgb(110, 110, 116),
        .edit_fg = rgb(234, 234, 238),
        .overlay_label_fg = rgb(210, 228, 255),
        .info_fg = rgb(142, 197, 255),
        .error_fg = rgb(255, 132, 132),

        .accent = rgb(116, 156, 224),
        .accent_hover = rgb(132, 172, 238),
        .chrome_accent_idle = rgb(62, 62, 62),
        // The Settings field frame. The themed edit border it replaced was
        // #646464 in both modes; this is the nearest gray that keeps 3:1
        // against the dark pane and the field (WCAG 1.4.11).
        .edit_border_unfocused = rgb(106, 106, 106),

        .button_bg = rgb(38, 38, 38),
        .button_border = rgb(58, 58, 58),
        .button_fg = rgb(200, 200, 200),

        .button_overlay_bg = rgb(36, 36, 38),
        .button_overlay_border = rgb(68, 68, 72),
        .button_overlay_fg = rgb(224, 224, 228),
        .button_chrome_fg = rgb(190, 190, 194),

        .button_active_bg = rgb(50, 60, 82),
        .button_active_border = rgb(116, 156, 224),
        .button_active_fg = rgb(244, 247, 252),

        .button_accept_bg = rgb(52, 92, 166),
        .button_accept_border = rgb(126, 169, 247),
        .button_accept_fg = rgb(248, 250, 255),

        .button_disabled_bg = rgb(28, 28, 30),
        .button_disabled_border = rgb(48, 48, 50),
        .button_disabled_fg = rgb(110, 110, 114),

        .button_focus_ring = rgb(140, 166, 208),
        .button_overlay_focus_ring = rgb(160, 190, 238),
        .button_active_focus_ring = rgb(172, 206, 255),
        .button_accept_focus_ring = rgb(184, 212, 255),

        .pane_divider = rgb(58, 58, 58),
        .pane_divider_focused = rgb(116, 156, 224),

        .is_dark = true,
    };
}

pub fn lightTheme() ThemeColors {
    return .{
        .chrome_bg = rgb(243, 243, 243),
        .chrome_border = rgb(209, 209, 209),
        .overlay_bg = rgb(249, 249, 249),
        .overlay_border = rgb(220, 220, 220),
        .edit_bg = rgb(255, 255, 255),
        .edit_frame_bg = rgb(245, 245, 245),
        .inspector_bg = rgb(235, 235, 235),

        .text_primary = rgb(27, 27, 27),
        .text_secondary = rgb(96, 96, 96),
        .text_disabled = rgb(160, 160, 160),
        .edit_fg = rgb(27, 27, 27),
        .overlay_label_fg = rgb(0, 60, 116),
        .info_fg = rgb(0, 95, 184),
        .error_fg = rgb(196, 43, 28),

        .accent = rgb(0, 120, 212),
        .accent_hover = rgb(0, 99, 177),
        .chrome_accent_idle = rgb(180, 180, 180),
        // The themed edit border the Settings field frame replaced.
        .edit_border_unfocused = rgb(100, 100, 100),

        .button_bg = rgb(251, 251, 251),
        .button_border = rgb(209, 209, 209),
        .button_fg = rgb(27, 27, 27),

        .button_overlay_bg = rgb(245, 245, 245),
        .button_overlay_border = rgb(180, 180, 180),
        .button_overlay_fg = rgb(27, 27, 27),
        .button_chrome_fg = rgb(96, 96, 96),

        .button_active_bg = rgb(204, 228, 247),
        .button_active_border = rgb(0, 120, 212),
        .button_active_fg = rgb(0, 60, 116),

        .button_accept_bg = rgb(0, 120, 212),
        .button_accept_border = rgb(0, 99, 177),
        .button_accept_fg = rgb(255, 255, 255),

        .button_disabled_bg = rgb(243, 243, 243),
        .button_disabled_border = rgb(209, 209, 209),
        .button_disabled_fg = rgb(160, 160, 160),

        .button_focus_ring = rgb(0, 120, 212),
        .button_overlay_focus_ring = rgb(0, 120, 212),
        .button_active_focus_ring = rgb(0, 90, 158),
        .button_accept_focus_ring = rgb(0, 90, 158),

        .pane_divider = rgb(209, 209, 209),
        .pane_divider_focused = rgb(0, 120, 212),

        .is_dark = false,
    };
}

// ── Color helpers ───────────────────────────────────────────────────────

pub fn adjustColor(base: u32, dr: i16, dg: i16, db: i16) u32 {
    const r: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast(base & 0xFF)) + dr, 0, 255))));
    const g: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast((base >> 8) & 0xFF)) + dg, 0, 255))));
    const b: u8 = @intCast(@as(u16, @intCast(std.math.clamp(@as(i16, @intCast((base >> 16) & 0xFF)) + db, 0, 255))));
    return rgb(r, g, b);
}

// ── Button color derivation ─────────────────────────────────────────────

/// Dim inactive top chrome while preserving the system palette in high contrast.
pub fn windowChromeTextColor(theme: *const ThemeColors, foreground: u32, window_active: bool, high_contrast: bool) u32 {
    return if (window_active or high_contrast) foreground else theme.text_secondary;
}

test "CHROME57 inactive chrome dims without altering high contrast" {
    for ([_]ThemeColors{ darkTheme(), lightTheme() }) |theme| {
        try std.testing.expectEqual(theme.text_secondary, windowChromeTextColor(&theme, theme.text_primary, false, false));
        try std.testing.expectEqual(theme.text_primary, windowChromeTextColor(&theme, theme.text_primary, true, false));
        try std.testing.expectEqual(theme.text_primary, windowChromeTextColor(&theme, theme.text_primary, false, true));
    }
}

pub fn buttonColorsFromTheme(
    theme: *const ThemeColors,
    active: bool,
    overlay: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
    accept: bool,
    high_contrast: bool,
) ButtonColors {
    var colors: ButtonColors = .{
        .bg = if (overlay) theme.button_overlay_bg else theme.button_bg,
        .border = if (overlay) theme.button_overlay_border else theme.button_border,
        .fg = theme.button_fg,
    };

    if (active) {
        colors = .{
            .bg = theme.button_active_bg,
            .border = theme.button_active_border,
            .fg = theme.button_active_fg,
        };
    }
    if (accept) {
        colors = .{
            .bg = theme.button_accept_bg,
            .border = theme.button_accept_border,
            .fg = theme.button_accept_fg,
        };
    }
    if (hovered and !pressed and !disabled) {
        if (accept) {
            colors.bg = adjustColor(theme.button_accept_bg, 14, 16, 22);
            colors.border = adjustColor(theme.button_accept_border, 24, 20, 10);
        } else if (active) {
            colors.bg = adjustColor(theme.button_active_bg, 16, 18, 22);
            colors.border = theme.accent_hover;
        } else {
            // High Contrast palettes can have a dark background with is_dark=false.
            // Choose hover direction from the actual button background.
            const hover_lightens = ((colors.bg & 0xff) * 299 + ((colors.bg >> 8) & 0xff) * 587 + ((colors.bg >> 16) & 0xff) * 114) < 128000;
            if (overlay) {
                colors.bg = if (hover_lightens) adjustColor(theme.button_overlay_bg, 14, 14, 16) else adjustColor(theme.button_overlay_bg, -8, -8, -8);
                colors.border = if (hover_lightens) adjustColor(theme.button_overlay_border, 20, 20, 24) else adjustColor(theme.button_overlay_border, -20, -20, -24);
            } else {
                colors.bg = if (hover_lightens) adjustColor(theme.button_bg, 16, 16, 18) else adjustColor(theme.button_bg, -8, -8, -8);
                colors.border = if (hover_lightens) adjustColor(theme.button_border, 28, 28, 30) else adjustColor(theme.button_border, -28, -28, -30);
            }
        }
    }
    if (pressed) {
        colors.bg = if (overlay) adjustColor(theme.overlay_bg, -4, -4, -4) else adjustColor(theme.chrome_bg, -8, -8, -8);
        if (active) colors.bg = adjustColor(theme.button_active_bg, -18, -20, -20);
        if (accept) colors.bg = adjustColor(theme.button_accept_bg, -14, -20, -32);
    }
    if (disabled) {
        colors = .{
            .bg = theme.button_disabled_bg,
            .border = theme.button_disabled_border,
            .fg = theme.button_disabled_fg,
        };
    }

    if (high_contrast and hovered and !pressed and !disabled) {
        colors = .{ .bg = theme.button_active_bg, .border = theme.button_active_border, .fg = theme.button_active_fg };
    }
    return colors;
}

test "CHROME57 light button hover darkens without becoming pressed" {
    const theme = lightTheme();
    for ([_]bool{ false, true }) |overlay| {
        const idle = buttonColorsFromTheme(&theme, false, overlay, false, false, false, false, false);
        const hover = buttonColorsFromTheme(&theme, false, overlay, true, false, false, false, false);
        const pressed = buttonColorsFromTheme(&theme, false, overlay, true, true, false, false, false);
        try std.testing.expect((hover.bg & 0xff) + 6 <= (idle.bg & 0xff));
        try std.testing.expect((hover.border & 0xff) < (idle.border & 0xff));
        try std.testing.expect(hover.bg != pressed.bg);
    }
}

test "CHROME57 High Contrast hover uses readable system highlight colours" {
    const RGB = @import("../terminal/color.zig").RGB;
    for ([_]bool{ false, true }) |black| {
        var theme = lightTheme();
        theme.button_bg = if (black) rgb(0, 0, 0) else rgb(255, 255, 255);
        theme.button_overlay_bg = theme.button_bg;
        theme.button_border = if (black) rgb(255, 255, 255) else rgb(0, 0, 0);
        theme.button_overlay_border = theme.button_border;
        theme.button_active_bg = if (black) rgb(255, 255, 0) else rgb(0, 0, 128);
        theme.button_active_fg = if (black) rgb(0, 0, 0) else rgb(255, 255, 255);
        theme.button_active_border = theme.button_active_fg;
        for ([_]bool{ false, true }) |overlay| {
            const hover = buttonColorsFromTheme(&theme, false, overlay, true, false, false, false, true);
            try std.testing.expectEqualDeep(ButtonColors{ .bg = theme.button_active_bg, .border = theme.button_active_border, .fg = theme.button_active_fg }, hover);
            const bg: RGB = .{ .r = @truncate(hover.bg), .g = @truncate(hover.bg >> 8), .b = @truncate(hover.bg >> 16) };
            const fg: RGB = .{ .r = @truncate(hover.fg), .g = @truncate(hover.fg >> 8), .b = @truncate(hover.fg >> 16) };
            try std.testing.expect(bg.contrast(fg) >= 4.5);
            try std.testing.expect(hover.bg != theme.button_bg);
        }
    }
}

// Legacy buttonColors() and buttonFocusRingColor() removed.
// Use buttonColorsFromTheme() and ThemeColors focus ring fields instead.

// ── Overlay accent ──────────────────────────────────────────────────────

pub fn overlayAccentColor(mode: HostOverlayMode, is_dark: bool) u32 {
    if (!is_dark) {
        return switch (mode) {
            .command_palette => rgb(0, 90, 158),
            .profile => rgb(136, 60, 160),
            .search => rgb(16, 124, 80),
            .surface_title, .tab_title => rgb(156, 112, 24),
            .tab_overview => rgb(102, 76, 180),
            // Destructive warning tone — muted red so the Accept
            // button visually reads as "something will be lost".
            .confirm => rgb(178, 48, 56),
            .none => rgb(140, 140, 140),
        };
    }
    return switch (mode) {
        .command_palette => rgb(116, 156, 224),
        .profile => rgb(192, 132, 214),
        .search => rgb(118, 196, 158),
        .surface_title, .tab_title => rgb(212, 170, 92),
        .tab_overview => rgb(168, 148, 228),
        .confirm => rgb(232, 104, 112),
        .none => rgb(72, 82, 98),
    };
}

pub fn overlayEditBorderColor(mode: HostOverlayMode, focused: bool, is_dark: bool) u32 {
    if (focused) return overlayAccentColor(mode, is_dark);
    if (!is_dark) {
        return switch (mode) {
            .none => rgb(180, 180, 180),
            else => rgb(140, 140, 140),
        };
    }
    return switch (mode) {
        .none => rgb(72, 82, 98),
        else => rgb(86, 96, 112),
    };
}

// ── Profile chrome accents ──────────────────────────────────────────────

pub fn profileChromeAccent(kind: ProfileKind, is_dark: bool) ProfileChromeAccent {
    if (!is_dark) {
        return switch (kind) {
            .wsl_default, .wsl_distro, .ssh => .{
                .idle_bg = rgb(228, 245, 233),
                .idle_border = rgb(46, 125, 70),
                .hover_bg = rgb(218, 238, 224),
                .hover_border = rgb(36, 110, 58),
                .pressed_bg = rgb(200, 228, 210),
                .active_bg = rgb(195, 232, 208),
                .active_border = rgb(28, 100, 48),
                .focus = rgb(22, 80, 40),
            },
            .pwsh => .{
                .idle_bg = rgb(224, 242, 248),
                .idle_border = rgb(24, 120, 150),
                .hover_bg = rgb(212, 236, 244),
                .hover_border = rgb(16, 108, 138),
                .pressed_bg = rgb(196, 226, 236),
                .active_bg = rgb(188, 228, 240),
                .active_border = rgb(12, 96, 126),
                .focus = rgb(8, 80, 108),
            },
            .powershell, .vs_dev_shell => .{
                .idle_bg = rgb(228, 232, 248),
                .idle_border = rgb(48, 68, 156),
                .hover_bg = rgb(218, 222, 242),
                .hover_border = rgb(38, 56, 140),
                .pressed_bg = rgb(200, 208, 232),
                .active_bg = rgb(196, 206, 236),
                .active_border = rgb(30, 48, 128),
                .focus = rgb(24, 40, 108),
            },
            .git_bash => .{
                .idle_bg = rgb(252, 244, 228),
                .idle_border = rgb(168, 120, 24),
                .hover_bg = rgb(248, 238, 216),
                .hover_border = rgb(152, 108, 16),
                .pressed_bg = rgb(240, 228, 200),
                .active_bg = rgb(244, 232, 196),
                .active_border = rgb(140, 96, 8),
                .focus = rgb(120, 80, 4),
            },
            // A user profile can run anything; it takes the neutral Command
            // Prompt palette, as the Developer Command Prompt does.
            .cmd, .user, .vs_dev_cmd => .{
                .idle_bg = rgb(240, 240, 240),
                .idle_border = rgb(128, 128, 128),
                .hover_bg = rgb(232, 232, 232),
                .hover_border = rgb(112, 112, 112),
                .pressed_bg = rgb(220, 220, 220),
                .active_bg = rgb(216, 216, 216),
                .active_border = rgb(96, 96, 96),
                .focus = rgb(64, 64, 64),
            },
        };
    }

    return switch (kind) {
        .wsl_default, .wsl_distro, .ssh => .{
            .idle_bg = rgb(34, 46, 38),
            .idle_border = rgb(92, 176, 118),
            .hover_bg = rgb(40, 54, 44),
            .hover_border = rgb(116, 206, 144),
            .pressed_bg = rgb(28, 38, 31),
            .active_bg = rgb(46, 72, 54),
            .active_border = rgb(142, 224, 164),
            .focus = rgb(188, 244, 200),
        },
        .pwsh => .{
            .idle_bg = rgb(34, 45, 52),
            .idle_border = rgb(86, 176, 204),
            .hover_bg = rgb(40, 54, 62),
            .hover_border = rgb(110, 204, 234),
            .pressed_bg = rgb(28, 37, 43),
            .active_bg = rgb(44, 70, 82),
            .active_border = rgb(136, 216, 242),
            .focus = rgb(186, 232, 248),
        },
        .powershell, .vs_dev_shell => .{
            .idle_bg = rgb(34, 42, 58),
            .idle_border = rgb(98, 144, 220),
            .hover_bg = rgb(40, 50, 72),
            .hover_border = rgb(122, 170, 244),
            .pressed_bg = rgb(27, 34, 48),
            .active_bg = rgb(46, 64, 96),
            .active_border = rgb(148, 194, 255),
            .focus = rgb(192, 220, 255),
        },
        .git_bash => .{
            .idle_bg = rgb(48, 40, 31),
            .idle_border = rgb(212, 156, 92),
            .hover_bg = rgb(58, 48, 37),
            .hover_border = rgb(236, 182, 118),
            .pressed_bg = rgb(40, 33, 26),
            .active_bg = rgb(78, 62, 42),
            .active_border = rgb(248, 202, 134),
            .focus = rgb(255, 224, 178),
        },
        .cmd, .user, .vs_dev_cmd => .{
            .idle_bg = rgb(31, 41, 35),
            .idle_border = rgb(104, 186, 126),
            .hover_bg = rgb(38, 50, 42),
            .hover_border = rgb(128, 210, 150),
            .pressed_bg = rgb(25, 34, 29),
            .active_bg = rgb(42, 64, 50),
            .active_border = rgb(150, 228, 170),
            .focus = rgb(194, 244, 202),
        },
    };
}

pub fn applyProfileChromeAccent(
    base: ButtonColors,
    kind: ProfileKind,
    is_dark: bool,
    active: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
) ButtonColors {
    if (disabled) return base;

    const accent = profileChromeAccent(kind, is_dark);
    var colors = base;
    colors.bg = if (active) accent.active_bg else accent.idle_bg;
    colors.border = if (active) accent.active_border else accent.idle_border;

    if (hovered and !pressed) {
        colors.bg = if (active) accent.active_bg else accent.hover_bg;
        colors.border = if (active) accent.active_border else accent.hover_border;
    }
    if (pressed) {
        colors.bg = accent.pressed_bg;
        colors.border = if (active) accent.active_border else accent.hover_border;
    }
    if (active) {
        colors.fg = if (is_dark) rgb(248, 250, 255) else rgb(16, 16, 24);
    }
    return colors;
}

pub fn profileKindFocusRingColor(kind: ProfileKind, is_dark: bool) u32 {
    return profileChromeAccent(kind, is_dark).focus;
}

pub fn profileChromeStripeColor(
    kind: ProfileKind,
    is_dark: bool,
    active: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
) u32 {
    const accent = profileChromeAccent(kind, is_dark);
    if (disabled) return if (is_dark) rgb(86, 94, 108) else rgb(180, 180, 180);
    if (pressed) return accent.hover_border;
    if (hovered or active) return accent.active_border;
    return accent.idle_border;
}

pub fn profileKindLabelColor(kind: ProfileKind, is_dark: bool) u32 {
    return profileChromeAccent(kind, is_dark).focus;
}

pub fn profileKindHintColor(kind: ProfileKind, is_dark: bool) u32 {
    return profileChromeAccent(kind, is_dark).active_border;
}

test "settings colors follow explicit light and dark app themes" {
    const system = SettingsSystemColors{
        .window = 1,
        .window_text = 2,
        .button_face = 3,
        .button_text = 4,
        .gray_text = 5,
        .highlight = 6,
        .highlight_text = 7,
    };
    const light = settingsColors(lightTheme(), system, false);
    const dark = settingsColors(darkTheme(), system, false);
    try std.testing.expect(!light.is_dark);
    try std.testing.expect(dark.is_dark);
    try std.testing.expectEqual(lightTheme().overlay_bg, light.window_bg);
    try std.testing.expectEqual(lightTheme().chrome_bg, light.rail_bg);
    try std.testing.expectEqual(darkTheme().overlay_bg, dark.window_bg);
    try std.testing.expectEqual(darkTheme().chrome_bg, dark.rail_bg);
    try std.testing.expectEqual(darkTheme().text_secondary, dark.secondary_text);
    try std.testing.expectEqual(darkTheme().overlay_border, dark.rail_separator);
    try std.testing.expectEqual(darkTheme().overlay_border, dark.pane_separator);
    try std.testing.expectEqual(darkTheme().accent, dark.accent);
    try std.testing.expectEqual(darkTheme().button_active_bg, dark.selection_bg);
    try std.testing.expectEqual(darkTheme().button_active_fg, dark.selection_text);
    try std.testing.expectEqual(darkTheme().button_focus_ring, dark.focus_ring);
    try std.testing.expectEqual(darkTheme().error_fg, dark.error_text);
    try std.testing.expectEqual(darkTheme().edit_border_unfocused, dark.field_border);
    try std.testing.expect(light.window_bg != dark.window_bg);
    try std.testing.expect(light.edit_bg != dark.edit_bg);
}

test "settings field frames keep 3:1 against the pane and the field" {
    const RGB = @import("../terminal/color.zig").RGB;
    const of = struct {
        fn rgbOf(color: u32) RGB {
            return .{ .r = @truncate(color), .g = @truncate(color >> 8), .b = @truncate(color >> 16) };
        }
    }.rgbOf;
    const system = std.mem.zeroes(SettingsSystemColors);
    for ([_]ThemeColors{ lightTheme(), darkTheme() }) |theme| {
        const colors = settingsColors(theme, system, false);
        // WCAG 1.4.11: the resting frame and the focus stroke.
        for ([_]u32{ colors.field_border, colors.accent }) |stroke| {
            try std.testing.expect(of(stroke).contrast(of(colors.window_bg)) >= 3.0);
            try std.testing.expect(of(stroke).contrast(of(colors.edit_bg)) >= 3.0);
        }
    }
}

test "settings colours keep their contrast in light, dark and every shipped High Contrast theme" {
    const RGB = @import("../terminal/color.zig").RGB;
    const of = struct {
        fn rgbOf(color: u32) RGB {
            return .{ .r = @truncate(color), .g = @truncate(color >> 8), .b = @truncate(color >> 16) };
        }
    }.rgbOf;
    // The contrast themes Windows 11 ships, as their files set them
    // (`%WINDIR%\Resources\Ease of Access Themes`): hc1 (Dusk), hc2 (Night
    // sky), hcblack (Aquatic) and hcwhite (Desert).
    const shipped = [_]SettingsSystemColors{
        .{ .window = rgb(45, 50, 54), .window_text = rgb(255, 255, 255), .button_face = rgb(45, 50, 54), .button_text = rgb(182, 246, 240), .gray_text = rgb(166, 166, 166), .highlight = rgb(161, 191, 222), .highlight_text = rgb(33, 45, 59) },
        .{ .window = rgb(0, 0, 0), .window_text = rgb(255, 255, 255), .button_face = rgb(0, 0, 0), .button_text = rgb(255, 238, 50), .gray_text = rgb(166, 166, 166), .highlight = rgb(214, 180, 253), .highlight_text = rgb(43, 43, 43) },
        .{ .window = rgb(32, 32, 32), .window_text = rgb(255, 255, 255), .button_face = rgb(32, 32, 32), .button_text = rgb(255, 255, 255), .gray_text = rgb(166, 166, 166), .highlight = rgb(142, 227, 240), .highlight_text = rgb(38, 59, 80) },
        .{ .window = rgb(255, 250, 239), .window_text = rgb(61, 61, 61), .button_face = rgb(255, 250, 239), .button_text = rgb(32, 32, 32), .gray_text = rgb(103, 103, 103), .highlight = rgb(144, 57, 9), .highlight_text = rgb(255, 245, 227) },
    };
    var palettes: [2 + shipped.len]SettingsColors = undefined;
    palettes[0] = settingsColors(lightTheme(), std.mem.zeroes(SettingsSystemColors), false);
    palettes[1] = settingsColors(darkTheme(), std.mem.zeroes(SettingsSystemColors), false);
    for (shipped, 2..) |system, index| palettes[index] = settingsColors(lightTheme(), system, true);
    var failed = false;
    for (palettes, 0..) |colors, index| inline for (settings_contrast_pairs) |pair| {
        const ratio = of(@field(colors, pair.foreground)).contrast(of(@field(colors, pair.background)));
        if (ratio < pair.minimum and (pair.high_contrast or !colors.high_contrast)) {
            std.debug.print("palette {d}: {s} on {s} is {d:.2}:1, under {d:.1}:1\n", .{ index, pair.foreground, pair.background, ratio, pair.minimum });
            failed = true;
        }
    };
    try std.testing.expect(!failed);
    // The toggle's state is not its colour alone: the thumb moves too.
    // Still, on and off differ by more than the fill.
    for (palettes[0..2]) |colors| try std.testing.expect(colors.toggle_on_track != colors.toggle_off);
}

test "settings high contrast uses only exact system color roles" {
    const system = SettingsSystemColors{
        .window = 11,
        .window_text = 12,
        .button_face = 13,
        .button_text = 14,
        .gray_text = 15,
        .highlight = 16,
        .highlight_text = 17,
    };
    const colors = settingsColors(darkTheme(), system, true);
    try std.testing.expect(colors.high_contrast);
    try std.testing.expectEqual(system.button_face, colors.window_bg);
    try std.testing.expectEqual(system.window, colors.rail_bg);
    try std.testing.expectEqual(system.button_text, colors.text);
    try std.testing.expectEqual(system.button_text, colors.secondary_text);
    try std.testing.expectEqual(system.gray_text, colors.disabled_text);
    try std.testing.expectEqual(system.window_text, colors.rail_separator);
    try std.testing.expectEqual(system.button_text, colors.pane_separator);
    try std.testing.expectEqual(system.highlight, colors.accent);
    try std.testing.expectEqual(system.highlight, colors.selection_bg);
    try std.testing.expectEqual(system.highlight_text, colors.selection_text);
    try std.testing.expectEqual(system.highlight, colors.focus_ring);
    try std.testing.expectEqual(system.button_text, colors.error_text);
    try std.testing.expectEqual(system.window, colors.edit_bg);
    try std.testing.expectEqual(system.window_text, colors.edit_text);
    try std.testing.expectEqual(system.window_text, colors.field_border);
    try std.testing.expectEqual(system.highlight, colors.toggle_on_track);
    try std.testing.expectEqual(system.highlight_text, colors.toggle_on_thumb);
    try std.testing.expectEqual(system.button_text, colors.toggle_off);
    try std.testing.expectEqual(system.button_text, colors.action_text);
    try std.testing.expectEqual(@as(u32, 0), settingsDwmDarkModeValue(colors));
    try std.testing.expectEqual(
        @as(u32, 1),
        settingsDwmDarkModeValue(settingsColors(darkTheme(), system, false)),
    );
}

test "window theme policy actively resets sticky DWM state in high contrast" {
    const policy = windowThemePolicy(.host, true, true, 1, 2, 4);
    try std.testing.expectEqual(@as(u32, 0), policy.immersive_dark);
    try std.testing.expectEqual(dwm_color_default, policy.caption_color);
    try std.testing.expectEqual(dwm_color_default, policy.text_color);
    try std.testing.expectEqual(DWMSBT_NONE, policy.backdrop_type);
    try std.testing.expectEqual(NativeControlTheme.system, policy.native_controls);
}

test "settings window policy explicitly disables system backdrop" {
    const policy = windowThemePolicy(.settings, true, false, 1, 2, DWMSBT_NONE);
    try std.testing.expectEqual(DWMSBT_NONE, policy.backdrop_type);
    try std.testing.expectEqual(NativeControlTheme.explorer_dark, policy.native_controls);
}

test "DWM system backdrop constants match Win32 ABI" {
    try std.testing.expectEqual(@as(u32, 0), DWMSBT_AUTO);
    try std.testing.expectEqual(@as(u32, 1), DWMSBT_NONE);
    try std.testing.expectEqual(@as(u32, 2), DWMSBT_MAINWINDOW);
    try std.testing.expectEqual(@as(u32, 3), DWMSBT_TRANSIENTWINDOW);
    try std.testing.expectEqual(@as(u32, 4), DWMSBT_TABBEDWINDOW);
}
