const Self = @This();
const std = @import("std");
const Direct3D11 = @import("../Direct3D11.zig");
const Renderer = @import("../generic.zig").Renderer(Direct3D11);
const RenderPass = @import("RenderPass.zig");
const Target = @import("Target.zig");
const Health = @import("../../renderer.zig").Health;
pub const Options = struct {};
renderer: *Renderer,
target: *Target,
healthy: bool = true,
pub fn begin(_: Options, renderer: *Renderer, target: *Target) !Self {
    return .{ .renderer = renderer, .target = target };
}
pub fn renderPass(self: *Self, attachments: []const RenderPass.Options.Attachment) RenderPass {
    return RenderPass.begin(.{ .attachments = attachments, .frame_healthy = &self.healthy });
}
pub fn markUnhealthy(self: *Self, context: []const u8, err: anyerror) void {
    self.healthy = false;
    std.log.scoped(.d3d11).warn("frame unhealthy context={s} err={}", .{ context, err });
}
pub fn complete(self: *const Self, _: bool) void {
    var health: Health = if (self.healthy) .healthy else .unhealthy;
    if (self.healthy) self.renderer.api.present(self.target.*) catch |err| {
        std.log.scoped(.d3d11).err("present failed err={}", .{err});
        health = .unhealthy;
    };
    self.renderer.frameCompleted(health);
}
