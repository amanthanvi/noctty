//! One search query over a terminal, stepped by one thread: which query
//! runs, when the terminal is read under its lock, what changed since the
//! last report, where the first select goes, and ending a query whose
//! pattern fails at run time. The search thread (`Thread.zig`) is a shell
//! that turns each `Report` into events.
const std = @import("std");
const build_options = @import("terminal_options");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const UntrackedHighlight = @import("../highlight.zig").Untracked;
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const Pattern = @import("pattern.zig").Pattern;
const Query = @import("query_options.zig").Query;
const QueryOptions = @import("query_options.zig").QueryOptions;
const ScreenSearch = @import("screen.zig").ScreenSearch;
const ViewportSearch = @import("viewport.zig").ViewportSearch;
const oni = if (build_options.oniguruma) @import("oniguruma") else struct {};

const log = std.log.scoped(.search_thread);

pub const QuerySearch = struct {
    alloc: Allocator,
    term: Term,

    /// The running query, if any.
    search: ?Search = null,

    pub const Term = struct {
        terminal: *Terminal,

        /// Must be held while the terminal is read or written. `step` and
        /// `deinit` take it themselves, so their caller must not hold it:
        /// a Debug build panics with "Deadlock detected" and a release
        /// build hangs.
        mutex: *std.Thread.Mutex,
    };

    pub const Request = struct {
        /// Set, change or clear ("") the query. An equivalent query
        /// replays everything.
        query: ?Query = null,

        /// The terminal may have changed.
        refresh: bool = false,

        /// Select a match. `.next` goes toward older matches.
        select: ?ScreenSearch.Select = null,
    };

    pub const State = enum {
        /// No search, so a refresh is pointless.
        idle,

        /// Step again with an empty request after polling input.
        busy,

        /// Caught up: step again on the next refresh, query or select.
        waiting,
    };

    pub const Total = union(enum) {
        count: usize,

        /// The query cannot be searched for: a pattern that does not
        /// compile, or options the build does not support.
        invalid,
    };

    pub const Selected = union(enum) {
        none,
        match: struct {
            /// From the newest match, 0 being the newest.
            idx: usize,
            highlight: FlattenedHighlight,
        },
    };

    /// What changed since the previous report: a null field did not. A
    /// query that starts a search, clears one or is invalid reports every
    /// field, and an equivalent query replays every field. Slices are
    /// borrowed until the next step or deinit.
    pub const Report = struct {
        state: State,
        total: ?Total = null,
        viewport_matches: ?[]const FlattenedHighlight = null,

        /// The screen rows of the matches, ascending and unique.
        match_rows: ?[]const u32 = null,
        selected: ?Selected = null,
        complete: bool = false,
    };

    /// Idle until the first query. Allocates nothing.
    pub fn init(alloc: Allocator, term: Term) QuerySearch {
        return .{ .alloc = alloc, .term = term };
    }

    /// Takes the terminal lock to release the search's pins.
    pub fn deinit(self: *QuerySearch) void {
        self.stop();
    }

    /// Handle `req`: its query, then a refresh, then a select. A request
    /// with none of them makes one bounded slice of progress instead (one
    /// tick round, plus one locked feed if every screen is blocked). Then
    /// report what changed.
    ///
    /// Out of memory is logged and retried at the next refresh; a new
    /// query that runs out of memory still ends the previous one. A
    /// pattern that fails at run time ends the query: one clear, then idle.
    pub fn step(self: *QuerySearch, req: Request) Report {
        var force = false;
        if (req.query) |query| switch (self.changeQuery(query)) {
            .started => {},
            .replay => force = true,
            .cleared => |total| return self.cleared(total),
        };
        if (req.refresh) self.refresh();
        if (req.select) |to| self.select(to);

        const s = if (self.search) |*s| s else return .{ .state = .idle };

        // A search reports what its query, refresh or select left before it
        // makes progress, as the search thread notified before it ticked.
        const slice = req.query == null and !req.refresh and req.select == null;
        if (slice and s.reported and !s.isComplete()) {
            switch (s.tick()) {
                .complete, .progress => {},
                .blocked => {
                    self.term.mutex.lock();
                    defer self.term.mutex.unlock();
                    s.feed(self.alloc, self.term.terminal);
                },
            }
        }

        // A failed pattern finds nothing from then on, in any searcher.
        if (s.failure()) |err| {
            log.warn("search query ended by a pattern failure err={}", .{err});
            self.stop();
            return self.cleared(.{ .count = 0 });
        }

        var report = s.report(self.alloc, force);
        report.state = if (s.isComplete()) .waiting else .busy;
        return report;
    }

    const QueryChange = union(enum) {
        /// A new search started without ending another, or nothing changed.
        started,

        /// The query is equivalent to the running one.
        replay,

        /// The running search ended, or the query is invalid.
        cleared: Total,
    };

    fn changeQuery(self: *QuerySearch, query: Query) QueryChange {
        log.debug("changing search query len={} options={}", .{
            query.needle.len,
            query.options,
        });

        if (self.search) |*s| {
            if (s.query().eql(query)) {
                // Reset clears both the viewport fingerprint and sliding-window
                // buffer, so the forced report rescans from a clean state.
                s.viewport.reset();
                s.stale_viewport_matches = true;

                self.term.mutex.lock();
                defer self.term.mutex.unlock();
                s.feed(self.alloc, self.term.terminal);
                return .replay;
            }
        }

        // Compile before the previous search stops, so a query that cannot be
        // searched for is reported by the one clear of the previous results,
        // not by a second one after it (which would show "no matches" first).
        var invalid = false;
        var next: ?Search = null;
        if (query.needle.len > 0) {
            if (Search.init(self.alloc, query.needle, query.options)) |search| {
                next = search;
            } else |err| switch (err) {
                // The previous search still stops: its results would
                // otherwise be reported for the new query.
                error.OutOfMemory => log.warn("error initializing search query err={}", .{err}),
                error.InvalidPattern, error.UnsupportedQueryOptions => {
                    log.warn("error initializing search query err={}", .{err});
                    invalid = true;
                },
            }
        }

        const replaced = self.search != null;
        self.stop();

        // No needle means stop the search, and an invalid one starts none.
        self.search = next;
        if (self.search) |*s| {
            self.term.mutex.lock();
            defer self.term.mutex.unlock();
            s.feed(self.alloc, self.term.terminal);
        }

        if (invalid) return .{ .cleared = .invalid };
        if (replaced) return .{ .cleared = .{ .count = 0 } };
        return .started;
    }

    /// Every field cleared, with the total `total`.
    fn cleared(self: *const QuerySearch, total: Total) Report {
        return .{
            .state = if (self.search != null) .busy else .idle,
            .total = total,
            .viewport_matches = &.{},
            .match_rows = &.{},
            .selected = .none,
        };
    }

    fn refresh(self: *QuerySearch) void {
        const s = if (self.search) |*s| s else return;
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        s.feed(self.alloc, self.term.terminal);
    }

    fn select(self: *QuerySearch, to: ScreenSearch.Select) void {
        const s = if (self.search) |*s| s else return;
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        s.select(self.alloc, self.term.terminal, to) catch |err|
            log.warn("error selecting search match err={}", .{err});
    }

    fn stop(self: *QuerySearch) void {
        const s = if (self.search) |*s| s else return;
        {
            self.term.mutex.lock();
            defer self.term.mutex.unlock();
            s.deinit(self.term.terminal);
        }
        self.search = null;
    }
};

/// Search state: the searchers of one query, and what has been reported.
const Search = struct {
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

    /// True if we reported the completion yet.
    last_complete: bool,

    /// True once anything has been reported.
    reported: bool,

    /// The last viewport matches we found.
    stale_viewport_matches: bool,

    /// The viewport matches last reported.
    viewport_matches: std.ArrayList(FlattenedHighlight),

    /// Match rows for the active screen. Rebuilt while the terminal lock
    /// is held so downstream consumers never have to touch terminal state.
    match_rows: std.ArrayList(u32),

    /// Inputs used to build the current match row snapshot.
    match_rows_screen: ?ScreenSet.Key,
    match_rows_revision: u64,

    /// Last match rows snapshot reported.
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

    fn init(
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
            .reported = false,
            .stale_viewport_matches = true,
            .viewport_matches = .empty,
            .match_rows = .empty,
            .match_rows_screen = null,
            .match_rows_revision = 0,
            .notified_match_rows = .empty,
        };
    }

    /// The caller must hold the terminal lock: a searcher whose screen is
    /// still alive untracks its pins from that screen's PageList.
    fn deinit(self: *Search, t: *Terminal) void {
        const alloc = self.viewport.window.alloc;
        self.clearViewportMatches();
        self.viewport_matches.deinit(alloc);
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
    fn failure(self: *const Search) ?Pattern.Failure {
        const p = self.pattern orelse return null;
        return p.failure();
    }

    /// The query this search runs. The needle is borrowed.
    fn query(self: *const Search) Query {
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
    fn isComplete(self: *Search) bool {
        var it = self.screens.iterator();
        while (it.next()) |entry| {
            if (!entry.value.state.isComplete()) return false;
        }

        return true;
    }

    const Tick = enum {
        /// All searches are complete.
        complete,

        /// Progress was made on at least one screen.
        progress,

        /// All incomplete searches are blocked on feed.
        blocked,
    };

    /// Scan copied data without the big lock. Returns overall progress.
    fn tick(self: *Search) Tick {
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

    /// Update any state that requires the terminal, such as feeding
    /// additional data to the searches or updating the active screen. The
    /// caller must hold the terminal lock.
    fn feed(
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

        screen_search.collectMatchRows(alloc, &self.match_rows) catch |err| {
            log.warn("error rebuilding search match rows err={}", .{err});
            return;
        };
        self.match_rows_screen = self.last_screen.key;
        self.match_rows_revision = match_rows_revision;
    }

    /// Select a match on the active screen, scrolling to it when it is not
    /// visible. The caller must hold the terminal lock.
    fn select(
        self: *Search,
        alloc: Allocator,
        t: *Terminal,
        sel: ScreenSearch.Select,
    ) Allocator.Error!void {
        // A screen can be removed or replaced between refresh ticks (and the
        // refresh timer stops while the surface is unfocused). Reconcile while
        // holding the terminal lock before touching any ScreenSearch pins.
        self.feed(alloc, t);
        const screen_search = self.screens.getPtr(self.last_screen.key) orelse return;

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

        // No matter what we reset our selected match cache. The next report
        // then carries the selection, so the renderer learns the screen
        // scrolled.
        self.last_screen.selected = null;

        // Grab the current screen and see if this match is visible within
        // the viewport already. If it is, we do nothing.
        const screen = t.screens.get(self.last_screen.key) orelse return;

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

    fn clearViewportMatches(self: *Search) void {
        const alloc = self.viewport.window.alloc;
        for (self.viewport_matches.items) |*hl| hl.deinit(alloc);
        self.viewport_matches.clearRetainingCapacity();
    }

    /// What changed since the last report, or everything when forced.
    ///
    /// This doesn't require any locking as it only reads internal state.
    fn report(self: *Search, alloc: Allocator, force: bool) QuerySearch.Report {
        self.reported = true;
        var result: QuerySearch.Report = .{ .state = .busy };
        const screen_search = self.screens.getPtr(self.last_screen.key) orelse return result;

        // Check our total match data
        const total = screen_search.matchesLen();
        if (force or total != self.last_screen.total) {
            log.debug("notifying total matches={}", .{total});
            self.last_screen.total = total;
            result.total = .{ .count = total };
        }

        // Check our viewport matches. If they're stale, we do the
        // viewport search now. We do this as part of reporting and not
        // tick because the viewport search is very fast and doesn't
        // require ticked progress or feeds.
        if (force or self.stale_viewport_matches) viewport: {
            // We always make stale as false. Even if we fail below
            // we require a re-feed to re-search the viewport. The feed
            // process will make it stale again.
            self.stale_viewport_matches = false;

            self.clearViewportMatches();
            while (self.viewport.next()) |hl| {
                var hl_cloned = hl.clone(alloc) catch |err| {
                    log.warn("error collecting viewport matches err={}", .{err});

                    // Reset the viewport so we force an update on the
                    // next feed instead of reporting a partial match set.
                    self.clearViewportMatches();
                    self.viewport.reset();
                    break :viewport;
                };
                self.viewport_matches.append(alloc, hl_cloned) catch |err| {
                    log.warn("error collecting viewport matches err={}", .{err});
                    hl_cloned.deinit(alloc);
                    self.clearViewportMatches();
                    self.viewport.reset();
                    break :viewport;
                };
            }

            log.debug("notifying viewport matches len={}", .{self.viewport_matches.items.len});
            result.viewport_matches = self.viewport_matches.items;
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
            result.match_rows = self.match_rows.items;
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
            result.selected = .{ .match = .{
                .idx = m.idx,
                .highlight = flattened,
            } };
        } else if (force or self.last_screen.selected != null) {
            log.debug("notifying selection cleared", .{});
            self.last_screen.selected = null;
            result.selected = .none;
        }

        // Report our completion if we just completed.
        if (!self.last_complete and self.isComplete()) {
            log.debug("notifying search complete", .{});
            self.last_complete = true;
            result.complete = true;
        }

        return result;
    }
};

/// What tests read from reports, copied out of what they borrow.
const TestObserved = struct {
    state: QuerySearch.State = .idle,
    reports: usize = 0,

    /// The number of reports with a total.
    totals: usize = 0,
    total: ?QuerySearch.Total = null,
    viewport_len: ?usize = null,
    rows: []u32 = &.{},
    selected: ?union(enum) { none, match: struct { idx: usize, start: PageList.Pin } } = null,
    complete: bool = false,

    fn deinit(self: *TestObserved) void {
        testing.allocator.free(self.rows);
    }

    fn take(self: *TestObserved, r: QuerySearch.Report) !void {
        self.state = r.state;
        self.reports += 1;
        if (r.total) |total| {
            self.totals += 1;
            self.total = total;
        }
        if (r.viewport_matches) |matches| self.viewport_len = matches.len;
        if (r.match_rows) |rows| {
            testing.allocator.free(self.rows);
            self.rows = try testing.allocator.dupe(u32, rows);
        }
        if (r.selected) |selected| self.selected = switch (selected) {
            .none => .none,
            .match => |m| .{ .match = .{ .idx = m.idx, .start = m.highlight.startPin() } },
        };
        if (r.complete) self.complete = true;
    }

    /// Step with `req`, then until the search is no longer busy.
    fn run(self: *TestObserved, qs: *QuerySearch, req: QuerySearch.Request) !void {
        try self.take(qs.step(req));
        while (self.state == .busy) try self.take(qs.step(.{}));
    }

    fn count(self: *const TestObserved) ?usize {
        const total = self.total orelse return null;
        return switch (total) {
            .count => |n| n,
            .invalid => null,
        };
    }
};

test "an invalid query clears the previous search in one report" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    try seen.run(&qs, .{ .query = .{ .needle = "world" } });
    try testing.expectEqual(@as(?usize, 1), seen.count());
    try testing.expectEqualSlices(u32, &.{0}, seen.rows);

    // The invalid query is the clear of the previous search. A zero total
    // before it would show as "no matches" for a moment.
    const totals = seen.totals;
    try seen.take(qs.step(.{ .query = .{ .needle = "[", .options = .{ .regex = true } } }));
    try testing.expectEqual(QuerySearch.State.idle, seen.state);
    try testing.expectEqual(@as(?QuerySearch.Total, .invalid), seen.total);
    try testing.expectEqual(totals + 1, seen.totals);
    try testing.expectEqual(@as(?usize, 0), seen.viewport_len);
    try testing.expectEqualSlices(u32, &.{}, seen.rows);
    try testing.expect(seen.selected.? == .none);
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

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    // A valid regex with no match, and a literal that holds regex syntax.
    try seen.run(&qs, .{ .query = .{ .needle = "w[x]+", .options = .{ .regex = true } } });
    try testing.expectEqual(@as(?usize, 0), seen.count());
    try testing.expectEqual(QuerySearch.State.waiting, seen.state);
    try seen.run(&qs, .{ .query = .{ .needle = "[" } });
    try testing.expectEqual(@as(?usize, 0), seen.count());
    try testing.expectEqual(QuerySearch.State.waiting, seen.state);

    // The invalid pattern reports itself once per query, whether or not a
    // search was running, and the next valid query searches again.
    for ([_][]const u8{ "[", "(" }) |needle| {
        seen.total = null;
        try seen.run(&qs, .{ .query = .{ .needle = needle, .options = .{ .regex = true } } });
        try testing.expectEqual(@as(?QuerySearch.Total, .invalid), seen.total);
        try testing.expectEqual(QuerySearch.State.idle, seen.state);
    }
    try seen.run(&qs, .{ .query = .{ .needle = "world", .options = .{ .regex = true } } });
    try testing.expectEqual(@as(?usize, 1), seen.count());
    try testing.expectEqual(QuerySearch.State.waiting, seen.state);
}

test "a query that runs out of memory still stops the previous search" {
    // The new query already owns the event generation, so the previous
    // search must not keep reporting results under it.
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");

    var failing = testing.FailingAllocator.init(alloc, .{ .fail_index = std.math.maxInt(usize) });
    var qs: QuerySearch = .init(failing.allocator(), .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    try seen.run(&qs, .{ .query = .{ .needle = "world" } });
    try testing.expectEqual(@as(?usize, 1), seen.count());

    failing.fail_index = failing.alloc_index;
    const totals = seen.totals;
    try seen.run(&qs, .{ .query = .{ .needle = "hello" } });
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(QuerySearch.State.idle, seen.state);
    try testing.expectEqual(@as(?usize, 0), seen.count());
    try testing.expectEqual(totals + 1, seen.totals);
    try testing.expectEqualSlices(u32, &.{}, seen.rows);
}

test "equivalent query replays search state" {
    const alloc = testing.allocator;
    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Hello, world");

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    try seen.run(&qs, .{ .query = .{ .needle = "world" } });
    try testing.expectEqual(@as(?usize, 1), seen.count());
    try testing.expectEqualSlices(u32, &.{0}, seen.rows);
    try testing.expectEqual(@as(?usize, 1), seen.viewport_len);

    // A literal query is ASCII case-insensitive, so this is the same query.
    const r = qs.step(.{ .query = .{ .needle = "WORLD" } });
    try testing.expectEqual(@as(?QuerySearch.Total, .{ .count = 1 }), r.total);
    try testing.expectEqual(@as(usize, 1), r.viewport_matches.?.len);
    try testing.expectEqualSlices(u32, &.{0}, r.match_rows.?);
    try testing.expect(r.selected.? == .none);
}

/// The screen rows whose text contains `needle`, ASCII case-insensitive:
/// what a search reports as match rows once it is caught up, for needles
/// that do not wrap.
fn testRowsContaining(alloc: Allocator, list: *PageList, needle: []const u8) ![]u32 {
    var rows: std.ArrayList(u32) = .empty;
    errdefer rows.deinit(alloc);
    var y: u32 = 0;
    var node = list.pages.first;
    while (node) |n| : (node = n.next) {
        const page = n.page();
        for (0..n.rows()) |row_y| {
            var text: [256]u8 = undefined;
            const cells = page.getCells(page.getRow(row_y));
            for (cells, 0..) |cell, x| {
                const cp = cell.codepoint();
                text[x] = if (cp > 0 and cp < 0x80) @intCast(cp) else ' ';
            }
            if (std.ascii.indexOfIgnoreCase(text[0..cells.len], needle) != null) {
                try rows.append(alloc, y);
            }
            y += 1;
        }
    }
    return try rows.toOwnedSlice(alloc);
}

test "reported match rows follow streamed output while the scrollback is pruned" {
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

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();
    try seen.run(&qs, .{ .query = .{ .needle = "Fizz" } });

    // A prune moves the first page to the end of the list.
    const first_serial = list.pages.first.?.serial;
    var rounds: usize = 0;
    while (rounds < 4 or list.pages.first.?.serial == first_serial) : (rounds += 1) {
        if (rounds > 10_000) return error.TestScrollbackNeverPruned;

        const expected = try testRowsContaining(alloc, list, "Fizz");
        defer alloc.free(expected);
        try testing.expect(expected.len > 0);
        try testing.expectEqualSlices(u32, expected, seen.rows);

        // More output, then a refresh as the renderer would trigger one.
        for (0..200) |_| {
            stream.nextSlice(lines[line % lines.len]);
            line += 1;
        }
        t.flags.search_viewport_dirty = true;
        try seen.run(&qs, .{ .refresh = true });
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

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    try seen.run(&qs, .{ .query = .{ .needle = "needle" } });
    try seen.run(&qs, .{ .select = .next });
    try testing.expectEqual(@as(?usize, 1), seen.count());
    try testing.expectEqual(@as(usize, 0), seen.selected.?.match.idx);

    _ = try t.switchScreen(.primary);
    t.screens.remove(alloc, .alternate);

    // The select reconciles first, so it reports the primary screen, which
    // has no match, instead of touching the removed screen's searcher.
    try seen.run(&qs, .{ .select = .next });
    try testing.expectEqual(@as(?usize, 0), seen.count());
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

        var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
        defer qs.deinit();
        var seen: TestObserved = .{};
        defer seen.deinit();
        try seen.run(&qs, .{ .query = .{ .needle = "needle" } });

        try seen.run(&qs, .{ .select = first });
        const selected = seen.selected.?.match;
        try testing.expectEqual(@as(usize, 0), selected.idx);
        const row = t.screens.active.pages.pointFromPin(.screen, selected.start).?;
        try testing.expectEqual(@as(u32, 2), row.screen.y);

        // Once something is selected, `.prev` steps toward the newer matches
        // as before, which wraps past the newest to the oldest.
        try seen.run(&qs, .{ .select = .prev });
        try testing.expectEqual(@as(usize, 2), seen.selected.?.match.idx);
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

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    try seen.run(&qs, .{ .query = .{ .needle = "needle" } });
    try seen.run(&qs, .{ .select = .next });
    const destroyed = t.screens.get(.alternate).?;
    try testing.expectEqual(@as(usize, 0), seen.selected.?.match.idx);

    // RIS destroys the alternate screen; re-entering it builds a new one.
    stream.nextSlice("\x1bc\x1b[?1049h");
    const rebuilt = t.screens.get(.alternate).?;
    try testing.expectEqual(destroyed, rebuilt);

    // A refresh must not keep the destroyed screen's results and tracked
    // selection just because the new screen has the same address.
    try seen.run(&qs, .{ .refresh = true });
    try testing.expectEqual(@as(?usize, 0), seen.count());
    try testing.expect(seen.selected.? == .none);

    try seen.run(&qs, .{ .select = .next });
    try testing.expect(seen.selected.? == .none);
}

test "a pattern that fails at run time ends the query with one clear" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();
    for (0..3) |_| {
        stream.nextSlice("Fizz\r\n");
        const pages = list.totalPages();
        while (list.totalPages() == pages) stream.nextSlice("\r\n");
    }
    for (0..list.rows) |_| stream.nextSlice("\r\n");
    stream.nextSlice("Fizz");
    const tracked_pins = list.countTrackedPins();

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    // Search until some of the history has matched.
    try seen.take(qs.step(.{ .query = .{ .needle = "Fizz", .options = .{ .whole_word = true } } }));
    while (seen.count().? < 2) {
        try testing.expectEqual(QuerySearch.State.busy, seen.state);
        try seen.take(qs.step(.{}));
    }
    try testing.expectEqual(QuerySearch.State.busy, seen.state);
    try testing.expect(!seen.complete);

    // The engine fails partway through the history.
    const tw = @import("pattern.zig").find_tw;
    defer tw.end(.reset) catch unreachable;
    tw.errorAlways(.search, error.RetryLimit);
    const totals = seen.totals;
    while (seen.state == .busy) try seen.take(qs.step(.{}));

    try testing.expectEqual(QuerySearch.State.idle, seen.state);
    try testing.expectEqual(totals + 1, seen.totals);
    try testing.expectEqual(@as(?usize, 0), seen.count());
    try testing.expectEqual(@as(?usize, 0), seen.viewport_len);
    try testing.expectEqualSlices(u32, &.{}, seen.rows);
    try testing.expect(seen.selected.? == .none);
    try testing.expectEqual(tracked_pins, list.countTrackedPins());

    // Nothing is left to do until the next query.
    try seen.take(qs.step(.{ .refresh = true }));
    try testing.expectEqual(QuerySearch.State.idle, seen.state);
    try testing.expectEqual(totals + 1, seen.totals);
}

test "every searcher of one query borrows one Pattern" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list = &t.screens.get(.primary).?.pages;

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) stream.nextSlice("\r\n");
    for (0..list.rows) |_| stream.nextSlice("\r\n");
    stream.nextSlice("Fizz\x1b[?1049hFizz\x1b[?1049l");

    var search: Search = try .init(alloc, "Fizz", .{ .whole_word = true });
    defer search.deinit(&t);
    const pattern = search.pattern.?;

    for ([_]u16{ 10, 12 }) |cols| {
        search.feed(alloc, &t);
        try testing.expectEqual(pattern, search.viewport.window.pattern.?);
        try testing.expectEqual(@as(usize, 2), search.screens.count());
        var it = search.screens.iterator();
        while (it.next()) |entry| {
            try testing.expectEqual(pattern, entry.value.pattern().?);
        }
        const primary = search.screens.getPtr(.primary).?;
        try testing.expectEqual(cols, primary.cols);
        try testing.expectEqual(pattern, primary.history.?.searcher.window.pattern.?);

        // A resize replaces the active screen's searcher at its next
        // reload; the new one borrows the pattern too.
        try t.resize(alloc, 12, 2);
        t.flags.search_viewport_dirty = true;
    }
}
