const std = @import("std");
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const actionpkg = @import("action.zig");

const list_fonts = @import("list_fonts.zig");
const help = @import("help.zig");
const version = @import("version.zig");
const list_keybinds = @import("list_keybinds.zig");
const list_themes = @import("list_themes.zig");
const list_colors = @import("list_colors.zig");
const list_actions = @import("list_actions.zig");
const vt_probe = @import("vt_probe.zig");
const ssh_cache = @import("ssh_cache.zig");
const edit_config = @import("edit_config.zig");
const show_config = @import("show_config.zig");
const explain_config = @import("explain_config.zig");
const validate_config = @import("validate_config.zig");
const crash_report = @import("crash_report.zig");
const show_face = @import("show_face.zig");
const boo = @import("boo.zig");
const new_window = @import("new_window.zig");
const list_windows = @import("list_windows.zig");

pub const Action = @import("ghostty_action.zig").Action;

pub fn requiresTerminalUi(self: Action) bool {
    return self == .boo;
}

/// Run the action. This returns the exit code to exit with.
pub fn run(self: Action, alloc: Allocator) !u8 {
    return runMain(self, alloc) catch |err| switch (err) {
        // If help is requested, then we use some comptime trickery
        // to find this action in the help strings and output that.
        Action.help_error => printActionHelp(self),
        else => err,
    };
}

fn printActionHelp(self: Action) !u8 {
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        // All action help text is emitted through this shared path.
        if (self == @field(Action, field.name)) {
            var buffer: [1024]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&buffer);
            const stdout = &stdout_writer.interface;
            const text = @field(help_strings.Action, field.name) ++ "\n";
            stdout.writeAll(text) catch return error.ActionHelpOutputUnavailable;
            stdout.flush() catch return error.ActionHelpOutputUnavailable;
            return 0;
        }
    }

    unreachable;
}

fn runMain(self: Action, alloc: Allocator) !u8 {
    return switch (self) {
        .version => try version.run(alloc),
        .help => try help.run(alloc),
        .@"list-fonts" => try list_fonts.run(alloc),
        .@"list-keybinds" => try list_keybinds.run(alloc),
        .@"list-themes" => try list_themes.run(alloc),
        .@"list-colors" => try list_colors.run(alloc),
        .@"list-actions" => try list_actions.run(alloc),
        .@"vt-probe" => try vt_probe.run(alloc),
        .@"ssh-cache" => try ssh_cache.run(alloc),
        .@"edit-config" => try edit_config.run(alloc),
        .@"show-config" => try show_config.run(alloc),
        .@"explain-config" => try explain_config.run(alloc),
        .@"validate-config" => try validate_config.run(alloc),
        .@"crash-report" => try crash_report.run(alloc),
        .@"show-face" => try show_face.run(alloc),
        .boo => try boo.run(alloc),
        .@"new-window" => try new_window.run(alloc),
        .@"list-windows" => try list_windows.run(alloc),
    };
}

/// Returns the options of action. Supports generating shell completions
/// without duplicating the mapping from Action to relevant Option
/// @import(..) declaration.
pub fn options(comptime self: Action) type {
    comptime {
        return switch (self) {
            .version => version.Options,
            .help => help.Options,
            .@"list-fonts" => list_fonts.Options,
            .@"list-keybinds" => list_keybinds.Options,
            .@"list-themes" => list_themes.Options,
            .@"list-colors" => list_colors.Options,
            .@"list-actions" => list_actions.Options,
            .@"vt-probe" => vt_probe.options,
            .@"ssh-cache" => ssh_cache.Options,
            .@"edit-config" => edit_config.Options,
            .@"show-config" => show_config.Options,
            .@"explain-config" => explain_config.Options,
            .@"validate-config" => validate_config.Options,
            .@"crash-report" => crash_report.Options,
            .@"show-face" => show_face.Options,
            .boo => boo.Options,
            .@"new-window" => new_window.Options,
            .@"list-windows" => list_windows.Options,
        };
    }
}

test "parse action none" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        alloc,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    const action = try actionpkg.detectIter(Action, &iter);
    try testing.expect(action == null);
}

test "parse action version" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false --version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d --version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
}

test "parse action plus" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false +version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "+version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d +version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action.? == .version);
    }
}

test "parse action plus ignores -e" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 -e +version",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action == null);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "+list-fonts --a=42 -e +version",
        );
        defer iter.deinit();
        try testing.expectError(
            actionpkg.DetectError.MultipleActions,
            actionpkg.detectIter(Action, &iter),
        );
    }
}

test "terminal UI actions are classified separately" {
    const testing = std.testing;

    try testing.expect(requiresTerminalUi(.boo));

    try testing.expect(!requiresTerminalUi(.@"list-keybinds"));
    try testing.expect(!requiresTerminalUi(.@"list-themes"));
    try testing.expect(!requiresTerminalUi(.@"list-colors"));
    try testing.expect(!requiresTerminalUi(.help));
    try testing.expect(!requiresTerminalUi(.version));
    try testing.expect(!requiresTerminalUi(.@"show-config"));
    try testing.expect(!requiresTerminalUi(.@"crash-report"));
}

test "vt-probe action is registered" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const probe = std.meta.stringToEnum(Action, "vt-probe");
    try testing.expect(probe != null);
    try testing.expect(@hasDecl(help_strings.Action, "vt-probe"));

    if (probe) |expected| {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "+vt-probe",
        );
        defer iter.deinit();
        const action = try actionpkg.detectIter(Action, &iter);
        try testing.expect(action != null);
        try testing.expectEqual(expected, action.?);
    }
}
