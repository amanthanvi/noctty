//! One search query over a terminal, stepped by one thread: which query
//! runs, when the terminal is read under its lock, what changed since the
//! last report, where the first select goes, and ending a query whose
//! pattern fails at run time. It runs upstream's `TerminalSearch` and owns
//! the query's `Pattern`. The search thread (`Thread.zig`) is a shell that
//! turns each `Report` into events.
//!
//! The private parts map onto upstream's search thread functions
//! (`changeNeedle`, `feedLocked`, `select`, `notify` and its
//! `NotifyState`), so upstream fixes to them port here.
const std = @import("std");
const build_options = @import("terminal_options");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const UntrackedHighlight = @import("../highlight.zig").Untracked;
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const ScreenSet = @import("../ScreenSet.zig");
const Terminal = @import("../Terminal.zig");
const Pattern = @import("pattern.zig").Pattern;
const Query = @import("query_options.zig").Query;
const ScreenSearch = @import("screen.zig").ScreenSearch;
const TerminalSearch = @import("terminal.zig").TerminalSearch;
const oni = if (build_options.oniguruma) @import("oniguruma") else struct {};

const log = std.log.scoped(.search_thread);

pub const QuerySearch = struct {
    alloc: Allocator,
    term: Term,

    /// The running query, if any.
    current: ?Current = null,

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
        match: Match,

        pub const Match = struct {
            /// From the newest match, 0 being the newest.
            idx: usize,
            highlight: FlattenedHighlight,
        };
    };

    /// What changed since the previous report: a null field did not. A
    /// query that replaces or clears a search, or is invalid, reports every
    /// field, and an equivalent query replays every field; a first query
    /// reports what it found. Slices are borrowed until the next step or
    /// deinit.
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
            .cleared => |total| {
                // The new search's first feed may have failed: this clear
                // ends it too.
                _ = self.endIfFailed();
                return self.cleared(total);
            },
        };
        if (req.refresh) self.refresh();
        if (req.select) |to| self.select(to);

        const cur = if (self.current) |*cur| cur else return .{ .state = .idle };

        // A search reports what its query, refresh or select left before it
        // makes progress, as the search thread notified before it ticked.
        const slice = req.query == null and !req.refresh and req.select == null;
        if (slice and cur.reported and !cur.search.isComplete()) {
            switch (cur.search.tick()) {
                .complete, .progress => {},
                .blocked => {
                    self.term.mutex.lock();
                    defer self.term.mutex.unlock();
                    self.feedLocked(cur);
                },
            }
        }

        // Building the report collects the viewport matches, which runs the
        // pattern too, so the failure check comes after it.
        const report = self.notify(cur, force);
        if (self.endIfFailed()) return self.cleared(.{ .count = 0 });
        return report;
    }

    /// End the query if its pattern has failed in any searcher, and say
    /// whether it did. A failed pattern finds nothing from then on.
    fn endIfFailed(self: *QuerySearch) bool {
        const cur = if (self.current) |*cur| cur else return false;
        const p = cur.pattern orelse return false;
        const err = p.failure() orelse return false;
        log.warn("search query ended by a pattern failure err={}", .{err});
        self.stop();
        return true;
    }

    /// The search of one query and what has been reported of it.
    const Current = struct {
        search: TerminalSearch,

        /// Lent to every searcher; null for a literal query.
        pattern: ?*Pattern,

        notified: NotifyState = .{},
        rows: MatchRows = .{},

        /// True once anything has been reported.
        reported: bool = false,

        fn init(alloc: Allocator, query_: Query) Pattern.CompileError!Current {
            const pattern = try Pattern.forQuery(alloc, query_);
            errdefer if (pattern) |p| p.destroy(alloc);
            return .{
                .search = try .initPattern(alloc, query_.needle, pattern),
                .pattern = pattern,
            };
        }

        /// The query this search runs. The needle is borrowed.
        fn query(self: *const Current) Query {
            return .{
                .needle = self.search.needle(),
                .options = if (self.pattern) |p| p.options else .{},
            };
        }
    };

    /// What was last reported, in the shape of upstream's search thread
    /// `NotifyState`.
    const NotifyState = struct {
        /// The active screen key the state below was captured against.
        key: ScreenSet.Key = .primary,

        /// Last notified total matches count
        total: ?usize = null,

        /// Last notified selected match
        selected: ?SelectedMatch = null,

        /// True if we sent the complete notification yet.
        complete: bool = false,

        const SelectedMatch = struct {
            idx: usize,
            highlight: UntrackedHighlight,
        };
    };

    /// The active screen's match rows, rebuilt under the terminal lock only
    /// when the screen or its match-row revision changes, so a report never
    /// touches terminal state.
    const MatchRows = struct {
        rows: std.ArrayList(u32) = .empty,
        notified: std.ArrayList(u32) = .empty,

        /// The searcher the rows were built from: its screen, that
        /// screen's ScreenSet generation, and its match-row revision.
        screen: ?ScreenSet.Key = null,
        generation: usize = 0,
        revision: u64 = 0,

        fn deinit(self: *MatchRows, alloc: Allocator) void {
            self.rows.deinit(alloc);
            self.notified.deinit(alloc);
        }

        fn clear(self: *MatchRows) void {
            self.rows.clearRetainingCapacity();
            self.screen = null;
            self.revision = 0;
        }

        /// The caller must hold the terminal lock.
        fn refresh(self: *MatchRows, alloc: Allocator, s: *TerminalSearch) void {
            // The searcher the rows came from was removed by the feed.
            if (self.screen) |key| {
                if (s.screen_generations.get(key) != self.generation) self.clear();
            }

            const screen_search = s.activeScreenSearch() orelse return self.clear();
            const revision = screen_search.matchRowsRevision();
            if (self.screen == s.active_key and self.revision == revision) return;

            screen_search.collectMatchRows(alloc, &self.rows) catch |err| {
                log.warn("error rebuilding search match rows err={}", .{err});
                return;
            };
            self.screen = s.active_key;
            self.generation = s.screen_generations.get(s.active_key).?;
            self.revision = revision;
        }

        /// The rows, when they differ from the reported ones or `force`.
        fn unreported(self: *MatchRows, alloc: Allocator, force: bool) ?[]const u32 {
            if (!force and std.mem.eql(u32, self.rows.items, self.notified.items)) return null;
            self.notified.ensureTotalCapacity(alloc, self.rows.items.len) catch |err| {
                log.warn("error caching notified search match rows err={}", .{err});
                return null;
            };
            self.notified.clearRetainingCapacity();
            self.notified.appendSliceAssumeCapacity(self.rows.items);
            return self.rows.items;
        }
    };

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

        if (self.current) |*cur| {
            if (cur.query().eql(query)) {
                // Reset clears both the viewport fingerprint and sliding-window
                // buffer, so the forced report rescans from a clean state.
                cur.search.viewport.reset();
                cur.search.stale_viewport_matches = true;

                self.term.mutex.lock();
                defer self.term.mutex.unlock();
                self.feedLocked(cur);
                return .replay;
            }
        }

        // Compile before the previous search stops, so a query that cannot be
        // searched for is reported by the one clear of the previous results,
        // not by a second one after it (which would show "no matches" first).
        var invalid = false;
        var next: ?Current = null;
        if (query.needle.len > 0) {
            if (Current.init(self.alloc, query)) |cur| {
                next = cur;
            } else |err| {
                // Out of memory is not an invalid query, but the previous
                // search still stops: its results would otherwise be
                // reported for the new query.
                log.warn("error initializing search query err={}", .{err});
                invalid = err != error.OutOfMemory;
            }
        }

        const replaced = self.current != null;
        self.stop();

        // No needle means stop the search, and an invalid one starts none.
        self.current = next;
        if (self.current) |*cur| {
            self.term.mutex.lock();
            defer self.term.mutex.unlock();
            self.feedLocked(cur);
        }

        if (invalid) return .{ .cleared = .invalid };
        if (replaced) return .{ .cleared = .{ .count = 0 } };
        return .started;
    }

    /// Every field cleared, with the total `total`.
    fn cleared(self: *const QuerySearch, total: Total) Report {
        return .{
            .state = if (self.current != null) .busy else .idle,
            .total = total,
            .viewport_matches = &.{},
            .match_rows = &.{},
            .selected = .none,
        };
    }

    /// Feed the search from the terminal state and rebuild the match rows.
    /// The terminal mutex must be held by the caller.
    fn feedLocked(self: *QuerySearch, cur: *Current) void {
        const t = self.term.terminal;

        // See the `search_viewport_dirty` flag on the terminal to know
        // what exactly this is for. But, if this is set, we know the renderer
        // found the viewport/active area dirty, so the active area must be
        // re-scanned.
        const active_dirty = t.flags.search_viewport_dirty;
        t.flags.search_viewport_dirty = false;

        cur.search.feed(t, active_dirty);
        cur.rows.refresh(self.alloc, &cur.search);
    }

    fn refresh(self: *QuerySearch) void {
        const cur = if (self.current) |*cur| cur else return;
        self.term.mutex.lock();
        defer self.term.mutex.unlock();
        self.feedLocked(cur);
    }

    fn select(self: *QuerySearch, to: ScreenSearch.Select) void {
        const cur = if (self.current) |*cur| cur else return;
        self.term.mutex.lock();
        defer self.term.mutex.unlock();

        // A screen can be removed or replaced between refresh ticks (and the
        // refresh timer stops while the surface is unfocused). Reconcile while
        // holding the terminal lock before touching any ScreenSearch pins.
        self.feedLocked(cur);
        const screen_search = cur.search.activeScreenSearch() orelse return;

        // With nothing selected yet, either direction starts at the newest match,
        // the one nearest the bottom of the screen. `.prev` alone would start at
        // the oldest, which sends the first Enter after typing to the top of the
        // scrollback.
        const dir: ScreenSearch.Select = if (screen_search.selected == null) .next else to;

        const selected = cur.search.select(self.term.terminal, dir, .if_needed) catch |err| {
            log.warn("error selecting search match err={}", .{err});
            return;
        };

        // No matter what we reset our selected match cache. The next report
        // then carries the selection, so the renderer learns the screen
        // scrolled.
        if (selected) cur.notified.selected = null;
    }

    fn stop(self: *QuerySearch) void {
        const cur = if (self.current) |*cur| cur else return;
        {
            self.term.mutex.lock();
            defer self.term.mutex.unlock();
            cur.search.deinit(self.term.terminal);
        }
        cur.rows.deinit(self.alloc);

        // Every searcher above borrowed it.
        if (cur.pattern) |p| p.destroy(self.alloc);
        self.current = null;
    }

    /// What changed since the last report, or everything when forced.
    ///
    /// This doesn't require any locking as it only reads search-owned state.
    fn notify(self: *QuerySearch, cur: *Current, force: bool) Report {
        cur.reported = true;
        const s = &cur.search;
        const state = &cur.notified;
        var result: Report = .{ .state = if (s.isComplete()) .waiting else .busy };

        // A screen switch makes all previously notified per-screen state
        // stale, so reset it to force recalculations and notifications.
        if (state.key != s.active_key) {
            state.key = s.active_key;
            state.total = null;
            state.selected = null;
        }

        const screen_search = s.activeScreenSearch() orelse return result;

        // Check our total match data
        const total = screen_search.matchesLen();
        if (force or total != state.total) {
            log.debug("notifying total matches={}", .{total});
            state.total = total;
            result.total = .{ .count = total };
        }

        // Check our viewport matches. If they're stale, we collect them
        // now. We do this as part of notify and not tick because the
        // viewport search is very fast and doesn't require ticked progress
        // or feeds.
        if (force or s.stale_viewport_matches) viewport: {
            const matches = s.viewportMatches() catch |err| {
                log.warn("error collecting viewport matches err={}", .{err});
                break :viewport;
            };

            log.debug("notifying viewport matches len={}", .{matches.len});
            result.viewport_matches = matches;
        }

        if (cur.rows.unreported(self.alloc, force)) |rows| {
            log.debug("notifying search match rows len={}", .{rows.len});
            result.match_rows = rows;
        }

        // Check our last selected match data.
        if (screen_search.selected) |m| match: {
            const flattened = screen_search.selectedMatch() orelse break :match;
            const untracked = flattened.untracked();
            if (state.selected) |prev| {
                if (!force and prev.idx == m.idx and prev.highlight.eql(untracked)) {
                    // Same selection, don't update it.
                    break :match;
                }
            }

            // New selection, notify!
            state.selected = .{
                .idx = m.idx,
                .highlight = untracked,
            };

            log.debug("notifying selection updated idx={}", .{m.idx});
            result.selected = .{ .match = .{
                .idx = m.idx,
                .highlight = flattened,
            } };
        } else if (force or state.selected != null) {
            log.debug("notifying selection cleared", .{});
            state.selected = null;
            result.selected = .none;
        }

        // Send our complete notification if we just completed.
        if (!state.complete and s.isComplete()) {
            log.debug("notifying search complete", .{});
            state.complete = true;
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

test "a pattern that fails while the report is built ends the query with one clear" {
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

    // A match on the first page, and the active area pages later.
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) stream.nextSlice("\r\n");
    stream.nextSlice("Fizz");

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    try seen.run(&qs, .{ .query = .{ .needle = "Fizz", .options = .{ .whole_word = true } } });
    try testing.expectEqual(QuerySearch.State.waiting, seen.state);
    try testing.expectEqual(@as(?usize, 2), seen.count());

    // The search is caught up, so a refresh after the viewport moves to
    // another page feeds no new text: only the report's viewport
    // collection runs the pattern.
    t.scrollViewport(.top);
    const tw = @import("pattern.zig").find_tw;
    defer tw.reset();
    tw.errorAlways(.search, error.RetryLimit);
    const totals = seen.totals;
    try seen.take(qs.step(.{ .refresh = true }));
    try tw.end(.reset);

    try testing.expectEqual(QuerySearch.State.idle, seen.state);
    try testing.expectEqual(totals + 1, seen.totals);
    try testing.expectEqual(@as(?usize, 0), seen.count());
    try testing.expectEqual(@as(?usize, 0), seen.viewport_len);
    try testing.expectEqualSlices(u32, &.{}, seen.rows);
}

test "a replacing query whose first feed fails ends with one clear" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var mutex: std.Thread.Mutex = .{};
    var t: Terminal = try .init(alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz Buzz");

    var qs: QuerySearch = .init(alloc, .{ .terminal = &t, .mutex = &mutex });
    defer qs.deinit();
    var seen: TestObserved = .{};
    defer seen.deinit();

    try seen.run(&qs, .{ .query = .{ .needle = "Fizz" } });
    try testing.expectEqual(@as(?usize, 1), seen.count());

    // The new query's first feed scans the active area with its pattern.
    const tw = @import("pattern.zig").find_tw;
    defer tw.reset();
    tw.errorAlways(.search, error.RetryLimit);
    const totals = seen.totals;
    try seen.take(qs.step(.{ .query = .{ .needle = "Buzz", .options = .{ .whole_word = true } } }));
    try tw.end(.reset);

    // That clear both ends the previous search and the failed one.
    try testing.expectEqual(QuerySearch.State.idle, seen.state);
    try testing.expectEqual(totals + 1, seen.totals);
    try testing.expectEqual(@as(?usize, 0), seen.count());

    try seen.take(qs.step(.{}));
    try testing.expectEqual(QuerySearch.State.idle, seen.state);
    try testing.expectEqual(totals + 1, seen.totals);
}
