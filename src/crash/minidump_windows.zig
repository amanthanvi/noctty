//! Local Windows minidump capture.
//!
//! This intentionally stays independent from Sentry. Windows builds in this
//! fork keep crash capture local-only, so the unhandled-exception filter writes
//! a small `.dmp` next to any other local crash artifacts.

const std = @import("std");
const windows = std.os.windows;
const dir = @import("dir.zig");

const log = std.log.scoped(.crash_minidump);

const EXCEPTION_EXECUTE_HANDLER: c_long = 1;
const MiniDumpWithDataSegs: u32 = 0x00000001;
const MiniDumpWithHandleData: u32 = 0x00000004;
const MiniDumpWithUnloadedModules: u32 = 0x00000020;
const MiniDumpType =
    MiniDumpWithDataSegs |
    MiniDumpWithHandleData |
    MiniDumpWithUnloadedModules;

// minidumpapiset.h declares this struct inside `#include <pshpack4.h>`, so on
// 64-bit Windows the pointer sits at offset 4 and the struct is 16 bytes, not
// the naturally aligned 24. With natural alignment dbghelp assembles the
// pointer from the padding and half the real pointer, and fails every dump
// with ERROR_NOACCESS.
const MINIDUMP_EXCEPTION_INFORMATION = extern struct {
    ThreadId: windows.DWORD,
    ExceptionPointers: *windows.EXCEPTION_POINTERS align(4),
    ClientPointers: windows.BOOL,
};

comptime {
    std.debug.assert(@offsetOf(MINIDUMP_EXCEPTION_INFORMATION, "ExceptionPointers") == 4);
    std.debug.assert(@sizeOf(MINIDUMP_EXCEPTION_INFORMATION) == 8 + @sizeOf(usize));
}

const ExceptionFilter = ?*const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long;

extern "kernel32" fn SetUnhandledExceptionFilter(
    lpTopLevelExceptionFilter: ExceptionFilter,
) callconv(.winapi) ExceptionFilter;

extern "dbghelp" fn MiniDumpWriteDump(
    hProcess: windows.HANDLE,
    ProcessId: windows.DWORD,
    hFile: windows.HANDLE,
    DumpType: u32,
    ExceptionParam: ?*MINIDUMP_EXCEPTION_INFORMATION,
    UserStreamParam: ?*anyopaque,
    CallbackParam: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

var installed = false;
var previous_filter: ExceptionFilter = null;
var writing = std.atomic.Value(bool).init(false);
var crash_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var crash_dir: []const u8 = "";
// Static rather than on the stack: the filter runs on the faulting thread,
// which may be a driver thread with a small stack. `writing` serializes use.
var dump_path_buf: [std.fs.max_path_bytes]u8 = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    // Preserve the original exception filter across repeated crash init calls.
    if (installed) return;

    const crash = try dir.defaultDir(alloc);
    defer alloc.free(crash.path);

    std.fs.makeDirAbsolute(crash.path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    if (crash.path.len > crash_dir_buf.len) return error.NameTooLong;

    @memcpy(crash_dir_buf[0..crash.path.len], crash.path);
    crash_dir = crash_dir_buf[0..crash.path.len];

    previous_filter = SetUnhandledExceptionFilter(unhandledExceptionFilter);
    installed = true;
    log.debug("windows minidump handler initialized path={s}", .{crash_dir});
}

pub fn deinit() void {
    if (!installed) return;
    _ = SetUnhandledExceptionFilter(previous_filter);
    installed = false;
    previous_filter = null;
}

fn unhandledExceptionFilter(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    if (writing.swap(true, .seq_cst)) {
        return callPreviousFilter(info);
    }
    defer writing.store(false, .seq_cst);

    writeMinidump(info) catch |err| {
        log.warn("failed to write windows minidump err={}", .{err});
    };

    return callPreviousFilter(info);
}

fn callPreviousFilter(info: *windows.EXCEPTION_POINTERS) c_long {
    if (previous_filter) |filter| return filter(info);
    return EXCEPTION_EXECUTE_HANDLER;
}

fn writeMinidump(info: *windows.EXCEPTION_POINTERS) !void {
    if (crash_dir.len == 0) return error.NotInitialized;
    try writeMinidumpIn(crash_dir, info);
}

fn writeMinidumpIn(base_dir: []const u8, info: *windows.EXCEPTION_POINTERS) !void {
    const path = try formatDumpPath(
        &dump_path_buf,
        base_dir,
        windows.GetCurrentProcessId(),
        std.time.milliTimestamp(),
    );

    var file = try std.fs.createFileAbsolute(path, .{
        .read = false,
        .truncate = true,
    });
    errdefer std.fs.deleteFileAbsolute(path) catch |err| {
        log.warn("failed to delete incomplete windows minidump path={s} err={}", .{ path, err });
    };
    defer file.close();

    var exception_info: MINIDUMP_EXCEPTION_INFORMATION = .{
        .ThreadId = windows.GetCurrentThreadId(),
        .ExceptionPointers = info,
        .ClientPointers = 0,
    };

    if (MiniDumpWriteDump(
        windows.GetCurrentProcess(),
        windows.GetCurrentProcessId(),
        file.handle,
        MiniDumpType,
        &exception_info,
        null,
        null,
    ) == 0) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }

    log.warn("windows minidump written path={s}", .{path});
}

fn formatDumpPath(
    buf: []u8,
    base_dir: []const u8,
    pid: windows.DWORD,
    timestamp_ms: i64,
) ![]const u8 {
    if (base_dir.len == 0) return error.InvalidDirectory;
    const sep: []const u8 = if (std.fs.path.isSep(base_dir[base_dir.len - 1])) "" else &.{std.fs.path.sep};
    return try std.fmt.bufPrint(
        buf,
        "{s}{s}noctty-{d}-{d}.dmp",
        .{ base_dir, sep, pid, timestamp_ms },
    );
}

test "formatDumpPath appends separator and dmp extension" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try formatDumpPath(&buf, "C:\\Users\\a\\noctty\\crash", 42, 1234);
    try std.testing.expectEqualStrings("C:\\Users\\a\\noctty\\crash\\noctty-42-1234.dmp", path);
}

test "formatDumpPath keeps existing separator" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try formatDumpPath(&buf, "C:\\crash\\", 7, 9);
    try std.testing.expectEqualStrings("C:\\crash\\noctty-7-9.dmp", path);
}

test "writeMinidumpIn writes a dump that carries the exception" {
    // Same layout as windows.EXCEPTION_RECORD, with a nullable chain pointer.
    const Record = extern struct {
        ExceptionCode: u32,
        ExceptionFlags: u32,
        ExceptionRecord: ?*anyopaque,
        ExceptionAddress: ?*anyopaque,
        NumberParameters: u32,
        ExceptionInformation: [15]usize,
    };
    comptime std.debug.assert(@sizeOf(Record) == @sizeOf(windows.EXCEPTION_RECORD));

    var record: Record = .{
        .ExceptionCode = windows.EXCEPTION_ACCESS_VIOLATION,
        .ExceptionFlags = 0,
        .ExceptionRecord = null,
        .ExceptionAddress = @ptrFromInt(@returnAddress()),
        .NumberParameters = 2,
        .ExceptionInformation = [_]usize{ 0, 0x10 } ++ [_]usize{0} ** 13,
    };
    var context: windows.CONTEXT = undefined;
    windows.ntdll.RtlCaptureContext(&context);
    var pointers: windows.EXCEPTION_POINTERS = .{
        .ExceptionRecord = @ptrCast(&record),
        .ContextRecord = &context,
    };

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &dir_buf);

    try writeMinidumpIn(dir_path, &pointers);

    var it = tmp.dir.iterate();
    const entry = (try it.next()) orelse return error.TestExpectedDump;
    try std.testing.expect(std.mem.endsWith(u8, entry.name, ".dmp"));
    try std.testing.expect((try it.next()) == null);

    // MINIDUMP_HEADER starts with "MDMP"; the exception stream (type 6) is
    // present only when dbghelp could read the exception pointers.
    var file = try tmp.dir.openFile(entry.name, .{});
    defer file.close();
    var header: [32]u8 = undefined;
    try std.testing.expectEqual(header.len, try file.preadAll(&header, 0));
    try std.testing.expectEqualStrings("MDMP", header[0..4]);
    const stream_count = std.mem.readInt(u32, header[8..12], .little);
    const directory_rva = std.mem.readInt(u32, header[12..16], .little);
    var found_exception = false;
    for (0..stream_count) |i| {
        var dir_entry: [12]u8 = undefined;
        try std.testing.expectEqual(dir_entry.len, try file.preadAll(&dir_entry, directory_rva + i * dir_entry.len));
        if (std.mem.readInt(u32, dir_entry[0..4], .little) == 6) found_exception = true;
    }
    try std.testing.expect(found_exception);
}
