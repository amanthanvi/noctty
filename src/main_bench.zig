const benchmark = @import("benchmark/main.zig");

pub const synthetic = @import("synthetic/main.zig");
pub const terminal = @import("terminal/main.zig");

pub const main = benchmark.cli.main;
