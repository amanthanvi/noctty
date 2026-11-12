const Self = @This();
/// The bridge's pipeline numbers (`koreterm_d3d11_draw` in bridge.c).
pub const Kind = enum(u32) { bg_color = 0, cell_bg = 1, cell_text = 2, image = 3, bg_image = 4, split_dim = 5 };
kind: Kind,
pub fn deinit(_: *const Self) void {}
