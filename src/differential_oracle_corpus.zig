//! Run once on the pre-side compiler. Never regenerate the corpus on a
//! compared tree: the saved bytes, not PRNG source equivalence, are the input.
//! Zig 0.15.2-only generator: delete whole at 1B.3/1B.5 after freezing input.
const std = @import("std");
const synthetic = @import("synthetic/main.zig");

pub fn main() !void {
    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer output.deinit();
    try output.writer.writeAll("OSC1");
    try output.writer.writeInt(u32, 12, .little);
    for ([_]u64{ 0, 1, 0xC0FFEEEEEEEEEEEE }) |seed| {
        for (0..4) |kind| {
            var prng = std.Random.DefaultPrng.init(seed);
            var buffer: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            switch (kind) {
                0 => {
                    var generator: synthetic.Bytes = .{ .rand = prng.random(), .min_len = buffer.len, .max_len = buffer.len };
                    try generator.next(&writer, buffer.len);
                },
                1 => {
                    var generator: synthetic.Utf8 = .{ .rand = prng.random(), .min_len = buffer.len, .max_len = buffer.len };
                    try generator.next(&writer, buffer.len);
                },
                2, 3 => {
                    var generator: synthetic.Osc = .{ .rand = prng.random(), .p_valid = if (kind == 2) 1.0 else 0.0 };
                    for (0..16) |_| try generator.next(&writer, 256);
                },
                else => unreachable,
            }
            try output.writer.writeInt(u64, seed, .little);
            try output.writer.writeInt(u8, @intCast(kind), .little);
            try output.writer.writeInt(u32, @intCast(writer.buffered().len), .little);
            try output.writer.writeAll(writer.buffered());
        }
    }
    const file = try std.fs.cwd().createFile("synthetic.bin", .{ .exclusive = true });
    defer file.close();
    try file.writeAll(output.written());
}
