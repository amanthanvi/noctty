//! Keyboard focus-region model for the Win32 host window.
//!
//! Windows convention is F6 / Shift+F6 to move keyboard focus between the
//! panes of a window's chrome. This module owns the cycle order and the
//! rule for skipping a region that is not currently on screen, as pure
//! data so it can be tested without a window. `win32.zig` owns the
//! mapping from a region to the HWND that actually takes focus, because
//! only real Win32 focus raises a UIA focus-changed event.

const std = @import("std");

/// The focusable regions of a host window, in cycle order.
///
/// `terminal` is the active pane; the rest is chrome. The order is the
/// on-screen reading order of the default layout: tab strip above the
/// terminal, docked search below it, host banner below that.
pub const Region = enum {
    terminal,
    tab_strip,
    search,
    banner,
};

pub const Direction = enum {
    next,
    previous,
};

/// Which regions can take focus right now. A region whose HWND does not
/// exist, or exists but is hidden, is not available and is skipped rather
/// than focused invisibly.
pub const Availability = struct {
    terminal: bool = false,
    tab_strip: bool = false,
    search: bool = false,
    banner: bool = false,

    pub fn has(self: Availability, region: Region) bool {
        return switch (region) {
            .terminal => self.terminal,
            .tab_strip => self.tab_strip,
            .search => self.search,
            .banner => self.banner,
        };
    }

    pub fn count(self: Availability) usize {
        var total: usize = 0;
        for (cycle_order) |region| {
            if (self.has(region)) total += 1;
        }
        return total;
    }
};

pub const cycle_order = [_]Region{ .terminal, .tab_strip, .search, .banner };

fn orderIndex(region: Region) usize {
    return switch (region) {
        .terminal => 0,
        .tab_strip => 1,
        .search => 2,
        .banner => 3,
    };
}

/// The first available region in cycle order, or the last one for
/// `.previous`. Used when focus is not currently in any known region, so
/// the cycle still has somewhere to land.
pub fn edge(availability: Availability, direction: Direction) ?Region {
    switch (direction) {
        .next => for (cycle_order) |region| {
            if (availability.has(region)) return region;
        },
        .previous => {
            var i: usize = cycle_order.len;
            while (i > 0) {
                i -= 1;
                if (availability.has(cycle_order[i])) return cycle_order[i];
            }
        },
    }
    return null;
}

/// The region focus should move to from `current`.
///
/// Returns null when there is nowhere else to go: no available region at
/// all, or `current` is the only available one. Callers treat null as
/// "leave focus alone" rather than as an error, so a single-region window
/// does not raise a focus event that says nothing changed.
///
/// `current` may name a region that is no longer available — focus can sit
/// on a search bar that is closing — and the walk still starts from its
/// position in the order.
pub fn next(
    availability: Availability,
    current: ?Region,
    direction: Direction,
) ?Region {
    const from = current orelse return edge(availability, direction);
    var index = orderIndex(from);
    for (0..cycle_order.len) |_| {
        index = switch (direction) {
            .next => (index + 1) % cycle_order.len,
            .previous => (index + cycle_order.len - 1) % cycle_order.len,
        };
        const candidate = cycle_order[index];
        if (candidate == from) continue;
        if (availability.has(candidate)) return candidate;
    }
    return null;
}

/// Where Escape sends focus from a chrome region. Escape always returns to
/// the terminal, and does nothing when focus is already there or when
/// there is no terminal to return to.
pub fn escapeTarget(availability: Availability, current: ?Region) ?Region {
    const from = current orelse return null;
    if (from == .terminal) return null;
    if (!availability.terminal) return null;
    return .terminal;
}

test "cycle order is the on-screen reading order" {
    try std.testing.expectEqual(@as(usize, 4), cycle_order.len);
    try std.testing.expectEqual(Region.terminal, cycle_order[0]);
    try std.testing.expectEqual(Region.tab_strip, cycle_order[1]);
    try std.testing.expectEqual(Region.search, cycle_order[2]);
    try std.testing.expectEqual(Region.banner, cycle_order[3]);
}

test "forward cycle visits every available region and wraps" {
    const all: Availability = .{
        .terminal = true,
        .tab_strip = true,
        .search = true,
        .banner = true,
    };
    try std.testing.expectEqual(@as(usize, 4), all.count());
    try std.testing.expectEqual(Region.tab_strip, next(all, .terminal, .next).?);
    try std.testing.expectEqual(Region.search, next(all, .tab_strip, .next).?);
    try std.testing.expectEqual(Region.banner, next(all, .search, .next).?);
    try std.testing.expectEqual(Region.terminal, next(all, .banner, .next).?);
}

test "backward cycle is the exact inverse" {
    const all: Availability = .{
        .terminal = true,
        .tab_strip = true,
        .search = true,
        .banner = true,
    };
    for (cycle_order) |region| {
        const forward = next(all, region, .next).?;
        try std.testing.expectEqual(region, next(all, forward, .previous).?);
    }
}

test "hidden regions are skipped, not focused invisibly" {
    // Docked search closed, no banner: the cycle is terminal <-> tabs.
    const chrome_only: Availability = .{ .terminal = true, .tab_strip = true };
    try std.testing.expectEqual(Region.tab_strip, next(chrome_only, .terminal, .next).?);
    try std.testing.expectEqual(Region.terminal, next(chrome_only, .tab_strip, .next).?);
    try std.testing.expectEqual(Region.tab_strip, next(chrome_only, .terminal, .previous).?);

    // Search open, banner absent.
    const with_search: Availability = .{ .terminal = true, .tab_strip = true, .search = true };
    try std.testing.expectEqual(Region.search, next(with_search, .tab_strip, .next).?);
    try std.testing.expectEqual(Region.terminal, next(with_search, .search, .next).?);

    // Banner up, search closed.
    const with_banner: Availability = .{ .terminal = true, .tab_strip = true, .banner = true };
    try std.testing.expectEqual(Region.banner, next(with_banner, .tab_strip, .next).?);
    try std.testing.expectEqual(Region.tab_strip, next(with_banner, .banner, .previous).?);
}

test "a lone region has nowhere to move" {
    const only_terminal: Availability = .{ .terminal = true };
    try std.testing.expectEqual(@as(?Region, null), next(only_terminal, .terminal, .next));
    try std.testing.expectEqual(@as(?Region, null), next(only_terminal, .terminal, .previous));

    const nothing: Availability = .{};
    try std.testing.expectEqual(@as(?Region, null), next(nothing, .terminal, .next));
    try std.testing.expectEqual(@as(?Region, null), next(nothing, null, .next));
    try std.testing.expectEqual(@as(?Region, null), edge(nothing, .next));
}

test "unknown focus lands on an edge of the cycle" {
    const all: Availability = .{
        .terminal = true,
        .tab_strip = true,
        .search = true,
        .banner = true,
    };
    try std.testing.expectEqual(Region.terminal, next(all, null, .next).?);
    try std.testing.expectEqual(Region.banner, next(all, null, .previous).?);

    const no_terminal: Availability = .{ .tab_strip = true, .search = true };
    try std.testing.expectEqual(Region.tab_strip, next(no_terminal, null, .next).?);
    try std.testing.expectEqual(Region.search, next(no_terminal, null, .previous).?);
}

test "a region that just became unavailable still cycles from its position" {
    // Focus sits on the docked search while it is being dismissed.
    const closing: Availability = .{ .terminal = true, .tab_strip = true };
    try std.testing.expectEqual(Region.terminal, next(closing, .search, .next).?);
    try std.testing.expectEqual(Region.tab_strip, next(closing, .search, .previous).?);
}

test "escape returns to the terminal only from chrome" {
    const all: Availability = .{
        .terminal = true,
        .tab_strip = true,
        .search = true,
        .banner = true,
    };
    try std.testing.expectEqual(Region.terminal, escapeTarget(all, .tab_strip).?);
    try std.testing.expectEqual(Region.terminal, escapeTarget(all, .banner).?);
    try std.testing.expectEqual(@as(?Region, null), escapeTarget(all, .terminal));
    try std.testing.expectEqual(@as(?Region, null), escapeTarget(all, null));

    const no_terminal: Availability = .{ .tab_strip = true };
    try std.testing.expectEqual(@as(?Region, null), escapeTarget(no_terminal, .tab_strip));
}
