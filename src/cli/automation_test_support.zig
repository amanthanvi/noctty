const std = @import("std");

/// Minimal argument iterator for automation CLI unit tests.
pub const TestArgs = struct {
    items: []const []const u8,
    index: usize = 0,

    /// Returns the next test argument, or null at the end of the input.
    pub fn next(self: *@This()) ?[]const u8 {
        if (self.index == self.items.len) {
            return null;
        }
        defer self.index += 1;
        return self.items[self.index];
    }
};

/// Runs an injected automation CLI seam with in-memory arguments and stderr.
pub fn testRun(comptime runner: anytype, items: []const []const u8, hook: anytype) !u8 {
    var iter: TestArgs = .{ .items = items };
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();

    return runner(std.testing.allocator, &iter, &stderr.writer, hook);
}

/// Maps stable CLI exit codes to representative hook outcomes for tests.
pub fn testOutcome(code: u8) !bool {
    return switch (code) {
        1 => error.InvalidAutomationTarget,
        2 => false,
        3 => error.AutomationTargetNotFound,
        4 => error.AutomationPolicyRefused,
        5 => error.IPCFailed,
        else => true,
    };
}
