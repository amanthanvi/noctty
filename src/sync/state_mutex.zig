//! `StateMutex`, the renderer-state mutex with the runtime thread-role layer
//! (PLAN.md §2.7). It has `std.Thread.Mutex`'s methods (`lock`, `tryLock`,
//! `unlock`), 0.17's `lockUncancelable`, a demand acquire (`demand`, which the
//! renderer reaches through `State.lockDemand`) and `assertHeld`. With the
//! layer on it keeps its owner, records each (acquiring function, role) pair
//! and panics on the policies below; with it off it is the same struct around
//! the plain mutex, every method an inline forward, with no owner, no roles
//! and no recorder, and nothing that reaches Win32 (lib-vt builds for wasm32).
//!
//! The panics (`thread_role.armed` holds PN3 and PN4 back while 1A.2 gives
//! threads their roles):
//! - PN1: `lock`, `lockUncancelable` or `demand` by the thread that holds it,
//!   checked before the inner lock, so this text wins over Zig's own
//!   "Deadlock detected".
//! - PN2: `assertHeld` on a thread that does not hold it.
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

        inner: std.Thread.Mutex = .{},

        /// The holding thread's ID, or `no_owner`. Only the holder stores its
        /// own ID, and only while it holds the inner mutex, so a thread that
        /// reads its own ID here holds the mutex, whatever the ordering of
        /// other threads' stores.
        owner: Owner = if (on) .init(no_owner) else {},

        pub inline fn lock(self: *Self) void {
            if (on) @call(.never_tail, acquire, .{ self, Acquire.lock }) else self.inner.lock();
        }

        pub inline fn lockUncancelable(self: *Self) void {
            if (on) @call(.never_tail, acquire, .{ self, Acquire.lock_uncancelable }) else self.inner.lock();
        }

        /// The demand acquire: the renderer's way in (PN3 exempts it).
        pub inline fn demand(self: *Self) void {
            if (on) @call(.never_tail, acquire, .{ self, Acquire.demand }) else self.inner.lock();
        }

        /// False when another thread holds it, or when the caller does; the
        /// holder keeps it then.
        pub inline fn tryLock(self: *Self) bool {
            return if (on) @call(.never_tail, tryAcquire, .{self}) else self.inner.tryLock();
        }

        pub inline fn unlock(self: *Self) void {
            if (on) {
                std.debug.assert(self.owner.load(.monotonic) == std.Thread.getCurrentId());
                self.owner.store(no_owner, .monotonic);
            }
            self.inner.unlock();
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
            if (thread_role.armed) {
                if (role == .none) panicNoRole(kind);
                if (role == .renderer and kind != .demand) panicRendererPlain(kind);
            }
            self.inner.lock();
            self.owner.store(me, .monotonic);
        }

        noinline fn tryAcquire(self: *Self) bool {
            const site = @returnAddress();
            const role = Roles.current();
            record(site, role, .try_lock);
            if (thread_role.armed and role == .none) panicNoRole(.try_lock);
            const me = std.Thread.getCurrentId();
            if (self.owner.load(.monotonic) == me) return false;
            if (!self.inner.tryLock()) return false;
            self.owner.store(me, .monotonic);
            return true;
        }
    };
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

const OtherThreadTry = struct {
    m: *Checked,
    got: bool = true,
    owner_seen: std.Thread.Id = 0,

    fn tryFromOtherThread(self: *OtherThreadTry) void {
        const scope = OnRoles.enter(.termio);
        defer scope.exit();
        self.got = self.m.tryLock();
        if (self.got) self.m.unlock();
        self.owner_seen = self.m.owner.load(.monotonic);
    }
};

test "another thread's tryLock fails while the holder holds it" {
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
    try testing.expectEqual(@sizeOf(std.Thread.Mutex), @sizeOf(Plain));
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
