const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.update_portable_apply);
const portableRelativePathAlloc = util.portableRelativePathAlloc;
const parseSha256Hex = util.parseSha256Hex;
const sha256File = util.sha256File;

pub const StagedKind = enum {
    installer,
    portable,
};

pub const Phase = enum {
    pending,
    swapped,
    confirmed,
    rollback,
};

pub const Event = union(enum) {
    next_launch,
    backup_completed,
    startup: struct {
        running_version: []const u8,
        target_version: []const u8,
        confirmation_token_matches: bool,
        installed_payload_matches: bool,
    },
    child_failed,
    interrupted,
    rollback_completed,
};

pub const Decision = enum {
    swap,
    clear_pending_and_continue,
    record_swapped_before_replace,
    continue_for_confirmation,
    confirm,
    rollback,
    clear_and_relaunch_old,
    cleanup,
};

/// Pure portable updater transition logic. The persisted staged kind is
/// checked before the phase so an installer stage can never be interpreted as
/// a portable transaction based on its path or extension.
pub fn decide(kind: ?StagedKind, phase: Phase, event: Event) !Decision {
    if (kind != .portable) return error.StagedKindMismatch;

    return switch (phase) {
        .pending => switch (event) {
            .next_launch => .swap,
            .backup_completed => .record_swapped_before_replace,
            .interrupted, .child_failed => .clear_pending_and_continue,
            else => error.InvalidPortableApplyTransition,
        },
        .swapped => switch (event) {
            .startup => |startup| if ((startup.confirmation_token_matches or
                startup.installed_payload_matches) and
                std.mem.eql(u8, startup.running_version, startup.target_version))
                .continue_for_confirmation
            else
                .rollback,
            .child_failed, .interrupted => .rollback,
            else => error.InvalidPortableApplyTransition,
        },
        .confirmed => switch (event) {
            .next_launch, .interrupted => .cleanup,
            .child_failed => .rollback,
            else => error.InvalidPortableApplyTransition,
        },
        .rollback => switch (event) {
            .next_launch, .interrupted, .child_failed => .rollback,
            .rollback_completed => .clear_and_relaunch_old,
            else => error.InvalidPortableApplyTransition,
        },
    };
}

pub fn confirmationDecision(
    kind: ?StagedKind,
    phase: Phase,
    running_version: []const u8,
    target_version: []const u8,
    confirmation_token_matches: bool,
    installed_payload_matches: bool,
) !Decision {
    const startup = try decide(kind, phase, .{ .startup = .{
        .running_version = running_version,
        .target_version = target_version,
        .confirmation_token_matches = confirmation_token_matches,
        .installed_payload_matches = installed_payload_matches,
    } });
    return if (startup == .continue_for_confirmation) .confirm else startup;
}

/// ZIP entry policy applied to every central-directory entry before extraction.
/// The release ZIP uses forward slashes and exactly one `noctty/` root.
pub fn isSafeZipEntryPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    if (!std.mem.eql(u8, path, "noctty/") and
        !std.mem.startsWith(u8, path, "noctty/")) return false;

    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    }
    return true;
}

/// Every file scripts/package-windows.ps1 puts in the portable root, which is
/// the same set Write-PortablePayloadManifest allows there. A payload member
/// missing from this list makes a genuine portable ZIP fail verification as an
/// unmanaged file, and one listed here but never staged makes apply fail as an
/// incomplete payload, so the two lists have to stay equal.
pub const managed_entries = [_][]const u8{
    "noctty.com",
    "ghostty-vt.dll",
    "noctty-terminal-handoff-proxy.dll",
    // Microsoft's bundled ConPTY pair. These are the only payload PEs noctty
    // does not sign; src/update/conpty_redist.zig pins their bytes instead.
    "conpty.dll",
    "OpenConsole.exe",
    "LICENSE",
    "LICENSE-conpty.txt",
    "config-template.ghostty",
    "README.md",
    "noctty.ico",
    "share",
    // Replace the executable last so an interrupted transaction always leaves
    // a launchable old or new preflight entrypoint.
    "noctty.exe",
};

/// Managed entries noctty no longer needs in a payload. A payload may leave
/// one out: `requirePayloadEntries` does not ask for it, and `swapPayload`
/// then moves the install's copy into the displaced directory, so a rollback
/// restores it from the backup and a confirmed update deletes it. Each one
/// stays in `managed_entries`, so the backup, the rollback and the manifest
/// checks keep covering it, and the update never removes anything else.
///
/// The updater of every release up to 1.3.136 has none of this: it refuses a
/// payload without every `managed_entries` name while staging
/// (`verifyPortablePayload`, in the running app) and again in the swap (run by
/// `portable-update-helper.exe`, a copy of the running, old, executable). So
/// the portable ZIP keeps shipping a retired file until a release with this
/// list has been out; `legacy_updater_required_entries` pins that.
pub const retired_entries = [_][]const u8{
    // libghostty-vt 0.1.0, the pre-1.0 C ABI under the name upstream's
    // libghostty-vt 1.0 DLL uses. noctty.exe does not import it.
    "ghostty-vt.dll",
};

pub fn isRetiredEntry(name: []const u8) bool {
    for (retired_entries) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

/// What the portable updater of releases up to 1.3.136 requires in a payload
/// (their `managed_entries`). Frozen: an older copy updates only to a release
/// whose portable ZIP holds every one of these.
const legacy_updater_required_entries = [_][]const u8{
    "noctty.com",
    "ghostty-vt.dll",
    "noctty-terminal-handoff-proxy.dll",
    "conpty.dll",
    "OpenConsole.exe",
    "LICENSE",
    "LICENSE-conpty.txt",
    "config-template.ghostty",
    "README.md",
    "noctty.ico",
    "share",
    "noctty.exe",
};

/// A payload has every managed entry except, possibly, retired ones.
pub fn requirePayloadEntries(alloc: Allocator, payload_root: []const u8) !void {
    for (managed_entries) |name| {
        const path = try std.fs.path.join(alloc, &.{ payload_root, name });
        defer alloc.free(path);
        _ = try payloadEntryPresent(path, name);
    }
}

/// Whether a payload has `name`: false only for a retired entry it leaves
/// out, `IncompletePortablePayload` for any other entry it cannot show.
fn payloadEntryPresent(path: []const u8, name: []const u8) !bool {
    std.fs.accessAbsolute(path, .{}) catch |err| return payloadEntryAbsent(err, name);
    return true;
}

/// How a failed access of a payload entry reads: only a retired entry that is
/// not there at all is allowed to be missing. Any other error, for a retired
/// entry too (access denied, a bad name), leaves the payload incomplete.
fn payloadEntryAbsent(err: anyerror, name: []const u8) error{IncompletePortablePayload}!bool {
    if (err == error.FileNotFound and isRetiredEntry(name)) return false;
    return error.IncompletePortablePayload;
}

test "portable payload entry access errors other than not-found are incomplete, retired or not" {
    try std.testing.expectEqual(false, try payloadEntryAbsent(error.FileNotFound, "ghostty-vt.dll"));
    for ([_]anyerror{
        error.AccessDenied,
        error.BadPathName,
        error.NameTooLong,
        error.InputOutput,
        error.PermissionDenied,
        error.Unexpected,
    }) |err| {
        try std.testing.expectError(error.IncompletePortablePayload, payloadEntryAbsent(err, "ghostty-vt.dll"));
        try std.testing.expectError(error.IncompletePortablePayload, payloadEntryAbsent(err, "noctty.com"));
    }
    try std.testing.expectError(error.IncompletePortablePayload, payloadEntryAbsent(error.FileNotFound, "noctty.com"));
}

// Test-only drift guard for the literal foreach lists in both manifest scripts.
// Parse their entries so ordering and PowerShell's two quote styles do not
// affect the comparison; reject unrecognized syntax instead of skipping it.
fn expectScriptManagedEntries(script: []const u8) !void {
    const root_marker = "$managedRootFiles =";
    const root_start = std.mem.indexOf(u8, script, root_marker) orelse
        return error.ManagedRootListMissing;
    const body = script[root_start + root_marker.len ..];
    const list_marker = "foreach ($name in @(";
    const list_start = std.mem.indexOf(u8, body, list_marker) orelse
        return error.ManagedRootListMissing;
    const remainder = body[list_start + list_marker.len ..];
    const list_end = std.mem.indexOf(u8, remainder, ")) {") orelse
        return error.InvalidManagedRootList;

    var seen = [_]bool{false} ** managed_entries.len;
    var lines = std.mem.splitScalar(u8, remainder[0..list_end], '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[line.len - 1] == ',') line = std.mem.trimEnd(u8, line[0 .. line.len - 1], " \t");
        if (line.len < 2 or (line[0] != '\'' and line[0] != '"') or
            line[line.len - 1] != line[0]) return error.InvalidManagedRootList;
        const name = line[1 .. line.len - 1];
        for (managed_entries, 0..) |entry, i| {
            if (!std.mem.eql(u8, name, entry)) continue;
            if (seen[i]) return error.DuplicateManagedRootEntry;
            seen[i] = true;
            break;
        } else return error.UnexpectedManagedRootEntry;
    }
    for (seen) |present| if (!present) return error.MissingManagedRootEntry;
}

test "portable managed entries match both PowerShell manifest script sets" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "scripts/package-windows.ps1",
        "scripts/portable-manifest-verification.ps1",
    }) |path| {
        const script = try std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
        defer alloc.free(script);
        try expectScriptManagedEntries(script);
    }
    try std.testing.expectEqualStrings("noctty.exe", managed_entries[managed_entries.len - 1]);
}

test "portable managed script list parser rejects missing extra and duplicate entries" {
    const prefix = "$managedRootFiles = @{}\nforeach ($name in @(\n";
    const suffix = ")) {\n    [void]$managedRootFiles.Add($name)\n}\n";
    // The script order deliberately differs from replacement order, and both
    // quote styles are accepted without evaluating any PowerShell.
    const tail =
        \\    "noctty.exe",
        \\    'ghostty-vt.dll',
        \\    'noctty-terminal-handoff-proxy.dll',
        \\    'conpty.dll',
        \\    'OpenConsole.exe',
        \\    'LICENSE',
        \\    'LICENSE-conpty.txt',
        \\    'config-template.ghostty',
        \\    'README.md',
        \\    'noctty.ico',
        \\    'share'
        \\
    ;
    const entries = "    'noctty.com',\n" ++ tail;
    try expectScriptManagedEntries(prefix ++ entries ++ suffix);
    try std.testing.expectError(error.MissingManagedRootEntry, expectScriptManagedEntries(prefix ++ tail ++ suffix));
    try std.testing.expectError(error.UnexpectedManagedRootEntry, expectScriptManagedEntries(prefix ++ "    'extra.txt',\n" ++ entries ++ suffix));
    try std.testing.expectError(error.DuplicateManagedRootEntry, expectScriptManagedEntries(prefix ++ "    'noctty.com',\n" ++ entries ++ suffix));
    try std.testing.expectError(error.ManagedRootListMissing, expectScriptManagedEntries(""));
    try std.testing.expectError(error.InvalidManagedRootList, expectScriptManagedEntries(prefix ++ "    $dynamicName\n" ++ suffix));
}

/// Whether the portable ZIP still carries the retired entries that
/// `legacy_updater_required_entries` names. Without them, every portable copy
/// of 1.3.136 or older fails to stage the update (`IncompletePortablePayload`)
/// and falls back to the release page. Set it to false only in the change
/// that drops them from the packaging scripts, once a release with
/// `retired_entries` has been the latest one long enough for copies to reach
/// it; a copy older than that still has to update by hand.
///
/// That change also drops the DLL from (names, not line numbers, so this
/// survives edits):
/// - `$runtimeFiles` and `-Demit-lib-vt=true` in scripts/package-windows.ps1
///   and scripts/build-package-windows.ps1, and ghostty-vt.pdb from the
///   symbols ZIP they build;
/// - `Get-WindowsSignedRuntimePayloads` in scripts/common.ps1 (the release
///   chain derives its expected signature count from it, so the count drops
///   on its own) and the pins of that list in
///   test/windows/flagship/contracts/Contracts.93-ConPty.ps1;
/// - scripts/test-windows-build-capabilities.ps1;
/// - the packaged-DLL smoke: test/windows/package-portable-cli.ps1 and
///   test/windows/test_dll_init.c;
/// - the symbols fixture in
///   test/windows/flagship/contracts/Contracts.82-ReleaseSymbols.ps1. It is
///   synthetic but not independent: `Assert-SymbolsMatchBinaries` takes its
///   binary list from `Get-WindowsSignedRuntimePayloads`, so with the DLL gone
///   from that list the fixture's ghostty-vt.pdb "matches no shipped binary",
///   its evidence count of 3 is wrong, and the age-mismatch case has to move
///   to another binary;
/// - the list in the github_releases.zig test "portable payload PEs are
///   publisher-pinned except the bundled ConPTY pair", which mirrors
///   `Get-WindowsSignedRuntimePayloads`.
/// These keep naming it. The `$managedRootFiles` allowlists in
/// scripts/portable-manifest-verification.ps1 and scripts/package-windows.ps1
/// must match `managed_entries`, which keeps the DLL while the updater manages
/// retired copies (they permit it in a payload, they do not require it).
/// And these verify releases that shipped it: docs/verify-release.md,
/// scripts/check-site-copy.ps1 and site/tests/trust.test.mjs. The lib-vt job
/// in .github/workflows/test.yml stays while CI builds lib-vt.
///
/// An option for that change, for the maintainer to weigh: ship a tiny
/// noctty-signed stub named ghostty-vt.dll (no exports) in place of the
/// library, so copies of 1.3.136 or older still update in-app. Their updater
/// (read at e629842e9, the 1.3.136 release commit, `github_releases.zig`)
/// asks of a payload DLL only that it exists (`verifyPortablePayload` and
/// `swapPayload`), has a line in the signed manifest with its SHA-256
/// (`verifyPortablePayloadAgainstManifest`), is `MZ`/`PE` with the build's
/// machine (`readPeMachine`) and carries a pinned-publisher Authenticode
/// signature (`verifyPortablePayloadBinaries`). Nothing reads its exports or
/// size. The cost: a file under the clashing name stays in the portable ZIP
/// (a program that loads it fails on missing entry points rather than a
/// mismatched ABI), and it stays in `Get-WindowsSignedRuntimePayloads`.
const portable_zip_carries_legacy_entries = true;

/// The quoted names of a PowerShell `<marker> @(` list, one per line.
fn scriptListContains(script: []const u8, marker: []const u8, name: []const u8) !bool {
    const start = std.mem.indexOf(u8, script, marker) orelse return error.ScriptListMissing;
    const body = script[start + marker.len ..];
    const end = std.mem.indexOf(u8, body, "\n)") orelse return error.ScriptListMissing;
    var lines = std.mem.splitScalar(u8, body[0..end], '\n');
    var count: usize = 0;
    var found = false;
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[line.len - 1] == ',') line = line[0 .. line.len - 1];
        if (line.len < 2 or (line[0] != '"' and line[0] != '\'') or line[line.len - 1] != line[0])
            return error.InvalidScriptList;
        count += 1;
        if (std.mem.eql(u8, line[1 .. line.len - 1], name)) found = true;
    }
    if (count == 0) return error.ScriptListMissing;
    return found;
}

/// The text of one `[Section]` of an Inno Setup script.
fn innoSection(script: []const u8, header: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, script, header) orelse return error.InnoSectionMissing;
    const body = script[start + header.len ..];
    const end = std.mem.indexOf(u8, body, "\n[") orelse body.len;
    return body[0..end];
}

/// The next line of an Inno section that ISCC compiles: trimmed, and neither
/// blank nor a `;` comment.
fn nextActiveInnoLine(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';') continue;
        return line;
    }
    return null;
}

fn innoSectionHasLine(section: []const u8, rule: []const u8) bool {
    var lines = std.mem.splitScalar(u8, section, '\n');
    while (nextActiveInnoLine(&lines)) |line| {
        if (std.mem.eql(u8, line, rule)) return true;
    }
    return false;
}

/// The `[InstallDelete]` rules for the libghostty-vt files an older Setup
/// installed under share\ (the portable updater swaps share\ whole, so these
/// left both packages without a transition).
const setup_delete_pc_rule = "Type: files; Name: \"{app}\\share\\pkgconfig\\libghostty-vt.pc\"";
const setup_delete_pc_dir_rule = "Type: dirifempty; Name: \"{app}\\share\\pkgconfig\"";
const setup_lib_vt_share_delete_rules = [_][]const u8{ setup_delete_pc_rule, setup_delete_pc_dir_rule };

/// Setup never installs a retired file, and deletes the copies an older Setup
/// left: exactly one active stage rule, whose `Excludes` names each retired
/// entry at the stage root, no other `[Files]` rule that could install one,
/// and an active `[InstallDelete]` rule for each.
///
/// This catches an edit that breaks the transition by mistake. It reads the
/// script as ISCC would only as far as ISPP conditionals and `{#...}`
/// expansions go (both refused around and in these rules); deliberately
/// obfuscating the script (`#include`, `#emit`, macros) is for review to catch.
fn checkSetupRetiresLibVt(alloc: Allocator, iss: []const u8) !void {
    const files = try innoSection(iss, "\n[Files]");
    const install_delete = try innoSection(iss, "\n[InstallDelete]");

    // ISPP drops whatever a false conditional wraps, including a whole section
    // when the conditional opens before its header, so neither header may sit
    // inside one.
    var depth: usize = 0;
    var script_lines = std.mem.splitScalar(u8, iss, '\n');
    while (script_lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "#if")) {
            depth += 1;
        } else if (std.mem.startsWith(u8, line, "#endif")) {
            depth -|= 1;
        } else if (depth > 0 and (std.mem.eql(u8, line, "[Files]") or std.mem.eql(u8, line, "[InstallDelete]"))) {
            return error.SetupRuleConditional;
        }
    }

    // Nor may either section hold a preprocessor line, so the active lines read
    // below are what ISCC compiles.
    for ([_][]const u8{ files, install_delete }) |section| {
        var raw_lines = std.mem.splitScalar(u8, section, '\n');
        while (raw_lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len > 0 and line[0] == '#') return error.SetupRuleConditional;
        }
    }

    const stage_prefix = "Source: \"{#StageDir}\\*\";";
    var stage_rule: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, files, '\n');
    while (nextActiveInnoLine(&lines)) |line| {
        if (std.mem.startsWith(u8, line, stage_prefix)) {
            if (stage_rule != null) return error.SetupStageRuleNotUnique;
            stage_rule = line;
            continue;
        }
        // The stage rule's Excludes covers only that rule, so any other rule
        // names its files literally: no ISPP expansion, no wildcard, and
        // nothing from libghostty-vt.
        if (std.mem.indexOf(u8, line, "{#") != null) return error.SetupRuleExpansion;
        if (std.mem.indexOfAny(u8, line, "*?") != null) return error.SetupExtraWildcardRule;
        for (retired_entries) |entry| {
            if (std.ascii.indexOfIgnoreCase(line, entry) != null) return error.RetiredEntryInstalledBySetup;
        }
        if (std.ascii.indexOfIgnoreCase(line, "libghostty-vt") != null) return error.LibVtShareFileInstalledBySetup;
    }
    const rule = stage_rule orelse return error.SetupStageRuleMissing;

    // The rule's `Excludes: "..."` parameter, split at its commas.
    var excludes: ?[]const u8 = null;
    var params = std.mem.splitScalar(u8, rule, ';');
    while (params.next()) |raw_param| {
        const param = std.mem.trim(u8, raw_param, " \t");
        const name = "Excludes: \"";
        if (!std.mem.startsWith(u8, param, name) or param[param.len - 1] != '"') continue;
        excludes = param[name.len .. param.len - 1];
    }
    for (retired_entries) |entry| {
        const exclude = try std.fmt.allocPrint(alloc, "\\{s}", .{entry});
        defer alloc.free(exclude);
        var patterns = std.mem.splitScalar(u8, excludes orelse return error.RetiredEntryInstalledBySetup, ',');
        while (patterns.next()) |pattern| {
            if (std.mem.eql(u8, std.mem.trim(u8, pattern, " "), exclude)) break;
        } else return error.RetiredEntryInstalledBySetup;

        const delete_rule = try std.fmt.allocPrint(alloc, "Type: files; Name: \"{{app}}\\{s}\"", .{entry});
        defer alloc.free(delete_rule);
        if (!innoSectionHasLine(install_delete, delete_rule)) return error.RetiredEntryLeftBySetup;
    }
    for (setup_lib_vt_share_delete_rules) |delete_rule| {
        if (!innoSectionHasLine(install_delete, delete_rule)) return error.LibVtShareFileLeftBySetup;
    }
}

test "Setup retirement check reads only the rules ISCC compiles" {
    const alloc = std.testing.allocator;
    const iss = try std.fs.cwd().readFileAlloc(alloc, "dist/windows/noctty.iss", 1024 * 1024);
    defer alloc.free(iss);
    try checkSetupRetiresLibVt(alloc, iss);

    // Each mutation of the shipped script must fail: a rule commented out,
    // deleted or wrapped in an ISPP conditional, the Excludes dropped or not
    // naming the root file, or a separate [Files] rule that bypasses it.
    const Mutation = struct { from: []const u8, to: []const u8, err: anyerror };
    const delete_dll = "Type: files; Name: \"{app}\\ghostty-vt.dll\"";
    const delete_pc = setup_delete_pc_rule;
    const delete_pc_dir = setup_delete_pc_dir_rule;
    const excludes = " Excludes: \"\\ghostty-vt.dll\";";
    const stage = "Source: \"{#StageDir}\\*\";";
    const files_end = "\n[InstallDelete]";
    for ([_]Mutation{
        .{ .from = delete_dll, .to = "; " ++ delete_dll, .err = error.RetiredEntryLeftBySetup },
        .{ .from = delete_dll, .to = "", .err = error.RetiredEntryLeftBySetup },
        .{ .from = delete_dll, .to = "Type: files; Name: \"{app}\\share\\ghostty-vt.dll\"", .err = error.RetiredEntryLeftBySetup },
        .{ .from = delete_pc, .to = ";" ++ delete_pc, .err = error.LibVtShareFileLeftBySetup },
        .{ .from = delete_pc_dir, .to = "  ; " ++ delete_pc_dir, .err = error.LibVtShareFileLeftBySetup },
        .{ .from = excludes, .to = "", .err = error.RetiredEntryInstalledBySetup },
        .{ .from = excludes, .to = " Excludes: \"ghostty-vt.dll.txt\";", .err = error.RetiredEntryInstalledBySetup },
        .{ .from = stage, .to = "; " ++ stage, .err = error.SetupStageRuleMissing },
        .{ .from = delete_dll, .to = "#if 0\n" ++ delete_dll ++ "\n#endif", .err = error.SetupRuleConditional },
        .{ .from = stage, .to = "#if 0\n#endif\n" ++ stage, .err = error.SetupRuleConditional },
        .{ .from = files_end, .to = "\nSource: \"stage\\ghostty-vt.dll\"; DestDir: \"{app}\"" ++ files_end, .err = error.RetiredEntryInstalledBySetup },
        .{ .from = files_end, .to = "\nSource: \"stage\\share\\pkgconfig\\libghostty-vt.pc\"; DestDir: \"{app}\\share\\pkgconfig\"" ++ files_end, .err = error.LibVtShareFileInstalledBySetup },
        .{ .from = files_end, .to = "\nSource: \"stage\\ghostty-*.dll\"; DestDir: \"{app}\"" ++ files_end, .err = error.SetupExtraWildcardRule },
        // An ISPP expansion hides the name an extra rule installs.
        .{ .from = files_end, .to = "\nSource: \"{#LegacyDll}\"; DestDir: \"{app}\"" ++ files_end, .err = error.SetupRuleExpansion },
        // A conditional opened before a section header drops the whole section.
        .{ .from = files_end, .to = "\n[Icons]\n#if 0" ++ files_end, .err = error.SetupRuleConditional },
    }) |mutation| {
        try std.testing.expect(std.mem.indexOf(u8, iss, mutation.from) != null);
        const mutated = try std.mem.replaceOwned(u8, alloc, iss, mutation.from, mutation.to);
        defer alloc.free(mutated);
        checkSetupRetiresLibVt(alloc, mutated) catch |err| {
            try std.testing.expectEqual(mutation.err, err);
            continue;
        };
        std.debug.print("mutation passed: '{s}' -> '{s}'\n", .{ mutation.from, mutation.to });
        return error.TestExpectedError;
    }

    // A commented-out duplicate of the stage rule is not a second rule.
    const commented_copy = try std.mem.replaceOwned(u8, alloc, iss, "\n[InstallDelete]", "\n; Source: \"{#StageDir}\\*\"; DestDir: \"{app}\"\n[InstallDelete]");
    defer alloc.free(commented_copy);
    try checkSetupRetiresLibVt(alloc, commented_copy);
}

test "portable payload keeps retired entries while older updaters require them" {
    const alloc = std.testing.allocator;

    // This updater still manages everything the older ones did, so it backs
    // each one up and is the only code that may remove it.
    for (legacy_updater_required_entries) |entry| {
        for (managed_entries) |managed| {
            if (std.mem.eql(u8, entry, managed)) break;
        } else return error.LegacyEntryNoLongerManaged;
    }
    for (retired_entries) |entry| {
        for (managed_entries) |managed| {
            if (std.mem.eql(u8, entry, managed)) break;
        } else return error.RetiredEntryNotManaged;
        try std.testing.expect(!std.mem.eql(u8, entry, "noctty.exe"));
        try std.testing.expect(!std.mem.eql(u8, entry, "share"));
    }

    // The portable ZIP is staged from `$runtimeFiles` (built by both scripts).
    for ([_][]const u8{
        "scripts/package-windows.ps1",
        "scripts/build-package-windows.ps1",
    }) |path| {
        const script = try std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
        defer alloc.free(script);
        for (legacy_updater_required_entries) |entry| {
            if (!isRetiredEntry(entry)) continue;
            const shipped = try scriptListContains(script, "$runtimeFiles = @(", entry);
            if (shipped != portable_zip_carries_legacy_entries) {
                std.debug.print("{s}: $runtimeFiles {s} {s}\n", .{
                    path,
                    if (shipped) "still lists" else "dropped",
                    entry,
                });
                return error.RetiredEntryTransitionBroken;
            }
        }
    }

    // Setup runs the new release's own script, so it needs no transition:
    // it never installs a retired file, and removes the copy an older Setup
    // installed.
    const iss = try std.fs.cwd().readFileAlloc(alloc, "dist/windows/noctty.iss", 1024 * 1024);
    defer alloc.free(iss);
    try checkSetupRetiresLibVt(alloc, iss);
}

test "portable script list parser reads quoted names and rejects other syntax" {
    const list = "$runtimeFiles = @(\n    \"a.exe\",\n    # note\n    'b.dll'\n)\n";
    try std.testing.expect(try scriptListContains(list, "$runtimeFiles = @(", "b.dll"));
    try std.testing.expect(!try scriptListContains(list, "$runtimeFiles = @(", "c.dll"));
    try std.testing.expectError(error.ScriptListMissing, scriptListContains(list, "$other = @(", "a.exe"));
    try std.testing.expectError(
        error.InvalidScriptList,
        scriptListContains("$runtimeFiles = @(\n    $dynamic\n)\n", "$runtimeFiles = @(", "a.exe"),
    );
}

const backup_complete_name = ".complete";
const max_backup_manifest_bytes = 2 * 1024 * 1024;

pub fn prepareBackup(
    alloc: Allocator,
    install_root: []const u8,
    backup_root: []const u8,
) !void {
    // A complete backup belongs to the current transaction. In particular,
    // never replace it after an interrupted, partially completed swap.
    if (backupIsComplete(alloc, backup_root)) return;

    removePathIfExists(backup_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.cwd().makePath(backup_root);

    for (managed_entries) |name| {
        const source = try std.fs.path.join(alloc, &.{ install_root, name });
        defer alloc.free(source);
        const destination = try std.fs.path.join(alloc, &.{ backup_root, name });
        defer alloc.free(destination);
        copyPath(alloc, source, destination) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    try syncDirectory(alloc, backup_root);
    try commitBackupManifest(alloc, backup_root);
}

pub fn backupIsComplete(alloc: Allocator, backup_root: []const u8) bool {
    validateBackup(alloc, backup_root) catch return false;
    return true;
}

pub fn validateBackup(alloc: Allocator, backup_root: []const u8) !void {
    if (try pathIsWindowsReparsePointChecked(alloc, backup_root)) {
        return error.IncompletePortableUpdateBackup;
    }
    try verifyBackupManifest(alloc, backup_root, null, false);
}

pub fn swapPayload(
    alloc: Allocator,
    install_root: []const u8,
    payload_root: []const u8,
    backup_root: []const u8,
    displaced_root: []const u8,
) !void {
    if (!backupIsComplete(alloc, backup_root)) return error.IncompletePortableUpdateBackup;
    removePathIfExists(displaced_root) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.cwd().makePath(displaced_root);

    // Check the whole payload before the first replacement, so a payload
    // that is missing a required entry changes nothing.
    try requirePayloadEntries(alloc, payload_root);
    for (managed_entries) |name| {
        const source = try std.fs.path.join(alloc, &.{ payload_root, name });
        defer alloc.free(source);
        const target = try std.fs.path.join(alloc, &.{ install_root, name });
        defer alloc.free(target);
        const displaced = try std.fs.path.join(alloc, &.{ displaced_root, name });
        defer alloc.free(displaced);
        if (!try payloadEntryPresent(source, name)) {
            // A retired file the new payload no longer ships: move the
            // install's copy aside like any replaced file.
            try displaceManagedPath(target, displaced);
            continue;
        }
        try replaceManagedPath(alloc, source, target, displaced);
    }
}

fn displaceManagedPath(target: []const u8, displaced: []const u8) !void {
    removePathIfExists(displaced) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.fs.renameAbsolute(target, displaced) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn rollback(
    alloc: Allocator,
    install_root: []const u8,
    backup_root: []const u8,
    displaced_root: []const u8,
) !void {
    try validateBackup(alloc, backup_root);

    const install_share = try std.fs.path.join(alloc, &.{ install_root, "share" });
    defer alloc.free(install_share);
    const displaced_share = try std.fs.path.join(alloc, &.{ displaced_root, "share" });
    defer alloc.free(displaced_share);
    const backup_share = try std.fs.path.join(alloc, &.{ backup_root, "share" });
    defer alloc.free(backup_share);

    removePathIfExists(install_share) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const displaced_share_kind = pathKind(displaced_share) catch null;
    const restored_share_by_rename = restored: {
        if (displaced_share_kind != .directory) break :restored false;
        std.fs.renameAbsolute(displaced_share, install_share) catch break :restored false;
        break :restored true;
    };
    if (!restored_share_by_rename) {
        removePathIfExists(install_share) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        copyPath(alloc, backup_share, install_share) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    try verifyBackupManifest(alloc, backup_root, install_root, true);
}

pub fn cleanupBackup(backup_root: []const u8) !void {
    return cleanupUpdatePath(backup_root);
}

pub fn cleanupUpdatePath(path: []const u8) !void {
    removePathIfExists(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn replaceManagedPath(
    alloc: Allocator,
    source: []const u8,
    target: []const u8,
    displaced: []const u8,
) !void {
    if (try pathKind(source) != .directory) return replaceFileAtomic(alloc, source, target);

    removePathIfExists(displaced) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.fs.renameAbsolute(target, displaced) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.fs.renameAbsolute(source, target) catch |err| {
        std.fs.renameAbsolute(displaced, target) catch {};
        return err;
    };
}

fn replaceFileAtomic(alloc: Allocator, source: []const u8, target: []const u8) !void {
    if (builtin.os.tag != .windows) {
        std.fs.deleteFileAbsolute(target) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return std.fs.renameAbsolute(source, target);
    }

    const source_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, source);
    defer alloc.free(source_w);
    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, target);
    defer alloc.free(target_w);
    if (ReplaceFileW(target_w.ptr, source_w.ptr, null, 0, null, null) != 0) return;
    if (MoveFileExW(source_w.ptr, target_w.ptr, movefile_replace_existing) != 0) return;
    return error.PortableUpdateReplaceFailed;
}

fn copyPath(alloc: Allocator, source: []const u8, destination: []const u8) !void {
    if (pathIsWindowsReparsePoint(source)) return error.InvalidPortableUpdatePath;
    if (try pathKind(source) != .directory) {
        if (std.fs.path.dirname(destination)) |parent| try std.fs.cwd().makePath(parent);
        try std.fs.copyFileAbsolute(source, destination, .{});
        const copied = try std.fs.openFileAbsolute(destination, .{ .mode = .read_write });
        defer copied.close();
        return copied.sync();
    }

    try std.fs.cwd().makePath(destination);
    var source_dir = try std.fs.openDirAbsolute(source, .{ .iterate = true });
    defer source_dir.close();
    var iter = source_dir.iterate();
    while (try iter.next()) |entry| {
        const child_source = try std.fs.path.join(alloc, &.{ source, entry.name });
        defer alloc.free(child_source);
        const child_destination = try std.fs.path.join(alloc, &.{ destination, entry.name });
        defer alloc.free(child_destination);
        try copyPath(alloc, child_source, child_destination);
    }
    try syncDirectory(alloc, destination);
}

/// Best-effort on Windows, and deliberately so: `FlushFileBuffers` is
/// documented for files, volumes, and communication devices, not for
/// directory handles, and it reports ERROR_ACCESS_DENIED on filesystems and
/// SMB shares that refuse the `GENERIC_WRITE` directory open. Windows offers
/// no equivalent of POSIX fsync-on-a-directory, so propagating that refusal
/// would abort a portable apply on a working machine over an operation that
/// was never guaranteed. Every file's own contents are still flushed through
/// its file handle before this runs, which is the durability that matters.
/// Non-Windows keeps the real `fsync` and its error.
fn syncDirectory(alloc: Allocator, path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        var dir = try std.fs.openDirAbsolute(path, .{});
        defer dir.close();
        return std.posix.fsync(dir.fd);
    }
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const handle = std.os.windows.kernel32.CreateFileW(
        path_w.ptr,
        std.os.windows.GENERIC_WRITE,
        std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE | std.os.windows.FILE_SHARE_DELETE,
        null,
        std.os.windows.OPEN_EXISTING,
        std.os.windows.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
        log.debug("directory sync open unsupported path={s} err={}", .{
            path,
            std.os.windows.kernel32.GetLastError(),
        });
        return;
    }
    defer std.os.windows.CloseHandle(handle);
    if (std.os.windows.kernel32.FlushFileBuffers(handle) == 0) {
        log.debug("directory sync unsupported path={s} err={}", .{
            path,
            std.os.windows.kernel32.GetLastError(),
        });
    }
}

fn commitBackupManifest(alloc: Allocator, backup_root: []const u8) !void {
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(alloc);
    var backup_dir = try std.fs.openDirAbsolute(backup_root, .{ .iterate = true });
    defer backup_dir.close();
    var walker = try backup_dir.walk(alloc);
    defer walker.deinit();
    var file_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.IncompletePortableUpdateBackup;
        const relative = try portableRelativePathAlloc(alloc, entry.path);
        defer alloc.free(relative);
        if (!isManagedRelativePath(relative)) return error.IncompletePortableUpdateBackup;
        const path = try std.fs.path.join(alloc, &.{ backup_root, entry.path });
        defer alloc.free(path);
        const digest = try sha256File(path);
        try contents.writer(alloc).print("{s} *{s}\n", .{
            std.fmt.bytesToHex(digest, .lower),
            relative,
        });
        file_count += 1;
    }
    if (file_count == 0) return error.IncompletePortableUpdateBackup;

    const marker_path = try std.fs.path.join(alloc, &.{ backup_root, backup_complete_name });
    defer alloc.free(marker_path);
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{marker_path});
    defer alloc.free(temp_path);
    const marker = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
    defer marker.close();
    try marker.writeAll(contents.items);
    try marker.sync();
    if (builtin.os.tag == .windows) {
        const source_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, temp_path);
        defer alloc.free(source_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, marker_path);
        defer alloc.free(target_w);
        if (MoveFileExW(source_w.ptr, target_w.ptr, movefile_replace_existing | movefile_write_through) == 0) {
            return error.PortableUpdateReplaceFailed;
        }
    } else {
        try std.fs.renameAbsolute(temp_path, marker_path);
    }
}

fn verifyBackupManifest(
    alloc: Allocator,
    backup_root: []const u8,
    restore_root: ?[]const u8,
    share_already_restored: bool,
) !void {
    const marker_path = try std.fs.path.join(alloc, &.{ backup_root, backup_complete_name });
    defer alloc.free(marker_path);
    const contents = try std.fs.cwd().readFileAlloc(alloc, marker_path, max_backup_manifest_bytes);
    defer alloc.free(contents);

    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| alloc.free(key.*);
        seen.deinit(alloc);
    }
    var file_count: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line.len <= std.crypto.hash.sha2.Sha256.digest_length * 2) {
            return error.IncompletePortableUpdateBackup;
        }
        const hex = line[0 .. std.crypto.hash.sha2.Sha256.digest_length * 2];
        const name_raw = std.mem.trimLeft(
            u8,
            line[std.crypto.hash.sha2.Sha256.digest_length * 2 ..],
            " \t",
        );
        if (name_raw.len < 2 or name_raw[0] != '*') return error.IncompletePortableUpdateBackup;
        const name = name_raw[1..];
        if (!isManagedRelativePath(name)) return error.IncompletePortableUpdateBackup;
        const key = try std.ascii.allocLowerString(alloc, name);
        const gop = try seen.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            return error.IncompletePortableUpdateBackup;
        }
        const expected = parseSha256Hex(hex) catch return error.IncompletePortableUpdateBackup;
        const backup_path = try joinPortableRelativePath(alloc, backup_root, name);
        defer alloc.free(backup_path);
        const actual = sha256File(backup_path) catch |err| switch (err) {
            error.FileNotFound => return error.IncompletePortableUpdateBackup,
            else => return err,
        };
        if (!std.mem.eql(u8, &expected, &actual)) return error.IncompletePortableUpdateBackup;

        if (restore_root) |root| {
            const target = try joinPortableRelativePath(alloc, root, name);
            defer alloc.free(target);
            if ((!share_already_restored or
                !(std.mem.eql(u8, name, "share") or std.mem.startsWith(u8, name, "share/"))) and
                !fileMatches(target, &expected))
            {
                // A file the failed swap never changed already holds the
                // backup's bytes. Rewriting it anyway fails exactly when the
                // swap did, on a copy another process holds open without
                // delete sharing, and a rollback that fails relaunches
                // nothing.
                const restore_temp = try std.fmt.allocPrint(alloc, "{s}.restore", .{target});
                defer alloc.free(restore_temp);
                removePathIfExists(restore_temp) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
                try copyPath(alloc, backup_path, restore_temp);
                try replaceFileAtomic(alloc, restore_temp, target);
            }
            const restored = try sha256File(target);
            if (!std.mem.eql(u8, &expected, &restored)) return error.IncompletePortableUpdateRollback;
        }
        file_count += 1;
    }
    if (file_count == 0) return error.IncompletePortableUpdateBackup;

    if (restore_root) |root| {
        for (managed_entries) |managed_entry| {
            if (std.mem.eql(u8, managed_entry, "share") or
                std.mem.eql(u8, managed_entry, "noctty.exe")) continue;
            const key = try std.ascii.allocLowerString(alloc, managed_entry);
            defer alloc.free(key);
            if (seen.contains(key)) continue;
            const managed_path = try std.fs.path.join(alloc, &.{ root, managed_entry });
            defer alloc.free(managed_path);
            removePathIfExists(managed_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }

        var restored_file_count: usize = 0;
        for (managed_entries) |managed_entry| {
            const managed_path = try std.fs.path.join(alloc, &.{ root, managed_entry });
            defer alloc.free(managed_path);
            const kind = pathKind(managed_path) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            if (!std.mem.eql(u8, managed_entry, "share")) {
                if (kind != .file) return error.IncompletePortableUpdateRollback;
                const key = try std.ascii.allocLowerString(alloc, managed_entry);
                defer alloc.free(key);
                if (!seen.contains(key)) return error.IncompletePortableUpdateRollback;
                restored_file_count += 1;
                continue;
            }
            if (kind != .directory) return error.IncompletePortableUpdateRollback;
            var managed_dir = try std.fs.openDirAbsolute(managed_path, .{ .iterate = true });
            defer managed_dir.close();
            var walker = try managed_dir.walk(alloc);
            defer walker.deinit();
            while (try walker.next()) |entry| {
                if (entry.kind == .directory) continue;
                if (entry.kind != .file) return error.IncompletePortableUpdateRollback;
                const native_relative = try std.fs.path.join(
                    alloc,
                    &.{ managed_entry, entry.path },
                );
                defer alloc.free(native_relative);
                const relative = try portableRelativePathAlloc(alloc, native_relative);
                defer alloc.free(relative);
                const key = try std.ascii.allocLowerString(alloc, relative);
                defer alloc.free(key);
                if (!seen.contains(key)) return error.IncompletePortableUpdateRollback;
                restored_file_count += 1;
            }
        }
        if (restored_file_count != file_count) return error.IncompletePortableUpdateRollback;
    }
}

/// Whether `path` is a file whose SHA-256 is `expected`. Any failure to read
/// it (missing, a directory, unreadable) is a no.
fn fileMatches(path: []const u8, expected: *const [std.crypto.hash.sha2.Sha256.digest_length]u8) bool {
    if (pathIsWindowsReparsePoint(path)) return false;
    const kind = pathKind(path) catch return false;
    if (kind != .file) return false;
    const actual = sha256File(path) catch return false;
    return std.mem.eql(u8, expected, &actual);
}

fn joinPortableRelativePath(alloc: Allocator, root: []const u8, relative: []const u8) ![]u8 {
    const native = try alloc.dupe(u8, relative);
    defer alloc.free(native);
    for (native) |*byte| {
        if (byte.* == '/') byte.* = std.fs.path.sep;
    }
    return std.fs.path.join(alloc, &.{ root, native });
}

pub fn isManagedRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, ':') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (managed_entries) |entry| {
        if (std.mem.eql(u8, path, entry)) return true;
        if (std.mem.eql(u8, entry, "share") and std.mem.startsWith(u8, path, "share/")) return true;
    }
    return false;
}

fn removePathIfExists(path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(path_w);
        const attributes = std.os.windows.kernel32.GetFileAttributesW(path_w.ptr);
        if (attributes != std.os.windows.INVALID_FILE_ATTRIBUTES and
            attributes & std.os.windows.FILE_ATTRIBUTE_REPARSE_POINT != 0)
        {
            if (attributes & file_attribute_directory != 0) {
                return std.fs.deleteDirAbsolute(path);
            }
            return std.fs.deleteFileAbsolute(path);
        }
    }
    if (try pathKind(path) == .directory) return std.fs.deleteTreeAbsolute(path);
    return std.fs.deleteFileAbsolute(path);
}

fn pathKind(path: []const u8) !std.fs.File.Kind {
    if (builtin.os.tag != .windows) return (try std.fs.cwd().statFile(path)).kind;
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(path_w);
    const attributes = std.os.windows.kernel32.GetFileAttributesW(path_w.ptr);
    if (attributes == std.os.windows.INVALID_FILE_ATTRIBUTES) {
        const err = std.os.windows.kernel32.GetLastError();
        return switch (err) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            else => std.os.windows.unexpectedError(err),
        };
    }
    return if (attributes & file_attribute_directory != 0) .directory else .file;
}

fn pathIsWindowsReparsePoint(path: []const u8) bool {
    return pathIsWindowsReparsePointChecked(std.heap.page_allocator, path) catch false;
}

fn pathIsWindowsReparsePointChecked(alloc: Allocator, path: []const u8) !bool {
    if (builtin.os.tag != .windows) return false;
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const attributes = std.os.windows.kernel32.GetFileAttributesW(path_w.ptr);
    if (attributes == std.os.windows.INVALID_FILE_ATTRIBUTES) {
        const err = std.os.windows.kernel32.GetLastError();
        return switch (err) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            else => std.os.windows.unexpectedError(err),
        };
    }
    return attributes & std.os.windows.FILE_ATTRIBUTE_REPARSE_POINT != 0;
}

const movefile_replace_existing: u32 = 0x1;
const movefile_write_through: u32 = 0x8;
const file_attribute_directory: u32 = 0x10;
extern "kernel32" fn ReplaceFileW(
    replaced_file_name: [*:0]const u16,
    replacement_file_name: [*:0]const u16,
    backup_file_name: ?[*:0]const u16,
    replace_flags: u32,
    exclude: ?*anyopaque,
    reserved: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn MoveFileExW(
    existing_file_name: [*:0]const u16,
    new_file_name: [*:0]const u16,
    flags: u32,
) callconv(.winapi) i32;

test "portable update decision pending swapped confirm rollback interrupted" {
    const testing = std.testing;

    try testing.expectEqual(Decision.swap, try decide(.portable, .pending, .next_launch));
    try testing.expectEqual(Decision.record_swapped_before_replace, try decide(.portable, .pending, .backup_completed));
    try testing.expectEqual(Decision.clear_pending_and_continue, try decide(.portable, .pending, .interrupted));
    try testing.expectEqual(Decision.clear_pending_and_continue, try decide(.portable, .pending, .child_failed));
    try testing.expectEqual(Decision.rollback, try decide(.portable, .swapped, .child_failed));
    try testing.expectEqual(Decision.cleanup, try decide(.portable, .confirmed, .interrupted));
    try testing.expectEqual(Decision.rollback, try decide(.portable, .confirmed, .child_failed));
    try testing.expectEqual(Decision.rollback, try decide(.portable, .rollback, .interrupted));
    try testing.expectEqual(Decision.clear_and_relaunch_old, try decide(.portable, .rollback, .rollback_completed));

    try testing.expectEqual(Decision.confirm, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.200",
        "1.3.200",
        true,
        false,
    ));
    try testing.expectEqual(Decision.rollback, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.199",
        "1.3.200",
        true,
        false,
    ));
    try testing.expectEqual(Decision.rollback, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.200",
        "1.3.200",
        false,
        false,
    ));

    // A concurrent launch does not inherit the helper's confirmation token.
    // Content identity still proves that the target build completed its swap.
    try testing.expectEqual(Decision.confirm, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.200",
        "1.3.200",
        false,
        true,
    ));
    try testing.expectEqual(Decision.rollback, try confirmationDecision(
        .portable,
        .swapped,
        "1.3.199",
        "1.3.200",
        false,
        true,
    ));
}

test "portable update rejects staged kind confusion" {
    try std.testing.expectError(
        error.StagedKindMismatch,
        decide(.installer, .pending, .next_launch),
    );
    try std.testing.expectError(
        error.StagedKindMismatch,
        decide(null, .pending, .next_launch),
    );
}

test "portable update preserves complete backup across interrupted retry" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install/share");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/resource theme.txt", .data = "old-resource" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);

    try prepareBackup(alloc, install_root, backup_root);
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "mixed" });
    try prepareBackup(alloc, install_root, backup_root);

    const backed_up = try tmp.dir.readFileAlloc(alloc, "backup/noctty.com", 16);
    defer alloc.free(backed_up);
    try std.testing.expectEqualStrings("old", backed_up);
}

test "portable rollback removes new-only managed files without deleting user data" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install/share");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/resource theme.txt", .data = "old-resource" });
    try tmp.dir.writeFile(.{ .sub_path = "install/user-data.txt", .data = "keep" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);
    const displaced_root = try std.fs.path.join(alloc, &.{ root, "displaced" });
    defer alloc.free(displaced_root);
    try prepareBackup(alloc, install_root, backup_root);
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "new" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/resource theme.txt", .data = "new-resource" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/new-only.ps1", .data = "new-only share" });
    try tmp.dir.writeFile(.{ .sub_path = "install/LICENSE", .data = "new-only" });

    try rollback(alloc, install_root, backup_root, displaced_root);
    const restored = try tmp.dir.readFileAlloc(alloc, "install/noctty.com", 16);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings("old", restored);
    const restored_resource = try tmp.dir.readFileAlloc(alloc, "install/share/resource theme.txt", 32);
    defer alloc.free(restored_resource);
    try std.testing.expectEqualStrings("old-resource", restored_resource);
    const sentinel = try tmp.dir.readFileAlloc(alloc, "install/user-data.txt", 16);
    defer alloc.free(sentinel);
    try std.testing.expectEqualStrings("keep", sentinel);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("install/share/new-only.ps1", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("install/LICENSE", .{}));
}

test "portable rollback renames displaced share tree back exactly" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install/share/shell-integration");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old executable" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/old-only.ps1", .data = "old only" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/shared.ps1", .data = "old shared" });
    try tmp.dir.writeFile(.{ .sub_path = "install/user-data.txt", .data = "keep" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);
    const displaced_root = try std.fs.path.join(alloc, &.{ root, "displaced" });
    defer alloc.free(displaced_root);
    try prepareBackup(alloc, install_root, backup_root);

    try tmp.dir.makePath("displaced");
    try tmp.dir.rename("install/share", "displaced/share");
    try tmp.dir.makePath("install/share");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "new executable" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/shared.ps1", .data = "new shared" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/new-only.ps1", .data = "new only" });

    try rollback(alloc, install_root, backup_root, displaced_root);
    const restored_executable = try tmp.dir.readFileAlloc(alloc, "install/noctty.com", 32);
    defer alloc.free(restored_executable);
    try std.testing.expectEqualStrings("old executable", restored_executable);
    const restored_old_only = try tmp.dir.readFileAlloc(alloc, "install/share/old-only.ps1", 32);
    defer alloc.free(restored_old_only);
    try std.testing.expectEqualStrings("old only", restored_old_only);
    const restored_shared = try tmp.dir.readFileAlloc(alloc, "install/share/shared.ps1", 32);
    defer alloc.free(restored_shared);
    try std.testing.expectEqualStrings("old shared", restored_shared);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("install/share/new-only.ps1", .{}));
    const user_data = try tmp.dir.readFileAlloc(alloc, "install/user-data.txt", 16);
    defer alloc.free(user_data);
    try std.testing.expectEqualStrings("keep", user_data);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("displaced/share", .{}));
}

/// A payload under `root` with every managed entry, each file holding
/// "new <name>", except the names in `omit`.
fn writeTestPayload(dir: std.fs.Dir, root: []const u8, omit: []const []const u8) !void {
    try dir.makePath(root);
    var buf: [256]u8 = undefined;
    entries: for (managed_entries) |name| {
        for (omit) |omitted| if (std.mem.eql(u8, name, omitted)) continue :entries;
        if (std.mem.eql(u8, name, "share")) {
            const sub_path = try std.fmt.bufPrint(&buf, "{s}/share/themes/theme.txt", .{root});
            try dir.makePath(std.fs.path.dirname(sub_path).?);
            try dir.writeFile(.{ .sub_path = sub_path, .data = "new share" });
            continue;
        }
        const sub_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, name });
        var data_buf: [128]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "new {s}", .{name});
        try dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }
}

test "portable payload check requires every managed entry except a retired one" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestPayload(tmp.dir, "full", &.{});
    try writeTestPayload(tmp.dir, "without-retired", &retired_entries);
    try writeTestPayload(tmp.dir, "without-com", &.{"noctty.com"});
    try writeTestPayload(tmp.dir, "without-share", &.{"share"});

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    for ([_]struct { name: []const u8, ok: bool }{
        .{ .name = "full", .ok = true },
        .{ .name = "without-retired", .ok = true },
        .{ .name = "without-com", .ok = false },
        .{ .name = "without-share", .ok = false },
    }) |case| {
        const payload_root = try std.fs.path.join(alloc, &.{ root, case.name });
        defer alloc.free(payload_root);
        if (case.ok) {
            try requirePayloadEntries(alloc, payload_root);
        } else {
            try std.testing.expectError(error.IncompletePortablePayload, requirePayloadEntries(alloc, payload_root));
        }
    }
}

test "portable swap removes a retired file the payload leaves out, and rollback restores it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // An install from a release that still shipped ghostty-vt.dll, with the
    // user's own files beside it.
    try tmp.dir.makePath("install/share");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.exe", .data = "old exe" });
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old com" });
    try tmp.dir.writeFile(.{ .sub_path = "install/ghostty-vt.dll", .data = "old vt" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/theme.txt", .data = "old share" });
    try tmp.dir.writeFile(.{ .sub_path = "install/user-data.txt", .data = "keep" });
    try tmp.dir.writeFile(.{ .sub_path = "install/ghostty-vt.dll.txt", .data = "keep too" });
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.portable", .data = "" });
    try writeTestPayload(tmp.dir, "payload", &retired_entries);

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const payload_root = try std.fs.path.join(alloc, &.{ root, "payload" });
    defer alloc.free(payload_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);
    const displaced_root = try std.fs.path.join(alloc, &.{ root, "displaced" });
    defer alloc.free(displaced_root);

    try prepareBackup(alloc, install_root, backup_root);
    try swapPayload(alloc, install_root, payload_root, backup_root, displaced_root);

    try std.testing.expectError(error.FileNotFound, tmp.dir.access("install/ghostty-vt.dll", .{}));
    const displaced = try tmp.dir.readFileAlloc(alloc, "displaced/ghostty-vt.dll", 16);
    defer alloc.free(displaced);
    try std.testing.expectEqualStrings("old vt", displaced);
    const swapped = try tmp.dir.readFileAlloc(alloc, "install/noctty.com", 32);
    defer alloc.free(swapped);
    try std.testing.expectEqualStrings("new noctty.com", swapped);
    for ([_][2][]const u8{
        .{ "install/user-data.txt", "keep" },
        .{ "install/ghostty-vt.dll.txt", "keep too" },
        .{ "install/noctty.portable", "" },
    }) |kept| {
        const contents = try tmp.dir.readFileAlloc(alloc, kept[0], 16);
        defer alloc.free(contents);
        try std.testing.expectEqualStrings(kept[1], contents);
    }

    try rollback(alloc, install_root, backup_root, displaced_root);
    for ([_][2][]const u8{
        .{ "install/ghostty-vt.dll", "old vt" },
        .{ "install/noctty.com", "old com" },
        .{ "install/noctty.exe", "old exe" },
        .{ "install/user-data.txt", "keep" },
    }) |restored| {
        const contents = try tmp.dir.readFileAlloc(alloc, restored[0], 16);
        defer alloc.free(contents);
        try std.testing.expectEqualStrings(restored[1], contents);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("install/LICENSE", .{}));
}

test "portable rollback succeeds when the swap failed on a file held without delete sharing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install/share");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.exe", .data = "old exe" });
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old com" });
    try tmp.dir.writeFile(.{ .sub_path = "install/ghostty-vt.dll", .data = "old vt" });
    try tmp.dir.writeFile(.{ .sub_path = "install/share/theme.txt", .data = "old share" });
    try writeTestPayload(tmp.dir, "payload", &retired_entries);

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const payload_root = try std.fs.path.join(alloc, &.{ root, "payload" });
    defer alloc.free(payload_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);
    const displaced_root = try std.fs.path.join(alloc, &.{ root, "displaced" });
    defer alloc.free(displaced_root);
    const dll_path = try std.fs.path.join(alloc, &.{ install_root, "ghostty-vt.dll" });
    defer alloc.free(dll_path);

    // Another process reading the DLL without FILE_SHARE_DELETE: it can be
    // read and copied, but neither renamed nor replaced.
    const dll_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, dll_path);
    defer alloc.free(dll_w);
    const holder = std.os.windows.kernel32.CreateFileW(
        dll_w.ptr,
        std.os.windows.GENERIC_READ,
        std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE,
        null,
        std.os.windows.OPEN_EXISTING,
        std.os.windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    try std.testing.expect(holder != std.os.windows.INVALID_HANDLE_VALUE);
    defer std.os.windows.CloseHandle(holder);

    try prepareBackup(alloc, install_root, backup_root);
    // The swap replaced noctty.com, then could not move the held DLL aside.
    if (swapPayload(alloc, install_root, payload_root, backup_root, displaced_root)) |_| {
        return error.TestExpectedError;
    } else |_| {}
    const partial = try tmp.dir.readFileAlloc(alloc, "install/noctty.com", 32);
    defer alloc.free(partial);
    try std.testing.expectEqualStrings("new noctty.com", partial);

    // Rollback leaves the untouched, still held DLL alone and restores the
    // rest, so the helper goes on to relaunch the old build.
    try rollback(alloc, install_root, backup_root, displaced_root);
    for ([_][2][]const u8{
        .{ "install/noctty.com", "old com" },
        .{ "install/ghostty-vt.dll", "old vt" },
        .{ "install/noctty.exe", "old exe" },
        .{ "install/share/theme.txt", "old share" },
    }) |restored| {
        const contents = try tmp.dir.readFileAlloc(alloc, restored[0], 16);
        defer alloc.free(contents);
        try std.testing.expectEqualStrings(restored[1], contents);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("install/ghostty-vt.dll.restore", .{}));
}

test "portable swap of an install without the retired file, or a payload with it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.exe", .data = "old exe" });
    try writeTestPayload(tmp.dir, "without", &retired_entries);
    try writeTestPayload(tmp.dir, "with", &.{});

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const without_root = try std.fs.path.join(alloc, &.{ root, "without" });
    defer alloc.free(without_root);
    const with_root = try std.fs.path.join(alloc, &.{ root, "with" });
    defer alloc.free(with_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);
    const displaced_root = try std.fs.path.join(alloc, &.{ root, "displaced" });
    defer alloc.free(displaced_root);

    // Nothing to remove: the swap succeeds and creates nothing in its place.
    try prepareBackup(alloc, install_root, backup_root);
    try swapPayload(alloc, install_root, without_root, backup_root, displaced_root);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("install/ghostty-vt.dll", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("displaced/ghostty-vt.dll", .{}));
    try cleanupBackup(backup_root);

    // A payload that still ships it (the transition release) installs it.
    try prepareBackup(alloc, install_root, backup_root);
    try swapPayload(alloc, install_root, with_root, backup_root, displaced_root);
    const installed = try tmp.dir.readFileAlloc(alloc, "install/ghostty-vt.dll", 32);
    defer alloc.free(installed);
    try std.testing.expectEqualStrings("new ghostty-vt.dll", installed);
}

test "portable swap refuses a payload missing a required entry before replacing anything" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("install");
    try tmp.dir.writeFile(.{ .sub_path = "install/noctty.com", .data = "old com" });
    try tmp.dir.writeFile(.{ .sub_path = "install/ghostty-vt.dll", .data = "old vt" });
    // Missing noctty.exe, which the swap would reach last.
    try writeTestPayload(tmp.dir, "payload", &.{ "noctty.exe", "ghostty-vt.dll" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const install_root = try std.fs.path.join(alloc, &.{ root, "install" });
    defer alloc.free(install_root);
    const payload_root = try std.fs.path.join(alloc, &.{ root, "payload" });
    defer alloc.free(payload_root);
    const backup_root = try std.fs.path.join(alloc, &.{ root, "backup" });
    defer alloc.free(backup_root);
    const displaced_root = try std.fs.path.join(alloc, &.{ root, "displaced" });
    defer alloc.free(displaced_root);

    try prepareBackup(alloc, install_root, backup_root);
    try std.testing.expectError(
        error.IncompletePortablePayload,
        swapPayload(alloc, install_root, payload_root, backup_root, displaced_root),
    );
    for ([_][2][]const u8{
        .{ "install/noctty.com", "old com" },
        .{ "install/ghostty-vt.dll", "old vt" },
    }) |kept| {
        const contents = try tmp.dir.readFileAlloc(alloc, kept[0], 16);
        defer alloc.free(contents);
        try std.testing.expectEqualStrings(kept[1], contents);
    }
}

test "portable update rejects unsafe ZIP entry paths" {
    const testing = std.testing;
    try testing.expect(isSafeZipEntryPath("noctty/"));
    try testing.expect(isSafeZipEntryPath("noctty/share/ghostty/themes/a"));
    try testing.expect(!isSafeZipEntryPath("/noctty/noctty.exe"));
    try testing.expect(!isSafeZipEntryPath("C:/noctty/noctty.exe"));
    try testing.expect(!isSafeZipEntryPath("noctty/../../outside"));
    try testing.expect(!isSafeZipEntryPath("noctty\\noctty.exe"));
    try testing.expect(!isSafeZipEntryPath("other/noctty.exe"));
}
