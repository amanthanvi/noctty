const std = @import("std");
const configpkg = @import("../config.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;

pub const title_prefix = "Administrator: ";

const token_query: windows.DWORD = 0x0008;
const process_query_limited_information: windows.DWORD = 0x1000;
const token_user_class: c_int = 1;
const token_elevation_class: c_int = 20;
const sw_show_normal: c_int = 1;
const see_mask_flag_no_ui: windows.ULONG = 0x00000400;
const sddl_revision_1: windows.DWORD = 1;
const file_flag_first_pipe_instance: windows.DWORD = 0x00080000;

const TokenElevation = extern struct {
    token_is_elevated: windows.DWORD,
};

const SidAndAttributes = extern struct {
    sid: *anyopaque,
    attributes: windows.DWORD,
};

const TokenUser = extern struct {
    user: SidAndAttributes,
};

/// LocalAlloc-owned security descriptor and the attributes passed to
/// CreateNamedPipeW. The descriptor remains valid for every pipe instance
/// created by the elevated server thread.
pub const ElevatedPipeSecurity = struct {
    descriptor: *anyopaque,
    attributes: windows.SECURITY_ATTRIBUTES,

    pub fn deinit(self: *ElevatedPipeSecurity) void {
        _ = LocalFree(self.descriptor);
        self.* = undefined;
    }

    pub fn securityAttributes(self: *ElevatedPipeSecurity) *windows.SECURITY_ATTRIBUTES {
        return &self.attributes;
    }
};

const ShellExecuteInfoW = extern struct {
    cb_size: windows.DWORD,
    mask: windows.ULONG,
    hwnd: ?windows.HWND,
    verb: ?windows.LPCWSTR,
    file: ?windows.LPCWSTR,
    parameters: ?windows.LPCWSTR,
    directory: ?windows.LPCWSTR,
    show: c_int,
    instance: ?windows.HINSTANCE,
    id_list: ?*anyopaque,
    class: ?windows.LPCWSTR,
    class_key: ?windows.HKEY,
    hot_key: windows.DWORD,
    icon_or_monitor: ?*anyopaque,
    process: ?windows.HANDLE,
};

const ElevationCache = union(enum) {
    unknown,
    value: bool,
    failure: anyerror,
};

var elevation_cache: ElevationCache = .unknown;
var elevation_cache_mutex: std.Thread.Mutex = .{};

/// Return whether the current process token is elevated.
///
/// A successful result or query failure is cached for the process lifetime so
/// callers on static CLI paths do not repeatedly open and inspect the token.
pub fn isProcessElevated() !bool {
    elevation_cache_mutex.lock();
    defer elevation_cache_mutex.unlock();

    switch (elevation_cache) {
        .unknown => {},
        .value => |value| return value,
        .failure => |err| return err,
    }

    const value = queryProcessElevated() catch |err| {
        elevation_cache = .{ .failure = err };
        return err;
    };
    elevation_cache = .{ .value = value };
    return value;
}

fn queryProcessElevated() !bool {
    const token_handle = try openProcessToken(windows.GetCurrentProcess());
    defer _ = windows.CloseHandle(token_handle);

    return try tokenIsElevated(token_handle);
}

fn openProcessToken(process: windows.HANDLE) !windows.HANDLE {
    var token: ?windows.HANDLE = null;
    if (OpenProcessToken(process, token_query, &token) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    return token orelse error.Unexpected;
}

fn tokenIsElevated(token: windows.HANDLE) !bool {
    var elevation: TokenElevation = .{ .token_is_elevated = 0 };
    var returned_size: windows.DWORD = 0;
    if (GetTokenInformation(
        token,
        token_elevation_class,
        &elevation,
        @sizeOf(TokenElevation),
        &returned_size,
    ) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    if (returned_size < @sizeOf(TokenElevation)) return error.Unexpected;
    return elevation.token_is_elevated != 0;
}

fn allocTokenUser(
    alloc: Allocator,
    token: windows.HANDLE,
) ![]align(@alignOf(TokenUser)) u8 {
    var required_size: windows.DWORD = 0;
    if (GetTokenInformation(
        token,
        token_user_class,
        null,
        0,
        &required_size,
    ) != 0) return error.Unexpected;

    const size_error = windows.kernel32.GetLastError();
    if (size_error != .INSUFFICIENT_BUFFER) return windows.unexpectedError(size_error);
    if (required_size < @sizeOf(TokenUser)) return error.Unexpected;

    const bytes = try alloc.alignedAlloc(u8, .of(TokenUser), required_size);
    errdefer alloc.free(bytes);
    var returned_size: windows.DWORD = 0;
    if (GetTokenInformation(
        token,
        token_user_class,
        @ptrCast(bytes.ptr),
        @intCast(bytes.len),
        &returned_size,
    ) == 0) return windows.unexpectedError(windows.kernel32.GetLastError());
    if (returned_size < @sizeOf(TokenUser) or returned_size > bytes.len) {
        return error.Unexpected;
    }
    return bytes;
}

fn tokenUser(bytes: []align(@alignOf(TokenUser)) const u8) *const TokenUser {
    return @ptrCast(bytes.ptr);
}

fn allocCurrentUserSidString(alloc: Allocator) ![]u8 {
    const token = try openProcessToken(windows.GetCurrentProcess());
    defer _ = windows.CloseHandle(token);

    const user_bytes = try allocTokenUser(alloc, token);
    defer alloc.free(user_bytes);

    var sid_string_w: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(tokenUser(user_bytes).user.sid, &sid_string_w) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    const sid_w = sid_string_w orelse return error.Unexpected;
    defer _ = LocalFree(@ptrCast(sid_w));

    return try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(sid_w));
}

/// Build the elevated endpoint descriptor: only the current token user gets
/// access, and the high mandatory label rejects both read-up and write-up.
pub fn buildElevatedPipeSddl(alloc: Allocator, user_sid: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        alloc,
        "O:{s}D:P(A;;GA;;;{s})S:(ML;;NRNW;;;HI)",
        .{ user_sid, user_sid },
    );
}

pub fn initElevatedPipeSecurity(alloc: Allocator) !ElevatedPipeSecurity {
    const user_sid = try allocCurrentUserSidString(alloc);
    defer alloc.free(user_sid);
    const sddl = try buildElevatedPipeSddl(alloc, user_sid);
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

    const owned_descriptor = descriptor orelse return error.Unexpected;
    return .{
        .descriptor = owned_descriptor,
        .attributes = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = owned_descriptor,
            .bInheritHandle = windows.FALSE,
        },
    };
}

/// Authenticate the process at the server end of a connected elevated pipe.
/// The server must run elevated under the same token user SID as this process.
pub fn authenticateElevatedPipeServer(
    alloc: Allocator,
    pipe: windows.HANDLE,
) !bool {
    var server_process_id: windows.DWORD = 0;
    if (GetNamedPipeServerProcessId(pipe, &server_process_id) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    if (server_process_id == 0) return error.Unexpected;

    const server_process = OpenProcess(
        process_query_limited_information,
        windows.FALSE,
        server_process_id,
    ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
    defer _ = windows.CloseHandle(server_process);

    const current_token = try openProcessToken(windows.GetCurrentProcess());
    defer _ = windows.CloseHandle(current_token);
    const server_token = try openProcessToken(server_process);
    defer _ = windows.CloseHandle(server_token);

    if (!(try tokenIsElevated(server_token))) return false;

    const current_user_bytes = try allocTokenUser(alloc, current_token);
    defer alloc.free(current_user_bytes);
    const server_user_bytes = try allocTokenUser(alloc, server_token);
    defer alloc.free(server_user_bytes);

    return EqualSid(
        tokenUser(current_user_bytes).user.sid,
        tokenUser(server_user_bytes).user.sid,
    ) != 0;
}

pub fn ipcPipeOpenMode(base_mode: windows.DWORD, first_instance: bool) windows.DWORD {
    return base_mode | if (first_instance) file_flag_first_pipe_instance else 0;
}

pub fn isIpcPipeClaimConflict(err: windows.Win32Error) bool {
    return err == .ACCESS_DENIED or err == .PIPE_BUSY;
}

/// Allocate the effective window title, including the elevation marker when
/// needed. A missing title uses the same `noctty` fallback as the Win32 host.
pub fn allocPrefixedTitle(
    alloc: Allocator,
    title: ?[]const u8,
    elevated: bool,
) Allocator.Error![]u8 {
    const base = title orelse "noctty";
    if (!elevated or std.mem.startsWith(u8, base, title_prefix)) {
        return alloc.dupe(u8, base);
    }
    return std.mem.concat(alloc, u8, &.{ title_prefix, base });
}

/// Build the argument string for a new elevated process.
///
/// `argv` is the complete current argv, including argv[0]. Only explicit
/// config-file overrides are inherited; the effective class, invoking working
/// directory, and selected profile command are appended after them.
pub fn buildRelaunchParameters(
    alloc: Allocator,
    argv: []const []const u8,
    effective_class: ?[]const u8,
    cwd: []const u8,
    config_base_cwd: []const u8,
    command: ?configpkg.Command,
) ![:0]u8 {
    var result: std.Io.Writer.Allocating = .init(alloc);
    errdefer result.deinit();

    var i: usize = @min(argv.len, 1);
    while (i < argv.len) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--config-file")) {
            if (i + 1 < argv.len) {
                try appendConfigFileArgument(
                    &result,
                    argv[i + 1],
                    config_base_cwd,
                );
                i += 2;
                continue;
            }
        } else if (std.mem.startsWith(u8, arg, "--config-file=")) {
            try appendConfigFileArgument(
                &result,
                arg["--config-file=".len..],
                config_base_cwd,
            );
        }
        i += 1;
    }

    if (effective_class) |class| {
        try appendKeyValueArgument(&result, "--class=", class);
    }
    try appendKeyValueArgument(&result, "--working-directory=", cwd);

    if (command) |value| {
        var argument: std.Io.Writer.Allocating = .init(alloc);
        defer argument.deinit();
        try argument.writer.writeAll("--command=");
        try writeCommand(&argument.writer, value);
        try appendWindowsArgument(&result, argument.written());
    }

    return result.toOwnedSliceSentinel(0);
}

fn appendConfigFileArgument(
    result: *std.Io.Writer.Allocating,
    value: []const u8,
    base_cwd: []const u8,
) !void {
    const optional = value.len > 0 and value[0] == '?';
    const path = if (optional) value[1..] else value;
    if (path.len == 0 or std.fs.path.isAbsolute(path)) {
        return appendKeyValueArgument(result, "--config-file=", value);
    }

    const resolved = try std.fs.path.resolve(result.allocator, &.{ base_cwd, path });
    defer result.allocator.free(resolved);
    if (optional) {
        const marked = try std.fmt.allocPrint(result.allocator, "?{s}", .{resolved});
        defer result.allocator.free(marked);
        return appendKeyValueArgument(result, "--config-file=", marked);
    }
    return appendKeyValueArgument(result, "--config-file=", resolved);
}

fn appendKeyValueArgument(
    result: *std.Io.Writer.Allocating,
    key: []const u8,
    value: []const u8,
) !void {
    var argument: std.Io.Writer.Allocating = .init(result.allocator);
    defer argument.deinit();
    try argument.writer.writeAll(key);
    try argument.writer.writeAll(value);
    try appendWindowsArgument(result, argument.written());
}

fn writeCommand(writer: *std.Io.Writer, command: configpkg.Command) !void {
    switch (command) {
        .shell => |value| try writer.writeAll(value),
        .direct => |args| {
            try writer.writeAll("direct:");
            for (args, 0..) |arg, i| {
                if (i != 0) try writer.writeByte(' ');
                try configpkg.Command.writeDirectArg(writer, arg);
            }
        },
    }
}

fn appendWindowsArgument(
    result: *std.Io.Writer.Allocating,
    argument: []const u8,
) !void {
    if (result.written().len != 0) try result.writer.writeByte(' ');
    try writeWindowsArgument(&result.writer, argument);
}

/// Quote one complete argument according to CommandLineToArgvW parsing rules.
fn writeWindowsArgument(writer: *std.Io.Writer, argument: []const u8) !void {
    if (!windowsArgumentNeedsQuotes(argument)) return writer.writeAll(argument);

    try writer.writeByte('"');
    var backslashes: usize = 0;
    for (argument) |byte| switch (byte) {
        '\\' => backslashes += 1,
        '"' => {
            try writer.splatByteAll('\\', backslashes * 2 + 1);
            backslashes = 0;
            try writer.writeByte('"');
        },
        else => {
            try writer.splatByteAll('\\', backslashes);
            backslashes = 0;
            try writer.writeByte(byte);
        },
    };
    try writer.splatByteAll('\\', backslashes * 2);
    try writer.writeByte('"');
}

fn windowsArgumentNeedsQuotes(argument: []const u8) bool {
    if (argument.len == 0) return true;
    for (argument) |byte| switch (byte) {
        ' ', '\t', '\r', '\n', '"' => return true,
        else => {},
    };
    return false;
}

pub const LaunchResult = enum {
    launched,
    cancelled,
};

/// Relaunch the current executable with the Windows `runas` verb.
pub fn launchElevated(
    alloc: Allocator,
    parameters: [:0]const u8,
    cwd: []const u8,
) !LaunchResult {
    var exe_buffer: [windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const exe = try windows.GetModuleFileNameW(
        null,
        &exe_buffer,
        @intCast(exe_buffer.len),
    );
    const parameters_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, parameters);
    defer alloc.free(parameters_w);
    const cwd_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, cwd);
    defer alloc.free(cwd_w);

    var info: ShellExecuteInfoW = .{
        .cb_size = @sizeOf(ShellExecuteInfoW),
        .mask = see_mask_flag_no_ui,
        .hwnd = null,
        .verb = std.unicode.utf8ToUtf16LeStringLiteral("runas"),
        .file = exe.ptr,
        .parameters = parameters_w.ptr,
        .directory = cwd_w.ptr,
        .show = sw_show_normal,
        .instance = null,
        .id_list = null,
        .class = null,
        .class_key = null,
        .hot_key = 0,
        .icon_or_monitor = null,
        .process = null,
    };
    if (ShellExecuteExW(&info) != 0) return .launched;

    const err = windows.kernel32.GetLastError();
    if (err == .CANCELLED) return .cancelled;
    return windows.unexpectedError(err);
}

extern "advapi32" fn OpenProcessToken(
    process: windows.HANDLE,
    desired_access: windows.DWORD,
    token: *?windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn GetTokenInformation(
    token: windows.HANDLE,
    information_class: c_int,
    information: ?*anyopaque,
    information_size: windows.DWORD,
    return_size: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn ConvertSidToStringSidW(
    sid: *anyopaque,
    string_sid: *?[*:0]u16,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    string_security_descriptor: windows.LPCWSTR,
    string_sd_revision: windows.DWORD,
    security_descriptor: *?*anyopaque,
    security_descriptor_size: ?*windows.ULONG,
) callconv(.winapi) windows.BOOL;

extern "advapi32" fn EqualSid(
    sid1: *anyopaque,
    sid2: *anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetNamedPipeServerProcessId(
    pipe: windows.HANDLE,
    server_process_id: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn OpenProcess(
    desired_access: windows.DWORD,
    inherit_handle: windows.BOOL,
    process_id: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn LocalFree(
    memory: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;

extern "shell32" fn ShellExecuteExW(
    info: *ShellExecuteInfoW,
) callconv(.winapi) windows.BOOL;

test "elevation title prefix handles elevated non-elevated null and prefixed titles" {
    const testing = std.testing;

    const elevated = try allocPrefixedTitle(testing.allocator, "PowerShell", true);
    defer testing.allocator.free(elevated);
    try testing.expectEqualStrings("Administrator: PowerShell", elevated);

    const regular = try allocPrefixedTitle(testing.allocator, "PowerShell", false);
    defer testing.allocator.free(regular);
    try testing.expectEqualStrings("PowerShell", regular);

    const fallback = try allocPrefixedTitle(testing.allocator, null, true);
    defer testing.allocator.free(fallback);
    try testing.expectEqualStrings("Administrator: noctty", fallback);

    const prefixed = try allocPrefixedTitle(
        testing.allocator,
        "Administrator: PowerShell",
        true,
    );
    defer testing.allocator.free(prefixed);
    try testing.expectEqualStrings("Administrator: PowerShell", prefixed);
}

test "elevation IPC pipe SDDL is owner-only at high integrity" {
    const sddl = try buildElevatedPipeSddl(
        std.testing.allocator,
        "S-1-5-21-111-222-333-1001",
    );
    defer std.testing.allocator.free(sddl);

    try std.testing.expectEqualStrings(
        "O:S-1-5-21-111-222-333-1001" ++
            "D:P(A;;GA;;;S-1-5-21-111-222-333-1001)" ++
            "S:(ML;;NRNW;;;HI)",
        sddl,
    );
}

test "elevation IPC pipe claims only the first instance" {
    const base_mode: windows.DWORD = 0x00000003;
    try std.testing.expectEqual(
        base_mode | file_flag_first_pipe_instance,
        ipcPipeOpenMode(base_mode, true),
    );
    try std.testing.expectEqual(base_mode, ipcPipeOpenMode(base_mode, false));
    try std.testing.expect(isIpcPipeClaimConflict(.ACCESS_DENIED));
    try std.testing.expect(isIpcPipeClaimConflict(.PIPE_BUSY));
    try std.testing.expect(!isIpcPipeClaimConflict(.INVALID_PARAMETER));
}

test "elevation relaunch parameters forward config class and cwd exactly" {
    const testing = std.testing;
    const argv = [_][]const u8{
        "C:\\noctty.exe",
        "--config-file",
        "C:\\configs\\one.conf",
        "--theme=Cobalt2",
        "--config-file=C:\\configs\\two words.conf",
        "--config-file",
        "relative.conf",
        "--config-file=?optional.conf",
        "--config-file=?C:\\configs\\optional absolute.conf",
        "-e",
        "cmd.exe",
        "--config-file=child-command.conf",
    };

    const parameters = try buildRelaunchParameters(
        testing.allocator,
        &argv,
        "work class",
        "C:\\Users\\Aman\\Source Dir",
        "C:\\startup",
        null,
    );
    defer testing.allocator.free(parameters);

    try testing.expectEqualStrings(
        "--config-file=C:\\configs\\one.conf " ++
            "\"--config-file=C:\\configs\\two words.conf\" " ++
            "--config-file=C:\\startup\\relative.conf " ++
            "--config-file=?C:\\startup\\optional.conf " ++
            "\"--config-file=?C:\\configs\\optional absolute.conf\" " ++
            "\"--class=work class\" " ++
            "\"--working-directory=C:\\Users\\Aman\\Source Dir\"",
        parameters,
    );
}

test "elevation relaunch parameters serialize and outer-quote direct command" {
    const testing = std.testing;
    const argv = [_][]const u8{"C:\\noctty.exe"};
    const direct_args = [_][:0]const u8{
        "pwsh.exe",
        "-NoLogo",
        "C:\\Program Files\\profile.ps1",
        "say \"hello\"",
    };
    const command: configpkg.Command = .{ .direct = &direct_args };

    const parameters = try buildRelaunchParameters(
        testing.allocator,
        &argv,
        null,
        "C:\\work",
        "C:\\startup",
        command,
    );
    defer testing.allocator.free(parameters);

    try testing.expectEqualStrings(
        \\--working-directory=C:\work "--command=direct:pwsh.exe -NoLogo \"C:\Program Files\profile.ps1\" \"say \\\"hello\\\"\""
    , parameters);
}

test "elevation relaunch parameters preserve shell command text" {
    const testing = std.testing;
    const argv = [_][]const u8{"C:\\noctty.exe"};
    const command: configpkg.Command = .{ .shell = "echo \"hello world\"" };

    const parameters = try buildRelaunchParameters(
        testing.allocator,
        &argv,
        null,
        "C:\\work",
        "C:\\startup",
        command,
    );
    defer testing.allocator.free(parameters);

    try testing.expectEqualStrings(
        \\--working-directory=C:\work "--command=echo \"hello world\""
    , parameters);
}
