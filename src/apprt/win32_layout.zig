//! Pure Win32 host layout geometry.
//!
//! No HWNDs, no `RECT`, no runtime side effects. The Win32 host owns topology
//! and child-window application; this module owns the pane/search rectangles
//! derived from a content box and normalized split slots.

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

pub const NormalizedSlot = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const SurfacePlacement = struct {
    visible: bool = true,
    pane_rect: Rect,
    search_frame_rect: ?Rect = null,
};

pub fn childRect(x: i32, y: i32, width: i32, height: i32) Rect {
    return .{
        .left = x,
        .top = y,
        .right = x + width,
        .bottom = y + height,
    };
}

pub fn zoomedSurfacePlacement(
    content_rect: Rect,
    search_visible: bool,
    scaled_search_bar_height: i32,
) SurfacePlacement {
    const content_width = @max(1, content_rect.width());
    const content_height = @max(1, content_rect.height());
    return surfacePlacementFromBaseRect(
        childRect(content_rect.left, content_rect.top, content_width, content_height),
        search_visible,
        scaled_search_bar_height,
    );
}

pub fn splitSurfacePlacement(
    content_rect: Rect,
    slot: NormalizedSlot,
    has_multi_panes: bool,
    search_visible: bool,
    scaled_search_bar_height: i32,
) SurfacePlacement {
    const content_width = @max(1, content_rect.width());
    const content_height = @max(1, content_rect.height());
    const content_right = content_rect.left + content_width;
    const content_bottom = content_rect.top + content_height;

    var x = content_rect.left + roundedSlotPixel(slot.x, content_width);
    var y = content_rect.top + roundedSlotPixel(slot.y, content_height);
    var w = @max(1, roundedSlotPixel(slot.width, content_width));
    var h = @max(1, roundedSlotPixel(slot.height, content_height));

    // Match the existing host behaviour: create a 1px visual divider gap only
    // at internal split edges. Outer edges stay flush with content bounds.
    if (has_multi_panes) {
        if (x > content_rect.left) {
            x += 1;
            w -= 1;
        }
        if (x + w < content_right) {
            w -= 1;
        }
        if (y > content_rect.top) {
            y += 1;
            h -= 1;
        }
        if (y + h < content_bottom) {
            h -= 1;
        }
        w = @max(1, w);
        h = @max(1, h);
    }

    // Independent rounding of a slot's origin and span can overshoot the
    // content edge by one pixel. Keep every child rect inside its host lane.
    x = std.math.clamp(x, content_rect.left, content_right - 1);
    y = std.math.clamp(y, content_rect.top, content_bottom - 1);
    w = @max(1, @min(w, content_right - x));
    h = @max(1, @min(h, content_bottom - y));

    return surfacePlacementFromBaseRect(
        childRect(x, y, w, h),
        search_visible,
        scaled_search_bar_height,
    );
}

fn surfacePlacementFromBaseRect(
    base_rect: Rect,
    search_visible: bool,
    scaled_search_bar_height: i32,
) SurfacePlacement {
    const base_w = @max(1, base_rect.width());
    const base_h = @max(1, base_rect.height());
    const frame_h: i32 = if (search_visible)
        @min(@max(0, scaled_search_bar_height), @max(0, base_h - 1))
    else
        0;

    const search_frame_rect = if (frame_h > 0)
        childRect(base_rect.left, base_rect.top, base_w, frame_h)
    else
        null;

    return .{
        .pane_rect = childRect(
            base_rect.left,
            base_rect.top + frame_h,
            base_w,
            @max(1, base_h - frame_h),
        ),
        .search_frame_rect = search_frame_rect,
    };
}

fn roundedSlotPixel(value: f32, span: i32) i32 {
    return @intFromFloat(@round(value * @as(f32, @floatFromInt(span))));
}

test "zoomed placement reserves search frame above pane" {
    const placement = zoomedSurfacePlacement(
        childRect(10, 20, 400, 240),
        true,
        32,
    );
    try std.testing.expectEqual(Rect{ .left = 10, .top = 20, .right = 410, .bottom = 52 }, placement.search_frame_rect.?);
    try std.testing.expectEqual(Rect{ .left = 10, .top = 52, .right = 410, .bottom = 260 }, placement.pane_rect);
}

test "single split slot stays flush without divider inset" {
    const placement = splitSurfacePlacement(
        childRect(5, 7, 101, 51),
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        false,
        false,
        30,
    );
    try std.testing.expectEqual(Rect{ .left = 5, .top = 7, .right = 106, .bottom = 58 }, placement.pane_rect);
    try std.testing.expect(placement.search_frame_rect == null);
}

test "multi-pane internal edges receive one pixel gaps" {
    const left = splitSurfacePlacement(
        childRect(0, 0, 101, 51),
        .{ .x = 0, .y = 0, .width = 0.5, .height = 1 },
        true,
        false,
        30,
    );
    const right = splitSurfacePlacement(
        childRect(0, 0, 101, 51),
        .{ .x = 0.5, .y = 0, .width = 0.5, .height = 1 },
        true,
        false,
        30,
    );
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 50, .bottom = 51 }, left.pane_rect);
    try std.testing.expectEqual(Rect{ .left = 52, .top = 0, .right = 101, .bottom = 51 }, right.pane_rect);
}

test "tiny content suppresses search frame and preserves one pixel pane" {
    const placement = splitSurfacePlacement(
        childRect(0, 0, 1, 1),
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        true,
        true,
        30,
    );
    try std.testing.expect(placement.search_frame_rect == null);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 1, .bottom = 1 }, placement.pane_rect);
}
