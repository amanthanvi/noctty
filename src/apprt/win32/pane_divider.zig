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
/// its `window-padding`. Beside a pane that can scroll, its overlay
/// scrollbar's band (10 DIP at its right edge) keeps the margin on that
/// side (`Surface.scrollbarBandAtScreen`), so the target there is the gap
/// and the other pane's margin: 5 px at 100%, 6 at 150%.
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

fn contains(rect: Rect, point: Point) bool {
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
            /// the divider's position, which a drag moves (`stepRatio`).
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

        /// The ratios a drag of `found`'s divider may take: neither side
        /// smaller than `min_px` (`minExtent`), measured on the layout as it
        /// is. The Host takes them once, at the press, and again only when
        /// the split's extent changes mid-drag (`Host.dragPaneDivider`):
        /// measured on every move, a pane that started below the minimum
        /// would count at the size the drag grew it to, and could not be
        /// dragged back to where it was. Null when the split has no extent.
        pub fn ratioBounds(tree: *const Tree, spatial: Spatial, content: Rect, found: Divider, min_px: i32) ?Bounds {
            if (found.handle.idx() >= tree.nodes.len) return null;
            const s = switch (tree.nodes[found.handle.idx()]) {
                .leaf => return null,
                .split => |s| s,
            };
            const extent = splitExtent(found);
            if (extent <= 0) return null;
            const span: f32 = @floatFromInt(extent);
            const min: f32 = @floatFromInt(@max(0, min_px));
            // The split's ratio now (the start, measured at the press) is
            // always in the bounds: a pane already under the minimum counts
            // at its size, through f32 shares that do not round as the f16
            // slots do, and once put a bound just inside the start, so a
            // drag toward that pane moved the divider away from the pointer
            // (Opus on #689: 3 px back for a 1 px drag). `fitRatio` keeps
            // the real floors either way.
            const ratio: f32 = s.ratio;
            return .{
                .lo = @min(ratio, @max(0, minExtent(tree, spatial, content, s.left, s.layout, min) / span)),
                .hi = @max(ratio, @min(1, 1 - minExtent(tree, spatial, content, s.right, s.layout, min) / span)),
                .extent = extent,
                .min_px = min_px,
            };
        }

        /// `want` held in `bounds`, as an f16; `current` when no f16 ratio
        /// fits them. The bounds are checked in pixels after the f16
        /// conversion: an f16 has no 1 px step on a wide window, and the
        /// nearest one to 1 - 40/3840 (0.98958) is 0.98975, which puts the
        /// divider 1 px past the bound and leaves a 39 px pane; then the
        /// ratio steps one f16 back toward the inside. A pane inside a
        /// nested split goes through more f16 slot arithmetic; `fitRatio`,
        /// after this, checks those on the real layout.
        pub fn ratioAt(found: Divider, want: f32, bounds: Bounds, current: f16) f16 {
            const span: f32 = @floatFromInt(@max(1, splitExtent(found)));
            // A subtree already smaller than its minimum keeps its size
            // (`minExtent`), so the starting ratio lies in [lo, hi]; only
            // rounding can cross them, which leaves the ratio as is.
            if (!(bounds.lo <= bounds.hi)) return current;
            const lo_px = @round(bounds.lo * span);
            const hi_px = @round(bounds.hi * span);
            var ratio: f16 = @floatCast(std.math.clamp(want, bounds.lo, bounds.hi));
            if (@round(@as(f32, ratio) * span) > hi_px) ratio = std.math.nextAfter(f16, ratio, 0);
            if (@round(@as(f32, ratio) * span) < lo_px) ratio = std.math.nextAfter(f16, ratio, 1);
            const px = @round(@as(f32, ratio) * span);
            if (px < lo_px or px > hi_px) return current;
            return ratio;
        }

        /// A drag step's ratio: `want` held in `bounds` (`ratioAt`), then
        /// fitted to the real layout (`fitRatio`). The Host's drag and the
        /// tests take this one path.
        pub fn stepRatio(alloc: std.mem.Allocator, tree: *Tree, content: Rect, found: Divider, want: f32, bounds: Bounds, start_ratio: f16, min_px: i32) std.mem.Allocator.Error!f16 {
            const current = tree.nodes[found.handle.idx()].split.ratio;
            const at = ratioAt(found, want, bounds, current);
            return fitRatio(alloc, tree, content, found.handle, at, start_ratio, min_px);
        }

        /// `ratio`, unless laying the panes out at it leaves a pane under
        /// the split at `handle` short of its floor along the split's axis
        /// (`min_px`, or its size at `start_ratio` if that was smaller):
        /// then an f16 between `ratio` and `start_ratio` at which every pane
        /// fits (the start always does: its floors are its own sizes). The
        /// nearest one within `walk_steps` f16 steps of `ratio`; past them,
        /// the one a binary search ends on, which fits but need not be the
        /// nearest, since fitting is not monotone at the pixel scale (Opus
        /// on #689: from 0.999 on the 119-pane chain the search ends on
        /// 0.56641, where 0.60156 also fits). Measured on the real slots
        /// (`SplitTree.spatial` and the layout's rounding), so it holds at
        /// any depth: the bounds are ratios, and a pane deep in a chain goes
        /// through f16 slot arithmetic at every level. In CodeRabbit's case
        /// on #689 (11,866 px, one pane beside a chain of 118, the root at
        /// its upper bound) a chain pane came out at 39 px of a 40 px
        /// minimum. The tree keeps the ratio it had on entry.
        pub fn fitRatio(alloc: std.mem.Allocator, tree: *Tree, content: Rect, handle: Handle, ratio: f16, start_ratio: f16, min_px: i32) std.mem.Allocator.Error!f16 {
            if (handle.idx() >= tree.nodes.len) return ratio;
            const axis = switch (tree.nodes[handle.idx()]) {
                .leaf => return ratio,
                .split => |s| s.layout,
            };
            // The search below orders ratios by their bits, where -0 (0x8000)
            // is above them all: the search's endpoints are +0 for either
            // zero (Sol on #689: a -0 start probed 34.3 and `spatial`
            // asserted). The caller keeps its own start for an Esc.
            const from = Tree.canonicalRatio(start_ratio);
            const entry = tree.nodes[handle.idx()].split.ratio;
            defer tree.resizeInPlace(handle, entry);
            tree.resizeInPlace(handle, from);
            var start = try tree.spatial(alloc);
            defer start.deinit(alloc);
            // Walk toward the start one f16 at a time: the nearest ratio that
            // fits. Fitting is not monotone at the scale of a pixel (a deep
            // chain's rounding: a binary search alone stopped a drag at
            // 0.566 where 0.5995 fits), so the walk is what is exact; it
            // usually takes a step or two.
            var candidate = Tree.canonicalRatio(ratio);
            var steps: usize = 0;
            while (candidate != from) : (steps += 1) {
                if (try fitsAt(alloc, tree, start, content, handle, axis, candidate, min_px)) return candidate;
                if (steps == walk_steps) break;
                candidate = Tree.canonicalRatio(std.math.nextAfter(f16, candidate, from));
            }
            if (candidate == from) return from;
            // A long way to go (a split a few pixels across): a binary search
            // for the rest, between the walk's last candidate, tested and
            // failing, and the start, which fits, so it always ends on a
            // ratio that fits.
            // Ratios are in [0, 1], where an f16's bits order as its value
            // (+0 is 0; both endpoints are canonical above).
            var failing: i32 = @as(u16, @bitCast(candidate));
            var fitting: i32 = @as(u16, @bitCast(from));
            while (@abs(fitting - failing) > 1) {
                const middle = failing + @divTrunc(fitting - failing, 2);
                const probe: f16 = @bitCast(@as(u16, @intCast(middle)));
                if (try fitsAt(alloc, tree, start, content, handle, axis, probe, min_px)) fitting = middle else failing = middle;
            }
            return @bitCast(@as(u16, @intCast(fitting)));
        }

        /// How far `fitRatio` walks before it searches.
        const walk_steps = 256;

        fn fitsAt(alloc: std.mem.Allocator, tree: *Tree, start: Spatial, content: Rect, handle: Handle, axis: Layout, candidate: f16, min_px: i32) std.mem.Allocator.Error!bool {
            tree.resizeInPlace(handle, candidate);
            var now = try tree.spatial(alloc);
            defer now.deinit(alloc);
            return leavesFit(tree, now, start, content, handle, axis, min_px);
        }

        fn leavesFit(tree: *const Tree, now: Spatial, start: Spatial, content: Rect, handle: Handle, axis: Layout, min_px: i32) bool {
            if (handle.idx() >= tree.nodes.len or handle.idx() >= now.slots.len or handle.idx() >= start.slots.len) return true;
            return switch (tree.nodes[handle.idx()]) {
                .leaf => slotPixels(content, now.slots[handle.idx()], axis) >=
                    @min(min_px, slotPixels(content, start.slots[handle.idx()], axis)),
                .split => |s| leavesFit(tree, now, start, content, s.left, axis, min_px) and
                    leavesFit(tree, now, start, content, s.right, axis, min_px),
            };
        }

        /// A slot's extent along `axis` in pixels, rounded as the layout
        /// rounds a pane's width or height and clamped to the content's far
        /// edges, as `win32_layout.splitSurfacePlacement` clamps the pane:
        /// a pane's rounding can reach a pixel past the content, which the
        /// layout takes off (Opus on #689: 39 px panes at the far edge).
        fn slotPixels(content: Rect, slot: anytype, axis: Layout) i32 {
            var rect = slotRect(content, slot);
            rect.right = @min(rect.right, content.right);
            rect.bottom = @min(rect.bottom, content.bottom);
            return switch (axis) {
                .horizontal => rect.right - rect.left,
                .vertical => rect.bottom - rect.top,
            };
        }

        /// The ratio that puts `found`'s divider at `along` (a pixel on the
        /// split's axis, in content coordinates): `ratioBounds` and `ratioAt`
        /// on the layout as it is. A drag moves by the pointer's distance
        /// from the press instead (`Host.dragPaneDivider`), which keeps the
        /// starting ratio exactly when the pointer has not moved.
        /// No production caller: the drag goes through `stepRatio`. This is
        /// the tested pure form of its first two steps (`ratioBounds`, then
        /// `ratioAt`) for an absolute pointer pixel, which the tests here
        /// pin those steps through; the third, `fitRatio`, has its own
        /// tests through `stepRatio` (Muse on #689).
        pub fn dragRatio(tree: *const Tree, spatial: Spatial, content: Rect, found: Divider, along: i32, min_px: i32) ?f16 {
            const bounds = ratioBounds(tree, spatial, content, found, min_px) orelse return null;
            const start = switch (found.layout) {
                .horizontal => found.split.left,
                .vertical => found.split.top,
            };
            const span: f32 = @floatFromInt(bounds.extent);
            const want = @as(f32, @floatFromInt(along - start)) / span;
            return ratioAt(found, want, bounds, tree.nodes[found.handle.idx()].split.ratio);
        }

        pub const Bounds = struct {
            lo: f32,
            hi: f32,
            /// The split's extent along its axis the bounds were measured at.
            extent: i32,
            /// The minimum pane, in pixels, they were measured with: it
            /// changes with the DPI while the extent may not.
            min_px: i32,
        };

        /// The split's extent along its axis, in pixels.
        pub fn splitExtent(found: Divider) i32 {
            return switch (found.layout) {
                .horizontal => found.split.right - found.split.left,
                .vertical => found.split.bottom - found.split.top,
            };
        }

        /// The smallest extent along `axis` the subtree at `handle` can take
        /// without any pane in it getting smaller than `min_px`, given the
        /// ratios inside it (a drag of an outer divider scales them all). A
        /// pane that is already smaller counts at its size in `spatial`, so a
        /// layout the keyboard made does not block a drag. The shares are
        /// f32 while the slots are f16, so the result can miss the start by
        /// a hair; `ratioBounds` keeps the start inside the bounds.
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

        /// The ratio `SplitTree.equalize` gives the split at `handle`, from
        /// the same `SplitTree.weight`: its sides weighted by their panes
        /// along its axis. Double-clicking a divider applies it to that one
        /// split.
        pub fn equalRatio(tree: *const Tree, handle: Handle) ?f16 {
            if (handle.idx() >= tree.nodes.len) return null;
            const s = switch (tree.nodes[handle.idx()]) {
                .leaf => return null,
                .split => |s| s,
            };
            const first: f32 = @floatFromInt(tree.weight(s.left, s.layout, 0));
            const second: f32 = @floatFromInt(tree.weight(s.right, s.layout, 0));
            return @floatCast(first / (first + second));
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

/// Every pane's laid-out width in `content`, rounded as the layout rounds it.
fn expectPanesAtLeast(tree: *const TestTree, content: Rect, min: i32) !void {
    var spatial = try tree.spatial(testing.allocator);
    defer spatial.deinit(testing.allocator);
    var it = tree.iterator();
    while (it.next()) |entry| {
        const slot = spatial.slots[entry.handle.idx()];
        const width = win32_layout.roundedSlotPixel(@floatCast(slot.width), content.width());
        if (width < min) {
            std.debug.print("pane {s} is {d} px, under {d}\n", .{ entry.view.label, width, min });
            return error.TestPaneUnderMinimum;
        }
    }
}

test "pane divider: the minimum holds after the ratio is rounded to f16" {
    // 3840 px at 96 DPI: the bound 1 - 40/3840 = 0.98958 has no f16; the
    // nearest one, 0.98975, would leave the right pane 39 px.
    const wide: Rect = .{ .left = 0, .top = 0, .right = 3840, .bottom = 600 };
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    // Three panes, [A | (B | C)]: the slots go through a division by 3.
    var three_views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var three = try buildTree(&three_views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer three.deinit();
    {
        var inserted = try TestTree.init(testing.allocator, &three_views[2]);
        defer inserted.deinit();
        const next = try three.split(testing.allocator, handleOfView(&three, "B"), .right, 0.5, &inserted);
        three.deinit();
        three = next;
    }
    for ([_]*TestTree{ &tree, &three }) |subject| {
        for ([_]i32{ 4000, -100 }) |along| {
            var spatial = try subject.spatial(testing.allocator);
            const found = Dividers.divider(subject, spatial, wide, .root, 3).?;
            const ratio = Dividers.dragRatio(subject, spatial, wide, found, along, 40).?;
            spatial.deinit(testing.allocator);
            subject.resizeInPlace(.root, ratio);
            try expectPanesAtLeast(subject, wide, 40);
            // Still at the bound, not stepped far from it: within 2 px.
            const reach: f32 = if (along > 0) @as(f32, ratio) else 1 - @as(f32, ratio);
            try testing.expect(reach * 3840 > 3840 - (if (subject == &tree) @as(f32, 40) else @as(f32, 80)) - 3);
            subject.resizeInPlace(.root, 0.5);
        }
    }
}

test "pane divider: the minimum holds after the ratio is rounded to f16, stacked" {
    // A stacked split 3840 px tall: the same rounding, measured in heights.
    const tall: Rect = .{ .left = 0, .top = 0, .right = 600, .bottom = 3840 };
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .down, .ratio = 0.5 }});
    defer tree.deinit();
    for ([_]i32{ 4000, -100 }) |along| {
        var spatial = try tree.spatial(testing.allocator);
        const found = Dividers.divider(&tree, spatial, tall, .root, 3).?;
        const ratio = Dividers.dragRatio(&tree, spatial, tall, found, along, 40).?;
        spatial.deinit(testing.allocator);
        tree.resizeInPlace(.root, ratio);
        var after = try tree.spatial(testing.allocator);
        defer after.deinit(testing.allocator);
        var it = tree.iterator();
        while (it.next()) |entry| {
            const height = win32_layout.roundedSlotPixel(@floatCast(after.slots[entry.handle.idx()].height), tall.height());
            try testing.expect(height >= 40);
        }
        tree.resizeInPlace(.root, 0.5);
    }
}

test "pane divider: no pane of a nested split rounds under its floor at the bounds" {
    // `ratioAt` alone, on shallow trees: sweeps of 942,648 placements
    // (three nested shapes, inner ratios 1/3 to 0.7, outer starts 0.2 to
    // 0.8, side by side and stacked, 200 to 4000 px, both bounds) found no
    // pane under its floor (40 px, or its size at the press if smaller);
    // this keeps a sample of them. Deeper trees can (the deep-chain test
    // below), which `fitRatio` covers.
    const ratios = [_]f16{ 0.5, 0.3, 0.7, 1.0 / 3.0 };
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    for ([_]TestTree.Split.Direction{ .right, .down }) |dir| for (0..2) |shape| for (ratios) |inner| {
        var tree = try buildTree(views[0..2], &.{.{ .at = .root, .direction = dir, .ratio = 0.5 }});
        defer tree.deinit();
        {
            var inserted = try TestTree.init(testing.allocator, &views[2]);
            defer inserted.deinit();
            const at = if (shape == 1) handleOfView(&tree, "A") else handleOfView(&tree, "B");
            const next = try tree.split(testing.allocator, at, dir, inner, &inserted);
            tree.deinit();
            tree = next;
        }
        var span: i32 = 200;
        while (span <= 4000) : (span += 37) {
            const content: Rect = if (dir == .right) .{ .left = 0, .top = 0, .right = span, .bottom = 300 } else .{ .left = 0, .top = 0, .right = 300, .bottom = span };
            for ([_]i32{ -100000, 100000 }) |along| {
                tree.resizeInPlace(.root, 0.5);
                var start = try tree.spatial(testing.allocator);
                defer start.deinit(testing.allocator);
                const d = Dividers.divider(&tree, start, content, .root, 3).?;
                tree.resizeInPlace(.root, Dividers.dragRatio(&tree, start, content, d, along, 40).?);
                var now = try tree.spatial(testing.allocator);
                defer now.deinit(testing.allocator);
                var it = tree.iterator();
                while (it.next()) |e| {
                    const axis_now: f16 = if (dir == .right) now.slots[e.handle.idx()].width else now.slots[e.handle.idx()].height;
                    const axis_start: f16 = if (dir == .right) start.slots[e.handle.idx()].width else start.slots[e.handle.idx()].height;
                    const px_now = win32_layout.roundedSlotPixel(@floatCast(axis_now), span);
                    const px_start = win32_layout.roundedSlotPixel(@floatCast(axis_start), span);
                    try testing.expect(px_now >= @min(40, px_start));
                }
            }
        }
    };
}

test "pane divider: a deep chain keeps every pane at its floor at the bound (CodeRabbit's case)" {
    // 11,866 px: one pane on the left of the root and a chain of 118 on
    // the right, the chain's split i giving its left side f16(1/(118 - i))
    // so the 118 panes are equal (about 50 px). Dragging the root to its
    // upper bound brings them to 40 px nominal, through 118 levels of f16
    // slot arithmetic.
    const alloc = testing.allocator;
    var labels = std.heap.ArenaAllocator.init(alloc);
    defer labels.deinit();
    const views = try alloc.alloc(TestView, 119);
    defer alloc.free(views);
    var tree = try buildChain(alloc, labels.allocator(), views);
    defer tree.deinit();
    var panes: usize = 0;
    var counting = tree.iterator();
    while (counting.next()) |_| panes += 1;
    try testing.expectEqual(@as(usize, 119), panes);

    const content: Rect = .{ .left = 0, .top = 0, .right = 11866, .bottom = 600 };
    var start = try tree.spatial(alloc);
    defer start.deinit(alloc);
    const found = Dividers.divider(&tree, start, content, .root, 3).?;
    const bounds = Dividers.ratioBounds(&tree, start, content, found, 40).?;
    const dragged = Dividers.dragRatio(&tree, start, content, found, 20000, 40).?;
    const ratio = try Dividers.stepRatio(alloc, &tree, content, found, 2.0, bounds, 0.5, 40);
    tree.resizeInPlace(.root, ratio);
    var now = try tree.spatial(alloc);
    defer now.deinit(alloc);
    var short: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        const px_now = win32_layout.roundedSlotPixel(@floatCast(now.slots[entry.handle.idx()].width), content.width());
        const px_start = win32_layout.roundedSlotPixel(@floatCast(start.slots[entry.handle.idx()].width), content.width());
        if (px_now < @min(40, px_start)) {
            if (short == 0) std.debug.print("deep chain: a pane is {d} px (was {d}) at root ratio {d} (dragged {d})\n", .{ px_now, px_start, @as(f32, ratio), @as(f32, dragged) });
            short += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), short);
}

test "pane divider: a starting ratio of -0 fits as +0 does" {
    // Sol on #689: a saved layout may say "ratio": -0.0 (validation takes
    // it, since -0 < 0 is false), and an f16 -0 is 0x8000, so the fit's
    // bit search between it and a ratio near 1 probed 34.3 and `spatial`
    // asserted. One pane at ratio 0 beside the 118-pane chain, dragged to
    // the upper bound (past 256 f16 steps, so the search runs), on Sol's
    // 4774 px and a sample of 300 to 12,000 px; +0 is the control.
    const alloc = testing.allocator;
    var labels = std.heap.ArenaAllocator.init(alloc);
    defer labels.deinit();
    const views = try alloc.alloc(TestView, 119);
    defer alloc.free(views);
    var tree = try buildChain(alloc, labels.allocator(), views);
    defer tree.deinit();
    const negative_zero: f16 = @bitCast(@as(u16, 0x8000));
    var widths: [32]i32 = undefined;
    widths[0] = 4774;
    for (widths[1..], 0..) |*width, i| width.* = 300 + @as(i32, @intCast(i)) * 377;
    for (widths) |width| {
        const content: Rect = .{ .left = 0, .top = 0, .right = width, .bottom = 600 };
        var fitted: [2]f16 = undefined;
        for ([_]f16{ 0, negative_zero }, 0..) |zero, i| {
            tree.resizeInPlace(.root, zero);
            var start = try tree.spatial(alloc);
            defer start.deinit(alloc);
            const found = Dividers.divider(&tree, start, content, .root, 3).?;
            const bounds = Dividers.ratioBounds(&tree, start, content, found, 40).?;
            fitted[i] = try Dividers.stepRatio(alloc, &tree, content, found, 2.0, bounds, zero, 40);
            try testing.expect(fitted[i] >= 0 and fitted[i] <= 1);
            tree.resizeInPlace(.root, fitted[i]);
            var now = try tree.spatial(alloc);
            defer now.deinit(alloc);
            var it = tree.iterator();
            while (it.next()) |entry| {
                const px_now = win32_layout.roundedSlotPixel(@floatCast(now.slots[entry.handle.idx()].width), width);
                const px_start = win32_layout.roundedSlotPixel(@floatCast(start.slots[entry.handle.idx()].width), width);
                try testing.expect(px_now >= @min(40, px_start));
            }
        }
        try testing.expectEqual(@as(u16, @bitCast(fitted[0])), @as(u16, @bitCast(fitted[1])));
    }
    // A candidate of -0 (a lower bound of -0 from that start) searches
    // from +0 as well: dragged down from the chain's bound, it lands where
    // the +0 candidate does.
    const content: Rect = .{ .left = 0, .top = 0, .right = 4774, .bottom = 600 };
    tree.resizeInPlace(.root, 0.5);
    const from_positive = try Dividers.fitRatio(alloc, &tree, content, .root, 0, 0.5, 40);
    const from_negative = try Dividers.fitRatio(alloc, &tree, content, .root, negative_zero, 0.5, 40);
    try testing.expectEqual(@as(u16, @bitCast(from_positive)), @as(u16, @bitCast(from_negative)));
}

test "pane divider: the walk finds a long chain's fit that the search alone stops short of" {
    // Opus on #689: one pane beside a chain of 300 at 30,000 px, dragged
    // to the root's upper bound. The walk ends on 0.58887; with a walk of
    // one step (`walk_steps = 1`) the search took over and stopped at
    // 0.50195, 2,607 px short, since fitting is not monotone.
    const alloc = testing.allocator;
    var labels = std.heap.ArenaAllocator.init(alloc);
    defer labels.deinit();
    const views = try alloc.alloc(TestView, 301);
    defer alloc.free(views);
    var tree = try buildChain(alloc, labels.allocator(), views);
    defer tree.deinit();
    const content: Rect = .{ .left = 0, .top = 0, .right = 30000, .bottom = 600 };
    var start = try tree.spatial(alloc);
    defer start.deinit(alloc);
    const found = Dividers.divider(&tree, start, content, .root, 3).?;
    const bounds = Dividers.ratioBounds(&tree, start, content, found, 40).?;
    const ratio = try Dividers.stepRatio(alloc, &tree, content, found, 2.0, bounds, 0.5, 40);
    try testing.expectApproxEqAbs(@as(f32, 0.58887), @as(f32, ratio), 0.0001);
}

test "pane divider: the walk's last candidate is tested before the search" {
    // Opus on #689: two panes at 800 px, from 256 f16 steps below the
    // first ratio at which A fits (0x2a52). The walk's 257th candidate is
    // that ratio; taking it as failing without testing it, the search
    // returned the next one up (0x2a53).
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    const below: f16 = @bitCast(@as(u16, 0x2a52 - 256));
    const fitted = try Dividers.fitRatio(testing.allocator, &tree, content_800x600, .root, below, 0.5, 40);
    try testing.expectEqual(@as(u16, 0x2a52), @as(u16, @bitCast(fitted)));
}

/// One pane left of the root and a chain of `views.len - 2` on its right,
/// the chain's split i giving its left side f16(1/(n - i)), so the chain's
/// panes are equal (CodeRabbit's shape on #689).
fn buildChain(alloc: std.mem.Allocator, label_alloc: std.mem.Allocator, views: []TestView) !TestTree {
    for (views, 0..) |*view, i| view.* = .{ .label = try std.fmt.allocPrint(label_alloc, "P{d}", .{i}) };
    var tree = try TestTree.init(alloc, &views[0]);
    errdefer tree.deinit();
    {
        var first = try TestTree.init(alloc, &views[1]);
        defer first.deinit();
        const next = try tree.split(alloc, .root, .right, 0.5, &first);
        tree.deinit();
        tree = next;
    }
    const chain = views.len - 1;
    var last = handleOfView(&tree, views[1].label);
    for (0..chain - 1) |i| {
        var inserted = try TestTree.init(alloc, &views[i + 2]);
        defer inserted.deinit();
        const left_share: f16 = @floatCast(1.0 / @as(f32, @floatFromInt(chain - i)));
        const next = try tree.split(alloc, last, .right, left_share, &inserted);
        tree.deinit();
        tree = next;
        last = handleOfView(&tree, views[i + 2].label);
    }
    return tree;
}

test "pane divider: a pane at the content's far edge keeps its floor as the layout places it" {
    // The layout clamps a pane to the content's far edge
    // (`win32_layout.splitSurfacePlacement`), where its slot's own rounding
    // can reach one pixel past it. [A | (B | C)] with the root at its upper
    // bound, every width from 900 to 4000 px: each pane as the layout
    // places it, with its pixels of the gap, keeps its floor (C, at the far
    // edge, came out at 39 px from 950 px on).
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var tree = try buildTree(views[0..2], &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    {
        var inserted = try TestTree.init(testing.allocator, &views[2]);
        defer inserted.deinit();
        const next = try tree.split(testing.allocator, handleOfView(&tree, "B"), .right, 0.5, &inserted);
        tree.deinit();
        tree = next;
    }
    // Stacked, [A / (B / C)] over the same heights: the bottom edge's clamp
    // (Opus on #689: each guard is checked from both sides).
    var stacked_views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" } };
    var stacked = try buildTree(stacked_views[0..2], &.{.{ .at = .root, .direction = .down, .ratio = 0.5 }});
    defer stacked.deinit();
    {
        var inserted = try TestTree.init(testing.allocator, &stacked_views[2]);
        defer inserted.deinit();
        const next = try stacked.split(testing.allocator, handleOfView(&stacked, "B"), .down, 0.5, &inserted);
        stacked.deinit();
        stacked = next;
    }
    for ([_]*TestTree{ &tree, &stacked }) |subject| {
        const across = subject == &tree;
        var short: usize = 0;
        var span: i32 = 900;
        while (span <= 4000) : (span += 1) {
            const content: Rect = if (across) .{ .left = 0, .top = 0, .right = span, .bottom = 300 } else .{ .left = 0, .top = 0, .right = 300, .bottom = span };
            subject.resizeInPlace(.root, 0.5);
            var start = try subject.spatial(testing.allocator);
            defer start.deinit(testing.allocator);
            const found = Dividers.divider(subject, start, content, .root, 3).?;
            const bounds = Dividers.ratioBounds(subject, start, content, found, 40).?;
            const ratio = try Dividers.stepRatio(testing.allocator, subject, content, found, 2.0, bounds, 0.5, 40);
            subject.resizeInPlace(.root, ratio);
            var now = try subject.spatial(testing.allocator);
            defer now.deinit(testing.allocator);
            var it = subject.iterator();
            while (it.next()) |entry| {
                const slot = now.slots[entry.handle.idx()];
                const placed = win32_layout.splitSurfacePlacement(content, .{
                    .x = @floatCast(slot.x),
                    .y = @floatCast(slot.y),
                    .width = @floatCast(slot.width),
                    .height = @floatCast(slot.height),
                }, true, false, 0).pane_rect;
                const pixels = if (across)
                    placed.width() + @as(i32, @intFromBool(placed.left > content.left)) + @intFromBool(placed.right < content.right)
                else
                    placed.height() + @as(i32, @intFromBool(placed.top > content.top)) + @intFromBool(placed.bottom < content.bottom);
                if (pixels < 40) short += 1;
            }
        }
        if (short != 0) std.debug.print("far edge: {d} short panes ({s})\n", .{ short, if (across) "side by side" else "stacked" });
        try testing.expectEqual(@as(usize, 0), short);
    }
}

test "pane divider: a 1 px drag toward a pane under the minimum never moves the divider away, on either side" {
    // Opus's tree on #689, A | ((B | D)@0.25 | C)@0.04, and its mirror,
    // (C | (D | B)@0.75)@0.96 | A, side by side and stacked, 400 to 8000
    // px: B is under the minimum beside the root's divider, right of it or
    // left. Dragged 1 px toward B, the divider stays or follows; before
    // the bounds kept the start, it could step away (3 px on 5314 px).
    var backward: usize = 0;
    for ([_]bool{ false, true }) |mirrored| for ([_]bool{ true, false }) |across| for ([_]f16{ 0.4, 0.5, 0.6 }) |root| {
        var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" }, .{ .label = "C" }, .{ .label = "D" } };
        const toward_b: TestTree.Split.Direction = if (across)
            (if (mirrored) .left else .right)
        else
            (if (mirrored) .up else .down);
        const share = struct {
            fn of(ratio: f16, flip: bool) f16 {
                return if (flip) 1 - ratio else ratio;
            }
        }.of;
        var tree = try buildTree(views[0..2], &.{.{ .at = .root, .direction = toward_b, .ratio = share(root, mirrored) }});
        defer tree.deinit();
        for ([_]struct { label: usize, ratio: f16 }{ .{ .label = 2, .ratio = 0.04 }, .{ .label = 3, .ratio = 0.25 } }) |step| {
            var inserted = try TestTree.init(testing.allocator, &views[step.label]);
            defer inserted.deinit();
            const next = try tree.split(testing.allocator, handleOfView(&tree, "B"), toward_b, share(step.ratio, mirrored), &inserted);
            tree.deinit();
            tree = next;
        }
        const start_ratio = tree.nodes[0].split.ratio;
        var span: i32 = 400;
        while (span <= 8000) : (span += 3) {
            const content: Rect = if (across) .{ .left = 0, .top = 0, .right = span, .bottom = 300 } else .{ .left = 0, .top = 0, .right = 300, .bottom = span };
            tree.resizeInPlace(.root, start_ratio);
            var start = try tree.spatial(testing.allocator);
            defer start.deinit(testing.allocator);
            const found = Dividers.divider(&tree, start, content, .root, 3).?;
            const bounds = Dividers.ratioBounds(&tree, start, content, found, 40).?;
            const step: f32 = (if (mirrored) @as(f32, -1) else 1) / @as(f32, @floatFromInt(span));
            const ratio = try Dividers.stepRatio(testing.allocator, &tree, content, found, @as(f32, start_ratio) + step, bounds, start_ratio, 40);
            tree.resizeInPlace(.root, ratio);
            var now = try tree.spatial(testing.allocator);
            defer now.deinit(testing.allocator);
            const moved = Dividers.divider(&tree, now, content, .root, 3).?.position - found.position;
            if (if (mirrored) moved > 0 else moved < 0) {
                if (backward == 0) std.debug.print("backward: mirrored={} across={} root={d} span={d} moved={d}\n", .{ mirrored, across, @as(f32, root), span, moved });
                backward += 1;
            }
        }
    };
    try testing.expectEqual(@as(usize, 0), backward);
}

test "pane divider: past the walk, the search ends on a ratio that fits next to one that does not" {
    // Two panes at 800 px, from 0.5 down to 0.001: 256 f16 steps from
    // 0.001 reach about 0.0012, so the binary search finds the rest. It
    // must end on the side that fits (A at 40 px), not on the start
    // (400 px) and not on the side that does not (39 px). Opus on #689:
    // no test reached the search half.
    var views = [_]TestView{ .{ .label = "A" }, .{ .label = "B" } };
    var tree = try buildTree(&views, &.{.{ .at = .root, .direction = .right, .ratio = 0.5 }});
    defer tree.deinit();
    const fitted = try Dividers.fitRatio(testing.allocator, &tree, content_800x600, .root, 0.001, 0.5, 40);
    try testing.expectEqual(@as(f16, 0.5), tree.nodes[0].split.ratio);
    try testing.expectEqual(@as(i32, 40), win32_layout.roundedSlotPixel(@as(f32, fitted), 800));
    // From 0.999 the walk (2^-11 a step near 1) reaches B's 40 px itself.
    const far = try Dividers.fitRatio(testing.allocator, &tree, content_800x600, .root, 0.999, 0.5, 40);
    try testing.expectEqual(@as(i32, 760), win32_layout.roundedSlotPixel(@as(f32, far), 800));
}

test "pane divider: a pane already below the minimum keeps its size" {
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
