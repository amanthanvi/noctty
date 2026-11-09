//! The dividers between split panes as mouse targets: which divider a point
//! grabs, where a drag puts it, the smallest a pane may get, and the ratio a
//! double-click equalizes a split to. Pure: a split tree, its `spatial`
//! slots and the content rectangle in physical pixels in, ratios out. The
//! Host (`win32/host.zig`, `beginPaneDividerDrag` and its neighbours) owns
//! the mouse, the capture, the layout and the undo history.
//!
//! The gap `win32_layout.splitSurfacePlacement` leaves between two panes is
//! 2 physical pixels at every DPI, one taken from each pane, and the host
//! paints it (`chrome_scene.paintChromePaneDividers`). A divider's grab zone
//! is that gap widened by `grab_margin_dip` into both panes, across the
//! divider only. Where zones overlap (a nested divider meets its parent),
//! the deepest split wins: the innermost divider under the point.

const std = @import("std");
const win32_chrome_state = @import("../win32_chrome_state.zig");
const win32_layout = @import("../win32_layout.zig");

pub const Rect = win32_layout.Rect;
pub const Point = struct { x: i32, y: i32 };

/// How far (96 DPI) a divider's grab zone reaches into each pane beside it.
/// With the 2 px gap that is an 8 px target at 100% and 10 at 150%, while a
/// terminal keeps every pixel more than 3 DIP from its edge, which is mostly
/// its `window-padding`.
pub const grab_margin_dip: i32 = 3;

/// The smallest (96 DPI) a drag leaves a pane, along the drag: about two
/// rows of text and four columns at the default font, and enough to click
/// and to grab the pane's other dividers. The keyboard `resize_split`
/// enforces no minimum (it clamps the ratio to 0..1), so a pane it made
/// smaller than this keeps its size: a drag never shrinks it further, and
/// never pushes it out to this minimum either (`minExtent`).
pub const min_pane_dip: i32 = 40;

pub fn grabMargin(dpi: u32) i32 {
    return win32_chrome_state.scaled(grab_margin_dip, dpi);
}

pub fn minPane(dpi: u32) i32 {
    return win32_chrome_state.scaled(min_pane_dip, dpi);
}

pub fn contains(rect: Rect, point: Point) bool {
    return point.x >= rect.left and point.x < rect.right and
        point.y >= rect.top and point.y < rect.bottom;
}

pub fn For(comptime Tree: type) type {
    return struct {
        pub const Handle = Tree.Node.Handle;
        pub const Layout = Tree.Split.Layout;
        pub const Spatial = Tree.Spatial;

        pub const Divider = struct {
            /// The split node the divider belongs to.
            handle: Handle,
            /// `.horizontal`: the panes sit left and right of a vertical
            /// line (IDC_SIZEWE); `.vertical`: above and below (IDC_SIZENS).
            layout: Layout,
            /// 0 for the root split; deeper splits win overlapping zones.
            depth: usize,
            /// The pixels the split's two children share.
            split: Rect,
            /// The painted gap between them.
            line: Rect,
            /// `line` widened by the grab margin across the divider, inside
            /// `split`.
            grab: Rect,
            /// Where the second child's slot starts along the split's axis:
            /// the divider's position, which `dragRatio` moves.
            position: i32,
        };

        /// The divider of the split at `handle`, or null for a leaf or a
        /// handle the tree or `spatial` does not have.
        pub fn divider(tree: *const Tree, spatial: Spatial, content: Rect, handle: Handle, margin: i32) ?Divider {
            return dividerAt(tree, spatial, content, handle, 0, margin);
        }

        fn dividerAt(tree: *const Tree, spatial: Spatial, content: Rect, handle: Handle, depth: usize, margin: i32) ?Divider {
            if (handle.idx() >= tree.nodes.len or handle.idx() >= spatial.slots.len) return null;
            const s = switch (tree.nodes[handle.idx()]) {
                .leaf => return null,
                .split => |s| s,
            };
            if (s.left.idx() >= spatial.slots.len or s.right.idx() >= spatial.slots.len) return null;
            const split = slotRect(content, spatial.slots[handle.idx()]);
            const first = slotRect(content, spatial.slots[s.left.idx()]);
            const second = slotRect(content, spatial.slots[s.right.idx()]);
            var line = split;
            var grab = split;
            var position: i32 = undefined;
            switch (s.layout) {
                .horizontal => {
                    // The first pane loses its last column to the gap and the
                    // second its first; their slots can round one pixel apart.
                    const lo = @min(first.right, second.left) - 1;
                    const hi = @max(first.right, second.left) + 1;
                    line.left = std.math.clamp(lo, split.left, split.right);
                    line.right = std.math.clamp(hi, split.left, split.right);
                    grab.left = std.math.clamp(lo - margin, split.left, split.right);
                    grab.right = std.math.clamp(hi + margin, split.left, split.right);
                    position = second.left;
                },
                .vertical => {
                    const lo = @min(first.bottom, second.top) - 1;
                    const hi = @max(first.bottom, second.top) + 1;
                    line.top = std.math.clamp(lo, split.top, split.bottom);
                    line.bottom = std.math.clamp(hi, split.top, split.bottom);
                    grab.top = std.math.clamp(lo - margin, split.top, split.bottom);
                    grab.bottom = std.math.clamp(hi + margin, split.top, split.bottom);
                    position = second.top;
                },
            }
            return .{
                .handle = handle,
                .layout = s.layout,
                .depth = depth,
                .split = split,
                .line = line,
                .grab = grab,
                .position = position,
            };
        }

        /// The innermost divider whose grab zone holds `point`. None while
        /// a pane is zoomed: the zoomed pane covers the content and no
        /// divider is shown.
        pub fn hitTest(tree: *const Tree, spatial: Spatial, content: Rect, point: Point, margin: i32) ?Divider {
            if (tree.nodes.len == 0 or tree.zoomed != null) return null;
            if (!contains(content, point)) return null;
            var best: ?Divider = null;
            visit(tree, spatial, content, point, margin, .root, 0, &best);
            return best;
        }

        fn visit(
            tree: *const Tree,
            spatial: Spatial,
            content: Rect,
            point: Point,
            margin: i32,
            handle: Handle,
            depth: usize,
            best: *?Divider,
        ) void {
            if (handle.idx() >= tree.nodes.len) return;
            const s = switch (tree.nodes[handle.idx()]) {
                .leaf => return,
                .split => |s| s,
            };
            if (dividerAt(tree, spatial, content, handle, depth, margin)) |found| {
                if (contains(found.grab, point)) {
                    if (best.* == null or found.depth >= best.*.?.depth) best.* = found;
                }
            }
            visit(tree, spatial, content, point, margin, s.left, depth + 1, best);
            visit(tree, spatial, content, point, margin, s.right, depth + 1, best);
        }

        /// The ratio that puts `found`'s divider at `along` (a pixel on the
        /// split's axis, in content coordinates), held where neither side
        /// gets smaller than `min_px` (`minExtent`). Null when the split has
        /// no extent.
        pub fn dragRatio(tree: *const Tree, spatial: Spatial, content: Rect, found: Divider, along: i32, min_px: i32) ?f16 {
            if (found.handle.idx() >= tree.nodes.len) return null;
            const s = switch (tree.nodes[found.handle.idx()]) {
                .leaf => return null,
                .split => |s| s,
            };
            const start: i32, const extent: i32 = switch (s.layout) {
                .horizontal => .{ found.split.left, found.split.right - found.split.left },
                .vertical => .{ found.split.top, found.split.bottom - found.split.top },
            };
            if (extent <= 0) return null;
            const span: f32 = @floatFromInt(extent);
            const min: f32 = @floatFromInt(@max(0, min_px));
            const lo = @max(0, minExtent(tree, spatial, content, s.left, s.layout, min) / span);
            const hi = @min(1, 1 - minExtent(tree, spatial, content, s.right, s.layout, min) / span);
            const want = @as(f32, @floatFromInt(along - start)) / span;
            // A subtree already smaller than its minimum keeps its size
            // (`minExtent`), so the current ratio always lies in [lo, hi];
            // only rounding can cross them, which leaves the ratio as is.
            if (!(lo <= hi)) return s.ratio;
            return @floatCast(std.math.clamp(want, lo, hi));
        }

        /// The smallest extent along `axis` the subtree at `handle` can take
        /// without any pane in it getting smaller than `min_px`, given the
        /// ratios inside it (a drag of an outer divider scales them all). A
        /// pane that is already smaller counts at its current size, so a
        /// layout the keyboard made never blocks a drag or jumps on it.
        pub fn minExtent(tree: *const Tree, spatial: Spatial, content: Rect, handle: Handle, axis: Layout, min_px: f32) f32 {
            if (handle.idx() >= tree.nodes.len or handle.idx() >= spatial.slots.len) return 0;
            return switch (tree.nodes[handle.idx()]) {
                .leaf => @min(min_px, slotSpan(content, spatial.slots[handle.idx()], axis)),
                .split => |s| split: {
                    const first = minExtent(tree, spatial, content, s.left, axis, min_px);
                    const second = minExtent(tree, spatial, content, s.right, axis, min_px);
                    if (s.layout != axis) break :split @max(first, second);
                    const ratio: f32 = s.ratio;
                    break :split @max(share(first, ratio), share(second, 1 - ratio));
                },
            };
        }

        fn share(min: f32, ratio: f32) f32 {
            if (min <= 0) return 0;
            if (ratio <= 0) return std.math.inf(f32);
            return min / ratio;
        }

        /// The ratio `SplitTree.equalize` gives the split at `handle`: its
        /// sides weighted by their panes along its axis. Double-clicking a
        /// divider applies it to that one split.
        pub fn equalRatio(tree: *const Tree, handle: Handle) ?f16 {
            if (handle.idx() >= tree.nodes.len) return null;
            const s = switch (tree.nodes[handle.idx()]) {
                .leaf => return null,
                .split => |s| s,
            };
            const first: f32 = @floatFromInt(weight(tree, s.left, s.layout));
            const second: f32 = @floatFromInt(weight(tree, s.right, s.layout));
            return @floatCast(first / (first + second));
        }

        /// `SplitTree.weight`, which is private there.
        fn weight(tree: *const Tree, handle: Handle, layout: Layout) usize {
            if (handle.idx() >= tree.nodes.len) return 1;
            return switch (tree.nodes[handle.idx()]) {
                .leaf => 1,
                .split => |s| if (s.layout == layout)
                    weight(tree, s.left, layout) + weight(tree, s.right, layout)
                else
                    1,
            };
        }

        fn slotRect(content: Rect, slot: anytype) Rect {
            const width = @max(1, content.width());
            const height = @max(1, content.height());
            const x = content.left + win32_layout.roundedSlotPixel(@floatCast(slot.x), width);
            const y = content.top + win32_layout.roundedSlotPixel(@floatCast(slot.y), height);
            return .{
                .left = x,
                .top = y,
                .right = x + win32_layout.roundedSlotPixel(@floatCast(slot.width), width),
                .bottom = y + win32_layout.roundedSlotPixel(@floatCast(slot.height), height),
            };
        }

        fn slotSpan(content: Rect, slot: anytype, axis: Layout) f32 {
            return switch (axis) {
                .horizontal => @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(@max(1, content.width()))),
                .vertical => @as(f32, @floatCast(slot.height)) * @as(f32, @floatFromInt(@max(1, content.height()))),
            };
        }
    };
}

const testing = std.testing;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

const TestView = struct {
    label: []const u8,

    pub fn ref(self: *TestView, alloc: std.mem.Allocator) std.mem.Allocator.Error!*TestView {
        const ptr = try alloc.create(TestView);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *TestView, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }

    pub fn splitTreeLabel(self: *const TestView) []const u8 {
        return self.label;
    }
};

const TestTree = SplitTree(TestView);
const Dividers = For(TestTree);
const content_800x600: Rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };

/// A tree of `views` built by splitting the pane at each step's handle.
const Step = struct { at: TestTree.Node.Handle, direction: TestTree.Split.Direction, ratio: f16 };

fn buildTree(views: []TestView, steps: []const Step) !TestTree {
    var tree = try TestTree.init(testing.allocator, &views[0]);
    errdefer tree.deinit();
    for (steps, 1..) |step, i| {
        var inserted = try TestTree.init(testing.allocator, &views[i]);
        defer inserted.deinit();
        const next = try tree.split(testing.allocator, step.at, step.direction, step.ratio, &inserted);
        tree.deinit();
        tree = next;
    }
    return tree;
}

fn handleOfView(tree: *const TestTree, label: []const u8) TestTree.Node.Handle {
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.view.label, label)) return entry.handle;
    }
    unreachable;
}

/// The split whose children include the pane `label`, directly.
fn parentOf(tree: *const TestTree, child: TestTree.Node.Handle) TestTree.Node.Handle {
    for (tree.nodes, 0..) |node, i| switch (node) {
        .leaf => {},
        .split => |s| if (s.left == child or s.right == child) return @enumFromInt(i),
    };
    unreachable;
}

test "pane divider: two side-by-side panes grab across the 2 px gap and the margin" {
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);

    const margin = grabMargin(96);
    try testing.expectEqual(@as(i32, 3), margin);
    const found = Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 400, .y = 300 }, margin).?;
    try testing.expectEqual(TestTree.Node.Handle.root, found.handle);
    try testing.expectEqual(TestTree.Split.Layout.horizontal, found.layout);
    // The painted gap: A ends at 399, B starts at 401.
    try testing.expectEqual(Rect{ .left = 399, .top = 0, .right = 401, .bottom = 600 }, found.line);
    try testing.expectEqual(Rect{ .left = 396, .top = 0, .right = 404, .bottom = 600 }, found.grab);
    try testing.expectEqual(@as(i32, 400), found.position);

    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 396, .y = 0 }, margin) != null);
    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 403, .y = 599 }, margin) != null);
    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 395, .y = 300 }, margin) == null);
    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 404, .y = 300 }, margin) == null);
    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 400, .y = 600 }, margin) == null);

    // Stacked panes give a horizontal line, offset by the content's origin.
    var stacked_views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var stacked = try buildTree(&stacked_views, &.{.{ .at = .root, .direction = .down, .ratio = 0.5 }});
    defer stacked.deinit();
    var stacked_spatial = try stacked.spatial(testing.allocator);
    defer stacked_spatial.deinit(testing.allocator);
    const below_tabs: Rect = .{ .left = 0, .top = 40, .right = 800, .bottom = 640 };
    const line = Dividers.hitTest(&stacked, stacked_spatial, below_tabs, .{ .x = 10, .y = 342 }, margin).?;
    try testing.expectEqual(TestTree.Split.Layout.vertical, line.layout);
    try testing.expectEqual(Rect{ .left = 0, .top = 339, .right = 800, .bottom = 341 }, line.line);
    try testing.expectEqual(@as(i32, 340), line.position);
}

test "pane divider: the innermost divider wins where nested dividers meet" {
    // [A | (B / C)]: the root splits A from a stack of B over C.
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    {
        var inserted = try TestTree.init(testing.allocator, &views[2]);
        defer inserted.deinit();
        const next = try tree.split(testing.allocator, handleOfView(&tree, "B"), .down, 0.5, &inserted);
        tree.deinit();
        tree = next;
    }
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);
    const inner = parentOf(&tree, handleOfView(&tree, "C"));
    const margin = grabMargin(96);

    // On the stack's line, and where it meets the root's line on B's side.
    for ([_]Point{ .{ .x = 600, .y = 300 }, .{ .x = 401, .y = 300 }, .{ .x = 400, .y = 298 } }) |point| {
        const found = Dividers.hitTest(&tree, spatial, content_800x600, point, margin).?;
        try testing.expectEqual(inner, found.handle);
        try testing.expectEqual(TestTree.Split.Layout.vertical, found.layout);
        try testing.expectEqual(@as(usize, 1), found.depth);
    }
    // On A's side of the root's line, and along it away from the stack's.
    for ([_]Point{ .{ .x = 399, .y = 300 }, .{ .x = 401, .y = 100 } }) |point| {
        const found = Dividers.hitTest(&tree, spatial, content_800x600, point, margin).?;
        try testing.expectEqual(TestTree.Node.Handle.root, found.handle);
        try testing.expectEqual(TestTree.Split.Layout.horizontal, found.layout);
    }
    // The stack's line does not reach into A.
    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 200, .y = 300 }, margin) == null);
}

test "pane divider: a zoomed tree or a single pane has no divider" {
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);
    tree.zoom(handleOfView(&tree, "A"));
    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 400, .y = 300 }, 3) == null);
    tree.zoom(null);
    try testing.expect(Dividers.hitTest(&tree, spatial, content_800x600, .{ .x = 400, .y = 300 }, 3) != null);

    var single_view = [_]TestView{.{ .label = "A" }};
    var single = try buildTree(&single_view, &.{});
    defer single.deinit();
    var single_spatial = try single.spatial(testing.allocator);
    defer single_spatial.deinit(testing.allocator);
    try testing.expect(Dividers.hitTest(&single, single_spatial, content_800x600, .{ .x = 400, .y = 300 }, 3) == null);
}

test "pane divider: grab margin and minimum pane scale with DPI" {
    try testing.expectEqual(@as(i32, 3), grabMargin(96));
    try testing.expectEqual(@as(i32, 4), grabMargin(144));
    try testing.expectEqual(@as(i32, 6), grabMargin(192));
    try testing.expectEqual(@as(i32, 40), minPane(96));
    try testing.expectEqual(@as(i32, 60), minPane(144));
    try testing.expectEqual(@as(i32, 80), minPane(192));

    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);
    // 1600 physical pixels at 192 DPI: the gap stays 2 px, the zone grows.
    const wide: Rect = .{ .left = 0, .top = 0, .right = 1600, .bottom = 1200 };
    const found = Dividers.hitTest(&tree, spatial, wide, .{ .x = 794, .y = 10 }, grabMargin(192)).?;
    try testing.expectEqual(Rect{ .left = 799, .top = 0, .right = 801, .bottom = 1200 }, found.line);
    try testing.expectEqual(Rect{ .left = 793, .top = 0, .right = 807, .bottom = 1200 }, found.grab);
    try testing.expect(Dividers.hitTest(&tree, spatial, wide, .{ .x = 792, .y = 10 }, grabMargin(192)) == null);
    // The minimum is 80 px at 192 DPI: 0.05 of 1600.
    try testing.expectEqual(@as(f16, 0.05), Dividers.dragRatio(&tree, spatial, wide, found, 0, minPane(192)).?);
}

test "pane divider: a drag follows the pointer and stops at the minimum pane" {
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);
    const found = Dividers.divider(&tree, spatial, content_800x600, .root, 3).?;
    try testing.expectEqual(@as(f16, 0.25), Dividers.dragRatio(&tree, spatial, content_800x600, found, 200, 40).?);
    try testing.expectEqual(@as(f16, 0.75), Dividers.dragRatio(&tree, spatial, content_800x600, found, 600, 40).?);
    // 40 of 800 px on either side.
    try testing.expectEqual(@as(f16, 0.05), Dividers.dragRatio(&tree, spatial, content_800x600, found, -50, 40).?);
    try testing.expectEqual(@as(f16, 0.95), Dividers.dragRatio(&tree, spatial, content_800x600, found, 900, 40).?);
}

test "pane divider: a drag keeps every nested pane at its minimum" {
    // [A | (B | C)]: B and C share the right half, so it cannot get narrower
    // than two minimum panes.
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    {
        var inserted = try TestTree.init(testing.allocator, &views[2]);
        defer inserted.deinit();
        const next = try tree.split(testing.allocator, handleOfView(&tree, "B"), .right, 0.5, &inserted);
        tree.deinit();
        tree = next;
    }
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);
    const root = Dividers.divider(&tree, spatial, content_800x600, .root, 3).?;
    try testing.expectEqual(@as(f16, 0.9), Dividers.dragRatio(&tree, spatial, content_800x600, root, 800, 40).?);
    // A stack across the axis needs only one pane's width: [A | (B / C)]
    // would stop at 0.95; the equal stack weighs one, the side-by-side two.
    try testing.expectEqual(@as(f16, 1.0 / 3.0), Dividers.equalRatio(&tree, .root).?);
    const inner = parentOf(&tree, handleOfView(&tree, "C"));
    try testing.expectEqual(@as(f16, 0.5), Dividers.equalRatio(&tree, inner).?);
    try testing.expect(Dividers.equalRatio(&tree, handleOfView(&tree, "A")) == null);

    var stack_views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var stack = try buildTree(&stack_views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer stack.deinit();
    {
        var inserted = try TestTree.init(testing.allocator, &stack_views[2]);
        defer inserted.deinit();
        const next = try stack.split(testing.allocator, handleOfView(&stack, "B"), .down, 0.5, &inserted);
        stack.deinit();
        stack = next;
    }
    var stack_spatial = try stack.spatial(testing.allocator);
    defer stack_spatial.deinit(testing.allocator);
    const stack_root = Dividers.divider(&stack, stack_spatial, content_800x600, .root, 3).?;
    try testing.expectEqual(@as(f16, 0.95), Dividers.dragRatio(&stack, stack_spatial, content_800x600, stack_root, 800, 40).?);
    try testing.expectEqual(@as(f16, 0.5), Dividers.equalRatio(&stack, .root).?);
}

test "pane divider: a pane already below the minimum keeps its size and does not jump" {
    // The keyboard `resize_split` clamps only to 0..1: A is 16 px of 800.
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.02 }});
    defer tree.deinit();
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);
    const found = Dividers.divider(&tree, spatial, content_800x600, .root, 3).?;
    const kept = Dividers.dragRatio(&tree, spatial, content_800x600, found, 0, 40).?;
    try testing.expectApproxEqAbs(@as(f32, 0.02), @as(f32, kept), 0.001);
    try testing.expectEqual(@as(f16, 0.5), Dividers.dragRatio(&tree, spatial, content_800x600, found, 400, 40).?);

    // A window too small for two minimum panes keeps the ratio it has.
    const narrow: Rect = .{ .left = 0, .top = 0, .right = 60, .bottom = 600 };
    var even_views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var even = try buildTree(&even_views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer even.deinit();
    var even_spatial = try even.spatial(testing.allocator);
    defer even_spatial.deinit(testing.allocator);
    const tight = Dividers.divider(&even, even_spatial, narrow, .root, 3).?;
    try testing.expectEqual(@as(f16, 0.5), Dividers.dragRatio(&even, even_spatial, narrow, tight, 0, 40).?);
    try testing.expectEqual(@as(f16, 0.5), Dividers.dragRatio(&even, even_spatial, narrow, tight, 60, 40).?);
}
