const std = @import("std");
const assert = std.debug.assert;
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "width", .type = u2 },
    .{ .name = "is_symbol", .type = bool },
});
pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{
        .Impl = WidthComponent,
        .inputs = &.{
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
            "is_emoji_modifier",
            "grapheme_break_no_control",
        },
        .fields = &.{"width"},
    },
    .{
        .Impl = IsSymbolComponent,
        .inputs = &.{ "block", "general_category" },
        .fields = &.{"is_symbol"},
    },
});

pub const get_components: []const config.Component = &.{};

pub const tables = [_]config.Table{
    .{
        .name = "runtime",
        .fields = &.{
            "is_emoji_presentation",
            "case_folding_full",
        },
    },
    .{
        // Fields that libvaxis needs that aren't included in the `runtime`
        // table.
        .name = "libvaxis_only",
        .fields = &.{
            "east_asian_width",
            "general_category",
            "grapheme_break",
        },
    },
    .{
        .name = "buildtime",
        // Unpacked, because a packed table this size cannot be evaluated
        // at comptime by Zig 0.16.0 and this one has to be, whether or not
        // anything reads it.
        //
        // `uucode.get.FieldEnum` is built by walking `@TypeOf(tables)`, so
        // instantiating anything that names a field -- `grapheme.Iterator`,
        // among others -- materialises every table including this one. In a
        // packed layout its rows are a `@bitCast` of a 32000 element `[_]u10`,
        // and the compiler gives up on it two different ways depending on
        // build options:
        //
        //     tables.zig: error: unable to evaluate comptime expression
        //     thread panic: TODO implement writeToPackedMemory for more types
        //
        // Ghostty does not hit this, because its own uses of these fields go
        // through the tables generated at build time rather than through
        // `uucode.get`. A downstream pairing this config with libvaxis does:
        // vaxis measures grapheme widths with `grapheme.Iterator`, so any
        // program calling `Vaxis.render` fails to compile.
        //
        // The cost is the size of a table nothing reads at runtime. The fix
        // belongs upstream in uucode or in the compiler; this is what makes
        // the pairing build today.
        .packing = .unpacked,
        .fields = &.{
            "width",
            "wcwidth_zero_in_grapheme",
            "grapheme_break_no_control",
            "is_symbol",
            "is_emoji_vs_base",
        },
    },
};

const WidthComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;

        rows.len = config.num_code_points;
        const items = rows.items(.width);
        const standalone = inputs.items(.wcwidth_standalone);
        const zero_in_grapheme = inputs.items(.wcwidth_zero_in_grapheme);
        const is_emoji_modifier = inputs.items(.is_emoji_modifier);
        const grapheme_break_no_control = inputs.items(.grapheme_break_no_control);

        // This condition is needed as Ghostty currently has a singular concept for
        // the `width` of a code point, while `uucode` splits the concept into
        // `wcwidth_standalone` and `wcwidth_zero_in_grapheme`. The two cases where
        // we want to use the `wcwidth_standalone` despite the code point occupying
        // zero width in a grapheme (`wcwidth_zero_in_grapheme`) are emoji
        // modifiers and prepend code points. For emoji modifiers we want to
        // support displaying them in isolation as color patches, and if prepend
        // characters were to be width 0 they would disappear from the output with
        // Ghostty's current width 0 handling. Future work will take advantage of
        // the new uucode `wcwidth_standalone` vs `wcwidth_zero_in_grapheme` split.
        for (0..config.num_code_points) |i| {
            if (zero_in_grapheme[i] and !is_emoji_modifier[i] and grapheme_break_no_control[i] != .prepend) {
                items[i] = 0;
            } else {
                items[i] = @min(2, standalone[i]);
            }
        }

        for (conpty_width_pins) |pin| {
            for (pin.first..@as(usize, pin.last) + 1) |cp| items[cp] = pin.width;
        }
    }
};

/// Code points whose width is pinned to the width the bundled ConPTY gives
/// them, so that noctty's cursor stays where ConPTY's is (PLAN.md 7.7, the
/// Unicode 18 width rule). Unicode 18 made these 990 newly assigned code
/// points East Asian Wide (they were Neutral while unassigned in Unicode 17),
/// and the bundled OpenConsole 1.24.260710001 (`dist/windows/conpty-redist.json`)
/// does not know them yet: `test/windows/hidden-win11-conpty-width.ps1`
/// measured each at 1 column in its screen buffer, with glyph width flags 0
/// (noctty's default) and 0x10 (`grapheme-width-method = legacy`), VT
/// processing on and off. Unpinned, the cursor drifts a column after each one.
///
/// Each range holds only code points the probe measured at `width`; the probe's
/// table is `src/unicode/testdata/conpty_width.tsv`, and the test "unicode:
/// widths match the bundled ConPTY's measured widths" (`src/unicode/main.zig`)
/// asserts it against the table noctty compiles in. Remove a range only when
/// a re-run against a newer bundled ConPTY measures the Unicode width there
/// (`docs/agents/log/conpty.md`, the 2026-11-26 CONPTY-WIDTH-18 entry).
const conpty_width_pins = [_]WidthPin{
    // Khitan Small Script additions.
    .{ .first = 0x18CD6, .last = 0x18CDA, .width = 1 },
    // Tangut Supplement additions.
    .{ .first = 0x18D1F, .last = 0x18D20, .width = 1 },
    // Jurchen, and Jurchen Radicals.
    .{ .first = 0x18E00, .last = 0x19191, .width = 1 },
    .{ .first = 0x191A0, .last = 0x191D2, .width = 1 },
    // Kana Extended-A and Small Kana Extension additions.
    .{ .first = 0x1B123, .last = 0x1B128, .width = 1 },
    .{ .first = 0x1B168, .last = 0x1B168, .width = 1 },
    // The emoji blocks: U+1F1AE and U+1F7DA, and nine with
    // Emoji_Presentation (U+1F6D9, U+1FA8B..U+1FA8D, U+1FACC, U+1FADD,
    // U+1FAEB, U+1FAF9..U+1FAFA).
    .{ .first = 0x1F1AE, .last = 0x1F1AE, .width = 1 },
    .{ .first = 0x1F6D9, .last = 0x1F6D9, .width = 1 },
    .{ .first = 0x1F7DA, .last = 0x1F7DA, .width = 1 },
    .{ .first = 0x1FA8B, .last = 0x1FA8D, .width = 1 },
    .{ .first = 0x1FACC, .last = 0x1FACC, .width = 1 },
    .{ .first = 0x1FADD, .last = 0x1FADD, .width = 1 },
    .{ .first = 0x1FAEB, .last = 0x1FAEB, .width = 1 },
    .{ .first = 0x1FAF9, .last = 0x1FAFA, .width = 1 },
};

const WidthPin = struct { first: u21, last: u21, width: u2 };

const IsSymbolComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;

        rows.len = config.num_code_points;
        const items = rows.items(.is_symbol);
        const block = inputs.items(.block);
        const general_category = inputs.items(.general_category);

        for (0..config.num_code_points) |i| {
            items[i] =
                general_category[i] == .other_private_use or
                block[i] == .arrows or
                block[i] == .dingbats or
                block[i] == .emoticons or
                block[i] == .miscellaneous_symbols or
                block[i] == .enclosed_alphanumerics or
                block[i] == .enclosed_alphanumeric_supplement or
                block[i] == .miscellaneous_symbols_and_pictographs or
                block[i] == .transport_and_map_symbols;
        }
    }
};
