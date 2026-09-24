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
//! Why the payload is a `& { ... }` script block:
//!
//!   The block's child scope is the only way to make the per-launch
//!   `$__ghostty_utf8_console` decision stick on a session whose profile
//!   already defined a variable of that name. A child scope SHADOWS an outer
//!   variable even when that outer variable is `ReadOnly` or `Constant`; a
//!   plain global assignment does not — it raises a non-terminating
//!   `Cannot overwrite variable ... because it is read-only or constant`,
//!   the dot-source proceeds anyway, and the profile's value wins. Measured
//!   on pwsh 7 and Windows PowerShell 5.1: with a `ReadOnly` profile
//!   sentinel of `$true` and noctty asking for `$false`, the block form
//!   leaves the console at codepage 437 (correct) while the global form
//!   ends at 65001 with a visible error. The block is therefore load-bearing
//!   for the `utf8-console = never` guarantee.
//!
//!   It is NOT about child-process inheritance — PowerShell variables are
//!   never inherited by child processes in the first place. (An earlier
//!   version of this comment claimed that; it was wrong.)
//!
//!   The cost of the block, and the contract it imposes: the child scope is
//!   torn down as soon as the dot-source returns, so every top-level name in
//!   `integration.ps1` that must outlive load has to carry an explicit
//!   `global:` / `$Global:` qualifier. When it did not, `prompt` survived
//!   (it was `function global:prompt`) but every helper it calls did not,
//!   so each prompt draw threw `CommandNotFoundException`, PowerShell fell
//!   back to its built-in `PS C:\...>` prompt over the user's starship /
//!   oh-my-posh prompt, and no OSC 133 or OSC 7 was ever emitted (#231).
//!   `integration.ps1 honours the injected block scope` below pins that
//!   contract at compile time; note that a test which dot-sources the script
//!   at its own scope cannot catch a violation.
//!
//! Testing: `@embedFile("../...")` needs the `src/` package root.
//!   echo 'test { _ = @import("apprt/win32_powershell_install.zig"); }' > src/_t.zig
//!   zig test src/_t.zig && rm src/_t.zig

const std = @import("std");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
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
    // The quota scales with the script's length: Sha256 runs one comptime
    // compression round per 64 bytes and each round is thousands of
    // backwards branches, measured at roughly 50 per input byte. A FIXED
    // quota silently becomes a build error the moment the script grows past
    // it -- 1_000_000 was exhausted at ~26 KiB, and the failure mode is a
    // confusing `evaluation exceeded 1000000 backwards branches` pointing
    // into std/crypto/sha2.zig from a build that only grew a comment in the
    // .ps1. Derive it from the input, with a generous floor.
    @setEvalBranchQuota(@max(10_000_000, integration_script.len * 256));
    var buf: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(integration_script, &buf, .{});
    break :blk buf;
};

// ── Path resolution ─────────────────────────────────────────────────

/// Resolve the install path under the portable root or `%LOCALAPPDATA%`.
/// Creates intermediate directories if missing. Returned path owned by `alloc`.
pub fn resolveInstallPath(alloc: Allocator) ![]u8 {
    const portable_root = try internal_os.xdg.portableRoot(alloc);
    const base = portable_root orelse
        (std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => known: {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const path = try internal_os.windows.knownFolderPathUtf8(
                    &internal_os.windows.FOLDERID_LocalAppData,
                    &buf,
                );
                break :known try alloc.dupe(u8, path orelse return error.EnvironmentVariableNotFound);
            },
            else => return err,
        });
    defer alloc.free(base);
    const path = try std.fs.path.join(alloc, &.{
        base,
        if (portable_root != null) "" else build_config.data_dir_name,
        "shell-integration",
        "powershell",
        "integration.ps1",
    });
    errdefer alloc.free(path);
    const dir_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir_path);
    return path;
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
///
/// The payload is a `& { ... }` block so that binding lands in a child scope
/// and shadows a profile-defined sentinel even when the profile marked it
/// `ReadOnly` / `Constant`. See the module doc comment for the measurement
/// and for the `global:` contract the block imposes on `integration.ps1`.
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
/// interactive session starts.
pub const utf8_console_variable = "__ghostty_utf8_console";

fn buildCommandValue(alloc: Allocator, escaped: []const u8, utf8_console: bool) ![]u8 {
    // Always bind the sentinel, including the `false` case. `integration.ps1`
    // reads it with `Get-Variable -Scope Local`, which sees only the scope
    // this script block creates (the dot-sourced script shares it) and never
    // walks up to a profile-defined `$global:__ghostty_utf8_console`. That
    // scope pin is what enforces `utf8-console = never` and the CJK guard
    // against a hostile profile; the explicit `$false` exists so the "no"
    // decision is a deliberate value rather than an absent variable, and so
    // the child-scope binding shadows any same-named outer variable if the
    // lookup is ever loosened again.
    //
    // Keep this a `& { ... }` block. A child scope shadows a `ReadOnly` /
    // `Constant` profile global; a plain global assignment cannot overwrite
    // one and silently leaves the profile's value in force. The tradeoff is
    // that `integration.ps1` must `global:`-qualify everything that outlives
    // the dot-source — see the module doc comment and the contract test.
    //
    // A profile can still defeat this by declaring the sentinel with
    // `-Option AllScope,ReadOnly`, which makes the name unbindable in child
    // scopes too. Hardening against that would mean prefixing a
    // `Microsoft.PowerShell.Utility\Remove-Variable __ghostty_utf8_console
    // -Scope Global -Force` inside the braces; deliberately not done here to
    // keep the pinned payload string stable.
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

/// Strip a leading PowerShell type cast from a statement, so
/// `[string[]]$x = 'v'` reduces to `$x = 'v'`. Brackets nest, which is why
/// this counts rather than searching for the first `]`. Returns the input
/// unchanged when it does not start with a balanced cast.
fn stripLeadingTypeCast(statement: []const u8) []const u8 {
    var rest = statement;
    while (rest.len > 0 and rest[0] == '[') {
        var bracket: usize = 0;
        const end = for (rest, 0..) |c, idx| {
            switch (c) {
                '[' => bracket += 1,
                ']' => {
                    bracket -= 1;
                    if (bracket == 0) break idx;
                },
                else => {},
            }
        } else return statement;
        rest = std.mem.trimLeft(u8, rest[end + 1 ..], " \t");
    }
    return rest;
}

/// PowerShell braces come in two flavours and only one of them matters for
/// scoping. `function`, `filter`, `& { }`, `. { }`, a scriptblock passed as
/// an argument and a `@{ }` hashtable all open something the runtime treats
/// as its own scope (or, for the hashtable, as a region whose keys are not
/// statements at all). `if` / `elseif` / `else` / `try` / `catch` /
/// `finally` / `foreach` / `for` / `while` / `switch` / `do` do NOT: a
/// variable assigned inside a top-level `if` block lives in the enclosing
/// script scope and dies with the injected `& { }` just like one written at
/// column 0.
const BraceKind = enum { scope, transparent };

/// Keywords whose block does not introduce a PowerShell scope.
fn isTransparentKeyword(word: []const u8) bool {
    // A `}` or `;` can be glued to the keyword (`} else {`, `};try {`).
    const bare = std.mem.trimLeft(u8, word, "};");
    for ([_][]const u8{
        "if",      "elseif", "else",  "try",    "catch", "finally",
        "foreach", "for",    "while", "switch", "do",
    }) |kw| {
        if (std.ascii.eqlIgnoreCase(bare, kw)) return true;
    }
    return false;
}

fn lastWord(text: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, text, " \t");
    var start = trimmed.len;
    while (start > 0 and trimmed[start - 1] != ' ' and trimmed[start - 1] != '\t') {
        start -= 1;
    }
    return trimmed[start..];
}

/// Tracks PowerShell brace nesting across lines, separating scope-creating
/// braces from control-flow braces that are transparent to scoping.
///
/// Braces inside a `#` comment and inside single- or double-quoted strings do
/// not count. String skipping is load-bearing for this script: every OSC
/// payload interpolates `${Global:__ghostty_esc}` and friends, and those
/// braces would otherwise desync the counter. Handles the backtick escape
/// inside double quotes.
///
/// Quote and paren state deliberately reset per line — `integration.ps1`
/// contains no here-strings. The end-of-script depth assertions in the test
/// below are the tripwire if that ever stops holding.
const BraceTracker = struct {
    stack: [64]BraceKind = undefined,
    depth: usize = 0,
    /// How many enclosing braces actually create a scope. An assignment is
    /// top-level when this is zero, however deeply nested it is in `if` /
    /// `try` blocks.
    scoping_depth: usize = 0,
    overflowed: bool = false,

    fn push(self: *BraceTracker, kind: BraceKind) void {
        if (self.depth >= self.stack.len) {
            self.overflowed = true;
            return;
        }
        self.stack[self.depth] = kind;
        self.depth += 1;
        if (kind == .scope) self.scoping_depth += 1;
    }

    fn pop(self: *BraceTracker) void {
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.stack[self.depth] == .scope) self.scoping_depth -= 1;
    }

    fn advance(self: *BraceTracker, line: []const u8) void {
        var in_single = false;
        var in_double = false;
        // Position of the `(` matching the most recently closed `)`, so a
        // `... ) {` brace can be classified by the keyword in front of the
        // condition. Recorded during the forward walk so parens inside
        // strings (`-match '^user\s+(.+)$'`) cannot desync it.
        var paren_opens: [32]usize = undefined;
        var paren_depth: usize = 0;
        var last_paren_open: ?usize = null;
        // A `)` with no matching `(` on this line means the condition began
        // on an earlier line, which in practice is always control flow.
        var continued_condition = false;

        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const c = line[i];
            if (in_single) {
                if (c == '\'') in_single = false;
                continue;
            }
            if (in_double) {
                if (c == '`') {
                    i += 1;
                    continue;
                }
                if (c == '"') in_double = false;
                continue;
            }
            switch (c) {
                // The rest of the line is a comment.
                '#' => return,
                '\'' => in_single = true,
                '"' => in_double = true,
                '(' => {
                    if (paren_depth < paren_opens.len) paren_opens[paren_depth] = i;
                    paren_depth += 1;
                },
                ')' => {
                    if (paren_depth == 0) {
                        continued_condition = true;
                    } else {
                        paren_depth -= 1;
                        if (paren_depth < paren_opens.len) {
                            last_paren_open = paren_opens[paren_depth];
                        }
                    }
                },
                '{' => self.push(classifyBrace(
                    line[0..i],
                    last_paren_open,
                    continued_condition,
                )),
                '}' => self.pop(),
                else => {},
            }
        }
    }

    fn classifyBrace(
        prefix_raw: []const u8,
        last_paren_open: ?usize,
        continued_condition: bool,
    ) BraceKind {
        const prefix = std.mem.trimRight(u8, prefix_raw, " \t");
        // A brace alone on its line. `integration.ps1` is K&R throughout, so
        // this does not occur today; call it transparent because a loud
        // false positive on an Allman-style function body beats silently
        // missing an unqualified assignment in an Allman-style `if`.
        if (prefix.len == 0) return .transparent;

        switch (prefix[prefix.len - 1]) {
            // `@{` hashtable (keys are not statements), `= {` scriptblock
            // literal, `& {` / `. {` invocation, and `{` in argument
            // position — all scope-creating, or close enough that we must
            // not scan their contents as top-level statements.
            '@', '=', '&', '.', '(', ',', '|' => return .scope,
            ')' => {
                if (continued_condition) return .transparent;
                const open = last_paren_open orelse return .transparent;
                if (open > prefix.len) return .transparent;
                const head = prefix[0..open];
                if (std.mem.trim(u8, head, " \t").len == 0) return .transparent;
                return if (isTransparentKeyword(lastWord(head)))
                    .transparent
                else
                    .scope;
            },
            else => {},
        }

        // Bare keyword forms: `else {`, `try {`, `catch {`, `do {`.
        return if (isTransparentKeyword(lastWord(prefix))) .transparent else .scope;
    }
};

test "integration.ps1 honours the injected block scope" {
    // `buildCommandValue` dot-sources the script from inside `& { ... }`, so
    // the script's top-level scope is a child scope that is destroyed the
    // moment the dot-source returns. Anything the interactive session needs
    // afterwards must be declared `global:`.
    //
    // This cannot be caught from `test/windows/powershell-shell-integration.ps1`
    // alone: that harness dot-sources the script at its own scope, where
    // unqualified definitions survive. Regression guard for #231, where the
    // helpers died with the block, `prompt` threw CommandNotFoundException on
    // every draw, and PowerShell replaced the user's prompt with `PS C:\...>`
    // while emitting no OSC 133 / OSC 7 at all.

    // Every function this script declares must be `global:`-qualified, and
    // every top-level variable it defines must be `$Global:`-qualified.
    // Declarations are found by scanning for the keyword at a statement
    // start (line start, or right after `{` / `;`) rather than by matching
    // one spelling, so `function  __ghostty_x`, `Function __ghostty_x`, an
    // indented declaration, and `if (...) { function __ghostty_x { } }` are
    // all caught.
    //
    // Top-level is decided by brace depth, not by column: PowerShell
    // indentation creates no scope, so `    $x = 1` written at depth 0 is
    // just as fatal as one at column 0.
    //
    // Known limits, both currently unused by the script: reflection forms
    // (`$function:x = { }`, `Set-Item Function:x`, `New-Variable`) are not
    // detected; and an unqualified assignment inside a top-level `if` / `try`
    // block sits at depth > 0 and is not flagged even though those blocks do
    // not create a PowerShell scope either. Extend the scan if either starts
    // to matter.
    var lines = std.mem.splitScalar(u8, integration_script, '\n');
    var declarations: usize = 0;
    var top_level_variables: usize = 0;
    var braces: BraceTracker = .{};
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Scoping depth as of the START of this line. Not indentation:
        // PowerShell indentation carries no meaning. Not raw brace depth
        // either: `if` / `try` / `foreach` blocks create no scope, so an
        // unqualified assignment inside a top-level `if` is every bit as
        // fatal as one written at column 0.
        const line_depth = braces.scoping_depth;
        braces.advance(line);

        // Top-level variable assignment, with any leading type cast
        // stripped: `[string]$x = 'v'` and `[string[]]$x = @()` declare a
        // variable just as much as a bare `$x = 'v'` does.
        const statement = stripLeadingTypeCast(trimmed);
        if (line_depth == 0 and statement.len > 0 and statement[0] == '$') {
            const name_end = for (statement[1..], 1..) |c, idx| {
                if (!std.ascii.isAlphanumeric(c) and c != '_' and c != ':') break idx;
            } else statement.len;
            const after = std.mem.trimLeft(u8, statement[name_end..], " \t");
            if (after.len > 0 and after[0] == '=' and
                (after.len == 1 or after[1] != '='))
            {
                const name = statement[1..name_end];
                top_level_variables += 1;
                // The deliberate block-scoped locals: both are consumed
                // during load and must not outlive it. They carry the
                // `ghostty` prefix so this list stays unambiguous — do not
                // add a generically-named variable here.
                const load_time_locals = [_][]const u8{
                    "ghosttyUtf8Console",
                    "ghosttyUtf8Encoding",
                };
                const allowed = for (load_time_locals) |local| {
                    if (std.mem.eql(u8, name, local)) break true;
                } else false;
                if (!std.ascii.startsWithIgnoreCase(name, "Global:") and !allowed) {
                    std.debug.print(
                        "integration.ps1 defines a non-global top-level variable: {s}\n",
                        .{trimmed},
                    );
                    return error.UnqualifiedVariableDeclaration;
                }
            }
        }

        // Function declarations, anywhere a statement can start.
        var idx: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(line, idx, "function")) |at| {
            idx = at + "function".len;
            const before_ok = at == 0 or switch (line[at - 1]) {
                ' ', '\t', '{', ';' => true,
                else => false,
            };
            if (!before_ok) continue;
            // Only whitespace, `{` or `;` may precede it on the line, else
            // this is prose or an argument rather than a declaration.
            const prefix = std.mem.trim(u8, line[0..at], " \t");
            if (prefix.len != 0 and prefix[prefix.len - 1] != '{' and
                prefix[prefix.len - 1] != ';') continue;
            if (idx >= line.len or (line[idx] != ' ' and line[idx] != '\t')) continue;
            const rest = std.mem.trimLeft(u8, line[idx..], " \t");
            declarations += 1;
            if (!std.ascii.startsWithIgnoreCase(rest, "global:")) {
                std.debug.print(
                    "integration.ps1 declares a non-global function: {s}\n",
                    .{trimmed},
                );
                return error.UnqualifiedFunctionDeclaration;
            }
        }
    }
    // Guard the guard: if either scan stops matching, everything above turns
    // vacuous. These are the live counts; bump them when the script grows.
    try std.testing.expectEqual(@as(usize, 23), declarations);
    try std.testing.expectEqual(@as(usize, 11), top_level_variables);
    // Unbalanced braces here mean the tracker desynced (an unterminated
    // string, a here-string, nesting past the stack), which would silently
    // mis-classify every line after it.
    try std.testing.expect(!braces.overflowed);
    try std.testing.expectEqual(@as(usize, 0), braces.depth);
    try std.testing.expectEqual(@as(usize, 0), braces.scoping_depth);

    // The escape / bell characters the prompt interpolates are globals under
    // the `__ghostty_` prefix. Bare `$ESC` / `$BEL` died with the block on
    // the injected path, and clobbered a profile variable of the same name
    // on the manual dot-source path. Matched on a token boundary so an
    // unrelated `$ESCAPED` local does not trip the guard.
    for ([_][]const u8{ "$ESC", "$BEL" }) |banned| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, integration_script, at, banned)) |hit| {
            at = hit + banned.len;
            if (at < integration_script.len) {
                const next = integration_script[at];
                if (std.ascii.isAlphanumeric(next) or next == '_') continue;
            }
            std.debug.print("integration.ps1 still uses {s}\n", .{banned});
            return error.UnprefixedGlobalVariable;
        }
    }
    try std.testing.expect(std.mem.indexOf(
        u8,
        integration_script,
        "$Global:__ghostty_esc",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        integration_script,
        "$Global:__ghostty_bel",
    ) != null);

    // The hook targets and every helper they call must be global. The
    // generated `prompt` function calls `__ghostty_prompt_body` by name, and
    // the global alias `PSConsoleHostReadLine` points at `__ghostty_readline`;
    // the host runs both on every prompt and every line, long after the
    // injected `& { }` is gone, so a target that died with the block would
    // make the host fall back to its built-in prompt and its own line reader.
    for ([_][]const u8{
        "__ghostty_prompt_body",
        "__ghostty_wrap_prompt",
        "__ghostty_prompt_is_ours",
        "__ghostty_same_object",
        "__ghostty_readline",
        "__ghostty_append_input_mark",
        "__ghostty_read_global",
        "__ghostty_error_head",
        "__ghostty_is_native_error",
        "__ghostty_write_osc",
        "__ghostty_encode_osc133_value",
        "__ghostty_encode_cwd_uri",
        "__ghostty_ssh_wrapper_is_ours",
        "__ghostty_install_alias",
        "__ghostty_retire_legacy_hooks",
    }) |name| {
        var buf: [96]u8 = undefined;
        const decl = try std.fmt.bufPrint(&buf, "\nfunction global:{s} {{", .{name});
        try std.testing.expect(std.mem.indexOf(u8, integration_script, decl) != null);
    }
}

/// Does `integration.ps1` contain `needle` in CODE, ignoring whole-line `#`
/// comments? The comments in that script quote the very constructs these tests
/// assert are gone (`-CommandValidationHandler`, the old `Function:\global:ssh`
/// path) in order to explain why they were removed, so a naive substring scan
/// over the whole file could never go green.
///
/// Whole-line comments are enough here, and the test below keeps it that way.
fn codeContains(needle: []const u8) bool {
    var lines = std.mem.splitScalar(u8, integration_script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

test "integration.ps1 keeps trailing comments off code lines" {
    // `codeContains` only skips whole-line comments, so a trailing `#` on a
    // code line would hide that code from it. Quotes are tracked because every
    // OSC payload is a double-quoted string and `#` is legal inside one.
    var lines = std.mem.splitScalar(u8, integration_script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var in_single = false;
        var in_double = false;
        for (line) |c| {
            if (in_single) {
                if (c == '\'') in_single = false;
                continue;
            }
            if (in_double) {
                if (c == '"') in_double = false;
                continue;
            }
            switch (c) {
                '\'' => in_single = true,
                '"' => in_double = true,
                '#' => {
                    std.debug.print(
                        "integration.ps1 has a trailing comment on a code line: {s}\n",
                        .{line},
                    );
                    return error.TrailingCommentOnCodeLine;
                },
                else => {},
            }
        }
    }
}

test "integration.ps1 emits OSC 133 C from the line reader" {
    // C used to hang off PSReadLine's AddToHistoryHandler, which PSReadLine
    // skips for a line equal to the previous history entry (the default
    // HistoryNoDuplicates) and for a whitespace-only line, so running the
    // same command twice got no C the second time. The console host reads
    // every line through the `PSConsoleHostReadLine` command, and our alias
    // of that name wraps whatever function PSReadLine (or a profile) put
    // there, so C now goes out once per accepted line.
    try std.testing.expect(codeContains(
        "__ghostty_install_alias 'PSConsoleHostReadLine' '__ghostty_readline'",
    ));
    try std.testing.expect(codeContains("$line = & $read_line"));
    // noctty must leave the user's AddToHistoryHandler, and PSReadLine's
    // default sensitive-history filter, exactly as it found them. The only
    // place the option is still set is where a session's OLDER copy of this
    // script installed a handler and we put the original back.
    try std.testing.expect(!codeContains("-AddToHistoryHandler {"));
    try std.testing.expect(!codeContains("GetBufferState"));
    try std.testing.expect(codeContains(
        "Set-PSReadLineOption -AddToHistoryHandler (__ghostty_read_global '__ghostty_addtohistory_original')",
    ));
    // CommandValidationHandler, the hook before that, only fires for
    // `ValidateAndAcceptLine`, which Enter is not bound to by default.
    try std.testing.expect(!codeContains("-CommandValidationHandler"));
    // The terminal reads OSC 133 into a 2048-byte buffer and drops a longer
    // mark whole, so an oversized label is left off rather than costing C.
    try std.testing.expect(codeContains("if ($encoded.Length -le 2000) { $cmdline = ';cmdline_url=' + $encoded }"));
    // A blank line runs nothing; a C there would make it the terminal's "last
    // command" and cost `insert_last_command` the real one.
    try std.testing.expect(codeContains(
        "if ($line -is [string] -and -not [string]::IsNullOrWhiteSpace($line)) {",
    ));
    // PSReadLine's own PSConsoleHostReadLine reads $? first and hands it to
    // predictors, so our wrapper must read it first and hand it on.
    try std.testing.expect(std.mem.indexOf(
        u8,
        integration_script,
        "function global:__ghostty_readline {\n    # $? FIRST",
    ) != null);
}

test "integration.ps1 wraps the prompt in a generated function the line reader renews" {
    // `function prompt` becomes one line that captures $? and calls the body
    // with the id of the prompt it wraps. The id lives in the function's own
    // text, so a copy (a venv's Copy-Item, a profile chaining to
    // `$function:prompt` or `(Get-Command prompt).ScriptBlock`) still wraps
    // the same prompt.
    try std.testing.expect(codeContains(
        "$function:global:prompt = '$__ghostty_ok = $?; __ghostty_prompt_body $__ghostty_ok ' + $id",
    ));
    try std.testing.expect(codeContains("__ghostty_wrap_prompt -EvenIfMissing"));
    // Not an alias: `Get-Command prompt` has to stay a Function with a
    // ScriptBlock, and PSReadLine must not see the user's own plain prompt,
    // or it derives a PromptText and repaints it after our B mark.
    try std.testing.expect(!codeContains("__ghostty_install_alias 'prompt'"));
    try std.testing.expect(!codeContains("function global:prompt {"));
    // The line reader renews the wrapper before the line is read, so a
    // prompt replaced by the previous command is drawn unwrapped only once.
    const readline = std.mem.indexOf(u8, integration_script, "function global:__ghostty_readline {").?;
    const rewrap = std.mem.indexOfPos(u8, integration_script, readline, "        __ghostty_wrap_prompt\n").?;
    const read = std.mem.indexOfPos(u8, integration_script, readline, "    $line = & $read_line").?;
    try std.testing.expect(rewrap < read);
    // A copy of an earlier wrapper, called from inside a newer one, passes
    // straight through instead of writing a second D / A pair.
    try std.testing.expect(codeContains("if (__ghostty_read_global '__ghostty_in_prompt') {"));
    // The user's prompt must see the $? their command left, not ours.
    try std.testing.expect(codeContains(
        "Microsoft.PowerShell.Utility\\Write-Error -Message '' -ErrorAction Ignore",
    ));
    // A profile's `$ConfirmPreference = 'Low'` or `$WhatIfPreference` must
    // neither stop the launch at a prompt nor turn the install into a no-op.
    try std.testing.expect(codeContains(
        "Set-Alias -Name $Name -Value $Target -Scope Global -Force -ErrorAction Ignore -Confirm:$false -WhatIf:$false -Verbose:$false",
    ));
}

test "integration.ps1 writes OSC 133 B from the line reader" {
    // The host draws the string `prompt` returns only after it returns, so a
    // B written from the prompt lands ahead of the visible prompt and the
    // terminal records the prompt's cells as input. Appending B to the
    // returned string put it in every transcript. The line reader writes it
    // instead: the host has drawn the prompt by then, whatever it returned,
    // and PSReadLine has not started.
    const readline = std.mem.indexOf(u8, integration_script, "function global:__ghostty_readline {").?;
    const b_write = std.mem.indexOfPos(
        u8,
        integration_script,
        readline,
        "__ghostty_write_osc \"${Global:__ghostty_esc}]133;B${Global:__ghostty_bel}\"",
    ).?;
    const read = std.mem.indexOfPos(u8, integration_script, readline, "    $line = & $read_line").?;
    try std.testing.expect(b_write < read);
    // A prompt our wrapper did not draw (replaced by the last command, or a
    // ReadOnly one) gets OSC 7 and a P mark with redraw=0 in place of its
    // missing A. P, unlike A, does not fresh-line.
    const p_write = std.mem.indexOfPos(
        u8,
        integration_script,
        readline,
        "__ghostty_write_osc \"${Global:__ghostty_esc}]133;P;k=i;redraw=0${Global:__ghostty_bel}\"",
    ).?;
    try std.testing.expect(p_write < b_write);
    try std.testing.expect(codeContains("$Global:__ghostty_prompt_marked = $true"));
    // The prompt appends B itself only where no line read follows a host
    // draw: a PSReadLine repaint, which runs inside the reader, or a session
    // with no PSConsoleHostReadLine function to hook.
    try std.testing.expect(codeContains("if (-not $reader_marks_input) { $out = __ghostty_append_input_mark $out }"));
    try std.testing.expect(codeContains("(-not (__ghostty_read_global '__ghostty_in_readline')) -and"));
    // The reader must not be wrapped in try/finally: a throw from it has to
    // reach the host, which then reads the line itself. Inside a try the
    // function ran on and returned $null, which the host takes for end of
    // input and exits.
    try std.testing.expect(std.mem.indexOf(u8, integration_script, "    $line = & $read_line\n    $Global:__ghostty_in_readline = $false\n") != null);
    // B is spelled in exactly two code lines: the reader's, and the
    // prompt's own for those two cases.
    var b_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, integration_script, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "]133;B") != null) b_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), b_lines);
}

test "integration.ps1 marks its prompt as one the shell will not redraw" {
    // Without `redraw=0` the terminal clears the prompt rows on every resize
    // and waits for the shell to paint them again. PowerShell never re-runs
    // `prompt` after a resize, so every resize left the cursor alone on a
    // blank row where the prompt had been.
    try std.testing.expect(codeContains(
        "]133;A;cl=line;aid=${Global:__ghostty_aid};redraw=0${Global:__ghostty_bel}",
    ));
}

test "integration.ps1 removes only an ssh wrapper it installed" {
    // The unconditional `Remove-Item -Path Function:\ssh,Function:\global:ssh`
    // that used to sit ahead of the feature check deleted a user's own
    // profile-defined `ssh` on every launch, and `Function:\global:ssh` is not
    // a valid provider path, so each launch also pushed two
    // ItemNotFoundException records into `$Error`.
    try std.testing.expect(!codeContains("Function:\\global:ssh"));
    // Removal is gated on our own marker plus a flag that cannot be set on a
    // first load, which is what makes it a re-source-only operation.
    try std.testing.expect(codeContains("if (__ghostty_ssh_wrapper_is_ours) {"));
    try std.testing.expect(codeContains("__ghostty_ssh_wrapper_marker"));
    try std.testing.expect(codeContains("$Global:__ghostty_ssh_wrapper_installed = $true"));
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

// ── What the terminal makes of the script's marks ───────────────────
//
// The tests above pin the script's text; these pin what its byte shapes mean
// to the terminal. Each sequence is trimmed from a recording of pwsh 7.6.6
// through the bundled pseudo console (Windows PowerShell 5.1 produces the
// same mark order): PSReadLine's per-keystroke re-render is cut to its final
// frame and the aid, cwd and command are shortened. An empty step stands for
// the user pressing Enter, which noctty records on the screen as it writes it
// to the pty.

const terminal_for_tests = @import("../terminal/main.zig");

/// The prompt the script draws: D, OSC 7 and `A;redraw=0` written directly
/// while `prompt` runs; the host then draws the string it returns, and the
/// line reader writes B after it.
const pwsh_prompt_marks = "\x1b]133;D;0;aid=1\x07\x1b]7;file://h/C:/\x07\x1b]133;A;cl=line;aid=1;redraw=0\x07";

fn pwshReplay(
    alloc: Allocator,
    cols: u16,
    steps: []const []const u8,
) !terminal_for_tests.Terminal {
    var t = try terminal_for_tests.Terminal.init(alloc, .{ .cols = cols, .rows = 8 });
    errdefer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    for (steps) |step| {
        if (step.len == 0) {
            t.screens.active.semanticPromptInputSubmitted();
        } else {
            stream.nextSlice(step);
        }
    }
    return t;
}

test "PowerShell marks: the prompt text is prompt and the last command is recovered without it" {
    const alloc = std.testing.allocator;
    const command = "\x1b[93mGet-Date\x1b[0m";
    const output = "\r\n\x1b]133;C;aid=1;cmdline_url=Get-Date\x07\r\nWednesday\r\n\r\n";

    // B after the prompt text, as the script now writes it.
    {
        var t = try pwshReplay(alloc, 40, &.{
            pwsh_prompt_marks ++ "PS C:\\> \x1b]133;B\x07" ++ command,
            "",
            output ++ pwsh_prompt_marks ++ "PS C:\\> \x1b]133;B\x07",
        });
        defer t.deinit(alloc);

        const recovered = (try t.screens.active.lastCommandString(alloc)).?;
        defer alloc.free(recovered);
        try std.testing.expectEqualStrings("Get-Date", recovered);

        const pages = &t.screens.active.pages;
        const prompt_cell = pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const input_cell = pages.pin(.{ .active = .{ .x = 8, .y = 0 } }).?;
        try std.testing.expectEqual(.prompt, prompt_cell.rowAndCell().cell.semantic_content);
        try std.testing.expectEqual(.input, input_cell.rowAndCell().cell.semantic_content);
    }

    // Control: B written directly, ahead of the prompt text, as it used to
    // be. The prompt's own cells become input, so `insert_last_command`
    // would type the old prompt back in front of the command.
    {
        var t = try pwshReplay(alloc, 40, &.{
            pwsh_prompt_marks ++ "\x1b]133;B\x07PS C:\\> " ++ command,
            "",
            output ++ pwsh_prompt_marks ++ "\x1b]133;B\x07PS C:\\> ",
        });
        defer t.deinit(alloc);

        const recovered = (try t.screens.active.lastCommandString(alloc)).?;
        defer alloc.free(recovered);
        try std.testing.expectEqualStrings("PS C:\\> Get-Date", recovered);
    }
}

fn pwshNestedShellAfterTransientRepeat(alloc: Allocator, c_mark: []const u8) ![]const u8 {
    // A prompt theme's transient prompt (Starship's Enable-TransientPrompt,
    // oh-my-posh's) redraws the prompt from its Enter handler, AFTER noctty
    // wrote the Enter, so the redrawn prompt's A opens a prompt again, and
    // only a C mark closes it. The line repeats the previous history entry,
    // so the old AddToHistoryHandler hook sent no C, and the nested shell's
    // bare A then read as part of PowerShell's prompt and inherited
    // `redraw=0`.
    var t = try pwshReplay(alloc, 40, &.{
        pwsh_prompt_marks ++ "STAR> \x1b]133;B\x07\x1b[93mwsl\x1b[0m",
        "",
        "\r" ++ pwsh_prompt_marks ++ "T> \x1b]133;B\x07\x1b[93mwsl\x1b[0m\r\n",
        c_mark,
        "\x1b]133;A;cl=line\x07\x1b[?2004hinner$ ",
    });
    defer t.deinit(alloc);
    try t.resize(alloc, 20, 8);
    return try t.plainString(alloc);
}

test "PowerShell marks: a shell started by a repeated line gets its prompt cleared on resize" {
    const alloc = std.testing.allocator;

    // The script now sends C for every accepted line: the nested shell's
    // prompt is left for it to redraw, which it will.
    const fixed = try pwshNestedShellAfterTransientRepeat(
        alloc,
        "\x1b]133;C;aid=1;cmdline_url=wsl\x07",
    );
    defer alloc.free(fixed);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "T> wsl") != null);
    try std.testing.expect(std.mem.indexOf(u8, fixed, "inner$") == null);

    // Control: the same bytes without C, which is what the old script sent
    // for this exact sequence. The nested prompt survives the resize, and
    // the nested shell then paints a second copy.
    const broken = try pwshNestedShellAfterTransientRepeat(alloc, "\x1b[0m");
    defer alloc.free(broken);
    try std.testing.expect(std.mem.indexOf(u8, broken, "inner$") != null);
}

test "PowerShell marks: a prompt the wrapper did not draw gets its marks from the line reader" {
    // `. $PROFILE` replaced the prompt, so the next prompt is drawn by the
    // user's own function: no D, no OSC 7, no A. The line reader then writes
    // OSC 7 and `P;k=i;redraw=0` in place of the A, and B. Trimmed from the
    // pwsh 7.6.6 recording of that exact sequence.
    const alloc = std.testing.allocator;
    const before = pwsh_prompt_marks ++ "PS> \x1b]133;B\x07. $PROFILE";
    const reload = "\r\n\x1b]133;C;aid=1;cmdline_url=.%20%24PROFILE\x07RELOADED> ";
    {
        var t = try pwshReplay(alloc, 40, &.{
            before,
            "",
            reload ++ "\x1b]7;file://h/C:/\x07\x1b]133;P;k=i;redraw=0\x07\x1b]133;B\x07",
        });
        defer t.deinit(alloc);
        // Input is marked, so noctty knows a line editor is reading here...
        try std.testing.expect(t.screens.active.semanticPromptInputPending());
        // ...and the prompt says it cannot redraw, so a resize keeps it.
        try std.testing.expect(t.flags.shell_redraws_prompt == .false);
        try t.resize(alloc, 20, 8);
        const screen = try t.plainString(alloc);
        defer alloc.free(screen);
        try std.testing.expect(std.mem.indexOf(u8, screen, "RELOADED>") != null);
    }
    // Control: the same prompt without the reader's marks, as before. No
    // input mark, so `insert_last_command` has nothing to type into.
    {
        var t = try pwshReplay(alloc, 40, &.{ before, "", reload });
        defer t.deinit(alloc);
        try std.testing.expect(!t.screens.active.semanticPromptInputPending());
    }
}
