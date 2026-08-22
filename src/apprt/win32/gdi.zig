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
