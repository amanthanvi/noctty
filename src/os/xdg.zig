//! Implementation of the XDG Base Directory specification
//! (https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html)

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const homedir = @import("homedir.zig");
const windows_ext = @import("windows_ext.zig");

pub const portable_marker_names = [_][]const u8{
    "noctty.portable",
    "portable.txt",
    "config.ghostty",
};

const PortableMarker = enum { explicit, legacy_config };

fn portableMarkerInDir(directory: std.fs.Dir) ?PortableMarker {
    for (portable_marker_names) |name| {
        const stat = directory.statFile(name) catch continue;
        if (stat.kind != .file) continue;
        return if (std.mem.eql(u8, name, "config.ghostty")) .legacy_config else .explicit;
    }
    return null;
}

/// Detect portable mode from a real executable directory. Markers must be
/// regular files so an unrelated directory cannot relocate application data.
pub fn detectPortableRoot(alloc: Allocator, exe_dir: []const u8) !?[]u8 {
    return detectPortableRootWithInstallerManaged(alloc, exe_dir, null);
}

fn detectPortableRootWithInstallerManaged(
    alloc: Allocator,
    exe_dir: []const u8,
    installer_managed_override: ?bool,
) !?[]u8 {
    var directory = try std.fs.openDirAbsolute(exe_dir, .{});
    defer directory.close();
    const marker = portableMarkerInDir(directory) orelse return null;
    if (marker == .legacy_config) {
        const installer_managed = installer_managed_override orelse
            (builtin.os.tag == .windows and windows_ext.innoUninstallRegistryMatchesInstallDir(exe_dir));
        if (installer_managed) return null;
    }
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
    if (!portableModeActive()) return null;
    return try alloc.dupe(u8, portable_root_cache.path[0..portable_root_cache.len]);
}

/// The cached answer `portableRoot` gives, without copying the path, so a
/// caller cannot see a different one when that copy fails.
pub fn portableModeActive() bool {
    portable_root_once.call();
    return portable_root_cache.present;
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
pub fn config(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_CONFIG_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".config",
    });
}

/// Get the XDG cache directory. The returned value is allocated.
pub fn cache(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
        .env = "XDG_CACHE_HOME",
        .windows_env = "LOCALAPPDATA",
        .default_subdir = ".cache",
    });
}

/// Get the XDG state directory. The returned value is allocated.
pub fn state(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map, opts: Options) ![]u8 {
    return try dir(io, alloc, environ_map, opts, .{
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
    io: std.Io,
    alloc: Allocator,
    environ_map: *const std.process.Environ.Map,
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

    // First check the env var. On Windows we treat `LOCALAPPDATA` as a
    // fallback for `XDG_CONFIG_HOME`
    const env = switch (builtin.target.os.tag) {
        .windows => environ_map.get(internal_opts.env) orelse environ_map.get(internal_opts.windows_env) orelse "",
        else => environ_map.get(internal_opts.env) orelse "",
    };

    if (env.len > 0) {
        // If we have a subdir, then we use the env as-is to avoid a copy.
        if (opts.subdir) |subdir| {
            return try std.fs.path.join(alloc, &[_][]const u8{
                env,
                subdir,
            });
        }

        return try alloc.dupe(u8, env);
    }

    // On Windows, a stripped-down shell may not have LOCALAPPDATA set
    // even though the known folder still exists.
    if (builtin.os.tag == .windows) {
        var windows_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (try windows_ext.knownFolderPathUtf8(&windows_ext.FOLDERID_LocalAppData, &windows_buf)) |local_appdata| {
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
    if (try homedir.home(io, environ_map, &buf)) |home| {
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
    const io = testing.io;
    const alloc = testing.allocator;
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();

    {
        const value = try config(io, alloc, &environ_map, .{});
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

    const ssh_path = try portablePath(alloc, path_root, "noctty/ssh_cache");
    defer alloc.free(ssh_path);
    const expected_ssh = try std.fs.path.join(alloc, &.{ path_root, "ssh_cache" });
    defer alloc.free(expected_ssh);
    try testing.expectEqualStrings(expected_ssh, ssh_path);
}

test "ambiguous portable config marker does not override an installer-managed directory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const exe_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(exe_dir);

    try tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "user configuration" });
    try testing.expect((try detectPortableRootWithInstallerManaged(alloc, exe_dir, true)) == null);
    const legacy_root = (try detectPortableRootWithInstallerManaged(alloc, exe_dir, false)).?;
    defer alloc.free(legacy_root);
    try testing.expectEqualStrings(exe_dir, legacy_root);

    for ([_][]const u8{ "noctty.portable", "portable.txt" }) |explicit_marker| {
        try tmp.dir.writeFile(.{ .sub_path = explicit_marker, .data = explicit_marker });
        const explicit_root = (try detectPortableRootWithInstallerManaged(alloc, exe_dir, true)).?;
        defer alloc.free(explicit_root);
        try testing.expectEqualStrings(exe_dir, explicit_root);
        try tmp.dir.deleteFile(explicit_marker);
    }
}

test "cache directory paths" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    const mock_home = if (builtin.target.os.tag == .windows) "C:\\Users\\test" else "/Users/test";
    var environ_map = try testing.environ.createMap(alloc);
    defer environ_map.deinit();

    // Test when XDG_CACHE_HOME is not set
    {
        // Test base path
        {
            const cache_path = try cache(io, alloc, &environ_map, .{ .home = mock_home });
            defer alloc.free(cache_path);
            const expected = try std.fs.path.join(alloc, &.{ mock_home, ".cache" });
            defer alloc.free(expected);
            try testing.expectEqualStrings(expected, cache_path);
        }

        // Test with subdir
        {
            const cache_path = try cache(io, alloc, &environ_map, .{
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
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (std.Io, Allocator, *std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        var environ_map = try std.testing.environ.createMap(alloc);
        defer environ_map.deinit();
        const temp_home = "/tmp/ghostty-test-home";
        try environ_map.put("HOME", temp_home);

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        try environ_map.put(case.name, "");
        const actual = try case.func(io, alloc, &environ_map, .{});
        defer alloc.free(actual);

        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "fallback when xdg env empty and subdir" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const DirCase = struct {
        name: [:0]const u8,
        func: fn (std.Io, Allocator, *const std.process.Environ.Map, Options) anyerror![]u8,
        default_subdir: []const u8,
    };

    const cases = [_]DirCase{
        .{ .name = "XDG_CONFIG_HOME", .func = config, .default_subdir = ".config" },
        .{ .name = "XDG_CACHE_HOME", .func = cache, .default_subdir = ".cache" },
        .{ .name = "XDG_STATE_HOME", .func = state, .default_subdir = ".local/state" },
    };

    inline for (cases) |case| {
        var environ_map = try std.testing.environ.createMap(alloc);
        defer environ_map.deinit();
        const temp_home = "/tmp/ghostty-test-home";
        try environ_map.put("HOME", temp_home);

        const expected = try std.fs.path.join(alloc, &[_][]const u8{
            temp_home,
            case.default_subdir,
            "ghostty",
        });
        defer alloc.free(expected);

        // Test with empty string - should fallback to home
        try environ_map.put(case.name, "");
        const actual = try case.func(io, alloc, &environ_map, .{ .subdir = "ghostty" });
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
