const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global_state = &@import("../global.zig").state;
const internal_os = @import("../os/main.zig");
const cli_diags = @import("../cli/diagnostics.zig");

/// Location of possible themes. The order of this enum matters because it
/// defines the priority of theme search (from top to bottom).
pub const Location = enum {
    user, // XDG config dir
    resources, // Ghostty resources dir

    /// Returns the directory for the given theme based on this location type.
    ///
    /// This will return null with no error if the directory type doesn't exist
    /// or is invalid for any reason. For example, it is perfectly valid to
    /// install and run Ghostty without the resources directory.
    ///
    /// Due to the way allocations are handled, an Arena allocator (or another
    /// similar allocator implementation) should be used. It may not be safe to
    /// free the returned allocations.
    pub fn dir(
        self: Location,
        arena_alloc: Allocator,
    ) error{OutOfMemory}!?[]const u8 {
        return switch (self) {
            .user => user: {
                const subdir = std.fs.path.join(arena_alloc, &.{
                    "ghostty", "themes",
                }) catch return error.OutOfMemory;

                break :user internal_os.xdg.config(
                    arena_alloc,
                    .{ .subdir = subdir },
                ) catch |err| {
                    // We need to do some comptime tricks to get the right
                    // error set since some platforms don't support some
                    // error types.
                    const Error = @TypeOf(err) || switch (builtin.os.tag) {
                        .ios => error{BufferTooSmall},
                        else => error{},
                    };

                    switch (@as(Error, err)) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.BufferTooSmall => return error.OutOfMemory,

                        // Any other error we treat as the XDG directory not
                        // existing. Windows in particularly can return a LOT
                        // of errors here.
                        else => return null,
                    }
                };
            },

            .resources => try std.fs.path.join(arena_alloc, &.{
                global_state.resources_dir.app() orelse return null,
                "themes",
            }),
        };
    }
};

/// An iterator that returns all possible directories for finding themes in
/// order of priority.
pub const LocationIterator = struct {
    /// Due to the way allocations are handled, an Arena allocator (or another
    /// similar allocator implementation) should be used. It may not be safe to
    /// free the returned allocations.
    arena_alloc: Allocator,
    i: usize = 0,

    pub fn next(self: *LocationIterator) !?struct {
        location: Location,
        dir: []const u8,
    } {
        const max = @typeInfo(Location).@"enum".fields.len;
        while (self.i < max) {
            const location: Location = @enumFromInt(self.i);
            self.i += 1;
            if (try location.dir(self.arena_alloc)) |dir|
                return .{
                    .location = location,
                    .dir = dir,
                };
        }
        return null;
    }

    pub fn reset(self: *LocationIterator) void {
        self.i = 0;
    }
};

pub const Entry = struct {
    location: Location,
    path: []const u8,
    name: []const u8,

    pub fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name) == .lt;
    }
};

pub const Directory = struct {
    location: Location,
    dir: []const u8,
};

pub fn list(alloc: Allocator, arena_alloc: Allocator) ![]Entry {
    var dirs: std.ArrayList(Directory) = .empty;
    defer dirs.deinit(alloc);

    var it: LocationIterator = .{ .arena_alloc = arena_alloc };
    while (try it.next()) |loc| {
        try dirs.append(alloc, .{
            .location = loc.location,
            .dir = loc.dir,
        });
    }

    return try listFromDirectories(alloc, dirs.items);
}

/// Enumerate installed theme files with the same directory priority as
/// `open`: user themes first, bundled resources second. Duplicate names keep
/// the first location so user themes shadow bundled themes deterministically.
pub fn listFromDirectories(alloc: Allocator, dirs: []const Directory) ![]Entry {
    var themes: std.ArrayList(Entry) = .empty;
    errdefer {
        for (themes.items) |entry| {
            alloc.free(entry.path);
            alloc.free(entry.name);
        }
        themes.deinit(alloc);
    }

    for (dirs) |loc| {
        var dir = std.fs.cwd().openDir(loc.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => continue,
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            switch (entry.kind) {
                .file, .sym_link => {},
                else => continue,
            }
            if (std.mem.eql(u8, entry.name, ".DS_Store")) continue;
            if (containsThemeName(themes.items, entry.name)) continue;

            try themes.append(alloc, .{
                .location = loc.location,
                .path = try std.fs.path.join(alloc, &.{ loc.dir, entry.name }),
                .name = try alloc.dupe(u8, entry.name),
            });
        }
    }

    std.mem.sortUnstable(Entry, themes.items, {}, Entry.lessThan);
    return try themes.toOwnedSlice(alloc);
}

pub fn freeList(alloc: Allocator, themes: []Entry) void {
    for (themes) |entry| {
        alloc.free(entry.path);
        alloc.free(entry.name);
    }
    alloc.free(themes);
}

fn containsThemeName(themes: []const Entry, name: []const u8) bool {
    for (themes) |theme| {
        if (std.mem.eql(u8, theme.name, name)) return true;
    }
    return false;
}

/// Open the given named theme. If there are any errors then messages
/// will be appended to the given error list and null is returned. If
/// a non-null return value is returned, there are never any errors added.
///
/// One error that is not recoverable and may be returned is OOM. This is
/// always a critical error for configuration loading so it is returned.
///
/// Due to the way allocations are handled, an Arena allocator (or another
/// similar allocator implementation) should be used. It may not be safe to
/// free the returned allocations.
///
/// This will never return anything other than a handle to a regular file. If
/// the theme resolves to something other than a regular file a diagnostic entry
/// will be added to the list and null will be returned.
pub fn open(
    arena_alloc: Allocator,
    theme: []const u8,
    diags: *cli_diags.DiagnosticList,
) error{OutOfMemory}!?struct {
    path: []const u8,
    file: std.fs.File,
} {
    // Absolute themes are loaded a different path.
    if (std.fs.path.isAbsolute(theme)) {
        const file: std.fs.File = try openAbsolute(
            arena_alloc,
            theme,
            diags,
        ) orelse return null;
        const stat = file.stat() catch |err| {
            try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "not reading theme from \"{s}\": {}",
                    .{ theme, err },
                    0,
                ),
            });
            return null;
        };
        switch (stat.kind) {
            .file => {},
            else => {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "not reading theme from \"{s}\": it is a {s}",
                        .{ theme, @tagName(stat.kind) },
                        0,
                    ),
                });
                return null;
            },
        }
        return .{ .path = theme, .file = file };
    }

    const basename = std.fs.path.basename(theme);
    if (!std.mem.eql(u8, theme, basename)) {
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "theme \"{s}\" cannot include path separators unless it is an absolute path",
                .{theme},
                0,
            ),
        });
        return null;
    }

    // Iterate over the possible locations to try to find the
    // one that exists.
    var it: LocationIterator = .{ .arena_alloc = arena_alloc };
    const cwd = std.fs.cwd();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        if (cwd.openFile(path, .{})) |file| {
            const stat = file.stat() catch |err| {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "not reading theme from \"{s}\": {}",
                        .{ theme, err },
                        0,
                    ),
                });
                return null;
            };
            switch (stat.kind) {
                .file => {},
                else => {
                    try diags.append(arena_alloc, .{
                        .message = try std.fmt.allocPrintSentinel(
                            arena_alloc,
                            "not reading theme from \"{s}\": it is a {s}",
                            .{ theme, @tagName(stat.kind) },
                            0,
                        ),
                    });
                    return null;
                },
            }
            return .{
                .path = path,
                .file = file,
            };
        } else |err| switch (err) {
            // Not an error, just continue to the next location.
            error.FileNotFound => {},

            // Anything else is an error we log and give up on.
            else => {
                try diags.append(arena_alloc, .{
                    .message = try std.fmt.allocPrintSentinel(
                        arena_alloc,
                        "failed to load theme \"{s}\" from the file \"{s}\": {}",
                        .{ theme, path, err },
                        0,
                    ),
                });

                return null;
            },
        }
    }

    // Unlikely scenario: the theme doesn't exist. In this case, we reset
    // our iterator, reiterate over in order to build a better error message.
    // This does double allocate some memory but for errors I think that's
    // fine.
    it.reset();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        try diags.append(arena_alloc, .{
            .message = try std.fmt.allocPrintSentinel(
                arena_alloc,
                "theme \"{s}\" not found, tried path \"{s}\"",
                .{ theme, path },
                0,
            ),
        });
    }

    return null;
}

/// Open the given theme from an absolute path. If there are any errors
/// then messages will be appended to the given error list and null is
/// returned. If a non-null return value is returned, there are never any
/// errors added.
///
/// Due to the way allocations are handled, an Arena allocator (or another
/// similar allocator implementation) should be used. It may not be safe to
/// free the returned allocations.
pub fn openAbsolute(
    arena_alloc: Allocator,
    theme: []const u8,
    diags: *cli_diags.DiagnosticList,
) error{OutOfMemory}!?std.fs.File {
    return std.fs.openFileAbsolute(theme, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "failed to load theme from the path \"{s}\"",
                    .{theme},
                    0,
                ),
            }),
            else => try diags.append(arena_alloc, .{
                .message = try std.fmt.allocPrintSentinel(
                    arena_alloc,
                    "failed to load theme from the path \"{s}\": {}",
                    .{ theme, err },
                    0,
                ),
            }),
        }

        return null;
    };
}

test "theme list keeps first duplicate by directory priority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("user");
    try tmp.dir.makePath("resources");
    {
        var file = try tmp.dir.createFile("user/Dupe", .{});
        file.close();
    }
    {
        var file = try tmp.dir.createFile("resources/Dupe", .{});
        file.close();
    }
    {
        var file = try tmp.dir.createFile("resources/Other", .{});
        file.close();
    }

    var user_buf: [std.fs.max_path_bytes]u8 = undefined;
    var resources_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user_dir = try tmp.dir.realpath("user", &user_buf);
    const resources_dir = try tmp.dir.realpath("resources", &resources_buf);
    const entries = try listFromDirectories(std.testing.allocator, &.{
        .{ .location = .user, .dir = user_dir },
        .{ .location = .resources, .dir = resources_dir },
    });
    defer freeList(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "Dupe")) {
            try std.testing.expectEqual(Location.user, entry.location);
            return;
        }
    }
    return error.TestExpectedEqual;
}
