//! Isolated children of the test exe (PLAN.md §2.7 RQ15, §19.3): a test that
//! expects a panic or an off-table pair runs its body in a child process, the
//! test exe started again, because a test exe can neither survive nor assert
//! its own panic, and the run's compare would fail on an off-table pair.
//!
//! The dispatch: `src/main.zig`'s first test, an unnamed one that no
//! `-Dtest-filter` drops, calls `runChildIfRequested`. In a child it finds
//! the test `child_env` names in `builtin.test_functions`, runs it with
//! `inChild()` true and ends the process: 0 when the test returned, 1 when it
//! failed, 2 when the executable holds no such test, 3 when it panicked (Zig's
//! abort, whose Debug breakpoint the child turns into that exit:
//! `exitOnBreakpoint`), 4 when it leaked. `builtin.test_functions` lists the
//! root file's tests first, in declaration order, then the files it reaches
//! (measured on Zig 0.15.2), so the dispatch runs before any other test, and
//! the parent starts a child unsharded, with no `--results` or `--listen`, so
//! it writes no ran-list record (test-harnesses.md, 2026-11-18 RAN-LIST-01).
//!
//! An isolated test is one test block, its body in the child and its verdict
//! in the parent:
//!
//!     test "a child that ... panics" {
//!         if (isolated.inChild()) {
//!             ... // the body, which panics
//!             return;
//!         }
//!         try isolated.expectPanic(@src(), "the panic text");
//!     }
//!
//! The parent checks `child_env` first, so a child never starts a child, and
//! names its test from `@src()` (`@src().fn_name` is `test.<name>` in a test
//! block). It starts the child with no console window, its stdin closed, a
//! deadline, and either no dump directory or one of its own, never the run's
//! (`NOCTTY_THREAD_ROLE_DUMP` is replaced or removed, so the run's compare
//! never reads a child's dump: CHILD-DUMP-IN-RUN). Its verdict follows the
//! variant: a panic variant asserts the abnormal exit and the panic text
//! (test 12's also its dump's pairs); an off-table variant asserts a
//! successful exit and exactly one PAIR-OUTSIDE-TABLE naming the pair. Each
//! also asserts that the dispatch ran as the child's first test.
//!
//! The child's dump is compared here, in the test exe (`compare.zig`), after
//! `symbolise.zig` names its pairs against this exe's own PDB, with the
//! reviewed table read at test time: `NOCTTY_THREAD_ROLE_TABLE` if set (a
//! drive-absolute path, screened as the dump directory is), else
//! `ci/lock-inventory-threads.tsv` under this build's source root, which the
//! PDB's own path for `symbolise.zig` gives, so it is found whatever the
//! working directory (`tablePathAlloc`), in `compare.tree_scope`, the one
//! place that names the tree's scope.

const std = @import("std");
const win32_types = @import("../apprt/win32_types.zig");
const win32_sys = @import("../apprt/win32/sys.zig");
const builtin = @import("builtin");
const windows = std.os.windows;
const thread_role = @import("thread_role.zig");
const state_mutex = @import("state_mutex.zig");
const recorder = @import("recorder.zig");
const dump = @import("dump.zig");
const symbolise = @import("symbolise.zig");
const compare = @import("compare.zig");

const Allocator = std.mem.Allocator;

/// The variable that makes the test exe an isolated child: the qualified
/// name of the test it runs (`sync.isolated.test.<name>`).
pub const child_env = "NOCTTY_THREAD_ROLE_ISOLATED";

/// The variable that overrides where the in-process compare reads the
/// reviewed table: a drive-absolute path, never a share, a device or a
/// relative path (`dump.isDriveAbsolute`).
pub const table_env = "NOCTTY_THREAD_ROLE_TABLE";

/// The table's place under the source root (lead's 1A.2 decision 8).
pub const table_path = "ci" ++ std.fs.path.sep_str ++ "lock-inventory-threads.tsv";

/// The child's exit codes (a panic exits 3, through Zig's abort).
pub const exit_passed = 0;
pub const exit_failed = 1;
pub const exit_no_test = 2;
pub const exit_panicked = 3;
pub const exit_leaked = 4;
pub const exit_kind_decided = 5;

/// How long a parent waits for its child before it ends it. A panicking
/// child loads this exe's PDB for its stack trace first.
pub const child_deadline_ms = 120_000;

/// The marker the dispatch prints before it runs the test: the parent
/// checks that it follows the runner's header for test 0.
const dispatch_marker = "isolated child: running ";

var running_child = false;

/// Whether this process is an isolated child running its test's body.
pub fn inChild() bool {
    return running_child;
}

/// The child-mode dispatch, called by `src/main.zig`'s first test. In an
/// isolated child, runs its test and ends the process; in the symbolise
/// mode, symbolises and ends the process; otherwise returns at once.
pub fn runChildIfRequested() void {
    if (comptime builtin.os.tag != .windows) return;
    if (std.testing.environ.containsConstant(symbolise.raw_env)) symbolise.runFromEnvironment();
    var name_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&name_buf);
    // One variable from the live block, as 0.15's `getEnvVarOwned` read it
    // (a whole-environment map would not fit the fixed buffer).
    const name_w = std.testing.environ.getWindows(std.unicode.utf8ToUtf16LeStringLiteral(child_env)) orelse return;
    const name = std.unicode.wtf16LeToWtf8Alloc(fba.allocator(), name_w) catch |err| {
        // A child must never fall through to the rest of the suite.
        std.debug.print("isolated child: its test's name cannot be read: {s}\n", .{@errorName(err)});
        std.process.exit(exit_no_test);
    };
    for (builtin.test_functions) |test_fn| {
        if (!std.mem.eql(u8, test_fn.name, name)) continue;
        std.debug.print(dispatch_marker ++ "{s}\n", .{test_fn.name});
        // A panic ends in Zig's abort, which in Debug first executes a
        // breakpoint: with no debugger that is an unhandled exception
        // (the process exits 0x80000003, which `std.process.Child` reports
        // truncated as 3), left to Windows' error reporting and any
        // just-in-time debugger. The child exits 3 itself instead, after the
        // panic has printed, and asks Windows for no fault dialog.
        _ = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
        _ = win32_sys.AddVectoredExceptionHandler(1, exitOnBreakpoint);
        // Before the first pair, so the dump's header says what it is.
        recorder.setProcessKind(.child) catch std.process.exit(exit_kind_decided);
        running_child = true;
        test_fn.func() catch |err| {
            std.debug.print("isolated child: the test failed: error.{s}\n", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.process.exit(exit_failed);
        };
        if (std.testing.allocator_instance.deinit() == .leak) std.process.exit(exit_leaked);
        std.debug.print("isolated child: the test returned\n", .{});
        std.process.exit(exit_passed);
    }
    std.debug.print("isolated child: the executable holds no such test\n", .{});
    std.process.exit(exit_no_test);
}

const SEM_FAILCRITICALERRORS: u32 = 0x0001;
const SEM_NOGPFAULTERRORBOX: u32 = 0x0002;
const STATUS_BREAKPOINT: u32 = 0x80000003;

extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;

/// An isolated child's end at the breakpoint of Zig's Debug abort: exit 3,
/// as abort does in the other modes. Every other exception goes on to the
/// next handler.
fn exitOnBreakpoint(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    if (info.ExceptionRecord.ExceptionCode != STATUS_BREAKPOINT) return windows.EXCEPTION_CONTINUE_SEARCH;
    _ = win32_sys.TerminateProcess(windows.GetCurrentProcess(), exit_panicked);
    return windows.EXCEPTION_CONTINUE_SEARCH;
}

/// A test's name as `builtin.test_functions` holds it, from the `@src()` of
/// its block: the file under the module root with `.` for each separator
/// and no `.zig`, then `.test.<name>`.
pub fn qualifiedName(buf: []u8, src: std.builtin.SourceLocation) error{ NotATestBlock, NoSpace }![]const u8 {
    if (!std.mem.startsWith(u8, src.fn_name, "test.")) return error.NotATestBlock;
    if (!std.mem.endsWith(u8, src.file, ".zig")) return error.NotATestBlock;
    const stem = src.file[0 .. src.file.len - ".zig".len];
    const out = std.fmt.bufPrint(buf, "{s}.{s}", .{ stem, src.fn_name }) catch return error.NoSpace;
    for (out[0..stem.len]) |*c| {
        if (c.* == '\\' or c.* == '/') c.* = '.';
    }
    return out;
}

/// Where the child writes its dump.
pub const Dumps = enum {
    /// Nowhere: the variable is removed.
    none,
    /// A fresh directory of its own.
    own,
};

/// A finished child.
pub const Child = struct {
    term: std.process.Child.Term,
    /// The whole exit code: `term` keeps only its low byte.
    exit_code: u32,
    stderr: []u8,
    timed_out: bool,
    /// Its dump directory, for `Dumps.own`.
    dir: ?dump.TestDir,

    pub fn deinit(self: *Child) void {
        std.testing.allocator.free(self.stderr);
        if (self.dir) |*d| d.deinit();
    }

    /// Prints what a failed verdict needs: the exit and the end of stderr.
    fn explain(self: *const Child, comptime why: []const u8, args: anytype) void {
        const tail = self.stderr[self.stderr.len -| 4000..];
        std.debug.print("isolated parent: " ++ why ++ "\n  child exit code: 0x{x} (timed out: {})\n  child stderr (its end):\n{s}\n", args ++ .{
            self.exit_code, self.timed_out, tail,
        });
    }
};

/// The child's environment: this process's, without the build runner's
/// progress pipe, the symbolise mode or the run's dump directory, with the
/// test's name, and with `dump_dir` as its dump directory if one is given.
pub fn childEnvironment(a: Allocator, qualified: []const u8, dump_dir: ?[]const u8) !std.process.Environ.Map {
    var env = try std.testing.environ.createMap(a);
    errdefer env.deinit();
    _ = env.orderedRemove("ZIG_PROGRESS");
    _ = env.orderedRemove(symbolise.raw_env);
    _ = env.orderedRemove(dump.env_var);
    try env.put(child_env, qualified);
    if (dump_dir) |dir| try env.put(dump.env_var, dir);
    return env;
}

const Deadline = struct {
    handle: windows.HANDLE,
    timed_out: bool = false,

    /// The parent's watcher thread, the registry's `Deadline.run` entry: a
    /// test helper that takes no renderer lock (acceptance test 9).
    fn run(self: *Deadline) void {
        const role_scope = thread_role.enter(.test_support);
        defer role_scope.exit();
        win32_sys.waitForSingleObject(self.handle, child_deadline_ms) catch {
            self.timed_out = true;
            win32_sys.terminateProcess(self.handle, 124) catch {};
        };
    }
};

/// Starts this exe as the isolated child of the calling test and waits for
/// it. `src` is the test block's `@src()`.
pub fn run(src: std.builtin.SourceLocation, dumps: Dumps) !Child {
    const a = std.testing.allocator;
    if (running_child or std.testing.environ.containsConstant(child_env)) return error.IsolatedChildStartsNoChild;
    var name_buf: [1024]u8 = undefined;
    const qualified = try qualifiedName(&name_buf, src);

    var dir: ?dump.TestDir = if (dumps == .own) try dump.TestDir.init() else null;
    errdefer if (dir) |*d| d.deinit();
    const dir_utf8: ?[]u8 = if (dir) |d| try std.unicode.wtf16LeToWtf8Alloc(a, d.path) else null;
    defer if (dir_utf8) |d| a.free(d);

    var env = try childEnvironment(a, qualified, dir_utf8);
    defer env.deinit();
    const io = std.testing.io;
    const exe = try std.process.executablePathAlloc(io, a);
    defer a.free(exe);

    var child = try std.process.spawn(io, .{
        .argv = &.{exe},
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    var waited = false;
    errdefer if (!waited) child.kill(io);
    var deadline: Deadline = .{ .handle = child.id.? };
    const watcher = try std.Thread.spawn(.{}, Deadline.run, .{&deadline});
    // Both pipes until they end, as 0.15's `collectOutput` with a 4 MiB
    // limit on each.
    const collected = collectOutput(io, a, &child, 4 << 20);
    errdefer if (collected) |s| a.free(s) else |_| {};
    watcher.join();
    // Read before `wait`, which keeps only the low byte and closes the handle.
    var exit_code: windows.DWORD = 0;
    if (win32_sys.GetExitCodeProcess(child.id.?, &exit_code) == 0) exit_code = 0xffff_ffff;
    const term = try child.wait(io);
    waited = true;
    const stderr = try collected;
    return .{
        .term = term,
        .exit_code = exit_code,
        .stderr = stderr,
        .timed_out = deadline.timed_out,
        .dir = dir,
    };
}

/// Reads the child's stdout and stderr pipes to their ends and returns its
/// stderr (stdout is read and dropped), failing as 0.15's
/// `std.process.Child.collectOutput` did when either passes `max_bytes`.
fn collectOutput(io: std.Io, a: Allocator, child: *std.process.Child, max_bytes: usize) ![]u8 {
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(a, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(64, .none)) |_| {
        if (multi_reader.reader(0).buffered().len > max_bytes) return error.StdoutStreamTooLong;
        if (multi_reader.reader(1).buffered().len > max_bytes) return error.StderrStreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    return multi_reader.toOwnedSlice(1);
}

/// Whether the dispatch ran the child's test as its first: the runner's
/// header for test 0 (`1/<n> main.test_0...`) and then the marker naming it.
fn dispatchedFirst(stderr: []const u8, qualified: []const u8) bool {
    if (!std.mem.startsWith(u8, stderr, "1/")) return false;
    const header_end = std.mem.indexOf(u8, stderr, "...") orelse return false;
    var rest = stderr[header_end + 3 ..];
    if (!std.mem.startsWith(u8, rest, dispatch_marker)) return false;
    rest = rest[dispatch_marker.len..];
    return std.mem.startsWith(u8, rest, qualified) and rest.len > qualified.len and rest[qualified.len] == '\n';
}

fn expectDispatched(child: *const Child, src: std.builtin.SourceLocation) !void {
    var name_buf: [1024]u8 = undefined;
    const qualified = try qualifiedName(&name_buf, src);
    if (!dispatchedFirst(child.stderr, qualified)) {
        child.explain("the dispatch did not run the test as the child's first", .{});
        return error.IsolatedChildNotDispatched;
    }
}

/// A panic variant: the child exits abnormally, with Zig's panic exit code,
/// and its stderr holds `panic: <text>`.
pub fn expectPanic(src: std.builtin.SourceLocation, text: []const u8) !void {
    var child = try run(src, .none);
    defer child.deinit();
    try expectPanicked(&child, src, text);
}

/// `expectPanic`'s verdict for a child the caller ran itself (`run`), for
/// a test that also reads what the child left in its own directory.
pub fn expectChildPanicked(child: *const Child, src: std.builtin.SourceLocation, text: []const u8) !void {
    return expectPanicked(child, src, text);
}

fn expectPanicked(child: *const Child, src: std.builtin.SourceLocation, text: []const u8) !void {
    try expectDispatched(child, src);
    const panicked = !child.timed_out and child.exit_code == exit_panicked;
    if (!panicked) {
        child.explain("expected the child to panic", .{});
        return error.IsolatedChildDidNotPanic;
    }
    var want_buf: [1024]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "panic: {s}", .{text});
    if (std.mem.indexOf(u8, child.stderr, want) == null) {
        child.explain("the child's panic text is not \"{s}\"", .{text});
        return error.IsolatedChildPanicText;
    }
}

/// A (function key, role) pair as the symbolised dump writes it.
pub const Pair = struct {
    function: []const u8,
    role: []const u8,
};

/// A panic variant that also compares its dump (acceptance test 12): the
/// child panics with `text`, and the compare of its own directory passes
/// with exactly `pairs`. Where this build's tests check no names
/// (`symbolise.names_checked`, RQ16), the dump holds exactly the pairs'
/// roles instead, and the compare, which keys pairs by name, is not judged.
pub fn expectPanicPairs(src: std.builtin.SourceLocation, text: []const u8, pairs: []const Pair) !void {
    var child = try run(src, .own);
    defer child.deinit();
    try expectPanicked(&child, src, text);
    var result = try compareChild(&child);
    defer result.deinit();
    const held = if (symbolise.names_checked)
        result.report.passed() and result.holdsExactly(pairs)
    else
        result.holdsRoles(pairs);
    if (!held) {
        result.explain(&child, "expected the child's compare to pass with exactly its pairs");
        return error.IsolatedChildCompare;
    }
}

/// A child that breaks no policy and whose pairs are all in the table
/// (acceptance test 2): it exits successfully, and the compare of its own
/// directory passes with exactly `pairs` (their roles alone where this
/// build's tests check no names, RQ16).
pub fn expectPairs(src: std.builtin.SourceLocation, pairs: []const Pair) !void {
    var child = try run(src, .own);
    defer child.deinit();
    try expectExited(&child, src);
    var result = try compareChild(&child);
    defer result.deinit();
    const held = if (symbolise.names_checked)
        result.report.passed() and result.holdsExactly(pairs)
    else
        result.holdsRoles(pairs);
    if (!held) {
        result.explain(&child, "expected the child's compare to pass with exactly its pairs");
        return error.IsolatedChildCompare;
    }
}

/// An off-table variant (acceptance tests 4 and 8): the child exits
/// successfully, and the compare of its own directory fails with exactly
/// one failure, the PAIR-OUTSIDE-TABLE naming `pair` (its role alone where
/// this build's tests check no names, RQ16).
pub fn expectOffTable(src: std.builtin.SourceLocation, pair: Pair) !void {
    var child = try run(src, .own);
    defer child.deinit();
    try expectExited(&child, src);
    var result = try compareChild(&child);
    defer result.deinit();
    var line_buf: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "FAIL PAIR-OUTSIDE-TABLE {s}: ({s}, {s})", .{
        result.dump_name orelse "?", pair.function, pair.role,
    });
    var tail_buf: [256]u8 = undefined;
    const tail = try std.fmt.bufPrint(&tail_buf, ", {s})", .{pair.role});
    const named = if (symbolise.names_checked)
        result.report.hasLine(line)
    else
        result.report.count(.pair_outside_table) == 1 and
            std.mem.endsWith(u8, result.report.failures.items[0].line, tail);
    if (result.report.failures.items.len != 1 or !named) {
        result.explain(&child, "expected exactly one PAIR-OUTSIDE-TABLE naming the pair");
        return error.IsolatedChildCompare;
    }
}

fn expectExited(child: *const Child, src: std.builtin.SourceLocation) !void {
    try expectDispatched(child, src);
    if (child.timed_out or child.exit_code != exit_passed) {
        child.explain("expected the child to exit successfully", .{});
        return error.IsolatedChildFailed;
    }
}

/// A child's own directory, symbolised and compared.
pub const Compared = struct {
    arena: std.heap.ArenaAllocator,
    report: compare.Report,
    /// The symbolised dumps.
    dumps: []compare.Dump,
    /// The one dump's name, when there is one.
    dump_name: ?[]const u8,

    pub fn deinit(self: *Compared) void {
        self.report.deinit();
        self.arena.deinit();
    }

    /// Whether the dumps hold exactly these pairs, each once, and no other.
    pub fn holdsExactly(self: *const Compared, pairs: []const Pair) bool {
        var lines: usize = 0;
        for (self.dumps) |d| {
            var it = std.mem.splitScalar(u8, d.text, '\n');
            _ = it.next();
            while (it.next()) |line| lines += @intFromBool(line.len > 0);
        }
        if (lines != pairs.len) return false;
        for (pairs) |pair| {
            var found: usize = 0;
            for (self.dumps) |d| {
                var it = std.mem.splitScalar(u8, d.text, '\n');
                _ = it.next();
                while (it.next()) |line| {
                    const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
                    if (std.mem.eql(u8, line[0..space], pair.function) and std.mem.eql(u8, line[space + 1 ..], pair.role)) found += 1;
                }
            }
            if (found != 1) return false;
        }
        return true;
    }

    /// Whether the dumps hold exactly as many pairs as `pairs`, with the
    /// same roles, whatever their keys (RQ16's role-only check).
    pub fn holdsRoles(self: *const Compared, pairs: []const Pair) bool {
        var lines: usize = 0;
        for (self.dumps) |d| {
            var it = std.mem.splitScalar(u8, d.text, '\n');
            _ = it.next();
            while (it.next()) |line| lines += @intFromBool(line.len > 0);
        }
        if (lines != pairs.len) return false;
        for (pairs) |pair| {
            var want: usize = 0;
            for (pairs) |other| want += @intFromBool(std.mem.eql(u8, other.role, pair.role));
            var found: usize = 0;
            for (self.dumps) |d| {
                var it = std.mem.splitScalar(u8, d.text, '\n');
                _ = it.next();
                while (it.next()) |line| {
                    const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
                    found += @intFromBool(std.mem.eql(u8, line[space + 1 ..], pair.role));
                }
            }
            if (found != want) return false;
        }
        return true;
    }

    fn explain(self: *const Compared, child: *const Child, why: []const u8) void {
        var buf: [8192]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        self.report.format(&w) catch {};
        for (self.dumps) |d| w.print("-- {s}\n{s}", .{ d.name, d.text }) catch {};
        child.explain("{s}\n  compare:\n{s}", .{ why, w.buffered() });
    }
};

/// Where the in-process compare reads the reviewed table: `table_env`'s
/// path, which must be drive-absolute (error.NotDriveAbsolute), else the
/// table under the source root.
pub fn tablePathAlloc(a: Allocator, session: *const symbolise.Session) ![]u8 {
    if (try symbolise.envPath(a, table_env)) |path| return path;
    const root = try session.sourceRoot(a);
    defer a.free(root);
    return std.fs.path.join(a, &.{ root, table_path });
}

/// Symbolises the child's dumps against this exe (the child is this exe, so
/// its PDB is this process's) and compares them with the reviewed table.
pub fn compareChild(child: *Child) !Compared {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const dir = if (child.dir) |*d| d else return error.IsolatedChildHasNoDumpDirectory;

    const own_pdb = (dump.selfModule() orelse return error.NoModule).pdb;
    const root, const table = setup: {
        // A session holds DbgHelp's lock until it closes, on every path.
        var session = try symbolise.Session.openSelf(aa);
        defer session.close();
        const root = try session.sourceRoot(aa);
        const path = try tablePathAlloc(aa, &session);
        const table = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, aa, .limited(16 << 20)) catch |err| {
            std.debug.print("isolated parent: the reviewed table cannot be read ({s}); set " ++ table_env ++
                " or run from a build whose checkout holds " ++ table_path ++ "\n", .{@errorName(err)});
            return err;
        };
        break :setup .{ root, table };
    };

    var dumps: std.ArrayListUnmanaged(compare.Dump) = .empty;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| try names.append(aa, try aa.dupe(u8, entry.name));
    for (names.items) |name| {
        const raw = try dir.tmp.dir.readFileAlloc(std.testing.io, name, aa, .limited(16 << 20));
        if (!std.mem.endsWith(u8, name, dump.extension)) continue;
        var s = try symbolise.Session.openSelf(aa);
        defer s.close();
        const result = try symbolise.symbolise(aa, raw, &s, own_pdb, root);
        if (result.problem) |problem| {
            std.debug.print("isolated parent: the child's dump {s} cannot be symbolised: {s}\n", .{ name, @tagName(problem) });
            return error.IsolatedChildDumpNotSymbolised;
        }
        try dumps.append(aa, .{ .name = name, .text = result.text });
    }
    const report = try compare.isolated(a, table, compare.tree_scope, dumps.items, .{});
    return .{
        .arena = arena,
        .report = report,
        .dumps = dumps.items,
        .dump_name = if (dumps.items.len == 1) dumps.items[0].name else null,
    };
}

const testing = std.testing;
const StateMutex = state_mutex.StateMutex;

test {
    _ = compare;
    _ = symbolise;
}

test "a test's qualified name comes from its block's @src()" {
    var buf: [256]u8 = undefined;
    const here = @src();
    try testing.expectEqualStrings("sync.isolated.test.a test's qualified name comes from its block's @src()", try qualifiedName(&buf, here));
    // A name in builtin.test_functions, as the dispatch finds it.
    var found = false;
    for (builtin.test_functions) |test_fn| found = found or std.mem.eql(u8, test_fn.name, try qualifiedName(&buf, here));
    try testing.expect(found);
    var fake = here;
    fake.file = "a/b\\c.zig";
    fake.fn_name = "test.x y";
    try testing.expectEqualStrings("a.b.c.test.x y", try qualifiedName(&buf, fake));
    fake.fn_name = "helper";
    try testing.expectError(error.NotATestBlock, qualifiedName(&buf, fake));
    fake.fn_name = "test.x";
    try testing.expectError(error.NoSpace, qualifiedName(buf[0..4], fake));
}

test "a child's environment drops the progress pipe and the run's dump directory and names its test" {
    const a = testing.allocator;
    var env = try childEnvironment(a, "sync.isolated.test.x", null);
    defer env.deinit();
    try testing.expectEqualStrings("sync.isolated.test.x", env.get(child_env).?);
    try testing.expect(env.get("ZIG_PROGRESS") == null);
    try testing.expect(env.get(dump.env_var) == null);
    try testing.expect(env.get(symbolise.raw_env) == null);
    var own = try childEnvironment(a, "sync.isolated.test.x", "C:\\child\\own");
    defer own.deinit();
    try testing.expectEqualStrings("C:\\child\\own", own.get(dump.env_var).?);
}

test "the table variable must name a drive-absolute path" {
    const a = testing.allocator;
    const name = std.unicode.utf8ToUtf16LeStringLiteral(table_env);
    // A run may set it; it is put back as it was.
    var saved_buf: [32768]u16 = undefined;
    const saved_len = GetEnvironmentVariableW(name, &saved_buf, saved_buf.len);
    if (saved_len >= saved_buf.len) return error.SkipZigTest;
    saved_buf[saved_len] = 0;
    defer _ = SetEnvironmentVariableW(name, if (saved_len == 0) null else saved_buf[0..saved_len :0].ptr);

    for ([_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("ci\\lock-inventory-threads.tsv"),
        std.unicode.utf8ToUtf16LeStringLiteral("\\\\server\\share\\t.tsv"),
        std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\t.tsv"),
        std.unicode.utf8ToUtf16LeStringLiteral("C:t.tsv"),
        std.unicode.utf8ToUtf16LeStringLiteral("C:\\t.tsv:stream"),
    }) |value| {
        try testing.expect(SetEnvironmentVariableW(name, value.ptr) != 0);
        try testing.expectError(error.NotDriveAbsolute, symbolise.envPath(a, table_env));
    }
    try testing.expect(SetEnvironmentVariableW(name, std.unicode.utf8ToUtf16LeStringLiteral("C:\\ci\\t.tsv").ptr) != 0);
    const path = (try symbolise.envPath(a, table_env)).?;
    defer a.free(path);
    try testing.expectEqualStrings("C:\\ci\\t.tsv", path);
}

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: [*]u16, size: u32) callconv(.winapi) u32;
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) win32_types.BOOL;

test "the dispatch check reads the runner's header for test 0 and then the marker" {
    try testing.expect(dispatchedFirst("1/6800 main.test_0..." ++ dispatch_marker ++ "a.test.b\nthread 1 panic: x", "a.test.b"));
    try testing.expect(!dispatchedFirst("1/6800 main.test_0...OK\n2/6800 main.test_1..." ++ dispatch_marker ++ "a.test.b\n", "a.test.b"));
    try testing.expect(!dispatchedFirst("1/6800 main.test_0..." ++ dispatch_marker ++ "a.test.bc\n", "a.test.b"));
    try testing.expect(!dispatchedFirst("", "a.test.b"));
}

test "isolated: a child starts no child" {
    if (inChild()) {
        // In the child, a parent's call is refused before it starts anything.
        var child = run(@src(), .none) catch |err| {
            if (err == error.IsolatedChildStartsNoChild) return;
            return err;
        };
        child.deinit();
        return error.TestUnexpectedResult;
    }
    var child = try run(@src(), .none);
    defer child.deinit();
    try expectExited(&child, @src());
}

test "isolated: a 16-slot recorder panics on its 17th distinct pair with PN5's text (acceptance test 12)" {
    if (inChild()) {
        var slots = recorder.Recorder(16).empty;
        var rec: recorder.Recorder(16) = .{ .slots = &slots, .sink = .{ .target = .none } };
        for (0..17) |i| rec.record(0x7ff600001000 + i * 0x10, .ui, .lock);
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN5 the pair recorder is full: more than 16 distinct " ++
        "(acquiring function, role) pairs in one process");
}

test "isolated: a child that acquires at two sites and then panics keeps both pairs, and its compare passes (acceptance test 12)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    // Two bodies that differ (each its own store), so no build folds them
    // into one symbol (identical-code folding in a release mode).
    const Sites = struct {
        var first: u32 = 0;
        var second: u64 = 0;

        noinline fn isolatedFirstSite(m: *StateMutex) void {
            m.lock();
            first += 1;
            m.unlock();
        }

        noinline fn isolatedSecondSite(m: *StateMutex) void {
            m.lock();
            second +%= 0x5eed;
            m.unlock();
        }
    };
    if (inChild()) {
        const scope = thread_role.fixture(.ui);
        defer scope.exit();
        var m: StateMutex = .{};
        Sites.isolatedFirstSite(&m);
        Sites.isolatedSecondSite(&m);
        @panic("isolated test 12: a panic after acquiring at two sites");
    }
    try expectPanicPairs(@src(), "isolated test 12: a panic after acquiring at two sites", &.{
        .{ .function = "src/sync/isolated.zig:isolatedFirstSite", .role = "ui" },
        .{ .function = "src/sync/isolated.zig:isolatedSecondSite", .role = "ui" },
    });
}

test "isolated: a plain lock from .renderer panics with PN3 (acceptance test 1)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        const scope = thread_role.fixture(.renderer);
        defer scope.exit();
        var m: StateMutex = .{};
        m.lock();
        m.unlock();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN3 a plain lock of the renderer-state mutex from " ++
        "renderer; the renderer acquires through State.lockDemand or tryLock");
}

test "isolated: a plain lockUncancelable from .renderer panics with PN3 (acceptance test 1)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        const scope = thread_role.fixture(.renderer);
        defer scope.exit();
        var m: StateMutex = .{};
        m.lockUncancelable();
        m.unlock();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN3 a plain lockUncancelable of the renderer-state mutex from " ++
        "renderer; the renderer acquires through State.lockDemand or tryLock");
}

test "isolated: an off-table child exits successfully and its compare fails one PAIR-OUTSIDE-TABLE naming the pair (acceptance test 8)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    const Sites = struct {
        /// Its row lists `ui`; the child simulates `.termio`.
        noinline fn isolatedOffTableSite(m: *StateMutex) void {
            m.lock();
            m.unlock();
        }
    };
    if (inChild()) {
        const scope = thread_role.fixture(.termio);
        defer scope.exit();
        var m: StateMutex = .{};
        Sites.isolatedOffTableSite(&m);
        return;
    }
    try expectOffTable(@src(), .{ .function = "src/sync/isolated.zig:isolatedOffTableSite", .role = "termio" });
}

test "isolated: a child that acquires nothing leaves no dump, and its compare fails MISSING-DUMP (acceptance test 8)" {
    if (inChild()) return;
    var child = try run(@src(), .own);
    defer child.deinit();
    try expectExited(&child, @src());
    var result = try compareChild(&child);
    defer result.deinit();
    try testing.expectEqual(@as(usize, 1), result.report.failures.items.len);
    try testing.expect(result.report.hasLine("FAIL MISSING-DUMP isolated child: no child dump in its directory"));
}

test "isolated: a fixture scope entered on a thread that has a role panics with PN6 (acceptance test 15)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        const outer = thread_role.enter(.termio);
        defer outer.exit();
        const scope = thread_role.fixture(.ui);
        scope.exit();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN6 a fixture scope for role ui entered on a thread whose role is termio");
}

test "isolated: a scope exited out of order panics with PN6 (acceptance test 15)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        const outer = thread_role.fixture(.ui);
        const inner = thread_role.enter(.reader);
        outer.exit();
        inner.exit();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN6 a fixture scope exited out of order (its depth 1, the thread's 2)");
}

test "isolated: an unscoped unit-test acquisition panics with PN4, and its text names the fix (acceptance test 3)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        // No fixture: the child's test thread has no role.
        var m: StateMutex = .{};
        m.lock();
        m.unlock();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN4 lock of the renderer-state mutex from a thread with no " ++
        "role; a test enters the role it simulates first: `const scope = thread_role.fixture(.<role>); " ++
        "defer scope.exit();`");
}

test "isolated: an acquisition from a thread with no role panics with PN4 (acceptance test 3)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    const Sites = struct {
        /// Reviewed for the UI thread; the child runs it on a thread that
        /// entered no role, as a helper thread that forgot its role would.
        fn noRoleThreadSite(m: *StateMutex) void {
            if (m.tryLock()) m.unlock();
        }
    };
    if (inChild()) {
        // The test thread has a role, and the thread it starts has none: a
        // role is the thread's own, never inherited.
        const scope = thread_role.fixture(.ui);
        defer scope.exit();
        var m: StateMutex = .{};
        const thread = try std.Thread.spawn(.{}, Sites.noRoleThreadSite, .{&m});
        thread.join();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN4 tryLock of the renderer-state mutex from a thread with no " ++
        "role; a test enters the role it simulates first");
}

test "isolated: a fixture that simulates the wrong role fails its compare with one PAIR-OUTSIDE-TABLE (acceptance test 4)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        // This test block's row lists ui; its fixture enters .termio.
        const scope = thread_role.fixture(.termio);
        defer scope.exit();
        var m: StateMutex = .{};
        m.lock();
        m.unlock();
        return;
    }
    // A test block's own pair is keyed `test.<name>`, as std.debug names it.
    try expectOffTable(@src(), .{ .function = "src/sync/isolated.zig:" ++ @src().fn_name, .role = "termio" });
}

test "isolated: a blocking re-entry by lock panics with PN1 (acceptance test 6)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        const scope = thread_role.fixture(.ui);
        defer scope.exit();
        var m: StateMutex = .{};
        m.lock();
        m.lock();
        m.unlock();
        return;
    }
    // PN1 is checked before the inner lock, so its text wins over Zig's own
    // "Deadlock detected".
    try expectPanic(@src(), "thread-role layer: PN1 a blocking re-entry: lock of the renderer-state mutex by " ++
        "the thread that holds it (role ui)");
}

test "isolated: a blocking re-entry by lockUncancelable panics with PN1 (acceptance test 6)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        const scope = thread_role.fixture(.ui);
        defer scope.exit();
        var m: StateMutex = .{};
        m.lock();
        m.lockUncancelable();
        m.unlock();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN1 a blocking re-entry: lockUncancelable of the renderer-state " ++
        "mutex by the thread that holds it (role ui)");
}

test "isolated: a blocking re-entry by the demand acquire panics with PN1 (acceptance test 6)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    if (inChild()) {
        // The renderer's own way in: PN3 allows it, and a re-entry still panics.
        const scope = thread_role.fixture(.renderer);
        defer scope.exit();
        var m: StateMutex = .{};
        m.demand();
        m.demand();
        m.unlock();
        return;
    }
    try expectPanic(@src(), "thread-role layer: PN1 a blocking re-entry: the demand acquire of the " ++
        "renderer-state mutex by the thread that holds it (role renderer)");
}

/// One function key a site-shape child's symbolised dump must hold: `lines`
/// lines naming `name`; for an instantiation of a comptime-parameter
/// function, each with its own instantiation suffix (`__anon_N` on 0.15.2,
/// `__func_N` on 0.17.1), which the compare strips.
pub const ShapeLine = struct {
    name: []const u8,
    lines: usize = 1,
    instantiated: bool = false,
};

/// Whether the dumps hold exactly the `want` lines, each keyed
/// `<file_prefix><name>` with `role`, and no other line (acceptance test 10).
pub fn holdsShapes(result: *const Compared, file_prefix: []const u8, want: []const ShapeLine, role: []const u8) bool {
    var total: usize = 0;
    for (want) |w| total += w.lines;
    var lines: usize = 0;
    for (result.dumps) |d| {
        var it = std.mem.splitScalar(u8, d.text, '\n');
        _ = it.next();
        while (it.next()) |line| lines += @intFromBool(line.len > 0);
    }
    if (lines != total) return false;
    for (want) |w| {
        var found: usize = 0;
        var first_suffix: ?[]const u8 = null;
        for (result.dumps) |d| {
            var it = std.mem.splitScalar(u8, d.text, '\n');
            _ = it.next();
            while (it.next()) |line| {
                const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse continue;
                if (!std.mem.eql(u8, line[space + 1 ..], role)) continue;
                const key = line[0..space];
                if (!std.mem.startsWith(u8, key, file_prefix)) continue;
                const symbol = key[file_prefix.len..];
                if (!std.mem.startsWith(u8, symbol, w.name)) continue;
                const suffix = symbol[w.name.len..];
                if (!w.instantiated) {
                    found += @intFromBool(suffix.len == 0);
                    continue;
                }
                if (!instantiationSuffix(suffix)) continue;
                // Each instantiation is its own symbol.
                if (first_suffix) |s| {
                    if (std.mem.eql(u8, s, suffix)) return false;
                } else first_suffix = suffix;
                found += 1;
            }
        }
        if (found != w.lines) return false;
    }
    return true;
}

/// `__anon_<digits>` or `__func_<digits>`.
fn instantiationSuffix(suffix: []const u8) bool {
    const digits = if (std.mem.startsWith(u8, suffix, "__anon_"))
        suffix["__anon_".len..]
    else if (std.mem.startsWith(u8, suffix, "__func_"))
        suffix["__func_".len..]
    else
        return false;
    if (digits.len == 0) return false;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// A site-shape child (acceptance test 10): it exits successfully, and the
/// compare of its own directory passes with exactly `want`, every pair with
/// `role`. The caller skips where this build checks no names
/// (`symbolise.names_checked`).
pub fn expectShapes(src: std.builtin.SourceLocation, file_prefix: []const u8, want: []const ShapeLine, role: []const u8) !void {
    var child = try run(src, .own);
    defer child.deinit();
    try expectExited(&child, src);
    var result = try compareChild(&child);
    defer result.deinit();
    if (!result.report.passed() or !holdsShapes(&result, file_prefix, want, role)) {
        result.explain(&child, "expected the compare to pass with each shape's acquiring function");
        return error.IsolatedChildCompare;
    }
}

test "an instantiation suffix is __anon_ or __func_ and digits" {
    try testing.expect(instantiationSuffix("__anon_30924"));
    try testing.expect(instantiationSuffix("__func_721"));
    try testing.expect(!instantiationSuffix(""));
    try testing.expect(!instantiationSuffix("__anon_"));
    try testing.expect(!instantiationSuffix("__anon_12x"));
    try testing.expect(!instantiationSuffix("_anon_12"));
}

test "isolated: the compare names the acquiring function of every site shape (acceptance test 10)" {
    if (thread_role.layer == .off) return error.SkipZigTest;
    // RQ16: a 0.15.2 ReleaseSafe build attributes noinline functions only;
    // this test checks nothing but names, so it is skipped there. The demand
    // forwarder's shape is acceptance test 2's (src/renderer/State.zig), a
    // site in a function that was an inline fn is the Debug suite's required
    // pair (surfaceMessageWriter, reader), and Surface.confirmQuitAnswer's
    // two instantiations are checked in src/Surface.zig.
    if (!symbolise.names_checked) return error.SkipZigTest;
    // Each shape's site is its function's only acquisition, so its pair can
    // name nothing else; each body differs from the others' (its own store).
    const Shapes = struct {
        var counter: u64 = 0;

        fn shapePlainSite(m: *StateMutex) void {
            m.lock();
            defer m.unlock();
            counter +%= 1;
        }

        /// An always_inline target made non-inline in Debug (RQ11's fix, as
        /// Exec.zig calls processOutput): the site is attributed to it.
        fn shapeAutoTarget(m: *StateMutex) void {
            m.lock();
            defer m.unlock();
            counter +%= 2;
        }

        fn shapeAutoCaller(m: *StateMutex) void {
            @call(if (builtin.mode == .debug) .auto else .always_inline, shapeAutoTarget, .{m});
        }

        /// The caller holds the mutex, and the relock is this function's
        /// last act, as `send` relocks in mailbox.zig.
        fn shapeDeferRelockSite(m: *StateMutex) void {
            m.unlock();
            defer m.lock();
            counter +%= 3;
        }

        fn shapeDeferRelockCaller(m: *StateMutex) void {
            m.lock();
            defer m.unlock();
            shapeDeferRelockSite(m);
            m.assertHeld();
        }

        fn shapeTryLockSite(m: *StateMutex) void {
            if (!m.tryLock()) return;
            defer m.unlock();
            counter +%= 4;
        }

        fn shapeLockUncancelableSite(m: *StateMutex) void {
            m.lockUncancelable();
            defer m.unlock();
            counter +%= 5;
        }

        /// Surface.confirmQuitAnswer's shape: each instantiation is its own
        /// symbol, with a suffix the compare strips.
        fn shapeComptimeSite(m: *StateMutex, comptime wait: bool) void {
            if (wait) m.lock() else if (!m.tryLock()) return;
            defer m.unlock();
            counter +%= if (wait) 6 else 7;
        }

        const Holder = struct {
            value: u64 = 0,

            fn shapeMethodSite(self: *Holder, m: *StateMutex) void {
                m.lock();
                defer m.unlock();
                self.value +%= 8;
            }

            const Inner = struct {
                fn shapeNestedSite(m: *StateMutex) void {
                    m.lock();
                    defer m.unlock();
                    counter +%= 9;
                }
            };
        };

        fn Box(comptime T: type) type {
            return struct {
                value: T = 0,

                fn shapeGenericSite(self: *@This(), m: *StateMutex) void {
                    m.lock();
                    defer m.unlock();
                    self.value +%= 10;
                }
            };
        }
    };
    if (inChild()) {
        const scope = thread_role.fixture(.ui);
        defer scope.exit();
        var m: StateMutex = .{};
        Shapes.shapePlainSite(&m);
        Shapes.shapeAutoCaller(&m);
        Shapes.shapeDeferRelockCaller(&m);
        Shapes.shapeTryLockSite(&m);
        Shapes.shapeLockUncancelableSite(&m);
        Shapes.shapeComptimeSite(&m, true);
        Shapes.shapeComptimeSite(&m, false);
        var holder: Shapes.Holder = .{};
        holder.shapeMethodSite(&m);
        Shapes.Holder.Inner.shapeNestedSite(&m);
        var small: Shapes.Box(u8) = .{};
        small.shapeGenericSite(&m);
        var wide: Shapes.Box(u64) = .{};
        wide.shapeGenericSite(&m);
        return;
    }
    // A struct method, a nested container's function and both instantiations
    // of a generic method are each named bare: the generic method's two are
    // two pairs of one key.
    try expectShapes(@src(), "src/sync/isolated.zig:", &.{
        .{ .name = "shapePlainSite" },
        .{ .name = "shapeAutoTarget" },
        .{ .name = "shapeDeferRelockCaller" },
        .{ .name = "shapeDeferRelockSite" },
        .{ .name = "shapeTryLockSite" },
        .{ .name = "shapeLockUncancelableSite" },
        .{ .name = "shapeComptimeSite", .lines = 2, .instantiated = true },
        .{ .name = "shapeMethodSite" },
        .{ .name = "shapeNestedSite" },
        .{ .name = "shapeGenericSite", .lines = 2 },
    }, "ui");
}
