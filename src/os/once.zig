//! `std.once` as Zig 0.15.2 had it, which Zig 0.17 removed: `call` runs `f`
//! the first time any thread calls it, and every call returns only after `f`
//! has returned. 0.15.2's took a `std.Thread.Mutex` on its slow path; this one
//! is a three-state atomic, so it needs no `Io`: the first caller runs `f`, and
//! a caller that arrives while `f` runs yields until it is done. The callers
//! (the portable-root cache, the pty resolver, the search icon font and the
//! hint scheme regex) run short initializers, so a waiter yields only briefly.
//!
//! Memory orders: the done check is an acquire load (on the fast path and in
//! the waiters' loop), and the store that marks `f` done is a release, so
//! everything `f` wrote happens before any `call` that sees it done returns.
//! The claim of the first call is an acquire compare-exchange; a losing claim
//! orders nothing and goes on to the acquire loads. 1B.6 re-checks this with
//! the other sync primitives (PLAN decision 19's roles).
const std = @import("std");

pub fn once(comptime f: fn () void) Once(f) {
    return .{};
}

pub fn Once(comptime f: fn () void) type {
    return struct {
        state: std.atomic.Value(u8) = .init(idle),

        const Self = @This();
        const idle: u8 = 0;
        const running: u8 = 1;
        const done: u8 = 2;

        pub fn call(self: *Self) void {
            if (self.state.load(.acquire) == done) return;
            self.callSlow();
        }

        fn callSlow(self: *Self) void {
            @branchHint(.cold);
            if (self.state.cmpxchgStrong(idle, running, .acquire, .acquire) == null) {
                f();
                self.state.store(done, .release);
                return;
            }
            while (self.state.load(.acquire) != done) std.Thread.yield() catch {};
        }
    };
}

test "once runs its function once, however many threads call it" {
    const Counter = struct {
        var runs: std.atomic.Value(u32) = .init(0);
        var seen_done: std.atomic.Value(u32) = .init(0);
        var flag = once(incr);

        fn incr() void {
            // Long enough that the other threads arrive while it runs.
            for (0..1000) |_| std.Thread.yield() catch {};
            _ = runs.fetchAdd(1, .monotonic);
        }

        fn worker() void {
            flag.call();
            // `call` returned only after `incr` returned.
            if (runs.load(.monotonic) == 1) _ = seen_done.fetchAdd(1, .monotonic);
        }
    };

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Counter.worker, .{});
    for (threads) |t| t.join();
    Counter.flag.call();
    try std.testing.expectEqual(@as(u32, 1), Counter.runs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, threads.len), Counter.seen_done.load(.monotonic));
}

test "once: threads released together race the first call, and each sees what it wrote" {
    const Race = struct {
        var go: std.atomic.Value(bool) = .init(false);
        var ready: std.atomic.Value(u32) = .init(0);
        var runs: std.atomic.Value(u32) = .init(0);
        // Written by the one `init` with plain stores: a caller that returns
        // from `call` must see them (the release store and acquire loads).
        var table: [64]u32 = undefined;
        var mismatches: std.atomic.Value(u32) = .init(0);
        var flag = once(init);

        fn init() void {
            _ = runs.fetchAdd(1, .monotonic);
            for (&table, 0..) |*slot, i| slot.* = @intCast(i * 7 + 1);
        }

        fn worker() void {
            _ = ready.fetchAdd(1, .release);
            // Every thread spins at the start line, so all of them reach the
            // first call together rather than one after another.
            while (!go.load(.acquire)) std.atomic.spinLoopHint();
            flag.call();
            for (table, 0..) |value, i| {
                if (value != i * 7 + 1) _ = mismatches.fetchAdd(1, .monotonic);
            }
        }
    };

    var threads: [16]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Race.worker, .{});
    while (Race.ready.load(.acquire) != threads.len) std.Thread.yield() catch {};
    Race.go.store(true, .release);
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 1), Race.runs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), Race.mismatches.load(.monotonic));
}
