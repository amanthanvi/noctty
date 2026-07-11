//! Native Direct2D/DirectWrite resources for DirectComposition shell content.
//!
//! This module deliberately accepts an existing `IDXGIDevice` instead of
//! creating or owning D3D11. The Win32 compositor driver remains the sole owner
//! of the D3D11/DXGI/DirectComposition device graph, while this resource graph
//! owns the drawing objects derived from it. Terminal child HWNDs and their WGL
//! renderer are outside this boundary.

const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
const GUID = windows.GUID;
const HRESULT = windows.HRESULT;
const HMODULE = ?*anyopaque;

const S_OK: HRESULT = 0;
const D2D1_FACTORY_TYPE_SINGLE_THREADED: u32 = 0;
const D2D1_DEVICE_CONTEXT_OPTIONS_NONE: u32 = 0;
const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;
const DWRITE_FONT_WEIGHT_NORMAL: u32 = 400;
const DWRITE_FONT_STYLE_NORMAL: u32 = 0;
const DWRITE_FONT_STRETCH_NORMAL: u32 = 5;

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;

const DXGI_ERROR_DEVICE_HUNG: HRESULT = @bitCast(@as(u32, 0x887A0006));
const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
const DXGI_ERROR_DRIVER_INTERNAL_ERROR: HRESULT = @bitCast(@as(u32, 0x887A0020));
const DXGI_ERROR_ACCESS_LOST: HRESULT = @bitCast(@as(u32, 0x887A0026));
const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));

const IID_ID2D1Factory = GUID.parse("{06152247-6F50-465A-9245-118BFD3B6007}");
const IID_IDWriteFactory = GUID.parse("{B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48}");
const IID_IDXGIDevice = GUID.parse("{54EC77FA-1377-44E6-8C32-88FD5F44C84C}");

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

const IUnknown = extern struct {
    vtbl: *const IUnknownVtbl,
};

// ID2D1Device inherits ID2D1Resource. Only CreateDeviceContext is called.
const ID2D1DeviceVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetFactory: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) void,
    CreateDeviceContext: *const fn (*anyopaque, u32, *?*ID2D1DeviceContext) callconv(.winapi) HRESULT,
};

const ID2D1Device = extern struct {
    vtbl: *const ID2D1DeviceVtbl,
};

// No context methods are needed until a DComp surface is attached. Keeping the
// declaration to IUnknown prevents accidental reliance on an incomplete ABI.
const ID2D1DeviceContext = extern struct {
    vtbl: *const IUnknownVtbl,
};

const ID2D1Factory = extern struct {
    vtbl: *const IUnknownVtbl,
};

// IDWriteFactory::CreateTextFormat is vtable slot 15. Unused slots remain
// pointer-sized opaque entries so the called slot stays ABI-exact.
const IDWriteFactoryVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetSystemFontCollection: *const anyopaque,
    CreateCustomFontCollection: *const anyopaque,
    RegisterFontCollectionLoader: *const anyopaque,
    UnregisterFontCollectionLoader: *const anyopaque,
    CreateFontFileReference: *const anyopaque,
    CreateCustomFontFileReference: *const anyopaque,
    CreateFontFace: *const anyopaque,
    CreateRenderingParams: *const anyopaque,
    CreateMonitorRenderingParams: *const anyopaque,
    CreateCustomRenderingParams: *const anyopaque,
    RegisterFontFileLoader: *const anyopaque,
    UnregisterFontFileLoader: *const anyopaque,
    CreateTextFormat: *const fn (
        *anyopaque,
        [*:0]const u16,
        ?*anyopaque,
        u32,
        u32,
        u32,
        f32,
        [*:0]const u16,
        *?*IDWriteTextFormat,
    ) callconv(.winapi) HRESULT,
};

const IDWriteFactory = extern struct {
    vtbl: *const IDWriteFactoryVtbl,
};

const IDWriteTextFormat = extern struct {
    vtbl: *const IUnknownVtbl,
};

const D2D1CreateFactoryFn = *const fn (
    factory_type: u32,
    iid: *const GUID,
    factory_options: ?*const anyopaque,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

const D2D1CreateDeviceFn = *const fn (
    dxgi_device: *anyopaque,
    creation_properties: ?*const anyopaque,
    d2d_device: *?*ID2D1Device,
) callconv(.winapi) HRESULT;

const DWriteCreateFactoryFn = *const fn (
    factory_type: u32,
    iid: *const GUID,
    factory: *?*anyopaque,
) callconv(.winapi) HRESULT;

const D3D11CreateDeviceFn = *const fn (
    adapter: ?*anyopaque,
    driver_type: u32,
    software: HMODULE,
    flags: u32,
    feature_levels: ?[*]const u32,
    feature_level_count: u32,
    sdk_version: u32,
    device: *?*anyopaque,
    selected_feature_level: ?*u32,
    immediate_context: ?*?*anyopaque,
) callconv(.winapi) HRESULT;

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) i32;

pub const ResourceError = error{
    Unavailable,
    InitializationFailed,
    DeviceLost,
};

pub const State = enum {
    stopped,
    ready,
    device_lost,
};

pub const TextSpec = struct {
    family: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    locale: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("en-us"),
    size_dip: f32 = 14.0,
};

const Api = struct {
    d2d1_module: HMODULE = null,
    dwrite_module: HMODULE = null,
    d2d1_create_factory: ?D2D1CreateFactoryFn = null,
    d2d1_create_device: ?D2D1CreateDeviceFn = null,
    dwrite_create_factory: ?DWriteCreateFactoryFn = null,

    fn load() ResourceError!Api {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;

        var self: Api = .{};
        errdefer self.unload();
        self.d2d1_module = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d2d1.dll")) orelse
            return error.Unavailable;
        self.dwrite_module = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dwrite.dll")) orelse
            return error.Unavailable;
        self.d2d1_create_factory = loadProc(D2D1CreateFactoryFn, self.d2d1_module, "D2D1CreateFactory") orelse
            return error.Unavailable;
        self.d2d1_create_device = loadProc(D2D1CreateDeviceFn, self.d2d1_module, "D2D1CreateDevice") orelse
            return error.Unavailable;
        self.dwrite_create_factory = loadProc(DWriteCreateFactoryFn, self.dwrite_module, "DWriteCreateFactory") orelse
            return error.Unavailable;
        return self;
    }

    fn unload(self: *Api) void {
        self.d2d1_create_factory = null;
        self.d2d1_create_device = null;
        self.dwrite_create_factory = null;
        if (comptime builtin.os.tag == .windows) {
            if (self.dwrite_module) |module| _ = FreeLibrary(module);
            if (self.d2d1_module) |module| _ = FreeLibrary(module);
        }
        self.* = .{};
    }
};

/// Stable-address owner of shell drawing resources. All COM objects are
/// released before their supplying DLLs. `stop` is safe after any partial
/// initialization and may be called repeatedly.
pub const ResourceGraph = struct {
    api: Api = .{},
    d2d_factory: ?*ID2D1Factory = null,
    dwrite_factory: ?*IDWriteFactory = null,
    text_format: ?*IDWriteTextFormat = null,
    d2d_device: ?*ID2D1Device = null,
    d2d_context: ?*ID2D1DeviceContext = null,
    state: State = .stopped,
    generation: u64 = 0,

    pub fn start(self: *ResourceGraph, dxgi_device: *anyopaque) ResourceError!void {
        return self.startWithText(dxgi_device, .{});
    }

    pub fn startWithText(
        self: *ResourceGraph,
        dxgi_device: *anyopaque,
        text: TextSpec,
    ) ResourceError!void {
        if (self.state == .ready) return;
        self.stop();
        self.api = try Api.load();
        errdefer self.stop();
        try self.createIndependentResources(text);
        try self.createDeviceResources(dxgi_device);
        self.state = .ready;
        self.generation +%= 1;
    }

    /// Releases only resources tied to the old DXGI device. Factories and the
    /// text format remain valid and are reused during recovery.
    pub fn noteDeviceLoss(self: *ResourceGraph) void {
        if (self.state == .stopped) return;
        self.releaseDeviceResources();
        self.state = .device_lost;
    }

    pub fn recover(self: *ResourceGraph, dxgi_device: *anyopaque) ResourceError!void {
        if (self.state == .stopped or self.d2d_factory == null or self.dwrite_factory == null)
            return error.InitializationFailed;

        self.releaseDeviceResources();
        self.createDeviceResources(dxgi_device) catch |err| {
            self.state = .device_lost;
            return err;
        };
        self.state = .ready;
        self.generation +%= 1;
    }

    pub fn stop(self: *ResourceGraph) void {
        self.releaseDeviceResources();
        releaseCom(self.text_format);
        self.text_format = null;
        releaseCom(self.dwrite_factory);
        self.dwrite_factory = null;
        releaseCom(self.d2d_factory);
        self.d2d_factory = null;
        self.api.unload();
        self.state = .stopped;
    }

    pub fn isReady(self: *const ResourceGraph) bool {
        return self.state == .ready and
            self.d2d_factory != null and
            self.dwrite_factory != null and
            self.text_format != null and
            self.d2d_device != null and
            self.d2d_context != null;
    }

    /// Opaque handles keep Direct2D/DirectWrite declarations private while
    /// giving the rendering integration a narrow, truthful handoff.
    pub fn contextHandle(self: *const ResourceGraph) ?*anyopaque {
        return if (self.d2d_context) |value| @ptrCast(value) else null;
    }

    pub fn textFormatHandle(self: *const ResourceGraph) ?*anyopaque {
        return if (self.text_format) |value| @ptrCast(value) else null;
    }

    fn createIndependentResources(self: *ResourceGraph, text: TextSpec) ResourceError!void {
        const create_d2d_factory = self.api.d2d1_create_factory orelse return error.Unavailable;
        var d2d_raw: ?*anyopaque = null;
        var hr = create_d2d_factory(
            D2D1_FACTORY_TYPE_SINGLE_THREADED,
            &IID_ID2D1Factory,
            null,
            &d2d_raw,
        );
        if (failed(hr) or d2d_raw == null) return mapResourceError(hr);
        self.d2d_factory = @ptrCast(@alignCast(d2d_raw.?));

        const create_dwrite_factory = self.api.dwrite_create_factory orelse return error.Unavailable;
        var dwrite_raw: ?*anyopaque = null;
        hr = create_dwrite_factory(DWRITE_FACTORY_TYPE_SHARED, &IID_IDWriteFactory, &dwrite_raw);
        if (failed(hr) or dwrite_raw == null) return mapResourceError(hr);
        self.dwrite_factory = @ptrCast(@alignCast(dwrite_raw.?));

        var format: ?*IDWriteTextFormat = null;
        hr = self.dwrite_factory.?.vtbl.CreateTextFormat(
            self.dwrite_factory.?,
            text.family,
            null,
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            text.size_dip,
            text.locale,
            &format,
        );
        if (failed(hr) or format == null) return mapResourceError(hr);
        self.text_format = format;
    }

    fn createDeviceResources(self: *ResourceGraph, dxgi_device: *anyopaque) ResourceError!void {
        const create_d2d_device = self.api.d2d1_create_device orelse return error.Unavailable;
        var device: ?*ID2D1Device = null;
        var hr = create_d2d_device(dxgi_device, null, &device);
        if (failed(hr) or device == null) return mapResourceError(hr);
        self.d2d_device = device;
        errdefer self.releaseDeviceResources();

        var context: ?*ID2D1DeviceContext = null;
        hr = device.?.vtbl.CreateDeviceContext(
            device.?,
            D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
            &context,
        );
        if (failed(hr) or context == null) return mapResourceError(hr);
        self.d2d_context = context;
    }

    fn releaseDeviceResources(self: *ResourceGraph) void {
        releaseCom(self.d2d_context);
        self.d2d_context = null;
        releaseCom(self.d2d_device);
        self.d2d_device = null;
    }
};

fn loadProc(comptime T: type, module: HMODULE, comptime name: [:0]const u8) ?T {
    const raw = GetProcAddress(module, name.ptr) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn releaseCom(value: anytype) void {
    if (value) |raw| {
        const unknown: *IUnknown = @ptrCast(@alignCast(raw));
        _ = unknown.vtbl.Release(raw);
    }
}

fn queryInterface(value: *anyopaque, iid: *const GUID, out: *?*anyopaque) HRESULT {
    const unknown: *IUnknown = @ptrCast(@alignCast(value));
    return unknown.vtbl.QueryInterface(value, iid, out);
}

fn failed(hr: HRESULT) bool {
    return hr < S_OK;
}

fn isDeviceLost(hr: HRESULT) bool {
    return hr == DXGI_ERROR_DEVICE_HUNG or
        hr == DXGI_ERROR_DEVICE_REMOVED or
        hr == DXGI_ERROR_DEVICE_RESET or
        hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR or
        hr == DXGI_ERROR_ACCESS_LOST or
        hr == D2DERR_RECREATE_TARGET;
}

fn mapResourceError(hr: HRESULT) ResourceError {
    return if (isDeviceLost(hr)) error.DeviceLost else error.InitializationFailed;
}

test "shell content COM declarations retain pointer ABI" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IUnknown));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(ID2D1Factory));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(ID2D1Device));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(ID2D1DeviceContext));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IDWriteFactory));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IDWriteTextFormat));
    try std.testing.expectEqual(@as(usize, 16 * @sizeOf(usize)), @sizeOf(IDWriteFactoryVtbl));
}

test "shell content device loss classification includes D2D recreate target" {
    try std.testing.expect(isDeviceLost(DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expect(isDeviceLost(D2DERR_RECREATE_TARGET));
    try std.testing.expect(!isDeviceLost(@bitCast(@as(u32, 0x80004005))));
}

test "shell content stop and loss notification are idempotent" {
    var graph: ResourceGraph = .{};
    graph.noteDeviceLoss();
    graph.stop();
    graph.stop();
    try std.testing.expectEqual(State.stopped, graph.state);
    try std.testing.expectEqual(@as(u64, 0), graph.generation);
    try std.testing.expect(!graph.isReady());
}

test "native shell content resources recover against a live DXGI device" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const d3d11_module = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
        return error.SkipZigTest;
    defer _ = FreeLibrary(d3d11_module);
    const create_device = loadProc(D3D11CreateDeviceFn, d3d11_module, "D3D11CreateDevice") orelse
        return error.SkipZigTest;

    var d3d_device: ?*anyopaque = null;
    var hr = create_device(
        null,
        D3D_DRIVER_TYPE_HARDWARE,
        null,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        null,
        0,
        D3D11_SDK_VERSION,
        &d3d_device,
        null,
        null,
    );
    if (failed(hr)) {
        releaseCom(d3d_device);
        d3d_device = null;
        hr = create_device(
            null,
            D3D_DRIVER_TYPE_WARP,
            null,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            null,
            0,
            D3D11_SDK_VERSION,
            &d3d_device,
            null,
            null,
        );
    }
    if (failed(hr) or d3d_device == null) return error.SkipZigTest;
    defer releaseCom(d3d_device);

    var dxgi_device: ?*anyopaque = null;
    hr = queryInterface(d3d_device.?, &IID_IDXGIDevice, &dxgi_device);
    if (failed(hr) or dxgi_device == null) return error.SkipZigTest;
    defer releaseCom(dxgi_device);

    var rejected_graph: ResourceGraph = .{};
    try std.testing.expectError(
        error.InitializationFailed,
        rejected_graph.startWithText(dxgi_device.?, .{ .size_dip = -1.0 }),
    );
    try std.testing.expectEqual(State.stopped, rejected_graph.state);
    try std.testing.expect(!rejected_graph.isReady());
    try std.testing.expect(rejected_graph.contextHandle() == null);
    try std.testing.expect(rejected_graph.textFormatHandle() == null);
    rejected_graph.stop();

    var graph: ResourceGraph = .{};
    defer graph.stop();
    try graph.start(dxgi_device.?);
    try std.testing.expect(graph.isReady());
    try std.testing.expectEqual(State.ready, graph.state);
    try std.testing.expectEqual(@as(u64, 1), graph.generation);
    try std.testing.expect(graph.contextHandle() != null);
    const original_text_format = graph.textFormatHandle();
    try std.testing.expect(original_text_format != null);

    graph.noteDeviceLoss();
    try std.testing.expectEqual(State.device_lost, graph.state);
    try std.testing.expect(graph.contextHandle() == null);
    try std.testing.expectEqual(original_text_format, graph.textFormatHandle());

    try graph.recover(dxgi_device.?);
    try std.testing.expect(graph.isReady());
    try std.testing.expectEqual(@as(u64, 2), graph.generation);
    try std.testing.expectEqual(original_text_format, graph.textFormatHandle());
}
