// AA1/M-a probe, Zig 0.15.2 (r14: comptime-parameter sites with suffix stripping, lockUncancelable, dump header).
// PROBE_MODE unset: run the sites, recording each pair to PROBE_DUMP as it is seen (PROBE_CRASH=1 then panics after
// acquiring). PROBE_MODE=symbolise: a separate process reads PROBE_DUMP and maps each module-relative address to its
// function with std.debug (the compare tool's step, M-d).
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
    const di = try std.debug.getSelfDebugInfo();
    const base = w32.imageBase();
    var ok: usize = 0;
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
        const module = try di.getModuleForAddress(addr);
        const sym = try module.getSymbolAtAddress(di.allocator, addr);
        const file: []const u8 = if (sym.source_location) |sl| std.fs.path.basename(sl.file_name) else "???";
        const ln: u64 = if (sym.source_location) |sl| sl.line else 0;
        const good_raw = std.mem.endsWith(u8, sym.name, want);
        const good = std.mem.endsWith(u8, stripInst(sym.name), want);
        total += 1;
        if (good) ok += 1;
        if (good_raw) ok_raw += 1;
        std.debug.print("site {s} {s:<17} expected {s}:{s} -> {s}:{d} in {s} : {s} (raw name: {s})\n", .{ id, kind, want, want_line, file, ln, sym.name, if (good) "OK" else "WRONG", if (good_raw) "OK" else "WRONG" });
    }
    std.debug.print("zig {s} {s}: {d} of {d} recorded pairs attributed to the acquiring function (instantiation suffix stripped); raw names: {d} of {d}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), ok, total, ok_raw, total });
}
