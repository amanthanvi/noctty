const std = @import("std");
const model = @import("model.zig");
const intent_mod = @import("intent.zig");
const effect_mod = @import("effect.zig");
const selectors = @import("selectors.zig");

pub const Intent = intent_mod.Intent;
pub const Effect = effect_mod.Effect;

pub const Reduction = struct {
    effects: std.ArrayList(Effect) = .empty,

    pub fn deinit(self: *Reduction, allocator: std.mem.Allocator) void {
        self.effects.deinit(allocator);
    }
};

pub const ReduceError = error{
    StaleId,
    InvalidIndex,
    InvalidRatio,
    LastPane,
    SameTab,
    InvalidTransfer,
} || std.mem.Allocator.Error;

pub fn apply(state: *model.ShellState, intent: Intent) ReduceError!Reduction {
    var reduction: Reduction = .{};
    errdefer reduction.deinit(state.allocator);

    switch (intent) {
        .create_window => try createWindow(state, &reduction),
        .close_window => |id| try closeWindow(state, &reduction, id),
        .create_tab => |id| try createTab(state, &reduction, id),
        .close_tab => |id| try closeTab(state, &reduction, id),
        .detach_tab => |id| try detachTab(state, &reduction, id),
        .restore_tab => |restore| try restoreTab(state, &reduction, restore.tab, restore.index),
        .discard_detached_tab => |id| try discardDetachedTab(state, &reduction, id),
        .reorder_tab => |reorder| try reorderTab(state, &reduction, reorder.tab, reorder.index),
        .split_pane => |split| try splitPane(state, &reduction, split.pane, split.direction, split.ratio),
        .transfer_subtree => |transfer| try transferSubtree(state, &reduction, transfer.source_root, transfer.target_pane, transfer.direction, transfer.ratio),
        .set_transfer_applied => |transfer| try setTransferApplied(state, &reduction, transfer.source_root, transfer.applied),
        .discard_transfer => |source_root| try discardTransfer(state, &reduction, source_root),
        .close_pane => |id| try closePane(state, &reduction, id),
        .focus_window => |id| try focusWindow(state, &reduction, id),
        .focus_tab => |id| try focusTab(state, &reduction, id),
        .focus_pane => |id| try focusPane(state, &reduction, id),
    }
    return reduction;
}

fn createWindow(state: *model.ShellState, out: *Reduction) !void {
    var window: model.Window = undefined;
    window = .{ .id = undefined };
    errdefer window.deinit(state.allocator);
    try window.tabs.ensureUnusedCapacity(state.allocator, 1);
    try state.windows.ensureUnusedCapacity(state.allocator, 1);
    try state.tabs.ensureUnusedCapacity(state.allocator, 1);
    try state.panes.ensureUnusedCapacity(state.allocator, 1);
    try state.nodes.ensureUnusedCapacity(state.allocator, 1);
    try state.window_ids.reserve(state.allocator);
    try state.tab_ids.reserve(state.allocator);
    try state.pane_ids.reserve(state.allocator);
    try state.node_ids.reserve(state.allocator);
    try out.effects.ensureUnusedCapacity(state.allocator, 4);

    const window_id = state.window_ids.acquireAssumeCapacity();
    const tab_id = state.tab_ids.acquireAssumeCapacity();
    const pane_id = state.pane_ids.acquireAssumeCapacity();
    const node_id = state.node_ids.acquireAssumeCapacity();

    window.id = window_id;
    window.active_tab = tab_id;
    window.tabs.appendAssumeCapacity(tab_id);

    state.windows.appendAssumeCapacity(window);
    window.tabs = .empty;
    state.tabs.appendAssumeCapacity(.{ .id = tab_id, .window = window_id, .root = node_id, .focused_pane = pane_id });
    state.panes.appendAssumeCapacity(.{ .id = pane_id, .tab = tab_id });
    state.nodes.appendAssumeCapacity(.{ .id = node_id, .tab = tab_id, .value = .{ .pane = pane_id } });
    state.focused_window = window_id;

    out.effects.appendAssumeCapacity(.{ .create_window = window_id });
    out.effects.appendAssumeCapacity(.{ .create_surface = pane_id });
    out.effects.appendAssumeCapacity(.{ .focus_surface = pane_id });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn createTab(state: *model.ShellState, out: *Reduction, window_id: model.WindowId) !void {
    const window = state.window(window_id) orelse return error.StaleId;
    try window.tabs.ensureUnusedCapacity(state.allocator, 1);
    try state.tabs.ensureUnusedCapacity(state.allocator, 1);
    try state.panes.ensureUnusedCapacity(state.allocator, 1);
    try state.nodes.ensureUnusedCapacity(state.allocator, 1);
    try state.tab_ids.reserve(state.allocator);
    try state.pane_ids.reserve(state.allocator);
    try state.node_ids.reserve(state.allocator);
    try out.effects.ensureUnusedCapacity(state.allocator, 4);

    const tab_id = state.tab_ids.acquireAssumeCapacity();
    const pane_id = state.pane_ids.acquireAssumeCapacity();
    const node_id = state.node_ids.acquireAssumeCapacity();
    window.tabs.appendAssumeCapacity(tab_id);
    window.active_tab = tab_id;
    state.tabs.appendAssumeCapacity(.{ .id = tab_id, .window = window_id, .root = node_id, .focused_pane = pane_id });
    state.panes.appendAssumeCapacity(.{ .id = pane_id, .tab = tab_id });
    state.nodes.appendAssumeCapacity(.{ .id = node_id, .tab = tab_id, .value = .{ .pane = pane_id } });
    state.focused_window = window_id;

    out.effects.appendAssumeCapacity(.{ .create_surface = pane_id });
    out.effects.appendAssumeCapacity(.{ .focus_surface = pane_id });
    out.effects.appendAssumeCapacity(.{ .relayout_window = window_id });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn splitPane(state: *model.ShellState, out: *Reduction, pane_id: model.PaneId, direction: model.Direction, ratio: f32) !void {
    if (!(ratio > 0 and ratio < 1)) return error.InvalidRatio;
    const pane = state.pane(pane_id) orelse return error.StaleId;
    const tab = state.tab(pane.tab) orelse return error.StaleId;
    if (activeWindowForTab(state, tab.id) == null) return error.StaleId;
    const window_id = tab.window;
    const leaf_id = (findPaneNode(state, tab.id, pane_id) orelse return error.StaleId).id;

    try state.panes.ensureUnusedCapacity(state.allocator, 1);
    try state.nodes.ensureUnusedCapacity(state.allocator, 2);
    try state.pane_ids.reserve(state.allocator);
    try state.node_ids.reserveMany(state.allocator, 2);
    try out.effects.ensureUnusedCapacity(state.allocator, 4);

    const new_pane = state.pane_ids.acquireAssumeCapacity();
    const old_leaf = state.node_ids.acquireAssumeCapacity();
    const new_leaf = state.node_ids.acquireAssumeCapacity();
    const axis: model.Axis = switch (direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    const new_first = direction == .left or direction == .up;

    state.panes.appendAssumeCapacity(.{ .id = new_pane, .tab = tab.id });
    state.nodes.appendAssumeCapacity(.{ .id = old_leaf, .tab = tab.id, .value = .{ .pane = pane_id } });
    state.nodes.appendAssumeCapacity(.{ .id = new_leaf, .tab = tab.id, .value = .{ .pane = new_pane } });
    state.node(leaf_id).?.value = .{ .split = .{
        .axis = axis,
        .ratio = ratio,
        .first = if (new_first) new_leaf else old_leaf,
        .second = if (new_first) old_leaf else new_leaf,
    } };
    tab.focused_pane = new_pane;

    out.effects.appendAssumeCapacity(.{ .create_surface = new_pane });
    out.effects.appendAssumeCapacity(.{ .focus_surface = new_pane });
    out.effects.appendAssumeCapacity(.{ .relayout_window = window_id });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn transferSubtree(
    state: *model.ShellState,
    out: *Reduction,
    source_root: model.NodeId,
    target_pane_id: model.PaneId,
    direction: model.Direction,
    ratio: f32,
) !void {
    if (!(ratio > 0 and ratio < 1)) return error.InvalidRatio;
    for (state.transfers.items) |transfer| if (transfer.source_root.eql(source_root)) return error.InvalidTransfer;

    const source_node = state.node(source_root) orelse return error.StaleId;
    const source_tab_id = source_node.tab;
    const source_tab = state.tab(source_tab_id) orelse return error.StaleId;
    const source_window = activeWindowForTab(state, source_tab_id) orelse return error.StaleId;
    const source_tab_index = indexOfId(source_window.tabs.items, source_tab_id) orelse return error.StaleId;
    const source_relation = findNodeRelation(state, source_tab.root, source_root, null) orelse return error.StaleId;

    const target_pane = state.pane(target_pane_id) orelse return error.StaleId;
    const target_tab_id = target_pane.tab;
    if (target_tab_id.eql(source_tab_id)) return error.SameTab;
    const target_tab = state.tab(target_tab_id) orelse return error.StaleId;
    _ = activeWindowForTab(state, target_tab_id) orelse return error.StaleId;
    const target_leaf = (findPaneNode(state, target_tab_id, target_pane_id) orelse return error.StaleId).id;
    const target_relation = findNodeRelation(state, target_tab.root, target_leaf, null) orelse return error.StaleId;
    const moved_focus = if (treeContainsPane(state, source_root, source_tab.focused_pane))
        source_tab.focused_pane
    else
        (firstPane(state, source_root) orelse return error.StaleId);

    try state.transfers.ensureUnusedCapacity(state.allocator, 1);
    try out.effects.ensureUnusedCapacity(state.allocator, 4);
    if (source_relation.parent == null) {
        try source_window.retained_tabs.ensureUnusedCapacity(state.allocator, 1);
        try state.nodes.ensureUnusedCapacity(state.allocator, 1);
        try state.node_ids.reserve(state.allocator);
    }

    const source_parent_parent = if (source_relation.parent) |parent|
        (findNodeRelation(state, source_tab.root, parent, null) orelse return error.StaleId).parent
    else
        null;
    const source_split: ?model.Split = if (source_relation.parent) |parent| switch (state.node(parent).?.value) {
        .split => |split| split,
        else => return error.InvalidTransfer,
    } else null;

    var record: model.Transfer = .{
        .source_tab = source_tab_id,
        .source_root = source_root,
        .source_parent = source_relation.parent,
        .source_parent_parent = source_parent_parent,
        .source_split = source_split,
        .source_tab_index = source_tab_index,
        .source_focus = source_tab.focused_pane,
        .moved_focus = moved_focus,
        .target_tab = target_tab_id,
        .target_leaf = target_leaf,
        .target_parent = target_relation.parent,
        .target_focus = target_tab.focused_pane,
        .direction = direction,
        .ratio = ratio,
        .displaced_target = null,
        .applied = true,
    };
    try applyTransferTopology(state, &record);
    state.transfers.appendAssumeCapacity(record);
    appendTransferEffects(state, out, source_tab.window, target_tab.window, moved_focus);
}

fn setTransferApplied(state: *model.ShellState, out: *Reduction, source_root: model.NodeId, applied: bool) !void {
    const index = transferIndex(state, source_root) orelse return error.StaleId;
    if (state.transfers.items[index].applied == applied) return;
    try out.effects.ensureUnusedCapacity(state.allocator, 4);
    if (applied) {
        if (state.transfers.items[index].source_parent == null) {
            const source_window = activeWindowForTab(state, state.transfers.items[index].source_tab) orelse return error.InvalidTransfer;
            try source_window.retained_tabs.ensureUnusedCapacity(state.allocator, 1);
            try state.nodes.ensureUnusedCapacity(state.allocator, 1);
            try state.node_ids.reserve(state.allocator);
        }
        try applyTransferTopology(state, &state.transfers.items[index]);
    } else {
        const record = &state.transfers.items[index];
        if (record.source_parent == null) {
            const source_tab = state.tab(record.source_tab) orelse return error.StaleId;
            const source_window = state.window(source_tab.window) orelse return error.StaleId;
            try source_window.tabs.ensureUnusedCapacity(state.allocator, 1);
            try state.node_ids.free.ensureUnusedCapacity(state.allocator, 1);
        }
        try undoTransferTopology(state, record);
    }
    const record = &state.transfers.items[index];
    const focus = if (applied) record.moved_focus else record.source_focus;
    const source_window = state.tab(record.source_tab).?.window;
    const target_window = state.tab(record.target_tab).?.window;
    appendTransferEffects(state, out, source_window, target_window, focus);
}

fn discardTransfer(state: *model.ShellState, out: *Reduction, source_root: model.NodeId) !void {
    const index = transferIndex(state, source_root) orelse return error.StaleId;
    const record = state.transfers.items[index];
    const discard_source_shell = record.applied and record.source_parent == null;
    var remove_window = false;
    var source_window_id: ?model.WindowId = null;
    if (discard_source_shell) {
        const source_tab = state.tab(record.source_tab) orelse return error.InvalidTransfer;
        const source_window = retainingWindowForTab(state, record.source_tab) orelse return error.InvalidTransfer;
        source_window_id = source_window.id;
        remove_window = source_window.tabs.items.len == 0 and source_window.retained_tabs.items.len == 1;
        try state.tab_ids.free.ensureUnusedCapacity(state.allocator, 1);
        if (remove_window) try state.window_ids.free.ensureUnusedCapacity(state.allocator, 1);
        _ = source_tab;
    }
    try out.effects.ensureUnusedCapacity(state.allocator, if (remove_window) 2 else 1);

    if (discard_source_shell) {
        const source_window = retainingWindowForTab(state, record.source_tab).?;
        const retained_index = indexOfId(source_window.retained_tabs.items, record.source_tab).?;
        _ = source_window.retained_tabs.orderedRemove(retained_index);
        removeTab(state, record.source_tab);
        try state.tab_ids.release(state.allocator, record.source_tab);
        if (remove_window) {
            const window_id = source_window_id.?;
            removeWindow(state, window_id);
            try state.window_ids.release(state.allocator, window_id);
            out.effects.appendAssumeCapacity(.{ .destroy_window = window_id });
        }
    }
    _ = state.transfers.orderedRemove(index);
    out.effects.appendAssumeCapacity(.persist_session);
}

fn applyTransferTopology(state: *model.ShellState, record: *model.Transfer) !void {
    const source_tab = state.tab(record.source_tab) orelse return error.StaleId;
    const target_tab = state.tab(record.target_tab) orelse return error.StaleId;
    const axis: model.Axis = switch (record.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };
    const source_first = record.direction == .left or record.direction == .up;

    if (record.source_parent) |wrapper| {
        const split = record.source_split orelse return error.InvalidTransfer;
        const sibling = if (split.first.eql(record.source_root)) split.second else split.first;
        replaceChildOrRoot(state, source_tab, record.source_parent_parent, wrapper, sibling) catch return error.InvalidTransfer;
        replaceChildOrRoot(state, target_tab, record.target_parent, record.target_leaf, wrapper) catch return error.InvalidTransfer;
        state.node(wrapper).?.value = .{ .split = .{
            .axis = axis,
            .ratio = record.ratio,
            .first = if (source_first) record.source_root else record.target_leaf,
            .second = if (source_first) record.target_leaf else record.source_root,
        } };
        state.node(wrapper).?.tab = target_tab.id;
        if (treeContainsPane(state, record.source_root, source_tab.focused_pane)) {
            source_tab.focused_pane = firstPane(state, sibling) orelse return error.InvalidTransfer;
        }
    } else {
        const source_window = activeWindowForTab(state, source_tab.id) orelse return error.InvalidTransfer;
        const active_index = indexOfId(source_window.tabs.items, source_tab.id) orelse return error.InvalidTransfer;
        _ = source_window.tabs.orderedRemove(active_index);
        source_window.retained_tabs.appendAssumeCapacity(source_tab.id);
        if (source_window.tabs.items.len == 0) source_window.active_tab = null else if (source_window.active_tab.?.eql(source_tab.id))
            source_window.active_tab = source_window.tabs.items[@min(active_index, source_window.tabs.items.len - 1)];

        const displaced = state.node_ids.acquireAssumeCapacity();
        const old_value = state.node(record.target_leaf).?.value;
        state.nodes.appendAssumeCapacity(.{ .id = displaced, .tab = target_tab.id, .value = old_value });
        record.displaced_target = displaced;
        state.node(record.target_leaf).?.value = .{ .split = .{
            .axis = axis,
            .ratio = record.ratio,
            .first = if (source_first) record.source_root else displaced,
            .second = if (source_first) displaced else record.source_root,
        } };
    }
    retagTree(state, record.source_root, target_tab.id);
    target_tab.focused_pane = if (treeContainsPane(state, record.source_root, record.source_focus))
        record.source_focus
    else
        (firstPane(state, record.source_root) orelse return error.InvalidTransfer);
    state.window(target_tab.window).?.active_tab = target_tab.id;
    state.focused_window = target_tab.window;
    record.applied = true;
}

fn undoTransferTopology(state: *model.ShellState, record: *model.Transfer) !void {
    const source_tab = state.tab(record.source_tab) orelse return error.StaleId;
    const target_tab = state.tab(record.target_tab) orelse return error.StaleId;
    if (record.source_parent == null) {
        const source_window = retainingWindowForTab(state, source_tab.id) orelse return error.InvalidTransfer;
        if (record.source_tab_index > source_window.tabs.items.len) return error.InvalidTransfer;
    }
    retagTree(state, record.source_root, source_tab.id);
    if (record.source_parent) |wrapper| {
        const split = record.source_split orelse return error.InvalidTransfer;
        const sibling = if (split.first.eql(record.source_root)) split.second else split.first;
        replaceChildOrRoot(state, target_tab, record.target_parent, wrapper, record.target_leaf) catch return error.InvalidTransfer;
        replaceChildOrRoot(state, source_tab, record.source_parent_parent, sibling, wrapper) catch return error.InvalidTransfer;
        state.node(wrapper).?.value = .{ .split = split };
        state.node(wrapper).?.tab = source_tab.id;
    } else {
        const displaced = record.displaced_target orelse return error.InvalidTransfer;
        const displaced_node = state.node(displaced) orelse return error.InvalidTransfer;
        state.node(record.target_leaf).?.value = displaced_node.value;
        removeNode(state, displaced);
        try state.node_ids.release(state.allocator, displaced);
        record.displaced_target = null;
        const source_window = retainingWindowForTab(state, source_tab.id) orelse return error.InvalidTransfer;
        const retained_index = indexOfId(source_window.retained_tabs.items, source_tab.id) orelse return error.InvalidTransfer;
        _ = source_window.retained_tabs.orderedRemove(retained_index);
        source_window.tabs.insertAssumeCapacity(record.source_tab_index, source_tab.id);
        source_window.active_tab = source_tab.id;
    }
    source_tab.focused_pane = record.source_focus;
    target_tab.focused_pane = record.target_focus;
    state.window(source_tab.window).?.active_tab = source_tab.id;
    state.focused_window = source_tab.window;
    record.applied = false;
}

fn appendTransferEffects(state: *model.ShellState, out: *Reduction, source_window: model.WindowId, target_window: model.WindowId, focus: model.PaneId) void {
    _ = state;
    out.effects.appendAssumeCapacity(.{ .focus_surface = focus });
    out.effects.appendAssumeCapacity(.{ .relayout_window = source_window });
    if (!target_window.eql(source_window)) out.effects.appendAssumeCapacity(.{ .relayout_window = target_window });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn focusWindow(state: *model.ShellState, out: *Reduction, window_id: model.WindowId) !void {
    const window = state.window(window_id) orelse return error.StaleId;
    if (window.tabs.items.len == 0) return error.StaleId;
    const pane = selectors.focusedPane(state, window_id) orelse return error.StaleId;
    try out.effects.ensureUnusedCapacity(state.allocator, 1);
    state.focused_window = window_id;
    out.effects.appendAssumeCapacity(.{ .focus_surface = pane });
}

fn focusTab(state: *model.ShellState, out: *Reduction, tab_id: model.TabId) !void {
    const tab = state.tab(tab_id) orelse return error.StaleId;
    const window = activeWindowForTab(state, tab_id) orelse return error.StaleId;
    try out.effects.ensureUnusedCapacity(state.allocator, 2);
    window.active_tab = tab_id;
    state.focused_window = window.id;
    out.effects.appendAssumeCapacity(.{ .focus_surface = tab.focused_pane });
    out.effects.appendAssumeCapacity(.{ .relayout_window = window.id });
}

fn focusPane(state: *model.ShellState, out: *Reduction, pane_id: model.PaneId) !void {
    const pane = state.pane(pane_id) orelse return error.StaleId;
    const tab = state.tab(pane.tab) orelse return error.StaleId;
    const window = activeWindowForTab(state, tab.id) orelse return error.StaleId;
    try out.effects.ensureUnusedCapacity(state.allocator, 2);
    tab.focused_pane = pane_id;
    window.active_tab = tab.id;
    state.focused_window = window.id;
    out.effects.appendAssumeCapacity(.{ .focus_surface = pane_id });
    out.effects.appendAssumeCapacity(.{ .relayout_window = window.id });
}

fn closePane(state: *model.ShellState, out: *Reduction, pane_id: model.PaneId) !void {
    const pane = state.pane(pane_id) orelse return error.StaleId;
    const tab = state.tab(pane.tab) orelse return error.StaleId;
    if (activeWindowForTab(state, tab.id) == null) return error.StaleId;
    if (selectors.paneCount(state, tab.id) == 1) return error.LastPane;

    const relation = findPaneRelation(state, tab.root, pane_id, null) orelse return error.StaleId;
    const parent_id = relation.parent orelse return error.LastPane;
    const parent = state.node(parent_id) orelse return error.StaleId;
    const split = switch (parent.value) {
        .split => |value| value,
        else => unreachable,
    };
    const sibling_id = if (split.first.eql(relation.node)) split.second else split.first;
    const sibling = state.node(sibling_id) orelse return error.StaleId;
    const sibling_value = sibling.value;
    const next_focus = firstPane(state, sibling_id) orelse return error.StaleId;
    const window_id = tab.window;
    try out.effects.ensureUnusedCapacity(state.allocator, 4);
    try state.node_ids.free.ensureUnusedCapacity(state.allocator, 2);
    try state.pane_ids.free.ensureUnusedCapacity(state.allocator, 1);

    parent.value = sibling_value;
    removeNode(state, relation.node);
    removeNode(state, sibling_id);
    removePane(state, pane_id);
    try state.node_ids.release(state.allocator, relation.node);
    try state.node_ids.release(state.allocator, sibling_id);
    try state.pane_ids.release(state.allocator, pane_id);
    if (tab.focused_pane.eql(pane_id)) tab.focused_pane = next_focus;

    out.effects.appendAssumeCapacity(.{ .destroy_surface = pane_id });
    out.effects.appendAssumeCapacity(.{ .focus_surface = tab.focused_pane });
    out.effects.appendAssumeCapacity(.{ .relayout_window = window_id });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn closeTab(state: *model.ShellState, out: *Reduction, tab_id: model.TabId) !void {
    const tab = state.tab(tab_id) orelse return error.StaleId;
    const window_id = tab.window;
    const window = activeWindowForTab(state, tab_id) orelse return error.StaleId;
    if (window.tabs.items.len == 1) return closeWindow(state, out, window_id);

    const pane_count = selectors.paneCount(state, tab_id);
    try out.effects.ensureUnusedCapacity(state.allocator, pane_count + 3);
    try state.pane_ids.free.ensureUnusedCapacity(state.allocator, pane_count);
    var node_count: usize = 0;
    for (state.nodes.items) |node| if (node.tab.eql(tab_id)) {
        node_count += 1;
    };
    try state.node_ids.free.ensureUnusedCapacity(state.allocator, node_count);
    try state.tab_ids.free.ensureUnusedCapacity(state.allocator, 1);

    var i = state.panes.items.len;
    while (i > 0) {
        i -= 1;
        if (state.panes.items[i].tab.eql(tab_id)) {
            const id = state.panes.items[i].id;
            out.effects.appendAssumeCapacity(.{ .destroy_surface = id });
            _ = state.panes.swapRemove(i);
            try state.pane_ids.release(state.allocator, id);
        }
    }
    i = state.nodes.items.len;
    while (i > 0) {
        i -= 1;
        if (state.nodes.items[i].tab.eql(tab_id)) {
            const id = state.nodes.items[i].id;
            _ = state.nodes.swapRemove(i);
            try state.node_ids.release(state.allocator, id);
        }
    }
    removeTab(state, tab_id);
    try state.tab_ids.release(state.allocator, tab_id);
    removeTabId(window, tab_id);
    if (window.active_tab.?.eql(tab_id)) window.active_tab = window.tabs.items[0];
    const focused = state.tab(window.active_tab.?).?.focused_pane;
    out.effects.appendAssumeCapacity(.{ .focus_surface = focused });
    out.effects.appendAssumeCapacity(.{ .relayout_window = window_id });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn detachTab(state: *model.ShellState, out: *Reduction, tab_id: model.TabId) !void {
    const tab = state.tab(tab_id) orelse return error.StaleId;
    const window = activeWindowForTab(state, tab_id) orelse return error.StaleId;
    const active_index = indexOfId(window.tabs.items, tab_id) orelse return error.StaleId;
    const was_active = window.active_tab != null and window.active_tab.?.eql(tab_id);
    const was_focused_window = state.focused_window != null and state.focused_window.?.eql(window.id);

    try window.retained_tabs.ensureUnusedCapacity(state.allocator, 1);
    // relayout + persist, with one optional replacement focus.
    try out.effects.ensureUnusedCapacity(state.allocator, 3);

    _ = window.tabs.orderedRemove(active_index);
    window.retained_tabs.appendAssumeCapacity(tab_id);
    if (window.tabs.items.len == 0) {
        window.active_tab = null;
        if (was_focused_window) state.focused_window = firstActiveWindow(state);
    } else if (was_active) {
        window.active_tab = window.tabs.items[@min(active_index, window.tabs.items.len - 1)];
    }

    if (was_active and was_focused_window) {
        if (state.focused_window) |focused_window| {
            if (selectors.focusedPane(state, focused_window)) |focused_pane| {
                out.effects.appendAssumeCapacity(.{ .focus_surface = focused_pane });
            }
        }
    }
    out.effects.appendAssumeCapacity(.{ .relayout_window = tab.window });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn restoreTab(
    state: *model.ShellState,
    out: *Reduction,
    tab_id: model.TabId,
    index: usize,
) !void {
    const tab = state.tab(tab_id) orelse return error.StaleId;
    const window = retainingWindowForTab(state, tab_id) orelse return error.StaleId;
    if (index > window.tabs.items.len) return error.InvalidIndex;
    const retained_index = indexOfId(window.retained_tabs.items, tab_id) orelse return error.StaleId;

    try window.tabs.ensureUnusedCapacity(state.allocator, 1);
    try out.effects.ensureUnusedCapacity(state.allocator, 3);

    _ = window.retained_tabs.orderedRemove(retained_index);
    window.tabs.insertAssumeCapacity(index, tab_id);
    window.active_tab = tab_id;
    state.focused_window = window.id;

    out.effects.appendAssumeCapacity(.{ .focus_surface = tab.focused_pane });
    out.effects.appendAssumeCapacity(.{ .relayout_window = window.id });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn discardDetachedTab(state: *model.ShellState, out: *Reduction, tab_id: model.TabId) !void {
    const window = retainingWindowForTab(state, tab_id) orelse return error.StaleId;
    const retained_index = indexOfId(window.retained_tabs.items, tab_id) orelse return error.StaleId;
    const window_id = window.id;
    const pane_count = selectors.paneCount(state, tab_id);
    var node_count: usize = 0;
    for (state.nodes.items) |node| {
        if (node.tab.eql(tab_id)) node_count += 1;
    }
    const remove_window = window.tabs.items.len == 0 and window.retained_tabs.items.len == 1;

    try out.effects.ensureUnusedCapacity(state.allocator, pane_count + @as(usize, if (remove_window) 2 else 1));
    try state.pane_ids.free.ensureUnusedCapacity(state.allocator, pane_count);
    try state.node_ids.free.ensureUnusedCapacity(state.allocator, node_count);
    try state.tab_ids.free.ensureUnusedCapacity(state.allocator, 1);
    if (remove_window) try state.window_ids.free.ensureUnusedCapacity(state.allocator, 1);

    _ = window.retained_tabs.orderedRemove(retained_index);
    var i = state.panes.items.len;
    while (i > 0) {
        i -= 1;
        if (state.panes.items[i].tab.eql(tab_id)) {
            const id = state.panes.items[i].id;
            out.effects.appendAssumeCapacity(.{ .destroy_surface = id });
            _ = state.panes.swapRemove(i);
            try state.pane_ids.release(state.allocator, id);
        }
    }
    i = state.nodes.items.len;
    while (i > 0) {
        i -= 1;
        if (state.nodes.items[i].tab.eql(tab_id)) {
            const id = state.nodes.items[i].id;
            _ = state.nodes.swapRemove(i);
            try state.node_ids.release(state.allocator, id);
        }
    }
    removeTab(state, tab_id);
    try state.tab_ids.release(state.allocator, tab_id);

    if (remove_window) {
        removeWindow(state, window_id);
        try state.window_ids.release(state.allocator, window_id);
        out.effects.appendAssumeCapacity(.{ .destroy_window = window_id });
    }
    out.effects.appendAssumeCapacity(.persist_session);
}

fn reorderTab(state: *model.ShellState, out: *Reduction, tab_id: model.TabId, index: usize) !void {
    const tab = state.tab(tab_id) orelse return error.StaleId;
    const window = activeWindowForTab(state, tab_id) orelse return error.StaleId;
    if (index >= window.tabs.items.len) return error.InvalidIndex;
    const old_index = indexOfId(window.tabs.items, tab_id) orelse return error.StaleId;
    if (old_index == index) return;

    try out.effects.ensureUnusedCapacity(state.allocator, 2);
    _ = window.tabs.orderedRemove(old_index);
    window.tabs.insertAssumeCapacity(index, tab_id);
    out.effects.appendAssumeCapacity(.{ .relayout_window = tab.window });
    out.effects.appendAssumeCapacity(.persist_session);
}

fn closeWindow(state: *model.ShellState, out: *Reduction, window_id: model.WindowId) !void {
    const window = state.window(window_id) orelse return error.StaleId;
    var pane_count: usize = 0;
    var node_count: usize = 0;
    for (state.tabs.items) |tab| if (tab.window.eql(window_id)) {
        pane_count += selectors.paneCount(state, tab.id);
        for (state.nodes.items) |node| if (node.tab.eql(tab.id)) {
            node_count += 1;
        };
    };
    try out.effects.ensureUnusedCapacity(state.allocator, pane_count + 2);
    try state.pane_ids.free.ensureUnusedCapacity(state.allocator, pane_count);
    try state.node_ids.free.ensureUnusedCapacity(state.allocator, node_count);
    try state.tab_ids.free.ensureUnusedCapacity(state.allocator, window.tabs.items.len + window.retained_tabs.items.len);
    try state.window_ids.free.ensureUnusedCapacity(state.allocator, 1);

    var tab_i = state.tabs.items.len;
    while (tab_i > 0) {
        tab_i -= 1;
        if (!state.tabs.items[tab_i].window.eql(window_id)) continue;
        const tab_id = state.tabs.items[tab_i].id;
        var i = state.panes.items.len;
        while (i > 0) {
            i -= 1;
            if (state.panes.items[i].tab.eql(tab_id)) {
                const id = state.panes.items[i].id;
                out.effects.appendAssumeCapacity(.{ .destroy_surface = id });
                _ = state.panes.swapRemove(i);
                try state.pane_ids.release(state.allocator, id);
            }
        }
        i = state.nodes.items.len;
        while (i > 0) {
            i -= 1;
            if (state.nodes.items[i].tab.eql(tab_id)) {
                const id = state.nodes.items[i].id;
                _ = state.nodes.swapRemove(i);
                try state.node_ids.release(state.allocator, id);
            }
        }
        _ = state.tabs.swapRemove(tab_i);
        try state.tab_ids.release(state.allocator, tab_id);
    }
    removeWindow(state, window_id);
    try state.window_ids.release(state.allocator, window_id);
    out.effects.appendAssumeCapacity(.{ .destroy_window = window_id });
    out.effects.appendAssumeCapacity(.persist_session);

    if (state.focused_window == null or state.focused_window.?.eql(window_id)) {
        state.focused_window = firstActiveWindow(state);
    }
}

fn indexOfId(items: []const model.TabId, id: model.TabId) ?usize {
    for (items, 0..) |item, index| if (item.eql(id)) return index;
    return null;
}

fn activeWindowForTab(state: *model.ShellState, tab_id: model.TabId) ?*model.Window {
    const tab = state.tab(tab_id) orelse return null;
    const window = state.window(tab.window) orelse return null;
    return if (indexOfId(window.tabs.items, tab_id) != null) window else null;
}

fn retainingWindowForTab(state: *model.ShellState, tab_id: model.TabId) ?*model.Window {
    const tab = state.tab(tab_id) orelse return null;
    const window = state.window(tab.window) orelse return null;
    return if (indexOfId(window.retained_tabs.items, tab_id) != null) window else null;
}

fn firstActiveWindow(state: *const model.ShellState) ?model.WindowId {
    for (state.windows.items) |window| if (window.tabs.items.len > 0) return window.id;
    return null;
}

const Relation = struct { node: model.NodeId, parent: ?model.NodeId };

fn findNodeRelation(state: *model.ShellState, root: model.NodeId, wanted: model.NodeId, parent: ?model.NodeId) ?Relation {
    if (root.eql(wanted)) return .{ .node = root, .parent = parent };
    const node = state.node(root) orelse return null;
    return switch (node.value) {
        .pane => null,
        .split => |split| findNodeRelation(state, split.first, wanted, root) orelse
            findNodeRelation(state, split.second, wanted, root),
    };
}

fn replaceChildOrRoot(
    state: *model.ShellState,
    tab: *model.Tab,
    parent_id: ?model.NodeId,
    old: model.NodeId,
    new: model.NodeId,
) error{InvalidTransfer}!void {
    if (parent_id) |id| {
        const parent = state.node(id) orelse return error.InvalidTransfer;
        switch (parent.value) {
            .pane => return error.InvalidTransfer,
            .split => |*split| {
                if (split.first.eql(old)) split.first = new else if (split.second.eql(old)) split.second = new else return error.InvalidTransfer;
            },
        }
    } else {
        if (!tab.root.eql(old)) return error.InvalidTransfer;
        tab.root = new;
    }
}

fn treeContainsPane(state: *model.ShellState, root: model.NodeId, pane: model.PaneId) bool {
    const node = state.node(root) orelse return false;
    return switch (node.value) {
        .pane => |id| id.eql(pane),
        .split => |split| treeContainsPane(state, split.first, pane) or treeContainsPane(state, split.second, pane),
    };
}

fn retagTree(state: *model.ShellState, root: model.NodeId, tab_id: model.TabId) void {
    const node = state.node(root) orelse return;
    node.tab = tab_id;
    switch (node.value) {
        .pane => |pane| state.pane(pane).?.tab = tab_id,
        .split => |split| {
            retagTree(state, split.first, tab_id);
            retagTree(state, split.second, tab_id);
        },
    }
}

fn transferIndex(state: *const model.ShellState, source_root: model.NodeId) ?usize {
    for (state.transfers.items, 0..) |transfer, index| if (transfer.source_root.eql(source_root)) return index;
    return null;
}

fn findPaneRelation(state: *model.ShellState, node_id: model.NodeId, pane_id: model.PaneId, parent: ?model.NodeId) ?Relation {
    const node = state.node(node_id) orelse return null;
    return switch (node.value) {
        .pane => |id| if (id.eql(pane_id)) .{ .node = node_id, .parent = parent } else null,
        .split => |split| findPaneRelation(state, split.first, pane_id, node_id) orelse
            findPaneRelation(state, split.second, pane_id, node_id),
    };
}

fn findPaneNode(state: *model.ShellState, tab_id: model.TabId, pane_id: model.PaneId) ?*model.Node {
    for (state.nodes.items) |*node| if (node.tab.eql(tab_id)) switch (node.value) {
        .pane => |id| if (id.eql(pane_id)) return node,
        .split => {},
    };
    return null;
}

fn firstPane(state: *model.ShellState, node_id: model.NodeId) ?model.PaneId {
    const node = state.node(node_id) orelse return null;
    return switch (node.value) {
        .pane => |id| id,
        .split => |split| firstPane(state, split.first),
    };
}

fn removeWindow(state: *model.ShellState, id: model.WindowId) void {
    for (state.windows.items, 0..) |*window, i| if (window.id.eql(id)) {
        window.deinit(state.allocator);
        _ = state.windows.swapRemove(i);
        return;
    };
}

fn removeTab(state: *model.ShellState, id: model.TabId) void {
    for (state.tabs.items, 0..) |tab, i| if (tab.id.eql(id)) {
        _ = state.tabs.swapRemove(i);
        return;
    };
}

fn removePane(state: *model.ShellState, id: model.PaneId) void {
    for (state.panes.items, 0..) |pane, i| if (pane.id.eql(id)) {
        _ = state.panes.swapRemove(i);
        return;
    };
}

fn removeNode(state: *model.ShellState, id: model.NodeId) void {
    for (state.nodes.items, 0..) |node, i| if (node.id.eql(id)) {
        _ = state.nodes.swapRemove(i);
        return;
    };
}

fn removeTabId(window: *model.Window, id: model.TabId) void {
    for (window.tabs.items, 0..) |item, i| if (item.eql(id)) {
        _ = window.tabs.orderedRemove(i);
        return;
    };
}
