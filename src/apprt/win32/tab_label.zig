//! What the tab strip calls a tab: the label its button draws, the hover
//! tooltip that shows the title the label had to cut, and the name UI
//! Automation reports, all from one `Key`; and which tabs a strip of a given
//! width shows. `Host.syncTabButtons` builds each tab's Key from its facts and
//! rebuilds the button only when that Key differs from the one it last drew
//! (`Tab.cachedKey`). Nothing here touches a window.
const std = @import("std");
const Allocator = std.mem.Allocator;
const win32_chrome_state = @import("../win32_chrome_state.zig");
const win32_theme = @import("../win32_theme.zig");
const paint_text = @import("text.zig");

const compactHostLabel = paint_text.compactHostLabel;
const displayWidth = paint_text.displayWidth;

const default_metrics: win32_theme.ThemeMetrics = .{};
const host_tab_label_max_width: usize = default_metrics.tab_label_max_width;
const host_tab_min_button_width: i32 = default_metrics.tab_min_width;

/// Where a terminal's tab sits among its window's tabs: the window caption
/// and the overlays number it from this ("[2/3] pwsh").
pub const TabStatus = struct {
    index: usize = 0,
    total: usize = 1,
};

/// A tab as its button is about to be drawn.
pub const Facts = struct {
    /// The focused pane's title; a tab without one draws "koreterm".
    title: ?[]const u8,
    /// Position in the strip, from 0.
    index: usize,
    active: bool,
    /// The tab shows the bell glyph.
    bell: bool,
    pane_count: usize,
    /// A program status badge (OSC 7501) is drawn before the label.
    status_badge: bool,
    /// The button's width in pixels at `dpi`.
    button_width: i32,
    dpi: u32,
};

/// What the drawn label, the tooltip and the UIA name are built from: the
/// facts with the button's width turned into a cell budget. It is exactly
/// what `Tab` caches (`cached_button_*`), so two Keys that are `eql` draw the
/// same label.
pub const Key = struct {
    title: ?[]const u8,
    index: usize,
    active: bool,
    bell: bool,
    pane_count: usize,
    /// Cells the label may use, the status badge already charged.
    max_width: usize,
    /// The label shows the pane count: a split tab wide enough for it.
    show_pane_count: bool,

    /// Whether `a` and `b` draw the same label.
    pub fn eql(a: Key, b: Key) bool {
        return paint_text.optionalOwnedStringEquals(a.title, b.title) and
            a.bell == b.bell and
            a.index == b.index and
            a.active == b.active and
            a.pane_count == b.pane_count and
            a.max_width == b.max_width and
            a.show_pane_count == b.show_pane_count;
    }

    /// Whether `uiaName` names `a` and `b` alike. The drawn label cannot
    /// answer this: a narrow tab keeps the pane count out of its label, so
    /// splitting it moves the name while the label stays byte-identical, and
    /// a reader driven by NameChanged events keeps announcing the old one.
    pub fn sameUiaName(a: Key, b: Key) bool {
        // A tab with no title falls back to the drawn label, which `eql`
        // compares.
        return a.index == b.index and
            a.pane_count == b.pane_count and
            paint_text.optionalOwnedStringEquals(a.title, b.title);
    }
};

/// Cells the program status badge takes from the label with the gap after
/// it: its 15 DIP slot (`tab_status_badge_slot` in host.zig), at about 7 DIPs
/// a cell in the chrome font.
const tab_status_badge_cells: usize = 2;

/// The fewest cells `hostTabLabelMaxWidth` gives a label.
const tab_label_min_cells: usize = 6;

/// The Key of a tab with these facts.
pub fn key(facts: Facts) Key {
    const label_max_width = hostTabLabelMaxWidth(facts.button_width, facts.dpi);
    return .{
        .title = facts.title,
        .index = facts.index,
        .active = facts.active,
        .bell = facts.bell,
        .pane_count = facts.pane_count,
        // A program status badge takes its slot out of the label's room,
        // charged in cells after `hostTabLabelMaxWidth` has capped the
        // budget the way the layout caps the button.
        .max_width = if (facts.status_badge)
            @max(tab_label_min_cells, label_max_width -| tab_status_badge_cells)
        else
            label_max_width,
        .show_pane_count = shouldShowPaneCount(facts.button_width, facts.pane_count, facts.dpi),
    };
}

/// The label the tab's button draws: `"* "` on the active tab, the index
/// from 1, the title compacted to the cells the button leaves it, and the
/// pane count when the Key shows it; an alerted tab has the bell glyph in
/// front. The glyph sits outside the text that is compacted, so a narrow
/// tab shortens its title and never loses the glyph. Caller frees.
pub fn text(alloc: Allocator, k: Key) ![]u8 {
    const label = try buildTabButtonLabel(alloc, k);
    if (!k.bell) return label;
    defer alloc.free(label);
    return withTitleGlyph(alloc, label);
}

/// The tab's hover tooltip: its whole title, bounded only by
/// `tooltip_max_width`. Null when the drawn label shows all of the title, or
/// the tab has none: repeating a title that fits is noise. Caller frees.
///
/// The gate measures the BARE title against the budget the label compacted
/// it to, not the drawn label against the button's own budget. The label
/// also carries the index, the active marker, the pane count and the glyph,
/// and is built to fit, so asking whether it fits always answered no; it also
/// answered differently for an active tab than for its inactive neighbour
/// showing the same title.
pub fn tooltip(alloc: Allocator, k: Key) !?[]u8 {
    const title = k.title orelse return null;
    if (displayWidth(title) <= titleBudget(k)) return null;
    return try compactHostLabel(alloc, title, tooltip_max_width);
}

/// Widest tooltip title the tab strip will build. A title past this is
/// pathological -- a runaway OSC 0 sequence, say -- and the popup would run off
/// the window long before it was readable.
pub const tooltip_max_width: usize = 240;

/// The UIA name of the tab at `index` (from 0) with `pane_count` panes,
/// written into `buf`: the three things `Key.sameUiaName` compares.
///
/// The name carries the tab's 1-based index and its FULL title -- assistive
/// technology has no button to run out of -- plus the pane count of a split
/// tab, because "2: pwsh" and "2: pwsh (3)" are different tabs to a
/// screen-reader user and only the second one is split, even where the
/// button is too narrow to show the count. Null when the tab has no title or
/// `buf` cannot hold the name, so the caller falls back to the drawn label
/// instead of reporting a cut name.
pub fn uiaName(buf: []u8, title: ?[]const u8, index: usize, pane_count: usize) ?[]const u8 {
    const value = title orelse return null;
    if (pane_count > 1) {
        return std.fmt.bufPrint(
            buf,
            "{d}: {s} ({d})",
            .{ index + 1, value, pane_count },
        ) catch null;
    }
    return std.fmt.bufPrint(buf, "{d}: {s}", .{ index + 1, value }) catch null;
}

/// The tabs a strip shows: `count` of them from `start`.
const Window = struct {
    start: usize,
    count: usize,
};

/// Which of `tab_count` tabs a strip `tab_area_width` pixels wide shows at
/// `dpi`: as many as fit at the minimum button width, centred on the active
/// tab where the ends allow.
pub fn visible(tab_count: usize, active_index: usize, tab_area_width: i32, dpi: u32) Window {
    if (tab_count == 0) return .{ .start = 0, .count = 0 };
    const max_visible = std.math.clamp(
        @as(usize, @intCast(@max(1, @divTrunc(tab_area_width, @max(1, win32_chrome_state.scaled(host_tab_min_button_width, dpi)))))),
        @as(usize, 1),
        tab_count,
    );
    if (tab_count <= max_visible) return .{ .start = 0, .count = tab_count };

    const clamped_active = @min(active_index, tab_count - 1);
    var start = clamped_active;
    if (max_visible > 1) start = clamped_active -| @divTrunc(max_visible - 1, 2);
    if (start + max_visible > tab_count) start = tab_count - max_visible;
    return .{ .start = start, .count = max_visible };
}

/// The bell glyph in front of an alerted title, on its tab and on the
/// window caption, with the space that separates it.
pub const title_glyph = "\u{1F514} ";

/// `title` with the bell glyph in front. Caller frees.
pub fn withTitleGlyph(alloc: Allocator, title: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, title_glyph ++ "{s}", .{title});
}

/// Display cells `title_glyph` takes in a tab label (the emoji is two wide).
const title_glyph_cells: usize = 3;

/// Cell budget for a tab label drawn into a `button_width` pixel button.
///
/// The divisor is an average glyph advance, so the budget is an estimate; GDI
/// still applies `DT_END_ELLIPSIS` when the estimate ran long.
fn hostTabLabelMaxWidth(button_width: i32, dpi: u32) usize {
    const estimated: usize = @intCast(@max(0, @divTrunc(button_width - win32_chrome_state.scaled(26, dpi), @max(1, win32_chrome_state.scaled(8, dpi)))));
    return std.math.clamp(estimated, tab_label_min_cells, host_tab_label_max_width);
}

fn shouldShowPaneCount(button_width: i32, pane_count: usize, dpi: u32) bool {
    return pane_count > 1 and button_width >= win32_chrome_state.scaled(140, dpi);
}

const tab_button_label_fmt = "{s}{d}: {s}";
const tab_button_label_pane_fmt = "{s}{d}: {s} ({d})";

/// Smallest title budget `titleBudget` will hand back. A button too narrow to
/// hold even its own decorations still shows an ellipsis rather than nothing;
/// the label then overflows, which is exactly what the tab strip's
/// `DT_END_ELLIPSIS` is there for.
const tab_button_min_title_width: usize = 3;

/// The cells the title gets in `k`'s label: what the label compacts it to and
/// what the tooltip gate measures it against, so the two cannot disagree. The
/// bell glyph and the label's decorations -- the `"* "` active marker, the
/// `"N: "` index prefix and the `" (N)"` pane count -- are paid for out of
/// `k.max_width` first, so the label stays inside the button.
fn titleBudget(k: Key) usize {
    const cells = if (k.bell) k.max_width -| title_glyph_cells else k.max_width;
    // Render the decorations around an empty title so the measurement can
    // never drift from the format strings below, and measure them with the
    // same `displayWidth` the compaction spends its budget in.
    var buf: [96]u8 = undefined;
    const decoration = if (k.show_pane_count and k.pane_count > 1)
        std.fmt.bufPrint(
            &buf,
            tab_button_label_pane_fmt,
            .{ tabButtonActiveMarker(k.active), k.index + 1, "", k.pane_count },
        )
    else
        std.fmt.bufPrint(
            &buf,
            tab_button_label_fmt,
            .{ tabButtonActiveMarker(k.active), k.index + 1, "" },
        );
    // `buf` holds the widest decoration two `usize` decimals can produce, so
    // the error arm is unreachable in practice; charging the whole budget
    // keeps it conservative rather than silently restoring the old overflow.
    const decoration_width = if (decoration) |label| displayWidth(label) else |_| cells;
    return @max(tab_button_min_title_width, cells -| decoration_width);
}

fn tabButtonActiveMarker(active: bool) []const u8 {
    return if (active) "* " else "";
}

/// The label without the bell glyph.
fn buildTabButtonLabel(alloc: Allocator, k: Key) ![]u8 {
    const compact = try compactHostLabel(alloc, k.title orelse "koreterm", titleBudget(k));
    defer alloc.free(compact);
    if (k.show_pane_count and k.pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            tab_button_label_pane_fmt,
            .{
                tabButtonActiveMarker(k.active),
                k.index + 1,
                compact,
                k.pane_count,
            },
        );
    }

    return try std.fmt.allocPrint(
        alloc,
        tab_button_label_fmt,
        .{
            tabButtonActiveMarker(k.active),
            k.index + 1,
            compact,
        },
    );
}

const testing = std.testing;

/// A tab without a bell.
fn testKey(
    title: ?[]const u8,
    index: usize,
    active: bool,
    pane_count: usize,
    max_width: usize,
    show_pane_count: bool,
) Key {
    return .{
        .title = title,
        .index = index,
        .active = active,
        .bell = false,
        .pane_count = pane_count,
        .max_width = max_width,
        .show_pane_count = show_pane_count,
    };
}

/// The Key of an inactive "pwsh" tab in a `button_width` pixel button at
/// `dpi`.
fn widthKey(button_width: i32, dpi: u32, pane_count: usize, status_badge: bool) Key {
    return key(.{
        .title = "pwsh",
        .index = 0,
        .active = false,
        .bell = false,
        .pane_count = pane_count,
        .status_badge = status_badge,
        .button_width = button_width,
        .dpi = dpi,
    });
}

fn expectText(expected: []const u8, k: Key) !void {
    const label = try text(testing.allocator, k);
    defer testing.allocator.free(label);
    try testing.expectEqualStrings(expected, label);
}

fn expectTooltip(expected: ?[]const u8, k: Key) !void {
    const shown = try tooltip(testing.allocator, k);
    defer if (shown) |value| testing.allocator.free(value);
    if (expected) |value| {
        try testing.expect(shown != null);
        try testing.expectEqualStrings(value, shown.?);
    } else {
        try testing.expect(shown == null);
    }
}

test "win32 tab label marks the active tab and its pane count" {
    try expectText("* 2: pwsh (3)", testKey("pwsh", 1, true, 3, 24, true));
}

test "win32 tab label omits the pane count of a single-pane tab" {
    try expectText("1: pwsh", testKey("pwsh", 0, false, 1, 24, false));
}

test "win32 tab label compacts a long title" {
    try expectText("1: this-is-a-very-lon...", testKey("this-is-a-very-long-terminal-title", 0, false, 1, 24, false));
}

test "win32 tab label keeps a narrow CJK title valid UTF-8" {
    const label = try text(testing.allocator, testKey(
        "\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{30bf}\u{30a4}\u{30c8}\u{30eb}",
        0,
        false,
        1,
        9,
        false,
    ));
    defer testing.allocator.free(label);
    try testing.expect(std.unicode.utf8ValidateSlice(label));
    try testing.expectEqualStrings("1: \u{65e5}...", label);
}

test "win32 tab label drops the pane count when the tab is narrow" {
    // A 98 px button at 96 DPI has 9 cells and no room for the count.
    try expectText("2: log...", key(.{
        .title = "logs-and-output-pane",
        .index = 1,
        .active = false,
        .bell = false,
        .pane_count = 3,
        .status_badge = false,
        .button_width = 98,
        .dpi = 96,
    }));
}

test "win32 tab tooltip shows only a title the drawn label hides" {
    try expectTooltip(null, testKey("build", 0, false, 1, 24, false));
    // Eight kana are sixteen cells: they fit the widest tab but not the nine a
    // narrow one gets, and that gap is exactly when a tooltip has something to
    // add.
    const kana = "\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{30bf}\u{30a4}\u{30c8}\u{30eb}";
    try expectTooltip(null, testKey(kana, 0, false, 1, 24, false));
    try expectTooltip(kana, testKey(kana, 0, false, 1, 9, false));
    // A tab without a title has nothing to show in one.
    try expectTooltip(null, testKey(null, 0, false, 1, 9, false));
}

test "win32 tab label charges its decorations to the button's budget" {
    // "* " + "1: " + " (3)" is nine cells the title cannot also spend, so a
    // 24-cell button leaves it 15; without the count 19, and the inactive
    // second tab ("2: ") 21.
    const long = "a" ** 40;
    try expectText("* 1: " ++ "a" ** 12 ++ "... (3)", testKey(long, 0, true, 3, 24, true));
    try expectText("* 1: " ++ "a" ** 16 ++ "...", testKey(long, 0, true, 3, 24, false));
    try expectText("2: " ++ "a" ** 18 ++ "...", testKey(long, 1, false, 1, 24, false));
    // A button too narrow for its own decorations still shows an ellipsis.
    try expectText("* 1: ... (3)", testKey(long, 0, true, 3, 6, true));

    // The decorated label stays inside the button either way; it used to run
    // up to nine cells past it.
    for ([_]bool{ true, false }) |active| {
        const label = try text(testing.allocator, testKey(long, 0, active, 3, 24, true));
        defer testing.allocator.free(label);
        try testing.expect(displayWidth(label) <= 24);
    }
}

test "win32 tab tooltip decision matches for an active tab and its neighbour" {
    // Eighteen cells, so the title fits even the active tab's 19-cell budget:
    // nothing is hidden and neither tab has anything to say in a tooltip.
    const fits = "session-alpha-1234";
    try expectText("* 1: session-alpha-1234", testKey(fits, 0, true, 1, 24, false));
    try expectText("2: session-alpha-1234", testKey(fits, 1, false, 1, 24, false));
    try expectTooltip(null, testKey(fits, 0, true, 1, 24, false));
    try expectTooltip(null, testKey(fits, 1, false, 1, 24, false));

    // The gate measures the bare title against the budget it was actually
    // compacted to. Measuring the decorated label against the button budget
    // instead made this pair disagree -- tooltip on the active tab, none on
    // its neighbour, same title.
    const long = "session-alpha-1234-beta-5678";
    try expectTooltip(long, testKey(long, 0, true, 1, 24, false));
    try expectTooltip(long, testKey(long, 1, false, 1, 24, false));
}

test "win32 tab UIA name keeps the pane count the drawn label shows" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("2: pwsh (3)", uiaName(&buf, "pwsh", 1, 3).?);
    // One pane is the ordinary case and carries no count, matching the label.
    try testing.expectEqualStrings("1: pwsh", uiaName(&buf, "pwsh", 0, 1).?);
    // The name is the full title, not the compacted one the button draws.
    const long = "a" ** 40;
    try testing.expectEqualStrings("1: " ++ long, uiaName(&buf, long, 0, 1).?);
    // A title too long for the provider's buffer is refused so the caller can
    // fall back to the drawn label instead of reporting a cut name, and so is
    // a tab without a title.
    var tiny: [4]u8 = undefined;
    try testing.expect(uiaName(&tiny, "pwsh", 0, 1) == null);
    try testing.expect(uiaName(&buf, null, 0, 1) == null);
}

test "win32 tab UIA name changes with a split the drawn label hides" {
    // Splitting a narrow tab: the 120 px button keeps the count out of the
    // label, so the drawn text is byte-identical and only `sameUiaName` can
    // tell the UIA name moved.
    const before = widthKey(120, 96, 1, false);
    const after = widthKey(120, 96, 2, false);
    try testing.expect(!after.show_pane_count);
    const before_label = try text(testing.allocator, before);
    defer testing.allocator.free(before_label);
    const after_label = try text(testing.allocator, after);
    defer testing.allocator.free(after_label);
    try testing.expectEqualStrings(before_label, after_label);
    try testing.expect(!before.sameUiaName(after));

    // And the comparison agrees with the names themselves.
    var before_buf: [64]u8 = undefined;
    var after_buf: [64]u8 = undefined;
    try testing.expect(!std.mem.eql(
        u8,
        uiaName(&before_buf, before.title, before.index, before.pane_count).?,
        uiaName(&after_buf, after.title, after.index, after.pane_count).?,
    ));

    // Nothing moved: no event, or every layout pass would announce the tab.
    try testing.expect(before.sameUiaName(before));
    // A reorder and a retitle both change the name.
    try testing.expect(!before.sameUiaName(testKey("pwsh", 1, false, 1, 24, false)));
    try testing.expect(!before.sameUiaName(testKey("bash", 0, false, 1, 24, false)));
    // A tab with no title rides on the drawn-label fallback the caller checks.
    try testing.expect(testKey(null, 0, false, 1, 24, false).sameUiaName(testKey(null, 0, false, 1, 24, false)));
    try testing.expect(!testKey(null, 0, false, 1, 24, false).sameUiaName(before));
}

test "win32 tab tooltip keeps a runaway title bounded" {
    const shown = (try tooltip(testing.allocator, testKey("a" ** 600, 0, false, 1, 24, false))).?;
    defer testing.allocator.free(shown);
    try testing.expectEqual(tooltip_max_width, displayWidth(shown));
    try testing.expect(std.mem.endsWith(u8, shown, "..."));
}

test "CHROME57 tab budgets and overflow use device-independent widths" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const scale = win32_chrome_state.scaled;
        try testing.expectEqualDeep(Window{ .start = 2, .count = 3 }, visible(6, 3, scale(324, dpi), dpi));
        try testing.expectEqual(@as(usize, 24), widthKey(scale(260, dpi), dpi, 1, false).max_width);
        try testing.expectEqual(@as(usize, 9), widthKey(scale(98, dpi), dpi, 1, false).max_width);
        try testing.expect(!widthKey(scale(139, dpi), dpi, 2, false).show_pane_count);
        try testing.expect(widthKey(scale(140, dpi), dpi, 2, false).show_pane_count);
        try testing.expectEqual(@as(usize, 1), visible(6, 5, 1, dpi).count);
    }
}

test "win32 tab label budget shrinks with narrow tab widths" {
    try testing.expectEqual(@as(usize, 6), widthKey(40, 96, 1, false).max_width);
    try testing.expect(widthKey(180, 96, 3, false).show_pane_count);
    try testing.expect(!widthKey(120, 96, 3, false).show_pane_count);
}

test "win32 tab strip windows its tabs around the active tab" {
    try testing.expectEqualDeep(Window{ .start = 0, .count = 3 }, visible(6, 0, 324, 96));
    try testing.expectEqualDeep(Window{ .start = 3, .count = 3 }, visible(6, 5, 324, 96));
    try testing.expectEqualDeep(Window{ .start = 0, .count = 2 }, visible(2, 1, 500, 96));
}

test "win32 bell title glyph goes in front and leaves the title alone" {
    const alerted = try withTitleGlyph(testing.allocator, "pwsh");
    defer testing.allocator.free(alerted);
    try testing.expectEqualStrings("\u{1F514} pwsh", alerted);
    const empty = try withTitleGlyph(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("\u{1F514} ", empty);
}

test "win32 bell tab label keeps the glyph on a narrow tab" {
    const glyph = title_glyph;
    var beta = testKey("beta", 1, false, 1, 24, false);
    // The same tab without a bell is the plain label.
    try expectText("2: beta", beta);
    // Plenty of room: the title keeps all but the glyph's three cells.
    beta.bell = true;
    try expectText(glyph ++ "2: beta", beta);
    // Narrow: the active tab 10 leaves four cells for its title. The title is
    // compacted, the glyph is not.
    var narrow = testKey("beta gamma", 9, true, 1, 10, false);
    narrow.bell = true;
    const label = try text(testing.allocator, narrow);
    defer testing.allocator.free(label);
    try testing.expect(std.mem.startsWith(u8, label, glyph));
    try testing.expect(std.mem.indexOf(u8, label, "10: ") != null);

    // The tooltip gate's budget is the label's: twenty cells fit tab 2's 21
    // without a bell and are compacted to 18 with one, and the tooltip
    // appears exactly then.
    const twenty = "a" ** 20;
    var alerted = testKey(twenty, 1, false, 1, 24, false);
    try expectText("2: " ++ twenty, alerted);
    try expectTooltip(null, alerted);
    alerted.bell = true;
    try expectText(glyph ++ "2: " ++ "a" ** 15 ++ "...", alerted);
    try expectTooltip(twenty, alerted);
    // A budget smaller than the glyph leaves the title the minimum, not less.
    var tiny = testKey("beta", 0, false, 1, 2, false);
    tiny.bell = true;
    try expectText(glyph ++ "1: ...", tiny);
}

test "win32 tab label keys are equal only when every label input is" {
    const base = testKey("pwsh", 1, true, 2, 24, true);
    try testing.expect(base.eql(testKey("pwsh", 1, true, 2, 24, true)));
    var bell = base;
    bell.bell = true;
    for ([_]Key{
        testKey("bash", 1, true, 2, 24, true),
        testKey(null, 1, true, 2, 24, true),
        bell,
        testKey("pwsh", 0, true, 2, 24, true),
        testKey("pwsh", 1, false, 2, 24, true),
        testKey("pwsh", 1, true, 3, 24, true),
        testKey("pwsh", 1, true, 2, 23, true),
        testKey("pwsh", 1, true, 2, 24, false),
    }) |other| {
        try testing.expect(!base.eql(other));
        try testing.expect(!other.eql(base));
    }
    // Two tabs without a title draw the same label, and no title is not an
    // empty one.
    try testing.expect(testKey(null, 0, false, 1, 24, false).eql(testKey(null, 0, false, 1, 24, false)));
    try testing.expect(!testKey(null, 0, false, 1, 24, false).eql(testKey("", 0, false, 1, 24, false)));
}

test "win32 a status badge comes out of the label's cells after the button's cap" {
    // Charged after `hostTabLabelMaxWidth` caps the budget: a wide button is
    // capped at 24 cells and the badge takes two of those.
    try testing.expectEqual(@as(usize, 24), widthKey(1000, 96, 1, false).max_width);
    try testing.expectEqual(@as(usize, 22), widthKey(1000, 96, 1, true).max_width);
    try testing.expectEqual(@as(usize, 7), widthKey(98, 96, 1, true).max_width);
    // Never below the fewest cells a label gets.
    try testing.expectEqual(@as(usize, 6), widthKey(40, 96, 1, true).max_width);
}
