//! The decisions a Window's state is made of, from values. The Win32 calls
//! that carry them out are window_state.zig's, the one file that imports this
//! one (it re-exports `TopLevel`). This file imports no `sys`, so the compiler
//! keeps it free of them, and its tests need no window.
const std = @import("std");
const types = @import("../win32_types.zig");

const MONITORINFO = types.MONITORINFO;
const RECT = types.RECT;
const WINDOWPLACEMENT = types.WINDOWPLACEMENT;

/// The state of one top-level window, kept once, on its `Host`
/// (`Host.top_level`), whichever of its panes acts on it.
pub const TopLevel = struct {
    decorations_visible: bool = true,
    /// `toggle_window_decorations` chose them, so a reload leaves them.
    decorations_overridden: bool = false,
    /// `float_window`: above every window that is not topmost.
    topmost: bool = false,
    /// `background-opacity`, clamped to 0..1.
    opacity: f64 = 1.0,
    /// `toggle_background_opacity` shows the window opaque whatever
    /// `opacity` says. A reload to an opaque config clears it.
    force_opaque: bool = false,
    /// What leaving fullscreen gives back, set exactly while the window is
    /// fullscreen.
    fullscreen: ?Return = null,

    /// The window as it was when it entered fullscreen.
    pub const Return = struct {
        /// Its rect, in screen coordinates.
        rect: RECT,
        /// Its placement, captured before the style write that drops
        /// `WS_MAXIMIZE`. `rcNormalPosition` is in the workspace coordinates
        /// of `monitor`.
        placement: WINDOWPLACEMENT,
        /// The monitor it entered fullscreen on.
        monitor: ?Monitor,
    };

    pub fn isFullscreen(self: *const TopLevel) bool {
        return self.fullscreen != null;
    }

    /// The layered alpha the window shows, or null when it shows opaque and
    /// so is not layered at all (#234: layering is the only mechanism, and an
    /// opaque window must not pay for it).
    pub fn alpha(self: *const TopLevel) ?u8 {
        if (self.force_opaque or self.opacity >= 0.999) return null;
        return @intFromFloat(@round(std.math.clamp(self.opacity, 0.0, 1.0) * 255.0));
    }
};

/// A monitor as a window on it sees it. `id` is its `HMONITOR`.
pub const Monitor = struct { id: usize, info: MONITORINFO, dpi: u32 };

test "win32 a window shows its opacity as a layered alpha, and opaque unlayered" {
    var top_level: TopLevel = .{ .opacity = 0.5 };
    try std.testing.expectEqual(@as(?u8, 128), top_level.alpha());
    top_level.opacity = 0.75;
    try std.testing.expectEqual(@as(?u8, 191), top_level.alpha());
    // `toggle_background_opacity`, and an opacity that rounds to opaque.
    top_level.force_opaque = true;
    try std.testing.expectEqual(@as(?u8, null), top_level.alpha());
    top_level = .{ .opacity = 0.9995 };
    try std.testing.expectEqual(@as(?u8, null), top_level.alpha());
    try std.testing.expectEqual(@as(?u8, 0), (TopLevel{ .opacity = 0 }).alpha());
}
