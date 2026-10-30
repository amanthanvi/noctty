//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, but
//! also OS-specific features and conventions.

const std = @import("std");
const builtin = @import("builtin");

const dbus = if (builtin.os.tag == .linux) @import("dbus.zig") else struct {
    pub fn launchedByDbusActivation() bool {
        return false;
    }
};
const desktop = if (builtin.os.tag == .windows) struct {
    pub const DesktopEnvironment = enum {
        gnome,
        macos,
        other,
        windows,
    };

    pub fn launchedFromDesktop() bool {
        return false;
    }

    pub fn desktopEnvironment() DesktopEnvironment {
        return .windows;
    }
} else @import("desktop.zig");
const env = @import("env.zig");
const file = @import("file.zig");
const flatpak = if (builtin.os.tag == .linux) @import("flatpak.zig") else struct {
    pub fn isFlatpak() bool {
        return false;
    }

    pub const FlatpakHostCommand = struct {
        pub const Completion = struct {};
    };
};
const homedir = @import("homedir.zig");
const locale = @import("locale.zig");
const mouse = @import("mouse.zig");
const openpkg = @import("open.zig");
const pipepkg = @import("pipe.zig");
const resourcesdir = @import("resourcesdir.zig");
const systemd = if (builtin.os.tag == .linux) @import("systemd.zig") else struct {
    pub fn launchedBySystemd() bool {
        return false;
    }
};
const kernel_info = if (builtin.os.tag == .linux) @import("kernel_info.zig") else struct {
    pub fn getKernelInfo(_: std.mem.Allocator) ?[]const u8 {
        return null;
    }
};

// Namespaces
pub const args = @import("args.zig");
pub const cgroup = @import("cgroup.zig");
pub const hostname = @import("hostname.zig");
pub const i18n = @import("i18n.zig");
pub const mach = if (builtin.os.tag.isDarwin()) @import("mach.zig") else struct {};
pub const color_scheme = @import("color_scheme.zig");
pub const local_path = @import("local_path.zig");
pub const path = @import("path.zig");
pub const passwd = @import("passwd.zig");
pub const redact = @import("redact.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
pub const macos = if (builtin.os.tag.isDarwin()) @import("macos.zig") else struct {};
pub const monotonic = @import("monotonic.zig");
pub const shell = @import("shell.zig");
pub const uri = @import("uri.zig");

// Functions and types
pub const CFReleaseThread = if (builtin.os.tag.isDarwin()) @import("cf_release_thread.zig") else struct {};
pub const TempDir = @import("TempDir.zig");
pub const GetEnvResult = env.GetEnvResult;
pub const getEnvMap = env.getEnvMap;
pub const appendEnv = env.appendEnv;
pub const appendEnvAlways = env.appendEnvAlways;
pub const prependEnv = env.prependEnv;
pub const getenv = env.getenv;
pub const getEnvVarOwnedTrimmedNotEmpty = env.getEnvVarOwnedTrimmedNotEmpty;
pub const setenv = env.setenv;
pub const unsetenv = env.unsetenv;
pub const launchedFromDesktop = desktop.launchedFromDesktop;
pub const launchedByDbusActivation = dbus.launchedByDbusActivation;
pub const launchedBySystemd = systemd.launchedBySystemd;
pub const desktopEnvironment = desktop.desktopEnvironment;
pub const rlimit = file.rlimit;
pub const fixMaxFiles = file.fixMaxFiles;
pub const restoreMaxFiles = file.restoreMaxFiles;
pub const allocTmpDir = file.allocTmpDir;
pub const freeTmpDir = file.freeTmpDir;
pub const isFlatpak = flatpak.isFlatpak;
pub const FlatpakHostCommand = flatpak.FlatpakHostCommand;
pub const home = homedir.home;
pub const expandHome = homedir.expandHome;
pub const ensureLocale = locale.ensureLocale;
pub const clickInterval = mouse.clickInterval;
pub const open = openpkg.open;
pub const OpenType = openpkg.Type;
pub const pipe = pipepkg.pipe;
pub const resourcesDir = resourcesdir.resourcesDir;
pub const ResourcesDir = resourcesdir.ResourcesDir;
pub const ShellEscapeWriter = shell.ShellEscapeWriter;
pub const getKernelInfo = kernel_info.getKernelInfo;

/// Per-surface terminal threads are numerous on Windows, where Zig's default
/// 16 MiB stack is committed by CreateThread. Keep process-global and
/// short-lived worker threads on the standard library default.
pub fn surfaceThreadSpawnConfig() std.Thread.SpawnConfig {
    return if (builtin.os.tag == .windows)
        .{ .stack_size = 1024 * 1024 }
    else
        .{};
}

test "Windows surface threads use a bounded stack" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const config = surfaceThreadSpawnConfig();
    try std.testing.expectEqual(@as(usize, 1024 * 1024), config.stack_size);
    try std.testing.expect(config.stack_size < std.Thread.SpawnConfig.default_stack_size);
}

fn surfaceThreadStackProbe(result: *std.atomic.Value(u64)) void {
    // Match the largest fixed local on the Windows PTY reader and exercise
    // the configured stack through a real CreateThread/join lifecycle.
    var read_buf: [64 * 1024]u8 = undefined;
    for (&read_buf, 0..) |*byte, i| byte.* = @truncate(i);

    var sum: u64 = 0;
    for (read_buf) |byte| sum += byte;
    result.store(sum, .release);
}

test "Windows surface thread stack carries a 64 KiB read batch and joins" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var result = std.atomic.Value(u64).init(0);
    const thread = try std.Thread.spawn(
        surfaceThreadSpawnConfig(),
        surfaceThreadStackProbe,
        .{&result},
    );
    thread.join();

    try std.testing.expectEqual(@as(u64, 8_355_840), result.load(.acquire));
}

const stack_paint: u8 = 0xa5;

/// For tests: how much of this thread's stack `run(context)` used below this
/// call, in bytes. The committed stack under this frame is painted first, and
/// the deepest byte written is the measure: a call writes its return address
/// at its caller's stack pointer, and Debug also fills `undefined` locals.
/// Past the commit, how far the committed limit moved is the measure, since a
/// thread's stack pages stay committed.
noinline fn stackUse(context: anytype, comptime run: fn (@TypeOf(context)) void) usize {
    const tib = &std.os.windows.teb().NtTib;
    const frame = @frameAddress();
    const low = @intFromPtr(tib.StackLimit);
    // Room above the paint for this frame and the calls that paint and read.
    const top = frame - 16 * 1024;
    const painted = @as([*]u8, @ptrFromInt(low))[0 .. top - low];
    @memset(painted, stack_paint);
    // Never inlined: `run`'s locals belong below the paint, not in this frame.
    @call(.never_inline, run, .{context});
    const limit = @intFromPtr(tib.StackLimit);
    if (limit < low) return frame - limit;
    return frame - low - (std.mem.indexOfNone(u8, painted, &.{stack_paint}) orelse painted.len);
}

/// One `local_path.open` on a surface thread, as a kitty graphics `t=f` load
/// makes it on the pty reader.
const LocalOpenProbe = struct {
    path: []const u8,
    opened: ?std.meta.Tag(local_path.Opened) = null,
    used: usize = 0,

    fn run(self: *LocalOpenProbe) void {
        self.used = stackUse(self, openLocal);
    }

    fn openLocal(self: *LocalOpenProbe) void {
        const alloc = std.testing.allocator;
        const opened = local_path.open(alloc, self.path, .{ .data = true }) catch return;
        if (opened == .found) opened.found.deinit(alloc);
        self.opened = std.meta.activeTag(opened);
    }
};

/// The most stack one more link may cost `local_path.open`. Its walk recurses
/// once per link and keeps each frame across the call, so a buffer in that
/// frame is paid once per link: with its name and reparse buffers there, a
/// link cost 146 KiB (5.3 MiB for 32 links in ReleaseFast); without, about
/// 0.6 KiB (1.2 KiB in Debug).
const local_open_link_frame_max = 4 * 1024;

test "Windows surface thread stack carries local_path.open through a junction cycle and a 32-link chain" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const links = local_path.test_links;
    const chain_len = 32;

    // A kitty graphics `t=f` load opens its file on the pty reader. The 1 MiB
    // of `surfaceThreadSpawnConfig` is what CreateThread commits; the reserve
    // is the exe's (16 MiB), so a deeper open commits more rather than
    // overflowing, and what this pins is that the walk's stack does not grow
    // with the links it follows.

    // Under the system temp folder, which is shallow: the walk spends one of
    // its 256 names on each component of every path it opens, so from the
    // build tree's cache a 31-link chain would run out of names first.
    var tmp = try TempDir.init();
    defer tmp.deinit();
    try tmp.dir.makeDir("real");
    try tmp.dir.writeFile(.{ .sub_path = "real\\image.data", .data = "image" });
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    var components = std.mem.tokenizeScalar(u8, base[3..], '\\');
    var depth: usize = 0;
    while (components.next()) |_| depth += 1;
    if (chain_len * depth + chain_len + 1 > 256) {
        std.log.warn("surface thread stack test: the temp folder is {d} names deep; a 31-link chain would run out of names", .{depth});
        return error.SkipZigTest;
    }

    // `link-K` leads to `link-(K+1)`, the last one to `real`; `loop` to itself.
    var made: usize = 0;
    defer {
        // Links go first, removed as links (never followed).
        tmp.dir.deleteDir("loop") catch {};
        for (0..made) |i| {
            var name_buf: [16]u8 = undefined;
            tmp.dir.deleteDir(std.fmt.bufPrint(&name_buf, "link-{d}", .{i}) catch unreachable) catch {};
        }
    }
    try tmp.dir.makeDir("loop");
    {
        const loop = try std.fs.path.join(alloc, &.{ base, "loop" });
        defer alloc.free(loop);
        const target = try std.fmt.allocPrint(alloc, "\\??\\{s}", .{loop});
        defer alloc.free(target);
        try links.junction(alloc, loop, target);
    }
    while (made < chain_len) : (made += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "link-{d}", .{made});
        try tmp.dir.makeDir(name);
        const link = try std.fs.path.join(alloc, &.{ base, name });
        defer alloc.free(link);
        const target = if (made + 1 == chain_len)
            try std.fmt.allocPrint(alloc, "\\??\\{s}\\real", .{base})
        else
            try std.fmt.allocPrint(alloc, "\\??\\{s}\\link-{d}", .{ base, made + 1 });
        defer alloc.free(target);
        try links.junction(alloc, link, target);
    }

    const OpenedTag = std.meta.Tag(local_path.Opened);
    const Case = struct { rel: []const u8, links: usize, want: OpenedTag };
    const cases = [_]Case{
        .{ .rel = "real\\image.data", .links = 0, .want = .found },
        .{ .rel = "link-31\\image.data", .links = 1, .want = .found },
        // The longest chain the walk follows: every frame it keeps at once.
        .{ .rel = "link-1\\image.data", .links = 31, .want = .found },
        // One link past the walk's limit, and a link to itself.
        .{ .rel = "link-0\\image.data", .links = 32, .want = .refused },
        .{ .rel = "loop\\image.data", .links = 32, .want = .refused },
    };
    var one_link: usize = 0;
    for (cases) |case| {
        const case_path = try std.fs.path.join(alloc, &.{ base, case.rel });
        defer alloc.free(case_path);
        var probe: LocalOpenProbe = .{ .path = case_path };
        const thread = try std.Thread.spawn(surfaceThreadSpawnConfig(), LocalOpenProbe.run, .{&probe});
        thread.join();
        errdefer std.debug.print("local_path.open of {s} on a surface thread: {?t}, {d} bytes of stack (one link: {d})\n", .{ case.rel, probe.opened, probe.used, one_link });
        try std.testing.expectEqual(@as(?OpenedTag, case.want), probe.opened);
        if (case.links == 1) one_link = probe.used;
        if (case.links > 1) try std.testing.expect(probe.used <= one_link + (case.links - 1) * local_open_link_frame_max);
    }
}

test {
    _ = file;
    _ = i18n;
    _ = monotonic;
    _ = path;
    _ = uri;
    _ = shell;

    if (comptime builtin.os.tag == .linux) {
        _ = kernel_info;
    } else if (comptime builtin.os.tag.isDarwin()) {
        _ = mach;
        _ = macos;
    } else if (comptime builtin.os.tag == .windows) {
        _ = local_path;
    }
}
