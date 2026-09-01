const builtin = @import("builtin");

/// Whether CLI actions may render their output through the vaxis TUI instead of
/// writing plain text.
///
/// Windows is excluded: the vaxis pretty-print path draws nothing usable on a
/// Windows console, so `+list-keybinds`, `+list-colors` and `+list-themes`
/// produced blank output whenever stdout was a terminal (issue #178). The plain
/// text renderer these actions fall back to is correct on every console.
pub const can_pretty_print = switch (builtin.os.tag) {
    .ios, .tvos, .watchos, .windows => false,
    else => true,
};
