//! Golden replay tests: application-shaped VT streams fed through
//! `Terminal.vtStream` with a resize schedule, checked against the screen the
//! program meant to draw.
//!
//! Each case is a small script in `testdata/replay/*.vt`:
//!
//!   # comment
//!   size <cols> <rows>      create the terminal (first command)
//!   pty conpty              the bytes come from Windows ConPTY (see below)
//!   send <text>             feed bytes; escapes \e \r \n \t \\ \xHH (use
//!                           \x20 for a leading space)
//!   seq <pre> <a> <b> [suf] feed "<pre><n><suf>\r\n" for n = a..b, with the
//!                           same escapes
//!   resize <cols> <rows>    Terminal.resize, as Termio does
//!   expect [xfail <why>]    the viewport, one `|row` line per row from the
//!   |row                    top (trailing blanks ignored, missing rows are
//!   ?                       blank); a line that is just `?` skips that row
//!   end
//!   cursor <x> <y> [xfail <why>]
//!                           the cursor, 0-based within the active area
//!
//! A `pty conpty` case models ConPTY, which keeps its own screen buffer
//! without scrollback and sends nothing after a resize (AGENTS.md, #262).
//! Its expectations are ConPTY's own buffer as measured by
//! `test/windows/interactive-win11-conpty-sync.ps1`, and the absolute cursor
//! moves in its `send` lines stand for console-API programs (cmd's line
//! editor, PSReadLine) drawing at ConPTY's coordinates. The terminal passes
//! when it ends up where ConPTY is, so the next absolute write lands on the
//! right row.
//!
//! A check marked `xfail` documents a known bug with the correct
//! expectation: it must fail, and the test fails once it passes, so the fix
//! has to remove the mark. Every unmarked check must pass, and prints its
//! differences when it does not.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");
const Stream = @import("stream_terminal.zig").Stream;

test "resize replay: conpty grow rows with the prompt at the bottom" {
    try runCase("conpty-grow-rows.vt");
}

test "resize replay: conpty shrink then grow rows (search bar)" {
    try runCase("conpty-shrink-grow-rows.vt");
}

test "resize replay: conpty leave the alternate screen after a grow" {
    try runCase("conpty-altscreen-grow.vt");
}

test "resize replay: conpty shrink rows with content below the cursor" {
    try runCase("conpty-shrink-rows-below-cursor.vt");
}

test "resize replay: conpty shrink cols with content below the cursor" {
    try runCase("conpty-shrink-cols-below-cursor.vt");
}

test "resize replay: conpty narrow then widen with the prompt at the bottom" {
    try runCase("conpty-narrow-widen.vt");
}

test "resize replay: conpty shrink rows with the prompt at the bottom" {
    try runCase("conpty-shrink-rows-bottom.vt");
}

test "resize replay: alternate screen frame repainted after a resize" {
    try runCase("altscreen-repaint.vt");
}

test "resize replay: wide characters at the right edge survive narrow and widen" {
    try runCase("wide-edge-roundtrip.vt");
}

test "resize replay: script parser" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("a\x1b[1m\r\n\t\\\xff", try unescape(&buf, "a\\e[1m\\r\\n\\t\\\\\\xff"));
    try testing.expectError(error.BadEscape, unescape(&buf, "\\q"));
    try testing.expectError(error.BadEscape, unescape(&buf, "\\x1"));
    try testing.expectError(error.BadEscape, unescape(&buf, "\\x+f"));

    // An unmarked check that fails is a test failure.
    try testing.expectError(error.ReplayMismatch, run(testing.allocator, "inline",
        \\size 4 2
        \\send ab
        \\expect
        \\|xy
        \\end
        \\
    , .quiet));
    // So is a marked check that passes, even when another one still fails.
    try testing.expectError(error.UnexpectedPass, run(testing.allocator, "inline",
        \\size 4 2
        \\send ab
        \\expect xfail nothing is wrong
        \\|ab
        \\end
        \\cursor 0 0 xfail this one is wrong
        \\
    , .quiet));
    // A marked check does not excuse an unmarked one.
    try testing.expectError(error.ReplayMismatch, run(testing.allocator, "inline",
        \\size 4 2
        \\send ab
        \\cursor 0 0
        \\expect xfail the expectation is wrong on purpose
        \\|zz
        \\end
        \\
    , .quiet));
    try run(testing.allocator, "inline",
        \\  # indented comments and blank lines are fine
        \\
        \\size 4 2
        \\send ab
        \\expect xfail the expectation is wrong on purpose
        \\?
        \\|zz
        \\end
        \\cursor 2 0
        \\
    , .quiet);
}

fn runCase(comptime name: []const u8) !void {
    try run(testing.allocator, name, @embedFile("testdata/replay/" ++ name), .verbose);
}

const Verbosity = enum { quiet, verbose };

const Check = struct {
    name: []const u8,
    line_no: usize,
    verbosity: Verbosity,
    /// The reason after `xfail`, if the check is expected to fail.
    xfail: ?[]const u8,
    failed: *usize,
    unexpected_passes: *usize,

    /// Record the outcome of a check. Differences are printed by the caller
    /// only for unmarked checks.
    fn record(self: Check, ok: bool) void {
        if (self.xfail) |reason| {
            if (ok) {
                self.unexpected_passes.* += 1;
                if (self.verbosity == .verbose) std.debug.print(
                    "{s}:{d}: this check now passes; remove `xfail {s}`\n",
                    .{ self.name, self.line_no, reason },
                );
            }
        } else if (!ok) self.failed.* += 1;
    }

    fn printing(self: Check) bool {
        return self.verbosity == .verbose and self.xfail == null;
    }
};

fn run(alloc: Allocator, name: []const u8, script: []const u8, verbosity: Verbosity) !void {
    var term: ?Terminal = null;
    defer if (term) |*t| t.deinit(alloc);
    var stream: ?Stream = null;
    defer if (stream) |*s| s.deinit();

    var failed: usize = 0;
    var unexpected_passes: usize = 0;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);

    var lines = std.mem.splitScalar(u8, script, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = words.next().?;
        const rest = std.mem.trimLeft(u8, line[cmd.len..], " ");

        if (std.mem.eql(u8, cmd, "size")) {
            if (term != null) return scriptError(name, line_no, "size given twice");
            const cols = try parseInt(name, line_no, words.next());
            const rows = try parseInt(name, line_no, words.next());
            try noMoreWords(name, line_no, &words);
            term = try Terminal.init(alloc, .{ .cols = cols, .rows = rows });
            stream = term.?.vtStream();
            continue;
        }
        const t = if (term) |*v| v else return scriptError(name, line_no, "size must come first");

        if (std.mem.eql(u8, cmd, "pty")) {
            if (!std.mem.eql(u8, rest, "conpty")) return scriptError(name, line_no, "unknown pty");
            // The Windows ConPTY backend configures nothing on the terminal
            // yet: a ConPTY case runs with the defaults every pty gets.
        } else if (std.mem.eql(u8, cmd, "send")) {
            try bytes.resize(alloc, rest.len);
            const decoded = unescape(bytes.items, rest) catch return scriptError(name, line_no, "bad escape");
            stream.?.nextSlice(decoded);
        } else if (std.mem.eql(u8, cmd, "seq")) {
            var prefix_buf: [64]u8 = undefined;
            var suffix_buf: [256]u8 = undefined;
            const prefix_raw = words.next() orelse return scriptError(name, line_no, "seq needs a prefix");
            const first = try parseInt(name, line_no, words.next());
            const last = try parseInt(name, line_no, words.next());
            const suffix_raw = words.next() orelse "";
            try noMoreWords(name, line_no, &words);
            if (prefix_raw.len > prefix_buf.len or suffix_raw.len > suffix_buf.len) return scriptError(name, line_no, "seq text too long");
            const prefix = unescape(&prefix_buf, prefix_raw) catch return scriptError(name, line_no, "bad escape");
            const suffix = unescape(&suffix_buf, suffix_raw) catch return scriptError(name, line_no, "bad escape");
            var n = first;
            while (n <= last) : (n += 1) {
                var buf: [512]u8 = undefined;
                stream.?.nextSlice(try std.fmt.bufPrint(&buf, "{s}{d}{s}\r\n", .{ prefix, n, suffix }));
            }
        } else if (std.mem.eql(u8, cmd, "resize")) {
            const cols = try parseInt(name, line_no, words.next());
            const rows = try parseInt(name, line_no, words.next());
            try noMoreWords(name, line_no, &words);
            try t.resize(alloc, cols, rows);
        } else if (std.mem.eql(u8, cmd, "expect")) {
            const check: Check = .{
                .name = name,
                .line_no = line_no,
                .verbosity = verbosity,
                .xfail = try xfailReason(name, line_no, &words),
                .failed = &failed,
                .unexpected_passes = &unexpected_passes,
            };
            var expected: std.ArrayList(?[]const u8) = .empty;
            defer expected.deinit(alloc);
            while (true) {
                const next = lines.next() orelse return scriptError(name, check.line_no, "expect without end");
                line_no += 1;
                const row = std.mem.trimRight(u8, next, "\r");
                if (std.mem.eql(u8, row, "end")) break;
                if (std.mem.eql(u8, row, "?")) {
                    try expected.append(alloc, null);
                } else if (row.len > 0 and row[0] == '|') {
                    try expected.append(alloc, row[1..]);
                } else return scriptError(name, line_no, "expect rows start with | or are ?");
            }
            check.record(try viewportMatches(alloc, t, expected.items, check));
        } else if (std.mem.eql(u8, cmd, "cursor")) {
            const x = try parseInt(name, line_no, words.next());
            const y = try parseInt(name, line_no, words.next());
            const check: Check = .{
                .name = name,
                .line_no = line_no,
                .verbosity = verbosity,
                .xfail = try xfailReason(name, line_no, &words),
                .failed = &failed,
                .unexpected_passes = &unexpected_passes,
            };
            const cursor = t.screens.active.cursor;
            const ok = cursor.x == x and cursor.y == y;
            if (!ok and check.printing()) std.debug.print(
                "{s}:{d}: cursor expected {d},{d}, found {d},{d}\n",
                .{ name, line_no, x, y, cursor.x, cursor.y },
            );
            check.record(ok);
        } else return scriptError(name, line_no, "unknown command");
    }

    if (failed > 0) return error.ReplayMismatch;
    if (unexpected_passes > 0) return error.UnexpectedPass;
}

/// Compare the viewport row by row.
fn viewportMatches(
    alloc: Allocator,
    t: *Terminal,
    expected: []const ?[]const u8,
    check: Check,
) !bool {
    const text = try t.plainString(alloc);
    defer alloc.free(text);
    var actual: std.ArrayList([]const u8) = .empty;
    defer actual.deinit(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |row| try actual.append(alloc, std.mem.trimRight(u8, row, " "));

    if (expected.len > t.rows) return scriptError(check.name, check.line_no, "more expected rows than the terminal has");
    var ok = true;
    for (0..t.rows) |y| {
        const want: ?[]const u8 = if (y < expected.len) expected[y] else "";
        const exp = want orelse continue;
        const got = if (y < actual.items.len) actual.items[y] else "";
        if (!std.mem.eql(u8, std.mem.trimRight(u8, exp, " "), got)) {
            ok = false;
            if (check.printing()) std.debug.print(
                "{s}:{d}: row {d}\n  expected: |{s}\n  actual:   |{s}\n",
                .{ check.name, check.line_no, y, exp, got },
            );
        }
    }
    return ok;
}

/// `xfail <reason>` at the end of a check line, or nothing.
fn xfailReason(
    name: []const u8,
    line_no: usize,
    words: *std.mem.TokenIterator(u8, .scalar),
) !?[]const u8 {
    const word = words.next() orelse return null;
    if (!std.mem.eql(u8, word, "xfail")) return scriptError(name, line_no, "expected `xfail <reason>` or nothing");
    const reason = std.mem.trimLeft(u8, words.rest(), " ");
    if (reason.len == 0) return scriptError(name, line_no, "xfail needs a reason");
    return reason;
}

fn noMoreWords(name: []const u8, line_no: usize, words: *std.mem.TokenIterator(u8, .scalar)) !void {
    if (words.next() != null) return scriptError(name, line_no, "unexpected extra words");
}

fn parseInt(name: []const u8, line_no: usize, word: ?[]const u8) !u16 {
    const w = word orelse return scriptError(name, line_no, "missing number");
    return std.fmt.parseInt(u16, w, 10) catch scriptError(name, line_no, "bad number");
}

fn scriptError(name: []const u8, line_no: usize, message: []const u8) error{BadReplayScript} {
    std.debug.print("{s}:{d}: {s}\n", .{ name, line_no, message });
    return error.BadReplayScript;
}

/// Decode the escapes a `send` line may use into `buf`, which must be at
/// least as long as `src`.
fn unescape(buf: []u8, src: []const u8) error{BadEscape}![]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] != '\\') {
            buf[out] = src[i];
            out += 1;
            continue;
        }
        i += 1;
        if (i >= src.len) return error.BadEscape;
        buf[out] = switch (src[i]) {
            'e' => 0x1b,
            'r' => '\r',
            'n' => '\n',
            't' => '\t',
            '\\' => '\\',
            'x' => hex: {
                if (i + 2 >= src.len) return error.BadEscape;
                const hi = std.fmt.charToDigit(src[i + 1], 16) catch return error.BadEscape;
                const lo = std.fmt.charToDigit(src[i + 2], 16) catch return error.BadEscape;
                i += 2;
                break :hex hi * 16 + lo;
            },
            else => return error.BadEscape,
        };
        out += 1;
    }
    return buf[0..out];
}
