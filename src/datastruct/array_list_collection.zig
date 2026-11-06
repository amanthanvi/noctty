const std = @import("std");
const Allocator = std.mem.Allocator;

/// A collection of ArrayLists with methods for bulk operations.
pub fn ArrayListCollection(comptime T: type) type {
    return struct {
        const Self = ArrayListCollection(T);
        const ArrayListT = std.ArrayListUnmanaged(T);

        // An array containing the lists that belong to this collection.
        lists: []ArrayListT,

        // The collection will be initialized with empty ArrayLists.
        pub fn init(
            alloc: Allocator,
            list_count: usize,
            initial_capacity: usize,
        ) Allocator.Error!Self {
            const self: Self = .{
                .lists = try alloc.alloc(ArrayListT, list_count),
            };
            errdefer alloc.free(self.lists);

            for (self.lists, 0..) |*list, i| {
                // A failure frees the lists already allocated.
                errdefer for (self.lists[0..i]) |*done| done.deinit(alloc);
                list.* = try .initCapacity(alloc, initial_capacity);
            }

            return self;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.lists) |*list| {
                list.deinit(alloc);
            }
            alloc.free(self.lists);
        }

        /// Clear all lists in the collection, retaining capacity.
        pub fn reset(self: *Self) void {
            for (self.lists) |*list| {
                list.clearRetainingCapacity();
            }
        }
    };
}

test "ArrayListCollection init frees what it allocated when an allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var lists: ArrayListCollection(u32) = try .init(alloc, 4, 8);
            lists.deinit(alloc);
        }
    }.run, .{});
}
