//! Two-phase bridge between the pure shell reducer and fallible native work.
//! Prepare mutates an isolated candidate; commit is the sole authoritative
//! state swap. Dropping a prepared transaction rolls the candidate back.
//! A committed transaction keeps its reduction's effects until it is
//! dropped, for the platform to apply (`Prepared.effects`).

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
            .allocator = self.state.allocator,
            .created = createdEntities(&next, &reduction),
            .intent = intent,
            .expected_revision = self.revision,
        };
    }

    /// Allocation-free focus transition for the UI hot path.
    pub fn focusPane(self: *Runtime, pane_id: model.PaneId) !bool {
        return self.setPaneFocus(pane_id, true);
    }

    /// `focusPane` for a pane that comes up without taking the keyboard, such
    /// as one in a window that is not in front: its tab becomes the window's
    /// active tab and it the tab's focused pane, but the window does not
    /// become the focused window.
    pub fn activatePane(self: *Runtime, pane_id: model.PaneId) !bool {
        return self.setPaneFocus(pane_id, false);
    }

    fn setPaneFocus(self: *Runtime, pane_id: model.PaneId, take_window: bool) !bool {
        const pane = self.state.pane(pane_id) orelse return error.StaleId;
        const tab = self.state.tab(pane.tab) orelse return error.StaleId;
        const window = self.state.window(tab.window) orelse return error.StaleId;
        // A model with windows always names one as focused (`validate`).
        const takes_window = take_window or self.state.focused_window == null;
        const unchanged = tab.focused_pane.eql(pane_id) and
            window.active_tab != null and window.active_tab.?.eql(tab.id) and
            (!takes_window or (self.state.focused_window != null and self.state.focused_window.?.eql(window.id)));
        if (unchanged) return false;
        tab.focused_pane = pane_id;
        window.active_tab = tab.id;
        if (takes_window) self.state.focused_window = window.id;
        self.bumpRevision();
        return true;
    }

    fn bumpRevision(self: *Runtime) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    /// Emergency close reconciliation after native teardown. The close
    /// reducers reserve every fallible allocation before mutating state, so a
    /// failure leaves authority unchanged. The caller applies the returned
    /// effects and frees them with the state's allocator.
    pub fn forceClose(self: *Runtime, intent: intent_mod.Intent) !reducer.Reduction {
        switch (intent) {
            .close_window, .close_tab, .close_pane => {},
            else => return error.InvalidForceIntent,
        }
        var reduction = try reducer.apply(&self.state, intent);
        errdefer reduction.deinit(self.state.allocator);
        try self.state.validate();
        self.bumpRevision();
        return reduction;
    }

    /// Remove a just-created window after native session restore fails.
    /// This path is intentionally allocation-free: the generational IDs are
    /// retired rather than recycled, and normal Runtime teardown reclaims the
    /// pool storage later.
    pub fn rollbackWindow(self: *Runtime, window_id: model.WindowId) void {
        var tab_i = self.state.tabs.items.len;
        while (tab_i > 0) {
            tab_i -= 1;
            const tab = self.state.tabs.items[tab_i];
            if (!tab.window.eql(window_id)) continue;

            var pane_i = self.state.panes.items.len;
            while (pane_i > 0) {
                pane_i -= 1;
                if (self.state.panes.items[pane_i].tab.eql(tab.id)) {
                    _ = self.state.panes.swapRemove(pane_i);
                }
            }
            var node_i = self.state.nodes.items.len;
            while (node_i > 0) {
                node_i -= 1;
                if (self.state.nodes.items[node_i].tab.eql(tab.id)) {
                    _ = self.state.nodes.swapRemove(node_i);
                }
            }
            var transfer_i = self.state.transfers.items.len;
            while (transfer_i > 0) {
                transfer_i -= 1;
                const transfer = self.state.transfers.items[transfer_i];
                if (transfer.source_tab.eql(tab.id) or transfer.target_tab.eql(tab.id)) {
                    _ = self.state.transfers.swapRemove(transfer_i);
                }
            }
            _ = self.state.tabs.swapRemove(tab_i);
        }

        for (self.state.windows.items, 0..) |*window, i| {
            if (!window.id.eql(window_id)) continue;
            var removed = self.state.windows.swapRemove(i);
            removed.deinit(self.state.allocator);
            break;
        }
        if (self.state.focused_window == null or self.state.focused_window.?.eql(window_id)) {
            self.state.focused_window = null;
            for (self.state.windows.items) |window| {
                if (window.tabs.items.len == 0) continue;
                self.state.focused_window = window.id;
                break;
            }
        }
        self.bumpRevision();
    }
};

pub const Prepared = struct {
    next: ?model.ShellState,
    reduction: reducer.Reduction,
    allocator: std.mem.Allocator,
    created: Created,
    intent: intent_mod.Intent,
    expected_revision: u64,
    /// The authority this transaction replaced, kept from commit to deinit
    /// so that a native step failing after the commit can put it back
    /// (`rollback`).
    previous: ?model.ShellState = null,
    /// The revision the commit produced: `rollback` applies only while it
    /// is still the runtime's.
    committed_revision: u64 = 0,

    pub fn deinit(self: *Prepared) void {
        if (self.next) |*next| {
            next.deinit();
            self.next = null;
        }
        if (self.previous) |*previous| {
            previous.deinit();
            self.previous = null;
        }
        self.reduction.deinit(self.allocator);
        self.reduction = .{};
    }

    /// What the committed transaction asks of the platform. Empty until it
    /// commits, when a retry found its work already done, and after a
    /// rollback.
    pub fn effects(self: *const Prepared) []const reducer.Effect {
        if (self.next != null) return &.{};
        return self.reduction.effects.items;
    }

    pub fn commit(self: *Prepared, runtime: *Runtime) !void {
        if (runtime.revision != self.expected_revision) return error.StaleRevision;
        const next = self.next orelse return;
        self.previous = runtime.state;
        runtime.state = next;
        self.next = null;
        runtime.bumpRevision();
        self.committed_revision = runtime.revision;
    }

    /// Takes a commit back because the platform could not carry out its
    /// effects: the authority it replaced returns, allocation-free, and
    /// the effects are dropped. Only while nothing else has committed on
    /// top of it (`StaleRevision`); the revision still moves forward, so a
    /// transaction prepared against the rolled-back state is stale.
    pub fn rollback(self: *Prepared, runtime: *Runtime) !void {
        const previous = self.previous orelse return error.NotCommitted;
        if (runtime.revision != self.committed_revision) return error.StaleRevision;
        runtime.state.deinit();
        runtime.state = previous;
        self.previous = null;
        runtime.bumpRevision();
        self.reduction.effects.clearRetainingCapacity();
    }

    /// A synchronous DestroyWindow can dispatch focus messages between close
    /// prepare and commit. Rebuild the close candidate from current authority
    /// so the latest focus survives rather than stranding the removed pane.
    /// A retry that finds its entity already gone (`StaleId`, `LastPane`)
    /// counts the close as done.
    pub fn commitRetryingInterleavedFocus(self: *Prepared, runtime: *Runtime) !void {
        return self.commitRetrying(runtime, .done);
    }

    /// `commitRetryingInterleavedFocus` for a change whose entities must
    /// still be there: something else committed in between (a focus
    /// change, or a history clear releasing what the model kept for undo,
    /// the `discard_detached_*` intents), so the change is rebuilt on top of
    /// it, and a retry that finds an entity gone fails, for the caller to
    /// undo its native half.
    pub fn commitRetryingStale(self: *Prepared, runtime: *Runtime) !void {
        return self.commitRetrying(runtime, .failed);
    }

    fn commitRetrying(self: *Prepared, runtime: *Runtime, gone: enum { done, failed }) !void {
        self.commit(runtime) catch |err| switch (err) {
            error.StaleRevision => {
                var retry = runtime.prepare(self.intent) catch |retry_err| switch (retry_err) {
                    error.StaleId, error.LastPane => if (gone == .done) return else return retry_err,
                    else => return retry_err,
                };
                defer retry.deinit();
                try retry.commit(runtime);
                // What the retry did is what happened, and what a rollback
                // takes back.
                std.mem.swap(reducer.Reduction, &self.reduction, &retry.reduction);
                std.mem.swap(?model.ShellState, &self.previous, &retry.previous);
                self.committed_revision = retry.committed_revision;
                if (self.next) |*stale| stale.deinit();
                self.next = null;
            },
            else => return err,
        };
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

    var discarded = try runtime.prepare(.{ .create_tab = .{ .window = window_id } });
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

test "a rollback puts back the authority its commit replaced" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var window = try runtime.prepare(.create_window);
    defer window.deinit();
    try window.commit(&runtime);
    const first = window.created.pane.?;
    var split = try runtime.prepare(.{ .split_pane = .{ .pane = first, .direction = .right } });
    defer split.deinit();
    try split.commit(&runtime);
    const created = split.created.pane.?;

    var detach = try runtime.prepare(.{ .detach_pane = created });
    defer detach.deinit();
    try std.testing.expectError(error.NotCommitted, detach.rollback(&runtime));
    try detach.commit(&runtime);
    try std.testing.expect(runtime.state.pane(created) == null);
    try std.testing.expectEqual(@as(usize, 3), detach.effects().len);

    // The platform could not follow: the split is back as it was, with its
    // focus, and nothing is left for the platform to apply.
    const revision = runtime.revision;
    try detach.rollback(&runtime);
    try runtime.state.validate();
    try std.testing.expect(runtime.state.pane(created) != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.state.windows.items[0].retained_panes.items.len);
    try std.testing.expect(runtime.state.tabs.items[0].focused_pane.eql(created));
    try std.testing.expectEqual(@as(usize, 0), detach.effects().len);
    // The revision moves on: what was prepared against the detached state
    // is stale.
    try std.testing.expect(runtime.revision != revision);
    try std.testing.expectError(error.NotCommitted, detach.rollback(&runtime));

    // A commit on top of another one cannot be taken back.
    var again = try runtime.prepare(.{ .detach_pane = created });
    defer again.deinit();
    try again.commit(&runtime);
    var later = try runtime.prepare(.{ .create_tab = .{ .window = window.created.window.? } });
    defer later.deinit();
    try later.commit(&runtime);
    try std.testing.expectError(error.StaleRevision, again.rollback(&runtime));
    try std.testing.expect(runtime.state.pane(created) == null);
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

test "activating a pane shows it without making its window the focused one" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var first = try runtime.prepare(.create_window);
    defer first.deinit();
    try first.commit(&runtime);
    var second = try runtime.prepare(.create_window);
    defer second.deinit();
    try second.commit(&runtime);
    var other_tab = try runtime.prepare(.{ .create_tab = .{ .window = second.created.window.? } });
    defer other_tab.deinit();
    try other_tab.commit(&runtime);
    const first_window = first.created.window.?;
    const second_window = second.created.window.?;
    try std.testing.expect(try runtime.focusPane(first.created.pane.?));
    try std.testing.expect(runtime.state.focused_window.?.eql(first_window));
    // The second window's first tab is behind its second.
    try std.testing.expect(runtime.state.window(second_window).?.active_tab.?.eql(other_tab.created.tab.?));

    const revision = runtime.revision;
    try std.testing.expect(try runtime.activatePane(second.created.pane.?));
    try std.testing.expectEqual(revision + 1, runtime.revision);
    try std.testing.expect(runtime.state.window(second_window).?.active_tab.?.eql(second.created.tab.?));
    try std.testing.expect(runtime.state.focused_window.?.eql(first_window));
    try std.testing.expect(!try runtime.activatePane(second.created.pane.?));
    try runtime.state.validate();

    // Real focus is what moves the focused window.
    try std.testing.expect(try runtime.focusPane(second.created.pane.?));
    try std.testing.expect(runtime.state.focused_window.?.eql(second_window));
}

test "restore rollback removes only the failed window without allocation" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var first = try runtime.prepare(.create_window);
    defer first.deinit();
    try first.commit(&runtime);
    const surviving_window = first.created.window.?;

    var second = try runtime.prepare(.create_window);
    defer second.deinit();
    try second.commit(&runtime);
    const failed_window = second.created.window.?;
    const failed_tab = second.created.tab.?;
    const failed_pane = second.created.pane.?;

    runtime.rollbackWindow(failed_window);
    try runtime.state.validate();
    try std.testing.expect(runtime.state.window(surviving_window) != null);
    try std.testing.expect(runtime.state.window(failed_window) == null);
    try std.testing.expect(runtime.state.tab(failed_tab) == null);
    try std.testing.expect(runtime.state.pane(failed_pane) == null);
}

test "close retry preserves interleaved focus and removes pane" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var window = try runtime.prepare(.create_window);
    defer window.deinit();
    try window.commit(&runtime);
    const original = runtime.state.panes.items[0].id;

    var split = try runtime.prepare(.{ .split_pane = .{ .pane = original, .direction = .right } });
    defer split.deinit();
    try split.commit(&runtime);
    const sibling = split.created.pane.?;
    try std.testing.expect(try runtime.focusPane(original));

    var close = try runtime.prepare(.{ .close_pane = original });
    defer close.deinit();
    try std.testing.expectEqual(std.meta.Tag(intent_mod.Intent).close_pane, std.meta.activeTag(close.intent));
    try std.testing.expect(try runtime.focusPane(sibling));
    try std.testing.expectError(error.StaleRevision, close.commit(&runtime));
    try close.commitRetryingInterleavedFocus(&runtime);

    try runtime.state.validate();
    try std.testing.expect(runtime.state.pane(original) == null);
    try std.testing.expect(runtime.state.pane(sibling) != null);
    try std.testing.expect(runtime.state.tab(runtime.state.pane(sibling).?.tab).?.focused_pane.eql(sibling));
}

test "close tab retry preserves focus in the surviving tab" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var window = try runtime.prepare(.create_window);
    defer window.deinit();
    try window.commit(&runtime);
    const window_id = window.created.window.?;
    const original_pane = window.created.pane.?;
    const original_tab = window.created.tab.?;

    var second = try runtime.prepare(.{ .create_tab = .{ .window = window_id } });
    defer second.deinit();
    try second.commit(&runtime);
    const surviving_pane = second.created.pane.?;
    const surviving_tab = second.created.tab.?;
    try std.testing.expect(try runtime.focusPane(original_pane));

    var close = try runtime.prepare(.{ .close_tab = original_tab });
    defer close.deinit();
    try std.testing.expectEqual(std.meta.Tag(intent_mod.Intent).close_tab, std.meta.activeTag(close.intent));
    try std.testing.expect(try runtime.focusPane(surviving_pane));
    try close.commitRetryingInterleavedFocus(&runtime);

    try runtime.state.validate();
    try std.testing.expect(runtime.state.tab(original_tab) == null);
    try std.testing.expect(runtime.state.tab(surviving_tab) != null);
    try std.testing.expect(runtime.state.window(window_id).?.active_tab.?.eql(surviving_tab));
    try std.testing.expect(runtime.state.tab(surviving_tab).?.focused_pane.eql(surviving_pane));
}

test "a committed transaction hands its effects to the platform" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var window = try runtime.prepare(.create_window);
    defer window.deinit();
    try window.commit(&runtime);
    const first = window.created.pane.?;
    var split = try runtime.prepare(.{ .split_pane = .{ .pane = first, .direction = .right } });
    defer split.deinit();
    try split.commit(&runtime);
    const second = split.created.pane.?;

    // The focused new pane closes: its sibling takes focus.
    var close = try runtime.prepare(.{ .close_pane = second });
    defer close.deinit();
    try std.testing.expectEqual(@as(usize, 0), close.effects().len);
    try close.commit(&runtime);
    try std.testing.expectEqual(@as(usize, 2), close.effects().len);
    try std.testing.expect(close.effects()[0].focus_surface.eql(first));
    try std.testing.expectEqual(std.meta.Tag(reducer.Effect).persist_session, std.meta.activeTag(close.effects()[1]));

    // A retry hands over its own effects. In [first / (third | fourth)]
    // with fourth focused, closing first would keep fourth; the user moved
    // to third before the close committed, and third is what stays.
    var again = try runtime.prepare(.{ .split_pane = .{ .pane = first, .direction = .down } });
    defer again.deinit();
    try again.commit(&runtime);
    const third = again.created.pane.?;
    var last = try runtime.prepare(.{ .split_pane = .{ .pane = third, .direction = .right } });
    defer last.deinit();
    try last.commit(&runtime);
    var stale = try runtime.prepare(.{ .close_pane = first });
    defer stale.deinit();
    _ = try runtime.focusPane(third);
    try stale.commitRetryingInterleavedFocus(&runtime);
    try std.testing.expect(stale.effects()[0].focus_surface.eql(third));

    // A close another path already made has nothing left to apply.
    var split_back = try runtime.prepare(.{ .split_pane = .{ .pane = third, .direction = .right } });
    defer split_back.deinit();
    try split_back.commit(&runtime);
    var done = try runtime.prepare(.{ .close_pane = third });
    defer done.deinit();
    var current = try runtime.prepare(.{ .close_pane = third });
    defer current.deinit();
    try current.commit(&runtime);
    try done.commitRetryingInterleavedFocus(&runtime);
    try std.testing.expectEqual(@as(usize, 0), done.effects().len);
}

test "close retry treats an already removed entity as complete" {
    const allocator = std.testing.allocator;
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();

    var window = try runtime.prepare(.create_window);
    defer window.deinit();
    try window.commit(&runtime);
    const original = runtime.state.panes.items[0].id;
    var split = try runtime.prepare(.{ .split_pane = .{ .pane = original, .direction = .right } });
    defer split.deinit();
    try split.commit(&runtime);

    var stale = try runtime.prepare(.{ .close_pane = original });
    defer stale.deinit();
    var current = try runtime.prepare(.{ .close_pane = original });
    defer current.deinit();
    try current.commit(&runtime);
    try stale.commitRetryingInterleavedFocus(&runtime);
    try runtime.state.validate();
    try std.testing.expect(runtime.state.pane(original) == null);
}
