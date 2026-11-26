//! The test runner of the Zig test executables (`build.zig`: `test_runner`).
//!
//! A copy of Zig 0.17.1's `lib/compiler/test_runner.zig` (MIT, Copyright (c)
//! Zig contributors) with two additions: `--shard=K/N` runs only every Nth test
//! from the Kth (src/test_shard.zig), so `-Dtest-shards=N` can run one test
//! executable as N processes side by side and the shards together run each
//! test exactly once; and `--results=<path>` makes terminal mode also write
//! what it ran to a new file (`Results`), which scripts/capture-test-ran-list.ps1
//! reads instead of the printed lines a test's own output can imitate. Without
//! either it behaves exactly like the stock runner. The stock runner runs one
//! test at a time, so on a four-core CI runner one process left three cores
//! idle.
//!
//! Every other line is the stock file's, so a Zig upgrade re-copies the new
//! version and reapplies the parts marked `noctty:`; the version check below
//! fails the build until someone does.
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const fatal = std.process.fatal;
const testing = std.testing;
const assert = std.debug.assert;
const panic = std.debug.panic;
const fuzz_abi = std.Build.abi.fuzz;

// noctty: the protocol with the build runner (`std.zig.Server`) belongs to the
// Zig version this file was copied from.
comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 17) @compileError(
        "src/test_runner.zig is a copy of Zig 0.17's lib/compiler/test_runner.zig: " ++
            "copy this Zig's version and reapply the `noctty:` changes",
    );
}

/// noctty: which tests this process runs (`--shard=K/N`).
const Shard = @import("test_shard.zig").Shard;
var shard: Shard = .{};

/// noctty: the results file of `--results=<path>`, null without it.
var results: ?Results = null;

/// noctty: what terminal mode ran, as the runner itself decided it, one
/// LF-terminated line each:
///
///     noctty test results v1
///     zig <builtin.zig_version_string>
///     mode <@tagName(builtin.mode)>
///     shard <K>/<N>
///     test <index> <OK|SKIP|FAIL> <leaked: 0|1> <the name's bytes, lowercase hex>
///     end tests=<n> ok=<n> skip=<n> fail=<n> leaked=<n> errors-logged=<n>
///
/// A test line is written after its test's allocator is checked, and each line
/// is flushed as it is written, so a run that stops leaves a file without its
/// `end` line. `leaked` is whether the test leaked, and `end`'s `leaked` the
/// tests that did, as terminal mode counts them (server mode reports each
/// test's leaked allocations instead). The file must not exist yet. A process
/// the tests start (the ConPTY probe child) gets no `--results`, so it writes
/// nothing here.
const Results = struct {
    file: Io.File,

    const Outcome = enum { ok, skip, fail };

    fn create(path: []const u8) Results {
        return .{
            .file = Io.Dir.cwd().createFile(runner_threaded_io, path, .{ .exclusive = true }) catch |err|
                panic("unable to create the --results file, which must not exist yet: {t}", .{err}),
        };
    }

    fn header(r: *Results) void {
        r.write("noctty test results v1\nzig {s}\nmode {s}\nshard {d}/{d}\n", .{
            builtin.zig_version_string, @tagName(builtin.mode), shard.index + 1, shard.count,
        }, null);
    }

    fn testRun(r: *Results, index: usize, name: []const u8, outcome: Outcome, leaked: bool) void {
        const word = switch (outcome) {
            .ok => "OK",
            .skip => "SKIP",
            .fail => "FAIL",
        };
        r.write("test {d} {s} {d} ", .{ index, word, @intFromBool(leaked) }, name);
    }

    fn end(r: *Results, tests: usize, ok: usize, skip: usize, fail: usize, leaked: usize, errors_logged: usize) void {
        r.write("end tests={d} ok={d} skip={d} fail={d} leaked={d} errors-logged={d}\n", .{
            tests, ok, skip, fail, leaked, errors_logged,
        }, null);
        r.file.close(runner_threaded_io);
        results = null;
    }

    /// Writes `format`, then `hex`'s bytes in hex and a line end if it is
    /// given, and flushes.
    fn write(r: *Results, comptime format: []const u8, args: anytype, hex: ?[]const u8) void {
        var buffer: [1024]u8 = undefined;
        var w = r.file.writerStreaming(runner_threaded_io, &buffer);
        writeLine(&w.interface, format, args, hex) catch {
            if (w.err) |err| panic("unable to write the --results file: {t}", .{err});
            @panic("unable to write the --results file");
        };
    }

    fn writeLine(w: *Io.Writer, comptime format: []const u8, args: anytype, hex: ?[]const u8) !void {
        try w.print(format, args);
        if (hex) |bytes| {
            try w.printHex(bytes, .lower);
            try w.writeByte('\n');
        }
        try w.flush();
    }
};

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
var fba_buffer: [8192]u8 = undefined;
var stdin_buffer: [4096]u8 = undefined;
var stdout_buffer: [4096]u8 = undefined;
var stdin_reader: Io.File.Reader = undefined;
var stdout_writer: Io.File.Writer = undefined;
const runner_threaded_io: Io = Io.Threaded.global_single_threaded.io();

/// Keep in sync with logic in `std.Build.addRunArtifact` which decides whether
/// the test runner will communicate with the build runner via `std.zig.Server`.
const need_simple = switch (builtin.zig_backend) {
    .stage2_aarch64,
    .stage2_loongarch,
    .stage2_powerpc,
    .stage2_riscv64,
    => true,
    else => false,
};

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    if (builtin.cpu.arch.isSpirV()) {
        // SPIR-V needs an special test-runner
        return;
    }

    if (need_simple) {
        return mainSimple() catch |err| panic("test failure: {t}", .{err});
    }

    const args = init.args.toSlice(fba.allocator()) catch |err| panic("unable to parse command line args: {t}", .{err});

    var listen = false;
    var opt_cache_dir: ?[]const u8 = null;
    var results_path: ?[]const u8 = null; // noctty

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--cache-dir")) {
            opt_cache_dir = arg["--cache-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--shard=")) {
            // noctty: a malformed shard must not quietly run all tests, or none.
            shard = Shard.parse(arg["--shard=".len..]) orelse
                @panic("--shard must be K/N with 1 <= K <= N");
        } else if (std.mem.startsWith(u8, arg, "--results=")) {
            // noctty: see `Results`.
            if (results_path != null) @panic("--results given twice");
            results_path = arg["--results=".len..];
        } else {
            panic("unrecognized command line argument: {s}", .{arg});
        }
    }
    // noctty: the build runner's server mode keeps its own record.
    if (results_path) |path| {
        if (listen) @panic("--results is for terminal mode");
        results = Results.create(path);
    }

    if (builtin.fuzz) {
        const cache_dir = opt_cache_dir orelse @panic("missing --cache-dir=[path] argument");
        fuzz_abi.fuzzer_init(.fromSlice(cache_dir));
    }

    if (listen) {
        return mainServer(init) catch |err| panic("internal test runner failure: {t}", .{err});
    } else {
        return mainTerminal(init);
    }
}

fn mainServer(init: std.process.Init.Minimal) !void {
    @disableInstrumentation();
    stdin_reader = .initStreaming(.stdin(), runner_threaded_io, &stdin_buffer);
    stdout_writer = .initStreaming(.stdout(), runner_threaded_io, &stdout_buffer);
    var server: std.zig.Server = .{
        .in = &stdin_reader.interface,
        .out = &stdout_writer.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);

    while (true) {
        const hdr = try server.receiveMessage();
        switch (hdr.tag) {
            .exit => {
                return std.process.exit(0);
            },
            .query_test_metadata => {
                var sa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
                defer if (sa.deinit() != 0) @panic("internal test runner memory leak");
                const gpa = sa.allocator();

                var string_bytes: std.ArrayList(u8) = .empty;
                defer string_bytes.deinit(gpa);
                try string_bytes.append(gpa, 0); // Reserve 0 for null.

                // noctty: the build runner sees only this shard's tests, and
                // its `run_test` indices count within them (`Shard.testIndex`).
                const shard_len = shard.len(builtin.test_functions.len);
                const names = try gpa.alloc(u32, shard_len);
                defer gpa.free(names);
                const expected_panic_msgs = try gpa.alloc(u32, shard_len);
                defer gpa.free(expected_panic_msgs);

                for (names, expected_panic_msgs, 0..) |*name, *expected_panic_msg, i| {
                    const test_fn = builtin.test_functions[shard.testIndex(i)];
                    name.* = @intCast(string_bytes.items.len);
                    try string_bytes.ensureUnusedCapacity(gpa, test_fn.name.len + 1);
                    string_bytes.appendSliceAssumeCapacity(test_fn.name);
                    string_bytes.appendAssumeCapacity(0);
                    expected_panic_msg.* = 0;
                }

                try server.serveTestMetadata(.{
                    .names = names,
                    .expected_panic_msgs = expected_panic_msgs,
                    .string_bytes = string_bytes.items,
                });
            },

            .run_test => {
                testing.environ = init.environ;
                testing.allocator_instance = .init(std.heap.page_allocator, .{
                    .canary = 0xc3a701ba,
                    .check_write_after_free = true,
                });
                testing.io_instance = .init(testing.allocator, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                log_err_count = 0;
                const index = try server.receiveBody_u32();
                const test_fn = builtin.test_functions[shard.testIndex(index)]; // noctty
                is_fuzz_test = false;

                // let the build server know we're starting the test now
                try server.serveStringMessage(.test_started, &.{});

                const TestResults = std.zig.Server.Message.TestResults;
                const status: TestResults.Status = if (test_fn.func()) |v| s: {
                    v;
                    break :s .pass;
                } else |err| switch (err) {
                    error.SkipZigTest => .skip,
                    else => s: {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpErrorReturnTrace(trace);
                        }
                        break :s .fail;
                    },
                };
                testing.io_instance.deinit();
                const leak_count = testing.allocator_instance.deinit();
                try server.serveTestResults(.{
                    .index = index,
                    .flags = .{
                        .status = status,
                        .fuzz = is_fuzz_test,
                        .log_err_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "log_err_count"),
                            log_err_count,
                        ),
                        .leak_count = std.math.lossyCast(
                            @FieldType(TestResults.Flags, "leak_count"),
                            leak_count,
                        ),
                    },
                });
            },
            .start_fuzzing => {
                // This ensures that this code won't be analyzed and hence reference fuzzer symbols
                // since they are not present.
                if (!builtin.fuzz) unreachable;

                var gpa_instance: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
                defer if (gpa_instance.deinit() != 0) {
                    @panic("internal test runner memory leak");
                };
                const gpa = gpa_instance.allocator();
                var io_instance: Io.Threaded = .init(gpa, .{
                    .argv0 = .init(init.args),
                    .environ = init.environ,
                });
                defer io_instance.deinit();

                const mode: fuzz_abi.LimitKind = @fromBackingInt(@intCast(try server.receiveBody_u8()));
                const amount_or_instance = try server.receiveBody_u64();
                const main_instance = mode == .iterations or amount_or_instance == 0;

                if (main_instance) {
                    const coverage = fuzz_abi.fuzzer_coverage();
                    try server.serveCoverageIdMessage(
                        coverage.id,
                        coverage.runs,
                        coverage.unique,
                        coverage.seen,
                    );
                }

                const n_tests: u32 = try server.receiveBody_u32();
                const test_indexes = try gpa.alloc(u32, n_tests);
                defer gpa.free(test_indexes);
                fuzz_runner = .{
                    .indexes = test_indexes,
                    .server = &server,
                    .gpa = gpa,
                    .threaded_io = &io_instance,
                    .input_poller = undefined,
                };

                {
                    var large_name_buf: std.ArrayList(u8) = .empty;
                    defer large_name_buf.deinit(gpa);
                    for (test_indexes) |*i| {
                        const name_len = try server.receiveBody_u32();
                        const name = if (name_len <= server.in.buffer.len)
                            try server.in.take(name_len)
                        else large_name: {
                            try large_name_buf.resize(gpa, name_len);
                            try server.in.readSliceAll(large_name_buf.items);
                            break :large_name large_name_buf.items;
                        };

                        // noctty: the build runner names the tests to fuzz,
                        // so this search, and `fuzz_runner.indexes` after it,
                        // index the whole table whatever the shard: no
                        // `Shard.testIndex` here.
                        for (0.., builtin.test_functions) |test_i, test_fn| {
                            if (std.mem.eql(u8, name, test_fn.name)) {
                                i.* = @intCast(test_i);
                                break;
                            }
                        } else {
                            panic("fuzz test {s} no longer exists", .{name});
                        }

                        if (main_instance) {
                            const relocated_entry_addr = @intFromPtr(builtin.test_functions[i.*].func);
                            const entry_addr = fuzz_abi.fuzzer_unslide_address(relocated_entry_addr);
                            try server.serveU64Message(.fuzz_start_addr, entry_addr);
                        }
                    }
                }

                fuzz_abi.fuzzer_main(n_tests, testing.random_seed, mode, amount_or_instance);

                assert(mode != .forever);
                std.process.exit(0);
            },

            else => {
                std.debug.print("unsupported message: {x}\n", .{@backingInt(hdr.tag)});
                std.process.exit(1);
            },
        }
    }
}

fn mainTerminal(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    if (builtin.fuzz) @panic("fuzz test requires server");

    // noctty: this shard's tests, numbered within the shard. A strided
    // selection is not a slice, so the loop below reads it through
    // `Shard.testIndex`, and `test_fn_list.len` is the shard's count.
    const test_fn_list: struct {
        len: usize,
    } = .{ .len = shard.len(builtin.test_functions.len) };
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var fuzz_count: usize = 0;
    const root_node = if (builtin.fuzz) std.Progress.Node.none else std.Progress.start(runner_threaded_io, .{
        .root_name = "Test",
        .estimated_total_items = test_fn_list.len,
    });
    const have_tty = Io.File.stderr().isTty(runner_threaded_io) catch unreachable;

    if (results) |*r| r.header(); // noctty
    var leaks: usize = 0;
    for (0..test_fn_list.len) |i| {
        const test_fn = builtin.test_functions[shard.testIndex(i)]; // noctty
        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        var outcome: Results.Outcome = .fail; // noctty: set with each count below
        defer {
            testing.io_instance.deinit();
            const leaked = testing.allocator_instance.deinit() != 0; // noctty
            if (leaked) leaks += 1;
            if (results) |*r| r.testRun(i + 1, test_fn.name, outcome, leaked); // noctty
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        const test_node = root_node.start(test_fn.name, 0);
        if (!have_tty) {
            std.debug.print("{d}/{d} {s}...", .{ i + 1, test_fn_list.len, test_fn.name });
        }
        is_fuzz_test = false;
        if (test_fn.func()) |_| {
            ok_count += 1;
            outcome = .ok; // noctty
            test_node.end();
            if (!have_tty) std.debug.print("OK\n", .{});
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip_count += 1;
                outcome = .skip; // noctty
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...SKIP\n", .{ i + 1, test_fn_list.len, test_fn.name });
                } else {
                    std.debug.print("SKIP\n", .{});
                }
                test_node.end();
            },
            else => {
                fail_count += 1;
                if (have_tty) {
                    std.debug.print("{d}/{d} {s}...FAIL ({t})\n", .{
                        i + 1, test_fn_list.len, test_fn.name, err,
                    });
                } else {
                    std.debug.print("FAIL ({t})\n", .{err});
                }
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                test_node.end();
            },
        }
        fuzz_count += @intFromBool(is_fuzz_test);
    }
    root_node.end();
    if (ok_count == test_fn_list.len) {
        std.debug.print("All {d} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    }
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (fuzz_count != 0) {
        std.debug.print("{d} fuzz tests found.\n", .{fuzz_count});
    }
    if (results) |*r| r.end(test_fn_list.len, ok_count, skip_count, fail_count, leaks, log_err_count); // noctty
    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

/// Simpler main(), exercising fewer language features, so that
/// work-in-progress backends can handle it.
pub fn mainSimple() anyerror!void {
    @disableInstrumentation();
    // is the backend capable of calling `Io.File.writeAll`?
    const enable_write = switch (builtin.zig_backend) {
        .stage2_aarch64, .stage2_riscv64 => true,
        else => false,
    };
    // is the backend capable of calling `Io.Writer.print`?
    const enable_print = switch (builtin.zig_backend) {
        .stage2_aarch64, .stage2_riscv64 => true,
        else => false,
    };

    testing.allocator_instance = .init(std.heap.page_allocator, .{});
    testing.io_instance = .init(testing.allocator, .{});

    var passed: u64 = 0;
    var skipped: u64 = 0;
    var failed: u64 = 0;

    // we don't want to bring in File and Writer if the backend doesn't support it
    const stdout = if (enable_write) Io.File.stdout() else {};

    for (builtin.test_functions) |test_fn| {
        if (enable_write) {
            stdout.writeStreamingAll(runner_threaded_io, test_fn.name) catch {};
            stdout.writeStreamingAll(runner_threaded_io, "... ") catch {};
        }
        if (test_fn.func()) |_| {
            if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "PASS\n") catch {};
        } else |err| {
            if (err != error.SkipZigTest) {
                if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "FAIL\n") catch {};
                failed += 1;
                if (!enable_write) return err;
                continue;
            }
            if (enable_write) stdout.writeStreamingAll(runner_threaded_io, "SKIP\n") catch {};
            skipped += 1;
            continue;
        }
        passed += 1;
    }
    if (enable_print) {
        var unbuffered_stdout_writer = stdout.writer(runner_threaded_io, &.{});
        unbuffered_stdout_writer.interface.print(
            "{} passed, {} skipped, {} failed\n",
            .{ passed, skipped, failed },
        ) catch {};
    }
    if (failed != 0) std.process.exit(1);
}

var is_fuzz_test: bool = undefined;
var fuzz_runner: if (builtin.fuzz) struct {
    indexes: []u32,
    server: *std.zig.Server,
    gpa: std.mem.Allocator,
    threaded_io: *Io.Threaded,
    input_poller: Io.Future(Io.Cancelable!void),

    comptime {
        assert(builtin.fuzz); // `fuzz_runner` was analyzed in non-fuzzing compilation
    }

    export fn runner_test_run(i: u32) void {
        @disableInstrumentation();

        fuzz_runner.server.serveU32Message(.fuzz_test_change, i) catch |e| switch (e) {
            error.WriteFailed => panic("failed to write to stdout: {t}", .{stdout_writer.err.?}),
        };

        testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        defer if (testing.allocator_instance.deinit() != 0) std.process.exit(1);
        is_fuzz_test = false;

        testing.io_instance = .init(testing.allocator, .{
            .argv0 = fuzz_runner.threaded_io.argv0,
            .environ = fuzz_runner.threaded_io.environ.process_environ,
        });
        defer testing.io_instance.deinit();

        builtin.test_functions[fuzz_runner.indexes[i]].func() catch |err| switch (err) {
            error.SkipZigTest => return,
            else => {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                std.debug.print("failed with error.{t}\n", .{err});
                std.process.exit(1);
            },
        };

        if (!is_fuzz_test) @panic("missed call to std.testing.fuzz");
        if (log_err_count != 0) @panic("error logs detected");
    }

    export fn runner_test_name(i: u32) fuzz_abi.Slice {
        @disableInstrumentation();
        return .fromSlice(builtin.test_functions[fuzz_runner.indexes[i]].name);
    }

    export fn runner_broadcast_input(test_i: u32, bytes_slice: fuzz_abi.Slice) void {
        @disableInstrumentation();
        const bytes = bytes_slice.toSlice();
        fuzz_runner.server.serveBroadcastFuzzInputMessage(test_i, bytes) catch |e| switch (e) {
            error.WriteFailed => panic("failed to write to stdout: {t}", .{stdout_writer.err.?}),
        };
    }

    export fn runner_start_input_poller() void {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        const future = io.concurrent(inputPoller, .{}) catch |e| switch (e) {
            error.ConcurrencyUnavailable => @panic("failed to spawn concurrent fuzz input poller"),
        };
        fuzz_runner.input_poller = future;
    }

    export fn runner_stop_input_poller() void {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        assert(fuzz_runner.input_poller.cancel(io) == error.Canceled);
    }

    export fn runner_futex_wait(ptr: *const u32, expected: u32) bool {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        return io.futexWait(u32, ptr, expected) == error.Canceled;
    }

    export fn runner_futex_wake(ptr: *const u32, waiters: u32) void {
        @disableInstrumentation();
        const io = fuzz_runner.threaded_io.io();
        io.futexWake(u32, ptr, waiters);
    }

    fn inputPoller() Io.Cancelable!void {
        @disableInstrumentation();
        switch (inputPollerInner()) {
            error.Canceled => |e| return e,
            error.ReadFailed => {
                if (stdin_reader.err.? == error.Canceled) return error.Canceled;
                panic("failed to read from stdin: {t}", .{stdin_reader.err.?});
            },
            error.EndOfStream => @panic("unexpected end of stdin"),
        }
    }

    fn inputPollerInner() (Io.Cancelable || Io.Reader.Error) {
        @disableInstrumentation();
        const server = fuzz_runner.server;
        var large_bytes_list: std.ArrayList(u8) = .empty;
        defer large_bytes_list.deinit(fuzz_runner.gpa);
        while (true) {
            const hdr = try server.receiveMessage();
            if (hdr.tag != .new_fuzz_input) {
                panic("unexpected message: {x}\n", .{@backingInt(hdr.tag)});
            }
            const test_i = try server.receiveBody_u32();
            const input_len = hdr.bytes_len - 4;
            const bytes = if (input_len <= server.in.buffer.len)
                try server.in.take(input_len)
            else bytes: {
                large_bytes_list.resize(fuzz_runner.gpa, @intCast(input_len)) catch @panic("OOM");
                try server.in.readSliceAll(large_bytes_list.items);
                break :bytes large_bytes_list.items;
            };
            if (fuzz_abi.fuzzer_receive_input(test_i, .fromSlice(bytes))) {
                return error.Canceled;
            }
        }
    }
} else void = undefined;

pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), *std.testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    // Prevent this function from confusing the fuzzer by omitting its own code
    // coverage from being considered.
    @disableInstrumentation();

    // Some compiler backends are not capable of handling fuzz testing yet but
    // we still want CI test coverage enabled.
    if (need_simple) return;

    // Smoke test to ensure the test did not use conditional compilation to
    // contradict itself by making it not actually be a fuzz test when the test
    // is built in fuzz mode.
    is_fuzz_test = true;

    // Ensure no test failure occurred before starting fuzzing.
    if (log_err_count != 0) @panic("error logs detected");

    // libfuzzer is in a separate compilation unit so that its own code can be
    // excluded from code coverage instrumentation. It needs a function pointer
    // it can call for checking exactly one input. Inside this function we do
    // our standard unit test checks such as memory leaks, and interaction with
    // error logs.
    const global = struct {
        var ctx: @TypeOf(context) = undefined;

        fn test_one() callconv(.c) bool {
            @disableInstrumentation();
            testing.allocator_instance = .init(std.heap.page_allocator, .{
                .canary = 0xcacce5e0,
                .check_write_after_free = true,
            });
            defer if (testing.allocator_instance.deinit() != 0) std.process.exit(1);
            log_err_count = 0;
            testOne(ctx, @constCast(&testing.Smith{ .in = null })) catch |err| switch (err) {
                error.SkipZigTest => return true,
                else => {
                    const stderr = std.debug.lockStderr(&.{}).terminal();
                    p: {
                        if (@errorReturnTrace()) |trace| {
                            std.debug.writeErrorReturnTrace(trace, stderr) catch break :p;
                        }
                        stderr.writer.print("failed with error.{t}\n", .{err}) catch break :p;
                    }
                    std.process.exit(1);
                },
            };
            if (log_err_count != 0) {
                const stderr = std.debug.lockStderr(&.{}).terminal();
                stderr.writer.print("error logs detected\n", .{}) catch {};
                std.process.exit(1);
            }
            return false;
        }
    };

    if (builtin.fuzz) {
        // Preserve the calling test's allocator state
        const prev_allocator_state = testing.allocator_instance;
        defer testing.allocator_instance = prev_allocator_state;

        global.ctx = context;
        fuzz_abi.fuzzer_set_test(&global.test_one);
        for (options.corpus) |elem|
            fuzz_abi.fuzzer_new_input(.fromSlice(elem));
        fuzz_abi.fuzzer_start_test();
        return;
    }

    // When the unit test executable is not built in fuzz mode, only run the
    // provided corpus.
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }

    // In case there is no provided corpus, also use an empty
    // string as a smoke test.
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}
