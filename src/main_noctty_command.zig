//! Console entrypoint. Keep the application in noctty.exe; this binary only
//! chooses whether to wait and forwards the original Windows command line.
const std = @import("std");
const win32_sys = @import("apprt/win32/sys.zig");
const win32_types = @import("apprt/win32_types.zig");
const w = std.os.windows;
const k = w.kernel32;
const cli_action = @import("cli/action.zig");
const Action = @import("cli/ghostty_action.zig").Action;
const jobs = @import("apprt/win32_job_object.zig");
const os_windows = @import("os/windows.zig");
const windows_ext = @import("os/windows_ext.zig");

pub const panic = std.debug.no_panic;

/// This launcher has no global state: its file and process calls run on the
/// calling thread.
inline fn launcherIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn main(init: std.process.Init.Minimal) void {
    const code = forward(init.args) catch |err| {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stderr().writer(launcherIo(), &buffer);
        writer.interface.print("noctty command launcher could not start or wait for noctty.exe: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        win32_sys.ExitProcess(1);
    };
    win32_sys.ExitProcess(code);
}

fn forward(args: std.process.Args) !u32 {
    const alloc = std.heap.page_allocator;
    // Detection errors are actions too: noctty.exe owns their diagnostics.
    const wait = if (cli_action.detectArgs(Action, alloc, args)) |action| action != null else |_| true;
    // executablePath resolves symlinks, preserving the old launcher's sibling rule.
    const self_path = try std.process.executablePathAlloc(launcherIo(), alloc);
    defer alloc.free(self_path);
    const image_path = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(self_path) orelse return error.ExecutablePathUnavailable, "noctty.exe" });
    defer alloc.free(image_path);
    const image_z = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, image_path);
    defer alloc.free(image_z);

    // lpApplicationName selects the sibling independently of argv[0]. Do not
    // parse/requote this buffer: doubled quotes have different CRT and
    // CommandLineToArgvW interpretations. CreateProcessW needs writable memory.
    const command_line = std.mem.span(GetCommandLineW());
    // CreateProcess permits an empty line; supply argv[0] only in that case.
    const raw = if (std.mem.trim(u16, command_line, &.{ ' ', '\t' }).len == 0) raw: {
        const value = try alloc.allocSentinel(u16, image_z.len + 2, 0);
        value[0] = '"';
        @memcpy(value[1..][0..image_z.len], image_z);
        value[value.len - 1] = '"';
        break :raw value;
    } else try alloc.dupeSentinel(u16, command_line, 0);
    defer alloc.free(raw);
    var parent: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    GetStartupInfoW(&parent);
    var startup: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    startup.cb = @sizeOf(w.STARTUPINFOW);
    startup.lpDesktop = parent.lpDesktop;
    const handles = if (wait) [3]?w.HANDLE{
        try inheritableStdHandle(win32_types.STD_INPUT_HANDLE),
        try inheritableStdHandle(win32_types.STD_OUTPUT_HANDLE),
        try inheritableStdHandle(win32_types.STD_ERROR_HANDLE),
    } else [3]?w.HANDLE{ null, null, null };
    defer for (handles) |handle| {
        if (handle) |h| if (h != w.INVALID_HANDLE_VALUE) w.CloseHandle(h);
    };
    if (wait) {
        startup.dwFlags = w.STARTF_USESTDHANDLES | w.STARTF_FORCEOFFFEEDBACK;
        startup.hStdInput = handles[0];
        startup.hStdOutput = handles[1];
        startup.hStdError = handles[2];
        // A real handler is not inherited; the NULL-handler ignore attribute
        // is. Keep receiving the child's full exit status after Ctrl+C/Break.
        if (win32_sys.SetConsoleCtrlHandler(ignoreControl, win32_types.TRUE) == 0) return error.ConsoleHandlerFailed;
    }
    // Keep an action's lifetime tied to the wrapper, as with the old in-process
    // dispatch. Editors or GUI processes the action launches may outlive it.
    const job = if (wait) actionJob() catch null else null;
    defer if (job) |handle| w.CloseHandle(handle);
    var process: os_windows.PROCESS_INFORMATION = undefined;
    if (windows_ext.CreateProcessW(image_z, raw, null, null, @intFromBool(wait), .{ .detached_process = !wait, .create_suspended = wait }, null, null, &startup, &process) == 0)
        return switch (std.os.windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .BAD_EXE_FORMAT => error.InvalidExecutable,
            else => error.CreateProcessFailed,
        };
    defer w.CloseHandle(process.hProcess);
    defer w.CloseHandle(process.hThread);
    errdefer {
        _ = win32_sys.TerminateProcess(process.hProcess, 1);
        _ = win32_sys.WaitForSingleObject(process.hProcess, win32_types.INFINITE);
    }
    if (!wait) return 0;
    // Some caller-owned jobs cannot nest (notably with UI restrictions).
    // Preserve CLI availability there; lifetime cleanup is best effort.
    if (job) |handle| _ = jobs.AssignProcessToJobObject(handle, process.hProcess);
    if (ResumeThread(process.hThread) == 0xFFFFFFFF) return error.ResumeFailed;
    if (win32_sys.WaitForSingleObject(process.hProcess, win32_types.INFINITE) != win32_types.WAIT_OBJECT_0) return error.WaitFailed;
    var code: u32 = undefined;
    if (win32_sys.GetExitCodeProcess(process.hProcess, &code) == 0) return error.ExitCodeUnavailable;
    return code;
}

fn inheritableStdHandle(id: w.DWORD) !?w.HANDLE {
    const handle = win32_sys.GetStdHandle(id);
    if (handle == null or handle == w.INVALID_HANDLE_VALUE) return handle;
    var copy: w.HANDLE = undefined;
    if (win32_sys.DuplicateHandle(w.GetCurrentProcess(), handle.?, w.GetCurrentProcess(), &copy, 0, win32_types.TRUE, w.DUPLICATE_SAME_ACCESS) == 0) {
        if (std.os.windows.GetLastError() == .INVALID_HANDLE) return null;
        return error.StandardHandleUnavailable;
    }
    return copy;
}

fn actionJob() !w.HANDLE {
    const job = jobs.CreateJobObjectW(null, null) orelse return error.ActionJobFailed;
    errdefer w.CloseHandle(job);
    var limits: jobs.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    limits.BasicLimitInformation.LimitFlags = jobs.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | 0x1000; // SILENT_BREAKAWAY_OK
    if (jobs.SetInformationJobObject(job, .extended_limit_information, &limits, @sizeOf(@TypeOf(limits))) == 0) return error.ActionJobFailed;
    return job;
}

fn ignoreControl(kind: w.DWORD) callconv(.winapi) win32_types.BOOL {
    return @intFromBool(kind == 0 or kind == 1); // CTRL_C_EVENT / CTRL_BREAK_EVENT
}

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn GetStartupInfoW(*w.STARTUPINFOW) callconv(.winapi) void;
extern "kernel32" fn ResumeThread(w.HANDLE) callconv(.winapi) w.DWORD;
