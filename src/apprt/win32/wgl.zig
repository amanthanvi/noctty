//! Lazy, process-lifetime OpenGL entry points. Importing this module does not
//! load OpenGL; the first WGL call or core symbol lookup loads System32 only.
const std = @import("std");
const win32_sys = @import("sys.zig");
const windows = std.os.windows;
const types = @import("../win32_types.zig");

const Api = struct {
    wglCreateContext: *const fn (types.HDC) callconv(.winapi) types.HGLRC,
    wglDeleteContext: *const fn (types.HGLRC) callconv(.winapi) types.BOOL,
    wglGetCurrentContext: *const fn () callconv(.winapi) types.HGLRC,
    wglGetCurrentDC: *const fn () callconv(.winapi) types.HDC,
    wglGetProcAddress: *const fn ([*:0]const u8) callconv(.winapi) ?*const anyopaque,
    wglMakeCurrent: *const fn (types.HDC, types.HGLRC) callconv(.winapi) types.BOOL,
};

const NativeBackend = struct {
    fn loadLibraryExW(_: *@This(), name: [*:0]const u16, reserved: ?windows.HANDLE, flags: u32) types.HMODULE {
        return win32_sys.LoadLibraryExW(name, reserved, flags);
    }

    fn freeLibrary(_: *@This(), module: types.HMODULE) void {
        _ = win32_sys.FreeLibrary(@ptrCast(module.?));
    }

    fn getProcAddress(_: *@This(), module: types.HMODULE, name: [*:0]const u8) ?*const anyopaque {
        return win32_sys.GetProcAddress(@ptrCast(module.?), name);
    }

    fn getLastError(_: *@This()) u32 {
        return @backingInt(std.os.windows.GetLastError());
    }

    fn setLastError(_: *@This(), err: u32) void {
        win32_sys.SetLastError(err);
    }
};

// The backend is instance-owned so tests can exercise the same initialization
// and dispatch paths without loading OpenGL or resetting shared global state.
fn Loader(comptime Backend: type) type {
    return struct {
        const Self = @This();

        backend: Backend = .{},
        initialized: std.atomic.Value(bool) = .init(false),
        mutex: std.Thread.Mutex = .{},
        module: types.HMODULE = null,
        api: ?Api = null,
        load_error: std.atomic.Value(u32) = .init(0),

        fn getApi(self: *Self) ?*const Api {
            if (self.initialized.load(.acquire)) return &self.api.?;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.initialized.load(.monotonic)) return &self.api.?;

            // Keep this reference for the process lifetime, as the original
            // static import did. Never search the application directory/CWD.
            const module = self.backend.loadLibraryExW(
                std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll"),
                null,
                0x00000800, // LOAD_LIBRARY_SEARCH_SYSTEM32
            ) orelse return self.loadFailed(self.backend.getLastError());
            var api: Api = undefined;
            inline for (@typeInfo(Api).@"struct".fields) |field| {
                const ptr = self.backend.getProcAddress(module, field.name) orelse {
                    const err = self.backend.getLastError();
                    self.backend.freeLibrary(module);
                    return self.loadFailed(err);
                };
                @field(api, field.name) = @ptrCast(@alignCast(ptr));
            }
            self.module = module;
            self.api = api;
            self.load_error.store(0, .monotonic);
            self.initialized.store(true, .release);
            return &self.api.?;
        }

        /// Record `err` for `lastLoadError` and leave it as the thread's last
        /// error for the caller of the wrapper that triggered the load.
        fn loadFailed(self: *Self, err: u32) ?*const Api {
            self.load_error.store(err, .monotonic);
            self.backend.setLastError(err);
            return null;
        }

        fn lastLoadError(self: *Self) u32 {
            // An error inspection alone must not cause a DLL load.
            return self.load_error.load(.monotonic);
        }

        fn createContext(self: *Self, hdc: types.HDC) types.HGLRC {
            const api = self.getApi() orelse return null;
            return api.wglCreateContext(hdc);
        }

        fn deleteContext(self: *Self, hglrc: types.HGLRC) types.BOOL {
            const api = self.getApi() orelse return 0;
            return api.wglDeleteContext(hglrc);
        }

        fn getCurrentContext(self: *Self) types.HGLRC {
            const api = self.getApi() orelse return null;
            return api.wglGetCurrentContext();
        }

        fn getCurrentDC(self: *Self) types.HDC {
            const api = self.getApi() orelse return null;
            return api.wglGetCurrentDC();
        }

        fn getProcAddress(self: *Self, name: [*:0]const u8) ?*const anyopaque {
            const api = self.getApi() orelse return null;
            return api.wglGetProcAddress(name);
        }

        fn makeCurrent(self: *Self, hdc: types.HDC, hglrc: types.HGLRC) types.BOOL {
            const api = self.getApi() orelse return 0;
            return api.wglMakeCurrent(hdc, hglrc);
        }

        fn coreProcAddress(self: *Self, name: [*:0]const u8) ?*const anyopaque {
            _ = self.getApi() orelse return null;
            return self.backend.getProcAddress(self.module, name);
        }
    };
}

var loader: Loader(NativeBackend) = .{};

/// Pin System32 OpenGL before GDI's pixel-format APIs can load it by name.
pub fn ensureLoaded() bool {
    return loader.getApi() != null;
}

pub fn wglCreateContext(hdc: types.HDC) callconv(.winapi) types.HGLRC {
    return loader.createContext(hdc);
}

pub fn wglDeleteContext(hglrc: types.HGLRC) callconv(.winapi) types.BOOL {
    return loader.deleteContext(hglrc);
}

pub fn wglGetCurrentContext() callconv(.winapi) types.HGLRC {
    return loader.getCurrentContext();
}

pub fn wglGetCurrentDC() callconv(.winapi) types.HDC {
    return loader.getCurrentDC();
}

pub fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque {
    return loader.getProcAddress(name);
}

pub fn wglMakeCurrent(hdc: types.HDC, hglrc: types.HGLRC) callconv(.winapi) types.BOOL {
    return loader.makeCurrent(hdc, hglrc);
}

/// Resolve OpenGL 1.1 exports from the same System32 module as WGL.
pub fn coreProcAddress(name: [*:0]const u8) ?*const anyopaque {
    return loader.coreProcAddress(name);
}

/// Zero before first use or after successful loading; never triggers loading.
pub fn lastLoadError() windows.Win32Error {
    return @fromBackingInt(@intCast(loader.lastLoadError()));
}

// Tests use fresh loader instances; none touches the process OpenGL loader.
const FakeBackend = struct {
    loads: usize = 0,
    resolutions: usize = 0,
    flags: u32 = 0,
    filename_ok: bool = false,
    reserved_ok: bool = false,
    module_ok: bool = true,
    missing_dll: bool = false,
    missing_export: ?[]const u8 = null,
    last_error: u32 = 0,
    slow_load: bool = false,
    frees: usize = 0,

    const module: *anyopaque = @ptrFromInt(0x1000);
    const context: *anyopaque = @ptrFromInt(0x2000);
    const dc: *anyopaque = @ptrFromInt(0x3000);

    fn loadLibraryExW(self: *@This(), name: [*:0]const u16, reserved: ?windows.HANDLE, flags: u32) types.HMODULE {
        self.loads += 1;
        if (self.slow_load) std.Thread.sleep(20 * std.time.ns_per_ms);
        self.flags = flags;
        self.filename_ok = std.mem.eql(u16, std.mem.span(name), std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll"));
        self.reserved_ok = reserved == null;
        if (self.missing_dll) {
            self.last_error = 126; // ERROR_MOD_NOT_FOUND
            return null;
        }
        return module;
    }

    fn getProcAddress(self: *@This(), handle: types.HMODULE, name: [*:0]const u8) ?*const anyopaque {
        self.resolutions += 1;
        self.module_ok = self.module_ok and handle == module;
        if (self.missing_export) |missing| {
            if (std.mem.eql(u8, std.mem.span(name), missing)) {
                self.last_error = 127; // ERROR_PROC_NOT_FOUND
                return null;
            }
        }
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            if (std.mem.eql(u8, std.mem.span(name), field.name))
                return @ptrCast(&@field(@This(), field.name));
        }
        if (std.mem.eql(u8, std.mem.span(name), "glGetString")) return @ptrCast(&coreProc);
        self.last_error = 127;
        return null;
    }

    fn getLastError(self: *@This()) u32 {
        return self.last_error;
    }

    fn freeLibrary(self: *@This(), handle: types.HMODULE) void {
        self.module_ok = self.module_ok and handle == module;
        self.frees += 1;
        self.last_error = 0; // prove the resolver error survives cleanup
    }

    fn setLastError(self: *@This(), err: u32) void {
        self.last_error = err;
    }

    // Deliberately non-default results prove the resolved exports are called
    // with their original arguments. No global fixture state is needed.
    fn wglCreateContext(hdc: types.HDC) callconv(.winapi) types.HGLRC {
        return if (hdc == dc) context else null;
    }

    fn wglDeleteContext(hglrc: types.HGLRC) callconv(.winapi) types.BOOL {
        return if (hglrc == context) 7 else 0;
    }

    fn wglGetCurrentContext() callconv(.winapi) types.HGLRC {
        return context;
    }

    fn wglGetCurrentDC() callconv(.winapi) types.HDC {
        return dc;
    }

    fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque {
        return if (std.mem.eql(u8, std.mem.span(name), "extension")) @ptrCast(&coreProc) else null;
    }

    fn wglMakeCurrent(hdc: types.HDC, hglrc: types.HGLRC) callconv(.winapi) types.BOOL {
        return if (hdc == dc and hglrc == context) 9 else 0;
    }

    fn coreProc() callconv(.winapi) void {}
};

test "WGL loader stays dormant until first WGL use and caches all six System32 exports" {
    var fixture: Loader(FakeBackend) = .{};
    try std.testing.expectEqual(@as(usize, 0), fixture.backend.loads);
    try std.testing.expectEqual(@as(u32, 0), fixture.lastLoadError());
    try std.testing.expectEqual(@as(usize, 0), fixture.backend.loads);

    try std.testing.expectEqual(FakeBackend.context, fixture.createContext(FakeBackend.dc).?);
    try std.testing.expectEqual(@as(usize, 1), fixture.backend.loads);
    try std.testing.expectEqual(@as(usize, 6), fixture.backend.resolutions);
    try std.testing.expectEqual(@as(u32, 0x800), fixture.backend.flags);
    try std.testing.expect(fixture.backend.filename_ok);
    try std.testing.expect(fixture.backend.reserved_ok);
    try std.testing.expectEqual(@as(types.BOOL, 7), fixture.deleteContext(FakeBackend.context));
    try std.testing.expectEqual(FakeBackend.context, fixture.getCurrentContext().?);
    try std.testing.expectEqual(FakeBackend.dc, fixture.getCurrentDC().?);
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&FakeBackend.coreProc)), fixture.getProcAddress("extension"));
    try std.testing.expectEqual(@as(types.BOOL, 9), fixture.makeCurrent(FakeBackend.dc, FakeBackend.context));
    try std.testing.expectEqual(@as(usize, 1), fixture.backend.loads);
    try std.testing.expectEqual(@as(usize, 6), fixture.backend.resolutions);
    try std.testing.expect(fixture.backend.module_ok);
}

test "WGL core lookup shares the System32 module and can be first use" {
    var fixture: Loader(FakeBackend) = .{};
    try std.testing.expectEqual(@as(?*const anyopaque, @ptrCast(&FakeBackend.coreProc)), fixture.coreProcAddress("glGetString"));
    try std.testing.expectEqual(FakeBackend.context, fixture.getCurrentContext().?);
    try std.testing.expectEqual(@as(usize, 1), fixture.backend.loads);
    try std.testing.expectEqual(@as(usize, 7), fixture.backend.resolutions);
    try std.testing.expect(fixture.backend.module_ok);
    try std.testing.expect(fixture.coreProcAddress("missingCoreProc") == null);
    try std.testing.expectEqual(@as(u32, 127), fixture.backend.last_error);
    try std.testing.expectEqual(@as(u32, 0), fixture.lastLoadError());
}

fn expectUnavailable(fixture: *Loader(FakeBackend), expected_error: u32) !void {
    // A partial API must never dispatch any export: the fake exports above
    // would return non-null/nonzero values for every one of these arguments.
    fixture.backend.last_error = 0;
    try std.testing.expect(fixture.createContext(FakeBackend.dc) == null);
    try std.testing.expectEqual(expected_error, fixture.backend.last_error);
    fixture.backend.last_error = 0;
    try std.testing.expectEqual(@as(types.BOOL, 0), fixture.deleteContext(FakeBackend.context));
    try std.testing.expectEqual(expected_error, fixture.backend.last_error);
    fixture.backend.last_error = 0;
    try std.testing.expect(fixture.getCurrentContext() == null);
    try std.testing.expectEqual(expected_error, fixture.backend.last_error);
    fixture.backend.last_error = 0;
    try std.testing.expect(fixture.getCurrentDC() == null);
    try std.testing.expectEqual(expected_error, fixture.backend.last_error);
    fixture.backend.last_error = 0;
    try std.testing.expect(fixture.getProcAddress("extension") == null);
    try std.testing.expectEqual(expected_error, fixture.backend.last_error);
    fixture.backend.last_error = 0;
    try std.testing.expectEqual(@as(types.BOOL, 0), fixture.makeCurrent(FakeBackend.dc, FakeBackend.context));
    try std.testing.expectEqual(expected_error, fixture.backend.last_error);
    fixture.backend.last_error = 0;
    try std.testing.expect(fixture.coreProcAddress("glGetString") == null);
    try std.testing.expectEqual(expected_error, fixture.backend.last_error);
    try std.testing.expectEqual(expected_error, fixture.lastLoadError());
}

test "WGL missing DLL retries and every wrapper restores the load error" {
    var fixture: Loader(FakeBackend) = .{ .backend = .{ .missing_dll = true } };
    try expectUnavailable(&fixture, 126);
    try std.testing.expectEqual(@as(usize, 7), fixture.backend.loads);
    try std.testing.expectEqual(@as(usize, 0), fixture.backend.resolutions);
    fixture.backend.missing_dll = false;
    try std.testing.expectEqual(FakeBackend.context, fixture.getCurrentContext().?);
    try std.testing.expectEqual(@as(usize, 8), fixture.backend.loads);
    try std.testing.expectEqual(@as(u32, 0), fixture.lastLoadError());
}

test "WGL missing export never publishes a partial API and retries after recovery" {
    inline for (@typeInfo(Api).@"struct".fields, 0..) |field, index| {
        var fixture: Loader(FakeBackend) = .{ .backend = .{ .missing_export = field.name } };
        try expectUnavailable(&fixture, 127);
        try std.testing.expectEqual(@as(usize, 7), fixture.backend.loads);
        try std.testing.expectEqual(7 * (index + 1), fixture.backend.resolutions);
        try std.testing.expectEqual(@as(usize, 7), fixture.backend.frees);
        fixture.backend.missing_export = null;
        try std.testing.expectEqual(FakeBackend.context, fixture.getCurrentContext().?);
        try std.testing.expectEqual(@as(usize, 8), fixture.backend.loads);
        try std.testing.expectEqual(7 * (index + 1) + 6, fixture.backend.resolutions);
        try std.testing.expectEqual(@as(u32, 0), fixture.lastLoadError());
    }
}

test "WGL concurrent first use initializes and publishes exactly once" {
    var fixture: Loader(FakeBackend) = .{ .backend = .{ .slow_load = true } };
    const Worker = struct {
        fn run(state: *Loader(FakeBackend), start: *std.atomic.Value(bool), result: *bool) void {
            while (!start.load(.acquire)) std.Thread.yield() catch {};
            result.* = state.getCurrentContext() == FakeBackend.context;
        }
    };
    var start: std.atomic.Value(bool) = .init(false);
    var results: [8]bool = @splat(false);
    var threads: [8]std.Thread = undefined;
    var spawned: usize = 0;
    defer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
    }
    for (&threads, &results) |*thread, *result| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &fixture, &start, result });
        spawned += 1;
    }
    start.store(true, .release);
    // Join before inspecting the fake backend, which is only written while
    // the loader initialization mutex is held.
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    for (results) |result| try std.testing.expect(result);
    try std.testing.expectEqual(@as(usize, 1), fixture.backend.loads);
    try std.testing.expectEqual(@as(usize, 6), fixture.backend.resolutions);
}
