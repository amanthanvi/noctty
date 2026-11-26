const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
const cli_diags = @import("../cli/diagnostics.zig");
const file_load = @import("file_load.zig");
const global = @import("../global.zig");

/// Location of possible themes. The order of this enum matters because it
/// defines the priority of theme search (from top to bottom).
pub const Location = enum {
    user, // XDG config dir
    legacy_user, // Legacy Ghostty XDG config dir
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
    ) error{ OutOfMemory, Unexpected }!?[]const u8 {
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        return switch (self) {
            .user, .legacy_user => user: {
                const subdir = std.fs.path.join(arena_alloc, &.{
                    if (self == .user) build_config.data_dir_name else "ghostty",
                    "themes",
                }) catch return error.OutOfMemory;

                // A test build looks only under the config home its test
                // names (`file_load.test_config_root`), and with none has
                // no user theme directory, so it never probes the
                // developer's own themes.
                if (comptime builtin.is_test) break :user file_load.configHomePath(
                    arena_alloc,
                    subdir,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NoTestConfigRoot => return null,
                };

                break :user internal_os.xdg.config(
                    global.io(),
                    arena_alloc,
                    &environ_map,
                    .{ .subdir = subdir },
                ) catch |err| {
                    // We need to do some comptime tricks to get the right
                    // error set since some platforms don't support some
                    // error types.
                    const Error = @TypeOf(err) || switch (builtin.target.os.tag) {
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
                global.resourcesDir().app() orelse return null,
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
        const max = @typeInfo(Location).@"enum".field_names.len;
        while (self.i < max) {
            const location: Location = @fromBackingInt(@intCast(self.i));
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
/// `open`: current user themes first, legacy user themes second, and bundled
/// resources last. Duplicate names keep the first location deterministically.
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
            else => {
                std.log.warn("failed to open theme directory dir={f} err={}", .{ internal_os.redact.bytes(loc.dir), err });
                continue;
            },
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
) error{ OutOfMemory, Unexpected }!?struct {
    path: []const u8,
    file: std.Io.File,
} {
    // Absolute themes are loaded a different path.
    if (std.fs.path.isAbsolute(theme)) {
        const file: std.Io.File = try openAbsolute(
            arena_alloc,
            theme,
            diags,
        ) orelse return null;
        const stat = file.stat(global.io()) catch |err| {
            try diags.append(arena_alloc, .{
                .message = try arena_alloc.printSentinel(
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
                    .message = try arena_alloc.printSentinel(
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
            .message = try arena_alloc.printSentinel(
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
    const cwd = std.Io.Dir.cwd();
    while (try it.next()) |loc| {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        if (cwd.openFile(global.io(), path, .{})) |file| {
            const stat = file.stat(global.io()) catch |err| {
                try diags.append(arena_alloc, .{
                    .message = try arena_alloc.printSentinel(
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
                        .message = try arena_alloc.printSentinel(
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
                    .message = try arena_alloc.printSentinel(
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
    try appendNotFound(arena_alloc, theme, &it, diags);

    return null;
}

/// One diagnostic for a theme no directory has, naming every path tried. A
/// diagnostic per directory made a single misspelled name count as several
/// config problems.
fn appendNotFound(
    arena_alloc: Allocator,
    theme: []const u8,
    it: *LocationIterator,
    diags: *cli_diags.DiagnosticList,
) error{ OutOfMemory, Unexpected }!void {
    var message: std.Io.Writer.Allocating = .init(arena_alloc);
    message.writer.print("theme \"{s}\" not found", .{theme}) catch return error.OutOfMemory;
    var tried: usize = 0;
    while (try it.next()) |loc| : (tried += 1) {
        const path = try std.fs.path.join(arena_alloc, &.{ loc.dir, theme });
        message.writer.print("{s} \"{s}\"", .{ if (tried == 0) ", tried path" else ",", path }) catch return error.OutOfMemory;
    }
    if (tried == 0) message.writer.writeAll(": there is no theme directory") catch return error.OutOfMemory;
    try diags.append(arena_alloc, .{
        .message = try message.toOwnedSliceSentinel(0),
    });
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
) error{OutOfMemory}!?std.Io.File {
    return std.Io.Dir.openFileAbsolute(global.io(), theme, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => try diags.append(arena_alloc, .{
                .message = try arena_alloc.printSentinel(
                    "failed to load theme from the path \"{s}\"",
                    .{theme},
                    0,
                ),
            }),
            else => try diags.append(arena_alloc, .{
                .message = try arena_alloc.printSentinel(
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

    try tmp.dir.createDirPath(std.testing.io, "user");
    try tmp.dir.createDirPath(std.testing.io, "legacy-user");
    try tmp.dir.createDirPath(std.testing.io, "resources");
    {
        var file = try tmp.dir.createFile(std.testing.io, "user/Dupe", .{});
        file.close(std.testing.io);
    }
    {
        var file = try tmp.dir.createFile(std.testing.io, "legacy-user/Dupe", .{});
        file.close(std.testing.io);
    }
    {
        var file = try tmp.dir.createFile(std.testing.io, "legacy-user/LegacyWins", .{});
        file.close(std.testing.io);
    }
    {
        var file = try tmp.dir.createFile(std.testing.io, "resources/Dupe", .{});
        file.close(std.testing.io);
    }
    {
        var file = try tmp.dir.createFile(std.testing.io, "resources/LegacyWins", .{});
        file.close(std.testing.io);
    }

    var user_buf: [std.fs.max_path_bytes]u8 = undefined;
    var legacy_user_buf: [std.fs.max_path_bytes]u8 = undefined;
    var resources_buf: [std.fs.max_path_bytes]u8 = undefined;
    const user_dir = try tmp.dir.realpath("user", &user_buf);
    const legacy_user_dir = try tmp.dir.realpath("legacy-user", &legacy_user_buf);
    const resources_dir = try tmp.dir.realpath("resources", &resources_buf);
    const entries = try listFromDirectories(std.testing.allocator, &.{
        .{ .location = .user, .dir = user_dir },
        .{ .location = .legacy_user, .dir = legacy_user_dir },
        .{ .location = .resources, .dir = resources_dir },
    });
    defer freeList(std.testing.allocator, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    var found_user = false;
    var found_legacy_user = false;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "Dupe")) {
            try std.testing.expectEqual(Location.user, entry.location);
            found_user = true;
        } else if (std.mem.eql(u8, entry.name, "LegacyWins")) {
            try std.testing.expectEqual(Location.legacy_user, entry.location);
            found_legacy_user = true;
        }
    }
    try std.testing.expect(found_user);
    try std.testing.expect(found_legacy_user);
}

test "issue149 user theme locations prefer noctty before legacy ghostty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A test build has user theme directories only under a config home its
    // test names; nothing here opens them.
    file_load.test_config_root = if (builtin.os.tag == .windows) "C:\\noctty-test-config-home" else "/noctty-test-config-home";
    defer file_load.test_config_root = null;

    var it: LocationIterator = .{ .arena_alloc = arena.allocator() };
    const user = (try it.next()).?;
    try std.testing.expectEqual(Location.user, user.location);
    try std.testing.expectEqualStrings("themes", std.fs.path.basename(user.dir));
    try std.testing.expectEqualStrings(
        build_config.data_dir_name,
        std.fs.path.basename(std.fs.path.dirname(user.dir).?),
    );

    const legacy_user = (try it.next()).?;
    try std.testing.expectEqual(Location.legacy_user, legacy_user.location);
    try std.testing.expectEqualStrings("themes", std.fs.path.basename(legacy_user.dir));
    try std.testing.expectEqualStrings(
        "ghostty",
        std.fs.path.basename(std.fs.path.dirname(legacy_user.dir).?),
    );
}

test "a theme no directory has is one diagnostic that names every path tried" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The user theme directories under a scratch config home this test
    // names (a test build has none otherwise), so the paths tried are there.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    file_load.test_config_root = home;
    defer file_load.test_config_root = null;

    var diags: cli_diags.DiagnosticList = .{};
    const found = try open(arena.allocator(), "no-such-theme-pkg22", &diags);
    try std.testing.expect(found == null);

    // One misspelled name used to count as one problem per directory searched.
    try std.testing.expectEqual(@as(usize, 1), diags.items().len);
    const message = diags.items()[0].message;
    try std.testing.expect(std.mem.indexOf(u8, message, "theme \"no-such-theme-pkg22\" not found") != null);

    var it: LocationIterator = .{ .arena_alloc = arena.allocator() };
    var tried: usize = 0;
    while (try it.next()) |loc| : (tried += 1) {
        try std.testing.expect(std.mem.indexOf(u8, message, loc.dir) != null);
    }
    // At least both user directories, so the check above is not empty.
    try std.testing.expect(tried >= 2);
}

test "a test build looks for user themes only under the config home its test names" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // Without the guard a portable copy looks beside the executable, which
    // the environment below cannot steer, so this test could not fail there.
    // Skip rather than pass without checking anything.
    if (try internal_os.xdg.portableRoot(alloc)) |root| {
        alloc.free(root);
        return error.SkipZigTest;
    }

    // A theme in a scratch home's user theme directory, where a lookup
    // without the guard looks first: `XDG_CONFIG_HOME` points at the home
    // (it wins over `LOCALAPPDATA`) for this test's length.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const themes_dir = build_config.data_dir_name ++ "/themes";
    try tmp.dir.createDirPath(std.testing.io, themes_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = themes_dir ++ "/test-config-guard-theme", .data = "font-size = 31\n" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    const saved: ?[:0]u8 = saved: {
        const value = std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :saved null,
            else => return err,
        };
        defer alloc.free(value);
        break :saved try alloc.dupeSentinel(u8, value, 0);
    };
    defer if (saved) |value| alloc.free(value);
    defer _ = if (saved) |value|
        internal_os.setenv("XDG_CONFIG_HOME", value)
    else
        internal_os.unsetenv("XDG_CONFIG_HOME");
    try std.testing.expectEqual(@as(c_int, 0), internal_os.setenv("XDG_CONFIG_HOME", try arena.allocator().dupeSentinel(u8, home, 0)));

    // No root named: the theme is not found, and no user theme directory is
    // there to look in.
    {
        var diags: cli_diags.DiagnosticList = .{};
        if (try open(arena.allocator(), "test-config-guard-theme", &diags)) |hit| {
            hit.file.close();
            std.debug.print("found the scratch home's theme without a named root\n", .{});
            return error.TestUserThemeFound;
        }
        var it: LocationIterator = .{ .arena_alloc = arena.allocator() };
        while (try it.next()) |loc| {
            if (loc.location == .resources) continue;
            std.debug.print("a {t} theme directory without a named root\n", .{loc.location});
            return error.TestUserThemeDirectory;
        }
    }

    // The positive control: named as the test's config home, the theme is
    // found there, as a user theme.
    file_load.test_config_root = home;
    defer file_load.test_config_root = null;
    var diags: cli_diags.DiagnosticList = .{};
    const hit = (try open(arena.allocator(), "test-config-guard-theme", &diags)) orelse
        return error.TestExpectedTheme;
    defer hit.file.close();
    const expected = try std.fs.path.join(arena.allocator(), &.{ home, build_config.data_dir_name, "themes", "test-config-guard-theme" });
    try std.testing.expectEqualStrings(expected, hit.path);
}
