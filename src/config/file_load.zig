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

pub const FileState = enum { missing, empty, content };

/// What a candidate config file holds, as a caller with its own rules for
/// opening files sees it; null when it cannot tell.
pub const FileProbe = *const fn (alloc: Allocator, path: []const u8) ?FileState;

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
    return (try preferredXdgPathProbed(alloc, &fileStateKnown)).?;
}

fn fileStateKnown(_: Allocator, path: []const u8) ?FileState {
    return fileState(path);
}

/// `preferredXdgPath`, each candidate looked at through `probe`. Null when
/// the probe cannot tell what a candidate it needs holds, so the file cannot
/// be named. Returned value must be freed by the caller.
pub fn preferredXdgPathProbed(alloc: Allocator, probe: FileProbe) !?[]const u8 {
    const xdg_path = try defaultXdgPath(alloc);
    errdefer alloc.free(xdg_path);
    const legacy_path = try legacyGhosttyDefaultXdgPath(alloc);
    errdefer alloc.free(legacy_path);

    const xdg_state = probe(alloc, xdg_path) orelse {
        alloc.free(xdg_path);
        alloc.free(legacy_path);
        return null;
    };
    const legacy_state = probe(alloc, legacy_path) orelse {
        alloc.free(xdg_path);
        alloc.free(legacy_path);
        return null;
    };

    for ([_]FileState{ .content, .empty }) |wanted| {
        if (xdg_state == wanted) {
            alloc.free(legacy_path);
            return xdg_path;
        }
        if (legacy_state == wanted) {
            alloc.free(xdg_path);
            return legacy_path;
        }
    }

    const fork_path = try legacyForkXdgPath(alloc);
    const fork_state = probe(alloc, fork_path);
    if (fork_state == null or fork_state.? != .missing) {
        alloc.free(xdg_path);
        alloc.free(legacy_path);
        if (fork_state == null) {
            alloc.free(fork_path);
            return null;
        }
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
