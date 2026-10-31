//! The matcher behind a `SlidingWindow` for the queries upstream's ASCII
//! case-insensitive literal scan does not cover: a regular expression,
//! whole-word or case-sensitive matching, run through oniguruma. A window
//! without a pattern runs the literal scan.
//!
//! One pattern serves every window of one query, so all of them must run
//! on one thread (the search thread): the failure latch and the match
//! limits are shared.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const tripwire = @import("../../tripwire.zig");
const build_options = @import("terminal_options");
const query_options = @import("query_options.zig");
const Query = query_options.Query;
const QueryOptions = query_options.QueryOptions;
const oni = if (build_options.oniguruma) @import("oniguruma") else struct {};

const log = std.log.scoped(.search_pattern);

/// Where a test can make the engine fail at run time.
pub const find_tw = tripwire.module(enum { search }, Pattern.Failure);

pub const Pattern = struct {
    /// The regex source: the needle escaped unless it is a regex, wrapped
    /// in word boundaries for whole-word matching.
    source: []u8,
    regex: if (build_options.oniguruma) oni.Regex else void,

    /// The engine's limits for each search: oniguruma's defaults.
    match_param: if (build_options.oniguruma) oni.MatchParam else void,

    needle_len: usize,
    options: QueryOptions,

    /// The first run-time failure. From then on `find` finds nothing.
    failed: ?Failure = null,

    /// Which edges of a haystack the pattern can tell apart from text
    /// beyond them, parsed once from `source`.
    sensitivity: EdgeSensitivity,

    pub const CompileError = Allocator.Error || error{
        /// Oniguruma rejects the pattern.
        InvalidPattern,

        /// Non-default options in a build without oniguruma.
        UnsupportedQueryOptions,
    };

    /// A run-time matcher failure: a retry or stack limit, oniguruma
    /// running out of memory, or any other engine error.
    pub const Failure = error{ RetryLimit, StackLimit, Memory, Engine };

    /// Regexes can be arbitrary-width. Keep a generous bounded suffix on
    /// no-match scans so large scrollback cannot accumulate in the sliding
    /// window forever.
    pub const regex_no_match_retain_len = 64 * 1024;

    /// What lies just outside one end of a haystack.
    pub const Edge = union(enum) {
        /// The real end of the text.
        none,

        /// The byte next to the haystack.
        byte: u8,

        /// More text whose byte is not known.
        unknown,
    };

    pub const Haystack = struct {
        /// Contiguous text in screen order.
        text: []const u8,
        before: Edge,
        after: Edge,

        /// A forward window wants the first match, a reverse one the last.
        pick: enum { first, last },
    };

    /// A match in `Haystack.text`; `len` is never zero.
    pub const Span = struct { start: usize, len: usize };

    /// Compile a query. Null means upstream's literal scan already does it
    /// (default options). The pattern text is never logged.
    pub fn forQuery(alloc: Allocator, query: Query) CompileError!?*Pattern {
        if (query.options.isDefault()) return null;
        if (comptime !build_options.oniguruma) return error.UnsupportedQueryOptions;

        const source = try buildSource(alloc, query);
        errdefer alloc.free(source);

        var regex = oni.Regex.init(
            source,
            .{
                .ignorecase = !query.options.case_sensitive,
                .word_is_ascii = true,
            },
            oni.Encoding.utf8,
            oni.Syntax.default,
            null,
        ) catch |err| switch (err) {
            // Oniguruma could not allocate, which says nothing about the
            // pattern.
            error.Memory => return error.OutOfMemory,
            else => {
                log.warn("search pattern does not compile err={}", .{err});
                return error.InvalidPattern;
            },
        };
        errdefer regex.deinit();

        var match_param = oni.MatchParam.init() catch return error.OutOfMemory;
        errdefer match_param.deinit();

        const self = try alloc.create(Pattern);
        self.* = .{
            .source = source,
            .regex = regex,
            .match_param = match_param,
            .needle_len = query.needle.len,
            .options = query.options,
            .sensitivity = .parse(source),
        };
        return self;
    }

    pub fn destroy(self: *Pattern, alloc: Allocator) void {
        if (comptime build_options.oniguruma) {
            self.match_param.deinit();
            self.regex.deinit();
        }
        alloc.free(self.source);
        alloc.destroy(self);
    }

    /// The match `h.pick` asks for. A match that touches an edge the
    /// pattern is sensitive to is skipped unless that edge is the real end
    /// of the text or its byte allows the match there.
    ///
    /// A run-time failure is latched (see `failure`) and finds nothing, here
    /// and in every later call. This never allocates through a Zig
    /// allocator; oniguruma's own allocations can fail, which latches
    /// `Memory`.
    pub fn find(self: *Pattern, h: Haystack) ?Span {
        if (comptime !build_options.oniguruma) unreachable;
        if (self.failed != null) return null;

        var search_start: usize = 0;
        var found: ?Span = null;
        while (search_start <= h.text.len) {
            var region: oni.Region = .{};
            defer region.deinit();

            self.search(h.text, search_start, &region) catch |err| switch (err) {
                error.Mismatch => break,
                else => |failure_| {
                    log.warn("search pattern failed err={}", .{failure_});
                    self.failed = failure_;
                    return null;
                },
            };

            const starts = region.starts();
            const ends = region.ends();
            if (starts.len == 0 or ends.len == 0) break;

            const start: usize = @intCast(starts[0]);
            const end: usize = @intCast(ends[0]);
            if (end <= start or self.touchesSyntheticEdge(h, start, end)) {
                search_start = start + 1;
                continue;
            }

            found = .{ .start = start, .len = end - start };
            if (h.pick == .first) break;
            search_start = start + 1;
        }

        return found;
    }

    /// The first run-time failure, if the pattern has failed.
    pub fn failure(self: *const Pattern) ?Failure {
        return self.failed;
    }

    /// The suffix a window keeps after a scan finds nothing, so a match
    /// that continues into the next page is still found.
    pub fn retainLen(self: *const Pattern) usize {
        if (self.needle_len == 0) return 0;

        if (self.options.regex) {
            return @max(self.needle_len + 1, regex_no_match_retain_len);
        }

        if (self.options.whole_word) {
            // A literal whole-word match at the end of the current window may
            // need left context and the next page's first byte to validate
            // word boundaries.
            return self.needle_len + 1;
        }

        return self.needle_len - 1;
    }

    fn search(
        self: *Pattern,
        text: []const u8,
        start: usize,
        region: *oni.Region,
    ) (Failure || error{Mismatch})!void {
        try find_tw.check(.search);
        _ = self.regex.searchAdvancedWithParam(text, start, text.len, region, .{
            .find_not_empty = true,
        }, &self.match_param) catch |err| return switch (err) {
            error.Mismatch => error.Mismatch,
            error.RetryLimitInMatchOver,
            error.RetryLimitInSearchOver,
            error.SubexpCallLimitInSearchOver,
            => error.RetryLimit,
            error.MatchStackLimitOver => error.StackLimit,
            error.Memory => error.Memory,
            else => error.Engine,
        };
    }

    /// Only for tests!
    fn testSetSearchRetryLimit(self: *Pattern, limit: usize) !void {
        try self.match_param.setRetryLimitInSearch(limit);
    }

    fn touchesSyntheticEdge(self: *const Pattern, h: Haystack, start: usize, end: usize) bool {
        if (start == 0 and
            self.sensitivity.before.any() and
            rejects(h.before, self.sensitivity.before, h.text[0]))
        {
            return true;
        }
        if (end == h.text.len and
            self.sensitivity.after.any() and
            rejects(h.after, self.sensitivity.after, h.text[h.text.len - 1]))
        {
            return true;
        }
        return false;
    }

    fn rejects(edge: Edge, context: EdgeContext, edge_byte: u8) bool {
        return switch (edge) {
            .none => false,
            .unknown => true,
            .byte => |byte| context.absolute_anchor or
                (context.line_anchor and byte != '\n') or
                (context.word_boundary and !isAsciiWordBoundary(byte, edge_byte)),
        };
    }

    fn isAsciiWordBoundary(a: u8, b: u8) bool {
        return isAsciiWordByte(a) != isAsciiWordByte(b);
    }

    fn isAsciiWordByte(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn buildSource(alloc: Allocator, query: Query) Allocator.Error![]u8 {
        const base = if (query.options.regex)
            try alloc.dupe(u8, query.needle)
        else
            try escapeRegexLiteral(alloc, query.needle);
        errdefer alloc.free(base);

        if (!query.options.whole_word) return base;
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

    const EdgeContext = struct {
        word_boundary: bool = false,
        line_anchor: bool = false,
        absolute_anchor: bool = false,

        fn any(self: EdgeContext) bool {
            return self.word_boundary or self.line_anchor or self.absolute_anchor;
        }
    };

    const EdgeSensitivity = struct {
        before: EdgeContext = .{},
        after: EdgeContext = .{},

        fn parse(pattern: []const u8) EdgeSensitivity {
            var sensitivity: EdgeSensitivity = .{};
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
                        if (dollarIsLineAnchor(pattern, i)) {
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

        /// A `$` anchors the end of a line only where its alternative
        /// ends: at the end of the pattern or before `|` or `)`.
        fn dollarIsLineAnchor(pattern: []const u8, dollar_i: usize) bool {
            const rest = pattern[dollar_i + 1 ..];
            return rest.len == 0 or rest[0] == '|' or rest[0] == ')';
        }
    };
};

/// Only for tests! Compile `query`, which must not be a default (literal)
/// query.
pub fn testPattern(query: Query) !*Pattern {
    try oni.testing.ensureInit();
    return (try Pattern.forQuery(testing.allocator, query)).?;
}

/// `find` over `text` with the given edges, picking the first match.
fn testFind(p: *Pattern, text: []const u8, before: Pattern.Edge, after: Pattern.Edge) ?Pattern.Span {
    return p.find(.{ .text = text, .before = before, .after = after, .pick = .first });
}

test "forQuery returns null for default options" {
    try testing.expectEqual(null, try Pattern.forQuery(testing.allocator, .{ .needle = "boo" }));
}

test "forQuery rejects non-default options without oniguruma" {
    if (comptime build_options.oniguruma) return error.SkipZigTest;

    try testing.expectError(error.UnsupportedQueryOptions, Pattern.forQuery(testing.allocator, .{
        .needle = "boo",
        .options = .{ .case_sensitive = true },
    }));
}

test "forQuery reports InvalidPattern" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;
    try oni.testing.ensureInit();

    try testing.expectError(error.InvalidPattern, Pattern.forQuery(testing.allocator, .{
        .needle = "[",
        .options = .{ .regex = true },
    }));
}

test "regex edge sensitivity detects anchors and character classes" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;
    const alloc = testing.allocator;
    const whole: Pattern.Span = .{ .start = 0, .len = 3 };

    // Absolute start anchors reject any text before the haystack, known or
    // not, and leave the end alone.
    for ([_][]const u8{ "\\Afoo", "\\Gfoo" }) |source| {
        const p = try testPattern(.{ .needle = source, .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(whole, (testFind(p, "foo", .none, .unknown)).?);
        try testing.expectEqual(null, testFind(p, "foo", .{ .byte = '\n' }, .none));
        try testing.expectEqual(null, testFind(p, "foo", .{ .byte = 'x' }, .none));
        try testing.expectEqual(null, testFind(p, "foo", .unknown, .none));
    }

    // Absolute end anchors, the other way around.
    for ([_][]const u8{ "foo\\Z", "foo\\z" }) |source| {
        const p = try testPattern(.{ .needle = source, .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(whole, (testFind(p, "foo", .unknown, .none)).?);
        try testing.expectEqual(null, testFind(p, "foo", .none, .{ .byte = '\n' }));
        try testing.expectEqual(null, testFind(p, "foo", .none, .{ .byte = 'x' }));
        try testing.expectEqual(null, testFind(p, "foo", .none, .unknown));
    }

    // A word boundary anywhere makes both edges depend on the byte there.
    {
        const p = try testPattern(.{ .needle = "\\bfoo", .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(whole, (testFind(p, "foo", .none, .none)).?);
        try testing.expectEqual(whole, (testFind(p, "foo", .{ .byte = '\n' }, .{ .byte = ' ' })).?);
        try testing.expectEqual(null, testFind(p, "foo", .{ .byte = 'x' }, .none));
        try testing.expectEqual(null, testFind(p, "foo", .unknown, .none));
        try testing.expectEqual(null, testFind(p, "foo", .none, .{ .byte = 'x' }));
        try testing.expectEqual(null, testFind(p, "foo", .none, .unknown));
    }

    // Anchors inside a character class are bytes, so no edge matters.
    {
        const p = try testPattern(.{ .needle = "[^$^]+", .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(whole, (testFind(p, "foo", .unknown, .unknown)).?);
        try testing.expectEqual(whole, (testFind(p, "foo", .{ .byte = 'x' }, .{ .byte = 'x' })).?);
    }

    // Line anchors accept a newline or the real end on each side.
    {
        const p = try testPattern(.{ .needle = "^foo$", .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(whole, (testFind(p, "foo", .none, .none)).?);
        try testing.expectEqual(whole, (testFind(p, "foo", .{ .byte = '\n' }, .{ .byte = '\n' })).?);
        try testing.expectEqual(null, testFind(p, "foo", .{ .byte = 'x' }, .none));
        try testing.expectEqual(null, testFind(p, "foo", .unknown, .none));
        try testing.expectEqual(null, testFind(p, "foo", .none, .{ .byte = 'x' }));
        try testing.expectEqual(null, testFind(p, "foo", .none, .unknown));
    }
}

test "regex edge sensitivity ignores literal anchor bytes" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;
    const alloc = testing.allocator;

    // `^` after other text and `$` before it anchor inside the match, not at
    // the haystack's edges.
    for ([_][]const u8{ "a\\n^b", "a$\\nb" }) |source| {
        const p = try testPattern(.{ .needle = source, .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(
            Pattern.Span{ .start = 0, .len = 3 },
            (testFind(p, "a\nb", .unknown, .unknown)).?,
        );
    }

    // A literal query escapes them.
    {
        const text = "foo^bar price$usd";
        const p = try testPattern(.{ .needle = text, .options = .{ .case_sensitive = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(
            Pattern.Span{ .start = 0, .len = text.len },
            (testFind(p, text, .unknown, .unknown)).?,
        );
    }

    // An alternative starts a pattern for `^` and ends one for `$`.
    {
        const p = try testPattern(.{ .needle = "foo|^bar", .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(null, testFind(p, "bar", .{ .byte = 'x' }, .unknown));
        try testing.expect(testFind(p, "bar", .{ .byte = '\n' }, .unknown) != null);
    }
    {
        const p = try testPattern(.{ .needle = "foo$|bar", .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(null, testFind(p, "foo", .unknown, .{ .byte = 'x' }));
        try testing.expect(testFind(p, "foo", .unknown, .{ .byte = '\n' }) != null);
    }
    {
        const p = try testPattern(.{ .needle = "(?:^bar$)", .options = .{ .regex = true } });
        defer p.destroy(alloc);
        try testing.expectEqual(null, testFind(p, "bar", .unknown, .none));
        try testing.expectEqual(null, testFind(p, "bar", .none, .unknown));
        try testing.expect(testFind(p, "bar", .{ .byte = '\n' }, .{ .byte = '\n' }) != null);
    }
}

test "whole-word regex edge sensitivity preserves embedded anchors" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;
    const alloc = testing.allocator;

    const p = try testPattern(.{ .needle = "^boo", .options = .{ .regex = true, .whole_word = true } });
    defer p.destroy(alloc);
    const whole: Pattern.Span = .{ .start = 0, .len = 3 };
    try testing.expectEqual(whole, (testFind(p, "boo", .none, .none)).?);
    try testing.expectEqual(whole, (testFind(p, "boo", .{ .byte = '\n' }, .{ .byte = ' ' })).?);

    // A space is a word boundary but not a line start: the `^` survived the
    // whole-word wrap.
    try testing.expectEqual(null, testFind(p, "boo", .{ .byte = ' ' }, .none));
    try testing.expectEqual(null, testFind(p, "boo", .unknown, .none));
    try testing.expectEqual(null, testFind(p, "boo", .none, .{ .byte = 'x' }));
    try testing.expectEqual(null, testFind(p, "boo", .none, .unknown));
}

test "a run-time failure latches and finds nothing" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;
    const alloc = testing.allocator;

    // Nested quantifiers backtrack over every way to split the run of `a`.
    // The pattern needs no literal (`(a*)*b` over text without a `b` fails
    // before it backtracks: oniguruma looks for the `b` first).
    const text = "aaaaaaaaaaaaaaaac";
    const query: Query = .{ .needle = "(a+)+$", .options = .{ .regex = true } };

    // The positive control: with oniguruma's default limits the scan ends
    // with no match and no failure.
    {
        const p = try testPattern(query);
        defer p.destroy(alloc);
        try testing.expectEqual(null, testFind(p, text, .none, .none));
        try testing.expectEqual(null, p.failure());
        try testing.expectEqual(
            Pattern.Span{ .start = 0, .len = 3 },
            testFind(p, "aaa", .none, .none).?,
        );
    }

    const p = try testPattern(query);
    defer p.destroy(alloc);
    try p.testSetSearchRetryLimit(100);
    try testing.expectEqual(null, testFind(p, text, .none, .none));
    try testing.expectEqual(@as(?Pattern.Failure, error.RetryLimit), p.failure());

    // Latched: text the pattern does match now finds nothing too.
    try testing.expectEqual(null, testFind(p, "aaa", .none, .none));
    try testing.expectEqual(@as(?Pattern.Failure, error.RetryLimit), p.failure());

    // The same limit leaves a pattern that does not backtrack matching.
    const simple = try testPattern(.{ .needle = "a*b", .options = .{ .regex = true } });
    defer simple.destroy(alloc);
    try simple.testSetSearchRetryLimit(100);
    try testing.expectEqual(
        Pattern.Span{ .start = 0, .len = 2 },
        testFind(simple, "ab", .none, .none).?,
    );
    try testing.expectEqual(null, simple.failure());
}
