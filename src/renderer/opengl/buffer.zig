const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const OpenGL = @import("../OpenGL.zig");

const log = std.log.scoped(.opengl);

/// Options for initializing a buffer.
pub const Options = struct {
    target: gl.Buffer.Target = .array,
    usage: gl.Buffer.Usage = .dynamic_draw,
};

/// What a sync that wants to upload only part of a buffer must actually do.
pub const SyncPlan = struct {
    /// Element capacity to reallocate the data store to, or null to keep
    /// the current allocation. Reallocating discards the buffer's contents.
    grow_to: ?usize = null,

    /// Element offset to start uploading at. Everything before it is
    /// already resident in the buffer and can be left alone.
    upload_from: usize = 0,
};

/// Plan a sync that would like to upload only the elements from
/// `requested_from` onwards, leaving the earlier ones in place.
///
/// `total_len` is how many elements must be resident once the sync is done,
/// and `capacity` is how many the buffer can hold right now.
///
/// Growing a buffer means calling `glBufferData` with a null pointer, which
/// discards the entire existing data store and leaves the new one undefined.
/// Any element we then decline to upload keeps whatever the driver happened
/// to leave in that memory. Cell instances carry their own grid position, so
/// stale instances draw glyphs at arbitrary places on screen rather than
/// simply going missing (see issue #254). A growth therefore has to
/// re-upload everything.
pub fn planSync(
    capacity: usize,
    total_len: usize,
    requested_from: usize,
) SyncPlan {
    if (total_len > capacity) return .{ .grow_to = total_len * 2 };
    return .{ .upload_from = requested_from };
}

/// OpenGL data storage for a certain set of equal types. This is usually
/// used for vertex buffers, etc. This helpful wrapper makes it easy to
/// prealloc, shrink, grow, sync, buffers with OpenGL.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying `gl.Buffer` instance.
        buffer: gl.Buffer,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store.
        /// Note this is the number of `T`s, not the size in bytes.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setDataNullManual(len * @sizeOf(T), opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                .len = len,
            };
        }

        /// Init the buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            const buffer = try gl.Buffer.create();
            errdefer buffer.destroy();

            const binding = try buffer.bind(opts.target);
            defer binding.unbind();

            try binding.setData(data, opts.usage);

            return .{
                .buffer = buffer,
                .opts = opts,
                // `len` counts elements, not bytes. This used to be
                // multiplied by @sizeOf(T), which overstated the capacity
                // and would let a later sync skip a reallocation it needed.
                .len = data.len,
            };
        }

        pub fn deinit(self: Self) void {
            self.buffer.destroy();
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// If the amount of data is smaller than the buffer length, the
        /// remaining data in the buffer is left untouched.
        pub fn sync(self: *Self, data: []const T) !void {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            // If we need more space than our buffer has, we need to reallocate.
            if (data.len > self.len) {
                // Reallocate the buffer to hold double what we require.
                self.len = data.len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            if (data.len == 0) return;
            try binding.setSubData(0, data);
        }

        /// Sync only the `all[start..end]` subrange to the buffer, leaving
        /// the rest of the buffer's contents in place.
        ///
        /// `all` must be the complete contents the buffer should hold, since
        /// growing the buffer discards everything (see `planSync`) and so
        /// forces us to upload all of it.
        pub fn syncRange(
            self: *Self,
            all: []const T,
            start: usize,
            end: usize,
        ) !void {
            const plan = planSync(self.len, all.len, start);

            // Growing orphans the data store, which would leave everything
            // outside [start, end) undefined, so upload the whole thing.
            if (plan.grow_to != null) return self.sync(all);

            const data = all[start..end];
            if (data.len == 0) return;

            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            try binding.setSubData(plan.upload_from * @sizeOf(T), data);
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }

            // If we need more space than our buffer has, we need to reallocate.
            if (total_len > self.len) {
                // Reallocate the buffer to hold double what we require.
                self.len = total_len * 2;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );
            }

            // We can fit within the buffer so we can just replace bytes.
            var i: usize = 0;

            for (lists) |list| {
                if (list.items.len == 0) continue;
                try binding.setSubData(i, list.items);
                i += list.items.len * @sizeOf(T);
            }

            return total_len;
        }

        /// Like Buffer.syncFromArrayLists but only uploads the suffix
        /// starting at the given list index. Returns the total item count
        /// across all lists.
        pub fn syncFromArrayListsStart(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
            start_index: usize,
        ) !usize {
            const binding = try self.buffer.bind(self.opts.target);
            defer binding.unbind();

            var start = @min(start_index, lists.len);

            var total_len: usize = 0;
            var prefix_len: usize = 0;
            for (lists, 0..) |list, i| {
                total_len += list.items.len;
                if (i < start) prefix_len += list.items.len;
            }

            const plan = planSync(self.len, total_len, prefix_len);
            if (plan.grow_to) |new_len| {
                self.len = new_len;
                try binding.setDataNullManual(
                    self.len * @sizeOf(T),
                    self.opts.usage,
                );

                // Reallocating discarded the prefix we were going to skip,
                // so it has to be re-uploaded along with the suffix.
                start = 0;
            }

            var offset = plan.upload_from * @sizeOf(T);
            for (lists[start..]) |list| {
                if (list.items.len == 0) continue;
                try binding.setSubData(offset, list.items);
                offset += list.items.len * @sizeOf(T);
            }

            return total_len;
        }
    };
}

test "planSync keeps a partial upload partial while it fits ConPTY" {
    const testing = std.testing;

    // Nothing has to grow, so only the dirty suffix goes up.
    try testing.expectEqual(SyncPlan{
        .grow_to = null,
        .upload_from = 1226,
    }, planSync(1318, 1300, 1226));

    // Exactly filling the buffer is still a fit.
    try testing.expectEqual(SyncPlan{
        .grow_to = null,
        .upload_from = 1226,
    }, planSync(1318, 1318, 1226));

    // Nothing dirty before the end is a no-op offset, not a growth.
    try testing.expectEqual(SyncPlan{
        .grow_to = null,
        .upload_from = 0,
    }, planSync(0, 0, 0));
}

test "planSync promotes a growth to a full upload ConPTY" {
    const testing = std.testing;

    // Growing calls glBufferData with a null pointer, which discards the
    // whole data store, so the prefix we meant to skip would be left as
    // undefined driver memory. It has to be re-uploaded.
    //
    // These are the four growth events measured on a new tab printing
    // ~100 lines with a bar cursor, which is issue #254: before the fix
    // they skipped 0, 188, 564 and 1226 of the glyph instances.
    try testing.expectEqual(SyncPlan{
        .grow_to = 190,
        .upload_from = 0,
    }, planSync(1, 95, 0));
    try testing.expectEqual(SyncPlan{
        .grow_to = 566,
        .upload_from = 0,
    }, planSync(190, 283, 188));
    try testing.expectEqual(SyncPlan{
        .grow_to = 1318,
        .upload_from = 0,
    }, planSync(566, 659, 564));
    try testing.expectEqual(SyncPlan{
        .grow_to = 2644,
        .upload_from = 0,
    }, planSync(1318, 1322, 1226));

    // An empty buffer can never take a partial upload of real data.
    try testing.expectEqual(SyncPlan{
        .grow_to = 2,
        .upload_from = 0,
    }, planSync(0, 1, 0));
}
