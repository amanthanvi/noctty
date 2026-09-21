const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const os_windows = @import("../os/windows.zig");
const pty = @import("../pty.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");

const build_config_heading = "Build Config\n";
const platform_label = "  - platform      : ";
const architecture_label = "  - architecture  : ";
const event_backend_label = "  - event backend : ";
const custom_shaders_label = "  - custom shaders: ";
const conpty_label = "  - ConPTY        : ";

fn customShadersStatus(comptime enabled: bool) []const u8 {
    return if (enabled) "enabled" else "disabled";
}

/// Architecture line for the bug-report template.
///
/// The build architecture alone hides the case that matters on Windows on
/// ARM: an x64 build running under emulation behaves differently from a
/// native ARM64 build, and the reporter usually cannot tell which they have.
/// The native machine is added only when it differs, so the common line stays
/// short. A 64-byte `buf` always holds the result.
fn architectureText(buf: []u8, arch: ?os_windows.ProcessArchitecture) []const u8 {
    // The build machine is comptime-known, so its name is a static string and
    // is safe to return without a caller-owned buffer. The Zig target tag is
    // the fallback for an architecture `build_machine` has no code for.
    const build_name: []const u8 = comptime if (os_windows.build_machine ==
        os_windows.IMAGE_FILE_MACHINE_UNKNOWN)
        @tagName(builtin.target.cpu.arch)
    else
        os_windows.machineArchitectureName(os_windows.build_machine).?;

    const detected = arch orelse return build_name;
    if (!detected.emulated()) return build_name;

    var native_buf: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} (running on {s})", .{
        build_name,
        os_windows.machineArchitectureLabel(&native_buf, detected.native_machine),
    }) catch build_name;
}

pub const Options = struct {};

/// The `version` command is used to display information about noctty. Recognized as
/// either `+version` or `--version`.
pub fn run(alloc: Allocator) !u8 {
    _ = alloc;
    var buffer: [1024]u8 = undefined;
    const stdout_file: std.fs.File = .stdout();
    var stdout_writer = stdout_file.writer(&buffer);

    const stdout = &stdout_writer.interface;
    const tty = stdout_file.isTty();

    if (tty) if (build_config.version.build) |commit_hash| {
        try stdout.print(
            "\x1b]8;;https://github.com/amanthanvi/noctty/commit/{s}\x1b\\",
            .{commit_hash},
        );
    };
    try stdout.print("noctty {s}\n\n", .{build_config.version_string});
    if (tty) try stdout.print("\x1b]8;;\x1b\\", .{});

    try stdout.print("Version\n", .{});
    try stdout.print("  - version: {s}\n", .{build_config.version_string});
    try stdout.print("  - channel: {t}\n", .{build_config.release_channel});

    try stdout.writeAll(build_config_heading);
    try stdout.print("  - Zig version   : {s}\n", .{builtin.zig_version_string});
    try stdout.print("  - build mode    : {}\n", .{builtin.mode});
    try stdout.print("{s}{}\n", .{ platform_label, builtin.target.os.tag });
    var architecture_buf: [64]u8 = undefined;
    try stdout.print("{s}{s}\n", .{
        architecture_label,
        architectureText(&architecture_buf, os_windows.detectProcessArchitecture()),
    });
    if (pty.conPtyInfo()) |info| {
        try stdout.print("{s}{t}", .{ conpty_label, info.source });
        if (info.dll_path) |path| try stdout.print(" ({s})", .{path});
        try stdout.writeByte('\n');
    }
    try stdout.print("  - app runtime   : {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine   : {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer      : {}\n", .{renderer.Renderer});
    try stdout.print("{s}{t}\n", .{ event_backend_label, xev.backend });
    try stdout.print("{s}{s}\n", .{
        custom_shaders_label,
        customShadersStatus(build_config.custom_shaders),
    });

    // Don't forget to flush!
    try stdout.flush();
    return 0;
}

test "version output labels are Windows-facing" {
    try std.testing.expect(std.mem.indexOf(u8, build_config_heading, "Build Config") != null);
    try std.testing.expect(std.mem.indexOf(u8, platform_label, "platform") != null);
    try std.testing.expect(std.mem.indexOf(u8, event_backend_label, "event backend") != null);
    try std.testing.expect(std.mem.indexOf(u8, event_backend_label, "libxev") == null);
    try std.testing.expect(std.mem.indexOf(u8, custom_shaders_label, "custom shaders") != null);
    try std.testing.expect(std.mem.indexOf(u8, conpty_label, "ConPTY") != null);
    try std.testing.expect(std.mem.indexOf(u8, architecture_label, "architecture") != null);
    try std.testing.expectEqual(platform_label.len, architecture_label.len);
}

test "version custom shader status selection" {
    try std.testing.expectEqualStrings("enabled", customShadersStatus(true));
    try std.testing.expectEqualStrings("disabled", customShadersStatus(false));
}

test "version architecture names the native machine only when it differs" {
    var buf: [64]u8 = undefined;

    // A native run: the build architecture already says everything.
    const native = architectureText(&buf, .{
        .process_machine = os_windows.build_machine,
        .native_machine = os_windows.build_machine,
    });
    try std.testing.expect(std.mem.indexOf(u8, native, "running on") == null);
    try std.testing.expect(std.mem.indexOf(u8, native, "unknown") == null);
    try std.testing.expectEqualStrings(native, architectureText(&buf, null));

    // Emulation: a bug report has to show both halves. On Windows on ARM this
    // is the difference between "works" and "install the ARM64 build".
    const foreign: u16 = if (os_windows.build_machine == os_windows.IMAGE_FILE_MACHINE_ARM64)
        os_windows.IMAGE_FILE_MACHINE_AMD64
    else
        os_windows.IMAGE_FILE_MACHINE_ARM64;
    const emulated = architectureText(&buf, .{
        .process_machine = os_windows.build_machine,
        .native_machine = foreign,
    });
    var expected_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_buf, "{s} (running on {s})", .{
            native,
            os_windows.machineArchitectureName(foreign).?,
        }),
        emulated,
    );

    // An unreported native machine must not be rendered as "unknown".
    const unreported = architectureText(&buf, .{
        .process_machine = os_windows.build_machine,
        .native_machine = os_windows.IMAGE_FILE_MACHINE_UNKNOWN,
    });
    try std.testing.expectEqualStrings(native, unreported);
    try std.testing.expect(std.mem.indexOf(u8, unreported, "unknown") == null);
}
