//! Runtime policy shared by startup, config reload, and backend tests.
const std = @import("std");
const Config = @import("../config/Config.zig");

pub const Unsupported = enum { custom_shaders, background_image, terminal_images };

pub fn unsupported(custom_shaders: bool, background_image: bool, terminal_images: bool) ?Unsupported {
    if (custom_shaders) return .custom_shaders;
    if (background_image) return .background_image;
    if (terminal_images) return .terminal_images;
    return null;
}

/// Each surface tries these in order until one initializes completely.
/// OpenGL goes first when it was asked for or a feature needs it, and last
/// otherwise. The Direct3D 11 beta fills the rest: hardware, then WARP, or
/// WARP alone when software was asked for. Once OpenGL could not start in
/// this process (`opengl_unavailable`), it is left out.
pub fn startupOrder(
    requested: Config.RendererBackend,
    feature: ?Unsupported,
    opengl_unavailable: bool,
) []const Config.RendererBackend {
    const warp_only = requested == .@"d3d11-warp";
    if (opengl_unavailable) return if (warp_only) &.{.@"d3d11-warp"} else &.{ .d3d11, .@"d3d11-warp" };
    if (requested == .opengl or feature != null) return if (warp_only)
        &.{ .opengl, .@"d3d11-warp" }
    else
        &.{ .opengl, .d3d11, .@"d3d11-warp" };
    return if (warp_only) &.{ .@"d3d11-warp", .opengl } else &.{ .d3d11, .@"d3d11-warp", .opengl };
}

/// Recovery must not re-enter a hardware driver that may have crashed.
/// OpenGL keeps its normal first attempt; its D3D11 fallback is WARP-only.
pub fn startupOrderForMode(
    requested: Config.RendererBackend,
    feature: ?Unsupported,
    opengl_unavailable: bool,
    safe_mode: bool,
) []const Config.RendererBackend {
    if (safe_mode) return if (opengl_unavailable) &.{.@"d3d11-warp"} else &.{ .opengl, .@"d3d11-warp" };
    return startupOrder(requested, feature, opengl_unavailable);
}

/// The banner a surface shows when OpenGL could not start for it and the
/// Direct3D 11 beta drew instead.
pub fn openGLFallbackNotice(warp: bool) []const u8 {
    const before = "OpenGL could not start, so koreterm switched to the Direct3D 11 beta renderer";
    const after = ". Custom shaders and images are not available. To choose a renderer, set renderer in the config.";
    return if (warp) before ++ ", in software (WARP)" ++ after else before ++ after;
}

test "renderer startup order is bounded and tries every renderer once" {
    const Backend = Config.RendererBackend;
    // OpenGL, the default, falls back to the Direct3D 11 beta.
    try std.testing.expectEqualSlices(Backend, &.{ .opengl, .d3d11, .@"d3d11-warp" }, startupOrder(.opengl, null, false));
    try std.testing.expectEqualSlices(Backend, &.{ .d3d11, .@"d3d11-warp", .opengl }, startupOrder(.d3d11, null, false));
    try std.testing.expectEqualSlices(Backend, &.{ .@"d3d11-warp", .opengl }, startupOrder(.@"d3d11-warp", null, false));
    inline for (std.meta.tags(Unsupported)) |feature| {
        // A feature only OpenGL draws puts OpenGL first, whatever was asked.
        try std.testing.expectEqualSlices(Backend, &.{ .opengl, .d3d11, .@"d3d11-warp" }, startupOrder(.opengl, feature, false));
        try std.testing.expectEqualSlices(Backend, &.{ .opengl, .d3d11, .@"d3d11-warp" }, startupOrder(.d3d11, feature, false));
        try std.testing.expectEqualSlices(Backend, &.{ .opengl, .@"d3d11-warp" }, startupOrder(.@"d3d11-warp", feature, false));
    }
}

test "renderer startup skips OpenGL once it could not start in this process" {
    const Backend = Config.RendererBackend;
    for ([_]?Unsupported{ null, .custom_shaders, .terminal_images }) |feature| {
        try std.testing.expectEqualSlices(Backend, &.{ .d3d11, .@"d3d11-warp" }, startupOrder(.opengl, feature, true));
        try std.testing.expectEqualSlices(Backend, &.{ .d3d11, .@"d3d11-warp" }, startupOrder(.d3d11, feature, true));
        try std.testing.expectEqualSlices(Backend, &.{.@"d3d11-warp"}, startupOrder(.@"d3d11-warp", feature, true));
    }
}

test "renderer safe mode excludes hardware D3D11 at startup and after cached GL failure" {
    const Backend = Config.RendererBackend;
    inline for (std.meta.tags(Backend)) |requested| {
        try std.testing.expectEqualSlices(Backend, &.{ .opengl, .@"d3d11-warp" }, startupOrderForMode(requested, null, false, true));
        try std.testing.expectEqualSlices(Backend, &.{.@"d3d11-warp"}, startupOrderForMode(requested, .custom_shaders, true, true));
        try std.testing.expectEqualSlices(Backend, startupOrder(requested, null, false), startupOrderForMode(requested, null, false, false));
    }
}

test "renderer feature selection names the first unsupported feature" {
    try std.testing.expectEqual(Unsupported.custom_shaders, unsupported(true, true, true).?);
    try std.testing.expectEqual(Unsupported.background_image, unsupported(false, true, true).?);
    try std.testing.expectEqual(Unsupported.terminal_images, unsupported(false, false, true).?);
    try std.testing.expectEqual(@as(?Unsupported, null), unsupported(false, false, false));
}

test "OpenGL fallback notice says what happened, what is missing, and how to choose" {
    try std.testing.expectEqualStrings(
        "OpenGL could not start, so koreterm switched to the Direct3D 11 beta renderer. Custom shaders and images are not available. To choose a renderer, set renderer in the config.",
        openGLFallbackNotice(false),
    );
    try std.testing.expectEqualStrings(
        "OpenGL could not start, so koreterm switched to the Direct3D 11 beta renderer, in software (WARP). Custom shaders and images are not available. To choose a renderer, set renderer in the config.",
        openGLFallbackNotice(true),
    );
    // The renderer keeps its notice in a fixed 256-byte buffer.
    try std.testing.expect(openGLFallbackNotice(true).len <= 256);
}
