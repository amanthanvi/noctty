//! Standalone issue #132 feasibility spike. This is intentionally a small,
//! disposable host/client pair, not a product session protocol.

const std = @import("std");
const builtin = @import("builtin");
const Command = @import("Command.zig");
const Pty = @import("pty.zig").Pty;
const win32_job_object = @import("apprt/win32_job_object.zig");

const windows = std.os.windows;
const Allocator = std.mem.Allocator;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("conpty-host is a Windows-only feasibility spike");
    }
}

const default_ring_size = 1024 * 1024;
const max_frame_payload = 64 * 1024;
// LOCAL affects AppContainer pipe-name resolution, not desktop-process security.
const pipe_prefix = "\\\\.\\pipe\\LOCAL\\noctty-conpty-host-";
const pipe_access_duplex = 0x00000003;
const file_flag_first_pipe_instance = 0x00080000;
const pipe_reject_remote_clients = 0x00000008;
const token_query = 0x0008;
const token_user_class = 1;
const sddl_revision_1 = 1;
const error_io_pending = 997;
const error_file_not_found = 2;
const error_pipe_busy = 231;
const still_active = 259;
const security_sqos_present = 0x00100000;
const security_identification = 0x00010000;
const process_query_limited_information = 0x1000;

const Tag = enum(u8) {
    attach = 1,
    detach = 2,
    resize = 3,
    input = 4,
    output = 5,
};

const Resize = struct {
    columns: u16,
    rows: u16,
};

const TokenUser = extern struct {
    user: extern struct {
        sid: *anyopaque,
        attributes: windows.DWORD,
    },
};

extern "kernel32" fn ConnectNamedPipe(
    pipe: windows.HANDLE,
    overlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn DisconnectNamedPipe(pipe: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn PeekNamedPipe(
    pipe: windows.HANDLE,
    buffer: ?*anyopaque,
    buffer_size: windows.DWORD,
    bytes_read: ?*windows.DWORD,
    total_available: ?*windows.DWORD,
    bytes_left: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout_ms: windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn OpenProcessToken(
    process: windows.HANDLE,
    access: windows.DWORD,
    token: *?windows.HANDLE,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn GetTokenInformation(
    token: windows.HANDLE,
    information_class: windows.DWORD,
    information: ?*anyopaque,
    information_len: windows.DWORD,
    return_len: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn ConvertSidToStringSidW(
    sid: *anyopaque,
    string_sid: *?[*:0]u16,
) callconv(.winapi) windows.BOOL;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    sddl: [*:0]const u16,
    revision: windows.DWORD,
    descriptor: *?*anyopaque,
    descriptor_size: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetNamedPipeServerProcessId(
    pipe: windows.HANDLE,
    process_id: *windows.DWORD,
) callconv(.winapi) windows.BOOL;
extern "kernel32" fn OpenProcess(
    access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

// Token user SID of `process` in canonical string form. Callers compare these
// strings to decide whether two handles belong to the same user.
fn tokenUserSidAlloc(alloc: Allocator, process: windows.HANDLE) ![]u8 {
    var token: ?windows.HANDLE = null;
    if (OpenProcessToken(process, token_query, &token) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    defer _ = windows.CloseHandle(token.?);

    var token_buffer: [512]u8 align(@alignOf(TokenUser)) = undefined;
    var token_len: windows.DWORD = 0;
    if (GetTokenInformation(
        token.?,
        token_user_class,
        &token_buffer,
        token_buffer.len,
        &token_len,
    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

    const token_user: *const TokenUser = @ptrCast(&token_buffer);
    var sid_w: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(token_user.user.sid, &sid_w) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    defer _ = LocalFree(sid_w);
    return std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(sid_w.?));
}

const PipeSecurity = struct {
    descriptor: *anyopaque,

    fn init(alloc: Allocator) !PipeSecurity {
        const sid = try tokenUserSidAlloc(alloc, windows.GetCurrentProcess());
        defer alloc.free(sid);
        const sddl = try std.fmt.allocPrintSentinel(
            alloc,
            "O:{s}D:P(A;;GA;;;{s})",
            .{ sid, sid },
            0,
        );
        defer alloc.free(sddl);
        const sddl_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, sddl);
        defer alloc.free(sddl_w);

        var descriptor: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_w.ptr,
            sddl_revision_1,
            &descriptor,
            null,
        ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

        return .{ .descriptor = descriptor.? };
    }

    fn deinit(self: *PipeSecurity) void {
        _ = LocalFree(self.descriptor);
        self.* = undefined;
    }

    fn attributes(self: *PipeSecurity) windows.SECURITY_ATTRIBUTES {
        return .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = self.descriptor,
            .bInheritHandle = windows.FALSE,
        };
    }
};

const Ring = struct {
    bytes: []u8,
    head: usize = 0,
    len: usize = 0,
    total: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    const Stats = struct {
        total: u64,
        retained: usize,
        capacity: usize,
    };

    const Snapshot = struct {
        len: usize,
        cursor: u64,
    };

    fn append(self: *Ring, src: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.total += src.len;
        if (src.len >= self.bytes.len) {
            @memcpy(self.bytes, src[src.len - self.bytes.len ..]);
            self.head = 0;
            self.len = self.bytes.len;
            return;
        }

        const free = self.bytes.len - self.len;
        if (src.len > free) {
            const dropped = src.len - free;
            self.head = (self.head + dropped) % self.bytes.len;
            self.len -= dropped;
        }

        const write_at = (self.head + self.len) % self.bytes.len;
        const first_len = @min(src.len, self.bytes.len - write_at);
        @memcpy(self.bytes[write_at .. write_at + first_len], src[0..first_len]);
        @memcpy(self.bytes[0 .. src.len - first_len], src[first_len..]);
        self.len += src.len;
    }

    fn stats(self: *Ring) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.statsLocked();
    }

    fn read(self: *Ring, cursor: *u64, dst: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const retained_start = self.total - self.len;
        if (cursor.* < retained_start) cursor.* = retained_start;
        if (cursor.* >= self.total) return 0;

        const read_len: usize = @intCast(@min(self.total - cursor.*, dst.len));
        const offset: usize = @intCast(cursor.* - retained_start);
        const read_at = (self.head + offset) % self.bytes.len;
        const first_len = @min(read_len, self.bytes.len - read_at);
        @memcpy(dst[0..first_len], self.bytes[read_at .. read_at + first_len]);
        @memcpy(dst[first_len..read_len], self.bytes[0 .. read_len - first_len]);
        cursor.* += read_len;
        return read_len;
    }

    fn snapshotInto(self: *Ring, dst: []u8) Snapshot {
        std.debug.assert(dst.len >= self.bytes.len);
        self.mutex.lock();
        defer self.mutex.unlock();

        const first_len = @min(self.len, self.bytes.len - self.head);
        @memcpy(dst[0..first_len], self.bytes[self.head .. self.head + first_len]);
        @memcpy(dst[first_len..self.len], self.bytes[0 .. self.len - first_len]);
        return .{ .len = self.len, .cursor = self.total };
    }

    fn statsLocked(self: *Ring) Stats {
        return .{
            .total = self.total,
            .retained = self.len,
            .capacity = self.bytes.len,
        };
    }
};

const DrainContext = struct {
    output: windows.HANDLE,
    ring: *Ring,
};

// Keep all diagnostics off this thread. Anything the host writes to stderr can
// block indefinitely when stderr is a pipe whose reader stops consuming, and
// this is the only thread draining ConPTY. Blocking here would backpressure the
// shell even with no client attached, which is the load-bearing property this
// spike exists to measure.
fn drainConpty(context: *DrainContext) void {
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        var read_len: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            context.output,
            &buffer,
            buffer.len,
            &read_len,
            null,
        ) == 0 or read_len == 0) return;

        context.ring.append(buffer[0..read_len]);
    }
}

const stats_sample_interval_ns = 20 * std.time.ns_per_ms;

const StatsContext = struct {
    ring: *Ring,
    stop: std.atomic.Value(bool) = .init(false),
};

// Samples the ring on its own thread so a stalled stderr consumer can only stall
// diagnostics, never ConPTY draining. This thread is detached and never joined:
// the print below can block indefinitely on a stderr pipe nobody reads, and a
// thread already inside WriteFile cannot observe `stop`, so teardown must not
// wait on it. `stop` is still honoured for the ordinary case, where it lets the
// sampler publish one last set of totals and exit promptly.
fn reportRingStats(context: *StatsContext) void {
    var last_total: u64 = 0;
    while (true) {
        const stopping = context.stop.load(.acquire);
        const stats = context.ring.stats();
        if (stats.total != last_total) {
            last_total = stats.total;
            std.debug.print(
                "RING_STATS total={} retained={} capacity={}\n",
                .{ stats.total, stats.retained, stats.capacity },
            );
        }
        if (stopping) return;
        std.Thread.sleep(stats_sample_interval_ns);
    }
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) return usage();

    if (std.mem.eql(u8, args[1], "serve")) {
        try serve(alloc, args[2..]);
    } else if (std.mem.eql(u8, args[1], "attach")) {
        try attach(alloc, args[2..]);
    } else {
        return usage();
    }
}

fn usage() error{InvalidArguments} {
    std.debug.print(
        \\usage: conpty-host serve --pipe <name> [--ring-size <bytes>]
        \\       conpty-host attach --pipe <name> [--resize <columns>x<rows>] [--stay-on-eof]
        \\
    , .{});
    return error.InvalidArguments;
}

fn serve(alloc: Allocator, args: []const [:0]u8) !void {
    var pipe_name_arg: ?[]const u8 = null;
    var ring_size: usize = default_ring_size;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pipe") and i + 1 < args.len) {
            i += 1;
            pipe_name_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--ring-size") and i + 1 < args.len) {
            i += 1;
            ring_size = try std.fmt.parseInt(usize, args[i], 10);
        } else {
            return usage();
        }
    }
    if (ring_size == 0) return error.InvalidRingSize;

    const pipe_name = try makePipeName(alloc, pipe_name_arg orelse return usage());
    defer alloc.free(pipe_name);
    const pipe_name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name);
    defer alloc.free(pipe_name_w);

    // The stats sampler is deliberately never joined (see the teardown below), so
    // it can still be running when serve returns. Everything it reads therefore
    // has to outlive this frame: the ring, its backing bytes, and the sampler
    // context come from the page allocator and are never freed. This host is a
    // one-shot process, so the OS reclaims them at exit. Keeping them out of the
    // GPA also stops its leak report from firing at teardown, which would itself
    // be another blocking write to the stderr we may already be stuck on.
    const ring = try std.heap.page_allocator.create(Ring);
    ring.* = .{ .bytes = try std.heap.page_allocator.alloc(u8, ring_size) };
    const stats_context = try std.heap.page_allocator.create(StatsContext);
    stats_context.* = .{ .ring = ring };

    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80 });
    var command: Command = .{
        .path = "pwsh.exe",
        .args = &.{ "pwsh.exe", "-NoLogo", "-NoProfile" },
        .pseudo_console = pty.pseudoConsole(),
        .windows_job_object_plan = .{
            .mode = .always,
            .attach_policy = .hard_fail,
            .kill_on_close = true,
        },
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    var drain_thread: ?std.Thread = null;
    defer {
        command.closeWindowsJobObject();
        pty.deinit();
        // Joining the drain thread is safe: pty.deinit closed the handle it reads,
        // so its ReadFile returns and it exits.
        if (drain_thread) |thread| thread.join();
        // Signal the stats sampler but never join it. If stderr is a pipe nobody
        // drains, the sampler can be blocked inside a write, and no signal wakes a
        // thread already inside WriteFile, so joining it would hang teardown and
        // leave this broker alive after its shell exited. Abandoning it is safe
        // because everything it touches is intentionally never freed.
        stats_context.stop.store(true, .release);
        if (command.pid) |process| _ = windows.CloseHandle(process);
    }

    try command.start(alloc);
    const shell_pid = win32_job_object.GetProcessId(command.pid.?);
    if (shell_pid == 0) return windows.unexpectedError(windows.kernel32.GetLastError());

    var drain_context = DrainContext{ .output = pty.out_pipe, .ring = ring };
    drain_thread = try std.Thread.spawn(.{}, drainConpty, .{&drain_context});
    const stats_thread = try std.Thread.spawn(.{}, reportRingStats, .{stats_context});
    stats_thread.detach();

    var security = try PipeSecurity.init(alloc);
    defer security.deinit();

    // Create the one pipe instance before advertising the name, and keep it alive
    // for the whole host lifetime. The \\.\pipe namespace is machine-global and
    // any local user can both enumerate it and create a name in it, so the DACL
    // below protects the object this process created but never reserves the name
    // itself. Destroying and recreating the instance between clients would leave
    // the name unowned in the gap, letting any local user stand up a permissive
    // pipe of the same name; FIRST_PIPE_INSTANCE would then fail this host closed,
    // which protects the host but not a reconnecting client. That client does
    // authenticate the server (see verifyPipeServer), but only by user, so a
    // different-user impostor is rejected while a same-user one would still
    // capture keystrokes. Reusing one instance removes the window for both cases.
    var security_attributes = security.attributes();
    const pipe = try createHostPipe(pipe_name_w.ptr, &security_attributes);
    defer _ = windows.CloseHandle(pipe);
    const accept_event = try createManualResetEvent();
    defer _ = windows.CloseHandle(accept_event);
    const server = OverlappedPipe{ .handle = pipe, .event = accept_event };

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print(
        "CONPTY_HOST_READY pipe={s} host_pid={} shell_pid={} ring_capacity={} security=current-user\n",
        .{ pipe_name, windows.GetCurrentProcessId(), shell_pid, ring_size },
    );
    try stdout_writer.interface.flush();

    while (shellRunning(command.pid.?)) {
        // The accept is overlapped and waits on the shell's process handle as
        // well, so a shell that exits while no client is attached releases the
        // host into teardown instead of leaving it parked until some client
        // happens to connect.
        const outcome = acceptClientOrShellExit(pipe, accept_event, command.pid.?) catch |err| switch (err) {
            error.BrokenPipe, error.NoData, error.PipeNotConnected => {
                _ = DisconnectNamedPipe(pipe);
                continue;
            },
            else => return err,
        };
        if (outcome == .shell_exited) break;

        serveClient(alloc, server, &pty, ring, command.pid.?) catch |err| switch (err) {
            error.BrokenPipe, error.NoData, error.PipeNotConnected => {},
            else => return err,
        };

        // Discards whatever is still buffered in the instance, so the next client
        // cannot observe the previous client's bytes, and returns the instance to
        // a listening state for the next accept. All other per-client state
        // (replay snapshot, ring cursor, frame buffers) is local to serveClient
        // and is rebuilt on the next call. Max instances stays 1, so the
        // one-client-at-a-time invariant is unchanged; a second client now sees
        // ERROR_PIPE_BUSY instead of ERROR_FILE_NOT_FOUND, and connectClient
        // already retries on both.
        _ = DisconnectNamedPipe(pipe);
    }
}

fn serveClient(
    alloc: Allocator,
    pipe: OverlappedPipe,
    pty: *Pty,
    ring: *Ring,
    shell: windows.HANDLE,
) !void {
    const first = try readHeader(pipe);
    if (first.tag != .attach or first.len != 0) return error.ExpectedAttach;

    // Never hold the ring lock across a pipe write. A client that stops reading
    // must not be able to stop the load-bearing ConPTY drain thread.
    const replay_bytes = try alloc.alloc(u8, ring.bytes.len);
    defer alloc.free(replay_bytes);
    const snapshot = ring.snapshotInto(replay_bytes);
    var replay_offset: usize = 0;
    while (replay_offset < snapshot.len) {
        const frame_len = @min(max_frame_payload, snapshot.len - replay_offset);
        try sendFrame(pipe, .output, replay_bytes[replay_offset .. replay_offset + frame_len]);
        replay_offset += frame_len;
    }

    var output: [32 * 1024]u8 = undefined;
    var cursor = snapshot.cursor;

    var payload: [max_frame_payload]u8 = undefined;
    while (shellRunning(shell)) {
        const read_len = ring.read(&cursor, &output);
        if (read_len > 0) try sendFrame(pipe, .output, output[0..read_len]);

        var available: windows.DWORD = 0;
        if (PeekNamedPipe(pipe.handle, null, 0, null, &available, null) == 0) {
            return pipeError();
        }
        if (available >= 5) {
            const header = try readHeader(pipe);
            if (header.len > payload.len) return error.FrameTooLarge;
            try readExact(pipe, payload[0..header.len]);
            switch (header.tag) {
                .detach => {
                    if (header.len != 0) return error.InvalidFrame;
                    return;
                },
                .resize => {
                    if (header.len != 4) return error.InvalidFrame;
                    const columns = std.mem.readInt(u16, payload[0..2], .little);
                    const rows = std.mem.readInt(u16, payload[2..4], .little);
                    if (columns == 0 or rows == 0) return error.InvalidResize;
                    try pty.setSize(.{ .ws_col = columns, .ws_row = rows });
                },
                .input => try writePtyInput(pty.in_pipe, payload[0..header.len]),
                else => return error.InvalidFrame,
            }
        }

        if (read_len == 0 and available < 5) {
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }
    }
}

// The client's handle is an ordinary synchronous file handle.
const SyncPipe = struct {
    handle: windows.HANDLE,

    fn read(self: SyncPipe, dst: []u8) !usize {
        var read_len: windows.DWORD = 0;
        if (windows.kernel32.ReadFile(
            self.handle,
            dst.ptr,
            @intCast(dst.len),
            &read_len,
            null,
        ) == 0) return pipeError();
        return read_len;
    }

    fn write(self: SyncPipe, src: []const u8) !usize {
        var write_len: windows.DWORD = 0;
        if (windows.kernel32.WriteFile(
            self.handle,
            src.ptr,
            @intCast(src.len),
            &write_len,
            null,
        ) == 0) return pipeError();
        return write_len;
    }
};

// The host's instance is FILE_FLAG_OVERLAPPED so that its accept can be
// cancelled, which means every read and write on it must be issued overlapped
// too. One thread performs all host-side pipe I/O, so a single manual-reset
// event is enough to serialise it; each call waits for its own completion
// before returning, so the OVERLAPPED never outlives the frame that owns it.
const OverlappedPipe = struct {
    handle: windows.HANDLE,
    event: windows.HANDLE,

    fn read(self: OverlappedPipe, dst: []u8) !usize {
        var request = try self.beginRequest();
        return self.finish(windows.kernel32.ReadFile(
            self.handle,
            dst.ptr,
            @intCast(dst.len),
            null,
            &request,
        ), &request);
    }

    fn write(self: OverlappedPipe, src: []const u8) !usize {
        var request = try self.beginRequest();
        return self.finish(windows.kernel32.WriteFile(
            self.handle,
            src.ptr,
            @intCast(src.len),
            null,
            &request,
        ), &request);
    }

    fn beginRequest(self: OverlappedPipe) !windows.OVERLAPPED {
        if (ResetEvent(self.event) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        var result: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        result.hEvent = self.event;
        return result;
    }

    fn finish(
        self: OverlappedPipe,
        issued: windows.BOOL,
        overlapped: *windows.OVERLAPPED,
    ) !usize {
        if (issued == 0) {
            const err = windows.kernel32.GetLastError();
            if (err != .IO_PENDING) return pipeErrorFrom(err);
        }
        var transferred: windows.DWORD = 0;
        if (windows.kernel32.GetOverlappedResult(
            self.handle,
            overlapped,
            &transferred,
            windows.TRUE,
        ) == 0) return pipeError();
        return transferred;
    }
};

const AcceptOutcome = enum { client_connected, shell_exited };

// Creates the host's single pipe instance. Overlapped mode is what makes the
// accept cancellable: a synchronous ConnectNamedPipe has no cancellation path,
// so a host whose shell exited with no client attached would otherwise sit in
// the accept until some arbitrary client happened to connect.
fn createHostPipe(
    pipe_name_w: [*:0]const u16,
    security_attributes: ?*windows.SECURITY_ATTRIBUTES,
) !windows.HANDLE {
    const pipe = windows.kernel32.CreateNamedPipeW(
        pipe_name_w,
        pipe_access_duplex | file_flag_first_pipe_instance | windows.FILE_FLAG_OVERLAPPED,
        windows.PIPE_TYPE_BYTE | pipe_reject_remote_clients,
        1,
        max_frame_payload,
        max_frame_payload,
        0,
        security_attributes,
    );
    if (pipe == windows.INVALID_HANDLE_VALUE) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    return pipe;
}

fn createManualResetEvent() !windows.HANDLE {
    return windows.CreateEventExW(
        null,
        null,
        windows.CREATE_EVENT_MANUAL_RESET,
        windows.EVENT_ALL_ACCESS,
    );
}

// Waits for whichever happens first: a client connects to `pipe`, or `shell`
// becomes signalled. A process handle signals when the process exits; the
// tests pass an event so the select logic is exercised without a shell. When
// the shell wins, the pending accept is cancelled and its completion is waited
// for before returning, so the stack OVERLAPPED is never referenced afterwards.
fn acceptClientOrShellExit(
    pipe: windows.HANDLE,
    accept_event: windows.HANDLE,
    shell: windows.HANDLE,
) !AcceptOutcome {
    if (ResetEvent(accept_event) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
    overlapped.hEvent = accept_event;

    if (ConnectNamedPipe(pipe, &overlapped) != 0) return .client_connected;
    switch (windows.kernel32.GetLastError()) {
        .IO_PENDING => {},
        // A client opened the instance before this accept was issued.
        .PIPE_CONNECTED => return .client_connected,
        else => |err| return pipeErrorFrom(err),
    }

    const handles = [_]windows.HANDLE{ accept_event, shell };
    const signalled = try windows.WaitForMultipleObjectsEx(&handles, false, windows.INFINITE, false);
    if (signalled == 0) {
        var transferred: windows.DWORD = 0;
        if (windows.kernel32.GetOverlappedResult(pipe, &overlapped, &transferred, windows.FALSE) == 0) {
            return pipeError();
        }
        return .client_connected;
    }

    // The shell exited first. CancelIoEx reports NOT_FOUND if the accept raced
    // to completion in the meantime; either way GetOverlappedResult returns
    // promptly once the request is no longer in flight. Its result is
    // irrelevant because the host is tearing down.
    _ = windows.kernel32.CancelIoEx(pipe, &overlapped);
    var transferred: windows.DWORD = 0;
    _ = windows.kernel32.GetOverlappedResult(pipe, &overlapped, &transferred, windows.TRUE);
    return .shell_exited;
}

const FrameHeader = struct { tag: Tag, len: usize };

fn readHeader(pipe: anytype) !FrameHeader {
    var header: [5]u8 = undefined;
    try readExact(pipe, &header);
    return .{
        .tag = std.meta.intToEnum(Tag, header[0]) catch return error.InvalidFrame,
        .len = std.mem.readInt(u32, header[1..5], .little),
    };
}

fn sendFrame(pipe: anytype, tag: Tag, payload: []const u8) !void {
    if (payload.len > max_frame_payload) return error.FrameTooLarge;
    var header: [5]u8 = undefined;
    header[0] = @intFromEnum(tag);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try writeAll(pipe, &header);
    try writeAll(pipe, payload);
}

fn readExact(pipe: anytype, dst: []u8) !void {
    var offset: usize = 0;
    while (offset < dst.len) {
        const read_len = try pipe.read(dst[offset..]);
        if (read_len == 0) return error.BrokenPipe;
        offset += read_len;
    }
}

fn writeAll(pipe: anytype, src: []const u8) !void {
    var offset: usize = 0;
    while (offset < src.len) {
        const write_len = try pipe.write(src[offset..]);
        if (write_len == 0) return error.BrokenPipe;
        offset += write_len;
    }
}

fn writePtyInput(handle: windows.HANDLE, src: []const u8) !void {
    var offset: usize = 0;
    while (offset < src.len) {
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        const submitted = windows.kernel32.WriteFile(
            handle,
            src[offset..].ptr,
            @intCast(src.len - offset),
            null,
            &overlapped,
        );
        if (submitted == 0 and @intFromEnum(windows.kernel32.GetLastError()) != error_io_pending) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        const write_len = try windows.GetOverlappedResult(handle, &overlapped, true);
        if (write_len == 0) return error.BrokenPipe;
        offset += write_len;
    }
}

fn pipeError() anyerror {
    return pipeErrorFrom(windows.kernel32.GetLastError());
}

fn pipeErrorFrom(last_error: windows.Win32Error) anyerror {
    return switch (last_error) {
        .BROKEN_PIPE => error.BrokenPipe,
        .NO_DATA => error.NoData,
        .PIPE_NOT_CONNECTED => error.PipeNotConnected,
        else => |err| windows.unexpectedError(err),
    };
}

fn shellRunning(process: windows.HANDLE) bool {
    var exit_code: windows.DWORD = 0;
    if (windows.kernel32.GetExitCodeProcess(process, &exit_code) == 0) return false;
    return exit_code == still_active;
}

fn attach(alloc: Allocator, args: []const [:0]u8) !void {
    var pipe_name_arg: ?[]const u8 = null;
    var resize: ?Resize = null;
    var stay_on_eof = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--pipe") and i + 1 < args.len) {
            i += 1;
            pipe_name_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "--resize") and i + 1 < args.len) {
            i += 1;
            resize = try parseResize(args[i]);
        } else if (std.mem.eql(u8, args[i], "--stay-on-eof")) {
            stay_on_eof = true;
        } else {
            return usage();
        }
    }

    const pipe_name = try makePipeName(alloc, pipe_name_arg orelse return usage());
    defer alloc.free(pipe_name);
    const pipe_name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name);
    defer alloc.free(pipe_name_w);
    const handle = try connectClient(alloc, pipe_name_w);
    defer _ = windows.CloseHandle(handle);
    const pipe = SyncPipe{ .handle = handle };

    try sendFrame(pipe, .attach, "");
    if (resize) |size| {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], size.columns, .little);
        std.mem.writeInt(u16, payload[2..4], size.rows, .little);
        try sendFrame(pipe, .resize, &payload);
    }

    const input_context = InputContext{ .pipe = pipe, .detach_on_eof = !stay_on_eof };
    const input_thread = try std.Thread.spawn(.{}, attachInput, .{input_context});
    input_thread.detach();

    var payload: [max_frame_payload]u8 = undefined;
    while (true) {
        const header = readHeader(pipe) catch |err| switch (err) {
            error.BrokenPipe, error.NoData, error.PipeNotConnected => return,
            else => return err,
        };
        if (header.tag != .output or header.len > payload.len) return error.InvalidFrame;
        try readExact(pipe, payload[0..header.len]);
        try std.fs.File.stdout().writeAll(payload[0..header.len]);
    }
}

const InputContext = struct {
    pipe: SyncPipe,
    detach_on_eof: bool,
};

fn attachInput(context: InputContext) void {
    var input: [16 * 1024]u8 = undefined;
    while (true) {
        const read_len = std.fs.File.stdin().read(&input) catch return;
        if (read_len == 0) {
            if (context.detach_on_eof) sendFrame(context.pipe, .detach, "") catch {};
            return;
        }
        sendFrame(context.pipe, .input, input[0..read_len]) catch return;
    }
}

// A client must not hand its keystrokes to whatever happens to own the pipe name.
// The host holding one instance for its lifetime closes the between-client gap,
// but that says nothing about a name an attacker owned *before* the host started,
// nor about running `attach` when no host is running at all. In both cases the
// open below succeeds against the attacker's pipe and the host's own fail-closed
// behaviour protects only the host. So confirm the server process runs as this
// user before any frame is sent. Anything that cannot be positively confirmed is
// untrusted, including an OpenProcess that fails because the server belongs to
// another user.
fn verifyPipeServer(alloc: Allocator, pipe: windows.HANDLE) !void {
    var server_pid: windows.DWORD = 0;
    if (GetNamedPipeServerProcessId(pipe, &server_pid) == 0) {
        return error.UntrustedPipeServer;
    }
    const server = OpenProcess(
        process_query_limited_information,
        windows.FALSE,
        server_pid,
    ) orelse return error.UntrustedPipeServer;
    defer _ = windows.CloseHandle(server);

    const server_sid = tokenUserSidAlloc(alloc, server) catch return error.UntrustedPipeServer;
    defer alloc.free(server_sid);
    const own_sid = try tokenUserSidAlloc(alloc, windows.GetCurrentProcess());
    defer alloc.free(own_sid);

    // Scope, stated precisely: this authenticates the process currently holding
    // the PID that NPFS recorded as the instance's creator. It does not bind to
    // the pipe endpoint. An attacker can create the instance in a short-lived
    // process, DuplicateHandle the server end into a long-lived one, let the
    // creator exit, and groom PID reuse so that a victim-user process holds that
    // PID by the time OpenProcess runs. So this closes the cross-user case only
    // up to that PID-reuse race. A same-user attacker, and a same-user attacker
    // at a different integrity level, both still pass outright. There is no
    // TOCTOU after the check: the handle stays bound to the verified instance.
    if (!std.mem.eql(u8, server_sid, own_sid)) return error.UntrustedPipeServer;
}

fn connectClient(alloc: Allocator, pipe_name: [:0]const u16) !windows.HANDLE {
    const deadline = std.time.nanoTimestamp() + (10 * std.time.ns_per_s);
    while (true) {
        // Named pipes default to SecurityImpersonation when the caller supplies no
        // SQOS, which would let any server on the other end impersonate this
        // client. Pin identification level so a server can learn who we are but
        // cannot act as us. This does NOT authenticate the server; the host keeps
        // its single pipe instance alive precisely so the name is never available
        // for an impostor to claim.
        const pipe = windows.kernel32.CreateFileW(
            pipe_name.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL | security_sqos_present | security_identification,
            null,
        );
        if (pipe != windows.INVALID_HANDLE_VALUE) {
            errdefer _ = windows.CloseHandle(pipe);
            try verifyPipeServer(alloc, pipe);
            return pipe;
        }

        const last_error = windows.kernel32.GetLastError();
        const last_error_int = @intFromEnum(last_error);
        if ((last_error_int != error_pipe_busy and last_error_int != error_file_not_found) or
            std.time.nanoTimestamp() >= deadline)
        {
            return windows.unexpectedError(last_error);
        }
        _ = WaitNamedPipeW(pipe_name.ptr, 100);
    }
}

fn parseResize(value: []const u8) !Resize {
    const separator = std.mem.indexOfScalar(u8, value, 'x') orelse return error.InvalidResize;
    const columns = try std.fmt.parseInt(u16, value[0..separator], 10);
    const rows = try std.fmt.parseInt(u16, value[separator + 1 ..], 10);
    if (columns == 0 or rows == 0) return error.InvalidResize;
    return .{ .columns = columns, .rows = rows };
}

fn makePipeName(alloc: Allocator, name: []const u8) ![:0]u8 {
    if (name.len == 0 or name.len > 100) return error.InvalidPipeName;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
            return error.InvalidPipeName;
        }
    }
    return std.fmt.allocPrintSentinel(alloc, pipe_prefix ++ "{s}", .{name}, 0);
}

// Hermetic tests for the accept/select logic: a real overlapped instance under
// a random name, a real client open, and an event standing in for the shell's
// process handle. No shell, no ConPTY, no external process.
const TestPipe = struct {
    name_w: [:0]u16,
    security: PipeSecurity,
    pipe: windows.HANDLE,
    accept_event: windows.HANDLE,
    shell_event: windows.HANDLE,

    fn init(alloc: Allocator) !TestPipe {
        var random: [8]u8 = undefined;
        std.crypto.random.bytes(&random);
        const name = try std.fmt.allocPrint(alloc, "test-{x}", .{&random});
        defer alloc.free(name);
        const pipe_name = try makePipeName(alloc, name);
        defer alloc.free(pipe_name);
        const name_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, pipe_name);
        errdefer alloc.free(name_w);

        var security = try PipeSecurity.init(alloc);
        errdefer security.deinit();
        var security_attributes = security.attributes();
        const pipe = try createHostPipe(name_w.ptr, &security_attributes);
        errdefer _ = windows.CloseHandle(pipe);
        const accept_event = try createManualResetEvent();
        errdefer _ = windows.CloseHandle(accept_event);
        const shell_event = try createManualResetEvent();
        errdefer _ = windows.CloseHandle(shell_event);

        return .{
            .name_w = name_w,
            .security = security,
            .pipe = pipe,
            .accept_event = accept_event,
            .shell_event = shell_event,
        };
    }

    fn deinit(self: *TestPipe, alloc: Allocator) void {
        _ = windows.CloseHandle(self.shell_event);
        _ = windows.CloseHandle(self.accept_event);
        _ = windows.CloseHandle(self.pipe);
        self.security.deinit();
        alloc.free(self.name_w);
        self.* = undefined;
    }

    fn accept(self: *TestPipe) !AcceptOutcome {
        return acceptClientOrShellExit(self.pipe, self.accept_event, self.shell_event);
    }

    fn openClient(self: *TestPipe) !windows.HANDLE {
        const client = windows.kernel32.CreateFileW(
            self.name_w.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL | security_sqos_present | security_identification,
            null,
        );
        if (client == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        return client;
    }

    fn openClientAfterDelay(self: *TestPipe, client: *windows.HANDLE) void {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        client.* = self.openClient() catch windows.INVALID_HANDLE_VALUE;
    }
};

test "conpty-host accept: client already connected before the accept is issued" {
    const alloc = std.testing.allocator;
    var fixture = try TestPipe.init(alloc);
    defer fixture.deinit(alloc);

    const client = try fixture.openClient();
    defer _ = windows.CloseHandle(client);

    try std.testing.expectEqual(AcceptOutcome.client_connected, try fixture.accept());
}

test "conpty-host accept: client connecting while the accept is pending" {
    const alloc = std.testing.allocator;
    var fixture = try TestPipe.init(alloc);
    defer fixture.deinit(alloc);

    var client: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    const opener = try std.Thread.spawn(.{}, TestPipe.openClientAfterDelay, .{ &fixture, &client });
    const outcome = try fixture.accept();
    opener.join();
    defer if (client != windows.INVALID_HANDLE_VALUE) {
        _ = windows.CloseHandle(client);
    };

    try std.testing.expect(client != windows.INVALID_HANDLE_VALUE);
    try std.testing.expectEqual(AcceptOutcome.client_connected, outcome);
}

test "conpty-host accept: shell exit cancels a pending accept and leaves the instance usable" {
    const alloc = std.testing.allocator;
    var fixture = try TestPipe.init(alloc);
    defer fixture.deinit(alloc);

    // No client will ever connect; the only way out is the shell handle.
    try std.testing.expect(SetEvent(fixture.shell_event) != 0);
    try std.testing.expectEqual(AcceptOutcome.shell_exited, try fixture.accept());

    // The cancelled accept must not have wedged the instance: a later client
    // still connects and a later accept still completes on the same handle.
    try std.testing.expect(ResetEvent(fixture.shell_event) != 0);
    const client = try fixture.openClient();
    defer _ = windows.CloseHandle(client);
    try std.testing.expectEqual(AcceptOutcome.client_connected, try fixture.accept());
}

test "conpty-host accept: shell exit wins while the accept is pending" {
    const alloc = std.testing.allocator;
    var fixture = try TestPipe.init(alloc);
    defer fixture.deinit(alloc);

    // Signal the shell while the accept is pending on another thread; the
    // accept must return shell_exited rather than wait for a client forever.
    const Signaller = struct {
        fn run(event: windows.HANDLE) void {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            _ = SetEvent(event);
        }
    };
    const signaller = try std.Thread.spawn(.{}, Signaller.run, .{fixture.shell_event});
    defer signaller.join();

    try std.testing.expectEqual(AcceptOutcome.shell_exited, try fixture.accept());
}
