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

pub fn useD3D11(requested: Config.RendererBackend, feature: ?Unsupported) bool {
    return requested != .opengl and feature == null;
}

/// Complete initialization failures advance through this bounded order.
/// The D3D11 API also tries WARP if hardware device creation itself fails.
pub fn startupOrder(requested: Config.RendererBackend, feature: ?Unsupported) []const Config.RendererBackend {
    if (!useD3D11(requested, feature)) return &.{.opengl};
    return switch (requested) {
        .d3d11 => &.{ .d3d11, .@"d3d11-warp", .opengl },
        .@"d3d11-warp" => &.{ .@"d3d11-warp", .opengl },
        .opengl => unreachable,
    };
}

test "renderer startup fallback is bounded and preserves software preference" {
    const Backend = Config.RendererBackend;
    try std.testing.expectEqualSlices(Backend, &.{.opengl}, startupOrder(.opengl, null));
    try std.testing.expectEqualSlices(Backend, &.{ .d3d11, .@"d3d11-warp", .opengl }, startupOrder(.d3d11, null));
    try std.testing.expectEqualSlices(Backend, &.{ .@"d3d11-warp", .opengl }, startupOrder(.@"d3d11-warp", null));
    inline for (std.meta.tags(Unsupported)) |feature| {
        try std.testing.expectEqualSlices(Backend, &.{.opengl}, startupOrder(.d3d11, feature));
    }
}

test "renderer selection keeps OpenGL default and rejects unsupported features" {
    try std.testing.expect(!useD3D11(.opengl, null));
    try std.testing.expect(useD3D11(.d3d11, null));
    try std.testing.expect(useD3D11(.@"d3d11-warp", null));
    inline for (std.meta.tags(Unsupported)) |reason| {
        try std.testing.expect(!useD3D11(.d3d11, reason));
        try std.testing.expect(!useD3D11(.@"d3d11-warp", reason));
    }
    try std.testing.expectEqual(Unsupported.custom_shaders, unsupported(true, true, true).?);
    try std.testing.expectEqual(Unsupported.background_image, unsupported(false, true, true).?);
    try std.testing.expectEqual(Unsupported.terminal_images, unsupported(false, false, true).?);
    try std.testing.expectEqual(@as(?Unsupported, null), unsupported(false, false, false));
}
