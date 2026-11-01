//! Where a config key's effective value came from: the origin record.
//!
//! It is derived from the config's replay log (`Config._replay_steps`), not
//! kept beside it. The loader appends every argument it applies to that log,
//! in order and with its place: the command line's arguments, each line of the
//! default config files, the files `config-file` names, and the lines of the
//! theme `theme` names (conditional on the light or dark state they were read
//! for). The last step that set a key is where its value came from. Clones and
//! the configs `loadTheme` and `changeConditionalState` rebuild keep the log,
//! so every config the app holds can answer, at the cost of one pass over it.
//!
//! A step counts when it applies now (its conditions match the config's
//! conditional state), when it parsed (the loader left no diagnostic at its
//! place), and when it sets the key: by name, through a compatibility name
//! (`Config.compatibility`), or as one of the keys `-e` implies (an `-e` with
//! a command; `shell-integration` only when `-e` made it `detect`). What the
//! log cannot see: a value written into a config in memory (a Settings draft,
//! or `finalize`'s own choices) leaves no step. Given a default config, `of`
//! tells such a value from the default and calls it `.derived`.
//!
//! Three keys `finalize` sets back to the command line's value over any file
//! read after the command line (an included file): `command`,
//! `initial-command` and `default-profile`. For those the command line's step
//! is the origin whenever the config holds a command-line value for them,
//! which is what `finalize` applies; every config the app holds has been
//! finalized. Two more choices of `finalize` are followed: it puts every
//! `--elevated-profile-env=` it took over `env` (`elevatedEnv`), and it
//! settles `single-instance` and its alias `gtk-single-instance` together
//! (`SingleInstance`).

const std = @import("std");
const builtin = @import("builtin");
const cli_args = @import("../cli/args.zig");
const Location = @import("../cli/diagnostics.zig").Location;
const Config = @import("Config.zig");
const Key = @import("key.zig").Key;

pub const Origin = union(enum) {
    /// No step set the key, and its value is the default's (or no default
    /// config was given to compare with).
    default,

    /// A line of a file. `path` borrows from the config.
    file: File,

    /// The command line: the argument's index, as diagnostics count it.
    cli: usize,

    /// No step set the key, but its value is not the default's: something
    /// gave it a value after the layers were read.
    derived: Derivation,

    /// A step set the key, but the log has no place for it (an argument
    /// added without a location).
    unplaced,

    pub const File = struct {
        path: []const u8,
        /// 1-based, as diagnostics print it.
        line: usize,
        kind: FileKind,
    };
};

pub const FileKind = enum {
    /// A file the loader reads on its own: the default config files.
    config,
    /// A file named by `config-file`, in a file or on the command line.
    included,
    /// The file `theme` names, read for the current light or dark state.
    theme,
};

/// What gave a value no step set. More kinds belong here as the code that
/// makes such values learns to say so (a launch layer's recovery or default
/// profile, say); until then they are all `.automatic`.
pub const Derivation = enum {
    /// Code that wrote the config after it was read: `Config.finalize`,
    /// for one.
    automatic,
};

/// Where `key`'s effective value in `config` came from. `defaults` is a
/// default config, finalized as `config` was, to tell a value something gave
/// the key from the default; without it such a value reads as `.default`. A
/// returned path borrows from `config`.
///
/// A step loaded through an iterator with no `location` method has no place
/// (`.none`), so a problem the loader noted for it cannot be matched to it:
/// such a step counts as having set the key even when the loader refused
/// it, and the origin is `.unplaced`. Matching the problem by key alone
/// would also drop a later step of that key that was taken. No config the app
/// reads origins from is loaded that way: the command line, the config files
/// and a replay all give places. The one such iterator, for the arguments a
/// running instance is forwarded for a new window
/// (`ipc_server.ForwardedArgIterator`), loads that window's own config, which
/// nothing asks for an origin.
pub fn of(config: *const Config, key: Key, defaults: ?*const Config) Origin {
    return scan(config, key, defaults, false);
}

/// Where the config files' value of `key` came from: as `of`, counting only
/// lines of files (the command line's arguments, and any step the log has no
/// place for, are left out). For a value the files give but the command line
/// overrides in this process, which is the value Settings shows for
/// `default-profile` (`Config.defaultProfileFromFiles`). `.default` when no
/// file set the key.
pub fn ofFiles(config: *const Config, key: Key) Origin {
    return scan(config, key, null, true);
}

fn scan(config: *const Config, key: Key, defaults: ?*const Config, comptime files_only: bool) Origin {
    var last: ?Origin = null;
    // The last command-line step that set the key (`restoredFromCli`).
    var last_cli: ?Origin = null;
    // `finalize` settles these two keys together (`SingleInstance`).
    const single_instance = key == .@"single-instance" or key == .@"gtk-single-instance";
    var fold: SingleInstance = .{};
    // The last `--elevated-profile-env=` the loader took (`elevatedEnv`).
    var elevated: ?Origin = null;
    // Whether an `-e` with a command set the key.
    var by_e = false;
    const steps = config._replay_steps.items;
    for (steps, 0..) |step, i| switch (step) {
        .arg => |arg| if (!files_only or arg.location == .file) {
            if (stepSets(config, arg.value, arg.location, key)) {
                last = place(config, arg.location, false);
                if (arg.location == .cli) last_cli = last;
            }
            if (single_instance) fold.see(config, arg.value, arg.location, false);
            if (key == .env and elevatedEnv(arg.value, arg.location)) elevated = place(config, arg.location, false);
        },
        .conditional_arg => |arg| {
            var theme = false;
            const applies = for (arg.conditions) |cond| {
                if (cond.key == .theme) theme = true;
                if (!config._conditional_state.match(cond)) break false;
            } else true;
            if (applies and (!files_only or arg.location == .file)) {
                if (stepSets(config, arg.arg, arg.location, key)) last = place(config, arg.location, theme);
                if (single_instance) fold.see(config, arg.arg, arg.location, theme);
            }
        },
        // The arguments after `-e` are its command's, not settings. An `-e`
        // with no command after it was refused (the loader noted "missing
        // command"), and set none of the keys it implies.
        .@"-e" => |location| {
            const has_command = i + 1 < steps.len and steps[i + 1] == .arg;
            if (!files_only and has_command and setByE(config, key)) {
                last = place(config, location, false);
                by_e = true;
            }
            break;
        },
        .expand, .diagnostic => {},
    };
    if (!files_only) if (last_cli) |found| if (restoredFromCli(config, key)) return found;
    // `finalize` puts these over `env` once every file has been read.
    if (elevated) |found| return found;
    if (single_instance and !by_e) if (fold.decided()) |found| return found;
    if (last) |found| return found;
    const reference = defaults orelse return .default;
    return switch (key) {
        inline else => |comptime_key| if (config.changed(reference, comptime_key)) .{ .derived = .automatic } else .default,
    };
}

/// Whether `finalize` sets `key` back to a value the command line gave it, over
/// what a file read after the command line set (`Config.finalizeCliLaunch`, and
/// the `default-profile` the command line names for this process).
fn restoredFromCli(config: *const Config, key: Key) bool {
    return switch (key) {
        .command => config._command_cli != null,
        .@"initial-command" => config._initial_command_cli != null,
        .@"default-profile" => config._default_profile_cli != null,
        else => false,
    };
}

/// Whether the argument `text`, applied at `location`, set `key`.
fn stepSets(config: *const Config, text: []const u8, location: Location, key: Key) bool {
    if (!std.mem.startsWith(u8, text, "--")) return false;
    const body = text[2..];
    const eq = std.mem.indexOfScalar(u8, body, '=');
    const name = body[0 .. eq orelse body.len];
    const value: ?[]const u8 = if (eq) |at| body[at + 1 ..] else null;
    if (!setsKey(name, value, key)) return false;
    // A key whose value is any text cannot refuse one, so a problem noted at
    // its line is about what the value names (`finalize` checks
    // `default-profile`, `profile-order` and `profile-hidden`), and the line
    // set it all the same.
    if (value != null and takesAnyText(key)) return true;
    // A line that did not parse set nothing; the loader noted it there.
    if (location != .none) for (config._diagnostics.list.items) |diag| {
        if (std.mem.eql(u8, diag.key, name) and samePlace(diag.location, location)) return false;
    };
    return true;
}

/// Whether `key`'s field takes any text it is given: a string, or a list of
/// strings.
fn takesAnyText(key: Key) bool {
    return switch (key) {
        inline else => |k| comptime anyText: {
            const T = @FieldType(Config, @tagName(k));
            const U = switch (@typeInfo(T)) {
                .optional => |optional| optional.child,
                else => T,
            };
            break :anyText U == [:0]const u8 or U == []const u8 or U == Config.RepeatableString;
        },
    };
}

/// Whether an argument named `name` with `value` sets `key`, compatibility
/// names included.
fn setsKey(name: []const u8, value: ?[]const u8, key: Key) bool {
    for (compatibility) |entry| if (std.mem.eql(u8, entry.name, name)) {
        if (entry.applies(value)) return std.mem.indexOfScalar(Key, entry.keys, key) != null;
        break;
    };
    return std.mem.eql(u8, name, @tagName(key));
}

/// The keys `Config.compatibility`'s handlers set, and when. A handler runs
/// only when the field's own parser refuses the argument, so a name that is
/// also a field (`gtk-tabs-location`) sets the field for any other value.
const Compatibility = struct {
    name: []const u8,
    keys: []const Key,
    when: union(enum) { always, value: []const u8, truthy },

    fn applies(self: Compatibility, value: ?[]const u8) bool {
        return switch (self.when) {
            .always => true,
            .value => |wanted| std.mem.eql(u8, value orelse "", wanted),
            // As the handlers read it; a value they refuse leaves a diagnostic.
            .truthy => cli_args.parseBool(value orelse "t") catch false,
        };
    }
};

const compatibility = [_]Compatibility{
    .{ .name = "background-blur-radius", .keys = &.{.@"background-blur"}, .when = .always },
    .{ .name = "adw-toolbar-style", .keys = &.{.@"gtk-toolbar-style"}, .when = .always },
    .{ .name = "gtk-tabs-location", .keys = &.{.@"window-show-tab-bar"}, .when = .{ .value = "hidden" } },
    .{ .name = "gtk-single-instance", .keys = &.{ .@"single-instance", .@"gtk-single-instance" }, .when = .{ .value = "desktop" } },
    .{ .name = "cursor-invert-fg-bg", .keys = &.{ .@"cursor-color", .@"cursor-text" }, .when = .truthy },
    .{ .name = "selection-invert-fg-bg", .keys = &.{ .@"selection-foreground", .@"selection-background" }, .when = .truthy },
    .{ .name = "bold-is-bright", .keys = &.{.@"bold-color"}, .when = .truthy },
};

/// Whether an `-e` with a command set `key` (`Config.applyECommand`): the
/// keys it always sets, and `shell-integration` unless that is `none`, which
/// `-e` leaves as it is. `finalize` applies `-e` again over every file, so
/// the value in `config` is the one `-e` left.
fn setByE(config: *const Config, key: Key) bool {
    if (key == .@"shell-integration") return config.@"shell-integration" != .none;
    return impliedByE(key);
}

/// What `Config.finalize` reads to settle `single-instance` and its GTK alias
/// `gtk-single-instance` together. It takes `single-instance` unless that is
/// `detect`, then the alias unless that is `detect`, works out a `detect`
/// that is left, and gives the alias the result. So both keys have the
/// origin of the step that decided: the last step that set `single-instance`
/// to a value other than `detect`, else the last step that set the alias to
/// one. An accepted `-e` sets both after every file (`Config.applyECommand`)
/// and is theirs. When both are `detect`, each key's own last step is its
/// origin, as for any other key: a `gtk-single-instance = desktop` line, which
/// sets both to `detect`, names both.
const SingleInstance = struct {
    single: ?Set = null,
    alias: ?Set = null,

    const Set = struct { origin: Origin, detect: bool };

    fn see(self: *SingleInstance, config: *const Config, text: []const u8, location: Location, theme: bool) void {
        if (stepSets(config, text, location, .@"single-instance"))
            self.single = .{ .origin = place(config, location, theme), .detect = setsDetect(text) };
        if (stepSets(config, text, location, .@"gtk-single-instance"))
            self.alias = .{ .origin = place(config, location, theme), .detect = setsDetect(text) };
    }

    /// The step whose value both keys hold, or null when `finalize` worked it
    /// out from `detect`.
    fn decided(self: SingleInstance) ?Origin {
        if (self.single) |set| if (!set.detect) return set.origin;
        if (self.alias) |set| if (!set.detect) return set.origin;
        return null;
    }
};

/// Whether the argument `text`, which set `single-instance` or
/// `gtk-single-instance`, left it `detect`: an empty value resets it to that
/// default, and `desktop`, the alias's compatibility value, sets both keys to
/// it.
fn setsDetect(text: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return true;
    const value = text[eq + 1 ..];
    const Value = Config.GtkSingleInstance;
    const set: Value = if (value.len == 0) Value.default else std.meta.stringToEnum(Value, value) orelse .detect;
    return set == .detect;
}

/// Whether the argument `text`, applied at `location`, is an
/// `--elevated-profile-env=NAME=VALUE` the loader took
/// (`Config.consumeManuallyHook`): not a file's line, and with a name before
/// the `=`. `finalize` puts every one it took over `env` once every file has
/// been read, so the last is where `env`'s value came from, over a file read
/// after the command line. The words of `-e`'s command are not arguments,
/// and `scan` stops before them.
fn elevatedEnv(text: []const u8, location: Location) bool {
    if (builtin.os.tag != .windows) return false;
    const prefix = "--elevated-profile-env=";
    if (location == .file or !std.mem.startsWith(u8, text, prefix)) return false;
    const eq = std.mem.indexOfScalar(u8, text[prefix.len..], '=') orelse return false;
    return eq > 0;
}

/// The keys `-e` always sets (see `initial-command`'s documentation).
fn impliedByE(key: Key) bool {
    return switch (key) {
        .@"initial-command",
        .@"single-instance",
        .@"gtk-single-instance",
        .@"quit-after-last-window-closed",
        .@"quit-after-last-window-closed-delay",
        => true,
        else => false,
    };
}

fn place(config: *const Config, location: Location, theme: bool) Origin {
    return switch (location) {
        .none => .unplaced,
        .cli => |index| .{ .cli = index },
        .file => |file| .{ .file = .{
            .path = file.path,
            .line = file.line,
            .kind = if (theme) .theme else if (included(config, file.path)) .included else .config,
        } },
    };
}

/// Whether `path` is one of the files `config-file` names.
fn included(config: *const Config, path: []const u8) bool {
    for (config.@"config-file".value.items) |entry| {
        const named = switch (entry) {
            .optional, .required => |named| named,
        };
        if (std.mem.eql(u8, named, path)) return true;
    }
    return false;
}

fn samePlace(a: Location, b: Location) bool {
    return switch (a) {
        .none => b == .none,
        .cli => |index| b == .cli and b.cli == index,
        .file => |file| b == .file and b.file.line == file.line and std.mem.eql(u8, b.file.path, file.path),
    };
}

test "origin: every compatibility name is mapped to the keys its handler sets" {
    for (Config.compatibility.keys()) |name| {
        const known = for (compatibility) |entry| {
            if (std.mem.eql(u8, entry.name, name)) break true;
        } else false;
        errdefer std.debug.print("origin: no mapping for compatibility name {s}\n", .{name});
        try std.testing.expect(known);
    }
}

/// Command-line arguments with the places `Config.loadCliArgs` gives them.
const TestArgs = struct {
    list: []const []const u8,
    index: usize = 0,

    pub fn next(self: *TestArgs) ?[]const u8 {
        if (self.index >= self.list.len) return null;
        defer self.index += 1;
        return self.list[self.index];
    }

    /// The index of the argument `next` returned last.
    pub fn location(self: *const TestArgs, _: std.mem.Allocator) std.mem.Allocator.Error!?Location {
        return .{ .cli = self.index - 1 };
    }
};

fn expectFile(origin: Origin, path: []const u8, line: usize, kind: FileKind) !void {
    errdefer std.debug.print("origin: {any}\n", .{origin});
    try std.testing.expect(origin == .file);
    try std.testing.expectEqualStrings(path, origin.file.path);
    try std.testing.expectEqual(line, origin.file.line);
    try std.testing.expectEqual(kind, origin.file.kind);
}

test "origin: the last line that parsed, an included file, the command line, compatibility names and the default" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "included.conf", .data = "\nfont-size = 15\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" ++
        "font-size = 13\n" ++
        "font-size = abc\n" ++
        "config-file = included.conf\n" ++
        "scrollback-limit = 5\n" ++
        "bold-is-bright = true\n" ++
        "cursor-invert-fg-bg = false\n" ++
        "gtk-tabs-location = hidden\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "included.conf");
    defer alloc.free(included_path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    var args: TestArgs = .{ .list = &.{"--window-padding-balance=true"} };
    try cfg.loadIter(alloc, &args);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();

    // The included file is read after the file that names it, and wins.
    try std.testing.expectEqual(@as(f32, 15), cfg.@"font-size");
    try expectFile(of(&cfg, .@"font-size", null), included_path, 2, .included);
    try expectFile(of(&cfg, .@"scrollback-limit", null), path, 5, .config);
    try expectFile(of(&cfg, .@"config-file", null), path, 4, .config);
    // Compatibility names set the keys their handlers set, and only those.
    try expectFile(of(&cfg, .@"bold-color", null), path, 6, .config);
    try std.testing.expect(of(&cfg, .@"cursor-color", null) == .default);
    try expectFile(of(&cfg, .@"window-show-tab-bar", null), path, 8, .config);
    try std.testing.expect(of(&cfg, .@"gtk-tabs-location", null) == .default);
    try std.testing.expect(of(&cfg, .@"window-padding-balance", null) == .cli);
    try std.testing.expect(of(&cfg, .@"font-family", null) == .default);

    // A clone keeps the log, and with it every origin.
    var copy = try cfg.clone(alloc);
    defer copy.deinit();
    try expectFile(of(&copy, .@"font-size", null), included_path, 2, .included);
}

test "origin: a line that did not parse is not where the value came from" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 13\nfont-size = abc\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    try cfg.finalize();
    try std.testing.expectEqual(@as(f32, 13), cfg.@"font-size");
    try expectFile(of(&cfg, .@"font-size", null), path, 1, .config);
}

test "origin: a theme's lines, and the config's own lines over them" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\nforeground = #202020\n" });
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    const text = try std.fmt.allocPrint(alloc, "theme = {s}\nforeground = #303030\n", .{theme_path});
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    try cfg.finalize();
    try expectFile(of(&cfg, .background, null), theme_path, 1, .theme);
    try expectFile(of(&cfg, .foreground, null), path, 2, .config);
    try expectFile(of(&cfg, .theme, null), path, 1, .config);
    // The theme's lines were read for the light state; in the other one
    // they do not apply.
    try std.testing.expectEqual(@as(@TypeOf(cfg._conditional_state.theme), .light), cfg._conditional_state.theme);
    cfg._conditional_state.theme = .dark;
    try std.testing.expect(of(&cfg, .background, null) == .default);
    try expectFile(of(&cfg, .foreground, null), path, 2, .config);
}

test "origin: -e sets the keys it implies, and its command's words set nothing" {
    const alloc = std.testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var args: TestArgs = .{ .list = &.{ "--font-size=11", "-e", "cmd.exe", "--font-size=99" } };
    try cfg.loadIter(alloc, &args);
    try cfg.finalize();
    try std.testing.expectEqual(@as(f32, 11), cfg.@"font-size");
    try std.testing.expectEqual(Origin{ .cli = 0 }, of(&cfg, .@"font-size", null));
    try std.testing.expectEqual(Origin{ .cli = 1 }, of(&cfg, .@"initial-command", null));
    try std.testing.expectEqual(Origin{ .cli = 1 }, of(&cfg, .@"quit-after-last-window-closed", null));
    try std.testing.expect(of(&cfg, .@"scrollback-limit", null) == .default);
}

test "origin: a command-line value finalize restores over an included file is the command line's" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "command = pwsh.exe\ninitial-command = pwsh.exe\ndefault-profile = pwsh\nfont-size = 15\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "config-file = x.conf\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "x.conf");
    defer alloc.free(included_path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    var args: TestArgs = .{ .list = &.{ "--command=cmd.exe", "--initial-command=cmd.exe", "--default-profile=cmd", "--font-size=11" } };
    try cfg.loadIter(alloc, &args);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();

    // The included file is read after the command line; `finalize` puts the
    // command line's values back for these three, and not for the others.
    try std.testing.expectEqualStrings("cmd.exe", cfg.command.?.shell);
    try std.testing.expectEqual(Origin{ .cli = 0 }, of(&cfg, .command, null));
    try std.testing.expectEqualStrings("cmd.exe", cfg.@"initial-command".?.shell);
    try std.testing.expectEqual(Origin{ .cli = 1 }, of(&cfg, .@"initial-command", null));
    try std.testing.expectEqualStrings("cmd", cfg.@"default-profile".?);
    try std.testing.expectEqual(Origin{ .cli = 2 }, of(&cfg, .@"default-profile", null));
    // The files' own value, which Settings shows, came from the included file;
    // a key no file sets has no file origin.
    try expectFile(ofFiles(&cfg, .@"default-profile"), included_path, 3, .included);
    try std.testing.expect(ofFiles(&cfg, .@"font-family") == .default);
    try std.testing.expectEqual(@as(f32, 15), cfg.@"font-size");
    try expectFile(of(&cfg, .@"font-size", null), included_path, 4, .included);
}

test "origin: a line finalize reports a problem at still set the key" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "\ndefault-profile = pwsh\nprofile-order = no profile at all\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "command = cmd.exe\nconfig-file = x.conf\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "x.conf");
    defer alloc.free(included_path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();

    // A config file's `command` leaves `default-profile` unused, and
    // `profile-order` names nothing: `finalize` says so at their lines.
    var noted: usize = 0;
    for (cfg._diagnostics.list.items) |diag| {
        if (std.mem.eql(u8, diag.key, "default-profile") or std.mem.eql(u8, diag.key, "profile-order")) noted += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), noted);
    try std.testing.expectEqualStrings("pwsh", cfg.@"default-profile".?);
    try expectFile(of(&cfg, .@"default-profile", null), included_path, 2, .included);
    try expectFile(of(&cfg, .@"profile-order", null), included_path, 3, .included);
}

test "origin: rejected -e does not change origins" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "quit-after-last-window-closed = false\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    var args: TestArgs = .{ .list = &.{"-e"} };
    try cfg.loadIter(alloc, &args);
    try cfg.finalize();
    // `-e` with no command is refused: the file's value stays, and so does
    // its origin.
    try std.testing.expect(!cfg._diagnostics.empty());
    try std.testing.expect(!cfg.@"quit-after-last-window-closed");
    try expectFile(of(&cfg, .@"quit-after-last-window-closed", null), path, 1, .config);
    try std.testing.expect(of(&cfg, .@"initial-command", null) == .default);
}

/// Command-line arguments with no places: `cli.Location.fromIter` gives
/// `.none` for an iterator without a `location` method.
const PlainArgs = struct {
    list: []const []const u8,
    index: usize = 0,

    pub fn next(self: *PlainArgs) ?[]const u8 {
        if (self.index >= self.list.len) return null;
        defer self.index += 1;
        return self.list[self.index];
    }
};

test "origin: ofFiles counts only lines of files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 13\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);

    // A step with no place after a file's line: the file's line stays the
    // files' origin, though `of` says the value came from somewhere unplaced.
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    var args: PlainArgs = .{ .list = &.{"--font-size=15"} };
    try cfg.loadIter(alloc, &args);
    try cfg.finalize();
    try std.testing.expectEqual(@as(f32, 15), cfg.@"font-size");
    try std.testing.expect(of(&cfg, .@"font-size", null) == .unplaced);
    try expectFile(ofFiles(&cfg, .@"font-size"), path, 1, .config);

    // With no file line, no file is the origin.
    var bare = try Config.default(alloc);
    defer bare.deinit();
    var more: PlainArgs = .{ .list = &.{"--font-size=15"} };
    try bare.loadIter(alloc, &more);
    try bare.finalize();
    try std.testing.expect(ofFiles(&bare, .@"font-size") == .default);
}

/// Load `path` (holding `text`), the command line `args`, and the files
/// `config-file` names, and finalize, as the app does.
fn loadWithArgs(alloc: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, text: []const u8, args: []const []const u8) !Config {
    try dir.writeFile(.{ .sub_path = "config", .data = text });
    var cfg = try Config.default(alloc);
    errdefer cfg.deinit();
    try cfg.loadFile(alloc, path);
    var it: TestArgs = .{ .list = args };
    try cfg.loadIter(alloc, &it);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();
    return cfg;
}

/// `command` when it is a shell command, or a test failure (not a panic) for
/// none or a direct one.
fn shellCommand(command: ?Config.Command) ![:0]const u8 {
    const value = command orelse return error.TestUnexpectedResult;
    if (value != .shell) return error.TestUnexpectedResult;
    return value.shell;
}

/// That `cfg` holds `-e cmd.exe`'s values, and names the `-e` at `index` as
/// where they came from.
fn expectE(cfg: *const Config, index: usize) !void {
    const initial = cfg.@"initial-command" orelse return error.TestExpectedEqual;
    try std.testing.expect(initial == .direct);
    try std.testing.expectEqualStrings("cmd.exe", initial.direct[0]);
    try std.testing.expect(cfg.@"quit-after-last-window-closed");
    try std.testing.expectEqual(Origin{ .cli = index }, of(cfg, .@"initial-command", null));
    try std.testing.expectEqual(Origin{ .cli = index }, of(cfg, .@"quit-after-last-window-closed", null));
}

test "origin: -e wins over an included file with or without a theme, and is named as the command line's" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "quit-after-last-window-closed = false\ninitial-command = pwsh.exe\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "x.conf");
    defer alloc.free(included_path);
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    const themed = try std.fmt.allocPrint(alloc, "config-file = x.conf\ntheme = {s}\n", .{theme_path});
    defer alloc.free(themed);
    const config_file_arg = try std.fmt.allocPrint(alloc, "--config-file={s}", .{included_path});
    defer alloc.free(config_file_arg);

    // No theme: nothing replays the log, and before `finalize` applied `-e`
    // again the include's values won here.
    {
        var cfg = try loadWithArgs(alloc, tmp.dir, path, "config-file = x.conf\n", &.{ "-e", "cmd.exe" });
        defer cfg.deinit();
        try expectE(&cfg, 0);
    }
    // A theme replays the log with `-e` last, so `-e` won here before the
    // loader change too: the rule is the same with or without a theme, and
    // an origin that let includes win would fail here.
    {
        var cfg = try loadWithArgs(alloc, tmp.dir, path, themed, &.{ "-e", "cmd.exe" });
        defer cfg.deinit();
        try expectE(&cfg, 0);
    }
    // The include named on the command line, as a reload with
    // `--config-file` reads it.
    {
        var cfg = try loadWithArgs(alloc, tmp.dir, path, "font-size = 12\n", &.{ config_file_arg, "-e", "cmd.exe" });
        defer cfg.deinit();
        try expectE(&cfg, 1);
    }
    // An `-e` refused for want of a command: the include's values and
    // origins stand.
    {
        var cfg = try loadWithArgs(alloc, tmp.dir, path, "config-file = x.conf\n", &.{"-e"});
        defer cfg.deinit();
        try std.testing.expect(!cfg.@"quit-after-last-window-closed");
        try std.testing.expectEqualStrings("pwsh.exe", try shellCommand(cfg.@"initial-command"));
        try expectFile(of(&cfg, .@"quit-after-last-window-closed", null), included_path, 1, .included);
        try expectFile(of(&cfg, .@"initial-command", null), included_path, 2, .included);
    }
}

test "origin: a refused -e leaves an accepted --initial-command= the origin, with or without a theme" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "initial-command = pwsh.exe\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    const themed = try std.fmt.allocPrint(alloc, "config-file = x.conf\ntheme = {s}\n", .{theme_path});
    defer alloc.free(themed);

    for ([_][]const u8{ "config-file = x.conf\n", themed }) |text| {
        var cfg = try loadWithArgs(alloc, tmp.dir, path, text, &.{ "--initial-command=cmd.exe", "-e" });
        defer cfg.deinit();
        try std.testing.expectEqualStrings("cmd.exe", try shellCommand(cfg.@"initial-command"));
        try std.testing.expectEqual(Origin{ .cli = 0 }, of(&cfg, .@"initial-command", null));
    }
}

test "origin: -e's shell-integration is -e's unless it is none, with or without a theme" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    const themed = try std.fmt.allocPrint(alloc, "config-file = x.conf\ntheme = {s}\n", .{theme_path});
    defer alloc.free(themed);

    const Case = struct { include: []const u8, want: Config.ShellIntegration, by_e: bool };
    for ([_]Case{
        // `-e` turns `fish` into `detect`, and is where the value came from.
        .{ .include = "shell-integration = fish\n", .want = .detect, .by_e = true },
        // `-e` leaves `none`, and the include's line stands.
        .{ .include = "shell-integration = none\n", .want = .none, .by_e = false },
    }) |case| {
        try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = case.include });
        const x_path = try tmp.dir.realpathAlloc(alloc, "x.conf");
        defer alloc.free(x_path);
        for ([_][]const u8{ "config-file = x.conf\n", themed }) |text| {
            errdefer std.debug.print("origin: -e shell-integration case {s}", .{case.include});
            var cfg = try loadWithArgs(alloc, tmp.dir, path, text, &.{ "-e", "cmd.exe" });
            defer cfg.deinit();
            try std.testing.expectEqual(case.want, cfg.@"shell-integration");
            if (case.by_e)
                try std.testing.expectEqual(Origin{ .cli = 0 }, of(&cfg, .@"shell-integration", null))
            else
                try expectFile(of(&cfg, .@"shell-integration", null), x_path, 1, .included);
        }
    }
}

test "origin: after a light/dark flip, -e's values and their origin still agree" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "quit-after-last-window-closed = false\ninitial-command = pwsh.exe\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);

    var cfg = try loadWithArgs(alloc, tmp.dir, path, "config-file = x.conf\n", &.{ "-e", "cmd.exe" });
    defer cfg.deinit();
    try expectE(&cfg, 0);
    // A new conditional state replays the log into a new config and
    // finalizes it.
    cfg._conditional_set.insert(.theme);
    var flipped = (try cfg.changeConditionalState(.{ .theme = .dark })) orelse return error.TestUnexpectedResult;
    defer flipped.deinit();
    try expectE(&flipped, 0);
}

test "origin: -e and the command-line settings around it" {
    const alloc = std.testing.allocator;
    const Case = struct {
        args: []const []const u8,
        /// `initial-command`'s words, or null for none.
        words: ?[]const []const u8,
        initial: Origin,
        /// `command`, when the case sets it.
        command: ?[]const u8 = null,
    };
    for ([_]Case{
        // An empty word is still a word: `-e` is taken.
        .{ .args = &.{ "-e", "" }, .words = &.{""}, .initial = .{ .cli = 0 } },
        // Nothing after `-e`: it is refused.
        .{ .args = &.{"-e"}, .words = null, .initial = .default },
        // Everything after `-e` is its command's, a flag and a second `-e`
        // included.
        .{ .args = &.{ "-e", "cmd.exe", "--font-size=99" }, .words = &.{ "cmd.exe", "--font-size=99" }, .initial = .{ .cli = 0 } },
        .{ .args = &.{ "-e", "-e", "cmd.exe" }, .words = &.{ "-e", "cmd.exe" }, .initial = .{ .cli = 0 } },
        .{ .args = &.{ "-e", "foo.exe", "--initial-command=x.exe" }, .words = &.{ "foo.exe", "--initial-command=x.exe" }, .initial = .{ .cli = 0 } },
        // `-e` after `--initial-command=` wins over it.
        .{ .args = &.{ "--initial-command=x.exe", "-e", "foo.exe" }, .words = &.{"foo.exe"}, .initial = .{ .cli = 1 } },
        // `--command=` and `-e` set different keys, and both stand.
        .{ .args = &.{ "--command=vim.exe", "-e", "foo.exe" }, .words = &.{"foo.exe"}, .initial = .{ .cli = 1 }, .command = "vim.exe" },
    }) |case| {
        errdefer std.debug.print("origin: -e case {d} argument(s), first {s}\n", .{ case.args.len, case.args[0] });
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var args: TestArgs = .{ .list = case.args };
        try cfg.loadIter(alloc, &args);
        try cfg.finalize();
        if (case.words) |words| {
            const initial = cfg.@"initial-command" orelse return error.TestExpectedEqual;
            try std.testing.expect(initial == .direct);
            try std.testing.expectEqual(words.len, initial.direct.len);
            for (words, initial.direct) |want, have| try std.testing.expectEqualStrings(want, have);
        } else try std.testing.expect(cfg.@"initial-command" == null);
        try std.testing.expectEqual(case.initial, of(&cfg, .@"initial-command", null));
        // A setting among `-e`'s words sets nothing.
        try std.testing.expect(cfg.@"font-size" != 99);
        try std.testing.expect(of(&cfg, .@"font-size", null) == .default);
        if (case.command) |command| {
            try std.testing.expectEqualStrings(command, try shellCommand(cfg.command));
            try std.testing.expectEqual(Origin{ .cli = 0 }, of(&cfg, .command, null));
        }
    }
}

test "origin: a value no step set is derived when it differs from the default" {
    const alloc = std.testing.allocator;
    var defaults = try Config.default(alloc);
    defer defaults.deinit();
    try defaults.finalize();
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.finalize();
    try std.testing.expect(of(&cfg, .@"font-size", &defaults) == .default);
    cfg.@"font-size" = defaults.@"font-size" + 4;
    try std.testing.expectEqual(Origin{ .derived = .automatic }, of(&cfg, .@"font-size", &defaults));
    // Without a default config to compare with, it reads as the default.
    try std.testing.expect(of(&cfg, .@"font-size", null) == .default);
}

test "origin: single-instance and its alias gtk-single-instance name the step finalize took both values from, with or without a theme" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    const theme_line = try std.fmt.allocPrint(alloc, "theme = {s}\n", .{theme_path});
    defer alloc.free(theme_line);
    var defaults = try Config.default(alloc);
    defer defaults.deinit();
    try defaults.finalize();

    const Where = union(enum) { line: usize, cli: usize, default };
    const Case = struct {
        text: []const u8,
        args: []const []const u8 = &.{},
        /// The value both keys hold, or null for one `finalize` worked out
        /// from `detect`.
        value: ?Config.GtkSingleInstance,
        /// Where both keys' value came from.
        where: Where,
    };
    for ([_]Case{
        // Only the alias: `finalize` copies it into `single-instance`.
        .{ .text = "gtk-single-instance = false\n", .value = .false, .where = .{ .line = 1 } },
        // Both: `single-instance` wins, and is copied into the alias.
        .{ .text = "single-instance = true\ngtk-single-instance = false\n", .value = .true, .where = .{ .line = 1 } },
        // `single-instance` left `detect`: the alias decides.
        .{ .text = "single-instance = detect\ngtk-single-instance = false\n", .value = .false, .where = .{ .line = 2 } },
        // Neither: worked out, as before.
        .{ .text = "font-size = 12\n", .value = null, .where = .default },
        // An accepted `-e` sets both, over every file.
        .{ .text = "gtk-single-instance = true\n", .args = &.{ "-e", "cmd.exe" }, .value = .false, .where = .{ .cli = 0 } },
        // `desktop` sets both to `detect`, over an earlier `single-instance`,
        // and its line is named for both.
        .{ .text = "single-instance = true\ngtk-single-instance = desktop\n", .value = null, .where = .{ .line = 2 } },
    }, 0..) |case, n| {
        for ([_]bool{ false, true }) |themed| {
            errdefer std.debug.print("origin: single-instance case {d}, theme {}\n", .{ n, themed });
            const text = try std.mem.concat(alloc, u8, &.{ case.text, if (themed) theme_line else "" });
            defer alloc.free(text);
            var cfg = try loadWithArgs(alloc, tmp.dir, path, text, case.args);
            defer cfg.deinit();
            if (case.value) |want| try std.testing.expectEqual(want, cfg.@"single-instance");
            try std.testing.expectEqual(cfg.@"single-instance", cfg.@"gtk-single-instance");
            for ([_]Key{ .@"single-instance", .@"gtk-single-instance" }) |key| {
                errdefer std.debug.print("origin: of {s}\n", .{@tagName(key)});
                const found = of(&cfg, key, &defaults);
                switch (case.where) {
                    .line => |line| try expectFile(found, path, line, .config),
                    .cli => |index| try std.testing.expectEqual(Origin{ .cli = index }, found),
                    .default => try std.testing.expect(found == .default),
                }
            }
        }
    }
}

test "origin: an --elevated-profile-env= the loader took is env's origin over every file, with or without a theme" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The included file is read after the command line; its
    // `elevated-profile-env` line is refused, as any file's.
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "env = MODE=include\nelevated-profile-env = MODE=file\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "x.conf");
    defer alloc.free(included_path);
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    const plain = "env = MODE=config\nconfig-file = x.conf\n";
    const themed = try std.fmt.allocPrint(alloc, plain ++ "theme = {s}\n", .{theme_path});
    defer alloc.free(themed);

    const Case = struct {
        args: []const []const u8,
        mode: []const u8,
        /// The command-line argument env's value came from, or null for the
        /// included file's line.
        cli: ?usize,
    };
    for ([_]Case{
        .{ .args = &.{"--elevated-profile-env=MODE=cli"}, .mode = "cli", .cli = 0 },
        // `finalize` puts it over an `--env=` after it too.
        .{ .args = &.{ "--elevated-profile-env=MODE=cli", "--env=OTHER=1" }, .mode = "cli", .cli = 0 },
        // The last one taken is named.
        .{ .args = &.{ "--font-size=12", "--elevated-profile-env=A=1", "--elevated-profile-env=MODE=cli" }, .mode = "cli", .cli = 2 },
        // Refused for want of a name: the included file's line stands.
        .{ .args = &.{"--elevated-profile-env=nothing"}, .mode = "include", .cli = null },
        .{ .args = &.{"--elevated-profile-env==x"}, .mode = "include", .cli = null },
        // A word of `-e`'s command sets nothing.
        .{ .args = &.{ "-e", "cmd.exe", "--elevated-profile-env=MODE=cli" }, .mode = "include", .cli = null },
    }, 0..) |case, n| {
        for ([_][]const u8{ plain, themed }) |text| {
            errdefer std.debug.print("origin: elevated-profile-env case {d}, theme {}\n", .{ n, text.len != plain.len });
            var cfg = try loadWithArgs(alloc, tmp.dir, path, text, case.args);
            defer cfg.deinit();
            try std.testing.expectEqualStrings(case.mode, cfg.env.map.get("MODE") orelse return error.TestUnexpectedResult);
            const found = of(&cfg, .env, null);
            if (case.cli) |index|
                try std.testing.expectEqual(Origin{ .cli = index }, found)
            else
                try expectFile(found, included_path, 1, .included);
            // The files' origin leaves the command line out.
            try expectFile(ofFiles(&cfg, .env), included_path, 1, .included);
        }
    }
}

test "origin: a refused argument with no place still counts as set" {
    // The limit `of` documents: the loader's problem for a step with no place
    // cannot be matched to it. No config the app asks for an origin is loaded
    // through such an iterator.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 13\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, path);
    var args: PlainArgs = .{ .list = &.{"--font-size=abc"} };
    try cfg.loadIter(alloc, &args);
    try cfg.finalize();
    try std.testing.expect(!cfg._diagnostics.empty());
    try std.testing.expectEqual(@as(f32, 13), cfg.@"font-size");
    try std.testing.expect(of(&cfg, .@"font-size", null) == .unplaced);
    try expectFile(ofFiles(&cfg, .@"font-size"), path, 1, .config);
}
