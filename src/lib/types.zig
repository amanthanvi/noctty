pub const String = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(zig: []const u8) String {
        return .{
            .ptr = zig.ptr,
            .len = zig.len,
        };
    }
};

pub const Buffer = extern struct {
    ptr: ?[*]u8 = null,
    cap: usize = 0,
    len: usize = 0,
};

test "String init accepts byte slices" {
    var mutable = [_]u8{ 'h', 'i' };
    const mut = String.init(mutable[0..]);
    try @import("std").testing.expectEqual(@as(usize, 2), mut.len);

    const const_slice: []const u8 = "hello";
    const constant = String.init(const_slice);
    try @import("std").testing.expectEqual(@as(usize, 5), constant.len);
}
