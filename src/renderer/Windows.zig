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
active: union(enum) { opengl: *GL, d3d11: *D3D },
pending_fallback: bool = false,
state: ?*renderer.State = null,
cursor_blink_visible: bool = true,
thread: *renderer.Thread,
presentation_pending: std.atomic.Value(bool) = .init(false),

/// D3D11 does not require WGL initialization. OpenGL is prepared lazily at
/// renderer init, after the complete per-surface config is available.
pub fn surfaceInit(_: *apprt.Surface) !void {}

fn initGL(alloc: std.mem.Allocator, options: renderer.Options) !*GL {
    try options.rt_surface.ensureGLContext();
    try GL.surfaceInit(options.rt_surface);
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
    if (feature) |reason| {
        if (config.renderer_backend != .opengl) log.warn("D3D11 does not support {s}; using OpenGL", .{@tagName(reason)});
    }
    for (selection.startupOrder(config.renderer_backend, feature)) |candidate| {
        if (candidate == .opengl) break;
        var candidate_options = options;
        candidate_options.config.renderer_backend = candidate;
        const value = try alloc.create(D3D);
        if (D3D.init(alloc, candidate_options)) |initialized| {
            value.* = initialized;
            value.config.renderer_backend = config.renderer_backend;
            result.active = .{ .d3d11 = value };
            return result;
        } else |err| {
            alloc.destroy(value);
            log.warn("{s} startup failed; trying next renderer candidate err={}", .{ @tagName(candidate), err });
        }
    }
    result.active = .{ .opengl = try initGL(alloc, options) };
    return result;
}

/// Caller owns mutex and is the UI draw thread. Failed construction leaves
/// the current backend intact; ownership changes only after full GL init.
fn fallBack(self: *Windows) !void {
    const old = switch (self.active) {
        .opengl => return,
        .d3d11 => |v| v,
    };
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
        _ = try replacement.updateFrame(state, self.cursor_blink_visible);
    }
    log.warn("surface switched to OpenGL; D3D11 beta fallback", .{});
}

pub fn drawFrame(self: *Windows, sync: bool) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.active == .d3d11 and (self.pending_fallback or self.active.d3d11.api.isUnavailable()))
        try self.fallBack();
    switch (self.active) {
        .opengl => |v| {
            try self.rt_surface.makeGLContextCurrent();
            try v.drawFrame(sync);
        },
        .d3d11 => |v| {
            // A failed frame enters bounded recovery on the same UI thread.
            // Present can fail from frame.complete without returning an error.
            for (0..2) |_| {
                v.drawFrame(sync) catch |err| {
                    if (!v.api.recoveryPending() and !v.api.isUnavailable()) return err;
                };
                if (v.api.isUnavailable()) {
                    try self.fallBack();
                    try self.active.opengl.drawFrame(sync);
                    break;
                }
                if (!v.api.recoveryPending()) {
                    self.setPresentationPending(v.api.isOccluded());
                    break;
                }
            }
        },
    }
}

pub fn updateFrame(self: *Windows, state: *renderer.State, cursor_blink_visible: bool) std.mem.Allocator.Error!FrameUpdate {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.state = state;
    self.cursor_blink_visible = cursor_blink_visible;
    switch (self.active) {
        .opengl => |v| return v.updateFrame(state, cursor_blink_visible),
        .d3d11 => |v| {
            const result = try v.updateFrame(state, cursor_blink_visible);
            // Images include Kitty graphics and the generated hint overlay.
            if (v.images.images.count() != 0) {
                if (!self.pending_fallback) log.warn("D3D11 does not support terminal images; using OpenGL", .{});
                self.pending_fallback = true;
            }
            return result;
        },
    }
}

pub fn changeConfig(self: *Windows, config: *DerivedConfig) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.active == .d3d11) {
        if (selection.unsupported(config.custom_shaders.value.items.len != 0, config.bg_image != null, false)) |feature| {
            log.warn("D3D11 does not support {s}; using OpenGL on next draw", .{@tagName(feature)});
            self.pending_fallback = true;
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
    switch (self.active) {
        inline else => |v| {
            v.draw_mutex.lock();
            defer v.draw_mutex.unlock();
            if (self.active == .opengl) try self.rt_surface.makeGLContextCurrent();
            try v.api.capture(hdc);
        },
    }
    const status_path = try std.process.getEnvVarOwned(self.alloc, "NOCTTY_RENDERER_STATUS_PATH");
    defer self.alloc.free(status_path);
    const file = try std.fs.cwd().createFile(status_path, .{});
    defer file.close();
    const json = switch (self.active) {
        .opengl => try std.json.Stringify.valueAlloc(self.alloc, .{ .backend = "opengl" }, .{}),
        .d3d11 => |v| report: {
            const receipt = v.api.stats();
            break :report try std.json.Stringify.valueAlloc(self.alloc, .{
                .backend = "d3d11",
                .warp = receipt.warp != 0,
                .adapter = std.mem.sliceTo(&receipt.adapter_name, 0),
                .feature_level = receipt.feature_level,
                .frames = receipt.frames,
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
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.finalizeSurfaceInit(surface),
    }
}

pub fn threadEnter(self: *Windows, surface: *apprt.Surface) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.threadEnter(surface),
    }
}

pub fn prepareSurfaceDeinit(self: *Windows, surface: *apprt.Surface) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.prepareSurfaceDeinit(surface),
    }
}

pub fn threadExit(self: *Windows) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.threadExit(),
    }
}

pub fn loopEnter(self: *Windows, thr: *renderer.Thread) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.loopEnter(thr),
    }
}

pub fn loopExit(self: *Windows) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.loopExit(),
    }
}

pub fn hasAnimations(self: *Windows) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| return v.hasAnimations(),
    }
}

pub fn hasVsync(self: *Windows) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| return v.hasVsync(),
    }
}

pub fn setFocus(self: *Windows, focus: bool) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| try v.setFocus(focus),
    }
}

pub fn setVisible(self: *Windows, visible: bool) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setVisible(visible),
    }
}

pub fn setFontGrid(self: *Windows, grid: *font.SharedGrid) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setFontGrid(grid),
    }
}

pub fn setScreenSize(self: *Windows, size: renderer.Size) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setScreenSize(size),
    }
}

pub fn setSearchMatches(self: *Windows, value: ?renderer.Message.SearchMatches) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    switch (self.active) {
        inline else => |v| v.setSearchMatches(value),
    }
}

pub fn setSearchSelectedMatch(self: *Windows, value: ?renderer.Message.SearchMatch) void {
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
    self.thread.wakeup.notify() catch {};
}
