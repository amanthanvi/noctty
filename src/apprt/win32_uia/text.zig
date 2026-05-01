//! Pure terminal-text helpers for future UIA text-pattern providers.
//!
//! This first slice deliberately stops before COM registration. It
//! snapshots the terminal's plain-text document and line boundaries so
//! later `ITextProvider` / `ITextRangeProvider` wiring can stay thin.

const std = @import("std");
const terminal = @import("../../terminal/main.zig");
const terminal_c = @import("../../terminal/c/terminal.zig");
const terminal_lib = @import("../../terminal/lib.zig");
const Result = @import("../../terminal/c/result.zig").Result;

pub const OffsetRange = struct {
    start: usize,
    end: usize,
};

pub const TerminalTextSnapshot = struct {
    alloc: std.mem.Allocator,
    /// UTF-8 plain text with `\n` separators for hard and soft line breaks.
    text: []u8,
    /// Terminal pin for each byte in `text`; `\n` bytes reuse the pin from
    /// the row they terminate rather than naming a distinct source cell.
    pin_map: []terminal.Pin,
    /// UTF-16 code-unit offset for each byte in `text`, plus a sentinel for
    /// `text.len`. Multibyte scalars therefore repeat the same start offset.
    utf16_offset_for_byte: []usize,
    /// Byte offsets into `text` for each line start.
    line_start_byte_offsets: []usize,

    pub fn deinit(self: *TerminalTextSnapshot) void {
        self.alloc.free(self.line_start_byte_offsets);
        self.alloc.free(self.utf16_offset_for_byte);
        self.alloc.free(self.pin_map);
        self.alloc.free(self.text);
        self.* = undefined;
    }

    pub fn lineCount(self: *const TerminalTextSnapshot) usize {
        return self.line_start_byte_offsets.len;
    }

    /// Return a half-open UTF-8 byte range for the requested line.
    pub fn lineByteRange(self: *const TerminalTextSnapshot, line_index: usize) ?OffsetRange {
        if (line_index >= self.line_start_byte_offsets.len) return null;

        const start = self.line_start_byte_offsets[line_index];
        const end = if (line_index + 1 < self.line_start_byte_offsets.len)
            self.line_start_byte_offsets[line_index + 1] - 1
        else blk: {
            var line_end = self.text.len;
            if (line_end > start and self.text[line_end - 1] == '\n') line_end -= 1;
            break :blk line_end;
        };
        return .{ .start = start, .end = end };
    }

    /// Return a half-open UTF-16 code-unit range for the requested line.
    pub fn lineUtf16Range(self: *const TerminalTextSnapshot, line_index: usize) ?OffsetRange {
        const byte_range = self.lineByteRange(line_index) orelse return null;
        return .{
            .start = self.utf16_offset_for_byte[byte_range.start],
            .end = self.utf16_offset_for_byte[byte_range.end],
        };
    }
};

pub fn snapshotTerminalPlainText(
    alloc: std.mem.Allocator,
    terminal_state: *const terminal.Terminal,
) !TerminalTextSnapshot {
    var text_writer: std.Io.Writer.Allocating = .init(alloc);
    defer text_writer.deinit();

    var pin_map: std.ArrayList(terminal.Pin) = .empty;
    defer pin_map.deinit(alloc);

    var formatter = terminal.formatter.TerminalFormatter.init(
        terminal_state,
        .plain,
    );
    formatter.extra = .none;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&text_writer.writer);

    const text = try text_writer.toOwnedSlice();
    errdefer alloc.free(text);

    if (pin_map.items.len != text.len) return error.PinMapLengthMismatch;
    const owned_pin_map = try pin_map.toOwnedSlice(alloc);
    errdefer alloc.free(owned_pin_map);

    const utf16_offset_for_byte = try buildUtf16OffsetMap(alloc, text);
    errdefer alloc.free(utf16_offset_for_byte);

    const line_start_byte_offsets = try buildLineStartByteOffsets(alloc, text);
    errdefer alloc.free(line_start_byte_offsets);

    return .{
        .alloc = alloc,
        .text = text,
        .pin_map = owned_pin_map,
        .utf16_offset_for_byte = utf16_offset_for_byte,
        .line_start_byte_offsets = line_start_byte_offsets,
    };
}

fn buildLineStartByteOffsets(
    alloc: std.mem.Allocator,
    text: []const u8,
) ![]usize {
    var line_start_byte_offsets: std.ArrayList(usize) = .empty;
    defer line_start_byte_offsets.deinit(alloc);

    try line_start_byte_offsets.append(alloc, 0);

    // Preserve interior blank lines, but treat a terminal trailing '\n' as the
    // last line terminator instead of the start of a phantom empty line.
    for (text, 0..) |c, i| {
        if (c == '\n' and i + 1 < text.len) try line_start_byte_offsets.append(alloc, i + 1);
    }

    return try line_start_byte_offsets.toOwnedSlice(alloc);
}

fn buildUtf16OffsetMap(
    alloc: std.mem.Allocator,
    text: []const u8,
) ![]usize {
    const utf16_offset_for_byte = try alloc.alloc(usize, text.len + 1);
    errdefer alloc.free(utf16_offset_for_byte);

    var byte_index: usize = 0;
    var utf16_offset: usize = 0;
    while (byte_index < text.len) {
        const utf8_len = try std.unicode.utf8ByteSequenceLength(text[byte_index]);
        if (byte_index + utf8_len > text.len) return error.TruncatedUtf8;
        const codepoint = try std.unicode.utf8Decode(text[byte_index .. byte_index + utf8_len]);
        @memset(utf16_offset_for_byte[byte_index .. byte_index + utf8_len], utf16_offset);
        byte_index += utf8_len;
        utf16_offset += if (codepoint <= 0xFFFF) 1 else 2;
    }
    utf16_offset_for_byte[text.len] = utf16_offset;

    return utf16_offset_for_byte;
}

test "snapshotTerminalPlainText captures terminal rows" {
    var t: terminal_c.Terminal = null;
    try std.testing.expectEqual(Result.success, terminal_c.new(
        &terminal_lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello\r\nWorld", 12);

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        (t orelse unreachable).terminal,
    );
    defer snapshot.deinit();

    try std.testing.expectEqualStrings("Hello\nWorld", snapshot.text);
    try std.testing.expectEqual(@as(usize, 2), snapshot.lineCount());

    const first = snapshot.lineByteRange(0).?;
    try std.testing.expectEqualStrings("Hello", snapshot.text[first.start..first.end]);
    try std.testing.expectEqual(
        OffsetRange{ .start = 0, .end = 5 },
        snapshot.lineUtf16Range(0).?,
    );

    const second = snapshot.lineByteRange(1).?;
    try std.testing.expectEqualStrings("World", snapshot.text[second.start..second.end]);
    try std.testing.expectEqual(
        OffsetRange{ .start = 6, .end = 11 },
        snapshot.lineUtf16Range(1).?,
    );
}

test "snapshotTerminalPlainText includes scrollback rows" {
    var t: terminal_c.Terminal = null;
    try std.testing.expectEqual(Result.success, terminal_c.new(
        &terminal_lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 3,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n", 35);

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        (t orelse unreachable).terminal,
    );
    defer snapshot.deinit();

    try std.testing.expectEqualStrings(
        "line1\nline2\nline3\nline4\nline5",
        snapshot.text,
    );
    try std.testing.expectEqual(@as(usize, 5), snapshot.lineCount());
    try std.testing.expectEqual(
        OffsetRange{ .start = 24, .end = 29 },
        snapshot.lineUtf16Range(4).?,
    );
}

test "snapshotTerminalPlainText preserves blank rows in line map" {
    var t: terminal_c.Terminal = null;
    try std.testing.expectEqual(Result.success, terminal_c.new(
        &terminal_lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "top\r\n\r\nbottom", 13);

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        (t orelse unreachable).terminal,
    );
    defer snapshot.deinit();

    try std.testing.expectEqualStrings("top\n\nbottom", snapshot.text);
    try std.testing.expectEqual(@as(usize, 3), snapshot.lineCount());

    const blank = snapshot.lineByteRange(1).?;
    try std.testing.expectEqual(@as(usize, blank.start), blank.end);
    try std.testing.expectEqual(
        OffsetRange{ .start = 4, .end = 4 },
        snapshot.lineUtf16Range(1).?,
    );
}

test "snapshotTerminalPlainText line map ignores trailing newline terminator" {
    const alloc = std.testing.allocator;
    const text = "top\n\n";

    var snapshot = TerminalTextSnapshot{
        .alloc = alloc,
        .text = try alloc.dupe(u8, text),
        .pin_map = try alloc.alloc(terminal.Pin, text.len),
        .utf16_offset_for_byte = try buildUtf16OffsetMap(alloc, text),
        .line_start_byte_offsets = try buildLineStartByteOffsets(alloc, text),
    };
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 2), snapshot.lineCount());
    try std.testing.expectEqualSlices(usize, &.{ 0, 4 }, snapshot.line_start_byte_offsets);

    const first = snapshot.lineByteRange(0).?;
    try std.testing.expectEqualStrings("top", snapshot.text[first.start..first.end]);

    const second = snapshot.lineByteRange(1).?;
    try std.testing.expectEqual(@as(usize, second.start), second.end);
    try std.testing.expectEqual(
        OffsetRange{ .start = 4, .end = 4 },
        snapshot.lineUtf16Range(1).?,
    );
    try std.testing.expect(snapshot.lineByteRange(2) == null);
}

test "snapshotTerminalPlainText tracks multibyte text for UIA offsets" {
    var t: terminal_c.Terminal = null;
    try std.testing.expectEqual(Result.success, terminal_c.new(
        &terminal_lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "A\xf0\x9f\x94\xa5B", 6);

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        (t orelse unreachable).terminal,
    );
    defer snapshot.deinit();

    try std.testing.expectEqualStrings("A🔥B", snapshot.text);
    try std.testing.expectEqual(@as(usize, snapshot.text.len), snapshot.pin_map.len);
    try std.testing.expectEqual(@as(usize, snapshot.text.len + 1), snapshot.utf16_offset_for_byte.len);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1, 1, 1, 1, 3, 4 },
        snapshot.utf16_offset_for_byte,
    );

    try std.testing.expectEqual(@as(usize, 0), snapshot.pin_map[0].x);
    for (1..5) |i| try std.testing.expectEqual(@as(usize, 1), snapshot.pin_map[i].x);
    try std.testing.expectEqual(@as(usize, 3), snapshot.pin_map[5].x);
    try std.testing.expectEqual(
        OffsetRange{ .start = 0, .end = 4 },
        snapshot.lineUtf16Range(0).?,
    );
}

test "snapshotTerminalPlainText utf16 map rejects truncated utf8" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(
        error.TruncatedUtf8,
        buildUtf16OffsetMap(alloc, &.{ 0xF0, 0x9F }),
    );
}
