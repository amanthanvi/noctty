//! PowerShell shell-integration installer for noctty.
//!
//! Lifecycle (called from `App.init`):
//!   1. `resolveInstallPath` -> `%LOCALAPPDATA%\noctty\shell-integration\
//!      powershell\integration.ps1`, creating intermediate dirs as needed.
//!   2. `installIfStale` compares the on-disk SHA-256 against the comptime
//!      `integration_script_sha256`. Writes atomically (temp + rename) only
//!      when the hash differs or the file is missing.
//!   3. `buildInjectedArgv` wraps interactive PowerShell launches with
//!      `-NoExit -Command "& { $__ghostty_utf8_console = $true|$false; . '<path>' }"`
//!      while preserving existing prefix flags and skipping explicit command /
//!      script entry points. The sentinel is always bound, both ways, so it
//!      shadows any same-named variable a profile may have defined.
//!
//! Testing: `@embedFile("../...")` needs the `src/` package root.
//!   echo 'test { _ = @import("apprt/win32_powershell_install.zig"); }' > src/_t.zig
//!   zig test src/_t.zig && rm src/_t.zig

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.win32_powershell_install);

// ── Embedded script + comptime hash ─────────────────────────────────

/// The bytes of `src/shell-integration/powershell/integration.ps1`
/// embedded at compile time via `@embedFile`.
pub const integration_script = @embedFile("../shell-integration/powershell/integration.ps1");

/// SHA-256 of `integration_script`, computed at comptime. Serves as
/// the version identifier so the installed file rewrites automatically
/// when the script changes between builds.
pub const integration_script_sha256: [32]u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var buf: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(integration_script, &buf, .{});
    break :blk buf;
};

// ── Path resolution ─────────────────────────────────────────────────

/// Resolve the install path under `%LOCALAPPDATA%`. Creates
/// intermediate directories if missing. Returned path owned by `alloc`.
pub fn resolveInstallPath(alloc: Allocator) ![]u8 {
    const local_app_data = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.EnvironmentVariableNotFound,
        else => return err,
    };
    defer alloc.free(local_app_data);

    const sub = "noctty" ++ std.fs.path.sep_str ++
        "shell-integration" ++ std.fs.path.sep_str ++ "powershell";

    const dir_path = try std.fs.path.join(alloc, &.{ local_app_data, sub });
    defer alloc.free(dir_path);

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            var dir = try std.fs.openDirAbsolute(local_app_data, .{});
            defer dir.close();
            try dir.makePath(sub);
        },
    };

    return std.fs.path.join(alloc, &.{ dir_path, "integration.ps1" });
}

// ── Install gate ────────────────────────────────────────────────────

pub const InstallResult = enum {
    skipped, // destination matched embedded SHA-256
    installed, // wrote new file (first run OR hash changed)
    failed, // couldn't write; caller logs and continues
};

/// Install `integration.ps1` at `path` unless its SHA-256 already
/// matches the embedded blob. Atomic via temp-file + rename.
pub fn installIfStale(alloc: Allocator, path: []const u8) InstallResult {
    if (readAndHash(alloc, path)) |on_disk_hash| {
        if (std.mem.eql(u8, &on_disk_hash, &integration_script_sha256)) return .skipped;
    }
    return writeAtomically(path) catch |err| {
        log.warn("powershell integration install failed path={s} err={}", .{ path, err });
        return .failed;
    };
}

fn readAndHash(alloc: Allocator, path: []const u8) ?[32]u8 {
    const contents = blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => {
                log.debug("powershell integration hash read skipped path={s} err={}", .{ path, err });
                return null;
            },
        };
        defer file.close();
        break :blk file.readToEndAlloc(alloc, 1024 * 1024) catch |err| {
            log.debug("powershell integration hash read failed path={s} err={}", .{ path, err });
            return null;
        };
    };
    defer alloc.free(contents);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &hash, .{});
    return hash;
}

/// Atomic write: temp file + rename. Falls back to direct overwrite
/// if rename fails (Windows `std.fs.Dir.rename` uses
/// `NtSetInformationFile` / `FileRenameInformation` with replace
/// semantics -- no `MoveFileExW` needed).
fn writeAtomically(path: []const u8) !InstallResult {
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    var dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer dir.close();
    const basename = std.fs.path.basename(path);

    if (atomicWriteViaTemp(dir, basename)) return .installed;

    // Fallback: direct overwrite.
    const file = try dir.createFile(basename, .{ .truncate = true });
    defer file.close();
    try file.writeAll(integration_script);
    return .installed;
}

fn atomicWriteViaTemp(dir: std.fs.Dir, basename: []const u8) bool {
    const tmp = ".integration.ps1.tmp";
    const f = dir.createFile(tmp, .{ .truncate = true }) catch |err| {
        log.debug("powershell integration temp create failed name={s} err={}", .{ tmp, err });
        return false;
    };
    f.writeAll(integration_script) catch |err| {
        log.debug("powershell integration temp write failed name={s} err={}", .{ tmp, err });
        f.close();
        dir.deleteFile(tmp) catch {};
        return false;
    };
    f.close();
    dir.rename(tmp, basename) catch |err| {
        log.debug("powershell integration temp rename failed name={s} target={s} err={}", .{ tmp, basename, err });
        dir.deleteFile(tmp) catch {};
        return false;
    };
    return true;
}

// ── Argv injection builder ──────────────────────────────────────────

pub const InjectError = error{ OutOfMemory, EmptyCommand };

/// Build an argv that sources integration.ps1 before the user's
/// interactive PowerShell session. Returns `null` for non-interactive or
/// explicit command launch modes (`-Command`, `-File`, etc.) because
/// appending our own `-Command` would change exit behavior or drop user
/// payload.
///
/// `utf8_console` asks `integration.ps1` to switch the console encodings to
/// UTF-8. It travels inside the `-Command` payload as a PowerShell variable
/// rather than as a child environment variable: profiles run before our
/// `-Command` does, so an environment variable would already have been
/// inherited by anything a profile spawned.
pub fn buildInjectedArgv(
    alloc: Allocator,
    pwsh_argv: []const []const u8,
    integration_path: []const u8,
    utf8_console: bool,
) InjectError!?[]const [:0]const u8 {
    if (pwsh_argv.len == 0) return InjectError.EmptyCommand;

    const mode = analyzeInteractiveMode(pwsh_argv) orelse return null;

    const escaped = escapeForPwshSingleQuote(alloc, integration_path) catch
        return InjectError.OutOfMemory;
    defer alloc.free(escaped);

    const cmd_val = buildCommandValue(alloc, escaped, utf8_console) catch
        return InjectError.OutOfMemory;
    defer alloc.free(cmd_val);

    var result: std.ArrayList([:0]const u8) = .empty;
    errdefer {
        for (result.items) |arg| alloc.free(arg);
        result.deinit(alloc);
    }

    for (pwsh_argv) |arg| {
        try result.append(alloc, try alloc.dupeZ(u8, arg));
    }

    if (!mode.has_no_exit) {
        try result.append(alloc, try alloc.dupeZ(u8, "-NoExit"));
    }
    try result.append(alloc, try alloc.dupeZ(u8, "-Command"));
    try result.append(alloc, try alloc.dupeZ(u8, cmd_val));
    return try result.toOwnedSlice(alloc);
}

const InteractiveMode = struct {
    has_no_exit: bool,
};

fn analyzeInteractiveMode(argv: []const []const u8) ?InteractiveMode {
    var has_no_exit = false;
    var expects_value = false;

    for (argv[1..]) |arg| {
        if (expects_value) {
            expects_value = false;
            continue;
        }

        if (hasAttachedFlagValue(arg) and
            (isNoExitFlag(arg) or isSafeInteractiveFlag(arg) or isHelpFlag(arg) or isVersionFlag(arg)))
        {
            return null;
        }

        if (isNoExitFlag(arg)) {
            has_no_exit = true;
            continue;
        }

        if (isValueTakingInteractiveFlag(arg)) {
            if (hasAttachedFlagValue(arg)) return null;
            expects_value = true;
            continue;
        }

        if (isCommandFlag(arg) or
            isCommandWithArgsFlag(arg) or
            isEncodedCommandFlag(arg) or
            isEncodedArgumentsFlag(arg) or
            isFileFlag(arg) or
            isNonInteractiveFlag(arg) or
            isHelpFlag(arg) or
            isVersionFlag(arg))
        {
            return null;
        }

        if (isSafeInteractiveFlag(arg)) continue;

        // Any positional payload or unrecognized token is treated as
        // unsupported so we don't corrupt script / command semantics.
        return null;
    }

    if (expects_value) return null;
    return .{ .has_no_exit = has_no_exit };
}

const FlagToken = struct {
    name: []const u8,
    has_attached_value: bool,
};

fn isFlagPrefixChar(c: u8) bool {
    return c == '-' or c == '/';
}

fn parseFlagToken(arg: []const u8) ?FlagToken {
    if (arg.len < 2 or !isFlagPrefixChar(arg[0])) return null;

    const flag = arg[1..];
    const attached_idx = std.mem.indexOfScalar(u8, flag, ':');
    if ((attached_idx orelse flag.len) == 0) return null;
    return .{
        .name = flag[0 .. attached_idx orelse flag.len],
        .has_attached_value = attached_idx != null,
    };
}

fn hasAttachedFlagValue(arg: []const u8) bool {
    const token = parseFlagToken(arg) orelse return false;
    return token.has_attached_value;
}

const FlagMatchMode = enum { exact, prefix };

fn flagNameMatches(
    name: []const u8,
    full: []const u8,
    aliases: []const []const u8,
    mode: FlagMatchMode,
    min_prefix_len: usize,
) bool {
    switch (mode) {
        .exact => if (std.ascii.eqlIgnoreCase(name, full)) return true,
        .prefix => if (name.len >= min_prefix_len and name.len <= full.len) {
            if (std.ascii.eqlIgnoreCase(name, full[0..name.len])) return true;
        },
    }

    for (aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(name, alias)) return true;
    }

    return false;
}

fn flagMatches(
    arg: []const u8,
    full: []const u8,
    aliases: []const []const u8,
    mode: FlagMatchMode,
    min_prefix_len: usize,
) bool {
    const token = parseFlagToken(arg) orelse return false;
    return flagNameMatches(token.name, full, aliases, mode, min_prefix_len);
}

fn isExactFlag(arg: []const u8, full: []const u8, aliases: []const []const u8) bool {
    return flagMatches(arg, full, aliases, .exact, 0);
}

fn isPrefixedFlag(arg: []const u8, full: []const u8, alias: ?[]const u8) bool {
    return if (alias) |value|
        flagMatches(arg, full, &.{value}, .prefix, 0)
    else
        flagMatches(arg, full, &.{}, .prefix, 0);
}

fn isPrefixedFlagMin(arg: []const u8, full: []const u8, min_prefix_len: usize, alias: ?[]const u8) bool {
    return if (alias) |value|
        flagMatches(arg, full, &.{value}, .prefix, min_prefix_len)
    else
        flagMatches(arg, full, &.{}, .prefix, min_prefix_len);
}

fn isCommandFlag(arg: []const u8) bool {
    return isPrefixedFlag(arg, "Command", "c");
}

fn isCommandWithArgsFlag(arg: []const u8) bool {
    return isPrefixedFlag(arg, "CommandWithArgs", "cwa");
}

fn isEncodedCommandFlag(arg: []const u8) bool {
    return isPrefixedFlag(arg, "EncodedCommand", "enc");
}

fn isEncodedArgumentsFlag(arg: []const u8) bool {
    return isPrefixedFlag(arg, "EncodedArguments", null);
}

fn isFileFlag(arg: []const u8) bool {
    return isPrefixedFlag(arg, "File", "f");
}

fn isNoExitFlag(arg: []const u8) bool {
    return isPrefixedFlagMin(arg, "NoExit", 3, "noe");
}

fn isNonInteractiveFlag(arg: []const u8) bool {
    return isPrefixedFlagMin(arg, "NonInteractive", 4, null);
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-?") or
        std.mem.eql(u8, arg, "/?") or
        isPrefixedFlag(arg, "Help", "h");
}

fn isVersionFlag(arg: []const u8) bool {
    return isPrefixedFlag(arg, "Version", "v");
}

fn isSafeInteractiveFlag(arg: []const u8) bool {
    return isExactFlag(arg, "Interactive", &.{"i"}) or
        isExactFlag(arg, "Login", &.{"l"}) or
        isExactFlag(arg, "MTA", &.{}) or
        isExactFlag(arg, "NoLogo", &.{"nol"}) or
        isExactFlag(arg, "NoProfile", &.{"nop"}) or
        isExactFlag(arg, "NoProfileLoadTime", &.{}) or
        isExactFlag(arg, "STA", &.{});
}

fn isValueTakingInteractiveFlag(arg: []const u8) bool {
    return isExactFlag(arg, "ConfigurationFile", &.{}) or
        isExactFlag(arg, "ConfigurationName", &.{"config"}) or
        isExactFlag(arg, "CustomPipeName", &.{}) or
        isExactFlag(arg, "ExecutionPolicy", &.{ "ep", "ex" }) or
        isExactFlag(arg, "InputFormat", &.{ "if", "inp" }) or
        isExactFlag(arg, "OutputFormat", &.{ "of", "o" }) or
        isExactFlag(arg, "PSConsoleFile", &.{}) or
        isExactFlag(arg, "SettingsFile", &.{"settings"}) or
        isExactFlag(arg, "WindowStyle", &.{"w"}) or
        isExactFlag(arg, "WorkingDirectory", &.{ "wd", "wo" });
}

/// The variable `integration.ps1` reads to decide whether to force UTF-8
/// console encodings. It only ever exists in the script block scope that
/// dot-sources the integration script, so it is gone by the time the
/// interactive session starts and no child process can inherit it.
pub const utf8_console_variable = "__ghostty_utf8_console";

fn buildCommandValue(alloc: Allocator, escaped: []const u8, utf8_console: bool) ![]u8 {
    // Always bind the sentinel, including the `false` case. `integration.ps1`
    // reads it with `Get-Variable -Scope Local`, which sees only the scope
    // this script block creates (the dot-sourced script shares it) and never
    // walks up to a profile-defined `$global:__ghostty_utf8_console`. That
    // scope pin is what enforces `utf8-console = never` and the CJK guard
    // against a hostile profile; the explicit `$false` exists so the "no"
    // decision is a deliberate value rather than an absent variable, and so
    // the local binding shadows any same-named outer variable if the lookup
    // is ever loosened again.
    return std.fmt.allocPrint(
        alloc,
        "& {{ ${s} = ${s}; . '{s}' }}",
        .{ utf8_console_variable, if (utf8_console) "true" else "false", escaped },
    );
}

/// Escape a path for a PowerShell single-quoted string (`'` -> `''`).
pub fn escapeForPwshSingleQuote(alloc: Allocator, input: []const u8) ![]u8 {
    var extra: usize = 0;
    for (input) |c| {
        if (c == '\'') extra += 1;
    }
    if (extra == 0) return alloc.dupe(u8, input);

    const out = try alloc.alloc(u8, input.len + extra);
    var j: usize = 0;
    for (input) |c| {
        if (c == '\'') {
            out[j] = '\'';
            j += 1;
        }
        out[j] = c;
        j += 1;
    }
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────

test "integration_script is non-empty" {
    try std.testing.expect(integration_script.len > 0);
}

test "integration_script_sha256 is not all zero" {
    const zero: [32]u8 = .{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &integration_script_sha256, &zero));
}

test "escapeForPwshSingleQuote: empty string" {
    const r = try escapeForPwshSingleQuote(std.testing.allocator, "");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "escapeForPwshSingleQuote: no quotes" {
    const r = try escapeForPwshSingleQuote(std.testing.allocator, "hello");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("hello", r);
}

test "escapeForPwshSingleQuote: mid-string quote" {
    const r = try escapeForPwshSingleQuote(std.testing.allocator, "it's");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("it''s", r);
}

test "escapeForPwshSingleQuote: leading quote" {
    const r = try escapeForPwshSingleQuote(std.testing.allocator, "'start");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("''start", r);
}

test "escapeForPwshSingleQuote: consecutive quotes" {
    const r = try escapeForPwshSingleQuote(std.testing.allocator, "a''b");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a''''b", r);
}

test "buildInjectedArgv: interactive shell injects without changing banner semantics" {
    const argv = [_][]const u8{"pwsh.exe"};
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\Users\\test\\integration.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqualStrings("pwsh.exe", r[0]);
    try std.testing.expectEqualStrings("-NoExit", r[1]);
    try std.testing.expectEqualStrings("-Command", r[2]);
    try std.testing.expectEqualStrings("& { $__ghostty_utf8_console = $false; . 'C:\\Users\\test\\integration.ps1' }", r[3]);
}

test "buildInjectedArgv: utf8 console travels in the command payload" {
    const argv = [_][]const u8{"pwsh.exe"};
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", true)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqual(@as(usize, 4), r.len);
    try std.testing.expectEqualStrings("-Command", r[2]);
    try std.testing.expectEqualStrings(
        "& { $__ghostty_utf8_console = $true; . 'C:\\int.ps1' }",
        r[3],
    );

    // The decision must never become part of the child environment, or a
    // profile that runs before our -Command would leak it to its own children.
    try std.testing.expect(std.mem.indexOf(u8, r[3], "env:") == null);
}

test "buildInjectedArgv: a negative utf8 decision is bound explicitly" {
    // `integration.ps1` reads the sentinel with `Get-Variable -Scope Local`,
    // so a profile's `$global:__ghostty_utf8_console = $true` is never
    // consulted. The "no" decision must still be an explicit `$false` binding
    // in that local scope rather than an absent variable: it keeps the shape
    // uniform for both outcomes and shadows any same-named outer variable.
    const argv = [_][]const u8{"pwsh.exe"};
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqualStrings(
        "& { $__ghostty_utf8_console = $false; . 'C:\\int.ps1' }",
        r[3],
    );
}

test "buildInjectedArgv: preserves existing prefix flags" {
    const argv = [_][]const u8{ "pwsh.exe", "-ExecutionPolicy", "Bypass", "-NoProfile" };
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqual(@as(usize, 7), r.len);
    try std.testing.expectEqualStrings("pwsh.exe", r[0]);
    try std.testing.expectEqualStrings("-ExecutionPolicy", r[1]);
    try std.testing.expectEqualStrings("Bypass", r[2]);
    try std.testing.expectEqualStrings("-NoProfile", r[3]);
    try std.testing.expectEqualStrings("-NoExit", r[4]);
    try std.testing.expectEqualStrings("-Command", r[5]);
    try std.testing.expectEqualStrings("& { $__ghostty_utf8_console = $false; . 'C:\\int.ps1' }", r[6]);
}

test "buildInjectedArgv: preserves slash-prefixed interactive flags" {
    const argv = [_][]const u8{ "pwsh.exe", "/NoProfile" };
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqualStrings("pwsh.exe", r[0]);
    try std.testing.expectEqualStrings("/NoProfile", r[1]);
    try std.testing.expectEqualStrings("-NoExit", r[2]);
    try std.testing.expectEqualStrings("-Command", r[3]);
    try std.testing.expectEqualStrings("& { $__ghostty_utf8_console = $false; . 'C:\\int.ps1' }", r[4]);
}

test "buildInjectedArgv: existing noexit is not duplicated for powershell.exe" {
    const argv = [_][]const u8{ "powershell.exe", "-NoExit", "-NoProfile" };
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqualStrings("powershell.exe", r[0]);
    try std.testing.expectEqualStrings("-NoExit", r[1]);
    try std.testing.expectEqualStrings("-NoProfile", r[2]);
    try std.testing.expectEqualStrings("-Command", r[3]);
    try std.testing.expectEqualStrings("& { $__ghostty_utf8_console = $false; . 'C:\\int.ps1' }", r[4]);
}

test "buildInjectedArgv: existing slash noexit is not duplicated" {
    const argv = [_][]const u8{ "powershell.exe", "/NoExit", "/NoProfile" };
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqualStrings("powershell.exe", r[0]);
    try std.testing.expectEqualStrings("/NoExit", r[1]);
    try std.testing.expectEqualStrings("/NoProfile", r[2]);
    try std.testing.expectEqualStrings("-Command", r[3]);
    try std.testing.expectEqualStrings("& { $__ghostty_utf8_console = $false; . 'C:\\int.ps1' }", r[4]);
}

test "buildInjectedArgv: path with single quote" {
    const argv = [_][]const u8{"pwsh.exe"};
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\don't\\integration.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqualStrings("& { $__ghostty_utf8_console = $false; . 'C:\\don''t\\integration.ps1' }", r[3]);
}

test "buildInjectedArgv: skips explicit command mode" {
    const argv = [_][]const u8{ "pwsh.exe", "-Command", "Get-Date" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips short command alias" {
    const argv = [_][]const u8{ "pwsh.exe", "-c", "Get-Date" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips long command prefix" {
    const argv = [_][]const u8{ "pwsh.exe", "-Com", "Get-Date" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips attached command form" {
    const argv = [_][]const u8{ "pwsh.exe", "-Command:Get-Date" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips attached file form" {
    const argv = [_][]const u8{ "pwsh.exe", "-File:.\\script.ps1" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips attached encoded command form" {
    const argv = [_][]const u8{ "pwsh.exe", "-EncodedCommand:QQA=" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips slash version form" {
    const argv = [_][]const u8{ "pwsh.exe", "/Version" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips slash noninteractive form" {
    const argv = [_][]const u8{ "pwsh.exe", "/NonInteractive" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: existing noexit prefix is not duplicated" {
    const argv = [_][]const u8{ "pwsh.exe", "-NoEx", "-NoProfile" };
    const r = (try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)).?;
    defer {
        for (r) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(r);
    }
    try std.testing.expectEqual(@as(usize, 5), r.len);
    try std.testing.expectEqualStrings("pwsh.exe", r[0]);
    try std.testing.expectEqualStrings("-NoEx", r[1]);
    try std.testing.expectEqualStrings("-NoProfile", r[2]);
    try std.testing.expectEqualStrings("-Command", r[3]);
    try std.testing.expectEqualStrings("& { $__ghostty_utf8_console = $false; . 'C:\\int.ps1' }", r[4]);
}

test "buildInjectedArgv: skips ambiguous no prefix" {
    const argv = [_][]const u8{ "pwsh.exe", "-No" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips empty flag names" {
    const argv = [_][]const u8{ "pwsh.exe", "-:Get-Date" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips empty slash flag names" {
    const argv = [_][]const u8{ "pwsh.exe", "/:Get-Date" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips positional script path after prefix flags" {
    const argv = [_][]const u8{ "pwsh.exe", "-NoProfile", ".\\script.ps1" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips encoded arguments mode" {
    const argv = [_][]const u8{ "powershell.exe", "-EncodedArguments", "QQA=" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips help mode" {
    const argv = [_][]const u8{ "pwsh.exe", "-?" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: skips version mode" {
    const argv = [_][]const u8{ "powershell.exe", "-Version", "5.1" };
    try std.testing.expect((try buildInjectedArgv(std.testing.allocator, &argv, "C:\\int.ps1", false)) == null);
}

test "buildInjectedArgv: empty argv" {
    const argv = [_][]const u8{};
    try std.testing.expectError(InjectError.EmptyCommand, buildInjectedArgv(std.testing.allocator, &argv, "p", false));
}

test "installIfStale: first install writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const fp = try std.fs.path.join(std.testing.allocator, &.{ dp, "integration.ps1" });
    defer std.testing.allocator.free(fp);
    try std.testing.expectEqual(InstallResult.installed, installIfStale(std.testing.allocator, fp));
}

test "installIfStale: same content skips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const fp = try std.fs.path.join(std.testing.allocator, &.{ dp, "integration.ps1" });
    defer std.testing.allocator.free(fp);
    _ = installIfStale(std.testing.allocator, fp);
    try std.testing.expectEqual(InstallResult.skipped, installIfStale(std.testing.allocator, fp));
}

test "installIfStale: different content on disk triggers reinstall" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const fp = try std.fs.path.join(std.testing.allocator, &.{ dp, "integration.ps1" });
    defer std.testing.allocator.free(fp);

    const f = try tmp.dir.createFile("integration.ps1", .{ .truncate = true });
    try f.writeAll("# stale");
    f.close();

    try std.testing.expectEqual(InstallResult.installed, installIfStale(std.testing.allocator, fp));

    const verify = try tmp.dir.openFile("integration.ps1", .{});
    defer verify.close();
    const contents = try verify.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings(integration_script, contents);
}
