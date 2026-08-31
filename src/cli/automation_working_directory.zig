const std = @import("std");

/// Keep this in sync with win32_ipc.max_new_window_arg_len. This CLI module
/// validates before platform dispatch so an oversized value is a usage error.
const max_wire_bytes: usize = 32 * 1024;

/// Mirrors win32.forwardedWorkingDirectoryAllowed.
pub fn allowed(value: []const u8) bool {
    if (value.len > max_wire_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.indexOfScalar(u8, value, 0) != null)
    {
        return false;
    }

    var path = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
        path = std.mem.trim(u8, path[1 .. path.len - 1], &std.ascii.whitespace);
    }

    if (std.mem.eql(u8, path, "home") or
        std.mem.eql(u8, path, "inherit") or
        std.mem.eql(u8, path, "~"))
    {
        return true;
    }

    if (path.len >= 2 and
        path[0] == '~' and
        (path[1] == '/' or path[1] == '\\'))
    {
        return true;
    }

    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        (path[2] == '/' or path[2] == '\\');
}

test "automation working directory enforces wire byte limit" {
    const alloc = std.testing.allocator;
    const path = try alloc.alloc(u8, max_wire_bytes + 1);
    defer alloc.free(path);
    @memset(path, 'x');
    @memcpy(path[0..3], "C:\\");

    try std.testing.expect(allowed(path[0..max_wire_bytes]));
    try std.testing.expect(!allowed(path));
}
