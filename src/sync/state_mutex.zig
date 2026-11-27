//! `StateMutex`, the renderer-state mutex with the runtime thread-role layer
//! (PLAN.md §2.7). It has `std.Io.Mutex`'s `lockUncancelable`, `tryLock` and
//! `unlock` without their `Io` (the wrapper supplies its own: `innerIo`), the
//! fork's older `lock`, a demand acquire (`demand`, which the renderer reaches
//! through `State.lockDemand`) and `assertHeld`.
//!
//! The call sites' one spelling (1B.6, carry-over B6 and A7) is upstream's:
//! `lockUncancelable()` and `unlock()`. Upstream writes
//! `lockUncancelable(global.io())` and `unlock(global.io())` on the plain
//! mutex, so a fork line differs from upstream's by the argument alone, which
//! a forward merge drops mechanically. `lock` stays for the wrapper's own
//! tests of PN1 and PN3 (acceptance tests 1 and 6), and a build that is not a
//! test refuses it at compile time. The thread gate reads both names as one
//! (`thread_gate15.py` `signature_of`), so the spelling moves no table row.
//!
//! With the
//! layer on it keeps its owner, records each (acquiring function, role) pair
//! and panics on the policies below; with it off it is the same struct around
//! the plain mutex, every method an inline forward, with no owner, no roles
//! and no recorder, and nothing that reaches Win32 (lib-vt builds for wasm32).
//!
//! The panics, wherever the layer is on:
//! - PN1: `lock`, `lockUncancelable` or `demand` by the thread that holds it,
//!   checked before the inner lock, which would wait for itself: 0.17.1's
//!   `std.Io.Mutex` has no re-entry check in any mode.
//! - PN2: `assertHeld` or `unlock` on a thread that does not hold it.
//! - PN3: a plain `lock` or `lockUncancelable` from `.renderer` (`demand`
//!   and `tryLock` are allowed).
//! - PN4: any acquisition from a thread with no role.
//! A holder's `tryLock` is no panic: it returns false and the holder keeps
//! the mutex.
//!
//! Site identity (§19.1): each acquiring method is an `inline fn` whose body
//! is one `@call(.never_tail, ...)` into a `noinline` implementation that
//! takes `@returnAddress()`. The public method inlines into the function that
//! acquires, and `.never_tail` keeps the call a call even where it is that
//! function's last act (a `defer` relock), so the address recorded is inside
//! the acquiring function. `@src()` would name this file.

const std = @import("std");
const builtin = @import("builtin");
const thread_role = @import("thread_role.zig");

const Layer = thread_role.Layer;
const Role = thread_role.Role;

/// This build's renderer-state mutex.
pub const StateMutex = StateMutexOf(thread_role.layer);

/// Which acquire a site used.
pub const Acquire = enum(u8) {
    lock,
    lock_uncancelable,
    demand,
    try_lock,

    fn method(self: Acquire) []const u8 {
        return switch (self) {
            .lock => "lock",
            .lock_uncancelable => "lockUncancelable",
            .demand => "the demand acquire",
            .try_lock => "tryLock",
        };
    }
};

/// The mutex in one form of the layer. Code uses `StateMutex`, this build's
/// form; tests name a form to check both in one build.
pub fn StateMutexOf(comptime form: Layer) type {
    return struct {
        const Self = @This();
        const on = form == .on;
        const Roles = thread_role.Roles(.on);
        const ThreadId = std.Thread.Id;
        const Owner = if (on) std.atomic.Value(ThreadId) else void;

        /// No thread holds it. No Windows thread has ID 0.
        const no_owner: ThreadId = 0;

        inner: std.Io.Mutex = .init,

        /// The holding thread's ID, or `no_owner`. Only the holder stores its
        /// own ID, and only while it holds the inner mutex, so a thread that
        /// reads its own ID here holds the mutex, whatever the ordering of
        /// other threads' stores.
        owner: Owner = if (on) .init(no_owner) else {},

        /// The fork's older name for `lockUncancelable`, for the wrapper's own
        /// tests only: call sites spell `lockUncancelable()` (B6).
        pub inline fn lock(self: *Self) void {
            if (comptime !builtin.is_test) @compileError("StateMutex: call sites spell lockUncancelable(), not lock() (1B.6, B6)");
            if (on) @call(.never_tail, acquire, .{ self, Acquire.lock }) else self.inner.lockUncancelable(innerIo());
        }

        pub inline fn lockUncancelable(self: *Self) void {
            if (on) @call(.never_tail, acquire, .{ self, Acquire.lock_uncancelable }) else self.inner.lockUncancelable(innerIo());
        }

        /// The demand acquire: the renderer's way in (PN3 exempts it).
        pub inline fn demand(self: *Self) void {
            if (on) @call(.never_tail, acquire, .{ self, Acquire.demand }) else self.inner.lockUncancelable(innerIo());
        }

        /// False when another thread holds it, or when the caller does; the
        /// holder keeps it then.
        pub inline fn tryLock(self: *Self) bool {
            return if (on) @call(.never_tail, tryAcquire, .{self}) else self.inner.tryLock();
        }

        /// PN2 with the layer on: only the holder unlocks, checked before
        /// the owner is cleared or the inner lock released.
        pub inline fn unlock(self: *Self) void {
            if (on) {
                if (self.owner.load(.monotonic) != std.Thread.getCurrentId()) {
                    panicUnlockNotHeld(Roles.current());
                }
                self.owner.store(no_owner, .monotonic);
            }
            self.inner.unlock(innerIo());
        }

        /// PN2: for a function documented "requires the mutex held". A no-op
        /// with the layer off.
        pub inline fn assertHeld(self: *const Self) void {
            if (on and self.owner.load(.monotonic) != std.Thread.getCurrentId()) {
                panicNotHeld(Roles.current());
            }
        }

        noinline fn acquire(self: *Self, kind: Acquire) void {
            const site = @returnAddress();
            const role = Roles.current();
            record(site, role, kind);
            const me = std.Thread.getCurrentId();
            if (self.owner.load(.monotonic) == me) panicReentry(kind, role);
            if (role == .none) panicNoRole(kind);
            if (role == .renderer and kind != .demand) panicRendererPlain(kind);
            self.inner.lockUncancelable(innerIo());
            self.owner.store(me, .monotonic);
        }

        noinline fn tryAcquire(self: *Self) bool {
            const site = @returnAddress();
            const role = Roles.current();
            record(site, role, .try_lock);
            if (role == .none) panicNoRole(.try_lock);
            const me = std.Thread.getCurrentId();
            if (self.owner.load(.monotonic) == me) return false;
            if (!self.inner.tryLock()) return false;
            self.owner.store(me, .monotonic);
            return true;
        }
    };
}

/// The `Io` of the inner mutex's waits and wakes, settled in 1B.6 (B6).
/// Zig 0.17's `std.Io.Mutex` takes one for its futex; `lockUncancelable` and
/// `unlock` reach only `futexWaitUncancelable` and `futexWake`, which
/// `std.Io.Threaded` runs on the process-wide futex whatever the instance,
/// branching only on `builtin.single_threaded` (0.17.1
/// `lib/std/Io/Threaded.zig` `futexWaitUncancelable`, `futexWake`; the lead's
/// QR-16). So the wrapper keeps its `Io`-free API, with no cancelation point,
/// and works on every thread that takes it: the UI, renderer,
/// termio, reader and search threads, which no `Io` started, and an `Io`
/// task's thread, inline or a pool worker (decision 19). The owner and the
/// role are the OS thread's, which holds for `Io.Threaded`, whose tasks never
/// leave the thread they start on; an `Io` that moved a task between threads
/// would break both. `std.Io.Mutex` checks no owner in any mode on 0.17.1
/// (its `unlock` asserts only that the mutex is locked), so PN1 and PN2 are
/// the only re-entry and wrong-thread checks there are.
inline fn innerIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The recorder's seam: each acquisition's site (the address its acquiring
/// function resumes at after the call) and the thread's role, taken before
/// any policy or the inner lock, so a process that then panics keeps the
/// pair. The recorder (PLAN.md §19.3) fills it; until then it records nothing.
inline fn record(site: usize, role: Role, kind: Acquire) void {
    // Imported whatever the layer, so the recorder's and the dump's tests
    // build wherever this hook does; the process recorder, its dump and
    // their Win32 calls are reached only with the layer on (§2.7: a build
    // with the layer off has no recorder).
    const recorder = @import("recorder.zig");
    if (comptime thread_role.layer == .on) recorder.process.record(site, role, kind);
}

fn panicReentry(kind: Acquire, role: Role) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN1 a blocking re-entry: {s} of the renderer-state " ++
            "mutex by the thread that holds it (role {f})",
        .{ kind.method(), role },
    );
}

fn panicNotHeld(role: Role) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN2 assertHeld() on a thread that does not hold the " ++
            "renderer-state mutex (role {f})",
        .{role},
    );
}

fn panicUnlockNotHeld(role: Role) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN2 unlock() on a thread that does not hold the " ++
            "renderer-state mutex (role {f})",
        .{role},
    );
}

fn panicRendererPlain(kind: Acquire) noreturn {
    @branchHint(.cold);
    std.debug.panic(
        "thread-role layer: PN3 a plain {s} of the renderer-state mutex from " ++
            "renderer; the renderer acquires through State.lockDemand or tryLock",
        .{kind.method()},
    );
}

fn panicNoRole(kind: Acquire) noreturn {
    @branchHint(.cold);
    const fix = if (@import("builtin").is_test)
        "a test enters the role it simulates first: " ++
            "`const scope = thread_role.fixture(.<role>); defer scope.exit();`"
    else
        "its thread entry enters its role first: " ++
            "`const scope = thread_role.enter(.<role>); defer scope.exit();`";
    std.debug.panic(
        "thread-role layer: PN4 {s} of the renderer-state mutex from a thread " ++
            "with no role; " ++ fix,
        .{kind.method()},
    );
}

// These tests check the on form in every build. Where the layer is on, their
// acquisitions reach the process recorder like any other, so each has a test
// row in ci/lock-inventory-threads.tsv with the role it simulates (PLAN.md
// §2.7 RQ8: tests have no exemption).
const testing = std.testing;
const Checked = StateMutexOf(.on);
const OnRoles = thread_role.Roles(.on);

test {
    _ = thread_role;
}

fn expectOwner(m: *const Checked, owner: std.Thread.Id) !void {
    try testing.expectEqual(owner, m.owner.load(.monotonic));
}

test "a holder's tryLock returns false and keeps the mutex" {
    const scope = OnRoles.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var m: Checked = .{};
    m.lock();
    try expectOwner(&m, me);
    try testing.expect(!m.tryLock());
    try expectOwner(&m, me);
    m.assertHeld();
    m.unlock();
    try expectOwner(&m, Checked.no_owner);

    // Its own unlock released the inner mutex too.
    try testing.expect(m.tryLock());
    try expectOwner(&m, me);
    try testing.expect(!m.tryLock());
    m.assertHeld();
    m.unlock();
    try expectOwner(&m, Checked.no_owner);
}

test "each acquire sets the owner and unlock clears it" {
    const scope = OnRoles.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var m: Checked = .{};
    try expectOwner(&m, Checked.no_owner);
    m.lock();
    try expectOwner(&m, me);
    m.unlock();
    try expectOwner(&m, Checked.no_owner);
    m.lockUncancelable();
    try expectOwner(&m, me);
    m.unlock();
    try expectOwner(&m, Checked.no_owner);
    m.demand();
    try expectOwner(&m, me);
    m.assertHeld();
    m.unlock();
    try expectOwner(&m, Checked.no_owner);
}

test "another thread's tryLock fails while the holder holds it" {
    // Nested in its test block, so it is test code with this test's row.
    const OtherThreadTry = struct {
        m: *Checked,
        got: bool = true,
        owner_seen: std.Thread.Id = 0,

        fn tryFromOtherThread(self: *@This()) void {
            const scope = OnRoles.enter(.termio);
            defer scope.exit();
            self.got = self.m.tryLock();
            if (self.got) self.m.unlock();
            self.owner_seen = self.m.owner.load(.monotonic);
        }
    };

    const scope = OnRoles.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var m: Checked = .{};
    m.lock();
    var other: OtherThreadTry = .{ .m = &m };
    const thread = try std.Thread.spawn(.{}, OtherThreadTry.tryFromOtherThread, .{&other});
    thread.join();
    try testing.expect(!other.got);
    try testing.expectEqual(me, other.owner_seen);
    try expectOwner(&m, me);
    m.assertHeld();
    m.unlock();
}

test "the off form is the plain mutex with the same API" {
    const Plain = StateMutexOf(.off);
    try testing.expectEqual(@sizeOf(std.Io.Mutex), @sizeOf(Plain));
    try testing.expectEqual(void, @FieldType(Plain, "owner"));

    var m: Plain = .{};
    m.lock();
    m.assertHeld();
    m.unlock();
    m.lockUncancelable();
    m.unlock();
    m.demand();
    m.unlock();
    try testing.expect(m.tryLock());
    m.unlock();
}

test "this build's StateMutex is the form thread_role.layer names" {
    try testing.expectEqual(StateMutexOf(thread_role.layer), StateMutex);
}

test "a holder's tryLock keeps the mutex, and its own unlock lets a waiting thread's lock in (acceptance test 11)" {
    // This build's StateMutex, whose pairs reach the process recorder as the
    // app's do, with a thread that blocks in lock while the holder tries.
    if (thread_role.layer == .off) return error.SkipZigTest;
    const Waiter = struct {
        m: *StateMutex,
        owner_seen: std.Thread.Id = 0,

        /// Another thread's blocking lock, which gets the mutex only once the
        /// holder's own unlock releases it.
        fn lockAfterHolderRelease(self: *@This()) void {
            const scope = thread_role.enter(.termio);
            defer scope.exit();
            self.m.lock();
            defer self.m.unlock();
            self.m.assertHeld();
            self.owner_seen = self.m.owner.load(.monotonic);
        }
    };

    const scope = thread_role.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var m: StateMutex = .{};
    m.lock();
    var waiter: Waiter = .{ .m = &m };
    const thread = try std.Thread.spawn(.{}, Waiter.lockAfterHolderRelease, .{&waiter});
    // The holder's tryLock is no PN1: it returns false and the holder keeps
    // the mutex, whether the other thread has reached its lock yet or not.
    try testing.expect(!m.tryLock());
    try testing.expectEqual(me, m.owner.load(.monotonic));
    m.assertHeld();
    m.unlock();
    thread.join();
    try testing.expect(waiter.owner_seen != 0);
    try testing.expect(waiter.owner_seen != me);
    try testing.expectEqual(StateMutex.no_owner, m.owner.load(.monotonic));
}

test "isolated: an unlock by a thread that does not hold the mutex panics with PN2" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    const isolated = @import("isolated.zig");
    const Other = struct {
        /// A thread of another role that unlocks the mutex the test thread
        /// holds. Zig 0.17.1's `std.Io.Mutex` checks no owner in any mode,
        /// so the layer's check is the only one.
        fn unlockFromOtherThread(m: *StateMutex) void {
            const scope = thread_role.enter(.termio);
            defer scope.exit();
            m.unlock();
        }
    };
    if (isolated.inChild()) {
        const scope = thread_role.fixture(.ui);
        defer scope.exit();
        var m: StateMutex = .{};
        m.lock();
        const thread = try std.Thread.spawn(.{}, Other.unlockFromOtherThread, .{&m});
        thread.join();
        m.unlock();
        return;
    }
    try isolated.expectPanic(@src(), "thread-role layer: PN2 unlock() on a thread that does not hold the " ++
        "renderer-state mutex (role termio)");
}
