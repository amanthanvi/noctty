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

pub const ByteRange = struct {
    start: usize,
    end: usize,
};

pub const TerminalTextSnapshot = struct {
    alloc: std.mem.Allocator,
    text: []u8,
    line_start_offsets: []usize,

    pub fn deinit(self: *TerminalTextSnapshot) void {
        self.alloc.free(self.line_start_offsets);
        self.alloc.free(self.text);
        self.* = undefined;
    }

    pub fn lineCount(self: *const TerminalTextSnapshot) usize {
        return self.line_start_offsets.len;
    }

    pub fn lineByteRange(self: *const TerminalTextSnapshot, line_index: usize) ?ByteRange {
        if (line_index >= self.line_start_offsets.len) return null;

        const start = self.line_start_offsets[line_index];
        const end = if (line_index + 1 < self.line_start_offsets.len)
            self.line_start_offsets[line_index + 1] - 1
        else
            self.text.len;
        return .{ .start = start, .end = end };
    }
};

pub fn snapshotTerminalPlainText(
    alloc: std.mem.Allocator,
    terminal_state: *const terminal.Terminal,
) !TerminalTextSnapshot {
    var text_writer: std.Io.Writer.Allocating = .init(alloc);
    defer text_writer.deinit();

    var formatter = terminal.formatter.TerminalFormatter.init(
        terminal_state,
        .plain,
    );
    formatter.extra = .none;
    try formatter.format(&text_writer.writer);

    const text = try text_writer.toOwnedSlice();
    errdefer alloc.free(text);

    var line_start_offsets: std.ArrayList(usize) = .empty;
    defer line_start_offsets.deinit(alloc);
    try line_start_offsets.append(alloc, 0);
    for (text, 0..) |c, i| {
        if (c == '\n') try line_start_offsets.append(alloc, i + 1);
    }

    return .{
        .alloc = alloc,
        .text = text,
        .line_start_offsets = try line_start_offsets.toOwnedSlice(alloc),
    };
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

    const second = snapshot.lineByteRange(1).?;
    try std.testing.expectEqualStrings("World", snapshot.text[second.start..second.end]);
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
}
