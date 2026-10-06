const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const xdg = @import("../os/xdg.zig");

const log = std.log.scoped(.config);

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    return try xdg.config(
        alloc,
        .{ .subdir = build_config.data_dir_name ++ "/config.ghostty" },
    );
}

/// Legacy Ghostty default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn legacyGhosttyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    return try xdg.config(
        alloc,
        .{ .subdir = "ghostty/config" },
    );
}

/// Pre-rename fork default path for the XDG home configuration file.
/// The fork shipped as "winghostty" before the Noctty rename, so
/// existing users still have their config under that directory.
/// Returned value must be freed by the caller.
pub fn legacyForkXdgPath(alloc: Allocator) ![]const u8 {
    return try xdg.config(
        alloc,
        .{ .subdir = "winghostty/config.ghostty" },
    );
}

const FileState = enum { missing, empty, content };

fn fileState(path: []const u8) FileState {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.BadPathName => return .missing,
        // Something is there that we cannot open; it still exists.
        else => return .content,
    };
    defer file.close();
    const stat = file.stat() catch return .content;
    return if (stat.size == 0) .empty else .content;
}

/// The per-user config file an edit has to land in: the one
/// `Config.loadDefaultFiles` will read back.
///
/// The loader reads `ghostty/config`, then `noctty/config.ghostty` over it,
/// and falls back to the pre-rename `winghostty/config.ghostty` only when
/// neither exists. It never reads `ghostty/config.ghostty`, so that file is
/// not a candidate. The highest-precedence file with content wins, so an edit
/// is not shadowed by another layer; an empty file is only chosen when
/// nothing has content, and the noctty path is the answer when nothing exists.
///
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    const xdg_path = try defaultXdgPath(alloc);
    errdefer alloc.free(xdg_path);
    const legacy_path = try legacyGhosttyDefaultXdgPath(alloc);
    errdefer alloc.free(legacy_path);

    const xdg_state = fileState(xdg_path);
    const legacy_state = fileState(legacy_path);

    if (xdg_state == .content) {
        alloc.free(legacy_path);
        return xdg_path;
    }
    if (legacy_state == .content) {
        alloc.free(xdg_path);
        return legacy_path;
    }
    if (xdg_state == .empty) {
        alloc.free(legacy_path);
        return xdg_path;
    }
    if (legacy_state == .empty) {
        alloc.free(xdg_path);
        return legacy_path;
    }

    const fork_path = try legacyForkXdgPath(alloc);
    if (fileState(fork_path) != .missing) {
        alloc.free(xdg_path);
        alloc.free(legacy_path);
        return fork_path;
    }
    alloc.free(fork_path);
    alloc.free(legacy_path);
    return xdg_path;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// In the Windows-only fork, this resolves to the per-user config location
/// backed by `LOCALAPPDATA` or the Windows known-folder fallback used by the
/// XDG helper.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    return try preferredXdgPath(alloc);
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(path: []const u8) OpenFileError!std.fs.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}
