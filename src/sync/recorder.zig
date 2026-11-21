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
//! compare-and-swap, writes the pair and publishes it (`.ready`), appends it
//! to the dump and marks it `.written`; a thread that finds a slot being
//! written waits for it, and one that finds its own pair waits until it is
//! in the dump before it goes on, so no thread acts on a pair (and perhaps
//! panics) that the dump might not hold. A worker role matches by its
//! name's bytes. The capacity is a comptime parameter: the process's is
//! `process_capacity`, and tests build small ones (acceptance test 12). A
//! full table is PN5, after the pair that found it full is written to the
//! dump.
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
const Acquire = state_mutex.Acquire;

/// The process recorder's capacity: the fork head has 96 production gate
/// sites and 2 test-code sites, each seen in at most 3 roles (§19.3).
pub const process_capacity = 4096;

/// The process's recorder, which `StateMutex` fills; its dump goes to the
/// directory `NOCTTY_THREAD_ROLE_DUMP` names.
pub var process: Recorder(process_capacity) = .{
    .slots = &process_slots,
    .sink = .{ .target = .{ .environment = dump.env_var_w } },
};

/// The process recorder's table, a variable of its own: every byte of it is
/// zero (`Slot` has no padding), so it is zero-initialised data and takes no
/// room in the image, where the sink's pointer would put a table beside it
/// into initialised data.
var process_slots: [process_capacity]Slot = @splat(.{});

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

        /// The table, which the recorder does not own: the process's is
        /// `process_slots`, and a test's is its own `empty` copy.
        slots: *Slots,
        /// Where new pairs go.
        sink: dump.Dump,

        pub const slot_count = capacity;
        pub const Slots = [capacity]Slot;
        /// An empty table, all zero bytes.
        pub const empty: Slots = @splat(.{});

        /// Records a pair: a new one goes to the dump, and a full table
        /// panics (PN5) once the pair is in the dump.
        pub fn record(self: *Self, site: usize, role: Role, acquire: Acquire) void {
            switch (self.claim(site, role, acquire)) {
                .seen => {},
                .new => |slot| {
                    self.sink.append(site, role, acquire);
                    slot.state.store(.written, .release);
                },
                .full => {
                    self.sink.append(site, role, acquire);
                    panicFull(capacity);
                },
            }
        }

        /// The table alone, with no dump: claims a slot for a pair it does
        /// not hold yet, and marks it written at once. Safe from any number
        /// of threads.
        pub fn insert(self: *Self, site: usize, role: Role, acquire: Acquire) Outcome {
            return switch (self.claim(site, role, acquire)) {
                .new => |slot| new: {
                    slot.state.store(.written, .release);
                    break :new .new;
                },
                .seen => .seen,
                .full => .full,
            };
        }

        const Claim = union(Outcome) {
            /// The slot this thread published, `.ready`: its caller marks
            /// it `.written` once the pair is in the dump.
            new: *Slot,
            seen,
            full,
        };

        /// Claims and publishes a slot for a pair the table does not hold;
        /// for one it holds, returns once that pair is written.
        fn claim(self: *Self, site: usize, role: Role, acquire: Acquire) Claim {
            const start: usize = @intCast(hash(site, role) % capacity);
            for (0..capacity) |i| {
                const slot = &self.slots[(start + i) % capacity];
                var state = slot.state.load(.acquire);
                if (state == .empty) {
                    state = slot.state.cmpxchgStrong(.empty, .writing, .acquire, .acquire) orelse {
                        slot.site = site;
                        slot.acquire = acquire;
                        slot.tag = @intFromEnum(std.meta.activeTag(role));
                        if (role == .worker) {
                            slot.name_ptr = role.worker.ptr;
                            slot.name_len = role.worker.len;
                        }
                        slot.state.store(.ready, .release);
                        return .{ .new = slot };
                    };
                }
                // Another thread claimed it and is writing its pair: a few
                // stores, unless that thread is preempted.
                state = waitWhile(slot, state, .writing);
                if (slot.matches(site, role)) {
                    // Its claimer is appending it to the dump (RQ12: the
                    // dump keeps every pair a thread saw, and this thread
                    // may panic next). One write, the first time only.
                    _ = waitWhile(slot, state, .ready);
                    return .seen;
                }
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
                    .ready, .written => if (slot.matches(site, role)) return true,
                }
            }
            return false;
        }

        /// The pairs the table holds (published ones).
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |*slot| {
                switch (slot.state.load(.acquire)) {
                    .empty, .writing => {},
                    .ready, .written => n += 1,
                }
            }
            return n;
        }
    };
}

/// Waits while `slot` is in `busy`, from the state `from` read last.
fn waitWhile(slot: *const Slot, from: Slot.State, busy: Slot.State) Slot.State {
    var state = from;
    var spins: u32 = 0;
    while (state == busy) : (state = slot.state.load(.acquire)) {
        spins +%= 1;
        if (spins % 64 == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
    }
    return state;
}

/// A table slot. Its layout has no padding (`reserved` fills it), so an
/// empty slot, every field zero, is all zero bytes, and a table of them is
/// zero-initialised data.
const Slot = extern struct {
    site: usize = 0,
    /// A worker's name; set only for `.worker`.
    name_ptr: ?[*]const u8 = null,
    name_len: usize = 0,
    state: std.atomic.Value(State) = .init(.empty),
    acquire: Acquire = .lock,
    /// The role's tag, `@intFromEnum(std.meta.activeTag(role))`.
    tag: u8 = 0,
    reserved: [@sizeOf(usize) - 3]u8 = @splat(0),

    /// `.ready`: published, its fields readable; `.written`: in the dump.
    const State = enum(u8) { empty, writing, ready, written };

    comptime {
        var fields: usize = 0;
        for (@typeInfo(Slot).@"struct".fields) |field| fields += @sizeOf(field.type);
        if (fields != @sizeOf(Slot)) @compileError("a recorder slot has padding");
    }

    /// Whether this published slot holds the pair.
    fn matches(self: *const Slot, site: usize, role: Role) bool {
        if (self.site != site or self.tag != @intFromEnum(std.meta.activeTag(role))) return false;
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
    try testing.expectEqual(&process_slots, process.slots);
    try testing.expectEqualSlices(u16, dump.env_var_w, process.sink.target.environment);
    try testing.expectEqualStrings("NOCTTY_THREAD_ROLE_DUMP", dump.env_var);
    // An empty slot is all zero bytes: Slot has no padding (its comptime
    // check), so these are its fields' defaults.
    const empty: Slot = .{};
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&empty), 0));
}

test "a 16-slot recorder holds 16 distinct pairs and finds the 17th full" {
    var slots = Recorder(16).empty;
    var rec: Recorder(16) = .{ .slots = &slots, .sink = .{ .target = .none } };
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
    var slots = Recorder(8).empty;
    var rec: Recorder(8) = .{ .slots = &slots, .sink = .{ .target = .none } };
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .ui, .lock));
    try testing.expectEqual(Outcome.seen, rec.insert(0x10, .ui, .try_lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .termio, .lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x11, .ui, .lock));
    try testing.expectEqual(Outcome.new, rec.insert(0x10, .none, .lock));
    try testing.expectEqual(@as(usize, 4), rec.count());
}

test "a worker role is matched by its name's bytes, not its pointer" {
    var slots = Recorder(8).empty;
    var rec: Recorder(8) = .{ .slots = &slots, .sink = .{ .target = .none } };
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
    var slots = Recorder(16).empty;
    var rec: Recorder(16) = .{ .slots = &slots, .sink = .{ .target = .{ .directory = dir.path } } };
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

test "a thread that finds its pair published waits until the pair is written" {
    var slots = Recorder(8).empty;
    var rec: Recorder(8) = .{ .slots = &slots, .sink = .{ .target = .none } };
    // This thread published the pair and has not written it yet.
    const slot = switch (rec.claim(0x10, .ui, .lock)) {
        .new => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Slot.State.ready, slot.state.load(.acquire));

    const Other = struct {
        rec: *Recorder(8),
        outcome: Outcome = .full,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.outcome = self.rec.insert(0x10, .ui, .try_lock);
            self.done.store(true, .release);
        }
    };
    var other: Other = .{ .rec = &rec };
    const thread = try std.Thread.spawn(.{}, Other.run, .{&other});
    // It waits for the write; a pair it does not hold would not wait.
    std.Thread.sleep(20 * std.time.ns_per_ms);
    try testing.expect(!other.done.load(.acquire));
    try testing.expectEqual(Outcome.new, rec.insert(0x20, .ui, .lock));
    slot.state.store(.written, .release);
    thread.join();
    try testing.expect(other.done.load(.acquire));
    try testing.expectEqual(Outcome.seen, other.outcome);
    try testing.expectEqual(@as(usize, 2), rec.count());
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
    var slots = Recorder(256).empty;
    var rec: Recorder(256) = .{ .slots = &slots, .sink = .{ .target = .{ .directory = dir.path } } };
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
