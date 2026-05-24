//! Status-bar fragment model for the Win32 apprt.
//!
//! Pure state + layout math — no HWND, no paint, no Win32 externs.
//!
//! The redesigned status bar is 28 px tall (`ThemeMetrics.height_status`),
//! down from 42 px. It drops the `^N%` scroll fragment (the graphical
//! scrollbar owns that signal) and renders the remaining fragments
//! separated by a 2 px middle-dot (`U+00B7`) with `space_4` padding on
//! each side.
//!
//! Fragment pipeline:
//!   1. Caller resolves a `Status` struct each paint.
//!   2. `composeFragments` fills an ordered slice of `Fragment` values
//!      using caller-owned scratch buffers for dynamic text (digit runs).
//!   3. `truncateToFit` trims whole fragments from the right when the
//!      composed line exceeds the available pixel width.
//!   4. The paint layer walks the returned fragments, inserting the
//!      middle-dot separator between them and applying `tnum` OpenType
//!      features where `isDigitRun` returns true.
//!
//! The public API is allocation-free; callers provide scratch buffers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Static labels
// ---------------------------------------------------------------------------

pub const readonly_label = "Read-only";
pub const secure_input_label = "Sensitive input";
pub const inspector_label = "Inspector";

// ---------------------------------------------------------------------------
// Separator
// ---------------------------------------------------------------------------

/// Middle-dot separator rendered between fragments (U+00B7).
/// Approximately 2 px wide in most monospace fonts.
pub const separator_dot = "\xc2\xb7"; // UTF-8 for U+00B7

// ---------------------------------------------------------------------------
// Status input
// ---------------------------------------------------------------------------

pub const Status = struct {
    tab_index: usize,
    tab_total: usize,
    pane_index: usize,
    pane_total: usize,
    readonly: bool,
    secure_input: bool,
    inspector_active: bool,
    key_sequence: ?[]const u8 = null,
    key_table: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Fragment types
// ---------------------------------------------------------------------------

pub const max_fragments: usize = 8;

pub const Kind = enum {
    tabs,
    panes,
    readonly,
    secure_input,
    inspector,
    key_sequence,
    key_table,
};

pub const Fragment = struct {
    kind: Kind,
    text: []const u8,
};

// ---------------------------------------------------------------------------
// Fragment composition
// ---------------------------------------------------------------------------

/// Produce the ordered list of visible fragments for `status`.
///
/// Order: tabs, panes, readonly, secure_input, inspector,
/// key_sequence, key_table. Inactive fragments are omitted.
///
/// `scratch` is caller-owned storage used for dynamic digit-run text
/// (tab count, pane count). Static labels point to module constants.
pub fn composeFragments(
    status: Status,
    scratch: *[max_fragments][64]u8,
) struct { fragments: [max_fragments]Fragment, len: usize } {
    var out: [max_fragments]Fragment = undefined;
    var n: usize = 0;

    // -- tabs (always present) --
    const tab_len = formatFraction("Tab ", status.tab_index + 1, status.tab_total, &scratch[0]);
    out[n] = .{ .kind = .tabs, .text = scratch[0][0..tab_len] };
    n += 1;

    // -- panes (always present) --
    const pane_len = formatFraction("Pane ", status.pane_index + 1, status.pane_total, &scratch[1]);
    out[n] = .{ .kind = .panes, .text = scratch[1][0..pane_len] };
    n += 1;

    // -- readonly --
    if (status.readonly) {
        out[n] = .{ .kind = .readonly, .text = readonly_label };
        n += 1;
    }

    // -- secure input --
    if (status.secure_input) {
        out[n] = .{ .kind = .secure_input, .text = secure_input_label };
        n += 1;
    }

    // -- inspector --
    if (status.inspector_active) {
        out[n] = .{ .kind = .inspector, .text = inspector_label };
        n += 1;
    }

    // -- key sequence --
    if (status.key_sequence) |seq| {
        out[n] = .{ .kind = .key_sequence, .text = seq };
        n += 1;
    }

    // -- key table --
    if (status.key_table) |tbl| {
        out[n] = .{ .kind = .key_table, .text = tbl };
        n += 1;
    }

    return .{ .fragments = out, .len = n };
}

// ---------------------------------------------------------------------------
// Tabular-numeral hint
// ---------------------------------------------------------------------------

/// Returns true when every byte in `text` is an ASCII digit ('0'..'9').
/// Empty strings return false.
pub fn isDigitRun(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Ellipsis-aware layout (truncate whole fragments)
// ---------------------------------------------------------------------------

/// Return the longest prefix of `fragments` (joined with ` · `) that
/// fits within `available_px`. Fragments are dropped from the right;
/// text within a fragment is never split.
pub fn truncateToFit(
    fragments: []const Fragment,
    available_px: i32,
    separator_px: i32,
    measure: *const fn (text: []const u8) i32,
) []const Fragment {
    if (fragments.len == 0 or available_px <= 0) return fragments[0..0];

    // Compute cumulative widths left-to-right so we can binary-search
    // the largest fitting prefix, but a linear scan is fine for <= 8.
    var total: i32 = 0;
    var fit: usize = 0;

    for (fragments, 0..) |frag, i| {
        const w = measure(frag.text);
        const sep = if (i > 0) separator_px else @as(i32, 0);
        const next_total = total + sep + w;
        if (next_total > available_px) break;
        total = next_total;
        fit = i + 1;
    }

    return fragments[0..fit];
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Write `"<prefix><a>/<b>"` into `buf` and return the length written.
fn formatFraction(
    comptime prefix: []const u8,
    a: usize,
    b: usize,
    buf: *[64]u8,
) usize {
    const slice = std.fmt.bufPrint(buf, prefix ++ "{d}/{d}", .{ a, b }) catch unreachable;
    return slice.len;
}

// ===========================================================================
// Tests
// ===========================================================================

test "composeFragments: minimal — only tab and pane" {
    var scratch: [max_fragments][64]u8 = undefined;
    const result = composeFragments(.{
        .tab_index = 0,
        .tab_total = 3,
        .pane_index = 0,
        .pane_total = 1,
        .readonly = false,
        .secure_input = false,
        .inspector_active = false,
    }, &scratch);

    const frags = result.fragments[0..result.len];
    try std.testing.expectEqual(@as(usize, 2), frags.len);
    try std.testing.expectEqualStrings("Tab 1/3", frags[0].text);
    try std.testing.expectEqualStrings("Pane 1/1", frags[1].text);
    try std.testing.expectEqual(Kind.tabs, frags[0].kind);
    try std.testing.expectEqual(Kind.panes, frags[1].kind);
}

test "composeFragments: readonly adds fragment" {
    var scratch: [max_fragments][64]u8 = undefined;
    const result = composeFragments(.{
        .tab_index = 0,
        .tab_total = 1,
        .pane_index = 0,
        .pane_total = 1,
        .readonly = true,
        .secure_input = false,
        .inspector_active = false,
    }, &scratch);

    const frags = result.fragments[0..result.len];
    try std.testing.expectEqual(@as(usize, 3), frags.len);
    try std.testing.expectEqual(Kind.readonly, frags[2].kind);
    try std.testing.expectEqualStrings(readonly_label, frags[2].text);
}

test "composeFragments: all flags on — 7 fragments in order" {
    var scratch: [max_fragments][64]u8 = undefined;
    const result = composeFragments(.{
        .tab_index = 2,
        .tab_total = 5,
        .pane_index = 1,
        .pane_total = 4,
        .readonly = true,
        .secure_input = true,
        .inspector_active = true,
        .key_sequence = "Ctrl+A",
        .key_table = "vim",
    }, &scratch);

    const frags = result.fragments[0..result.len];
    try std.testing.expectEqual(@as(usize, 7), frags.len);

    try std.testing.expectEqual(Kind.tabs, frags[0].kind);
    try std.testing.expectEqual(Kind.panes, frags[1].kind);
    try std.testing.expectEqual(Kind.readonly, frags[2].kind);
    try std.testing.expectEqual(Kind.secure_input, frags[3].kind);
    try std.testing.expectEqual(Kind.inspector, frags[4].kind);
    try std.testing.expectEqual(Kind.key_sequence, frags[5].kind);
    try std.testing.expectEqual(Kind.key_table, frags[6].kind);

    try std.testing.expectEqualStrings("Tab 3/5", frags[0].text);
    try std.testing.expectEqualStrings("Pane 2/4", frags[1].text);
    try std.testing.expectEqualStrings(readonly_label, frags[2].text);
    try std.testing.expectEqualStrings(secure_input_label, frags[3].text);
    try std.testing.expectEqualStrings(inspector_label, frags[4].text);
    try std.testing.expectEqualStrings("Ctrl+A", frags[5].text);
    try std.testing.expectEqualStrings("vim", frags[6].text);
}

test "composeFragments: scratch buffers hold dynamic text" {
    var scratch: [max_fragments][64]u8 = undefined;
    const result = composeFragments(.{
        .tab_index = 0,
        .tab_total = 3,
        .pane_index = 0,
        .pane_total = 1,
        .readonly = false,
        .secure_input = false,
        .inspector_active = false,
    }, &scratch);

    const frags = result.fragments[0..result.len];

    // Verify that fragment text is backed by scratch memory.
    const tab_ptr = @intFromPtr(frags[0].text.ptr);
    const scratch0_ptr = @intFromPtr(&scratch[0]);
    try std.testing.expect(tab_ptr >= scratch0_ptr and tab_ptr < scratch0_ptr + 64);

    const pane_ptr = @intFromPtr(frags[1].text.ptr);
    const scratch1_ptr = @intFromPtr(&scratch[1]);
    try std.testing.expect(pane_ptr >= scratch1_ptr and pane_ptr < scratch1_ptr + 64);
}

test "isDigitRun: pure digits" {
    try std.testing.expect(isDigitRun("123"));
    try std.testing.expect(isDigitRun("42"));
}

test "isDigitRun: non-digit strings" {
    try std.testing.expect(!isDigitRun("Tab 1/3"));
    try std.testing.expect(!isDigitRun("1/3"));
}

test "isDigitRun: empty string" {
    try std.testing.expect(!isDigitRun(""));
}

test "truncateToFit: all fragments fit" {
    const frags = [_]Fragment{
        .{ .kind = .tabs, .text = "Tab 1/3" },
        .{ .kind = .panes, .text = "Pane 1/1" },
        .{ .kind = .readonly, .text = readonly_label },
    };
    // Each char = 10 px, separator = 20 px. Widths: 70 + 20 + 80 + 20 + 90 = 280.
    const result = truncateToFit(&frags, 300, 20, &charMeasure);
    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "truncateToFit: only 2 of 3 fit" {
    const frags = [_]Fragment{
        .{ .kind = .tabs, .text = "Tab 1/3" },
        .{ .kind = .panes, .text = "Pane 1/1" },
        .{ .kind = .readonly, .text = readonly_label },
    };
    // 70 + 20 + 80 = 170 for first two; + 20 + 90 = 280 total (too wide for 200).
    const result = truncateToFit(&frags, 200, 20, &charMeasure);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "truncateToFit: zero width" {
    const frags = [_]Fragment{
        .{ .kind = .tabs, .text = "Tab 1/3" },
    };
    const result = truncateToFit(&frags, 0, 20, &charMeasure);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "truncateToFit: single fragment overflows" {
    const frags = [_]Fragment{
        .{ .kind = .tabs, .text = "Tab 1/3" },
    };
    // 70 px needed, only 50 available.
    const result = truncateToFit(&frags, 50, 20, &charMeasure);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Trivial measure function for tests: each byte = 10 px.
fn charMeasure(text: []const u8) i32 {
    return @as(i32, @intCast(text.len)) * 10;
}
