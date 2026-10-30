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
//! (`Config.compatibility`), or as one of the keys `-e` implies. What the log
//! cannot see: a value written into a config in memory (a Settings draft, or
//! `finalize`'s own choices) leaves no step. Given a default config, `of` tells
//! such a value from the default and calls it `.derived`.

const std = @import("std");
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
pub fn of(config: *const Config, key: Key, defaults: ?*const Config) Origin {
    var last: ?Origin = null;
    for (config._replay_steps.items) |step| switch (step) {
        .arg => |arg| if (stepSets(config, arg.value, arg.location, key)) {
            last = place(config, arg.location, false);
        },
        .conditional_arg => |arg| {
            var theme = false;
            const applies = for (arg.conditions) |cond| {
                if (cond.key == .theme) theme = true;
                if (!config._conditional_state.match(cond)) break false;
            } else true;
            if (applies and stepSets(config, arg.arg, arg.location, key)) last = place(config, arg.location, theme);
        },
        // The arguments after `-e` are its command's, not settings.
        .@"-e" => |location| {
            if (impliedByE(key)) last = place(config, location, false);
            break;
        },
        .expand, .diagnostic => {},
    };
    if (last) |found| return found;
    const reference = defaults orelse return .default;
    return switch (key) {
        inline else => |comptime_key| if (config.changed(reference, comptime_key)) .{ .derived = .automatic } else .default,
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
    // A line that did not parse set nothing; the loader noted it there.
    if (location != .none) for (config._diagnostics.list.items) |diag| {
        if (std.mem.eql(u8, diag.key, name) and samePlace(diag.location, location)) return false;
    };
    return true;
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

/// The keys `-e` sets (see `command`'s documentation). It also turns a
/// `shell-integration` other than `none` into `detect`; that one keeps the
/// origin of its own line.
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
