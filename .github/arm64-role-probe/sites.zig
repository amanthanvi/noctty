// The probe's acquiring sites and its recorder, shared by both compilers so every site sits on the same line.
// r14 adds site 13/14 (a comptime-parameter function, two instantiations: AC1), site 15 (lockUncancelable: Opus L5)
// and a header line in each dump (process id and image base, as M-d's dump header has).
// Recorder (M-d): each newly seen (RVA, kind) pair is appended at once to this process's dump file (path from
// PROBE_DUMP), unbuffered, with the site the probe expects; a process that crashes afterwards keeps its pairs.
const std = @import("std");
const builtin = @import("builtin");
const sm = @import("state_mutex.zig");
const st = @import("state.zig");
const w32 = @import("w32.zig");

// the optimise-mode enum's spelling differs between 0.15.2 (.Debug) and 0.17.1
const is_debug = std.ascii.eqlIgnoreCase(@tagName(builtin.mode), "debug");

pub const Expect = struct { id: u8, func: []const u8, line: u32 };
pub var cur: Expect = undefined;
var sink: u64 = 0;
var dump: ?w32.HANDLE = null;
var seen: [32]usize = undefined;
var n_seen: usize = 0;

fn record(addr: usize, kind: sm.Kind) void {
    const rva = addr - w32.imageBase();
    for (seen[0..n_seen]) |s| if (s == rva) return; // distinct pairs only
    if (n_seen == seen.len) @panic("recorder full"); // fails loudly on overflow
    seen[n_seen] = rva;
    n_seen += 1;
    var line: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{d} {x} {s} {s} {d}\n", .{ cur.id, rva, @tagName(kind), cur.func, cur.line }) catch return;
    var written: u32 = 0;
    _ = w32.WriteFile(dump.?, text.ptr, @intCast(text.len), &written, null);
}

pub fn openDump() bool {
    var buf: [512]u16 = undefined;
    const p = w32.env("PROBE_DUMP", buf[0 .. buf.len - 1]) orelse return false;
    buf[p.len] = 0;
    const h = w32.CreateFileW(@ptrCast(&buf), w32.FILE_APPEND_DATA, w32.FILE_SHARE_READ | w32.FILE_SHARE_WRITE, null, w32.OPEN_ALWAYS, 0, null);
    if (@intFromPtr(h) == w32.INVALID) return false;
    dump = h;
    sm.hook = &record;
    var line: [96]u8 = undefined;
    const head = std.fmt.bufPrint(&line, "# probe pid={d} base={x}\n", .{ w32.GetCurrentProcessId(), w32.imageBase() }) catch return true;
    var written: u32 = 0;
    _ = w32.WriteFile(h, head.ptr, @intCast(head.len), &written, null);
    return true;
}

// ---- the sites: each sets `cur` on the same line as its acquisition
fn sitePlain(w: *sm.StateMutex) void {
    cur = .{ .id = 1, .func = "sitePlain", .line = @src().line }; w.lock();
    sink +%= 1;
}

inline fn siteInline(w: *sm.StateMutex) void {
    cur = .{ .id = 2, .func = "siteInline", .line = @src().line }; w.lock();
    sink +%= 2;
}

fn callerOfInline(w: *sm.StateMutex) void {
    sink +%= 20;
    siteInline(w);
}

fn siteAlways(w: *sm.StateMutex) void {
    cur = .{ .id = 3, .func = "siteAlways", .line = @src().line }; w.lock();
    sink +%= 3;
}

fn callerOfAlways(w: *sm.StateMutex) void {
    sink +%= 30;
    @call(.always_inline, siteAlways, .{w});
}

fn siteAlwaysAuto(w: *sm.StateMutex) void {
    cur = .{ .id = 4, .func = "siteAlwaysAuto", .line = @src().line }; w.lock();
    sink +%= 4;
}

fn callerOfAlwaysAuto(w: *sm.StateMutex) void {
    sink +%= 40;
    // M-b's Debug fix: .auto in Debug, .always_inline otherwise
    @call(if (is_debug) .auto else .always_inline, siteAlwaysAuto, .{w});
}

fn siteTail(w: *sm.StateMutex) void {
    sink +%= 5;
    cur = .{ .id = 5, .func = "siteTail", .line = @src().line }; defer w.lock();
}

fn siteTailOld(w: *sm.StateMutex) void {
    sink +%= 6;
    cur = .{ .id = 6, .func = "siteTailOld", .line = @src().line }; defer w.lockOld();
}

fn siteDemand(s: *sm.State) void {
    sink +%= 7;
    cur = .{ .id = 7, .func = "siteDemand", .line = @src().line }; s.lockDemand();
}

fn siteTry(w: *sm.StateMutex) void {
    sink +%= 8;
    cur = .{ .id = 8, .func = "siteTry", .line = @src().line }; if (w.tryLock()) sink +%= 1;
}

// the mailbox shape (send ends in `defer if (mutex) |m| m.lock();`), in functions that are not inlined
noinline fn siteTailOptOld(m: ?*sm.StateMutex) void {
    sink +%= 9;
    cur = .{ .id = 9, .func = "siteTailOptOld", .line = @src().line }; defer if (m) |x| x.lockOld();
}

noinline fn siteTailOpt(m: ?*sm.StateMutex) void {
    sink +%= 10;
    cur = .{ .id = 10, .func = "siteTailOpt", .line = @src().line }; defer if (m) |x| x.lock();
}

noinline fn sitePlainNoinline(w: *sm.StateMutex) void {
    cur = .{ .id = 11, .func = "sitePlainNoinline", .line = @src().line }; w.lock();
    sink +%= 11;
}

// the demand acquire through a State whose lockDemand lives outside the wrapper module (noctty's layout)
fn siteDemandOther(s: *st.State) void {
    sink +%= 12;
    cur = .{ .id = 12, .func = "siteDemandOther", .line = @src().line }; s.lockDemand();
}

// AC1: a comptime-parameter function, as Surface.confirmQuitAnswer(self, comptime wait: bool): each instantiation is
// its own function, and the symbol names carry a per-build suffix
fn siteComptime(w: *sm.StateMutex, comptime wait: bool) void {
    sink +%= 13;
    if (wait) {
        cur = .{ .id = 13, .func = "siteComptime", .line = @src().line }; w.lock();
    } else {
        cur = .{ .id = 14, .func = "siteComptime", .line = @src().line }; if (w.tryLock()) sink +%= 1;
    }
}

fn siteUncancelable(w: *sm.StateMutex) void {
    sink +%= 15;
    cur = .{ .id = 15, .func = "siteUncancelable", .line = @src().line }; w.lockUncancelable();
}

pub fn runSites() void {
    var w: sm.StateMutex = .{};
    var s: sm.State = .{ .mutex = &w };
    sitePlain(&w);
    callerOfInline(&w);
    callerOfAlways(&w);
    callerOfAlwaysAuto(&w);
    siteTail(&w);
    siteTailOld(&w);
    siteDemand(&s);
    siteTry(&w);
    siteTailOptOld(&w);
    siteTailOpt(&w);
    sitePlainNoinline(&w);
    var s2: st.State = .{ .mutex = &w };
    siteDemandOther(&s2);
    siteComptime(&w, true);
    siteComptime(&w, false);
    siteUncancelable(&w);
    std.mem.doNotOptimizeAway(sink);
}

pub const site_count = 15;
