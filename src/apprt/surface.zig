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
/// omission marker. A push fills the newest chunk before it starts another,
/// unless a reset has to come between, so between resets the capacity is
/// `capacity` bytes however many pushes bring them; each reset takes a chunk.
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
        // Top up the newest chunk first. A pending reset belongs before these
        // bytes, so they start a chunk of their own instead.
        if (remaining.len != 0 and !reset_pending and self.count != 0) {
            const tail = (self.head + self.count - 1) % max_chunks;
            const fit = utf8FitLen(remaining, chunk_bytes - self.lengths[tail]);
            @memcpy(self.chunks[tail][self.lengths[tail]..][0..fit], remaining[0..fit]);
            self.lengths[tail] += fit;
            remaining = remaining[fit..];
        }
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

    /// Push what one PTY read batch captured. `reset_at` is where its consumer
    /// forgets what it holds (typed input waiting to be seen echoed): null for
    /// nowhere, 0 before everything, otherwise between two bytes, so the bytes
    /// ahead of it are still matched against what was held.
    pub fn pushSemanticCapture(
        self: *TerminalOutputTransport,
        epoch: InterestEpoch,
        output: []const u8,
        omitted_after: bool,
        reset_at: ?usize,
    ) PushResult {
        const at = reset_at orelse return self.pushSemanticBatchForEpoch(epoch, output, omitted_after, false);
        if (at == 0) return self.pushSemanticBatchForEpoch(epoch, output, omitted_after, true);
        // Anything but `.enqueued` left an omission barrier or a newer
        // epoch behind, and the omission forgets what the consumer holds too.
        const head = self.pushSemanticBatchForEpoch(epoch, output[0..at], false, false);
        if (head != .enqueued) return head;
        return self.pushSemanticBatchForEpoch(epoch, output[at..], omitted_after, true);
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

    /// The longest prefix of `output` that fits in `room` bytes without
    /// splitting a UTF-8 sequence, possibly 0. It tops up a chunk that
    /// already holds bytes, so it needs no progress guarantee: what does not
    /// fit starts the next chunk.
    fn utf8FitLen(output: []const u8, room: usize) usize {
        if (output.len <= room) return output.len;
        var len = room;
        while (len > 0 and output[len] & 0xc0 == 0x80) len -= 1;
        return len;
    }

    fn utf8PrefixLen(output: []const u8, max_len: usize) usize {
        const len = utf8FitLen(output, max_len);
        // Semantic producers always provide valid UTF-8. Keep the historical
        // progress guarantee for generic callers if malformed bytes arrive.
        return if (len == 0 and output.len != 0) max_len else len;
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
        /// The query does not compile, so `total` is zero for a reason
        /// other than "nothing matched".
        invalid: bool = false,
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

    /// A ConPTY client asked to show or minimize its owning window.
    window_visibility: bool,

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

    /// A program status report (OSC 7501) or an event that ends records.
    program_status: ProgramStatus,

    /// A command has started in the shell, start a timer.
    start_command,

    /// A command has finished in the shell, stop the timer and send out
    /// notifications as appropriate. The optional i32 is the exit code
    /// of the command. Windows exit codes are 32 bits wide (NTSTATUS
    /// crashes, installer codes), so nothing narrower can carry them.
    stop_command: ?i32,

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
            .program_status => |v| switch (v) {
                .report => |report| report.data.deinit(),
                .prompt, .reset => {},
            },
            else => {},
        }
    }

    /// See `apprt.action.ProgramStatus` for what each event means.
    pub const ProgramStatus = union(enum) {
        /// A report the parser validated. `data` holds the report body,
        /// everything after `7501;`, which a
        /// `terminal.osc.Command.ProgramStatus.Report` reads.
        report: struct {
            state: terminal.osc.Command.ProgramStatus.State,
            data: WriteReq,
        },

        /// A new shell prompt started (OSC 133 A or N).
        prompt,

        /// A full reset (RIS).
        reset,
    };

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
    // The capacity is bytes: once every chunk is full, the next byte has
    // nowhere to go.
    var retained: [TerminalOutputTransport.max_chunks][TerminalOutputTransport.chunk_bytes]u8 = undefined;
    for (&retained, 0..) |*chunk, index| {
        @memset(chunk, 'a' + @as(u8, @intCast(index)));
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
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&retained), ctx.bytes.items);
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

test "terminal output transport counts its capacity in bytes, not pushes" {
    const Context = struct {
        items: usize = 0,
        bytes: std.ArrayList(u8) = .empty,
        omissions: usize = 0,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (item) {
                .reset => {},
                .data => |data| {
                    self.items += 1;
                    self.bytes.appendSlice(std.testing.allocator, data) catch unreachable;
                },
                .omitted => self.omissions += 1,
            }
        }
    };

    // A typing burst: each echoed byte is a PTY read of its own, and more of
    // them arrive before the UI drains than there are chunks.
    var burst: [TerminalOutputTransport.max_chunks * 4]u8 = undefined;
    for (&burst, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));

    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    for (0..burst.len) |index| {
        try std.testing.expectEqual(
            TerminalOutputTransport.PushResult.enqueued,
            transport.push(burst[index .. index + 1]),
        );
    }

    var ctx: Context = .{};
    defer ctx.bytes.deinit(std.testing.allocator);
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqual(@as(usize, 1), ctx.items);
    try std.testing.expectEqualSlices(u8, &burst, ctx.bytes.items);
    try std.testing.expectEqual(@as(usize, 0), ctx.omissions);

    // The last chunk tops up too: after seven full chunks and one short of a
    // full eighth, one more byte fits, and only the byte after it is dropped.
    const chunk_bytes = TerminalOutputTransport.chunk_bytes;
    var filler: [chunk_bytes]u8 = undefined;
    @memset(&filler, 'y');
    for (0..TerminalOutputTransport.max_chunks - 1) |_| {
        try std.testing.expectEqual(
            TerminalOutputTransport.PushResult.enqueued,
            transport.push(&filler),
        );
    }
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.push(filler[0 .. chunk_bytes - 1]),
    );
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.enqueued,
        transport.push("z"),
    );
    try std.testing.expectEqual(
        TerminalOutputTransport.PushResult.omitted,
        transport.push("!"),
    );
    ctx.items = 0;
    ctx.bytes.clearRetainingCapacity();
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqual(@as(usize, TerminalOutputTransport.max_chunks), ctx.items);
    try std.testing.expectEqual(@as(usize, TerminalOutputTransport.capacity), ctx.bytes.items.len);
    try std.testing.expectEqual(@as(u8, 'z'), ctx.bytes.items[ctx.bytes.items.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), ctx.omissions);
}

test "terminal output transport tops up a chunk only behind its reset and on utf8 boundaries" {
    const Context = struct {
        items: std.ArrayList([]u8) = .empty,

        fn callback(raw: *anyopaque, item: TerminalOutputTransport.Item) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const text: []const u8 = switch (item) {
                .reset => "<reset>",
                .data => |data| data,
                .omitted => "<omitted>",
            };
            const copy = std.testing.allocator.dupe(u8, text) catch unreachable;
            self.items.append(std.testing.allocator, copy) catch unreachable;
        }

        fn clear(self: *@This()) void {
            for (self.items.items) |text| std.testing.allocator.free(text);
            self.items.clearRetainingCapacity();
        }

        fn deinit(self: *@This()) void {
            self.clear();
            self.items.deinit(std.testing.allocator);
        }
    };

    const chunk_bytes = TerminalOutputTransport.chunk_bytes;
    const E = TerminalOutputTransport.PushResult.enqueued;
    var transport: TerminalOutputTransport = .{};
    transport.setInterested(true);
    const epoch = transport.captureEpoch().?;
    var ctx: Context = .{};
    defer ctx.deinit();

    // Bytes behind a reset start a chunk of their own, and later bytes top
    // that chunk up, behind the same reset.
    try std.testing.expectEqual(E, transport.push("a"));
    try std.testing.expectEqual(E, transport.pushSemanticBatchForEpoch(epoch, "b", false, true));
    try std.testing.expectEqual(E, transport.push("c"));
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqual(@as(usize, 3), ctx.items.items.len);
    try std.testing.expectEqualStrings("a", ctx.items.items[0]);
    try std.testing.expectEqualStrings("<reset>", ctx.items.items[1]);
    try std.testing.expectEqualStrings("bc", ctx.items.items[2]);

    var filler: [chunk_bytes]u8 = undefined;
    @memset(&filler, 'x');

    // A sequence that does not fit whole in the newest chunk starts the next.
    ctx.clear();
    try std.testing.expectEqual(E, transport.push(filler[0 .. chunk_bytes - 1]));
    try std.testing.expectEqual(E, transport.push("🙂"));
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqual(@as(usize, 2), ctx.items.items.len);
    try std.testing.expectEqualSlices(u8, filler[0 .. chunk_bytes - 1], ctx.items.items[0]);
    try std.testing.expectEqualStrings("🙂", ctx.items.items[1]);

    // One that fits exactly tops the chunk up to full.
    ctx.clear();
    try std.testing.expectEqual(E, transport.push(filler[0 .. chunk_bytes - 4]));
    try std.testing.expectEqual(E, transport.push("🙂"));
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqual(@as(usize, 1), ctx.items.items.len);
    try std.testing.expectEqual(chunk_bytes, ctx.items.items[0].len);
    try std.testing.expectEqualStrings("🙂", ctx.items.items[0][chunk_bytes - 4 ..]);

    // ASCII splits wherever the chunk fills.
    ctx.clear();
    try std.testing.expectEqual(E, transport.push(filler[0 .. chunk_bytes - 2]));
    try std.testing.expectEqual(E, transport.push("abc"));
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqual(@as(usize, 2), ctx.items.items.len);
    try std.testing.expectEqualStrings("ab", ctx.items.items[0][chunk_bytes - 2 ..]);
    try std.testing.expectEqualStrings("c", ctx.items.items[1]);
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

test "terminal output transport places a capture's reset between its bytes" {
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
    var ctx: Context = .{};
    defer ctx.events.deinit(std.testing.allocator);

    // No reset, a reset before everything, and one in the middle: the bytes
    // ahead of it stay ahead of it.
    const E = TerminalOutputTransport.PushResult.enqueued;
    try std.testing.expectEqual(E, transport.pushSemanticCapture(epoch, "none|", false, null));
    try std.testing.expectEqual(E, transport.pushSemanticCapture(epoch, "all|", false, 0));
    try std.testing.expectEqual(E, transport.pushSemanticCapture(epoch, "head|tail|", false, 5));
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings(
        "none|<reset>|all|head|<reset>|tail|",
        ctx.events.items,
    );

    // A reset at the very end of the bytes waits behind them, and the next
    // data comes after it.
    ctx.events.clearRetainingCapacity();
    try std.testing.expectEqual(E, transport.pushSemanticCapture(epoch, "last|", false, 5));
    try std.testing.expectEqual(E, transport.pushSemanticCapture(epoch, "next|", false, null));
    transport.drain(&ctx, Context.callback);
    try std.testing.expectEqualStrings("last|<reset>|next|", ctx.events.items);
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
