//! Headless Terminal/stream/TerminalFormatter oracle. The Python driver
//! supplies frozen operations and owns filenames, manifests and comparison.
const std = @import("std");
const vt = @import("ghostty-vt");
const adapter = @import("oracle-adapter");
const Entry = adapter.Entry(run);
pub const main = Entry.main;
pub const std_options: std.Options = .{ .log_level = .err };
extern fn oracle_highway_target() [*:0]const u8;
extern fn oracle_simdutf_name([*]u8, usize) usize;

const Input = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Input, count: usize) ![]const u8 {
        if (count > self.bytes.len - self.pos) return error.TruncatedRequest;
        const result = self.bytes[self.pos..][0..count];
        self.pos += count;
        return result;
    }

    fn int(self: *Input, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

fn run(ctx: adapter.Context) !void {
    const bytes = try adapter.readRequest(ctx);
    defer adapter.alloc.free(bytes);
    var input: Input = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try input.take(4), "ORQ1")) return error.BadRequest;
    const count = try input.int(u32);
    var output: std.Io.Writer.Allocating = .init(adapter.alloc);
    defer output.deinit();
    try output.writer.writeAll("ORS3");
    var profile: std.Io.Writer.Allocating = .init(adapter.alloc);
    defer profile.deinit();
    const build = @import("oracle_build");
    const identity = @import("oracle_identity");
    try profile.writer.writeAll("{\"build_identity\":");
    try std.json.Stringify.value(.{
        .revision = identity.revision,
        .dirty = identity.dirty,
        .vt_api = build.vt_api,
        .terminal_source = build.terminal_source,
        .zig_exe_sha256 = identity.zig_exe_sha256,
        .zig_lib_sha256 = identity.zig_lib_sha256,
    }, .{}, &profile.writer);
    try profile.writer.writeAll(",\"profile\":{\"target\":");
    try std.json.Stringify.value(build.target, .{}, &profile.writer);
    try profile.writer.writeAll(",\"cpu_model\":");
    try std.json.Stringify.value(build.cpu_model, .{}, &profile.writer);
    try profile.writer.writeAll(",\"cpu_features\":");
    try std.json.Stringify.value(build.cpu_features, .{}, &profile.writer);
    try profile.writer.writeAll(",\"baseline_cpu_model\":");
    try std.json.Stringify.value(build.baseline_cpu_model, .{}, &profile.writer);
    try profile.writer.writeAll(",\"baseline_cpu_features\":");
    try std.json.Stringify.value(build.baseline_cpu_features, .{}, &profile.writer);
    try profile.writer.writeAll(",\"compiler_version\":");
    try std.json.Stringify.value(build.compiler_version, .{}, &profile.writer);
    try profile.writer.writeAll(",\"scrollback_bytes\":");
    try std.json.Stringify.value(adapter.scrollback_bytes, .{}, &profile.writer);
    try profile.writer.writeAll(",\"runtime_simd\":");
    if (vt.options.simd) {
        if (!build.simd_probe) @compileError("SIMD oracle requires the vt.cpp dispatch probe");
        var name: [128]u8 = undefined;
        const length = oracle_simdutf_name(&name, name.len);
        try std.json.Stringify.value(.{ .highway = std.mem.span(oracle_highway_target()), .simdutf = name[0..length] }, .{}, &profile.writer);
    } else try std.json.Stringify.value(.{ .highway = "scalar", .simdutf = "disabled" }, .{}, &profile.writer);
    try profile.writer.writeAll(",\"optimize\":");
    try std.json.Stringify.value(build.optimize, .{}, &profile.writer);
    try profile.writer.writeAll(",\"conpty_no_pull_supported\":");
    try std.json.Stringify.value(adapter.conpty_no_pull_supported, .{}, &profile.writer);
    try profile.writer.writeAll(",\"terminal_options\":{");
    var comma = false;
    inline for (adapter.option_names) |name| {
        const value = @field(vt.options, name);
        if (@TypeOf(value) != type) {
            if (comma) try profile.writer.writeByte(',');
            try std.json.Stringify.value(name, .{}, &profile.writer);
            try profile.writer.writeByte(':');
            try std.json.Stringify.value(value, .{}, &profile.writer);
            comma = true;
        }
    }
    try profile.writer.writeAll("}}}");
    try output.writer.writeInt(u32, @intCast(profile.written().len), .little);
    try output.writer.writeAll(profile.written());
    try output.writer.writeInt(u32, count, .little);
    for (0..count) |index| {
        // Only the ordinal is diagnostic: never print corpus-controlled
        // terminal text, commands, paths, or formatter output to a log.
        std.debug.print("oracle record {d}/{d}\n", .{ index, count });
        const cols = try input.int(u16);
        const rows = try input.int(u16);
        const conpty = try input.int(u8);
        if (conpty > 1) return error.BadRequest;
        var term = try adapter.initTerminal(ctx, cols, rows);
        defer term.deinit(adapter.alloc);
        adapter.setConpty(&term, conpty == 1);
        var stream = term.vtStream();
        defer stream.deinit();
        const operations = try input.int(u32);
        for (0..operations) |_| {
            switch (try input.int(u8)) {
                0 => stream.nextSlice(try input.take(try input.int(u32))),
                1 => {
                    const width = try input.int(u16);
                    const height = try input.int(u16);
                    try adapter.resize(&term, width, height);
                },
                else => return error.BadRequest,
            }
        }
        try output.writer.writeInt(u32, @intCast(index), .little);
        for ([_]vt.formatter.Format{ .plain, .vt }) |format| {
            var dump: std.Io.Writer.Allocating = .init(adapter.alloc);
            defer dump.deinit();
            var formatter: vt.formatter.TerminalFormatter = .init(&term, .{
                .emit = format,
                .unwrap = false,
                .trim = false,
            });
            formatter.extra = if (format == .vt) .all else .none;
            try formatter.format(&dump.writer);
            const data = dump.written();
            try output.writer.writeInt(u64, @intCast(data.len), .little);
            try output.writer.writeAll(data);
        }
    }
    if (input.pos != bytes.len) return error.TrailingRequest;
    try adapter.writeResponse(ctx, output.written());
}
