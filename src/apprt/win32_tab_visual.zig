//! Per-tab visual polish: the close-button fade.
//!
//! Each tab's close button is invisible at rest (alpha 0). On hover-enter
//! the alpha fades to 1 over `close_fade_ms`; on hover-leave it fades back
//! to 0 over the same duration. The hit-zone width scales in lockstep so
//! that clicks at partial alpha land correctly.
//!
//! The state machine is allocation-free, Win32-free, and testable in
//! isolation. The paint layer calls `alphaAt` each frame and pre-composites
//! the close glyph's colour with the result. The fade uses a cubic
//! ease-in-out curve (slow start, fast middle, slow end).

const std = @import("std");
const geometry = @import("win32_geometry.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Duration for close-button fade-in or fade-out, in milliseconds.
pub const close_fade_ms: u64 = 120;

// ---------------------------------------------------------------------------
// Easing
// ---------------------------------------------------------------------------

/// Standard cubic ease-in-out: 0 at t=0, 1 at t=1, smooth at both ends.
/// t is clamped to [0, 1].
///
/// Formula: t < 0.5 => 4*t^3  else  1 - (-2*t + 2)^3 / 2
pub fn easeInOutCubic(t: f32) f32 {
    const s = std.math.clamp(t, 0.0, 1.0);
    if (s < 0.5) {
        return 4.0 * s * s * s;
    } else {
        const p = -2.0 * s + 2.0;
        return 1.0 - (p * p * p) / 2.0;
    }
}

// ---------------------------------------------------------------------------
// CloseState
// ---------------------------------------------------------------------------

/// Per-tab close-button hover fade state.
pub const CloseState = struct {
    /// Current animated alpha (updated lazily via `alphaAt`).
    alpha: f32 = 0.0,
    /// Animation target: 0 = hidden, 1 = visible.
    target: f32 = 0.0,
    /// Timestamp when the current fade began.
    fade_started_ms: u64 = 0,
    /// Alpha at the moment the current fade was initiated. This lets a
    /// mid-fade reversal start from the current visual alpha rather than
    /// snapping to 0 or 1.
    start_alpha: f32 = 0.0,

    /// Trigger a fade-in (hovered=true) or fade-out (hovered=false).
    /// Captures the current visual alpha so mid-fade reversals are smooth.
    pub fn setHovered(self: *CloseState, hovered: bool, now_ms: u64) void {
        const new_target: f32 = if (hovered) 1.0 else 0.0;
        if (new_target == self.target) return;
        self.start_alpha = self.alphaAt(now_ms);
        self.target = new_target;
        self.fade_started_ms = now_ms;
    }

    /// Apply the host's effective motion policy to this fade.
    pub fn setHoveredWithMotion(self: *CloseState, hovered: bool, now_ms: u64, animate: bool) void {
        self.setHovered(hovered, now_ms);
        if (!animate) {
            self.alpha = self.target;
            self.start_alpha = self.target;
            self.fade_started_ms = 0;
        }
    }

    /// Compute the current alpha based on fade progress. Clamps to [0, 1].
    pub fn alphaAt(self: CloseState, now_ms: u64) f32 {
        if (self.fade_started_ms == 0) return self.alpha;
        if (now_ms <= self.fade_started_ms) return self.start_alpha;
        const elapsed = now_ms - self.fade_started_ms;
        if (elapsed >= close_fade_ms) return self.target;
        const t: f32 = @as(f32, @floatFromInt(elapsed)) /
            @as(f32, @floatFromInt(close_fade_ms));
        const eased = easeInOutCubic(t);
        return self.start_alpha + (self.target - self.start_alpha) * eased;
    }

    /// True while the animation is mid-fade; the caller should schedule
    /// another repaint tick.
    pub fn animating(self: CloseState, now_ms: u64) bool {
        if (self.fade_started_ms == 0) return false;
        if (now_ms <= self.fade_started_ms) return true;
        return (now_ms - self.fade_started_ms) < close_fade_ms;
    }
};

// ---------------------------------------------------------------------------
// Hit-zone helper
// ---------------------------------------------------------------------------

pub const Rect = geometry.Rect;

/// Given a tab button's full rect and the current close-button alpha,
/// return the close-button hit rect. When alpha == 0 the hit zone has
/// zero width (clicks fall through to the tab body). When alpha == 1
/// the hit zone is a right-aligned square of side `close_zone_width_px`.
/// Intermediate alphas scale the width linearly.
pub fn closeHitRect(tab_rect: Rect, alpha: f32, close_zone_width_px: i32) Rect {
    const a = std.math.clamp(alpha, 0.0, 1.0);
    const w: i32 = @intFromFloat(@as(f32, @floatFromInt(close_zone_width_px)) * a);
    return .{
        .left = tab_rect.right - w,
        .top = tab_rect.top,
        .right = tab_rect.right,
        .bottom = tab_rect.bottom,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

test "easeInOutCubic: f(0) = 0" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), easeInOutCubic(0.0), 1e-6);
}

test "easeInOutCubic: f(1) = 1" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), easeInOutCubic(1.0), 1e-6);
}

test "easeInOutCubic: f(0.5) = 0.5" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), easeInOutCubic(0.5), 1e-6);
}

test "easeInOutCubic: f(0.25) < 0.25 — slow start" {
    try std.testing.expect(easeInOutCubic(0.25) < 0.25);
}

test "easeInOutCubic: f(0.75) > 0.75 — slow end" {
    try std.testing.expect(easeInOutCubic(0.75) > 0.75);
}

// ---------------------------------------------------------------------------
// CloseState tests
// ---------------------------------------------------------------------------

test "CHROME57 reduced-motion close reveal snaps both directions and mid-fade" {
    var state: CloseState = .{};
    state.setHoveredWithMotion(true, 1000, false);
    try std.testing.expectEqual(@as(f32, 1), state.alphaAt(1000));
    try std.testing.expect(!state.animating(1000));
    state.setHoveredWithMotion(false, 1001, false);
    try std.testing.expectEqual(@as(f32, 0), state.alphaAt(1001));
    state.setHoveredWithMotion(true, 1100, true);
    state.setHoveredWithMotion(true, 1140, false);
    try std.testing.expectEqual(@as(f32, 1), state.alphaAt(1140));
    try std.testing.expect(!state.animating(1140));
}

test "CloseState: default is hidden" {
    const cs: CloseState = .{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cs.alpha, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cs.target, 1e-6);
}

test "CloseState: setHovered(true) triggers fade-in" {
    var cs: CloseState = .{};
    cs.setHovered(true, 1000);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cs.target, 1e-6);
    try std.testing.expect(cs.animating(1000));
}

test "CloseState: alphaAt at start of fade" {
    var cs: CloseState = .{};
    cs.setHovered(true, 1000);
    // At the exact start time, alpha should be the start value (0).
    const a = cs.alphaAt(1000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), a, 0.01);
}

test "CloseState: alphaAt after fade_ms" {
    var cs: CloseState = .{};
    cs.setHovered(true, 1000);
    const a = cs.alphaAt(1000 + close_fade_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), a, 1e-6);
}

test "CloseState: alphaAt at mid-fade" {
    var cs: CloseState = .{};
    cs.setHovered(true, 1000);
    const a = cs.alphaAt(1000 + close_fade_ms / 2);
    // easeInOutCubic(0.5) == 0.5, so mid-fade from 0->1 gives ~0.5.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), a, 0.05);
}

test "CloseState: setHovered(false) mid-fade reverses" {
    var cs: CloseState = .{};
    cs.setHovered(true, 1000);
    // At 25% into the fade-in, reverse.
    const mid_time = 1000 + close_fade_ms / 4;
    const captured_alpha = cs.alphaAt(mid_time);
    cs.setHovered(false, mid_time);
    // start_alpha should be the captured mid-fade alpha, target should be 0.
    try std.testing.expectApproxEqAbs(captured_alpha, cs.start_alpha, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), cs.target, 1e-6);
    try std.testing.expect(cs.animating(mid_time));
}

test "CloseState: animating false after completion" {
    var cs: CloseState = .{};
    cs.setHovered(true, 1000);
    try std.testing.expect(!cs.animating(1000 + close_fade_ms + 1));
}

// ---------------------------------------------------------------------------
// closeHitRect tests
// ---------------------------------------------------------------------------

test "closeHitRect: alpha=0 gives zero-width" {
    const tab: Rect = .{ .left = 10, .top = 0, .right = 110, .bottom = 30 };
    const r = closeHitRect(tab, 0.0, 20);
    try std.testing.expectEqual(r.left, r.right);
}

test "closeHitRect: alpha=1 gives full-width square" {
    const tab: Rect = .{ .left = 10, .top = 0, .right = 110, .bottom = 30 };
    const r = closeHitRect(tab, 1.0, 20);
    try std.testing.expectEqual(@as(i32, 90), r.left);
    try std.testing.expectEqual(@as(i32, 110), r.right);
    try std.testing.expectEqual(@as(i32, 0), r.top);
    try std.testing.expectEqual(@as(i32, 30), r.bottom);
}

test "closeHitRect: alpha=0.5 gives half-width" {
    const tab: Rect = .{ .left = 10, .top = 0, .right = 110, .bottom = 30 };
    const r = closeHitRect(tab, 0.5, 20);
    try std.testing.expectEqual(@as(i32, 100), r.left);
    try std.testing.expectEqual(@as(i32, 110), r.right);
}
