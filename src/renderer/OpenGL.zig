//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const windows = std.os.windows;
const gl = @import("opengl");
const shadertoy = if (build_config.custom_shaders)
    @import("shadertoy.zig")
else
    @import("shadertoy_stub.zig");
const apprt = @import("../apprt.zig");
const Atlas = @import("../font/Atlas.zig");
const Config = @import("../config/Config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Because OpenGL's frame completion is always
/// sync, we have no need for multi-buffering.
pub const swap_chain_count = 1;

const log = std.log.scoped(.opengl);
const WglSwapIntervalExt = *const fn (interval: c_int) callconv(.winapi) windows.BOOL;
const wgl_swap_interval_ext_name: [*:0]const u8 = "wglSwapIntervalEXT";
const enable_gl_debug_output = false;
/// Bound on the driver strings read for the startup diagnostic. The Win32
/// failure record owns the real capacity; other targets never reach this
/// path, so they keep an unbounded scan only to stay compiling.
const startup_gl_string_max_len: usize = if (apprt.runtime == apprt.win32)
    apprt.win32.OpenGLStartupString.capacity
else
    std.math.maxInt(usize);

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

pub const TargetStrategy = enum {
    offscreen,
    default_framebuffer,
};

pub const TargetStrategyOptions = struct {
    win32: bool,
    custom_shaders: bool,
    default_framebuffer_srgb: bool,
    linear_blending: bool,
};

pub fn targetStrategy(opts: TargetStrategyOptions) TargetStrategy {
    if (opts.win32 and
        !opts.custom_shaders and
        opts.default_framebuffer_srgb and
        opts.linear_blending)
    {
        return .default_framebuffer;
    }
    return .offscreen;
}

pub fn targetStrategyRequiresBlit(strategy: TargetStrategy) bool {
    return strategy == .offscreen;
}

const DefaultFramebufferInfo = struct {
    framebuffer: gl.Framebuffer,
    srgb: bool,
};

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: Config.AlphaBlending,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// Runtime surface used for context ownership and size queries on Win32.
rt_surface: *apprt.Surface,
vsync_enabled: bool,
swap_interval_configured: bool = false,
swap_interval_supported: bool = false,
default_framebuffer: gl.Framebuffer,
default_framebuffer_srgb: bool,

/// NOTE: This is fallible to satisfy the renderer init interface, even though
///       OpenGL setup here cannot currently fail.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!OpenGL {
    const default_framebuffer: DefaultFramebufferInfo = if (apprt.runtime == apprt.win32)
        queryDefaultFramebufferInfo() catch |err| info: {
            log.warn(
                "unable to verify default framebuffer color encoding; retaining offscreen target err={}",
                .{err},
            );
            break :info .{
                .framebuffer = .{ .id = 0 },
                .srgb = false,
            };
        }
    else
        .{
            .framebuffer = .{ .id = 0 },
            .srgb = false,
        };

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .rt_surface = opts.rt_surface,
        .vsync_enabled = opts.config.vsync,
        .default_framebuffer = default_framebuffer.framebuffer,
        .default_framebuffer_srgb = default_framebuffer.srgb,
    };
}

fn queryDefaultFramebufferInfo() gl.errors.Error!DefaultFramebufferInfo {
    var framebuffer: gl.c.GLint = 0;
    gl.glad.context.GetIntegerv.?(
        gl.c.GL_DRAW_FRAMEBUFFER_BINDING,
        &framebuffer,
    );
    try gl.errors.getError();
    if (!defaultFramebufferBindingIsUsable(framebuffer)) {
        return error.InvalidOperation;
    }

    var encoding: gl.c.GLint = 0;
    gl.glad.context.GetFramebufferAttachmentParameteriv.?(
        gl.c.GL_DRAW_FRAMEBUFFER,
        gl.c.GL_BACK_LEFT,
        gl.c.GL_FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING,
        &encoding,
    );
    try gl.errors.getError();

    return .{
        .framebuffer = .{ .id = @intCast(framebuffer) },
        .srgb = encoding == gl.c.GL_SRGB,
    };
}

pub fn defaultFramebufferBindingIsUsable(framebuffer: gl.c.GLint) bool {
    return framebuffer == 0;
}

pub fn deinit(self: *OpenGL) void {
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = gl.glad.load(getProcAddress) catch |err| {
        recordWin32OpenGLStartupError(.load_functions, err);
        return err;
    };
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.debug("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. noctty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        // Queried only on this below-floor branch; a successful start does
        // no extra work.
        recordWin32OpenGLStartupVersionError(
            major,
            minor,
            startupGLString(gl.c.GL_RENDERER),
            startupGLString(gl.c.GL_VENDOR),
        );
        return error.OpenGLOutdated;
    }

    if (enable_gl_debug_output) {
        // Enable debug output for the context.
        try gl.enable(gl.c.GL_DEBUG_OUTPUT);

        // Register our debug message callback with the OpenGL context.
        gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);
    }

    // Enable SRGB framebuffer for linear blending support.
    gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        recordWin32OpenGLStartupError(.framebuffer_srgb, err);
        return err;
    };
}

fn recordWin32OpenGLStartupError(step: apprt.win32.OpenGLStartupStep, err: anyerror) void {
    if (apprt.runtime == apprt.win32) {
        apprt.win32.recordOpenGLStartupError(step, err);
    }
}

fn recordWin32OpenGLStartupVersionError(
    major: u32,
    minor: u32,
    renderer: ?[]const u8,
    vendor: ?[]const u8,
) void {
    if (apprt.runtime == apprt.win32) {
        apprt.win32.recordOpenGLStartupVersionError(major, minor, renderer, vendor);
    }
}

/// Read at most `max_len` bytes of a C string, stopping at the first NUL.
///
/// The scan itself is bounded, not just its result. Letting `std.mem.span`
/// find the terminator would be wrong twice over: it is unbounded, so an
/// unterminated buffer is scanned until it faults; and it is vectorized, so
/// it can read a whole chunk past the NUL of a short string. This loop reads
/// one byte at a time and never touches an index at or beyond `max_len`.
fn boundedCString(ptr: [*]const u8, max_len: usize) []const u8 {
    var len: usize = 0;
    while (len < max_len and ptr[len] != 0) len += 1;
    return ptr[0..len];
}

fn startupGLString(name: gl.c.GLenum) ?[]const u8 {
    const get_string = gl.glad.context.GetString orelse return null;
    const value = get_string(name);
    if (value == null) return null;

    // This runs only on the below-floor branch, i.e. precisely when the
    // driver is old or malfunctioning, so do not assume it honoured the
    // spec's promise of a NUL-terminated string.
    return boundedCString(@ptrCast(value), startup_gl_string_max_len);
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.win32 => {
            log.debug("OpenGL.surfaceInit win32 begin", .{});
            var loader_dialogs = apprt.win32.suppressStartupLoaderErrorDialogs();
            defer loader_dialogs.restore();

            try surface.makeGLContextCurrent();
            log.debug("OpenGL.surfaceInit win32 current", .{});
            try prepareContext(&apprt.win32.getProcAddress);
            apprt.win32.clearOpenGLStartupFailure();
            log.debug("OpenGL.surfaceInit win32 prepared", .{});
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer
/// thread for final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;

    switch (apprt.runtime) {
        else => {},

        apprt.win32 => surface.clearGLContextCurrent(),
    }
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.win32 => {
            _ = surface;
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.win32 => self.rt_surface.clearGLContextCurrent(),

        apprt.embedded => {
            // TODO: see threadEnter
        },
    }
}

fn makeSurfaceContextCurrentForDeinit(surface: anytype) !void {
    try surface.makeGLContextCurrent();
}

/// Renderer resources are owned by a pane's WGL context. Core surface
/// teardown runs on the app thread after the renderer thread has exited, so
/// rebind the owning context before deleting buffers, textures, and shaders.
/// Otherwise those deletes target whichever surviving pane was current last.
pub fn prepareSurfaceDeinit(
    self: *const OpenGL,
    surface: *apprt.Surface,
) !void {
    _ = self;
    switch (apprt.runtime) {
        else => {},
        apprt.win32 => try makeSurfaceContextCurrentForDeinit(surface),
    }
}

test "OpenGL surface teardown makes the owning context current" {
    const Probe = struct {
        made_current: bool = false,

        fn makeGLContextCurrent(self: *@This()) !void {
            self.made_current = true;
        }
    };

    var probe: Probe = .{};
    try makeSurfaceContextCurrentForDeinit(&probe);
    try std.testing.expect(probe.made_current);
}

pub fn displayRealized(self: *const OpenGL) void {
    _ = self;
}

fn ensureWin32SwapInterval(self: *OpenGL) void {
    if (apprt.runtime != apprt.win32) return;
    if (self.swap_interval_configured) return;
    self.swap_interval_configured = true;

    const proc = apprt.win32.getProcAddress(wgl_swap_interval_ext_name) orelse {
        log.debug("WGL swap interval extension unavailable; leaving window-vsync unmanaged", .{});
        return;
    };
    const set_swap_interval: WglSwapIntervalExt = @ptrCast(@alignCast(proc));
    const interval: c_int = if (self.vsync_enabled) 1 else 0;
    if (set_swap_interval(interval) == 0) {
        log.warn("failed to configure WGL swap interval interval={}", .{interval});
        return;
    }

    self.swap_interval_supported = true;
    log.debug("configured WGL swap interval interval={}", .{interval});
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}

pub fn hasVsync(self: *const OpenGL) bool {
    return self.vsync_enabled and self.swap_interval_supported;
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    switch (apprt.runtime) {
        apprt.win32 => {
            const size = try self.rt_surface.getSize();
            return .{
                .width = @intCast(size.width),
                .height = @intCast(size.height),
            };
        },

        else => {
            var viewport: [4]gl.c.GLint = undefined;
            gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
            return .{
                .width = @intCast(viewport[2]),
                .height = @intCast(viewport[3]),
            };
        },
    }
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(
    self: *const OpenGL,
    width: usize,
    height: usize,
    custom_shaders: bool,
) !Target {
    return switch (self.selectTargetStrategy(custom_shaders)) {
        .default_framebuffer => Target.initDefault(
            self.default_framebuffer,
            width,
            height,
        ),
        .offscreen => Target.init(.{
            .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
            .width = width,
            .height = height,
        }),
    };
}

pub fn selectTargetStrategy(
    self: *const OpenGL,
    custom_shaders: bool,
) TargetStrategy {
    return targetStrategy(.{
        .win32 = apprt.runtime == apprt.win32,
        .custom_shaders = custom_shaders,
        .default_framebuffer_srgb = self.default_framebuffer_srgb,
        .linear_blending = self.blending.isLinear(),
    });
}

/// Present the provided target.
pub fn present(self: *OpenGL, target: Target) !void {
    if (target.width == 0 or target.height == 0) return;

    if (apprt.runtime == apprt.win32) {
        try self.rt_surface.makeGLContextCurrent();
        self.ensureWin32SwapInterval();
    }

    const strategy: TargetStrategy = switch (target.storage) {
        .offscreen => .offscreen,
        .default_framebuffer => .default_framebuffer,
    };

    if (targetStrategyRequiresBlit(strategy)) {
        // The offscreen target stores sRGB values. Disable conversion while
        // copying those values to the window's default framebuffer.
        try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
        defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
            log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
        };

        const fbobind = try target.framebuffer.bind(.read);
        defer fbobind.unbind();

        const dst_width: i32, const dst_height: i32 = if (apprt.runtime == apprt.win32) size: {
            const size = try self.surfaceSize();
            break :size .{ @intCast(size.width), @intCast(size.height) };
        } else .{ @intCast(target.width), @intCast(target.height) };

        if (dst_width <= 0 or dst_height <= 0) return;

        gl.glad.context.BlitFramebuffer.?(
            0,
            0,
            @intCast(target.width),
            @intCast(target.height),
            0,
            0,
            dst_width,
            dst_height,
            gl.c.GL_COLOR_BUFFER_BIT,
            gl.c.GL_NEAREST,
        );
    }

    // Keep track of this target in case we need to repeat it.
    self.last_target = target;

    if (apprt.runtime == apprt.win32) {
        try self.rt_surface.swapGLBuffers();
    }
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2D",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2D",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .Rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}

test "OpenGL startup driver strings bound the scan, not just the result" {
    // Terminated and short: stops at the NUL and never reaches the trailing
    // filler, which stands in for whatever follows the driver's buffer.
    const terminated = "GDI Generic\x00\xAA\xAA\xAA\xAA\xAA\xAA\xAA\xAA";
    try std.testing.expectEqualStrings(
        "GDI Generic",
        boundedCString(terminated.ptr, 128),
    );

    // Unterminated: the scan stops at the cap instead of running on. Sizing
    // the backing buffer to exactly `max_len` means reading even one byte
    // past the bound would be an out-of-bounds index.
    var unterminated: [16]u8 = @splat('x');
    const bounded = boundedCString(&unterminated, unterminated.len);
    try std.testing.expectEqual(@as(usize, 16), bounded.len);
    try std.testing.expectEqualStrings("xxxxxxxxxxxxxxxx", bounded);

    // Truncation still happens when the string is longer than the cap.
    var long: [64]u8 = @splat('y');
    try std.testing.expectEqual(@as(usize, 8), boundedCString(&long, 8).len);

    // Degenerate cases.
    try std.testing.expectEqualStrings("", boundedCString("\x00abc".ptr, 4));
    try std.testing.expectEqualStrings("", boundedCString("abc".ptr, 0));
}

test "OpenGL hasVsync requires enabled swap interval" {
    var api: OpenGL = undefined;
    api.vsync_enabled = true;
    api.swap_interval_supported = false;
    try std.testing.expect(!api.hasVsync());

    api.swap_interval_supported = true;
    try std.testing.expect(api.hasVsync());

    api.vsync_enabled = false;
    try std.testing.expect(!api.hasVsync());
}

test "OpenGL direct default target policy preserves unsupported paths" {
    try std.testing.expectEqual(
        TargetStrategy.default_framebuffer,
        targetStrategy(.{
            .win32 = true,
            .custom_shaders = false,
            .default_framebuffer_srgb = true,
            .linear_blending = true,
        }),
    );
    try std.testing.expectEqual(
        TargetStrategy.offscreen,
        targetStrategy(.{
            .win32 = true,
            .custom_shaders = true,
            .default_framebuffer_srgb = true,
            .linear_blending = true,
        }),
    );
    try std.testing.expectEqual(
        TargetStrategy.offscreen,
        targetStrategy(.{
            .win32 = false,
            .custom_shaders = false,
            .default_framebuffer_srgb = true,
            .linear_blending = true,
        }),
    );
    try std.testing.expectEqual(
        TargetStrategy.offscreen,
        targetStrategy(.{
            .win32 = true,
            .custom_shaders = false,
            .default_framebuffer_srgb = false,
            .linear_blending = true,
        }),
    );
    try std.testing.expectEqual(
        TargetStrategy.offscreen,
        targetStrategy(.{
            .win32 = true,
            .custom_shaders = false,
            .default_framebuffer_srgb = true,
            .linear_blending = false,
        }),
    );
}

test "OpenGL direct default target presents without an offscreen blit" {
    try std.testing.expect(!targetStrategyRequiresBlit(.default_framebuffer));
    try std.testing.expect(targetStrategyRequiresBlit(.offscreen));
}

test "OpenGL direct default target rejects a stray framebuffer binding" {
    try std.testing.expect(defaultFramebufferBindingIsUsable(0));
    try std.testing.expect(!defaultFramebufferBindingIsUsable(1));
    try std.testing.expect(!defaultFramebufferBindingIsUsable(-1));
}
