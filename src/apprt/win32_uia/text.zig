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
    selection_range: ?OffsetRange = null,
    selection_active_offset: ?usize = null,
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
    const active_top = pages.getTopLeft(.active);
    const history_rows = accessibleHistoryRows(pages.cols, !screen.no_scrollback);
    const viewport_bottom = pages.getBottomRight(.viewport) orelse return error.UnknownPoint;
    const active_bottom = pages.getBottomRight(.active) orelse return error.UnknownPoint;
    const history_top = switch (active_top.upOverflow(history_rows)) {
        .offset => |pin| pin,
        .overflow => |overflow| overflow.end,
    };

    // The window is history plus one viewport of rows. It normally ends at the
    // active screen so the caret stays inside it, but a viewport scrolled
    // farther back than the history budget would otherwise fall outside the
    // window entirely and leave `visible_range` empty while a full screen of
    // text is on display. Slide the same-sized window up to the viewport
    // instead of growing it; the off-window caret degrades to the document end.
    const document_top = if (viewport_top.isBetween(history_top, active_bottom))
        history_top
    else
        viewport_top;
    const budget_rows = history_rows + @as(usize, pages.rows);
    const budget_bottom: terminal.Pin = blk: {
        var pin = switch (document_top.downOverflow(budget_rows -| 1)) {
            .offset => |value| value,
            .overflow => |overflow| overflow.end,
        };
        pin.x = active_bottom.x;
        break :blk pin;
    };
    const document_bottom = if (budget_bottom.isBetween(document_top, active_bottom))
        budget_bottom
    else
        active_bottom;

    var formatter = terminal.formatter.PageListFormatter.init(pages, .plain);
    formatter.top_left = document_top;
    formatter.bottom_right = document_bottom;
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
    const selection = selectionOffsets(text, pin_map.items, screen);
    return .{
        .alloc = alloc,
        .text = text,
        .visible_range = visible,
        .caret_offset = caret_offset,
        .selection_range = if (selection) |value| value.range else null,
        .selection_active_offset = if (selection) |value| value.active_offset else null,
        .cell_for_byte = cell_for_byte,
        .viewport_rows = @intCast(pages.rows),
        .viewport_columns = @intCast(pages.cols),
    };
}

const SelectionOffsets = struct {
    range: OffsetRange,
    active_offset: usize,
};

fn selectionOffsets(
    text: []const u8,
    pin_map: []const terminal.Pin,
    screen: *const terminal.Screen,
) ?SelectionOffsets {
    const selection = screen.selection orelse return null;
    if (pin_map.len != text.len) return null;

    if (selection.rectangle) {
        const active = screen.pages.pointFromPin(.screen, selection.end()) orelse return null;
        const anchor = screen.pages.pointFromPin(.screen, selection.start()) orelse return null;
        var first: ?usize = null;
        var last_end: usize = 0;
        var index: usize = 0;
        while (index < text.len) {
            const scalar_len = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
            if (text[index] == '\n') {
                index += scalar_len;
                continue;
            }
            const pin = pin_map[index];
            const point = screen.pages.pointFromPin(.screen, pin) orelse return null;
            if (point.screen.y == active.screen.y and selection.contains(screen, pin)) {
                if (first == null) first = index;
                last_end = index + scalar_len;
            }
            index += scalar_len;
        }
        const start = first orelse return null;
        return .{
            .range = .{ .start = start, .end = last_end },
            .active_offset = if (active.screen.x <= anchor.screen.x) start else last_end,
        };
    }

    const top_left = selection.topLeft(screen);
    const bottom_right = selection.bottomRight(screen);
    if (pin_map.len == 0) return null;
    const first_pin = pin_map[0];
    const last_pin = pin_map[pin_map.len - 1];
    const start = scalarRangeForPin(text, pin_map, top_left) orelse blk: {
        if (top_left.before(first_pin)) break :blk OffsetRange{ .start = 0, .end = 0 };
        if (last_pin.before(top_left)) break :blk OffsetRange{ .start = text.len, .end = text.len };
        const boundary = scalarBoundaryBeforePin(text, pin_map, top_left) orelse return null;
        break :blk OffsetRange{ .start = boundary, .end = boundary };
    };
    const end = scalarRangeForPin(text, pin_map, bottom_right) orelse blk: {
        if (bottom_right.before(first_pin)) break :blk OffsetRange{ .start = 0, .end = 0 };
        if (last_pin.before(bottom_right)) break :blk OffsetRange{ .start = text.len, .end = text.len };
        const boundary = scalarBoundaryBeforePin(text, pin_map, bottom_right) orelse return null;
        break :blk OffsetRange{ .start = boundary, .end = boundary };
    };
    if (start.start >= end.end) return null;
    return .{
        .range = .{ .start = start.start, .end = end.end },
        .active_offset = if (selection.end().eql(top_left)) start.start else end.end,
    };
}

/// Return the text insertion boundary immediately before an unmapped terminal
/// pin. The plain formatter omits trailing blank cells, so a live selection
/// endpoint can be inside the document window without owning any output byte.
fn scalarBoundaryBeforePin(
    text: []const u8,
    pin_map: []const terminal.Pin,
    target: terminal.Pin,
) ?usize {
    var boundary: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const scalar_len = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
        if (text[index] != '\n') {
            const pin = pin_map[index];
            if (target.before(pin)) break;
            if (pin.before(target)) boundary = index + scalar_len;
        }
        index += scalar_len;
    }
    return boundary;
}

fn scalarRangeForPin(
    text: []const u8,
    pin_map: []const terminal.Pin,
    target: terminal.Pin,
) ?OffsetRange {
    var index: usize = 0;
    while (index < text.len) {
        const scalar_len = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
        if (pin_map[index].eql(target)) {
            var end = index + scalar_len;
            while (end < text.len and text[end] != '\n' and pin_map[end].eql(target)) {
                end += std.unicode.utf8ByteSequenceLength(text[end]) catch return null;
            }
            return .{ .start = index, .end = end };
        }
        index += scalar_len;
    }
    return null;
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

test "accessible snapshot keeps the live caret truthful while scrolled back" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 20,
        .rows = 3,
        .max_scrollback = 100,
    });
    defer t.deinit(std.testing.allocator);

    try t.printString("row-0\nrow-1\nrow-2\nrow-3\ntail");
    t.cursorLeft(2);
    var active = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer active.deinit();
    try std.testing.expectEqual(@as(u8, 'i'), active.text[active.caret_offset]);

    t.screens.active.scroll(.{ .delta_row = -2 });
    var scrolled = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer scrolled.deinit();

    try std.testing.expectEqualStrings(active.text, scrolled.text);
    try std.testing.expectEqual(active.caret_offset, scrolled.caret_offset);
    try std.testing.expect(!std.meta.eql(active.visible_range, scrolled.visible_range));
    try std.testing.expect(scrolled.caret_offset > scrolled.visible_range.end);
    try std.testing.expectEqual(@as(u8, 'i'), scrolled.text[scrolled.caret_offset]);
}

test "accessible snapshot keeps a deeply scrolled viewport inside the document window" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 20,
        .rows = 3,
        .max_scrollback = 10_000_000,
    });
    defer t.deinit(std.testing.allocator);

    var line: [32]u8 = undefined;
    for (0..900) |index| {
        const value = try std.fmt.bufPrint(&line, "row-{d:0>3}\n", .{index});
        try t.printString(value);
    }

    // Scroll farther back than the history budget, so the viewport and the
    // active screen can no longer share one bounded window.
    t.screens.active.scroll(.top);
    var snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer snapshot.deinit();

    // The viewport is on screen, so it must be reported as visible rather than
    // collapsed to a degenerate range at the end of the document.
    try std.testing.expect(snapshot.visible_range.start < snapshot.visible_range.end);
    const visible = snapshot.text[snapshot.visible_range.start..snapshot.visible_range.end];
    try std.testing.expect(std.mem.indexOf(u8, visible, "row-000") != null);
    try std.testing.expect(std.mem.indexOf(u8, visible, "row-002") != null);
    for (snapshot.cell_for_byte[snapshot.visible_range.start..snapshot.visible_range.end]) |cell| {
        try std.testing.expect(cell.row >= 0);
        try std.testing.expect(cell.row < 3);
    }

    // Sliding the window must not grow it past the same history budget.
    var line_count: usize = 1;
    for (snapshot.text) |byte| if (byte == '\n') {
        line_count += 1;
    };
    const history_rows = accessibleHistoryRows(t.screens.active.pages.cols, true);
    try std.testing.expect(line_count <= history_rows + 3);
}

test "accessible snapshot exposes ordered terminal selection and active end" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10,
    });
    defer t.deinit(std.testing.allocator);
    try t.printString("abcdef\nghijkl\nmnopqr");

    const screen = t.screens.active;
    const first = screen.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?;
    const last = screen.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?;
    try screen.select(terminal.Selection.init(first, last, false));
    var forward = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer forward.deinit();
    const forward_range = forward.selection_range.?;
    try std.testing.expectEqualStrings("bcdef\nghij", forward.text[forward_range.start..forward_range.end]);
    try std.testing.expectEqual(forward_range.end, forward.selection_active_offset.?);

    try screen.select(terminal.Selection.init(last, first, false));
    var reverse = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer reverse.deinit();
    try std.testing.expectEqual(forward_range, reverse.selection_range.?);
    try std.testing.expectEqual(reverse.selection_range.?.start, reverse.selection_active_offset.?);
}

test "accessible selection includes every scalar in the endpoint grapheme" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10,
    });
    defer t.deinit(std.testing.allocator);
    try t.printString("Ae\u{301}B");

    const screen = t.screens.active;
    const anchor = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    const grapheme = screen.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?;
    try screen.select(terminal.Selection.init(anchor, grapheme, false));
    var snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer snapshot.deinit();

    const range = snapshot.selection_range.?;
    try std.testing.expectEqualStrings("Ae\u{301}", snapshot.text[range.start..range.end]);
    try std.testing.expectEqual(range.end, snapshot.selection_active_offset.?);
}

test "accessible selection endpoint excludes the formatter newline" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10,
    });
    defer t.deinit(std.testing.allocator);
    try t.printString("ABCD\nEFGH");

    const screen = t.screens.active;
    const anchor = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    const row_end = screen.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?;
    try screen.select(terminal.Selection.init(anchor, row_end, false));
    var snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer snapshot.deinit();

    const range = snapshot.selection_range.?;
    try std.testing.expectEqualStrings("ABCD", snapshot.text[range.start..range.end]);
    try std.testing.expectEqual(range.end, snapshot.selection_active_offset.?);
}

test "accessible selection clamps trimmed trailing-cell endpoints" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10,
    });
    defer t.deinit(std.testing.allocator);
    try t.printString("AB\nCD");

    const screen = t.screens.active;
    const anchor = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    const trailing = screen.pages.pin(.{ .screen = .{ .x = 6, .y = 0 } }).?;
    try screen.select(terminal.Selection.init(anchor, trailing, false));
    var forward = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer forward.deinit();
    const range = forward.selection_range.?;
    try std.testing.expectEqualStrings("AB", forward.text[range.start..range.end]);
    try std.testing.expectEqual(range.end, forward.selection_active_offset.?);

    try screen.select(terminal.Selection.init(trailing, anchor, false));
    var reverse = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer reverse.deinit();
    try std.testing.expectEqual(range, reverse.selection_range.?);
    try std.testing.expectEqual(range.start, reverse.selection_active_offset.?);
}

test "accessible selection clamps endpoints outside the document window" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10,
    });
    defer t.deinit(std.testing.allocator);

    const screen = t.screens.active;
    const before = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    const middle = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    const after = screen.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?;
    const pin_map = [_]terminal.Pin{middle};

    try screen.select(terminal.Selection.init(before, after, false));
    const forward = selectionOffsets("M", &pin_map, screen).?;
    try std.testing.expectEqual(OffsetRange{ .start = 0, .end = 1 }, forward.range);
    try std.testing.expectEqual(@as(usize, 1), forward.active_offset);

    try screen.select(terminal.Selection.init(after, before, false));
    const reverse = selectionOffsets("M", &pin_map, screen).?;
    try std.testing.expectEqual(forward.range, reverse.range);
    try std.testing.expectEqual(@as(usize, 0), reverse.active_offset);

    const before_end = screen.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?;
    try screen.select(terminal.Selection.init(before, before_end, false));
    try std.testing.expect(selectionOffsets("M", &pin_map, screen) == null);
}

test "rectangular terminal selection exposes only its active row" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10,
    });
    defer t.deinit(std.testing.allocator);
    try t.printString("abcdef\nghijkl\nmnopqr");

    const screen = t.screens.active;
    const anchor = screen.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?;
    const active = screen.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?;
    try screen.select(terminal.Selection.init(anchor, active, true));
    var snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer snapshot.deinit();

    const range = snapshot.selection_range.?;
    try std.testing.expectEqualStrings("nop", snapshot.text[range.start..range.end]);
    try std.testing.expectEqual(range.end, snapshot.selection_active_offset.?);

    const line_end_active = screen.pages.pin(.{ .screen = .{ .x = 5, .y = 0 } }).?;
    try screen.select(terminal.Selection.init(anchor, line_end_active, true));
    var line_end_snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer line_end_snapshot.deinit();

    const line_end_range = line_end_snapshot.selection_range.?;
    try std.testing.expectEqualStrings("bcdef", line_end_snapshot.text[line_end_range.start..line_end_range.end]);
    try std.testing.expectEqual(line_end_range.end, line_end_snapshot.selection_active_offset.?);

    const trailing_active = screen.pages.pin(.{ .screen = .{ .x = 7, .y = 0 } }).?;
    try screen.select(terminal.Selection.init(anchor, trailing_active, true));
    var trailing_snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer trailing_snapshot.deinit();

    const trailing_range = trailing_snapshot.selection_range.?;
    try std.testing.expectEqualStrings("bcdef", trailing_snapshot.text[trailing_range.start..trailing_range.end]);
    try std.testing.expectEqual(trailing_range.end, trailing_snapshot.selection_active_offset.?);
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
