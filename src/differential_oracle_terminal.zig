//! Same Terminal implementation and terminal_options as the app build.
const terminal = @import("terminal/main.zig");
pub const Terminal = terminal.Terminal;
pub const formatter = terminal.formatter;
pub const options = @import("terminal_options");
