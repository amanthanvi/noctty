//! The pair recorder of the runtime thread-role layer (PLAN.md §2.7 RQ12,
//! §19.3): each (acquiring function, role) pair a process's renderer-state
//! mutex sees, once per process. It is bounded, never allocates and takes no
//! lock to record: `StateMutex`'s recorder hook calls `process.record` at
//! every acquisition, before any policy and before the inner lock, and a new
//! pair goes to the process's dump (`dump.zig`) before the call returns, so
//! a process that then panics, crashes or is killed keeps every pair it saw.
//!
//! A pair is a site, the return address `StateMutex` takes (inside the
//! acquiring function, §19.1), and the thread's role; the acquire kind rides
//! along for the dump (one site is one call, so one kind). The table is open
//! addressing with linear probing: a thread claims an empty slot by
//! compare-and-swap, writes the pair and publishes it; a thread that finds a
//! slot being written waits for it, and one that finds its pair published
//! returns. A worker role matches by its name's bytes. The capacity is a
//! comptime parameter: the process's is `process_capacity`, and tests build
//! small ones (acceptance test 12). A full table is PN5, after the pair that
//! found it full is written to the dump.
//!
//! Only `StateMutex`'s hook reaches `process`, and only with the layer on
//! (`thread_role.layer`): a build with the layer off has no table, no dump
//! and no PN5 text.

const std = @import("std");
const builtin = @import("builtin");
const thread_role = @import("thread_role.zig");
const state_mutex = @import("state_mutex.zig");
const dump = @import("dump.zig");

const Role = thread_role.Role;
const RoleTag = std.meta.Tag(Role);
const Acquire = state_mutex.Acquire;

/// The process recorder's capacity: the fork head has 96 production gate
/// sites and 2 test-code sites, each seen in at most 3 roles (§19.3).
pub const process_capacity = 4096;

/// The process's recorder, which `StateMutex` fills; its dump goes to the
/// directory `NOCTTY_THREAD_ROLE_DUMP` names.
pub var process: Recorder(process_capacity) = .{
    .sink = .{ .target = .{ .environment = dump.env_var_w } },
};

/// Names the process's kind in its dump's header: an isolated child calls
/// this with `.child` before it acquires anything. It fails once the
/// process has recorded its first pair.
pub fn setProcessKind(kind: dump.ProcessKind) error{AlreadyDecided}!void {
    return process.sink.setKind(kind);
}

/// What `insert` did with a pair.
pub const Outcome = enum {
    /// It took a slot: the first time the table saw the pair.
    new,
    /// The table already held it.
    seen,
    /// No slot was free and the table does not hold it.
    full,
};

pub fn Recorder(comptime capacity: usize) type {
    if (capacity == 0) @compileError("a recorder needs at least one slot");
    return struct {
        const Self = @This();

        slots: [capacity]Slot = @splat(.{}),
        /// Where new pairs go.
        sink: dump.Dump,

        pub const slot_count = capacity;

        /// Records a pair: a new one goes to the dump, and a full table
        /// panics (PN5) once the pair is in the dump.
        pub fn record(self: *Self, site: usize, role: Role, acquire: Acquire) void {
            switch (self.insert(site, role, acquire)) {
                .seen => {},
                .new => self.sink.append(site, role, acquire),
                .full => {
                    self.sink.append(site, role, acquire);
                    panicFull(capacity);
                },
            }
        }

        /// The table alone: claims a slot for a pair it does not hold yet.
        /// Safe from any number of threads.
        pub fn insert(self: *Self, site: usize, role: Role, acquire: Acquire) Outcome {
            const start: usize = @intCast(hash(site, role) % capacity);
            for (0..capacity) |i| {
                const slot = &self.slots[(start + i) % capacity];
                var state = slot.state.load(.acquire);
                if (state == .empty) {
                    state = slot.state.cmpxchgStrong(.empty, .writing, .acquire, .acquire) orelse {
                        slot.site = site;
                        slot.acquire = acquire;
                        slot.tag = std.meta.activeTag(role);
                        if (role == .worker) {
                            slot.name_ptr = role.worker.ptr;
                            slot.name_len = role.worker.len;
                        }
                        slot.state.store(.ready, .release);
                        return .new;
                    };
                }
                // Another thread claimed it and is writing its pair: a few
                // stores, unless that thread is preempted.
                var spins: u32 = 0;
                while (state == .writing) : (state = slot.state.load(.acquire)) {
                    spins +%= 1;
                    if (spins % 64 == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
                }
                if (slot.matches(site, role)) return .seen;
            }
            return .full;
        }

        /// Whether the table holds the pair.
        pub fn contains(self: *const Self, site: usize, role: Role) bool {
            const start: usize = @intCast(hash(site, role) % capacity);
            for (0..capacity) |i| {
                const slot = &self.slots[(start + i) % capacity];
                switch (slot.state.load(.acquire)) {
                    .empty => return false,
                    .writing => continue,
                    .ready => if (slot.matches(site, role)) return true,
                }
            }
            return false;
        }

        /// The pairs the table holds (published ones).
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.state.load(.acquire) == .ready) n += 1;
            }
            return n;
        }
    };
}

const Slot = struct {
    state: std.atomic.Value(State) = .init(.empty),
    acquire: Acquire = .lock,
    tag: RoleTag = .none,
    site: usize = 0,
    /// A worker's name; set only for `.worker`.
    name_ptr: ?[*]const u8 = null,
    name_len: usize = 0,

    // Every default is zero, so a table is zero-initialised data.
    const State = enum(u8) { empty, writing, ready };

    /// Whether this published slot holds the pair.
    fn matches(self: *const Slot, site: usize, role: Role) bool {
        if (self.site != site or self.tag != std.meta.activeTag(role)) return false;
        if (role != .worker) return true;
        return std.mem.eql(u8, self.name_ptr.?[0..self.name_len], role.worker);
    }
};

fn hash(site: usize, role: Role) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&site));
    h.update(&.{@intFromEnum(std.meta.activeTag(role))});
    if (role == .worker) h.update(role.worker);
    return h.final();
}

fn panicFull(capacity: usize) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN5 the pair recorder is full: more than {d} distinct " ++
            "(acquiring function, role) pairs in one process; the dump holds every pair " ++
            "it saw, and recorder.process_capacity sets the process's bound",
        .{capacity},
    );
}

const testing = std.testing;

test {
    _ = dump;
}

test "the process recorder is the build's capacity and writes to the dump variable's directory" {
    try testing.expectEqual(4096, @TypeOf(process).slot_count);
    try testing.expectEqualSlices(u16, dump.env_var_w, process.sink.target.environment);
    try testing.expectEqualStrings("NOCTTY_THREAD_ROLE_DUMP", dump.env_var);
    // A table is zero-initialised: an empty slot is all zero bytes.
    const empty: Slot = .{};
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&empty), 0));
}

test "a 16-slot recorder holds 16 distinct pairs and finds the 17th full" {
    var rec: Recorder(16) = .{ .sink = .{ .target = .none } };
    const roles = [_]Role{ .ui, .renderer, .termio, .reader };
    for (0..16) |i| {
        try testing.expectEqual(Outcome.new, rec.insert(0x1000 + (i / 4) * 0x10, roles[i % 4], .lock));
    }
    try testing.expectEqual(@as(usize, 16), rec.count());
    // Each again: seen, wherever it landed in the full table.
    for (0..16) |i| {
        try testing.expectEqual(Outcome.seen, rec.insert(0x1000 + (i / 4) * 0x10, roles[i % 4], .lock));
        try testing.expect(rec.contains(0x1000 + (i / 4) * 0x10, roles[i % 4]));
    }
    // A 17th distinct pair, by site or by role.
    try testing.expectEqual(Outcome.full, rec.insert(0x2000, .ui, .lock));
    try testing.expectEqual(Outcome.full, rec.insert(0x1000, .search, .lock));
    try testing.expectEqual(Outcome.full, rec.insert(0x1000, .{ .worker = "w" }, .lock));
    try testing.expect(!rec.contains(0x2000, .ui));
    try testing.expectEqual(@as(usize, 16), rec.count());
    // Recording what it holds still works when full.
    rec.record(0x1030, .reader, .lock);
    try testing.expectEqual(Outcome.seen, rec.insert(0x1000, .ui, .demand));
}

test "a pair is (site, role): another role or site is another pair, the kind is not" {
    var rec: Recorder(8) = .{ .sink = .{ .target = .none } };
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .ui, .lock));
    try testing.expectEqual(Outcome.seen, rec.insert(0x10, .ui, .try_lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .termio, .lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x11, .ui, .lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .none, .lock));
    try testing.expectEqual(@as(usize, 4), rec.count());
}

test "a worker role is matched by its name's bytes, not its pointer" {
    var rec: Recorder(8) = .{ .sink = .{ .target = .none } };
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .{ .worker = "update-check" }, .lock));
    var copy: [12]u8 = "update-check".*;
    try testing.expectEqual(Outcome.seen, rec.insert(0x10, .{ .worker = &copy }, .lock));
    try testing.expect(rec.contains(0x10, .{ .worker = &copy }));
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .{ .worker = "update-chec" }, .lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .{ .worker = "" }, .lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .ui, .lock));
    try testing.expectEqual(@as(usize, 4), rec.count());
}

test "a recorder writes each new pair to its dump once, and nothing for a pair it holds" {
    var dir = try dump.TestDir.init();
    defer dir.deinit();
    var rec: Recorder(16) = .{ .sink = .{ .target = .{ .directory = dir.path } } };
    defer rec.sink.close();
    // Nothing is opened before the first pair.
    try testing.expectEqual(@as(usize, 0), try dir.count());
    rec.record(0x7ff600001000, .ui, .lock);
    rec.record(0x7ff600001000, .ui, .lock);
    rec.record(0x7ff600002000, .{ .worker = "bell" }, .try_lock);
    rec.record(0x7ff600001000, .ui, .demand);
    rec.record(0x7ff600002000, .{ .worker = "bell" }, .try_lock);

    const text = try dir.read();
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = try dump.parseHeader(lines.next().?);
    try testing.expectEqual(dump.ProcessKind.default, header.kind);
    try testing.expectEqualStrings("0x00007ff600001000 lock ui", lines.next().?);
    try testing.expectEqualStrings("0x00007ff600002000 try_lock worker:bell", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
}

const Concurrent = struct {
    const threads = 8;
    const own = 16;
    const names = [threads][]const u8{ "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7" };

    rec: *Recorder(256),
    arrived: *std.atomic.Value(u32),

    fn shared() struct { usize, Role } {
        return .{ 0x7ff600000100, .ui };
    }

    /// Thread `t`'s `i`th pair: its own sites, and roles that vary.
    fn pair(t: usize, i: usize) struct { usize, Role } {
        const site = 0x7ff600010000 + t * 0x1000 + i * 0x10;
        return switch (i % 4) {
            0 => .{ site, .termio },
            1 => .{ site, .reader },
            2 => .{ site, .search },
            else => .{ site, .{ .worker = names[t] } },
        };
    }

    /// Records the shared pair, then its own, each more than once. A full
    /// table would panic (PN5) and end the test binary.
    fn run(self: Concurrent, t: usize) void {
        // Start together, for the most contention.
        _ = self.arrived.fetchAdd(1, .acq_rel);
        while (self.arrived.load(.acquire) < threads) std.atomic.spinLoopHint();
        for (0..3) |_| {
            const s = shared();
            self.rec.record(s[0], s[1], .lock);
        }
        for (0..2) |_| {
            for (0..own) |i| {
                const p = pair(t, i);
                self.rec.record(p[0], p[1], .lock);
            }
        }
    }
};

test "a 256-slot recorder, eight threads: one shared pair and 16 each make 129 pairs, each in the dump once" {
    var dir = try dump.TestDir.init();
    defer dir.deinit();
    var rec: Recorder(256) = .{ .sink = .{ .target = .{ .directory = dir.path } } };
    defer rec.sink.close();
    var arrived: std.atomic.Value(u32) = .init(0);
    const ctx: Concurrent = .{ .rec = &rec, .arrived = &arrived };

    var threads: [Concurrent.threads]std.Thread = undefined;
    for (&threads, 0..) |*thread, t| thread.* = try std.Thread.spawn(.{}, Concurrent.run, .{ ctx, t });
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(usize, 1 + Concurrent.threads * Concurrent.own), rec.count());
    try testing.expectEqual(@as(usize, 129), rec.count());
    const s = Concurrent.shared();
    try testing.expect(rec.contains(s[0], s[1]));

    // The dump: its header, then each pair exactly once.
    const text = try dir.read();
    defer testing.allocator.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = try dump.parseHeader(lines.next().?);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        _ = try dump.parsePair(line);
        const entry = try seen.getOrPut(testing.allocator, line);
        try testing.expect(!entry.found_existing);
        n += 1;
    }
    try testing.expectEqual(@as(?[]const u8, null), lines.next());
    try testing.expectEqual(@as(usize, 129), n);

    var buf: [dump.pair_line_max]u8 = undefined;
    try testing.expect(seen.contains(std.mem.trimRight(u8, dump.formatPair(&buf, s[0], s[1], .lock), "\n")));
    for (0..Concurrent.threads) |t| {
        for (0..Concurrent.own) |i| {
            const p = Concurrent.pair(t, i);
            try testing.expect(seen.contains(std.mem.trimRight(u8, dump.formatPair(&buf, p[0], p[1], .lock), "\n")));
        }
    }
}
