//! Per-window DirectComposition surface content rendered with Direct2D.
//!
//! This module attaches an updatable DirectComposition surface to an existing
//! visual. It borrows the compositor's device graph through AddRef'd COM
//! bindings and never commits DirectComposition itself; callers can batch the
//! resulting SetContent/EndDraw changes into their normal commit boundary.
//!
//! The existing compositor is created from IDXGIDevice, so BeginDraw requests
//! IDXGISurface. That surface is wrapped as a target bitmap on the supplied
//! ID2D1DeviceContext. Terminal child HWNDs and WGL presentation never cross
//! this boundary.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("win32/sys.zig");

const windows = std.os.windows;
const GUID = windows.GUID;
const HRESULT = windows.HRESULT;
const HMODULE = ?*anyopaque;
const HWND = ?*anyopaque;

const S_OK: HRESULT = 0;
const DIP_BASE: f32 = 96.0;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_FORMAT_UNKNOWN: u32 = 0;
const DXGI_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_ALPHA_MODE_PREMULTIPLIED: u32 = 1;
const D2D1_BITMAP_OPTIONS_TARGET: u32 = 1;
const D2D1_BITMAP_OPTIONS_CANNOT_DRAW: u32 = 2;
const D2D1_DRAW_TEXT_OPTIONS_CLIP: u32 = 2;
const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;

const DXGI_ERROR_DEVICE_HUNG: HRESULT = @bitCast(@as(u32, 0x887A0006));
const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));
const DXGI_ERROR_DRIVER_INTERNAL_ERROR: HRESULT = @bitCast(@as(u32, 0x887A0020));
const DXGI_ERROR_ACCESS_LOST: HRESULT = @bitCast(@as(u32, 0x887A0026));
const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));

const IID_IDXGISurface = GUID.parse("{CAFCB56C-6AC3-4889-BF47-9E23BBD260EC}");

// Vtable indices are fixed by dcomp.h and d2d1.h/d2d1_1.h. Keeping only an
// indexed pointer table avoids publishing partial interface declarations that
// could accidentally be used as complete ABI types.
const VTBL_IUNKNOWN_ADD_REF: usize = 1;
const VTBL_IUNKNOWN_RELEASE: usize = 2;
const VTBL_DCOMP_DEVICE_CREATE_SURFACE: usize = 8;
const VTBL_DCOMP_VISUAL_SET_CONTENT: usize = 15;
const VTBL_DCOMP_SURFACE_BEGIN_DRAW: usize = 3;
const VTBL_DCOMP_SURFACE_END_DRAW: usize = 4;
const VTBL_D2D_CREATE_SOLID_COLOR_BRUSH: usize = 8;
const VTBL_D2D_DRAW_TEXT: usize = 27;
const VTBL_D2D_SET_TRANSFORM: usize = 30;
const VTBL_D2D_GET_TRANSFORM: usize = 31;
const VTBL_D2D_CLEAR: usize = 47;
const VTBL_D2D_BEGIN_DRAW: usize = 48;
const VTBL_D2D_END_DRAW: usize = 49;
const VTBL_D2D_SET_DPI: usize = 51;
const VTBL_D2D_GET_DPI: usize = 52;
const VTBL_D2D_CREATE_BITMAP_FROM_DXGI_SURFACE: usize = 62;
const VTBL_D2D_SET_TARGET: usize = 74;
const VTBL_D2D_GET_TARGET: usize = 75;

const ComObject = extern struct {
    vtbl: [*]const *const anyopaque,
};

const Point = extern struct {
    x: i32,
    y: i32,
};

const PixelFormat = extern struct {
    format: u32,
    alpha_mode: u32,
};

const BitmapProperties = extern struct {
    pixel_format: PixelFormat,
    dpi_x: f32,
    dpi_y: f32,
    bitmap_options: u32,
    color_context: ?*anyopaque,
};

const Matrix3x2 = extern struct {
    m11: f32,
    m12: f32,
    m21: f32,
    m22: f32,
    dx: f32,
    dy: f32,
};

pub const RectF = extern struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

pub const Color = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,
};

pub const Bindings = struct {
    dcomp_device: *anyopaque,
    visual: *anyopaque,
    d2d_context: *anyopaque,
    text_format: *anyopaque,
};

pub const ContentError = error{
    InvalidSize,
    Busy,
    AttachFailed,
    DrawFailed,
    DeviceLost,
};

pub const State = enum {
    empty,
    ready,
    drawing,
    device_lost,
};

pub const RenderText = struct {
    text: []const u16,
    background: Color = .{ .r = 0.055, .g = 0.063, .b = 0.078 },
    foreground: Color = .{ .r = 0.91, .g = 0.93, .b = 0.96 },
    padding_dip: f32 = 12.0,
    layout_dip: ?RectF = null,
};

pub const WindowContent = struct {
    dcomp_device: ?*anyopaque = null,
    visual: ?*anyopaque = null,
    d2d_context: ?*anyopaque = null,
    text_format: ?*anyopaque = null,
    surface: ?*anyopaque = null,
    width_px: u32 = 0,
    height_px: u32 = 0,
    dpi: f32 = DIP_BASE,
    state: State = .empty,
    generation: u64 = 0,

    pub fn init(
        bindings: Bindings,
        width_dip: f32,
        height_dip: f32,
        dpi: f32,
    ) ContentError!WindowContent {
        const size = try pixelSize(width_dip, height_dip, dpi);
        var self: WindowContent = .{
            .width_px = size.width,
            .height_px = size.height,
            .dpi = dpi,
        };
        self.retainBindings(bindings);
        errdefer self.releaseBindings();
        try self.replaceSurface(size.width, size.height);
        self.state = .ready;
        self.generation = 1;
        return self;
    }

    /// Replaces the fixed-size DirectComposition surface transactionally. A
    /// failure leaves the old surface attached and all dimensions unchanged.
    /// Returns true only when observable sizing state changed.
    pub fn resizeDips(
        self: *WindowContent,
        width_dip: f32,
        height_dip: f32,
        dpi: f32,
    ) ContentError!bool {
        if (self.state == .drawing) return error.Busy;
        if (self.state != .ready) return error.DeviceLost;
        const size = try pixelSize(width_dip, height_dip, dpi);
        if (size.width == self.width_px and size.height == self.height_px) {
            if (dpi == self.dpi) return false;
            self.dpi = dpi;
            self.generation +%= 1;
            return true;
        }

        try self.replaceSurface(size.width, size.height);
        self.width_px = size.width;
        self.height_px = size.height;
        self.dpi = dpi;
        self.generation +%= 1;
        return true;
    }

    /// Draws and closes both drawing transactions. The caller must commit its
    /// DirectComposition device after this returns successfully.
    pub fn renderText(self: *WindowContent, args: RenderText) ContentError!void {
        if (self.state == .drawing) return error.Busy;
        if (self.state != .ready) return error.DeviceLost;
        if (args.text.len > std.math.maxInt(u32) or
            !std.math.isFinite(args.padding_dip) or args.padding_dip < 0 or
            (args.layout_dip != null and !validRect(args.layout_dip.?)) or
            !validColor(args.background) or !validColor(args.foreground))
            return error.DrawFailed;

        const surface = self.surface orelse return error.DeviceLost;
        self.state = .drawing;
        defer if (self.state == .drawing) {
            self.state = .ready;
        };

        var update_object: ?*anyopaque = null;
        var update_offset: Point = .{ .x = 0, .y = 0 };
        var hr = call(
            SurfaceBeginDrawFn,
            surface,
            VTBL_DCOMP_SURFACE_BEGIN_DRAW,
        )(surface, null, &IID_IDXGISurface, &update_object, &update_offset);
        if (failed(hr) or update_object == null) {
            releaseCom(update_object);
            return self.recordError(mapError(hr, error.DrawFailed));
        }

        var draw_error: ?ContentError = null;
        self.drawDxgiUpdate(update_object.?, update_offset, args) catch |err| {
            draw_error = err;
        };
        releaseCom(update_object);

        hr = call(SurfaceEndDrawFn, surface, VTBL_DCOMP_SURFACE_END_DRAW)(surface);
        if (failed(hr) and isDeviceLost(hr)) return self.recordError(error.DeviceLost);
        if (draw_error) |err| return self.recordError(err);
        if (failed(hr)) return self.recordError(mapError(hr, error.DrawFailed));
        self.state = .ready;
    }

    /// Drops every object associated with the invalid device graph without
    /// issuing additional commands against that graph.
    pub fn noteDeviceLoss(self: *WindowContent) void {
        if (self.state == .empty) return;
        releaseCom(self.surface);
        self.surface = null;
        self.releaseBindings();
        self.state = .device_lost;
    }

    /// Rebinds to a reconstructed compositor graph and recreates the surface.
    /// Surface pixels are undefined until the caller renders and commits a
    /// frame; integration must not commit the newly attached surface first.
    pub fn recover(self: *WindowContent, bindings: Bindings) ContentError!void {
        if (self.state == .drawing) return error.Busy;
        if (self.state != .device_lost) return error.AttachFailed;

        releaseCom(self.surface);
        self.surface = null;
        self.releaseBindings();
        self.retainBindings(bindings);
        self.replaceSurface(self.width_px, self.height_px) catch |err| {
            self.releaseBindings();
            self.state = .device_lost;
            return err;
        };
        self.state = .ready;
        self.generation +%= 1;
    }

    /// Detaches content as a pending DComp operation, then releases ownership.
    /// The caller may commit after this call; teardown remains safe without it.
    pub fn deinit(self: *WindowContent) void {
        if (self.state != .device_lost) {
            if (self.visual) |visual| {
                _ = call(VisualSetContentFn, visual, VTBL_DCOMP_VISUAL_SET_CONTENT)(visual, null);
            }
        }
        releaseCom(self.surface);
        self.surface = null;
        self.releaseBindings();
        self.width_px = 0;
        self.height_px = 0;
        self.state = .empty;
    }

    pub fn isReady(self: *const WindowContent) bool {
        return self.state == .ready and self.surface != null and
            self.dcomp_device != null and self.visual != null and
            self.d2d_context != null and self.text_format != null;
    }

    fn replaceSurface(self: *WindowContent, width: u32, height: u32) ContentError!void {
        const device = self.dcomp_device orelse return error.DeviceLost;
        const visual = self.visual orelse return error.DeviceLost;
        var replacement: ?*anyopaque = null;
        var hr = call(
            DeviceCreateSurfaceFn,
            device,
            VTBL_DCOMP_DEVICE_CREATE_SURFACE,
        )(
            device,
            width,
            height,
            DXGI_FORMAT_B8G8R8A8_UNORM,
            DXGI_ALPHA_MODE_PREMULTIPLIED,
            &replacement,
        );
        if (failed(hr) or replacement == null) {
            releaseCom(replacement);
            return self.recordError(mapError(hr, error.AttachFailed));
        }
        errdefer releaseCom(replacement);

        hr = call(VisualSetContentFn, visual, VTBL_DCOMP_VISUAL_SET_CONTENT)(visual, replacement);
        if (failed(hr)) return self.recordError(mapError(hr, error.AttachFailed));

        releaseCom(self.surface);
        self.surface = replacement;
    }

    fn drawDxgiUpdate(
        self: *WindowContent,
        dxgi_surface: *anyopaque,
        offset: Point,
        args: RenderText,
    ) ContentError!void {
        const context = self.d2d_context orelse return error.DeviceLost;
        const text_format = self.text_format orelse return error.DeviceLost;
        const properties: BitmapProperties = .{
            .pixel_format = .{
                .format = DXGI_FORMAT_UNKNOWN,
                .alpha_mode = D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            .dpi_x = self.dpi,
            .dpi_y = self.dpi,
            .bitmap_options = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
            .color_context = null,
        };

        var target_bitmap: ?*anyopaque = null;
        var hr = call(
            CreateBitmapFromDxgiSurfaceFn,
            context,
            VTBL_D2D_CREATE_BITMAP_FROM_DXGI_SURFACE,
        )(context, dxgi_surface, &properties, &target_bitmap);
        if (failed(hr) or target_bitmap == null) {
            releaseCom(target_bitmap);
            return mapError(hr, error.DrawFailed);
        }
        defer releaseCom(target_bitmap);

        var old_transform: Matrix3x2 = undefined;
        call(GetTransformFn, context, VTBL_D2D_GET_TRANSFORM)(context, &old_transform);
        var old_dpi_x: f32 = 0;
        var old_dpi_y: f32 = 0;
        call(GetDpiFn, context, VTBL_D2D_GET_DPI)(context, &old_dpi_x, &old_dpi_y);
        var old_target: ?*anyopaque = null;
        call(GetTargetFn, context, VTBL_D2D_GET_TARGET)(context, &old_target);
        defer releaseCom(old_target);

        call(SetTargetFn, context, VTBL_D2D_SET_TARGET)(context, target_bitmap);
        defer {
            call(SetTransformFn, context, VTBL_D2D_SET_TRANSFORM)(context, &old_transform);
            call(SetDpiFn, context, VTBL_D2D_SET_DPI)(context, old_dpi_x, old_dpi_y);
            call(SetTargetFn, context, VTBL_D2D_SET_TARGET)(context, old_target);
        }
        call(SetDpiFn, context, VTBL_D2D_SET_DPI)(context, self.dpi, self.dpi);
        const px_to_dip = DIP_BASE / self.dpi;
        const transform: Matrix3x2 = .{
            .m11 = 1,
            .m12 = 0,
            .m21 = 0,
            .m22 = 1,
            .dx = @as(f32, @floatFromInt(offset.x)) * px_to_dip,
            .dy = @as(f32, @floatFromInt(offset.y)) * px_to_dip,
        };
        call(SetTransformFn, context, VTBL_D2D_SET_TRANSFORM)(context, &transform);

        var brush: ?*anyopaque = null;
        hr = call(
            CreateSolidColorBrushFn,
            context,
            VTBL_D2D_CREATE_SOLID_COLOR_BRUSH,
        )(context, &args.foreground, null, &brush);
        if (failed(hr) or brush == null) {
            releaseCom(brush);
            return mapError(hr, error.DrawFailed);
        }
        defer releaseCom(brush);

        call(BeginDrawFn, context, VTBL_D2D_BEGIN_DRAW)(context);
        call(ClearFn, context, VTBL_D2D_CLEAR)(context, &args.background);
        if (args.text.len > 0) {
            const width_dip = @as(f32, @floatFromInt(self.width_px)) * px_to_dip;
            const height_dip = @as(f32, @floatFromInt(self.height_px)) * px_to_dip;
            const layout: RectF = args.layout_dip orelse .{
                .left = args.padding_dip,
                .top = args.padding_dip,
                .right = @max(args.padding_dip, width_dip - args.padding_dip),
                .bottom = @max(args.padding_dip, height_dip - args.padding_dip),
            };
            call(DrawTextFn, context, VTBL_D2D_DRAW_TEXT)(
                context,
                args.text.ptr,
                @intCast(args.text.len),
                text_format,
                &layout,
                brush.?,
                D2D1_DRAW_TEXT_OPTIONS_CLIP,
                DWRITE_MEASURING_MODE_NATURAL,
            );
        }
        hr = call(EndDrawFn, context, VTBL_D2D_END_DRAW)(context, null, null);
        if (failed(hr)) return mapError(hr, error.DrawFailed);
    }

    fn retainBindings(self: *WindowContent, bindings: Bindings) void {
        addRef(bindings.dcomp_device);
        addRef(bindings.visual);
        addRef(bindings.d2d_context);
        addRef(bindings.text_format);
        self.dcomp_device = bindings.dcomp_device;
        self.visual = bindings.visual;
        self.d2d_context = bindings.d2d_context;
        self.text_format = bindings.text_format;
    }

    fn releaseBindings(self: *WindowContent) void {
        releaseCom(self.text_format);
        self.text_format = null;
        releaseCom(self.d2d_context);
        self.d2d_context = null;
        releaseCom(self.visual);
        self.visual = null;
        releaseCom(self.dcomp_device);
        self.dcomp_device = null;
    }

    fn recordError(self: *WindowContent, err: ContentError) ContentError {
        self.state = if (err == error.DeviceLost) .device_lost else .ready;
        return err;
    }
};

pub const PixelSize = struct { width: u32, height: u32 };

pub fn pixelSize(width_dip: f32, height_dip: f32, dpi: f32) ContentError!PixelSize {
    if (!std.math.isFinite(width_dip) or !std.math.isFinite(height_dip) or
        !std.math.isFinite(dpi) or width_dip < 0 or height_dip < 0 or dpi <= 0)
        return error.InvalidSize;
    return .{
        .width = try dipExtentToPixels(width_dip, dpi),
        .height = try dipExtentToPixels(height_dip, dpi),
    };
}

fn dipExtentToPixels(dips: f32, dpi: f32) ContentError!u32 {
    const scaled = @ceil(@as(f64, dips) * @as(f64, dpi) / @as(f64, DIP_BASE));
    if (!std.math.isFinite(scaled) or scaled > @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return error.InvalidSize;
    return @max(1, @as(u32, @intFromFloat(scaled)));
}

fn validColor(color: Color) bool {
    return std.math.isFinite(color.r) and
        std.math.isFinite(color.g) and
        std.math.isFinite(color.b) and
        std.math.isFinite(color.a);
}

fn validRect(rect: RectF) bool {
    return std.math.isFinite(rect.left) and std.math.isFinite(rect.top) and
        std.math.isFinite(rect.right) and std.math.isFinite(rect.bottom) and
        rect.right >= rect.left and rect.bottom >= rect.top;
}

fn call(comptime T: type, object: *anyopaque, comptime index: usize) T {
    const com: *ComObject = @ptrCast(@alignCast(object));
    return @ptrCast(@alignCast(com.vtbl[index]));
}

fn addRef(value: *anyopaque) void {
    _ = call(AddRefFn, value, VTBL_IUNKNOWN_ADD_REF)(value);
}

fn releaseCom(value: anytype) void {
    if (value) |raw| {
        _ = call(ReleaseFn, raw, VTBL_IUNKNOWN_RELEASE)(raw);
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
        hr == DXGI_ERROR_ACCESS_LOST or
        hr == D2DERR_RECREATE_TARGET;
}

fn mapError(hr: HRESULT, fallback: ContentError) ContentError {
    return if (isDeviceLost(hr)) error.DeviceLost else fallback;
}

const AddRefFn = *const fn (*anyopaque) callconv(.winapi) u32;
const ReleaseFn = *const fn (*anyopaque) callconv(.winapi) u32;
const DeviceCreateSurfaceFn = *const fn (
    *anyopaque,
    u32,
    u32,
    u32,
    u32,
    *?*anyopaque,
) callconv(.winapi) HRESULT;
const VisualSetContentFn = *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) HRESULT;
const SurfaceBeginDrawFn = *const fn (
    *anyopaque,
    ?*const windows.RECT,
    *const GUID,
    *?*anyopaque,
    *Point,
) callconv(.winapi) HRESULT;
const SurfaceEndDrawFn = *const fn (*anyopaque) callconv(.winapi) HRESULT;
const CreateBitmapFromDxgiSurfaceFn = *const fn (
    *anyopaque,
    *anyopaque,
    *const BitmapProperties,
    *?*anyopaque,
) callconv(.winapi) HRESULT;
const SetTargetFn = *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) void;
const GetTargetFn = *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) void;
const CreateSolidColorBrushFn = *const fn (
    *anyopaque,
    *const Color,
    ?*const anyopaque,
    *?*anyopaque,
) callconv(.winapi) HRESULT;
const SetTransformFn = *const fn (*anyopaque, *const Matrix3x2) callconv(.winapi) void;
const GetTransformFn = *const fn (*anyopaque, *Matrix3x2) callconv(.winapi) void;
const SetDpiFn = *const fn (*anyopaque, f32, f32) callconv(.winapi) void;
const GetDpiFn = *const fn (*anyopaque, *f32, *f32) callconv(.winapi) void;
const BeginDrawFn = *const fn (*anyopaque) callconv(.winapi) void;
const ClearFn = *const fn (*anyopaque, ?*const Color) callconv(.winapi) void;
const DrawTextFn = *const fn (
    *anyopaque,
    [*]const u16,
    u32,
    *anyopaque,
    *const RectF,
    *anyopaque,
    u32,
    u32,
) callconv(.winapi) void;
const EndDrawFn = *const fn (*anyopaque, ?*u64, ?*u64) callconv(.winapi) HRESULT;

test "DIP sizing rounds outward and keeps minimized surfaces valid" {
    try std.testing.expectEqual(PixelSize{ .width = 1, .height = 1 }, try pixelSize(0, 0, 96));
    try std.testing.expectEqual(PixelSize{ .width = 150, .height = 76 }, try pixelSize(100, 50.1, 144));
    try std.testing.expectError(error.InvalidSize, pixelSize(-1, 10, 96));
    try std.testing.expectError(error.InvalidSize, pixelSize(10, 10, 0));
    try std.testing.expectError(error.InvalidSize, pixelSize(std.math.inf(f32), 10, 96));
}

test "window content device-loss classification covers D2D and DXGI" {
    try std.testing.expect(isDeviceLost(D2DERR_RECREATE_TARGET));
    try std.testing.expect(isDeviceLost(DXGI_ERROR_DEVICE_REMOVED));
    try std.testing.expect(!isDeviceLost(@bitCast(@as(u32, 0x80004005))));
}

test "window content ABI indices match Windows SDK interface inheritance" {
    try std.testing.expectEqual(@as(usize, 8), VTBL_DCOMP_DEVICE_CREATE_SURFACE);
    try std.testing.expectEqual(@as(usize, 15), VTBL_DCOMP_VISUAL_SET_CONTENT);
    try std.testing.expectEqual(@as(usize, 62), VTBL_D2D_CREATE_BITMAP_FROM_DXGI_SURFACE);
    try std.testing.expectEqual(@as(usize, 74), VTBL_D2D_SET_TARGET);
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(ComObject));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BitmapProperties));
}

// Native smoke support remains in this file so standalone `zig test` executes
// the exact COM ABI used in production without adding build-graph wiring.
const content_resources = @import("win32_compositor_content_native.zig");

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;
const GA_ROOT: u32 = 2;
const IID_IDXGIDevice = GUID.parse("{54EC77FA-1377-44E6-8C32-88FD5F44C84C}");
const IID_IDCompositionDevice = GUID.parse("{C37EA93A-E7AA-450D-B16F-9746CB0407F3}");

const D3D11CreateDeviceFn = *const fn (
    ?*anyopaque,
    u32,
    HMODULE,
    u32,
    ?[*]const u32,
    u32,
    u32,
    *?*anyopaque,
    ?*u32,
    ?*?*anyopaque,
) callconv(.winapi) HRESULT;
const DCompositionCreateDeviceFn = *const fn (
    ?*anyopaque,
    *const GUID,
    *?*anyopaque,
) callconv(.winapi) HRESULT;
const DeviceCommitFn = *const fn (*anyopaque) callconv(.winapi) HRESULT;
const DeviceCreateTargetFn = *const fn (
    *anyopaque,
    HWND,
    i32,
    *?*anyopaque,
) callconv(.winapi) HRESULT;
const DeviceCreateVisualFn = *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT;
const TargetSetRootFn = *const fn (*anyopaque, ?*anyopaque) callconv(.winapi) HRESULT;
const QueryInterfaceFn = *const fn (
    *anyopaque,
    *const GUID,
    *?*anyopaque,
) callconv(.winapi) HRESULT;

fn loadProc(comptime T: type, module: HMODULE, comptime name: [:0]const u8) ?T {
    const raw = sys.GetProcAddress(module, name.ptr) orelse return null;
    return @ptrCast(@alignCast(raw));
}

test "native hidden HWND renders and resizes DirectComposition shell content" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const d3d_module = sys.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
        return error.SkipZigTest;
    defer _ = sys.FreeLibrary(d3d_module);
    const dcomp_module = sys.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse
        return error.SkipZigTest;
    defer _ = sys.FreeLibrary(dcomp_module);
    const create_d3d = loadProc(D3D11CreateDeviceFn, d3d_module, "D3D11CreateDevice") orelse
        return error.SkipZigTest;
    const create_dcomp = loadProc(DCompositionCreateDeviceFn, dcomp_module, "DCompositionCreateDevice") orelse
        return error.SkipZigTest;

    var d3d_device: ?*anyopaque = null;
    var hr = create_d3d(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &d3d_device, null, null);
    if (failed(hr)) {
        releaseCom(d3d_device);
        d3d_device = null;
        hr = create_d3d(null, D3D_DRIVER_TYPE_WARP, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &d3d_device, null, null);
    }
    if (failed(hr) or d3d_device == null) return error.SkipZigTest;
    defer releaseCom(d3d_device);

    var dxgi_device: ?*anyopaque = null;
    hr = call(QueryInterfaceFn, d3d_device.?, 0)(d3d_device.?, &IID_IDXGIDevice, &dxgi_device);
    if (failed(hr) or dxgi_device == null) return error.SkipZigTest;
    defer releaseCom(dxgi_device);

    var dcomp_device: ?*anyopaque = null;
    hr = create_dcomp(dxgi_device, &IID_IDCompositionDevice, &dcomp_device);
    if (failed(hr) or dcomp_device == null) return error.SkipZigTest;
    defer releaseCom(dcomp_device);

    const hwnd = sys.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("winghostty dcomp content smoke"),
        0x00CF0000,
        0,
        0,
        360,
        120,
        null,
        null,
        null,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = sys.DestroyWindow(hwnd);
    const ancestor = sys.GetAncestor(hwnd, GA_ROOT) orelse return error.SkipZigTest;
    try std.testing.expectEqual(hwnd, ancestor);

    var target: ?*anyopaque = null;
    hr = call(DeviceCreateTargetFn, dcomp_device.?, 6)(dcomp_device.?, hwnd, 0, &target);
    if (failed(hr) or target == null) return error.SkipZigTest;
    defer releaseCom(target);

    var visual: ?*anyopaque = null;
    hr = call(DeviceCreateVisualFn, dcomp_device.?, 7)(dcomp_device.?, &visual);
    if (failed(hr) or visual == null) return error.SkipZigTest;
    defer releaseCom(visual);
    hr = call(TargetSetRootFn, target.?, 3)(target.?, visual);
    if (failed(hr)) return error.SkipZigTest;

    var resources: content_resources.ResourceGraph = .{};
    defer resources.stop();
    try resources.start(dxgi_device.?);
    const d2d_context = resources.contextHandle() orelse return error.SkipZigTest;
    const text_format = resources.textFormatHandle() orelse return error.SkipZigTest;

    var window_content = try WindowContent.init(.{
        .dcomp_device = dcomp_device.?,
        .visual = visual.?,
        .d2d_context = d2d_context,
        .text_format = text_format,
    }, 320, 72, 144);
    defer window_content.deinit();
    try std.testing.expect(window_content.isReady());
    try std.testing.expectEqual(@as(u32, 480), window_content.width_px);
    try std.testing.expectEqual(@as(u32, 108), window_content.height_px);
    try window_content.renderText(.{
        .text = std.unicode.utf8ToUtf16LeStringLiteral("winghostty shell composition"),
    });
    hr = call(DeviceCommitFn, dcomp_device.?, 3)(dcomp_device.?);
    try std.testing.expect(!failed(hr));

    try std.testing.expect(try window_content.resizeDips(240, 64, 120));
    try std.testing.expectEqual(@as(u32, 300), window_content.width_px);
    try std.testing.expectEqual(@as(u32, 80), window_content.height_px);
    try window_content.renderText(.{
        .text = std.unicode.utf8ToUtf16LeStringLiteral("resized shell content"),
        .background = .{ .r = 0.08, .g = 0.1, .b = 0.14 },
        .foreground = .{ .r = 0.4, .g = 0.8, .b = 1.0 },
    });
    hr = call(DeviceCommitFn, dcomp_device.?, 3)(dcomp_device.?);
    try std.testing.expect(!failed(hr));

    const prior_generation = window_content.generation;
    window_content.noteDeviceLoss();
    try std.testing.expectEqual(State.device_lost, window_content.state);
    try window_content.recover(.{
        .dcomp_device = dcomp_device.?,
        .visual = visual.?,
        .d2d_context = d2d_context,
        .text_format = text_format,
    });
    try std.testing.expect(window_content.isReady());
    try std.testing.expectEqual(prior_generation +% 1, window_content.generation);
    try window_content.renderText(.{
        .text = std.unicode.utf8ToUtf16LeStringLiteral("recreated shell content"),
    });
    hr = call(DeviceCommitFn, dcomp_device.?, 3)(dcomp_device.?);
    try std.testing.expect(!failed(hr));
}
