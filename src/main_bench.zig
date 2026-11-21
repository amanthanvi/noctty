const benchmark = @import("benchmark/main.zig");

pub const synthetic = @import("synthetic/main.zig");
pub const terminal = @import("terminal/main.zig");
/// The thread roles the renderer-state mutex reads, for the search
/// benchmark's fixture scopes: the benchmarks build without the layer, so
/// they compile to nothing (PLAN.md §2.7 acceptance test 14).
pub const thread_role = @import("sync/thread_role.zig");
pub const win32_palette = @import("apprt/win32_palette.zig");

pub const main = benchmark.cli.main;
