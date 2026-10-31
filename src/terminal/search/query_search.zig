//! The state of one search query over a terminal, driven by the search
//! thread (`Thread.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const UntrackedHighlight = @import("../highlight.zig").Untracked;
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const EventCallback = @import("Thread.zig").EventCallback;
const Pattern = @import("pattern.zig").Pattern;
const Query = @import("query_options.zig").Query;
const QueryOptions = @import("query_options.zig").QueryOptions;
const ScreenSearch = @import("screen.zig").ScreenSearch;
const ViewportSearch = @import("viewport.zig").ViewportSearch;

const log = std.log.scoped(.search_thread);

/// Search state. Public for `src/bench/search_stream.zig`, which drives
/// it the way `threadMain_` does.
pub const Search = struct {
    /// The query's compiled pattern, lent to every searcher. Null for a
    /// literal query.
    pattern: ?*Pattern,

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
    ) Pattern.CompileError!Search {
        const pattern = try Pattern.forQuery(alloc, .{
            .needle = needle,
            .options = query_options,
        });
        errdefer if (pattern) |p| p.destroy(alloc);

        var vp: ViewportSearch = try .initPattern(alloc, needle, pattern);
        errdefer vp.deinit();

        // We use dirty tracking for active area changes. Start with it
        // dirty so the first change is re-searched.
        vp.active_dirty = true;

        return .{
            .pattern = pattern,
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
        const alloc = self.viewport.window.alloc;
        self.match_rows.deinit(alloc);
        self.notified_match_rows.deinit(alloc);
        self.viewport.deinit();
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (self.screenIsValid(&t.screens, entry.key, entry.value)) {
                entry.value.deinit();
            } else {
                entry.value.deinitScreenInvalid();
            }
        }

        // Every searcher above borrowed it.
        if (self.pattern) |p| p.destroy(alloc);
    }

    /// The query's run-time pattern failure, which ends the query.
    pub fn failure(self: *const Search) ?Pattern.Failure {
        const p = self.pattern orelse return null;
        return p.failure();
    }

    /// The query this search runs. The needle is borrowed.
    pub fn query(self: *const Search) Query {
        return .{
            .needle = self.viewport.needle(),
            .options = if (self.pattern) |p| p.options else .{},
        };
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

    /// Scan copied data without the big lock. Returns overall progress.
    pub fn tick(self: *Search) Tick {
        var result: Tick = .complete;
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (entry.value.tick()) {
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
                const screen_search = ScreenSearch.initPattern(
                    alloc,
                    entry.value.*,
                    self.viewport.needle(),
                    self.pattern,
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
            while (self.viewport.next()) |hl| {
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
