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

pub const debounce_ms: i64 = 40;

/// The regex, case and whole-word toggles, as the core takes them.
pub const QueryOptions = @import("../../terminal/search/query_options.zig").QueryOptions;

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
    /// The edit's text after EN_CHANGE, borrowed for the call.
    edit: []const u8,
    /// A toggle's BN_CLICKED (regex, case_sensitive, whole_word).
    click: Role,
    /// The host's search timer fired.
    tick,
    /// A core action for this pane.
    core: Core,

    pub const Core = union(enum) {
        total: struct { total: ?usize, invalid: bool = false },
        /// 1-based, newest first (`apprtSearchSelectedIndex`).
        selected: ?usize,
        /// Copied: the caller may free its slice once `apply` returns.
        rows: []const u32,
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
    results_changed: bool = false,
    /// Clear the scrollbar markers and refresh the scrollbar window.
    markers_changed: bool = false,
    /// The chip appeared or went: lay the host out again.
    frame: enum { same, relayout } = .same,
    /// Refresh the host's search timer (`view().wants_tick`).
    timer_changed: bool = false,
    core: ?Command = null,
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

/// Alt+R, Alt+C and Alt+W flip the regex, case and whole-word flags from the
/// docked search bar. Alt has to be held without Ctrl, since AltGr reports as
/// Ctrl+Alt and types characters on many layouts, and without Shift.
pub fn toggleAccelerator(vk: usize, mods: Mods) ?Role {
    if (!mods.alt or mods.ctrl or mods.shift) return null;
    return switch (vk) {
        'R' => .regex,
        'C' => .case_sensitive,
        'W' => .whole_word,
        else => null,
    };
}

/// Pair a handled virtual-key shortcut with TranslateMessage's WM_SYSCHAR
/// by scan code, not character: the character can be non-Latin on another
/// layout. Only a handled press can consume a character; AltGr stays out.
pub const ToggleKeys = struct {
    pending_scan: ?u16 = null,

    pub fn keyDown(self: *ToggleKeys, vk: usize, mods: Mods, bits: usize) ?Role {
        const role = toggleAccelerator(vk, mods);
        self.pending_scan = if (role != null) @intCast((bits >> 16) & 0x1FF) else null;
        return role;
    }

    /// `bits` is the WM_SYSCHAR's lParam; its character does not matter.
    pub fn consumeChar(self: *ToggleKeys, bits: usize) bool {
        const pending = self.pending_scan;
        self.pending_scan = null;
        return if (pending) |scan| scan == ((bits >> 16) & 0x1FF) else false;
    }
};

pub const DockedSearch = struct {
    visible: bool = false,
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
    /// When the debounce started; 0 when none is waiting.
    last_edit_ms: i64 = 0,
    /// False while an edit waits out the debounce, and when the core's
    /// answer says nothing about the query (a null total, or a null
    /// selection with no total).
    searched: bool = true,
    /// A query was edited or searched and not stopped since. The core
    /// searches for `query` when this is set and `searched` is too.
    active: bool = false,
    /// The rows of the matches, owned, for the scrollbar markers.
    match_rows: []const u32 = &.{},
    toggle_keys: ToggleKeys = .{},
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
            .edit => |text| try self.edit(text, now_ms),
            .click => |role| switch (role) {
                .regex, .case_sensitive, .whole_word => self.toggle(role),
                .prev, .next, .close => .{},
            },
            .tick => if (self.visible and self.debounceDue(now_ms)) self.issue() else .{},
            .core => |core| try self.report(core),
        };
        out.results_changed = !before.eql(self.results());
        return out;
    }

    pub fn view(self: *const DockedSearch) View {
        return .{
            .open = self.visible,
            .chip = self.query.len > 0,
            .results = self.results(),
            .options = self.options,
            .wants_tick = self.visible and self.query.len > 0 and !self.searched,
            .match_rows = self.match_rows,
        };
    }

    /// Searches for the query at once, debounce or not, as navigation and
    /// the open do until they go through `apply`.
    pub fn rerun(self: *DockedSearch) Outcome {
        if (self.query.len == 0) return .{};
        const before = self.results();
        var out = self.issue();
        out.results_changed = !before.eql(self.results());
        return out;
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
        self.searched = true;
        self.last_edit_ms = 0;
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
            self.searched = self.query.len == 0;
            self.last_edit_ms = 0;
        }
        if (self.match_rows.len > 0) self.alloc.free(self.match_rows);
        self.match_rows = &.{};
    }

    /// The debounce fires once per edit, 40 ms after it.
    fn debounceDue(self: *const DockedSearch, now_ms: i64) bool {
        if (self.query.len == 0) return false;
        if (self.searched) return false;
        if (self.last_edit_ms == 0) return false;
        return (now_ms - self.last_edit_ms) >= debounce_ms;
    }

    fn report(self: *DockedSearch, core: Input.Core) Allocator.Error!Outcome {
        // While the debounce waits, a report belongs to the query before
        // the edit: it would overwrite "Searching" and the markers.
        if (self.query.len > 0 and !self.searched) return .{};
        switch (core) {
            .total => |total| {
                self.total = total.total;
                self.invalid = total.invalid;
                self.searched = total.total != null;
            },
            .selected => |selected| {
                self.selected_raw = if (selected) |number| if (number == 0) null else number - 1 else null;
                self.searched = self.shownSelected() != null or self.total != null;
            },
            .rows => |rows| {
                if (std.mem.eql(u32, self.match_rows, rows)) return .{};
                const copy: []const u32 = if (rows.len == 0) &.{} else try self.alloc.dupe(u32, rows);
                if (self.match_rows.len > 0) self.alloc.free(self.match_rows);
                self.match_rows = copy;
                return .{ .markers_changed = true };
            },
        }
        return .{};
    }

    fn results(self: *const DockedSearch) Results {
        if (self.query.len == 0) return .idle;
        if (!self.searched) return .pending;
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

    pub fn open(self: *DockedSearch) void {
        self.visible = true;
    }

    pub fn close(self: *DockedSearch) void {
        self.visible = false;
    }

    /// A new query starts the debounce (`now_ms`) and drops what the core
    /// said of the old one; an empty one waits for nothing. Copies first, so
    /// on OutOfMemory nothing changed.
    pub fn setQuery(self: *DockedSearch, next: []const u8, now_ms: i64) Allocator.Error!void {
        const next_owned: ?[]u8 = if (next.len > 0) try self.alloc.dupe(u8, next) else null;
        errdefer if (next_owned) |value| self.alloc.free(value);

        if (self.query.len > 0) self.alloc.free(self.query);

        if (next.len == 0) {
            self.query = &.{};
            self.total = null;
            self.selected_raw = null;
            self.invalid = false;
            self.last_edit_ms = 0;
            self.searched = true;
            return;
        }

        self.query = next_owned.?;
        self.total = null;
        self.selected_raw = null;
        self.invalid = false;
        self.last_edit_ms = now_ms;
        self.searched = false;
    }
};

// =====================================================================
// Tests
// =====================================================================

test "open shows; close hides" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try std.testing.expect(!bar.visible);
    bar.open();
    try std.testing.expect(bar.visible);
    bar.close();
    try std.testing.expect(!bar.visible);
}

test "query survives close/open" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    bar.open();
    try bar.setQuery("foo", 1000);
    bar.close();
    bar.open();
    try std.testing.expectEqualStrings("foo", bar.query);
}

test "toggles persist across open/close" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    bar.open();
    _ = try bar.apply(.{ .click = .case_sensitive }, 1000);
    bar.close();
    bar.open();
    try std.testing.expect(bar.view().options.case_sensitive);
}

test "win32 search toggle accelerators need Alt without Ctrl, Shift or AltGr" {
    const alt: Mods = .{ .alt = true };
    try std.testing.expectEqual(@as(?Role, .regex), toggleAccelerator('R', alt));
    try std.testing.expectEqual(@as(?Role, .case_sensitive), toggleAccelerator('C', alt));
    try std.testing.expectEqual(@as(?Role, .whole_word), toggleAccelerator('W', alt));
    try std.testing.expectEqual(@as(?Role, null), toggleAccelerator('X', alt));
    // No Alt, or Alt with Ctrl (AltGr reports as both), or Shift: not ours.
    try std.testing.expectEqual(@as(?Role, null), toggleAccelerator('R', .{}));
    try std.testing.expectEqual(@as(?Role, null), toggleAccelerator('R', .{ .ctrl = true }));
    try std.testing.expectEqual(@as(?Role, null), toggleAccelerator('R', .{ .alt = true, .ctrl = true }));
    try std.testing.expectEqual(@as(?Role, null), toggleAccelerator('R', .{ .alt = true, .shift = true }));
    var keys: ToggleKeys = .{};
    const r_scan = 0x13 << 16;
    const c_scan = 0x2E << 16;
    try std.testing.expectEqual(@as(?Role, .regex), keys.keyDown('R', alt, r_scan));
    // The character is never read, so Cyrillic K on the R key is consumed
    // just like Latin r: only the one character the press typed, though.
    try std.testing.expect(keys.consumeChar(r_scan));
    try std.testing.expect(!keys.consumeChar(r_scan));
    _ = keys.keyDown('C', alt, c_scan);
    try std.testing.expect(keys.consumeChar(c_scan));
    _ = keys.keyDown('R', alt, r_scan);
    try std.testing.expect(!keys.consumeChar(c_scan));
    _ = keys.keyDown('R', .{ .alt = true, .ctrl = true }, r_scan);
    try std.testing.expect(!keys.consumeChar(r_scan));
    _ = keys.keyDown('R', alt, r_scan);
    _ = keys.keyDown('X', alt, r_scan);
    try std.testing.expect(!keys.consumeChar(r_scan));
}

/// A pane whose query `text` has reached the core.
fn testSearching(alloc: Allocator, text: []const u8) !DockedSearch {
    var search = DockedSearch.init(alloc);
    errdefer search.deinit();
    search.open();
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
    search.open();
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
    search.open();
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
    search.open();
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
    search.open();
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
    const command = (try search.apply(.{ .click = .regex }, 2001)).core orelse return error.NoSearch;
    try std.testing.expectEqualStrings("needle", command.search.text);
}
