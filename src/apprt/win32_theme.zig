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
    status_bg: u32,
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
    button_bg: u32,
    button_text: u32,
    is_dark: bool,
    high_contrast: bool,
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
            .button_bg = system.button_face,
            .button_text = system.button_text,
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
        .button_bg = theme.button_bg,
        .button_text = theme.button_fg,
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
    // top of src/apprt/win32.zig (host_tab_height, host_overlay_height,
    // host_status_height). Keep those aliases until the consumers migrate.
    height_tab: u16 = 32, // separate tab bar (Win10 / native mode)
    height_tab_integrated: u16 = 40, // tabs-in-caption (Win11 default)
    height_titlebar: u16 = 40, // integrated titlebar total
    height_overlay: u16 = 58, // command palette / search
    height_inspector: u16 = 42,
    height_status: u16 = 42, // status row
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
    tab_label_max_len: u16 = 24, // character count, not pixels

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

    pub fn fromColors(colors: ThemeColors) Theme {
        return .{ .colors = colors };
    }
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
        .status_bg = rgb(26, 26, 28),
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
        .edit_border_unfocused = rgb(72, 72, 72),

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
        .status_bg = rgb(238, 238, 238),
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
        .edit_border_unfocused = rgb(160, 160, 160),

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

pub fn buttonColorsFromTheme(
    theme: *const ThemeColors,
    active: bool,
    overlay: bool,
    hovered: bool,
    pressed: bool,
    disabled: bool,
    accept: bool,
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
        // Stronger hover deltas for responsive premium feel
        colors.bg = if (accept)
            adjustColor(theme.button_accept_bg, 14, 16, 22)
        else if (active)
            adjustColor(theme.button_active_bg, 16, 18, 22)
        else if (overlay)
            adjustColor(theme.button_overlay_bg, 14, 14, 16)
        else
            adjustColor(theme.button_bg, 16, 16, 18);
        colors.border = if (accept)
            adjustColor(theme.button_accept_border, 24, 20, 10)
        else if (active)
            theme.accent_hover
        else if (overlay)
            adjustColor(theme.button_overlay_border, 20, 20, 24)
        else
            adjustColor(theme.button_border, 28, 28, 30);
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

    return colors;
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
            .powershell => .{
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
            .cmd => .{
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
        .powershell => .{
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
        .cmd => .{
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

pub fn quickSlotChipColors(kind: ProfileKind, is_dark: bool, hovered: bool) ButtonColors {
    const accent = profileChromeAccent(kind, is_dark);
    return .{
        .bg = if (hovered) accent.hover_bg else accent.idle_bg,
        .border = if (hovered) accent.hover_border else accent.idle_border,
        .fg = if (hovered) profileKindHintColor(kind, is_dark) else profileKindLabelColor(kind, is_dark),
    };
}

pub fn pinnedChipMarkerColor(kind: ProfileKind, is_dark: bool, hovered: bool) u32 {
    return if (hovered) profileKindLabelColor(kind, is_dark) else profileKindHintColor(kind, is_dark);
}

// ── Accent-follow helpers ───────────────────────────────────────────────
// Registry read: win32.zig:resolveSystemAccentColor.
// Blend: 60% system / 40% semantic, S clamped [0.45, 0.75], V clamped
// [0.40, 0.90] — keeps the overlay readable against any system accent
// while preserving the semantic cue.

pub fn semanticOverlayHue(mode: HostOverlayMode) f32 {
    return switch (mode) {
        .command_palette => 215.0, // cool blue
        .profile => 285.0, // violet
        .search => 150.0, // teal / emerald
        .surface_title, .tab_title => 40.0, // warm amber
        .tab_overview => 258.0, // periwinkle
        .confirm => 0.0, // warning red (destructive)
        .none => 0.0,
    };
}

pub fn blendSemanticAccent(system_rgb: u32, semantic_h_deg: f32) u32 {
    // Neutral-black accent (e.g. registry empty, or user disabled
    // accent colour) has no hue to blend — keep the pure semantic hue
    // at mid saturation / value instead of washing to grey.
    if (system_rgb == 0) {
        return hsvToRgb(.{ .h = semantic_h_deg, .s = 0.60, .v = 0.70 });
    }
    const sys = rgbToHsv(system_rgb);
    const blended_h = lerpHue(semantic_h_deg, sys.h, 0.60);
    const blended_s = std.math.clamp((sys.s * 0.60) + (0.50 * 0.40), 0.45, 0.75);
    const blended_v = std.math.clamp((sys.v * 0.60) + (0.70 * 0.40), 0.40, 0.90);
    return hsvToRgb(.{ .h = blended_h, .s = blended_s, .v = blended_v });
}

const Hsv = struct { h: f32, s: f32, v: f32 };

fn rgbToHsv(colorref: u32) Hsv {
    const r: f32 = @as(f32, @floatFromInt(colorref & 0xFF)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt((colorref >> 8) & 0xFF)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt((colorref >> 16) & 0xFF)) / 255.0;
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    const delta = max - min;

    var h: f32 = 0.0;
    if (delta > 0.0) {
        if (max == r) {
            h = 60.0 * @mod((g - b) / delta, 6.0);
        } else if (max == g) {
            h = 60.0 * (((b - r) / delta) + 2.0);
        } else {
            h = 60.0 * (((r - g) / delta) + 4.0);
        }
        if (h < 0.0) h += 360.0;
    }
    const s: f32 = if (max == 0.0) 0.0 else delta / max;
    return .{ .h = h, .s = s, .v = max };
}

fn hsvToRgb(hsv: Hsv) u32 {
    const c = hsv.v * hsv.s;
    // @mod normalises h = 360 to 0, preventing the hp = 6.0 fall-through
    // (every `if (hp < N)` branch false → pure black).
    const hp = @mod(hsv.h, 360.0) / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    if (hp < 1.0) {
        r = c;
        g = x;
    } else if (hp < 2.0) {
        r = x;
        g = c;
    } else if (hp < 3.0) {
        g = c;
        b = x;
    } else if (hp < 4.0) {
        g = x;
        b = c;
    } else if (hp < 5.0) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = hsv.v - c;
    const ri: u8 = @intFromFloat(std.math.clamp((r + m) * 255.0, 0.0, 255.0));
    const gi: u8 = @intFromFloat(std.math.clamp((g + m) * 255.0, 0.0, 255.0));
    const bi: u8 = @intFromFloat(std.math.clamp((b + m) * 255.0, 0.0, 255.0));
    return rgb(ri, gi, bi);
}

fn lerpHue(a: f32, b: f32, t: f32) f32 {
    var diff = b - a;
    if (diff > 180.0) diff -= 360.0;
    if (diff < -180.0) diff += 360.0;
    const out = a + diff * t;
    return @mod(out + 360.0, 360.0);
}

test "rgbToHsv recovers grayscale" {
    const hsv = rgbToHsv(rgb(128, 128, 128));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), hsv.s, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), hsv.v, 0.01);
}

test "rgbToHsv primary blue" {
    const hsv = rgbToHsv(rgb(0, 120, 215)); // Windows default accent-ish
    try std.testing.expect(hsv.h > 200.0 and hsv.h < 220.0);
    try std.testing.expect(hsv.s > 0.9);
}

test "hsvToRgb round-trips primary red" {
    const c = hsvToRgb(.{ .h = 0.0, .s = 1.0, .v = 1.0 });
    try std.testing.expectEqual(@as(u32, rgb(255, 0, 0)), c);
}

test "lerpHue takes shortest arc" {
    // 350 -> 10 should cross through 0, not go the long way through 180.
    const mid = lerpHue(350.0, 10.0, 0.5);
    // Expect midpoint to be near 0 / 360, not ~180.
    try std.testing.expect(mid < 20.0 or mid > 340.0);
}

test "blendSemanticAccent stays in sane ranges" {
    const system = rgb(0, 120, 215); // Windows default-ish
    for ([_]HostOverlayMode{
        .command_palette, .profile, .search, .surface_title, .tab_overview,
    }) |mode| {
        const blended = blendSemanticAccent(system, semanticOverlayHue(mode));
        const hsv = rgbToHsv(blended);
        try std.testing.expect(hsv.s >= 0.45 - 0.01 and hsv.s <= 0.75 + 0.01);
        try std.testing.expect(hsv.v >= 0.40 - 0.01 and hsv.v <= 0.90 + 0.01);
    }
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
    try std.testing.expect(light.window_bg != dark.window_bg);
    try std.testing.expect(light.edit_bg != dark.edit_bg);
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
