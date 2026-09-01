//! Benchmark-only PTY end-marker observation.
//!
//! Nothing here is a product path. It exists so
//! `test/windows/bench-windows.ps1` can time interactive throughput to a causal
//! endpoint: ConPTY does not promise to preserve the producer's byte count, so
//! the benchmark child emits a unique visible
//! token after its payload and the harness needs to know the exact parsed
//! chunk at which that token became visible.
//!
//! This has to live on the terminal-parsing seam. The endpoint is defined as
//! "the marker is committed to the reconstructed visible grid", which only
//! exists after `processOutputLocked` has run under the renderer lock. There
//! is no other observation point that produces the same measurement, so this
//! is the one benchmark control that stays wired into `Termio`. It is inert
//! by default: without `NOCTTY_BENCH_END_MARKER` in the environment,
//! `bytes` is null and `observeVisible` is a single null check that returns
//! before touching terminal state.

const std = @import("std");
const Allocator = std.mem.Allocator;

const terminalpkg = @import("../terminal/main.zig");

pub const BenchmarkEndMarker = struct {
    bytes: ?[]const u8 = null,
    owned: bool = false,
    seen: bool = false,

    pub fn init(alloc: Allocator) BenchmarkEndMarker {
        const raw = std.process.getEnvVarOwned(
            alloc,
            "NOCTTY_BENCH_END_MARKER",
        ) catch return .{};

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            alloc.free(raw);
            return .{};
        }

        const owned = if (trimmed.len == raw.len)
            raw
        else
            alloc.dupe(u8, trimmed) catch {
                alloc.free(raw);
                return .{};
            };
        if (trimmed.len != raw.len) alloc.free(raw);
        return .{ .bytes = owned, .owned = true };
    }

    pub fn initForTest(bytes: []const u8) BenchmarkEndMarker {
        return .{ .bytes = bytes };
    }

    pub fn deinit(self: *BenchmarkEndMarker, alloc: Allocator) void {
        if (self.owned) if (self.bytes) |bytes| alloc.free(bytes);
        self.* = .{};
    }

    /// Returns true exactly once after the terminal parser has committed the
    /// configured marker at the start of the visible top row. Looking at the
    /// reconstructed grid is required because ConPTY may interleave cursor
    /// movement with visible text in its screen-diff output.
    pub fn observeVisible(
        self: *BenchmarkEndMarker,
        terminal: *const terminalpkg.Terminal,
    ) bool {
        const pattern = self.bytes orelse return false;
        if (self.seen or pattern.len == 0) return false;

        const top = terminal.screens.active.pages.getTopLeft(.viewport);
        const cells = top.cells(.right);
        if (pattern.len > cells.len) return false;
        for (pattern, cells[0..pattern.len]) |expected, cell| {
            if (cell.codepoint() != @as(u21, expected)) return false;
        }
        self.seen = true;
        return true;
    }
};

test "benchmark end marker is inert without the environment variable" {
    var marker: BenchmarkEndMarker = .{};
    var term = try terminalpkg.Terminal.init(std.testing.allocator, .{
        .cols = 30,
        .rows = 3,
    });
    defer term.deinit(std.testing.allocator);
    try std.testing.expect(!marker.observeVisible(&term));
}

test "benchmark end marker waits for reconstructed visible terminal state" {
    var term = try terminalpkg.Terminal.init(std.testing.allocator, .{
        .cols = 30,
        .rows = 3,
    });
    defer term.deinit(std.testing.allocator);
    var stream = term.vtStream();
    defer stream.deinit();

    var marker = BenchmarkEndMarker.initForTest("NB121DEADBEEFCAFE");
    stream.nextSlice("\x1b[1;1H\x1b[2KNB121DEAD");
    try std.testing.expect(!marker.observeVisible(&term));
    stream.nextSlice("\x1b[0mBEEFCAFE");
    try std.testing.expect(marker.observeVisible(&term));
    try std.testing.expect(!marker.observeVisible(&term));
}
