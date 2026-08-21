//! Non-client-area geometry for the Win11 integrated titlebar.
//!
//! This module provides pure math for two window messages:
//!
//!   WM_NCCALCSIZE — adjusts the client rect so the caption row lives
//!   inside the client area (top margin zeroed), while preserving
//!   left / right / bottom resize borders.
//!
//!   WM_NCHITTEST — maps a cursor position to the correct HT* code.
//!   The close / max / min button rects are pixel-exact so that
//!   Win11 22H2+ Snap Layouts triggers on HTMAXBUTTON hover.
//!
//! Maximize compensation: when a window is maximized, Win11 adds an
//! invisible resize margin equal to `SM_CYSIZEFRAME + SM_CXPADDEDBORDER`
//! above the visible content. `calcNcClientRect` shifts the top edge
//! down by that amount so content is not clipped behind the monitor
//! bezel. Edge-resize strips are suppressed (everything maps to
//! .client) because the window already fills the work area.
//!
//! This module is allocation-free, has no Win32 API calls, and takes
//! all system metrics as caller-resolved inputs so it is fully
//! testable with synthetic values.

const std = @import("std");
const geometry = @import("win32_geometry.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const HitTest = enum(i32) {
    nowhere = 0,
    client = 1,
    caption = 2,
    sysmenu = 3,
    minbutton = 8,
    maxbutton = 9,
    left = 10,
    right = 11,
    top = 12,
    topleft = 13,
    topright = 14,
    bottom = 15,
    bottomleft = 16,
    bottomright = 17,
    close = 20,
};

pub const Rect = geometry.Rect;
pub const Point = geometry.Point;

pub const WindowState = enum {
    normal,
    maximized,
};

pub const Metrics = struct {
    /// `SM_CYSIZEFRAME` for this DPI. Typical 4 px @ 96 dpi.
    size_frame_y: i32,
    /// `SM_CXSIZEFRAME` for this DPI. Typical 4 px @ 96 dpi.
    size_frame_x: i32,
    /// `SM_CXPADDEDBORDER` for this DPI. Typical 4 px @ 96 dpi.
    padded_border: i32,
    /// Caption button width. Default 46 px @ 96 dpi.
    caption_button_w: i32,
    /// Caption button height (== integrated-titlebar height).
    /// Default 40 px @ 96 dpi.
    caption_button_h: i32,
    /// Edge-resize strip width. Includes the padded invisible border.
    edge_resize_width: i32,
};

/// Return default metrics scaled linearly from 96 dpi base values.
pub fn metricsDefault(dpi: u32) Metrics {
    const scale = @as(i32, @intCast(dpi));
    return .{
        .size_frame_y = scaleDim(4, scale),
        .size_frame_x = scaleDim(4, scale),
        .padded_border = scaleDim(4, scale),
        .caption_button_w = scaleDim(46, scale),
        .caption_button_h = scaleDim(40, scale),
        .edge_resize_width = scaleDim(8, scale),
    };
}

// ---------------------------------------------------------------------------
// WM_NCCALCSIZE
// ---------------------------------------------------------------------------

/// Compute the adjusted client rect for the integrated titlebar.
///
/// Normal: zero the top margin, preserve left / right / bottom borders.
/// Maximized: additionally shift top down by `size_frame_y + padded_border`
/// to compensate for the invisible resize margin Win11 adds.
pub fn calcNcClientRect(
    proposed: Rect,
    metrics: Metrics,
    state: WindowState,
) Rect {
    var r = proposed;

    // Preserve side and bottom resize borders.
    r.left += metrics.size_frame_x;
    r.right -= metrics.size_frame_x;
    r.bottom -= metrics.size_frame_y;

    // Top margin is zeroed (caption is drawn inside the client area).
    // For normal state the top stays at the proposed top.
    // For maximized state we push it down to compensate for the
    // invisible resize margin.
    r.top = switch (state) {
        .normal => proposed.top,
        .maximized => proposed.top + metrics.size_frame_y + metrics.padded_border,
    };

    return r;
}

// ---------------------------------------------------------------------------
// Caption button rects
// ---------------------------------------------------------------------------

pub const CaptionButtons = struct {
    close: Rect,
    max: Rect,
    min: Rect,
};

fn captionTop(window: Rect, metrics: Metrics, state: WindowState) i32 {
    return switch (state) {
        .normal => window.top,
        .maximized => window.top + metrics.size_frame_y + metrics.padded_border,
    };
}

/// Return the three caption-button rects in screen coordinates.
/// Order is right-to-left: close (rightmost), max, min.
/// Each button is `caption_button_w x caption_button_h`, flush against
/// the visible top-right corner of the caption row.
pub fn captionButtonsRect(window: Rect, metrics: Metrics, state: WindowState) CaptionButtons {
    const w = metrics.caption_button_w;
    const h = metrics.caption_button_h;
    const t = captionTop(window, metrics, state);

    return .{
        .close = .{
            .left = window.right - w,
            .top = t,
            .right = window.right,
            .bottom = t + h,
        },
        .max = .{
            .left = window.right - 2 * w,
            .top = t,
            .right = window.right - w,
            .bottom = t + h,
        },
        .min = .{
            .left = window.right - 3 * w,
            .top = t,
            .right = window.right - 2 * w,
            .bottom = t + h,
        },
    };
}

// ---------------------------------------------------------------------------
// WM_NCHITTEST
// ---------------------------------------------------------------------------

/// Classify a cursor position into the correct hit-test code.
///
/// Zone priority (highest first):
///   1. Resize corners (suppressed when maximized)
///   2. Close / Max / Min button rects
///   3. Sysmenu rect (leftmost 40 px of caption row)
///   4. Edge-resize strips (suppressed when maximized)
///   5. Caption row (top `caption_button_h` pixels)
///   6. Client area
pub fn hitTest(
    window: Rect,
    cursor: Point,
    metrics: Metrics,
    state: WindowState,
) HitTest {
    // Outside the window entirely.
    if (!window.contains(cursor.x, cursor.y)) return .nowhere;

    const edge_hit = if (state == .normal)
        edgeHitTest(window, cursor, metrics.edge_resize_width)
    else
        null;

    // --- 1. Resize corners must win in the outer frame so diagonal
    // resizing remains available with an integrated client titlebar.
    if (edge_hit) |hit| switch (hit) {
        .topleft, .topright, .bottomleft, .bottomright => return hit,
        else => {},
    };

    // --- 2. Caption buttons ---
    const btns = captionButtonsRect(window, metrics, state);
    if (btns.close.contains(cursor.x, cursor.y)) return .close;
    if (btns.max.contains(cursor.x, cursor.y)) return .maxbutton;
    if (btns.min.contains(cursor.x, cursor.y)) return .minbutton;

    // --- 3. Sysmenu (leftmost 40 px of caption row, DPI-unscaled; we
    //     use the caption_button_h as the sysmenu width for a square
    //     icon area) ---
    const caption_top = captionTop(window, metrics, state);
    const sysmenu_rect = Rect{
        .left = window.left,
        .top = caption_top,
        .right = window.left + metrics.caption_button_h,
        .bottom = caption_top + metrics.caption_button_h,
    };
    if (sysmenu_rect.contains(cursor.x, cursor.y)) return .sysmenu;

    // --- 4. Edge-resize strips (normal only) ---
    if (edge_hit) |hit| return hit;

    // --- 5. Caption row ---
    if (cursor.y >= caption_top and cursor.y < caption_top + metrics.caption_button_h) return .caption;

    // --- 6. Client ---
    return .client;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// Scale a base-96-dpi dimension to the target DPI (integer math,
/// rounded to nearest).
fn scaleDim(base: i32, dpi: i32) i32 {
    return @divTrunc(base * dpi + 48, 96);
}

/// Client-relative top of terminal content below app-painted chrome.
/// The tab and caption bands are independently sized; overlays begin below
/// whichever band extends farther into the client area.
pub fn terminalContentTop(
    tab_bottom: i32,
    caption_bottom: i32,
    overlay_height: i32,
    inspector_height: i32,
) i32 {
    return @max(tab_bottom, caption_bottom) + overlay_height + inspector_height;
}

/// Bottom of the app-painted tab/caption band. All dimensions are already
/// scaled for the host's current DPI.
pub fn captionBandBottom(
    tab_bottom: i32,
    titlebar_height: i32,
    caption_button_height: i32,
    integrated: bool,
) i32 {
    if (!integrated) return tab_bottom;
    return @max(tab_bottom, @max(titlebar_height, caption_button_height));
}

pub const ContentBands = struct {
    overlay_top: i32,
    inspector_top: i32,
    content_top: i32,
};

/// Boundaries for panels stacked between the tab/caption band and terminal.
pub fn contentBands(
    tab_bottom: i32,
    titlebar_height: i32,
    caption_button_height: i32,
    integrated: bool,
    overlay_height: i32,
    inspector_height: i32,
) ContentBands {
    const chrome_bottom = captionBandBottom(
        tab_bottom,
        titlebar_height,
        caption_button_height,
        integrated,
    );
    const inspector_top = chrome_bottom + overlay_height;
    return .{
        .overlay_top = chrome_bottom,
        .inspector_top = inspector_top,
        .content_top = terminalContentTop(
            tab_bottom,
            chrome_bottom,
            overlay_height,
            inspector_height,
        ),
    };
}

pub fn contentBottom(content_top: i32, client_bottom: i32, status_height: i32) i32 {
    return @max(content_top + 1, client_bottom - status_height);
}

fn edgeHitTest(window: Rect, cursor: Point, ew: i32) ?HitTest {
    const in_left = cursor.x < window.left + ew;
    const in_right = cursor.x >= window.right - ew;
    const in_top = cursor.y < window.top + ew;
    const in_bottom = cursor.y >= window.bottom - ew;

    if (in_top and in_left) return .topleft;
    if (in_top and in_right) return .topright;
    if (in_bottom and in_left) return .bottomleft;
    if (in_bottom and in_right) return .bottomright;
    if (in_top) return .top;
    if (in_bottom) return .bottom;
    if (in_left) return .left;
    if (in_right) return .right;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "metricsDefault: 96 dpi produces base values" {
    const m = metricsDefault(96);
    try std.testing.expectEqual(@as(i32, 4), m.size_frame_x);
    try std.testing.expectEqual(@as(i32, 4), m.size_frame_y);
    try std.testing.expectEqual(@as(i32, 4), m.padded_border);
    try std.testing.expectEqual(@as(i32, 46), m.caption_button_w);
    try std.testing.expectEqual(@as(i32, 40), m.caption_button_h);
    try std.testing.expectEqual(@as(i32, 8), m.edge_resize_width);
}

test "metricsDefault: 144 dpi (150%)" {
    const m = metricsDefault(144);
    try std.testing.expectEqual(@as(i32, 6), m.size_frame_x);
    try std.testing.expectEqual(@as(i32, 69), m.caption_button_w);
    try std.testing.expectEqual(@as(i32, 60), m.caption_button_h);
}

test "metricsDefault: 192 dpi (200%)" {
    const m = metricsDefault(192);
    try std.testing.expectEqual(@as(i32, 8), m.size_frame_x);
    try std.testing.expectEqual(@as(i32, 92), m.caption_button_w);
    try std.testing.expectEqual(@as(i32, 80), m.caption_button_h);
}

// -- calcNcClientRect -------------------------------------------------------

test "normal: zero top, keep side borders" {
    const m = metricsDefault(96);
    const proposed = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const r = calcNcClientRect(proposed, m, .normal);
    try std.testing.expectEqual(@as(i32, 4), r.left);
    try std.testing.expectEqual(@as(i32, 0), r.top);
    try std.testing.expectEqual(@as(i32, 1276), r.right);
    try std.testing.expectEqual(@as(i32, 796), r.bottom);
}

test "maximized: additional top inset" {
    const m = metricsDefault(96);
    const proposed = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const r = calcNcClientRect(proposed, m, .maximized);
    // top = size_frame_y + padded_border = 4 + 4 = 8
    try std.testing.expectEqual(@as(i32, 8), r.top);
}

test "sides preserved in both states" {
    const m = metricsDefault(96);
    const proposed = Rect{ .left = 100, .top = 50, .right = 1380, .bottom = 850 };
    const rn = calcNcClientRect(proposed, m, .normal);
    const rm = calcNcClientRect(proposed, m, .maximized);
    // Left, right, bottom borders are the same in both states.
    try std.testing.expectEqual(rn.left, rm.left);
    try std.testing.expectEqual(rn.right, rm.right);
    try std.testing.expectEqual(rn.bottom, rm.bottom);
    // Only top differs.
    try std.testing.expect(rm.top > rn.top);
}

// -- hitTest ----------------------------------------------------------------

test "top-left corner: resize wins over sysmenu in outer frame" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    try std.testing.expectEqual(HitTest.topleft, hitTest(win, .{ .x = 0, .y = 0 }, m, .normal));
    try std.testing.expectEqual(HitTest.sysmenu, hitTest(win, .{ .x = 20, .y = 20 }, m, .normal));
}

test "topleft resize at bottom-left corner" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    // Bottom-left corner is unambiguously bottomleft resize.
    try std.testing.expectEqual(HitTest.bottomleft, hitTest(win, .{ .x = 0, .y = 799 }, m, .normal));
}

test "top-right corner: resize wins over close in outer frame" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    try std.testing.expectEqual(HitTest.topright, hitTest(win, .{ .x = 1279, .y = 0 }, m, .normal));
    try std.testing.expectEqual(HitTest.close, hitTest(win, .{ .x = 1257, .y = 20 }, m, .normal));
    try std.testing.expectEqual(HitTest.bottomright, hitTest(win, .{ .x = 1279, .y = 799 }, m, .normal));
}

test "over close button" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const btns = captionButtonsRect(win, m, .normal);
    const cx = @divTrunc(btns.close.left + btns.close.right, 2);
    const cy = @divTrunc(btns.close.top + btns.close.bottom, 2);
    try std.testing.expectEqual(HitTest.close, hitTest(win, .{ .x = cx, .y = cy }, m, .normal));
}

test "over max button" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const btns = captionButtonsRect(win, m, .normal);
    const cx = @divTrunc(btns.max.left + btns.max.right, 2);
    const cy = @divTrunc(btns.max.top + btns.max.bottom, 2);
    try std.testing.expectEqual(HitTest.maxbutton, hitTest(win, .{ .x = cx, .y = cy }, m, .normal));
}

test "over min button" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const btns = captionButtonsRect(win, m, .normal);
    const cx = @divTrunc(btns.min.left + btns.min.right, 2);
    const cy = @divTrunc(btns.min.top + btns.min.bottom, 2);
    try std.testing.expectEqual(HitTest.minbutton, hitTest(win, .{ .x = cx, .y = cy }, m, .normal));
}

test "caption area between sysmenu and buttons" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    // Pick a point in the caption row, past sysmenu, before buttons.
    // Sysmenu occupies [0, 40) horizontally; buttons start at 1280 - 3*46 = 1142.
    // So x = 200, y = 20 should be caption.
    try std.testing.expectEqual(HitTest.caption, hitTest(win, .{ .x = 200, .y = 20 }, m, .normal));
}

test "client area below caption" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    // y = 200 is well below the caption row (40 px).
    try std.testing.expectEqual(HitTest.client, hitTest(win, .{ .x = 640, .y = 200 }, m, .normal));
}

test "bottom edge strip" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    // y = 799 (last row), x in the middle — avoids corner zones.
    try std.testing.expectEqual(HitTest.bottom, hitTest(win, .{ .x = 640, .y = 799 }, m, .normal));
}

test "maximized edge resize -> client not bottom" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    // Same position as "bottom edge strip" but maximized — edge resize
    // strips are suppressed.
    try std.testing.expectEqual(HitTest.client, hitTest(win, .{ .x = 640, .y = 799 }, m, .maximized));
}

test "sysmenu icon rect (leftmost 40px of caption row)" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    // Centre of the sysmenu rect: x = 20, y = 20.
    try std.testing.expectEqual(HitTest.sysmenu, hitTest(win, .{ .x = 20, .y = 20 }, m, .normal));
}

// -- captionButtonsRect -----------------------------------------------------

test "buttons flush right" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const btns = captionButtonsRect(win, m, .normal);
    try std.testing.expectEqual(@as(i32, 1280), btns.close.right);
}

test "buttons ordered right-to-left" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const btns = captionButtonsRect(win, m, .normal);
    try std.testing.expect(btns.close.left < win.right);
    try std.testing.expectEqual(btns.close.left, btns.max.right);
    try std.testing.expectEqual(btns.max.left, btns.min.right);
}

test "button height == metrics.caption_button_h" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
    const btns = captionButtonsRect(win, m, .normal);
    try std.testing.expectEqual(m.caption_button_h, btns.close.height());
    try std.testing.expectEqual(m.caption_button_h, btns.max.height());
    try std.testing.expectEqual(m.caption_button_h, btns.min.height());
    // All aligned at window.top.
    try std.testing.expectEqual(win.top, btns.close.top);
    try std.testing.expectEqual(win.top, btns.max.top);
    try std.testing.expectEqual(win.top, btns.min.top);
}

test "maximized buttons align to visible caption row" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 100, .top = 50, .right = 1380, .bottom = 850 };
    const btns = captionButtonsRect(win, m, .maximized);
    const expected_top = win.top + m.size_frame_y + m.padded_border;
    try std.testing.expectEqual(expected_top, btns.close.top);
    try std.testing.expectEqual(expected_top, btns.max.top);
    try std.testing.expectEqual(expected_top, btns.min.top);
}

test "maximized hit test follows shifted caption buttons" {
    const m = metricsDefault(96);
    const win = Rect{ .left = 100, .top = 50, .right = 1380, .bottom = 850 };
    const btns = captionButtonsRect(win, m, .maximized);
    const max_x = @divTrunc(btns.max.left + btns.max.right, 2);
    const max_y = @divTrunc(btns.max.top + btns.max.bottom, 2);
    const min_x = @divTrunc(btns.min.left + btns.min.right, 2);
    const min_y = @divTrunc(btns.min.top + btns.min.bottom, 2);
    try std.testing.expectEqual(HitTest.maxbutton, hitTest(win, .{ .x = max_x, .y = max_y }, m, .maximized));
    try std.testing.expectEqual(HitTest.minbutton, hitTest(win, .{ .x = min_x, .y = min_y }, m, .maximized));
}

test "maximized caption row starts below invisible top margin at 150% dpi" {
    const m = metricsDefault(144);
    const win = Rect{ .left = 100, .top = 50, .right = 1380, .bottom = 850 };
    const caption_top = win.top + m.size_frame_y + m.padded_border;

    try std.testing.expectEqual(HitTest.client, hitTest(win, .{ .x = 420, .y = caption_top - 1 }, m, .maximized));
    try std.testing.expectEqual(HitTest.caption, hitTest(win, .{ .x = 420, .y = caption_top + 1 }, m, .maximized));
}

test "max button hit test scales at 150% dpi for snap hover" {
    const m = metricsDefault(144);
    const win = Rect{ .left = 40, .top = 20, .right = 1480, .bottom = 920 };
    const btns = captionButtonsRect(win, m, .normal);
    const max_x = @divTrunc(btns.max.left + btns.max.right, 2);
    const max_y = @divTrunc(btns.max.top + btns.max.bottom, 2);

    try std.testing.expectEqual(HitTest.maxbutton, hitTest(win, .{ .x = max_x, .y = max_y }, m, .normal));
}

test "Issue150 terminal content clears independently sized integrated caption" {
    const dpis = [_]u32{ 96, 144, 192 };
    const states = [_]WindowState{ .normal, .maximized };
    const window = Rect{ .left = 100, .top = 50, .right = 1380, .bottom = 850 };

    // Keep the two metrics deliberately different. The production defaults
    // are both 40 DIP today, but terminal placement must not depend on that
    // coincidence when the painted caption is independently sized.
    const tab_height_dip: i32 = 32;

    for (dpis) |dpi| {
        const metrics = metricsDefault(@intCast(dpi));
        for (states) |state| {
            const client = calcNcClientRect(window, metrics, state);
            const caption = captionButtonsRect(window, metrics, state);
            const content_screen_top = client.top + terminalContentTop(
                scaleDim(tab_height_dip, @intCast(dpi)),
                metrics.caption_button_h,
                0,
                0,
            );
            try std.testing.expect(content_screen_top >= caption.close.bottom);
        }
    }
}

test "Issue150 runtime DPI changes recompute integrated content boundary" {
    const dpi_sequence = [_]i32{ 96, 144, 192, 144, 96 };
    const window = Rect{ .left = 100, .top = 50, .right = 1380, .bottom = 850 };

    for (dpi_sequence) |dpi| {
        const metrics = metricsDefault(@intCast(dpi));
        const client = calcNcClientRect(window, metrics, .maximized);
        const caption = captionButtonsRect(window, metrics, .maximized);
        const content_screen_top = client.top + terminalContentTop(
            scaleDim(32, dpi),
            metrics.caption_button_h,
            0,
            0,
        );
        try std.testing.expect(content_screen_top >= caption.close.bottom);
    }
}

test "Issue150 non-integrated content keeps tab and panel offsets" {
    try std.testing.expectEqual(@as(i32, 132), terminalContentTop(32, 0, 58, 42));
}

test "Issue150 panels start below an unequal integrated caption band" {
    const bands = contentBands(32, 48, 40, true, 58, 42);
    try std.testing.expectEqual(@as(i32, 48), bands.overlay_top);
    try std.testing.expectEqual(@as(i32, 106), bands.inspector_top);
    try std.testing.expectEqual(@as(i32, 148), bands.content_top);
}

test "Issue150 small clients keep content bottom after content top" {
    const bands = contentBands(32, 48, 40, true, 58, 42);
    try std.testing.expectEqual(
        bands.content_top + 1,
        contentBottom(bands.content_top, 80, 0),
    );
}
