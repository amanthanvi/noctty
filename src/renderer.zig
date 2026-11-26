//! Renderer implementation and utilities. The renderer is responsible for
//! taking the internal screen state and turning into some output format,
//! usually for a screen.
//!
//! The renderer is closely tied to the windowing system which usually
//! has to prepare the window for the given renderer using system-specific
//! APIs. The renderers in this package assume that the renderer is already
//! setup (OpenGL has a context, Vulkan has a surface, etc.)

const std = @import("std");
const build_config = @import("build_config.zig");

const cursor = @import("renderer/cursor.zig");
const message = @import("renderer/message.zig");
const size = @import("renderer/size.zig");
pub const shadertoy = if (build_config.custom_shaders)
    @import("renderer/shadertoy.zig")
else
    @import("renderer/shadertoy_stub.zig");
pub const Backend = @import("renderer/backend.zig").Backend;
pub const GenericRenderer = @import("renderer/generic.zig").Renderer;
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const Direct3D11 = if (build_config.d3d11) @import("renderer/Direct3D11.zig") else struct {};
pub const Options = @import("renderer/Options.zig");
pub const Overlay = @import("renderer/Overlay.zig");
pub const Pacer = @import("renderer/Pacer.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");
pub const StateMutex = @import("sync/state_mutex.zig").StateMutex;
pub const CursorStyle = cursor.Style;
pub const Message = message.Message;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;
pub const cursorStyle = cursor.style;
pub const lib = @import("lib/main.zig");

/// Comptime-selected platform renderer. Win32 optionally dispatches between
/// two generic graphics APIs using each surface's runtime preference.
pub const Renderer = switch (build_config.renderer) {
    .opengl => if (build_config.d3d11) @import("renderer/Windows.zig") else GenericRenderer(OpenGL),
};

/// The app-scoped render device from which surface renderers are created
/// (upstream 40d5b860d: `App.device`, made from the apprt surface's
/// `renderDeviceOptions`, and handed to every renderer in `Options.device`).
///
/// noctty divergence: the device holds nothing. The Win32 renderers create
/// their GPU contexts per surface (the runtime's WGL context for OpenGL, its
/// own device for each D3D11 renderer, with a fallback between them), so
/// there is no app-wide GPU state to share, and upstream's EGL device
/// (`renderer/opengl/Device.zig`) is not used.
pub const Device = struct {
    /// What the apprt passes to `init`: nothing on Windows.
    pub const Options = struct {};

    pub fn init(alloc: std.mem.Allocator, options: Device.Options) std.mem.Allocator.Error!*Device {
        _ = options;
        return try alloc.create(Device);
    }

    pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

/// The health status of a renderer. These must be shared across all
/// renderers even if some states aren't reachable so that our API users
/// can use the same enum for all renderers.
pub const Health = enum(c_int) {
    healthy,
    unhealthy,

    test "ghostty.h Health" {
        try lib.checkGhosttyHEnum(Health, "GHOSTTY_RENDERER_HEALTH_");
    }
};

test {
    // Our comptime-chosen renderer
    _ = Renderer;

    _ = cursor;
    _ = message;
    _ = shadertoy;
    _ = size;
    _ = Pacer;
    _ = @import("renderer/pacer_sim.zig");
    _ = Thread;
    _ = State;
    _ = @import("sync/state_mutex.zig");
}
