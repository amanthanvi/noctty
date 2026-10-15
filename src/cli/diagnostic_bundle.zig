const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const actionpkg = @import("action.zig");
const args = @import("args.zig");
const build_config = @import("../build_config.zig");
const crash = @import("../crash/main.zig");
const pty = @import("../pty.zig");
const Config = @import("../config/Config.zig");
const config_file = @import("../config/file_load.zig");
const os_windows = @import("../os/windows.zig");
const xdg = @import("../os/xdg.zig");
const sys = @import("../apprt/win32/sys.zig");
const powershell = @import("../apprt/win32_powershell_install.zig");
const integration_sha256_hex = std.fmt.bytesToHex(powershell.integration_script_sha256, .lower);

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
    os_version: ?OsVersion = null,
    native_architecture: ?[]const u8 = null,
    emulated: ?bool = null,
    install_kind: InstallKind = .other,
    embedded_powershell_integration_sha256: []const u8 = &integration_sha256_hex,
    /// Recognized names written directly in default files, never values.
    /// Includes, themes and CLI overrides are deliberately not evaluated.
    config_key_names: ?[]const []const u8 = null,
    config_keys_scope: []const u8 = "default-files-only",
    conpty: ?pty.ConPtyInfo,
    crash_report_count: usize,
    crash_dumps_included: bool,
    privacy: Privacy = .{},
};

const OsVersion = struct {
    major: u32,
    minor: u32,
    build: u32,

    fn detect() ?OsVersion {
        if (builtin.os.tag != .windows) return null;
        var info = std.mem.zeroes(sys.RTL_OSVERSIONINFOW);
        info.dwOSVersionInfoSize = @sizeOf(sys.RTL_OSVERSIONINFOW);
        if (sys.RtlGetVersion(&info) < 0) return null;
        return .{ .major = info.dwMajorVersion, .minor = info.dwMinorVersion, .build = info.dwBuildNumber };
    }
};

const InstallKind = enum {
    portable,
    installer,
    other,

    fn classify(portable: bool, installer: bool) InstallKind {
        if (portable) return .portable;
        return if (installer) .installer else .other;
    }

    fn detect(alloc: Allocator) InstallKind {
        if (xdg.portableRoot(alloc) catch return .other) |root| {
            alloc.free(root);
            return classify(true, false);
        }
        if (builtin.os.tag != .windows) return .other;
        const exe_dir = std.fs.selfExeDirPathAlloc(alloc) catch return .other;
        defer alloc.free(exe_dir);
        return classify(false, os_windows.isInstallerManagedInstallDir(exe_dir));
    }
};

const ConfigKeys = std.EnumSet(Config.Key);

/// Bounded, names-only inspection. Do not use Config.load here: it creates
/// templates, consumes CLI arguments and can log configuration values/paths.
fn collectConfigKeyNames(alloc: Allocator) ![][]const u8 {
    const legacy = try config_file.legacyGhosttyDefaultXdgPath(alloc);
    defer alloc.free(legacy);
    const current = try config_file.defaultXdgPath(alloc);
    defer alloc.free(current);
    var keys = ConfigKeys.initEmpty();
    const legacy_exists = try scanConfigFile(alloc, legacy, &keys);
    const current_exists = try scanConfigFile(alloc, current, &keys);
    if (!legacy_exists and !current_exists) {
        const fallback = try config_file.legacyForkXdgPath(alloc);
        defer alloc.free(fallback);
        _ = try scanConfigFile(alloc, fallback, &keys);
    }
    return configKeyNames(alloc, keys);
}

fn scanConfigFile(alloc: Allocator, path: []const u8, keys: *ConfigKeys) !bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    if ((try file.stat()).kind != .file) return error.NotAFile;
    const bytes = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(bytes);
    try scanConfigBytes(alloc, bytes, keys);
    return true;
}

fn scanConfigBytes(alloc: Allocator, bytes: []const u8, keys: *ConfigKeys) !void {
    var decoded: ?[]u8 = null;
    defer if (decoded) |text| alloc.free(text);
    var text = bytes;
    if (bytes.len >= 2 and (std.mem.eql(u8, bytes[0..2], "\xff\xfe") or
        std.mem.eql(u8, bytes[0..2], "\xfe\xff")))
    {
        if (bytes.len % 2 != 0) return error.InvalidEncoding;
        const units = try alloc.alloc(u16, (bytes.len - 2) / 2);
        defer alloc.free(units);
        for (units, 0..) |*unit, i| {
            unit.* = std.mem.nativeToLittle(u16, std.mem.readInt(u16, bytes[2 + i * 2 ..][0..2], if (bytes[0] == 0xff) .little else .big));
        }
        decoded = try std.unicode.utf16LeToUtf8Alloc(alloc, units);
        text = decoded.?;
    } else if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) {
        text = text[3..];
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        // Bare boolean keys are valid config lines too. Values are never
        // interpreted, including when the line has no equals sign.
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse trimmed.len;
        const name = std.mem.trim(u8, trimmed[0..equals], " \t");
        const key = std.meta.stringToEnum(Config.Key, name) orelse continue;
        // The real loader ignores this one-shot CLI option in files.
        if (key == .@"launch-layout") continue;
        keys.insert(key);
    }
}

fn configKeyNames(alloc: Allocator, keys: ConfigKeys) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(alloc);
    var iterator = keys.iterator();
    while (iterator.next()) |key| try names.append(alloc, @tagName(key));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(alloc);
}

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
    std.fs.cwd().makeDir(output) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try stdout.writeAll("Diagnostic output already exists. Choose a new directory with --output=<directory>; existing bundles are never reused.\n");
            return 1;
        },
        else => return err,
    };
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
    const architecture = os_windows.detectProcessArchitecture();
    const key_names = collectConfigKeyNames(alloc) catch null;
    defer if (key_names) |names| alloc.free(names);
    try std.json.Stringify.value(Manifest{
        .os_version = OsVersion.detect(),
        .native_architecture = if (architecture) |value| os_windows.machineArchitectureName(value.native_machine) else null,
        .emulated = if (architecture) |value| if (value.native_machine == os_windows.IMAGE_FILE_MACHINE_UNKNOWN) null else value.emulated() else null,
        .install_kind = InstallKind.detect(alloc),
        .config_key_names = key_names,
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

test "diagnostic system metadata identifies the OS and embedded integration" {
    if (builtin.os.tag == .windows) {
        const version = OsVersion.detect() orelse return error.TestUnexpectedResult;
        try std.testing.expect(version.major >= 10);
        try std.testing.expect(version.build != 0);
    } else try std.testing.expect(OsVersion.detect() == null);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(powershell.integration_script, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(&hex, &integration_sha256_hex);
    try std.testing.expectEqual(InstallKind.portable, InstallKind.classify(true, true));
    try std.testing.expectEqual(InstallKind.portable, InstallKind.classify(true, false));
    try std.testing.expectEqual(InstallKind.installer, InstallKind.classify(false, true));
    try std.testing.expectEqual(InstallKind.other, InstallKind.classify(false, false));
}

test "diagnostic config scan emits recognized sorted names only" {
    const alloc = std.testing.allocator;
    var keys = ConfigKeys.initEmpty();
    try scanConfigBytes(alloc, "\xef\xbb\xbf# command = comment-secret\n" ++
        " font-size = 19\r\n" ++
        "env = TOKEN=secret-token\n" ++
        "command = pwsh -Command secret-command\n" ++
        "config-file = C:\\Users\\private-user\\secret.conf\n" ++
        "font-size =\n" ++ // Resets remain directly configured names.
        "focus-follows-mouse\n" ++ // A bare boolean is accepted by the loader.
        "unknown-bare-secret\n" ++
        "unknown-secret-key = secret-value\n" ++
        "launch-layout = private-layout\n" ++
        "# environment = secret-environment\n", &keys);
    const names = try configKeyNames(alloc, keys);
    defer alloc.free(names);
    try std.testing.expectEqual(@as(usize, 5), names.len);
    for (names, [_][]const u8{ "command", "config-file", "env", "focus-follows-mouse", "font-size" }) |actual, expected| {
        try std.testing.expectEqualStrings(expected, actual);
    }

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.json.Stringify.value(Manifest{
        .config_key_names = names,
        .os_version = .{ .major = 10, .minor = 0, .build = 26200 },
        .native_architecture = "ARM64",
        .emulated = true,
        .install_kind = .portable,
        .conpty = null,
        .crash_report_count = 0,
        .crash_dumps_included = false,
    }, .{}, &writer);
    const json = writer.buffered();
    for ([_][]const u8{ "secret", "private-user", "pwsh", "TOKEN", "dll_path" }) |value| {
        try std.testing.expect(std.mem.indexOf(u8, json, value) == null);
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings("ARM64", object.get("native_architecture").?.string);
    try std.testing.expect(object.get("emulated").?.bool);
    try std.testing.expectEqual(@as(i64, 26200), object.get("os_version").?.object.get("build").?.integer);
    try std.testing.expectEqualStrings("portable", object.get("install_kind").?.string);
    try std.testing.expectEqualStrings(&integration_sha256_hex, object.get("embedded_powershell_integration_sha256").?.string);
    try std.testing.expectEqualStrings("default-files-only", object.get("config_keys_scope").?.string);
}

test "diagnostic config scan supports UTF16 byte orders and missing files" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "\xff\xfef\x00o\x00n\x00t\x00-\x00s\x00i\x00z\x00e\x00=\x002\x000\x00\n\x00",
        "\xfe\xff\x00f\x00o\x00n\x00t\x00-\x00s\x00i\x00z\x00e\x00=\x002\x000\x00\n",
    }) |bytes| {
        var keys = ConfigKeys.initEmpty();
        try scanConfigBytes(alloc, bytes, &keys);
        try std.testing.expect(keys.contains(.@"font-size"));
        try std.testing.expectEqual(@as(usize, 1), keys.count());
    }
    for ([_][]const u8{ "\xff\xfef", "\xfe\xff\x00" }) |bytes| {
        var invalid_keys = ConfigKeys.initEmpty();
        try std.testing.expectError(error.InvalidEncoding, scanConfigBytes(alloc, bytes, &invalid_keys));
        try std.testing.expectEqual(@as(usize, 0), invalid_keys.count());
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "config.ghostty" });
    defer alloc.free(path);
    var keys = ConfigKeys.initEmpty();
    try std.testing.expect(!try scanConfigFile(alloc, path, &keys));
    try tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "" });
    // An empty default file still exists, so the caller must not load the
    // pre-rename fallback just because no keys were collected from it.
    try std.testing.expect(try scanConfigFile(alloc, path, &keys));
    try std.testing.expectEqual(@as(usize, 0), keys.count());
    try tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "font-size=22\n" });
    try std.testing.expect(try scanConfigFile(alloc, path, &keys));
    try std.testing.expect(keys.contains(.@"font-size"));
    const file = try tmp.dir.createFile("config.ghostty", .{});
    try file.setEndPos(1024 * 1024 + 1);
    file.close();
    try std.testing.expectError(error.FileTooBig, scanConfigFile(alloc, path, &keys));
}

test "diagnostic bundle existing output is refused with guidance" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "preserved.txt", .data = "existing bundle" });
    const output = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(output);
    const output_z = try alloc.dupeZ(u8, output);
    defer alloc.free(output_z);

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(u8, 1), try create(alloc, .{ .output = output_z }, &writer));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "already exists") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--output") != null);
    const preserved = try tmp.dir.readFileAlloc(alloc, "preserved.txt", 1024);
    defer alloc.free(preserved);
    try std.testing.expectEqualStrings("existing bundle", preserved);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("manifest.json", .{}));
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

    var json_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&json_buffer);
    var serialized_manifest = manifest;
    serialized_manifest.conpty = .{
        .source = .bundled,
        .dll_path = "C:\\Users\\example-user\\noctty\\conpty.dll",
    };
    try std.json.Stringify.value(serialized_manifest, .{}, &writer);
    const json = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "example-user") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "dll_path") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"conpty\":{\"source\":\"bundled\",\"fallback\":null}") != null);

    // An in-box selection records why, so a report shows a degraded build.
    writer = std.Io.Writer.fixed(&json_buffer);
    serialized_manifest.conpty = .{ .source = .inbox, .dll_path = null, .fallback = error.NotFound };
    try std.json.Stringify.value(serialized_manifest, .{}, &writer);
    try std.testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "\"conpty\":{\"source\":\"inbox\",\"fallback\":\"NotFound\"}",
    ) != null);
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
