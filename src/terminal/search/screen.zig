const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const testing = std.testing;
const tripwire = @import("../../tripwire.zig");
const Allocator = std.mem.Allocator;
const point = @import("../point.zig");
const highlight = @import("../highlight.zig");
const size = @import("../size.zig");
const FlattenedHighlight = highlight.Flattened;
const TrackedHighlight = highlight.Tracked;
const PageList = @import("../PageList.zig");
const Pin = PageList.Pin;
const Screen = @import("../Screen.zig");
const Terminal = @import("../Terminal.zig");
const ActiveSearch = @import("active.zig").ActiveSearch;
const PageListSearch = @import("pagelist.zig").PageListSearch;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;
const QueryOptions = @import("query_options.zig").QueryOptions;

const log = std.log.scoped(.search_screen);

const reloadActive_tw = tripwire.module(enum {
    history_append_new,
    history_append_existing,
}, ScreenSearch.reloadActive);

/// Searches for a needle within a Screen, handling active area updates,
/// pages being pruned from the screen (e.g. scrollback limits), and more.
///
/// Unlike our lower-level searchers (like ActiveSearch and PageListSearch),
/// this will cache and store all search results so the caller can re-access
/// them as needed. This structure does this because it is intended to help
/// the caller handle the case where the Screen is changing while the user
/// is searching.
///
/// An inactive screen can continue to be searched in the background, and when
/// screen state changes, the renderer/caller can access the existing search
/// results without needing to re-search everything. This prevents a particularly
/// nasty UX where going to alt screen (e.g. neovim) and then back would
/// restart the full scrollback search.
pub const ScreenSearch = struct {
    /// The screen being searched.
    screen: *Screen,

    /// The active area search state
    active: ActiveSearch,

    /// The history (scrollback) search state. May be null if there is
    /// no history yet.
    history: ?HistorySearch,

    /// Current state of the search, a state machine.
    state: State,

    /// The currently selected match, if any. As the screen contents
    /// change or get pruned, the screen search will do its best to keep
    /// this accurate.
    selected: ?SelectedMatch = null,

    /// The results found so far. These are stored separately because history
    /// is mostly immutable once found, while active area results may
    /// change. This lets us easily reset the active area results for a
    /// re-search scenario.
    history_results: std.ArrayList(FlattenedHighlight),
    active_results: std.ArrayList(FlattenedHighlight),

    /// Monotonic marker for result-set changes that affect match-row markers.
    match_rows_revision: u64 = 0,

    /// The dimensions of the screen. When this changes we need to
    /// restart the whole search, currently.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    pub const SelectedMatch = struct {
        /// Index from the end of the match list (0 = most recent match)
        idx: usize,

        /// Tracked highlight so we can detect movement.
        highlight: TrackedHighlight,

        pub fn deinit(self: *SelectedMatch, screen: *Screen) void {
            self.highlight.deinit(screen);
        }
    };

    /// History search state.
    const HistorySearch = struct {
        /// The actual searcher state.
        searcher: PageListSearch,

        /// The pin for the first node that this searcher is searching from.
        /// We use this when the active area changes to find the diff between
        /// the top of the new active area and the previous start point
        /// to determine if we need to search more history.
        start_pin: *Pin,

        pub fn deinit(self: *HistorySearch, screen: *Screen) void {
            self.searcher.deinit();
            screen.pages.untrackPin(self.start_pin);
        }
    };

    /// Search state machine
    const State = enum {
        /// Currently searching the active area
        active,

        /// Currently searching the history area
        history,

        /// History search is waiting for more data to be fed before
        /// it can progress.
        history_feed,

        /// Search is complete given the current terminal state.
        complete,

        pub fn isComplete(self: State) bool {
            return switch (self) {
                .complete => true,
                else => false,
            };
        }

        pub fn needsFeed(self: State) bool {
            return switch (self) {
                .history_feed => true,

                // Not obvious but complete search states will prune
                // stale history results on feed.
                .complete => true,

                else => false,
            };
        }
    };

    // Initialize a screen search for the given screen and needle.
    pub fn init(
        alloc: Allocator,
        screen: *Screen,
        needle_unowned: []const u8,
    ) Allocator.Error!ScreenSearch {
        return ScreenSearch.initWithOptions(alloc, screen, needle_unowned, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Default options cannot hit unsupported regex/option paths.
            else => unreachable,
        };
    }

    pub fn initWithOptions(
        alloc: Allocator,
        screen: *Screen,
        needle_unowned: []const u8,
        query_options: QueryOptions,
    ) SlidingWindow.InitError!ScreenSearch {
        var result: ScreenSearch = .{
            .screen = screen,
            .rows = screen.pages.rows,
            .cols = screen.pages.cols,
            .active = try .initWithOptions(alloc, needle_unowned, query_options),
            .history = null,
            .state = .active,
            .active_results = .empty,
            .history_results = .empty,
        };
        errdefer result.deinit();

        // Update our initial active area state
        try result.reloadActive();

        return result;
    }

    pub fn deinit(self: *ScreenSearch) void {
        self.deinitInternal(true);
    }

    /// Release owned search state after the underlying Screen has already
    /// been destroyed. Tracked pins belonged to that Screen's PageList pool
    /// and were freed with it, so only independently owned memory is freed.
    pub fn deinitScreenInvalid(self: *ScreenSearch) void {
        self.deinitInternal(false);
    }

    fn deinitInternal(self: *ScreenSearch, screen_valid: bool) void {
        const alloc = self.allocator();
        self.active.deinit();
        if (self.history) |*h| {
            if (screen_valid) {
                h.deinit(self.screen);
            } else {
                h.searcher.deinitListInvalid();
            }
        }
        if (screen_valid) {
            if (self.selected) |*m| m.deinit(self.screen);
        }
        for (self.active_results.items) |*hl| hl.deinit(alloc);
        self.active_results.deinit(alloc);
        for (self.history_results.items) |*hl| hl.deinit(alloc);
        self.history_results.deinit(alloc);
    }

    fn allocator(self: *ScreenSearch) Allocator {
        return self.active.window.alloc;
    }

    /// The needle that this search is using.
    pub fn needle(self: *const ScreenSearch) []const u8 {
        assert(self.active.window.direction == .forward);
        return self.active.window.needle;
    }

    /// Returns the total number of matches found so far.
    pub fn matchesLen(self: *const ScreenSearch) usize {
        return self.active_results.items.len + self.history_results.items.len;
    }

    /// Returns a version token that changes when match-row inputs change.
    pub fn matchRowsRevision(self: *const ScreenSearch) u64 {
        return self.match_rows_revision;
    }

    fn markMatchRowsDirty(self: *ScreenSearch) void {
        self.match_rows_revision +%= 1;
    }

    fn failSearch(self: *ScreenSearch) void {
        const alloc = self.allocator();
        const had_results = self.active_results.items.len > 0 or
            self.history_results.items.len > 0 or
            self.selected != null;

        if (self.selected) |*m| {
            m.deinit(self.screen);
            self.selected = null;
        }
        if (self.history) |*h| {
            h.deinit(self.screen);
            self.history = null;
        }
        for (self.active_results.items) |*hl| hl.deinit(alloc);
        self.active_results.clearRetainingCapacity();
        for (self.history_results.items) |*hl| hl.deinit(alloc);
        self.history_results.clearRetainingCapacity();
        if (had_results) self.markMatchRowsDirty();
        self.state = .complete;
    }

    /// Handle an error from setting up or running a matcher: out of memory
    /// is returned, and anything else is logged as `what` and ends the
    /// search through `failSearch`. The caller must hold the screen lock.
    fn failSearchUnlessOutOfMemory(
        self: *ScreenSearch,
        err: anyerror,
        comptime what: []const u8,
    ) Allocator.Error!void {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log.warn(what ++ " err={}", .{err});
        self.failSearch();
    }

    /// Reinitialize cached search state after a screen resize. Reflow can
    /// replace every PageList node, so even flattened highlights that weren't
    /// selected contain invalid node pointers once either dimension changes.
    ///
    /// Returns true when the reset occurred. The replacement search has
    /// already loaded its active area through `init` in that case. A
    /// matcher that fails to reinitialize ends the search through
    /// `failSearch`, which also counts as a reset.
    fn resetIfDimensionsChanged(self: *ScreenSearch) Allocator.Error!bool {
        if (self.screen.pages.rows == self.rows and
            self.screen.pages.cols == self.cols)
        {
            return false;
        }

        const previous_match_rows_revision = self.match_rows_revision;
        const new: ScreenSearch = ScreenSearch.initWithOptions(
            self.allocator(),
            self.screen,
            self.needle(),
            self.active.window.query_options,
        ) catch |err| {
            try self.failSearchUnlessOutOfMemory(err, "error reinitializing screen search after resize");
            return true;
        };

        self.deinit();
        self.* = new;
        self.match_rows_revision = previous_match_rows_revision +% 1;

        assert(self.screen.pages.rows == self.rows);
        assert(self.screen.pages.cols == self.cols);
        return true;
    }

    /// Returns all matches as an owned slice (caller must free).
    /// The matches are ordered from most recent to oldest (e.g. bottom
    /// of the screen to top of the screen).
    pub fn matches(
        self: *ScreenSearch,
        alloc: Allocator,
    ) Allocator.Error![]FlattenedHighlight {
        const active_results = self.active_results.items;
        const history_results = self.history_results.items;
        const results = try alloc.alloc(
            FlattenedHighlight,
            active_results.len + history_results.len,
        );
        errdefer alloc.free(results);

        // Active does a forward search, so we add the active results then
        // reverse them. There are usually not many active results so this
        // is fast enough compared to adding them in reverse order.
        assert(self.active.window.direction == .forward);
        @memcpy(
            results[0..active_results.len],
            active_results,
        );
        std.mem.reverse(FlattenedHighlight, results[0..active_results.len]);

        // History does a backward search, so we can just append them
        // after.
        @memcpy(
            results[active_results.len..],
            history_results,
        );

        return results;
    }

    /// Returns the unique screen row for each match as an owned slice,
    /// sorted from oldest to newest. Callers must hold the screen lock.
    pub fn matchRows(
        self: *ScreenSearch,
        alloc: Allocator,
    ) Allocator.Error![]u32 {
        var rows: std.ArrayList(u32) = .empty;
        errdefer rows.deinit(alloc);
        try self.collectMatchRows(alloc, &rows);
        return try rows.toOwnedSlice(alloc);
    }

    /// Replaces the contents of `rows` with `matchRows`, or leaves them
    /// unchanged on error. Callers must hold the screen lock.
    pub fn collectMatchRows(
        self: *ScreenSearch,
        alloc: Allocator,
        rows: *std.ArrayList(u32),
    ) Allocator.Error!void {
        if (self.matchesLen() == 0) {
            rows.clearRetainingCapacity();
            return;
        }
        try rows.ensureTotalCapacity(alloc, self.matchesLen());
        var node_rows: NodeRows = try .init(alloc, &self.screen.pages);
        defer node_rows.deinit(alloc);

        // History is newest first and the active results are oldest first,
        // so this order is usually sorted already.
        rows.clearRetainingCapacity();
        var i = self.history_results.items.len;
        while (i > 0) {
            i -= 1;
            const start = self.history_results.items[i].startPin();
            const row = node_rows.screenRow(start) orelse continue;
            rows.appendAssumeCapacity(row);
        }
        for (self.active_results.items) |hl| {
            const row = node_rows.screenRow(hl.startPin()) orelse continue;
            rows.appendAssumeCapacity(row);
        }
        if (rows.items.len == 0) return;

        if (!std.sort.isSorted(u32, rows.items, {}, std.sort.asc(u32))) {
            std.mem.sort(u32, rows.items, {}, std.sort.asc(u32));
        }

        var write: usize = 1;
        for (rows.items[1..]) |row| {
            if (row == rows.items[write - 1]) continue;
            rows.items[write] = row;
            write += 1;
        }
        rows.shrinkRetainingCapacity(write);
    }

    /// Screen rows of pins, as `PageList.pointFromPin(.screen, pin)` gives
    /// them, for many pins at once. `pointFromPin` walks the page list from
    /// the top for every pin; this walks it once and records the screen row
    /// of every node's first row. A pin whose node is not in the list (its
    /// page was destroyed) has no row, as with `pointFromPin`.
    const NodeRows = struct {
        first_rows: std.AutoHashMapUnmanaged(*const PageList.List.Node, u32),

        /// Matches come in runs on the same node, so most lookups repeat
        /// the previous one.
        last_node: ?*const PageList.List.Node = null,
        last_first_row: ?u32 = null,

        fn init(alloc: Allocator, pages: *const PageList) Allocator.Error!NodeRows {
            var first_rows: std.AutoHashMapUnmanaged(*const PageList.List.Node, u32) = .empty;
            errdefer first_rows.deinit(alloc);
            var row: u32 = 0;
            var it = pages.pages.first;
            while (it) |node| : (it = node.next) {
                try first_rows.putNoClobber(alloc, node, row);
                row += node.data.size.rows;
            }
            return .{ .first_rows = first_rows };
        }

        fn deinit(self: *NodeRows, alloc: Allocator) void {
            self.first_rows.deinit(alloc);
        }

        fn screenRow(self: *NodeRows, pin: Pin) ?u32 {
            if (self.last_node != pin.node) {
                self.last_node = pin.node;
                self.last_first_row = self.first_rows.get(pin.node);
            }
            const first_row = self.last_first_row orelse return null;
            return first_row + pin.y;
        }
    };

    /// Search the full screen state. This will block until the search
    /// is complete. For performance, it is recommended to use `tick` and
    /// `feed` to incrementally make progress on the search instead.
    pub fn searchAll(self: *ScreenSearch) Allocator.Error!void {
        while (true) {
            self.tick() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FeedRequired => try self.feed(),
                error.SearchComplete => return,
            };
        }
    }

    pub const TickError = Allocator.Error || error{
        FeedRequired,
        SearchComplete,
    };

    /// Make incremental progress. The caller protects screen-owned pins
    /// during failure cleanup; background callers use tickWithMutex instead.
    ///
    /// This will return error.FeedRequired if the search cannot make progress
    /// without being fed more data. In this case, the caller should call
    /// the `feed` function to provide more data to the searcher.
    ///
    /// This will return error.SearchComplete if the search is fully complete.
    /// This is to signal to the caller that it can move to a more efficient
    /// sleep/wait state until there is more work to do (e.g. new data to feed).
    pub fn tick(self: *ScreenSearch) TickError!void {
        return self.tickWithMutex(null);
    }

    /// Scan copied data without the terminal lock, acquiring it only when
    /// a matcher failure must release screen-owned tracked pins. A null
    /// mutex means the caller already protects the screen (as in searchAll).
    pub fn tickWithMutex(self: *ScreenSearch, mutex: ?*std.Thread.Mutex) TickError!void {
        switch (self.state) {
            .active => try self.tickActive(mutex),
            .history => try self.tickHistory(mutex, PageListSearch.next, ScreenSearch.failSearch),
            .history_feed => return error.FeedRequired,
            .complete => return error.SearchComplete,
        }
    }

    /// Feed more data to the searcher so it can continue searching. This
    /// accesses the screen state, so the caller must hold the necessary locks.
    ///
    /// Feed on a complete screen search will perform some cleanup of
    /// potentially stale history results (pruned) and reclaim some memory.
    pub fn feed(self: *ScreenSearch) Allocator.Error!void {
        // Resize/reflow invalidates every flattened result, not just search
        // state that needs another history feed.
        _ = try self.resetIfDimensionsChanged();

        const history: *PageListSearch = if (self.history) |*h| &h.searcher else {
            // No history to feed, search is complete.
            self.state = .complete;
            return;
        };

        // Future: we may want to feed multiple pages at once here to
        // lower the frequency of lock acquisitions.
        if (!try history.feed()) {
            // No more data to feed, search is complete.
            self.state = .complete;

            // We use this opportunity to also clean up older history
            // results that may be gone due to scrollback pruning, though.
            try self.pruneHistory();

            return;
        }

        // Depending on our state handle where feed goes
        switch (self.state) {
            // If we're searching active or history, then feeding doesn't
            // change the state.
            .active, .history => {},

            // Feed goes back to searching history.
            .history_feed => self.state = .history,

            // If we're complete then the feed call above should always
            // return false and we can't reach this.
            .complete => unreachable,
        }
    }

    fn historyResultIsValid(
        self: *const ScreenSearch,
        hl: *const FlattenedHighlight,
    ) bool {
        const chunks = hl.chunks.slice();
        const nodes = chunks.items(.node);
        const serials = chunks.items(.serial);
        for (nodes, serials) |node, serial| {
            if (!self.screen.pages.nodeIsValid(node, serial)) return false;
        }

        return true;
    }

    /// Clear a selected history match if its flattened page coordinates are
    /// stale. reloadActive only inspects the selected history result, so this
    /// avoids validating every cached result on each active-area refresh.
    fn validateSelectedHistory(self: *ScreenSearch) void {
        const m = if (self.selected) |*m| m else return;
        const active_len = self.active_results.items.len;
        if (m.idx < active_len) return;

        const history_idx = m.idx - active_len;
        if (history_idx < self.history_results.items.len and
            self.historyResultIsValid(&self.history_results.items[history_idx]))
        {
            return;
        }

        m.deinit(self.screen);
        self.selected = null;
    }

    fn pruneHistory(self: *ScreenSearch) Allocator.Error!void {
        const results = self.history_results.items;
        if (results.len == 0) return;

        const alloc = self.allocator();
        var live: LiveNodes = try .init(alloc, &self.screen.pages);
        defer live.deinit(alloc);

        // The selected match's index into the history results, if any. It
        // is cleared once that result is kept, so one left over was dropped.
        const active_len = self.active_results.items.len;
        var selected: ?usize = if (self.selected) |m|
            if (m.idx >= active_len) m.idx - active_len else null
        else
            null;

        // Go through our history results in order (newest to oldest) and
        // keep the valid ones in place, so removing many costs one pass.
        var kept: usize = 0;
        var i: usize = 0;
        while (i < results.len) : (i += 1) {
            const hl = &results[i];

            // Only PageList.reset raises page_serial_min. Results are newest
            // to oldest, so this result and every older one predate that
            // reset: drop them without validating each chunk.
            if (hl.chunks.items(.serial)[0] < self.screen.pages.page_serial_min) break;

            // Ordinary pruning, layout changes and replacements leave
            // page_serial_min alone, so validate the captured pointer and
            // serial pairs against the live list. Older results may live on
            // unrelated pages and remain usable, so only this result is
            // removed.
            if (!live.resultIsValid(hl)) {
                hl.deinit(alloc);
                continue;
            }

            if (selected == i) {
                self.selected.?.idx = active_len + kept;
                selected = null;
            }
            results[kept] = hl.*;
            kept += 1;
        }
        for (results[i..]) |*prune_hl| prune_hl.deinit(alloc);
        if (kept == results.len) return;

        if (selected != null) {
            self.selected.?.deinit(self.screen);
            self.selected = null;
        }
        self.history_results.shrinkAndFree(alloc, kept);
        self.markMatchRowsDirty();
    }

    /// Live page generations, answering `PageList.nodeIsValid` for many
    /// results at once. `nodeIsValid` walks the page list for every chunk,
    /// and pruneHistory runs on every refresh of a complete search under
    /// the terminal lock, so this walks the list once, as NodeRows does.
    const LiveNodes = struct {
        page_serial_min: u64,
        serials: std.AutoHashMapUnmanaged(*const PageList.List.Node, u64),

        /// Matches come in runs on the same node, so most lookups repeat
        /// the previous one.
        last_node: ?*const PageList.List.Node = null,
        last_serial: ?u64 = null,

        fn init(alloc: Allocator, pages: *const PageList) Allocator.Error!LiveNodes {
            var serials: std.AutoHashMapUnmanaged(*const PageList.List.Node, u64) = .empty;
            errdefer serials.deinit(alloc);
            var it = pages.pages.first;
            while (it) |node| : (it = node.next) {
                try serials.putNoClobber(alloc, node, node.serial);
            }
            return .{
                .page_serial_min = pages.page_serial_min,
                .serials = serials,
            };
        }

        fn deinit(self: *LiveNodes, alloc: Allocator) void {
            self.serials.deinit(alloc);
        }

        fn isValid(self: *LiveNodes, node: *const PageList.List.Node, serial: u64) bool {
            if (serial < self.page_serial_min) return false;
            if (self.last_node != node) {
                self.last_node = node;
                self.last_serial = self.serials.get(node);
            }
            const live_serial = self.last_serial orelse return false;
            return live_serial == serial;
        }

        /// Whether every chunk of a cached result is on a live page
        /// generation.
        fn resultIsValid(self: *LiveNodes, hl: *const FlattenedHighlight) bool {
            const chunks = hl.chunks.slice();
            for (chunks.items(.node), chunks.items(.serial)) |node, serial| {
                if (!self.isValid(node, serial)) return false;
            }
            return true;
        }
    };

    fn tickActive(self: *ScreenSearch, mutex: ?*std.Thread.Mutex) Allocator.Error!void {
        // For the active area, we consume the entire search in one go
        // because the active area is generally small.
        const alloc = self.allocator();
        var appended = false;
        while (true) {
            const hl = self.active.next() catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                log.warn("error searching active area err={}", .{err});
                if (mutex) |lock| lock.lock();
                defer if (mutex) |lock| lock.unlock();
                self.failSearch();
                return;
            } orelse break;

            // `active.next()` prunes as it advances, so clone before
            // appending to keep result ownership stable.
            var hl_cloned = try hl.clone(alloc);
            errdefer hl_cloned.deinit(alloc);
            try self.active_results.append(alloc, hl_cloned);
            appended = true;
        }
        if (appended) self.markMatchRowsDirty();

        // We've consumed the entire active area, move to history.
        self.state = .history;
    }

    fn tickHistory(
        self: *ScreenSearch,
        mutex: ?*std.Thread.Mutex,
        comptime next: anytype,
        comptime cleanup: anytype,
    ) Allocator.Error!void {
        const history: *HistorySearch = if (self.history) |*h| h else {
            // No history to search, we're done.
            self.state = .complete;
            return;
        };

        // Try to consume all the loaded matches in one go, because
        // the search is generally fast for loaded data.
        const alloc = self.allocator();
        var appended = false;
        while (true) {
            const hl = next(&history.searcher) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                log.warn("error searching history err={}", .{err});
                if (mutex) |lock| lock.lock();
                defer if (mutex) |lock| lock.unlock();
                cleanup(self);
                return;
            } orelse break;

            // Ignore selections that are found within the starting
            // node since those are covered by the active area search.
            if (hl.chunks.items(.node)[0] == history.start_pin.node) continue;

            // Same note as tickActive for error handling.
            var hl_cloned = try hl.clone(alloc);
            errdefer hl_cloned.deinit(alloc);
            try self.history_results.append(alloc, hl_cloned);
            appended = true;

            // Since history only appends to our results in reverse order,
            // we don't need to update any selected match state. The index
            // and prior results are unaffected.
        }
        if (appended) self.markMatchRowsDirty();

        // We need to be fed more data.
        self.state = .history_feed;
    }

    /// Reload the active area because it has changed.
    ///
    /// Since it is very fast, this will also do the full active area
    /// search again, too. This avoids any complexity around the search
    /// state machine.
    ///
    /// The caller must hold the necessary locks to access the screen state.
    pub fn reloadActive(self: *ScreenSearch) Allocator.Error!void {
        return self.reloadActiveWithNext(SlidingWindow.next);
    }

    // A comptime matcher seam lets tests fail after accumulating results.
    fn reloadActiveWithNext(self: *ScreenSearch, comptime next: anytype) Allocator.Error!void {
        // This check must precede all inspection of cached highlights and
        // searchers: column reflow may have freed every node they reference.
        if (try self.resetIfDimensionsChanged()) return;

        // reloadActive only inspects the selected history result, so validate
        // that result without scanning every cached match on this hot path.
        self.validateSelectedHistory();

        const tw = reloadActive_tw;

        // If our selection pin became garbage it means we scrolled off
        // the end. Clear our selection and on exit of this function,
        // try to select the last match.
        const select_prev: bool = select_prev: {
            const m = if (self.selected) |*m| m else break :select_prev false;
            if (!m.highlight.start.garbage and
                !m.highlight.end.garbage) break :select_prev false;

            m.deinit(self.screen);
            self.selected = null;
            break :select_prev true;
        };
        defer if (select_prev) {
            _ = self.select(.prev) catch |err| {
                log.info("reload failed to reset search selection err={}", .{err});
            };
        };

        const alloc = self.allocator();
        const list: *PageList = &self.screen.pages;
        if (try self.active.update(list)) |history_node| history: {
            // We need to account for any active area growth that would
            // cause new pages to move into our history. If there are new
            // pages then we need to re-search the pages and add it to
            // our history results.

            // If our screen has no scrollback then we have no history.
            if (self.screen.no_scrollback) {
                assert(self.history == null);
                break :history;
            }

            const history_: ?*HistorySearch = if (self.history) |*h| state: {
                // If our start pin became garbage, it means we pruned all
                // the way up through it, so we have no history anymore.
                // Reset our history state.
                if (h.start_pin.garbage) {
                    h.deinit(self.screen);
                    self.history = null;
                    const had_results = self.history_results.items.len > 0;
                    for (self.history_results.items) |*hl| hl.deinit(alloc);
                    self.history_results.clearRetainingCapacity();
                    if (had_results) self.markMatchRowsDirty();
                    break :state null;
                }

                break :state h;
            } else null;

            const history = history_ orelse {
                // No history search yet, but we now have history. So let's
                // initialize.

                var search: PageListSearch = PageListSearch.initWithOptions(
                    alloc,
                    self.needle(),
                    self.active.window.query_options,
                    list,
                    history_node,
                ) catch |err|
                    return self.failSearchUnlessOutOfMemory(err, "error initializing history search");
                errdefer search.deinit();

                const pin = try list.trackPin(.{ .node = history_node });
                errdefer list.untrackPin(pin);

                self.history = .{
                    .searcher = search,
                    .start_pin = pin,
                };

                // We don't need to update any history since we had no history
                // before, so we can break out of the whole conditional.
                break :history;
            };

            if (history.start_pin.node == history_node) {
                // No change in the starting node, we're done.
                break :history;
            }

            // Do a forward search from our prior node to this one. We
            // collect all the results into a new list. We ASSUME that
            // reloadActive is being called frequently enough that there isn't
            // a massive amount of history to search here.
            var window: SlidingWindow = SlidingWindow.initWithOptions(
                alloc,
                .forward,
                self.needle(),
                self.active.window.query_options,
            ) catch |err|
                return self.failSearchUnlessOutOfMemory(err, "error initializing active-history reconciliation search");
            defer window.deinit();
            while (true) {
                _ = try window.append(history.start_pin.node);
                if (history.start_pin.node == history_node) break;
                const next_node = history.start_pin.node.next orelse break;
                history.start_pin.node = next_node;
            }
            assert(history.start_pin.node == history_node);

            var results: std.ArrayList(FlattenedHighlight) = try .initCapacity(
                alloc,
                self.history_results.items.len,
            );
            defer {
                for (results.items) |*hl| hl.deinit(alloc);
                results.deinit(alloc);
            }
            while (true) {
                const maybe_hl = next(&window) catch |err|
                    return self.failSearchUnlessOutOfMemory(err, "error refreshing history matches");
                const hl = maybe_hl orelse break;

                if (hl.chunks.items(.node)[0] == history_node) continue;

                var hl_cloned = try hl.clone(alloc);
                errdefer hl_cloned.deinit(alloc);
                try tw.check(.history_append_new);
                try results.append(alloc, hl_cloned);
            }

            // If we have no matches then there is nothing to change
            // in our history (fast path)
            if (results.items.len == 0) break :history;

            // The number added to our history. Needed for updating
            // our selection if we have one.
            const added_len = results.items.len;

            // Matches! Reverse our list then append all the remaining
            // history items that didn't start on our original node.
            std.mem.reverse(FlattenedHighlight, results.items);
            try tw.check(.history_append_existing);
            try results.appendSlice(alloc, self.history_results.items);
            self.history_results.deinit(alloc);
            self.history_results = results;
            results = .empty;
            self.markMatchRowsDirty();

            // If our prior selection was in the history area, update
            // the offset.
            if (self.selected) |*m| selected: {
                const active_len = self.active_results.items.len;
                if (m.idx < active_len) break :selected;
                m.idx += added_len;

                // Moving the idx should not change our targeted result
                // since the history is immutable.
                if (comptime std.debug.runtime_safety) {
                    const hl = self.history_results.items[m.idx - active_len];
                    assert(m.highlight.start.eql(hl.startPin()));
                }
            }
        } else {
            // No history node means we have no history
            if (self.history) |*h| {
                h.deinit(self.screen);
                self.history = null;
                const had_results = self.history_results.items.len > 0;
                for (self.history_results.items) |*hl| hl.deinit(alloc);
                self.history_results.clearRetainingCapacity();
                if (had_results) self.markMatchRowsDirty();
            }

            // If we have a selection in the history area, we need to
            // move it to the end of the active area.
            if (self.selected) |*m| selected: {
                const active_len = self.active_results.items.len;
                if (m.idx < active_len) break :selected;
                m.deinit(self.screen);
                self.selected = null;
                _ = self.select(.prev) catch |err| {
                    log.info("reload failed to reset search selection err={}", .{err});
                };
            }
        }

        // Figure out if we need to fixup our selection later because
        // it was in the active area.
        const old_active_len = self.active_results.items.len;
        const old_selection_idx: ?usize = if (self.selected) |m| m.idx else null;
        errdefer if (old_selection_idx != null and
            old_selection_idx.? < old_active_len)
        {
            // This is the error scenario. If something fails below,
            // our active area is probably gone, so we just go back
            // to the first result because our selection can't be trusted.
            if (self.selected) |*m| {
                m.deinit(self.screen);
                self.selected = null;
                _ = self.select(.next) catch |err| {
                    log.info("reload failed to reset search selection err={}", .{err});
                };
            }
        };

        // Reset our active search results and search again.
        for (self.active_results.items) |*hl| hl.deinit(alloc);
        self.active_results.clearRetainingCapacity();
        self.markMatchRowsDirty();
        switch (self.state) {
            // If we're in the active state we run a normal tick so
            // we can move into a better state.
            .active => try self.tickActive(null),

            // Otherwise, just tick it and move back to whatever state
            // we were in.
            else => {
                const old_state = self.state;
                defer self.state = old_state;
                try self.tickActive(null);
            },
        }

        // If we have no scrollback, we need to prune any active results
        // that aren't in the actual active area. We only do this for the
        // no scrollback scenario because with scrollback we actually
        // rely on our active search searching by page to find history
        // items as well. This is all related to the fact that PageList
        // scrollback limits are discrete by page size except we special
        // case zero.
        if (self.screen.no_scrollback and
            self.active_results.items.len > 0)
        active_prune: {
            const items = self.active_results.items;
            const tl = self.screen.pages.getTopLeft(.active);
            for (0.., items) |i, *hl| {
                if (!tl.before(hl.endPin())) {
                    // Deinit because its going to be pruned no matter
                    // what at some point for not being in the active area.
                    hl.deinit(alloc);
                    continue;
                }

                // In the active area! Since our results are sorted
                // that means everything after this is also in the active
                // area, so we prune up to this i.
                if (i > 0) self.active_results.replaceRangeAssumeCapacity(
                    0,
                    i,
                    &.{},
                );

                break :active_prune;
            }

            // None are in the active area...
            self.active_results.clearRetainingCapacity();
        }

        // Now we have to fixup our selection if we had one.
        fixup: {
            const old_idx = old_selection_idx orelse break :fixup;
            const m = if (self.selected) |*m| m else break :fixup;

            // If our old selection wasn't in the active area, then we
            // need to fix up our offsets.
            if (old_idx >= old_active_len) {
                m.idx -= old_active_len;
                m.idx += self.active_results.items.len;
                break :fixup;
            }

            // We search for the matching highlight in the new active results.
            for (0.., self.active_results.items) |i, hl| {
                const untracked = hl.untracked();
                if (m.highlight.start.eql(untracked.start) and
                    m.highlight.end.eql(untracked.end))
                {
                    // Found it! Update our index.
                    m.idx = self.active_results.items.len - 1 - i;
                    break :fixup;
                }
            }

            // No match, just go back to the first match.
            m.deinit(self.screen);
            self.selected = null;
            _ = self.select(.next) catch |err| {
                log.info("reload failed to reset search selection err={}", .{err});
            };
        }
    }

    /// Return the selected match.
    ///
    /// This does not require read/write access to the underlying screen.
    pub fn selectedMatch(self: *const ScreenSearch) ?FlattenedHighlight {
        const sel = self.selected orelse return null;
        const active_len = self.active_results.items.len;
        if (sel.idx < active_len) {
            return self.active_results.items[active_len - 1 - sel.idx];
        }

        const history_len = self.history_results.items.len;
        if (sel.idx < active_len + history_len) {
            return self.history_results.items[sel.idx - active_len];
        }

        return null;
    }

    pub const Select = enum {
        /// Next selection, in reverse order (newest to oldest),
        /// non-wrapping.
        next,

        /// Prev selection, in forward order (oldest to newest),
        /// non-wrapping.
        prev,
    };

    /// Select the next or previous search result. This requires read/write
    /// access to the underlying screen, since we utilize tracked pins to
    /// ensure our selection sticks with contents changing.
    pub fn select(self: *ScreenSearch, to: Select) Allocator.Error!bool {
        // A resize can replace any page node, including nodes retained by
        // flattened history results. Reset before reloadActive or tracking a
        // selected result so no pre-resize pointer is ever dereferenced.
        _ = try self.resetIfDimensionsChanged();

        // Reload validates the selected history result before inspecting its
        // cached coordinates. Prune the remaining results afterward so every
        // candidate is valid before selection tracks it.
        try self.reloadActive();
        try self.pruneHistory();

        return switch (to) {
            .next => try self.selectNext(),
            .prev => try self.selectPrev(),
        };
    }

    fn selectNext(self: *ScreenSearch) Allocator.Error!bool {
        // Get our previous match so we can change it. If we have no
        // prior match, we have the easy task of getting the first.
        var prev = if (self.selected) |*m| m else {
            // Get our highlight
            const hl: FlattenedHighlight = hl: {
                if (self.active_results.items.len > 0) {
                    // Active is in forward order
                    const len = self.active_results.items.len;
                    break :hl self.active_results.items[len - 1];
                } else if (self.history_results.items.len > 0) {
                    // History is in reverse order
                    break :hl self.history_results.items[0];
                } else {
                    // No matches at all. Can't select anything.
                    return false;
                }
            };

            // Pin it so we can track any movement
            const tracked = try hl.untracked().track(self.screen);
            errdefer tracked.deinit(self.screen);

            // Our selection is index zero since we just started and
            // we store our selection.
            self.selected = .{
                .idx = 0,
                .highlight = tracked,
            };
            return true;
        };

        const active_len = self.active_results.items.len;
        const history_len = self.history_results.items.len;
        const next_idx = if (prev.idx + 1 >= active_len + history_len) 0 else prev.idx + 1;
        const hl: FlattenedHighlight = if (next_idx < active_len)
            self.active_results.items[active_len - 1 - next_idx]
        else
            self.history_results.items[next_idx - active_len];

        // Pin it so we can track any movement
        const tracked = try hl.untracked().track(self.screen);
        errdefer tracked.deinit(self.screen);

        // Free our previous match and setup our new selection
        prev.deinit(self.screen);
        self.selected = .{
            .idx = next_idx,
            .highlight = tracked,
        };

        return true;
    }

    fn selectPrev(self: *ScreenSearch) Allocator.Error!bool {
        // Get our previous match so we can change it. If we have no
        // prior match, we have the easy task of getting the last.
        var prev = if (self.selected) |*m| m else {
            // Get our highlight (oldest match)
            const hl: FlattenedHighlight = hl: {
                if (self.history_results.items.len > 0) {
                    // History is in reverse order, so last item is oldest
                    const len = self.history_results.items.len;
                    break :hl self.history_results.items[len - 1];
                } else if (self.active_results.items.len > 0) {
                    // Active is in forward order, so first item is oldest
                    break :hl self.active_results.items[0];
                } else {
                    // No matches at all. Can't select anything.
                    return false;
                }
            };

            // Pin it so we can track any movement
            const tracked = try hl.untracked().track(self.screen);
            errdefer tracked.deinit(self.screen);

            // Our selection is the last index since we just started
            // and we store our selection.
            const active_len = self.active_results.items.len;
            const history_len = self.history_results.items.len;
            self.selected = .{
                .idx = active_len + history_len - 1,
                .highlight = tracked,
            };
            return true;
        };

        const active_len = self.active_results.items.len;
        const history_len = self.history_results.items.len;
        const next_idx = if (prev.idx != 0) prev.idx - 1 else active_len + history_len - 1;

        const hl: FlattenedHighlight = if (next_idx < active_len)
            self.active_results.items[active_len - 1 - next_idx]
        else
            self.history_results.items[next_idx - active_len];

        // Pin it so we can track any movement
        const tracked = try hl.untracked().track(self.screen);
        errdefer tracked.deinit(self.screen);

        // Free our previous match and setup our new selection
        prev.deinit(self.screen);
        self.selected = .{
            .idx = next_idx,
            .highlight = tracked,
        };

        return true;
    }
};

test "history matcher failure cleans tracked pins under the terminal mutex" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\n");
    while (t.screens.active.pages.totalPages() < 3) stream.nextSlice("\r\n");
    for (0..t.screens.active.pages.rows) |_| stream.nextSlice("\r\n");
    stream.nextSlice("Fizz");
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    _ = try search.select(.next);
    try testing.expect(search.history != null and search.selected != null);
    const revision = search.matchRowsRevision();

    var mutex: std.Thread.Mutex = .{};
    const Probe = struct {
        var mutex_: *std.Thread.Mutex = undefined;
        var scanning_unlocked = false;
        var cleanup_locked = false;
        fn next(_: *PageListSearch) error{ OutOfMemory, InjectedMatcherFailure }!?FlattenedHighlight {
            scanning_unlocked = mutex_.tryLock();
            if (scanning_unlocked) mutex_.unlock();
            return error.InjectedMatcherFailure;
        }
        fn cleanup(search_: *ScreenSearch) void {
            const acquired = mutex_.tryLock();
            cleanup_locked = !acquired;
            if (acquired) mutex_.unlock();
            search_.failSearch();
        }
    };
    Probe.mutex_ = &mutex;
    Probe.scanning_unlocked = false;
    Probe.cleanup_locked = false;
    search.state = .history;
    try search.tickHistory(&mutex, Probe.next, Probe.cleanup);
    try testing.expect(Probe.scanning_unlocked);
    try testing.expect(Probe.cleanup_locked);
    try testing.expect(search.history == null and search.selected == null);
    try testing.expectEqual(@as(usize, 0), search.matchesLen());
    try testing.expect(search.matchRowsRevision() != revision);
    try testing.expectEqual(ScreenSearch.State.complete, search.state);
}

test "simple search" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(2, search.active_results.items.len);
    // We don't test history results since there is overlap

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(2, matches.len);

    {
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
    {
        const sel = matches[1].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "simple search with history" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("hello.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(1, matches.len);

    {
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "reload active with history change" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\n");

    // Start up our search which will populate our initial active area.
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(1, matches.len);
    }

    // Grow into two pages so our history pin will move.
    while (list.totalPages() < 2) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("2Fizz");

    // Active area changed so reload
    try search.reloadActive();
    try search.searchAll();

    // Get all matches
    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(2, matches.len);
        {
            const sel = matches[1].untracked();
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 0,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 3,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
        }
        {
            const sel = matches[0].untracked();
            try testing.expectEqual(point.Point{ .active = .{
                .x = 1,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 4,
                .y = 1,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
        }
    }

    // Reset the screen which will make our pin garbage.
    t.fullReset();
    s.nextSlice("WeFizzing");
    try search.reloadActive();
    try search.searchAll();

    {
        const matches = try search.matches(alloc);
        defer alloc.free(matches);
        try testing.expectEqual(1, matches.len);
        {
            const sel = matches[0].untracked();
            try testing.expectEqual(point.Point{ .active = .{
                .x = 2,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
            try testing.expectEqual(point.Point{ .active = .{
                .x = 5,
                .y = 0,
            } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
        }
    }
}

test "active change contents" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fuzz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);

    // Erase the screen, move our cursor to the top, and change contents.
    s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    s.nextSlice("Bang\r\nFizz\r\nHello!");

    try search.reloadActive();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(1, matches.len);

    {
        const sel = matches[0].untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select next" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();

    // Initially no selection
    try testing.expect(search.selectedMatch() == null);

    // Select our next match (first)
    try search.searchAll();
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Next match
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Next match (wrap)
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select after resize resets stale flattened results" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\nBuzz");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(try search.select(.next));
    try testing.expect(search.selectedMatch() != null);
    try testing.expectEqual(@as(size.CellCountInt, 10), search.cols);

    // Column reflow replaces the nodes referenced by the cached flattened
    // active result. select() calls reloadActive(), so dimension invalidation
    // must run before either path dereferences those old nodes.
    try t.screens.active.pages.resize(.{ .cols = 5 });
    try testing.expectEqual(@as(size.CellCountInt, 10), search.cols);

    try testing.expect(try search.select(.next));
    try testing.expectEqual(@as(size.CellCountInt, 5), search.cols);

    const selected = search.selectedMatch().?.untracked();
    try testing.expectEqual(@as(size.CellCountInt, 5), selected.start.node.data.size.cols);
    try testing.expectEqual(@as(size.CellCountInt, 5), selected.end.node.data.size.cols);
}

test "reload after resize resets stale flattened results" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 3,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("Fizz\r\nBuzz");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(try search.select(.next));
    const revision = search.matchRowsRevision();

    // The search thread reloads the active area when the renderer reports
    // a resized viewport, before any feed sees the new dimensions.
    try t.screens.active.pages.resize(.{ .cols = 5 });
    try search.reloadActive();
    try testing.expectEqual(@as(size.CellCountInt, 5), search.cols);
    try testing.expect(search.selected == null);
    try testing.expect(search.matchRowsRevision() != revision);

    const match = search.active_results.items[0].untracked();
    try testing.expectEqual(@as(size.CellCountInt, 5), match.start.node.data.size.cols);
}

test "select in active changes contents completely" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    _ = try search.select(.next);
    _ = try search.select(.next);
    {
        // Initial selection is the first fizz
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Erase the screen, move our cursor to the top, and change contents.
    s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    s.nextSlice("Fuzz\r\nFizz\r\nHello!");

    try search.reloadActive();
    {
        // Our selection should move to the first
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Erase the screen, redraw with same contents.
    s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    s.nextSlice("Fuzz\r\nFizz\r\nFizz");

    try search.reloadActive();
    {
        // Our selection should not move to the first
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select into history" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("hello.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Get all matches
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Erase the screen, redraw with same contents.
    s.nextSlice("\x1b[2J\x1b[H"); // Clear screen and move home
    s.nextSlice("yo yo");

    try search.reloadActive();
    {
        // Our selection should not move since the history is still active.
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Create some new history by adding more lines.
    s.nextSlice("\r\nfizz\r\nfizz\r\nfizz"); // Clear screen and move home
    try search.reloadActive();
    {
        // Our selection should not move since the history is still not
        // pruned.
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select prev" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();

    // Initially no selection
    try testing.expect(search.selectedMatch() == null);

    // Select prev (oldest first)
    try search.searchAll();
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Prev match (towards newest)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Prev match (wrap)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }
}

test "select prev then next" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz\r\nBuzz\r\nFizz\r\nBang");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Select next (newest first)
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }

    // Select next (older)
    _ = try search.select(.next);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }

    // Select prev (back to newer)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
    }
}

test "select prev with history" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Fizz.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Select prev (oldest first, should be in history)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 0,
        } }, t.screens.active.pages.pointFromPin(.screen, sel.end).?);
    }

    // Select prev (towards newer, should move to active area)
    _ = try search.select(.prev);
    {
        const sel = search.selectedMatch().?.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 0,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 3,
            .y = 1,
        } }, t.screens.active.pages.pointFromPin(.active, sel.end).?);
    }
}

test "select prev wraps when every match is in history" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    // The only match scrolls into history and the active area has none, so
    // wrapping from the first match computed `active_len - 1` on zero.
    s.nextSlice("Fizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Buzz.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(@as(usize, 0), search.active_results.items.len);
    try testing.expectEqual(@as(usize, 1), search.history_results.items.len);

    _ = try search.select(.prev);
    _ = try search.select(.prev);
    const sel = search.selectedMatch().?.untracked();
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 0,
    } }, t.screens.active.pages.pointFromPin(.screen, sel.start).?);
}

test "select after all matches disappear drops the selection" {
    // The wrap arithmetic in selectPrev (active_len + history_len - 1) would
    // underflow if a selection were ever live while both result lists are
    // empty. This guards the invariant that makes that unreachable: when a
    // reload/prune empties the results, the selection is dropped, so the next
    // select() hits the "no matches" guard instead of the wrap arithmetic.
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.active_results.items.len);

    // Take a selection, then overwrite the only match so a reload finds none
    // (active and history both empty).
    _ = try search.select(.next);
    try testing.expect(search.selectedMatch() != null);
    s.nextSlice("\x1b[1;1H    ");

    // Must not underflow; the selection is dropped and nothing is selected.
    _ = try search.select(.prev);
    try testing.expect(search.selectedMatch() == null);
    try testing.expectEqual(0, search.active_results.items.len);
    try testing.expectEqual(0, search.history_results.items.len);
}

test "select after partial history erase drops a pruned selection" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice("error\r\n");
    const first = list.pages.first.?;
    while (list.totalPages() < 3) stream.nextSlice("\r\n");
    const first_rows = first.data.size.rows;

    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);
    try testing.expectEqual(1, search.history_results.items.len);
    try testing.expect(try search.select(.next));

    list.eraseHistory(.{ .history = .{ .y = first_rows - 1 } });
    try testing.expect(!search.selected.?.highlight.start.garbage);

    try testing.expect(!try search.select(.next));
    try testing.expect(search.selected == null);
}

test "select after a history page is replaced ignores its results" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice("error\r\n");
    const first = list.pages.first.?;
    while (list.totalPages() < 3) stream.nextSlice("\r\n");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.history_results.items.len);

    // compact() never replaces a page of standard size or smaller, so
    // replace the page through increaseCapacity, as the capacity retries
    // in Screen do.
    const replacement = try list.increaseCapacity(first, null);
    try testing.expect(replacement != first);

    try testing.expect(!try search.select(.next));
    try testing.expect(search.selected == null);
}

test "reload after a history page is replaced drops the stale selection first" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice("error\r\n");
    const first = list.pages.first.?;
    while (list.totalPages() < 3) stream.nextSlice("\r\n");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(try search.select(.next));
    try testing.expect(search.selected != null);

    // The replacement moves the selection's tracked pins to the new node,
    // while the cached history result still names the old one.
    _ = try list.increaseCapacity(first, null);

    // Advance the active boundary into another node and add matches so
    // reloadActive updates the history result offsets. It must discard the
    // stale selected result before comparing any of its captured coordinates.
    const active_node = list.getTopLeft(.active).node;
    while (list.getTopLeft(.active).node == active_node) {
        stream.nextSlice("error\r\n");
    }

    try search.reloadActive();
    try testing.expect(search.selected == null);
}

test "reload defers pruning unselected history results" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice("error\r\n");
    const first = list.pages.first.?;
    while (list.totalPages() < 3) stream.nextSlice("\r\n");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.history_results.items.len);

    _ = try list.increaseCapacity(first, null);

    // Routine active refreshes don't inspect unselected history results.
    try search.reloadActive();
    try testing.expectEqual(1, search.history_results.items.len);

    // Selection prunes every candidate before attempting to track it.
    try testing.expect(!try search.select(.next));
    try testing.expectEqual(0, search.history_results.items.len);
}

test "prune keeps an older selected history match when a newer page is replaced" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice("error\r\n");
    while (list.totalPages() < 2) stream.nextSlice("\r\n");
    stream.nextSlice("error\r\n");
    const newer = list.pages.last.?;
    while (list.totalPages() < 4) stream.nextSlice("\r\n");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);
    try testing.expectEqual(2, search.history_results.items.len);
    try testing.expect(try search.select(.next));
    try testing.expect(try search.select(.next));
    try testing.expectEqual(1, search.selected.?.idx);
    const older = search.history_results.items[1].startPin();

    _ = try list.increaseCapacity(newer, null);
    try search.pruneHistory();
    try testing.expectEqual(1, search.history_results.items.len);
    try testing.expectEqual(0, search.selected.?.idx);
    try testing.expect(search.selectedMatch().?.startPin().eql(older));
    try testing.expect(search.selected.?.highlight.start.eql(older));
}

test "LiveNodes agrees with PageList.nodeIsValid" {
    const alloc = testing.allocator;
    var list: PageList = try .init(alloc, 10, 2, null);
    defer list.deinit();
    const first = list.pages.first.?;
    while (first.data.size.rows < first.data.capacity.rows) _ = try list.grow();
    _ = try list.grow();

    const old_serial = first.serial;
    const replacement = try list.increaseCapacity(first, null);

    var live: ScreenSearch.LiveNodes = try .init(alloc, &list);
    defer live.deinit(alloc);
    const cases = [_]struct { *PageList.List.Node, u64 }{
        .{ first, old_serial },
        .{ replacement, replacement.serial },
        .{ replacement, old_serial },
        .{ list.pages.last.?, list.pages.last.?.serial },
        .{ list.pages.last.?, list.pages.last.?.serial + 1 },
    };
    for (cases) |case| {
        const node, const serial = case;
        try testing.expectEqual(list.nodeIsValid(node, serial), live.isValid(node, serial));
    }
    try testing.expect(!live.isValid(first, old_serial));
    try testing.expect(live.isValid(replacement, replacement.serial));
}

test "prune keeps a history match across a page boundary" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var stream = t.vtStream();
    defer stream.deinit();

    // The first page's last row ends in "hell" and the match wraps onto
    // the second page.
    const first_page_rows = list.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| stream.nextSlice("\r\n");
    for (0..list.cols - 4) |_| stream.nextSlice("x");
    stream.nextSlice("hello, world");
    while (list.totalPages() < 4) stream.nextSlice("\r\n");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "hello, world");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(1, search.history_results.items.len);
    try testing.expectEqual(2, search.history_results.items[0].chunks.len);

    try search.pruneHistory();
    try testing.expectEqual(1, search.history_results.items.len);
}

test "screen search no scrollback has no history" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer t.deinit(alloc);

    // Alt screen has no scrollback
    _ = try t.switchScreen(.alternate);

    var s = t.vtStream();
    defer s.deinit();

    // This will probably stop working at some point and we'll have
    // no way to test it using public APIs, but at the time of writing
    // this test, CSI 22 J (scroll complete) pushes into scrollback
    // with alt screen.
    s.nextSlice("Fizz\r\n");
    s.nextSlice("\x1b[22J");
    s.nextSlice("hello.");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expectEqual(0, search.active_results.items.len);

    // Get all matches
    const matches = try search.matches(alloc);
    defer alloc.free(matches);
    try testing.expectEqual(0, matches.len);
}

test "reloadActive temporary history cleanup on matcher failure or no new matches" {
    for ([_]?usize{ 0, 1, null }) |matches_before_failure| {
        const alloc = testing.allocator;
        var t: Terminal = try .init(alloc, .{
            .cols = 10,
            .rows = 2,
            .max_scrollback = std.math.maxInt(usize),
        });
        defer t.deinit(alloc);
        const list = &t.screens.active.pages;
        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("Fizz\r\nFizz\r\n");
        while (list.totalPages() < 3) s.nextSlice("\r\n");
        for (0..list.rows) |_| s.nextSlice("\r\n");
        s.nextSlice(if (matches_before_failure != null) "Fizz." else "noop");

        var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
        defer search.deinit();
        try search.searchAll();
        _ = try search.select(.next);
        try testing.expect(search.history_results.items.len > 0);
        const history_len = search.history_results.items.len;
        try testing.expect(search.selected != null);
        const revision = search.matchRowsRevision();

        s.nextSlice(if (matches_before_failure != null) "\r\nFizz\r\nFizz\r\n" else "\r\nnoop\r\n");
        while (list.totalPages() < 4) s.nextSlice("\r\n");
        for (0..list.rows) |_| s.nextSlice("\r\n");

        const Probe = struct {
            var remaining: usize = 0;
            var failed = false;
            fn next(window: *SlidingWindow) (SlidingWindow.SearchError || error{InjectedMatcherFailure})!?FlattenedHighlight {
                if (remaining == 0) {
                    failed = true;
                    return error.InjectedMatcherFailure;
                }
                const hl = try window.next();
                if (hl != null) remaining -= 1;
                return hl;
            }
        };
        Probe.remaining = matches_before_failure orelse 0;
        Probe.failed = false;

        if (matches_before_failure == null) {
            // No new matches still reserves capacity for the old results.
            // Exercise the real matcher and its successful empty fast path.
            try search.reloadActive();
            try testing.expect(search.history != null);
            try testing.expectEqual(history_len, search.history_results.items.len);
            continue;
        }

        // A matcher error is logged and consumed, so errdefer cannot own
        // either the reserved results buffer or its already cloned match.
        try search.reloadActiveWithNext(Probe.next);
        try testing.expect(Probe.failed);
        try testing.expectEqual(@as(usize, 0), Probe.remaining);
        try testing.expect(search.history == null and search.selected == null);
        try testing.expectEqual(@as(usize, 0), search.matchesLen());
        try testing.expectEqual(ScreenSearch.State.complete, search.state);
        try testing.expect(search.matchRowsRevision() != revision);
    }
}

test "reloadActive partial history cleanup on appendSlice error" {
    // This test verifies that when reloadActive fails at appendSlice (after
    // the loop), all FlattenedHighlight items are properly cleaned up.
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    // Write multiple "Fizz" matches that will end up in history.
    // We need enough content to push "Fizz" entries into scrollback.
    s.nextSlice("Fizz\r\nFizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Fizz.");

    // Complete initial search
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Now trigger reloadActive by adding more content that changes the
    // active/history boundary. First add more "Fizz" entries to history.
    s.nextSlice("\r\nFizz\r\nFizz\r\n");
    while (list.totalPages() < 4) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");

    // Arm the tripwire to fail at appendSlice (after the loop completes).
    // At this point, there are FlattenedHighlight items in the results list
    // that need cleanup.
    const tw = reloadActive_tw;
    defer tw.end(.reset) catch unreachable;
    tw.errorAlways(.history_append_existing, error.OutOfMemory);

    // reloadActive is called by select(), which should trigger the error path.
    // If the bug exists, testing.allocator will report a memory leak
    // because FlattenedHighlight items weren't cleaned up.
    try testing.expectError(error.OutOfMemory, search.select(.next));
}

test "reloadActive partial history cleanup on loop append error" {
    // This test verifies that when reloadActive fails inside the loop
    // (after some items have been appended), all FlattenedHighlight items
    // are properly cleaned up.
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    // Write multiple "Fizz" matches that will end up in history.
    // We need enough content to push "Fizz" entries into scrollback.
    s.nextSlice("Fizz\r\nFizz\r\n");
    while (list.totalPages() < 3) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("Fizz.");

    // Complete initial search
    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    // Now trigger reloadActive by adding more content that changes the
    // active/history boundary. First add more "Fizz" entries to history.
    s.nextSlice("\r\nFizz\r\nFizz\r\n");
    while (list.totalPages() < 4) s.nextSlice("\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");

    // Arm the tripwire to fail after the first loop append succeeds.
    // This leaves at least one FlattenedHighlight in the results list
    // that needs cleanup.
    const tw = reloadActive_tw;
    defer tw.end(.reset) catch unreachable;
    tw.errorAfter(.history_append_new, error.OutOfMemory, 1);

    // reloadActive is called by select(), which should trigger the error path.
    // If the bug exists, testing.allocator will report a memory leak
    // because FlattenedHighlight items weren't cleaned up.
    try testing.expectError(error.OutOfMemory, search.select(.next));
}

test "select after clearing scrollback" {
    // Regression test for: https://github.com/ghostty-org/ghostty/issues/11957
    // After clearing scrollback (CSI 3J), selecting next/prev should not crash.
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 10,
        .rows = 2,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    // Write enough content to push matches into scrollback history.
    s.nextSlice("error\r\n");
    while (list.totalPages() < 3) s.nextSlice("error\r\n");
    for (0..list.rows) |_| s.nextSlice("\r\n");
    s.nextSlice("error.");

    // Start search and find all matches.
    var search: ScreenSearch = try .init(alloc, t.screens.active, "error");
    defer search.deinit();
    try search.searchAll();

    // Should have matches in both history and active areas.
    try testing.expect(search.history_results.items.len > 0);
    try testing.expect(search.active_results.items.len > 0);

    // Select a match first (so we have a selection).
    _ = try search.select(.next);
    try testing.expect(search.selected != null);

    // Clear scrollback (equivalent to CSI 3J / Cmd+K erasing scrollback).
    t.eraseDisplay(.scrollback, false);

    // Selecting next/prev after clearing scrollback should not crash.
    // Before the fix, this would hit an assertion in trackPin because
    // the FlattenedHighlight contained dangling node pointers.
    _ = try search.select(.next);
    _ = try search.select(.prev);
}

test "matchRows returns ascending unique screen rows" {
    const alloc = testing.allocator;
    var t: Terminal = try .init(alloc, .{
        .cols = 20,
        .rows = 4,
        .max_scrollback = std.math.maxInt(usize),
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("Fizz Fizz\r\nnoop\r\nFizz");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();

    const rows = try search.matchRows(alloc);
    defer alloc.free(rows);

    try testing.expectEqualSlices(u32, &.{ 0, 2 }, rows);
}

/// `matchRows` as it was computed before it walked the page list once:
/// `pointFromPin` for every match, then sorted and deduplicated.
fn testMatchRowsByPointFromPin(search: *ScreenSearch, alloc: Allocator) ![]u32 {
    var rows: std.ArrayList(u32) = .empty;
    errdefer rows.deinit(alloc);
    const pages = &search.screen.pages;
    for ([_][]const FlattenedHighlight{
        search.active_results.items,
        search.history_results.items,
    }) |results| for (results) |hl| {
        const pt = pages.pointFromPin(.screen, hl.startPin()) orelse continue;
        try rows.append(alloc, pt.screen.y);
    };
    std.mem.sort(u32, rows.items, {}, std.sort.asc(u32));
    var write: usize = 0;
    for (rows.items) |row| {
        if (write > 0 and rows.items[write - 1] == row) continue;
        rows.items[write] = row;
        write += 1;
    }
    rows.shrinkRetainingCapacity(write);
    return try rows.toOwnedSlice(alloc);
}

fn testExpectPointFromPinRows(search: *ScreenSearch) !void {
    const alloc = testing.allocator;
    const expected = try testMatchRowsByPointFromPin(search, alloc);
    defer alloc.free(expected);
    const rows = try search.matchRows(alloc);
    defer alloc.free(rows);
    try testing.expectEqualSlices(u32, expected, rows);
}

test "matchRows gives the rows pointFromPin gives, across pages, pruning and clearing" {
    const alloc = testing.allocator;

    // Room for about three pages, so more output prunes the oldest page.
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
    const list: *PageList = &t.screens.active.pages;

    var s = t.vtStream();
    defer s.deinit();

    // Rows with two matches, one match and none.
    const lines = [_][]const u8{ "Fizz Fizz\r\n", "noop\r\n", "x Fizz\r\n" };
    var line: usize = 0;
    while (list.totalPages() < 3) : (line += 1) s.nextSlice(lines[line % lines.len]);
    s.nextSlice("Fizz");

    var search: ScreenSearch = try .init(alloc, t.screens.active, "Fizz");
    defer search.deinit();
    try search.searchAll();
    try testing.expect(search.history_results.items.len > 0);
    try testing.expect(search.active_results.items.len > 0);
    try testExpectPointFromPinRows(&search);

    // Prune the oldest pages without telling the search. A pruned page is
    // reused as the newest one, so its old matches map near the bottom.
    const first_serial = list.pages.first.?.serial;
    while (list.pages.first.?.serial == first_serial) : (line += 1) {
        if (line > 1_000_000) return error.TestScrollbackNeverPruned;
        s.nextSlice(lines[line % lines.len]);
    }
    const oldest = search.history_results.items[search.history_results.items.len - 1];
    try testing.expect(!list.nodeIsValid(
        oldest.chunks.items(.node)[0],
        oldest.chunks.items(.serial)[0],
    ));
    try testExpectPointFromPinRows(&search);

    // Once the search has caught up.
    try search.reloadActive();
    try search.feed();
    try testExpectPointFromPinRows(&search);

    // Clear the scrollback without telling the search: the history pages
    // are destroyed, so the history results name nodes no longer in the
    // list, which have no row. (Their rows within those pages can coincide
    // with remaining rows, so check them one by one.)
    t.eraseDisplay(.scrollback, false);
    var node_rows: ScreenSearch.NodeRows = try .init(alloc, list);
    defer node_rows.deinit(alloc);
    for (search.history_results.items) |hl| {
        try testing.expect(list.pointFromPin(.screen, hl.startPin()) == null);
        try testing.expect(node_rows.screenRow(hl.startPin()) == null);
    }
    try testExpectPointFromPinRows(&search);
}
