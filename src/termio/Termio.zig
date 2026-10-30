//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const terminal_render_dirty = @import("../terminal/render_dirty.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const BenchmarkEndMarker = @import("bench_marker.zig").BenchmarkEndMarker;

const log = std.log.scoped(.io_exec);

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn processOutputTickMs() u64 {
    if (comptime builtin.os.tag == .windows) return GetTickCount64();
    return 0;
}

var output_trace_file_claimed = std.atomic.Value(bool).init(false);

const OutputTrace = struct {
    path: ?[]const u8 = null,
    start_time: ?std.time.Instant = null,
    process_output_count: u64 = 0,
    process_output_bytes: u64 = 0,
    renderer_wake_count: u64 = 0,
    queued_renderer_message_count: u64 = 0,
    synchronized_output_active_count: u64 = 0,
    ended_synchronized_output_count: u64 = 0,
    completed_synchronized_output_batch_count: u64 = 0,
    has_render_work_count: u64 = 0,
    max_process_output_gap_ms: u64 = 0,
    max_process_output_gap_ended_at_ms: u64 = 0,
    last_process_output_tick_ms: ?u64 = null,
    first_process_output_at_ms: ?u64 = null,
    windows_pty_read_buffer_bytes: u64 = 0,
    windows_pty_read_count: u64 = 0,
    windows_pty_read_bytes: u64 = 0,
    windows_pty_read_le_4k_count: u64 = 0,
    windows_pty_read_le_16k_count: u64 = 0,
    windows_pty_read_le_64k_count: u64 = 0,
    windows_pty_read_gt_64k_count: u64 = 0,
    windows_read_file_total_ns: u64 = 0,
    windows_read_file_max_ns: u64 = 0,
    windows_process_output_total_ns: u64 = 0,
    windows_process_output_max_ns: u64 = 0,
    renderer_mutex_wait_total_ns: u64 = 0,
    renderer_mutex_wait_max_ns: u64 = 0,
    renderer_mutex_hold_total_ns: u64 = 0,
    renderer_mutex_hold_max_ns: u64 = 0,

    fn init(alloc: Allocator) OutputTrace {
        const owned = (internal_os.getEnvVarOwnedTrimmedNotEmpty(
            alloc,
            "NOCTTY_TERMIO_TRACE_FILE",
        ) catch return .{}) orelse return .{};

        return initWithClaimedPath(alloc, &output_trace_file_claimed, owned);
    }

    fn initWithClaimedPath(
        alloc: Allocator,
        claimed: *std.atomic.Value(bool),
        owned: []const u8,
    ) OutputTrace {
        // The configured path is a single JSON document. The interactive
        // harness waits for the initial terminal before seeding tabs, so the
        // first claimant is deterministic. Retaining the process-lifetime
        // claim prevents later tab teardown from replacing its evidence.
        const trace_path = claimTracePath(alloc, claimed, owned) orelse
            return .{};
        return .{
            .path = trace_path,
            .start_time = std.time.Instant.now() catch null,
        };
    }

    fn deinit(self: *OutputTrace, alloc: Allocator) void {
        defer {
            if (self.path) |path| alloc.free(path);
            self.* = .{};
        }

        if (self.path == null) return;
        self.writeSnapshot();
    }

    fn enabled(self: *const OutputTrace) bool {
        return self.path != null;
    }

    fn elapsedMs(self: *const OutputTrace) u64 {
        const start_time = self.start_time orelse return 0;
        const now = std.time.Instant.now() catch return 0;
        return @intCast(@divFloor(now.since(start_time), std.time.ns_per_ms));
    }

    fn noteProcessOutput(
        self: *OutputTrace,
        buf_len: usize,
        should_render: bool,
        queued_renderer_message: bool,
        synchronized_output_active: bool,
        ended_synchronized_output: bool,
        completed_synchronized_output_batch: bool,
        has_render_work: bool,
    ) void {
        if (!self.enabled()) return;

        self.process_output_count += 1;
        self.process_output_bytes += buf_len;
        if (should_render) self.renderer_wake_count += 1;
        if (queued_renderer_message) self.queued_renderer_message_count += 1;
        if (synchronized_output_active) self.synchronized_output_active_count += 1;
        if (ended_synchronized_output) self.ended_synchronized_output_count += 1;
        if (completed_synchronized_output_batch) self.completed_synchronized_output_batch_count += 1;
        if (has_render_work) self.has_render_work_count += 1;

        const elapsed_ms = self.elapsedMs();
        if (self.first_process_output_at_ms == null) self.first_process_output_at_ms = elapsed_ms;
        if (self.last_process_output_tick_ms) |last_tick_ms| if (elapsed_ms > last_tick_ms) {
            const gap_ms = elapsed_ms - last_tick_ms;
            if (gap_ms > self.max_process_output_gap_ms) {
                self.max_process_output_gap_ms = gap_ms;
                self.max_process_output_gap_ended_at_ms = elapsed_ms;
            }
        };
        self.last_process_output_tick_ms = elapsed_ms;
    }

    fn noteWindowsPtyRead(
        self: *OutputTrace,
        byte_count: usize,
        buffer_size: usize,
        read_file_ns: u64,
    ) void {
        if (!self.enabled()) return;

        self.windows_pty_read_buffer_bytes = @intCast(buffer_size);
        self.windows_pty_read_count +|= 1;
        self.windows_pty_read_bytes +|= @intCast(byte_count);
        if (byte_count <= 4 * 1024) {
            self.windows_pty_read_le_4k_count +|= 1;
        } else if (byte_count <= 16 * 1024) {
            self.windows_pty_read_le_16k_count +|= 1;
        } else if (byte_count <= 64 * 1024) {
            self.windows_pty_read_le_64k_count +|= 1;
        } else {
            self.windows_pty_read_gt_64k_count +|= 1;
        }
        self.windows_read_file_total_ns +|= read_file_ns;
        self.windows_read_file_max_ns = @max(self.windows_read_file_max_ns, read_file_ns);
    }

    fn noteWindowsProcessOutput(self: *OutputTrace, duration_ns: u64) void {
        if (!self.enabled()) return;
        self.windows_process_output_total_ns +|= duration_ns;
        self.windows_process_output_max_ns = @max(self.windows_process_output_max_ns, duration_ns);
    }

    fn noteProcessOutputLock(self: *OutputTrace, wait_ns: u64, hold_ns: u64) void {
        if (!self.enabled()) return;
        self.renderer_mutex_wait_total_ns +|= wait_ns;
        self.renderer_mutex_wait_max_ns = @max(self.renderer_mutex_wait_max_ns, wait_ns);
        self.renderer_mutex_hold_total_ns +|= hold_ns;
        self.renderer_mutex_hold_max_ns = @max(self.renderer_mutex_hold_max_ns, hold_ns);
    }

    fn writeSnapshot(self: *const OutputTrace) void {
        const trace_path = self.path orelse return;
        const file = std.fs.createFileAbsolute(trace_path, .{ .truncate = true }) catch |err| {
            log.warn("termio output trace create failed path={s} err={}", .{ trace_path, err });
            return;
        };
        defer file.close();

        var buffer: [1024]u8 = undefined;
        var writer = file.writer(&buffer);
        const stream = &writer.interface;
        stream.print("{f}", .{std.json.fmt(.{
            .runtime_ms = self.elapsedMs(),
            .process_output_count = self.process_output_count,
            .process_output_bytes = self.process_output_bytes,
            .renderer_wake_count = self.renderer_wake_count,
            .queued_renderer_message_count = self.queued_renderer_message_count,
            .synchronized_output_active_count = self.synchronized_output_active_count,
            .ended_synchronized_output_count = self.ended_synchronized_output_count,
            .completed_synchronized_output_batch_count = self.completed_synchronized_output_batch_count,
            .has_render_work_count = self.has_render_work_count,
            .max_process_output_gap_ms = self.max_process_output_gap_ms,
            .max_process_output_gap_ended_at_ms = self.max_process_output_gap_ended_at_ms,
            .first_process_output_at_ms = self.first_process_output_at_ms orelse 0,
            .windows_pty_read_buffer_bytes = self.windows_pty_read_buffer_bytes,
            .windows_pty_read_count = self.windows_pty_read_count,
            .windows_pty_read_bytes = self.windows_pty_read_bytes,
            .windows_pty_read_le_4k_count = self.windows_pty_read_le_4k_count,
            .windows_pty_read_le_16k_count = self.windows_pty_read_le_16k_count,
            .windows_pty_read_le_64k_count = self.windows_pty_read_le_64k_count,
            .windows_pty_read_gt_64k_count = self.windows_pty_read_gt_64k_count,
            .windows_read_file_total_ns = self.windows_read_file_total_ns,
            .windows_read_file_max_ns = self.windows_read_file_max_ns,
            .windows_process_output_total_ns = self.windows_process_output_total_ns,
            .windows_process_output_max_ns = self.windows_process_output_max_ns,
            .renderer_mutex_wait_total_ns = self.renderer_mutex_wait_total_ns,
            .renderer_mutex_wait_max_ns = self.renderer_mutex_wait_max_ns,
            .renderer_mutex_hold_total_ns = self.renderer_mutex_hold_total_ns,
            .renderer_mutex_hold_max_ns = self.renderer_mutex_hold_max_ns,
        }, .{})}) catch |err| {
            log.warn("termio output trace write failed path={s} err={}", .{ trace_path, err });
            return;
        };
        stream.flush() catch |err| {
            log.warn("termio output trace flush failed path={s} err={}", .{ trace_path, err });
            return;
        };
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
    log.debug("termio trace path already has a process owner; tracing disabled for this terminal", .{});
    alloc.free(owned);
    return null;
}

test "termio output trace init rejects and frees a second process owner" {
    var claimed = std.atomic.Value(bool).init(false);
    const first = try std.testing.allocator.dupe(u8, "first.json");
    const first_trace = OutputTrace.initWithClaimedPath(std.testing.allocator, &claimed, first);
    defer if (first_trace.path) |path| std.testing.allocator.free(path);
    try std.testing.expect(first_trace.path != null);

    const second = try std.testing.allocator.dupe(u8, "second.json");
    const second_trace = OutputTrace.initWithClaimedPath(std.testing.allocator, &claimed, second);
    defer if (second_trace.path) |path| std.testing.allocator.free(path);
    try std.testing.expect(second_trace.path == null);
}

test "termio output trace aggregates Windows PTY hot-path timings in memory" {
    var trace: OutputTrace = .{ .path = "unused.json" };
    trace.noteWindowsPtyRead(4096, 16 * 1024, 11);
    trace.noteWindowsPtyRead(8192, 16 * 1024, 13);
    trace.noteWindowsProcessOutput(17);
    trace.noteWindowsProcessOutput(19);
    trace.noteProcessOutputLock(23, 29);
    trace.noteProcessOutputLock(31, 37);

    try std.testing.expectEqual(@as(u64, 2), trace.windows_pty_read_count);
    try std.testing.expectEqual(@as(u64, 12 * 1024), trace.windows_pty_read_bytes);
    try std.testing.expectEqual(@as(u64, 1), trace.windows_pty_read_le_4k_count);
    try std.testing.expectEqual(@as(u64, 1), trace.windows_pty_read_le_16k_count);
    try std.testing.expectEqual(@as(u64, 24), trace.windows_read_file_total_ns);
    try std.testing.expectEqual(@as(u64, 13), trace.windows_read_file_max_ns);
    try std.testing.expectEqual(@as(u64, 36), trace.windows_process_output_total_ns);
    try std.testing.expectEqual(@as(u64, 19), trace.windows_process_output_max_ns);
    try std.testing.expectEqual(@as(u64, 54), trace.renderer_mutex_wait_total_ns);
    try std.testing.expectEqual(@as(u64, 31), trace.renderer_mutex_wait_max_ns);
    try std.testing.expectEqual(@as(u64, 66), trace.renderer_mutex_hold_total_ns);
    try std.testing.expectEqual(@as(u64, 37), trace.renderer_mutex_hold_max_ns);
}

/// Whether any handle to `path` is still open, measured by asking for the
/// file with no sharing at all: that fails while another handle exists.
fn fileHeldOpen(alloc: Allocator, path: []const u8) !bool {
    const k32 = windows.kernel32;
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const h = k32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ,
        0,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (h == windows.INVALID_HANDLE_VALUE) {
        return k32.GetLastError() == .SHARING_VIOLATION;
    }
    _ = windows.CloseHandle(h);
    return false;
}

test "termio input files are closed after prepareInput fails part way" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "first.txt", .data = "one" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const first = try std.fs.path.join(alloc, &.{ dir, "first.txt" });
    defer alloc.free(first);
    const missing = try std.fs.path.join(alloc, &.{ dir, "missing.txt" });
    defer alloc.free(missing);

    var state: ThreadEnterState = .{
        .arena = ArenaAllocator.init(alloc),
        .input = .{},
    };
    defer state.destroy();
    const arena_alloc = state.arena.allocator();
    try state.input.list.append(arena_alloc, .{ .path = try arena_alloc.dupeZ(u8, first) });
    try state.input.list.append(arena_alloc, .{ .path = try arena_alloc.dupeZ(u8, missing) });

    // Positive control: the probe sees a handle that is open.
    {
        const held = try std.fs.openFileAbsolute(first, .{});
        defer held.close();
        try testing.expect(try fileHeldOpen(alloc, first));
    }

    try testing.expectError(error.InputNotFound, state.prepareInput());
    try testing.expect(!try fileHeldOpen(alloc, first));
}

test "termio input files are closed and read buffers freed once queued" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "in.txt", .data = "echo hi\r" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "in.txt" });
    defer alloc.free(path);

    var state: ThreadEnterState = .{
        .arena = ArenaAllocator.init(alloc),
        .input = .{},
    };
    defer state.destroy();
    const arena_alloc = state.arena.allocator();
    try state.input.list.append(arena_alloc, .{ .path = try arena_alloc.dupeZ(u8, path) });
    const inputs = try state.prepareInput();
    try testing.expect(try fileHeldOpen(alloc, path));

    // An exited process drops writes, which is all the queueing needs to
    // run: the testing allocator then fails the test if the buffer the
    // file was read into is not freed.
    var td: ThreadData = .{
        .alloc = alloc,
        .loop = undefined,
        .renderer_state = undefined,
        .surface_mailbox = undefined,
        .backend = .{ .exec = .{
            .start = undefined,
            .exited = true,
            .write_stream = undefined,
            .process = null,
            .read_thread = undefined,
            .read_thread_pipe = undefined,
            .read_thread_fd = undefined,
            .stopping = undefined,
            .termios_timer = undefined,
            .write_pool = .init(alloc),
        } },
        .mailbox = undefined,
    };
    defer td.backend.exec.write_pool.deinit();
    var io: Termio = undefined;
    io.alloc = alloc;
    io.backend = .{ .exec = undefined };
    try io.queueInputs(&td, inputs);

    ThreadEnterState.closeInputs(inputs);
    try testing.expect(!try fileHeldOpen(alloc, path));
}

test {
    // The benchmark end-marker matcher lives in its own module so the
    // benchmark boundary is visible in the file list, not buried in
    // Termio. Pull its tests in explicitly.
    _ = @import("bench_marker.zig");
}

/// Mutex state argument for queueMessage.
pub const MutexState = enum { locked, unlocked };

/// Allocator
alloc: Allocator,

/// This is the implementation responsible for io.
backend: termio.Backend,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminalpkg.Terminal,

/// Successful local clears of the pty since startup. Undo snapshots from
/// before a clear must keep the live cursor. Protected by renderer_state.mutex.
pty_clear_generation: u64 = 0,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: *xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// Nonblocking semantic terminal-output transport owned by the Surface.
terminal_output_transport: *apprt.surface.TerminalOutputTransport,

/// The cached size info
size: renderer.Size,

/// The mailbox implementation to use.
mailbox: termio.Mailbox,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: StreamHandler.Stream,

/// Set when the IO thread is being stopped: by `Surface.deinit` before it
/// joins the IO thread, and by the backend's `threadExit`, which also covers
/// an IO thread that ends on its own. The pty reader then exits before its
/// next read, and neither it nor the IO thread waits any longer for room in
/// the termio or surface mailbox; what would wait is dropped. The threads
/// that drain those mailboxes, the IO thread and the app thread, are the
/// ones waiting for them to exit.
stopping: std.atomic.Value(bool) = .init(false),

/// Last time the cursor was reset. This is used to prevent message
/// flooding with cursor resets.
last_cursor_reset: ?std.time.Instant = null,

/// Optional PTY/output trace for debugging render wake cadence.
output_trace: OutputTrace = .{},

/// Optional benchmark-only marker used to acknowledge transformed ConPTY
/// output by terminal generation instead of original input bytes.
benchmark_end_marker: BenchmarkEndMarker = .{},

/// State we have for thread enter. This may be null if we don't need
/// to keep track of any state or if its already been freed.
thread_enter_state: ?*ThreadEnterState = null,

/// The state we need to keep around only until we enter the IO
/// thread. Then we can throw it all away.
const ThreadEnterState = struct {
    arena: ArenaAllocator,

    /// Initial input to send to the subprocess after starting. This
    /// memory is freed once the subprocess start is attempted, even
    /// if it fails, because Exec only starts once.
    input: configpkg.io.RepeatableReadableIO,

    pub fn create(
        alloc: Allocator,
        config: *const configpkg.Config,
    ) !?*ThreadEnterState {
        // If we have no input then we have no thread enter state
        if (config.input.list.items.len == 0) return null;

        // Create our arena allocator
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Allocate our ThreadEnterState
        const ptr = try arena_alloc.create(ThreadEnterState);

        // Copy the input from the config
        const input = try config.input.cloneParsed(arena_alloc);

        // Return the initialized state
        ptr.* = .{
            .arena = arena,
            .input = input,
        };
        return ptr;
    }

    pub fn destroy(self: *ThreadEnterState) void {
        self.arena.deinit();
    }

    /// Prepare the inputs for use. Allocations happen on the arena.
    pub fn prepareInput(
        self: *ThreadEnterState,
    ) (Allocator.Error || error{InputNotFound})![]const Input {
        const alloc = self.arena.allocator();

        var input = try alloc.alloc(
            Input,
            self.input.list.items.len,
        );
        // The arena frees memory but never closes a handle, so a failure
        // part way through must close the files already opened.
        var opened: usize = 0;
        errdefer closeInputs(input[0..opened]);
        for (self.input.list.items, 0..) |item, i| {
            input[i] = switch (item) {
                .raw => |v| .{ .string = try alloc.dupe(u8, v) },
                .path => |path| file: {
                    const f = std.fs.cwd().openFile(
                        path,
                        .{},
                    ) catch |err| {
                        log.warn("failed to open input file={s} err={}", .{
                            path,
                            err,
                        });
                        return error.InputNotFound;
                    };

                    break :file .{ .file = f };
                },
            };
            opened = i + 1;
        }

        return input;
    }

    /// Close the files `prepareInput` opened.
    fn closeInputs(inputs: []const Input) void {
        for (inputs) |input| switch (input) {
            .string => {},
            .file => |f| f.close(),
        };
    }

    const Input = union(enum) {
        string: []const u8,
        file: std.fs.File,
    };
};

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    enquiry_response: []const u8,
    conditional_state: configpkg.ConditionalState,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
        conditional_state: configpkg.ConditionalState,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    // If the user didn't set any values manually, then
                    // we're using the default palette and we don't need
                    // to apply the generation code to it.
                    break :generate;
                }

                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }

            break :palette config.palette.value;
        };

        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            // Config.changeConditionalState intentionally skips replay when no
            // config field uses the changed condition. The terminal still
            // needs the live state for color-scheme reports in that case.
            .conditional_state = conditional_state,

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    // The default terminal modes based on our config.
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};

        // Setup our initial grapheme cluster support if enabled. We use a
        // switch to ensure we get a compiler error if more cases are added.
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }

        // Set default cursor blink settings
        modes.cursor_blinking = opts.config.cursor_blink orelse true;

        break :modes modes;
    };

    // Create our terminal
    var term = try terminalpkg.Terminal.init(alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback = opts.full_config.@"scrollback-limit",
            .default_modes = default_modes,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .init(opts.config.palette),
            },
        };
    });
    errdefer term.deinit(alloc);

    // Set the image size limits
    var it = term.screens.all.iterator();
    while (it.next()) |entry| {
        const screen: *terminalpkg.Screen = entry.value.*;
        try screen.kitty_images.setLimit(
            alloc,
            screen,
            opts.config.image_storage_limit,
        );
    }

    // Set our default cursor style
    term.screens.active.cursor.cursor_style = opts.config.cursor_style;

    // Setup our terminal size in pixels for certain requests.
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;

    // Setup our backend.
    var backend = opts.backend;
    try backend.initTerminal(&term);

    // Create our stream handler. This points to memory in self so it
    // isn't safe to use until self.* is set.
    const handler: StreamHandler = .{
        .alloc = alloc,
        .termio_mailbox = &self.mailbox,
        .stopping = &self.stopping,
        .surface_mailbox = opts.surface_mailbox,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .size = &self.size,
        .terminal = &self.terminal,
        .osc_color_report_format = opts.config.osc_color_report_format,
        .clipboard_write = opts.config.clipboard_write,
        .enquiry_response = opts.config.enquiry_response,
        .default_cursor_style = opts.config.cursor_style,
        .default_cursor_blink = opts.config.cursor_blink,
    };

    const thread_enter_state = try ThreadEnterState.create(
        alloc,
        opts.full_config,
    );

    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .terminal_output_transport = opts.terminal_output_transport,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = .initAlloc(alloc, handler),
        .output_trace = OutputTrace.init(alloc),
        .benchmark_end_marker = BenchmarkEndMarker.init(alloc),
        .thread_enter_state = thread_enter_state,
    };
}

pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);

    // Clear any StreamHandler state
    self.terminal_stream.deinit();
    self.output_trace.deinit(self.alloc);
    self.benchmark_end_marker.deinit(self.alloc);

    // Clear any initial state if we have it
    if (self.thread_enter_state) |v| v.destroy();
}

pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    // Always free our thread enter state when we're done.
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };

    // If we have thread enter state then we're going to validate
    // and set that all up now so that we can error before we actually
    // start the command and pty.
    const inputs: ?[]const ThreadEnterState.Input = if (self.thread_enter_state) |v|
        try v.prepareInput()
    else
        null;
    defer if (inputs) |v| ThreadEnterState.closeInputs(v);

    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined, // Backend must replace this on threadEnter
    };

    // Setup our backend
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer self.backend.threadExit(data);

    // If we have inputs, then queue them all up.
    try self.queueInputs(data, inputs orelse &.{});
}

/// Queue the prepared inputs for the subprocess. The backend copies what
/// it is given, so the buffer an input file is read into is ours to free.
fn queueInputs(
    self: *Termio,
    data: *ThreadData,
    inputs: []const ThreadEnterState.Input,
) !void {
    for (inputs) |input| switch (input) {
        .string => |v| self.queueWrite(data, v, false) catch |err| {
            log.warn("failed to queue input string err={}", .{err});
            return error.InputFailed;
        },
        .file => |f| {
            const bytes = f.readToEndAlloc(
                self.alloc,
                10 * 1024 * 1024, // 10 MiB max
            ) catch |err| {
                log.warn("failed to read input file err={}", .{err});
                return error.InputFailed;
            };
            defer self.alloc.free(bytes);
            self.queueWrite(data, bytes, false) catch |err| {
                log.warn("failed to queue input file err={}", .{err});
                return error.InputFailed;
            };
        },
    };
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}

/// Send a message to the mailbox. Depending on the mailbox type in use
/// this may process now or it may just enqueue and process later.
///
/// This will also notify the mailbox thread to process the message. If
/// you're sending a lot of messages, it may be more efficient to use
/// the mailbox directly and then call notify separately.
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    }, null);
    self.mailbox.notify();
}

/// Queue a write directly to the pty.
///
/// If you're using termio.Thread, this must ONLY be called from the
/// mailbox thread. If you're not on the thread, use queueMessage with
/// mailbox messages instead.
///
/// If you're not using termio.Thread, this is not threadsafe.
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    //
    // This must happen before the mode 2031 report below, which reads the
    // scheme from `self.config`: installing after it would answer with the
    // outgoing scheme.
    installDerivedConfig(&self.config, config);

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    self.terminal_stream.handler.changeConfig(&self.config);
    td.backend.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette.
    self.terminal.colors.palette.changeDefault(config.palette);
    self.terminal.flags.dirty.palette = true;

    // Update all our other colors
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // The config could have changed any of our colors so update mode 2031.
    // This is written directly rather than queued as a color_scheme_report
    // message because we're on the io thread, the only reader of our
    // mailbox: if the mailbox were full, queueing would wait forever.
    // (Fork: upstream writes it last; here it comes before the image limits,
    // whose `try` would otherwise skip it. Pinned by "issue149 config change
    // writes exactly one color scheme report".)
    self.colorSchemeReportLocked(td, false) catch |err| {
        log.warn("error sending color scheme report err={}", .{err});
    };

    // Set the image size limits
    var it = self.terminal.screens.all.iterator();
    while (it.next()) |entry| {
        const screen: *terminalpkg.Screen = entry.value.*;
        try screen.kitty_images.setLimit(
            self.alloc,
            screen,
            config.image_storage_limit,
        );
    }
}

/// Replace the live derived config. Split out so the ordering contract with
/// the mode 2031 report is testable: whatever is installed here is what
/// `colorSchemeReportLocked` will report.
fn installDerivedConfig(current: *DerivedConfig, replacement: *DerivedConfig) void {
    current.deinit();
    current.* = replacement.*;
}

/// Resize the terminal.
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    const grid_size = size.grid();

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Resizing the pty can make the shell, or the pseudo console's host,
        // redraw at once. Hold the same lock used by processOutput before
        // notifying it, so that redraw cannot be parsed against the old
        // terminal dimensions.
        //
        // A pty that refuses (a pseudo console whose host is gone, a handoff
        // session whose signal pipe closed) must not keep the grid and the
        // renderer at the old size: the surface has the new size either way.
        // A mode 2048 report below then says the new size while the pty may
        // keep the old one until a later resize succeeds.
        self.backend.resize(grid_size, size.terminal()) catch |err| {
            log.warn("pty resize failed, resizing the terminal anyway err={}", .{err});
        };

        // The stream handler reads this under the same lock (DECCOLM's
        // mode 3 reset, size reports).
        self.size = size;

        // Update the size of our terminal state
        try self.terminal.resize(
            self.alloc,
            grid_size.columns,
            grid_size.rows,
        );

        // Update our pixel sizes
        self.terminal.width_px = grid_size.columns * self.size.cell.width;
        self.terminal.height_px = grid_size.rows * self.size.cell.height;

        // Disable synchronized output mode so that we show changes
        // immediately for a resize. This is allowed by the spec.
        self.terminal.modes.set(.synchronized_output, false);

        // If we have size reporting enabled we need to send a report.
        if (self.terminal.modes.get(.in_band_size_reports)) {
            try self.sizeReportLocked(td, .mode_2048);
        }
    }

    // Mail the renderer so that it can update the GPU and re-render
    self.renderer_state.noteWakeSource(.mailbox);
    renderer.Thread.sendMessage(
        self.renderer_wakeup,
        self.renderer_mailbox,
        .{ .resize = size },
    );
}

/// Resize terminal/backend state before the IO thread starts.
///
/// This lets an apprt apply startup window sizing before the exec backend opens
/// its PTY. Unlike `resize`, this has no thread data yet and therefore cannot
/// emit in-band size reports.
pub fn resizeBeforeThreadStart(
    self: *Termio,
    size: renderer.Size,
) !void {
    self.size = size;
    const grid_size = size.grid();

    try self.backend.resize(grid_size, size.terminal());

    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        try self.terminal.resize(
            self.alloc,
            grid_size.columns,
            grid_size.rows,
        );

        self.terminal.width_px = grid_size.columns * self.size.cell.width;
        self.terminal.height_px = grid_size.rows * self.size.cell.height;
        self.terminal.modes.set(.synchronized_output, false);
    }

    self.renderer_state.noteWakeSource(.mailbox);
    renderer.Thread.sendMessage(
        self.renderer_wakeup,
        self.renderer_mailbox,
        .{ .resize = size },
    );
}

/// Make a size report.
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    try self.sizeReportLocked(td, style);
}

fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    const grid_size = self.size.grid();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };

    // 1024 bytes should be enough for size report since report
    // in columns and pixels.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );

    try self.queueWrite(td, writer.buffered(), false);
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    // Whether the rows above the cursor were erased; null at a prompt.
    const erased_off_prompt: ?bool = clear: {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.screens.active_key == .alternate) return;

        // Clear our selection
        self.terminal.screens.active.clearSelection();

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            const erased = self.terminal.screens.active.cursor.y > 0;
            if (erased) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }

            // Keep the screen clear consistent by dropping Kitty graphics
            // state alongside the text clear.
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );

            break :clear erased;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        self.terminal.eraseDisplay(.complete, false);
        break :clear null;
    };

    // Off a prompt nothing tells the child: ConPTY still holds the erased
    // rows and its cursor stays below them, so the next line a console
    // program draws by ConPTY's cursor lands that many rows down. ConPTY
    // makes the cursor's row its top row too.
    if (erased_off_prompt) |erased| {
        if (erased) self.ptyClear(true);
        return;
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.scrollViewport(scroll);
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
    }

    try self.renderer_wakeup.notify();
}

/// Synchronize the console's pseudo HWND with its hosting window.
/// This is independent of per-tab renderer visibility and focus events.
pub fn ptyVisibility(self: *Termio, visible: bool) !void {
    switch (self.backend) {
        .exec => |*exec| try exec.ptyVisibility(visible),
    }
}

/// The screen was cleared behind the pty's back; see `Pty.clearPseudoConsole`.
pub fn ptyClear(self: *Termio, keep_cursor_row: bool) void {
    const cleared = switch (self.backend) {
        .exec => |*exec| exec.ptyClear(keep_cursor_row),
    };
    if (cleared) {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        self.pty_clear_generation +%= 1;
    }
}

/// Called when focus is gained or lost (when focus events are enabled)
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    self.renderer_state.mutex.lock();
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock();

    // If we have focus events enabled, we send the focus event.
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }

    // We always notify our backend of focus changes.
    try self.backend.focusGained(td, focused);
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    const semantic_output_epoch = self.terminal_output_transport.captureEpoch();
    const trace_lock = self.output_trace.enabled();
    const lock_started = if (trace_lock) std.time.Instant.now() catch null else null;
    var lock_acquired: ?std.time.Instant = null;
    const decision = render: {
        // We are modifying terminal state from here on out and we need
        // the lock to grab our read data.
        self.renderer_state.mutex.lock();
        if (trace_lock) lock_acquired = std.time.Instant.now() catch null;
        defer self.renderer_state.mutex.unlock();
        // Typing at a prompt often echoes only a cursor move (Left is a BS
        // or CUB), which marks nothing dirty but must still be drawn.
        const drawn = self.renderer_state.drawn_undirtied;
        const had_render_work = terminal_render_dirty.needsFrame(&self.terminal, drawn);
        const was_synchronized_output = self.terminal.modes.get(.synchronized_output);
        self.terminal_stream.handler.semantic_output.begin(semantic_output_epoch != null);
        const processing = self.processOutputLocked(buf);
        self.renderer_state.noteProcessOutput(buf.len, processOutputTickMs());
        if (self.benchmark_end_marker.observeVisible(&self.terminal)) {
            self.renderer_state.noteBenchmarkEndMarker();
        }
        const semantic_output = self.terminal_stream.handler.semantic_output.finish();
        const has_render_work = terminal_render_dirty.needsFrame(&self.terminal, drawn);
        const synchronized_output_active = self.terminal.modes.get(.synchronized_output);
        const ended_synchronized_output =
            was_synchronized_output and !synchronized_output_active;
        const completed_synchronized_output_batch =
            processing.started_synchronized_output and
            !synchronized_output_active;
        const should_render = shouldWakeRendererAfterOutput(
            had_render_work,
            has_render_work,
            processing.queued_renderer_message,
            synchronized_output_active,
            ended_synchronized_output,
            completed_synchronized_output_batch,
        );
        // Record the wake before the lock lets the renderer see this state:
        // its follow-up leaves dirt to a recorded wake, and would otherwise
        // draw it here and then again for the wake (`renderFollowupDecision`).
        if (should_render) self.renderer_state.noteWakeSource(.io_output);
        break :render .{
            .should_render = should_render,
            .queued_renderer_message = processing.queued_renderer_message,
            .synchronized_output_active = synchronized_output_active,
            .ended_synchronized_output = ended_synchronized_output,
            .completed_synchronized_output_batch = completed_synchronized_output_batch,
            .has_render_work = has_render_work,
            .semantic_output = semantic_output,
            .semantic_output_epoch = semantic_output_epoch,
        };
    };
    if (trace_lock) {
        const lock_released = std.time.Instant.now() catch null;
        const wait_ns = if (lock_started != null and lock_acquired != null)
            lock_acquired.?.since(lock_started.?)
        else
            0;
        const hold_ns = if (lock_acquired != null and lock_released != null)
            lock_released.?.since(lock_acquired.?)
        else
            0;
        self.output_trace.noteProcessOutputLock(wait_ns, hold_ns);
    }

    if (decision.semantic_output_epoch) |epoch| {
        if (decision.semantic_output.len != 0 or
            decision.semantic_output.omitted_after or
            decision.semantic_output.reset_at != null)
        {
            const semantic_bytes = decision.semantic_output.slice();
            _ = self.terminal_output_transport.pushSemanticCapture(
                epoch,
                semantic_bytes,
                decision.semantic_output.omitted_after,
                decision.semantic_output.reset_at,
            );
        }
    }

    self.output_trace.noteProcessOutput(
        buf.len,
        decision.should_render,
        decision.queued_renderer_message,
        decision.synchronized_output_active,
        decision.ended_synchronized_output,
        decision.completed_synchronized_output_batch,
        decision.has_render_work,
    );

    if (decision.should_render) {
        // Wake the renderer after parsing so it doesn't contend on the
        // terminal mutex while the PTY thread is still mutating state.
        self.terminal_stream.handler.queueRender() catch unreachable;
    }
}

pub fn outputTraceEnabled(self: *const Termio) bool {
    return self.output_trace.enabled();
}

pub fn noteWindowsPtyRead(
    self: *Termio,
    byte_count: usize,
    buffer_size: usize,
    read_file_ns: u64,
) void {
    self.output_trace.noteWindowsPtyRead(byte_count, buffer_size, read_file_ns);
}

pub fn noteWindowsProcessOutput(self: *Termio, duration_ns: u64) void {
    self.output_trace.noteWindowsProcessOutput(duration_ns);
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) struct {
    queued_renderer_message: bool,
    started_synchronized_output: bool,
} {
    var queued_renderer_message = false;
    self.terminal_stream.handler.saw_synchronized_output_start = false;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    if (buf.len > 0) {
        if (std.time.Instant.now()) |now| cursor_reset: {
            if (self.last_cursor_reset) |last| {
                if (now.since(last) <= (500 * std.time.ns_per_ms)) {
                    break :cursor_reset;
                }
            }

            self.last_cursor_reset = now;
            _ = self.renderer_mailbox.push(.{
                .reset_cursor_blink = {},
            }, .{ .instant = {} });
            queued_renderer_message = true;
        } else |err| {
            log.warn("failed to get current time err={}", .{err});
        }
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (self.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(
                self.alloc,
                &self.terminal,
                buf[i .. i + 1],
            ) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            self.terminal_stream.next(byte);
        }
    } else {
        self.terminal_stream.nextSlice(buf);
    }

    // If our stream handling caused messages to be sent to the mailbox
    // thread, then we need to wake it up so that it processes them.
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }

    return .{
        .queued_renderer_message = queued_renderer_message,
        .started_synchronized_output = self.terminal_stream.handler.saw_synchronized_output_start,
    };
}

fn shouldWakeRendererAfterOutput(
    had_render_work: bool,
    has_render_work: bool,
    queued_renderer_message: bool,
    synchronized_output_active: bool,
    ended_synchronized_output: bool,
    completed_synchronized_output_batch: bool,
) bool {
    if (queued_renderer_message) return true;
    if (ended_synchronized_output and has_render_work) return true;
    if (completed_synchronized_output_batch and has_render_work) return true;
    if (synchronized_output_active) return false;
    if (!had_render_work and has_render_work) return true;

    // For ordinary PTY output, every batch with visible dirty state needs
    // a wake so streaming animations don't stall while the terminal stays
    // continuously dirty between renderer passes.
    if (has_render_work) return true;

    return false;
}

/// Sends a DSR response for the current color scheme to the pty.
pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    try self.colorSchemeReportLocked(td, force);
}

pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    try self.queueWrite(
        td,
        colorSchemeReportBytes(self.config.conditional_state.theme),
        false,
    );
}

fn colorSchemeReportBytes(theme: configpkg.ConditionalState.Theme) []const u8 {
    return switch (theme) {
        .light => "\x1B[?997;2n",
        .dark => "\x1B[?997;1n",
    };
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,

    /// Data associated with the backend implementation (i.e. pty/exec state)
    backend: termio.backend.ThreadData,
    mailbox: *termio.Mailbox,

    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Get information about the process(es) attached to the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}

test "shared terminal dirty helper tracks visible terminal dirtiness" {
    const testing = std.testing;

    var t = try terminalpkg.Terminal.init(testing.allocator, .{
        .cols = 8,
        .rows = 4,
    });
    defer t.deinit(testing.allocator);

    try testing.expect(!terminal_render_dirty.needsRendererWake(&t));

    try t.print('x');
    try testing.expect(terminal_render_dirty.needsRendererWake(&t));

    t.screens.active.pages.clearDirty();
    try testing.expect(!terminal_render_dirty.needsRendererWake(&t));

    t.flags.dirty.palette = true;
    try testing.expect(terminal_render_dirty.needsRendererWake(&t));

    t.flags.dirty = .{};
    t.screens.active.kitty_images.dirty = true;
    try testing.expect(terminal_render_dirty.needsRendererWake(&t));
}

test "shouldWakeRendererAfterOutput wakes when synchronized output ends with pending render work" {
    const testing = std.testing;

    try testing.expect(shouldWakeRendererAfterOutput(
        true,
        true,
        false,
        false,
        true,
        false,
    ));

    try testing.expect(!shouldWakeRendererAfterOutput(
        true,
        false,
        false,
        false,
        true,
        false,
    ));

    try testing.expect(shouldWakeRendererAfterOutput(
        false,
        true,
        false,
        false,
        false,
        false,
    ));

    try testing.expect(shouldWakeRendererAfterOutput(
        true,
        true,
        false,
        false,
        false,
        true,
    ));

    try testing.expect(!shouldWakeRendererAfterOutput(
        false,
        true,
        false,
        true,
        false,
        false,
    ));
}

test "issue149 explicit config colors reach derived config and terminal colors" {
    const testing = std.testing;

    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();
    config.background = .{ .r = 0x13, .g = 0x27, .b = 0x38 };
    config.foreground = .{ .r = 0xFE, .g = 0xDC, .b = 0xBA };
    try config.palette.parseCLI("5=#123456");

    const conditional_state: configpkg.ConditionalState = .{ .theme = .dark };
    var derived = try DerivedConfig.init(testing.allocator, &config, conditional_state);
    defer derived.deinit();
    try testing.expectEqual(config.background, derived.background);
    try testing.expectEqual(config.foreground, derived.foreground);
    try testing.expectEqual(config.palette.value[5], derived.palette[5]);
    try testing.expectEqual(conditional_state, derived.conditional_state);

    var terminal = try terminalpkg.Terminal.init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .colors = .{
            .background = .init(derived.background.toTerminalRGB()),
            .foreground = .init(derived.foreground.toTerminalRGB()),
            .cursor = .unset,
            .palette = .init(derived.palette),
        },
    });
    defer terminal.deinit(testing.allocator);
    try testing.expectEqual(config.background.toTerminalRGB(), terminal.colors.background.get().?);
    try testing.expectEqual(config.foreground.toTerminalRGB(), terminal.colors.foreground.get().?);
    try testing.expectEqual(config.palette.value[5], terminal.colors.palette.current[5]);

    // The renderer consumes terminal.RenderState rather than Config directly.
    // Keep the final public handoff in this regression so a future break
    // between terminal color defaults and the retained renderer state is
    // detected before a GUI-only failure ships.
    var render_state = terminalpkg.RenderState.empty;
    defer render_state.deinit(testing.allocator);
    try render_state.update(testing.allocator, &terminal);
    try testing.expectEqual(
        terminalpkg.color.RGB{ .r = 0x13, .g = 0x27, .b = 0x38 },
        render_state.colors.background,
    );
    try testing.expectEqual(
        terminalpkg.color.RGB{ .r = 0xFE, .g = 0xDC, .b = 0xBA },
        render_state.colors.foreground,
    );
    try testing.expectEqual(
        terminalpkg.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 },
        render_state.colors.palette[5],
    );
}

test "issue149 color scheme report bytes distinguish dark and light" {
    try std.testing.expectEqualStrings("\x1B[?997;1n", colorSchemeReportBytes(.dark));
    try std.testing.expectEqualStrings("\x1B[?997;2n", colorSchemeReportBytes(.light));
}

test "issue149 OS scheme flip reports only the newly installed scheme" {
    const testing = std.testing;

    var config = try configpkg.Config.default(testing.allocator);
    defer config.deinit();

    var installed = try DerivedConfig.init(testing.allocator, &config, .{ .theme = .light });
    defer installed.deinit();
    var replacement = try DerivedConfig.init(testing.allocator, &config, .{ .theme = .dark });

    // `changeConfig` installs before it writes the mode 2031 report, which
    // reads the live config. So whatever this leaves installed is exactly
    // what gets reported: the incoming scheme, never the outgoing one.
    installDerivedConfig(&installed, &replacement);

    try testing.expectEqual(configpkg.ConditionalState.Theme.dark, installed.conditional_state.theme);
    const report = colorSchemeReportBytes(installed.conditional_state.theme);
    try testing.expectEqualStrings(colorSchemeReportBytes(.dark), report);
    try testing.expect(!std.mem.eql(u8, colorSchemeReportBytes(.light), report));
}

/// Every pty write `queueWrite` has queued so far, in order. The test loop
/// never runs, so nothing leaves the exec write queue.
fn issue149QueuedWrites(td: *ThreadData, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    var req = td.backend.exec.write_queue.head;
    while (req) |r| : (req = r.next) {
        try out.appendSlice(std.testing.allocator, r.full_write_buffer.slice);
    }
}

test "issue149 config change writes exactly one color scheme report" {
    // `Termio.changeConfig` writes the mode 2031 report itself, from the
    // config it has just installed (`StreamHandler.changeConfig` no longer
    // queues one: "issue149 config change queues no color scheme report" in
    // stream_handler.zig). So an OS light/dark flip reaches a subscriber
    // once, as the incoming scheme, and nothing reaches a program that did
    // not ask for mode 2031.
    const testing = std.testing;
    const alloc = testing.allocator;

    var config = try configpkg.Config.default(alloc);
    defer config.deinit();

    // Only what `changeConfig` reaches is set up.
    var io: Termio = undefined;
    io.alloc = alloc;
    io.backend = .{ .exec = undefined };
    io.config = try DerivedConfig.init(alloc, &config, .{ .theme = .light });
    defer io.config.deinit();
    io.terminal = try terminalpkg.Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer io.terminal.deinit(alloc);

    var renderer_mutex: std.Thread.Mutex = .{};
    var renderer_state: renderer.State = undefined;
    renderer_state.mutex = &renderer_mutex;
    renderer_state.terminal = &io.terminal;
    io.renderer_state = &renderer_state;

    var termio_mailbox = try termio.Mailbox.initSPSC(alloc);
    defer termio_mailbox.deinit(alloc);
    var rt_app: apprt.App = undefined;
    rt_app.ui_thread_id = 0;
    const AppMailbox = @TypeOf(@as(apprt.surface.Mailbox, undefined).app);
    const app_queue = try AppMailbox.Queue.create(alloc);
    defer app_queue.destroy(alloc);
    io.terminal_stream = StreamHandler.Stream.initAlloc(alloc, .{
        .alloc = alloc,
        .size = undefined,
        .terminal = &io.terminal,
        .termio_mailbox = &termio_mailbox,
        .surface_mailbox = .{
            .surface = undefined,
            .app = .{ .rt_app = &rt_app, .mailbox = app_queue },
        },
        .renderer_state = &renderer_state,
        .renderer_mailbox = undefined,
        .renderer_wakeup = undefined,
        .default_cursor_style = .block,
        .default_cursor_blink = true,
        .enquiry_response = "",
        .osc_color_report_format = .@"16-bit",
        .clipboard_write = .allow,
    });
    defer io.terminal_stream.deinit();

    // The loop never runs, so the write stream's handle is never used.
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var td: ThreadData = .{
        .alloc = alloc,
        .loop = &loop,
        .renderer_state = &renderer_state,
        .surface_mailbox = undefined,
        .backend = .{ .exec = .{
            .start = undefined,
            .write_stream = xev.Stream.initFd(undefined),
            .process = null,
            .read_thread = undefined,
            .read_thread_pipe = undefined,
            .read_thread_fd = undefined,
            .stopping = undefined,
            .termios_timer = undefined,
            .write_pool = .init(alloc),
        } },
        .mailbox = undefined,
    };
    defer td.backend.exec.write_pool.deinit();

    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(alloc);

    // Mode 2031 off: a change writes nothing.
    var dark = try DerivedConfig.init(alloc, &config, .{ .theme = .dark });
    try io.changeConfig(&td, &dark);
    try issue149QueuedWrites(&td, &written);
    try testing.expectEqualStrings("", written.items);

    // Mode 2031 on: each change writes one report, of the scheme it installs.
    io.terminal.modes.set(.report_color_scheme, true);
    var light = try DerivedConfig.init(alloc, &config, .{ .theme = .light });
    try io.changeConfig(&td, &light);
    try issue149QueuedWrites(&td, &written);
    try testing.expectEqualStrings("\x1B[?997;2n", written.items);

    var dark_again = try DerivedConfig.init(alloc, &config, .{ .theme = .dark });
    try io.changeConfig(&td, &dark_again);
    try issue149QueuedWrites(&td, &written);
    try testing.expectEqualStrings("\x1B[?997;2n\x1B[?997;1n", written.items);
}
