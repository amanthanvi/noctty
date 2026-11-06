//! Parent chrome scene, cached paint text, and repaint scopes. Host retains coordination.
const win32 = @import("../win32.zig");
const runtime = win32.chrome_scene_runtime;
const Allocator = runtime.Allocator;
const CaptionButton = runtime.CaptionButton;
const ChildPlacement = child_window.ChildPlacement;
const ChromeRepaintMask = runtime.ChromeRepaintMask;
const HDC = runtime.HDC;
const HWND = runtime.HWND;
const Host = runtime.Host;
const PAINTSTRUCT = runtime.PAINTSTRUCT;
const POINT = runtime.POINT;
const RECT = runtime.RECT;
const ThemeColors = runtime.ThemeColors;
const TitlebarButtonRole = runtime.TitlebarButtonRole;
const TitlebarGlyphKind = runtime.TitlebarGlyphKind;
const c = runtime.c;
const centeredRect = runtime.centeredRect;
const child_window = @import("child_window.zig");
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
const overlayEditText = runtime.overlayEditText;
const overlayFeedbackLineRect = runtime.overlayFeedbackLineRect;
const overlayLabelReservation = runtime.overlayLabelReservation;
const overlay_view = @import("overlay_view.zig");
const paintRectVisible = runtime.paintRectVisible;
const paint_text = runtime.paint_text;
const profileChromeAccent = runtime.profileChromeAccent;
const profileKindHintColor = runtime.profileKindHintColor;
const profileKindLabelColor = runtime.profileKindLabelColor;
const restoreFont = runtime.restoreFont;
const searchBarGroupRect = search_controls.searchBarGroupRect;
const searchBarSeparatorX = search_controls.searchBarSeparatorX;
const searchBarToolbarVisual = search_controls.searchBarToolbarVisual;
const search_controls = @import("search_controls.zig");
const std = runtime.std;
const sys = runtime.sys;
const tab_label = @import("tab_label.zig");
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

    /// Draw one titlebar glyph centered in `rect`: the icon font's glyph when
    /// that font is loaded and `DrawTextW` succeeds, else the `win32_icons`
    /// fallback shape.
    /// `caption_button` selects the caption icon font and a 10 DIP glyph;
    /// otherwise it is the action icon font and 12 DIP (the tab row's new-tab
    /// and dropdown buttons).
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

    /// Paint the 3 caption buttons (min / max-or-restore / close) at
    /// the top-right of the tab row. Called from `paintChrome` only
    /// when this host is actively using the integrated titlebar.
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

            // The strip carries no accent color in any layout: the active
            // tab is marked by its terminal's background, joined to the
            // terminal below (painted after the separator), and by the `* `
            // in its label, as in Windows Terminal (wt-chrome-reference.md
            // §1). A separate tab row (Win10, or decorations without the
            // integrated titlebar) keeps its framed [+] [▾] cluster.
            if (!self.usingIntegratedTitlebar()) {
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
            // The active tab runs on through the lane under its button and
            // the separator into its terminal (`Host.activeTabJoin`).
            if (self.activeTabJoin()) |join| fillSolidRect(hdc, join.rect, join.color);
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

            const overlay_paint_dirty = win32_chrome_state.overlayPaintCacheDirty(
                self.chrome_text_dirty.overlay,
                self.overlay_mode,
                self.cached_overlay_paint_label_w != null,
                self.cached_overlay_paint_feedback_w != null,
                self.cached_overlay_paint_badge_w != null,
            );
            if (overlay_paint_dirty) {
                var arena = std.heap.ArenaAllocator.init(alloc);
                defer arena.deinit();
                // A query EDIT that cannot be read paints as an empty query.
                const facts = self.overlayFacts(overlayEditText(self) catch "");
                const text = overlay_view.compose(arena.allocator(), facts) catch return false;
                paint_text.replaceCachedUtf16(alloc, &self.cached_overlay_paint_label_w, text.paint_label) catch return false;
                paint_text.replaceCachedUtf16(alloc, &self.cached_overlay_paint_feedback_w, text.feedback) catch return false;
                if (text.badge) |badge| {
                    paint_text.replaceCachedUtf16(alloc, &self.cached_overlay_paint_badge_w, badge) catch return false;
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

            if (overlay_view.shape(self.overlay_mode).edit_visible) {
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
        const target_hdc = sys.BeginPaint(hwnd, &ps) orelse return;
        defer _ = sys.EndPaint(hwnd, &ps);

        const alloc = self.app.core_app.alloc;
        const theme = &self.app.resolved_theme;

        var alpha_paint = AlphaPaint.begin(self, target_hdc, ps.rcPaint);
        defer alpha_paint.end();
        const hdc = alpha_paint.hdc;

        const prev_font = self.selectChromeFont(hdc);
        defer restoreFont(hdc, prev_font);

        var client_rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client_rect) == 0) return;
        const tab_h = self.tabBarHeight();
        const inspector_panel_visible = self.inspectorPanelVisible();
        const bands = contentBandsOf(self);
        alpha_paint.see_through_top = bands.content_top;
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
        // The window's update region, which a buffer's DC does not have.
        const paint_top = paintRectVisible(target_hdc, ps.rcPaint, top_rect);
        const paint_content = paintRectVisible(target_hdc, ps.rcPaint, content_rect);

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

fn buildInspectorPanelTitleText(
    alloc: Allocator,
    host: tab_label.TabStatus,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  {d} panes  •  zoomed",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  {d} panes",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (zoomed) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  zoomed",
            .{ host.index + 1, host.total },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "Inspector  •  tab {d}/{d}",
        .{ host.index + 1, host.total },
    );
}

fn buildInspectorPanelHintText(
    alloc: Allocator,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed) {
        return try alloc.dupe(
            u8,
            "Core inspector is live for the zoomed pane. Toggle Inspect to return to terminal-only view.",
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Core inspector is live across {d} panes in this tab. Toggle Inspect to return to terminal-only view.",
            .{pane_count},
        );
    }
    return try alloc.dupe(u8, "Core inspector is live for this tab. Toggle Inspect to return to terminal-only view.");
}

test "win32 buildInspectorPanelTitleText reflects host inspector context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildInspectorPanelTitleText(std.testing.allocator, .{ .index = 1, .total = 4 }, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "Inspector") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "tab 2/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorPanelTitleText(std.testing.allocator, .{ .index = 0, .total = 2 }, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoomed") != null);
}

test "win32 buildInspectorPanelHintText reflects live inspector scope" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const single = try buildInspectorPanelHintText(std.testing.allocator, 1, false);
    defer std.testing.allocator.free(single);
    try std.testing.expect(std.mem.indexOf(u8, single, "this tab") != null);

    const multi = try buildInspectorPanelHintText(std.testing.allocator, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorPanelHintText(std.testing.allocator, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoomed pane") != null);
}

/// The bands `paintChrome` lays out: the tab strip, the overlay band, the
/// inspector panel, then the terminal lane from `content_top`.
fn contentBandsOf(host: *Host) win32_nc_layout.ContentBands {
    const overlay_offset: i32 = if (host.overlay_mode != .none) host.scaled(host_overlay_height) else 0;
    const inspector_offset: i32 = if (host.inspectorPanelVisible()) host.scaled(host_inspector_panel_height) else 0;
    return host.contentBands(host.tabBarHeight(), overlay_offset, inspector_offset);
}

/// GDI painting with the alpha DWM reads while a window's background alone
/// is translucent (`Host.chrome_alpha`: blur-behind, under which the alpha 0
/// GDI writes shows through). The painter draws into a buffer that starts as
/// what the target shows, and `end` gives every pixel its alpha before the
/// buffer lands (`fixAlpha`): the chrome's background color from client row
/// `see_through_top` down, the terminal lane, takes `Host.chrome_alpha`, and
/// everything else is opaque. For an opaque window `hdc` is the target, at no
/// cost; so it is when no buffer can be had, and the paint still shows, with
/// GDI's alpha.
pub const AlphaPaint = struct {
    hdc: HDC,
    buffer: ?*anyopaque = null,
    bg: u32 = 0,
    alpha: u8 = 255,
    /// The client row where the terminal lane starts. Chrome background
    /// below it is see-through; everything above it, like the title bar,
    /// stays solid.
    see_through_top: i32 = std.math.maxInt(i32),

    /// `saved` is the buffer DC's state before the painter selects into it:
    /// uxtheme keeps that DC for the next paint, and an object left selected
    /// there could not be deleted.
    saved: c_int = 0,

    pub fn begin(host: *const Host, target: HDC, rect: RECT) AlphaPaint {
        const alpha = host.chrome_alpha orelse return .{ .hdc = target };
        return beginBuffered(target, rect, host.app.resolved_theme.chrome_bg, alpha);
    }

    /// For a host's owner-drawn control: the terminal lane starts at the
    /// same window row in its coordinates, so a control there (the docked
    /// search bar's background) keys the chrome background as `paintChrome`
    /// does around it.
    pub fn beginItem(host: *Host, item: *const sys.DRAWITEMSTRUCT) AlphaPaint {
        var paint = begin(host, item.hDC, item.rcItem);
        if (paint.buffer == null) return paint;
        const hwnd = host.hwnd orelse return paint;
        const control = item.hwndItem;
        var lane: POINT = .{ .x = 0, .y = contentBandsOf(host).content_top };
        if (sys.ClientToScreen(hwnd, &lane) != 0 and sys.ScreenToClient(control, &lane) != 0) {
            paint.see_through_top = lane.y;
        }
        return paint;
    }

    fn beginBuffered(target: HDC, rect: RECT, bg: u32, alpha: u8) AlphaPaint {
        var buffer_hdc: HDC = null;
        const buffer = sys.BeginBufferedPaint(target, &rect, sys.BPBF_TOPDOWNDIB, null, &buffer_hdc) orelse {
            if (!buffer_failure_logged) {
                buffer_failure_logged = true;
                win32.log.warn("win32 buffered chrome paint failed; translucent chrome paints with GDI's alpha", .{});
            }
            return .{ .hdc = target };
        };
        // A pixel the painter leaves keeps what the target shows: a cached
        // buffer holds the last paint's pixels, from anywhere.
        _ = sys.BitBlt(buffer_hdc, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, target, rect.left, rect.top, sys.SRCCOPY);
        return .{ .hdc = buffer_hdc, .buffer = buffer, .bg = bg, .alpha = alpha, .saved = sys.SaveDC(buffer_hdc) };
    }

    var buffer_failure_logged = false;

    pub fn end(self: *AlphaPaint) void {
        const buffer = self.buffer orelse return;
        self.buffer = null;
        if (self.saved != 0) _ = sys.RestoreDC(self.hdc, self.saved);
        var bits: ?[*]u32 = null;
        var row: i32 = 0;
        var rect: RECT = undefined;
        if (sys.GetBufferedPaintBits(buffer, &bits, &row) >= 0 and
            sys.GetBufferedPaintTargetRect(buffer, &rect) >= 0)
        {
            if (bits) |pixels| fixAlpha(
                pixels,
                @intCast(@max(0, row)),
                .{ .width = @intCast(@max(0, rect.right - rect.left)), .height = @intCast(@max(0, rect.bottom - rect.top)), .top = rect.top },
                self.bg,
                self.alpha,
                self.see_through_top,
            );
        }
        _ = sys.EndBufferedPaint(buffer, 1);
    }
};

/// `AlphaPaint.end`'s pass over the buffer's 0xAARRGGBB pixels, rows
/// `stride` pixels apart, whose first row is client row `area.top`. `bg` is a
/// COLORREF (0x00BBGGRR). A see-through pixel holds the background
/// premultiplied by `alpha`, which DWM composes over what is behind; one
/// that already does (the buffer started from the target) keeps it.
fn fixAlpha(
    pixels: [*]u32,
    stride: usize,
    area: struct { width: usize, height: usize, top: i32 },
    bg: u32,
    alpha: u8,
    see_through_top: i32,
) void {
    const bg_rgb: u32 = ((bg & 0xff) << 16) | (bg & 0xff00) | ((bg >> 16) & 0xff);
    const a: u32 = alpha;
    const see_through: u32 = (a << 24) |
        ((((bg_rgb >> 16) & 0xff) * a / 255) << 16) |
        ((((bg_rgb >> 8) & 0xff) * a / 255) << 8) |
        ((bg_rgb & 0xff) * a / 255);
    for (0..area.height) |y| {
        const line = pixels[y * stride ..][0..area.width];
        if (area.top + @as(i32, @intCast(y)) < see_through_top) {
            for (line) |*px| px.* |= 0xff000000;
            continue;
        }
        for (line) |*px| {
            px.* = if (px.* & 0x00ffffff == bg_rgb or px.* == see_through) see_through else px.* | 0xff000000;
        }
    }
}

test "win32 AlphaPaint leaves the chrome opaque and the terminal lane's background at the window's alpha" {
    const Canvas = Host.BannerTestCanvas;
    const bg: u32 = 0x00302010; // COLORREF: red 0x10, green 0x20, blue 0x30
    const ink: u32 = 0x000000C0; // red
    const width = 40;
    var canvas = try Canvas.init(width, 40);
    defer canvas.deinit();
    if (sys.BufferedPaintInit() < 0) return error.SkipZigTest;
    defer _ = sys.BufferedPaintUnInit();

    const full: RECT = .{ .left = 0, .top = 0, .right = width, .bottom = 40 };
    var paint = AlphaPaint.beginBuffered(canvas.dc, full, bg, 128);
    try std.testing.expect(paint.buffer != null);
    // The terminal lane starts at row 20, as `paintChrome` sets it.
    paint.see_through_top = 20;
    fillSolidRect(paint.hdc, full, bg);
    fillSolidRect(paint.hdc, .{ .left = 4, .top = 4, .right = 12, .bottom = 12 }, ink);
    fillSolidRect(paint.hdc, .{ .left = 4, .top = 24, .right = 12, .bottom = 32 }, ink);
    paint.end();
    _ = Canvas.raw.GdiFlush();

    const at = struct {
        fn px(c_: Canvas, x: usize, y: usize) u32 {
            return c_.bits[y * width + x];
        }
    }.px;
    // Above the lane: the chrome's background and what is drawn on it,
    // opaque.
    try std.testing.expectEqual(@as(u32, 0xff102030), at(canvas, 30, 2));
    try std.testing.expectEqual(@as(u32, 0xffc00000), at(canvas, 6, 6));
    // In the lane: the background at alpha 128, premultiplied, and what is
    // drawn on it opaque.
    try std.testing.expectEqual(@as(u32, 0x80081018), at(canvas, 30, 30));
    try std.testing.expectEqual(@as(u32, 0xffc00000), at(canvas, 6, 26));

    // A second paint that touches only the top keeps the lane as it was:
    // the buffer starts from the target, whose background is already
    // premultiplied.
    var again = AlphaPaint.beginBuffered(canvas.dc, full, bg, 128);
    again.see_through_top = 20;
    fillSolidRect(again.hdc, .{ .left = 0, .top = 0, .right = width, .bottom = 20 }, bg);
    again.end();
    _ = Canvas.raw.GdiFlush();
    try std.testing.expectEqual(@as(u32, 0x80081018), at(canvas, 30, 30));
    try std.testing.expectEqual(@as(u32, 0xffc00000), at(canvas, 6, 26));
    try std.testing.expectEqual(@as(u32, 0xff102030), at(canvas, 6, 6));
}

test "win32 AlphaPaint paints straight to the target for an opaque window" {
    // `begin` reads nothing else of an opaque window.
    var app: win32.App = undefined;
    const host: Host = .{ .app = &app, .id = 1 };
    const target: HDC = @ptrFromInt(0x1000);
    var paint = AlphaPaint.begin(&host, target, .{ .left = 0, .top = 0, .right = 1, .bottom = 1 });
    try std.testing.expectEqual(target, paint.hdc);
    try std.testing.expectEqual(@as(?*anyopaque, null), paint.buffer);
    paint.end();
}
