//! Which command a new pane runs: the launch side of a config load.
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
const cli_diags = @import("../cli/diagnostics.zig");

const cli = struct {
    const args = @import("../cli/args.zig");
    const Diagnostic = cli_diags.Diagnostic;
    const Location = cli_diags.Location;
};

const log = std.log.scoped(.config);

/// What `arg` sets of the launch, read before the field parse
/// (`Config.parseManuallyHook` calls this first): the command line's accepted
/// `--command=`, `--initial-command=` and `--default-profile=`, the files'
/// `default-profile`, which layer set `command`, and where a profile line was
/// read.
pub fn note(self: *Config, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!void {
    // Only a value the field parse takes changes `command` (and so which layer
    // set it, and what `finalize` puts back); a refused one leaves all of
    // that as it was and is reported by the parse that follows.
    if (try takenCliValue(self, "command", arg)) |value| {
        const location = try cli.Location.fromIter(iter, alloc);
        self._command_defaulted = false;
        self._command_from_file = location == .file;
        if (location == .cli) self._command_cli = try alloc.dupeZ(u8, value);
    }
    if (std.mem.startsWith(u8, arg, "--initial-command=")) {
        if ((try cli.Location.fromIter(iter, alloc)) == .cli) {
            if (try takenCliValue(self, "initial-command", arg)) |value| {
                self._initial_command_cli = try alloc.dupeZ(u8, value);
            }
        }
    }
    if (std.mem.startsWith(u8, arg, "--default-profile=")) {
        const value = arg["--default-profile=".len..];
        if ((try cli.Location.fromIter(iter, alloc)) == .cli) {
            self._default_profile_cli = try alloc.dupeZ(u8, value);
        } else {
            self._default_profile_file = if (value.len == 0) null else try alloc.dupeZ(u8, value);
        }
    }
    // The place a profile line writes, for a problem only finalize sees.
    try recordProfilePlace(self, alloc, arg, iter);
}

/// `Config.consumeManuallyHook`: takes `--elevated-profile-env=KEY=VALUE`.
pub fn consume(
    self: *Config,
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
        try self._diagnostics.append(alloc, .{
            .key = try alloc.dupeZ(u8, "elevated-profile-env"),
            .message = message,
            .location = location,
        });
        return true;
    }
    try self._elevated_profile_env.append(alloc, .{
        .key = try alloc.dupeZ(u8, value[0..eq]),
        .value = try alloc.dupeZ(u8, value[eq + 1 ..]),
    });
    return true;
}

/// The launch half of `Config.finalize`, after the theme and before the
/// automatic default. Tests resolve `default-profile` through fixed lookups
/// (no PATH search), so they load it through this same call.
pub fn finalize(self: *Config) !void {
    const visual_studio = self.@"visual-studio-profiles";
    try finalizeWith(self, if (comptime builtin.is_test)
        fixtures.Machine{ .visual_studio = visual_studio }
    else
        windows_shell.ReferenceHost{ .visual_studio = visual_studio });
}

/// `finalize` with the lookups `machine` makes for `default-profile`.
pub fn finalizeWith(self: *Config, machine: anytype) !void {
    // Before the default command: `default-profile` can name a user profile,
    // which has to have passed these checks.
    try finalizeProfiles(self);
    try finalizeCliLaunch(self);
    try finalizeDefaultProfileSetting(self);
    // `default-profile` stands in for the automatic default.
    if (comptime builtin.os.tag == .windows) {
        if (self.command == null) try applyDefaultProfile(self, machine);
    }
    // Over `env` once every file has been read, and after `default-profile`
    // resolved: a profile's `%NAME%` reads `env` (`expandProfileText`).
    if (self._elevated_profile_env.items.len > 0) {
        try windows_shell.layerEnv(self._arena.?.allocator(), &self.env, self._elevated_profile_env.items);
    }
}

/// Resolve the automatic Windows command without hiding whether it was explicit.
pub fn useAutomatic(self: *Config) !void {
    if (self.command != null) return;
    setAutomaticCommand(self, "windows-default", try windows_shell.defaultCommand(self._arena.?.allocator()));
}

/// Give a config with no `command` the one safe mode starts, so a recovery
/// launch runs neither the user's PowerShell profile nor AutoRun. Call it before
/// `Config.finalize`, which then has no default to look for: safe mode
/// searches no `PATH`. The command stays marked automatic. A command already
/// set stays.
pub fn useRecovery(self: *Config) !void {
    if (self.command != null) return;
    setAutomaticCommand(self, "windows-recovery", try windows_shell.recoveryCommand(self._arena.?.allocator()));
}

/// Set `command` to `cmd`, chosen by noctty rather than a config layer.
fn setAutomaticCommand(self: *Config, comptime src: []const u8, cmd: Command) void {
    log.info("default shell src=" ++ src ++ " value={f}", .{cmd.redacted()});
    self.command = cmd;
    self._command_defaulted = true;
}

/// Check what needs every layer read: a `profile-name`,
/// `profile-working-directory` or `profile-env` entry whose id no
/// `profile-command` line names, live or removed, since a field may come
/// before the line that defines its profile, or from another file. Each is a
/// config problem at the last line that wrote it, and is dropped, so nothing
/// downstream sees a field of a profile the user was told does not exist.
/// Every other profile check runs while the line is parsed
/// (`profile_map.check`).
fn finalizeProfiles(self: *Config) Allocator.Error!void {
    try finalizeProfileField(self, ProfileMap.Name, &self.@"profile-name", "profile-name");
    try finalizeProfileField(self, ProfileMap.Text, &self.@"profile-working-directory", "profile-working-directory");
    try finalizeProfileField(self, ProfileMap.Env, &self.@"profile-env", "profile-env");
    try finalizeProfileReferences(self, "profile-order");
    try finalizeProfileReferences(self, "profile-hidden");
}

/// Report each `profile-order` or `profile-hidden` value that can name no
/// profile anywhere (`windows_shell.referenceCanName`): a typo, an id no
/// `profile-command` line names, a comment after the value. One naming a
/// shell this machine lacks (`wsl:docker-desktop`, an `ssh:` host) is not
/// reported, so a shared config loads quietly everywhere. A reference is not
/// a secret, so the message quotes it, as `default-profile`'s does.
fn finalizeProfileReferences(self: *Config, comptime key: [:0]const u8) Allocator.Error!void {
    const alloc = self._arena.?.allocator();
    for (@field(self, key).list.items) |reference| {
        if (windows_shell.referenceCanName(reference, &self.@"profile-command")) continue;
        try appendFinalizeProblem(self, .{
            .key = key,
            .message = try std.fmt.allocPrintSentinel(alloc, "\"{s}\" names no profile: use a profile-command id, " ++
                "a key such as pwsh.exe, wsl:<distribution>, ssh:<alias> or vs:newest:cmd, or a name such as pwsh, git, cmd or wsl{s}", .{
                reference,
                if (hasInlineComment(reference)) " (comments go on a line of their own)" else "",
            }, 0),
            .location = try profilePlace(self, key, reference).clone(alloc),
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
    self: *Config,
    comptime Map: type,
    map: *Map,
    comptime key: [:0]const u8,
) Allocator.Error!void {
    const alloc = self._arena.?.allocator();
    var index: usize = 0;
    while (index < map.entries.items.len) {
        const id = map.entries.items[index].id;
        if (self.@"profile-command".contains(id)) {
            index += 1;
            continue;
        }
        try self._diagnostics.append(alloc, .{
            .key = key,
            .message = try std.fmt.allocPrintSentinel(
                alloc,
                "\"{s}\" has no profile-command line, so there is no such profile",
                .{id},
                0,
            ),
            .location = try profilePlace(self, key, id).clone(alloc),
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
pub fn cloneProfilePlaces(self: *const Config, alloc: Allocator) Allocator.Error!std.ArrayListUnmanaged(ProfilePlace) {
    var out: std.ArrayListUnmanaged(ProfilePlace) = .empty;
    try out.ensureTotalCapacity(alloc, self._profile_places.items.len);
    for (self._profile_places.items) |place| {
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
pub fn profilePlace(self: *const Config, key: []const u8, id: []const u8) cli.Location {
    var index = self._profile_places.items.len;
    while (index > 0) {
        index -= 1;
        const place = self._profile_places.items[index];
        if (std.mem.eql(u8, place.key, key) and std.ascii.eqlIgnoreCase(place.id, id)) return place.location;
    }
    return .none;
}

/// Whether any argument on noctty's command line wrote `id` for `key`
/// (`--profile-env=<id>: ...`), or cleared every id (`--profile-env=`), which
/// a process that reads only the config files would not see.
pub fn profileWrittenOnCommandLine(self: *const Config, key: []const u8, id: []const u8) bool {
    for (self._profile_places.items) |place| {
        if (place.location != .cli or !std.mem.eql(u8, place.key, key)) continue;
        if (place.id.len == 0 or std.ascii.eqlIgnoreCase(place.id, id)) return true;
    }
    return false;
}

/// Whether noctty's command line has an `--env=` argument. A process that
/// reads only the config files (an elevated window) would not get it, and a
/// user profile's `%NAME%` reads `env` entries first.
pub fn commandLineSetsEnv(self: *const Config) bool {
    for (self._replay_steps.items) |step| switch (step) {
        .arg => |arg| if (arg.location == .cli and std.mem.startsWith(u8, arg.value, "--env=")) return true,
        else => {},
    };
    return false;
}

/// Record where `arg` (`--<key>=<value>`) was read when it writes an id of a
/// `profile-*` key, or a value of `default-profile`, `profile-order` or
/// `profile-hidden` (recorded under the value itself). A line the parser
/// will refuse writes nothing and is not recorded.
fn recordProfilePlace(self: *Config, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!void {
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
        if (std.mem.eql(u8, key, "profile-env")) try self._profile_places.append(alloc, .{
            .key = "profile-env",
            .id = "",
            .location = try cli.Location.fromIter(iter, alloc),
        });
        return;
    }
    inline for (.{ "default-profile", "profile-order", "profile-hidden" }) |reference_key| {
        if (std.mem.eql(u8, key, reference_key)) {
            try self._profile_places.append(alloc, .{
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
            try self._profile_places.append(alloc, .{
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
fn finalizeCliLaunch(self: *Config) Allocator.Error!void {
    if (self._command_cli) |value| {
        if (try applyCliValue(self, "command", value)) {
            self._command_defaulted = false;
            self._command_from_file = false;
        }
    }
    if (self._initial_command_cli) |value| _ = try applyCliValue(self, "initial-command", value);
    finalizeECommand(self);
}

/// Apply `-e`'s command (`_e_command`) again, over the files read after the
/// command line. A replay with `-e` last (a theme's, a new conditional
/// state's) has already given these values, and this gives them again.
fn finalizeECommand(self: *Config) void {
    const command = self._e_command orelse return;
    self.applyECommand(command);
}

/// The value of `arg` when it is `--<key>=<value>` and the field parse takes
/// it. It is parsed here, into the field, by the same `applyCliValue` the
/// parse that follows uses (and `finalizeCliLaunch` repeats), so the answer is
/// that parse's, with no copy of its rules (a blank value, `direct:`).
fn takenCliValue(self: *Config, comptime key: []const u8, arg: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "--" ++ key ++ "=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    const value = arg[prefix.len..];
    return if (try applyCliValue(self, key, value)) value else null;
}

fn applyCliValue(self: *Config, comptime key: []const u8, value: []const u8) Allocator.Error!bool {
    cli.args.parseIntoField(Config, self._arena.?.allocator(), self, key, value) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return false;
    };
    return true;
}

/// Add a problem `finalize` found, unless the config already has it:
/// `finalize` can run again on a finalized config (a new window's clone of
/// the app config is finalized again with its forwarded arguments).
fn appendFinalizeProblem(self: *Config, diag: cli.Diagnostic) Allocator.Error!void {
    for (self._diagnostics.items()) |have| {
        if (sameDiagnostic(have, diag)) return;
    }
    try self._diagnostics.append(self._arena.?.allocator(), diag);
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
fn finalizeDefaultProfileSetting(self: *Config) Allocator.Error!void {
    if (self._default_profile_cli) |value| {
        self.@"default-profile" = if (value.len == 0) null else value;
    }
    if (self.@"default-profile" == null or self._default_profile != null) return;
    if (self.command == null or self._command_defaulted or !self._command_from_file) return;
    const alloc = self._arena.?.allocator();
    try appendFinalizeProblem(self, .{
        .key = "default-profile",
        .message = "is not used, because a config file sets command; remove the command line to start the profile",
        .location = try profilePlace(self, "default-profile", self.@"default-profile".?).clone(alloc),
    });
}

/// Give a config with no `command` the profile `default-profile` names
/// (`windows_shell.resolveProfileReference`, through `host`): its command,
/// marked automatic as the default it replaces, and the profile itself in
/// `_default_profile`. A value that names nothing that can start is a config
/// problem, and `command` stays unset for the automatic default.
fn applyDefaultProfile(self: *Config, host: anytype) !void {
    if (self.command != null) return;
    const reference = self.@"default-profile" orelse return;
    const alloc = self._arena.?.allocator();
    var user = try windows_shell.UserProfiles.init(alloc, self);
    defer user.deinit();
    // A failed lookup (not memory) is a profile that cannot start, as for
    // the automatic default, which also looks the shells up here.
    const resolved = windows_shell.resolveProfileReference(alloc, reference, user.definitions, host) catch |err| found: {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (err == error.VisualStudioUnavailable) {
            // The value may be right: reported apart from one that names
            // nothing, and the next load (a reload) asks again.
            self._default_profile_failure = .unavailable;
            try appendFinalizeProblem(self, .{
                .key = "default-profile",
                .message = try std.fmt.allocPrintSentinel(
                    alloc,
                    "\"{s}\" could not be looked up: Visual Studio's Setup Configuration did not answer in full, so the automatic default is used until the config is reloaded",
                    .{reference},
                    0,
                ),
                .location = try profilePlace(self, "default-profile", reference).clone(alloc),
            });
            return;
        }
        log.warn("default-profile lookup failed err={}", .{err});
        break :found null;
    };
    const profile = resolved orelse {
        self._default_profile_failure = .not_found;
        try appendFinalizeProblem(self, .{
            .key = "default-profile",
            .message = try std.fmt.allocPrintSentinel(
                alloc,
                "\"{s}\" names no profile that can start here (a profile-command id, a key such as pwsh.exe, wsl:<distribution>, ssh:<alias> or vs:newest:cmd, or a name such as pwsh, git, cmd or wsl), so the automatic default is used",
                .{reference},
                0,
            ),
            .location = try profilePlace(self, "default-profile", reference).clone(alloc),
        });
        return;
    };
    log.info("default shell src=default-profile key={s}", .{profile.key});
    self.command = profile.command;
    self._command_defaulted = true;
    self._default_profile = profile;
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

/// Test adapters: a machine with fixed answers, and a load as `Config.load`
/// makes it.
pub const fixtures = struct {
    /// Fixed lookups for `default-profile` in tests: no PATH search, and
    /// one Visual Studio 18 instead of the machine's.
    pub const Machine = struct {
        visual_studio: windows_shell.VisualStudioProfiles = .newest,
        /// False: Setup Configuration fails, and lists nothing.
        visual_studio_answers: bool = true,

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

        pub fn sshExecutable(_: Machine, _: Allocator) !?[]u8 {
            return null;
        }

        pub fn get(_: Machine, _: Allocator, _: []const u8) Allocator.Error!?[]u8 {
            return null;
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
        try testing.expectEqualStrings("wsl:Ubuntu", cfg.defaultProfileFromFiles().?);
        // And it survives a rebuild for a conditional state (a theme).
        cfg._conditional_set.insert(.theme);
        var replayed = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
        defer replayed.deinit();
        try testing.expectEqualStrings("user:py", replayed.@"default-profile".?);
        try testing.expectEqualStrings("wsl:Ubuntu", replayed.defaultProfileFromFiles().?);
        var copy = try cfg.clone(alloc);
        defer copy.deinit();
        try testing.expectEqualStrings("wsl:Ubuntu", copy.defaultProfileFromFiles().?);
    }
    {
        // An empty one on the command line undoes the files', which still
        // give theirs; an empty file line gives none.
        var cfg = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .argv = &.{"--default-profile="} });
        defer cfg.deinit();
        try testing.expect(cfg.@"default-profile" == null);
        try testing.expect(cfg._default_profile == null);
        try testing.expectEqualStrings("py", cfg.defaultProfileFromFiles().?);
        var cleared = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n", .argv = &.{"--default-profile=pwsh"}, .include = "default-profile =\n" });
        defer cleared.deinit();
        try testing.expect(cleared.defaultProfileFromFiles() == null);
        // With nothing on the command line it is the setting itself.
        var plain = try fixtures.load(alloc, .{ .file = profile ++ "default-profile = py\n" });
        defer plain.deinit();
        try testing.expectEqualStrings("py", plain.defaultProfileFromFiles().?);
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
    try testing.expect(automatic._command_defaulted);
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
