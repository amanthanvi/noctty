//! Opt-in Win32 benchmark and stage tracing.
//!
//! `test/windows/bench-windows.ps1` attributes per-pane memory and startup work
//! to exact lifecycle stages. Settings-open diagnostics record only ordered
//! stage names and timestamps. Traces are inert without their environment flags.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

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

pub const SettingsOpenStage = enum {
    f9_keydown,
    f9_before_core_initialized,
    open_config_action,
    settings_open_enter,
    settings_open_ok,
    settings_open_error,
};

/// The steps `SettingsWindow.open` takes to build the window. A stamp is taken
/// as a step ends, so the time since the stamp before it is that step's.
pub const SettingsCreationStage = enum {
    create_begin,
    create_config,
    create_frame,
    create_theme,
    create_fonts,
    create_rail,
    create_form,
    create_actions,
    create_annotate,
    create_refresh,
    create_layout,
    create_show,
    create_end,
};

/// Stamps `SettingsWindow.open` takes while it builds the window, kept in
/// memory and written by the App after the open returns: one file write per
/// open instead of one per stage, and none inside the work being timed.
/// Disabled, `mark` reads one flag: no clock, syscall or allocation.
pub const SettingsCreationStamps = struct {
    pub const capacity = 32;

    enabled: bool = false,
    len: usize = 0,
    stages: [capacity]SettingsCreationStage = undefined,
    ticks: [capacity]u64 = undefined,
    counters: [capacity]i64 = undefined,

    pub fn mark(self: *SettingsCreationStamps, stage: SettingsCreationStage) void {
        if (!self.enabled or self.len == capacity) return;
        var counter: i64 = 0;
        _ = QueryPerformanceCounter(&counter);
        self.stages[self.len] = stage;
        self.ticks[self.len] = GetTickCount64();
        self.counters[self.len] = counter;
        self.len += 1;
    }
};

/// Ordered App/UI-thread diagnostics, separate from per-surface memory metrics.
/// Only static stages and timestamps are accepted; no keys, config, or text.
pub const SettingsOpenTrace = struct {
    pub const max_records = 1024;
    pub const max_record_bytes = 128;

    file: ?std.fs.File = null,
    records: u16 = 0,

    /// Read the opt-in once per App lifetime. An inherited environment must
    /// not make unit tests write files; tests exercise initPath explicitly.
    pub fn init(alloc: Allocator) SettingsOpenTrace {
        return initEnv(alloc, "KORETERM_SETTINGS_OPEN_TRACE");
    }

    fn initEnv(alloc: Allocator, name: []const u8) SettingsOpenTrace {
        if (builtin.is_test) return .{};
        const path = std.process.getEnvVarOwned(alloc, name) catch return .{};
        defer alloc.free(path);
        return initPath(path) catch .{};
    }

    fn initPath(path: []const u8) !SettingsOpenTrace {
        if (builtin.os.tag == .windows and @import("../../os/path.zig").isNetworkOrDevicePath(path))
            return error.NetworkOrDeviceTracePath;
        if (!std.fs.path.isAbsolute(path)) return error.RelativeTracePath;
        // Zig calls a root-relative Windows path (\trace) absolute, too.
        // Require a drive/share so the destination cannot depend on cwd.
        if (builtin.os.tag == .windows and std.fs.path.diskDesignatorWindows(path).len == 0)
            return error.RelativeTracePath;
        return .{ .file = try std.fs.createFileAbsolute(path, .{ .exclusive = true, .truncate = false }) };
    }

    pub fn enabled(self: *const SettingsOpenTrace) bool {
        return self.file != null;
    }

    pub fn deinit(self: *SettingsOpenTrace) void {
        if (self.file) |file| file.close();
        self.file = null;
    }

    /// App owns the handle and all calls run on its UI thread. Disabled calls
    /// only check the handle: no allocation, environment read, or syscall.
    pub fn note(self: *SettingsOpenTrace, stage: SettingsOpenStage) void {
        const file = self.file orelse return;
        var buf: [max_record_bytes]u8 = undefined;
        const line = formatRecord(&buf, GetTickCount64(), stage) catch {
            self.deinit();
            return;
        };
        self.writeRecord(file, line);
    }

    /// Write the creation stamps one open took, in one write, and empty them.
    /// Each record keeps its own tick and adds the performance counter in
    /// microseconds, which resolves what the 15.6 ms tick cannot.
    pub fn noteCreation(self: *SettingsOpenTrace, stamps: *SettingsCreationStamps) void {
        defer stamps.len = 0;
        const file = self.file orelse return;
        var frequency: i64 = 0;
        if (QueryPerformanceFrequency(&frequency) == 0 or frequency <= 0) return;
        var buf: [SettingsCreationStamps.capacity * max_record_bytes]u8 = undefined;
        var used: usize = 0;
        var count: u16 = 0;
        for (stamps.stages[0..stamps.len], stamps.ticks[0..stamps.len], stamps.counters[0..stamps.len]) |stage, tick, counter| {
            if (self.records + count == max_records) break;
            const line = formatCreationRecord(buf[used..][0..max_record_bytes], tick, stage, counterMicroseconds(counter, frequency)) catch {
                self.deinit();
                return;
            };
            used += line.len;
            count += 1;
        }
        if (count == 0) return;
        file.writeAll(buf[0..used]) catch {
            self.deinit();
            return;
        };
        self.records += count;
        if (self.records == max_records) self.deinit();
    }

    fn writeRecord(self: *SettingsOpenTrace, file: std.fs.File, line: []const u8) void {
        file.writeAll(line) catch {
            self.deinit();
            return;
        };
        self.records += 1;
        if (self.records == max_records) self.deinit();
    }

    fn formatRecord(buf: []u8, tick_ms: u64, stage: SettingsOpenStage) ![]const u8 {
        return std.fmt.bufPrint(buf, "{{\"tick_ms\":{d},\"stage\":\"{s}\"}}\n", .{ tick_ms, @tagName(stage) });
    }

    fn formatCreationRecord(buf: []u8, tick_ms: u64, stage: SettingsCreationStage, qpc_us: u64) ![]const u8 {
        return std.fmt.bufPrint(buf, "{{\"tick_ms\":{d},\"stage\":\"{s}\",\"qpc_us\":{d}}}\n", .{ tick_ms, @tagName(stage), qpc_us });
    }

    fn counterMicroseconds(counter: i64, frequency: i64) u64 {
        if (counter <= 0) return 0;
        return @intCast(@divTrunc(@as(i128, counter) * std.time.us_per_s, @as(i128, frequency)));
    }
};

/// Opt-in receipts from the Settings HWND thread, immediately around the
/// subclass's call into the native CB_SHOWDROPDOWN handler. This distinguishes
/// a UIA request from a message actually delivered to the control. No text,
/// configuration values, process arguments or input state is recorded.
pub const SettingsComboTrace = struct {
    const max_record_bytes = 192;
    pub const Event = enum { action_received, action_returned, focus_lost, capture_changed, closeup };
    inner: SettingsOpenTrace = .{},

    pub fn init(alloc: Allocator) SettingsComboTrace {
        return .{ .inner = SettingsOpenTrace.initEnv(alloc, "KORETERM_SETTINGS_COMBO_TRACE") };
    }

    pub fn deinit(self: *SettingsComboTrace) void {
        self.inner.deinit();
    }

    pub fn enabled(self: *const SettingsComboTrace) bool {
        return self.inner.enabled();
    }

    pub fn note(self: *SettingsComboTrace, control_id: i32, show: bool, dropped: bool, result: ?isize) void {
        const file = self.inner.file orelse return;
        var buf: [max_record_bytes]u8 = undefined;
        const line = formatRecord(&buf, GetTickCount64(), control_id, show, dropped, result) catch {
            self.deinit();
            return;
        };
        self.inner.writeRecord(file, line);
    }

    pub fn noteEvent(self: *SettingsComboTrace, event: Event, control_id: i32, dropped: bool) void {
        const file = self.inner.file orelse return;
        var buf: [max_record_bytes]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{{\"tick_ms\":{d},\"stage\":\"{s}\",\"control_id\":{d},\"dropped\":{}}}\n", .{ GetTickCount64(), @tagName(event), control_id, dropped }) catch {
            self.deinit();
            return;
        };
        self.inner.writeRecord(file, line);
    }

    fn formatRecord(buf: []u8, tick_ms: u64, control_id: i32, show: bool, dropped: bool, result: ?isize) ![]const u8 {
        if (result) |value| return std.fmt.bufPrint(buf, "{{\"tick_ms\":{d},\"stage\":\"show_returned\",\"control_id\":{d},\"show\":{},\"dropped\":{},\"result\":{d}}}\n", .{ tick_ms, control_id, show, dropped, value });
        return std.fmt.bufPrint(buf, "{{\"tick_ms\":{d},\"stage\":\"show_received\",\"control_id\":{d},\"show\":{},\"dropped\":{}}}\n", .{ tick_ms, control_id, show, dropped });
    }
};

test "Settings combo trace records native dropdown delivery without control text" {
    var buf: [SettingsComboTrace.max_record_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"tick_ms\":99,\"stage\":\"show_received\",\"control_id\":405,\"show\":true,\"dropped\":false}\n",
        try SettingsComboTrace.formatRecord(&buf, 99, 405, true, false, null),
    );
    try std.testing.expectEqualStrings(
        "{\"tick_ms\":100,\"stage\":\"show_returned\",\"control_id\":405,\"show\":false,\"dropped\":true,\"result\":0}\n",
        try SettingsComboTrace.formatRecord(&buf, 100, 405, false, true, 0),
    );
    _ = try SettingsComboTrace.formatRecord(&buf, std.math.maxInt(u64), std.math.minInt(i32), false, false, std.math.minInt(isize));
}

test "Settings open trace formatter emits only stage and timestamp" {
    var buf: [SettingsOpenTrace.max_record_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"tick_ms\":99,\"stage\":\"f9_keydown\"}\n",
        try SettingsOpenTrace.formatRecord(&buf, 99, .f9_keydown),
    );
    try std.testing.expectEqualStrings(
        "{\"tick_ms\":100,\"stage\":\"settings_open_error\"}\n",
        try SettingsOpenTrace.formatRecord(&buf, 100, .settings_open_error),
    );
    inline for (std.meta.tags(SettingsOpenStage)) |stage| {
        const line = try SettingsOpenTrace.formatRecord(&buf, std.math.maxInt(u64), stage);
        try std.testing.expect(line.len < SettingsOpenTrace.max_record_bytes);
    }
}

test "Settings open trace refuses relative paths and preserves an existing file" {
    try std.testing.expectError(error.RelativeTracePath, SettingsOpenTrace.initPath("relative-settings-trace.jsonl"));
    if (builtin.os.tag == .windows) {
        for ([_][]const u8{ "\\\\server\\share\\trace", "//server/share/trace", "\\/server/share/trace", "/\\server/share/trace", "\\\\.\\pipe\\trace", "\\??\\UNC\\server\\share\\trace" }) |path|
            try std.testing.expectError(error.NetworkOrDeviceTracePath, SettingsOpenTrace.initPath(path));
        try std.testing.expectError(error.RelativeTracePath, SettingsOpenTrace.initPath("C:relative-settings-trace.jsonl"));
        try std.testing.expectError(error.RelativeTracePath, SettingsOpenTrace.initPath("\\root-relative-settings-trace.jsonl"));
        try std.testing.expectError(error.RelativeTracePath, SettingsOpenTrace.initPath("/root-relative-settings-trace.jsonl"));
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "trace.jsonl" });
    defer alloc.free(path);
    try tmp.dir.writeFile(.{ .sub_path = "trace.jsonl", .data = "preserve-me" });
    try std.testing.expectError(error.PathAlreadyExists, SettingsOpenTrace.initPath(path));
    const data = try tmp.dir.readFileAlloc(alloc, "trace.jsonl", 100);
    defer alloc.free(data);
    try std.testing.expectEqualStrings("preserve-me", data);
}

test "Settings open trace caps output and closes its owned handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "trace.jsonl" });
    defer alloc.free(path);
    var trace = try SettingsOpenTrace.initPath(path);
    defer trace.deinit();
    for (0..SettingsOpenTrace.max_records + 10) |_| trace.note(.open_config_action);
    try std.testing.expectEqual(@as(u16, SettingsOpenTrace.max_records), trace.records);
    try std.testing.expect(!trace.enabled());
    const data = try tmp.dir.readFileAlloc(alloc, "trace.jsonl", SettingsOpenTrace.max_records * SettingsOpenTrace.max_record_bytes);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, SettingsOpenTrace.max_records), std.mem.count(u8, data, "\n"));
    try std.testing.expectEqual(@as(usize, SettingsOpenTrace.max_records), std.mem.count(u8, data, "\"stage\":\"open_config_action\""));
    trace.deinit();
    trace.note(.settings_open_enter);
}

test "Settings creation stamps cost one flag check while disabled" {
    var stamps: SettingsCreationStamps = .{};
    stamps.mark(.create_begin);
    try std.testing.expectEqual(@as(usize, 0), stamps.len);
    stamps.enabled = true;
    for (0..SettingsCreationStamps.capacity + 3) |_| stamps.mark(.create_form);
    try std.testing.expectEqual(@as(usize, SettingsCreationStamps.capacity), stamps.len);
    try std.testing.expect(stamps.counters[0] <= stamps.counters[stamps.len - 1]);
}

test "Settings creation records carry the stage and both clocks" {
    var buf: [SettingsOpenTrace.max_record_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"tick_ms\":99,\"stage\":\"create_form\",\"qpc_us\":1234567}\n",
        try SettingsOpenTrace.formatCreationRecord(&buf, 99, .create_form, 1234567),
    );
    inline for (std.meta.tags(SettingsCreationStage)) |stage| {
        const line = try SettingsOpenTrace.formatCreationRecord(&buf, std.math.maxInt(u64), stage, std.math.maxInt(u64));
        try std.testing.expect(line.len < SettingsOpenTrace.max_record_bytes);
    }
    // A 10 MHz counter at 25 s, and a counter that read nothing.
    try std.testing.expectEqual(@as(u64, 25_000_000), SettingsOpenTrace.counterMicroseconds(250_000_000, 10_000_000));
    try std.testing.expectEqual(@as(u64, 0), SettingsOpenTrace.counterMicroseconds(0, 10_000_000));
}

test "Settings creation stamps are written once, in order, within the record cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "trace.jsonl" });
    defer alloc.free(path);
    var trace = try SettingsOpenTrace.initPath(path);
    defer trace.deinit();

    var stamps: SettingsCreationStamps = .{ .enabled = true };
    stamps.mark(.create_begin);
    stamps.mark(.create_end);
    trace.noteCreation(&stamps);
    try std.testing.expectEqual(@as(usize, 0), stamps.len);
    try std.testing.expectEqual(@as(u16, 2), trace.records);
    const data = try tmp.dir.readFileAlloc(alloc, "trace.jsonl", 4096);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, data, "\n"));
    const begin = std.mem.indexOf(u8, data, "\"stage\":\"create_begin\"").?;
    const end = std.mem.indexOf(u8, data, "\"stage\":\"create_end\"").?;
    try std.testing.expect(begin < end);

    // The file closes at the cap, part way through a batch.
    trace.records = SettingsOpenTrace.max_records - 1;
    stamps.mark(.create_begin);
    stamps.mark(.create_end);
    trace.noteCreation(&stamps);
    try std.testing.expect(!trace.enabled());
    try std.testing.expectEqual(@as(usize, 0), stamps.len);
    trace.noteCreation(&stamps);
}

/// Resolve a trace output path against the current working directory.
///
/// Every trace writer here opens its file with `createFileAbsolute`, which
/// asserts the path is absolute, so a relative `KORETERM_*_FILE` value has to
/// be resolved once at init rather than at each write. Takes ownership of
/// `owned` in every path, including the error paths.
pub fn absolutizeTracePath(alloc: Allocator, owned: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(owned)) return owned;
    defer alloc.free(owned);
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    return try std.fs.path.join(alloc, &.{ cwd, owned });
}

pub const BenchmarkMemoryStage = enum {
    surface_begin,
    child_hwnd_created,
    // The DC acquisition and the first `wglMakeCurrent` both happen inside
    // `App.createGLContext`, which has no surface in scope, so they are
    // observed together at its one call site rather than reported as two
    // stages the trace cannot actually separate.
    gl_context_created,
    opengl_functions_loaded,
    renderer_initialized,
    terminal_initialized,
    renderer_thread_spawned,
    io_thread_spawned,
    threads_started,
    io_reader_spawned,
    first_successful_swap,
    destroy_begin,
    core_deinit_complete,
    wgl_context_unbound,
    wgl_context_deleted,
    dc_released,
    surface_destroy_complete,
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
    published_surface_id: std.atomic.Value(u64) = .init(0),
    renderer_thread_recorded: std.atomic.Value(bool) = .init(false),
    io_thread_recorded: std.atomic.Value(bool) = .init(false),
    io_reader_recorded: std.atomic.Value(bool) = .init(false),
    io_reader_ready: std.atomic.Value(bool) = .init(false),
    first_swap_recorded: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: Allocator) MemoryStageTrace {
        const raw = std.process.getEnvVarOwned(
            alloc,
            "KORETERM_BENCH_MEMORY_STAGE_TRACE_FILE",
        ) catch return .{};
        errdefer alloc.free(raw);

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            alloc.free(raw);
            return .{};
        }
        const owned = if (trimmed.len == raw.len) raw else owned: {
            const dupe = alloc.dupe(u8, trimmed) catch {
                alloc.free(raw);
                return .{};
            };
            alloc.free(raw);
            break :owned dupe;
        };

        // `note` writes with `createFileAbsolute`, so resolve a relative
        // path once here against the process's starting cwd.
        const absolute = absolutizeTracePath(alloc, owned) catch |err| {
            log.warn("memory stage trace path could not be absolutized err={}", .{err});
            return .{};
        };
        return .{ .path = absolute };
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
    ) bool {
        const path = self.path orelse return false;
        const resolved_surface_id = self.surfaceId(surface_id);

        memory_stage_trace_write_mutex.lock();
        defer memory_stage_trace_write_mutex.unlock();
        const private_bytes = queryProcessPrivateBytes() orelse return false;
        const trace_sequence = self.trace_sequence.fetchAdd(1, .acq_rel) + 1;
        const surface_width_px = self.surface_width_px.load(.acquire);
        const surface_height_px = self.surface_height_px.load(.acquire);
        const cell_width_px = self.cell_width_px.load(.acquire);
        const cell_height_px = self.cell_height_px.load(.acquire);
        const columns = self.columns.load(.acquire);
        const rows = self.rows.load(.acquire);
        const wgl_pixel_format = self.wglPixelFormat();

        const file = std.fs.createFileAbsolute(path, .{ .truncate = false }) catch |err| {
            log.warn("memory stage trace open failed path={s} err={}", .{ path, err });
            return false;
        };
        defer file.close();
        file.seekFromEnd(0) catch return false;

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
        }, .{})}) catch return false;
        stream.flush() catch return false;
        return true;
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
    ) bool {
        if (recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return false;
        return self.note(stage, surface_token, surface_id);
    }

    pub fn noteRendererThreadSpawned(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        _ = self.noteOnce(&self.renderer_thread_recorded, .renderer_thread_spawned, surface_token, surface_id);
    }

    pub fn noteIoThreadSpawned(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        _ = self.noteOnce(&self.io_thread_recorded, .io_thread_spawned, surface_token, surface_id);
    }

    pub fn noteIoReaderSpawned(self: *MemoryStageTrace, surface_token: u64, surface_id: ?u64) void {
        if (self.noteOnce(&self.io_reader_recorded, .io_reader_spawned, surface_token, surface_id)) {
            // Publish readiness only after the serialized stage write returns.
            // A swap that observes this flag cannot overtake io_reader_spawned
            // at the trace writer mutex.
            self.io_reader_ready.store(true, .release);
        }
    }

    pub fn claimFirstSwapObservation(self: *MemoryStageTrace) bool {
        // The renderer can present before the IO worker publishes its reader
        // boundary. Do not label that swap as the completed startup frame;
        // the first swap after reader startup is the first one the lifecycle
        // consumer can place causally after all thread-start stages.
        if (!self.io_reader_ready.load(.acquire)) return false;
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

test "win32 memory stage trace claims first swap after a written reader stage exactly once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "memory-stage-reader.jsonl", .data = "" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "memory-stage-reader.jsonl");
    defer std.testing.allocator.free(path);

    var trace: MemoryStageTrace = .{ .path = path };

    try std.testing.expect(!trace.claimFirstSwapObservation());
    trace.noteIoReaderSpawned(11, null);
    try std.testing.expect(trace.claimFirstSwapObservation());
    try std.testing.expect(!trace.claimFirstSwapObservation());
}

test "win32 memory stage trace rejects first swap when reader stage was not written" {
    var trace: MemoryStageTrace = .{};
    trace.noteIoReaderSpawned(11, null);
    try std.testing.expect(!trace.claimFirstSwapObservation());
}

test "win32 memory stage trace claims each concurrent boundary exactly once" {
    var trace: MemoryStageTrace = .{};
    try std.testing.expect(trace.renderer_thread_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.renderer_thread_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) != null);
    try std.testing.expect(trace.io_thread_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
    try std.testing.expect(trace.io_reader_recorded.cmpxchgStrong(false, true, .acq_rel, .acquire) == null);
}

test "win32 memory stage trace preserves every surface identity record" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "memory-stage.jsonl", .data = "" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "memory-stage.jsonl");
    defer std.testing.allocator.free(path);

    var trace: MemoryStageTrace = .{ .path = path };
    try std.testing.expect(trace.note(.surface_begin, 11, null));
    trace.setGeometry(1400, 900, 10, 20, 140, 45);
    try std.testing.expect(trace.note(.terminal_initialized, 11, 22));

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
    // A worker boundary can be reached before runtime Surface.init returns
    // and flips core_initialized. The trace must still carry the ID that
    // core Surface.init assigned before starting either worker.
    trace.noteRendererThreadSpawned(11, trace.surfaceId(null));

    const contents = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "memory-stage-worker-id.jsonl",
        4096,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"stage\":\"renderer_thread_spawned\"") != null);
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
    try std.testing.expect(trace.note(.destroy_begin, 11, null));

    const contents = try tmp.dir.readFileAlloc(
        std.testing.allocator,
        "memory-stage-teardown-id.jsonl",
        4096,
    );
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"stage\":\"destroy_begin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"surface_id\":22") != null);
}
