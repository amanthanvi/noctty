//! Atlas reads use integer Load coordinates. No sampler state is required.
const Self = @This();
pub const Options = struct {};
pub fn init(_: Options) !Self {
    return .{};
}
pub fn deinit(_: Self) void {}
