//! Pure Win32 shell domain. This module intentionally contains no HWND, COM,
//! WGL, thread, filesystem, or terminal `Surface` references. Platform code
//! consumes reducer effects and returns completions as intents.

const std = @import("std");

pub const ids = @import("win32_shell/ids.zig");
pub const model = @import("win32_shell/model.zig");
pub const intent = @import("win32_shell/intent.zig");
pub const effect = @import("win32_shell/effect.zig");
pub const reducer = @import("win32_shell/reducer.zig");
pub const selectors = @import("win32_shell/selectors.zig");
pub const runtime = @import("win32_shell/runtime.zig");

test "window tab split focus close lifecycle" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    defer result.deinit(allocator);
    try state.validate();
    try std.testing.expectEqual(@as(usize, 1), state.windows.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.panes.items.len);

    const window_id = state.windows.items[0].id;
    const tab_id = state.tabs.items[0].id;
    const first_pane = state.panes.items[0].id;
    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .split_pane = .{
        .pane = first_pane,
        .direction = .right,
    } });
    try state.validate();
    try std.testing.expectEqual(@as(usize, 2), selectors.paneCount(&state, tab_id));

    const second_pane = state.tab(tab_id).?.focused_pane;
    try std.testing.expect(!second_pane.eql(first_pane));
    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .focus_pane = first_pane });
    try std.testing.expect(state.tab(tab_id).?.focused_pane.eql(first_pane));

    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .close_pane = first_pane });
    try state.validate();
    try std.testing.expectEqual(@as(usize, 1), selectors.paneCount(&state, tab_id));
    try std.testing.expectError(error.StaleId, reducer.apply(&state, .{ .focus_pane = first_pane }));

    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .create_tab = window_id });
    try state.validate();
    try std.testing.expectEqual(@as(usize, 2), state.tabs.items.len);

    const active_tab = state.window(window_id).?.active_tab.?;
    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .close_tab = active_tab });
    try state.validate();
    try std.testing.expectEqual(@as(usize, 1), state.tabs.items.len);

    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .close_window = window_id });
    try state.validate();
    try std.testing.expectEqual(@as(usize, 0), state.windows.items.len);
}

test "direction controls split axis and leaf order" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    defer result.deinit(allocator);
    const tab_id = state.tabs.items[0].id;
    const old_pane = state.panes.items[0].id;
    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .split_pane = .{
        .pane = old_pane,
        .direction = .left,
        .ratio = 0.4,
    } });
    try state.validate();

    const ordered = try selectors.orderedPanesAlloc(allocator, &state, tab_id);
    defer allocator.free(ordered);
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expect(!ordered[0].eql(old_pane));
    try std.testing.expect(ordered[1].eql(old_pane));
    const root = state.nodeConst(state.tabConst(tab_id).?.root).?;
    try std.testing.expectEqual(model.Axis.horizontal, root.value.split.axis);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), root.value.split.ratio, 0.001);
}

test "deterministic operation sequence preserves invariants" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    var iteration: usize = 0;
    while (iteration < 32) : (iteration += 1) {
        const tab_id = state.tabs.items[0].id;
        const focused = state.tab(tab_id).?.focused_pane;
        result = try reducer.apply(&state, .{ .split_pane = .{
            .pane = focused,
            .direction = if (iteration % 2 == 0) .down else .right,
            .ratio = 0.25 + @as(f32, @floatFromInt(iteration % 3)) * 0.2,
        } });
        result.deinit(allocator);
        try state.validate();

        if (iteration % 3 == 2) {
            result = try reducer.apply(&state, .{ .close_pane = focused });
            result.deinit(allocator);
            try state.validate();
        }
    }
}

test "invalid operations do not mutate state" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    defer result.deinit(allocator);
    const pane = state.panes.items[0].id;
    const before_nodes = state.nodes.items.len;
    try std.testing.expectError(error.InvalidRatio, reducer.apply(&state, .{ .split_pane = .{
        .pane = pane,
        .direction = .right,
        .ratio = 1.0,
    } }));
    try std.testing.expectEqual(before_nodes, state.nodes.items.len);
    try state.validate();
}

test "win32 shell retained multi-pane tab restores exact identity and topology" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const retained_tab = state.tabs.items[0].id;
    const first_pane = state.tabs.items[0].focused_pane;

    result = try reducer.apply(&state, .{ .split_pane = .{
        .pane = first_pane,
        .direction = .right,
        .ratio = 0.37,
    } });
    result.deinit(allocator);
    const second_pane = state.tab(retained_tab).?.focused_pane;
    result = try reducer.apply(&state, .{ .split_pane = .{
        .pane = second_pane,
        .direction = .down,
        .ratio = 0.63,
    } });
    result.deinit(allocator);
    const focused_before = state.tab(retained_tab).?.focused_pane;
    const root_before = state.tab(retained_tab).?.root;
    const panes_before = try allocator.dupe(model.Pane, state.panes.items);
    defer allocator.free(panes_before);
    const nodes_before = try allocator.dupe(model.Node, state.nodes.items);
    defer allocator.free(nodes_before);

    result = try reducer.apply(&state, .{ .create_tab = window_id });
    result.deinit(allocator);
    const second_tab = state.window(window_id).?.active_tab.?;

    result = try reducer.apply(&state, .{ .detach_tab = retained_tab });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.effects.items.len);
    try std.testing.expectEqual(.relayout_window, std.meta.activeTag(result.effects.items[0]));
    try std.testing.expectEqual(.persist_session, std.meta.activeTag(result.effects.items[1]));
    try state.validate();
    try std.testing.expectEqual(@as(usize, 1), state.window(window_id).?.tabs.items.len);
    try std.testing.expect(state.window(window_id).?.tabs.items[0].eql(second_tab));
    try std.testing.expectEqual(@as(usize, 1), state.window(window_id).?.retained_tabs.items.len);
    try std.testing.expect(state.window(window_id).?.retained_tabs.items[0].eql(retained_tab));
    try std.testing.expect(state.tab_ids.isCurrent(retained_tab));
    for (panes_before) |pane| try std.testing.expect(state.pane_ids.isCurrent(pane.id));
    for (nodes_before) |node| try std.testing.expect(state.node_ids.isCurrent(node.id));

    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .restore_tab = .{ .tab = retained_tab, .index = 0 } });
    try std.testing.expectEqual(@as(usize, 3), result.effects.items.len);
    try std.testing.expectEqual(.focus_surface, std.meta.activeTag(result.effects.items[0]));
    try std.testing.expectEqual(.relayout_window, std.meta.activeTag(result.effects.items[1]));
    try std.testing.expectEqual(.persist_session, std.meta.activeTag(result.effects.items[2]));
    try state.validate();
    const window = state.window(window_id).?;
    try std.testing.expectEqual(@as(usize, 2), window.tabs.items.len);
    try std.testing.expect(window.tabs.items[0].eql(retained_tab));
    try std.testing.expect(window.tabs.items[1].eql(second_tab));
    try std.testing.expect(window.active_tab.?.eql(retained_tab));
    try std.testing.expectEqual(@as(usize, 0), window.retained_tabs.items.len);
    try std.testing.expect(state.tab(retained_tab).?.root.eql(root_before));
    try std.testing.expect(state.tab(retained_tab).?.focused_pane.eql(focused_before));
    try std.testing.expectEqualSlices(model.Pane, panes_before, state.panes.items[0..panes_before.len]);
    try std.testing.expectEqualSlices(model.Node, nodes_before, state.nodes.items[0..nodes_before.len]);
}

test "win32 shell last active tab becomes retained inactive window and restores" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const tab_id = state.tabs.items[0].id;
    const pane_id = state.panes.items[0].id;

    result = try reducer.apply(&state, .{ .detach_tab = tab_id });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.effects.items.len);
    try std.testing.expectEqual(.relayout_window, std.meta.activeTag(result.effects.items[0]));
    try std.testing.expectEqual(.persist_session, std.meta.activeTag(result.effects.items[1]));
    try state.validate();
    const inactive = state.window(window_id).?;
    try std.testing.expectEqual(@as(usize, 0), inactive.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), inactive.retained_tabs.items.len);
    try std.testing.expectEqual(@as(?model.TabId, null), inactive.active_tab);
    try std.testing.expectEqual(@as(?model.WindowId, null), state.focused_window);
    try std.testing.expect(state.window_ids.isCurrent(window_id));
    try std.testing.expect(state.tab_ids.isCurrent(tab_id));
    try std.testing.expect(state.pane_ids.isCurrent(pane_id));

    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .restore_tab = .{ .tab = tab_id, .index = 0 } });
    try std.testing.expectEqual(@as(usize, 3), result.effects.items.len);
    try std.testing.expectEqual(.focus_surface, std.meta.activeTag(result.effects.items[0]));
    try std.testing.expectEqual(.relayout_window, std.meta.activeTag(result.effects.items[1]));
    try std.testing.expectEqual(.persist_session, std.meta.activeTag(result.effects.items[2]));
    try state.validate();
    try std.testing.expect(state.focused_window.?.eql(window_id));
    try std.testing.expect(state.window(window_id).?.active_tab.?.eql(tab_id));
    try std.testing.expect(state.tab(tab_id).?.focused_pane.eql(pane_id));
}

test "win32 shell discarding detached tab releases complete subtree and retained window" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const tab_id = state.tabs.items[0].id;
    const first_pane = state.panes.items[0].id;
    result = try reducer.apply(&state, .{ .split_pane = .{
        .pane = first_pane,
        .direction = .left,
        .ratio = 0.41,
    } });
    result.deinit(allocator);
    const pane_ids = try allocator.alloc(model.PaneId, state.panes.items.len);
    defer allocator.free(pane_ids);
    for (state.panes.items, pane_ids) |pane, *id| id.* = pane.id;
    const node_ids = try allocator.alloc(model.NodeId, state.nodes.items.len);
    defer allocator.free(node_ids);
    for (state.nodes.items, node_ids) |node, *id| id.* = node.id;

    result = try reducer.apply(&state, .{ .detach_tab = tab_id });
    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .discard_detached_tab = tab_id });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), result.effects.items.len);
    try std.testing.expectEqual(.destroy_surface, std.meta.activeTag(result.effects.items[0]));
    try std.testing.expectEqual(.destroy_surface, std.meta.activeTag(result.effects.items[1]));
    try std.testing.expectEqual(.destroy_window, std.meta.activeTag(result.effects.items[2]));
    try std.testing.expectEqual(.persist_session, std.meta.activeTag(result.effects.items[3]));
    try state.validate();
    try std.testing.expectEqual(@as(usize, 0), state.windows.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.panes.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.nodes.items.len);
    try std.testing.expect(!state.window_ids.isCurrent(window_id));
    try std.testing.expect(!state.tab_ids.isCurrent(tab_id));
    for (pane_ids) |id| try std.testing.expect(!state.pane_ids.isCurrent(id));
    for (node_ids) |id| try std.testing.expect(!state.node_ids.isCurrent(id));
}

test "win32 shell retained operations reject stale ids and invalid restore index without mutation" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const tab_id = state.tabs.items[0].id;
    result = try reducer.apply(&state, .{ .detach_tab = tab_id });
    result.deinit(allocator);

    const stale: model.TabId = .{ .index = tab_id.index, .generation = tab_id.generation +% 1 };
    try std.testing.expectError(error.StaleId, reducer.apply(&state, .{ .restore_tab = .{ .tab = stale, .index = 0 } }));
    try std.testing.expectError(error.InvalidIndex, reducer.apply(&state, .{ .restore_tab = .{ .tab = tab_id, .index = 1 } }));
    try std.testing.expectError(error.StaleId, reducer.apply(&state, .{ .detach_tab = tab_id }));
    try std.testing.expectError(error.StaleId, reducer.apply(&state, .{ .reorder_tab = .{ .tab = tab_id, .index = 0 } }));
    try state.validate();
    try std.testing.expectEqual(@as(usize, 0), state.window(window_id).?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.window(window_id).?.retained_tabs.items.len);
    try std.testing.expect(state.window(window_id).?.retained_tabs.items[0].eql(tab_id));
}

test "win32 shell detach allocation failure leaves active graph unchanged" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const tab_id = state.tabs.items[0].id;
    const pane_id = state.panes.items[0].id;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const original_allocator = state.allocator;
    state.allocator = failing.allocator();
    const attempted = reducer.apply(&state, .{ .detach_tab = tab_id });
    state.allocator = original_allocator;
    try std.testing.expectError(error.OutOfMemory, attempted);

    try state.validate();
    const window = state.window(window_id).?;
    try std.testing.expectEqual(@as(usize, 1), window.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), window.retained_tabs.items.len);
    try std.testing.expect(window.active_tab.?.eql(tab_id));
    try std.testing.expect(state.focused_window.?.eql(window_id));
    try std.testing.expect(state.pane_ids.isCurrent(pane_id));
}

test "win32 shell restore and discard allocation failures preserve retained graph" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const tab_id = state.tabs.items[0].id;
    const pane_id = state.panes.items[0].id;
    result = try reducer.apply(&state, .{ .detach_tab = tab_id });
    result.deinit(allocator);

    // Force restore to require capacity instead of reusing the active list's
    // allocation left behind by detach.
    state.windows.items[0].tabs.deinit(allocator);
    state.windows.items[0].tabs = .empty;
    var failing_restore = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const original_allocator = state.allocator;
    state.allocator = failing_restore.allocator();
    const restore_attempt = reducer.apply(&state, .{ .restore_tab = .{ .tab = tab_id, .index = 0 } });
    state.allocator = original_allocator;
    try std.testing.expectError(error.OutOfMemory, restore_attempt);
    try state.validate();
    try std.testing.expectEqual(@as(usize, 0), state.window(window_id).?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.window(window_id).?.retained_tabs.items.len);
    try std.testing.expect(state.tab_ids.isCurrent(tab_id));
    try std.testing.expect(state.pane_ids.isCurrent(pane_id));

    var failing_discard = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    state.allocator = failing_discard.allocator();
    const discard_attempt = reducer.apply(&state, .{ .discard_detached_tab = tab_id });
    state.allocator = original_allocator;
    try std.testing.expectError(error.OutOfMemory, discard_attempt);
    try state.validate();
    try std.testing.expect(state.window_ids.isCurrent(window_id));
    try std.testing.expect(state.tab_ids.isCurrent(tab_id));
    try std.testing.expect(state.pane_ids.isCurrent(pane_id));
    try std.testing.expectEqual(@as(usize, 1), state.window(window_id).?.retained_tabs.items.len);
}

test "win32 shell ordered tab reorder preserves active identity" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const first = state.tabs.items[0].id;
    result = try reducer.apply(&state, .{ .create_tab = window_id });
    result.deinit(allocator);
    const second = state.window(window_id).?.active_tab.?;
    result = try reducer.apply(&state, .{ .create_tab = window_id });
    result.deinit(allocator);
    const third = state.window(window_id).?.active_tab.?;

    result = try reducer.apply(&state, .{ .reorder_tab = .{ .tab = first, .index = 2 } });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.effects.items.len);
    try std.testing.expectEqual(.relayout_window, std.meta.activeTag(result.effects.items[0]));
    try std.testing.expectEqual(.persist_session, std.meta.activeTag(result.effects.items[1]));
    try state.validate();
    const window = state.window(window_id).?;
    try std.testing.expect(window.tabs.items[0].eql(second));
    try std.testing.expect(window.tabs.items[1].eql(third));
    try std.testing.expect(window.tabs.items[2].eql(first));
    try std.testing.expect(window.active_tab.?.eql(third));
    try std.testing.expectError(error.InvalidIndex, reducer.apply(&state, .{ .reorder_tab = .{ .tab = first, .index = 3 } }));
}

test "win32 shell closing last active window does not focus retained-only window" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const retained_window = state.windows.items[0].id;
    const retained_tab = state.tabs.items[0].id;
    result = try reducer.apply(&state, .{ .detach_tab = retained_tab });
    result.deinit(allocator);

    result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const active_window = state.focused_window.?;
    result = try reducer.apply(&state, .{ .close_window = active_window });
    defer result.deinit(allocator);

    try state.validate();
    try std.testing.expectEqual(@as(?model.WindowId, null), state.focused_window);
    try std.testing.expectEqual(@as(usize, 1), state.windows.items.len);
    try std.testing.expect(state.windows.items[0].id.eql(retained_window));
    try std.testing.expectEqual(@as(usize, 0), state.windows.items[0].tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.windows.items[0].retained_tabs.items.len);
}

test "win32 shell whole tab transfer preserves subtree identities and exact undo redo" {
    const allocator = std.testing.allocator;
    var shell_runtime = runtime.Runtime.init(allocator);
    defer shell_runtime.deinit();

    var prepared = try shell_runtime.prepare(.create_window);
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    const window_id = shell_runtime.state.windows.items[0].id;
    const source_tab = shell_runtime.state.tabs.items[0].id;
    const original_pane = shell_runtime.state.tabs.items[0].focused_pane;
    prepared = try shell_runtime.prepare(.{ .split_pane = .{ .pane = original_pane, .direction = .down, .ratio = 0.3 } });
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    const source_root = shell_runtime.state.tab(source_tab).?.root;
    const source_focus = shell_runtime.state.tab(source_tab).?.focused_pane;
    const source_node_count = shell_runtime.state.nodes.items.len;
    const source_pane_count = shell_runtime.state.panes.items.len;

    prepared = try shell_runtime.prepare(.{ .create_tab = window_id });
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    const target_tab = shell_runtime.state.window(window_id).?.active_tab.?;
    const target_pane = shell_runtime.state.tab(target_tab).?.focused_pane;

    prepared = try shell_runtime.prepare(.{ .transfer_subtree = .{
        .source_root = source_root,
        .target_pane = target_pane,
        .direction = .left,
        .ratio = 0.4,
    } });
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    try shell_runtime.state.validate();
    try std.testing.expectEqual(@as(usize, 1), shell_runtime.state.window(window_id).?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), shell_runtime.state.window(window_id).?.retained_tabs.items.len);
    try std.testing.expectEqual(source_node_count + 2, shell_runtime.state.nodes.items.len);
    try std.testing.expectEqual(source_pane_count + 1, shell_runtime.state.panes.items.len);
    try std.testing.expect(shell_runtime.state.node_ids.isCurrent(source_root));
    try std.testing.expect(shell_runtime.state.pane_ids.isCurrent(source_focus));
    try std.testing.expect(shell_runtime.state.pane(source_focus).?.tab.eql(target_tab));

    prepared = try shell_runtime.prepare(.{ .set_transfer_applied = .{ .source_root = source_root, .applied = false } });
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    try shell_runtime.state.validate();
    try std.testing.expectEqual(@as(usize, 2), shell_runtime.state.window(window_id).?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), shell_runtime.state.window(window_id).?.retained_tabs.items.len);
    try std.testing.expect(shell_runtime.state.window(window_id).?.tabs.items[0].eql(source_tab));
    try std.testing.expect(shell_runtime.state.tab(source_tab).?.root.eql(source_root));
    try std.testing.expect(shell_runtime.state.tab(source_tab).?.focused_pane.eql(source_focus));
    try std.testing.expect(shell_runtime.state.pane(source_focus).?.tab.eql(source_tab));

    prepared = try shell_runtime.prepare(.{ .set_transfer_applied = .{ .source_root = source_root, .applied = true } });
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    try shell_runtime.state.validate();
    try std.testing.expect(shell_runtime.state.node_ids.isCurrent(source_root));
    try std.testing.expect(shell_runtime.state.pane_ids.isCurrent(source_focus));
    try std.testing.expect(shell_runtime.state.pane(source_focus).?.tab.eql(target_tab));

    prepared = try shell_runtime.prepare(.{ .discard_transfer = source_root });
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    try shell_runtime.state.validate();
    try std.testing.expectEqual(@as(usize, 0), shell_runtime.state.transfers.items.len);
    try std.testing.expect(!shell_runtime.state.tab_ids.isCurrent(source_tab));
    try std.testing.expect(shell_runtime.state.node_ids.isCurrent(source_root));
    try std.testing.expect(shell_runtime.state.pane_ids.isCurrent(source_focus));
}

test "win32 shell pane rooted subtree transfer restores source and target focus topology" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    result.deinit(allocator);
    const window_id = state.windows.items[0].id;
    const source_tab = state.tabs.items[0].id;
    const original_pane = state.tabs.items[0].focused_pane;
    result = try reducer.apply(&state, .{ .split_pane = .{ .pane = original_pane, .direction = .right, .ratio = 0.35 } });
    result.deinit(allocator);
    const source_root_before = state.tab(source_tab).?.root;
    const source_split_before = state.node(source_root_before).?.value.split;
    const moved_pane = state.tab(source_tab).?.focused_pane;
    const moved_root = (findTestPaneNode(&state, source_tab, moved_pane) orelse unreachable).id;

    result = try reducer.apply(&state, .{ .create_tab = window_id });
    result.deinit(allocator);
    const target_tab = state.window(window_id).?.active_tab.?;
    const target_pane = state.tab(target_tab).?.focused_pane;
    const target_root_before = state.tab(target_tab).?.root;
    const target_focus_before = state.tab(target_tab).?.focused_pane;

    result = try reducer.apply(&state, .{ .transfer_subtree = .{
        .source_root = moved_root,
        .target_pane = target_pane,
        .direction = .up,
        .ratio = 0.6,
    } });
    result.deinit(allocator);
    try state.validate();
    try std.testing.expect(state.pane(moved_pane).?.tab.eql(target_tab));
    try std.testing.expect(state.tab(target_tab).?.focused_pane.eql(moved_pane));
    try std.testing.expect(state.tab(source_tab).?.root.eql(source_split_before.first));

    result = try reducer.apply(&state, .{ .set_transfer_applied = .{ .source_root = moved_root, .applied = false } });
    result.deinit(allocator);
    try state.validate();
    try std.testing.expect(state.tab(source_tab).?.root.eql(source_root_before));
    try std.testing.expect(std.meta.eql(source_split_before, state.node(source_root_before).?.value.split));
    try std.testing.expect(state.tab(source_tab).?.focused_pane.eql(moved_pane));
    try std.testing.expect(state.tab(target_tab).?.root.eql(target_root_before));
    try std.testing.expect(state.tab(target_tab).?.focused_pane.eql(target_focus_before));
    try std.testing.expect(state.pane(moved_pane).?.tab.eql(source_tab));

    result = try reducer.apply(&state, .{ .set_transfer_applied = .{ .source_root = moved_root, .applied = true } });
    result.deinit(allocator);
    try state.validate();
    try std.testing.expect(state.pane(moved_pane).?.tab.eql(target_tab));

    result = try reducer.apply(&state, .{ .set_transfer_applied = .{ .source_root = moved_root, .applied = false } });
    result.deinit(allocator);
    result = try reducer.apply(&state, .{ .discard_transfer = moved_root });
    result.deinit(allocator);
    try state.validate();
    try std.testing.expectEqual(@as(usize, 0), state.transfers.items.len);
    try std.testing.expect(state.tab_ids.isCurrent(source_tab));
    try std.testing.expect(state.pane(moved_pane).?.tab.eql(source_tab));
}

test "win32 shell transfer allocation failure and stale commit do not mutate authority" {
    const allocator = std.testing.allocator;
    var shell_runtime = runtime.Runtime.init(allocator);
    defer shell_runtime.deinit();
    var prepared = try shell_runtime.prepare(.create_window);
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    const window_id = shell_runtime.state.windows.items[0].id;
    const source_root = shell_runtime.state.tabs.items[0].root;
    const source_pane = shell_runtime.state.tabs.items[0].focused_pane;
    prepared = try shell_runtime.prepare(.{ .create_tab = window_id });
    try prepared.commit(&shell_runtime);
    prepared.deinit();
    const target_pane = shell_runtime.state.tab(shell_runtime.state.window(window_id).?.active_tab.?).?.focused_pane;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    const original_allocator = shell_runtime.state.allocator;
    shell_runtime.state.allocator = failing.allocator();
    const attempted = reducer.apply(&shell_runtime.state, .{ .transfer_subtree = .{
        .source_root = source_root,
        .target_pane = target_pane,
        .direction = .right,
    } });
    shell_runtime.state.allocator = original_allocator;
    try std.testing.expectError(error.OutOfMemory, attempted);
    try shell_runtime.state.validate();
    try std.testing.expectEqual(@as(usize, 2), shell_runtime.state.window(window_id).?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), shell_runtime.state.transfers.items.len);

    var stale = try shell_runtime.prepare(.{ .transfer_subtree = .{
        .source_root = source_root,
        .target_pane = target_pane,
        .direction = .right,
    } });
    defer stale.deinit();
    try std.testing.expect(try shell_runtime.focusPane(source_pane));
    try std.testing.expectError(error.StaleRevision, stale.commit(&shell_runtime));
    try shell_runtime.state.validate();
    try std.testing.expectEqual(@as(usize, 2), shell_runtime.state.window(window_id).?.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), shell_runtime.state.transfers.items.len);
}

fn findTestPaneNode(state: *model.ShellState, tab: model.TabId, pane: model.PaneId) ?*model.Node {
    for (state.nodes.items) |*node| if (node.tab.eql(tab)) switch (node.value) {
        .pane => |id| if (id.eql(pane)) return node,
        .split => {},
    };
    return null;
}

test "validation rejects orphan and duplicate panes" {
    const allocator = std.testing.allocator;
    var state = model.ShellState.init(allocator);
    defer state.deinit();

    var result = try reducer.apply(&state, .create_window);
    defer result.deinit(allocator);
    const tab_id = state.tabs.items[0].id;
    const root = state.tabs.items[0].root;
    const original_pane = state.panes.items[0].id;

    try state.panes.ensureUnusedCapacity(allocator, 1);
    const orphan = try state.pane_ids.acquire(allocator);
    state.panes.appendAssumeCapacity(.{ .id = orphan, .tab = tab_id });
    try std.testing.expectError(error.OrphanedPane, state.validate());

    _ = state.panes.pop();
    try state.pane_ids.release(allocator, orphan);
    try state.nodes.ensureUnusedCapacity(allocator, 2);
    try state.node_ids.reserveMany(allocator, 2);
    const first = state.node_ids.acquireAssumeCapacity();
    const second = state.node_ids.acquireAssumeCapacity();
    state.nodes.appendAssumeCapacity(.{ .id = first, .tab = tab_id, .value = .{ .pane = original_pane } });
    state.nodes.appendAssumeCapacity(.{ .id = second, .tab = tab_id, .value = .{ .pane = original_pane } });
    state.node(root).?.value = .{ .split = .{
        .axis = .horizontal,
        .ratio = 0.5,
        .first = first,
        .second = second,
    } };
    try std.testing.expectError(error.DuplicatePane, state.validate());
}
