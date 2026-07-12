//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("buffer.zig").Buffer;
const apprt = @import("../../apprt.zig");

const log = std.log.scoped(.opengl);

/// Options for beginning a render pass.
pub const Options = struct {
    /// Color attachments for this render pass.
    attachments: []const Attachment,
    frame_healthy: ?*bool = null,
    frame_failure_context: ?*?[]const u8 = null,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?gl.Buffer = null,
    buffers: []const ?gl.Buffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: gl.Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

attachments: []const Options.Attachment,
frame_healthy: ?*bool = null,
frame_failure_context: ?*?[]const u8 = null,

step_number: usize = 0,

fn attachmentSize(attachment: Options.Attachment) struct { width: usize, height: usize } {
    return switch (attachment.target) {
        .target => |target| .{
            .width = target.width,
            .height = target.height,
        },
        .texture => |texture| .{
            .width = texture.width,
            .height = texture.height,
        },
    };
}

/// Begin a render pass.
pub fn begin(
    opts: Options,
) Self {
    return .{
        .attachments = opts.attachments,
        .frame_healthy = opts.frame_healthy,
        .frame_failure_context = opts.frame_failure_context,
    };
}

fn markUnhealthy(self: *Self, context: []const u8, err: anyerror) void {
    if (self.frame_healthy) |healthy| healthy.* = false;
    if (self.frame_failure_context) |failure_context| {
        if (failure_context.* == null) failure_context.* = context;
    }
    log.warn(
        "renderPass step failed step={} context={s} err={}",
        .{ self.step_number, context, err },
    );
}

fn fail(self: *Self, context: []const u8, err: anyerror) anyerror {
    self.markUnhealthy(context, err);
    return err;
}

/// Add a step to this render pass.
///
pub fn step(self: *Self, s: Step) !void {
    if (s.draw.instance_count == 0) return;
    if (apprt.runtime == apprt.win32) log.debug(
        "renderPass step begin step={} vertex_count={} instance_count={}",
        .{ self.step_number, s.draw.vertex_count, s.draw.instance_count },
    );

    const pbind = s.pipeline.program.use() catch |err| return self.fail("program.use", err);
    defer pbind.unbind();

    const vaobind = s.pipeline.vao.bind() catch |err| return self.fail("vao.bind", err);
    defer vaobind.unbind();

    const fbobind = switch (self.attachments[0].target) {
        .target => |t| t.framebuffer.bind(.framebuffer) catch |err| return self.fail("target.framebuffer.bind", err),
        .texture => |t| bind: {
            const fbobind = s.pipeline.fbo.bind(.framebuffer) catch |err| return self.fail("pipeline.fbo.bind", err);
            fbobind.texture2D(.color0, t.target, t.texture, 0) catch |err| {
                fbobind.unbind();
                return self.fail("framebuffer.texture2D", err);
            };
            break :bind fbobind;
        },
    };
    defer fbobind.unbind();

    defer self.step_number += 1;

    // Framebuffer binds do not update the GL viewport. When the window or
    // render target size changes, leaving the old viewport in place causes the
    // scene to render into the previous bottom-left sub-rect, which shows up on
    // Win32 as black growth bands on enlarge and distorted content on shrink.
    const viewport = attachmentSize(self.attachments[0]);
    gl.viewport(
        0,
        0,
        @intCast(viewport.width),
        @intCast(viewport.height),
    ) catch |err| return self.fail("viewport", err);

    // If we have a clear color and this is the
    // first step in the pass, go ahead and clear.
    if (self.step_number == 0) if (self.attachments[0].clear_color) |c| {
        gl.clearColor(c[0], c[1], c[2], c[3]);
        gl.clear(gl.c.GL_COLOR_BUFFER_BIT);
    };

    // Bind the uniform buffer at the shader layout's conventional binding point.
    if (s.uniforms) |ubo| {
        _ = ubo.bindBase(.uniform, 1) catch |err| return self.fail("uniform.bindBase", err);
    }

    // Bind relevant texture units.
    for (s.textures, 0..) |t, i| if (t) |tex| {
        gl.Texture.active(@intCast(i)) catch |err| return self.fail("texture.active", err);
        _ = tex.texture.bind(tex.target) catch |err| return self.fail("texture.bind", err);
    };

    // Bind relevant samplers.
    for (s.samplers, 0..) |s_, i| if (s_) |sampler| {
        _ = sampler.sampler.bind(@intCast(i)) catch |err| return self.fail("sampler.bind", err);
    };

    // Bind 0th buffer as the vertex buffer,
    // and bind the rest as storage buffers.
    if (s.buffers.len > 0) {
        if (s.buffers[0]) |vbo| vaobind.bindVertexBuffer(
            0,
            vbo.id,
            0,
            @intCast(s.pipeline.stride),
        ) catch |err| return self.fail("vertex_buffer.bind", err);

        for (s.buffers[1..], 1..) |b, i| if (b) |buf| {
            _ = buf.bindBase(.storage, @intCast(i)) catch |err| return self.fail("storage.bindBase", err);
        };
    }

    if (s.pipeline.blending_enabled) {
        gl.enable(gl.c.GL_BLEND) catch |err| return self.fail("blend.enable", err);
        gl.blendFunc(gl.c.GL_ONE, gl.c.GL_ONE_MINUS_SRC_ALPHA) catch |err| return self.fail("blend.func", err);
    } else {
        gl.disable(gl.c.GL_BLEND) catch |err| return self.fail("blend.disable", err);
    }

    gl.drawArraysInstanced(
        s.draw.type,
        0,
        @intCast(s.draw.vertex_count),
        @intCast(s.draw.instance_count),
    ) catch |err| return self.fail("drawArraysInstanced", err);
}

/// Complete this render pass.
/// This struct can no longer be used after calling this.
pub fn complete(self: *const Self) void {
    _ = self;
    gl.flush();
}

test "RenderPass attachmentSize uses target dimensions" {
    const attachment: Options.Attachment = .{
        .target = .{
            .target = .{
                .framebuffer = undefined,
                .renderbuffer = undefined,
                .width = 320,
                .height = 240,
            },
        },
    };

    const size = attachmentSize(attachment);
    try std.testing.expectEqual(@as(usize, 320), size.width);
    try std.testing.expectEqual(@as(usize, 240), size.height);
}

test "RenderPass attachmentSize uses texture dimensions" {
    const attachment: Options.Attachment = .{
        .target = .{
            .texture = .{
                .texture = undefined,
                .width = 640,
                .height = 360,
                .format = .rgba,
                .target = .@"2D",
            },
        },
    };

    const size = attachmentSize(attachment);
    try std.testing.expectEqual(@as(usize, 640), size.width);
    try std.testing.expectEqual(@as(usize, 360), size.height);
}

test "RenderPass markUnhealthy records first failure context" {
    var healthy = true;
    var context: ?[]const u8 = null;
    var pass = Self.begin(.{
        .attachments = &.{},
        .frame_healthy = &healthy,
        .frame_failure_context = &context,
    });

    pass.markUnhealthy("first", error.First);
    pass.markUnhealthy("second", error.Second);

    try std.testing.expect(!healthy);
    try std.testing.expectEqualStrings("first", context.?);
}
