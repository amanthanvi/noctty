//! Creates a temporary directory at runtime that can be safely used to
//! store temporary data and is destroyed on deinit.
const TempDir = @This();

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;
const Dir = std.fs.Dir;
const allocTmpDir = @import("file.zig").allocTmpDir;
const freeTmpDir = @import("file.zig").freeTmpDir;

const log = std.log.scoped(.tempdir);

/// Dir is the directory handle
dir: Dir,

/// Parent directory
parent: Dir,

/// Name buffer that name points into. Generally do not use. To get the
/// name call the name() function.
name_buf: [TMP_PATH_LEN:0]u8,

/// Create the temporary directory.
pub fn init() !TempDir {
    // Note: the tmp_path_buf sentinel is important because it ensures
    // we actually always have TMP_PATH_LEN+1 bytes of available space. We
    // need that so we can set the sentinel in the case we use all the
    // possible length.
    var tmp_path_buf: [TMP_PATH_LEN:0]u8 = undefined;
    var rand_buf: [RANDOM_BYTES]u8 = undefined;

    // The parent is always a handle of our own, so `close` can close it.
    var dir = dir: {
        const cwd = std.fs.cwd();
        const tmp_dir = try allocTmpDir(std.heap.page_allocator);
        defer freeTmpDir(std.heap.page_allocator, tmp_dir);
        break :dir try cwd.openDir(tmp_dir, .{});
    };
    errdefer dir.close();

    // We now loop forever until we can find a directory that we can create.
    while (true) {
        std.crypto.random.bytes(rand_buf[0..]);
        const tmp_path = b64_encoder.encode(&tmp_path_buf, &rand_buf);
        tmp_path_buf[tmp_path.len] = 0;

        dir.makeDir(tmp_path) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        return TempDir{
            .dir = try dir.openDir(tmp_path, .{}),
            .parent = dir,
            .name_buf = tmp_path_buf,
        };
    }
}

/// Name returns the name of the directory. This is just the basename
/// and is not the full absolute path.
pub fn name(self: *TempDir) []const u8 {
    return std.mem.sliceTo(&self.name_buf, 0);
}

/// Finish with the temporary directory. This deletes all contents in the
/// directory.
pub fn deinit(self: *TempDir) void {
    self.close(.delete);
}

pub const CloseMode = enum { delete, retain };

/// Close the directory handles, optionally retaining the temporary directory
/// and its contents on disk.
pub fn close(self: *TempDir, mode: CloseMode) void {
    self.dir.close();
    switch (mode) {
        .delete => self.parent.deleteTree(self.name()) catch |err|
            log.err("error deleting temp dir err={}", .{err}),
        .retain => {},
    }
    self.parent.close();
}

// The amount of random bytes to get to determine our filename.
const RANDOM_BYTES = 16;
const TMP_PATH_LEN = b64_encoder.calcSize(RANDOM_BYTES);

// Base64 encoder, replacing the standard `+/` with `-_` so that it can
// be used in a file name on any filesystem.
const b64_encoder = std.base64.Base64Encoder.init(b64_alphabet, null);
const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".*;

test {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = undefined;
    var handles: Handles = undefined;
    {
        var td = try init();
        errdefer td.deinit();

        const nameval = td.name();
        try testing.expect(nameval.len > 0);

        // Can open a new handle to it proves it exists.
        var dir = try td.parent.openDir(nameval, .{});
        dir.close();

        path = try td.parent.realpath(nameval, &path_buf);
        handles = try .capture(&td);

        // Should be deleted after we deinit.
        td.deinit();
    }

    try handles.expectClosed();
    try testing.expectError(error.FileNotFound, std.fs.openDirAbsolute(path, .{}));
}

test "close retains the temporary directory" {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = undefined;
    var handles: Handles = undefined;
    {
        var td = try init();
        errdefer td.deinit();

        path = try td.parent.realpath(td.name(), &path_buf);
        handles = try .capture(&td);

        td.close(.retain);
    }
    defer std.fs.deleteDirAbsolute(path) catch {};

    try handles.expectClosed();
    var dir = try std.fs.openDirAbsolute(path, .{});
    dir.close();
}

/// A TempDir's two handles and the directories they named.
const Handles = struct {
    values: [2]Dir.Handle,
    ids: [2]?FileId,

    fn capture(td: *const TempDir) !Handles {
        const values: [2]Dir.Handle = .{ td.dir.fd, td.parent.fd };
        var ids: [2]?FileId = undefined;
        for (values, &ids) |value, *id| {
            id.* = fileId(value);
            if (builtin.os.tag == .windows) try testing.expect(id.* != null);
        }
        return .{ .values = values, .ids = ids };
    }

    /// Fails if a handle still names the directory it named before it was
    /// closed. Any thread can be handed a closed handle value again at once,
    /// so a handle value that is open again proves nothing.
    fn expectClosed(self: Handles) !void {
        for (self.values, self.ids) |value, id| {
            const now = fileId(value) orelse continue;
            try testing.expect(!std.meta.eql(now, id.?));
        }
    }
};

const FileId = struct { volume: u32, index_high: u32, index_low: u32 };

/// The file `handle` refers to, or null if it is not an open file handle.
fn fileId(handle: Dir.Handle) ?FileId {
    switch (builtin.os.tag) {
        .windows => {
            var info: std.os.windows.BY_HANDLE_FILE_INFORMATION = undefined;
            if (GetFileInformationByHandle(handle, &info) == 0) return null;
            return .{
                .volume = info.dwVolumeSerialNumber,
                .index_high = info.nFileIndexHigh,
                .index_low = info.nFileIndexLow,
            };
        },
        else => return null,
    }
}

extern "kernel32" fn GetFileInformationByHandle(
    hFile: std.os.windows.HANDLE,
    lpFileInformation: *std.os.windows.BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) std.os.windows.BOOL;
