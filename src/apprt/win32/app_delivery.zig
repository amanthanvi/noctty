//! Process-owned capabilities for messages delivered through the App HWND.
//! Posting and closing share a lock so no producer can post to a recycled HWND.
const std = @import("std");
const sys = @import("sys.zig");

pub fn Channel(comptime Payload: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { id: usize, message: u32, payload: Payload };
        refs: std.atomic.Value(usize) = .init(1),
        mutex: std.Thread.Mutex = .{},
        hwnd: std.atomic.Value(usize) = .init(0),
        entries: std.ArrayList(Entry) = .empty,
        update_running: std.atomic.Value(bool) = .init(false),
        /// A startup profile discovery runs or its result is queued.
        profiles_running: std.atomic.Value(bool) = .init(false),
        toast_pending: std.atomic.Value(bool) = .init(false),

        pub fn create() !*Self {
            const self = try std.heap.page_allocator.create(Self);
            self.* = .{};
            return self;
        }

        pub fn retain(self: *Self) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        pub fn release(self: *Self) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            std.debug.assert(self.hwnd.load(.acquire) == 0);
            for (self.entries.items) |*entry| entry.payload.deinit();
            self.entries.deinit(std.heap.page_allocator);
            std.heap.page_allocator.destroy(self);
        }

        pub fn publish(self: *Self, hwnd: sys.HWND) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.hwnd.store(@intFromPtr(hwnd), .release);
        }

        /// Stop new posts before destroying the native window. Already owned
        /// payloads remain available for the UI thread's shutdown drain.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.hwnd.store(0, .release);
        }

        pub fn wake(self: *Self, message: u32) bool {
            return self.notify(message, 0);
        }

        pub fn notify(self: *Self, message: u32, id: usize) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.postLocked(message, id);
        }

        fn postLocked(self: *Self, message: u32, id: usize) bool {
            const raw = self.hwnd.load(.acquire);
            if (raw == 0) return false;
            return sys.PostMessageW(@ptrFromInt(raw), message, 0, @bitCast(id)) != 0;
        }

        /// Ownership transfers only when both insertion and posting succeed.
        pub fn post(self: *Self, message: u32, payload: Payload) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.hwnd.load(.acquire) == 0) return false;
            const id = id: while (true) {
                const candidate = std.crypto.random.int(usize);
                if (candidate == 0) continue;
                for (self.entries.items) |entry| {
                    if (entry.id == candidate) break;
                } else break :id candidate;
            };
            self.entries.append(std.heap.page_allocator, .{
                .id = id,
                .message = message,
                .payload = payload,
            }) catch return false;
            if (self.postLocked(message, id)) return true;
            _ = self.entries.pop();
            return false;
        }

        /// Never derive a pointer from message parameters. Validate both the
        /// capability and its message kind before removing owned storage.
        pub fn take(self: *Self, message: u32, id: usize) ?Payload {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.entries.items, 0..) |entry, index| {
                if (entry.id == id and entry.message == message) {
                    return self.entries.orderedRemove(index).payload;
                }
            }
            return null;
        }

        pub fn pop(self: *Self) ?Payload {
            self.mutex.lock();
            defer self.mutex.unlock();
            return if (self.entries.pop()) |entry| entry.payload else null;
        }
    };
}

test "closed App delivery rejects wake and payload without taking ownership" {
    const Payload = struct {
        pub fn deinit(_: *@This()) void {}
    };
    const channel = try Channel(Payload).create();
    defer channel.release();
    try std.testing.expect(!channel.wake(0x8001));
    try std.testing.expect(!channel.post(0x8002, .{}));
    try std.testing.expect(channel.take(0x8002, 1) == null);
}
