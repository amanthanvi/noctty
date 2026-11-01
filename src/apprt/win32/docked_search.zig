//! One pane's docked search state: the query, the regex/case/word toggles,
//! what the core last reported, the 40 ms debounce and the Alt+R/C/W press
//! pairing. No HWND creation, painting or keybind dispatch: those belong to
//! the Win32 surface layer (`search_controls.zig`).
//!
//! `apply` takes an input and returns what the window must do (`Outcome`);
//! `view` says what to draw. Nothing here calls the core, Win32 or the
//! clock, and `apply` finishes its whole state change before it returns, so
//! the core can call back into it while the caller carries out an Outcome.
//! A View's slices are valid until the next `apply`.
//!
//! **Debounce rationale.**  Scrollback search is O(lines * query_len).
//! Re-running on every WM_COMMAND / EN_CHANGE would stall the UI on
//! large histories.  A 40 ms window batches rapid keystrokes into a
//! single search pass while feeling instantaneous to the user.
//!
//! **Wrap navigation.**  The helper keeps an internal `wrap` flag so
//! callers can choose whether next/previous navigation wraps. The
//! current Win32 UI does not surface a dedicated wrap toggle; it keeps
//! the default wrapping behaviour unless a caller opts out.
//!
//! **Toggle persistence across close.**  Closing the bar (Esc) hides
//! the visual but preserves query + toggles so that re-opening (Ctrl+F)
//! restores the previous search context.  Users iterating on
//! case/word filters shouldn't lose progress.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

pub const Toggles = packed struct {
    regex: bool = false,
    case_sensitive: bool = false,
    whole_word: bool = false,
    wrap: bool = true,
    _padding: u4 = 0,
};

pub const Input = union(enum) {
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

/// What the window must do after an `apply`.
pub const Outcome = struct {
    /// Write `view().results` to the chip and raise its live region once.
    results_changed: bool = false,
    /// Clear the scrollbar markers and refresh the scrollbar window.
    markers_changed: bool = false,
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
    results: Results,
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
    toggles: Toggles = .{},
    /// What the core last reported: the total, and the selected match's
    /// newest-first index (the core's 1-based number minus one).
    total: ?usize = null,
    selected_raw: ?usize = null,
    /// The core could not compile the query (an invalid regular expression).
    /// Every edit or toggle clears it, because the answer belongs to the
    /// query that was searched.
    invalid: bool = false,
    last_edit_ms: i64 = 0,
    /// When true the debounce has already fired (or was bypassed via
    /// `forceSearch`) and no new edit has arrived since.  Prevents
    /// `shouldRunSearch` from returning true twice for the same edit.
    searched: bool = true,
    /// A query reached the core and has not been stopped since.
    active: bool = false,
    /// The query the core is searching for, owned.
    needle: ?[:0]const u8 = null,
    /// The rows of the matches, owned, for the scrollbar markers.
    match_rows: []const u32 = &.{},
    toggle_keys: ToggleKeys = .{},
    alloc: Allocator,

    pub const debounce_ms: i64 = 40;

    pub fn init(alloc: Allocator) DockedSearch {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DockedSearch) void {
        if (self.query.len > 0) self.alloc.free(self.query);
        if (self.needle) |value| self.alloc.free(value);
        if (self.match_rows.len > 0) self.alloc.free(self.match_rows);
        self.* = undefined;
    }

    /// Fails only to copy what the input carries, and then changes nothing.
    pub fn apply(self: *DockedSearch, in: Input, now_ms: i64) Allocator.Error!Outcome {
        _ = now_ms;
        const before = self.results();
        var out: Outcome = switch (in) {
            .core => |core| try self.report(core),
        };
        out.results_changed = !before.eql(self.results());
        return out;
    }

    pub fn view(self: *const DockedSearch) View {
        return .{
            .results = self.results(),
            .match_rows = self.match_rows,
        };
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

    // -----------------------------------------------------------------
    // Visibility
    // -----------------------------------------------------------------

    pub fn open(self: *DockedSearch) void {
        self.visible = true;
    }

    pub fn close(self: *DockedSearch) void {
        self.visible = false;
    }

    // -----------------------------------------------------------------
    // Query
    // -----------------------------------------------------------------

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

    // -----------------------------------------------------------------
    // Debounce
    // -----------------------------------------------------------------

    pub fn shouldRunSearch(self: *const DockedSearch, now_ms: i64) bool {
        if (self.query.len == 0) return false;
        if (self.searched) return false;
        if (self.last_edit_ms == 0) return false;
        return (now_ms - self.last_edit_ms) >= debounce_ms;
    }

    /// Clear debounce and signal the caller to re-run immediately.
    /// Returns true when a non-empty query exists (caller should search).
    pub fn forceSearch(self: *DockedSearch) bool {
        if (self.query.len == 0) return false;
        self.searched = true;
        self.last_edit_ms = 0;
        return true;
    }

    // -----------------------------------------------------------------
    // Toggles
    // -----------------------------------------------------------------

    fn invalidateResults(self: *DockedSearch, now_ms: i64) void {
        self.total = null;
        self.selected_raw = null;
        self.invalid = false;
        if (self.query.len == 0) {
            self.searched = true;
            self.last_edit_ms = 0;
        } else {
            self.searched = false;
            self.last_edit_ms = now_ms;
        }
    }

    pub fn toggleRegex(self: *DockedSearch, now_ms: i64) void {
        self.toggles.regex = !self.toggles.regex;
        self.invalidateResults(now_ms);
    }

    pub fn toggleCase(self: *DockedSearch, now_ms: i64) void {
        self.toggles.case_sensitive = !self.toggles.case_sensitive;
        self.invalidateResults(now_ms);
    }

    pub fn toggleWord(self: *DockedSearch, now_ms: i64) void {
        self.toggles.whole_word = !self.toggles.whole_word;
        self.invalidateResults(now_ms);
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

test "setQuery accepts aliased source slice" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("foo", 1000);
    try bar.setQuery(bar.query, 2000);
    try std.testing.expectEqualStrings("foo", bar.query);
    try std.testing.expectEqual(@as(i64, 2000), bar.last_edit_ms);
}

test "setQuery clears stale results for a new search" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("foo", 1000);
    bar.total = 8;
    bar.searched = true;
    bar.selected_raw = 4;

    try bar.setQuery("bar", 1100);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected_raw);
    try std.testing.expect(!bar.searched);
    try std.testing.expectEqual(@as(i64, 1100), bar.last_edit_ms);
}

test "empty query clears results" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    bar.open();
    try bar.setQuery("x", 1000);
    bar.total = 5;
    bar.searched = true;
    try std.testing.expectEqual(@as(?usize, 5), bar.total);

    try bar.setQuery("", 2000);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected_raw);
}

test "setQuery starts debounce" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("hi", 1000);
    try std.testing.expect(!bar.shouldRunSearch(1010)); // 10 ms < 40 ms
    try std.testing.expect(bar.shouldRunSearch(1041)); // 41 ms >= 40 ms
}

test "shouldRunSearch needs non-empty query" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("", 1000);
    try std.testing.expect(!bar.shouldRunSearch(2000));
}

test "forceSearch bypasses debounce" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("q", 1000);
    try std.testing.expect(bar.forceSearch());
    try std.testing.expect(!bar.shouldRunSearch(9999)); // already searched
}

test "toggleRegex flips bit" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try std.testing.expect(!bar.toggles.regex);
    bar.toggleRegex(1000);
    try std.testing.expect(bar.toggles.regex);
    bar.toggleRegex(2000);
    try std.testing.expect(!bar.toggles.regex);
}

test "toggle invalidates stale results for non-empty query" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("needle", 1000);
    try std.testing.expect(bar.forceSearch());
    bar.total = 10;
    bar.selected_raw = 3;

    bar.toggleRegex(2000);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected_raw);
    try std.testing.expect(!bar.searched);
    try std.testing.expectEqual(@as(i64, 2000), bar.last_edit_ms);
    try std.testing.expect(bar.shouldRunSearch(2041));
}

test "toggleCase invalidates stale results for non-empty query" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("needle", 1000);
    try std.testing.expect(bar.forceSearch());
    bar.total = 10;
    bar.selected_raw = 3;

    bar.toggleCase(2000);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected_raw);
    try std.testing.expect(!bar.searched);
    try std.testing.expectEqual(@as(i64, 2000), bar.last_edit_ms);
    try std.testing.expect(bar.shouldRunSearch(2041));
}

test "toggleWord invalidates stale results for non-empty query" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("needle", 1000);
    try std.testing.expect(bar.forceSearch());
    bar.total = 10;
    bar.selected_raw = 3;

    bar.toggleWord(2000);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected_raw);
    try std.testing.expect(!bar.searched);
    try std.testing.expectEqual(@as(i64, 2000), bar.last_edit_ms);
    try std.testing.expect(bar.shouldRunSearch(2041));
}

test "an edit or a toggle clears the invalid-query mark" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("need(", 1000);
    try std.testing.expect(bar.forceSearch());
    bar.total = 0;
    bar.invalid = true;

    try bar.setQuery("need(e", 1100);
    try std.testing.expect(!bar.invalid);

    bar.invalid = true;
    bar.toggleRegex(1200);
    try std.testing.expect(!bar.invalid);

    bar.invalid = true;
    bar.toggleCase(1300);
    try std.testing.expect(!bar.invalid);

    bar.invalid = true;
    bar.toggleWord(1400);
    try std.testing.expect(!bar.invalid);

    bar.invalid = true;
    try bar.setQuery("", 1500);
    try std.testing.expect(!bar.invalid);
}

test "toggles persist across open/close" {
    var bar = DockedSearch.init(std.testing.allocator);
    defer bar.deinit();

    bar.open();
    bar.toggleCase(1000);
    bar.close();
    bar.open();
    try std.testing.expect(bar.toggles.case_sensitive);
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
    try search.setQuery(text, 1000);
    _ = search.forceSearch();
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
