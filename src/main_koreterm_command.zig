//! Console entrypoint. Keep the application in koreterm.exe; this binary only
//! chooses whether to wait and forwards the original Windows command line.
const std = @import("std");
const w = std.os.windows;
const k = w.kernel32;
const cli_action = @import("cli/action.zig");
const Action = @import("cli/ghostty_action.zig").Action;
const jobs = @import("apprt/win32_job_object.zig");

pub const panic = std.debug.no_panic;

pub fn main() void {
    const code = forward() catch |err| {
        var buffer: [256]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buffer);
        writer.interface.print("koreterm command launcher could not start or wait for koreterm.exe: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        k.ExitProcess(1);
    };
    k.ExitProcess(code);
}

fn forward() !u32 {
    const alloc = std.heap.page_allocator;
    // Detection errors are actions too: koreterm.exe owns their diagnostics.
    const wait = if (cli_action.detectArgs(Action, alloc)) |action| action != null else |_| true;
    // selfExePath resolves symlinks, preserving the old launcher's sibling rule.
    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);
    const image_path = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(self_path) orelse return error.ExecutablePathUnavailable, "koreterm.exe" });
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
    } else try alloc.dupeZ(u16, command_line);
    defer alloc.free(raw);
    var parent: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    GetStartupInfoW(&parent);
    var startup: w.STARTUPINFOW = std.mem.zeroes(w.STARTUPINFOW);
    startup.cb = @sizeOf(w.STARTUPINFOW);
    startup.lpDesktop = parent.lpDesktop;
    const handles = if (wait) [3]?w.HANDLE{
        try inheritableStdHandle(w.STD_INPUT_HANDLE),
        try inheritableStdHandle(w.STD_OUTPUT_HANDLE),
        try inheritableStdHandle(w.STD_ERROR_HANDLE),
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
        if (k.SetConsoleCtrlHandler(ignoreControl, w.TRUE) == 0) return error.ConsoleHandlerFailed;
    }
    // Keep an action's lifetime tied to the wrapper, as with the old in-process
    // dispatch. Editors or GUI processes the action launches may outlive it.
    const job = if (wait) actionJob() catch null else null;
    defer if (job) |handle| w.CloseHandle(handle);
    var process: w.PROCESS_INFORMATION = undefined;
    if (k.CreateProcessW(image_z, raw, null, null, @intFromBool(wait), .{ .detached_process = !wait, .create_suspended = wait }, null, null, &startup, &process) == 0)
        return switch (k.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .BAD_EXE_FORMAT => error.InvalidExecutable,
            else => error.CreateProcessFailed,
        };
    defer w.CloseHandle(process.hProcess);
    defer w.CloseHandle(process.hThread);
    errdefer {
        _ = k.TerminateProcess(process.hProcess, 1);
        _ = k.WaitForSingleObject(process.hProcess, w.INFINITE);
    }
    if (!wait) return 0;
    // Some caller-owned jobs cannot nest (notably with UI restrictions).
    // Preserve CLI availability there; lifetime cleanup is best effort.
    if (job) |handle| _ = jobs.AssignProcessToJobObject(handle, process.hProcess);
    if (ResumeThread(process.hThread) == 0xFFFFFFFF) return error.ResumeFailed;
    if (k.WaitForSingleObject(process.hProcess, w.INFINITE) != w.WAIT_OBJECT_0) return error.WaitFailed;
    var code: u32 = undefined;
    if (k.GetExitCodeProcess(process.hProcess, &code) == 0) return error.ExitCodeUnavailable;
    return code;
}

fn inheritableStdHandle(id: w.DWORD) !?w.HANDLE {
    const handle = k.GetStdHandle(id);
    if (handle == null or handle == w.INVALID_HANDLE_VALUE) return handle;
    var copy: w.HANDLE = undefined;
    if (k.DuplicateHandle(w.GetCurrentProcess(), handle.?, w.GetCurrentProcess(), &copy, 0, w.TRUE, w.DUPLICATE_SAME_ACCESS) == 0) {
        if (k.GetLastError() == .INVALID_HANDLE) return null;
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

fn ignoreControl(kind: w.DWORD) callconv(.winapi) w.BOOL {
    return @intFromBool(kind == 0 or kind == 1); // CTRL_C_EVENT / CTRL_BREAK_EVENT
}

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "kernel32" fn GetStartupInfoW(*w.STARTUPINFOW) callconv(.winapi) void;
extern "kernel32" fn ResumeThread(w.HANDLE) callconv(.winapi) w.DWORD;
