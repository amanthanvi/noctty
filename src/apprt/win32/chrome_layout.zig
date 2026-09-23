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

/// The client rect a host lays its children out against: the live one while
/// it has an area, otherwise the last one that did. Null means no rect with
/// an area has been seen yet, so there is nothing to lay out against.
///
/// A minimized window reports a 0x0 client rect. Laying the terminal out
/// against it clamps every pane to 1x1 px, which the core turns into a 1x1
/// grid and a 1x1 `ResizePseudoConsole` (#262). ConPTY keeps no scrollback, so
/// that throws away its whole buffer and homes its cursor, while the terminal
/// reflows its own copy down to one column and back. On restore the two
/// disagree about where the cursor is, and the shell's next output lands on
/// the top rows over the old text. Minimizing hides the window without
/// changing the size it will come back at, so keep the size it had.
pub fn hostLayoutClientRect(live: RECT, last_with_area: ?RECT) ?RECT {
    if (live.right > live.left and live.bottom > live.top) return live;
    return last_with_area;
}

pub fn centeredRect(rect: RECT, width: i32, height: i32) RECT {
    const outer_w = rect.right - rect.left;
    const outer_h = rect.bottom - rect.top;
    const left = rect.left + @divTrunc(outer_w - width, 2);
    const top = rect.top + @divTrunc(outer_h - height, 2);
    return childRect(left, top, width, height);
}

pub const confirm_preview_min_height_base: i32 = 72;
pub const confirm_preview_max_height_base: i32 = 220;
pub const confirm_preview_min_width_base: i32 = 200;

/// Rect for the confirm preview pane: the width under the overlay band,
/// tall enough to read several lines but never so tall that approving a
/// paste means losing sight of the terminal underneath.
///
/// Returns a zero-area rect when the window cannot show anything
/// readable. Callers treat that as "hide the pane" rather than drawing
/// a sliver, matching how the palette list refuses to render when its
/// width falls below the readable bound.
pub fn confirmPreviewRect(
    width: i32,
    client_bottom: i32,
    top: i32,
    left: i32,
    padding: i32,
    dpi: u32,
) RECT {
    const empty: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const min_h = scaledBy(confirm_preview_min_height_base, dpi);
    const max_h = scaledBy(confirm_preview_max_height_base, dpi);
    const min_w = scaledBy(confirm_preview_min_width_base, dpi);

    const right = width - @max(0, padding);
    if (right - left < min_w) return empty;

    const available = client_bottom - top;
    if (available < min_h) return empty;

    // A third of what is left, bounded both ways: enough to read, never
    // enough to hide the terminal the payload is about to land in.
    const height = @min(max_h, @max(min_h, @divTrunc(available, 3)));
    return .{
        .left = left,
        .top = top,
        .right = right,
        .bottom = top + height,
    };
}

/// Insets of the overlay band's two text rows, in unscaled logical
/// pixels. These are the offsets chrome paint has always used; the
/// confirm prompt's owner-drawn title and body children have to land on
/// exactly the same pixels or the prompt visibly shifts.
pub const overlay_text_inset_base: i32 = 10;
pub const confirm_title_top_base: i32 = 5;
pub const confirm_title_bottom_base: i32 = 25;
pub const overlay_feedback_top_base: i32 = 31;
pub const overlay_feedback_bottom_inset_base: i32 = 4;
/// Floor for the feedback line's right edge, so a very narrow window
/// still gets a readable strip instead of a zero-width rect.
pub const overlay_feedback_min_right_base: i32 = 40;

/// Insets of the overlay's rounded panel from the band it sits in.
pub const overlay_panel_top_inset_base: i32 = 4;
pub const overlay_panel_bottom_inset_base: i32 = 6;

/// Thickness, in device pixels, of the panel outline that must survive
/// above and below a child placed on the panel.
///
/// Not DPI-scaled: `gdi.drawRoundedRect` insets its `RoundRect` by one
/// pixel and strokes it with the 1px stock pen, so the outline is two
/// rows deep at every scale. A child that starts on those rows erases
/// them, and `WS_CLIPCHILDREN` on the host means the parent cannot draw
/// them back.
pub const overlay_panel_border_px: i32 = 2;

/// Rows of the overlay panel a chrome child may occupy without eating
/// the panel outline. `bottom` is exclusive.
pub const OverlayPanelInterior = struct { top: i32, bottom: i32 };

pub fn overlayPanelInterior(overlay_top: i32, overlay_bottom: i32, dpi: u32) OverlayPanelInterior {
    return .{
        .top = overlay_top + scaledBy(overlay_panel_top_inset_base, dpi) + overlay_panel_border_px,
        .bottom = overlay_bottom - scaledBy(overlay_panel_bottom_inset_base, dpi) - overlay_panel_border_px,
    };
}

/// Where one confirm prompt line lives once a child window owns it.
pub const ConfirmTextPlacement = struct {
    /// Rect the child window occupies, in client coordinates, clipped so
    /// it never covers the panel outline.
    child: RECT,
    /// Rect the text is laid out in, in the CHILD's coordinates. It is
    /// the rect chrome paint used, translated -- so the glyphs land on
    /// the pixels they always did and only the rows that would have sat
    /// on the panel outline get clipped by the child's edge. Keeping the
    /// painted rect rather than re-centring inside the clipped child is
    /// what makes this a pure ownership change: `DrawText`'s `DT_VCENTER`
    /// truncates its half-leading while a STATIC's `SS_CENTERIMAGE`
    /// rounds it up, so re-centring moves the line by a pixel whenever
    /// that leading is odd (measured: the body line, 150% DPI).
    text: RECT,

    pub fn visible(self: ConfirmTextPlacement) bool {
        return self.child.right > self.child.left and self.child.bottom > self.child.top;
    }
};

pub const empty_confirm_text_placement: ConfirmTextPlacement = .{
    .child = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    .text = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

/// Clip `paint` to the panel interior and express the original rect in
/// the resulting child's coordinates.
pub fn confirmTextPlacement(paint: RECT, interior: OverlayPanelInterior) ConfirmTextPlacement {
    if (paint.right <= paint.left or paint.bottom <= paint.top) return empty_confirm_text_placement;
    const top = @max(paint.top, interior.top);
    const bottom = @min(paint.bottom, interior.bottom);
    if (bottom <= top) return empty_confirm_text_placement;
    return .{
        .child = .{ .left = paint.left, .top = top, .right = paint.right, .bottom = bottom },
        .text = .{
            .left = 0,
            .top = paint.top - top,
            .right = paint.right - paint.left,
            .bottom = paint.bottom - top,
        },
    };
}

/// Rect chrome paint uses for the confirm prompt's title line.
///
/// `text_left` is the painted text origin and `edit_frame_right` the
/// right edge of the (hidden in confirm mode) query frame, which is what
/// bounds the title short of the action buttons.
pub fn confirmTitlePaintRect(
    overlay_top: i32,
    text_left: i32,
    edit_frame_right: i32,
    dpi: u32,
) RECT {
    const left = @max(0, text_left);
    return .{
        .left = left,
        .top = overlay_top + scaledBy(confirm_title_top_base, dpi),
        .right = @max(left, edit_frame_right),
        .bottom = overlay_top + scaledBy(confirm_title_bottom_base, dpi),
    };
}

/// Rect the confirm prompt's body line uses, in BOTH renderers.
///
/// The shared feedback line overhangs the rounded panel by a couple of
/// rows -- invisible for transparent-background GDI text, which simply
/// drew its descenders over the panel outline. A child window cannot do
/// that: its DC is clipped to its own client area (measured with
/// `GetClipBox` inside `WM_DRAWITEM`), so anything past the edge is lost
/// rather than overdrawn, and at most DPIs the body's `p` / `g` / `q`
/// descenders ended exactly one row past it.
///
/// So the confirm body is centred inside a rect that fits the panel
/// instead. The chrome paint fallback uses this same rect, which is the
/// point: there is no second renderer left to stay pixel-aligned with,
/// so moving the line up a row or two is free, while clipping ink is not.
/// Other overlay modes keep `overlayFeedbackLineRect` untouched.
pub fn confirmBodyPaintRect(
    width: i32,
    overlay_top: i32,
    overlay_bottom: i32,
    padding: i32,
    dpi: u32,
) RECT {
    const empty: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    const line = overlayFeedbackLineRect(width, overlay_top, overlay_bottom, padding, dpi);
    const interior = overlayPanelInterior(overlay_top, overlay_bottom, dpi);
    const top = @max(line.top, interior.top);
    const bottom = @min(line.bottom, interior.bottom);
    if (bottom <= top or line.right <= line.left) return empty;
    return .{ .left = line.left, .top = top, .right = line.right, .bottom = bottom };
}

/// Rect chrome paint uses for the overlay's feedback line -- the second
/// row of the band, under the label. Every overlay mode draws there; a
/// confirm goes through `confirmBodyPaintRect` instead, which pulls this
/// rect inside the panel outline. `padding` arrives already scaled,
/// matching every other overlay helper here.
pub fn overlayFeedbackLineRect(
    width: i32,
    overlay_top: i32,
    overlay_bottom: i32,
    padding: i32,
    dpi: u32,
) RECT {
    const bounded_padding = @max(0, padding);
    const inset = scaledBy(overlay_text_inset_base, dpi);
    const left = bounded_padding + inset;
    return .{
        .left = left,
        .top = overlay_top + scaledBy(overlay_feedback_top_base, dpi),
        .right = @max(
            bounded_padding + scaledBy(overlay_feedback_min_right_base, dpi),
            width - bounded_padding - inset,
        ),
        .bottom = overlay_bottom - scaledBy(overlay_feedback_bottom_inset_base, dpi),
    };
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

/// Insets of the overlay query EDIT inside its painted frame, in unscaled
/// logical pixels. The frame is `overlay_row_height` (24) tall and the
/// EDIT uses the 14 px chrome font, whose GDI cell is 19 px at 96 DPI:
/// a 6 px vertical inset left the child 12 px tall and the EDIT class
/// clipped every glyph at the waist. 2 px keeps the frame's own stroke
/// (`drawRoundedRect` draws one pixel in from the rect) visible around
/// the child while giving the text its full cell.
pub const overlay_edit_child_inset_x_base: i32 = 8;
pub const overlay_edit_child_inset_y_base: i32 = 2;

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

test "hostLayoutClientRect follows the live client rect while it has an area" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const before = RECT{ .left = 0, .top = 0, .right = 1258, .bottom = 789 };
    const after = RECT{ .left = 0, .top = 0, .right = 1258, .bottom = 889 };

    // A real resize is taken as is, whatever was laid out before it.
    try std.testing.expectEqual(after, hostLayoutClientRect(after, before).?);
    try std.testing.expectEqual(before, hostLayoutClientRect(before, null).?);

    // One pixel each way is still a window the user can see.
    const tiny = RECT{ .left = 0, .top = 0, .right = 1, .bottom = 1 };
    try std.testing.expectEqual(tiny, hostLayoutClientRect(tiny, before).?);
}

test "hostLayoutClientRect keeps the last real rect while the window is minimized" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const restored = RECT{ .left = 0, .top = 0, .right = 1258, .bottom = 789 };

    // `GetClientRect` on a minimized host, measured: 0x0 at the origin.
    // Before this, layout clamped that to a 1x1 px pane, a 1x1 grid and a
    // 1x1 pseudo console (#262).
    const minimized = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    try std.testing.expectEqual(restored, hostLayoutClientRect(minimized, restored).?);

    // Losing either axis is just as collapsed.
    const no_width = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 789 };
    const no_height = RECT{ .left = 0, .top = 0, .right = 1258, .bottom = 0 };
    try std.testing.expectEqual(restored, hostLayoutClientRect(no_width, restored).?);
    try std.testing.expectEqual(restored, hostLayoutClientRect(no_height, restored).?);
}

test "hostLayoutClientRect lays nothing out before the first real rect" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const minimized = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    try std.testing.expectEqual(@as(?RECT, null), hostLayoutClientRect(minimized, null));
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

test "win32 overlay edit child leaves room for the chrome font" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // The frame is one overlay row tall. With the shipped insets the EDIT
    // has to hold a 14 px font's 19 px GDI cell at 96 DPI, and scale with
    // it: the old 6 px inset left 12 px and clipped every glyph.
    const metrics: win32_theme.ThemeMetrics = .{};
    const dpis = [_]u32{ 96, 144, 192, 288 };
    for (dpis) |dpi| {
        const row_h = scaledBy(metrics.overlay_row_height, dpi);
        const frame = overlayEditFrameRect(800, 40, scaledBy(12, dpi), scaledBy(110, dpi), scaledBy(80, dpi), 0, row_h, dpi);
        const child = overlayEditChildRectFromFrame(
            frame,
            scaledBy(overlay_edit_child_inset_x_base, dpi),
            scaledBy(overlay_edit_child_inset_y_base, dpi),
        );
        const font_cell = scaledBy(19, dpi);
        try std.testing.expect(child.bottom - child.top >= font_cell);
        // The frame stroke sits one pixel inside the rect; the child must
        // not paint over it.
        try std.testing.expect(child.top > frame.top + 1);
        try std.testing.expect(child.bottom < frame.bottom - 1);
    }
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

test "confirmPreviewRect fills the width under the overlay band" {
    const r = confirmPreviewRect(1200, 800, 100, 26, 16, 96);
    try std.testing.expectEqual(@as(i32, 26), r.left);
    try std.testing.expectEqual(@as(i32, 100), r.top);
    try std.testing.expectEqual(@as(i32, 1184), r.right);
    // (800 - 100) / 3 = 233, clamped to the 220 maximum.
    try std.testing.expectEqual(@as(i32, 320), r.bottom);
}

test "confirmPreviewRect keeps a floor so short windows still read" {
    // (200 - 100) / 3 = 33, raised to the 72 minimum.
    const r = confirmPreviewRect(1200, 200, 100, 26, 16, 96);
    try std.testing.expectEqual(@as(i32, 172), r.bottom);
    try std.testing.expect(r.bottom <= 200);
}

test "confirmPreviewRect refuses to render a sliver" {
    // Too short for the minimum height.
    const short = confirmPreviewRect(1200, 160, 100, 26, 16, 96);
    try std.testing.expectEqual(@as(i32, 0), short.right);
    try std.testing.expectEqual(@as(i32, 0), short.bottom);

    // Too narrow for the minimum width.
    const narrow = confirmPreviewRect(200, 800, 100, 26, 16, 96);
    try std.testing.expectEqual(@as(i32, 0), narrow.right);
}

test "confirmPreviewRect scales its bounds with DPI" {
    const r = confirmPreviewRect(2400, 1600, 200, 52, 32, 192);
    // 220 base * 2 = 440 maximum; (1600 - 200) / 3 = 466 clamps to it.
    try std.testing.expectEqual(@as(i32, 640), r.bottom);
    // `padding` arrives already scaled by the caller, so the right edge
    // is a plain subtraction and does not scale again here.
    try std.testing.expectEqual(@as(i32, 2368), r.right);
}

test "confirm prompt text placement reproduces the painted line positions" {
    // The live geometry this was measured against: 150% DPI, band at
    // y=60..147, query frame ending at x=982, padding 30.
    const dpi: u32 = 144;
    const overlay_top: i32 = 60;
    const overlay_bottom: i32 = 147;
    const interior = overlayPanelInterior(overlay_top, overlay_bottom, dpi);
    try std.testing.expectEqual(@as(i32, 68), interior.top);
    try std.testing.expectEqual(@as(i32, 136), interior.bottom);

    const title_paint = confirmTitlePaintRect(overlay_top, 45, 982, dpi);
    try std.testing.expectEqual(@as(i32, 67), title_paint.top);
    try std.testing.expectEqual(@as(i32, 97), title_paint.bottom);
    const title = confirmTextPlacement(title_paint, interior);
    try std.testing.expect(title.visible());
    // One row of the painted rect sat on the panel outline.
    try std.testing.expectEqual(@as(i32, 68), title.child.top);
    try std.testing.expectEqual(@as(i32, 97), title.child.bottom);
    try std.testing.expectEqual(@as(i32, 45), title.child.left);
    try std.testing.expectEqual(@as(i32, 982), title.child.right);
    // The text rect keeps the painted span, so `DT_VCENTER` puts the
    // glyphs on the pixels they always used. Only internal leading is
    // given up at the top, never ink.
    try std.testing.expectEqual(@as(i32, -1), title.text.top);
    try std.testing.expectEqual(@as(i32, 29), title.text.bottom);
    try std.testing.expectEqual(@as(i32, 0), title.text.left);
    try std.testing.expectEqual(@as(i32, 937), title.text.right);

    // The body's own rect already fits the panel, so the placement clip
    // is a no-op and the text rect is exactly the child.
    const line = overlayFeedbackLineRect(1280, overlay_top, overlay_bottom, 30, dpi);
    try std.testing.expectEqual(@as(i32, 106), line.top);
    try std.testing.expectEqual(@as(i32, 141), line.bottom);
    const body_paint = confirmBodyPaintRect(1280, overlay_top, overlay_bottom, 30, dpi);
    try std.testing.expectEqual(@as(i32, 106), body_paint.top);
    try std.testing.expectEqual(@as(i32, 136), body_paint.bottom);
    const body = confirmTextPlacement(body_paint, interior);
    try std.testing.expectEqual(@as(i32, 106), body.child.top);
    try std.testing.expectEqual(@as(i32, 136), body.child.bottom);
    try std.testing.expectEqual(@as(i32, 45), body.child.left);
    try std.testing.expectEqual(@as(i32, 1235), body.child.right);
    try std.testing.expectEqual(@as(i32, 0), body.text.top);
    try std.testing.expectEqual(@as(i32, 30), body.text.bottom);
}

test "confirmTextPlacement keeps the text rect anchored to the painted one" {
    const interior: OverlayPanelInterior = .{ .top = 10, .bottom = 40 };

    // Entirely inside: child is the painted rect and the text rect is it
    // at the origin.
    const inside = confirmTextPlacement(.{ .left = 4, .top = 12, .right = 104, .bottom = 30 }, interior);
    try std.testing.expectEqual(@as(i32, 12), inside.child.top);
    try std.testing.expectEqual(@as(i32, 30), inside.child.bottom);
    try std.testing.expectEqual(@as(i32, 0), inside.text.top);
    try std.testing.expectEqual(@as(i32, 18), inside.text.bottom);

    // Clipped at the top: the text rect goes negative by the same amount,
    // so the glyphs keep their absolute position.
    const high = confirmTextPlacement(.{ .left = 0, .top = 7, .right = 100, .bottom = 33 }, interior);
    try std.testing.expectEqual(@as(i32, 10), high.child.top);
    try std.testing.expectEqual(@as(i32, -3), high.text.top);
    try std.testing.expectEqual(@as(i32, 7), high.child.top + high.text.top);
    try std.testing.expectEqual(@as(i32, 33), high.child.top + high.text.bottom);

    // Clipped at the bottom.
    const low = confirmTextPlacement(.{ .left = 0, .top = 20, .right = 100, .bottom = 45 }, interior);
    try std.testing.expectEqual(@as(i32, 20), low.child.top);
    try std.testing.expectEqual(@as(i32, 40), low.child.bottom);
    try std.testing.expectEqual(@as(i32, 45), low.child.top + low.text.bottom);

    // Nothing survives.
    const gone = confirmTextPlacement(.{ .left = 0, .top = 60, .right = 100, .bottom = 80 }, interior);
    try std.testing.expect(!gone.visible());
    const degenerate = confirmTextPlacement(.{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, interior);
    try std.testing.expect(!degenerate.visible());
}

test "confirm prompt text placement scales with DPI" {
    // A DPI table. At every scale both lines stay inside the panel
    // outline and the body's text rect fits its child exactly, which is
    // the font-independent property that decides whether descender ink
    // survives the child's clip -- the child's DC is clipped to its own
    // client area, so a text rect taller than the child loses rows.
    const dpis = [_]u32{ 96, 120, 144, 168, 192, 288 };
    for (dpis) |dpi| {
        const overlay_top = scaledBy(40, dpi);
        const overlay_bottom = overlay_top + scaledBy(58, dpi);
        const padding = scaledBy(20, dpi);
        const width = scaledBy(1280, dpi);
        const text_left = padding + scaledBy(overlay_text_inset_base, dpi);
        const interior = overlayPanelInterior(overlay_top, overlay_bottom, dpi);

        const title_paint = confirmTitlePaintRect(overlay_top, text_left, scaledBy(700, dpi), dpi);
        const body_paint = confirmBodyPaintRect(width, overlay_top, overlay_bottom, padding, dpi);
        const title = confirmTextPlacement(title_paint, interior);
        const body = confirmTextPlacement(body_paint, interior);

        try std.testing.expect(title.visible());
        try std.testing.expect(body.visible());
        try std.testing.expectEqual(text_left, title.child.left);
        try std.testing.expectEqual(text_left, body.child.left);
        try std.testing.expect(title.child.top >= interior.top);
        try std.testing.expect(title.child.bottom <= interior.bottom);
        try std.testing.expect(body.child.top >= interior.top);
        try std.testing.expect(body.child.bottom <= interior.bottom);
        try std.testing.expect(body.child.top >= title.child.bottom);

        // The painted rects, recoverable from the child coordinates.
        try std.testing.expectEqual(title_paint.top, title.child.top + title.text.top);
        try std.testing.expectEqual(title_paint.bottom, title.child.top + title.text.bottom);
        try std.testing.expectEqual(body_paint.top, body.child.top + body.text.top);
        try std.testing.expectEqual(body_paint.bottom, body.child.top + body.text.bottom);

        // The body's text rect is exactly its child: no ink can be
        // clipped at either edge.
        try std.testing.expectEqual(@as(i32, 0), body.text.top);
        try std.testing.expectEqual(body.child.bottom - body.child.top, body.text.bottom);

        // The title gives up at most the panel outline's worth of
        // internal leading at the top, and nothing at the bottom.
        try std.testing.expect(title.text.top >= -overlay_panel_border_px);
        try std.testing.expect(title.text.bottom <= title.child.bottom - title.child.top);

        // And the body still sits where the shared feedback line does,
        // minus only the rows that overhung the panel.
        const line = overlayFeedbackLineRect(width, overlay_top, overlay_bottom, padding, dpi);
        try std.testing.expectEqual(line.top, body_paint.top);
        try std.testing.expect(body_paint.bottom <= line.bottom);
    }
}

test "confirm prompt text placement refuses a collapsed band" {
    const interior = overlayPanelInterior(40, 70, 96);
    const body = confirmTextPlacement(confirmBodyPaintRect(1200, 40, 70, 16, 96), interior);
    try std.testing.expect(!body.visible());
    // The unclipped feedback line still reports a rect there; it is the
    // panel clip that refuses, which is what callers gate on.
    try std.testing.expectEqual(@as(i32, 0), confirmBodyPaintRect(1200, 40, 70, 16, 96).right);

    // A frame that ends left of the text origin cannot produce a
    // negative-width child.
    const inverted = confirmTextPlacement(
        confirmTitlePaintRect(40, 700, 100, 96),
        overlayPanelInterior(40, 140, 96),
    );
    try std.testing.expect(!inverted.visible());
}
