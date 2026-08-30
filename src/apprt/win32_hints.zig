//! Pure quick-select scanning, labels, narrowing, and placement.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const config_url = @import("../config/url.zig");
const QuickSelectAlphabet = @import("../config/Config.zig").QuickSelectAlphabet;
const terminal = @import("../terminal/main.zig");
const point = terminal.point;

pub const default_alphabet = QuickSelectAlphabet.default;

// Units are Oniguruma retry steps, not elapsed time. Quick-select scans run on
// the UI thread, so custom patterns must have the same finite backtracking
// budget as terminal link searches.
const oni_search_retry_limit = 100_000;
const max_pattern_count = 64;
const max_pattern_bytes = 4096;
const max_searches_per_pattern = 4096;
const max_candidate_count = 4096;

const windows_drive_path =
    \\(?<![A-Za-z0-9_])[A-Za-z]:\\[^\x00\r\n<>:"|?*]+
;
const windows_unc_path =
    \\(?<![\\A-Za-z0-9_])\\\\[A-Za-z0-9._-]+\\[^\x00\r\n<>:"|?*]+
;
const git_sha =
    \\\b[0-9A-Fa-f]{7,40}\b
;
const ipv4 =
    \\\b(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\.){3}(?:25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})\b
;
const ipv6 =
    "(?<![0-9A-Fa-f:])(?:" ++
    "(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|" ++
    "(?:[0-9A-Fa-f]{1,4}:){1,7}:|" ++
    "(?:[0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|" ++
    "(?:[0-9A-Fa-f]{1,4}:){1,5}(?::[0-9A-Fa-f]{1,4}){1,2}|" ++
    "(?:[0-9A-Fa-f]{1,4}:){1,4}(?::[0-9A-Fa-f]{1,4}){1,3}|" ++
    "(?:[0-9A-Fa-f]{1,4}:){1,3}(?::[0-9A-Fa-f]{1,4}){1,4}|" ++
    "(?:[0-9A-Fa-f]{1,4}:){1,2}(?::[0-9A-Fa-f]{1,4}){1,5}|" ++
    "[0-9A-Fa-f]{1,4}:(?:(?::[0-9A-Fa-f]{1,4}){1,6})|" ++
    ":(?:(?::[0-9A-Fa-f]{1,4}){1,7}|:)" ++
    ")(?![0-9A-Fa-f:])";
const uuid =
    \\\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b
;

/// Built-in patterns used when `quick-select-patterns` is empty.
pub const default_patterns = [_][]const u8{
    config_url.regex,
    windows_drive_path,
    windows_unc_path,
    git_sha,
    ipv4,
    ipv6,
    uuid,
};

/// Schemes that match (and so can be labeled and copied) but must never be
/// handed to the system opener.
///
/// The open allowlist is deliberately narrower than the match allowlist.
/// `file:` reaches ShellExecute, so `file:///C:/…/evil.exe` rendered by a
/// hostile program would otherwise be two keystrokes from running. Matching it
/// is still useful — the label copies the path.
const non_openable_schemes = [_][]const u8{"file:"};

/// Compiled once: the scheme set is a compile-time constant and this runs on
/// the UI thread for every fired label.
var scheme_regex_once = std.once(initSchemeRegex);
var scheme_regex: ?oni.Regex = null;
var scheme_regex_err: ?anyerror = null;

fn initSchemeRegex() void {
    scheme_regex = oni.Regex.init(
        "\\A(?:" ++ config_url.url_schemes ++ ")",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    ) catch |err| {
        scheme_regex_err = err;
        return;
    };
}

/// Whether text begins with a scheme this build is willing to hand to the
/// system opener. This is the security boundary before native opening: it is
/// anchored, case-sensitive, and fails closed.
pub fn beginsWithAllowedScheme(text: []const u8) !bool {
    for (non_openable_schemes) |scheme| {
        if (std.mem.startsWith(u8, text, scheme)) return false;
    }

    scheme_regex_once.call();
    if (scheme_regex_err) |err| return err;
    const regex = if (scheme_regex) |*value| value else return error.RegexUnavailable;

    var region = regex.search(text, .{}) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    defer region.deinit();
    return region.starts()[0] == 0 and region.ends()[0] > 0;
}

pub const Match = struct {
    start: usize,
    end: usize,
    first: point.Coordinate,
    last: point.Coordinate,
};

/// What firing a label does with the matched text.
pub const Action = enum { copy, open, paste };

/// Resolve the action for a fired label. Ctrl asks to open and Alt asks to
/// paste; anything not openable degrades to a copy rather than being refused,
/// so a mistyped modifier never silently does nothing.
pub fn resolveAction(text: []const u8, ctrl: bool, alt: bool) Action {
    if (ctrl) {
        const openable = beginsWithAllowedScheme(text) catch |err| blk: {
            std.log.warn("quick select scheme validation failed err={}", .{err});
            break :blk false;
        };
        return if (openable) .open else .copy;
    }
    if (alt) return .paste;
    return .copy;
}

test "hints: ctrl falls back to copy for targets that cannot be opened" {
    const testing = std.testing;
    try oni.testing.ensureInit();

    // Ctrl opens only real, allowlisted URLs.
    try testing.expectEqual(Action.open, resolveAction("https://example.com", true, false));

    // Everything else Ctrl is pressed on degrades to copy, never to open.
    try testing.expectEqual(Action.copy, resolveAction("C:\\work\\notes.txt", true, false));
    try testing.expectEqual(Action.copy, resolveAction("\\\\server\\share\\x", true, false));
    try testing.expectEqual(Action.copy, resolveAction("deadbeef", true, false));
    try testing.expectEqual(Action.copy, resolveAction("file:///C:/evil.exe", true, false));

    // Alt pastes; Ctrl wins over Alt so a chord cannot both open and paste.
    try testing.expectEqual(Action.paste, resolveAction("deadbeef", false, true));
    try testing.expectEqual(Action.open, resolveAction("https://example.com", true, true));
    try testing.expectEqual(Action.copy, resolveAction("file:///C:/evil.exe", true, true));

    // No modifier always copies.
    try testing.expectEqual(Action.copy, resolveAction("https://example.com", false, false));
}

fn coordEql(lhs: point.Coordinate, rhs: point.Coordinate) bool {
    return lhs.x == rhs.x and lhs.y == rhs.y;
}

/// The text currently occupying the cell span `first..last`, or null if that
/// span is no longer present. The coordinate map is in reading order, so the
/// bytes covering a cell span are contiguous.
pub fn spanText(
    text: []const u8,
    map: []const point.Coordinate,
    first: point.Coordinate,
    last: point.Coordinate,
) ?[]const u8 {
    const limit = @min(text.len, map.len);
    var start: ?usize = null;
    for (map[0..limit], 0..) |coord, i| {
        if (coordEql(coord, first)) {
            start = i;
            break;
        }
    }
    const begin = start orelse return null;

    var end: ?usize = null;
    var i: usize = limit;
    while (i > begin) {
        i -= 1;
        if (coordEql(map[i], last)) {
            end = i + 1;
            break;
        }
    }
    const finish = end orelse return null;
    return text[begin..finish];
}

/// Build the stable accessible name for one visible quick-select target.
/// The label is announced before the matched text so keyboard users hear the
/// key they can type before potentially long terminal content.
pub fn accessibleTargetName(
    buf: []u8,
    index: usize,
    count: usize,
    label: []const u8,
    text: []const u8,
) []const u8 {
    return std.fmt.bufPrint(
        buf,
        "Target {d} of {d}, label {s}, {s}",
        .{ index + 1, count, label, text },
    ) catch "Quick select target";
}

/// One immutable visible-viewport scan. Match text borrows from `text`.
pub const Scan = struct {
    text: []u8,
    map: []point.Coordinate,
    matches: []Match,

    pub fn deinit(self: *Scan, alloc: Allocator) void {
        alloc.free(self.matches);
        alloc.free(self.map);
        alloc.free(self.text);
        self.* = undefined;
    }

    pub fn matchText(self: *const Scan, index: usize) []const u8 {
        const matched = self.matches[index];
        return self.text[matched.start..matched.end];
    }
};

const Candidate = struct {
    start: usize,
    end: usize,
    pattern_index: usize,

    fn len(self: Candidate) usize {
        return self.end - self.start;
    }
};

/// The scan text for a render state, paired with its byte-to-cell map.
pub const RenderText = struct {
    text: []u8,
    map: []point.Coordinate,

    pub fn deinit(self: *RenderText, alloc: Allocator) void {
        alloc.free(self.map);
        alloc.free(self.text);
        self.* = undefined;
    }
};

/// Whether the cell at `coord` only exists to reserve room for a wide
/// character that lives in a neighbouring cell.
fn isWideSpacerCell(
    render_state: *const terminal.RenderState,
    coord: point.Coordinate,
) bool {
    const rows = render_state.row_data.slice();
    if (coord.y >= rows.len) return false;
    const cells = rows.items(.cells)[coord.y].slice();
    if (coord.x >= cells.len) return false;
    return switch (cells.items(.raw)[coord.x].wide) {
        .spacer_tail, .spacer_head => true,
        .narrow, .wide => false,
    };
}

/// Build the scan text and byte-to-cell map for one render state.
///
/// `RenderState.string` emits `\x00` for every cell that carries no codepoint.
/// For a genuinely blank cell that NUL is the right separator — the built-in
/// path patterns all exclude `\x00`, so a match stops at the end of the text.
/// The spacer cells that flank a wide character are not blanks though: they are
/// part of the character next to them. Left in, they split every wide character
/// in two, so `C:\用户\文档` would be labeled and copied as `C:\用`. Drop the
/// spacer bytes and their map entries; blank cells keep theirs.
pub fn renderStateText(
    alloc: Allocator,
    render_state: *const terminal.RenderState,
) !RenderText {
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();
    var raw_map: terminal.RenderState.StringMap = .empty;
    defer raw_map.deinit(alloc);
    try render_state.string(&builder.writer, .{
        .alloc = alloc,
        .map = &raw_map,
    });

    const raw_text = builder.writer.buffered();
    const limit = @min(raw_text.len, raw_map.items.len);

    var text = try alloc.alloc(u8, limit);
    errdefer alloc.free(text);
    var map = try alloc.alloc(point.Coordinate, limit);
    errdefer alloc.free(map);

    var len: usize = 0;
    for (raw_text[0..limit], raw_map.items[0..limit]) |byte, coord| {
        if (byte == 0 and isWideSpacerCell(render_state, coord)) continue;
        text[len] = byte;
        map[len] = coord;
        len += 1;
    }

    return .{
        .text = try alloc.realloc(text, len),
        .map = try alloc.realloc(map, len),
    };
}

/// Scan one already-snapshotted visible render state. The render-state string
/// and byte-to-cell map are retained so no terminal access is needed while the
/// overlay is open.
pub fn scanRenderState(
    alloc: Allocator,
    render_state: *const terminal.RenderState,
    patterns: []const []const u8,
) !Scan {
    var rendered = try renderStateText(alloc, render_state);
    errdefer rendered.deinit(alloc);

    const matches = try extractMatches(alloc, rendered.text, rendered.map, patterns);
    errdefer alloc.free(matches);

    return .{
        .text = rendered.text,
        .map = rendered.map,
        .matches = matches,
    };
}

/// Extract regex matches from a render-state `(string, coordinate map)` pair.
pub fn extractMatches(
    alloc: Allocator,
    text: []const u8,
    map: []const point.Coordinate,
    patterns: []const []const u8,
) ![]Match {
    if (text.len == 0 or patterns.len == 0) return try alloc.alloc(Match, 0);
    if (map.len < text.len) return error.InvalidCoordinateMap;

    var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
    defer candidates.deinit(alloc);

    pattern_loop: for (patterns[0..@min(patterns.len, max_pattern_count)], 0..) |pattern, pattern_index| {
        if (pattern.len == 0 or pattern.len > max_pattern_bytes) continue;
        var regex = try oni.Regex.init(
            pattern,
            .{},
            oni.Encoding.utf8,
            oni.Syntax.default,
            null,
        );
        defer regex.deinit();
        var match_param = try oni.MatchParam.init();
        defer match_param.deinit();
        try match_param.setRetryLimitInSearch(oni_search_retry_limit);

        var offset: usize = 0;
        var search_count: usize = 0;
        while (offset < text.len and search_count < max_searches_per_pattern) {
            if (candidates.items.len >= max_candidate_count) break :pattern_loop;
            search_count += 1;
            var region = regex.searchWithParam(text[offset..], .{}, &match_param) catch |err| switch (err) {
                error.Mismatch,
                error.RetryLimitInMatchOver,
                error.RetryLimitInSearchOver,
                error.MatchStackLimitOver,
                error.SubexpCallLimitInSearchOver,
                => break,
                else => return err,
            };
            defer region.deinit();

            const relative_start: usize = @intCast(region.starts()[0]);
            const relative_end: usize = @intCast(region.ends()[0]);
            const start = offset + relative_start;
            const end = offset + relative_end;
            if (end > start) {
                try candidates.append(alloc, .{
                    .start = start,
                    .end = end,
                    .pattern_index = pattern_index,
                });
            }

            // Custom patterns may match an empty string. Always advance so a
            // malformed-but-valid regex cannot hang overlay creation.
            offset = if (end > offset) end else offset + 1;
        }
    }

    return resolveCandidates(alloc, candidates.items, map);
}

fn candidatePriority(_: void, lhs: Candidate, rhs: Candidate) bool {
    if (lhs.len() != rhs.len()) return lhs.len() > rhs.len();
    if (lhs.start != rhs.start) return lhs.start < rhs.start;
    if (lhs.end != rhs.end) return lhs.end < rhs.end;
    return lhs.pattern_index < rhs.pattern_index;
}

fn candidateReadingOrder(_: void, lhs: Candidate, rhs: Candidate) bool {
    if (lhs.start != rhs.start) return lhs.start < rhs.start;
    if (lhs.end != rhs.end) return lhs.end < rhs.end;
    return lhs.pattern_index < rhs.pattern_index;
}

fn coordinateKey(coord: point.Coordinate) u64 {
    return (@as(u64, coord.y) << 16) | @as(u64, coord.x);
}

fn resolveCandidates(
    alloc: Allocator,
    candidates_: []const Candidate,
    map: []const point.Coordinate,
) ![]Match {
    const candidates = try alloc.dupe(Candidate, candidates_);
    defer alloc.free(candidates);
    std.mem.sortUnstable(Candidate, candidates, {}, candidatePriority);

    var accepted: std.ArrayListUnmanaged(Candidate) = .empty;
    defer accepted.deinit(alloc);
    var used_cells: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer used_cells.deinit(alloc);

    for (candidates) |candidate| {
        if (candidate.end > map.len or candidate.end <= candidate.start) continue;
        for (map[candidate.start..candidate.end]) |coord| {
            if (used_cells.contains(coordinateKey(coord))) break;
        } else {
            try accepted.append(alloc, candidate);
            for (map[candidate.start..candidate.end]) |coord| {
                try used_cells.put(alloc, coordinateKey(coord), {});
            }
        }
    }

    std.mem.sortUnstable(Candidate, accepted.items, {}, candidateReadingOrder);
    const result = try alloc.alloc(Match, accepted.items.len);
    for (accepted.items, result) |candidate, *matched| {
        matched.* = .{
            .start = candidate.start,
            .end = candidate.end,
            .first = map[candidate.start],
            .last = map[candidate.end - 1],
        };
    }
    return result;
}

pub const LabelSet = struct {
    storage: []u8,
    offsets: []usize,
    count: usize,
    max_len: usize,

    pub fn deinit(self: *LabelSet, alloc: Allocator) void {
        alloc.free(self.offsets);
        alloc.free(self.storage);
        self.* = undefined;
    }

    pub fn get(self: *const LabelSet, index: usize) []const u8 {
        return self.storage[self.offsets[index]..self.offsets[index + 1]];
    }

    pub fn startsWith(self: *const LabelSet, index: usize, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.get(index), prefix);
    }
};

pub fn generateLabels(alloc: Allocator, alphabet: []const u8, count: usize) !LabelSet {
    // `validate` already rejects a single-character alphabet, so this only
    // catches a direct caller that skipped config parsing.
    try QuickSelectAlphabet.validate(alphabet);

    var leaves: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (leaves.items) |label| alloc.free(label);
        leaves.deinit(alloc);
    }
    try leaves.ensureTotalCapacity(alloc, alphabet.len);
    for (alphabet) |char| {
        const label = try alloc.alloc(u8, 1);
        label[0] = char;
        leaves.appendAssumeCapacity(label);
    }

    while (leaves.items.len < count) {
        var expand_index: usize = 0;
        var shallowest = leaves.items[0].len;
        for (leaves.items, 0..) |label, index| {
            if (label.len <= shallowest) {
                shallowest = label.len;
                expand_index = index;
            }
        }
        if (shallowest >= PrefixState.max_len) return error.TooManyLabels;

        const children = try alloc.alloc([]u8, alphabet.len);
        defer alloc.free(children);
        var initialized: usize = 0;
        errdefer for (children[0..initialized]) |label| alloc.free(label);
        const prefix = leaves.items[expand_index];
        for (alphabet, children) |char, *child| {
            child.* = try alloc.alloc(u8, prefix.len + 1);
            initialized += 1;
            @memcpy(child.*[0..prefix.len], prefix);
            child.*[prefix.len] = char;
        }
        try leaves.ensureUnusedCapacity(alloc, alphabet.len - 1);
        leaves.replaceRangeAssumeCapacity(expand_index, 1, children);
        alloc.free(prefix);
        initialized = 0;
    }

    const LabelOrder = struct {
        rank: [128]u8,

        fn lessThan(context: @This(), lhs: []u8, rhs: []u8) bool {
            if (lhs.len != rhs.len) return lhs.len < rhs.len;
            for (lhs, rhs) |lhs_char, rhs_char| {
                const lhs_rank = context.rank[lhs_char];
                const rhs_rank = context.rank[rhs_char];
                if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
            }
            return false;
        }
    };
    var order: LabelOrder = .{ .rank = [_]u8{0} ** 128 };
    for (alphabet, 0..) |char, index| order.rank[char] = @intCast(index);
    std.mem.sortUnstable([]u8, leaves.items, order, LabelOrder.lessThan);

    var total_len: usize = 0;
    var max_len: usize = 0;
    for (leaves.items[0..count]) |label| {
        total_len = std.math.add(usize, total_len, label.len) catch return error.TooManyLabels;
        max_len = @max(max_len, label.len);
    }
    const storage = try alloc.alloc(u8, total_len);
    errdefer alloc.free(storage);
    const offsets = try alloc.alloc(usize, std.math.add(usize, count, 1) catch return error.TooManyLabels);
    errdefer alloc.free(offsets);

    var offset: usize = 0;
    offsets[0] = 0;
    for (leaves.items[0..count], 0..) |label, index| {
        @memcpy(storage[offset..][0..label.len], label);
        offset += label.len;
        offsets[index + 1] = offset;
    }
    return .{
        .storage = storage,
        .offsets = offsets,
        .count = count,
        .max_len = max_len,
    };
}

pub const PrefixState = struct {
    pub const max_len = 64;

    bytes: [max_len]u8 = undefined,
    len: usize = 0,

    pub const InputResult = union(enum) {
        ignored,
        narrowed: usize,
        complete: usize,
    };

    pub fn typed(self: *const PrefixState) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn input(self: *PrefixState, labels: *const LabelSet, char: u8) InputResult {
        if (self.len >= labels.max_len or self.len >= self.bytes.len) return .ignored;

        self.bytes[self.len] = char;
        const candidate_prefix = self.bytes[0 .. self.len + 1];
        var remaining: usize = 0;
        var exact: ?usize = null;
        for (0..labels.count) |index| {
            if (!labels.startsWith(index, candidate_prefix)) continue;
            remaining += 1;
            if (candidate_prefix.len == labels.get(index).len) exact = index;
        }
        if (remaining == 0) return .ignored;

        self.len += 1;
        if (exact) |index| return .{ .complete = index };
        return .{ .narrowed = remaining };
    }

    pub fn backspace(self: *PrefixState) bool {
        if (self.len == 0) return false;
        self.len -= 1;
        return true;
    }

    pub fn remainingCount(self: *const PrefixState, labels: *const LabelSet) usize {
        var result: usize = 0;
        for (0..labels.count) |index| {
            result += @intFromBool(labels.startsWith(index, self.typed()));
        }
        return result;
    }
};

pub const CellRect = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
};

pub const PixelRect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const PlacementMetrics = struct {
    cell_width: i32,
    cell_height: i32,
    padding_left: i32,
    padding_top: i32,
    viewport_width: i32,
    viewport_height: i32,
    dpi: u32 = 96,
    logical_padding_x: i32,
    logical_stroke: i32,
};

fn scaled(logical: i32, dpi: u32) i32 {
    if (logical <= 0) return 0;
    return @intCast(@divTrunc(@as(i64, logical) * @as(i64, dpi) + 48, 96));
}

/// Place a label at the first cell in `cells`, clamping it inside the visible
/// pixel viewport when its chip would otherwise extend beyond the right edge.
pub fn labelPlacement(cells: CellRect, label_len: usize, metrics: PlacementMetrics) PixelRect {
    const cell_width = @max(1, metrics.cell_width);
    const cell_height = @max(1, metrics.cell_height);
    const inset = scaled(metrics.logical_padding_x, metrics.dpi) +
        scaled(metrics.logical_stroke, metrics.dpi);
    const label_cells: i32 = @intCast(@max(@as(usize, 1), label_len));
    const width = label_cells * cell_width + 2 * inset;
    const height = cell_height;
    const raw_left = metrics.padding_left + @as(i32, @intCast(cells.left)) * cell_width;
    const raw_top = metrics.padding_top + @as(i32, @intCast(cells.top)) * cell_height;
    const max_left = @max(0, metrics.viewport_width - width);
    const max_top = @max(0, metrics.viewport_height - height);
    const left = std.math.clamp(raw_left, 0, max_left);
    const top = std.math.clamp(raw_top, 0, max_top);
    return .{
        .left = left,
        .top = top,
        .right = @min(metrics.viewport_width, left + width),
        .bottom = @min(metrics.viewport_height, top + height),
    };
}

fn renderFixture(alloc: Allocator, cols: u16, rows: u16, text: []const u8) !terminal.RenderState {
    var term: terminal.Terminal = try .init(alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(text);

    var state: terminal.RenderState = .empty;
    errdefer state.deinit(alloc);
    try state.update(alloc, &term);
    return state;
}

test "hints: scans visible viewport defaults with text and coordinates" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var state = try renderFixture(
        alloc,
        96,
        6,
        "URL https://example.com/a\r\n" ++
            "PATH C:\\repo\\src\\main.zig\r\n" ++
            "UNC \\\\server\\share\\folder\\file.txt\r\n" ++
            "SHA deadbee\r\n" ++
            "IP 192.168.1.10 IPv6 2001:db8::1\r\n" ++
            "UUID 550e8400-e29b-41d4-a716-446655440000",
    );
    defer state.deinit(alloc);

    var scan = try scanRenderState(alloc, &state, &default_patterns);
    defer scan.deinit(alloc);

    const expected = [_]struct { text: []const u8, x: u16, y: u32 }{
        .{ .text = "https://example.com/a", .x = 4, .y = 0 },
        .{ .text = "C:\\repo\\src\\main.zig", .x = 5, .y = 1 },
        .{ .text = "\\\\server\\share\\folder\\file.txt", .x = 4, .y = 2 },
        .{ .text = "deadbee", .x = 4, .y = 3 },
        .{ .text = "192.168.1.10", .x = 3, .y = 4 },
        .{ .text = "2001:db8::1", .x = 21, .y = 4 },
        .{ .text = "550e8400-e29b-41d4-a716-446655440000", .x = 5, .y = 5 },
    };
    try testing.expectEqual(expected.len, scan.matches.len);
    for (expected, scan.matches, 0..) |want, matched, index| {
        try testing.expectEqualStrings(want.text, scan.matchText(index));
        try testing.expectEqual(want.x, matched.first.x);
        try testing.expectEqual(want.y, matched.first.y);
    }
}

// Every wide character occupies two cells, and the second one carries no
// codepoint. `RenderState.string` emits `\x00` for it, which the built-in path
// patterns exclude, so before the spacers were dropped a CJK path was labeled
// and copied only up to its first wide character.
test "hints: wide characters do not truncate a matched path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var state = try renderFixture(alloc, 40, 2, "PATH C:\\用户\\文档\\a.txt\r\nEND");
    defer state.deinit(alloc);

    var scan = try scanRenderState(alloc, &state, &default_patterns);
    defer scan.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), scan.matches.len);
    try testing.expectEqualStrings("C:\\用户\\文档\\a.txt", scan.matchText(0));

    // The trailing cell still maps to the last cell the text occupies, so the
    // fire-time re-verification can find the same span again.
    const matched = scan.matches[0];
    try testing.expectEqual(@as(u16, 5), matched.first.x);
    try testing.expectEqualStrings(
        scan.matchText(0),
        spanText(scan.text, scan.map, matched.first, matched.last).?,
    );
}

test "hints: scan negative fixture has no matches" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();
    var state = try renderFixture(alloc, 40, 2, "plain words\r\nand 12345");
    defer state.deinit(alloc);
    var scan = try scanRenderState(alloc, &state, &default_patterns);
    defer scan.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), scan.matches.len);
}

test "hints: URL open allowlist rejects arbitrary matched text" {
    try oni.testing.ensureInit();
    try std.testing.expect(try beginsWithAllowedScheme("https://example.com"));
    try std.testing.expect(try beginsWithAllowedScheme("mailto:user@example.com"));
    try std.testing.expect(!(try beginsWithAllowedScheme("C:\\work\\notes.txt")));
    try std.testing.expect(!(try beginsWithAllowedScheme("example.com")));

    // Schemes that reach a handler capable of running code are never openable,
    // even though the URL matcher still labels them so they can be copied.
    try std.testing.expect(!(try beginsWithAllowedScheme("file:///C:/tmp/evil.exe")));
    try std.testing.expect(!(try beginsWithAllowedScheme("file://server/share/x")));
    try std.testing.expect(!(try beginsWithAllowedScheme("javascript:alert(1)")));
    try std.testing.expect(!(try beginsWithAllowedScheme("ms-msdt:/id")));
    try std.testing.expect(!(try beginsWithAllowedScheme("search-ms:query=x")));

    // Anchored: a permitted scheme appearing later must not authorize opening.
    try std.testing.expect(!(try beginsWithAllowedScheme("evil https://example.com")));
}

test "hints: span text tracks a target's live cells" {
    const testing = std.testing;
    const text = "ab cd";
    const map = [_]point.Coordinate{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 },
        .{ .x = 4, .y = 0 },
    };

    try testing.expectEqualStrings(
        "ab",
        spanText(text, &map, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }).?,
    );
    try testing.expectEqualStrings(
        "cd",
        spanText(text, &map, .{ .x = 3, .y = 0 }, .{ .x = 4, .y = 0 }).?,
    );

    // A span that scrolled away is reported missing, so callers fail closed.
    try testing.expect(spanText(text, &map, .{ .x = 0, .y = 7 }, .{ .x = 1, .y = 7 }) == null);
    try testing.expect(spanText(text, &map, .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 0 }) == null);
}

test "hints: labels are shortest first and prefix free" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var one = try generateLabels(alloc, default_alphabet, 3);
    defer one.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), one.max_len);
    try testing.expectEqualStrings("a", one.get(0));
    try testing.expectEqualStrings("s", one.get(1));
    try testing.expectEqualStrings("d", one.get(2));

    var two = try generateLabels(alloc, default_alphabet, 10);
    defer two.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), two.max_len);
    try testing.expectEqualStrings("a", two.get(0));
    try testing.expectEqualStrings("k", two.get(7));
    try testing.expectEqualStrings("la", two.get(8));
    try testing.expectEqualStrings("ls", two.get(9));
    for (0..two.count) |i| for (0..two.count) |j| {
        if (i == j) continue;
        try testing.expect(!std.mem.startsWith(u8, two.get(i), two.get(j)));
    };

    var custom = try generateLabels(alloc, "xyz", 4);
    defer custom.deinit(alloc);
    try testing.expectEqualStrings("x", custom.get(0));
    try testing.expectEqualStrings("y", custom.get(1));
    try testing.expectEqualStrings("zx", custom.get(2));
    try testing.expectEqualStrings("zy", custom.get(3));
}

test "hints: typed prefix narrows ignores no-match and backspaces" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var labels = try generateLabels(alloc, "as", 3);
    defer labels.deinit(alloc);
    var prefix: PrefixState = .{};

    try testing.expectEqual(PrefixState.InputResult{ .narrowed = 2 }, prefix.input(&labels, 's'));
    try testing.expectEqualStrings("s", prefix.typed());
    try testing.expectEqual(PrefixState.InputResult.ignored, prefix.input(&labels, 'x'));
    try testing.expectEqualStrings("s", prefix.typed());
    try testing.expectEqual(PrefixState.InputResult{ .complete = 1 }, prefix.input(&labels, 'a'));
    try testing.expectEqualStrings("sa", prefix.typed());
    try testing.expect(prefix.backspace());
    try testing.expectEqualStrings("s", prefix.typed());
    try testing.expectEqual(@as(usize, 2), prefix.remainingCount(&labels));
    try testing.expect(prefix.backspace());
    try testing.expect(!prefix.backspace());
}

test "hints: overlap resolution prefers longest then earliest" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var map: [10]point.Coordinate = undefined;
    for (&map, 0..) |*coord, x| coord.* = .{ .x = @intCast(x), .y = 0 };
    const candidates = [_]Candidate{
        .{ .start = 2, .end = 5, .pattern_index = 0 },
        .{ .start = 1, .end = 7, .pattern_index = 1 },
        .{ .start = 2, .end = 8, .pattern_index = 2 },
        .{ .start = 8, .end = 10, .pattern_index = 3 },
    };
    const matches = try resolveCandidates(alloc, &candidates, &map);
    defer alloc.free(matches);
    try testing.expectEqual(@as(usize, 2), matches.len);
    try testing.expectEqual(@as(usize, 1), matches[0].start);
    try testing.expectEqual(@as(usize, 7), matches[0].end);
    try testing.expectEqual(@as(usize, 8), matches[1].start);
    try testing.expectEqual(@as(usize, 10), matches[1].end);
}

test "hints: label placement clamps right edge and scales DPI metrics" {
    const testing = std.testing;
    const clamped = labelPlacement(.{
        .left = 9,
        .top = 1,
        .right = 10,
        .bottom = 2,
    }, 2, .{
        .cell_width = 10,
        .cell_height = 20,
        .padding_left = 5,
        .padding_top = 3,
        .viewport_width = 100,
        .viewport_height = 80,
        .logical_padding_x = 2,
        .logical_stroke = 1,
    });
    try testing.expectEqual(PixelRect{ .left = 74, .top = 23, .right = 100, .bottom = 43 }, clamped);

    const dpi_cases = [_]struct { dpi: u32, right: i32 }{
        .{ .dpi = 144, .right = 64 },
        .{ .dpi = 192, .right = 66 },
        .{ .dpi = 288, .right = 72 },
    };
    for (dpi_cases) |dpi_case| {
        const scaled_rect = labelPlacement(.{
            .left = 2,
            .top = 1,
            .right = 3,
            .bottom = 2,
        }, 2, .{
            .cell_width = 12,
            .cell_height = 24,
            .padding_left = 6,
            .padding_top = 4,
            .viewport_width = 200,
            .viewport_height = 100,
            .dpi = dpi_case.dpi,
            .logical_padding_x = 2,
            .logical_stroke = 1,
        });
        try testing.expectEqual(
            PixelRect{ .left = 30, .top = 28, .right = dpi_case.right, .bottom = 52 },
            scaled_rect,
        );
    }
}

test "hints: pathological custom pattern stays within the scan work budget" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    const input_len = 256;
    const text = try alloc.alloc(u8, input_len);
    defer alloc.free(text);
    @memset(text, 'a');
    text[text.len - 1] = '!';

    const map = try alloc.alloc(point.Coordinate, input_len);
    defer alloc.free(map);
    for (map, 0..) |*coord, index| coord.* = .{
        .x = @intCast(index % 80),
        .y = @intCast(index / 80),
    };

    var timer = try std.time.Timer.start();
    const matches = try extractMatches(alloc, text, map, &.{"^(a+)+$"});
    defer alloc.free(matches);
    try testing.expectEqual(@as(usize, 0), matches.len);
    try testing.expect(timer.read() < 250 * std.time.ns_per_ms);
}

test "hints: custom pattern candidate count is bounded" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    const text = try alloc.alloc(u8, 5000);
    defer alloc.free(text);
    @memset(text, 'x');
    const map = try alloc.alloc(point.Coordinate, text.len);
    defer alloc.free(map);
    for (map, 0..) |*coord, index| coord.* = .{
        .x = @intCast(index % 100),
        .y = @intCast(index / 100),
    };

    const matches = try extractMatches(alloc, text, map, &.{"x"});
    defer alloc.free(matches);
    try testing.expectEqual(@as(usize, 4096), matches.len);
}

test "hints: accessible target names expose label and matched text" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Target 1 of 2, label a, https://example.com/a",
        accessibleTargetName(&buf, 0, 2, "a", "https://example.com/a"),
    );
}
