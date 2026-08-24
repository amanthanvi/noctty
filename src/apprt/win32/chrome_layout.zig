//! Host-independent Win32 chrome and overlay rectangle math.
//!
//! This complements `win32_layout.zig`: that sibling owns normalized pane
//! topology, while this module owns native `RECT` calculations for chrome
//! controls and overlay action rows.

const std = @import("std");
const builtin = @import("builtin");

const win32_layout = @import("../win32_layout.zig");
const win32_chrome_state = @import("../win32_chrome_state.zig");
const win32_theme = @import("../win32_theme.zig");
const labels = @import("labels.zig");
const sys = @import("sys.zig");

const HostOverlayMode = win32_theme.HostOverlayMode;
const RECT = sys.RECT;
const overlay_right_gap_base: i32 = 6;
const overlay_min_edit_width_base: i32 = 24;

const OverlayActionVisibility = struct {
    accept: bool,
    cancel: bool,
};

const OverlayActionLayout = struct {
    accept_visible: bool,
    cancel_visible: bool,
    compact_cancel: bool,
    accept_x: i32,
    cancel_x: i32,
    accept_width: i32,
    cancel_width: i32,
    accept_reservation_width: i32,
};

pub fn rectEquals(a: RECT, b: RECT) bool {
    return a.left == b.left and
        a.top == b.top and
        a.right == b.right and
        a.bottom == b.bottom;
}

pub fn childRect(x: i32, y: i32, width: i32, height: i32) RECT {
    return .{
        .left = x,
        .top = y,
        .right = x + width,
        .bottom = y + height,
    };
}

pub fn layoutRectToWin32(rect: win32_layout.Rect) RECT {
    return .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };
}

pub fn centeredRect(rect: RECT, width: i32, height: i32) RECT {
    const outer_w = rect.right - rect.left;
    const outer_h = rect.bottom - rect.top;
    const left = rect.left + @divTrunc(outer_w - width, 2);
    const top = rect.top + @divTrunc(outer_h - height, 2);
    return childRect(left, top, width, height);
}

pub fn overlayEditFrameRect(
    width: i32,
    overlay_y: i32,
    padding: i32,
    label_w: i32,
    cancel_w: i32,
    accept_reservation_w: i32,
    row_h: i32,
    dpi: u32,
) RECT {
    const top_offset = scaledBy(4, dpi);
    const right_gap = scaledBy(overlay_right_gap_base, dpi);
    const min_edit_width = scaledBy(overlay_min_edit_width_base, dpi);
    const effective_label_w = overlayLabelReservation(
        width,
        padding,
        label_w,
        cancel_w,
        accept_reservation_w,
        dpi,
    );
    const bounded_width = @max(0, width);
    const raw_right = width - cancel_w - accept_reservation_w - (padding * 2) - right_gap;
    const right = @min(bounded_width, @max(@min(bounded_width, min_edit_width), raw_right));
    const left = @min(
        @max(0, padding + effective_label_w),
        @max(0, right - min_edit_width),
    );
    return .{
        .left = left,
        .top = overlay_y + top_offset,
        .right = right,
        .bottom = overlay_y + top_offset + row_h,
    };
}

pub fn overlayLabelReservation(
    width: i32,
    padding: i32,
    desired_label_w: i32,
    cancel_w: i32,
    accept_reservation_w: i32,
    dpi: u32,
) i32 {
    const right_gap = scaledBy(overlay_right_gap_base, dpi);
    const min_edit_width = scaledBy(overlay_min_edit_width_base, dpi);
    const desired = @max(0, desired_label_w);
    const available_before_actions = width - @max(0, cancel_w) - @max(0, accept_reservation_w) -
        2 * @max(0, padding) - right_gap;
    return if (available_before_actions - @max(0, padding) >= desired + min_edit_width) desired else 0;
}

fn overlayActionVisibilityForWidth(
    width: i32,
    padding: i32,
    cancel_w: i32,
    accept_w: i32,
    accept_requested: bool,
    dpi: u32,
) OverlayActionVisibility {
    const bounded_padding = @max(0, padding);
    const right_gap = scaledBy(overlay_right_gap_base, dpi);
    const min_edit_width = scaledBy(overlay_min_edit_width_base, dpi);
    const cancel = width >= @max(0, cancel_w) + 3 * bounded_padding + right_gap + min_edit_width;
    const accept = cancel and accept_requested and
        width >= @max(0, cancel_w) + @max(0, accept_w) + 4 * bounded_padding + right_gap + min_edit_width;
    return .{ .accept = accept, .cancel = cancel };
}

pub fn overlayActionLayoutForWidth(
    mode: HostOverlayMode,
    width: i32,
    padding: i32,
    cancel_button_w: i32,
    accept_button_w: i32,
    dpi: u32,
) OverlayActionLayout {
    const bounded_padding = @max(0, padding);
    const visibility = overlayActionVisibilityForWidth(
        width,
        bounded_padding,
        cancel_button_w,
        accept_button_w,
        labels.overlayAcceptButtonVisible(mode),
        dpi,
    );
    const compact_cancel = mode == .confirm and !visibility.cancel and width > 0;
    const compact_inset = if (compact_cancel)
        @min(bounded_padding, @divTrunc(width - 1, 2))
    else
        bounded_padding;
    const cancel_visible = visibility.cancel or compact_cancel;
    const accept_width = if (visibility.accept) @max(0, accept_button_w) else 0;
    const cancel_width = if (compact_cancel)
        width - 2 * compact_inset
    else if (cancel_visible)
        @max(0, cancel_button_w)
    else
        0;
    return .{
        .accept_visible = visibility.accept,
        .cancel_visible = cancel_visible,
        .compact_cancel = compact_cancel,
        .accept_x = @max(0, width - cancel_width - accept_width - 2 * bounded_padding),
        .cancel_x = if (compact_cancel) compact_inset else width - cancel_width - bounded_padding,
        .accept_width = accept_width,
        .cancel_width = cancel_width,
        .accept_reservation_width = if (visibility.accept) accept_width + bounded_padding else 0,
    };
}

pub fn overlayEditChildRectFromFrame(frame: RECT, inset_x: i32, inset_y: i32) RECT {
    const left = @min(frame.right, frame.left + @max(0, inset_x));
    const top = @min(frame.bottom, frame.top + @max(0, inset_y));
    return .{
        .left = left,
        .top = top,
        .right = @max(left, frame.right - @max(0, inset_x)),
        .bottom = @max(top, frame.bottom - @max(0, inset_y)),
    };
}

fn scaledBy(base: i32, dpi: u32) i32 {
    return win32_chrome_state.scaled(base, dpi);
}

test "win32 overlay edit child rect preserves frame border" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const frame = RECT{ .left = 100, .top = 20, .right = 300, .bottom = 58 };
    const child = overlayEditChildRectFromFrame(frame, 8, 6);
    try std.testing.expectEqual(@as(i32, 108), child.left);
    try std.testing.expectEqual(@as(i32, 26), child.top);
    try std.testing.expectEqual(@as(i32, 292), child.right);
    try std.testing.expectEqual(@as(i32, 52), child.bottom);
    try std.testing.expect(child.bottom < frame.bottom);
}

test "win32 overlay edit frame offsets scale with DPI" {
    const dpis = [_]u32{ 96, 192, 288 };
    for (dpis, 1..) |dpi, scale| {
        const scale_i32: i32 = @intCast(scale);
        const padding = 10 * scale_i32;
        const label_w = 100 * scale_i32;
        const cancel_w = 80 * scale_i32;
        const row_h = 30 * scale_i32;
        const overlay_y = 20 * scale_i32;
        const frame = overlayEditFrameRect(
            800 * scale_i32,
            overlay_y,
            padding,
            label_w,
            cancel_w,
            0,
            row_h,
            dpi,
        );
        try std.testing.expectEqual(overlay_y + 4 * scale_i32, frame.top);
        try std.testing.expectEqual(frame.top + row_h, frame.bottom);
        try std.testing.expectEqual(
            800 * scale_i32 - cancel_w - padding * 2 - 6 * scale_i32,
            frame.right,
        );
    }

    const narrow = overlayEditFrameRect(220, 20, 10, 100, 80, 0, 30, 96);
    const close_left = 220 - 80 - 10;
    try std.testing.expectEqual(@as(i32, 10), narrow.left);
    try std.testing.expect(narrow.right <= close_left);
    try std.testing.expect(narrow.right >= narrow.left);

    for ([_]i32{ 80, 100, 120, 140 }) |width| {
        const visibility = overlayActionVisibilityForWidth(width, 10, 80, 80, false, 96);
        const effective_cancel: i32 = if (visibility.cancel) 80 else 0;
        const frame = overlayEditFrameRect(width, 20, 10, 100, effective_cancel, 0, 30, 96);
        const child = overlayEditChildRectFromFrame(frame, 8, 6);
        try std.testing.expect(child.left >= frame.left);
        try std.testing.expect(child.right <= frame.right);
        try std.testing.expect(child.left <= child.right);
        if (visibility.cancel) try std.testing.expect(child.right <= width - 80 - 10);
    }
    for ([_]i32{ 1, 10, 20, 30 }) |width| {
        const frame = overlayEditFrameRect(width, 20, 10, 100, 0, 0, 30, 96);
        try std.testing.expect(frame.left >= 0);
        try std.testing.expect(frame.right <= width);
        try std.testing.expect(frame.right > frame.left);
    }
    try std.testing.expect(!overlayActionVisibilityForWidth(220, 10, 80, 80, true, 96).accept);
    try std.testing.expect(overlayActionVisibilityForWidth(230, 10, 80, 80, true, 96).accept);
}
