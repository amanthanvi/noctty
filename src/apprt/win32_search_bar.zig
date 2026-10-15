//! Per-pane docked search bar state machine.
//!
//! Owns query text, regex/case/word toggles, result display state, a 40 ms
//! debounce policy, and match-marker downsampling for the scrollbar
//! overlay.  No HWND creation, painting, or keybind dispatch — those
//! belong to the Win32 surface layer.
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

pub const Toggles = packed struct {
    regex: bool = false,
    case_sensitive: bool = false,
    whole_word: bool = false,
    wrap: bool = true,
    _padding: u4 = 0,
};

pub const SearchBar = struct {
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
    alloc: Allocator,

    pub const debounce_ms: i64 = 40;

    pub fn init(alloc: Allocator) SearchBar {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *SearchBar) void {
        if (self.query.len > 0) self.alloc.free(self.query);
        self.* = undefined;
    }

    // -----------------------------------------------------------------
    // Visibility
    // -----------------------------------------------------------------

    pub fn open(self: *SearchBar) void {
        self.visible = true;
    }

    pub fn close(self: *SearchBar) void {
        self.visible = false;
    }

    // -----------------------------------------------------------------
    // Query
    // -----------------------------------------------------------------

    pub fn setQuery(self: *SearchBar, next: []const u8, now_ms: i64) Allocator.Error!void {
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

    pub fn shouldRunSearch(self: *const SearchBar, now_ms: i64) bool {
        if (self.query.len == 0) return false;
        if (self.searched) return false;
        if (self.last_edit_ms == 0) return false;
        return (now_ms - self.last_edit_ms) >= debounce_ms;
    }

    /// Clear debounce and signal the caller to re-run immediately.
    /// Returns true when a non-empty query exists (caller should search).
    pub fn forceSearch(self: *SearchBar) bool {
        if (self.query.len == 0) return false;
        self.searched = true;
        self.last_edit_ms = 0;
        return true;
    }

    // -----------------------------------------------------------------
    // Results / navigation
    // -----------------------------------------------------------------

    // -----------------------------------------------------------------
    // Toggles
    // -----------------------------------------------------------------

    fn invalidateResults(self: *SearchBar, now_ms: i64) void {
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

    pub fn toggleRegex(self: *SearchBar, now_ms: i64) void {
        self.toggles.regex = !self.toggles.regex;
        self.invalidateResults(now_ms);
    }

    pub fn toggleCase(self: *SearchBar, now_ms: i64) void {
        self.toggles.case_sensitive = !self.toggles.case_sensitive;
        self.invalidateResults(now_ms);
    }

    pub fn toggleWord(self: *SearchBar, now_ms: i64) void {
        self.toggles.whole_word = !self.toggles.whole_word;
        self.invalidateResults(now_ms);
    }
};

// ---------------------------------------------------------------------
// Match-marker downsampling
// ---------------------------------------------------------------------

/// Downsample `matches` (sorted ascending, unique row indices) into at
/// most `max_markers` normalized [0, 1] positions for the scrollbar
/// overlay.
///
/// When `matches.len <= max_markers` every match is returned directly
/// as `row / total_rows`.  Otherwise the scrollback is partitioned into
/// `max_markers` equal-height bins and any bin containing at least one
/// match emits a marker at the bin's midpoint.
pub fn downsampleMarkers(
    alloc: Allocator,
    matches: []const usize,
    total_rows: usize,
    max_markers: usize,
) Allocator.Error![]f32 {
    if (matches.len == 0 or total_rows == 0 or max_markers == 0) {
        return try alloc.alloc(f32, 0);
    }

    const rows_f: f64 = @floatFromInt(total_rows);

    // Fast path: few enough matches to emit them all.
    if (matches.len <= max_markers) {
        const out = try alloc.alloc(f32, matches.len);
        for (matches, 0..) |row, i| {
            out[i] = @floatCast(@as(f64, @floatFromInt(row)) / rows_f);
        }
        return out;
    }

    // Bucket path: partition into `max_markers` equal bins.
    const bin_height: f64 = rows_f / @as(f64, @floatFromInt(max_markers));

    // Bit-set tracking which bins are occupied.  Use a dynamic array of
    // bools — max_markers is typically small (scrollbar track pixels).
    const occupied = try alloc.alloc(bool, max_markers);
    defer alloc.free(occupied);
    @memset(occupied, false);

    for (matches) |row| {
        var bin: usize = @intFromFloat(@as(f64, @floatFromInt(row)) / bin_height);
        if (bin >= max_markers) bin = max_markers - 1;
        occupied[bin] = true;
    }

    // Count occupied bins, allocate output.
    var count: usize = 0;
    for (occupied) |o| {
        if (o) count += 1;
    }
    const out = try alloc.alloc(f32, count);

    var idx: usize = 0;
    for (occupied, 0..) |o, b| {
        if (o) {
            const mid: f64 = (@as(f64, @floatFromInt(b)) + 0.5) * bin_height / rows_f;
            out[idx] = @floatCast(mid);
            idx += 1;
        }
    }

    return out;
}

// =====================================================================
// Tests
// =====================================================================

test "open shows; close hides" {
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try std.testing.expect(!bar.visible);
    bar.open();
    try std.testing.expect(bar.visible);
    bar.close();
    try std.testing.expect(!bar.visible);
}

test "query survives close/open" {
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    bar.open();
    try bar.setQuery("foo", 1000);
    bar.close();
    bar.open();
    try std.testing.expectEqualStrings("foo", bar.query);
}

test "setQuery accepts aliased source slice" {
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("foo", 1000);
    try bar.setQuery(bar.query, 2000);
    try std.testing.expectEqualStrings("foo", bar.query);
    try std.testing.expectEqual(@as(i64, 2000), bar.last_edit_ms);
}

test "setQuery clears stale results for a new search" {
    var bar = SearchBar.init(std.testing.allocator);
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
    var bar = SearchBar.init(std.testing.allocator);
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
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("hi", 1000);
    try std.testing.expect(!bar.shouldRunSearch(1010)); // 10 ms < 40 ms
    try std.testing.expect(bar.shouldRunSearch(1041)); // 41 ms >= 40 ms
}

test "shouldRunSearch needs non-empty query" {
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("", 1000);
    try std.testing.expect(!bar.shouldRunSearch(2000));
}

test "forceSearch bypasses debounce" {
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("q", 1000);
    try std.testing.expect(bar.forceSearch());
    try std.testing.expect(!bar.shouldRunSearch(9999)); // already searched
}

test "toggleRegex flips bit" {
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try std.testing.expect(!bar.toggles.regex);
    bar.toggleRegex(1000);
    try std.testing.expect(bar.toggles.regex);
    bar.toggleRegex(2000);
    try std.testing.expect(!bar.toggles.regex);
}

test "toggle invalidates stale results for non-empty query" {
    var bar = SearchBar.init(std.testing.allocator);
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
    var bar = SearchBar.init(std.testing.allocator);
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
    var bar = SearchBar.init(std.testing.allocator);
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
    var bar = SearchBar.init(std.testing.allocator);
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
    var bar = SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    bar.open();
    bar.toggleCase(1000);
    bar.close();
    bar.open();
    try std.testing.expect(bar.toggles.case_sensitive);
}

test "N <= max returns all matches normalized" {
    const matches = [_]usize{ 10, 50, 90 };
    const out = try downsampleMarkers(std.testing.allocator, &matches, 100, 10);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), out[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.50), out[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.90), out[2], 0.001);
}

test "N > max buckets" {
    const matches = [_]usize{ 10, 20, 30, 40, 50 };
    const out = try downsampleMarkers(std.testing.allocator, &matches, 100, 2);
    defer std.testing.allocator.free(out);

    // 2 bins: [0..50) and [50..100).  Matches 10,20,30,40 in bin 0;
    // match 50 in bin 1.  Both occupied -> 2 markers.
    try std.testing.expectEqual(@as(usize, 2), out.len);
}

test "empty matches returns empty" {
    const matches = [_]usize{};
    const out = try downsampleMarkers(std.testing.allocator, &matches, 100, 10);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "total_rows=0 safe" {
    const matches = [_]usize{};
    const out = try downsampleMarkers(std.testing.allocator, &matches, 0, 10);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "single bucket with multiple matches" {
    const matches = [_]usize{ 5, 15, 25 };
    const out = try downsampleMarkers(std.testing.allocator, &matches, 30, 1);
    defer std.testing.allocator.free(out);

    // Single bin covers entire range; midpoint = 0.5.
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
}
