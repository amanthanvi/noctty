//! The oracle inherits the app's actual module options and dependencies.
//! Nothing is installed or run by the default build through this step.
const std = @import("std");
const Api = enum { fork, stone, v140, v140_fork };

pub fn add(b: *std.Build, app: *std.Build.Step.Compile) !void {
    const step = b.step("oracle", "Build the differential terminal oracle (no capture)");
    const api = b.option(Api, "vt-api", "Terminal API shape: fork, stone, v140, v140_fork") orelse {
        step.dependOn(&b.addFail("oracle requires an explicit -Dvt-api").step);
        return;
    };
    const source = app.root_module;
    const core = b.createModule(.{
        .root_source_file = b.path("src/differential_oracle_terminal.zig"),
        .target = source.resolved_target,
        .optimize = source.optimize,
        .link_libc = source.link_libc,
        .link_libcpp = source.link_libcpp,
    });
    var imports = source.import_table.iterator();
    while (imports.next()) |entry| core.addImport(entry.key_ptr.*, entry.value_ptr.*);
    try core.include_dirs.appendSlice(b.allocator, source.include_dirs.items);
    try core.c_macros.appendSlice(b.allocator, source.c_macros.items);
    for (source.link_objects.items) |object| switch (object) {
        .win32_resource_file => {}, // app icon/GUI manifest is not a terminal option
        else => try core.link_objects.append(b.allocator, object),
    };
    const shape = b.addOptions();
    shape.addOption(Api, "api", api);
    const adapter = b.createModule(.{
        .root_source_file = b.path(switch (api) {
            .fork, .stone => "src/differential_oracle_adapter_legacy.zig",
            .v140, .v140_fork => "src/differential_oracle_adapter.zig",
        }),
        .target = source.resolved_target,
        .optimize = source.optimize,
    });
    adapter.addOptions("oracle_api", shape);
    adapter.addImport("ghostty-vt", core);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/differential_oracle.zig"),
        .target = source.resolved_target,
        .optimize = source.optimize,
    });
    mod.addImport("ghostty-vt", core);
    mod.addImport("oracle-adapter", adapter);
    const metadata = b.addOptions();
    const target = source.resolved_target.?.result;
    metadata.addOption([]const u8, "target", b.fmt("{s}-{s}-{s}", .{ @tagName(target.cpu.arch), @tagName(target.os.tag), @tagName(target.abi) }));
    metadata.addOption([]const u8, "cpu_model", target.cpu.model.name);
    var features: std.ArrayList([]const u8) = .empty;
    for (target.cpu.arch.allFeaturesList(), 0..) |feature, index| {
        if (target.cpu.features.isEnabled(@intCast(index))) try features.append(b.allocator, feature.name);
    }
    metadata.addOption([]const []const u8, "cpu_features", features.items);
    metadata.addOption([]const u8, "optimize", @tagName(source.optimize.?));
    mod.addOptions("oracle_build", metadata);
    const exe = b.addExecutable(.{ .name = "differential-oracle", .root_module = mod, .use_llvm = true });
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    if (b.option(bool, "oracle-corpus", "Build the pre-side synthetic generator") orelse false) {
        const generator = b.addExecutable(.{
            .name = "oracle-corpus",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/differential_oracle_corpus.zig"),
                .target = source.resolved_target,
                .optimize = source.optimize,
            }),
            .use_llvm = true,
        });
        step.dependOn(&b.addInstallArtifact(generator, .{}).step);
    }
}
