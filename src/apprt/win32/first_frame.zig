//! One-shot "the window is on screen now, draw something" handshake.
//!
//! Win32 presents only from `WM_PAINT`, and a `WM_PAINT` only draws when the
//! renderer thread has reserved a frame for it. Both halves of that handshake
//! are latched booleans (`Surface.paint_pending`,
//! `Surface.renderer_repaint_requested`) with no timeout, and both are armed
//! while the top-level host window is still hidden: the host is created
//! hidden and only shown at the end of `Surface.init`, after GL and core
//! initialization have succeeded. A request that is issued in that hidden
//! window and never answered by a real `WM_PAINT` leaves both latches set,
//! after which every later repaint request coalesces into a reservation that
//! is never completed and every invalidate is dropped as "already pending".
//! The surface then stays on its background clear until something forces a
//! paint out of band (a resize, or the app-mailbox drain that the next
//! dispatched input message happens to run). That is issue #224.
//!
//! This state machine is the missing edge: it turns "the window became
//! visible" and "the OS asked us to paint and we had nothing to give it"
//! into a bounded number of explicit frame requests. It is deliberately
//! terminal — at most two requests per surface for the whole process
//! lifetime — so it cannot become a steady-state repaint source and cannot
//! regress the #134 idle budget.

const std = @import("std");

/// What the apprt observed.
pub const Event = enum {
    /// A show or window-position message reported the host window visible.
    host_shown,
    /// A `WM_PAINT` ran with a renderer frame reserved, so real content was
    /// handed to the GL swap.
    content_presented,
    /// A `WM_PAINT` ran with no renderer frame reserved. The OS believes the
    /// window needs pixels and the renderer had none ready.
    paint_without_content,
};

/// What the apprt must do about it.
pub const Action = enum {
    /// Nothing. Either the handshake already finished, or this event adds no
    /// information.
    none,
    /// Re-sync occlusion, wake the renderer with `.apprt_first_show`, and
    /// force a paint now.
    request_frame,
};

pub const State = struct {
    /// The `host_shown` one-shot has fired.
    shown_requested: bool = false,
    /// The `paint_without_content` one-shot has fired.
    paint_requested: bool = false,
    /// Content reached a swap; the handshake is over for good.
    settled: bool = false,

    pub fn observe(self: *State, event: Event) Action {
        if (self.settled) return .none;

        switch (event) {
            .host_shown => {
                if (self.shown_requested) return .none;
                self.shown_requested = true;
                return .request_frame;
            },

            .content_presented => {
                self.settled = true;
                return .none;
            },

            // A paint with nothing reserved is the exact shape of the stall:
            // the OS is asking and the renderer is not answering. One
            // recovery is enough — if it does not produce content, the
            // surface has a different problem and repeating this would just
            // spin the message pump.
            .paint_without_content => {
                if (self.paint_requested) return .none;
                self.paint_requested = true;
                return .request_frame;
            },
        }
    }

    /// True once content has been presented. Used only by tests and by the
    /// trace so a stalled startup is visible in evidence.
    pub fn isSettled(self: *const State) bool {
        return self.settled;
    }
};

test "first show requests exactly one frame" {
    var state: State = .{};
    try std.testing.expectEqual(Action.request_frame, state.observe(.host_shown));
    // Every later show message (restore, z-order change, virtual desktop
    // switch) is a no-op: the one-shot is spent.
    try std.testing.expectEqual(Action.none, state.observe(.host_shown));
    try std.testing.expectEqual(Action.none, state.observe(.host_shown));
    try std.testing.expect(!state.isSettled());
}

test "a paint with no reserved frame gets one recovery request" {
    var state: State = .{};
    try std.testing.expectEqual(Action.request_frame, state.observe(.paint_without_content));
    try std.testing.expectEqual(Action.none, state.observe(.paint_without_content));
    try std.testing.expectEqual(Action.none, state.observe(.paint_without_content));
}

test "show and paint recoveries are independent and bounded at two" {
    var state: State = .{};
    var requests: usize = 0;
    for (0..64) |i| {
        const event: Event = if (i % 2 == 0) .host_shown else .paint_without_content;
        if (state.observe(event) == .request_frame) requests += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), requests);
}

test "presented content ends the handshake permanently" {
    var state: State = .{};
    try std.testing.expectEqual(Action.request_frame, state.observe(.host_shown));
    try std.testing.expectEqual(Action.none, state.observe(.content_presented));
    try std.testing.expect(state.isSettled());

    // After a settle nothing can rearm it: this is what keeps a window that
    // is hidden and shown a thousand times from becoming a wake source.
    try std.testing.expectEqual(Action.none, state.observe(.host_shown));
    try std.testing.expectEqual(Action.none, state.observe(.paint_without_content));
    try std.testing.expectEqual(Action.none, state.observe(.content_presented));
}

test "content presented before any show still settles" {
    // The healthy ordering on machines that never reproduced #224: the
    // renderer reserves a frame during `Surface.init` and the first
    // post-show `WM_PAINT` draws it. The show one-shot never has to fire.
    var state: State = .{};
    try std.testing.expectEqual(Action.none, state.observe(.content_presented));
    try std.testing.expectEqual(Action.none, state.observe(.host_shown));
    try std.testing.expect(state.isSettled());
}
