//! Native child-control plumbing shared by the facade and the modules under
//! win32/: window user data, the last Win32 error, the placement cache, cached
//! window text and EDIT selections in UTF-8 offsets. A leaf by its own imports:
//! none of them is the facade or a file that owns its objects. What they import
//! in turn is not a leaf (chrome_layout imports labels, which imports
//! ../../apprt.zig and so the facade).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const chrome_layout = @import("chrome_layout.zig");
const c = @import("consts.zig");
const paint_text = @import("text.zig");
const sys = @import("sys.zig");
const win32_types = @import("../win32_types.zig");
const win32_uia = @import("../win32_uia/mod.zig");

const BOOL = win32_types.BOOL;
const HWND = win32_types.HWND;
const LONG_PTR = win32_types.LONG_PTR;
const LPARAM = win32_types.LPARAM;
const POINT = sys.POINT;
const RECT = sys.RECT;
const appendOwnedString = paint_text.appendOwnedString;
const childRect = chrome_layout.childRect;
const ownedStringEquals = paint_text.ownedStringEquals;
const rectEquals = chrome_layout.rectEquals;

pub fn lastError() std.posix.UnexpectedError {
    return windows.unexpectedError(windows.kernel32.GetLastError());
}

pub fn setWindowData(hwnd: HWND, ptr: ?*anyopaque) void {
    const raw: LONG_PTR = if (ptr) |value|
        @intCast(@intFromPtr(value))
    else
        0;
    _ = sys.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, raw);
}

pub fn windowData(comptime T: type, hwnd: HWND) ?*T {
    const raw = sys.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(raw)));
}

pub const prompt_label_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
pub const prompt_edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
pub const prompt_button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");

pub const ChildPlacement = struct {
    hwnd: ?HWND = null,
    rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    rect_known: bool = false,
    visible: bool = false,
    visible_known: bool = false,
};

fn syncChildPlacementTarget(placement: *ChildPlacement, hwnd: HWND) void {
    if (placement.hwnd == null or placement.hwnd.? != hwnd) {
        placement.* = .{ .hwnd = hwnd };
    }
}

pub fn applyChildRect(hwnd: HWND, placement: *ChildPlacement, rect: RECT) bool {
    syncChildPlacementTarget(placement, hwnd);
    if (placement.rect_known and rectEquals(placement.rect, rect)) return false;
    _ = sys.MoveWindow(
        hwnd,
        rect.left,
        rect.top,
        @max(0, rect.right - rect.left),
        @max(0, rect.bottom - rect.top),
        0,
    );
    placement.rect = rect;
    placement.rect_known = true;
    return true;
}

/// `applyChildRect` for chrome children, which have to repaint themselves
/// after a move.
///
/// `MoveWindow` runs with `bRepaint = FALSE` so a relayout never forces a
/// paint of the terminal surfaces, and the host carries `WS_CLIPCHILDREN`, so
/// the parent's own chrome-band repaint is clipped out of every child rect. A
/// moved chrome child therefore keeps whatever pixels happened to be on screen
/// at its new position -- the strip background, or the stale image of the
/// button that used to sit there -- until something else invalidates it.
///
/// `Host.layout` covers the moves it makes itself via
/// `invalidateChromeChildPaint`, but `Host.refreshChrome` and
/// `Surface.refreshWindowTitle` also relayout the tab strip through
/// `syncTabButtons` and invalidate only the parent. Whichever of them runs
/// first after a tab is inserted does the move, and the placement cache then
/// makes the miss permanent: the next `layout` sees no rect change and skips
/// the child invalidation, so the button stays unpainted at its new slot while
/// its old image survives underneath the neighbour that took its place.
///
/// Tying the invalidation to the move keeps correctness from depending on
/// which caller happens to relayout the strip first. It costs one
/// `InvalidateRect` per child that actually moved, so idle repaints are
/// unaffected.
pub fn applyChromeChildRect(hwnd: HWND, placement: *ChildPlacement, rect: RECT) bool {
    if (!applyChildRect(hwnd, placement, rect)) return false;
    // Chrome children are owner-drawn over their full client area, so the
    // erase pass would only add a flash of background under the new paint.
    _ = sys.InvalidateRect(hwnd, null, 0);
    return true;
}

pub fn applyChildVisibility(hwnd: HWND, placement: *ChildPlacement, visible: bool) bool {
    syncChildPlacementTarget(placement, hwnd);
    if (placement.visible_known and placement.visible == visible) return false;
    _ = sys.ShowWindow(hwnd, if (visible) c.SW_SHOW else c.SW_HIDE);
    placement.visible = visible;
    placement.visible_known = true;
    return true;
}

pub fn syncWindowTextUtf8Cached(
    alloc: Allocator,
    hwnd: HWND,
    cached: *?[:0]const u8,
    value: []const u8,
) !bool {
    if (ownedStringEquals(cached.*, value)) return false;
    try appendOwnedString(alloc, cached, value);
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value);
    defer alloc.free(value_w);
    _ = sys.SetWindowTextW(hwnd, value_w.ptr);
    return true;
}

/// `syncWindowTextUtf8Cached`, but `cached` changes after `SetWindowTextW`
/// rather than before. Its one caller is `Host.setOverlayEditText`, and a
/// program write to the overlay EDIT goes through that wrapper, not here:
/// `SetWindowTextW` fires `EN_CHANGE` synchronously, and only the wrapper sets
/// `suppress_edit_events` across it (the 2026-04-17 "Palette EN_CHANGE
/// re-entry guard" entry in docs/agents/log/chrome-overlays.md).
pub fn syncWindowTextUtf8CachedAfterSet(
    alloc: Allocator,
    hwnd: HWND,
    cached: *?[:0]const u8,
    value: []const u8,
) !bool {
    if (ownedStringEquals(cached.*, value)) return false;
    const value_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value);
    defer alloc.free(value_w);
    _ = sys.SetWindowTextW(hwnd, value_w.ptr);
    try appendOwnedString(alloc, cached, value);
    return true;
}

pub fn readWindowTextUtf8Alloc(alloc: Allocator, hwnd: HWND) ![:0]u8 {
    const len_w = sys.GetWindowTextLengthW(hwnd);
    if (len_w <= 0) return try alloc.dupeZ(u8, "");

    const needed: usize = @intCast(len_w + 1);
    var buf_w = try alloc.alloc(u16, needed);
    defer alloc.free(buf_w);
    buf_w[needed - 1] = 0;

    const copied = sys.GetWindowTextW(hwnd, buf_w.ptr, @intCast(needed));
    if (copied < 0) return lastError();

    return try std.unicode.utf16LeToUtf8AllocZ(alloc, buf_w[0..@intCast(copied)]);
}

fn utf16CodeUnitOffsetToUtf8ByteOffset(text: []const u8, target_units: usize) usize {
    var byte_offset: usize = 0;
    var utf16_units: usize = 0;
    while (byte_offset < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch return byte_offset;
        const end = byte_offset + @as(usize, sequence_len);
        if (end > text.len) return byte_offset;
        const codepoint = std.unicode.utf8Decode(text[byte_offset..end]) catch return byte_offset;
        const codepoint_units: usize = if (codepoint > 0xFFFF) 2 else 1;
        if (utf16_units + codepoint_units > target_units) return byte_offset;
        utf16_units += codepoint_units;
        byte_offset = end;
        if (utf16_units == target_units) return byte_offset;
    }
    return text.len;
}

fn utf8ByteOffsetToUtf16CodeUnitOffset(text: []const u8, target_bytes: usize) usize {
    const target = @min(target_bytes, text.len);
    var byte_offset: usize = 0;
    var utf16_units: usize = 0;
    while (byte_offset < target) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[byte_offset]) catch return utf16_units;
        const end = byte_offset + @as(usize, sequence_len);
        if (end > target or end > text.len) return utf16_units;
        const codepoint = std.unicode.utf8Decode(text[byte_offset..end]) catch return utf16_units;
        utf16_units += if (codepoint > 0xFFFF) 2 else 1;
        byte_offset = end;
    }
    return utf16_units;
}

test "Win32 edit offsets preserve supplementary Unicode boundaries" {
    const text = "a🚀b";
    const utf16_offsets = [_]usize{ 0, 1, 3, 4 };
    const utf8_offsets = [_]usize{ 0, 1, 5, 6 };
    for (utf16_offsets, utf8_offsets) |utf16_offset, utf8_offset| {
        try std.testing.expectEqual(
            utf8_offset,
            utf16CodeUnitOffsetToUtf8ByteOffset(text, utf16_offset),
        );
        try std.testing.expectEqual(
            utf16_offset,
            utf8ByteOffsetToUtf16CodeUnitOffset(text, utf8_offset),
        );
    }
    try std.testing.expectEqual(@as(usize, 1), utf16CodeUnitOffsetToUtf8ByteOffset(text, 2));
    try std.testing.expectEqual(@as(usize, 1), utf8ByteOffsetToUtf16CodeUnitOffset(text, 2));
}

test "Win32 edit caret chooses the active selection endpoint" {
    try std.testing.expectEqual(@as(u32, 2), editSelectionCaretEndpoint(.{ 2, 8 }, 2));
    try std.testing.expectEqual(@as(u32, 8), editSelectionCaretEndpoint(.{ 2, 8 }, 8));
    try std.testing.expectEqual(@as(u32, 2), editSelectionCaretEndpoint(.{ 2, 8 }, 3));
    try std.testing.expectEqual(@as(u32, 8), editSelectionCaretEndpoint(.{ 2, 8 }, 7));
    try std.testing.expectEqual(@as(u32, 5), editSelectionCaretEndpoint(.{ 5, 5 }, 99));
}

pub fn nativeEditSelection(hwnd: HWND) [2]u32 {
    var start: u32 = 0;
    var end: u32 = 0;
    _ = sys.SendMessageW(
        hwnd,
        c.EM_GETSEL,
        @intFromPtr(&start),
        @bitCast(@intFromPtr(&end)),
    );
    return .{ start, end };
}

fn editSelectionCaretEndpoint(selection: [2]u32, native_caret: u32) u32 {
    if (selection[0] == selection[1]) return selection[0];
    const distance_to_start = if (native_caret >= selection[0])
        native_caret - selection[0]
    else
        selection[0] - native_caret;
    const distance_to_end = if (native_caret >= selection[1])
        native_caret - selection[1]
    else
        selection[1] - native_caret;
    return if (distance_to_start < distance_to_end) selection[0] else selection[1];
}

fn nativeEditCaret(hwnd: HWND, selection: [2]u32) u32 {
    if (selection[0] == selection[1]) return selection[0];
    if (sys.GetFocus() != hwnd) return selection[1];
    var point: POINT = undefined;
    if (sys.GetCaretPos(&point) == 0) return selection[1];
    const x: u16 = @bitCast(@as(i16, @truncate(point.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(point.y)));
    const packed_point: LPARAM = @bitCast(@as(usize, x) | (@as(usize, y) << 16));
    const result = sys.SendMessageW(hwnd, c.EM_CHARFROMPOS, 0, packed_point);
    const native_caret: u32 = @intCast(@as(usize, @bitCast(result)) & 0xFFFF);
    return editSelectionCaretEndpoint(selection, native_caret);
}

pub fn editSnapshot(
    alloc: Allocator,
    hwnd: HWND,
    value: []const u8,
) !win32_uia.TerminalSnapshot {
    const document_text = try alloc.dupe(u8, value);
    const selection = nativeEditSelection(hwnd);
    const start = utf16CodeUnitOffsetToUtf8ByteOffset(value, selection[0]);
    const end = utf16CodeUnitOffsetToUtf8ByteOffset(value, selection[1]);
    const caret = utf16CodeUnitOffsetToUtf8ByteOffset(value, nativeEditCaret(hwnd, selection));
    return .{
        .document_text = document_text,
        .visible_range = .{ .start = 0, .end = document_text.len },
        .caret_offset = caret,
        .selection_range = .{ .start = @min(start, end), .end = @max(start, end) },
    };
}

pub fn selectNativeEditRange(
    hwnd: HWND,
    snapshot_text: []const u8,
    range: win32_uia.OffsetRange,
) void {
    const start = utf8ByteOffsetToUtf16CodeUnitOffset(snapshot_text, range.start);
    const end = utf8ByteOffsetToUtf16CodeUnitOffset(snapshot_text, range.end);
    _ = sys.SendMessageW(hwnd, c.EM_SETSEL, start, @intCast(end));
    _ = sys.SetFocus(hwnd);
}

test "win32 chrome child placement invalidates a moved button" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Off-screen so the fixture never flashes over the desktop. An update
    // region is per-window bookkeeping, so it survives being off-screen.
    const hinstance = sys.GetModuleHandleW(null);
    const parent = sys.CreateWindowExW(
        0,
        prompt_label_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        c.WS_POPUP | c.WS_VISIBLE | c.WS_CLIPCHILDREN,
        -4000,
        -4000,
        1280,
        64,
        null,
        null,
        hinstance,
        null,
    ) orelse return lastError();
    defer _ = sys.DestroyWindow(parent);

    const button = sys.CreateWindowExW(
        0,
        prompt_button_class,
        std.unicode.utf8ToUtf16LeStringLiteral("2: tab"),
        c.WS_CHILD | c.WS_VISIBLE | c.BS_OWNERDRAW,
        0,
        0,
        220,
        32,
        parent,
        null,
        hinstance,
        null,
    ) orelse return lastError();
    defer _ = sys.DestroyWindow(button);

    var placement: ChildPlacement = .{};
    _ = applyChromeChildRect(button, &placement, childRect(0, 0, 220, 32));

    // Baseline: the plain helper moves with `bRepaint = FALSE` and leaves
    // nothing to repaint. That is what the terminal surfaces want, and it is
    // why a tab button shifted right by a mid-strip insert stayed unpainted
    // at its new slot while its old image survived under its neighbour.
    var update: RECT = undefined;
    _ = sys.ValidateRect(button, null);
    try std.testing.expect(applyChildRect(button, &placement, childRect(220, 0, 220, 32)));
    try std.testing.expectEqual(@as(BOOL, 0), sys.GetUpdateRect(button, &update, 0));

    // The chrome variant leaves the button invalidated wherever it lands.
    _ = sys.ValidateRect(button, null);
    try std.testing.expect(applyChromeChildRect(button, &placement, childRect(440, 0, 210, 32)));
    try std.testing.expect(sys.GetUpdateRect(button, &update, 0) != 0);

    // An unchanged rect stays a no-op, so a settled strip does not repaint on
    // every chrome sync.
    _ = sys.ValidateRect(button, null);
    try std.testing.expect(!applyChromeChildRect(button, &placement, childRect(440, 0, 210, 32)));
    try std.testing.expectEqual(@as(BOOL, 0), sys.GetUpdateRect(button, &update, 0));
}
