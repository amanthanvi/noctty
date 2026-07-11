const std = @import("std");
const ids = @import("ids.zig");

pub const WindowId = ids.WindowId;
pub const TabId = ids.TabId;
pub const PaneId = ids.PaneId;
pub const NodeId = ids.NodeId;

pub const Axis = enum { horizontal, vertical };
pub const Direction = enum { left, right, up, down };

pub const Split = struct {
    axis: Axis,
    ratio: f32,
    first: NodeId,
    second: NodeId,
};

pub const NodeValue = union(enum) {
    pane: PaneId,
    split: Split,
};

pub const Window = struct {
    id: WindowId,
    /// Tabs currently presented by the native Host, in visual order.
    tabs: std.ArrayList(TabId) = .empty,
    /// Tabs detached from the native Host but retained by structural undo.
    /// Their Tab/Pane/Node records and generational IDs remain owned by this
    /// ShellState until restore or explicit discard.
    retained_tabs: std.ArrayList(TabId) = .empty,
    active_tab: ?TabId = null,

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        self.tabs.deinit(allocator);
        self.retained_tabs.deinit(allocator);
    }
};

pub const Tab = struct {
    id: TabId,
    window: WindowId,
    root: NodeId,
    focused_pane: PaneId,
};

pub const Pane = struct {
    id: PaneId,
    tab: TabId,
};

pub const Node = struct {
    id: NodeId,
    tab: TabId,
    value: NodeValue,
};

/// Durable provenance for an identity-preserving tree graft. Records remain
/// in the model while structural history can toggle them between applied and
/// undone; callers never need to infer an inverse from the current topology.
pub const Transfer = struct {
    source_tab: TabId,
    source_root: NodeId,
    source_parent: ?NodeId,
    source_parent_parent: ?NodeId,
    source_split: ?Split,
    source_tab_index: usize,
    source_focus: PaneId,
    moved_focus: PaneId,
    target_tab: TabId,
    target_leaf: NodeId,
    target_parent: ?NodeId,
    target_focus: PaneId,
    direction: Direction,
    ratio: f32,
    /// Whole-tab grafts displace the target leaf into this retained node.
    /// Non-root subtree grafts reuse `source_parent` as the graft wrapper.
    displaced_target: ?NodeId,
    applied: bool,
};

pub const ShellState = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window) = .empty,
    tabs: std.ArrayList(Tab) = .empty,
    panes: std.ArrayList(Pane) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    transfers: std.ArrayList(Transfer) = .empty,
    focused_window: ?WindowId = null,

    window_ids: ids.Pool(WindowId) = .{},
    tab_ids: ids.Pool(TabId) = .{},
    pane_ids: ids.Pool(PaneId) = .{},
    node_ids: ids.Pool(NodeId) = .{},

    pub fn init(allocator: std.mem.Allocator) ShellState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShellState) void {
        for (self.windows.items) |*window_item| window_item.deinit(self.allocator);
        self.windows.deinit(self.allocator);
        self.tabs.deinit(self.allocator);
        self.panes.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.transfers.deinit(self.allocator);
        self.window_ids.deinit(self.allocator);
        self.tab_ids.deinit(self.allocator);
        self.pane_ids.deinit(self.allocator);
        self.node_ids.deinit(self.allocator);
    }

    /// Returns an ownership-independent snapshot suitable for staging a
    /// reducer transaction. No list storage is shared with `self`.
    pub fn clone(self: *const ShellState) !ShellState {
        var result = ShellState.init(self.allocator);
        errdefer result.deinit();

        try result.windows.ensureUnusedCapacity(self.allocator, self.windows.items.len);
        for (self.windows.items) |window_item| {
            var window_copy: Window = .{
                .id = window_item.id,
                .active_tab = window_item.active_tab,
            };
            errdefer window_copy.deinit(self.allocator);
            try window_copy.tabs.appendSlice(self.allocator, window_item.tabs.items);
            try window_copy.retained_tabs.appendSlice(self.allocator, window_item.retained_tabs.items);
            result.windows.appendAssumeCapacity(window_copy);
        }
        try result.tabs.appendSlice(self.allocator, self.tabs.items);
        try result.panes.appendSlice(self.allocator, self.panes.items);
        try result.nodes.appendSlice(self.allocator, self.nodes.items);
        try result.transfers.appendSlice(self.allocator, self.transfers.items);
        result.focused_window = self.focused_window;

        try clonePool(WindowId, self.allocator, &result.window_ids, &self.window_ids);
        try clonePool(TabId, self.allocator, &result.tab_ids, &self.tab_ids);
        try clonePool(PaneId, self.allocator, &result.pane_ids, &self.pane_ids);
        try clonePool(NodeId, self.allocator, &result.node_ids, &self.node_ids);
        return result;
    }

    pub fn window(self: *ShellState, id: WindowId) ?*Window {
        if (!self.window_ids.isCurrent(id)) return null;
        for (self.windows.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn tab(self: *ShellState, id: TabId) ?*Tab {
        if (!self.tab_ids.isCurrent(id)) return null;
        for (self.tabs.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn pane(self: *ShellState, id: PaneId) ?*Pane {
        if (!self.pane_ids.isCurrent(id)) return null;
        for (self.panes.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn node(self: *ShellState, id: NodeId) ?*Node {
        if (!self.node_ids.isCurrent(id)) return null;
        for (self.nodes.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn windowConst(self: *const ShellState, id: WindowId) ?*const Window {
        if (!self.window_ids.isCurrent(id)) return null;
        for (self.windows.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn tabConst(self: *const ShellState, id: TabId) ?*const Tab {
        if (!self.tab_ids.isCurrent(id)) return null;
        for (self.tabs.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn paneConst(self: *const ShellState, id: PaneId) ?*const Pane {
        if (!self.pane_ids.isCurrent(id)) return null;
        for (self.panes.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn nodeConst(self: *const ShellState, id: NodeId) ?*const Node {
        if (!self.node_ids.isCurrent(id)) return null;
        for (self.nodes.items) |*item| if (item.id.eql(id)) return item;
        return null;
    }

    pub fn validate(self: *const ShellState) !void {
        if (self.windows.items.len == 0) {
            if (self.focused_window != null or self.tabs.items.len != 0 or
                self.panes.items.len != 0 or self.nodes.items.len != 0 or self.transfers.items.len != 0)
                return error.OrphanedState;
            return;
        }

        var active_window_count: usize = 0;
        for (self.windows.items) |window_item| {
            if (!self.window_ids.isCurrent(window_item.id)) return error.StaleWindow;
            if (window_item.tabs.items.len == 0 and window_item.retained_tabs.items.len == 0)
                return error.EmptyWindow;

            var active_found = window_item.tabs.items.len == 0 and window_item.active_tab == null;
            if (window_item.tabs.items.len > 0) {
                active_window_count += 1;
                if (window_item.active_tab == null) return error.InvalidActiveTab;
            } else if (window_item.active_tab != null) return error.InvalidActiveTab;

            for (window_item.tabs.items) |tab_id| {
                const tab_item = self.tabConst(tab_id) orelse return error.MissingTab;
                if (!tab_item.window.eql(window_item.id)) return error.WrongWindow;
                if (tab_id.eql(window_item.active_tab.?)) active_found = true;
            }
            for (window_item.retained_tabs.items) |tab_id| {
                const tab_item = self.tabConst(tab_id) orelse return error.MissingTab;
                if (!tab_item.window.eql(window_item.id)) return error.WrongWindow;
            }
            if (!active_found) return error.InvalidActiveTab;
        }

        if (active_window_count == 0) {
            if (self.focused_window != null) return error.InvalidFocusedWindow;
        } else {
            const focused_id = self.focused_window orelse return error.InvalidFocusedWindow;
            const focused = self.windowConst(focused_id) orelse return error.InvalidFocusedWindow;
            if (focused.tabs.items.len == 0) return error.InvalidFocusedWindow;
        }

        var visited_panes: std.ArrayList(PaneId) = .empty;
        defer visited_panes.deinit(self.allocator);
        for (self.tabs.items) |tab_item| {
            if (self.windowConst(tab_item.window) == null) return error.MissingWindow;
            var memberships: usize = 0;
            for (self.windows.items) |window_item| {
                for (window_item.tabs.items) |id| if (id.eql(tab_item.id)) {
                    memberships += 1;
                };
                for (window_item.retained_tabs.items) |id| if (id.eql(tab_item.id)) {
                    memberships += 1;
                };
            }
            if (memberships == 0) return error.OrphanedTab;
            if (memberships != 1) return error.DuplicateTab;
            if (self.appliedWholeTabTransfer(tab_item.id)) continue;
            const focused = self.paneConst(tab_item.focused_pane) orelse return error.MissingFocusedPane;
            if (!focused.tab.eql(tab_item.id)) return error.WrongTab;
            try self.validateTree(tab_item, &visited_panes);
        }
        if (visited_panes.items.len != self.panes.items.len) return error.OrphanedPane;

        for (self.transfers.items, 0..) |transfer, index| {
            if (!self.node_ids.isCurrent(transfer.source_root) or
                !self.tab_ids.isCurrent(transfer.source_tab) or
                !self.tab_ids.isCurrent(transfer.target_tab)) return error.StaleTransfer;
            for (self.transfers.items[0..index]) |prior| {
                if (prior.source_root.eql(transfer.source_root)) return error.DuplicateTransfer;
            }
            if (!(transfer.ratio > 0 and transfer.ratio < 1)) return error.InvalidRatio;
        }
    }

    fn appliedWholeTabTransfer(self: *const ShellState, tab_id: TabId) bool {
        for (self.transfers.items) |transfer| {
            if (transfer.applied and transfer.source_parent == null and transfer.source_tab.eql(tab_id)) return true;
        }
        return false;
    }

    fn validateTree(
        self: *const ShellState,
        tab_item: Tab,
        visited_panes: *std.ArrayList(PaneId),
    ) !void {
        var visited: std.ArrayList(NodeId) = .empty;
        defer visited.deinit(self.allocator);
        var stack: std.ArrayList(NodeId) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, tab_item.root);

        while (stack.pop()) |node_id| {
            for (visited.items) |seen| if (seen.eql(node_id)) return error.InvalidTree;
            try visited.append(self.allocator, node_id);
            const node_item = self.nodeConst(node_id) orelse return error.MissingNode;
            if (!node_item.tab.eql(tab_item.id)) return error.WrongTab;
            switch (node_item.value) {
                .pane => |pane_id| {
                    const pane_item = self.paneConst(pane_id) orelse return error.MissingPane;
                    if (!pane_item.tab.eql(tab_item.id)) return error.WrongTab;
                    for (visited_panes.items) |seen| {
                        if (seen.eql(pane_id)) return error.DuplicatePane;
                    }
                    try visited_panes.append(self.allocator, pane_id);
                },
                .split => |split| {
                    if (!(split.ratio > 0 and split.ratio < 1)) return error.InvalidRatio;
                    try stack.append(self.allocator, split.first);
                    try stack.append(self.allocator, split.second);
                },
            }
        }

        var tab_node_count: usize = 0;
        for (self.nodes.items) |node_item| if (node_item.tab.eql(tab_item.id)) {
            tab_node_count += 1;
        };
        if (tab_node_count != visited.items.len) return error.UnreachableNode;
    }
};

fn clonePool(
    comptime EntityId: type,
    allocator: std.mem.Allocator,
    destination: *ids.Pool(EntityId),
    source: *const ids.Pool(EntityId),
) !void {
    try destination.generations.appendSlice(allocator, source.generations.items);
    try destination.active.appendSlice(allocator, source.active.items);
    try destination.free.appendSlice(allocator, source.free.items);
}

test "shell state clone owns independent model and id pool storage" {
    const reducer = @import("reducer.zig");
    const allocator = std.testing.allocator;
    var original = ShellState.init(allocator);
    defer original.deinit();

    var created = try reducer.apply(&original, .create_window);
    defer created.deinit(allocator);
    var copy = try original.clone();
    defer copy.deinit();

    const window_id = original.windows.items[0].id;
    var added = try reducer.apply(&copy, .{ .create_tab = window_id });
    defer added.deinit(allocator);

    try original.validate();
    try copy.validate();
    try std.testing.expectEqual(@as(usize, 1), original.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), copy.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), original.windows.items[0].tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), copy.windows.items[0].tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), original.tab_ids.generations.items.len);
    try std.testing.expectEqual(@as(usize, 2), copy.tab_ids.generations.items.len);
}
