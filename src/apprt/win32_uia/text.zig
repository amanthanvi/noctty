//! Terminal text for the UIA text pattern: the bounded, pointer-free document
//! snapshot `TerminalProvider` serves, built while the caller holds the
//! renderer lock.

const std = @import("std");
const terminal = @import("../../terminal/main.zig");

pub const OffsetRange = struct {
    start: usize,
    end: usize,
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

const Node = @typeInfo(@FieldType(terminal.Pin, "node")).pointer.child;

/// Screen rows of pins taken in document order. `pointFromPin` finds a pin by
/// walking the page list from its first page, so a call costs as much as the
/// scrollback is deep. Only the first pin (or one that is out of order) pays
/// that; every later pin on the same page or the next one follows from the
/// page's first row, which is how the formatter's pin map is laid out.
const ScreenRows = struct {
    pages: *const terminal.PageList,
    /// The page of the last pin resolved and the screen row of its first row.
    node: ?*Node = null,
    node_top: usize = 0,
    /// How many pins had to be located from the first page.
    walks: usize = 0,

    fn of(self: *ScreenRows, pin: terminal.Pin) ?usize {
        if (self.node) |node| {
            if (pin.node == node) return self.node_top + pin.y;
            if (pin.node == node.next) {
                self.node = pin.node;
                self.node_top += node.data.size.rows;
                return self.node_top + pin.y;
            }
        }

        const point = self.pages.pointFromPin(.screen, pin) orelse return null;
        self.walks += 1;
        self.node = pin.node;
        self.node_top = point.screen.y - pin.y;
        return point.screen.y;
    }
};

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

    var rows: ScreenRows = .{ .pages = pages };
    var visible_start: ?usize = null;
    var visible_end: usize = 0;
    for (pin_map.items, 0..) |pin, index| {
        const screen_y = rows.of(pin) orelse return error.UnknownPoint;
        const cell = pin.node.data.getRowAndCell(pin.x, pin.y).cell;
        cell_for_byte[index] = .{
            .row = @intCast(@as(i64, @intCast(screen_y)) - viewport_y),
            .column = pin.x,
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
        // `Selection.contains` derives both corners again on every call, which
        // is a handful of page list walks per byte. The active row is an
        // endpoint's row, so it is inside the rectangle's rows and only the
        // columns decide.
        const left = (screen.pages.pointFromPin(.screen, selection.topLeft(screen)) orelse return null).screen.x;
        const right = (screen.pages.pointFromPin(.screen, selection.bottomRight(screen)) orelse return null).screen.x;
        var rows: ScreenRows = .{ .pages = &screen.pages };
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
            const screen_y = rows.of(pin) orelse return null;
            if (screen_y == active.screen.y and pin.x >= left and pin.x <= right) {
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

const numbered_rows: usize = 5_000;

/// Print `numbered_rows` lines ("row-00000" ...), enough to fill several
/// pages (579 rows each at 80 columns), so that the document window crosses a
/// page boundary.
fn printNumberedRows(t: *terminal.Terminal) !void {
    var line: [32]u8 = undefined;
    for (0..numbered_rows) |index| {
        const value = try std.fmt.bufPrint(&line, "row-{d:0>5}\r\n", .{index});
        try t.printString(value);
    }
}

test "screen rows are derived from the page, not walked per pin" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000_000,
    });
    defer t.deinit(std.testing.allocator);
    try printNumberedRows(&t);

    const pages = &t.screens.active.pages;
    var page_count: usize = 0;
    var node = pages.pages.first;
    while (node) |page| : (node = page.next) page_count += 1;
    try std.testing.expect(page_count > 5);

    // Every row, in order and across every page boundary: the same answer as
    // the page list gives, from one walk.
    var rows: ScreenRows = .{ .pages = pages };
    for (0..pages.total_rows) |y| {
        const pin = pages.pin(.{ .screen = .{ .x = 3, .y = @intCast(y) } }).?;
        try std.testing.expectEqual(y, rows.of(pin).?);
    }
    try std.testing.expectEqual(@as(usize, 1), rows.walks);

    // A pin from a page that is neither the same nor the next is located from
    // the first page again, and still comes out right.
    const first = pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    try std.testing.expectEqual(@as(usize, 0), rows.of(first).?);
    try std.testing.expectEqual(@as(usize, 2), rows.walks);
    const jump = pages.pin(.{ .screen = .{ .x = 0, .y = numbered_rows / 2 } }).?;
    try std.testing.expectEqual(@as(usize, numbered_rows / 2), rows.of(jump).?);
    try std.testing.expectEqual(@as(usize, 3), rows.walks);
}

test "accessible snapshot rows match the page list across many pages" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000_000,
    });
    defer t.deinit(std.testing.allocator);
    try printNumberedRows(&t);

    var snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer snapshot.deinit();

    // The last line printed is the screen's second to last row (the cursor is
    // on the blank one below it), which places every other line; its row is
    // that relative to the viewport's top, however many pages the window spans.
    // The newline between two pages is skipped: the formatter gives it the
    // next page's pin, which is not what is under test.
    const pages = &t.screens.active.pages;
    const viewport_y: i64 = @intCast(pages.pointFromPin(.screen, pages.getTopLeft(.viewport)).?.screen.y);
    const last_y: i64 = @as(i64, @intCast(pages.total_rows)) - 2;
    var offset: usize = 0;
    var lines: usize = 0;
    var page_changes: usize = 0;
    var last_node: ?*Node = null;
    while (offset < snapshot.text.len) {
        const end = std.mem.indexOfScalarPos(u8, snapshot.text, offset, '\n') orelse snapshot.text.len;
        const number = try std.fmt.parseInt(usize, snapshot.text[offset + 4 .. offset + 9], 10);
        const screen_y = last_y - (@as(i64, numbered_rows - 1) - @as(i64, @intCast(number)));
        const expected: i32 = @intCast(screen_y - viewport_y);
        for (offset..end) |index| {
            try std.testing.expectEqual(expected, snapshot.cell_for_byte[index].row);
        }
        const pin = pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(screen_y) } }).?;
        if (pin.node != last_node) page_changes += 1;
        last_node = pin.node;
        lines += 1;
        offset = end + 1;
    }
    try std.testing.expect(lines > 400);
    try std.testing.expect(page_changes > 1);
}

test "rectangular selection finds its active row past the first page" {
    var t = try terminal.Terminal.init(std.testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000_000,
    });
    defer t.deinit(std.testing.allocator);
    try printNumberedRows(&t);

    // Both rows are on a later page, where a pin's own `y` is not its screen
    // row, so a row taken from the pin would select another row or none.
    const screen = t.screens.active;
    const total: u32 = @intCast(screen.pages.total_rows);
    const anchor = screen.pages.pin(.{ .screen = .{ .x = 1, .y = total - 6 } }).?;
    const active = screen.pages.pin(.{ .screen = .{ .x = 3, .y = total - 4 } }).?;
    try std.testing.expect(@as(u32, active.y) != total - 4);
    try screen.select(terminal.Selection.init(anchor, active, true));
    var snapshot = try snapshotTerminalAccessiblePlainText(std.testing.allocator, &t);
    defer snapshot.deinit();

    // The last line printed is the second to last row, so the active row is
    // the line two before it.
    const range = snapshot.selection_range orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("ow-", snapshot.text[range.start..range.end]);
    const line_start = if (std.mem.lastIndexOfScalar(u8, snapshot.text[0..range.start], '\n')) |i| i + 1 else 0;
    const number = try std.fmt.parseInt(usize, snapshot.text[line_start + 4 .. line_start + 9], 10);
    try std.testing.expectEqual(numbered_rows - 1 - 2, number);
    try std.testing.expectEqual(range.end, snapshot.selection_active_offset.?);
}
