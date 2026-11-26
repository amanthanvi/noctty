const Ghostty = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");

/// The primary noctty executable.
exe: *std.Build.Step.Compile,

/// The install step for the executable.
install_step: *std.Build.Step.InstallArtifact,

/// Console launcher that shells resolve before noctty.exe.
command_exe: ?*std.Build.Step.Compile = null,
command_install_step: ?*std.Build.Step.InstallFile = null,
command_pdb_install_step: ?*std.Build.Step.InstallFile = null,

/// `noctty.ico` next to the exe. The AUMID registration points the toast
/// `IconUri` at it (src/apprt/win32_aumid.zig), and the packaging script
/// stages the same file in the portable/installer layout, so a dev tree
/// gets the same toast icon as a release install.
icon_install_step: ?*std.Build.Step.InstallFile = null,

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "noctty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.omit_frame_pointer,
            // Kept when stripped. On x64 Windows these are the .pdata/.xdata
            // records a debugger unwinds with; a function without one is
            // taken for a leaf, so a minidump's stacks stop making sense at
            // the first noctty frame (#299). Measured on ReleaseFast:
            // +132,096 bytes (0.5%) on noctty.exe.
            .unwind_tables = .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});
    var command_exe: ?*std.Build.Step.Compile = null;
    var command_install_step: ?*std.Build.Step.InstallFile = null;
    var command_pdb_install_step: ?*std.Build.Step.InstallFile = null;
    var icon_install_step: ?*std.Build.Step.InstallFile = null;

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // The app executable always needs the shared dependency wiring,
    // including build_options and generated imports.
    _ = try deps.add(exe);

    // OS-specific
    switch (cfg.target.result.os.tag) {
        .windows => {
            exe.subsystem = .windows;
            try addWindowsResource(b, cfg, exe);

            const command = b.addExecutable(.{
                .name = "noctty-command",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main_noctty_command.zig"),
                    .target = cfg.target,
                    .optimize = cfg.optimize,
                    .strip = cfg.strip,
                    .omit_frame_pointer = cfg.omit_frame_pointer,
                    .unwind_tables = .sync,
                }),
                .use_llvm = true,
            });
            command.subsystem = .console;
            command_exe = command;
            command_install_step = b.addInstallBinFile(command.getEmittedBin(), "noctty.com");
            // The compiled name is noctty-command, so noctty.com's CodeView
            // record asks for noctty-command.pdb. Installing the exe alone
            // would leave that PDB in the build cache.
            if (command.producesPdbFile()) {
                command_pdb_install_step = b.addInstallBinFile(command.getEmittedPdb(), "noctty-command.pdb");
            }
            icon_install_step = b.addInstallBinFile(b.path("dist/windows/noctty.ico"), "noctty.ico");
        },

        else => {},
    }

    return .{
        .exe = exe,
        .install_step = install_step,
        .command_exe = command_exe,
        .command_install_step = command_install_step,
        .command_pdb_install_step = command_pdb_install_step,
        .icon_install_step = icon_install_step,
    };
}

/// Add the noctty exe to the install target.
pub fn install(self: *const Ghostty) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
    if (self.command_install_step) |step| b.getInstallStep().dependOn(&step.step);
    if (self.command_pdb_install_step) |step| b.getInstallStep().dependOn(&step.step);
    if (self.icon_install_step) |step| b.getInstallStep().dependOn(&step.step);
}

/// Attach `noctty.rc` (icon, manifest, version) to a Windows executable. The
/// defines are part of Zig's resource cache key, so a version change rebuilds
/// the resource. The updater's test fixture uses this too, so it exercises the
/// same flags as the shipped exe.
pub fn addWindowsResource(
    b: *std.Build,
    cfg: *const Config,
    compile: *std.Build.Step.Compile,
) !void {
    // VS_FIXEDFILEINFO stores four 16-bit components. Never silently
    // truncate a SemVer component that the downgrade guard compares.
    if (cfg.version.major > std.math.maxInt(u16) or
        cfg.version.minor > std.math.maxInt(u16) or
        cfg.version.patch > std.math.maxInt(u16)) return error.WindowsVersionComponentOutOfRange;
    compile.root_module.addWin32ResourceFile(.{
        .file = b.path("dist/windows/noctty.rc"),
        .flags = &.{
            try win32IconResourceStamp(b),
            b.fmt("/DNOCTTY_VERSION_MAJOR={d}", .{cfg.version.major}),
            b.fmt("/DNOCTTY_VERSION_MINOR={d}", .{cfg.version.minor}),
            b.fmt("/DNOCTTY_VERSION_PATCH={d}", .{cfg.version.patch}),
            b.fmt("/DNOCTTY_VERSION_STRING=\"{f}\"", .{cfg.version}),
        },
    });
}

fn win32IconResourceStamp(b: *std.Build) ![]const u8 {
    // Zig 0.17 caches the configure step itself: register the icon, or a
    // changed icon would reuse the old stamp.
    b.dependOnFileContents(b.path("dist/windows/noctty.ico"));
    const icon_bytes = try b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        "dist/windows/noctty.ico",
        b.allocator,
        .limited(1024 * 1024),
    );
    defer b.allocator.free(icon_bytes);

    return try std.fmt.allocPrint(
        b.allocator,
        "/DNOCTTY_ICON_HASH_{x}",
        .{std.hash.Wyhash.hash(0, icon_bytes)},
    );
}
