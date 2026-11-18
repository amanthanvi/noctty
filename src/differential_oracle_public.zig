//! Use upstream's public lib-vt API and its exact generated option module.
const vt = @import("public-vt");
pub const Terminal = vt.Terminal;
pub const formatter = vt.formatter;
pub const options = @import("terminal_options");
