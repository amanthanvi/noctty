const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const build_config = @import("../build_config.zig");
const crash = @import("../crash/main.zig");
const pty = @import("../pty.zig");

pub const Options = struct {
    /// Directory to create. Defaults to `noctty-diagnostic-bundle`.
    output: ?[:0]const u8 = null,

    /// Copy local crash dumps into the bundle. Disabled by default because
    /// dumps may contain process memory and other sensitive data.
    @"include-crash-dumps": bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return actionpkg.help_error;
    }
};

const Manifest = struct {
    schema: []const u8 = "noctty.diagnostics.v1",
    schema_version: u8 = 1,
    application: []const u8 = build_config.app_name,
    version: []const u8 = build_config.version_string,
    platform: []const u8 = @tagName(builtin.os.tag),
    architecture: []const u8 = @tagName(builtin.cpu.arch),
    optimize: []const u8 = build_config.mode_string,
    renderer: []const u8 = @tagName(build_config.renderer),
    conpty: ?pty.ConPtyInfo,
    crash_report_count: usize,
    crash_dumps_included: bool,
    privacy: Privacy = .{},
};

const Privacy = struct {
    terminal_content: bool = false,
    commands: bool = false,
    environment: bool = false,
    working_directories: bool = false,
    config_values: bool = false,
};

/// Create a local, inspectable diagnostic bundle. Collection is deliberately
/// offline and redacted by default; this command never uploads data.
///
/// Flags:
///
///   * `--output=<directory>`: Directory to create.
///   * `--include-crash-dumps`: Copy crash dumps into the bundle. Dumps can
///     contain sensitive process memory and are excluded by default.
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var opts: Options = .{};
    defer opts.deinit();
    try args.parse(Options, alloc, &opts, &iter);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const result = try create(alloc, opts, &stdout_writer.interface);
    try stdout_writer.interface.flush();
    return result;
}

fn create(alloc: Allocator, opts: Options, stdout: *std.Io.Writer) !u8 {
    const generated_output = if (opts.output == null)
        try std.fmt.allocPrint(alloc, "noctty-diagnostic-bundle-{d}", .{@max(std.time.milliTimestamp(), 0)})
    else
        null;
    defer if (generated_output) |path| alloc.free(path);
    const output: []const u8 = opts.output orelse generated_output.?;

    // Never reuse a directory: a previous opt-in bundle may contain crash
    // dumps that a later redacted invocation must not accidentally retain.
    try std.fs.cwd().makeDir(output);
    const output_absolute = try std.fs.cwd().realpathAlloc(alloc, output);
    defer alloc.free(output_absolute);

    var reports: usize = 0;
    reports += try collectCrashDir(alloc, output_absolute, try crash.defaultDir(alloc), opts.@"include-crash-dumps");
    reports += try collectCrashDir(alloc, output_absolute, try crash.legacyGhosttyDir(alloc), opts.@"include-crash-dumps");

    const manifest_path = try std.fs.path.join(alloc, &.{ output_absolute, "manifest.json" });
    defer alloc.free(manifest_path);
    const manifest_file = try std.fs.createFileAbsolute(manifest_path, .{ .truncate = true });
    defer manifest_file.close();

    var file_buf: [4096]u8 = undefined;
    var file_writer = manifest_file.writer(&file_buf);
    try std.json.Stringify.value(Manifest{
        .conpty = pty.conPtyInfo(),
        .crash_report_count = reports,
        .crash_dumps_included = opts.@"include-crash-dumps",
    }, .{ .whitespace = .indent_2 }, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();

    try stdout.print("Diagnostic bundle created at {s}\n", .{output});
    return 0;
}

fn collectCrashDir(
    alloc: Allocator,
    output: []const u8,
    crash_dir: crash.Dir,
    include_dumps: bool,
) !usize {
    defer alloc.free(crash_dir.path);
    var iterator = try crash_dir.iterator();
    defer iterator.deinit();

    var count: usize = 0;
    while (try iterator.next()) |report| {
        count += 1;
        if (!include_dumps) continue;

        const destination_dir = try std.fs.path.join(alloc, &.{ output, "crash-dumps" });
        defer alloc.free(destination_dir);
        try std.fs.cwd().makePath(destination_dir);

        const source = try std.fs.path.join(alloc, &.{ crash_dir.path, report.name });
        defer alloc.free(source);
        const destination = try std.fs.path.join(alloc, &.{ destination_dir, report.name });
        defer alloc.free(destination);
        try std.fs.copyFileAbsolute(source, destination, .{});
    }
    return count;
}

test "diagnostic manifest defaults exclude sensitive data" {
    const manifest: Manifest = .{
        .conpty = pty.conPtyInfo(),
        .crash_report_count = 0,
        .crash_dumps_included = false,
    };
    try std.testing.expectEqualStrings("noctty.diagnostics.v1", manifest.schema);
    try std.testing.expect(!manifest.crash_dumps_included);
    try std.testing.expect(!manifest.privacy.terminal_content);
    try std.testing.expect(!manifest.privacy.commands);
    try std.testing.expect(!manifest.privacy.environment);
    try std.testing.expect(!manifest.privacy.working_directories);
    try std.testing.expect(!manifest.privacy.config_values);
    if (builtin.os.tag == .windows) try std.testing.expect(manifest.conpty != null);
}

test "diagnostic crash dump copy uses canonical output path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("crash");
    try tmp.dir.writeFile(.{ .sub_path = "crash/report.dmp", .data = "test dump" });
    try tmp.dir.makePath("bundle");

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const crash_path = try std.fs.path.join(alloc, &.{ root, "crash" });
    const output_path = try std.fs.path.join(alloc, &.{ root, "bundle" });
    defer alloc.free(output_path);

    try std.testing.expectEqual(@as(usize, 1), try collectCrashDir(
        alloc,
        output_path,
        .{ .path = crash_path },
        true,
    ));

    const copied = try tmp.dir.readFileAlloc(alloc, "bundle/crash-dumps/report.dmp", 1024);
    defer alloc.free(copied);
    try std.testing.expectEqualStrings("test dump", copied);
}
