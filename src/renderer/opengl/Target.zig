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

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
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
    self.renderbuffer.?.destroy();
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
