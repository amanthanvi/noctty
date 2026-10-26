//! Parent chrome scene, cached paint text, and repaint scopes. Host retains coordination.
const win32 = @import("../win32.zig");
const runtime = win32.chrome_scene_runtime;
const Allocator = runtime.Allocator;
const CaptionButton = runtime.CaptionButton;
const ChildPlacement = runtime.ChildPlacement;
const ChromeRepaintMask = runtime.ChromeRepaintMask;
const HDC = runtime.HDC;
const HWND = runtime.HWND;
const Host = runtime.Host;
const HostTabStatus = runtime.HostTabStatus;
const PAINTSTRUCT = runtime.PAINTSTRUCT;
const POINT = runtime.POINT;
const RECT = runtime.RECT;
const ThemeColors = runtime.ThemeColors;
const TitlebarButtonRole = runtime.TitlebarButtonRole;
const TitlebarGlyphKind = runtime.TitlebarGlyphKind;
const buildInspectorPanelHintText = runtime.buildInspectorPanelHintText;
const buildInspectorPanelTitleText = runtime.buildInspectorPanelTitleText;
const buildOverlayFeedbackText = runtime.buildOverlayFeedbackText;
const buildOverlayPaintLabelText = runtime.buildOverlayPaintLabelText;
const buildProfileChromeBadgeText = runtime.buildProfileChromeBadgeText;
const buildProfileHintText = runtime.buildProfileHintText;
const buildProfileOverlayLabel = runtime.buildProfileOverlayLabel;
const c = runtime.c;
const centeredRect = runtime.centeredRect;
const clientTitlebarTheme = runtime.clientTitlebarTheme;
const confirmBodyPaintRect = runtime.confirmBodyPaintRect;
const confirmTitlePaintRect = runtime.confirmTitlePaintRect;
const confirm_prompt_text_format = runtime.confirm_prompt_text_format;
const drawRoundedRect = runtime.drawRoundedRect;
const drawTextWz = runtime.drawTextWz;
const fillSolidRect = runtime.fillSolidRect;
const host_inspector_panel_height = runtime.host_inspector_panel_height;
const host_overlay_accept_width = runtime.host_overlay_accept_width;
const host_overlay_cancel_width = runtime.host_overlay_cancel_width;
const host_overlay_height = runtime.host_overlay_height;
const host_overlay_label_width = runtime.host_overlay_label_width;
const host_overlay_padding = runtime.host_overlay_padding;
const host_overlay_row_height = runtime.host_overlay_row_height;
const isHighContrastActive = runtime.isHighContrastActive;
const overlayAccentColor = runtime.overlayAccentColor;
const overlayActionLayoutForWidth = runtime.overlayActionLayoutForWidth;
const overlayEditBorderColor = runtime.overlayEditBorderColor;
const overlayEditFrameRect = runtime.overlayEditFrameRect;
const overlayEditFrameVisible = runtime.overlayEditFrameVisible;
const overlayEditText = runtime.overlayEditText;
const overlayFeedbackLineRect = runtime.overlayFeedbackLineRect;
const overlayLabelReservation = runtime.overlayLabelReservation;
const overlayPaintCacheDirty = runtime.overlayPaintCacheDirty;
const paintRectVisible = runtime.paintRectVisible;
const paint_text = runtime.paint_text;
const profileChromeAccent = runtime.profileChromeAccent;
const profileKindHintColor = runtime.profileKindHintColor;
const profileKindLabelColor = runtime.profileKindLabelColor;
const restoreFont = runtime.restoreFont;
const searchBarGroupRect = runtime.searchBarGroupRect;
const searchBarSeparatorX = runtime.searchBarSeparatorX;
const searchBarToolbarVisual = runtime.searchBarToolbarVisual;
const std = runtime.std;
const sys = runtime.sys;
const tabAccent = runtime.tabAccent;
const textOutWz = runtime.textOutWz;
const themeSurface = runtime.themeSurface;
const titlebarButtonVisual = runtime.titlebarButtonVisual;
const titlebarFallbackIcon = runtime.titlebarFallbackIcon;
const titlebarGlyphText = runtime.titlebarGlyphText;
const win32_chrome_state = runtime.win32_chrome_state;
const win32_icons = runtime.win32_icons;
const win32_nc_layout = runtime.win32_nc_layout;
const win32_theme = runtime.win32_theme;
const test_runtime = if (@import("builtin").is_test) win32.chrome_scene_test_runtime else struct {};
const App = test_runtime.App;
const CoreApp = test_runtime.CoreApp;
const TestSession = test_runtime.TestSession;
const builtin = test_runtime.builtin;

pub const HostScene = struct {
    pub fn repaintChrome(self: *Host) void {
        var mask: ChromeRepaintMask = .{};
        mask.markChrome();
        self.queueChromeRepaint(mask);
    }

    pub fn repaintFullHost(self: *Host) void {
        self.queueChromeRepaint(.{
            .top = true,
            .content = true,
        });
    }

    pub fn invalidateChromeMask(self: *Host, hwnd: HWND, mask: ChromeRepaintMask) void {
        if (mask.isEmpty()) return;
        var client_rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client_rect) == 0) return;
        const content_rect = self.contentRect() catch return;

        if (mask.top) {
            const top_rect = RECT{
                .left = client_rect.left,
                .top = client_rect.top,
                .right = client_rect.right,
                .bottom = @max(client_rect.top, content_rect.top),
            };
            if (top_rect.bottom > top_rect.top) {
                _ = sys.InvalidateRect(hwnd, &top_rect, 0);
            }
        }

        if (mask.content) {
            if (content_rect.bottom > content_rect.top) {
                _ = sys.InvalidateRect(hwnd, &content_rect, 0);
            }
        } else if (mask.search_frames) {
            if (self.activeTab()) |tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| {
                    if (!entry.view.search_bar_frame_visible) continue;
                    _ = sys.InvalidateRect(hwnd, &entry.view.search_bar_frame_rect, 0);
                }
            }
        }
    }

    pub fn queueChromeRepaint(self: *Host, mask: ChromeRepaintMask) void {
        self.chrome_repaint_dirty = true;
        const hwnd = self.hwnd orelse return;
        const added = win32_chrome_state.mergeRepaintMask(&self.chrome_paint_mask, mask);
        if (added.isEmpty()) return;
        self.chrome_paint_pending = true;
        self.invalidateChromeMask(hwnd, added);
    }

    pub fn repaintTopChrome(self: *Host) void {
        self.queueChromeRepaint(.{ .top = true });
    }

    pub fn repaintContentChrome(self: *Host) void {
        self.queueChromeRepaint(.{ .content = true });
    }

    pub fn invalidateOverlayText(self: *Host) void {
        self.chrome_text_dirty.overlay = true;
        self.repaintTopChrome();
    }

    fn invalidateChromeText(self: *Host) void {
        self.chrome_text_dirty.markAll();
        self.invalidateChrome();
    }

    pub fn invalidateTopChromeText(self: *Host) void {
        self.chrome_text_dirty.markTop();
        self.repaintTopChrome();
    }

    pub fn invalidateChrome(self: *Host) void {
        self.repaintChrome();
    }

    pub fn freeCachedChromeStrings(self: *Host) void {
        const alloc = self.app.core_app.alloc;
        self.chrome_text_dirty.markAll();
        if (self.cached_inspector_title_w) |w| alloc.free(w);
        if (self.cached_inspector_hint_w) |w| alloc.free(w);
        if (self.cached_overlay_paint_badge_w) |w| alloc.free(w);
        if (self.cached_overlay_paint_label_w) |w| alloc.free(w);
        if (self.cached_overlay_paint_feedback_w) |w| alloc.free(w);
        self.cached_inspector_title_w = null;
        self.cached_inspector_hint_w = null;
        self.cached_overlay_paint_badge_w = null;
        self.cached_overlay_paint_label_w = null;
        self.cached_overlay_paint_feedback_w = null;
    }

    test "EXT-03 overlay cache OOM remains retryable and chrome teardown frees once" {
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
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        core_app.alloc = failing.allocator();
        defer core_app.alloc = std.testing.allocator;
        defer host.freeCachedChromeStrings();
        inline for (.{
            "cached_overlay_paint_label_w",
            "cached_overlay_paint_feedback_w",
            "cached_overlay_paint_badge_w",
        }) |field| {
            const slot = &@field(host, field);
            try paint_text.replaceCachedUtf16(core_app.alloc, slot, "previous");
            const old = slot.*.?.ptr;
            failing.fail_index = failing.alloc_index;
            try std.testing.expectError(error.OutOfMemory, paint_text.replaceCachedUtf16(core_app.alloc, slot, "replacement"));
            try std.testing.expectEqual(old, slot.*.?.ptr);
            try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("previous"), slot.*.?);
            failing.fail_index = std.math.maxInt(usize);
            try paint_text.replaceCachedUtf16(core_app.alloc, slot, "replacement");
        }
        host.freeCachedChromeStrings();
        try std.testing.expect(host.cached_overlay_paint_label_w == null);
        try std.testing.expect(host.cached_overlay_paint_feedback_w == null);
        try std.testing.expect(host.cached_overlay_paint_badge_w == null);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }

    /// Paint the 3 caption buttons (min / max-or-restore / close) at
    /// the top-right of the tab row. Called from `paintChrome` only
    /// when this host is actively using the integrated titlebar.
    pub fn drawTitlebarGlyph(
        self: *Host,
        hdc: HDC,
        rect: RECT,
        kind: TitlebarGlyphKind,
        color: u32,
        caption_button: bool,
    ) void {
        const hdc_nn: *anyopaque = hdc orelse return;
        const font = if (caption_button)
            self.titlebar_caption_icon_font
        else
            self.titlebar_action_icon_font;
        const glyph_size = self.scaled(if (caption_button) 10 else 12);
        var glyph_rect = centeredRect(rect, glyph_size, glyph_size);

        if (font) |font_handle| {
            if (sys.SelectObject(hdc, font_handle)) |old_font| {
                defer _ = sys.SelectObject(hdc, old_font);
                _ = sys.SetBkMode(hdc, c.TRANSPARENT);
                _ = sys.SetTextColor(hdc, color);
                if (sys.DrawTextW(
                    hdc,
                    titlebarGlyphText(kind),
                    1,
                    &glyph_rect,
                    c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX,
                ) != 0) {
                    return;
                }
            }
        }

        win32_icons.drawIcon(
            titlebarFallbackIcon(kind),
            hdc_nn,
            .{
                .left = glyph_rect.left,
                .top = glyph_rect.top,
                .right = glyph_rect.right,
                .bottom = glyph_rect.bottom,
            },
            color,
            true,
        );
    }

    pub fn paintCaptionButton(
        self: *Host,
        hdc: HDC,
        rect: RECT,
        role: TitlebarButtonRole,
        glyph: TitlebarGlyphKind,
        now_ms: u64,
        high_contrast: bool,
        theme: *const win32_theme.ThemeColors,
    ) void {
        const caption = switch (role) {
            .minimize => CaptionButton.minimize,
            .maximize => CaptionButton.maximize,
            .close => CaptionButton.close,
            else => CaptionButton.none,
        };
        const visual = titlebarButtonVisual(
            theme,
            role,
            theme.chrome_bg,
            self.titlebarHoverAlpha(role, self.caption_hover == caption, now_ms),
            self.caption_pressed == caption,
            high_contrast,
            self.window_active,
        );
        if (visual.bg) |bg| fillSolidRect(hdc, rect, bg);
        self.drawTitlebarGlyph(hdc, rect, glyph, visual.glyph, true);
    }

    pub fn paintCaptionButtons(
        self: *Host,
        hdc: HDC,
        client_rect: RECT,
        theme: *const win32_theme.ThemeColors,
    ) void {
        const rects = self.captionButtonRects(client_rect) orelse return;
        const maximized = if (self.hwnd) |h| sys.IsZoomed(h) != 0 else false;
        const is_hc = isHighContrastActive();
        const now = sys.GetTickCount64();
        self.paintCaptionButton(hdc, rects.minimize, .minimize, .minimize, now, is_hc, theme);
        self.paintCaptionButton(
            hdc,
            rects.maximize,
            .maximize,
            if (maximized) .restore else .maximize,
            now,
            is_hc,
            theme,
        );
        self.paintCaptionButton(hdc, rects.close, .close, .close, now, is_hc, theme);
    }

    pub fn paintChromeTabBar(
        self: *Host,
        hdc: HDC,
        client_rect: RECT,
        tab_h: i32,
        band_bottom: i32,
        paint_top: bool,
        theme: *const ThemeColors,
    ) void {
        // The client-drawn band is what the user actually sees while the
        // integrated titlebar is active, so `window-titlebar-background` /
        // `-foreground` have to reach it here rather than only the DWM
        // caption. Unconfigured, this is byte-identical to `theme`.
        const titlebar_theme_value = clientTitlebarTheme(
            theme,
            self.app.shownConfig(),
            self.usingIntegratedTitlebar(),
            isHighContrastActive(),
        );
        const titlebar_theme = &titlebar_theme_value;

        // Tab bar (only when visible)
        if (paint_top and tab_h > 0) {
            // Fill the whole chrome band, not just the tab row. The tab
            // metric and the caption metric are scaled independently and can
            // land a pixel apart at DPIs that are not a multiple of 24 (110
            // dpi: 45 px vs 46 px), and everything below stacks from the
            // greater of the two. Filling only `tab_h` would leave that pixel
            // row stale between the tab strip and the terminal.
            const tab_rect = RECT{
                .left = 0,
                .top = 0,
                .right = client_rect.right,
                .bottom = @max(tab_h, band_bottom),
            };
            fillSolidRect(hdc, tab_rect, titlebar_theme.chrome_bg);

            // Focused-tab accent underline. Tabs keep their legacy bottom
            // at scaled(3) + tab_h - scaled(6), including any fractional-DPI
            // remainder before this lane. Drawn on the parent HWND so the single
            // rect can slide across child button boundaries; children
            // paint themselves above this region via WM_DRAWITEM and do
            // not occlude it. The `scaled(3)` inset on each horizontal edge
            // is noctty's own choice: Windows Terminal draws no accent
            // underline or tab indicator (wt-chrome-reference.md §1).
            {
                const now_ms = sys.GetTickCount64();
                const cur = self.tab_underline.currentRect(now_ms);
                const underline_left = @as(i32, @intFromFloat(@round(cur.left))) + self.scaled(3);
                const underline_right = @as(i32, @intFromFloat(@round(cur.left + cur.width))) - self.scaled(3);
                if (underline_right > underline_left and cur.width > 0.5) {
                    fillSolidRect(hdc, .{
                        .left = underline_left,
                        .top = tab_h - self.scaled(3),
                        .right = underline_right,
                        .bottom = tab_h - self.scaled(1),
                    }, tabAccent(titlebar_theme));
                }
            }

            // A separate tab row (Win10, or decorations without the
            // integrated titlebar) sits under the system caption and gets
            // a 2 px accent strip so the strip reads as ours. In the
            // integrated titlebar the same strip landed directly under
            // DWM's own 1 px accent border and read as a thick blue rim
            // around the window, so there the band starts clean.
            if (!self.usingIntegratedTitlebar()) {
                // A flush undecorated row has no continuous lane above its tabs.
                if (!self.tabsFlushWithTop()) {
                    fillSolidRect(
                        hdc,
                        .{
                            .left = 0,
                            .top = 0,
                            .right = client_rect.right,
                            .bottom = @max(1, self.scaled(2)),
                        },
                        themeSurface(titlebar_theme, .tab_accent),
                    );
                }
                const cluster_left = @max(self.scaled(8), client_rect.right - self.rightButtonsWidth() - self.scaled(4));
                const cluster_rect = RECT{
                    .left = cluster_left,
                    .top = self.scaled(4),
                    .right = client_rect.right - self.scaled(6),
                    .bottom = tab_h - self.scaled(4),
                };
                if (cluster_rect.right > cluster_rect.left and cluster_rect.bottom > cluster_rect.top) {
                    drawRoundedRect(
                        hdc,
                        cluster_rect,
                        themeSurface(titlebar_theme, .caption_cluster_bg),
                        themeSurface(titlebar_theme, .caption_cluster_border),
                        self.scaled(6),
                    );
                    if (cluster_left > self.scaled(14)) {
                        fillSolidRect(hdc, .{
                            .left = cluster_left - 1,
                            .top = self.scaled(8),
                            .right = cluster_left,
                            .bottom = tab_h - self.scaled(8),
                        }, theme.chrome_border);
                    }
                }
            }
            // Caption buttons (integrated titlebar only). Painted on
            // the parent HWND at the rightmost edge of the tab row;
            // hit-tested via `win32_nc_layout.hitTest` and dispatched
            // from our NC mouse handlers so Snap Layout hover remains
            // intact while the visuals stay app-owned.
            if (self.usingIntegratedTitlebar()) {
                self.paintCaptionButtons(hdc, client_rect, titlebar_theme);
            }

            // The separator belongs on the band boundary the terminal
            // actually starts at, so it tracks `contentBands` rather than the
            // tab metric alone.
            const separator_bottom = @max(tab_h, band_bottom);
            fillSolidRect(
                hdc,
                .{
                    .left = 0,
                    .top = separator_bottom - 1,
                    .right = client_rect.right,
                    .bottom = separator_bottom,
                },
                titlebar_theme.chrome_border,
            );
        } // end tab bar painting
    }

    pub fn paintChromeOverlay(
        self: *Host,
        hdc: HDC,
        alloc: Allocator,
        client_rect: RECT,
        tab_h: i32,
        bands: win32_nc_layout.ContentBands,
        paint_top: bool,
        theme: *const ThemeColors,
    ) bool {
        if (paint_top and self.overlay_mode != .none) {
            const overlay_rect = RECT{
                .left = 0,
                .top = bands.overlay_top,
                .right = client_rect.right,
                .bottom = bands.inspector_top,
            };
            fillSolidRect(hdc, overlay_rect, theme.overlay_bg);
            const overlay_panel = RECT{
                .left = self.scaled(8),
                .top = overlay_rect.top + self.scaled(4),
                .right = client_rect.right - self.scaled(8),
                .bottom = overlay_rect.bottom - self.scaled(6),
            };
            if (overlay_panel.right > overlay_panel.left and overlay_panel.bottom > overlay_panel.top) {
                drawRoundedRect(
                    hdc,
                    overlay_panel,
                    themeSurface(theme, .overlay_panel_bg),
                    themeSurface(theme, .overlay_panel_border),
                    self.scaled(7),
                );
                fillSolidRect(hdc, .{
                    .left = overlay_panel.left + self.scaled(6),
                    .top = overlay_panel.top + self.scaled(6),
                    .right = overlay_panel.left + self.scaled(9),
                    .bottom = overlay_panel.bottom - self.scaled(6),
                }, overlayAccentColor(self.overlay_mode, theme.is_dark));
            }
            fillSolidRect(
                hdc,
                .{
                    .left = 0,
                    .top = overlay_rect.bottom - 1,
                    .right = client_rect.right,
                    .bottom = overlay_rect.bottom,
                },
                theme.chrome_border,
            );

            const surface = self.activeSurface();
            const overlay_paint_dirty = overlayPaintCacheDirty(
                self.chrome_text_dirty.overlay,
                self.overlay_mode,
                self.cached_overlay_paint_label_w,
                self.cached_overlay_paint_feedback_w,
                self.cached_overlay_paint_badge_w,
            );
            if (overlay_paint_dirty) {
                const overlay_text = std.mem.trim(u8, overlayEditText(self) catch "", " \t\r\n");
                const overlay_status = if (surface) |value| self.app.hostTabStatus(value) else HostTabStatus{};
                const pane_count = if (self.activeTab()) |tab| tab.leafCount() else 1;
                const overlay_label = if (self.overlay_mode == .profile)
                    buildProfileOverlayLabel(
                        alloc,
                        self.shownProfiles() orelse &.{},
                        overlay_text,
                        self.selectedProfileIndex() orelse 0,
                    ) catch return false
                else
                    buildOverlayPaintLabelText(
                        alloc,
                        self.overlay_mode,
                        overlay_text,
                        if (surface) |value| value.search_total else null,
                        if (surface) |value| value.search_selected else null,
                        overlay_status,
                        self.palettePresentation(),
                        self.confirmText(),
                    ) catch return false;
                defer alloc.free(overlay_label);
                paint_text.replaceCachedUtf16(alloc, &self.cached_overlay_paint_label_w, overlay_label) catch return false;

                const overlay_feedback = if (self.overlay_mode == .profile)
                    if (self.banner_text) |value|
                        switch (self.banner_kind) {
                            .err => std.fmt.allocPrint(alloc, "Error: {s}", .{value}) catch return false,
                            .info => std.fmt.allocPrint(alloc, "Info: {s}", .{value}) catch return false,
                            .none => alloc.dupe(u8, value) catch return false,
                        }
                    else
                        buildProfileHintText(
                            alloc,
                            self.shownProfiles(),
                            overlay_text,
                            self.selectedProfileIndex() orelse 0,
                            self.app.launcher_profile_target,
                            self.app.launcher_quick_slot_keys,
                        ) catch return false
                else feedback: {
                    var mru_buf: [5][]const u8 = undefined;
                    const mru = self.app.paletteMruSlice(&mru_buf);
                    break :feedback buildOverlayFeedbackText(
                        alloc,
                        self.banner_kind,
                        self.banner_text,
                        self.overlay_mode,
                        overlay_text,
                        if (surface) |value| value.search_needle else null,
                        if (surface) |value| value.search_total else null,
                        if (surface) |value| value.search_selected else null,
                        overlay_status,
                        pane_count,
                        self.paletteSnapshot(),
                        mru,
                        self.palettePresentation(),
                        self.confirmText(),
                    ) catch return false;
                };
                defer alloc.free(overlay_feedback);
                paint_text.replaceCachedUtf16(alloc, &self.cached_overlay_paint_feedback_w, overlay_feedback) catch return false;

                if (self.overlay_mode == .profile) {
                    if (self.selectedProfile()) |profile| {
                        const badge = buildProfileChromeBadgeText(alloc, profile.kind) catch return false;
                        defer alloc.free(badge);
                        paint_text.replaceCachedUtf16(alloc, &self.cached_overlay_paint_badge_w, badge) catch return false;
                    } else {
                        if (self.cached_overlay_paint_badge_w) |old| alloc.free(old);
                        self.cached_overlay_paint_badge_w = null;
                    }
                } else {
                    if (self.cached_overlay_paint_badge_w) |old| alloc.free(old);
                    self.cached_overlay_paint_badge_w = null;
                }
                self.chrome_text_dirty.overlay = false;
            }
            _ = sys.SetBkMode(hdc, c.TRANSPARENT);
            const overlay_padding = self.scaled(host_overlay_padding);
            const overlay_accept_button_w = self.scaled(host_overlay_accept_width);
            const overlay_cancel_button_w = self.scaled(host_overlay_cancel_width);
            const overlay_action_layout = overlayActionLayoutForWidth(
                self.overlay_mode,
                client_rect.right,
                overlay_padding,
                overlay_cancel_button_w,
                overlay_accept_button_w,
                self.current_dpi,
            );
            const overlay_label_reservation = overlayLabelReservation(
                client_rect.right,
                overlay_padding,
                self.scaled(host_overlay_label_width),
                overlay_action_layout.cancel_width,
                overlay_action_layout.accept_reservation_width,
                self.current_dpi,
            );
            var overlay_label_x: i32 = self.scaled(host_overlay_padding) + self.scaled(10);
            var overlay_label_color: u32 = theme.overlay_label_fg;
            if (overlay_label_reservation > 0 and self.overlay_mode == .profile) {
                if (self.selectedProfile()) |profile| {
                    const badge_w = self.cached_overlay_paint_badge_w orelse return false;
                    const badge_width = self.scaled(16) + @as(i32, @intCast(badge_w.len * @as(usize, @intCast(self.scaled(7)))));
                    const badge_rect = RECT{
                        .left = self.scaled(host_overlay_padding) + self.scaled(10),
                        .top = overlay_rect.top + self.scaled(5),
                        .right = self.scaled(host_overlay_padding) + self.scaled(10) + badge_width,
                        .bottom = overlay_rect.top + self.scaled(23),
                    };
                    const accent = profileChromeAccent(profile.kind, theme.is_dark);
                    drawRoundedRect(hdc, badge_rect, accent.idle_bg, accent.idle_border, self.scaled(3));
                    _ = sys.SetTextColor(hdc, profileKindLabelColor(profile.kind, theme.is_dark));
                    var badge_text_rect = badge_rect;
                    badge_text_rect.left += self.scaled(6);
                    badge_text_rect.right -= self.scaled(6);
                    drawTextWz(
                        hdc,
                        badge_w,
                        &badge_text_rect,
                        c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX,
                    );
                    overlay_label_x = badge_rect.right + self.scaled(10);
                    overlay_label_color = profileKindLabelColor(profile.kind, theme.is_dark);
                }
            }
            // In `.confirm` mode the title and body live in their own
            // STATIC children (`overlay_label_hwnd` / `overlay_hint_hwnd`)
            // so UI Automation can see them. The host carries
            // `WS_CLIPCHILDREN`, so those rects are already clipped out of
            // this paint -- drawing them again would be invisible work.
            // The fallback still matters, per line: if control creation
            // failed, or the band is too narrow to place that line, paint
            // remains its only renderer.
            const confirm_title_is_child = self.confirmTitleTextPlaced();
            const confirm_body_is_child = self.confirmBodyTextPlaced();
            _ = sys.SetTextColor(hdc, overlay_label_color);
            if (overlay_label_reservation > 0 and !confirm_title_is_child) {
                if (self.cached_overlay_paint_label_w) |overlay_label_w| {
                    if (self.overlay_mode == .confirm) {
                        // A confirm title is caller-supplied ("Allow
                        // clipboard paste?") and routinely wider than the
                        // fixed label reservation, so bound it at the
                        // action buttons and ellipsize instead of running
                        // underneath them. The EDIT frame is hidden in
                        // this mode, so its span is free for the title.
                        var title_rect = confirmTitlePaintRect(
                            overlay_rect.top,
                            overlay_label_x,
                            overlayEditFrameRect(
                                client_rect.right,
                                tab_h,
                                overlay_padding,
                                self.scaled(host_overlay_label_width),
                                overlay_action_layout.cancel_width,
                                overlay_action_layout.accept_reservation_width,
                                self.scaled(host_overlay_row_height),
                                self.current_dpi,
                            ).right,
                            self.current_dpi,
                        );
                        drawTextWz(hdc, overlay_label_w, &title_rect, confirm_prompt_text_format);
                    } else {
                        textOutWz(hdc, overlay_label_x, overlay_rect.top + self.scaled(7), overlay_label_w);
                    }
                }
            }

            if (overlayEditFrameVisible(self.overlay_mode)) {
                const edit_frame = overlayEditFrameRect(
                    client_rect.right,
                    tab_h,
                    overlay_padding,
                    self.scaled(host_overlay_label_width),
                    overlay_action_layout.cancel_width,
                    overlay_action_layout.accept_reservation_width,
                    self.scaled(host_overlay_row_height),
                    self.current_dpi,
                );
                const overlay_edit_focused = if (self.overlay_edit_hwnd) |edit_hwnd|
                    sys.GetFocus() == edit_hwnd
                else
                    false;
                drawRoundedRect(hdc, edit_frame, theme.edit_frame_bg, overlayEditBorderColor(self.overlay_mode, overlay_edit_focused, theme.is_dark), self.scaled(4));
            }

            _ = sys.SetTextColor(hdc, if (self.overlay_mode == .profile and self.banner_text == null)
                if (self.selectedProfile()) |profile|
                    profileKindHintColor(profile.kind, theme.is_dark)
                else
                    theme.text_secondary
            else switch (if (self.banner_text != null) self.banner_kind else .none) {
                .none => theme.text_secondary,
                .info => theme.info_fg,
                .err => theme.error_fg,
            });
            if (!confirm_body_is_child) if (self.cached_overlay_paint_feedback_w) |overlay_feedback_w| {
                // A confirm shares its rect with the child that normally
                // owns this line, so the fallback and the control put the
                // glyphs on the same pixels. Every other mode keeps the
                // untouched feedback rect.
                var feedback_rect = if (self.overlay_mode == .confirm)
                    confirmBodyPaintRect(
                        client_rect.right,
                        overlay_rect.top,
                        overlay_rect.bottom,
                        self.scaled(host_overlay_padding),
                        self.current_dpi,
                    )
                else
                    overlayFeedbackLineRect(
                        client_rect.right,
                        overlay_rect.top,
                        overlay_rect.bottom,
                        self.scaled(host_overlay_padding),
                        self.current_dpi,
                    );
                drawTextWz(hdc, overlay_feedback_w, &feedback_rect, confirm_prompt_text_format);
            };
        }

        return true;
    }

    pub fn paintChromeContentLane(
        self: *Host,
        hdc: HDC,
        content_rect: RECT,
        paint_content: bool,
        theme: *const ThemeColors,
    ) void {
        if (paint_content) {
            // Content-lane paints can arrive after search-frame or pane
            // geometry shrinks/moves. Clear the exposed parent-painted
            // lane first so stale owner-drawn frame/group chrome from the
            // previous layout does not linger until a later full repaint.
            //
            // This still respects the host clip region from BeginPaint, so
            // child GL surfaces are not brute-force repainted here.
            fillSolidRect(hdc, content_rect, theme.chrome_bg);

            if (self.activeTab()) |tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| {
                    if (!entry.view.search_bar_frame_visible) continue;
                    const frame_rect = entry.view.search_bar_frame_rect;
                    if (frame_rect.right <= frame_rect.left or frame_rect.bottom <= frame_rect.top) continue;

                    drawRoundedRect(
                        hdc,
                        frame_rect,
                        themeSurface(theme, .search_frame_bg),
                        themeSurface(theme, .search_frame_border),
                        self.scaled(8),
                    );
                    fillSolidRect(hdc, .{
                        .left = frame_rect.left + self.scaled(8),
                        .top = frame_rect.bottom,
                        .right = frame_rect.right - self.scaled(8),
                        .bottom = frame_rect.bottom + 1,
                    }, themeSurface(theme, .search_frame_underline));

                    if (searchBarGroupRect(&[_]ChildPlacement{
                        entry.view.search_bar_results_placement,
                        entry.view.search_bar_prev_placement,
                        entry.view.search_bar_next_placement,
                        entry.view.search_bar_regex_placement,
                        entry.view.search_bar_case_placement,
                        entry.view.search_bar_word_placement,
                    }, self.scaled(4), self.scaled(2))) |toolbar_rect| {
                        const toolbar = searchBarToolbarVisual(theme);
                        drawRoundedRect(
                            hdc,
                            toolbar_rect,
                            toolbar.bg,
                            toolbar.border,
                            self.scaled(7),
                        );

                        const sep_top = toolbar_rect.top + self.scaled(6);
                        const sep_bottom = toolbar_rect.bottom - self.scaled(6);
                        if (sep_bottom > sep_top) {
                            if (searchBarSeparatorX(
                                entry.view.search_bar_results_placement,
                                entry.view.search_bar_prev_placement,
                            )) |sep_x| {
                                fillSolidRect(hdc, .{
                                    .left = sep_x,
                                    .top = sep_top,
                                    .right = sep_x + 1,
                                    .bottom = sep_bottom,
                                }, toolbar.separator);
                            }
                            if (searchBarSeparatorX(
                                entry.view.search_bar_prev_placement,
                                entry.view.search_bar_next_placement,
                            )) |sep_x| {
                                fillSolidRect(hdc, .{
                                    .left = sep_x,
                                    .top = sep_top,
                                    .right = sep_x + 1,
                                    .bottom = sep_bottom,
                                }, toolbar.separator);
                            }
                            if (searchBarSeparatorX(
                                entry.view.search_bar_next_placement,
                                entry.view.search_bar_regex_placement,
                            )) |sep_x| {
                                fillSolidRect(hdc, .{
                                    .left = sep_x,
                                    .top = sep_top,
                                    .right = sep_x + 1,
                                    .bottom = sep_bottom,
                                }, toolbar.separator);
                            }
                        }
                    }
                    if (entry.view.search_bar_edit_placement.rect_known) {
                        const edit_rect = entry.view.search_bar_edit_placement.rect;
                        const edit_focused = if (entry.view.search_bar_edit_hwnd) |edit_hwnd|
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
                            hdc,
                            edit_frame_rect,
                            theme.edit_frame_bg,
                            theme.edit_frame_bg,
                            self.scaled(6),
                        );
                        if (edit_focused) {
                            fillSolidRect(hdc, .{
                                .left = edit_frame_rect.left + self.scaled(8),
                                .top = edit_frame_rect.bottom - self.scaled(2),
                                .right = edit_frame_rect.right - self.scaled(8),
                                .bottom = edit_frame_rect.bottom,
                            }, overlayAccentColor(.search, theme.is_dark));
                        }
                    }
                }
            }
        }
    }

    pub fn paintChromeInspectorPanel(
        self: *Host,
        hdc: HDC,
        alloc: Allocator,
        client_rect: RECT,
        bands: win32_nc_layout.ContentBands,
        inspector_panel_visible: bool,
        paint_top: bool,
        theme: *const ThemeColors,
    ) void {
        if (paint_top and inspector_panel_visible) {
            const panel_rect = RECT{
                .left = 0,
                .top = bands.inspector_top,
                .right = client_rect.right,
                .bottom = bands.content_top,
            };
            fillSolidRect(hdc, panel_rect, theme.inspector_bg);
            fillSolidRect(
                hdc,
                .{
                    .left = 0,
                    .top = panel_rect.bottom - 1,
                    .right = client_rect.right,
                    .bottom = panel_rect.bottom,
                },
                theme.chrome_border,
            );

            if (self.activeSurface()) |surface| {
                if (self.chrome_text_dirty.inspector) {
                    const host_status = self.app.hostTabStatus(surface);
                    const pane_count = if (self.activeTab()) |tab| tab.leafCount() else 1;
                    const zoomed = if (self.activeTab()) |tab| tab.tree.zoomed != null else false;

                    if (self.cached_inspector_title_w) |old| alloc.free(old);
                    self.cached_inspector_title_w = blk: {
                        const utf8 = buildInspectorPanelTitleText(alloc, host_status, pane_count, zoomed) catch break :blk null;
                        defer alloc.free(utf8);
                        break :blk std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8) catch null;
                    };

                    if (self.cached_inspector_hint_w) |old| alloc.free(old);
                    self.cached_inspector_hint_w = blk: {
                        const utf8 = buildInspectorPanelHintText(alloc, pane_count, zoomed) catch break :blk null;
                        defer alloc.free(utf8);
                        break :blk std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8) catch null;
                    };
                    self.chrome_text_dirty.inspector = false;
                }

                _ = sys.SetBkMode(hdc, c.TRANSPARENT);
                if (self.cached_inspector_title_w) |title_w| {
                    _ = sys.SetTextColor(hdc, theme.overlay_label_fg);
                    textOutWz(hdc, self.scaled(16), panel_rect.top + self.scaled(6), title_w);
                }
                if (self.cached_inspector_hint_w) |hint_w| {
                    _ = sys.SetTextColor(hdc, theme.text_secondary);
                    textOutWz(hdc, self.scaled(16), panel_rect.top + self.scaled(22), hint_w);
                }
            }
        }
    }

    pub fn paintChromePaneDividers(
        self: *Host,
        hwnd: HWND,
        hdc: HDC,
        content_rect: RECT,
        paint_content: bool,
        theme: *const ThemeColors,
    ) void {
        // Paint pane divider gaps between split panes
        if (paint_content) {
            if (self.activeTab()) |active_tab| {
                if (active_tab.leafCount() > 1) {
                    const c_rect = content_rect;
                    const c_width = @max(1, c_rect.right - c_rect.left);
                    const c_height = @max(1, c_rect.bottom - c_rect.top);
                    // Fill entire content area with divider color first (gap pixels)
                    fillSolidRect(hdc, c_rect, theme.pane_divider);
                    // Draw accent border around focused pane
                    const focused_surface = self.activeSurface();
                    if (focused_surface) |surface| {
                        if (surface.hwnd) |surface_hwnd| {
                            var sr: RECT = undefined;
                            if (sys.GetWindowRect(surface_hwnd, &sr) != 0) {
                                var tl = POINT{ .x = sr.left, .y = sr.top };
                                var br = POINT{ .x = sr.right, .y = sr.bottom };
                                _ = sys.ScreenToClient(hwnd, &tl);
                                _ = sys.ScreenToClient(hwnd, &br);
                                // Only draw focus border if pane is within content area
                                if (tl.x >= c_rect.left and br.x <= c_rect.right and
                                    tl.y >= c_rect.top and br.y <= c_rect.bottom)
                                {
                                    const bw: i32 = 1; // border width for focus accent
                                    // Top
                                    if (tl.y > c_rect.top) fillSolidRect(hdc, .{ .left = tl.x - bw, .top = tl.y - bw, .right = br.x + bw, .bottom = tl.y }, theme.pane_divider_focused);
                                    // Bottom
                                    if (br.y < c_rect.bottom) fillSolidRect(hdc, .{ .left = tl.x - bw, .top = br.y, .right = br.x + bw, .bottom = br.y + bw }, theme.pane_divider_focused);
                                    // Left
                                    if (tl.x > c_rect.left) fillSolidRect(hdc, .{ .left = tl.x - bw, .top = tl.y, .right = tl.x, .bottom = br.y }, theme.pane_divider_focused);
                                    // Right
                                    if (br.x < c_rect.right) fillSolidRect(hdc, .{ .left = br.x, .top = tl.y, .right = br.x + bw, .bottom = br.y }, theme.pane_divider_focused);
                                }
                                _ = c_width;
                                _ = c_height;
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn paintChrome(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        var ps: PAINTSTRUCT = undefined;
        const hdc = sys.BeginPaint(hwnd, &ps) orelse return;
        defer _ = sys.EndPaint(hwnd, &ps);

        const alloc = self.app.core_app.alloc;
        const theme = &self.app.resolved_theme;

        const prev_font = self.selectChromeFont(hdc);
        defer restoreFont(hdc, prev_font);

        var client_rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client_rect) == 0) return;
        const tab_h = self.tabBarHeight();
        const overlay_offset: i32 = if (self.overlay_mode != .none) self.scaled(host_overlay_height) else 0;
        const inspector_panel_visible = self.inspectorPanelVisible();
        const inspector_offset: i32 = if (inspector_panel_visible) self.scaled(host_inspector_panel_height) else 0;
        const bands = self.contentBands(tab_h, overlay_offset, inspector_offset);
        const content_rect = RECT{
            .left = 0,
            .top = bands.content_top,
            .right = client_rect.right,
            .bottom = @max(bands.content_top + 1, client_rect.bottom),
        };
        const top_rect = RECT{
            .left = client_rect.left,
            .top = client_rect.top,
            .right = client_rect.right,
            .bottom = @max(client_rect.top, content_rect.top),
        };
        const paint_top = paintRectVisible(hdc, ps.rcPaint, top_rect);
        const paint_content = paintRectVisible(hdc, ps.rcPaint, content_rect);

        self.paintChromeTabBar(hdc, client_rect, tab_h, bands.overlay_top, paint_top, theme);
        if (!self.paintChromeOverlay(hdc, alloc, client_rect, tab_h, bands, paint_top, theme)) return;
        self.paintChromeContentLane(hdc, content_rect, paint_content, theme);
        self.paintChromeInspectorPanel(
            hdc,
            alloc,
            client_rect,
            bands,
            inspector_panel_visible,
            paint_top,
            theme,
        );
        self.paintChromePaneDividers(hwnd, hdc, content_rect, paint_content, theme);
        self.chrome_repaint_dirty = false;
    }
};
