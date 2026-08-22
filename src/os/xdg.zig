//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const homedir = @import("homedir.zig");
const env_os = @import("env.zig");
const windows_os = @import("windows.zig");

pub const portable_marker_names = [_][]const u8{
    "noctty.portable",
    "portable.txt",
    "config.ghostty",
};

fn portableMarkerInDir(directory: std.fs.Dir) ?[]const u8 {
    for (portable_marker_names) |name| {
        const stat = directory.statFile(name) catch continue;
        if (stat.kind == .file) return name;
    }
    return null;
}

/// Detect portable mode from a real executable directory. Markers must be
/// regular files so an unrelated directory cannot relocate application data.
pub fn detectPortableRoot(alloc: Allocator, exe_dir: []const u8) !?[]u8 {
    var directory = try std.fs.openDirAbsolute(exe_dir, .{});
    defer directory.close();
    _ = portableMarkerInDir(directory) orelse return null;
    return try alloc.dupe(u8, exe_dir);
}

const PortableRootCache = struct {
    path: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,
    present: bool = false,
};

var portable_root_cache: PortableRootCache = .{};
var portable_root_once = std.once(initPortableRootCache);

fn initPortableRootCache() void {
    if (builtin.os.tag != .windows) return;

    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch return;
    const root = detectPortableRoot(std.heap.page_allocator, exe_dir) catch return;
    defer if (root) |value| std.heap.page_allocator.free(value);
    const value = root orelse return;
    if (value.len > portable_root_cache.path.len) return;
    @memcpy(portable_root_cache.path[0..value.len], value);
    portable_root_cache.len = value.len;
    portable_root_cache.present = true;
}

/// Return the process-wide cached portable root, if portable mode was enabled
/// beside the executable. The caller owns the returned path.
pub fn portableRoot(alloc: Allocator) !?[]u8 {
    portable_root_once.call();
    if (!portable_root_cache.present) return null;
    return try alloc.dupe(u8, portable_root_cache.path[0..portable_root_cache.len]);
}

fn portablePath(alloc: Allocator, root: []const u8, subdir: ?[]const u8) ![]u8 {
    const requested = subdir orelse return try alloc.dupe(u8, root);
    const relative = if (std.mem.startsWith(u8, requested, "noctty/"))
        requested["noctty/".len..]
    else if (std.mem.startsWith(u8, requested, "noctty\\"))
        requested["noctty\\".len..]
    else
        requested;
    if (relative.len == 0) return try alloc.dupe(u8, root);
    return try std.fs.path.join(alloc, &.{ root, relative });
}

pub const Options = struct {
    /// Subdirectories to join to the base. This avoids extra allocations
    /// when building up the directory. This is commonly the application.
    subdir: ?[]const u8 = null,

    /// The home directory for the user. If this is not set, we will attempt
    /// to look it up which is an expensive process. By setting this, you can
    /// avoid lookups.
    home: ?[]const u8 = null,
};

/// Get the XDG user config directory. The returned value is allocated.
pub fn config(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}

/// Get the XDG cache directory. The returned value is allocated.
pub fn cache(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}

/// Get the XDG state directory. The returned value is allocated.
pub fn state(alloc: Allocator, opts: Options) ![]u8 {
    return try dir(alloc, opts, .{
        .env = "XDG_STATE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".local/state",
    });
}

const InternalOptions = struct {
    env: []const u8,
    windows_env: []const u8,
    default_subdir: []const u8,
};

/// Unified helper to get XDG directories that follow a common pattern.
fn dir(
    alloc: Allocator,
    opts: Options,
    internal_opts: InternalOptions,
) ![]u8 {
    if (try portableRoot(alloc)) |root| {
        defer alloc.free(root);
        return try portablePath(alloc, root, opts.subdir);
    }

    // If we have a cached home dir, use that.
    if (opts.home) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    // First check the env var. On Windows we have to allocate so this tracks
    // both whether we have the env var and whether we own it.
    // on Windows we treat `LOCALAPPDATA` as a fallback for `XDG_CONFIG_HOME`
    const env_ = try env_os.getenvNotEmpty(alloc, internal_opts.env) orelse switch (builtin.os.tag) {
        else => null,
        .windows => try env_os.getenvNotEmpty(alloc, internal_opts.windows_env),
    };
    defer if (env_) |env| env.deinit(alloc);

    if (env_) |env| {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.fs.path.join(alloc, &[_][]const u8{
                env.value,
                subdir,
            });
        }

        return try alloc.dupe(u8, env.value);
    }

    // On Windows, a stripped-down shell may not have LOCALAPPDATA set
    // even though the known folder still exists.
    if (builtin.os.tag == .windows) {
        var windows_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (try windows_os.knownFolderPathUtf8(&windows_os.FOLDERID_LocalAppData, &windows_buf)) |local_appdata| {
            if (opts.subdir) |subdir| {
                return try std.fs.path.join(alloc, &[_][]const u8{
                    local_appdata,
                    subdir,
                });
            }

            return try alloc.dupe(u8, local_appdata);
        }
    }

    // Get our home dir
    var buf: [1024]u8 = undefined;
    if (try homedir.home(&buf)) |home| {
        return try std.fs.path.join(alloc, &[_][]const u8{
            home,
            internal_opts.default_subdir,
            opts.subdir orelse "",
        });
    }

    return error.NoHomeDir;
}

/// Parses the xdg-terminal-exec specification. This expects argv[0] to
/// be "xdg-terminal-exec".
pub fn parseTerminalExec(argv: []const [*:0]const u8) ?[]const [*:0]const u8 {
    if (!std.mem.eql(
        u8,
        std.fs.path.basename(std.mem.sliceTo(argv[0], 0)),
        "xdg-terminal-exec",
    )) return null;

    // We expect at least one argument
    if (argv.len < 2) return &.{};

    // If the first argument is "-e" we skip it.
    const start: usize = if (std.mem.eql(u8, std.mem.sliceTo(argv[1], 0), "-e")) 2 else 1;
    return argv[start..];
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        const value = try config(alloc, .{});
        defer alloc.free(value);
        try testing.expect(value.len > 0);
    }
}

test "portable marker detection requires a regular file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(exe_dir);

    try testing.expect((try detectPortableRoot(alloc, exe_dir)) == null);

    for (portable_marker_names) |marker| {
        try tmp.dir.makeDir(marker);
        try testing.expect((try detectPortableRoot(alloc, exe_dir)) == null);
        try tmp.dir.deleteDir(marker);

        const file = try tmp.dir.createFile(marker, .{});
        file.close();
        const root = (try detectPortableRoot(alloc, exe_dir)).?;
        defer alloc.free(root);
        try testing.expectEqualStrings(exe_dir, root);
        try tmp.dir.deleteFile(marker);
    }

    const ignored = try tmp.dir.createFile("config", .{});
    ignored.close();
    try testing.expect((try detectPortableRoot(alloc, exe_dir)) == null);

    const path_root = if (builtin.os.tag == .windows) "D:\\apps\\noctty" else "/apps/noctty";

    const config_path = try portablePath(alloc, path_root, "noctty/config.ghostty");
    defer alloc.free(config_path);
    const expected_config = try std.fs.path.join(alloc, &.{ path_root, "config.ghostty" });
    defer alloc.free(expected_config);
    try testing.expectEqualStrings(expected_config, config_path);

    const state_path = try portablePath(alloc, path_root, "noctty\\update-state.json");
    defer alloc.free(state_path);
    const expected_state = try std.fs.path.join(alloc, &.{ path_root, "update-state.json" });
    defer alloc.free(expected_state);
    try testing.expectEqualStrings(expected_state, state_path);

    const crash_path = try portablePath(alloc, path_root, "noctty/crash");
    defer alloc.free(crash_path);
    const expected_crash = try std.fs.path.join(alloc, &.{ path_root, "crash" });
    defer alloc.free(expected_crash);
    try testing.expectEqualStrings(expected_crash, crash_path);
}

test "cache directory paths" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const mock_home = if (builtin.os.tag == .windows) "C:\\Users\\test" else "/Users/test";

    // Test when XDG_CACHE_HOME is not set
    {
        // Test base path
        {
            const cache_path = try cache(alloc, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }

        // Test with subdir
        {
            const cache_path = try cache(alloc, .{
                .home = mock_home,
                .subdir = "ghostty",
            });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache", "ghostty" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }
    }
}

test "fallback when xdg env empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    const saved_home = home: {
        const home = std.posix.getenv("HOME") orelse break :home null;
        break :home try alloc.dupeZ(u8, home);
    };
    defer env: {
        const home = saved_home orelse {
            _ = env_os.unsetenv("HOME");
            break :env;
        };
        _ = env_os.setenv("HOME", home);
        std.testing.allocator.free(home);
    }
    const temp_home = "/tmp/ghostty-test-home";
    _ = env_os.setenv("HOME", temp_home);

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (Allocator, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        // Save and restore each environment variable
        const saved_env = blk: {
            const value = std.posix.getenv(case.name) orelse break :blk null;
            break :blk try alloc.dupeZ(u8, value);
        };
        defer env: {
            const value = saved_env orelse {
                _ = env_os.unsetenv(case.name);
                break :env;
            };
            _ = env_os.setenv(case.name, value);
            alloc.free(value);
        }

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env_os.setenv(case.name, "");
        const actual = try case.func(alloc, .{});
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "fallback when xdg env empty and subdir" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const env = @import("env.zig");
    const alloc = std.testing.allocator;

    const saved_home = home: {
        const home = std.posix.getenv("HOME") orelse break :home null;
        break :home try alloc.dupeZ(u8, home);
    };
    defer env: {
        const home = saved_home orelse {
            _ = env.unsetenv("HOME");
            break :env;
        };
        _ = env.setenv("HOME", home);
        std.testing.allocator.free(home);
    }

    const temp_home = "/tmp/ghostty-test-home";
    _ = env.setenv("HOME", temp_home);

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (Allocator, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        // Save and restore each environment variable
        const saved_env = blk: {
            const value = std.posix.getenv(case.name) orelse break :blk null;
            break :blk try alloc.dupeZ(u8, value);
        };
        defer env: {
            const value = saved_env orelse {
                _ = env.unsetenv(case.name);
                break :env;
            };
            _ = env.setenv(case.name, value);
            alloc.free(value);
        }

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "ghostty",
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        _ = env.setenv(case.name, "");
        const actual = try case.func(alloc, .{ .subdir = "ghostty" });
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test parseTerminalExec {
    const testing = std.testing;

    {
        const actual = parseTerminalExec(&.{ "a", "b", "c" });
        try testing.expect(actual == null);
    }
    {
        const actual = parseTerminalExec(&.{"xdg-terminal-exec"}).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{});
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "-e", "a", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "b", "c" });
    }
    {
        const actual = parseTerminalExec(&.{ "xdg-terminal-exec", "a", "-e", "b", "c" }).?;
        try testing.expectEqualSlices([*:0]const u8, actual, &.{ "a", "-e", "b", "c" });
    }
}
