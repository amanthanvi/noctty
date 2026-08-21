const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const win32_powershell_install = @import("../apprt/win32_powershell_install.zig");
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const Shell = enum {
    bash,
    elvish,
    fish,
    nushell,
    zsh,
    /// PowerShell 5.1+ / pwsh 7+. Detection covers `pwsh`, `pwsh.exe`,
    /// `powershell`, `powershell.exe`. Automatic injection only wraps
    /// interactive shell launches; explicit `-Command` / `-File` entry
    /// points are left untouched so exit behavior and payload semantics
    /// are preserved.
    powershell,
    /// Windows Command Prompt. `PROMPT` supplies prompt/cwd marks, and an
    /// optional Clink script supplies command-start/command-finish marks.
    cmd,
};

/// The result of setting up a shell integration.
pub const ShellIntegration = struct {
    /// The successfully-integrated shell.
    shell: Shell,

    /// The command to use to start the shell with the integration.
    /// In most cases this is identical to the command given but for
    /// bash in particular it may be different.
    ///
    /// The memory is allocated in the arena given to setup.
    command: config.Command,
};

/// Set up the command execution environment for automatic
/// integrated shell integration and return a ShellIntegration
/// struct describing the integration.  If integration fails
/// (shell type couldn't be detected, etc.), this will return null.
///
/// The allocator is used for temporary values and to allocate values
/// in the ShellIntegration result. It is expected to be an arena to
/// simplify cleanup.
pub fn setup(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: config.Command,
    env: *EnvMap,
    force_shell: ?Shell,
) !?ShellIntegration {
    const shell: Shell = force_shell orelse
        try detectShell(alloc_arena, command) orelse
        return null;

    const new_command: config.Command = switch (shell) {
        .bash => try setupBash(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .nushell => try setupNushell(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .zsh => try setupZsh(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),

        .elvish, .fish => xdg: {
            if (!try setupXdgDataDirs(alloc_arena, resource_dir, env)) return null;
            break :xdg try command.clone(alloc_arena);
        },

        .powershell => try setupPowerShell(alloc_arena, command, resource_dir),

        .cmd => try setupCmd(
            alloc_arena,
            command,
            resource_dir,
            env,
        ),
    } orelse return null;

    return .{
        .shell = shell,
        .command = new_command,
    };
}

test "force shell" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).@"enum".fields) |field| {
        const shell = @field(Shell, field.name);

        var res: TmpResourcesDir = try .init(alloc, shell);
        defer res.deinit();

        const command: config.Command = switch (shell) {
            .powershell => .{ .direct = &.{"pwsh.exe"} },
            .cmd => .{ .direct = &.{"cmd.exe"} },
            else => .{ .shell = "sh" },
        };

        const result = try setup(
            alloc,
            res.path,
            command,
            &env,
            shell,
        );
        if ((shell == .powershell or shell == .cmd) and
            builtin.os.tag != .windows)
        {
            try testing.expect(result == null);
        } else {
            try testing.expectEqual(shell, result.?.shell);
        }
    }
}

test "shell integration failure" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const result = try setup(
        alloc,
        "/nonexistent",
        .{ .shell = "sh" },
        &env,
        null,
    );

    try testing.expect(result == null);
    try testing.expectEqual(0, env.count());
}

fn detectShell(alloc: Allocator, command: config.Command) !?Shell {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    const arg0 = arg_iter.next() orelse return null;
    const exe = std.fs.path.basename(arg0);

    if (std.ascii.eqlIgnoreCase(exe, "bash") or std.ascii.eqlIgnoreCase(exe, "bash.exe")) {
        // Apple distributes their own patched version of Bash 3.2
        // on macOS that disables the ENV-based POSIX startup path.
        // This means we're unable to perform our automatic shell
        // integration sequence in this specific environment.
        //
        // If we're running "/bin/bash" on Darwin, we can assume
        // we're using Apple's Bash because /bin is non-writable
        // on modern macOS due to System Integrity Protection.
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (std.mem.eql(u8, "/bin/bash", arg0)) {
                return null;
            }
        }
        return .bash;
    }

    if (std.mem.eql(u8, "elvish", exe)) return .elvish;
    if (std.mem.eql(u8, "fish", exe)) return .fish;
    if (std.mem.eql(u8, "nu", exe)) return .nushell;
    if (std.mem.eql(u8, "zsh", exe)) return .zsh;

    // PowerShell — both Windows PowerShell (5.1) and pwsh (7+). Case-
    // insensitive match on the basename so `pwsh.EXE` from Explorer
    // drag-drop still resolves.
    if (std.ascii.eqlIgnoreCase(exe, "pwsh") or
        std.ascii.eqlIgnoreCase(exe, "pwsh.exe") or
        std.ascii.eqlIgnoreCase(exe, "powershell") or
        std.ascii.eqlIgnoreCase(exe, "powershell.exe"))
    {
        return .powershell;
    }

    if (std.ascii.eqlIgnoreCase(exe, "cmd") or
        std.ascii.eqlIgnoreCase(exe, "cmd.exe"))
    {
        return .cmd;
    }

    return null;
}

test detectShell {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(try detectShell(alloc, .{ .shell = "sh" }) == null);
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "BASH" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{
        .direct = &.{ "bash.exe", "--login", "-i" },
    }));
    if (builtin.target.os.tag == .windows) {
        try testing.expectEqual(.bash, try detectShell(alloc, .{
            .direct = &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" },
        }));
    }
    try testing.expectEqual(.elvish, try detectShell(alloc, .{ .shell = "elvish" }));
    try testing.expectEqual(.fish, try detectShell(alloc, .{ .shell = "fish" }));
    try testing.expectEqual(.nushell, try detectShell(alloc, .{ .shell = "nu" }));
    try testing.expectEqual(.zsh, try detectShell(alloc, .{ .shell = "zsh" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "pwsh" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "pwsh.exe" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "powershell" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "PowerShell.EXE" }));
    try testing.expectEqual(.powershell, try detectShell(alloc, .{ .shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoProfile" }));
    try testing.expectEqual(.cmd, try detectShell(alloc, .{ .shell = "cmd" }));
    try testing.expectEqual(.cmd, try detectShell(alloc, .{ .shell = "cmd.exe" }));
    try testing.expectEqual(.cmd, try detectShell(alloc, .{
        .direct = &.{"C:\\Windows\\System32\\cmd.exe"},
    }));

    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expect(try detectShell(alloc, .{ .shell = "/bin/bash" }) == null);
    }

    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "bash -c 'command'" }));
    try testing.expectEqual(.bash, try detectShell(alloc, .{ .shell = "\"/a b/bash\"" }));
}

test "setup powershell: interactive direct command auto injects" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const command: config.Command = .{ .direct = &.{ "pwsh.exe", "-NoProfile" } };
    const result = (try setup(alloc, res.path, command, &env, .powershell)).?;

    const expected_path = try std.fs.path.join(alloc, &.{ res.path, "shell-integration", "powershell", "integration.ps1" });
    defer alloc.free(expected_path);
    const expected_command = try std.fmt.allocPrint(
        alloc,
        "& {{ . '{s}' }}",
        .{expected_path},
    );
    defer alloc.free(expected_command);

    try testing.expectEqual(.powershell, result.shell);
    try testing.expect(result.command == .direct);
    try testing.expectEqual(@as(usize, 5), result.command.direct.len);
    try testing.expectEqualStrings("pwsh.exe", result.command.direct[0]);
    try testing.expectEqualStrings("-NoProfile", result.command.direct[1]);
    try testing.expectEqualStrings("-NoExit", result.command.direct[2]);
    try testing.expectEqualStrings("-Command", result.command.direct[3]);
    try testing.expectEqualStrings(expected_command, result.command.direct[4]);
}

test "setup powershell: interactive shell command auto injects" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const command: config.Command = .{ .shell = "powershell.exe -NoProfile" };
    const result = (try setup(alloc, res.path, command, &env, .powershell)).?;

    const expected_path = try std.fs.path.join(alloc, &.{ res.path, "shell-integration", "powershell", "integration.ps1" });
    defer alloc.free(expected_path);
    const expected_command = try std.fmt.allocPrint(
        alloc,
        "& {{ . '{s}' }}",
        .{expected_path},
    );
    defer alloc.free(expected_command);

    try testing.expectEqual(.powershell, result.shell);
    try testing.expect(result.command == .direct);
    try testing.expectEqual(@as(usize, 5), result.command.direct.len);
    try testing.expectEqualStrings("powershell.exe", result.command.direct[0]);
    try testing.expectEqualStrings("-NoProfile", result.command.direct[1]);
    try testing.expectEqualStrings("-NoExit", result.command.direct[2]);
    try testing.expectEqualStrings("-Command", result.command.direct[3]);
    try testing.expectEqualStrings(expected_command, result.command.direct[4]);
}

test "setup powershell: interactive shell command with quoted exe path auto injects" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const command: config.Command = .{ .shell = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoProfile" };
    const result = (try setup(alloc, res.path, command, &env, .powershell)).?;

    const expected_path = try std.fs.path.join(alloc, &.{ res.path, "shell-integration", "powershell", "integration.ps1" });
    defer alloc.free(expected_path);
    const expected_command = try std.fmt.allocPrint(
        alloc,
        "& {{ . '{s}' }}",
        .{expected_path},
    );
    defer alloc.free(expected_command);

    try testing.expectEqual(.powershell, result.shell);
    try testing.expect(result.command == .direct);
    try testing.expectEqual(@as(usize, 5), result.command.direct.len);
    try testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", result.command.direct[0]);
    try testing.expectEqualStrings("-NoProfile", result.command.direct[1]);
    try testing.expectEqualStrings("-NoExit", result.command.direct[2]);
    try testing.expectEqualStrings("-Command", result.command.direct[3]);
    try testing.expectEqualStrings(expected_command, result.command.direct[4]);
}

test "setup powershell: explicit command launch is not wrapped" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const result = try setup(
        alloc,
        res.path,
        .{ .direct = &.{ "pwsh.exe", "-Command", "Get-Date" } },
        &env,
        .powershell,
    );

    try testing.expect(result == null);
}

test "setup powershell: explicit short command launch is not wrapped" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const result = try setup(
        alloc,
        res.path,
        .{ .shell = "pwsh.exe -c Get-Date" },
        &env,
        .powershell,
    );

    try testing.expect(result == null);
}

test "setup powershell: explicit command prefix launch is not wrapped" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const result = try setup(
        alloc,
        res.path,
        .{ .shell = "powershell.exe -Com Get-Date" },
        &env,
        .powershell,
    );

    try testing.expect(result == null);
}

test "setup powershell: slash-prefixed interactive launch auto injects" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const command: config.Command = .{ .shell = "pwsh.exe /NoProfile" };
    const result = (try setup(alloc, res.path, command, &env, .powershell)).?;

    const expected_path = try std.fs.path.join(alloc, &.{ res.path, "shell-integration", "powershell", "integration.ps1" });
    defer alloc.free(expected_path);
    const expected_command = try std.fmt.allocPrint(
        alloc,
        "& {{ . '{s}' }}",
        .{expected_path},
    );
    defer alloc.free(expected_command);

    try testing.expectEqual(.powershell, result.shell);
    try testing.expect(result.command == .direct);
    try testing.expectEqual(@as(usize, 5), result.command.direct.len);
    try testing.expectEqualStrings("pwsh.exe", result.command.direct[0]);
    try testing.expectEqualStrings("/NoProfile", result.command.direct[1]);
    try testing.expectEqualStrings("-NoExit", result.command.direct[2]);
    try testing.expectEqualStrings("-Command", result.command.direct[3]);
    try testing.expectEqualStrings(expected_command, result.command.direct[4]);
}

test "setup powershell: slash version launch is not wrapped" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    var res: TmpResourcesDir = try .init(alloc, .powershell);
    defer res.deinit();

    const result = try setup(
        alloc,
        res.path,
        .{ .shell = "powershell.exe /Version" },
        &env,
        .powershell,
    );

    try testing.expect(result == null);
}

fn setupPowerShell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
) !?config.Command {
    if (builtin.os.tag != .windows) return null;

    const integration_path = try std.fs.path.join(
        alloc,
        &.{ resource_dir, "shell-integration", "powershell", "integration.ps1" },
    );
    defer alloc.free(integration_path);

    std.fs.accessAbsolute(integration_path, .{}) catch return null;

    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    while (arg_iter.next()) |arg| {
        try argv.append(alloc, arg);
    }

    const injected = (try win32_powershell_install.buildInjectedArgv(
        alloc,
        argv.items,
        integration_path,
    )) orelse return null;

    return .{ .direct = injected };
}

const cmd_default_prompt = "$P$G";
// OSC 9;9 feeds the same cwd handler as OSC 7, so use its accepted URI form.
// The kitty scheme keeps cmd's unescaped `$P` Windows path intact.
const cmd_prompt_osc_a = "$E]133;A$E\\";
const cmd_prompt_prefix = cmd_prompt_osc_a ++
    "$E]9;9;kitty-shell-cwd://localhost/$P$E\\";
const cmd_prompt_suffix = "$E]133;B$E\\";
const cmd_clink_executables = [_][]const u8{
    "clink.bat",
    "clink_x64.exe",
};
const CmdClinkDetectionCache = struct {
    mutex: std.Thread.Mutex = .{},
    snapshot: ?Snapshot = null,

    const Snapshot = struct {
        path: []u8,
        local_app_data: []u8,
        installed: bool,
    };
};
var cmd_clink_detection_cache: CmdClinkDetectionCache = .{};

/// Build a cmd PROMPT value that preserves the user's prompt while adding
/// prompt boundaries and the current working directory. `$E` is ESC in cmd's
/// PROMPT syntax; ESC followed by `\\` terminates each OSC sequence.
fn buildCmdPrompt(alloc: Allocator, existing: ?[]const u8) ![]u8 {
    if (existing) |current| {
        if (std.mem.startsWith(u8, current, cmd_prompt_osc_a)) {
            return try alloc.dupe(u8, current);
        }
    }

    return try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ cmd_prompt_prefix, existing orelse cmd_default_prompt, cmd_prompt_suffix },
    );
}

fn composeCmdClinkPath(
    alloc: Allocator,
    existing: ?[]const u8,
    integration_dir: []const u8,
) ![]u8 {
    const current = existing orelse "";
    if (current.len == 0) return try alloc.dupe(u8, integration_dir);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    try result.appendSlice(alloc, integration_dir);

    var dirs = std.mem.splitScalar(u8, current, ';');
    while (dirs.next()) |raw_dir| {
        const dir = std.mem.trim(u8, raw_dir, " \t\"");
        if (std.ascii.eqlIgnoreCase(dir, integration_dir)) continue;
        try result.append(alloc, ';');
        try result.appendSlice(alloc, raw_dir);
    }

    return try result.toOwnedSlice(alloc);
}

fn cmdClinkIntegrationDirSafe(integration_dir: []const u8) bool {
    return std.mem.indexOfScalar(u8, integration_dir, ';') == null;
}

fn setupCmd(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    if (builtin.os.tag != .windows) return null;
    if (!isInteractiveCmd(alloc, command)) return null;

    const prompt = try buildCmdPrompt(alloc, env.get("PROMPT"));
    defer alloc.free(prompt);
    try env.put("PROMPT", prompt);

    const integration_dir = try std.fs.path.join(alloc, &.{
        resource_dir,
        "shell-integration",
        "cmd",
    });
    defer alloc.free(integration_dir);

    if (!cmdClinkIntegrationDirSafe(integration_dir)) {
        log.warn(
            "cmd Clink integration disabled because its path contains a semicolon path={s}",
            .{integration_dir},
        );
        return try command.clone(alloc);
    }

    if (try clinkInstalled(alloc, env)) {
        const script_path = try std.fs.path.join(alloc, &.{
            integration_dir,
            "clink.lua",
        });
        defer alloc.free(script_path);

        if (fileExistsAbsolute(script_path)) {
            const clink_path = try composeCmdClinkPath(
                alloc,
                env.get("CLINK_PATH"),
                integration_dir,
            );
            defer alloc.free(clink_path);
            try env.put("CLINK_PATH", clink_path);
        } else {
            log.warn("cmd Clink integration script is unavailable path={s}", .{script_path});
        }
    }

    return try command.clone(alloc);
}

fn isInteractiveCmd(alloc: Allocator, command: config.Command) bool {
    var arg_iter = command.argIterator(alloc) catch return false;
    defer arg_iter.deinit();

    _ = arg_iter.next() orelse return false;
    while (arg_iter.next()) |arg| {
        if (cmdMode(arg)) |keep_open| return keep_open;
    }
    return true;
}

fn cmdMode(arg: []const u8) ?bool {
    if (arg.len < 2 or arg[0] != '/') return null;

    var index: usize = 0;
    while (index + 1 < arg.len) : (index += 1) {
        if (arg[index] != '/') continue;
        switch (std.ascii.toLower(arg[index + 1])) {
            'c', 'r' => return false,
            'k' => return true,
            else => {},
        }
    }

    return null;
}

fn clinkInstalled(alloc: Allocator, env: *const EnvMap) !bool {
    if (builtin.os.tag != .windows) return false;

    const path = env.get("PATH") orelse "";
    const local_app_data = env.get("LOCALAPPDATA") orelse "";

    cmd_clink_detection_cache.mutex.lock();
    defer cmd_clink_detection_cache.mutex.unlock();

    if (cmd_clink_detection_cache.snapshot) |snapshot| {
        if (std.mem.eql(u8, snapshot.path, path) and
            std.mem.eql(u8, snapshot.local_app_data, local_app_data))
        {
            return snapshot.installed;
        }
    }

    const installed = try clinkInstalledUncached(alloc, path, local_app_data);
    const cache_alloc = std.heap.page_allocator;
    const path_copy = try cache_alloc.dupe(u8, path);
    errdefer cache_alloc.free(path_copy);
    const local_app_data_copy = try cache_alloc.dupe(u8, local_app_data);
    errdefer cache_alloc.free(local_app_data_copy);

    if (cmd_clink_detection_cache.snapshot) |snapshot| {
        cache_alloc.free(snapshot.path);
        cache_alloc.free(snapshot.local_app_data);
    }
    cmd_clink_detection_cache.snapshot = .{
        .path = path_copy,
        .local_app_data = local_app_data_copy,
        .installed = installed,
    };
    return installed;
}

fn clinkInstalledUncached(
    alloc: Allocator,
    path: []const u8,
    local_app_data: []const u8,
) !bool {
    if (local_app_data.len > 0) {
        const local_clink_dir = try std.fs.path.resolve(
            alloc,
            &.{ local_app_data, "clink" },
        );
        defer alloc.free(local_clink_dir);
        if (try directoryContainsClink(alloc, local_clink_dir)) return true;
    }

    if (path.len > 0) {
        var dirs = std.mem.splitScalar(u8, path, ';');
        while (dirs.next()) |raw_dir| {
            const dir = std.mem.trim(u8, raw_dir, " \t\"");
            if (cmdPathEntrySafeToProbe(dir) and
                try directoryContainsClink(alloc, dir)) return true;
        }
    }

    return false;
}

fn cmdPathEntrySafeToProbe(dir: []const u8) bool {
    return dir.len >= 3 and
        std.ascii.isAlphabetic(dir[0]) and
        dir[1] == ':' and
        (dir[2] == '\\' or dir[2] == '/');
}

fn directoryContainsClink(alloc: Allocator, dir: []const u8) !bool {
    for (cmd_clink_executables) |exe| {
        const candidate = try std.fs.path.resolve(alloc, &.{ dir, exe });
        defer alloc.free(candidate);
        if (fileExistsAbsolute(candidate)) return true;
    }
    return false;
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "cmd prompt construction defaults and preserves escapes" {
    const testing = std.testing;

    const prompt = try buildCmdPrompt(testing.allocator, null);
    defer testing.allocator.free(prompt);

    try testing.expectEqualStrings(
        "$E]133;A$E\\$E]9;9;kitty-shell-cwd://localhost/$P$E\\$P$G$E]133;B$E\\",
        prompt,
    );
}

test "cmd prompt construction preserves user prompt" {
    const testing = std.testing;

    const prompt = try buildCmdPrompt(testing.allocator, "[$T] $P$_$$ ");
    defer testing.allocator.free(prompt);

    try testing.expectEqualStrings(
        "$E]133;A$E\\$E]9;9;kitty-shell-cwd://localhost/$P$E\\[$T] $P$_$$ $E]133;B$E\\",
        prompt,
    );
}

test "cmd prompt construction is idempotent" {
    const testing = std.testing;

    const prompt = try buildCmdPrompt(testing.allocator, "[$T] $P$_$$ ");
    defer testing.allocator.free(prompt);
    const repeated = try buildCmdPrompt(testing.allocator, prompt);
    defer testing.allocator.free(repeated);

    try testing.expectEqualStrings(prompt, repeated);
}

test "cmd Clink path composition prepends once and rejects semicolons" {
    const testing = std.testing;

    const empty = try composeCmdClinkPath(testing.allocator, "", "C:\\noctty\\cmd");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("C:\\noctty\\cmd", empty);

    const existing = try composeCmdClinkPath(
        testing.allocator,
        "C:\\user\\clink;D:\\shared\\clink",
        "C:\\noctty\\cmd",
    );
    defer testing.allocator.free(existing);
    try testing.expectEqualStrings(
        "C:\\noctty\\cmd;C:\\user\\clink;D:\\shared\\clink",
        existing,
    );

    const idempotent = try composeCmdClinkPath(
        testing.allocator,
        existing,
        "C:\\noctty\\cmd",
    );
    defer testing.allocator.free(idempotent);
    try testing.expectEqualStrings(existing, idempotent);

    const repeated = try composeCmdClinkPath(
        testing.allocator,
        "C:\\user\\clink;C:\\noctty\\cmd;D:\\shared\\clink",
        "C:\\noctty\\cmd",
    );
    defer testing.allocator.free(repeated);
    try testing.expectEqualStrings(
        "C:\\noctty\\cmd;C:\\user\\clink;D:\\shared\\clink",
        repeated,
    );

    try testing.expect(cmdClinkIntegrationDirSafe("C:\\noctty\\cmd"));
    try testing.expect(!cmdClinkIntegrationDirSafe("C:\\unsafe;path\\cmd"));
}

test "cmd Clink detection covers PATH and LocalAppData" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("path-bat");
    try tmp_dir.dir.makePath("path-x64");
    try tmp_dir.dir.makePath("local/clink");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "path-bat/clink.bat",
        .data = "",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "path-x64/clink_x64.exe",
        .data = "",
    });

    const root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    const path_bat = try std.fs.path.join(alloc, &.{ root, "path-bat" });
    const path_x64 = try std.fs.path.join(alloc, &.{ root, "path-x64" });
    const local_app_data = try std.fs.path.join(alloc, &.{ root, "local" });

    try testing.expect(try clinkInstalledUncached(alloc, path_bat, ""));
    try testing.expect(try clinkInstalledUncached(alloc, path_x64, ""));
    try testing.expect(!try clinkInstalledUncached(alloc, "", local_app_data));

    try tmp_dir.dir.writeFile(.{
        .sub_path = "local/clink/clink_x64.exe",
        .data = "",
    });
    try testing.expect(try clinkInstalledUncached(alloc, path_bat, local_app_data));

    try testing.expect(cmdPathEntrySafeToProbe(path_bat));
    try testing.expect(!cmdPathEntrySafeToProbe("relative\\clink"));
    try testing.expect(!cmdPathEntrySafeToProbe("C:relative\\clink"));
    try testing.expect(!cmdPathEntrySafeToProbe("\\rooted\\clink"));
    try testing.expect(!cmdPathEntrySafeToProbe("\\\\server\\share\\clink"));
    try testing.expect(!cmdPathEntrySafeToProbe("//server/share/clink"));
    try testing.expect(cmdPathEntrySafeToProbe("D:/absolute/clink"));
}

test "cmd Clink setup fails closed for semicolon integration path" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("resources;unsafe/shell-integration/cmd");
    try tmp_dir.dir.makePath("local/clink");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "resources;unsafe/shell-integration/cmd/clink.lua",
        .data = "",
    });
    try tmp_dir.dir.writeFile(.{
        .sub_path = "local/clink/clink_x64.exe",
        .data = "",
    });

    const root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    const resource_dir = try std.fs.path.join(alloc, &.{ root, "resources;unsafe" });
    const local_app_data = try std.fs.path.join(alloc, &.{ root, "local" });

    var env = EnvMap.init(alloc);
    defer env.deinit();
    try env.put("LOCALAPPDATA", local_app_data);
    try env.put("CLINK_PATH", "C:\\trusted\\clink");

    _ = (try setupCmd(
        alloc,
        .{ .direct = &.{"cmd.exe"} },
        resource_dir,
        &env,
    )).?;
    try testing.expectEqualStrings("C:\\trusted\\clink", env.get("CLINK_PATH").?);
}

test "cmd Clink detection caches one environment snapshot" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("path");
    try tmp_dir.dir.makePath("local");

    const root = try tmp_dir.dir.realpathAlloc(alloc, ".");
    const path = try std.fs.path.join(alloc, &.{ root, "path" });
    const local_app_data = try std.fs.path.join(alloc, &.{ root, "local" });

    var env = EnvMap.init(alloc);
    defer env.deinit();
    try env.put("PATH", path);
    try env.put("LOCALAPPDATA", local_app_data);

    try testing.expect(!try clinkInstalled(alloc, &env));
    try tmp_dir.dir.writeFile(.{
        .sub_path = "path/clink.bat",
        .data = "",
    });
    try testing.expect(!try clinkInstalled(alloc, &env));

    const changed_path = try std.fmt.allocPrint(alloc, "{s};relative", .{path});
    try env.put("PATH", changed_path);
    try testing.expect(try clinkInstalled(alloc, &env));
}

test "cmd integration follows cmd slash switch modes" {
    const testing = std.testing;

    try testing.expect(!isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/C", "payload" },
    }));
    try testing.expect(!isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/Cpayload" },
    }));
    try testing.expect(!isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/D", "/Q", "/C", "payload" },
    }));
    try testing.expect(!isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/d/q/c", "payload" },
    }));
    try testing.expect(!isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/R", "payload" },
    }));
    try testing.expect(!isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/C/K", "payload" },
    }));
    try testing.expect(isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/K" },
    }));
    try testing.expect(isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/D", "/Q", "/K" },
    }));
    try testing.expect(isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/K", "chcp 65001 >nul" },
    }));
    try testing.expect(isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "/K/C", "payload" },
    }));
    try testing.expect(isInteractiveCmd(testing.allocator, .{
        .direct = &.{ "cmd.exe", "-c", "payload" },
    }));
    try testing.expect(isInteractiveCmd(testing.allocator, .{
        .direct = &.{"cmd.exe"},
    }));
}

/// Set up the shell integration features environment variable.
pub fn setupFeatures(
    env: *EnvMap,
    features: config.ShellIntegrationFeatures,
    cursor_blink: bool,
) !void {
    const fields = @typeInfo(@TypeOf(features)).@"struct".fields;
    const capacity: usize = capacity: {
        comptime var n: usize = fields.len - 1; // commas
        inline for (fields) |field| n += field.name.len;
        n += ":steady".len; // cursor value
        break :capacity n;
    };

    var buf: [capacity]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Sort the fields so that the output is deterministic. This is
    // done at comptime so it has no runtime cost
    const fields_sorted: [fields.len][]const u8 = comptime fields: {
        var fields_sorted: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| fields_sorted[i] = field.name;
        std.mem.sortUnstable(
            []const u8,
            &fields_sorted,
            {},
            (struct {
                fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
                }
            }).lessThan,
        );
        break :fields fields_sorted;
    };

    inline for (fields_sorted) |name| {
        if (@field(features, name)) {
            if (writer.end > 0) try writer.writeByte(',');
            try writer.writeAll(name);

            if (std.mem.eql(u8, name, "cursor")) {
                try writer.writeAll(if (cursor_blink) ":blink" else ":steady");
            }
        }
    }

    if (writer.end > 0) {
        try env.put("GHOSTTY_SHELL_FEATURES", buf[0..writer.end]);
    }
}

test "setup features" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test: all features enabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = true, .sudo = true, .title = true, .@"ssh-env" = true, .@"ssh-terminfo" = true, .path = true }, true);
        try testing.expectEqualStrings("cursor:blink,path,ssh-env,ssh-terminfo,sudo,title", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: all features disabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, std.mem.zeroes(config.ShellIntegrationFeatures), true);
        try testing.expect(env.get("GHOSTTY_SHELL_FEATURES") == null);
    }

    // Test: mixed features
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = false, .sudo = true, .title = false, .@"ssh-env" = true, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("ssh-env,sudo", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: blinking cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, true);
        try testing.expectEqualStrings("cursor:blink", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: steady cursor
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();
        try setupFeatures(&env, .{ .cursor = true, .sudo = false, .title = false, .@"ssh-env" = false, .@"ssh-terminfo" = false, .path = false }, false);
        try testing.expectEqualStrings("cursor:steady", env.get("GHOSTTY_SHELL_FEATURES").?);
    }
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    var stack_fallback = std.heap.stackFallback(4096, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.get());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;
    try cmd.appendArg("--posix");

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var buf: [32]u8 = undefined;
    var inject: std.Io.Writer = .fixed(&buf);
    try inject.writeAll("1");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration script.
    //
    // Unsupported options:
    //  -c          -c is always non-interactive
    //  --posix     POSIX mode (a la /bin/sh)
    var rcfile: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.writeAll(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.writeAll(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            rcfile = iter.next();
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // '-c command' is always non-interactive
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Preserve an existing ENV value. We're about to overwrite it.
    if (env.get("ENV")) |v| {
        try env.put("GHOSTTY_BASH_ENV", v);
    }

    // Set our new ENV to point to our integration script.
    var script_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const script_path = try std.fmt.bufPrint(
        &script_path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    if (std.fs.openFileAbsolute(script_path, .{})) |file| {
        file.close();
        try env.put("ENV", script_path);
    } else |err| {
        log.warn("unable to open {s}: {}", .{ script_path, err });
        env.remove("GHOSTTY_BASH_ENV");
        return null;
    }

    try env.put("GHOSTTY_BASH_INJECT", buf[0..inject.end]);
    if (rcfile) |v| {
        try env.put("GHOSTTY_BASH_RCFILE", v);
    }

    // In POSIX mode, HISTFILE defaults to ~/.sh_history, so unless we're
    // staying in POSIX mode (--posix), change it back to ~/.bash_history.
    if (env.get("HISTFILE") == null) {
        var home_buf: [1024]u8 = undefined;
        if (try homedir.home(&home_buf)) |home| {
            var histfile_buf: [std.fs.max_path_bytes]u8 = undefined;
            const histfile = try std.fmt.bufPrint(
                &histfile_buf,
                "{s}/.bash_history",
                .{home},
            );
            try env.put("HISTFILE", histfile);
            try env.put("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeZ(u8, try cmd.toOwnedSlice()) };
}

test "bash" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("bash --posix", command.?.shell);
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .bash);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "bash --posix",
        "bash --rcfile script.sh --posix",
        "bash --init-file script.sh --posix",
        "bash -c script.sh",
        "bash -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupBash(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expectEqual(0, env.count());
    }
}

test "bash: inject flags" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .bash);
    defer res.deinit();

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --norc" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --noprofile" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, .{ .shell = "bash --rcfile profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, .{ .shell = "bash --init-file profile.sh" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix", command.?.shell);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: HISTFILE" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .bash);
    defer res.deinit();

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: ENV" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("ENV", "env.sh");

    _ = try setupBash(alloc, .{ .shell = "bash" }, res.path, &env);
    try testing.expectEqualStrings("env.sh", env.get("GHOSTTY_BASH_ENV").?);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/ghostty.bash", .{res.shell_path}),
        env.get("ENV").?,
    );
}

test "bash: additional arguments" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .bash);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // "-" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash - --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix - --arg file1 file2", command.?.shell);
    }

    // "--" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash -- --arg file1 file2" }, res.path, &env);
        try testing.expectEqualStrings("bash --posix -- --arg file1 file2", command.?.shell);
    }
}

test "bash: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupBash(alloc, .{ .shell = "bash" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Setup automatic shell integration for shells that include
/// their modules from paths in `XDG_DATA_DIRS` env variable.
///
/// The shell-integration path is prepended to `XDG_DATA_DIRS`.
/// It is also saved in the `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` variable
/// so that the shell can refer to it and safely remove this directory
/// from `XDG_DATA_DIRS` when integration is complete.
fn setupXdgDataDirs(
    alloc: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Get our path to the shell integration directory.
    const integ_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );
    var integ_dir = std.fs.openDirAbsolute(integ_path, .{}) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return false;
    };
    integ_dir.close();

    // Set an env var so we can remove this from XDG_DATA_DIRS later.
    // This happens in the shell integration config itself. We do this
    // so that our modifications don't interfere with other commands.
    try env.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", integ_path);

    // We attempt to avoid allocating by using the stack up to 4K.
    // Max stack size is considerably larger on mac
    // 4K is a reasonable size for this for most cases. However, env
    // vars can be significantly larger so if we have to we fall
    // back to a heap allocated value.
    var stack_alloc_state = std.heap.stackFallback(4096, alloc);
    const stack_alloc = stack_alloc_state.get();

    // If no XDG_DATA_DIRS set use the default value as specified.
    // This ensures that the default directories aren't lost by setting
    // our desired integration dir directly. See #2711.
    // <https://specifications.freedesktop.org/basedir-spec/0.6/#variables>
    const xdg_data_dirs_key = "XDG_DATA_DIRS";
    try env.put(
        xdg_data_dirs_key,
        try internal_os.prependEnv(
            stack_alloc,
            env.get(xdg_data_dirs_key) orelse "/usr/local/share:/usr/share",
            integ_path,
        ),
    );

    return true;
}

test "xdg: empty XDG_DATA_DIRS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration:/usr/local/share:/usr/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: existing XDG_DATA_DIRS" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .fish);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("XDG_DATA_DIRS", "/opt/share");

    try testing.expect(try setupXdgDataDirs(alloc, res.path, &env));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration:/opt/share", .{res.path}),
        env.get("XDG_DATA_DIRS").?,
    );
}

test "xdg: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(!try setupXdgDataDirs(alloc, resources_dir, &env));
    try testing.expectEqual(0, env.count());
}

/// Set up automatic Nushell shell integration. This works by adding our
/// shell resource directory to the `XDG_DATA_DIRS` environment variable,
/// which Nushell will use to load `nushell/vendor/autoload/ghostty.nu`.
///
/// We then add `--execute 'use ghostty ...'` to the nu command line to
/// automatically enable our shelll features.
fn setupNushell(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Add our XDG_DATA_DIRS entry (for nushell/vendor/autoload/). This
    // makes our 'ghostty' module automatically available, even if any
    // of the later checks abort the rest of our automatic integration.
    if (!try setupXdgDataDirs(alloc, resource_dir, env)) return null;

    var stack_fallback = std.heap.stackFallback(4096, alloc);
    var cmd = internal_os.shell.ShellCommandBuilder.init(stack_fallback.get());
    defer cmd.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try cmd.appendArg(exe);
    } else return null;

    // Tell nu to immediately "use" all of the exported functions in our
    // 'ghostty' module.
    //
    // We can consider making this more specific based on the set of
    // enabled shell features (e.g. `use ghostty sudo`). At the moment,
    // shell features are all runtime-guarded in the nushell script.
    try cmd.appendArg("--execute 'use ghostty *'");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration module.
    //
    // Unsupported options:
    //  -c / --command      -c is always non-interactive
    //  --lsp               --lsp starts the language server
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--command") or std.mem.eql(u8, arg, "--lsp")) {
            return null;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try cmd.appendArg(arg);
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try cmd.appendArg(arg);
            while (iter.next()) |remaining_arg| {
                try cmd.appendArg(remaining_arg);
            }
            break;
        } else {
            try cmd.appendArg(arg);
        }
    }

    // Return a copy of our modified command line to use as the shell command.
    return .{ .shell = try alloc.dupeZ(u8, try cmd.toOwnedSlice()) };
}

test "nushell" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .nushell);
    defer res.deinit();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupNushell(alloc, .{ .shell = "nu" }, res.path, &env);
    try testing.expectEqualStrings("nu --execute 'use ghostty *'", command.?.shell);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
        env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?,
    );
    try testing.expectStringStartsWith(
        env.get("XDG_DATA_DIRS").?,
        try std.fmt.bufPrint(&path_buf, "{s}/shell-integration", .{res.path}),
    );
}

test "nushell: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(alloc, .nushell);
    defer res.deinit();

    const cmdlines = [_][:0]const u8{
        "nu --command exit",
        "nu --lsp",
        "nu -c script.sh",
        "nu -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupNushell(alloc, .{ .shell = cmdline }, res.path, &env) == null);
        try testing.expect(env.get("XDG_DATA_DIRS") != null);
        try testing.expect(env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR") != null);
    }
}

test "nushell: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupNushell(alloc, .{ .shell = "nu" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Setup the zsh automatic shell integration. This works by setting
/// ZDOTDIR to our resources dir so that zsh will load our config. This
/// config then loads the true user config.
fn setupZsh(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    // Preserve an existing ZDOTDIR value. We're about to overwrite it.
    if (env.get("ZDOTDIR")) |old| {
        try env.put("GHOSTTY_ZSH_ZDOTDIR", old);
    }

    // Set our new ZDOTDIR to point to our shell resource directory.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const integ_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    var integ_dir = std.fs.openDirAbsolute(integ_path, .{}) catch |err| {
        log.warn("unable to open {s}: {}", .{ integ_path, err });
        return null;
    };
    integ_dir.close();
    try env.put("ZDOTDIR", integ_path);

    return try command.clone(alloc);
}

test "zsh" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(testing.allocator, .zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expect(env.get("GHOSTTY_ZSH_ZDOTDIR") == null);
}

test "zsh: ZDOTDIR" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var res: TmpResourcesDir = try .init(testing.allocator, .zsh);
    defer res.deinit();

    var env = EnvMap.init(testing.allocator);
    defer env.deinit();

    try env.put("ZDOTDIR", "$HOME/.config/zsh");

    const command = try setupZsh(alloc, .{ .shell = "zsh" }, res.path, &env);
    try testing.expectEqualStrings("zsh", command.?.shell);
    try testing.expectEqualStrings(res.shell_path, env.get("ZDOTDIR").?);
    try testing.expectEqualStrings("$HOME/.config/zsh", env.get("GHOSTTY_ZSH_ZDOTDIR").?);
}

test "zsh: missing resources" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const resources_dir = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(resources_dir);

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupZsh(alloc, .{ .shell = "zsh" }, resources_dir, &env) == null);
    try testing.expectEqual(0, env.count());
}

/// Test helper that creates a temporary resources directory with shell integration paths.
const TmpResourcesDir = struct {
    allocator: Allocator,
    tmp_dir: std.testing.TmpDir,
    path: []const u8,
    shell_path: []const u8,

    fn init(allocator: Allocator, shell: Shell) !TmpResourcesDir {
        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const relative_shell_path = try std.fmt.bufPrint(
            &path_buf,
            "shell-integration/{s}",
            .{@tagName(shell)},
        );
        try tmp_dir.dir.makePath(relative_shell_path);

        const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(path);

        const shell_path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ path, relative_shell_path },
        );
        errdefer allocator.free(shell_path);

        switch (shell) {
            .bash => try tmp_dir.dir.writeFile(.{
                .sub_path = "shell-integration/bash/ghostty.bash",
                .data = "",
            }),
            .powershell => try tmp_dir.dir.writeFile(.{
                .sub_path = "shell-integration/powershell/integration.ps1",
                .data = "",
            }),
            .cmd => try tmp_dir.dir.writeFile(.{
                .sub_path = "shell-integration/cmd/clink.lua",
                .data = "",
            }),
            else => {},
        }

        return .{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .path = path,
            .shell_path = shell_path,
        };
    }

    fn deinit(self: *TmpResourcesDir) void {
        self.allocator.free(self.shell_path);
        self.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};
