// AA1/M-a probe, Zig 0.17.1 (r13: site 12, the demand forwarder outside the wrapper module; r14: comptime-parameter
// sites with suffix stripping, lockUncancelable, dump header). PROBE_MODE unset: run the sites, recording each pair
// to PROBE_DUMP as it is seen (PROBE_CRASH=1 then panics after acquiring). PROBE_MODE=symbolise: a separate process
// reads PROBE_DUMP and maps each module-relative address to its function with std.debug, taking the first frame
// outside the wrapper module (state_mutex.zig) and the named forwarder lockDemand when inline callers are resolved
// (M-a), and printing frame 0 as well.
const std = @import("std");
const sites = @import("sites.zig");
const w32 = @import("w32.zig");

fn isMode(buf: []u16, comptime want: []const u8) bool {
    const v = w32.env("PROBE_MODE", buf) orelse return false;
    if (v.len != want.len) return false;
    for (want, 0..) |c, i| if (v[i] != c) return false;
    return true;
}

pub fn main() !void {
    var mb: [64]u16 = undefined;
    if (isMode(&mb, "symbolise")) return symbolise();
    if (!sites.openDump()) return error.NoDump;
    sites.runSites();
    var cb: [8]u16 = undefined;
    if (w32.env("PROBE_CRASH", &cb) != null) @panic("probe: crash after acquiring");
}

/// AC1: a comptime-parameter instantiation's symbol carries a per-build suffix (`__anon_N` on 0.15.2, `__func_N` on
/// 0.17.1); the compare strips it before matching the function.
fn stripInst(name: []const u8) []const u8 {
    inline for (.{ "__anon_", "__func_" }) |pat| {
        if (std.mem.lastIndexOf(u8, name, pat)) |i| {
            const rest = name[i + pat.len ..];
            var digits = rest.len > 0;
            for (rest) |c| {
                if (!std.ascii.isDigit(c)) digits = false;
            }
            if (digits) return name[0..i];
        }
    }
    return name;
}

fn symbolise() !void {
    var pb: [512]u16 = undefined;
    const p = w32.env("PROBE_DUMP", pb[0 .. pb.len - 1]) orelse return error.NoDump;
    pb[p.len] = 0;
    const h = w32.CreateFileW(@ptrCast(&pb), w32.GENERIC_READ, w32.FILE_SHARE_READ | w32.FILE_SHARE_WRITE, null, w32.OPEN_EXISTING, 0, null);
    if (@intFromPtr(h) == w32.INVALID) return error.NoDump;
    var data: [16384]u8 = undefined;
    var n: u32 = 0;
    _ = w32.ReadFile(h, &data, data.len, &n, null);
    _ = w32.CloseHandle(h);
    const io = std.Options.debug_io;
    const gpa = std.heap.page_allocator;
    const di = try std.debug.getSelfDebugInfo();
    const base = w32.imageBase();
    var ok = [2]usize{ 0, 0 };
    var ok_f: usize = 0;
    var ok_raw: usize = 0;
    var total: usize = 0;
    var it = std.mem.tokenizeScalar(u8, data[0..n], '\n');
    while (it.next()) |line| {
        if (line[0] == '#') {
            std.debug.print("header: {s}\n", .{line});
            continue;
        }
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const id = f.next().?;
        const rva = try std.fmt.parseInt(usize, f.next().?, 16);
        const kind = f.next().?;
        const want = f.next().?;
        const want_line = f.next().?;
        const addr = base + rva - 1; // the call instruction
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var symbols: std.ArrayList(std.debug.Symbol) = .empty;
        defer symbols.deinit(gpa);
        try di.getSymbols(io, gpa, arena.allocator(), addr, true, &symbols);
        var frame0: []const u8 = "???";
        var outside: []const u8 = "???";
        var out_file: []const u8 = "???";
        var out_line: u64 = 0;
        var found = false;
        var outside_f: []const u8 = "???"; // the file-only rule: skip state_mutex.zig frames only
        var found_f = false;
        for (symbols.items, 0..) |sym, depth| {
            const name: []const u8 = sym.name orelse "???";
            const file: []const u8 = if (sym.source_location) |sl| std.fs.path.basename(sl.file_name) else "???";
            if (depth == 0) frame0 = name;
            const in_wrapper_file = std.mem.eql(u8, file, "state_mutex.zig");
            if (!found_f and !in_wrapper_file) {
                found_f = true;
                outside_f = name;
            }
            // the wrapper's frames: its module, plus the named forwarder State.lockDemand outside it
            const forwarder = std.mem.eql(u8, name, "lockDemand") or std.mem.endsWith(u8, name, ".lockDemand");
            if (!found and !in_wrapper_file and !forwarder) {
                found = true;
                outside = name;
                out_file = file;
                out_line = if (sym.source_location) |sl| sl.line else 0;
            }
        }
        const good0 = std.mem.endsWith(u8, stripInst(frame0), want);
        const good = std.mem.endsWith(u8, stripInst(outside), want);
        const good_raw = std.mem.endsWith(u8, outside, want);
        const good_f = std.mem.endsWith(u8, stripInst(outside_f), want);
        total += 1;
        if (good0) ok[0] += 1;
        if (good) ok[1] += 1;
        if (good_f) ok_f += 1;
        if (good_raw) ok_raw += 1;
        std.debug.print("site {s} {s:<17} expected {s}:{s} -> first frame outside the wrapper {s}:{d} in {s} : {s} (raw name: {s}; file-only rule: {s} : {s}; frame 0: {s} : {s})\n", .{ id, kind, want, want_line, out_file, out_line, outside, if (good) "OK" else "WRONG", if (good_raw) "OK" else "WRONG", outside_f, if (good_f) "OK" else "WRONG", frame0, if (good0) "OK" else "WRONG" });
    }
    std.debug.print("zig {s} {s}: {d} of {d} recorded pairs attributed to the acquiring function (first frame outside the wrapper and its named forwarder, instantiation suffix stripped); raw names: {d} of {d}; file-only rule: {d} of {d}; frame 0 alone: {d} of {d}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), ok[1], total, ok_raw, total, ok_f, total, ok[0], total });
}
