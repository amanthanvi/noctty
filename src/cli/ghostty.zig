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
const diagnostic_bundle = @import("diagnostic_bundle.zig");
const show_face = @import("show_face.zig");
const new_window = @import("new_window.zig");
const list_windows = @import("list_windows.zig");
const perform_action = @import("perform_action.zig");
const register_default_terminal = @import("register_default_terminal.zig");
const unregister_default_terminal = @import("unregister_default_terminal.zig");
const focus = @import("focus.zig");
const send_text = @import("send_text.zig");
const new_tab = @import("new_tab.zig");
const new_split = @import("new_split.zig");
const register_shell_menu = @import("register_shell_menu.zig");
const unregister_shell_menu = @import("unregister_shell_menu.zig");

pub const Action = @import("ghostty_action.zig").Action;

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
        .@"diagnostic-bundle" => try diagnostic_bundle.run(alloc),
        .@"show-face" => try show_face.run(alloc),
        .@"new-window" => try new_window.run(alloc),
        .@"list-windows" => try list_windows.run(alloc),
        .@"perform-action" => try perform_action.run(alloc),
        .@"register-default-terminal" => try register_default_terminal.run(alloc),
        .@"unregister-default-terminal" => try unregister_default_terminal.run(alloc),
        .focus => try focus.run(alloc),
        .@"send-text" => try send_text.run(alloc),
        .@"new-tab" => try new_tab.run(alloc),
        .@"new-split" => try new_split.run(alloc),
        .@"register-shell-menu" => try register_shell_menu.run(alloc),
        .@"unregister-shell-menu" => try unregister_shell_menu.run(alloc),
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
            .@"diagnostic-bundle" => diagnostic_bundle.Options,
            .@"show-face" => show_face.Options,
            .@"new-window" => new_window.Options,
            .@"list-windows" => list_windows.Options,
            .@"perform-action" => perform_action.Options,
            .@"register-default-terminal" => register_default_terminal.Options,
            .@"unregister-default-terminal" => unregister_default_terminal.Options,
            .focus => focus.Options,
            .@"send-text" => send_text.Options,
            .@"new-tab" => new_tab.Options,
            .@"new-split" => new_split.Options,
            .@"register-shell-menu" => register_shell_menu.Options,
            .@"unregister-shell-menu" => unregister_shell_menu.Options,
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

test "parse send-text action ignores literal action-like payloads" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_][]const u8{
        "+send-text --surface-id=42 -- --version",
        "+send-text --surface-id=42 -- +focus",
    }) |args_text| {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, args_text);
        defer iter.deinit();
        try testing.expectEqual(Action.@"send-text", (try actionpkg.detectIter(Action, &iter)).?);
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
