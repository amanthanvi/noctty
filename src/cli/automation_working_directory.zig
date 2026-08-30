const std = @import("std");
/// Mirrors win32.forwardedWorkingDirectoryAllowed.
pub fn allowed(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    var path = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
        path = std.mem.trim(u8, path[1 .. path.len - 1], &std.ascii.whitespace);
    }
    if (std.mem.eql(u8, path, "home") or std.mem.eql(u8, path, "inherit") or std.mem.eql(u8, path, "~")) return true;
    if (path.len >= 2 and path[0] == '~' and (path[1] == '/' or path[1] == '\\')) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '/' or path[2] == '\\');
}
pub const TestArgs = struct {
    items: []const []const u8,
    index: usize = 0,
    pub fn next(self: *@This()) ?[]const u8 {
        if (self.index == self.items.len) return null;
        defer self.index += 1;
        return self.items[self.index];
    }
};
pub fn testRun(comptime runner: anytype, items: []const []const u8, hook: anytype) !u8 {
    var iter: TestArgs = .{ .items = items };
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    return runner(std.testing.allocator, &iter, &stderr.writer, hook);
}
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
