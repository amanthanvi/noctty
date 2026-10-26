const model = @import("model.zig");

pub const Intent = union(enum) {
    create_window,
    close_window: model.WindowId,
    create_tab: struct {
        window: model.WindowId,
        /// Where the tab goes in the window's order, as the native strip
        /// inserts it (`window-new-tab-position`); null appends.
        index: ?usize = null,
    },
    close_tab: model.TabId,
    detach_tab: model.TabId,
    restore_tab: struct {
        tab: model.TabId,
        index: usize,
        /// Bring the tab to the front, as when the tab that closed was in
        /// front. A tab that closed behind the front one comes back behind
        /// it. A window with no tab in front always gets the restored one.
        activate: bool = true,
    },
    discard_detached_tab: model.TabId,
    reorder_tab: struct {
        tab: model.TabId,
        index: usize,
    },
    split_pane: struct {
        pane: model.PaneId,
        direction: model.Direction,
        ratio: f32 = 0.5,
    },
    /// Graft `source_root` (or its whole tab when it is the tab root) at the
    /// target pane. Existing pane/node identities are retained.
    transfer_subtree: struct {
        source_root: model.NodeId,
        target_pane: model.PaneId,
        direction: model.Direction,
        ratio: f32 = 0.5,
    },
    /// Exact history toggle for a prior transfer. `applied=false` is undo;
    /// `applied=true` is redo. The durable record is keyed by source_root.
    set_transfer_applied: struct {
        source_root: model.NodeId,
        applied: bool,
    },
    /// Expire transfer history. Applied whole-tab transfers release only the
    /// empty retained Tab/Window shell; moved Pane/Node IDs stay target-owned.
    discard_transfer: model.NodeId,
    close_pane: model.PaneId,
    /// Undo of a split: the pane leaves its tab as `close_pane` would, but
    /// its window retains its ID for redo instead of releasing it.
    detach_pane: model.PaneId,
    /// Redo of a split: a pane `detach_pane` retained splits `at` again on
    /// the `direction` side, in half, with its own ID.
    restore_pane: struct {
        pane: model.PaneId,
        at: model.PaneId,
        direction: model.Direction,
    },
    /// Expire the redo that retained `pane`: its ID is released.
    discard_detached_pane: model.PaneId,
    focus_window: model.WindowId,
    focus_tab: model.TabId,
    focus_pane: model.PaneId,
};
