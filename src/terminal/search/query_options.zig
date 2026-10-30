const std = @import("std");

pub const QueryOptions = packed struct {
    regex: bool = false,
    case_sensitive: bool = false,
    whole_word: bool = false,
    _padding: u5 = 0,

    pub fn eql(self: QueryOptions, other: QueryOptions) bool {
        return self.regex == other.regex and
            self.case_sensitive == other.case_sensitive and
            self.whole_word == other.whole_word;
    }

    pub fn isDefault(self: QueryOptions) bool {
        return !self.regex and !self.case_sensitive and !self.whole_word;
    }
};

/// A needle and the options it is searched with. The needle is borrowed.
pub const Query = struct {
    needle: []const u8,
    options: QueryOptions = .{},

    /// Whether two queries give the same results on the same text.
    pub fn eql(a: Query, b: Query) bool {
        if (!a.options.eql(b.options)) return false;

        if (b.options.regex or b.options.case_sensitive) {
            return std.mem.eql(u8, a.needle, b.needle);
        }

        // Whole-word without explicit case sensitivity still uses the regex
        // engine's ignorecase path, so equivalent queries are ASCII-insensitive.
        return std.ascii.eqlIgnoreCase(a.needle, b.needle);
    }
};

test "Query.eql is byte-exact only for regex and case-sensitive queries" {
    const testing = std.testing;

    try testing.expect(Query.eql(.{ .needle = "Boo" }, .{ .needle = "bOO" }));
    try testing.expect(!Query.eql(.{ .needle = "boo" }, .{ .needle = "boo!" }));
    try testing.expect(Query.eql(
        .{ .needle = "Boo", .options = .{ .whole_word = true } },
        .{ .needle = "bOO", .options = .{ .whole_word = true } },
    ));
    for ([_]QueryOptions{
        .{ .regex = true },
        .{ .case_sensitive = true },
        .{ .regex = true, .whole_word = true },
        .{ .case_sensitive = true, .whole_word = true },
    }) |options| {
        try testing.expect(Query.eql(
            .{ .needle = "Boo", .options = options },
            .{ .needle = "Boo", .options = options },
        ));
        try testing.expect(!Query.eql(
            .{ .needle = "Boo", .options = options },
            .{ .needle = "boo", .options = options },
        ));
    }

    // The same needle under other options is another query.
    try testing.expect(!Query.eql(
        .{ .needle = "boo" },
        .{ .needle = "boo", .options = .{ .whole_word = true } },
    ));
}
