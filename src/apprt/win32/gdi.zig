//! Host-independent Win32 GDI paint primitives.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("consts.zig");
const sys = @import("sys.zig");
const win32_types = @import("../win32_types.zig");

const HDC = win32_types.HDC;
const RECT = sys.RECT;
const UINT = win32_types.UINT;

/// Linear-interpolate two `COLORREF`-shaped values (`0x00BBGGRR` on
/// Windows GDI) by `alpha` in [0, 1]. `alpha = 0` returns `a`,
/// `alpha = 1` returns `b`. Used for pre-composited alpha on paths
/// where GDI cannot render RGBA directly.
pub fn blendColorRGB(a: u32, b: u32, alpha: f32) u32 {
    const t: f32 = std.math.clamp(alpha, 0.0, 1.0);
    const inv: f32 = 1.0 - t;
    const ar: u32 = a & 0xFF;
    const ag: u32 = (a >> 8) & 0xFF;
    const ab: u32 = (a >> 16) & 0xFF;
    const br: u32 = b & 0xFF;
    const bg: u32 = (b >> 8) & 0xFF;
    const bb: u32 = (b >> 16) & 0xFF;
    const rr: u32 = @intFromFloat(@as(f32, @floatFromInt(ar)) * inv + @as(f32, @floatFromInt(br)) * t);
    const gg: u32 = @intFromFloat(@as(f32, @floatFromInt(ag)) * inv + @as(f32, @floatFromInt(bg)) * t);
    const bb2: u32 = @intFromFloat(@as(f32, @floatFromInt(ab)) * inv + @as(f32, @floatFromInt(bb)) * t);
    return (bb2 << 16) | (gg << 8) | rr;
}

pub fn fillSolidRect(hdc: HDC, rect: RECT, color: u32) void {
    const brush = sys.GetStockObject(c.DC_BRUSH) orelse return;
    _ = sys.SetDCBrushColor(hdc, color);
    _ = sys.FillRect(hdc, &rect, brush);
}

pub fn drawRectBorder(hdc: HDC, rect: RECT, color: u32, thickness: i32) void {
    if (rect.right <= rect.left or rect.bottom <= rect.top or thickness <= 0) return;
    const stroke = @min(thickness, @min(rect.right - rect.left, rect.bottom - rect.top));
    fillSolidRect(hdc, .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + stroke }, color);
    fillSolidRect(hdc, .{ .left = rect.left, .top = rect.bottom - stroke, .right = rect.right, .bottom = rect.bottom }, color);
    fillSolidRect(hdc, .{ .left = rect.left, .top = rect.top + stroke, .right = rect.left + stroke, .bottom = rect.bottom - stroke }, color);
    fillSolidRect(hdc, .{ .left = rect.right - stroke, .top = rect.top + stroke, .right = rect.right, .bottom = rect.bottom - stroke }, color);
}

pub fn textOutWz(hdc: HDC, x: i32, y: i32, text: [:0]const u16) void {
    const len = utf16GdiTextLen(text);
    if (len == 0) return;
    _ = sys.TextOutW(hdc, x, y, text.ptr, len);
}

pub fn drawTextWz(hdc: HDC, text: [:0]const u16, rect: *RECT, format: UINT) void {
    const len = utf16GdiTextLen(text);
    if (len == 0) return;
    _ = sys.DrawTextW(hdc, text.ptr, len, rect, format);
}

pub fn drawRoundedRect(hdc: HDC, rect: RECT, bg: u32, border: u32, radius: i32) void {
    const stock_brush = sys.GetStockObject(c.DC_BRUSH) orelse return;
    const stock_pen = sys.GetStockObject(c.DC_PEN) orelse return;
    _ = sys.SetDCBrushColor(hdc, bg);
    _ = sys.SetDCPenColor(hdc, border);
    const old_brush = sys.SelectObject(hdc, stock_brush);
    const old_pen = sys.SelectObject(hdc, stock_pen);
    // GDI strokes are centered; the inset prevents clipping at the edges.
    _ = sys.RoundRect(hdc, rect.left + 1, rect.top + 1, rect.right - 1, rect.bottom - 1, radius, radius);
    _ = sys.SelectObject(hdc, old_pen);
    _ = sys.SelectObject(hdc, old_brush);
}

/// The small status badge a tab draws for its programs (OSC 7501). Every
/// badge has its own shape, so the state still reads in high contrast,
/// where all of them are drawn in the text color.
pub const StatusBadge = union(enum) {
    /// Working: a ring. With a progress percentage, a bright arc runs
    /// clockwise from the top over a muted track; without one, the whole
    /// ring is bright.
    ring: ?u8,
    /// Blocked on the user: a filled disc.
    disc,
    /// Done: a check mark.
    check,
    /// Failed: a cross.
    cross,
};

const NULL_BRUSH: i32 = 5;
const NULL_PEN: i32 = 8;
const PS_SOLID: i32 = 0;

/// Draw `badge` inside the square `rect` in `color`, with lines `stroke`
/// pixels wide. A progress ring's track is `color` faded into `bg`.
pub fn drawStatusBadge(
    hdc: HDC,
    rect: RECT,
    badge: StatusBadge,
    color: u32,
    bg: u32,
    stroke: i32,
) void {
    const size = rect.right - rect.left;
    if (size < 4 or rect.bottom - rect.top != size) return;
    const pen = sys.CreatePen(PS_SOLID, stroke, color) orelse return;
    defer _ = sys.DeleteObject(pen);
    const brush = sys.GetStockObject(c.DC_BRUSH) orelse return;
    const no_brush = sys.GetStockObject(NULL_BRUSH) orelse return;
    const no_pen = sys.GetStockObject(NULL_PEN) orelse return;
    _ = sys.SetDCBrushColor(hdc, color);
    const old_pen = sys.SelectObject(hdc, pen);
    defer _ = sys.SelectObject(hdc, old_pen);
    const old_brush = sys.SelectObject(hdc, no_brush);
    defer _ = sys.SelectObject(hdc, old_brush);

    const l = rect.left;
    const t = rect.top;
    switch (badge) {
        .ring => |progress| {
            // GDI centers a pen on the outline, so inset by half a stroke
            // to keep the ring inside the badge.
            const half = @divTrunc(stroke, 2);
            const ring: RECT = .{
                .left = l + half,
                .top = t + half,
                .right = rect.right - half,
                .bottom = rect.bottom - half,
            };
            const percent = progress orelse {
                _ = sys.Ellipse(hdc, ring.left, ring.top, ring.right, ring.bottom);
                return;
            };
            if (percent < 100) {
                const track = sys.CreatePen(PS_SOLID, stroke, blendColorRGB(bg, color, 0.35)) orelse return;
                defer _ = sys.DeleteObject(track);
                _ = sys.SelectObject(hdc, track);
                _ = sys.Ellipse(hdc, ring.left, ring.top, ring.right, ring.bottom);
                _ = sys.SelectObject(hdc, pen);
                if (percent == 0) return;
                const radials = progressArcRadials(ring, percent);
                _ = sys.Arc(
                    hdc,
                    ring.left,
                    ring.top,
                    ring.right,
                    ring.bottom,
                    radials.start.x,
                    radials.start.y,
                    radials.end.x,
                    radials.end.y,
                );
                return;
            }
            _ = sys.Ellipse(hdc, ring.left, ring.top, ring.right, ring.bottom);
        },
        .disc => {
            _ = sys.SelectObject(hdc, no_pen);
            _ = sys.SelectObject(hdc, brush);
            // Without a pen GDI leaves the right and bottom edges out.
            _ = sys.Ellipse(hdc, l, t, rect.right + 1, rect.bottom + 1);
        },
        .check => {
            const s: f32 = @floatFromInt(size);
            line(hdc, l + px(s, 0.12), t + px(s, 0.52), l + px(s, 0.40), t + px(s, 0.80));
            line(hdc, l + px(s, 0.40), t + px(s, 0.80), l + px(s, 0.90), t + px(s, 0.22));
        },
        .cross => {
            const near = px(@floatFromInt(size), 0.18);
            const far = size - near;
            line(hdc, l + near, t + near, l + far, t + far);
            line(hdc, l + far, t + near, l + near, t + far);
        },
    }
}

fn px(size: f32, fraction: f32) i32 {
    return @intFromFloat(@round(size * fraction));
}

fn line(hdc: HDC, x1: i32, y1: i32, x2: i32, y2: i32) void {
    _ = sys.MoveToEx(hdc, x1, y1, null);
    _ = sys.LineTo(hdc, x2, y2);
}

const ArcRadials = struct {
    start: sys.POINT,
    end: sys.POINT,
};

/// The radial end points `Arc` takes for an arc that starts at the top of
/// `rect` and sweeps `percent` of the circle clockwise. GDI draws arcs
/// counterclockwise from the first point to the second, so the arc starts
/// where the clockwise sweep ends and ends at the top.
fn progressArcRadials(rect: RECT, percent: u8) ArcRadials {
    const cx: f32 = @as(f32, @floatFromInt(rect.left + rect.right)) / 2;
    const cy: f32 = @as(f32, @floatFromInt(rect.top + rect.bottom)) / 2;
    const r: f32 = @floatFromInt(rect.right - rect.left);
    const sweep = std.math.tau * @as(f32, @floatFromInt(percent)) / 100;
    const angle = std.math.pi / 2.0 - sweep;
    return .{
        .start = .{
            .x = @intFromFloat(@round(cx + r * @cos(angle))),
            .y = @intFromFloat(@round(cy - r * @sin(angle))),
        },
        .end = .{ .x = @intFromFloat(@round(cx)), .y = @intFromFloat(@round(cy - r)) },
    };
}

pub fn paintRectVisible(hdc: HDC, paint_rect: RECT, rect: RECT) bool {
    if (rect.right <= rect.left or rect.bottom <= rect.top) return false;
    if (!rectIntersects(paint_rect, rect)) return false;
    return sys.RectVisible(hdc, &rect) != 0;
}

fn rectIntersects(a: RECT, b: RECT) bool {
    return a.left < b.right and
        a.right > b.left and
        a.top < b.bottom and
        a.bottom > b.top;
}

fn utf16GdiTextLen(text: [:0]const u16) i32 {
    const max_len: usize = @intCast(std.math.maxInt(i32));
    return @intCast(@min(text.len, max_len));
}

test "win32 rectIntersects only trips on positive overlap" {
    const testing = std.testing;

    try testing.expect(rectIntersects(
        .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
        .{ .left = 5, .top = 5, .right = 15, .bottom = 15 },
    ));
    try testing.expect(!rectIntersects(
        .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
        .{ .left = 10, .top = 0, .right = 20, .bottom = 10 },
    ));
    try testing.expect(!rectIntersects(
        .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
        .{ .left = 0, .top = 10, .right = 10, .bottom = 20 },
    ));
}

test "progress arc starts at the top and sweeps clockwise" {
    const testing = std.testing;
    const rect: RECT = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 };

    // The arc always ends at the top.
    const quarter = progressArcRadials(rect, 25);
    try testing.expectEqual(@as(i32, 10), quarter.end.x);
    try testing.expectEqual(@as(i32, -10), quarter.end.y);
    // A quarter sweeps to 3 o'clock.
    try testing.expectEqual(@as(i32, 30), quarter.start.x);
    try testing.expectEqual(@as(i32, 10), quarter.start.y);
    // Half sweeps to 6 o'clock, three quarters to 9 o'clock.
    const half = progressArcRadials(rect, 50);
    try testing.expectEqual(@as(i32, 10), half.start.x);
    try testing.expectEqual(@as(i32, 30), half.start.y);
    const three_quarters = progressArcRadials(rect, 75);
    try testing.expectEqual(@as(i32, -10), three_quarters.start.x);
    try testing.expectEqual(@as(i32, 10), three_quarters.start.y);
}

test "win32 GDI text length accepts empty sentinel slices" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const empty = try std.unicode.utf8ToUtf16LeAllocZ(alloc, "");
    defer alloc.free(empty);
    try std.testing.expectEqual(@as(i32, 0), utf16GdiTextLen(empty));

    const confirm = try std.unicode.utf8ToUtf16LeAllocZ(alloc, "Confirm");
    defer alloc.free(confirm);
    try std.testing.expectEqual(@as(i32, 7), utf16GdiTextLen(confirm));
}
