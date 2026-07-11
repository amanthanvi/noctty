const std = @import("std");
const model = @import("model.zig");

pub fn activeTab(state: *const model.ShellState, window_id: model.WindowId) ?model.TabId {
    const window = state.windowConst(window_id) orelse return null;
    return window.active_tab;
}

pub fn focusedPane(state: *const model.ShellState, window_id: model.WindowId) ?model.PaneId {
    const tab_id = activeTab(state, window_id) orelse return null;
    const tab = state.tabConst(tab_id) orelse return null;
    return tab.focused_pane;
}

pub fn paneCount(state: *const model.ShellState, tab_id: model.TabId) usize {
    var count: usize = 0;
    for (state.panes.items) |pane| if (pane.tab.eql(tab_id)) {
        count += 1;
    };
    return count;
}

pub fn orderedPanesAlloc(
    allocator: std.mem.Allocator,
    state: *const model.ShellState,
    tab_id: model.TabId,
) ![]model.PaneId {
    const tab = state.tabConst(tab_id) orelse return error.StaleId;
    var result: std.ArrayList(model.PaneId) = .empty;
    errdefer result.deinit(allocator);
    try appendLeaves(allocator, state, tab.root, &result);
    return result.toOwnedSlice(allocator);
}

fn appendLeaves(
    allocator: std.mem.Allocator,
    state: *const model.ShellState,
    node_id: model.NodeId,
    result: *std.ArrayList(model.PaneId),
) !void {
    const node = state.nodeConst(node_id) orelse return error.InvalidTree;
    switch (node.value) {
        .pane => |pane| try result.append(allocator, pane),
        .split => |split| {
            try appendLeaves(allocator, state, split.first, result);
            try appendLeaves(allocator, state, split.second, result);
        },
    }
}
