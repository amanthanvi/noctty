//! One binary, two instantiations of the shared renderer. Backend replacement
//! occurs on the UI draw thread; the outer mutex protects the active pointer
//! from renderer-thread updates during replacement. OpenGL is the default.
const Windows = @This();
const std = @import("std");
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const build_config = @import("../build_config.zig");
const terminal_options = @import("terminal_options");
const generic = @import("generic.zig");
const selection = @import("selection.zig");
const log = std.log.scoped(.renderer_windows);

const GL = renderer.GenericRenderer(renderer.OpenGL);
const D3D = renderer.GenericRenderer(renderer.Direct3D11);
pub const API = renderer.OpenGL;
pub const DerivedConfig = generic.CommonDerivedConfig;
pub const FrameUpdate = generic.CommonFrameUpdate;

alloc: std.mem.Allocator,
rt_surface: *apprt.Surface,
surface_mailbox: apprt.surface.Mailbox,
mutex: std.Thread.Mutex = .{},
/// Published once, after full GL construction/state transfer. GL never changes
/// again, so default surfaces forward with the original GenericRenderer locks.
opengl: std.atomic.Value(?*GL) = .init(null),
fallback_blocked: bool = false,
draw_failures: u8 = 0,
fallback_retry_ms: i64 = 0,
fallback_attempts: u32 = 0,
last_warp: bool = false,
notice: [256]u8 = undefined,
notice_len: usize = 0,
active: union(enum) { opengl: *GL, d3d11: *D3D },
pending_fallback: bool = false,
state: ?*renderer.State = null,
cursor_blink_visible: bool = true,
thread: *renderer.Thread,
presentation_pending: std.atomic.Value(bool) = .init(false),
presentation_pending_changed: std.atomic.Value(bool) = .init(false),

/// D3D11 does not require WGL initialization. OpenGL is prepared lazily at
/// renderer init, after the complete per-surface config is available.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    // Default WGL creation precedes core init, exactly as in GL-only builds.
    if (surface.hglrc != null) try GL.surfaceInit(surface);
}

fn initGL(alloc: std.mem.Allocator, options: renderer.Options) !*GL {
    if (comptime build_config.renderer_test_tools) {
        if (std.process.hasEnvVarConstant("NOCTTY_RENDERER_FAIL_OPENGL")) return error.OpenGLTestFailure;
    }
    // The default surface was prepared in surfaceInit, before font allocation.
    if (!options.rt_surface.renderer_gl_prepared) {
        try options.rt_surface.ensureGLContext();
        try GL.surfaceInit(options.rt_surface);
        options.rt_surface.noteBenchmarkMemoryStage(.opengl_functions_loaded, null);
    }
    const value = try alloc.create(GL);
    errdefer alloc.destroy(value);
    value.* = try GL.init(alloc, options);
    return value;
}

pub fn init(alloc: std.mem.Allocator, options: renderer.Options) !Windows {
    var config = options.config;
    errdefer config.deinit();
    const feature = selection.unsupported(config.custom_shaders.value.items.len != 0, config.bg_image != null, false);
    const base: Windows = .{ .alloc = alloc, .rt_surface = options.rt_surface, .surface_mailbox = options.surface_mailbox, .active = undefined, .thread = options.thread };
    var result = base;
    if (config.renderer_backend == .opengl or feature != null) {
        if (initGL(alloc, options)) |value| {
            result.active = .{ .opengl = value };
            result.opengl.store(value, .release);
            if (config.renderer_backend != .opengl) if (feature) |reason| result.setNotice("OpenGL: D3D11 beta does not support {s}.", .{@tagName(reason)});
            return result;
        } else |err| {
            if (config.renderer_backend == .opengl) return err;
            result.setNotice("OpenGL failed ({s}); D3D11 will draw text without unsupported features.", .{@errorName(err)});
        }
    }
    // Each D3D candidate covers full generic-renderer initialization. WARP
    // remains a separate candidate for failures after device creation.
    for (selection.startupOrder(config.renderer_backend, null)) |candidate| {
        if (candidate == .opengl) break;
        var candidate_options = options;
        candidate_options.config.renderer_backend = candidate;
        const value = try alloc.create(D3D);
        if (D3D.init(alloc, candidate_options)) |initialized| {
            value.* = initialized;
            value.config.renderer_backend = config.renderer_backend;
            value.api.setRecoveryPreference(config.renderer_backend);
            result.active = .{ .d3d11 = value };
            result.last_warp = value.api.stats().warp != 0;
            if (feature != null) {
                result.fallback_blocked = true;
            } else if (result.last_warp) {
                result.setNotice("D3D11 WARP (software): hardware unavailable or software requested; HRESULT 0x{x}.", .{@as(u32, @bitCast(value.api.stats().last_error))});
            } else {
                result.setNotice("D3D11 beta: hardware renderer active.", .{});
            }
            return result;
        } else |err| {
            alloc.destroy(value);
            log.warn("{s} startup failed err={}", .{ @tagName(candidate), err });
            result.setNotice("OpenGL: D3D11 startup failed ({s}).", .{@errorName(err)});
        }
    }
    const value = try initGL(alloc, options);
    result.active = .{ .opengl = value };
    result.opengl.store(value, .release);
    return result;
}

fn setNotice(self: *Windows, comptime fmt: []const u8, args: anytype) void {
    const message = std.fmt.bufPrint(&self.notice, fmt, args) catch return;
    self.notice_len = message.len;
    log.warn("{s}", .{message});
}

fn showNotice(self: *Windows) void {
    if (self.notice_len == 0) return;
    if (comptime build_config.renderer_test_tools) {
        // Target-pixel parity fixes geometry independently of host banners.
        if (std.process.hasEnvVarConstant("NOCTTY_RENDERER_HIDE_NOTICES")) {
            self.notice_len = 0;
            return;
        }
    }
    self.rt_surface.showRendererNotice(self.notice[0..self.notice_len]) catch return;
    self.notice_len = 0;
}

/// Caller owns mutex and is the UI draw thread. Failed construction leaves
/// the current backend intact; ownership changes only after full GL init.
fn fallBack(self: *Windows) !void {
    const old = switch (self.active) {
        .opengl => return,
        .d3d11 => |v| v,
    };
    try old.api.suspendPresentation();
    const replacement = try initGL(self.alloc, .{ .config = old.config, .font_grid = old.font_grid, .size = old.size, .surface_mailbox = old.surface_mailbox, .rt_surface = self.rt_surface, .thread = self.thread });
    old.transferCpuState(replacement);
    old.deinitAfterBackendSwitch();
    self.alloc.destroy(old);
    self.active = .{ .opengl = replacement };
    self.pending_fallback = false;
    self.setPresentationPending(false);
    if (self.state) |state| {
        if (comptime terminal_options.kitty_graphics) {
            state.mutex.lock();
            state.terminal.screens.active.kitty_images.dirty = true;
            state.mutex.unlock();
        }
        _ = replacement.updateFrame(state, self.cursor_blink_visible) catch |err| {
            log.warn("OpenGL frame preparation after fallback failed err={}", .{err});
        };
    }
    self.setNotice("OpenGL: switched from D3D11 beta ({s}).", .{if (self.fallback_blocked) "repeated draw failure" else "unsupported feature or device recovery"});
    self.showNotice();
    self.opengl.store(replacement, .release);
}

fn tryFallback(self: *Windows) bool {
    const old = self.active.d3d11;
    const now = std.time.milliTimestamp();
    if (now < self.fallback_retry_ms) return false;
    if (comptime build_config.renderer_test_tools) self.fallback_attempts +|= 1;
    self.fallBack() catch |err| {
        // Healthy D3D11 keeps rendering text. A config reload explicitly retries
        // a previously rejected feature; retained images alone cannot spin.
        self.pending_fallback = false;
        self.fallback_blocked = true;
        self.fallback_retry_ms = now + 5000;
        self.setNotice("D3D11: OpenGL fallback failed ({s}); unsupported images/effects are ignored. Retrying unavailable devices in 5 seconds.", .{@errorName(err)});
        self.showNotice();
        old.cells_rebuilt = true;
        return false;
    };
    return true;
}

pub fn drawFrame(self: *Windows, sync: bool) !void {
    if (self.opengl.load(.acquire)) |v| {
        // The startup notice is UI-owned; all other GL calls remain direct.
        self.showNotice();
        return v.drawFrame(sync);
    }
    self.mutex.lock();
    defer self.mutex.unlock();
    self.showNotice();
    if (self.active == .opengl) return self.active.opengl.drawFrame(sync);
    const v = self.active.d3d11;
    if (self.pending_fallback or v.api.isUnavailable() or self.draw_failures >= 3) {
        if (self.tryFallback()) return self.active.opengl.drawFrame(sync);
        if (v.api.isUnavailable()) {
            self.setPresentationPending(true);
            return;
        }
    }
    for (0..2) |_| {
        v.drawFrame(sync or self.draw_failures != 0) catch |err| {
            self.draw_failures +|= 1;
            if (!v.api.recoveryPending() and !v.api.isUnavailable()) {
                self.setPresentationPending(true);
                if (self.draw_failures >= 3 and self.tryFallback()) return self.active.opengl.drawFrame(sync);
                return err;
            }
        };
        if (v.api.isUnavailable()) {
            if (self.tryFallback()) return self.active.opengl.drawFrame(sync);
            self.setPresentationPending(true);
            return;
        }
        if (!v.api.recoveryPending()) {
            // RenderPass/Frame completion also reports errors through health,
            // including calls whose API does not propagate an error union.
            if (v.health.load(.monotonic) == .unhealthy) {
                self.draw_failures +|= 1;
                self.setPresentationPending(true);
                if (self.draw_failures >= 3 and self.tryFallback()) return self.active.opengl.drawFrame(sync);
                return;
            }
            self.draw_failures = 0;
            const stats = v.api.stats();
            if (self.last_warp != (stats.warp != 0)) {
                self.last_warp = stats.warp != 0;
                self.setNotice("D3D11 {s}: device reconstructed; HRESULT 0x{x}.", .{ if (self.last_warp) "WARP (software)" else "hardware", @as(u32, @bitCast(stats.last_error)) });
                self.showNotice();
            }
            self.setPresentationPending(v.api.isOccluded());
            return;
        }
    }
    self.setPresentationPending(true);
}

pub fn updateFrame(self: *Windows, state: *renderer.State, cursor_blink_visible: bool) std.mem.Allocator.Error!FrameUpdate {
    if (self.opengl.load(.acquire)) |v| return v.updateFrame(state, cursor_blink_visible);
    self.mutex.lock();
    defer self.mutex.unlock();
    self.state = state;
    self.cursor_blink_visible = cursor_blink_visible;
    switch (self.active) {
        .opengl => |v| return v.updateFrame(state, cursor_blink_visible),
        .d3d11 => |v| {
            const result = try v.updateFrame(state, cursor_blink_visible);
            // Images include Kitty graphics and the generated hint overlay.
            if (v.images.hasLiveImages() and !self.fallback_blocked) {
                if (!self.pending_fallback) log.warn("D3D11 does not support terminal images; using OpenGL", .{});
                self.pending_fallback = true;
            }
            return result;
        },
    }
}

pub fn changeConfig(self: *Windows, config: *DerivedConfig) !void {
    if (self.opengl.load(.acquire)) |v| return v.changeConfig(config);
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.active == .d3d11) {
        if (selection.unsupported(config.custom_shaders.value.items.len != 0, config.bg_image != null, self.active.d3d11.images.hasLiveImages())) |feature| {
            log.warn("D3D11 does not support {s}; trying OpenGL on next draw", .{@tagName(feature)});
            self.pending_fallback = true;
            self.fallback_blocked = false;
            self.fallback_retry_ms = 0;
        }
    }
    switch (self.active) {
        inline else => |v| try v.changeConfig(config),
    }
}

pub fn deinit(self: *Windows) void {
    switch (self.active) {
        inline else => |v| {
            v.deinit();
            self.alloc.destroy(v);
        },
    }
    self.* = undefined;
}

pub fn capture(self: *Windows, hdc: *anyopaque) !void {
    if (!build_config.renderer_test_tools) return error.TestToolsDisabled;
    self.mutex.lock();
    defer self.mutex.unlock();
    const status_path = try std.process.getEnvVarOwned(self.alloc, "NOCTTY_RENDERER_STATUS_PATH");
    defer self.alloc.free(status_path);
    const file = try std.fs.cwd().createFile(status_path, .{});
    defer file.close();
    const json = switch (self.active) {
        .opengl => try std.json.Stringify.valueAlloc(self.alloc, .{ .backend = "opengl" }, .{}),
        .d3d11 => |v| report: {
            const receipt = v.api.stats();
            var max_image_id: u32 = 0;
            var image_it = v.images.images.keyIterator();
            while (image_it.next()) |key| {
                if (key.* == .kitty) max_image_id = @max(max_image_id, key.kitty);
            }
            break :report try std.json.Stringify.valueAlloc(self.alloc, .{
                .backend = "d3d11",
                .warp = receipt.warp != 0,
                .adapter = std.mem.sliceTo(&receipt.adapter_name, 0),
                .feature_level = receipt.feature_level,
                .frames = receipt.frames,
                .draw_calls = receipt.draw_calls,
                .upload_bytes = receipt.upload_bytes,
                .encode_ns = receipt.encode_ns,
                .present_ns = receipt.present_ns,
                .last_error = receipt.last_error,
                .removed_reason = receipt.removed_reason,
                .fallback_blocked = self.fallback_blocked,
                .fallback_attempts = self.fallback_attempts,
                .image_count = v.images.images.count(),
                .max_image_id = max_image_id,
                .hardware_attempts = receipt.hardware_attempts,
                .draw_failures = self.draw_failures,
                .swapchain_width = receipt.swapchain_width,
                .swapchain_height = receipt.swapchain_height,
                .resize_buffers = receipt.resize_buffers,
                .composition_commits = receipt.composition_commits,
                .presents = receipt.presents,
                .occluded = receipt.occluded_presents,
                .present_tests = receipt.present_tests,
                .recoveries = receipt.recoveries,
                .generation = receipt.generation,
                .unavailable = receipt.unavailable,
                .last_present_status = receipt.last_present_status,
            }, .{});
        },
    };
    defer self.alloc.free(json);
    try file.writeAll(json);
    // Status remains observable when the device cannot provide GPU pixels.
    // The harness still requires successful capture for pixel assertions.
    switch (self.active) {
        inline else => |v| {
            v.draw_mutex.lock();
            defer v.draw_mutex.unlock();
            if (self.active == .opengl) try self.rt_surface.makeGLContextCurrent();
            try v.api.capture(hdc);
        },
    }
}

pub fn requestDeviceLoss(self: *Windows) bool {
    if (!build_config.renderer_test_tools) return false;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.active != .d3d11) return false;
    self.active.d3d11.api.requestDeviceLoss() catch return false;
    return true;
}

test {
    _ = selection;
}

pub fn finalizeSurfaceInit(self: *Windows, surface: *apprt.Surface) !void {
    if (self.opengl.load(.acquire)) |v| return v.finalizeSurfaceInit(surface);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.finalizeSurfaceInit(surface),
    }
}

pub fn threadEnter(self: *Windows, surface: *apprt.Surface) !void {
    if (self.opengl.load(.acquire)) |v| return v.threadEnter(surface);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.threadEnter(surface),
    }
}

pub fn prepareSurfaceDeinit(self: *Windows, surface: *apprt.Surface) !void {
    if (self.opengl.load(.acquire)) |v| return v.prepareSurfaceDeinit(surface);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.prepareSurfaceDeinit(surface),
    }
}

pub fn threadExit(self: *Windows) void {
    if (self.opengl.load(.acquire)) |v| return v.threadExit();
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.threadExit(),
    }
}

pub fn loopEnter(self: *Windows, thr: *renderer.Thread) !void {
    if (self.opengl.load(.acquire)) |v| return v.loopEnter(thr);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.loopEnter(thr),
    }
}

pub fn loopExit(self: *Windows) void {
    if (self.opengl.load(.acquire)) |v| return v.loopExit();
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.loopExit(),
    }
}

pub fn hasAnimations(self: *Windows) bool {
    if (self.opengl.load(.acquire)) |v| return v.hasAnimations();
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| return v.hasAnimations(),
    }
}

pub fn hasVsync(self: *Windows) bool {
    if (self.opengl.load(.acquire)) |v| return v.hasVsync();
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| return v.hasVsync(),
    }
}

pub fn setFocus(self: *Windows, focus: bool) !void {
    if (self.opengl.load(.acquire)) |v| return v.setFocus(focus);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.setFocus(focus),
    }
}

pub fn setVisible(self: *Windows, visible: bool) void {
    if (self.opengl.load(.acquire)) |v| return v.setVisible(visible);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setVisible(visible),
    }
}

pub fn setFontGrid(self: *Windows, grid: *font.SharedGrid) void {
    if (self.opengl.load(.acquire)) |v| return v.setFontGrid(grid);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setFontGrid(grid),
    }
}

pub fn setScreenSize(self: *Windows, size: renderer.Size) void {
    if (self.opengl.load(.acquire)) |v| return v.setScreenSize(size);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setScreenSize(size),
    }
}

pub fn setSearchMatches(self: *Windows, value: ?renderer.Message.SearchMatches) void {
    if (self.opengl.load(.acquire)) |v| return v.setSearchMatches(value);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setSearchMatches(value),
    }
}

pub fn setSearchSelectedMatch(self: *Windows, value: ?renderer.Message.SearchMatch) void {
    if (self.opengl.load(.acquire)) |v| return v.setSearchSelectedMatch(value);
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setSearchSelectedMatch(value),
    }
}

pub fn setTestFailures(self: *Windows, hardware: bool, device: bool) bool {
    if (!build_config.renderer_test_tools) return false;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.active != .d3d11) return false;
    self.active.d3d11.api.setTestFailures(hardware, device) catch return false;
    return true;
}

pub fn failNextPresent(self: *Windows) bool {
    if (!build_config.renderer_test_tools) return false;
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.active != .d3d11) return false;
    self.active.d3d11.api.failNextPresent() catch return false;
    return true;
}

/// An occluded frame still needs a later Present(TEST), even with a steady
/// cursor and no terminal output. Reuse the renderer draw timer, at 4 Hz.
pub fn hasPendingPresentation(self: *const Windows) bool {
    return self.presentation_pending.load(.acquire);
}
fn setPresentationPending(self: *Windows, pending: bool) void {
    if (self.presentation_pending.swap(pending, .acq_rel) == pending) return;
    self.presentation_pending_changed.store(true, .release);
    self.thread.wakeup.notify() catch {};
}

pub fn takePresentationPendingChanged(self: *Windows) bool {
    return self.presentation_pending_changed.swap(false, .acq_rel);
}

test "OpenGL scheduling queries bypass the dispatcher lock" {
    var gl: GL = undefined;
    gl.has_custom_shaders = true;
    var value: Windows = undefined;
    value.mutex = .{};
    value.opengl = .init(&gl);
    value.mutex.lock();
    defer value.mutex.unlock();
    try std.testing.expect(value.hasAnimations());
    try std.testing.expect(!value.hasVsync());
}
