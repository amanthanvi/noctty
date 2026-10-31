//! Headless benchmark: scrollback search while output streams.
//!
//! Fills a Terminal's scrollback with log-like lines, most of which match
//! the needle, and drives the search thread's `Search` state the way the
//! search thread does (`notify`, `tick`, `feed` under the terminal lock).
//!
//! Two modes:
//!
//!   --mode=feed    Single-threaded. Times the initial search over the
//!                  prefilled history, then streams `--stream-mib` of new
//!                  lines and, after every `--refresh-kib` of output (the
//!                  renderer marks the viewport dirty on every frame and the
//!                  search thread refreshes every 24 ms), times one
//!                  `Search.feed` (active-area reload, history feed and the
//!                  match-row rebuild) plus the `notify` that follows it.
//!
//!   --mode=thread  The real search thread. Streams `--stream-mib` into the
//!                  terminal under the terminal lock, as the IO thread does,
//!                  with the search thread refreshing every 24 ms, and
//!                  compares the wall time and the writer's wait for the
//!                  lock with the same stream and no search. Pace it with
//!                  `--rate-mib-s` (a console host delivers a few MiB/s):
//!                  unpaced, a refresh covers megabytes of new output, so
//!                  the search of that output dominates, and a short stream
//!                  spans only a refresh or two.
//!
//! `--regex` and `--whole-word` search with those options, so every
//! searcher matches through the query's compiled pattern.
//!
//! Usage:
//!   zig build bench:search-stream -- --mode=feed --lines=100000 --runs=5
//!   zig build bench:search-stream -- --mode=thread --lines=100000 --stream-mib=8 --rate-mib-s=2 --runs=3

const std = @import("std");
const bench_core = @import("bench_core");
const terminal = bench_core.terminal;
const Terminal = terminal.Terminal;
const SearchThread = terminal.search.Thread;
const ThreadSearch = SearchThread.Search;
const stats = @import("stats.zig");

pub const std_options: std.Options = .{ .log_level = .err };

const Mode = enum { feed, thread };

const Args = struct {
    mode: Mode = .feed,
    /// Lines written to the scrollback before the search starts.
    lines: usize = 100_000,
    /// One line in this many contains the needle.
    match_every: usize = 1,
    /// Bytes per line including CRLF.
    line_len: usize = 90,
    /// Output streamed while the search is active.
    stream_mib: usize = 16,
    /// `--mode=feed`: output written between two refreshes.
    refresh_kib: usize = 32,
    runs: usize = 5,
    rows: u16 = 45,
    cols: u16 = 140,
    scrollback_mib: usize = 200,
    needle: []const u8 = "request",
    regex: bool = false,
    whole_word: bool = false,
    /// `--mode=thread`: output rate in MiB/s, as a producer such as a
    /// console host limits it; 0 streams as fast as the terminal takes it.
    rate_mib_s: f64 = 0,
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const args_alloc = arena.allocator();

    const args_raw = try std.process.argsAlloc(args_alloc);
    defer std.process.argsFree(args_alloc, args_raw);
    const args = try parseArgs(args_raw);

    const alloc = std.heap.c_allocator;
    const history = try buildLines(alloc, args, 0, args.lines);
    defer alloc.free(history);
    const stream_lines = (args.stream_mib * 1024 * 1024) / args.line_len;
    const streamed = try buildLines(alloc, args, args.lines, stream_lines);
    defer alloc.free(streamed);

    switch (args.mode) {
        .feed => try runFeed(alloc, args, history, streamed),
        .thread => try runThread(alloc, args, history, streamed),
    }
}

/// Log-like lines: `0001234 GET /api/items/1234 request status=200 ...`,
/// padded to `line_len`. Lines that should not match say `reply` instead.
fn buildLines(
    alloc: std.mem.Allocator,
    args: Args,
    first: usize,
    count: usize,
) ![]u8 {
    const out = try alloc.alloc(u8, count * args.line_len);
    errdefer alloc.free(out);
    for (0..count) |i| {
        const n = first + i;
        const line = out[i * args.line_len ..][0..args.line_len];
        @memset(line, '.');
        const word: []const u8 = if (n % args.match_every == 0) args.needle else "reply";
        _ = std.fmt.bufPrint(
            line[0 .. args.line_len - 2],
            "{d:0>8} GET /api/items/{d} {s} status={d} bytes={d} ",
            .{ n, n % 9973, word, 200 + (n % 5) * 100, n % 65536 },
        ) catch {
            // A cut line could lose the needle and measure another workload.
            std.log.err(
                "bench:search-stream: --line-len={d} is too short for the line text and --needle",
                .{args.line_len},
            );
            return error.InvalidArgument;
        };
        line[args.line_len - 2] = '\r';
        line[args.line_len - 1] = '\n';
    }
    return out;
}

fn initTerminal(alloc: std.mem.Allocator, args: Args) !Terminal {
    return try .init(alloc, .{
        .rows = args.rows,
        .cols = args.cols,
        .max_scrollback = args.scrollback_mib * 1024 * 1024,
    });
}

fn writeAll(t: *Terminal, bytes: []const u8) void {
    var stream = t.vtStream();
    defer stream.deinit();
    nextSliceChunked(&stream, bytes);
}

/// Feed `bytes` to `stream` in 4 KiB writes.
fn nextSliceChunked(stream: anytype, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 4096, bytes.len);
        stream.nextSlice(bytes[offset..end]);
        offset = end;
    }
}

/// Stands in for the surface's search callback: the surface copies every
/// match-row snapshot into a message for the app thread.
const Sink = struct {
    alloc: std.mem.Allocator,
    row_messages: usize = 0,
    row_values: usize = 0,
    total: usize = 0,
    complete: std.Thread.ResetEvent = .{},

    fn callback(event: SearchThread.Event, _: u64, ud: ?*anyopaque) void {
        const self: *Sink = @ptrCast(@alignCast(ud.?));
        switch (event) {
            .match_rows => |rows| {
                const copy = self.alloc.dupe(u32, rows) catch return;
                self.alloc.free(copy);
                self.row_messages += 1;
                self.row_values += rows.len;
            },
            .total_matches => |v| self.total = v,
            .complete => self.complete.set(),
            else => {},
        }
    }
};

/// Feed the search, then run the search thread's loop until it completes.
fn searchUntilComplete(
    alloc: std.mem.Allocator,
    search: *ThreadSearch,
    t: *Terminal,
    sink: *Sink,
) void {
    search.feed(alloc, t);
    while (true) {
        search.notify(alloc, &Sink.callback, 1, sink, false);
        if (search.isComplete()) break;
        switch (search.tick()) {
            .complete, .progress => {},
            .blocked => search.feed(alloc, t),
        }
    }
}

fn runFeed(
    alloc: std.mem.Allocator,
    args: Args,
    history: []const u8,
    streamed: []const u8,
) !void {
    const runs = args.runs;
    const initial_ms = try alloc.alloc(f64, runs);
    defer alloc.free(initial_ms);
    var refresh_all: std.ArrayList(f64) = .empty;
    defer refresh_all.deinit(alloc);
    const stream_ms = try alloc.alloc(f64, runs);
    defer alloc.free(stream_ms);
    const baseline_ms = try alloc.alloc(f64, runs);
    defer alloc.free(baseline_ms);

    var final_total: usize = 0;
    var final_rows: usize = 0;
    var final_nodes: usize = 0;
    var row_messages: usize = 0;

    const refresh_bytes = @max(args.refresh_kib * 1024, args.line_len);

    for (0..runs) |run| {
        // Baseline: the same output with no search.
        {
            var t = try initTerminal(alloc, args);
            defer t.deinit(alloc);
            writeAll(&t, history);
            var timer = try std.time.Timer.start();
            writeAll(&t, streamed);
            baseline_ms[run] = nsToMs(timer.read());
        }

        var t = try initTerminal(alloc, args);
        defer t.deinit(alloc);
        writeAll(&t, history);

        var sink: Sink = .{ .alloc = alloc };
        var search = try ThreadSearch.init(alloc, args.needle, queryOptions(args));
        defer search.deinit(&t);

        // `changeQuery`'s initial feed, then the search thread's loop until
        // the search completes.
        var timer = try std.time.Timer.start();
        searchUntilComplete(alloc, &search, &t, &sink);
        initial_ms[run] = nsToMs(timer.read());

        // Streaming with a refresh after every `refresh_bytes` of output.
        var stream = t.vtStream();
        defer stream.deinit();
        var stream_timer = try std.time.Timer.start();
        var offset: usize = 0;
        while (offset < streamed.len) {
            const end = @min(offset + refresh_bytes, streamed.len);
            nextSliceChunked(&stream, streamed[offset..end]);
            offset = end;

            // What the renderer does on a dirty frame.
            t.flags.search_viewport_dirty = true;

            var refresh_timer = try std.time.Timer.start();
            searchUntilComplete(alloc, &search, &t, &sink);
            try refresh_all.append(alloc, nsToMs(refresh_timer.read()));
        }
        stream_ms[run] = nsToMs(stream_timer.read());

        final_total = sink.total;
        final_rows = search.match_rows.items.len;
        final_nodes = 0;
        var node_it = t.screens.active.pages.pages.first;
        while (node_it) |node| : (node_it = node.next) final_nodes += 1;
        row_messages = sink.row_messages;
    }

    for ([_][]f64{ initial_ms, stream_ms, baseline_ms, refresh_all.items }) |samples| {
        std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    }

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const out = &out_writer.interface;
    try out.print(
        \\bench:search-stream mode=feed regex={} whole-word={}
        \\  history lines      = {d} (1 in {d} matches "{s}"), {d}x{d}, scrollback {d} MiB
        \\  streamed           = {d} MiB, refresh every {d} KiB
        \\  final matches      = {d}, match rows = {d}, page nodes = {d}
        \\  row snapshots sent = {d} (last run)
        \\  initial search     median {d:.1} ms  min {d:.1}  max {d:.1}
        \\  refresh (feed+notify) median {d:.3} ms  p95 {d:.3}  max {d:.3}  (n={d})
        \\  stream with search median {d:.1} ms
        \\  stream, no search  median {d:.1} ms
        \\
    , .{
        args.regex,
        args.whole_word,
        args.lines,
        args.match_every,
        args.needle,
        args.cols,
        args.rows,
        args.scrollback_mib,
        args.stream_mib,
        args.refresh_kib,
        final_total,
        final_rows,
        final_nodes,
        row_messages,
        stats.median(initial_ms).?,
        initial_ms[0],
        initial_ms[initial_ms.len - 1],
        stats.median(refresh_all.items).?,
        stats.percentile(refresh_all.items, 95).?,
        refresh_all.items[refresh_all.items.len - 1],
        refresh_all.items.len,
        stats.median(stream_ms).?,
        stats.median(baseline_ms).?,
    });
    try out.flush();
}

fn runThread(
    alloc: std.mem.Allocator,
    args: Args,
    history: []const u8,
    streamed: []const u8,
) !void {
    const runs = args.runs;
    const with_ms = try alloc.alloc(f64, runs);
    defer alloc.free(with_ms);
    const without_ms = try alloc.alloc(f64, runs);
    defer alloc.free(without_ms);
    const with_wait_ms = try alloc.alloc(f64, runs);
    defer alloc.free(with_wait_ms);
    const without_wait_ms = try alloc.alloc(f64, runs);
    defer alloc.free(without_wait_ms);
    const initial_ms = try alloc.alloc(f64, runs);
    defer alloc.free(initial_ms);

    var final_total: usize = 0;
    var row_messages: usize = 0;

    for (0..runs) |run| {
        const without = try streamLocked(alloc, args, history, streamed, null);
        without_ms[run] = without.wall_ms;
        without_wait_ms[run] = without.lock_wait_ms;

        var sink: Sink = .{ .alloc = alloc };
        const with = try streamLocked(alloc, args, history, streamed, &sink);
        with_ms[run] = with.wall_ms;
        with_wait_ms[run] = with.lock_wait_ms;
        initial_ms[run] = with.initial_ms;
        final_total = sink.total;
        row_messages = sink.row_messages;
    }

    for ([_][]f64{ with_ms, without_ms, with_wait_ms, without_wait_ms, initial_ms }) |samples| {
        std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    }

    var out_buf: [2048]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const out = &out_writer.interface;
    const with_median = stats.median(with_ms).?;
    const without_median = stats.median(without_ms).?;
    try out.print(
        \\bench:search-stream mode=thread regex={} whole-word={}
        \\  history lines      = {d} (1 in {d} matches "{s}"), {d}x{d}, scrollback {d} MiB
        \\  streamed           = {d} MiB in 4 KiB writes under the terminal lock, paced at {d} MiB/s (0 = unpaced)
        \\  final matches      = {d}, row snapshots sent = {d} (last run)
        \\  initial search     median {d:.1} ms
        \\  stream with search median {d:.1} ms  (min {d:.1} max {d:.1}), writer waited for the lock {d:.1} ms
        \\  stream, no search  median {d:.1} ms  (min {d:.1} max {d:.1}), writer waited for the lock {d:.1} ms
        \\  slowdown           {d:.2}x
        \\
    , .{
        args.regex,
        args.whole_word,
        args.lines,
        args.match_every,
        args.needle,
        args.cols,
        args.rows,
        args.scrollback_mib,
        args.stream_mib,
        args.rate_mib_s,
        final_total,
        row_messages,
        stats.median(initial_ms).?,
        with_median,
        with_ms[0],
        with_ms[with_ms.len - 1],
        stats.median(with_wait_ms).?,
        without_median,
        without_ms[0],
        without_ms[without_ms.len - 1],
        stats.median(without_wait_ms).?,
        with_median / without_median,
    });
    try out.flush();
}

const StreamResult = struct {
    wall_ms: f64,
    lock_wait_ms: f64,
    initial_ms: f64 = 0,
};

/// Streams `streamed` into a terminal holding `history` the way the IO
/// thread does: 4 KiB at a time under the terminal lock, marking the
/// viewport dirty as the renderer would. With a `sink`, the real search
/// thread runs a search to completion first and then refreshes while the
/// output streams.
fn streamLocked(
    alloc: std.mem.Allocator,
    args: Args,
    history: []const u8,
    streamed: []const u8,
    sink: ?*Sink,
) !StreamResult {
    var mutex: std.Thread.Mutex = .{};
    var t = try initTerminal(alloc, args);
    defer t.deinit(alloc);
    writeAll(&t, history);

    var thread: SearchThread = try .init(alloc, .{
        .mutex = &mutex,
        .terminal = &t,
        .event_cb = &Sink.callback,
        .event_userdata = sink,
    });
    var os_thread: ?std.Thread = null;
    defer {
        if (os_thread) |th| {
            thread.stop.notify() catch {};
            th.join();
        }
        thread.deinit();
    }

    var result: StreamResult = .{ .wall_ms = 0, .lock_wait_ms = 0 };
    if (sink) |search_sink| {
        os_thread = try std.Thread.spawn(.{}, SearchThread.threadMain, .{&thread});
        var timer = try std.time.Timer.start();
        thread.send(.{ .change_query = .{
            .generation = 1,
            .options = queryOptions(args),
            .req = try .init(alloc, args.needle),
        } });
        try search_sink.complete.timedWait(600 * std.time.ns_per_s);
        result.initial_ms = nsToMs(timer.read());
    }

    const ns_per_byte: f64 = if (args.rate_mib_s > 0)
        std.time.ns_per_s / (args.rate_mib_s * 1024 * 1024)
    else
        0;

    var stream = t.vtStream();
    defer stream.deinit();
    var timer = try std.time.Timer.start();
    var lock_wait_ns: u64 = 0;
    var offset: usize = 0;
    while (offset < streamed.len) {
        const end = @min(offset + 4096, streamed.len);
        const before_lock = timer.read();
        mutex.lock();
        lock_wait_ns += timer.read() - before_lock;
        stream.nextSlice(streamed[offset..end]);
        t.flags.search_viewport_dirty = true;
        mutex.unlock();
        offset = end;

        // Pace the output like a producer that cannot write faster.
        if (ns_per_byte > 0) {
            const due: u64 = @intFromFloat(@as(f64, @floatFromInt(offset)) * ns_per_byte);
            while (timer.read() + std.time.ns_per_ms < due) std.Thread.sleep(std.time.ns_per_ms);
        }
    }
    result.wall_ms = nsToMs(timer.read());
    result.lock_wait_ms = nsToMs(lock_wait_ns);
    return result;
}

fn queryOptions(args: Args) terminal.search.QueryOptions {
    return .{ .regex = args.regex, .whole_word = args.whole_word };
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn parseArgs(raw: []const []const u8) !Args {
    var out: Args = .{};
    for (raw[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            out.mode = std.meta.stringToEnum(Mode, arg["--mode=".len..]) orelse
                return error.InvalidMode;
        } else if (std.mem.startsWith(u8, arg, "--lines=")) {
            out.lines = try std.fmt.parseInt(usize, arg["--lines=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--match-every=")) {
            out.match_every = try std.fmt.parseInt(usize, arg["--match-every=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--line-len=")) {
            out.line_len = try std.fmt.parseInt(usize, arg["--line-len=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--stream-mib=")) {
            out.stream_mib = try std.fmt.parseInt(usize, arg["--stream-mib=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--refresh-kib=")) {
            out.refresh_kib = try std.fmt.parseInt(usize, arg["--refresh-kib=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--runs=")) {
            out.runs = try std.fmt.parseInt(usize, arg["--runs=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--rows=")) {
            out.rows = try std.fmt.parseInt(u16, arg["--rows=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--cols=")) {
            out.cols = try std.fmt.parseInt(u16, arg["--cols=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--scrollback-mib=")) {
            out.scrollback_mib = try std.fmt.parseInt(usize, arg["--scrollback-mib=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--rate-mib-s=")) {
            out.rate_mib_s = try std.fmt.parseFloat(f64, arg["--rate-mib-s=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--needle=")) {
            out.needle = arg["--needle=".len..];
        } else if (std.mem.eql(u8, arg, "--regex")) {
            out.regex = true;
        } else if (std.mem.eql(u8, arg, "--whole-word")) {
            out.whole_word = true;
        } else {
            std.log.err("bench:search-stream: unknown arg '{s}'", .{arg});
            return error.InvalidArgument;
        }
    }
    if (!std.math.isFinite(out.rate_mib_s) or out.rate_mib_s < 0) return error.InvalidArgument;
    // Both modes report statistics over the streamed output, so it must
    // hold at least one line.
    if (out.runs == 0 or out.match_every == 0 or out.line_len < 64 or
        out.line_len > 1024 * 1024 or out.stream_mib == 0 or
        out.needle.len == 0 or out.rows == 0 or out.cols == 0)
    {
        return error.InvalidArgument;
    }
    return out;
}
