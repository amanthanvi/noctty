const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const win32 = @import("../os/windows.zig");
const Command = @import("command.zig").Command;
const windows_shell_types = @import("windows_shell_types.zig");
const windows_ssh_hosts = @import("windows_ssh_hosts.zig");
pub const visual_studio = @import("windows_visual_studio.zig");
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

pub const ProfileKind = windows_shell_types.ProfileKind;
pub const Utf8Console = windows_shell_types.Utf8Console;
pub const VisualStudioProfiles = visual_studio.Mode;

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
    /// Where a launch from the picker or the palette starts. Null is home,
    /// as for every detected profile. Set only for `.user` profiles.
    working_directory: ?WorkingDirectory = null,
    /// The command line `command` was split from and the profile's own
    /// environment entries. Set only for `.user` profiles.
    user: ?UserLaunch = null,
    /// Named by `profile-hidden`: left out of the picker, the palette, the
    /// jump list and the quick slots, but still found by key (restore,
    /// `default-profile`, `new_window_elevated:<key>`, a split's profile).
    /// `arrangeProfiles` puts hidden profiles after every shown one.
    hidden: bool = false,
    /// The first Visual Studio shell of its kind as discovery listed them
    /// (newest instance first): what `vs:newest:cmd` or `vs:newest:pwsh`
    /// names, wherever `profile-order` later moves it (`NewestVisualStudio`).
    newest_visual_studio: bool = false,

    /// Deep copy into `alloc`.
    pub fn clone(self: Profile, alloc: Allocator) Allocator.Error!Profile {
        const key = try alloc.dupe(u8, self.key);
        errdefer alloc.free(key);
        const label = try alloc.dupe(u8, self.label);
        errdefer alloc.free(label);
        const palette_title = if (self.palette_title) |value| try alloc.dupe(u8, value) else null;
        errdefer if (palette_title) |value| alloc.free(value);
        var command = try self.command.clone(alloc);
        errdefer command.deinit(alloc);
        const working_directory: ?WorkingDirectory = if (self.working_directory) |dir| switch (dir) {
            .path => |path| .{ .path = try alloc.dupeZ(u8, path) },
            .home, .inherit => dir,
        } else null;
        errdefer if (working_directory) |dir| switch (dir) {
            .path => |path| alloc.free(path),
            .home, .inherit => {},
        };
        return .{
            .kind = self.kind,
            .key = key,
            .label = label,
            .palette_title = palette_title,
            .command = command,
            .working_directory = working_directory,
            .user = if (self.user) |user| try user.clone(alloc) else null,
            .hidden = self.hidden,
            .newest_visual_studio = self.newest_visual_studio,
        };
    }

    pub fn deinit(self: *Profile, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.label);
        if (self.palette_title) |value| alloc.free(value);
        self.command.deinit(alloc);
        if (self.working_directory) |dir| switch (dir) {
            .path => |path| alloc.free(path),
            .home, .inherit => {},
        };
        if (self.user) |*user| user.deinit(alloc);
    }
};

/// One environment variable a user profile sets (`profile-env`), its value
/// with `%NAME%` already expanded.
pub const EnvEntry = struct {
    key: [:0]const u8,
    value: [:0]const u8,
};

/// `profile-working-directory`, resolved: `inherit` keeps the ordinary
/// new-tab rules, a path is used as given.
pub const WorkingDirectory = union(enum) {
    home,
    inherit,
    path: [:0]const u8,
};

/// What a user profile adds to a launch besides its argv. A surface keeps a
/// copy, so the tabs and splits that inherit its launch get the same.
pub const UserLaunch = struct {
    /// The expanded command line. Exec passes it to CreateProcess unchanged
    /// when the argv it is about to run is exactly this line's split
    /// (`verbatimCommandLine`).
    command_line: [:0]const u8,
    env: []const EnvEntry = &.{},

    pub fn clone(self: UserLaunch, alloc: Allocator) Allocator.Error!UserLaunch {
        const line = try alloc.dupeZ(u8, self.command_line);
        errdefer alloc.free(line);
        const env = try alloc.alloc(EnvEntry, self.env.len);
        var copied: usize = 0;
        errdefer {
            for (env[0..copied]) |entry| {
                alloc.free(entry.key);
                alloc.free(entry.value);
            }
            alloc.free(env);
        }
        for (self.env, env) |src, *dst| {
            const key = try alloc.dupeZ(u8, src.key);
            errdefer alloc.free(key);
            dst.* = .{ .key = key, .value = try alloc.dupeZ(u8, src.value) };
            copied += 1;
        }
        return .{ .command_line = line, .env = env };
    }

    pub fn deinit(self: *UserLaunch, alloc: Allocator) void {
        alloc.free(self.command_line);
        for (self.env) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
        alloc.free(self.env);
        self.* = undefined;
    }
};

/// Put `entries` over `env` (an `env` map), each replacing a variable of the
/// same name in any case, as Windows compares names: a profile `PATH`
/// replaces a global `Path`. An empty value only removes, as `env = KEY=`
/// does. `alloc` is the arena `env` lives in.
pub fn layerEnv(alloc: Allocator, env: anytype, entries: []const EnvEntry) Allocator.Error!void {
    for (entries) |entry| {
        var index: usize = 0;
        while (index < env.map.count()) {
            if (std.ascii.eqlIgnoreCase(env.map.keys()[index], entry.key)) {
                env.map.orderedRemoveAt(index);
            } else index += 1;
        }
        if (entry.value.len == 0) continue;
        try env.map.put(alloc, try alloc.dupeZ(u8, entry.key), try alloc.dupeZ(u8, entry.value));
    }
}

/// The user profiles a config defines, as written (nothing expanded or
/// split yet), copied out of the config so a discovery on another thread
/// owns what it reads. The loader has already refused every line it
/// reports, so each definition has a valid id and a command; removed
/// profiles (`profile-command = <id>:`) are left out with their fields.
pub const UserProfiles = struct {
    arena: std.heap.ArenaAllocator,
    definitions: []const Definition = &.{},
    /// `profile-order` and `profile-hidden`: references (a user profile id,
    /// `user:<id>`, a detected key or a `NOCTTY_WIN32_PROFILE_ORDER` alias)
    /// that `arrangeProfiles` applies to the whole list.
    order: []const []const u8 = &.{},
    hidden: []const []const u8 = &.{},
    /// `visual-studio-profiles`.
    visual_studio: VisualStudioProfiles = .newest,

    pub const Definition = struct {
        id: []const u8,
        name: ?[]const u8 = null,
        command: []const u8,
        working_directory: ?[]const u8 = null,
        env: []const EnvEntry = &.{},
        /// The config's `env` entries, in order: `%NAME%` reads them before
        /// noctty's own environment (`expandProfileText`), so a value sees
        /// the environment the shell would get without this profile.
        global_env: []const EnvEntry = &.{},
    };

    pub fn init(gpa: Allocator, config: anytype) Allocator.Error!UserProfiles {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const global_env = try copyEnvEntries(alloc, config.env);
        const commands = config.@"profile-command".entries.items;
        var definitions: std.ArrayList(Definition) = try .initCapacity(alloc, commands.len);
        for (commands) |entry| {
            if (entry.removed) continue;
            definitions.appendAssumeCapacity(.{
                .id = try alloc.dupe(u8, entry.id),
                .name = if (config.@"profile-name".get(entry.id)) |name| try alloc.dupe(u8, name) else null,
                .command = try alloc.dupe(u8, entry.value),
                .working_directory = if (config.@"profile-working-directory".get(entry.id)) |dir|
                    try alloc.dupe(u8, dir)
                else
                    null,
                .env = if (config.@"profile-env".get(entry.id)) |map| try copyEnvEntries(alloc, map) else &.{},
                .global_env = global_env,
            });
        }
        // Allocate everything before `arena` is copied into the result: a
        // node the copy creates after that is known only to this local and
        // would never be freed.
        const order = try copyStrings(alloc, config.@"profile-order".list.items);
        const hidden = try copyStrings(alloc, config.@"profile-hidden".list.items);
        return .{
            .arena = arena,
            .definitions = definitions.items,
            .order = order,
            .hidden = hidden,
            .visual_studio = config.@"visual-studio-profiles",
        };
    }

    /// The entries of an `env`-style map, in order.
    fn copyEnvEntries(alloc: Allocator, map: anytype) Allocator.Error![]const EnvEntry {
        const out = try alloc.alloc(EnvEntry, map.count());
        var it = map.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            out[i] = .{
                .key = try alloc.dupeZ(u8, kv.key_ptr.*),
                .value = try alloc.dupeZ(u8, kv.value_ptr.*),
            };
        }
        return out;
    }

    fn copyStrings(alloc: Allocator, values: []const [:0]const u8) Allocator.Error![]const []const u8 {
        const out = try alloc.alloc([]const u8, values.len);
        for (values, out) |value, *dst| dst.* = try alloc.dupe(u8, value);
        return out;
    }

    pub fn deinit(self: *UserProfiles) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// noctty's own environment, read by name for `%NAME%` in a user profile
/// (`expandProfileText`). The seam `appendUserProfiles` takes; tests pass a
/// table of their own.
pub const ProcessEnvironment = struct {
    /// The value of `name` (compared without case, as Windows does), or null
    /// when it is not set.
    pub fn get(_: ProcessEnvironment, alloc: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        return std.process.getEnvVarOwned(alloc, name) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EnvironmentVariableNotFound, error.InvalidWtf8 => null,
        };
    }
};

/// `%NAME%` in `text` replaced by the value the shell would get without the
/// profile: the last `global_env` entry of that name (compared without case;
/// its value as written, since `env` values are not expanded), else
/// `process`'s, else nothing, in which case the text stays as written. One
/// pass, as `ExpandEnvironmentStringsW` scans (the test "user profile
/// expansion matches ExpandEnvironmentStringsW" holds it to that): text from a
/// `%` to the next `%` is a name, and an unset name stays as written, its
/// closing `%` free to open the next name. An empty name (`%%`) is never set.
pub fn expandProfileText(
    alloc: Allocator,
    text: []const u8,
    global_env: []const EnvEntry,
    process: anytype,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const start = std.mem.indexOfScalarPos(u8, text, i, '%') orelse {
            try out.appendSlice(alloc, text[i..]);
            break;
        };
        try out.appendSlice(alloc, text[i..start]);
        const end = std.mem.indexOfScalarPos(u8, text, start + 1, '%') orelse {
            try out.appendSlice(alloc, text[start..]);
            break;
        };
        const name = text[start + 1 .. end];
        if (try profileVariable(alloc, name, global_env, process)) |value| {
            defer alloc.free(value);
            try out.appendSlice(alloc, value);
            i = end + 1;
        } else {
            // The closing `%` of a name that is not set may open the next
            // one: `%UNSET%PATH%` keeps `%UNSET` and expands `%PATH%`.
            try out.appendSlice(alloc, text[start..end]);
            i = end;
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn profileVariable(alloc: Allocator, name: []const u8, global_env: []const EnvEntry, process: anytype) !?[]u8 {
    if (name.len == 0) return null;
    var index = global_env.len;
    while (index > 0) {
        index -= 1;
        const entry = global_env[index];
        if (std.ascii.eqlIgnoreCase(entry.key, name)) return try alloc.dupe(u8, entry.value);
    }
    return try process.get(alloc, name);
}

/// `ExpandEnvironmentStringsW` on noctty's own environment, which
/// `expandProfileText` must match when no `env` entry is involved.
fn expandEnvironmentStrings(alloc: Allocator, text: []const u8) ![]u8 {
    const source = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, text);
    defer alloc.free(source);
    var capacity: usize = source.len + 1;
    while (true) {
        const buffer = try alloc.alloc(u16, capacity);
        defer alloc.free(buffer);
        const needed = ExpandEnvironment.ExpandEnvironmentStringsW(
            source.ptr,
            buffer.ptr,
            std.math.cast(windows.DWORD, capacity) orelse return error.NameTooLong,
        );
        if (needed == 0) return error.InvalidArgument;
        if (needed <= capacity) {
            // `needed` counts the terminator.
            return try std.unicode.wtf16LeToWtf8Alloc(alloc, buffer[0 .. needed - 1]);
        }
        capacity = needed;
    }
}

const ExpandEnvironment = struct {
    extern "kernel32" fn ExpandEnvironmentStringsW(
        lpSrc: [*:0]const u16,
        lpDst: ?[*]u16,
        nSize: windows.DWORD,
    ) callconv(.winapi) windows.DWORD;
};
/// Split a Windows command line into argv with the rules CreateProcess's
/// callee (the MSVC runtime, `CommandLineToArgvW`) applies, so the argv
/// noctty inspects is the argv the program will see.
pub fn splitWindowsCommandLine(alloc: Allocator, line: []const u8) ![][:0]const u8 {
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, line);
    defer alloc.free(wide);
    var it = try std.process.ArgIteratorWindows.init(alloc, wide);
    defer it.deinit();
    var argv: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (argv.items) |arg| alloc.free(arg);
        argv.deinit(alloc);
    }
    while (it.next()) |arg| {
        const copy = try alloc.dupeZ(u8, arg);
        argv.append(alloc, copy) catch |err| {
            alloc.free(copy);
            return err;
        };
    }
    return try argv.toOwnedSlice(alloc);
}

/// The command line a launch hands CreateProcess unchanged: `line` when the
/// argv about to run is exactly its split, or when it is that argv's
/// `cmdKeepOpenLine`; else null and the argv is quoted as usual. Shell
/// integration, the WSL directory rewrite, the cmd UTF-8 preamble and
/// `initial-command` all change the argv, so a line that no longer describes
/// it is never used.
pub fn verbatimCommandLine(
    alloc: Allocator,
    line: ?[]const u8,
    argv: []const [:0]const u8,
    windows_cmd_shell: bool,
) Allocator.Error!?[]const u8 {
    const value = line orelse return null;
    if (windows_cmd_shell) return null;
    if (try splitsTo(alloc, value, argv)) return value;
    const own = (try cmdKeepOpenLine(alloc, argv)) orelse return null;
    defer alloc.free(own);
    return if (std.mem.eql(u8, own, value)) value else null;
}

fn splitsTo(alloc: Allocator, line: []const u8, argv: []const [:0]const u8) Allocator.Error!bool {
    const split = splitWindowsCommandLine(alloc, line) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer {
        for (split) |arg| alloc.free(arg);
        alloc.free(split);
    }
    if (split.len != argv.len) return false;
    for (split, argv) |a, b| {
        if (!std.mem.eql(u8, a, b)) return false;
    }
    return true;
}

/// cmd's own line for `<cmd> /k <program> <arguments>`: the text after `/k`
/// in one more pair of quotes, `<cmd> /k ""<program>" <arguments>"`. cmd
/// takes the first and the last quote off that text and runs the rest, so
/// the program path stays quoted whatever it holds. Measured with cmd.exe:
/// quoted as usual, or as `/k "<program>" ...` (Windows Terminal's line), a
/// path with `&` or `^`, or one with no space and `(`, `;`, `,` or `=`, runs
/// something else or nothing; this form ran every one. A defined `%NAME%` in
/// the path is still expanded. Null unless argv has that shape: a program
/// with no `"`, and arguments with nothing cmd reads specially.
pub fn cmdKeepOpenLine(alloc: Allocator, argv: []const []const u8) Allocator.Error!?[:0]u8 {
    if (argv.len < 3 or !std.ascii.eqlIgnoreCase(argv[1], "/k")) return null;
    for (argv[0..3]) |arg| {
        if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, '"') != null) return null;
    }
    for (argv[3..]) |arg| {
        if (arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\r\n\"&|<>^%()") != null) return null;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;
    const quote = if (std.mem.indexOfAny(u8, argv[0], " \t") != null) "\"" else "";
    writer.print("{s}{s}{s} {s} \"\"{s}\"", .{ quote, argv[0], quote, argv[1], argv[2] }) catch return error.OutOfMemory;
    for (argv[3..]) |arg| writer.print(" {s}", .{arg}) catch return error.OutOfMemory;
    writer.writeByte('"') catch return error.OutOfMemory;
    return try out.toOwnedSliceSentinel(0);
}

/// Add the user profiles after the detected local shells (and before the SSH
/// hosts, which the callers append next), in definition order. Takes
/// ownership of `shell_profiles`, also on error. A definition whose line does
/// not split into a program is skipped with a warning that names its id.
/// With no definitions this returns `shell_profiles` itself.
pub fn appendUserProfiles(
    alloc: Allocator,
    shell_profiles: []Profile,
    definitions: []const UserProfiles.Definition,
    expander: anytype,
) ![]Profile {
    if (definitions.len == 0) return shell_profiles;
    var profiles: std.ArrayList(Profile) = .empty;
    profiles.ensureTotalCapacity(alloc, shell_profiles.len + definitions.len) catch |err| {
        deinitProfiles(alloc, shell_profiles);
        return err;
    };
    profiles.appendSliceAssumeCapacity(shell_profiles);
    alloc.free(shell_profiles);
    errdefer deinitProfileList(alloc, &profiles);

    for (definitions) |definition| {
        const profile = userProfile(alloc, definition, expander) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("user profile skipped id={s} err={}", .{ definition.id, err });
                continue;
            },
        };
        profiles.appendAssumeCapacity(profile);
    }
    return try profiles.toOwnedSlice(alloc);
}

fn userProfile(alloc: Allocator, definition: UserProfiles.Definition, expander: anytype) !Profile {
    const expanded = try expandProfileText(alloc, definition.command, definition.global_env, expander);
    defer alloc.free(expanded);
    const line = std.mem.trim(u8, expanded, &std.ascii.whitespace);
    const argv = try splitWindowsCommandLine(alloc, line);
    var command: Command = .{ .direct = argv };
    errdefer command.deinit(alloc);
    if (argv.len == 0 or argv[0].len == 0) return error.NoProgram;

    const key = try std.ascii.allocLowerString(alloc, definition.id);
    defer alloc.free(key);
    const owned_key = try std.fmt.allocPrint(alloc, "user:{s}", .{key});
    errdefer alloc.free(owned_key);
    const label = try alloc.dupe(u8, definition.name orelse definition.id);
    errdefer alloc.free(label);
    const working_directory = if (definition.working_directory) |raw|
        try userWorkingDirectory(alloc, raw, definition.global_env, expander)
    else
        null;
    errdefer if (working_directory) |dir| switch (dir) {
        .path => |path| alloc.free(path),
        .home, .inherit => {},
    };

    const env = try alloc.alloc(EnvEntry, definition.env.len);
    var filled: usize = 0;
    errdefer {
        for (env[0..filled]) |entry| {
            alloc.free(entry.key);
            alloc.free(entry.value);
        }
        alloc.free(env);
    }
    for (definition.env, env) |src, *dst| {
        const value = try expandProfileText(alloc, src.value, definition.global_env, expander);
        defer alloc.free(value);
        const owned_value = try alloc.dupeZ(u8, value);
        errdefer alloc.free(owned_value);
        dst.* = .{ .key = try alloc.dupeZ(u8, src.key), .value = owned_value };
        filled += 1;
    }

    return .{
        .kind = .user,
        .key = owned_key,
        .label = label,
        .command = command,
        .working_directory = working_directory,
        .user = .{ .command_line = try alloc.dupeZ(u8, line), .env = env },
    };
}

/// `profile-working-directory` with the grammar of `working-directory`:
/// `home`, `inherit`, or a path, optionally quoted, after `%NAME%` expansion;
/// a leading `~/` or `~\` is the home directory.
fn userWorkingDirectory(
    alloc: Allocator,
    raw: []const u8,
    global_env: []const EnvEntry,
    expander: anytype,
) !WorkingDirectory {
    const expanded = try expandProfileText(alloc, raw, global_env, expander);
    defer alloc.free(expanded);
    var value = std.mem.trim(u8, expanded, &std.ascii.whitespace);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (std.mem.eql(u8, value, "home")) return .home;
    if (std.mem.eql(u8, value, "inherit")) return .inherit;
    if (value.len >= 2 and value[0] == '~' and (value[1] == '/' or value[1] == '\\')) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (internal_os.home(&buf) catch null) |home| {
            return .{ .path = try std.fmt.allocPrintSentinel(alloc, "{s}\\{s}", .{
                std.mem.trimRight(u8, home, "\\/"),
                value[2..],
            }, 0) };
        }
    }
    return .{ .path = try alloc.dupeZ(u8, value) };
}

/// noctty's environment for tests, a fixed table: the seam
/// `appendUserProfiles` takes. Names compare without case, as Windows
/// compares them.
const TestEnvironment = struct {
    vars: []const [2][]const u8 = &.{},

    pub fn get(self: TestEnvironment, alloc: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        for (self.vars) |pair| {
            if (std.ascii.eqlIgnoreCase(pair[0], name)) return try alloc.dupe(u8, pair[1]);
        }
        return null;
    }
};

const test_vs18_cmd_line =
    \\cmd.exe /k "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -startdir=none -arch=x64 -host_arch=x64
;
/// Windows Terminal's Developer PowerShell line (`VsDevShellGenerator`),
/// with its `"""` quoting; the split below is the one measured for the
/// design in `_scratch-profiles-judge/rt-judge.log`.
const test_vs18_wt_devshell_line =
    \\pwsh.exe -NoExit -Command "&{Import-Module """C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"""; Enter-VsDevShell 6bb7cfd9 -SkipAutomaticLocation -DevCmdArguments """-arch=x64 -host_arch=x64"""}"
;

fn testFreeArgv(alloc: Allocator, argv: []const [:0]const u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

test "user profile command lines split with the Windows rules, unlike direct:" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const devcmd = try splitWindowsCommandLine(alloc, test_vs18_cmd_line);
    defer testFreeArgv(alloc, devcmd);
    const want_devcmd = [_][]const u8{
        "cmd.exe",
        "/k",
        "C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\Common7\\Tools\\VsDevCmd.bat",
        "-startdir=none",
        "-arch=x64",
        "-host_arch=x64",
    };
    try testing.expectEqual(want_devcmd.len, devcmd.len);
    for (want_devcmd, devcmd) |want, got| try testing.expectEqualStrings(want, got);

    const devshell = try splitWindowsCommandLine(alloc, test_vs18_wt_devshell_line);
    defer testFreeArgv(alloc, devshell);
    const want_devshell = [_][]const u8{
        "pwsh.exe",
        "-NoExit",
        "-Command",
        "&{Import-Module \"C:\\Program",
        "Files\\Microsoft",
        "Visual",
        "Studio\\18\\Community\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll\"; Enter-VsDevShell 6bb7cfd9 -SkipAutomaticLocation -DevCmdArguments \"-arch=x64",
        "-host_arch=x64\"}",
    };
    try testing.expectEqual(want_devshell.len, devshell.len);
    for (want_devshell, devshell) |want, got| try testing.expectEqualStrings(want, got);

    // `command = direct:` splits with the general rules, which drop the inner
    // quotes PowerShell needs to see the module path as one string.
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var direct: Command = undefined;
    try direct.parseCLI(arena.allocator(), "direct:" ++ test_vs18_wt_devshell_line);
    try testing.expectEqual(@as(usize, 8), direct.direct.len);
    try testing.expectEqualStrings("&{Import-Module C:\\Program", direct.direct[3]);
    try testing.expect(!std.mem.eql(u8, direct.direct[3], devshell[3]));
}

test "verbatimCommandLine keeps a line only while it still describes the argv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // cmd.exe reads its raw command line, so these must reach it as written:
    // quoted again from argv, the first loses cmd's outer-quote idiom and the
    // second unquotes the `&` (measured for the design).
    for ([_][]const u8{
        "cmd.exe /k \"\"C:\\Tools Dir\\init.cmd\" \"some arg\"\"",
        "cmd.exe /k echo \"a&b\"",
        test_vs18_cmd_line,
    }) |line| {
        const argv = try splitWindowsCommandLine(alloc, line);
        defer testFreeArgv(alloc, argv);
        const chosen = (try verbatimCommandLine(alloc, line, argv, false)).?;
        try testing.expectEqualStrings(line, chosen);
        // The cmd /C trampoline writes its own tail; a line never replaces it.
        try testing.expect((try verbatimCommandLine(alloc, line, argv, true)) == null);
    }
    try testing.expect((try verbatimCommandLine(alloc, null, &.{"cmd.exe"}, false)) == null);

    // The WSL `--cd` rewrite changes the argv, so the line no longer applies
    // and the launch quotes the rewritten argv.
    const wsl_line = "wsl.exe -d Ubuntu";
    const wsl_argv = try splitWindowsCommandLine(alloc, wsl_line);
    defer testFreeArgv(alloc, wsl_argv);
    const wsl = try prepareCommandWithLookup(alloc, .{ .direct = wsl_argv }, "D:\\work", false, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer wsl.deinit(alloc);
    try testing.expect(wsl.direct.len != wsl_argv.len);
    try testing.expect((try verbatimCommandLine(alloc, wsl_line, wsl.direct, false)) == null);

    // `initial-command` (or anything else) running another argv.
    try testing.expect((try verbatimCommandLine(alloc, wsl_line, &.{ "wsl.exe", "-d", "Debian" }, false)) == null);
}

test "user profiles expand %NAME% in the command, the directory and env values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const env = TestEnvironment{ .vars = &.{
        .{ "TOOLS", "C:\\T dir" },
        .{ "work", "D:\\w" },
        .{ "PATH", "C:\\Windows" },
    } };
    const definitions = [_]UserProfiles.Definition{.{
        .id = "Tool",
        .command = "  \"%TOOLS%\\x.exe\" --flag %NOCTTY_UNDEFINED% 100%  ",
        .working_directory = "\"%WORK%\\src\"",
        .env = &.{
            .{ .key = "PATH", .value = "%TOOLS%;%PATH%" },
            .{ .key = "LITERAL", .value = "%nope%" },
        },
    }};
    const profiles = try appendUserProfiles(alloc, try alloc.alloc(Profile, 0), &definitions, env);
    defer deinitProfiles(alloc, profiles);
    try testing.expectEqual(@as(usize, 1), profiles.len);
    const profile = profiles[0];
    try testing.expectEqual(ProfileKind.user, profile.kind);
    try testing.expectEqualStrings("\"C:\\T dir\\x.exe\" --flag %NOCTTY_UNDEFINED% 100%", profile.user.?.command_line);
    try testing.expectEqualStrings("C:\\T dir\\x.exe", profile.command.direct[0]);
    try testing.expectEqualStrings("%NOCTTY_UNDEFINED%", profile.command.direct[2]);
    try testing.expectEqualStrings("D:\\w\\src", profile.working_directory.?.path);
    try testing.expectEqualStrings("PATH", profile.user.?.env[0].key);
    try testing.expectEqualStrings("C:\\T dir;C:\\Windows", profile.user.?.env[0].value);
    try testing.expectEqualStrings("%nope%", profile.user.?.env[1].value);
}

test "user profile %NAME% reads env lines before noctty's environment" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const process = TestEnvironment{ .vars = &.{
        .{ "PATH", "C:\\Windows" },
        .{ "USERPROFILE", "C:\\Users\\me" },
        .{ "MODE", "process" },
    } };
    // `env = Path=C:\team` and `env = PATH=C:\later` (Windows sees the
    // later one), plus a variable only noctty's environment has.
    const global = [_]EnvEntry{
        .{ .key = "Path", .value = "C:\\team" },
        .{ .key = "OTHER", .value = "%USERPROFILE%" },
        .{ .key = "PATH", .value = "C:\\later" },
    };
    const definitions = [_]UserProfiles.Definition{.{
        .id = "py",
        .command = "%USERPROFILE%\\py.exe %OTHER% %UNSET% %MODE%",
        .working_directory = "%path%\\src",
        .env = &.{
            .{ .key = "PATH", .value = "C:\\py;%PATH%" },
            .{ .key = "MODE", .value = "profile" },
            // The profile's own variable is not visible to its values.
            .{ .key = "SEEN", .value = "%MODE%" },
        },
        .global_env = &global,
    }};
    const profiles = try appendUserProfiles(alloc, try alloc.alloc(Profile, 0), &definitions, process);
    defer deinitProfiles(alloc, profiles);
    const user = profiles[0].user.?;
    // `env` values are literal: `%USERPROFILE%` in one stays as written.
    try testing.expectEqualStrings("C:\\Users\\me\\py.exe %USERPROFILE% %UNSET% process", user.command_line);
    try testing.expectEqualStrings("C:\\later\\src", profiles[0].working_directory.?.path);
    try testing.expectEqualStrings("C:\\py;C:\\later", user.env[0].value);
    try testing.expectEqualStrings("process", user.env[2].value);

    // From a config: the global `env` lines reach every definition.
    const Config = @import("Config.zig");
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    const arena = cfg._arena.?.allocator();
    try cfg.env.parseCLI(arena, "Path=C:\\team");
    try cfg.@"profile-command".parseCLI(arena, "a: a.exe %PATH%");
    try cfg.@"profile-command".parseCLI(arena, "b: b.exe");
    try cfg.@"profile-env".parseCLI(arena, "b: PATH=C:\\py;%PATH%");
    try cfg.finalize();
    var from_config = try UserProfiles.init(alloc, &cfg);
    defer from_config.deinit();
    const listed = try appendUserProfiles(alloc, try alloc.alloc(Profile, 0), from_config.definitions, process);
    defer deinitProfiles(alloc, listed);
    try testing.expectEqualStrings("a.exe C:\\team", listed[0].user.?.command_line);
    try testing.expectEqualStrings("C:\\py;C:\\team", listed[1].user.?.env[0].value);
}

test "user profile expansion matches ExpandEnvironmentStringsW" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    // Names this process has (`SystemRoot`, `windir`) and does not have, in
    // every arrangement of `%` the scanner has to agree on.
    const unset = "NOCTTY_TEST_SURELY_UNDEFINED_8C1F";
    const cases = [_][]const u8{
        "",
        "plain",
        "%SystemRoot%\\x",
        "%systemroot%",
        "%SYSTEMROOT%%windir%",
        "%%",
        "%%%",
        "100%",
        "%",
        "a%b",
        "%" ++ unset ++ "%",
        "%" ++ unset ++ "%SystemRoot%",
        "%" ++ unset ++ "%SystemRoot%x%",
        "%A%SystemRoot%",
        "x%" ++ unset ++ "%%windir%%",
        "%SystemRoot",
        "%SystemRoot%%",
        "%%SystemRoot%%",
        "% SystemRoot%",
        "\"%SystemRoot%\\a b\\\" %%x",
    };
    for (cases) |text| {
        const want = try expandEnvironmentStrings(alloc, text);
        defer alloc.free(want);
        const got = try expandProfileText(alloc, text, &.{}, ProcessEnvironment{});
        defer alloc.free(got);
        testing.expectEqualStrings(want, got) catch |err| {
            std.debug.print("text: {s}\n", .{text});
            return err;
        };
    }
}

test "user profile working directories take the working-directory values" {
    const testing = std.testing;
    const alloc = testing.allocator;
    for ([_]struct { raw: []const u8, want: std.meta.Tag(WorkingDirectory) }{
        .{ .raw = "home", .want = .home },
        .{ .raw = " inherit ", .want = .inherit },
        .{ .raw = "\"home\"", .want = .home },
        .{ .raw = "C:\\src", .want = .path },
    }) |case| {
        const dir = try userWorkingDirectory(alloc, case.raw, &.{}, TestEnvironment{});
        defer if (dir == .path) alloc.free(dir.path);
        try testing.expectEqual(case.want, std.meta.activeTag(dir));
    }
    if (builtin.os.tag == .windows) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (try internal_os.home(&buf)) |home| {
            const dir = try userWorkingDirectory(alloc, "~/src", &.{}, TestEnvironment{});
            defer alloc.free(dir.path);
            try testing.expect(std.mem.startsWith(u8, dir.path, std.mem.trimRight(u8, home, "\\/")));
            try testing.expect(std.mem.endsWith(u8, dir.path, "\\src"));
        }
    }
}

test "user profiles list after the local shells and before SSH, keyed by lowercased id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Config = @import("Config.zig");

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    const arena = cfg._arena.?.allocator();
    try cfg.@"profile-name".parseCLI(arena, "vs18-cmd: Developer Command Prompt for VS 18");
    try cfg.@"profile-command".parseCLI(arena, "vs18-cmd: " ++ test_vs18_cmd_line);
    try cfg.@"profile-name".parseCLI(arena, "vs18-ps: Developer PowerShell for VS 18");
    try cfg.@"profile-command".parseCLI(arena, "vs18-ps: " ++ test_vs18_wt_devshell_line);
    try cfg.@"profile-command".parseCLI(arena, "Py312: cmd.exe");
    try cfg.@"profile-env".parseCLI(arena, "py312: A=1");
    try cfg.finalize();
    try testing.expect(cfg._diagnostics.empty());

    var user = try UserProfiles.init(alloc, &cfg);
    defer user.deinit();
    try testing.expectEqual(@as(usize, 3), user.definitions.len);

    const lookup = struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup;
    const probe = struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return true;
        }
    }.probe;
    const list = struct {
        fn list(a: Allocator, _: []const u8) ![][]u8 {
            return try a.alloc([]u8, 0);
        }
    }.list;
    const hosts = [_]windows_ssh_hosts.Host{.{ .alias = "prod" }};

    // The same stages, in the same order, as `listProfiles`.
    const shell = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, lookup, probe, list, null, null);
    const local = try appendUserProfiles(alloc, shell, user.definitions, TestEnvironment{});
    const profiles = try appendSshProfiles(alloc, local, &hosts, "C:\\Windows\\System32\\OpenSSH\\ssh.exe");
    defer deinitProfiles(alloc, profiles);

    const want = [_]struct { key: []const u8, label: []const u8, kind: ProfileKind }{
        .{ .key = "pwsh.exe", .label = "PowerShell", .kind = .pwsh },
        .{ .key = "cmd.exe", .label = "Command Prompt", .kind = .cmd },
        .{ .key = "user:vs18-cmd", .label = "Developer Command Prompt for VS 18", .kind = .user },
        .{ .key = "user:vs18-ps", .label = "Developer PowerShell for VS 18", .kind = .user },
        .{ .key = "user:py312", .label = "Py312", .kind = .user },
        .{ .key = "ssh:prod", .label = "SSH: prod", .kind = .ssh },
    };
    try testing.expectEqual(want.len, profiles.len);
    for (want, profiles) |w, p| {
        try testing.expectEqualStrings(w.key, p.key);
        try testing.expectEqualStrings(w.label, p.label);
        try testing.expectEqual(w.kind, p.kind);
    }
    try testing.expectEqualStrings(test_vs18_cmd_line, profiles[2].user.?.command_line);
    try testing.expectEqual(@as(usize, 6), profiles[2].command.direct.len);
    try testing.expectEqual(@as(usize, 8), profiles[3].command.direct.len);
    try testing.expectEqualStrings("A", profiles[4].user.?.env[0].key);
    // The detected ones carry nothing new.
    try testing.expect(profiles[0].user == null and profiles[0].working_directory == null);

    // Copies keep the new fields (a worker's list is cloned onto each host).
    const copy = try cloneProfiles(alloc, profiles);
    defer deinitProfiles(alloc, copy);
    try testing.expectEqualStrings(test_vs18_cmd_line, copy[2].user.?.command_line);
    try testing.expect(copy[2].user.?.command_line.ptr != profiles[2].user.?.command_line.ptr);
    try testing.expectEqualStrings("1", copy[4].user.?.env[0].value);
}

test "no profile keys leave the detected list exactly as it was" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Config = @import("Config.zig");
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.finalize();
    var user = try UserProfiles.init(alloc, &cfg);
    defer user.deinit();
    try testing.expectEqual(@as(usize, 0), user.definitions.len);

    const shell = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
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
    }.list, null, null);
    const merged = try appendUserProfiles(alloc, shell, user.definitions, TestEnvironment{});
    defer deinitProfiles(alloc, merged);
    // The very same slice: nothing copied, nothing reordered.
    try testing.expectEqual(shell.ptr, merged.ptr);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqualStrings("cmd.exe", merged[0].key);
}

test "pin: the whole detected list with no profile keys, through symbols main has" {
    // Written against main's own entry points, so this exact text passes on
    // main and on this branch: the detected shells and the SSH hosts, every
    // kind, key, label, palette title and argv, in order.
    const testing = std.testing;
    const alloc = testing.allocator;
    const shell = try listProfilesWithLookupAndProbeAndWslList(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            const found = [_][2][]const u8{
                .{ "wsl.exe", "C:\\W\\wsl.exe" },
                .{ "pwsh.exe", "C:\\P\\pwsh.exe" },
                .{ "powershell.exe", "C:\\W\\powershell.exe" },
                .{ "bash.exe", "C:\\G\\bin\\bash.exe" },
                .{ "cmd.exe", "C:\\W\\cmd.exe" },
            };
            for (found) |pair| if (std.mem.eql(u8, exe, pair[0])) return try a.dupe(u8, pair[1]);
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return true;
        }
    }.probe, struct {
        fn list(a: Allocator, _: []const u8) ![][]u8 {
            const distros = try a.alloc([]u8, 2);
            distros[0] = try a.dupe(u8, "Ubuntu");
            distros[1] = try a.dupe(u8, "Debian");
            return distros;
        }
    }.list);
    const hosts = [_]windows_ssh_hosts.Host{.{ .alias = "prod" }};
    const profiles = try appendSshProfiles(alloc, shell, &hosts, "C:\\S\\ssh.exe");
    defer deinitProfiles(alloc, profiles);

    const Want = struct { kind: ProfileKind, key: []const u8, label: []const u8, palette: ?[]const u8 = null, argv: []const []const u8 };
    const want = [_]Want{
        .{ .kind = .wsl_default, .key = "wsl-default", .label = "WSL (Default)", .argv = &.{"C:\\W\\wsl.exe"} },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "WSL: Ubuntu", .argv = &.{ "C:\\W\\wsl.exe", "-d", "Ubuntu" } },
        .{ .kind = .wsl_distro, .key = "wsl:Debian", .label = "WSL: Debian", .argv = &.{ "C:\\W\\wsl.exe", "-d", "Debian" } },
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .argv = &.{"C:\\P\\pwsh.exe"} },
        .{ .kind = .powershell, .key = "powershell.exe", .label = "Windows PowerShell", .argv = &.{"C:\\W\\powershell.exe"} },
        .{ .kind = .git_bash, .key = "git-bash", .label = "Git Bash", .argv = &.{ "C:\\G\\bin\\bash.exe", "--login", "-i" } },
        .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .argv = &.{"C:\\W\\cmd.exe"} },
        .{ .kind = .ssh, .key = "ssh:prod", .label = "SSH: prod", .palette = "Connect to prod", .argv = &.{ "C:\\S\\ssh.exe", "prod" } },
    };
    try testing.expectEqual(want.len, profiles.len);
    for (want, profiles) |w, p| {
        try testing.expectEqual(w.kind, p.kind);
        try testing.expectEqualStrings(w.key, p.key);
        try testing.expectEqualStrings(w.label, p.label);
        if (w.palette) |title| try testing.expectEqualStrings(title, p.palette_title.?) else try testing.expect(p.palette_title == null);
        try testing.expectEqual(w.argv.len, p.command.direct.len);
        for (w.argv, p.command.direct) |a, b| try testing.expectEqualStrings(a, b);
    }
}

test "a user profile whose line names no program is skipped" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const definitions = [_]UserProfiles.Definition{
        .{ .id = "empty", .command = "\"\" arg" },
        .{ .id = "ok", .command = "ok.exe" },
    };
    const profiles = try appendUserProfiles(alloc, try alloc.alloc(Profile, 0), &definitions, TestEnvironment{});
    defer deinitProfiles(alloc, profiles);
    try testing.expectEqual(@as(usize, 1), profiles.len);
    try testing.expectEqualStrings("user:ok", profiles[0].key);
}

test "user profile listing frees what it built when an allocation fails" {
    const definitions = [_]UserProfiles.Definition{.{
        .id = "a",
        .name = "A",
        .command = "a.exe \"b c\"",
        .working_directory = "C:\\a",
        .env = &.{ .{ .key = "K", .value = "V" }, .{ .key = "L", .value = "W" } },
    }};
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const alloc = failing.allocator();
        const start = alloc.alloc(Profile, 0) catch continue;
        const profiles = appendUserProfiles(alloc, start, &definitions, TestEnvironment{}) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        deinitProfiles(alloc, profiles);
        break;
    }
}

test "profileShellIntegrationDiagnostic reads a user profile's program" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const Case = struct { argv: []const [:0]const u8, support: ShellIntegrationSupport };
    for ([_]Case{
        .{ .argv = &.{ "cmd.exe", "/k", "x.bat" }, .support = .automatic },
        .{ .argv = &.{ "C:\\PowerShell\\pwsh.exe", "-NoLogo" }, .support = .automatic },
        .{ .argv = &.{"python.exe"}, .support = .manual },
    }) |case| {
        const profile: Profile = .{ .kind = .user, .key = "user:x", .label = "x", .command = .{ .direct = case.argv } };
        try testing.expectEqual(case.support, (try profileShellIntegrationDiagnostic(alloc, &profile)).support);
    }
    const cmd: Profile = .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{"cmd.exe"} } };
    try testing.expectEqualStrings(
        shellIntegrationDiagnostic(.cmd).summary,
        (try profileShellIntegrationDiagnostic(alloc, &cmd)).summary,
    );
}

pub const ProfileDiscovery = struct {
    profiles: []Profile,
    complete: bool,
};

/// The command a terminal runs when `command` is unset: PowerShell 7+
/// (`pwsh.exe`), else Windows PowerShell, else Command Prompt. WSL is never
/// chosen here, because `wsl.exe --status` can report a healthy installation
/// when launching a session would still fail; a distribution is picked from
/// the profile picker or by `command = wsl.exe`.
///
/// Nothing is launched, and `PATH` entries that are network or device paths,
/// or folder links to one, are never searched, so this is safe on the UI thread
/// while the configuration loads. A direct command skips the `cmd.exe /C`
/// trampoline.
pub fn defaultCommand(alloc: Allocator) !Command {
    return try defaultCommandWithHost(alloc, DefaultShellHost);
}

/// The command safe mode runs: always Command Prompt, as `cmd.exe /D`. Recovery
/// has to work when the user's own startup files are what broke. PowerShell
/// loads `$PROFILE` even under the shell integration's `-NoExit -Command`;
/// `cmd.exe` reads no profile, and `/D` also skips the `AutoRun` command that
/// a registry value or Clink can hang there.
pub fn recoveryCommand(alloc: Allocator) !Command {
    return try commandPromptWithHost(alloc, DefaultShellHost, &.{"/D"});
}

/// Every profile the picker lists: the detected local shells, then the user's
/// own (`user`, a snapshot of the `profile-*` keys), then Visual Studio's
/// developer shells, then the SSH hosts.
pub fn listProfiles(
    alloc: Allocator,
    include_ssh_hosts: bool,
    user: *const UserProfiles,
) ![]Profile {
    // `profile-order` replaces the environment's order hint.
    const order_hint: ?[]u8 = if (user.order.len > 0) null else detectProfileOrderHint(alloc);
    defer if (order_hint) |value| alloc.free(value);

    const shell_profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookupExecutable,
        probeWslExecutableCached,
        listWslDistros,
        order_hint,
        null,
    );
    return try appendLaterProfiles(alloc, shell_profiles, user, SystemStages{ .include_ssh_hosts = include_ssh_hosts }, null);
}

/// `listProfiles` that also says whether the list is complete (a WSL probe
/// timed out, the SSH config was busy).
pub fn discoverProfiles(
    alloc: Allocator,
    include_ssh_hosts: bool,
    user: *const UserProfiles,
) !ProfileDiscovery {
    const order_hint: ?[]u8 = if (user.order.len > 0) null else detectProfileOrderHint(alloc);
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
    const profiles = try appendLaterProfiles(alloc, shell_profiles, user, SystemStages{ .include_ssh_hosts = include_ssh_hosts }, &complete);
    return .{ .profiles = profiles, .complete = complete };
}

/// The stages after the detected local shells, in the picker's order: the
/// user's profiles, Visual Studio's developer shells, then the SSH hosts,
/// arranged by `profile-order` and `profile-hidden`. `stages` says how each
/// one asks the system (`SystemStages`, or a test's). Takes ownership of
/// `shell_profiles`, also on error.
fn appendLaterProfiles(
    alloc: Allocator,
    shell_profiles: []Profile,
    user: *const UserProfiles,
    stages: anytype,
    complete: ?*bool,
) ![]Profile {
    const user_profiles = try appendUserProfiles(alloc, shell_profiles, user.definitions, stages.environment);
    const local_profiles = try appendVisualStudioProfiles(
        alloc,
        user_profiles,
        user.visual_studio,
        stages.arch,
        stages.visual_studio,
        stages.visual_studio_host,
        complete,
    );
    const profiles = try stages.ssh(alloc, local_profiles, complete);
    arrangeProfiles(profiles, user.order, user.hidden);
    return profiles;
}

/// The real system, for `appendLaterProfiles`.
const SystemStages = struct {
    include_ssh_hosts: bool,
    environment: ProcessEnvironment = .{},
    arch: visual_studio.Arch = visual_studio.build_arch,
    visual_studio: visual_studio.ComSource = .{},
    visual_studio_host: VisualStudioHost = .{},

    pub fn ssh(self: SystemStages, alloc: Allocator, profiles: []Profile, complete: ?*bool) ![]Profile {
        return try appendConfiguredSshProfiles(alloc, profiles, self.include_ssh_hosts, complete);
    }
};

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
        // Busy: another discovery was reading the config at the same
        // moment. Not worth a warning; the incomplete list is retried.
        if (err != error.SshConfigReadBusy) warnSshDiscoveryOnce(err);
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

/// What `appendVisualStudioProfiles` asks of the system: whether an install
/// folder and a file exist, with the guards discovery uses everywhere (a
/// fixed local drive, no link followed at any component, no cloud
/// placeholder), and the shell lookups the other profiles use.
const VisualStudioHost = struct {
    pub fn installDirectory(_: VisualStudioHost, path: []const u8) bool {
        return isLocalSearchDirectory(path);
    }

    pub fn file(_: VisualStudioHost, path: []const u8) bool {
        return isLocalExecutableInfo(pathInfo(path) orelse return false);
    }

    pub fn lookup(_: VisualStudioHost, alloc: Allocator, exe: []const u8) !?[]u8 {
        return try lookupExecutable(alloc, exe);
    }
};

/// Add Visual Studio's developer shells after `shell_profiles`, newest
/// instance first: its Developer Command Prompt, then its Developer
/// PowerShell, then the next instance's. `source` lists the instances
/// (`visual_studio.ComSource`, or a test's), `host` checks their files.
/// Under `.newest` every instance after the first that makes a profile is
/// hidden, as in Windows Terminal: still found by key. Under `.none`
/// `source` is not asked. Takes ownership of `shell_profiles`, also on
/// error; a failed query leaves `complete` false.
pub fn appendVisualStudioProfiles(
    alloc: Allocator,
    shell_profiles: []Profile,
    mode: VisualStudioProfiles,
    arch: visual_studio.Arch,
    source: anytype,
    host: anytype,
    complete: ?*bool,
) ![]Profile {
    if (mode == .none) return shell_profiles;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const found = source.query(arena.allocator()) catch |err| {
        deinitProfiles(alloc, shell_profiles);
        return err;
    };
    if (!found.complete) {
        if (complete) |value| value.* = false;
    }
    if (found.instances.len == 0) return shell_profiles;
    visual_studio.sortNewestFirst(found.instances);

    var profiles: std.ArrayList(Profile) = .empty;
    profiles.ensureTotalCapacity(alloc, shell_profiles.len + 2 * found.instances.len) catch |err| {
        deinitProfiles(alloc, shell_profiles);
        return err;
    };
    profiles.appendSliceAssumeCapacity(shell_profiles);
    alloc.free(shell_profiles);
    errdefer deinitProfileList(alloc, &profiles);

    var shown = false;
    var newest_cmd = false;
    var newest_pwsh = false;
    for (found.instances) |instance| {
        const first = profiles.items.len;
        try appendVisualStudioInstance(alloc, &profiles, instance, arch, host);
        if (profiles.items.len == first) continue;
        for (profiles.items[first..]) |*profile| {
            profile.hidden = mode == .newest and shown;
            const newest = switch (profile.kind) {
                .vs_dev_cmd => &newest_cmd,
                .vs_dev_shell => &newest_pwsh,
                else => continue,
            };
            profile.newest_visual_studio = !newest.*;
            newest.* = true;
        }
        shown = true;
    }
    return try profiles.toOwnedSlice(alloc);
}

/// The two profiles of one instance, each only when its script is there.
/// The key carries the instance id (`vs:<id>:cmd`, `vs:<id>:pwsh`), which
/// survives updates and moves. Both start in home: `-startdir=none` and
/// `-SkipAutomaticLocation` keep the scripts from changing directory. The
/// PowerShell argv survives the usual quoting as is (its script holds no
/// `"`), so only the Command Prompt carries a line of its own.
fn appendVisualStudioInstance(
    alloc: Allocator,
    profiles: *std.ArrayList(Profile),
    instance: visual_studio.Instance,
    arch: visual_studio.Arch,
    host: anytype,
) !void {
    // The id goes into a key and a PowerShell script; a network install
    // would put a share's timeouts on discovery.
    if (!visual_studio.isPlainInstanceId(instance.id)) return;
    if (!isOnLocalDrive(instance.path)) return;
    if (!host.installDirectory(instance.path)) return;
    const root = std.mem.trimRight(u8, instance.path, "\\/");
    const dev_args = visual_studio.devCmdArguments(arch, instance.version);

    const bat = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ root, visual_studio.dev_cmd_relative });
    defer alloc.free(bat);
    if (host.file(bat)) {
        if (try host.lookup(alloc, "cmd.exe")) |cmd| {
            defer alloc.free(cmd);
            const key = try std.fmt.allocPrint(alloc, "vs:{s}:cmd", .{instance.id});
            defer alloc.free(key);
            const label = try visual_studio.commandPromptLabel(alloc, instance);
            defer alloc.free(label);
            const argv = [_][]const u8{ cmd, "/k", bat, "-startdir=none", dev_args[0], dev_args[1] };
            // cmd reads the raw text after `/k`: in cmd's own form an
            // install path with `&`, `^` or `(` stays one path, where the
            // usual quoting (and Windows Terminal's line) splits it. Exec
            // launches this line while the argv is still this one.
            const line = try cmdKeepOpenLine(alloc, &argv);
            errdefer if (line) |value| alloc.free(value);
            try appendProfile(alloc, profiles, .vs_dev_cmd, key, label, &argv);
            if (line) |value| profiles.items[profiles.items.len - 1].user = .{ .command_line = value };
        }
    }

    if (!visual_studio.hasDevShell(instance.version)) return;
    const module = try std.fmt.allocPrint(alloc, "{s}\\{s}", .{ root, visual_studio.devShellModuleRelative(instance.version) });
    defer alloc.free(module);
    if (!host.file(module)) return;
    // PowerShell 7 when it is installed, as Windows Terminal picks.
    const shell = (try host.lookup(alloc, "pwsh.exe")) orelse
        (try host.lookup(alloc, "powershell.exe")) orelse return;
    defer alloc.free(shell);
    const script = try visual_studio.devShellScript(alloc, module, instance, arch);
    defer alloc.free(script);
    const key = try std.fmt.allocPrint(alloc, "vs:{s}:pwsh", .{instance.id});
    defer alloc.free(key);
    const label = try visual_studio.powerShellLabel(alloc, instance);
    defer alloc.free(label);
    try appendProfile(alloc, profiles, .vs_dev_shell, key, label, &.{ shell, "-NoExit", "-Command", script });
}

/// A Visual Studio instance list for tests, counting the queries.
const TestVsSource = struct {
    instances: []const visual_studio.Instance = &.{},
    complete: bool = true,
    queries: *usize,

    pub fn query(self: TestVsSource, alloc: Allocator) !visual_studio.Discovery {
        self.queries.* += 1;
        return .{ .instances = try alloc.dupe(visual_studio.Instance, self.instances), .complete = self.complete };
    }
};

/// The files and folders a test's Visual Studio installs have, and the
/// shells on the machine; counts every question.
const TestVsHost = struct {
    paths: []const []const u8,
    pwsh: bool = true,
    queries: *usize,

    pub fn installDirectory(self: TestVsHost, path: []const u8) bool {
        return self.has(path);
    }

    pub fn file(self: TestVsHost, path: []const u8) bool {
        return self.has(path);
    }

    fn has(self: TestVsHost, path: []const u8) bool {
        self.queries.* += 1;
        for (self.paths) |known| if (std.mem.eql(u8, known, path)) return true;
        return false;
    }

    pub fn lookup(self: TestVsHost, alloc: Allocator, exe: []const u8) !?[]u8 {
        self.queries.* += 1;
        if (std.mem.eql(u8, exe, "pwsh.exe")) return if (self.pwsh) try alloc.dupe(u8, test_pwsh) else null;
        if (std.mem.eql(u8, exe, "powershell.exe")) return try alloc.dupe(u8, test_windows_powershell);
        if (std.mem.eql(u8, exe, "cmd.exe")) return try alloc.dupe(u8, test_cmd);
        return null;
    }
};

const test_vs18_root = "C:\\Program Files\\Microsoft Visual Studio\\18\\Community";
const test_vs2022_root = "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community";
const test_vs18: visual_studio.Instance = .{
    .id = "6bb7cfd9",
    .path = test_vs18_root,
    .version_text = "18.10.12201.205",
    .version = visual_studio.version(18, 10) | 0x2fa9_00cd,
    .install_date = 134145712400000000,
    .suffix = "18",
};
const test_vs2022: visual_studio.Instance = .{
    .id = "486bb794",
    .path = test_vs2022_root,
    .version_text = "17.14.37628.2",
    .version = visual_studio.version(17, 14) | 0x92fc_0002,
    .install_date = 134145709760000000,
    .suffix = "2022",
};
/// What both installs have on disk.
const test_vs_paths = [_][]const u8{
    test_vs18_root,
    test_vs18_root ++ "\\Common7\\Tools\\VsDevCmd.bat",
    test_vs18_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll",
    test_vs2022_root,
    test_vs2022_root ++ "\\Common7\\Tools\\VsDevCmd.bat",
    test_vs2022_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll",
};

fn testVsProfiles(
    alloc: Allocator,
    mode: VisualStudioProfiles,
    arch: visual_studio.Arch,
    source: TestVsSource,
    host: TestVsHost,
    complete: ?*bool,
) ![]Profile {
    return try appendVisualStudioProfiles(alloc, try alloc.alloc(Profile, 0), mode, arch, source, host, complete);
}

fn expectArgv(profile: Profile, argv: []const []const u8) !void {
    try std.testing.expectEqual(argv.len, profile.command.direct.len);
    for (argv, profile.command.direct) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "two Visual Studio installs give their developer shells, newest first, the older hidden" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var source_queries: usize = 0;
    var host_queries: usize = 0;
    // Setup Configuration's order is not the list's: the newest comes first.
    const source: TestVsSource = .{ .instances = &.{ test_vs2022, test_vs18 }, .queries = &source_queries };
    const host: TestVsHost = .{ .paths = &test_vs_paths, .queries = &host_queries };

    const vs18_script = "&{Import-Module '" ++ test_vs18_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll'; Enter-VsDevShell 6bb7cfd9 -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}";
    const vs2022_script = "&{Import-Module '" ++ test_vs2022_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll'; Enter-VsDevShell 486bb794 -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}";
    for ([_]VisualStudioProfiles{ .newest, .all }) |mode| {
        var complete = true;
        const profiles = try testVsProfiles(alloc, mode, .x64, source, host, &complete);
        defer deinitProfiles(alloc, profiles);
        try testing.expect(complete);
        try expectProfileKeys(profiles, &.{ "vs:6bb7cfd9:cmd", "vs:6bb7cfd9:pwsh", "vs:486bb794:cmd", "vs:486bb794:pwsh" });
        const labels = [_][]const u8{
            "Developer Command Prompt for VS 18",
            "Developer PowerShell for VS 18",
            "Developer Command Prompt for VS 2022",
            "Developer PowerShell for VS 2022",
        };
        const kinds = [_]ProfileKind{ .vs_dev_cmd, .vs_dev_shell, .vs_dev_cmd, .vs_dev_shell };
        for (profiles, labels, kinds, 0..) |profile, label, kind, index| {
            try testing.expectEqualStrings(label, profile.label);
            try testing.expectEqual(kind, profile.kind);
            try testing.expectEqual(mode == .newest and index >= 2, profile.hidden);
            // Home, as every detected profile, and no environment of its own.
            try testing.expect(profile.working_directory == null);
            try testing.expectEqual(kind == .vs_dev_cmd, profile.user != null);
            if (profile.user) |launch| try testing.expectEqual(@as(usize, 0), launch.env.len);
        }
        // cmd's own form of the argv, which Exec launches as written.
        try testing.expectEqualStrings(
            test_cmd ++ " /k \"\"" ++ test_vs18_root ++ "\\Common7\\Tools\\VsDevCmd.bat\" -startdir=none -arch=x64 -host_arch=x64\"",
            profiles[0].user.?.command_line,
        );
        try expectArgv(profiles[0], &.{ test_cmd, "/k", test_vs18_root ++ "\\Common7\\Tools\\VsDevCmd.bat", "-startdir=none", "-arch=x64", "-host_arch=x64" });
        try expectArgv(profiles[1], &.{ test_pwsh, "-NoExit", "-Command", vs18_script });
        try expectArgv(profiles[2], &.{ test_cmd, "/k", test_vs2022_root ++ "\\Common7\\Tools\\VsDevCmd.bat", "-startdir=none", "-arch=x64", "-host_arch=x64" });
        try expectArgv(profiles[3], &.{ test_pwsh, "-NoExit", "-Command", vs2022_script });
    }

    // On ARM64 the tools run natively from 17.4, under x64 before.
    {
        var vs17_3 = test_vs2022;
        vs17_3.version = visual_studio.version(17, 3);
        const profiles = try testVsProfiles(alloc, .all, .arm64, .{ .instances = &.{ test_vs18, vs17_3 }, .queries = &source_queries }, host, null);
        defer deinitProfiles(alloc, profiles);
        try expectArgv(profiles[0], &.{ test_cmd, "/k", test_vs18_root ++ "\\Common7\\Tools\\VsDevCmd.bat", "-startdir=none", "-arch=arm64", "-host_arch=arm64" });
        try testing.expect(std.mem.endsWith(u8, profiles[1].command.direct[3], "-DevCmdArguments '-arch=arm64 -host_arch=arm64'}"));
        try expectArgv(profiles[2], &.{ test_cmd, "/k", test_vs2022_root ++ "\\Common7\\Tools\\VsDevCmd.bat", "-startdir=none", "-arch=arm64", "-host_arch=x64" });
        try testing.expect(std.mem.endsWith(u8, profiles[3].command.direct[3], "-DevCmdArguments '-arch=arm64 -host_arch=x64'}"));
    }

    // `none` asks nothing at all.
    source_queries = 0;
    host_queries = 0;
    const none = try testVsProfiles(alloc, .none, .x64, source, host, null);
    defer deinitProfiles(alloc, none);
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expectEqual(@as(usize, 0), source_queries);
    try testing.expectEqual(@as(usize, 0), host_queries);
}

test "a Visual Studio install gets each developer shell only when its script is there" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;

    // No VsDevCmd.bat: no Command Prompt, and the PowerShell is still there.
    {
        const paths = [_][]const u8{ test_vs18_root, test_vs18_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll" };
        const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{test_vs18}, .queries = &queries }, .{ .paths = &paths, .queries = &queries }, null);
        defer deinitProfiles(alloc, profiles);
        try expectProfileKeys(profiles, &.{"vs:6bb7cfd9:pwsh"});
    }
    // Before 16.2 there is no Developer PowerShell, even with a module.
    {
        var vs16_1 = test_vs18;
        vs16_1.version = visual_studio.version(16, 1);
        const paths = [_][]const u8{
            test_vs18_root,
            test_vs18_root ++ "\\Common7\\Tools\\VsDevCmd.bat",
            test_vs18_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll",
            test_vs18_root ++ "\\Common7\\Tools\\vsdevshell\\Microsoft.VisualStudio.DevShell.dll",
        };
        const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{vs16_1}, .queries = &queries }, .{ .paths = &paths, .queries = &queries }, null);
        defer deinitProfiles(alloc, profiles);
        try expectProfileKeys(profiles, &.{"vs:6bb7cfd9:cmd"});
    }
    // 16.2 kept the module in `vsdevshell\`; 16.3 moved it.
    {
        var vs16_2 = test_vs18;
        vs16_2.version = visual_studio.version(16, 2);
        const old_module = test_vs18_root ++ "\\Common7\\Tools\\vsdevshell\\Microsoft.VisualStudio.DevShell.dll";
        const paths = [_][]const u8{ test_vs18_root, old_module };
        const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{vs16_2}, .queries = &queries }, .{ .paths = &paths, .queries = &queries }, null);
        defer deinitProfiles(alloc, profiles);
        try expectProfileKeys(profiles, &.{"vs:6bb7cfd9:pwsh"});
        try testing.expect(std.mem.startsWith(u8, profiles[0].command.direct[3], "&{Import-Module '" ++ old_module ++ "';"));
    }
    // No install folder: nothing, though its files answer.
    {
        const paths = test_vs_paths[1..3];
        const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{test_vs18}, .queries = &queries }, .{ .paths = paths, .queries = &queries }, null);
        defer deinitProfiles(alloc, profiles);
        try testing.expectEqual(@as(usize, 0), profiles.len);
    }
    // An id that could not go in a key or a script: nothing.
    {
        var odd = test_vs18;
        odd.id = "6bb7cfd9'; calc";
        const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{odd}, .queries = &queries }, .{ .paths = &test_vs_paths, .queries = &queries }, null);
        defer deinitProfiles(alloc, profiles);
        try testing.expectEqual(@as(usize, 0), profiles.len);
    }
}

test "under newest the first install that makes a profile stays shown" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;
    // The newest lacks both scripts (a broken install): the next is shown.
    const paths = [_][]const u8{ test_vs18_root, test_vs2022_root, test_vs2022_root ++ "\\Common7\\Tools\\VsDevCmd.bat" };
    const profiles = try testVsProfiles(alloc, .newest, .x64, .{ .instances = &.{ test_vs18, test_vs2022 }, .queries = &queries }, .{ .paths = &paths, .queries = &queries }, null);
    defer deinitProfiles(alloc, profiles);
    try expectProfileKeys(profiles, &.{"vs:486bb794:cmd"});
    try testing.expect(!profiles[0].hidden);
}

test "the Developer Command Prompt carries cmd's own line, which Exec keeps only for its argv" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;
    // `Command.zig` runs this line through cmd ("a Developer Command Prompt
    // line runs its batch file through cmd whatever the install path holds").
    const root = "C:\\VS&calc";
    var odd = test_vs18;
    odd.path = root;
    const paths = [_][]const u8{ root, root ++ "\\Common7\\Tools\\VsDevCmd.bat" };
    const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{odd}, .queries = &queries }, .{ .paths = &paths, .queries = &queries }, null);
    defer deinitProfiles(alloc, profiles);
    const line = profiles[0].user.?.command_line;
    try testing.expectEqualStrings(test_cmd ++ " /k \"\"C:\\VS&calc\\Common7\\Tools\\VsDevCmd.bat\" -startdir=none -arch=x64 -host_arch=x64\"", line);
    // Not the argv's split, but its cmd form, so the launch uses it.
    try testing.expectEqualStrings(line, (try verbatimCommandLine(alloc, line, profiles[0].command.direct, false)).?);
    // Any other argv (integration, `initial-command`) drops it.
    const other = [_][:0]const u8{ test_cmd, "/k", "C:\\VS&calc\\Common7\\Tools\\VsDevCmd.bat", "-startdir=none" };
    try testing.expect((try verbatimCommandLine(alloc, line, &other, false)) == null);
    try testing.expect((try verbatimCommandLine(alloc, line, profiles[0].command.direct, true)) == null);

    // A program path with a space is quoted; anything but `/k` and plain
    // arguments has no such form.
    const spaced = (try cmdKeepOpenLine(alloc, &.{ "C:\\W s\\cmd.exe", "/K", "C:\\a b\\x.bat" })).?;
    defer alloc.free(spaced);
    try testing.expectEqualStrings("\"C:\\W s\\cmd.exe\" /K \"\"C:\\a b\\x.bat\"\"", spaced);
    for ([_][]const []const u8{
        &.{ "cmd.exe", "/c", "x.bat" },
        &.{ "cmd.exe", "/k" },
        &.{ "cmd.exe", "/k", "x\".bat" },
        &.{ "cmd.exe", "/k", "x.bat", "a b" },
        &.{ "cmd.exe", "/k", "x.bat", "a&b" },
        &.{ "cmd.exe", "/k", "x.bat", "%PATH%" },
        &.{ "cmd.exe", "/k", "x.bat", "" },
    }) |argv| try testing.expect((try cmdKeepOpenLine(alloc, argv)) == null);
}

test "Developer PowerShell runs pwsh when it is installed, else Windows PowerShell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;
    for ([_]bool{ true, false }) |pwsh| {
        const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{test_vs18}, .queries = &queries }, .{ .paths = &test_vs_paths, .pwsh = pwsh, .queries = &queries }, null);
        defer deinitProfiles(alloc, profiles);
        try testing.expectEqualStrings(if (pwsh) test_pwsh else test_windows_powershell, profiles[1].command.direct[0]);
    }
}

test "a Visual Studio path with quotes and dollar signs reaches PowerShell as written" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;
    const root = "D:\\VS 'Pro' $env:TEMP `n";
    var odd = test_vs18;
    odd.path = root;
    const paths = [_][]const u8{ root, root ++ "\\Common7\\Tools\\VsDevCmd.bat", root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll" };
    const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{odd}, .queries = &queries }, .{ .paths = &paths, .queries = &queries }, null);
    defer deinitProfiles(alloc, profiles);
    // The batch file is one argument, and quoted in the line cmd reads.
    try testing.expectEqualStrings(root ++ "\\Common7\\Tools\\VsDevCmd.bat", profiles[0].command.direct[2]);
    try testing.expect(std.mem.indexOf(u8, profiles[0].user.?.command_line, " /k \"\"" ++ root ++ "\\Common7") != null);
    try testing.expectEqualStrings(
        "&{Import-Module 'D:\\VS ''Pro'' $env:TEMP `n\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll'; Enter-VsDevShell 6bb7cfd9 -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        profiles[1].command.direct[3],
    );
}

test "Visual Studio names carry the nickname or a channel that is not Release" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;
    var nicknamed = test_vs18;
    nicknamed.suffix = "18 (Work)";
    var preview = test_vs2022;
    preview.suffix = "2022 [Preview]";
    const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{ nicknamed, preview }, .queries = &queries }, .{ .paths = &test_vs_paths, .queries = &queries }, null);
    defer deinitProfiles(alloc, profiles);
    try testing.expectEqualStrings("Developer Command Prompt for VS 18 (Work)", profiles[0].label);
    try testing.expectEqualStrings("Developer PowerShell for VS 18 (Work)", profiles[1].label);
    try testing.expectEqualStrings("Developer Command Prompt for VS 2022 [Preview]", profiles[2].label);
    try testing.expectEqualStrings("Developer PowerShell for VS 2022 [Preview]", profiles[3].label);
}

test "Visual Studio installs on a share or behind a link are skipped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;

    // A share is refused before anything is asked of it.
    for ([_][]const u8{ "\\\\server\\share\\VS\\18", "//server/share/VS", "\\\\?\\UNC\\server\\share\\VS", "Program Files\\VS" }) |root| {
        var remote = test_vs18;
        remote.path = root;
        var host_queries: usize = 0;
        const all_paths = [_][]const u8{root};
        const profiles = try testVsProfiles(alloc, .all, .x64, .{ .instances = &.{remote}, .queries = &queries }, .{ .paths = &all_paths, .queries = &host_queries }, null);
        defer deinitProfiles(alloc, profiles);
        try testing.expectEqual(@as(usize, 0), profiles.len);
        try testing.expectEqual(@as(usize, 0), host_queries);
    }

    // Through the real file checks: an install reached by a junction is
    // refused, the same install by its own path is listed.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("real/Common7/Tools");
    try tmp.dir.makePath("link");
    try tmp.dir.writeFile(.{ .sub_path = "real/Common7/Tools/VsDevCmd.bat", .data = "@echo off" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const real = try std.fmt.allocPrint(alloc, "{s}\\real", .{root});
    defer alloc.free(real);
    const link = try std.fmt.allocPrint(alloc, "{s}\\link", .{root});
    defer alloc.free(link);
    try testMakeJunction(alloc, link, real);
    const lookup_host: TestVsHost = .{ .paths = &.{}, .queries = &queries };
    const Real = struct {
        lookups: TestVsHost,
        pub fn installDirectory(_: @This(), path: []const u8) bool {
            return (VisualStudioHost{}).installDirectory(path);
        }
        pub fn file(_: @This(), path: []const u8) bool {
            return (VisualStudioHost{}).file(path);
        }
        pub fn lookup(self: @This(), a: Allocator, exe: []const u8) !?[]u8 {
            return try self.lookups.lookup(a, exe);
        }
    };
    for ([_]struct { path: []const u8, listed: bool }{ .{ .path = real, .listed = true }, .{ .path = link, .listed = false } }) |case| {
        var local = test_vs18;
        local.path = case.path;
        const profiles = try appendVisualStudioProfiles(alloc, try alloc.alloc(Profile, 0), .all, .x64, TestVsSource{ .instances = &.{local}, .queries = &queries }, Real{ .lookups = lookup_host }, null);
        defer deinitProfiles(alloc, profiles);
        try testing.expectEqual(@as(usize, if (case.listed) 1 else 0), profiles.len);
    }
}

test "a failed Visual Studio query leaves the list incomplete, and asking again is the retry" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;
    var complete = true;
    const profiles = try testVsProfiles(alloc, .newest, .x64, .{ .complete = false, .queries = &queries }, .{ .paths = &.{}, .queries = &queries }, &complete);
    defer deinitProfiles(alloc, profiles);
    try testing.expect(!complete);
    // No Visual Studio at all is a complete answer.
    complete = true;
    const none = try testVsProfiles(alloc, .newest, .x64, .{ .queries = &queries }, .{ .paths = &.{}, .queries = &queries }, &complete);
    defer deinitProfiles(alloc, none);
    try testing.expect(complete);
}

test "Visual Studio profile listing frees what it built when an allocation fails" {
    var queries: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const alloc = failing.allocator();
        const start = alloc.alloc(Profile, 0) catch continue;
        const profiles = appendVisualStudioProfiles(alloc, start, .newest, .x64, TestVsSource{ .instances = &.{ test_vs18, test_vs2022 }, .queries = &queries }, TestVsHost{ .paths = &test_vs_paths, .queries = &queries }, null) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        deinitProfiles(alloc, profiles);
        break;
    }
}

/// `appendLaterProfiles`'s stages with a fake Visual Studio (`Source`,
/// `Host`) or the real one, and one SSH host, `prod`.
fn TestStages(comptime Source: type, comptime Host: type) type {
    return struct {
        environment: TestEnvironment = .{},
        arch: visual_studio.Arch = .x64,
        visual_studio: Source,
        visual_studio_host: Host,

        pub fn ssh(_: @This(), alloc: Allocator, profiles: []Profile, _: ?*bool) ![]Profile {
            const hosts = [_]windows_ssh_hosts.Host{.{ .alias = "prod" }};
            return try appendSshProfiles(alloc, profiles, &hosts, "C:\\Windows\\System32\\OpenSSH\\ssh.exe");
        }
    };
}

/// One detected shell, Command Prompt, for `appendLaterProfiles`.
fn testShellProfiles(alloc: Allocator) ![]Profile {
    const shell = try alloc.alloc(Profile, 1);
    errdefer alloc.free(shell);
    shell[0] = try makeProfile(alloc, .cmd, "cmd.exe", "Command Prompt", &.{test_cmd});
    return shell;
}

test "Visual Studio profiles list after the user's and before SSH, the hidden ones last" {
    // The stages `listProfiles` and `discoverProfiles` run after the local
    // shells, with a fake Visual Studio.
    const testing = std.testing;
    const alloc = testing.allocator;
    var queries: usize = 0;
    const definitions = [_]UserProfiles.Definition{.{ .id = "py", .command = "cmd.exe /k py" }};
    var user: UserProfiles = .{ .arena = .init(alloc), .definitions = &definitions };
    defer user.deinit();
    const stages: TestStages(TestVsSource, TestVsHost) = .{
        .visual_studio = .{ .instances = &.{ test_vs2022, test_vs18 }, .queries = &queries },
        .visual_studio_host = .{ .paths = &test_vs_paths, .queries = &queries },
    };

    // `all` shows both installs' pairs, newest first.
    user.visual_studio = .all;
    {
        const profiles = try appendLaterProfiles(alloc, try testShellProfiles(alloc), &user, stages, null);
        defer deinitProfiles(alloc, profiles);
        try expectProfileKeys(profiles, &.{ "cmd.exe", "user:py", "vs:6bb7cfd9:cmd", "vs:6bb7cfd9:pwsh", "vs:486bb794:cmd", "vs:486bb794:pwsh", "ssh:prod" });
        try testing.expectEqual(@as(usize, 7), visibleProfileCount(profiles));
    }
    // `none` asks nothing.
    user.visual_studio = .none;
    queries = 0;
    {
        const profiles = try appendLaterProfiles(alloc, try testShellProfiles(alloc), &user, stages, null);
        defer deinitProfiles(alloc, profiles);
        try expectProfileKeys(profiles, &.{ "cmd.exe", "user:py", "ssh:prod" });
        try testing.expectEqual(@as(usize, 0), queries);
    }

    // `newest`, nothing else set: the older install's pair goes after SSH,
    // hidden.
    user.visual_studio = .newest;
    var complete = true;
    const profiles = try appendLaterProfiles(alloc, try testShellProfiles(alloc), &user, stages, &complete);
    defer deinitProfiles(alloc, profiles);
    try testing.expect(complete);
    try expectProfileKeys(profiles, &.{ "cmd.exe", "user:py", "vs:6bb7cfd9:cmd", "vs:6bb7cfd9:pwsh", "ssh:prod", "vs:486bb794:cmd", "vs:486bb794:pwsh" });
    try testing.expectEqual(@as(usize, 5), visibleProfileCount(profiles));
    // A key names a Visual Studio profile, in any case, to order or hide it.
    arrangeProfiles(profiles, &.{"VS:6BB7CFD9:PWSH"}, &.{"vs:6bb7cfd9:cmd"});
    try expectProfileKeys(profiles, &.{ "vs:6bb7cfd9:pwsh", "cmd.exe", "user:py", "ssh:prod", "vs:6bb7cfd9:cmd", "vs:486bb794:cmd", "vs:486bb794:pwsh" });
    // `vs:newest:*` names the newest instance's shells, resolved before the
    // sort moves anything, whichever order the lines come in.
    for (profiles) |*profile| profile.hidden = std.mem.startsWith(u8, profile.key, "vs:486bb794");
    arrangeProfiles(profiles, &.{ "ssh:prod", "vs:newest:pwsh", "vs:newest:cmd" }, &.{"VS:NEWEST:CMD"});
    try expectProfileKeys(profiles, &.{ "ssh:prod", "vs:6bb7cfd9:pwsh", "cmd.exe", "user:py", "vs:6bb7cfd9:cmd", "vs:486bb794:cmd", "vs:486bb794:pwsh" });
    // Discovery marked the newest instance's shells, so a list that puts the
    // older instance first (`profile-order`, the Settings rows), arranged
    // again or copied, still resolves to the newest.
    try testing.expectEqual(@as(usize, 4), visibleProfileCount(profiles));
    for (profiles) |*profile| profile.hidden = false;
    arrangeProfiles(profiles, &.{ "vs:486bb794:cmd", "vs:486bb794:pwsh" }, &.{});
    try testing.expectEqualStrings("vs:486bb794:cmd", profiles[0].key);
    const copied = try cloneProfiles(alloc, profiles);
    defer deinitProfiles(alloc, copied);
    for ([_][]const Profile{ profiles, copied }) |list| {
        const newest: NewestVisualStudio = .of(list);
        try testing.expectEqualStrings("vs:6bb7cfd9:cmd", newest.resolve("vs:newest:cmd").?);
        try testing.expectEqualStrings("vs:6bb7cfd9:pwsh", newest.resolve("vs:newest:pwsh").?);
    }
}

test "the machine's Visual Studio shells, through the stages a listing runs" {
    // Real Setup Configuration and file checks, between a fake shell and a
    // fake SSH host (no WSL probe, no SSH config). Only enumerates and looks
    // at files. A machine without Visual Studio skips.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    // Skip where Setup Configuration is absent, lists nothing, or does not
    // answer in full (a stale registration, an unreadable instance).
    const found = try visual_studio.ComSource.query(.{}, arena.allocator());
    if (!found.complete or found.instances.len == 0) return error.SkipZigTest;
    var user: UserProfiles = .{ .arena = .init(alloc) };
    defer user.deinit();
    const stages: TestStages(visual_studio.ComSource, VisualStudioHost) = .{
        .arch = visual_studio.build_arch,
        .visual_studio = .{},
        .visual_studio_host = .{},
    };
    for ([_]VisualStudioProfiles{ .newest, .all, .none }) |mode| {
        user.visual_studio = mode;
        var complete = true;
        const profiles = try appendLaterProfiles(alloc, try testShellProfiles(alloc), &user, stages, &complete);
        defer deinitProfiles(alloc, profiles);
        if (!complete) return error.SkipZigTest;
        const shown = visibleProfiles(profiles);
        try testing.expectEqualStrings("cmd.exe", shown[0].key);
        try testing.expectEqualStrings("ssh:prod", shown[shown.len - 1].key);
        var vs_count: usize = 0;
        for (profiles) |profile| {
            if (!std.mem.startsWith(u8, profile.key, "vs:")) continue;
            vs_count += 1;
            try testing.expect(profile.kind == .vs_dev_cmd or profile.kind == .vs_dev_shell);
            try testing.expect(std.mem.startsWith(u8, profile.label, "Developer "));
        }
        if (mode == .none) {
            try testing.expectEqual(@as(usize, 2), profiles.len);
            continue;
        }
        // Every shown one is between the shell and SSH; under `newest` they
        // are one instance's, and every other instance's are hidden, last.
        var shown_vs: usize = 0;
        var first_id: ?[]const u8 = null;
        for (shown[1 .. shown.len - 1]) |profile| {
            try testing.expect(std.mem.startsWith(u8, profile.key, "vs:"));
            shown_vs += 1;
            const id = profile.key[3..std.mem.lastIndexOfScalar(u8, profile.key, ':').?];
            if (first_id) |want| {
                if (mode == .newest) try testing.expectEqualStrings(want, id);
            } else first_id = id;
        }
        if (mode == .all) try testing.expectEqual(vs_count, shown_vs);
        if (mode == .newest and vs_count > 0) {
            try testing.expect(shown_vs > 0);
            for (profiles[shown.len..]) |profile| {
                try testing.expect(profile.hidden);
                try testing.expect(!std.mem.containsAtLeast(u8, profile.key, 1, first_id.?));
            }
        }
        if (std.process.hasEnvVarConstant("NOCTTY_PRINT_VISUAL_STUDIO_PROFILES")) {
            std.debug.print("visual-studio-profiles = {s}: {d} shown, {d} hidden\n", .{ @tagName(mode), shown_vs, vs_count - shown_vs });
            for (profiles) |profile| {
                if (std.mem.startsWith(u8, profile.key, "vs:")) std.debug.print("  {s} {s}{s}\n", .{ profile.key, profile.label, if (profile.hidden) " (hidden)" else "" });
            }
        }
    }
}

test "a Visual Studio key resolves through the host's instances, hidden ones too" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lookups: usize = 0;
    var wsl_probes: usize = 0;
    var wsl_lists: usize = 0;
    const Host = struct {
        base: TestReferenceHost,
        mode: VisualStudioProfiles,
        queries: *usize,
        answers: bool = true,
        /// What a partial answer (`answers` false) still lists.
        partial: []const visual_studio.Instance = &.{test_vs18},
        pub fn lookup(self: @This(), a: Allocator, exe: []const u8) !?[]u8 {
            return try self.base.lookup(a, exe);
        }
        pub fn gitBash(self: @This(), a: Allocator) !?[]u8 {
            return try self.base.gitBash(a);
        }
        pub fn sshExecutable(self: @This(), a: Allocator) !?[]u8 {
            return try self.base.sshExecutable(a);
        }
        pub fn get(self: @This(), a: Allocator, name: []const u8) Allocator.Error!?[]u8 {
            return try self.base.get(a, name);
        }
        pub fn visualStudio(self: @This(), a: Allocator, complete: *bool) ![]Profile {
            const instances: []const visual_studio.Instance = if (self.answers) &.{ test_vs18, test_vs2022 } else self.partial;
            return try testVsProfiles(a, self.mode, .x64, .{ .instances = instances, .complete = self.answers, .queries = self.queries }, .{ .paths = &test_vs_paths, .queries = self.queries }, complete);
        }
    };
    var queries: usize = 0;
    const base: TestReferenceHost = .{ .lookups = &lookups, .wsl_probes = &wsl_probes, .wsl_lists = &wsl_lists };
    const host: Host = .{ .base = base, .mode = .newest, .queries = &queries };
    for ([_][3][]const u8{
        .{ "vs:6bb7cfd9:cmd", "vs:6bb7cfd9:cmd", test_cmd },
        .{ "VS:6BB7CFD9:PWSH", "vs:6bb7cfd9:pwsh", test_pwsh },
        // Hidden under `newest`, and still a default profile.
        .{ "vs:486bb794:cmd", "vs:486bb794:cmd", test_cmd },
    }) |case| {
        var profile = (try resolveProfileReference(alloc, case[0], &.{}, host)).?;
        defer profile.deinit(alloc);
        try testing.expectEqualStrings(case[1], profile.key);
        try testing.expectEqualStrings(case[2], profile.command.direct[0]);
    }
    for ([_][]const u8{ "vs:", "vs:6bb7cfd9", "vs:6bb7cfd9:bash", "vs:00000000:cmd" }) |ref| {
        try testing.expect((try resolveProfileReference(alloc, ref, &.{}, host)) == null);
    }
    // `none`, and a host that cannot ask Visual Studio, name nothing.
    try testing.expect((try resolveProfileReference(alloc, "vs:6bb7cfd9:cmd", &.{}, Host{ .base = base, .mode = .none, .queries = &queries })) == null);
    try testing.expect((try resolveProfileReference(alloc, "vs:6bb7cfd9:cmd", &.{}, base)) == null);
    // A query that failed part way still resolves what it found, and does
    // not say the rest is absent.
    const partial: Host = .{ .base = base, .mode = .newest, .queries = &queries, .answers = false };
    var found = (try resolveProfileReference(alloc, "vs:6bb7cfd9:cmd", &.{}, partial)).?;
    found.deinit(alloc);
    try testing.expectError(error.VisualStudioUnavailable, resolveProfileReference(alloc, "vs:486bb794:cmd", &.{}, partial));
    try testing.expectEqual(@as(usize, 0), wsl_probes + wsl_lists);

    // `vs:newest:<shell>`: the newest instance (18.10 before 17.14) under
    // `newest` and `all`, as its concrete key; nothing under `none`.
    for ([_]VisualStudioProfiles{ .newest, .all }) |mode| {
        for ([_][2][]const u8{
            .{ "vs:newest:cmd", "vs:6bb7cfd9:cmd" },
            .{ "VS:Newest:PWSH", "vs:6bb7cfd9:pwsh" },
        }) |case| {
            var profile = (try resolveProfileReference(alloc, case[0], &.{}, Host{ .base = base, .mode = mode, .queries = &queries })).?;
            defer profile.deinit(alloc);
            try testing.expectEqualStrings(case[1], profile.key);
        }
    }
    for ([_][]const u8{ "vs:newest:cmd", "vs:newest:pwsh" }) |ref| {
        try testing.expect((try resolveProfileReference(alloc, ref, &.{}, Host{ .base = base, .mode = .none, .queries = &queries })) == null);
    }
    try testing.expect((try resolveProfileReference(alloc, "vs:newest:bash", &.{}, host)) == null);
    // A partial answer may lack the newest instance: `vs:newest` names
    // none, rather than an older instance that panes would then remember,
    // whether the newest came back (18) or not (2022 alone).
    for ([_][]const visual_studio.Instance{ &.{test_vs2022}, &.{test_vs18} }) |instances| {
        const lacking: Host = .{ .base = base, .mode = .newest, .queries = &queries, .answers = false, .partial = instances };
        for ([_][]const u8{ "vs:newest:cmd", "VS:NEWEST:PWSH" }) |ref| {
            try testing.expectError(error.VisualStudioUnavailable, resolveProfileReference(alloc, ref, &.{}, lacking));
        }
    }
    var older = (try resolveProfileReference(alloc, "vs:486bb794:cmd", &.{}, Host{ .base = base, .mode = .newest, .queries = &queries, .answers = false, .partial = &.{test_vs2022} })).?;
    older.deinit(alloc);
}

test "vs:newest skips an instance without that shell's script" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // The newest instance (18) has no VsDevCmd.bat, only the DevShell module:
    // `vs:newest:cmd` is 2022's prompt, `vs:newest:pwsh` 18's PowerShell.
    var queries: usize = 0;
    const paths = [_][]const u8{
        test_vs18_root,
        test_vs18_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll",
        test_vs2022_root,
        test_vs2022_root ++ "\\Common7\\Tools\\VsDevCmd.bat",
        test_vs2022_root ++ "\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll",
    };
    for ([_]VisualStudioProfiles{ .newest, .all }) |mode| {
        const profiles = try testVsProfiles(alloc, mode, .x64, .{ .instances = &.{ test_vs18, test_vs2022 }, .queries = &queries }, .{ .paths = &paths, .queries = &queries }, null);
        defer deinitProfiles(alloc, profiles);
        const newest: NewestVisualStudio = .of(profiles);
        try testing.expectEqualStrings("vs:486bb794:cmd", newest.resolve("vs:newest:cmd").?);
        try testing.expectEqualStrings("vs:6bb7cfd9:pwsh", newest.resolve("vs:newest:pwsh").?);
        try testing.expect(newest.resolve("vs:6bb7cfd9:cmd") == null);
    }
    // No Visual Studio shell at all: they name nothing.
    try testing.expectEqualStrings("", (NewestVisualStudio{}).resolve("vs:newest:cmd").?);
}

/// The profile that is the shell `defaultCommand` chose, so the picker's
/// starting selection names what a new tab really runs instead of the first
/// entry in the list (WSL, when it is installed). Null when the command is
/// none of the three shells it chooses between, or the list has no such profile.
pub fn profileIndexForDefaultCommand(profiles: []const Profile, command: Command) ?usize {
    if (command != .direct or command.direct.len == 0) return null;
    const base = std.fs.path.basename(command.direct[0]);
    const kind: ProfileKind = if (std.ascii.eqlIgnoreCase(base, "pwsh.exe"))
        .pwsh
    else if (std.ascii.eqlIgnoreCase(base, "powershell.exe"))
        .powershell
    else if (std.ascii.eqlIgnoreCase(base, "cmd.exe"))
        .cmd
    else
        return null;
    for (profiles, 0..) |profile, index| {
        if (profile.kind == kind) return index;
    }
    return null;
}

pub fn deinitProfiles(alloc: Allocator, profiles: []Profile) void {
    for (profiles) |*profile| profile.deinit(alloc);
    alloc.free(profiles);
}

/// Deep-copy `profiles` into `alloc` (a discovery that ran on another
/// thread allocates from its own allocator).
pub fn cloneProfiles(alloc: Allocator, profiles: []const Profile) ![]Profile {
    const out = try alloc.alloc(Profile, profiles.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |*profile| profile.deinit(alloc);
        alloc.free(out);
    }
    for (profiles, out) |src, *dst| {
        dst.* = try src.clone(alloc);
        copied += 1;
    }
    return out;
}

test "cloneProfiles copies every field into the target allocator" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src_alloc = arena.allocator();
    const argv = try src_alloc.alloc([:0]const u8, 2);
    argv[0] = try src_alloc.dupeZ(u8, "wsl.exe");
    argv[1] = try src_alloc.dupeZ(u8, "-d");
    const source = [_]Profile{
        .{ .kind = .pwsh, .key = "pwsh", .label = "PowerShell", .command = .{ .shell = try src_alloc.dupeZ(u8, "pwsh.exe") } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "Ubuntu", .palette_title = "WSL: Ubuntu", .command = .{ .direct = argv } },
    };
    const copy = try cloneProfiles(testing.allocator, &source);
    // Freeing the copy with the testing allocator proves nothing still
    // points into the arena.
    defer deinitProfiles(testing.allocator, copy);
    try testing.expectEqual(source.len, copy.len);
    for (source, copy) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqualStrings(a.key, b.key);
        try testing.expectEqualStrings(a.label, b.label);
        try testing.expect(a.key.ptr != b.key.ptr);
    }
    try testing.expectEqualStrings("WSL: Ubuntu", copy[1].palette_title.?);
    try testing.expectEqualStrings("-d", copy[1].command.direct[1]);
    try testing.expectEqualStrings("pwsh.exe", copy[0].command.shell);
}

test "cloneProfiles frees what it copied when an allocation fails" {
    const source = [_]Profile{
        .{ .kind = .pwsh, .key = "pwsh", .label = "PowerShell", .palette_title = "PS", .command = .{ .shell = "pwsh.exe" } },
        .{ .kind = .powershell, .key = "powershell", .label = "Windows PowerShell", .command = .{ .shell = "powershell.exe" } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "Ubuntu", .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } } },
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const copy = cloneProfiles(failing.allocator(), &source) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        deinitProfiles(failing.allocator(), copy);
        break;
    }
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
        .vs_dev_cmd => .{
            .support = .automatic,
            .summary = "Visual Studio Developer Command Prompt with PROMPT-based shell integration; Clink adds command-start/finish and exit-code marks",
        },
        .vs_dev_shell => .{
            .support = .unavailable,
            .summary = "Visual Studio Developer PowerShell; it starts through -Command, which runs without OSC 133 and OSC 7 marks, as in Windows Terminal",
        },
        .user => .{
            .support = .manual,
            .summary = "User profile; shell integration follows the program it runs",
            .next_step = "Start a shell noctty integrates (PowerShell, cmd, Git Bash) or enable integration in the program's own startup.",
        },
    };
}

/// `shellIntegrationDiagnostic` for one profile. A user profile can run
/// anything, so its diagnostic is the one of the shell its argv[0] names, as
/// the launch's own shell detection (`detectShell`) sees it.
pub fn profileShellIntegrationDiagnostic(alloc: Allocator, profile: *const Profile) Allocator.Error!ShellIntegrationDiagnostic {
    if (profile.kind != .user) return shellIntegrationDiagnostic(profile.kind);
    const shell = (try @import("../termio/shell_integration.zig").detectShell(alloc, profile.command)) orelse
        return shellIntegrationDiagnostic(.user);
    return switch (shell) {
        .powershell => .{
            .support = .automatic,
            .summary = "User profile running PowerShell; automatic shell integration applies unless the line passes -Command or -File",
            .next_step = "A -Command or -File line runs without OSC 133 and OSC 7 marks, as in Windows Terminal.",
        },
        .cmd => shellIntegrationDiagnostic(.cmd),
        else => .{
            .support = .automatic,
            .summary = "User profile running a shell with automatic shell integration",
        },
    };
}

/// Config string quoting is removed before Command parsing. Recover a whole
/// executable path before splitting it, while preserving actual cmd strings.
/// The result may borrow command; new argv storage belongs to the arena.
pub fn executableCommand(alloc: Allocator, command: Command) !Command {
    if (builtin.os.tag != .windows or command == .direct) return command;
    const path = stripOuterQuotes(std.mem.trim(u8, command.shell, " \t"));
    // A relative executable is resolved against the pane's cwd by cmd, not
    // the app's cwd used by this probe and lpApplicationName. Keep that
    // existing contract, including drive-relative and root-relative values.
    if (!isDriveAbsolutePath(path)) return command;
    if (!isExeOrCom(std.fs.path.extension(path))) return command;
    // Screen these before querying attributes. A command value must not
    // introduce a network timeout on the terminal's startup path.
    if (!isOnLocalDrive(path)) return command;
    if (!windowsNonDirectoryPathExists(path)) return command;
    const argv = try alloc.alloc([:0]const u8, 1);
    errdefer alloc.free(argv);
    argv[0] = try alloc.dupeZ(u8, path);
    return .{ .direct = argv };
}

/// Resolve a bare integration executable using the child's search environment.
/// Never consult the app's PATH or cwd, and never probe a network PATH entry.
/// A batch/script match keeps the caller on its original shell launch path.
pub fn lookupChildExecutable(alloc: Allocator, exe: []const u8, env: *const std.process.EnvMap) !?[:0]const u8 {
    if (builtin.os.tag != .windows or exe.len == 0 or
        std.mem.indexOfAny(u8, exe, "\\/:") != null) return null;
    const path = env.get("PATH") orelse return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = searchPath(&buf, exe, path, env.get("PATHEXT"), false, acceptAnyPath) orelse return null;
    return try alloc.dupeZ(u8, found);
}

fn acceptAnyPath(_: []const u8) bool {
    return true;
}

/// The first file `exe` names in the `path` list (`PATH` syntax), as a slice of
/// `buf`. Only absolute local-drive entries are searched: a relative entry
/// would mean the current directory, and a network or device entry could stall
/// the caller. `pathext` is `PATHEXT` and only matters when `exe` has no
/// extension. `accept` can refuse a file that exists, and then the search goes
/// on in the next directory.
fn searchPath(
    buf: *[std.fs.max_path_bytes]u8,
    exe: []const u8,
    path: []const u8,
    pathext: ?[]const u8,
    comptime discovery: bool,
    accept: anytype,
) ?[]const u8 {
    const error_mode = struct {
        extern "kernel32" fn SetThreadErrorMode(mode: u32, previous: ?*u32) callconv(.winapi) windows.BOOL;
    };
    var previous_mode: u32 = 0;
    const suppressed = error_mode.SetThreadErrorMode(0x0001 | 0x8000, &previous_mode) != 0;
    defer if (suppressed) {
        _ = error_mode.SetThreadErrorMode(previous_mode, null);
    };
    const extension = std.fs.path.extension(exe);
    var dirs = std.mem.splitScalar(u8, path, ';');
    dirs: while (dirs.next()) |raw_dir| {
        const dir = stripOuterQuotes(std.mem.trim(u8, raw_dir, " \t"));
        if (internal_os.path.isNetworkOrDevicePath(dir) or !isDriveAbsolutePath(dir)) continue;
        const drive_type = internal_os.windows.driveTypeForLetter(dir[0]);
        if (drive_type == internal_os.windows.DRIVE_REMOTE) continue;
        // Discovery never spins up removable/optical media on the UI thread.
        if (discovery and drive_type != internal_os.windows.DRIVE_FIXED and
            drive_type != internal_os.windows.DRIVE_RAMDISK) continue;
        if (discovery and !isLocalSearchDirectory(dir)) continue;
        var extensions = std.mem.splitScalar(u8, if (extension.len > 0) "" else pathext orelse ".COM;.EXE;.BAT;.CMD", ';');
        exts: while (extensions.next()) |raw_ext| {
            const ext = std.mem.trim(u8, raw_ext, " \t");
            if (extension.len == 0) {
                if (ext.len < 2 or ext[0] != '.') continue;
                // PATHEXT supplies suffixes, not paths or cmd syntax.
                for (ext[1..]) |c| if (!std.ascii.isAlphanumeric(c)) continue :exts;
            }
            const candidate = std.fmt.bufPrint(buf, "{s}\\{s}{s}", .{ dir, exe, ext }) catch continue;
            if (discovery) {
                const attributes = pathAttributes(candidate) orelse continue;
                if (attributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) continue;
            } else if (!windowsNonDirectoryPathExists(candidate)) continue;
            if (!isExeOrCom(if (extension.len > 0) extension else ext)) return null;
            if (!accept(candidate)) continue :dirs;
            return candidate;
        }
    }
    return null;
}

/// Disable cmd's implicit cwd executable search for the final shell wrapper.
/// Keep this in its environment: clearing it before the target immediately
/// restores cwd lookup. Explicit paths and PATH entries retain cmd semantics.
pub fn configureShellSearch(env: *std.process.EnvMap, windows_cmd_shell: bool) !void {
    if (builtin.os.tag == .windows and windows_cmd_shell and
        env.get("NoDefaultCurrentDirectoryInExePath") == null)
        try env.put("NoDefaultCurrentDirectoryInExePath", "1");
}

test "PKG48 only shell wrappers receive the inherited cwd search guard" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "relative;C:\\Tools!;%literal%");
    try configureShellSearch(&env, false);
    try std.testing.expect(env.get("NoDefaultCurrentDirectoryInExePath") == null);
    try configureShellSearch(&env, true);
    try std.testing.expectEqualStrings("1", env.get("NoDefaultCurrentDirectoryInExePath").?);
    inline for (.{ "user-value", "" }) |value| {
        try env.put("NoDefaultCurrentDirectoryInExePath", value);
        try configureShellSearch(&env, true);
        try std.testing.expectEqualStrings(value, env.get("NoDefaultCurrentDirectoryInExePath").?);
    }
    try std.testing.expectEqualStrings("relative;C:\\Tools!;%literal%", env.get("PATH").?);
}

/// App Execution Aliases are reparse points whose target cannot be opened
/// or stat'ed as an ordinary file. Query the path itself, accepting aliases.
/// Callers must screen network/device paths and remote drives first.
fn windowsNonDirectoryPathExists(path: []const u8) bool {
    // Explicit commands retain Windows link semantics, including Scoop's
    // current junction and paths with spaces. Only discovery refuses redirects.
    const path_w = windows.sliceToPrefixedFileW(null, path) catch return false;
    const attributes = windows.kernel32.GetFileAttributesW(path_w.span().ptr);
    if (attributes == windows.INVALID_FILE_ATTRIBUTES) return false;
    return attributes & windows.FILE_ATTRIBUTE_DIRECTORY == 0;
}

/// Open only the final object, refusing every reparse ancestor in the kernel.
/// FILE_OPEN_REPARSE_POINT lets us inspect a final Store alias without following
/// it. OBJ_DONT_REPARSE prevents even a metadata query from traversing an
/// ancestor link into a share or an unchecked redirect chain.
fn openPathNoRedirect(path: []const u8) ?windows.HANDLE {
    if (!isDriveAbsolutePath(path) or internal_os.path.isNetworkOrDevicePath(path)) return null;
    const drive_type = internal_os.windows.driveTypeForLetter(path[0]);
    if (drive_type != internal_os.windows.DRIVE_FIXED and drive_type != internal_os.windows.DRIVE_RAMDISK) return null;
    var handle: windows.HANDLE = undefined;
    const status = ntOpenDontReparse(
        path,
        windows.FILE_READ_ATTRIBUTES | windows.SYNCHRONIZE,
        windows.FILE_OPEN_REPARSE_POINT | windows.FILE_SYNCHRONOUS_IO_NONALERT,
        &handle,
    ) orelse return null;
    return if (status == .SUCCESS) handle else null;
}

/// `NtCreateFile` opening the existing object at `path` with `access` and
/// `options`, under `OBJ_DONT_REPARSE`, so the kernel refuses to traverse a
/// link at any component. The caller screens `path` first. Null when `path`
/// cannot be named that way; otherwise the status, and on success `handle`
/// is open for the caller to close.
pub fn ntOpenDontReparse(
    path: []const u8,
    access: windows.ACCESS_MASK,
    options: windows.ULONG,
    handle: *windows.HANDLE,
) ?windows.NTSTATUS {
    var wide = windows.sliceToPrefixedFileW(null, path) catch return null;
    // Older Windows also treats the DOS drive-letter mapping as a reparse.
    // Resolve just that mapping without opening a filesystem target, and accept
    // only a direct local volume device. The rest keeps the kernel guard.
    if (!internal_os.windows.directVolumePath(&wide)) return null;
    const span = wide.span();
    var name: windows.UNICODE_STRING = .{
        .Length = @intCast(span.len * 2),
        .MaximumLength = @intCast(span.len * 2),
        .Buffer = @constCast(span.ptr),
    };
    var attrs: windows.OBJECT_ATTRIBUTES = .{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = null,
        .ObjectName = &name,
        .Attributes = 0x1000, // OBJ_DONT_REPARSE
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var io: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtCreateFile(
        handle,
        access,
        &attrs,
        &io,
        null,
        windows.FILE_ATTRIBUTE_NORMAL,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        windows.FILE_OPEN,
        options,
        null,
        0,
    );
}

/// Attributes of the final object, with no ancestor or final link followed.
fn pathInfo(path: []const u8) ?windows.FILE_ATTRIBUTE_TAG_INFO {
    const handle = openPathNoRedirect(path) orelse return null;
    defer windows.CloseHandle(handle);
    var info: windows.FILE_ATTRIBUTE_TAG_INFO = undefined;
    var io: windows.IO_STATUS_BLOCK = undefined;
    if (windows.ntdll.NtQueryInformationFile(handle, &io, &info, @sizeOf(@TypeOf(info)), .FileAttributeTagInformation) != .SUCCESS) return null;
    return info;
}

fn pathAttributes(path: []const u8) ?windows.DWORD {
    return (pathInfo(path) orelse return null).FileAttributes;
}

/// A file `CreateProcess` can start. Besides local data reparse tags, accept an App
/// Execution Alias whose package is installed: the Store's PowerShell and the
/// Python launcher put one on `PATH`, and an alias can stay behind after its
/// package is gone. Following a symlink or junction would open its target,
/// which can be on a network share, so those are not accepted.
/// The caller screens network and device paths first.
fn isLaunchableFile(path: []const u8) bool {
    const info = pathInfo(path) orelse return false;
    if (isLocalExecutableInfo(info)) return true;
    if (info.FileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) return false;
    return appExecLinkTargetExists(path);
}

/// WOF compression and deduplication keep file data on the local volume.
/// Neither is a name redirect or a cloud placeholder that can fetch data.
fn isLocalExecutableInfo(info: windows.FILE_ATTRIBUTE_TAG_INFO) bool {
    if (info.FileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) return false;
    return info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT == 0 or
        info.ReparseTag == 0x80000017 or info.ReparseTag == 0x80000013;
}

/// The reparse data of the open reparse point `handle`, as the slice of `buf`
/// the call filled, or null.
fn readReparseData(handle: windows.HANDLE, buf: []align(4) u8) ?[]const u8 {
    var returned: windows.DWORD = 0;
    if (internal_os.windows.DeviceIoControl(
        handle,
        windows.FSCTL_GET_REPARSE_POINT,
        null,
        0,
        buf.ptr,
        @intCast(buf.len),
        &returned,
        null,
    ) == 0) return null;
    return buf[0..@min(returned, buf.len)];
}

/// Only ordinary local folders are searched. Reparse ancestors are rejected
/// by openPathNoRedirect; final folder links and cloud placeholders are skipped.
fn isLocalSearchDirectory(dir: []const u8) bool {
    const attributes = pathAttributes(dir) orelse return false;
    return attributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0 and
        attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT == 0;
}

const IO_REPARSE_TAG_APPEXECLINK: u32 = 0x8000001b;

/// Whether the alias at `path` points at a file that exists. Reads the alias's
/// reparse data and never launches it (an alias to a missing package can open
/// the Store).
fn appExecLinkTargetExists(path: []const u8) bool {
    const handle = openPathNoRedirect(path) orelse return false;
    defer windows.CloseHandle(handle);
    var target_buf: AppExecLinkTargetBuf = undefined;
    const target = (readAppExecLinkTarget(handle, &target_buf) catch return false) orelse return false;
    // A local file only; the screen is the one for any path a program reports.
    if (!isOnLocalDrive(target)) return false;
    return isLocalExecutableInfo(pathInfo(target) orelse return false);
}

/// Room for the longest alias target `readAppExecLinkTarget` reads, as UTF-8.
const AppExecLinkTargetBuf = [3 * app_exec_link_target_max]u8;
const app_exec_link_target_max = 1024;

/// The target of the App Execution Alias open at `handle`, as UTF-8 in `buf`,
/// or null when the reparse data is not such an alias (see `appExecLinkTarget`).
/// A target that is not valid UTF-16 is an error.
fn readAppExecLinkTarget(handle: windows.HANDLE, buf: *AppExecLinkTargetBuf) std.unicode.Utf16LeToUtf8Error!?[]const u8 {
    var data: [windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = @splat(0);
    const record = readReparseData(handle, &data) orelse return null;
    var target_w: [app_exec_link_target_max]u16 = undefined;
    const target_len = appExecLinkTarget(record, &target_w) orelse return null;
    const target_end = try std.unicode.utf16LeToUtf8(buf, target_w[0..target_len]);
    return buf[0..target_end];
}

/// The target of an App Execution Alias, copied as UTF-16 into `out`, from the
/// output of `FSCTL_GET_REPARSE_POINT`: the reparse header (tag, data length,
/// reserved), a version `3`, and four NUL-terminated UTF-16 strings, namely
/// the package family name, the AppUserModelID, the target path and the
/// application type. Layout as read from the aliases of installed packages
/// (the same one libuv reads). Returns the length of the target, or null for
/// any other tag, a version, or a record that is not exactly those four
/// strings: the buffer is zeroed before the call, so a length header that
/// claims more than the call returned reads as empty strings and fails here.
fn appExecLinkTarget(data: []const u8, out: []u16) ?usize {
    if (data.len < 12 or std.mem.readInt(u32, data[0..4], .little) != IO_REPARSE_TAG_APPEXECLINK) return null;
    const end = 8 + @as(usize, std.mem.readInt(u16, data[4..6], .little));
    if (end > data.len or end < 12 or std.mem.readInt(u32, data[8..12], .little) != 3) return null;
    const strings = data[12..end];
    var index: usize = 0;
    var start: usize = 0;
    var fields: usize = 0;
    var target: []const u8 = &.{};
    while (index + 2 <= strings.len and fields < 4) : (index += 2) {
        if (strings[index] != 0 or strings[index + 1] != 0) continue;
        if (fields == 2) target = strings[start..index];
        fields += 1;
        start = index + 2;
    }
    if (fields != 4 or start != strings.len or target.len == 0 or target.len / 2 > out.len) return null;
    for (0..target.len / 2) |i| out[i] = std.mem.readInt(u16, target[2 * i ..][0..2], .little);
    return target.len / 2;
}

test "PKG08 round2 child executable lookup respects PATHEXT and local PATH" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "nu.exe", .data = "exe" });
    try tmp.dir.writeFile(.{ .sub_path = "nu.com", .data = "com" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    var env = std.process.EnvMap.init(alloc);
    try env.put("PATH", try std.fmt.allocPrint(alloc, "relative;;\\\\server\\share;\\??\\UNC\\server\\share;\"{s}\"", .{dir}));
    try env.put("PATHEXT", ".com;.exe");
    try std.testing.expectEqualStrings(try tmp.dir.realpathAlloc(alloc, "nu.com"), (try lookupChildExecutable(alloc, "nu", &env)).?);
    try env.put("PATHEXT", ".exe;.com");
    try std.testing.expectEqualStrings(try tmp.dir.realpathAlloc(alloc, "nu.exe"), (try lookupChildExecutable(alloc, "nu", &env)).?);
    // An explicit extension is looked up exactly, regardless of PATHEXT.
    try env.put("PATHEXT", ".com");
    try std.testing.expectEqualStrings(try tmp.dir.realpathAlloc(alloc, "nu.exe"), (try lookupChildExecutable(alloc, "nu.exe", &env)).?);
    // Preserve a cmd/batch wrapper that wins PATHEXT instead of skipping it.
    try tmp.dir.writeFile(.{ .sub_path = "nu.cmd", .data = "wrapper" });
    try env.put("PATHEXT", ".cmd;.exe");
    try std.testing.expect(try lookupChildExecutable(alloc, "nu", &env) == null);
    try std.testing.expect(try lookupChildExecutable(alloc, "missing", &env) == null);
    try tmp.dir.makeDir("directory.exe");
    try std.testing.expect(try lookupChildExecutable(alloc, "directory.exe", &env) == null);
    for ([_][]const u8{ "C:nu", ".\\nu", "\\nu", "\\\\server\\nu" }) |value|
        try std.testing.expect(try lookupChildExecutable(alloc, value, &env) == null);
}

test "PKG08 round3 child lookup accepts a real App Execution Alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var host_env = try std.process.getEnvMap(alloc);
    const local_app_data = host_env.get("LOCALAPPDATA") orelse return error.SkipZigTest;
    const dir = try std.fs.path.join(alloc, &.{ local_app_data, "Microsoft", "WindowsApps" });
    if (internal_os.path.isNetworkOrDevicePath(dir) or
        dir.len < 3 or dir[1] != ':' or
        internal_os.windows.driveTypeForLetter(dir[0]) == internal_os.windows.DRIVE_REMOTE)
        return error.SkipZigTest;
    var env = std.process.EnvMap.init(alloc);
    try env.put("PATH", dir);
    try env.put("PATHEXT", ".EXE");
    // These aliases are installed by Store PowerShell or the Windows Python
    // launcher. Do not launch them: an unconfigured alias can open the Store.
    for ([_][]const u8{ "pwsh.exe", "python.exe", "python3.exe" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ dir, name });
        const attributes = windows.GetFileAttributes(path) catch continue;
        if (attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT == 0 or
            attributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) continue;
        const result = try lookupChildExecutable(alloc, name, &env);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings(path, result.?);
        const normalized = try executableCommand(alloc, .{ .shell = try alloc.dupeZ(u8, path) });
        try std.testing.expect(normalized == .direct);
        try std.testing.expectEqualStrings(path, normalized.direct[0]);
        return;
    }
    return error.SkipZigTest;
}

test "PKG08 whole executable path with spaces launches directly" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("PowerShell 7");
    const exe = try tmp.dir.createFile("PowerShell 7/pwsh.exe", .{});
    exe.close();
    const path = try tmp.dir.realpathAlloc(alloc, "PowerShell 7/pwsh.exe");
    const input: Command = .{ .shell = try alloc.dupeZ(u8, path) };
    const result = try prepareCommandWithLookup(std.testing.allocator, input, null, false, false, lookupExecutable);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .direct);
    try std.testing.expectEqual(@as(usize, 1), result.direct.len);
    try std.testing.expectEqualStrings(path, result.direct[0]);
    const current = try std.process.getCwdAlloc(alloc);
    const relative = try std.fs.path.relative(alloc, current, path);
    const relative_input: Command = .{ .shell = try alloc.dupeZ(u8, relative) };
    const preserved = try executableCommand(alloc, relative_input);
    try std.testing.expect(preserved == .shell);
    try std.testing.expectEqualStrings(relative, preserved.shell);
    for ([_][:0]const u8{ "C:pwsh.exe", "\\pwsh.exe", "\\\\server\\share\\pwsh.exe" }) |value| {
        try std.testing.expect((try executableCommand(alloc, .{ .shell = value })) == .shell);
    }
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
    command_: Command,
    cwd: ?[]const u8,
    working_directory_home: bool,
    utf8_console: bool,
    lookup: anytype,
) !Command {
    const command = try executableCommand(alloc, command_);
    defer if (command_ == .shell and command == .direct) command.deinit(alloc);
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

/// Machine lookups return owned paths or null, and fail only on allocation.
/// Discovery requires guarded metadata; the final cmd fallback uses the system
/// path even when that metadata is unavailable, avoiding a current-dir search.
const DefaultShellHost = struct {
    /// `pwsh.exe` on the process's `PATH`.
    fn findPwsh(alloc: Allocator) !?[]u8 {
        return try lookupExecutable(alloc, "pwsh.exe");
    }

    /// `relative` below the Windows system directory. The built-in shells are
    /// taken from there, not from `PATH`, so a `powershell.exe` or `cmd.exe`
    /// placed earlier on `PATH` does not become the default shell.
    fn systemShell(alloc: Allocator, relative: []const u8) !?[]u8 {
        const path = (try systemPath(alloc, relative)) orelse return null;
        if (isLaunchableFile(path)) return path;
        alloc.free(path);
        return null;
    }

    fn systemPath(alloc: Allocator, relative: []const u8) !?[]u8 {
        if (builtin.os.tag != .windows) return null;
        var buf: [windows.MAX_PATH:0]u16 = undefined;
        const len = windows.kernel32.GetSystemDirectoryW(&buf, buf.len);
        if (len == 0 or len >= buf.len) return null;
        const dir = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..len]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer alloc.free(dir);
        return try std.fs.path.join(alloc, &.{ dir, relative });
    }
};

const windows_powershell_relative = "WindowsPowerShell\\v1.0\\powershell.exe";

fn defaultCommandWithHost(alloc: Allocator, comptime Host: type) !Command {
    if (try Host.findPwsh(alloc)) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }
    if (try Host.systemShell(alloc, windows_powershell_relative)) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }
    return try commandPromptWithHost(alloc, Host, &.{});
}

fn commandPromptWithHost(alloc: Allocator, comptime Host: type, switches: []const []const u8) !Command {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    const found = (try Host.systemShell(alloc, "cmd.exe")) orelse
        try Host.systemPath(alloc, "cmd.exe");
    defer if (found) |path| alloc.free(path);
    // Only an unavailable system directory leaves a bare-name fallback.
    try argv.append(alloc, found orelse "cmd.exe");
    try argv.appendSlice(alloc, switches);
    return try directCommand(alloc, argv.items);
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
    var profile = try makeProfile(alloc, kind, key, label, argv);
    errdefer profile.deinit(alloc);
    try profiles.append(alloc, profile);
}

fn makeProfile(
    alloc: Allocator,
    kind: ProfileKind,
    key: []const u8,
    label: []const u8,
    argv: []const []const u8,
) !Profile {
    const owned_key = try alloc.dupe(u8, key);
    errdefer alloc.free(owned_key);
    const owned_label = try alloc.dupe(u8, label);
    errdefer alloc.free(owned_label);
    return .{
        .kind = kind,
        .key = owned_key,
        .label = owned_label,
        .command = try directCommand(alloc, argv),
    };
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
    if (profile.kind == .wsl_distro and profile.label.len > 5 and
        std.ascii.eqlIgnoreCase(profile.label[0..5], "WSL: ") and
        std.ascii.eqlIgnoreCase(token, profile.label[5..])) return true;
    // A distribution's own name (`Ubuntu` for `wsl:Ubuntu`), which only this
    // variable takes; a reference in the config writes `wsl:<name>`.
    if (profile.kind == .wsl_distro and profile.key.len > 4 and
        std.ascii.eqlIgnoreCase(profile.key[0..4], "wsl:") and
        std.ascii.eqlIgnoreCase(token, profile.key[4..])) return true;
    return profileAliasMatches(token, profile);
}

/// Whether `token` is one of the fixed words for `profile`'s kind (`pwsh`,
/// `git`, `cmd`, `wsl`, ...; `profile_alias_words`).
fn profileAliasMatches(token: []const u8, profile: Profile) bool {
    for (profile_alias_words) |alias| {
        if (alias.kind == profile.kind and std.ascii.eqlIgnoreCase(token, alias.word)) return true;
    }
    return false;
}

/// The fixed words that name a detected profile besides its key. Each is
/// reserved as a user profile id (`profile_map.reserved_ids`; the test
/// "every profile alias word is reserved as an id" holds that), so a bare
/// word names one thing.
pub const profile_alias_words = [_]struct { kind: ProfileKind, word: []const u8 }{
    .{ .kind = .wsl_default, .word = "wsl" },
    .{ .kind = .wsl_default, .word = "wsl-default" },
    .{ .kind = .wsl_default, .word = "default-wsl" },
    .{ .kind = .wsl_distro, .word = "wsl-distro" },
    .{ .kind = .wsl_distro, .word = "distro" },
    .{ .kind = .wsl_distro, .word = "wsl" },
    .{ .kind = .pwsh, .word = "pwsh" },
    .{ .kind = .pwsh, .word = "powershell-7" },
    .{ .kind = .pwsh, .word = "powershell-core" },
    .{ .kind = .powershell, .word = "powershell" },
    .{ .kind = .powershell, .word = "windows-powershell" },
    .{ .kind = .powershell, .word = "ps" },
    .{ .kind = .git_bash, .word = "git-bash" },
    .{ .kind = .git_bash, .word = "gitbash" },
    .{ .kind = .git_bash, .word = "git" },
    .{ .kind = .cmd, .word = "cmd" },
    .{ .kind = .cmd, .word = "cmd.exe" },
    .{ .kind = .cmd, .word = "command-prompt" },
};

test "a vs: key of either shell is a reference that can name a profile" {
    const Ids = struct {
        pub fn contains(_: @This(), _: []const u8) bool {
            return false;
        }
    };
    for ([_][]const u8{ "vs:deadbeef:cmd", "VS:6bb7cfd9:PWSH", "vs:newest:cmd", "vs:newest:pwsh" }) |ref| {
        try std.testing.expect(referenceCanName(ref, Ids{}));
    }
    for ([_][]const u8{ "vs:", "vs:newest", "vs:x:bash", "vs::cmd", "vs:a b:cmd", "vs:newest:cmd # x" }) |ref| {
        try std.testing.expect(!referenceCanName(ref, Ids{}));
    }
}

test "every profile alias word is reserved as an id" {
    const profile_map = @import("profile_map.zig");
    for (profile_alias_words) |alias| {
        std.testing.expect(profile_map.isReservedId(alias.word)) catch |err| {
            std.debug.print("not reserved: {s}\n", .{alias.word});
            return err;
        };
    }
}

/// Whether `reference` (a `default-profile`, `profile-order` or
/// `profile-hidden` value) names `profile`, one of `profiles`. A bare word
/// names the user profile with that id when `profiles` has one; otherwise
/// it is a key (`pwsh.exe`, `wsl:Ubuntu`, `user:<id>`; an `ssh:` key's
/// prefix in any case, as `resolveProfileReference` takes it, and its alias
/// exactly, as OpenSSH aliases are case-sensitive) or one of the
/// fixed words (`pwsh`, `git`, `wsl`, ...; `profile_alias_words`), which can
/// name several profiles. The ids reserve those words, so the classes never
/// overlap. A distribution is always `wsl:<name>`, and labels are not
/// references: they change.
pub fn referenceNames(profiles: []const Profile, reference: []const u8, profile: Profile) bool {
    return referenceNamesWithNewest(profiles, reference, profile, .of(profiles));
}

/// The keys `vs:newest:cmd` and `vs:newest:pwsh` stand for in a list: the
/// Visual Studio profile of each kind that discovery marked newest
/// (`Profile.newest_visual_studio`; its newest instance with that shell,
/// shown or hidden), so ordering the list (`profile-order`, the Settings
/// rows) does not change it. A list nobody marked (built by hand) takes the
/// first of each kind.
pub const NewestVisualStudio = struct {
    cmd: ?[]const u8 = null,
    pwsh: ?[]const u8 = null,

    pub fn of(profiles: []const Profile) NewestVisualStudio {
        var marked: NewestVisualStudio = .{};
        var first: NewestVisualStudio = .{};
        for (profiles) |profile| {
            const kind_slot: struct { marked: *?[]const u8, first: *?[]const u8 } = switch (profile.kind) {
                .vs_dev_cmd => .{ .marked = &marked.cmd, .first = &first.cmd },
                .vs_dev_shell => .{ .marked = &marked.pwsh, .first = &first.pwsh },
                else => continue,
            };
            if (kind_slot.first.* == null) kind_slot.first.* = profile.key;
            if (profile.newest_visual_studio and kind_slot.marked.* == null) kind_slot.marked.* = profile.key;
        }
        return .{ .cmd = marked.cmd orelse first.cmd, .pwsh = marked.pwsh orelse first.pwsh };
    }

    /// The concrete key `reference` stands for when it is `vs:newest:cmd`
    /// or `vs:newest:pwsh` (any case): a key, or "" when the list has no
    /// such shell. Null for any other reference.
    pub fn resolve(self: NewestVisualStudio, reference: []const u8) ?[]const u8 {
        return switch (newestVisualStudioKind(reference) orelse return null) {
            .vs_dev_cmd => self.cmd orelse "",
            .vs_dev_shell => self.pwsh orelse "",
            else => unreachable,
        };
    }
};

/// The kind `vs:newest:cmd` or `vs:newest:pwsh` names, any case.
fn newestVisualStudioKind(reference: []const u8) ?ProfileKind {
    if (std.ascii.eqlIgnoreCase(reference, "vs:newest:cmd")) return .vs_dev_cmd;
    if (std.ascii.eqlIgnoreCase(reference, "vs:newest:pwsh")) return .vs_dev_shell;
    return null;
}

fn referenceNamesWithNewest(
    profiles: []const Profile,
    reference: []const u8,
    profile: Profile,
    newest: NewestVisualStudio,
) bool {
    var ref = std.mem.trim(u8, reference, &std.ascii.whitespace);
    if (newest.resolve(ref)) |key| ref = key;
    if (ref.len == 0) return false;
    if (userProfileWithId(profiles, ref)) |named| return named == profile.key.ptr;
    if (profile.kind == .ssh) {
        const prefix = "ssh:";
        return ref.len == profile.key.len and
            std.ascii.startsWithIgnoreCase(ref, prefix) and
            std.ascii.startsWithIgnoreCase(profile.key, prefix) and
            std.mem.eql(u8, ref[prefix.len..], profile.key[prefix.len..]);
    }
    if (std.ascii.eqlIgnoreCase(ref, profile.key)) return true;
    return profileAliasMatches(ref, profile);
}

/// The key of the user profile in `profiles` whose id is `id`, as a pointer
/// that identifies it.
fn userProfileWithId(profiles: []const Profile, id: []const u8) ?[*]const u8 {
    for (profiles) |profile| {
        if (profile.kind != .user or profile.key.len != "user:".len + id.len) continue;
        if (std.ascii.eqlIgnoreCase(profile.key["user:".len..], id)) return profile.key.ptr;
    }
    return null;
}

/// Apply `profile-order` and `profile-hidden` to a finished list, in place.
/// The profiles `order` names come first, in the order of the first
/// reference that names each, the rest keep their order. Then every profile
/// `hidden` names is marked hidden, and every hidden one (also one that
/// discovery hid) is moved after all the shown ones, so the shown profiles
/// are always `profiles[0..visibleProfileCount(profiles)]`.
pub fn arrangeProfiles(
    profiles: []Profile,
    order: []const []const u8,
    hidden: []const []const u8,
) void {
    // `vs:newest:*` stands for a key of the list as discovery made it: the
    // sort below moves profiles, so it is resolved once, here.
    const newest: NewestVisualStudio = .of(profiles);
    if (order.len > 0 and profiles.len > 1) {
        // A stable insertion sort by rank: lists are short.
        var i: usize = 1;
        while (i < profiles.len) : (i += 1) {
            var j = i;
            while (j > 0 and referenceRank(profiles, order, profiles[j], newest) <
                referenceRank(profiles, order, profiles[j - 1], newest)) : (j -= 1)
            {
                std.mem.swap(Profile, &profiles[j], &profiles[j - 1]);
            }
        }
    }
    for (profiles) |*profile| {
        for (hidden) |reference| {
            if (referenceNamesWithNewest(profiles, reference, profile.*, newest)) {
                profile.hidden = true;
                break;
            }
        }
    }
    // Stable partition: shown first. Discovery hides profiles too (an older
    // Visual Studio under `visual-studio-profiles = newest`).
    var shown: usize = 0;
    for (0..profiles.len) |index| {
        if (profiles[index].hidden) continue;
        const moved = profiles[index];
        var k = index;
        while (k > shown) : (k -= 1) profiles[k] = profiles[k - 1];
        profiles[shown] = moved;
        shown += 1;
    }
}

fn referenceRank(
    profiles: []const Profile,
    order: []const []const u8,
    profile: Profile,
    newest: NewestVisualStudio,
) usize {
    for (order, 0..) |reference, index| {
        if (referenceNamesWithNewest(profiles, reference, profile, newest)) return index;
    }
    return std.math.maxInt(usize);
}

/// How many profiles at the start of an arranged list are shown.
pub fn visibleProfileCount(profiles: []const Profile) usize {
    for (profiles, 0..) |profile, index| {
        if (profile.hidden) return index;
    }
    return profiles.len;
}

/// The profiles an arranged list shows (the picker, the palette, the jump
/// list, the quick slots); the hidden ones follow them in the same slice.
pub fn visibleProfiles(profiles: []Profile) []Profile {
    return profiles[0..visibleProfileCount(profiles)];
}

/// What `resolveProfileReference` needs from the system: the lookups
/// discovery uses, noctty's environment for `%NAME%` in a user profile,
/// and Visual Studio's instances (`visual-studio-profiles`) for a `vs:` key.
pub const ReferenceHost = struct {
    visual_studio: VisualStudioProfiles = .newest,

    pub fn lookup(_: ReferenceHost, alloc: Allocator, exe: []const u8) !?[]u8 {
        return try lookupExecutable(alloc, exe);
    }

    pub fn gitBash(_: ReferenceHost, alloc: Allocator) !?[]u8 {
        return try lookupGitBash(alloc, lookupExecutable);
    }

    pub fn sshExecutable(_: ReferenceHost, alloc: Allocator) !?[]u8 {
        return try resolveSshExecutable(alloc, lookupExecutable, accessAbsolute);
    }

    pub fn get(_: ReferenceHost, alloc: Allocator, name: []const u8) Allocator.Error!?[]u8 {
        return try ProcessEnvironment.get(.{}, alloc, name);
    }

    /// Visual Studio's developer shells, hidden ones included; `complete`
    /// false when Setup Configuration did not answer in full.
    pub fn visualStudio(self: ReferenceHost, alloc: Allocator, complete: *bool) ![]Profile {
        return try appendVisualStudioProfiles(
            alloc,
            try alloc.alloc(Profile, 0),
            self.visual_studio,
            visual_studio.build_arch,
            visual_studio.ComSource{},
            VisualStudioHost{},
            complete,
        );
    }
};

/// The profile `reference` (`default-profile`) names, built without listing
/// the profiles: a user profile from `user`, a fixed detected key or alias
/// through the lookups discovery uses, `wsl:<distro>` as `wsl.exe -d
/// <distro>`, `ssh:<alias>` as `ssh.exe <alias>`, and a Visual Studio key
/// (`vs:<instance>:cmd`, `vs:<instance>:pwsh`) from the instances
/// `host.visualStudio` lists (none for a host without it). WSL is never probed and
/// its distributions are never listed, so a stopped or hung WSL costs
/// nothing here. Null when nothing by that name can start: an unknown
/// reference, a program that is not installed, an alias that names no single
/// profile (`distro`).
pub fn resolveProfileReference(
    alloc: Allocator,
    reference: []const u8,
    user: []const UserProfiles.Definition,
    host: anytype,
) !?Profile {
    const ref = std.mem.trim(u8, reference, &std.ascii.whitespace);
    if (ref.len == 0) return null;

    const user_id = if (std.ascii.startsWithIgnoreCase(ref, "user:")) ref["user:".len..] else ref;
    for (user) |definition| {
        if (!std.ascii.eqlIgnoreCase(definition.id, user_id)) continue;
        return userProfile(alloc, definition, host) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
    }
    if (user_id.len != ref.len) return null;

    if (std.ascii.startsWithIgnoreCase(ref, "wsl:")) {
        const distro = ref["wsl:".len..];
        if (!isPlainReferenceArgument(distro)) return null;
        const wsl = (try host.lookup(alloc, "wsl.exe")) orelse return null;
        defer alloc.free(wsl);
        const key = try std.fmt.allocPrint(alloc, "wsl:{s}", .{distro});
        defer alloc.free(key);
        const label = try std.fmt.allocPrint(alloc, "WSL: {s}", .{distro});
        defer alloc.free(label);
        return try makeProfile(alloc, .wsl_distro, key, label, &.{ wsl, "-d", distro });
    }
    if (std.ascii.startsWithIgnoreCase(ref, "vs:")) {
        if (comptime !@hasDecl(@TypeOf(host), "visualStudio")) return null;
        var complete = true;
        const profiles = try host.visualStudio(alloc, &complete);
        defer deinitProfiles(alloc, profiles);
        // `vs:newest:<shell>` is the first instance, newest first, that has
        // that shell; the profile keeps its concrete key, so a pane started
        // through it remembers the instance it ran. A partial answer may
        // lack the newest instance, so it names none: an older one would be
        // started, and remembered by every pane started through it.
        if (!complete and newestVisualStudioKind(ref) != null) return error.VisualStudioUnavailable;
        const want = NewestVisualStudio.of(profiles).resolve(ref) orelse ref;
        for (profiles) |profile| {
            if (std.ascii.eqlIgnoreCase(profile.key, want)) return try profile.clone(alloc);
        }
        // Setup Configuration failed: the install may well be there.
        if (!complete) return error.VisualStudioUnavailable;
        return null;
    }
    if (std.ascii.startsWithIgnoreCase(ref, "ssh:")) {
        const alias = ref["ssh:".len..];
        if (!isPlainReferenceArgument(alias)) return null;
        const ssh = (try host.sshExecutable(alloc)) orelse return null;
        defer alloc.free(ssh);
        const key = try std.fmt.allocPrint(alloc, "ssh:{s}", .{alias});
        defer alloc.free(key);
        const label = try std.fmt.allocPrint(alloc, "SSH: {s}", .{alias});
        defer alloc.free(label);
        var profile = try makeProfile(alloc, .ssh, key, label, &.{ ssh, alias });
        errdefer profile.deinit(alloc);
        profile.palette_title = try std.fmt.allocPrint(alloc, "Connect to {s}", .{alias});
        return profile;
    }

    // The fixed detected profiles, by key or alias. `wsl` names the default
    // distribution here; the aliases of every distribution (`distro`) name
    // no single profile.
    const Fixed = struct { kind: ProfileKind, key: []const u8, label: []const u8 };
    for ([_]Fixed{
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell" },
        .{ .kind = .powershell, .key = "powershell.exe", .label = "Windows PowerShell" },
        .{ .kind = .git_bash, .key = "git-bash", .label = "Git Bash" },
        .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt" },
        .{ .kind = .wsl_default, .key = "wsl-default", .label = "WSL (Default)" },
    }) |fixed| {
        const probe: Profile = .{ .kind = fixed.kind, .key = fixed.key, .label = fixed.label, .command = .{ .direct = &.{} } };
        if (!std.ascii.eqlIgnoreCase(ref, fixed.key) and !profileAliasMatches(ref, probe)) continue;
        const path = (try switch (fixed.kind) {
            .git_bash => host.gitBash(alloc),
            .wsl_default => host.lookup(alloc, "wsl.exe"),
            else => host.lookup(alloc, fixed.key),
        }) orelse return null;
        defer alloc.free(path);
        const argv: []const []const u8 = if (fixed.kind == .git_bash) &.{ path, "--login", "-i" } else &.{path};
        return try makeProfile(alloc, fixed.kind, fixed.key, fixed.label, argv);
    }
    return null;
}

/// A distribution or SSH alias a reference may pass as one argument: not
/// empty, not an option, no whitespace or control character.
fn isPlainReferenceArgument(value: []const u8) bool {
    if (value.len == 0 or value[0] == '-') return false;
    for (value) |ch| {
        if (ch <= ' ' or ch == 0x7f) return false;
    }
    return true;
}

/// Whether `reference` (a `profile-order` or `profile-hidden` value) can name
/// a profile, decided without listing any: a fixed key or word; `wsl:<x>` or
/// `ssh:<x>` with `<x>` one plain argument; `vs:<x>:cmd` or `vs:<x>:pwsh`
/// (`vs:newest:*` included); an id, bare or as `user:<id>`,
/// that `commands` (the `profile-command` map) holds, also a removed one.
/// Whether such a profile exists depends on the machine, so a shared config
/// that names a shell this one lacks loads quietly; anything else, a typo or
/// a comment after the value, can name nothing anywhere.
pub fn referenceCanName(reference: []const u8, commands: anytype) bool {
    const ref = std.mem.trim(u8, reference, &std.ascii.whitespace);
    if (ref.len == 0) return false;
    for ([_][]const u8{ "pwsh.exe", "powershell.exe", "cmd.exe", "git-bash", "wsl-default" }) |key| {
        if (std.ascii.eqlIgnoreCase(ref, key)) return true;
    }
    for (profile_alias_words) |alias| {
        if (std.ascii.eqlIgnoreCase(ref, alias.word)) return true;
    }
    for ([_][]const u8{ "wsl:", "ssh:" }) |prefix| {
        if (std.ascii.startsWithIgnoreCase(ref, prefix)) return isPlainReferenceArgument(ref[prefix.len..]);
    }
    if (std.ascii.startsWithIgnoreCase(ref, "vs:")) {
        const rest = ref["vs:".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
        const shell = rest[colon + 1 ..];
        return isPlainReferenceArgument(rest[0..colon]) and
            (std.ascii.eqlIgnoreCase(shell, "cmd") or std.ascii.eqlIgnoreCase(shell, "pwsh"));
    }
    const id = if (std.ascii.startsWithIgnoreCase(ref, "user:")) ref["user:".len..] else ref;
    return commands.contains(id);
}

/// The `resolveProfileReference` host for tests: fixed install paths, no
/// `%NAME%` expansion, and counters for every lookup and for the WSL calls
/// discovery makes (`probe`, `listWsl`), which resolution must never make.
const TestReferenceHost = struct {
    pwsh: bool = true,
    lookups: *usize,
    wsl_probes: *usize,
    wsl_lists: *usize,

    pub fn lookup(self: TestReferenceHost, alloc: Allocator, exe: []const u8) !?[]u8 {
        self.lookups.* += 1;
        if (std.mem.eql(u8, exe, "pwsh.exe") and !self.pwsh) return null;
        for ([_][2][]const u8{
            .{ "pwsh.exe", "C:\\Program Files\\PowerShell\\7\\pwsh.exe" },
            .{ "powershell.exe", "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" },
            .{ "cmd.exe", "C:\\Windows\\System32\\cmd.exe" },
            .{ "wsl.exe", "C:\\Windows\\System32\\wsl.exe" },
        }) |entry| {
            if (std.mem.eql(u8, exe, entry[0])) return try alloc.dupe(u8, entry[1]);
        }
        return null;
    }

    pub fn gitBash(self: TestReferenceHost, alloc: Allocator) !?[]u8 {
        self.lookups.* += 1;
        return try alloc.dupe(u8, "C:\\Program Files\\Git\\bin\\bash.exe");
    }

    pub fn sshExecutable(self: TestReferenceHost, alloc: Allocator) !?[]u8 {
        self.lookups.* += 1;
        return try alloc.dupe(u8, "C:\\Windows\\System32\\OpenSSH\\ssh.exe");
    }

    pub fn get(_: TestReferenceHost, _: Allocator, _: []const u8) Allocator.Error!?[]u8 {
        return null;
    }

    // What discovery would call; resolution has no business with them.
    pub fn probe(self: TestReferenceHost, _: Allocator, _: []const u8) !bool {
        self.wsl_probes.* += 1;
        return true;
    }

    pub fn listWsl(self: TestReferenceHost, alloc: Allocator, _: []const u8) ![][]u8 {
        self.wsl_lists.* += 1;
        return try alloc.alloc([]u8, 0);
    }
};

test "default-profile references resolve without listing profiles or asking WSL" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var lookups: usize = 0;
    var wsl_probes: usize = 0;
    var wsl_lists: usize = 0;
    const host: TestReferenceHost = .{ .lookups = &lookups, .wsl_probes = &wsl_probes, .wsl_lists = &wsl_lists };
    const definitions = [_]UserProfiles.Definition{
        .{ .id = "VS18-cmd", .name = "Developer Command Prompt for VS 18", .command = test_vs18_cmd_line, .env = &.{.{ .key = "VSCMD_SKIP_SENDTELEMETRY", .value = "1" }} },
        .{ .id = "py", .command = "cmd.exe", .working_directory = "D:\\src" },
    };

    const Want = struct { ref: []const u8, kind: ProfileKind, key: []const u8, argv: []const []const u8 };
    for ([_]Want{
        // A user profile, by its id in any case or by its key.
        .{ .ref = "vs18-CMD", .kind = .user, .key = "user:vs18-cmd", .argv = &.{ "cmd.exe", "/k" } },
        .{ .ref = " user:VS18-cmd ", .kind = .user, .key = "user:vs18-cmd", .argv = &.{ "cmd.exe", "/k" } },
        .{ .ref = "py", .kind = .user, .key = "user:py", .argv = &.{"cmd.exe"} },
        // The fixed detected profiles, by key and by alias.
        .{ .ref = "pwsh.exe", .kind = .pwsh, .key = "pwsh.exe", .argv = &.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"} },
        .{ .ref = "PWSH", .kind = .pwsh, .key = "pwsh.exe", .argv = &.{"C:\\Program Files\\PowerShell\\7\\pwsh.exe"} },
        .{ .ref = "powershell", .kind = .powershell, .key = "powershell.exe", .argv = &.{"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"} },
        .{ .ref = "cmd", .kind = .cmd, .key = "cmd.exe", .argv = &.{"C:\\Windows\\System32\\cmd.exe"} },
        .{ .ref = "command-prompt", .kind = .cmd, .key = "cmd.exe", .argv = &.{"C:\\Windows\\System32\\cmd.exe"} },
        .{ .ref = "git", .kind = .git_bash, .key = "git-bash", .argv = &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" } },
        .{ .ref = "wsl", .kind = .wsl_default, .key = "wsl-default", .argv = &.{"C:\\Windows\\System32\\wsl.exe"} },
        // A distribution and an SSH alias, without asking WSL or the SSH config.
        .{ .ref = "wsl:Ubuntu", .kind = .wsl_distro, .key = "wsl:Ubuntu", .argv = &.{ "C:\\Windows\\System32\\wsl.exe", "-d", "Ubuntu" } },
        .{ .ref = "ssh:prod", .kind = .ssh, .key = "ssh:prod", .argv = &.{ "C:\\Windows\\System32\\OpenSSH\\ssh.exe", "prod" } },
    }) |want| {
        var profile = (try resolveProfileReference(alloc, want.ref, &definitions, host)) orelse {
            std.debug.print("unresolved: {s}\n", .{want.ref});
            return error.TestUnexpectedResult;
        };
        defer profile.deinit(alloc);
        try testing.expectEqual(want.kind, profile.kind);
        try testing.expectEqualStrings(want.key, profile.key);
        for (want.argv, 0..) |arg, i| try testing.expectEqualStrings(arg, profile.command.direct[i]);
        if (want.kind != .user) try testing.expectEqual(want.argv.len, profile.command.direct.len);
    }

    // A user profile comes with what discovery would give it.
    {
        var profile = (try resolveProfileReference(alloc, "vs18-cmd", &definitions, host)).?;
        defer profile.deinit(alloc);
        try testing.expectEqualStrings("Developer Command Prompt for VS 18", profile.label);
        try testing.expectEqualStrings(test_vs18_cmd_line, profile.user.?.command_line);
        try testing.expectEqualStrings("1", profile.user.?.env[0].value);
        try testing.expectEqual(@as(usize, 6), profile.command.direct.len);
        var py = (try resolveProfileReference(alloc, "py", &definitions, host)).?;
        defer py.deinit(alloc);
        try testing.expectEqualStrings("D:\\src", py.working_directory.?.path);
        var ssh = (try resolveProfileReference(alloc, "ssh:prod", &definitions, host)).?;
        defer ssh.deinit(alloc);
        try testing.expectEqualStrings("Connect to prod", ssh.palette_title.?);
    }

    // Nothing that can start: an unknown name, `user:` of no profile, an
    // alias of every distribution, an empty or option-shaped distribution
    // or alias, a program that is not installed.
    for ([_][]const u8{ "", "  ", "nosuch", "user:nosuch", "user:pwsh.exe", "distro", "wsl-distro", "wsl:", "wsl:-x", "wsl:a b", "ssh:", "ssh:-oProxyCommand=calc" }) |ref| {
        try testing.expect((try resolveProfileReference(alloc, ref, &definitions, host)) == null);
    }
    const no_pwsh: TestReferenceHost = .{ .pwsh = false, .lookups = &lookups, .wsl_probes = &wsl_probes, .wsl_lists = &wsl_lists };
    try testing.expect((try resolveProfileReference(alloc, "pwsh", &definitions, no_pwsh)) == null);

    // A user id shadows the alias it spells.
    const shadow = [_]UserProfiles.Definition{.{ .id = "pwsh", .command = "C:\\tools\\my-pwsh.exe -NoLogo" }};
    {
        var profile = (try resolveProfileReference(alloc, "pwsh", &shadow, host)).?;
        defer profile.deinit(alloc);
        try testing.expectEqualStrings("user:pwsh", profile.key);
        var detected = (try resolveProfileReference(alloc, "pwsh.exe", &shadow, host)).?;
        defer detected.deinit(alloc);
        try testing.expectEqual(ProfileKind.pwsh, detected.kind);
    }

    try testing.expect(lookups > 0);
    try testing.expectEqual(@as(usize, 0), wsl_probes);
    try testing.expectEqual(@as(usize, 0), wsl_lists);
}

test "resolveProfileReference frees what it built when an allocation fails" {
    var lookups: usize = 0;
    var wsl_probes: usize = 0;
    var wsl_lists: usize = 0;
    const host: TestReferenceHost = .{ .lookups = &lookups, .wsl_probes = &wsl_probes, .wsl_lists = &wsl_lists };
    const definitions = [_]UserProfiles.Definition{.{ .id = "py", .command = "cmd.exe /k py", .working_directory = "D:\\src", .env = &.{.{ .key = "A", .value = "1" }} }};
    for ([_][]const u8{ "py", "wsl:Ubuntu", "ssh:prod", "git" }) |ref| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            var profile = (resolveProfileReference(failing.allocator(), ref, &definitions, host) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                continue;
            }).?;
            profile.deinit(failing.allocator());
            break;
        }
    }
}

/// A profile for the arrangement tests; nothing to free.
fn testArrangeProfile(kind: ProfileKind, key: []const u8, label: []const u8) Profile {
    return .{ .kind = kind, .key = key, .label = label, .command = .{ .direct = &.{} } };
}

fn expectProfileKeys(profiles: []const Profile, keys: []const []const u8) !void {
    try std.testing.expectEqual(keys.len, profiles.len);
    for (keys, profiles) |key, profile| try std.testing.expectEqualStrings(key, profile.key);
}

test "profile-order puts the profiles it names first and profile-hidden moves the hidden ones last" {
    const testing = std.testing;
    const all = [_]Profile{
        testArrangeProfile(.wsl_default, "wsl-default", "WSL (Default)"),
        testArrangeProfile(.wsl_distro, "wsl:Ubuntu", "WSL: Ubuntu"),
        testArrangeProfile(.wsl_distro, "wsl:docker-desktop", "WSL: docker-desktop"),
        testArrangeProfile(.pwsh, "pwsh.exe", "PowerShell"),
        testArrangeProfile(.git_bash, "git-bash", "Git Bash"),
        testArrangeProfile(.cmd, "cmd.exe", "Command Prompt"),
        testArrangeProfile(.user, "user:vs18-cmd", "Developer Command Prompt for VS 18"),
        testArrangeProfile(.user, "user:py", "Python"),
        testArrangeProfile(.ssh, "ssh:Prod", "SSH: Prod"),
    };

    // Nothing set: the list as discovery made it, nothing hidden.
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{}, &.{});
        try expectProfileKeys(&profiles, &.{ "wsl-default", "wsl:Ubuntu", "wsl:docker-desktop", "pwsh.exe", "git-bash", "cmd.exe", "user:vs18-cmd", "user:py", "ssh:Prod" });
        try testing.expectEqual(profiles.len, visibleProfileCount(&profiles));
    }

    // Order by a bare id, a key in another case and an alias; the rest keep
    // their order after them.
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{ "VS18-CMD", "CMD.EXE", "pwsh" }, &.{});
        try expectProfileKeys(&profiles, &.{ "user:vs18-cmd", "cmd.exe", "pwsh.exe", "wsl-default", "wsl:Ubuntu", "wsl:docker-desktop", "git-bash", "user:py", "ssh:Prod" });
    }

    // An alias can name several profiles: they keep their order among
    // themselves. An SSH alias is exact; a label is no reference.
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{ "ssh:prod", "Python", "ssh:Prod", "wsl" }, &.{});
        try expectProfileKeys(&profiles, &.{ "ssh:Prod", "wsl-default", "wsl:Ubuntu", "wsl:docker-desktop", "pwsh.exe", "git-bash", "cmd.exe", "user:vs18-cmd", "user:py" });
    }

    // The `ssh:` prefix takes any case, as `default-profile` and the
    // reference check take it; the alias still does not.
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{"SSH:Prod"}, &.{});
        try testing.expectEqualStrings("ssh:Prod", profiles[0].key);
    }
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{}, &.{"SSH:Prod"});
        try testing.expectEqualStrings("ssh:Prod", profiles[profiles.len - 1].key);
        try testing.expect(profiles[profiles.len - 1].hidden);
        try testing.expectEqual(profiles.len - 1, visibleProfileCount(&profiles));
    }
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{}, &.{"SSH:prod"});
        try testing.expectEqual(profiles.len, visibleProfileCount(&profiles));
    }

    // Hidden by key and by a fixed word: marked, and after every shown one,
    // each side in its order. A distribution's own name is no reference
    // (`wsl:<name>` is), and a word that names nothing hides nothing.
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{"py"}, &.{ "wsl:docker-desktop", "ubuntu", "git", "nosuch" });
        try expectProfileKeys(&profiles, &.{ "user:py", "wsl-default", "wsl:Ubuntu", "pwsh.exe", "cmd.exe", "user:vs18-cmd", "ssh:Prod", "wsl:docker-desktop", "git-bash" });
        try testing.expectEqual(@as(usize, 7), visibleProfileCount(&profiles));
        try testing.expectEqual(@as(usize, 7), visibleProfiles(&profiles).len);
        for (profiles, 0..) |profile, index| try testing.expectEqual(index >= 7, profile.hidden);
    }
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{"Ubuntu"}, &.{"WSL:ubuntu"});
        try testing.expectEqualStrings("wsl:Ubuntu", profiles[profiles.len - 1].key);
        try testing.expect(profiles[profiles.len - 1].hidden);
        try testing.expectEqualStrings("wsl-default", profiles[0].key);
    }

    // The fixed words name the detected profiles: `git` is Git Bash (no user
    // id can be `git`; `profile_map.reserved_ids`).
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{}, &.{"git"});
        try testing.expectEqualStrings("git-bash", profiles[profiles.len - 1].key);
        try testing.expectEqual(profiles.len - 1, visibleProfileCount(&profiles));
    }

    // Hiding everything leaves nothing shown, and every profile in the list.
    {
        var profiles = all;
        arrangeProfiles(&profiles, &.{}, &.{ "wsl", "pwsh", "git", "cmd", "vs18-cmd", "py", "ssh:Prod" });
        try testing.expectEqual(@as(usize, 0), visibleProfileCount(&profiles));
        try testing.expectEqual(all.len, profiles.len);
    }
}

test "listing applies profile-order and profile-hidden after SSH and the user profiles" {
    // The stages `listProfiles` runs, with the definitions a config makes.
    const testing = std.testing;
    const alloc = testing.allocator;
    const Config = @import("Config.zig");
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    const arena = cfg._arena.?.allocator();
    try cfg.@"profile-command".parseCLI(arena, "py: cmd.exe /k py");
    try cfg.@"profile-order".parseCLI(arena, "ssh:prod");
    try cfg.@"profile-order".parseCLI(arena, "py");
    try cfg.@"profile-hidden".parseCLI(arena, "pwsh.exe");
    try cfg.finalize();
    try testing.expect(cfg._diagnostics.empty());
    var user = try UserProfiles.init(alloc, &cfg);
    defer user.deinit();
    try testing.expectEqual(@as(usize, 2), user.order.len);
    try testing.expectEqualStrings("pwsh.exe", user.hidden[0]);

    const shell = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
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
    }.list, null, null);
    const local = try appendUserProfiles(alloc, shell, user.definitions, TestEnvironment{});
    const hosts = [_]windows_ssh_hosts.Host{.{ .alias = "prod" }};
    const profiles = try appendSshProfiles(alloc, local, &hosts, "C:\\Windows\\System32\\OpenSSH\\ssh.exe");
    defer deinitProfiles(alloc, profiles);
    arrangeProfiles(profiles, user.order, user.hidden);
    try expectProfileKeys(profiles, &.{ "ssh:prod", "user:py", "cmd.exe", "pwsh.exe" });
    try testing.expectEqual(@as(usize, 3), visibleProfileCount(profiles));
    // Copies keep the mark (a worker's list is cloned onto each host).
    const copy = try cloneProfiles(alloc, profiles);
    defer deinitProfiles(alloc, copy);
    try testing.expect(copy[3].hidden and !copy[2].hidden);
}

test "UserProfiles frees profile-order and profile-hidden when no profile is defined" {
    // With no `profile-command` the definitions take no arena memory, so
    // the first copy below creates the arena's first node.
    const testing = std.testing;
    const Config = @import("Config.zig");
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    const arena = cfg._arena.?.allocator();
    try cfg.@"profile-hidden".parseCLI(arena, "wsl:docker-desktop");
    try cfg.@"profile-order".parseCLI(arena, "cmd");
    var user = try UserProfiles.init(testing.allocator, &cfg);
    defer user.deinit();
    try testing.expectEqual(@as(usize, 0), user.definitions.len);
    try testing.expectEqualStrings("cmd", user.order[0]);
    try testing.expectEqualStrings("wsl:docker-desktop", user.hidden[0]);
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

    win32.spawnChildHoldingInheritLock(&child) catch |err| {
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
    var filled: usize = 0;
    errdefer {
        for (args[0..filled]) |arg| alloc.free(arg);
        alloc.free(args);
    }
    for (argv, args) |arg, *dst| {
        dst.* = try alloc.dupeZ(u8, arg);
        filled += 1;
    }
    return .{ .direct = args };
}

/// A program by bare name, for the profile list and the SSH lookup. The same
/// search `defaultCommand` uses for pwsh.exe, so the picker and a new tab agree
/// on what is installed: local absolute `PATH` entries only, quoted entries
/// understood, and guarded metadata handles (no reparse ancestor is followed).
fn lookupExecutable(alloc: Allocator, exe: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows or std.mem.indexOfAny(u8, exe, "\\/:") != null)
        return try internal_os.path.expand(alloc, exe);
    // The built-in shells live in the system directory, where `defaultCommand`
    // takes them from, so the picker lists exactly the executable a new tab runs.
    if (std.ascii.eqlIgnoreCase(exe, "cmd.exe")) {
        return try DefaultShellHost.systemShell(alloc, "cmd.exe");
    } else if (std.ascii.eqlIgnoreCase(exe, "powershell.exe")) {
        return try DefaultShellHost.systemShell(alloc, windows_powershell_relative);
    }
    const path = std.process.getEnvVarOwned(alloc, "PATH") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = searchPath(&buf, exe, path, null, true, isLaunchableFile) orelse return null;
    return try alloc.dupe(u8, found);
}

/// Git for Windows' `bash.exe`, from the most to the least trustworthy source:
/// the install that `git.exe` on PATH belongs to, the install its installer
/// registered, and last a `bash.exe` on PATH that is not a WSL launcher.
///
/// The last source can name a `bash.exe` that is not Git's, such as MSYS2's or
/// Cygwin's; it is still offered as the "Git Bash" profile, as it was before
/// this lookup existed, and gets the same automatic shell integration.
///
/// A plain PATH search is not enough. The installer puts only `Git\cmd` on
/// PATH, so on a machine with WSL the first `bash.exe` is the launcher in
/// System32, and the "Git Bash" profile would open a Linux distribution.
fn lookupGitBash(alloc: Allocator, lookup: anytype) !?[]u8 {
    return try lookupGitBashWithHost(alloc, lookup, GitBashHost);
}

/// Hives `GitBashHost.registryInstallRoot` reads: HKCU, then HKLM.
const git_registry_hives = 2;

const GitBashHost = struct {
    fn fileExists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// `InstallPath` of the Git for Windows installer in hive `index`: the
    /// per-user install (0) is tried before the all-users one (1).
    fn registryInstallRoot(alloc: Allocator, index: usize) !?[]u8 {
        // Tests must not depend on whether this machine has Git installed.
        if (builtin.is_test) return null;
        const hives = [git_registry_hives]windows.HKEY{ windows.HKEY_CURRENT_USER, windows.HKEY_LOCAL_MACHINE };
        return try registryString(
            alloc,
            hives[index],
            std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\GitForWindows"),
            std.unicode.utf8ToUtf16LeStringLiteral("InstallPath"),
        );
    }

    fn systemRoot(alloc: Allocator) ![]u8 {
        return std.process.getEnvVarOwned(alloc, "SystemRoot") catch |err| switch (err) {
            error.EnvironmentVariableNotFound, error.InvalidWtf8 => try alloc.dupe(u8, "C:\\Windows"),
            else => |e| return e,
        };
    }
};

/// A non-empty `REG_SZ` value as UTF-8, or null when the key or value is
/// missing, not a string, or empty.
fn registryString(
    alloc: Allocator,
    hive: windows.HKEY,
    subkey: [*:0]const u16,
    name: [*:0]const u16,
) !?[]u8 {
    var buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    var bytes: windows.DWORD = @sizeOf(@TypeOf(buf));
    const status = windows.advapi32.RegGetValueW(
        hive,
        subkey,
        name,
        windows.advapi32.RRF.RT_REG_SZ | windows.advapi32.RRF.ZEROONFAILURE,
        null,
        @ptrCast(&buf),
        &bytes,
    );
    if (status != @intFromEnum(windows.Win32Error.SUCCESS)) return null;
    // The size counts the terminator.
    if (bytes < @sizeOf(u16) or bytes % @sizeOf(u16) != 0) return null;
    const len = bytes / @sizeOf(u16) - 1;
    if (len == 0) return null;
    // WTF-8 holds any registry text, an unpaired surrogate included.
    return try std.unicode.wtf16LeToWtf8Alloc(alloc, buf[0..len]);
}

fn lookupGitBashWithHost(alloc: Allocator, lookup: anytype, comptime Host: type) !?[]u8 {
    if (try lookup(alloc, "git.exe")) |git_path| {
        defer alloc.free(git_path);
        if (try gitBashBesideGit(alloc, git_path, Host)) |path| return path;
    }

    // A hive can name an install that was removed while the other holds a
    // working one, so each root is checked before the next hive is read.
    for (0..git_registry_hives) |hive| {
        const root = (try Host.registryInstallRoot(alloc, hive)) orelse continue;
        defer alloc.free(root);
        if (try bashInInstall(alloc, root, Host)) |path| return path;
    }

    const path = (try lookup(alloc, "bash.exe")) orelse return null;
    errdefer alloc.free(path);
    const system_root = try Host.systemRoot(alloc);
    defer alloc.free(system_root);
    if (isWslBashLauncher(path, system_root)) {
        alloc.free(path);
        return null;
    }
    return path;
}

/// `bin\bash.exe` of the Git install `git_path` belongs to. `git.exe` lives in
/// `cmd` (what the installer adds to PATH), in `bin`, or in a MinGW
/// environment's `bin` (`mingw64\bin`); any other folder is not recognised as
/// part of an install, so a shim or an unrelated `git.exe` leads nowhere.
fn gitBashBesideGit(alloc: Allocator, git_path: []const u8, comptime Host: type) !?[]u8 {
    const dir = std.fs.path.dirname(git_path) orelse return null;
    var root = std.fs.path.dirname(dir) orelse return null;
    const leaf = std.fs.path.basename(dir);
    if (std.ascii.eqlIgnoreCase(leaf, "bin")) {
        const env = std.fs.path.basename(root);
        if (std.ascii.startsWithIgnoreCase(env, "mingw") or
            std.ascii.eqlIgnoreCase(env, "ucrt64") or
            std.ascii.eqlIgnoreCase(env, "clang64") or
            std.ascii.eqlIgnoreCase(env, "clangarm64"))
        {
            root = std.fs.path.dirname(root) orelse return null;
        }
    } else if (!std.ascii.eqlIgnoreCase(leaf, "cmd")) {
        return null;
    }

    return try bashInInstall(alloc, root, Host);
}

/// `bin\bash.exe` below the Git install `root`, when that file exists.
fn bashInInstall(alloc: Allocator, root: []const u8, comptime Host: type) !?[]u8 {
    const candidate = try std.fs.path.join(alloc, &.{ root, "bin", "bash.exe" });
    if (Host.fileExists(candidate)) return candidate;
    alloc.free(candidate);
    return null;
}

/// True for the `bash.exe` that starts WSL: the launcher in System32 (or its
/// SysWOW64 and Sysnative views) and the WindowsApps alias. Neither is Git
/// Bash, and shell integration cannot reach into the Linux side (the
/// environment it relies on does not cross into WSL), so a bash started there
/// would stay in POSIX mode.
fn isWslBashLauncher(path: []const u8, system_root: []const u8) bool {
    if (pathIsUnder(path, system_root)) return true;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, "WindowsApps")) return true;
    }
    return false;
}

/// Whether `path` is `dir` or below it, ignoring case and the kind of
/// separator, as Windows does.
fn pathIsUnder(path: []const u8, dir: []const u8) bool {
    const root = std.mem.trimRight(u8, dir, "/\\");
    if (root.len == 0 or path.len <= root.len) return false;
    for (root, path[0..root.len]) |a, b| {
        if (isSeparator(a) and isSeparator(b)) continue;
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return isSeparator(path[root.len]);
}

/// `isWslBashLauncher` for a path from the command line, which shell
/// integration must leave alone.
pub fn isWslBashLauncherPath(alloc: Allocator, path: []const u8) !bool {
    const system_root = try GitBashHost.systemRoot(alloc);
    defer alloc.free(system_root);
    return isWslBashLauncher(path, system_root);
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

    try win32.spawnChildHoldingInheritLock(&child);
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

    // Must be backslash-separated throughout: a forward slash proves this is a
    // POSIX path that merely begins with backslashes, not the form cmd's `$P`
    // produces.
    if (std.mem.indexOfScalar(u8, path[3..], '/') != null) return false;

    // A UNC path needs both a host and a non-empty share (`\\server\share`).
    // `/\\server` alone is a legal POSIX filename, never a usable UNC path.
    const host = path[3..];
    const sep = std.mem.indexOfScalar(u8, host, '\\') orelse return false;
    return sep + 1 < host.len;
}

pub fn isDriveAbsolutePath(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        isSeparator(path[2]);
}

/// A drive-absolute path that is not a network or device path and not on a
/// network drive, so a metadata query cannot wait on a network timeout.
fn isOnLocalDrive(path: []const u8) bool {
    return isDriveAbsolutePath(path) and
        !internal_os.path.isNetworkOrDevicePath(path) and
        internal_os.windows.driveTypeForLetter(path[0]) != internal_os.windows.DRIVE_REMOTE;
}

/// `value` without one pair of enclosing double quotes, if it has them.
fn stripOuterQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
        return value[1 .. value.len - 1];
    return value;
}

fn isExeOrCom(extension: []const u8) bool {
    return std.ascii.eqlIgnoreCase(extension, ".exe") or
        std.ascii.eqlIgnoreCase(extension, ".com");
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
    return try drivePathToWindows(alloc, path[1], path[3..]);
}

/// `rest` is what follows the `X:` and its first separator.
fn drivePathToWindows(alloc: Allocator, drive: u8, rest: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, drive);
    try buf.appendSlice(alloc, ":\\");
    try appendWindowsPath(&buf, alloc, trimLeadingSeparators(rest));
    return try buf.toOwnedSlice(alloc);
}

/// The Windows path in the plain form of ConEmu's OSC 9;9: `C:\Users\me`,
/// `C:/Users/me`, or either in one pair of double quotes, as oh-my-posh's
/// `osc99` and nushell send it. Returns null for anything else, which the
/// caller then reads as a URL (noctty's cmd integration sends
/// `kitty-shell-cwd://localhost/%P`).
///
/// Only a drive-absolute path qualifies, plus the WSL form: `wslpath -w`, the
/// recipe Windows Terminal documents for WSL, prints `\\wsl.localhost\Ubuntu\home\me`,
/// which maps to the distro's own `/home/me` exactly as it does in an OSC 7
/// URL (`osc7PathToLocal`). Any other UNC path, a device path and a relative
/// path are not taken. The result is not checked for control bytes or a
/// network shape; `isSafeWindowsPath` and `os.path.isNetworkOrDevicePath` do
/// that.
pub fn conemuPathToLocal(alloc: Allocator, value: []const u8) !?[]const u8 {
    const path = stripOuterQuotes(value);
    // A quote left over is not part of any Windows path.
    if (std.mem.indexOfScalar(u8, path, '"') != null) return null;
    if (isDriveAbsolutePath(path)) return try drivePathToWindows(alloc, path[0], path[3..]);
    if (std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\")) return try normalizeWslPath(alloc, path);
    return null;
}

/// The Windows path an MSYS2 or Cygwin program means by an absolute path on a
/// drive: MSYS2 (Git Bash included) prints `C:\Users\me` as `/c/Users/me`, and
/// Cygwin as `/cygdrive/c/Users/me`. Returns null for anything else:
/// - a drive's root (`/c`, `/c/`, `/c/x/..`): in text a lone `/c` is nearly
///   always a switch (`cmd /c`, `findstr /c:x`), and a drive root is never a
///   link (`url.regex` does not match `C:\`). A shell's directory, where `/c`
///   is meant, takes `msysDriveDirToWindows`;
/// - a `..` above the drive, which MSYS2 reads as its own root (`/c/..` is `/`);
/// - a first segment of more than one letter (`/cd/x`), a rooted path that is
///   not a drive (`/home/me`, `/usr/bin`), and every network or device shape,
///   since `//server/share` and `/\server` never start with a letter.
///
/// Only for a pane that is not WSL: there `/c/x` is a Linux path. The drive is
/// not checked; whatever opens the result must refuse a letter that is not a
/// local drive, as it does for the same text written `C:\x`.
pub fn msysDrivePathToWindows(alloc: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    return msysToWindows(alloc, path, 1);
}

/// `msysDrivePathToWindows` for a directory a shell reports (`pwd`, OSC 7),
/// where `/c` is `C:\`.
pub fn msysDriveDirToWindows(alloc: Allocator, path: []const u8) Allocator.Error!?[]const u8 {
    return msysToWindows(alloc, path, 0);
}

/// Whether `msysDrivePathToWindows` reads `path` as a drive path.
pub fn isMsysDrivePath(path: []const u8) bool {
    return msysDriveRoot(path, 1) != null;
}

fn msysToWindows(alloc: Allocator, path: []const u8, min_depth: usize) Allocator.Error!?[]const u8 {
    const rooted = msysDriveRoot(path, min_depth) orelse return null;
    return try drivePathToWindows(alloc, std.ascii.toUpper(rooted[1]), rooted[2..]);
}

/// `path` from its `/<letter>` on, without the `/cygdrive` prefix, when it
/// names something at least `min_depth` levels below the drive's root and no
/// `..` leaves the drive. A name of only dots and spaces adds no level:
/// Windows drops a final one (`C:\...` is `C:\`).
fn msysDriveRoot(path: []const u8, min_depth: usize) ?[]const u8 {
    const rooted = if (std.mem.startsWith(u8, path, "/cygdrive/")) path["/cygdrive".len..] else path;
    if (rooted.len < 2 or rooted[0] != '/' or !std.ascii.isAlphabetic(rooted[1])) return null;
    if (rooted.len > 2 and rooted[2] != '/') return null;
    var depth: usize = 0;
    var names = std.mem.tokenizeAny(u8, rooted[2..], "/\\");
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "..")) {
            depth = std.math.sub(usize, depth, 1) catch return null;
        } else if (std.mem.trim(u8, name, ". ").len > 0) {
            depth += 1;
        }
    }
    return if (depth >= min_depth) rooted else null;
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

/// A machine for `defaultCommandWithHost`: the `pwsh.exe` on `PATH` (null when
/// none is launchable) and which shells live in the system directory. Asking
/// for `wsl.exe` fails the test: the default never looks for it.
fn FakeDefaultShellHost(
    comptime pwsh: ?[]const u8,
    comptime system_shells: []const []const u8,
) type {
    return struct {
        fn findPwsh(a: Allocator) !?[]u8 {
            return if (pwsh) |path| try a.dupe(u8, path) else null;
        }

        fn systemShell(a: Allocator, relative: []const u8) !?[]u8 {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(relative, "wsl.exe"));
            inline for (system_shells) |shell| {
                if (std.mem.eql(u8, shell, relative))
                    return try std.fs.path.join(a, &.{ "C:\\WINDOWS\\system32", relative });
            }
            return null;
        }

        fn systemPath(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    };
}

fn expectDefaultShell(expected: []const u8, command: Command) !void {
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(command == .direct);
    try std.testing.expectEqual(@as(usize, 1), command.direct.len);
    try std.testing.expectEqualStrings(expected, command.direct[0]);
}

const test_pwsh = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
const test_windows_powershell = "C:\\WINDOWS\\system32\\WindowsPowerShell\\v1.0\\powershell.exe";
const test_cmd = "C:\\WINDOWS\\system32\\cmd.exe";

test "default command prefers pwsh, then Windows PowerShell, then cmd" {
    const alloc = std.testing.allocator;
    const all_system = [_][]const u8{ windows_powershell_relative, "cmd.exe" };

    try expectDefaultShell(test_pwsh, try defaultCommandWithHost(alloc, FakeDefaultShellHost(test_pwsh, &all_system)));
    try expectDefaultShell(test_windows_powershell, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &all_system)));
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &.{"cmd.exe"})));
    // pwsh and cmd alone: pwsh still wins over the shells that are missing.
    try expectDefaultShell(test_pwsh, try defaultCommandWithHost(alloc, FakeDefaultShellHost(test_pwsh, &.{"cmd.exe"})));
}

test "default command falls back to bare cmd.exe when the system directory is unavailable" {
    try expectDefaultShell("cmd.exe", try defaultCommandWithHost(std.testing.allocator, FakeDefaultShellHost(null, &.{})));
}

test "cmd fallback uses absolute system path when guarded discovery rejects it" {
    const Host = struct {
        fn findPwsh(_: Allocator) !?[]u8 {
            return null;
        }
        fn systemShell(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
        fn systemPath(a: Allocator, relative: []const u8) !?[]u8 {
            try std.testing.expectEqualStrings("cmd.exe", relative);
            return try a.dupe(u8, test_cmd);
        }
    };
    const alloc = std.testing.allocator;
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, Host));
    const recovery = try commandPromptWithHost(alloc, Host, &.{"/D"});
    defer recovery.deinit(alloc);
    try std.testing.expectEqualStrings(test_cmd, recovery.direct[0]);
    try std.testing.expectEqualStrings("/D", recovery.direct[1]);
}

test "default command never picks WSL, which only the picker or an explicit command starts" {
    // wsl.exe is installed and answering as far as the profile picker is
    // concerned; the fake host fails the test if the default asks for it.
    const alloc = std.testing.allocator;
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &.{ "wsl.exe", "cmd.exe" })));
    try expectDefaultShell(test_pwsh, try defaultCommandWithHost(alloc, FakeDefaultShellHost(test_pwsh, &.{ "wsl.exe", "cmd.exe" })));
}

test "the picker starts on the profile the default command runs, not on WSL" {
    const profiles = [_]Profile{
        .{ .kind = .wsl_default, .key = "wsl-default", .label = "WSL (Default)", .command = .{ .direct = &.{"C:\\WINDOWS\\system32\\wsl.exe"} } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "WSL: Ubuntu", .command = .{ .direct = &.{ "C:\\WINDOWS\\system32\\wsl.exe", "-d", "Ubuntu" } } },
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{test_pwsh} } },
        .{ .kind = .powershell, .key = "powershell.exe", .label = "Windows PowerShell", .command = .{ .direct = &.{test_windows_powershell} } },
        .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{test_cmd} } },
    };
    try std.testing.expectEqual(@as(?usize, 2), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{test_pwsh} }));
    try std.testing.expectEqual(@as(?usize, 3), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{test_windows_powershell} }));
    try std.testing.expectEqual(@as(?usize, 4), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{"cmd.exe"} }));
    // A pwsh that is not in the list (the picker found none) leaves the choice to the caller.
    try std.testing.expectEqual(@as(?usize, null), profileIndexForDefaultCommand(profiles[0..2], .{ .direct = &.{test_pwsh} }));
    // A command that is none of the three shells is not this function's to map.
    try std.testing.expectEqual(@as(?usize, null), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{"C:\\WINDOWS\\system32\\wsl.exe"} }));
    try std.testing.expectEqual(@as(?usize, null), profileIndexForDefaultCommand(&profiles, .{ .shell = "pwsh.exe" }));
}

test "the recovery command keeps /D through launch preparation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const recovery = try recoveryCommand(alloc);
    defer recovery.deinit(alloc);
    for ([_]bool{ false, true }) |utf8_console| {
        const prepared = try prepareCommand(alloc, recovery, null, false, utf8_console);
        defer if (prepared.direct.ptr != recovery.direct.ptr) prepared.deinit(alloc);
        try std.testing.expect(prepared == .direct);
        try std.testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.basename(prepared.direct[0]), "cmd.exe"));
        // /D stays the first switch, ahead of anything the UTF-8 preamble adds.
        try std.testing.expectEqualStrings("/D", prepared.direct[1]);
    }
}

test "recovery command is cmd /D even when PowerShell is installed" {
    const alloc = std.testing.allocator;
    const all_system = [_][]const u8{ windows_powershell_relative, "cmd.exe" };
    const with_cmd = try commandPromptWithHost(alloc, FakeDefaultShellHost(test_pwsh, &all_system), &.{"/D"});
    defer with_cmd.deinit(alloc);
    try std.testing.expect(with_cmd == .direct);
    try std.testing.expectEqual(@as(usize, 2), with_cmd.direct.len);
    try std.testing.expectEqualStrings(test_cmd, with_cmd.direct[0]);
    try std.testing.expectEqualStrings("/D", with_cmd.direct[1]);

    const bare = try commandPromptWithHost(alloc, FakeDefaultShellHost(test_pwsh, &.{windows_powershell_relative}), &.{"/D"});
    defer bare.deinit(alloc);
    try std.testing.expectEqualStrings("cmd.exe", bare.direct[0]);
    try std.testing.expectEqualStrings("/D", bare.direct[1]);

    // The default command itself carries no switch.
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &.{"cmd.exe"})));
}

/// The bytes `FSCTL_GET_REPARSE_POINT` returns for an App Execution Alias made
/// of `strings`: header, version 3, each string NUL-terminated.
fn appExecLinkRecord(alloc: Allocator, strings: []const []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, &.{ 3, 0, 0, 0 });
    for (strings) |text| {
        const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
        defer alloc.free(wide);
        try body.appendSlice(alloc, std.mem.sliceAsBytes(wide));
        try body.appendSlice(alloc, &.{ 0, 0 });
    }
    var record: std.ArrayList(u8) = .empty;
    errdefer record.deinit(alloc);
    try record.appendSlice(alloc, &.{ 0x1b, 0x00, 0x00, 0x80 });
    try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(body.items.len))));
    try record.appendSlice(alloc, &.{ 0, 0 });
    try record.appendSlice(alloc, body.items);
    return try record.toOwnedSlice(alloc);
}

/// Creates an empty file `name` in `dir` and makes it an App Execution Alias to
/// `target`, as the Store does for an installed package. Skips the test where
/// the volume refuses a reparse point.
fn createTestAppExecLink(dir: std.fs.Dir, name: []const u8, target: []const u8) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Reopen it for the reparse write, without following what it will become.
    (try dir.createFile(name, .{})).close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try dir.realpath(name, &path_buf);
    const path_w = try windows.sliceToPrefixedFileW(null, path);
    const handle = windows.kernel32.CreateFileW(
        path_w.span().ptr,
        windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_OPEN_REPARSE_POINT,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.SkipZigTest;
    defer windows.CloseHandle(handle);

    const alloc = std.testing.allocator;
    const record = try appExecLinkRecord(alloc, &.{ "Test.Pkg_abc", "Test.Pkg_abc!App", target, "0" });
    defer alloc.free(record);

    const FSCTL_SET_REPARSE_POINT: windows.DWORD = 0x900a4;
    windows.DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, record, null) catch return error.SkipZigTest;
}

test "appExecLinkTarget reads the third string and rejects a cut, foreign or odd record" {
    const alloc = std.testing.allocator;
    const target = "C:\\Program Files\\WindowsApps\\x\\pwsh.exe";
    const record = try appExecLinkRecord(alloc, &.{ "Microsoft.PowerShell_8wekyb3d8bbwe", "Microsoft.PowerShell_8wekyb3d8bbwe!App", target, "0" });
    defer alloc.free(record);

    var out: [128]u16 = undefined;
    const len = appExecLinkTarget(record, &out).?;
    var utf8: [128]u8 = undefined;
    const end = try std.unicode.utf16LeToUtf8(&utf8, out[0..len]);
    try std.testing.expectEqualStrings(target, utf8[0..end]);

    // Another tag, a wrong version, a length past the buffer and a record cut
    // short are all refused.
    var other = try alloc.dupe(u8, record);
    defer alloc.free(other);
    other[3] = 0xa0;
    try std.testing.expect(appExecLinkTarget(other, &out) == null);
    var version = try alloc.dupe(u8, record);
    defer alloc.free(version);
    version[8] = 2;
    try std.testing.expect(appExecLinkTarget(version, &out) == null);
    try std.testing.expect(appExecLinkTarget(record[0 .. record.len - 40], &out) == null);
    // Even the last terminator missing: only what the call returned counts.
    try std.testing.expect(appExecLinkTarget(record[0 .. record.len - 2], &out) == null);
    try std.testing.expect(appExecLinkTarget(record[0..8], &out) == null);
    var tiny: [4]u16 = undefined;
    try std.testing.expect(appExecLinkTarget(record, &tiny) == null);

    // A record that is not exactly four terminated strings is not one Windows
    // wrote, even when its length header fits: no application type, bytes after
    // it, an empty target.
    const three = try appExecLinkRecord(alloc, &.{ "pkg", "pkg!App", target });
    defer alloc.free(three);
    try std.testing.expect(appExecLinkTarget(three, &out) == null);
    const five = try appExecLinkRecord(alloc, &.{ "pkg", "pkg!App", target, "0", "extra" });
    defer alloc.free(five);
    try std.testing.expect(appExecLinkTarget(five, &out) == null);
    const empty = try appExecLinkRecord(alloc, &.{ "pkg", "pkg!App", "", "0" });
    defer alloc.free(empty);
    try std.testing.expect(appExecLinkTarget(empty, &out) == null);
    // The unfilled tail of the zeroed buffer after a short call reads as empty strings.
    var zeroed = [_]u8{0} ** 512;
    @memcpy(zeroed[0..40], record[0..40]);
    try std.testing.expect(appExecLinkTarget(&zeroed, &out) == null);
}

test "shell discovery refuses reparse ancestors before reading the target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("real/bin");
    try tmp.dir.writeFile(.{ .sub_path = "real/bin/pwsh.exe", .data = "MZ" });
    tmp.dir.symLink("real", "link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fmt.allocPrint(alloc, "{s}\\link\\bin\\pwsh.exe", .{root});
    defer alloc.free(path);
    // Even a local ancestor link is refused: the kernel guard must reject
    // traversal before any metadata query can contact an unchecked target.
    try std.testing.expect(pathAttributes(path) == null);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.path.dirname(path).?;
    try std.testing.expect(searchPath(&buf, "pwsh.exe", dir, null, true, isLaunchableFile) == null);
}

test "shell discovery searches only ordinary local folders" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    // A real folder passes, a missing one does not (nothing to search).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    try std.testing.expect(isLocalSearchDirectory(root));
    const missing = try std.fmt.allocPrint(alloc, "{s}\\absent", .{root});
    defer alloc.free(missing);
    try std.testing.expect(!isLocalSearchDirectory(missing));
}

/// Make the existing empty folder `link` a junction to the folder `target`
/// (both absolute), which needs no privilege, unlike a symlink.
fn testMakeJunction(alloc: Allocator, link: []const u8, target: []const u8) !void {
    const nt_target = try std.fmt.allocPrint(alloc, "\\??\\{s}", .{target});
    defer alloc.free(nt_target);
    const target_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, nt_target);
    defer alloc.free(target_w);
    const link_w = try windows.sliceToPrefixedFileW(null, link);
    const handle = windows.kernel32.CreateFileW(link_w.span().ptr, windows.GENERIC_WRITE, 0, null, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT | windows.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.AccessDenied;
    defer windows.CloseHandle(handle);
    const bytes: u16 = @intCast(target_w.len * 2);
    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(alloc);
    try record.appendSlice(alloc, &.{ 3, 0, 0, 0xa0 }); // mount point
    try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, bytes + 12)));
    try record.appendSlice(alloc, &.{ 0, 0, 0, 0 }); // reserved, substitute offset
    try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, bytes)));
    try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, bytes + 2)));
    try record.appendSlice(alloc, &.{ 0, 0 }); // empty print name
    try record.appendSlice(alloc, std.mem.sliceAsBytes(target_w));
    try record.appendSlice(alloc, &.{ 0, 0, 0, 0 }); // terminators
    try windows.DeviceIoControl(handle, 0x900a4, record.items, null);
}

test "explicit commands and child PATH keep junctions with spaces" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("real");
    try tmp.dir.makePath("current tools");
    try tmp.dir.writeFile(.{ .sub_path = "real/pwsh.exe", .data = "MZ" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const link = try std.fmt.allocPrint(alloc, "{s}\\current tools", .{root});
    defer alloc.free(link);
    const real = try std.fmt.allocPrint(alloc, "{s}\\real", .{root});
    defer alloc.free(real);
    try testMakeJunction(alloc, link, real);
    const exe = try std.fmt.allocPrintSentinel(alloc, "{s}\\pwsh.exe", .{link}, 0);
    defer alloc.free(exe);
    const command = try executableCommand(alloc, .{ .shell = exe });
    defer command.deinit(alloc);
    try std.testing.expect(command == .direct);
    try std.testing.expectEqualStrings(exe, command.direct[0]);
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("PATH", link);
    const child = (try lookupChildExecutable(alloc, "pwsh.exe", &env)).?;
    defer alloc.free(child);
    try std.testing.expectEqualStrings(exe, child);
    // The same layout is deliberately excluded from automatic discovery.
    try std.testing.expect(!isLaunchableFile(exe));
}

test "local executable data reparse tags exclude redirects and cloud files" {
    for ([_]u32{ 0x80000017, 0x80000013 }) |tag| {
        try std.testing.expect(isLocalExecutableInfo(.{ .FileAttributes = windows.FILE_ATTRIBUTE_REPARSE_POINT, .ReparseTag = tag }));
        try std.testing.expect(!isLocalExecutableInfo(.{ .FileAttributes = windows.FILE_ATTRIBUTE_REPARSE_POINT | windows.FILE_ATTRIBUTE_DIRECTORY, .ReparseTag = tag }));
    }
    for ([_]u32{ 0xa000000c, 0xa0000003, 0x9000001a, 0x8000001b }) |tag|
        try std.testing.expect(!isLocalExecutableInfo(.{ .FileAttributes = windows.FILE_ATTRIBUTE_REPARSE_POINT, .ReparseTag = tag }));
}

test "shell discovery uses the production DOS mapping before metadata opens" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Reject = struct {
        fn map(_: [*:0]const u16, _: []u16) ?[]const u16 {
            return null;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "pwsh.exe", .data = "not executed" });
    const path = try tmp.dir.realpathAlloc(alloc, "pwsh.exe");
    defer alloc.free(path);
    win32.TestHooks.direct_volume_mapping = Reject.map;
    defer win32.TestHooks.direct_volume_mapping = null;
    try std.testing.expectEqual(null, pathInfo(path));
    win32.TestHooks.direct_volume_mapping = win32.TestHooks.unavailableVolume;
    try std.testing.expectEqual(null, pathInfo(path));
    win32.TestHooks.direct_volume_mapping = null;
    try std.testing.expect(pathInfo(path) != null);
}

test "shell discovery accepts a real installed Store execution alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return error.SkipZigTest;
    defer alloc.free(local);
    for ([_][]const u8{ "wt.exe", "winget.exe" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ local, "Microsoft", "WindowsApps", name });
        defer alloc.free(path);
        if (!windowsNonDirectoryPathExists(path)) continue;
        const info = pathInfo(path) orelse return error.TestUnexpectedResult;
        if (info.ReparseTag != IO_REPARSE_TAG_APPEXECLINK) continue;
        const handle = openPathNoRedirect(path) orelse return error.TestUnexpectedResult;
        defer windows.CloseHandle(handle);
        var target_buf: AppExecLinkTargetBuf = undefined;
        const target = (try readAppExecLinkTarget(handle, &target_buf)) orelse return error.TestUnexpectedResult;
        // Even a real alias's record is untrusted: screen its target before
        // the independent existence check can touch it.
        const checked = openPathNoRedirect(target) orelse {
            try std.testing.expect(!isLaunchableFile(path));
            continue;
        };
        defer windows.CloseHandle(checked);
        // A stale alias is valid evidence of layout, but not an installed
        // target. Its rejection is intentional; try another installed alias.
        if (!windowsNonDirectoryPathExists(target)) {
            try std.testing.expect(!isLaunchableFile(path));
            continue;
        }
        try std.testing.expect(isLaunchableFile(path));
        var search_buf: [std.fs.max_path_bytes]u8 = undefined;
        const found = searchPath(&search_buf, name, std.fs.path.dirname(path).?, null, true, isLaunchableFile) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(path, found);
        return;
    }
    return error.SkipZigTest;
}

test "pwsh search skips what cannot start and keeps going down PATH" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1: a directory named pwsh.exe. 2: an alias whose package is gone.
    // 3: the real thing. 4: one that must not be reached.
    try tmp.dir.makePath("dir/pwsh.exe");
    try tmp.dir.makePath("gone");
    try createTestAppExecLink(tmp.dir, "gone/pwsh.exe", "C:\\Program Files\\WindowsApps\\Missing.Package_1.0.0.0_x64__abc\\pwsh.exe");
    try tmp.dir.makePath("real");
    try tmp.dir.writeFile(.{ .sub_path = "real/pwsh.exe", .data = "MZ" });
    try tmp.dir.makePath("later");
    try tmp.dir.writeFile(.{ .sub_path = "later/pwsh.exe", .data = "MZ" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fmt.allocPrint(
        alloc,
        "\\\\server\\share;relative;\\??\\UNC\\server\\share;{s}\\dir;{s}\\gone;\"{s}\\real\";{s}\\later",
        .{ root, root, root, root },
    );
    defer alloc.free(path);
    const expected = try std.fmt.allocPrint(alloc, "{s}\\real\\pwsh.exe", .{root});
    defer alloc.free(expected);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, searchPath(&buf, "pwsh.exe", path, null, true, isLaunchableFile).?);

    // With only the dead alias and the directory on PATH nothing is found, so
    // the default moves on to Windows PowerShell instead of a shell that fails.
    const dead = try std.fmt.allocPrint(alloc, "{s}\\dir;{s}\\gone", .{ root, root });
    defer alloc.free(dead);
    try std.testing.expect(searchPath(&buf, "pwsh.exe", dead, null, true, isLaunchableFile) == null);
}

test "an App Execution Alias counts only while its target exists" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("pkg");
    try tmp.dir.writeFile(.{ .sub_path = "pkg/pwsh.exe", .data = "MZ" });
    try tmp.dir.makePath("pkg/folder");
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const present = try std.fmt.allocPrint(alloc, "{s}\\pkg\\pwsh.exe", .{root});
    defer alloc.free(present);
    const missing = try std.fmt.allocPrint(alloc, "{s}\\pkg\\nope.exe", .{root});
    defer alloc.free(missing);
    const folder = try std.fmt.allocPrint(alloc, "{s}\\pkg\\folder", .{root});
    defer alloc.free(folder);

    try createTestAppExecLink(tmp.dir, "to-present.exe", present);
    try createTestAppExecLink(tmp.dir, "to-missing.exe", missing);
    try createTestAppExecLink(tmp.dir, "to-folder.exe", folder);
    try createTestAppExecLink(tmp.dir, "to-network.exe", "\\\\server\\share\\pwsh.exe");
    try createTestAppExecLink(tmp.dir, "to-relative.exe", "pkg\\pwsh.exe");

    const check = struct {
        fn launchable(a: Allocator, dir: []const u8, name: []const u8) !bool {
            const full = try std.fmt.allocPrint(a, "{s}\\{s}", .{ dir, name });
            defer a.free(full);
            return isLaunchableFile(full);
        }
    }.launchable;
    try std.testing.expect(try check(alloc, root, "to-present.exe"));
    try std.testing.expect(!try check(alloc, root, "to-missing.exe"));
    try std.testing.expect(!try check(alloc, root, "to-folder.exe"));
    try std.testing.expect(!try check(alloc, root, "to-network.exe"));
    try std.testing.expect(!try check(alloc, root, "to-relative.exe"));
    // A plain file starts, a folder and a missing name do not.
    try std.testing.expect(try check(alloc, root, "pkg\\pwsh.exe"));
    try std.testing.expect(!try check(alloc, root, "pkg\\folder"));
    try std.testing.expect(!try check(alloc, root, "pkg\\absent.exe"));
}

test "the real machine yields a default command that exists" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const command = try defaultCommand(alloc);
    defer command.deinit(alloc);
    try std.testing.expect(command == .direct and command.direct.len == 1);
    const exe = std.fs.path.basename(command.direct[0]);
    try std.testing.expect(std.ascii.eqlIgnoreCase(exe, "pwsh.exe") or
        std.ascii.eqlIgnoreCase(exe, "powershell.exe") or std.ascii.eqlIgnoreCase(exe, "cmd.exe"));
    try std.testing.expect(isLaunchableFile(command.direct[0]));

    const recovery = try recoveryCommand(alloc);
    defer recovery.deinit(alloc);
    try std.testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.basename(recovery.direct[0]), "cmd.exe"));
    try std.testing.expectEqualStrings("/D", recovery.direct[1]);
}

/// A machine for `lookupGitBashWithHost`: the files that exist and the install
/// the Git installer registered in HKCU and HKLM. SystemRoot is `C:\WINDOWS`.
fn FakeGitBashHost(
    comptime files: []const []const u8,
    comptime registry: [git_registry_hives]?[]const u8,
) type {
    return struct {
        fn fileExists(path: []const u8) bool {
            inline for (files) |file| {
                if (std.ascii.eqlIgnoreCase(file, path)) return true;
            }
            return false;
        }

        fn registryInstallRoot(a: Allocator, index: usize) !?[]u8 {
            return if (registry[index]) |root| try a.dupe(u8, root) else null;
        }

        fn systemRoot(a: Allocator) ![]u8 {
            return try a.dupe(u8, "C:\\WINDOWS");
        }
    };
}

/// A PATH holding `git` and `bash`, each possibly absent.
fn PathLookup(comptime git: ?[]const u8, comptime bash: ?[]const u8) type {
    return struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            const found = if (std.mem.eql(u8, exe, "git.exe")) git else if (std.mem.eql(u8, exe, "bash.exe")) bash else null;
            return if (found) |path| try a.dupe(u8, path) else null;
        }
    };
}

fn expectGitBash(expected: ?[]const u8, actual: ?[]u8) !void {
    defer if (actual) |path| std.testing.allocator.free(path);
    if (expected) |want| {
        try std.testing.expectEqualStrings(want, actual orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expect(actual == null);
    }
}

const test_wsl_launcher = "C:\\WINDOWS\\system32\\bash.exe";
const test_git_bash = "C:\\Program Files\\Git\\bin\\bash.exe";

test "lookupGitBash takes the install git.exe belongs to over a WSL launcher earlier on PATH" {
    const alloc = std.testing.allocator;
    // The installer puts only Git\cmd on PATH; System32 holds WSL's bash.exe.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Program Files\\Git\\cmd\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, null }),
    ));
    // git.exe in bin, and in mingw64\bin, name the same install.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Program Files\\Git\\bin\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, null }),
    ));
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Program Files\\Git\\mingw64\\bin\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, null }),
    ));
    // A MinGit without bash does not borrow a bash.exe from a folder above its install.
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\X\\Git\\cmd\\git.exe", null).lookup,
        FakeGitBashHost(&.{"C:\\X\\bin\\bash.exe"}, .{ null, null }),
    ));
}

test "lookupGitBash falls back to the registered install, then to a PATH bash that is not WSL" {
    const alloc = std.testing.allocator;
    // No git.exe on PATH (the installer's "Git Bash only" choice): the registry names the install.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, "C:\\Program Files\\Git" }),
    ));
    // A git.exe whose install has no bash.exe (a shim, a stale entry) is skipped.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Users\\me\\scoop\\shims\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, "C:\\Program Files\\Git" }),
    ));
    // HKCU names a removed per-user install; the all-users one in HKLM still works.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ "C:\\Users\\me\\AppData\\Local\\Programs\\Git", "C:\\Program Files\\Git" }),
    ));
    // The registry points at deleted installs: PATH is next.
    try expectGitBash("C:\\msys64\\usr\\bin\\bash.exe", try lookupGitBashWithHost(
        alloc,
        PathLookup(null, "C:\\msys64\\usr\\bin\\bash.exe").lookup,
        FakeGitBashHost(&.{}, .{ "C:\\Gone\\Git", "C:\\Gone\\Too" }),
    ));
}

test "lookupGitBash offers no Git Bash when only WSL's bash.exe exists" {
    const alloc = std.testing.allocator;
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, test_wsl_launcher).lookup,
        FakeGitBashHost(&.{}, .{ null, null }),
    ));
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, "C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe").lookup,
        FakeGitBashHost(&.{}, .{ null, null }),
    ));
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, null).lookup,
        FakeGitBashHost(&.{}, .{ null, null }),
    ));
}

test "registryString reads a string value and nothing else" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const Reg = struct {
        extern "advapi32" fn RegCreateKeyExW(
            key: windows.HKEY,
            sub: [*:0]const u16,
            reserved: windows.DWORD,
            class: ?[*:0]const u16,
            options: windows.DWORD,
            sam: windows.DWORD,
            security: ?*anyopaque,
            result: *windows.HKEY,
            disposition: ?*windows.DWORD,
        ) callconv(.winapi) i32;
        extern "advapi32" fn RegSetValueExW(
            key: windows.HKEY,
            name: [*:0]const u16,
            reserved: windows.DWORD,
            kind: windows.DWORD,
            data: [*]const u8,
            size: windows.DWORD,
        ) callconv(.winapi) i32;
        extern "advapi32" fn RegDeleteKeyW(key: windows.HKEY, sub: [*:0]const u16) callconv(.winapi) i32;
    };
    const reg_sz: windows.DWORD = 1;
    const reg_dword: windows.DWORD = 4;
    const key_write: windows.DWORD = 0x20006;

    // A key of this test's own, under HKCU, deleted at the end.
    const key_name = try std.fmt.allocPrint(alloc, "Software\\noctty-test-pkg17-{d}", .{windows.GetCurrentProcessId()});
    defer alloc.free(key_name);
    const subkey = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_name);
    defer alloc.free(subkey);
    const value = std.unicode.utf8ToUtf16LeStringLiteral("InstallPath");

    try testing.expect((try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)) == null);

    var key: windows.HKEY = undefined;
    try testing.expectEqual(@as(i32, 0), Reg.RegCreateKeyExW(windows.HKEY_CURRENT_USER, subkey, 0, null, 0, key_write, null, &key, null));
    defer _ = Reg.RegDeleteKeyW(windows.HKEY_CURRENT_USER, subkey);
    defer _ = windows.advapi32.RegCloseKey(key);

    // Present but not a string.
    const number: windows.DWORD = 7;
    try testing.expectEqual(@as(i32, 0), Reg.RegSetValueExW(key, value, 0, reg_dword, @ptrCast(&number), @sizeOf(windows.DWORD)));
    try testing.expect((try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)) == null);

    // Empty.
    const empty = [_]u16{0};
    try testing.expectEqual(@as(i32, 0), Reg.RegSetValueExW(key, value, 0, reg_sz, @ptrCast(&empty), @sizeOf(@TypeOf(empty))));
    try testing.expect((try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)) == null);

    const root = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Git");
    try testing.expectEqual(@as(i32, 0), Reg.RegSetValueExW(key, value, 0, reg_sz, @ptrCast(root), @intCast((root.len + 1) * @sizeOf(u16))));
    const got = (try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("C:\\Program Files\\Git", got);
}

test "isWslBashLauncher matches the Windows folders whatever the case or separator" {
    const root = "C:\\WINDOWS";
    try std.testing.expect(isWslBashLauncher("C:\\WINDOWS\\system32\\bash.exe", root));
    try std.testing.expect(isWslBashLauncher("c:\\windows\\System32\\bash.exe", root));
    try std.testing.expect(isWslBashLauncher("C:/Windows/Sysnative/bash.exe", root));
    try std.testing.expect(isWslBashLauncher("C:\\Windows\\SysWOW64\\bash.exe", "C:\\Windows\\"));
    try std.testing.expect(isWslBashLauncher("C:\\Users\\me\\AppData\\Local\\Microsoft\\windowsapps\\bash.exe", root));

    try std.testing.expect(!isWslBashLauncher("C:\\Program Files\\Git\\usr\\bin\\bash.exe", root));
    // A sibling folder that only shares the prefix, and the root itself.
    try std.testing.expect(!isWslBashLauncher("C:\\Windows.old\\bash.exe", root));
    try std.testing.expect(!isWslBashLauncher("C:\\WINDOWS", root));
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

test "conemuPathToLocal reads the plain path of OSC 9;9" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "C:\\Users\\aman\\src", "C:\\Users\\aman\\src" },
        // oh-my-posh quotes the path.
        .{ "\"C:\\Users\\aman\\src\"", "C:\\Users\\aman\\src" },
        // A path with spaces needs no quotes of its own.
        .{ "C:\\Program Files\\Git", "C:\\Program Files\\Git" },
        // A forward slash is the other separator, and the letter keeps its case.
        .{ "d:/work/noctty", "d:\\work\\noctty" },
        .{ "C:\\", "C:\\" },
        .{ "C:/", "C:\\" },
    };
    for (cases) |case| {
        const result = (try conemuPathToLocal(alloc, case[0])).?;
        defer alloc.free(result);
        try testing.expectEqualStrings(case[1], result);
    }
}

test "conemuPathToLocal maps the UNC form wslpath prints to the distro's own path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\\\\wsl.localhost\\Ubuntu\\home\\aman\\src", "/home/aman/src" },
        .{ "\\\\wsl$\\Ubuntu\\home\\aman", "/home/aman" },
        .{ "\"\\\\wsl.localhost\\Ubuntu-24.04\\mnt\\data\"", "/mnt/data" },
        .{ "\\\\wsl.localhost\\Ubuntu", "/" },
    };
    for (cases) |case| {
        const result = (try conemuPathToLocal(alloc, case[0])).?;
        defer alloc.free(result);
        try testing.expectEqualStrings(case[1], result);
    }
}

test "conemuPathToLocal leaves everything but a drive-absolute path to the caller" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_][]const u8{
        // The URL forms, including the one noctty's cmd integration sends.
        "kitty-shell-cwd://localhost/C:\\Users\\aman",
        "file://localhost/C:/Users/aman",
        // Not drive-absolute, and not WSL's own UNC form.
        "",
        "\"\"",
        "C:",
        "C:Users",
        "Users\\aman",
        "\\Users\\aman",
        "/mnt/c/Users",
        "\\\\server\\share",
        "\\\\server\\wsl.localhost\\share",
        "\\\\?\\UNC\\server\\share",
        "\\\\.\\pipe\\x",
        "\\\\wsl",
        // One pair of quotes only, and both of them.
        "\"\"C:\\Users\"\"",
        "\"C:\\Users",
        "C:\\Users\"",
    }) |value| {
        try testing.expect(try conemuPathToLocal(alloc, value) == null);
    }
}

test "msysDrivePathToWindows reads the drive paths MSYS2 and Cygwin print" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct { []const u8, []const u8 }{
        // The reporter's `pwd` in an MSYS2 fish (#514).
        .{ "/c/Users/FengYu/.config/fish/conf.d", "C:\\Users\\FengYu\\.config\\fish\\conf.d" },
        .{ "/cygdrive/c/Users/me", "C:\\Users\\me" },
        .{ "/D/work", "D:\\work" },
        // A location stays on for the resolver to take off.
        .{ "/c/src/main.zig:12:5", "C:\\src\\main.zig:12:5" },
        // A doubled separator never makes a share out of the rest.
        .{ "/c//server/share", "C:\\server\\share" },
        // `..` is fine while it stays below the drive's root.
        .{ "/c/x/../y", "C:\\x\\..\\y" },
        .{ "/c/.../x", "C:\\...\\x" },
    };
    for (cases) |case| {
        const result = try msysDrivePathToWindows(alloc, case[0]) orelse return error.TestUnexpectedResult;
        defer alloc.free(result);
        try testing.expectEqualStrings(case[1], result);
        try testing.expect(isMsysDrivePath(case[0]));
        const dir = try msysDriveDirToWindows(alloc, case[0]) orelse return error.TestUnexpectedResult;
        defer alloc.free(dir);
        try testing.expectEqualStrings(case[1], dir);
    }

    // A drive's root is a directory a shell can report (`cd /c; pwd`), but
    // never link text: `cmd /c "x"`, `findstr /c:x` and `xcopy /s /e` would
    // open the root of C:, S: and E: (#520 review).
    for ([_]struct { []const u8, []const u8 }{
        .{ "/c", "C:\\" },
        .{ "/C", "C:\\" },
        .{ "/c/", "C:\\" },
        .{ "/cygdrive/c", "C:\\" },
        .{ "/cygdrive/c/", "C:\\" },
        .{ "/c/.", "C:\\." },
        .{ "/c/x/..", "C:\\x\\.." },
        // Windows drops a final name of dots and spaces.
        .{ "/c/...", "C:\\..." },
        .{ "/c/ .", "C:\\ ." },
    }) |case| {
        try testing.expect(try msysDrivePathToWindows(alloc, case[0]) == null);
        try testing.expect(!isMsysDrivePath(case[0]));
        const dir = try msysDriveDirToWindows(alloc, case[0]) orelse return error.TestUnexpectedResult;
        defer alloc.free(dir);
        try testing.expectEqualStrings(case[1], dir);
    }

    for ([_][]const u8{
        // A `..` above the drive is MSYS2's own root (`/c/..` is `/`).
        "/c/..",
        "/c/x/../..",
        "/c/x/../../y",
        "/cygdrive/c/..",
        "",
        "/",
        "c/Users",
        "C:\\Users",
        "C:/Users",
        // noctty's Git Bash integration sends this form, a Windows path.
        "/C:/Users",
        "/cd/x",
        "/home/me",
        "/usr/bin",
        "/cygdrive",
        "/cygdrive/",
        "/cygdrive/cd/x",
        "/1/x",
        "/_/x",
        "\\c\\Users",
        // Shares and devices are never drives.
        "//server/share",
        "//c/share",
        "/\\server\\share",
        "\\\\server\\share",
        "//?/UNC/server/share",
        "\\\\.\\pipe\\x",
    }) |path| {
        try testing.expect(try msysDrivePathToWindows(alloc, path) == null);
        try testing.expect(!isMsysDrivePath(path));
        try testing.expect(try msysDriveDirToWindows(alloc, path) == null);
    }
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

    // A host with no share is not a usable UNC path, so it is a POSIX name.
    for ([_][]const u8{ "/\\\\server", "/\\\\server\\" }) |path| {
        const kept = try osc7PathToLocal(alloc, path);
        defer alloc.free(kept);
        try testing.expectEqualStrings(path, kept);
    }
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
