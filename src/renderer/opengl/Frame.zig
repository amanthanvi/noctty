//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const gl = @import("opengl");

const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,
healthy: bool = true,
failure_context: ?[]const u8 = null,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .frame_healthy = &self.healthy,
        .frame_failure_context = &self.failure_context,
    });
}

/// Mark this frame as unsafe to present.
///
/// This is used for failures that happen between `beginFrame` and
/// `complete`, but outside a `RenderPass.step`. The pass itself marks the
/// frame unhealthy when a GL operation fails.
pub fn markUnhealthy(self: *Self, context: []const u8, err: anyerror) void {
    self.healthy = false;
    if (self.failure_context == null) self.failure_context = context;
    log.warn("OpenGL frame marked unhealthy context={s} err={}", .{ context, err });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored and we always block.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;
    gl.flush();
    var health: Health = if (!self.healthy) unhealthy: {
        if (self.failure_context) |context| {
            log.warn("OpenGL frame suppressed present context={s}", .{context});
        }
        break :unhealthy .unhealthy;
    } else if (gl.errors.getError()) .healthy else |err| unhealthy: {
        log.warn("OpenGL frame marked unhealthy context=gl.flush err={}", .{err});
        break :unhealthy .unhealthy;
    };

    // If the frame is healthy, present it.
    if (health == .healthy) {
        self.renderer.api.present(self.target.*) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
            health = .unhealthy;
        };
    }

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}
