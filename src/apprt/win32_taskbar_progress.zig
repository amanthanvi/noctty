const std = @import("std");
const windows = std.os.windows;
const progress_report = @import("../progress_report.zig");
const win32_types = @import("win32_types.zig");
const sys = @import("win32/sys.zig");

const HRESULT = windows.HRESULT;
const GUID = windows.GUID;
const BOOL = win32_types.BOOL;
const DWORD = win32_types.DWORD;
const HWND = win32_types.HWND;
const ULONGLONG = u64;

const log = std.log.scoped(.win32_taskbar_progress);

const CLSCTX_INPROC_SERVER: DWORD = 0x1;

pub const TBPFLAG = enum(u32) {
    no_progress = 0x0,
    indeterminate = 0x1,
    normal = 0x2,
    @"error" = 0x4,
    paused = 0x8,
};
pub const TBPF_NOPROGRESS: TBPFLAG = .no_progress;
pub const TBPF_INDETERMINATE: TBPFLAG = .indeterminate;
pub const TBPF_NORMAL: TBPFLAG = .normal;
pub const TBPF_ERROR: TBPFLAG = .@"error";
pub const TBPF_PAUSED: TBPFLAG = .paused;

const CLSID_TaskbarList = GUID.parse("{56FDF344-FD6D-11d0-958A-006097C9A090}");
const IID_ITaskbarList3 = GUID.parse("{EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF}");
const CO_E_NOTINITIALIZED: HRESULT = @bitCast(@as(u32, 0x800401F0));

const ITaskbarList3Vtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    HrInit: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    AddTab: *const fn (*anyopaque, HWND) callconv(.winapi) HRESULT,
    DeleteTab: *const fn (*anyopaque, HWND) callconv(.winapi) HRESULT,
    ActivateTab: *const fn (*anyopaque, HWND) callconv(.winapi) HRESULT,
    SetActiveAlt: *const fn (*anyopaque, HWND) callconv(.winapi) HRESULT,
    MarkFullscreenWindow: *const fn (*anyopaque, HWND, BOOL) callconv(.winapi) HRESULT,
    SetProgressValue: *const fn (*anyopaque, HWND, ULONGLONG, ULONGLONG) callconv(.winapi) HRESULT,
    SetProgressState: *const fn (*anyopaque, HWND, DWORD) callconv(.winapi) HRESULT,
};

const ITaskbarList3 = extern struct {
    vtbl: *const ITaskbarList3Vtbl,

    fn fromRaw(raw: *anyopaque) *ITaskbarList3 {
        return @ptrCast(@alignCast(raw));
    }

    fn asRaw(self: *ITaskbarList3) *anyopaque {
        return @ptrCast(self);
    }

    fn release(self: *ITaskbarList3) u32 {
        return self.vtbl.Release(self.asRaw());
    }

    fn hrInit(self: *ITaskbarList3) HRESULT {
        return self.vtbl.HrInit(self.asRaw());
    }

    fn setProgressState(self: *ITaskbarList3, hwnd: HWND, flags: TBPFLAG) HRESULT {
        return self.vtbl.SetProgressState(self.asRaw(), hwnd, @intFromEnum(flags));
    }

    fn setProgressValue(self: *ITaskbarList3, hwnd: HWND, completed: ULONGLONG, total: ULONGLONG) HRESULT {
        return self.vtbl.SetProgressValue(self.asRaw(), hwnd, completed, total);
    }
};

pub const ProgressValue = struct {
    completed: u64,
    total: u64,
};

pub const ProgressMapping = struct {
    flags: TBPFLAG,
    value: ?ProgressValue = null,
};

pub const ProgressReport = progress_report.Report;
pub const ProgressState = progress_report.State;

pub fn clampPercent(progress: ?u8) ?u8 {
    return if (progress) |value|
        std.math.clamp(value, 0, 100)
    else
        null;
}

pub fn mapProgressReport(report: ProgressReport) ProgressMapping {
    const progress = clampPercent(report.progress);
    return switch (report.state) {
        .remove => .{ .flags = TBPF_NOPROGRESS },
        .indeterminate => .{ .flags = TBPF_INDETERMINATE },
        .set => if (progress) |value| .{
            .flags = TBPF_NORMAL,
            .value = .{ .completed = value, .total = 100 },
        } else .{ .flags = TBPF_INDETERMINATE },
        .@"error" => .{
            .flags = TBPF_ERROR,
            .value = .{ .completed = progress orelse 0, .total = 100 },
        },
        .pause => .{
            .flags = TBPF_PAUSED,
            .value = .{ .completed = progress orelse 0, .total = 100 },
        },
    };
}

pub const InitError = error{
    ComNotInitialized,
    Unavailable,
    InitializationFailed,
};

pub const ApplyError = error{
    SetProgressStateFailed,
    SetProgressValueFailed,
    ResetProgressStateFailed,
};

pub const TaskbarProgress = struct {
    taskbar: *ITaskbarList3,

    pub fn init() InitError!TaskbarProgress {
        var raw: ?*anyopaque = null;
        const create_hr = sys.CoCreateInstance(
            &CLSID_TaskbarList,
            null,
            CLSCTX_INPROC_SERVER,
            &IID_ITaskbarList3,
            &raw,
        );
        if (create_hr == CO_E_NOTINITIALIZED) return error.ComNotInitialized;
        if (create_hr < 0 or raw == null) return error.Unavailable;

        const taskbar = ITaskbarList3.fromRaw(raw.?);
        errdefer _ = taskbar.release();

        const init_hr = taskbar.hrInit();
        if (init_hr < 0) return error.InitializationFailed;

        return .{ .taskbar = taskbar };
    }

    pub fn deinit(self: *TaskbarProgress) void {
        _ = self.taskbar.release();
        self.* = undefined;
    }

    pub fn apply(self: *TaskbarProgress, hwnd: HWND, report: ?ProgressReport) ApplyError!void {
        const mapping = if (report) |value| mapProgressReport(value) else ProgressMapping{ .flags = TBPF_NOPROGRESS };

        const state_hr = self.taskbar.setProgressState(hwnd, mapping.flags);
        if (state_hr < 0) return error.SetProgressStateFailed;

        if (mapping.value) |value| {
            const value_hr = self.taskbar.setProgressValue(
                hwnd,
                value.completed,
                value.total,
            );
            if (value_hr < 0) {
                const reset_hr = self.taskbar.setProgressState(hwnd, TBPF_NOPROGRESS);
                if (reset_hr < 0) {
                    log.warn("taskbar progress reset after value failure also failed hr=0x{x}", .{@as(u32, @bitCast(reset_hr))});
                    return error.ResetProgressStateFailed;
                }
                return error.SetProgressValueFailed;
            }
        }
    }
};

test "ITaskbarList3 IID matches Windows shell interface" {
    const expected = GUID.parse("{EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF}");
    try std.testing.expectEqualDeep(expected, IID_ITaskbarList3);
}

test "ITaskbarList3 wrapper preserves COM pointer layout" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ITaskbarList3, "vtbl"));
    try std.testing.expectEqual(@sizeOf(*anyopaque), @sizeOf(ITaskbarList3));
}

test "taskbar progress maps remove and indeterminate states without values" {
    try std.testing.expectEqual(
        ProgressMapping{ .flags = TBPF_NOPROGRESS },
        mapProgressReport(.{ .state = .remove }),
    );
    try std.testing.expectEqual(
        ProgressMapping{ .flags = TBPF_INDETERMINATE },
        mapProgressReport(.{ .state = .indeterminate }),
    );
}

test "taskbar progress maps determinate states to shell colors and values" {
    try std.testing.expectEqual(
        ProgressMapping{ .flags = TBPF_NORMAL, .value = .{ .completed = 42, .total = 100 } },
        mapProgressReport(.{ .state = .set, .progress = 42 }),
    );
    try std.testing.expectEqual(
        ProgressMapping{ .flags = TBPF_ERROR, .value = .{ .completed = 42, .total = 100 } },
        mapProgressReport(.{ .state = .@"error", .progress = 42 }),
    );
    try std.testing.expectEqual(
        ProgressMapping{ .flags = TBPF_PAUSED, .value = .{ .completed = 42, .total = 100 } },
        mapProgressReport(.{ .state = .pause, .progress = 42 }),
    );
}

test "taskbar progress treats missing set progress as indeterminate and clamps overflow" {
    try std.testing.expectEqual(
        ProgressMapping{ .flags = TBPF_INDETERMINATE },
        mapProgressReport(.{ .state = .set }),
    );
    try std.testing.expectEqual(
        ProgressMapping{ .flags = TBPF_NORMAL, .value = .{ .completed = 100, .total = 100 } },
        mapProgressReport(.{ .state = .set, .progress = 255 }),
    );
}

test "taskbar progress clears visible state when value update fails" {
    const Call = union(enum) {
        state: TBPFLAG,
        value: ProgressValue,
    };

    const FakeTaskbar = struct {
        iface: ITaskbarList3,
        calls: [4]Call = undefined,
        call_count: usize = 0,

        const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

        fn fromRaw(raw: *anyopaque) *@This() {
            const iface = ITaskbarList3.fromRaw(raw);
            return @fieldParentPtr("iface", iface);
        }

        fn queryInterface(_: *anyopaque, _: *const GUID, _: *?*anyopaque) callconv(.winapi) HRESULT {
            return E_FAIL;
        }

        fn addRef(_: *anyopaque) callconv(.winapi) u32 {
            return 1;
        }

        fn release(_: *anyopaque) callconv(.winapi) u32 {
            return 1;
        }

        fn hrInit(_: *anyopaque) callconv(.winapi) HRESULT {
            return 0;
        }

        fn tab(_: *anyopaque, _: HWND) callconv(.winapi) HRESULT {
            return 0;
        }

        fn markFullscreenWindow(_: *anyopaque, _: HWND, _: BOOL) callconv(.winapi) HRESULT {
            return 0;
        }

        fn setProgressValue(raw: *anyopaque, _: HWND, completed: ULONGLONG, total: ULONGLONG) callconv(.winapi) HRESULT {
            const self = fromRaw(raw);
            self.calls[self.call_count] = .{ .value = .{ .completed = completed, .total = total } };
            self.call_count += 1;
            return E_FAIL;
        }

        fn setProgressState(raw: *anyopaque, _: HWND, flags: DWORD) callconv(.winapi) HRESULT {
            const self = fromRaw(raw);
            self.calls[self.call_count] = .{ .state = @enumFromInt(flags) };
            self.call_count += 1;
            return 0;
        }

        const vtbl: ITaskbarList3Vtbl = .{
            .QueryInterface = queryInterface,
            .AddRef = addRef,
            .Release = release,
            .HrInit = hrInit,
            .AddTab = tab,
            .DeleteTab = tab,
            .ActivateTab = tab,
            .SetActiveAlt = tab,
            .MarkFullscreenWindow = markFullscreenWindow,
            .SetProgressValue = setProgressValue,
            .SetProgressState = setProgressState,
        };
    };

    var fake = FakeTaskbar{ .iface = .{ .vtbl = &FakeTaskbar.vtbl } };
    var taskbar = TaskbarProgress{ .taskbar = &fake.iface };

    try std.testing.expectError(
        error.SetProgressValueFailed,
        taskbar.apply(@ptrFromInt(1), .{ .state = .set, .progress = 42 }),
    );

    try std.testing.expectEqual(@as(usize, 3), fake.call_count);
    try std.testing.expectEqual(TBPF_NORMAL, fake.calls[0].state);
    try std.testing.expectEqual(ProgressValue{ .completed = 42, .total = 100 }, fake.calls[1].value);
    try std.testing.expectEqual(TBPF_NOPROGRESS, fake.calls[2].state);
}
