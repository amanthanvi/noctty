//! Allocation-free universal palette query parsing and ranking.
//!
//! Catalog strings are borrowed and results are written into caller-owned
//! storage. Ranking uses integers and stable identifiers so identical catalog
//! state and queries always produce identical ordering.

const std = @import("std");

pub const Kind = enum(u8) {
    action,
    tab,
    pane,
    profile,
    setting,
    theme,
    help,
    recent_command,
};

pub const StableId = struct {
    kind: Kind,
    value: u64,

    pub fn eql(self: StableId, other: StableId) bool {
        return self.kind == other.kind and self.value == other.value;
    }
};

pub const Shortcut = struct {
    /// Display-ready chord or sequence, for example `Ctrl+Shift+P`.
    label: []const u8,
    /// Number of chords in the sequence. Zero is not a valid shortcut.
    chord_count: u8 = 1,
    is_default: bool = false,
};

pub const Recency = struct {
    /// Zero is most recent. Null means the item has not been used.
    mru_rank: ?u16 = null,
    use_count: u32 = 0,
};

pub const Item = struct {
    id: StableId,
    title: []const u8,
    subtitle: []const u8 = "",
    /// Search-only aliases separated by ASCII whitespace.
    keywords: []const u8 = "",
    enabled: bool = true,
    disabled_reason: ?[]const u8 = null,
    destructive: bool = false,
    shortcut: ?Shortcut = null,
    recency: Recency = .{},
};

pub const Prefix = struct {
    value: u8,
    kind: Kind,
    label: []const u8,
};

pub const prefixes = [_]Prefix{
    .{ .value = '>', .kind = .action, .label = "Actions" },
    .{ .value = '@', .kind = .tab, .label = "Tabs" },
    .{ .value = '/', .kind = .pane, .label = "Panes" },
    .{ .value = '~', .kind = .profile, .label = "Profiles" },
    .{ .value = ':', .kind = .setting, .label = "Settings" },
    .{ .value = '%', .kind = .theme, .label = "Themes" },
    .{ .value = '?', .kind = .help, .label = "Help" },
    .{ .value = '!', .kind = .recent_command, .label = "Recent commands" },
};

pub fn prefixFor(kind: Kind) u8 {
    for (prefixes) |prefix| if (prefix.kind == kind) return prefix.value;
    unreachable;
}

pub const ParsedQuery = struct {
    filter: ?Kind,
    text: []const u8,
};

/// A leading category prefix may be adjacent to the query (`@build`) or
/// separated by whitespace (`@ build`). Returned text borrows from `raw`.
pub fn parseQuery(raw: []const u8) ParsedQuery {
    var text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return .{ .filter = null, .text = text };
    for (prefixes) |prefix| {
        if (text[0] == prefix.value) {
            text = std.mem.trimLeft(u8, text[1..], " \t");
            return .{ .filter = prefix.kind, .text = text };
        }
    }
    return .{ .filter = null, .text = text };
}

pub const Options = struct {
    /// Used when the query has no prefix. A query prefix takes precedence.
    filter: ?Kind = null,
    include_disabled: bool = true,
    max_results: usize = 64,
};

pub const Ranked = struct {
    index: usize,
    id: StableId,
    score: i64,
    enabled: bool,
};

pub const max_tokens: usize = 8;

/// Rank a blended catalog into caller-owned storage. The returned slice never
/// exceeds `options.max_results` or `buffer.len`. Empty queries show the
/// catalog ordered by bounded recency and stable ID.
pub fn rank(
    items: []const Item,
    raw_query: []const u8,
    options: Options,
    buffer: []Ranked,
) []Ranked {
    const parsed = parseQuery(raw_query);
    const filter = parsed.filter orelse options.filter;
    const limit = @min(buffer.len, options.max_results);
    if (limit == 0) return buffer[0..0];

    var token_buffer: [max_tokens][]const u8 = undefined;
    const tokenized = tokenize(parsed.text, &token_buffer);
    if (tokenized.overflow) return buffer[0..0];
    const tokens = tokenized.items;
    var count: usize = 0;
    var worst: usize = 0;

    for (items, 0..) |item, index| {
        if (filter) |kind| if (item.id.kind != kind) continue;
        if (!options.include_disabled and !item.enabled) continue;
        const score = scoreItem(item, parsed.text, tokens) orelse continue;
        const candidate: Ranked = .{
            .index = index,
            .id = item.id,
            .score = score,
            .enabled = item.enabled,
        };

        if (count < limit) {
            buffer[count] = candidate;
            if (count == 0 or better(buffer[worst], candidate)) worst = count;
            count += 1;
            continue;
        }
        if (!better(candidate, buffer[worst])) continue;
        buffer[worst] = candidate;
        worst = findWorst(buffer[0..count]);
    }

    const result = buffer[0..count];
    std.mem.sort(Ranked, result, {}, struct {
        fn lessThan(_: void, a: Ranked, b: Ranked) bool {
            return better(a, b);
        }
    }.lessThan);
    return result;
}

const Tokenized = struct {
    items: []const []const u8,
    overflow: bool,
};

fn tokenize(query: []const u8, buffer: *[max_tokens][]const u8) Tokenized {
    var count: usize = 0;
    var iterator = std.mem.tokenizeAny(u8, query, " \t");
    while (iterator.next()) |token| {
        if (count == buffer.len) {
            return .{ .items = buffer, .overflow = true };
        }
        buffer[count] = token;
        count += 1;
    }
    return .{ .items = buffer[0..count], .overflow = false };
}

fn scoreItem(item: Item, query: []const u8, tokens: []const []const u8) ?i64 {
    var score = recencyScore(item.recency);
    if (!item.enabled) score -= 2_000;
    if (tokens.len == 0) return score;

    if (eqlIgnoreCase(item.title, query)) score += 150_000;
    for (tokens) |token| {
        var best_score: ?i32 = fuzzyScore(item.title, token);
        if (fuzzyScore(item.keywords, token)) |keyword_score| {
            const adjusted = keyword_score - 1_000;
            if (best_score == null or adjusted > best_score.?) best_score = adjusted;
        }
        if (fuzzyScore(item.subtitle, token)) |subtitle_score| {
            const adjusted = subtitle_score - 3_000;
            if (best_score == null or adjusted > best_score.?) best_score = adjusted;
        }
        score += best_score orelse return null;
    }
    return score;
}

fn recencyScore(recency: Recency) i64 {
    var score: i64 = @min(recency.use_count, 100);
    if (recency.mru_rank) |rank_value| {
        const bounded: i64 = @min(rank_value, 100);
        // One MRU position outweighs the entire bounded frequency bonus.
        score += (100 - bounded) * 128 + 1_000;
    }
    return score;
}

/// Deterministic ASCII fuzzy score. Exact, prefix, word-prefix, substring,
/// then ordered-subsequence matches receive progressively lower scores.
fn fuzzyScore(haystack: []const u8, needle: []const u8) ?i32 {
    if (needle.len == 0) return 0;
    if (eqlIgnoreCase(haystack, needle)) return 120_000;
    if (startsWithIgnoreCase(haystack, needle)) {
        return 105_000 - @as(i32, @intCast(@min(haystack.len - needle.len, 4_000)));
    }

    if (findIgnoreCase(haystack, needle)) |position| {
        const boundary_bonus: i32 = if (position == 0 or isBoundary(haystack[position - 1])) 10_000 else 0;
        return 80_000 + boundary_bonus - @as(i32, @intCast(@min(position, 4_000)));
    }

    var haystack_index: usize = 0;
    var previous_match: ?usize = null;
    var score: i32 = 45_000;
    for (needle) |needle_char| {
        var found: ?usize = null;
        while (haystack_index < haystack.len) : (haystack_index += 1) {
            if (lower(haystack[haystack_index]) == lower(needle_char)) {
                found = haystack_index;
                haystack_index += 1;
                break;
            }
        }
        const position = found orelse return null;
        if (previous_match) |previous| {
            if (position == previous + 1) {
                score += 1_000;
            } else {
                score -= @as(i32, @intCast(@min(position - previous - 1, 1_000))) * 50;
            }
        }
        if (position == 0 or isBoundary(haystack[position - 1])) score += 500;
        previous_match = position;
    }
    score -= @as(i32, @intCast(@min(haystack.len, 4_000)));
    return score;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return a.len == b.len and startsWithIgnoreCase(a, b);
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (haystack[0..needle.len], needle) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
}

fn findIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (startsWithIgnoreCase(haystack[index..], needle)) return index;
    }
    return null;
}

fn lower(value: u8) u8 {
    return if (value >= 'A' and value <= 'Z') value + ('a' - 'A') else value;
}

fn isBoundary(value: u8) bool {
    return value == ' ' or value == '\t' or value == '-' or value == '_' or value == '/' or value == '\\';
}

fn better(a: Ranked, b: Ranked) bool {
    if (a.enabled != b.enabled) return a.enabled;
    if (a.score != b.score) return a.score > b.score;
    if (a.id.kind != b.id.kind) return @intFromEnum(a.id.kind) < @intFromEnum(b.id.kind);
    if (a.id.value != b.id.value) return a.id.value < b.id.value;
    return a.index < b.index;
}

fn findWorst(items: []const Ranked) usize {
    var worst: usize = 0;
    for (items[1..], 1..) |item, index| {
        if (better(items[worst], item)) worst = index;
    }
    return worst;
}

const test_items = [_]Item{
    .{
        .id = .{ .kind = .action, .value = 10 },
        .title = "New Tab",
        .subtitle = "Open another terminal tab",
        .keywords = "create terminal",
        .shortcut = .{ .label = "Ctrl+Shift+T", .is_default = true },
    },
    .{
        .id = .{ .kind = .tab, .value = 20 },
        .title = "Build server",
        .subtitle = "PowerShell",
        .recency = .{ .mru_rank = 1, .use_count = 8 },
    },
    .{
        .id = .{ .kind = .pane, .value = 30 },
        .title = "API logs",
        .subtitle = "WSL Ubuntu",
    },
    .{
        .id = .{ .kind = .profile, .value = 40 },
        .title = "Ubuntu",
        .keywords = "wsl linux",
    },
    .{
        .id = .{ .kind = .setting, .value = 50 },
        .title = "Clipboard protection",
        .subtitle = "Privacy",
        .enabled = false,
        .disabled_reason = "Managed by policy",
    },
    .{
        .id = .{ .kind = .theme, .value = 60 },
        .title = "Noctty Dark",
        .keywords = "appearance color",
    },
    .{
        .id = .{ .kind = .recent_command, .value = 70 },
        .title = "zig build test",
        .subtitle = "Recent command",
        .destructive = false,
        .recency = .{ .mru_rank = 0, .use_count = 3 },
    },
};

test "category prefixes parse adjacent and spaced queries" {
    const adjacent = parseQuery("  @build  ");
    try std.testing.expectEqual(Kind.tab, adjacent.filter.?);
    try std.testing.expectEqualStrings("build", adjacent.text);

    const spaced = parseQuery(":  clipboard");
    try std.testing.expectEqual(Kind.setting, spaced.filter.?);
    try std.testing.expectEqualStrings("clipboard", spaced.text);
    try std.testing.expectEqual(@as(u8, '!'), prefixFor(.recent_command));
}

test "blended fuzzy ranking searches every result kind" {
    var storage: [16]Ranked = undefined;
    const results = rank(&test_items, "wsl", .{}, &storage);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqual(Kind.profile, results[0].id.kind);
    try std.testing.expectEqual(Kind.pane, results[1].id.kind);
    try std.testing.expectEqual(Kind.tab, results[2].id.kind);
}

test "category filter and disabled metadata are preserved" {
    var storage: [8]Ranked = undefined;
    const results = rank(&test_items, ":clip", .{}, &storage);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    const item = test_items[results[0].index];
    try std.testing.expectEqual(Kind.setting, item.id.kind);
    try std.testing.expect(!item.enabled);
    try std.testing.expectEqualStrings("Managed by policy", item.disabled_reason.?);

    const excluded = rank(&test_items, ":clip", .{ .include_disabled = false }, &storage);
    try std.testing.expectEqual(@as(usize, 0), excluded.len);
}

test "empty query uses bounded MRU scoring" {
    var storage: [16]Ranked = undefined;
    const results = rank(&test_items, "", .{}, &storage);
    try std.testing.expectEqual(test_items.len, results.len);
    try std.testing.expectEqual(Kind.recent_command, results[0].id.kind);
    try std.testing.expectEqual(Kind.tab, results[1].id.kind);
}

test "exact title outranks recency and exposes shortcut metadata" {
    var storage: [16]Ranked = undefined;
    const results = rank(&test_items, "new tab", .{}, &storage);
    try std.testing.expect(results.len >= 1);
    const top = test_items[results[0].index];
    try std.testing.expectEqual(Kind.action, top.id.kind);
    try std.testing.expectEqualStrings("Ctrl+Shift+T", top.shortcut.?.label);
    try std.testing.expect(top.shortcut.?.is_default);
}

test "stable IDs make tie order independent of catalog order" {
    const first = [_]Item{
        .{ .id = .{ .kind = .theme, .value = 9 }, .title = "Dark" },
        .{ .id = .{ .kind = .theme, .value = 2 }, .title = "Dark" },
    };
    const reversed = [_]Item{ first[1], first[0] };
    var a_storage: [2]Ranked = undefined;
    var b_storage: [2]Ranked = undefined;
    const a = rank(&first, "dark", .{}, &a_storage);
    const b = rank(&reversed, "dark", .{}, &b_storage);
    try std.testing.expectEqual(@as(u64, 2), a[0].id.value);
    try std.testing.expectEqual(a[0].id.value, b[0].id.value);
    try std.testing.expectEqual(a[1].id.value, b[1].id.value);
}

test "result cap keeps the globally best entries" {
    const items = [_]Item{
        .{ .id = .{ .kind = .action, .value = 1 }, .title = "xylophone action" },
        .{ .id = .{ .kind = .tab, .value = 2 }, .title = "xylophone tab" },
        .{ .id = .{ .kind = .pane, .value = 3 }, .title = "xylophone" },
    };
    var storage: [2]Ranked = undefined;
    const results = rank(&items, "xylophone", .{ .max_results = 2 }, &storage);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u64, 3), results[0].id.value);
}

test "all query tokens must match" {
    var storage: [16]Ranked = undefined;
    try std.testing.expectEqual(@as(usize, 1), rank(&test_items, "build powershell", .{}, &storage).len);
    try std.testing.expectEqual(@as(usize, 0), rank(&test_items, "build impossible", .{}, &storage).len);
}

test "queries over the token bound fail closed" {
    const items = [_]Item{.{
        .id = .{ .kind = .action, .value = 1 },
        .title = "one two three four five six seven eight nine",
    }};
    var storage: [2]Ranked = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        rank(&items, "one two three four five six seven eight nine", .{}, &storage).len,
    );
}

test "enabled results always precede disabled matches" {
    const items = [_]Item{
        .{
            .id = .{ .kind = .action, .value = 1 },
            .title = "Build",
            .enabled = false,
            .disabled_reason = "Unavailable",
            .recency = .{ .mru_rank = 0, .use_count = 100 },
        },
        .{
            .id = .{ .kind = .action, .value = 2 },
            .title = "Build",
        },
    };
    var storage: [2]Ranked = undefined;
    const results = rank(&items, "build", .{}, &storage);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].enabled);
    try std.testing.expectEqual(@as(u64, 2), results[0].id.value);
}
