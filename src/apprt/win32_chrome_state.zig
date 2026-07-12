//! Semantic Win32 chrome state and repaint policy.
//!
//! This module owns pure chrome decisions: dirty text zones, repaint masks,
//! child repaint policy, reduced-motion/DPI helpers, profile/inspector
//! visibility, overlay cache dirtiness, and shell-chrome fallback decisions.
//! Native HWND/GDI/DirectComposition painting remains in `win32.zig`.

const std = @import("std");
const win32_theme = @import("win32_theme.zig");

pub const HostOverlayMode = win32_theme.HostOverlayMode;

pub const TextDirty = packed struct(u8) {
    overlay: bool = true,
    inspector: bool = true,
    banner: bool = true,
    status: bool = true,
    _padding: u4 = 0,

    pub fn markTop(self: *TextDirty) void {
        self.overlay = true;
        self.inspector = true;
        self.banner = true;
    }

    pub fn markAll(self: *TextDirty) void {
        self.markTop();
        self.status = true;
    }
};

pub const RepaintMask = packed struct(u8) {
    top: bool = false,
    content: bool = false,
    status: bool = false,
    search_frames: bool = false,
    _padding: u4 = 0,

    pub fn markChrome(self: *RepaintMask) void {
        self.top = true;
        self.status = true;
        self.search_frames = true;
    }

    pub fn isEmpty(self: RepaintMask) bool {
        return !self.top and !self.content and !self.status and !self.search_frames;
    }
};

pub fn mergeRepaintMask(current: *RepaintMask, next: RepaintMask) RepaintMask {
    const added: RepaintMask = .{
        .top = next.top and !current.top,
        .content = next.content and !current.content,
        .status = next.status and !current.status,
        .search_frames = next.search_frames and !current.search_frames,
    };
    current.* = .{
        .top = current.top or next.top,
        .content = current.content or next.content,
        .status = current.status or next.status,
        .search_frames = current.search_frames or next.search_frames,
    };
    return added;
}

pub const LayoutChildPaintPlan = struct {
    chrome: bool,
    content: bool,
    native_content_controls: bool,
};

pub fn layoutChildPaintPlan(chrome_changed: bool, content_changed: bool) LayoutChildPaintPlan {
    return .{
        .chrome = chrome_changed,
        .content = content_changed,
        .native_content_controls = content_changed,
    };
}

pub fn focusRepaintNeeded(pane_count: usize) bool {
    return pane_count > 1;
}

pub fn profileVisible(overlay_mode: HostOverlayMode, status_bar_height: i32) bool {
    return overlay_mode == .profile or status_bar_height > 0;
}

pub fn profileNeedsFullTextInvalidation(overlay_mode: HostOverlayMode, status_bar_height: i32) bool {
    return overlay_mode != .profile and status_bar_height > 0;
}

pub fn textNeedsFullInvalidation(status_bar_height: i32) bool {
    return status_bar_height > 0;
}

pub fn inspectorVisible(overlay_mode: HostOverlayMode, status_bar_height: i32) bool {
    return overlay_mode == .none or status_bar_height > 0;
}

pub fn overlayPaintCacheDirty(
    overlay_text_dirty: bool,
    overlay_mode: HostOverlayMode,
    cached_label_present: bool,
    cached_feedback_present: bool,
    cached_badge_present: bool,
) bool {
    return overlay_text_dirty or
        !cached_label_present or
        !cached_feedback_present or
        (overlay_mode == .profile and !cached_badge_present);
}

pub fn scaled(base: i32, dpi: u32) i32 {
    if (dpi <= 96) return base;
    return @divTrunc(base * @as(i32, @intCast(dpi)), 96);
}

pub const HighContrastDpiState = struct {
    high_contrast: bool,
    client_animations_enabled: bool,
    dpi: u32,

    pub fn effectiveAnimationDuration(self: HighContrastDpiState, duration_ms: u16) u16 {
        return if (!self.client_animations_enabled or self.high_contrast) 0 else duration_ms;
    }

    pub fn scale(self: HighContrastDpiState, base: i32) i32 {
        return scaled(base, self.dpi);
    }

    pub fn nativeTitlebarOwnsHighContrast(self: HighContrastDpiState) bool {
        return self.high_contrast;
    }
};

pub const ShellChromeFallbackAction = enum {
    recover_and_retry,
    use_gdi_fallback,
    ignore,
};

pub fn shellChromeFallbackAction(err: anyerror) ShellChromeFallbackAction {
    return switch (err) {
        error.DeviceLost => .recover_and_retry,
        error.FallbackOnly, error.InvalidState => .ignore,
        else => .use_gdi_fallback,
    };
}

test "chrome text dirty splits top and status cache invalidation" {
    const testing = std.testing;

    var dirty: TextDirty = .{
        .overlay = false,
        .inspector = false,
        .banner = false,
        .status = false,
    };
    dirty.markTop();
    try testing.expect(dirty.overlay);
    try testing.expect(dirty.inspector);
    try testing.expect(dirty.banner);
    try testing.expect(!dirty.status);

    dirty = .{
        .overlay = false,
        .inspector = false,
        .banner = false,
        .status = false,
    };
    dirty.status = true;
    try testing.expect(!dirty.overlay);
    try testing.expect(!dirty.inspector);
    try testing.expect(!dirty.banner);
    try testing.expect(dirty.status);

    dirty = .{
        .overlay = false,
        .inspector = false,
        .banner = false,
        .status = false,
    };
    dirty.markAll();
    try testing.expect(dirty.overlay);
    try testing.expect(dirty.inspector);
    try testing.expect(dirty.banner);
    try testing.expect(dirty.status);
}

test "chrome repaint mask merge returns only newly requested regions" {
    const testing = std.testing;

    var current: RepaintMask = .{};
    var added = mergeRepaintMask(&current, .{ .top = true });
    try testing.expect(std.meta.eql(current, RepaintMask{ .top = true }));
    try testing.expect(std.meta.eql(added, RepaintMask{ .top = true }));

    added = mergeRepaintMask(&current, .{ .top = true });
    try testing.expect(added.isEmpty());
    try testing.expect(std.meta.eql(current, RepaintMask{ .top = true }));

    added = mergeRepaintMask(&current, .{ .status = true, .search_frames = true });
    try testing.expect(std.meta.eql(current, RepaintMask{
        .top = true,
        .status = true,
        .search_frames = true,
    }));
    try testing.expect(std.meta.eql(added, RepaintMask{
        .status = true,
        .search_frames = true,
    }));

    added = mergeRepaintMask(&current, .{ .content = true, .search_frames = true });
    try testing.expect(std.meta.eql(current, RepaintMask{
        .top = true,
        .content = true,
        .status = true,
        .search_frames = true,
    }));
    try testing.expect(std.meta.eql(added, RepaintMask{ .content = true }));
}

test "chrome layout child paint plan keeps chrome and content separate" {
    const testing = std.testing;

    try testing.expectEqualDeep(
        LayoutChildPaintPlan{ .chrome = true, .content = false, .native_content_controls = false },
        layoutChildPaintPlan(true, false),
    );
    try testing.expectEqualDeep(
        LayoutChildPaintPlan{ .chrome = false, .content = true, .native_content_controls = true },
        layoutChildPaintPlan(false, true),
    );
    try testing.expectEqualDeep(
        LayoutChildPaintPlan{ .chrome = true, .content = true, .native_content_controls = true },
        layoutChildPaintPlan(true, true),
    );
}

test "chrome profile and inspector visibility policies are status aware" {
    try std.testing.expect(profileVisible(.profile, 0));
    try std.testing.expect(profileVisible(.none, 24));
    try std.testing.expect(!profileVisible(.none, 0));
    try std.testing.expect(!profileVisible(.search, 0));

    try std.testing.expect(!profileNeedsFullTextInvalidation(.profile, 0));
    try std.testing.expect(!profileNeedsFullTextInvalidation(.profile, 24));
    try std.testing.expect(!profileNeedsFullTextInvalidation(.none, 0));
    try std.testing.expect(profileNeedsFullTextInvalidation(.none, 24));

    try std.testing.expect(inspectorVisible(.none, 0));
    try std.testing.expect(inspectorVisible(.search, 24));
    try std.testing.expect(!inspectorVisible(.search, 0));
}

test "chrome overlay cache dirtiness ignores repaint-only work" {
    try std.testing.expect(!overlayPaintCacheDirty(false, .search, true, true, false));
    try std.testing.expect(!overlayPaintCacheDirty(false, .profile, true, true, true));

    try std.testing.expect(overlayPaintCacheDirty(true, .search, true, true, false));
    try std.testing.expect(overlayPaintCacheDirty(false, .search, false, true, false));
    try std.testing.expect(overlayPaintCacheDirty(false, .profile, true, true, false));
}

test "chrome high contrast and dpi state collapse motion and scale metrics" {
    const normal: HighContrastDpiState = .{
        .high_contrast = false,
        .client_animations_enabled = true,
        .dpi = 144,
    };
    try std.testing.expectEqual(@as(u16, 120), normal.effectiveAnimationDuration(120));
    try std.testing.expectEqual(@as(i32, 30), normal.scale(20));
    try std.testing.expect(!normal.nativeTitlebarOwnsHighContrast());

    const reduced: HighContrastDpiState = .{
        .high_contrast = false,
        .client_animations_enabled = false,
        .dpi = 96,
    };
    try std.testing.expectEqual(@as(u16, 0), reduced.effectiveAnimationDuration(120));

    const high_contrast: HighContrastDpiState = .{
        .high_contrast = true,
        .client_animations_enabled = true,
        .dpi = 96,
    };
    try std.testing.expectEqual(@as(u16, 0), high_contrast.effectiveAnimationDuration(120));
    try std.testing.expect(high_contrast.nativeTitlebarOwnsHighContrast());
}

test "chrome shell fallback policy retries only device loss" {
    try std.testing.expectEqual(ShellChromeFallbackAction.recover_and_retry, shellChromeFallbackAction(error.DeviceLost));
    try std.testing.expectEqual(ShellChromeFallbackAction.ignore, shellChromeFallbackAction(error.FallbackOnly));
    try std.testing.expectEqual(ShellChromeFallbackAction.ignore, shellChromeFallbackAction(error.InvalidState));
    try std.testing.expectEqual(ShellChromeFallbackAction.use_gdi_fallback, shellChromeFallbackAction(error.DriverFailure));
}
