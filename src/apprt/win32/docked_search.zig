//! One pane's docked search state: the query, the regex/case/word toggles,
//! what the core last reported, the 40 ms debounce and the Alt+R/C/W press
//! pairing. No HWND creation, painting or keybind dispatch: those belong to
//! the Win32 surface layer (`search_controls.zig`).
//!
//! `apply` takes an input and returns what the window and the core must do
//! (`Outcome`); `view` says what to draw. Nothing here calls the core, Win32
//! or the clock, and `apply` finishes its whole state change before it
//! returns, so the core can call back into it while the caller carries out
//! an Outcome. A View's slices, and a `Command.search` text, are valid until
//! the next `apply`, a re-entrant one included.
//!
//! **Debounce rationale.**  Scrollback search is O(lines * query_len).
//! Re-running on every WM_COMMAND / EN_CHANGE would stall the UI on
//! large histories.  A 40 ms window batches rapid keystrokes into a
//! single search pass while feeling instantaneous to the user.
//!
//! **Toggle persistence across close.**  Closing the bar (Esc) hides
//! the visual but preserves query + toggles so that re-opening (Ctrl+F)
//! restores the previous search context.  Users iterating on
//! case/word filters shouldn't lose progress.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("consts.zig");

pub const debounce_ms: i64 = 40;

/// The regex, case and whole-word toggles, as the core takes them.
pub const QueryOptions = @import("../../terminal/search/query_options.zig").QueryOptions;

const NavigateSearch = @import("../../input.zig").Binding.Action.NavigateSearch;

/// The docked search bar's buttons, in the order the bar lays them out.
pub const Role = enum {
    prev,
    next,
    regex,
    case_sensitive,
    whole_word,
    close,
};

/// The modifier keys of one key press, read once by the caller. Decisions
/// take this instead of asking the keyboard, so a test states it. AltGr
/// reports as Ctrl and Alt together, and no rule here counts that as Alt.
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
};

pub const Input = union(enum) {
    /// start_search and the Find menus; "" opens on the last query.
    open: []const u8,
    /// The edit's text after EN_CHANGE, borrowed for the call.
    edit: []const u8,
    /// A button's BN_CLICKED.
    click: Role,
    /// A key message at the edit or a button, once the procedure has taken
    /// Ctrl+F6, Tab and the edit's WM_CHAR swallow.
    key: Key,
    /// The host's search timer fired.
    tick,
    /// A core action for this pane.
    core: Core,

    pub const Key = struct {
        /// WM_KEYDOWN, WM_SYSKEYDOWN, WM_SYSCHAR, WM_KILLFOCUS.
        event: enum { down, sys_down, sys_char, blur },
        at: enum { edit, button },
        vk: usize = 0,
        mods: Mods = .{},
        /// lParam bits 16..24.
        scan: u9 = 0,
        /// KF_REPEAT: an autorepeat of a held key.
        repeat: bool = false,
    };

    pub const Core = union(enum) {
        total: struct { total: ?usize, invalid: bool = false },
        /// 1-based, newest first (`apprtSearchSelectedIndex`).
        selected: ?usize,
        /// Copied: the caller may free its slice once `apply` returns.
        rows: []const u32,
        /// end_search, which also arrives from inside `Command.end`.
        ended,
    };
};

/// What the core must do: at most one per `apply`.
pub const Command = union(enum) {
    /// `setSearchQuery(text, options)`.
    search: struct { text: []const u8, options: QueryOptions },
    /// `setSearchQuery("", .{})`.
    stop,
    /// `invalidateSearchResults()`.
    invalidate,
    /// `navigate_search`, in the core's terms: matches are numbered newest
    /// first, so the visible Up (previous) button asks for `.next`.
    navigate: NavigateSearch,
    /// `endSearch()`, which reports `.core.ended` and then, when the core
    /// had a search, the null clears, before it returns.
    end,
};

/// What the window and the core must do after an `apply`. The adapter
/// (`search_controls.applyDockedSearch`) carries the fields out in the
/// order they are declared: `core` is next to last because the core
/// reports back into `apply` while it runs, and `frame` comes before it so
/// a search starts against the pane's new size.
pub const Outcome = struct {
    /// The input was search's: the window procedure returns 0.
    handled: bool = false,
    /// A toggle flipped: raise its UIA ToggleChanged and repaint the
    /// buttons. First, so the toggle is announced before the results.
    toggled: ?Role = null,
    /// Write `view().results` to the chip and raise its live region once.
    /// Only while the bar is open: a closed bar's chip is hidden.
    results_changed: bool = false,
    /// Clear the scrollbar markers and refresh the scrollbar window.
    markers_changed: bool = false,
    /// `relayout`: the chip appeared or went, so lay the host out again.
    /// `shown`: write `view().query` to the edit and `view().results` to the
    /// chip (which may be stale from while the bar was closed), lay out,
    /// repaint and focus the edit. `hidden`: hide the controls, lay out and
    /// repaint.
    frame: enum { same, relayout, shown, hidden } = .same,
    /// Refresh the host's search timer (`view().wants_tick`).
    timer_changed: bool = false,
    core: ?Command = null,
    /// Give the terminal the keyboard focus.
    focus_terminal: bool = false,
};

/// What the results chip says.
pub const Results = union(enum) {
    /// No query.
    idle,
    /// The debounce, or the core's first answer, is still to come.
    pending,
    /// The core could not compile the query.
    invalid,
    none,
    /// `selected` is 1-based and newest first, as the core numbers matches.
    count: struct { selected: ?usize, total: usize },

    pub const Tone = enum { pending, no_match, found };

    pub fn text(self: Results, buf: *[48]u8) []const u8 {
        return switch (self) {
            .idle => "Type to search",
            .pending => "Searching",
            .invalid => "Invalid pattern",
            .none => "No matches",
            // Two usize values and a slash fit in 48 bytes.
            .count => |count| if (count.selected) |selected|
                std.fmt.bufPrint(buf, "{d}/{d}", .{ selected, count.total }) catch unreachable
            else
                std.fmt.bufPrint(buf, "{d}", .{count.total}) catch unreachable,
        };
    }

    pub fn tone(self: Results) Tone {
        return switch (self) {
            .idle, .pending => .pending,
            .invalid, .none => .no_match,
            .count => .found,
        };
    }

    pub fn eql(a: Results, b: Results) bool {
        return std.meta.eql(a, b);
    }
};

pub const View = struct {
    open: bool,
    query: []const u8,
    /// The query is not empty, so the layout gives the chip a slot (it may
    /// still drop it for width).
    chip: bool,
    results: Results,
    options: QueryOptions,
    /// The host's search timer has a debounce to wait out here.
    wants_tick: bool,
    /// Rows of the matches, for the scrollbar markers.
    match_rows: []const u32,
};

pub const DockedSearch = struct {
    open: bool = false,
    query: []u8 = &.{},
    options: QueryOptions = .{},
    /// What the core last reported: the total, and the selected match's
    /// newest-first index (the core's 1-based number minus one).
    total: ?usize = null,
    selected_raw: ?usize = null,
    /// The core could not compile the query (an invalid regular expression).
    /// Every edit or toggle clears it, because the answer belongs to the
    /// query that was searched.
    invalid: bool = false,
    /// When the debounce fires; null when no edit waits for it.
    deadline: ?i64 = null,
    /// The core's answer says nothing of the query (a null total, or a null
    /// selection with no total), or the bar closed on a query: the chip
    /// reads "Searching", and opening or navigating searches again. Unlike
    /// the debounce, it drops no report and keeps no timer running.
    awaiting: bool = false,
    /// A query was edited or searched and not stopped since. The core
    /// searches for `query` when this is set and neither the debounce nor
    /// `awaiting` holds (`live`).
    active: bool = false,
    /// The rows of the matches, owned, for the scrollbar markers.
    match_rows: []const u32 = &.{},
    /// The scan code of the Alt+R/C/W press whose WM_SYSCHAR is still to
    /// come.
    pending_scan: ?u9 = null,
    alloc: Allocator,

    pub fn init(alloc: Allocator) DockedSearch {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DockedSearch) void {
        if (self.query.len > 0) self.alloc.free(self.query);
        if (self.match_rows.len > 0) self.alloc.free(self.match_rows);
        self.* = undefined;
    }

    /// Fails only to copy what the input carries, and then changes nothing.
    pub fn apply(self: *DockedSearch, in: Input, now_ms: i64) Allocator.Error!Outcome {
        const before = self.results();
        var out: Outcome = switch (in) {
            .open => |needle| try self.show(needle),
            .edit => |text| try self.edit(text, now_ms),
            .click => |role| switch (role) {
                .prev => self.navigate(.next),
                .next => self.navigate(.previous),
                .regex, .case_sensitive, .whole_word => self.toggle(role),
                .close => dismiss,
            },
            .key => |k| self.key(k),
            .tick => if (self.open and self.debounceDue(now_ms)) self.issue() else .{},
            .core => |core| try self.report(core),
        };
        // A hidden chip is left alone, so a close announces nothing; `.shown`
        // writes it when the bar opens again.
        out.results_changed = self.open and !before.eql(self.results());
        return out;
    }

    pub fn view(self: *const DockedSearch) View {
        return .{
            .open = self.open,
            .query = self.query,
            .chip = self.query.len > 0,
            .results = self.results(),
            .options = self.options,
            .wants_tick = self.open and self.deadline != null,
            .match_rows = self.match_rows,
        };
    }

    fn show(self: *DockedSearch, needle: []const u8) Allocator.Error!Outcome {
        const initial = if (needle.len > 0) needle else self.query;
        const same = std.mem.eql(u8, self.query, initial);
        // The core already searches for this query, so its results stay.
        const restore = initial.len > 0 and same and self.live();
        if (!same) try self.setQuery(initial, 0);
        self.open = true;
        if (!restore) {
            self.total = null;
            self.selected_raw = null;
        }
        self.deadline = null;
        self.awaiting = false;
        var out: Outcome = if (initial.len > 0 and !restore) self.issue() else .{ .handled = true, .timer_changed = true };
        out.frame = .shown;
        return out;
    }

    /// The bar hides; the query and the toggles stay for the next open.
    fn close(self: *DockedSearch) Outcome {
        self.open = false;
        self.setActive(false);
        return .{ .handled = true, .markers_changed = true, .frame = .hidden, .timer_changed = true };
    }

    fn navigate(self: *DockedSearch, dir: NavigateSearch) Outcome {
        if (self.query.len == 0) return .{ .handled = true };
        if (!self.live()) return self.issue();
        // The selection moves at once; the core's report of it follows.
        self.selected_raw = self.advance(dir);
        self.awaiting = self.selected_raw == null and self.total == null;
        return .{ .handled = true, .core = .{ .navigate = dir } };
    }

    /// The core searches for the query: a search is active, no debounce
    /// holds it back, and the core has not cleared it. Otherwise opening
    /// and navigating search again.
    fn live(self: *const DockedSearch) bool {
        return self.active and self.deadline == null and !self.awaiting;
    }

    /// The raw index one step `dir` from the selection, wrapping; null
    /// when nothing is selected among the matches counted.
    fn advance(self: *const DockedSearch, dir: NavigateSearch) ?usize {
        const index = self.selected_raw orelse return null;
        const count = self.total orelse return null;
        if (count == 0 or index >= count) return null;
        const last = count - 1;
        return switch (dir) {
            .next => if (index >= last) 0 else index + 1,
            .previous => if (index == 0) last else index - 1,
        };
    }

    /// The core's `endSearch` reports end_search, which hides the bar,
    /// before its clears, so they reach a closed bar and write no chip.
    const dismiss: Outcome = .{ .handled = true, .core = .end, .focus_terminal = true };

    fn key(self: *DockedSearch, k: Input.Key) Outcome {
        switch (k.event) {
            .blur => {
                self.pending_scan = null;
                return .{};
            },
            // Swallowed when it is the character of the Alt+R/C/W just
            // handled, found by scan code: on another layout the character
            // need not be Latin.
            .sys_char => {
                const pending = self.pending_scan;
                self.pending_scan = null;
                return .{ .handled = if (pending) |scan| scan == k.scan else false };
            },
            .down => {},
            // Alt+R, Alt+C and Alt+W flip regex, case and whole word: Alt
            // without Ctrl (AltGr reports as Ctrl+Alt and types on many
            // layouts) and without Shift. A held key does not flip again,
            // and any other system key forgets the press.
            .sys_down => {
                const role: ?Role = if (!k.mods.alt or k.mods.ctrl or k.mods.shift) null else switch (k.vk) {
                    'R' => .regex,
                    'C' => .case_sensitive,
                    'W' => .whole_word,
                    else => null,
                };
                self.pending_scan = if (role != null) k.scan else null;
                if (role) |flip| return if (k.repeat) .{ .handled = true } else self.toggle(flip);
            },
        }
        // Enter, Down and F3 step down the bar (visible next); with Shift,
        // and Up, they step up. The core numbers matches newest first, so
        // down is core `.previous`. A held key keeps stepping.
        const step: NavigateSearch = if (k.mods.shift) .next else .previous;
        return switch (k.at) {
            .edit => switch (k.vk) {
                c.VK_RETURN, c.VK_F3 => self.navigate(step),
                c.VK_UP => self.navigate(.next),
                c.VK_DOWN => self.navigate(.previous),
                c.VK_ESCAPE => dismiss,
                else => .{},
            },
            // Enter on a button is its click, and Tab its focus step. Escape
            // ends the search of the button's own pane, when there is one.
            .button => if (k.event != .down) .{} else switch (k.vk) {
                c.VK_F3 => self.navigate(step),
                c.VK_ESCAPE => if (self.active or self.open) dismiss else .{ .handled = true },
                else => .{},
            },
        };
    }

    fn edit(self: *DockedSearch, text: []const u8, now_ms: i64) Allocator.Error!Outcome {
        const previous_len = self.query.len;
        try self.setQuery(text, now_ms);
        self.setActive(text.len > 0);
        return .{
            .handled = true,
            .markers_changed = true,
            // Only the chip's slot moves the controls, and it follows
            // whether there is a query.
            .frame = if ((previous_len == 0) != (text.len == 0)) .relayout else .same,
            .timer_changed = true,
            // Once a query has reached the core, an edit invalidates it
            // until the debounced replacement runs.
            .core = if (previous_len == 0) null else if (text.len == 0) .stop else .invalidate,
        };
    }

    fn toggle(self: *DockedSearch, role: Role) Outcome {
        switch (role) {
            .regex => self.options.regex = !self.options.regex,
            .case_sensitive => self.options.case_sensitive = !self.options.case_sensitive,
            .whole_word => self.options.whole_word = !self.options.whole_word,
            .prev, .next, .close => unreachable,
        }
        var out: Outcome = if (self.query.len > 0) self.issue() else .{ .handled = true };
        // A search under the old options says nothing of the new ones.
        self.total = null;
        self.selected_raw = null;
        self.invalid = false;
        out.toggled = role;
        return out;
    }

    /// The query, which is not empty, goes to the core now.
    fn issue(self: *DockedSearch) Outcome {
        self.deadline = null;
        self.awaiting = false;
        self.setActive(true);
        return .{
            .handled = true,
            .markers_changed = true,
            .timer_changed = true,
            .core = .{ .search = .{ .text = self.query, .options = self.options } },
        };
    }

    /// What the core reported is dropped, and the markers with it.
    fn setActive(self: *DockedSearch, active: bool) void {
        self.active = active;
        self.total = null;
        self.selected_raw = null;
        self.invalid = false;
        if (!active) {
            self.deadline = null;
            self.awaiting = self.query.len > 0;
        }
        if (self.match_rows.len > 0) self.alloc.free(self.match_rows);
        self.match_rows = &.{};
    }

    /// The debounce fires once per edit, 40 ms after it.
    fn debounceDue(self: *const DockedSearch, now_ms: i64) bool {
        const deadline = self.deadline orelse return false;
        return now_ms >= deadline;
    }

    fn report(self: *DockedSearch, core: Input.Core) Allocator.Error!Outcome {
        if (core == .ended) return self.close();
        // While the debounce waits, a report belongs to the query before
        // the edit: it would overwrite "Searching" and the markers.
        if (self.deadline != null) return .{};
        switch (core) {
            .total => |total| {
                self.total = total.total;
                self.invalid = total.invalid;
                self.awaiting = total.total == null;
            },
            .selected => |selected| {
                self.selected_raw = if (selected) |number| if (number == 0) null else number - 1 else null;
                self.awaiting = self.shownSelected() == null and self.total == null;
            },
            .rows => |rows| {
                if (std.mem.eql(u32, self.match_rows, rows)) return .{};
                const copy: []const u32 = if (rows.len == 0) &.{} else try self.alloc.dupe(u32, rows);
                if (self.match_rows.len > 0) self.alloc.free(self.match_rows);
                self.match_rows = copy;
                return .{ .markers_changed = true };
            },
            .ended => unreachable,
        }
        return .{};
    }

    fn results(self: *const DockedSearch) Results {
        if (self.query.len == 0) return .idle;
        if (self.deadline != null or self.awaiting) return .pending;
        const total = self.total orelse return .pending;
        if (self.invalid) return .invalid;
        if (total == 0) return .none;
        return .{ .count = .{ .selected = self.shownSelected(), .total = total } };
    }

    /// The selected match's 1-based number, or null when the core has not
    /// selected one among those it counted.
    fn shownSelected(self: *const DockedSearch) ?usize {
        const index = self.selected_raw orelse return null;
        const total = self.total orelse return null;
        return if (index < total) index + 1 else null;
    }

    /// A new query starts the debounce at `now_ms` and drops what the core
    /// said of the old one; an empty one waits for nothing. Copies first, so
    /// on OutOfMemory nothing changed.
    fn setQuery(self: *DockedSearch, next: []const u8, now_ms: i64) Allocator.Error!void {
        const next_owned: ?[]u8 = if (next.len > 0) try self.alloc.dupe(u8, next) else null;
        errdefer if (next_owned) |value| self.alloc.free(value);

        if (self.query.len > 0) self.alloc.free(self.query);

        if (next.len == 0) {
            self.query = &.{};
            self.total = null;
            self.selected_raw = null;
            self.invalid = false;
            self.deadline = null;
            self.awaiting = false;
            return;
        }

        self.query = next_owned.?;
        self.total = null;
        self.selected_raw = null;
        self.invalid = false;
        self.deadline = now_ms + debounce_ms;
        self.awaiting = false;
    }
};

// =====================================================================
// Tests
// =====================================================================

/// A pane whose query `text` has reached the core.
fn testSearching(alloc: Allocator, text: []const u8) !DockedSearch {
    var search = DockedSearch.init(alloc);
    errdefer search.deinit();
    _ = try search.apply(.{ .open = "" }, 0);
    _ = try search.apply(.{ .edit = text }, 1000);
    _ = try search.apply(.tick, 1000 + debounce_ms);
    return search;
}

test "core index 1 of 2500 reads 1/2500 (newest first)" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    var buf: [48]u8 = undefined;
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 2500 } } }, 0);
    try std.testing.expectEqualStrings("2500", search.view().results.text(&buf));
    for ([_]usize{ 1, 2, 3 }) |number| {
        _ = try search.apply(.{ .core = .{ .selected = number } }, 0);
        var want: [16]u8 = undefined;
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&want, "{d}/2500", .{number}),
            search.view().results.text(&buf),
        );
    }
}

test "duplicate total and selected callbacks report no change" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    const total: Input = .{ .core = .{ .total = .{ .total = 12 } } };
    try std.testing.expect((try search.apply(total, 0)).results_changed);
    try std.testing.expect(!(try search.apply(total, 0)).results_changed);
    const selected: Input = .{ .core = .{ .selected = 3 } };
    try std.testing.expect((try search.apply(selected, 0)).results_changed);
    try std.testing.expect(!(try search.apply(selected, 0)).results_changed);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("3/12", search.view().results.text(&buf));
    try std.testing.expectEqual(Results.Tone.found, search.view().results.tone());
}

test "an invalid pattern reads Invalid pattern with exactly one results change" {
    var search = try testSearching(std.testing.allocator, "need(");
    defer search.deinit();
    // What the core sends for a query that does not compile: the zero total
    // marked invalid, then the clear's selection and rows.
    const reports = [_]Input{
        .{ .core = .{ .total = .{ .total = 0, .invalid = true } } },
        .{ .core = .{ .selected = null } },
        .{ .core = .{ .rows = &.{} } },
    };
    var changes: usize = 0;
    for (reports) |in| {
        const out = try search.apply(in, 0);
        if (out.results_changed) changes += 1;
        try std.testing.expect(!out.markers_changed);
    }
    try std.testing.expectEqual(@as(usize, 1), changes);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Invalid pattern", search.view().results.text(&buf));
    try std.testing.expectEqual(Results.Tone.no_match, search.view().results.tone());
}

test "match rows are copied; the caller may free its slice after apply" {
    const alloc = std.testing.allocator;
    var search = try testSearching(alloc, "needlex");
    defer search.deinit();
    const rows = try alloc.dupe(u32, &.{ 3, 9, 40 });
    const out = try search.apply(.{ .core = .{ .rows = rows } }, 0);
    alloc.free(rows);
    try std.testing.expect(out.markers_changed);
    try std.testing.expect(!out.results_changed);
    try std.testing.expectEqualSlices(u32, &.{ 3, 9, 40 }, search.view().match_rows);
    try std.testing.expect(!(try search.apply(.{ .core = .{ .rows = &.{ 3, 9, 40 } } }, 0)).markers_changed);
}

test "OutOfMemory copying rows leaves the state unchanged" {
    // The query is allocation 0 and the first rows allocation 1.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var search = try testSearching(failing.allocator(), "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .rows = &.{ 1, 2 } } }, 0);
    try std.testing.expectError(error.OutOfMemory, search.apply(.{ .core = .{ .rows = &.{ 5, 6, 7 } } }, 0));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, search.view().match_rows);
}

test "an edit waits out 40 ms, then one tick searches once" {
    var search = DockedSearch.init(std.testing.allocator);
    defer search.deinit();
    _ = try search.apply(.{ .open = "" }, 0);
    const edited = try search.apply(.{ .edit = "needle" }, 1000);
    try std.testing.expect(edited.timer_changed);
    try std.testing.expect(edited.core == null);
    try std.testing.expect(search.view().wants_tick);
    try std.testing.expect((try search.apply(.tick, 1000 + debounce_ms - 1)).core == null);
    const fired = try search.apply(.tick, 1000 + debounce_ms);
    const command = fired.core orelse return error.NoSearch;
    try std.testing.expectEqual(std.meta.Tag(Command).search, std.meta.activeTag(command));
    try std.testing.expectEqualStrings("needle", command.search.text);
    try std.testing.expect(fired.timer_changed);
    try std.testing.expect(!search.view().wants_tick);
    try std.testing.expect((try search.apply(.tick, 1000 + debounce_ms + 1)).core == null);
}

test "a stale total, selection and rows for the previous query during the debounce are ignored" {
    var search = try testSearching(std.testing.allocator, "needle");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 12 } } }, 0);
    _ = try search.apply(.{ .core = .{ .rows = &.{ 4, 8 } } }, 0);
    _ = try search.apply(.{ .edit = "needlex" }, 2000);
    const stale = [_]Input{
        .{ .core = .{ .total = .{ .total = 12 } } },
        .{ .core = .{ .selected = 1 } },
        .{ .core = .{ .rows = &.{ 4, 8 } } },
    };
    for (stale) |in| {
        const out = try search.apply(in, 2010);
        try std.testing.expect(!out.results_changed);
        try std.testing.expect(!out.markers_changed);
    }
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Searching", search.view().results.text(&buf));
    try std.testing.expectEqual(@as(usize, 0), search.view().match_rows.len);
}

test "editing a searched query invalidates, clearing it stops, and the first character from empty sends nothing" {
    var search = DockedSearch.init(std.testing.allocator);
    defer search.deinit();
    _ = try search.apply(.{ .open = "" }, 0);
    try std.testing.expect((try search.apply(.{ .edit = "n" }, 1000)).core == null);
    _ = try search.apply(.tick, 1000 + debounce_ms);
    const narrowed = (try search.apply(.{ .edit = "ne" }, 2000)).core orelse return error.NoCommand;
    try std.testing.expectEqual(std.meta.Tag(Command).invalidate, std.meta.activeTag(narrowed));
    const cleared = (try search.apply(.{ .edit = "" }, 2010)).core orelse return error.NoCommand;
    try std.testing.expectEqual(std.meta.Tag(Command).stop, std.meta.activeTag(cleared));
}

test "the chip relayouts only when the query goes empty to non-empty or back" {
    var search = DockedSearch.init(std.testing.allocator);
    defer search.deinit();
    _ = try search.apply(.{ .open = "" }, 0);
    const Frame = @FieldType(Outcome, "frame");
    const steps = [_]struct { text: []const u8, frame: Frame, chip: bool }{
        .{ .text = "a", .frame = .relayout, .chip = true },
        .{ .text = "ab", .frame = .same, .chip = true },
        .{ .text = "", .frame = .relayout, .chip = false },
        .{ .text = "", .frame = .same, .chip = false },
    };
    for (steps, 0..) |step, i| {
        const out = try search.apply(.{ .edit = step.text }, 1000 + @as(i64, @intCast(i)));
        try std.testing.expectEqual(step.frame, out.frame);
        try std.testing.expectEqual(step.chip, search.view().chip);
    }
}

test "a toggle with a query reports which toggle flipped and searches at once with the new options" {
    var search = DockedSearch.init(std.testing.allocator);
    defer search.deinit();
    _ = try search.apply(.{ .open = "" }, 0);
    // Without a query only the toggle changes.
    const idle = try search.apply(.{ .click = .regex }, 1000);
    try std.testing.expectEqual(@as(?Role, .regex), idle.toggled);
    try std.testing.expect(idle.core == null);
    try std.testing.expect(search.view().options.regex);

    // An invalid pattern: the toggle clears the mark and searches at once.
    _ = try search.apply(.{ .edit = "need(" }, 1000);
    _ = try search.apply(.tick, 1000 + debounce_ms);
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 0, .invalid = true } } }, 0);
    const flipped = try search.apply(.{ .click = .case_sensitive }, 2000);
    try std.testing.expectEqual(@as(?Role, .case_sensitive), flipped.toggled);
    try std.testing.expect(flipped.results_changed);
    const command = flipped.core orelse return error.NoSearch;
    try std.testing.expectEqual(std.meta.Tag(Command).search, std.meta.activeTag(command));
    try std.testing.expectEqualStrings("need(", command.search.text);
    try std.testing.expect(command.search.options.regex and command.search.options.case_sensitive);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Searching", search.view().results.text(&buf));

    // So does an edit.
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 0, .invalid = true } } }, 0);
    _ = try search.apply(.{ .edit = "need(e" }, 3000);
    try std.testing.expectEqualStrings("Searching", search.view().results.text(&buf));
}

test "re-entrant null clears right after .stop and .invalidate change nothing visible" {
    var search = try testSearching(std.testing.allocator, "needle");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 12 } } }, 0);
    _ = try search.apply(.{ .core = .{ .selected = 1 } }, 0);
    _ = try search.apply(.{ .core = .{ .rows = &.{3} } }, 0);
    // What the core sends back from `invalidateSearchResults` and
    // `setSearchQuery("")` while it has a search, before they return.
    const clears = [_]Input{
        .{ .core = .{ .total = .{ .total = null } } },
        .{ .core = .{ .selected = null } },
        .{ .core = .{ .rows = &.{} } },
    };
    for ([_][]const u8{ "needlex", "" }) |text| {
        _ = try search.apply(.{ .edit = text }, 2000);
        const shown = search.view().results;
        for (clears) |in| {
            const out = try search.apply(in, 2000);
            try std.testing.expect(!out.results_changed);
            try std.testing.expect(!out.markers_changed);
        }
        try std.testing.expect(shown.eql(search.view().results));
    }
}

test "OutOfMemory on an edit leaves the state unchanged" {
    // The query is allocation 0.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var search = try testSearching(failing.allocator(), "needle");
    defer search.deinit();
    const shown = search.view().results;
    try std.testing.expectError(error.OutOfMemory, search.apply(.{ .edit = "other" }, 2000));
    try std.testing.expect(shown.eql(search.view().results));
    const command = try testCommand(try search.apply(.{ .click = .regex }, 2001), .search);
    try std.testing.expectEqualStrings("needle", command.text);
}

/// The command's payload when `out` asks the core for a `tag`, so a wrong
/// command fails the test rather than panicking on the union.
fn testCommand(out: Outcome, comptime tag: std.meta.Tag(Command)) !@FieldType(Command, @tagName(tag)) {
    const command = out.core orelse return error.NoCommand;
    if (std.meta.activeTag(command) != tag) return error.WrongCommand;
    return @field(command, @tagName(tag));
}

test "open with no query reads Type to search, shows the bar and asks nothing of the core" {
    var search = DockedSearch.init(std.testing.allocator);
    defer search.deinit();
    const out = try search.apply(.{ .open = "" }, 0);
    try std.testing.expect(out.handled);
    try std.testing.expectEqual(.shown, out.frame);
    try std.testing.expect(out.timer_changed);
    try std.testing.expect(out.core == null);
    try std.testing.expect(search.view().open);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Type to search", search.view().results.text(&buf));
}

test "open with the live needle restores its results without rerunning; another needle reruns" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 60 } } }, 0);
    _ = try search.apply(.{ .core = .{ .selected = 3 } }, 0);
    var buf: [48]u8 = undefined;

    const again = try search.apply(.{ .open = "needlex" }, 0);
    try std.testing.expectEqual(.shown, again.frame);
    try std.testing.expect(again.core == null);
    try std.testing.expectEqualStrings("3/60", search.view().results.text(&buf));

    // The frame is shown and the search starts in the same Outcome, the
    // frame first, so the core searches the resized pane.
    const other = try search.apply(.{ .open = "other" }, 0);
    try std.testing.expectEqual(.shown, other.frame);
    try std.testing.expectEqualStrings("other", (try testCommand(other, .search)).text);
    try std.testing.expectEqualStrings("other", search.view().query);
    try std.testing.expectEqualStrings("Searching", search.view().results.text(&buf));
}

test "close keeps the query and toggles, drops totals and rows; reopening reruns" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .click = .regex }, 0);
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 60 } } }, 0);
    _ = try search.apply(.{ .core = .{ .rows = &.{ 1, 2 } } }, 0);

    const closed = try search.apply(.{ .core = .ended }, 0);
    try std.testing.expectEqual(.hidden, closed.frame);
    try std.testing.expect(closed.markers_changed);
    try std.testing.expect(closed.timer_changed);
    const shown = search.view();
    try std.testing.expect(!shown.open);
    try std.testing.expectEqualStrings("needlex", shown.query);
    try std.testing.expect(shown.options.regex);
    try std.testing.expectEqual(@as(usize, 0), shown.match_rows.len);
    try std.testing.expect(!shown.wants_tick);

    const reopened = try testCommand(try search.apply(.{ .open = "" }, 0), .search);
    try std.testing.expectEqualStrings("needlex", reopened.text);
    try std.testing.expect(reopened.options.regex);
}

test "the previous button asks the core for .next and the next button for .previous" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 60 } } }, 0);
    try std.testing.expectEqual(NavigateSearch.next, try testCommand(try search.apply(.{ .click = .prev }, 0), .navigate));
    try std.testing.expectEqual(NavigateSearch.previous, try testCommand(try search.apply(.{ .click = .next }, 0), .navigate));
}

test "navigate reruns when the search is not live (inactive or pending)" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .edit = "needlexy" }, 2000);
    const pending = try testCommand(try search.apply(.{ .click = .next }, 2001), .search);
    try std.testing.expectEqualStrings("needlexy", pending.text);

    _ = try search.apply(.{ .core = .ended }, 0);
    const inactive = try testCommand(try search.apply(.{ .click = .prev }, 3000), .search);
    try std.testing.expectEqualStrings("needlexy", inactive.text);
}

test "navigation previews 1/60 to 2/60 and wraps; the core's echo of the same index reports no change" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    var buf: [48]u8 = undefined;
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 60 } } }, 0);
    _ = try search.apply(.{ .core = .{ .selected = 1 } }, 0);
    try std.testing.expectEqualStrings("1/60", search.view().results.text(&buf));

    try std.testing.expect((try search.apply(.{ .click = .prev }, 0)).results_changed);
    try std.testing.expectEqualStrings("2/60", search.view().results.text(&buf));
    try std.testing.expect(!(try search.apply(.{ .core = .{ .selected = 2 } }, 0)).results_changed);

    _ = try search.apply(.{ .core = .{ .selected = 60 } }, 0);
    _ = try search.apply(.{ .click = .prev }, 0);
    try std.testing.expectEqualStrings("1/60", search.view().results.text(&buf));
    _ = try search.apply(.{ .click = .next }, 0);
    try std.testing.expectEqualStrings("60/60", search.view().results.text(&buf));
}

test "a close click sends .end with focus_terminal; ended alone hides without moving focus" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 12 } } }, 0);
    const click = try search.apply(.{ .click = .close }, 0);
    try std.testing.expect(click.handled);
    try std.testing.expect(click.focus_terminal);
    try std.testing.expectEqual(.same, click.frame);
    try testCommand(click, .end);
    try std.testing.expect(search.view().open);

    // What `endSearch` sends back before it returns: the clears, then
    // end_search.
    _ = try search.apply(.{ .core = .{ .total = .{ .total = null } } }, 0);
    _ = try search.apply(.{ .core = .{ .selected = null } }, 0);
    _ = try search.apply(.{ .core = .{ .rows = &.{} } }, 0);
    const ended = try search.apply(.{ .core = .ended }, 0);
    try std.testing.expect(!ended.focus_terminal);
    try std.testing.expectEqual(.hidden, ended.frame);
    try std.testing.expect(ended.core == null);
    try std.testing.expect(!search.view().open);
}

/// A key press as the procedures forward it.
fn testKey(event: @FieldType(Input.Key, "event"), at: @FieldType(Input.Key, "at"), vk: usize, mods: Mods) Input {
    return .{ .key = .{ .event = event, .at = at, .vk = vk, .mods = mods } };
}

test "the direction table: Enter, Down and F3 step down (core .previous), with Shift and Up they step up" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 60 } } }, 0);
    const shift: Mods = .{ .shift = true };
    const Row = struct { vk: usize, mods: Mods = .{}, dir: NavigateSearch };
    const edit_rows = [_]Row{
        .{ .vk = c.VK_RETURN, .dir = .previous },
        .{ .vk = c.VK_RETURN, .mods = shift, .dir = .next },
        .{ .vk = c.VK_DOWN, .dir = .previous },
        .{ .vk = c.VK_UP, .dir = .next },
        .{ .vk = c.VK_F3, .dir = .previous },
        .{ .vk = c.VK_F3, .mods = shift, .dir = .next },
    };
    for (edit_rows) |row| {
        for ([_]@FieldType(Input.Key, "event"){ .down, .sys_down }) |event| {
            const out = try search.apply(testKey(event, .edit, row.vk, row.mods), 0);
            try std.testing.expect(out.handled);
            try std.testing.expectEqual(row.dir, try testCommand(out, .navigate));
        }
    }
    const button_rows = [_]Row{
        .{ .vk = c.VK_F3, .dir = .previous },
        .{ .vk = c.VK_F3, .mods = shift, .dir = .next },
    };
    for (button_rows) |row| {
        try std.testing.expectEqual(row.dir, try testCommand(try search.apply(testKey(.down, .button, row.vk, row.mods), 0), .navigate));
        const sys = try search.apply(testKey(.sys_down, .button, row.vk, row.mods), 0);
        try std.testing.expect(!sys.handled);
        try std.testing.expect(sys.core == null);
    }
}

test "the first Enter after results asks the core for .previous, and an autorepeat Enter navigates again" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 60 } } }, 0);
    const first = try search.apply(testKey(.down, .edit, c.VK_RETURN, .{}), 0);
    try std.testing.expectEqual(NavigateSearch.previous, try testCommand(first, .navigate));
    // The core selects the newest match, which it numbers 1.
    _ = try search.apply(.{ .core = .{ .selected = 1 } }, 0);
    var held = testKey(.down, .edit, c.VK_RETURN, .{});
    held.key.repeat = true;
    try std.testing.expectEqual(NavigateSearch.previous, try testCommand(try search.apply(held, 0), .navigate));
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("60/60", search.view().results.text(&buf));
}

test "Alt+R/C/W toggle once per press and swallow their WM_SYSCHAR by scan code; AltGr and Alt+Shift do nothing" {
    var search = DockedSearch.init(std.testing.allocator);
    defer search.deinit();
    _ = try search.apply(.{ .open = "" }, 0);
    const alt: Mods = .{ .alt = true };
    const r_scan: u9 = 0x13;
    const c_scan: u9 = 0x2E;

    // A press toggles; its autorepeat is swallowed without toggling.
    const press = try search.apply(.{ .key = .{ .event = .sys_down, .at = .edit, .vk = 'R', .mods = alt, .scan = r_scan } }, 0);
    try std.testing.expect(press.handled);
    try std.testing.expectEqual(@as(?Role, .regex), press.toggled);
    const held = try search.apply(.{ .key = .{ .event = .sys_down, .at = .edit, .vk = 'R', .mods = alt, .scan = r_scan, .repeat = true } }, 0);
    try std.testing.expect(held.handled);
    try std.testing.expect(held.toggled == null);
    try std.testing.expect(search.view().options.regex);

    // The character is never read, so Cyrillic K on the R key is consumed
    // just like Latin r: only the one character the press typed, though.
    const char: Input.Key = .{ .event = .sys_char, .at = .edit, .scan = r_scan };
    try std.testing.expect((try search.apply(.{ .key = char }, 0)).handled);
    try std.testing.expect(!(try search.apply(.{ .key = char }, 0)).handled);

    // A button pairs the same way; another scan code is not the press's.
    _ = try search.apply(.{ .key = .{ .event = .sys_down, .at = .button, .vk = 'C', .mods = alt, .scan = c_scan } }, 0);
    try std.testing.expect(search.view().options.case_sensitive);
    try std.testing.expect(!(try search.apply(.{ .key = char }, 0)).handled);

    // Another system key or a blur forgets the press.
    _ = try search.apply(.{ .key = .{ .event = .sys_down, .at = .edit, .vk = 'W', .mods = alt, .scan = r_scan } }, 0);
    _ = try search.apply(.{ .key = .{ .event = .sys_down, .at = .edit, .vk = 'X', .mods = alt, .scan = r_scan } }, 0);
    try std.testing.expect(!(try search.apply(.{ .key = char }, 0)).handled);
    _ = try search.apply(.{ .key = .{ .event = .sys_down, .at = .edit, .vk = 'W', .mods = alt, .scan = r_scan } }, 0);
    _ = try search.apply(.{ .key = .{ .event = .blur, .at = .edit } }, 0);
    try std.testing.expect(!(try search.apply(.{ .key = char }, 0)).handled);
    try std.testing.expect(!search.view().options.whole_word);

    // No Alt, AltGr (Ctrl+Alt) and Alt+Shift are not the accelerator.
    for ([_]Mods{ .{}, .{ .ctrl = true }, .{ .alt = true, .ctrl = true }, .{ .alt = true, .shift = true } }) |mods| {
        const out = try search.apply(.{ .key = .{ .event = .sys_down, .at = .edit, .vk = 'R', .mods = mods, .scan = r_scan } }, 0);
        try std.testing.expect(!out.handled);
        try std.testing.expect(!(try search.apply(.{ .key = char }, 0)).handled);
    }
    try std.testing.expect(search.view().options.regex);
}

test "Escape at the edit sends .end with focus_terminal" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    for ([_]@FieldType(Input.Key, "event"){ .down, .sys_down }) |event| {
        const out = try search.apply(testKey(event, .edit, c.VK_ESCAPE, .{}), 0);
        try std.testing.expect(out.handled);
        try std.testing.expect(out.focus_terminal);
        try testCommand(out, .end);
    }
}

test "Escape at a button ends its own pane's search" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    const out = try search.apply(testKey(.down, .button, c.VK_ESCAPE, .{}), 0);
    try std.testing.expect(out.handled);
    try std.testing.expect(out.focus_terminal);
    try testCommand(out, .end);
}

test "Escape at a button with nothing open asks nothing of the core" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .ended }, 0);
    const closed = try search.apply(testKey(.down, .button, c.VK_ESCAPE, .{}), 0);
    try std.testing.expect(closed.handled);
    try std.testing.expect(closed.core == null);
    try std.testing.expect(!closed.focus_terminal);
}

test "a key that is not search's is not handled" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    for ([_]Input{
        testKey(.down, .edit, 'A', .{}),
        testKey(.down, .edit, c.VK_LEFT, .{}),
        testKey(.down, .button, c.VK_UP, .{}),
        testKey(.down, .button, c.VK_RETURN, .{}),
        testKey(.sys_down, .edit, 'Q', .{ .alt = true }),
    }) |in| {
        const out = try search.apply(in, 0);
        try std.testing.expect(!out.handled);
        try std.testing.expect(out.core == null);
    }
}

test "PKG32 default F3 and Shift+F3 match the docked search F3 and Enter directions" {
    var cfg = try @import("../../config.zig").Config.default(std.testing.allocator);
    defer cfg.deinit();
    const set = &cfg.keybind.set;

    const f3 = set.get(.{ .key = .{ .physical = .f3 } }) orelse return error.F3Unbound;
    const shift_f3 = set.get(.{ .key = .{ .physical = .f3 }, .mods = .{ .shift = true } }) orelse
        return error.ShiftF3Unbound;
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 60 } } }, 0);
    const bound = [_]struct { dir: NavigateSearch, mods: Mods }{
        .{ .dir = f3.value_ptr.leaf.action.navigate_search, .mods = .{} },
        .{ .dir = shift_f3.value_ptr.leaf.action.navigate_search, .mods = .{ .shift = true } },
    };
    for (bound) |binding| {
        try std.testing.expectEqual(binding.dir, try testCommand(try search.apply(testKey(.down, .edit, c.VK_F3, binding.mods), 0), .navigate));
        try std.testing.expectEqual(binding.dir, try testCommand(try search.apply(testKey(.down, .edit, c.VK_RETURN, binding.mods), 0), .navigate));
        try std.testing.expectEqual(binding.dir, try testCommand(try search.apply(testKey(.down, .button, c.VK_F3, binding.mods), 0), .navigate));
    }
}

test "Enter before the first total, then total 12, reads 12" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    // The search went to the core and nothing has come back: Enter asks
    // the core to step, and its total arrives after.
    try std.testing.expectEqual(NavigateSearch.previous, try testCommand(try search.apply(testKey(.down, .edit, c.VK_RETURN, .{}), 0), .navigate));
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 12 } } }, 0);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("12", search.view().results.text(&buf));
    try std.testing.expect(!search.view().wants_tick);
}

test "a core clear while open stops wants_tick" {
    var search = try testSearching(std.testing.allocator, "needlex");
    defer search.deinit();
    _ = try search.apply(.{ .core = .{ .total = .{ .total = 12 } } }, 0);
    _ = try search.apply(.{ .core = .{ .selected = 1 } }, 0);
    // A `search:` binding with no text clears the core's search under the
    // open bar.
    _ = try search.apply(.{ .core = .{ .total = .{ .total = null } } }, 0);
    _ = try search.apply(.{ .core = .{ .selected = null } }, 0);
    _ = try search.apply(.{ .core = .{ .rows = &.{} } }, 0);
    try std.testing.expect(!search.view().wants_tick);
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Searching", search.view().results.text(&buf));
    // Enter searches again rather than stepping a search that is gone.
    try std.testing.expectEqualStrings("needlex", (try testCommand(try search.apply(testKey(.down, .edit, c.VK_RETURN, .{}), 0), .search)).text);
}

test "close: end_search, then the clears, on a bar showing results change no chip" {
    // `endSearch` reports end_search and then the clears, whether the bar's
    // close sent `.end` or the end_search binding (Escape at the terminal)
    // called it with no `.end` at all.
    for ([_]bool{ true, false }) |from_bar| {
        var search = try testSearching(std.testing.allocator, "needlex");
        defer search.deinit();
        _ = try search.apply(.{ .core = .{ .total = .{ .total = 12 } } }, 0);
        _ = try search.apply(.{ .core = .{ .selected = 3 } }, 0);
        _ = try search.apply(.{ .core = .{ .rows = &.{7} } }, 0);
        if (from_bar) try testCommand(try search.apply(.{ .click = .close }, 0), .end);
        // The close hides the chip and leaves it alone: dropping the totals
        // must not write "Searching" into it (and raise its live region)
        // while it is still shown.
        const ended = try search.apply(.{ .core = .ended }, 0);
        try std.testing.expectEqual(.hidden, ended.frame);
        try std.testing.expect(ended.markers_changed);
        try std.testing.expect(!ended.results_changed);
        try std.testing.expect(!ended.focus_terminal);
        try std.testing.expect(ended.core == null);
        // The clears reach a closed bar: no chip, and no markers to clear.
        const clears = [_]Input{
            .{ .core = .{ .total = .{ .total = null } } },
            .{ .core = .{ .selected = null } },
            .{ .core = .{ .rows = &.{} } },
        };
        for (clears) |in| {
            const out = try search.apply(in, 0);
            try std.testing.expect(!out.results_changed);
            try std.testing.expect(!out.markers_changed);
            try std.testing.expectEqual(.same, out.frame);
        }
        const closed = search.view();
        try std.testing.expect(!closed.open);
        try std.testing.expect(!closed.wants_tick);
        try std.testing.expectEqual(@as(usize, 0), closed.match_rows.len);
        // A later report under the closed bar writes no chip either, though
        // its rows still reach the markers.
        try std.testing.expect(!(try search.apply(.{ .core = .{ .total = .{ .total = 5 } } }, 0)).results_changed);
        const rows = try search.apply(.{ .core = .{ .rows = &.{4} } }, 0);
        try std.testing.expect(rows.markers_changed);
        try std.testing.expect(!rows.results_changed);
    }
}

test "an open while the debounce waits, or after a core clear, searches at once" {
    var search = DockedSearch.init(std.testing.allocator);
    defer search.deinit();
    _ = try search.apply(.{ .open = "" }, 0);
    _ = try search.apply(.{ .edit = "abc" }, 1000);
    // start_search within 40 ms of the edit: the core has not been asked.
    const during = try search.apply(.{ .open = "" }, 1010);
    try std.testing.expectEqualStrings("abc", (try testCommand(during, .search)).text);
    try std.testing.expect(!search.view().wants_tick);
    // The core cleared its search under the open bar.
    _ = try search.apply(.{ .core = .{ .total = .{ .total = null } } }, 1020);
    try std.testing.expectEqualStrings("abc", (try testCommand(try search.apply(.{ .open = "" }, 1030), .search)).text);
}
