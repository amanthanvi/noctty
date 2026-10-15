//! Search thread that handles searching a terminal for a string match.
//! This is expected to run on a dedicated thread to try to prevent too much
//! overhead to other terminal read/write operations.
//!
//! The current architecture of search does acquire global locks for accessing
//! terminal data, so there's still added contention, but we do our best to
//! minimize this by trading off memory usage (copying data to minimize lock
//! time).
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Mutex = std.Thread.Mutex;
const xev = @import("../../global.zig").xev;
const internal_os = @import("../../os/main.zig");
const BlockingQueue = @import("../../datastruct/main.zig").BlockingQueue;
const MessageData = @import("../../datastruct/main.zig").MessageData;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const UntrackedHighlight = @import("../highlight.zig").Untracked;
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Selection = @import("../Selection.zig");
const Terminal = @import("../Terminal.zig");

const QueryOptions = @import("query_options.zig").QueryOptions;
const ScreenSearch = @import("screen.zig").ScreenSearch;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const ViewportSearch = @import("viewport.zig").ViewportSearch;
const oni = if (build_options.oniguruma) @import("oniguruma") else struct {};

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

fn shouldRunRefreshTimer(has_search: bool, visible: bool, focused: bool) bool {
    return has_search and visible and focused;
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

/// Search state. Starts as null and is populated when a search is
/// started (a needle is given).
search: ?Search = null,

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

    if (self.search) |*s| {
        self.opts.mutex.lock();
        defer self.opts.mutex.unlock();
        s.deinit(self.opts.terminal);
    }
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

        const s: *Search = if (self.search) |*s| s else {
            // If we're not actively searching, we can block the loop
            // until it does some work.
            try self.loop.run(.once);
            continue;
        };

        // If we have an active search, we always send any pending
        // notifications. Even if the search is complete, there may be
        // notifications to send.
        if (self.opts.event_cb) |cb| {
            s.notify(
                self.alloc,
                cb,
                self.event_generation,
                self.opts.event_userdata,
                false,
            );
        }

        if (s.isComplete()) {
            // If our search is complete, there's no more work to do, we
            // can block until we have an xev action.
            try self.loop.run(.once);
            continue;
        }

        // Tick the search. This will trigger any event callbacks, lock
        // for data loading, etc.
        switch (s.tick(self.opts.mutex)) {
            // We're complete now when we were not before. Notify!
            .complete => {},

            // Forward progress was made.
            .progress => {},

            // All searches are blocked. Let's grab the lock and feed data.
            .blocked => {
                self.opts.mutex.lock();
                defer self.opts.mutex.unlock();
                s.feed(self.alloc, self.opts.terminal);
            },
        }

        // We have an active search, so we only want to process messages
        // we have but otherwise return immediately so we can continue the
        // search. If the above completed the search, we still want to
        // go around the loop as quickly as possible to send notifications,
        // and then we'll block on the loop next time.
        try self.loop.run(.no_wait);
    }
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
fn drainMailbox(self: *Thread) !void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .change_query => |v| {
                defer v.req.deinit();
                try self.changeQueryAndSyncRefreshTimer(
                    v.req.slice(),
                    v.options,
                    v.generation,
                );
            },
            .select => |v| try self.select(v),
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

fn select(self: *Thread, sel: ScreenSearch.Select) !void {
    const s = if (self.search) |*s| s else return;

    self.opts.mutex.lock();
    defer self.opts.mutex.unlock();

    // A screen can be removed or replaced between refresh ticks (and the
    // refresh timer stops while the surface is unfocused). Reconcile while
    // holding the terminal lock before touching any ScreenSearch pins.
    s.feed(self.alloc, self.opts.terminal);
    const screen_search = s.screens.getPtr(s.last_screen.key) orelse return;

    // With nothing selected yet, either direction starts at the newest match,
    // the one nearest the bottom of the screen. `.prev` alone would start at
    // the oldest, which sends the first Enter after typing to the top of the
    // scrollback.
    const dir: ScreenSearch.Select = if (screen_search.selected == null) .next else sel;

    // Make the selection. Ignore the result because we don't
    // care if the selection didn't change.
    _ = try screen_search.select(dir);

    // Grab our match if we have one. If we don't have a selection
    // then we do nothing.
    const flattened = screen_search.selectedMatch() orelse return;

    // No matter what we reset our selected match cache. This will
    // trigger a callback which will trigger the renderer to wake up
    // so it can be notified the screen scrolled.
    s.last_screen.selected = null;

    // Grab the current screen and see if this match is visible within
    // the viewport already. If it is, we do nothing.
    const screen = self.opts.terminal.screens.get(
        s.last_screen.key,
    ) orelse return;

    // Grab the viewport. Viewports and selections are usually small
    // so this check isn't very expensive, despite appearing O(N^2),
    // both Ns are usually equal to 1.
    var it = screen.pages.pageIterator(
        .right_down,
        .{ .viewport = .{} },
        null,
    );
    const hl_chunks = flattened.chunks.slice();
    while (it.next()) |chunk| {
        for (0..hl_chunks.len) |i| {
            const hl_chunk = hl_chunks.get(i);
            if (chunk.overlaps(.{
                .node = hl_chunk.node,
                .start = hl_chunk.start,
                .end = hl_chunk.end,
            })) return;
        }
    }

    screen.scroll(.{ .pin = flattened.startPin() });
}

fn changeQueryAndSyncRefreshTimer(
    self: *Thread,
    needle: []const u8,
    query_options: QueryOptions,
    generation: u64,
) !void {
    defer self.syncRefreshTimer();
    try self.changeQuery(needle, query_options, generation);
}

/// Change the search term to the given value.
fn changeQuery(
    self: *Thread,
    needle: []const u8,
    query_options: QueryOptions,
    generation: u64,
) !void {
    log.debug("changing search query len={} options={}", .{
        needle.len,
        query_options,
    });
    self.event_generation = generation;

    if (self.search) |*s| {
        // If our search is unchanged, do nothing.
        if (queryEquals(s.viewport.needle(), s.viewport.window.query_options, needle, query_options)) {
            // Reset clears both the viewport fingerprint and sliding-window
            // buffer, so the forced notify below rescans from a clean state.
            s.viewport.reset();
            s.stale_viewport_matches = true;

            {
                self.opts.mutex.lock();
                defer self.opts.mutex.unlock();
                s.feed(self.alloc, self.opts.terminal);
            }

            if (self.opts.event_cb) |cb| {
                s.notify(
                    self.alloc,
                    cb,
                    generation,
                    self.opts.event_userdata,
                    true,
                );
            }
            return;
        }
    }

    // Setup our search state. This comes before the previous search is
    // stopped so that a query that cannot be searched for is reported by the
    // one event that clears the previous results, not by a second one after
    // it (which a consumer would show as "no matches" first).
    var invalid = false;
    var out_of_memory = false;
    var next: ?Search = null;
    if (needle.len > 0) {
        if (Search.init(self.alloc, needle, query_options)) |search| {
            next = search;
        } else |err| switch (err) {
            error.OutOfMemory => out_of_memory = true,
            else => {
                log.warn("error initializing search query err={}", .{err});
                invalid = true;
            },
        }
    }

    // Stop the previous search. When the search changes then we need to emit
    // that it stopped.
    var cleared_previous = false;
    if (self.search) |*s| {
        {
            self.opts.mutex.lock();
            defer self.opts.mutex.unlock();
            s.deinit(self.opts.terminal);
        }
        self.search = null;
        cleared_previous = true;
    }
    if (cleared_previous or invalid) self.notifySearchCleared(invalid);

    // The previous search is gone even when the new one could not be set up:
    // its results would otherwise be published for the new query.
    if (out_of_memory) return error.OutOfMemory;

    // No needle means stop the search, and an invalid one starts none.
    self.search = next orelse return;

    // We need to grab the terminal lock and do an initial feed.
    self.opts.mutex.lock();
    defer self.opts.mutex.unlock();
    self.search.?.feed(self.alloc, self.opts.terminal);
}

/// Report that the search was cleared. The first event is the total of zero
/// matches, or for a query that cannot be searched for, `invalid_query`.
fn notifySearchCleared(self: *Thread, invalid: bool) void {
    if (self.opts.event_cb) |cb| {
        cb(
            if (invalid) .invalid_query else .{ .total_matches = 0 },
            self.event_generation,
            self.opts.event_userdata,
        );
        cb(
            .{ .selected_match = null },
            self.event_generation,
            self.opts.event_userdata,
        );
        cb(
            .{ .viewport_matches = &.{} },
            self.event_generation,
            self.opts.event_userdata,
        );
        // The previous Search is about to be discarded; do not mutate its
        // notified row snapshot just to publish the explicit clear event.
        cb(
            .{ .match_rows = &.{} },
            self.event_generation,
            self.opts.event_userdata,
        );
    }
}

fn queryEquals(
    prev_needle: []const u8,
    prev_options: QueryOptions,
    next_needle: []const u8,
    next_options: QueryOptions,
) bool {
    if (!prev_options.eql(next_options)) return false;

    if (next_options.regex or next_options.case_sensitive) {
        return std.mem.eql(u8, prev_needle, next_needle);
    }

    // Whole-word without explicit case sensitivity still uses the regex
    // engine's ignorecase path, so equivalent queries are ASCII-insensitive.
    return std.ascii.eqlIgnoreCase(prev_needle, next_needle);
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
    if (!shouldRunRefreshTimer(self.search != null, self.visible, self.focused)) {
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
    self.drainMailbox() catch |err|
        log.warn("error draining mailbox err={}", .{err});

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

    // Run our feed if we have a search active.
    if (self.search) |*s| {
        self.opts.mutex.lock();
        defer self.opts.mutex.unlock();
        s.feed(self.alloc, self.opts.terminal);
    }

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

    pub const SelectedMatch = struct {
        idx: usize,
        highlight: FlattenedHighlight,
    };
};

/// Search state. Public for `src/bench/search_stream.zig`, which drives
/// it the way `threadMain_` does.
pub const Search = struct {
    /// Active viewport search for the active screen.
    viewport: ViewportSearch,

    /// The searchers for all the screens.
    screens: std.EnumMap(ScreenSet.Key, ScreenSearch),

    /// ScreenSet generations captured when each searcher was initialized.
    /// Allocators may reuse a destroyed Screen address, so pointer equality
    /// alone cannot distinguish replacement screens from stale handles.
    screen_generations: std.EnumMap(ScreenSet.Key, usize),

    /// All state related to screen switches, collected so that when
    /// we switch screens it makes everything related stale, too.
    last_screen: ScreenState,

    /// True if we sent the complete notification yet.
    last_complete: bool,

    /// The last viewport matches we found.
    stale_viewport_matches: bool,

    /// Match rows for the active screen. Rebuilt while the terminal lock
    /// is held so downstream consumers never have to touch terminal state.
    match_rows: std.ArrayList(u32),

    /// Inputs used to build the current match row snapshot.
    match_rows_screen: ?ScreenSet.Key,
    match_rows_revision: u64,

    /// Last match rows snapshot emitted to the callback.
    notified_match_rows: std.ArrayList(u32),

    const ScreenState = struct {
        /// Last active screen key
        key: ScreenSet.Key,

        /// Last notified total matches count
        total: ?usize = null,

        /// Last notified selected match index
        selected: ?SelectedMatch = null,

        const SelectedMatch = struct {
            idx: usize,
            highlight: UntrackedHighlight,
        };
    };

    pub fn init(
        alloc: Allocator,
        needle: []const u8,
        query_options: QueryOptions,
    ) SlidingWindow.InitError!Search {
        var vp: ViewportSearch = try .initWithOptions(alloc, needle, query_options);
        errdefer vp.deinit();

        // We use dirty tracking for active area changes. Start with it
        // dirty so the first change is re-searched.
        vp.active_dirty = true;

        return .{
            .viewport = vp,
            .screens = .init(.{}),
            .screen_generations = .init(.{}),
            .last_screen = .{ .key = .primary },
            .last_complete = false,
            .stale_viewport_matches = true,
            .match_rows = .empty,
            .match_rows_screen = null,
            .match_rows_revision = 0,
            .notified_match_rows = .empty,
        };
    }

    /// The caller must hold the terminal lock: a searcher whose screen is
    /// still alive untracks its pins from that screen's PageList.
    pub fn deinit(self: *Search, t: *Terminal) void {
        self.match_rows.deinit(self.viewport.window.alloc);
        self.notified_match_rows.deinit(self.viewport.window.alloc);
        self.viewport.deinit();
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (self.screenIsValid(&t.screens, entry.key, entry.value)) {
                entry.value.deinit();
            } else {
                entry.value.deinitScreenInvalid();
            }
        }
    }

    fn screenIsValid(
        self: *const Search,
        screens: *const ScreenSet,
        key: ScreenSet.Key,
        search: *const ScreenSearch,
    ) bool {
        const generation = self.screen_generations.get(key) orelse return false;
        if (generation != screens.generation(key)) return false;
        const actual = screens.get(key) orelse return false;
        return actual == search.screen;
    }

    /// Returns true if all searches on all screens are complete.
    pub fn isComplete(self: *Search) bool {
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (!entry.value.state.isComplete()) return false;
        }

        return true;
    }

    pub const Tick = enum {
        /// All searches are complete.
        complete,

        /// Progress was made on at least one screen.
        progress,

        /// All incomplete searches are blocked on feed.
        blocked,
    };

    /// Scan copied data without the big lock, taking it only for failure
    /// cleanup that releases screen-owned pins. Returns overall progress.
    pub fn tick(self: *Search, mutex: *Mutex) Tick {
        var result: Tick = .complete;
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (entry.value.tickWithMutex(mutex)) {
                result = .progress;
            } else |err| switch (err) {
                // Ignore... nothing we can do.
                error.OutOfMemory => log.warn(
                    "error ticking screen search key={} err={}",
                    .{ entry.key, err },
                ),

                // Ignore, good for us. State remains whatever it is.
                error.SearchComplete => {},

                // Ignore, too, progressed
                error.FeedRequired => switch (result) {
                    // If we think we're complete, we're not because we're
                    // blocked now (nothing made progress).
                    .complete => result = .blocked,

                    // If we made some progress, we remain in progress
                    // since blocked means no progress at all.
                    .progress => {},

                    // If we're blocked already then we remain blocked.
                    .blocked => {},
                },
            }
        }

        // log.debug("tick result={}", .{result});
        return result;
    }

    fn clearMatchRowsCache(self: *Search) void {
        self.match_rows.clearRetainingCapacity();
        self.match_rows_screen = null;
        self.match_rows_revision = 0;
    }

    /// Grab the mutex and update any state that requires it, such as
    /// feeding additional data to the searches or updating the active screen.
    pub fn feed(
        self: *Search,
        alloc: Allocator,
        t: *Terminal,
    ) void {
        // Update our active screen
        if (t.screens.active_key != self.last_screen.key) {
            // The default values will force resets of a bunch of other
            // state too to force recalculations and notifications.
            self.last_screen = .{ .key = t.screens.active_key };
        }

        // Reconcile our screens with the terminal screens. Remove
        // searchers for screens that no longer exist and add searchers
        // for screens that do exist but we don't have yet.
        {
            // Remove screens we have that no longer exist or were destroyed
            // and rebuilt (possibly at the same address) since.
            var it = self.screens.iterator();
            while (it.next()) |entry| {
                if (!self.screenIsValid(&t.screens, entry.key, entry.value)) {
                    if (self.match_rows_screen) |key| {
                        if (key == entry.key) self.clearMatchRowsCache();
                    }
                    entry.value.deinitScreenInvalid();
                    _ = self.screens.remove(entry.key);
                    _ = self.screen_generations.remove(entry.key);
                }
            }
        }
        {
            // Add screens that exist but we don't have yet.
            var it = t.screens.all.iterator();
            while (it.next()) |entry| {
                if (self.screens.contains(entry.key)) continue;
                const screen_search = ScreenSearch.initWithOptions(
                    alloc,
                    entry.value.*,
                    self.viewport.needle(),
                    self.viewport.window.query_options,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        // OOM is probably going to sink the entire ship but
                        // we can just ignore it and wait on the next
                        // reconciliation to try again.
                        log.warn(
                            "error initializing screen search for key={} err={}",
                            .{ entry.key, err },
                        );
                        continue;
                    },
                    else => {
                        log.warn(
                            "error initializing screen search for key={} err={}",
                            .{ entry.key, err },
                        );
                        continue;
                    },
                };
                self.screens.put(entry.key, screen_search);
                self.screen_generations.put(
                    entry.key,
                    t.screens.generation(entry.key),
                );
            }
        }

        // See the `search_viewport_dirty` flag on the terminal to know
        // what exactly this is for. But, if this is set, we know the renderer
        // found the viewport/active area dirty, so we should mark it as
        // dirty in our viewport searcher so it forces a re-search.
        if (t.flags.search_viewport_dirty) {
            t.flags.search_viewport_dirty = false;

            // Mark our viewport dirty so it researches the active
            self.viewport.active_dirty = true;

            // Reload our active area for our active screen
            if (self.screens.getPtr(t.screens.active_key)) |screen_search| {
                screen_search.reloadActive() catch |err| switch (err) {
                    error.OutOfMemory => log.warn(
                        "error reloading active area for screen key={} err={}",
                        .{ t.screens.active_key, err },
                    ),
                };
            }
        }

        // Check our viewport for changes.
        if (self.viewport.update(&t.screens.active.pages)) |updated| {
            if (updated) self.stale_viewport_matches = true;
        } else |err| switch (err) {
            error.OutOfMemory => log.warn(
                "error updating viewport search err={}",
                .{err},
            ),
        }

        // Feed data
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (entry.value.state.needsFeed()) {
                entry.value.feed() catch |err| switch (err) {
                    error.OutOfMemory => log.warn(
                        "error feeding screen search key={} err={}",
                        .{ entry.key, err },
                    ),
                };
            }
        }

        const screen_search = self.screens.getPtr(self.last_screen.key) orelse {
            self.clearMatchRowsCache();
            return;
        };
        const match_rows_revision = screen_search.matchRowsRevision();
        const same_match_rows_screen = if (self.match_rows_screen) |key|
            key == self.last_screen.key
        else
            false;
        if (same_match_rows_screen and
            self.match_rows_revision == match_rows_revision) return;

        self.rebuildMatchRows(alloc, screen_search) catch |err| {
            log.warn("error rebuilding search match rows err={}", .{err});
            return;
        };
        self.match_rows_screen = self.last_screen.key;
        self.match_rows_revision = match_rows_revision;
    }

    /// Notify about any changes to the search state.
    ///
    /// This doesn't require any locking as it only reads internal state.
    pub fn notify(
        self: *Search,
        alloc: Allocator,
        cb: EventCallback,
        generation: u64,
        ud: ?*anyopaque,
        force: bool,
    ) void {
        const screen_search = self.screens.get(self.last_screen.key) orelse return;

        // Check our total match data
        const total = screen_search.matchesLen();
        if (force or total != self.last_screen.total) {
            log.debug("notifying total matches={}", .{total});
            self.last_screen.total = total;
            cb(.{ .total_matches = total }, generation, ud);
        }

        // Check our viewport matches. If they're stale, we do the
        // viewport search now. We do this as part of notify and not
        // tick because the viewport search is very fast and doesn't
        // require ticked progress or feeds.
        if (force or self.stale_viewport_matches) viewport: {
            // We always make stale as false. Even if we fail below
            // we require a re-feed to re-search the viewport. The feed
            // process will make it stale again.
            self.stale_viewport_matches = false;

            var arena: ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();
            var results: std.ArrayList(FlattenedHighlight) = .empty;
            while (self.viewport.next() catch |err| {
                log.warn("error collecting viewport matches err={}", .{err});
                self.viewport.reset();
                break :viewport;
            }) |hl| {
                const hl_cloned = hl.clone(arena_alloc) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn(
                            "error collecting viewport matches err={}",
                            .{err},
                        );

                        // Reset the viewport so we force an update on the
                        // next feed instead of notifying a partial match set.
                        self.viewport.reset();
                        break :viewport;
                    },
                };
                results.append(arena_alloc, hl_cloned) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn(
                            "error collecting viewport matches err={}",
                            .{err},
                        );

                        // Reset the viewport so we force an update on the
                        // next feed.
                        self.viewport.reset();
                        break :viewport;
                    },
                };
            }

            log.debug("notifying viewport matches len={}", .{results.items.len});
            cb(.{ .viewport_matches = results.items }, generation, ud);
        }

        if (force or !std.mem.eql(u32, self.match_rows.items, self.notified_match_rows.items)) match_rows: {
            self.notified_match_rows.ensureTotalCapacity(
                alloc,
                self.match_rows.items.len,
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    log.warn("error caching notified search match rows err={}", .{err});
                    break :match_rows;
                },
            };
            self.notified_match_rows.clearRetainingCapacity();
            self.notified_match_rows.appendSliceAssumeCapacity(self.match_rows.items);

            log.debug("notifying search match rows len={}", .{self.match_rows.items.len});
            cb(.{ .match_rows = self.match_rows.items }, generation, ud);
        }

        // Check our last selected match data.
        if (screen_search.selected) |m| match: {
            const flattened = screen_search.selectedMatch() orelse break :match;
            const untracked = flattened.untracked();
            if (self.last_screen.selected) |prev| {
                if (!force and prev.idx == m.idx and prev.highlight.eql(untracked)) {
                    // Same selection, don't update it.
                    break :match;
                }
            }

            // New selection, notify!
            self.last_screen.selected = .{
                .idx = m.idx,
                .highlight = untracked,
            };

            log.debug("notifying selection updated idx={}", .{m.idx});
            cb(
                .{ .selected_match = .{
                    .idx = m.idx,
                    .highlight = flattened,
                } },
                generation,
                ud,
            );
        } else if (force or self.last_screen.selected != null) {
            log.debug("notifying selection cleared", .{});
            self.last_screen.selected = null;
            cb(
                .{ .selected_match = null },
                generation,
                ud,
            );
        }

        // Send our complete notification if we just completed.
        if (!self.last_complete and self.isComplete()) {
            log.debug("notifying search complete", .{});
            self.last_complete = true;
            cb(.complete, generation, ud);
        }
    }

    fn rebuildMatchRows(
        self: *Search,
        alloc: Allocator,
        screen_search: *ScreenSearch,
    ) Allocator.Error!void {
        try screen_search.collectMatchRows(alloc, &self.match_rows);
    }
};

const TestUserData = struct {
    const Self = @This();
    reset: std.Thread.ResetEvent = .{},
    total: usize = 0,
    total_events: usize = 0,
    invalid: bool = false,
    selected: ?Event.SelectedMatch = null,
    viewport: []FlattenedHighlight = &.{},
    rows: []u32 = &.{},

    fn deinit(self: *Self) void {
        for (self.viewport) |*hl| hl.deinit(testing.allocator);
        testing.allocator.free(self.viewport);
        testing.allocator.free(self.rows);
    }

    fn clearObserved(self: *Self) void {
        for (self.viewport) |*hl| hl.deinit(testing.allocator);
        testing.allocator.free(self.viewport);
        testing.allocator.free(self.rows);

        self.total = 0;
        self.invalid = false;
        self.selected = null;
        self.viewport = &.{};
        self.rows = &.{};
    }

    fn callback(event: Event, generation: u64, userdata: ?*anyopaque) void {
        _ = generation;
        const ud: *Self = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .quit => {},
            .complete => ud.reset.set(),
            .total_matches => |v| {
                ud.total = v;
                ud.total_events += 1;
            },
            .invalid_query => ud.invalid = true,
            .selected_match => |v| ud.selected = v,
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

    var os_thread = try std.Thread.spawn(
        .{},
        threadMain,
        .{&thread},
    );

    // Start our search
    _ = thread.mailbox.push(
        .{ .change_query = .{
            .generation = 1,
            .options = .{},
            .req = try .init(
                alloc,
                @as([]const u8, "world"),
            ),
        } },
        .forever,
    );
    try thread.wakeup.notify();

    // Wait for completion
    try ud.reset.timedWait(100 * std.time.ns_per_ms);

    // Stop the thread
    try thread.stop.notify();
    os_thread.join();

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
    try testing.expect(shouldRunRefreshTimer(true, true, true));
    try testing.expect(!shouldRunRefreshTimer(false, true, true));
    try testing.expect(!shouldRunRefreshTimer(true, false, true));
    try testing.expect(!shouldRunRefreshTimer(true, true, false));
}

test "invalid regex query clears search and stops refresh polling" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const alloc = testing.allocator;
    try oni.testing.ensureInit();

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

    try thread.changeQuery("world", .{}, 1);
    try testing.expect(thread.search != null);

    thread.refresh_active = true;
    try thread.changeQueryAndSyncRefreshTimer("[", .{ .regex = true }, 2);

    try testing.expect(thread.search == null);
    try testing.expect(!thread.refresh_active);
    try testing.expectEqual(0, ud.total);
    try testing.expectEqual(0, ud.viewport.len);
    try testing.expectEqualSlices(u32, &.{}, ud.rows);
    // The invalid query is the clear of the previous search. A zero total
    // before it would show as "no matches" for a moment.
    try testing.expect(ud.invalid);
    try testing.expectEqual(0, ud.total_events);
}

test "a query that matches nothing is not reported as invalid" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const alloc = testing.allocator;
    try oni.testing.ensureInit();

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

    // A valid regex with no match, and a literal that holds regex syntax.
    try thread.changeQuery("w[x]+", .{ .regex = true }, 1);
    try testing.expect(thread.search != null);
    try thread.changeQuery("[", .{}, 2);
    try testing.expect(thread.search != null);
    try testing.expect(!ud.invalid);

    // The invalid pattern reports itself once per query, whether or not a
    // search was running, and the next valid query searches again.
    try thread.changeQuery("[", .{ .regex = true }, 3);
    try testing.expect(thread.search == null);
    try testing.expect(ud.invalid);
    ud.invalid = false;
    try thread.changeQuery("(", .{ .regex = true }, 4);
    try testing.expect(thread.search == null);
    try testing.expect(ud.invalid);
    ud.invalid = false;
    try thread.changeQuery("world", .{ .regex = true }, 5);
    try testing.expect(thread.search != null);
    try testing.expect(!ud.invalid);
}

test "a query that runs out of memory still stops the previous search" {
    // The new query already owns the event generation, so the previous
    // search must not keep publishing results under it.
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

    try thread.changeQuery("world", .{}, 1);
    try testing.expect(thread.search != null);

    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    thread.alloc = failing.allocator();
    defer thread.alloc = alloc;
    try testing.expectError(error.OutOfMemory, thread.changeQuery("hello", .{}, 2));

    try testing.expect(thread.search == null);
    try testing.expect(!ud.invalid);
    try testing.expectEqual(1, ud.total_events);
}

test "equivalent query replays search state" {
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

    try thread.changeQuery("world", .{}, 1);
    if (thread.search) |*s| {
        s.notify(alloc, &TestUserData.callback, 1, &ud, false);
    }
    try testing.expectEqual(1, ud.total);
    try testing.expectEqualSlices(u32, &.{0}, ud.rows);
    try testing.expectEqual(1, ud.viewport.len);

    ud.clearObserved();
    try thread.changeQuery("world", .{}, 2);

    try testing.expectEqual(1, ud.total);
    try testing.expectEqualSlices(u32, &.{0}, ud.rows);
    try testing.expectEqual(1, ud.viewport.len);
}

test "notified match rows follow streamed output while the scrollback is pruned" {
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};

    // Room for about three pages, so the output below prunes the oldest.
    const page_size = page_size: {
        var probe: Terminal = try .init(alloc, .{ .cols = 20, .rows = 4 });
        defer probe.deinit(alloc);
        break :page_size probe.screens.active.pages.page_size;
    };
    var t: Terminal = try .init(alloc, .{
        .cols = 20,
        .rows = 4,
        .max_scrollback = 3 * page_size,
    });
    defer t.deinit(alloc);
    const list = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();
    const lines = [_][]const u8{ "Fizz Fizz\r\n", "noop\r\n", "x Fizz\r\n" };
    var line: usize = 0;
    while (list.totalPages() < 2) : (line += 1) stream.nextSlice(lines[line % lines.len]);

    var ud: TestUserData = .{};
    defer ud.deinit();
    var thread: Thread = try .init(alloc, .{
        .mutex = &mutex,
        .terminal = &t,
        .event_cb = &TestUserData.callback,
        .event_userdata = &ud,
    });
    defer thread.deinit();
    try thread.changeQuery("Fizz", .{}, 1);
    const s = &thread.search.?;

    var rounds: usize = 0;
    while (rounds < 4 or list.page_serial_min == 0) : (rounds += 1) {
        if (rounds > 10_000) return error.TestScrollbackNeverPruned;

        // What the search thread does until the search completes.
        while (true) {
            s.notify(alloc, &TestUserData.callback, 1, &ud, false);
            if (s.isComplete()) break;
            if (s.tick(&mutex) == .blocked) s.feed(alloc, &t);
        }

        // The rows `pointFromPin` gives for every match.
        var expected: std.ArrayList(u32) = .empty;
        defer expected.deinit(alloc);
        const screen_search = s.screens.getPtr(.primary).?;
        for ([_][]const FlattenedHighlight{
            screen_search.active_results.items,
            screen_search.history_results.items,
        }) |results| for (results) |hl| {
            const pt = list.pointFromPin(.screen, hl.startPin()) orelse continue;
            try expected.append(alloc, pt.screen.y);
        };
        std.mem.sort(u32, expected.items, {}, std.sort.asc(u32));
        var write: usize = 0;
        for (expected.items) |row| {
            if (write > 0 and expected.items[write - 1] == row) continue;
            expected.items[write] = row;
            write += 1;
        }
        try testing.expect(write > 0);
        try testing.expectEqualSlices(u32, expected.items[0..write], ud.rows);

        // More output, then a refresh as the renderer would trigger one.
        for (0..200) |_| {
            stream.nextSlice(lines[line % lines.len]);
            line += 1;
        }
        t.flags.search_viewport_dirty = true;
        s.feed(alloc, &t);
    }
}

test "select after the searched screen is removed" {
    // Upstream 73ac36fa5679: a select between refresh ticks must not reach
    // the searcher of a screen the terminal has already destroyed.
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?1049hneedle");

    var thread: Thread = try .init(alloc, .{ .mutex = &mutex, .terminal = &t });
    defer thread.deinit();

    try thread.changeQuery("needle", .{}, 1);
    try thread.select(.next);
    try testing.expectEqual(ScreenSet.Key.alternate, thread.search.?.last_screen.key);
    try testing.expect(thread.search.?.screens.getPtr(.alternate).?.selected != null);

    _ = try t.switchScreen(.primary);
    t.screens.remove(alloc, .alternate);

    try thread.select(.next);
    try testing.expectEqual(ScreenSet.Key.primary, thread.search.?.last_screen.key);
    try testing.expect(!thread.search.?.screens.contains(.alternate));
}

test "the first select with nothing selected starts at the newest match" {
    // `.prev` from no selection used to pick the oldest match, so the first
    // Enter after typing a query scrolled to the top of the scrollback.
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};

    for ([_]ScreenSearch.Select{ .next, .prev }) |first| {
        var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 4 });
        defer t.deinit(alloc);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice("needle a\r\nneedle b\r\nneedle c");

        var thread: Thread = try .init(alloc, .{ .mutex = &mutex, .terminal = &t });
        defer thread.deinit();
        try thread.changeQuery("needle", .{}, 1);

        try thread.select(first);
        const searcher = thread.search.?.screens.getPtr(.primary).?;
        try testing.expectEqual(@as(usize, 0), searcher.selected.?.idx);
        const row = t.screens.active.pages.pointFromPin(
            .screen,
            searcher.selectedMatch().?.startPin(),
        ).?;
        try testing.expectEqual(@as(u32, 2), row.screen.y);

        // Once something is selected, `.prev` steps toward the newer matches
        // as before, which wraps past the newest to the oldest.
        try thread.select(.prev);
        try testing.expectEqual(
            @as(usize, 2),
            thread.search.?.screens.getPtr(.primary).?.selected.?.idx,
        );
    }
}

/// Keeps the last freed block of one size and hands it to the next allocation
/// of that size, as a real allocator may: a Screen destroyed by a full reset
/// then comes back at the same address when the alternate screen is
/// re-entered.
const ReuseAllocator = struct {
    backing: Allocator,
    len: usize,
    held: ?struct { ptr: [*]u8, alignment: std.mem.Alignment } = null,

    fn allocator(self: *ReuseAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn deinit(self: *ReuseAllocator) void {
        const held = self.held orelse return;
        self.backing.rawFree(held.ptr[0..self.len], held.alignment, @returnAddress());
        self.held = null;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ReuseAllocator = @ptrCast(@alignCast(ctx));
        if (self.held) |held| if (len == self.len and held.alignment == alignment) {
            self.held = null;
            return held.ptr;
        };
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ReuseAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ReuseAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ReuseAllocator = @ptrCast(@alignCast(ctx));
        if (memory.len == self.len and self.held == null) {
            @memset(memory, undefined);
            self.held = .{ .ptr = memory.ptr, .alignment = alignment };
            return;
        }
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "a full reset that re-creates the alternate screen at the same address drops its searcher" {
    const alloc = testing.allocator;
    var reuse: ReuseAllocator = .{ .backing = alloc, .len = @sizeOf(Screen) };
    defer reuse.deinit();
    const term_alloc = reuse.allocator();

    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(term_alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(term_alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[?1049hneedle");

    var thread: Thread = try .init(alloc, .{ .mutex = &mutex, .terminal = &t });
    defer thread.deinit();

    try thread.changeQuery("needle", .{}, 1);
    try thread.select(.next);
    const destroyed = t.screens.get(.alternate).?;
    try testing.expect(thread.search.?.screens.getPtr(.alternate).?.selected != null);

    // RIS destroys the alternate screen; re-entering it builds a new one.
    stream.nextSlice("\x1bc\x1b[?1049h");
    const rebuilt = t.screens.get(.alternate).?;
    try testing.expectEqual(destroyed, rebuilt);

    // A refresh must not keep the destroyed screen's results and tracked
    // selection just because the new screen has the same address.
    {
        mutex.lock();
        defer mutex.unlock();
        thread.search.?.feed(alloc, &t);
    }
    const searcher = thread.search.?.screens.getPtr(.alternate).?;
    try testing.expectEqual(rebuilt, searcher.screen);
    try testing.expectEqual(
        t.screens.generation(.alternate),
        thread.search.?.screen_generations.get(.alternate).?,
    );
    try testing.expectEqual(@as(usize, 0), searcher.matchesLen());
    try testing.expect(searcher.selected == null);

    try thread.select(.next);
    try testing.expect(thread.search.?.screens.getPtr(.alternate).?.selected == null);
}
