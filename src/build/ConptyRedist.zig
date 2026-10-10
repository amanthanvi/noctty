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
//! few milliseconds, and runs PowerShell only when the pair is missing or
//! stale. The helper keeps the verified package in the Zig global cache. A
//! package or file that does not match the pin fails the build. Only a failed
//! download (offline, or `zig build --system`) is tolerated: the step warns,
//! removes any installed pair the pin does not vouch for, and the build
//! continues on the in-box conhost.
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

/// Both files are about 1 MB; anything far larger is not the pinned payload.
const max_file_bytes = 16 * 1024 * 1024;

step: Step,
arch: Arch,

const Arch = enum {
    x64,
    arm64,

    fn machine(self: Arch) u16 {
        return switch (self) {
            .x64 => 0x8664,
            .arm64 => 0xaa64,
        };
    }
};

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

    if (installedMatches(arena, bin, &staged, self.arch)) return;

    // The helper's own account of a failed download, shown after the warning.
    var detail: []const u8 = "";
    const reason: []const u8 = reason: {
        if (b.graph.system_package_mode) break :reason "downloads are disabled by --system";
        const cache_root = b.graph.global_cache_root.join(arena, &.{"noctty-conpty"}) catch @panic("OOM");
        const result = std.process.Child.run(.{
            .allocator = arena,
            .argv = &.{
                if (builtin.os.tag == .windows) "powershell.exe" else "pwsh",
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
        }) catch |err| break :reason b.fmt("PowerShell could not be started: {s}", .{@errorName(err)});
        switch (result.term) {
            .Exited => |code| switch (code) {
                0 => {
                    if (installedMatches(arena, bin, &staged, self.arch)) return;
                    return step.fail("{s} reported success, but the pair in '{s}' does not match {s}", .{
                        stage_script, bin_path, pin_path,
                    });
                },
                exit_not_downloaded => {
                    detail = b.fmt("{s}{s}", .{ result.stdout, result.stderr });
                    break :reason "the download failed";
                },
                else => {},
            },
            else => {},
        }
        return step.fail("{s} failed ({any}):\n{s}{s}", .{
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
        \\graphics and Sixel. Build again with network access to stage conpty.dll and
        \\OpenConsole.exe from {s}.
        \\{s}
    , .{ reason, bin_path, pin.nupkg.url, detail });
}

const Staged = struct {
    name: []const u8,
    sha256: []const u8,
};

/// Whether every staged file is installed with its pinned SHA-256 and the
/// target's PE machine, the checks Install-ConPtyRedist applies.
fn installedMatches(arena: std.mem.Allocator, bin: std.fs.Dir, staged: []const Staged, arch: Arch) bool {
    for (staged) |file| {
        const bytes = bin.readFileAlloc(arena, file.name, max_file_bytes) catch return false;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &digest, .{});
        if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), file.sha256)) return false;
        if (peMachine(bytes) != arch.machine()) return false;
    }
    return true;
}

fn peMachine(bytes: []const u8) ?u16 {
    if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..2], "MZ")) return null;
    const pe = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (pe > bytes.len or bytes.len - pe < 6) return null;
    if (!std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return null;
    return std.mem.readInt(u16, bytes[pe + 4 ..][0..2], .little);
}
