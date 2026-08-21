//! Native DirectComposition driver for the Win32 shell compositor boundary.
//!
//! This module owns only top-level shell composition resources. It never sees
//! terminal child HWNDs, HDCs, HGLRCs, or SwapBuffers; terminal presentation
//! therefore remains exclusively owned by the existing WGL renderer.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("win32/sys.zig");
const boundary = @import("win32_compositor.zig");
const content_native = @import("win32_compositor_content_native.zig");
const window_content_native = @import("win32_compositor_window_content_native.zig");

const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const GUID = windows.GUID;
const HRESULT = windows.HRESULT;
const BOOL = i32;
const UINT = u32;
const HMODULE = ?*anyopaque;
const HWND = sys.HWND;

const RECT = sys.RECT;

const S_OK: HRESULT = 0;
const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
const GA_ROOT: u32 = 2;

const DXGI_ERROR_DEVICE_HUNG: HRESULT = @bitCast(@as(u32, 0x887A0006));
const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
const DXGI_ERROR_DRIVER_INTERNAL_ERROR: HRESULT = @bitCast(@as(u32, 0x887A0020));
const DXGI_ERROR_ACCESS_LOST: HRESULT = @bitCast(@as(u32, 0x887A0026));

const IID_IDXGIDevice = GUID.parse("{54EC77FA-1377-44E6-8C32-88FD5F44C84C}");
const IID_IDCompositionDevice = GUID.parse("{C37EA93A-E7AA-450D-B16F-9746CB0407F3}");

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

const IUnknown = extern struct {
    vtbl: *const IUnknownVtbl,
};

const IDCompositionDeviceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    Commit: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    WaitForCommitCompletion: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    GetFrameStatistics: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    CreateTargetForHwnd: *const fn (*anyopaque, HWND, BOOL, *?*IDCompositionTarget) callconv(.winapi) HRESULT,
    CreateVisual: *const fn (*anyopaque, *?*IDCompositionVisual) callconv(.winapi) HRESULT,
};

const IDCompositionDevice = extern struct {
    vtbl: *const IDCompositionDeviceVtbl,
};

const IDCompositionTargetVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    SetRoot: *const fn (*anyopaque, ?*IDCompositionVisual) callconv(.winapi) HRESULT,
};

const IDCompositionTarget = extern struct {
    vtbl: *const IDCompositionTargetVtbl,
};

// Only IUnknown is used on visuals. The native vtable has more methods, but
// declaring unused slots would enlarge the ABI surface without adding safety.
const IDCompositionVisual = extern struct {
    vtbl: *const IUnknownVtbl,
};

const D3D11CreateDeviceFn = *const fn (
    adapter: ?*anyopaque,
    driver_type: u32,
    software: HMODULE,
    flags: UINT,
    feature_levels: ?[*]const u32,
    feature_level_count: UINT,
    sdk_version: UINT,
    device: *?*anyopaque,
    selected_feature_level: ?*u32,
    immediate_context: ?*?*anyopaque,
) callconv(.winapi) HRESULT;

const DCompositionCreateDeviceFn = *const fn (
    rendering_device: ?*anyopaque,
    iid: *const GUID,
    device: *?*anyopaque,
) callconv(.winapi) HRESULT;

const IsWindowFn = *const fn (HWND) callconv(.winapi) BOOL;
const GetAncestorFn = *const fn (HWND, UINT) callconv(.winapi) ?HWND;

const Api = struct {
    d3d11_module: HMODULE = null,
    dcomp_module: HMODULE = null,
    d2d1_module: HMODULE = null,
    dwrite_module: HMODULE = null,
    user32_module: HMODULE = null,
    d3d11_create_device: ?D3D11CreateDeviceFn = null,
    dcomposition_create_device: ?DCompositionCreateDeviceFn = null,
    is_window: ?IsWindowFn = null,
    get_ancestor: ?GetAncestorFn = null,

    fn load() boundary.DriverError!Api {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;

        var self: Api = .{};
        errdefer self.unload();
        self.d3d11_module = sys.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
            return error.Unavailable;
        self.dcomp_module = sys.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse
            return error.Unavailable;
        self.d2d1_module = sys.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d2d1.dll")) orelse
            return error.Unavailable;
        self.dwrite_module = sys.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dwrite.dll")) orelse
            return error.Unavailable;
        self.user32_module = sys.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse
            return error.Unavailable;

        self.d3d11_create_device = loadProc(D3D11CreateDeviceFn, self.d3d11_module, "D3D11CreateDevice") orelse
            return error.Unavailable;
        self.dcomposition_create_device = loadProc(DCompositionCreateDeviceFn, self.dcomp_module, "DCompositionCreateDevice") orelse
            return error.Unavailable;
        // Drawing factories are capability prerequisites, but no factory is
        // created until shell content actually needs D2D/DWrite resources.
        if (sys.GetProcAddress(self.d2d1_module, "D2D1CreateFactory") == null) return error.Unavailable;
        if (sys.GetProcAddress(self.dwrite_module, "DWriteCreateFactory") == null) return error.Unavailable;
        self.is_window = loadProc(IsWindowFn, self.user32_module, "IsWindow") orelse
            return error.Unavailable;
        self.get_ancestor = loadProc(GetAncestorFn, self.user32_module, "GetAncestor") orelse
            return error.Unavailable;
        return self;
    }

    fn unload(self: *Api) void {
        if (comptime builtin.os.tag != .windows) {
            self.* = .{};
            return;
        }
        self.d3d11_create_device = null;
        self.dcomposition_create_device = null;
        self.is_window = null;
        self.get_ancestor = null;
        if (self.user32_module) |module| _ = sys.FreeLibrary(module);
        if (self.dwrite_module) |module| _ = sys.FreeLibrary(module);
        if (self.d2d1_module) |module| _ = sys.FreeLibrary(module);
        if (self.dcomp_module) |module| _ = sys.FreeLibrary(module);
        if (self.d3d11_module) |module| _ = sys.FreeLibrary(module);
        self.* = .{};
    }
};

fn loadProc(comptime T: type, module: HMODULE, comptime name: [:0]const u8) ?T {
    const raw = sys.GetProcAddress(module, name.ptr) orelse return null;
    return @ptrCast(@alignCast(raw));
}

const Target = struct {
    hwnd: boundary.WindowHandle,
    target: ?*IDCompositionTarget = null,
    visual: ?*IDCompositionVisual = null,
    shell_content: ?window_content_native.WindowContent = null,

    fn releaseNative(self: *Target) void {
        if (self.shell_content) |*content| content.deinit();
        self.shell_content = null;
        self.releaseCompositionObjects();
    }

    fn releaseCompositionObjects(self: *Target) void {
        releaseCom(self.visual);
        self.visual = null;
        releaseCom(self.target);
        self.target = null;
    }
};

pub const ChromeText = struct {
    text: []const u16,
    left_px: i32,
    top_px: i32,
    right_px: i32,
    bottom_px: i32,
    color_ref: u32,
};

/// Stable-address native driver. Keep this value at a fixed address for as
/// long as its `boundary.Driver` interface can be called.
pub const NativeDriver = struct {
    allocator: Allocator,
    api: Api = .{},
    d3d_device: ?*anyopaque = null,
    dxgi_device: ?*anyopaque = null,
    dcomp_device: ?*IDCompositionDevice = null,
    content: content_native.ResourceGraph = .{},
    targets: std.ArrayListUnmanaged(Target) = .empty,
    started: bool = false,

    pub fn init(allocator: Allocator) NativeDriver {
        return .{ .allocator = allocator };
    }

    pub fn interface(self: *NativeDriver) boundary.Driver {
        return .{
            .context = self,
            .start_fn = startThunk,
            .stop_fn = stopThunk,
            .attach_window_fn = attachWindowThunk,
            .detach_window_fn = detachWindowThunk,
            .commit_fn = commitThunk,
            .recover_fn = recoverThunk,
        };
    }

    pub fn isStarted(self: *const NativeDriver) bool {
        return self.started;
    }

    pub fn targetCount(self: *const NativeDriver) u32 {
        return @intCast(self.targets.items.len);
    }

    pub fn shellContentReady(self: *const NativeDriver) bool {
        return self.content.isReady();
    }

    pub fn shellContentContext(self: *const NativeDriver) ?*anyopaque {
        return self.content.contextHandle();
    }

    pub fn shellTextFormat(self: *const NativeDriver) ?*anyopaque {
        return self.content.textFormatHandle();
    }

    /// Resize the shell-only composition surface to the current client area.
    /// The caller retains commit batching authority.
    pub fn resizeWindow(self: *NativeDriver, window: boundary.WindowHandle) boundary.DriverError!bool {
        if (!self.started) return error.InitializationFailed;
        const index = self.findTarget(window) orelse return error.AttachFailed;
        const hwnd: HWND = @ptrFromInt(window);
        const geometry = clientGeometry(hwnd) orelse return error.AttachFailed;
        const content = if (self.targets.items[index].shell_content) |*value|
            value
        else
            return error.AttachFailed;
        const changed = content.resizeDips(
            geometry.width_dip,
            geometry.height_dip,
            geometry.dpi,
        ) catch |err| return mapContentError(err, error.AttachFailed);
        if (changed) try renderNeutralContent(content);
        return changed;
    }

    /// Replaces the shell composition layer with one transparent DWrite text
    /// zone. This is intentionally narrow: callers migrate isolated chrome
    /// zones while child HWND controls and terminal WGL content stay owned by
    /// their established paths. An empty string clears the migrated zone.
    pub fn renderWindowChromeText(
        self: *NativeDriver,
        window: boundary.WindowHandle,
        args: ChromeText,
    ) boundary.DriverError!void {
        if (!self.started) return error.InitializationFailed;
        const index = self.findTarget(window) orelse return error.AttachFailed;
        const content = if (self.targets.items[index].shell_content) |*value|
            value
        else
            return error.AttachFailed;
        const px_to_dip = 96.0 / content.dpi;
        content.renderText(.{
            .text = args.text,
            .background = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .foreground = colorRefToD2d(args.color_ref),
            .padding_dip = 0,
            .layout_dip = .{
                .left = @as(f32, @floatFromInt(args.left_px)) * px_to_dip,
                .top = @as(f32, @floatFromInt(args.top_px)) * px_to_dip,
                .right = @as(f32, @floatFromInt(@max(args.left_px, args.right_px))) * px_to_dip,
                .bottom = @as(f32, @floatFromInt(@max(args.top_px, args.bottom_px))) * px_to_dip,
            },
        }) catch |err| return mapContentError(err, error.AttachFailed);
    }

    fn fromContext(context: *anyopaque) *NativeDriver {
        return @ptrCast(@alignCast(context));
    }

    fn startThunk(context: *anyopaque) boundary.DriverError!void {
        return fromContext(context).start();
    }

    fn stopThunk(context: *anyopaque) void {
        fromContext(context).stop();
    }

    fn attachWindowThunk(context: *anyopaque, window: boundary.WindowHandle) boundary.DriverError!u32 {
        return fromContext(context).attachWindow(window);
    }

    fn detachWindowThunk(context: *anyopaque, window: boundary.WindowHandle) boundary.DriverError!u32 {
        return fromContext(context).detachWindow(window);
    }

    fn commitThunk(context: *anyopaque) boundary.DriverError!void {
        return fromContext(context).commit();
    }

    fn recoverThunk(context: *anyopaque) boundary.DriverError!u32 {
        return fromContext(context).recover();
    }

    fn start(self: *NativeDriver) boundary.DriverError!void {
        if (self.started) return;
        // Make retry after any partial or failed initialization deterministic.
        self.releaseDeviceGraph();
        self.api.unload();
        self.api = try Api.load();
        errdefer {
            self.content.stop();
            self.releaseDeviceGraph();
            self.api.unload();
        }
        try self.createDeviceGraph();
        self.content.start(self.dxgi_device.?) catch |err| return switch (err) {
            error.DeviceLost => error.DeviceLost,
            error.Unavailable, error.InitializationFailed => error.InitializationFailed,
        };
        self.started = true;
    }

    fn stop(self: *NativeDriver) void {
        for (self.targets.items) |*target| target.releaseNative();
        self.targets.deinit(self.allocator);
        self.targets = .empty;
        self.content.stop();
        self.releaseDeviceGraph();
        self.api.unload();
        self.started = false;
    }

    fn createDeviceGraph(self: *NativeDriver) boundary.DriverError!void {
        const create_d3d = self.api.d3d11_create_device orelse return error.Unavailable;
        var device: ?*anyopaque = null;
        var hr = create_d3d(
            null,
            D3D_DRIVER_TYPE_HARDWARE,
            null,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            null,
            0,
            D3D11_SDK_VERSION,
            &device,
            null,
            null,
        );
        if (failed(hr)) {
            releaseCom(device);
            device = null;
            hr = create_d3d(
                null,
                D3D_DRIVER_TYPE_WARP,
                null,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                null,
                0,
                D3D11_SDK_VERSION,
                &device,
                null,
                null,
            );
        }
        if (failed(hr) or device == null) return mapInitializationError(hr);
        self.d3d_device = device;
        errdefer {
            releaseCom(self.d3d_device);
            self.d3d_device = null;
        }

        var dxgi: ?*anyopaque = null;
        hr = queryInterface(device.?, &IID_IDXGIDevice, &dxgi);
        if (failed(hr) or dxgi == null) return mapInitializationError(hr);
        self.dxgi_device = dxgi;
        errdefer {
            releaseCom(self.dxgi_device);
            self.dxgi_device = null;
        }

        const create_dcomp = self.api.dcomposition_create_device orelse return error.Unavailable;
        var dcomp_raw: ?*anyopaque = null;
        hr = create_dcomp(dxgi, &IID_IDCompositionDevice, &dcomp_raw);
        if (failed(hr) or dcomp_raw == null) return mapInitializationError(hr);
        self.dcomp_device = @ptrCast(@alignCast(dcomp_raw.?));
    }

    fn releaseDeviceGraph(self: *NativeDriver) void {
        releaseCom(self.dcomp_device);
        self.dcomp_device = null;
        releaseCom(self.dxgi_device);
        self.dxgi_device = null;
        releaseCom(self.d3d_device);
        self.d3d_device = null;
    }

    fn attachWindow(self: *NativeDriver, window: boundary.WindowHandle) boundary.DriverError!u32 {
        if (!self.started) return error.InitializationFailed;
        if (self.findTarget(window) != null) return self.targetCount();
        if (!self.isTopLevelWindow(window)) return error.AttachFailed;

        var entry: Target = .{ .hwnd = window };
        errdefer entry.releaseNative();
        try self.createTargetNative(&entry);
        self.targets.append(self.allocator, entry) catch return error.AttachFailed;
        return self.targetCount();
    }

    fn detachWindow(self: *NativeDriver, window: boundary.WindowHandle) boundary.DriverError!u32 {
        if (!self.started) return error.InitializationFailed;
        const index = self.findTarget(window) orelse return self.targetCount();
        // Detaching the root before releasing it prevents a later commit from
        // retaining shell content for a window whose Host is already closing.
        // Keep the entry in the authoritative set until SetRoot succeeds: on
        // device loss, recover() must still know which HWNDs to reconstruct.
        if (self.targets.items[index].target) |target| {
            const hr = target.vtbl.SetRoot(target, null);
            if (failed(hr)) return mapOperationError(hr, error.DetachFailed);
        }
        var removed = self.targets.orderedRemove(index);
        removed.releaseNative();
        return self.targetCount();
    }

    fn commit(self: *NativeDriver) boundary.DriverError!void {
        if (!self.started) return error.InitializationFailed;
        const device = self.dcomp_device orelse return error.InitializationFailed;
        const hr = device.vtbl.Commit(device);
        if (failed(hr)) return mapOperationError(hr, error.CommitFailed);
    }

    fn recover(self: *NativeDriver) boundary.DriverError!u32 {
        if (!self.started) return error.RecoveryFailed;
        for (self.targets.items) |*target| {
            if (target.shell_content) |*content| content.noteDeviceLoss();
            target.releaseCompositionObjects();
        }
        self.content.noteDeviceLoss();
        self.releaseDeviceGraph();

        self.createDeviceGraph() catch {
            self.content.stop();
            return error.RecoveryFailed;
        };
        self.content.recover(self.dxgi_device.?) catch {
            self.content.stop();
            self.releaseDeviceGraph();
            return error.RecoveryFailed;
        };
        errdefer {
            for (self.targets.items) |*target| target.releaseNative();
            self.content.stop();
            self.releaseDeviceGraph();
        }
        for (self.targets.items) |*target| {
            if (!self.isTopLevelWindow(target.hwnd)) return error.RecoveryFailed;
            self.createTargetNative(target) catch return error.RecoveryFailed;
        }
        if (self.targets.items.len > 0) try self.commit();
        return self.targetCount();
    }

    fn createTargetNative(self: *NativeDriver, entry: *Target) boundary.DriverError!void {
        const device = self.dcomp_device orelse return error.InitializationFailed;
        const hwnd: HWND = @ptrFromInt(entry.hwnd);
        var target: ?*IDCompositionTarget = null;
        var hr = device.vtbl.CreateTargetForHwnd(device, hwnd, 0, &target);
        if (failed(hr) or target == null) return mapOperationError(hr, error.AttachFailed);
        entry.target = target;

        var visual: ?*IDCompositionVisual = null;
        hr = device.vtbl.CreateVisual(device, &visual);
        if (failed(hr) or visual == null) return mapOperationError(hr, error.AttachFailed);
        entry.visual = visual;

        hr = target.?.vtbl.SetRoot(target.?, visual);
        if (failed(hr)) return mapOperationError(hr, error.AttachFailed);

        const context = self.content.contextHandle() orelse return error.InitializationFailed;
        const text_format = self.content.textFormatHandle() orelse return error.InitializationFailed;
        const geometry = clientGeometry(hwnd) orelse return error.AttachFailed;
        const bindings: window_content_native.Bindings = .{
            .dcomp_device = @ptrCast(device),
            .visual = @ptrCast(visual.?),
            .d2d_context = context,
            .text_format = text_format,
        };
        if (entry.shell_content) |*content| {
            content.recover(bindings) catch |err| return mapContentError(err, error.AttachFailed);
        } else {
            entry.shell_content = window_content_native.WindowContent.init(
                bindings,
                geometry.width_dip,
                geometry.height_dip,
                geometry.dpi,
            ) catch |err| return mapContentError(err, error.AttachFailed);
        }
        if (entry.shell_content) |*content| {
            try renderNeutralContent(content);
        }
    }

    fn findTarget(self: *const NativeDriver, window: boundary.WindowHandle) ?usize {
        for (self.targets.items, 0..) |target, index| {
            if (target.hwnd == window) return index;
        }
        return null;
    }

    fn isTopLevelWindow(self: *const NativeDriver, window: boundary.WindowHandle) bool {
        if (window == 0) return false;
        const is_window = self.api.is_window orelse return false;
        const get_ancestor = self.api.get_ancestor orelse return false;
        const hwnd: HWND = @ptrFromInt(window);
        if (is_window(hwnd) == 0) return false;
        const ancestor = get_ancestor(hwnd, GA_ROOT) orelse return false;
        return ancestor == hwnd;
    }
};

const ClientGeometry = struct {
    width_dip: f32,
    height_dip: f32,
    dpi: f32,
};

fn clientGeometry(hwnd: HWND) ?ClientGeometry {
    var rect: RECT = undefined;
    if (sys.GetClientRect(hwnd, &rect) == 0) return null;
    const dpi_value = sys.GetDpiForWindow(hwnd);
    const dpi: f32 = @floatFromInt(if (dpi_value == 0) @as(UINT, 96) else dpi_value);
    const scale = 96.0 / dpi;
    return .{
        .width_dip = @as(f32, @floatFromInt(@max(0, rect.right - rect.left))) * scale,
        .height_dip = @as(f32, @floatFromInt(@max(0, rect.bottom - rect.top))) * scale,
        .dpi = dpi,
    };
}

fn mapContentError(
    err: window_content_native.ContentError,
    fallback: boundary.DriverError,
) boundary.DriverError {
    return switch (err) {
        error.DeviceLost => error.DeviceLost,
        else => fallback,
    };
}

fn renderNeutralContent(content: *window_content_native.WindowContent) boundary.DriverError!void {
    // Keep the migration surface visually neutral until native chrome parity
    // is complete. Child terminal HWNDs and the established GDI shell remain
    // authoritative while D2D content is adopted zone by zone; an opaque
    // bootstrap clear would hide them.
    content.renderText(.{
        .text = &.{},
        .background = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .foreground = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    }) catch |err| return mapContentError(err, error.AttachFailed);
}

fn colorRefToD2d(color: u32) window_content_native.Color {
    const scale: f32 = 1.0 / 255.0;
    return .{
        .r = @as(f32, @floatFromInt(color & 0xff)) * scale,
        .g = @as(f32, @floatFromInt((color >> 8) & 0xff)) * scale,
        .b = @as(f32, @floatFromInt((color >> 16) & 0xff)) * scale,
        .a = 1,
    };
}

fn queryInterface(value: *anyopaque, iid: *const GUID, out: *?*anyopaque) HRESULT {
    const unknown: *IUnknown = @ptrCast(@alignCast(value));
    return unknown.vtbl.QueryInterface(value, iid, out);
}

fn releaseCom(value: anytype) void {
    if (value) |raw| {
        const unknown: *IUnknown = @ptrCast(@alignCast(raw));
        _ = unknown.vtbl.Release(raw);
    }
}

fn failed(hr: HRESULT) bool {
    return hr < S_OK;
}

fn isDeviceLost(hr: HRESULT) bool {
    return hr == DXGI_ERROR_DEVICE_HUNG or
        hr == DXGI_ERROR_DEVICE_REMOVED or
        hr == DXGI_ERROR_DEVICE_RESET or
        hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR or
        hr == DXGI_ERROR_ACCESS_LOST;
}

fn mapInitializationError(hr: HRESULT) boundary.DriverError {
    return if (isDeviceLost(hr)) error.DeviceLost else error.InitializationFailed;
}

fn mapOperationError(hr: HRESULT, fallback: boundary.DriverError) boundary.DriverError {
    return if (isDeviceLost(hr)) error.DeviceLost else fallback;
}

test "driver ABI uses pointer-sized COM interfaces" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IUnknown));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IDCompositionDevice));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IDCompositionTarget));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IDCompositionVisual));
}

test "device loss HRESULT classification is exact" {
    try std.testing.expect(isDeviceLost(DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expect(isDeviceLost(DXGI_ERROR_DEVICE_RESET));
    try std.testing.expect(!isDeviceLost(@bitCast(@as(u32, 0x80004005))));
}

test "stop is idempotent after zero and partial initialization" {
    var driver = NativeDriver.init(std.testing.allocator);
    driver.stop();
    driver.stop();
    try std.testing.expect(!driver.isStarted());
    try std.testing.expectEqual(@as(u32, 0), driver.targetCount());
}

test "native initialization remains truthful and never implies a target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const capability = boundary.probeNativeCapability();
    var driver = NativeDriver.init(std.testing.allocator);
    var backend = boundary.Backend.init(capability, driver.interface());
    defer backend.deinit();

    try std.testing.expect(!backend.status().compositionActive());
    if (backend.status().state == .ready) {
        try std.testing.expect(driver.isStarted());
        try std.testing.expectEqual(@as(u32, 0), driver.targetCount());
        try std.testing.expectError(error.DriverFailure, backend.attachWindow(1));
        try std.testing.expectEqual(boundary.State.fallback, backend.status().state);
        try std.testing.expect(!driver.isStarted());
    } else {
        try std.testing.expectEqual(boundary.State.fallback, backend.status().state);
    }
}

test "native driver attaches commits and detaches a real top-level HWND" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var driver = NativeDriver.init(std.testing.allocator);
    var backend = boundary.Backend.init(boundary.probeNativeCapability(), driver.interface());
    defer backend.deinit();
    if (backend.status().state != .ready) return error.SkipZigTest;

    const hwnd = sys.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("winghostty compositor smoke"),
        0,
        0,
        0,
        32,
        32,
        null,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = sys.DestroyWindow(hwnd);

    try backend.attachWindow(@intFromPtr(hwnd));
    try std.testing.expect(backend.status().compositionActive());
    try std.testing.expectEqual(@as(u32, 1), driver.targetCount());
    try std.testing.expect(driver.shellContentReady());
    try std.testing.expect(driver.shellContentContext() != null);
    const original_text_format = driver.shellTextFormat();
    try std.testing.expect(original_text_format != null);
    try driver.renderWindowChromeText(@intFromPtr(hwnd), .{
        .text = std.unicode.utf8ToUtf16LeStringLiteral("composed banner"),
        .left_px = 2,
        .top_px = 2,
        .right_px = 30,
        .bottom_px = 20,
        .color_ref = 0x00ff8040,
    });
    try backend.commit();

    // Exercise the same reconstruction path used after a real DXGI loss.
    // markDeviceLost does not touch the terminal WGL renderer or its child.
    backend.markDeviceLost();
    try backend.recover();
    try std.testing.expect(backend.status().compositionActive());
    try std.testing.expectEqual(@as(u32, 1), driver.targetCount());
    try std.testing.expect(driver.shellContentReady());
    try std.testing.expect(driver.shellContentContext() != null);
    try std.testing.expectEqual(original_text_format, driver.shellTextFormat());
    try driver.renderWindowChromeText(@intFromPtr(hwnd), .{
        .text = &.{},
        .left_px = 0,
        .top_px = 0,
        .right_px = 0,
        .bottom_px = 0,
        .color_ref = 0,
    });
    try backend.commit();

    try backend.detachWindow(@intFromPtr(hwnd));
    try std.testing.expectEqual(boundary.State.ready, backend.status().state);
    try std.testing.expectEqual(@as(u32, 0), driver.targetCount());
}

test "terminal presentation remains outside the native shell driver" {
    try std.testing.expectEqual(
        boundary.TerminalPresentation.wgl_swap_buffers_unchanged,
        boundary.terminal_presentation,
    );
}
