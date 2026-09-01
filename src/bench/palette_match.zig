//! Microbench: command palette fuzzy-match latency.
//!
//! Stress-tests the production `Catalog.rank` path used by the live Win32
//! palette. The synthetic catalog is built before timing; each sample covers
//! the same allocation-free full-catalog scan, scoring, bounded top-K, and
//! stable sort that runs for a palette query in the application.
//!
//! Reports min / mean / p50 / p99 / max in microseconds and exits
//! non-zero when p99 exceeds the budget. Intended as a CI regression
//! guardrail.
//!
//! Usage:
//!   zig build bench:palette-match -- \
//!       --entries=500 --keystrokes=1000 --budget-us=1000

const std = @import("std");
const palette = @import("bench_core").win32_palette;
const stats = @import("stats.zig");

const Catalog = palette.catalog.Catalog;
const Item = palette.catalog.Item;
const Payload = palette.catalog.Payload;
const Ranked = palette.catalog.Ranked;

const Args = struct {
    entries: usize = 500,
    keystrokes: usize = 1000,
    budget_us: u64 = 1000,
};

const Entry = struct {
    title: []const u8,
    action: []const u8,
};

// Representative catalogue shaped like input.command.defaults. Kept
// small enough that synthetic padding via `--entries=N` scales
// predictably to any target size.
const seed_entries = [_]Entry{
    .{ .title = "New Tab", .action = "new_tab" },
    .{ .title = "New Window", .action = "new_window" },
    .{ .title = "Split Left", .action = "new_split:left" },
    .{ .title = "Split Right", .action = "new_split:right" },
    .{ .title = "Split Up", .action = "new_split:up" },
    .{ .title = "Split Down", .action = "new_split:down" },
    .{ .title = "Close Tab", .action = "close_tab:this" },
    .{ .title = "Close Other Tabs", .action = "close_tab:other" },
    .{ .title = "Close Window", .action = "close_window" },
    .{ .title = "Close All Windows", .action = "close_all_windows" },
    .{ .title = "Toggle Fullscreen", .action = "toggle_fullscreen" },
    .{ .title = "Toggle Window Decorations", .action = "toggle_window_decorations" },
    .{ .title = "Toggle Tab Overview", .action = "toggle_tab_overview" },
    .{ .title = "Toggle Split Zoom", .action = "toggle_split_zoom" },
    .{ .title = "Toggle Readonly", .action = "toggle_readonly" },
    .{ .title = "Toggle Maximize", .action = "toggle_maximize" },
    .{ .title = "Toggle Secure Input", .action = "toggle_secure_input" },
    .{ .title = "Toggle Mouse Reporting", .action = "toggle_mouse_reporting" },
    .{ .title = "Toggle Background Opacity", .action = "toggle_background_opacity" },
    .{ .title = "Focus Split: Left", .action = "goto_split:left" },
    .{ .title = "Focus Split: Right", .action = "goto_split:right" },
    .{ .title = "Focus Split: Up", .action = "goto_split:up" },
    .{ .title = "Focus Split: Down", .action = "goto_split:down" },
    .{ .title = "Focus Split: Previous", .action = "goto_split:previous" },
    .{ .title = "Focus Split: Next", .action = "goto_split:next" },
    .{ .title = "Equalize Splits", .action = "equalize_splits" },
    .{ .title = "Reset Window Size", .action = "reset_window_size" },
    .{ .title = "Reset Terminal", .action = "reset" },
    .{ .title = "Clear Screen", .action = "clear_screen" },
    .{ .title = "Select All", .action = "select_all" },
    .{ .title = "Copy to Clipboard", .action = "copy_to_clipboard:mixed" },
    .{ .title = "Copy Selection as Plain Text to Clipboard", .action = "copy_to_clipboard:plain" },
    .{ .title = "Copy Selection as HTML to Clipboard", .action = "copy_to_clipboard:html" },
    .{ .title = "Copy URL to Clipboard", .action = "copy_url_to_clipboard" },
    .{ .title = "Paste from Clipboard", .action = "paste_from_clipboard" },
    .{ .title = "Paste from Selection", .action = "paste_from_selection" },
    .{ .title = "Start Search", .action = "start_search" },
    .{ .title = "Search Selection", .action = "search_selection" },
    .{ .title = "End Search", .action = "end_search" },
    .{ .title = "Next Search Result", .action = "navigate_search:next" },
    .{ .title = "Previous Search Result", .action = "navigate_search:previous" },
    .{ .title = "Increase Font Size", .action = "increase_font_size:1" },
    .{ .title = "Decrease Font Size", .action = "decrease_font_size:1" },
    .{ .title = "Reset Font Size", .action = "reset_font_size" },
    .{ .title = "Scroll to Top", .action = "scroll_to_top" },
    .{ .title = "Scroll to Bottom", .action = "scroll_to_bottom" },
    .{ .title = "Scroll Page Up", .action = "scroll_page_up" },
    .{ .title = "Scroll Page Down", .action = "scroll_page_down" },
    .{ .title = "Open Config", .action = "open_config" },
    .{ .title = "Reload Config", .action = "reload_config" },
    .{ .title = "Toggle Inspector", .action = "inspector:toggle" },
    .{ .title = "Undo", .action = "undo" },
    .{ .title = "Redo", .action = "redo" },
    .{ .title = "Quit", .action = "quit" },
    .{ .title = "Check for Updates", .action = "check_for_updates" },
};

const queries = [_][]const u8{
    "n",
    "ne",
    "new",
    "new_",
    "new_t",
    "new_tab",
    "t",
    "tog",
    "toggle",
    "toggle_f",
    "toggle_fullscreen",
    "fs",
    "copy",
    "copy html",
    "paste",
    "search",
    "next",
    "prev",
    "reload",
    "close",
    "open config",
    "scrol",
    "inspec",
    "reset",
    "quit",
    ">new",
    "window decorations",
};

const max_ranked: usize = 256;

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args_raw = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args_raw);

    const args = try parseArgs(args_raw);
    const n = @max(args.entries, seed_entries.len);

    const item_storage = try alloc.alloc(Item, n);
    const payload_storage = try alloc.alloc(Payload, n);
    var catalog = try Catalog.init(item_storage, payload_storage);
    for (0..n) |i| {
        const seed = seed_entries[i % seed_entries.len];
        try catalog.append(.{
            .item = .{
                .id = .{ .kind = .action, .value = @intCast(i + 1) },
                .title = seed.title,
                .subtitle = seed.action,
                .keywords = seed.action,
                .enabled = i % 17 != 0,
                .disabled_reason = if (i % 17 == 0) "Unavailable in this context" else null,
                .recency = if (i % 13 == 0)
                    .{ .mru_rank = @intCast(i % 100), .use_count = @intCast(i % 101) }
                else
                    .{},
            },
            .payload = .{ .action = .{ .action = seed.action } },
        });
    }

    const samples = try alloc.alloc(u64, args.keystrokes);
    var buf: [max_ranked]Ranked = undefined;

    // Warm-up to stabilise first-call cost.
    for (0..@min(args.keystrokes, 16)) |i| {
        _ = catalog.rank(
            queries[i % queries.len],
            .{ .max_results = buf.len },
            &buf,
        );
    }

    var timer = try std.time.Timer.start();
    for (0..args.keystrokes) |i| {
        const q = queries[i % queries.len];
        timer.reset();
        _ = catalog.rank(q, .{ .max_results = buf.len }, &buf);
        samples[i] = timer.read();
    }

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const min_ns = stats.min(samples).?;
    const p50_ns = stats.percentile(samples, 50).?;
    const p99_ns = stats.percentile(samples, 99).?;
    const max_ns = stats.max(samples).?;
    const mean_ns: u64 = @intFromFloat(stats.mean(samples).?);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        \\bench:palette-match
        \\  entries    = {d}
        \\  keystrokes = {d}
        \\  budget_us  = {d}
        \\  min        = {d} us
        \\  mean       = {d} us
        \\  p50        = {d} us
        \\  p99        = {d} us
        \\  max        = {d} us
        \\
    , .{
        n,
        args.keystrokes,
        args.budget_us,
        min_ns / std.time.ns_per_us,
        mean_ns / std.time.ns_per_us,
        p50_ns / std.time.ns_per_us,
        p99_ns / std.time.ns_per_us,
        max_ns / std.time.ns_per_us,
    });

    const p99_us = p99_ns / std.time.ns_per_us;
    if (p99_us > args.budget_us) {
        try stdout.print(
            "  status     = REGRESSION: p99 {d} us > budget {d} us\n",
            .{ p99_us, args.budget_us },
        );
        try stdout.flush();
        std.process.exit(1);
    }
    try stdout.print("  status     = OK\n", .{});
    try stdout.flush();
}

fn parseArgs(raw: []const []const u8) !Args {
    var out: Args = .{};
    for (raw[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--entries=")) {
            out.entries = try std.fmt.parseInt(usize, arg["--entries=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--keystrokes=")) {
            out.keystrokes = try std.fmt.parseInt(usize, arg["--keystrokes=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--budget-us=")) {
            out.budget_us = try std.fmt.parseInt(u64, arg["--budget-us=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else {
            std.log.warn("bench:palette-match: unknown arg '{s}' — ignoring", .{arg});
        }
    }
    if (out.keystrokes == 0) return error.InvalidArgument;
    return out;
}

fn printHelp() !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\bench:palette-match — command palette fuzzy-match latency microbench
        \\
        \\Flags:
        \\  --entries=N        Synthetic snapshot size; padded from a seed catalogue (default 500).
        \\  --keystrokes=N     Queries timed (default 1000). Must be at least 1.
        \\  --budget-us=N      p99 budget in microseconds (default 1000). Exits non-zero on regression.
        \\  -h, --help         Print this help.
        \\
    );
    try stdout.flush();
}

test "palette match rejects a zero keystroke count" {
    try std.testing.expectError(
        error.InvalidArgument,
        parseArgs(&.{ "bench-palette-match", "--keystrokes=0" }),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        (try parseArgs(&.{ "bench-palette-match", "--keystrokes=1" })).keystrokes,
    );
}
