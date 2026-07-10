const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const build_options = @import("terminal_options");
const point = @import("../point.zig");
const size = @import("../size.zig");
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const Terminal = @import("../Terminal.zig");
const PageFormatter = @import("../formatter.zig").PageFormatter;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const QueryOptions = @import("query_options.zig").QueryOptions;
const oni = if (build_options.oniguruma) @import("oniguruma") else struct {};

// Regexes can be arbitrary-width. Keep a generous bounded suffix on no-match
// scans so large scrollback cannot accumulate in the sliding window forever.
const regex_no_match_retain_len = 64 * 1024;

/// Searches page nodes via a sliding window. The sliding window maintains
/// the invariant that data isn't pruned until (1) we've searched it and
/// (2) we've accounted for overlaps across pages to fit the needle.
///
/// The sliding window is first initialized empty. Pages are then appended
/// in the order to search them. The sliding window supports both a forward
/// and reverse order specified via `init`. The pages should be appended
/// in the correct order matching the search direction.
///
/// All appends grow the window. The window is only pruned when a search
/// is done (positive or negative match) via `next()`.
///
/// To avoid unnecessary memory growth, the recommended usage is to
/// call `next()` until it returns null and then `append` the next page
/// and repeat the process. This will always maintain the minimum
/// required memory to search for the needle.
///
/// The caller is responsible for providing the pages and ensuring they're
/// in the proper order. The SlidingWindow itself doesn't own the pages, but
/// it will contain pointers to them in order to return selections. If any
/// pages become invalid, the caller should clear the sliding window and
/// start over.
pub const SlidingWindow = struct {
    /// The allocator to use for all the data within this window. We
    /// store this rather than passing it around because its already
    /// part of multiple elements (eg. Meta's CellMap) and we want to
    /// ensure we always use a consistent allocator. Additionally, only
    /// a small amount of sliding windows are expected to be in use
    /// at any one time so the memory overhead isn't that large.
    alloc: Allocator,

    /// The data buffer is a circular buffer of u8 that contains the
    /// encoded page text that we can use to search for the needle.
    data: DataBuf,

    /// The meta buffer is a circular buffer that contains the metadata
    /// about the pages we're searching. This usually isn't that large
    /// so callers must iterate through it to find the offset to map
    /// data to meta.
    meta: MetaBuf,

    /// Buffer that can fit any amount of chunks necessary for next
    /// to never fail allocation.
    chunk_buf: std.MultiArrayList(FlattenedHighlight.Chunk),

    /// Offset into data for our current state. This handles the
    /// situation where our search moved through meta[0] but didn't
    /// do enough to prune it.
    data_offset: usize = 0,

    /// The needle we're searching for. Does own the memory.
    needle: []const u8,

    /// Match behavior for the current query.
    query_options: QueryOptions,

    /// The search direction. If the direction is forward then pages should
    /// be appended in forward linked list order from the PageList. If the
    /// direction is reverse then pages should be appended in reverse order.
    ///
    /// This is important because in most cases, a reverse search is going
    /// to be more desirable to search from the end of the active area
    /// backwards so more recent data is found first.
    direction: Direction,

    /// A buffer to store the overlap search data. This is used to search
    /// overlaps between pages where the match starts on one page and
    /// ends on another. The length is always `needle.len * 2`.
    overlap_buf: []u8,

    /// Scratch buffer used by regex / whole-word / case-sensitive paths
    /// when a contiguous linear view of the circular buffer is required.
    regex_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// Precompiled regex for non-default query options.
    regex_state: if (build_options.oniguruma) ?RegexState else void =
        if (build_options.oniguruma) null else {},

    const Direction = enum { forward, reverse };
    const DataBuf = CircBuf(u8, 0);
    const MetaBuf = CircBuf(Meta, undefined);
    const RegexError = if (build_options.oniguruma) oni.errors.Error else error{};

    pub const InitError = Allocator.Error || RegexError || error{
        UnsupportedQueryOptions,
    };
    pub const SearchError = Allocator.Error || RegexError;

    const Meta = struct {
        node: *PageList.List.Node,
        serial: u64,
        cell_map: std.ArrayList(point.Coordinate),

        pub fn deinit(self: *Meta, alloc: Allocator) void {
            self.cell_map.deinit(alloc);
        }
    };

    const RegexState = if (build_options.oniguruma) struct {
        pattern: []u8,
        regex: oni.Regex,

        fn deinit(self: *RegexState, alloc: Allocator) void {
            self.regex.deinit();
            alloc.free(self.pattern);
        }
    } else void;

    pub fn init(
        alloc: Allocator,
        direction: Direction,
        needle_unowned: []const u8,
    ) Allocator.Error!SlidingWindow {
        return SlidingWindow.initWithOptions(alloc, direction, needle_unowned, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Default options never request the optional regex engine.
            else => unreachable,
        };
    }

    pub fn initWithOptions(
        alloc: Allocator,
        direction: Direction,
        needle_unowned: []const u8,
        query_options: QueryOptions,
    ) InitError!SlidingWindow {
        if (comptime !build_options.oniguruma) {
            if (!query_options.isDefault()) return error.UnsupportedQueryOptions;
        }

        var data = try DataBuf.init(alloc, 0);
        errdefer data.deinit(alloc);

        var meta = try MetaBuf.init(alloc, 0);
        errdefer meta.deinit(alloc);

        const needle = try alloc.dupe(u8, needle_unowned);
        errdefer alloc.free(needle);
        switch (direction) {
            .forward => {},
            .reverse => std.mem.reverse(u8, needle),
        }

        const overlap_buf = try alloc.alloc(u8, needle.len * 2);
        errdefer alloc.free(overlap_buf);

        var regex_state = if (comptime build_options.oniguruma) @as(?RegexState, null) else {};
        if (comptime build_options.oniguruma) {
            if (!query_options.isDefault()) {
                regex_state = try initRegexState(alloc, needle_unowned, query_options);
            }
        }
        errdefer if (comptime build_options.oniguruma) {
            if (regex_state) |*state| state.deinit(alloc);
        };

        return .{
            .alloc = alloc,
            .data = data,
            .meta = meta,
            .chunk_buf = .empty,
            .needle = needle,
            .query_options = query_options,
            .direction = direction,
            .overlap_buf = overlap_buf,
            .regex_state = regex_state,
        };
    }

    pub fn deinit(self: *SlidingWindow) void {
        if (comptime build_options.oniguruma) {
            if (self.regex_state) |*state| state.deinit(self.alloc);
        }
        self.regex_buf.deinit(self.alloc);
        self.alloc.free(self.overlap_buf);
        self.alloc.free(self.needle);
        self.chunk_buf.deinit(self.alloc);
        self.data.deinit(self.alloc);

        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.deinit(self.alloc);
    }

    /// Clear all data but retain allocated capacity.
    pub fn clearAndRetainCapacity(self: *SlidingWindow) void {
        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.clear();
        self.data.clear();
        self.data_offset = 0;
    }

    fn initRegexState(
        alloc: Allocator,
        needle_unowned: []const u8,
        query_options: QueryOptions,
    ) InitError!RegexState {
        const pattern = try buildRegexPattern(alloc, needle_unowned, query_options);
        errdefer alloc.free(pattern);

        var regex = try oni.Regex.init(
            pattern,
            .{
                .ignorecase = !query_options.case_sensitive,
                .word_is_ascii = true,
            },
            oni.Encoding.utf8,
            oni.Syntax.default,
            null,
        );
        errdefer regex.deinit();

        return .{
            .pattern = pattern,
            .regex = regex,
        };
    }

    fn buildRegexPattern(
        alloc: Allocator,
        needle_unowned: []const u8,
        query_options: QueryOptions,
    ) Allocator.Error![]u8 {
        const base = if (query_options.regex)
            try alloc.dupe(u8, needle_unowned)
        else
            try escapeRegexLiteral(alloc, needle_unowned);
        errdefer alloc.free(base);

        if (!query_options.whole_word) return base;
        const wrapped = try std.fmt.allocPrint(alloc, "\\b(?:{s})\\b", .{base});
        alloc.free(base);
        return wrapped;
    }

    fn escapeRegexLiteral(alloc: Allocator, input: []const u8) Allocator.Error![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);

        for (input) |c| {
            switch (c) {
                '\\', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}' => {
                    try out.append(alloc, '\\');
                },
                else => {},
            }
            try out.append(alloc, c);
        }

        return try out.toOwnedSlice(alloc);
    }

    /// Search the window for the next occurrence of the needle. As
    /// the window moves, the window will prune itself while maintaining
    /// the invariant that the window is always big enough to contain
    /// the needle.
    ///
    /// This returns a flattened highlight on a match. The
    /// flattened highlight requires allocation and is therefore more expensive
    /// than a normal selection, but it is more efficient to render since it
    /// has all the information without having to dereference pointers into
    /// the terminal state.
    ///
    /// The flattened highlight chunks reference internal memory for this
    /// sliding window and are only valid until the next call to `next()`
    /// or `append()`. If the caller wants to retain the flattened highlight
    /// then they should clone it.
    pub fn next(self: *SlidingWindow) SearchError!?FlattenedHighlight {
        const using_regex_engine = if (comptime build_options.oniguruma)
            self.regex_state != null
        else
            false;
        const slices = slices: {
            const data_len = self.data.len();
            if (data_len == 0) return null;

            // Literal matching needs at least needle.len bytes. Regex matching
            // may match shorter than its pattern source, so it cannot use this
            // literal fast-fail path.
            if (!using_regex_engine and data_len < self.needle.len) return null;

            break :slices self.data.getPtrSlice(
                self.data_offset,
                data_len - self.data_offset,
            );
        };

        if (comptime build_options.oniguruma) {
            if (using_regex_engine) {
                if (try self.regexMatch(slices[0], slices[1])) |match| {
                    return self.highlight(match.start, match.len);
                }
            }
        }

        if (!using_regex_engine) {
            // Search the first slice for the needle.
            if (std.ascii.indexOfIgnoreCase(slices[0], self.needle)) |idx| {
                return self.highlight(
                    idx,
                    self.needle.len,
                );
            }

            // Search the overlap buffer for the needle.
            if (slices[0].len > 0 and slices[1].len > 0) overlap: {
                // Get up to needle.len - 1 bytes from each side (as much as
                // we can) and store it in the overlap buffer.
                const prefix: []const u8 = prefix: {
                    const len = @min(slices[0].len, self.needle.len - 1);
                    const idx = slices[0].len - len;
                    break :prefix slices[0][idx..];
                };
                const suffix: []const u8 = suffix: {
                    const len = @min(slices[1].len, self.needle.len - 1);
                    break :suffix slices[1][0..len];
                };
                const overlap_len = prefix.len + suffix.len;
                assert(overlap_len <= self.overlap_buf.len);
                @memcpy(self.overlap_buf[0..prefix.len], prefix);
                @memcpy(self.overlap_buf[prefix.len..overlap_len], suffix);

                // Search the overlap
                const idx = std.ascii.indexOfIgnoreCase(
                    self.overlap_buf[0..overlap_len],
                    self.needle,
                ) orelse break :overlap;

                // We found a match in the overlap buffer. We need to map the
                // index back to the data buffer in order to get our selection.
                return self.highlight(
                    slices[0].len - prefix.len + idx,
                    self.needle.len,
                );
            }

            // Search the last slice for the needle.
            if (std.ascii.indexOfIgnoreCase(slices[1], self.needle)) |idx| {
                return self.highlight(
                    slices[0].len + idx,
                    self.needle.len,
                );
            }
        }

        const retain_len = self.noMatchRetainLen(using_regex_engine);

        // Special case zero-overlap searches to delete the entire buffer.
        if (retain_len == 0) {
            self.clearAndRetainCapacity();
            self.assertIntegrity();
            return null;
        }

        self.pruneRetainingSuffix(retain_len);

        self.assertIntegrity();
        return null;
    }

    fn pruneRetainingSuffix(self: *SlidingWindow, retain_len: usize) void {
        if (self.data.len() <= retain_len) {
            self.data_offset = 0;
            return;
        }

        var drop = self.data.len() - retain_len;
        while (drop > 0) {
            var meta_it = self.meta.iterator(.forward);
            const meta = meta_it.next().?;
            const meta_len = meta.cell_map.items.len;
            assert(meta_len > 0);

            if (drop >= meta_len) {
                meta.deinit(self.alloc);
                self.meta.deleteOldest(1);
                self.data.deleteOldest(meta_len);
                drop -= meta_len;
                continue;
            }

            const keep_len = meta_len - drop;
            std.mem.copyForwards(
                point.Coordinate,
                meta.cell_map.items[0..keep_len],
                meta.cell_map.items[drop..],
            );
            meta.cell_map.shrinkRetainingCapacity(keep_len);
            self.data.deleteOldest(drop);
            drop = 0;
        }

        self.data_offset = 0;
    }

    fn noMatchRetainLen(self: *const SlidingWindow, using_regex_engine: bool) usize {
        if (self.needle.len == 0) return 0;

        if (using_regex_engine and self.query_options.regex) {
            return @max(self.needle.len + 1, regex_no_match_retain_len);
        }

        if (using_regex_engine and self.query_options.whole_word) {
            // A literal whole-word match at the end of the current window may
            // need left context and the next page's first byte to validate
            // word boundaries.
            return self.needle.len + 1;
        }

        return self.needle.len - 1;
    }

    const RegexMatch = struct {
        start: usize,
        len: usize,
    };

    const RegexEdgeContext = struct {
        word_boundary: bool = false,
        line_anchor: bool = false,
        absolute_anchor: bool = false,

        fn any(self: RegexEdgeContext) bool {
            return self.word_boundary or self.line_anchor or self.absolute_anchor;
        }
    };

    const RegexEdgeSensitivity = struct {
        before: RegexEdgeContext = .{},
        after: RegexEdgeContext = .{},

        fn any(self: RegexEdgeSensitivity) bool {
            return self.before.any() or self.after.any();
        }
    };

    fn regexMatch(
        self: *SlidingWindow,
        first: []const u8,
        second: []const u8,
    ) SearchError!?RegexMatch {
        if (comptime !build_options.oniguruma) return null;
        const state = if (self.regex_state) |*state| state else return null;
        const edge_sensitivity = self.regexEdgeSensitivity();
        const haystack = try self.buildRegexHaystack(first, second);

        var search_start: usize = 0;
        var last_match: ?RegexMatch = null;
        while (search_start <= haystack.len) {
            var region: oni.Region = .{};
            defer region.deinit();

            _ = state.regex.searchAdvanced(haystack, search_start, haystack.len, &region, .{
                .find_not_empty = true,
            }) catch |err| switch (err) {
                error.Mismatch => break,
                else => return err,
            };

            const starts = region.starts();
            const ends = region.ends();
            if (starts.len == 0 or ends.len == 0) break;

            const start_i: usize = @intCast(starts[0]);
            const end_i: usize = @intCast(ends[0]);
            if (end_i <= start_i) {
                search_start = start_i + 1;
                continue;
            }
            if (edge_sensitivity.any() and self.regexMatchTouchesSyntheticEdge(
                haystack,
                start_i,
                end_i,
                edge_sensitivity,
            )) {
                search_start = start_i + 1;
                continue;
            }

            last_match = if (self.direction == .forward)
                .{
                    .start = start_i,
                    .len = end_i - start_i,
                }
            else
                .{
                    .start = haystack.len - end_i,
                    .len = end_i - start_i,
                };

            if (self.direction == .forward) break;
            search_start = start_i + 1;
        }

        return last_match;
    }

    fn buildRegexHaystack(
        self: *SlidingWindow,
        first: []const u8,
        second: []const u8,
    ) Allocator.Error![]const u8 {
        const total_len = first.len + second.len;
        self.regex_buf.clearRetainingCapacity();
        try self.regex_buf.ensureTotalCapacity(self.alloc, total_len);

        switch (self.direction) {
            .forward => {
                self.regex_buf.appendSliceAssumeCapacity(first);
                self.regex_buf.appendSliceAssumeCapacity(second);
            },
            .reverse => {
                // `first` and `second` are logical search-order slices after
                // data_offset. Reverse the whole range across the circular
                // split: reverse(first ++ second) == reverse(second) ++ reverse(first).
                self.appendReverseForRegex(second);
                self.appendReverseForRegex(first);
            },
        }

        return self.regex_buf.items;
    }

    fn appendReverseForRegex(self: *SlidingWindow, bytes: []const u8) void {
        var i = bytes.len;
        while (i > 0) {
            i -= 1;
            self.regex_buf.appendAssumeCapacity(bytes[i]);
        }
    }

    fn regexMatchTouchesSyntheticEdge(
        self: *const SlidingWindow,
        haystack: []const u8,
        start: usize,
        end: usize,
        sensitivity: RegexEdgeSensitivity,
    ) bool {
        if (start == 0 and
            sensitivity.before.any() and
            self.hasRegexContextBeforeHaystack(haystack, sensitivity.before))
        {
            return true;
        }
        if (end == haystack.len and
            sensitivity.after.any() and
            self.hasRegexContextAfterHaystack(haystack, sensitivity.after))
        {
            return true;
        }
        return false;
    }

    fn hasRegexContextBeforeHaystack(
        self: *const SlidingWindow,
        haystack: []const u8,
        context: RegexEdgeContext,
    ) bool {
        return switch (self.direction) {
            .forward => self.hasSearchOrderContextBeforeWindow(context, haystack[0]),
            .reverse => self.hasSearchOrderContextAfterWindow(context, haystack[0]),
        };
    }

    fn hasRegexContextAfterHaystack(
        self: *const SlidingWindow,
        haystack: []const u8,
        context: RegexEdgeContext,
    ) bool {
        return switch (self.direction) {
            .forward => self.hasSearchOrderContextAfterWindow(context, haystack[haystack.len - 1]),
            .reverse => self.hasSearchOrderContextBeforeWindow(context, haystack[haystack.len - 1]),
        };
    }

    fn hasSearchOrderContextBeforeWindow(
        self: *const SlidingWindow,
        context: RegexEdgeContext,
        edge_byte: u8,
    ) bool {
        if (self.data_offset > 0) {
            const prior_byte = self.dataByteAt(self.data_offset - 1) orelse return true;
            return regexContextRejectsKnownBefore(context, prior_byte, edge_byte);
        }

        var it = self.meta.iterator(.forward);
        const meta = it.next() orelse return false;
        return switch (self.direction) {
            .forward => {
                const prev = meta.node.prev orelse return false;
                if (hardNewlineAfterNode(prev)) |byte| {
                    return regexContextRejectsKnownBefore(context, byte, edge_byte);
                }
                return true;
            },
            .reverse => meta.node.next != null,
        };
    }

    fn hasSearchOrderContextAfterWindow(
        self: *const SlidingWindow,
        context: RegexEdgeContext,
        edge_byte: u8,
    ) bool {
        var it = self.meta.iterator(.reverse);
        const meta = it.next() orelse return false;
        return switch (self.direction) {
            .forward => meta.node.next != null,
            .reverse => {
                const prev = meta.node.prev orelse return false;
                if (hardNewlineAfterNode(prev)) |byte| {
                    return regexContextRejectsKnownAfter(context, edge_byte, byte);
                }
                return true;
            },
        };
    }

    fn dataByteAt(self: *const SlidingWindow, offset: usize) ?u8 {
        if (offset >= self.data.len()) return null;

        const cap = self.data.capacity();
        if (cap == 0) return null;

        const idx = self.data.tail + offset;
        const storage_idx = if (idx < cap) idx else idx - cap;
        return self.data.storage[storage_idx];
    }

    fn isAsciiWordBoundary(a: u8, b: u8) bool {
        return isAsciiWordByte(a) != isAsciiWordByte(b);
    }

    fn isAsciiWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn regexContextRejectsKnownBefore(context: RegexEdgeContext, prior_byte: u8, edge_byte: u8) bool {
        if (context.absolute_anchor) return true;
        if (context.line_anchor and prior_byte != '\n') return true;
        if (context.word_boundary and !isAsciiWordBoundary(prior_byte, edge_byte)) return true;
        return false;
    }

    fn regexContextRejectsKnownAfter(context: RegexEdgeContext, edge_byte: u8, next_byte: u8) bool {
        if (context.absolute_anchor) return true;
        if (context.line_anchor and next_byte != '\n') return true;
        if (context.word_boundary and !isAsciiWordBoundary(edge_byte, next_byte)) return true;
        return false;
    }

    fn hardNewlineAfterNode(node: *const PageList.List.Node) ?u8 {
        const row = node.data.getRow(node.data.size.rows - 1);
        return if (row.wrap) null else '\n';
    }

    fn regexEdgeSensitivity(self: *const SlidingWindow) RegexEdgeSensitivity {
        if (comptime build_options.oniguruma) {
            const state = self.regex_state orelse return .{};
            return regexPatternEdgeSensitivity(state.pattern);
        } else {
            return .{};
        }
    }

    fn regexPatternEdgeSensitivity(pattern: []const u8) RegexEdgeSensitivity {
        var sensitivity: RegexEdgeSensitivity = .{};
        var escaped = false;
        var in_class = false;
        var at_alt_start = true;
        var group_prefix = false;
        for (pattern, 0..) |c, i| {
            if (escaped) {
                escaped = false;
                if (!in_class) {
                    switch (c) {
                        'A', 'G' => sensitivity.before.absolute_anchor = true,
                        'Z', 'z' => sensitivity.after.absolute_anchor = true,
                        'b' => {
                            sensitivity.before.word_boundary = true;
                            sensitivity.after.word_boundary = true;
                        },
                        else => {},
                    }
                    at_alt_start = false;
                    group_prefix = false;
                }
                continue;
            }

            if (c == '\\') {
                escaped = true;
                continue;
            }

            if (in_class) {
                if (c == ']') in_class = false;
                continue;
            }

            switch (c) {
                '[' => {
                    in_class = true;
                    at_alt_start = false;
                    group_prefix = false;
                },
                '(' => {
                    at_alt_start = true;
                    group_prefix = true;
                },
                ')' => {
                    at_alt_start = false;
                    group_prefix = false;
                },
                '|' => {
                    at_alt_start = true;
                    group_prefix = false;
                },
                '?', ':' => {
                    if (!(group_prefix and at_alt_start)) {
                        at_alt_start = false;
                        group_prefix = false;
                    }
                },
                '^' => {
                    if (at_alt_start) sensitivity.before.line_anchor = true;
                    at_alt_start = false;
                    group_prefix = false;
                },
                '$' => {
                    if (regexDollarIsLineAnchor(pattern, i)) {
                        sensitivity.after.line_anchor = true;
                    }
                    at_alt_start = false;
                    group_prefix = false;
                },
                else => {
                    at_alt_start = false;
                    group_prefix = false;
                },
            }
        }

        return sensitivity;
    }

    fn regexDollarIsLineAnchor(pattern: []const u8, dollar_i: usize) bool {
        var escaped = false;
        var in_class = false;
        var i = dollar_i + 1;
        while (i < pattern.len) : (i += 1) {
            const c = pattern[i];
            if (escaped) {
                return false;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (in_class) {
                if (c == ']') in_class = false;
                continue;
            }
            return switch (c) {
                '|' => true,
                ')' => true,
                '[' => false,
                else => false,
            };
        }
        return true;
    }

    /// Return a flattened highlight for the given start and length.
    ///
    /// The flattened highlight can be used to render the highlight
    /// in the most efficient way because it doesn't require a terminal
    /// lock to access terminal data to compare whether some viewport
    /// matches the highlight (because it doesn't need to traverse
    /// the page nodes).
    ///
    /// The start index is assumed to be relative to the offset. i.e.
    /// index zero is actually at `self.data[self.data_offset]`. The
    /// selection will account for the offset.
    fn highlight(
        self: *SlidingWindow,
        start_offset: usize,
        len: usize,
    ) FlattenedHighlight {
        const start = start_offset + self.data_offset;
        const end = start + len - 1;
        if (comptime std.debug.runtime_safety) {
            assert(start < self.data.len());
            assert(start + len <= self.data.len());
        }

        self.chunk_buf.clearRetainingCapacity();
        var result: FlattenedHighlight = .empty;

        // Go through the meta nodes to find our start.
        const tl: struct {
            /// If non-null, we need to continue searching for the bottom-right.
            br: ?struct {
                it: MetaBuf.Iterator,
                consumed: usize,
            },

            /// Data to prune, both are lengths.
            prune: struct {
                meta: usize,
                data: usize,
            },
        } = tl: {
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            while (meta_it.next()) |meta| {
                // Always increment our consumed count so that our index
                // is right for the end search if we do it.
                const prior_meta_consumed = meta_consumed;
                meta_consumed += meta.cell_map.items.len;

                // meta_i is the index we expect to find the match in the
                // cell map within this meta if it contains it.
                const meta_i = start - prior_meta_consumed;

                // This meta doesn't contain the match. This means we
                // can also prune this set of data because we only look
                // forward.
                if (meta_i >= meta.cell_map.items.len) continue;

                // Now we look for the end. In MOST cases it is the same as
                // our starting chunk because highlights are usually small and
                // not on a boundary, so let's optimize for that.
                const end_i = end - prior_meta_consumed;
                if (end_i < meta.cell_map.items.len) {
                    @branchHint(.likely);

                    // The entire highlight is within this meta.
                    const start_map = meta.cell_map.items[meta_i];
                    const end_map = meta.cell_map.items[end_i];
                    result.top_x = start_map.x;
                    result.bot_x = end_map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(start_map.y),
                        .end = @intCast(end_map.y + 1),
                    });

                    break :tl .{
                        .br = null,
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                } else {
                    // We found the meta that contains the start of the match
                    // only. Consume this entire node from our start offset.
                    const map = meta.cell_map.items[meta_i];
                    result.top_x = map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(map.y),
                        .end = meta.node.data.size.rows,
                    });

                    break :tl .{
                        .br = .{
                            .it = meta_it,
                            .consumed = meta_consumed,
                        },
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                }
            } else {
                // Precondition that the start index is within the data buffer.
                unreachable;
            }
        };

        // Search for our end.
        if (tl.br) |br| {
            var meta_it = br.it;
            var meta_consumed: usize = br.consumed;
            while (meta_it.next()) |meta| {
                // meta_i is the index we expect to find the match in the
                // cell map within this meta if it contains it.
                const meta_i = end - meta_consumed;
                if (meta_i >= meta.cell_map.items.len) {
                    // This meta doesn't contain the match. We still add it
                    // to our results because we want the full flattened list.
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = 0,
                        .end = meta.node.data.size.rows,
                    });

                    meta_consumed += meta.cell_map.items.len;
                    continue;
                }

                // We found it
                const map = meta.cell_map.items[meta_i];
                result.bot_x = map.x;
                self.chunk_buf.appendAssumeCapacity(.{
                    .node = meta.node,
                    .serial = meta.serial,
                    .start = 0,
                    .end = @intCast(map.y + 1),
                });
                break;
            } else {
                // Precondition that the end index is within the data buffer.
                unreachable;
            }
        }

        // Our offset into the current meta block is the start index
        // minus the amount of data fully consumed. We then add one
        // to move one past the match so we don't repeat it.
        self.data_offset = start - tl.prune.data + 1;

        // If we went beyond our initial meta node we can prune.
        if (tl.prune.meta > 0) {
            // Deinit all our memory in the meta blocks prior to our
            // match.
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            for (0..tl.prune.meta) |_| {
                const meta: *Meta = meta_it.next().?;
                meta_consumed += meta.cell_map.items.len;
                meta.deinit(self.alloc);
            }
            if (comptime std.debug.runtime_safety) {
                assert(meta_it.idx == tl.prune.meta);
                assert(meta_it.next().?.node == self.chunk_buf.items(.node)[0]);
            }
            self.meta.deleteOldest(tl.prune.meta);

            // Delete all the data up to our current index.
            assert(tl.prune.data > 0);
            self.data.deleteOldest(tl.prune.data);
        }

        switch (self.direction) {
            .forward => {},
            .reverse => {
                const slice = self.chunk_buf.slice();
                const nodes = slice.items(.node);
                const serials = slice.items(.serial);
                const starts = slice.items(.start);
                const ends = slice.items(.end);

                if (self.chunk_buf.len > 1) {
                    // Reverse all our chunks. This should be pretty obvious why.
                    std.mem.reverse(*PageList.List.Node, nodes);
                    std.mem.reverse(u64, serials);
                    std.mem.reverse(size.CellCountInt, starts);
                    std.mem.reverse(size.CellCountInt, ends);

                    // Now normally with forward traversal with multiple pages,
                    // the suffix of the first page and the prefix of the last
                    // page are used.
                    //
                    // For a reverse traversal, this is inverted (since the
                    // pages are in reverse order we get the suffix of the last
                    // page and the prefix of the first page). So we need to
                    // invert this.
                    //
                    // We DON'T need to do this for any middle pages because
                    // they always use the full page.
                    //
                    // This is a fixup that makes our start/end match the
                    // same logic as the loops above if they were in forward
                    // order.
                    assert(nodes.len >= 2);
                    starts[0] = ends[0] - 1;
                    ends[0] = nodes[0].data.size.rows;
                    ends[nodes.len - 1] = starts[nodes.len - 1] + 1;
                    starts[nodes.len - 1] = 0;
                } else {
                    // For a single chunk, the y values are in reverse order
                    // (start is the screen-end, end is the screen-start).
                    // Swap them to get proper top-to-bottom order.
                    const start_y = starts[0];
                    starts[0] = ends[0] - 1;
                    ends[0] = start_y + 1;
                }

                // X values also need to be reversed since the top/bottom
                // are swapped for the nodes.
                const top_x = result.top_x;
                result.top_x = result.bot_x;
                result.bot_x = top_x;
            },
        }

        // Copy over our MultiArrayList so it points to the proper memory.
        result.chunks = self.chunk_buf;
        return result;
    }

    /// Add a new node to the sliding window. This will always grow
    /// the sliding window; data isn't pruned until it is consumed
    /// via a search (via next()).
    ///
    /// Returns the number of bytes of content added to the sliding window.
    /// The total bytes will be larger since this omits metadata, but it is
    /// an accurate measure of the text content size added.
    pub fn append(
        self: *SlidingWindow,
        node: *PageList.List.Node,
    ) Allocator.Error!usize {
        // Initialize our metadata for the node.
        var meta: Meta = .{
            .node = node,
            .serial = node.serial,
            .cell_map = .empty,
        };
        errdefer meta.deinit(self.alloc);

        // PageFormatter writes to a linear writer; copy that encoded
        // page into the circular search window below.
        var encoded: std.Io.Writer.Allocating = .init(self.alloc);
        defer encoded.deinit();

        // Encode the page into the buffer.
        const formatter: PageFormatter = formatter: {
            var formatter: PageFormatter = .init(&meta.node.data, .{
                .emit = .plain,
                .unwrap = true,
            });
            formatter.point_map = .{
                .alloc = self.alloc,
                .map = &meta.cell_map,
            };
            break :formatter formatter;
        };
        formatter.format(&encoded.writer) catch {
            // The ArrayList-backed writer can only fail by exhausting memory.
            return error.OutOfMemory;
        };
        assert(meta.cell_map.items.len == encoded.written().len);

        // If the node we're adding isn't soft-wrapped, we add the
        // trailing newline.
        const row = node.data.getRow(node.data.size.rows - 1);
        if (!row.wrap) {
            encoded.writer.writeByte('\n') catch return error.OutOfMemory;
            try meta.cell_map.append(
                self.alloc,
                meta.cell_map.getLastOrNull() orelse .{
                    .x = 0,
                    .y = 0,
                },
            );
        }

        // If our written data is empty, then there is nothing to
        // add to our data set.
        const written = encoded.written();
        if (written.len == 0) {
            self.assertIntegrity();
            return 0;
        }

        // Get our written data. If we're doing a reverse search then we
        // need to reverse all our encodings.
        switch (self.direction) {
            .forward => {},
            .reverse => {
                std.mem.reverse(u8, written);
                std.mem.reverse(point.Coordinate, meta.cell_map.items);
            },
        }

        // Ensure our buffers are big enough to store what we need.
        try self.data.ensureUnusedCapacity(self.alloc, written.len);
        try self.meta.ensureUnusedCapacity(self.alloc, 1);
        try self.chunk_buf.ensureTotalCapacity(self.alloc, self.meta.capacity());

        // Append our new node to the circular buffer.
        self.data.appendSliceAssumeCapacity(written);
        self.meta.appendAssumeCapacity(meta);

        self.assertIntegrity();
        return written.len;
    }

    /// Only for tests!
    fn testChangeNeedle(self: *SlidingWindow, new: []const u8) void {
        assert(new.len == self.needle.len);
        self.alloc.free(self.needle);
        self.needle = self.alloc.dupe(u8, new) catch unreachable;
    }

    fn assertIntegrity(self: *const SlidingWindow) void {
        if (comptime !std.debug.runtime_safety) return;

        // We don't run integrity checks on Valgrind because its soooooo slow,
        // Valgrind is our integrity checker, and we run these during unit
        // tests (non-Valgrind) anyways so we're verifying anyways.
        if (std.valgrind.runningOnValgrind() > 0) return;

        // Integrity check: verify our data matches our metadata exactly.
        var meta_it = self.meta.iterator(.forward);
        var data_len: usize = 0;
        while (meta_it.next()) |m| data_len += m.cell_map.items.len;
        assert(data_len == self.data.len());

        // Integrity check: verify our data offset is within bounds.
        assert(self.data.len() == 0 or self.data_offset < self.data.len());
    }
};

test "SlidingWindow empty on init" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();
    try testing.expectEqual(0, w.data.len());
    try testing.expectEqual(0, w.meta.len());
}

test "SlidingWindow single append" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append case insensitive ASCII" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "Boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append case sensitive" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "Boo!", .{
        .case_sensitive = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    try testing.expect((try w.next()) == null);
}

test "SlidingWindow non-regex regex engine prunes no-match pages" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "Needle", .{
        .case_sensitive = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 20, .rows = 4, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_cells = s.pages.cols * s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_cells + w.needle.len + 1) |_| try s.testWriteString("x");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect((try w.next()) == null);

    _ = try w.append(first_node.next.?);
    try testing.expect((try w.next()) == null);
    try testing.expectEqual(@as(usize, 1), w.meta.len());
    try testing.expectEqual(w.needle.len - 1, w.data.len() - w.data_offset);
}

test "SlidingWindow single append whole word" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "boo", .{
        .whole_word = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("booo boo barbar");

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 5,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start));
    try testing.expectEqual(point.Point{ .active = .{
        .x = 7,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end));
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow whole word matches true page edge" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "boo", .{
        .whole_word = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString(" boo");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);

    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 77,
        .y = 23,
    } }, s.pages.pointFromPin(.active, sel.start));
    try testing.expectEqual(point.Point{ .active = .{
        .x = 79,
        .y = 23,
    } }, s.pages.pointFromPin(.active, sel.end));
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow whole word does not match synthetic page edge" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "boo", .{
        .whole_word = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString(" boo");
    try s.testWriteString("x");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect((try w.next()) == null);

    _ = try w.append(first_node.next.?);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow whole-word literal retains full synthetic edge match" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "boo", .{
        .whole_word = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString(" boo");
    try s.testWriteString(" ");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect((try w.next()) == null);

    _ = try w.append(first_node.next.?);
    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(first_node, sel.start.node);
    try testing.expectEqual(first_node, sel.end.node);
}

test "SlidingWindow single append regex" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "b[o]{2}!", .{
        .regex = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. baa! hello. boo!");

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 19,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start));
    try testing.expectEqual(point.Point{ .active = .{
        .x = 22,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end));
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow invalid regex init returns recoverable error" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w = SlidingWindow.initWithOptions(alloc, .forward, "[", .{
        .regex = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer w.deinit();

    return error.TestExpectedError;
}

test "SlidingWindow regex runtime error preserves window state" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "b[o]{2}!", .{
        .regex = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const data_len = w.data.len();
    const meta_len = w.meta.len();

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const original_alloc = w.alloc;
    defer w.alloc = original_alloc;
    w.alloc = failing.allocator();
    try testing.expectError(error.OutOfMemory, w.next());
    try testing.expectEqual(data_len, w.data.len());
    try testing.expectEqual(meta_len, w.meta.len());
}

test "SlidingWindow regex no match preserves window state" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "boo!", .{
        .regex = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. bo");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const data_len = w.data.len();
    const meta_len = w.meta.len();
    try testing.expect((try w.next()) == null);
    try testing.expectEqual(data_len, w.data.len());
    try testing.expectEqual(meta_len, w.meta.len());
}

test "SlidingWindow regex no match defers pruning" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "b[o]{2}!", .{
        .regex = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols) |_| try s.testWriteString("x");
    try s.testWriteString("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    _ = try w.append(first_node.next.?);
    const data_len = w.data.len();

    try testing.expect((try w.next()) == null);
    try testing.expectEqual(@as(usize, 2), w.meta.len());
    try testing.expectEqual(data_len, w.data.len());
    try testing.expectEqual(@as(usize, 0), w.data_offset);
}

test "SlidingWindow regex no match keeps bounded suffix" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "y+z", .{
        .regex = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 120, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    try text.appendNTimes(alloc, 'x', regex_no_match_retain_len + 8192);
    try s.testWriteString(text.items);

    var node: ?*PageList.List.Node = s.pages.pages.first.?;
    while (node) |n| : (node = n.next) {
        _ = try w.append(n);
    }
    const meta_len = w.meta.len();
    try testing.expect(meta_len > 1);

    try testing.expect((try w.next()) == null);
    try testing.expectEqual(@as(usize, 0), w.data_offset);
    try testing.expectEqual(regex_no_match_retain_len, w.data.len());
}

test "SlidingWindow regex match can span more than literal overlap" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "startx+end", .{
        .regex = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 20, .rows = 4, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_cells = s.pages.cols * s.pages.pages.first.?.data.capacity.rows;
    try s.testWriteString("start");
    for (0..first_page_cells - "start".len) |_| try s.testWriteString("x");
    try s.testWriteString("end");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    const first_node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(first_node);
    try testing.expect((try w.next()) == null);
    try testing.expectEqual(@as(usize, 1), w.meta.len());
    try testing.expectEqual(@as(usize, 0), w.data_offset);

    _ = try w.append(first_node.next.?);
    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(first_node, sel.start.node);
    try testing.expectEqual(first_node.next.?, sel.end.node);
}

test "SlidingWindow regex edge sensitivity detects anchors and character classes" {
    const testing = std.testing;

    const absolute_start = SlidingWindow.regexPatternEdgeSensitivity("\\Afoo");
    try testing.expect(absolute_start.before.absolute_anchor);
    try testing.expect(!absolute_start.after.any());

    const search_start = SlidingWindow.regexPatternEdgeSensitivity("\\Gfoo");
    try testing.expect(search_start.before.absolute_anchor);
    try testing.expect(!search_start.after.any());

    const absolute_end = SlidingWindow.regexPatternEdgeSensitivity("foo\\Z");
    try testing.expect(!absolute_end.before.any());
    try testing.expect(absolute_end.after.absolute_anchor);

    const strict_end = SlidingWindow.regexPatternEdgeSensitivity("foo\\z");
    try testing.expect(!strict_end.before.any());
    try testing.expect(strict_end.after.absolute_anchor);

    const word = SlidingWindow.regexPatternEdgeSensitivity("\\bfoo");
    try testing.expect(word.before.word_boundary);
    try testing.expect(word.after.word_boundary);

    const class_only = SlidingWindow.regexPatternEdgeSensitivity("[^$^]+");
    try testing.expect(!class_only.any());

    const anchors = SlidingWindow.regexPatternEdgeSensitivity("^foo$");
    try testing.expect(anchors.before.line_anchor);
    try testing.expect(anchors.after.line_anchor);
}

test "SlidingWindow regex edge sensitivity ignores literal anchor bytes" {
    const testing = std.testing;

    const literals = SlidingWindow.regexPatternEdgeSensitivity("foo^bar price$usd");
    try testing.expect(!literals.before.line_anchor);
    try testing.expect(!literals.after.line_anchor);

    const alternation_start = SlidingWindow.regexPatternEdgeSensitivity("foo|^bar");
    try testing.expect(alternation_start.before.line_anchor);

    const alternation_end = SlidingWindow.regexPatternEdgeSensitivity("foo$|bar");
    try testing.expect(alternation_end.after.line_anchor);

    const grouped = SlidingWindow.regexPatternEdgeSensitivity("(?:^bar$)");
    try testing.expect(grouped.before.line_anchor);
    try testing.expect(grouped.after.line_anchor);
}

test "SlidingWindow reverse regex haystack preserves offset across circular split" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .reverse, "abc", .{
        .regex = true,
    });
    defer w.deinit();

    try w.data.ensureUnusedCapacity(alloc, 8);
    w.data.appendSliceAssumeCapacity("123456");
    w.data.deleteOldest(4);
    w.data.appendSliceAssumeCapacity("abcdef");
    w.data_offset = 2;

    const slices = w.data.getPtrSlice(w.data_offset, w.data.len() - w.data_offset);
    try testing.expect(slices[0].len > 0);
    try testing.expect(slices[1].len > 0);

    const haystack = try w.buildRegexHaystack(slices[0], slices[1]);
    try testing.expectEqualStrings("fedcba", haystack);
}

test "SlidingWindow whole-word regex edge sensitivity preserves embedded anchors" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "^boo", .{
        .regex = true,
        .whole_word = true,
    });
    defer w.deinit();

    const sensitivity = w.regexEdgeSensitivity();
    try testing.expect(sensitivity.before.word_boundary);
    try testing.expect(sensitivity.before.line_anchor);
    try testing.expect(sensitivity.after.word_boundary);
}

test "SlidingWindow whole-word regex accepts hard newline page boundary" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .forward, "boo", .{
        .whole_word = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    try s.testWriteString("tail");
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("boo ok");

    const second_node: *PageList.List.Node = s.pages.pages.first.?.next.?;
    _ = try w.append(second_node);

    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(second_node, sel.start.node);
    try testing.expectEqual(second_node, sel.end.node);
}

test "SlidingWindow reverse search works with non-default query options" {
    const testing = std.testing;
    const alloc = testing.allocator;
    if (comptime !build_options.oniguruma) {
        try testing.expectError(
            error.UnsupportedQueryOptions,
            SlidingWindow.initWithOptions(alloc, .reverse, "boo!", .{
                .case_sensitive = true,
            }),
        );
        return;
    }

    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .reverse, "boo!", .{
        .case_sensitive = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 19,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start).?);
    try testing.expectEqual(point.Point{ .active = .{
        .x = 22,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end).?);
}

test "SlidingWindow reverse regex searches UTF-8 haystack in forward order" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var w: SlidingWindow = try .initWithOptions(alloc, .reverse, "caf.", .{
        .regex = true,
    });
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("caf\xc3\xa9 one caf\xc3\xa9");

    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    const h = (try w.next()).?;
    const sel = h.untracked();
    try testing.expectEqual(point.Point{ .active = .{
        .x = 9,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.start).?);
    try testing.expectEqual(point.Point{ .active = .{
        .x = 12,
        .y = 0,
    } }, s.pages.pointFromPin(.active, sel.end).?);
}

test "SlidingWindow single append single char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // No matches
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find two matches
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow two pages single char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find two matches
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow two pages match across boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find a match
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // We shouldn't prune because we don't have enough space
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow two pages no match across boundary with newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should NOT find a match
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // We shouldn't prune because we don't have enough space
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow two pages no match across boundary with newline reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should NOT find a match
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow two pages no match prunes first page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find nothing
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // We should've pruned our page because the second page
    // has enough text to contain our needle.
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match keeps both pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Imaginary needle for search. Doesn't match!
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    var w: SlidingWindow = try .init(alloc, .forward, needle);
    defer w.deinit();

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find nothing
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow single append across circular buffer boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "abc");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect((try w.next()) == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    w.testChangeNeedle("boo");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append match on boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "abcd");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");

    // We need to surgically modify the last row to be soft-wrapped
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.data.getRow(node.data.size.rows - 1).wrap = true;

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect((try w.next()) == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    w.testChangeNeedle("boo!");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append no match reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // No matches
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find two matches (in reverse order)
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow two pages match across boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "hell"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find a match
    {
        const h = (try w.next()).?;
        const chunks = h.chunks.slice();
        const nodes = chunks.items(.node);
        const serials = chunks.items(.serial);
        try testing.expectEqual(2, chunks.len);
        try testing.expectEqual(node, nodes[0]);
        try testing.expectEqual(node.serial, serials[0]);
        try testing.expectEqual(node.next.?, nodes[1]);
        try testing.expectEqual(node.next.?.serial, serials[1]);

        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // In reverse mode, the last appended meta (first original page) is large
    // enough to contain needle.len - 1 bytes, so pruning occurs
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match prunes first page reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find nothing
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // We should've pruned our page because the second page
    // has enough text to contain our needle.
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match keeps both pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Imaginary needle for search. Doesn't match!
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    var w: SlidingWindow = try .init(alloc, .reverse, needle);
    defer w.deinit();

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find nothing
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow single append across circular buffer boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "abc");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect((try w.next()) == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    // testChangeNeedle doesn't reverse, so pass reversed needle for reverse mode
    w.testChangeNeedle("oob");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append match on boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "abcd");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");

    // We need to surgically modify the last row to be soft-wrapped
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.data.getRow(node.data.size.rows - 1).wrap = true;

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect((try w.next()) == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    // testChangeNeedle doesn't reverse, so pass reversed needle for reverse mode
    w.testChangeNeedle("!oob");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var t: Terminal = try .init(alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nxxboo!\r\nC");

    // We want to test single-page cases.
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

test "SlidingWindow single append reversed soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var t: Terminal = try .init(alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A\r\nxxboo!\r\nC");

    // We want to test single-page cases.
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = (try w.next()).?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect((try w.next()) == null);
    try testing.expect((try w.next()) == null);
}

// This tests a real bug that occurred where a whitespace-only page
// that encodes to zero bytes would crash.
test "SlidingWindow append whitespace only node" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "x");
    defer w.deinit();

    var s = try Screen.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 0,
    });
    defer s.deinit();

    // By setting the empty page to wrap we get a zero-byte page.
    // This is invasive but its otherwise hard to reproduce naturally
    // without creating a slow test.
    const node: *PageList.List.Node = s.pages.pages.first.?;
    const last_row = node.data.getRow(node.data.size.rows - 1);
    last_row.wrap = true;

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    _ = try w.append(node);

    // No matches expected
    try testing.expect((try w.next()) == null);
}
