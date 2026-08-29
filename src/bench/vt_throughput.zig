//! Deterministic headless VT throughput microbenchmark.
//!
//! Generates a fixed-size payload in-process from the synthetic generators and
//! feeds it through the existing full `Terminal.vtStream()` parser/handler path.
//!
//! Usage:
//!   zig build bench:vt-throughput -- \
//!       --workload=ascii --bytes=4194304 --seed=121 --runs=5

const std = @import("std");
const build_options = @import("build_options");
const bench_core = @import("bench_core");
const synthetic = bench_core.synthetic;
const SyntheticAscii = synthetic.cli.Action.Struct(.ascii);
const Terminal = bench_core.terminal.Terminal;
const stats = @import("stats.zig");

const default_bytes = 4 * 1024 * 1024;
const schema_version = "noctty.vt-throughput.v1";

// Synthetic OSC and UTF-8 workloads deliberately exercise malformed control
// payloads. Terminal warning/info logging would otherwise dominate the timed
// parser/handler work; errors and integrity failures remain visible.
pub const std_options: std.Options = .{ .log_level = .err };

const Workload = enum {
    ascii,
    utf8,
    osc,
    scroll,
};

const Args = struct {
    workload: Workload = .ascii,
    bytes: usize = default_bytes,
    seed: u64 = 121,
    runs: usize = 5,
    rows: u16 = 80,
    cols: u16 = 120,
    min_mb_s: f64 = 0,
    json: ?[]const u8 = null,
};

const JsonResult = struct {
    schema_version: []const u8 = schema_version,
    benchmark: []const u8 = "vt-throughput",
    workload: []const u8,
    bytes: usize,
    seed: u64,
    runs: usize,
    rows: u16,
    cols: u16,
    per_run_mb_s: []const f64,
    median_mb_s: f64,
    p95_mb_s: f64,
    noctty_version: []const u8,
    noctty_commit: ?[]const u8,
};

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args_raw = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args_raw);
    const args = try parseArgs(args_raw);

    const payload = try alloc.alloc(u8, args.bytes);
    try generatePayload(payload, args.workload, args.seed, args.cols);

    const samples = try alloc.alloc(f64, args.runs);
    for (samples, 0..) |*sample, i| {
        var terminal: Terminal = try .init(std.heap.page_allocator, .{
            .rows = args.rows,
            .cols = args.cols,
        });
        defer terminal.deinit(std.heap.page_allocator);
        var stream = terminal.vtStream();
        defer stream.deinit();

        var timer = try std.time.Timer.start();
        var offset: usize = 0;
        while (offset < payload.len) {
            const end = @min(offset + 4096, payload.len);
            stream.nextSlice(payload[offset..end]);
            offset = end;
        }
        const elapsed_ns = @max(timer.read(), 1);
        sample.* = mbPerSecond(payload.len, elapsed_ns);

        if (args.json == null or !std.mem.eql(u8, args.json.?, "-")) {
            try printRun(i, sample.*);
        }
    }

    const sorted = try alloc.dupe(f64, samples);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const median_mb_s = stats.median(sorted).?;
    const p95_mb_s = stats.percentile(sorted, 95).?;
    const result: JsonResult = .{
        .workload = @tagName(args.workload),
        .bytes = args.bytes,
        .seed = args.seed,
        .runs = args.runs,
        .rows = args.rows,
        .cols = args.cols,
        .per_run_mb_s = samples,
        .median_mb_s = median_mb_s,
        .p95_mb_s = p95_mb_s,
        .noctty_version = build_options.app_version_string,
        // This fork uses semantic-version build metadata ("windows") here,
        // not a source revision. Do not mislabel it as a commit hash.
        .noctty_commit = null,
    };

    if (args.json) |path| try emitJsonPath(path, result);
    if (args.json == null or !std.mem.eql(u8, args.json.?, "-")) {
        try printSummary(args, median_mb_s, p95_mb_s);
    }

    if (args.min_mb_s > 0 and median_mb_s < args.min_mb_s) {
        var stderr_buf: [512]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;
        try stderr.print(
            "bench:vt-throughput: median_mb_s {d:.2} MB/s below threshold {d:.2} MB/s\n",
            .{ median_mb_s, args.min_mb_s },
        );
        try stderr.flush();
        std.process.exit(1);
    }
}

fn generatePayload(
    payload: []u8,
    workload: Workload,
    seed: u64,
    cols: u16,
) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    var writer: std.Io.Writer = .fixed(payload);

    switch (workload) {
        .ascii, .scroll => {
            var generator: synthetic.Bytes = .{
                .rand = rand,
                .alphabet = SyntheticAscii.ascii,
                .min_len = payload.len,
                .max_len = payload.len,
            };
            try generator.generator().next(&writer, payload.len);
        },
        .utf8 => {
            var generator: synthetic.Utf8 = .{
                .rand = rand,
                .min_len = payload.len,
                .max_len = payload.len,
            };
            try generator.generator().next(&writer, payload.len);
        },
        .osc => {
            var generator: synthetic.Osc = .{
                .rand = rand,
                .p_valid = 0.5,
            };
            const osc_generator = generator.generator();
            while (payload.len - writer.buffered().len >= 1024) {
                try osc_generator.next(&writer, 1024);
            }

            const remaining = payload.len - writer.buffered().len;
            if (remaining > 0) {
                var tail: synthetic.Bytes = .{
                    .rand = rand,
                    .alphabet = SyntheticAscii.ascii,
                    .min_len = remaining,
                    .max_len = remaining,
                };
                try tail.generator().next(&writer, remaining);
            }
        },
    }

    std.debug.assert(writer.buffered().len == payload.len);
    if (workload == .scroll) forceScrollNewlines(payload, cols);
}

fn forceScrollNewlines(payload: []u8, cols: u16) void {
    const line_bytes = @max(@as(usize, cols), 2);
    var line_end = line_bytes;
    while (line_end <= payload.len) : (line_end += line_bytes) {
        payload[line_end - 2] = '\r';
        payload[line_end - 1] = '\n';
    }
}

fn mbPerSecond(bytes: usize, elapsed_ns: u64) f64 {
    const megabytes = @as(f64, @floatFromInt(bytes)) / 1_000_000;
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    return megabytes / seconds;
}

fn emitJsonPath(path: []const u8, result: JsonResult) !void {
    if (std.mem.eql(u8, path, "-")) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        try writeJson(&stdout_writer.interface, result);
        try stdout_writer.interface.flush();
        return;
    }

    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{})
    else
        try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var file_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buf);
    try writeJson(&file_writer.interface, result);
    try file_writer.interface.flush();
}

fn writeJson(writer: *std.Io.Writer, result: JsonResult) !void {
    try writer.print("{f}\n", .{std.json.fmt(result, .{})});
}

fn printRun(index: usize, mb_s: f64) !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("  run {d}: {d:.2} MB/s\n", .{ index + 1, mb_s });
    try stdout.flush();
}

fn printSummary(args: Args, median_mb_s: f64, p95_mb_s: f64) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        \\bench:vt-throughput
        \\  workload  = {s}
        \\  bytes     = {d}
        \\  seed      = {d}
        \\  runs      = {d}
        \\  geometry  = {d}x{d}
        \\  median    = {d:.2} MB/s
        \\  p95       = {d:.2} MB/s
        \\  status    = {s}
        \\
    , .{
        @tagName(args.workload),
        args.bytes,
        args.seed,
        args.runs,
        args.cols,
        args.rows,
        median_mb_s,
        p95_mb_s,
        if (args.min_mb_s == 0 or median_mb_s >= args.min_mb_s) "OK" else "REGRESSION",
    });
    try stdout.flush();
}

fn parseArgs(raw: []const []const u8) !Args {
    var out: Args = .{};
    for (raw[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--workload=")) {
            out.workload = std.meta.stringToEnum(
                Workload,
                arg["--workload=".len..],
            ) orelse return error.InvalidWorkload;
        } else if (std.mem.startsWith(u8, arg, "--bytes=")) {
            out.bytes = try std.fmt.parseInt(usize, arg["--bytes=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            out.seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--runs=")) {
            out.runs = try std.fmt.parseInt(usize, arg["--runs=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--rows=")) {
            out.rows = try std.fmt.parseInt(u16, arg["--rows=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--cols=")) {
            out.cols = try std.fmt.parseInt(u16, arg["--cols=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--min-mb-s=")) {
            out.min_mb_s = try std.fmt.parseFloat(f64, arg["--min-mb-s=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--json=")) {
            out.json = arg["--json=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else {
            std.log.warn("bench:vt-throughput: unknown arg '{s}' - ignoring", .{arg});
        }
    }

    if (out.bytes == 0 or out.runs == 0 or out.rows == 0 or out.cols == 0) {
        return error.InvalidArgument;
    }
    if (!std.math.isFinite(out.min_mb_s) or out.min_mb_s < 0) {
        return error.InvalidArgument;
    }
    return out;
}

fn printHelp() !void {
    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\bench:vt-throughput - deterministic headless VT throughput
        \\
        \\Flags:
        \\  --workload=NAME  ascii, utf8, osc, or scroll (default ascii).
        \\  --bytes=N        Exact generated payload bytes (default 4194304).
        \\  --seed=N         Fixed generator seed (default 121).
        \\  --runs=N         Timed runs (default 5).
        \\  --rows=N         Terminal rows (default 80).
        \\  --cols=N         Terminal columns (default 120).
        \\  --min-mb-s=N     Minimum median decimal MB/s; 0 disables the gate.
        \\  --json=PATH      Write versioned JSON; '-' writes JSON to stdout.
        \\  -h, --help       Print this help.
        \\
    );
    try stdout.flush();
}

test "issue121-vt-bench-json-shape" {
    const testing = std.testing;
    const samples = [_]f64{ 10, 20, 30 };
    const result: JsonResult = .{
        .workload = "ascii",
        .bytes = 4096,
        .seed = 121,
        .runs = samples.len,
        .rows = 24,
        .cols = 80,
        .per_run_mb_s = &samples,
        .median_mb_s = 20,
        .p95_mb_s = 30,
        .noctty_version = "1.2.3",
        .noctty_commit = "abc123",
    };

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try writeJson(&output.writer, result);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        output.written(),
        .{},
    );
    defer parsed.deinit();
    const object = parsed.value.object;
    try testing.expectEqual(@as(usize, 13), object.count());
    try testing.expectEqualStrings(schema_version, object.get("schema_version").?.string);
    try testing.expectEqualStrings("vt-throughput", object.get("benchmark").?.string);
    try testing.expectEqualStrings("ascii", object.get("workload").?.string);
    try testing.expectEqual(@as(i64, 4096), object.get("bytes").?.integer);
    try testing.expectEqual(@as(usize, 3), object.get("per_run_mb_s").?.array.items.len);
    try testing.expectEqualStrings("1.2.3", object.get("noctty_version").?.string);
    try testing.expectEqualStrings("abc123", object.get("noctty_commit").?.string);
}
