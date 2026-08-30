//! Win32 WGL pixel-format selection.
//!
//! Split out of `win32.zig` so the window code does not carry driver
//! compatibility ranking. The renderer may only draw straight to the Win32
//! default framebuffer when a format is verified sRGB-capable, so what this
//! module returns is a correctness input, not a preference.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const c = @import("consts.zig");
const gl_startup = @import("gl_startup.zig");
const sys = @import("sys.zig");
const win32_types = @import("../win32_types.zig");

const log = std.log.scoped(.win32);

const DWORD = win32_types.DWORD;
const BYTE = win32_types.BYTE;
const BOOL = win32_types.BOOL;
const UINT = sys.UINT;
const HDC = win32_types.HDC;
const HWND = sys.HWND;
const HGLRC = win32_types.HGLRC;
const HINSTANCE = win32_types.HINSTANCE;
const WPARAM = sys.WPARAM;
const LPARAM = sys.LPARAM;
const LRESULT = win32_types.LRESULT;
const PIXELFORMATDESCRIPTOR = sys.PIXELFORMATDESCRIPTOR;
const RECT = sys.RECT;
const WNDCLASSEXW = sys.WNDCLASSEXW;

const ChoosePixelFormat = sys.ChoosePixelFormat;
const CreateWindowExW = sys.CreateWindowExW;
const DefWindowProcW = sys.DefWindowProcW;
const DescribePixelFormat = sys.DescribePixelFormat;
const DestroyWindow = sys.DestroyWindow;
const GetDC = sys.GetDC;
const GetWindowRect = sys.GetWindowRect;
const RegisterClassExW = sys.RegisterClassExW;
const ReleaseDC = sys.ReleaseDC;
const SetPixelFormat = sys.SetPixelFormat;
const UnregisterClassW = sys.UnregisterClassW;
const wglCreateContext = sys.wglCreateContext;
const wglDeleteContext = sys.wglDeleteContext;
const wglGetCurrentContext = sys.wglGetCurrentContext;
const wglGetCurrentDC = sys.wglGetCurrentDC;
const wglGetProcAddress = sys.wglGetProcAddress;
const wglMakeCurrent = sys.wglMakeCurrent;

const PFD_STEREO = 0x00000002;

const PFD_GENERIC_FORMAT = 0x00000040;

const PFD_GENERIC_ACCELERATED = 0x00001000;

const PFD_DEPTH_DONTCARE = 0x20000000;

const WGL_NUMBER_PIXEL_FORMATS_EXT = 0x2000;

const WGL_DRAW_TO_WINDOW_EXT = 0x2001;

const WGL_ACCELERATION_EXT = 0x2003;

const WGL_SUPPORT_OPENGL_EXT = 0x2010;

const WGL_DOUBLE_BUFFER_EXT = 0x2011;

const WGL_STEREO_EXT = 0x2012;

const WGL_PIXEL_TYPE_EXT = 0x2013;

const WGL_COLOR_BITS_EXT = 0x2014;

const WGL_ALPHA_BITS_EXT = 0x201B;

const WGL_ACCUM_BITS_EXT = 0x201D;

const WGL_DEPTH_BITS_EXT = 0x2022;

const WGL_STENCIL_BITS_EXT = 0x2023;

const WGL_AUX_BUFFERS_EXT = 0x2024;

const WGL_FULL_ACCELERATION_EXT = 0x2027;

const WGL_TYPE_RGBA_EXT = 0x202B;

// WGL_ARB_framebuffer_sRGB and WGL_EXT_framebuffer_sRGB define the *same*
// value for this attribute (0x20A9), and both spec it against the EXT
// pixel-format entry points. Drivers accept it through the ARB entry points
// too, which is what every mainstream loader queries.
const WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB = 0x20A9;

const WGL_SAMPLE_BUFFERS_ARB = 0x2041;

const WGL_SAMPLES_ARB = 0x2042;

const WGL_COLORSPACE_EXT = 0x309D;

const WGL_COLORSPACE_SRGB_EXT = 0x3089;

const wgl_pixel_format_inventory_attributes = [_]i32{
    WGL_DRAW_TO_WINDOW_EXT, 1,
    WGL_SUPPORT_OPENGL_EXT, 1,
    WGL_DOUBLE_BUFFER_EXT,  1,
    WGL_PIXEL_TYPE_EXT,     WGL_TYPE_RGBA_EXT,
    WGL_COLOR_BITS_EXT,     32,
    WGL_ALPHA_BITS_EXT,     8,
    0,
};

pub const WglPixelFormatProvenance = struct {
    index: u32,
    color_bits: u8,
    alpha_bits: u8,
    depth_bits: u8,
    stencil_bits: u8,
    double_buffer: bool,
    stereo: bool,
    accum_bits: u8,
    aux_buffers: u8,
    selection_source: WglPixelFormatSelectionSource,
    srgb_capable: bool,
    multisample_query_supported: bool,
    sample_buffers: ?u8,
    samples: ?u8,
    total_format_count: ?u16,
    candidate_count: ?u16,
};

const WglPixelFormatSelectionSource = enum(u8) {
    classic,
    ext_srgb,
    arb_ext_colorspace_srgb,
    arb_srgb,
};

const WglPixelFormatCandidate = struct {
    index: i32,
    color_bits: u8,
    alpha_bits: u8,
    depth_bits: u8,
    stencil_bits: u8,
    srgb_capable: bool,
    fully_accelerated: bool,
    stereo: bool = false,
    accum_bits: u8 = 0,
    aux_buffers: u8 = 0,
    multisample_query_supported: bool = false,
    sample_buffers: ?u8 = null,
    samples: ?u8 = null,
};

const WglPixelFormatRejection = enum {
    base_contract,
    nonaccelerated,
    non_srgb,
    stereo,
    multisample,
    descriptor_invalid,
};

fn classifyWglPixelFormatCandidate(
    candidate: WglPixelFormatCandidate,
    base_contract: bool,
) ?WglPixelFormatRejection {
    // Keep these disjoint and ordered so the bounded startup diagnostic adds
    // up to every returned match instead of double-counting unsuitable formats.
    if (!base_contract or candidate.color_bits < 32 or candidate.alpha_bits < 8) {
        return .base_contract;
    }
    if (!candidate.fully_accelerated) return .nonaccelerated;
    if (!candidate.srgb_capable) return .non_srgb;
    if (candidate.stereo) return .stereo;
    if (candidate.multisample_query_supported) {
        if (candidate.sample_buffers == null or
            candidate.samples == null or
            candidate.sample_buffers.? != 0 or
            candidate.samples.? != 0)
        {
            return .multisample;
        }
    } else if (candidate.sample_buffers != null or candidate.samples != null) {
        return .multisample;
    }
    return null;
}

fn wglPixelFormatCandidateUsable(candidate: WglPixelFormatCandidate) bool {
    return classifyWglPixelFormatCandidate(candidate, true) == null;
}

fn betterWglPixelFormatCandidate(
    candidate: WglPixelFormatCandidate,
    current: WglPixelFormatCandidate,
) bool {
    const candidate_accum_free = candidate.accum_bits == 0;
    const current_accum_free = current.accum_bits == 0;
    if (candidate_accum_free != current_accum_free) return candidate_accum_free;

    const candidate_aux_free = candidate.aux_buffers == 0;
    const current_aux_free = current.aux_buffers == 0;
    if (candidate_aux_free != current_aux_free) return candidate_aux_free;

    const candidate_depthless = candidate.depth_bits == 0;
    const current_depthless = current.depth_bits == 0;
    if (candidate_depthless != current_depthless) return candidate_depthless;

    const candidate_stencilless = candidate.stencil_bits == 0;
    const current_stencilless = current.stencil_bits == 0;
    if (candidate_stencilless != current_stencilless) return candidate_stencilless;
    if (candidate.accum_bits != current.accum_bits) return candidate.accum_bits < current.accum_bits;
    if (candidate.aux_buffers != current.aux_buffers) return candidate.aux_buffers < current.aux_buffers;
    if (candidate.depth_bits != current.depth_bits) return candidate.depth_bits < current.depth_bits;
    if (candidate.stencil_bits != current.stencil_bits) return candidate.stencil_bits < current.stencil_bits;
    if (candidate.color_bits != current.color_bits) return candidate.color_bits < current.color_bits;
    if (candidate.alpha_bits != current.alpha_bits) return candidate.alpha_bits < current.alpha_bits;
    return candidate.index < current.index;
}

fn rankWglPixelFormatCandidates(
    candidates: []const WglPixelFormatCandidate,
) ?WglPixelFormatCandidate {
    var selected: ?WglPixelFormatCandidate = null;
    for (candidates) |candidate| {
        if (!wglPixelFormatCandidateUsable(candidate)) continue;
        if (selected == null or betterWglPixelFormatCandidate(candidate, selected.?)) {
            selected = candidate;
        }
    }
    return selected;
}

const ClassicPixelFormatCandidate = struct {
    index: i32,
    descriptor: PIXELFORMATDESCRIPTOR,
    provenance: WglPixelFormatProvenance,
    acceleration: ClassicPixelFormatAcceleration,
};

const ClassicPixelFormatAcceleration = enum(u8) {
    generic,
    mcd,
    icd,
};

fn classicPixelFormatAcceleration(flags: DWORD) ClassicPixelFormatAcceleration {
    if (flags & PFD_GENERIC_FORMAT == 0) return .icd;
    if (flags & PFD_GENERIC_ACCELERATED != 0) return .mcd;
    return .generic;
}

fn betterClassicPixelFormatCandidate(
    candidate: ClassicPixelFormatCandidate,
    current: ClassicPixelFormatCandidate,
) bool {
    if (candidate.acceleration != current.acceleration) {
        return @intFromEnum(candidate.acceleration) > @intFromEnum(current.acceleration);
    }
    const candidate_accum_free = candidate.provenance.accum_bits == 0;
    const current_accum_free = current.provenance.accum_bits == 0;
    if (candidate_accum_free != current_accum_free) return candidate_accum_free;
    const candidate_aux_free = candidate.provenance.aux_buffers == 0;
    const current_aux_free = current.provenance.aux_buffers == 0;
    if (candidate_aux_free != current_aux_free) return candidate_aux_free;
    const candidate_depthless = candidate.provenance.depth_bits == 0;
    const current_depthless = current.provenance.depth_bits == 0;
    if (candidate_depthless != current_depthless) return candidate_depthless;
    const candidate_stencilless = candidate.provenance.stencil_bits == 0;
    const current_stencilless = current.provenance.stencil_bits == 0;
    if (candidate_stencilless != current_stencilless) return candidate_stencilless;
    if (candidate.provenance.accum_bits != current.provenance.accum_bits) {
        return candidate.provenance.accum_bits < current.provenance.accum_bits;
    }
    if (candidate.provenance.aux_buffers != current.provenance.aux_buffers) {
        return candidate.provenance.aux_buffers < current.provenance.aux_buffers;
    }
    if (candidate.provenance.depth_bits != current.provenance.depth_bits) {
        return candidate.provenance.depth_bits < current.provenance.depth_bits;
    }
    if (candidate.provenance.stencil_bits != current.provenance.stencil_bits) {
        return candidate.provenance.stencil_bits < current.provenance.stencil_bits;
    }
    return candidate.index < current.index;
}

fn rankClassicPixelFormatCandidates(
    candidates: []const ClassicPixelFormatCandidate,
) ?ClassicPixelFormatCandidate {
    var selected: ?ClassicPixelFormatCandidate = null;
    for (candidates) |candidate| {
        if (selected == null or betterClassicPixelFormatCandidate(candidate, selected.?)) {
            selected = candidate;
        }
    }
    return selected;
}

const max_wgl_pixel_formats = 1024;

fn validatedWglPixelFormatCount(total_format_count: i32) !UINT {
    if (total_format_count <= 0 or total_format_count > max_wgl_pixel_formats) {
        return error.WglPixelFormatCandidateCapacityExceeded;
    }
    return @intCast(total_format_count);
}

pub fn validatePixelFormatSetTransition(before: i32, selected: i32, after: i32) !void {
    if (before != 0) return error.PixelFormatAlreadySet;
    if (selected <= 0 or after != selected) return error.PixelFormatSetVerificationFailed;
}

fn isWglPixelFormatHardError(err: anyerror) bool {
    return switch (err) {
        error.WglBootstrapMakeCurrentFailed,
        error.WglBootstrapRestoreCurrentFailed,
        error.WglBootstrapClearCurrentFailed,
        => true,
        else => false,
    };
}

const PixelFormatBaseCompatibilityFailure = enum {
    invalid_index,
    invalid_descriptor_header,
    non_rgba,
    non_main_plane,
    missing_required_flags,
    insufficient_color,
    insufficient_alpha,
    stereo,
};

fn pixelFormatBaseCompatibilityFailure(
    pixel_format: i32,
    pfd: PIXELFORMATDESCRIPTOR,
) ?PixelFormatBaseCompatibilityFailure {
    if (pixel_format <= 0) return .invalid_index;
    if (pfd.nSize != @sizeOf(PIXELFORMATDESCRIPTOR) or pfd.nVersion != 1) {
        return .invalid_descriptor_header;
    }
    if (pfd.iPixelType != c.PFD_TYPE_RGBA) return .non_rgba;
    if (pfd.iLayerType != c.PFD_MAIN_PLANE) return .non_main_plane;
    const required_flags = c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER;
    if (pfd.dwFlags & required_flags != required_flags) return .missing_required_flags;
    if (pfd.cColorBits < 32) return .insufficient_color;
    if (pfd.cAlphaBits < 8) return .insufficient_alpha;
    if (pfd.dwFlags & PFD_STEREO != 0) return .stereo;
    return null;
}

fn validateSelectedPixelFormat(
    pixel_format: i32,
    pfd: PIXELFORMATDESCRIPTOR,
) !WglPixelFormatProvenance {
    if (pixelFormatBaseCompatibilityFailure(pixel_format, pfd) != null)
        return error.InvalidSelectedPixelFormat;

    return .{
        .index = @intCast(pixel_format),
        .color_bits = pfd.cColorBits,
        .alpha_bits = pfd.cAlphaBits,
        .depth_bits = pfd.cDepthBits,
        .stencil_bits = pfd.cStencilBits,
        .double_buffer = pfd.dwFlags & c.PFD_DOUBLEBUFFER != 0,
        .stereo = pfd.dwFlags & PFD_STEREO != 0,
        .accum_bits = pfd.cAccumBits,
        .aux_buffers = pfd.cAuxBuffers,
        .selection_source = .classic,
        .srgb_capable = false,
        .multisample_query_supported = false,
        .sample_buffers = null,
        .samples = null,
        .total_format_count = null,
        .candidate_count = null,
    };
}

const WglChoosePixelFormatExtFn = *const fn (
    hdc: HDC,
    int_attributes: ?[*]const i32,
    float_attributes: ?[*]const f32,
    max_formats: UINT,
    formats: [*]i32,
    format_count: *UINT,
) callconv(.winapi) BOOL;

const WglGetPixelFormatAttribivExtFn = *const fn (
    hdc: HDC,
    pixel_format: i32,
    layer_plane: i32,
    attribute_count: UINT,
    attributes: [*]i32,
    values: [*]i32,
) callconv(.winapi) BOOL;

const WglGetExtensionsStringExtFn = *const fn () callconv(.winapi) ?[*:0]const u8;

const WglChoosePixelFormatArbFn = *const fn (
    hdc: HDC,
    int_attributes: ?[*]const i32,
    float_attributes: ?[*]const f32,
    max_formats: UINT,
    formats: [*]i32,
    format_count: *UINT,
) callconv(.winapi) BOOL;

const WglGetPixelFormatAttribivArbFn = *const fn (
    hdc: HDC,
    pixel_format: i32,
    layer_plane: i32,
    attribute_count: UINT,
    attributes: [*]const i32,
    values: [*]i32,
) callconv(.winapi) BOOL;

const WglGetExtensionsStringArbFn = *const fn (hdc: HDC) callconv(.winapi) ?[*:0]const u8;

const WglPixelFormatExtFunctions = struct {
    choose: WglChoosePixelFormatExtFn,
    get_attributes: WglGetPixelFormatAttribivExtFn,
};

const WglPixelFormatArbFunctions = struct {
    choose: WglChoosePixelFormatArbFn,
    get_attributes: WglGetPixelFormatAttribivArbFn,
};

const WglPixelFormatFunctions = union(enum) {
    ext_framebuffer_srgb: WglPixelFormatExtFunctions,
    arb_ext_colorspace_srgb: WglPixelFormatArbFunctions,
    arb_framebuffer_srgb: WglPixelFormatArbFunctions,

    fn choose(
        self: WglPixelFormatFunctions,
        hdc: HDC,
        attributes: [*]const i32,
        max_formats: UINT,
        formats: [*]i32,
        count: *UINT,
    ) BOOL {
        return switch (self) {
            .ext_framebuffer_srgb => |functions| functions.choose(
                hdc,
                attributes,
                null,
                max_formats,
                formats,
                count,
            ),
            .arb_ext_colorspace_srgb,
            .arb_framebuffer_srgb,
            => |functions| functions.choose(
                hdc,
                attributes,
                null,
                max_formats,
                formats,
                count,
            ),
        };
    }

    fn getAttributes(
        self: WglPixelFormatFunctions,
        hdc: HDC,
        pixel_format: i32,
        attributes: []i32,
        values: [*]i32,
    ) BOOL {
        const attribute_count: UINT = @intCast(attributes.len);
        return switch (self) {
            .ext_framebuffer_srgb => |functions| functions.get_attributes(
                hdc,
                pixel_format,
                0,
                attribute_count,
                attributes.ptr,
                values,
            ),
            .arb_ext_colorspace_srgb,
            .arb_framebuffer_srgb,
            => |functions| functions.get_attributes(
                hdc,
                pixel_format,
                0,
                attribute_count,
                attributes.ptr,
                values,
            ),
        };
    }

    fn source(self: WglPixelFormatFunctions) WglPixelFormatSelectionSource {
        return switch (self) {
            .ext_framebuffer_srgb => .ext_srgb,
            .arb_ext_colorspace_srgb => .arb_ext_colorspace_srgb,
            .arb_framebuffer_srgb => .arb_srgb,
        };
    }

    fn srgbAttribute(self: WglPixelFormatFunctions) struct { name: i32, value: i32 } {
        return switch (self) {
            .ext_framebuffer_srgb, .arb_framebuffer_srgb => .{
                .name = WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB,
                .value = 1,
            },
            .arb_ext_colorspace_srgb => .{
                .name = WGL_COLORSPACE_EXT,
                .value = WGL_COLORSPACE_SRGB_EXT,
            },
        };
    }
};

/// The sRGB-capable pixel-format API pairings we will accept, in the exact
/// order `WglPixelFormatSelector.init` tries them.
///
/// The pairing rules are not interchangeable, so they are spelled out here
/// rather than inferred:
///
///   * `WGL_ARB_framebuffer_sRGB` and `WGL_EXT_framebuffer_sRGB` are both
///     written against `WGL_EXT_pixel_format` and both declare the 0x20A9
///     attribute for `wglGetPixelFormatAttribivEXT` /
///     `wglChoosePixelFormatEXT`. Despite the `_ARB` token suffix, the EXT
///     entry points are the spec-exact home of that attribute.
///   * `WGL_EXT_colorspace` is written against `WGL_ARB_pixel_format` and
///     declares `WGL_COLORSPACE_EXT` for the ARB entry points only.
///   * In practice every shipping ICD also honors 0x20A9 through
///     `wglGetPixelFormatAttribivARB`, and that de-facto pairing is what
///     mainstream loaders query. Without it we would skip the verified-sRGB
///     path entirely on a driver that advertises `WGL_ARB_pixel_format` and
///     `WGL_ARB_framebuffer_sRGB` but not `WGL_EXT_pixel_format`. It is tried
///     last so any driver exposing a spec-exact pairing keeps that path.
const wgl_srgb_api_family_order = [_]WglSrgbApiFamily{
    .ext_pixel_format_framebuffer_srgb,
    .arb_pixel_format_colorspace,
    .arb_pixel_format_framebuffer_srgb,
};

const WglSrgbApiFamily = enum {
    ext_pixel_format_framebuffer_srgb,
    arb_pixel_format_colorspace,
    arb_pixel_format_framebuffer_srgb,
};

fn hasWglFramebufferSrgbExtension(extensions: []const u8) bool {
    return hasWglExtension(extensions, "WGL_ARB_framebuffer_sRGB") or
        hasWglExtension(extensions, "WGL_EXT_framebuffer_sRGB");
}

fn wglSrgbApiFamilyAdvertised(
    family: WglSrgbApiFamily,
    extensions: []const u8,
) bool {
    return switch (family) {
        .ext_pixel_format_framebuffer_srgb => hasWglExtension(extensions, "WGL_EXT_pixel_format") and
            hasWglFramebufferSrgbExtension(extensions),
        .arb_pixel_format_colorspace => hasWglExtension(extensions, "WGL_ARB_pixel_format") and
            hasWglExtension(extensions, "WGL_EXT_colorspace"),
        .arb_pixel_format_framebuffer_srgb => hasWglExtension(extensions, "WGL_ARB_pixel_format") and
            hasWglFramebufferSrgbExtension(extensions),
    };
}

/// First family in `wgl_srgb_api_family_order` that the driver advertises,
/// or null when no valid pairing is present. `WglPixelFormatSelector.init`
/// walks the same order with the same predicate, but keeps going when a
/// family's procedures fail to resolve.
fn firstAdvertisedWglSrgbApiFamily(extensions: []const u8) ?WglSrgbApiFamily {
    for (wgl_srgb_api_family_order) |family| {
        if (wglSrgbApiFamilyAdvertised(family, extensions)) return family;
    }
    return null;
}

/// Resolve the entry points for an advertised family. Returns null when the
/// driver advertises the extension but does not hand back usable procedures,
/// so the caller can keep walking the order instead of failing closed early.
fn loadWglPixelFormatFunctions(family: WglSrgbApiFamily) ?WglPixelFormatFunctions {
    switch (family) {
        .ext_pixel_format_framebuffer_srgb => {
            const choose_raw = wglGetProcAddress("wglChoosePixelFormatEXT");
            const get_raw = wglGetProcAddress("wglGetPixelFormatAttribivEXT");
            if (!validWglProcAddress(choose_raw) or !validWglProcAddress(get_raw)) return null;
            return .{ .ext_framebuffer_srgb = .{
                .choose = @ptrCast(@alignCast(choose_raw.?)),
                .get_attributes = @ptrCast(@alignCast(get_raw.?)),
            } };
        },
        .arb_pixel_format_colorspace, .arb_pixel_format_framebuffer_srgb => {
            const choose_raw = wglGetProcAddress("wglChoosePixelFormatARB");
            const get_raw = wglGetProcAddress("wglGetPixelFormatAttribivARB");
            if (!validWglProcAddress(choose_raw) or !validWglProcAddress(get_raw)) return null;
            const functions: WglPixelFormatArbFunctions = .{
                .choose = @ptrCast(@alignCast(choose_raw.?)),
                .get_attributes = @ptrCast(@alignCast(get_raw.?)),
            };
            return if (family == .arb_pixel_format_colorspace)
                .{ .arb_ext_colorspace_srgb = functions }
            else
                .{ .arb_framebuffer_srgb = functions };
        },
    }
}

fn validWglProcAddress(raw: ?*const anyopaque) bool {
    const address = @intFromPtr(raw orelse return false);
    return address > 3 and address != std.math.maxInt(usize);
}

fn hasWglExtension(extensions: []const u8, expected: []const u8) bool {
    var iterator = std.mem.tokenizeScalar(u8, extensions, ' ');
    while (iterator.next()) |extension| {
        if (std.mem.eql(u8, extension, expected)) return true;
    }
    return false;
}

fn wglMultisampleQuerySupported(
    source: WglPixelFormatSelectionSource,
    extensions: []const u8,
) bool {
    return switch (source) {
        .ext_srgb => hasWglExtension(extensions, "WGL_ARB_multisample") or
            hasWglExtension(extensions, "WGL_EXT_multisample"),
        // WGL_SAMPLE_BUFFERS_ARB / WGL_SAMPLES_ARB are declared by
        // WGL_ARB_multisample against the ARB entry points, so the ARB
        // families require the ARB multisample extension exactly.
        .arb_ext_colorspace_srgb, .arb_srgb => hasWglExtension(extensions, "WGL_ARB_multisample"),
        .classic => false,
    };
}

pub const WglPixelFormatSelection = struct {
    pixel_format: i32,
    descriptor: PIXELFORMATDESCRIPTOR,
    provenance: WglPixelFormatProvenance,
};

const WglBootstrapPlacement = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

fn wglBootstrapPlacement(anchor: RECT) WglBootstrapPlacement {
    return .{
        .x = anchor.left,
        .y = anchor.top,
        .width = 1,
        .height = 1,
    };
}

const WglPixelFormatSelector = struct {
    hinstance: HINSTANCE,
    hwnd: HWND,
    hdc: HDC,
    hglrc: HGLRC,
    functions: WglPixelFormatFunctions,
    multisample_query_supported: bool,

    fn init(hinstance: HINSTANCE, anchor: RECT) !WglPixelFormatSelector {
        const placement = wglBootstrapPlacement(anchor);
        var window_class: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = c.CS_OWNDC,
            .lpfnWndProc = &wglBootstrapWindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = wgl_bootstrap_class_name,
            .hIconSm = null,
        };
        if (RegisterClassExW(&window_class) == 0) {
            return error.WglBootstrapRegisterClassFailed;
        }
        errdefer _ = UnregisterClassW(wgl_bootstrap_class_name, hinstance);

        const window_name = std.unicode.utf8ToUtf16LeStringLiteral("");
        const hwnd = CreateWindowExW(
            0,
            wgl_bootstrap_class_name,
            window_name,
            c.WS_POPUP,
            placement.x,
            placement.y,
            placement.width,
            placement.height,
            null,
            null,
            hinstance,
            null,
        ) orelse return error.WglBootstrapWindowFailed;
        errdefer _ = DestroyWindow(hwnd);

        const hdc = GetDC(hwnd) orelse return error.WglBootstrapGetDCFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        const pfd = defaultPixelFormatDescriptor();
        const pixel_format = ChoosePixelFormat(hdc, &pfd);
        if (pixel_format == 0) return error.WglBootstrapChoosePixelFormatFailed;
        if (SetPixelFormat(hdc, pixel_format, &pfd) == 0) {
            return error.WglBootstrapSetPixelFormatFailed;
        }

        const hglrc = wglCreateContext(hdc) orelse return error.WglBootstrapCreateContextFailed;
        errdefer {
            if (wglGetCurrentContext() == hglrc) _ = wglMakeCurrent(null, null);
            _ = wglDeleteContext(hglrc);
        }

        const previous_hdc = wglGetCurrentDC();
        const previous_hglrc = wglGetCurrentContext();
        if (wglMakeCurrent(hdc, hglrc) == 0) return error.WglBootstrapMakeCurrentFailed;

        const loaded = load: {
            const extensions = extensions: {
                const arb_raw = wglGetProcAddress("wglGetExtensionsStringARB");
                if (validWglProcAddress(arb_raw)) {
                    const get_arb: WglGetExtensionsStringArbFn = @ptrCast(@alignCast(arb_raw.?));
                    if (get_arb(hdc)) |value| {
                        const list = std.mem.span(value);
                        if (hasWglExtension(list, "WGL_ARB_extensions_string")) {
                            break :extensions list;
                        }
                    }
                }
                const ext_raw = wglGetProcAddress("wglGetExtensionsStringEXT");
                if (validWglProcAddress(ext_raw)) {
                    const get_ext: WglGetExtensionsStringExtFn = @ptrCast(@alignCast(ext_raw.?));
                    if (get_ext()) |value| {
                        const list = std.mem.span(value);
                        if (hasWglExtension(list, "WGL_EXT_extensions_string")) {
                            break :extensions list;
                        }
                    }
                }
                break :load error.WglExtensionsUnavailable;
            };
            // Never mix one family's sRGB attribute with the other family's
            // entry points; `wgl_srgb_api_family_order` documents each valid
            // pairing and the order they are tried in.
            const functions: WglPixelFormatFunctions = functions: {
                for (wgl_srgb_api_family_order) |family| {
                    if (!wglSrgbApiFamilyAdvertised(family, extensions)) continue;
                    if (loadWglPixelFormatFunctions(family)) |resolved| {
                        break :functions resolved;
                    }
                }
                break :load error.WglSrgbPixelFormatUnavailable;
            };
            break :load .{
                .functions = functions,
                .multisample = wglMultisampleQuerySupported(
                    functions.source(),
                    extensions,
                ),
            };
        };

        if (wglMakeCurrent(previous_hdc, previous_hglrc) == 0) {
            // Never let a failed restoration leave the dummy context current
            // while its errdefer cleanup tries to delete it.
            return if (wglMakeCurrent(null, null) != 0)
                error.WglBootstrapRestoreCurrentFailed
            else
                error.WglBootstrapClearCurrentFailed;
        }
        const functions = try loaded;

        return .{
            .hinstance = hinstance,
            .hwnd = hwnd,
            .hdc = hdc,
            .hglrc = hglrc,
            .functions = functions.functions,
            .multisample_query_supported = functions.multisample,
        };
    }

    fn deinit(self: *WglPixelFormatSelector) void {
        if (wglGetCurrentContext() == self.hglrc) _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.hglrc);
        _ = ReleaseDC(self.hwnd, self.hdc);
        _ = DestroyWindow(self.hwnd);
        _ = UnregisterClassW(wgl_bootstrap_class_name, self.hinstance);
        self.* = undefined;
    }

    fn choose(
        self: *const WglPixelFormatSelector,
        hdc: HDC,
    ) !?WglPixelFormatSelection {
        const previous_hdc = wglGetCurrentDC();
        const previous_hglrc = wglGetCurrentContext();
        if (wglMakeCurrent(self.hdc, self.hglrc) == 0) {
            return error.WglBootstrapMakeCurrentFailed;
        }

        const result = self.chooseCurrent(hdc);
        if (wglMakeCurrent(previous_hdc, previous_hglrc) == 0) {
            return if (wglMakeCurrent(null, null) != 0)
                error.WglBootstrapRestoreCurrentFailed
            else
                error.WglBootstrapClearCurrentFailed;
        }
        return result;
    }

    fn chooseCurrent(
        self: *const WglPixelFormatSelector,
        hdc: HDC,
    ) !?WglPixelFormatSelection {
        const srgb_attribute = self.functions.srgbAttribute();
        var format_count_attributes = [_]i32{WGL_NUMBER_PIXEL_FORMATS_EXT};
        var format_count_values: [1]i32 = undefined;
        if (self.functions.getAttributes(
            hdc,
            0,
            &format_count_attributes,
            &format_count_values,
        ) == 0) return error.WglPixelFormatCountQueryFailed;
        const total_format_count = format_count_values[0];
        const max_format_count = validatedWglPixelFormatCount(total_format_count) catch |err| {
            log.warn(
                "WGL extended pixel-format inventory exceeds deterministic capacity total={} capacity={}",
                .{ total_format_count, max_wgl_pixel_formats },
            );
            return err;
        };

        var pixel_formats: [max_wgl_pixel_formats]i32 = undefined;
        var pixel_format_count: UINT = 0;
        if (self.functions.choose(
            hdc,
            &wgl_pixel_format_inventory_attributes,
            max_format_count,
            &pixel_formats,
            &pixel_format_count,
        ) == 0) return error.WglChoosePixelFormatFailed;
        if (pixel_format_count > max_format_count) return error.WglInvalidPixelFormatCandidateCount;
        const count: usize = @intCast(pixel_format_count);
        if (count == 0) {
            return null;
        }
        log.debug(
            "WGL extended pixel-format inventory total={} matching={} truncated=false",
            .{ total_format_count, count },
        );

        var query_attributes_base = [_]i32{
            WGL_DRAW_TO_WINDOW_EXT,
            WGL_SUPPORT_OPENGL_EXT,
            WGL_DOUBLE_BUFFER_EXT,
            WGL_STEREO_EXT,
            WGL_PIXEL_TYPE_EXT,
            WGL_COLOR_BITS_EXT,
            WGL_ALPHA_BITS_EXT,
            WGL_ACCUM_BITS_EXT,
            WGL_AUX_BUFFERS_EXT,
            WGL_DEPTH_BITS_EXT,
            WGL_STENCIL_BITS_EXT,
            WGL_ACCELERATION_EXT,
            srgb_attribute.name,
        };
        var query_attributes_multisample = [_]i32{
            WGL_DRAW_TO_WINDOW_EXT,
            WGL_SUPPORT_OPENGL_EXT,
            WGL_DOUBLE_BUFFER_EXT,
            WGL_STEREO_EXT,
            WGL_PIXEL_TYPE_EXT,
            WGL_COLOR_BITS_EXT,
            WGL_ALPHA_BITS_EXT,
            WGL_ACCUM_BITS_EXT,
            WGL_AUX_BUFFERS_EXT,
            WGL_DEPTH_BITS_EXT,
            WGL_STENCIL_BITS_EXT,
            WGL_ACCELERATION_EXT,
            srgb_attribute.name,
            WGL_SAMPLE_BUFFERS_ARB,
            WGL_SAMPLES_ARB,
        };
        const query_attributes: []i32 = if (self.multisample_query_supported)
            &query_attributes_multisample
        else
            &query_attributes_base;
        var candidates: [pixel_formats.len]WglPixelFormatCandidate = undefined;
        var candidate_count: usize = 0;
        for (pixel_formats[0..count]) |pixel_format| {
            var values: [query_attributes_multisample.len]i32 = undefined;
            if (self.functions.getAttributes(
                hdc,
                pixel_format,
                query_attributes,
                &values,
            ) == 0) return error.WglPixelFormatCandidateQueryFailed;
            if (values[0] < 0 or values[0] > 1 or
                values[1] < 0 or values[1] > 1 or
                values[2] < 0 or values[2] > 1 or
                values[3] < 0 or values[3] > 1 or
                values[5] < 0 or
                values[5] > std.math.maxInt(u8) or
                values[6] < 0 or
                values[6] > std.math.maxInt(u8) or
                values[7] < 0 or
                values[7] > std.math.maxInt(u8) or
                values[8] < 0 or
                values[8] > std.math.maxInt(u8) or
                values[9] < 0 or
                values[9] > std.math.maxInt(u8) or
                values[10] < 0 or
                values[10] > std.math.maxInt(u8) or
                (self.multisample_query_supported and
                    (values[13] < 0 or
                        values[13] > std.math.maxInt(u8) or
                        values[14] < 0 or
                        values[14] > std.math.maxInt(u8))))
            {
                return error.WglPixelFormatCandidateContractViolation;
            }

            const candidate: WglPixelFormatCandidate = .{
                .index = pixel_format,
                .color_bits = @intCast(values[5]),
                .alpha_bits = @intCast(values[6]),
                .depth_bits = @intCast(values[9]),
                .stencil_bits = @intCast(values[10]),
                .fully_accelerated = values[11] == WGL_FULL_ACCELERATION_EXT,
                .srgb_capable = values[12] == srgb_attribute.value,
                .stereo = values[3] != 0,
                .accum_bits = @intCast(values[7]),
                .aux_buffers = @intCast(values[8]),
                .multisample_query_supported = self.multisample_query_supported,
                .sample_buffers = if (self.multisample_query_supported) @intCast(values[13]) else null,
                .samples = if (self.multisample_query_supported) @intCast(values[14]) else null,
            };
            const base_contract = values[0] == 1 and
                values[1] == 1 and
                values[2] == 1 and
                values[4] == WGL_TYPE_RGBA_EXT;
            if (classifyWglPixelFormatCandidate(candidate, base_contract) != null) {
                continue;
            }

            var descriptor: PIXELFORMATDESCRIPTOR = undefined;
            if (DescribePixelFormat(
                hdc,
                pixel_format,
                @sizeOf(PIXELFORMATDESCRIPTOR),
                &descriptor,
            ) == 0) return error.WglDescribePixelFormatFailed;
            _ = validateSelectedPixelFormat(pixel_format, descriptor) catch {
                continue;
            };
            if ((descriptor.dwFlags & PFD_STEREO != 0) != (values[3] != 0) or
                descriptor.cColorBits != @as(u8, @intCast(values[5])) or
                descriptor.cAlphaBits != @as(u8, @intCast(values[6])) or
                descriptor.cAccumBits != @as(u8, @intCast(values[7])) or
                descriptor.cAuxBuffers != @as(u8, @intCast(values[8])) or
                descriptor.cDepthBits != @as(u8, @intCast(values[9])) or
                descriptor.cStencilBits != @as(u8, @intCast(values[10])))
            {
                continue;
            }

            candidates[candidate_count] = candidate;
            candidate_count += 1;
        }

        const selected_candidate = rankWglPixelFormatCandidates(candidates[0..candidate_count]) orelse {
            return null;
        };
        var selected_pfd: PIXELFORMATDESCRIPTOR = undefined;
        if (DescribePixelFormat(
            hdc,
            selected_candidate.index,
            @sizeOf(PIXELFORMATDESCRIPTOR),
            &selected_pfd,
        ) == 0) return error.WglDescribePixelFormatFailed;
        var provenance = try validateSelectedPixelFormat(selected_candidate.index, selected_pfd);
        provenance.selection_source = self.functions.source();
        provenance.srgb_capable = true;
        provenance.multisample_query_supported = selected_candidate.multisample_query_supported;
        provenance.sample_buffers = selected_candidate.sample_buffers;
        provenance.samples = selected_candidate.samples;
        provenance.total_format_count = @intCast(total_format_count);
        provenance.candidate_count = @intCast(count);
        return .{
            .pixel_format = selected_candidate.index,
            .descriptor = selected_pfd,
            .provenance = provenance,
        };
    }
};

const wgl_bootstrap_class_name = std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.wgl_bootstrap");

fn wglBootstrapWindowProc(
    hwnd: HWND,
    msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
) callconv(.winapi) LRESULT {
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

pub fn defaultPixelFormatDescriptor() PIXELFORMATDESCRIPTOR {
    return .{
        .nSize = @sizeOf(PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        // cDepthBits=0 alone still makes ChoosePixelFormat consider only
        // depth-buffered formats. This is request-only; selected actual
        // depth remains whatever DescribePixelFormat reports.
        .dwFlags = c.PFD_DRAW_TO_WINDOW |
            c.PFD_SUPPORT_OPENGL |
            c.PFD_DOUBLEBUFFER |
            PFD_DEPTH_DONTCARE,
        .iPixelType = c.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cRedBits = 0,
        .cRedShift = 0,
        .cGreenBits = 0,
        .cGreenShift = 0,
        .cBlueBits = 0,
        .cBlueShift = 0,
        .cAlphaBits = 8,
        .cAlphaShift = 0,
        .cAccumBits = 0,
        .cAccumRedBits = 0,
        .cAccumGreenBits = 0,
        .cAccumBlueBits = 0,
        .cAccumAlphaBits = 0,
        .cDepthBits = 0,
        .cStencilBits = 0,
        .cAuxBuffers = 0,
        .iLayerType = c.PFD_MAIN_PLANE,
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };
}

fn compatibilityPixelFormatDescriptor() PIXELFORMATDESCRIPTOR {
    var result = defaultPixelFormatDescriptor();
    result.dwFlags &= ~@as(DWORD, PFD_DEPTH_DONTCARE);
    return result;
}

fn chooseClassicCompatibilityPixelFormat(hdc: HDC) !WglPixelFormatSelection {
    const requested = compatibilityPixelFormatDescriptor();
    const pixel_format = ChoosePixelFormat(hdc, &requested);
    if (pixel_format == 0) {
        const err = windows.kernel32.GetLastError();
        gl_startup.recordOpenGLStartupWin32Failure(.choose_pixel_format, err);
        return windows.unexpectedError(err);
    }
    var descriptor: PIXELFORMATDESCRIPTOR = undefined;
    if (DescribePixelFormat(
        hdc,
        pixel_format,
        @sizeOf(PIXELFORMATDESCRIPTOR),
        &descriptor,
    ) == 0) {
        const err = windows.kernel32.GetLastError();
        gl_startup.recordOpenGLStartupWin32Failure(.describe_pixel_format, err);
        return windows.unexpectedError(err);
    }
    const provenance = validateSelectedPixelFormat(pixel_format, descriptor) catch |err| {
        const reason = pixelFormatBaseCompatibilityFailure(pixel_format, descriptor) orelse unreachable;
        log.warn(
            "classic ChoosePixelFormat recovery rejected index={} reason={s} flags=0x{x} size={} version={} pixel_type={} layer={} color_bits={} alpha_bits={} accum_bits={} aux_buffers={} depth_bits={} stencil_bits={}",
            .{
                pixel_format,
                @tagName(reason),
                descriptor.dwFlags,
                descriptor.nSize,
                descriptor.nVersion,
                descriptor.iPixelType,
                descriptor.iLayerType,
                descriptor.cColorBits,
                descriptor.cAlphaBits,
                descriptor.cAccumBits,
                descriptor.cAuxBuffers,
                descriptor.cDepthBits,
                descriptor.cStencilBits,
            },
        );
        gl_startup.recordOpenGLStartupError(.describe_pixel_format, err);
        return err;
    };
    return .{
        .pixel_format = pixel_format,
        .descriptor = descriptor,
        .provenance = provenance,
    };
}

fn enumerateClassicPixelFormat(hdc: HDC) !WglPixelFormatSelection {
    var descriptor: PIXELFORMATDESCRIPTOR = undefined;
    const format_count = DescribePixelFormat(
        hdc,
        1,
        @sizeOf(PIXELFORMATDESCRIPTOR),
        &descriptor,
    );
    if (format_count <= 0 or format_count > 4096) {
        gl_startup.recordOpenGLStartupError(.describe_pixel_format, error.InvalidPixelFormatInventory);
        return error.InvalidPixelFormatInventory;
    }

    var selected: ?ClassicPixelFormatCandidate = null;
    var pixel_format: i32 = 1;
    while (pixel_format <= format_count) : (pixel_format += 1) {
        if (DescribePixelFormat(
            hdc,
            pixel_format,
            @sizeOf(PIXELFORMATDESCRIPTOR),
            &descriptor,
        ) == 0) {
            const err = windows.kernel32.GetLastError();
            gl_startup.recordOpenGLStartupWin32Failure(.describe_pixel_format, err);
            return windows.unexpectedError(err);
        }
        const provenance = validateSelectedPixelFormat(pixel_format, descriptor) catch continue;
        const candidate: ClassicPixelFormatCandidate = .{
            .index = pixel_format,
            .descriptor = descriptor,
            .provenance = provenance,
            .acceleration = classicPixelFormatAcceleration(descriptor.dwFlags),
        };
        if (selected == null or betterClassicPixelFormatCandidate(candidate, selected.?)) {
            selected = candidate;
        }
    }

    const candidate = selected orelse {
        // The real DC remains untouched. Retain the prior known-compatible
        // classic request only as a last recovery for drivers whose full
        // DescribePixelFormat inventory exposes no base-compatible format.
        log.warn(
            "classic WGL inventory exposed no base-compatible descriptor; trying the validated depth-compatible recovery",
            .{},
        );
        return chooseClassicCompatibilityPixelFormat(hdc);
    };
    log.debug(
        "classic WGL inventory selected deterministic format index={} total={} acceleration={s} accum_bits={} aux_buffers={} depth_bits={} stencil_bits={}",
        .{
            candidate.index,
            format_count,
            @tagName(candidate.acceleration),
            candidate.provenance.accum_bits,
            candidate.provenance.aux_buffers,
            candidate.provenance.depth_bits,
            candidate.provenance.stencil_bits,
        },
    );
    return .{
        .pixel_format = candidate.index,
        .descriptor = candidate.descriptor,
        .provenance = candidate.provenance,
    };
}

pub fn chooseRealPixelFormat(
    hinstance: HINSTANCE,
    hwnd: HWND,
    hdc: HDC,
) !WglPixelFormatSelection {
    var child_rect: RECT = undefined;
    if (GetWindowRect(hwnd, &child_rect) == 0) {
        log.warn(
            "unable to anchor a display-local WGL bootstrap; retaining classic selection err={}",
            .{windows.kernel32.GetLastError()},
        );
        return enumerateClassicPixelFormat(hdc);
    }

    // WGL extension strings and proc addresses are current-context and
    // display scoped. Bootstrap beside this exact child, select while the
    // dummy context is current, then restore and destroy the dummy before
    // SetPixelFormat ever touches the real child DC.
    var selector = WglPixelFormatSelector.init(hinstance, child_rect) catch |err| {
        if (isWglPixelFormatHardError(err)) return err;
        log.warn(
            "display-local WGL sRGB bootstrap unavailable before touching the real DC; retaining classic selection err={}",
            .{err},
        );
        return enumerateClassicPixelFormat(hdc);
    };
    defer selector.deinit();

    if (selector.choose(hdc) catch |err| fallback: {
        if (isWglPixelFormatHardError(err)) return err;
        // choose() only returns selection/query errors after restoring the
        // caller's previous current pair. The real DC remains untouched.
        log.warn(
            "WGL sRGB pixel-format selection unavailable after safe restoration; retaining classic selection err={}",
            .{err},
        );
        break :fallback null;
    }) |selection| {
        return selection;
    }
    log.debug("WGL sRGB selector exhausted verified candidates; retaining classic selection", .{});
    return enumerateClassicPixelFormat(hdc);
}

test "win32 pixel format descriptor omits unused depth and stencil" {
    const pfd = defaultPixelFormatDescriptor();
    try std.testing.expectEqual(
        @as(
            DWORD,
            c.PFD_DRAW_TO_WINDOW |
                c.PFD_SUPPORT_OPENGL |
                c.PFD_DOUBLEBUFFER |
                PFD_DEPTH_DONTCARE,
        ),
        pfd.dwFlags,
    );
    try std.testing.expectEqual(@as(BYTE, 32), pfd.cColorBits);
    try std.testing.expectEqual(@as(BYTE, 8), pfd.cAlphaBits);
    try std.testing.expectEqual(@as(BYTE, 0), pfd.cDepthBits);
    try std.testing.expectEqual(@as(BYTE, 0), pfd.cStencilBits);
}

test "win32 classic compatibility request preserves the prior depth constraint" {
    const pfd = compatibilityPixelFormatDescriptor();
    try std.testing.expectEqual(
        @as(DWORD, c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER),
        pfd.dwFlags,
    );
    try std.testing.expectEqual(@as(BYTE, 32), pfd.cColorBits);
    try std.testing.expectEqual(@as(BYTE, 8), pfd.cAlphaBits);
    try std.testing.expectEqual(@as(BYTE, 0), pfd.cDepthBits);
    try std.testing.expectEqual(@as(BYTE, 0), pfd.cStencilBits);
}

test "win32 classic pixel format ranking preserves acceleration before attachments" {
    var generic_pfd = defaultPixelFormatDescriptor();
    generic_pfd.dwFlags |= PFD_GENERIC_FORMAT;
    const base = try validateSelectedPixelFormat(10, generic_pfd);
    var accelerated_pfd = defaultPixelFormatDescriptor();
    accelerated_pfd.cDepthBits = 24;
    const accelerated = try validateSelectedPixelFormat(11, accelerated_pfd);
    const candidates = [_]ClassicPixelFormatCandidate{
        .{
            .index = 10,
            .descriptor = generic_pfd,
            .provenance = base,
            .acceleration = classicPixelFormatAcceleration(generic_pfd.dwFlags),
        },
        .{
            .index = 11,
            .descriptor = accelerated_pfd,
            .provenance = accelerated,
            .acceleration = classicPixelFormatAcceleration(accelerated_pfd.dwFlags),
        },
    };
    try std.testing.expectEqual(
        @as(i32, 11),
        rankClassicPixelFormatCandidates(&candidates).?.index,
    );
}

test "win32 classic pixel format ranking minimizes attachments within acceleration class" {
    var attached_pfd = defaultPixelFormatDescriptor();
    attached_pfd.cAccumBits = 64;
    attached_pfd.cAuxBuffers = 1;
    attached_pfd.cDepthBits = 24;
    attached_pfd.cStencilBits = 8;
    const candidates = [_]ClassicPixelFormatCandidate{
        .{
            .index = 12,
            .descriptor = attached_pfd,
            .provenance = try validateSelectedPixelFormat(12, attached_pfd),
            .acceleration = .icd,
        },
        .{
            .index = 14,
            .descriptor = defaultPixelFormatDescriptor(),
            .provenance = try validateSelectedPixelFormat(14, defaultPixelFormatDescriptor()),
            .acceleration = .icd,
        },
    };
    try std.testing.expectEqual(
        @as(i32, 14),
        rankClassicPixelFormatCandidates(&candidates).?.index,
    );
}

test "win32 classic acceleration classification distinguishes ICD MCD and generic" {
    try std.testing.expectEqual(ClassicPixelFormatAcceleration.icd, classicPixelFormatAcceleration(0));
    try std.testing.expectEqual(
        ClassicPixelFormatAcceleration.mcd,
        classicPixelFormatAcceleration(PFD_GENERIC_FORMAT | PFD_GENERIC_ACCELERATED),
    );
    try std.testing.expectEqual(
        ClassicPixelFormatAcceleration.generic,
        classicPixelFormatAcceleration(PFD_GENERIC_FORMAT),
    );
}

test "win32 sRGB pixel format ranking prefers depthless stencil-less" {
    const candidates = [_]WglPixelFormatCandidate{
        .{
            .index = 12,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 24,
            .stencil_bits = 8,
            .srgb_capable = true,
            .fully_accelerated = true,
        },
        .{
            .index = 14,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 0,
            .stencil_bits = 0,
            .srgb_capable = true,
            .fully_accelerated = true,
        },
        .{
            .index = 16,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 0,
            .stencil_bits = 0,
            .srgb_capable = false,
            .fully_accelerated = true,
        },
    };

    const selected = rankWglPixelFormatCandidates(&candidates).?;
    try std.testing.expectEqual(@as(i32, 14), selected.index);
}

test "win32 sRGB pixel format ranking honestly falls back to attached depth" {
    const candidates = [_]WglPixelFormatCandidate{
        .{
            .index = 12,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 24,
            .stencil_bits = 8,
            .srgb_capable = true,
            .fully_accelerated = true,
        },
        .{
            .index = 10,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 24,
            .stencil_bits = 0,
            .srgb_capable = true,
            .fully_accelerated = true,
        },
    };

    const selected = rankWglPixelFormatCandidates(&candidates).?;
    try std.testing.expectEqual(@as(i32, 10), selected.index);
    try std.testing.expectEqual(@as(u8, 24), selected.depth_bits);
    try std.testing.expectEqual(@as(u8, 0), selected.stencil_bits);
}

test "win32 pixel format inventory accepts observed full count without truncation" {
    try std.testing.expectEqual(@as(UINT, 670), try validatedWglPixelFormatCount(670));
    try std.testing.expectEqual(
        @as(UINT, max_wgl_pixel_formats),
        try validatedWglPixelFormatCount(max_wgl_pixel_formats),
    );
    try std.testing.expectError(
        error.WglPixelFormatCandidateCapacityExceeded,
        validatedWglPixelFormatCount(0),
    );
    try std.testing.expectError(
        error.WglPixelFormatCandidateCapacityExceeded,
        validatedWglPixelFormatCount(max_wgl_pixel_formats + 1),
    );
}

test "win32 pixel format ranking prefers zero attachments but permits honest fallback" {
    const candidates = [_]WglPixelFormatCandidate{
        .{
            .index = 8,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 0,
            .stencil_bits = 0,
            .srgb_capable = true,
            .fully_accelerated = true,
            .accum_bits = 64,
        },
        .{
            .index = 9,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 24,
            .stencil_bits = 0,
            .srgb_capable = true,
            .fully_accelerated = true,
        },
    };
    try std.testing.expectEqual(
        @as(i32, 9),
        rankWglPixelFormatCandidates(&candidates).?.index,
    );
    const attached = rankWglPixelFormatCandidates(candidates[0..1]).?;
    try std.testing.expectEqual(@as(i32, 8), attached.index);
    try std.testing.expectEqual(@as(u8, 64), attached.accum_bits);
}

test "win32 pixel format SetPixelFormat transition requires zero to selected" {
    try validatePixelFormatSetTransition(0, 7, 7);
    try std.testing.expectError(
        error.PixelFormatAlreadySet,
        validatePixelFormatSetTransition(7, 7, 7),
    );
    try std.testing.expectError(
        error.PixelFormatSetVerificationFailed,
        validatePixelFormatSetTransition(0, 7, 0),
    );
    try std.testing.expectError(
        error.PixelFormatSetVerificationFailed,
        validatePixelFormatSetTransition(0, 7, 9),
    );
}

test "win32 WGL bootstrap keeps exact sRGB API families and valid procs" {
    const extensions = "WGL_ARB_extensions_string WGL_EXT_extensions_string WGL_EXT_pixel_format WGL_ARB_framebuffer_sRGB WGL_ARB_pixel_format WGL_EXT_colorspace";
    try std.testing.expect(hasWglExtension(extensions, "WGL_ARB_extensions_string"));
    try std.testing.expect(hasWglExtension(extensions, "WGL_EXT_extensions_string"));
    try std.testing.expect(hasWglExtension(extensions, "WGL_EXT_pixel_format"));
    try std.testing.expect(hasWglExtension(extensions, "WGL_ARB_framebuffer_sRGB"));
    try std.testing.expect(hasWglExtension(extensions, "WGL_ARB_pixel_format"));
    try std.testing.expect(hasWglExtension(extensions, "WGL_EXT_colorspace"));
    try std.testing.expect(!hasWglExtension(extensions, "WGL_ARB_framebuffer"));
    try std.testing.expectEqual(@as(i32, 0x309D), WGL_COLORSPACE_EXT);
    try std.testing.expectEqual(@as(i32, 0x3089), WGL_COLORSPACE_SRGB_EXT);
    try std.testing.expect(!validWglProcAddress(null));
    try std.testing.expect(!validWglProcAddress(@ptrFromInt(1)));
    try std.testing.expect(validWglProcAddress(@ptrFromInt(0x1000)));
}

test "win32 WGL sRGB family order covers every pairing exactly once" {
    const fields = @typeInfo(WglSrgbApiFamily).@"enum".fields;
    try std.testing.expectEqual(fields.len, wgl_srgb_api_family_order.len);
    inline for (fields) |field| {
        const family: WglSrgbApiFamily = @enumFromInt(field.value);
        var seen: usize = 0;
        for (wgl_srgb_api_family_order) |candidate| {
            if (candidate == family) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
    }
}

test "win32 WGL sRGB selection reaches ARB-only drivers without WGL_EXT_pixel_format" {
    // The regression this guards: a driver advertising the standard
    // WGL_ARB_pixel_format + WGL_ARB_framebuffer_sRGB pair but no
    // WGL_EXT_pixel_format and no WGL_EXT_colorspace must still reach the
    // verified-sRGB direct-framebuffer path instead of silently falling
    // back to the classic offscreen selection.
    try std.testing.expectEqual(
        WglSrgbApiFamily.arb_pixel_format_framebuffer_srgb,
        firstAdvertisedWglSrgbApiFamily(
            "WGL_ARB_extensions_string WGL_ARB_pixel_format WGL_ARB_framebuffer_sRGB WGL_ARB_multisample",
        ).?,
    );

    // WGL_EXT_framebuffer_sRGB declares the same 0x20A9 attribute, so an
    // EXT-only spelling is equally usable through either entry-point family.
    try std.testing.expectEqual(
        WglSrgbApiFamily.arb_pixel_format_framebuffer_srgb,
        firstAdvertisedWglSrgbApiFamily(
            "WGL_ARB_extensions_string WGL_ARB_pixel_format WGL_EXT_framebuffer_sRGB",
        ).?,
    );
    try std.testing.expectEqual(
        WglSrgbApiFamily.ext_pixel_format_framebuffer_srgb,
        firstAdvertisedWglSrgbApiFamily(
            "WGL_EXT_extensions_string WGL_EXT_pixel_format WGL_EXT_framebuffer_sRGB",
        ).?,
    );
}

test "win32 WGL sRGB selection prefers the spec-exact pairings" {
    // Both framebuffer_sRGB specs are written against WGL_EXT_pixel_format,
    // so that family wins whenever the driver advertises it.
    try std.testing.expectEqual(
        WglSrgbApiFamily.ext_pixel_format_framebuffer_srgb,
        firstAdvertisedWglSrgbApiFamily(
            "WGL_EXT_pixel_format WGL_ARB_pixel_format WGL_ARB_framebuffer_sRGB WGL_EXT_colorspace",
        ).?,
    );

    // WGL_EXT_colorspace is written against WGL_ARB_pixel_format and keeps
    // priority over the de-facto ARB framebuffer_sRGB pairing, so drivers
    // that already selected through it do not change path.
    try std.testing.expectEqual(
        WglSrgbApiFamily.arb_pixel_format_colorspace,
        firstAdvertisedWglSrgbApiFamily(
            "WGL_ARB_pixel_format WGL_EXT_colorspace WGL_ARB_framebuffer_sRGB",
        ).?,
    );
}

test "win32 WGL sRGB selection refuses unpaired or absent extensions" {
    // Pixel-format API with no sRGB attribute at all.
    try std.testing.expectEqual(
        @as(?WglSrgbApiFamily, null),
        firstAdvertisedWglSrgbApiFamily("WGL_ARB_pixel_format WGL_ARB_multisample"),
    );
    try std.testing.expectEqual(
        @as(?WglSrgbApiFamily, null),
        firstAdvertisedWglSrgbApiFamily("WGL_EXT_pixel_format WGL_EXT_swap_control"),
    );
    // sRGB attributes with no pixel-format API to query them through.
    try std.testing.expectEqual(
        @as(?WglSrgbApiFamily, null),
        firstAdvertisedWglSrgbApiFamily("WGL_ARB_framebuffer_sRGB WGL_EXT_colorspace"),
    );
    // WGL_EXT_colorspace must never be paired with the EXT entry points.
    try std.testing.expectEqual(
        @as(?WglSrgbApiFamily, null),
        firstAdvertisedWglSrgbApiFamily("WGL_EXT_pixel_format WGL_EXT_colorspace"),
    );
    try std.testing.expectEqual(
        @as(?WglSrgbApiFamily, null),
        firstAdvertisedWglSrgbApiFamily(""),
    );
}

test "win32 WGL sRGB attribute stays bound to its own API family" {
    const stubs = struct {
        fn chooseArb(
            _: HDC,
            _: ?[*]const i32,
            _: ?[*]const f32,
            _: UINT,
            _: [*]i32,
            _: *UINT,
        ) callconv(.winapi) BOOL {
            return 0;
        }
        fn getArb(
            _: HDC,
            _: i32,
            _: i32,
            _: UINT,
            _: [*]const i32,
            _: [*]i32,
        ) callconv(.winapi) BOOL {
            return 0;
        }
        fn chooseExt(
            _: HDC,
            _: ?[*]const i32,
            _: ?[*]const f32,
            _: UINT,
            _: [*]i32,
            _: *UINT,
        ) callconv(.winapi) BOOL {
            return 0;
        }
        fn getExt(
            _: HDC,
            _: i32,
            _: i32,
            _: UINT,
            _: [*]i32,
            _: [*]i32,
        ) callconv(.winapi) BOOL {
            return 0;
        }
    };
    const arb: WglPixelFormatArbFunctions = .{
        .choose = &stubs.chooseArb,
        .get_attributes = &stubs.getArb,
    };
    const ext: WglPixelFormatExtFunctions = .{
        .choose = &stubs.chooseExt,
        .get_attributes = &stubs.getExt,
    };

    const ext_srgb: WglPixelFormatFunctions = .{ .ext_framebuffer_srgb = ext };
    try std.testing.expectEqual(WglPixelFormatSelectionSource.ext_srgb, ext_srgb.source());
    try std.testing.expectEqual(
        @as(i32, WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB),
        ext_srgb.srgbAttribute().name,
    );
    try std.testing.expectEqual(@as(i32, 1), ext_srgb.srgbAttribute().value);

    const arb_srgb: WglPixelFormatFunctions = .{ .arb_framebuffer_srgb = arb };
    try std.testing.expectEqual(WglPixelFormatSelectionSource.arb_srgb, arb_srgb.source());
    try std.testing.expectEqual(
        @as(i32, WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB),
        arb_srgb.srgbAttribute().name,
    );
    try std.testing.expectEqual(@as(i32, 1), arb_srgb.srgbAttribute().value);

    const colorspace: WglPixelFormatFunctions = .{ .arb_ext_colorspace_srgb = arb };
    try std.testing.expectEqual(
        WglPixelFormatSelectionSource.arb_ext_colorspace_srgb,
        colorspace.source(),
    );
    try std.testing.expectEqual(
        @as(i32, WGL_COLORSPACE_EXT),
        colorspace.srgbAttribute().name,
    );
    try std.testing.expectEqual(
        @as(i32, WGL_COLORSPACE_SRGB_EXT),
        colorspace.srgbAttribute().value,
    );
}

test "win32 WGL multisample query pairs with each family's own extension" {
    // WGL_SAMPLE_BUFFERS_ARB / WGL_SAMPLES_ARB come from WGL_ARB_multisample
    // against the ARB entry points, so the ARB families must not accept the
    // EXT multisample spelling.
    try std.testing.expect(wglMultisampleQuerySupported(.arb_srgb, "WGL_ARB_multisample"));
    try std.testing.expect(!wglMultisampleQuerySupported(.arb_srgb, "WGL_EXT_multisample"));
    try std.testing.expect(
        wglMultisampleQuerySupported(.arb_ext_colorspace_srgb, "WGL_ARB_multisample"),
    );
    try std.testing.expect(
        !wglMultisampleQuerySupported(.arb_ext_colorspace_srgb, "WGL_EXT_multisample"),
    );
    try std.testing.expect(wglMultisampleQuerySupported(.ext_srgb, "WGL_EXT_multisample"));
    try std.testing.expect(wglMultisampleQuerySupported(.ext_srgb, "WGL_ARB_multisample"));
    try std.testing.expect(!wglMultisampleQuerySupported(.classic, "WGL_ARB_multisample"));
}

test "win32 selected pixel format validation preserves actual attachments" {
    var pfd = defaultPixelFormatDescriptor();
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.cAccumBits = 64;
    pfd.cAuxBuffers = 1;
    const selected = try validateSelectedPixelFormat(7, pfd);
    try std.testing.expectEqual(@as(u32, 7), selected.index);
    try std.testing.expectEqual(@as(u8, 32), selected.color_bits);
    try std.testing.expectEqual(@as(u8, 8), selected.alpha_bits);
    try std.testing.expectEqual(@as(u8, 24), selected.depth_bits);
    try std.testing.expectEqual(@as(u8, 8), selected.stencil_bits);
    try std.testing.expect(selected.double_buffer);
    try std.testing.expect(!selected.stereo);
    try std.testing.expectEqual(@as(u8, 64), selected.accum_bits);
    try std.testing.expectEqual(@as(u8, 1), selected.aux_buffers);
    try std.testing.expectEqual(WglPixelFormatSelectionSource.classic, selected.selection_source);
    try std.testing.expect(!selected.srgb_capable);
}

test "win32 selected pixel format validation rejects missing requirements" {
    const valid = defaultPixelFormatDescriptor();
    try std.testing.expectError(
        error.InvalidSelectedPixelFormat,
        validateSelectedPixelFormat(0, valid),
    );

    var not_double_buffered = valid;
    not_double_buffered.dwFlags &= ~@as(u32, c.PFD_DOUBLEBUFFER);
    try std.testing.expectError(
        error.InvalidSelectedPixelFormat,
        validateSelectedPixelFormat(7, not_double_buffered),
    );

    var low_color = valid;
    low_color.cColorBits = 24;
    try std.testing.expectError(
        error.InvalidSelectedPixelFormat,
        validateSelectedPixelFormat(7, low_color),
    );

    var no_alpha = valid;
    no_alpha.cAlphaBits = 0;
    try std.testing.expectError(
        error.InvalidSelectedPixelFormat,
        validateSelectedPixelFormat(7, no_alpha),
    );

    var stereo = valid;
    stereo.dwFlags |= PFD_STEREO;
    try std.testing.expectError(
        error.InvalidSelectedPixelFormat,
        validateSelectedPixelFormat(7, stereo),
    );
}
