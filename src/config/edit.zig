const std = @import("std");
const Allocator = std.mem.Allocator;
const file_load = @import("file_load.zig");

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

    // Create config directory recursively.
    if (std.fs.path.dirname(config_path)) |config_dir| {
        try std.fs.cwd().makePath(config_dir);
    }

    // Try to create file and go on if it already exists
    _ = std.fs.createFileAbsolute(
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
