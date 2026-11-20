//! The oracle inherits app dependencies, or upstream's public lib-vt module.
//! Nothing is installed or run by the default build through this step.
const std = @import("std");
const Api = enum { fork, stone, stone_flag, v140, v140_fork };
const Configuration = struct {
    zig_exe_sha256: ?[]const u8 = null,
    system_requested: ?[]const u8 = null,
};

/// Check oracle invocations before Config executes Git or configures dependencies.
pub fn configure(b: *std.Build) !Configuration {
    var config: Configuration = .{};
    if (b.user_input_options.contains("vt-api")) {
        _ = b.run(&.{ "python", "-I", "test/differential-oracle/build_args.py", b.graph.zig_exe });
        // Maker may otherwise reuse configuration from another invocation.
        if (@hasDecl(@TypeOf(b.graph.*), "poisonCache")) b.graph.poisonCache();
        try sanitizeGitEnvironment(b);
        config.zig_exe_sha256 = std.mem.trim(u8, b.run(&.{
            "python", "-I", "test/differential-oracle/identity.py", "--configure", b.graph.zig_exe,
        }), " \r\n");
    }
    // Snapshot command-line integrations before Config applies package defaults.
    if (b.graph.system_package_mode) {
        config.system_requested = "--system";
        return config;
    }
    const integrations = if (@hasField(@TypeOf(b.graph.*), "system_integration_options"))
        &b.graph.system_integration_options
    else
        &b.graph.system_library_options;
    for (integrations.values()) |mode| {
        if (mode == .user_enabled or mode == .declared_enabled) {
            config.system_requested = "-fsys";
            break;
        }
    }
    return config;
}

fn sanitizeGitEnvironment(b: *std.Build) !void {
    const modern = @hasField(@TypeOf(b.graph.*), "environ_map");
    const env = if (modern) &b.graph.environ_map else &b.graph.env_map;
    var names: std.ArrayList([]const u8) = .empty;
    var entries = env.iterator();
    while (entries.next()) |entry| {
        if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, "GIT_"))
            try names.append(b.allocator, entry.key_ptr.*);
    }
    for (names.items) |name| {
        if (modern) {
            _ = env.swapRemove(name);
        } else {
            env.remove(name);
        }
    }
}

/// An oracle invocation is exclusive, so its private configuration can salt
/// the shared app modules in place without touching any ordinary build.
fn saltCModules(
    module: *std.Build.Module,
    salt: []const u8,
    seen: *std.AutoHashMap(*std.Build.Module, void),
) !void {
    const visit = try seen.getOrPut(module);
    if (visit.found_existing) return;
    module.addCMacro("NOCTTY_DIFFERENTIAL_ORACLE", salt);
    for (module.import_table.values()) |child| try saltCModules(child, salt, seen);
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |compile| try saltCModules(compile.root_module, salt, seen),
        else => {},
    };
}

pub fn add(b: *std.Build, app: *std.Build.Step.Compile, config: Configuration) !void {
    try addInner(b, app.root_module, false, config);
}

pub fn addPublic(b: *std.Build, public: *std.Build.Module, config: Configuration) !void {
    try addInner(b, public, true, config);
}

fn addInner(b: *std.Build, source: *std.Build.Module, public: bool, config: Configuration) !void {
    const step = b.step("oracle", "Build the differential terminal oracle (no capture)");
    const api = b.option(Api, "vt-api", "Terminal API shape: fork, stone, stone_flag, v140, v140_fork") orelse {
        step.dependOn(&b.addFail("oracle requires an explicit -Dvt-api").step);
        return;
    };
    const corpus = b.option(bool, "oracle-corpus", "Build the pre-side synthetic generator") orelse false;
    if (config.system_requested) |option| {
        step.dependOn(&b.addFail(b.fmt("oracle build arguments: disallowed option: {s}", .{option})).step);
        return;
    }
    const compiler = std.mem.trim(u8, b.run(&.{ b.graph.zig_exe, "version" }), " \r\n");
    const modern = (try std.SemanticVersion.parse(compiler)).minor >= 17;
    if (modern and (api == .fork or api == .stone or api == .stone_flag or corpus)) {
        step.dependOn(&b.addFail("oracle: legacy API/generator selected on a modern compiler; at 1B.3/1B.5 delete both legacy files and change CI -Dvt-api=fork to v140_fork (or v140 for structured resize)").step);
        return;
    }
    const core = b.createModule(.{
        .root_source_file = b.path(if (public) "src/differential_oracle_public.zig" else "src/differential_oracle_terminal.zig"),
        .target = source.resolved_target,
        .optimize = source.optimize,
        .link_libc = source.link_libc,
        .link_libcpp = source.link_libcpp,
    });
    if (public) {
        core.addImport("public-vt", source);
        core.addImport("terminal_options", source.import_table.get("terminal_options").?);
    } else {
        var imports = source.import_table.iterator();
        while (imports.next()) |entry| core.addImport(entry.key_ptr.*, entry.value_ptr.*);
        try core.include_dirs.appendSlice(b.allocator, source.include_dirs.items);
        try core.c_macros.appendSlice(b.allocator, source.c_macros.items);
        for (source.link_objects.items) |object| switch (object) {
            .win32_resource_file => {}, // app icon/GUI manifest is not a terminal option
            else => try core.link_objects.append(b.allocator, object),
        };
    }
    var probe_flags: ?[]const []const u8 = null;
    for (source.link_objects.items) |object| switch (object) {
        .c_source_files => |files| for (files.files) |file| {
            if (std.mem.eql(u8, file, "src/simd/vt.cpp")) probe_flags = files.flags;
        },
        else => {},
    };
    if (probe_flags) |flags| (if (public) source else core).addCSourceFile(.{
        .file = b.path("src/differential_oracle_simd.cpp"),
        .flags = flags,
    });
    var salted = std.AutoHashMap(*std.Build.Module, void).init(b.allocator);
    defer salted.deinit();
    const compiler_sha256 = config.zig_exe_sha256.?;
    try saltCModules(core, b.fmt("\"{s}\"", .{compiler_sha256}), &salted);
    const shape = b.addOptions();
    shape.addOption(Api, "api", api);
    const adapter = b.createModule(.{
        .root_source_file = b.path(switch (api) {
            .fork, .stone, .stone_flag => "src/differential_oracle_adapter_legacy.zig",
            .v140, .v140_fork => "src/differential_oracle_adapter.zig",
        }),
        .target = source.resolved_target,
        .optimize = source.optimize,
    });
    adapter.addOptions("oracle_api", shape);
    const settings = b.addOptions();
    settings.addOption(usize, "scrollback_bytes", b.option(usize, "oracle-scrollback", "Oracle scrollback bytes (app default: 10000000)") orelse 10_000_000);
    adapter.addOptions("oracle_settings", settings);
    adapter.addImport("ghostty-vt", core);
    const mod = b.createModule(.{
        .root_source_file = b.path("src/differential_oracle.zig"),
        .target = source.resolved_target,
        .optimize = source.optimize,
    });
    mod.addImport("ghostty-vt", core);
    mod.addImport("oracle-adapter", adapter);
    const identity = b.addSystemCommand(&.{ "python", "-I" });
    identity.addFileArg(b.path("test/differential-oracle/identity.py"));
    identity.setCwd(b.path("."));
    // HEAD and cleanliness are not file inputs in the build cache.
    identity.has_side_effects = true;
    identity.addArg(compiler_sha256);
    if (@hasDecl(std.Build.LazyPath, "zig_lib")) {
        identity.addDirectoryArg(.zig_lib);
    } else {
        identity.addArg(b.graph.zig_lib_directory.path.?);
    }
    identity.addArgs(&.{ compiler, @tagName(api), if (public) "public-lib-vt" else "app" });
    var dependencies = b.graph.dependency_cache.iterator();
    while (dependencies.next()) |entry| {
        const dep = entry.value_ptr.*;
        identity.addArgs(&.{ "--dependency", dep.builder.pkg_hash });
        identity.addDirectoryArg(dep.path(""));
    }
    mod.addImport("oracle_identity", b.createModule(.{
        .root_source_file = identity.addOutputFileArg("oracle_identity.zig"),
        .target = source.resolved_target,
        .optimize = source.optimize,
    }));
    const metadata = b.addOptions();
    metadata.addOption([]const u8, "compiler_version", compiler);
    metadata.addOption([]const u8, "vt_api", @tagName(api));
    metadata.addOption([]const u8, "terminal_source", if (public) "public-lib-vt" else "app");
    metadata.addOption(bool, "simd_probe", probe_flags != null);
    const target = source.resolved_target.?.result;
    metadata.addOption([]const u8, "target", b.fmt("{s}-{s}-{s}", .{ @tagName(target.cpu.arch), @tagName(target.os.tag), @tagName(target.abi) }));
    metadata.addOption([]const u8, "cpu_model", target.cpu.model.name);
    var features: std.ArrayList([]const u8) = .empty;
    for (target.cpu.arch.allFeaturesList(), 0..) |feature, index| {
        if (target.cpu.features.isEnabled(@intCast(index))) try features.append(b.allocator, feature.name);
    }
    metadata.addOption([]const []const u8, "cpu_features", features.items);
    const baseline = b.resolveTargetQuery(.{ .cpu_arch = target.cpu.arch, .os_tag = target.os.tag, .abi = target.abi, .cpu_model = .baseline }).result.cpu;
    metadata.addOption([]const u8, "baseline_cpu_model", baseline.model.name);
    var baseline_features: std.ArrayList([]const u8) = .empty;
    for (baseline.arch.allFeaturesList(), 0..) |feature, index| {
        if (baseline.features.isEnabled(@intCast(index))) try baseline_features.append(b.allocator, feature.name);
    }
    metadata.addOption([]const []const u8, "baseline_cpu_features", baseline_features.items);
    // These names describe the same optimization levels on both API lines.
    const optimize = @tagName(source.optimize.?);
    metadata.addOption([]const u8, "optimize", if (std.mem.eql(u8, optimize, "fast")) "ReleaseFast" else if (std.mem.eql(u8, optimize, "safe")) "ReleaseSafe" else if (std.mem.eql(u8, optimize, "small")) "ReleaseSmall" else if (std.mem.eql(u8, optimize, "debug")) "Debug" else optimize);
    mod.addOptions("oracle_build", metadata);
    const exe = b.addExecutable(.{ .name = "differential-oracle", .root_module = mod, .use_llvm = true });
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    if (corpus) {
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
