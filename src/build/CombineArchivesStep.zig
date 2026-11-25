//! Combines multiple static archives into a single fat archive with a
//! cross-platform MRI-script build tool. Upstream also uses libtool on
//! Darwin; noctty builds no Apple targets, so that path and LibtoolStep.zig
//! are stripped (PLAN.md r46a §2.5's 1A exception, the "strip" option).
const std = @import("std");

/// Combine multiple static archives into a single fat archive.
///
/// `name` identifies the library (e.g. "ghostty-internal", "ghostty-vt").
/// Output uses a `-fat` suffix to distinguish the combined archive from
/// the single-library archive in the build cache.
pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    sources: []const std.Build.LazyPath,
) struct { step: *std.Build.Step, output: std.Build.LazyPath } {
    // A build tool that generates an MRI script and pipes it to
    // `zig ar -M`. This works on all platforms including Windows (the
    // previous /bin/sh approach did not).
    const tool = b.addExecutable(.{
        .name = "combine_archives",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/combine_archives.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addArg(b.graph.zig_exe);
    const out_name = if (target.result.os.tag == .windows)
        b.fmt("{s}-fat.lib", .{name})
    else
        b.fmt("lib{s}-fat.a", .{name});
    const output = run.addOutputFileArg(out_name);
    for (sources) |source| run.addFileArg(source);

    return .{ .step = &run.step, .output = output };
}
