const Self = @This();
const api = @import("api.zig");
pub const Options = struct { device: *api.Device, width: usize, height: usize, linear: bool };
handle: *api.Target,
width: usize,
height: usize,
pub fn init(opts: Options) !Self {
    if (opts.width > 16384 or opts.height > 16384) return error.Direct3D11Failed;
    const handle = api.noctty_d3d11_target_create(opts.device, @intCast(opts.width), @intCast(opts.height), @intFromBool(opts.linear)) orelse return api.allocationError(opts.device);
    return .{ .handle = handle, .width = opts.width, .height = opts.height };
}
pub fn deinit(self: *Self) void {
    api.noctty_d3d11_target_destroy(self.handle);
    self.* = undefined;
}
