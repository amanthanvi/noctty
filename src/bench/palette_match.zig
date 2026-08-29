//! Microbench: command palette fuzzy-match latency.
//!
//! Stress-tests the zf-backed ranker used by the live palette. The
//! ranker logic here is a near-duplicate of `src/apprt/win32_palette.zig`
//! — kept inline so the bench exe stays free of cross-module imports
//! (Zig compiles each target as its own module root, and the live
//! palette's helpers reach into the input catalogue + Win32 types that
//! aren't part of a clean bench graph).
//!
//! Reports min / mean / p50 / p99 / max in microseconds and exits
//! non-zero when p99 exceeds the budget. Intended as a CI regression
//! guardrail.
//!
//! Usage:
//!   zig build bench:palette-match -- \
//!       --entries=500 --keystrokes=1000 --budget-us=1000

const std = @import("std");
const zf = @import("zf");
const stats = @import("stats.zig");

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
};

const max_tokens: usize = 8;
const max_ranked: usize = 256;

fn tokenize(query: []const u8, buf: *[max_tokens][]const u8) []const []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, query, " \t");
    while (it.next()) |tok| {
        if (n >= buf.len) break;
        buf[n] = tok;
        n += 1;
    }
    return buf[0..n];
}

fn rankEntry(entry: Entry, tokens: []const []const u8) ?f64 {
    const opts: zf.RankOptions = .{ .to_lower = true, .plain = true };
    const t = zf.rank(entry.title, tokens, opts);
    const a = zf.rank(entry.action, tokens, opts);
    if (t) |tr| {
        if (a) |ar| return @min(tr, ar);
        return tr;
    }
    return a;
}

const Ranked = struct { index: usize, rank: f64 };

fn rankedForQuery(
    entries: []const Entry,
    query: []const u8,
    buf: *[max_ranked]Ranked,
) []Ranked {
    var token_buf: [max_tokens][]const u8 = undefined;
    const tokens = tokenize(query, &token_buf);
    if (tokens.len == 0) return buf[0..0];

    // Mirror win32_palette.rankedForQuery: full scan, keep top-K by
    // replacing the current worst when a better rank arrives. The
    // first-N-match shortcut would hide later (better) matches when
    // the palette grows past max_ranked.
    var count: usize = 0;
    var worst_i: usize = 0;
    for (entries, 0..) |e, i| {
        const r = rankEntry(e, tokens) orelse continue;
        if (count < buf.len) {
            buf[count] = .{ .index = i, .rank = r };
            if (count == 0 or r > buf[worst_i].rank) worst_i = count;
            count += 1;
            continue;
        }
        if (r >= buf[worst_i].rank) continue;
        buf[worst_i] = .{ .index = i, .rank = r };
        worst_i = 0;
        var j: usize = 1;
        while (j < buf.len) : (j += 1) {
            if (buf[j].rank > buf[worst_i].rank) worst_i = j;
        }
    }
    const slice = buf[0..count];
    std.mem.sort(Ranked, slice, {}, struct {
        fn lt(_: void, a: Ranked, b: Ranked) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return a.index < b.index;
        }
    }.lt);
    return slice;
}

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args_raw = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args_raw);

    const args = try parseArgs(args_raw);
    const n = @max(args.entries, seed_entries.len);

    const entries = try alloc.alloc(Entry, n);
    for (entries, 0..) |*e, i| e.* = seed_entries[i % seed_entries.len];

    const samples = try alloc.alloc(u64, args.keystrokes);
    var buf: [max_ranked]Ranked = undefined;

    // Warm-up to stabilise first-call cost.
    for (0..@min(args.keystrokes, 16)) |i| {
        _ = rankedForQuery(entries, queries[i % queries.len], &buf);
    }

    var timer = try std.time.Timer.start();
    for (0..args.keystrokes) |i| {
        const q = queries[i % queries.len];
        timer.reset();
        _ = rankedForQuery(entries, q, &buf);
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
        \\  --keystrokes=N     Queries timed (default 1000).
        \\  --budget-us=N      p99 budget in microseconds (default 1000). Exits non-zero on regression.
        \\  -h, --help         Print this help.
        \\
    );
    try stdout.flush();
}
