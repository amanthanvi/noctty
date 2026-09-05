//! This is the render state that is given to a renderer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");

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

/// Wall-clock milliseconds of the most recent renderer wake notify. This is
/// used by Win32 to keep a short follow-up render loop active even when the
/// underlying async wake primitive coalesces multiple notifies together.
last_render_wakeup_notify_ms: std.atomic.Value(u64) = .init(0),

/// Set of `WakeSource` bits contributed by every notify since the renderer
/// thread last consumed them. The wake primitive coalesces, so a single
/// wakeup callback can be owed to several sources at once; the renderer
/// thread swaps this to zero when it picks the wake up and hands the set to
/// the apprt, which is the only place that can name why a frame happened.
wake_sources: std.atomic.Value(u32) = .init(0),

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
    self.last_render_wakeup_notify_ms.store(@intCast(std.time.milliTimestamp()), .release);
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

pub fn renderWakeupNotifiedRecently(self: *const @This(), window_ms: u64) bool {
    const last = self.last_render_wakeup_notify_ms.load(.acquire);
    if (last == 0) return false;

    const now: u64 = @intCast(std.time.milliTimestamp());
    if (now < last) return false;
    return now - last < window_ms;
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

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
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
