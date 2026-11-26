//! `std.once` as Zig 0.15.2 had it, which Zig 0.17 removed: `call` runs `f`
//! the first time any thread calls it, and every call returns only after `f`
//! has returned. 0.15.2's took a `std.Thread.Mutex` on its slow path; this one
//! is a three-state atomic, so it needs no `Io` from its caller: the first
//! caller runs `f`, and a caller that arrives while `f` runs waits on the
//! state's address (std's `futexWait`) until `f` is done and the first caller
//! wakes every waiter. On Windows 0.17.1's futex parks the waiting thread
//! itself (`Io.Threaded`'s `parking_futex`, through
//! `NtWaitForAlertByThreadId` and `NtAlertThreadByThreadId`), not through
//! WaitOnAddress. The callers are the portable-root
//! cache, the pty resolver (a LoadLibrary), the search icon font and the hint
//! scheme regex.
//!
//! Memory orders: the done check is an acquire load (on the fast path and in
//! the waiters' loop), and the store that marks `f` done is a release, so
//! everything `f` wrote happens before any `call` that sees it done returns.
//! The claim of the first call is an acquire compare-exchange; a losing claim
//! orders nothing and goes on to the acquire loads.
//!
//! Re-entry: 0.15.2's Debug mutex panicked "Deadlock detected" when `f` called
//! back into its own once. In builds with runtime safety this one records the
//! thread that runs `f` and panics the same way; without it a re-entering `f`
//! waits forever, as 0.15.2's release builds did. 1B.6 re-checks this with the
//! other sync primitives (PLAN decision 19's roles).
const std = @import("std");
const builtin = @import("builtin");

pub fn once(comptime f: fn () void) Once(f) {
    return .{};
}

pub fn Once(comptime f: fn () void) type {
    return struct {
        state: std.atomic.Value(u32) = .init(idle),
        /// The thread running `f`, in builds with runtime safety.
        runner: if (std.debug.runtime_safety) std.atomic.Value(std.Thread.Id) else void =
            if (std.debug.runtime_safety) .init(0) else {},
        /// Test builds only: how many times a waiter went round its wait
        /// loop. A parked waiter goes round once per wake; a busy-yielding
        /// one would go round thousands of times while `f` runs (council F7).
        wait_loops: if (builtin.is_test) std.atomic.Value(u32) else void =
            if (builtin.is_test) .init(0) else {},

        const Self = @This();
        const idle: u32 = 0;
        const running: u32 = 1;
        const done: u32 = 2;

        pub fn call(self: *Self) void {
            if (self.state.load(.acquire) == done) return;
            self.callSlow();
        }

        fn callSlow(self: *Self) void {
            @branchHint(.cold);
            if (self.state.cmpxchgStrong(idle, running, .acquire, .acquire) == null) {
                if (std.debug.runtime_safety) self.runner.store(std.Thread.getCurrentId(), .monotonic);
                f();
                self.state.store(done, .release);
                waitIo().futexWake(u32, &self.state.raw, std.math.maxInt(u32));
                return;
            }
            if (self.reentered()) @panic("Deadlock detected: a once's function called its own once");
            while (true) {
                const now = self.state.load(.acquire);
                if (now == done) return;
                if (builtin.is_test) _ = self.wait_loops.fetchAdd(1, .monotonic);
                waitIo().futexWaitUncancelable(u32, &self.state.raw, now);
            }
        }

        /// Whether `f` is running now, on any thread. For a test's reset of a
        /// once it means to run again, which must not race a running `f`.
        pub fn isRunning(self: *const Self) bool {
            return self.state.load(.acquire) == running;
        }

        /// The calling thread is the one running `f` (runtime safety only).
        fn reentered(self: *const Self) bool {
            if (!std.debug.runtime_safety) return false;
            return self.state.load(.acquire) == running and
                self.runner.load(.monotonic) == std.Thread.getCurrentId();
        }
    };
}

/// The `Io` of the waits and wakes: std's single-threaded one, as
/// `sync/state_mutex.zig`'s `innerIo` (QR-16). Its futex is process-wide, so
/// a wake on one thread reaches a waiter on any other: on Windows the waiters
/// are parked threads in `parking_futex`'s buckets, found by the address.
inline fn waitIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
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

test "once: waiters sleep on the state until the first call wakes them" {
    const Slow = struct {
        var release: std.atomic.Value(u32) = .init(0);
        var entered: std.atomic.Value(bool) = .init(false);
        var returned: std.atomic.Value(u32) = .init(0);
        var flag = once(init);

        fn init() void {
            entered.store(true, .release);
            // Holds the first call until the test lets it go.
            while (release.load(.acquire) == 0) std.Thread.yield() catch {};
        }

        fn worker() void {
            flag.call();
            _ = returned.fetchAdd(1, .monotonic);
        }
    };

    var first = try std.Thread.spawn(.{}, Slow.worker, .{});
    while (!Slow.entered.load(.acquire)) std.Thread.yield() catch {};
    var waiters: [4]std.Thread = undefined;
    for (&waiters) |*t| t.* = try std.Thread.spawn(.{}, Slow.worker, .{});
    // While `f` runs, no caller returns, and the waiters sleep: in 50 ms a
    // parked waiter goes round its loop about once (each enters it, and a
    // spurious wake may add a turn), where a waiter that yielded or spun
    // would go round thousands of times (council F7).
    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
    try std.testing.expectEqual(@as(u32, 0), Slow.returned.load(.monotonic));
    try std.testing.expectEqual(Slow.flag.state.load(.acquire), 1);
    const loops = Slow.flag.wait_loops.load(.monotonic);
    try std.testing.expect(loops <= waiters.len * 8);
    Slow.release.store(1, .release);
    first.join();
    for (waiters) |t| t.join();
    try std.testing.expectEqual(@as(u32, waiters.len + 1), Slow.returned.load(.monotonic));
}

test "once: a function that calls its own once panics in safe builds" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    // In an isolated child of the test exe (`sync/isolated.zig`), since a test
    // exe cannot survive its own panic: the re-entering `call` panics there,
    // and without the check it would wait for itself until the parent's
    // deadline, which fails this test too (council F7).
    const isolated = @import("../sync/isolated.zig");
    if (isolated.inChild()) {
        const Inner = struct {
            var flag = once(init);

            fn init() void {
                flag.call();
            }
        };
        Inner.flag.call();
        return;
    }
    try isolated.expectPanic(@src(), "Deadlock detected: a once's function called its own once");
}
