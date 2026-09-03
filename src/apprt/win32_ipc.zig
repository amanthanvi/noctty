const std = @import("std");
const builtin = @import("builtin");
const apprt = @import("../apprt.zig");
const sys = @import("win32/sys.zig");
const win32_layouts = @import("win32_layouts.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

const BOOL = std.os.windows.BOOL;
const PIPE_READMODE_BYTE = 0x00000000;
const security_sqos_present: windows.DWORD = 0x00100000;
const security_identification: windows.DWORD = 0x00010000;
pub const pipe_nowait = 0x00000001;
pub const client_pipe_open_flags: windows.DWORD = windows.FILE_ATTRIBUTE_NORMAL |
    security_sqos_present |
    security_identification;
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
    new_tab = 4,
    new_split = 5,
    focus = 6,
    send_text = 7,
    launch_layout = 8,
    list_windows_timed = 9,
    perform_action_timed = 10,
    new_tab_timed = 11,
    new_split_timed = 12,
    focus_timed = 13,
    send_text_timed = 14,
    launch_layout_timed = 15,
};

pub const PerformActionPayload = struct {
    deadline_ms: u64,
    target: apprt.ipc.AutomationActionTarget,
    action_text: []u8,
};

pub const FocusPayload = struct {
    deadline_ms: u64,
    target: apprt.ipc.AutomationTarget,
};

pub const SendTextPayload = struct {
    deadline_ms: u64,
    target: apprt.ipc.AutomationTarget,
    text: []u8,

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const NewTabPayload = struct {
    deadline_ms: u64,
    target: apprt.ipc.AutomationTarget,
    working_directory: ?[]u8,
    pub fn deinit(self: *@This(), alloc: Allocator) void {
        if (self.working_directory) |value| alloc.free(value);
        self.* = undefined;
    }
};
pub const NewSplitPayload = struct {
    deadline_ms: u64,
    target: apprt.ipc.AutomationTarget,
    direction: apprt.ipc.AutomationSplitDirection,
    working_directory: ?[]u8,
    pub fn deinit(self: *@This(), alloc: Allocator) void {
        if (self.working_directory) |value| alloc.free(value);
        self.* = undefined;
    }
};

/// Did the first-instance claim lose to a process that already owns the
/// name? Both codes mean "someone else has it", not "the call was wrong".
pub fn isIpcPipeClaimConflict(err: windows.Win32Error) bool {
    return err == .ACCESS_DENIED or err == .PIPE_BUSY;
}

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

pub fn setAutomationRequestDeadline(encoded: []u8, deadline_ms: u64) !void {
    if (encoded.len < 13) return error.InvalidIpcRequest;
    std.mem.writeInt(u64, encoded[5..13], deadline_ms, .little);
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

fn appendWorkingDirectory(dst: *std.ArrayList(u8), alloc: Allocator, value: ?[]const u8) !void {
    const cwd = value orelse return appendU32(dst, alloc, 0);
    if (cwd.len == 0 or cwd.len > max_new_window_arg_len or
        !std.unicode.utf8ValidateSlice(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null)
    {
        return error.InvalidAutomationWorkingDirectory;
    }
    try appendU32(dst, alloc, @intCast(cwd.len));
    try dst.appendSlice(alloc, cwd);
}

fn decodeWorkingDirectory(alloc: Allocator, pipe: windows.HANDLE, deadline_ms: u64) !?[]u8 {
    var len_buf: [4]u8 = undefined;
    try readExactUntil(pipe, &len_buf, deadline_ms);
    const len = readU32(&len_buf);
    if (len == 0) return null;
    if (len > max_new_window_arg_len) return error.InvalidAutomationWorkingDirectory;
    const cwd = try alloc.alloc(u8, len);
    errdefer alloc.free(cwd);
    try readExactUntil(pipe, cwd, deadline_ms);
    if (!std.unicode.utf8ValidateSlice(cwd) or std.mem.indexOfScalar(u8, cwd, 0) != null) {
        return error.InvalidAutomationWorkingDirectory;
    }
    return cwd;
}

fn validateLaunchTarget(target: apprt.ipc.AutomationTarget, window: bool) !void {
    switch (target) {
        .focused => {},
        .surface_id => if (window) return error.InvalidAutomationTarget,
        .window_id => if (!window) return error.InvalidAutomationTarget,
    }
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

pub fn encodeListWindowsRequest(alloc: Allocator, deadline_ms: u64) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.list_windows_timed));
    try appendU64(&encoded, alloc, deadline_ms);

    return try encoded.toOwnedSlice(alloc);
}

pub fn encodePerformActionRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
    deadline_ms: u64,
) ![]u8 {
    if (action_text.len == 0 or action_text.len > max_action_text_len) {
        return error.InvalidAutomationAction;
    }

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.perform_action_timed));
    try appendU64(&encoded, alloc, deadline_ms);
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
    deadline_ms: u64,
) ![]u8 {
    try validateLaunchLayoutName(name);

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);

    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.launch_layout_timed));
    try appendU64(&encoded, alloc, deadline_ms);
    try appendU32(&encoded, alloc, @intCast(name.len));
    try encoded.appendSlice(alloc, name);
    return try encoded.toOwnedSlice(alloc);
}

fn encodeLaunchRequest(
    alloc: Allocator,
    kind: RequestKind,
    target: apprt.ipc.AutomationTarget,
    direction: ?apprt.ipc.AutomationSplitDirection,
    working_directory: ?[]const u8,
    deadline_ms: u64,
) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);
    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(kind));
    try appendU64(&encoded, alloc, deadline_ms);
    try appendAutomationTarget(&encoded, alloc, target);
    if (direction) |value| try encoded.append(alloc, switch (value) {
        .left => 1,
        .right => 2,
        .up => 3,
        .down => 4,
    });
    try appendWorkingDirectory(&encoded, alloc, working_directory);
    return try encoded.toOwnedSlice(alloc);
}

pub fn encodeNewTabRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationTarget,
    cwd: ?[]const u8,
    deadline_ms: u64,
) ![]u8 {
    try validateLaunchTarget(target, true);
    return encodeLaunchRequest(alloc, .new_tab_timed, target, null, cwd, deadline_ms);
}

pub fn encodeNewSplitRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationTarget,
    direction: apprt.ipc.AutomationSplitDirection,
    cwd: ?[]const u8,
    deadline_ms: u64,
) ![]u8 {
    try validateLaunchTarget(target, false);
    return encodeLaunchRequest(alloc, .new_split_timed, target, direction, cwd, deadline_ms);
}

pub fn encodeFocusRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationTarget,
    deadline_ms: u64,
) ![]u8 {
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);
    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.focus_timed));
    try appendU64(&encoded, alloc, deadline_ms);
    try appendAutomationTarget(&encoded, alloc, target);
    return try encoded.toOwnedSlice(alloc);
}

pub fn encodeSendTextRequest(
    alloc: Allocator,
    target: apprt.ipc.AutomationTarget,
    text: []const u8,
    deadline_ms: u64,
) ![]u8 {
    if (text.len == 0 or text.len > max_action_text_len or
        !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null)
    {
        return error.InvalidAutomationText;
    }

    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(alloc);
    try appendU32(&encoded, alloc, wire_version);
    try encoded.append(alloc, @intFromEnum(RequestKind.send_text_timed));
    try appendU64(&encoded, alloc, deadline_ms);
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

fn decodeAutomationDeadline(
    pipe: windows.HANDLE,
    timed: bool,
    io_deadline_ms: u64,
) !u64 {
    if (!timed) return std.math.maxInt(u64);
    var encoded: [8]u8 = undefined;
    try readExactUntil(pipe, &encoded, io_deadline_ms);
    return readU64(&encoded);
}

pub fn decodeListWindowsDeadline(pipe: windows.HANDLE, timed: bool) !u64 {
    const io_deadline_ms = deadline();
    if (timed) return decodeAutomationDeadline(pipe, true, io_deadline_ms);

    // Kind 2's original v1 payload was a zero u32 trailer. Keep accepting it
    // so an older client can query a newer running instance.
    var trailer: [4]u8 = undefined;
    try readExactUntil(pipe, &trailer, io_deadline_ms);
    if (readU32(&trailer) != 0) return error.InvalidIpcRequest;
    return std.math.maxInt(u64);
}

pub fn decodePerformActionPayload(
    alloc: Allocator,
    pipe: windows.HANDLE,
    timed: bool,
) !PerformActionPayload {
    const io_deadline_ms = deadline();
    const request_deadline_ms = try decodeAutomationDeadline(pipe, timed, io_deadline_ms);
    var header: [13]u8 = undefined;
    try readExactUntil(pipe, &header, io_deadline_ms);

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
    try readExactUntil(pipe, action_text, io_deadline_ms);
    return .{
        .deadline_ms = request_deadline_ms,
        .target = target,
        .action_text = action_text,
    };
}

pub fn decodeLaunchLayoutPayload(
    alloc: Allocator,
    pipe: windows.HANDLE,
    timed: bool,
) !struct { deadline_ms: u64, name: []u8 } {
    const io_deadline_ms = deadline();
    const request_deadline_ms = try decodeAutomationDeadline(pipe, timed, io_deadline_ms);
    var len_buf: [4]u8 = undefined;
    try readExactUntil(pipe, &len_buf, io_deadline_ms);

    const len = readU32(&len_buf);
    if (len == 0 or len > max_layout_name_len) {
        return error.InvalidAutomationAction;
    }

    const name = try alloc.alloc(u8, len);
    errdefer alloc.free(name);
    try readExactUntil(pipe, name, io_deadline_ms);
    try validateLaunchLayoutName(name);
    return .{ .deadline_ms = request_deadline_ms, .name = name };
}

fn validateLaunchLayoutName(name: []const u8) !void {
    if (name.len == 0 or name.len > @as(usize, max_layout_name_len)) {
        return error.InvalidAutomationAction;
    }
    if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidAutomationAction;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidAutomationAction;
    win32_layouts.validateName(name) catch return error.InvalidAutomationAction;
}

pub fn decodeNewTabPayload(alloc: Allocator, pipe: windows.HANDLE, timed: bool) !NewTabPayload {
    const io_deadline_ms = deadline();
    const request_deadline_ms = try decodeAutomationDeadline(pipe, timed, io_deadline_ms);
    var encoded: [9]u8 = undefined;
    try readExactUntil(pipe, &encoded, io_deadline_ms);
    const target = try decodeAutomationTarget(&encoded);
    try validateLaunchTarget(target, true);
    return .{
        .deadline_ms = request_deadline_ms,
        .target = target,
        .working_directory = try decodeWorkingDirectory(alloc, pipe, io_deadline_ms),
    };
}

pub fn decodeNewSplitPayload(alloc: Allocator, pipe: windows.HANDLE, timed: bool) !NewSplitPayload {
    const io_deadline_ms = deadline();
    const request_deadline_ms = try decodeAutomationDeadline(pipe, timed, io_deadline_ms);
    var encoded: [10]u8 = undefined;
    try readExactUntil(pipe, &encoded, io_deadline_ms);
    const target = try decodeAutomationTarget(encoded[0..9]);
    try validateLaunchTarget(target, false);
    const direction: apprt.ipc.AutomationSplitDirection = switch (encoded[9]) {
        1 => .left,
        2 => .right,
        3 => .up,
        4 => .down,
        else => return error.InvalidAutomationDirection,
    };
    const cwd = try decodeWorkingDirectory(alloc, pipe, io_deadline_ms);
    return .{
        .deadline_ms = request_deadline_ms,
        .target = target,
        .direction = direction,
        .working_directory = cwd,
    };
}

pub fn decodeFocusPayload(pipe: windows.HANDLE, timed: bool) !FocusPayload {
    const io_deadline_ms = deadline();
    const request_deadline_ms = try decodeAutomationDeadline(pipe, timed, io_deadline_ms);
    var encoded: [9]u8 = undefined;
    try readExactUntil(pipe, &encoded, io_deadline_ms);
    return .{
        .deadline_ms = request_deadline_ms,
        .target = try decodeAutomationTarget(&encoded),
    };
}

pub fn decodeSendTextPayload(
    alloc: Allocator,
    pipe: windows.HANDLE,
    timed: bool,
) !SendTextPayload {
    const io_deadline_ms = deadline();
    const request_deadline_ms = try decodeAutomationDeadline(pipe, timed, io_deadline_ms);
    var header: [13]u8 = undefined;
    try readExactUntil(pipe, &header, io_deadline_ms);
    const target = try decodeAutomationTarget(header[0..9]);
    const len = readU32(header[9..13]);
    if (len == 0 or len > max_action_text_len) return error.InvalidAutomationText;

    const text = try alloc.alloc(u8, len);
    errdefer alloc.free(text);
    try readExactUntil(pipe, text, io_deadline_ms);
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) {
        return error.InvalidAutomationText;
    }
    return .{
        .deadline_ms = request_deadline_ms,
        .target = target,
        .text = text,
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
    var expired_buffered_budget: ?usize = null;
    while (offset < dst.len) {
        // A zero timeout is a nonblocking poll, not an automatic failure. At
        // (or after) the deadline, snapshot the bytes already buffered and
        // consume at most that snapshot. This permits a buffered multi-read
        // response without letting a producer extend the deadline forever by
        // continuously dribbling short reads.
        if (expired_buffered_budget == null and sys.GetTickCount64() >= deadline_ms) {
            var available: u32 = 0;
            if (sys.PeekNamedPipe(pipe, null, 0, null, &available, null) == 0) {
                const err = windows.kernel32.GetLastError();
                if (err == .BROKEN_PIPE) return error.EndOfStream;
                if (pipeIoPending(err)) return error.IpcTimeout;
                return windows.unexpectedError(err);
            }
            if (available == 0) return error.IpcTimeout;
            expired_buffered_budget = @min(@as(usize, available), dst.len - offset);
        }

        const read_cap = if (expired_buffered_budget) |budget|
            @min(budget, dst.len - offset)
        else
            dst.len - offset;
        var read_len: u32 = 0;
        if (windows.kernel32.ReadFile(
            pipe,
            dst[offset..].ptr,
            @intCast(read_cap),
            &read_len,
            null,
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            if (err == .BROKEN_PIPE) return error.EndOfStream;
            if (pipeIoPending(err)) {
                if (sys.GetTickCount64() >= deadline_ms) return error.IpcTimeout;
                std.Thread.sleep(poll_interval_ns);
                continue;
            }
            return windows.unexpectedError(err);
        }

        if (read_len == 0) return error.EndOfStream;
        offset += read_len;
        if (expired_buffered_budget) |*budget| {
            budget.* -= read_len;
            if (budget.* == 0 and offset < dst.len) return error.IpcTimeout;
        }
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

fn writeAutomationSizedPayload(
    file: *std.fs.File,
    target: [9]u8,
    extra: []const u8,
    declared_len: u32,
    body: []const u8,
) !void {
    try file.setEndPos(0);
    try file.seekTo(0);
    var deadline_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &deadline_buf, test_deadline_ms, .little);
    try file.writeAll(&deadline_buf);
    try file.writeAll(&target);
    try file.writeAll(extra);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, declared_len, .little);
    try file.writeAll(&len_buf);
    try file.writeAll(body);
    try file.seekTo(0);
}

const test_deadline_ms: u64 = 0x0102030405060708;

fn writeAutomationBytes(file: *std.fs.File, bytes: []const u8) !void {
    try file.setEndPos(0);
    try file.seekTo(0);
    try file.writeAll(bytes);
    try file.seekTo(0);
}

test "win32 automation numeric pins" {
    try std.testing.expectEqual(@as(u32, 1), wire_version);
    for ([_]RequestKind{
        .new_window,
        .list_windows,
        .perform_action,
        .new_tab,
        .new_split,
        .focus,
        .send_text,
        .launch_layout,
        .list_windows_timed,
        .perform_action_timed,
        .new_tab_timed,
        .new_split_timed,
        .focus_timed,
        .send_text_timed,
        .launch_layout_timed,
    }, 1..) |kind, value| {
        try std.testing.expectEqual(@as(u8, @intCast(value)), @intFromEnum(kind));
    }
    const acks = [_]u8{ ack_success, ack_failure, ack_invalid_automation_action, ack_unsafe_automation_action, ack_invalid_automation_target, ack_no_automation_target, ack_automation_target_not_found, ack_automation_policy_refused };
    for (acks, 0..) |ack, value| try std.testing.expectEqual(@as(u8, @intCast(value)), ack);
    for ([_]apprt.ipc.AutomationSplitDirection{ .left, .right, .up, .down }, 1..) |direction, value| {
        try std.testing.expectEqual(@as(u8, @intCast(value)), @intFromEnum(direction));
        const request = try encodeNewSplitRequest(
            std.testing.allocator,
            .focused,
            direction,
            null,
            test_deadline_ms,
        );
        defer std.testing.allocator.free(request);
        try std.testing.expectEqual(@as(u8, @intCast(value)), request[22]);
    }
}

test "win32 automation keeps legacy v1 kinds decodable" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-legacy-v1.bin", .{ .read = true });
    defer file.close();

    var list_request: [9]u8 = undefined;
    std.mem.writeInt(u32, list_request[0..4], wire_version, .little);
    list_request[4] = @intFromEnum(RequestKind.list_windows);
    std.mem.writeInt(u32, list_request[5..9], 0, .little);
    try writeAutomationBytes(&file, &list_request);
    try std.testing.expectEqual(RequestKind.list_windows, try decodeRequestKind(file.handle));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try decodeListWindowsDeadline(file.handle, false),
    );

    const action_text = "new_tab";
    var action_request: std.ArrayList(u8) = .empty;
    defer action_request.deinit(std.testing.allocator);
    try appendU32(&action_request, std.testing.allocator, wire_version);
    try action_request.append(std.testing.allocator, @intFromEnum(RequestKind.perform_action));
    try action_request.append(std.testing.allocator, 0);
    try appendU64(&action_request, std.testing.allocator, 0);
    try appendU32(&action_request, std.testing.allocator, @intCast(action_text.len));
    try action_request.appendSlice(std.testing.allocator, action_text);
    try writeAutomationBytes(&file, action_request.items);
    try std.testing.expectEqual(RequestKind.perform_action, try decodeRequestKind(file.handle));
    const payload = try decodePerformActionPayload(std.testing.allocator, file.handle, false);
    defer std.testing.allocator.free(payload.action_text);
    try std.testing.expectEqual(std.math.maxInt(u64), payload.deadline_ms);
    try std.testing.expectEqual(apprt.ipc.AutomationActionTarget.focused, payload.target);
    try std.testing.expectEqualStrings(action_text, payload.action_text);
}

test "win32 automation request and ack round trips" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-roundtrip.bin", .{ .read = true });
    defer file.close();

    for ([_]apprt.ipc.AutomationTarget{ .{ .surface_id = 42 }, .{ .window_id = 17 } }) |target| {
        const request = try encodeFocusRequest(std.testing.allocator, target, test_deadline_ms);
        defer std.testing.allocator.free(request);
        try writeAutomationBytes(&file, request);
        try std.testing.expectEqual(RequestKind.focus_timed, try decodeRequestKind(file.handle));
        const payload = try decodeFocusPayload(file.handle, true);
        try std.testing.expectEqual(test_deadline_ms, payload.deadline_ms);
        try std.testing.expectEqual(target, payload.target);
    }

    const text = "printable £ ✓ ; | $(allowed) https://example.com mixed";
    const send = try encodeSendTextRequest(
        std.testing.allocator,
        .{ .surface_id = 0x1234 },
        text,
        test_deadline_ms,
    );
    defer std.testing.allocator.free(send);
    try writeAutomationBytes(&file, send);
    try std.testing.expectEqual(RequestKind.send_text_timed, try decodeRequestKind(file.handle));
    var sent = try decodeSendTextPayload(std.testing.allocator, file.handle, true);
    defer sent.deinit(std.testing.allocator);
    try std.testing.expectEqual(test_deadline_ms, sent.deadline_ms);
    try std.testing.expectEqualStrings(text, sent.text);

    const cwd = try std.testing.allocator.alloc(u8, max_new_window_arg_len);
    defer std.testing.allocator.free(cwd);
    @memset(cwd, 'x');
    const tab = try encodeNewTabRequest(
        std.testing.allocator,
        .{ .window_id = std.math.maxInt(u32) },
        cwd,
        test_deadline_ms,
    );
    defer std.testing.allocator.free(tab);
    try writeAutomationBytes(&file, tab);
    try std.testing.expectEqual(RequestKind.new_tab_timed, try decodeRequestKind(file.handle));
    var tab_payload = try decodeNewTabPayload(std.testing.allocator, file.handle, true);
    defer tab_payload.deinit(std.testing.allocator);
    try std.testing.expectEqual(test_deadline_ms, tab_payload.deadline_ms);
    try std.testing.expectEqual(apprt.ipc.AutomationTarget{ .window_id = std.math.maxInt(u32) }, tab_payload.target);
    try std.testing.expectEqual(@as(usize, max_new_window_arg_len), tab_payload.working_directory.?.len);

    const split = try encodeNewSplitRequest(
        std.testing.allocator,
        .{ .surface_id = 42 },
        .down,
        "C:\\x",
        test_deadline_ms,
    );
    defer std.testing.allocator.free(split);
    try writeAutomationBytes(&file, split);
    try std.testing.expectEqual(RequestKind.new_split_timed, try decodeRequestKind(file.handle));
    var split_payload = try decodeNewSplitPayload(std.testing.allocator, file.handle, true);
    defer split_payload.deinit(std.testing.allocator);
    try std.testing.expectEqual(test_deadline_ms, split_payload.deadline_ms);
    try std.testing.expectEqual(apprt.ipc.AutomationTarget{ .surface_id = 42 }, split_payload.target);
    try std.testing.expectEqual(apprt.ipc.AutomationSplitDirection.down, split_payload.direction);
    try std.testing.expectEqualStrings("C:\\x", split_payload.working_directory.?);

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

test "win32 automation malformed codecs free allocations" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(apprt.ipc.AutomationTarget.focused, try decodeAutomationTarget(&automationTargetBytes(0, 0)));
    try std.testing.expectEqual(apprt.ipc.AutomationTarget{ .surface_id = 42 }, try decodeAutomationTarget(&automationTargetBytes(1, 42)));
    try std.testing.expectEqual(apprt.ipc.AutomationTarget{ .window_id = 17 }, try decodeAutomationTarget(&automationTargetBytes(2, 17)));
    for ([_][9]u8{ automationTargetBytes(0, 1), automationTargetBytes(1, 0), automationTargetBytes(2, 0), automationTargetBytes(2, @as(u64, std.math.maxInt(u32)) + 1), automationTargetBytes(3, 1) }) |encoded| {
        try std.testing.expectError(error.InvalidAutomationTarget, decodeAutomationTarget(&encoded));
    }
    try std.testing.expectError(error.InvalidAutomationTarget, encodeFocusRequest(alloc, .{ .surface_id = 0 }, test_deadline_ms));
    try std.testing.expectError(error.InvalidAutomationTarget, encodeFocusRequest(alloc, .{ .window_id = 0 }, test_deadline_ms));
    try std.testing.expectError(error.InvalidAutomationTarget, encodeNewTabRequest(alloc, .{ .surface_id = 1 }, null, test_deadline_ms));
    try std.testing.expectError(error.InvalidAutomationTarget, encodeNewSplitRequest(alloc, .{ .window_id = 1 }, .right, null, test_deadline_ms));
    for ([_][]const u8{ "", &.{0xFF}, "x\x00y" }) |value| {
        try std.testing.expectError(error.InvalidAutomationText, encodeSendTextRequest(alloc, .{ .surface_id = 1 }, value, test_deadline_ms));
        try std.testing.expectError(error.InvalidAutomationWorkingDirectory, encodeNewTabRequest(alloc, .focused, value, test_deadline_ms));
    }
    const oversized = try alloc.alloc(u8, max_new_window_arg_len + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.InvalidAutomationText, encodeSendTextRequest(alloc, .{ .surface_id = 1 }, oversized[0 .. max_action_text_len + 1], test_deadline_ms));
    try std.testing.expectError(error.InvalidAutomationWorkingDirectory, encodeNewTabRequest(alloc, .focused, oversized, test_deadline_ms));

    const max_send = try encodeSendTextRequest(alloc, .{ .surface_id = 42 }, oversized[0..max_action_text_len], test_deadline_ms);
    defer alloc.free(max_send);
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("automation-invalid.bin", .{ .read = true });
    defer file.close();
    try writeAutomationBytes(&file, max_send);
    _ = try decodeRequestKind(file.handle);
    var max_payload = try decodeSendTextPayload(alloc, file.handle, true);
    defer max_payload.deinit(alloc);
    try std.testing.expectEqual(@as(usize, max_action_text_len), max_payload.text.len);

    const surface = automationTargetBytes(1, 42);
    const window = automationTargetBytes(2, 42);
    const bad_cases = [_]struct { len: u32, body: []const u8, expected: anyerror }{
        .{ .len = 0, .body = "", .expected = error.InvalidAutomationText },
        .{ .len = max_action_text_len + 1, .body = "", .expected = error.InvalidAutomationText },
        .{ .len = 1, .body = &.{0xFF}, .expected = error.InvalidAutomationText },
        .{ .len = 3, .body = "x\x00y", .expected = error.InvalidAutomationText },
        .{ .len = 3, .body = "x", .expected = error.EndOfStream },
    };
    for (bad_cases) |case| {
        try writeAutomationSizedPayload(&file, surface, "", case.len, case.body);
        try std.testing.expectError(case.expected, decodeSendTextPayload(alloc, file.handle, true));
    }
    try writeAutomationSizedPayload(&file, surface, "", 0, "");
    try std.testing.expectError(error.InvalidAutomationTarget, decodeNewTabPayload(alloc, file.handle, true));
    try writeAutomationSizedPayload(&file, surface, &.{0}, 0, "");
    try std.testing.expectError(error.InvalidAutomationDirection, decodeNewSplitPayload(alloc, file.handle, true));
    for ([_]struct { len: u32, body: []const u8, expected: anyerror }{
        .{ .len = 1, .body = &.{0xFF}, .expected = error.InvalidAutomationWorkingDirectory },
        .{ .len = 3, .body = "x\x00y", .expected = error.InvalidAutomationWorkingDirectory },
        .{ .len = max_new_window_arg_len + 1, .body = "", .expected = error.InvalidAutomationWorkingDirectory },
        .{ .len = 3, .body = "x", .expected = error.EndOfStream },
    }) |case| {
        try writeAutomationSizedPayload(&file, window, "", case.len, case.body);
        try std.testing.expectError(case.expected, decodeNewTabPayload(alloc, file.handle, true));
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
    var server_open = true;
    defer {
        if (server_open) _ = windows.CloseHandle(server);
    }

    try std.testing.expectEqual(@as(BOOL, 0), sys.ConnectNamedPipe(server, null));
    try std.testing.expectEqual(windows.Win32Error.PIPE_LISTENING, windows.kernel32.GetLastError());

    const client = windows.kernel32.CreateFileW(
        pipe_name.ptr,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        client_pipe_open_flags,
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

    try writeAll(client, "x");
    try readExactWithTimeout(server, &byte, 0);
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);

    const DelayedWriter = struct {
        fn run(pipe: windows.HANDLE) void {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            writeAll(pipe, "y") catch unreachable;
        }
    };
    const writer = try std.Thread.spawn(.{}, DelayedWriter.run, .{server});
    errdefer writer.join();
    try readExactWithTimeout(client, &byte, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u8, 'y'), byte[0]);
    writer.join();

    _ = windows.CloseHandle(server);
    server_open = false;
    try std.testing.expectError(
        error.EndOfStream,
        readExactWithTimeout(client, &byte, std.math.maxInt(u64)),
    );
}

test "win32 IPC pipe claims only the first instance" {
    try std.testing.expect(isIpcPipeClaimConflict(.ACCESS_DENIED));
    try std.testing.expect(isIpcPipeClaimConflict(.PIPE_BUSY));
    try std.testing.expect(!isIpcPipeClaimConflict(.INVALID_PARAMETER));
    try std.testing.expectEqual(
        @as(windows.DWORD, 0x00110080),
        client_pipe_open_flags,
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

test "win32 IPC deadline patching stays codec-owned" {
    const request = try encodeFocusRequest(std.testing.allocator, .focused, 0);
    defer std.testing.allocator.free(request);

    try setAutomationRequestDeadline(request, test_deadline_ms);
    try std.testing.expectEqual(test_deadline_ms, readU64(request[5..13]));
    try std.testing.expectError(
        error.InvalidIpcRequest,
        setAutomationRequestDeadline(request[0..12], test_deadline_ms),
    );
}

test "win32 launch-layout IPC encode decode round trip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const request = try encodeLaunchLayoutRequest(
        std.testing.allocator,
        "Project Alpha",
        test_deadline_ms,
    );
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

    try std.testing.expectEqual(RequestKind.launch_layout_timed, try decodeRequestKind(file.handle));
    const decoded = try decodeLaunchLayoutPayload(std.testing.allocator, file.handle, true);
    defer std.testing.allocator.free(decoded.name);
    try std.testing.expectEqual(test_deadline_ms, decoded.deadline_ms);
    try std.testing.expectEqualStrings("Project Alpha", decoded.name);
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
        encodeLaunchLayoutRequest(std.testing.allocator, name, test_deadline_ms),
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

        var deadline_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &deadline_buf, test_deadline_ms, .little);
        try file.writeAll(&deadline_buf);
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(name.len), .little);
        try file.writeAll(&len_buf);
        try file.writeAll(name);
        try file.seekTo(0);
        try std.testing.expectError(
            error.InvalidAutomationAction,
            decodeLaunchLayoutPayload(std.testing.allocator, file.handle, true),
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

    var deadline_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &deadline_buf, test_deadline_ms, .little);
    try file.writeAll(&deadline_buf);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, 4, .little);
    try file.writeAll(&len_buf);
    try file.writeAll("ab");
    try file.seekTo(0);
    try std.testing.expectError(
        error.EndOfStream,
        decodeLaunchLayoutPayload(std.testing.allocator, file.handle, true),
    );
}

test "win32 encodeListWindowsRequest carries the response deadline" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const request = try encodeListWindowsRequest(std.testing.allocator, test_deadline_ms);
    defer std.testing.allocator.free(request);

    try std.testing.expectEqual(@as(usize, 13), request.len);
    try std.testing.expectEqual(wire_version, readU32(request[0..4]));
    try std.testing.expectEqual(@intFromEnum(RequestKind.list_windows_timed), request[4]);
    try std.testing.expectEqual(test_deadline_ms, readU64(request[5..13]));
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

/// A seekable file standing in for the pipe handle the wire decoders read
/// from. The decoders take a `windows.HANDLE` and never seek, so a temp file
/// exercises the same `readExactUntil` path without a live named pipe, and
/// one file is reused across a whole campaign instead of one per iteration.
const FuzzTransport = struct {
    file: std.fs.File,

    fn load(self: *FuzzTransport, bytes: []const u8) !void {
        try self.file.seekTo(0);
        try self.file.setEndPos(0);
        try self.file.writeAll(bytes);
        try self.file.seekTo(0);
    }

    /// Overwrite the transport with filler so any decoded value that still
    /// aliased the read buffer shows up as a re-encode mismatch.
    fn scrub(self: *FuzzTransport, len: usize) !void {
        var filler: [256]u8 = undefined;
        @memset(&filler, 0xA5);
        try self.file.seekTo(0);
        try self.file.setEndPos(0);
        var remaining = len;
        while (remaining > 0) {
            const chunk = @min(remaining, filler.len);
            try self.file.writeAll(filler[0..chunk]);
            remaining -= chunk;
        }
        try self.file.seekTo(0);
    }
};

fn expectArgumentsEqual(
    expected: ?[]const [:0]const u8,
    actual: ?[]const [:0]const u8,
) !void {
    if (expected == null or actual == null) {
        return std.testing.expect(expected == null and actual == null);
    }

    try std.testing.expectEqual(expected.?.len, actual.?.len);
    for (expected.?, actual.?) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
}

fn fuzzDecodeNewWindowPayload(transport: *FuzzTransport, input: []const u8) !void {
    const max_input_len: usize = @as(usize, max_new_window_args_bytes) +
        (@as(usize, max_new_window_argc) + 1) * @sizeOf(u32);
    if (input.len > max_input_len) return;

    try transport.load(input);
    const arguments = decodeNewWindowPayload(
        std.testing.allocator,
        transport.file.handle,
    ) catch |err| switch (err) {
        error.EndOfStream, error.InvalidIpcRequest, error.IpcTimeout => return,
        else => return err,
    };
    defer freeOwnedArguments(std.testing.allocator, arguments);

    const encoded_before = try encodeNewWindowRequest(
        std.testing.allocator,
        arguments,
    );
    defer std.testing.allocator.free(encoded_before);

    try transport.scrub(input.len);
    const encoded_after = try encodeNewWindowRequest(
        std.testing.allocator,
        arguments,
    );
    defer std.testing.allocator.free(encoded_after);
    try std.testing.expectEqualSlices(u8, encoded_before, encoded_after);

    try transport.load(encoded_before[5..]);
    const round_trip = try decodeNewWindowPayload(
        std.testing.allocator,
        transport.file.handle,
    );
    defer freeOwnedArguments(std.testing.allocator, round_trip);
    try expectArgumentsEqual(arguments, round_trip);
}

const new_window_fuzz_corpus = [_][]const u8{
    "\x00\x00\x00\x00",
    "\x01\x00\x00\x00\x03\x00\x00\x00cmd",
    "\x02\x00\x00\x00\x01\x00\x00\x00x\x01\x00\x00\x00y",
    "\x01",
    "\x01\x10\x00\x00",
};

test "win32 IPC new-window decoder rejects every truncated payload" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("ipc-fuzz-new-window-truncated.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();
    var transport: FuzzTransport = .{ .file = file };

    const payload = "\x01\x00\x00\x00\x03\x00\x00\x00cmd";
    for (0..payload.len) |len| {
        try transport.load(payload[0..len]);
        try std.testing.expectError(
            error.EndOfStream,
            decodeNewWindowPayload(std.testing.allocator, transport.file.handle),
        );
    }
}

test "fuzz win32 IPC new-window payload decoder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("ipc-fuzz-new-window.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();
    var transport: FuzzTransport = .{ .file = file };

    try std.testing.fuzz(&transport, fuzzDecodeNewWindowPayload, .{
        .corpus = &new_window_fuzz_corpus,
    });
}

test "bounded fuzz campaign win32 IPC new-window payload decoder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("ipc-bounded-fuzz-new-window.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();
    var transport: FuzzTransport = .{ .file = file };

    const bounded_fuzz = @import("../testing/bounded_fuzz.zig");
    try bounded_fuzz.run(&transport, fuzzDecodeNewWindowPayload, .{
        .iterations = 256,
        .random_seed = 0x6C21_C45E_83B7_2D91,
        .corpus = &.{
            "\x00\x00\x00\x00",
            "\x01\x00\x00\x00\x03\x00\x00\x00cmd",
            "\x02\x00\x00\x00\x01\x00\x00\x00x\x01\x00\x00\x00y",
            "\x01",
        },
    });
}

fn fuzzDecodePerformActionPayload(transport: *FuzzTransport, input: []const u8) !void {
    const max_input_len: usize = 13 + @as(usize, max_action_text_len);
    if (input.len > max_input_len) return;

    try transport.load(input);
    const payload = decodePerformActionPayload(
        std.testing.allocator,
        transport.file.handle,
        false,
    ) catch |err| switch (err) {
        error.EndOfStream,
        error.InvalidIpcRequest,
        error.InvalidAutomationAction,
        error.IpcTimeout,
        => return,
        else => return err,
    };
    defer std.testing.allocator.free(payload.action_text);

    const encoded_before = try encodePerformActionRequest(
        std.testing.allocator,
        payload.target,
        payload.action_text,
        test_deadline_ms,
    );
    defer std.testing.allocator.free(encoded_before);

    try transport.scrub(input.len);
    const encoded_after = try encodePerformActionRequest(
        std.testing.allocator,
        payload.target,
        payload.action_text,
        test_deadline_ms,
    );
    defer std.testing.allocator.free(encoded_after);
    try std.testing.expectEqualSlices(u8, encoded_before, encoded_after);

    try transport.load(encoded_before[5..]);
    const round_trip = try decodePerformActionPayload(
        std.testing.allocator,
        transport.file.handle,
        true,
    );
    defer std.testing.allocator.free(round_trip.action_text);
    try std.testing.expectEqual(test_deadline_ms, round_trip.deadline_ms);
    try std.testing.expect(std.meta.eql(payload.target, round_trip.target));
    try std.testing.expectEqualSlices(
        u8,
        payload.action_text,
        round_trip.action_text,
    );
}

test "win32 IPC perform-action decoder rejects every truncated payload" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("ipc-fuzz-perform-action-truncated.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();
    var transport: FuzzTransport = .{ .file = file };

    const payload =
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x07\x00\x00\x00new_tab";
    for (0..payload.len) |len| {
        try transport.load(payload[0..len]);
        try std.testing.expectError(
            error.EndOfStream,
            decodePerformActionPayload(
                std.testing.allocator,
                transport.file.handle,
                false,
            ),
        );
    }
}

test "fuzz win32 IPC perform-action payload decoder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("ipc-fuzz-perform-action.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();
    var transport: FuzzTransport = .{ .file = file };

    try std.testing.fuzz(&transport, fuzzDecodePerformActionPayload, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x07\x00\x00\x00new_tab",
        "\x01\x2A\x00\x00\x00\x00\x00\x00\x00" ++
            "\x07\x00\x00\x00new_tab",
        "\x00",
        "\x02\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x07\x00\x00\x00new_tab",
        "\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
            "\x00\x00\x00\x00",
    } });
}

test "bounded fuzz campaign win32 IPC perform-action payload decoder" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("ipc-bounded-fuzz-perform-action.bin", .{
        .read = true,
        .truncate = true,
    });
    defer file.close();
    var transport: FuzzTransport = .{ .file = file };

    const bounded_fuzz = @import("../testing/bounded_fuzz.zig");
    try bounded_fuzz.run(&transport, fuzzDecodePerformActionPayload, .{
        .iterations = 256,
        .random_seed = 0xBC18_5FE2_43D7_096A,
        .corpus = &.{
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
                "\x07\x00\x00\x00new_tab",
            "\x01\x2A\x00\x00\x00\x00\x00\x00\x00" ++
                "\x07\x00\x00\x00new_tab",
            "\x00",
        },
    });
}
