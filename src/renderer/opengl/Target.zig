//! Represents a render target.
//!
//! On Win32 this can render directly to the window's default framebuffer when
//! the renderer does not need an offscreen custom-shader target. Other paths
//! retain the owned renderbuffer-backed framebuffer.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const log = std.log.scoped(.opengl);

/// Options for initializing a Target
pub const Options = struct {
    /// Desired width
    width: usize,
    /// Desired height
    height: usize,

    /// Internal format for the renderbuffer.
    internal_format: gl.Texture.InternalFormat,

    /// Back the target with a texture instead of a renderbuffer, so that
    /// presenting can sample it (noctty, #640: a composed frame).
    sampled: bool = false,
};

pub const Storage = enum {
    offscreen,
    default_framebuffer,

    pub fn ownsResources(self: Storage) bool {
        return self == .offscreen;
    }
};

storage: Storage,

/// The underlying `gl.Framebuffer` instance.
framebuffer: gl.Framebuffer,

/// The underlying `gl.Renderbuffer` instance.
renderbuffer: ?gl.Renderbuffer,

/// The texture a sampled target renders into, in place of the renderbuffer.
texture: ?gl.Texture = null,

/// The dim of an unfocused split that presenting lays over this sampled
/// target after converting it (noctty, #640): the bytes of the fill and its
/// alpha, as `splitDimUniforms` gives them. The dim blends in gamma space on
/// the window's sRGB-premultiplied pixels, so drawn into the target first
/// the conversion would read it as linear light. Set for each frame by the
/// generic renderer (`splitDimPass`); null for no dim.
composed_dim: ?[4]u8 = null,

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    if (opts.sampled) return initSampled(opts);
    const rbo = try gl.Renderbuffer.create();
    const bound_rbo = try rbo.bind();
    defer bound_rbo.unbind();
    try bound_rbo.storage(
        opts.internal_format,
        @intCast(opts.width),
        @intCast(opts.height),
    );

    const fbo = try gl.Framebuffer.create();
    const bound_fbo = try fbo.bind(.framebuffer);
    defer bound_fbo.unbind();
    try bound_fbo.renderbuffer(.color0, rbo);

    return .{
        .storage = .offscreen,
        .framebuffer = fbo,
        .renderbuffer = rbo,
        .width = opts.width,
        .height = opts.height,
    };
}

fn initSampled(opts: Options) !Self {
    const tex = try gl.Texture.create();
    errdefer tex.destroy();
    {
        const texbind = try tex.bind(.@"2D");
        defer texbind.unbind();
        try texbind.parameter(.MinFilter, @as(gl.c.GLint, gl.c.GL_NEAREST));
        try texbind.parameter(.MagFilter, @as(gl.c.GLint, gl.c.GL_NEAREST));
        try texbind.parameter(.WrapS, @as(gl.c.GLint, gl.c.GL_CLAMP_TO_EDGE));
        try texbind.parameter(.WrapT, @as(gl.c.GLint, gl.c.GL_CLAMP_TO_EDGE));
        try texbind.image2D(
            0,
            opts.internal_format,
            @intCast(opts.width),
            @intCast(opts.height),
            .rgba,
            .UnsignedByte,
            null,
        );
    }

    const fbo = try gl.Framebuffer.create();
    errdefer fbo.destroy();
    const bound_fbo = try fbo.bind(.framebuffer);
    defer bound_fbo.unbind();
    try bound_fbo.texture2D(.color0, .@"2D", tex, 0);

    return .{
        .storage = .offscreen,
        .framebuffer = fbo,
        .renderbuffer = null,
        .texture = tex,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn initDefault(
    framebuffer: gl.Framebuffer,
    width: usize,
    height: usize,
) Self {
    std.debug.assert(framebuffer.id == 0);
    return .{
        .storage = .default_framebuffer,
        .framebuffer = framebuffer,
        .renderbuffer = null,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: *Self) void {
    if (!self.storage.ownsResources()) return;
    self.framebuffer.destroy();
    if (self.renderbuffer) |rbo| rbo.destroy();
    if (self.texture) |tex| tex.destroy();
}

test "OpenGL target storage owns only offscreen resources" {
    try std.testing.expect(Storage.offscreen.ownsResources());
    try std.testing.expect(!Storage.default_framebuffer.ownsResources());

    const target = initDefault(.{ .id = 0 }, 640, 480);
    try std.testing.expectEqual(Storage.default_framebuffer, target.storage);
    try std.testing.expectEqual(@as(gl.c.GLuint, 0), target.framebuffer.id);
    try std.testing.expectEqual(@as(?gl.Renderbuffer, null), target.renderbuffer);
    try std.testing.expectEqual(@as(usize, 640), target.width);
    try std.testing.expectEqual(@as(usize, 480), target.height);
}
