//! Benchmark-only Win32 tracing.
//!
//! Nothing here is a product path. It exists so `test/windows/bench-windows.ps1`
//! can attribute per-pane memory and startup work to exact lifecycle stages
//! instead of guessing from process totals. The trace is inert unless the
//! benchmark environment variables are present.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const internal_os = @import("../../os/main.zig");
const win32_types = @import("../win32_types.zig");
const sys = @import("sys.zig");
const pixel_format = @import("pixel_format.zig");

const log = std.log.scoped(.win32);

const DWORD = win32_types.DWORD;
const HANDLE = win32_types.HANDLE;
const BOOL = win32_types.BOOL;
const GetTickCount64 = sys.GetTickCount64;
const WglPixelFormatProvenance = pixel_format.WglPixelFormatProvenance;

// Benchmark-only Win32 entry points; deliberately not in sys.zig, which
// carries the product surface.
extern "kernel32" fn QueryPerformanceCounter(value: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(value: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn K32GetProcessMemoryInfo(
    process: windows.HANDLE,
    counters: *PROCESS_MEMORY_COUNTERS_EX,
    cb: DWORD,
) callconv(.winapi) BOOL;

var process_origin_tick_ms = std.atomic.Value(u64).init(0);
var memory_stage_trace_write_mutex: std.Thread.Mutex = .{};

pub const BenchmarkMemoryStage = enum {
    surface_begin,
    child_hwnd_created,
    child_dc_acquired,
    wgl_context_current,
    opengl_functions_loaded,
    renderer_initialized,
    terminal_initialized,
    renderer_thread_spawned,
    io_thread_spawned,
    threads_started,
    io_reader_spawned,
    first_renderer_update_complete,
    target_resize_begin,
    target_resize_complete,
    first_draw_resources_complete,
    first_successful_swap,
    destroy_begin,
    core_deinit_complete,
    wgl_context_unbound,
    wgl_context_deleted,
    dc_released,
    surface_destroy_complete,
};

pub const BenchmarkRenderTargetStrategy = enum(u8) {
    offscreen,
    default_framebuffer,
};

pub const RenderTargetProvenance = struct {
    strategy: BenchmarkRenderTargetStrategy,
    default_framebuffer_srgb: bool,
    linear_blending: bool,
};

const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: DWORD,
    page_fault_count: DWORD,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
};

pub const MemoryStageTrace = struct {
    path: ?[]const u8 = null,
    trace_sequence: std.atomic.Value(u64) = .init(0),
    surface_width_px: std.atomic.Value(u32) = .init(0),
    surface_height_px: std.atomic.Value(u32) = .init(0),
    cell_width_px: std.atomic.Value(u32) = .init(0),
    cell_height_px: std.atomic.Value(u32) = .init(0),
    columns: std.atomic.Value(u32) = .init(0),
    rows: std.atomic.Value(u32) = .init(0),
    wgl_pixel_format_ready: std.atomic.Value(bool) = .init(false),
    wgl_pixel_format_index: std.atomic.Value(u32) = .init(0),
    wgl_color_bits: std.atomic.Value(u8) = .init(0),
    wgl_alpha_bits: std.atomic.Value(u8) = .init(0),
    wgl_depth_bits: std.atomic.Value(u8) = .init(0),
    wgl_stencil_bits: std.atomic.Value(u8) = .init(0),
    wgl_double_buffer: std.atomic.Value(bool) = .init(false),
    wgl_stereo: std.atomic.Value(bool) = .init(false),
    wgl_accum_bits: std.atomic.Value(u8) = .init(0),
    wgl_aux_buffers: std.atomic.Value(u8) = .init(0),
    wgl_selection_source: std.atomic.Value(u8) = .init(0),
    wgl_srgb_capable: std.atomic.Value(bool) = .init(false),
    wgl_multisample_query_supported: std.atomic.Value(bool) = .init(false),
    wgl_sample_buffers: std.atomic.Value(u8) = .init(0),
    wgl_samples: std.atomic.Value(u8) = .init(0),
    wgl_total_format_count: std.atomic.Value(u16) = .init(0),
    wgl_candidate_count: std.atomic.Value(u16) = .init(0),
    render_target_ready: std.atomic.Value(bool) = .init(false),
    render_target_strategy: std.atomic.Value(u8) = .init(0),
    default_framebuffer_srgb: std.atomic.Value(bool) = .init(false),
    render_target_linear_blending: std.atomic.Value(bool) = .init(false),
    published_surface_id: std.atomic.Value(u64) = .init(0),
    renderer_thread_recorded: std.atomic.Value(bool) = .init(false),
    io_thread_recorded: std.atomic.Value(bool) = .init(false),
    io_reader_recorded: std.atomic.Value(bool) = .init(false),
    first_renderer_update_recorded: std.atomic.Value(bool) = .init(false),
    target_resize_begin_recorded: std.atomic.Value(bool) = .init(false),
    target_resize_complete_recorded: std.atomic.Value(bool) = .init(false),
    first_draw_resources_recorded: std.atomic.Value(bool) = .init(false),
    first_swap_recorded: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) MemoryStageTrace {
        const raw = std.process.getEnvVarOwned(
            alloc,
            "NOCTTY_BENCH_MEMORY_STAGE_TRACE_FILE",
        ) catch return .{};
        errdefer alloc.free(raw);

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            alloc.free(raw);
            return .{};
        }
        if (trimmed.len == raw.len) return .{
            .path = raw,
        };

        const owned = alloc.dupe(u8, trimmed) catch {
            alloc.free(raw);
            return .{};
        };
        alloc.free(raw);
        return .{
            .path = owned,
        };
    }

    pub fn deinit(self: *MemoryStageTrace, alloc: Allocator) void {
        if (self.path) |path| alloc.free(path);
        self.* = .{};
    }

    pub fn enabled(self: *const MemoryStageTrace) bool {
        return self.path != null;
    }

    pub fn note(
        self: *MemoryStageTrace,
        stage: BenchmarkMemoryStage,
        surface_token: u64,
        surface_id: ?u64,
    ) void {
        const path = self.path orelse return;
        const resolved_surface_id = self.surfaceId(surface_id);

        memory_stage_trace_write_mutex.lock();
        defer memory_stage_trace_write_mutex.unlock();
        const private_bytes = queryProcessPrivateBytes() orelse return;
        const trace_sequence = self.trace_sequence.fetchAdd(1, .acq_rel) + 1;
        const surface_width_px = self.surface_width_px.load(.acquire);
        const surface_height_px = self.surface_height_px.load(.acquire);
        const cell_width_px = self.cell_width_px.load(.acquire);
        const cell_height_px = self.cell_height_px.load(.acquire);
        const columns = self.columns.load(.acquire);
        const rows = self.rows.load(.acquire);
        const wgl_pixel_format = self.wglPixelFormat();
        const render_target = self.renderTargetProvenance();

        const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;

        var buffer: [512]u8 = undefined;
        // This trace is JSONL. The positional writer starts at offset zero
        // even after seekFromEnd and would overwrite every earlier surface
        // identity record; streaming mode honors the append seek.
        var writer = file.writerStreaming(&buffer);
        const stream = &writer.interface;
        stream.print("{f}\n", .{std.json.fmt(.{
            .stage = @tagName(stage),
            .surface_token = surface_token,
            .surface_id = resolved_surface_id,
            .private_bytes = private_bytes,
            .tick_ms = GetTickCount64(),
            .trace_sequence = trace_sequence,
            .surface_width_px = if (surface_width_px == 0) null else surface_width_px,
            .surface_height_px = if (surface_height_px == 0) null else surface_height_px,
            .cell_width_px = if (cell_width_px == 0) null else cell_width_px,
            .cell_height_px = if (cell_height_px == 0) null else cell_height_px,
            .columns = if (columns == 0) null else columns,
            .rows = if (rows == 0) null else rows,
            .wgl_pixel_format_index = if (wgl_pixel_format) |value| value.index else null,
            .wgl_color_bits = if (wgl_pixel_format) |value| value.color_bits else null,
            .wgl_alpha_bits = if (wgl_pixel_format) |value| value.alpha_bits else null,
            .wgl_depth_bits = if (wgl_pixel_format) |value| value.depth_bits else null,
            .wgl_stencil_bits = if (wgl_pixel_format) |value| value.stencil_bits else null,
            .wgl_double_buffer = if (wgl_pixel_format) |value| value.double_buffer else null,
            .wgl_stereo = if (wgl_pixel_format) |value| value.stereo else null,
            .wgl_accum_bits = if (wgl_pixel_format) |value| value.accum_bits else null,
            .wgl_aux_buffers = if (wgl_pixel_format) |value| value.aux_buffers else null,
            .wgl_selection_source = if (wgl_pixel_format) |value| @tagName(value.selection_source) else null,
            .wgl_srgb_capable = if (wgl_pixel_format) |value| value.srgb_capable else null,
            .wgl_multisample_query_supported = if (wgl_pixel_format) |value| value.multisample_query_supported else null,
            .wgl_sample_buffers = if (wgl_pixel_format) |value| value.sample_buffers else null,
            .wgl_samples = if (wgl_pixel_format) |value| value.samples else null,
            .wgl_total_format_count = if (wgl_pixel_format) |value| value.total_format_count else null,
            .wgl_candidate_count = if (wgl_pixel_format) |value| value.candidate_count else null,
            .render_target_strategy = if (render_target) |value| @tagName(value.strategy) else null,
            .default_framebuffer_srgb = if (render_target) |value| value.default_framebuffer_srgb else null,
            .render_target_linear_blending = if (render_target) |value| value.linear_blending else null,
        }, .{})}) catch return;
        stream.flush() catch return;
    }

    pub fn setGeometry(
        self: *MemoryStageTrace,
        surface_width_px: u32,
        surface_height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
        columns: u32,
        rows: u32,
    ) void {
        self.surface_width_px.store(surface_width_px, .release);
        self.surface_height_px.store(surface_height_px, .release);
        self.cell_width_px.store(cell_width_px, .release);
        self.cell_height_px.store(cell_height_px, .release);
        self.columns.store(columns, .release);
        self.rows.store(rows, .release);
    }

    pub fn publishSurfaceId(self: *MemoryStageTrace, surface_id: u64) void {
        self.published_surface_id.store(surface_id, .release);
    }

    pub fn setWglPixelFormat(
        self: *MemoryStageTrace,
        value: WglPixelFormatProvenance,
    ) void {
        self.wgl_pixel_format_index.store(value.index, .monotonic);
        self.wgl_color_bits.store(value.color_bits, .monotonic);
        self.wgl_alpha_bits.store(value.alpha_bits, .monotonic);
        self.wgl_depth_bits.store(value.depth_bits, .monotonic);
        self.wgl_stencil_bits.store(value.stencil_bits, .monotonic);
        self.wgl_double_buffer.store(value.double_buffer, .monotonic);
        self.wgl_stereo.store(value.stereo, .monotonic);
        self.wgl_accum_bits.store(value.accum_bits, .monotonic);
        self.wgl_aux_buffers.store(value.aux_buffers, .monotonic);
        self.wgl_selection_source.store(@intFromEnum(value.selection_source), .monotonic);
        self.wgl_srgb_capable.store(value.srgb_capable, .monotonic);
        self.wgl_multisample_query_supported.store(value.multisample_query_supported, .monotonic);
        self.wgl_sample_buffers.store(value.sample_buffers orelse 0, .monotonic);
        self.wgl_samples.store(value.samples orelse 0, .monotonic);
        self.wgl_total_format_count.store(value.total_format_count orelse 0, .monotonic);
        self.wgl_candidate_count.store(value.candidate_count orelse 0, .monotonic);
        self.wgl_pixel_format_ready.store(true, .release);
    }

    pub fn wglPixelFormat(self: *const MemoryStageTrace) ?WglPixelFormatProvenance {
        if (!self.wgl_pixel_format_ready.load(.acquire)) return null;
        return .{
            .index = self.wgl_pixel_format_index.load(.monotonic),
            .color_bits = self.wgl_color_bits.load(.monotonic),
            .alpha_bits = self.wgl_alpha_bits.load(.monotonic),
            .depth_bits = self.wgl_depth_bits.load(.monotonic),
            .stencil_bits = self.wgl_stencil_bits.load(.monotonic),
            .double_buffer = self.wgl_double_buffer.load(.monotonic),
            .stereo = self.wgl_stereo.load(.monotonic),
            .accum_bits = self.wgl_accum_bits.load(.monotonic),
            .aux_buffers = self.wgl_aux_buffers.load(.monotonic),
            .selection_source = @enumFromInt(self.wgl_selection_source.load(.monotonic)),
            .srgb_capable = self.wgl_srgb_capable.load(.monotonic),
            .multisample_query_supported = self.wgl_multisample_query_supported.load(.monotonic),
            .sample_buffers = if (self.wgl_multisample_query_supported.load(.monotonic))
                self.wgl_sample_buffers.load(.monotonic)
            else
                null,
            .samples = if (self.wgl_multisample_query_supported.load(.monotonic))
                self.wgl_samples.load(.monotonic)
            else
                null,
            .total_format_count = switch (self.wgl_total_format_count.load(.monotonic)) {
                0 => null,
                else => |value| value,
            },
            .candidate_count = switch (self.wgl_candidate_count.load(.monotonic)) {
                0 => null,
                else => |value| value,
            },
        };
    }

    pub fn setRenderTargetProvenance(
        self: *MemoryStageTrace,
        strategy: BenchmarkRenderTargetStrategy,
        default_framebuffer_srgb: bool,
        linear_blending: bool,
    ) void {
        self.render_target_strategy.store(@intFromEnum(strategy), .monotonic);
        self.default_framebuffer_srgb.store(default_framebuffer_srgb, .monotonic);
        self.render_target_linear_blending.store(linear_blending, .monotonic);
        self.render_target_ready.store(true, .release);
    }

    pub fn renderTargetProvenance(self: *const MemoryStageTrace) ?RenderTargetProvenance {
        if (!self.render_target_ready.load(.acquire)) return null;
        return .{
            .strategy = @enumFromInt(self.render_target_strategy.load(.monotonic)),
            .default_framebuffer_srgb = self.default_framebuffer_srgb.load(.monotonic),
            .linear_blending = self.render_target_linear_blending.load(.monotonic),
        };
    }

    pub fn surfaceId(self: *const MemoryStageTrace, explicit: ?u64) ?u64 {
        if (explicit) |surface_id| return surface_id;
        const published = self.published_surface_id.load(.acquire);
        return if (published == 0) null else published;
    }

    pub fn noteOnce(
        self: *MemoryStageTrace,
        recorded: *std.atomic.Value(bool),
        stage: BenchmarkMemoryStage,
        surface_token: u64,
        surface_id: ?u64,
    ) void {
        if (recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        self.note(stage, surface_token, surface_id);
    }

    pub fn noteRendererThreadSpawned(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        self.noteOnce(&self.renderer_thread_recorded, .renderer_thread_spawned, surface_token, surface_id);
    }

    pub fn noteIoThreadSpawned(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        self.noteOnce(&self.io_thread_recorded, .io_thread_spawned, surface_token, surface_id);
    }

    pub fn noteIoReaderSpawned(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        self.noteOnce(&self.io_reader_recorded, .io_reader_spawned, surface_token, surface_id);
    }

    pub fn noteFirstRendererUpdateComplete(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        self.noteOnce(&self.first_renderer_update_recorded, .first_renderer_update_complete, surface_token, self.surfaceId(surface_id));
    }

    pub fn noteTargetResizeBegin(
        self: *MemoryStageTrace,
        surface_token: u64,
        surface_id: ?u64,
        strategy: BenchmarkRenderTargetStrategy,
        default_framebuffer_srgb: bool,
        linear_blending: bool,
    ) void {
        self.setRenderTargetProvenance(
            strategy,
            default_framebuffer_srgb,
            linear_blending,
        );
        self.noteOnce(
            &self.target_resize_begin_recorded,
            .target_resize_begin,
            surface_token,
            self.surfaceId(surface_id),
        );
    }

    pub fn noteTargetResizeComplete(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        self.noteOnce(
            &self.target_resize_complete_recorded,
            .target_resize_complete,
            surface_token,
            self.surfaceId(surface_id),
        );
    }

    pub fn noteFirstDrawResourcesComplete(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        self.noteOnce(&self.first_draw_resources_recorded, .first_draw_resources_complete, surface_token, self.surfaceId(surface_id));
    }

    pub fn noteFirstSuccessfulSwap(
        self: *MemoryStageTrace,
        surface_token: u64,
        surface_id: ?u64,
    ) void {
        if (!self.claimFirstSwapObservation()) return;
        self.note(.first_successful_swap, surface_token, self.surfaceId(surface_id));
    }

    pub fn claimFirstSwapObservation(self: *MemoryStageTrace) bool {
        return self.first_swap_recorded.cmpxchgStrong(
            false,
            true,
            .acq_rel,
            .acquire,
        ) == null;
    }
};

pub fn captureProcessOrigin() void {
    _ = processOriginTickMs();
}

pub fn processOriginTickMs() u64 {
    const existing = process_origin_tick_ms.load(.acquire);
    if (existing != 0) return existing;

    const now = GetTickCount64();
    return process_origin_tick_ms.cmpxchgStrong(0, now, .acq_rel, .acquire) orelse now;
}

pub fn queryProcessPrivateBytes() ?u64 {
    var counters: PROCESS_MEMORY_COUNTERS_EX = undefined;
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS_EX);
    if (K32GetProcessMemoryInfo(
        windows.kernel32.GetCurrentProcess(),
        &counters,
        counters.cb,
    ) == 0) return null;
    return @intCast(counters.private_usage);
}

pub fn queryPerformanceCounter() u64 {
    var value: i64 = 0;
    if (QueryPerformanceCounter(&value) == 0 or value < 0) return 0;
    return @intCast(value);
}

pub fn queryPerformanceFrequency() u64 {
    var value: i64 = 0;
    if (QueryPerformanceFrequency(&value) == 0 or value <= 0) return 0;
    return @intCast(value);
}

test "win32 memory stage trace claims exactly one first swap observation" {
    var trace: MemoryStageTrace = .{};
    try std.testing.expect(trace.claimFirstSwapObservation());
    try std.testing.expect(!trace.claimFirstSwapObservation());
}

test "win32 memory stage trace publishes direct target compatibility" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "memory-stage-target.jsonl", .data = "" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "memory-stage-target.jsonl");
    defer std.testing.allocator.free(path);

    var trace: MemoryStageTrace = .{ .path = path };
    trace.publishSurfaceId(22);
    trace.noteTargetResizeBegin(
        11,
        null,
        .default_framebuffer,
        true,
        true,
    );

    const contents = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "memory-stage-target.jsonl",
        4096,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"stage\":\"target_resize_begin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"surface_id\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"render_target_strategy\":\"default_framebuffer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"default_framebuffer_srgb\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"render_target_linear_blending\":true") != null);
}

test "win32 memory stage trace claims each concurrent boundary exactly once" {
    var trace: MemoryStageTrace = .{};
    try std.testing.expect(trace.renderer_thread_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.renderer_thread_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) != null);
    try std.testing.expect(trace.io_thread_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.io_reader_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.first_renderer_update_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.target_resize_begin_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.target_resize_complete_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.first_draw_resources_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
}

test "win32 memory stage trace preserves every surface identity record" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "memory-stage.jsonl", .data = "" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "memory-stage.jsonl");
    defer std.testing.allocator.free(path);

    var trace: MemoryStageTrace = .{ .path = path };
    trace.note(.surface_begin, 11, null);
    trace.setGeometry(1400, 900, 10, 20, 140, 45);
    trace.note(.terminal_initialized, 11, 22);

    const contents = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "memory-stage.jsonl",
        4096,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"stage\":\"surface_begin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"surface_id\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"trace_sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"trace_sequence\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"surface_width_px\":1400") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"columns\":140") != null);
}

test "win32 memory stage trace publishes core identity before worker stages" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "memory-stage-worker-id.jsonl", .data = "" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "memory-stage-worker-id.jsonl");
    defer std.testing.allocator.free(path);

    var trace: MemoryStageTrace = .{ .path = path };
    trace.publishSurfaceId(22);
    // The renderer can complete its first update before runtime Surface.init
    // returns and flips core_initialized. The trace must still carry the ID
    // that core Surface.init assigned before starting either worker.
    trace.noteFirstRendererUpdateComplete(11, null);

    const contents = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "memory-stage-worker-id.jsonl",
        4096,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"stage\":\"first_renderer_update_complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"surface_id\":22") != null);
}

test "win32 memory stage trace retains published identity through teardown" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "memory-stage-teardown-id.jsonl", .data = "" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "memory-stage-teardown-id.jsonl");
    defer std.testing.allocator.free(path);

    var trace: MemoryStageTrace = .{ .path = path };
    trace.publishSurfaceId(22);
    trace.note(.destroy_begin, 11, null);

    const contents = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "memory-stage-teardown-id.jsonl",
        4096,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"stage\":\"destroy_begin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"surface_id\":22") != null);
}
