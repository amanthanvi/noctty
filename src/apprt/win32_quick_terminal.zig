//! Quick-terminal geometry.
//!
//! Pure rectangle math for the quick terminal window. Computes start and
//! end positions for slide-in animation given monitor work-area and the
//! seven config fields:
//!
//!   position              — edge to dock against (top/bottom/left/right/center)
//!   size                  — percentage of edge dimension or absolute pixels
//!   screen                — which monitor(s): main, focused, all
//!   animation_duration_s  — seconds for slide tween (0 = snap)
//!   autohide              — hide on focus-loss
//!   space_behavior        — follow virtual-desktop switches or stay put
//!   keyboard_interactivity — when the QT receives keyboard input
//!
//! Position semantics:
//!
//!   top    — full work-area width; height = size against H; top-anchored.
//!            Start rect shifted -height above work-area top.
//!   bottom — full work-area width; height = size against H; bottom-anchored.
//!            Start rect shifted +height below work-area bottom.
//!   left   — full work-area height; width = size against W; left-anchored.
//!            Start rect shifted -width left of work-area left.
//!   right  — full work-area height; width = size against W; right-anchored.
//!            Start rect shifted +width right of work-area right.
//!   center — width = size against W, height = size against H; centered.
//!            Start rect == end rect (no slide; caller fades alpha).
//!
//! This module is allocation-free and uses shared Win32-compatible geometry
//! types without importing the Win32 runtime module.

const std = @import("std");
const geometry = @import("win32_geometry.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Position = enum { top, bottom, left, right, center };

pub const SizePercent = union(enum) {
    pixels: u32,
    percent: f32,
};

pub const Screen = enum { main, focused, all };

pub const KeyboardInteractivity = enum { on_demand, always, never };

pub const SpaceBehavior = enum { move, ignore };

pub const QuickTerminalConfig = struct {
    position: Position = .top,
    /// Primary axis size. For `.top` / `.bottom`, governs HEIGHT.
    /// For `.left` / `.right`, governs WIDTH. For `.center`, governs
    /// WIDTH (and `size_secondary` governs HEIGHT if set).
    size: SizePercent = .{ .percent = 25 },
    /// Secondary axis size, optional. Only consulted for `.center`
    /// (controls the perpendicular HEIGHT dimension) since
    /// edge-docked positions fill the perpendicular axis from the
    /// work-area completely. When null for `.center`, the perpendicular
    /// axis falls back to `size` so a single scalar still produces a
    /// square by default.
    size_secondary: ?SizePercent = null,
    screen: Screen = .main,
    animation_duration_s: f64 = 0.2,
    autohide: bool = true,
    space_behavior: SpaceBehavior = .move,
    keyboard_interactivity: KeyboardInteractivity = .on_demand,
};

pub const FocusPolicy = struct {
    activate_window: bool,
    diagnostic: Diagnostic = .none,

    pub const Diagnostic = enum {
        none,
        exclusive_keyboard_grab_unsupported,
    };
};

pub const Rect = geometry.Rect;

pub const MonitorInfo = struct {
    work_area: Rect,
    full_rect: Rect,
};

// ---------------------------------------------------------------------------
// Size resolution helper
// ---------------------------------------------------------------------------

/// Resolve a SizePercent against a given edge dimension (pixels).
/// Returns a value clamped to [1, edge_dimension].
fn resolveSize(size: SizePercent, edge_dimension: i32) i32 {
    const dim: i32 = switch (size) {
        .pixels => |px| @as(i32, @intCast(px)),
        .percent => |pct| blk: {
            if (pct <= 0) break :blk 1;
            const edge_f: f64 = @floatFromInt(edge_dimension);
            const raw: f64 = edge_f * (@as(f64, pct) / 100.0);
            break :blk @as(i32, @intFromFloat(@round(raw)));
        },
    };
    return std.math.clamp(dim, 1, edge_dimension);
}

// ---------------------------------------------------------------------------
// Core math — public API
// ---------------------------------------------------------------------------

/// Final (docked) rect once animation completes.
pub fn computeEndRect(cfg: QuickTerminalConfig, monitor: MonitorInfo) Rect {
    const wa = monitor.work_area;
    const wa_w = wa.width();
    const wa_h = wa.height();

    return switch (cfg.position) {
        .top => .{
            .left = wa.left,
            .top = wa.top,
            .right = wa.right,
            .bottom = wa.top + resolveSize(cfg.size, wa_h),
        },
        .bottom => blk: {
            const h = resolveSize(cfg.size, wa_h);
            break :blk .{
                .left = wa.left,
                .top = wa.bottom - h,
                .right = wa.right,
                .bottom = wa.bottom,
            };
        },
        .left => .{
            .left = wa.left,
            .top = wa.top,
            .right = wa.left + resolveSize(cfg.size, wa_w),
            .bottom = wa.bottom,
        },
        .right => blk: {
            const w = resolveSize(cfg.size, wa_w);
            break :blk .{
                .left = wa.right - w,
                .top = wa.top,
                .right = wa.right,
                .bottom = wa.bottom,
            };
        },
        .center => blk: {
            const w = resolveSize(cfg.size, wa_w);
            // For center, `size` governs WIDTH; height uses the
            // secondary axis when provided, falling back to `size`
            // when not (equal-axis square — the single-scalar
            // default).
            const h_size = cfg.size_secondary orelse cfg.size;
            const h = resolveSize(h_size, wa_h);
            const cx = wa.left + @divTrunc(wa_w, 2);
            const cy = wa.top + @divTrunc(wa_h, 2);
            break :blk .{
                .left = cx - @divTrunc(w, 2),
                .top = cy - @divTrunc(h, 2),
                .right = cx - @divTrunc(w, 2) + w,
                .bottom = cy - @divTrunc(h, 2) + h,
            };
        },
    };
}

/// Start rect — fully off-screen on the slide-origin edge.
/// For `.center`, returns the same rect as computeEndRect (no slide).
pub fn computeStartRect(cfg: QuickTerminalConfig, monitor: MonitorInfo) Rect {
    const end = computeEndRect(cfg, monitor);

    return switch (cfg.position) {
        .top => .{
            .left = end.left,
            .top = end.top - end.height(),
            .right = end.right,
            .bottom = end.top,
        },
        .bottom => .{
            .left = end.left,
            .top = end.bottom,
            .right = end.right,
            .bottom = end.bottom + end.height(),
        },
        .left => .{
            .left = end.left - end.width(),
            .top = end.top,
            .right = end.left,
            .bottom = end.bottom,
        },
        .right => .{
            .left = end.right,
            .top = end.top,
            .right = end.right + end.width(),
            .bottom = end.bottom,
        },
        .center => end,
    };
}

/// Linearly interpolate between two rects. t=0 returns `start`, t=1
/// returns `end`. Intermediate values are rounded to integer pixels.
pub fn lerpRect(start: Rect, end: Rect, t: f64) Rect {
    const tc = std.math.clamp(t, 0.0, 1.0);
    return .{
        .left = lerpI32(start.left, end.left, tc),
        .top = lerpI32(start.top, end.top, tc),
        .right = lerpI32(start.right, end.right, tc),
        .bottom = lerpI32(start.bottom, end.bottom, tc),
    };
}

pub fn animationDurationMs(duration_s: f64) u16 {
    if (!std.math.isFinite(duration_s) or duration_s <= 0) return 0;
    const raw_ms = duration_s * std.time.ms_per_s;
    const clamped = @min(raw_ms, @as(f64, @floatFromInt(std.math.maxInt(u16))));
    return @intFromFloat(@round(clamped));
}

pub fn focusPolicy(interactivity: KeyboardInteractivity) FocusPolicy {
    return switch (interactivity) {
        .on_demand => .{ .activate_window = true },
        .always => .{
            .activate_window = true,
            .diagnostic = .exclusive_keyboard_grab_unsupported,
        },
        .never => .{ .activate_window = false },
    };
}

fn lerpI32(a: i32, b: i32, t: f64) i32 {
    const af: f64 = @floatFromInt(a);
    const bf: f64 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}

/// Combine N monitor infos into one bounding MonitorInfo spanning the
/// entire virtual desktop. Caller must pass at least one monitor.
pub fn unionMonitors(monitors: []const MonitorInfo) MonitorInfo {
    std.debug.assert(monitors.len > 0);
    var wa = monitors[0].work_area;
    var fr = monitors[0].full_rect;
    for (monitors[1..]) |m| {
        wa = unionRect(wa, m.work_area);
        fr = unionRect(fr, m.full_rect);
    }
    return .{ .work_area = wa, .full_rect = fr };
}

fn unionRect(a: Rect, b: Rect) Rect {
    return .{
        .left = @min(a.left, b.left),
        .top = @min(a.top, b.top),
        .right = @max(a.right, b.right),
        .bottom = @max(a.bottom, b.bottom),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Standard 1920x1080 monitor at (0,0) with no taskbar offset.
const test_monitor: MonitorInfo = .{
    .work_area = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
    .full_rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
};

test "top 25% on a 1920x1080 monitor" {
    const cfg: QuickTerminalConfig = .{ .position = .top, .size = .{ .percent = 25 } };
    const end = computeEndRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 0), end.left);
    try testing.expectEqual(@as(i32, 0), end.top);
    try testing.expectEqual(@as(i32, 1920), end.right);
    try testing.expectEqual(@as(i32, 270), end.bottom);

    const start = computeStartRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, -270), start.top);
    try testing.expectEqual(@as(i32, 0), start.bottom);
    try testing.expectEqual(@as(i32, 1920), end.width());
    try testing.expectEqual(@as(i32, 270), end.height());
}

test "bottom 25%" {
    const cfg: QuickTerminalConfig = .{ .position = .bottom, .size = .{ .percent = 25 } };
    const end = computeEndRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 810), end.top);
    try testing.expectEqual(@as(i32, 1080), end.bottom);

    const start = computeStartRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 1080), start.top);
    try testing.expectEqual(@as(i32, 1350), start.bottom);
}

test "left 30%" {
    const cfg: QuickTerminalConfig = .{ .position = .left, .size = .{ .percent = 30 } };
    const end = computeEndRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 576), end.right);
    try testing.expectEqual(@as(i32, 0), end.left);
    try testing.expectEqual(@as(i32, 1080), end.height());

    const start = computeStartRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, -576), start.left);
    try testing.expectEqual(@as(i32, 0), start.right);
}

test "right 30%" {
    const cfg: QuickTerminalConfig = .{ .position = .right, .size = .{ .percent = 30 } };
    const end = computeEndRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 1344), end.left);
    try testing.expectEqual(@as(i32, 1920), end.right);

    const start = computeStartRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 1920), start.left);
    try testing.expectEqual(@as(i32, 2496), start.right);
}

test "center 40%" {
    const cfg: QuickTerminalConfig = .{ .position = .center, .size = .{ .percent = 40 } };
    const end = computeEndRect(cfg, test_monitor);
    // 40% of 1920 = 768, 40% of 1080 = 432
    try testing.expectEqual(@as(i32, 768), end.width());
    try testing.expectEqual(@as(i32, 432), end.height());
    // Centered: left = 960 - 384 = 576, top = 540 - 216 = 324
    try testing.expectEqual(@as(i32, 576), end.left);
    try testing.expectEqual(@as(i32, 324), end.top);

    // Start == end for center (no slide)
    const start = computeStartRect(cfg, test_monitor);
    try testing.expectEqual(end.left, start.left);
    try testing.expectEqual(end.top, start.top);
    try testing.expectEqual(end.right, start.right);
    try testing.expectEqual(end.bottom, start.bottom);
}

test "pixel size" {
    const cfg: QuickTerminalConfig = .{ .position = .top, .size = .{ .pixels = 400 } };
    const end = computeEndRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 400), end.height());
    try testing.expectEqual(@as(i32, 1920), end.width());
}

test "percent over 100 clamps to monitor" {
    const cfg: QuickTerminalConfig = .{ .position = .top, .size = .{ .percent = 200 } };
    const end = computeEndRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 1080), end.height());
}

test "percent under 1 clamps to 1 px" {
    const cfg: QuickTerminalConfig = .{ .position = .top, .size = .{ .percent = 0 } };
    const end = computeEndRect(cfg, test_monitor);
    try testing.expectEqual(@as(i32, 1), end.height());
}

test "lerpRect at t=0.5 returns midpoint" {
    const a: Rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 };
    const b: Rect = .{ .left = 100, .top = 100, .right = 200, .bottom = 200 };
    const mid = lerpRect(a, b, 0.5);
    try testing.expectEqual(@as(i32, 50), mid.left);
    try testing.expectEqual(@as(i32, 50), mid.top);
    try testing.expectEqual(@as(i32, 150), mid.right);
    try testing.expectEqual(@as(i32, 150), mid.bottom);
}

test "lerpRect clamps t" {
    const a: Rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 };
    const b: Rect = .{ .left = 200, .top = 200, .right = 300, .bottom = 300 };
    const under = lerpRect(a, b, -1.0);
    try testing.expectEqual(@as(i32, 0), under.left);
    const over = lerpRect(a, b, 2.0);
    try testing.expectEqual(@as(i32, 200), over.left);
}

test "animationDurationMs clamps invalid and large durations" {
    try testing.expectEqual(@as(u16, 0), animationDurationMs(-1));
    try testing.expectEqual(@as(u16, 0), animationDurationMs(std.math.nan(f64)));
    try testing.expectEqual(@as(u16, 200), animationDurationMs(0.2));
    try testing.expectEqual(std.math.maxInt(u16), animationDurationMs(90));
}

test "focusPolicy maps keyboard interactivity to Win32 activation behavior" {
    try testing.expectEqual(true, focusPolicy(.on_demand).activate_window);
    try testing.expectEqual(.none, focusPolicy(.on_demand).diagnostic);

    const always = focusPolicy(.always);
    try testing.expectEqual(true, always.activate_window);
    try testing.expectEqual(.exclusive_keyboard_grab_unsupported, always.diagnostic);

    try testing.expectEqual(false, focusPolicy(.never).activate_window);
}

test "unionMonitors spans two side-by-side monitors" {
    const monitors = [_]MonitorInfo{
        .{
            .work_area = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
            .full_rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
        },
        .{
            .work_area = .{ .left = 1920, .top = 0, .right = 3840, .bottom = 1080 },
            .full_rect = .{ .left = 1920, .top = 0, .right = 3840, .bottom = 1080 },
        },
    };
    const combined = unionMonitors(&monitors);
    try testing.expectEqual(@as(i32, 0), combined.work_area.left);
    try testing.expectEqual(@as(i32, 3840), combined.work_area.right);
    try testing.expectEqual(@as(i32, 1080), combined.work_area.bottom);
}

test "center on unionMonitors (all screens)" {
    const monitors = [_]MonitorInfo{
        .{
            .work_area = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
            .full_rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
        },
        .{
            .work_area = .{ .left = 1920, .top = 0, .right = 3840, .bottom = 1080 },
            .full_rect = .{ .left = 1920, .top = 0, .right = 3840, .bottom = 1080 },
        },
    };
    const combined = unionMonitors(&monitors);
    const cfg: QuickTerminalConfig = .{ .position = .center, .size = .{ .percent = 25 } };
    const end = computeEndRect(cfg, combined);
    // 25% of 3840 = 960, 25% of 1080 = 270
    try testing.expectEqual(@as(i32, 960), end.width());
    try testing.expectEqual(@as(i32, 270), end.height());
    // Centered at (1920, 540)
    try testing.expectEqual(@as(i32, 1440), end.left);
    try testing.expectEqual(@as(i32, 405), end.top);
}

test "work area with taskbar offset" {
    const monitor: MonitorInfo = .{
        .work_area = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 },
        .full_rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
    };
    const cfg: QuickTerminalConfig = .{ .position = .bottom, .size = .{ .percent = 25 } };
    const end = computeEndRect(cfg, monitor);
    // 25% of 1040 = 260
    try testing.expectEqual(@as(i32, 260), end.height());
    try testing.expectEqual(@as(i32, 1040), end.bottom);
    try testing.expectEqual(@as(i32, 780), end.top);
}
