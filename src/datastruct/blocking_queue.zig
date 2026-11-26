//! Blocking queue implementation aimed primarily for message passing
//! between threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compat_thread = @import("../lib/compat/thread.zig");

/// Returns a blocking queue implementation for type T.
///
/// This is tailor made for ghostty usage so it isn't meant to be maximally
/// generic, but I'm happy to make it more generic over time. Traits of this
/// queue that are specific to our usage:
///
///   - Fixed size. We expect our queue to quickly drain and also not be
///     too large so we prefer a fixed size queue for now.
///   - No blocking pop. We use an external event loop mechanism such as
///     eventfd to notify our waiter that there is no data available so
///     we don't need to implement a blocking pop.
///   - Drain function. Most queues usually pop one at a time. We have
///     a mechanism for draining since on every IO loop our TTY drains
///     the full queue so we can get rid of the overhead of a ton of
///     locks and bounds checking and do a one-time drain.
///
/// These queues were originally written for single producer, single consumer
/// (SPSC) use, but that is no longer accurate: the renderer mailbox in
/// particular is written by both the app thread and the IO thread. Blocking
/// operations must therefore assume another producer can take a freed slot
/// before a woken waiter reacquires the mutex. At the time of writing this,
/// the blocking queue implementation is purposely naive to build something
/// quickly, but we should benchmark and make this more optimized as
/// necessary.
pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        // The type we use for queue size types. We can optimize this
        // in the future to be the correct bit-size for our preallocated
        // size for this queue.
        pub const Size = u32;

        // The bounds of this queue. We recast this to Size so we can do math.
        const bounds: Size = @intCast(capacity);

        /// Specifies the timeout for an operation.
        pub const Timeout = union(enum) {
            /// Fail instantly (non-blocking).
            instant: void,

            /// Run forever or until interrupted
            forever: void,

            /// Like `forever`, but fail once the flag is set: for a producer
            /// that is stopped while the queue's consumer may be waiting for
            /// it to exit. Nothing signals the queue when the flag changes,
            /// so a waiting push rechecks it every `forever_unless_poll_ns`.
            forever_unless: *const std.atomic.Value(bool),

            /// Nanoseconds
            ns: u64,
        };

        const forever_unless_poll_ns = 10 * std.time.ns_per_ms;

        /// Our data. The values are undefined until they are written.
        data: [bounds]T = undefined,

        /// The next location to write (next empty loc) and next location
        /// to read (next non-empty loc). The number of written elements.
        write: Size = 0,
        read: Size = 0,
        len: Size = 0,

        /// The big mutex that must be held to read/write.
        mutex: std.Io.Mutex = .init,

        /// A CV for being notified when the queue is no longer full. This is
        /// used for writing. Note we DON'T have a CV for waiting on the
        /// queue not being EMPTY because we use external notifiers for that.
        cond_not_full: std.Io.Condition = .init,
        not_full_waiters: usize = 0,

        /// Allocate the blocking queue on the heap.
        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);

            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .init,
                .cond_not_full = .init,
                .not_full_waiters = 0,
            };

            return ptr;
        }

        /// Free all the resources for this queue. This should only be
        /// called once all producers and consumers have quit.
        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        /// Push a value to the queue. This returns the total size of the
        /// queue (unread items) after the push. A return value of zero
        /// means that the push failed.
        pub fn push(self: *Self, io: std.Io, value: T, timeout: Timeout) Size {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // The
            if (self.full()) {
                switch (timeout) {
                    // If we're not waiting, then we failed to write.
                    .instant => return 0,

                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;

                        // Wait in a loop, as condition variables require.
                        // A single wait is not enough: the wake can be
                        // spurious, and this queue is multi-producer, so
                        // another producer can claim the freed slot before
                        // we reacquire the mutex. Falling through in either
                        // case would report a failed push to callers who
                        // asked to wait indefinitely, silently dropping
                        // messages that carry ownership or state.
                        while (self.full()) self.cond_not_full.waitUncancelable(io, &self.mutex);
                    },

                    .forever_unless => |flag| {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        while (self.full() and !flag.load(.acquire)) {
                            compat_thread.waitTimeout(
                                &self.cond_not_full,
                                io,
                                &self.mutex,
                                .{
                                    .duration = .{
                                        .raw = .fromNanoseconds(forever_unless_poll_ns),
                                        .clock = .awake,
                                    },
                                },
                            ) catch {};
                        }
                    },

                    .ns => |ns| {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        compat_thread.waitTimeout(
                            &self.cond_not_full,
                            io,
                            &self.mutex,
                            .{
                                .duration = .{
                                    .raw = .fromNanoseconds(ns),
                                    .clock = .awake,
                                },
                            },
                        ) catch return 0;
                    },
                }

                // A timed wait can expire, or be interrupted, and
                // `.forever_unless` can give up, with the queue still full.
                // `.forever` cannot reach here full.
                if (self.full()) return 0;
            }

            // Add our data and update our accounting
            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;

            return self.len;
        }

        /// Pop a value from the queue without blocking.
        pub fn pop(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // If we're empty we have nothing
            if (self.len == 0) return null;

            // Get the index we're going to read data from and do some
            // accounting. We don't copy the value here to avoid copying twice.
            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            // If we have consumers waiting on a full queue, notify.
            if (self.not_full_waiters > 0) self.cond_not_full.signal(io);

            return self.data[n];
        }

        /// Pop all values from the queue. This will hold the big mutex
        /// until `deinit` is called on the return value. This is used if
        /// you know you're going to "pop" and utilize all the values
        /// quickly to avoid many locks, bounds checks, and cv signals.
        pub fn drain(self: *Self, io: std.Io) DrainIterator {
            self.mutex.lockUncancelable(io);
            return .{ .queue = self };
        }

        pub const DrainIterator = struct {
            queue: *Self,

            pub fn next(self: *DrainIterator) ?T {
                if (self.queue.len == 0) return null;

                // Read and account
                const n = self.queue.read;
                self.queue.read += 1;
                if (self.queue.read >= bounds) self.queue.read -= bounds;
                self.queue.len -= 1;

                return self.queue.data[n];
            }

            pub fn deinit(self: *DrainIterator, io: std.Io) void {
                // If we have consumers waiting on a full queue, notify.
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.signal(io);

                // Unlock
                self.queue.mutex.unlock(io);
            }
        };

        /// Returns true if the queue is full. This is not public because
        /// it requires the lock to be held.
        inline fn full(self: *Self) bool {
            return self.len == bounds;
        }
    };
}

test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Should have no values
    try testing.expect(q.pop(io) == null);

    // Push until we're full
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(io, 3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(io, 4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 5, .{ .instant = {} }));

    // Pop!
    try testing.expect(q.pop(io).? == 1);
    try testing.expect(q.pop(io).? == 2);
    try testing.expect(q.pop(io).? == 3);
    try testing.expect(q.pop(io).? == 4);
    try testing.expect(q.pop(io) == null);

    // Drain does nothing
    var it = q.drain(io);
    try testing.expect(it.next() == null);
    it.deinit(io);

    // Verify we can still push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
}

test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));

    // Timed push should fail
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .ns = 1000 }));
}

test "forever push waits again when a wake leaves the queue full" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));

    const Pusher = struct {
        q: *Q,
        result: Q.Size = 0,

        fn run(self: *@This()) void {
            self.result = self.q.push(testing.io, 99, .{ .forever = {} });
        }
    };

    var pusher: Pusher = .{ .q = q };
    const thread = try std.Thread.spawn(.{}, Pusher.run, .{&pusher});

    // Wait until the pusher is parked on the condition variable.
    while (true) {
        q.mutex.lockUncancelable(io);
        const waiting = q.not_full_waiters;
        q.mutex.unlock(io);
        if (waiting == 1) break;
        std.Thread.yield() catch {};
    }

    // The interleaving that loses messages: a consumer frees the slot and
    // signals, but another producer refills it before the waiter can
    // reacquire the mutex. Doing both under the lock makes that
    // deterministic -- the waiter cannot observe the opening. A single-wait
    // `.forever` gives up here and returns 0.
    q.mutex.lockUncancelable(io);
    q.len -= 1;
    q.cond_not_full.signal(io);
    q.len += 1;
    q.mutex.unlock(io);

    // Let the woken pusher reacquire the mutex and observe the still-full
    // queue before we free a slot for real. Without this the pusher races
    // the pop below and a single-wait `.forever` can pass by luck.
    std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};

    // Now genuinely make room for it.
    try testing.expectEqual(@as(u64, 1), q.pop(io).?);
    thread.join();

    // The push waited rather than reporting failure, and the value landed.
    try testing.expect(pusher.result != 0);
    try testing.expectEqual(@as(u64, 99), q.pop(io).?);
}

test "forever_unless push waits for room and gives up once its flag is set" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));

    // Every wait is bounded, so a broken push fails the test instead of
    // hanging the suite.
    const Pusher = struct {
        q: *Q,
        stop: *const std.atomic.Value(bool),
        value: u64,
        result: Q.Size = 0,
        done: std.Io.Event = .unset,

        fn run(self: *@This()) void {
            self.result = self.q.push(testing.io, self.value, .{ .forever_unless = self.stop });
            self.done.set(testing.io);
        }

        /// Whether the push parked on the full queue.
        fn parked(self: *@This()) bool {
            const start = std.Io.Timestamp.now(testing.io, .awake);
            while (start.untilNow(testing.io, .awake).toNanoseconds() < 5 * std.time.ns_per_s and !self.done.isSet()) {
                self.q.mutex.lockUncancelable(testing.io);
                const waiting = self.q.not_full_waiters;
                self.q.mutex.unlock(testing.io);
                if (waiting == 1) return true;
                std.Thread.yield() catch {};
            }
            return false;
        }

        /// Join the pusher, making room for a push that did not return.
        fn finish(self: *@This(), thread: std.Thread) !void {
            self.done.waitTimeout(testing.io, .{ .duration = .{
                .raw = .fromSeconds(5),
                .clock = .awake,
            } }) catch {
                _ = self.q.pop(testing.io);
                thread.join();
                return error.PushDidNotReturn;
            };
            thread.join();
        }
    };

    // While the flag is clear the push waits like `forever` and lands once
    // there is room.
    var stop: std.atomic.Value(bool) = .init(false);
    var waits: Pusher = .{ .q = q, .stop = &stop, .value = 2 };
    const waiting = try std.Thread.spawn(.{}, Pusher.run, .{&waits});
    const waited = waits.parked();
    try testing.expectEqual(@as(u64, 1), q.pop(io).?);
    try waits.finish(waiting);
    try testing.expect(waited);
    try testing.expectEqual(@as(Q.Size, 1), waits.result);

    // Setting the flag releases a push that is waiting on the full queue.
    var gives_up: Pusher = .{ .q = q, .stop = &stop, .value = 3 };
    const released = try std.Thread.spawn(.{}, Pusher.run, .{&gives_up});
    const waited_again = gives_up.parked();
    stop.store(true, .release);
    try gives_up.finish(released);
    try testing.expect(waited_again);
    try testing.expectEqual(@as(Q.Size, 0), gives_up.result);

    // Once the flag is set a push to a full queue fails without waiting,
    // and the queue keeps what it held.
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 4, .{ .forever_unless = &stop }));
    try testing.expectEqual(@as(u64, 2), q.pop(io).?);
    try testing.expect(q.pop(io) == null);
}
