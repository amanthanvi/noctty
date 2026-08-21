//! Tab drag state machine, insertion-index math, and CF_NOCTTY_TAB
//! payload format for cross-window tab transfer.
//!
//! State machine semantics:
//!   none      — idle; no press tracked.
//!   maybe_tab — mouse is down on a tab header but hasn't moved beyond
//!               the drag threshold yet. Release in this state activates
//!               the tab (click). Movement beyond the threshold promotes
//!               to drag_tab.
//!   drag_tab  — full drag in progress; the Host paints a drop indicator
//!               and the cursor reflects drag feedback.
//!
//! The threshold uses L1 (Manhattan) distance: abs(dx) + abs(dy). We
//! pick 5 px rather than the system SM_CXDRAG/SM_CYDRAG (typically 4 at
//! 96 DPI) to forgive touchpad jitter on high-precision trackpads. L1
//! over Euclidean avoids a sqrt and matches how Windows internally
//! resolves the drag rectangle (independent per-axis check).
//!
//! PID sentinel security model:
//!   The `Payload.pid` field is a correctness guard, not a security
//!   boundary. A local attacker with the same integrity level can forge
//!   the PID trivially. The sentinel exists to reject:
//!     (a) accidental cross-process drops (two noctty instances),
//!     (b) clipboard format name collisions with unrelated apps,
//!     (c) stale data from a crashed source process.
//!   Real cross-process tab transfer (if ever needed) requires shared
//!   memory or a dedicated IPC channel — not a raw pointer in a
//!   clipboard payload.

const std = @import("std");

// ---------------------------------------------------------------------------
// Drag threshold
// ---------------------------------------------------------------------------

/// Pixel movement beyond this threshold from the mousedown point
/// promotes `maybe_tab` -> `drag_tab`. Matches Windows Explorer's
/// SM_CXDRAG / SM_CYDRAG default (typically 4px at 96 DPI); we
/// pick 5 to forgive touchpad jitter.
pub const drag_threshold_px: i32 = 5;

// ---------------------------------------------------------------------------
// State + Gesture
// ---------------------------------------------------------------------------

pub const State = enum {
    none,
    /// Mouse is down on a tab but hasn't moved far enough yet.
    /// Release -> activate tab. Move >= threshold -> drag_tab.
    maybe_tab,
    /// Full drag in progress; drop indicator painted.
    drag_tab,
};

pub const Gesture = enum { activate, drop, ignore };

// ---------------------------------------------------------------------------
// DragState
// ---------------------------------------------------------------------------

pub const DragState = struct {
    state: State = .none,
    /// Origin of the press, in host client coordinates.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    /// Index of the tab under the mousedown. Meaningful when
    /// `state != .none`.
    source_index: usize = 0,

    pub fn init() DragState {
        return .{};
    }

    /// Start a maybe-drag from `(x, y)` on tab `index`. If the
    /// state was already non-idle, this resets cleanly -- caller
    /// guarantees they called `end()` at the previous release.
    pub fn beginPress(self: *DragState, x: i32, y: i32, index: usize) void {
        self.* = .{
            .state = .maybe_tab,
            .origin_x = x,
            .origin_y = y,
            .source_index = index,
        };
    }

    /// Called on every mousemove while a button is held. Returns
    /// the new state. Transition rules:
    ///   none      -> stays none
    ///   maybe_tab -> maybe_tab if abs(dx) + abs(dy) < threshold
    ///   maybe_tab -> drag_tab  if cumulative movement >= threshold
    ///   drag_tab  -> drag_tab  (steady)
    pub fn onMouseMove(self: *DragState, x: i32, y: i32) State {
        switch (self.state) {
            .none => return .none,
            .maybe_tab => {
                const dx = if (x >= self.origin_x) x - self.origin_x else self.origin_x - x;
                const dy = if (y >= self.origin_y) y - self.origin_y else self.origin_y - y;
                if (dx + dy >= drag_threshold_px) {
                    self.state = .drag_tab;
                }
                return self.state;
            },
            .drag_tab => return .drag_tab,
        }
    }

    /// Called on mouse-up. Returns the gesture the caller should act on:
    ///   .activate -- user pressed-and-released without dragging
    ///   .drop     -- user dragged; caller resolves the drop location
    ///   .ignore   -- nothing was pressed
    pub fn onMouseUp(self: *DragState) Gesture {
        const prev = self.state;
        self.state = .none;
        return switch (prev) {
            .none => .ignore,
            .maybe_tab => .activate,
            .drag_tab => .drop,
        };
    }

    /// Reset to idle without emitting a gesture -- useful for
    /// cancel paths (Esc pressed mid-drag, window lost capture).
    pub fn cancel(self: *DragState) void {
        self.state = .none;
    }
};

// ---------------------------------------------------------------------------
// Insertion-index math
// ---------------------------------------------------------------------------

pub const TabRect = struct {
    left: i32,
    right: i32,
    index: usize,
};

/// Given the cursor x-coordinate and the list of tab rects (in
/// left-to-right order), return the insertion index a drop would
/// land at. Rules:
///   * Cursor before any tab -> 0
///   * Cursor past all tabs  -> tabs.len
///   * Cursor over tab i's left half  -> i   (before tab i)
///   * Cursor over tab i's right half -> i+1 (after tab i)
/// Ignores `source_index` -- callers who want a no-op index can
/// compare against the returned value.
pub fn insertionIndexAtX(cursor_x: i32, tabs: []const TabRect) usize {
    if (tabs.len == 0) return 0;

    // Before the first tab.
    if (cursor_x < tabs[0].left) return 0;

    // Past the last tab.
    if (cursor_x >= tabs[tabs.len - 1].right) return tabs.len;

    // Scan for the tab the cursor sits over.
    for (tabs) |tab| {
        if (cursor_x >= tab.left and cursor_x < tab.right) {
            const mid = tab.left + @divTrunc(tab.right - tab.left, 2);
            return if (cursor_x < mid) tab.index else tab.index + 1;
        }
    }

    // Cursor is in a gap between tabs (shouldn't happen with a
    // contiguous strip, but handle gracefully).
    return tabs.len;
}

/// True when dropping a tab from `source_index` at
/// `insertion_index` is a no-op (same slot). Dropping at index i
/// means "insert before the item currently at i". When the source
/// is removed first, `insertion_index == source_index` means the
/// tab would land back in its original position. So does
/// `insertion_index == source_index + 1`, because removing the
/// source shifts everything after it left by one, placing the tab
/// right back where it was.
pub fn isNoOpDrop(source_index: usize, insertion_index: usize) bool {
    return insertion_index == source_index or insertion_index == source_index + 1;
}

// ---------------------------------------------------------------------------
// CF_NOCTTY_TAB payload
// ---------------------------------------------------------------------------

/// Registered clipboard format name: "io.github.amanthanvi.noctty.tab.v1"
pub const clipboard_format_name = "io.github.amanthanvi.noctty.tab.v1";

/// Bytes we put on the drag data object. Includes a PID sentinel
/// so cross-process drops (different noctty install, or a
/// spoof attempt) fail cleanly on decode. The pointer is a
/// `*DragState` -- caller interprets it. `version` is a u32 for
/// forward-compat (bump when the payload shape changes).
pub const Payload = extern struct {
    magic: u64 = magic_value,
    version: u32 = 1,
    pid: u32,
    state_ptr: usize,

    /// "WGTABV1\0" packed little-endian.
    pub const magic_value: u64 = 0x0031_5642_4154_4757;
};

pub fn encodePayload(source_pid: u32, state: *anyopaque) Payload {
    return .{
        .pid = source_pid,
        .state_ptr = @intFromPtr(state),
    };
}

pub const DecodeError = error{
    BadMagic,
    BadVersion,
    WrongProcess,
};

/// Verify the payload and return the opaque state pointer. Errors
/// if the magic is wrong (random bytes or format mixup), the
/// version doesn't match ours, or the pid doesn't match the
/// current process (cross-process drop -- rejected by design;
/// tab transfer requires shared memory).
pub fn decodePayload(
    payload: Payload,
    current_pid: u32,
) DecodeError!*anyopaque {
    if (payload.magic != Payload.magic_value) return error.BadMagic;
    if (payload.version != 1) return error.BadVersion;
    if (payload.pid != current_pid) return error.WrongProcess;
    return @ptrFromInt(payload.state_ptr);
}

// ===========================================================================
// Tests
// ===========================================================================

test "beginPress + immediate release -> activate" {
    var ds = DragState.init();
    ds.beginPress(100, 50, 3);
    const g = ds.onMouseUp();
    try std.testing.expectEqual(Gesture.activate, g);
    try std.testing.expectEqual(State.none, ds.state);
}

test "small move stays in maybe_tab" {
    var ds = DragState.init();
    ds.beginPress(100, 50, 0);
    const s = ds.onMouseMove(103, 50); // 3 px L1 < 5
    try std.testing.expectEqual(State.maybe_tab, s);
}

test "move past threshold promotes to drag_tab" {
    var ds = DragState.init();
    ds.beginPress(100, 50, 1);
    const s = ds.onMouseMove(110, 50); // 10 px L1 >= 5
    try std.testing.expectEqual(State.drag_tab, s);
    const g = ds.onMouseUp();
    try std.testing.expectEqual(Gesture.drop, g);
}

test "cancel from drag_tab returns to none" {
    var ds = DragState.init();
    ds.beginPress(100, 50, 2);
    _ = ds.onMouseMove(200, 50);
    try std.testing.expectEqual(State.drag_tab, ds.state);
    ds.cancel();
    try std.testing.expectEqual(State.none, ds.state);
}

test "idle onMouseUp emits ignore" {
    var ds = DragState.init();
    const g = ds.onMouseUp();
    try std.testing.expectEqual(Gesture.ignore, g);
}

test "diagonal movement uses L1 distance" {
    var ds = DragState.init();
    ds.beginPress(100, 100, 0);
    // (3,3) -> |3|+|3| = 6 >= 5 -> drag_tab
    const s = ds.onMouseMove(103, 103);
    try std.testing.expectEqual(State.drag_tab, s);
}

test "before all tabs -> 0" {
    const tabs = [_]TabRect{
        .{ .left = 0, .right = 100, .index = 0 },
        .{ .left = 100, .right = 200, .index = 1 },
    };
    try std.testing.expectEqual(@as(usize, 0), insertionIndexAtX(-10, &tabs));
}

test "past all tabs -> len" {
    const tabs = [_]TabRect{
        .{ .left = 0, .right = 100, .index = 0 },
        .{ .left = 100, .right = 200, .index = 1 },
    };
    try std.testing.expectEqual(@as(usize, 2), insertionIndexAtX(500, &tabs));
}

test "left half of tab -> i" {
    const tabs = [_]TabRect{
        .{ .left = 0, .right = 100, .index = 0 },
        .{ .left = 100, .right = 200, .index = 1 },
    };
    try std.testing.expectEqual(@as(usize, 0), insertionIndexAtX(30, &tabs));
}

test "right half of tab -> i+1" {
    const tabs = [_]TabRect{
        .{ .left = 0, .right = 100, .index = 0 },
        .{ .left = 100, .right = 200, .index = 1 },
    };
    try std.testing.expectEqual(@as(usize, 1), insertionIndexAtX(75, &tabs));
}

test "empty tabs -> 0" {
    const tabs = [_]TabRect{};
    try std.testing.expectEqual(@as(usize, 0), insertionIndexAtX(42, &tabs));
}

test "same slot" {
    try std.testing.expect(isNoOpDrop(2, 2));
}

test "source slides right by one on same-position drop" {
    try std.testing.expect(isNoOpDrop(2, 3));
}

test "different slot -> not no-op" {
    try std.testing.expect(!isNoOpDrop(2, 5));
}

test "encode/decode roundtrip" {
    var dummy: u8 = 0;
    const pid: u32 = 1234;
    const payload = encodePayload(pid, @ptrCast(&dummy));
    const ptr = try decodePayload(payload, pid);
    try std.testing.expectEqual(@intFromPtr(&dummy), @intFromPtr(ptr));
}

test "wrong PID rejects" {
    var dummy: u8 = 0;
    const payload = encodePayload(1234, @ptrCast(&dummy));
    try std.testing.expectError(error.WrongProcess, decodePayload(payload, 5678));
}

test "bad magic rejects" {
    var dummy: u8 = 0;
    var payload = encodePayload(1234, @ptrCast(&dummy));
    payload.magic = 0xDEAD_BEEF;
    try std.testing.expectError(error.BadMagic, decodePayload(payload, 1234));
}

test "bad version rejects" {
    var dummy: u8 = 0;
    var payload = encodePayload(1234, @ptrCast(&dummy));
    payload.version = 99;
    try std.testing.expectError(error.BadVersion, decodePayload(payload, 1234));
}
