//! Pure terminal-text helpers for future UIA text-pattern providers.
//!
//! This first slice deliberately stops before COM registration. It
//! snapshots the terminal's plain-text document and line boundaries so
//! later `ITextProvider` / `ITextRangeProvider` wiring can stay thin.

const std = @import("std");
const terminal = @import("../../terminal/main.zig");

pub const OffsetRange = struct {
    start: usize,
    end: usize,
};

pub const TerminalTextMetadata = struct {
    byte_len: usize,
    utf16_len: usize,
    line_count: usize,
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

    /// Transfer ownership of the plain-text buffer to the caller. `deinit`
    /// still releases the snapshot side tables after this call.
    pub fn takeText(self: *TerminalTextSnapshot) []u8 {
        const text = self.text;
        self.text = text[0..0];
        return text;
    }

    pub fn lineCount(self: *const TerminalTextSnapshot) usize {
        return self.line_start_byte_offsets.len;
    }

    pub fn utf16Len(self: *const TerminalTextSnapshot) usize {
        return self.utf16_offset_for_byte[self.text.len];
    }

    pub fn metadata(self: *const TerminalTextSnapshot) TerminalTextMetadata {
        return .{
            .byte_len = self.text.len,
            .utf16_len = self.utf16Len(),
            .line_count = self.lineCount(),
        };
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

pub const TerminalCellPosition = struct {
    row: i32,
    column: u32,
    width: u8,
};

/// Bounded, pointer-free document snapshot for UIA. Rows before the viewport
/// use negative coordinates; rows inside the viewport start at zero.
pub const AccessibleTextSnapshot = struct {
    alloc: std.mem.Allocator,
    text: []u8,
    visible_range: OffsetRange,
    caret_offset: usize,
    cell_for_byte: []TerminalCellPosition,
    viewport_rows: u32,
    viewport_columns: u32,

    pub fn deinit(self: *AccessibleTextSnapshot) void {
        self.alloc.free(self.cell_for_byte);
        self.alloc.free(self.text);
        self.* = undefined;
    }
};

pub const accessible_history_max_rows: usize = 500;
pub const accessible_history_target_cells: usize = 40_000;

/// Bound UIA history by an approximate cell budget so narrow terminals expose
/// useful context without making wide terminal snapshots disproportionately
/// expensive. The active viewport is always exposed separately.
pub fn accessibleHistoryRows(columns: usize, scrollback_enabled: bool) usize {
    if (!scrollback_enabled) return 0;

    const rows_for_cell_budget = accessible_history_target_cells / @max(columns, 1);
    return @min(rows_for_cell_budget, accessible_history_max_rows);
}

/// Return metadata using the same line-start semantics as
/// `TerminalTextSnapshot`: empty text counts as one line, interior blank lines
/// are preserved, and a trailing newline terminates the last line instead of
/// creating a phantom empty line.
pub fn terminalTextMetadata(text: []const u8) !TerminalTextMetadata {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;

    var line_count: usize = 1;
    for (text, 0..) |c, i| {
        if (c == '\n' and i + 1 < text.len) line_count += 1;
    }

    return .{
        .byte_len = text.len,
        .utf16_len = try std.unicode.calcUtf16LeLen(text),
        .line_count = line_count,
    };
}

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

    return snapshotFromTextAndPins(alloc, &text_writer, &pin_map);
}

pub fn snapshotTerminalVisiblePlainText(
    alloc: std.mem.Allocator,
    terminal_state: *const terminal.Terminal,
) !TerminalTextSnapshot {
    var text_writer: std.Io.Writer.Allocating = .init(alloc);
    defer text_writer.deinit();

    var pin_map: std.ArrayList(terminal.Pin) = .empty;
    defer pin_map.deinit(alloc);

    const screen = terminal_state.screens.active;
    var formatter = terminal.formatter.PageListFormatter.init(
        &screen.pages,
        .plain,
    );
    formatter.top_left = screen.pages.getTopLeft(.viewport);
    formatter.bottom_right = screen.pages.getBottomRight(.viewport) orelse return error.UnknownPoint;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&text_writer.writer);

    return snapshotFromTextAndPins(alloc, &text_writer, &pin_map);
}

/// Capture a recent, hard-capped document window plus exact viewport-relative
/// grid positions. Terminal page pointers are converted while the caller owns
/// the renderer lock and never escape this function.
pub fn snapshotTerminalAccessiblePlainText(
    alloc: std.mem.Allocator,
    terminal_state: *const terminal.Terminal,
) !AccessibleTextSnapshot {
    var text_writer: std.Io.Writer.Allocating = .init(alloc);
    defer text_writer.deinit();

    var pin_map: std.ArrayList(terminal.Pin) = .empty;
    defer pin_map.deinit(alloc);

    const screen = terminal_state.screens.active;
    const pages = &screen.pages;
    const viewport_top = pages.getTopLeft(.viewport);
    const history_rows = accessibleHistoryRows(pages.cols, !screen.no_scrollback);
    const document_top = switch (viewport_top.upOverflow(history_rows)) {
        .offset => |pin| pin,
        .overflow => |overflow| overflow.end,
    };
    const viewport_bottom = pages.getBottomRight(.viewport) orelse return error.UnknownPoint;

    var formatter = terminal.formatter.PageListFormatter.init(pages, .plain);
    formatter.top_left = document_top;
    formatter.bottom_right = viewport_bottom;
    formatter.pin_map = .{ .alloc = alloc, .map = &pin_map };
    try formatter.format(&text_writer.writer);

    const text = try text_writer.toOwnedSlice();
    errdefer alloc.free(text);
    if (pin_map.items.len != text.len) return error.PinMapLengthMismatch;

    const cell_for_byte = try alloc.alloc(TerminalCellPosition, text.len);
    errdefer alloc.free(cell_for_byte);
    const viewport_screen = pages.pointFromPin(.screen, viewport_top) orelse return error.UnknownPoint;
    const viewport_y: i64 = @intCast(viewport_screen.screen.y);

    var visible_start: ?usize = null;
    var visible_end: usize = 0;
    for (pin_map.items, 0..) |pin, index| {
        const screen_point = pages.pointFromPin(.screen, pin) orelse return error.UnknownPoint;
        const cell = pin.node.data.getRowAndCell(pin.x, pin.y).cell;
        cell_for_byte[index] = .{
            .row = @intCast(@as(i64, @intCast(screen_point.screen.y)) - viewport_y),
            .column = @intCast(screen_point.screen.x),
            .width = if (text[index] == '\n') 0 else @intCast(cell.gridWidth()),
        };
        if (pin.isBetween(viewport_top, viewport_bottom)) {
            if (visible_start == null) visible_start = index;
            visible_end = index + 1;
        }
    }

    const visible = if (visible_start) |start|
        OffsetRange{ .start = start, .end = visible_end }
    else
        OffsetRange{ .start = text.len, .end = text.len };
    const cursor_screen = pages.pointFromPin(.screen, screen.cursor.page_pin.*) orelse return error.UnknownPoint;
    const cursor_row: i32 = @intCast(@as(i64, @intCast(cursor_screen.screen.y)) - viewport_y);
    const caret_offset = caretOffsetForGridPosition(
        text,
        cell_for_byte,
        cursor_row,
        @intCast(screen.cursor.x),
    );
    return .{
        .alloc = alloc,
        .text = text,
        .visible_range = visible,
        .caret_offset = caret_offset,
        .cell_for_byte = cell_for_byte,
        .viewport_rows = @intCast(pages.rows),
        .viewport_columns = @intCast(pages.cols),
    };
}

fn caretOffsetForGridPosition(
    text: []const u8,
    cell_for_byte: []const TerminalCellPosition,
    cursor_row: i32,
    cursor_column: u32,
) usize {
    if (cell_for_byte.len != text.len) return text.len;

    var row_end: ?usize = null;
    var index: usize = 0;
    while (index < text.len) {
        const scalar_len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const cell = cell_for_byte[index];
        if (cell.row > cursor_row) break;
        if (cell.row == cursor_row) {
            if (cell.width == 0 or cursor_column <= cell.column) return index;
            if (cursor_column < cell.column + cell.width) return index;
            row_end = @min(text.len, index + scalar_len);
        }
        index += scalar_len;
    }
    return row_end orelse text.len;
}

pub fn visibleRangeInDocument(
    document: *const TerminalTextSnapshot,
    visible: *const TerminalTextSnapshot,
) ?OffsetRange {
    if (visible.text.len == 0) return .{ .start = 0, .end = 0 };
    if (visible.pin_map.len > document.pin_map.len) return null;

    const max_start = document.pin_map.len - visible.pin_map.len;
    for (0..max_start + 1) |start| {
        if (!pinSlicesEqual(
            document.pin_map[start .. start + visible.pin_map.len],
            visible.pin_map,
        )) continue;

        return .{ .start = start, .end = start + visible.text.len };
    }

    return null;
}

fn pinSlicesEqual(lhs: []const terminal.Pin, rhs: []const terminal.Pin) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (a.node != b.node or a.x != b.x or a.y != b.y or a.garbage != b.garbage) return false;
    }
    return true;
}

fn snapshotFromTextAndPins(
    alloc: std.mem.Allocator,
    text_writer: *std.Io.Writer.Allocating,
    pin_map: *std.ArrayList(terminal.Pin),
) !TerminalTextSnapshot {
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
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000,
    });
    defer t.deinit(std.testing.allocator);

    try t.printString("Hello\nWorld");

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        &t,
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

    try std.testing.expectEqual(
        TerminalTextMetadata{
            .byte_len = 11,
            .utf16_len = 11,
            .line_count = 2,
        },
        snapshot.metadata(),
    );
}

test "TerminalTextSnapshot takeText transfers text ownership" {
    const alloc = std.testing.allocator;
    const text = try alloc.dupe(u8, "owned text");
    var snapshot = TerminalTextSnapshot{
        .alloc = alloc,
        .text = text,
        .pin_map = try alloc.alloc(terminal.Pin, text.len),
        .utf16_offset_for_byte = try buildUtf16OffsetMap(alloc, text),
        .line_start_byte_offsets = try buildLineStartByteOffsets(alloc, text),
    };

    const taken = snapshot.takeText();
    defer alloc.free(taken);

    try std.testing.expectEqualSlices(u8, text, taken);
    try std.testing.expectEqual(@as(usize, 0), snapshot.text.len);
    snapshot.deinit();
}

test "snapshotTerminalPlainText includes scrollback rows" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer t.deinit(std.testing.allocator);

    try t.printString("line1\nline2\nline3\nline4\nline5\n");

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        &t,
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

test "snapshotTerminalVisiblePlainText excludes scrollback rows" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer t.deinit(std.testing.allocator);

    try t.printString("line1\nline2\nline3\nline4\nline5\n");

    var document = try snapshotTerminalPlainText(
        std.testing.allocator,
        &t,
    );
    defer document.deinit();

    var visible = try snapshotTerminalVisiblePlainText(
        std.testing.allocator,
        &t,
    );
    defer visible.deinit();

    try std.testing.expect(std.mem.indexOf(u8, document.text, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible.text, "line1") == null);
    try std.testing.expect(std.mem.indexOf(u8, visible.text, "line5") != null);
}

test "snapshotTerminalAccessiblePlainText bounds history and maps viewport" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer t.deinit(std.testing.allocator);

    var line: [32]u8 = undefined;
    for (0..750) |index| {
        const value = try std.fmt.bufPrint(&line, "row-{d:0>3}\n", .{index});
        try t.printString(value);
    }

    var snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer snapshot.deinit();

    try std.testing.expect(snapshot.text.len > 0);
    try std.testing.expectEqual(snapshot.text.len, snapshot.cell_for_byte.len);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.text, "row-000") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.text, "row-300") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.text, "row-749") != null);
    try std.testing.expect(snapshot.visible_range.start <= snapshot.visible_range.end);
    try std.testing.expect(snapshot.visible_range.end <= snapshot.text.len);
    try std.testing.expect(snapshot.visible_range.start > 0);
    try std.testing.expect(snapshot.caret_offset >= snapshot.visible_range.start);
    try std.testing.expect(snapshot.caret_offset <= snapshot.visible_range.end);

    var line_count: usize = 1;
    for (snapshot.text) |byte| if (byte == '\n') {
        line_count += 1;
    };
    const history_rows = accessibleHistoryRows(t.screens.active.pages.cols, true);
    try std.testing.expectEqual(accessible_history_max_rows, history_rows);
    try std.testing.expect(line_count <= history_rows + 3);
    for (snapshot.cell_for_byte[snapshot.visible_range.start..snapshot.visible_range.end]) |cell| {
        try std.testing.expect(cell.row >= 0);
        try std.testing.expect(cell.row < 3);
    }
}

test "accessible history policy follows scrollback and cell budget" {
    try std.testing.expectEqual(@as(usize, 0), accessibleHistoryRows(80, false));
    try std.testing.expectEqual(@as(usize, 500), accessibleHistoryRows(0, true));
    try std.testing.expectEqual(@as(usize, 500), accessibleHistoryRows(80, true));
    try std.testing.expectEqual(@as(usize, 333), accessibleHistoryRows(120, true));
    try std.testing.expectEqual(@as(usize, 0), accessibleHistoryRows(40_001, true));
}

test "accessible caret mapping uses UTF-8 grid boundaries and line ends" {
    const text = "A🔥B\nnext";
    const cells = [_]TerminalCellPosition{
        .{ .row = 0, .column = 0, .width = 1 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 1, .width = 2 },
        .{ .row = 0, .column = 3, .width = 1 },
        .{ .row = 0, .column = 3, .width = 0 },
        .{ .row = 1, .column = 0, .width = 1 },
        .{ .row = 1, .column = 1, .width = 1 },
        .{ .row = 1, .column = 2, .width = 1 },
        .{ .row = 1, .column = 3, .width = 1 },
    };

    try std.testing.expectEqual(@as(usize, 1), caretOffsetForGridPosition(text, &cells, 0, 1));
    try std.testing.expectEqual(@as(usize, 1), caretOffsetForGridPosition(text, &cells, 0, 2));
    try std.testing.expectEqual(@as(usize, 6), caretOffsetForGridPosition(text, &cells, 0, 9));
    try std.testing.expectEqual(@as(usize, 8), caretOffsetForGridPosition(text, &cells, 1, 1));
}

test "visibleRangeInDocument maps viewport pins into document offsets" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer t.deinit(std.testing.allocator);

    try t.printString("line1\nline2\nline3\nline4\nline5\n");

    var document = try snapshotTerminalPlainText(
        std.testing.allocator,
        &t,
    );
    defer document.deinit();

    var visible = try snapshotTerminalVisiblePlainText(
        std.testing.allocator,
        &t,
    );
    defer visible.deinit();

    const range = visibleRangeInDocument(&document, &visible).?;
    try std.testing.expect(range.start > 0);
    try std.testing.expectEqualStrings(visible.text, document.text[range.start..range.end]);
}

test "snapshotTerminalPlainText preserves blank rows in line map" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000,
    });
    defer t.deinit(std.testing.allocator);

    try t.printString("top\n\nbottom");

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        &t,
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
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000,
    });
    defer t.deinit(std.testing.allocator);

    try t.printString("A\xf0\x9f\x94\xa5B");

    var snapshot = try snapshotTerminalPlainText(
        std.testing.allocator,
        &t,
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

    try std.testing.expectEqual(
        TerminalTextMetadata{
            .byte_len = 6,
            .utf16_len = 4,
            .line_count = 1,
        },
        try terminalTextMetadata(snapshot.text),
    );
}

test "snapshotTerminalPlainText utf16 map rejects truncated utf8" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(
        error.TruncatedUtf8,
        buildUtf16OffsetMap(alloc, &.{ 0xF0, 0x9F }),
    );

    try std.testing.expectError(
        error.InvalidUtf8,
        terminalTextMetadata(&.{ 0xF0, 0x9F }),
    );
}
