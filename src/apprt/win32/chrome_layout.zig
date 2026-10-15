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

/// What the host banner offers besides its text, which fixes its buttons.
pub const BannerActions = enum {
    /// A message set through `Host.setBanner`: a close button.
    close,
    /// The update notice: Open Release and Dismiss.
    update,
    /// The update notice for a verified staged update: Install and Dismiss.
    update_staged,
};

pub const banner_height_base: i32 = 32;
pub const banner_stripe_width_base: i32 = 3;
pub const banner_text_left_base: i32 = 12;
pub const banner_button_height_base: i32 = 24;
pub const banner_button_gap_base: i32 = 8;
pub const banner_close_width_base: i32 = 28;
pub const banner_dismiss_width_base: i32 = 72;
pub const banner_open_release_width_base: i32 = 102;
pub const banner_install_width_base: i32 = 86;

/// The width a banner needs for a line `text_width` pixels wide and its
/// buttons, before the content area bounds it.
pub fn hostBannerWidth(text_width: i32, actions: BannerActions, dpi: u32) i32 {
    const gap = scaledBy(banner_button_gap_base, dpi);
    const buttons = switch (actions) {
        .close => scaledBy(banner_close_width_base, dpi),
        .update => scaledBy(banner_open_release_width_base, dpi) + gap + scaledBy(banner_dismiss_width_base, dpi),
        .update_staged => scaledBy(banner_install_width_base, dpi) + gap + scaledBy(banner_dismiss_width_base, dpi),
    };
    return scaledBy(banner_text_left_base, dpi) + @max(0, text_width) + gap + buttons + gap;
}

/// The host banner in host client coordinates: `width` wide at the right end
/// of the content rect at `top`, never wider than the content rect nor
/// taller than what is left of it.
pub fn hostBannerRect(content: RECT, top: i32, width: i32, dpi: u32) RECT {
    const height = std.math.clamp(content.bottom - top, 0, scaledBy(banner_height_base, dpi));
    const right = @max(content.left, content.right);
    return .{ .left = @max(content.left, right - @max(0, width)), .top = top, .right = right, .bottom = top + height };
}

/// The parts of a banner `width` by `height` pixels, in its own client
/// coordinates.
pub const HostBannerParts = struct {
    /// The severity stripe along the left edge.
    stripe: RECT,
    text: RECT,
    /// Open Release or Install; null for a `.close` banner.
    primary: ?RECT,
    /// The close button, or Dismiss for the update notice.
    dismiss: ?RECT,
};

/// Lay the banner's buttons out right-aligned and give the text what is
/// left. Taken from the banner's own size rather than recomputed from the
/// DPI, so paint and hit-testing agree with the rect the child really has.
/// A button that does not fit at its full width is left out (null) rather
/// than squeezed to nothing, which would leave a focusable button nobody
/// can see; the text gets what remains, never a negative width.
pub fn hostBannerParts(width: i32, height: i32, actions: BannerActions, dpi: u32) HostBannerParts {
    const w = @max(0, width);
    const h = @max(0, height);
    const button_h = @min(h, scaledBy(banner_button_height_base, dpi));
    const button_top = @divTrunc(h - button_h, 2);
    const gap = scaledBy(banner_button_gap_base, dpi);

    var right = w - gap;
    const dismiss_w = scaledBy(switch (actions) {
        .close => banner_close_width_base,
        .update, .update_staged => banner_dismiss_width_base,
    }, dpi);
    const dismiss = bannerButtonRect(&right, dismiss_w, button_top, button_h, gap);
    const primary: ?RECT = switch (actions) {
        .close => null,
        .update => bannerButtonRect(&right, scaledBy(banner_open_release_width_base, dpi), button_top, button_h, gap),
        .update_staged => bannerButtonRect(&right, scaledBy(banner_install_width_base, dpi), button_top, button_h, gap),
    };
    const text_left = @min(w, scaledBy(banner_text_left_base, dpi));
    return .{
        .stripe = .{ .left = 0, .top = 0, .right = @min(w, scaledBy(banner_stripe_width_base, dpi)), .bottom = h },
        .text = .{ .left = text_left, .top = 0, .right = @max(text_left, right), .bottom = h },
        .primary = primary,
        .dismiss = dismiss,
    };
}

/// Take a button of `width` off the right of the row ending at `right.*`,
/// and leave `right.*` one gap left of it; null, leaving `right.*` as it
/// was, when the row has no room for the whole button.
fn bannerButtonRect(right: *i32, width: i32, top: i32, height: i32, gap: i32) ?RECT {
    if (height <= 0 or right.* < width) return null;
    const button = RECT{ .left = right.* - width, .top = top, .right = right.*, .bottom = top + height };
    right.* = button.left - gap;
    return button;
}

/// The sizes of the docked search bar's controls at one DPI, in pixels.
pub const SearchBarChromeLayout = struct {
    pad_x: i32,
    pad_y: i32,
    gap: i32,
    section_gap: i32,
    close_gap: i32,
    nav_w: i32,
    toggle_w: i32,
    close_w: i32,
    results_w: i32,
    min_edit_w: i32,
    control_h: i32,
};

pub fn searchBarChromeLayout(dpi: u32) SearchBarChromeLayout {
    return .{
        .pad_x = scaledBy(8, dpi),
        .pad_y = scaledBy(6, dpi),
        .gap = scaledBy(2, dpi),
        .section_gap = scaledBy(10, dpi),
        .close_gap = scaledBy(10, dpi),
        .nav_w = scaledBy(30, dpi),
        .toggle_w = scaledBy(30, dpi),
        .close_w = scaledBy(30, dpi),
        // The results chip clips on its left: its longest text, "Invalid
        // pattern", is 98 px wide in the 14 px chrome font at 100%.
        .results_w = scaledBy(104, dpi),
        .min_edit_w = scaledBy(120, dpi),
        .control_h = scaledBy(28, dpi),
    };
}

/// Which optional controls of the docked search bar fit in a frame of
/// `frame_width`. The close button and the edit always stay.
pub const SearchBarFit = struct {
    /// The regex, case and whole-word toggles.
    toggles: bool,
    /// The previous and next buttons. Enter, Shift+Enter and the arrow keys
    /// in the edit still step through the matches without them.
    nav: bool,
};

/// In a narrow pane the controls used to be placed right to left without
/// regard to the left edge, so they overlapped each other and the next pane
/// while the edit shrank to 1 px. The toggles go first, then previous and
/// next, whenever the edit would be narrower than `min_edit_w` beside them.
pub fn searchBarFit(frame_width: i32, layout: SearchBarChromeLayout) SearchBarFit {
    const room = frame_width - 2 * layout.pad_x - layout.close_w - layout.close_gap;
    const nav_w = 2 * layout.nav_w + layout.gap + layout.section_gap;
    const toggles_w = 3 * layout.toggle_w + 2 * layout.gap + layout.section_gap;
    return .{
        .toggles = room - nav_w - toggles_w >= layout.min_edit_w,
        .nav = room - nav_w >= layout.min_edit_w,
    };
}

fn scaledBy(base: i32, dpi: u32) i32 {
    return win32_chrome_state.scaled(base, dpi);
}

test "searchBarFit drops the toggles, then previous and next, as the pane narrows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    for ([_]u32{ 96, 120, 144, 192, 288 }) |dpi| {
        const layout = searchBarChromeLayout(dpi);
        // Everything the bar can show, and the edit at its minimum.
        const room_all = 2 * layout.pad_x + layout.close_w + layout.close_gap +
            (2 * layout.nav_w + layout.gap + layout.section_gap) +
            (3 * layout.toggle_w + 2 * layout.gap + layout.section_gap) + layout.min_edit_w;
        const room_nav = room_all - (3 * layout.toggle_w + 2 * layout.gap + layout.section_gap);

        try std.testing.expectEqual(SearchBarFit{ .toggles = true, .nav = true }, searchBarFit(room_all, layout));
        try std.testing.expectEqual(SearchBarFit{ .toggles = true, .nav = true }, searchBarFit(room_all + 500, layout));
        try std.testing.expectEqual(SearchBarFit{ .toggles = false, .nav = true }, searchBarFit(room_all - 1, layout));
        try std.testing.expectEqual(SearchBarFit{ .toggles = false, .nav = true }, searchBarFit(room_nav, layout));
        try std.testing.expectEqual(SearchBarFit{ .toggles = false, .nav = false }, searchBarFit(room_nav - 1, layout));
        try std.testing.expectEqual(SearchBarFit{ .toggles = false, .nav = false }, searchBarFit(0, layout));
        try std.testing.expectEqual(SearchBarFit{ .toggles = false, .nav = false }, searchBarFit(-40, layout));
    }
}

test "searchBarFit at 232 px leaves an edit that can be typed in" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // 232 px at 96 DPI is exactly the width the fixed controls need, which
    // used to leave the edit 1 px wide.
    const layout = searchBarChromeLayout(96);
    const fit = searchBarFit(232, layout);
    try std.testing.expect(!fit.toggles);
    try std.testing.expect(!fit.nav);
    const edit_w = 232 - 2 * layout.pad_x - layout.close_w - layout.close_gap;
    try std.testing.expect(edit_w >= layout.min_edit_w);

    // The two thresholds at 96 DPI, written out: 16 px of padding, the close
    // button and its gap (40), previous and next with their gaps (72), the
    // toggles with theirs (104) and the 120 px edit.
    try std.testing.expect(searchBarFit(352, layout).toggles);
    try std.testing.expect(!searchBarFit(351, layout).toggles);
    try std.testing.expect(searchBarFit(248, layout).nav);
    try std.testing.expect(!searchBarFit(247, layout).nav);
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

test "hostBannerWidth fits the line and the buttons the parts layout uses" {
    // 12 text inset + 200 text + 8 gap + 28 close + 8 right gap.
    try std.testing.expectEqual(@as(i32, 256), hostBannerWidth(200, .close, 96));
    // At that width the text gets exactly its 200 pixels.
    const parts = hostBannerParts(hostBannerWidth(200, .close, 96), 32, .close, 96);
    try std.testing.expectEqual(@as(i32, 200), parts.text.right - parts.text.left);
    for ([_]BannerActions{ .update, .update_staged }) |actions| {
        for ([_]u32{ 96, 144, 192 }) |dpi| {
            const fitted = hostBannerParts(hostBannerWidth(300, actions, dpi), 48, actions, dpi);
            try std.testing.expectEqual(@as(i32, 300), fitted.text.right - fitted.text.left);
        }
    }
}

test "hostBannerRect sits at the right of the content area, which bounds it" {
    try std.testing.expectEqual(
        RECT{ .left = 544, .top = 40, .right = 800, .bottom = 72 },
        hostBannerRect(.{ .left = 0, .top = 40, .right = 800, .bottom = 600 }, 40, 256, 96),
    );
    // Below a docked search frame, and 150% tall.
    try std.testing.expectEqual(
        RECT{ .left = 700, .top = 100, .right = 1200, .bottom = 148 },
        hostBannerRect(.{ .left = 0, .top = 60, .right = 1200, .bottom = 900 }, 100, 500, 144),
    );
    try std.testing.expectEqual(@as(i32, 64), hostBannerRect(.{ .left = 0, .top = 0, .right = 1600, .bottom = 1200 }, 0, 500, 192).bottom);
    // Wider than the content area: as wide as it.
    try std.testing.expectEqual(
        RECT{ .left = 10, .top = 0, .right = 400, .bottom = 32 },
        hostBannerRect(.{ .left = 10, .top = 0, .right = 400, .bottom = 300 }, 0, 9000, 96),
    );
    // A content area shorter than the banner bounds it.
    try std.testing.expectEqual(@as(i32, 20), hostBannerRect(.{ .left = 0, .top = 0, .right = 400, .bottom = 20 }, 0, 100, 96).bottom);
}

test "hostBannerParts puts a close button at the right and gives the text the rest" {
    const parts = hostBannerParts(800, 32, .close, 96);
    try std.testing.expectEqual(RECT{ .left = 0, .top = 0, .right = 3, .bottom = 32 }, parts.stripe);
    try std.testing.expectEqual(RECT{ .left = 764, .top = 4, .right = 792, .bottom = 28 }, parts.dismiss.?);
    try std.testing.expectEqual(@as(?RECT, null), parts.primary);
    try std.testing.expectEqual(RECT{ .left = 12, .top = 0, .right = 756, .bottom = 32 }, parts.text);
}

test "hostBannerParts scales the update notice and its two buttons with DPI" {
    // 150%: 24 -> 36 buttons, 8 -> 12 gaps.
    const parts = hostBannerParts(1200, 48, .update, 144);
    try std.testing.expectEqual(RECT{ .left = 1080, .top = 6, .right = 1188, .bottom = 42 }, parts.dismiss.?);
    try std.testing.expectEqual(RECT{ .left = 915, .top = 6, .right = 1068, .bottom = 42 }, parts.primary.?);
    try std.testing.expectEqual(RECT{ .left = 18, .top = 0, .right = 903, .bottom = 48 }, parts.text);

    // 200%: Install is narrower than Open Release.
    const staged = hostBannerParts(1600, 64, .update_staged, 192);
    try std.testing.expectEqual(RECT{ .left = 1440, .top = 8, .right = 1584, .bottom = 56 }, staged.dismiss.?);
    try std.testing.expectEqual(RECT{ .left = 1252, .top = 8, .right = 1424, .bottom = 56 }, staged.primary.?);
}

test "hostBannerParts leaves out a button that does not fit and never hands out negative rects" {
    // Room for Dismiss but not Open Release: no zero-width primary for
    // F6 to land on; the text keeps what is left of Dismiss.
    const tight = hostBannerParts(120, 32, .update, 96);
    try std.testing.expectEqual(RECT{ .left = 40, .top = 4, .right = 112, .bottom = 28 }, tight.dismiss.?);
    try std.testing.expectEqual(@as(?RECT, null), tight.primary);
    try std.testing.expectEqual(RECT{ .left = 12, .top = 0, .right = 32, .bottom = 32 }, tight.text);

    // Room for neither: no buttons, and the text gets the row.
    const narrow = hostBannerParts(60, 32, .update, 96);
    try std.testing.expectEqual(@as(?RECT, null), narrow.dismiss);
    try std.testing.expectEqual(@as(?RECT, null), narrow.primary);
    try std.testing.expectEqual(RECT{ .left = 12, .top = 0, .right = 52, .bottom = 32 }, narrow.text);
    const sliver = hostBannerParts(5, 32, .close, 96);
    try std.testing.expect(sliver.text.right >= sliver.text.left);

    // Shorter than a button: the buttons shrink to fit.
    const short = hostBannerParts(400, 20, .close, 96);
    try std.testing.expectEqual(@as(i32, 20), short.dismiss.?.bottom - short.dismiss.?.top);
    try std.testing.expectEqual(@as(i32, 20), short.stripe.bottom);
}
