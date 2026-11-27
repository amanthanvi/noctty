//! Local Windows minidump capture.
//!
//! This intentionally stays independent from Sentry. Windows builds in this
//! fork keep crash capture local-only, so the unhandled-exception filter writes
//! a small `.dmp` next to any other local crash artifacts.

const std = @import("std");
const win32_repeat = @import("../apprt/win32_repeat.zig");
const prefixed_path = @import("../apprt/win32_prefixed_path.zig");
const win32_sys = @import("../apprt/win32/sys.zig");
const win32_types = @import("../apprt/win32_types.zig");
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
    ClientPointers: win32_types.BOOL,
};

comptime {
    std.debug.assert(@offsetOf(MINIDUMP_EXCEPTION_INFORMATION, "ExceptionPointers") == 4);
    std.debug.assert(@sizeOf(MINIDUMP_EXCEPTION_INFORMATION) == 8 + @sizeOf(usize));
}

const ExceptionFilter = ?*const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long;

extern "kernel32" fn SetUnhandledExceptionFilter(
    lpTopLevelExceptionFilter: ExceptionFilter,
) callconv(.winapi) ExceptionFilter;

extern "kernel32" fn DeleteFileW(path: windows.LPCWSTR) callconv(.winapi) win32_types.BOOL;

extern "dbghelp" fn MiniDumpWriteDump(
    hProcess: windows.HANDLE,
    ProcessId: windows.DWORD,
    hFile: windows.HANDLE,
    DumpType: u32,
    ExceptionParam: ?*MINIDUMP_EXCEPTION_INFORMATION,
    UserStreamParam: ?*anyopaque,
    CallbackParam: ?*anyopaque,
) callconv(.winapi) win32_types.BOOL;

var installed = false;
var previous_filter: ExceptionFilter = null;
var writing = std.atomic.Value(bool).init(false);
var crash_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
var crash_dir: []const u8 = "";
var crash_dir_w: prefixed_path.PathSpace = undefined;
// Static rather than on the stack: the filter runs on the faulting thread,
// which may be a driver thread with a small stack. `writing` serializes use.
var dump_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var dump_path_w: [windows.PATH_MAX_WIDE:0]u16 = undefined;

pub fn init(io: std.Io, alloc: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !void {
    // Preserve the original exception filter across repeated crash init calls.
    if (installed) return;

    const crash = try dir.defaultDir(io, alloc, environ_map);
    defer alloc.free(crash.path);

    try initIn(io, crash.path);
}

fn initIn(io: std.Io, path: []const u8) !void {
    if (installed) return;

    if (path.len > crash_dir_buf.len) return error.NameTooLong;
    // Normalize and convert on the healthy startup stack, before the filter
    // is installed. The filter only appends its ASCII filename.
    crash_dir_w = try dumpDirectoryW(path);
    // Zig 0.17's `createDirPath` does not follow a link it finds on the way
    // (0.15's `makePath` did), so an existing directory, a link to one
    // included, is opened first and created only when it is missing.
    if (std.Io.Dir.cwd().openDir(io, path, .{ .follow_symlinks = true })) |existing| {
        existing.close(io);
    } else |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createDirPath(io, path),
        else => |e| return e,
    }

    @memcpy(crash_dir_buf[0..path.len], path);
    crash_dir = crash_dir_buf[0..path.len];

    previous_filter = SetUnhandledExceptionFilter(unhandledExceptionFilter);
    installed = true;
    log.debug("windows minidump handler initialized path={s}", .{crash_dir});
}

test "minidump init creates missing parent directories" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "absent", "noctty", "crash" });
    defer alloc.free(path);

    try initIn(std.testing.io, path);
    defer deinit();
    var created = try std.Io.Dir.openDirAbsolute(std.testing.io, path, .{});
    defer created.close(std.testing.io);
    try std.testing.expect(installed);
    try std.testing.expectEqualStrings(path, crash_dir);
    try initIn(std.testing.io, path);
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
    try writeMinidumpIn(crash_dir, crash_dir_w.span(), info);
}

fn dumpDirectoryW(path: []const u8) !prefixed_path.PathSpace {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidDirectory;
    var result = try prefixed_path.sliceToPrefixedFileW(path);
    // Zig normalizes absolute paths to the NT namespace (\??\). Change it
    // to the equivalent Win32 extended prefix (\\?\) for CreateFileW,
    // retaining normalized separators, UNC paths and long-path support.
    if (!std.mem.startsWith(u16, result.span(), &.{ '\\', '?', '?', '\\' })) return error.InvalidDirectory;
    result.data[1] = '\\';
    return result;
}

fn writeMinidumpIn(base_dir: []const u8, base_dir_w: [:0]const u16, info: *windows.EXCEPTION_POINTERS) !void {
    const path = try formatDumpPath(
        &dump_path_buf,
        base_dir,
        windows.GetCurrentProcessId(),
        std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).toMilliseconds(),
    );

    const filename = std.fs.path.basename(path);
    const sep_len: usize = if (base_dir_w.len > 0 and base_dir_w[base_dir_w.len - 1] == '\\') 0 else 1;
    const wide_len = base_dir_w.len + sep_len + filename.len;
    if (wide_len > dump_path_w.len) return error.NameTooLong;
    @memcpy(dump_path_w[0..base_dir_w.len], base_dir_w);
    if (sep_len != 0) dump_path_w[base_dir_w.len] = '\\';
    // formatDumpPath's filename is ASCII, one UTF-16 code unit per byte.
    for (filename, base_dir_w.len + sep_len..) |c, i| dump_path_w[i] = c;
    dump_path_w[wide_len] = 0;

    const handle = win32_sys.CreateFileW(
        &dump_path_w,
        win32_types.GENERIC_WRITE,
        win32_types.FILE_SHARE_READ | win32_types.FILE_SHARE_WRITE | win32_types.FILE_SHARE_DELETE,
        null,
        win32_types.CREATE_ALWAYS,
        win32_types.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return windows.unexpectedError(std.os.windows.GetLastError());
    errdefer if (DeleteFileW(&dump_path_w) == 0) {
        log.warn("failed to delete incomplete windows minidump path={s} err={}", .{ path, std.os.windows.GetLastError() });
    };
    defer windows.CloseHandle(handle);

    var exception_info: MINIDUMP_EXCEPTION_INFORMATION = .{
        .ThreadId = windows.GetCurrentThreadId(),
        .ExceptionPointers = info,
        .ClientPointers = 0,
    };

    if (MiniDumpWriteDump(
        windows.GetCurrentProcess(),
        windows.GetCurrentProcessId(),
        handle,
        MiniDumpType,
        &exception_info,
        null,
        null,
    ) == 0) {
        return windows.unexpectedError(std.os.windows.GetLastError());
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
        .ExceptionInformation = [_]usize{ 0, 0x10 } ++ @as([13]usize, @splat(0)),
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
    // Twelve components are 300 characters on their own, so the path passes
    // MAX_PATH however short the checkout is. The limit counts UTF-16 units.
    const sub_path = "用户-Ü/" ++ comptime win32_repeat.repeat("long-directory-component/", 12);
    try tmp.dir.createDirPath(std.testing.io, sub_path);
    var dump_dir = try tmp.dir.openDir(std.testing.io, sub_path, .{ .iterate = true });
    defer dump_dir.close(std.testing.io);
    const dir_path = dir_buf[0..try dump_dir.realPathFile(std.testing.io, ".", &dir_buf)];
    try std.testing.expect(try std.unicode.calcWtf16LeLen(dir_path) > windows.MAX_PATH);
    const dir_w = try dumpDirectoryW(dir_path);

    try writeMinidumpIn(dir_path, dir_w.span(), &pointers);

    var it = dump_dir.iterate();
    const entry = (try it.next(std.testing.io)) orelse return error.TestExpectedDump;
    try std.testing.expect(std.mem.endsWith(u8, entry.name, ".dmp"));
    try std.testing.expect((try it.next(std.testing.io)) == null);

    // MINIDUMP_HEADER starts with "MDMP". The exception stream (type 6)
    // must carry this thread and the record above, which proves dbghelp
    // read our exception pointers rather than something else.
    var file = try dump_dir.openFile(std.testing.io, entry.name, .{});
    defer file.close(std.testing.io);
    var header: [32]u8 = undefined;
    try std.testing.expectEqual(header.len, try file.readPositionalAll(std.testing.io, &header, 0));
    try std.testing.expectEqualStrings("MDMP", header[0..4]);
    const stream_count = std.mem.readInt(u32, header[8..12], .little);
    const directory_rva = std.mem.readInt(u32, header[12..16], .little);
    const stream_rva = for (0..stream_count) |i| {
        var dir_entry: [12]u8 = undefined;
        try std.testing.expectEqual(dir_entry.len, try file.readPositionalAll(std.testing.io, &dir_entry, directory_rva + i * dir_entry.len));
        if (std.mem.readInt(u32, dir_entry[0..4], .little) == 6) break std.mem.readInt(u32, dir_entry[8..12], .little);
    } else return error.TestExpectedExceptionStream;

    // MINIDUMP_EXCEPTION_STREAM: ThreadId, padding, then MINIDUMP_EXCEPTION
    // (code, flags, record, address, parameter count, padding, parameters).
    var stream: [56]u8 = undefined;
    try std.testing.expectEqual(stream.len, try file.readPositionalAll(std.testing.io, &stream, stream_rva));
    try std.testing.expectEqual(windows.GetCurrentThreadId(), std.mem.readInt(u32, stream[0..4], .little));
    try std.testing.expectEqual(record.ExceptionCode, std.mem.readInt(u32, stream[8..12], .little));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, stream[32..36], .little));
    try std.testing.expectEqual(@as(u64, 0x10), std.mem.readInt(u64, stream[48..56], .little));
}
