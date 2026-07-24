const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const semantic_output = @import("../terminal/semantic_output.zig");
const Config = @import("../config.zig").Config;
const MessageData = @import("../datastruct/main.zig").MessageData;

/// Fixed-memory semantic terminal-output handoff from the PTY thread to the UI
/// thread. Producers never block: lock contention and capacity exhaustion
/// become one ordered omission barrier. While that barrier is pending, newer
/// bytes are rejected until the UI consumes all retained chunks and the
/// omission marker.
pub const TerminalOutputTransport = struct {
    pub const chunk_bytes = semantic_output.transport_chunk_bytes;
    pub const max_chunks = semantic_output.transport_max_chunks;
    pub const capacity = semantic_output.capacity;
    pub const InterestEpoch = u64;

    pub const PushResult = enum {
        uninterested,
        stale,
        enqueued,
        omitted,
        contended,
        rejecting,
    };

    pub const Item = union(enum) {
        reset,
        data: []const u8,
        omitted,
    };

    pub const DrainCallback = *const fn (*anyopaque, Item) void;

    interest_state: std.atomic.Value(u64) = .init(0),
    omission_pending: std.atomic.Value(u64) = .init(0),
    mutex: std.Thread.Mutex = .{},
    chunks: [max_chunks][chunk_bytes]u8 = undefined,
    lengths: [max_chunks]usize = [_]usize{0} ** max_chunks,
    resets_before: [max_chunks]bool = [_]bool{false} ** max_chunks,
    trailing_reset: bool = false,
    head: usize = 0,
    count: usize = 0,

    pub fn setInterested(self: *TerminalOutputTransport, interested: bool) void {
        const state = self.interest_state.load(.acquire);
        if ((state & 1 != 0) == interested) return;
        if (!interested) self.interest_state.store(state +% 1, .release);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.head = 0;
        self.count = 0;
        self.trailing_reset = false;
        self.omission_pending.store(0, .release);
        if (interested) {
            const disabled_state = self.interest_state.load(.acquire);
            self.interest_state.store(disabled_state +% 1, .release);
        }
    }

    pub inline fn isInterested(self: *const TerminalOutputTransport) bool {
        return self.captureEpoch() != null;
    }

    pub inline fn captureEpoch(
        self: *const TerminalOutputTransport,
    ) ?InterestEpoch {
        const state = self.interest_state.load(.acquire);
        return if (state & 1 != 0) state else null;
    }

    pub fn push(self: *TerminalOutputTransport, output: []const u8) PushResult {
        return self.pushBatch(output, false);
    }

    pub fn pushBatch(
        self: *TerminalOutputTransport,
        output: []const u8,
        omitted_after: bool,
    ) PushResult {
        const epoch = self.captureEpoch() orelse return .uninterested;
        return self.pushBatchForEpoch(epoch, output, omitted_after);
    }

    pub fn pushBatchForEpoch(
        self: *TerminalOutputTransport,
        epoch: InterestEpoch,
        output: []const u8,
        omitted_after: bool,
    ) PushResult {
        return self.pushSemanticBatchForEpoch(
            epoch,
            output,
            omitted_after,
            false,
        );
    }

    pub fn pushSemanticBatchForEpoch(
        self: *TerminalOutputTransport,
        epoch: InterestEpoch,
        output: []const u8,
        omitted_after: bool,
        reset_before: bool,
    ) PushResult {
        if (self.interest_state.load(.acquire) != epoch) return .stale;
        if (self.omissionPendingForEpoch(epoch)) return .rejecting;
        if (!self.mutex.tryLock()) {
            if (!self.markOmissionForEpoch(epoch)) return .stale;
            return .contended;
        }
        defer self.mutex.unlock();

        if (self.interest_state.load(.acquire) != epoch) return .stale;
        if (self.omissionPendingForEpoch(epoch)) return .rejecting;

        var remaining = output;
        var reset_pending = reset_before or self.trailing_reset;
        if (remaining.len == 0 and reset_pending) self.trailing_reset = true;
        while (remaining.len != 0) {
            if (self.count == max_chunks) {
                _ = self.markOmissionForEpoch(epoch);
                return .omitted;
            }
            const chunk_len = utf8PrefixLen(remaining, chunk_bytes);
            const index = (self.head + self.count) % max_chunks;
            @memcpy(self.chunks[index][0..chunk_len], remaining[0..chunk_len]);
            self.lengths[index] = chunk_len;
            self.resets_before[index] = reset_pending;
            if (reset_pending) {
                self.trailing_reset = false;
                reset_pending = false;
            }
            self.count += 1;
            remaining = remaining[chunk_len..];
        }
        if (omitted_after) {
            _ = self.markOmissionForEpoch(epoch);
            return .omitted;
        }
        return .enqueued;
    }

    fn omissionPendingForEpoch(
        self: *TerminalOutputTransport,
        epoch: InterestEpoch,
    ) bool {
        while (true) {
            const pending = self.omission_pending.load(.acquire);
            if (pending == 0) return false;
            if (pending == epoch) return true;
            const current = self.interest_state.load(.acquire);
            if (current != epoch) return false;
            if (pending == current) return false;
            _ = self.omission_pending.cmpxchgStrong(
                pending,
                0,
                .acq_rel,
                .acquire,
            );
        }
    }

    fn markOmissionForEpoch(
        self: *TerminalOutputTransport,
        epoch: InterestEpoch,
    ) bool {
        while (self.interest_state.load(.acquire) == epoch) {
            if (self.omissionPendingForEpoch(epoch)) return true;
            if (self.omission_pending.cmpxchgStrong(
                0,
                epoch,
                .acq_rel,
                .acquire,
            ) == null) return true;
        }
        return false;
    }

    fn utf8PrefixLen(output: []const u8, max_len: usize) usize {
        if (output.len <= max_len) return output.len;

        var len = max_len;
        while (len > 0 and output[len] & 0xc0 == 0x80) len -= 1;
        // Semantic producers always provide valid UTF-8. Keep the historical
        // progress guarantee for generic callers if malformed bytes arrive.
        return if (len == 0) max_len else len;
    }

    pub fn drain(
        self: *TerminalOutputTransport,
        ctx: *anyopaque,
        callback: DrainCallback,
    ) void {
        const epoch = self.captureEpoch() orelse return;

        var chunks: [max_chunks][chunk_bytes]u8 = undefined;
        var lengths: [max_chunks]usize = [_]usize{0} ** max_chunks;
        var resets_before: [max_chunks]bool = [_]bool{false} ** max_chunks;
        var count: usize = 0;
        self.mutex.lock();
        if (self.interest_state.load(.acquire) != epoch) {
            self.mutex.unlock();
            return;
        }
        while (self.count != 0) {
            const index = self.head;
            const chunk_len = self.lengths[index];
            @memcpy(chunks[count][0..chunk_len], self.chunks[index][0..chunk_len]);
            lengths[count] = chunk_len;
            resets_before[count] = self.resets_before[index];
            count += 1;
            self.head = (index + 1) % max_chunks;
            self.count -= 1;
        }
        self.head = 0;
        const trailing_reset = self.trailing_reset;
        self.trailing_reset = false;
        // Close this retained-data epoch while still holding the queue lock.
        // Producers that race after the swap either enqueue into the next
        // epoch or establish a fresh omission barrier for its next drain.
        const emit_omission = self.omission_pending.cmpxchgStrong(
            epoch,
            0,
            .acq_rel,
            .acquire,
        ) == null;
        self.mutex.unlock();

        for (0..count) |index| {
            if (resets_before[index]) callback(ctx, .reset);
            callback(ctx, .{ .data = chunks[index][0..lengths[index]] });
        }
        if (trailing_reset) callback(ctx, .reset);
        if (emit_omission) callback(ctx, .omitted);
    }
};

/// The message types that can be sent to a single surface.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);
    // 64 is only the inline-small capacity; larger row snapshots allocate in
    // MessageData.init and are not truncated.
    pub const SearchRowsReq = MessageData(u32, 64);
    pub const SearchTotal = struct {
        generation: u64,
        total: ?usize,
    };
    pub const SearchSelected = struct {
        generation: u64,
        selected: ?usize,
    };
    pub const SearchClear = struct {
        generation: u64,
    };
    pub const SearchMatchRows = struct {
        generation: u64,
        rows: SearchRowsReq,

        pub fn deinit(self: SearchMatchRows) void {
            self.rows.deinit();
        }
    };
    pub const SearchViewportMatches = renderer.Message.SearchMatches;
    pub const SearchSelectedMatch = renderer.Message.SearchSelectedMatch;

    /// Set the title of the surface.
    /// TODO: we should change this to a "WriteReq" style structure in
    /// the termio message so that we can more efficiently send strings
    /// of any length
    set_title: [256]u8,

    /// Report the window title back to the terminal
    report_title: ReportTitleStyle,

    /// Set the mouse shape.
    set_mouse_shape: terminal.MouseShape,

    /// Read the clipboard and write to the pty.
    clipboard_read: apprt.Clipboard,

    /// Write the clipboard contents.
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },

    /// Change the configuration to the given configuration. The pointer is
    /// not valid after receiving this message so any config must be used
    /// and derived immediately.
    change_config: *const Config,

    /// Close the surface. This will only close the current surface that
    /// receives this, not the full application.
    close: void,

    /// The child process running in the surface has exited. This may trigger
    /// a surface close, it may not. Additional details about the child
    /// command are given in the `ChildExited` struct.
    child_exited: ChildExited,

    /// Show a desktop notification.
    desktop_notification: struct {
        /// Desktop notification title.
        title: [63:0]u8,

        /// Desktop notification body.
        body: [255:0]u8,
    },

    /// Health status change for the renderer.
    renderer_health: renderer.Health,

    /// Tell the surface to present itself to the user. This may require raising
    /// a window and switching tabs.
    present_surface: void,

    /// Notifies the surface that password input has started within
    /// the terminal. This should always be followed by a false value
    /// unless the surface exits.
    password_input: bool,

    /// A terminal color was changed using OSC sequences.
    color_change: terminal.osc.color.ColoredTarget,

    /// Notifies the surface that a tick of the timer that is timing
    /// out selection scrolling has occurred. "selection scrolling"
    /// is when the user has clicked and dragged the mouse outside
    /// the viewport of the terminal and the terminal is scrolling
    /// the viewport to follow the mouse cursor.
    selection_scroll_tick: bool,

    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    /// A command has started in the shell, start a timer.
    start_command,

    /// A command has finished in the shell, stop the timer and send out
    /// notifications as appropriate. The optional u8 is the exit code
    /// of the command.
    stop_command: ?u8,

    /// The scrollbar state changed for the surface.
    scrollbar: terminal.Scrollbar,

    /// Search viewport highlight updates.
    search_viewport_matches: SearchViewportMatches,

    /// Selected search highlight update.
    search_selected_match: SearchSelectedMatch,

    /// Search progress update.
    search_total: SearchTotal,

    /// Selected search index change.
    search_selected: SearchSelected,

    /// Search match rows for scrollbar markers.
    search_match_rows: SearchMatchRows,

    /// Force-clear search state for the current search generation.
    search_clear: SearchClear,

    pub fn deinit(self: *Message) void {
        switch (self.*) {
            .clipboard_write => |v| v.req.deinit(),
            .pwd_change => |v| v.deinit(),
            .search_viewport_matches => |*v| v.deinit(),
            .search_selected_match => |*v| v.deinit(),
            .search_match_rows => |v| v.deinit(),
            else => {},
        }
    }

    pub const ReportTitleStyle = enum {
        csi_21_t,
    };

    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,

        /// GTK boxed types are not used in the Windows-only fork.
        pub const getGObjectType = void;
    };
};

/// A surface mailbox.
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,

    /// Send a message to the surface.
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        // Surface message sending is actually implemented on the app
        // thread, so we have to rewrap the message with our surface
        // pointer and send it to the app thread.
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
};

test "terminal output transport ignores uninterested producers without copying" {
    var transport: TerminalOutputTransport = .{};
    const input = "uninterested output";
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.uninterested,
        transport.push(input),
    );
    try std.testing.expectEqual(@as(usize, 0), transport.count);
    try std.testing.expectEqual(@as(u64, 0), transport.omission_pending.load(.acquire));
}

test "terminal output transport saturation is nonblocking and ordered" {
    const Context = struct {
        bytes: std.ArrayList(u8) = .empty,
        omissions: usize = 0,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (item) {
                .reset => {},
                .data => |data| self.bytes.appendSlice(std.testing.allocator, data) catch unreachable,
                .omitted => self.omissions += 1,
            }
        }
    };

    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    const retained = [_][]const u8{
        "old-0|",
        "old-1|",
        "old-2|",
        "old-3|",
        "old-4|",
        "old-5|",
        "old-6|",
        "old-7|",
    };
    for (retained) |chunk| {
        try std.testing.expectEqual(
            TerminalOutputTransport.PushResult.enqueued,
            transport.push(chunk),
        );
    }
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.omitted,
        transport.push("dropped"),
    );
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.rejecting,
        transport.push("newer"),
    );

    var ctx: Context = .{};
    defer ctx.bytes.deinit(std.testing.allocator);
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings(
        "old-0|old-1|old-2|old-3|old-4|old-5|old-6|old-7|",
        ctx.bytes.items,
    );
    try std.testing.expectEqual(@as(usize, 1), ctx.omissions);

    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.push("accepted-after-omission"),
    );
    ctx.bytes.clearRetainingCapacity();
    ctx.omissions = 0;
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings("accepted-after-omission", ctx.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.omissions);
}

test "terminal output transport keeps utf8 chunks before batch omission marker" {
    const Context = struct {
        bytes: std.ArrayList(u8) = .empty,
        omissions: usize = 0,
        chunks_valid: bool = true,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (item) {
                .reset => {},
                .data => |data| {
                    self.chunks_valid = self.chunks_valid and
                        std.unicode.utf8ValidateSlice(data);
                    self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
                },
                .omitted => self.omissions += 1,
            }
        }
    };

    var semantic: [TerminalOutputTransport.chunk_bytes + 3]u8 = undefined;
    @memset(semantic[0 .. TerminalOutputTransport.chunk_bytes - 1], 'x');
    @memcpy(semantic[TerminalOutputTransport.chunk_bytes - 1 ..], "🙂");

    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.omitted,
        transport.pushBatch(&semantic, true),
    );

    var ctx: Context = .{};
    defer ctx.bytes.deinit(std.testing.allocator);
    transport.drain(&ctx, Context.callback);
    try std.testing.expect(ctx.chunks_valid);
    try std.testing.expectEqualSlices(u8, &semantic, ctx.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), ctx.omissions);
}

test "terminal output transport lock contention returns immediately" {
    const Context = struct {
        omissions: usize = 0,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (item) {
                .reset => {},
                .data => {},
                .omitted => self.omissions += 1,
            }
        }
    };

    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    transport.mutex.lock();
    var parsing_continued = false;
    const result = transport.push("cannot wait");
    parsing_continued = true;
    transport.mutex.unlock();
    try std.testing.expectEqual(TerminalOutputTransport.PushResult.contended, result);
    try std.testing.expect(parsing_continued);
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.rejecting,
        transport.push("later bytes"),
    );

    var ctx: Context = .{};
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqual(@as(usize, 1), ctx.omissions);
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.push("accepted"),
    );
}

test "terminal output transport reentrant callbacks preserve epochs and contention marker" {
    const Context = struct {
        transport: *TerminalOutputTransport,
        events: std.ArrayList(u8) = .empty,
        reenter: bool = true,
        pushed_from_data: ?TerminalOutputTransport.PushResult = null,
        pushed_from_omission: ?TerminalOutputTransport.PushResult = null,
        contended_after_clear: ?TerminalOutputTransport.PushResult = null,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (item) {
                .reset => self.events.appendSlice(std.testing.allocator, "<reset>|") catch unreachable,
                .data => |data| {
                    self.events.appendSlice(std.testing.allocator, data) catch unreachable;
                    if (self.reenter and self.pushed_from_data == null) {
                        self.pushed_from_data = self.transport.push("during-data|");
                    }
                },
                .omitted => {
                    self.events.appendSlice(std.testing.allocator, "<omitted>|") catch unreachable;
                    if (self.reenter) {
                        self.pushed_from_omission = self.transport.push("during-omission|");
                        self.transport.mutex.lock();
                        self.contended_after_clear = self.transport.push("dropped-after-clear");
                        self.transport.mutex.unlock();
                        self.reenter = false;
                    }
                },
            }
        }
    };

    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.push("old|"),
    );
    transport.mutex.lock();
    const initial_contention = transport.push("initially-dropped");
    transport.mutex.unlock();
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.contended,
        initial_contention,
    );

    var ctx: Context = .{ .transport = &transport };
    defer ctx.events.deinit(std.testing.allocator);
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings("old|<omitted>|", ctx.events.items);
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        ctx.pushed_from_data.?,
    );
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        ctx.pushed_from_omission.?,
    );
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.contended,
        ctx.contended_after_clear.?,
    );
    try std.testing.expect(transport.omission_pending.load(.acquire) != 0);
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.rejecting,
        transport.push("rejected-after-contention"),
    );

    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings(
        "old|<omitted>|during-data|during-omission|<omitted>|",
        ctx.events.items,
    );
    try std.testing.expectEqual(@as(u64, 0), transport.omission_pending.load(.acquire));
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.push("accepted-next-epoch"),
    );
}

test "terminal output transport rejects stale interest epoch without poisoning new epoch" {
    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    const stale_epoch = transport.captureEpoch().?;

    transport.setInterested(false);
    transport.setInterested(true);
    const current_epoch = transport.captureEpoch().?;
    try std.testing.expect(stale_epoch != current_epoch);
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.stale,
        transport.pushSemanticBatchForEpoch(
            stale_epoch,
            "stale",
            true,
            true,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), transport.omission_pending.load(.acquire));
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.pushBatchForEpoch(current_epoch, "current", false),
    );

    const Context = struct {
        events: std.ArrayList(u8) = .empty,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (item) {
                .reset => self.events.appendSlice(std.testing.allocator, "<reset>|") catch unreachable,
                .data => |data| self.events.appendSlice(std.testing.allocator, data) catch unreachable,
                .omitted => self.events.appendSlice(std.testing.allocator, "<omitted>|") catch unreachable,
            }
        }
    };
    var ctx: Context = .{};
    defer ctx.events.deinit(std.testing.allocator);
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings("current", ctx.events.items);
}

test "terminal output transport orders silent reset before post reset data" {
    const Context = struct {
        events: std.ArrayList(u8) = .empty,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (item) {
                .reset => self.events.appendSlice(std.testing.allocator, "<reset>|") catch unreachable,
                .data => |data| self.events.appendSlice(std.testing.allocator, data) catch unreachable,
                .omitted => self.events.appendSlice(std.testing.allocator, "<omitted>|") catch unreachable,
            }
        }
    };

    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    const epoch = transport.captureEpoch().?;
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.pushBatchForEpoch(epoch, "before|", false),
    );
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.pushSemanticBatchForEpoch(
            epoch,
            "after|",
            false,
            true,
        ),
    );

    var ctx: Context = .{};
    defer ctx.events.deinit(std.testing.allocator);
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings("before|<reset>|after|", ctx.events.items);

    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.pushSemanticBatchForEpoch(epoch, "", false, true),
    );
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.pushBatchForEpoch(epoch, "later|", false),
    );
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings(
        "before|<reset>|after|<reset>|later|",
        ctx.events.items,
    );
}

/// Context for new surface creation to determine inheritance behavior
pub const NewSurfaceContext = enum(c_int) {
    window = 0,
    tab = 1,
    split = 2,
};

pub fn shouldInheritWorkingDirectory(context: NewSurfaceContext, config: *const Config) bool {
    return switch (context) {
        .window => config.@"window-inherit-working-directory",
        .tab => config.@"tab-inherit-working-directory",
        .split => config.@"split-inherit-working-directory",
    };
}

/// Returns a new config for a surface for the given app that should be
/// used for any new surfaces. The resulting config should be deinitialized
/// after the surface is initialized.
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
) Allocator.Error!Config {
    // Create a shallow clone
    var copy = config.shallowClone(app.alloc);

    // Our allocator is our config's arena
    const alloc = copy._arena.?.allocator();

    // Get our previously focused surface for some inherited values.
    const prev = app.focusedSurface();
    if (prev) |p| {
        if (shouldInheritWorkingDirectory(context, config)) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = .{ .path = pwd };
            }
        }
    }

    return copy;
}
