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
//!
//! Zig 0.17's build graph has no custom steps, so the check is this file's
//! `main`, built for the host and run by the install step.
const std = @import("std");
const builtin = @import("builtin");
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
    const tool = b.addExecutable(.{
        .name = "stage-bundled-conpty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/ConptyRedist.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.setName("stage bundled ConPTY");
    // It reads and writes the install directory, so it runs every build.
    run.has_side_effects = true;
    run.stdio = .inherit;
    run.addFileArg(b.path(pin_path));
    run.addFileArg(b.path(stage_script));
    run.addArg(@tagName(arch));
    run.addDirectoryArg(b.graph.path(.install_bin, ""));
    run.addDirectoryArg(b.graph.path(.global_cache, ""));
    run.addArg(if (b.graph.system_package_mode) "system" else "fetch");
    b.getInstallStep().dependOn(&run.step);
}

/// The host tool: `stage-bundled-conpty <pin> <stage script> <x64|arm64>
/// <bin dir> <global cache> <system|fetch>`. Exits 0 when the pinned pair is
/// installed, or when it could not be fetched (after a warning, and after
/// removing any pair the pin does not vouch for), and 1 on a mismatch or a
/// helper failure.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) fail(
        "usage: stage-bundled-conpty <pin> <stage script> <x64|arm64> <bin dir> <global cache> <system|fetch>",
        .{},
    );
    const pin_file = args[1];
    const script = args[2];
    const arch = std.meta.stringToEnum(Arch, args[3]) orelse
        fail("unknown architecture '{s}'", .{args[3]});
    const bin_path = args[4];
    const cache_root = try std.Io.Dir.path.join(arena, &.{ args[5], "noctty-conpty" });
    const system_package_mode = std.mem.eql(u8, args[6], "system");

    // readFileAlloc refuses a file that reaches its limit; + 1 accepts exactly 64 KiB, as 0.15 did.
    const pin_text = std.Io.Dir.cwd().readFileAlloc(io, pin_file, arena, .limited(64 * 1024 + 1)) catch |err|
        fail("unable to read {s}: {t}", .{ pin_path, err });
    const pin = std.json.parseFromSliceLeaky(Pin, arena, pin_text, .{
        .ignore_unknown_fields = true,
    }) catch |err| fail("unable to parse {s}: {t}", .{ pin_path, err });
    const pair = switch (arch) {
        .x64 => pin.architectures.x64,
        .arm64 => pin.architectures.arm64,
    };
    const staged = [_]Staged{
        .{ .name = "conpty.dll", .sha256 = pair.conptyDll.sha256 },
        .{ .name = "OpenConsole.exe", .sha256 = pair.openConsoleExe.sha256 },
    };

    var bin = std.Io.Dir.cwd().createDirPathOpen(io, bin_path, .{}) catch |err|
        fail("unable to open '{s}': {t}", .{ bin_path, err });
    defer bin.close(io);

    if (installedMatches(io, arena, bin, &staged)) return;

    // The helper's own account of a failed download, shown after the warning.
    var detail: []const u8 = "";
    const reason: []const u8 = reason: {
        if (system_package_mode) break :reason "downloads are disabled by --system";

        // A PowerShell 7 parent puts its own modules first in PSModulePath,
        // and Windows PowerShell then loads them instead of its own, losing
        // Get-FileHash. Each PowerShell rebuilds the variable when unset.
        var env = try init.environ_map.clone(arena);
        _ = env.swapRemove("PSModulePath");
        const powershell = if (builtin.os.tag == .windows)
            try std.fmt.allocPrint(arena, "{s}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .{
                env.get("SystemRoot") orelse "C:\\Windows",
            })
        else
            "pwsh";
        const result = std.process.run(arena, io, .{
            .environ_map = &env,
            .argv = &.{
                powershell,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                script,
                "-Architecture",
                @tagName(arch),
                "-Destination",
                bin_path,
                "-CacheRoot",
                cache_root,
            },
        }) catch |err| switch (err) {
            error.FileNotFound => break :reason try std.fmt.allocPrint(arena, "{s} is not installed", .{powershell}),
            else => fail("unable to run {s}: {t}; " ++ opt_out, .{ stage_script, err }),
        };
        switch (result.term) {
            .exited => |code| switch (code) {
                0 => {
                    if (installedMatches(io, arena, bin, &staged)) return;
                    fail("{s} reported success, but the pair in '{s}' does not match {s}", .{
                        stage_script, bin_path, pin_path,
                    });
                },
                exit_not_downloaded => {
                    detail = try std.fmt.allocPrint(arena, "{s}{s}", .{ result.stdout, result.stderr });
                    break :reason "the package could not be fetched";
                },
                else => {},
            },
            else => {},
        }
        fail("{s} failed ({any}); " ++ opt_out ++ ":\n{s}{s}", .{
            stage_script, result.term, result.stdout, result.stderr,
        });
    };

    // Leave nothing installed that the pin does not vouch for, so the
    // runtime's fallback matches this warning.
    for (staged) |file| {
        bin.deleteFile(io, file.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => fail("unable to remove '{s}' from '{s}', which does not match {s}: {t}", .{
                file.name, bin_path, pin_path, err,
            }),
        };
    }
    std.debug.print(
        \\warning: the bundled ConPTY was not staged because {s}.
        \\noctty in '{s}' will fall back to Windows' in-box conhost, which re-renders
        \\output, drops OSC 4/10/11/12 and XTGETTCAP replies, and may strip Kitty
        \\graphics and Sixel. Once that is fixed, build again to stage conpty.dll and
        \\OpenConsole.exe from {s}, or pass -Dbundled-conpty=false to stop trying.
        \\{s}
        \\
    , .{ reason, bin_path, pin.nupkg.url, detail });
}

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
}

const Staged = struct {
    name: []const u8,
    sha256: []const u8,
};

/// Whether every staged file is installed with its pinned SHA-256. The pins
/// are per architecture, so a match also fixes the PE machine, which
/// Install-ConPtyRedist checked when it staged the file.
fn installedMatches(io: std.Io, arena: std.mem.Allocator, bin: std.Io.Dir, staged: []const Staged) bool {
    for (staged) |file| {
        // + 1: a file of exactly max_file_bytes is read, as 0.15 did.
        const bytes = bin.readFileAlloc(io, file.name, arena, .limited(max_file_bytes + 1)) catch return false;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), file.sha256)) return false;
    }
    return true;
}
