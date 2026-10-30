//! This is the render state that is given to a renderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const render_dirty = @import("../terminal/render_dirty.zig");
const inputpkg = @import("../input.zig");
const monotonic = @import("../os/monotonic.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Thread.Mutex,

/// The terminal data.
terminal: *terminalpkg.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// `os/monotonic` nanoseconds of the most recent renderer wake notify, or 0
/// before the first. This is used by Win32 to keep a short follow-up render
/// loop active even when the underlying async wake primitive coalesces
/// multiple notifies together.
last_render_wakeup_notify_ns: std.atomic.Value(u64) = .init(0),

/// Set of `WakeSource` bits contributed by every notify since the renderer
/// thread last consumed them. The wake primitive coalesces, so a single
/// wakeup callback can be owed to several sources at once; the renderer
/// thread swaps this to zero when it picks the wake up and hands the set to
/// the apprt, which is the only place that can name why a frame happened.
wake_sources: std.atomic.Value(u32) = .init(0),

/// The cursor and colors as of the last frame update, or null before the
/// first: what output can change in a frame without marking it dirty (see
/// `render_dirty.Undirtied`). Written by the renderer and compared by termio
/// and the render follow-up, all under `mutex`.
drawn_undirtied: ?render_dirty.Undirtied = null,

/// Monotonic progress recorded after each parsed PTY output chunk. These
/// fields are protected by `mutex` and let presentation diagnostics prove
/// that a swap includes a specific amount of terminal output.
process_output_generation: u64 = 0,
process_output_bytes: u64 = 0,
last_process_output_tick_ms: u64 = 0,

/// Benchmark-only acknowledgement copied from process-output progress when a
/// configured visible end marker has been parsed and committed.
benchmark_end_marker_generation: u64 = 0,
benchmark_end_marker_output_bytes: u64 = 0,

pub const OutputProgress = struct {
    generation: u64,
    bytes: u64,
    tick_ms: u64,
    benchmark_end_marker_generation: u64,
    benchmark_end_marker_output_bytes: u64,
};

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},
};

/// Why a renderer wake was requested. Every `renderer_thread.wakeup.notify()`
/// call site records exactly one of these so an idle repaint can be traced
/// back to the code that asked for it instead of showing up as an
/// unexplained frame.
pub const WakeSource = enum(u5) {
    /// `renderer.Thread` sends itself one wake when the loop starts.
    thread_start,
    /// `Surface.queueRender` — core surface state changed.
    core_surface,
    /// A message was placed in the renderer mailbox.
    mailbox,
    /// The VT stream parsed PTY output.
    io_output,
    /// The cursor blink timer toggled visibility.
    cursor_blink,
    /// A Win32 paint completed while a newer frame was already pending.
    apprt_repaint_retry,
    /// The Win32 resize-settle sweep found no reserved paint to present.
    apprt_resize_settle,
    /// A Win32 `WM_PAINT` arrived with no renderer frame reserved.
    apprt_paint_retry,
    /// Win32 renderer health recovery asked for a fresh frame.
    apprt_health_recovery,
    /// A Win32 paint request collapsed into an already-pending paint.
    apprt_paint_pending,
    /// The Win32 window was seen on screen for the first time, or its first
    /// `WM_PAINT` found no reserved frame. Bounded to at most two wakes per
    /// surface for the life of the process; see
    /// `apprt/win32/first_frame.zig`.
    apprt_first_show,
    /// The inspector redrew itself.
    inspector,

    pub fn bit(self: WakeSource) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }
};

pub fn noteRenderWakeupNotify(self: *@This()) void {
    self.last_render_wakeup_notify_ns.store(monotonic.nowNs(), .release);
}

/// Record the reason for a wake. Callers must do this before notifying, so
/// the renderer thread cannot consume the wake before the reason is visible.
pub fn noteWakeSource(self: *@This(), source: WakeSource) void {
    _ = self.wake_sources.fetchOr(source.bit(), .acq_rel);
}

/// Take and clear the accumulated wake sources.
pub fn takeWakeSources(self: *@This()) u32 {
    return self.wake_sources.swap(0, .acq_rel);
}

/// Whether a recorded wake has not been picked up yet. Every source is
/// recorded before its notify, so its wakeup callback is still to come.
pub fn wakePending(self: *const @This()) bool {
    return self.wake_sources.load(.acquire) != 0;
}

pub fn renderWakeupNotifiedRecently(self: *const @This(), window_ms: u64) bool {
    const last = self.last_render_wakeup_notify_ns.load(.acquire);
    if (last == 0) return false;

    const now = monotonic.nowNs();
    if (now < last) return false;
    return now - last < window_ms * std.time.ns_per_ms;
}

/// Caller must hold `mutex`.
pub fn noteProcessOutput(self: *@This(), byte_count: usize, tick_ms: u64) void {
    if (byte_count == 0) return;
    self.process_output_generation +%= 1;
    self.process_output_bytes +|= @intCast(byte_count);
    self.last_process_output_tick_ms = tick_ms;
}

/// Caller must hold `mutex` and call this after `noteProcessOutput` for the
/// chunk that completed the configured benchmark marker.
pub fn noteBenchmarkEndMarker(self: *@This()) void {
    self.benchmark_end_marker_generation = self.process_output_generation;
    self.benchmark_end_marker_output_bytes = self.process_output_bytes;
}

/// Caller must hold `mutex`.
pub fn outputProgress(self: *const @This()) OutputProgress {
    return .{
        .generation = self.process_output_generation,
        .bytes = self.process_output_bytes,
        .tick_ms = self.last_process_output_tick_ms,
        .benchmark_end_marker_generation = self.benchmark_end_marker_generation,
        .benchmark_end_marker_output_bytes = self.benchmark_end_marker_output_bytes,
    };
}

test "renderer state records PTY output progress" {
    var mutex: std.Thread.Mutex = .{};
    var state: @This() = .{
        .mutex = &mutex,
        .terminal = undefined,
    };

    state.noteProcessOutput(17, 100);
    state.noteProcessOutput(5, 125);
    state.noteBenchmarkEndMarker();

    const progress = state.outputProgress();

    try std.testing.expectEqual(@as(u64, 2), progress.generation);
    try std.testing.expectEqual(@as(u64, 22), progress.bytes);
    try std.testing.expectEqual(@as(u64, 125), progress.tick_ms);
    try std.testing.expectEqual(@as(u64, 2), progress.benchmark_end_marker_generation);
    try std.testing.expectEqual(@as(u64, 22), progress.benchmark_end_marker_output_bytes);
}

/// The pre-edit state. See Surface.preeditCaretCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// The composition caret as an index into `codepoints`, from 0 (before
    /// the first) through `codepoints.len` (after the last), or null when
    /// the input method reports none (dead keys, an IME without one).
    caret: ?usize = null,

    /// The clause the input method is converting (its target clause), as a
    /// range of `codepoints`, or null when it reports none. It is drawn with
    /// a double underline and the rest of the preedit with a single one.
    target: ?Target = null,

    /// Codepoints `start` up to, not including, `end`; never empty.
    pub const Target = struct {
        start: usize,
        end: usize,
    };

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,

        fn cells(self: Codepoint) usize {
            return if (self.wide) 2 else 1;
        }
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
            .caret = self.caret,
            .target = self.target,
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| result += cp.cells();
        return result;
    }

    /// Where the preedit is drawn on a row whose last column is `max`.
    pub const Layout = struct {
        /// The first and last cell the drawn codepoints cover, `max` at
        /// most. The terminal's own cells in this span are not drawn.
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        /// The first codepoint drawn, at `start`. The codepoints after it
        /// are drawn up to `end`.
        cp_offset: usize,
        /// The cell whose left edge the caret is drawn on, or null.
        caret_x: ?terminalpkg.size.CellCountInt,
        /// The first and last cell of the target clause's drawn part, or
        /// null when none of it is drawn.
        target_x: ?[2]terminalpkg.size.CellCountInt = null,
    };

    /// Lay the preedit out from the terminal cursor at `start` on a row
    /// whose last column is `max`. When it does not fit, the head is cut,
    /// so the text nearest the caret stays visible, and `start` stays at the
    /// cursor unless not even one codepoint fits there. A caret after the
    /// last codepoint takes a cell of its own, and a caret inside the cut
    /// head brings its codepoint back as the first one drawn.
    pub fn layout(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) Layout {
        if (self.codepoints.len == 0 or start > max) return .{
            .start = start,
            .end = start,
            .cp_offset = 0,
            .caret_x = null,
        };
        var result = self.place(start, max);
        result.target_x = self.targetCells(result);
        return result;
    }

    /// `layout` for a preedit with codepoints, without the target clause.
    fn place(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) Layout {
        const CellCountInt = terminalpkg.size.CellCountInt;
        const cps = self.codepoints;
        const caret: ?usize = if (self.caret) |c| @min(c, cps.len) else null;
        // Cells from the cursor through the last column.
        const avail: usize = @as(usize, max - start) + 1;

        // The longest tail that fits, with a cell for a caret after it.
        var first = cps.len;
        var need: usize = if (caret == cps.len) 1 else 0;
        while (first > 0 and need + cps[first - 1].cells() <= avail) {
            first -= 1;
            need += cps[first].cells();
        }

        // A caret in the cut head: its codepoint is drawn first and the
        // tail is cut instead.
        if (caret) |c| slide: {
            if (c >= first) break :slide;
            const at = cps[c].cells();
            // From the last column, a wide codepoint moves left to fit.
            const from: CellCountInt = if (at > avail) @intCast((@as(usize, max) + 1) -| at) else start;
            var end: usize = from + at - 1;
            for (cps[c + 1 ..]) |cp| {
                if (end + cp.cells() > max) break;
                end += cp.cells();
            }
            return .{
                .start = from,
                .end = @intCast(@min(end, max)),
                .cp_offset = c,
                .caret_x = from,
            };
        }

        // Not even the last codepoint fits beside the cursor (a wide one in
        // the last column, or any one with the caret after it): move it
        // left until it does.
        var from = start;
        if (first == cps.len) {
            first = cps.len - 1;
            need += cps[first].cells();
            from = @intCast((@as(usize, max) + 1) -| need);
        }

        var text: usize = 0;
        for (cps[first..]) |cp| text += cp.cells();
        const caret_x: ?CellCountInt = if (caret) |c| caret_x: {
            var x: usize = from;
            for (cps[first..c]) |cp| x += cp.cells();
            break :caret_x @intCast(@min(x, max));
        } else null;
        return .{
            .start = from,
            .end = @intCast(@min(@as(usize, from) + text - 1, max)),
            .cp_offset = first,
            .caret_x = caret_x,
        };
    }

    /// The cells of the target clause that `placed` draws, walking the
    /// codepoints the way `rebuildCells` does.
    fn targetCells(self: *const Preedit, placed: Layout) ?[2]terminalpkg.size.CellCountInt {
        const target = self.target orelse return null;
        var first: ?usize = null;
        var last: usize = 0;
        var x: usize = placed.start;
        for (self.codepoints[placed.cp_offset..], placed.cp_offset..) |cp, i| {
            if (x + cp.cells() - 1 > placed.end) break;
            if (i >= target.start and i < target.end) {
                if (first == null) first = x;
                last = x + cp.cells() - 1;
            }
            x += cp.cells();
        }
        return .{ @intCast(first orelse return null), @intCast(last) };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

/// Checks what `rebuildCells` draws for a layout: codepoints from
/// `cp_offset` cover exactly `start..end`, and nothing lands past `max`.
fn expectLayout(
    p: Preedit,
    start: terminalpkg.size.CellCountInt,
    max: terminalpkg.size.CellCountInt,
    expected: Preedit.Layout,
) !void {
    const testing = std.testing;
    const l = p.layout(start, max);
    try testing.expectEqual(expected, l);
    var x: usize = l.start;
    for (p.codepoints[l.cp_offset..]) |cp| {
        if (x + cp.cells() - 1 > l.end) break;
        x += cp.cells();
    }
    try testing.expectEqual(@as(usize, l.end) + 1, x);
    try testing.expect(l.end <= max);
    if (l.caret_x) |caret_x| try testing.expect(caret_x <= max);
}

test "preedit layout covers exact cell width" {
    try expectLayout(.{
        .codepoints = &.{.{ .codepoint = 'a' }},
    }, 2, 9, .{ .start = 2, .end = 2, .cp_offset = 0, .caret_x = null });

    try expectLayout(.{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    }, 2, 9, .{ .start = 2, .end = 3, .cp_offset = 0, .caret_x = null });
}

test "preedit layout shifts left at right edge" {
    try expectLayout(.{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    }, 9, 9, .{ .start = 8, .end = 9, .cp_offset = 0, .caret_x = null });
    try expectLayout(.{
        .codepoints = &.{ .{ .codepoint = 'a' }, .{ .codepoint = test_hangul_ga, .wide = true } },
    }, 9, 9, .{ .start = 8, .end = 9, .cp_offset = 1, .caret_x = null });
}

test "preedit layout draws no cell past max when it truncates" {
    // main's range() returned cp_offset 4 here and so drew 11 cells, the
    // last one at x = 10, past the last column.
    const narrow: [15]Preedit.Codepoint = @splat(.{ .codepoint = 'a' });
    try expectLayout(.{ .codepoints = &narrow }, 0, 9, .{ .start = 0, .end = 9, .cp_offset = 5, .caret_x = null });
}

test "preedit layout never starts left of the cursor" {
    // main's range() started this one at column 4, over the cell left of
    // the cursor.
    const narrow: [15]Preedit.Codepoint = @splat(.{ .codepoint = 'a' });
    try expectLayout(.{ .codepoints = &narrow }, 5, 9, .{ .start = 5, .end = 9, .cp_offset = 10, .caret_x = null });
}

test "preedit layout places the caret inside the text" {
    const narrow: [8]Preedit.Codepoint = @splat(.{ .codepoint = 'a' });
    try expectLayout(.{ .codepoints = &narrow, .caret = 5 }, 0, 79, .{ .start = 0, .end = 7, .cp_offset = 0, .caret_x = 5 });
    try expectLayout(.{ .codepoints = &narrow, .caret = 0 }, 3, 79, .{ .start = 3, .end = 10, .cp_offset = 0, .caret_x = 3 });
    // A caret past the end clamps to the end.
    try expectLayout(.{ .codepoints = &narrow, .caret = 99 }, 0, 79, .{ .start = 0, .end = 7, .cp_offset = 0, .caret_x = 8 });
}

test "preedit layout reserves a cell for a caret at the end" {
    const narrow: [10]Preedit.Codepoint = @splat(.{ .codepoint = 'a' });
    // Fits with its caret cell.
    try expectLayout(.{ .codepoints = narrow[0..8], .caret = 8 }, 0, 9, .{ .start = 0, .end = 7, .cp_offset = 0, .caret_x = 8 });
    // Ten cells of text fill the row: the head loses one more codepoint
    // than without a caret, and the caret sits on the last column.
    try expectLayout(.{ .codepoints = &narrow, .caret = 10 }, 0, 9, .{ .start = 0, .end = 8, .cp_offset = 1, .caret_x = 9 });
    try expectLayout(.{ .codepoints = &narrow }, 0, 9, .{ .start = 0, .end = 9, .cp_offset = 0, .caret_x = null });
    // From the last column, the text moves left by the caret's cell.
    try expectLayout(.{ .codepoints = narrow[0..3], .caret = 3 }, 9, 9, .{ .start = 8, .end = 8, .cp_offset = 2, .caret_x = 9 });
}

test "preedit layout brings a caret in the cut head into view" {
    const narrow: [15]Preedit.Codepoint = @splat(.{ .codepoint = 'a' });
    // Codepoints 5..15 are what fits; a caret before 5 is drawn first and
    // the tail is cut instead.
    try expectLayout(.{ .codepoints = &narrow, .caret = 2 }, 0, 9, .{ .start = 0, .end = 9, .cp_offset = 2, .caret_x = 0 });
    try expectLayout(.{ .codepoints = &narrow, .caret = 0 }, 5, 9, .{ .start = 5, .end = 9, .cp_offset = 0, .caret_x = 5 });
    // A caret inside the visible tail leaves the window alone.
    try expectLayout(.{ .codepoints = &narrow, .caret = 7 }, 0, 9, .{ .start = 0, .end = 9, .cp_offset = 5, .caret_x = 2 });
    // A wide codepoint at the caret, on the last column, moves left to fit.
    const wide: [5]Preedit.Codepoint = @splat(.{ .codepoint = test_hangul_ga, .wide = true });
    try expectLayout(.{ .codepoints = &wide, .caret = 1 }, 9, 9, .{ .start = 8, .end = 9, .cp_offset = 1, .caret_x = 8 });
}

test "preedit layout places the caret between wide codepoints" {
    const wide: [4]Preedit.Codepoint = @splat(.{ .codepoint = test_hangul_ga, .wide = true });
    try expectLayout(.{ .codepoints = &wide, .caret = 0 }, 2, 79, .{ .start = 2, .end = 9, .cp_offset = 0, .caret_x = 2 });
    try expectLayout(.{ .codepoints = &wide, .caret = 1 }, 2, 79, .{ .start = 2, .end = 9, .cp_offset = 0, .caret_x = 4 });
    try expectLayout(.{ .codepoints = &wide, .caret = 3 }, 2, 79, .{ .start = 2, .end = 9, .cp_offset = 0, .caret_x = 8 });
    try expectLayout(.{ .codepoints = &wide, .caret = 4 }, 2, 79, .{ .start = 2, .end = 9, .cp_offset = 0, .caret_x = 10 });
    // Truncated: a wide codepoint that does not fit beside the caret cell
    // is cut whole.
    try expectLayout(.{ .codepoints = &wide, .caret = 4 }, 0, 7, .{ .start = 0, .end = 5, .cp_offset = 1, .caret_x = 6 });
}

test "preedit layout marks the drawn cells of the target clause" {
    // A Japanese-shaped composition: kana, then the clause being
    // converted, then a converted one, all wide.
    const wide: [6]Preedit.Codepoint = @splat(.{ .codepoint = test_hangul_ga, .wide = true });
    try expectLayout(.{ .codepoints = &wide, .target = .{ .start = 2, .end = 4 } }, 0, 79, .{ .start = 0, .end = 11, .cp_offset = 0, .caret_x = null, .target_x = .{ 4, 7 } });
    // The target on the next clause moves only the target cells.
    try expectLayout(.{ .codepoints = &wide, .target = .{ .start = 4, .end = 6 } }, 0, 79, .{ .start = 0, .end = 11, .cp_offset = 0, .caret_x = null, .target_x = .{ 8, 11 } });
    const narrow: [8]Preedit.Codepoint = @splat(.{ .codepoint = 'a' });
    try expectLayout(.{ .codepoints = &narrow, .target = .{ .start = 3, .end = 5 } }, 2, 79, .{ .start = 2, .end = 9, .cp_offset = 0, .caret_x = null, .target_x = .{ 5, 6 } });
    try expectLayout(.{ .codepoints = &narrow, .target = .{ .start = 0, .end = 8 } }, 2, 79, .{ .start = 2, .end = 9, .cp_offset = 0, .caret_x = null, .target_x = .{ 2, 9 } });
}

test "preedit layout keeps the visible part of a truncated target" {
    const narrow: [15]Preedit.Codepoint = @splat(.{ .codepoint = 'a' });
    // Codepoints 5..15 are drawn at x = 0..9: of the target 3..8, the
    // drawn 5..8 sit at x = 0..2.
    try expectLayout(.{ .codepoints = &narrow, .target = .{ .start = 3, .end = 8 } }, 0, 9, .{ .start = 0, .end = 9, .cp_offset = 5, .caret_x = null, .target_x = .{ 0, 2 } });
    // All of it in the cut head: none drawn.
    try expectLayout(.{ .codepoints = &narrow, .target = .{ .start = 0, .end = 3 } }, 0, 9, .{ .start = 0, .end = 9, .cp_offset = 5, .caret_x = null, .target_x = null });
    // A caret in the cut head cuts the tail: codepoints 0..5 at x = 5..9,
    // so of the target 3..8 only 3 and 4 are drawn.
    try expectLayout(.{ .codepoints = &narrow, .caret = 0, .target = .{ .start = 3, .end = 8 } }, 5, 9, .{ .start = 5, .end = 9, .cp_offset = 0, .caret_x = 5, .target_x = .{ 8, 9 } });
    // A wide codepoint cut whole takes its target cells with it.
    const wide: [4]Preedit.Codepoint = @splat(.{ .codepoint = test_hangul_ga, .wide = true });
    try expectLayout(.{ .codepoints = &wide, .caret = 4, .target = .{ .start = 0, .end = 2 } }, 0, 7, .{ .start = 0, .end = 5, .cp_offset = 1, .caret_x = 6, .target_x = .{ 0, 1 } });
}

test "preedit layout draws the caret and the target together" {
    const wide: [6]Preedit.Codepoint = @splat(.{ .codepoint = test_hangul_ga, .wide = true });
    try expectLayout(.{ .codepoints = &wide, .caret = 2, .target = .{ .start = 2, .end = 4 } }, 0, 79, .{ .start = 0, .end = 11, .cp_offset = 0, .caret_x = 4, .target_x = .{ 4, 7 } });
    try expectLayout(.{ .codepoints = &wide, .caret = 6, .target = .{ .start = 4, .end = 6 } }, 3, 79, .{ .start = 3, .end = 14, .cp_offset = 0, .caret_x = 15, .target_x = .{ 11, 14 } });
}

test "preedit clone keeps the caret" {
    const testing = std.testing;
    const p: Preedit = .{ .codepoints = &.{ .{ .codepoint = 'a' }, .{ .codepoint = 'b' } }, .caret = 1, .target = .{ .start = 0, .end = 1 } };
    const copy = try p.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expectEqual(@as(?usize, 1), copy.caret);
    try testing.expectEqual(@as(?Preedit.Target, .{ .start = 0, .end = 1 }), copy.target);
    try testing.expectEqualSlices(Preedit.Codepoint, p.codepoints, copy.codepoints);
}

test "renderer state accumulates wake sources until taken" {
    var mutex: std.Thread.Mutex = .{};
    var state: @This() = .{
        .mutex = &mutex,
        .terminal = undefined,
    };

    try std.testing.expectEqual(@as(u32, 0), state.takeWakeSources());

    state.noteWakeSource(.io_output);
    state.noteWakeSource(.mailbox);
    state.noteWakeSource(.io_output);

    const taken = state.takeWakeSources();
    try std.testing.expect(taken & WakeSource.io_output.bit() != 0);
    try std.testing.expect(taken & WakeSource.mailbox.bit() != 0);
    try std.testing.expect(taken & WakeSource.cursor_blink.bit() == 0);

    // Taking clears, so a coalesced wake with no new notify is reported as
    // unattributed rather than blamed on the previous source.
    try std.testing.expectEqual(@as(u32, 0), state.takeWakeSources());
}

test "renderer wake source bits are distinct and fit the mask" {
    var seen: u32 = 0;
    for (std.enums.values(WakeSource)) |source| {
        const bit = source.bit();
        try std.testing.expect(bit != 0);
        try std.testing.expectEqual(@as(u32, 0), seen & bit);
        seen |= bit;
    }
}
