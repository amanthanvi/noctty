//! Per-pane docked search controls. Host and Surface retain coordination.
const win32 = @import("../win32.zig");
const runtime = win32.search_controls_runtime;
const Allocator = runtime.Allocator;
const ButtonColors = runtime.ButtonColors;
const ChildPlacement = child_window.ChildPlacement;
const DRAWITEMSTRUCT = runtime.DRAWITEMSTRUCT;
const DWORD = runtime.DWORD;
const HDC = runtime.HDC;
const HWND = runtime.HWND;
const Host = runtime.Host;
const LONG_PTR = runtime.LONG_PTR;
const LPARAM = runtime.LPARAM;
const LRESULT = runtime.LRESULT;
const RECT = runtime.RECT;
const SearchBarButtonRole = runtime.SearchBarButtonRole;
const Surface = runtime.Surface;
const UINT = runtime.UINT;
const WPARAM = runtime.WPARAM;
const adjustColor = runtime.adjustColor;
const applyChildRect = child_window.applyChildRect;
const applyChildVisibility = child_window.applyChildVisibility;
const blendColorRGB = runtime.blendColorRGB;
const buttonColorsFromTheme = runtime.buttonColorsFromTheme;
const c = runtime.c;
const childRect = chrome_layout.childRect;
const child_window = @import("child_window.zig");
const chromeKeyMods = runtime.chromeKeyMods;
const chrome_layout = @import("chrome_layout.zig");
const createIconFontForFace = runtime.createIconFontForFace;
const decorativeUiaName = runtime.decorativeUiaName;
const detachChromeControlProvider = runtime.detachChromeControlProvider;
const docked_search = @import("docked_search.zig");
const dockedSearchArrowDirection = runtime.dockedSearchArrowDirection;
const dockedSearchCoreDirectionFromKeyAction = runtime.dockedSearchCoreDirectionFromKeyAction;
const dockedSearchEnterDirection = runtime.dockedSearchEnterDirection;
const drawRoundedRect = runtime.drawRoundedRect;
const editSnapshot = child_window.editSnapshot;
const fillSolidRect = runtime.fillSolidRect;
const focusableHwnd = runtime.focusableHwnd;
const fontGlyphCoverage = runtime.fontGlyphCoverage;
const font_embedded = runtime.font_embedded;
const getHost = runtime.getHost;
const getSurface = runtime.getSurface;
const hostButtonProc = runtime.hostButtonProc;
const host_search_bar_height = runtime.host_search_bar_height;
const input = runtime.input;
const isHighContrastActive = runtime.isHighContrastActive;
const keyPressed = runtime.keyPressed;
const lParamBits = runtime.lParamBits;
const labels = runtime.labels;
const lastError = child_window.lastError;
const log = runtime.log;
const logUiActionError = runtime.logUiActionError;
const nativeEditSelection = child_window.nativeEditSelection;
const overlayAccentColor = runtime.overlayAccentColor;
const prompt_button_class = child_window.prompt_button_class;
const prompt_edit_class = child_window.prompt_edit_class;
const prompt_label_class = child_window.prompt_label_class;
const readWindowTextUtf8Alloc = child_window.readWindowTextUtf8Alloc;
const rectEquals = chrome_layout.rectEquals;
const rectInset = chrome_layout.rectInset;
const rectOffset = chrome_layout.rectOffset;
const rectUnion = chrome_layout.rectUnion;
const scheduleDeferredUiaDisconnect = runtime.scheduleDeferredUiaDisconnect;
const searchBarBottomLine = runtime.searchBarBottomLine;
const searchBarButtonCommandId = runtime.searchBarButtonCommandId;
const searchBarButtonLabel = runtime.searchBarButtonLabel;
const searchBarButtonParentBg = runtime.searchBarButtonParentBg;
const searchBarButtonShowsLabel = runtime.searchBarButtonShowsLabel;
const searchBarChromeLayout = runtime.searchBarChromeLayout;
const searchBarFit = runtime.searchBarFit;
const searchBarFrameBg = runtime.searchBarFrameBg;
const searchBarFrameBorder = runtime.searchBarFrameBorder;
const searchBarToolbarVisual = runtime.searchBarToolbarVisual;
const searchButtonKeyAction = runtime.searchButtonKeyAction;
const selectNativeEditRange = child_window.selectNativeEditRange;
const setWindowData = child_window.setWindowData;
const std = runtime.std;
const syncWindowTextUtf8Cached = child_window.syncWindowTextUtf8Cached;
const sys = runtime.sys;
const terminalDisconnectThunk = runtime.terminalDisconnectThunk;
const terminalReleaseThunk = runtime.terminalReleaseThunk;
const win32_icons = runtime.win32_icons;
const win32_uia = runtime.win32_uia;
const test_runtime = if (@import("builtin").is_test) win32.search_controls_test_runtime else struct {};
const App = test_runtime.App;
const CoreApp = test_runtime.CoreApp;
const TestSession = test_runtime.TestSession;
const builtin = test_runtime.builtin;

/// The search bar's icons are VS Code's (Codicons), drawn from the Symbols
/// Nerd Font that noctty already embeds for the terminal (Nerd Fonts bundles
/// Codicons). The system icon fonts have no regex, match-case or whole-word
/// glyph, and taking all six from one set keeps them the same weight and
/// size. `win32_icons` stays the fallback when the font is unavailable.
pub const search_icon_font_face = std.unicode.utf8ToUtf16LeStringLiteral("Symbols Nerd Font");

/// Codicons are drawn on a 16 px grid, the size VS Code uses them at.
pub const search_icon_font_px = 16;

/// GDI cannot draw from font bytes in memory until they are registered, so
/// the embedded Symbols Nerd Font is added once as a private font: only this
/// process can see it, and Windows removes it when the process exits.
fn registerSearchIconFont() void {
    const bytes = font_embedded.symbols_nerd_font;
    var count: DWORD = 0;
    const handle = sys.AddFontMemResourceEx(@constCast(bytes.ptr), @intCast(bytes.len), null, &count);
    if (handle == null or count == 0) {
        log.warn("embedded Symbols Nerd Font could not be registered for the search bar icons", .{});
    }
}

pub var search_icon_font_registration = std.once(registerSearchIconFont);

fn logSearchIconFontRejected() void {
    log.warn("search bar icon font lacks a Codicon glyph; drawing geometric search icons", .{});
}

var search_icon_font_rejection_log = std.once(logSearchIconFontRejected);

/// The search bar's Codicons font at `dpi`, or null when it is unavailable,
/// in which case `win32_icons` draws the buttons.
fn createSearchIconFont(dpi: u32) ?*anyopaque {
    search_icon_font_registration.call();
    const font = createIconFontForFace(
        search_icon_font_face,
        Host.scaledBy(search_icon_font_px, dpi),
    ) orelse return null;
    if (!fontHasSearchCodicons(font)) {
        search_icon_font_rejection_log.call();
        _ = sys.DeleteObject(font);
        return null;
    }
    return font;
}

/// Every search bar button's Codicon, one UTF-16 unit each.
pub const search_codicon_glyphs = glyphs: {
    var units: [search_bar_button_roles.len]u16 = undefined;
    for (search_bar_button_roles, &units) |role, *unit| unit.* = searchButtonCodicon(role)[0];
    break :glyphs units;
};

/// Whether `font` has a glyph for every search bar button. An older
/// "Symbols Nerd Font" installed on the system can shadow the registered one
/// without having them all. A failed check counts as missing.
pub fn fontHasSearchCodicons(font: *anyopaque) bool {
    return fontGlyphCoverage(font, &search_codicon_glyphs) == .all;
}

/// The Codicon for each search bar button, by its Nerd Fonts code point.
fn searchButtonCodicon(role: SearchBarButtonRole) [:0]const u16 {
    return switch (role) {
        .prev => std.unicode.utf8ToUtf16LeStringLiteral("\u{EAA1}"), // arrow-up
        .next => std.unicode.utf8ToUtf16LeStringLiteral("\u{EA9A}"), // arrow-down
        .close => std.unicode.utf8ToUtf16LeStringLiteral("\u{EA76}"), // close
        .regex => std.unicode.utf8ToUtf16LeStringLiteral("\u{EB38}"), // regex
        .case_sensitive => std.unicode.utf8ToUtf16LeStringLiteral("\u{EAB1}"), // case-sensitive
        .whole_word => std.unicode.utf8ToUtf16LeStringLiteral("\u{EB7E}"), // whole-word
    };
}

const search_edit_cue = std.unicode.utf8ToUtf16LeStringLiteral("Find in scrollback");

const search_bar_button_roles = [_]SearchBarButtonRole{
    .prev,
    .next,
    .regex,
    .case_sensitive,
    .whole_word,
    .close,
};

pub fn searchBarGroupRect(placements: []const ChildPlacement, expand_x: i32, expand_y: i32) ?RECT {
    var out: ?RECT = null;
    for (placements) |placement| {
        if (!placement.rect_known or !placement.visible) continue;
        const expanded: RECT = .{
            .left = placement.rect.left - expand_x,
            .top = placement.rect.top - expand_y,
            .right = placement.rect.right + expand_x,
            .bottom = placement.rect.bottom + expand_y,
        };
        out = if (out) |current| rectUnion(current, expanded) else expanded;
    }
    return out;
}

pub fn searchBarSeparatorX(left: ChildPlacement, right: ChildPlacement) ?i32 {
    if (!left.rect_known or !left.visible or !right.rect_known or !right.visible) return null;
    const gap = right.rect.left - left.rect.right;
    if (gap <= 1) return null;
    return left.rect.right + @divTrunc(gap, 2);
}

/// The control at a docked search bar stop (`labels.search_focus_stop_count`),
/// or null while it is hidden: the toggles and arrows hide when the bar is
/// too narrow, and a closed bar hides them all.
pub fn searchFocusStopHwnd(surface: *const Surface, stop: usize) ?HWND {
    if (stop == 0) return focusableHwnd(surface.search_bar_edit_hwnd);
    const role = labels.searchFocusStopRole(stop) orelse return null;
    return focusableHwnd(surface.searchBarButtonHwnd(role));
}

pub fn searchFocusStopAvailable(surface: *const Surface, stop: usize) bool {
    return searchFocusStopHwnd(surface, stop) != null;
}

/// Alt+R, Alt+C and Alt+W from the docked search bar's query or buttons.
/// True when the key is one of those chords, so the caller swallows it; a
/// held key does not toggle again.
fn searchToggleKey(surface: *Surface, vk: WPARAM, lParam: LPARAM) bool {
    const role = surface.docked_search.toggle_keys.keyDown(vk, chromeKeyMods(), lParamBits(lParam)) orelse return false;
    if ((lParamBits(lParam) & c.KF_REPEAT) == 0) {
        _ = surface.dockedSearch(.{ .click = role }) catch |err| {
            logUiActionError("docked search accelerator toggle failed", err);
        };
    }
    return true;
}

/// The button that asks the core for `dir`: matches are numbered newest
/// first, so core `.next` is the visible previous (Up) button. Until the
/// key procedures hand their keys to `.key`.
fn navigateClick(dir: input.Binding.Action.NavigateSearch) SearchBarButtonRole {
    return switch (dir) {
        .next => .prev,
        .previous => .next,
    };
}

fn searchLabelProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (getSurface(hwnd)) |surface| {
        if (msg == c.WM_GETOBJECT) {
            if (surface.searchLabelUiaProvider(hwnd)) |provider| {
                if (win32_uia.returnChromeControlProvider(hwnd, wParam, lParam, provider)) |lr| return lr;
            }
        }
        if (surface.searchLabelPrevProc(hwnd)) |previous| return sys.CallWindowProcW(previous, hwnd, msg, wParam, lParam);
    }
    return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn searchEditProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    const host = getHost(hwnd);
    if (msg == c.WM_GETOBJECT) {
        if (host) |v| {
            if (v.searchControlSurface(hwnd)) |surface| {
                if (surface.search_bar_edit_uia_provider) |provider| {
                    if (win32_uia.returnTerminalProvider(hwnd, wParam, lParam, provider)) |lr| return lr;
                }
            }
        }
    }
    if (host) |v| {
        if (v.searchControlSurface(hwnd)) |surface| switch (msg) {
            c.WM_SETFOCUS => {
                v.app.activateSurfaceNoFocus(surface);
                surface.invalidateSearchBarChildPaint();
            },
            c.WM_KILLFOCUS => {
                surface.docked_search.toggle_keys = .{};
                surface.invalidateSearchBarChildPaint();
            },
            c.WM_LBUTTONDOWN => v.noteChromePointerInput(),
            // A Tab character would be typed into the query: there is no
            // dialog manager to take it.
            c.WM_CHAR => {
                if (wParam == c.VK_RETURN or wParam == c.VK_ESCAPE or wParam == c.VK_TAB) return 0;
            },
            // The WM_SYSCHAR of Alt+R / Alt+C / Alt+W; see below.
            c.WM_SYSCHAR => {
                if (surface.docked_search.toggle_keys.consumeChar(lParamBits(lParam))) return 0;
            },
            c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
                v.noteChromeKeyInput(wParam);
                // Escape stays with the search bar, which dismisses
                // itself and returns focus to the terminal; only Ctrl+F6
                // is taken for the focus-region cycle.
                if (v.handleFocusRegionKey(hwnd, wParam, false)) return 0;
                // Tab walks the query and then the bar's visible buttons,
                // wrapping; Escape and Ctrl+F6 still leave the bar.
                if (labels.tabFocusStep(wParam, chromeKeyMods())) |step| {
                    _ = v.stepSearchFocus(surface, hwnd, step == .previous);
                    return 0;
                }
                // Alt+R / Alt+C / Alt+W flip regex, case and whole word. The
                // press is a WM_SYSKEYDOWN, so it never types; the paired
                // WM_SYSCHAR is swallowed above.
                if (msg == c.WM_SYSKEYDOWN and searchToggleKey(surface, wParam, lParam)) return 0;
                if (wParam == c.VK_RETURN) {
                    _ = surface.dockedSearch(.{ .click = navigateClick(dockedSearchEnterDirection(keyPressed(c.VK_SHIFT))) }) catch |err| {
                        logUiActionError("docked search enter navigation failed", err);
                    };
                    return 0;
                }
                if (dockedSearchArrowDirection(wParam)) |dir| {
                    _ = surface.dockedSearch(.{ .click = navigateClick(dir) }) catch |err| {
                        logUiActionError("docked search arrow navigation failed", err);
                    };
                    return 0;
                }
                if (searchButtonKeyAction(wParam, keyPressed(c.VK_SHIFT))) |action| {
                    if (dockedSearchCoreDirectionFromKeyAction(action)) |dir| {
                        _ = surface.dockedSearch(.{ .click = navigateClick(dir) }) catch |err| {
                            logUiActionError("docked search key navigation failed", err);
                        };
                        return 0;
                    }
                    switch (action) {
                        .dismiss => {
                            _ = surface.dockedSearch(.{ .click = .close }) catch |err| {
                                logUiActionError("docked search key close failed", err);
                            };
                            return 0;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        };
    }

    const result = if (host) |v| blk: {
        if (v.searchControlSurface(hwnd)) |surface| {
            if (surface.search_bar_edit_prev_proc) |proc| {
                break :blk sys.CallWindowProcW(proc, hwnd, msg, wParam, lParam);
            }
        }
        break :blk sys.DefWindowProcW(hwnd, msg, wParam, lParam);
    } else sys.DefWindowProcW(hwnd, msg, wParam, lParam);
    if (host) |v| {
        if (v.searchControlSurface(hwnd)) |surface| {
            if (surface.search_bar_edit_uia_provider) |provider| switch (msg) {
                c.WM_SETFOCUS => win32_uia.events.raiseFocusChanged(&provider.base),
                c.WM_KEYUP, c.WM_LBUTTONUP, c.EM_SETSEL => surface.raiseSearchEditSelectionChangedIfNeeded(),
                else => {},
            };
        }
    }
    return result;
}

fn searchEditNameThunk(_: *anyopaque, _: []u8) []const u8 {
    return "Search query";
}

fn searchEditValueThunk(ctx: *anyopaque, alloc: Allocator) ![]u8 {
    const surface: *Surface = @ptrCast(@alignCast(ctx));
    const value = try surface.readSearchBarEditText();
    defer surface.app.core_app.alloc.free(value);
    return alloc.dupe(u8, value);
}

fn searchEditSnapshotThunk(ctx: *anyopaque, alloc: Allocator) !win32_uia.TerminalSnapshot {
    const surface: *Surface = @ptrCast(@alignCast(ctx));
    const hwnd = surface.search_bar_edit_hwnd orelse return error.ElementNotAvailable;
    const value = try surface.readSearchBarEditText();
    defer surface.app.core_app.alloc.free(value);
    return editSnapshot(alloc, hwnd, value);
}

fn searchEditFocusedThunk(ctx: *anyopaque) bool {
    const surface: *const Surface = @ptrCast(@alignCast(ctx));
    const hwnd = surface.search_bar_edit_hwnd orelse return false;
    return sys.GetFocus() == hwnd;
}

fn searchEditSetValueThunk(ctx: *anyopaque, value: []const u8) !void {
    const surface: *Surface = @ptrCast(@alignCast(ctx));
    const hwnd = surface.search_bar_edit_hwnd orelse return error.ElementNotAvailable;
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(surface.app.core_app.alloc, value);
    defer surface.app.core_app.alloc.free(value_w);
    if (sys.SetWindowTextW(hwnd, value_w.ptr) == 0) return lastError();
}

fn searchEditSelectRangeThunk(
    ctx: *anyopaque,
    snapshot_text: []const u8,
    range: win32_uia.OffsetRange,
) !void {
    const surface: *Surface = @ptrCast(@alignCast(ctx));
    const hwnd = surface.search_bar_edit_hwnd orelse return error.ElementNotAvailable;
    selectNativeEditRange(hwnd, snapshot_text, range);
}

pub const HostControls = struct {
    /// The search bar's Codicons font, created at its first use rather than
    /// with the host: registering the embedded font costs a few milliseconds
    /// of cold start, and most sessions never open the search bar. A failed
    /// creation is not retried until the next DPI or theme change.
    pub fn searchIconFont(self: *Host) ?*anyopaque {
        if (!self.search_icon_font_resolved) {
            self.search_icon_font = createSearchIconFont(self.current_dpi);
            self.search_icon_font_resolved = true;
        }
        return self.search_icon_font;
    }

    pub fn isSearchBarButton(self: *const Host, child: HWND) bool {
        const surface = self.searchControlSurface(child) orelse return false;
        return surface.searchBarButtonRole(child) != null;
    }

    pub fn isSearchBarResultsLabel(self: *const Host, child: HWND) bool {
        const surface = self.searchControlSurface(child) orelse return false;
        return surface.search_bar_results_hwnd != null and child == surface.search_bar_results_hwnd.?;
    }

    pub fn searchBarButtonRole(self: *const Host, child: HWND) ?SearchBarButtonRole {
        const surface = self.searchControlSurface(child) orelse return null;
        return surface.searchBarButtonRole(child);
    }

    pub fn searchBarButtonIcon(self: *const Host, child: HWND) ?win32_icons.Kind {
        return switch (self.searchBarButtonRole(child) orelse return null) {
            .prev => .arrow_up,
            .next => .arrow_down,
            .regex => .regex,
            .case_sensitive => .case_sens,
            .whole_word => .whole_word,
            .close => .close,
        };
    }

    pub fn searchBarButtonColors(
        self: *const Host,
        role: SearchBarButtonRole,
        active: bool,
        hovered: bool,
        pressed: bool,
        disabled: bool,
    ) ButtonColors {
        const theme = &self.app.resolved_theme;
        if (disabled) return buttonColorsFromTheme(theme, active, true, hovered, pressed, true, false, isHighContrastActive());

        const accent = overlayAccentColor(.search, theme.is_dark);
        const toolbar = searchBarToolbarVisual(theme);
        var colors: ButtonColors = .{
            .bg = searchBarButtonParentBg(theme, role),
            .border = searchBarButtonParentBg(theme, role),
            .fg = theme.text_secondary,
        };
        switch (role) {
            .prev, .next => {},
            .regex, .case_sensitive, .whole_word => {
                if (active) {
                    colors.bg = if (pressed)
                        blendColorRGB(accent, toolbar.bg, if (theme.is_dark) 0.42 else 0.28)
                    else if (hovered)
                        blendColorRGB(accent, toolbar.bg, if (theme.is_dark) 0.36 else 0.22)
                    else
                        blendColorRGB(accent, toolbar.bg, if (theme.is_dark) 0.30 else 0.18);
                    colors.border = colors.bg;
                    colors.fg = theme.text_primary;
                } else {
                    colors.bg = if (pressed)
                        adjustColor(toolbar.bg, -10, -8, -8)
                    else if (hovered)
                        adjustColor(toolbar.bg, 6, 8, 8)
                    else
                        toolbar.bg;
                    colors.border = colors.bg;
                    colors.fg = if (hovered) theme.text_primary else theme.text_secondary;
                }
            },
            .close => {
                colors.bg = if (pressed)
                    blendColorRGB(theme.error_fg, theme.overlay_bg, if (theme.is_dark) 0.18 else 0.12)
                else if (hovered)
                    blendColorRGB(theme.error_fg, theme.overlay_bg, if (theme.is_dark) 0.12 else 0.08)
                else
                    theme.overlay_bg;
                colors.border = colors.bg;
                colors.fg = if (hovered or pressed) theme.error_fg else theme.text_secondary;
            },
        }
        if (role == .prev or role == .next) {
            colors.bg = if (pressed)
                adjustColor(toolbar.bg, -10, -8, -8)
            else if (hovered)
                adjustColor(toolbar.bg, 6, 8, 8)
            else
                toolbar.bg;
            colors.border = colors.bg;
            colors.fg = if (hovered or pressed) theme.text_primary else theme.text_secondary;
        }
        return colors;
    }

    pub fn drawSearchBarBackground(self: *Host, draw: *const DRAWITEMSTRUCT) bool {
        if (draw.CtlType != c.ODT_STATIC) return false;
        const surface = self.searchBarBackgroundSurface(draw.hwndItem) orelse return false;

        const theme = &self.app.resolved_theme;
        const frame_rect = draw.rcItem;
        fillSolidRect(draw.hDC, frame_rect, theme.chrome_bg);
        drawRoundedRect(
            draw.hDC,
            frame_rect,
            searchBarFrameBg(theme),
            searchBarFrameBorder(theme),
            self.scaled(8),
        );
        fillSolidRect(draw.hDC, .{
            .left = frame_rect.left + self.scaled(8),
            .top = frame_rect.bottom - 1,
            .right = frame_rect.right - self.scaled(8),
            .bottom = frame_rect.bottom,
        }, searchBarBottomLine(theme));

        const origin_x = surface.search_bar_frame_rect.left;
        const origin_y = surface.search_bar_frame_rect.top;
        if (searchBarGroupRect(&[_]ChildPlacement{
            surface.search_bar_results_placement,
            surface.search_bar_prev_placement,
            surface.search_bar_next_placement,
            surface.search_bar_regex_placement,
            surface.search_bar_case_placement,
            surface.search_bar_word_placement,
        }, self.scaled(4), self.scaled(2))) |host_toolbar_rect| {
            const toolbar_rect = rectOffset(host_toolbar_rect, -origin_x, -origin_y);
            const toolbar = searchBarToolbarVisual(theme);
            drawRoundedRect(
                draw.hDC,
                toolbar_rect,
                toolbar.bg,
                toolbar.border,
                self.scaled(7),
            );

            const sep_top = toolbar_rect.top + self.scaled(6);
            const sep_bottom = toolbar_rect.bottom - self.scaled(6);
            if (sep_bottom > sep_top) {
                if (searchBarSeparatorX(
                    surface.search_bar_results_placement,
                    surface.search_bar_prev_placement,
                )) |host_sep_x| {
                    const sep_x = host_sep_x - origin_x;
                    fillSolidRect(draw.hDC, .{
                        .left = sep_x,
                        .top = sep_top,
                        .right = sep_x + 1,
                        .bottom = sep_bottom,
                    }, toolbar.separator);
                }
                if (searchBarSeparatorX(
                    surface.search_bar_prev_placement,
                    surface.search_bar_next_placement,
                )) |host_sep_x| {
                    const sep_x = host_sep_x - origin_x;
                    fillSolidRect(draw.hDC, .{
                        .left = sep_x,
                        .top = sep_top,
                        .right = sep_x + 1,
                        .bottom = sep_bottom,
                    }, toolbar.separator);
                }
                if (searchBarSeparatorX(
                    surface.search_bar_next_placement,
                    surface.search_bar_regex_placement,
                )) |host_sep_x| {
                    const sep_x = host_sep_x - origin_x;
                    fillSolidRect(draw.hDC, .{
                        .left = sep_x,
                        .top = sep_top,
                        .right = sep_x + 1,
                        .bottom = sep_bottom,
                    }, toolbar.separator);
                }
            }
        }

        if (surface.search_bar_edit_placement.rect_known) {
            const edit_rect = rectOffset(surface.search_bar_edit_placement.rect, -origin_x, -origin_y);
            const edit_focused = if (surface.search_bar_edit_hwnd) |edit_hwnd|
                sys.GetFocus() == edit_hwnd
            else
                false;
            const edit_frame_rect = RECT{
                .left = edit_rect.left - self.scaled(1),
                .top = edit_rect.top - self.scaled(1),
                .right = edit_rect.right + self.scaled(1),
                .bottom = edit_rect.bottom + self.scaled(1),
            };
            drawRoundedRect(
                draw.hDC,
                edit_frame_rect,
                theme.edit_frame_bg,
                theme.edit_frame_bg,
                self.scaled(6),
            );
            if (edit_focused) {
                fillSolidRect(draw.hDC, .{
                    .left = edit_frame_rect.left + self.scaled(8),
                    .top = edit_frame_rect.bottom - self.scaled(2),
                    .right = edit_frame_rect.right - self.scaled(8),
                    .bottom = edit_frame_rect.bottom,
                }, overlayAccentColor(.search, theme.is_dark));
            }
        }

        return true;
    }

    pub fn drawSearchBarButton(
        self: *Host,
        draw: *const DRAWITEMSTRUCT,
        role: SearchBarButtonRole,
        icon: win32_icons.Kind,
        disabled: bool,
        pressed: bool,
        focused: bool,
        hovered: bool,
        active: bool,
    ) void {
        const theme = &self.app.resolved_theme;
        const colors = self.searchBarButtonColors(role, active, hovered, pressed, disabled);
        const show_label = searchBarButtonShowsLabel(role, draw.rcItem.right - draw.rcItem.left);
        const bg_rect = rectInset(draw.rcItem, self.scaled(2), self.scaled(2));
        const parent_bg = searchBarButtonParentBg(theme, role);

        fillSolidRect(draw.hDC, draw.rcItem, parent_bg);
        drawRoundedRect(draw.hDC, bg_rect, colors.bg, colors.border, self.scaled(4));

        if (self.chromeFocusRingVisible(focused, disabled)) {
            drawRoundedRect(
                draw.hDC,
                rectInset(bg_rect, self.scaled(2), self.scaled(2)),
                colors.bg,
                overlayAccentColor(.search, theme.is_dark),
                self.scaled(3),
            );
        }

        const content_rect = rectInset(bg_rect, self.scaled(7), self.scaled(5));
        _ = sys.SetBkMode(draw.hDC, c.TRANSPARENT);
        _ = sys.SetTextColor(draw.hDC, colors.fg);

        if (show_label) {
            var text_buf: [160]u16 = undefined;
            const text_len = sys.GetWindowTextW(draw.hwndItem, &text_buf, text_buf.len);
            const icon_box_w = @min(content_rect.bottom - content_rect.top, self.scaled(18));
            const icon_rect = RECT{
                .left = content_rect.left,
                .top = content_rect.top,
                .right = content_rect.left + icon_box_w,
                .bottom = content_rect.bottom,
            };
            self.drawSearchButtonGlyph(draw.hDC, icon_rect, role, icon, colors.fg);

            var label_rect = content_rect;
            label_rect.left = icon_rect.right + self.scaled(5);
            _ = sys.DrawTextW(
                draw.hDC,
                @ptrCast(&text_buf),
                text_len,
                &label_rect,
                c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
            );
            return;
        }

        self.drawSearchButtonGlyph(draw.hDC, content_rect, role, icon, colors.fg);

        if (active and (role == .regex or role == .case_sensitive or role == .whole_word)) {
            fillSolidRect(draw.hDC, .{
                .left = bg_rect.left + self.scaled(6),
                .top = bg_rect.bottom - self.scaled(3),
                .right = bg_rect.right - self.scaled(6),
                .bottom = bg_rect.bottom - self.scaled(1),
            }, overlayAccentColor(.search, theme.is_dark));
        }
    }

    /// Draw a search button's Codicon centred in `rect`, falling back to the
    /// geometric `fallback` icon when the font is missing or the glyph cannot
    /// be drawn.
    pub fn drawSearchButtonGlyph(
        self: *Host,
        hdc: HDC,
        rect: RECT,
        role: SearchBarButtonRole,
        fallback: win32_icons.Kind,
        color: u32,
    ) void {
        const hdc_nn: *anyopaque = hdc orelse return;
        if (self.searchIconFont()) |font_handle| {
            const glyph = searchButtonCodicon(role);
            if (sys.SelectObject(hdc, font_handle)) |old_font| {
                defer _ = sys.SelectObject(hdc, old_font);
                _ = sys.SetBkMode(hdc, c.TRANSPARENT);
                _ = sys.SetTextColor(hdc, color);
                var glyph_rect = rect;
                // Whole-word's bracket spans its full advance, 16 px at
                // 100%, wider than the 12 px wide padded content box;
                // clipping to the box cut off both ends of the bracket.
                if (sys.DrawTextW(
                    hdc,
                    glyph.ptr,
                    @intCast(glyph.len),
                    &glyph_rect,
                    c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_NOCLIP,
                ) != 0) return;
            }
        }
        win32_icons.drawIcon(fallback, hdc_nn, .{
            .left = rect.left,
            .top = rect.top,
            .right = rect.right,
            .bottom = rect.bottom,
        }, color, isHighContrastActive());
    }
};

pub const SurfaceControls = struct {
    pub fn searchBarButtonHwnd(self: *const Surface, role: SearchBarButtonRole) ?HWND {
        return switch (role) {
            .prev => self.search_bar_prev_hwnd,
            .next => self.search_bar_next_hwnd,
            .regex => self.search_bar_regex_hwnd,
            .case_sensitive => self.search_bar_case_hwnd,
            .whole_word => self.search_bar_word_hwnd,
            .close => self.search_bar_close_hwnd,
        };
    }

    fn searchControlUiaName(_: *anyopaque, tag: usize, _: []u8) []const u8 {
        return labels.searchBarButtonName(@enumFromInt(tag));
    }

    fn searchToggleUiaState(ctx: *anyopaque, tag: usize) bool {
        const self: *Surface = @ptrCast(@alignCast(ctx));
        return self.searchBarButtonActive(@enumFromInt(tag));
    }

    fn searchResultsUiaName(ctx: *anyopaque, _: usize, buf: []u8) []const u8 {
        const self: *Surface = @ptrCast(@alignCast(ctx));
        return if (self.search_bar_results_cache) |text|
            std.fmt.bufPrint(buf, "{s}", .{text}) catch "Search results"
        else
            "Search results";
    }

    pub fn searchLabelUiaProvider(self: *Surface, hwnd: HWND) ?*win32_uia.ChromeControlProvider {
        if (self.search_bar_bg_hwnd == hwnd) return self.search_bar_bg_uia_provider;
        if (self.search_bar_results_hwnd == hwnd) return self.search_bar_results_uia_provider;
        return null;
    }

    pub fn searchLabelPrevProc(self: *Surface, hwnd: HWND) ?*const anyopaque {
        if (self.search_bar_bg_hwnd == hwnd) return self.search_bar_label_prev_procs[0];
        if (self.search_bar_results_hwnd == hwnd) return self.search_bar_label_prev_procs[1];
        return null;
    }

    pub fn searchEditUiaState(self: *Surface) win32_uia.TerminalState {
        return .{
            .ctx = @ptrCast(self),
            .name = &searchEditNameThunk,
            .value = &searchEditValueThunk,
            .snapshot = &searchEditSnapshotThunk,
            .focused = &searchEditFocusedThunk,
            .role = .edit,
            .use_com_threading = self.app.com_initialized,
            .set_value = &searchEditSetValueThunk,
            .select_range = &searchEditSelectRangeThunk,
        };
    }

    pub fn raiseSearchEditSelectionChangedIfNeeded(self: *Surface) void {
        const hwnd = self.search_bar_edit_hwnd orelse return;
        const provider = self.search_bar_edit_uia_provider orelse return;
        const selection = nativeEditSelection(hwnd);
        if (self.search_bar_edit_uia_selection) |previous| {
            if (std.meta.eql(previous, selection)) return;
        }
        self.search_bar_edit_uia_selection = selection;
        provider.raiseTextSelectionChanged();
    }

    pub fn searchBarButtonPlacement(self: *Surface, role: SearchBarButtonRole) *ChildPlacement {
        return switch (role) {
            .prev => &self.search_bar_prev_placement,
            .next => &self.search_bar_next_placement,
            .regex => &self.search_bar_regex_placement,
            .case_sensitive => &self.search_bar_case_placement,
            .whole_word => &self.search_bar_word_placement,
            .close => &self.search_bar_close_placement,
        };
    }

    pub fn searchBarButtonRole(self: *const Surface, hwnd: HWND) ?SearchBarButtonRole {
        for (search_bar_button_roles) |role| {
            if (self.searchBarButtonHwnd(role)) |button_hwnd| {
                if (hwnd == button_hwnd) return role;
            }
        }
        return null;
    }

    pub fn searchBarButtonActive(self: *const Surface, role: SearchBarButtonRole) bool {
        const options = self.docked_search.view().options;
        return switch (role) {
            .regex => options.regex,
            .case_sensitive => options.case_sensitive,
            .whole_word => options.whole_word,
            else => false,
        };
    }

    pub fn ownsSearchBarControl(self: *const Surface, hwnd: HWND) bool {
        if (self.search_bar_edit_hwnd != null and hwnd == self.search_bar_edit_hwnd.?) return true;
        if (self.search_bar_results_hwnd != null and hwnd == self.search_bar_results_hwnd.?) return true;
        return self.searchBarButtonRole(hwnd) != null;
    }

    pub fn searchBarButtonPrevProc(self: *const Surface, hwnd: HWND) ?*const anyopaque {
        const role = self.searchBarButtonRole(hwnd) orelse return null;
        return self.search_bar_button_prev_procs[@intFromEnum(role)];
    }

    pub fn applySearchBarFont(self: *Surface, font: ?*anyopaque) void {
        const value = if (font) |f| @intFromPtr(f) else 0;
        if (self.search_bar_edit_hwnd) |hwnd| _ = sys.SendMessageW(hwnd, c.WM_SETFONT, value, 1);
        for (search_bar_button_roles) |role| {
            if (self.searchBarButtonHwnd(role)) |hwnd| _ = sys.SendMessageW(hwnd, c.WM_SETFONT, value, 1);
        }
        if (self.search_bar_results_hwnd) |hwnd| _ = sys.SendMessageW(hwnd, c.WM_SETFONT, value, 1);
    }

    pub fn invalidateSearchButtons(self: *Surface) void {
        for (search_bar_button_roles) |role| {
            if (self.searchBarButtonHwnd(role)) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        }
    }

    pub fn invalidateSearchBarChildPaint(self: *Surface) void {
        if (!self.search_bar_frame_visible) return;
        const handles = [_]?HWND{
            self.search_bar_bg_hwnd,
            self.search_bar_edit_hwnd,
            self.search_bar_prev_hwnd,
            self.search_bar_next_hwnd,
            self.search_bar_regex_hwnd,
            self.search_bar_case_hwnd,
            self.search_bar_word_hwnd,
            self.search_bar_close_hwnd,
            self.search_bar_results_hwnd,
        };
        for (handles) |maybe_hwnd| {
            if (maybe_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        }
    }

    pub fn invalidateSearchBarFrameRect(self: *Surface, rect: RECT) void {
        if (rect.right <= rect.left or rect.bottom <= rect.top) return;
        const host = self.host orelse return;
        const hwnd = host.hwnd orelse return;
        _ = sys.InvalidateRect(hwnd, &rect, 0);
    }

    pub fn invalidateSearchBarFrame(self: *Surface) void {
        if (!self.search_bar_frame_visible) return;
        self.invalidateSearchBarFrameRect(self.search_bar_frame_rect);
    }

    pub fn updateSearchBarFrameRect(self: *Surface, frame_rect: RECT) void {
        const was_visible = self.search_bar_frame_visible;
        const old_rect = self.search_bar_frame_rect;
        self.search_bar_frame_rect = frame_rect;
        self.search_bar_frame_visible = true;
        if (!was_visible or !rectEquals(old_rect, frame_rect)) {
            if (was_visible) self.invalidateSearchBarFrameRect(old_rect);
            self.invalidateSearchBarFrameRect(frame_rect);
        }
    }

    pub fn invalidateSearchBarLayoutCache(self: *Surface) void {
        self.invalidateSearchBarFrame();
        self.search_bar_bg_placement.rect_known = false;
        self.search_bar_edit_placement.rect_known = false;
        self.search_bar_prev_placement.rect_known = false;
        self.search_bar_next_placement.rect_known = false;
        self.search_bar_regex_placement.rect_known = false;
        self.search_bar_case_placement.rect_known = false;
        self.search_bar_word_placement.rect_known = false;
        self.search_bar_close_placement.rect_known = false;
        self.search_bar_results_placement.rect_known = false;
        self.search_bar_frame_visible = false;
        self.search_bar_frame_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }

    pub fn hideSearchBarControls(self: *Surface) bool {
        var changed = false;
        if (self.search_bar_frame_visible) {
            self.invalidateSearchBarFrame();
            changed = true;
        }
        if (self.search_bar_bg_hwnd) |hwnd| {
            changed = applyChildVisibility(hwnd, &self.search_bar_bg_placement, false) or changed;
        }
        if (self.search_bar_edit_hwnd) |hwnd| {
            changed = applyChildVisibility(hwnd, &self.search_bar_edit_placement, false) or changed;
        }
        for (search_bar_button_roles) |role| {
            if (self.searchBarButtonHwnd(role)) |hwnd| {
                changed = applyChildVisibility(hwnd, self.searchBarButtonPlacement(role), false) or changed;
            }
        }
        if (self.search_bar_results_hwnd) |hwnd| {
            changed = applyChildVisibility(hwnd, &self.search_bar_results_placement, false) or changed;
        }
        self.search_bar_frame_visible = false;
        self.search_bar_frame_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        return changed;
    }

    pub fn createSearchBarButton(self: *Surface, host: *Host, parent: HWND, role: SearchBarButtonRole) !HWND {
        const hwnd = sys.CreateWindowExW(
            0,
            prompt_button_class,
            searchBarButtonLabel(role),
            c.WS_CHILD | c.WS_TABSTOP | c.BS_OWNERDRAW,
            0,
            0,
            28,
            host_search_bar_height - 10,
            parent,
            @ptrFromInt(searchBarButtonCommandId(role)),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        host.subclassButton(
            hwnd,
            &hostButtonProc,
            &self.search_bar_button_prev_procs[@intFromEnum(role)],
        );
        self.search_bar_button_uia_providers[@intFromEnum(role)] = self.createChromeUiaProvider(hwnd, .{
            .ctx = @ptrCast(self),
            .role = switch (role) {
                .regex, .case_sensitive, .whole_word => .toggle,
                else => .button,
            },
            .tag = @intFromEnum(role),
            .name = &searchControlUiaName,
            .toggled = if (role == .regex or role == .case_sensitive or role == .whole_word)
                &searchToggleUiaState
            else
                null,
        });
        return hwnd;
    }

    pub fn ensureSearchBarControls(self: *Surface) !void {
        if (self.search_bar_edit_hwnd != null) return;

        const host = self.host orelse return;
        const hwnd = host.hwnd orelse return;

        self.search_bar_bg_hwnd = sys.CreateWindowExW(
            0,
            prompt_label_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD | c.WS_CLIPSIBLINGS | c.SS_OWNERDRAW,
            0,
            0,
            160,
            host_search_bar_height,
            hwnd,
            @ptrFromInt(c.SEARCH_BG_ID),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        _ = sys.SetWindowLongPtrW(
            self.search_bar_bg_hwnd.?,
            c.GWLP_USERDATA,
            @as(LONG_PTR, @intCast(@intFromPtr(self))),
        );
        const background_previous = sys.SetWindowLongPtrW(
            self.search_bar_bg_hwnd.?,
            c.GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(&searchLabelProc))),
        );
        self.search_bar_label_prev_procs[0] = if (background_previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(background_previous)));
        self.search_bar_bg_uia_provider = self.createChromeUiaProvider(self.search_bar_bg_hwnd.?, .{
            .ctx = @ptrCast(self),
            .role = .decorative,
            .name = &decorativeUiaName,
        });

        self.search_bar_edit_hwnd = sys.CreateWindowExW(
            0,
            prompt_edit_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
            0,
            0,
            160,
            host_search_bar_height - 10,
            hwnd,
            @ptrFromInt(c.SEARCH_EDIT_ID),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        const edit_hwnd = self.search_bar_edit_hwnd.?;
        setWindowData(edit_hwnd, host);
        const edit_prev = sys.SetWindowLongPtrW(
            edit_hwnd,
            c.GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(&searchEditProc))),
        );
        self.search_bar_edit_prev_proc = if (edit_prev == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(edit_prev)));
        const edit_margin = @as(u16, @intCast(@max(host.scaled(10), 6)));
        const packed_margins: isize = @intCast(@as(usize, edit_margin) | (@as(usize, edit_margin) << 16));
        _ = sys.SendMessageW(
            edit_hwnd,
            c.EM_SETMARGINS,
            c.EC_LEFTMARGIN | c.EC_RIGHTMARGIN,
            packed_margins,
        );
        _ = sys.SendMessageW(edit_hwnd, c.EM_SETCUEBANNER, 0, @as(LPARAM, @intCast(@intFromPtr(search_edit_cue.ptr))));
        self.search_bar_edit_uia_provider = if (self.app.com_initialized)
            win32_uia.TerminalProvider.create(
                std.heap.page_allocator,
                edit_hwnd,
                self.searchEditUiaState(),
            ) catch |err| blk: {
                log.warn("search edit UIA provider unavailable err={}", .{err});
                break :blk null;
            }
        else blk: {
            log.debug("search edit UIA provider disabled: UI thread is not a confirmed STA", .{});
            break :blk null;
        };

        self.search_bar_prev_hwnd = try self.createSearchBarButton(host, hwnd, .prev);
        self.search_bar_next_hwnd = try self.createSearchBarButton(host, hwnd, .next);
        self.search_bar_regex_hwnd = try self.createSearchBarButton(host, hwnd, .regex);
        self.search_bar_case_hwnd = try self.createSearchBarButton(host, hwnd, .case_sensitive);
        self.search_bar_word_hwnd = try self.createSearchBarButton(host, hwnd, .whole_word);
        self.search_bar_close_hwnd = try self.createSearchBarButton(host, hwnd, .close);

        self.search_bar_results_hwnd = sys.CreateWindowExW(
            0,
            prompt_label_class,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD | c.SS_RIGHT | c.SS_CENTERIMAGE,
            0,
            0,
            96,
            18,
            hwnd,
            @ptrFromInt(c.SEARCH_RESULTS_ID),
            self.app.hinstance,
            null,
        ) orelse return lastError();
        _ = sys.SetWindowLongPtrW(
            self.search_bar_results_hwnd.?,
            c.GWLP_USERDATA,
            @as(LONG_PTR, @intCast(@intFromPtr(self))),
        );
        const results_previous = sys.SetWindowLongPtrW(
            self.search_bar_results_hwnd.?,
            c.GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(&searchLabelProc))),
        );
        self.search_bar_label_prev_procs[1] = if (results_previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(results_previous)));
        self.search_bar_results_uia_provider = self.createChromeUiaProvider(self.search_bar_results_hwnd.?, .{
            .ctx = @ptrCast(self),
            .role = .live_text,
            .name = &searchResultsUiaName,
        });

        self.applySearchBarFont(host.chrome_font);
        _ = try self.syncSearchBarResultsText();
        _ = self.hideSearchBarControls();
    }

    pub fn destroySearchBarControls(self: *Surface) void {
        const alloc = self.app.core_app.alloc;
        detachChromeControlProvider(self.app, &self.search_bar_bg_uia_provider);
        detachChromeControlProvider(self.app, &self.search_bar_results_uia_provider);
        for (&self.search_bar_button_uia_providers) |*provider| {
            detachChromeControlProvider(self.app, provider);
        }
        if (self.search_bar_edit_uia_provider) |provider| {
            self.search_bar_edit_uia_provider = null;
            self.search_bar_edit_uia_selection = null;
            provider.detach();
            scheduleDeferredUiaDisconnect(
                self.app,
                @ptrCast(provider),
                &terminalDisconnectThunk,
                &terminalReleaseThunk,
            );
        }
        if (self.search_bar_results_cache) |value| {
            alloc.free(value);
            self.search_bar_results_cache = null;
        }
        if (self.search_bar_results_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_close_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_word_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_case_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_regex_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_next_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_prev_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_edit_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        if (self.search_bar_bg_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);

        self.search_bar_results_hwnd = null;
        self.search_bar_close_hwnd = null;
        self.search_bar_word_hwnd = null;
        self.search_bar_case_hwnd = null;
        self.search_bar_regex_hwnd = null;
        self.search_bar_next_hwnd = null;
        self.search_bar_prev_hwnd = null;
        self.search_bar_edit_hwnd = null;
        self.search_bar_bg_hwnd = null;
        self.search_bar_edit_prev_proc = null;
        self.search_bar_button_prev_procs = [_]?*const anyopaque{null} ** 6;
        self.search_bar_button_uia_providers = [_]?*win32_uia.ChromeControlProvider{null} ** 6;
        self.search_bar_label_prev_procs = .{ null, null };
        self.search_bar_bg_placement = .{};
        self.search_bar_edit_placement = .{};
        self.search_bar_prev_placement = .{};
        self.search_bar_next_placement = .{};
        self.search_bar_regex_placement = .{};
        self.search_bar_case_placement = .{};
        self.search_bar_word_placement = .{};
        self.search_bar_close_placement = .{};
        self.search_bar_results_placement = .{};
        self.search_bar_frame_visible = false;
        self.search_bar_frame_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }

    /// Hides a search bar button the pane is too narrow for. The edit takes
    /// the focus the button had: hiding the window that has it leaves the
    /// keyboard with no window of ours.
    pub fn hideSearchBarButton(self: *Surface, role: SearchBarButtonRole) bool {
        const hwnd = self.searchBarButtonHwnd(role) orelse return false;
        if (sys.GetFocus() == hwnd) {
            if (self.search_bar_edit_hwnd) |edit| _ = sys.SetFocus(edit);
        }
        return applyChildVisibility(hwnd, self.searchBarButtonPlacement(role), false);
    }

    /// Places a search bar button at `rect` and shows it. The controls
    /// exist once `ensureSearchBarControls` has run.
    pub fn showSearchBarButton(self: *Surface, role: SearchBarButtonRole, rect: RECT) bool {
        const hwnd = self.searchBarButtonHwnd(role).?;
        const placement = self.searchBarButtonPlacement(role);
        // Both run: a move and a show are separate changes.
        const moved = applyChildRect(hwnd, placement, rect);
        const shown = applyChildVisibility(hwnd, placement, true);
        return moved or shown;
    }

    pub fn layoutSearchBarControls(self: *Surface, frame_rect: RECT, visible: bool) !bool {
        const search = self.docked_search.view();
        if (!visible or !search.open) return self.hideSearchBarControls();

        try self.ensureSearchBarControls();
        const host = self.host orelse return false;

        var changed = false;
        var bg_changed = false;
        const layout = searchBarChromeLayout(host.current_dpi);
        const fit = searchBarFit(frame_rect.right - frame_rect.left, layout);
        const control_top = frame_rect.top + layout.pad_y;
        const left = frame_rect.left + layout.pad_x;
        var right = frame_rect.right - layout.pad_x;

        self.updateSearchBarFrameRect(frame_rect);
        bg_changed = applyChildRect(
            self.search_bar_bg_hwnd.?,
            &self.search_bar_bg_placement,
            frame_rect,
        );
        changed = bg_changed or changed;

        changed = self.showSearchBarButton(
            .close,
            childRect(right - layout.close_w, control_top, layout.close_w, layout.control_h),
        ) or changed;
        right -= layout.close_w + layout.close_gap;

        if (fit.toggles) {
            changed = self.showSearchBarButton(
                .whole_word,
                childRect(right - layout.toggle_w, control_top, layout.toggle_w, layout.control_h),
            ) or changed;
            right -= layout.toggle_w + layout.gap;

            changed = self.showSearchBarButton(
                .case_sensitive,
                childRect(right - layout.toggle_w, control_top, layout.toggle_w, layout.control_h),
            ) or changed;
            right -= layout.toggle_w + layout.gap;

            changed = self.showSearchBarButton(
                .regex,
                childRect(right - layout.toggle_w, control_top, layout.toggle_w, layout.control_h),
            ) or changed;
            right -= layout.toggle_w + layout.section_gap;
        } else {
            changed = self.hideSearchBarButton(.whole_word) or changed;
            changed = self.hideSearchBarButton(.case_sensitive) or changed;
            changed = self.hideSearchBarButton(.regex) or changed;
        }

        if (fit.nav) {
            changed = self.showSearchBarButton(
                .next,
                childRect(right - layout.nav_w, control_top, layout.nav_w, layout.control_h),
            ) or changed;
            right -= layout.nav_w + layout.gap;

            changed = self.showSearchBarButton(
                .prev,
                childRect(right - layout.nav_w, control_top, layout.nav_w, layout.control_h),
            ) or changed;
            right -= layout.nav_w + layout.section_gap;
        } else {
            changed = self.hideSearchBarButton(.next) or changed;
            changed = self.hideSearchBarButton(.prev) or changed;
        }

        const show_results = search.chip and
            (right - layout.results_w - layout.section_gap - left) >= layout.min_edit_w;
        if (show_results) {
            changed = applyChildRect(
                self.search_bar_results_hwnd.?,
                &self.search_bar_results_placement,
                childRect(right - layout.results_w, control_top, layout.results_w, layout.control_h),
            ) or changed;
            changed = applyChildVisibility(
                self.search_bar_results_hwnd.?,
                &self.search_bar_results_placement,
                true,
            ) or changed;
            right -= layout.results_w + layout.section_gap;
        } else {
            changed = applyChildVisibility(
                self.search_bar_results_hwnd.?,
                &self.search_bar_results_placement,
                false,
            ) or changed;
        }

        changed = applyChildRect(
            self.search_bar_edit_hwnd.?,
            &self.search_bar_edit_placement,
            childRect(left, control_top, @max(1, right - left), layout.control_h),
        ) or changed;
        changed = applyChildVisibility(
            self.search_bar_edit_hwnd.?,
            &self.search_bar_edit_placement,
            true,
        ) or changed;
        const bg_visibility_changed = applyChildVisibility(
            self.search_bar_bg_hwnd.?,
            &self.search_bar_bg_placement,
            true,
        );
        changed = bg_visibility_changed or changed;
        if (changed) {
            if (self.search_bar_bg_hwnd) |bg_hwnd| _ = sys.InvalidateRect(bg_hwnd, null, 0);
        }

        return changed;
    }

    fn setSearchBarEditText(self: *Surface, value: []const u8) !bool {
        const edit_hwnd = self.search_bar_edit_hwnd orelse return false;
        const host = self.host orelse return false;
        const current = try self.readSearchBarEditText();
        defer self.app.core_app.alloc.free(current);
        if (std.mem.eql(u8, current, value)) return false;
        host.suppress_edit_events = true;
        defer host.suppress_edit_events = false;

        const value_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, value);
        defer self.app.core_app.alloc.free(value_w);
        if (sys.SetWindowTextW(edit_hwnd, value_w.ptr) == 0) {
            return lastError();
        }
        if (self.search_bar_edit_uia_provider) |provider| {
            provider.raiseTextChanged();
            provider.raiseValueChanged();
        }
        self.raiseSearchEditSelectionChangedIfNeeded();
        return true;
    }

    pub fn readSearchBarEditText(self: *Surface) ![:0]u8 {
        const edit_hwnd = self.search_bar_edit_hwnd orelse return try self.app.core_app.alloc.dupeZ(u8, "");
        return try readWindowTextUtf8Alloc(self.app.core_app.alloc, edit_hwnd);
    }

    pub fn syncSearchBarResultsText(self: *Surface) !bool {
        const hwnd = self.search_bar_results_hwnd orelse return false;
        var buf: [48]u8 = undefined;
        const changed = try syncWindowTextUtf8Cached(
            self.app.core_app.alloc,
            hwnd,
            &self.search_bar_results_cache,
            self.docked_search.view().results.text(&buf),
        );
        if (changed) {
            if (self.search_bar_results_uia_provider) |provider| provider.raiseLiveRegionChanged();
        }
        return changed;
    }

    pub fn handleSearchBarEditChanged(self: *Surface) !bool {
        const text = try self.readSearchBarEditText();
        defer self.app.core_app.alloc.free(text);
        return try self.dockedSearch(.{ .edit = text });
    }

    /// Hands `in` to this pane's search and carries out what it returns.
    /// True when the input was search's (a window procedure returns 0).
    /// The core calls back into this synchronously, so the error set is
    /// explicit: dockedSearch, the core, App.performAction, dockedSearch.
    pub fn dockedSearch(self: *Surface, in: docked_search.Input) anyerror!bool {
        switch (in) {
            .open => {
                const host = self.host orelse return false;
                if (host.overlay_mode != .none) host.hideOverlay();
                try self.ensureSearchBarControls();
            },
            .core => |core| if (core == .ended and self.host == null) return false,
            else => {},
        }
        const out = try self.docked_search.apply(in, @intCast(sys.GetTickCount64()));
        try applyDockedSearch(self, out);
        return out.handled;
    }
};

/// Carries out an Outcome. Nothing after the core step may use a View taken
/// before it: the core's synchronous reports can free what it borrows.
fn applyDockedSearch(self: *Surface, out: docked_search.Outcome) anyerror!void {
    if (out.toggled) |role| {
        const now = self.searchBarButtonActive(role);
        if (self.search_bar_button_uia_providers[@intFromEnum(role)]) |provider| {
            provider.raiseToggleChanged(!now, now);
        }
        self.invalidateSearchButtons();
    }
    if (out.results_changed) _ = try self.syncSearchBarResultsText();
    if (out.markers_changed) {
        self.clearScrollbarMarkers();
        try self.refreshScrollbarWindow();
    }
    switch (out.frame) {
        .same => {},
        .relayout => if (self.host) |host| try host.layout(),
        .shown => if (self.host) |host| {
            _ = try SurfaceControls.setSearchBarEditText(self, self.docked_search.view().query);
            try host.layout();
            host.forceHostCompositionPaint();
            if (self.search_bar_edit_hwnd) |edit_hwnd| {
                _ = sys.SetFocus(edit_hwnd);
                _ = sys.SendMessageW(edit_hwnd, c.EM_SETSEL, 0, -1);
            }
        },
        .hidden => {
            _ = self.hideSearchBarControls();
            if (self.host) |host| {
                try host.layout();
                host.forceHostCompositionPaint();
            }
        },
    }
    if (out.timer_changed) {
        if (self.host) |host| host.refreshSearchTimerState();
    }
    if (out.core) |command| switch (command) {
        .search => |search| _ = try self.core_surface.setSearchQuery(search.text, search.options),
        .stop => _ = try self.core_surface.setSearchQuery("", .{}),
        .invalidate => _ = try self.core_surface.invalidateSearchResults(),
        .navigate => |dir| _ = try self.core_surface.performBindingAction(.{ .navigate_search = dir }),
        .end => _ = try self.core_surface.endSearch(),
    };
    if (out.focus_terminal) {
        if (self.hwnd) |hwnd| _ = sys.SetFocus(hwnd);
    }
}

pub fn searchButtonKey(v: *Host, hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) ?LRESULT {
    // Alt+R / Alt+C / Alt+W flip the search flags from a focused search
    // button too. Alt is a system key, so the press is a WM_SYSKEYDOWN,
    // and its WM_SYSCHAR is swallowed or `DefWindowProc` turns it into a
    // menu request.
    if ((msg == c.WM_SYSKEYDOWN or msg == c.WM_SYSCHAR) and v.isSearchBarButton(hwnd)) {
        if (v.searchControlSurface(hwnd)) |surface| {
            if (msg == c.WM_SYSKEYDOWN) {
                v.noteChromeKeyInput(c.VK_TAB);
                if (searchToggleKey(surface, wParam, lParam)) return 0;
            } else if (surface.docked_search.toggle_keys.consumeChar(lParamBits(lParam))) {
                return 0;
            }
        }
    }
    if (msg == c.WM_KEYDOWN and v.isSearchBarButton(hwnd)) {
        if (v.searchControlSurface(hwnd)) |surface| {
            if (searchButtonKeyAction(wParam, keyPressed(c.VK_SHIFT))) |action| {
                if (dockedSearchCoreDirectionFromKeyAction(action)) |dir| {
                    _ = surface.dockedSearch(.{ .click = navigateClick(dir) }) catch |err| {
                        logUiActionError("docked search button navigation failed", err);
                    };
                    return 0;
                }
                switch (action) {
                    .dismiss => {
                        _ = v.dismissActiveSearch();
                        return 0;
                    },
                    else => {},
                }
            }
        }
    }
    return null;
}

test "win32 searchBarGroupRect ignores hidden placements" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const shown = ChildPlacement{
        .rect = .{ .left = 20, .top = 10, .right = 40, .bottom = 30 },
        .rect_known = true,
        .visible = true,
        .visible_known = true,
    };
    const hidden = ChildPlacement{
        .rect = .{ .left = 100, .top = 10, .right = 140, .bottom = 30 },
        .rect_known = true,
        .visible = false,
        .visible_known = true,
    };

    const rect = searchBarGroupRect(&[_]ChildPlacement{ shown, hidden }, 2, 1).?;
    try std.testing.expectEqualDeep(RECT{
        .left = 18,
        .top = 9,
        .right = 42,
        .bottom = 31,
    }, rect);
}

test "win32 search bar codicons exist in the embedded symbols font" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Each button is one UTF-16 unit, which `fontHasSearchCodicons` looks up.
    for (search_bar_button_roles) |role| {
        try std.testing.expectEqual(@as(usize, 1), searchButtonCodicon(role).len);
    }

    // The registered font has every button's glyph, so a Nerd Fonts update
    // that renumbers a Codicon fails here rather than drawing an empty box.
    for ([_]u32{ 96, 144 }) |dpi| {
        const font = createSearchIconFont(dpi) orelse return error.FontCreateFailed;
        _ = sys.DeleteObject(font);
    }
}

test "win32 search bar codicons are rejected in a substitute font" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Arial is what GDI substituted for a missing icon face on Windows 10.
    const font = createIconFontForFace(
        std.unicode.utf8ToUtf16LeStringLiteral("Arial"),
        search_icon_font_px,
    ) orelse return error.FontCreateFailed;
    defer _ = sys.DeleteObject(font);
    try std.testing.expect(!fontHasSearchCodicons(font));
}

test "win32 search bar icon font is created at first use and dropped on a DPI or theme change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var host: Host = undefined;
    var session: TestSession = .{};
    try session.init(.{
        .core_app = &core_app,
        .app = &app,
        .hosts = &.{.{ .storage = &host }},
    });
    defer session.deinit();
    defer {
        if (host.titlebar_caption_icon_font) |font| _ = sys.DeleteObject(font);
        if (host.titlebar_action_icon_font) |font| _ = sys.DeleteObject(font);
        if (host.search_icon_font) |font| _ = sys.DeleteObject(font);
    }

    // `createHost` runs this before the first frame.
    host.recreateTitlebarIconFonts();
    try std.testing.expect(host.search_icon_font == null);

    const font = host.searchIconFont() orelse return error.FontCreateFailed;
    try std.testing.expectEqual(font, host.searchIconFont().?);

    // A DPI or theme change drops it, to be created again at the next use.
    host.recreateTitlebarIconFonts();
    try std.testing.expect(host.search_icon_font == null);
    try std.testing.expect(!host.search_icon_font_resolved);
}
