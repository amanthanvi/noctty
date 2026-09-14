//! Placement math for the tab strip's title tooltip.
//!
//! Tab labels are compacted to the cell budget their button can draw (see
//! `win32/labels.zig`), so a long title is only ever shown in part and the rest
//! used to be unreachable without renaming the tab. Upstream Ghostty never had
//! to place this popup itself: its GTK apprt hands the title to `AdwTabPage`
//! and libadwaita falls back to that title for the tab's tooltip, while the
//! macOS apprt inherits the same behavior from AppKit's native window tabs. The
//! Win32 chrome owner-draws its own tab buttons, so the geometry is ours.
//!
//! Only the window-free parts live here, so they can be tested without a
//! desktop.

const std = @import("std");

pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

pub const Size = struct {
    width: i32,
    height: i32,
};

/// Place a tooltip of `size` for the tab button occupying `anchor`, keeping the
/// popup inside `client` with `margin` px to spare.
///
/// The tooltip hangs below its tab by `gap` px and is left-aligned with it, so
/// the eye can follow the label straight down into the full title. A tab near
/// the right edge slides left instead of hanging off the window.
///
/// The popup is a top-level window, so nothing clips it for us: a title wider
/// than the window would be drawn over whatever sits beside the window, and the
/// part past the screen edge would be unreachable either way. The width is
/// clamped to the client area instead, and the popup's own `DT_END_ELLIPSIS`
/// then truncates the text it cannot fit.
pub fn place(anchor: Rect, size: Size, client: Rect, gap: i32, margin: i32) Rect {
    const w = @min(@max(0, size.width), @max(0, client.width() - margin * 2));
    const h = @max(0, size.height);

    var left = anchor.left;
    if (left + w > client.right - margin) left = client.right - margin - w;
    if (left < client.left + margin) left = client.left + margin;

    var top = anchor.bottom + gap;
    if (top + h > client.bottom - margin) {
        // No room below: prefer directly above the tab, and if the window is
        // too short for that too, sit at the bottom margin. A tooltip that
        // overlaps its own tab is still readable; one drawn past the window is
        // not shown at all.
        const above = anchor.top - gap - h;
        top = if (above >= client.top + margin)
            above
        else
            @max(client.top + margin, client.bottom - margin - h);
    }

    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

test "win32 tab tooltip hangs under its tab" {
    const placement = place(
        .{ .left = 40, .top = 0, .right = 180, .bottom = 32 },
        .{ .width = 200, .height = 24 },
        .{ .left = 0, .top = 0, .right = 800, .bottom = 600 },
        4,
        6,
    );
    try std.testing.expectEqual(@as(i32, 40), placement.left);
    try std.testing.expectEqual(@as(i32, 36), placement.top);
    try std.testing.expectEqual(@as(i32, 240), placement.right);
    try std.testing.expectEqual(@as(i32, 60), placement.bottom);
}

test "win32 tab tooltip slides left at the window edge" {
    const placement = place(
        .{ .left = 700, .top = 0, .right = 790, .bottom = 32 },
        .{ .width = 200, .height = 24 },
        .{ .left = 0, .top = 0, .right = 800, .bottom = 600 },
        4,
        6,
    );
    try std.testing.expectEqual(@as(i32, 594), placement.left);
    try std.testing.expectEqual(@as(i32, 794), placement.right);
}

test "win32 tab tooltip clamps to the client width and stays in the window" {
    const placement = place(
        .{ .left = 10, .top = 0, .right = 100, .bottom = 32 },
        .{ .width = 400, .height = 24 },
        .{ .left = 0, .top = 0, .right = 200, .bottom = 600 },
        4,
        6,
    );
    try std.testing.expectEqual(@as(i32, 6), placement.left);
    try std.testing.expectEqual(@as(i32, 194), placement.right);
    try std.testing.expect(placement.right <= 200 - 6);
}

test "win32 tab tooltip moves above the tab when the window is short" {
    const placement = place(
        .{ .left = 40, .top = 40, .right = 180, .bottom = 72 },
        .{ .width = 200, .height = 24 },
        .{ .left = 0, .top = 0, .right = 800, .bottom = 90 },
        4,
        6,
    );
    try std.testing.expectEqual(@as(i32, 12), placement.top);
    try std.testing.expectEqual(@as(i32, 36), placement.bottom);
}

test "win32 tab tooltip sits at the bottom margin when neither side fits" {
    // Too short for the tooltip above or below the tab: it overlaps the tab
    // rather than being placed outside the window, where it would not be
    // shown at all.
    const placement = place(
        .{ .left = 40, .top = 30, .right = 180, .bottom = 62 },
        .{ .width = 200, .height = 24 },
        .{ .left = 0, .top = 0, .right = 800, .bottom = 80 },
        4,
        6,
    );
    try std.testing.expectEqual(@as(i32, 50), placement.top);
    try std.testing.expectEqual(@as(i32, 74), placement.bottom);
}
