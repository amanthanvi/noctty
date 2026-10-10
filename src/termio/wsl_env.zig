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
    const selecting = [_][]const u8{ "-d", "--distribution", "--distribution-id", "-u", "--user" };
    // Options that take a value the probe has no use for.
    const skipping = [_][]const u8{ "--cd", "--shell-type" };
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
fn probeArgv(alloc: Allocator, argv: []const [:0]const u8, term: []const u8) Allocator.Error!?[]const []const u8 {
    const selector = (try selectorArgs(alloc, argv)) orelse return null;
    defer alloc.free(selector);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, argv[0]);
    try out.appendSlice(alloc, selector);
    try out.appendSlice(alloc, &.{ "--exec", "infocmp", term });
    return try out.toOwnedSlice(alloc);
}

/// What distributions have answered, by a hash of the probe command line and
/// of the variables that steer where the probe looks for terminfo. Asking
/// costs a `wsl.exe` start, 200 ms or more, and a restored window opens
/// several tabs at once, so ask once; a probe that times out is a "no" too, so
/// a hung WSL service stalls one tab and not each in turn. An install made
/// while noctty runs is therefore seen by the next noctty, not the next tab.
/// The lock covers the table only: a tab waits for a probe of its own question
/// and for nothing else.
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
) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (argv.len == 0) return false;

    const probe = (probeArgv(alloc, argv, term) catch return false) orelse return false;
    defer alloc.free(probe);

    var hasher = std.hash.Wyhash.init(0);
    for (probe) |arg| {
        hasher.update(arg);
        hasher.update(&.{0});
    }
    for ([_][]const u8{ "WSLENV", "TERMINFO", "TERMINFO_DIRS" }) |name| {
        hasher.update(env.get(name) orelse "");
        hasher.update(&.{0});
    }
    const key = hasher.final();

    probe_mutex.lock();
    while (true) {
        const known = probe_cache.get(key) orelse break;
        switch (known) {
            .yes => {
                probe_mutex.unlock();
                return true;
            },
            .no => {
                probe_mutex.unlock();
                return false;
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

    const answer = runProbe(alloc, env, probe);

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

/// Run the probe. Null when it did not start, so a later tab may try again.
fn runProbe(alloc: Allocator, env: *const EnvMap, probe: []const []const u8) ?bool {
    var child = std.process.Child.init(probe, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    child.env_map = env;
    child.spawn() catch |err| {
        log.warn("terminfo probe did not start err={}", .{err});
        return null;
    };

    windows.WaitForSingleObjectEx(child.id, probe_timeout_ms, false) catch |err| {
        log.warn("terminfo probe did not finish err={}", .{err});
        _ = child.kill() catch {};
        return false;
    };
    return switch (child.wait() catch return false) {
        .Exited => |code| code == 0,
        else => false,
    };
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
    if (!distroHasTerminfo(alloc, env, probe.argv, probe.term)) {
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
        // The options noctty puts in front: `--cd` and its value are not the
        // probe's.
        .{
            .argv = &.{ "C:\\Windows\\System32\\wsl.exe", "--cd", "~", "-d", "Ubuntu" },
            .expected = &.{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu", "--exec", "infocmp", "xterm-ghostty" },
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
