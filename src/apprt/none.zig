const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Always return false as there is no apprt to communicate with.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
        _: u64,
    ) !bool {
        return false;
    }

    pub fn queryAutomationWindowList(
        _: Allocator,
        _: apprt.ipc.Target,
        _: u64,
    ) !?[]u8 {
        return null;
    }

    pub fn performAutomationAction(
        _: Allocator,
        _: apprt.ipc.Target,
        _: apprt.ipc.AutomationActionTarget,
        _: []const u8,
        _: u64,
    ) !bool {
        return false;
    }

    pub fn focusAutomationTarget(
        _: Allocator,
        _: apprt.ipc.Target,
        _: apprt.ipc.AutomationTarget,
        _: u64,
    ) !bool {
        return false;
    }

    pub fn newAutomationTab(
        _: Allocator,
        _: apprt.ipc.Target,
        _: apprt.ipc.AutomationTarget,
        _: ?[]const u8,
        _: u64,
    ) !bool {
        return false;
    }

    pub fn newAutomationSplit(
        _: Allocator,
        _: apprt.ipc.Target,
        _: apprt.ipc.AutomationTarget,
        _: apprt.ipc.AutomationSplitDirection,
        _: ?[]const u8,
        _: u64,
    ) !bool {
        return false;
    }

    pub fn sendAutomationText(
        _: Allocator,
        _: apprt.ipc.Target,
        _: apprt.ipc.AutomationTarget,
        _: []const u8,
        _: u64,
    ) !bool {
        return false;
    }

    pub fn performAutomationCommand(_: *App, _: apprt.ipc.AutomationCommand) !void {}

    pub fn buildAutomationWindowListJson(
        _: *App,
        _: Allocator,
    ) ![]u8 {
        return error.Unsupported;
    }
};
pub const Surface = struct {};
