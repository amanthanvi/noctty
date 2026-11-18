//! Headless Terminal/stream/TerminalFormatter oracle. The Python driver
//! supplies frozen operations and owns filenames, manifests and comparison.
const std = @import("std");
const vt = @import("ghostty-vt");
const adapter = @import("differential_oracle_adapter.zig");
const Entry = adapter.Entry(run);
pub const main = if (adapter.modern) Entry.current else Entry.legacy;
pub const std_options: std.Options = .{ .log_level = .err };

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
    try output.writer.writeAll("ORS1");
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
        term.flags.resize_pull_scrollback = conpty == 0;
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
