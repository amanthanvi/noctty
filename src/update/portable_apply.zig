const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const StagedKind = enum {
    installer,
    portable,
};

pub const Phase = enum {
    pending,
    swapped,
    confirmed,
    rollback,
};

pub const Event = union(enum) {
    next_launch,
    backup_completed,
    startup: struct {
        running_version: []const u8,
        target_version: []const u8,
        confirmation_token_matches: bool,
    },
    child_failed,
    interrupted,
    rollback_completed,
};

pub const Decision = enum {
    swap,
    clear_pending_and_continue,
    record_swapped_before_replace,
    continue_for_confirmation,
    confirm,
    rollback,
    clear_and_relaunch_old,
    cleanup,
};

/// Pure portable updater transition logic. The persisted staged kind is
/// checked before the phase so an installer stage can never be interpreted as
/// a portable transaction based on its path or extension.
pub fn decide(kind: ?StagedKind, phase: Phase, event: Event) !Decision {
    if (kind != .portable) return error.StagedKindMismatch;

    return switch (phase) {
        .pending => switch (event) {
            .next_launch => .swap,
            .backup_completed => .record_swapped_before_replace,
            .interrupted, .child_failed => .clear_pending_and_continue,
            else => error.InvalidPortableApplyTransition,
        },
        .swapped => switch (event) {
            .startup => |startup| if (startup.confirmation_token_matches and
                std.mem.eql(u8, startup.running_version, startup.target_version))
                .continue_for_confirmation
            else
                .rollback,
            .child_failed, .interrupted => .rollback,
            else => error.InvalidPortableApplyTransition,
        },
        .confirmed => switch (event) {
            .next_launch, .interrupted => .cleanup,
            .child_failed => .rollback,
            else => error.InvalidPortableApplyTransition,
        },
        .rollback => switch (event) {
            .next_launch, .interrupted, .child_failed => .rollback,
            .rollback_completed => .clear_and_relaunch_old,
            else => error.InvalidPortableApplyTransition,
        },
    };
}

pub fn confirmationDecision(
    kind: ?StagedKind,
    phase: Phase,
    running_version: []const u8,
    target_version: []const u8,
    confirmation_token_matches: bool,
) !Decision {
    const startup = try decide(kind, phase, .{ .startup = .{
        .running_version = running_version,
        .target_version = target_version,
        .confirmation_token_matches = confirmation_token_matches,
    } });
    return if (startup == .continue_for_confirmation) .confirm else startup;
}

/// ZIP entry policy applied to every central-directory entry before extraction.
/// The release ZIP uses forward slashes and exactly one `noctty/` root.
pub fn isSafeZipEntryPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (!std.mem.eql(u8, path, "noctty/") and
        !std.mem.startsWith(u8, path, "noctty/")) return false;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    }
    return true;
}

pub const managed_entries = [_][]const u8{
    "noctty.com",
    "ghostty-vt.dll",
    "LICENSE",
    "config-template.ghostty",
    "README.md",
    "noctty.ico",
    "share",
    // Replace the executable last so an interrupted transaction always leaves
    // a launchable old or new preflight entrypoint.
    "noctty.exe",
};

const backup_complete_name = ".complete";
const max_backup_manifest_bytes = 2 * 1024 * 1024;

pub fn prepareBackup(
    alloc: Allocator,
    install_root: []const u8,
    backup_root: []const u8,
) !void {
    // A complete backup belongs to the current transaction. In particular,
    // never replace it after an interrupted, partially completed swap.
    if (backupIsComplete(alloc, backup_root)) return;

    removePathIfExists(backup_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.cwd().makePath(backup_root);

    for (managed_entries) |name| {
        const source = try std.fs.path.join(alloc, &.{ install_root, name });
        defer alloc.free(source);
        const destination = try std.fs.path.join(alloc, &.{ backup_root, name });
        defer alloc.free(destination);
        copyPath(alloc, source, destination) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    try syncDirectory(alloc, backup_root);
    try commitBackupManifest(alloc, backup_root);
}

pub fn backupIsComplete(alloc: Allocator, backup_root: []const u8) bool {
    if (pathIsWindowsReparsePoint(backup_root)) return false;
    verifyBackupManifest(alloc, backup_root, null) catch return false;
    return true;
}

pub fn swapPayload(
    alloc: Allocator,
    install_root: []const u8,
    payload_root: []const u8,
    backup_root: []const u8,
    displaced_root: []const u8,
) !void {
    if (!backupIsComplete(alloc, backup_root)) return error.IncompletePortableUpdateBackup;
    removePathIfExists(displaced_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.cwd().makePath(displaced_root);

    for (managed_entries) |name| {
        const source = try std.fs.path.join(alloc, &.{ payload_root, name });
        defer alloc.free(source);
        std.fs.accessAbsolute(source, .{}) catch return error.IncompletePortablePayload;

        const target = try std.fs.path.join(alloc, &.{ install_root, name });
        defer alloc.free(target);
        const displaced = try std.fs.path.join(alloc, &.{ displaced_root, name });
        defer alloc.free(displaced);
        try replaceManagedPath(alloc, source, target, displaced);
    }
}

pub fn rollback(
    alloc: Allocator,
    install_root: []const u8,
    backup_root: []const u8,
) !void {
    if (!backupIsComplete(alloc, backup_root)) return error.IncompletePortableUpdateBackup;
    try verifyBackupManifest(alloc, backup_root, install_root);
}

pub fn cleanupBackup(backup_root: []const u8) !void {
    return cleanupUpdatePath(backup_root);
}

pub fn cleanupUpdatePath(path: []const u8) !void {
    removePathIfExists(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn replaceManagedPath(
    alloc: Allocator,
    source: []const u8,
    target: []const u8,
    displaced: []const u8,
) !void {
    if (try pathKind(source) != .directory) return replaceFileAtomic(alloc, source, target);

    removePathIfExists(displaced) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.fs.renameAbsolute(target, displaced) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.fs.renameAbsolute(source, target) catch |err| {
        std.fs.renameAbsolute(displaced, target) catch {};
        return err;
    };
}

fn replaceFileAtomic(alloc: Allocator, source: []const u8, target: []const u8) !void {
    if (builtin.os.tag != .windows) {
        std.fs.deleteFileAbsolute(target) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return std.fs.renameAbsolute(source, target);
    }

    const source_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, source);
    defer alloc.free(source_w);
    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, target);
    defer alloc.free(target_w);
    if (ReplaceFileW(target_w.ptr, source_w.ptr, null, 0, null, null) != 0) return;
    if (MoveFileExW(source_w.ptr, target_w.ptr, movefile_replace_existing) != 0) return;
    return error.PortableUpdateReplaceFailed;
}

fn copyPath(alloc: Allocator, source: []const u8, destination: []const u8) !void {
    if (pathIsWindowsReparsePoint(source)) return error.InvalidPortableUpdatePath;
    if (try pathKind(source) != .directory) {
        if (std.fs.path.dirname(destination)) |parent| try std.fs.cwd().makePath(parent);
        try std.fs.copyFileAbsolute(source, destination, .{});
        const copied = try std.fs.openFileAbsolute(destination, .{ .mode = .read_write });
        defer copied.close();
        return copied.sync();
    }

    try std.fs.cwd().makePath(destination);
    var source_dir = try std.fs.openDirAbsolute(source, .{ .iterate = true });
    defer source_dir.close();
    var iter = source_dir.iterate();
    while (try iter.next()) |entry| {
        const child_source = try std.fs.path.join(alloc, &.{ source, entry.name });
        defer alloc.free(child_source);
        const child_destination = try std.fs.path.join(alloc, &.{ destination, entry.name });
        defer alloc.free(child_destination);
        try copyPath(alloc, child_source, child_destination);
    }
    try syncDirectory(alloc, destination);
}

fn syncDirectory(alloc: Allocator, path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        var dir = try std.fs.openDirAbsolute(path, .{});
        defer dir.close();
        return std.posix.fsync(dir.fd);
    }
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const handle = std.os.windows.kernel32.CreateFileW(
        path_w.ptr,
        std.os.windows.GENERIC_WRITE,
        std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE | std.os.windows.FILE_SHARE_DELETE,
        null,
        std.os.windows.OPEN_EXISTING,
        std.os.windows.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
        return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
    }
    defer std.os.windows.CloseHandle(handle);
    if (std.os.windows.kernel32.FlushFileBuffers(handle) == 0) {
        return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
    }
}

fn commitBackupManifest(alloc: Allocator, backup_root: []const u8) !void {
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(alloc);
    var backup_dir = try std.fs.openDirAbsolute(backup_root, .{ .iterate = true });
    defer backup_dir.close();
    var walker = try backup_dir.walk(alloc);
    defer walker.deinit();
    var file_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.IncompletePortableUpdateBackup;
        const relative = try portableRelativePathAlloc(alloc, entry.path);
        defer alloc.free(relative);
        if (!isManagedRelativePath(relative)) return error.IncompletePortableUpdateBackup;
        const path = try std.fs.path.join(alloc, &.{ backup_root, entry.path });
        defer alloc.free(path);
        const digest = try sha256File(path);
        try contents.writer(alloc).print("{s} *{s}\n", .{
            std.fmt.bytesToHex(digest, .lower),
            relative,
        });
        file_count += 1;
    }
    if (file_count == 0) return error.IncompletePortableUpdateBackup;

    const marker_path = try std.fs.path.join(alloc, &.{ backup_root, backup_complete_name });
    defer alloc.free(marker_path);
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{marker_path});
    defer alloc.free(temp_path);
    const marker = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
    defer marker.close();
    try marker.writeAll(contents.items);
    try marker.sync();
    if (builtin.os.tag == .windows) {
        const source_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, temp_path);
        defer alloc.free(source_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, marker_path);
        defer alloc.free(target_w);
        if (MoveFileExW(source_w.ptr, target_w.ptr, movefile_replace_existing | movefile_write_through) == 0) {
            return error.PortableUpdateReplaceFailed;
        }
    } else {
        try std.fs.renameAbsolute(temp_path, marker_path);
    }
}

fn verifyBackupManifest(
    alloc: Allocator,
    backup_root: []const u8,
    restore_root: ?[]const u8,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ backup_root, backup_complete_name });
    defer alloc.free(marker_path);
    const contents = try std.fs.cwd().readFileAlloc(alloc, marker_path, max_backup_manifest_bytes);
    defer alloc.free(contents);

    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| alloc.free(key.*);
        seen.deinit(alloc);
    }
    var file_count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line.len <= std.crypto.hash.sha2.Sha256.digest_length * 2) {
            return error.IncompletePortableUpdateBackup;
        }
        const hex = line[0 .. std.crypto.hash.sha2.Sha256.digest_length * 2];
        const name_raw = std.mem.trimLeft(
            u8,
            line[std.crypto.hash.sha2.Sha256.digest_length * 2 ..],
            " \t",
        );
        if (name_raw.len < 2 or name_raw[0] != '*') return error.IncompletePortableUpdateBackup;
        const name = name_raw[1..];
        if (!isManagedRelativePath(name)) return error.IncompletePortableUpdateBackup;
        const key = try std.ascii.allocLowerString(alloc, name);
        const gop = try seen.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            return error.IncompletePortableUpdateBackup;
        }
        const expected = try parseSha256Hex(hex);
        const backup_path = try joinPortableRelativePath(alloc, backup_root, name);
        defer alloc.free(backup_path);
        const actual = sha256File(backup_path) catch return error.IncompletePortableUpdateBackup;
        if (!std.mem.eql(u8, &expected, &actual)) return error.IncompletePortableUpdateBackup;

        if (restore_root) |root| {
            const target = try joinPortableRelativePath(alloc, root, name);
            defer alloc.free(target);
            const restore_temp = try std.fmt.allocPrint(alloc, "{s}.restore", .{target});
            defer alloc.free(restore_temp);
            removePathIfExists(restore_temp) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try copyPath(alloc, backup_path, restore_temp);
            try replaceFileAtomic(alloc, restore_temp, target);
            const restored = try sha256File(target);
            if (!std.mem.eql(u8, &expected, &restored)) return error.IncompletePortableUpdateRollback;
        }
        file_count += 1;
    }
    if (file_count == 0) return error.IncompletePortableUpdateBackup;
}

fn portableRelativePathAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    const result = try alloc.dupe(u8, path);
    for (result) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return result;
}

fn joinPortableRelativePath(alloc: Allocator, root: []const u8, relative: []const u8) ![]u8 {
    const native = try alloc.dupe(u8, relative);
    defer alloc.free(native);
    for (native) |*byte| {
        if (byte.* == '/') byte.* = std.fs.path.sep;
    }
    return std.fs.path.join(alloc, &.{ root, native });
}

pub fn isManagedRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, ':') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (managed_entries) |entry| {
        if (std.mem.eql(u8, path, entry)) return true;
        if (std.mem.eql(u8, entry, "share") and std.mem.startsWith(u8, path, "share/")) return true;
    }
    return false;
}

fn sha256File(path: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const len = try file.read(&buf);
        if (len == 0) break;
        hasher.update(buf[0..len]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn parseSha256Hex(hex: []const u8) ![std.crypto.hash.sha2.Sha256.digest_length]u8 {
    if (hex.len != std.crypto.hash.sha2.Sha256.digest_length * 2) return error.InvalidChecksum;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    for (&digest, 0..) |*byte, i| {
        byte.* = (try hexNibble(hex[i * 2]) << 4) | try hexNibble(hex[i * 2 + 1]);
    }
    return digest;
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidChecksum,
    };
}

fn removePathIfExists(path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(path_w);
        const attributes = std.os.windows.kernel32.GetFileAttributesW(path_w.ptr);
        if (attributes != std.os.windows.INVALID_FILE_ATTRIBUTES and
            attributes & std.os.windows.FILE_ATTRIBUTE_REPARSE_POINT != 0)
        {
            if (attributes & file_attribute_directory != 0) {
                return std.fs.deleteDirAbsolute(path);
            }
            return std.fs.deleteFileAbsolute(path);
        }
    }
    if (try pathKind(path) == .directory) return std.fs.deleteTreeAbsolute(path);
    return std.fs.deleteFileAbsolute(path);
}

fn pathKind(path: []const u8) !std.fs.File.Kind {
    if (builtin.os.tag != .windows) return (try std.fs.cwd().statFile(path)).kind;
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(path_w);
    const attributes = std.os.windows.kernel32.GetFileAttributesW(path_w.ptr);
    if (attributes == std.os.windows.INVALID_FILE_ATTRIBUTES) {
        const err = std.os.windows.kernel32.GetLastError();
        return switch (err) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            else => std.os.windows.unexpectedError(err),
        };
    }
    return if (attributes & file_attribute_directory != 0) .directory else .file;
}

fn pathIsWindowsReparsePoint(path: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path) catch return false;
    defer std.heap.page_allocator.free(path_w);
    const attributes = std.os.windows.kernel32.GetFileAttributesW(path_w.ptr);
    return attributes != std.os.windows.INVALID_FILE_ATTRIBUTES and
        attributes & std.os.windows.FILE_ATTRIBUTE_REPARSE_POINT != 0;
}

const movefile_replace_existing: u32 = 0x1;
const movefile_write_through: u32 = 0x8;
const file_attribute_directory: u32 = 0x10;
extern "kernel32" fn ReplaceFileW(
    replaced_file_name: [*:0]const u16,
    replacement_file_name: [*:0]const u16,
    backup_file_name: ?[*:0]const u16,
    replace_flags: u32,
    exclude: ?*anyopaque,
    reserved: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExW(
    existing_file_name: [*:0]const u16,
    new_file_name: [*:0]const u16,
    flags: u32,
) callconv(.winapi) i32;

test "portable update decision pending swapped confirm rollback interrupted" {
    const testing = std.testing;

    try testing.expectEqual(Decision.swap, try decide(.portable, .pending, .next_launch));
    try testing.expectEqual(Decision.record_swapped_before_replace, try decide(.portable, .pending, .backup_completed));
    try testing.expectEqual(Decision.clear_pending_and_continue, try decide(.portable, .pending, .interrupted));
    try testing.expectEqual(Decision.clear_pending_and_continue, try decide(.portable, .pending, .child_failed));
    try testing.expectEqual(Decision.rollback, try decide(.portable, .swapped, .child_failed));
    try testing.expectEqual(Decision.cleanup, try decide(.portable, .confirmed, .interrupted));
    try testing.expectEqual(Decision.rollback, try decide(.portable, .confirmed, .child_failed));
    try testing.expectEqual(Decision.rollback, try decide(.portable, .rollback, .interrupted));
    try testing.expectEqual(Decision.clear_and_relaunch_old, try decide(.portable, .rollback, .rollback_completed));

    try testing.expectEqual(Decision.confirm, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.200",
        "1.3.200",
        true,
    ));
    try testing.expectEqual(Decision.rollback, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.199",
        "1.3.200",
        true,
    ));
    try testing.expectEqual(Decision.rollback, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.200",
        "1.3.200",
        false,
    ));
}

test "portable update rejects staged kind confusion" {
    try std.testing.expectError(
        error.StagedKindMismatch,
        decide(.installer, .pending, .next_launch),
    );
    try std.testing.expectError(
        error.StagedKindMismatch,
        decide(null, .pending, .next_launch),
    );
}

test "portable update preserves complete backup across interrupted retry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install/share");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/resource theme.txt", .data = "old-resource" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);

    try prepareBackup(alloc, install_root, backup_root);
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "mixed" });
    try prepareBackup(alloc, install_root, backup_root);

    const backed_up = try tmp.dir.readFileAlloc(alloc, "backup/noctty.com", 16);
    defer alloc.free(backed_up);
    try std.testing.expectEqualStrings("old", backed_up);
}

test "portable rollback restores manifest files without deleting user data" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install/share");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/resource theme.txt", .data = "old-resource" });
    try tmp.dir.writeFile(.{ .sub_path = "install/user-data.txt", .data = "keep" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);
    try prepareBackup(alloc, install_root, backup_root);
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "new" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/resource theme.txt", .data = "new-resource" });
    try tmp.dir.writeFile(.{ .sub_path = "install/LICENSE", .data = "new-only" });

    try rollback(alloc, install_root, backup_root);
    const restored = try tmp.dir.readFileAlloc(alloc, "install/noctty.com", 16);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("old", restored);
    const restored_resource = try tmp.dir.readFileAlloc(alloc, "install/share/resource theme.txt", 32);
    defer alloc.free(restored_resource);
    try std.testing.expectEqualStrings("old-resource", restored_resource);
    const sentinel = try tmp.dir.readFileAlloc(alloc, "install/user-data.txt", 16);
    defer alloc.free(sentinel);
    try std.testing.expectEqualStrings("keep", sentinel);
    const absent_backup = try tmp.dir.readFileAlloc(alloc, "install/LICENSE", 16);
    defer alloc.free(absent_backup);
    try std.testing.expectEqualStrings("new-only", absent_backup);
}

test "portable update rejects unsafe ZIP entry paths" {
    const testing = std.testing;
    try testing.expect(isSafeZipEntryPath("noctty/"));
    try testing.expect(isSafeZipEntryPath("noctty/share/ghostty/themes/a"));
    try testing.expect(!isSafeZipEntryPath("/noctty/noctty.exe"));
    try testing.expect(!isSafeZipEntryPath("C:/noctty/noctty.exe"));
    try testing.expect(!isSafeZipEntryPath("noctty/../../outside"));
    try testing.expect(!isSafeZipEntryPath("noctty\\noctty.exe"));
    try testing.expect(!isSafeZipEntryPath("other/noctty.exe"));
}
