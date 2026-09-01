const Proxy = @This();

const std = @import("std");
const Config = @import("Config.zig");

const name = "noctty-terminal-handoff-proxy";
const source_root = "src/apprt/win32_terminal_handoff_proxy";

library: *std.Build.Step.Compile,
install_step: *std.Build.Step.InstallFile,

pub fn init(b: *std.Build, cfg: *const Config) !Proxy {
    const arch_dir = switch (cfg.target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return error.UnsupportedTerminalHandoffProxyArchitecture,
    };
    const generated_root = b.path(b.fmt("{s}/{s}", .{ source_root, arch_dir }));
    const module = b.createModule(.{
        .target = cfg.target,
        .optimize = cfg.optimize,
    });
    module.addIncludePath(generated_root);
    module.addCMacro("REGISTER_PROXY_DLL", "1");
    module.addCMacro("WIN32", "1");
    module.addCMacro(
        "PROXY_CLSID_IS",
        "{0x1d349824,0x21fb,0x46c7,{0xac,0xf3,0x74,0x6e,0xdc,0x99,0x1d,0x52}}",
    );
    module.addCSourceFiles(.{
        .root = generated_root,
        .files = &.{
            "dlldata.c",
            "ITerminalHandoff_i.c",
            "ITerminalHandoff_p.c",
        },
    });
    module.addCSourceFile(.{
        .file = b.path(source_root ++ "/exports.c"),
    });
    module.linkSystemLibrary("rpcrt4", .{});
    module.linkSystemLibrary("ole32", .{});
    module.linkSystemLibrary("oleaut32", .{});

    const library = b.addLibrary(.{
        .name = name,
        .root_module = module,
        .linkage = .dynamic,
        .use_llvm = true,
    });
    library.linkLibC();
    const install_step = b.addInstallBinFile(
        library.getEmittedBin(),
        name ++ ".dll",
    );
    return .{ .library = library, .install_step = install_step };
}

pub fn install(self: *const Proxy) void {
    const b = self.install_step.step.owner;
    b.getInstallStep().dependOn(&self.install_step.step);
}
