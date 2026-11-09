//! The ghostty-vt.dll placeholder the portable ZIP carries in place of the
//! retired libghostty-vt 0.1.0 library (see `ghostty_vt_stub.c`). Built with
//! the Windows exe and installed to `zig-out\bin\ghostty-vt-stub\`, beside its
//! PDB, so it never meets the `-Demit-lib-vt=true` library, which installs
//! the same file name to `zig-out\bin`.
const Stub = @This();

const std = @import("std");
const Config = @import("Config.zig");

/// The file name of the DLL and the base name of its PDB. The DLL's CodeView
/// record names `ghostty-vt.pdb`, which the symbols ZIP carries.
const name = "ghostty-vt";
const source_root = "src/ghostty_vt_stub";
/// Under zig-out\bin. scripts/package-windows.ps1 and
/// scripts/build-package-windows.ps1 stage `<install_dir>\ghostty-vt.dll`.
pub const install_dir = "ghostty-vt-stub";

dll_install_step: *std.Build.Step.InstallFile,
pdb_install_step: ?*std.Build.Step.InstallFile,

pub fn init(b: *std.Build, cfg: *const Config) !Stub {
    switch (cfg.target.result.cpu.arch) {
        .x86_64, .aarch64 => {},
        else => return error.UnsupportedGhosttyVtStubArchitecture,
    }
    // VS_FIXEDFILEINFO stores four 16-bit components.
    if (cfg.version.major > std.math.maxInt(u16) or
        cfg.version.minor > std.math.maxInt(u16) or
        cfg.version.patch > std.math.maxInt(u16)) return error.WindowsVersionComponentOutOfRange;

    const module = b.createModule(.{
        .target = cfg.target,
        .optimize = cfg.optimize,
        .strip = cfg.strip,
        // No C runtime: DllMain is the entry point, and the DLL imports
        // nothing.
        .link_libc = false,
    });
    // Not read by the source. build.zig links a release that keeps its PDB
    // with /OPT:REF through the environment, which Zig's cache key ignores:
    // this macro stops a DLL linked without the flag from being reused (as
    // for the handoff proxy).
    module.addCMacro("NOCTTY_RELEASE_SYMBOLS", if (cfg.release_symbols) "1" else "0");
    module.addCSourceFile(.{ .file = b.path(source_root ++ "/ghostty_vt_stub.c") });
    module.addWin32ResourceFile(.{
        .file = b.path(source_root ++ "/ghostty_vt_stub.rc"),
        .flags = &.{
            b.fmt("/DNOCTTY_VERSION_MAJOR={d}", .{cfg.version.major}),
            b.fmt("/DNOCTTY_VERSION_MINOR={d}", .{cfg.version.minor}),
            b.fmt("/DNOCTTY_VERSION_PATCH={d}", .{cfg.version.patch}),
            b.fmt("/DNOCTTY_VERSION_STRING=\"{f}\"", .{cfg.version}),
        },
    });

    const library = b.addLibrary(.{
        .name = name,
        .root_module = module,
        .linkage = .dynamic,
        .use_llvm = true,
    });
    library.entry = .{ .symbol_name = "DllMain" };

    const dll_install_step = b.addInstallFileWithDir(
        library.getEmittedBin(),
        .{ .custom = "bin/" ++ install_dir },
        name ++ ".dll",
    );
    // Installed as a bare file, so the PDB its CodeView record names has to
    // be installed explicitly.
    const pdb_install_step: ?*std.Build.Step.InstallFile = if (library.producesPdbFile())
        b.addInstallFileWithDir(
            library.getEmittedPdb(),
            .{ .custom = "bin/" ++ install_dir },
            name ++ ".pdb",
        )
    else
        null;
    return .{ .dll_install_step = dll_install_step, .pdb_install_step = pdb_install_step };
}

pub fn install(self: *const Stub) void {
    const b = self.dll_install_step.step.owner;
    b.getInstallStep().dependOn(&self.dll_install_step.step);
    if (self.pdb_install_step) |step| b.getInstallStep().dependOn(&step.step);
}
