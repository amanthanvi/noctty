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

const help_prelude =
    \\Usage: winghostty [+action] [options]
    \\
    \\Run the Windows-native winghostty terminal or a specific helper action.
    \\
    \\If no `+action` is specified, run `winghostty.exe`.
    \\All configuration keys are available as command line options.
    \\To specify a configuration key, use the `--<key>=<value>` syntax
    \\where key and value are the same format you'd put into a configuration
    \\file. For example, `--font-size=12` or `--font-family="Fira Code"`.
    \\
    \\Discover configuration from the CLI:
    \\  `winghostty +show-config --default --docs` lists every config key and its docs.
    \\  `winghostty +explain-config <option>` explains one config key.
    \\  `winghostty +explain-config --keybind=<action>` explains one keybind action.
    \\
    \\A special command line argument `-e <command>` can be used to run
    \\the specific command inside the terminal emulator. For example,
    \\`winghostty -e top` will run the `top` command inside the terminal.
    \\
    \\Discover actions and keybindings:
    \\  `winghostty +list-actions --docs` lists bindable actions with docs.
    \\  `winghostty +list-keybinds --default` shows the shipped default bindings.
    \\  `winghostty +list-keybinds --docs` annotates bindings with action docs.
    \\
    \\Useful Windows actions:
    \\  `winghostty +new-window` forwards into the running instance when possible.
    \\  `winghostty +list-windows` prints local automation window IDs as JSON.
    \\  `winghostty +perform-action new_tab` forwards a safe UI action.
    \\  `winghostty +edit-config` opens the config file in your default editor.
    \\
    \\Available actions:
    \\
    \\
;

/// The `help` command shows general help about winghostty. Recognized as either
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
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "Windows-native winghostty terminal") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "winghostty.exe") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "src/config/Config.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, help_prelude, "future update") == null);
}
