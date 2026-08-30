const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const win32 = @import("../os/windows.zig");
const Command = @import("command.zig").Command;
const windows_shell_types = @import("windows_shell_types.zig");
const windows_ssh_hosts = @import("windows_ssh_hosts.zig");
const log = std.log.scoped(.windows_shell);
const windows = std.os.windows;

const wsl_probe_timeout_ms: windows.DWORD = 1500;
const wsl_list_timeout_ms: windows.DWORD = 1500;
var wsl_probe_mutex: std.Thread.Mutex = .{};
var wsl_probe_cache: ?bool = null;
var wsl_profile_probe_cache: ?bool = null;
var ssh_missing_mutex: std.Thread.Mutex = .{};
var ssh_missing_logged = false;
const wsl_shell_integration_next_step =
    "Enable shell integration inside the selected WSL shell startup.";

pub const DefaultShell = enum {
    wsl,
    pwsh,
    powershell,
    cmd,
};

pub const ProfileKind = windows_shell_types.ProfileKind;
pub const Utf8Console = windows_shell_types.Utf8Console;

/// ANSI/OEM code pages where forcing 65001 would mojibake legacy programs.
/// 932 Shift-JIS, 936 GBK, 949 Unified Hangul Code, 950 Big5, 1361 Johab.
const legacy_cjk_code_pages = [_]u32{ 932, 936, 949, 950, 1361 };

pub fn shouldApplyUtf8Console(
    mode: Utf8Console,
    ansi_code_page: u32,
    oem_code_page: u32,
) bool {
    return switch (mode) {
        .never => false,
        .always => true,
        .auto => !isLegacyCjkCodePage(ansi_code_page) and
            !isLegacyCjkCodePage(oem_code_page),
    };
}

pub fn shouldApplyUtf8ConsoleForCurrentSystem(mode: Utf8Console) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return shouldApplyUtf8Console(mode, win32.GetACP(), win32.GetOEMCP());
}

fn isLegacyCjkCodePage(code_page: u32) bool {
    for (legacy_cjk_code_pages) |legacy| {
        if (code_page == legacy) return true;
    }
    return false;
}

pub const ShellIntegrationSupport = enum {
    automatic,
    shell_managed,
    manual,
    unavailable,
};

pub const ShellIntegrationDiagnostic = struct {
    support: ShellIntegrationSupport,
    summary: []const u8,
    next_step: ?[]const u8 = null,
};

pub const Profile = struct {
    kind: ProfileKind,
    key: []const u8,
    label: []const u8,
    palette_title: ?[]const u8 = null,
    command: Command,

    pub fn deinit(self: *Profile, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.label);
        if (self.palette_title) |value| alloc.free(value);
        self.command.deinit(alloc);
    }
};

pub const ProfileDiscovery = struct {
    profiles: []Profile,
    complete: bool,
};

/// Determine the default shell order for Windows:
/// WSL -> pwsh -> powershell -> cmd.
pub fn defaultShell(alloc: Allocator) !DefaultShell {
    return try defaultShellWithLookupAndProbe(alloc, lookupExecutable, probeWslExecutableCached);
}

/// Build the default Windows command. This intentionally returns a direct
/// command so we avoid the extra `cmd.exe /C` trampoline on the hot path.
pub fn defaultCommand(alloc: Allocator) !Command {
    return try defaultCommandWithLookupAndProbe(alloc, lookupExecutable, probeWslExecutableCached);
}

/// Build a safe default Windows command that explicitly skips WSL.
/// This is used by the Win32 preview runtime while the WSL startup path
/// is being stabilized independently from renderer bring-up.
pub fn defaultCommandNoWsl(alloc: Allocator) !Command {
    return try defaultCommandNoWslWithLookup(alloc, lookupExecutable);
}

/// Build a conservative preview command for the Win32 runtime.
/// This prefers `cmd.exe` first because its startup semantics are simpler
/// than PowerShell while the native Windows runtime is still under bring-up.
pub fn previewCommand(alloc: Allocator) !Command {
    return try previewCommandWithLookup(alloc, lookupExecutable);
}

pub fn listProfiles(alloc: Allocator, include_ssh_hosts: bool) ![]Profile {
    const order_hint = detectProfileOrderHint(alloc);
    defer if (order_hint) |value| alloc.free(value);

    const shell_profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookupExecutable,
        probeWslExecutableCached,
        listWslDistros,
        order_hint,
        null,
    );
    return try appendConfiguredSshProfiles(alloc, shell_profiles, include_ssh_hosts, null);
}

pub fn discoverProfiles(alloc: Allocator, include_ssh_hosts: bool) !ProfileDiscovery {
    const order_hint = detectProfileOrderHint(alloc);
    defer if (order_hint) |value| alloc.free(value);

    var complete = true;
    const shell_profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookupExecutable,
        probeWslExecutableForProfiles,
        listWslDistros,
        order_hint,
        &complete,
    );
    return .{
        .profiles = try appendConfiguredSshProfiles(alloc, shell_profiles, include_ssh_hosts, &complete),
        .complete = complete,
    };
}

fn appendConfiguredSshProfiles(
    alloc: Allocator,
    shell_profiles: []Profile,
    include_ssh_hosts: bool,
    complete: ?*bool,
) ![]Profile {
    if (!include_ssh_hosts) return shell_profiles;

    // SSH discovery is additive. Any failure below degrades to the detected
    // shells rather than propagating, because the caller treats an error as
    // "no profiles at all" and would leave the user with no picker.
    const hosts = windows_ssh_hosts.load(alloc) catch |err| {
        warnSshDiscoveryOnce(err);
        if (complete) |value| value.* = false;
        return shell_profiles;
    };
    defer windows_ssh_hosts.deinitHosts(alloc, hosts);
    if (hosts.len == 0) return shell_profiles;

    const ssh_path = resolveSshExecutable(alloc, lookupExecutable, accessAbsolute) catch |err| {
        warnSshDiscoveryOnce(err);
        if (complete) |value| value.* = false;
        return shell_profiles;
    };
    if (ssh_path == null) {
        warnMissingSshOnce();
        return shell_profiles;
    }
    defer alloc.free(ssh_path.?);
    return try appendSshProfiles(alloc, shell_profiles, hosts, ssh_path.?);
}

pub fn profileOrderHint(alloc: Allocator) ?[:0]const u8 {
    const raw = detectProfileOrderHint(alloc) orelse return null;
    defer alloc.free(raw);
    return alloc.dupeZ(u8, raw) catch null;
}

pub fn deinitProfiles(alloc: Allocator, profiles: []Profile) void {
    for (profiles) |*profile| profile.deinit(alloc);
    alloc.free(profiles);
}

pub fn shellIntegrationDiagnostic(kind: ProfileKind) ShellIntegrationDiagnostic {
    return switch (kind) {
        .wsl_default, .wsl_distro => .{
            .support = .shell_managed,
            .summary = switch (kind) {
                .wsl_default => "WSL default profile; shell integration depends on the Linux shell",
                .wsl_distro => "WSL distro profile; shell integration depends on the Linux shell",
                else => unreachable,
            },
            .next_step = wsl_shell_integration_next_step,
        },
        .pwsh => .{
            .support = .automatic,
            .summary = "PowerShell profile with automatic shell integration",
        },
        .powershell => .{
            .support = .automatic,
            .summary = "Windows PowerShell profile with automatic shell integration",
        },
        .git_bash => .{
            .support = .automatic,
            .summary = "Git Bash profile with automatic shell integration",
        },
        .cmd => .{
            .support = .automatic,
            .summary = "Command Prompt profile with PROMPT-based shell integration; Clink adds command-start/finish and exit-code marks",
        },
        .ssh => .{
            .support = .unavailable,
            .summary = "SSH profile; shell integration is disabled for remote sessions",
            .next_step = "Enable shell integration inside the remote shell's own startup files.",
        },
    };
}

/// Prepare a command for Windows spawning. This applies the guarded UTF-8
/// preamble to payload-free cmd launches and translates WSL working
/// directories into `wsl.exe --cd ...` without paying a shell trampoline cost.
pub fn prepareCommand(
    alloc: Allocator,
    command: Command,
    cwd: ?[]const u8,
    working_directory_home: bool,
    utf8_console: bool,
) !Command {
    return try prepareCommandWithLookup(
        alloc,
        command,
        cwd,
        working_directory_home,
        utf8_console,
        lookupExecutable,
    );
}

/// Determine a safe Windows host cwd for launching a command. This is
/// primarily needed for WSL, where the terminal cwd may be a WSL path or
/// `home` while CreateProcess still requires a Windows-local directory.
pub fn spawnCwd(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
) !?[]const u8 {
    if (cwd) |v| {
        if (isWindowsUriPath(v)) return try uriPathToWindows(alloc, v);
        if (isDriveAbsolutePath(v)) return try alloc.dupe(u8, v);
        if (isWslPath(v)) return try defaultWindowsHome(alloc);
        return try defaultWindowsHome(alloc);
    }

    _ = working_directory_home;
    return try defaultWindowsHome(alloc);
}

/// Determine a safe shell-visible PWD for Windows launches.
///
/// Non-WSL shells should only receive native Windows paths. WSL launches can
/// receive normalized WSL-style paths or the home sentinel. Obviously invalid
/// Windows cwd values such as `\\` are dropped entirely.
pub fn shellPwd(
    alloc: Allocator,
    cwd: ?[]const u8,
    is_wsl: bool,
) !?[]const u8 {
    const value = cwd orelse return null;

    const result: ?[]const u8 = result: {
        if (isWindowsUriPath(value)) break :result try uriPathToWindows(alloc, value);
        if (isDriveAbsolutePath(value)) break :result try alloc.dupe(u8, value);
        if (!is_wsl) break :result null;
        if (std.mem.eql(u8, value, "~")) break :result try alloc.dupe(u8, value);
        if (isWslPath(value)) break :result try normalizeWslPath(alloc, value);
        log.warn("dropping unsupported windows shell pwd cwd={s} is_wsl={}", .{ value, is_wsl });
        break :result null;
    };
    if (result) |path| {
        if (!isSafeWindowsPath(path)) {
            log.warn("dropping windows shell pwd with unsafe path bytes len={}", .{path.len});
            alloc.free(path);
            return null;
        }
    }
    return result;
}

/// Determine a safe CreateProcess cwd for Windows launches while preserving
/// inherit semantics when the caller did not request a specific cwd.
pub fn safeCurrentDirectory(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
    is_wsl: bool,
) !?[]const u8 {
    const current = try currentWindowsDirectory(alloc);

    const result = try safeCurrentDirectoryWithCurrent(
        alloc,
        cwd,
        working_directory_home,
        is_wsl,
        current,
    );
    if (result) |path| {
        if (!isSafeWindowsPath(path)) {
            log.warn("dropping windows current directory with unsafe path bytes len={}", .{path.len});
            alloc.free(path);
            return null;
        }
    }
    return result;
}

/// Takes ownership of `current` and frees it on every path.
fn safeCurrentDirectoryWithCurrent(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
    is_wsl: bool,
    current: ?[]const u8,
) !?[]const u8 {
    defer if (current) |value| alloc.free(value);

    if (cwd) |value| {
        if (isWindowsUriPath(value)) return try uriPathToWindows(alloc, value);
        if (isDriveAbsolutePath(value)) return try alloc.dupe(u8, value);
        if (is_wsl or isWslPath(value) or isObviouslyInvalidWindowsCurrentDirectory(value)) {
            log.warn("falling back to windows home for unsafe cwd cwd={s} is_wsl={}", .{ value, is_wsl });
            return try defaultWindowsHome(alloc);
        }

        log.warn("falling back to windows home for unsupported cwd cwd={s} is_wsl={}", .{ value, is_wsl });
        return try defaultWindowsHome(alloc);
    }

    if (current) |value| {
        if (isDriveAbsolutePath(value)) return try alloc.dupe(u8, value);
        if (isWindowsUriPath(value)) return try uriPathToWindows(alloc, value);
        if (isObviouslyInvalidWindowsCurrentDirectory(value)) {
            log.warn("falling back to windows home for inherited unsafe cwd cwd={s} is_wsl={}", .{ value, is_wsl });
            return try defaultWindowsHome(alloc);
        }

        log.warn("using inherited windows cwd cwd={s} is_wsl={}", .{ value, is_wsl });
        return try alloc.dupe(u8, value);
    }

    if (working_directory_home or is_wsl) return try defaultWindowsHome(alloc);
    return null;
}

fn currentWindowsDirectory(alloc: Allocator) !?[]const u8 {
    return std.process.getCwdAlloc(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            log.warn("failed to read current windows cwd err={}", .{err});
            return null;
        },
    };
}

fn prepareCommandWithLookup(
    alloc: Allocator,
    command: Command,
    cwd: ?[]const u8,
    working_directory_home: bool,
    utf8_console: bool,
    lookup: anytype,
) !Command {
    if (utf8_console) {
        if (try prepareCmdUtf8(alloc, command)) |prepared| return prepared;
    }

    if (!isWslCommand(command)) return try command.clone(alloc);

    const target_cwd: ?[]const u8 = cwd_: {
        if (cwd) |v| break :cwd_ try pathToWsl(alloc, v);
        if (working_directory_home) break :cwd_ try alloc.dupe(u8, "~");
        break :cwd_ null;
    };
    defer if (target_cwd) |v| alloc.free(v);

    return switch (command) {
        .direct => |argv| try prepareWslDirect(alloc, argv, target_cwd, lookup),

        // We only auto-rewrite WSL direct launches. A shell command is assumed
        // to be user-authored and remains untouched.
        .shell => try command.clone(alloc),
    };
}

/// The silent code-page switch we run before an interactive Command Prompt
/// draws its first prompt. `chcp` is idempotent, so this is a no-op when the
/// console already uses code page 65001.
const cmd_utf8_preamble = "chcp 65001 >nul";

/// Build the UTF-8 preamble form of a `cmd.exe` launch, or `null` when the
/// launch must be left byte-for-byte unchanged.
///
/// Only an interactive Command Prompt that carries no command payload of its
/// own is rewritten. Non-payload switches (`/d`, `/q`, `/v:on`, ...) are kept
/// in their original order and `/K "chcp 65001 >nul"` is appended after them.
fn prepareCmdUtf8(alloc: Allocator, command: Command) !?Command {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);

    const argv0 = arg_iter.next() orelse return null;
    if (!isExecutableName(argv0, "cmd") and
        !isExecutableName(argv0, "cmd.exe")) return null;
    try args.append(alloc, argv0);

    while (arg_iter.next()) |arg| {
        if (classifyCmdArg(arg) == .unsupported) return null;
        try args.append(alloc, arg);
    }

    try args.append(alloc, "/K");
    try args.append(alloc, cmd_utf8_preamble);
    return try directCommand(alloc, args.items);
}

const CmdArg = enum {
    /// A switch run carrying only non-payload options. Safe to preserve and
    /// to append our own `/K` after.
    option,

    /// A command payload switch or a token we don't recognize. The launch is
    /// left untouched.
    unsupported,
};

/// Classify one `cmd.exe` argument.
///
/// `cmd.exe` only treats `/` as a switch prefix (`-c` is a positional), and it
/// accepts fused switch runs such as `/d/q/c` and `/v:on/c`, so a run has to be
/// walked to the end before it can be called payload-free.
fn classifyCmdArg(arg: []const u8) CmdArg {
    if (arg.len < 2 or arg[0] != '/') return .unsupported;

    var i: usize = 0;
    while (i < arg.len) {
        // A fused run repeats the `/` separator: `/d/q/v:on`.
        if (arg[i] == '/') {
            i += 1;
            if (i >= arg.len) return .unsupported;
        }

        switch (std.ascii.toLower(arg[i])) {
            // `/c` and `/r` run a command and terminate; `/k` runs a command
            // and stays interactive. All three carry the user's own payload,
            // which we never touch.
            'c', 'r', 'k' => return .unsupported,

            // Valueless options: ANSI/Unicode piped output, quiet echo,
            // AutoRun suppression, and quoting mode. `/x` and `/y` are the
            // OS/2-compatibility spellings of `/e:on` and `/e:off`, which
            // `cmd /?` documents and which take no value.
            'a', 'u', 'q', 'd', 's', 'x', 'y' => i += 1,

            // `/e:on`, `/f:off`, `/v:on`.
            'e', 'f', 'v' => {
                i += 1;
                if (i >= arg.len or arg[i] != ':') return .unsupported;
                i += 1;
                if (asciiStartsWithIgnoreCase(arg[i..], "off")) {
                    i += "off".len;
                } else if (asciiStartsWithIgnoreCase(arg[i..], "on")) {
                    i += "on".len;
                } else return .unsupported;
            },

            // `/t:fg` takes one or two hex color digits.
            't' => {
                i += 1;
                if (i >= arg.len or arg[i] != ':') return .unsupported;
                i += 1;
                var digits: usize = 0;
                while (digits < 2 and i < arg.len and std.ascii.isHex(arg[i])) {
                    i += 1;
                    digits += 1;
                }
                if (digits == 0) return .unsupported;
            },

            else => return .unsupported,
        }

        // A run either ends here or continues with another `/`. Anything else
        // is a fused payload such as `/cecho hi`.
        if (i < arg.len and arg[i] != '/') return .unsupported;
    }

    return .option;
}

pub fn isWslCommand(command: Command) bool {
    return switch (command) {
        .direct => |argv| isWslArgv(argv),
        .shell => false,
    };
}

pub fn isWslArgv(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    return isExecutableName(argv[0], "wsl") or isExecutableName(argv[0], "wsl.exe");
}

pub fn isWslPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/") or
        std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\");
}

/// Convert a local path coming from OSC 7 into a Windows-local path string.
/// WSL paths stay WSL-style so they can be inherited into later WSL shells.
pub fn osc7PathToLocal(alloc: Allocator, path: []const u8) ![]const u8 {
    if (isWindowsUriPath(path)) return try uriPathToWindows(alloc, path);
    // A UNC path carried in a URI keeps the URI's leading `/`. Strip it before
    // the WSL check below, which would otherwise treat the whole string as a
    // POSIX path and hand back an unusable `/\\server\share` cwd.
    if (isUncUriPath(path)) {
        const unc = path[1..];
        if (isWslPath(unc)) return try normalizeWslPath(alloc, unc);
        return try alloc.dupe(u8, unc);
    }
    if (isWslPath(path)) return try normalizeWslPath(alloc, path);
    return try alloc.dupe(u8, path);
}

/// Translate a Windows or WSL-style path into a WSL path. Returns `null` for
/// paths we can't confidently map.
pub fn pathToWsl(alloc: Allocator, path: []const u8) !?[]const u8 {
    if (path.len == 0) return null;
    if (isWindowsUriPath(path)) return try pathToWsl(alloc, path[1..]);
    if (isUncUriPath(path)) return try pathToWsl(alloc, path[1..]);
    if (isWslPath(path)) return try normalizeWslPath(alloc, path);

    if (!isDriveAbsolutePath(path)) return null;

    const rest = trimLeadingSeparators(path[2..]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "/mnt/");
    try buf.append(alloc, std.ascii.toLower(path[0]));
    if (rest.len == 0) {
        return try buf.toOwnedSlice(alloc);
    }

    try buf.append(alloc, '/');
    try appendNormalizedPath(&buf, alloc, rest);
    return try buf.toOwnedSlice(alloc);
}

fn defaultShellWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !DefaultShell {
    return try defaultShellWithLookupAndProbe(alloc, lookup, probeWslExecutableAlwaysTrue);
}

fn defaultShellWithLookupAndProbe(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
) !DefaultShell {
    for (default_shell_candidates) |candidate| {
        const found = try lookup(alloc, candidate.exe);
        defer if (found) |path| alloc.free(path);
        if (found) |path| {
            if (candidate.shell == .wsl and !try probe(alloc, path)) continue;
            return candidate.shell;
        }
    }

    return .cmd;
}

fn defaultCommandWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !Command {
    return try defaultCommandWithLookupAndProbe(alloc, lookup, probeWslExecutableAlwaysTrue);
}

fn defaultCommandWithLookupAndProbe(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
) !Command {
    for (default_shell_candidates) |candidate| {
        const found = try lookup(alloc, candidate.exe);
        if (found) |path| {
            defer alloc.free(path);
            if (candidate.shell == .wsl and !try probe(alloc, path)) continue;
            return switch (candidate.shell) {
                .wsl => try directCommand(alloc, &.{path}),
                else => try directCommand(alloc, &.{path}),
            };
        }
    }

    if (try lookup(alloc, "cmd.exe")) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }

    return try directCommand(alloc, &.{"cmd.exe"});
}

fn defaultCommandNoWslWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !Command {
    inline for (default_shell_candidates_no_wsl) |candidate| {
        const found = try lookup(alloc, candidate.exe);
        if (found) |path| {
            defer alloc.free(path);
            return try directCommand(alloc, &.{path});
        }
    }

    if (try lookup(alloc, "cmd.exe")) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }

    return try directCommand(alloc, &.{"cmd.exe"});
}

fn listProfilesWithLookupAndProbeAndWslList(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
    list_wsl: anytype,
) ![]Profile {
    return try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookup,
        probe,
        list_wsl,
        null,
        null,
    );
}

fn listProfilesWithLookupAndProbeAndWslListAndOrder(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
    list_wsl: anytype,
    order_hint: ?[]const u8,
    complete: ?*bool,
) ![]Profile {
    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |*profile| profile.deinit(alloc);
        profiles.deinit(alloc);
    }

    if (try lookup(alloc, "wsl.exe")) |path| {
        defer alloc.free(path);

        const wsl_ready = try probe(alloc, path);
        if (!wsl_ready) {
            if (complete) |value| value.* = false;
        } else {
            try appendProfile(
                alloc,
                &profiles,
                .wsl_default,
                "wsl-default",
                "WSL (Default)",
                &.{path},
            );

            const distros = try list_wsl(alloc, path);
            defer deinitOwnedStringList(alloc, distros);

            for (distros) |distro| {
                const key = try std.fmt.allocPrint(alloc, "wsl:{s}", .{distro});
                defer alloc.free(key);
                const label = try std.fmt.allocPrint(alloc, "WSL: {s}", .{distro});
                defer alloc.free(label);
                try appendProfile(
                    alloc,
                    &profiles,
                    .wsl_distro,
                    key,
                    label,
                    &.{ path, "-d", distro },
                );
            }
        }
    }

    try appendProfileIfFound(alloc, &profiles, lookup, .pwsh, "pwsh.exe", "PowerShell");
    try appendProfileIfFound(alloc, &profiles, lookup, .powershell, "powershell.exe", "Windows PowerShell");

    if (try lookupGitBash(alloc, lookup)) |path| {
        defer alloc.free(path);
        try appendProfile(
            alloc,
            &profiles,
            .git_bash,
            "git-bash",
            "Git Bash",
            &.{ path, "--login", "-i" },
        );
    }

    try appendProfileIfFound(alloc, &profiles, lookup, .cmd, "cmd.exe", "Command Prompt");

    if (order_hint) |hint| applyProfileOrderHint(profiles.items, hint);

    return try profiles.toOwnedSlice(alloc);
}

fn appendProfileIfFound(
    alloc: Allocator,
    profiles: *std.ArrayList(Profile),
    lookup: anytype,
    kind: ProfileKind,
    exe: []const u8,
    label: []const u8,
) !void {
    if (try lookup(alloc, exe)) |path| {
        defer alloc.free(path);
        try appendProfile(alloc, profiles, kind, exe, label, &.{path});
    }
}

fn appendProfile(
    alloc: Allocator,
    profiles: *std.ArrayList(Profile),
    kind: ProfileKind,
    key: []const u8,
    label: []const u8,
    argv: []const []const u8,
) !void {
    try profiles.append(alloc, .{
        .kind = kind,
        .key = try alloc.dupe(u8, key),
        .label = try alloc.dupe(u8, label),
        .command = try directCommand(alloc, argv),
    });
}

fn appendSshProfiles(
    alloc: Allocator,
    shell_profiles: []Profile,
    hosts: []const windows_ssh_hosts.Host,
    ssh_path: []const u8,
) ![]Profile {
    var profiles: std.ArrayList(Profile) = .empty;
    profiles.ensureTotalCapacity(alloc, shell_profiles.len + hosts.len) catch |err| {
        deinitProfiles(alloc, shell_profiles);
        return err;
    };
    profiles.appendSliceAssumeCapacity(shell_profiles);
    alloc.free(shell_profiles);
    errdefer deinitProfileList(alloc, &profiles);

    for (hosts) |host| {
        const key = try std.fmt.allocPrint(alloc, "ssh:{s}", .{host.alias});
        defer alloc.free(key);
        const label = try std.fmt.allocPrint(alloc, "SSH: {s}", .{host.alias});
        defer alloc.free(label);
        const palette_title = try std.fmt.allocPrint(alloc, "Connect to {s}", .{host.alias});
        defer alloc.free(palette_title);
        try appendProfile(
            alloc,
            &profiles,
            .ssh,
            key,
            label,
            &.{ ssh_path, host.alias },
        );
        profiles.items[profiles.items.len - 1].palette_title = try alloc.dupe(u8, palette_title);
    }

    return try profiles.toOwnedSlice(alloc);
}

fn resolveSshExecutable(alloc: Allocator, lookup: anytype, access: anytype) !?[]u8 {
    const path_result = lookup(alloc, "ssh.exe") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (path_result) |path| return path;

    const fallback = "C:\\Windows\\System32\\OpenSSH\\ssh.exe";
    access(fallback) catch return null;
    return try alloc.dupe(u8, fallback);
}

fn accessAbsolute(path: []const u8) !void {
    try std.fs.accessAbsolute(path, .{});
}

fn warnSshDiscoveryOnce(err: anyerror) void {
    ssh_missing_mutex.lock();
    defer ssh_missing_mutex.unlock();
    if (ssh_missing_logged) return;
    ssh_missing_logged = true;
    log.warn("SSH hosts skipped: discovery failed err={}", .{err});
}

fn warnMissingSshOnce() void {
    ssh_missing_mutex.lock();
    defer ssh_missing_mutex.unlock();
    if (ssh_missing_logged) return;
    ssh_missing_logged = true;
    log.warn("SSH hosts skipped: ssh.exe was not found on PATH or in Windows OpenSSH", .{});
}

fn deinitProfileList(alloc: Allocator, profiles: *std.ArrayList(Profile)) void {
    for (profiles.items) |*profile| profile.deinit(alloc);
    profiles.deinit(alloc);
}

fn detectProfileOrderHint(alloc: Allocator) ?[]u8 {
    const raw = std.process.getEnvVarOwned(alloc, "NOCTTY_WIN32_PROFILE_ORDER") catch
        return null;
    errdefer alloc.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        alloc.free(raw);
        return null;
    }

    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;

    const copy = alloc.dupe(u8, trimmed) catch return null;
    alloc.free(raw);
    return copy;
}

fn applyProfileOrderHint(profiles: []Profile, order_hint: []const u8) void {
    if (profiles.len <= 1 or order_hint.len == 0) return;

    var i: usize = 1;
    while (i < profiles.len) : (i += 1) {
        var j = i;
        while (j > 0 and shouldProfileSortBefore(order_hint, profiles[j], profiles[j - 1])) : (j -= 1) {
            std.mem.swap(Profile, &profiles[j], &profiles[j - 1]);
        }
    }
}

fn shouldProfileSortBefore(order_hint: []const u8, lhs: Profile, rhs: Profile) bool {
    const lhs_rank = profileOrderRank(order_hint, lhs);
    const rhs_rank = profileOrderRank(order_hint, rhs);
    if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
    return false;
}

fn profileOrderRank(order_hint: []const u8, profile: Profile) usize {
    var index: usize = 0;
    var it = std.mem.splitAny(u8, order_hint, ",;");
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        if (profileOrderTokenMatches(token, profile)) return index;
        index += 1;
    }
    return std.math.maxInt(usize);
}

fn profileOrderTokenMatches(token: []const u8, profile: Profile) bool {
    if (std.ascii.eqlIgnoreCase(token, profile.key)) return true;
    if (std.ascii.eqlIgnoreCase(token, profile.label)) return true;
    if (profile.kind == .wsl_distro) {
        if (profile.key.len > 4 and std.ascii.eqlIgnoreCase(profile.key[0..4], "wsl:")) {
            if (std.ascii.eqlIgnoreCase(token, profile.key[4..])) return true;
        }
        if (profile.label.len > 5 and std.ascii.eqlIgnoreCase(profile.label[0..5], "WSL: ")) {
            if (std.ascii.eqlIgnoreCase(token, profile.label[5..])) return true;
        }
    }

    return switch (profile.kind) {
        .wsl_default => std.ascii.eqlIgnoreCase(token, "wsl") or
            std.ascii.eqlIgnoreCase(token, "wsl-default") or
            std.ascii.eqlIgnoreCase(token, "default-wsl"),
        .wsl_distro => std.ascii.eqlIgnoreCase(token, "wsl-distro") or
            std.ascii.eqlIgnoreCase(token, "distro") or
            std.ascii.eqlIgnoreCase(token, "wsl"),
        .pwsh => std.ascii.eqlIgnoreCase(token, "pwsh") or
            std.ascii.eqlIgnoreCase(token, "powershell-7") or
            std.ascii.eqlIgnoreCase(token, "powershell-core"),
        .powershell => std.ascii.eqlIgnoreCase(token, "powershell") or
            std.ascii.eqlIgnoreCase(token, "windows-powershell") or
            std.ascii.eqlIgnoreCase(token, "ps"),
        .git_bash => std.ascii.eqlIgnoreCase(token, "git-bash") or
            std.ascii.eqlIgnoreCase(token, "gitbash") or
            std.ascii.eqlIgnoreCase(token, "git"),
        .cmd => std.ascii.eqlIgnoreCase(token, "cmd") or
            std.ascii.eqlIgnoreCase(token, "cmd.exe") or
            std.ascii.eqlIgnoreCase(token, "command-prompt"),
        .ssh => false,
    };
}

fn previewCommandWithLookup(
    alloc: Allocator,
    lookup: anytype,
) !Command {
    if (try lookup(alloc, "cmd.exe")) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }

    return try defaultCommandNoWslWithLookup(alloc, lookup);
}

fn probeWslExecutableAlwaysTrue(_: Allocator, _: []const u8) !bool {
    return true;
}

fn probeWslExecutableCached(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    wsl_probe_mutex.lock();
    defer wsl_probe_mutex.unlock();

    if (wsl_probe_cache) |cached| return cached;

    const result = try probeWslExecutable(alloc, exe_path);
    wsl_probe_cache = result;
    return result;
}

fn probeWslExecutableForProfiles(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    wsl_probe_mutex.lock();
    defer wsl_probe_mutex.unlock();

    if ((wsl_profile_probe_cache orelse false) or (wsl_probe_cache orelse false)) return true;

    const result = try probeWslExecutable(alloc, exe_path);
    // Profile discovery keeps transient negative results retryable while a
    // successful probe remains stable for later palette/jump-list refreshes.
    if (result) wsl_profile_probe_cache = true;
    return result;
}

fn probeWslExecutable(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    var child = std.process.Child.init(&.{ exe_path, "--status" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;

    child.spawn() catch |err| {
        log.warn("failed to probe wsl responsiveness exe={s} err={}", .{ exe_path, err });
        return false;
    };
    errdefer {
        _ = child.kill() catch {};
    }

    windows.WaitForSingleObjectEx(child.id, wsl_probe_timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            log.warn("skipping unresponsive wsl default shell exe={s} timeout_ms={}", .{
                exe_path,
                wsl_probe_timeout_ms,
            });
            _ = child.kill() catch {};
            return false;
        },

        else => {
            log.warn("wsl probe wait failed exe={s} err={}", .{ exe_path, err });
            _ = child.kill() catch {};
            return false;
        },
    };

    _ = child.wait() catch |err| {
        log.warn("wsl probe wait cleanup failed exe={s} err={}", .{ exe_path, err });
        return false;
    };
    return true;
}

const default_shell_candidates = [_]struct {
    shell: DefaultShell,
    exe: []const u8,
}{
    .{ .shell = .wsl, .exe = "wsl.exe" },
    .{ .shell = .pwsh, .exe = "pwsh.exe" },
    .{ .shell = .powershell, .exe = "powershell.exe" },
};

const default_shell_candidates_no_wsl = [_]struct {
    shell: DefaultShell,
    exe: []const u8,
}{
    .{ .shell = .pwsh, .exe = "pwsh.exe" },
    .{ .shell = .powershell, .exe = "powershell.exe" },
};

fn prepareWslDirect(
    alloc: Allocator,
    argv: []const [:0]const u8,
    target_cwd: ?[]const u8,
    lookup: anytype,
) !Command {
    const resolved_exe = try resolveExecutableForArgv0(alloc, argv, lookup);
    defer if (resolved_exe) |path| alloc.free(path);
    const target_home = if (target_cwd) |cwd| std.mem.eql(u8, cwd, "~") else false;

    if (argv.len == 0) {
        if (resolved_exe) |path| return try directCommand(alloc, &.{path});
        return try directCommand(alloc, &.{"wsl.exe"});
    }

    var count: usize = 1;
    if (target_cwd != null) count += 2;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (isCdFlag(argv[i])) {
            if (std.mem.eql(u8, argv[i], "--cd") and i + 1 < argv.len) i += 1;
            continue;
        }

        if (std.mem.eql(u8, argv[i], "~")) {
            // Treat a bare "~" as our legacy home sentinel for WSL launches.
            // Modern WSL expects "--cd ~" instead of a positional "~".
            continue;
        }

        count += 1;
    }

    const args = try alloc.alloc([:0]const u8, count);
    var j: usize = 0;
    if (resolved_exe) |path| {
        args[j] = try alloc.dupeZ(u8, path);
    } else {
        args[j] = try alloc.dupeZ(u8, argv[0]);
    }
    j += 1;

    if (target_cwd) |cwd| {
        _ = target_home;
        args[j] = try alloc.dupeZ(u8, "--cd");
        j += 1;
        args[j] = try alloc.dupeZ(u8, cwd);
        j += 1;
    }

    i = 1;
    while (i < argv.len) : (i += 1) {
        if (isCdFlag(argv[i])) {
            if (std.mem.eql(u8, argv[i], "--cd") and i + 1 < argv.len) i += 1;
            continue;
        }

        if (std.mem.eql(u8, argv[i], "~")) {
            continue;
        }

        args[j] = try alloc.dupeZ(u8, argv[i]);
        j += 1;
    }

    std.debug.assert(j == count);
    return .{ .direct = args };
}

fn resolveExecutableForArgv0(
    alloc: Allocator,
    argv: []const [:0]const u8,
    lookup: anytype,
) !?[]u8 {
    if (argv.len == 0) return try lookup(alloc, "wsl.exe");
    if (!isExecutableName(argv[0], "wsl") and !isExecutableName(argv[0], "wsl.exe")) return null;
    if (std.fs.path.isAbsolute(argv[0])) return try alloc.dupe(u8, argv[0]);
    return try lookup(alloc, "wsl.exe");
}

fn directCommand(alloc: Allocator, argv: []const []const u8) !Command {
    const args = try alloc.alloc([:0]const u8, argv.len);
    for (argv, 0..) |arg, i| args[i] = try alloc.dupeZ(u8, arg);
    return .{ .direct = args };
}

fn lookupExecutable(alloc: Allocator, exe: []const u8) !?[]u8 {
    return try internal_os.path.expand(alloc, exe);
}

fn lookupGitBash(alloc: Allocator, lookup: anytype) !?[]u8 {
    if (try lookup(alloc, "bash.exe")) |path| return path;

    if (try lookup(alloc, "git.exe")) |git_path| {
        defer alloc.free(git_path);

        const git_dir = std.fs.path.dirname(git_path) orelse return null;
        const root = std.fs.path.dirname(git_dir) orelse return null;
        const candidate = try std.fs.path.join(alloc, &.{ root, "bin", "bash.exe" });
        errdefer alloc.free(candidate);

        std.fs.accessAbsolute(candidate, .{}) catch return null;
        return candidate;
    }

    return null;
}

const WslOutputDrain = struct {
    stdout: std.fs.File,
    bytes: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *WslOutputDrain) void {
        self.bytes = self.stdout.readToEndAlloc(std.heap.page_allocator, 64 * 1024) catch |err| {
            self.err = err;
            return;
        };
    }

    fn deinit(self: *WslOutputDrain) void {
        if (self.bytes) |bytes| std.heap.page_allocator.free(bytes);
    }
};

fn listWslDistros(alloc: Allocator, exe_path: []const u8) ![][]u8 {
    var child = std.process.Child.init(&.{ exe_path, "-l", "-q" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;

    try child.spawn();
    var child_running = true;
    errdefer {
        if (child_running) _ = child.kill() catch {};
    }

    const stdout = child.stdout orelse {
        _ = child.kill() catch {};
        return error.Unexpected;
    };

    // Drain concurrently so a large distro list cannot fill the anonymous
    // pipe and prevent wsl.exe from reaching the signaled state below.
    var drain: WslOutputDrain = .{ .stdout = stdout };
    const drain_thread = try std.Thread.spawn(.{}, WslOutputDrain.run, .{&drain});
    var drain_joined = false;
    defer {
        if (!drain_joined) drain_thread.join();
        drain.deinit();
    }

    windows.WaitForSingleObjectEx(child.id, wsl_list_timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            log.warn("WSL distro enumeration timed out exe={s} timeout_ms={}", .{
                exe_path,
                wsl_list_timeout_ms,
            });
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            child_running = false;
            drain_thread.join();
            drain_joined = true;
            return error.WslListTimeout;
        },
        else => {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            child_running = false;
            drain_thread.join();
            drain_joined = true;
            return err;
        },
    };

    drain_thread.join();
    drain_joined = true;
    const term = try child.wait();
    child_running = false;
    if (drain.err) |err| {
        return err;
    }
    if (!childTermSucceeded(term)) {
        log.warn("WSL distro enumeration exited unsuccessfully exe={s}", .{exe_path});
        return error.WslListFailed;
    }
    const raw_bytes = drain.bytes orelse return error.Unexpected;

    // wsl.exe outputs UTF-16LE. Convert to UTF-8 before parsing.
    // bytesAsSlice returns align(1) u16, but utf16LeToUtf8Alloc needs align(2).
    // Copy into a properly-aligned buffer first.
    const output = if (raw_bytes.len >= 2 and raw_bytes.len % 2 == 0) blk: {
        const unaligned = std.mem.bytesAsSlice(u16, raw_bytes);
        const aligned = try alloc.alloc(u16, unaligned.len);
        defer alloc.free(aligned);
        @memcpy(aligned, unaligned);
        // Skip BOM if present
        const data: []const u16 = if (aligned.len > 0 and aligned[0] == 0xFEFF) aligned[1..] else aligned;
        break :blk std.unicode.utf16LeToUtf8Alloc(alloc, data) catch {
            // Fallback: treat as raw UTF-8 if conversion fails
            break :blk try alloc.dupe(u8, raw_bytes);
        };
    } else try alloc.dupe(u8, raw_bytes);
    defer alloc.free(output);

    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        deinitOwnedStringList(alloc, result.items);
        result.deinit(alloc);
    }

    var it = std.mem.splitAny(u8, output, "\r\n");
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n\x00");
        if (line.len == 0) continue;
        // Filter out Docker Desktop and Rancher Desktop service distros
        // (matches Windows Terminal behavior)
        if (isWslServiceDistro(line)) continue;
        try result.append(alloc, try alloc.dupe(u8, line));
    }

    return try result.toOwnedSlice(alloc);
}

fn childTermSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Returns true for WSL distros that are internal service distributions
/// (not intended for interactive use). Matches Windows Terminal's filtering.
fn isWslServiceDistro(name: []const u8) bool {
    return asciiStartsWithIgnoreCase(name, "docker-desktop") or
        asciiStartsWithIgnoreCase(name, "rancher-desktop");
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn deinitOwnedStringList(alloc: Allocator, values: []const []u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn defaultWindowsHome(alloc: Allocator) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (try internal_os.windows.knownFolderPathUtf8(
        &internal_os.windows.FOLDERID_Profile,
        &buf,
    )) |path| {
        return try alloc.dupe(u8, path);
    }

    return null;
}

fn isExecutableName(path: []const u8, exe: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basename(path), exe);
}

fn isCdFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--cd") or std.mem.startsWith(u8, arg, "--cd=");
}

fn isWindowsUriPath(path: []const u8) bool {
    return path.len >= 4 and
        path[0] == '/' and
        std.ascii.isAlphabetic(path[1]) and
        path[2] == ':' and
        isSeparator(path[3]);
}

/// True for a UNC path that still carries the leading `/` of the URI it came
/// from, e.g. `/\\server\share\dir`. cmd's `$P` expands to a raw UNC path, so
/// `kitty-shell-cwd://localhost/$P` yields exactly this shape.
/// A `kitty-shell-cwd` path whose body is a Windows UNC path, i.e. the URI
/// separator followed by `\\server\share...`.
///
/// The remainder must be backslash-separated. Backslashes are legal in POSIX
/// filenames, so a WSL or POSIX shell could in principle report a directory
/// such as `/\\server/share`; requiring that no forward slash appears after
/// the URI separator keeps that case on the WSL path where it belongs, while
/// still matching everything cmd's `$P` can produce (cmd always emits
/// backslashes).
fn isUncUriPath(path: []const u8) bool {
    if (path.len < 4) return false;
    if (path[0] != '/' or path[1] != '\\' or path[2] != '\\') return false;
    if (isSeparator(path[3])) return false;
    return std.mem.indexOfScalar(u8, path[3..], '/') == null;
}

pub fn isDriveAbsolutePath(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        isSeparator(path[2]);
}

/// Return true when a Windows path contains no bytes that can terminate or
/// split a CreateProcess environment/current-directory value or a window title.
pub fn isSafeWindowsPath(path: []const u8) bool {
    for (path) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

fn isObviouslyInvalidWindowsCurrentDirectory(path: []const u8) bool {
    return path.len == 0 or
        std.mem.eql(u8, path, "\\") or
        std.mem.eql(u8, path, "\\\\") or
        std.mem.eql(u8, path, "/") or
        std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\");
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn trimLeadingSeparators(path: []const u8) []const u8 {
    return std.mem.trimLeft(u8, path, "/\\");
}

fn normalizeWslPath(alloc: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) return try alloc.dupe(u8, path);

    for ([_][]const u8{
        "\\\\wsl.localhost\\",
        "\\\\wsl$\\",
    }) |prefix| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;

        const rest = path[prefix.len..];
        const distro_sep = std.mem.indexOfAny(u8, rest, "/\\") orelse return try alloc.dupe(u8, "/");
        const distro_rest = trimLeadingSeparators(rest[distro_sep..]);
        if (distro_rest.len == 0) return try alloc.dupe(u8, "/");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.append(alloc, '/');
        try appendNormalizedPath(&buf, alloc, distro_rest);
        return try buf.toOwnedSlice(alloc);
    }

    return try alloc.dupe(u8, path);
}

fn uriPathToWindows(alloc: Allocator, path: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, path[1]);
    try buf.appendSlice(alloc, ":\\");
    try appendWindowsPath(&buf, alloc, trimLeadingSeparators(path[3..]));
    return try buf.toOwnedSlice(alloc);
}

fn appendNormalizedPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) !void {
    for (path) |c| try buf.append(alloc, if (c == '\\') '/' else c);
}

fn appendWindowsPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) !void {
    for (path) |c| try buf.append(alloc, if (c == '/') '\\' else c);
}

test "defaultShellWithLookup prefers wsl first" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell = try defaultShellWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup);

    try testing.expectEqual(.wsl, shell);
}

test "defaultShellWithLookupAndProbe falls back when wsl probe fails" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell = try defaultShellWithLookupAndProbe(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, exe: []const u8) !bool {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            return false;
        }
    }.probe);

    try testing.expectEqual(.pwsh, shell);
}

test "defaultShellWithLookup falls back to cmd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell = try defaultShellWithLookup(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup);

    try testing.expectEqual(.cmd, shell);
}

test "defaultCommandWithLookup prefers absolute wsl path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try defaultCommandWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 1), command.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", command.direct[0]);
}

test "defaultCommandWithLookupAndProbe falls back when wsl probe fails" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try defaultCommandWithLookupAndProbe(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, exe: []const u8) !bool {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            return false;
        }
    }.probe);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 1), command.direct.len);
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", command.direct[0]);
}

test "defaultCommandNoWslWithLookup skips wsl and prefers pwsh" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try defaultCommandNoWslWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 1), command.direct.len);
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", command.direct[0]);
}

test "lookupGitBash infers Git Bash from git.exe" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const path = (try lookupGitBash(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "bash.exe")) return null;
            if (std.mem.eql(u8, exe, "git.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\cmd\\git.exe");
            return null;
        }
    }.lookup)).?;
    defer alloc.free(path);

    try testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", path);
}

test "listProfilesWithLookupAndProbeAndWslList enumerates windows profiles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const profiles = try listProfilesWithLookupAndProbeAndWslList(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "powershell.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (std.mem.eql(u8, exe, "bash.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\bin\\bash.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, exe: []const u8) !bool {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            return true;
        }
    }.probe, struct {
        fn list(alloc_: Allocator, exe: []const u8) ![][]u8 {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            var values: std.ArrayList([]u8) = .empty;
            try values.append(alloc_, try alloc_.dupe(u8, "Ubuntu"));
            try values.append(alloc_, try alloc_.dupe(u8, "Debian"));
            return try values.toOwnedSlice(alloc_);
        }
    }.list);
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 7), profiles.len);
    try testing.expectEqual(ProfileKind.wsl_default, profiles[0].kind);
    try testing.expectEqualStrings("WSL (Default)", profiles[0].label);
    try testing.expectEqual(@as(usize, 1), profiles[0].command.direct.len);

    try testing.expectEqual(ProfileKind.wsl_distro, profiles[1].kind);
    try testing.expectEqualStrings("WSL: Ubuntu", profiles[1].label);
    try testing.expectEqual(@as(usize, 3), profiles[1].command.direct.len);
    try testing.expectEqualStrings("-d", profiles[1].command.direct[1]);
    try testing.expectEqualStrings("Ubuntu", profiles[1].command.direct[2]);

    try testing.expectEqual(ProfileKind.wsl_distro, profiles[2].kind);
    try testing.expectEqualStrings("WSL: Debian", profiles[2].label);
    try testing.expectEqual(ProfileKind.pwsh, profiles[3].kind);
    try testing.expectEqual(ProfileKind.powershell, profiles[4].kind);
    try testing.expectEqual(ProfileKind.git_bash, profiles[5].kind);
    try testing.expectEqual(ProfileKind.cmd, profiles[6].kind);
}

test "profile discovery reports a retryable WSL probe failure" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var complete = true;
    const profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return false;
        }
    }.probe, struct {
        fn list(_: Allocator, _: []const u8) ![][]u8 {
            return error.UnexpectedWslList;
        }
    }.list, null, &complete);
    defer deinitProfiles(alloc, profiles);

    try testing.expect(!complete);
    try testing.expectEqual(@as(usize, 1), profiles.len);
    try testing.expectEqual(ProfileKind.cmd, profiles[0].kind);

    complete = true;
    const recovered = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return true;
        }
    }.probe, struct {
        fn list(a: Allocator, _: []const u8) ![][]u8 {
            return try a.alloc([]u8, 0);
        }
    }.list, null, &complete);
    defer deinitProfiles(alloc, recovered);
    try testing.expect(complete);
    try testing.expectEqual(@as(usize, 2), recovered.len);
    try testing.expectEqual(ProfileKind.wsl_default, recovered[0].kind);
}

test "WSL enumeration requires a successful child exit" {
    try std.testing.expect(childTermSucceeded(.{ .Exited = 0 }));
    try std.testing.expect(!childTermSucceeded(.{ .Exited = 1 }));
    try std.testing.expect(!childTermSucceeded(.{ .Unknown = 1 }));
}

test "ssh profiles append after shells with alias-only argv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell_profiles = try alloc.alloc(Profile, 1);
    shell_profiles[0] = .{
        .kind = .cmd,
        .key = try alloc.dupe(u8, "cmd.exe"),
        .label = try alloc.dupe(u8, "Command Prompt"),
        .command = try directCommand(alloc, &.{"cmd.exe"}),
    };
    const hosts = [_]windows_ssh_hosts.Host{.{ .alias = "production" }};
    const profiles = try appendSshProfiles(
        alloc,
        shell_profiles,
        &hosts,
        "C:\\Windows\\System32\\OpenSSH\\ssh.exe",
    );
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 2), profiles.len);
    try testing.expectEqual(ProfileKind.cmd, profiles[0].kind);
    try testing.expectEqual(ProfileKind.ssh, profiles[1].kind);
    try testing.expectEqualStrings("ssh:production", profiles[1].key);
    try testing.expectEqualStrings("SSH: production", profiles[1].label);
    try testing.expectEqualStrings("Connect to production", profiles[1].palette_title.?);
    try testing.expectEqual(@as(usize, 2), profiles[1].command.direct.len);
    try testing.expectEqualStrings(
        "C:\\Windows\\System32\\OpenSSH\\ssh.exe",
        profiles[1].command.direct[0],
    );
    try testing.expectEqualStrings("production", profiles[1].command.direct[1]);
}

test "ssh executable resolution prefers PATH then System32 fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const from_path = (try resolveSshExecutable(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            try testing.expectEqualStrings("ssh.exe", exe);
            return try a.dupe(u8, "C:\\Tools\\OpenSSH\\ssh.exe");
        }
    }.lookup, struct {
        fn access(_: []const u8) !void {
            return error.Unexpected;
        }
    }.access)).?;
    defer alloc.free(from_path);
    try testing.expectEqualStrings("C:\\Tools\\OpenSSH\\ssh.exe", from_path);

    const fallback = (try resolveSshExecutable(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup, struct {
        fn access(path: []const u8) !void {
            try testing.expectEqualStrings(
                "C:\\Windows\\System32\\OpenSSH\\ssh.exe",
                path,
            );
        }
    }.access)).?;
    defer alloc.free(fallback);
    try testing.expectEqualStrings("C:\\Windows\\System32\\OpenSSH\\ssh.exe", fallback);

    // A PATH lookup error is not fatal: it falls through to the same fallback.
    const after_lookup_error = (try resolveSshExecutable(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) anyerror!?[]u8 {
            return error.AccessDenied;
        }
    }.lookup, struct {
        fn access(_: []const u8) !void {}
    }.access)).?;
    defer alloc.free(after_lookup_error);
    try testing.expectEqualStrings("C:\\Windows\\System32\\OpenSSH\\ssh.exe", after_lookup_error);

    // Neither present: no SSH entries are produced at all.
    try testing.expectEqual(@as(?[]u8, null), try resolveSshExecutable(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup, struct {
        fn access(_: []const u8) !void {
            return error.FileNotFound;
        }
    }.access));
}

test "profileOrderTokenMatches supports Windows profile aliases" {
    const testing = std.testing;

    try testing.expect(profileOrderTokenMatches("pwsh", .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("git", .{
        .kind = .git_bash,
        .key = "git-bash",
        .label = "Git Bash",
        .command = .{ .direct = &.{"bash.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("windows-powershell", .{
        .kind = .powershell,
        .key = "powershell.exe",
        .label = "Windows PowerShell",
        .command = .{ .direct = &.{"powershell.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("Ubuntu", .{
        .kind = .wsl_distro,
        .key = "Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "~" } },
    }));
    try testing.expect(!profileOrderTokenMatches("cmd", .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    }));
}

test "listProfilesWithLookupAndProbeAndWslListAndOrder reorders windows profiles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "powershell.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (std.mem.eql(u8, exe, "bash.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\bin\\bash.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return true;
        }
    }.probe, struct {
        fn list(alloc_: Allocator, _: []const u8) ![][]u8 {
            var values: std.ArrayList([]u8) = .empty;
            try values.append(alloc_, try alloc_.dupe(u8, "Ubuntu"));
            try values.append(alloc_, try alloc_.dupe(u8, "Debian"));
            return try values.toOwnedSlice(alloc_);
        }
    }.list, "git,pwsh,Ubuntu,cmd", null);
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 7), profiles.len);
    try testing.expectEqual(ProfileKind.git_bash, profiles[0].kind);
    try testing.expectEqual(ProfileKind.pwsh, profiles[1].kind);
    try testing.expectEqualStrings("WSL: Ubuntu", profiles[2].label);
    try testing.expectEqual(ProfileKind.cmd, profiles[3].kind);
    try testing.expectEqual(ProfileKind.wsl_default, profiles[4].kind);
}

test "previewCommandWithLookup prefers cmd over powershell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try previewCommandWithLookup(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            return null;
        }
    }.lookup);
    defer command.deinit(alloc);

    try testing.expect(command == .direct);
    try testing.expectEqual(@as(usize, 1), command.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe", command.direct[0]);
}

test "pathToWsl converts windows drive path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try pathToWsl(alloc, "C:\\Users\\aman\\src")).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/mnt/c/Users/aman/src", result);
}

test "pathToWsl converts wsl unc path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try pathToWsl(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman\\src")).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/home/aman/src", result);
}

test "osc7PathToLocal converts windows file uri path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try osc7PathToLocal(alloc, "/C:/Users/aman/src");
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\Users\\aman\\src", result);
}

test "osc7PathToLocal strips the uri slash from a unc path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const share = try osc7PathToLocal(alloc, "/\\\\server\\share\\dir");
    defer alloc.free(share);
    try testing.expectEqualStrings("\\\\server\\share\\dir", share);

    const root = try osc7PathToLocal(alloc, "/\\\\server\\share");
    defer alloc.free(root);
    try testing.expectEqualStrings("\\\\server\\share", root);

    // A UNC path pointing back into WSL is still normalized to a WSL path.
    const wsl = try osc7PathToLocal(alloc, "/\\\\wsl.localhost\\Ubuntu\\home\\aman");
    defer alloc.free(wsl);
    try testing.expectEqualStrings("/home/aman", wsl);

    // Real POSIX paths must not be mistaken for UNC.
    const posix = try osc7PathToLocal(alloc, "/home/aman/src");
    defer alloc.free(posix);
    try testing.expectEqualStrings("/home/aman/src", posix);

    // Backslashes are legal in POSIX filenames, so a POSIX cwd can start with
    // two of them. A forward slash later in the path proves it is not the
    // backslash-separated UNC form cmd's `$P` produces, so it stays POSIX.
    const posix_backslashes = try osc7PathToLocal(alloc, "/\\\\server/share");
    defer alloc.free(posix_backslashes);
    try testing.expectEqualStrings("/\\\\server/share", posix_backslashes);
}

test "isUncUriPath only matches uri-carried unc paths" {
    const testing = std.testing;

    try testing.expect(isUncUriPath("/\\\\server\\share"));
    try testing.expect(isUncUriPath("/\\\\s\\a"));
    try testing.expect(!isUncUriPath("/home/aman"));
    try testing.expect(!isUncUriPath("//server/share"));
    try testing.expect(!isUncUriPath("\\\\server\\share"));
    try testing.expect(!isUncUriPath("/\\\\"));
    try testing.expect(!isUncUriPath("/\\\\\\share"));
    try testing.expect(!isUncUriPath("/C:/Users"));
}

test "pathToWsl rejects a uri-carried unc path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(try pathToWsl(alloc, "/\\\\server\\share\\dir") == null);

    const wsl = (try pathToWsl(alloc, "/\\\\wsl.localhost\\Ubuntu\\home\\aman")).?;
    defer alloc.free(wsl);
    try testing.expectEqualStrings("/home/aman", wsl);
}

test "shellPwd drops invalid non-wsl cwd roots" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try shellPwd(alloc, "\\\\", false);
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "shellPwd preserves normalized wsl pwd for wsl launches" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try shellPwd(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman", true)).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/home/aman", result);
}

test "security regression windows shell pwd rejects control-bearing paths" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_][]const u8{
        "C:\\evil\x00INJ=1\x0Ab",
        "C:\\evil\x01child",
        "C:\\evil\tchild",
        "C:\\evil\rchild",
        "C:\\evil\nchild",
        "C:\\evil\x1Fchild",
        "C:\\evil\x7Fchild",
    }) |path| {
        try testing.expectEqual(@as(?[]const u8, null), try shellPwd(alloc, path, false));
    }

    const ordinary = (try shellPwd(alloc, "C:\\Users\\aman\\src", false)).?;
    defer alloc.free(ordinary);
    try testing.expectEqualStrings("C:\\Users\\aman\\src", ordinary);
}

test "security regression windows current directory rejects control-bearing paths" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectEqual(
        @as(?[]const u8, null),
        try safeCurrentDirectory(alloc, "C:\\evil\x00INJ=1\x0Ab", false, false),
    );
}

test "safeCurrentDirectory keeps inherit semantics for non-wsl shells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectoryWithCurrent(alloc, null, false, false, try alloc.dupe(u8, "C:\\Users\\amant"))).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\Users\\amant", result);
}

test "safeCurrentDirectory keeps an inherited cwd ahead of a home request" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // SSH launches ask for home with an explicit path rather than this flag,
    // so the pre-existing "inherited cwd wins" precedence stays intact.
    const result = (try safeCurrentDirectoryWithCurrent(
        alloc,
        null,
        true,
        false,
        try alloc.dupe(u8, "C:\\work"),
    )).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\work", result);
}

test "safeCurrentDirectory falls back to home for invalid cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectory(alloc, "\\\\", false, false)).?;
    defer alloc.free(result);

    try testing.expect(result.len > 2);
    try testing.expect(std.ascii.isAlphabetic(result[0]));
    try testing.expectEqual(@as(u8, ':'), result[1]);
}

test "safeCurrentDirectory falls back to home for inherited invalid cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectoryWithCurrent(alloc, null, false, false, try alloc.dupe(u8, "\\\\"))).?;
    defer alloc.free(result);

    try testing.expect(result.len > 2);
    try testing.expect(std.ascii.isAlphabetic(result[0]));
    try testing.expectEqual(@as(u8, ':'), result[1]);
}

test "prepareCommand injects translated cwd for wsl direct command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{"wsl.exe"});
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "D:\\work\\noctty", false, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/mnt/d/work/noctty", prepared.direct[2]);
}

test "prepareCommand replaces default wsl home sentinel with explicit cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "~" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "D:\\work\\noctty", false, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/mnt/d/work/noctty", prepared.direct[2]);
}

test "prepareCommand rewrites wsl home sentinel to explicit --cd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "~" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, null, true, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("~", prepared.direct[2]);
}

test "prepareCommand replaces existing wsl --cd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "--cd", "~", "--", "bash" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "/home/aman/src", false, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 5), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/home/aman/src", prepared.direct[2]);
    try testing.expectEqualStrings("--", prepared.direct[3]);
    try testing.expectEqualStrings("bash", prepared.direct[4]);
}

test "spawnCwd uses home for wsl-style cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman", false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "spawnCwd preserves drive cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "C:\\Users\\aman\\src", false);
    defer if (result) |v| alloc.free(v);

    try testing.expect(result != null);
    try testing.expectEqualStrings("C:\\Users\\aman\\src", result.?);
}

test "spawnCwd uses home when cwd is unset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, null, false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "spawnCwd uses home for non-absolute cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "\\\\", false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "shellIntegrationDiagnostic reports automatic PowerShell support" {
    const testing = std.testing;

    const pwsh = shellIntegrationDiagnostic(.pwsh);
    try testing.expectEqual(ShellIntegrationSupport.automatic, pwsh.support);
    try testing.expectEqualStrings(
        "PowerShell profile with automatic shell integration",
        pwsh.summary,
    );
    try testing.expectEqual(@as(?[]const u8, null), pwsh.next_step);

    const powershell = shellIntegrationDiagnostic(.powershell);
    try testing.expectEqual(ShellIntegrationSupport.automatic, powershell.support);
    try testing.expectEqualStrings(
        "Windows PowerShell profile with automatic shell integration",
        powershell.summary,
    );
}

test "shellIntegrationDiagnostic differentiates WSL Git Bash and cmd support" {
    const testing = std.testing;

    const wsl_default = shellIntegrationDiagnostic(.wsl_default);
    try testing.expectEqual(ShellIntegrationSupport.shell_managed, wsl_default.support);
    try testing.expectEqualStrings(
        "WSL default profile; shell integration depends on the Linux shell",
        wsl_default.summary,
    );
    try testing.expectEqualStrings(
        wsl_shell_integration_next_step,
        wsl_default.next_step.?,
    );

    const wsl = shellIntegrationDiagnostic(.wsl_distro);
    try testing.expectEqual(ShellIntegrationSupport.shell_managed, wsl.support);
    try testing.expectEqualStrings(
        "WSL distro profile; shell integration depends on the Linux shell",
        wsl.summary,
    );
    try testing.expectEqualStrings(wsl_shell_integration_next_step, wsl.next_step.?);

    const git_bash = shellIntegrationDiagnostic(.git_bash);
    try testing.expectEqual(ShellIntegrationSupport.automatic, git_bash.support);
    try testing.expectEqualStrings(
        "Git Bash profile with automatic shell integration",
        git_bash.summary,
    );
    try testing.expectEqual(@as(?[]const u8, null), git_bash.next_step);

    const cmd = shellIntegrationDiagnostic(.cmd);
    try testing.expectEqual(ShellIntegrationSupport.automatic, cmd.support);
    try testing.expectEqualStrings(
        "Command Prompt profile with PROMPT-based shell integration; Clink adds command-start/finish and exit-code marks",
        cmd.summary,
    );
    try testing.expectEqual(@as(?[]const u8, null), cmd.next_step);
}

test "utf8-console decision covers modes and guarded code pages" {
    const testing = std.testing;

    const cases = [_]struct {
        mode: Utf8Console,
        western: bool,
        cjk: bool,
        utf8: bool,
    }{
        .{ .mode = .auto, .western = true, .cjk = false, .utf8 = true },
        .{ .mode = .always, .western = true, .cjk = true, .utf8 = true },
        .{ .mode = .never, .western = false, .cjk = false, .utf8 = false },
    };

    for (cases) |case| {
        try testing.expectEqual(case.western, shouldApplyUtf8Console(case.mode, 1252, 437));
        try testing.expectEqual(case.cjk, shouldApplyUtf8Console(case.mode, 932, 932));
        try testing.expectEqual(case.utf8, shouldApplyUtf8Console(case.mode, 65001, 65001));
    }

    for ([_]u32{ 932, 936, 949, 950, 1361 }) |code_page| {
        try testing.expect(!shouldApplyUtf8Console(.auto, code_page, 437));
        try testing.expect(!shouldApplyUtf8Console(.auto, 1252, code_page));
    }

    for ([_]Utf8Console{ .auto, .always }) |mode| {
        try testing.expect(shouldApplyUtf8Console(mode, 65001, 437));
        try testing.expect(shouldApplyUtf8Console(mode, 1252, 65001));
    }

    try testing.expect(!shouldApplyUtf8Console(.never, 65001, 437));
    try testing.expect(!shouldApplyUtf8Console(.never, 1252, 65001));
}

test "utf8-console cmd preamble leaves payload launches unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const lookup = struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup;

    const bare = try directCommand(alloc, &.{"cmd.exe"});
    defer bare.deinit(alloc);
    const prepared_bare = try prepareCommandWithLookup(alloc, bare, null, false, true, lookup);
    defer prepared_bare.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), prepared_bare.direct.len);
    try testing.expectEqualStrings("cmd.exe", prepared_bare.direct[0]);
    try testing.expectEqualStrings("/K", prepared_bare.direct[1]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_bare.direct[2]);

    const prepared_never = try prepareCommandWithLookup(
        alloc,
        bare,
        null,
        false,
        shouldApplyUtf8Console(.never, 1252, 437),
        lookup,
    );
    defer prepared_never.deinit(alloc);

    try testing.expect(prepared_never == .direct);
    try testing.expectEqual(@as(usize, 1), prepared_never.direct.len);
    try testing.expectEqualStrings("cmd.exe", prepared_never.direct[0]);

    const with_tail = try directCommand(alloc, &.{ "cmd.exe", "/c", "echo ok" });
    defer with_tail.deinit(alloc);
    const prepared_tail = try prepareCommandWithLookup(alloc, with_tail, null, false, true, lookup);
    defer prepared_tail.deinit(alloc);

    try testing.expectEqual(with_tail.direct.len, prepared_tail.direct.len);
    for (with_tail.direct, prepared_tail.direct) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    const shell_bare: Command = .{ .shell = "\"C:\\Windows\\System32\\cmd.exe\"" };
    const prepared_shell_bare = try prepareCommandWithLookup(alloc, shell_bare, null, false, true, lookup);
    defer prepared_shell_bare.deinit(alloc);

    try testing.expect(prepared_shell_bare == .direct);
    try testing.expectEqual(@as(usize, 3), prepared_shell_bare.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe", prepared_shell_bare.direct[0]);
    try testing.expectEqualStrings("/K", prepared_shell_bare.direct[1]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_shell_bare.direct[2]);

    const trampoline: Command = .{ .shell = "cmd.exe /c echo ok" };
    const prepared_trampoline = try prepareCommandWithLookup(alloc, trampoline, null, false, true, lookup);
    defer prepared_trampoline.deinit(alloc);

    try testing.expect(prepared_trampoline == .shell);
    try testing.expectEqualStrings("cmd.exe /c echo ok", prepared_trampoline.shell);
}

test "classifyCmdArg separates option-only switches from payload switches" {
    const testing = std.testing;

    for ([_][]const u8{
        "/d",      "/Q",      "/a",    "/u",      "/s",
        "/d/q",    "/D/Q/A",  "/e:on", "/E:OFF",  "/f:off",
        "/v:on",   "/t:0A",   "/t:f",  "/d/v:on", "/v:on/q",
        "/t:0a/q", "/s/d",
        // `cmd /?`: "for compatibility reasons, /X is the same as /E:ON,
        // /Y is the same as /E:OFF". Both are valueless.
           "/x",    "/Y",      "/x/q",
        "/d/y",    "/x/v:on",
    }) |arg| {
        try testing.expectEqual(CmdArg.option, classifyCmdArg(arg));
    }

    for ([_][]const u8{
        // Payload switches, separate and fused.
        "/c",       "/K",         "/r",     "/d/q/c", "/v:on/c",
        "/e:on/k",  "/cecho",     "/Kchcp", "/s/c",
        // Not a switch at all: cmd has no `-` prefix.
          "-c",
        "-d",       "script.bat",
        // Malformed or unknown switch runs.
        "/",      "/z",     "/e",
        "/e:maybe", "/t",         "/t:",    "/t:zz",  "/d/",
        "/v:onx",
    }) |arg| {
        try testing.expectEqual(CmdArg.unsupported, classifyCmdArg(arg));
    }
}

test "utf8-console cmd preamble preserves option-only switches" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const lookup = struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup;

    // Separate switches keep their order and gain the preamble.
    const separate = try directCommand(alloc, &.{ "cmd.exe", "/d", "/q" });
    defer separate.deinit(alloc);
    const prepared_separate = try prepareCommandWithLookup(alloc, separate, null, false, true, lookup);
    defer prepared_separate.deinit(alloc);

    try testing.expectEqual(@as(usize, 5), prepared_separate.direct.len);
    try testing.expectEqualStrings("cmd.exe", prepared_separate.direct[0]);
    try testing.expectEqualStrings("/d", prepared_separate.direct[1]);
    try testing.expectEqualStrings("/q", prepared_separate.direct[2]);
    try testing.expectEqualStrings("/K", prepared_separate.direct[3]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_separate.direct[4]);

    // Combined switch runs are preserved verbatim.
    const combined = try directCommand(alloc, &.{ "cmd.exe", "/d/q", "/v:on" });
    defer combined.deinit(alloc);
    const prepared_combined = try prepareCommandWithLookup(alloc, combined, null, false, true, lookup);
    defer prepared_combined.deinit(alloc);

    try testing.expectEqual(@as(usize, 5), prepared_combined.direct.len);
    try testing.expectEqualStrings("/d/q", prepared_combined.direct[1]);
    try testing.expectEqualStrings("/v:on", prepared_combined.direct[2]);
    try testing.expectEqualStrings("/K", prepared_combined.direct[3]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_combined.direct[4]);

    // A shell-form option-only launch normalizes into direct argv.
    const shell_options: Command = .{ .shell = "\"C:\\Windows\\System32\\cmd.exe\" /d /q" };
    const prepared_shell = try prepareCommandWithLookup(alloc, shell_options, null, false, true, lookup);
    defer prepared_shell.deinit(alloc);

    try testing.expect(prepared_shell == .direct);
    try testing.expectEqual(@as(usize, 5), prepared_shell.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe", prepared_shell.direct[0]);
    try testing.expectEqualStrings("/K", prepared_shell.direct[3]);

    // A fused payload switch after options is still left untouched.
    for ([_][]const []const u8{
        &.{ "cmd.exe", "/d", "/q", "/c", "echo ok" },
        &.{ "cmd.exe", "/d/q/c", "echo ok" },
        &.{ "cmd.exe", "/v:on/c", "echo ok" },
        &.{ "cmd.exe", "/k", "echo ok" },
        &.{ "cmd.exe", "/cecho ok" },
    }) |argv| {
        const original = try directCommand(alloc, argv);
        defer original.deinit(alloc);
        const prepared = try prepareCommandWithLookup(alloc, original, null, false, true, lookup);
        defer prepared.deinit(alloc);

        try testing.expectEqual(original.direct.len, prepared.direct.len);
        for (original.direct, prepared.direct) |expected, actual| {
            try testing.expectEqualStrings(expected, actual);
        }
    }
}
