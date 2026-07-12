//! Structural undo/redo bookkeeping for the Win32 apprt.
//!
//! This module deliberately owns only list mechanics: timestamp/sequence
//! ordering, bounded storage, pruning, and undo<->redo moves. Win32 replay,
//! detached surface/tab disposal, and shell-state mutations stay with Host.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn List(comptime Entry: type) type {
    return std.ArrayListUnmanaged(Entry);
}

pub fn sortsAfter(
    lhs_timestamp_ms: u64,
    lhs_sequence_id: u64,
    rhs_timestamp_ms: u64,
    rhs_sequence_id: u64,
) bool {
    return lhs_timestamp_ms > rhs_timestamp_ms or
        (lhs_timestamp_ms == rhs_timestamp_ms and lhs_sequence_id > rhs_sequence_id);
}

pub fn chooseStructural(
    structural_timestamp_ms: u64,
    structural_sequence_id: u64,
    local_timestamp_ms: u64,
    local_sequence_id: u64,
) bool {
    return sortsAfter(
        structural_timestamp_ms,
        structural_sequence_id,
        local_timestamp_ms,
        local_sequence_id,
    );
}

pub fn peek(comptime Entry: type, list: *const List(Entry)) ?*const Entry {
    if (list.items.len == 0) return null;
    return &list.items[list.items.len - 1];
}

pub fn appendAssumeCapacity(comptime Entry: type, list: *List(Entry), entry: Entry) *Entry {
    list.appendAssumeCapacity(entry);
    return &list.items[list.items.len - 1];
}

pub fn moveNewest(
    comptime Entry: type,
    from: *List(Entry),
    to: *List(Entry),
    alloc: Allocator,
) Allocator.Error!?*Entry {
    const entry = from.pop() orelse return null;
    to.append(alloc, entry) catch |err| {
        from.append(alloc, entry) catch unreachable;
        return err;
    };
    return &to.items[to.items.len - 1];
}

pub fn restoreNewestMove(
    comptime Entry: type,
    from: *List(Entry),
    to: *List(Entry),
    alloc: Allocator,
) void {
    const entry = from.pop() orelse return;
    to.append(alloc, entry) catch unreachable;
}

pub fn oldestTimestamp(comptime Entry: type, undo: *const List(Entry), redo: *const List(Entry)) ?u64 {
    var oldest: ?u64 = null;
    for (undo.items) |entry| {
        if (oldest == null or entry.timestamp_ms < oldest.?) oldest = entry.timestamp_ms;
    }
    for (redo.items) |entry| {
        if (oldest == null or entry.timestamp_ms < oldest.?) oldest = entry.timestamp_ms;
    }
    return oldest;
}

pub fn hasHistory(comptime Entry: type, undo: *const List(Entry), redo: *const List(Entry)) bool {
    return undo.items.len > 0 or redo.items.len > 0;
}

pub fn discardNewest(
    comptime Entry: type,
    list: *List(Entry),
    ctx: anytype,
    disposeFn: anytype,
) bool {
    if (list.items.len == 0) return true;
    const index = list.items.len - 1;
    disposeFn(ctx, &list.items[index]) catch return false;
    _ = list.pop();
    return true;
}

pub fn clear(
    comptime Entry: type,
    list: *List(Entry),
    ctx: anytype,
    disposeFn: anytype,
) bool {
    while (list.items.len > 0) {
        if (!discardNewest(Entry, list, ctx, disposeFn)) return false;
    }
    return true;
}

pub fn pruneExpired(
    comptime Entry: type,
    list: *List(Entry),
    min_timestamp_ms: u64,
    ctx: anytype,
    disposeFn: anytype,
) bool {
    var complete = true;
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i].timestamp_ms >= min_timestamp_ms) {
            i += 1;
            continue;
        }

        disposeFn(ctx, &list.items[i]) catch {
            complete = false;
            i += 1;
            continue;
        };
        _ = list.orderedRemove(i);
    }
    return complete;
}

pub fn evictOldest(
    comptime Entry: type,
    list: *List(Entry),
    ctx: anytype,
    disposeFn: anytype,
) !void {
    try disposeFn(ctx, &list.items[0]);
    _ = list.orderedRemove(0);
}

const DummyEntry = struct {
    timestamp_ms: u64,
    sequence_id: u64,
    disposed: bool = false,
};

const DummyCtx = struct {
    fail_on_sequence: ?u64 = null,
};

fn disposeDummy(ctx: *DummyCtx, entry: *DummyEntry) !void {
    if (ctx.fail_on_sequence == entry.sequence_id) return error.DisposeBlocked;
    entry.disposed = true;
}

test "structural history ordering uses sequence when timestamps tie" {
    try std.testing.expect(sortsAfter(10, 2, 10, 1));
    try std.testing.expect(!sortsAfter(10, 1, 10, 2));
    try std.testing.expect(sortsAfter(11, 0, 10, 999));
    try std.testing.expect(chooseStructural(20, 5, 20, 4));
}

test "structural history move failure rolls entry back before replay" {
    var buf: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&buf);
    var undo: List(DummyEntry) = .empty;
    var redo: List(DummyEntry) = .empty;

    try undo.append(std.testing.allocator, .{ .timestamp_ms = 1, .sequence_id = 1 });
    defer undo.deinit(std.testing.allocator);
    defer redo.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.OutOfMemory,
        moveNewest(DummyEntry, &undo, &redo, fixed.allocator()),
    );
    try std.testing.expectEqual(@as(usize, 1), undo.items.len);
    try std.testing.expectEqual(@as(usize, 0), redo.items.len);
}

test "structural history restore rolls back only explicit pre-mutation failures" {
    var undo: List(DummyEntry) = .empty;
    var redo: List(DummyEntry) = .empty;
    defer undo.deinit(std.testing.allocator);
    defer redo.deinit(std.testing.allocator);

    try undo.append(std.testing.allocator, .{ .timestamp_ms = 1, .sequence_id = 1 });
    _ = try moveNewest(DummyEntry, &undo, &redo, std.testing.allocator);
    restoreNewestMove(DummyEntry, &redo, &undo, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), undo.items.len);
    try std.testing.expectEqual(@as(usize, 0), redo.items.len);

    _ = try moveNewest(DummyEntry, &undo, &redo, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), undo.items.len);
    try std.testing.expectEqual(@as(usize, 1), redo.items.len);
}

test "structural history pruning preserves blocked entries and removes expired disposable entries" {
    var list: List(DummyEntry) = .empty;
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, .{ .timestamp_ms = 10, .sequence_id = 1 });
    try list.append(std.testing.allocator, .{ .timestamp_ms = 20, .sequence_id = 2 });
    try list.append(std.testing.allocator, .{ .timestamp_ms = 30, .sequence_id = 3 });

    var ctx: DummyCtx = .{ .fail_on_sequence = 2 };
    try std.testing.expect(!pruneExpired(DummyEntry, &list, 25, &ctx, disposeDummy));
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u64, 2), list.items[0].sequence_id);
    try std.testing.expectEqual(@as(u64, 3), list.items[1].sequence_id);
}

test "structural history oldest timestamp and capacity eviction are storage-only" {
    var undo: List(DummyEntry) = .empty;
    var redo: List(DummyEntry) = .empty;
    defer undo.deinit(std.testing.allocator);
    defer redo.deinit(std.testing.allocator);

    try undo.append(std.testing.allocator, .{ .timestamp_ms = 30, .sequence_id = 3 });
    try redo.append(std.testing.allocator, .{ .timestamp_ms = 10, .sequence_id = 1 });
    try std.testing.expectEqual(@as(u64, 10), oldestTimestamp(DummyEntry, &undo, &redo).?);
    try std.testing.expect(hasHistory(DummyEntry, &undo, &redo));

    var ctx: DummyCtx = .{};
    try evictOldest(DummyEntry, &redo, &ctx, disposeDummy);
    try std.testing.expectEqual(@as(usize, 0), redo.items.len);
}
