const Self = @This();
const api = @import("api.zig");
pub const Error = api.Error || error{ Direct3D11ImagesUnsupported, Direct3D11UnsupportedTextureFormat };
pub const Format = enum(u32) { gray = 0, rgba = 1, bgra = 2 };
pub const Options = struct {
    device: *api.Device,
    format: Format,
    srgb: bool = false,
    unsupported_image: bool = false,
};
handle: *api.Texture,
width: usize,
height: usize,
format: Format,

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Self {
    if (opts.unsupported_image) return error.Direct3D11ImagesUnsupported;
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.Direct3D11Failed;
    const pixel_size: usize = if (opts.format == .gray) 1 else 4;
    if (data) |bytes| if (bytes.len < width * height * pixel_size) return error.Direct3D11Failed;
    const handle = api.noctty_d3d11_texture_create(opts.device, @intCast(width), @intCast(height), @intFromEnum(opts.format), @intFromBool(opts.srgb), if (data) |bytes| bytes.ptr else null) orelse return api.allocationError(opts.device);
    return .{ .handle = handle, .width = width, .height = height, .format = opts.format };
}
pub fn deinit(self: Self) void {
    api.noctty_d3d11_texture_destroy(self.handle);
}
pub fn replaceRegion(self: Self, x: usize, y: usize, width: usize, height: usize, data: []const u8) Error!void {
    if (x > self.width or width > self.width - x or y > self.height or height > self.height - y) return error.Direct3D11Failed;
    const pixel_size: usize = if (self.format == .gray) 1 else 4;
    if (data.len < width * height * pixel_size) return error.Direct3D11Failed;
    try api.check(api.noctty_d3d11_texture_write(self.handle, @intCast(x), @intCast(y), @intCast(width), @intCast(height), data.ptr));
}
