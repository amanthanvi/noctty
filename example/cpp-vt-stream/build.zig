const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the app");

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    // MSVC 14.52's STL rejects Clang older than 22 (STL1000); Zig 0.15.2
    // bundles Clang 20. The define only silences that version check.
    const cpp_flags: []const []const u8 = if (target.result.abi == .msvc)
        &.{"-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH"}
    else
        &.{};
    exe_mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"main.cpp"},
        .flags = cpp_flags,
    });

    // You'll want to use a lazy dependency here so that ghostty is only
    // downloaded if you actually need it.
    if (b.lazyDependency("ghostty", .{
        // Setting simd to false will force a pure static build that
        // doesn't even require libc, but it has a significant performance
        // penalty. If your embedding app requires libc anyway, you should
        // always keep simd enabled.
        // .simd = false,
    })) |dep| {
        exe_mod.linkLibrary(dep.artifact("ghostty-vt"));
    }

    // Exe
    const exe = b.addExecutable(.{
        .name = "cpp_vt_stream",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
