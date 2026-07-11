//! DirectComposition shell backend boundary.
//!
//! This module deliberately does not replace or wrap terminal WGL presentation.
//! The terminal renderer continues to own its child HWND, HDC, HGLRC, and
//! `SwapBuffers`. The native driver supplies D3D11/DComp top-level targets
//! through `Driver`; GDI remains the truthful chrome-drawing fallback until
//! D2D/DWrite shell content is attached to those visuals.

const std = @import("std");
const builtin = @import("builtin");

pub const TerminalPresentation = enum {
    wgl_swap_buffers_unchanged,
};

pub const terminal_presentation: TerminalPresentation = .wgl_swap_buffers_unchanged;

pub const Capability = struct {
    windows: bool = false,
    d3d11_create_device: bool = false,
    dcomposition_create_device: bool = false,
    d2d1_create_factory: bool = false,
    dwrite_create_factory: bool = false,

    pub fn supportsNativeShell(self: Capability) bool {
        return self.windows and
            self.d3d11_create_device and
            self.dcomposition_create_device and
            self.d2d1_create_factory and
            self.dwrite_create_factory;
    }
};

/// Probe only for the required native DLL exports. A successful probe means a
/// native driver may attempt initialization; it never means composition is
/// initialized or active.
pub fn probeNativeCapability() Capability {
    if (comptime builtin.os.tag != .windows) return .{};
    return .{
        .windows = true,
        .d3d11_create_device = hasExport("d3d11.dll", "D3D11CreateDevice"),
        .dcomposition_create_device = hasExport("dcomp.dll", "DCompositionCreateDevice"),
        .d2d1_create_factory = hasExport("d2d1.dll", "D2D1CreateFactory"),
        .dwrite_create_factory = hasExport("dwrite.dll", "DWriteCreateFactory"),
    };
}

const HMODULE = ?*anyopaque;
const BOOL = i32;

extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) BOOL;

fn hasExport(comptime library: [:0]const u8, comptime symbol: [:0]const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    const module = LoadLibraryA(library.ptr) orelse return false;
    defer _ = FreeLibrary(module);
    return GetProcAddress(module, symbol.ptr) != null;
}

pub const WindowHandle = usize;

pub const DriverError = error{
    Unavailable,
    InitializationFailed,
    AttachFailed,
    DetachFailed,
    CommitFailed,
    DeviceLost,
    RecoveryFailed,
};

/// Native implementation contract. The driver owns all COM references and
/// per-window targets. `stop_fn` must be idempotent and safe after partial
/// initialization. Returned target counts are authoritative, allowing the
/// boundary to reject false "active" states without retaining HWNDs itself.
pub const Driver = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque) DriverError!void,
    stop_fn: *const fn (*anyopaque) void,
    attach_window_fn: *const fn (*anyopaque, WindowHandle) DriverError!u32,
    detach_window_fn: *const fn (*anyopaque, WindowHandle) DriverError!u32,
    commit_fn: *const fn (*anyopaque) DriverError!void,
    recover_fn: *const fn (*anyopaque) DriverError!u32,

    fn start(self: Driver) DriverError!void {
        return self.start_fn(self.context);
    }

    fn stop(self: Driver) void {
        self.stop_fn(self.context);
    }

    fn attachWindow(self: Driver, window: WindowHandle) DriverError!u32 {
        return self.attach_window_fn(self.context, window);
    }

    fn detachWindow(self: Driver, window: WindowHandle) DriverError!u32 {
        return self.detach_window_fn(self.context, window);
    }

    fn commit(self: Driver) DriverError!void {
        return self.commit_fn(self.context);
    }

    fn recover(self: Driver) DriverError!u32 {
        return self.recover_fn(self.context);
    }
};

pub const State = enum {
    fallback,
    ready,
    active,
    device_lost,
    deinitialized,
};

pub const FallbackReason = enum {
    capability_missing,
    driver_unwired,
    initialization_failed,
    attach_failed,
    detach_failed,
    commit_failed,
    recovery_failed,
};

pub const Status = struct {
    state: State,
    fallback_reason: ?FallbackReason,
    active_target_count: u32,
    capability: Capability,

    pub fn compositionActive(self: Status) bool {
        return self.state == .active and self.active_target_count > 0;
    }
};

pub const BackendError = error{
    FallbackOnly,
    InvalidState,
    InvalidWindow,
    DeviceLost,
    DriverFailure,
};

pub const Backend = struct {
    capability: Capability,
    driver: ?Driver = null,
    state: State = .fallback,
    fallback_reason: ?FallbackReason = null,
    active_target_count: u32 = 0,
    driver_started: bool = false,

    /// Initialize the boundary. Passing `null` is an explicit scaffold mode:
    /// capability is reported but the backend remains fallback-only.
    pub fn init(capability: Capability, driver: ?Driver) Backend {
        var self: Backend = .{
            .capability = capability,
            .driver = driver,
        };
        if (!capability.supportsNativeShell()) {
            self.fallback_reason = .capability_missing;
            return self;
        }
        const native = driver orelse {
            self.fallback_reason = .driver_unwired;
            return self;
        };
        native.start() catch {
            native.stop();
            self.fallback_reason = .initialization_failed;
            return self;
        };
        self.driver_started = true;
        self.state = .ready;
        return self;
    }

    pub fn deinit(self: *Backend) void {
        if (self.state == .deinitialized) return;
        self.stopDriver();
        self.state = .deinitialized;
        self.active_target_count = 0;
    }

    pub fn status(self: *const Backend) Status {
        return .{
            .state = self.state,
            .fallback_reason = self.fallback_reason,
            .active_target_count = self.active_target_count,
            .capability = self.capability,
        };
    }

    pub fn attachWindow(self: *Backend, window: WindowHandle) BackendError!void {
        if (window == 0) return error.InvalidWindow;
        if (self.state == .fallback) return error.FallbackOnly;
        if (self.state != .ready and self.state != .active) return error.InvalidState;
        const native = self.driver orelse return error.FallbackOnly;
        const count = native.attachWindow(window) catch |err| {
            if (err == error.DeviceLost) {
                self.state = .device_lost;
                return error.DeviceLost;
            }
            self.enterFallback(.attach_failed);
            return error.DriverFailure;
        };
        if (count == 0) {
            self.enterFallback(.attach_failed);
            return error.DriverFailure;
        }
        self.active_target_count = count;
        self.state = .active;
    }

    pub fn detachWindow(self: *Backend, window: WindowHandle) BackendError!void {
        if (window == 0) return error.InvalidWindow;
        if (self.state != .active and self.state != .ready) return error.InvalidState;
        const native = self.driver orelse return error.FallbackOnly;
        const count = native.detachWindow(window) catch |err| {
            if (err == error.DeviceLost) {
                self.state = .device_lost;
                return error.DeviceLost;
            }
            self.enterFallback(.detach_failed);
            return error.DriverFailure;
        };
        self.active_target_count = count;
        self.state = if (count == 0) .ready else .active;
    }

    pub fn commit(self: *Backend) BackendError!void {
        if (self.state == .device_lost) return error.DeviceLost;
        if (self.state != .active) return error.InvalidState;
        const native = self.driver orelse return error.FallbackOnly;
        native.commit() catch |err| {
            if (err == error.DeviceLost) {
                self.state = .device_lost;
                return error.DeviceLost;
            }
            self.enterFallback(.commit_failed);
            return error.DriverFailure;
        };
    }

    /// Record device loss reported by another shell operation. Terminal WGL
    /// state is external and must not be destroyed by this transition.
    pub fn markDeviceLost(self: *Backend) void {
        if (self.state == .active or self.state == .ready) self.state = .device_lost;
    }

    pub fn recover(self: *Backend) BackendError!void {
        if (self.state != .device_lost) return error.InvalidState;
        const native = self.driver orelse return error.FallbackOnly;
        const count = native.recover() catch {
            self.enterFallback(.recovery_failed);
            return error.DriverFailure;
        };
        self.active_target_count = count;
        self.state = if (count == 0) .ready else .active;
    }

    fn enterFallback(self: *Backend, reason: FallbackReason) void {
        self.stopDriver();
        self.active_target_count = 0;
        self.state = .fallback;
        self.fallback_reason = reason;
    }

    fn stopDriver(self: *Backend) void {
        if (!self.driver_started) return;
        if (self.driver) |native| native.stop();
        self.driver_started = false;
    }
};

const full_capability: Capability = .{
    .windows = true,
    .d3d11_create_device = true,
    .dcomposition_create_device = true,
    .d2d1_create_factory = true,
    .dwrite_create_factory = true,
};

const FakeDriver = struct {
    started: bool = false,
    stopped: bool = false,
    targets: u32 = 0,
    start_error: ?DriverError = null,
    attach_error: ?DriverError = null,
    detach_error: ?DriverError = null,
    commit_error: ?DriverError = null,
    recover_error: ?DriverError = null,
    recovered_targets: u32 = 0,

    fn interface(self: *FakeDriver) Driver {
        return .{
            .context = self,
            .start_fn = start,
            .stop_fn = stop,
            .attach_window_fn = attachWindow,
            .detach_window_fn = detachWindow,
            .commit_fn = commit,
            .recover_fn = recover,
        };
    }

    fn fromContext(context: *anyopaque) *FakeDriver {
        return @ptrCast(@alignCast(context));
    }

    fn start(context: *anyopaque) DriverError!void {
        const self = fromContext(context);
        if (self.start_error) |err| return err;
        self.started = true;
    }

    fn stop(context: *anyopaque) void {
        const self = fromContext(context);
        self.stopped = true;
        self.started = false;
        self.targets = 0;
    }

    fn attachWindow(context: *anyopaque, window: WindowHandle) DriverError!u32 {
        _ = window;
        const self = fromContext(context);
        if (self.attach_error) |err| return err;
        self.targets += 1;
        return self.targets;
    }

    fn detachWindow(context: *anyopaque, window: WindowHandle) DriverError!u32 {
        _ = window;
        const self = fromContext(context);
        if (self.detach_error) |err| return err;
        if (self.targets > 0) self.targets -= 1;
        return self.targets;
    }

    fn commit(context: *anyopaque) DriverError!void {
        const self = fromContext(context);
        if (self.commit_error) |err| return err;
    }

    fn recover(context: *anyopaque) DriverError!u32 {
        const self = fromContext(context);
        if (self.recover_error) |err| return err;
        self.targets = self.recovered_targets;
        return self.targets;
    }
};

test "capability requires every native shell component" {
    try std.testing.expect(full_capability.supportsNativeShell());
    var missing = full_capability;
    missing.dcomposition_create_device = false;
    try std.testing.expect(!missing.supportsNativeShell());
}

test "native capability probe reports the actual platform without activating composition" {
    const capability = probeNativeCapability();
    try std.testing.expectEqual(builtin.os.tag == .windows, capability.windows);

    var backend = Backend.init(capability, null);
    defer backend.deinit();
    try std.testing.expectEqual(State.fallback, backend.status().state);
    try std.testing.expect(!backend.status().compositionActive());
}

test "missing capability and unwired driver remain truthful fallback" {
    var unavailable = Backend.init(.{}, null);
    defer unavailable.deinit();
    try std.testing.expectEqual(State.fallback, unavailable.status().state);
    try std.testing.expectEqual(FallbackReason.capability_missing, unavailable.status().fallback_reason.?);
    try std.testing.expect(!unavailable.status().compositionActive());

    var unwired = Backend.init(full_capability, null);
    defer unwired.deinit();
    try std.testing.expectEqual(FallbackReason.driver_unwired, unwired.status().fallback_reason.?);
    try std.testing.expect(!unwired.status().compositionActive());
}

test "initialized backend is not active before a real window target" {
    var fake: FakeDriver = .{};
    var backend = Backend.init(full_capability, fake.interface());
    defer backend.deinit();
    try std.testing.expect(fake.started);
    try std.testing.expectEqual(State.ready, backend.status().state);
    try std.testing.expect(!backend.status().compositionActive());

    try backend.attachWindow(100);
    try std.testing.expectEqual(State.active, backend.status().state);
    try std.testing.expect(backend.status().compositionActive());
    try backend.commit();

    try backend.detachWindow(100);
    try std.testing.expectEqual(State.ready, backend.status().state);
    try std.testing.expect(!backend.status().compositionActive());
}

test "initialization and attach failures fall back and release driver" {
    var init_failure: FakeDriver = .{ .start_error = error.InitializationFailed };
    var init_backend = Backend.init(full_capability, init_failure.interface());
    defer init_backend.deinit();
    try std.testing.expectEqual(FallbackReason.initialization_failed, init_backend.status().fallback_reason.?);
    try std.testing.expect(!init_failure.started);
    try std.testing.expect(init_failure.stopped);

    var attach_failure: FakeDriver = .{ .attach_error = error.AttachFailed };
    var attach_backend = Backend.init(full_capability, attach_failure.interface());
    defer attach_backend.deinit();
    try std.testing.expectError(error.DriverFailure, attach_backend.attachWindow(100));
    try std.testing.expectEqual(FallbackReason.attach_failed, attach_backend.status().fallback_reason.?);
    try std.testing.expect(attach_failure.stopped);
}

test "device loss blocks commits and recovery restores truthful activity" {
    var fake: FakeDriver = .{ .commit_error = error.DeviceLost, .recovered_targets = 1 };
    var backend = Backend.init(full_capability, fake.interface());
    defer backend.deinit();
    try backend.attachWindow(100);
    try std.testing.expectError(error.DeviceLost, backend.commit());
    try std.testing.expectEqual(State.device_lost, backend.status().state);
    try std.testing.expect(!backend.status().compositionActive());

    fake.commit_error = null;
    try backend.recover();
    try std.testing.expectEqual(State.active, backend.status().state);
    try std.testing.expect(backend.status().compositionActive());
}

test "failed recovery enters durable fallback and releases resources" {
    var fake: FakeDriver = .{ .recover_error = error.RecoveryFailed };
    var backend = Backend.init(full_capability, fake.interface());
    defer backend.deinit();
    try backend.attachWindow(100);
    backend.markDeviceLost();
    try std.testing.expectError(error.DriverFailure, backend.recover());
    try std.testing.expectEqual(State.fallback, backend.status().state);
    try std.testing.expectEqual(FallbackReason.recovery_failed, backend.status().fallback_reason.?);
    try std.testing.expect(fake.stopped);
}

test "generic commit failure falls back instead of claiming active" {
    var fake: FakeDriver = .{ .commit_error = error.CommitFailed };
    var backend = Backend.init(full_capability, fake.interface());
    defer backend.deinit();
    try backend.attachWindow(100);
    try std.testing.expectError(error.DriverFailure, backend.commit());
    try std.testing.expectEqual(State.fallback, backend.status().state);
    try std.testing.expect(!backend.status().compositionActive());
}

test "terminal presentation contract remains WGL" {
    try std.testing.expectEqual(TerminalPresentation.wgl_swap_buffers_unchanged, terminal_presentation);
}
