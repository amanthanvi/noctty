//! Stages Microsoft's bundled ConPTY pair, `conpty.dll` and
//! `OpenConsole.exe`, beside the installed executable.
//!
//! Without the pair, src/pty.zig falls back to Windows' in-box conhost, which
//! re-renders output, answers device queries itself and drops the colour
//! queries. Release packaging stages the pair with `Install-ConPtyRedist` from
//! scripts/conpty-redist.ps1; this step runs the same function through
//! scripts/stage-conpty-redist.ps1, so `zig build` and `zig build run` get the
//! bytes a release ships and take the terminal path a release takes.
//!
//! Every build re-hashes the installed pair against the pin, which takes a
//! few milliseconds, and runs Windows PowerShell only when the pair is missing
//! or stale. (The build runner has TLS compiled out and `zig fetch` rejects a
//! `.nupkg`, so the download needs a child process.) The helper keeps the
//! verified package in the Zig global cache. A package or file that does not
//! match the pin fails the build. A download that cannot happen (no network,
//! `zig build --system`, no PowerShell) is tolerated: the step warns, removes
//! any installed pair the pin does not vouch for, and the build continues on
//! the in-box conhost. `-Dbundled-conpty=false` skips this step.
const ConptyRedist = @This();

const std = @import("std");
const builtin = @import("builtin");
const Step = std.Build.Step;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Shared with scripts/conpty-redist.ps1 and src/update/conpty_redist.zig.
const pin_path = "dist/windows/conpty-redist.json";
const stage_script = "scripts/stage-conpty-redist.ps1";

/// The exit code the stage script uses for "could not download".
const exit_not_downloaded = 3;

/// For environments that cannot run the helper or reach the package at all.
const opt_out = "pass -Dbundled-conpty=false to build without the bundled ConPTY";

/// Both files are about 1 MB; anything far larger is not the pinned payload.
const max_file_bytes = 16 * 1024 * 1024;

step: Step,
arch: Arch,

const Arch = enum { x64, arm64 };

/// The parts of the pin document this step checks the installed pair
/// against. Install-ConPtyRedist validates the rest before staging.
const Pin = struct {
    nupkg: struct { url: []const u8 },
    architectures: struct { x64: Pair, arm64: Pair },

    const Pair = struct { conptyDll: Entry, openConsoleExe: Entry };
    const Entry = struct { sha256: []const u8 };
};

/// Stage the pair for a Windows x64 or ARM64 target; other targets have no
/// pinned pair and get nothing.
pub fn install(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const arch: Arch = switch (target.result.cpu.arch) {
        .x86_64 => .x64,
        .aarch64 => .arm64,
        else => return,
    };
    const self = b.allocator.create(ConptyRedist) catch @panic("OOM");
    self.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "stage bundled ConPTY",
            .owner = b,
            .makeFn = make,
        }),
        .arch = arch,
    };
    b.getInstallStep().dependOn(&self.step);
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const self: *ConptyRedist = @fieldParentPtr("step", step);
    const arena = b.allocator;

    const pin_text = b.build_root.handle.readFileAlloc(arena, pin_path, 64 * 1024) catch |err|
        return step.fail("unable to read {s}: {s}", .{ pin_path, @errorName(err) });
    const pin = std.json.parseFromSliceLeaky(Pin, arena, pin_text, .{
        .ignore_unknown_fields = true,
    }) catch |err| return step.fail("unable to parse {s}: {s}", .{ pin_path, @errorName(err) });
    const pair = switch (self.arch) {
        .x64 => pin.architectures.x64,
        .arm64 => pin.architectures.arm64,
    };
    const staged = [_]Staged{
        .{ .name = "conpty.dll", .sha256 = pair.conptyDll.sha256 },
        .{ .name = "OpenConsole.exe", .sha256 = pair.openConsoleExe.sha256 },
    };

    const bin_path = b.getInstallPath(.bin, "");
    var bin = std.fs.cwd().makeOpenPath(bin_path, .{}) catch |err|
        return step.fail("unable to open '{s}': {s}", .{ bin_path, @errorName(err) });
    defer bin.close();

    if (installedMatches(arena, bin, &staged)) return;

    // The helper's own account of a failed download, shown after the warning.
    var detail: []const u8 = "";
    const reason: []const u8 = reason: {
        if (b.graph.system_package_mode) break :reason "downloads are disabled by --system";

        // A PowerShell 7 parent puts its own modules first in PSModulePath,
        // and Windows PowerShell then loads them instead of its own, losing
        // Get-FileHash. Each PowerShell rebuilds the variable when unset.
        var env = std.process.getEnvMap(arena) catch |err|
            return step.fail("unable to read the environment: {s}", .{@errorName(err)});
        env.remove("PSModulePath");
        const powershell = if (builtin.os.tag == .windows)
            b.fmt("{s}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .{
                env.get("SystemRoot") orelse "C:\\Windows",
            })
        else
            "pwsh";
        const cache_root = b.graph.global_cache_root.join(arena, &.{"noctty-conpty"}) catch @panic("OOM");
        const result = std.process.Child.run(.{
            .allocator = arena,
            .env_map = &env,
            .argv = &.{
                powershell,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                b.pathFromRoot(stage_script),
                "-Architecture",
                @tagName(self.arch),
                "-Destination",
                bin_path,
                "-CacheRoot",
                cache_root,
            },
        }) catch |err| switch (err) {
            error.FileNotFound => break :reason b.fmt("{s} is not installed", .{powershell}),
            else => return step.fail("unable to run {s}: {s}; " ++ opt_out, .{ stage_script, @errorName(err) }),
        };
        switch (result.term) {
            .Exited => |code| switch (code) {
                0 => {
                    if (installedMatches(arena, bin, &staged)) return;
                    return step.fail("{s} reported success, but the pair in '{s}' does not match {s}", .{
                        stage_script, bin_path, pin_path,
                    });
                },
                exit_not_downloaded => {
                    detail = b.fmt("{s}{s}", .{ result.stdout, result.stderr });
                    break :reason "the package could not be fetched";
                },
                else => {},
            },
            else => {},
        }
        return step.fail("{s} failed ({any}); " ++ opt_out ++ ":\n{s}{s}", .{
            stage_script, result.term, result.stdout, result.stderr,
        });
    };

    // Leave nothing installed that the pin does not vouch for, so the
    // runtime's fallback matches this warning.
    for (staged) |file| {
        bin.deleteFile(file.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return step.fail("unable to remove '{s}' from '{s}', which does not match {s}: {s}", .{
                file.name, bin_path, pin_path, @errorName(err),
            }),
        };
    }
    step.result_stderr = b.fmt(
        \\warning: the bundled ConPTY was not staged because {s}.
        \\noctty in '{s}' will fall back to Windows' in-box conhost, which re-renders
        \\output, drops OSC 4/10/11/12 and XTGETTCAP replies, and may strip Kitty
        \\graphics and Sixel. Once that is fixed, build again to stage conpty.dll and
        \\OpenConsole.exe from {s}, or pass -Dbundled-conpty=false to stop trying.
        \\{s}
    , .{ reason, bin_path, pin.nupkg.url, detail });
}

const Staged = struct {
    name: []const u8,
    sha256: []const u8,
};

/// Whether every staged file is installed with its pinned SHA-256. The pins
/// are per architecture, so a match also fixes the PE machine, which
/// Install-ConPtyRedist checked when it staged the file.
fn installedMatches(arena: std.mem.Allocator, bin: std.fs.Dir, staged: []const Staged) bool {
    for (staged) |file| {
        const bytes = bin.readFileAlloc(arena, file.name, max_file_bytes) catch return false;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), file.sha256)) return false;
    }
    return true;
}
