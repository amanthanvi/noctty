const std = @import("std");
const Allocator = std.mem.Allocator;
const file_load = @import("file_load.zig");
const global = @import("../global.zig");

/// The path to the configuration that should be opened for editing, created
/// empty if it does not exist yet.
///
/// This is `file_load.preferredDefaultFilePath`, the same file the loader
/// reads back, so a save is never written somewhere a launch ignores.
///
/// The returned value is allocated using the provided allocator.
pub fn openPath(alloc_gpa: Allocator) ![]const u8 {
    const config_path = try file_load.preferredDefaultFilePath(alloc_gpa);
    errdefer alloc_gpa.free(config_path);

    const io = global.io();

    // Create config directory recursively. Zig 0.17's `createDirPath` does
    // not follow a link it finds on the way (0.15's `makePath` did), so an
    // existing directory, a link to one included, is opened first and
    // created only when it is missing (upstream's `openPath` does the same).
    if (std.fs.path.dirname(config_path)) |config_dir| check_dir: {
        const dir = std.Io.Dir.cwd().openDir(io, config_dir, .{ .follow_symlinks = true }) catch |err| switch (err) {
            error.FileNotFound => {
                try std.Io.Dir.cwd().createDirPath(io, config_dir);
                break :check_dir;
            },
            else => return err,
        };
        dir.close(io);
    }

    // Try to create file and go on if it already exists
    _ = std.Io.Dir.createFileAbsolute(
        io,
        config_path,
        .{ .exclusive = true },
    ) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    return config_path;
}
