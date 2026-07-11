//! Pure client-coordinate policy for tab move and drag-to-split targets.
//!
//! The caller supplies a content rect, pointer, DPI, and the previously active
//! operation. This module performs no HWND lookup, drawing, or drag/drop I/O.

const std = @import("std");
const geometry = @import("win32_geometry.zig");

pub const Rect = geometry.Rect;
pub const Point = geometry.Point;

pub const Operation = enum {
    none,
    new_tab,
    split_left,
    split_right,
    split_up,
    split_down,
};

pub const Target = struct {
    operation: Operation = .none,
    preview_rect: ?Rect = null,
};

pub const Config = struct {
    /// Pointer-sensitive edge target depth at 96 DPI.
    edge_depth_dip: u16 = 72,
    /// Distance beyond a boundary before changing an existing target.
    hysteresis_dip: u16 = 12,
    /// Minimum width or height of both panes produced by a split.
    minimum_pane_dip: u16 = 120,
};

const Availability = struct {
    horizontal: bool,
    vertical: bool,
};

/// Resolve a drop target. `previous` should be the last returned operation for
/// this drag; pass `.none` on drag enter. Points outside the client rect never
/// retain a target.
pub fn resolve(
    client: Rect,
    point: Point,
    dpi: u32,
    previous: Operation,
    config: Config,
) Target {
    const width = dimension(client.left, client.right) orelse return .{};
    const height = dimension(client.top, client.bottom) orelse return .{};
    if (dpi == 0 or !client.contains(point.x, point.y)) return .{};

    const minimum = @as(i64, scaleDip(config.minimum_pane_dip, dpi));
    const available: Availability = .{
        .horizontal = width >= minimum * 2,
        .vertical = height >= minimum * 2,
    };
    const edge = @as(i64, scaleDip(config.edge_depth_dip, dpi));
    const hysteresis = @as(i64, scaleDip(config.hysteresis_dip, dpi));
    const horizontal_depth = @max(@as(i64, 1), @min(edge, @divTrunc(width, 3)));
    const vertical_depth = @max(@as(i64, 1), @min(edge, @divTrunc(height, 3)));
    const x = @as(i64, point.x);
    const y = @as(i64, point.y);
    const distances = Distances{
        .left = x - client.left,
        .right = @as(i64, client.right) - 1 - x,
        .up = y - client.top,
        .down = @as(i64, client.bottom) - 1 - y,
    };

    if (retainedOperation(
        previous,
        distances,
        horizontal_depth,
        vertical_depth,
        hysteresis,
        available,
    )) |operation| {
        return targetFor(client, operation);
    }

    const operation = nearestEdge(
        distances,
        horizontal_depth,
        vertical_depth,
        available,
        if (previous == .new_tab) hysteresis else 0,
    ) orelse .new_tab;
    return targetFor(client, operation);
}

fn dimension(start: i32, end: i32) ?i64 {
    const result = @as(i64, end) - @as(i64, start);
    return if (result > 0) result else null;
}

pub fn scaleDip(dip: u16, dpi: u32) i32 {
    if (dpi == 0) return 0;
    const rounded = (@as(u64, dip) * dpi + 48) / 96;
    return @intCast(@min(rounded, std.math.maxInt(i32)));
}

const Distances = struct {
    left: i64,
    right: i64,
    up: i64,
    down: i64,
};

fn retainedOperation(
    previous: Operation,
    distances: Distances,
    horizontal_depth: i64,
    vertical_depth: i64,
    hysteresis: i64,
    available: Availability,
) ?Operation {
    return switch (previous) {
        .split_left => if (available.horizontal and distances.left < horizontal_depth + hysteresis)
            .split_left
        else
            null,
        .split_right => if (available.horizontal and distances.right < horizontal_depth + hysteresis)
            .split_right
        else
            null,
        .split_up => if (available.vertical and distances.up < vertical_depth + hysteresis)
            .split_up
        else
            null,
        .split_down => if (available.vertical and distances.down < vertical_depth + hysteresis)
            .split_down
        else
            null,
        .none, .new_tab => null,
    };
}

fn nearestEdge(
    distances: Distances,
    horizontal_depth: i64,
    vertical_depth: i64,
    available: Availability,
    center_hysteresis: i64,
) ?Operation {
    const horizontal_threshold = @max(@as(i64, 0), horizontal_depth - center_hysteresis);
    const vertical_threshold = @max(@as(i64, 0), vertical_depth - center_hysteresis);
    var operation: ?Operation = null;
    var best_distance: i64 = std.math.maxInt(i64);

    // Stable tie order favors horizontal splits, then the leading edge.
    if (available.horizontal and distances.left < horizontal_threshold) {
        operation = .split_left;
        best_distance = distances.left;
    }
    if (available.horizontal and distances.right < horizontal_threshold and distances.right < best_distance) {
        operation = .split_right;
        best_distance = distances.right;
    }
    if (available.vertical and distances.up < vertical_threshold and distances.up < best_distance) {
        operation = .split_up;
        best_distance = distances.up;
    }
    if (available.vertical and distances.down < vertical_threshold and distances.down < best_distance) {
        operation = .split_down;
    }
    return operation;
}

fn targetFor(client: Rect, operation: Operation) Target {
    return .{
        .operation = operation,
        .preview_rect = switch (operation) {
            .none => null,
            .new_tab => client,
            .split_left => splitPreview(client, .split_left),
            .split_right => splitPreview(client, .split_right),
            .split_up => splitPreview(client, .split_up),
            .split_down => splitPreview(client, .split_down),
        },
    };
}

pub fn splitPreview(client: Rect, operation: Operation) Rect {
    const middle_x: i32 = @intCast(@as(i64, client.left) + @divTrunc(@as(i64, client.right) - client.left, 2));
    const middle_y: i32 = @intCast(@as(i64, client.top) + @divTrunc(@as(i64, client.bottom) - client.top, 2));
    return switch (operation) {
        .split_left => .{ .left = client.left, .top = client.top, .right = middle_x, .bottom = client.bottom },
        .split_right => .{ .left = middle_x, .top = client.top, .right = client.right, .bottom = client.bottom },
        .split_up => .{ .left = client.left, .top = client.top, .right = client.right, .bottom = middle_y },
        .split_down => .{ .left = client.left, .top = middle_y, .right = client.right, .bottom = client.bottom },
        .none, .new_tab => client,
    };
}

pub const PayloadIdentity = extern struct {
    version: u32 = 1,
    process_id: u32,
    source_window_id: u64,
    source_tab_id: u64,
    drag_nonce: u64,
};

pub const TransferScope = enum { same_window, cross_window };

pub const IdentityError = error{
    BadVersion,
    WrongProcess,
    MissingIdentity,
    StaleIdentity,
};

pub const LiveDragIdentity = struct {
    source_window_id: u64,
    source_tab_id: u64,
    drag_nonce: u64,
};

/// Validate same-process opaque IDs before resolving a same- or cross-window
/// transfer. These sentinels prevent accidental/stale drops, not malicious
/// same-integrity payload forgery.
pub fn validatePayloadIdentity(
    identity: PayloadIdentity,
    current_process_id: u32,
    target_window_id: u64,
    live_drag: LiveDragIdentity,
) IdentityError!TransferScope {
    if (identity.version != 1) return error.BadVersion;
    if (identity.process_id != current_process_id) return error.WrongProcess;
    if (identity.source_window_id == 0 or identity.source_tab_id == 0 or
        identity.drag_nonce == 0 or target_window_id == 0)
    {
        return error.MissingIdentity;
    }
    if (identity.source_window_id != live_drag.source_window_id or
        identity.source_tab_id != live_drag.source_tab_id or
        identity.drag_nonce != live_drag.drag_nonce)
    {
        return error.StaleIdentity;
    }
    return if (identity.source_window_id == target_window_id)
        .same_window
    else
        .cross_window;
}

const test_client: Rect = .{ .left = 100, .top = 50, .right = 700, .bottom = 450 };

test "center resolves to new tab with full client preview" {
    const target = resolve(test_client, .{ .x = 400, .y = 250 }, 96, .none, .{});
    try std.testing.expectEqual(Operation.new_tab, target.operation);
    try std.testing.expectEqual(test_client, target.preview_rect.?);
}

test "all split edges produce contiguous half previews" {
    const cases = [_]struct { point: Point, operation: Operation, expected: Rect }{
        .{ .point = .{ .x = 100, .y = 250 }, .operation = .split_left, .expected = .{ .left = 100, .top = 50, .right = 400, .bottom = 450 } },
        .{ .point = .{ .x = 699, .y = 250 }, .operation = .split_right, .expected = .{ .left = 400, .top = 50, .right = 700, .bottom = 450 } },
        .{ .point = .{ .x = 400, .y = 50 }, .operation = .split_up, .expected = .{ .left = 100, .top = 50, .right = 700, .bottom = 250 } },
        .{ .point = .{ .x = 400, .y = 449 }, .operation = .split_down, .expected = .{ .left = 100, .top = 250, .right = 700, .bottom = 450 } },
    };
    for (cases) |case| {
        const target = resolve(test_client, case.point, 96, .none, .{});
        try std.testing.expectEqual(case.operation, target.operation);
        try std.testing.expectEqual(case.expected, target.preview_rect.?);
    }
}

test "DPI scaling expands physical target depth" {
    const client: Rect = .{ .left = 0, .top = 0, .right = 600, .bottom = 600 };
    try std.testing.expectEqual(
        Operation.new_tab,
        resolve(client, .{ .x = 100, .y = 300 }, 96, .none, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.split_left,
        resolve(client, .{ .x = 100, .y = 300 }, 192, .none, .{}).operation,
    );
}

test "minimum pane size disables only the constrained axis" {
    const narrow: Rect = .{ .left = 0, .top = 0, .right = 200, .bottom = 500 };
    try std.testing.expectEqual(
        Operation.new_tab,
        resolve(narrow, .{ .x = 0, .y = 250 }, 96, .none, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.split_up,
        resolve(narrow, .{ .x = 100, .y = 0 }, 96, .none, .{}).operation,
    );
}

test "edge and center hysteresis resist boundary flicker" {
    const client: Rect = .{ .left = 0, .top = 0, .right = 600, .bottom = 400 };
    try std.testing.expectEqual(
        Operation.split_left,
        resolve(client, .{ .x = 80, .y = 200 }, 96, .split_left, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.new_tab,
        resolve(client, .{ .x = 84, .y = 200 }, 96, .split_left, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.new_tab,
        resolve(client, .{ .x = 65, .y = 200 }, 96, .new_tab, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.split_left,
        resolve(client, .{ .x = 59, .y = 200 }, 96, .new_tab, .{}).operation,
    );
}

test "corner targeting selects nearest edge with stable ties" {
    try std.testing.expectEqual(
        Operation.split_left,
        resolve(test_client, .{ .x = 110, .y = 70 }, 96, .none, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.split_up,
        resolve(test_client, .{ .x = 120, .y = 60 }, 96, .none, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.split_left,
        resolve(test_client, .{ .x = 110, .y = 60 }, 96, .none, .{}).operation,
    );
}

test "outside and invalid clients resolve to no target" {
    try std.testing.expectEqual(
        Operation.none,
        resolve(test_client, .{ .x = 700, .y = 100 }, 96, .split_right, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.none,
        resolve(.{ .left = 5, .top = 5, .right = 5, .bottom = 10 }, .{ .x = 5, .y = 5 }, 96, .none, .{}).operation,
    );
    try std.testing.expectEqual(
        Operation.none,
        resolve(test_client, .{ .x = 400, .y = 250 }, 0, .none, .{}).operation,
    );
}

test "odd split previews cover the client without gaps" {
    const client: Rect = .{ .left = -10, .top = -5, .right = 591, .bottom = 396 };
    const left = splitPreview(client, .split_left);
    const right = splitPreview(client, .split_right);
    const up = splitPreview(client, .split_up);
    const down = splitPreview(client, .split_down);
    try std.testing.expectEqual(left.right, right.left);
    try std.testing.expectEqual(client.width(), left.width() + right.width());
    try std.testing.expectEqual(up.bottom, down.top);
    try std.testing.expectEqual(client.height(), up.height() + down.height());
}

test "payload identity validates same and cross window scope" {
    const identity: PayloadIdentity = .{
        .process_id = 42,
        .source_window_id = 10,
        .source_tab_id = 20,
        .drag_nonce = 30,
    };
    const live: LiveDragIdentity = .{
        .source_window_id = 10,
        .source_tab_id = 20,
        .drag_nonce = 30,
    };
    try std.testing.expectEqual(TransferScope.same_window, try validatePayloadIdentity(identity, 42, 10, live));
    try std.testing.expectEqual(TransferScope.cross_window, try validatePayloadIdentity(identity, 42, 11, live));
    try std.testing.expectError(error.WrongProcess, validatePayloadIdentity(identity, 43, 11, live));

    var malformed = identity;
    malformed.source_tab_id = 0;
    try std.testing.expectError(error.MissingIdentity, validatePayloadIdentity(malformed, 42, 11, live));
    malformed = identity;
    malformed.version = 2;
    try std.testing.expectError(error.BadVersion, validatePayloadIdentity(malformed, 42, 11, live));

    var stale_live = live;
    stale_live.drag_nonce += 1;
    try std.testing.expectError(error.StaleIdentity, validatePayloadIdentity(identity, 42, 11, stale_live));
}
