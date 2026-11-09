//! Where a tab dragged out of its tab strip goes (tab tear-off). Pure: the
//! Win32 side measures the pointer, the windows under it and their tab
//! strips (`App.tabStripTargetAt`, `Host.tabStripScreenRect`), and this decides.
//!
//! A drag starts as today's reorder inside the strip and, for a tab behind
//! the front one, a drop into a split of the front tab
//! (`win32_tab_drop_zones`). It becomes a tear-off once the pointer leaves
//! the strip's band (`leavesStrip`) or the window, and a move into another
//! window while it is over that window's strip. A window's only tab moves
//! the window instead (`movesWindow`), and joins another window's strip
//! where the window move ends over it.
const std = @import("std");

/// What a drop at the pointer would do.
pub const Target = union(enum) {
    /// Inside the source window: the reorder or split drop already there.
    stay,
    /// A new window holding the tab, where it was dropped.
    new_window,
    /// Another window of this process, at `index` in its tab strip.
    window: Over,
};

/// Another window's tab strip under the pointer: the window, and where in
/// its strip the tab would go.
pub const Over = struct { host_id: u32, index: usize };

pub const Input = struct {
    /// Tabs in the source window, the dragged one included.
    tab_count: usize,
    /// The source is the quick terminal, whose tabs stay in it.
    quick_terminal: bool = false,
    /// The pointer is inside the source window.
    inside_source: bool,
    /// The pointer is past the strip's band (`leavesStrip`).
    outside_strip: bool,
    /// The pointer is over a split drop zone of the front tab.
    split_zone: bool = false,
    /// The pointer is over another window's tab strip.
    over: ?Over = null,
};

pub fn decide(input: Input) Target {
    if (input.quick_terminal or input.tab_count == 0) return .stay;
    if (input.over) |over| return .{ .window = over };
    // The only tab has nowhere new to go: its window moves with it instead.
    if (input.tab_count == 1) return .stay;
    if (input.inside_source and (!input.outside_strip or input.split_zone)) return .stay;
    return .new_window;
}

/// Whether a drag of a window's only tab hands over to the system's window
/// move (Windows Terminal's behaviour), once it passes the drag threshold.
pub fn movesWindow(tab_count: usize, quick_terminal: bool) bool {
    return tab_count == 1 and !quick_terminal;
}

pub const Size = struct { width: i32, height: i32 };

/// A rect's edges, in screen coordinates.
pub const Edges = struct { left: i32, top: i32, right: i32, bottom: i32 };

/// Whether the window is snapped: `IsWindowArranged`'s answer where Windows
/// has it (`api`), else whether the move ended looking snapped (`looks`,
/// `looksSnapped`) at a size it did not keep (`kept`, `keptSize`): a plain
/// move keeps its size, so a window sized by hand to the full height against
/// a side is not taken for a Snap Fill (CodeRabbit r4509693771). Across
/// DPIs (`dpi_changed`) the kept size is the rescaled one, which a snap zone
/// can come within the slack of (CodeRabbit r4510086538): there a rect that
/// looks snapped is a snap whatever its size, and such a plain move does not
/// merge. That errs toward keeping the window, on these builds only. The
/// rect is never asked where the API answers: a plain move against an edge
/// looks snapped and would decline a merge for nothing.
pub fn snapped(api: ?bool, looks: bool, kept: bool, dpi_changed: bool) bool {
    return api orelse (looks and (!kept or dpi_changed));
}

/// Whether a window ended its move at the size it moved at (`at`, at
/// `at_dpi`), scaled to the DPI it ended at, each side within `slack`: a
/// plain move, onto another monitor or not. Windows rescales a window that
/// moves onto a monitor of another DPI; the move loop changes its size no
/// other way but a snap or a maximize.
pub fn keptSize(at: Size, at_dpi: u32, end: Size, end_dpi: u32, slack: i32) bool {
    if (at_dpi == 0 or end_dpi == 0) return at.width == end.width and at.height == end.height;
    const from: i32 = @intCast(at_dpi);
    const to: i32 = @intCast(end_dpi);
    const width = @divTrunc(at.width * to + @divTrunc(from, 2), from);
    const height = @divTrunc(at.height * to + @divTrunc(from, 2), from);
    return @abs(end.width - width) <= slack and @abs(end.height - height) <= slack;
}

/// Whether a window rect sits as Windows 10's Snap leaves one (it has no
/// `IsWindowArranged` before later builds): against a side of its monitor's
/// work area and its top or bottom, half its width wide, and its full or
/// half height tall (a half or a quarter snap), each within `slack` (the
/// frame's invisible resize border) and twice that for the size; or against
/// a side and both its top and bottom at any width, as Snap Fill and a
/// resize of two snapped windows along their shared border leave one.
pub fn looksSnapped(window: Edges, work: Edges, slack: i32) bool {
    const near = struct {
        fn f(a: i32, b: i32, s: i32) bool {
            return @abs(a - b) <= s;
        }
    }.f;
    const side = near(window.left, work.left, slack) or near(window.right, work.right, slack);
    const top = near(window.top, work.top, slack);
    const bottom = near(window.bottom, work.bottom, slack);
    if (side and top and bottom) return true;
    const end = top or bottom;
    const width = window.right - window.left;
    const height = window.bottom - window.top;
    const work_width = work.right - work.left;
    const work_height = work.bottom - work.top;
    const half_wide = near(width, @divTrunc(work_width, 2), 2 * slack);
    const tall = near(height, work_height, 2 * slack) or near(height, @divTrunc(work_height, 2), 2 * slack);
    return side and end and half_wide and tall;
}

/// Whether the window move changed the window's size: against the size it
/// moved at (`moving`, after a snapped or maximized window took back its
/// normal size as the move began), else against the size it started at.
pub fn moveResized(start: Size, moving: ?Size, end: Size) bool {
    const at = moving orelse start;
    return at.width != end.width or at.height != end.height;
}

/// How the window move an only tab started ended (`App.finishOnlyTabWindowMove`).
pub const WindowMoveEnd = struct {
    /// The window's top-left moved (an Esc puts it back where it was).
    moved: bool,
    /// Its size changed: a snap, unless its DPI changed with the monitor.
    resized: bool,
    dpi_changed: bool,
    /// Maximized: a drag to the top edge.
    zoomed: bool,
    /// Snapped: half, quarter or a Snap Layouts zone (`IsWindowArranged`).
    arranged: bool,
    /// The pointer is over another window's tab strip.
    over_strip: bool,
};

/// Whether the tab joins the strip the move ended over. A move that snapped
/// or maximized the window was that, not a drop, wherever the pointer is.
pub fn windowMoveMerges(end: WindowMoveEnd) bool {
    if (!end.over_strip or !end.moved) return false;
    if (end.zoomed or end.arranged) return false;
    if (end.resized and !end.dpi_changed) return false;
    return true;
}

/// Whether a pointer at client `y` has left the tab strip's band
/// `[top, bottom)` by more than `margin`, the slack a drag along the strip
/// gets before it tears off.
pub fn leavesStrip(y: i32, top: i32, bottom: i32, margin: i32) bool {
    return y < top - margin or y >= bottom + margin;
}

/// A tab button's horizontal extent in screen coordinates and the tab's
/// index in its strip.
pub const Button = struct { index: usize, left: i32, right: i32 };

/// Where a tab dropped at screen `x` goes in a strip of `tab_count` tabs
/// whose visible buttons are `buttons`, left to right: before the first
/// button whose middle is right of `x`, else after the last visible one.
/// With no visible button it goes at the end.
pub fn insertIndex(buttons: []const Button, x: i32, tab_count: usize) usize {
    var scan: InsertScan = .{ .x = x, .tab_count = tab_count };
    for (buttons) |button| if (scan.add(button)) |index| return index;
    return scan.end();
}

/// `insertIndex` one button at a time, left to right, with no list: a wide
/// strip can show any number of tabs.
pub const InsertScan = struct {
    x: i32,
    tab_count: usize,
    last: ?usize = null,

    /// The index, once a button's middle is right of the pointer.
    pub fn add(self: *InsertScan, button: Button) ?usize {
        const middle = button.left + @divTrunc(button.right - button.left, 2);
        if (self.x < middle) return @min(button.index, self.tab_count);
        self.last = button.index;
        return null;
    }

    /// Past every button: after the last one shown, or at the end.
    pub fn end(self: *const InsertScan) usize {
        const last = self.last orelse return self.tab_count;
        return @min(last + 1, self.tab_count);
    }
};

pub const Offset = struct { x: i32, y: i32 };

/// Where the pointer sits in the new window, from its top-left, so the tab
/// lands under it there: the source window's frame (its client origin less
/// its window origin), the tab button's top, and where the pointer held the
/// button, its x held within `max_x`, about one tab's width, since the new
/// window's only tab is its first.
pub fn grabOffset(frame_x: i32, frame_y: i32, button_top: i32, held_x: i32, held_y: i32, max_x: i32) Offset {
    return .{
        .x = frame_x + std.math.clamp(held_x, 0, @max(0, max_x)),
        .y = frame_y + button_top + @max(0, held_y),
    };
}

test "a drag stays in its window along the strip and over a split zone, and tears off past the band or outside" {
    const Case = struct { input: Input, target: Target };
    for ([_]Case{
        // Along the strip, inside: today's reorder.
        .{ .input = .{ .tab_count = 3, .inside_source = true, .outside_strip = false }, .target = .stay },
        // Down into the window: a split zone of the front tab keeps the
        // split drop; elsewhere it tears off.
        .{ .input = .{ .tab_count = 3, .inside_source = true, .outside_strip = true, .split_zone = true }, .target = .stay },
        .{ .input = .{ .tab_count = 3, .inside_source = true, .outside_strip = true }, .target = .new_window },
        // Outside the window, at strip height or anywhere else.
        .{ .input = .{ .tab_count = 2, .inside_source = false, .outside_strip = false }, .target = .new_window },
        .{ .input = .{ .tab_count = 2, .inside_source = false, .outside_strip = true }, .target = .new_window },
        // Over another window's strip: into it, wherever the source is.
        .{ .input = .{ .tab_count = 2, .inside_source = false, .outside_strip = true, .over = .{ .host_id = 7, .index = 1 } }, .target = .{ .window = .{ .host_id = 7, .index = 1 } } },
        // The only tab: its window moves; it can still join another strip.
        .{ .input = .{ .tab_count = 1, .inside_source = false, .outside_strip = true }, .target = .stay },
        .{ .input = .{ .tab_count = 1, .inside_source = false, .outside_strip = true, .over = .{ .host_id = 2, .index = 0 } }, .target = .{ .window = .{ .host_id = 2, .index = 0 } } },
        // The quick terminal keeps its tabs.
        .{ .input = .{ .tab_count = 3, .quick_terminal = true, .inside_source = false, .outside_strip = true, .over = .{ .host_id = 2, .index = 0 } }, .target = .stay },
    }) |case| {
        try std.testing.expectEqualDeep(case.target, decide(case.input));
    }
    try std.testing.expect(movesWindow(1, false));
    try std.testing.expect(!movesWindow(1, true));
    try std.testing.expect(!movesWindow(2, false));
}

test "the only tab's window move joins another strip only as a plain move" {
    const plain: WindowMoveEnd = .{ .moved = true, .resized = false, .dpi_changed = false, .zoomed = false, .arranged = false, .over_strip = true };
    try std.testing.expect(windowMoveMerges(plain));
    const Case = struct { end: WindowMoveEnd, merges: bool };
    for ([_]Case{
        // Not over a strip, or not moved (Esc, or no move at all).
        .{ .end = .{ .moved = true, .resized = false, .dpi_changed = false, .zoomed = false, .arranged = false, .over_strip = false }, .merges = false },
        .{ .end = .{ .moved = false, .resized = false, .dpi_changed = false, .zoomed = false, .arranged = false, .over_strip = true }, .merges = false },
        // Maximized at the top edge, or snapped: that was the move.
        .{ .end = .{ .moved = true, .resized = true, .dpi_changed = false, .zoomed = true, .arranged = false, .over_strip = true }, .merges = false },
        .{ .end = .{ .moved = true, .resized = true, .dpi_changed = false, .zoomed = false, .arranged = true, .over_strip = true }, .merges = false },
        // Resized without `IsWindowArranged` to say so (Windows 10 before
        // it): a snap all the same.
        .{ .end = .{ .moved = true, .resized = true, .dpi_changed = false, .zoomed = false, .arranged = false, .over_strip = true }, .merges = false },
        // Onto a monitor of another DPI the size changes with it: a move.
        .{ .end = .{ .moved = true, .resized = true, .dpi_changed = true, .zoomed = false, .arranged = false, .over_strip = true }, .merges = true },
        // Snapped on a monitor of another DPI: still a snap.
        .{ .end = .{ .moved = true, .resized = true, .dpi_changed = true, .zoomed = false, .arranged = true, .over_strip = true }, .merges = false },
    }) |case| try std.testing.expectEqual(case.merges, windowMoveMerges(case.end));
}

test "a window move resizes only against the size it moved at" {
    const normal: Size = .{ .width = 800, .height = 600 };
    const maximized: Size = .{ .width = 1936, .height = 1056 };
    // A plain move.
    try std.testing.expect(!moveResized(normal, normal, normal));
    try std.testing.expect(!moveResized(normal, null, normal));
    // Out of a maximized or snapped window: restored as the move began,
    // and moved at that size, which is no resize at the end...
    try std.testing.expect(!moveResized(maximized, normal, normal));
    // ...so the tab still joins a strip the move ends over.
    try std.testing.expect(windowMoveMerges(.{ .moved = true, .resized = moveResized(maximized, normal, normal), .dpi_changed = false, .zoomed = false, .arranged = false, .over_strip = true }));
    // Snapped at the end: a resize from the size it moved at.
    try std.testing.expect(moveResized(normal, normal, .{ .width = 960, .height = 1032 }));
    // No move message (the loop never moved it): the start's size decides.
    try std.testing.expect(moveResized(maximized, null, normal));
}

test "a window against a side and the top or bottom of its work area looks snapped" {
    const work: Edges = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1032 };
    // Halves and quarters, with the frame's 7 px invisible border.
    try std.testing.expect(looksSnapped(.{ .left = -7, .top = 0, .right = 967, .bottom = 1039 }, work, 12));
    try std.testing.expect(looksSnapped(.{ .left = 953, .top = 0, .right = 1927, .bottom = 1039 }, work, 12));
    try std.testing.expect(looksSnapped(.{ .left = -7, .top = 516, .right = 967, .bottom = 1039 }, work, 12));
    // A window moved somewhere inside it, or only against one edge.
    try std.testing.expect(!looksSnapped(.{ .left = 300, .top = 200, .right = 1100, .bottom = 800 }, work, 12));
    // Plain moves into a corner, at a size of their own (council round 3).
    try std.testing.expect(!looksSnapped(.{ .left = -7, .top = 0, .right = 793, .bottom = 600 }, work, 12));
    try std.testing.expect(!looksSnapped(.{ .left = 3, .top = 8, .right = 803, .bottom = 608 }, work, 12));
    try std.testing.expect(!looksSnapped(.{ .left = 300, .top = 0, .right = 1100, .bottom = 600 }, work, 12));
    try std.testing.expect(!looksSnapped(.{ .left = -7, .top = 200, .right = 793, .bottom = 800 }, work, 12));
    // Snap Fill, or two snapped windows resized along the border they
    // share: full height against a side, at a width of its own (CodeRabbit
    // r4509329318).
    try std.testing.expect(looksSnapped(.{ .left = -7, .top = 0, .right = 647, .bottom = 1039 }, work, 12));
    try std.testing.expect(looksSnapped(.{ .left = 633, .top = 0, .right = 1927, .bottom = 1039 }, work, 12));
    // Full height away from both sides, or against a side and short of the
    // top: a size of its own.
    try std.testing.expect(!looksSnapped(.{ .left = 300, .top = 0, .right = 1100, .bottom = 1039 }, work, 12));
    try std.testing.expect(!looksSnapped(.{ .left = -7, .top = 60, .right = 647, .bottom = 1039 }, work, 12));
    // A cross-DPI snap on a build without `IsWindowArranged`: resized with
    // the DPI, so only this keeps it from merging.
    try std.testing.expect(!windowMoveMerges(.{
        .moved = true,
        .resized = true,
        .dpi_changed = true,
        .zoomed = false,
        .arranged = snapped(null, looksSnapped(.{ .left = -7, .top = 0, .right = 967, .bottom = 1039 }, work, 12), keptSize(.{ .width = 1200, .height = 900 }, 144, .{ .width = 974, .height = 1039 }, 96, 12), true),
        .over_strip = true,
    }));
}

test "a snap is IsWindowArranged's answer where it has one, the rect's only where it has none" {
    // Present and false: a plain move, whatever the rect looks like.
    try std.testing.expect(!snapped(false, true, false, false));
    try std.testing.expect(snapped(true, false, true, false));
    // Absent (Windows 10 builds): the rect decides, with the size the move
    // gave it.
    try std.testing.expect(snapped(null, true, false, false));
    try std.testing.expect(!snapped(null, false, false, false));
    try std.testing.expect(!snapped(null, true, true, false));
    // Across DPIs, a rect that looks snapped is a snap even at the kept
    // size; one that does not is a plain move.
    try std.testing.expect(snapped(null, true, true, true));
    try std.testing.expect(!snapped(null, false, true, true));
}

test "a window move that kept its size is a plain move however snapped it looks, one that took a zone's size a snap (CodeRabbit r4509693771)" {
    const work: Edges = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1032 };
    // Sized by hand to the full height, moved against the left side: it
    // looks like a Snap Fill and kept the size it moved at, so it merges.
    const tall: Edges = .{ .left = -7, .top = 0, .right = 893, .bottom = 1039 };
    try std.testing.expect(looksSnapped(tall, work, 12));
    const tall_size: Size = .{ .width = 900, .height = 1039 };
    try std.testing.expect(keptSize(tall_size, 96, tall_size, 96, 12));
    try std.testing.expect(windowMoveMerges(.{
        .moved = true,
        .resized = false,
        .dpi_changed = false,
        .zoomed = false,
        .arranged = snapped(null, looksSnapped(tall, work, 12), keptSize(tall_size, 96, tall_size, 96, 12), false),
        .over_strip = true,
    }));
    // The same window onto a 144 DPI monitor, rescaled there: still the size
    // it moved at, but a snap zone there can be within the slack of that
    // size, so against a side it does not merge (CodeRabbit r4510086538);
    // away from the sides it does.
    const scaled: Size = .{ .width = 1350, .height = 1559 };
    try std.testing.expect(keptSize(tall_size, 96, scaled, 144, 12));
    try std.testing.expect(!windowMoveMerges(.{
        .moved = true,
        .resized = true,
        .dpi_changed = true,
        .zoomed = false,
        .arranged = snapped(null, true, keptSize(tall_size, 96, scaled, 144, 12), true),
        .over_strip = true,
    }));
    try std.testing.expect(windowMoveMerges(.{
        .moved = true,
        .resized = true,
        .dpi_changed = true,
        .zoomed = false,
        .arranged = snapped(null, false, keptSize(tall_size, 96, scaled, 144, 12), true),
        .over_strip = true,
    }));
    // Snap Fill: an 800x600 window takes a third of the width and the full
    // height. Not its size: a snap, and no merge.
    const fill: Edges = .{ .left = -7, .top = 0, .right = 647, .bottom = 1039 };
    try std.testing.expect(!keptSize(.{ .width = 800, .height = 600 }, 96, .{ .width = 654, .height = 1039 }, 96, 12));
    try std.testing.expect(!windowMoveMerges(.{
        .moved = true,
        .resized = true,
        .dpi_changed = true,
        .zoomed = false,
        .arranged = snapped(null, looksSnapped(fill, work, 12), keptSize(.{ .width = 800, .height = 600 }, 144, .{ .width = 654, .height = 1039 }, 96, 12), true),
        .over_strip = true,
    }));
    // A size within the slack of the scaled one is kept; past it is not.
    try std.testing.expect(keptSize(.{ .width = 1200, .height = 900 }, 144, .{ .width = 805, .height = 596 }, 96, 12));
    try std.testing.expect(!keptSize(.{ .width = 1200, .height = 900 }, 144, .{ .width = 830, .height = 600 }, 96, 12));
}

test "a drag leaves the strip only past its band and the margin, above or below" {
    // A 40 px band at the client top with 20 px of slack.
    try std.testing.expect(!leavesStrip(0, 0, 40, 20));
    try std.testing.expect(!leavesStrip(59, 0, 40, 20));
    try std.testing.expect(leavesStrip(60, 0, 40, 20));
    try std.testing.expect(!leavesStrip(-20, 0, 40, 20));
    try std.testing.expect(leavesStrip(-21, 0, 40, 20));
}

test "a dropped tab goes before the first button whose middle is past the pointer, else after the last shown" {
    // Tabs 2 to 4 of 6 are shown, 100 px each from x = 1000.
    const shown = [_]Button{
        .{ .index = 2, .left = 1000, .right = 1100 },
        .{ .index = 3, .left = 1100, .right = 1200 },
        .{ .index = 4, .left = 1200, .right = 1300 },
    };
    try std.testing.expectEqual(@as(usize, 2), insertIndex(&shown, 900, 6));
    try std.testing.expectEqual(@as(usize, 2), insertIndex(&shown, 1049, 6));
    try std.testing.expectEqual(@as(usize, 3), insertIndex(&shown, 1050, 6));
    try std.testing.expectEqual(@as(usize, 4), insertIndex(&shown, 1199, 6));
    try std.testing.expectEqual(@as(usize, 5), insertIndex(&shown, 1250, 6));
    try std.testing.expectEqual(@as(usize, 5), insertIndex(&shown, 2000, 6));
    // The last tab shown is the last one: the end.
    const all = [_]Button{ .{ .index = 0, .left = 0, .right = 100 }, .{ .index = 1, .left = 100, .right = 200 } };
    try std.testing.expectEqual(@as(usize, 2), insertIndex(&all, 500, 2));
    try std.testing.expectEqual(@as(usize, 0), insertIndex(&all, 10, 2));
    try std.testing.expectEqual(@as(usize, 3), insertIndex(&.{}, 10, 3));
}

test "a dropped tab's index counts every tab shown, past 64 of them" {
    // 70 tabs, all shown, 20 px each: a drop right of the 65th goes after it.
    var buttons: [70]Button = undefined;
    for (&buttons, 0..) |*button, i| {
        const left: i32 = @intCast(i * 20);
        button.* = .{ .index = i, .left = left, .right = left + 20 };
    }
    try std.testing.expectEqual(@as(usize, 65), insertIndex(&buttons, 64 * 20 + 15, 70));
    try std.testing.expectEqual(@as(usize, 69), insertIndex(&buttons, 68 * 20 + 15, 70));
    try std.testing.expectEqual(@as(usize, 70), insertIndex(&buttons, 2000, 70));
    var scan: InsertScan = .{ .x = 64 * 20 + 15, .tab_count = 70 };
    for (buttons[0..65]) |button| try std.testing.expect(scan.add(button) == null);
    try std.testing.expectEqual(@as(usize, 65), scan.add(buttons[65]).?);
}

test "the pointer keeps its place over the tab in the new window" {
    // An 8 px frame, the strip 3 px down, the button held 30 px in and 10
    // down, within a 200 px tab.
    const grab = grabOffset(8, 31, 3, 30, 10, 200);
    try std.testing.expectEqual(@as(i32, 38), grab.x);
    try std.testing.expectEqual(@as(i32, 44), grab.y);
    // A grab far into a wide button is held at one tab's width; a negative
    // one (a capture can report it) at the edge.
    try std.testing.expectEqual(@as(i32, 208), grabOffset(8, 0, 0, 900, 0, 200).x);
    try std.testing.expectEqual(@as(i32, 8), grabOffset(8, 0, 0, -5, -5, 200).x);
    try std.testing.expectEqual(@as(i32, 0), grabOffset(8, 0, 0, -5, -5, 200).y);
}
