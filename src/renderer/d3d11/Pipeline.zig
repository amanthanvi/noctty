const Self = @This();
pub const Kind = enum(u32) { bg_color = 0, cell_bg = 1, cell_text = 2, image = 3, bg_image = 4 };
kind: Kind,
pub fn deinit(_: *const Self) void {}
