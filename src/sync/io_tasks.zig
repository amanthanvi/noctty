//! The thread roles of `Io` tasks (PLAN.md §2.7 RQ7, decision 19) and their
//! acceptance test 19.
//!
//! `std.Io.Threaded` runs a task one of two ways. A pool worker std started
//! runs it, on a thread with no role; or, in four arms of `async` and four of
//! the group path (`groupAsync`, behind `Io.Group.async` and
//! `Io.Select.async`), the caller runs it itself before the call returns: a
//! single-threaded build, a failed allocation, the async limit reached and a
//! failed spawn. So an `Io` task's function opens with the role it simulates
//! the way `enterIfNone` enters it:
//!
//!     const scope = thread_role.enterIfNone(.search);
//!     defer scope.exit();
//!
//! On a pool worker that enters the task's role and its exit restores the
//! worker's none, so the next task the worker runs starts with no role; run
//! inline it enters nothing and the task keeps its caller's role, which is
//! the thread it runs on. A task that used `enter` would take its role over
//! the caller's while it ran inline, and an acquisition there would record
//! the wrong pair. Acceptance test 9's checker (`ci/thread_role_points.py`)
//! binds an `Io` task's registry entry to its task call and fails an `async`
//! one whose target opens with `enter` (ENTRY-TASK-ENTER); a `concurrent`
//! task, which always runs on a worker, opens with `enter` as a thread does.
//!
//! No product code starts an `Io` task yet (only the test runner's
//! `concurrent` input poller, which always gets a worker), so the rule is
//! latent until one does. These tests check the on form of the layer in every
//! build, through `Roles(.on)`, which shares the layer's thread-local role.
//! The limit and allocation-failure arms are driven; the single-threaded and
//! spawn-failure arms, which a test cannot force, are pinned in the source of
//! the std this binary was built from, which the test reads through its own
//! PDB (`symbolise.Session`).

const std = @import("std");
const builtin = @import("builtin");
const thread_role = @import("thread_role.zig");
const symbolise = @import("symbolise.zig");

const Io = std.Io;
const Role = thread_role.Role;
const On = thread_role.Roles(.on);
const testing = std.testing;

/// What one task saw of its thread's role.
const Seen = struct {
    /// The role on entry, before the task's own scope.
    before: Role = .none,
    /// The role inside its scope: what an acquisition there would record.
    inside: Role = .none,
    /// The role after its scope exited.
    after: Role = .none,
    thread: std.Thread.Id = 0,
    ran: bool = false,
};

/// Holds a pool-run task until the test opens it, so the next task meets a
/// busy pool.
const Gate = struct {
    open: std.atomic.Value(bool) = .init(false),
    /// The test's own thread: a task std ran there, inline, never waits for
    /// the gate, which only that thread opens.
    caller: std.Thread.Id,
};

/// The tests' `Io` tasks, in an `is_test` branch: their role scopes are test
/// edit points, not registry entries, to acceptance test 9's checker
/// (`ci/thread_role_points.py`).
const Tasks = if (builtin.is_test) struct {
    /// An `Io` task registered with role `.search`.
    fn search(seen: *Seen) void {
        seen.before = On.current();
        seen.thread = std.Thread.getCurrentId();
        {
            const scope = On.enterIfNone(.search);
            defer scope.exit();
            seen.inside = On.current();
        }
        seen.after = On.current();
        seen.ran = true;
    }

    /// The same task, held inside its scope until the gate opens.
    fn heldSearch(seen: *Seen, gate: *Gate) void {
        seen.before = On.current();
        seen.thread = std.Thread.getCurrentId();
        {
            const scope = On.enterIfNone(.search);
            defer scope.exit();
            seen.inside = On.current();
            if (seen.thread != gate.caller) {
                while (!gate.open.load(.acquire)) std.Thread.yield() catch {};
            }
        }
        seen.after = On.current();
        seen.ran = true;
    }
} else struct {};
const searchTask = Tasks.search;
const heldSearchTask = Tasks.heldSearch;

fn expectTag(expected: Role, got: Role) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(got));
}

/// Run inline on the `.ui` test thread: it kept the caller's role all
/// through, and entered nothing.
fn expectInline(seen: Seen, caller: std.Thread.Id) !void {
    try testing.expect(seen.ran);
    try testing.expectEqual(caller, seen.thread);
    try expectTag(.ui, seen.before);
    try expectTag(.ui, seen.inside);
    try expectTag(.ui, seen.after);
}

/// Run by a pool worker: no role on entry, its own role inside its scope,
/// and none again after it.
fn expectPooled(seen: Seen, caller: std.Thread.Id) !void {
    try testing.expect(seen.ran);
    try testing.expect(seen.thread != caller);
    try expectTag(.none, seen.before);
    try expectTag(.search, seen.inside);
    try expectTag(.none, seen.after);
}

test "acceptance test 19: Io.async at the async limit runs a .search task inline under the caller's .ui, and a pool worker's task enters .search and restores none" {
    const scope = On.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    var gate: Gate = .{ .caller = me };
    var held: Seen = .{};
    var first = io.async(heldSearchTask, .{ &held, &gate });
    // Opened and awaited whatever a check below finds, before the pool's
    // deinit joins its worker.
    defer {
        gate.open.store(true, .release);
        first.await(io);
    }
    try testing.expect(first.any_future != null);

    // The pool's one worker is busy: the limit arm runs it before `async`
    // returns, on this thread.
    var seen: Seen = .{};
    var second = io.async(searchTask, .{&seen});
    try testing.expect(second.any_future == null);
    second.await(io);
    try expectInline(seen, me);
    try expectTag(.ui, On.current());

    gate.open.store(true, .release);
    first.await(io);
    try expectPooled(held, me);

    // A later task the only worker runs starts with no role: the held
    // task's scope restored the worker's. With an async limit of 1 the pool
    // has one worker, and a task issued while std still counts the held one
    // busy (its worker counts it done after the await returns) runs inline
    // instead, so this retries until a task runs on the pool. (In the test
    // block: a non-test `async` call is a thread entry to the gate.)
    var tries: usize = 0;
    while (true) : (tries += 1) {
        var later: Seen = .{};
        var next = io.async(searchTask, .{&later});
        next.await(io);
        if (later.thread != me) {
            try testing.expectEqual(held.thread, later.thread);
            try expectPooled(later, me);
            break;
        }
        try expectInline(later, me);
        if (tries >= 10_000) return error.TestNoTaskReachedThePool;
        std.Thread.yield() catch {};
    }
    try expectTag(.ui, On.current());
}

test "acceptance test 19: Io.async whose future cannot be allocated runs a .search task inline under the caller's .ui" {
    const scope = On.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var threaded: Io.Threaded = .init(failing.allocator(), .{ .async_limit = .limited(4) });
    defer threaded.deinit();
    const io = threaded.io();

    var seen: Seen = .{};
    var task = io.async(searchTask, .{&seen});
    try testing.expect(task.any_future == null);
    task.await(io);
    try expectInline(seen, me);
    try testing.expect(failing.has_induced_failure and failing.allocations == 0);
    try expectTag(.ui, On.current());
}

test "acceptance test 19: Io.Group.async at the async limit runs a .search task inline under the caller's .ui, and its pool task enters .search" {
    const scope = On.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    var gate: Gate = .{ .caller = me };
    var held: Seen = .{};
    var group: Io.Group = .init;
    group.async(io, heldSearchTask, .{ &held, &gate });
    defer {
        gate.open.store(true, .release);
        group.await(io) catch {};
    }

    // groupAsync's limit arm runs it through groupAsyncEager before
    // `Group.async` returns.
    var seen: Seen = .{};
    group.async(io, searchTask, .{&seen});
    try expectInline(seen, me);

    gate.open.store(true, .release);
    try group.await(io);
    try expectPooled(held, me);
    try expectTag(.ui, On.current());
}

test "acceptance test 19: Io.Group.async whose task cannot be allocated runs a .search task inline under the caller's .ui" {
    const scope = On.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var threaded: Io.Threaded = .init(failing.allocator(), .{ .async_limit = .limited(4) });
    defer threaded.deinit();
    const io = threaded.io();

    var seen: Seen = .{};
    var group: Io.Group = .init;
    group.async(io, searchTask, .{&seen});
    try expectInline(seen, me);
    try group.await(io);
    try testing.expect(failing.has_induced_failure and failing.allocations == 0);
    try expectTag(.ui, On.current());
}

/// A select's result. Two fields, so it has a size: `Io.Queue` divides by
/// its element's (0.17.1 `lib/std/Io.zig` `putUncancelable`, `get`), and a
/// one-`void` union has none, which fails to compile.
const SelectResult = union(enum) { task: void, unused: void };

test "acceptance test 19: Io.Select.async at the async limit runs a .search task inline under the caller's .ui, and its pool task enters .search" {
    const scope = On.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var threaded: Io.Threaded = .init(testing.allocator, .{ .async_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    var gate: Gate = .{ .caller = me };
    var held: Seen = .{};
    var buffer: [2]SelectResult = undefined;
    var select: Io.Select(SelectResult) = .init(io, &buffer);
    select.async(.task, heldSearchTask, .{ &held, &gate });
    defer {
        gate.open.store(true, .release);
        select.cancelDiscard();
    }

    var seen: Seen = .{};
    select.async(.task, searchTask, .{&seen});
    try expectInline(seen, me);

    gate.open.store(true, .release);
    _ = try select.await();
    _ = try select.await();
    try expectPooled(held, me);
    try expectTag(.ui, On.current());
}

test "acceptance test 19: Io.Select.async whose task cannot be allocated runs a .search task inline under the caller's .ui" {
    const scope = On.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var threaded: Io.Threaded = .init(failing.allocator(), .{ .async_limit = .limited(4) });
    defer threaded.deinit();
    const io = threaded.io();

    var seen: Seen = .{};
    var buffer: [1]SelectResult = undefined;
    var select: Io.Select(SelectResult) = .init(io, &buffer);
    defer select.cancelDiscard();
    select.async(.task, searchTask, .{&seen});
    try expectInline(seen, me);
    _ = try select.await();
    try testing.expect(failing.has_induced_failure and failing.allocations == 0);
    try expectTag(.ui, On.current());
}

test "decision 19: the global Io's pool runs async inline beyond two busy workers and refuses a fifth concurrent task" {
    const pool = @import("../global.zig").io_pool;
    try testing.expectEqual(Io.Limit.limited(2), pool.async_limit);
    try testing.expectEqual(Io.Limit.limited(4), pool.concurrent_limit);
    try testing.expectEqual(std.Thread.SpawnConfig.default_stack_size, pool.stack_size);

    const scope = On.fixture(.ui);
    defer scope.exit();
    const me = std.Thread.getCurrentId();

    var threaded: Io.Threaded = .init(testing.allocator, .{
        .async_limit = pool.async_limit,
        .concurrent_limit = pool.concurrent_limit,
        .stack_size = pool.stack_size,
    });
    defer threaded.deinit();
    const io = threaded.io();
    try testing.expectEqual(pool.stack_size, threaded.stack_size);

    var gate: Gate = .{ .caller = me };
    var held: [4]Seen = @splat(.{});
    var futures: [4]Io.Future(void) = undefined;
    var started: usize = 0;
    defer {
        gate.open.store(true, .release);
        for (futures[0..started]) |*f| f.await(io);
    }
    // Two async tasks take the async limit's two workers.
    while (started < 2) : (started += 1) {
        futures[started] = io.async(heldSearchTask, .{ &held[started], &gate });
        try testing.expect(futures[started].any_future != null);
    }
    var seen: Seen = .{};
    var third = io.async(searchTask, .{&seen});
    try testing.expect(third.any_future == null);
    third.await(io);
    try expectInline(seen, me);
    // `concurrent` counts the same busy workers, up to four.
    while (started < 4) : (started += 1) {
        futures[started] = try io.concurrent(heldSearchTask, .{ &held[started], &gate });
    }
    var fifth_seen: Seen = .{};
    if (io.concurrent(searchTask, .{&fifth_seen})) |fifth| {
        var extra = fifth;
        extra.await(io);
        return error.TestFifthConcurrentTaskStarted;
    } else |err| try testing.expectEqual(error.ConcurrencyUnavailable, err);

    gate.open.store(true, .release);
    for (&futures) |*f| f.await(io);
    for (held) |h| try expectPooled(h, me);
}

// A worker's stack as Windows holds it (winnt.h MEMORY_BASIC_INFORMATION,
// 48 bytes on x64 and ARM64, pinned below; processthreadsapi.h
// GetCurrentThreadStackLimits; memoryapi.h VirtualQuery).
const MemoryBasicInformation = extern struct {
    base_address: ?*anyopaque,
    allocation_base: ?*anyopaque,
    allocation_protect: u32,
    partition_id: u16,
    region_size: usize,
    state: u32,
    protect: u32,
    region_type: u32,
};
const mem_commit: u32 = 0x1000;
extern "kernel32" fn GetCurrentThreadStackLimits(low: *usize, high: *usize) callconv(.winapi) void;
extern "kernel32" fn VirtualQuery(address: ?*const anyopaque, buffer: *MemoryBasicInformation, length: usize) callconv(.winapi) usize;

/// The calling thread's stack: its reserve, and how much of it is
/// committed, guard pages included.
const StackUse = struct {
    reserved: usize = 0,
    committed: usize = 0,
    thread: std.Thread.Id = 0,

    fn own() StackUse {
        var low: usize = 0;
        var high: usize = 0;
        GetCurrentThreadStackLimits(&low, &high);
        var use: StackUse = .{ .reserved = high - low, .thread = std.Thread.getCurrentId() };
        var at = low;
        while (at < high) {
            var info: MemoryBasicInformation = undefined;
            if (VirtualQuery(@ptrFromInt(at), &info, @sizeOf(MemoryBasicInformation)) == 0) break;
            const end = @min(high, @intFromPtr(info.base_address) + info.region_size);
            if (info.state == mem_commit) use.committed += end - at;
            at = end;
        }
        return use;
    }
};

/// A task that reads its worker's stack, held until the gate opens so each
/// of the pool's workers runs one.
fn stackTask(use: *StackUse, gate: *Gate) void {
    const seen: StackUse = .own();
    use.reserved = seen.reserved;
    use.committed = seen.committed;
    // Last, so the test reads the sizes once it sees the thread.
    @atomicStore(std.Thread.Id, &use.thread, seen.thread, .release);
    while (!gate.open.load(.acquire)) std.Thread.yield() catch {};
}

test "decision 19: each of the global Io pool's workers commits its whole stack, std's 16 MiB, so four commit 64 MiB" {
    // The layout is x64's and ARM64's alike (both LLP64 with 8-byte pointers).
    try testing.expectEqual(48, @sizeOf(MemoryBasicInformation));
    try testing.expectEqual(24, @offsetOf(MemoryBasicInformation, "region_size"));
    try testing.expectEqual(32, @offsetOf(MemoryBasicInformation, "state"));

    // 0.17.1's std.Thread.spawn passes the size to NtCreateThreadEx as the
    // stack's commit, with the image's reserve (lib/std/Thread.zig:560,
    // :592-604), and Io.Threaded spawns every worker with its stack_size.
    const pool = @import("../global.zig").io_pool;
    var threaded: Io.Threaded = .init(testing.allocator, .{
        .async_limit = pool.async_limit,
        .concurrent_limit = pool.concurrent_limit,
        .stack_size = pool.stack_size,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var gate: Gate = .{ .caller = std.Thread.getCurrentId() };
    var uses: [4]StackUse = @splat(.{});
    var futures: [4]Io.Future(void) = undefined;
    var started: usize = 0;
    defer {
        gate.open.store(true, .release);
        for (futures[0..started]) |*f| f.await(io);
    }
    while (started < uses.len) : (started += 1) {
        futures[started] = try io.concurrent(stackTask, .{ &uses[started], &gate });
    }
    // Each task has its own worker while the gate is shut.
    while (true) {
        var measured: usize = 0;
        for (&uses) |*u| {
            if (@atomicLoad(std.Thread.Id, &u.thread, .acquire) != 0) measured += 1;
        }
        if (measured == uses.len) break;
        std.Thread.yield() catch {};
    }
    gate.open.store(true, .release);
    for (&futures) |*f| f.await(io);

    var total: usize = 0;
    for (uses, 0..) |u, i| {
        for (uses[0..i]) |v| try testing.expect(u.thread != v.thread);
        try testing.expectEqual(pool.stack_size, u.reserved);
        try testing.expectEqual(pool.stack_size, u.committed);
        total += u.committed;
    }
    try testing.expectEqual(64 << 20, total);
}

/// One pinned line of `lib/std/Io/Threaded.zig`: its 1-based number and its
/// text, leading and trailing spaces trimmed.
const Pin = struct { line: usize, text: []const u8 };

/// Zig 0.17.1's `async`: the four arms that call `start` on the caller.
const async_pins = [_]Pin{
    .{ .line = 2114, .text = "fn async(" },
    // A single-threaded build.
    .{ .line = 2123, .text = "if (builtin.single_threaded) {" },
    .{ .line = 2124, .text = "start(context.ptr, result.ptr);" },
    .{ .line = 2125, .text = "return null;" },
    // The future's allocation failed.
    .{ .line = 2129, .text = "const future = Future.create(gpa, result.len, result_alignment, context, context_alignment, start) catch |err| switch (err) {" },
    .{ .line = 2130, .text = "error.OutOfMemory => {" },
    .{ .line = 2131, .text = "start(context.ptr, result.ptr);" },
    .{ .line = 2132, .text = "return null;" },
    // The async limit is reached.
    .{ .line = 2140, .text = "if (busy_count >= @backingInt(t.async_limit)) {" },
    .{ .line = 2143, .text = "start(context.ptr, result.ptr);" },
    .{ .line = 2144, .text = "return null;" },
    // The worker's spawn failed.
    .{ .line = 2152, .text = "const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch {" },
    .{ .line = 2157, .text = "start(context.ptr, result.ptr);" },
    .{ .line = 2158, .text = "return null;" },
    .{ .line = 2170, .text = "fn concurrent(" },
};

/// Its `groupAsync`: the same four arms, each through `groupAsyncEager`,
/// which calls `start` on the caller.
const group_pins = [_]Pin{
    .{ .line = 2216, .text = "fn groupAsync(" },
    .{ .line = 2226, .text = "if (builtin.single_threaded) return groupAsyncEager(start, context.ptr);" },
    .{ .line = 2229, .text = "const task = Group.Task.create(gpa, g, context, context_alignment, start) catch |err| switch (err) {" },
    .{ .line = 2230, .text = "error.OutOfMemory => return groupAsyncEager(start, context.ptr)," },
    .{ .line = 2237, .text = "if (busy_count >= @backingInt(t.async_limit)) {" },
    .{ .line = 2240, .text = "return groupAsyncEager(start, context.ptr);" },
    .{ .line = 2248, .text = "const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch {" },
    .{ .line = 2253, .text = "return groupAsyncEager(start, context.ptr);" },
    .{ .line = 2271, .text = "fn groupAsyncEager(" },
    .{ .line = 2275, .text = "start(context);" },
    .{ .line = 2276, .text = "}" },
    .{ .line = 2278, .text = "fn groupConcurrent(" },
};

fn expectFunctionName(bare: []const u8, name: []const u8) !void {
    if (std.mem.eql(u8, bare, name)) return;
    if (name.len > bare.len and std.mem.endsWith(u8, name, bare) and name[name.len - bare.len - 1] == '.') return;
    std.debug.print("the vtable's {s} is named \"{s}\"\n", .{ bare, name });
    return error.TestUnexpectedFunction;
}

fn trimmed(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

/// How many lines in `lines[first - 1 .. last - 1]` contain `needle`.
fn countIn(lines: []const []const u8, first: usize, last: usize, needle: []const u8) usize {
    var n: usize = 0;
    for (lines[first - 1 .. last - 1]) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) n += 1;
    }
    return n;
}

test "acceptance test 19: the std this binary was built from runs a task on its caller in async's four inline arms and groupAsync's four, at the pinned lines" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const a = testing.allocator;

    // `async` and `groupAsync` are private: the vtable names them.
    const vtable = Io.Threaded.global_single_threaded.io().vtable;
    var session = try symbolise.Session.openSelf(a);
    defer session.close();
    const async_at = (try session.locate(a, @intFromPtr(vtable.async))) orelse return error.TestAsyncNotLocated;
    defer async_at.deinit(a);
    const group_at = (try session.locate(a, @intFromPtr(vtable.groupAsync))) orelse return error.TestGroupAsyncNotLocated;
    defer group_at.deinit(a);
    // DbgHelp names a function by its bare name on 0.17.1 (`symbolise`'s
    // keys), a qualified one if a later compiler writes it.
    try expectFunctionName("async", async_at.name);
    try expectFunctionName("groupAsync", group_at.name);
    try testing.expectEqualStrings(async_at.file, group_at.file);
    const tail = "lib\\std\\Io\\Threaded.zig";
    try testing.expect(async_at.file.len > tail.len);
    for (async_at.file[async_at.file.len - tail.len ..], tail) |got, want| {
        try testing.expectEqual(std.ascii.toLower(want), if (got == '/') '\\' else std.ascii.toLower(got));
    }

    const source = try Io.Dir.cwd().readFileAlloc(testing.io, async_at.file, a, .limited(8 << 20));
    defer a.free(source);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| try lines.append(a, line);

    for (async_pins ++ group_pins) |pin| {
        try testing.expect(pin.line <= lines.items.len);
        const got = trimmed(lines.items[pin.line - 1]);
        if (!std.mem.eql(u8, pin.text, got)) {
            std.debug.print("lib/std/Io/Threaded.zig:{d}: pinned \"{s}\", found \"{s}\"\n", .{ pin.line, pin.text, got });
            return error.TestStdArmMoved;
        }
    }
    // No fifth arm: `async` calls `start` four times, `groupAsync` its eager
    // path four times, and the eager path is the call alone.
    try testing.expectEqual(4, countIn(lines.items, 2114, 2170, "start(context.ptr, result.ptr);"));
    try testing.expectEqual(4, countIn(lines.items, 2216, 2271, "groupAsyncEager(start, context.ptr)"));
    try testing.expectEqual(1, countIn(lines.items, 2271, 2278, "start("));
}
