//! D3D11 backend for the unchanged GenericRenderer preparation path.
//! HWND flip presentation uses an offscreen target so an unchanged frame can be
//! presented again. The SDK bridge retains CPU buffer/atlas copies for recovery.
pub const Direct3D11 = @This();
const std = @import("std");
const apprt = @import("../apprt.zig");
const rendererpkg = @import("../renderer.zig");
const Atlas = @import("../font/Atlas.zig");
const Config = @import("../config/Config.zig");
const api = @import("d3d11/api.zig");
const bufferpkg = @import("d3d11/buffer.zig");
const Renderer = rendererpkg.GenericRenderer(Direct3D11);
const log = std.log.scoped(.d3d11);
const build_config = @import("../build_config.zig");

pub const GraphicsAPI = Direct3D11;
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");
pub const custom_shader_target: rendererpkg.shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = 1;
pub const requires_retained_present = true;
pub const supports_images = false;
pub const supports_custom_shaders = false;

device: *api.Device,
rt_surface: *apprt.Surface,
blending: Config.AlphaBlending,
vsync_enabled: bool,

pub fn init(_: std.mem.Allocator, opts: rendererpkg.Options) !Direct3D11 {
    const hwnd = opts.rt_surface.hwnd orelse return error.Direct3D11MissingWindow;
    const device = api.noctty_d3d11_create(@ptrCast(hwnd), @intFromBool(opts.config.renderer_backend == .@"d3d11-warp")) orelse return error.Direct3D11Unavailable;
    var receipt: api.Stats = undefined;
    api.noctty_d3d11_stats(device, &receipt);
    log.info("initialized driver={s} feature_level=0x{x} flip=sequential targets=offscreen", .{
        if (receipt.warp != 0) "WARP" else "hardware",
        receipt.feature_level,
    });
    return .{
        .device = device,
        .rt_surface = opts.rt_surface,
        .blending = opts.config.blending,
        .vsync_enabled = opts.config.vsync,
    };
}

pub fn deinit(self: *Direct3D11) void {
    api.noctty_d3d11_destroy(self.device);
    self.* = undefined;
}

/// Startup's adapter candidate is independent of the user's recovery policy.
pub fn setRecoveryPreference(self: *Direct3D11, requested: Config.RendererBackend) void {
    api.noctty_d3d11_set_recovery_preference(self.device, @intFromBool(requested == .@"d3d11-warp"));
}

pub fn surfaceInit(_: *apprt.Surface) !void {}
pub fn finalizeSurfaceInit(_: *const Direct3D11, _: *apprt.Surface) !void {}
pub fn threadEnter(_: *const Direct3D11, _: *apprt.Surface) !void {}
pub fn threadExit(_: *const Direct3D11) void {}
pub fn prepareSurfaceDeinit(_: *const Direct3D11, _: *apprt.Surface) !void {}
pub fn displayRealized(_: *const Direct3D11) void {}
pub fn drawFrameStart(self: *Direct3D11) void {
    // GenericRenderer prepares targets and atlases before beginFrame. Recover
    // first so a removed device cannot strand preparation on failed allocations.
    api.check(api.noctty_d3d11_recover(self.device)) catch |err| {
        log.warn("device recovery failed err={}", .{err});
    };
}
pub fn drawFrameEnd(_: *Direct3D11) void {}
pub fn hasVsync(self: *const Direct3D11) bool {
    return self.vsync_enabled;
}

/// Recovery replaces GPU targets. The generic renderer must encode a complete
/// frame before considering unchanged terminal content safe to skip again.
pub fn needsRedraw(self: *const Direct3D11) bool {
    return api.noctty_d3d11_needs_redraw(self.device) != 0;
}
pub fn isUnavailable(self: *const Direct3D11) bool {
    return api.noctty_d3d11_unavailable(self.device) != 0;
}
pub fn stats(self: *const Direct3D11) api.Stats {
    var result: api.Stats = undefined;
    api.noctty_d3d11_stats(self.device, &result);
    return result;
}

pub fn initShaders(_: *const Direct3D11, alloc: std.mem.Allocator, custom: []const [:0]const u8) !shaders.Shaders {
    return shaders.Shaders.init(alloc, custom);
}

pub fn surfaceSize(self: *const Direct3D11) !struct { width: u32, height: u32 } {
    const size = try self.rt_surface.getSize();
    return .{ .width = @intCast(size.width), .height = @intCast(size.height) };
}

pub fn initTarget(self: *const Direct3D11, width: usize, height: usize, custom: bool) !Target {
    if (custom) return error.Direct3D11CustomShadersUnsupported;
    return Target.init(.{
        .device = self.device,
        .width = width,
        .height = height,
        .linear = self.blending.isLinear(),
    });
}

pub fn present(self: *Direct3D11, target: Target) !void {
    if (target.width == 0 or target.height == 0) return;
    const hr = api.noctty_d3d11_present(self.device, target.handle, @intFromBool(self.vsync_enabled));
    try api.check(hr);
    if (hr == 0) self.rt_surface.noteSuccessfulPresent();
}

pub fn presentLastTarget(self: *Direct3D11) !void {
    const hr = api.noctty_d3d11_present_last(self.device, @intFromBool(self.vsync_enabled));
    try api.check(hr);
    if (hr == 0) self.rt_surface.noteSuccessfulPresent();
}

/// Test-only WM_PRINTCLIENT readback. Caller holds the renderer draw mutex.
/// This captures the rendered target, before any DWM composition.
pub fn capture(self: *Direct3D11, hdc: *anyopaque) !void {
    if (!build_config.renderer_test_tools) return error.RendererTestToolsDisabled;
    try api.check(api.noctty_d3d11_capture(self.device, hdc));
}

/// Inject a device-removed HRESULT through the production recovery classifier.
/// This tests resource restoration without resetting the system's graphics driver.
pub fn requestDeviceLoss(self: *Direct3D11) !void {
    if (!build_config.renderer_test_tools) return error.RendererTestToolsDisabled;
    try api.check(api.noctty_d3d11_request_device_loss(self.device));
}

pub fn setTestFailures(self: *Direct3D11, hardware: bool, device: bool) !void {
    if (!build_config.renderer_test_tools) return error.RendererTestToolsDisabled;
    try api.check(api.noctty_d3d11_set_test_failures(self.device, @intFromBool(hardware), @intFromBool(device)));
}

pub fn failNextPresent(self: *Direct3D11) !void {
    if (!build_config.renderer_test_tools) return error.RendererTestToolsDisabled;
    try api.check(api.noctty_d3d11_fail_next_present(self.device));
}

pub fn bufferOptions(self: Direct3D11) bufferpkg.Options {
    return .{ .device = self.device };
}
pub const instanceBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;
pub fn uniformBufferOptions(self: Direct3D11) bufferpkg.Options {
    return .{ .device = self.device, .uniform = true };
}

pub fn textureOptions(self: Direct3D11) Texture.Options {
    return .{ .device = self.device, .format = .rgba, .srgb = true };
}
pub fn samplerOptions(_: Direct3D11) Sampler.Options {
    return .{};
}
pub const ImageTextureFormat = enum { gray, rgba, bgra };
pub fn imageTextureOptions(self: Direct3D11, format: ImageTextureFormat, srgb: bool) Texture.Options {
    return .{
        .device = self.device,
        .format = switch (format) {
            .gray => .gray,
            .rgba => .rgba,
            .bgra => .bgra,
        },
        .srgb = srgb,
        .unsupported_image = true,
    };
}

pub fn initAtlasTexture(self: *const Direct3D11, atlas: *const Atlas) Texture.Error!Texture {
    return Texture.init(.{
        .device = self.device,
        .format = switch (atlas.format) {
            .grayscale => .gray,
            .bgra => .bgra,
            else => return error.Direct3D11UnsupportedTextureFormat,
        },
        .srgb = atlas.format == .bgra,
    }, atlas.size, atlas.size, null);
}

pub fn beginFrame(self: *const Direct3D11, renderer: *Renderer, target: *Target) !Frame {
    try api.check(api.noctty_d3d11_begin(self.device));
    return Frame.begin(.{}, renderer, target);
}

pub fn isOccluded(self: *const Direct3D11) bool {
    return api.noctty_d3d11_occluded(self.device) != 0;
}
pub fn recoveryPending(self: *const Direct3D11) bool {
    return api.noctty_d3d11_recovery_pending(self.device) != 0;
}

/// Detach the presentation surface before WGL touches the same HWND. GPU
/// resources and the device remain usable if OpenGL construction fails.
pub fn suspendPresentation(self: *Direct3D11) !void {
    try api.check(api.noctty_d3d11_suspend_presentation(self.device));
}

pub fn backendLabel(self: *const Direct3D11) [:0]const u8 {
    return if (self.stats().warp != 0) "D3D11 WARP (software)" else "D3D11 hardware";
}
