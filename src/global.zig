const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const cli_action = @import("cli/action.zig");
const cli_args = @import("cli/args.zig");
const cli_ghostty_action = @import("cli/ghostty_action.zig");
const internal_os = @import("os/main.zig");
const fontconfig = if (build_config.font_backend.hasFontconfig())
    @import("fontconfig")
else
    struct {
        pub fn version() c_int {
            return 0;
        }
    };
const harfbuzz = @import("harfbuzz");
const oni = @import("oniguruma");
const glslang = if (build_config.custom_shaders) @import("glslang") else struct {
    pub fn init() !void {}
};
const crash = @import("crash/main.zig");
const apprt = @import("apprt.zig");

/// We export the xev backend we want to use so that the rest of
/// Ghostty can import this once and have access to the proper
/// backend.
pub const xev = @import("xev").Dynamic;

/// Global process state. This is initialized by the executable entrypoint.
/// The removed app-embedding C API no longer initializes this separately.
/// New code should avoid leaning on global state and prefer explicit
/// allocators and runtime handles.
pub var state: GlobalState = undefined;

/// This represents the global process state. There should only
/// be one of these at any given moment. This is extracted into a dedicated
/// struct because it is reused by main and the static C lib.
pub const GlobalState = struct {
    const GPA = std.heap.GeneralPurposeAllocator(.{});

    gpa: ?GPA,
    alloc: std.mem.Allocator,
    action: ?cli_ghostty_action.Action,
    /// Start with built-in defaults and no workspace restore. This is an
    /// ephemeral recovery launch mode and is never persisted.
    safe_mode: bool,
    logging: Logging,
    rlimits: ResourceLimits = .{},

    /// The app resources directory, equivalent to zig-out/share when we build
    /// from source. This is null if we can't detect it.
    resources_dir: internal_os.ResourcesDir,

    /// Where logging should go
    pub const Logging = packed struct {
        /// Whether to log to stderr. For lib mode we always disable stderr
        /// logging by default. Otherwise it's enabled by default.
        stderr: bool = build_config.app_runtime != .none,
        /// Whether to log to macOS's unified logging. Enabled by default
        /// on macOS.
        macos: bool = builtin.os.tag.isDarwin(),
    };

    /// Initialize the global state.
    pub fn init(self: *GlobalState) !void {
        // Initialize ourself to nothing so we don't have any extra state.
        // IMPORTANT: this MUST be initialized before any log output because
        // the log function uses the global state.
        self.* = .{
            .gpa = null,
            .alloc = undefined,
            .action = null,
            .safe_mode = false,
            .logging = .{},
            .rlimits = .{},
            .resources_dir = .{},
        };
        errdefer self.deinit();

        self.gpa = gpa: {
            // Use the libc allocator if it is available because it is WAY
            // faster than GPA. We only do this in release modes so that we
            // can get easy memory leak detection in debug modes.
            if (builtin.link_libc) {
                if (switch (builtin.mode) {
                    .ReleaseSafe, .ReleaseFast => true,

                    // We also use it if we can detect we're running under
                    // Valgrind since Valgrind only instruments the C allocator
                    else => std.valgrind.runningOnValgrind() > 0,
                }) break :gpa null;
            }

            break :gpa GPA{};
        };

        self.alloc = if (self.gpa) |*value|
            value.allocator()
        else if (builtin.link_libc)
            std.heap.c_allocator
        else
            unreachable;

        self.safe_mode = detectSafeMode(self.alloc) catch false;

        // We first try to parse any action that we may be executing.
        self.action = try cli_action.detectArgs(
            cli_ghostty_action.Action,
            self.alloc,
        );

        // If we have an action executing, we disable logging by default
        // since we write to stderr we don't want logs messing up our
        // output.
        if (self.action != null) self.logging.stderr = false;

        // Logging uses an env var because action/config parsing already
        // consumes CLI args before logging is initialized.
        if ((try internal_os.getenv(self.alloc, "GHOSTTY_LOG"))) |v| {
            defer v.deinit(self.alloc);
            self.logging = cli_args.parsePackedStruct(Logging, v.value) catch .{};
        }

        // Setup our signal handlers before logging
        initSignals();

        // Setup our Xev backend if we're dynamic
        if (comptime xev.dynamic) xev.detect() catch |err| {
            std.log.warn("failed to detect xev backend, falling back to " ++
                "most compatible backend err={}", .{err});
        };

        // Output some debug information right away
        std.log.info("{s} version={s}", .{ build_config.app_name, build_config.version_string });
        std.log.info("{s} build optimize={s}", .{ build_config.app_name, build_config.mode_string });
        std.log.info("runtime={}", .{build_config.app_runtime});
        std.log.info("font_backend={}", .{build_config.font_backend});
        if (comptime build_config.font_backend.hasHarfbuzz()) {
            std.log.info("dependency harfbuzz={s}", .{harfbuzz.versionString()});
        }
        if (comptime build_config.font_backend.hasFontconfig()) {
            std.log.info("dependency fontconfig={d}", .{fontconfig.version()});
        }
        std.log.info("renderer={}", .{build_config.renderer});
        std.log.info("event backend={t}", .{xev.backend});
        if (self.safe_mode) std.log.warn("safe mode enabled: using built-in config and skipping session restore", .{});

        // As early as possible, initialize our resource limits.
        self.rlimits = .init();

        // Initialize our crash reporting.
        crash.init(self.alloc) catch |err| {
            std.log.warn(
                "sentry init failed, no crash capture available err={}",
                .{err},
            );
        };

        // We need to make sure the process locale is set properly. Locale
        // affects a lot of behaviors in a shell.
        try internal_os.ensureLocale(self.alloc);

        // Initialize custom shader support, if it is compiled in.
        try glslang.init();

        // Initialize oniguruma for regex
        try oni.init(&.{oni.Encoding.utf8});

        // Find our resources directory once for the app so every launch
        // hereafter can use this cached value.
        self.resources_dir = try apprt.runtime.resourcesDir(self.alloc);
        errdefer self.resources_dir.deinit(self.alloc);

        // Setup i18n
        if (self.resources_dir.app()) |v| internal_os.i18n.init(v) catch |err| {
            std.log.warn("failed to init i18n, translations will not be available err={}", .{err});
        };
    }

    /// Cleans up the global state. This doesn't _need_ to be called but
    /// doing so in dev modes will check for memory leaks.
    pub fn deinit(self: *GlobalState) void {
        self.resources_dir.deinit(self.alloc);

        // Flush our crash logs
        crash.deinit();

        if (self.gpa) |*value| {
            // We want to ensure that we deinit the GPA because this is
            // the point at which it will output if there were safety violations.
            _ = value.deinit();
        }
    }

    fn initSignals() void {
        // Only posix systems.
        if (comptime builtin.os.tag == .windows) return;

        const p = std.posix;

        var sa: p.Sigaction = .{
            .handler = .{ .handler = p.SIG.IGN },
            .mask = p.sigemptyset(),
            .flags = 0,
        };

        // Closed terminals can produce SIGPIPE while the read thread is
        // unwinding; normal shutdown paths handle the exit.
        p.sigaction(p.SIG.PIPE, &sa, null);
    }
};

fn detectSafeMode(alloc: std.mem.Allocator) !bool {
    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    return safeModeInArgs(argv);
}

fn safeModeInArgs(argv: []const []const u8) bool {
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-e")) return false;
        if (std.mem.eql(u8, arg, "--safe-mode")) return true;
    }
    return false;
}

test "safe mode only applies to application arguments" {
    try std.testing.expect(safeModeInArgs(&.{ "winghostty", "--safe-mode" }));
    try std.testing.expect(!safeModeInArgs(&.{ "winghostty", "-e", "tool", "--safe-mode" }));
    try std.testing.expect(!safeModeInArgs(&.{"winghostty"}));
}

/// Maintains the Unix resource limits that we set for our process. This
/// can be used to restore the limits to their original values.
pub const ResourceLimits = struct {
    nofile: ?internal_os.rlimit = null,

    pub fn init() ResourceLimits {
        return .{
            // Maximize the number of file descriptors we can have open
            // because we can consume a lot of them if we make many terminals.
            .nofile = internal_os.fixMaxFiles(),
        };
    }

    pub fn restore(self: *const ResourceLimits) void {
        if (self.nofile) |lim| internal_os.restoreMaxFiles(lim);
    }
};
