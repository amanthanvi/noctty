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
    /// The window composes the frame's alpha (`OpenGL.composed_alpha`):
    /// presenting converts it from a sampled offscreen target.
    composed_alpha: bool = false,
};

pub fn targetStrategy(opts: TargetStrategyOptions) TargetStrategy {
    if (opts.composed_alpha) return .offscreen;
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

/// noctty divergence (#640): the window composes this renderer's alpha
/// (Win32 blur-behind), so the frame must reach it as sRGB-premultiplied
/// pixels. With linear blending the target holds linear premultiplied color
/// that the framebuffer sRGB-encodes, `srgb(c * a)`, which DWM would show too
/// bright; presenting then converts it (`present_composed.f.glsl`). Set by the
/// generic renderer from the window's opacity (`syncComposedAlpha`). False
/// leaves the targets and the present exactly as upstream's.
composed_alpha: bool = false,
present_composed: ?Pipeline = null,
present_composed_failed: bool = false,
/// The last conversion failed to draw: until one draws, the next frame's
/// split dim is drawn into it (`presentsComposed`), where the blit keeps it.
present_composed_draw_failed: bool = false,
present_composed_draw_logged: bool = false,

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
        .default_framebuffer_srgb = default_framebuffer.srgb and !build_config.renderer_test_tools,
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
    if (self.present_composed) |pipeline| pipeline.deinit();
    self.* = undefined;
}

/// Whether presenting converts the frame for a window that composes its
/// alpha: only when blending is linear. Native blending already writes
/// sRGB-premultiplied pixels.
fn convertsComposed(self: *const OpenGL) bool {
    return self.composed_alpha and self.blending.isLinear();
}

/// Whether presenting `target` converts it for a window that composes its
/// alpha, so that an unfocused split's dim is laid over it there, after the
/// conversion (`Target.composed_dim`), rather than drawn into it. Only a
/// sampled target is converted, and not once the conversion pipeline has
/// failed to build, nor while the last conversion failed to draw: the dim is
/// then drawn into the frame, as upstream's, so the blit that stands in for
/// the conversion still shows it.
pub fn presentsComposed(self: *const OpenGL, target: Target) bool {
    return target.texture != null and
        !self.present_composed_failed and
        !self.present_composed_draw_failed;
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

// GLAD is shared by every context on this thread. Keep the last successfully
// prepared table so a failed new context cannot poison existing OpenGL panes.
threadlocal var prepared_dispatch: ?gl.glad.Context = null;

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    // A loader can fail before initializing its handle or any function slots.
    // Stage a zeroed candidate; cleanup and rollback are valid even then.
    gl.glad.context = std.mem.zeroes(gl.glad.Context);
    errdefer {
        if (prepared_dispatch) |previous| {
            gl.glad.context = previous;
        } else {
            gl.glad.unload();
        }
    }
    const version = gl.glad.load(getProcAddress) catch |err| {
        recordWin32OpenGLStartupError(.load_functions, err);
        return err;
    };
    var major = gl.glad.versionMajor(@intCast(version));
    var minor = gl.glad.versionMinor(@intCast(version));
    if (comptime build_config.renderer_test_tools) {
        // A real context and pixel format exist by now, as on a machine whose
        // only OpenGL is GDI Generic 1.1; only the version is made up.
        if (std.process.hasEnvVarConstant("NOCTTY_RENDERER_FAIL_OPENGL_VERSION")) {
            major = 1;
            minor = 1;
        }
    }
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
    prepared_dispatch = gl.glad.context;
}

test "failed context preparation preserves the previous GL dispatch" {
    const previous = prepared_dispatch;
    defer {
        prepared_dispatch = previous;
        if (previous) |dispatch| gl.glad.context = dispatch;
    }
    var dispatch = std.mem.zeroes(gl.glad.Context);
    dispatch.VERSION_4_3 = 1;
    prepared_dispatch = dispatch;
    gl.glad.context = dispatch;
    const Loader = struct {
        fn missing(_: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
            return null;
        }
    };
    try std.testing.expectError(error.GLInitFailed, prepareContext(&Loader.missing));
    try std.testing.expectEqual(@as(c_int, 1), gl.glad.context.VERSION_4_3);
    prepared_dispatch = null;
    gl.glad.context = undefined;
    try std.testing.expectError(error.GLInitFailed, prepareContext(&Loader.missing));
    try std.testing.expect(prepared_dispatch == null);
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
            surface.renderer_gl_prepared = true;
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
            .sampled = self.convertsComposed(),
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
        .composed_alpha = self.convertsComposed(),
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

        if (target.texture) |texture| if (self.presentComposed(texture, target.composed_dim, dst_width, dst_height)) {
            self.last_target = target;
            if (apprt.runtime == apprt.win32) try self.rt_surface.swapGLBuffers();
            return;
        };

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

/// Draws a sampled target into the window's framebuffer as
/// sRGB-premultiplied pixels (`composed_alpha`), with an unfocused split's
/// `dim` laid over them. Returns false, having drawn nothing, when the
/// conversion cannot be drawn: the caller blits as upstream does, too bright
/// and, for that frame, undimmed but shown. Either failure is logged once:
/// a pipeline that cannot be built is not tried again, a draw that fails is,
/// and until one draws the split dim goes into the frame
/// (`present_composed_draw_failed`), so it is not lost on every frame.
fn presentComposed(self: *OpenGL, texture: gl.Texture, dim: ?[4]u8, width: i32, height: i32) bool {
    if (self.present_composed == null) {
        if (self.present_composed_failed) return false;
        self.present_composed = shaders.initPresentComposedPipeline() catch |err| {
            self.present_composed_failed = true;
            log.warn("composed-alpha present pipeline unavailable err={}; presenting unconverted", .{err});
            return false;
        };
    }
    const pipeline = self.present_composed.?;
    self.drawComposed(pipeline, texture, dim, width, height) catch |err| {
        self.present_composed_draw_failed = true;
        if (!self.present_composed_draw_logged) {
            self.present_composed_draw_logged = true;
            log.warn("composed-alpha present failed err={}; presenting unconverted (logged once)", .{err});
        }
        return false;
    };
    self.present_composed_draw_failed = false;
    return true;
}

fn drawComposed(self: *const OpenGL, pipeline: Pipeline, texture: gl.Texture, dim: ?[4]u8, width: i32, height: i32) !void {
    const fbobind = try self.default_framebuffer.bind(.draw);
    defer fbobind.unbind();
    try gl.viewport(0, 0, width, height);
    try gl.disable(gl.c.GL_BLEND);
    const pbind = try pipeline.program.use();
    defer pbind.unbind();
    try pipeline.program.setUniform("dst_size", @Vector(2, f32){ @floatFromInt(width), @floatFromInt(height) });
    try pipeline.program.setUniform("dim", composedDimUniform(dim));
    try gl.Texture.active(0);
    const texbind = try texture.bind(.@"2D");
    defer texbind.unbind();
    const vaobind = try pipeline.vao.bind();
    defer vaobind.unbind();
    try gl.drawArrays(gl.c.GL_TRIANGLES, 0, 3);
}

/// The conversion's `dim` uniform: the fill and its alpha, 0-1; zero for no
/// dim, which leaves every pixel as converted.
fn composedDimUniform(dim: ?[4]u8) @Vector(4, f32) {
    const bytes = dim orelse return @splat(0);
    var result: @Vector(4, f32) = undefined;
    inline for (0..4) |i| result[i] = @as(f32, @floatFromInt(bytes[i])) / 255.0;
    return result;
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Test-only PrintWindow transport, compiled with -Drenderer-test-tools=true.
pub fn capture(self: *OpenGL, hdc: *anyopaque) !void {
    if (!build_config.renderer_test_tools) return error.TestToolsDisabled;
    const target = self.last_target orelse return error.NoCapturedFrame;
    if (target.storage != .offscreen) return error.CaptureDefaultFramebufferUnsupported;
    const pixels = try self.alloc.alloc(u8, target.width * target.height * 4);
    defer self.alloc.free(pixels);
    var previous_framebuffer: gl.c.GLint = 0;
    var previous_buffer: gl.c.GLint = 0;
    gl.glad.context.GetIntegerv.?(gl.c.GL_READ_FRAMEBUFFER_BINDING, &previous_framebuffer);
    gl.glad.context.GetIntegerv.?(gl.c.GL_READ_BUFFER, &previous_buffer);
    defer {
        gl.glad.context.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, @intCast(previous_framebuffer));
        gl.glad.context.ReadBuffer.?(@intCast(previous_buffer));
    }
    gl.glad.context.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, target.framebuffer.id);
    gl.glad.context.ReadBuffer.?(gl.c.GL_COLOR_ATTACHMENT0);
    gl.glad.context.ReadPixels.?(0, 0, @intCast(target.width), @intCast(target.height), gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, pixels.ptr);
    try gl.errors.getError();
    log.info("renderer readback storage={s} framebuffer={d} first_pixel={d},{d},{d},{d}", .{
        @tagName(target.storage), target.framebuffer.id, pixels[0], pixels[1], pixels[2], pixels[3],
    });
    if (noctty_renderer_blit(hdc, pixels.ptr, @intCast(target.width), @intCast(target.height), 1) == 0)
        return error.CaptureBlitFailed;
}

extern fn noctty_renderer_blit(*anyopaque, [*]u8, u32, u32, c_int) c_int;

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

test "OpenGL a composed frame always renders offscreen, to be converted as it is presented" {
    for ([_]bool{ false, true }) |win32| for ([_]bool{ false, true }) |custom| for ([_]bool{ false, true }) |srgb| {
        try std.testing.expectEqual(TargetStrategy.offscreen, targetStrategy(.{
            .win32 = win32,
            .custom_shaders = custom,
            .default_framebuffer_srgb = srgb,
            .linear_blending = true,
            .composed_alpha = true,
        }));
    };
}

/// `present_composed.f.glsl`, on one 8-bit RGBA pixel, for its tests: the
/// shader runs on the GPU only. The dim goes through the uniform `present`
/// sets.
fn composedPixel(stored: [4]u8, dim: ?[4]u8) [4]u8 {
    const d: [4]f32 = composedDimUniform(dim);
    const a = unitOf(stored[3]);
    var out: [4]u8 = undefined;
    for (0..3) |i| {
        // Sampling the sRGB texture decodes the channel.
        const converted = if (a <= 0)
            0
        else
            srgbEncode(std.math.clamp(srgbDecode(unitOf(stored[i])) / a, 0.0, 1.0)) * a;
        out[i] = byteOf(d[i] * d[3] + converted * (1 - d[3]));
    }
    out[3] = byteOf(d[3] + a * (1 - d[3]));
    return out;
}

/// The `split_dim` pass on one stored pixel: the fill, premultiplied by its
/// alpha in `bg_color.f.glsl`, blended over the stored bytes with
/// `GL_ONE, GL_ONE_MINUS_SRC_ALPHA` and `GL_FRAMEBUFFER_SRGB` off.
fn dimmedInTarget(stored: [4]u8, dim: [4]u8) [4]u8 {
    const d: [4]f32 = composedDimUniform(dim);
    var out: [4]u8 = undefined;
    for (0..3) |i| out[i] = byteOf(d[i] * d[3] + unitOf(stored[i]) * (1 - d[3]));
    out[3] = byteOf(d[3] + unitOf(stored[3]) * (1 - d[3]));
    return out;
}

fn unitOf(byte: u8) f64 {
    return @as(f64, @floatFromInt(byte)) / 255.0;
}

fn byteOf(unit: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(unit, 0.0, 1.0) * 255.0));
}

/// What the passes leave in the target for the sRGB color `c` (0-255) at
/// alpha `a`: linear premultiplied, sRGB-encoded by the framebuffer.
fn storedPixel(c: u8, a: u8) u8 {
    const alpha: f64 = @as(f64, @floatFromInt(a)) / 255.0;
    const linear = srgbDecode(@as(f64, @floatFromInt(c)) / 255.0) * alpha;
    return @intFromFloat(@round(srgbEncode(linear) * 255.0));
}

fn srgbDecode(v: f64) f64 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

fn srgbEncode(v: f64) f64 {
    return if (v <= 0.0031308) v * 12.92 else std.math.pow(f64, v, 1.0 / 2.4) * 1.055 - 0.055;
}

test "OpenGL a composed frame reaches the window as sRGB-premultiplied pixels" {
    // White and mid-grey at 0.5: what the target holds, and what DWM is
    // given. White unconverted is 188 over alpha 128, not even premultiplied.
    try std.testing.expectEqual(@as(u8, 188), storedPixel(255, 128));
    try std.testing.expectEqual([4]u8{ 128, 128, 128, 128 }, composedPixel(.{ 188, 188, 188, 128 }, null));
    // Mid-grey: 128 * 128 / 255 is 64.3, and the target's 8 bits leave 65.
    try std.testing.expectEqual(@as(u8, 93), storedPixel(128, 128));
    try std.testing.expectEqual([4]u8{ 65, 65, 65, 128 }, composedPixel(.{ 93, 93, 93, 128 }, null));
    // A dark theme's background moves only a little.
    try std.testing.expectEqual(@as(u8, 27), storedPixel(40, 128));
    try std.testing.expectEqual([4]u8{ 20, 20, 20, 128 }, composedPixel(.{ 27, 27, 27, 128 }, null));
    // Opaque pixels, text and opaque cells, come out as they were, and a
    // pixel with no alpha stays empty.
    for (0..256) |v| {
        const c: u8 = @intCast(v);
        try std.testing.expectEqual([4]u8{ c, c, c, 255 }, composedPixel(.{ c, c, c, 255 }, null));
    }
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, composedPixel(.{ 0, 0, 0, 0 }, null));
    // Every color at a few opacities ends within a level of `c * a`, which
    // is what the chrome around the pane paints (`AlphaPaint`).
    for ([_]u8{ 26, 128, 191, 230 }) |a| for (0..256) |v| {
        const c: u8 = @intCast(v);
        const want: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(c)) * @as(f64, @floatFromInt(a)) / 255.0));
        const got: i32 = composedPixel(.{ storedPixel(c, a), 0, 0, a }, null)[0];
        try std.testing.expect(@abs(got - want) <= 1);
    };
}

test "OpenGL an unfocused split in a composed frame is dimmed after the conversion" {
    // #678, Sol's case: a white background at opacity 0, dimmed by its
    // default fill (the background) at `unfocused-split-opacity = 0.7`. The
    // pane holds nothing, so the dim alone shows: 0.3 of white.
    const clear = [4]u8{ storedPixel(255, 0), storedPixel(255, 0), storedPixel(255, 0), 0 };
    const white_dim = [4]u8{ 255, 255, 255, 77 };
    try std.testing.expectEqual([4]u8{ 77, 77, 77, 77 }, composedPixel(clear, white_dim));
    // Greptile's case: white at 0.5 under a black dim at 0.3, 128 * 0.7.
    const half_white = [4]u8{ 188, 188, 188, 128 };
    const black_dim = [4]u8{ 0, 0, 0, 77 };
    try std.testing.expectEqual([4]u8{ 89, 89, 89, 166 }, composedPixel(half_white, black_dim));
    // The old order, the dim drawn into the target and converted with it,
    // read the dim's gamma bytes as linear light: 41 for 77, 104 for 89.
    try std.testing.expectEqual([4]u8{ 41, 41, 41, 77 }, composedPixel(dimmedInTarget(clear, white_dim), null));
    try std.testing.expectEqual([4]u8{ 104, 104, 104, 166 }, composedPixel(dimmedInTarget(half_white, black_dim), null));
    // An opaque pixel, text or an opaque cell, is dimmed exactly as the
    // `split_dim` pass dims any other frame: upstream's gamma-space dim.
    for (0..256) |v| for ([_]u8{ 0, 12, 128, 255 }) |f| for ([_]u8{ 26, 77, 128, 217 }) |alpha| {
        const c: u8 = @intCast(v);
        const pixel = [4]u8{ c, c, c, 255 };
        const dim = [4]u8{ f, f, f, alpha };
        try std.testing.expectEqual(dimmedInTarget(pixel, dim), composedPixel(pixel, dim));
    };
}

test "OpenGL a composed target takes the split dim at present only while its conversion can be drawn" {
    var gl_api: OpenGL = undefined;
    gl_api.present_composed_failed = false;
    gl_api.present_composed_draw_failed = false;
    var sampled = Target.initDefault(.{ .id = 0 }, 1, 1);
    sampled.storage = .offscreen;
    sampled.texture = .{ .id = 1 };
    const unsampled = Target.initDefault(.{ .id = 0 }, 1, 1);
    try std.testing.expect(gl_api.presentsComposed(sampled));
    try std.testing.expect(!gl_api.presentsComposed(unsampled));
    // A conversion that last failed to draw, or a pipeline that failed to
    // build, leaves the frame to the blit, so the dim is drawn into it, as
    // upstream's.
    gl_api.present_composed_draw_failed = true;
    try std.testing.expect(!gl_api.presentsComposed(sampled));
    gl_api.present_composed_draw_failed = false;
    gl_api.present_composed_failed = true;
    try std.testing.expect(!gl_api.presentsComposed(sampled));
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
