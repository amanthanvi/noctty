pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
pub const table = @import("props_table.zig").table;
pub const Properties = @import("props.zig").Properties;
pub const GraphemeWidthEffect = grapheme.GraphemeWidthEffect;
pub const GraphemeWidth = grapheme.GraphemeWidth;
pub const graphemeBreak = grapheme.graphemeBreak;
pub const graphemeWidth = grapheme.graphemeWidth;
pub const graphemeWidthEffect = grapheme.graphemeWidthEffect;

/// Returns the terminal display width of a codepoint in terminal
/// grid cells: 0, 1, or 2.
///
/// This is the same width table the terminal uses when laying out
/// printed text: 0 for zero-width codepoints (controls, combining
/// marks, default-ignorables, surrogates), 2 for wide codepoints
/// (East Asian Wide/Fullwidth, regional indicators, clamped at 2),
/// and 1 otherwise.
///
/// This operates on a single codepoint and cannot account for
/// grapheme-cluster-level width rules (VS16, combining sequences);
/// callers needing cluster-accurate widths should use graphemeWidth().
/// Summing per-codepoint widths is only correct when mode 2027 is
/// disabled.
pub fn codepointWidth(cp: u21) u2 {
    return table.get(cp).width;
}

test "codepointWidth" {
    const testing = @import("std").testing;

    // Narrow (width 1)
    try testing.expectEqual(1, codepointWidth('a'));
    try testing.expectEqual(1, codepointWidth(' '));
    try testing.expectEqual(1, codepointWidth(0x10FFFF)); // max codepoint

    // C0/C1 control characters (width 0)
    try testing.expectEqual(0, codepointWidth(0x00)); // NUL
    try testing.expectEqual(0, codepointWidth(0x07)); // BEL
    try testing.expectEqual(0, codepointWidth(0x1B)); // ESC
    try testing.expectEqual(0, codepointWidth(0x7F)); // DEL
    try testing.expectEqual(0, codepointWidth(0x80)); // C1 PAD

    // Zero-width codepoints
    try testing.expectEqual(0, codepointWidth(0x0301)); // combining acute
    try testing.expectEqual(0, codepointWidth(0x200B)); // zero width space
    try testing.expectEqual(0, codepointWidth(0x200D)); // ZWJ
    try testing.expectEqual(0, codepointWidth(0xFE0F)); // VS16
    try testing.expectEqual(0, codepointWidth(0xD800)); // surrogate

    // Wide (width 2)
    try testing.expectEqual(2, codepointWidth(0x4E00)); // CJK ideograph
    try testing.expectEqual(2, codepointWidth(0xFF21)); // fullwidth A
    try testing.expectEqual(2, codepointWidth(0xAC00)); // Hangul syllable
    try testing.expectEqual(2, codepointWidth(0x1F600)); // emoji
    try testing.expectEqual(2, codepointWidth(0x1F1E6)); // regional indicator
    try testing.expectEqual(2, codepointWidth(0x2E3B)); // three-em dash (clamped)
}

/// The rows of the bundled ConPTY width table (`testdata/conpty_width.tsv`,
/// written by `test/windows/hidden-win11-conpty-width.ps1`) whose width is
/// not `widthOf`'s, each printed. Counts the `unicode18` rows into
/// `unicode18_rows`; a row that is not `<hex>\t<width>\t<kind>` is an error.
fn conptyWidthMismatches(tsv: []const u8, widthOf: *const fn (u21) u2, unicode18_rows: *usize) !usize {
    const std = @import("std");
    var mismatches: usize = 0;
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |raw| {
        // .gitattributes keeps the table LF; a CR from another checkout is no row's.
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const cp = try std.fmt.parseInt(u21, cols.next() orelse return error.BadRow, 16);
        const width = try std.fmt.parseInt(u2, cols.next() orelse return error.BadRow, 10);
        const kind = cols.next() orelse return error.BadRow;
        if (cols.next() != null) return error.BadRow;
        if (std.mem.eql(u8, kind, "unicode18")) {
            unicode18_rows.* += 1;
        } else if (!std.mem.eql(u8, kind, "control")) return error.BadRow;
        const have = widthOf(cp);
        if (have != width) {
            std.debug.print("U+{X:0>4} ({s}): the bundled ConPTY gives {d}, noctty {d}\n", .{ cp, kind, width, have });
            mismatches += 1;
        }
    }
    return mismatches;
}

test "unicode: widths match the bundled ConPTY's measured widths" {
    // PLAN.md 7.7, the Unicode 18 width rule. A code point noctty gives
    // another width than the bundled ConPTY moves noctty's cursor to another
    // column than ConPTY's, and ConPTY draws from its own buffer. The table
    // is the probe's measurement of the pinned OpenConsole; its 990 unicode18
    // rows are pinned in src/build/uucode_config.zig (conpty_width_pins).
    const std = @import("std");
    const testing = std.testing;
    const uucode = @import("uucode");
    const tsv = @embedFile("testdata/conpty_width.tsv");

    var unicode18: usize = 0;
    try testing.expectEqual(@as(usize, 0), try conptyWidthMismatches(tsv, &codepointWidth, &unicode18));
    try testing.expectEqual(@as(usize, 990), unicode18);

    // Each unicode18 row is a pin against Unicode 18, which makes it Wide.
    var pinned: usize = 0;
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.endsWith(u8, line, "\tunicode18")) continue;
        const cp = try std.fmt.parseInt(u21, line[0..std.mem.findScalar(u8, line, '\t').?], 16);
        try testing.expectEqual(uucode.types.EastAsianWidth.wide, uucode.get(.east_asian_width, cp));
        pinned += 1;
    }
    try testing.expectEqual(@as(usize, 990), pinned);
}

test "unicode: the ConPTY width check reports a planted disagreement" {
    // The negative control of the test above: U+4E00 planted at width 1,
    // which noctty gives 2, is the one row reported.
    const testing = @import("std").testing;
    var unicode18: usize = 0;
    const planted = "# planted\n0041\t1\tcontrol\n4E00\t1\tcontrol\n1F6D9\t1\tunicode18\n";
    try testing.expectEqual(@as(usize, 1), try conptyWidthMismatches(planted, &codepointWidth, &unicode18));
    try testing.expectEqual(@as(usize, 1), unicode18);
    try testing.expectError(error.BadRow, conptyWidthMismatches("0041\t1\n", &codepointWidth, &unicode18));
}

test {
    @import("std").testing.refAllDecls(@This());
}
