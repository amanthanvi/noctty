//! Prefer a bundled OpenConsole `conpty.dll` beside the exe (C05).
//!
//! In-box `kernel32.CreatePseudoConsole` silently strips Kitty APC and
//! Sixel DCS on older conhost builds. When `conpty.dll` is present next
//! to the executable, load `CreatePseudoConsole` from it. Otherwise fall
//! back to kernel32 and log a degraded-mode warning.
//!
//! ponytail: this loader does not ship OpenConsole itself (Microsoft
//! redistributable, version-pinned per release). Place `conpty.dll` +
//! matching `OpenConsole.exe` beside the exe to opt in.

const std = @import("std");
const builtin = @import("builtin");
const win = @import("os/main.zig").windows;

pub const dll_name = "conpty.dll";
pub const openconsole_name = "OpenConsole.exe";

pub const Source = enum {
    bundled,
    inbox,
};

pub const Api = struct {
    source: Source,
    create: *const @TypeOf(win.exp.kernel32.CreatePseudoConsole),
    resize: *const @TypeOf(win.exp.kernel32.ResizePseudoConsole),
    close: *const @TypeOf(win.exp.kernel32.ClosePseudoConsole),
};

var resolve_mu: std.Thread.Mutex = .{};
var resolved: ?Api = null;

pub fn inboxApi() Api {
    return .{
        .source = .inbox,
        .create = win.exp.kernel32.CreatePseudoConsole,
        .resize = win.exp.kernel32.ResizePseudoConsole,
        .close = win.exp.kernel32.ClosePseudoConsole,
    };
}

/// Resolve once per process. Prefer side-by-side `conpty.dll` so
/// `kernel32.CreatePseudoConsole` cannot ignore a bundled OpenConsole.
pub fn resolve() Api {
    if (comptime builtin.os.tag != .windows) return inboxApi();
    resolve_mu.lock();
    defer resolve_mu.unlock();
    if (resolved) |api| return api;
    const api = resolveOnce();
    resolved = api;
    return api;
}

fn resolveOnce() Api {
    const alloc = std.heap.page_allocator;
    const exe = std.fs.selfExePathAlloc(alloc) catch return inboxApi();
    defer alloc.free(exe);
    if (!bundledPairPresent(exe)) return inboxApi();
    return loadBundled(exe) orelse inboxApi();
}

fn loadBundled(exe_path: []const u8) ?Api {
    const alloc = std.heap.page_allocator;
    const dll_path = adjacentDllPath(alloc, exe_path) catch return null;
    defer alloc.free(dll_path);
    const dll_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, dll_path) catch return null;
    defer alloc.free(dll_w);

    const module = std.os.windows.kernel32.LoadLibraryW(dll_w.ptr) orelse return null;
    const create = std.os.windows.kernel32.GetProcAddress(module, "CreatePseudoConsole") orelse {
        _ = std.os.windows.FreeLibrary(module);
        return null;
    };
    const resize = std.os.windows.kernel32.GetProcAddress(module, "ResizePseudoConsole") orelse {
        _ = std.os.windows.FreeLibrary(module);
        return null;
    };
    const close = std.os.windows.kernel32.GetProcAddress(module, "ClosePseudoConsole") orelse {
        _ = std.os.windows.FreeLibrary(module);
        return null;
    };
    return .{
        .source = .bundled,
        .create = @ptrCast(create),
        .resize = @ptrCast(resize),
        .close = @ptrCast(close),
    };
}

pub fn adjacentDllPath(alloc: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExePath;
    return std.fs.path.join(alloc, &.{ dir, dll_name });
}

pub fn adjacentOpenConsolePath(alloc: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExePath;
    return std.fs.path.join(alloc, &.{ dir, openconsole_name });
}

pub fn bundledPairPresent(exe_dir_or_exe: []const u8) bool {
    const dir = std.fs.path.dirname(exe_dir_or_exe) orelse exe_dir_or_exe;
    var dir_handle = std.fs.openDirAbsolute(dir, .{}) catch return false;
    defer dir_handle.close();
    dir_handle.access(dll_name, .{}) catch return false;
    dir_handle.access(openconsole_name, .{}) catch return false;
    return true;
}

pub fn degradedWarning() []const u8 {
    return "using OS conhost (Kitty graphics and Sixel may be stripped); place conpty.dll + OpenConsole.exe beside the exe to prefer bundled ConPTY";
}

test "adjacent paths join beside exe" {
    const testing = std.testing;
    const dll = try adjacentDllPath(testing.allocator, "C:\\apps\\winghostty\\winghostty.exe");
    defer testing.allocator.free(dll);
    try testing.expectEqualStrings("C:\\apps\\winghostty\\conpty.dll", dll);

    const oc = try adjacentOpenConsolePath(testing.allocator, "C:\\apps\\winghostty\\winghostty.exe");
    defer testing.allocator.free(oc);
    try testing.expectEqualStrings("C:\\apps\\winghostty\\OpenConsole.exe", oc);
}

test "degraded warning names Kitty and Sixel" {
    try std.testing.expect(std.mem.indexOf(u8, degradedWarning(), "Kitty") != null);
    try std.testing.expect(std.mem.indexOf(u8, degradedWarning(), "Sixel") != null);
}
