//! Opt-in Win32 renderer trace collection.

const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../../os/main.zig");
const sys = @import("sys.zig");
const bench_trace = @import("bench_trace.zig");

const log = std.log.scoped(.win32);

const GetTickCount64 = sys.GetTickCount64;
const processOriginTickMs = bench_trace.processOriginTickMs;
const absolutizeTracePath = bench_trace.absolutizeTracePath;
const queryPerformanceCounter = bench_trace.queryPerformanceCounter;
const queryPerformanceFrequency = bench_trace.queryPerformanceFrequency;

fn renderTraceLiveEnabled(alloc: Allocator) bool {
    const raw = std.process.getEnvVarOwned(alloc, "NOCTTY_RENDER_TRACE_LIVE") catch return false;
    defer alloc.free(raw);
    return std.mem.eql(u8, std.mem.trim(u8, raw, &std.ascii.whitespace), "1");
}

var render_trace_file_claimed = std.atomic.Value(bool).init(false);

pub const RenderTrace = struct {
    pub const OutputProgress = struct {
        generation: u64,
        bytes: u64,
        tick_ms: u64,
        benchmark_end_marker_generation: u64,
        benchmark_end_marker_output_bytes: u64,
    };

    const startup_window_ms: u64 = 1000;
    const startup_paint_gap_ceiling_ms: u64 = 1500;
    const paint_gap_limit_ms: u64 = 300;
    const target_swap_interval_capacity: usize = 2048;

    const PaintGapTargets = struct {
        max_gap_ms: *std.atomic.Value(u64),
        max_gap_ended_at_ms: *std.atomic.Value(u64),
        over_limit_count: *std.atomic.Value(u64),
    };

    path: ?[]const u8 = null,
    live_snapshot: bool = false,
    process_origin_tick_ms: u64 = 0,
    start_tick_ms: u64 = 0,
    renderer_update_frame_count: std.atomic.Value(u64) = .init(0),
    renderer_draw_request_count: std.atomic.Value(u64) = .init(0),
    renderer_core_wakeup_notify_count: std.atomic.Value(u64) = .init(0),
    surface_focus_change_count: std.atomic.Value(u64) = .init(0),
    surface_focused: std.atomic.Value(bool) = .init(true),
    cursor_timer_wakeup_count: std.atomic.Value(u64) = .init(0),
    renderer_repaint_retry_wakeup_count: std.atomic.Value(u64) = .init(0),
    resize_settle_wakeup_count: std.atomic.Value(u64) = .init(0),
    paint_retry_wakeup_count: std.atomic.Value(u64) = .init(0),
    health_recovery_wakeup_count: std.atomic.Value(u64) = .init(0),
    paint_pending_wakeup_count: std.atomic.Value(u64) = .init(0),
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
    renderer_process_output_generation: std.atomic.Value(u64) = .init(0),
    renderer_process_output_bytes: std.atomic.Value(u64) = .init(0),
    renderer_process_output_tick_ms: std.atomic.Value(u64) = .init(0),
    renderer_benchmark_end_marker_generation: std.atomic.Value(u64) = .init(0),
    renderer_benchmark_end_marker_output_bytes: std.atomic.Value(u64) = .init(0),
    renderer_cursor_blinking: std.atomic.Value(bool) = .init(true),
    last_swap_process_output_generation: std.atomic.Value(u64) = .init(0),
    last_swap_process_output_bytes: std.atomic.Value(u64) = .init(0),
    last_swap_process_output_tick_ms: std.atomic.Value(u64) = .init(0),
    last_swap_benchmark_end_marker_generation: std.atomic.Value(u64) = .init(0),
    last_swap_benchmark_end_marker_output_bytes: std.atomic.Value(u64) = .init(0),
    last_swap_qpc_ticks: std.atomic.Value(u64) = .init(0),
    target_active: std.atomic.Value(bool) = .init(false),
    target_process_output_bytes: std.atomic.Value(u64) = .init(0),
    first_target_swap_process_output_generation: std.atomic.Value(u64) = .init(0),
    first_target_swap_process_output_bytes: std.atomic.Value(u64) = .init(0),
    first_target_swap_process_output_tick_ms: std.atomic.Value(u64) = .init(0),
    first_target_swap_benchmark_end_marker_generation: std.atomic.Value(u64) = .init(0),
    first_target_swap_benchmark_end_marker_output_bytes: std.atomic.Value(u64) = .init(0),
    first_target_swap_qpc_ticks: std.atomic.Value(u64) = .init(0),
    target_mutex: std.Thread.Mutex = .{},
    target_swap_interval_qpc_ticks: ?[]u64 = null,
    target_swap_interval_count: usize = 0,
    target_swap_interval_overflow_count: u64 = 0,
    target_swap_interval_last_qpc_ticks: u64 = 0,
    snapshot_sequence: std.atomic.Value(u64) = .init(0),
    qpc_frequency: u64 = 0,
    first_renderer_update_at_ms: std.atomic.Value(u64) = .init(0),
    first_paint_at_ms: std.atomic.Value(u64) = .init(0),
    first_swap_at_ms: std.atomic.Value(u64) = .init(0),
    process_start_to_first_swap_ms: std.atomic.Value(u64) = .init(0),

    pub fn init(alloc: Allocator) RenderTrace {
        const raw = std.process.getEnvVarOwned(
            alloc,
            "NOCTTY_RENDER_TRACE_FILE",
        ) catch return .{};
        errdefer alloc.free(raw);

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            alloc.free(raw);
            return .{};
        }

        const owned = if (trimmed.len == raw.len)
            raw
        else
            alloc.dupe(u8, trimmed) catch {
                alloc.free(raw);
                return .{};
            };
        if (trimmed.len != raw.len) alloc.free(raw);

        // `writeSnapshot` opens the path with `createFileAbsolute`, so the
        // path we retain has to be absolute. Resolving it here (rather than
        // at write time) also keeps the trace pinned to the cwd the process
        // started in. `absolutizeTracePath` takes ownership of `owned`.
        const absolute = absolutizeTracePath(alloc, owned) catch |err| {
            log.warn("render trace path could not be absolutized err={}", .{err});
            return .{};
        };

        return initWithClaimedPath(
            alloc,
            &render_trace_file_claimed,
            absolute,
            processOriginTickMs(),
            renderTraceLiveEnabled(alloc),
        );
    }

    pub fn initWithClaimedPath(
        alloc: Allocator,
        claimed: *std.atomic.Value(bool),
        owned: []const u8,
        process_origin_ms: u64,
        live_snapshot: bool,
    ) RenderTrace {
        // A trace path names one JSON document. The interactive harness waits
        // for the initial surface before seeding tabs, so the first claimant
        // is deterministic. Keeping that claim for the process lifetime stops
        // later tab teardown from overwriting the initial surface's evidence.
        const trace_path = claimTracePath(alloc, claimed, owned) orelse
            return .{};
        const target_swap_intervals = if (live_snapshot)
            alloc.alloc(u64, target_swap_interval_capacity) catch null
        else
            null;
        return .{
            .path = trace_path,
            .live_snapshot = live_snapshot,
            .process_origin_tick_ms = process_origin_ms,
            .start_tick_ms = GetTickCount64(),
            .qpc_frequency = queryPerformanceFrequency(),
            .target_swap_interval_qpc_ticks = target_swap_intervals,
        };
    }

    pub fn deinit(self: *RenderTrace, alloc: Allocator) void {
        defer {
            if (self.target_swap_interval_qpc_ticks) |samples| alloc.free(samples);
            if (self.path) |path| alloc.free(path);
            self.* = .{};
        }

        if (self.path == null) return;
        self.writeSnapshot();
    }

    pub fn enabled(self: *const RenderTrace) bool {
        return self.path != null;
    }

    pub fn noteRendererUpdateFrame(
        self: *RenderTrace,
        progress: ?OutputProgress,
        cursor_blinking: bool,
    ) void {
        if (!self.enabled()) return;
        if (progress) |value| {
            self.renderer_process_output_generation.store(value.generation, .release);
            self.renderer_process_output_bytes.store(value.bytes, .release);
            self.renderer_process_output_tick_ms.store(value.tick_ms, .release);
            self.renderer_benchmark_end_marker_output_bytes.store(value.benchmark_end_marker_output_bytes, .release);
            // The generation is the publication barrier read by the swap
            // thread before it consumes the marker byte count.
            self.renderer_benchmark_end_marker_generation.store(value.benchmark_end_marker_generation, .release);
        }
        self.renderer_cursor_blinking.store(cursor_blinking, .release);
        _ = self.noteTimedCounter(
            &self.renderer_update_frame_count,
            &self.last_renderer_update_tick_ms,
            &self.max_renderer_update_gap_ms,
            &self.max_renderer_update_gap_ended_at_ms,
            &self.first_renderer_update_at_ms,
            null,
            GetTickCount64(),
        );
    }

    pub fn noteRendererDrawRequest(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.renderer_draw_request_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererCoreWakeupNotify(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.renderer_core_wakeup_notify_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteSurfaceFocusChanged(self: *RenderTrace, focused: bool) void {
        if (!self.enabled()) return;
        self.surface_focused.store(focused, .release);
        _ = self.surface_focus_change_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererCursorTimerWakeup(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.cursor_timer_wakeup_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererRepaintRetryWakeup(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.renderer_repaint_retry_wakeup_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererResizeSettleWakeup(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.resize_settle_wakeup_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererPaintRetryWakeup(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.paint_retry_wakeup_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererHealthRecoveryWakeup(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.health_recovery_wakeup_count.fetchAdd(1, .acq_rel);
    }

    pub fn noteRendererPaintPendingWakeup(self: *RenderTrace) void {
        if (!self.enabled()) return;
        _ = self.paint_pending_wakeup_count.fetchAdd(1, .acq_rel);
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
        _ = self.noteTimedCounter(
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
            GetTickCount64(),
        );
    }

    pub fn notePaintDrawDuration(self: *RenderTrace, duration_ms: u64) void {
        if (!self.enabled()) return;
        updateMaxAtomicWithTimestamp(
            &self.max_paint_draw_duration_ms,
            &self.max_paint_draw_duration_at_ms,
            duration_ms,
            elapsedTraceMs(self.start_tick_ms, GetTickCount64()),
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
        const now = GetTickCount64();
        const process_output_generation = self.renderer_process_output_generation.load(.acquire);
        const process_output_bytes = self.renderer_process_output_bytes.load(.acquire);
        const process_output_tick_ms = self.renderer_process_output_tick_ms.load(.acquire);
        const benchmark_end_marker_generation = self.renderer_benchmark_end_marker_generation.load(.acquire);
        const benchmark_end_marker_output_bytes = self.renderer_benchmark_end_marker_output_bytes.load(.acquire);
        const qpc_ticks = queryPerformanceCounter();
        self.last_swap_process_output_generation.store(process_output_generation, .release);
        self.last_swap_process_output_bytes.store(process_output_bytes, .release);
        self.last_swap_process_output_tick_ms.store(process_output_tick_ms, .release);
        self.last_swap_benchmark_end_marker_generation.store(benchmark_end_marker_generation, .release);
        self.last_swap_benchmark_end_marker_output_bytes.store(benchmark_end_marker_output_bytes, .release);
        self.last_swap_qpc_ticks.store(qpc_ticks, .release);
        {
            self.target_mutex.lock();
            defer self.target_mutex.unlock();
            const target_active = self.target_active.load(.acquire);
            self.noteTargetSwapIntervalLocked(qpc_ticks);
            const target_bytes = self.target_process_output_bytes.load(.acquire);
            const captured_qpc_ticks = self.first_target_swap_qpc_ticks.load(.acquire);
            if (shouldCaptureTargetSwap(
                target_active,
                target_bytes,
                process_output_bytes,
                benchmark_end_marker_generation,
                captured_qpc_ticks,
            )) {
                self.first_target_swap_process_output_generation.store(process_output_generation, .release);
                self.first_target_swap_process_output_bytes.store(process_output_bytes, .release);
                self.first_target_swap_process_output_tick_ms.store(process_output_tick_ms, .release);
                self.first_target_swap_benchmark_end_marker_generation.store(benchmark_end_marker_generation, .release);
                self.first_target_swap_benchmark_end_marker_output_bytes.store(benchmark_end_marker_output_bytes, .release);
                self.first_target_swap_qpc_ticks.store(qpc_ticks, .release);
                self.target_active.store(false, .release);
            }
        }
        const first_swap = self.noteTimedCounter(
            &self.swap_buffers_count,
            &self.last_swap_tick_ms,
            &self.max_swap_gap_ms,
            &self.max_swap_gap_ended_at_ms,
            &self.first_swap_at_ms,
            null,
            now,
        );
        if (first_swap) {
            self.process_start_to_first_swap_ms.store(
                elapsedTraceMs(self.process_origin_tick_ms, now),
                .release,
            );
        }
        if (shouldWriteSnapshotAfterSwap(first_swap)) self.writeSnapshot();
    }

    pub fn noteTimedCounter(
        self: *RenderTrace,
        counter: *std.atomic.Value(u64),
        last_tick_ms: *std.atomic.Value(u64),
        max_gap_ms: *std.atomic.Value(u64),
        max_gap_ended_at_ms: *std.atomic.Value(u64),
        first_at_ms: *std.atomic.Value(u64),
        paint_gaps: ?PaintGapTargets,
        now: u64,
    ) bool {
        const elapsed_ms = elapsedTraceMs(self.start_tick_ms, now);
        const first = counter.fetchAdd(1, .acq_rel) == 0;
        _ = first_at_ms.cmpxchgStrong(0, elapsed_ms, .acq_rel, .acquire);
        const prev = last_tick_ms.swap(now, .acq_rel);
        if (prev == 0 or now <= prev) return first;
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
        return first;
    }

    pub fn gapIsSustained(elapsed_ms: u64, gap_ms: u64) bool {
        return elapsed_ms -| gap_ms >= startup_window_ms;
    }

    pub fn gapExceedsPaintLimit(gap_ms: u64) bool {
        return gap_ms > paint_gap_limit_ms;
    }

    pub fn shouldWriteSnapshotAfterSwap(first_swap: bool) bool {
        // Recurring swaps only update atomics. Live evidence is serialized
        // on an explicit window-message request outside SwapBuffers.
        return first_swap;
    }

    pub fn shouldCaptureTargetSwap(
        target_active: bool,
        target_bytes: u64,
        output_bytes: u64,
        benchmark_end_marker_generation: u64,
        captured_qpc_ticks: u64,
    ) bool {
        if (!target_active or captured_qpc_ticks != 0) return false;
        return if (target_bytes == 0)
            benchmark_end_marker_generation != 0
        else
            output_bytes >= target_bytes;
    }

    pub fn noteTargetSwapInterval(self: *RenderTrace, qpc_ticks: u64) void {
        self.target_mutex.lock();
        defer self.target_mutex.unlock();
        self.noteTargetSwapIntervalLocked(qpc_ticks);
    }

    fn noteTargetSwapIntervalLocked(self: *RenderTrace, qpc_ticks: u64) void {
        if (!self.target_active.load(.acquire) or qpc_ticks == 0) return;
        const previous = self.target_swap_interval_last_qpc_ticks;
        self.target_swap_interval_last_qpc_ticks = qpc_ticks;
        if (previous == 0 or qpc_ticks <= previous) return;

        const samples = self.target_swap_interval_qpc_ticks orelse return;
        if (self.target_swap_interval_count == samples.len) {
            self.target_swap_interval_overflow_count +|= 1;
            return;
        }
        samples[self.target_swap_interval_count] = qpc_ticks - previous;
        self.target_swap_interval_count += 1;
    }

    pub fn setTargetOutputBytes(self: *RenderTrace, target_bytes: u64) void {
        if (!self.live_snapshot) return;
        self.target_mutex.lock();
        defer self.target_mutex.unlock();
        self.target_active.store(false, .release);
        self.target_process_output_bytes.store(0, .release);
        self.first_target_swap_process_output_generation.store(0, .release);
        self.first_target_swap_process_output_bytes.store(0, .release);
        self.first_target_swap_process_output_tick_ms.store(0, .release);
        self.first_target_swap_benchmark_end_marker_generation.store(0, .release);
        self.first_target_swap_benchmark_end_marker_output_bytes.store(0, .release);
        self.first_target_swap_qpc_ticks.store(0, .release);
        self.target_swap_interval_count = 0;
        self.target_swap_interval_overflow_count = 0;
        self.target_swap_interval_last_qpc_ticks = 0;
        self.target_process_output_bytes.store(target_bytes, .release);
        self.target_active.store(true, .release);
    }

    pub fn requestSnapshot(self: *RenderTrace) void {
        if (!self.live_snapshot) return;
        self.writeSnapshot();
    }

    pub fn writeSnapshot(self: *RenderTrace) void {
        const trace_path = self.path orelse return;
        self.target_mutex.lock();
        defer self.target_mutex.unlock();
        const file = std.fs.createFileAbsolute(trace_path, .{ .truncate = true }) catch |err| {
            log.warn("render trace snapshot open failed path={s} err={}", .{ trace_path, err });
            return;
        };
        defer file.close();
        const snapshot_sequence = self.snapshot_sequence.fetchAdd(1, .acq_rel) + 1;

        var buffer: [1024]u8 = undefined;
        var writer = file.writer(&buffer);
        const stream = &writer.interface;
        stream.print("{f}", .{std.json.fmt(.{
            .runtime_ms = GetTickCount64() - self.start_tick_ms,
            .snapshot_sequence = snapshot_sequence,
            .startup_window_ms = startup_window_ms,
            .startup_paint_gap_ceiling_ms = startup_paint_gap_ceiling_ms,
            .paint_gap_limit_ms = paint_gap_limit_ms,
            .renderer_update_frame_count = self.renderer_update_frame_count.load(.acquire),
            .renderer_draw_request_count = self.renderer_draw_request_count.load(.acquire),
            .renderer_core_wakeup_notify_count = self.renderer_core_wakeup_notify_count.load(.acquire),
            .surface_focus_change_count = self.surface_focus_change_count.load(.acquire),
            .surface_focused = self.surface_focused.load(.acquire),
            .cursor_timer_wakeup_count = self.cursor_timer_wakeup_count.load(.acquire),
            .renderer_repaint_retry_wakeup_count = self.renderer_repaint_retry_wakeup_count.load(.acquire),
            .resize_settle_wakeup_count = self.resize_settle_wakeup_count.load(.acquire),
            .paint_retry_wakeup_count = self.paint_retry_wakeup_count.load(.acquire),
            .health_recovery_wakeup_count = self.health_recovery_wakeup_count.load(.acquire),
            .paint_pending_wakeup_count = self.paint_pending_wakeup_count.load(.acquire),
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
            .last_swap_at_ms = elapsedTraceMs(
                self.start_tick_ms,
                self.last_swap_tick_ms.load(.acquire),
            ),
            .last_swap_tick_ms = self.last_swap_tick_ms.load(.acquire),
            .last_swap_process_output_generation = self.last_swap_process_output_generation.load(.acquire),
            .last_swap_process_output_bytes = self.last_swap_process_output_bytes.load(.acquire),
            .last_swap_process_output_tick_ms = self.last_swap_process_output_tick_ms.load(.acquire),
            .last_swap_benchmark_end_marker_generation = self.last_swap_benchmark_end_marker_generation.load(.acquire),
            .last_swap_benchmark_end_marker_output_bytes = self.last_swap_benchmark_end_marker_output_bytes.load(.acquire),
            .renderer_cursor_blinking = self.renderer_cursor_blinking.load(.acquire),
            .last_swap_qpc_ticks = self.last_swap_qpc_ticks.load(.acquire),
            .target_active = self.target_active.load(.acquire),
            .target_process_output_bytes = self.target_process_output_bytes.load(.acquire),
            .first_target_swap_process_output_generation = self.first_target_swap_process_output_generation.load(.acquire),
            .first_target_swap_process_output_bytes = self.first_target_swap_process_output_bytes.load(.acquire),
            .first_target_swap_process_output_tick_ms = self.first_target_swap_process_output_tick_ms.load(.acquire),
            .first_target_swap_benchmark_end_marker_generation = self.first_target_swap_benchmark_end_marker_generation.load(.acquire),
            .first_target_swap_benchmark_end_marker_output_bytes = self.first_target_swap_benchmark_end_marker_output_bytes.load(.acquire),
            .first_target_swap_qpc_ticks = self.first_target_swap_qpc_ticks.load(.acquire),
            .target_swap_interval_qpc_ticks = if (self.target_swap_interval_qpc_ticks) |samples|
                samples[0..self.target_swap_interval_count]
            else
                &[_]u64{},
            .target_swap_interval_overflow_count = self.target_swap_interval_overflow_count,
            .qpc_frequency = self.qpc_frequency,
            .process_start_to_first_swap_ms = self.process_start_to_first_swap_ms.load(.acquire),
        }, .{})}) catch return;
        stream.flush() catch return;
    }
};

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
    const first_trace = RenderTrace.initWithClaimedPath(std.testing.allocator, &claimed, first, 0, false);
    defer if (first_trace.path) |path| std.testing.allocator.free(path);
    try std.testing.expect(first_trace.path != null);

    const second = try std.testing.allocator.dupe(u8, "second.json");
    const second_trace = RenderTrace.initWithClaimedPath(std.testing.allocator, &claimed, second, 0, false);
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

test "win32 live render trace snapshots stay out of recurring swap hot path" {
    try std.testing.expect(RenderTrace.shouldWriteSnapshotAfterSwap(true));
    try std.testing.expect(!RenderTrace.shouldWriteSnapshotAfterSwap(false));
}

test "win32 render trace captures only the first swap meeting an armed output target" {
    try std.testing.expect(!RenderTrace.shouldCaptureTargetSwap(false, 100, 100, 0, 0));
    try std.testing.expect(!RenderTrace.shouldCaptureTargetSwap(true, 100, 99, 0, 0));
    try std.testing.expect(RenderTrace.shouldCaptureTargetSwap(true, 100, 100, 0, 0));
    try std.testing.expect(!RenderTrace.shouldCaptureTargetSwap(true, 100, 101, 0, 50));
}

test "win32 transformed alt-screen target waits for a committed end marker" {
    try std.testing.expect(!RenderTrace.shouldCaptureTargetSwap(true, 0, 60_800, 0, 0));
    try std.testing.expect(RenderTrace.shouldCaptureTargetSwap(true, 0, 60_800, 7, 0));
    try std.testing.expect(!RenderTrace.shouldCaptureTargetSwap(true, 0, 60_800, 8, 50));
}

test "win32 render trace preserves cursor mode from frame snapshot" {
    var trace: RenderTrace = .{ .path = "unused" };
    trace.noteRendererUpdateFrame(.{
        .generation = 1,
        .bytes = 16,
        .tick_ms = 2,
        .benchmark_end_marker_generation = 0,
        .benchmark_end_marker_output_bytes = 0,
    }, false);
    try std.testing.expect(!trace.renderer_cursor_blinking.load(.acquire));
}

test "win32 render trace counts frame updates without output progress" {
    var trace: RenderTrace = .{ .path = "unused" };
    trace.noteRendererUpdateFrame(null, false);
    try std.testing.expectEqual(@as(u64, 1), trace.renderer_update_frame_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), trace.renderer_process_output_generation.load(.acquire));
}

test "win32 render trace attributes every renderer wake source" {
    var trace: RenderTrace = .{ .path = "unused" };
    trace.noteRendererCoreWakeupNotify();
    trace.noteSurfaceFocusChanged(false);
    trace.noteRendererCursorTimerWakeup();
    trace.noteRendererRepaintRetryWakeup();
    trace.noteRendererResizeSettleWakeup();
    trace.noteRendererPaintRetryWakeup();
    trace.noteRendererHealthRecoveryWakeup();
    trace.noteRendererPaintPendingWakeup();

    try std.testing.expectEqual(@as(u64, 1), trace.renderer_core_wakeup_notify_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), trace.surface_focus_change_count.load(.acquire));
    try std.testing.expect(!trace.surface_focused.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), trace.cursor_timer_wakeup_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), trace.renderer_repaint_retry_wakeup_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), trace.resize_settle_wakeup_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), trace.paint_retry_wakeup_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), trace.health_recovery_wakeup_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), trace.paint_pending_wakeup_count.load(.acquire));
}

test "win32 render trace scopes successful swap intervals to the armed target" {
    var storage: [4]u64 = undefined;
    var trace: RenderTrace = .{
        .target_active = .init(true),
        .target_swap_interval_qpc_ticks = &storage,
    };

    trace.noteTargetSwapInterval(100);
    trace.noteTargetSwapInterval(116);
    trace.noteTargetSwapInterval(149);
    try std.testing.expectEqualSlices(u64, &.{ 16, 33 }, storage[0..trace.target_swap_interval_count]);

    trace.target_active.store(false, .release);
    trace.noteTargetSwapInterval(200);
    try std.testing.expectEqual(@as(usize, 2), trace.target_swap_interval_count);
}

test "win32 render trace rearm resets target evidence as one critical section" {
    var storage: [4]u64 = undefined;
    var trace: RenderTrace = .{
        .live_snapshot = true,
        .target_swap_interval_qpc_ticks = &storage,
    };

    trace.setTargetOutputBytes(100);
    trace.noteTargetSwapInterval(10);
    trace.noteTargetSwapInterval(20);
    trace.first_target_swap_process_output_bytes.store(100, .release);
    trace.first_target_swap_qpc_ticks.store(20, .release);

    trace.setTargetOutputBytes(200);
    try std.testing.expect(trace.target_active.load(.acquire));
    try std.testing.expectEqual(@as(u64, 200), trace.target_process_output_bytes.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), trace.first_target_swap_process_output_bytes.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), trace.first_target_swap_qpc_ticks.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), trace.target_swap_interval_count);
    try std.testing.expectEqual(@as(u64, 0), trace.target_swap_interval_last_qpc_ticks);
}
