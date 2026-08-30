const std = @import("std");
const builtin = @import("builtin");
const apprt = @import("../apprt.zig");
const sys = @import("win32/sys.zig");
const win32_layouts = @import("win32_layouts.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const BOOL = std.os.windows.BOOL;
const PIPE_READMODE_BYTE = 0x00000000;
pub const pipe_nowait = 0x00000001;
pub const io_timeout_ms: u64 = 2_000;
pub const automation_response_timeout_ms: u64 = 10_000;
const poll_interval_ns: u64 = 5 * std.time.ns_per_ms;
pub const wire_version: u32 = 1;
pub const ack_success: u8 = 0;
pub const ack_failure: u8 = 1;
pub const ack_invalid_automation_action: u8 = 2;
pub const ack_unsafe_automation_action: u8 = 3;
pub const ack_invalid_automation_target: u8 = 4;
pub const ack_no_automation_target: u8 = 5;
pub const ack_automation_target_not_found: u8 = 6;
pub const ack_automation_policy_refused: u8 = 7;
pub const max_data_response_len: u32 = 16 * 1024 * 1024;
pub const max_action_text_len: u32 = 16 * 1024;
pub const max_new_window_argc: u32 = 4096;
pub const max_new_window_arg_len: u32 = 32 * 1024;
pub const max_new_window_args_bytes: u32 = 256 * 1024;
pub const max_layout_name_len: u32 = @intCast(win32_layouts.max_name_bytes);

pub const RequestKind = enum(u8) {
    new_window = 1,
    list_windows = 2,
    perform_action = 3,
    focus = 6,
    send_text = 7,
    launch_layout = 8,
};

pub const PerformActionPayload = struct {
    target: apprt.ipc.AutomationActionTarget,
    action_text: []u8,
};

pub const SendTextPayload = struct {
    target: apprt.ipc.AutomationTarget,
    text: []u8,

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

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

fn appendAutomationTarget(
    dst: *std.ArrayList(u8),
    alloc: Allocator,
    target: apprt.ipc.AutomationTarget,
) !void {
    const tag: u8, const value: u64 = switch (target) {
        .focused => .{ 0, 0 },
        .surface_id => |id| if (id == 0) return error.InvalidAutomationTarget else .{ 1, id },
        .window_id => |id| if (id == 0) return error.InvalidAutomationTarget else .{ 2, id },
    };
    try dst.append(alloc, tag);
    try appendU64(dst, alloc, value);
}

fn decodeAutomationTarget(src: *const [9]u8) !apprt.ipc.AutomationTarget {
    const value = readU64(src[1..9]);
    return switch (src[0]) {
        0 => if (value == 0) .focused else error.InvalidAutomationTarget,
        1 => if (value != 0) .{ .surface_id = value } else error.InvalidAutomationTarget,
        2 => if (value != 0 and value <= std.math.maxInt(u32))
            .{ .window_id = @intCast(value) }
        else
            error.InvalidAutomationTarget,
        else => error.InvalidAutomationTarget,
    };
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

pub fn encodeLaunchLayoutRequest(
    alloc: Allocator,
    name: []const u8,
) ![]u8 {
    try validateLaunchLayoutName(name);

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.launch_layout));
    try appendU32(&encoded, alloc, @intCast(name.len));
    try encoded.appendSlice(alloc, name);
    return try encoded.toOwnedSlice(alloc);
}

pub fn encodeFocusRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationTarget,
) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);
    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.focus));
    try appendAutomationTarget(&encoded, alloc, target);
    return try encoded.toOwnedSlice(alloc);
}

pub fn encodeSendTextRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationTarget,
    text: []const u8,
) ![]u8 {
    if (text.len == 0 or text.len > max_action_text_len or
        !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null)
    {
        return error.InvalidAutomationText;
    }

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);
    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.send_text));
    try appendAutomationTarget(&encoded, alloc, target);
    try appendU32(&encoded, alloc, @intCast(text.len));
    try encoded.appendSlice(alloc, text);
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

pub fn decodeLaunchLayoutPayload(
    alloc: Allocator,
    pipe: windows.HANDLE,
) ![]u8 {
    const deadline_ms = deadline();
    var len_buf: [4]u8 = undefined;
    try readExactUntil(pipe, &len_buf, deadline_ms);

    const len = readU32(&len_buf);
    if (len == 0 or len > max_layout_name_len) {
        return error.InvalidAutomationAction;
    }

    const name = try alloc.alloc(u8, len);
    errdefer alloc.free(name);
    try readExactUntil(pipe, name, deadline_ms);
    try validateLaunchLayoutName(name);
    return name;
}

fn validateLaunchLayoutName(name: []const u8) !void {
    if (name.len == 0 or name.len > @as(usize, max_layout_name_len)) {
        return error.InvalidAutomationAction;
    }
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidAutomationAction;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidAutomationAction;
    win32_layouts.validateName(name) catch return error.InvalidAutomationAction;
}

pub fn decodeFocusPayload(pipe: windows.HANDLE) !apprt.ipc.AutomationTarget {
    var encoded: [9]u8 = undefined;
    try readExactUntil(pipe, &encoded, deadline());
    return try decodeAutomationTarget(&encoded);
}

pub fn decodeSendTextPayload(
    alloc: Allocator,
    pipe: windows.HANDLE,
) !SendTextPayload {
    const deadline_ms = deadline();
    var header: [13]u8 = undefined;
    try readExactUntil(pipe, &header, deadline_ms);
    const target = try decodeAutomationTarget(header[0..9]);
    const len = readU32(header[9..13]);
    if (len == 0 or len > max_action_text_len) return error.InvalidAutomationText;

    const text = try alloc.alloc(u8, len);
    errdefer alloc.free(text);
    try readExactUntil(pipe, text, deadline_ms);
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) {
        return error.InvalidAutomationText;
    }
    return .{ .target = target, .text = text };
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
    return readAckWithTimeout(pipe, io_timeout_ms);
}

pub fn readAckWithTimeout(pipe: windows.HANDLE, timeout_ms: u64) !bool {
    var response: [5]u8 = undefined;
    try readExactWithTimeout(pipe, &response, timeout_ms);
    if (readU32(response[0..4]) != wire_version) return error.InvalidIpcResponse;
    return switch (response[4]) {
        ack_success => true,
        ack_failure => error.IPCFailed,
        ack_invalid_automation_action => error.InvalidAutomationAction,
        ack_unsafe_automation_action => error.UnsafeAutomationAction,
        ack_invalid_automation_target => error.InvalidAutomationTarget,
        ack_no_automation_target => error.NoAutomationTarget,
        ack_automation_target_not_found => error.AutomationTargetNotFound,
        ack_automation_policy_refused => error.AutomationPolicyRefused,
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
    return readDataResponseWithTimeout(alloc, pipe, io_timeout_ms);
}

pub fn readDataResponseWithTimeout(
    alloc: Allocator,
    pipe: windows.HANDLE,
    timeout_ms: u64,
) ![]u8 {
    const deadline_ms = sys.GetTickCount64() +| timeout_ms;
    var header: [5]u8 = undefined;
    try readExactUntil(pipe, &header, deadline_ms);
    if (readU32(header[0..4]) != wire_version) return error.InvalidIpcResponse;

    const success = switch (header[4]) {
        ack_success => true,
        ack_failure => false,
        else => return error.InvalidIpcResponse,
    };

    var len_buf: [4]u8 = undefined;
    readExactUntil(pipe, &len_buf, deadline_ms) catch |err| switch (err) {
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
    if (len > 0) try readExactUntil(pipe, body, deadline_ms);
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
    return readExactUntil(pipe, dst, sys.GetTickCount64() +| timeout_ms);
}

fn deadline() u64 {
    return sys.GetTickCount64() +| io_timeout_ms;
}

fn pipeIoPending(err: windows.Win32Error) bool {
    return err == .NO_DATA or err == .PIPE_NOT_CONNECTED;
}

fn readExactUntil(
    pipe: windows.HANDLE,
    dst: []u8,
    deadline_ms: u64,
) !void {
    var offset: usize = 0;
    while (offset < dst.len) {
        if (sys.GetTickCount64() >= deadline_ms) return error.IpcTimeout;
        var read_len: u32 = 0;
        if (windows.kernel32.ReadFile(
            pipe,
            dst[offset..].ptr,
            @intCast(dst.len - offset),
            &read_len,
            null,
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            if (err == .BROKEN_PIPE) return error.EndOfStream;
            if (pipeIoPending(err)) {
                std.Thread.sleep(poll_interval_ns);
                continue;
            }
            return windows.unexpectedError(err);
        }

        if (read_len == 0) return error.EndOfStream;
        offset += read_len;
    }
}

pub fn writeAll(pipe: windows.HANDLE, src: []const u8) !void {
    const started_at = sys.GetTickCount64();
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
            if (pipeIoPending(err)) {
                if (sys.GetTickCount64() -| started_at >= io_timeout_ms) {
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

fn automationTargetBytes(tag: u8, value: u64) [9]u8 {
    var encoded: [9]u8 = undefined;
    encoded[0] = tag;
    std.mem.writeInt(u64, encoded[1..9], value, .little);
    return encoded;
}

fn writeAutomationSendTextPayload(
    file: *std.fs.File,
    target: [9]u8,
    declared_len: u32,
    body: []const u8,
) !void {
    try file.setEndPos(0);
    try file.seekTo(0);
    try file.writeAll(&target);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, declared_len, .little);
    try file.writeAll(&len_buf);
    try file.writeAll(body);
    try file.seekTo(0);
}

test "win32 automation wire and status numeric pins" {
    try std.testing.expectEqual(@as(u32, 1), wire_version);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(RequestKind.new_window));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(RequestKind.list_windows));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(RequestKind.perform_action));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(RequestKind.focus));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(RequestKind.send_text));
    try std.testing.expectEqual(@as(u8, 0), ack_success);
    try std.testing.expectEqual(@as(u8, 1), ack_failure);
    try std.testing.expectEqual(@as(u8, 2), ack_invalid_automation_action);
    try std.testing.expectEqual(@as(u8, 3), ack_unsafe_automation_action);
    try std.testing.expectEqual(@as(u8, 4), ack_invalid_automation_target);
    try std.testing.expectEqual(@as(u8, 5), ack_no_automation_target);
    try std.testing.expectEqual(@as(u8, 6), ack_automation_target_not_found);
    try std.testing.expectEqual(@as(u8, 7), ack_automation_policy_refused);
}

test "win32 automation focus request round trip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-focus.bin", .{ .read = true });
    defer file.close();

    for ([_]apprt.ipc.AutomationTarget{
        .{ .surface_id = 42 },
        .{ .window_id = 17 },
    }) |target| {
        const request = try encodeFocusRequest(std.testing.allocator, target);
        defer std.testing.allocator.free(request);
        try file.setEndPos(0);
        try file.seekTo(0);
        try file.writeAll(request);
        try file.seekTo(0);
        try std.testing.expectEqual(RequestKind.focus, try decodeRequestKind(file.handle));
        try std.testing.expectEqual(target, try decodeFocusPayload(file.handle));
    }
}

test "win32 automation send text request round trip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const target: apprt.ipc.AutomationTarget = .{ .surface_id = 0x1234 };
    const text = "printable £ ✓ ; | $(allowed) https://example.com mixed";
    const request = try encodeSendTextRequest(std.testing.allocator, target, text);
    defer std.testing.allocator.free(request);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-send-text.bin", .{ .read = true });
    defer file.close();
    try file.writeAll(request);
    try file.seekTo(0);

    try std.testing.expectEqual(RequestKind.send_text, try decodeRequestKind(file.handle));
    var payload = try decodeSendTextPayload(std.testing.allocator, file.handle);
    defer payload.deinit(std.testing.allocator);
    try std.testing.expectEqual(target, payload.target);
    try std.testing.expectEqualStrings(text, payload.text);
}

test "win32 automation target tags reject invalid forms" {
    try std.testing.expectEqual(
        apprt.ipc.AutomationTarget.focused,
        try decodeAutomationTarget(&automationTargetBytes(0, 0)),
    );
    try std.testing.expectEqual(
        apprt.ipc.AutomationTarget{ .surface_id = 42 },
        try decodeAutomationTarget(&automationTargetBytes(1, 42)),
    );
    try std.testing.expectEqual(
        apprt.ipc.AutomationTarget{ .window_id = 17 },
        try decodeAutomationTarget(&automationTargetBytes(2, 17)),
    );

    for ([_][9]u8{
        automationTargetBytes(0, 1),
        automationTargetBytes(1, 0),
        automationTargetBytes(2, 0),
        automationTargetBytes(2, @as(u64, std.math.maxInt(u32)) + 1),
        automationTargetBytes(3, 1),
    }) |encoded| {
        try std.testing.expectError(error.InvalidAutomationTarget, decodeAutomationTarget(&encoded));
    }

    try std.testing.expectError(
        error.InvalidAutomationTarget,
        encodeFocusRequest(std.testing.allocator, .{ .surface_id = 0 }),
    );
    try std.testing.expectError(
        error.InvalidAutomationTarget,
        encodeFocusRequest(std.testing.allocator, .{ .window_id = 0 }),
    );
}

test "win32 automation send text codec enforces text contract" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const target: apprt.ipc.AutomationTarget = .{ .surface_id = 42 };
    const max_text = try std.testing.allocator.alloc(u8, max_action_text_len);
    defer std.testing.allocator.free(max_text);
    @memset(max_text, 'x');
    const max_request = try encodeSendTextRequest(std.testing.allocator, target, max_text);
    defer std.testing.allocator.free(max_request);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-send-text-contract.bin", .{ .read = true });
    defer file.close();
    try file.writeAll(max_request);
    try file.seekTo(0);
    try std.testing.expectEqual(RequestKind.send_text, try decodeRequestKind(file.handle));
    var max_payload = try decodeSendTextPayload(std.testing.allocator, file.handle);
    defer max_payload.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, max_action_text_len), max_payload.text.len);

    const over_text = try std.testing.allocator.alloc(u8, max_action_text_len + 1);
    defer std.testing.allocator.free(over_text);
    @memset(over_text, 'x');
    try std.testing.expectError(
        error.InvalidAutomationText,
        encodeSendTextRequest(std.testing.allocator, target, ""),
    );
    try std.testing.expectError(
        error.InvalidAutomationText,
        encodeSendTextRequest(std.testing.allocator, target, over_text),
    );
    try std.testing.expectError(
        error.InvalidAutomationText,
        encodeSendTextRequest(std.testing.allocator, target, &.{0xFF}),
    );
    try std.testing.expectError(
        error.InvalidAutomationText,
        encodeSendTextRequest(std.testing.allocator, target, "a\x00b"),
    );

    const raw_target = automationTargetBytes(1, 42);
    try writeAutomationSendTextPayload(&file, raw_target, 0, "");
    try std.testing.expectError(
        error.InvalidAutomationText,
        decodeSendTextPayload(std.testing.allocator, file.handle),
    );
    try writeAutomationSendTextPayload(&file, raw_target, max_action_text_len + 1, "");
    try std.testing.expectError(
        error.InvalidAutomationText,
        decodeSendTextPayload(std.testing.allocator, file.handle),
    );
    try writeAutomationSendTextPayload(&file, raw_target, 1, &.{0xFF});
    try std.testing.expectError(
        error.InvalidAutomationText,
        decodeSendTextPayload(std.testing.allocator, file.handle),
    );
    try writeAutomationSendTextPayload(&file, raw_target, 3, "a\x00b");
    try std.testing.expectError(
        error.InvalidAutomationText,
        decodeSendTextPayload(std.testing.allocator, file.handle),
    );
}

test "win32 automation send text partial EOF frees allocation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-send-text-eof.bin", .{ .read = true });
    defer file.close();
    try writeAutomationSendTextPayload(&file, automationTargetBytes(1, 42), 3, "x");
    try std.testing.expectError(
        error.EndOfStream,
        decodeSendTextPayload(std.testing.allocator, file.handle),
    );
}

test "win32 automation ack maps target and policy statuses" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-ack.bin", .{ .read = true });
    defer file.close();

    for ([_]struct { status: u8, expected: anyerror }{
        .{ .status = ack_automation_target_not_found, .expected = error.AutomationTargetNotFound },
        .{ .status = ack_automation_policy_refused, .expected = error.AutomationPolicyRefused },
    }) |case| {
        try file.setEndPos(0);
        try file.seekTo(0);
        try writeAckStatus(file.handle, case.status);
        try file.seekTo(0);
        try std.testing.expectError(case.expected, readAck(file.handle));
    }
}

test "win32 IPC silent client read is bounded" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pipe_name_utf8 = try std.fmt.allocPrintSentinel(
        std.testing.allocator,
        "\\\\.\\pipe\\noctty-ipc-timeout-{d}",
        .{sys.GetTickCount64()},
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

    try std.testing.expectEqual(@as(BOOL, 0), sys.ConnectNamedPipe(server, null));
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

    const connected = sys.ConnectNamedPipe(server, null);
    if (connected == 0) {
        try std.testing.expectEqual(windows.Win32Error.PIPE_CONNECTED, windows.kernel32.GetLastError());
    }

    var byte: [1]u8 = undefined;
    try std.testing.expectError(
        error.IpcTimeout,
        readExactWithTimeout(server, &byte, 10),
    );
}

test "win32 IPC pending pipe states remain retryable" {
    try std.testing.expect(pipeIoPending(.NO_DATA));
    try std.testing.expect(pipeIoPending(.PIPE_NOT_CONNECTED));
    try std.testing.expect(!pipeIoPending(.BROKEN_PIPE));
}

test "win32 IPC request kind values remain stable" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(RequestKind.new_window));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(RequestKind.list_windows));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(RequestKind.perform_action));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(RequestKind.launch_layout));
}

test "win32 launch-layout IPC encode decode round trip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const request = try encodeLaunchLayoutRequest(std.testing.allocator, "Project Alpha");
    defer std.testing.allocator.free(request);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("launch-layout-round-trip.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();
    try file.writeAll(request);
    try file.seekTo(0);

    try std.testing.expectEqual(RequestKind.launch_layout, try decodeRequestKind(file.handle));
    const decoded = try decodeLaunchLayoutPayload(std.testing.allocator, file.handle);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("Project Alpha", decoded);
}

test "win32 launch-layout IPC encoder rejects invalid names" {
    const invalid_utf8 = [_]u8{0xff};
    const oversized = try std.testing.allocator.alloc(u8, max_layout_name_len + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    const invalid_names = [_][]const u8{
        "",
        oversized,
        &invalid_utf8,
        "bad\x00name",
        "..",
        "/",
        "\\",
        "CON",
    };
    for (invalid_names) |name| try std.testing.expectError(
        error.InvalidAutomationAction,
        encodeLaunchLayoutRequest(std.testing.allocator, name),
    );
}

test "win32 launch-layout IPC decoder rejects invalid names without leaks" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const invalid_utf8 = [_]u8{0xff};
    const oversized = try std.testing.allocator.alloc(u8, max_layout_name_len + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    const invalid_names = [_][]const u8{
        "",
        oversized,
        &invalid_utf8,
        "bad\x00name",
        "..",
        "/",
        "\\",
        "CON",
    };
    for (invalid_names, 0..) |name, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "launch-layout-invalid-{d}.bin",
            .{index},
        );
        defer std.testing.allocator.free(file_name);
        var file = try tmp.dir.createFile(file_name, .{
            .read = true,
            .truncate = true,
        });
        defer file.close();

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
        try file.writeAll(&len_buf);
        try file.writeAll(name);
        try file.seekTo(0);
        try std.testing.expectError(
            error.InvalidAutomationAction,
            decodeLaunchLayoutPayload(std.testing.allocator, file.handle),
        );
    }
}

test "win32 launch-layout IPC decoder cleans up on partial EOF" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("launch-layout-partial-eof.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();

    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, 4, .little);
    try file.writeAll(&len_buf);
    try file.writeAll("ab");
    try file.seekTo(0);
    try std.testing.expectError(
        error.EndOfStream,
        decodeLaunchLayoutPayload(std.testing.allocator, file.handle),
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
