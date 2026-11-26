//! Stand-in for noctty.exe in cli-com-forwarder.ps1: a windowless process that
//! records what the launcher gave it (desktop, station, startup flags, standard
//! handles, console, raw command line) to the file named by
//! NOCTTY_COM_FIXTURE_RECEIPT, then exits. Test knobs are environment variables:
//!   NOCTTY_COM_FIXTURE_EXIT     exit code (decimal u32, default 0)
//!   NOCTTY_COM_FIXTURE_HOLD_MS  sleep before exiting (default 3000)
//!   NOCTTY_COM_FIXTURE_STDIN    set: read all of stdin, report its length and SHA-256
//!   NOCTTY_COM_FIXTURE_OUT      set: write one line to stdout and one to stderr
const std = @import("std");
const w = std.os.windows;

// This fixture builds on its own (`zig build-exe`, no build graph), so it
// declares what it calls instead of importing the fork's declarations.
const std_input_handle: w.DWORD = std.math.maxInt(w.DWORD) - 10 + 1;
const std_output_handle: w.DWORD = std.math.maxInt(w.DWORD) - 11 + 1;
const std_error_handle: w.DWORD = std.math.maxInt(w.DWORD) - 12 + 1;
extern "kernel32" fn Sleep(dwMilliseconds: w.DWORD) callconv(.winapi) void;
extern "kernel32" fn ExitProcess(uExitCode: w.UINT) callconv(.winapi) noreturn;

pub const panic = std.debug.no_panic;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;
    const env = init.environ_map;
    const path = env.get("NOCTTY_COM_FIXTURE_RECEIPT") orelse return error.EnvironmentVariableNotFound;
    const exit_code = envU32(env, "NOCTTY_COM_FIXTURE_EXIT", 0);
    const hold_ms = envU32(env, "NOCTTY_COM_FIXTURE_HOLD_MS", 3000);

    var startup: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    startup.cb = @sizeOf(w.STARTUPINFOW);
    GetStartupInfoW(&startup);
    const stdin_kind = handleKind(std_input_handle);
    const stdout_kind = handleKind(std_output_handle);
    const stderr_kind = handleKind(std_error_handle);

    var stdin_bytes: u64 = 0;
    var digest: [32]u8 = undefined;
    if (env.contains("NOCTTY_COM_FIXTURE_STDIN")) {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [4096]u8 = undefined;
        const stdin = std.Io.File.stdin();
        while (true) {
            const n = stdin.readStreaming(io, &.{&buffer}) catch break;
            if (n == 0) break;
            hasher.update(buffer[0..n]);
            stdin_bytes += n;
        }
        hasher.final(&digest);
    } else digest = std.mem.zeroes([32]u8);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const hex_slice: []const u8 = hex[0..];

    if (env.contains("NOCTTY_COM_FIXTURE_OUT")) {
        if (isUsable(stdout_kind)) std.Io.File.stdout().writeStreamingAll(io, "fixture-out\n") catch {};
        if (isUsable(stderr_kind)) std.Io.File.stderr().writeStreamingAll(io, "fixture-err\n") catch {};
    }

    var name: [256]u16 = undefined;
    var needed: u32 = 0;
    if (GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), 2, &name, @sizeOf(@TypeOf(name)), &needed) == 0) return error.DesktopNameUnavailable;
    const desktop = try std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.sliceTo(&name, 0));
    defer alloc.free(desktop);
    var station_name: [256]u16 = undefined;
    if (GetUserObjectInformationW(GetProcessWindowStation(), 2, &station_name, @sizeOf(@TypeOf(station_name)), &needed) == 0) return error.StationNameUnavailable;
    const station = try std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.sliceTo(&station_name, 0));
    defer alloc.free(station);
    const raw = try std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.span(GetCommandLineW()));
    defer alloc.free(raw);

    var console_probe: [1]u32 = undefined;
    const json = try std.json.Stringify.valueAlloc(alloc, .{
        .desktop = desktop,
        .station = station,
        .pid = w.GetCurrentProcessId(),
        .command_line = raw,
        .startup_flags = startup.dwFlags,
        .show_window = startup.wShowWindow,
        .stdin = stdin_kind,
        .stdout = stdout_kind,
        .stderr = stderr_kind,
        .console = GetConsoleProcessList(&console_probe, 1) != 0,
        .stdin_bytes = stdin_bytes,
        .stdin_sha256 = hex_slice,
    }, .{});
    defer alloc.free(json);
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true });
    try file.writeStreamingAll(io, json);
    file.close(io);

    // Stay alive long enough for the harness to see that the launcher returned.
    if (hold_ms != 0) Sleep(hold_ms);
    ExitProcess(exit_code);
}

fn envU32(env: *const std.process.Environ.Map, name: []const u8, default: u32) u32 {
    const text = env.get(name) orelse return default;
    return std.fmt.parseInt(u32, text, 10) catch default;
}

fn handleKind(id: u32) []const u8 {
    const handle = GetStdHandle(id) orelse return "null";
    if (handle == w.INVALID_HANDLE_VALUE) return "invalid";
    return switch (GetFileType(handle)) {
        1 => "disk",
        2 => "char",
        3 => "pipe",
        else => "unknown",
    };
}

fn isUsable(kind: []const u8) bool {
    return !std.mem.eql(u8, kind, "null") and !std.mem.eql(u8, kind, "invalid");
}

extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn GetStartupInfoW(*w.STARTUPINFOW) callconv(.winapi) void;
extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn GetFileType(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetConsoleProcessList([*]u32, u32) callconv(.winapi) u32;
extern "user32" fn GetThreadDesktop(u32) callconv(.winapi) ?w.HANDLE;
extern "user32" fn GetProcessWindowStation() callconv(.winapi) ?w.HANDLE;
// A Win32 BOOL as the ABI has it (Zig 0.17's `std.os.windows.BOOL` is an enum).
extern "user32" fn GetUserObjectInformationW(?w.HANDLE, c_int, *anyopaque, u32, *u32) callconv(.winapi) c_int;
