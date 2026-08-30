//! Tracks the most recent command delimited by OSC 133 shell integration.
const SemanticCommand = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const PageList = @import("PageList.zig");
const point = @import("point.zig");
const Pin = PageList.Pin;

/// Prompt whose input has started with OSC 133;B/I but whose output has not.
pending: ?*Pin = null,

/// Prompt whose command has emitted OSC 133;C but not OSC 133;D.
active: ?*Pin = null,

/// Most recent command with a complete OSC 133;B..C..D lifecycle.
completed: ?Completed = null,

const Completed = struct {
    prompt: *Pin,
    /// Inclusive last output cell at OSC 133;D, or null for empty output.
    output_end: ?*Pin,
};

pub const Region = struct {
    start: Pin,
    end: Pin,
};

pub const OutputRegion = union(enum) {
    unavailable,
    empty,
    region: Region,
};

pub fn deinit(self: *SemanticCommand, pages: *PageList) void {
    self.reset(pages);
}

/// Drop every retained pin. The tracker is reusable afterwards.
pub fn reset(self: *SemanticCommand, pages: *PageList) void {
    self.clearPending(pages);
    self.clearActive(pages);
    self.clearCompleted(pages);
}

/// Record OSC 133;B/I, which begins recoverable command input.
pub fn startInput(
    self: *SemanticCommand,
    pages: *PageList,
    semantic_prompt_seen: bool,
    cursor: Pin,
) Allocator.Error!void {
    self.clearPending(pages);
    self.clearActive(pages);

    if (!semantic_prompt_seen) return;
    var it = cursor.promptIterator(.left_up, null);
    const prompt = it.next() orelse return;

    // A shell that redraws in place can start new input on the very row the
    // last completed command was recorded against. Retaining that record
    // would let extraction read the line the user is typing right now.
    if (self.completed) |command| {
        if (command.prompt.*.eql(prompt)) self.clearCompleted(pages);
    }

    self.pending = try pages.trackPin(prompt);
}

/// Record OSC 133;C. Prefer the prompt tracked by OSC 133;B/I, but preserve
/// C..D output recovery even when the shell omitted the input mark.
pub fn startOutput(
    self: *SemanticCommand,
    pages: *PageList,
    semantic_prompt_seen: bool,
    cursor: Pin,
) Allocator.Error!void {
    self.clearActive(pages);
    if (self.pending) |prompt| {
        self.active = prompt;
        self.pending = null;
        return;
    }

    if (!semantic_prompt_seen) return;
    var it = cursor.promptIterator(.left_up, null);
    const prompt = it.next() orelse return;
    self.active = try pages.trackPin(prompt);
}

/// Record OSC 133;D and freeze the completed command's output endpoint.
pub fn endCommand(
    self: *SemanticCommand,
    pages: *PageList,
    cursor: Pin,
) Allocator.Error!void {
    const prompt = self.active orelse return;
    if (!pinIsValid(prompt)) {
        self.clearActive(pages);
        return;
    }

    // highlightSemanticContent scans to the next prompt (or the bottom of
    // the screen), so on its own it can run past the D cursor and pick up
    // stale rows. Clamp to the last text cell at or before the D cursor.
    const output_end = if (pages.highlightSemanticContent(prompt.*, .output)) |hl| end: {
        if (!cursor.before(hl.end)) break :end try pages.trackPin(hl.end);

        // The D cursor can land *above* the first cell the output highlight
        // found — a command that printed nothing, with an older output-marked
        // row still sitting below the cursor. There is no output region at
        // all in that case. Falling through would both keep `hl.start` (a
        // cell after D, so `copy_last_command_output` would hand back stale
        // text) and build a `.left_up` iterator whose limit is after its
        // start, which asserts under slow runtime safety.
        if (cursor.before(hl.start)) break :end null;

        var clamped = hl.start;
        var cell_it = cursor.cellIterator(.left_up, hl.start);
        while (cell_it.next()) |p| {
            clamped = p;
            if (p.rowAndCell().cell.hasText()) break;
        }
        break :end try pages.trackPin(clamped);
    } else null;
    errdefer if (output_end) |pin| pages.untrackPin(pin);

    self.clearCompleted(pages);
    self.completed = .{
        .prompt = prompt,
        .output_end = output_end,
    };
    self.active = null;
}

pub fn commandRunning(self: *const SemanticCommand) bool {
    return self.active != null;
}

/// Whether an OSC 133;B input mark is outstanding, i.e. something has told us
/// it is reading a line of input right now.
///
/// Callers that only *read* history do not need this: absence of an input mark
/// is harmless for copying. Callers that write bytes back do, because it is the
/// only evidence we have that the bytes will land in a line editor at a prompt
/// rather than in whatever else happens to own the pty. A child that emits
/// OSC 133;A without a following B clears `active`, so a "no command is
/// running" check alone would happily type into that child.
pub fn inputPending(self: *const SemanticCommand) bool {
    const pending = self.pending orelse return false;
    return pinIsValid(pending);
}

/// Discard B/C state when a new prompt begins without a completing D mark.
pub fn abortCommand(self: *SemanticCommand, pages: *PageList) void {
    self.clearPending(pages);
    self.clearActive(pages);
}

/// Drop retained state whose recovered span overlaps a range about to be
/// erased, before PageList can relocate those pins onto unrelated rows.
pub fn invalidateRange(
    self: *SemanticCommand,
    pages: *PageList,
    tl: point.Point,
    bl: ?point.Point,
) void {
    var top = pages.pin(tl) orelse return;
    top.x = 0;

    var bottom = if (bl) |pt|
        pages.pin(pt) orelse return
    else
        pages.getBottomRight(tl) orelse return;
    bottom.x = pages.cols - 1;

    if (self.pending) |pin| {
        if (pin.*.isBetween(top, bottom)) self.clearPending(pages);
    }
    if (self.active) |pin| {
        if (pin.*.isBetween(top, bottom)) self.clearActive(pages);
    }
    if (self.completed) |command| {
        const command_end = if (command.output_end) |pin|
            pin.*
        else if (pages.highlightSemanticContent(command.prompt.*, .input)) |hl|
            hl.end
        else
            command.prompt.*;
        if (pinRangesOverlap(command.prompt.*, command_end, top, bottom)) {
            self.clearCompleted(pages);
        }
    }
}

fn pinRangesOverlap(a_top: Pin, a_bottom: Pin, b_top: Pin, b_bottom: Pin) bool {
    return !a_bottom.before(b_top) and !b_bottom.before(a_top);
}

/// With scrollback disabled, PageList shifts active rows in place rather than
/// pruning a page, so tracked pins are not marked garbage.
pub fn invalidateActiveTopRow(
    self: *SemanticCommand,
    pages: *PageList,
) void {
    const top = pages.getTopLeft(.active);

    if (self.pending) |pin| {
        if (pin.*.eql(top)) self.clearPending(pages);
    }
    if (self.active) |pin| {
        if (pin.*.eql(top)) self.clearActive(pages);
    }
    if (self.completed) |command| {
        if (command.prompt.*.eql(top)) self.clearCompleted(pages);
    }
}

pub fn inputRegion(
    self: *const SemanticCommand,
    pages: *const PageList,
) ?Region {
    const command = self.lastCompleted() orelse return null;
    const hl = pages.highlightSemanticContent(
        command.prompt.*,
        .input,
    ) orelse return null;

    return .{ .start = hl.start, .end = hl.end };
}

pub fn outputRegion(
    self: *const SemanticCommand,
    pages: *const PageList,
) OutputRegion {
    const command = self.lastCompleted() orelse return .unavailable;
    const output_end = command.output_end orelse return .empty;
    if (output_end.garbage) return .unavailable;

    const hl = pages.highlightSemanticContent(
        command.prompt.*,
        .output,
    ) orelse return .unavailable;
    if (!output_end.*.isBetween(hl.start, hl.end)) return .unavailable;

    return .{ .region = .{
        .start = hl.start,
        .end = output_end.*,
    } };
}

fn clearPending(self: *SemanticCommand, pages: *PageList) void {
    if (self.pending) |pin| pages.untrackPin(pin);
    self.pending = null;
}

fn clearActive(self: *SemanticCommand, pages: *PageList) void {
    if (self.active) |pin| pages.untrackPin(pin);
    self.active = null;
}

fn clearCompleted(self: *SemanticCommand, pages: *PageList) void {
    if (self.completed) |command| {
        pages.untrackPin(command.prompt);
        if (command.output_end) |pin| pages.untrackPin(pin);
    }
    self.completed = null;
}

fn lastCompleted(self: *const SemanticCommand) ?Completed {
    const command = self.completed orelse return null;
    if (!pinIsValid(command.prompt)) return null;
    if (!self.precedesActiveInput(command)) return null;
    return command;
}

/// A completed command has to sit strictly above the prompt the user is
/// typing into right now.
///
/// The invalidation hooks above cover the paths that erase rows, but they are
/// not the only ways a row moves. `PageList.eraseRowBounded` (the scrolling
/// fast path), `Terminal.insertLines` and `Terminal.deleteLines` all rotate
/// row contents and then *shift tracked pins by hand* without marking them
/// garbage — so a retained record can be carried onto the row holding
/// unsubmitted input, and `pinIsValid` still passes because that row is a
/// real prompt row. Rather than hooking every one of those hot paths (and
/// paying for it on every scroll, and silently regressing the next time one
/// is added), re-check the relationship at read time.
///
/// `pending` is the prompt whose OSC 133;B input mark has been seen but whose
/// output has not — precisely "the line the user is typing". When no input
/// mark is outstanding there is nothing unsubmitted to protect and the record
/// stands.
fn precedesActiveInput(self: *const SemanticCommand, command: Completed) bool {
    const pending = self.pending orelse return true;
    if (sameRow(command.prompt.*, pending.*)) return false;
    return command.prompt.*.before(pending.*);
}

fn sameRow(a: Pin, b: Pin) bool {
    return a.node == b.node and a.y == b.y;
}

fn pinIsValid(pin: *const Pin) bool {
    if (pin.garbage) return false;

    // PageList callers require a real semantic prompt row before invoking
    // promptIterator/highlightSemanticContent.
    return switch (pin.rowAndCell().row.semantic_prompt) {
        .prompt, .prompt_continuation => true,
        .none => false,
    };
}
