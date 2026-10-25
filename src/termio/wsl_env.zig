//! Environment forwarding into WSL.
//!
//! `wsl.exe` hands a Linux process only the Windows variables that `WSLENV`
//! lists, and starts it with its own `TERM=xterm-256color`. Without help, a
//! shell in WSL therefore misses `COLORTERM`, `TERM_PROGRAM` and
//! `TERM_PROGRAM_VERSION`, which cmd and PowerShell in the same terminal see,
//! and programs that read them choose different colors and features on the
//! two sides.
//!
//! The three identity variables are always listed. `TERM` is listed, as the
//! terminal's own value, only when the distribution has a terminfo entry for
//! it, so a distribution without `xterm-ghostty` keeps the working
//! `xterm-256color`. Only names are added, each with the `/u` flag so that a
//! Windows program started from inside WSL does not get the Linux values back:
//! the user's own entries, flags and order stay as they are, and no Windows
//! path is exported (`TERMINFO` never is).
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;
const windows = std.os.windows;
const windows_shell = @import("../config.zig").windows_shell;
const os_path = @import("../os/path.zig");
const os_windows = @import("../os/windows.zig");
const Command = @import("../Command.zig");

const log = std.log.scoped(.wsl_env);

/// Variables that name the terminal and its color support, forwarded whenever
/// the environment has them.
pub const identity_vars = [_][]const u8{ "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION" };

/// How long the terminfo probe may run before it counts as a "no". A stopped
/// distribution has to start first (13 s for one of the test distributions),
/// which the launch itself would pay otherwise.
const probe_timeout_ms: windows.DWORD = 15000;

/// What `Subprocess.start` needs to settle `TERM` for a WSL launch.
pub const Probe = struct {
    /// The command line of the `wsl.exe` launch.
    argv: []const [:0]const u8,
    /// The terminal's own `TERM`, listed if the distribution has an entry.
    term: []const u8,
    /// The sanitized native working directory used by the launch.
    cwd: ?[]const u8 = null,
};

/// The command line of a WSL launch, or null for any other command. The
/// words of a `command = wsl.exe -d Ubuntu` shell command, which noctty runs
/// as `cmd.exe /C <line>`, are its argv; they are allocated with `alloc`, which
/// should be an arena.
pub fn launchArgv(
    alloc: Allocator,
    args: []const [:0]const u8,
    windows_cmd_shell: bool,
) Allocator.Error!?[]const [:0]const u8 {
    if (windows_shell.isWslArgv(args)) return args;
    if (!windows_cmd_shell or args.len != 3) return null;

    const words = try splitWords(alloc, args[2]);
    if (!windows_shell.isWslArgv(words)) return null;
    return words;
}

/// Whether `args` start WSL through its `bash.exe` launcher, the one in the
/// Windows directory or the WindowsApps alias
/// (`windows_shell.isWslBashLauncherPath`), directly or as the program of a
/// `command = bash ...` line. A bare `bash` is the first one on the child's
/// `PATH`, as shell integration finds it before it leaves this launcher
/// alone (and otherwise launches its match by full path). Not exact for a
/// direct bare `bash` with integration off: `CreateProcessW` tries the
/// system directory before `PATH`. `alloc` should be an arena.
pub fn launchesBashLauncher(
    alloc: Allocator,
    args: []const [:0]const u8,
    windows_cmd_shell: bool,
    env: *const EnvMap,
) !bool {
    const argv = if (!windows_cmd_shell)
        args
    else if (args.len == 3)
        try splitWords(alloc, args[2])
    else
        return false;
    if (argv.len == 0) return false;
    const exe = argv[0];
    const name = std.fs.path.basename(exe);
    if (!std.ascii.eqlIgnoreCase(name, "bash") and !std.ascii.eqlIgnoreCase(name, "bash.exe")) return false;
    const program = if (std.mem.indexOfAny(u8, exe, "\\/:") == null)
        try windows_shell.lookupChildExecutable(alloc, exe, env) orelse return false
    else
        exe;
    return try windows_shell.isWslBashLauncherPath(alloc, program);
}

/// An automatic TERM belongs to one verified WSL child, not an entire cmd
/// pipeline. Shell expansion also prevents reproducing its selector/cwd.
pub fn canProbeShell(line: []const u8) bool {
    var quoted = false;
    for (line, 0..) |c, i| {
        switch (c) {
            '"' => {
                // Windows argv parsing treats backslashes before quotes and
                // adjacent quotes differently from our simple splitter.
                if (i > 0 and (line[i - 1] == '\\' or line[i - 1] == '"')) return false;
                quoted = !quoted;
            },
            '%', '^', '!' => return false,
            '&', '|', '<', '>', '(', ')' => if (!quoted) return false,
            '\r', '\n' => return false,
            else => if (c < 0x20 and c != '\t') return false,
        }
    }
    return !quoted;
}

/// An unresolved direct executable uses Windows process search, which is not
/// the shell's child-PATH search below. Probe only the exact prepared path.
pub fn canProbeDirect(exe: []const u8) bool {
    return isLocalAbsolute(exe);
}

/// cmd.exe /C runs user/machine AutoRun hooks before the WSL command. We
/// cannot verify their resulting environment without running them again.
/// Check for absence only, without reading or logging any hook contents.
pub fn cmdAutoRunAbsent() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return cmdAutoRunAbsentWithQuery(struct {
        fn query(root: windows.HKEY, view: windows.DWORD) windows.LSTATUS {
            var bytes: windows.DWORD = 0;
            return windows.advapi32.RegGetValueW(
                root,
                std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Command Processor"),
                std.unicode.utf8ToUtf16LeStringLiteral("AutoRun"),
                windows.advapi32.RRF.RT_ANY | windows.advapi32.RRF.NOEXPAND | view,
                null,
                null,
                &bytes,
            );
        }
    }.query);
}

fn cmdAutoRunAbsentWithQuery(query: anytype) bool {
    for ([_]windows.HKEY{ windows.HKEY_CURRENT_USER, windows.HKEY_LOCAL_MACHINE }) |root| {
        for ([_]windows.DWORD{ windows.advapi32.RRF.SUBKEY_WOW6432KEY, windows.advapi32.RRF.SUBKEY_WOW6464KEY }) |view| {
            if (query(root, view) != @intFromEnum(windows.Win32Error.FILE_NOT_FOUND)) return false;
        }
    }
    return true;
}

/// Split a command line at whitespace. A double-quoted stretch is part of a
/// word and loses its quotes; nothing else is interpreted.
fn splitWords(alloc: Allocator, line: []const u8) Allocator.Error![]const [:0]const u8 {
    var out: std.ArrayList([:0]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quoted = false;
    var in_word = false;
    for (line) |c| {
        if (c == '"') {
            quoted = !quoted;
            in_word = true;
        } else if (!quoted and std.ascii.isWhitespace(c)) {
            if (in_word) try out.append(alloc, try alloc.dupeZ(u8, word.items));
            word.clearRetainingCapacity();
            in_word = false;
        } else {
            try word.append(alloc, c);
            in_word = true;
        }
    }
    if (in_word) try out.append(alloc, try alloc.dupeZ(u8, word.items));
    return out.toOwnedSlice(alloc);
}

/// Whether the `WSLENV` list already has an entry for `name`, with or without
/// flags (`NAME/p`). Linux names are case-sensitive, so is this.
fn listed(wslenv: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, wslenv, ':');
    while (it.next()) |entry| {
        const entry_name = entry[0 .. std.mem.indexOfScalar(u8, entry, '/') orelse entry.len];
        if (std.mem.eql(u8, entry_name, name)) return true;
    }
    return false;
}

/// Add each of `names` that `env` holds and `WSLENV` does not list yet to
/// `WSLENV` as `NAME/u`, after the entries already there.
pub fn forward(env: *EnvMap, names: []const []const u8) !void {
    const alloc = env.hash_map.allocator;
    const existing = env.get("WSLENV") orelse "";

    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(alloc);
    try merged.appendSlice(alloc, existing);
    var changed = false;
    for (names) |name| {
        if (env.get(name) == null or listed(existing, name)) continue;
        if (merged.items.len > 0 and merged.getLast() != ':') try merged.append(alloc, ':');
        try merged.appendSlice(alloc, name);
        try merged.appendSlice(alloc, "/u");
        changed = true;
    }
    if (changed) try env.put("WSLENV", merged.items);
}

/// The `wsl.exe` options of a session launch that choose the system and user
/// it runs as, in order: all a terminfo probe must share with the launch, to
/// ask the same system the same user. Null when the command line is not a
/// plain session launch (`--shutdown`, `--update`, `--list`, ...), so there is
/// nothing to ask.
fn selectorArgs(alloc: Allocator, argv: []const [:0]const u8) Allocator.Error!?[]const []const u8 {
    const selecting = [_][]const u8{ "-d", "--distribution", "--distribution-id", "-u", "--user", "--cd" };
    // Options that take a value the probe has no use for.
    const skipping = [_][]const u8{"--shell-type"};
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 1;
    options: while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        // The command to run starts at `--`, at `-e`/`--exec`, or at the first
        // word that is not an option; what follows is not wsl.exe's.
        if (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "--") or
            std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exec")) break;

        if (std.mem.eql(u8, arg, "--system")) {
            try out.append(alloc, arg);
            continue;
        }
        for (selecting) |option| {
            if (!std.mem.eql(u8, arg, option)) continue;
            // A value cmd.exe expands (`%DISTRO%`, `^`) is not what the launch
            // gets, and the probe has no shell to expand it.
            if (i + 1 >= argv.len or std.mem.indexOfAny(u8, argv[i + 1], "%^") != null) {
                out.deinit(alloc);
                return null;
            }
            try out.appendSlice(alloc, argv[i .. i + 2]);
            i += 1;
            continue :options;
        }
        for (skipping) |option| {
            if (!std.mem.eql(u8, arg, option)) continue;
            i += 1;
            continue :options;
        }
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

/// The command line that asks a distribution whether `term` has a terminfo
/// entry: `argv[0]` (the `wsl.exe` that launches the session), the options
/// picking the distribution and user, then `--exec infocmp <term>`. Null when
/// `argv` is not a session launch. Free the slice (not its items) with `alloc`.
fn probeArgv(alloc: Allocator, argv: []const [:0]const u8, term: []const u8) Allocator.Error!?[][]const u8 {
    if (argv.len == 0 or term.len == 0 or term[0] == '-') return null;
    const selector = (try selectorArgs(alloc, argv)) orelse return null;
    defer alloc.free(selector);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, argv[0]);
    try out.appendSlice(alloc, selector);
    try out.appendSlice(alloc, &.{ "--exec", "infocmp", term });
    return try out.toOwnedSlice(alloc);
}

/// Explicit selections do not depend on WSL's mutable default distribution.
/// `probe` contains only selector options followed by `--exec infocmp`.
fn hasExplicitDistribution(probe: []const []const u8) bool {
    var i: usize = 1;
    while (i < probe.len) : (i += 1) {
        const arg = probe[i];
        if (std.mem.eql(u8, arg, "--exec")) break;
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--distribution") or
            std.mem.eql(u8, arg, "--distribution-id") or std.mem.eql(u8, arg, "--system")) return true;
        // Every other selector takes a value; a value spelled `-d` is not
        // a distribution selector.
        i += 1;
    }
    return false;
}

const DefaultDistribution = [38]u16;

/// Read WSL's default ID without starting WSL or opening a distribution.
/// An absent, unreadable or malformed value cannot identify a cache context.
fn readDefaultDistribution() ?DefaultDistribution {
    if (comptime builtin.os.tag != .windows) return null;
    return defaultDistributionWithQuery(struct {
        fn query(buf: *[39]u16, bytes: *windows.DWORD) windows.LSTATUS {
            return windows.advapi32.RegGetValueW(
                windows.HKEY_CURRENT_USER,
                std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Lxss"),
                std.unicode.utf8ToUtf16LeStringLiteral("DefaultDistribution"),
                windows.advapi32.RRF.RT_REG_SZ | windows.advapi32.RRF.NOEXPAND |
                    windows.advapi32.RRF.SUBKEY_WOW6464KEY,
                null,
                @ptrCast(buf),
                bytes,
            );
        }
    }.query);
}

fn defaultDistributionWithQuery(query: anytype) ?DefaultDistribution {
    var buf: [39]u16 = @splat(0);
    var bytes: windows.DWORD = @sizeOf(@TypeOf(buf));
    if (query(&buf, &bytes) != @intFromEnum(windows.Win32Error.SUCCESS) or
        bytes != @sizeOf(@TypeOf(buf)) or buf[38] != 0) return null;
    // WSL stores a braced GUID. Validate before using it as an identity,
    // including rejecting embedded NULs and truncated registry strings.
    for (buf[0..38], 0..) |c, i| {
        switch (i) {
            0 => if (c != '{') return null,
            37 => if (c != '}') return null,
            9, 14, 19, 24 => if (c != '-') return null,
            else => if (c > 0x7f or !std.ascii.isHex(@intCast(c))) return null,
        }
    }
    return buf[0..38].*;
}

/// A local drive path only. Screen it before any file operation, including
/// executable lookup; GetDriveType reads the local drive table.
fn isLocalAbsolute(path: []const u8) bool {
    if (os_path.isNetworkOrDevicePath(path) or !windows_shell.isDriveAbsolutePath(path)) return false;
    return switch (os_windows.driveTypeForLetter(path[0])) {
        os_windows.DRIVE_FIXED, os_windows.DRIVE_REMOVABLE, os_windows.DRIVE_RAMDISK => true,
        else => false,
    };
}

/// Refuse reparse traversal at any component, before filesystem lookup can
/// follow a local-looking symlink/junction onto a share. Checking only the
/// final component with FILE_OPEN_REPARSE_POINT would not protect ancestors.
const LocalPath = enum { safe, missing, unsafe };
fn localPathState(path: []const u8) LocalPath {
    if (comptime builtin.os.tag != .windows) return .unsafe;
    if (!isLocalAbsolute(path)) return .unsafe;
    var handle: windows.HANDLE = undefined;
    const status = windows_shell.ntOpenDontReparse(path, windows.FILE_READ_ATTRIBUTES, 0, &handle) orelse
        return .unsafe;
    switch (status) {
        .SUCCESS => {},
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return .missing,
        else => return .unsafe,
    }
    std.posix.close(handle);
    return .safe;
}

/// Resolve the shell's explicit .exe using its launch cwd and PATH. Stop at
/// an unsafe search directory rather than touch it or verify a later binary
/// that the shell might never reach. Direct WSL argv are normally absolute.
fn localExecutable(alloc: Allocator, env: *const EnvMap, exe: []const u8, cwd: []const u8) !?[]u8 {
    if (os_path.isNetworkOrDevicePath(exe) or localPathState(cwd) != .safe) return null;
    if (!std.ascii.endsWithIgnoreCase(exe, ".exe")) return null;
    if (std.fs.path.isAbsolute(exe) or std.mem.indexOfAny(u8, exe, "/\\") != null) {
        const path = try std.fs.path.resolve(alloc, &.{ cwd, exe });
        if (localPathState(path) == .safe) return path;
        alloc.free(path);
        return null;
    }
    // CMD omits cwd from its executable search when this opt-out is present,
    // even when its value is empty. Never probe an executable it would skip.
    if (env.get("NoDefaultCurrentDirectoryInExePath") == null) {
        const here = try std.fs.path.join(alloc, &.{ cwd, exe });
        const state = localPathState(here);
        if (state == .safe) return here;
        alloc.free(here);
        if (state == .unsafe) return null;
    }
    var paths = std.mem.splitScalar(u8, env.get("PATH") orelse "", ';');
    while (paths.next()) |entry| {
        const dir = std.mem.trim(u8, entry, "\"");
        if (dir.len == 0) continue;
        switch (localPathState(dir)) {
            .missing => continue,
            .unsafe => return null,
            .safe => {},
        }
        const path = try std.fs.path.join(alloc, &.{ dir, exe });
        const state = localPathState(path);
        if (state == .safe) return path;
        alloc.free(path);
        if (state == .unsafe) return null;
    }
    return null;
}

/// Fingerprint the launch environment in key order. WSLENV can
/// forward HOME, PATH, or any other lookup input, not just TERMINFO. Values
/// never leave this hash; the cache and logs contain no environment data.
/// The per-surface ID is omitted unless explicitly forwarded into WSL.
fn probeKey(alloc: Allocator, env: *const EnvMap, argv: []const []const u8, cwd: []const u8, default_distro: ?DefaultDistribution) !u64 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);
    var it = env.iterator();
    while (it.next()) |entry| {
        // Surface IDs differ in every tab but cannot affect WSL's lookup
        // unless the user explicitly forwards them. Keep shared questions
        // shared, including negative answers for a hung WSL service.
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "GHOSTTY_SURFACE_ID") and
            !listed(env.get("WSLENV") orelse "", "GHOSTTY_SURFACE_ID")) continue;
        try keys.append(alloc, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(if (default_distro != null) &.{1} else &.{0});
    if (default_distro) |id| hasher.update(std.mem.sliceAsBytes(&id));
    for (argv) |arg| {
        hasher.update(arg);
        hasher.update(&.{0});
    }
    hasher.update(cwd);
    hasher.update(&.{0});
    for (keys.items) |key| {
        hasher.update(key);
        hasher.update(&.{0});
        hasher.update(env.get(key).?);
        hasher.update(&.{0});
    }
    return hasher.final();
}

/// What distributions have answered, by a hash of the probe command line and
/// of the variables that steer where the probe looks for terminfo. Asking
/// costs a `wsl.exe` start, 200 ms or more, and a restored window opens
/// several tabs at once, so ask once; a probe that times out is a "no" too, so
/// a hung WSL service stalls one tab and not each in turn. An install made
/// while noctty runs is therefore seen by the next noctty, not the next tab.
/// The lock covers the table only: a tab waits for a probe of its own question
/// and for nothing else.
/// Implicit selections include the current registry default ID in their key;
/// an unavailable ID bypasses the cache so a default change is still seen.
const Answer = enum { pending, yes, no };
var probe_cache: std.AutoHashMapUnmanaged(u64, Answer) = .empty;
var probe_mutex: std.Thread.Mutex = .{};
var probe_done: std.Thread.Condition = .{};

/// Whether the distribution that `argv` (a `wsl.exe` launch) starts has a
/// terminfo entry for `term`, asked of the distribution itself with
/// `infocmp`, so that its own search path and the launch user's `~/.terminfo`
/// count. The probe runs in the launch's environment `env`, which decides what
/// `WSLENV` carries into the distribution (`TERMINFO`, say). Any failure,
/// including a missing `infocmp` and a timeout, answers no.
fn distroHasTerminfo(
    alloc: Allocator,
    env: *const EnvMap,
    argv: []const [:0]const u8,
    term: []const u8,
    launch_cwd: ?[]const u8,
) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (argv.len == 0) return false;

    const probe = (probeArgv(alloc, argv, term) catch return false) orelse return false;
    defer alloc.free(probe);
    const inherited_cwd = if (launch_cwd == null) std.process.getCwdAlloc(alloc) catch return false else null;
    defer if (inherited_cwd) |cwd| alloc.free(cwd);
    const cwd = launch_cwd orelse inherited_cwd.?;
    const exe = (localExecutable(alloc, env, probe[0], cwd) catch return false) orelse return false;
    defer alloc.free(exe);
    probe[0] = exe;
    return cachedProbeWithHost(alloc, env, probe, cwd, struct {
        const run = runProbe;
        const defaultDistribution = readDefaultDistribution;
    });
}

fn cachedProbeWithHost(
    alloc: Allocator,
    env: *const EnvMap,
    probe: []const []const u8,
    cwd: []const u8,
    comptime Host: type,
) bool {
    const default_distro: ?DefaultDistribution = if (hasExplicitDistribution(probe)) null else Host.defaultDistribution() orelse return Host.run(alloc, env, probe, cwd) orelse false;
    const key = probeKey(alloc, env, probe, cwd, default_distro) catch return false;
    // Bind the question to the ID we hashed, even if the default switches
    // A -> B -> A while a slow probe starts. The session launch stays implicit.
    var id_arg: [38]u8 = undefined;
    const pinned = if (default_distro != null) alloc.alloc([]const u8, probe.len + 2) catch return false else null;
    defer if (pinned) |args| alloc.free(args);
    if (default_distro) |id| {
        for (id, &id_arg) |c, *dest| dest.* = @intCast(c);
        pinned.?[0] = probe[0];
        pinned.?[1] = "--distribution-id";
        pinned.?[2] = &id_arg;
        @memcpy(pinned.?[3..], probe[1..]);
    }

    probe_mutex.lock();
    while (true) {
        const known = probe_cache.get(key) orelse break;
        switch (known) {
            .yes, .no => {
                probe_mutex.unlock();
                if (!defaultStillMatches(default_distro, Host)) return false;
                return known == .yes;
            },
            // Another tab is asking the same question.
            .pending => probe_done.wait(&probe_mutex),
        }
    }
    probe_cache.put(std.heap.page_allocator, key, .pending) catch {
        probe_mutex.unlock();
        return false;
    };
    probe_mutex.unlock();

    const answer = if (defaultStillMatches(default_distro, Host)) result: {
        const probed = Host.run(alloc, env, pinned orelse probe, cwd);
        // A slow probe may have run while the user changed WSL's default.
        // Do not retain or forward that answer under the earlier identity.
        break :result if (defaultStillMatches(default_distro, Host)) probed else null;
    } else null;

    probe_mutex.lock();
    defer probe_mutex.unlock();
    if (answer) |yes| {
        probe_cache.putAssumeCapacity(key, if (yes) .yes else .no);
    } else {
        _ = probe_cache.remove(key);
    }
    probe_done.broadcast();
    return answer orelse false;
}

fn defaultStillMatches(expected: ?DefaultDistribution, comptime Host: type) bool {
    const id = expected orelse return true;
    const current = Host.defaultDistribution() orelse return false;
    return std.mem.eql(u16, &id, &current);
}

/// Run the probe. Null when it did not start, so a later tab may try again.
fn runProbe(alloc: Allocator, env: *const EnvMap, probe: []const []const u8, cwd: []const u8) ?bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (probe.len == 0 or localPathState(cwd) != .safe or localPathState(probe[0]) != .safe) return null;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const temp = arena.allocator();
    const args = temp.alloc([:0]const u8, probe.len) catch return null;
    for (probe, args) |arg, *dest| dest.* = temp.dupeZ(u8, arg) catch return null;
    var sa: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .bInheritHandle = windows.TRUE,
        .lpSecurityDescriptor = null,
    };
    const nul = windows.OpenFile(&.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' }, .{
        .access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE | windows.SYNCHRONIZE,
        .share_access = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        .creation = windows.OPEN_EXISTING,
        .sa = &sa,
    }) catch return null;
    defer std.posix.close(nul);
    // Command uses an exact lpApplicationName for the absolute path. Unlike
    // std.Child, it never tries wsl.exe.cmd through the parent's PATHEXT.
    var child: Command = .{
        .path = args[0],
        .args = args,
        .env = env,
        .cwd = cwd,
        .stdin = .{ .handle = nul },
        .stdout = .{ .handle = nul },
        .stderr = .{ .handle = nul },
        .windows_create_no_window = true,
        .os_pre_exec = null,
        .rt_pre_exec = null,
        .rt_post_fork = null,
        .rt_pre_exec_info = undefined,
        .rt_post_fork_info = undefined,
    };
    child.start(temp) catch |err| {
        log.warn("terminfo probe did not start err={}", .{err});
        return null;
    };

    defer std.posix.close(child.pid.?);
    windows.WaitForSingleObjectEx(child.pid.?, probe_timeout_ms, false) catch |err| {
        log.warn("terminfo probe did not finish err={}", .{err});
        _ = windows.kernel32.TerminateProcess(child.pid.?, 1);
        windows.WaitForSingleObjectEx(child.pid.?, 5000, false) catch {};
        return false;
    };
    const result = child.wait(true) catch return false;
    return result.Exited == 0;
}

/// List the identity variables of `env` for a WSL launch, and `TERM` too when
/// `include_term`: the user chose it, so it is not probed.
pub fn forwardIdentity(env: *EnvMap, include_term: bool) !void {
    try forward(env, &identity_vars);
    if (include_term) try forward(env, &.{"TERM"});
}

/// The other half of `forwardIdentity`, for a TERM noctty chose: when the
/// distribution has an entry for `probe.term`, make it the `TERM` of `env` and
/// list it. That is not the `TERM` the Windows side settled on, which depends
/// on the Windows home having the entry and says nothing about the
/// distribution.
pub fn forwardProbedTerm(alloc: Allocator, env: *EnvMap, probe: Probe) !void {
    if (!distroHasTerminfo(alloc, env, probe.argv, probe.term, probe.cwd)) {
        log.info("WSL distribution has no terminfo entry for TERM={s}, leaving TERM to wsl.exe", .{probe.term});
        return;
    }
    try env.put("TERM", probe.term);
    try forward(env, &.{"TERM"});
}

test "forward adds the names the environment holds" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "ghostty");

    try forward(&env, &identity_vars);
    try std.testing.expectEqualStrings("COLORTERM/u:TERM_PROGRAM/u", env.get("WSLENV").?);
}

test "forward changes nothing without a name to add" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try forward(&env, &identity_vars);
    try std.testing.expectEqual(null, env.get("WSLENV"));

    try env.put("COLORTERM", "truecolor");
    try env.put("WSLENV", "COLORTERM/p");
    try forward(&env, &.{"COLORTERM"});
    try std.testing.expectEqualStrings("COLORTERM/p", env.get("WSLENV").?);
}

test "forward keeps the user's entries, flags and order" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "ghostty");
    try env.put("TERM_PROGRAM_VERSION", "1.3.2");
    try env.put("WSLENV", "GOPATH/l:USERPROFILE/p:TERM_PROGRAM/w");

    try forward(&env, &identity_vars);
    try std.testing.expectEqualStrings(
        "GOPATH/l:USERPROFILE/p:TERM_PROGRAM/w:COLORTERM/u:TERM_PROGRAM_VERSION/u",
        env.get("WSLENV").?,
    );
}

test "forward matches names exactly and lists each once" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("COLORTERM", "truecolor");
    try env.put("WSLENV", "COLORTERM2/p:xCOLORTERM:colorterm/u");

    try forward(&env, &identity_vars);
    try forward(&env, &identity_vars);
    try std.testing.expectEqualStrings(
        "COLORTERM2/p:xCOLORTERM:colorterm/u:COLORTERM/u",
        env.get("WSLENV").?,
    );
}

test "forward handles an empty WSLENV and stray separators" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM_PROGRAM", "ghostty");

    try env.put("WSLENV", "");
    try forward(&env, &identity_vars);
    try std.testing.expectEqualStrings("COLORTERM/u:TERM_PROGRAM/u", env.get("WSLENV").?);

    try env.put("WSLENV", ":");
    try forward(&env, &identity_vars);
    try std.testing.expectEqualStrings(":COLORTERM/u:TERM_PROGRAM/u", env.get("WSLENV").?);

    try env.put("WSLENV", "GOPATH/l:");
    try forward(&env, &identity_vars);
    try std.testing.expectEqualStrings("GOPATH/l:COLORTERM/u:TERM_PROGRAM/u", env.get("WSLENV").?);
}

test "forwardIdentity lists a TERM the user chose without probing" {
    var env = EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("COLORTERM", "truecolor");
    try env.put("TERM", "xterm-kitty");

    try forwardIdentity(&env, false);
    try std.testing.expectEqualStrings("COLORTERM/u", env.get("WSLENV").?);
    try forwardIdentity(&env, true);
    try std.testing.expectEqualStrings("COLORTERM/u:TERM/u", env.get("WSLENV").?);
}

test "probeArgv keeps the distribution and user selection" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        argv: []const [:0]const u8,
        expected: ?[]const []const u8,
    }{
        .{
            .argv = &.{"wsl.exe"},
            .expected = &.{ "wsl.exe", "--exec", "infocmp", "xterm-ghostty" },
        },
        // The probe needs the same cwd for relative terminfo databases.
        .{
            .argv = &.{ "C:\\Windows\\System32\\wsl.exe", "--cd", "~", "-d", "Ubuntu" },
            .expected = &.{ "C:\\Windows\\System32\\wsl.exe", "--cd", "~", "-d", "Ubuntu", "--exec", "infocmp", "xterm-ghostty" },
        },
        .{
            .argv = &.{ "wsl.exe", "--user", "root", "--distribution", "Debian", "--system", "--shell-type", "login" },
            .expected = &.{ "wsl.exe", "--user", "root", "--distribution", "Debian", "--system", "--exec", "infocmp", "xterm-ghostty" },
        },
        // Whatever follows `--`, `-e` or the first word is the command's.
        .{
            .argv = &.{ "wsl.exe", "-d", "Ubuntu", "--", "bash", "-d", "x" },
            .expected = &.{ "wsl.exe", "-d", "Ubuntu", "--exec", "infocmp", "xterm-ghostty" },
        },
        .{
            .argv = &.{ "wsl.exe", "-d", "Ubuntu", "sudo", "-u", "postgres", "psql" },
            .expected = &.{ "wsl.exe", "-d", "Ubuntu", "--exec", "infocmp", "xterm-ghostty" },
        },
        .{
            .argv = &.{ "wsl.exe", "-d", "Ubuntu", "ls", "-d", "/etc" },
            .expected = &.{ "wsl.exe", "-d", "Ubuntu", "--exec", "infocmp", "xterm-ghostty" },
        },
        // Not a session launch, or an option cut short: nothing to ask.
        .{ .argv = &.{ "wsl.exe", "--shutdown" }, .expected = null },
        .{ .argv = &.{ "wsl.exe", "-d", "Ubuntu", "--update" }, .expected = null },
        .{ .argv = &.{ "wsl.exe", "-d" }, .expected = null },
        .{ .argv = &.{ "wsl.exe", "-d", "%DISTRO%" }, .expected = null },
    };
    for (cases) |case| {
        const got = (try probeArgv(alloc, case.argv, "xterm-ghostty")) orelse {
            try std.testing.expectEqual(null, case.expected);
            continue;
        };
        defer alloc.free(got);
        const expected = case.expected.?;
        try std.testing.expectEqual(expected.len, got.len);
        for (expected, got) |want, have| try std.testing.expectEqualStrings(want, have);
    }
}

test "launchArgv finds a WSL launch in either command form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A direct command is its own argv.
    const direct: []const [:0]const u8 = &.{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu" };
    try std.testing.expectEqual(direct, (try launchArgv(alloc, direct, false)).?);

    // `command = wsl.exe -d Ubuntu` runs as `cmd.exe /C <line>`.
    const shell: []const [:0]const u8 = &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "wsl.exe -d \"My Distro\" ~" };
    const words = (try launchArgv(alloc, shell, true)).?;
    try std.testing.expectEqual(@as(usize, 4), words.len);
    for (&[_][]const u8{ "wsl.exe", "-d", "My Distro", "~" }, words) |want, have| {
        try std.testing.expectEqualStrings(want, have);
    }
    const quoted: []const [:0]const u8 = &.{ "cmd.exe", "/C", "\"C:\\Program Files\\WSL\\wsl.exe\" --system" };
    try std.testing.expectEqualStrings(
        "C:\\Program Files\\WSL\\wsl.exe",
        (try launchArgv(alloc, quoted, true)).?[0],
    );

    // Anything else is not.
    try std.testing.expectEqual(null, try launchArgv(alloc, &.{ "C:\\Windows\\System32\\cmd.exe", "/C", "echo wsl.exe" }, true));
    try std.testing.expectEqual(null, try launchArgv(alloc, &.{ "pwsh.exe", "-NoLogo" }, false));
    try std.testing.expectEqual(null, try launchArgv(alloc, &.{}, false));
}

test "automatic TERM refuses unresolved direct executables" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    for ([_][]const u8{
        "wsl.exe",                    ".\\wsl.exe",           "C:wsl.exe", "\\wsl.exe",
        "\\\\server\\share\\wsl.exe", "\\\\.\\pipe\\wsl.exe",
    }) |exe| try std.testing.expect(!canProbeDirect(exe));
    const cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const exe = try std.fs.path.join(std.testing.allocator, &.{ cwd, "wsl.exe" });
    defer std.testing.allocator.free(exe);
    try std.testing.expect(canProbeDirect(exe));
}

test "automatic TERM is limited to one reproducible shell command" {
    try std.testing.expect(canProbeShell("wsl.exe -d Ubuntu --exec bash"));
    try std.testing.expect(canProbeShell("\"C:\\Program Files\\WSL\\wsl.exe\" --exec echo \"a & b\""));
    for ([_][]const u8{
        "wsl.exe -d Ubuntu -e true & wsl.exe -d kali-linux",
        "wsl.exe | other.exe",
        "wsl.exe > output.txt",
        "wsl.exe -d %DISTRO%",
        "wsl.exe -d !DISTRO!",
        "wsl.exe -d My^ Distro",
        "wsl.exe \"unfinished",
        "wsl.exe --cd \"/tmp/probe\\\\\" --exec tput colors",
        "wsl.exe --cd \"/tmp/\"\"probe\" --exec tput colors",
        "wsl.exe --cd /tmp/probe\x0c --exec tput colors",
        "wsl.exe\nother.exe",
    }) |line| try std.testing.expect(!canProbeShell(line));
}

test "CMD AutoRun must be absent in both hives and registry views" {
    const Queries = struct {
        var calls: usize = 0;
        var bad_call: ?usize = null;
        var status: windows.LSTATUS = 0;
        fn query(_: windows.HKEY, _: windows.DWORD) windows.LSTATUS {
            defer calls += 1;
            if (bad_call == calls) return status;
            return @intFromEnum(windows.Win32Error.FILE_NOT_FOUND);
        }
    };
    Queries.calls = 0;
    Queries.bad_call = null;
    try std.testing.expect(cmdAutoRunAbsentWithQuery(Queries.query));
    try std.testing.expectEqual(@as(usize, 4), Queries.calls);
    for (0..4) |bad| {
        for ([_]windows.LSTATUS{ 0, @intFromEnum(windows.Win32Error.ACCESS_DENIED) }) |status| {
            Queries.calls = 0;
            Queries.bad_call = bad;
            Queries.status = status;
            try std.testing.expect(!cmdAutoRunAbsentWithQuery(Queries.query));
        }
    }
}

test "probeArgv refuses an infocmp option as the terminal name" {
    try std.testing.expectEqual(null, try probeArgv(std.testing.allocator, &.{"wsl.exe"}, "-V"));
    try std.testing.expectEqual(null, try probeArgv(std.testing.allocator, &.{"wsl.exe"}, ""));
}

test "probe selectors distinguish explicit distributions before the command" {
    const cases = [_]struct { argv: []const [:0]const u8, cache: bool }{
        .{ .argv = &.{"wsl.exe"}, .cache = false },
        .{ .argv = &.{ "wsl.exe", "-u", "root" }, .cache = false },
        .{ .argv = &.{ "wsl.exe", "--cd", "/tmp" }, .cache = false },
        .{ .argv = &.{ "wsl.exe", "--cd", "-d" }, .cache = false },
        .{ .argv = &.{ "wsl.exe", "--exec", "echo", "-d", "Ubuntu" }, .cache = false },
        .{ .argv = &.{ "wsl.exe", "echo", "-d", "Ubuntu" }, .cache = false },
        .{ .argv = &.{ "wsl.exe", "-d", "Ubuntu" }, .cache = true },
        .{ .argv = &.{ "wsl.exe", "--distribution", "Ubuntu" }, .cache = true },
        .{ .argv = &.{ "wsl.exe", "-u", "root", "--distribution-id", "id" }, .cache = true },
        .{ .argv = &.{ "wsl.exe", "--system" }, .cache = true },
    };
    for (cases) |case| {
        const probe = (try probeArgv(std.testing.allocator, case.argv, "xterm-ghostty")).?;
        defer std.testing.allocator.free(probe);
        try std.testing.expectEqual(case.cache, hasExplicitDistribution(probe));
    }
}

test "WSLCACHE implicit launches reuse answers and miss after a default change" {
    const Host = struct {
        var calls: usize = 0;
        var distro: ?[38]u16 = null;
        var answer: ?bool = true;
        var next_distro: ?[38]u16 = null;
        var aba = false;
        fn defaultDistribution() ?[38]u16 {
            return distro;
        }
        fn run(_: Allocator, _: *const EnvMap, args: []const []const u8, _: []const u8) ?bool {
            calls += 1;
            if (distro) |id| {
                std.debug.assert(std.mem.eql(u8, args[1], "--distribution-id"));
                std.debug.assert(args[2].len == id.len);
                for (id, args[2]) |expected, actual| std.debug.assert(expected == actual);
            }
            if (aba) {
                const captured = distro;
                distro = next_distro;
                // An unpinned probe would answer for the intervening default.
                const selected_first = std.mem.eql(u8, args[2], "{11111111-1111-1111-1111-111111111111}");
                distro = captured;
                return selected_first;
            }
            if (next_distro) |id| distro = id;
            return answer;
        }
    };
    defer {
        probe_cache.deinit(std.heap.page_allocator);
        probe_cache = .empty;
    }
    const alloc = std.testing.allocator;
    var env = EnvMap.init(alloc);
    defer env.deinit();
    const probe = &[_][]const u8{ "C:\\fake\\wsl.exe", "--exec", "infocmp", "xterm-ghostty" };
    const first = std.unicode.utf8ToUtf16LeStringLiteral("{11111111-1111-1111-1111-111111111111}")[0..38].*;
    const second = std.unicode.utf8ToUtf16LeStringLiteral("{22222222-2222-2222-2222-222222222222}")[0..38].*;
    Host.calls = 0;
    Host.distro = first;
    Host.answer = true;
    try std.testing.expect(cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
    try std.testing.expect(cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
    try std.testing.expectEqual(@as(usize, 1), Host.calls);
    Host.distro = second;
    Host.answer = false;
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
    try std.testing.expectEqual(@as(usize, 2), Host.calls);
    Host.distro = first;
    try std.testing.expect(cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
    try std.testing.expectEqual(@as(usize, 2), Host.calls);
    // Failure to identify the default must bypass even a positive cache.
    Host.distro = null;
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
    try std.testing.expectEqual(@as(usize, 4), Host.calls);
    // Keep launch context in the question even with the same default ID.
    Host.distro = first;
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\two", Host));
    try env.put("WSLENV", "HOME/u");
    try env.put("HOME", "/other");
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\two", Host));
    try std.testing.expectEqual(@as(usize, 6), Host.calls);
    // A failed start is not cached; subsequent launches can try again.
    Host.answer = null;
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\retry", Host));
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\retry", Host));
    try std.testing.expectEqual(@as(usize, 8), Host.calls);
    // Changing default during a probe must discard its answer and pending
    // entry. Switching back must ask again, rather than find a poisoned yes.
    Host.answer = true;
    Host.next_distro = second;
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\race", Host));
    Host.next_distro = null;
    Host.distro = first;
    Host.answer = false;
    try std.testing.expect(!cachedProbeWithHost(alloc, &env, probe, "C:\\race", Host));
    try std.testing.expectEqual(@as(usize, 10), Host.calls);
    Host.aba = true;
    Host.next_distro = second;
    try std.testing.expect(cachedProbeWithHost(alloc, &env, probe, "C:\\aba", Host));
    Host.aba = false;
    Host.next_distro = null;
    Host.answer = false;
    try std.testing.expect(cachedProbeWithHost(alloc, &env, probe, "C:\\aba", Host));
    try std.testing.expectEqual(@as(usize, 11), Host.calls);
}

test "WSLCACHE explicit selections reuse answers without reading the default" {
    const Host = struct {
        var calls: usize = 0;
        fn defaultDistribution() ?DefaultDistribution {
            unreachable;
        }
        fn run(_: Allocator, _: *const EnvMap, _: []const []const u8, _: []const u8) ?bool {
            calls += 1;
            return true;
        }
    };
    defer {
        probe_cache.deinit(std.heap.page_allocator);
        probe_cache = .empty;
    }
    Host.calls = 0;
    const alloc = std.testing.allocator;
    var env = EnvMap.init(alloc);
    defer env.deinit();
    for ([_][]const [:0]const u8{
        &.{ "wsl.exe", "-d", "Ubuntu" },
        &.{ "wsl.exe", "--distribution", "Ubuntu" },
        &.{ "wsl.exe", "--distribution-id", "id" },
        &.{ "wsl.exe", "--system" },
    }, 1..) |argv, expected| {
        const probe = (try probeArgv(alloc, argv, "xterm-ghostty")) orelse return error.TestUnexpectedResult;
        defer alloc.free(probe);
        try std.testing.expect(cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
        try std.testing.expect(cachedProbeWithHost(alloc, &env, probe, "C:\\one", Host));
        try std.testing.expectEqual(expected, Host.calls);
    }
}

test "WSLCACHE registry query rejects errors and malformed default IDs" {
    const Query = struct {
        const id = std.unicode.utf8ToUtf16LeStringLiteral("{11111111-1111-1111-1111-111111111111}")[0..38].* ++ [_]u16{0};
        var data: [39]u16 = id;
        var size: windows.DWORD = @sizeOf(@TypeOf(data));
        var status: windows.LSTATUS = 0;
        fn query(buf: *[39]u16, bytes: *windows.DWORD) windows.LSTATUS {
            std.debug.assert(bytes.* == @sizeOf(@TypeOf(data)));
            buf.* = data;
            bytes.* = size;
            return status;
        }
    };
    Query.data = Query.id;
    Query.size = @sizeOf(@TypeOf(Query.data));
    Query.status = 0;
    try std.testing.expectEqual(Query.id[0..38].*, defaultDistributionWithQuery(Query.query));
    for ([_]windows.Win32Error{ .FILE_NOT_FOUND, .ACCESS_DENIED, .MORE_DATA, .UNSUPPORTED_TYPE }) |err| {
        Query.status = @intFromEnum(err);
        try std.testing.expectEqual(null, defaultDistributionWithQuery(Query.query));
    }
    Query.status = 0;
    for ([_]windows.DWORD{ 0, 1, 2, 76, 77, 80 }) |size| {
        Query.size = size;
        try std.testing.expectEqual(null, defaultDistributionWithQuery(Query.query));
    }
    Query.size = @sizeOf(@TypeOf(Query.data));
    for (0..39) |i| {
        Query.data = Query.id;
        Query.data[i] = if (i == 38) 'x' else 0;
        try std.testing.expectEqual(null, defaultDistributionWithQuery(Query.query));
    }
    Query.data = Query.id;
    Query.data[1] = 'g';
    try std.testing.expectEqual(null, defaultDistributionWithQuery(Query.query));
}

test "probeKey distinguishes forwarded HOME and cwd independent of map order" {
    const alloc = std.testing.allocator;
    var a = EnvMap.init(alloc);
    defer a.deinit();
    var b = EnvMap.init(alloc);
    defer b.deinit();
    try a.put("WSLENV", "HOME/u:TERMINFO/u");
    try a.put("HOME", "/tmp/with-entry");
    try a.put("TERMINFO", "terminfo");
    try b.put("TERMINFO", "terminfo");
    try b.put("HOME", "/tmp/with-entry");
    try b.put("WSLENV", "HOME/u:TERMINFO/u");
    const argv = &[_][]const u8{ "C:\\Windows\\System32\\wsl.exe", "--exec", "infocmp", "xterm-ghostty" };
    const key = try probeKey(alloc, &a, argv, "C:\\one", null);
    try std.testing.expectEqual(key, try probeKey(alloc, &b, argv, "C:\\one", null));
    try b.put("HOME", "/tmp/without-entry");
    try std.testing.expect(key != try probeKey(alloc, &b, argv, "C:\\one", null));
    try std.testing.expect(key != try probeKey(alloc, &a, argv, "C:\\two", null));
    try a.put("GHOSTTY_SURFACE_ID", "1");
    try std.testing.expectEqual(key, try probeKey(alloc, &a, argv, "C:\\one", null));
    try a.put("GHOSTTY_SURFACE_ID", "2");
    try std.testing.expectEqual(key, try probeKey(alloc, &a, argv, "C:\\one", null));
    try a.put("WSLENV", "HOME/u:TERMINFO/u:GHOSTTY_SURFACE_ID/u");
    const forwarded = try probeKey(alloc, &a, argv, "C:\\one", null);
    try a.put("GHOSTTY_SURFACE_ID", "3");
    try std.testing.expect(forwarded != try probeKey(alloc, &a, argv, "C:\\one", null));
}

test "WSL guarded paths map DOS roots without an unchecked fallback" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const Reject = struct {
        fn map(_: [*:0]const u16, _: []u16) ?[]const u16 {
            return null;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "safe.txt", .data = "safe" });
    const path = try tmp.dir.realpathAlloc(alloc, "safe.txt");
    defer alloc.free(path);
    os_windows.TestHooks.direct_volume_mapping = Reject.map;
    defer os_windows.TestHooks.direct_volume_mapping = null;
    try std.testing.expectEqual(LocalPath.unsafe, localPathState(path));
    os_windows.TestHooks.direct_volume_mapping = os_windows.TestHooks.unavailableVolume;
    try std.testing.expect(localPathState(path) != .safe);
    os_windows.TestHooks.direct_volume_mapping = null;
    try std.testing.expectEqual(LocalPath.safe, localPathState(path));
    try tmp.dir.deleteFile("safe.txt");
    try std.testing.expectEqual(LocalPath.missing, localPathState(path));
}

test "WSL executable probe enters production DOS mapping" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const Reject = struct {
        fn map(_: [*:0]const u16, _: []u16) ?[]const u16 {
            return null;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "wsl.exe", .data = "not executed" });
    const cwd = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    var env = EnvMap.init(alloc);
    defer env.deinit();
    os_windows.TestHooks.direct_volume_mapping = Reject.map;
    defer os_windows.TestHooks.direct_volume_mapping = null;
    const refused = try localExecutable(alloc, &env, "wsl.exe", cwd);
    defer if (refused) |path| alloc.free(path);
    try std.testing.expectEqual(null, refused);
    os_windows.TestHooks.direct_volume_mapping = os_windows.TestHooks.unavailableVolume;
    const redirected = try localExecutable(alloc, &env, "wsl.exe", cwd);
    defer if (redirected) |path| alloc.free(path);
    try std.testing.expectEqual(null, redirected);
    os_windows.TestHooks.direct_volume_mapping = null;
    const found = (try localExecutable(alloc, &env, "wsl.exe", cwd)) orelse return error.TestUnexpectedResult;
    defer alloc.free(found);
    const expected = try std.fs.path.join(alloc, &.{ cwd, "wsl.exe" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, found);
}

test "localExecutable refuses remote device and ambiguous search paths" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const cwd = try td.dir.realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    var env = EnvMap.init(alloc);
    defer env.deinit();
    // No filesystem operation may follow these path shapes. The fake share
    // does not need to exist and must never be contacted by this test.
    for ([_][]const u8{ "\\\\unavailable\\share\\wsl.exe", "\\/unavailable/share/wsl.exe", "\\??\\UNC\\unavailable\\share\\wsl.exe" }) |exe| {
        try std.testing.expectEqual(null, try localExecutable(alloc, &env, exe, cwd));
    }
    try env.put("PATH", "\\\\unavailable\\share;C:\\Windows\\System32");
    try std.testing.expectEqual(null, try localExecutable(alloc, &env, "wsl.exe", cwd));
    try std.testing.expectEqual(null, try localExecutable(alloc, &env, "wsl", cwd));

    // An empty opt-out is still set. Even with a cwd executable planted,
    // the probe follows CMD to PATH (unsafe here, so it gives up).
    var planted = try td.dir.createFile("wsl.exe", .{});
    planted.close();
    try env.put("NoDefaultCurrentDirectoryInExePath", "");
    try std.testing.expectEqual(null, try localExecutable(alloc, &env, "wsl.exe", cwd));

    // CMD skips a removed local directory and can find a later candidate.
    const missing = try std.fs.path.join(alloc, &.{ cwd, "removed-tool" });
    defer alloc.free(missing);
    const search = try std.fmt.allocPrint(alloc, "{s};{s}", .{ missing, cwd });
    defer alloc.free(search);
    try env.put("PATH", search);
    const found = (try localExecutable(alloc, &env, "wsl.exe", cwd)).?;
    defer alloc.free(found);
    const expected = try std.fs.path.join(alloc, &.{ cwd, "wsl.exe" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, found);
}

test "probe paths refuse ancestor and final symlinks without following them" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try td.dir.makeDir("target");
    var exe_file = try td.dir.createFile("target/wsl.exe", .{});
    exe_file.close();
    const cwd = try td.dir.realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    const target = try std.fs.path.join(alloc, &.{ cwd, "target" });
    defer alloc.free(target);
    td.dir.symLink(target, "link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try td.dir.symLink("target/wsl.exe", "wsl.exe", .{});
    const good = try std.fs.path.join(alloc, &.{ target, "wsl.exe" });
    defer alloc.free(good);
    const linked_dir = try std.fs.path.join(alloc, &.{ cwd, "link" });
    defer alloc.free(linked_dir);
    const linked_exe = try std.fs.path.join(alloc, &.{ linked_dir, "wsl.exe" });
    defer alloc.free(linked_exe);
    try std.testing.expectEqual(LocalPath.safe, localPathState(good));
    try std.testing.expectEqual(LocalPath.unsafe, localPathState(linked_exe));
    var env = EnvMap.init(alloc);
    defer env.deinit();
    try env.put("PATH", target);
    // A reparse candidate must stop search, not authorize the later PATH exe.
    try std.testing.expectEqual(null, try localExecutable(alloc, &env, "wsl.exe", cwd));
    try std.testing.expectEqual(null, try localExecutable(alloc, &env, linked_exe, cwd));
    try std.testing.expectEqual(null, try localExecutable(alloc, &env, good, linked_dir));
    try env.put("NoDefaultCurrentDirectoryInExePath", "");
    try env.put("PATH", linked_dir);
    try std.testing.expectEqual(null, try localExecutable(alloc, &env, "wsl.exe", cwd));
}

test "runProbe does not execute a PATHEXT sibling of a missing exe" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const cwd = try td.dir.realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    const exe = try std.fs.path.join(alloc, &.{ cwd, "wsl.exe" });
    defer alloc.free(exe);
    var script = try td.dir.createFile("wsl.exe.cmd", .{});
    try script.writeAll("@echo off\r\necho executed>probe-executed.txt\r\nexit /b 0\r\n");
    script.close();
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    try env.put("PATHEXT", ".COM;.EXE;.BAT;.CMD");
    try std.testing.expectEqual(null, runProbe(alloc, &env, &.{ exe, "--exec", "infocmp", "xterm-ghostty" }, cwd));
    try std.testing.expectError(error.FileNotFound, td.dir.access("probe-executed.txt", .{}));
}
