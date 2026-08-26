//! Lean SSH host ingestion (C20).
//!
//! Parses `%USERPROFILE%\.ssh\config` Host lines into launchable names.
//! Wildcard hosts (`*`, `?`) are skipped. No bundled client, no vault.

const std = @import("std");

pub const max_hosts = 64;

pub const Host = struct {
    name: []const u8,
};

pub fn parseConfig(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |name| alloc.free(name);
        list.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trimComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len < 5) continue;
        if (!startsWithIgnoreCase(line, "host")) continue;
        const rest = std.mem.trim(u8, line["host".len..], " \t");
        if (rest.len == 0) continue;

        var tokens = std.mem.tokenizeAny(u8, rest, " \t");
        while (tokens.next()) |token| {
            if (isWildcard(token)) continue;
            if (contains(list.items, token)) continue;
            if (list.items.len >= max_hosts) break;
            try list.append(alloc, try alloc.dupe(u8, token));
        }
    }

    return try list.toOwnedSlice(alloc);
}

fn trimComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return std.mem.trimRight(u8, line[0..hash], " \t");
}

fn startsWithIgnoreCase(line: []const u8, prefix: []const u8) bool {
    if (line.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix) and
        (line.len == prefix.len or std.ascii.isWhitespace(line[prefix.len]));
}

fn isWildcard(token: []const u8) bool {
    return std.mem.indexOfScalar(u8, token, '*') != null or
        std.mem.indexOfScalar(u8, token, '?') != null;
}

pub fn isSafeHost(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (isWildcard(name)) return false;
    for (name) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '-', '_' => {},
            else => return false,
        }
    }
    return true;
}

fn contains(items: []const []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

test "parseConfig skips wildcards and comments" {
    const testing = std.testing;
    const text =
        \\# comment
        \\Host github.com
        \\  User git
        \\Host *.internal work?
        \\Host jump bastion
        \\host gitlab.com
    ;
    const hosts = try parseConfig(testing.allocator, text);
    defer {
        for (hosts) |name| testing.allocator.free(name);
        testing.allocator.free(hosts);
    }
    try testing.expectEqual(@as(usize, 4), hosts.len);
    try testing.expectEqualStrings("github.com", hosts[0]);
    try testing.expectEqualStrings("jump", hosts[1]);
    try testing.expectEqualStrings("bastion", hosts[2]);
    try testing.expectEqualStrings("gitlab.com", hosts[3]);
}

test "isSafeHost rejects metacharacters" {
    try std.testing.expect(isSafeHost("github.com"));
    try std.testing.expect(isSafeHost("jump_1"));
    try std.testing.expect(!isSafeHost(""));
    try std.testing.expect(!isSafeHost("*.internal"));
    try std.testing.expect(!isSafeHost("host;rm"));
    try std.testing.expect(!isSafeHost("host name"));
}
