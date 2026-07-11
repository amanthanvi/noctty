//! Two-phase bridge between the pure shell reducer and fallible native work.
//! Prepare mutates an isolated candidate; commit is the sole authoritative
//! state swap. Dropping a prepared transaction rolls the candidate back.

const std = @import("std");
const model = @import("model.zig");
const intent_mod = @import("intent.zig");
const reducer = @import("reducer.zig");

pub const Created = struct {
    window: ?model.WindowId = null,
    tab: ?model.TabId = null,
    pane: ?model.PaneId = null,
};

pub const Runtime = struct {
    state: model.ShellState,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Runtime {
        return .{ .state = model.ShellState.init(allocator) };
    }

    pub fn deinit(self: *Runtime) void {
        self.state.deinit();
    }

    pub fn prepare(self: *const Runtime, intent: intent_mod.Intent) !Prepared {
        var next = try self.state.clone();
        errdefer next.deinit();
        var reduction = try reducer.apply(&next, intent);
        errdefer reduction.deinit(next.allocator);
        try next.validate();

        return .{
            .next = next,
            .reduction = reduction,
            .created = createdEntities(&next, &reduction),
            .expected_revision = self.revision,
        };
    }

    /// Allocation-free focus transition for the UI hot path.
    pub fn focusPane(self: *Runtime, pane_id: model.PaneId) !bool {
        const pane = self.state.pane(pane_id) orelse return error.StaleId;
        const tab = self.state.tab(pane.tab) orelse return error.StaleId;
        const window = self.state.window(tab.window) orelse return error.StaleId;
        const unchanged = tab.focused_pane.eql(pane_id) and
            window.active_tab != null and window.active_tab.?.eql(tab.id) and
            self.state.focused_window != null and self.state.focused_window.?.eql(window.id);
        if (unchanged) return false;
        tab.focused_pane = pane_id;
        window.active_tab = tab.id;
        self.state.focused_window = window.id;
        self.bumpRevision();
        return true;
    }

    fn bumpRevision(self: *Runtime) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }
};

pub const Prepared = struct {
    next: ?model.ShellState,
    reduction: reducer.Reduction,
    created: Created,
    expected_revision: u64,

    pub fn deinit(self: *Prepared) void {
        if (self.next) |*next| {
            self.reduction.deinit(next.allocator);
            next.deinit();
            self.next = null;
        }
    }

    pub fn commit(self: *Prepared, runtime: *Runtime) !void {
        if (runtime.revision != self.expected_revision) return error.StaleRevision;
        const next = self.next orelse return;
        self.reduction.deinit(next.allocator);
        runtime.state.deinit();
        runtime.state = next;
        self.next = null;
        runtime.bumpRevision();
    }
};

fn createdEntities(next: *const model.ShellState, reduction: *const reducer.Reduction) Created {
    var result: Created = .{};
    for (reduction.effects.items) |effect| switch (effect) {
        .create_window => |id| result.window = id,
        .create_surface => |id| {
            result.pane = id;
            if (next.paneConst(id)) |pane| {
                result.tab = pane.tab;
                if (next.tabConst(pane.tab)) |tab| result.window = tab.window;
            }
        },
        else => {},
    };
    return result;
}

test "prepared transaction commits atomically" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var prepared = try runtime.prepare(.create_window);
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), runtime.state.windows.items.len);
    try std.testing.expect(prepared.created.window != null);
    try std.testing.expect(prepared.created.tab != null);
    try std.testing.expect(prepared.created.pane != null);

    try prepared.commit(&runtime);
    try runtime.state.validate();
    try std.testing.expectEqual(@as(usize, 1), runtime.state.windows.items.len);
}

test "discarded transaction preserves authoritative state and generations" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var initial = try runtime.prepare(.create_window);
    try initial.commit(&runtime);
    initial.deinit();
    const window_id = runtime.state.windows.items[0].id;
    const generations = runtime.state.tab_ids.generations.items.len;

    var discarded = try runtime.prepare(.{ .create_tab = window_id });
    discarded.deinit();
    try runtime.state.validate();
    try std.testing.expectEqual(@as(usize, 1), runtime.state.tabs.items.len);
    try std.testing.expectEqual(generations, runtime.state.tab_ids.generations.items.len);
}

test "stale prepared commit cannot overwrite newer authority" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var first = try runtime.prepare(.create_window);
    defer first.deinit();
    var stale = try runtime.prepare(.create_window);
    defer stale.deinit();
    try first.commit(&runtime);
    try std.testing.expectError(error.StaleRevision, stale.commit(&runtime));
    try std.testing.expectEqual(@as(usize, 1), runtime.state.windows.items.len);
}

test "focus pane is allocation free and revisioned" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    var created = try runtime.prepare(.create_window);
    defer created.deinit();
    try created.commit(&runtime);
    const original = runtime.state.panes.items[0].id;

    var split = try runtime.prepare(.{ .split_pane = .{ .pane = original, .direction = .right } });
    defer split.deinit();
    try split.commit(&runtime);
    const revision = runtime.revision;
    try std.testing.expect(try runtime.focusPane(original));
    try std.testing.expectEqual(revision + 1, runtime.revision);
    try std.testing.expect(!try runtime.focusPane(original));
}
