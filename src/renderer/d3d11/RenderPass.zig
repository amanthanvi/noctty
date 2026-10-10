const Self = @This();
const api = @import("api.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
pub const Options = struct {
    attachments: []const Attachment,
    frame_healthy: *bool,
    pub const Attachment = struct {
        target: union(enum) { texture: Texture, target: Target },
        clear_color: ?[4]f32 = null,
    };
};
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?*api.Buffer = null,
    buffers: []const ?*api.Buffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: struct {
        type: enum { triangle, triangle_strip },
        vertex_count: usize,
        instance_count: usize = 1,
    },
};
attachments: []const Options.Attachment,
frame_healthy: *bool,
step_number: usize = 0,
pub fn begin(opts: Options) Self {
    return .{ .attachments = opts.attachments, .frame_healthy = opts.frame_healthy };
}
pub fn step(self: *Self, s: Step) !void {
    if (s.draw.instance_count == 0) return;
    errdefer self.frame_healthy.* = false;
    if (self.attachments.len != 1) return error.Direct3D11UnsupportedAttachment;
    const target = switch (self.attachments[0].target) {
        .target => |t| t,
        .texture => return error.Direct3D11CustomShadersUnsupported,
    };
    if (self.step_number == 0) if (self.attachments[0].clear_color) |color| {
        try api.check(api.noctty_d3d11_clear(target.handle, &color));
    };
    switch (s.pipeline.kind) {
        .image, .bg_image => return error.Direct3D11ImagesUnsupported,
        else => {},
    }
    const text = if (s.buffers.len > 0) s.buffers[0] else null;
    const bg = if (s.buffers.len > 1) s.buffers[1] else null;
    const gray = if (s.textures.len > 0) if (s.textures[0]) |t| t.handle else null else null;
    const color = if (s.textures.len > 1) if (s.textures[1]) |t| t.handle else null else null;
    try api.check(api.noctty_d3d11_draw(target.handle, @intFromEnum(s.pipeline.kind), s.uniforms, text, bg, gray, color, @intCast(s.draw.vertex_count), @intCast(s.draw.instance_count)));
    self.step_number += 1;
}
pub fn complete(_: *const Self) void {}
