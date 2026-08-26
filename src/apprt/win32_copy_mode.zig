//! Modal copy mode with vi-style motions (C18).
//!
//! Viewport-relative cursor. Does not intercept the shell editor while
//! inactive. Escape leaves; `y` copies the selection.

const std = @import("std");

pub const Motion = enum {
    left,
    right,
    up,
    down,
    word_forward,
    word_back,
    line_start,
    line_end,
};

pub const State = struct {
    active: bool = false,
    row: u16 = 0,
    col: u16 = 0,
    anchor_row: u16 = 0,
    anchor_col: u16 = 0,
    selecting: bool = false,

    pub fn enter(self: *State, row: u16, col: u16) void {
        self.* = .{
            .active = true,
            .row = row,
            .col = col,
            .anchor_row = row,
            .anchor_col = col,
            .selecting = false,
        };
    }

    pub fn leave(self: *State) void {
        self.* = .{};
    }

    pub fn move(self: *State, motion: Motion, rows: u16, cols: u16) void {
        if (!self.active) return;
        switch (motion) {
            .left => self.col = decrement(self.col),
            .right => self.col = increment(self.col, cols),
            .up => self.row = decrement(self.row),
            .down => self.row = increment(self.row, rows),
            .word_forward => self.col = increment(self.col, cols),
            .word_back => self.col = decrement(self.col),
            .line_start => self.col = 0,
            .line_end => if (cols > 0) {
                self.col = cols - 1;
            },
        }
    }

    pub fn toggleSelect(self: *State) void {
        if (!self.active) return;
        self.selecting = !self.selecting;
        if (self.selecting) {
            self.anchor_row = self.row;
            self.anchor_col = self.col;
        }
    }

    pub fn handleVirtualKey(self: *State, vk: u16, rows: u16, cols: u16) KeyResult {
        if (!self.active) return .ignored;
        switch (vk) {
            0x1B => { // VK_ESCAPE
                self.leave();
                return .left;
            },
            0x48, 0x25 => { // H / Left
                self.move(.left, rows, cols);
                return .moved;
            },
            0x4A, 0x28 => { // J / Down
                self.move(.down, rows, cols);
                return .moved;
            },
            0x4B, 0x26 => { // K / Up
                self.move(.up, rows, cols);
                return .moved;
            },
            0x4C, 0x27 => { // L / Right
                self.move(.right, rows, cols);
                return .moved;
            },
            0x57 => { // W
                self.move(.word_forward, rows, cols);
                return .moved;
            },
            0x42 => { // B
                self.move(.word_back, rows, cols);
                return .moved;
            },
            0x30 => { // 0
                self.move(.line_start, rows, cols);
                return .moved;
            },
            0x24 => { // Home / $
                self.move(.line_end, rows, cols);
                return .moved;
            },
            0x56 => { // V
                self.toggleSelect();
                return .moved;
            },
            0x59 => return .copied, // Y
            else => return .ignored,
        }
    }
};

fn decrement(value: u16) u16 {
    return if (value == 0) 0 else value - 1;
}

fn increment(value: u16, max: u16) u16 {
    if (max == 0) return 0;
    if (value + 1 >= max) return max - 1;
    return value + 1;
}

pub const KeyResult = enum {
    ignored,
    moved,
    copied,
    left,
};

test "copy mode enter move leave" {
    var state: State = .{};
    state.enter(2, 4);
    try std.testing.expect(state.active);
    state.move(.left, 24, 80);
    try std.testing.expectEqual(@as(u16, 3), state.col);
    state.move(.line_start, 24, 80);
    try std.testing.expectEqual(@as(u16, 0), state.col);
    state.toggleSelect();
    try std.testing.expect(state.selecting);
    state.leave();
    try std.testing.expect(!state.active);
}

test "copy mode virtual keys" {
    var state: State = .{};
    try std.testing.expectEqual(KeyResult.ignored, state.handleVirtualKey(0x48, 24, 80));
    state.enter(2, 4);
    try std.testing.expectEqual(KeyResult.moved, state.handleVirtualKey(0x48, 24, 80));
    try std.testing.expectEqual(@as(u16, 3), state.col);
    try std.testing.expectEqual(KeyResult.copied, state.handleVirtualKey(0x59, 24, 80));
    try std.testing.expectEqual(KeyResult.left, state.handleVirtualKey(0x1B, 24, 80));
    try std.testing.expect(!state.active);
}
