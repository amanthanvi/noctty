const std = @import("std");

pub fn build(b: *std.Build) void {
    // Match the Windows-only fork's default ABI in the consuming executable
    // too. Zig otherwise defaults to GNU while ghostty-vt defaults to MSVC.
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .msvc } });
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("ghostty", .{ .simd = false, .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = dep.path("src/differential_oracle.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    b.installArtifact(b.addExecutable(.{
        .name = "differential-oracle",
        .root_module = mod,
        .use_llvm = true,
    }));

    // Generate once with the pre-side compiler; reuse these exact bytes on
    // every tree. Generator/PRNG changes must not change later input sets.
    if (b.option(bool, "corpus", "Build the Zig 0.15 synthetic corpus generator") orelse false) {
        const generator = b.addExecutable(.{
            .name = "oracle-corpus",
            .root_module = b.createModule(.{
                .root_source_file = dep.path("src/differential_oracle_corpus.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(generator);
    }
}
