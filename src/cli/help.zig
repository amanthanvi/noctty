const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty_action.zig").Action;

// Note that this options struct doesn't implement the `help` decl like other
// actions. That is because the help command is special and wants to handle its
// own logic around help detection.
pub const Options = struct {
    /// This must be registered so that it isn't an error to pass `--help`
    help: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

pub const keybinding_discovery_hint =
    \\  `koreterm +explain-config --keybind=<action>` explains one keybind action.
    \\  `koreterm +list-actions --docs` lists bindable actions with docs.
    \\  `koreterm +list-keybinds --default` shows the shipped default bindings.
    \\  `koreterm +list-keybinds --docs` annotates bindings with action docs.
;

const help_prelude =
    \\Usage: koreterm [+action] [options]
    \\
    \\Run the Windows-native koreterm terminal or a specific helper action.
    \\
    \\If no `+action` is specified, run `koreterm.exe`.
    \\All configuration keys are available as command line options.
    \\To specify a configuration key, use the `--<key>=<value>` syntax
    \\where key and value are the same format you'd put into a configuration
    \\file. For example, `--font-size=12` or `--font-family="Fira Code"`.
    \\
    \\Discover configuration from the CLI:
    \\  `koreterm +show-config --default --docs` lists every config key and its docs.
    \\  `koreterm +explain-config <option>` explains one config key.
    \\
    \\A special command line argument `-e <command>` can be used to run
    \\the specific command inside the terminal emulator. For example,
    \\`koreterm -e top` will run the `top` command inside the terminal.
    \\
    \\Discover actions and keybindings:
    \\
++ keybinding_discovery_hint ++
    \\
    \\Useful Windows actions:
    \\  `koreterm +new-window` forwards into the running instance when possible.
    \\  `koreterm +list-windows` prints local automation window IDs as JSON.
    \\  `koreterm +list-profiles` prints the profile keys that `default-profile` takes.
    \\  `koreterm +perform-action new_tab` forwards a safe UI action.
    \\  `koreterm --safe-mode` uses built-in config and skips session restore.
    \\  `koreterm +diagnostic-bundle` creates a local redacted support bundle.
    \\  `koreterm +edit-config` opens the config file in your default editor.
    \\
    \\Available actions:
    \\
    \\
;

/// The `help` command shows general help about koreterm. Recognized as either
/// `-h, `--help`, or like other actions `+help`.
///
/// You can also specify `--help` or `-h` along with any action such as
/// `+list-themes` to see help for a specific action.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(help_prelude);

    inline for (@typeInfo(Action).@"enum".fields) |field| {
        try stdout.print("  +{s}\n", .{field.name});
    }

    try stdout.writeAll(
        \\
        \\Specify `+<action> --help` to see the help for a specific action,
        \\where `<action>` is one of actions listed above.
        \\
    );
    try stdout.flush();

    return 0;
}

test "help prelude is Windows-only" {
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "Windows-native koreterm terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "koreterm.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "Ghostty.app") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "open -na") == null);
}

test "help prelude points to CLI discovery commands" {
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+show-config --default --docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+explain-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+explain-config --keybind=<action>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+list-actions --docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+list-keybinds --default") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+list-keybinds --docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "--safe-mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+diagnostic-bundle") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "+list-profiles") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "src/config/Config.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "future update") == null);
}
