//! Bounded undo/redo stack for per-surface recoverable terminal actions.
//!
//! Pure bookkeeping: stores opaque pre-action terminal snapshots for
//! `clear_screen` and `reset`. Capture and replay logic lives in the
//! Win32 apprt surface; this module only manages the stack and memory
//! budget.
//!
//! Two caps are load-bearing for memory safety in long sessions:
//!   - `max_entries` (16) prevents unbounded list growth.
//!   - `max_total_bytes` (8 MB) caps retained terminal-state blobs so
//!     a heavy terminal session doesn't balloon RSS.
//! Both are enforced on every `push`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { clear_screen, reset };

pub const ClearScreenSnapshot = struct {
    state_bytes: []u8,
};

pub const ResetSnapshot = struct {
    state_bytes: []u8,
};

pub const Snapshot = union(Kind) {
    clear_screen: ClearScreenSnapshot,
    reset: ResetSnapshot,
};

pub const Entry = struct {
    kind: Kind,
    snapshot: Snapshot,
    timestamp_ms: u64,
    sequence_id: u64 = 0,

    /// Pty clear generation when the snapshot was captured. Only a later
    /// successful clear makes its saved cursor stale relative to ConPTY.
    pty_clear_generation: u64 = 0,

    /// Owned-byte footprint used for cap accounting.
    pub fn byteSize(self: Entry) usize {
        return switch (self.snapshot) {
            .clear_screen => |s| s.state_bytes.len,
            .reset => |s| s.state_bytes.len,
        };
    }

    /// Frees every owned byte slice inside the snapshot.
    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.snapshot) {
            .clear_screen => |s| alloc.free(s.state_bytes),
            .reset => |s| alloc.free(s.state_bytes),
        }
    }
};

pub const max_entries: usize = 16;
pub const max_total_bytes: usize = 8 * 1024 * 1024;

pub const UndoStack = struct {
    alloc: Allocator,
    entries: std.ArrayListUnmanaged(Entry),
    redo_entries: std.ArrayListUnmanaged(Entry),
    total_bytes: usize,

    pub fn init(alloc: Allocator) UndoStack {
        return .{
            .alloc = alloc,
            .entries = .empty,
            .redo_entries = .empty,
            .total_bytes = 0,
        };
    }

    pub fn deinit(self: *UndoStack) void {
        for (self.entries.items) |*e| e.deinit(self.alloc);
        self.entries.deinit(self.alloc);
        for (self.redo_entries.items) |*e| e.deinit(self.alloc);
        self.redo_entries.deinit(self.alloc);
        self.total_bytes = 0;
    }

    /// Push a new entry, taking ownership of its snapshot allocations.
    /// Reserves append capacity first so an allocation failure leaves the
    /// existing undo/redo history untouched, then clears the redo branch
    /// and evicts oldest undo entries until both caps (count + bytes) are
    /// satisfied.
    pub fn push(self: *UndoStack, entry: Entry) Allocator.Error!void {
        try self.entries.ensureUnusedCapacity(self.alloc, 1);

        // New action invalidates the redo branch.
        self.clearRedoBranch();

        const incoming = entry.byteSize();

        while (self.entries.items.len > 0 and
            self.total_bytes + incoming > max_total_bytes)
        {
            self.evictOldest();
        }

        while (self.entries.items.len >= max_entries) {
            self.evictOldest();
        }

        self.entries.appendAssumeCapacity(entry);
        self.total_bytes += incoming;
    }

    /// Move the newest undo entry to the redo stack and return a
    /// borrowed pointer into the redo list so the caller can replay
    /// its snapshot. Returns `error.OutOfMemory` only if the redo append
    /// fails, and in that case restores the entry to the undo stack so
    /// replay state is unchanged. The pointer is only valid until the
    /// next mutation of `redo_entries`; callers must consume it
    /// synchronously.
    pub fn popForUndo(self: *UndoStack) Allocator.Error!?*const Entry {
        const entry = self.entries.pop() orelse return null;
        self.total_bytes -= entry.byteSize();
        self.redo_entries.append(self.alloc, entry) catch |err| {
            self.total_bytes += entry.byteSize();
            self.entries.append(self.alloc, entry) catch unreachable;
            return err;
        };
        return &self.redo_entries.items[self.redo_entries.items.len - 1];
    }

    /// Move the newest redo entry back onto the undo stack and return
    /// a borrowed pointer into the undo list. Returns `error.OutOfMemory`
    /// only if the undo append fails, and in that case restores the
    /// entry to the redo stack so replay state is unchanged. Same
    /// lifetime rules as `popForUndo`.
    pub fn popForRedo(self: *UndoStack) Allocator.Error!?*const Entry {
        const entry = self.redo_entries.pop() orelse return null;
        self.entries.append(self.alloc, entry) catch |err| {
            self.redo_entries.append(self.alloc, entry) catch unreachable;
            return err;
        };
        self.total_bytes += entry.byteSize();
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// Undo the most recent `popForRedo` when replay proves impossible
    /// before committing any terminal mutation.
    pub fn restoreLastRedoPop(self: *UndoStack) void {
        const entry = self.entries.pop() orelse return;
        self.total_bytes -= entry.byteSize();
        self.redo_entries.append(self.alloc, entry) catch unreachable;
    }

    pub fn undoDepth(self: *const UndoStack) usize {
        return self.entries.items.len;
    }

    pub fn redoDepth(self: *const UndoStack) usize {
        return self.redo_entries.items.len;
    }

    pub fn oldestTimestamp(self: *const UndoStack) ?u64 {
        var oldest: ?u64 = null;
        for (self.entries.items) |entry| {
            if (oldest == null or entry.timestamp_ms < oldest.?) oldest = entry.timestamp_ms;
        }
        for (self.redo_entries.items) |entry| {
            if (oldest == null or entry.timestamp_ms < oldest.?) oldest = entry.timestamp_ms;
        }
        return oldest;
    }

    pub fn peekUndo(self: *const UndoStack) ?*const Entry {
        if (self.entries.items.len == 0) return null;
        return &self.entries.items[self.entries.items.len - 1];
    }

    pub fn peekRedo(self: *const UndoStack) ?*const Entry {
        if (self.redo_entries.items.len == 0) return null;
        return &self.redo_entries.items[self.redo_entries.items.len - 1];
    }

    /// Drop every undo/redo entry older than `min_timestamp_ms`.
    /// The undo-side byte budget is updated as entries are removed.
    pub fn discardExpired(self: *UndoStack, min_timestamp_ms: u64) void {
        self.discardExpiredFromList(&self.entries, min_timestamp_ms, true);
        self.discardExpiredFromList(&self.redo_entries, min_timestamp_ms, false);
    }

    pub fn clear(self: *UndoStack) void {
        while (self.entries.items.len > 0) self.evictOldest();
        self.clearRedoBranch();
    }

    pub fn clearRedo(self: *UndoStack) void {
        self.clearRedoBranch();
    }

    fn discardExpiredFromList(
        self: *UndoStack,
        list: *std.ArrayListUnmanaged(Entry),
        min_timestamp_ms: u64,
        account_bytes: bool,
    ) void {
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].timestamp_ms >= min_timestamp_ms) {
                i += 1;
                continue;
            }

            var expired = list.orderedRemove(i);
            if (account_bytes) self.total_bytes -= expired.byteSize();
            expired.deinit(self.alloc);
        }
    }

    fn evictOldest(self: *UndoStack) void {
        var oldest = self.entries.orderedRemove(0);
        self.total_bytes -= oldest.byteSize();
        oldest.deinit(self.alloc);
    }

    fn clearRedoBranch(self: *UndoStack) void {
        // Do NOT subtract redo bytes from `total_bytes` — those bytes
        // were already deducted when entries moved undo → redo in
        // `popForUndo`, and `total_bytes` only tracks the undo-side
        // footprint for cap enforcement.
        for (self.redo_entries.items) |*e| e.deinit(self.alloc);
        self.redo_entries.clearAndFree(self.alloc);
    }
};

fn makeSmallEntry(alloc: Allocator, id: u8) Allocator.Error!Entry {
    const buf = try alloc.alloc(u8, 4);
    @memset(buf, id);
    return .{
        .kind = .clear_screen,
        .snapshot = .{ .clear_screen = .{ .state_bytes = buf } },
        .timestamp_ms = id,
    };
}

fn makeSizedEntry(alloc: Allocator, size: usize, ts: u64) Allocator.Error!Entry {
    const buf = try alloc.alloc(u8, size);
    @memset(buf, 0xAB);
    return .{
        .kind = .clear_screen,
        .snapshot = .{ .clear_screen = .{ .state_bytes = buf } },
        .timestamp_ms = ts,
    };
}

test "push enforces entry count cap" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    for (0..20) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }
    try std.testing.expectEqual(max_entries, stack.undoDepth());
    try std.testing.expectEqual(@as(u64, 4), stack.entries.items[0].timestamp_ms);
}

test "push enforces byte cap" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const chunk: usize = 2 * 1024 * 1024;
    for (0..8) |i| {
        const entry = try makeSizedEntry(alloc, chunk, @intCast(i));
        try stack.push(entry);
        try std.testing.expect(stack.total_bytes <= max_total_bytes);
    }
    try std.testing.expect(stack.undoDepth() <= 4);
}

test "push clears redo stack" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const a = try makeSmallEntry(alloc, 1);
    const b = try makeSmallEntry(alloc, 2);
    try stack.push(a);
    try stack.push(b);

    _ = try stack.popForUndo();
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());

    const c = try makeSmallEntry(alloc, 3);
    try stack.push(c);
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
    try std.testing.expectEqual(@as(usize, 2), stack.undoDepth());
}

test "oldestTimestamp scans undo and redo branches" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    try stack.push(try makeSmallEntry(alloc, 10));
    try stack.push(try makeSmallEntry(alloc, 20));
    try std.testing.expectEqual(@as(?u64, 10), stack.oldestTimestamp());

    _ = try stack.popForUndo();
    try std.testing.expectEqual(@as(?u64, 10), stack.oldestTimestamp());

    stack.clear();
    try std.testing.expectEqual(@as(?u64, null), stack.oldestTimestamp());
}

test "push after undo does not underflow total_bytes" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const a = try makeSmallEntry(alloc, 1);
    const a_size = a.byteSize();
    try stack.push(a);
    try std.testing.expectEqual(a_size, stack.total_bytes);

    _ = try stack.popForUndo();
    try std.testing.expectEqual(@as(usize, 0), stack.total_bytes);

    const b = try makeSmallEntry(alloc, 2);
    const b_size = b.byteSize();
    try stack.push(b);
    try std.testing.expectEqual(b_size, stack.total_bytes);
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
}

test "push allocation failure preserves undo and redo history" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    try stack.push(try makeSmallEntry(alloc, 1));
    try stack.push(try makeSmallEntry(alloc, 2));
    _ = try stack.popForUndo();
    stack.entries.shrinkAndFree(alloc, stack.entries.items.len);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const original_alloc = stack.alloc;
    stack.alloc = failing.allocator();
    defer stack.alloc = original_alloc;

    var entry = try makeSmallEntry(alloc, 3);
    var push_owned_entry = false;
    defer if (!push_owned_entry) entry.deinit(alloc);

    if (stack.push(entry)) {
        push_owned_entry = true;
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }

    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());
    try std.testing.expectEqual(@as(u64, 1), stack.peekUndo().?.timestamp_ms);
    try std.testing.expectEqual(@as(u64, 2), stack.peekRedo().?.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 4), stack.total_bytes);
}

test "clearRedo clears redo branch without touching undo history" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const a = try makeSmallEntry(alloc, 1);
    const b = try makeSmallEntry(alloc, 2);
    try stack.push(a);
    try stack.push(b);

    const undo_bytes = stack.total_bytes;
    _ = try stack.popForUndo();
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());

    stack.clearRedo();

    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
    try std.testing.expectEqual(undo_bytes - b.byteSize(), stack.total_bytes);
    try std.testing.expectEqual(@as(u64, 1), stack.peekUndo().?.timestamp_ms);
}

test "popForUndo returns newest" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    for (1..4) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }

    const e3 = (try stack.popForUndo()).?;
    try std.testing.expectEqual(@as(u64, 3), e3.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 2), stack.undoDepth());

    const e2 = (try stack.popForUndo()).?;
    try std.testing.expectEqual(@as(u64, 2), e2.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
}

test "popForUndo moves to redo and popForRedo moves back" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const entry = try makeSmallEntry(alloc, 42);
    try stack.push(entry);

    {
        const popped = (try stack.popForUndo()).?;
        try std.testing.expectEqual(@as(u64, 42), popped.timestamp_ms);
    }
    try std.testing.expectEqual(@as(usize, 0), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());

    {
        const restored = (try stack.popForRedo()).?;
        try std.testing.expectEqual(@as(u64, 42), restored.timestamp_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
}

test "restoreLastRedoPop preserves redo after failed replay" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    const entry = try makeSmallEntry(alloc, 42);
    try stack.push(entry);
    _ = try stack.popForUndo();

    {
        const redo = (try stack.popForRedo()).?;
        try std.testing.expectEqual(@as(u64, 42), redo.timestamp_ms);
    }
    stack.restoreLastRedoPop();

    try std.testing.expectEqual(@as(usize, 0), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());
    try std.testing.expectEqual(@as(u64, 42), stack.peekRedo().?.timestamp_ms);
}

test "popForUndo propagates allocation failure and preserves undo entry" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    try stack.push(try makeSmallEntry(alloc, 42));

    var backing: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const original_alloc = stack.alloc;
    stack.alloc = fixed.allocator();
    defer stack.alloc = original_alloc;

    try std.testing.expectError(error.OutOfMemory, stack.popForUndo());
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 0), stack.redoDepth());
    try std.testing.expectEqual(@as(u64, 42), stack.peekUndo().?.timestamp_ms);
}

test "popForRedo propagates allocation failure and preserves redo entry" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    try stack.push(try makeSmallEntry(alloc, 42));
    _ = try stack.popForUndo();
    stack.entries.clearAndFree(alloc);

    var backing: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const original_alloc = stack.alloc;
    stack.alloc = fixed.allocator();
    defer stack.alloc = original_alloc;

    try std.testing.expectError(error.OutOfMemory, stack.popForRedo());
    try std.testing.expectEqual(@as(usize, 0), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());
    try std.testing.expectEqual(@as(u64, 42), stack.peekRedo().?.timestamp_ms);
}

test "deinit frees everything" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);

    for (0..5) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }
    _ = try stack.popForUndo();

    stack.deinit();
}

test "single oversized entry is accepted and empties the rest" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    for (0..5) |i| {
        const entry = try makeSmallEntry(alloc, @intCast(i));
        try stack.push(entry);
    }
    try std.testing.expectEqual(@as(usize, 5), stack.undoDepth());

    const big = try makeSizedEntry(alloc, max_total_bytes + 1024, 99);
    try stack.push(big);

    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(u64, 99), stack.entries.items[0].timestamp_ms);
}

test "peekUndo and peekRedo expose the next replay entry" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    try stack.push(try makeSmallEntry(alloc, 1));
    try stack.push(try makeSmallEntry(alloc, 2));
    try stack.push(try makeSmallEntry(alloc, 3));

    try std.testing.expectEqual(@as(u64, 3), stack.peekUndo().?.timestamp_ms);
    _ = try stack.popForUndo();
    try std.testing.expectEqual(@as(u64, 2), stack.peekUndo().?.timestamp_ms);
    try std.testing.expectEqual(@as(u64, 3), stack.peekRedo().?.timestamp_ms);
    _ = try stack.popForUndo();
    try std.testing.expectEqual(@as(u64, 2), stack.peekRedo().?.timestamp_ms);
}

test "discardExpired prunes undo and redo branches" {
    const alloc = std.testing.allocator;
    var stack = UndoStack.init(alloc);
    defer stack.deinit();

    try stack.push(.{
        .kind = .clear_screen,
        .snapshot = .{ .clear_screen = .{ .state_bytes = try alloc.dupe(u8, "a") } },
        .timestamp_ms = 10,
    });
    try stack.push(.{
        .kind = .clear_screen,
        .snapshot = .{ .clear_screen = .{ .state_bytes = try alloc.dupe(u8, "b") } },
        .timestamp_ms = 20,
    });
    try stack.push(.{
        .kind = .clear_screen,
        .snapshot = .{ .clear_screen = .{ .state_bytes = try alloc.dupe(u8, "c") } },
        .timestamp_ms = 30,
    });

    _ = try stack.popForUndo();
    _ = try stack.popForUndo();
    try std.testing.expectEqual(@as(usize, 1), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 2), stack.redoDepth());

    stack.discardExpired(25);

    try std.testing.expectEqual(@as(usize, 0), stack.undoDepth());
    try std.testing.expectEqual(@as(usize, 1), stack.redoDepth());
    try std.testing.expectEqual(@as(u64, 30), stack.peekRedo().?.timestamp_ms);
    try std.testing.expectEqual(@as(usize, 0), stack.total_bytes);
}
