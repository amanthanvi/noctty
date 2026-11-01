//! One pane's docked search state: the query, the regex/case/word toggles,
//! what the core last reported, the 40 ms debounce and the Alt+R/C/W press
//! pairing. No HWND creation, painting or keybind dispatch: those belong to
//! the Win32 surface layer (`search_controls.zig`).
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
    total: ?usize = null,
    selected: ?usize = null,
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
    /// What the core last reported: the total, its newest-first index and
    /// that index as the chip shows it.
    core_total: ?usize = null,
    selected_raw: ?usize = null,
    core_selected: ?usize = null,
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
            self.selected = null;
            self.invalid = false;
            self.last_edit_ms = 0;
            self.searched = true;
            return;
        }

        self.query = next_owned.?;
        self.total = null;
        self.selected = null;
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
        self.selected = null;
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
    bar.selected = 4;

    try bar.setQuery("bar", 1100);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected);
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
    try std.testing.expectEqual(@as(?usize, null), bar.selected);
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
    bar.selected = 3;

    bar.toggleRegex(2000);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected);
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
    bar.selected = 3;

    bar.toggleCase(2000);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected);
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
    bar.selected = 3;

    bar.toggleWord(2000);
    try std.testing.expectEqual(@as(?usize, null), bar.total);
    try std.testing.expectEqual(@as(?usize, null), bar.selected);
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
