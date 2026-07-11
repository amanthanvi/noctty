//! Command palette ranking primitives.
//!
//! Pure, Win32-free: `std`, `zf`, and the command catalog. Shared between
//! the Win32 apprt (live palette) and the `bench/palette_match.zig`
//! microbench so both exercise the same scoring path.

const std = @import("std");
const zf = @import("zf");
const command = @import("../input/command.zig");

/// Universal catalog adapter. Existing action-only APIs below remain stable
/// while the Win32 host migrates providers onto this shared production path.
pub const catalog = @import("win32_palette_catalog.zig");

/// Non-owning view over the palette's command + cval lists.
pub const Snapshot = struct {
    commands: []const command.Command,
    cvals: []const command.Command.C,

    pub fn fromDefaults() Snapshot {
        return .{
            .commands = command.defaults,
            .cvals = command.defaultsC,
        };
    }
};

pub const RankedIndex = struct {
    index: usize,
    rank: f64,
};

pub const max_tokens: usize = 8;
pub const max_ranked: usize = 256;

/// Tokenize on ASCII whitespace into a caller-supplied buffer; returns
/// a subslice. Tokens borrow from `query`.
pub fn tokenizeQuery(
    query: []const u8,
    buf: *[max_tokens][]const u8,
) []const []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t");
    while (it.next()) |tok| {
        if (n >= buf.len) break;
        buf[n] = tok;
        n += 1;
    }
    return buf[0..n];
}

/// Rank one entry against tokens. Scores title and action; picks the
/// better (lower) rank. Null = at least one token missed both haystacks.
pub fn rankEntry(
    cmd: command.Command,
    c: command.Command.C,
    tokens: []const []const u8,
) ?f64 {
    const opts: zf.RankOptions = .{ .to_lower = true, .plain = true };
    const title_r = zf.rank(cmd.title, tokens, opts);
    const action_r = zf.rank(std.mem.span(c.action), tokens, opts);
    if (title_r) |t| {
        if (action_r) |a| return @min(t, a);
        return t;
    }
    return action_r;
}

/// Rank every entry in `snap` against `query`; emit the top `max_ranked`
/// by rank into `buf`, sorted best-first (ties broken by original index
/// for stable cycling). Returns a subslice of `buf`. Empty query →
/// empty slice.
///
/// Scans the full snapshot before truncating — callers with palettes
/// larger than `max_ranked` entries still see the true best matches,
/// not the first N that happened to match. Cost: O(N·K) in the
/// pathological case where every entry beats the current worst, which
/// stays sub-millisecond at realistic palette sizes.
pub fn rankedForQuery(
    snap: Snapshot,
    query: []const u8,
    buf: *[max_ranked]RankedIndex,
) []RankedIndex {
    var token_buf: [max_tokens][]const u8 = undefined;
    const tokens = tokenizeQuery(query, &token_buf);
    if (tokens.len == 0) return buf[0..0];

    var count: usize = 0;
    var worst_i: usize = 0; // index within buf of the worst (highest) rank
    for (snap.commands, snap.cvals, 0..) |cmd, c, i| {
        const r = rankEntry(cmd, c, tokens) orelse continue;
        if (count < buf.len) {
            buf[count] = .{ .index = i, .rank = r };
            if (count == 0 or r > buf[worst_i].rank) worst_i = count;
            count += 1;
            continue;
        }
        // Buffer full — only keep this entry if it beats the worst.
        if (r >= buf[worst_i].rank) continue;
        buf[worst_i] = .{ .index = i, .rank = r };
        // Recompute worst slot (O(K) but K=256 is cheap).
        worst_i = 0;
        var j: usize = 1;
        while (j < buf.len) : (j += 1) {
            if (buf[j].rank > buf[worst_i].rank) worst_i = j;
        }
    }
    const slice = buf[0..count];
    std.mem.sort(RankedIndex, slice, {}, struct {
        fn lt(_: void, a: RankedIndex, b: RankedIndex) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return a.index < b.index;
        }
    }.lt);
    return slice;
}

/// Number of entries that match `query`. Empty query returns the full
/// catalogue size — the paint-path short-circuits on empty input, so
/// this count is never surfaced in the UI.
pub fn matchCount(snap: Snapshot, query: []const u8) usize {
    var buf: [max_tokens][]const u8 = undefined;
    const tokens = tokenizeQuery(query, &buf);
    if (tokens.len == 0) return snap.cvals.len;
    var count: usize = 0;
    for (snap.commands, snap.cvals) |cmd, c| {
        if (rankEntry(cmd, c, tokens) != null) count += 1;
    }
    return count;
}

test "matchCount on real defaults" {
    const snap = Snapshot.fromDefaults();
    try std.testing.expect(matchCount(snap, "toggle") > 0);
    try std.testing.expect(matchCount(snap, "definitely_not_real") == 0);
}

test "rankedForQuery returns ordered matches" {
    const snap = Snapshot.fromDefaults();
    var buf: [max_ranked]RankedIndex = undefined;
    const ranked = rankedForQuery(snap, "new_tab", &buf);
    try std.testing.expect(ranked.len > 0);
    // Top entry's action should contain the query substring somewhere.
    const top_action = std.mem.span(snap.cvals[ranked[0].index].action);
    try std.testing.expect(std.mem.indexOf(u8, top_action, "new_tab") != null);
    // Results sorted ascending by rank.
    var i: usize = 1;
    while (i < ranked.len) : (i += 1) {
        try std.testing.expect(ranked[i - 1].rank <= ranked[i].rank);
    }
}

test "empty query yields empty ranked slice" {
    const snap = Snapshot.fromDefaults();
    var buf: [max_ranked]RankedIndex = undefined;
    try std.testing.expectEqual(@as(usize, 0), rankedForQuery(snap, "", &buf).len);
    try std.testing.expectEqual(@as(usize, 0), rankedForQuery(snap, "   ", &buf).len);
}

test "default actions populate universal catalog with unique stable IDs" {
    var item_storage: [command.defaults.len]catalog.Item = undefined;
    var payload_storage: [command.defaults.len]catalog.Payload = undefined;
    var universal_catalog = try catalog.Catalog.init(&item_storage, &payload_storage);
    try universal_catalog.appendActionSnapshot(Snapshot.fromDefaults());
    try std.testing.expectEqual(command.defaults.len, universal_catalog.items().len);
    try std.testing.expect(universal_catalog.items().len > 0);
}

test {
    _ = catalog;
}
