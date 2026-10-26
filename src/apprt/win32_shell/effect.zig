const model = @import("model.zig");

/// What a committed reduction asks of the platform. `create_*` name the
/// entities a prepared transaction made (`runtime.Created`); the platform
/// consumes the rest after commit (`App.applyShellEffects` in win32.zig,
/// and `Host.applyCommittedSplitHistory` for the split-tree changes).
pub const Effect = union(enum) {
    create_window: model.WindowId,
    create_surface: model.PaneId,
    /// A pane its window retained (`detach_pane`) joins its tab's tree
    /// again: it splits `beside` and takes the `direction` side.
    attach_surface: struct {
        pane: model.PaneId,
        beside: model.PaneId,
        direction: model.Direction,
    },
    /// The pane leaves its tab's tree; its window retains it for redo.
    detach_surface: model.PaneId,
    /// The pane is its tab's focused pane; native focus follows.
    focus_surface: model.PaneId,
    /// The windows, tabs or panes changed shape; the saved session follows.
    persist_session,
};
