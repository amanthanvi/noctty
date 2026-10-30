//! Open a local configuration document using the user's text editor association.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const shell = @import("../config/windows_shell.zig");
const os_windows = @import("windows.zig");
const local_target = @import("../apprt/win32/local_target.zig");

pub const failure_message = "Could not open the config file in a text editor. Check that the file is accessible and a text editor is installed, then try again.";

const SEE_MASK_CLASSNAME = 0x00000001;
const SEE_MASK_NOASYNC = 0x00000100;
const SEE_MASK_FLAG_NO_UI = 0x00000400;

const ShellExecuteInfo = extern struct {
    cbSize: windows.DWORD = @sizeOf(ShellExecuteInfo),
    fMask: windows.ULONG = 0,
    hwnd: ?windows.HWND = null,
    lpVerb: ?windows.LPCWSTR = null,
    lpFile: ?windows.LPCWSTR = null,
    lpParameters: ?windows.LPCWSTR = null,
    lpDirectory: ?windows.LPCWSTR = null,
    nShow: windows.INT = 1,
    hInstApp: ?windows.HINSTANCE = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?windows.LPCWSTR = null,
    hkeyClass: ?windows.HANDLE = null,
    dwHotKey: windows.DWORD = 0,
    hIcon: ?windows.HANDLE = null,
    hProcess: ?windows.HANDLE = null,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(ShellExecuteInfo) == 112);
        std.debug.assert(@offsetOf(ShellExecuteInfo, "lpClass") == 72);
        std.debug.assert(@offsetOf(ShellExecuteInfo, "hProcess") == 104);
    }
}

extern "shell32" fn ShellExecuteExW(info: *ShellExecuteInfo) callconv(.winapi) windows.BOOL;
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) windows.HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

pub fn open(alloc: std.mem.Allocator, path: []const u8) !void {
    return openWith(alloc, path, queryAssociation, execute);
}

fn queryAssociation(flags: u32, str: u32, assoc: [*:0]const u16, extra: ?[*:0]const u16, out: ?[*]u16, len: *u32) !windows.HRESULT {
    return os_windows.AssocQueryStringW(flags, str, assoc, extra, out, len);
}

fn execute(info: *ShellExecuteInfo) !bool {
    // Shell extensions may require COM. The CLI has no app runtime to set it
    // up, while the app may already have an apartment on this thread.
    const hr = CoInitializeEx(null, 0x2 | 0x4); // STA, disable OLE1 DDE
    const changed_mode: windows.HRESULT = @bitCast(@as(u32, 0x80010106));
    if (hr < 0 and hr != changed_mode) return error.EditorComInitializationFailed;
    defer if (hr >= 0) CoUninitialize();
    return ShellExecuteExW(info) != 0;
}

fn openWith(alloc: std.mem.Allocator, path: []const u8, comptime query_association: anytype, comptime shell_execute: anytype) !void {
    // Screen before opening anything, including any reparse target. The class
    // override must never make a network or device path acceptable.
    if (!shell.isSafeWindowsPath(path) or !shell.isDriveAbsolutePath(path) or
        @import("path.zig").isNetworkOrDevicePath(path) or
        std.mem.indexOfScalar(u8, path[2..], ':') != null) return error.OpenConfigRejected;
    var components = std.mem.tokenizeAny(u8, path[3..], "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) continue;
        if (component[component.len - 1] == '.' or component[component.len - 1] == ' ') return error.OpenConfigRejected;
    }
    const normalized = try std.fs.path.resolve(alloc, &.{path});
    defer alloc.free(normalized);
    if (!shell.isDriveAbsolutePath(normalized) or
        os_windows.driveTypeForLetter(normalized[0]) == os_windows.DRIVE_REMOTE) return error.OpenConfigRejected;
    const file = local_target.open(alloc, normalized, false) orelse return error.OpenConfigRejected;
    defer file.close();
    if ((try file.stat()).kind != .file) return error.OpenConfigRejected;

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, normalized);
    defer alloc.free(path_w);
    // SEE_MASK_CLASSNAME requires the association's ProgID, not its extension.
    // Let the shell resolve .txt (including UserChoice), without reading or
    // changing associations ourselves. Fail closed on an absent or oversized
    // result; do not dispatch a truncated class or an uninitialized buffer.
    var prog_id: [1024]u16 = @splat(0xffff);
    var prog_id_len: u32 = prog_id.len;
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("open");
    if (try query_association(0, 20, std.unicode.utf8ToUtf16LeStringLiteral(".txt"), verb, &prog_id, &prog_id_len) != 0)
        return error.TextEditorAssociationUnavailable;
    if (prog_id_len < 2 or prog_id_len > prog_id.len) return error.InvalidTextEditorAssociation;
    const end = std.mem.indexOfScalar(u16, prog_id[0..prog_id_len], 0) orelse return error.InvalidTextEditorAssociation;
    if (end != prog_id_len - 1) return error.InvalidTextEditorAssociation;
    var info: ShellExecuteInfo = .{
        // Keep the UTF-16 buffers alive until the shell finishes using them,
        // and let the caller present errors through its own status UI.
        .fMask = SEE_MASK_CLASSNAME | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI,
        .lpVerb = verb,
        .lpFile = path_w.ptr,
        .lpClass = prog_id[0..end :0].ptr,
    };
    if (!try shell_execute(&info)) return error.OpenConfigFailed;
}

test "SET text editor uses resolved txt ProgID for ghostty and extensionless files and reports failure" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Fake = struct {
        var fail = false;
        var calls: usize = 0;
        var expected: []const u8 = "";
        var queries: usize = 0;
        fn query(flags: u32, str: u32, assoc: [*:0]const u16, extra: ?[*:0]const u16, out: ?[*]u16, len: *u32) !windows.HRESULT {
            queries += 1;
            try std.testing.expectEqual(@as(u32, 0), flags);
            try std.testing.expectEqual(@as(u32, 20), str); // ASSOCSTR_PROGID
            try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral(".txt"), std.mem.span(assoc));
            try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("open"), std.mem.span(extra.?));
            try std.testing.expectEqual(@as(u32, 1024), len.*);
            const prog_id = std.unicode.utf8ToUtf16LeStringLiteral("Noctty.Test.TextEditor");
            @memcpy(out.?[0..prog_id.len], prog_id);
            out.?[prog_id.len] = 0;
            len.* = prog_id.len + 1;
            return 0;
        }
        fn executeFake(info: *ShellExecuteInfo) !bool {
            calls += 1;
            try std.testing.expectEqual(@as(windows.DWORD, @sizeOf(ShellExecuteInfo)), info.cbSize);
            try std.testing.expectEqual(@as(windows.ULONG, SEE_MASK_CLASSNAME | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI), info.fMask);
            try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Noctty.Test.TextEditor"), std.mem.span(info.lpClass.?));
            try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("open"), std.mem.span(info.lpVerb.?));
            try std.testing.expect(info.lpParameters == null);
            try std.testing.expect(info.hwnd == null);
            try std.testing.expect(info.lpFile != null);
            const actual = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, std.mem.span(info.lpFile.?));
            defer std.testing.allocator.free(actual);
            try std.testing.expectEqualStrings(expected, actual);
            return !fail;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    Fake.calls = 0;
    Fake.queries = 0;
    Fake.fail = false;
    for ([_][]const u8{ "config.ghostty", "config" }) |name| {
        try tmp.dir.writeFile(.{ .sub_path = name, .data = "font-size = 12\n" });
        const path = try tmp.dir.realpathAlloc(alloc, name);
        defer alloc.free(path);
        Fake.expected = path;
        try openWith(alloc, path, Fake.query, Fake.executeFake);
        Fake.fail = true;
        try std.testing.expectError(error.OpenConfigFailed, openWith(alloc, path, Fake.query, Fake.executeFake));
        Fake.fail = false;
    }
    try std.testing.expectEqual(@as(usize, 4), Fake.calls);
    try std.testing.expectEqual(@as(usize, 4), Fake.queries);
}

test "SET text editor safety gates reject unsafe targets before shell dispatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Fake = struct {
        fn unexpectedQuery(_: u32, _: u32, _: [*:0]const u16, _: ?[*:0]const u16, _: ?[*]u16, _: *u32) !windows.HRESULT {
            return error.UnexpectedAssociationQuery;
        }
        fn unexpected(_: *ShellExecuteInfo) !bool {
            return error.UnexpectedShellDispatch;
        }
    };
    for ([_][]const u8{
        "\\\\server\\config.ghostty", "//server/config",           "\\/server/config",    "/\\server/config",
        "\\\\?\\C:\\config",          "\\??\\UNC\\server\\config", "\\\\.\\pipe\\config", "C:\\config:stream",
        "C:\\alias.\\config",         "C:\\alias \\config",        "config.ghostty",      "https://example.com/config",
        "C:\\config\x00.ghostty",
    }) |path| try std.testing.expectError(error.OpenConfigRejected, openWith(std.testing.allocator, path, Fake.unexpectedQuery, Fake.unexpected));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.OpenConfigRejected, openWith(std.testing.allocator, path, Fake.unexpectedQuery, Fake.unexpected));
}

test "SET text editor query failure and invalid bounded ProgID never dispatch the shell" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Fake = struct {
        const Mode = enum { failure, partial_success, oversized, zero_length, empty, unterminated, embedded_null, short_count };
        var mode: Mode = .failure;
        fn query(_: u32, _: u32, _: [*:0]const u16, _: ?[*:0]const u16, out: ?[*]u16, len: *u32) !windows.HRESULT {
            switch (mode) {
                .failure => return @bitCast(@as(u32, 0x80070483)),
                .partial_success => return 1,
                .oversized => len.* += 1,
                .zero_length => len.* = 0,
                .empty => {
                    out.?[0] = 0;
                    len.* = 1;
                },
                .unterminated, .embedded_null, .short_count => {
                    @memcpy(out.?[0..4], &[_]u16{ 'A', 'B', 'C', 0 });
                    len.* = switch (mode) {
                        .embedded_null => 4,
                        .short_count => 2,
                        else => 3,
                    };
                    if (mode == .embedded_null) out.?[1] = 0;
                },
            }
            return 0;
        }
        fn unexpected(_: *ShellExecuteInfo) !bool {
            return error.UnexpectedShellDispatch;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "font-size = 12\n" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "config.ghostty");
    defer std.testing.allocator.free(path);
    for (std.enums.values(Fake.Mode)) |mode| {
        Fake.mode = mode;
        const expected = switch (mode) {
            .failure, .partial_success => error.TextEditorAssociationUnavailable,
            else => error.InvalidTextEditorAssociation,
        };
        try std.testing.expectError(expected, openWith(std.testing.allocator, path, Fake.query, Fake.unexpected));
    }
}
