//! MEASUREMENT ONLY (LAT-01 harness patch): keystroke-to-present event log.
//!
//! Inert unless NOCTTY_LATENCY_TRACE_FILE is set. Events are QPC-stamped and
//! kept in a fixed in-memory array; the file is written only when the
//! harness posts WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT, so recording costs one
//! atomic add and a QPC read per event.

const std = @import("std");

extern "kernel32" fn QueryPerformanceCounter(value: *i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(value: *i64) callconv(.winapi) c_int;

pub const Kind = enum(u8) {
    key_msg = 1,
    char_msg = 2,
    pty_write = 3,
    pty_output = 4,
    renderer_wake = 5,
    frame_update = 6,
    render_action = 7,
    paint_begin = 8,
    swap_begin = 9,
    swap_end = 10,
    app_wake = 11,
};

const Event = struct { qpc: u64, a: u64, b: u64, kind: u8 };

const event_capacity = 1 << 20;
const byte_capacity = 64 << 20;

var state = std.atomic.Value(u8).init(0); // 0 = unset, 1 = off, 2 = on
var path_storage: [1024]u8 = undefined;
var path_len: usize = 0;
var events: [event_capacity]Event = undefined;
var event_count = std.atomic.Value(usize).init(0);
var output_bytes: [byte_capacity]u8 = undefined;
var output_total = std.atomic.Value(u64).init(0);
var latest_frame_bytes = std.atomic.Value(u64).init(0);
var dump_mutex: std.Thread.Mutex = .{};

// Emulated display (NOCTTY_LAT_VSYNC_HZ, NOCTTY_LAT_VSYNC_MODE). A hidden
// desktop is never composed, so SwapBuffers there returns at once and a
// present costs nothing. To see what an extra present does on a real
// display, the UI thread can be made to block the way a vsynced swap chain
// blocks: `queue1` holds one frame for the next vblank and makes a second
// present inside the same refresh wait for that vblank (and display one
// refresh later); `sync` blocks every present until the next vblank.
var vsync_period: u64 = 0;
var vsync_sync = false;
var vsync_pending: u64 = 0;
var vsync_display: u64 = 0;

fn envInt(name: []const u8) ?u64 {
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return null;
    defer std.heap.page_allocator.free(raw);
    return std.fmt.parseInt(u64, std.mem.trim(u8, raw, " \t\r\n"), 10) catch null;
}

fn nextVblank(now: u64) u64 {
    return (now / vsync_period + 1) * vsync_period;
}

fn waitUntil(deadline: u64) void {
    var freq: i64 = 0;
    _ = QueryPerformanceFrequency(&freq);
    while (true) {
        const now = qpc();
        if (now >= deadline) return;
        const left_ms = (deadline - now) * 1000 / @as(u64, @intCast(freq));
        if (left_ms >= 2) std.Thread.sleep((left_ms - 1) * std.time.ns_per_ms) else std.atomic.spinLoopHint();
    }
}

/// Called on the UI thread right before SwapBuffers.
pub fn beforeSwap() void {
    if (!enabled() or vsync_period == 0) return;
    const now = qpc();
    const next = nextVblank(now);
    if (vsync_sync) {
        waitUntil(next);
        vsync_display = next;
    } else if (vsync_pending >= next) {
        // A frame is already queued for the coming vblank: the swap chain is
        // full, so this present waits for that flip and shows one later.
        waitUntil(vsync_pending);
        vsync_display = vsync_pending + vsync_period;
    } else {
        vsync_display = next;
    }
    vsync_pending = vsync_display;
}

pub fn init() void {
    if (state.load(.acquire) != 0) return;
    if (envInt("NOCTTY_LAT_VSYNC_HZ")) |hz| if (hz > 0) {
        var freq: i64 = 0;
        _ = QueryPerformanceFrequency(&freq);
        vsync_period = @as(u64, @intCast(freq)) / hz;
        vsync_sync = (envInt("NOCTTY_LAT_VSYNC_SYNC") orelse 0) != 0;
    };
    const raw = std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_LATENCY_TRACE_FILE") catch {
        state.store(1, .release);
        return;
    };
    defer std.heap.page_allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > path_storage.len) {
        state.store(1, .release);
        return;
    }
    @memcpy(path_storage[0..trimmed.len], trimmed);
    path_len = trimmed.len;
    state.store(2, .release);
}

pub inline fn enabled() bool {
    return state.load(.acquire) == 2;
}

fn qpc() u64 {
    var value: i64 = 0;
    _ = QueryPerformanceCounter(&value);
    return @intCast(@max(value, 0));
}

pub fn note(kind: Kind, a: u64, b: u64) void {
    if (!enabled()) return;
    const now = qpc();
    const index = event_count.fetchAdd(1, .acq_rel);
    if (index >= event_capacity) return;
    events[index] = .{ .qpc = now, .a = a, .b = b, .kind = @intFromEnum(kind) };
}

/// Called with the renderer state mutex held, after the chunk was counted.
pub fn noteOutput(end_offset: u64, buf: []const u8) void {
    if (!enabled()) return;
    note(.pty_output, end_offset, buf.len);
    const start = end_offset -| buf.len;
    if (start >= byte_capacity) return;
    const room: usize = @intCast(byte_capacity - start);
    const len = @min(room, buf.len);
    @memcpy(output_bytes[@intCast(start)..][0..len], buf[0..len]);
    output_total.store(end_offset, .release);
}

pub fn noteFrameUpdate(bytes: u64, generation: u64) void {
    if (!enabled()) return;
    latest_frame_bytes.store(bytes, .release);
    note(.frame_update, bytes, generation);
}

/// `b` is the emulated display time (QPC), or 0 without emulation.
pub fn noteSwapEnd() void {
    if (!enabled()) return;
    note(.swap_end, latest_frame_bytes.load(.acquire), if (vsync_period != 0) vsync_display else 0);
}

pub fn dump() void {
    if (!enabled()) return;
    dump_mutex.lock();
    defer dump_mutex.unlock();
    const file = std.fs.createFileAbsolute(path_storage[0..path_len], .{ .truncate = true }) catch return;
    defer file.close();
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(&buffer);
    const out = &writer.interface;
    var freq: i64 = 0;
    _ = QueryPerformanceFrequency(&freq);
    const count = @min(event_count.load(.acquire), event_capacity);
    out.print("F {d}\n", .{freq}) catch return;
    for (events[0..count]) |e| {
        out.print("E {d} {d} {d} {d}\n", .{ e.qpc, e.kind, e.a, e.b }) catch return;
    }
    const total: usize = @intCast(@min(output_total.load(.acquire), byte_capacity));
    var i: usize = 0;
    while (i < total) : (i += 4096) {
        const end = @min(total, i + 4096);
        out.print("B {d} {x}\n", .{ i, output_bytes[i..end] }) catch return;
    }
    out.flush() catch return;
}
