const std = @import("std");
const Pipeline = @import("Pipeline.zig");
// Reuse the core's existing preparation contract, including packed cursor flags.
const shared = @import("../opengl/shaders.zig");
pub const Uniforms = shared.Uniforms;
pub const CellText = shared.CellText;
pub const CellBg = shared.CellBg;
pub const BgImage = shared.BgImage;
pub const Image = shared.Image;
comptime {
    std.debug.assert(@sizeOf(Uniforms) == 144);
    std.debug.assert(@offsetOf(Uniforms, "cell_size") == 72);
    std.debug.assert(@offsetOf(Uniforms, "grid_size") == 80);
    std.debug.assert(@offsetOf(Uniforms, "grid_padding") == 96);
    std.debug.assert(@offsetOf(Uniforms, "padding_extend") == 112);
    std.debug.assert(@offsetOf(Uniforms, "cursor_pos") == 120);
    std.debug.assert(@offsetOf(Uniforms, "cursor_color") == 124);
    std.debug.assert(@offsetOf(Uniforms, "bg_color") == 128);
    std.debug.assert(@offsetOf(Uniforms, "bools") == 132);
    std.debug.assert(@sizeOf(CellText) == 32);
    std.debug.assert(@offsetOf(CellText, "bearings") == 16);
    std.debug.assert(@offsetOf(CellText, "grid_pos") == 20);
    std.debug.assert(@offsetOf(CellText, "color") == 24);
    std.debug.assert(@offsetOf(CellText, "atlas") == 28);
    std.debug.assert(@offsetOf(CellText, "bools") == 29);
}
pub const Shaders = struct {
    pipelines: struct {
        bg_color: Pipeline = .{ .kind = .bg_color },
        cell_bg: Pipeline = .{ .kind = .cell_bg },
        cell_text: Pipeline = .{ .kind = .cell_text },
        image: Pipeline = .{ .kind = .image },
        bg_image: Pipeline = .{ .kind = .bg_image },
    } = .{},
    post_pipelines: []const Pipeline = &.{},
    defunct: bool = false,
    pub fn init(_: std.mem.Allocator, custom: []const [:0]const u8) !Shaders {
        if (custom.len > 0) return error.Direct3D11CustomShadersUnsupported;
        return .{};
    }
    pub fn deinit(self: *Shaders, _: std.mem.Allocator) void {
        self.defunct = true;
    }
};

test "embedded D3D11 bytecode source hash is current" {
    // Metadata freshness check, not a rendering oracle. Behavioral parity is
    // measured by the GPU harness independently of these source bytes.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("terminal.hlsl"), &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const header = @embedFile("terminal_bytecode.h");
    const marker = "terminal.hlsl SHA256: ";
    const offset = (std.mem.indexOf(u8, header, marker) orelse return error.MissingShaderSourceHash) + marker.len;
    try std.testing.expectEqualStrings(&hex, header[offset..][0..hex.len]);
}
