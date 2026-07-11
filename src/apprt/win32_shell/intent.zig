const model = @import("model.zig");

pub const Intent = union(enum) {
    create_window,
    close_window: model.WindowId,
    create_tab: model.WindowId,
    close_tab: model.TabId,
    detach_tab: model.TabId,
    restore_tab: struct {
        tab: model.TabId,
        index: usize,
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
    focus_window: model.WindowId,
    focus_tab: model.TabId,
    focus_pane: model.PaneId,
};
