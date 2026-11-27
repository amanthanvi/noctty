const std = @import("std");
const progress_report = @This();

pub const State = enum(c_int) {
    remove,
    set,
    @"error",
    indeterminate,
    pause,
};

pub const Report = struct {
    pub const State = progress_report.State;

    state: progress_report.State,
    progress: ?u8 = null,

    // sync with ghostty_action_progress_report_s
    pub const C = extern struct {
        state: c_int,
        progress: i8,
    };

    pub fn cval(self: Report) C {
        return .{
            .state = @backingInt(self.state),
            .progress = if (self.progress) |progress| @intCast(std.math.clamp(
                progress,
                0,
                100,
            )) else -1,
        };
    }
};

test "progress report C value preserves state and clamps progress" {
    const report: Report = .{
        .state = .set,
        .progress = 255,
    };
    const c = report.cval();
    try std.testing.expectEqual(@backingInt(State.set), c.state);
    try std.testing.expectEqual(@as(i8, 100), c.progress);

    const indeterminate: Report = .{ .state = .indeterminate };
    try std.testing.expectEqual(@as(i8, -1), indeterminate.cval().progress);
}
