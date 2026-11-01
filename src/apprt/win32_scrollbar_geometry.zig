//! Graphical scrollbar geometry and visibility state for the Win32 apprt.
//!
//! Pure math module — no HWND, no GL, no paint calls. Provides:
//!
//!   1. Track and thumb rectangle computation given a pane content rect,
//!      scroll position, and DPI scale.
//!   2. A four-state visibility machine (hidden → fading_in → visible →
//!      fading_out → hidden) with auto-hide semantics.
//!   3. Hover-widen logic: the track expands from 8 dp to 10 dp when the
//!      cursor is over it or a drag is in progress.
//!   4. Drag-to-scroll mapping (cursor Y → target top_row).
//!   5. Search match rows downsampled to the track's markers.
//!
//! **Auto-hide semantics.**  Any scroll activity (wheel, key, content
//! delta) resets a 1500 ms countdown.  When the countdown expires the
//! scrollbar fades out over 200 ms.  Hovering or dragging freezes the
//! timer — the bar stays fully visible until the cursor leaves / drag
//! ends, at which point the countdown restarts.
//!
//! **Fade-cancel smoothness.**  When new scroll activity arrives during
//! a fade-out, the fade-in starts from the *current* alpha rather than
//! snapping to 0.  `fade_started_ms` is back-computed so the fade-in
//! duration covers only the remaining alpha range.  This avoids a
//! visible pop when the user scrolls again just as the bar is
//! disappearing.
//!
//! The GL renderer in `src/renderer/OpenGL.zig` consumes `trackRect`,
//! `thumbRect`, and `ScrollbarState.alpha` each frame to emit two
//! quads into the overlay vertex buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Configuration constants (dp = density-independent pixels at 96 DPI)
// ---------------------------------------------------------------------------

/// Scrollbar track width at 96 DPI. GL renderer scales by current DPI.
pub const track_width_dp: f32 = 8;

/// Hover-widen width at 96 DPI. Activates when the cursor is over
/// the track; thumb drag-in-progress uses this too.
pub const track_width_hover_dp: f32 = 10;

/// Minimum thumb height at 96 DPI. Small buffers don't produce a
/// sub-pixel thumb.
pub const thumb_min_height_dp: f32 = 40;

/// Milliseconds after the last scroll activity before the
/// scrollbar auto-hides. Reset-on-movement semantics.
pub const auto_hide_delay_ms: u64 = 1500;

/// Milliseconds the fade-out animation takes after the delay.
pub const auto_hide_fade_ms: u64 = 200;

// ---------------------------------------------------------------------------
// Visibility state machine
// ---------------------------------------------------------------------------

pub const Visibility = enum {
    hidden,
    fading_in,
    visible,
    fading_out,
};

pub const ScrollbarState = struct {
    visibility: Visibility = .hidden,
    /// Timestamp (ms) of the last scroll/hover/drag activity.
    last_activity_ms: u64 = 0,
    /// Start-of-fade timestamp for fading_in / fading_out.
    fade_started_ms: u64 = 0,
    /// True while the cursor hovers the track. Prevents auto-hide.
    hovered: bool = false,
    /// True while the user drags the thumb. Prevents auto-hide.
    dragging: bool = false,

    pub fn init() ScrollbarState {
        return .{};
    }

    /// Called on any scroll activity. Resets timer; triggers fade-in
    /// if hidden; cancels fade-out preserving current alpha.
    pub fn onScrollActivity(self: *ScrollbarState, now_ms: u64) void {
        self.last_activity_ms = now_ms;
        switch (self.visibility) {
            .hidden => {
                self.visibility = .fading_in;
                self.fade_started_ms = now_ms;
            },
            .fading_out => {
                // Cancel fade-out: start fade-in from current alpha.
                const current = rawFadeOutAlpha(self.*, now_ms);
                self.visibility = .fading_in;
                // Back-compute start so alpha(now) == current.
                // fade-in alpha = (now - start) / dur  =>  start = now - current * dur
                const offset: u64 = @intFromFloat(current * @as(f32, @floatFromInt(auto_hide_fade_ms)));
                self.fade_started_ms = now_ms -| offset;
            },
            .fading_in, .visible => {},
        }
    }

    /// Periodic tick driven by the renderer heartbeat. Returns true
    /// when visibility changed (caller should repaint).
    pub fn tick(self: *ScrollbarState, now_ms: u64) bool {
        const prev = self.visibility;
        switch (self.visibility) {
            .hidden => {},
            .fading_in => {
                const elapsed = now_ms -| self.fade_started_ms;
                if (elapsed >= auto_hide_fade_ms) {
                    self.visibility = .visible;
                    self.last_activity_ms = now_ms;
                }
            },
            .visible => {
                if (!self.hovered and !self.dragging) {
                    const idle = now_ms -| self.last_activity_ms;
                    if (idle >= auto_hide_delay_ms) {
                        self.visibility = .fading_out;
                        self.fade_started_ms = now_ms;
                    }
                }
            },
            .fading_out => {
                const elapsed = now_ms -| self.fade_started_ms;
                if (elapsed >= auto_hide_fade_ms) {
                    self.visibility = .hidden;
                }
            },
        }
        return self.visibility != prev;
    }

    /// Current alpha [0, 1].
    pub fn alpha(self: ScrollbarState, now_ms: u64) f32 {
        return switch (self.visibility) {
            .hidden => 0.0,
            .visible => 1.0,
            .fading_in => blk: {
                const elapsed = now_ms -| self.fade_started_ms;
                const t: f32 = @as(f32, @floatFromInt(@min(elapsed, auto_hide_fade_ms))) /
                    @as(f32, @floatFromInt(auto_hide_fade_ms));
                break :blk std.math.clamp(t, 0.0, 1.0);
            },
            .fading_out => rawFadeOutAlpha(self, now_ms),
        };
    }

    pub fn setHovered(self: *ScrollbarState, value: bool, now_ms: u64) void {
        self.hovered = value;
        if (value) {
            self.last_activity_ms = now_ms;
            if (self.visibility == .hidden) {
                self.visibility = .fading_in;
                self.fade_started_ms = now_ms;
            } else if (self.visibility == .fading_out) {
                self.onScrollActivity(now_ms);
            }
        } else {
            // Leaving hover: reset activity so auto-hide countdown restarts.
            self.last_activity_ms = now_ms;
        }
    }

    pub fn setDragging(self: *ScrollbarState, value: bool, now_ms: u64) void {
        self.dragging = value;
        if (value) {
            self.last_activity_ms = now_ms;
            if (self.visibility == .hidden) {
                self.visibility = .fading_in;
                self.fade_started_ms = now_ms;
            } else if (self.visibility == .fading_out) {
                self.onScrollActivity(now_ms);
            }
        } else {
            self.last_activity_ms = now_ms;
        }
    }

    /// Internal: fade-out alpha without clamping to enum.
    fn rawFadeOutAlpha(self: ScrollbarState, now_ms: u64) f32 {
        const elapsed = now_ms -| self.fade_started_ms;
        const t: f32 = @as(f32, @floatFromInt(@min(elapsed, auto_hide_fade_ms))) /
            @as(f32, @floatFromInt(auto_hide_fade_ms));
        return std.math.clamp(1.0 - t, 0.0, 1.0);
    }
};

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

pub const Rect = extern struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    fn width(self: Rect) f32 {
        return self.right - self.left;
    }

    fn height(self: Rect) f32 {
        return self.bottom - self.top;
    }

    fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.left and x <= self.right and
            y >= self.top and y <= self.bottom;
    }
};

pub const Layout = struct {
    pane: Rect,
    total_rows: usize,
    viewport_rows: usize,
    top_row: usize,
    dpi_scale: f32 = 1.0,
    hovered: bool = false,
    dragging: bool = false,
};

/// Track rect on the right edge of the pane. Width depends on
/// hover/drag state.
pub fn trackRect(layout: Layout) Rect {
    const w = effectiveWidth(layout);
    return .{
        .left = layout.pane.right - w,
        .top = layout.pane.top,
        .right = layout.pane.right,
        .bottom = layout.pane.bottom,
    };
}

/// Thumb rect within the track. Height is proportional to
/// viewport_rows / total_rows, clamped to thumb_min_height_dp.
pub fn thumbRect(layout: Layout) Rect {
    const track = trackRect(layout);
    const track_h = track.height();
    if (layout.total_rows == 0 or layout.viewport_rows >= layout.total_rows) {
        return track; // Thumb fills entire track — nothing to scroll.
    }

    const ratio: f32 = @as(f32, @floatFromInt(layout.viewport_rows)) /
        @as(f32, @floatFromInt(layout.total_rows));
    const min_h = thumb_min_height_dp * layout.dpi_scale;
    const raw_h = ratio * track_h;
    const thumb_h = @max(raw_h, @min(min_h, track_h));

    const scrollable = layout.total_rows - layout.viewport_rows;
    const frac: f32 = if (scrollable == 0)
        0.0
    else
        @as(f32, @floatFromInt(layout.top_row)) / @as(f32, @floatFromInt(scrollable));

    const travel = track_h - thumb_h;
    const thumb_top = track.top + frac * travel;

    return .{
        .left = track.left,
        .top = thumb_top,
        .right = track.right,
        .bottom = thumb_top + thumb_h,
    };
}

/// Map cursor Y → target top_row during a thumb drag.
/// `drag_anchor_offset` is the Y offset within the thumb where the
/// drag started (so the thumb doesn't jump on click).
pub fn rowFromCursor(layout: Layout, cursor_y: f32, drag_anchor_offset: f32) usize {
    if (layout.total_rows <= layout.viewport_rows) return 0;
    const track = trackRect(layout);
    const track_h = track.height();
    const ratio: f32 = @as(f32, @floatFromInt(layout.viewport_rows)) /
        @as(f32, @floatFromInt(layout.total_rows));
    const min_h = thumb_min_height_dp * layout.dpi_scale;
    const raw_h = ratio * track_h;
    const thumb_h = @max(raw_h, @min(min_h, track_h));
    const travel = track_h - thumb_h;
    if (travel <= 0) return 0;

    const thumb_top = cursor_y - drag_anchor_offset;
    const frac = std.math.clamp((thumb_top - track.top) / travel, 0.0, 1.0);
    const scrollable = layout.total_rows - layout.viewport_rows;
    const row: usize = @intFromFloat(@round(frac * @as(f32, @floatFromInt(scrollable))));
    return @min(row, scrollable);
}

/// True when (x, y) falls within the hover-expanded track region.
/// Uses hover width so moving slightly right of the skinny track
/// still counts as hovering — avoids flicker on the boundary.
pub fn pointOverTrack(layout: Layout, x: f32, y: f32) bool {
    const hover_w = track_width_hover_dp * layout.dpi_scale;
    const r: Rect = .{
        .left = layout.pane.right - hover_w,
        .top = layout.pane.top,
        .right = layout.pane.right,
        .bottom = layout.pane.bottom,
    };
    return r.contains(x, y);
}

/// True when (x, y) falls within the current thumb rect.
pub fn pointOverThumb(layout: Layout, x: f32, y: f32) bool {
    return thumbRect(layout).contains(x, y);
}

fn effectiveWidth(layout: Layout) f32 {
    const dp: f32 = if (layout.hovered or layout.dragging) track_width_hover_dp else track_width_dp;
    return dp * layout.dpi_scale;
}

// ---------------------------------------------------------------------
// Match-marker downsampling
// ---------------------------------------------------------------------

/// Downsample `matches` (sorted ascending, unique row indices) into at
/// most `max_markers` normalized [0, 1] positions for the scrollbar
/// overlay.
///
/// When `matches.len <= max_markers` every match is returned directly
/// as `row / total_rows`.  Otherwise the scrollback is partitioned into
/// `max_markers` equal-height bins and any bin containing at least one
/// match emits a marker at the bin's midpoint.
pub fn downsampleMarkers(
    alloc: Allocator,
    matches: []const usize,
    total_rows: usize,
    max_markers: usize,
) Allocator.Error![]f32 {
    if (matches.len == 0 or total_rows == 0 or max_markers == 0) {
        return try alloc.alloc(f32, 0);
    }

    const rows_f: f64 = @floatFromInt(total_rows);

    // Fast path: few enough matches to emit them all.
    if (matches.len <= max_markers) {
        const out = try alloc.alloc(f32, matches.len);
        for (matches, 0..) |row, i| {
            out[i] = @floatCast(@as(f64, @floatFromInt(row)) / rows_f);
        }
        return out;
    }

    // Bucket path: partition into `max_markers` equal bins.
    const bin_height: f64 = rows_f / @as(f64, @floatFromInt(max_markers));

    // Bit-set tracking which bins are occupied.  Use a dynamic array of
    // bools — max_markers is typically small (scrollbar track pixels).
    const occupied = try alloc.alloc(bool, max_markers);
    defer alloc.free(occupied);
    @memset(occupied, false);

    for (matches) |row| {
        var bin: usize = @intFromFloat(@as(f64, @floatFromInt(row)) / bin_height);
        if (bin >= max_markers) bin = max_markers - 1;
        occupied[bin] = true;
    }

    // Count occupied bins, allocate output.
    var count: usize = 0;
    for (occupied) |o| {
        if (o) count += 1;
    }
    const out = try alloc.alloc(f32, count);

    var idx: usize = 0;
    for (occupied, 0..) |o, b| {
        if (o) {
            const mid: f64 = (@as(f64, @floatFromInt(b)) + 0.5) * bin_height / rows_f;
            out[idx] = @floatCast(mid);
            idx += 1;
        }
    }

    return out;
}

// ===========================================================================
// Tests
// ===========================================================================

test "init is hidden" {
    const s = ScrollbarState.init();
    try std.testing.expectEqual(Visibility.hidden, s.visibility);
    try std.testing.expectEqual(@as(f32, 0.0), s.alpha(0));
}

test "scroll activity from hidden → fading_in" {
    var s = ScrollbarState.init();
    s.onScrollActivity(1000);
    try std.testing.expectEqual(Visibility.fading_in, s.visibility);
}

test "fading_in completes → visible after fade_ms" {
    var s = ScrollbarState.init();
    s.onScrollActivity(1000);
    const changed = s.tick(1000 + auto_hide_fade_ms);
    try std.testing.expect(changed);
    try std.testing.expectEqual(Visibility.visible, s.visibility);
}

test "visible → fading_out after auto_hide_delay_ms with no activity" {
    var s = ScrollbarState.init();
    s.onScrollActivity(0);
    _ = s.tick(auto_hide_fade_ms); // complete fade-in
    try std.testing.expectEqual(Visibility.visible, s.visibility);
    const changed = s.tick(auto_hide_fade_ms + auto_hide_delay_ms);
    try std.testing.expect(changed);
    try std.testing.expectEqual(Visibility.fading_out, s.visibility);
}

test "hovered prevents auto-hide" {
    var s = ScrollbarState.init();
    s.onScrollActivity(0);
    _ = s.tick(auto_hide_fade_ms); // → visible
    s.setHovered(true, auto_hide_fade_ms);
    // Even after a long time, still visible.
    const changed = s.tick(auto_hide_fade_ms + auto_hide_delay_ms + 10_000);
    try std.testing.expect(!changed);
    try std.testing.expectEqual(Visibility.visible, s.visibility);
}

test "dragging prevents auto-hide" {
    var s = ScrollbarState.init();
    s.onScrollActivity(0);
    _ = s.tick(auto_hide_fade_ms); // → visible
    s.setDragging(true, auto_hide_fade_ms);
    const changed = s.tick(auto_hide_fade_ms + auto_hide_delay_ms + 10_000);
    try std.testing.expect(!changed);
    try std.testing.expectEqual(Visibility.visible, s.visibility);
}

test "fading_out → hidden after fade_ms" {
    var s = ScrollbarState.init();
    s.onScrollActivity(0);
    _ = s.tick(auto_hide_fade_ms); // → visible
    _ = s.tick(auto_hide_fade_ms + auto_hide_delay_ms); // → fading_out
    try std.testing.expectEqual(Visibility.fading_out, s.visibility);
    const changed = s.tick(auto_hide_fade_ms + auto_hide_delay_ms + auto_hide_fade_ms);
    try std.testing.expect(changed);
    try std.testing.expectEqual(Visibility.hidden, s.visibility);
}

test "scroll activity during fading_out → fading_in from current alpha" {
    var s = ScrollbarState.init();
    s.onScrollActivity(0);
    _ = s.tick(auto_hide_fade_ms); // → visible
    _ = s.tick(auto_hide_fade_ms + auto_hide_delay_ms); // → fading_out
    // Halfway through fade-out: alpha ~0.5
    const mid = auto_hide_fade_ms + auto_hide_delay_ms + auto_hide_fade_ms / 2;
    const alpha_before = s.alpha(mid);
    try std.testing.expect(alpha_before > 0.4);
    try std.testing.expect(alpha_before < 0.6);
    // Re-scroll: should switch to fading_in preserving alpha.
    s.onScrollActivity(mid);
    try std.testing.expectEqual(Visibility.fading_in, s.visibility);
    const alpha_after = s.alpha(mid);
    try std.testing.expect(@abs(alpha_after - alpha_before) < 0.05);
}

// -- alpha tests -----------------------------------------------------------

test "alpha: hidden → 0" {
    const s = ScrollbarState.init();
    try std.testing.expectEqual(@as(f32, 0.0), s.alpha(999));
}

test "alpha: visible → 1" {
    var s = ScrollbarState.init();
    s.visibility = .visible;
    try std.testing.expectEqual(@as(f32, 1.0), s.alpha(999));
}

test "alpha: fading_in progression" {
    var s = ScrollbarState.init();
    s.onScrollActivity(1000);
    // t=0 → 0
    try std.testing.expectEqual(@as(f32, 0.0), s.alpha(1000));
    // t=fade_ms/2 → 0.5
    try std.testing.expectEqual(@as(f32, 0.5), s.alpha(1000 + auto_hide_fade_ms / 2));
    // t=fade_ms → 1.0
    try std.testing.expectEqual(@as(f32, 1.0), s.alpha(1000 + auto_hide_fade_ms));
}

test "alpha: fading_out progression" {
    var s = ScrollbarState.init();
    s.visibility = .fading_out;
    s.fade_started_ms = 1000;
    // t=0 → 1
    try std.testing.expectEqual(@as(f32, 1.0), s.alpha(1000));
    // t=fade_ms → 0
    try std.testing.expectEqual(@as(f32, 0.0), s.alpha(1000 + auto_hide_fade_ms));
}

// -- geometry tests --------------------------------------------------------

fn testLayout() Layout {
    return .{
        .pane = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 },
        .total_rows = 1000,
        .viewport_rows = 100,
        .top_row = 0,
        .dpi_scale = 1.0,
    };
}

test "track on right edge" {
    const l = testLayout();
    const t = trackRect(l);
    try std.testing.expectEqual(@as(f32, 800.0 - track_width_dp), t.left);
    try std.testing.expectEqual(@as(f32, 800.0), t.right);
    try std.testing.expectEqual(@as(f32, 0.0), t.top);
    try std.testing.expectEqual(@as(f32, 600.0), t.bottom);
}

test "track widens while hovered" {
    var l = testLayout();
    l.hovered = true;
    const t = trackRect(l);
    try std.testing.expectEqual(@as(f32, 800.0 - track_width_hover_dp), t.left);
    try std.testing.expectEqual(@as(f32, 800.0), t.right);
    try std.testing.expectEqual(@as(f32, 0.0), t.top);
    try std.testing.expectEqual(@as(f32, 600.0), t.bottom);
}

test "thumb height proportional to viewport/total" {
    const l = testLayout(); // 100/1000 = 10%
    const t = thumbRect(l);
    const expected_h: f32 = 600.0 * 0.1; // 60
    try std.testing.expect(@abs(t.height() - expected_h) < 0.01);
}

test "thumb clamped to min height" {
    var l = testLayout();
    l.total_rows = 100_000;
    l.viewport_rows = 10;
    const t = thumbRect(l);
    try std.testing.expect(t.height() >= thumb_min_height_dp * l.dpi_scale - 0.01);
}

test "thumb top tracks top_row" {
    var l = testLayout();
    // top_row = 0 → thumb at top
    l.top_row = 0;
    const t0 = thumbRect(l);
    try std.testing.expectEqual(@as(f32, 0.0), t0.top);

    // top_row = max → thumb at bottom
    l.top_row = l.total_rows - l.viewport_rows;
    const tmax = thumbRect(l);
    try std.testing.expect(@abs(tmax.bottom - 600.0) < 0.01);
}

test "rowFromCursor inverts thumbRect" {
    const l = testLayout();
    const track = trackRect(l);
    // Cursor at track top → row 0
    const r0 = rowFromCursor(l, track.top, 0);
    try std.testing.expectEqual(@as(usize, 0), r0);
    // Cursor at track bottom (accounting for thumb height)
    const th = thumbRect(l);
    const rmax = rowFromCursor(l, track.bottom - th.height(), 0);
    // Should map to approximately max scrollable row
    const scrollable = l.total_rows - l.viewport_rows;
    // Allow rounding to land within 1 row
    try std.testing.expect(rmax >= scrollable - 1);
    try std.testing.expect(rmax <= scrollable);
}

test "rowFromCursor honors drag anchor offset" {
    var l = testLayout();
    l.top_row = 450;
    const thumb = thumbRect(l);
    const anchor = thumb.height() / 2.0;
    const cursor_y = thumb.top + anchor;
    const row = rowFromCursor(l, cursor_y, anchor);
    try std.testing.expect(row >= l.top_row - 1);
    try std.testing.expect(row <= l.top_row + 1);
}

test "pointOverTrack respects hover width" {
    var l = testLayout();
    // Point 1 px left of skinny track, within hover width
    const x = 800.0 - track_width_dp - 1.0;
    const y: f32 = 300.0;
    // Not hovered — uses skinny width for hit-test reference,
    // but pointOverTrack always uses hover width.
    l.hovered = false;
    try std.testing.expect(pointOverTrack(l, x, y));
    // Point far left — never over track
    try std.testing.expect(!pointOverTrack(l, 0, y));
}

test "pointOverThumb narrower than pointOverTrack" {
    var l = testLayout();
    l.top_row = 0;
    // A point in the track area but below the thumb
    const th = thumbRect(l);
    const x = l.pane.right - 1.0;
    const y = th.bottom + 10.0;
    try std.testing.expect(pointOverTrack(l, x, y));
    try std.testing.expect(!pointOverThumb(l, x, y));
}

test "N <= max returns all matches normalized" {
    const matches = [_]usize{ 10, 50, 90 };
    const out = try downsampleMarkers(std.testing.allocator, &matches, 100, 10);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.90), out[2], 0.001);
}

test "N > max buckets" {
    const matches = [_]usize{ 10, 20, 30, 40, 50 };
    const out = try downsampleMarkers(std.testing.allocator, &matches, 100, 2);
    defer std.testing.allocator.free(out);

    // 2 bins: [0..50) and [50..100).  Matches 10,20,30,40 in bin 0;
    // match 50 in bin 1.  Both occupied -> 2 markers.
    try std.testing.expectEqual(@as(usize, 2), out.len);
}

test "empty matches returns empty" {
    const matches = [_]usize{};
    const out = try downsampleMarkers(std.testing.allocator, &matches, 100, 10);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "total_rows=0 safe" {
    const matches = [_]usize{};
    const out = try downsampleMarkers(std.testing.allocator, &matches, 0, 10);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "single bucket with multiple matches" {
    const matches = [_]usize{ 5, 15, 25 };
    const out = try downsampleMarkers(std.testing.allocator, &matches, 30, 1);
    defer std.testing.allocator.free(out);

    // Single bin covers entire range; midpoint = 0.5.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
}
