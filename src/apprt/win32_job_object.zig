//! Minimal Windows Job Object ABI and config planning.
//!
//! This layer exposes the Win32 declarations plus a small planning surface used
//! by the Windows process launcher. Enforcement remains opt-in through the
//! retained linux-cgroup compatibility settings, and WSL launches are excluded
//! because limiting `wsl.exe` does not safely or predictably limit the Linux
//! process tree.

const std = @import("std");
const windows = std.os.windows;
const configpkg = @import("../config.zig");
const win32_types = @import("win32_types.zig");

pub const HANDLE = windows.HANDLE;
pub const DWORD = windows.DWORD;
pub const BOOL = windows.BOOL;
pub const SIZE_T = windows.SIZE_T;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const LPCWSTR = win32_types.LPCWSTR;
pub const ULONG_PTR = win32_types.UINT_PTR;
pub const KAFFINITY = ULONG_PTR;

pub const JOB_OBJECT_LIMIT_ACTIVE_PROCESS: DWORD = 0x00000008;
pub const JOB_OBJECT_LIMIT_JOB_MEMORY: DWORD = 0x00000200;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;

pub const JOBOBJECTINFOCLASS = enum(i32) {
    basic_limit_information = 2,
    basic_process_id_list = 3,
    extended_limit_information = 9,
    _,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: SIZE_T = 0,
    MaximumWorkingSetSize: SIZE_T = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: KAFFINITY = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: SIZE_T = 0,
    JobMemoryLimit: SIZE_T = 0,
    PeakProcessMemoryUsed: SIZE_T = 0,
    PeakJobMemoryUsed: SIZE_T = 0,
};

pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInfoClass: JOBOBJECTINFOCLASS,
    lpJobObjectInfo: *const anyopaque,
    cbJobObjectInfoLength: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn QueryInformationJobObject(
    hJob: HANDLE,
    JobObjectInfoClass: JOBOBJECTINFOCLASS,
    lpJobObjectInfo: *anyopaque,
    cbJobObjectInfoLength: DWORD,
    lpReturnLength: ?*DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: HANDLE,
    hProcess: HANDLE,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;

pub const Mode = enum {
    never,
    always,
    single_instance,
};

pub const AttachPolicy = enum {
    best_effort,
    hard_fail,
};

pub const ConfigPlanError = error{
    ProcessLimitOverflow,
    JobMemoryLimitOverflow,
};

pub const Plan = struct {
    mode: Mode,
    attach_policy: AttachPolicy = .best_effort,
    active_process_limit: ?DWORD = null,
    job_memory_limit_bytes: ?SIZE_T = null,
    kill_on_close: bool = false,

    pub fn wantsJobObject(self: Plan) bool {
        return self.mode != .never;
    }

    pub fn hasLimits(self: Plan) bool {
        return self.active_process_limit != null or
            self.job_memory_limit_bytes != null;
    }

    pub fn extendedLimitInformation(self: Plan) ?JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        if (!self.wantsJobObject() or (!self.hasLimits() and !self.kill_on_close)) return null;

        var info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};

        if (self.active_process_limit) |limit| {
            info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
            info.BasicLimitInformation.ActiveProcessLimit = limit;
        }

        if (self.job_memory_limit_bytes) |limit| {
            info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
            info.JobMemoryLimit = limit;
        }
        if (self.kill_on_close) {
            info.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        }

        return info;
    }
};

pub const AttachTarget = enum {
    disabled,
    attach,
    unsupported_wsl,
};

pub fn attachTarget(plan: Plan, argv0: []const u8) AttachTarget {
    if (!plan.wantsJobObject()) return .disabled;
    if (isWslExecutable(argv0)) return .unsupported_wsl;
    return .attach;
}

pub fn configPlan(config: *const configpkg.Config) ConfigPlanError!Plan {
    const mode = switch (config.@"linux-cgroup") {
        .never => Mode.never,
        .always => Mode.always,
        .@"single-instance" => Mode.single_instance,
    };

    // Preserve current Windows behavior unless the explicit compat mode opts in.
    if (mode == .never) return .{ .mode = .never };

    return .{
        .mode = mode,
        .attach_policy = if (config.@"linux-cgroup-hard-fail")
            .hard_fail
        else
            .best_effort,
        .active_process_limit = if (config.@"linux-cgroup-processes-limit") |limit|
            std.math.cast(DWORD, limit) orelse return error.ProcessLimitOverflow
        else
            null,
        .job_memory_limit_bytes = if (config.@"linux-cgroup-memory-limit") |limit|
            std.math.cast(SIZE_T, limit) orelse return error.JobMemoryLimitOverflow
        else
            null,
        .kill_on_close = config.@"windows-job-object-kill-on-close",
    };
}

fn isWslExecutable(path: []const u8) bool {
    const base = basename(path);
    return std.ascii.eqlIgnoreCase(base, "wsl.exe") or
        std.ascii.eqlIgnoreCase(base, "wsl");
}

fn basename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '\\' or c == '/') return path[i..];
    }

    return path;
}

test "win32 job object ABI declarations match expected Win32 values" {
    const create_fn = @typeInfo(@TypeOf(CreateJobObjectW)).@"fn";
    const set_info_fn = @typeInfo(@TypeOf(SetInformationJobObject)).@"fn";

    try std.testing.expectEqual(@as(i32, 9), @intFromEnum(JOBOBJECTINFOCLASS.extended_limit_information));
    try std.testing.expectEqual(@as(i32, 3), @intFromEnum(JOBOBJECTINFOCLASS.basic_process_id_list));
    try std.testing.expectEqual(@as(DWORD, 0x00000008), JOB_OBJECT_LIMIT_ACTIVE_PROCESS);
    try std.testing.expectEqual(@as(DWORD, 0x00000200), JOB_OBJECT_LIMIT_JOB_MEMORY);
    try std.testing.expectEqual(@as(DWORD, 0x00002000), JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE);
    try std.testing.expect(create_fn.params[0].type.? == ?*SECURITY_ATTRIBUTES);
    try std.testing.expect(create_fn.params[1].type.? == ?LPCWSTR);
    try std.testing.expect(create_fn.return_type.? == ?HANDLE);
    try std.testing.expect(set_info_fn.params[2].type.? == *const anyopaque);
}

test "win32 job object ABI layouts stay compatible on x64" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 48), @sizeOf(IO_COUNTERS));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(JOBOBJECT_BASIC_LIMIT_INFORMATION));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));

    try std.testing.expectEqual(@as(usize, 16), @offsetOf(JOBOBJECT_BASIC_LIMIT_INFORMATION, "LimitFlags"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(JOBOBJECT_BASIC_LIMIT_INFORMATION, "ActiveProcessLimit"));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION, "BasicLimitInformation"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION, "IoInfo"));
    try std.testing.expectEqual(@as(usize, 120), @offsetOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION, "JobMemoryLimit"));
}

test "win32 job object plan stays disabled for default config" {
    var config: configpkg.Config = .{};
    const plan = try configPlan(&config);

    try std.testing.expectEqual(Mode.never, plan.mode);
    try std.testing.expectEqual(AttachPolicy.best_effort, plan.attach_policy);
    try std.testing.expect(!plan.wantsJobObject());
    try std.testing.expect(!plan.hasLimits());
    try std.testing.expect(plan.extendedLimitInformation() == null);
}

test "win32 job object plan maps compatibility limits without kill-on-close" {
    var config: configpkg.Config = .{};
    config.@"linux-cgroup" = .always;
    config.@"linux-cgroup-memory-limit" = 512 * 1024 * 1024;
    config.@"linux-cgroup-processes-limit" = 4;

    const plan = try configPlan(&config);
    const limits = plan.extendedLimitInformation().?;

    try std.testing.expectEqual(Mode.always, plan.mode);
    try std.testing.expectEqual(AttachPolicy.best_effort, plan.attach_policy);
    try std.testing.expect(plan.wantsJobObject());
    try std.testing.expect(plan.hasLimits());
    try std.testing.expectEqual(
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_JOB_MEMORY,
        limits.BasicLimitInformation.LimitFlags,
    );
    try std.testing.expectEqual(@as(u32, 4), limits.BasicLimitInformation.ActiveProcessLimit);
    try std.testing.expectEqual(@as(usize, 512 * 1024 * 1024), limits.JobMemoryLimit);
}

test "win32 job object plan opts into kill-on-close" {
    var config: configpkg.Config = .{};
    config.@"linux-cgroup" = .always;
    config.@"windows-job-object-kill-on-close" = true;

    const plan = try configPlan(&config);
    const limits = plan.extendedLimitInformation().?;

    try std.testing.expect(plan.kill_on_close);
    try std.testing.expectEqual(
        @as(DWORD, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE),
        limits.BasicLimitInformation.LimitFlags,
    );
}

test "win32 job object plan ignores compatibility limits when mode is never" {
    var config: configpkg.Config = .{};
    config.@"linux-cgroup-memory-limit" = 512 * 1024 * 1024;
    config.@"linux-cgroup-processes-limit" = 4;
    config.@"linux-cgroup-hard-fail" = true;
    config.@"windows-job-object-kill-on-close" = true;

    const plan = try configPlan(&config);

    try std.testing.expectEqual(Mode.never, plan.mode);
    try std.testing.expectEqual(AttachPolicy.best_effort, plan.attach_policy);
    try std.testing.expect(!plan.kill_on_close);
    try std.testing.expect(!plan.wantsJobObject());
    try std.testing.expect(!plan.hasLimits());
    try std.testing.expect(plan.extendedLimitInformation() == null);
}

test "win32 job object never plan cannot synthesize limit blob" {
    const plan: Plan = .{
        .mode = .never,
        .active_process_limit = 1,
        .job_memory_limit_bytes = 1024,
    };

    try std.testing.expect(plan.hasLimits());
    try std.testing.expect(plan.extendedLimitInformation() == null);
}

test "win32 job object single-instance mode can request hard-fail attachment without limits" {
    var config: configpkg.Config = .{};
    config.@"linux-cgroup" = .@"single-instance";
    config.@"linux-cgroup-hard-fail" = true;

    const plan = try configPlan(&config);

    try std.testing.expectEqual(Mode.single_instance, plan.mode);
    try std.testing.expectEqual(AttachPolicy.hard_fail, plan.attach_policy);
    try std.testing.expect(plan.wantsJobObject());
    try std.testing.expect(!plan.hasLimits());
    try std.testing.expect(plan.extendedLimitInformation() == null);
}

test "win32 job object attach target skips WSL launches" {
    const plan: Plan = .{ .mode = .always };

    try std.testing.expectEqual(AttachTarget.attach, attachTarget(plan, "pwsh.exe"));
    try std.testing.expectEqual(AttachTarget.attach, attachTarget(plan, "C:\\Windows\\System32\\cmd.exe"));
    try std.testing.expectEqual(AttachTarget.unsupported_wsl, attachTarget(plan, "wsl"));
    try std.testing.expectEqual(AttachTarget.unsupported_wsl, attachTarget(plan, "wsl.exe"));
    try std.testing.expectEqual(
        AttachTarget.unsupported_wsl,
        attachTarget(plan, "C:\\Windows\\System32\\wsl.exe"),
    );
    try std.testing.expectEqual(AttachTarget.disabled, attachTarget(.{ .mode = .never }, "cmd.exe"));
}

test "win32 job object plan rejects process limits that exceed DWORD" {
    var config: configpkg.Config = .{};
    config.@"linux-cgroup" = .always;
    config.@"linux-cgroup-processes-limit" = @as(u64, std.math.maxInt(u32)) + 1;

    try std.testing.expectError(error.ProcessLimitOverflow, configPlan(&config));
}

test "win32 job object plan rejects memory limits that exceed SIZE_T" {
    if (@sizeOf(SIZE_T) >= @sizeOf(u64)) return error.SkipZigTest;

    var config: configpkg.Config = .{};
    config.@"linux-cgroup" = .always;
    config.@"linux-cgroup-memory-limit" = @as(u64, std.math.maxInt(SIZE_T)) + 1;

    try std.testing.expectError(error.JobMemoryLimitOverflow, configPlan(&config));
}
