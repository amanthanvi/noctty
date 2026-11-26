//! `std.once` as Zig 0.15.2 had it, which Zig 0.17 removed: `call` runs `f`
//! the first time any thread calls it, and every call returns only after `f`
//! has returned. 0.15.2's took a `std.Thread.Mutex` on its slow path; this one
//! is a three-state atomic, so it needs no `Io`: the first caller runs `f`, and
//! a caller that arrives while `f` runs yields until it is done. The callers
//! (the portable-root cache, the pty resolver, the search icon font and the
//! hint scheme regex) run short initializers, so a waiter yields only briefly.
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
