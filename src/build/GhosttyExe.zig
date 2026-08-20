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

pub fn init(b: *std.Build, cfg: *const Config, deps: *const SharedDeps) !Ghostty {
    const exe: *std.Build.Step.Compile = b.addExecutable(.{
        .name = "noctty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = cfg.target,
            .optimize = cfg.optimize,
            .strip = cfg.strip,
            .omit_frame_pointer = cfg.strip,
            .unwind_tables = if (cfg.strip) .none else .sync,
        }),
        // Crashes on x86_64 self-hosted on 0.15.1
        .use_llvm = true,
    });
    const install_step = b.addInstallArtifact(exe, .{});
    var command_exe: ?*std.Build.Step.Compile = null;
    var command_install_step: ?*std.Build.Step.InstallFile = null;

    // Set PIE if requested
    if (cfg.pie) exe.pie = true;

    // The app executable always needs the shared dependency wiring,
    // including build_options and generated imports.
    _ = try deps.add(exe);

    // OS-specific
    switch (cfg.target.result.os.tag) {
        .windows => {
            exe.subsystem = .Windows;
            exe.addWin32ResourceFile(.{
                .file = b.path("dist/windows/noctty.rc"),
                .flags = &.{try win32IconResourceStamp(b)},
            });

            const command = b.addExecutable(.{
                .name = "noctty-command",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main_noctty_command.zig"),
                    .target = cfg.target,
                    .optimize = cfg.optimize,
                    .strip = cfg.strip,
                    .omit_frame_pointer = cfg.strip,
                    .unwind_tables = if (cfg.strip) .none else .sync,
                }),
                .use_llvm = true,
            });
            command.subsystem = .Console;
            _ = try deps.add(command);
            command_exe = command;
            command_install_step = b.addInstallBinFile(command.getEmittedBin(), "noctty.com");
        },

        else => {},
    }

    return .{
        .exe = exe,
        .install_step = install_step,
        .command_exe = command_exe,
        .command_install_step = command_install_step,
    };
}

/// Add the noctty exe to the install target.
pub fn install(self: *const Ghostty) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
    if (self.command_install_step) |step| b.getInstallStep().dependOn(&step.step);
}

fn win32IconResourceStamp(b: *std.Build) ![]const u8 {
    const icon_bytes = try std.fs.cwd().readFileAlloc(
        b.allocator,
        "dist/windows/noctty.ico",
        1024 * 1024,
    );
    defer b.allocator.free(icon_bytes);

    return try std.fmt.allocPrint(
        b.allocator,
        "/DNOCTTY_ICON_HASH_{x}",
        .{std.hash.Wyhash.hash(0, icon_bytes)},
    );
}
