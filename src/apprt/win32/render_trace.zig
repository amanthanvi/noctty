//! Opt-in Win32 renderer trace collection.

const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../../os/main.zig");
const sys = @import("sys.zig");

const log = std.log.scoped(.win32);

var render_trace_file_claimed = std.atomic.Value(bool).init(false);

pub const RenderTrace = struct {
    const startup_window_ms: u64 = 1000;
    const startup_paint_gap_ceiling_ms: u64 = 1500;
    const paint_gap_limit_ms: u64 = 300;

    const PaintGapTargets = struct {
        max_gap_ms: *std.atomic.Value(u64),
        max_gap_ended_at_ms: *std.atomic.Value(u64),
        over_limit_count: *std.atomic.Value(u64),
    };

    path: ?[]const u8 = null,
    start_tick_ms: u64 = 0,
    renderer_update_frame_count: std.atomic.Value(u64) = .init(0),
    renderer_draw_request_count: std.atomic.Value(u64) = .init(0),
    wakeup_callback_count: std.atomic.Value(u64) = .init(0),
    render_callback_count: std.atomic.Value(u64) = .init(0),
    renderer_repaint_accept_count: std.atomic.Value(u64) = .init(0),
    renderer_repaint_coalesced_count: std.atomic.Value(u64) = .init(0),
    queue_paint_count: std.atomic.Value(u64) = .init(0),
    queue_paint_update_now_count: std.atomic.Value(u64) = .init(0),
    force_paint_now_count: std.atomic.Value(u64) = .init(0),
    paint_draw_count: std.atomic.Value(u64) = .init(0),
    paint_retry_count: std.atomic.Value(u64) = .init(0),
    swap_buffers_count: std.atomic.Value(u64) = .init(0),
    max_renderer_update_gap_ms: std.atomic.Value(u64) = .init(0),
    max_paint_gap_ms: std.atomic.Value(u64) = .init(0),
    max_swap_gap_ms: std.atomic.Value(u64) = .init(0),
    max_renderer_update_gap_ended_at_ms: std.atomic.Value(u64) = .init(0),
    max_paint_gap_ended_at_ms: std.atomic.Value(u64) = .init(0),
    max_swap_gap_ended_at_ms: std.atomic.Value(u64) = .init(0),
    max_sustained_paint_gap_ms: std.atomic.Value(u64) = .init(0),
    max_sustained_paint_gap_ended_at_ms: std.atomic.Value(u64) = .init(0),
    paint_gap_over_limit_count: std.atomic.Value(u64) = .init(0),
    max_paint_draw_duration_ms: std.atomic.Value(u64) = .init(0),
    max_paint_draw_duration_at_ms: std.atomic.Value(u64) = .init(0),
    paint_draw_duration_over_20ms_count: std.atomic.Value(u64) = .init(0),
    paint_draw_duration_over_33ms_count: std.atomic.Value(u64) = .init(0),
    last_renderer_update_tick_ms: std.atomic.Value(u64) = .init(0),
    last_paint_tick_ms: std.atomic.Value(u64) = .init(0),
    last_swap_tick_ms: std.atomic.Value(u64) = .init(0),
    first_renderer_update_at_ms: std.atomic.Value(u64) = .init(0),
    first_paint_at_ms: std.atomic.Value(u64) = .init(0),
    first_swap_at_ms: std.atomic.Value(u64) = .init(0),

    pub fn init(alloc: Allocator) RenderTrace {
        const owned = (internal_os.getEnvVarOwnedTrimmedNotEmpty(
            alloc,
            "NOCTTY_RENDER_TRACE_FILE",
        ) catch return .{}) orelse return .{};
        const trace_path = absolutizeTracePath(alloc, owned) catch |err| {
            log.warn("unable to resolve render trace path err={}", .{err});
            return .{};
        };

        return initWithClaimedPath(alloc, &render_trace_file_claimed, trace_path);
    }

    fn initWithClaimedPath(
        alloc: Allocator,
        claimed: *std.atomic.Value(bool),
        owned: []const u8,
    ) RenderTrace {
        // A trace path names one JSON document. The interactive harness waits
        // for the initial surface before seeding tabs, so the first claimant
        // is deterministic. Keeping that claim for the process lifetime stops
        // later tab teardown from overwriting the initial surface's evidence.
        const trace_path = claimTracePath(alloc, claimed, owned) orelse
            return .{};
        return .{
            .path = trace_path,
            .start_tick_ms = sys.GetTickCount64(),
        };
    }

    pub fn deinit(self: *RenderTrace, alloc: Allocator) void {
        defer {
            if (self.path) |path| alloc.free(path);
            self.* = .{};
        }

        if (self.path == null) return;
        self.writeSnapshot();
    }

    pub fn enabled(self: *const RenderTrace) bool {
        return self.path != null;
    }

    pub fn noteRendererUpdateFrame(self: *RenderTrace) void {
        if (!self.enabled()) return;
        self.noteTimedCounter(
            &self.renderer_update_frame_count,
            &self.last_renderer_update_tick_ms,
            &self.max_renderer_update_gap_ms,
            &self.max_renderer_update_gap_ended_at_ms,
            &self.first_renderer_update_at_ms,
            null,
        );
    }

    pub fn noteRendererDrawRequest(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.renderer_draw_request_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererWakeupCallback(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.wakeup_callback_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererFollowupCallback(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.render_callback_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererRepaintAccepted(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.renderer_repaint_accept_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererRepaintCoalesced(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.renderer_repaint_coalesced_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteQueuePaint(self: *RenderTrace, update_now: bool) void {
        if (!self.enabled()) return;
        _ = self.queue_paint_count.fetchAdd(1, .acq_rel);
        if (update_now) _ = self.queue_paint_update_now_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteForcePaintNow(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.force_paint_now_count.fetchAdd(1, .acq_rel);
    }

    pub fn notePaintDraw(self: *RenderTrace) void {
        if (!self.enabled()) return;
        self.noteTimedCounter(
            &self.paint_draw_count,
            &self.last_paint_tick_ms,
            &self.max_paint_gap_ms,
            &self.max_paint_gap_ended_at_ms,
            &self.first_paint_at_ms,
            .{
                .max_gap_ms = &self.max_sustained_paint_gap_ms,
                .max_gap_ended_at_ms = &self.max_sustained_paint_gap_ended_at_ms,
                .over_limit_count = &self.paint_gap_over_limit_count,
            },
        );
    }

    pub fn notePaintDrawDuration(self: *RenderTrace, duration_ms: u64) void {
        if (!self.enabled()) return;
        updateMaxAtomicWithTimestamp(
            &self.max_paint_draw_duration_ms,
            &self.max_paint_draw_duration_at_ms,
            duration_ms,
            elapsedTraceMs(self.start_tick_ms, sys.GetTickCount64()),
        );
        if (duration_ms > 20) _ = self.paint_draw_duration_over_20ms_count.fetchAdd(1, .acq_rel);
        if (duration_ms > 33) _ = self.paint_draw_duration_over_33ms_count.fetchAdd(1, .acq_rel);
    }

    pub fn notePaintRetry(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.paint_retry_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteSwapBuffers(self: *RenderTrace) void {
        if (!self.enabled()) return;
        self.noteTimedCounter(
            &self.swap_buffers_count,
            &self.last_swap_tick_ms,
            &self.max_swap_gap_ms,
            &self.max_swap_gap_ended_at_ms,
            &self.first_swap_at_ms,
            null,
        );
    }

    fn noteTimedCounter(
        self: *RenderTrace,
        counter: *std.atomic.Value(u64),
        last_tick_ms: *std.atomic.Value(u64),
        max_gap_ms: *std.atomic.Value(u64),
        max_gap_ended_at_ms: *std.atomic.Value(u64),
        first_at_ms: *std.atomic.Value(u64),
        paint_gaps: ?PaintGapTargets,
    ) void {
        const now = sys.GetTickCount64();
        const elapsed_ms = elapsedTraceMs(self.start_tick_ms, now);
        _ = counter.fetchAdd(1, .acq_rel);
        _ = first_at_ms.cmpxchgStrong(0, elapsed_ms, .acq_rel, .acquire);
        const prev = last_tick_ms.swap(now, .acq_rel);
        if (prev == 0 or now <= prev) return;
        const gap_ms = now - prev;
        updateMaxAtomicWithTimestamp(
            max_gap_ms,
            max_gap_ended_at_ms,
            gap_ms,
            elapsed_ms,
        );
        if (paint_gaps) |targets| {
            if (gapExceedsPaintLimit(gap_ms)) {
                _ = targets.over_limit_count.fetchAdd(1, .acq_rel);
            }
            if (gapIsSustained(elapsed_ms, gap_ms)) {
                updateMaxAtomicWithTimestamp(
                    targets.max_gap_ms,
                    targets.max_gap_ended_at_ms,
                    gap_ms,
                    elapsed_ms,
                );
            }
        }
    }

    fn gapIsSustained(elapsed_ms: u64, gap_ms: u64) bool {
        return elapsed_ms -| gap_ms >= startup_window_ms;
    }

    fn gapExceedsPaintLimit(gap_ms: u64) bool {
        return gap_ms > paint_gap_limit_ms;
    }

    fn writeSnapshot(self: *const RenderTrace) void {
        const trace_path = self.path orelse return;
        const file = std.fs.createFileAbsolute(trace_path, .{ .truncate = true }) catch |err| {
            log.warn("unable to create render trace file path={s} err={}", .{ trace_path, err });
            return;
        };
        defer file.close();

        var buffer: [1024]u8 = undefined;
        var writer = file.writer(&buffer);
        const stream = &writer.interface;
        stream.print("{f}", .{std.json.fmt(.{
            .runtime_ms = sys.GetTickCount64() - self.start_tick_ms,
            .startup_window_ms = startup_window_ms,
            .startup_paint_gap_ceiling_ms = startup_paint_gap_ceiling_ms,
            .paint_gap_limit_ms = paint_gap_limit_ms,
            .renderer_update_frame_count = self.renderer_update_frame_count.load(.acquire),
            .renderer_draw_request_count = self.renderer_draw_request_count.load(.acquire),
            .wakeup_callback_count = self.wakeup_callback_count.load(.acquire),
            .render_callback_count = self.render_callback_count.load(.acquire),
            .renderer_repaint_accept_count = self.renderer_repaint_accept_count.load(.acquire),
            .renderer_repaint_coalesced_count = self.renderer_repaint_coalesced_count.load(.acquire),
            .queue_paint_count = self.queue_paint_count.load(.acquire),
            .queue_paint_update_now_count = self.queue_paint_update_now_count.load(.acquire),
            .force_paint_now_count = self.force_paint_now_count.load(.acquire),
            .paint_draw_count = self.paint_draw_count.load(.acquire),
            .paint_retry_count = self.paint_retry_count.load(.acquire),
            .swap_buffers_count = self.swap_buffers_count.load(.acquire),
            .max_renderer_update_gap_ms = self.max_renderer_update_gap_ms.load(.acquire),
            .max_paint_gap_ms = self.max_paint_gap_ms.load(.acquire),
            .max_swap_gap_ms = self.max_swap_gap_ms.load(.acquire),
            .max_renderer_update_gap_ended_at_ms = self.max_renderer_update_gap_ended_at_ms.load(.acquire),
            .max_paint_gap_ended_at_ms = self.max_paint_gap_ended_at_ms.load(.acquire),
            .max_swap_gap_ended_at_ms = self.max_swap_gap_ended_at_ms.load(.acquire),
            .max_sustained_paint_gap_ms = self.max_sustained_paint_gap_ms.load(.acquire),
            .max_sustained_paint_gap_ended_at_ms = self.max_sustained_paint_gap_ended_at_ms.load(.acquire),
            .paint_gap_over_limit_count = self.paint_gap_over_limit_count.load(.acquire),
            .max_paint_draw_duration_ms = self.max_paint_draw_duration_ms.load(.acquire),
            .max_paint_draw_duration_at_ms = self.max_paint_draw_duration_at_ms.load(.acquire),
            .paint_draw_duration_over_20ms_count = self.paint_draw_duration_over_20ms_count.load(.acquire),
            .paint_draw_duration_over_33ms_count = self.paint_draw_duration_over_33ms_count.load(.acquire),
            .first_renderer_update_at_ms = self.first_renderer_update_at_ms.load(.acquire),
            .first_paint_at_ms = self.first_paint_at_ms.load(.acquire),
            .first_swap_at_ms = self.first_swap_at_ms.load(.acquire),
        }, .{})}) catch return;
        stream.flush() catch return;
    }
};

fn absolutizeTracePath(alloc: Allocator, owned: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(owned)) return owned;
    defer alloc.free(owned);
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    return try std.fs.path.join(alloc, &.{ cwd, owned });
}

fn claimTraceFile(claimed: *std.atomic.Value(bool)) bool {
    return !claimed.swap(true, .acq_rel);
}

fn claimTracePath(
    alloc: Allocator,
    claimed: *std.atomic.Value(bool),
    owned: []const u8,
) ?[]const u8 {
    if (claimTraceFile(claimed)) return owned;
    log.debug("render trace path already has a process owner; tracing disabled for this surface", .{});
    alloc.free(owned);
    return null;
}

fn elapsedTraceMs(start_tick_ms: u64, now_tick_ms: u64) u64 {
    if (now_tick_ms <= start_tick_ms) return 0;
    return now_tick_ms - start_tick_ms;
}

fn updateMaxAtomicWithTimestamp(
    value: *std.atomic.Value(u64),
    at_ms: *std.atomic.Value(u64),
    candidate: u64,
    candidate_at_ms: u64,
) void {
    var current = value.load(.acquire);
    while (candidate > current) {
        const observed = value.cmpxchgWeak(current, candidate, .acq_rel, .acquire);
        if (observed) |next| {
            current = next;
            continue;
        }
        at_ms.store(candidate_at_ms, .release);
        return;
    }
}

test "win32 render trace classifies gaps by start time" {
    try std.testing.expect(!RenderTrace.gapIsSustained(1250, 578));
    try std.testing.expect(!RenderTrace.gapIsSustained(1299, 300));
    try std.testing.expect(RenderTrace.gapIsSustained(1300, 300));
    try std.testing.expect(!RenderTrace.gapIsSustained(500, 600));
}

test "win32 render trace classifies visible paint gaps" {
    try std.testing.expect(RenderTrace.startup_paint_gap_ceiling_ms >= RenderTrace.startup_window_ms);
    try std.testing.expect(!RenderTrace.gapExceedsPaintLimit(300));
    try std.testing.expect(RenderTrace.gapExceedsPaintLimit(301));
}

test "win32 render trace init rejects and frees a second process owner" {
    var claimed = std.atomic.Value(bool).init(false);
    const first = try std.testing.allocator.dupe(u8, "first.json");
    const first_trace = RenderTrace.initWithClaimedPath(std.testing.allocator, &claimed, first);
    defer if (first_trace.path) |path| std.testing.allocator.free(path);
    try std.testing.expect(first_trace.path != null);

    const second = try std.testing.allocator.dupe(u8, "second.json");
    const second_trace = RenderTrace.initWithClaimedPath(std.testing.allocator, &claimed, second);
    defer if (second_trace.path) |path| std.testing.allocator.free(path);
    try std.testing.expect(second_trace.path == null);
}

test "win32 render trace resolves relative output paths against cwd" {
    const relative = try std.testing.allocator.dupe(u8, "render-trace.json");
    const absolute = try absolutizeTracePath(std.testing.allocator, relative);
    defer std.testing.allocator.free(absolute);

    try std.testing.expect(std.fs.path.isAbsolute(absolute));
    try std.testing.expectEqualStrings("render-trace.json", std.fs.path.basename(absolute));
}
