//! Search thread that handles searching a terminal for a string match.
//! This is expected to run on a dedicated thread to try to prevent too much
//! overhead to other terminal read/write operations.
//!
//! The thread is a shell over `QuerySearch.step`: it owns the OS thread, the
//! event loop, the mailbox and the refresh timer, and turns each report into
//! events. The current architecture of search does acquire global locks for
//! accessing terminal data, so there's still added contention, but we do our
//! best to minimize this by trading off memory usage (copying data to
//! minimize lock time).
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const xev = @import("../../global.zig").xev;
const internal_os = @import("../../os/main.zig");
const BlockingQueue = @import("../../datastruct/main.zig").BlockingQueue;
const MessageData = @import("../../datastruct/main.zig").MessageData;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const Terminal = @import("../Terminal.zig");

const QueryOptions = @import("query_options.zig").QueryOptions;
const QuerySearch = @import("query_search.zig").QuerySearch;
const ScreenSearch = @import("screen.zig").ScreenSearch;

const log = std.log.scoped(.search_thread);
const darwin = if (builtin.os.tag.isDarwin()) struct {
    const QosClass = internal_os.macos.QosClass;

    fn setThreadName(name: [*:0]const u8) void {
        internal_os.macos.pthread_setname_np(name);
    }

    fn setQosClass(class: QosClass) !void {
        try internal_os.macos.setQosClass(class);
    }
} else struct {
    const QosClass = enum {
        utility,
    };

    fn setThreadName(_: [*:0]const u8) void {}

    fn setQosClass(_: QosClass) !void {}
};

/// The interval at which we refresh the terminal state to check if
/// there are any changes that require us to re-search. This should be
/// balanced to be fast enough to be responsive but not so fast that
/// we hold the terminal lock too often.
const REFRESH_INTERVAL = 24; // 40 FPS

fn shouldRunRefreshTimer(state: QuerySearch.State, visible: bool, focused: bool) bool {
    return state != .idle and visible and focused;
}

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// The event loop for the search thread.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the thread on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for refreshing the terminal state to determine if
/// we have a stale active area, viewport, screen change, etc. This is
/// CPU intensive so we stop doing this under certain conditions.
refresh: xev.Timer,
refresh_c: xev.Completion = .{},
refresh_active: bool = false,

/// Search refreshes only need to run while the search is active and the
/// owning surface is both visible and focused.
visible: bool = true,
focused: bool = true,

/// The query, stepped by this thread.
search: QuerySearch,

/// The state of the last step.
state: QuerySearch.State = .idle,

/// Generation for callbacks from the currently active query. The surface
/// uses this to reject events from superseded query-change messages.
event_generation: u64 = 0,

/// The options used to initialize this thread.
opts: Options,

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(alloc: Allocator, opts: Options) !Thread {
    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // Refresh timer, see comments.
    var refresh_h = try xev.Timer.init();
    errdefer refresh_h.deinit();

    return .{
        .alloc = alloc,
        .mailbox = mailbox,
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .refresh = refresh_h,
        .visible = opts.visible,
        .focused = opts.focused,
        .search = .init(alloc, .{ .terminal = opts.terminal, .mutex = opts.mutex }),
        .opts = opts,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.refresh.deinit();
    self.wakeup.deinit();
    self.stop.deinit();
    self.loop.deinit();
    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);

    self.search.deinit();
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("search thread err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("search thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (comptime builtin.os.tag.isDarwin()) {
        darwin.setThreadName("search");

        // We can run with lower priority than other threads.
        const class: darwin.QosClass = .utility;
        if (darwin.setQosClass(class)) {
            log.debug("thread QoS class set class={}", .{class});
        } else |err| {
            log.warn("error setting QoS class err={}", .{err});
        }
    }

    // Start the async handlers
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);

    // Send an initial wakeup so we drain our mailbox immediately.
    try self.wakeup.notify();

    // The refresh timer only runs while an active search is visible/focused.
    self.syncRefreshTimer();

    // Run
    log.debug("starting search thread", .{});
    defer {
        log.debug("starting search thread shutdown", .{});

        // Send the quit message
        if (self.opts.event_cb) |cb| {
            cb(.quit, self.event_generation, self.opts.event_userdata);
        }
    }

    // Unlike some of our other threads, we interleave search work
    // with our xev loop so that we can try to make forward search progress
    // while also listening for messages.
    while (true) {
        // If our loop is canceled then we drain our messages and quit.
        if (self.loop.stopped()) {
            while (self.mailbox.pop()) |message| {
                log.debug("mailbox message ignored during shutdown={}", .{message});
            }

            return;
        }

        // While the search has work, we only process the messages we
        // have and return immediately so we can continue it. Otherwise we
        // block until there is a message or the refresh timer fires.
        if (self.state == .busy) {
            self.apply(.{});
            try self.loop.run(.no_wait);
        } else {
            try self.loop.run(.once);
        }
    }
}

/// Step the query and send what changed as events, in this order: the
/// total (or invalid_query), the viewport matches, the match rows, the
/// selected match, completion.
fn apply(self: *Thread, req: QuerySearch.Request) void {
    const report = self.search.step(req);
    self.state = report.state;
    if (report.state == .idle) self.stopRefreshTimer();

    const cb = self.opts.event_cb orelse return;
    const generation = self.event_generation;
    const ud = self.opts.event_userdata;
    if (report.total) |total| cb(switch (total) {
        .count => |n| .{ .total_matches = n },
        .invalid => .invalid_query,
    }, generation, ud);
    if (report.viewport_matches) |matches| cb(.{ .viewport_matches = matches }, generation, ud);
    if (report.match_rows) |rows| cb(.{ .match_rows = rows }, generation, ud);
    if (report.selected) |selected| cb(.{ .selected_match = switch (selected) {
        .none => null,
        .match => |m| m,
    } }, generation, ud);
    if (report.complete) cb(.complete, generation, ud);
}

/// Enqueue a message and wake the search thread to process it.
///
/// The first notification lets the search thread make room if the mailbox
/// is full. The second covers the case where that notification is processed
/// before the message is enqueued.
pub fn send(self: *Thread, msg: Message) void {
    self.notify();

    // Search messages may transfer ownership or required state.
    _ = self.mailbox.push(msg, .{ .forever = {} });

    self.notify();
}

fn notify(self: *Thread) void {
    self.wakeup.notify() catch |err| {
        log.warn("error notifying search thread err={}", .{err});
    };
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .change_query => |v| {
                defer v.req.deinit();
                self.event_generation = v.generation;
                self.apply(.{ .query = .{
                    .needle = v.req.slice(),
                    .options = v.options,
                } });
                self.syncRefreshTimer();
            },
            .select => |v| self.apply(.{ .select = v }),
            .visible => |v| {
                if (self.visible == v) continue;
                self.visible = v;
                self.syncRefreshTimer();
            },
            .focus => |v| {
                if (self.focused == v) continue;
                self.focused = v;
                self.syncRefreshTimer();
            },
        }
    }
}

fn startRefreshTimer(self: *Thread) void {
    // Set our active state so it knows we're running. We set this before
    // even checking the active state in case we have a pending shutdown.
    self.refresh_active = true;

    // If our timer is already active, then we don't have to do anything.
    if (self.refresh_c.state() == .active) return;

    // Start the timer which loops
    self.refresh.run(
        &self.loop,
        &self.refresh_c,
        REFRESH_INTERVAL,
        Thread,
        self,
        refreshCallback,
    );
}

fn stopRefreshTimer(self: *Thread) void {
    // This will stop the refresh on the next iteration.
    self.refresh_active = false;
}

fn syncRefreshTimer(self: *Thread) void {
    if (!shouldRunRefreshTimer(self.state, self.visible, self.focused)) {
        self.stopRefreshTimer();
        return;
    }

    self.startRefreshTimer();
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.warn("error in wakeup err={}", .{err});
        return .rearm;
    };

    const self = self_.?;

    // When we wake up, we drain the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    self.drainMailbox();

    return .rearm;
}

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

fn refreshCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const self: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("refresh callback fired without data set", .{});
        return .disarm;
    };

    // Run our feed if we have a search active. A step that ends the
    // search only stops the timer: it is re-armed below, not here.
    if (self.state != .idle) self.apply(.{ .refresh = true });

    // Only continue if we're still active
    if (self.refresh_active) self.refresh.run(
        &self.loop,
        &self.refresh_c,
        REFRESH_INTERVAL,
        Thread,
        self,
        refreshCallback,
    );

    return .disarm;
}

pub const Options = struct {
    /// Mutex that must be held while reading/writing the terminal.
    mutex: *Mutex,

    /// The terminal data to search.
    terminal: *Terminal,

    /// The callback for events from the search thread along with optional
    /// userdata. This can be null if you don't want to receive events,
    /// which could be useful for a one-time search (although, odd, you
    /// should use our search structures directly then).
    event_cb: ?EventCallback = null,
    event_userdata: ?*anyopaque = null,

    /// Initial surface visibility/focus state so the refresh timer doesn't
    /// start polling before the owning surface is interactive.
    visible: bool = true,
    focused: bool = true,
};

pub const EventCallback = *const fn (
    event: Event,
    generation: u64,
    userdata: ?*anyopaque,
) void;

/// The type used for sending messages to the thread.
pub const Mailbox = BlockingQueue(Message, 64);

/// The messages that can be sent to the thread.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);

    /// Change the search term. If no prior search term is given this
    /// will start a search. If an existing search term is given this will
    /// stop the prior search and start a new one.
    change_query: struct {
        generation: u64,
        options: QueryOptions,
        req: WriteReq,
    },

    /// Select a search result.
    select: ScreenSearch.Select,

    /// Surface visibility changed.
    visible: bool,

    /// Surface focus changed.
    focus: bool,
};

/// Events that can be emitted from the search thread. The caller
/// chooses to handle these as they see fit.
pub const Event = union(enum) {
    /// Search is quitting. The search thread is exiting.
    quit,

    /// Search is complete for the given needle on all screens.
    complete,

    /// Total matches on the current active screen have changed.
    total_matches: usize,

    /// Selected match changed.
    selected_match: ?SelectedMatch,

    /// Matches in the viewport have changed. The memory is owned by the
    /// search thread and is only valid during the callback.
    viewport_matches: []const FlattenedHighlight,

    /// Search match rows for the active screen, sorted ascending and unique.
    /// The memory is owned by the search thread and is only valid during
    /// the callback.
    match_rows: []const u32,

    /// The query cannot be searched for: a regular expression that does not
    /// compile, or options the build does not support. The search is cleared,
    /// as for `total_matches = 0`, which this event replaces, so a consumer
    /// can tell the query from one that matches nothing.
    invalid_query,

    pub const SelectedMatch = QuerySearch.Selected.Match;
};

const TestUserData = struct {
    const Self = @This();
    reset: std.Thread.ResetEvent = .{},
    events_seen: std.atomic.Value(u32) = .init(0),
    total: usize = 0,
    viewport: []FlattenedHighlight = &.{},
    rows: []u32 = &.{},

    fn deinit(self: *Self) void {
        for (self.viewport) |*hl| hl.deinit(testing.allocator);
        testing.allocator.free(self.viewport);
        testing.allocator.free(self.rows);
    }

    fn callback(event: Event, generation: u64, userdata: ?*anyopaque) void {
        _ = generation;
        const ud: *Self = @ptrCast(@alignCast(userdata.?));
        _ = ud.events_seen.fetchOr(@as(u32, 1) << @intFromEnum(std.meta.activeTag(event)), .release);
        switch (event) {
            .quit, .invalid_query, .selected_match => {},
            .complete => ud.reset.set(),
            .total_matches => |v| ud.total = v,
            .viewport_matches => |v| {
                for (ud.viewport) |*hl| hl.deinit(testing.allocator);
                testing.allocator.free(ud.viewport);

                ud.viewport = testing.allocator.alloc(
                    FlattenedHighlight,
                    v.len,
                ) catch unreachable;
                for (ud.viewport, v) |*dst, src| {
                    dst.* = src.clone(testing.allocator) catch unreachable;
                }
            },
            .match_rows => |v| {
                testing.allocator.free(ud.rows);
                ud.rows = testing.allocator.dupe(u32, v) catch unreachable;
            },
        }
    }
};

test {
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");

    var ud: TestUserData = .{};
    defer ud.deinit();
    var thread: Thread = try .init(alloc, .{
        .mutex = &mutex,
        .terminal = &t,
        .event_cb = &TestUserData.callback,
        .event_userdata = &ud,
    });
    defer thread.deinit();

    const Worker = struct {
        thread: *Thread,
        started: std.atomic.Value(bool) = .init(false),
        exited: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            defer self.exited.store(true, .release);
            self.thread.threadMain();
        }
    };
    var worker: Worker = .{ .thread = &thread };
    var timer = try std.time.Timer.start();
    {
        const os_thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        // In particular, a timed-out wait must not free the mailbox, IOCP
        // loop or callback data while the search thread still uses them.
        defer {
            thread.stop.notify() catch |err| {
                // No safe teardown or join is possible without stopping
                // the worker. Fail this test process instead of hanging.
                std.debug.panic("search-test stop notification failed err={}", .{err});
            };
            os_thread.join();
        }

        // Start our search.
        _ = thread.mailbox.push(
            .{ .change_query = .{
                .generation = 1,
                .options = .{},
                .req = try .init(alloc, @as([]const u8, "world")),
            } },
            .forever,
        );
        try thread.wakeup.notify();

        // Wait for the .complete callback, not a scheduling performance target.
        // The generous timeout only guards against a hung search. Atomic
        // observations diagnose failure without racing the worker's callbacks.
        ud.reset.timedWait(30 * std.time.ns_per_s) catch |err| {
            std.debug.print("search-test wait failed err={} elapsed_ns={d} started={} exited={} events:", .{
                err,
                timer.read(),
                worker.started.load(.acquire),
                worker.exited.load(.acquire),
            });
            const seen = ud.events_seen.load(.acquire);
            inline for (std.meta.fields(Event)) |field| {
                if (seen & (@as(u32, 1) << @intFromEnum(@field(std.meta.Tag(Event), field.name))) != 0) {
                    std.debug.print(" {s}", .{field.name});
                }
            }
            std.debug.print("\n", .{});
            return err;
        };
    }

    // 1 total matches
    try testing.expectEqual(1, ud.total);
    try testing.expectEqualSlices(u32, &.{0}, ud.rows);
    try testing.expectEqual(1, ud.viewport.len);
    {
        const sel = ud.viewport[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 11,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "search refresh timer requires active visible focused search" {
    try testing.expect(shouldRunRefreshTimer(.busy, true, true));
    try testing.expect(shouldRunRefreshTimer(.waiting, true, true));
    try testing.expect(!shouldRunRefreshTimer(.idle, true, true));
    try testing.expect(!shouldRunRefreshTimer(.busy, false, true));
    try testing.expect(!shouldRunRefreshTimer(.busy, true, false));

    // A step that leaves no search stops the polling.
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");

    var thread: Thread = try .init(alloc, .{ .mutex = &mutex, .terminal = &t });
    defer thread.deinit();
    thread.apply(.{ .query = .{ .needle = "world" } });
    try testing.expect(thread.state != .idle);

    thread.refresh_active = true;
    thread.apply(.{ .query = .{ .needle = "" } });
    try testing.expectEqual(QuerySearch.State.idle, thread.state);
    try testing.expect(!thread.refresh_active);
}

/// Records the order of the events it gets.
const OrderUserData = struct {
    tags: std.ArrayList(std.meta.Tag(Event)) = .empty,

    fn callback(event: Event, generation: u64, userdata: ?*anyopaque) void {
        _ = generation;
        const ud: *OrderUserData = @ptrCast(@alignCast(userdata.?));
        ud.tags.append(testing.allocator, std.meta.activeTag(event)) catch unreachable;
    }
};

test "a clear sends the total first and the selection last" {
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");

    var ud: OrderUserData = .{};
    defer ud.tags.deinit(alloc);
    var thread: Thread = try .init(alloc, .{
        .mutex = &mutex,
        .terminal = &t,
        .event_cb = &OrderUserData.callback,
        .event_userdata = &ud,
    });
    defer thread.deinit();

    thread.apply(.{ .query = .{ .needle = "world" } });
    ud.tags.clearRetainingCapacity();
    thread.apply(.{ .query = .{ .needle = "" } });
    try testing.expectEqualSlices(
        std.meta.Tag(Event),
        &.{ .total_matches, .viewport_matches, .match_rows, .selected_match },
        ud.tags.items,
    );
}

test "a query that runs out of memory does not stop the mailbox drain" {
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = std.math.maxInt(usize) });
    var thread: Thread = try .init(failing.allocator(), .{ .mutex = &mutex, .terminal = &t });
    defer thread.deinit();

    failing.fail_index = failing.alloc_index;
    _ = thread.mailbox.push(.{ .change_query = .{
        .generation = 1,
        .options = .{},
        .req = try .init(alloc, @as([]const u8, "world")),
    } }, .forever);
    _ = thread.mailbox.push(.{ .visible = false }, .forever);
    thread.drainMailbox();
    try testing.expect(failing.has_induced_failure);
    try testing.expect(!thread.visible);
}
