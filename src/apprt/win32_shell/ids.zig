const std = @import("std");

/// A compact, typed entity identifier. Reusing a slot always changes its
/// generation, so delayed adapter completions cannot address a new entity.
pub fn Id(comptime domain: []const u8) type {
    return struct {
        pub const domain_name = domain;

        index: u32,
        generation: u32,

        const Self = @This();

        pub fn eql(self: Self, other: Self) bool {
            return self.index == other.index and self.generation == other.generation;
        }
    };
}

pub const WindowId = Id("window");
pub const TabId = Id("tab");
pub const PaneId = Id("pane");
pub const NodeId = Id("node");
pub const EffectId = Id("effect");

/// Slot allocator shared by pure shell entities and pending effects.
pub fn Pool(comptime EntityId: type) type {
    return struct {
        generations: std.ArrayList(u32) = .empty,
        active: std.ArrayList(bool) = .empty,
        free: std.ArrayList(u32) = .empty,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.generations.deinit(allocator);
            self.active.deinit(allocator);
            self.free.deinit(allocator);
        }

        pub fn reserve(self: *Self, allocator: std.mem.Allocator) !void {
            try self.reserveMany(allocator, 1);
        }

        pub fn reserveMany(self: *Self, allocator: std.mem.Allocator, count: usize) !void {
            try self.generations.ensureUnusedCapacity(allocator, count);
            try self.active.ensureUnusedCapacity(allocator, count);
        }

        pub fn acquireAssumeCapacity(self: *Self) EntityId {
            if (self.free.pop()) |index| {
                self.active.items[index] = true;
                return .{
                    .index = index,
                    .generation = self.generations.items[index],
                };
            }

            const index: u32 = @intCast(self.generations.items.len);
            self.generations.appendAssumeCapacity(1);
            self.active.appendAssumeCapacity(true);
            return .{ .index = index, .generation = 1 };
        }

        pub fn acquire(self: *Self, allocator: std.mem.Allocator) !EntityId {
            try self.reserve(allocator);
            return self.acquireAssumeCapacity();
        }

        pub fn release(self: *Self, allocator: std.mem.Allocator, id: EntityId) !void {
            if (!self.isCurrent(id)) return error.StaleId;
            try self.free.ensureUnusedCapacity(allocator, 1);
            self.generations.items[id.index] +%= 1;
            if (self.generations.items[id.index] == 0) {
                self.generations.items[id.index] = 1;
            }
            self.active.items[id.index] = false;
            self.free.appendAssumeCapacity(id.index);
        }

        pub fn isCurrent(self: *const Self, id: EntityId) bool {
            return id.index < self.generations.items.len and
                self.generations.items[id.index] == id.generation and
                self.active.items[id.index];
        }
    };
}

test "released slots are reused with a new generation" {
    const allocator = std.testing.allocator;
    var pool: Pool(PaneId) = .{};
    defer pool.deinit(allocator);

    const first = try pool.acquire(allocator);
    try std.testing.expect(pool.isCurrent(first));
    try pool.release(allocator, first);
    try std.testing.expect(!pool.isCurrent(first));

    const second = try pool.acquire(allocator);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expect(pool.isCurrent(second));
}

test "identifier domains are distinct types" {
    try std.testing.expect(WindowId != TabId);
}

test "liveness is independent of free-list length" {
    const allocator = std.testing.allocator;
    var pool: Pool(PaneId) = .{};
    defer pool.deinit(allocator);

    var ids: [128]PaneId = undefined;
    for (&ids) |*id| id.* = try pool.acquire(allocator);
    const survivor = ids[127];
    for (ids[0..127]) |id| try pool.release(allocator, id);

    try std.testing.expectEqual(@as(usize, 127), pool.free.items.len);
    try std.testing.expect(pool.isCurrent(survivor));
    try std.testing.expect(!pool.isCurrent(ids[0]));
}
