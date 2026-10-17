//! Per-tab visual polish: close-button fade and focused-tab underline slide.
//!
//! This module holds pure state machines and interpolation math for two
//! tab-chrome animations:
//!
//!   1. **Close-button reveal** -- each tab's close button is invisible at
//!      rest (alpha 0). On hover-enter the alpha fades to 1 over
//!      `close_fade_ms`; on hover-leave it fades back to 0 over the same
//!      duration. The hit-zone width scales in lockstep so that clicks at
//!      partial alpha land correctly.
//!
//!   2. **Focused-tab underline slide** -- a 2 px accent-colour line sits
//!      under the active tab. When focus changes, the line slides from the
//!      old tab rect to the new one over `underline_slide_ms` using a cubic
//!      ease-in-out curve, giving the eye a smooth anchor to follow.
//!
//! Both animations are allocation-free, Win32-free, and testable in
//! isolation. The paint layer calls `alphaAt` / `currentRect` each frame
//! and feeds the results into `win32_icons.drawIcon(.close, ..., alpha)`
//! or the underline `FillRect` call.
//!
//! Easing rationale: the underline uses cubic ease-in-out (slow start,
//! fast middle, slow end) because the motion spans a visible horizontal
//! distance and needs perceptual smoothness at both endpoints. The close
//! fade uses the same curve for consistency, though linear would also be
//! acceptable for opacity-only transitions.

const std = @import("std");
const geometry = @import("win32_geometry.zig");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Duration for close-button fade-in or fade-out, in milliseconds.
pub const close_fade_ms: u64 = 120;

/// Duration for the focused-tab underline slide, in milliseconds.
pub const underline_slide_ms: u64 = 160;

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
// UnderlineState
// ---------------------------------------------------------------------------

/// Focused-tab underline slide state.
pub const UnderlineState = struct {
    positioned: bool = false,
    tab_id: ?u32 = null,
    /// Pixel x where the slide started.
    start_left: f32 = 0.0,
    /// Width at slide start.
    start_width: f32 = 0.0,
    /// Destination left edge.
    target_left: f32 = 0.0,
    /// Destination width.
    target_width: f32 = 0.0,
    /// Timestamp when the current slide began.
    slide_started_ms: u64 = 0,

    /// Slide only on selection changes; layout/DPI changes track the tab exactly.
    pub fn retarget(self: *UnderlineState, tab_id: u32, left: f32, width: f32, now_ms: u64, animate: bool) bool {
        const selection_changed = self.tab_id != tab_id;
        self.tab_id = tab_id;
        if (animate and !selection_changed and self.positioned and self.target_left == left and self.target_width == width) return false;
        if (!self.positioned or !animate or !selection_changed) {
            self.positioned = true;
            self.slide_started_ms = 0;
            self.target_left = left;
            self.start_left = left;
            self.target_width = width;
            self.start_width = width;
            return false;
        }
        self.retargetTo(left, width, now_ms);
        return true;
    }

    /// Begin (or redirect) a slide toward `new_left` / `new_width`.
    /// If called mid-slide, captures the current interpolated position
    /// as the new start so the line never jumps.
    pub fn retargetTo(self: *UnderlineState, new_left: f32, new_width: f32, now_ms: u64) void {
        const cur = self.currentRect(now_ms);
        self.positioned = true;
        self.start_left = cur.left;
        self.start_width = cur.width;
        self.target_left = new_left;
        self.target_width = new_width;
        self.slide_started_ms = now_ms;
    }

    /// Current (left, width) of the underline, interpolated with cubic
    /// ease-in-out.
    pub fn currentRect(self: UnderlineState, now_ms: u64) struct { left: f32, width: f32 } {
        if (self.slide_started_ms == 0) {
            return .{ .left = self.target_left, .width = self.target_width };
        }
        if (now_ms <= self.slide_started_ms) {
            return .{ .left = self.start_left, .width = self.start_width };
        }
        const elapsed = now_ms - self.slide_started_ms;
        if (elapsed >= underline_slide_ms) {
            return .{ .left = self.target_left, .width = self.target_width };
        }
        const t: f32 = @as(f32, @floatFromInt(elapsed)) /
            @as(f32, @floatFromInt(underline_slide_ms));
        const e = easeInOutCubic(t);
        return .{
            .left = self.start_left + (self.target_left - self.start_left) * e,
            .width = self.start_width + (self.target_width - self.start_width) * e,
        };
    }

    /// True while the slide is in progress.
    pub fn animating(self: UnderlineState, now_ms: u64) bool {
        if (self.slide_started_ms == 0) return false;
        if (now_ms <= self.slide_started_ms) return true;
        return (now_ms - self.slide_started_ms) < underline_slide_ms;
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

test "CHROME57 underline second retarget slides and reduced motion clears the slide" {
    var state: UnderlineState = .{};
    try std.testing.expect(!state.retarget(1, 10, 100, 1000, true));
    try std.testing.expectEqual(@as(f32, 10), state.currentRect(1000).left);
    try std.testing.expect(state.retarget(2, 110, 100, 1200, true));
    try std.testing.expectApproxEqAbs(@as(f32, 60), state.currentRect(1280).left, 0.01);
    const before = state.currentRect(1280);
    try std.testing.expect(state.retarget(3, 210, 100, 1280, true));
    try std.testing.expectEqual(before.left, state.currentRect(1280).left);
    try std.testing.expect(!state.retarget(3, 210, 100, 1281, false));
    try std.testing.expectEqual(@as(f32, 210), state.currentRect(1281).left);
    try std.testing.expect(!state.animating(1281));
}

test "CHROME57 underline geometry changes snap without restarting selection animation" {
    var state: UnderlineState = .{};
    _ = state.retarget(1, 10, 100, 1000, true);
    try std.testing.expect(state.retarget(2, 110, 100, 1200, true));
    try std.testing.expect(!state.retarget(2, 110, 100, 1220, true));
    try std.testing.expectEqual(@as(u64, 1200), state.slide_started_ms);
    try std.testing.expect(!state.retarget(2, 90, 80, 1240, true));
    try std.testing.expectEqual(@as(f32, 90), state.currentRect(1240).left);
    try std.testing.expectEqual(@as(f32, 80), state.currentRect(1240).width);
    try std.testing.expect(!state.animating(1240));
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
// UnderlineState tests
// ---------------------------------------------------------------------------

test "UnderlineState: retargetTo from zero state" {
    var us: UnderlineState = .{};
    us.retargetTo(100.0, 80.0, 500);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), us.target_left, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 80.0), us.target_width, 1e-6);
}

test "UnderlineState: currentRect at t=0" {
    var us: UnderlineState = .{};
    // First retarget to set an initial position.
    us.retargetTo(50.0, 60.0, 100);
    // Let that complete.
    // Now retarget to a new position.
    us.retargetTo(200.0, 100.0, 1000);
    const r = us.currentRect(1000);
    // At t=0, should be at start (which was captured from previous target).
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), r.left, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 60.0), r.width, 1.0);
}

test "UnderlineState: currentRect at t=1" {
    var us: UnderlineState = .{};
    us.retargetTo(50.0, 60.0, 100);
    us.retargetTo(200.0, 100.0, 1000);
    const r = us.currentRect(1000 + underline_slide_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), r.left, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), r.width, 1e-6);
}

test "UnderlineState: currentRect at t=0.5 uses eased midpoint" {
    var us: UnderlineState = .{};
    us.retargetTo(0.0, 80.0, 100);
    us.retargetTo(200.0, 120.0, 1000);
    const r = us.currentRect(1000 + underline_slide_ms / 2);
    // easeInOutCubic(0.5) == 0.5, so midpoint is linear average.
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), r.left, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), r.width, 1.0);
}

test "UnderlineState: mid-slide retarget captures current" {
    var us: UnderlineState = .{};
    us.retargetTo(0.0, 80.0, 100);
    // Start a slide from 0 -> 300.
    us.retargetTo(300.0, 80.0, 1000);
    // Mid-slide at 50% (eased = 0.5 for cubic at midpoint).
    const mid_time = 1000 + underline_slide_ms / 2;
    const mid_rect = us.currentRect(mid_time);
    // Now retarget to 600.
    us.retargetTo(600.0, 80.0, mid_time);
    // Immediately after retarget, the start should be the captured midpoint.
    const r = us.currentRect(mid_time);
    try std.testing.expectApproxEqAbs(mid_rect.left, r.left, 1.0);
    // After full duration, should reach 600.
    const done = us.currentRect(mid_time + underline_slide_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 600.0), done.left, 1e-6);
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
