const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const requireZig = @import("src/build/zig.zig").requireZig;

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// Libghostty version. We use a separate version from the app.
const lib_version = "0.1.0-dev";

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    const oracle = try @import("src/differential_oracle_build.zig").configure(b);
    const BuildConfig = @import("src/build/Config.zig");
    const SharedDeps = @import("src/build/SharedDeps.zig");
    const GhosttyExe = @import("src/build/GhosttyExe.zig");
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    // If we have a VERSION file (present in source tarballs) then we
    // use that as the version source of truth. Otherwise we fall back
    // to what is in the build.zig.zon.
    const file_version: ?[]const u8 = if (b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .limited(128),
    )) |content| std.mem.trim(
        u8,
        content,
        &std.ascii.whitespace,
    ) else |_| null;

    const config = try BuildConfig.init(
        b,
        file_version orelse app_zon_version,
        lib_version,
    );

    // lld-link defaults to /OPT:NOREF,NOICF when it writes a PDB (/DEBUG), so a
    // release image that keeps its symbols (-Dstrip=false) would keep every
    // unreferenced function: +2 MB on noctty.exe against the stripped release,
    // none of it the debug info. Zig has no option for it on COFF, but lld
    // (the in-process one included) reads extra arguments from _LINK_, and
    // every compile step runs with this environment. REF gives back what a
    // stripped link drops; ICF adds nothing on top (measured). The two DLLs
    // were already linked with /DEBUG, so they lose their dead code as well.
    // Zig's cache key does not see the environment, so Config feeds the same
    // condition into the build options: that is what keeps a link cached
    // without the flag from being reused.
    //
    // From Zig 0.17 this script runs in its own configure process, and the
    // links run in the make process, which reads its own environment: a
    // value put into `b.graph.environ_map` here never reaches lld. So the
    // caller sets `_LINK_` (scripts/package-windows.ps1 does), and a release
    // build that keeps its symbols without it fails at install rather than
    // linking 2 MB of dead code.
    if (config.release_symbols) {
        // The configure cache does not key on the environment.
        b.graph.poisonCache();
        const link_env = b.graph.environ_map.get("_LINK_") orelse "";
        if (std.mem.indexOf(u8, link_env, "-OPT:REF") == null) {
            b.getInstallStep().dependOn(&b.addFail(
                "a Windows release build with -Dstrip=false links with /OPT:REF: set _LINK_ to include -OPT:REF (scripts/package-windows.ps1 does)",
            ).step);
        }
    }

    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    // Each Zig test executable runs as this many processes side by side, each
    // a disjoint shard of its tests (src/test_runner.zig), and the build
    // summary counts them together. The stock runner runs one test at a time,
    // so on CI's four-core runners one process left three cores idle.
    // Not with --fuzz: the build runner would rebuild the one test compile
    // concurrently for each sharded run step, and a build script cannot see
    // --fuzz to refuse it (Zig 0.15.2's libfuzzer does not build for Windows
    // anyway).
    const test_shards = b.option(
        u32,
        "test-shards",
        "Run each Zig test executable as this many concurrent shards (default 1; not with --fuzz)",
    ) orelse 1;
    if (test_shards == 0 or test_shards > 64) {
        std.debug.print("-Dtest-shards must be between 1 and 64, not {d}\n", .{test_shards});
        std.process.exit(1);
    }
    const test_runner: std.Build.Step.Compile.TestRunner = .{
        .path = b.path("src/test_runner.zig"),
        .mode = .server,
    };

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

    if (exe) |app| {
        // The oracle is not the app exe: its terminal core takes the app's
        // build options with the runtime thread-role layer off, in every mode
        // (PLAN.md §2.7's build scope).
        var app_oracle = oracle;
        app_oracle.build_options = deps.options;
        try @import("src/differential_oracle_build.zig").add(b, app.exe, app_oracle);
    }

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
        conpty_host.subsystem = .console;
        conpty_host.root_module.linkSystemLibrary("advapi32", .{});
        // It shares the app's deps, but never the runtime thread-role layer.
        const conpty_host_deps = deps.withoutThreadRoles();
        _ = try conpty_host_deps.add(conpty_host);
        b.installArtifact(conpty_host);
    }

    // The modules exported for Zig consumers of libghostty-vt, made once:
    // they are named modules of this package, and Zig 0.17 refuses a second
    // module of the same name.
    const lib_vt_mod = if (want_lib_vt_graph)
        try @import("src/build/GhosttyZig.zig").init(b, &config, &deps)
    else
        null;

    // libghostty-vt is retained in this fork, but normal app builds
    // shouldn't pay to build/install it unless explicitly requested.
    if (lib_vt_mod) |mod| {
        const GhosttyLibVt = @import("src/build/GhosttyLibVt.zig");

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
        // An app exe built without the runtime thread-role layer holds none
        // of its text (PLAN.md §2.7 acceptance test 14): checked at install.
        if (!BuildConfig.threadRoles(config.optimize)) {
            const check = ThreadRoleTextCheck.create(b, exe.?.exe.getEmittedBin());
            b.getInstallStep().dependOn(&check.step);
        }
        if (resources) |r| r.install();
        if (config.target.result.os.tag == .windows) {
            const TerminalHandoffProxy = @import("src/build/TerminalHandoffProxy.zig");
            const handoff_proxy = try TerminalHandoffProxy.init(b, &config);
            handoff_proxy.install();
            if (config.bundled_conpty) {
                const ConptyRedist = @import("src/build/ConptyRedist.zig");
                ConptyRedist.install(b, config.target);
            }
        }
    }

    // Run step. With an installed exe, launch the zig-out layout rather
    // than the cached artifact: the runtime finds share/, the bundled
    // ConPTY, the handoff proxy and the toast icon
    // (src/apprt/win32_aumid.zig) as siblings of the exe, and only
    // zig-out/bin has them. Running the cached binary registers the exe
    // path as the toast IconUri, and Windows then caches that icon-less
    // resolution for the rest of the logon session. The installed exe finds
    // zig-out/share/ghostty by climbing from its own path
    // (src/os/resourcesdir.zig), so it needs no GHOSTTY_RESOURCES_DIR (Zig
    // 0.17 knows the install prefix only when the build runs).
    if (config.app_runtime != .none) {
        const run_cmd = if (config.emit_exe) run: {
            const cmd = std.Build.Step.Run.create(b, "run noctty");
            cmd.addFileArg(b.graph.path(.install_bin, exe.?.exe.out_filename));
            cmd.step.dependOn(b.getInstallStep());
            break :run cmd;
        } else b.addRunArtifact(exe.?.exe);
        run_cmd.addPassthruArgs();
        run_step.dependOn(&run_cmd.step);
    }

    // Zig module tests
    if (lib_vt_mod) |mod| {
        const mod_vt_test = b.addTest(.{
            .name = "ghostty-vt-test",
            .root_module = mod.vt,
            .filters = test_filters,
            .test_runner = test_runner,
        });
        addTestRuns(b, test_lib_vt_step, mod_vt_test, test_shards);

        const mod_vt_c_test = b.addTest(.{
            .name = "ghostty-vt-c-test",
            .root_module = mod.vt_c,
            .filters = test_filters,
            .test_runner = test_runner,
        });
        addTestRuns(b, test_lib_vt_step, mod_vt_c_test, test_shards);
    } else {
        test_lib_vt_step.dependOn(&b.addFail("test-lib-vt requires -Demit-lib-vt=true in the Windows-only fork").step);
    }

    // Tests
    if (want_test_graph) {
        // Full unit tests
        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = test_filters,
            // -Dtest-optimize sets the mode, not the `.optimize` below.
            .root_module = config.testModule(b, .{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(b.graph.io),
                .optimize = .debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = true,
            .test_runner = test_runner,
        });
        if (config.emit_test_exe) b.installArtifact(test_exe);
        _ = try deps.add(test_exe);
        // The installer script, for the test that holds its toast activator
        // CLSID to the runtime's (`@embedFile` cannot leave src/).
        test_exe.root_module.addAnonymousImport("noctty_iss", .{
            .root_source_file = b.path("dist/windows/noctty.iss"),
        });

        // An empty exe carrying the app's PE resource, built with the same
        // flags as noctty.exe, so the updater's downgrade guard is tested
        // against a real version block without compiling the whole app.
        if (config.target.result.os.tag == .windows) {
            const fixture_exe = b.addExecutable(.{
                .name = "version-fixture",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/build/version_fixture_main.zig"),
                    .target = config.target,
                    .optimize = .debug,
                }),
            });
            try GhosttyExe.addWindowsResource(b, &config, fixture_exe);
            const fixture = b.addOptions();
            fixture.addOptionPath("exe_path", fixture_exe.getEmittedBin());
            test_exe.root_module.addOptions("windows_version_fixture", fixture);
        }

        // Normal test running
        addTestRuns(b, test_step, test_exe, test_shards);

        // The runner's shard selection (src/test_shard.zig). The runner is not
        // part of the tested module, so no test executable runs its tests.
        const shard_test = b.addTest(.{
            .name = "test-shard",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/test_shard.zig"),
                .target = config.baselineTarget(b.graph.io),
                .optimize = .debug,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(shard_test).step);

        // Normal tests always test our libghostty modules
        //test_step.dependOn(test_lib_vt_step);

    } else {
        test_step.dependOn(&b.addFail("test requires -Dtest-filter=<name> or -Demit-test-exe=true in the Windows-only fork").step);
    }

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    translations_step.dependOn(&b.addFail("update-translations is not supported in the Windows-only fork").step);

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
        .{ .name = "search-stream", .root = "src/bench/search_stream.zig" },
    };
    if (config.app_runtime != .none) {
        // The compile root alone is not enough: terminal build options also
        // derive from SharedDeps.config.optimize. Give the whole benchmark
        // dependency graph a ReleaseFast config so a default `zig build
        // bench:*` cannot measure Debug integrity checks hidden inside an
        // otherwise release binary.
        var bench_config = config;
        bench_config.optimize = .fast;
        // Never with the runtime thread-role layer, whatever the mode.
        const bench_deps = (try SharedDeps.init(b, &bench_config)).withoutThreadRoles();
        inline for (benches) |bench| {
            try addBenchStep(b, &bench_deps, config.baselineTarget(b.graph.io), bench.name, bench.root);
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

/// Makes `step` run the tests of `test_exe`, as `shards` processes side by
/// side when it is above 1. Each process runs a disjoint shard (`--shard=K/N`,
/// src/test_runner.zig), and the build runner runs independent steps in
/// parallel and adds their counts into the one `Build Summary` line.
fn addTestRuns(
    b: *std.Build,
    step: *std.Build.Step,
    test_exe: *std.Build.Step.Compile,
    shards: u32,
) void {
    if (shards == 1) {
        step.dependOn(&b.addRunArtifact(test_exe).step);
        return;
    }
    for (1..shards + 1) |k| {
        const run = b.addRunArtifact(test_exe);
        run.setName(b.fmt("run test {s} {d}/{d}", .{ test_exe.name, k, shards }));
        run.addArg(b.fmt("--shard={d}/{d}", .{ k, shards }));
        step.dependOn(&run.step);
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
            .optimize = .fast,
        }),
    });
    _ = try deps.add(exe);
    addBenchCoreImport(b, exe, target, .fast);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
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
    optimize: std.lang.Optimize,
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

/// Fails the install when an app exe built without the runtime thread-role
/// layer holds its text (PLAN.md §2.7 acceptance test 14).
const ThreadRoleTextCheck = @import("src/build/ThreadRoleTextCheck.zig");
