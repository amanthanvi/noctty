const ids = @import("ids.zig");
const model = @import("model.zig");

pub const Effect = union(enum) {
    create_window: model.WindowId,
    destroy_window: model.WindowId,
    create_surface: model.PaneId,
    destroy_surface: model.PaneId,
    focus_surface: model.PaneId,
    relayout_window: model.WindowId,
    persist_session,
};

pub const Pending = struct {
    id: ids.EffectId,
    effect: Effect,
};
