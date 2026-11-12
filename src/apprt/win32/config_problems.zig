//! What a config load found wrong, in the words the banner and the Settings
//! page use.
//!
//! `Config._diagnostics` lives in the config's arena and a reload frees it, and
//! a missing font is known only to the font set. `Problems` keeps its own copy
//! of the text, so the banner and the Settings page can read it for as long as
//! the app runs. No Win32 here, so the text builders are unit-testable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostics = @import("../../cli/diagnostics.zig");

/// The longest the first problem may run in the banner, which is one line
/// beside a close button. The list in Settings has the full text.
const max_banner_bytes = 100;

/// The longest one entry may run in the Settings list.
const max_entry_bytes = 220;

const ellipsis = "\u{2026}";

pub const Problems = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        /// `key: message`, without the file and line: for the banner.
        brief: []u8,
        /// `key: message (file:line)`: for the list. The place goes last, so
        /// that a cut entry loses the end of a long path and not the problem.
        full: []u8,
    };

    pub fn deinit(self: *Problems, alloc: Allocator) void {
        self.clear(alloc);
        self.entries.deinit(alloc);
    }

    pub fn clear(self: *Problems, alloc: Allocator) void {
        for (self.entries.items) |entry| {
            alloc.free(entry.brief);
            alloc.free(entry.full);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn count(self: *const Problems) usize {
        return self.entries.items.len;
    }

    /// A hash of what the list says, to tell whether a load found something
    /// other than the one before.
    pub fn fingerprint(self: *const Problems) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (self.entries.items) |entry| {
            hasher.update(entry.full);
            hasher.update("\n");
        }
        return hasher.final();
    }

    /// Take a copy of each diagnostic of a config load.
    pub fn addDiagnostics(
        self: *Problems,
        alloc: Allocator,
        items: []const diagnostics.Diagnostic,
    ) Allocator.Error!void {
        for (items) |diag| {
            const brief = if (diag.key.len > 0)
                try std.fmt.allocPrint(alloc, "{s}: {s}", .{ diag.key, diag.message })
            else
                try alloc.dupe(u8, diag.message);
            errdefer alloc.free(brief);
            const full = switch (diag.location) {
                .none => try alloc.dupe(u8, brief),
                .cli => |index| try std.fmt.allocPrint(alloc, "{s} (command line argument {d})", .{ brief, index }),
                .file => |file| try std.fmt.allocPrint(alloc, "{s} ({s}:{d})", .{ brief, file.path, file.line }),
            };
            errdefer alloc.free(full);
            try self.append(alloc, brief, full);
        }
    }

    /// A configured font family no installed font matched. Once per family,
    /// however many tabs and windows use it.
    pub fn addMissingFont(self: *Problems, alloc: Allocator, family: []const u8) Allocator.Error!void {
        const text = try std.fmt.allocPrint(
            alloc,
            "font-family: \"{s}\" was not found; other configured or built-in fonts are used",
            .{family},
        );
        errdefer alloc.free(text);
        // As stored: a name with bytes `append` would replace must still find
        // its earlier copy.
        sanitize(text);
        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.full, text)) {
                alloc.free(text);
                return;
            }
        }
        const full = try alloc.dupe(u8, text);
        errdefer alloc.free(full);
        try self.append(alloc, text, full);
    }

    /// Keeps both strings on success; on failure the caller still owns them.
    fn append(self: *Problems, alloc: Allocator, brief: []u8, full: []u8) Allocator.Error!void {
        sanitize(brief);
        sanitize(full);
        try self.entries.append(alloc, .{ .brief = brief, .full = full });
    }

    /// The banner's line: how many problems there are, the first one, and
    /// where the rest are. Null when there are none. Owned.
    pub fn bannerText(self: *const Problems, alloc: Allocator) Allocator.Error!?[]u8 {
        if (self.entries.items.len == 0) return null;
        const first = self.entries.items[0].brief;
        const shown = first[0..utf8PrefixLen(first, max_banner_bytes)];
        const cut: []const u8 = if (shown.len < first.len) ellipsis else "";
        const where = "See Config problems in the command palette.";
        if (self.entries.items.len == 1) {
            return try std.fmt.allocPrint(alloc, "Config problem: {s}{s}. {s}", .{ shown, cut, where });
        }
        return try std.fmt.allocPrint(alloc, "{d} config problems: {s}{s}. {s}", .{ self.entries.items.len, shown, cut, where });
    }

    /// The Settings page's list, numbered, in `buf`. Whole entries only: what
    /// does not fit is counted in a closing line, and so is an entry that was
    /// cut short.
    pub fn listText(self: *const Problems, buf: []u8) []const u8 {
        var len: usize = 0;
        if (self.entries.items.len == 0) {
            appendWhole(buf, &len, "No problems were found when the config was last loaded.\n");
            return buf[0..len];
        }

        var line_buf: [max_entry_bytes + 32]u8 = undefined;
        const heading = std.fmt.bufPrint(
            &line_buf,
            "Config problems ({d}):\n",
            .{self.entries.items.len},
        ) catch unreachable;
        appendWhole(buf, &len, heading);

        // Room for the closing line, which says how many are not listed.
        const closing_bytes = 96;
        const budget = buf.len -| closing_bytes;
        var listed: usize = 0;
        var any_cut = false;
        for (self.entries.items, 1..) |entry, number| {
            const full = entry.full[0..utf8PrefixLen(entry.full, max_entry_bytes)];
            const cut: []const u8 = if (full.len < entry.full.len) ellipsis else "";
            const line = std.fmt.bufPrint(&line_buf, "{d}. {s}{s}\n", .{ number, full, cut }) catch break;
            if (len + line.len > budget) break;
            appendWhole(buf, &len, line);
            listed += 1;
            any_cut = any_cut or cut.len > 0;
        }
        if (listed < self.entries.items.len) {
            const closing = std.fmt.bufPrint(
                &line_buf,
                "...and {d} more. Run koreterm +validate-config for the full list.\n",
                .{self.entries.items.len - listed},
            ) catch unreachable;
            appendWhole(buf, &len, closing);
        } else if (any_cut) {
            appendWhole(buf, &len, "Run koreterm +validate-config for the full text.\n");
        }
        return buf[0..len];
    }
};

/// One line of valid UTF-8: a stray line break would break the banner's one
/// line and the list's numbering.
fn sanitize(text: []u8) void {
    for (text) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    replaceInvalidUtf8(text);
}

/// Put `?` for each byte of `text` that is not part of a valid UTF-8
/// sequence. A config file is any bytes (Notepad's "ANSI" saves Latin-1), a
/// diagnostic can carry them, and the Win32 text calls here turn a string
/// that is not valid UTF-8 into an empty one: the banner or the whole
/// Advanced page would go blank.
pub fn replaceInvalidUtf8(text: []u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (len == 0 or i + len > text.len or !std.unicode.utf8ValidateSlice(text[i..][0..len])) {
            text[i] = '?';
            i += 1;
        } else {
            i += len;
        }
    }
}

/// Copy `text` after `len` bytes of `buf` only if all of it fits.
pub fn appendWhole(buf: []u8, len: *usize, text: []const u8) void {
    if (len.* + text.len > buf.len) return;
    @memcpy(buf[len.*..][0..text.len], text);
    len.* += text.len;
}

/// The longest prefix of `text`, at most `max` bytes, that ends between
/// characters.
fn utf8PrefixLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var len = max;
    // A continuation byte is 10xxxxxx; back up to the start of the character.
    while (len > 0 and text[len] & 0xC0 == 0x80) len -= 1;
    return len;
}

/// A copy of `path` in `buf` (at least `max` + 3 bytes), cut from the front to
/// at most `max` bytes and marked with an ellipsis when it is longer: the end
/// of a long path is what tells files apart.
pub fn pathTail(buf: []u8, path: []const u8, max: usize) []u8 {
    std.debug.assert(buf.len >= max + ellipsis.len);
    const shown = if (path.len <= max) blk: {
        @memcpy(buf[0..path.len], path);
        break :blk buf[0..path.len];
    } else blk: {
        var start = path.len - max;
        while (start < path.len and path[start] & 0xC0 == 0x80) start += 1;
        break :blk std.fmt.bufPrint(buf, "{s}{s}", .{ ellipsis, path[start..] }) catch unreachable;
    };
    replaceInvalidUtf8(shown);
    return shown;
}

fn testDiagnostic(key: [:0]const u8, message: [:0]const u8, line: usize) diagnostics.Diagnostic {
    return .{
        .location = .{ .file = .{ .path = "C:\\Users\\a\\config.ghostty", .line = line } },
        .key = key,
        .message = message,
    };
}

test "config problems: no diagnostics make no banner and a plain list" {
    var problems: Problems = .{};
    defer problems.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), problems.count());
    try std.testing.expect(try problems.bannerText(std.testing.allocator) == null);
    var buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, problems.listText(&buf), "No problems") != null);
}

test "config problems: the banner has the count, the first problem and where the rest are" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);

    try problems.addDiagnostics(alloc, &.{testDiagnostic("font-szie", "unknown field", 3)});
    const one = (try problems.bannerText(alloc)).?;
    defer alloc.free(one);
    try std.testing.expectEqualStrings(
        "Config problem: font-szie: unknown field. See Config problems in the command palette.",
        one,
    );

    try problems.addDiagnostics(alloc, &.{
        testDiagnostic("font-size", "invalid value", 4),
        .{ .message = "theme \"Nope\" not found" },
    });
    const three = (try problems.bannerText(alloc)).?;
    defer alloc.free(three);
    try std.testing.expectEqualStrings(
        "3 config problems: font-szie: unknown field. See Config problems in the command palette.",
        three,
    );
}

test "config problems: the list names the problem first and its file and line after" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    try problems.addDiagnostics(alloc, &.{
        testDiagnostic("font-szie", "unknown field", 3),
        .{ .message = "theme \"Nope\" not found, tried path \"C:\\t\\Nope\"" },
        .{ .location = .{ .cli = 2 }, .key = "stray", .message = "invalid field" },
    });
    try problems.addMissingFont(alloc, "Cascadia Nope");

    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Config problems (4):\n" ++
            "1. font-szie: unknown field (C:\\Users\\a\\config.ghostty:3)\n" ++
            "2. theme \"Nope\" not found, tried path \"C:\\t\\Nope\"\n" ++
            "3. stray: invalid field (command line argument 2)\n" ++
            "4. font-family: \"Cascadia Nope\" was not found; other configured or built-in fonts are used\n",
        problems.listText(&buf),
    );
}

test "config problems: a long path loses its tail, not the problem" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    const path = "C:\\" ++ "deep\\" ** 60 ++ "config.ghostty";
    try problems.addDiagnostics(alloc, &.{.{
        .location = .{ .file = .{ .path = path, .line = 7 } },
        .key = "font-szie",
        .message = "unknown field",
    }});

    var buf: [1024]u8 = undefined;
    const list = problems.listText(&buf);
    try std.testing.expect(std.mem.indexOf(u8, list, "1. font-szie: unknown field (C:\\deep\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, ellipsis ++ "\n") != null);
    // A cut entry says where the whole text is.
    try std.testing.expect(std.mem.endsWith(u8, list, "Run koreterm +validate-config for the full text.\n"));
}

test "config problems: a font family is listed once however often it is reported" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    try problems.addMissingFont(alloc, "Cascadia Nope");
    try problems.addMissingFont(alloc, "Cascadia Nope");
    try problems.addMissingFont(alloc, "cascadia nope");
    try problems.addMissingFont(alloc, "Other Nope");
    try std.testing.expectEqual(@as(usize, 2), problems.count());

    // A name with bytes that are replaced when it is stored (a Latin-1 file)
    // is the same family each time, not a new problem for every tab.
    try problems.addMissingFont(alloc, "Caf\xe9 Mono");
    try problems.addMissingFont(alloc, "Caf\xe9 Mono");
    try problems.addMissingFont(alloc, "Line\nBreak");
    try problems.addMissingFont(alloc, "Line\nBreak");
    try std.testing.expectEqual(@as(usize, 4), problems.count());
}

test "config problems: a long first problem is cut for the banner, not for the list" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    // 150 two-byte characters: a cut must not split one.
    const message = "\u{e9}" ** 150;
    try problems.addDiagnostics(alloc, &.{.{ .key = "theme", .message = message }});

    const banner = (try problems.bannerText(alloc)).?;
    defer alloc.free(banner);
    try std.testing.expect(std.unicode.utf8ValidateSlice(banner));
    try std.testing.expect(std.mem.indexOf(u8, banner, ellipsis ++ ". See") != null);
    try std.testing.expect(banner.len < 100 + 80);
}

test "config problems: line breaks in a message do not reach the banner or the list" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    try problems.addDiagnostics(alloc, &.{.{ .key = "theme", .message = "a\r\nb" }});
    const banner = (try problems.bannerText(alloc)).?;
    defer alloc.free(banner);
    try std.testing.expect(std.mem.indexOfAny(u8, banner, "\r\n") == null);
    var buf: [512]u8 = undefined;
    const list = problems.listText(&buf);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, list, "\n"));
}

test "config problems: the list keeps whole entries and counts the rest" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    for (0..40) |i| {
        var key_buf: [16:0]u8 = undefined;
        const key = std.fmt.bufPrintZ(&key_buf, "key-{d}", .{i}) catch unreachable;
        try problems.addDiagnostics(alloc, &.{testDiagnostic(key, "unknown field", i + 1)});
    }

    var buf: [600]u8 = undefined;
    const list = problems.listText(&buf);
    try std.testing.expect(list.len <= buf.len);
    try std.testing.expect(std.mem.startsWith(u8, list, "Config problems (40):\n1. "));
    try std.testing.expect(std.mem.indexOf(u8, list, "...and ") != null);
    try std.testing.expect(std.mem.endsWith(u8, list, "for the full list.\n"));
    // Every listed line is whole.
    var lines = std.mem.splitScalar(u8, list[0 .. list.len - 1], '\n');
    while (lines.next()) |line| {
        try std.testing.expect(std.mem.startsWith(u8, line, "Config problems") or
            std.mem.startsWith(u8, line, "...and ") or
            std.mem.endsWith(u8, line, ")"));
    }
}

test "config problems: a long path is cut from the front" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\a\\b", pathTail(&buf, "C:\\a\\b", 16));
    const cut = pathTail(&buf, "C:\\very\\long\\path\\config.ghostty", 15);
    try std.testing.expectEqualStrings(ellipsis ++ "\\config.ghostty", cut);
}

test "config problems: bytes that are not UTF-8 are replaced, so no text call blanks the page" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    // Latin-1 e-acute, a lone continuation byte, and a cut-off three-byte sequence.
    try problems.addDiagnostics(alloc, &.{
        .{ .key = "theme", .message = "caf\xe9 \x80 \xe2\x82" },
        .{ .message = "valid \u{e9}\u{20ac} stays" },
    });
    const banner = (try problems.bannerText(alloc)).?;
    defer alloc.free(banner);
    try std.testing.expect(std.unicode.utf8ValidateSlice(banner));
    try std.testing.expect(std.mem.indexOf(u8, banner, "theme: caf? ?") != null);

    var buf: [512]u8 = undefined;
    const list = problems.listText(&buf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(list));
    try std.testing.expect(std.mem.indexOf(u8, list, "valid \u{e9}\u{20ac} stays") != null);

    var path_buf: [64]u8 = undefined;
    const path = pathTail(&path_buf, "C:\\caf\xe9\\config", 32);
    try std.testing.expect(std.unicode.utf8ValidateSlice(path));
    try std.testing.expectEqualStrings("C:\\caf?\\config", path);
}

test "config problems: running out of memory keeps nothing and frees everything" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var problems: Problems = .{};
            defer problems.deinit(alloc);
            try problems.addDiagnostics(alloc, &.{
                testDiagnostic("font-szie", "unknown field", 3),
                .{ .message = "theme not found" },
            });
            try problems.addMissingFont(alloc, "Cascadia Nope");
            try problems.addMissingFont(alloc, "cascadia nope");
            const banner = try problems.bannerText(alloc);
            if (banner) |text| alloc.free(text);
        }
    }.run, .{});
}

test "config problems: the fingerprint changes with the problems and not otherwise" {
    const alloc = std.testing.allocator;
    var problems: Problems = .{};
    defer problems.deinit(alloc);
    const empty = problems.fingerprint();

    try problems.addDiagnostics(alloc, &.{testDiagnostic("font-szie", "unknown field", 3)});
    const one = problems.fingerprint();
    try std.testing.expect(one != empty);

    // The same problem found again is the same answer.
    var again: Problems = .{};
    defer again.deinit(alloc);
    try again.addDiagnostics(alloc, &.{testDiagnostic("font-szie", "unknown field", 3)});
    try std.testing.expectEqual(one, again.fingerprint());

    // A different line, or one more problem, is not.
    var moved: Problems = .{};
    defer moved.deinit(alloc);
    try moved.addDiagnostics(alloc, &.{testDiagnostic("font-szie", "unknown field", 4)});
    try std.testing.expect(moved.fingerprint() != one);
    try problems.addMissingFont(alloc, "Cascadia Nope");
    try std.testing.expect(problems.fingerprint() != one);

    problems.clear(alloc);
    try std.testing.expectEqual(empty, problems.fingerprint());
}
