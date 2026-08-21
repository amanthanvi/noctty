//! Geometric GDI icon primitives for the noctty Windows apprt.
//!
//! Provides a palette of small (16-24 px) geometric icons rendered via
//! Win32 GDI pens, brushes, and polygon calls.  No raster assets -- every
//! icon is drawn procedurally, eliminating the need for DPI-variant bitmaps
//! and a resource pipeline.
//!
//! Each icon has two rendering paths selected by the `is_hc` flag:
//!
//!   - **Normal mode** -- 2 px strokes, filled shapes.
//!   - **High-contrast mode** -- 1 px strokes, transparent interiors.
//!     Preserves visibility against arbitrary system background colours.
//!
//! The public entry point is `drawIcon(kind, hdc, rect, color, is_hc)`.
//! Callers supply their own DC and bounding rect; this module performs no
//! HWND creation, message handling, or resource management beyond the GDI
//! objects it creates and deletes within each draw call.
//!
//! Geometry helpers (`insetRect`, `centerSquare`, `iconContentRect`,
//! `isDrawable`) are pure functions with no Win32 dependency, tested
//! in-file via `std.testing`.

const std = @import("std");
const geometry = @import("win32_geometry.zig");
const win32_types = @import("win32_types.zig");
const sys = @import("win32/sys.zig");

// -- Public types -----------------------------------------------------------

pub const Rect = geometry.Rect;

pub const Kind = enum {
    close,
    arrow_up,
    arrow_down,
    split_h,
    split_v,
    pin,
    overflow,
    warn,
    info,
    success,
    err,
    plus,
    minimize,
    maximize,
    restore,
    search,
    settings,
    regex,
    case_sens,
    whole_word,
};

// -- Win32 GDI externs ------------------------------------------------------

const POINT = sys.POINT;

const HBRUSH = win32_types.HBRUSH;
const HDC = win32_types.HDC;
const HGDIOBJ = win32_types.HGDIOBJ;
const HPEN = win32_types.HPEN;

const PS_SOLID: i32 = 0;
const PS_NULL: i32 = 5;
const TRANSPARENT: i32 = 1;
const NULL_BRUSH_INDEX: i32 = 5;

// -- Geometry helpers (pure -- no GDI) --------------------------------------

/// Inset `r` by `padding` on all four sides.  Clamped to a zero-area
/// rect centred on the original if `padding` exceeds half the smaller
/// dimension.
pub fn insetRect(r: Rect, padding: i32) Rect {
    const w = r.width();
    const h = r.height();
    const min_dim = @min(w, h);
    const max_pad: i32 = @divTrunc(min_dim, 2);
    const p = @min(padding, max_pad);
    return .{
        .left = r.left + p,
        .top = r.top + p,
        .right = r.right - p,
        .bottom = r.bottom - p,
    };
}

/// Centre a `size x size` square inside `r`.
pub fn centerSquare(r: Rect, size: i32) Rect {
    const w = r.width();
    const h = r.height();
    const s = @min(size, @min(w, h));
    const cx = r.left + @divTrunc(w, 2);
    const cy = r.top + @divTrunc(h, 2);
    const half = @divTrunc(s, 2);
    return .{
        .left = cx - half,
        .top = cy - half,
        .right = cx - half + s,
        .bottom = cy - half + s,
    };
}

/// Content rect with proportional padding (12% of min dimension,
/// clamped to [1, 8]).
pub fn iconContentRect(r: Rect) Rect {
    const w = r.width();
    const h = r.height();
    const min_dim = @min(w, h);
    var pad: i32 = @divTrunc(min_dim * 12, 100);
    pad = @max(1, @min(8, pad));
    return insetRect(r, pad);
}

/// True when both axes are at least `min` pixels.
pub fn isDrawable(r: Rect, min: i32) bool {
    return r.width() >= min and r.height() >= min;
}

// -- Drawing internals ------------------------------------------------------

/// Select a pen + brush pair appropriate for normal / HC mode, returning
/// the previous pen and brush so the caller can restore + delete.
const GdiState = struct {
    pen: HPEN,
    brush: HGDIOBJ,
    old_pen: HGDIOBJ,
    old_brush: HGDIOBJ,
};

fn setupGdi(hdc: HDC, color: u32, is_hc: bool) ?GdiState {
    const stroke_w: i32 = if (is_hc) 1 else 2;
    const pen = sys.CreatePen(PS_SOLID, stroke_w, color) orelse return null;
    const brush = if (is_hc)
        sys.GetStockObject(NULL_BRUSH_INDEX) orelse {
            _ = sys.DeleteObject(pen);
            return null;
        }
    else
        sys.CreateSolidBrush(color) orelse {
            _ = sys.DeleteObject(pen);
            return null;
        };
    const old_pen = sys.SelectObject(hdc, pen) orelse {
        _ = sys.DeleteObject(pen);
        if (!is_hc) _ = sys.DeleteObject(brush);
        return null;
    };
    const old_brush = sys.SelectObject(hdc, brush) orelse {
        _ = sys.SelectObject(hdc, old_pen);
        _ = sys.DeleteObject(pen);
        if (!is_hc) _ = sys.DeleteObject(brush);
        return null;
    };
    return .{ .pen = pen, .brush = brush, .old_pen = old_pen, .old_brush = old_brush };
}

fn teardownGdi(hdc: HDC, gs: GdiState, is_hc: bool) void {
    _ = sys.SelectObject(hdc, gs.old_brush);
    _ = sys.SelectObject(hdc, gs.old_pen);
    if (!is_hc) _ = sys.DeleteObject(gs.brush);
    _ = sys.DeleteObject(gs.pen);
}

fn line(hdc: HDC, x1: i32, y1: i32, x2: i32, y2: i32) void {
    _ = sys.MoveToEx(hdc, x1, y1, null);
    _ = sys.LineTo(hdc, x2, y2);
}

// -- Per-icon draw routines -------------------------------------------------

fn drawClose(hdc: HDC, r: Rect) void {
    line(hdc, r.left, r.top, r.right, r.bottom);
    line(hdc, r.right, r.top, r.left, r.bottom);
}

const ArrowDir = enum { up, down };

fn drawArrow(hdc: HDC, r: Rect, dir: ArrowDir) void {
    const cx = r.left + @divTrunc(r.width(), 2);
    switch (dir) {
        .up => {
            line(hdc, r.left, r.bottom - 1, cx, r.top);
            line(hdc, cx, r.top, r.right, r.bottom - 1);
        },
        .down => {
            line(hdc, r.left, r.top, cx, r.bottom - 1);
            line(hdc, cx, r.bottom - 1, r.right, r.top);
        },
    }
}

fn drawArrowUp(hdc: HDC, r: Rect) void {
    drawArrow(hdc, r, .up);
}

fn drawArrowDown(hdc: HDC, r: Rect) void {
    drawArrow(hdc, r, .down);
}

fn drawSplitH(hdc: HDC, r: Rect) void {
    const mid = r.top + @divTrunc(r.height(), 2);
    _ = sys.Rectangle(hdc, r.left, r.top, r.right, mid - 1);
    _ = sys.Rectangle(hdc, r.left, mid + 1, r.right, r.bottom);
}

fn drawSplitV(hdc: HDC, r: Rect) void {
    const mid = r.left + @divTrunc(r.width(), 2);
    _ = sys.Rectangle(hdc, r.left, r.top, mid - 1, r.bottom);
    _ = sys.Rectangle(hdc, mid + 1, r.top, r.right, r.bottom);
}

fn drawPin(hdc: HDC, r: Rect) void {
    const cx = r.left + @divTrunc(r.width(), 2);
    const head_r = @max(@divTrunc(r.width(), 4), 2);
    // head circle
    _ = sys.Ellipse(hdc, cx - head_r, r.top, cx + head_r, r.top + head_r * 2);
    // shaft
    line(hdc, cx, r.top + head_r * 2, cx, r.bottom);
}

fn drawOverflow(hdc: HDC, r: Rect) void {
    const cx = r.left + @divTrunc(r.width(), 2);
    const gap = @max(@divTrunc(r.height(), 4), 2);
    const arm = @divTrunc(r.width(), 3);
    var y = r.top + gap;
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        line(hdc, cx - arm, y, cx, y + gap);
        line(hdc, cx, y + gap, cx + arm, y);
        y += gap + 1;
    }
}

fn drawWarn(hdc: HDC, r: Rect) void {
    const cx = r.left + @divTrunc(r.width(), 2);
    var pts = [3]POINT{
        .{ .x = cx, .y = r.top },
        .{ .x = r.left, .y = r.bottom },
        .{ .x = r.right, .y = r.bottom },
    };
    _ = sys.Polygon(hdc, &pts, 3);
    // exclamation mark: vertical bar + dot
    const bang_top = r.top + @divTrunc(r.height(), 3);
    const bang_bot = r.bottom - @divTrunc(r.height(), 4);
    line(hdc, cx, bang_top, cx, bang_bot);
    const dot_y = r.bottom - @divTrunc(r.height(), 8);
    _ = sys.Ellipse(hdc, cx - 1, dot_y - 1, cx + 1, dot_y + 1);
}

fn drawCircleGlyph(hdc: HDC, r: Rect, comptime glyph: enum { info, success, err_x }) void {
    _ = sys.Ellipse(hdc, r.left, r.top, r.right, r.bottom);
    const cx = r.left + @divTrunc(r.width(), 2);
    const cy = r.top + @divTrunc(r.height(), 2);
    const qh = @divTrunc(r.height(), 4);
    switch (glyph) {
        .info => {
            // dot
            _ = sys.Ellipse(hdc, cx - 1, cy - qh - 1, cx + 1, cy - qh + 1);
            // vertical stroke
            line(hdc, cx, cy - qh + 3, cx, cy + qh);
        },
        .success => {
            // check mark: two line segments
            line(hdc, cx - qh, cy, cx - @divTrunc(qh, 3), cy + qh);
            line(hdc, cx - @divTrunc(qh, 3), cy + qh, cx + qh, cy - qh);
        },
        .err_x => {
            // small X inside circle
            line(hdc, cx - qh, cy - qh, cx + qh, cy + qh);
            line(hdc, cx + qh, cy - qh, cx - qh, cy + qh);
        },
    }
}

fn drawPlus(hdc: HDC, r: Rect) void {
    const cx = r.left + @divTrunc(r.width(), 2);
    const cy = r.top + @divTrunc(r.height(), 2);
    line(hdc, cx, r.top, cx, r.bottom);
    line(hdc, r.left, cy, r.right, cy);
}

fn drawMinimize(hdc: HDC, r: Rect) void {
    const cy = r.top + @divTrunc(r.height(), 2);
    line(hdc, r.left, cy, r.right, cy);
}

fn drawMaximize(hdc: HDC, r: Rect) void {
    // `setupGdi` selected a SOLID brush of the glyph colour so
    // `Rectangle` would FILL the rect (producing a solid-coloured
    // block, which the user sees as a "blank button"). Swap to the
    // stock NULL brush while we draw so only the outline renders.
    const null_brush = sys.GetStockObject(NULL_BRUSH_INDEX) orelse return;
    const saved = sys.SelectObject(hdc, null_brush) orelse return;
    defer _ = sys.SelectObject(hdc, saved);
    _ = sys.Rectangle(hdc, r.left, r.top, r.right, r.bottom);
}

fn drawRestore(hdc: HDC, r: Rect) void {
    const null_brush = sys.GetStockObject(NULL_BRUSH_INDEX) orelse return;
    const saved = sys.SelectObject(hdc, null_brush) orelse return;
    defer _ = sys.SelectObject(hdc, saved);
    const off = @max(@divTrunc(r.width(), 4), 2);
    // back square (shifted right + up)
    _ = sys.Rectangle(hdc, r.left + off, r.top, r.right, r.bottom - off);
    // front square (shifted left + down)
    _ = sys.Rectangle(hdc, r.left, r.top + off, r.right - off, r.bottom);
}

fn drawSearch(hdc: HDC, r: Rect) void {
    const sz = @min(r.width(), r.height());
    const lens_r = @divTrunc(sz * 5, 12);
    const cx = r.left + lens_r;
    const cy = r.top + lens_r;
    _ = sys.Ellipse(hdc, cx - lens_r, cy - lens_r, cx + lens_r, cy + lens_r);
    // handle: diagonal from bottom-right of circle toward bottom-right corner
    const hx = cx + @divTrunc(lens_r * 7, 10);
    const hy = cy + @divTrunc(lens_r * 7, 10);
    line(hdc, hx, hy, r.right, r.bottom);
}

fn drawSettings(hdc: HDC, r: Rect) void {
    const cx = r.left + @divTrunc(r.width(), 2);
    const cy = r.top + @divTrunc(r.height(), 2);
    const outer = @divTrunc(@min(r.width(), r.height()), 2);
    const inner = @divTrunc(outer, 3);
    // centre dot
    _ = sys.Ellipse(hdc, cx - inner, cy - inner, cx + inner, cy + inner);
    // six teeth at 60-degree intervals, rendered as short radial lines
    const angles = [6]struct { dx: i32, dy: i32 }{
        .{ .dx = 0, .dy = -100 },
        .{ .dx = 87, .dy = -50 },
        .{ .dx = 87, .dy = 50 },
        .{ .dx = 0, .dy = 100 },
        .{ .dx = -87, .dy = 50 },
        .{ .dx = -87, .dy = -50 },
    };
    for (angles) |a| {
        const ix = cx + @divTrunc(a.dx * inner, 100);
        const iy = cy + @divTrunc(a.dy * inner, 100);
        const ox = cx + @divTrunc(a.dx * outer, 100);
        const oy = cy + @divTrunc(a.dy * outer, 100);
        line(hdc, ix, iy, ox, oy);
    }
}

/// Regex (.*), case-sensitivity (Aa), and whole-word ("ab") icons are
/// literal text glyphs.  We render them with simple geometric line
/// segments rather than loading a font via DrawTextW.  This keeps the
/// module free of font-selection complexity and avoids GDI font caching
/// concerns.  The glyphs are stylised approximations, not typographic.
fn drawRegex(hdc: HDC, r: Rect) void {
    // dot
    const dot_y = r.bottom - 2;
    _ = sys.Ellipse(hdc, r.left, dot_y - 2, r.left + 3, dot_y + 1);
    // asterisk: two crossing lines
    const sx = r.left + @divTrunc(r.width(), 3);
    const mid_y = r.top + @divTrunc(r.height(), 2);
    line(hdc, sx, r.top + 1, sx, r.bottom - 1);
    line(hdc, sx - 3, mid_y - 3, sx + 3, mid_y + 3);
    line(hdc, sx - 3, mid_y + 3, sx + 3, mid_y - 3);
}

fn drawCaseSens(hdc: HDC, r: Rect) void {
    // Capital A
    const ax = r.left;
    const amid = ax + @divTrunc(r.width(), 4);
    line(hdc, ax, r.bottom, amid, r.top);
    line(hdc, amid, r.top, ax + @divTrunc(r.width(), 2), r.bottom);
    const bar_y = r.top + @divTrunc(r.height() * 3, 5);
    line(hdc, ax + @divTrunc(r.width(), 8), bar_y, ax + @divTrunc(r.width() * 3, 8), bar_y);
    // lowercase a: small circle + vertical stroke on right half
    const arx = r.left + @divTrunc(r.width() * 5, 8);
    const ar = @divTrunc(r.width(), 6);
    const acy = r.top + @divTrunc(r.height() * 2, 3);
    _ = sys.Ellipse(hdc, arx - ar, acy - ar, arx + ar, acy + ar);
    line(hdc, arx + ar, r.top + @divTrunc(r.height(), 3), arx + ar, r.bottom);
}

fn drawWholeWord(hdc: HDC, r: Rect) void {
    // "a": small circle + vertical stroke
    const ar = @divTrunc(r.width(), 6);
    const acx = r.left + @divTrunc(r.width(), 4);
    const acy = r.top + @divTrunc(r.height() * 2, 3);
    _ = sys.Ellipse(hdc, acx - ar, acy - ar, acx + ar, acy + ar);
    line(hdc, acx + ar, r.top + @divTrunc(r.height(), 3), acx + ar, r.bottom);
    // "b": vertical stroke + circle on the right
    const bx = r.left + @divTrunc(r.width() * 3, 5);
    line(hdc, bx, r.top, bx, r.bottom);
    const bcx = bx + ar;
    _ = sys.Ellipse(hdc, bcx - ar, acy - ar, bcx + ar, acy + ar);
}

// -- Public draw entry point ------------------------------------------------

/// Draw the icon of `kind` centred in `rect`, painted in `color`.
/// `is_hc` selects 1 px outline-only strokes (high-contrast) vs 2 px
/// filled shapes (normal).  Safe to call with a zero or degenerate rect.
pub fn drawIcon(
    kind: Kind,
    hdc: *anyopaque,
    rect: Rect,
    color: u32,
    is_hc: bool,
) void {
    const content = iconContentRect(rect);
    if (!isDrawable(content, 4)) return;

    _ = sys.SetBkMode(hdc, TRANSPARENT);

    const gs = setupGdi(hdc, color, is_hc) orelse return;
    defer teardownGdi(hdc, gs, is_hc);

    switch (kind) {
        .close => drawClose(hdc, content),
        .arrow_up => drawArrowUp(hdc, content),
        .arrow_down => drawArrowDown(hdc, content),
        .split_h => drawSplitH(hdc, content),
        .split_v => drawSplitV(hdc, content),
        .pin => drawPin(hdc, content),
        .overflow => drawOverflow(hdc, content),
        .warn => drawWarn(hdc, content),
        .info => drawCircleGlyph(hdc, content, .info),
        .success => drawCircleGlyph(hdc, content, .success),
        .err => drawCircleGlyph(hdc, content, .err_x),
        .plus => drawPlus(hdc, content),
        .minimize => drawMinimize(hdc, content),
        .maximize => drawMaximize(hdc, content),
        .restore => drawRestore(hdc, content),
        .search => drawSearch(hdc, content),
        .settings => drawSettings(hdc, content),
        .regex => drawRegex(hdc, content),
        .case_sens => drawCaseSens(hdc, content),
        .whole_word => drawWholeWord(hdc, content),
    }
}

// -- Tests (geometry only -- no DC) -----------------------------------------

test "insetRect: normal inset" {
    const r = Rect{ .left = 0, .top = 0, .right = 100, .bottom = 100 };
    const got = insetRect(r, 10);
    try std.testing.expectEqual(@as(i32, 10), got.left);
    try std.testing.expectEqual(@as(i32, 10), got.top);
    try std.testing.expectEqual(@as(i32, 90), got.right);
    try std.testing.expectEqual(@as(i32, 90), got.bottom);
}
test "insetRect: oversized inset clamps to centre" {
    const r = Rect{ .left = 0, .top = 0, .right = 20, .bottom = 20 };
    const got = insetRect(r, 999);
    // max_pad = 10, so the rect collapses to the centre point
    try std.testing.expectEqual(@as(i32, 10), got.left);
    try std.testing.expectEqual(@as(i32, 10), got.top);
    try std.testing.expectEqual(@as(i32, 10), got.right);
    try std.testing.expectEqual(@as(i32, 10), got.bottom);
}
test "centerSquare: 20x20 in 100x50" {
    const r = Rect{ .left = 0, .top = 0, .right = 100, .bottom = 50 };
    const got = centerSquare(r, 20);
    try std.testing.expectEqual(@as(i32, 40), got.left);
    try std.testing.expectEqual(@as(i32, 15), got.top);
    try std.testing.expectEqual(@as(i32, 60), got.right);
    try std.testing.expectEqual(@as(i32, 35), got.bottom);
}
test "centerSquare: requested size larger than rect" {
    const r = Rect{ .left = 10, .top = 10, .right = 20, .bottom = 20 };
    const got = centerSquare(r, 50);
    // clamped to 10x10 (the rect's own size)
    try std.testing.expectEqual(@as(i32, 10), got.left);
    try std.testing.expectEqual(@as(i32, 10), got.top);
    try std.testing.expectEqual(@as(i32, 20), got.right);
    try std.testing.expectEqual(@as(i32, 20), got.bottom);
}

test "iconContentRect: 100x100" {
    const r = Rect{ .left = 0, .top = 0, .right = 100, .bottom = 100 };
    const got = iconContentRect(r);
    // 12% of 100 = 12 -> clamped to 8
    try std.testing.expectEqual(@as(i32, 8), got.left);
    try std.testing.expectEqual(@as(i32, 8), got.top);
    try std.testing.expectEqual(@as(i32, 92), got.right);
    try std.testing.expectEqual(@as(i32, 92), got.bottom);
}

test "iconContentRect: small rect gets 1 px minimum" {
    const r = Rect{ .left = 0, .top = 0, .right = 6, .bottom = 6 };
    const got = iconContentRect(r);
    // 12% of 6 = 0 -> clamped to 1
    try std.testing.expectEqual(@as(i32, 1), got.left);
    try std.testing.expectEqual(@as(i32, 1), got.top);
    try std.testing.expectEqual(@as(i32, 5), got.right);
    try std.testing.expectEqual(@as(i32, 5), got.bottom);
}

test "isDrawable: too small" {
    const r = Rect{ .left = 0, .top = 0, .right = 5, .bottom = 5 };
    try std.testing.expect(!isDrawable(r, 10));
}

test "isDrawable: exact boundary" {
    const r = Rect{ .left = 0, .top = 0, .right = 10, .bottom = 10 };
    try std.testing.expect(isDrawable(r, 10));
}

test "isDrawable: comfortable" {
    const r = Rect{ .left = 0, .top = 0, .right = 50, .bottom = 50 };
    try std.testing.expect(isDrawable(r, 4));
}

test "Rect width and height" {
    const r = Rect{ .left = 5, .top = 10, .right = 25, .bottom = 30 };
    try std.testing.expectEqual(@as(i32, 20), r.width());
    try std.testing.expectEqual(@as(i32, 20), r.height());
}
