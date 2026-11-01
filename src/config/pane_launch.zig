//! Which command a new pane runs, from which profile, with which variables and
//! directory.
//!
//! `prepare` gives a new pane's config the launch its `Origin` calls for and
//! says what the pane records of it (`Stamp`).
//!
//! `Config.parseManuallyHook` and `consumeManuallyHook` hand each argument to
//! `note` and `consume`, which keep the command line's accepted `--command=`,
//! `--initial-command=` and `--default-profile=`, which layer set `command`,
//! where each `profile-*` line was read and the `--elevated-profile-env=`
//! values. `finalize`, which `Config.finalize` calls before its automatic
//! default, checks the profile fields and references, puts the command line's
//! launch values back over the files read after it, resolves
//! `default-profile` through a machine (`windows_shell.ReferenceHost`, or
//! `fixtures.Machine` in tests) and puts the elevated profile's variables over
//! `env`. `useRecovery` (Safe Recovery, before `Config.finalize`) and
//! `useAutomatic` (the automatic default) set a `command` noctty chose.
//!
//! What a load decided lives in `Config`'s `_` launch fields.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Command = @import("command.zig").Command;
const ProfileMap = @import("profile_map.zig");
const windows_shell = @import("windows_shell.zig");
const windows_ssh_hosts = @import("windows_ssh_hosts.zig");
const internal_os = @import("../os/main.zig");
const cli_diags = @import("../cli/diagnostics.zig");

const cli = struct {
    const args = @import("../cli/args.zig");
    const Diagnostic = cli_diags.Diagnostic;
    const Location = cli_diags.Location;
};

const log = std.log.scoped(.config);

/// How a new pane comes to be, which decides what of a launch it takes.
pub const Origin = union(enum) {
    /// A pane nothing chose a launch for: the first window, a plain new tab
    /// or window, the quick terminal, a forwarded new window. It runs
    /// `default-profile`'s profile when one applies (`defaultApplies`).
    fresh: Fresh,
    /// A tab or split that repeats the source pane's launch as it started
    /// (automation's `+new-tab`, `+new-split`).
    inherit: Source,
    /// An ordinary split, which starts the source pane's profile as it is
    /// defined now.
    split: Source,
    /// A profile chosen from the picker, the palette or a quick slot.
    chosen: *const windows_shell.Profile,
    /// A Session Layout pane, by the profile key it was saved with.
    restored: ?[]const u8,

    pub const Fresh = struct {
        /// The launch named its directory (`--working-directory=` on noctty's
        /// command line, or in a forwarded new window's arguments), which
        /// wins over the one the default profile pins: the default replaces
        /// what runs, not where such a launch starts. An SSH profile keeps its
        /// own: a local directory means nothing to the remote shell.
        named_directory: bool = false,
    };
};

/// What a source pane launched, as it recorded it (`Stamp`): the command it
/// started, a user profile's line and variables, its profile key, and
/// whether it connects over SSH.
pub const Source = struct {
    command: ?Command = null,
    user: ?windows_shell.UserLaunch = null,
    key: ?[]const u8 = null,
    ssh: bool = false,
};

/// What a new pane records of its launch (`SurfaceInitOptions.launch`): the
/// key a split, a restore and elevation look its profile up by, whether it
/// connects over SSH, the SSH alias as its tab title, and a user profile's
/// line and variables, which the tabs and splits that repeat its launch run.
/// It borrows from the pane's config and what the pane started from (the
/// profile, the source pane, the saved key), so the window gets it before
/// that config is freed.
pub const Stamp = struct {
    key: ?[]const u8 = null,
    ssh: bool = false,
    title: ?[]const u8 = null,
    user: ?windows_shell.UserLaunch = null,
};

/// Give `pane` the launch `origin` calls for, and say what the pane records
/// of it. `pane` is the new pane's shallow clone of the app config
/// (`apprt.surface.newConfig`), never the app config itself, and everything
/// written goes into its arena: `command` is replaced, never freed (the old
/// value is the app config's), and `env` is replaced by a copy. Call it once
/// the pane's base directory is set, and before a directory the launch asks
/// for (an automation `cwd`, a restored pane's) goes over it; a split's own
/// directory inheritance comes after it too, since it reads the command
/// started (WSL) and whether it is SSH. `context` is what the app knows of
/// the pane:
///
/// - `first`: whether it is the process's first pane, which runs
///   `initial-command` (`-e`) and no profile;
/// - `windowed()`: whether the pane opens in a window, whose list `listed`
///   reads;
/// - `listed(key)`: that window's profile for `key`, or null;
/// - `discover(alloc)`: every profile, listed for a pane with no window
///   (discovery starts WSL probes); `prepare` frees the list;
/// - `automatic(alloc)`: the automatic default command.
///
/// A key `default-profile` resolved to is answered from the config, with no
/// list. The Stamp borrows from `pane`, the source pane and the saved key,
/// never from a discovered list.
pub fn prepare(pane: *Config, origin: Origin, context: anytype) !Stamp {
    switch (origin) {
        .fresh => |fresh| return try startDefault(pane, fresh.named_directory, context.first),
        .inherit => |source| {
            const command = source.command orelse return try startSource(pane, source, context);
            // The snapshot, not the current definition: a reload since the
            // source started does not change what an inherited launch runs.
            pane.command = try command.clone(pane._arena.?.allocator());
            pane._command_defaulted = false;
            const user = if (source.user) |launch| try useUserLaunch(pane, launch) else null;
            if (source.ssh) try hardenSsh(pane);
            return .{ .key = source.key, .ssh = source.ssh, .user = user };
        },
        .split => |source| return try startSource(pane, source, context),
        .chosen => |profile| {
            var stamp = try startChosen(pane, profile);
            stamp.title = windows_shell.sshProfileAlias(profile);
            return stamp;
        },
        .restored => |saved| {
            // The ordinary first window runs `initial-command` (`-e`, or the
            // option), which `Surface.init` prefers while the process's
            // first pane is made: the first pane of a restored session or a
            // launched layout would run the wrong command.
            pane.@"initial-command" = null;
            // Only its own profile leaves its key on the pane: a later split
            // of the restored pane would look a refused one up again.
            if (saved) |key| {
                if (try startRestored(pane, key, context)) |stamp| return .{ .key = key, .user = stamp.user };
            }
            // Restore never connects over SSH by itself: with an SSH
            // `default-profile` the pane gets the automatic shell, in place
            // of the SSH command the load made the default (a session saves
            // an SSH pane without its profile).
            if (defaultApplies(pane, context.first) and defaultProfile(pane).?.kind == .ssh) {
                setAutomaticCommand(pane, "windows-default", try context.automatic(pane._arena.?.allocator()));
                return .{};
            }
            return try startDefault(pane, false, context.first);
        },
    }
}

/// The source pane's profile as defined now, by its key, else the default
/// profile, for a source that recorded no profile or one no longer there.
fn startSource(pane: *Config, source: Source, context: anytype) !Stamp {
    if (source.key) |key| {
        if (defaultProfileForKey(pane, key) orelse try context.listed(key)) |profile| return try startProfile(pane, profile);
    }
    return try startDefault(pane, false, context.first);
}

/// A profile started for itself (chosen, restored): in home, unless it pins
/// a directory of its own or asks for the ordinary rules (`inherit`), which
/// `startProfile` gives it.
fn startChosen(pane: *Config, profile: *const windows_shell.Profile) !Stamp {
    if (profile.working_directory == null) pane.@"working-directory" = try homeDirectory(pane, profile);
    return try startProfile(pane, profile);
}

/// A Session Layout pane's own profile, by its saved key: `default-profile`'s
/// with no list, else its window's, else, with no window yet, the one
/// discovery lists. Restore relaunches a pane unattended at startup, and an
/// SSH profile would dial out with no interaction, so it is refused: by the
/// key's prefix in any case before any lookup (a state file's case variant
/// misses the exact SSH lookup, and so would slip past a refusal by kind),
/// and by its kind after. Null when nothing restorable has the key.
fn startRestored(pane: *Config, key: []const u8, context: anytype) !?Stamp {
    if (std.ascii.startsWithIgnoreCase(key, "ssh:")) return null;
    if (defaultProfileForKey(pane, key)) |profile| return try startSaved(pane, profile);
    if (context.windowed()) return try startSaved(pane, (try context.listed(key)) orelse return null);
    const alloc = pane._arena.?.child_allocator;
    const profiles = try context.discover(alloc);
    defer windows_shell.deinitProfiles(alloc, profiles);
    for (profiles) |*profile| {
        if (windows_shell.profileKeyEquals(profile.*, key)) return try startSaved(pane, profile);
    }
    return null;
}

fn startSaved(pane: *Config, profile: *const windows_shell.Profile) !?Stamp {
    if (profile.kind == .ssh) return null;
    return try startChosen(pane, profile);
}

/// Whether a pane nothing chose a launch for runs `default-profile`'s
/// profile: the load resolved one and no launch replaced its command since,
/// and the pane is not the first one of a process with `initial-command`
/// (`-e`), whichever path creates it, which runs that command.
pub fn defaultApplies(config: *const Config, first: bool) bool {
    if (!config._command_defaulted or config._default_profile == null) return false;
    return !(config.@"initial-command" != null and first);
}

/// `default-profile`'s launch, for a pane nothing chose one for. The load
/// made the profile's command the default `command`; this gives the pane the
/// rest of it, as a pick from the picker gets it, except that with no
/// `profile-working-directory` the directory the ordinary rules gave stays,
/// as for `command`.
fn startDefault(pane: *Config, named_directory: bool, first: bool) !Stamp {
    if (!defaultApplies(pane, first)) return .{};
    const profile = defaultProfile(pane).?;
    const directory = pane.@"working-directory";
    var stamp = try startProfile(pane, profile);
    if (named_directory and profile.kind != .ssh) pane.@"working-directory" = directory;
    stamp.title = windows_shell.sshProfileAlias(profile);
    return stamp;
}

/// Start `profile` on `pane`, with what has to hold on every launch path: a
/// user profile's line and variables, its pinned directory (a path, `home`,
/// or `inherit`, which leaves the ordinary rules' directory), and an SSH
/// profile's hardening. A split's own directory inheritance, applied after
/// this, still replaces the directory.
fn startProfile(pane: *Config, profile: *const windows_shell.Profile) !Stamp {
    const alloc = pane._arena.?.allocator();
    pane.command = try profile.command.clone(alloc);
    // `default-profile` no longer applies to this pane.
    pane._command_defaulted = false;
    const user = if (profile.user) |launch| try useUserLaunch(pane, launch) else null;
    if (profile.working_directory) |dir| switch (dir) {
        .path => |path| pane.@"working-directory" = .{ .path = try alloc.dupe(u8, path) },
        .home => pane.@"working-directory" = try homeDirectory(pane, profile),
        .inherit => {},
    };
    if (profile.kind == .ssh) try hardenSsh(pane);
    return .{ .key = profile.key, .ssh = profile.kind == .ssh, .user = user };
}

/// Give `pane` a user profile's variables and command line, and return its
/// copy of the line. The variables go on a copy: a shallow clone shares the
/// app config's map, so writing into it would change every later launch. A
/// profile variable replaces a global `env` variable of the same name in any
/// case, as Windows compares names (a profile `PATH` replaces a global
/// `Path`).
fn useUserLaunch(pane: *Config, launch: windows_shell.UserLaunch) !windows_shell.UserLaunch {
    const alloc = pane._arena.?.allocator();
    var env = try pane.env.clone(alloc);
    try windows_shell.layerEnv(alloc, &env, launch.env);
    pane.env = env;
    return try launch.clone(alloc);
}

/// Home for a profile launch. A bare `.home` set on a pane's config after
/// `Config.finalize` is not resolved again: Exec then starts the program in
/// noctty's own current directory (measured: the directory noctty was
/// started in), so a profile gets the path itself. For a Start menu launch
/// that directory is the install folder, the start folder of the installer's
/// shortcut (read from the installed `.lnk`, not measured by a launch). Only
/// a profile that runs `wsl.exe` keeps `.home`, which gives it `--cd ~` (the
/// Linux home) where a Windows path would give `--cd /mnt/c/Users/<name>`.
fn homeDirectory(pane: *Config, profile: *const windows_shell.Profile) !Config.WorkingDirectory {
    if (windows_shell.isWslCommand(profile.command)) return .home;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (internal_os.home(&buf) catch null) orelse return .home;
    return .{ .path = try pane._arena.?.allocator().dupe(u8, home) };
}

fn hardenSsh(pane: *Config) !void {
    // Shell integration injection rewrites the two-element ssh argv into a
    // space-joined, unquoted `cmd.exe /C` string. A remote session cannot use
    // it anyway: the integration scripts run locally.
    pane.@"shell-integration" = .none;

    // `.home` alone loses to an inherited working directory, so resolve the
    // path explicitly and let the drive-absolute branch of the cwd resolver
    // take it. This is the same directory `ssh` itself expands `~` to.
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (try windows_ssh_hosts.userProfileDir(&home_buf)) |home| {
        pane.@"working-directory" = .{ .path = try pane._arena.?.allocator().dupe(u8, home) };
    }
}

/// What `arg` sets of the launch, read before the field parse
/// (`Config.parseManuallyHook` calls this first): the command line's accepted
/// `--command=`, `--initial-command=` and `--default-profile=`, the files'
/// `default-profile`, which layer set `command`, and where a profile line was
/// read.
pub fn note(config: *Config, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!void {
    // Only a value the field parse takes changes `command` (and so which layer
    // set it, and what `finalize` puts back); a refused one leaves all of
    // that as it was and is reported by the parse that follows.
    if (try takenCliValue(config, "command", arg)) |value| {
        const location = try cli.Location.fromIter(iter, alloc);
        config._command_defaulted = false;
        config._command_from_file = location == .file;
        if (location == .cli) config._command_cli = try alloc.dupeZ(u8, value);
    }
    if (std.mem.startsWith(u8, arg, "--initial-command=")) {
        if ((try cli.Location.fromIter(iter, alloc)) == .cli) {
            if (try takenCliValue(config, "initial-command", arg)) |value| {
                config._initial_command_cli = try alloc.dupeZ(u8, value);
            }
        }
    }
    if (std.mem.startsWith(u8, arg, "--default-profile=")) {
        const value = arg["--default-profile=".len..];
        if ((try cli.Location.fromIter(iter, alloc)) == .cli) {
            config._default_profile_cli = try alloc.dupeZ(u8, value);
        } else {
            config._default_profile_file = if (value.len == 0) null else try alloc.dupeZ(u8, value);
        }
    }
    // The place a profile line writes, for a problem only finalize sees.
    try recordProfilePlace(config, alloc, arg, iter);
}

/// `Config.consumeManuallyHook`: takes `--elevated-profile-env=KEY=VALUE`.
pub fn consume(
    config: *Config,
    alloc: Allocator,
    arg: []const u8,
    iter: anytype,
) !bool {
    if (builtin.os.tag != .windows) return false;
    const prefix = "--elevated-profile-env=";
    if (!std.mem.startsWith(u8, arg, prefix)) return false;
    const location = try cli.Location.fromIter(iter, alloc);
    const value = arg[prefix.len..];
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse 0;
    // A config file line reaches here as the same argument. Only the
    // command line may set it, or an included file could replace a value
    // that exists to win over every file.
    const refused: ?[:0]const u8 = if (location == .file) "unknown field" else if (eq == 0) "value required" else null;
    if (refused) |message| {
        try config._diagnostics.append(alloc, .{
            .key = try alloc.dupeZ(u8, "elevated-profile-env"),
            .message = message,
            .location = location,
        });
        return true;
    }
    try config._elevated_profile_env.append(alloc, .{
        .key = try alloc.dupeZ(u8, value[0..eq]),
        .value = try alloc.dupeZ(u8, value[eq + 1 ..]),
    });
    return true;
}

/// The launch half of `Config.finalize`, after the theme and before the
/// automatic default. Tests resolve `default-profile` through fixed lookups
/// (no PATH search), so they load it through this same call.
pub fn finalize(config: *Config) !void {
    const visual_studio = config.@"visual-studio-profiles";
    try finalizeWith(config, if (comptime builtin.is_test)
        fixtures.Machine{ .visual_studio = visual_studio }
    else
        windows_shell.ReferenceHost{ .visual_studio = visual_studio });
}

/// `finalize` with the lookups `machine` makes for `default-profile`.
pub fn finalizeWith(config: *Config, machine: anytype) !void {
    // Before the default command: `default-profile` can name a user profile,
    // which has to have passed these checks.
    try finalizeProfiles(config);
    try finalizeCliLaunch(config);
    try finalizeDefaultProfileSetting(config);
    // `default-profile` stands in for the automatic default.
    if (comptime builtin.os.tag == .windows) {
        if (config.command == null) try applyDefaultProfile(config, machine);
    }
    // Over `env` once every file has been read, and after `default-profile`
    // resolved: a profile's `%NAME%` reads `env` (`expandProfileText`).
    if (config._elevated_profile_env.items.len > 0) {
        try windows_shell.layerEnv(config._arena.?.allocator(), &config.env, config._elevated_profile_env.items);
    }
}

/// Resolve the automatic Windows command without hiding whether it was explicit.
pub fn useAutomatic(config: *Config) !void {
    if (config.command != null) return;
    setAutomaticCommand(config, "windows-default", try windows_shell.defaultCommand(config._arena.?.allocator()));
}

/// Give a config with no `command` the one safe mode starts, so a recovery
/// launch runs neither the user's PowerShell profile nor AutoRun. Call it before
/// `Config.finalize`, which then has no default to look for: safe mode
/// searches no `PATH`. The command stays marked automatic. A command already
/// set stays.
pub fn useRecovery(config: *Config) !void {
    if (config.command != null) return;
    setAutomaticCommand(config, "windows-recovery", try windows_shell.recoveryCommand(config._arena.?.allocator()));
}

/// Set `command` to `cmd`, chosen by noctty rather than a config layer.
fn setAutomaticCommand(config: *Config, comptime src: []const u8, cmd: Command) void {
    log.info("default shell src=" ++ src ++ " value={f}", .{cmd.redacted()});
    config.command = cmd;
    config._command_defaulted = true;
}

/// The profile `default-profile` resolved to when the config was loaded. A
/// launch that later replaces `command` (a chosen profile, an inherited
/// one) leaves it set, so whether it is what a pane starts also needs
/// `nocttyCommand`.
pub fn defaultProfile(config: *const Config) ?*const windows_shell.Profile {
    return if (config._default_profile) |*profile| profile else null;
}

/// `default-profile`'s profile when `key` names it. A pane it started
/// carries its key, and the config holds the profile resolved, so a split,
/// an elevated window or a restore of that pane needs no list (no WSL probe
/// on the UI thread) and finds the profile though discovery may list none
/// such: an alias outside the SSH config, a distribution WSL did not list.
pub fn defaultProfileForKey(config: *const Config, key: []const u8) ?*const windows_shell.Profile {
    const profile = defaultProfile(config) orelse return null;
    return if (windows_shell.profileKeyEquals(profile.*, key)) profile else null;
}

/// The command noctty chose: the automatic default, Safe Recovery's or
/// `default-profile`'s. Null when a config layer set `command`, or when none
/// is set.
pub fn nocttyCommand(config: *const Config) ?Command {
    return if (config._command_defaulted) config.command else null;
}

/// What the loaded config made of `reference`, a `default-profile` value
/// (Settings' Default profile row asks). It looked its own value up, `vs:`
/// keys included. It did not look at a value the command line or a
/// `command` line kept it from using, or at one that is not its value.
pub fn outcome(config: *const Config, reference: ?[]const u8) Outcome {
    const value = config.@"default-profile" orelse return .untried;
    if (reference == null or !std.mem.eql(u8, value, reference.?)) return .untried;
    if (defaultProfile(config)) |profile| return .{ .resolved = profile };
    return switch (config._default_profile_failure) {
        .none => .untried,
        .not_found => .not_found,
        .unavailable => .unavailable,
    };
}

pub const Outcome = union(enum) {
    /// Not looked up.
    untried,
    /// The profile new terminals start.
    resolved: *const windows_shell.Profile,
    /// It names nothing that can start here: new terminals start the
    /// automatic default.
    not_found,
    /// Visual Studio did not answer the lookup in full: new terminals start
    /// the automatic default until a reload asks again, and the value may
    /// be right.
    unavailable,
};

/// The `default-profile` the config files give: the setting itself, unless
/// noctty's command line named one, which wins in this process only.
pub fn filesDefaultProfile(config: *const Config) ?[:0]const u8 {
    if (config._default_profile_cli == null) return config.@"default-profile";
    return config._default_profile_file;
}

/// Whether noctty's command line names a profile
/// (`--default-profile=<reference>`, which a jump-list link to a user
/// profile carries). An empty value names none.
pub fn commandLineNamesProfile(config: *const Config) bool {
    const reference = config._default_profile_cli orelse return false;
    return reference.len > 0;
}

/// Whether the config files alone give the profile `key`, so a process that
/// reads only them finds it as this one does: a Visual Studio shell, which
/// discovery finds as the picker does, or a user profile whose live
/// `profile-command` line was read from a config file. Not a profile defined
/// only by a `--profile-command` option, nor one given a variable on the
/// command line (`--profile-env=<id>: ...`, or a `--profile-env=` that
/// cleared them), nor any while an `--env=` argument is set, which `%NAME%`
/// in a profile's lines may read.
pub fn filesDefine(config: *const Config, key: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(key, "vs:")) return true;
    if (!std.ascii.startsWithIgnoreCase(key, "user:")) return false;
    const id = key["user:".len..];
    if (config.@"profile-command".get(id) == null) return false;
    if (profilePlace(config, "profile-command", id) != .file) return false;
    if (profileWrittenOnCommandLine(config, "profile-env", id)) return false;
    return !commandLineSetsEnv(config);
}

/// Make a copy of the app's config hold what the config files say, which is
/// what Settings shows and saves: no `command` when noctty chose it (the
/// automatic default, `default-profile`'s), and the files' `default-profile`
/// when noctty's command line named another one for this process (a
/// jump-list link's, an elevated window's). The copy then holds no choice
/// of noctty's: a `command` an edit gives it is the user's, and it resolved
/// no `default-profile` (`defaultProfile` is null, `outcome` is `.untried`),
/// since the load looked up another value or none.
pub fn asWritten(config: *Config) void {
    if (config._command_defaulted) config.command = null;
    config._command_defaulted = false;
    config.@"default-profile" = filesDefaultProfile(config);
    config._default_profile = null;
    config._default_profile_failure = .none;
}

/// Give `dst`, a config built again from the files (a palette theme
/// preview's, a forwarded new window's), what `src`, the running config,
/// launches from: the profile sources (the `profile-*` keys,
/// `visual-studio-profiles`, `ssh-config-hosts`, `env`, which a profile's
/// `%NAME%` reads, and where their lines were read) and the launch `src`
/// resolved (`command`, the `default-profile` profile and what Settings
/// reads of it). A profile line edited on disk since the last reload would
/// otherwise reach new terminals while the hosts' lists, the jump list and
/// a running discovery hold the old one; the lists are only dropped on a
/// reload, which then sees the change. Call it after `dst`'s last
/// `finalize`: with a `theme` set, `finalize` builds the config again from
/// its replay steps and drops what was put on it.
pub fn keepSources(dst: *Config, src: *const Config) Allocator.Error!void {
    const alloc = dst._arena.?.allocator();
    dst.command = if (src.command) |command| try command.clone(alloc) else null;
    dst._command_defaulted = src._command_defaulted;
    dst._command_from_file = src._command_from_file;
    dst.@"default-profile" = if (src.@"default-profile") |reference| try alloc.dupeZ(u8, reference) else null;
    dst._default_profile = if (src._default_profile) |profile| try profile.clone(alloc) else null;
    // And what Settings reads of it: whether the lookup found nothing, and
    // the files' value beside a command line's.
    dst._default_profile_failure = src._default_profile_failure;
    dst._default_profile_cli = if (src._default_profile_cli) |value| try alloc.dupeZ(u8, value) else null;
    dst._default_profile_file = if (src._default_profile_file) |value| try alloc.dupeZ(u8, value) else null;
    dst.@"ssh-config-hosts" = src.@"ssh-config-hosts";
    dst.env = try src.env.clone(alloc);
    dst.@"visual-studio-profiles" = src.@"visual-studio-profiles";
    dst.@"profile-command" = try src.@"profile-command".clone(alloc);
    dst.@"profile-name" = try src.@"profile-name".clone(alloc);
    dst.@"profile-working-directory" = try src.@"profile-working-directory".clone(alloc);
    dst.@"profile-env" = try src.@"profile-env".clone(alloc);
    dst.@"profile-order" = try src.@"profile-order".clone(alloc);
    dst.@"profile-hidden" = try src.@"profile-hidden".clone(alloc);
    // Where those lines were read goes with them (New Elevated Window names
    // a profile whose line came from a file).
    dst._profile_places = try cloneProfilePlaces(src, alloc);
}

/// Check what needs every layer read: a `profile-name`,
/// `profile-working-directory` or `profile-env` entry whose id no
/// `profile-command` line names, live or removed, since a field may come
/// before the line that defines its profile, or from another file. Each is a
/// config problem at the last line that wrote it, and is dropped, so nothing
/// downstream sees a field of a profile the user was told does not exist.
/// Every other profile check runs while the line is parsed
/// (`profile_map.check`).
fn finalizeProfiles(config: *Config) Allocator.Error!void {
    try finalizeProfileField(config, ProfileMap.Name, &config.@"profile-name", "profile-name");
    try finalizeProfileField(config, ProfileMap.Text, &config.@"profile-working-directory", "profile-working-directory");
    try finalizeProfileField(config, ProfileMap.Env, &config.@"profile-env", "profile-env");
    try finalizeProfileReferences(config, "profile-order");
    try finalizeProfileReferences(config, "profile-hidden");
}

/// Report each `profile-order` or `profile-hidden` value that can name no
/// profile anywhere (`windows_shell.referenceCanName`): a typo, an id no
/// `profile-command` line names, a comment after the value. One naming a
/// shell this machine lacks (`wsl:docker-desktop`, an `ssh:` host) is not
/// reported, so a shared config loads quietly everywhere. A reference is not
/// a secret, so the message quotes it, as `default-profile`'s does.
fn finalizeProfileReferences(config: *Config, comptime key: [:0]const u8) Allocator.Error!void {
    const alloc = config._arena.?.allocator();
    for (@field(config, key).list.items) |reference| {
        if (windows_shell.referenceCanName(reference, &config.@"profile-command")) continue;
        try appendFinalizeProblem(config, .{
            .key = key,
            .message = try std.fmt.allocPrintSentinel(alloc, "\"{s}\" names no profile: use a profile-command id, " ++
                "a key such as pwsh.exe, wsl:<distribution>, ssh:<alias> or vs:newest:cmd, or a name such as pwsh, git, cmd or wsl{s}", .{
                reference,
                if (hasInlineComment(reference)) " (comments go on a line of their own)" else "",
            }, 0),
            .location = try profilePlace(config, key, reference).clone(alloc),
        });
    }
}

/// Whether `value` holds whitespace followed by `#`: a comment written after
/// a value, which the config format reads as part of it.
fn hasInlineComment(value: []const u8) bool {
    var index: usize = 1;
    while (index < value.len) : (index += 1) {
        if (value[index] == '#' and std.ascii.isWhitespace(value[index - 1])) return true;
    }
    return false;
}

fn finalizeProfileField(
    config: *Config,
    comptime Map: type,
    map: *Map,
    comptime key: [:0]const u8,
) Allocator.Error!void {
    const alloc = config._arena.?.allocator();
    var index: usize = 0;
    while (index < map.entries.items.len) {
        const id = map.entries.items[index].id;
        if (config.@"profile-command".contains(id)) {
            index += 1;
            continue;
        }
        try config._diagnostics.append(alloc, .{
            .key = key,
            .message = try std.fmt.allocPrintSentinel(
                alloc,
                "\"{s}\" has no profile-command line, so there is no such profile",
                .{id},
                0,
            ),
            .location = try profilePlace(config, key, id).clone(alloc),
        });
        _ = map.entries.orderedRemove(index);
    }
}

/// Where a line that `finalize` may report was read: the last line that
/// wrote a (key, id) of a `profile-*` key, or a reference value.
pub const ProfilePlace = struct {
    key: []const u8,
    id: []const u8,
    location: cli.Location,
};

/// A copy of `_profile_places` in `alloc` (another config's arena): the ids
/// and locations are copied, the keys are static.
pub fn cloneProfilePlaces(config: *const Config, alloc: Allocator) Allocator.Error!std.ArrayListUnmanaged(ProfilePlace) {
    var out: std.ArrayListUnmanaged(ProfilePlace) = .empty;
    try out.ensureTotalCapacity(alloc, config._profile_places.items.len);
    for (config._profile_places.items) |place| {
        out.appendAssumeCapacity(.{
            .key = place.key,
            .id = try alloc.dupe(u8, place.id),
            .location = try place.location.clone(alloc),
        });
    }
    return out;
}

/// The place of the last line that wrote `id` for `key`, or none (a value
/// set by code, not by a line).
fn profilePlace(config: *const Config, key: []const u8, id: []const u8) cli.Location {
    var index = config._profile_places.items.len;
    while (index > 0) {
        index -= 1;
        const place = config._profile_places.items[index];
        if (std.mem.eql(u8, place.key, key) and std.ascii.eqlIgnoreCase(place.id, id)) return place.location;
    }
    return .none;
}

/// Whether any argument on noctty's command line wrote `id` for `key`
/// (`--profile-env=<id>: ...`), or cleared every id (`--profile-env=`), which
/// a process that reads only the config files would not see.
fn profileWrittenOnCommandLine(config: *const Config, key: []const u8, id: []const u8) bool {
    for (config._profile_places.items) |place| {
        if (place.location != .cli or !std.mem.eql(u8, place.key, key)) continue;
        if (place.id.len == 0 or std.ascii.eqlIgnoreCase(place.id, id)) return true;
    }
    return false;
}

/// Whether noctty's command line has an `--env=` argument. A process that
/// reads only the config files (an elevated window) would not get it, and a
/// user profile's `%NAME%` reads `env` entries first.
fn commandLineSetsEnv(config: *const Config) bool {
    for (config._replay_steps.items) |step| switch (step) {
        .arg => |arg| if (arg.location == .cli and std.mem.startsWith(u8, arg.value, "--env=")) return true,
        else => {},
    };
    return false;
}

/// Record where `arg` (`--<key>=<value>`) was read when it writes an id of a
/// `profile-*` key, or a value of `default-profile`, `profile-order` or
/// `profile-hidden` (recorded under the value itself). A line the parser
/// will refuse writes nothing and is not recorded.
fn recordProfilePlace(config: *Config, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!void {
    if (!std.mem.startsWith(u8, arg, "--profile-") and !std.mem.startsWith(u8, arg, "--default-profile=")) return;
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return;
    const key = arg[2..eq];
    const value = std.mem.trim(u8, arg[eq + 1 ..], &std.ascii.whitespace);
    if (value.len == 0) {
        // `profile-env =` clears every profile's variables: recorded under
        // the empty id, which no profile has, so `profileWrittenOnCommandLine`
        // sees a command-line reset (New Elevated Window would otherwise
        // name a file's profile, whose variables the elevated process reads
        // back from the files).
        if (std.mem.eql(u8, key, "profile-env")) try config._profile_places.append(alloc, .{
            .key = "profile-env",
            .id = "",
            .location = try cli.Location.fromIter(iter, alloc),
        });
        return;
    }
    inline for (.{ "default-profile", "profile-order", "profile-hidden" }) |reference_key| {
        if (std.mem.eql(u8, key, reference_key)) {
            try config._profile_places.append(alloc, .{
                .key = reference_key,
                .id = try alloc.dupe(u8, value),
                .location = try cli.Location.fromIter(iter, alloc),
            });
            return;
        }
    }
    inline for (.{
        .{ "profile-command", ProfileMap.Kind.command },
        .{ "profile-name", ProfileMap.Kind.name },
        .{ "profile-working-directory", ProfileMap.Kind.text },
        .{ "profile-env", ProfileMap.Kind.env },
    }) |field| {
        if (std.mem.eql(u8, key, field[0])) {
            const parsed = ProfileMap.check(field[1], value) catch return;
            try config._profile_places.append(alloc, .{
                .key = field[0],
                .id = try alloc.dupe(u8, parsed.id),
                .location = try cli.Location.fromIter(iter, alloc),
            });
            return;
        }
    }
}

/// `--command=` and `--initial-command=` from the command line once every
/// layer has been read, over a `command` or `initial-command` line in an
/// included file (read after the command line). What was kept is the last
/// value the field parse took (`takenCliValue`), so a later one it refused
/// does not replace it.
fn finalizeCliLaunch(config: *Config) Allocator.Error!void {
    if (config._command_cli) |value| {
        if (try applyCliValue(config, "command", value)) {
            config._command_defaulted = false;
            config._command_from_file = false;
        }
    }
    if (config._initial_command_cli) |value| _ = try applyCliValue(config, "initial-command", value);
    finalizeECommand(config);
}

/// Apply `-e`'s command (`_e_command`) again, over the files read after the
/// command line. A replay with `-e` last (a theme's, a new conditional
/// state's) has already given these values, and this gives them again.
fn finalizeECommand(config: *Config) void {
    const command = config._e_command orelse return;
    config.applyECommand(command);
}

/// The value of `arg` when it is `--<key>=<value>` and the field parse takes
/// it. It is parsed here, into the field, by the same `applyCliValue` the
/// parse that follows uses (and `finalizeCliLaunch` repeats), so the answer is
/// that parse's, with no copy of its rules (a blank value, `direct:`).
fn takenCliValue(config: *Config, comptime key: []const u8, arg: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "--" ++ key ++ "=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    const value = arg[prefix.len..];
    return if (try applyCliValue(config, key, value)) value else null;
}

fn applyCliValue(config: *Config, comptime key: []const u8, value: []const u8) Allocator.Error!bool {
    cli.args.parseIntoField(Config, config._arena.?.allocator(), config, key, value) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    return true;
}

/// Add a problem `finalize` found, unless the config already has it:
/// `finalize` can run again on a finalized config (a new window's clone of
/// the app config is finalized again with its forwarded arguments).
fn appendFinalizeProblem(config: *Config, diag: cli.Diagnostic) Allocator.Error!void {
    for (config._diagnostics.items()) |have| {
        if (sameDiagnostic(have, diag)) return;
    }
    try config._diagnostics.append(config._arena.?.allocator(), diag);
}

/// The same problem: the same key, message and place.
fn sameDiagnostic(a: cli.Diagnostic, b: cli.Diagnostic) bool {
    if (!std.mem.eql(u8, a.key, b.key) or !std.mem.eql(u8, a.message, b.message)) return false;
    return switch (a.location) {
        .none => b.location == .none,
        .cli => |index| b.location == .cli and b.location.cli == index,
        .file => |place| b.location == .file and b.location.file.line == place.line and
            std.mem.eql(u8, b.location.file.path, place.path),
    };
}

/// `default-profile` once every layer has been read: a command-line value
/// wins over the files (included ones are read after the command line), and
/// one that a `command` from a config file overrides is a config problem.
/// Safe mode starts with a `command` noctty chose, so this stays quiet there.
fn finalizeDefaultProfileSetting(config: *Config) Allocator.Error!void {
    if (config._default_profile_cli) |value| {
        config.@"default-profile" = if (value.len == 0) null else value;
    }
    if (config.@"default-profile" == null or config._default_profile != null) return;
    if (config.command == null or config._command_defaulted or !config._command_from_file) return;
    const alloc = config._arena.?.allocator();
    try appendFinalizeProblem(config, .{
        .key = "default-profile",
        .message = "is not used, because a config file sets command; remove the command line to start the profile",
        .location = try profilePlace(config, "default-profile", config.@"default-profile".?).clone(alloc),
    });
}

/// Give a config with no `command` the profile `default-profile` names
/// (`windows_shell.resolveProfileReference`, through `host`): its command,
/// marked automatic as the default it replaces, and the profile itself in
/// `_default_profile`. A value that names nothing that can start is a config
/// problem, and `command` stays unset for the automatic default.
fn applyDefaultProfile(config: *Config, host: anytype) !void {
    if (config.command != null) return;
    const reference = config.@"default-profile" orelse return;
    const alloc = config._arena.?.allocator();
    var user = try windows_shell.UserProfiles.init(alloc, config);
    defer user.deinit();
    // A failed lookup (not memory) is a profile that cannot start, as for
    // the automatic default, which also looks the shells up here.
    const resolved = windows_shell.resolveProfileReference(alloc, reference, user.definitions, host) catch |err| found: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.VisualStudioUnavailable) {
            // The value may be right: reported apart from one that names
            // nothing, and the next load (a reload) asks again.
            config._default_profile_failure = .unavailable;
            try appendFinalizeProblem(config, .{
                .key = "default-profile",
                .message = try std.fmt.allocPrintSentinel(
                    alloc,
                    "\"{s}\" could not be looked up: Visual Studio's Setup Configuration did not answer in full, so the automatic default is used until the config is reloaded",
                    .{reference},
                    0,
                ),
                .location = try profilePlace(config, "default-profile", reference).clone(alloc),
            });
            return;
        }
        log.warn("default-profile lookup failed err={}", .{err});
        break :found null;
    };
    const profile = resolved orelse {
        config._default_profile_failure = .not_found;
        try appendFinalizeProblem(config, .{
            .key = "default-profile",
            .message = try std.fmt.allocPrintSentinel(
                alloc,
                "\"{s}\" names no profile that can start here (a profile-command id, a key such as pwsh.exe, wsl:<distribution>, ssh:<alias> or vs:newest:cmd, or a name such as pwsh, git, cmd or wsl), so the automatic default is used",
                .{reference},
                0,
            ),
            .location = try profilePlace(config, "default-profile", reference).clone(alloc),
        });
        return;
    };
    log.info("default shell src=default-profile key={s}", .{profile.key});
    config.command = profile.command;
    config._command_defaulted = true;
    config._default_profile = profile;
}

pub const DefaultProfileFailure = enum {
    /// Not looked up, or found.
    none,
    /// It names nothing that can start here.
    not_found,
    /// Visual Studio's Setup Configuration did not answer in full, so a
    /// `vs:` value may still be right; the next load asks again.
    unavailable,
};

/// Test adapters: a machine with fixed answers, what the app knows of a new
/// pane, and a load as `Config.load` makes it.
pub const fixtures = struct {
    /// Fixed lookups for `default-profile` in tests: no PATH search, and
    /// one Visual Studio 18 instead of the machine's.
    pub const Machine = struct {
        visual_studio: windows_shell.VisualStudioProfiles = .newest,
        /// False: Setup Configuration fails, and lists nothing.
        visual_studio_answers: bool = true,
        /// True: OpenSSH is installed, so an `ssh:` reference resolves.
        ssh: bool = false,

        pub fn visualStudio(self: Machine, alloc: Allocator, complete: *bool) ![]windows_shell.Profile {
            const vs = windows_shell.visual_studio;
            const Fixed = struct {
                answers: bool,
                pub fn query(self_: @This(), a: Allocator) !vs.Discovery {
                    if (!self_.answers) return .{ .complete = false };
                    const list = try a.alloc(vs.Instance, 1);
                    list[0] = .{
                        .id = "6bb7cfd9",
                        .path = "C:\\Program Files\\Microsoft Visual Studio\\18\\Community",
                        .version_text = "18.10.12201.205",
                        .version = vs.version(18, 10),
                        .install_date = 1,
                        .suffix = "18",
                    };
                    return .{ .instances = list };
                }
                pub fn installDirectory(_: @This(), _: []const u8) bool {
                    return true;
                }
                pub fn file(_: @This(), _: []const u8) bool {
                    return true;
                }
                pub fn lookup(_: @This(), a: Allocator, exe: []const u8) !?[]u8 {
                    return try a.dupe(u8, exe);
                }
            };
            const fixed: Fixed = .{ .answers = self.visual_studio_answers };
            return try windows_shell.appendVisualStudioProfiles(alloc, try alloc.alloc(windows_shell.Profile, 0), self.visual_studio, .x64, fixed, fixed, complete);
        }

        pub fn lookup(_: Machine, alloc: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try alloc.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "wsl.exe")) return try alloc.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }

        pub fn gitBash(_: Machine, _: Allocator) !?[]u8 {
            return null;
        }

        pub fn sshExecutable(self: Machine, alloc: Allocator) !?[]u8 {
            if (!self.ssh) return null;
            return try alloc.dupe(u8, "C:\\Windows\\System32\\OpenSSH\\ssh.exe");
        }

        pub fn get(_: Machine, _: Allocator, _: []const u8) Allocator.Error!?[]u8 {
            return null;
        }
    };

    /// What the app knows of a new pane (`prepare`'s `context`), and how
    /// often `prepare` asked for a list.
    pub const Context = struct {
        first: bool = false,
        /// The profiles the pane's window lists; null for no window.
        window: ?[]const windows_shell.Profile = null,
        /// What a discovery lists.
        discovered: []const windows_shell.Profile = &.{},
        listed_count: usize = 0,
        discover_count: usize = 0,

        pub const automatic_argv = [_][:0]const u8{"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"};

        pub fn windowed(self: *const Context) bool {
            return self.window != null;
        }

        pub fn listed(self: *Context, key: []const u8) !?*const windows_shell.Profile {
            self.listed_count += 1;
            for (self.window orelse return null) |*profile| {
                if (windows_shell.profileKeyEquals(profile.*, key)) return profile;
            }
            return null;
        }

        pub fn discover(self: *Context, alloc: Allocator) ![]windows_shell.Profile {
            self.discover_count += 1;
            return try windows_shell.cloneProfiles(alloc, self.discovered);
        }

        pub fn automatic(_: *const Context, _: Allocator) !Command {
            return .{ .direct = &automatic_argv };
        }
    };

    pub const Load = struct {
        file: []const u8 = "",
        argv: []const []const u8 = &.{},
        /// A file `config-file` names, read after the command line.
        include: ?[]const u8 = null,
    };

    /// A load as `Config.load` makes it: the config file, the command line,
    /// then an included file (read after the command line), then `finalize`,
    /// which looks for the default profile.
    pub fn load(alloc: Allocator, how: Load) !Config {
        var cfg = try Config.default(alloc);
        errdefer cfg.deinit();
        var reader: std.Io.Reader = .fixed(how.file);
        try cfg.loadReader(alloc, &reader, "C:\\noctty-test\\config.ghostty");
        var it: cli.args.ArgsIterator(cli.args.SliceIterator) = .{ .iterator = .{ .slice = how.argv } };
        try cfg.loadIter(alloc, &it);
        if (how.include) |include| {
            var included: std.Io.Reader = .fixed(include);
            try cfg.loadReader(alloc, &included, "C:\\noctty-test\\profiles.ghostty");
        }
        try cfg.finalize();
        return cfg;
    }
};

/// How many of `cfg`'s problems are about `key`.
fn testProblems(cfg: *const Config, key: []const u8) usize {
    var count: usize = 0;
    for (cfg._diagnostics.items()) |diag| {
        if (std.mem.eql(u8, diag.key, key)) count += 1;
    }
    return count;
}

/// The config as `+show-config` writes it (only the changed keys).
fn testFormatChanged(alloc: Allocator, cfg: *const Config) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();
    const FileFormatter = @import("formatter_file.zig").FileFormatter;
    try buf.writer.print("{f}", .{FileFormatter{ .alloc = alloc, .config = cfg, .changed = true }});
    return try buf.toOwnedSlice();
}

test "default-profile gives way to a command from any layer, and says so only for a file's" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile =
        \\profile-command = py: cmd.exe /k "C:\Python 3\init.cmd"
        \\profile-env = py: MODE=profile
        \\
    ;

    // Alone, it is the command, still marked automatic, and the profile.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = PY\n" });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expect(cfg._command_defaulted);
        try testing.expectEqualStrings("cmd.exe", cfg.command.?.direct[0]);
        try testing.expectEqualStrings("C:\\Python 3\\init.cmd", cfg.command.?.direct[2]);
        try testing.expectEqualStrings("user:py", cfg._default_profile.?.key);
        try testing.expectEqualStrings("profile", cfg._default_profile.?.user.?.env[0].value);
        // A copy keeps it (a soft reload installs a copy).
        var copy = try cfg.clone(alloc);
        defer copy.deinit();
        try testing.expectEqualStrings("user:py", copy._default_profile.?.key);
        try testing.expect(copy._default_profile.?.key.ptr != cfg._default_profile.?.key.ptr);
    }

    // A config file's command wins, and the unused setting is a problem.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\ncommand = vim.exe\n" });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
        try testing.expect(!cfg._command_defaulted);
    }

    // The command line's command wins quietly.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .argv = &.{"--command=vim.exe"} });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 0), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
        try testing.expectEqualStrings("vim.exe", cfg.command.?.shell);
    }

    // `--command=` undoes a file's command, so the profile runs (a jump-list
    // link does this).
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "command = vim.exe\ndefault-profile = py\n", .argv = &.{"--command="} });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqualStrings("user:py", cfg._default_profile.?.key);
    }

    // An included file is read after the command line, but the command
    // line's command and initial command still win over its lines: a
    // jump-list link's resets hold, so the profile runs.
    {
        var cfg = try fixtures.load(alloc, .{
            .file = profile ++ "default-profile = py\n",
            .argv = &.{ "--command=", "--initial-command=" },
            .include = "command = vim.exe\ninitial-command = other.exe\n",
        });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqualStrings("user:py", cfg._default_profile.?.key);
        try testing.expect(cfg._command_defaulted);
        try testing.expect(cfg.@"initial-command" == null);
        // And after a rebuild for a conditional state (a theme).
        cfg._conditional_set.insert(.theme);
        var replayed = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer replayed.deinit();
        try testing.expectEqualStrings("user:py", replayed._default_profile.?.key);
        try testing.expect(replayed.@"initial-command" == null);
        // A copy keeps them.
        var copy = try cfg.clone(alloc);
        defer copy.deinit();
        try testing.expectEqualStrings("", copy._command_cli.?);
        try testing.expectEqualStrings("", copy._initial_command_cli.?);
    }
    // A command on the command line wins over an included one too, quietly.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .argv = &.{"--command=vim.exe"}, .include = "command = other.exe\n" });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqualStrings("vim.exe", cfg.command.?.shell);
        try testing.expect(cfg._default_profile == null);
    }
    // With nothing on the command line, an included file's command is a
    // file's command, which leaves the profile unused.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .include = "command = vim.exe\n" });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
    }
    // `-e` after `--initial-command=` still runs.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile, .argv = &.{ "--initial-command=", "-e", "vim.exe" } });
        defer cfg.deinit();
        try testing.expectEqualStrings("vim.exe", cfg.@"initial-command".?.direct[0]);
    }

    // `default-profile` on the command line wins over the files, the
    // included one too (the jump list names a profile so).
    {
        var cfg = try fixtures.load(alloc, .{
            .file = profile ++ "default-profile = pwsh\n",
            .argv = &.{ "--command=", "--initial-command=", "--default-profile=user:py" },
            .include = "default-profile = wsl:Ubuntu\n",
        });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqualStrings("user:py", cfg._default_profile.?.key);
        try testing.expect(cfg.@"initial-command" == null);
        // What the files give is kept apart, for Settings: the last file
        // read (the include), not the command line's value.
        try testing.expectEqualStrings("wsl:Ubuntu", filesDefaultProfile(&cfg).?);
        // And it survives a rebuild for a conditional state (a theme).
        cfg._conditional_set.insert(.theme);
        var replayed = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer replayed.deinit();
        try testing.expectEqualStrings("user:py", replayed.@"default-profile".?);
        try testing.expectEqualStrings("wsl:Ubuntu", filesDefaultProfile(&replayed).?);
        var copy = try cfg.clone(alloc);
        defer copy.deinit();
        try testing.expectEqualStrings("wsl:Ubuntu", filesDefaultProfile(&copy).?);
    }
    {
        // An empty one on the command line undoes the files', which still
        // give theirs; an empty file line gives none.
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .argv = &.{"--default-profile="} });
        defer cfg.deinit();
        try testing.expect(cfg.@"default-profile" == null);
        try testing.expect(cfg._default_profile == null);
        try testing.expectEqualStrings("py", filesDefaultProfile(&cfg).?);
        var cleared = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .argv = &.{"--default-profile=pwsh"}, .include = "default-profile =\n" });
        defer cleared.deinit();
        try testing.expect(filesDefaultProfile(&cleared) == null);
        // With nothing on the command line it is the setting itself.
        var plain = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n" });
        defer plain.deinit();
        try testing.expectEqualStrings("py", filesDefaultProfile(&plain).?);
    }

    // A name that starts nothing is a problem, and the automatic default runs.
    for ([_][]const u8{ "nosuch", "git", "distro" }) |name| {
        const text = try std.fmt.allocPrint(alloc, "default-profile = {s}\n", .{name});
        defer alloc.free(text);
        var cfg = try fixtures.load(alloc, .{ .file = text });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg.command == null and cfg._default_profile == null);
    }

    // A refused profile is no profile.
    {
        var cfg = try fixtures.load(alloc, .{ .file = "profile-command = bad: direct:cmd.exe\ndefault-profile = bad\n" });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
    }

    // A detected key resolves without listing anything.
    {
        var cfg = try fixtures.load(alloc, .{ .file = "default-profile = wsl:Ubuntu\n" });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqualStrings("-d", cfg.command.?.direct[1]);
        try testing.expectEqualStrings("wsl:Ubuntu", cfg._default_profile.?.key);
    }
}

test "a refused --command= does not replace an accepted one over an include" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile = "profile-command = py: cmd.exe /k init.cmd\n";

    // The last ACCEPTED `--command=` is what holds over an included file's
    // `command`; the refused one after it is reported and nothing more.
    for ([_][]const u8{ "direct:", "direct:   ", " " }) |refused| {
        const refused_arg = try std.fmt.allocPrint(alloc, "--command={s}", .{refused});
        defer alloc.free(refused_arg);
        var cfg = try fixtures.load(alloc, .{
            .file = profile ++ "default-profile = py\n",
            .argv = &.{ "--command=vim.exe", refused_arg },
            .include = "command = other.exe\n",
        });
        defer cfg.deinit();
        try testing.expectEqualStrings("vim.exe", cfg.command.?.shell);
        try testing.expectEqualStrings("vim.exe", cfg._command_cli.?);
        try testing.expect(!cfg._command_defaulted);
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "command"));
        // The command line's command is quiet toward `default-profile`.
        try testing.expectEqual(@as(usize, 0), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
        // A copy and a rebuild for a conditional state (a theme) keep it.
        var copy = try cfg.clone(alloc);
        defer copy.deinit();
        try testing.expectEqualStrings("vim.exe", copy._command_cli.?);
        cfg._conditional_set.insert(.theme);
        var replayed = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer replayed.deinit();
        try testing.expectEqualStrings("vim.exe", replayed.command.?.shell);
    }
}

test "a refused --initial-command= does not replace an accepted one over an include" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile = "profile-command = py: cmd.exe /k init.cmd\n";

    // The same for `--initial-command=`.
    for ([_][]const u8{ "direct:", " " }) |refused| {
        const refused_arg = try std.fmt.allocPrint(alloc, "--initial-command={s}", .{refused});
        defer alloc.free(refused_arg);
        var cfg = try fixtures.load(alloc, .{
            .file = profile,
            .argv = &.{ "--initial-command=vim.exe", refused_arg },
            .include = "initial-command = other.exe\n",
        });
        defer cfg.deinit();
        try testing.expectEqualStrings("vim.exe", cfg.@"initial-command".?.shell);
        try testing.expectEqualStrings("vim.exe", cfg._initial_command_cli.?);
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "initial-command"));
    }
}

test "a refused command-line value before or after an accepted one: the accepted one holds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile = "profile-command = py: cmd.exe /k init.cmd\n";

    // A refused value that comes first leaves the later accepted one alone,
    // and an accepted one after a refused one still wins.
    {
        var cfg = try fixtures.load(alloc, .{
            .file = profile,
            .argv = &.{ "--command=direct:", "--command=vim.exe", "--initial-command=direct:", "--initial-command=vim.exe" },
            .include = "command = other.exe\ninitial-command = other.exe\n",
        });
        defer cfg.deinit();
        try testing.expectEqualStrings("vim.exe", cfg.command.?.shell);
        try testing.expectEqualStrings("vim.exe", cfg.@"initial-command".?.shell);
    }
}

test "a refused command-line value after a reset leaves the reset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile = "profile-command = py: cmd.exe /k init.cmd\n";

    // A refused value after an accepted reset leaves the reset: the jump
    // list's `--command=` still starts the profile.
    {
        var cfg = try fixtures.load(alloc, .{
            .file = profile ++ "default-profile = py\n",
            .argv = &.{ "--command=", "--command=direct:", "--initial-command=", "--initial-command=direct:" },
            .include = "command = other.exe\ninitial-command = other.exe\n",
        });
        defer cfg.deinit();
        try testing.expectEqualStrings("", cfg._command_cli.?);
        try testing.expectEqualStrings("user:py", cfg._default_profile.?.key);
        try testing.expect(cfg._command_defaulted);
        try testing.expect(cfg.@"initial-command" == null);
    }
}

test "a refused --command= does not claim a config file's command as the command line's" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile = "profile-command = py: cmd.exe /k init.cmd\n";

    // With nothing accepted on the command line, a config file's `command`
    // is still the file's, so `default-profile` is reported as unused. A
    // refused `--command=` must not mark the command as the command line's.
    {
        var cfg = try fixtures.load(alloc, .{
            .file = profile ++ "command = vim.exe\ndefault-profile = py\n",
            .argv = &.{"--command=direct:"},
        });
        defer cfg.deinit();
        try testing.expect(cfg._command_cli == null);
        try testing.expectEqualStrings("vim.exe", cfg.command.?.shell);
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "command"));
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
    }
    {
        var cfg = try fixtures.load(alloc, .{
            .file = profile ++ "default-profile = py\n",
            .argv = &.{"--command=direct:"},
            .include = "command = other.exe\n",
        });
        defer cfg.deinit();
        try testing.expect(cfg._command_cli == null);
        try testing.expectEqualStrings("other.exe", cfg.command.?.shell);
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
    }
}

/// `command` when it is a shell command, or a test failure (not a panic) for
/// none or a direct one.
fn testShellCommand(command: ?Command) ![:0]const u8 {
    const value = command orelse return error.TestUnexpectedResult;
    if (value != .shell) return error.TestUnexpectedResult;
    return value.shell;
}

/// `command`'s words when it is a direct command, or a test failure (not a
/// panic) for none or a shell one.
fn testDirectCommand(command: ?Command) ![]const [:0]const u8 {
    const value = command orelse return error.TestUnexpectedResult;
    if (value != .direct) return error.TestUnexpectedResult;
    return value.direct;
}

test "-e wins over a file read after the command line, as a replay with -e last does" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // `fixtures.load` reads the include after the command line, as
    // a file `config-file` names is read, and sets no theme, so nothing
    // replays the log.
    const Case = struct { include: []const u8, shell_integration: Config.ShellIntegration };
    for ([_]Case{
        .{
            .include = "initial-command = pwsh.exe\nquit-after-last-window-closed = false\n" ++
                "quit-after-last-window-closed-delay = 5s\nshell-integration = fish\n",
            .shell_integration = .detect,
        },
        // `-e` leaves `none` as it is, as it does when it comes last.
        .{ .include = "shell-integration = none\n", .shell_integration = .none },
    }) |case| {
        var cfg = try fixtures.load(alloc, .{ .argv = &.{ "-e", "cmd.exe" }, .include = case.include });
        defer cfg.deinit();
        try testing.expectEqualStrings("cmd.exe", (try testDirectCommand(cfg.@"initial-command"))[0]);
        try testing.expect(cfg.@"quit-after-last-window-closed");
        try testing.expect(cfg.@"quit-after-last-window-closed-delay" == null);
        try testing.expectEqual(case.shell_integration, cfg.@"shell-integration");
    }
    // An `-e` refused for want of a command changes nothing: the file's
    // values stand.
    {
        var cfg = try fixtures.load(alloc, .{ .argv = &.{"-e"}, .include = "initial-command = pwsh.exe\nquit-after-last-window-closed = false\n" });
        defer cfg.deinit();
        try testing.expect(cfg._e_command == null);
        try testing.expectEqualStrings("pwsh.exe", try testShellCommand(cfg.@"initial-command"));
        try testing.expect(!cfg.@"quit-after-last-window-closed");
    }
}

test "-e still wins in a copy of the config, finalized again" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try fixtures.load(alloc, .{ .argv = &.{ "-e", "cmd.exe" } });
    defer cfg.deinit();
    // A deep copy keeps the command `-e` was given, and finalized again over
    // a later value, as a reload's would be, `-e` wins again.
    var copy = try cfg.clone(alloc);
    defer copy.deinit();
    try testing.expectEqualStrings("cmd.exe", (copy._e_command orelse return error.TestUnexpectedResult)[0]);
    copy.@"quit-after-last-window-closed" = false;
    copy.@"initial-command" = null;
    try copy.finalize();
    try testing.expect(copy.@"quit-after-last-window-closed");
    try testing.expectEqualStrings("cmd.exe", (try testDirectCommand(copy.@"initial-command"))[0]);
    // A shallow copy, as a new window's (`apprt.surface.newConfig`), holds
    // `-e`'s values and its command.
    var shallow = cfg.shallowClone(alloc);
    defer shallow.deinit();
    try testing.expect(shallow.@"quit-after-last-window-closed");
    try testing.expectEqualStrings("cmd.exe", (try testDirectCommand(shallow.@"initial-command"))[0]);
    try testing.expectEqualStrings("cmd.exe", (shallow._e_command orelse return error.TestUnexpectedResult)[0]);
}

test "a refused -e leaves an accepted --initial-command= before it in force" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try fixtures.load(alloc, .{ .argv = &.{ "--initial-command=cmd.exe", "-e" }, .include = "initial-command = pwsh.exe\n" });
    defer cfg.deinit();
    try testing.expectEqualStrings("cmd.exe", cfg._initial_command_cli orelse return error.TestUnexpectedResult);
    try testing.expectEqualStrings("cmd.exe", try testShellCommand(cfg.@"initial-command"));
}

test "a refused --initial-command= leaves -e its place" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile = "profile-command = py: cmd.exe /k init.cmd\n";

    // `-e` still comes after, and wins over, a kept `--initial-command=`.
    {
        var cfg = try fixtures.load(alloc, .{
            .file = profile,
            .argv = &.{ "--initial-command=vim.exe", "--initial-command=direct:", "-e", "foo.exe" },
        });
        defer cfg.deinit();
        try testing.expect(cfg._initial_command_cli == null);
        try testing.expectEqualStrings("foo.exe", cfg.@"initial-command".?.direct[0]);
    }
}

test "profile-order and profile-hidden report a value that can name no profile, at its line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const text =
        \\profile-command = py: cmd.exe
        \\profile-command = gone: x.exe
        \\profile-command = gone:
        \\profile-order = pyy
        \\profile-order = user:nope
        \\profile-hidden = wsl:docker-desktop   # unused
        \\profile-hidden = Ubuntu
        \\profile-order = py
        \\profile-order = user:PY
        \\profile-order = gone
        \\profile-hidden = wsl:docker-desktop
        \\profile-hidden = ssh:build-host
        \\profile-hidden = SSH:build-host
        \\profile-hidden = git
        \\profile-hidden = WSL
        \\profile-hidden = distro
        \\profile-hidden = cmd.exe
        \\
    ;
    var cfg = try fixtures.load(alloc, .{ .file = text });
    defer cfg.deinit();
    const Want = struct { key: []const u8, line: usize, message: []const u8 };
    const want = [_]Want{
        .{ .key = "profile-order", .line = 4, .message = "\"pyy\" names no profile: use a profile-command id, a key such as pwsh.exe, wsl:<distribution>, ssh:<alias> or vs:newest:cmd, or a name such as pwsh, git, cmd or wsl" },
        .{ .key = "profile-order", .line = 5, .message = "\"user:nope\" names no profile" },
        .{ .key = "profile-hidden", .line = 6, .message = "\"wsl:docker-desktop   # unused\" names no profile" },
        .{ .key = "profile-hidden", .line = 7, .message = "\"Ubuntu\" names no profile" },
    };
    const found = cfg._diagnostics.items();
    if (found.len != want.len) for (found) |diag| std.debug.print("{s}: {s}\n", .{ diag.key, diag.message });
    try testing.expectEqual(want.len, found.len);
    for (want, found) |w, got| {
        try testing.expectEqualStrings(w.key, got.key);
        try testing.expect(std.mem.startsWith(u8, got.message, w.message));
        try testing.expectEqualStrings("C:\\noctty-test\\config.ghostty", got.location.file.path);
        try testing.expectEqual(w.line, got.location.file.line);
    }
    // Only the value with a comment after it gets the hint.
    try testing.expect(std.mem.endsWith(u8, found[2].message, " (comments go on a line of their own)"));
    try testing.expect(!std.mem.endsWith(u8, found[3].message, ")"));
}

test "default-profile problems carry the line that set it" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try fixtures.load(alloc, .{ .file = "font-size = 12\ndefault-profile = nosuch\n" });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), cfg._diagnostics.items().len);
        const diag = cfg._diagnostics.items()[0];
        try testing.expectEqualStrings("default-profile", diag.key);
        try testing.expectEqual(@as(usize, 2), diag.location.file.line);
        // Looked up and not found, which Settings shows; a clone (the
        // app's config is one) keeps that.
        try testing.expectEqual(DefaultProfileFailure.not_found, cfg._default_profile_failure);
        var copy = try cfg.clone(alloc);
        defer copy.deinit();
        try testing.expectEqual(DefaultProfileFailure.not_found, copy._default_profile_failure);
    }
    {
        var cfg = try fixtures.load(alloc, .{ .file = "profile-command = py: cmd.exe\ndefault-profile = py\ncommand = vim.exe\n" });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), cfg._diagnostics.items().len);
        // Not looked up at all: the command won.
        try testing.expectEqual(DefaultProfileFailure.none, cfg._default_profile_failure);
        const diag = cfg._diagnostics.items()[0];
        try testing.expect(std.mem.startsWith(u8, diag.message, "is not used, because a config file sets command"));
        try testing.expectEqual(@as(usize, 2), diag.location.file.line);
    }
    // A command-line value that wins over the files is named at its argument.
    {
        var cfg = try fixtures.load(alloc, .{ .file = "default-profile = pwsh\n", .argv = &.{"--default-profile=nosuch"} });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), cfg._diagnostics.items().len);
        try testing.expect(cfg._diagnostics.items()[0].location == .cli);
    }
}

test "visual-studio-profiles loads, and default-profile can name a Visual Studio shell" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        var cfg = try fixtures.load(alloc, .{ .file = "default-profile = VS:6BB7CFD9:CMD\n" });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqual(Config.VisualStudioProfiles.newest, cfg.@"visual-studio-profiles");
        try testing.expectEqualStrings("vs:6bb7cfd9:cmd", cfg._default_profile.?.key);
        try testing.expectEqualStrings("cmd.exe", cfg.command.?.direct[0]);
        try testing.expectEqualStrings("/k", cfg.command.?.direct[1]);
        try testing.expect(cfg._command_defaulted);
    }
    // `vs:newest:cmd` resolves to the concrete key, which the pane stores, so
    // a restore names the instance it ran; a value that names nothing yet is
    // quiet in profile-hidden, reported in default-profile under `none`.
    {
        var cfg = try fixtures.load(alloc, .{ .file = "default-profile = vs:newest:cmd\nprofile-hidden = vs:newest:pwsh\nprofile-order = vs:deadbeef:cmd\n" });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqualStrings("vs:6bb7cfd9:cmd", cfg._default_profile.?.key);
    }
    {
        var cfg = try fixtures.load(alloc, .{ .file = "visual-studio-profiles = none\ndefault-profile = vs:newest:cmd\n" });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
    }
    // `none` asks nothing, so the key names nothing: a config problem.
    {
        var cfg = try fixtures.load(alloc, .{ .file = "visual-studio-profiles = none\ndefault-profile = vs:6bb7cfd9:cmd\n" });
        defer cfg.deinit();
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        try testing.expect(cfg._default_profile == null);
    }
    {
        var cfg = try fixtures.load(alloc, .{ .file = "visual-studio-profiles = all\n" });
        defer cfg.deinit();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqual(Config.VisualStudioProfiles.all, cfg.@"visual-studio-profiles");
        const formatted = try testFormatChanged(alloc, &cfg);
        defer alloc.free(formatted);
        try testing.expect(std.mem.indexOf(u8, formatted, "visual-studio-profiles = all") != null);
    }
    {
        var cfg = try fixtures.load(alloc, .{ .file = "visual-studio-profiles = latest\n" });
        defer cfg.deinit();
        try testing.expect(!cfg._diagnostics.empty());
        try testing.expectEqual(Config.VisualStudioProfiles.newest, cfg.@"visual-studio-profiles");
    }
    // Setup Configuration failed: the automatic default for now, and the
    // problem named as that, not as a key that names nothing, at the line
    // that set the value.
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var reader: std.Io.Reader = .fixed("font-size = 12\ndefault-profile = vs:6bb7cfd9:cmd\n");
        try cfg.loadReader(alloc, &reader, "C:\\noctty-test\\config.ghostty");
        try finalizeWith(&cfg, fixtures.Machine{ .visual_studio_answers = false });
        try testing.expect(cfg.command == null and cfg._default_profile == null);
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        // Not "names nothing": Settings keeps the value apart from every
        // listed instance, unmarked, and a clone (the app's config) keeps
        // that.
        try testing.expectEqual(DefaultProfileFailure.unavailable, cfg._default_profile_failure);
        var copy = try cfg.clone(alloc);
        defer copy.deinit();
        try testing.expectEqual(DefaultProfileFailure.unavailable, copy._default_profile_failure);
        // Asked again (a finalize run again), still one problem.
        try finalizeWith(&cfg, fixtures.Machine{ .visual_studio_answers = false });
        try testing.expectEqual(@as(usize, 1), testProblems(&cfg, "default-profile"));
        const diag = cfg._diagnostics.items()[0];
        try testing.expect(std.mem.indexOf(u8, diag.message, "did not answer") != null);
        try testing.expectEqualStrings("C:\\noctty-test\\config.ghostty", diag.location.file.path);
        try testing.expectEqual(@as(usize, 2), diag.location.file.line);
    }
}

test "safe mode starts its recovery command over default-profile" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    cfg.@"default-profile" = "pwsh";
    try useRecovery(&cfg);
    try cfg.finalize();
    try testing.expect(cfg._diagnostics.empty());
    try testing.expect(cfg._default_profile == null);
    try testing.expectEqualStrings("/D", cfg.command.?.direct[1]);
}

test "finalize run again adds no profile problem twice" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    for ([_][]const u8{
        "default-profile = nothing-here\nprofile-order = typo-id\nprofile-hidden = also-typo\n",
        "command = cmd.exe\ndefault-profile = pwsh\n",
    }, [_]usize{ 3, 1 }) |text, want| {
        var cfg = try fixtures.load(alloc, .{ .file = text });
        defer cfg.deinit();
        try testing.expectEqual(want, cfg._diagnostics.items().len);
        // As a new window's clone of the app config is finalized again.
        try cfg.finalize();
        try testing.expectEqual(want, cfg._diagnostics.items().len);
    }
}

test "finalize-time profile problems are there once, at their lines, after a theme replay" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    // Theme files that exist, so `finalize` swaps in a config rebuilt by
    // replay before the conditional replays below.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "background = #ffffff\n" });
    try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "background = #000000\n" });
    const light = try tmp.dir.realpathAlloc(alloc, "light");
    defer alloc.free(light);
    const dark_theme = try tmp.dir.realpathAlloc(alloc, "dark");
    defer alloc.free(dark_theme);
    const Want = struct { key: []const u8, line: usize, message: []const u8 };
    const cases = [_]struct { body: []const u8, want: []const Want }{
        .{
            .body = "default-profile = nosuch\nprofile-order = pyy\nprofile-hidden = Ubuntu\n",
            .want = &.{
                .{ .key = "profile-order", .line = 3, .message = "\"pyy\" names no profile" },
                .{ .key = "profile-hidden", .line = 4, .message = "\"Ubuntu\" names no profile" },
                .{ .key = "default-profile", .line = 2, .message = "\"nosuch\" names no profile that can start here" },
            },
        },
        .{
            .body = "profile-command = py: cmd.exe\ndefault-profile = py\ncommand = vim.exe\n",
            .want = &.{
                .{ .key = "default-profile", .line = 3, .message = "is not used, because a config file sets command" },
            },
        },
    };
    for (cases) |case| {
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\n{s}", .{ light, dark_theme, case.body });
        defer alloc.free(text);
        var cfg = try fixtures.load(alloc, .{ .file = text });
        defer cfg.deinit();
        var dark = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer dark.deinit();
        var light_again = (try dark.changeConditionalState(.{ .theme = .light })).?;
        defer light_again.deinit();
        // As a new window's clone of the replayed config is finalized again.
        try light_again.finalize();
        for ([_]*const Config{ &cfg, &dark, &light_again }) |config| {
            var found: usize = 0;
            for (config._diagnostics.list.items) |diag| {
                if (!std.mem.startsWith(u8, diag.key, "profile-") and !std.mem.eql(u8, diag.key, "default-profile")) continue;
                testing.expect(found < case.want.len) catch |err| {
                    std.debug.print("extra: {s}: {s}\n", .{ diag.key, diag.message });
                    return err;
                };
                const w = case.want[found];
                try testing.expectEqualStrings(w.key, diag.key);
                testing.expect(std.mem.startsWith(u8, diag.message, w.message)) catch |err| {
                    std.debug.print("{s}: {s}\n", .{ diag.key, diag.message });
                    return err;
                };
                try testing.expectEqualStrings("C:\\noctty-test\\config.ghostty", diag.location.file.path);
                try testing.expectEqual(w.line, diag.location.file.line);
                found += 1;
            }
            try testing.expectEqual(case.want.len, found);
        }
    }
}

test "profile keys: a field with no profile-command is reported at its last line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const text =
        \\profile-command = ok: ok.exe
        \\profile-name = ghost: Ghost
        \\profile-env = ghost: A=1
        \\profile-name = GHOST: Ghost again
        \\profile-working-directory = removed: home
        \\profile-command = removed:
        \\profile-name = ok: Fine
        \\
    ;
    var cfg = try fixtures.load(alloc, .{ .file = text });
    defer cfg.deinit();
    const Want = struct { key: []const u8, line: usize };
    const want = [_]Want{
        .{ .key = "profile-name", .line = 4 },
        .{ .key = "profile-env", .line = 3 },
    };
    const found = cfg._diagnostics.list.items;
    try testing.expectEqual(want.len, found.len);
    for (want, found) |w, got| {
        try testing.expectEqualStrings(w.key, got.key);
        try testing.expect(std.mem.startsWith(u8, got.message, "\"ghost\" has no profile-command line") or
            std.mem.startsWith(u8, got.message, "\"GHOST\" has no profile-command line"));
        try testing.expectEqualStrings("C:\\noctty-test\\config.ghostty", got.location.file.path);
        try testing.expectEqual(w.line, got.location.file.line);
    }
    const formatted = try testFormatChanged(alloc, &cfg);
    defer alloc.free(formatted);
    try testing.expect(std.mem.indexOf(u8, formatted, "ghost") == null);
    try testing.expect(std.mem.indexOf(u8, formatted, "profile-name = ok: Fine\n") != null);

    // A clone (an app config is installed as one) keeps the places, as its
    // own copies: the source may be freed first.
    var copy = try cfg.clone(alloc);
    defer copy.deinit();
    const place = profilePlace(&copy, "profile-name", "GHOST");
    try testing.expectEqual(@as(usize, 4), place.file.line);
    try testing.expect(place.file.path.ptr != profilePlace(&cfg, "profile-name", "ghost").file.path.ptr);
    try testing.expectEqual(@as(usize, 1), profilePlace(&copy, "profile-command", "ok").file.line);
}

test "elevated profile env is taken from the command line, over env, and kept on replay" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        alloc,
        "--elevated-profile-env=PATH=p=1 --env=Path=global --env=KEEP=1 --elevated-profile-env=nothing --elevated-profile-env=KEEP=",
    );
    defer iter.deinit();
    try cli.args.parse(Config, alloc, &cfg, &iter);
    // A value with no `=` is a problem; it is not an unknown field.
    try testing.expectEqual(@as(usize, 1), cfg._diagnostics.items().len);
    try testing.expectEqualStrings("elevated-profile-env", cfg._diagnostics.items()[0].key);
    try cfg.finalize();
    try testing.expectEqualStrings("p=1", cfg.env.map.get("PATH").?);
    try testing.expect(cfg.env.map.get("Path") == null);
    // An empty value removes the variable, as `env = KEY=` does.
    try testing.expect(cfg.env.map.get("KEEP") == null);

    // A config rebuilt by replay (a theme, `config-default-files`) takes it again.
    cfg._conditional_set.insert(.theme);
    var rebuilt = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer rebuilt.deinit();
    try testing.expectEqualStrings("p=1", rebuilt.env.map.get("PATH").?);
    try testing.expect(rebuilt.env.map.get("Path") == null);
}

test "Windows safe mode swaps only the automatic command for cmd.exe" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;

    // With no command, recovery gives `cmd.exe /D` (no profile, no AutoRun),
    // marked automatic, before `finalize` has anything to look up.
    var automatic = try Config.default(alloc);
    defer automatic.deinit();
    try useRecovery(&automatic);
    try testing.expect(nocttyCommand(&automatic) != null);
    try testing.expect(automatic.command.? == .direct);
    try testing.expect(std.ascii.eqlIgnoreCase(
        std.fs.path.basename(automatic.command.?.direct[0]),
        "cmd.exe",
    ));
    try testing.expectEqualStrings("/D", automatic.command.?.direct[1]);
    // The default lookup leaves a command that is already set alone.
    try useAutomatic(&automatic);
    try testing.expectEqualStrings("/D", automatic.command.?.direct[1]);

    // A command somebody set is not replaced.
    var explicit = try Config.default(alloc);
    defer explicit.deinit();
    explicit.command = .{ .shell = "pwsh.exe" };
    try useRecovery(&explicit);
    try testing.expectEqualStrings("pwsh.exe", explicit.command.?.shell);
}

test "what a load decided of default-profile: the profile, noctty's command and the outcome" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const profile = "profile-command = py: cmd.exe /k init.cmd\n";

    // Resolved: the profile, its command as noctty's, and the outcome of its
    // own value only.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n" });
        defer cfg.deinit();
        try testing.expectEqualStrings("user:py", (defaultProfile(&cfg) orelse return error.TestUnexpectedResult).key);
        try testing.expectEqualStrings("cmd.exe", (nocttyCommand(&cfg) orelse return error.TestUnexpectedResult).direct[0]);
        try testing.expect(outcome(&cfg, "py") == .resolved);
        try testing.expect(outcome(&cfg, "pwsh") == .untried);
        try testing.expect(outcome(&cfg, null) == .untried);
        try testing.expect(!commandLineNamesProfile(&cfg));
    }
    // Looked up and not found.
    {
        var cfg = try fixtures.load(alloc, .{ .file = "default-profile = nosuch\n" });
        defer cfg.deinit();
        try testing.expect(defaultProfile(&cfg) == null);
        try testing.expect(nocttyCommand(&cfg) == null);
        try testing.expect(outcome(&cfg, "nosuch") == .not_found);
    }
    // A config file's command won: not looked up, and not noctty's.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\ncommand = vim.exe\n" });
        defer cfg.deinit();
        try testing.expect(nocttyCommand(&cfg) == null);
        try testing.expect(outcome(&cfg, "py") == .untried);
    }
    // The command line named another: the files' value was not looked up.
    {
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = nosuch\n", .argv = &.{"--default-profile=user:py"} });
        defer cfg.deinit();
        try testing.expect(commandLineNamesProfile(&cfg));
        try testing.expect(outcome(&cfg, filesDefaultProfile(&cfg)) == .untried);
        try testing.expect(outcome(&cfg, "user:py") == .resolved);
        // An empty one names none, and undoes the files'.
        var reset = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .argv = &.{"--default-profile="} });
        defer reset.deinit();
        try testing.expect(!commandLineNamesProfile(&reset));
        try testing.expect(defaultProfile(&reset) == null);
    }
    // Visual Studio did not answer: apart from not found, for its own value
    // only.
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var reader: std.Io.Reader = .fixed("default-profile = vs:newest:cmd\n");
        try cfg.loadReader(alloc, &reader, "C:\\noctty-test\\config.ghostty");
        try finalizeWith(&cfg, fixtures.Machine{ .visual_studio_answers = false });
        try testing.expect(outcome(&cfg, "vs:newest:cmd") == .unavailable);
        try testing.expect(outcome(&cfg, "vs:6bb7cfd9:cmd") == .untried);
    }
}

test "filesDefine: a profile the config files alone give" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const files =
        \\profile-command = filed: cmd.exe /k "C:\a b\x.cmd"
        \\profile-env = filed: TOKEN=secret
        \\profile-command = both: one.exe
        \\profile-command = gone: gone.exe
        \\profile-command = gone:
        \\profile-command = envcli: four.exe
        \\profile-env = envcli: MODE=file
        \\
    ;
    var cfg = try fixtures.load(alloc, .{
        .file = files,
        .argv = &.{ "--profile-command=clionly: two.exe", "--profile-command=both: three.exe", "--profile-env=envcli: OTHER=cli" },
    });
    defer cfg.deinit();
    try testing.expect(cfg._diagnostics.empty());

    // A profile the files define, by its key in any case; not one the
    // command line defines or last changed.
    try testing.expect(filesDefine(&cfg, "user:filed"));
    try testing.expect(filesDefine(&cfg, "USER:FILED"));
    try testing.expect(!filesDefine(&cfg, "user:clionly"));
    try testing.expect(!filesDefine(&cfg, "user:both"));
    // A file's profile with a variable from the command line, which a
    // process reading only the files would not get.
    try testing.expect(!filesDefine(&cfg, "user:envcli"));
    // `--profile-env=` cleared every profile's variables, which the files
    // would give back.
    {
        var cleared = try fixtures.load(alloc, .{ .file = files, .argv = &.{"--profile-env="} });
        defer cleared.deinit();
        try testing.expect(cleared.@"profile-env".count() == 0);
        try testing.expect(!filesDefine(&cleared, "user:filed"));
    }
    // An `--env=` argument, which `%NAME%` may read, and a conditional
    // rebuild, which replays it.
    {
        var with_env = try fixtures.load(alloc, .{ .file = files, .argv = &.{"--env=TOOLS=C:\\Tools"} });
        defer with_env.deinit();
        try testing.expect(!filesDefine(&with_env, "user:filed"));
        with_env._conditional_set.insert(.theme);
        var dark = (try with_env.changeConditionalState(.{ .theme = .dark })).?;
        defer dark.deinit();
        try testing.expect(!filesDefine(&dark, "user:filed"));
    }
    // Nothing on the command line.
    {
        var plain = try fixtures.load(alloc, .{ .file = files });
        defer plain.deinit();
        try testing.expect(filesDefine(&plain, "user:filed"));
    }
    // Nothing to name: a removed or unknown profile, a detected one, an id
    // that is no key.
    try testing.expect(!filesDefine(&cfg, "user:gone"));
    try testing.expect(!filesDefine(&cfg, "user:nosuch"));
    try testing.expect(!filesDefine(&cfg, "pwsh.exe"));
    try testing.expect(!filesDefine(&cfg, "filed"));
    // A Visual Studio shell, which discovery finds from the files.
    try testing.expect(filesDefine(&cfg, "vs:6bb7cfd9:cmd"));
    try testing.expect(filesDefine(&cfg, "VS:6BB7CFD9:PWSH"));

    // A config rebuilt for a conditional state (a theme) records the places
    // again, and a clone (a reload installs the app config as one) keeps
    // them.
    cfg._conditional_set.insert(.theme);
    var replayed = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer replayed.deinit();
    try testing.expect(filesDefine(&replayed, "user:filed"));
    try testing.expect(!filesDefine(&replayed, "user:clionly"));
    var reloaded = try cfg.clone(alloc);
    defer reloaded.deinit();
    try testing.expect(filesDefine(&reloaded, "user:filed"));
    try testing.expect(!filesDefine(&reloaded, "user:clionly"));
}

test "asWritten: a Settings copy holds what the files say, and no choice of noctty's" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try fixtures.load(alloc, .{
        .file = "profile-command = py: cmd.exe /k init.cmd\ndefault-profile = pwsh\n",
        .argv = &.{"--default-profile=user:py"},
    });
    defer cfg.deinit();
    try testing.expect(nocttyCommand(&cfg) != null);
    asWritten(&cfg);
    try testing.expect(cfg.command == null);
    try testing.expectEqualStrings("pwsh", cfg.@"default-profile" orelse return error.TestUnexpectedResult);
    // The load resolved the command line's `user:py`, not the files'
    // `pwsh`: the copy holds no answer for either.
    try testing.expect(defaultProfile(&cfg) == null);
    try testing.expect(outcome(&cfg, "pwsh") == .untried);
    // A command the user then types into the copy is the user's.
    cfg.command = .{ .shell = "pwsh.exe" };
    try testing.expect(nocttyCommand(&cfg) == null);

    // Nor one for a value the lookup found nothing for.
    var missing = try fixtures.load(alloc, .{ .file = "default-profile = nosuch\n" });
    defer missing.deinit();
    asWritten(&missing);
    try testing.expectEqualStrings("nosuch", missing.@"default-profile" orelse return error.TestUnexpectedResult);
    try testing.expect(outcome(&missing, "nosuch") == .untried);

    // A command a config layer set stays.
    var set = try fixtures.load(alloc, .{ .file = "command = vim.exe\n" });
    defer set.deinit();
    asWritten(&set);
    try testing.expectEqualStrings("vim.exe", set.command.?.shell);
}

test "keepSources: a config built again from the files keeps the running launch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    // A theme file that exists, so the rebuilt config's `finalize` builds it
    // again from its replay steps, as a palette theme preview's does.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "preview-theme", .data = "background = #102030\n" });
    const theme = try tmp.dir.realpathAlloc(alloc, "preview-theme");
    defer alloc.free(theme);

    // The running config: `default-profile = py`, resolved.
    var running = try fixtures.load(alloc, .{ .argv = &.{ "--profile-command=py: old.exe", "--profile-env=py: MODE=old", "--default-profile=py" } });
    defer running.deinit();

    // The files read again: the same `default-profile` with its profile
    // edited since, and one that names another profile.
    inline for (.{
        "profile-command = py: new.exe\nprofile-env = py: MODE=new\ndefault-profile = py\n",
        "profile-command = py: old.exe\nprofile-env = py: MODE=old\nprofile-command = other: other.exe\ndefault-profile = other\n",
    }) |edited| {
        const text = try std.fmt.allocPrint(alloc, "theme = {s}\n{s}", .{ theme, edited });
        defer alloc.free(text);
        var preview = try fixtures.load(alloc, .{ .file = text });
        defer preview.deinit();
        try keepSources(&preview, &running);
        try testing.expectEqual(@as(u8, 0x10), preview.background.r);
        // A new tab runs the definition the lists hold: the running one.
        try testing.expectEqualStrings("old.exe", preview.@"profile-command".get("py").?);
        try testing.expectEqualStrings("py", preview.@"default-profile".?);
        const kept = defaultProfile(&preview) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("old.exe", (kept.user orelse return error.TestUnexpectedResult).command_line);
        try testing.expectEqualStrings("old", kept.user.?.env[0].value);
        try testing.expectEqualStrings("old.exe", (nocttyCommand(&preview) orelse return error.TestUnexpectedResult).direct[0]);
    }

    // With no `default-profile` running, files that add one start nothing
    // new before the reload either.
    var plain = try fixtures.load(alloc, .{});
    defer plain.deinit();
    const added_text = try std.fmt.allocPrint(alloc, "theme = {s}\nprofile-command = py: new.exe\ndefault-profile = py\n", .{theme});
    defer alloc.free(added_text);
    var added = try fixtures.load(alloc, .{ .file = added_text });
    defer added.deinit();
    try keepSources(&added, &plain);
    try testing.expect(defaultProfile(&added) == null);
    try testing.expect(added.command == null);
    try testing.expect(nocttyCommand(&added) == null);

    // What Settings reads of the running value stays too: a command-line
    // value the lookup found nothing for, over the files' own, while the
    // files read again say nothing about it.
    var missing = try fixtures.load(alloc, .{ .file = "default-profile = pwsh\n", .argv = &.{"--default-profile=nosuch"} });
    defer missing.deinit();
    try testing.expect(outcome(&missing, "nosuch") == .not_found);
    try testing.expectEqualStrings("pwsh", filesDefaultProfile(&missing).?);
    const reread_text = try std.fmt.allocPrint(alloc, "theme = {s}\nfont-size = 13\n", .{theme});
    defer alloc.free(reread_text);
    var reread = try fixtures.load(alloc, .{ .file = reread_text });
    defer reread.deinit();
    try keepSources(&reread, &missing);
    try testing.expectEqualStrings("nosuch", reread.@"default-profile".?);
    try testing.expect(outcome(&reread, "nosuch") == .not_found);
    try testing.expectEqualStrings("pwsh", filesDefaultProfile(&reread).?);
}

/// The user profiles `config` defines, built as discovery builds them.
fn testUserProfiles(alloc: Allocator, config: *const Config) ![]windows_shell.Profile {
    var user = try windows_shell.UserProfiles.init(alloc, config);
    defer user.deinit();
    return try windows_shell.appendUserProfiles(alloc, try alloc.alloc(windows_shell.Profile, 0), user.definitions, windows_shell.ProcessEnvironment{});
}

/// A new pane's config: a shallow clone of `config` in `C:\work`, as the
/// ordinary rules left it.
fn testPane(alloc: Allocator, config: *const Config) !Config {
    var pane = config.shallowClone(alloc);
    errdefer pane.deinit();
    pane.@"working-directory" = .{ .path = try pane._arena.?.allocator().dupe(u8, "C:\\work") };
    return pane;
}

/// Where `config` starts: its path, `~` for `.home`, or "" for neither.
fn testDirectory(config: *const Config) []const u8 {
    const directory = config.@"working-directory" orelse return "";
    return switch (directory) {
        .path => |path| path,
        .home => "~",
        .inherit => "",
    };
}

test "prepare: a fresh pane runs default-profile's profile, except the first pane of -e" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const files =
        \\env = Path=C:\global
        \\env = KEEP=1
        \\profile-command = py: cmd.exe /k py
        \\profile-env = py: PATH=C:\profile
        \\profile-env = py: MODE=profile
        \\profile-working-directory = py: D:\pinned
        \\profile-command = ubuntu: wsl.exe -d Ubuntu
        \\profile-working-directory = ubuntu: home
        \\
    ;
    const Row = struct {
        default: []const u8 = "",
        argv: []const []const u8 = &.{},
        first: bool = false,
        named_directory: bool = false,
        /// The key the pane records; null for no launch of the default.
        key: ?[]const u8 = null,
        line: bool = false,
        directory: []const u8 = "C:\\work",
    };
    for ([_]Row{
        // No default profile, nothing to start.
        .{},
        .{ .default = "py", .key = "user:py", .line = true, .directory = "D:\\pinned" },
        // The first pane of a launch with `-e` runs that command; a later
        // pane of it runs the profile.
        .{ .default = "py", .argv = &.{ "-e", "vim.exe" }, .first = true },
        .{ .default = "py", .argv = &.{ "-e", "vim.exe" }, .key = "user:py", .line = true, .directory = "D:\\pinned" },
        // A directory the launch named wins over the pinned one.
        .{ .default = "py", .named_directory = true, .key = "user:py", .line = true },
        // A wsl.exe profile in home keeps `.home`, which gives `--cd ~`.
        .{ .default = "ubuntu", .key = "user:ubuntu", .line = true, .directory = "~" },
        .{ .default = "ubuntu", .named_directory = true, .key = "user:ubuntu", .line = true },
        // A profile that pins nothing keeps the ordinary rules' directory.
        .{ .default = "wsl:Ubuntu", .key = "wsl:Ubuntu" },
        .{ .default = "vs:6bb7cfd9:cmd", .key = "vs:6bb7cfd9:cmd", .line = true },
    }) |row| {
        const text = try std.fmt.allocPrint(alloc, "{s}default-profile = {s}\n", .{ files, row.default });
        defer alloc.free(text);
        var cfg = try fixtures.load(alloc, .{ .file = text, .argv = row.argv });
        defer cfg.deinit();
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{ .first = row.first };
        const stamp = try prepare(&pane, .{ .fresh = .{ .named_directory = row.named_directory } }, &context);
        testing.expectEqualStrings(row.key orelse "", stamp.key orelse "") catch |err| {
            std.debug.print("default-profile = {s}, first={}\n", .{ row.default, row.first });
            return err;
        };
        try testing.expect(!stamp.ssh and stamp.title == null);
        try testing.expectEqual(row.line, stamp.user != null);
        try testing.expectEqualStrings(row.directory, testDirectory(&pane));
        // Started: no longer noctty's choice, so the default does not
        // stack on it.
        if (row.key != null) try testing.expect(!defaultApplies(&pane, false));
    }

    // The profile's variables go on a copy, and its command is the pane's.
    {
        var cfg = try fixtures.load(alloc, .{ .file = files ++ "default-profile = py\n" });
        defer cfg.deinit();
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{};
        const stamp = try prepare(&pane, .{ .fresh = .{} }, &context);
        try testing.expectEqualStrings("cmd.exe /k py", (stamp.user orelse return error.TestUnexpectedResult).command_line);
        // The profile's PATH replaces the global Path whatever the case.
        try testing.expectEqualStrings("C:\\profile", pane.env.map.get("PATH") orelse "");
        try testing.expect(pane.env.map.get("Path") == null);
        try testing.expectEqualStrings("1", pane.env.map.get("KEEP") orelse "");
        try testing.expectEqualStrings("profile", pane.env.map.get("MODE") orelse "");
        // The app config's map and command, which the clone shared, stay.
        try testing.expectEqualStrings("C:\\global", cfg.env.map.get("Path") orelse "");
        try testing.expect(cfg.env.map.get("MODE") == null);
        const words = try testDirectCommand(pane.command);
        try testing.expectEqualStrings("cmd.exe", words[0]);
        try testing.expect(words.ptr != (try testDirectCommand(cfg.command)).ptr);
    }

    // An SSH default is hardened and starts in USERPROFILE whatever the
    // launch named, with its alias as the tab title.
    {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = (try windows_ssh_hosts.userProfileDir(&home_buf)) orelse return error.SkipZigTest;
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var reader: std.Io.Reader = .fixed("default-profile = ssh:prod\n");
        try cfg.loadReader(alloc, &reader, "C:\\noctty-test\\config.ghostty");
        try finalizeWith(&cfg, fixtures.Machine{ .ssh = true });
        for ([_]bool{ false, true }) |named_directory| {
            var pane = try testPane(alloc, &cfg);
            defer pane.deinit();
            var context: fixtures.Context = .{};
            const stamp = try prepare(&pane, .{ .fresh = .{ .named_directory = named_directory } }, &context);
            try testing.expectEqualStrings("ssh:prod", stamp.key orelse "");
            try testing.expect(stamp.ssh);
            try testing.expectEqualStrings("prod", stamp.title orelse "");
            try testing.expectEqualStrings(home, testDirectory(&pane));
            try testing.expectEqual(Config.ShellIntegration.none, pane.@"shell-integration");
            try testing.expectEqual(Config.ShellIntegration.detect, cfg.@"shell-integration");
        }
    }
}

test "prepare: a chosen profile starts in home unless it pins a directory or inherits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try fixtures.load(alloc, .{ .file = 
        \\env = Path=C:\global
        \\env = KEEP=1
        \\profile-command = plain: cmd.exe /k echo "a&b"
        \\profile-env = plain: PATH=C:\profile
        \\profile-env = plain: NEW=2
        \\profile-command = home: tool.exe
        \\profile-working-directory = home: home
        \\profile-command = inh: tool.exe
        \\profile-working-directory = inh: inherit
        \\profile-command = pin: tool.exe
        \\profile-working-directory = pin: D:\pinned dir
        \\profile-command = ubuntu: wsl.exe -d Ubuntu
        \\profile-command = wslhome: C:\Windows\System32\wsl.exe -d Ubuntu
        \\profile-working-directory = wslhome: home
        \\
    });
    defer cfg.deinit();
    try testing.expect(cfg._diagnostics.empty());
    // A command the app config has, which the pane's clone shares.
    cfg.command = .{ .shell = "pwsh.exe" };
    const profiles = try testUserProfiles(alloc, &cfg);
    defer windows_shell.deinitProfiles(alloc, profiles);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try internal_os.home(&home_buf)) orelse return error.SkipZigTest;

    // Home as a path: a bare `.home` on a pane's config would start in
    // noctty's own folder. A wsl.exe launch keeps `.home`, which gives
    // `--cd ~` (the Linux home), not `/mnt/c/Users/<name>`.
    const pwsh = [_][:0]const u8{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"};
    const powershell = [_][:0]const u8{"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"};
    const cmd = [_][:0]const u8{"C:\\Windows\\System32\\cmd.exe"};
    const git_bash = [_][:0]const u8{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" };
    const wsl_default = [_][:0]const u8{"C:\\Windows\\System32\\wsl.exe"};
    const wsl_distro = [_][:0]const u8{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu" };
    const detected = [_]windows_shell.Profile{
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &pwsh } },
        .{ .kind = .powershell, .key = "powershell.exe", .label = "Windows PowerShell", .command = .{ .direct = &powershell } },
        .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &cmd } },
        .{ .kind = .git_bash, .key = "git-bash", .label = "Git Bash", .command = .{ .direct = &git_bash } },
        .{ .kind = .wsl_default, .key = "wsl-default", .label = "WSL", .command = .{ .direct = &wsl_default } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "Ubuntu", .command = .{ .direct = &wsl_distro } },
    };
    for (&detected) |*profile| {
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{};
        const stamp = try prepare(&pane, .{ .chosen = profile }, &context);
        try testing.expectEqualStrings(profile.key, stamp.key orelse "");
        try testing.expect(stamp.user == null and stamp.title == null);
        const wsl = profile.kind == .wsl_default or profile.kind == .wsl_distro;
        try testing.expectEqualStrings(if (wsl) "~" else home, testDirectory(&pane));
    }
    for ([_]struct { key: []const u8, directory: []const u8 }{
        .{ .key = "user:plain", .directory = home },
        .{ .key = "user:home", .directory = home },
        // `inherit`: the directory the ordinary rules gave stays.
        .{ .key = "user:inh", .directory = "C:\\work" },
        .{ .key = "user:pin", .directory = "D:\\pinned dir" },
        .{ .key = "user:ubuntu", .directory = "~" },
        .{ .key = "user:wslhome", .directory = "~" },
    }) |row| {
        const profile = for (profiles) |*profile| {
            if (std.mem.eql(u8, profile.key, row.key)) break profile;
        } else return error.TestUnexpectedResult;
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{};
        const stamp = try prepare(&pane, .{ .chosen = profile }, &context);
        try testing.expectEqualStrings(row.key, stamp.key orelse "");
        try testing.expectEqualStrings(row.directory, testDirectory(&pane));
        if (std.mem.eql(u8, row.key, "user:ubuntu")) {
            // What Exec then runs (`Surface` passes `wd == .home`).
            const command = pane.command orelse return error.TestUnexpectedResult;
            const prepared = try windows_shell.prepareCommand(alloc, command, null, true, false);
            defer prepared.deinit(alloc);
            const argv = prepared.direct;
            const cd = for (argv, 0..) |arg, i| {
                if (std.mem.eql(u8, arg, "--cd")) break i;
            } else return error.TestExpectedCd;
            try testing.expectEqualStrings("~", argv[cd + 1]);
        }
        if (!std.mem.eql(u8, row.key, "user:plain")) continue;
        // The line the pane runs as written, and the profile's variables on
        // a copy: its PATH replaces the global Path whatever the case.
        try testing.expectEqualStrings("cmd.exe /k echo \"a&b\"", (stamp.user orelse return error.TestUnexpectedResult).command_line);
        try testing.expectEqual(@as(usize, 4), (try testDirectCommand(pane.command)).len);
        try testing.expectEqualStrings("C:\\profile", pane.env.map.get("PATH") orelse "");
        try testing.expect(pane.env.map.get("Path") == null);
        try testing.expectEqualStrings("1", pane.env.map.get("KEEP") orelse "");
        try testing.expectEqualStrings("2", pane.env.map.get("NEW") orelse "");
        try testing.expectEqual(@as(usize, 2), cfg.env.count());
        try testing.expectEqualStrings("C:\\global", cfg.env.map.get("Path") orelse "");
        // The app config's command is not freed or replaced.
        try testing.expectEqualStrings("pwsh.exe", try testShellCommand(cfg.command));
    }

    // SSH: the two-word argv, hardened, in USERPROFILE (a path, so it
    // outranks an inherited directory), the alias as its title.
    {
        var ssh_home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const ssh_home = (try windows_ssh_hosts.userProfileDir(&ssh_home_buf)) orelse return error.SkipZigTest;
        const argv = [_][:0]const u8{ "C:\\Windows\\System32\\OpenSSH\\ssh.exe", "production" };
        const profile: windows_shell.Profile = .{ .kind = .ssh, .key = "ssh:production", .label = "SSH: production", .command = .{ .direct = &argv } };
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        pane.@"shell-integration" = .bash;
        var context: fixtures.Context = .{};
        const stamp = try prepare(&pane, .{ .chosen = &profile }, &context);
        try testing.expectEqualStrings("ssh:production", stamp.key orelse "");
        try testing.expect(stamp.ssh);
        try testing.expectEqualStrings("production", stamp.title orelse "");
        try testing.expectEqualStrings("production", (try testDirectCommand(pane.command))[1]);
        try testing.expectEqualStrings(ssh_home, testDirectory(&pane));
        try testing.expectEqual(Config.ShellIntegration.none, pane.@"shell-integration");
    }
}

/// User profiles for the inherit, split and restore rows, with
/// `default-profile = py`.
const test_source_profiles =
    \\profile-command = py: cmd.exe /k py
    \\profile-env = py: MODE=profile
    \\profile-working-directory = py: D:\pinned
    \\profile-command = tool: new.exe
    \\profile-env = tool: MODE=new
    \\profile-command = home: tool.exe
    \\profile-working-directory = home: home
    \\profile-command = inh: tool.exe
    \\profile-working-directory = inh: inherit
    \\profile-command = unset: tool.exe
    \\profile-command = ubuntu: wsl.exe -d Ubuntu
    \\profile-working-directory = ubuntu: home
    \\default-profile = py
    \\
;

test "prepare: an inherited launch repeats the source's as it started" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try fixtures.load(alloc, .{ .file = test_source_profiles });
    defer cfg.deinit();
    try testing.expect(cfg._diagnostics.empty());
    const profiles = try testUserProfiles(alloc, &cfg);
    defer windows_shell.deinitProfiles(alloc, profiles);

    // What the source started, though a reload changed `tool` since: the
    // snapshot runs, not the default profile, and no list is asked.
    {
        const started = [_][:0]const u8{ "old.exe", "/x" };
        const started_env = [_]windows_shell.EnvEntry{.{ .key = "MODE", .value = "old" }};
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{ .window = profiles };
        const stamp = try prepare(&pane, .{ .inherit = .{
            .command = .{ .direct = &started },
            .user = .{ .command_line = "old.exe /x", .env = &started_env },
            .key = "user:tool",
        } }, &context);
        try testing.expectEqualStrings("user:tool", stamp.key orelse "");
        try testing.expect(!stamp.ssh and stamp.title == null);
        try testing.expectEqualStrings("old.exe /x", (stamp.user orelse return error.TestUnexpectedResult).command_line);
        const words = try testDirectCommand(pane.command);
        try testing.expectEqual(@as(usize, 2), words.len);
        try testing.expectEqualStrings("old.exe", words[0]);
        try testing.expectEqualStrings("/x", words[1]);
        // The variables on a copy; the directory as the ordinary rules left it.
        try testing.expectEqualStrings("old", pane.env.map.get("MODE") orelse "");
        try testing.expect(cfg.env.map.get("MODE") == null);
        try testing.expectEqualStrings("C:\\work", testDirectory(&pane));
        try testing.expectEqual(@as(usize, 0), context.listed_count);
        try testing.expect(!defaultApplies(&pane, false));
    }
    // An SSH source's command, hardened again; a pane that ran no profile
    // (`-e`) has no key to repeat.
    {
        var home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const home = (try windows_ssh_hosts.userProfileDir(&home_buf)) orelse return error.SkipZigTest;
        const ssh = [_][:0]const u8{ "C:\\Windows\\System32\\OpenSSH\\ssh.exe", "production" };
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        pane.@"shell-integration" = .bash;
        var context: fixtures.Context = .{};
        const stamp = try prepare(&pane, .{ .inherit = .{ .command = .{ .direct = &ssh }, .key = "ssh:production", .ssh = true } }, &context);
        try testing.expectEqualStrings("ssh:production", stamp.key orelse "");
        try testing.expect(stamp.ssh and stamp.title == null and stamp.user == null);
        try testing.expectEqualStrings("production", (try testDirectCommand(pane.command))[1]);
        try testing.expectEqual(Config.ShellIntegration.none, pane.@"shell-integration");
        try testing.expectEqualStrings(home, testDirectory(&pane));

        const one_shot = [_][:0]const u8{ "cmd.exe", "/c", "one-shot.cmd" };
        var e_pane = try testPane(alloc, &cfg);
        defer e_pane.deinit();
        const e_stamp = try prepare(&e_pane, .{ .inherit = .{ .command = .{ .direct = &one_shot } } }, &context);
        try testing.expect(e_stamp.key == null and e_stamp.user == null);
        try testing.expectEqualStrings("one-shot.cmd", (try testDirectCommand(e_pane.command))[2]);
    }
    // A source with no command (headless fixtures): its profile by its key,
    // the default's without a list, else the window's; with neither, the
    // default profile.
    for ([_]struct { key: ?[]const u8, started: []const u8, listed: usize }{
        .{ .key = "USER:PY", .started = "user:py", .listed = 0 },
        .{ .key = "user:tool", .started = "user:tool", .listed = 1 },
        .{ .key = "user:gone", .started = "user:py", .listed = 1 },
        .{ .key = null, .started = "user:py", .listed = 0 },
    }) |row| {
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{ .window = profiles };
        const stamp = try prepare(&pane, .{ .inherit = .{ .key = row.key } }, &context);
        try testing.expectEqualStrings(row.started, stamp.key orelse "");
        try testing.expectEqual(row.listed, context.listed_count);
    }
}

test "prepare: a split starts the source's profile as it is defined now" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try fixtures.load(alloc, .{ .file = test_source_profiles });
    defer cfg.deinit();
    const profiles = try testUserProfiles(alloc, &cfg);
    defer windows_shell.deinitProfiles(alloc, profiles);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try internal_os.home(&home_buf)) orelse return error.SkipZigTest;

    // The split's own directory inheritance comes after `prepare`; before
    // it, a profile with no pinned directory keeps the ordinary rules' one
    // (no home, unlike a chosen profile), and a wsl.exe one in home keeps
    // `.home`.
    for ([_]struct { key: []const u8, started: []const u8, directory: []const u8, line: []const u8, mode: []const u8 = "", listed: usize = 1 }{
        // The default profile's own key needs no list (no WSL probe on the
        // UI thread), in any case.
        .{ .key = "USER:PY", .started = "user:py", .directory = "D:\\pinned", .line = "cmd.exe /k py", .mode = "profile", .listed = 0 },
        // The definition now, from the window's list.
        .{ .key = "user:tool", .started = "user:tool", .directory = "C:\\work", .line = "new.exe", .mode = "new" },
        .{ .key = "user:home", .started = "user:home", .directory = home, .line = "tool.exe" },
        .{ .key = "user:inh", .started = "user:inh", .directory = "C:\\work", .line = "tool.exe" },
        .{ .key = "user:unset", .started = "user:unset", .directory = "C:\\work", .line = "tool.exe" },
        .{ .key = "user:ubuntu", .started = "user:ubuntu", .directory = "~", .line = "wsl.exe -d Ubuntu" },
        // A profile no longer there: the default one.
        .{ .key = "user:gone", .started = "user:py", .directory = "D:\\pinned", .line = "cmd.exe /k py", .mode = "profile" },
    }) |row| {
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{ .window = profiles };
        const stamp = try prepare(&pane, .{ .split = .{ .key = row.key } }, &context);
        testing.expectEqualStrings(row.started, stamp.key orelse "") catch |err| {
            std.debug.print("split of {s}\n", .{row.key});
            return err;
        };
        try testing.expectEqualStrings(row.directory, testDirectory(&pane));
        try testing.expectEqualStrings(row.line, (stamp.user orelse return error.TestUnexpectedResult).command_line);
        try testing.expectEqualStrings(row.mode, pane.env.map.get("MODE") orelse "");
        try testing.expectEqual(row.listed, context.listed_count);
        try testing.expect(!stamp.ssh and stamp.title == null);
    }

    // An SSH profile is hardened on this path too.
    {
        var ssh_home_buf: [std.fs.max_path_bytes]u8 = undefined;
        const ssh_home = (try windows_ssh_hosts.userProfileDir(&ssh_home_buf)) orelse return error.SkipZigTest;
        const argv = [_][:0]const u8{ "C:\\Windows\\System32\\OpenSSH\\ssh.exe", "production" };
        const ssh = [_]windows_shell.Profile{.{ .kind = .ssh, .key = "ssh:production", .label = "SSH: production", .command = .{ .direct = &argv } }};
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        pane.@"shell-integration" = .bash;
        var context: fixtures.Context = .{ .window = &ssh };
        const stamp = try prepare(&pane, .{ .split = .{ .key = "ssh:production", .ssh = true } }, &context);
        try testing.expectEqualStrings("ssh:production", stamp.key orelse "");
        try testing.expect(stamp.ssh and stamp.title == null);
        try testing.expectEqual(Config.ShellIntegration.none, pane.@"shell-integration");
        try testing.expectEqualStrings(ssh_home, testDirectory(&pane));
    }

    // A source that ran no profile, a one-shot command among them: the
    // command is not repeated, and with no default profile nothing starts.
    {
        var plain = try fixtures.load(alloc, .{});
        defer plain.deinit();
        const one_shot = [_][:0]const u8{ "cmd.exe", "/c", "one-shot.cmd" };
        var pane = try testPane(alloc, &plain);
        defer pane.deinit();
        var context: fixtures.Context = .{ .window = profiles };
        const stamp = try prepare(&pane, .{ .split = .{ .command = .{ .direct = &one_shot } } }, &context);
        try testing.expect(stamp.key == null and pane.command == null);
        try testing.expectEqual(@as(usize, 0), context.listed_count);
    }
}

test "prepare: a restored pane runs its saved profile, and never connects over SSH" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try internal_os.home(&home_buf)) orelse return error.SkipZigTest;
    var cfg = try fixtures.load(alloc, .{ .file = test_source_profiles, .argv = &.{ "-e", "vim.exe" } });
    defer cfg.deinit();
    var plain = try fixtures.load(alloc, .{ .file = "profile-command = vs18-cmd: cmd.exe /k VsDevCmd.bat\n" });
    defer plain.deinit();
    const user = try testUserProfiles(alloc, &plain);
    defer windows_shell.deinitProfiles(alloc, user);
    var complete = true;
    const vs = try (fixtures.Machine{}).visualStudio(alloc, &complete);
    defer windows_shell.deinitProfiles(alloc, vs);
    const pwsh_argv = [_][:0]const u8{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"};
    const ssh_argv = [_][:0]const u8{ "C:\\Windows\\System32\\OpenSSH\\ssh.exe", "prod" };
    const window = [_]windows_shell.Profile{
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &pwsh_argv } },
        .{ .kind = .ssh, .key = "ssh:prod", .label = "SSH: prod", .command = .{ .direct = &ssh_argv } },
        // An SSH profile, whatever its key says.
        .{ .kind = .ssh, .key = "user:tunnel", .label = "Tunnel", .command = .{ .direct = &ssh_argv } },
        vs[0],
        vs[1],
    };
    // Visual Studio's Developer Command Prompt runs its line as written.
    const vs_cmd_line = for (vs) |profile| {
        if (std.mem.eql(u8, profile.key, "vs:6bb7cfd9:cmd")) break (profile.user orelse return error.TestUnexpectedResult).command_line;
    } else return error.TestUnexpectedResult;

    const Row = struct {
        config: *const Config,
        saved: ?[]const u8,
        window: ?[]const windows_shell.Profile,
        discovered: []const windows_shell.Profile = &.{},
        /// The key the pane keeps; null for none.
        key: ?[]const u8,
        /// What it starts in: "" for the directory it had.
        directory: []const u8 = "",
        line: ?[]const u8 = null,
        listed: usize = 0,
        discovered_count: usize = 0,
    };
    for ([_]Row{
        // Its own profile, by the saved key, whose case it keeps; in home.
        .{ .config = &cfg, .saved = "PWSH.EXE", .window = &window, .key = "PWSH.EXE", .directory = home, .listed = 1 },
        // `default-profile`'s, from the config, with or without a window,
        // and listing nothing.
        .{ .config = &cfg, .saved = "USER:PY", .window = &window, .key = "USER:PY", .directory = "D:\\pinned", .line = "cmd.exe /k py" },
        .{ .config = &cfg, .saved = "USER:PY", .window = null, .key = "USER:PY", .directory = "D:\\pinned", .line = "cmd.exe /k py" },
        // With no window, from a discovery, in any case.
        .{ .config = &plain, .saved = "USER:VS18-CMD", .window = null, .discovered = user, .key = "USER:VS18-CMD", .directory = home, .line = "cmd.exe /k VsDevCmd.bat", .discovered_count = 1 },
        // With a window, from its list only: no discovery (WSL probes).
        .{ .config = &plain, .saved = "user:vs18-cmd", .window = &window, .discovered = user, .key = null, .listed = 1 },
        // Visual Studio's, hidden or not, with and without a window.
        .{ .config = &plain, .saved = "vs:6bb7cfd9:pwsh", .window = &window, .key = "vs:6bb7cfd9:pwsh", .directory = home, .listed = 1 },
        .{ .config = &plain, .saved = "VS:6BB7CFD9:CMD", .window = null, .discovered = vs, .key = "VS:6BB7CFD9:CMD", .directory = home, .line = vs_cmd_line, .discovered_count = 1 },
        // SSH: refused by its prefix in any case before any lookup (an exact
        // SSH lookup misses a case variant), and by its kind after one.
        .{ .config = &plain, .saved = "ssh:prod", .window = &window, .key = null },
        .{ .config = &plain, .saved = "SSH:prod", .window = null, .discovered = &window, .key = null },
        .{ .config = &plain, .saved = "Ssh:PROD", .window = &window, .key = null },
        .{ .config = &plain, .saved = "user:tunnel", .window = &window, .key = null, .listed = 1 },
        // A profile that is gone, or none saved: the default profile.
        .{ .config = &cfg, .saved = "user:gone", .window = &window, .key = "user:py", .directory = "D:\\pinned", .line = "cmd.exe /k py", .listed = 1 },
        .{ .config = &cfg, .saved = null, .window = &window, .key = "user:py", .directory = "D:\\pinned", .line = "cmd.exe /k py" },
        .{ .config = &plain, .saved = "user:gone", .window = null, .discovered = user, .key = null, .discovered_count = 1 },
    }) |row| {
        var pane = try testPane(alloc, row.config);
        defer pane.deinit();
        // The first pane: `-e`'s command does not run in a restored one.
        var context: fixtures.Context = .{ .first = true, .window = row.window, .discovered = row.discovered };
        const stamp = try prepare(&pane, .{ .restored = row.saved }, &context);
        testing.expectEqualStrings(row.key orelse "", stamp.key orelse "") catch |err| {
            std.debug.print("restore of {s}\n", .{row.saved orelse "(none)"});
            return err;
        };
        try testing.expect(pane.@"initial-command" == null);
        try testing.expect(!stamp.ssh and stamp.title == null);
        try testing.expectEqualStrings(if (row.directory.len > 0) row.directory else "C:\\work", testDirectory(&pane));
        if (row.line) |line| try testing.expectEqualStrings(line, (stamp.user orelse return error.TestUnexpectedResult).command_line);
        try testing.expectEqual(row.listed, context.listed_count);
        try testing.expectEqual(row.discovered_count, context.discover_count);
        if (row.key == null) try testing.expect(pane.command == null);
    }
    // The pane's own profile alone: none of the default profile's variables.
    {
        var pane = try testPane(alloc, &cfg);
        defer pane.deinit();
        var context: fixtures.Context = .{ .window = &window };
        _ = try prepare(&pane, .{ .restored = "pwsh.exe" }, &context);
        try testing.expectEqualStrings(pwsh_argv[0], (try testDirectCommand(pane.command))[0]);
        try testing.expect(pane.env.map.get("MODE") == null);
    }

    // An SSH default: the automatic shell instead, marked as noctty's.
    {
        var ssh = try Config.default(alloc);
        defer ssh.deinit();
        var reader: std.Io.Reader = .fixed("default-profile = ssh:prod\n");
        try ssh.loadReader(alloc, &reader, "C:\\noctty-test\\config.ghostty");
        try finalizeWith(&ssh, fixtures.Machine{ .ssh = true });
        try testing.expect(defaultProfile(&ssh) != null);
        for ([_]?[]const u8{ null, "ssh:prod", "user:gone" }) |saved| {
            var pane = try testPane(alloc, &ssh);
            defer pane.deinit();
            var context: fixtures.Context = .{ .window = &window };
            const stamp = try prepare(&pane, .{ .restored = saved }, &context);
            try testing.expect(stamp.key == null and !stamp.ssh and stamp.title == null);
            try testing.expectEqualStrings(fixtures.Context.automatic_argv[0], (try testDirectCommand(nocttyCommand(&pane)))[0]);
            try testing.expectEqual(Config.ShellIntegration.detect, pane.@"shell-integration");
            try testing.expectEqualStrings("C:\\work", testDirectory(&pane));
        }
    }
}
