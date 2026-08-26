//! Named layouts: profile + split tree in one object (C17).
//!
//! A layout file is a `win32_session_state.SessionState` JSON document
//! stored as `%LOCALAPPDATA%\winghostty\layouts\<name>.json`. Filename
//! (minus `.json`) is the layout name.

const std = @import("std");
const win32_session_state = @import("win32_session_state.zig");

pub const max_name_len = 64;

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
            else => return false,
        }
    }
    return true;
}

pub fn fileName(name: []const u8, out: []u8) ![]const u8 {
    if (!isValidName(name)) return error.InvalidLayoutName;
    return std.fmt.bufPrint(out, "{s}.json", .{name});
}

pub fn parseLayout(alloc: std.mem.Allocator, raw: []const u8) !std.json.Parsed(win32_session_state.SessionState) {
    return win32_session_state.parseAlloc(alloc, raw);
}

pub fn listLayoutNames(alloc: std.mem.Allocator, dir_path: []const u8) ![][]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try alloc.alloc([]const u8, 0),
        else => return err,
    };
    defer dir.close();

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - ".json".len];
        if (!isValidName(stem)) continue;
        try names.append(alloc, try alloc.dupe(u8, stem));
    }
    return try names.toOwnedSlice(alloc);
}

test "isValidName rejects path junk" {
    try std.testing.expect(isValidName("dev"));
    try std.testing.expect(isValidName("web_2"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName(".."));
    try std.testing.expect(!isValidName("a/b"));
    try std.testing.expect(!isValidName("a\\b"));
}

test "parseLayout reuses session-state schema" {
    const raw =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:\\src","profile":"pwsh"}}]}}]}]}
    ;
    var parsed = try parseLayout(std.testing.allocator, raw);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.windows.len);
    try std.testing.expectEqualStrings("C:\\src", parsed.value.windows[0].tabs[0].layout.nodes[0].pane.cwd.?);
}
