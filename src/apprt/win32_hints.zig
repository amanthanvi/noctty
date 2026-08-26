//! Keyboard hints over visible text (C18).
//!
//! Default patterns: URLs, Windows paths, git SHAs, IPv4. `select_hint`
//! cycles matches and copies the current one (banner feedback). No
//! user-facing pattern knob until a settings field ships.

const std = @import("std");

pub const Kind = enum { url, path, hash, ipv4 };

pub const Match = struct {
    start: usize,
    end: usize,
    kind: Kind,
};

pub const max_matches = 32;

pub fn findMatches(text: []const u8, out: []Match) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len and count < out.len and count < max_matches) {
        if (matchUrl(text, i)) |end| {
            out[count] = .{ .start = i, .end = end, .kind = .url };
            count += 1;
            i = end;
            continue;
        }
        if (matchPath(text, i)) |end| {
            out[count] = .{ .start = i, .end = end, .kind = .path };
            count += 1;
            i = end;
            continue;
        }
        if (matchHash(text, i)) |end| {
            out[count] = .{ .start = i, .end = end, .kind = .hash };
            count += 1;
            i = end;
            continue;
        }
        if (matchIpv4(text, i)) |end| {
            out[count] = .{ .start = i, .end = end, .kind = .ipv4 };
            count += 1;
            i = end;
            continue;
        }
        i += 1;
    }
    return count;
}

fn matchUrl(text: []const u8, start: usize) ?usize {
    const prefixes = [_][]const u8{ "https://", "http://" };
    for (prefixes) |prefix| {
        if (start + prefix.len > text.len) continue;
        if (!std.mem.eql(u8, text[start .. start + prefix.len], prefix)) continue;
        var end = start + prefix.len;
        while (end < text.len and isUrlByte(text[end])) end += 1;
        if (end > start + prefix.len) return end;
    }
    return null;
}

fn matchPath(text: []const u8, start: usize) ?usize {
    if (start + 3 > text.len) return null;
    if (!std.ascii.isAlphabetic(text[start])) return null;
    if (text[start + 1] != ':' or (text[start + 2] != '\\' and text[start + 2] != '/')) return null;
    var end = start + 3;
    while (end < text.len and isPathByte(text[end])) end += 1;
    if (end > start + 3) return end;
    return null;
}

fn matchHash(text: []const u8, start: usize) ?usize {
    if (start > 0 and std.ascii.isAlphanumeric(text[start - 1])) return null;
    var end = start;
    while (end < text.len and isHex(text[end])) end += 1;
    const len = end - start;
    if (len < 7 or len > 40) return null;
    if (end < text.len and std.ascii.isAlphanumeric(text[end])) return null;
    return end;
}

fn matchIpv4(text: []const u8, start: usize) ?usize {
    if (start > 0 and std.ascii.isDigit(text[start - 1])) return null;
    var pos = start;
    var octets: u8 = 0;
    while (octets < 4) : (octets += 1) {
        const next = parseOctet(text, pos) orelse return null;
        pos = next;
        if (octets < 3) {
            if (pos >= text.len or text[pos] != '.') return null;
            pos += 1;
        }
    }
    if (pos < text.len and (std.ascii.isDigit(text[pos]) or text[pos] == '.')) return null;
    return pos;
}

fn parseOctet(text: []const u8, start: usize) ?usize {
    if (start >= text.len or !std.ascii.isDigit(text[start])) return null;
    var value: u16 = 0;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {
        value = value * 10 + (text[end] - '0');
        if (value > 255) return null;
        if (end - start >= 3) break;
    }
    if (end == start) return null;
    return end;
}

fn isUrlByte(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '/', '?', '=', '&', '%', ':', '~', '+' => true,
        else => false,
    };
}

fn isPathByte(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '\\', '/', '.', '-', '_' => true,
        else => false,
    };
}

fn isHex(c: u8) bool {
    return switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => true,
        else => false,
    };
}

test "findMatches classifies url path hash ipv4" {
    const text = "see https://example.com/a and C:\\src\\app.exe sha deadbeef and 10.0.0.1 done";
    var matches: [8]Match = undefined;
    const n = findMatches(text, &matches);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(Kind.url, matches[0].kind);
    try std.testing.expectEqualStrings("https://example.com/a", text[matches[0].start..matches[0].end]);
    try std.testing.expectEqual(Kind.path, matches[1].kind);
    try std.testing.expectEqual(Kind.hash, matches[2].kind);
    try std.testing.expectEqual(Kind.ipv4, matches[3].kind);
}
