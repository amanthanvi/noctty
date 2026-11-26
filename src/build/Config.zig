/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const ApprtRuntime = @import("../apprt/runtime.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const WasmTarget = @import("../os/wasm/target.zig").Target;
const expandPath = @import("../os/path.zig").expand;

/// Standard build configuration options.
optimize: std.lang.Optimize,
target: std.Build.ResolvedTarget,
wasm_target: WasmTarget,

/// Comptime interfaces
app_runtime: ApprtRuntime = .win32,
renderer: RendererBackend = .opengl,
/// Include the beta runtime D3D11 backend alongside OpenGL.
d3d11: bool = false,
renderer_test_tools: bool = false,
font_backend: FontBackend = .freetype,

/// Feature flags
sentry: bool = false,
simd: bool = true,
i18n: bool = true,
custom_shaders: bool = false,
bundled_conpty: bool = true,
wasm_shared: bool = true,

/// Ghostty exe properties
exe_entrypoint: ExeEntrypoint = .ghostty,
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
lib_version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },

/// The absolute path the Ghostty executable is installed at, for the Linux
/// desktop, D-Bus and systemd files that launch it. Null means they name
/// the executable alone.
installed_exe_path: ?[]const u8 = null,

/// Binary properties
pie: bool = false,
strip: bool = false,
omit_frame_pointer: bool = false,
release_symbols: bool = false,

/// Whether the modules built with this config's build options get the
/// runtime thread-role layer: `build_options.thread_roles`, which
/// `src/sync/thread_role.zig` reads. False here, so every lib-vt build, build
/// tool, benchmark and conpty-host gets the plain mutex; `SharedDeps.add`
/// builds the app exe and the test exe with a copy that sets it in the modes
/// `threadRoles` names (PLAN.md §2.7's build scope).
thread_roles: bool = false,

/// Artifacts
emit_bench: bool = false,
emit_conpty_host: bool = false,
emit_docs: bool = false,
emit_exe: bool = false,
emit_helpgen: bool = false,
emit_lib_vt: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
/// The test executable's optimize mode (-Dtest-optimize). Debug unless
/// asked: -Doptimize leaves it alone.
test_optimize: std.lang.Optimize = .debug,
emit_themes: bool = false,
emit_webdata: bool = false,
emit_unicode_table_gen: bool = false,

/// Feature gates for libghostty-vt artifacts (-Dvt-features). The full
/// Ghostty application ignores this and always enables everything.
vt_features: TerminalBuildOptions.Features = .{},

/// True when Ghostty is being built as a dependency of another project
/// rather than as the root project.
is_dep: bool = false,

/// Environmental properties
env: *const std.process.Environ.Map,

pub fn init(b: *std.Build, appVersion: []const u8, libVersion: []const u8) !Config {
    // Setup our standard Zig target and optimize options, i.e.
    // `-Doptimize` and `-Dtarget`.
    const optimize = b.standardOptimizeOption(.{});

    // Default dependency builds to libghostty-vt-only mode. Consumers can
    // still explicitly disable this to request the full Ghostty build.
    const is_dep = b.dep_prefix.len > 0;
    const emit_lib_vt = b.option(
        bool,
        "emit-lib-vt",
        "Set defaults for a libghostty-vt-only build in the Windows-only fork.",
    ) orelse is_dep;
    const target = target: {
        var result = b.standardTargetOptions(.{});

        // On Windows, default to the MSVC ABI so that produced COFF
        // objects (including compiler_rt) are compatible with the MSVC
        // linker. Zig defaults to the GNU ABI which produces objects
        // with invalid COMDAT sections that MSVC rejects (LNK1143).
        // Only override when no explicit ABI was requested. Every Windows
        // target also guarantees our documented 1809 floor, so std rename
        // can use POSIX semantics instead of rejecting held-open files.
        if (result.result.os.tag == .windows) {
            var query = result.query;
            if (query.abi == null) query.abi = .msvc;
            if (query.os_version_min == null or
                @intFromEnum(query.os_version_min.?.windows) < @intFromEnum(std.Target.Os.WindowsVersion.win10_rs5))
            {
                query.os_version_min = .{ .windows = .win10_rs5 };
            }
            result = b.resolveTargetQuery(query);
        }

        // On wasm, default to enabling the simd128 feature. Every
        // browser engine has supported it since 2023 or earlier
        // (Chrome 91, Firefox 89, Safari 16.4) and it is a large
        // performance win for the terminal hot paths (50%+ on
        // print-heavy VT streams). Only apply when no explicit CPU
        // was requested; targets for exotic non-browser runtimes
        // can opt out with `-Dcpu=generic`.
        if (result.result.cpu.arch.isWasm() and
            result.query.cpu_model == .determined_by_arch_os and
            result.query.cpu_features_add.isEmpty() and
            result.query.cpu_features_sub.isEmpty())
        {
            var query = result.query;
            query.cpu_features_add.addFeature(
                @backingInt(std.Target.wasm.Feature.simd128),
            );
            result = b.resolveTargetQuery(query);
        }

        // The full Ghostty build no longer supports iOS; Fail early
        // with a clear message rather than partway through the build.
        if (result.result.os.tag == .ios and !emit_lib_vt) {
            std.log.err(
                "iOS is not a supported target for the full Ghostty build; " ++
                    "only libghostty-vt supports iOS (-Demit-lib-vt)",
                .{},
            );
            return error.UnsupportedTarget;
        }

        // If we have no minimum OS version, we set the default based on
        // our tag. Not all tags have a minimum so this may be null.
        if (result.query.os_version_min == null) {
            result.query.os_version_min = if (emit_lib_vt)
                osVersionMinLibVt(result.result.os.tag)
            else
                osVersionMin(result.result.os.tag);
        }

        break :target result;
    };

    // This is set to true when we're building a system package. For now
    // this is trivially detected using the "system_package_mode" bool
    // but we may want to make this more sophisticated in the future.
    const system_package = b.graph.system_package_mode;

    // This specifies our target wasm runtime. For now only one semi-usable
    // one exists so this is hardcoded.
    const wasm_target: WasmTarget = .browser;

    // Grab the environment from build state
    const env = &b.graph.environ_map;

    // We use env vars throughout the build so we grab them immediately here.
    var config: Config = .{
        .optimize = optimize,
        .target = target,
        .wasm_target = wasm_target,
        .is_dep = is_dep,
        .env = env,
    };

    //---------------------------------------------------------------
    // Comptime Interfaces
    config.font_backend = b.option(
        FontBackend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse FontBackend.default(target.result, wasm_target);

    config.app_runtime = b.option(
        ApprtRuntime,
        "app-runtime",
        "The app runtime to use. This fork supports Win32 only for app builds.",
    ) orelse ApprtRuntime.default(target.result);
    if (config.app_runtime == .win32 and target.result.os.tag != .windows) {
        return error.WindowsOnlyAppRuntimeRequiresWindowsTarget;
    }

    config.renderer = b.option(
        RendererBackend,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse RendererBackend.default(target.result, wasm_target);

    config.d3d11 = b.option(bool, "d3d11", "Include beta D3D11 alongside OpenGL (Win32 default).") orelse
        (config.app_runtime == .win32 and config.renderer == .opengl);
    if (config.d3d11 and (config.app_runtime != .win32 or config.renderer != .opengl))
        return error.Direct3D11RequiresWin32OpenGL;
    config.renderer_test_tools = b.option(bool, "renderer-test-tools", "Enable isolated GPU readback and fault injection tests.") orelse false;

    //---------------------------------------------------------------
    // Feature Flags

    config.sentry = b.option(
        bool,
        "sentry",
        "Build with the Sentry SDK (disabled by default; Windows uses local minidumps independently).",
    ) orelse false;

    config.simd = b.option(
        bool,
        "simd",
        "Build with SIMD-accelerated code paths. Results in significant performance improvements.",
    ) orelse simd: {
        // We can't build our SIMD dependencies for Wasm or freestanding
        // targets. Note that we may still use SIMD features in the Wasm-builds.
        if (target.result.cpu.arch.isWasm() or
            target.result.os.tag == .freestanding) break :simd false;

        break :simd true;
    };

    config.i18n = b.option(
        bool,
        "i18n",
        "Enables gettext-based internationalization.",
    ) orelse switch (target.result.os.tag) {
        .windows => false,
        else => false,
    };

    config.custom_shaders = b.option(
        bool,
        "custom-shaders",
        "Enable custom shader compilation support. Disabled by default in the Windows-only fork to keep default app builds lighter.",
    ) orelse false;

    config.bundled_conpty = b.option(
        bool,
        "bundled-conpty",
        "Stage Microsoft's pinned ConPTY pair (conpty.dll, OpenConsole.exe) beside the Windows exe, as releases ship it. false skips the step and its one-time download; noctty then uses Windows' in-box conhost unless a pair is already installed, which is left as is and not verified.",
    ) orelse true;

    //---------------------------------------------------------------
    // Ghostty Exe Properties

    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, the Windows-only fork uses a generic dev version. This must be a semantic version.",
    );

    config.version = if (version_string) |v|
        // If an explicit version is given, we always use it.
        try std.SemanticVersion.parse(v)
    else version: {
        const app_version = try std.SemanticVersion.parse(appVersion);

        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = "dev",
            .build = if (is_dep) null else "windows",
        };
    };

    // libghostty-vt properties

    const lib_version_string = b.option(
        []const u8,
        "lib-version-string",
        "A specific version string to use for the build of libghostty-vt. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    config.lib_version = if (lib_version_string) |v|
        try std.SemanticVersion.parse(v)
    else
        try std.SemanticVersion.parse(libVersion);

    // The install prefix is only known once the build runs, too late to
    // write it into the files that launch Ghostty, so a build installing
    // anywhere systemd doesn't search has to say where the executable goes.
    config.installed_exe_path = b.option(
        []const u8,
        "installed-exe-path",
        "Absolute path the ghostty executable will be installed at, written " ++
            "into the Linux desktop, D-Bus and systemd files. If not specified, " ++
            "they name the executable alone, which systemd only finds in " ++
            "/usr/bin or /usr/local/bin.",
    );
    if (config.installed_exe_path) |exe_path| {
        if (!std.fs.path.isAbsolute(exe_path)) {
            std.log.err(
                "-Dinstalled-exe-path must be an absolute path, got '{s}'",
                .{exe_path},
            );
            return error.InvalidInstalledExePath;
        }
    }

    //---------------------------------------------------------------
    // Binary Properties

    config.pie = b.option(
        bool,
        "pie",
        "Build a Position Independent Executable. Default true for system packages.",
    ) orelse system_package;

    config.strip = b.option(
        bool,
        "strip",
        "Strip the final executable. Default true for fast and small releases",
    ) orelse switch (optimize) {
        .debug => false,
        .safe => false,
        .fast, .small => true,
    };

    // Follows the optimize mode, not `strip`: a release build that keeps its
    // debug info (-Dstrip=false, which is how the symbols zip is built) must
    // still generate release code, or the PDB would describe a different
    // binary from the one users run.
    config.omit_frame_pointer = switch (optimize) {
        .debug, .safe => false,
        .fast, .small => true,
    };

    // A Windows release image that keeps its PDB. build.zig links it with
    // /OPT:REF, and the value is also a build option (below) so that a link
    // cached from a build without the flag is never reused for it: Zig's
    // cache key does not see the environment.
    config.release_symbols = config.omit_frame_pointer and
        !config.strip and
        config.target.result.os.tag == .windows;

    //---------------------------------------------------------------
    // Artifacts to Emit

    config.emit_lib_vt = emit_lib_vt;

    config.vt_features = features: {
        const list = b.option(
            []const u8,
            "vt-features",
            "Comma-separated libghostty-vt feature modifications applied " ++
                "to the default all-enabled set, -Dcpu style: `+feature` " ++
                "or `feature` enables, `-feature` disables, and `all` " ++
                "means every feature (e.g. `-all,+render-state` for a " ++
                "render-only build). Only applies to lib artifacts.",
        ) orelse break :features .{};
        break :features TerminalBuildOptions.Features.parse(list) catch {
            var valid: std.ArrayList(u8) = .empty;
            inline for (@typeInfo(TerminalBuildOptions.Features).@"struct".field_names) |name| {
                if (valid.items.len > 0) try valid.appendSlice(b.allocator, ", ");
                try valid.appendSlice(b.allocator, name);
            }
            std.log.err(
                "-Dvt-features={s} contains an unknown feature. Valid features: all, {s}",
                .{ list, valid.items },
            );
            return error.UnknownVtFeature;
        };
    };

    config.emit_exe = b.option(
        bool,
        "emit-exe",
        "Build and install main executables with 'build'",
    ) orelse !config.emit_lib_vt;

    config.emit_test_exe = b.option(
        bool,
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    config.test_optimize = b.option(
        std.lang.Optimize,
        "test-optimize",
        "Optimize mode of the Zig test executable ghostty-test (default Debug; -Doptimize does not change it)",
    ) orelse .debug;

    config.emit_unicode_table_gen = b.option(
        bool,
        "emit-unicode-table-gen",
        "Build and install executables that generate unicode tables with 'build'",
    ) orelse false;

    config.emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;

    config.emit_conpty_host = b.option(
        bool,
        "emit-conpty-host",
        "Build and install the standalone Windows ConPTY host spike.",
    ) orelse false;

    if (config.emit_conpty_host and target.result.os.tag != .windows) {
        return error.ConptyHostRequiresWindowsTarget;
    }

    config.emit_helpgen = b.option(
        bool,
        "emit-helpgen",
        "Build and install the helpgen executable.",
    ) orelse false;

    config.emit_docs = b.option(
        bool,
        "emit-docs",
        "Build and install auto-generated documentation (requires pandoc)",
    ) orelse emit_docs: {
        // If we are emitting any other artifacts then we default to false.
        if (config.emit_bench or
            config.emit_conpty_host or
            config.emit_test_exe or
            config.emit_helpgen or
            config.emit_lib_vt) break :emit_docs false;

        // We always emit docs in system package mode.
        if (system_package) break :emit_docs true;

        // We only default to true if we can find pandoc.
        const path = expandPath(b.graph.io, b.allocator, &b.graph.environ_map, "pandoc") catch
            break :emit_docs false;
        defer if (path) |p| b.allocator.free(p);
        break :emit_docs path != null;
    };

    config.emit_terminfo = b.option(
        bool,
        "emit-terminfo",
        "Install Ghostty terminfo source file",
    ) orelse switch (target.result.os.tag) {
        .windows => true,
        else => switch (optimize) {
            .debug => true,
            .safe, .fast, .small => false,
        },
    };

    config.emit_termcap = b.option(
        bool,
        "emit-termcap",
        "Install Ghostty termcap file",
    ) orelse switch (optimize) {
        .debug => true,
        .safe, .fast, .small => false,
    };

    config.emit_themes = b.option(
        bool,
        "emit-themes",
        "Install bundled iTerm2-Color-Schemes Ghostty themes",
    ) orelse true;

    config.emit_webdata = b.option(
        bool,
        "emit-webdata",
        "Build the website data for the website.",
    ) orelse false;

    //---------------------------------------------------------------
    // System Packages

    // These are all our dependencies that can be used with system
    // packages if they exist. We set them up here so that we can set
    // their defaults early. The first call configures the integration and
    // subsequent calls just return the configured value. This lets them
    // show up properly in `--help`.

    {
        // These dependencies we want to default false if we're on macOS.
        // On macOS we don't want to use system libraries because we
        // generally want a fat binary. This can be overridden with the
        // `-fsys` flag.
        for (&[_][]const u8{
            "freetype",
            "harfbuzz",
            "fontconfig",
            "libpng",
            "zlib",
            "oniguruma",
        }) |dep| {
            _ = b.systemIntegrationOption(
                dep,
                .{
                    .default = null,
                },
            );
        }

        // These default to false because they're rarely available as
        // system packages so we usually want to statically link them.
        for (&[_][]const u8{
            "glslang",
            "spirv-cross",
            "simdutf",
        }) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = false });
        }
    }

    return config;
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(bool, "simd", self.simd);
    step.addOption(bool, "i18n", self.i18n);
    step.addOption(bool, "custom_shaders", self.custom_shaders);
    step.addOption(bool, "release_symbols", self.release_symbols);
    step.addOption(bool, "thread_roles", self.thread_roles);
    step.addOption(bool, "d3d11", self.d3d11);
    step.addOption(bool, "renderer_test_tools", self.renderer_test_tools);
    step.addOption(std.lang.Optimize, "test_optimize", self.test_optimize);
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
    step.addOption(WasmTarget, "wasm_target", self.wasm_target);
    step.addOption(bool, "wasm_shared", self.wasm_shared);

    // Our version. We also add the string version so we don't need
    // to do any allocations at runtime. This has to be long enough to
    // accommodate realistic large branch names for dev versions.
    var app_version_buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.mem.printSentinel(
        &app_version_buf,
        "{f}",
        .{self.version},
        0,
    ));
    var lib_version_buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "lib_version", self.lib_version);
    step.addOption([:0]const u8, "lib_version_string", try std.mem.printSentinel(
        &lib_version_buf,
        "{f}",
        .{self.lib_version},
        0,
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}

/// The test executable's root module: `options` built in the -Dtest-optimize
/// mode, whatever `options.optimize` says. build.zig keeps upstream's
/// `.optimize` line in the call because upstream respells that line (`.debug`
/// in v1.4.0); an edit there would conflict at every merge.
pub fn testModule(
    self: *const Config,
    b: *std.Build,
    options: std.Build.Module.CreateOptions,
) *std.Build.Module {
    var test_options = options;
    test_options.optimize = self.test_optimize;
    return b.createModule(test_options);
}

/// Whether the app exe or the test exe, built in `mode`, gets the runtime
/// thread-role layer (PLAN.md §2.7's build scope): in Debug and ReleaseSafe,
/// never in ReleaseFast or ReleaseSmall. Every other artifact gets it in no
/// mode.
pub fn threadRoles(mode: std.lang.Optimize) bool {
    return switch (mode) {
        .debug, .safe => true,
        .fast, .small => false,
    };
}

/// Returns the build options for the terminal module. This assumes a
/// Ghostty executable being built. Callers should modify this as needed.
pub fn terminalOptions(
    self: *const Config,
    artifact: TerminalBuildOptions.Artifact,
    optimize: std.lang.Optimize,
) TerminalBuildOptions {
    return .{
        .artifact = artifact,
        .simd = self.simd,
        .oniguruma = true,
        .c_abi = false,
        // The application requires every feature; only lib artifacts
        // may trim them.
        .features = switch (artifact) {
            .ghostty => .{},
            .lib => self.vt_features,
        },
        .version = switch (artifact) {
            .ghostty => self.version,
            .lib => self.lib_version,
        },
        .slow_runtime_safety = switch (optimize) {
            .debug => true,
            .safe,
            .small,
            .fast,
            => false,
        },
    };
}

/// Returns a baseline CPU target retaining all the other CPU configs.
pub fn baselineTarget(self: *const Config, io: std.Io) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(io, q) catch
            @panic("unable to resolve baseline query"),
    };
}

/// Rehydrate our Config from the comptime options. Note that not all
/// options are available at comptime, so look closely at this implementation
/// to see what is and isn't available.
pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{
        // Unused at runtime.
        .optimize = undefined,
        .target = undefined,
        .env = undefined,

        .version = options.app_version,
        .app_runtime = std.meta.stringToEnum(ApprtRuntime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(RendererBackend, @tagName(options.renderer)).?,
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
        .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
        .wasm_shared = options.wasm_shared,
        .i18n = options.i18n,
        .custom_shaders = options.custom_shaders,
        .d3d11 = options.d3d11,
        .renderer_test_tools = options.renderer_test_tools,
    };
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        // We support back to the earliest officially supported version
        // of macOS by Apple. EOL versions are not supported.
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },

        // This should never happen currently. If we add a new target then
        // we should add a new case here.
        else => null,
    };
}

/// Returns the minimum OS version for lib-vt build.
///
/// This should only be used for Darwin targets.
pub fn osVersionMinLibVt(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    // lib-vt is the only thing we still build for iOS, so its deployment
    // target lives here rather than in osVersionMin.
    if (tag == .ios) return .{ .semver = .{ .major = 13, .minor = 0, .patch = 0 } };
    return osVersionMin(tag);
}

/// The possible entrypoints for the exe artifact. This has no effect on
/// other artifact types (i.e. lib, wasm_module).
///
/// The whole existence of this enum is to workaround the fact that Zig
/// doesn't allow the main function to be in a file in a subdirctory
/// from the "root" of the module, and I don't want to pollute our root
/// directory with a bunch of individual zig files for each entrypoint.
///
/// Therefore, main.zig uses this to switch between the different entrypoints.
pub const ExeEntrypoint = enum {
    ghostty,
    helpgen,
    mdgen_ghostty_1,
    mdgen_ghostty_5,
    webgen_config,
    webgen_actions,
    webgen_commands,
};

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};

test "the test executable runs in its -Dtest-optimize mode" {
    // build_options declares its own copy of the enum, so compare the names.
    try std.testing.expectEqualStrings(
        @tagName(@import("build_options").test_optimize),
        @tagName(@import("builtin").mode),
    );
}

test "the thread-role layer is on in the test executable's Debug and ReleaseSafe only" {
    const on = @import("build_options").thread_roles;
    // The layer takes the build option's form.
    try std.testing.expectEqual(on, @import("../sync/thread_role.zig").layer == .on);
    const mode = @import("builtin").mode;
    // Never in ReleaseFast or ReleaseSmall, in any test executable.
    if (on) try std.testing.expect(threadRoles(mode));
    // The fork's test executable has it in its mode; lib-vt's never does.
    switch (@import("terminal_options").artifact) {
        .ghostty => try std.testing.expectEqual(threadRoles(mode), on),
        .lib => try std.testing.expect(!on),
    }
}

test {
    // The fork-owned build check of the layer's text, and its test.
    _ = @import("ThreadRoleTextCheck.zig");
}
