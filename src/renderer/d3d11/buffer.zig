const std = @import("std");
const api = @import("api.zig");
pub const Options = struct { device: *api.Device, uniform: bool = false };

/// Equal-sized elements retain the same generic renderer dirty-range contract.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();
        buffer: *api.Buffer,
        opts: Options,
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            const bytes = std.math.mul(usize, len, @sizeOf(T)) catch return error.Direct3D11Failed;
            const handle = api.noctty_d3d11_buffer_create(opts.device, bytes, @intFromBool(opts.uniform)) orelse return api.allocationError(opts.device);
            return .{ .buffer = handle, .opts = opts, .len = len };
        }
        pub fn initFill(opts: Options, data: []const T) !Self {
            var result = try init(opts, data.len);
            errdefer result.deinit();
            try result.sync(data);
            return result;
        }
        pub fn deinit(self: Self) void {
            api.noctty_d3d11_buffer_destroy(self.buffer);
        }
        fn reserve(self: *Self, len: usize) !bool {
            if (len <= self.len) return false;
            const capacity = std.math.mul(usize, len, 2) catch return error.Direct3D11Failed;
            const bytes = std.math.mul(usize, capacity, @sizeOf(T)) catch return error.Direct3D11Failed;
            try api.check(api.noctty_d3d11_buffer_reserve(self.buffer, bytes));
            self.len = capacity;
            return true;
        }
        fn write(self: *Self, offset: usize, data: []const T) !void {
            if (data.len == 0) return;
            const bytes = std.mem.sliceAsBytes(data);
            try api.check(api.noctty_d3d11_buffer_write(self.buffer, offset * @sizeOf(T), bytes.ptr, bytes.len));
        }
        pub fn sync(self: *Self, data: []const T) !void {
            _ = try self.reserve(data.len);
            try self.write(0, data);
        }
        pub fn syncRange(self: *Self, all: []const T, start: usize, end: usize) !void {
            if (try self.reserve(all.len)) return self.write(0, all);
            try self.write(start, all[start..end]);
        }
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            return self.syncFromArrayListsStart(lists, 0);
        }
        pub fn syncFromArrayListsStart(self: *Self, lists: []const std.ArrayListUnmanaged(T), start_index: usize) !usize {
            var total: usize = 0;
            var prefix: usize = 0;
            var start = @min(start_index, lists.len);
            for (lists, 0..) |list, i| {
                total += list.items.len;
                if (i < start) prefix += list.items.len;
            }
            if (try self.reserve(total)) {
                start = 0;
                prefix = 0;
            }
            var offset = prefix;
            for (lists[start..]) |list| {
                try self.write(offset, list.items);
                offset += list.items.len;
            }
            return total;
        }
    };
}
