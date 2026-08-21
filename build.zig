const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const requireZig = @import("src/build/zig.zig").requireZig;

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// Libghostty version. We use a separate version from the app.
const lib_version = "0.1.0";

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    const BuildConfig = @import("src/build/Config.zig");
    const SharedDeps = @import("src/build/SharedDeps.zig");
    const GhosttyExe = @import("src/build/GhosttyExe.zig");
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    // If we have a VERSION file (present in source tarballs) then we
    // use that as the version source of truth. Otherwise we fall back
    // to what is in the build.zig.zon.
    const file_version: ?[]const u8 = if (b.build_root.handle.readFileAlloc(
        b.allocator,
        "VERSION",
        128,
    )) |content| std.mem.trim(
        u8,
        content,
        &std.ascii.whitespace,
    ) else |_| null;

    const config = try BuildConfig.init(
        b,
        file_version orelse app_zon_version,
    );
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    const want_lib_vt_graph = config.emit_lib_vt or config.is_dep;
    const want_test_graph =
        config.emit_test_exe or
        test_filters.len > 0;

    // Shared dependencies used by many artifacts.
    const deps = try SharedDeps.init(b, &config);

    // Top-level user-facing build steps.
    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run tests");
    const test_lib_vt_step = b.step(
        "test-lib-vt",
        "Run libghostty-vt tests",
    );
    const translations_step = b.step(
        "update-translations",
        "Update translation files",
    );

    // A locally installed app build must carry the same share/ghostty tree
    // that the runtime expects. On Windows this keeps source-built CLI
    // actions such as +list-themes aligned with packaged behavior.
    const install_resources =
        config.emit_exe and
        config.app_runtime != .none;
    const resources = if (install_resources) resources: {
        const GhosttyResources = @import("src/build/GhosttyResources.zig");
        break :resources try GhosttyResources.init(b, &config, &deps);
    } else null;

    // noctty executable, the actual runnable app binary.
    const exe = if (config.app_runtime != .none)
        try GhosttyExe.init(b, &config, &deps)
    else
        null;

    // Standalone feasibility spike. This artifact is intentionally absent
    // from the normal build and every product packaging path.
    if (config.emit_conpty_host) {
        const conpty_host = b.addExecutable(.{
            .name = "conpty-host",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/conpty_host.zig"),
                .target = config.target,
                .optimize = config.optimize,
                .strip = config.strip,
                .omit_frame_pointer = config.strip,
                .unwind_tables = if (config.strip) .none else .sync,
            }),
            .use_llvm = true,
        });
        conpty_host.subsystem = .Console;
        conpty_host.linkSystemLibrary("advapi32");
        _ = try deps.add(conpty_host);
        b.installArtifact(conpty_host);
    }

    // libghostty-vt is retained in this fork, but normal app builds
    // shouldn't pay to build/install it unless explicitly requested.
    if (want_lib_vt_graph) {
        const GhosttyZig = @import("src/build/GhosttyZig.zig");
        const GhosttyLibVt = @import("src/build/GhosttyLibVt.zig");

        // The modules exported for Zig consumers of libghostty-vt.
        const mod = try GhosttyZig.init(
            b,
            &config,
            &deps,
        );

        const libghostty_vt_shared = shared: {
            if (config.target.result.cpu.arch.isWasm()) {
                break :shared try GhosttyLibVt.initWasm(
                    b,
                    &mod,
                );
            }

            break :shared try GhosttyLibVt.initShared(
                b,
                &mod,
            );
        };
        libghostty_vt_shared.install(b.getInstallStep());

        // libghostty-vt static lib
        const libghostty_vt_static = try GhosttyLibVt.initStatic(
            b,
            &mod,
        );
        if (config.is_dep) {
            // If we're a dependency, we need to install everything as-is
            // so that dep.artifact("ghostty-vt-static") works.
            libghostty_vt_static.install(b.getInstallStep());
        } else {
            // If we're not a dependency, we rename the static lib to
            // be idiomatic. On Windows, we use a distinct name to avoid
            // colliding with the DLL import library (ghostty-vt.lib).
            const static_lib_name = if (config.target.result.os.tag == .windows)
                "ghostty-vt-static.lib"
            else
                "libghostty-vt.a";
            b.getInstallStep().dependOn(&b.addInstallLibFile(
                libghostty_vt_static.output,
                static_lib_name,
            ).step);
        }
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    if (config.emit_exe and config.app_runtime != .none) {
        exe.?.install();
        if (resources) |r| r.install();
        if (config.target.result.os.tag == .windows) {
            const TerminalHandoffProxy = @import("src/build/TerminalHandoffProxy.zig");
            const handoff_proxy = try TerminalHandoffProxy.init(b, &config);
            handoff_proxy.install();
        }
    }

    // Run step
    if (config.app_runtime != .none) {
        const run_cmd = b.addRunArtifact(exe.?.exe);
        if (b.args) |args| run_cmd.addArgs(args);
        if (install_resources) run_cmd.setEnvironmentVariable(
            "GHOSTTY_RESOURCES_DIR",
            b.getInstallPath(.prefix, "share/ghostty"),
        );
        run_step.dependOn(&run_cmd.step);
    }

    // Zig module tests
    if (want_lib_vt_graph) {
        const GhosttyZig = @import("src/build/GhosttyZig.zig");
        const mod = try GhosttyZig.init(
            b,
            &config,
            &deps,
        );

        const mod_vt_test = b.addTest(.{
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);

        const mod_vt_c_test = b.addTest(.{
            .root_module = mod.vt_c,
            .filters = test_filters,
        });
        const mod_vt_c_test_run = b.addRunArtifact(mod_vt_c_test);
        test_lib_vt_step.dependOn(&mod_vt_c_test_run.step);
    } else {
        try test_lib_vt_step.addError(
            "test-lib-vt requires -Demit-lib-vt=true in the Windows-only fork",
            .{},
        );
    }

    // Tests
    if (want_test_graph) {
        // Full unit tests
        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(),
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = true,
        });
        if (config.emit_test_exe) b.installArtifact(test_exe);
        _ = try deps.add(test_exe);

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_run.step);

        // Normal tests always test our libghostty modules
        //test_step.dependOn(test_lib_vt_step);

    } else {
        try test_step.addError(
            "test requires -Dtest-filter=<name> or -Demit-test-exe=true in the Windows-only fork",
            .{},
        );
    }

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    try translations_step.addError("update-translations is not supported in the Windows-only fork", .{});

    // Benchmarks. Standalone `main()` exes under `bench/`, each exposed
    // as a `bench:<name>` step that builds + runs with forwarded args.
    //
    //   zig build bench:palette-match -- --entries=500 --keystrokes=1000
    //
    // `addBenchStep` wires the shared dep graph so harnesses can import
    // internal modules (e.g. `src/apprt/win32_palette.zig` pulls in zf
    // and the Command catalogue).
    const benches = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "palette-match", .root = "src/bench/palette_match.zig" },
        .{ .name = "vt-throughput", .root = "src/bench/vt_throughput.zig" },
    };
    if (config.app_runtime != .none) {
        // The compile root alone is not enough: terminal build options also
        // derive from SharedDeps.config.optimize. Give the whole benchmark
        // dependency graph a ReleaseFast config so a default `zig build
        // bench:*` cannot measure Debug integrity checks hidden inside an
        // otherwise release binary.
        var bench_config = config;
        bench_config.optimize = .ReleaseFast;
        const bench_deps = try SharedDeps.init(b, &bench_config);
        inline for (benches) |bench| {
            try addBenchStep(b, &bench_deps, config.baselineTarget(), bench.name, bench.root);
        }
    } else {
        inline for (benches) |bench| {
            const bench_step = b.step(
                b.fmt("bench:{s}", .{bench.name}),
                b.fmt("Build and run bench/{s} microbench", .{bench.name}),
            );
            bench_step.dependOn(&b.addFail(
                b.fmt("bench:{s} requires an application runtime", .{bench.name}),
            ).step);
        }
    }
}

fn addBenchStep(
    b: *std.Build,
    deps: *const @import("src/build/SharedDeps.zig"),
    target: std.Build.ResolvedTarget,
    comptime name: []const u8,
    comptime src: []const u8,
) !void {
    const exe = b.addExecutable(.{
        .name = "bench-" ++ name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    _ = try deps.add(exe);
    addBenchCoreImport(b, exe, target, .ReleaseFast);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step(
        "bench:" ++ name,
        "Build and run bench/" ++ name ++ " microbench",
    );
    step.dependOn(&run.step);
}

fn addBenchCoreImport(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const bench_core = b.createModule(.{
        .root_source_file = b.path("src/main_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    var imports = compile.root_module.import_table.iterator();
    while (imports.next()) |entry| {
        bench_core.addImport(entry.key_ptr.*, entry.value_ptr.*);
    }
    compile.root_module.addImport("bench_core", bench_core);
}
