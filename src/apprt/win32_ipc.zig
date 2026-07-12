const std = @import("std");
const builtin = @import("builtin");
const apprt = @import("../apprt.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const BOOL = std.os.windows.BOOL;
const PIPE_READMODE_BYTE = 0x00000000;
pub const pipe_nowait = 0x00000001;
pub const io_timeout_ms: u64 = 2_000;
const poll_interval_ns: u64 = 5 * std.time.ns_per_ms;
pub const wire_version: u32 = 1;
pub const ack_success: u8 = 0;
pub const ack_failure: u8 = 1;
pub const ack_invalid_automation_action: u8 = 2;
pub const ack_unsafe_automation_action: u8 = 3;
pub const ack_invalid_automation_target: u8 = 4;
pub const ack_no_automation_target: u8 = 5;
pub const max_data_response_len: u32 = 16 * 1024 * 1024;
pub const max_action_text_len: u32 = 16 * 1024;
pub const max_new_window_argc: u32 = 4096;
pub const max_new_window_arg_len: u32 = 32 * 1024;
pub const max_new_window_args_bytes: u32 = 256 * 1024;

pub const RequestKind = enum(u8) {
    new_window = 1,
    list_windows = 2,
    perform_action = 3,
};

pub const PerformActionPayload = struct {
    target: apprt.ipc.AutomationActionTarget,
    action_text: []u8,
};

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: windows.HANDLE,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

fn appendU32(dst: *std.ArrayList(u8), alloc: Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try dst.appendSlice(alloc, &buf);
}

fn appendU64(dst: *std.ArrayList(u8), alloc: Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try dst.appendSlice(alloc, &buf);
}

fn readU32(src: []const u8) u32 {
    return std.mem.readInt(u32, src[0..4], .little);
}

fn readU64(src: []const u8) u64 {
    return std.mem.readInt(u64, src[0..8], .little);
}

pub fn freeOwnedArguments(alloc: Allocator, arguments: ?[]const [:0]const u8) void {
    if (arguments) |owned| {
        for (owned) |arg| alloc.free(arg);
        alloc.free(owned);
    }
}

pub fn encodeNewWindowRequest(
    alloc: Allocator,
    arguments: ?[]const [:0]const u8,
) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.new_window));

    const argc: u32 = if (arguments) |argv| arg_count: {
        if (argv.len > max_new_window_argc) return error.InvalidIpcRequest;
        break :arg_count @intCast(argv.len);
    } else 0;
    try appendU32(&encoded, alloc, argc);

    var aggregate_len: u32 = 0;
    if (arguments) |argv| {
        for (argv) |arg| {
            if (arg.len > max_new_window_arg_len) return error.InvalidIpcRequest;
            aggregate_len = std.math.add(u32, aggregate_len, @intCast(arg.len)) catch return error.InvalidIpcRequest;
            if (aggregate_len > max_new_window_args_bytes) return error.InvalidIpcRequest;
            try appendU32(&encoded, alloc, @intCast(arg.len));
            try encoded.appendSlice(alloc, arg);
        }
    }

    return try encoded.toOwnedSlice(alloc);
}

pub fn encodeListWindowsRequest(alloc: Allocator) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.list_windows));
    try appendU32(&encoded, alloc, 0);

    return try encoded.toOwnedSlice(alloc);
}

pub fn encodePerformActionRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
) ![]u8 {
    if (action_text.len == 0 or action_text.len > max_action_text_len) {
        return error.InvalidAutomationAction;
    }

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.perform_action));
    try encoded.append(alloc, switch (target) {
        .focused => 0,
        .surface_id => 1,
    });
    try appendU64(&encoded, alloc, switch (target) {
        .focused => 0,
        .surface_id => |id| id,
    });
    try appendU32(&encoded, alloc, @intCast(action_text.len));
    try encoded.appendSlice(alloc, action_text);

    return try encoded.toOwnedSlice(alloc);
}

pub fn decodeRequestKind(pipe: windows.HANDLE) !RequestKind {
    var header: [5]u8 = undefined;
    try readExactUntil(pipe, &header, deadline());

    if (readU32(header[0..4]) != wire_version) return error.InvalidIpcRequest;
    return std.meta.intToEnum(RequestKind, header[4]) catch error.InvalidIpcRequest;
}

pub fn decodeNewWindowPayload(
    alloc: Allocator,
    pipe: windows.HANDLE,
) !?[]const [:0]const u8 {
    const deadline_ms = deadline();
    var argc_buf: [4]u8 = undefined;
    try readExactUntil(pipe, &argc_buf, deadline_ms);

    const argc = readU32(&argc_buf);
    if (argc == 0) return null;
    if (argc > max_new_window_argc) return error.InvalidIpcRequest;

    const argv = try alloc.alloc([:0]const u8, argc);
    var initialized_argc: usize = 0;
    errdefer {
        for (argv[0..initialized_argc]) |arg| alloc.free(arg);
        alloc.free(argv);
    }

    var aggregate_len: u32 = 0;
    for (argv, 0..) |*slot, i| {
        var len_buf: [4]u8 = undefined;
        try readExactUntil(pipe, &len_buf, deadline_ms);
        const len = readU32(&len_buf);
        if (len > max_new_window_arg_len) return error.InvalidIpcRequest;
        aggregate_len = std.math.add(u32, aggregate_len, len) catch return error.InvalidIpcRequest;
        if (aggregate_len > max_new_window_args_bytes) return error.InvalidIpcRequest;

        const arg = try alloc.allocSentinel(u8, len, 0);
        readExactUntil(pipe, arg[0..len], deadline_ms) catch |err| {
            alloc.free(arg);
            return err;
        };
        slot.* = arg;
        initialized_argc = i + 1;
    }

    return argv;
}

pub fn decodePerformActionPayload(
    alloc: Allocator,
    pipe: windows.HANDLE,
) !PerformActionPayload {
    const deadline_ms = deadline();
    var header: [13]u8 = undefined;
    try readExactUntil(pipe, &header, deadline_ms);

    const target: apprt.ipc.AutomationActionTarget = switch (header[0]) {
        0 => .focused,
        1 => .{ .surface_id = readU64(header[1..9]) },
        else => return error.InvalidIpcRequest,
    };
    const len = readU32(header[9..13]);
    if (len == 0 or len > max_action_text_len) {
        return error.InvalidAutomationAction;
    }

    const action_text = try alloc.alloc(u8, len);
    errdefer alloc.free(action_text);
    try readExactUntil(pipe, action_text, deadline_ms);
    return .{
        .target = target,
        .action_text = action_text,
    };
}

pub fn writeAck(pipe: windows.HANDLE, success: bool) !void {
    return writeAckStatus(pipe, if (success) ack_success else ack_failure);
}

pub fn writeAckStatus(pipe: windows.HANDLE, status: u8) !void {
    var response: [5]u8 = undefined;
    std.mem.writeInt(u32, response[0..4], wire_version, .little);
    response[4] = status;
    try writeAll(pipe, &response);
}

pub fn readAck(pipe: windows.HANDLE) !bool {
    var response: [5]u8 = undefined;
    try readExact(pipe, &response);
    if (readU32(response[0..4]) != wire_version) return error.InvalidIpcResponse;
    return switch (response[4]) {
        ack_success => true,
        ack_failure => error.IPCFailed,
        ack_invalid_automation_action => error.InvalidAutomationAction,
        ack_unsafe_automation_action => error.UnsafeAutomationAction,
        ack_invalid_automation_target => error.InvalidAutomationTarget,
        ack_no_automation_target => error.NoAutomationTarget,
        else => error.InvalidIpcResponse,
    };
}

pub fn writeDataResponse(
    pipe: windows.HANDLE,
    success: bool,
    body: []const u8,
) !void {
    if (body.len > max_data_response_len) return error.InvalidIpcResponse;

    var header: [9]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], wire_version, .little);
    header[4] = if (success) ack_success else ack_failure;
    std.mem.writeInt(u32, header[5..9], @intCast(body.len), .little);
    try writeAll(pipe, &header);
    if (body.len > 0) try writeAll(pipe, body);
}

pub fn readDataResponse(
    alloc: Allocator,
    pipe: windows.HANDLE,
) ![]u8 {
    var header: [5]u8 = undefined;
    try readExact(pipe, &header);
    if (readU32(header[0..4]) != wire_version) return error.InvalidIpcResponse;

    const success = switch (header[4]) {
        ack_success => true,
        ack_failure => false,
        else => return error.InvalidIpcResponse,
    };

    var len_buf: [4]u8 = undefined;
    readExact(pipe, &len_buf) catch |err| switch (err) {
        error.EndOfStream => {
            if (!success) return error.IPCFailed;
            return error.InvalidIpcResponse;
        },
        else => return err,
    };

    if (!success) return error.IPCFailed;

    const len = readU32(&len_buf);
    if (len > max_data_response_len) return error.InvalidIpcResponse;
    const body = try alloc.alloc(u8, len);
    errdefer alloc.free(body);
    if (len > 0) try readExact(pipe, body);
    return body;
}

pub fn readExact(pipe: windows.HANDLE, dst: []u8) !void {
    return readExactUntil(pipe, dst, deadline());
}

pub fn readExactWithTimeout(
    pipe: windows.HANDLE,
    dst: []u8,
    timeout_ms: u64,
) !void {
    return readExactUntil(pipe, dst, GetTickCount64() +| timeout_ms);
}

fn deadline() u64 {
    return GetTickCount64() +| io_timeout_ms;
}

fn readExactUntil(
    pipe: windows.HANDLE,
    dst: []u8,
    deadline_ms: u64,
) !void {
    var offset: usize = 0;
    while (offset < dst.len) {
        if (GetTickCount64() >= deadline_ms) return error.IpcTimeout;
        var read_len: u32 = 0;
        if (windows.kernel32.ReadFile(
            pipe,
            dst[offset..].ptr,
            @intCast(dst.len - offset),
            &read_len,
            null,
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            switch (err) {
                .BROKEN_PIPE => return error.EndOfStream,
                .NO_DATA => {
                    std.Thread.sleep(poll_interval_ns);
                    continue;
                },
                else => return windows.unexpectedError(err),
            }
        }

        if (read_len == 0) return error.EndOfStream;
        offset += read_len;
    }
}

pub fn writeAll(pipe: windows.HANDLE, src: []const u8) !void {
    const started_at = GetTickCount64();
    var offset: usize = 0;
    while (offset < src.len) {
        var write_len: u32 = 0;
        if (windows.kernel32.WriteFile(
            pipe,
            src[offset..].ptr,
            @intCast(src.len - offset),
            &write_len,
            null,
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            if (err == .NO_DATA) {
                if (GetTickCount64() -| started_at >= io_timeout_ms) {
                    return error.IpcTimeout;
                }
                std.Thread.sleep(poll_interval_ns);
                continue;
            }
            return windows.unexpectedError(err);
        }
        if (write_len == 0) return error.WriteFailed;
        offset += write_len;
    }
}

test "win32 IPC silent client read is bounded" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pipe_name_utf8 = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "\\\\.\\pipe\\winghostty-ipc-timeout-{d}",
        .{GetTickCount64()},
        0,
    );
    defer std.testing.allocator.free(pipe_name_utf8);
    const pipe_name = try std.unicode.utf8ToUtf16LeAllocZ(
        std.testing.allocator,
        pipe_name_utf8,
    );
    defer std.testing.allocator.free(pipe_name);

    const server = windows.kernel32.CreateNamedPipeW(
        pipe_name.ptr,
        0x00000003,
        windows.PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | pipe_nowait,
        1,
        1024,
        1024,
        0,
        null,
    );
    try std.testing.expect(server != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(server);

    try std.testing.expectEqual(@as(BOOL, 0), ConnectNamedPipe(server, null));
    try std.testing.expectEqual(windows.Win32Error.PIPE_LISTENING, windows.kernel32.GetLastError());

    const client = windows.kernel32.CreateFileW(
        pipe_name.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    try std.testing.expect(client != windows.INVALID_HANDLE_VALUE);
    defer _ = windows.CloseHandle(client);

    const connected = ConnectNamedPipe(server, null);
    if (connected == 0) {
        try std.testing.expectEqual(windows.Win32Error.PIPE_CONNECTED, windows.kernel32.GetLastError());
    }

    var byte: [1]u8 = undefined;
    try std.testing.expectError(
        error.IpcTimeout,
        readExactWithTimeout(server, &byte, 10),
    );
}

test "win32 encodeListWindowsRequest preserves legacy zero-argc trailer" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const request = try encodeListWindowsRequest(std.testing.allocator);
    defer std.testing.allocator.free(request);

    try std.testing.expectEqual(@as(usize, 9), request.len);
    try std.testing.expectEqual(wire_version, readU32(request[0..4]));
    try std.testing.expectEqual(@intFromEnum(RequestKind.list_windows), request[4]);
    try std.testing.expectEqual(@as(u32, 0), readU32(request[5..9]));
}

test "win32 decodeNewWindowPayload rejects oversized argument length before allocation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("ipc-request-arg-too-large.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();

    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    std.mem.writeInt(u32, buf[4..8], max_new_window_arg_len + 1, .little);
    try file.writeAll(&buf);
    try file.seekTo(0);

    try std.testing.expectError(
        error.InvalidIpcRequest,
        decodeNewWindowPayload(std.testing.allocator, file.handle),
    );
}

test "win32 decodeNewWindowPayload rejects aggregate argument bytes before allocation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("ipc-request-args-too-large.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();

    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 2, .little);
    std.mem.writeInt(u32, buf[4..8], max_new_window_args_bytes, .little);
    std.mem.writeInt(u32, buf[8..12], 1, .little);
    try file.writeAll(&buf);
    try file.seekTo(0);

    try std.testing.expectError(
        error.InvalidIpcRequest,
        decodeNewWindowPayload(std.testing.allocator, file.handle),
    );
}

test "win32 decodeNewWindowPayload cleans up initialized args on partial EOF" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("ipc-request-partial-eof.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 2, .little);
    std.mem.writeInt(u32, header[4..8], 1, .little);
    header[8] = 'x';
    std.mem.writeInt(u32, header[9..13], 1, .little);
    try file.writeAll(&header);
    try file.seekTo(0);

    try std.testing.expectError(
        error.EndOfStream,
        decodeNewWindowPayload(std.testing.allocator, file.handle),
    );
}

test "win32 encodeNewWindowRequest rejects oversized forwarded arguments" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const oversized = try std.testing.allocator.allocSentinel(u8, max_new_window_arg_len + 1, 0);
    defer std.testing.allocator.free(oversized);
    @memset(oversized[0 .. max_new_window_arg_len + 1], 'x');

    try std.testing.expectError(
        error.InvalidIpcRequest,
        encodeNewWindowRequest(std.testing.allocator, &.{oversized}),
    );
}
