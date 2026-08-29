//! Windows session-state file I/O and recovery policy.

const std = @import("std");
const sys = @import("win32/sys.zig");
const schema = @import("win32_session_state.zig");
const Allocator = std.mem.Allocator;

pub const default_max_state_bytes: usize = 1024 * 1024;

pub const LoadResult = union(enum) {
    missing,
    oversized,
    transient: anyerror,
    corrupt: anyerror,
    loaded: std.json.Parsed(schema.SessionState),

    pub fn deinit(self: *LoadResult) void {
        switch (self.*) {
            .loaded => |*parsed| parsed.deinit(),
            else => {},
        }
    }
};

pub fn loadAlloc(alloc: Allocator, absolute_path: []const u8, max_bytes: usize) LoadResult {
    return loadWithParser(alloc, absolute_path, max_bytes, schema.parseAlloc);
}

pub fn loadLayoutAlloc(alloc: Allocator, absolute_path: []const u8, max_bytes: usize) LoadResult {
    return loadWithParser(alloc, absolute_path, max_bytes, schema.parseLayoutAlloc);
}

fn loadWithParser(
    alloc: Allocator,
    absolute_path: []const u8,
    max_bytes: usize,
    comptime parse: fn (Allocator, []const u8) anyerror!std.json.Parsed(schema.SessionState),
) LoadResult {
    const raw = readFileBoundedAlloc(alloc, absolute_path, max_bytes) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        error.FileTooBig => .oversized,
        else => .{ .transient = err },
    };
    defer alloc.free(raw);

    // `parseAlloc` parses with `.allocate = .alloc_always`, so the document
    // owns every string and survives the `raw` free above.
    const parsed = parse(alloc, raw) catch |err| return switch (err) {
        error.OutOfMemory => .{ .transient = err },
        else => .{ .corrupt = err },
    };
    return .{ .loaded = parsed };
}

pub fn quarantineCorruptFileAlloc(alloc: Allocator, absolute_path: []const u8) ![]u8 {
    var collision_index: usize = 0;
    while (true) : (collision_index += 1) {
        const destination = if (collision_index == 0)
            try std.fmt.allocPrint(alloc, "{s}.corrupt", .{absolute_path})
        else
            try std.fmt.allocPrint(alloc, "{s}.corrupt.{d}", .{ absolute_path, collision_index });
        errdefer alloc.free(destination);

        const exists = exists: {
            std.fs.accessAbsolute(destination, .{}) catch |err| switch (err) {
                error.FileNotFound => break :exists false,
                else => return err,
            };
            break :exists true;
        };
        if (exists) {
            alloc.free(destination);
            continue;
        }

        std.fs.renameAbsolute(absolute_path, destination) catch |err| switch (err) {
            error.PathAlreadyExists => {
                alloc.free(destination);
                continue;
            },
            else => return err,
        };
        return destination;
    }
}

pub fn deleteFileIfPresent(absolute_path: []const u8) !void {
    std.fs.deleteFileAbsolute(absolute_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

pub fn writeFileAtomic(absolute_path: []const u8, temporary_path: []const u8, bytes: []const u8) !void {
    var temporary_created = false;
    errdefer if (temporary_created) deleteFileIfPresent(temporary_path) catch {};

    {
        var file = try std.fs.createFileAbsolute(temporary_path, .{ .truncate = true });
        temporary_created = true;
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }

    if (try replaceFileAtomic(absolute_path, temporary_path)) |failure| {
        std.log.warn(
            "win32 atomic replace failed replace_win32_error={d} move_win32_error={d}",
            .{ failure.replace_error, failure.move_error },
        );
        return std.os.windows.unexpectedError(@enumFromInt(failure.move_error));
    }
    temporary_created = false;
}

pub const AtomicReplaceFailure = struct {
    replace_error: u32,
    move_error: u32,
};

pub const WriteDisposition = union(enum) {
    atomic,
    in_place: AtomicReplaceFailure,
};

/// Recovery-ledger persistence is allowed to trade atomicity for progress.
/// Saved-session callers continue to use `writeFileAtomic` and fail closed.
pub fn writeFileAtomicOrInPlace(
    absolute_path: []const u8,
    temporary_path: []const u8,
    bytes: []const u8,
    atomic_failure: *?AtomicReplaceFailure,
) !WriteDisposition {
    atomic_failure.* = null;
    var temporary_created = false;
    // Once replacement fails, retain the unique temporary record if the
    // in-place fallback also fails. Recovery folds it into the next append.
    errdefer if (temporary_created and atomic_failure.* == null) {
        deleteFileIfPresent(temporary_path) catch {};
    };

    {
        var file = try std.fs.createFileAbsolute(temporary_path, .{ .truncate = true });
        temporary_created = true;
        defer file.close();
        try file.writeAll(bytes);
        try file.sync();
    }

    const failure = (try replaceFileAtomic(absolute_path, temporary_path)) orelse {
        temporary_created = false;
        return .atomic;
    };
    atomic_failure.* = failure;
    std.log.warn(
        "win32 recovery atomic replace failed replace_win32_error={d} move_win32_error={d}; falling back to in-place write",
        .{ failure.replace_error, failure.move_error },
    );
    try writeFileInPlace(absolute_path, bytes);
    try deleteFileIfPresent(temporary_path);
    temporary_created = false;
    return .{ .in_place = failure };
}

pub fn writeFileInPlace(absolute_path: []const u8, bytes: []const u8) !void {
    var file = try std.fs.createFileAbsolute(absolute_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

pub fn readFileBoundedAlloc(alloc: Allocator, absolute_path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(absolute_path, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.size > max_bytes) return error.FileTooBig;
    return try file.readToEndAlloc(alloc, max_bytes);
}

fn replaceFileAtomic(absolute_path: []const u8, temporary_path: []const u8) !?AtomicReplaceFailure {
    if (@import("builtin").os.tag == .windows) return replaceFileAtomicWindows(absolute_path, temporary_path);
    try std.fs.renameAbsolute(temporary_path, absolute_path);
    return null;
}

fn replaceFileAtomicWindows(absolute_path: []const u8, temporary_path: []const u8) !?AtomicReplaceFailure {
    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, absolute_path);
    defer std.heap.page_allocator.free(target_w);
    const temporary_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, temporary_path);
    defer std.heap.page_allocator.free(temporary_w);

    if (sys.ReplaceFileW(target_w.ptr, temporary_w.ptr, null, 0, null, null) != 0) return null;
    const replace_error: u32 = @intFromEnum(std.os.windows.kernel32.GetLastError());
    if (sys.MoveFileExW(temporary_w.ptr, target_w.ptr, MOVEFILE_REPLACE_EXISTING) != 0) return null;
    const move_error: u32 = @intFromEnum(std.os.windows.kernel32.GetLastError());
    return .{
        .replace_error = replace_error,
        .move_error = move_error,
    };
}

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;
const ERROR_SHARING_VIOLATION: u32 = 32;
const MOVEFILE_REPLACE_EXISTING: u32 = 0x00000001;
test "win32 session persistence load distinguishes missing corrupt oversized and transient reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "missing.json" });
    defer std.testing.allocator.free(missing_path);
    var missing = loadAlloc(std.testing.allocator, missing_path, default_max_state_bytes);
    defer missing.deinit();
    try std.testing.expectEqual(std.meta.Tag(LoadResult).missing, std.meta.activeTag(missing));

    {
        var file = try tmp.dir.createFile("corrupt.json", .{});
        defer file.close();
        try file.writeAll("{not json");
    }
    const corrupt_path = try tmp.dir.realpathAlloc(std.testing.allocator, "corrupt.json");
    defer std.testing.allocator.free(corrupt_path);
    var corrupt = loadAlloc(std.testing.allocator, corrupt_path, default_max_state_bytes);
    defer corrupt.deinit();
    try std.testing.expectEqual(std.meta.Tag(LoadResult).corrupt, std.meta.activeTag(corrupt));
    const quarantine_path = try quarantineCorruptFileAlloc(std.testing.allocator, corrupt_path);
    defer std.testing.allocator.free(quarantine_path);
    try std.testing.expect(std.mem.endsWith(u8, quarantine_path, ".corrupt"));

    {
        var file = try tmp.dir.createFile("oversized.json", .{});
        defer file.close();
        try file.writeAll("12345");
    }
    const oversized_path = try tmp.dir.realpathAlloc(std.testing.allocator, "oversized.json");
    defer std.testing.allocator.free(oversized_path);
    var oversized = loadAlloc(std.testing.allocator, oversized_path, 4);
    defer oversized.deinit();
    try std.testing.expectEqual(std.meta.Tag(LoadResult).oversized, std.meta.activeTag(oversized));
    var still_present = try std.fs.openFileAbsolute(oversized_path, .{});
    still_present.close();

    var transient = loadAlloc(std.testing.allocator, root_path, default_max_state_bytes);
    defer transient.deinit();
    try std.testing.expectEqual(std.meta.Tag(LoadResult).transient, std.meta.activeTag(transient));
}

test "win32 session persistence atomic write replaces existing file and delete is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile("session-state.json", .{});
        defer file.close();
        try file.writeAll("old");
    }
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "session-state.json");
    defer std.testing.allocator.free(path);
    const temporary = try std.mem.concat(std.testing.allocator, u8, &.{ path, ".tmp" });
    defer std.testing.allocator.free(temporary);
    try writeFileAtomic(path, temporary, "new");
    const contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 16);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("new", contents);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(temporary, .{}));
    try deleteFileIfPresent(path);
    try deleteFileIfPresent(path);
}

test "win32 recovery persistence falls back in place when delete sharing blocks replace" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile("startup-attempts.json", .{});
        defer file.close();
        try file.writeAll("old");
    }
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "startup-attempts.json");
    defer std.testing.allocator.free(path);
    const temporary = try std.mem.concat(std.testing.allocator, u8, &.{ path, ".tmp" });
    defer std.testing.allocator.free(temporary);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_w);

    const held = std.os.windows.kernel32.CreateFileW(
        path_w.ptr,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (held == std.os.windows.INVALID_HANDLE_VALUE) return error.TestUnexpectedResult;
    defer _ = std.os.windows.CloseHandle(held);

    var atomic_failure: ?AtomicReplaceFailure = null;
    const disposition = try writeFileAtomicOrInPlace(path, temporary, "new", &atomic_failure);
    switch (disposition) {
        .atomic => return error.TestExpectedFallback,
        .in_place => |failure| {
            try std.testing.expectEqual(@as(u32, ERROR_SHARING_VIOLATION), failure.replace_error);
            try std.testing.expectEqual(@as(u32, 5), failure.move_error);
        },
    }
    const contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 16);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("new", contents);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(temporary, .{}));
}

test "win32 recovery persistence retains temp evidence when fallback also fails" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("startup-attempts.json");
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "startup-attempts.json");
    defer std.testing.allocator.free(target);
    const temporary = try std.mem.concat(std.testing.allocator, u8, &.{ target, ".tmp" });
    defer std.testing.allocator.free(temporary);

    var atomic_failure: ?AtomicReplaceFailure = null;
    if (writeFileAtomicOrInPlace(target, temporary, "diagnosis", &atomic_failure)) |_| {
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expect(atomic_failure != null);
    const contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, temporary, 32);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("diagnosis", contents);
}

test "win32 session persistence quarantine preserves existing collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile("session-state.json", .{});
        defer file.close();
        try file.writeAll("new corrupt state");
    }
    {
        var file = try tmp.dir.createFile("session-state.json.corrupt", .{});
        defer file.close();
        try file.writeAll("previous corrupt state");
    }
    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "session-state.json");
    defer std.testing.allocator.free(source);
    const destination = try quarantineCorruptFileAlloc(std.testing.allocator, source);
    defer std.testing.allocator.free(destination);
    try std.testing.expect(std.mem.endsWith(u8, destination, ".corrupt.1"));
    const previous = try tmp.dir.readFileAlloc(std.testing.allocator, "session-state.json.corrupt", 64);
    defer std.testing.allocator.free(previous);
    try std.testing.expectEqualStrings("previous corrupt state", previous);
}

test "win32 session persistence atomic write removes temp after replace failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("target");
    const target = try tmp.dir.realpathAlloc(std.testing.allocator, "target");
    defer std.testing.allocator.free(target);
    const temporary = try std.mem.concat(std.testing.allocator, u8, &.{ target, ".tmp" });
    defer std.testing.allocator.free(temporary);
    if (writeFileAtomic(target, temporary, "state")) {
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(temporary, .{}));
}

test "win32 session persistence OOM load is transient and leaves source present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile("session-state.json", .{});
        defer file.close();
        try file.writeAll("{\"schema_version\":1,\"windows\":[]}");
    }
    const source = try tmp.dir.realpathAlloc(std.testing.allocator, "session-state.json");
    defer std.testing.allocator.free(source);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var result = loadAlloc(failing.allocator(), source, default_max_state_bytes);
    defer result.deinit();
    try std.testing.expectEqual(std.meta.Tag(LoadResult).transient, std.meta.activeTag(result));
    var file = try std.fs.openFileAbsolute(source, .{});
    file.close();
}

test "win32 session persistence schema round-trips multi-window selected indices" {
    const nodes = [_]schema.Node{.{ .pane = .{ .cwd = "C:\\src\\noctty" } }};
    const first_tabs = [_]schema.Tab{
        .{ .selected_leaf = 0, .layout = .{ .root = 0, .nodes = &nodes } },
        .{ .selected_leaf = 0, .layout = .{ .root = 0, .nodes = &nodes } },
    };
    const second_tabs = [_]schema.Tab{.{ .selected_leaf = 0, .layout = .{ .root = 0, .nodes = &nodes } }};
    const windows = [_]schema.Window{
        .{ .selected_tab = 1, .tabs = &first_tabs },
        .{ .selected_tab = 0, .tabs = &second_tabs },
    };
    const encoded = try schema.encodeAlloc(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(encoded);
    var parsed = try schema.parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.windows.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.windows[0].selected_tab);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.windows[1].selected_tab);
}

test "win32 session persistence named layout load owns pane strings after the read buffer is freed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Deliberately escape-free values: `std.json` borrows those directly from
    // the read buffer that `loadAlloc` frees before it returns.
    const raw =
        \\{"schema_version":1,"windows":[{"selected_tab":0,"tabs":[{"selected_leaf":0,"layout":{"root":0,"nodes":[{"pane":{"cwd":"C:/src/noctty","profile":"pwsh.exe","title_override":"Build","tab_title_override":"Project"}}]}}]}]}
    ;
    {
        var file = try tmp.dir.createFile("layout.json", .{});
        defer file.close();
        try file.writeAll(raw);
    }
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "layout.json");
    defer std.testing.allocator.free(path);

    var result = loadAlloc(std.testing.allocator, path, default_max_state_bytes);
    defer result.deinit();
    const parsed = switch (result) {
        .loaded => |value| value.value,
        else => return error.TestExpectedEqual,
    };

    // Recycle the freed read buffer. A borrowed string would now observe this
    // scratch fill instead of its persisted value.
    const scratch = try std.testing.allocator.alloc(u8, raw.len);
    defer std.testing.allocator.free(scratch);
    @memset(scratch, 'Z');

    const pane = parsed.windows[0].tabs[0].layout.nodes[0].pane;
    try std.testing.expectEqualStrings("C:/src/noctty", pane.cwd.?);
    try std.testing.expectEqualStrings("pwsh.exe", pane.profile.?);
    try std.testing.expectEqualStrings("Build", pane.title_override.?);
    try std.testing.expectEqualStrings("Project", pane.tab_title_override.?);
}
