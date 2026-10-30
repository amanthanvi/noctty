const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const Error = @import("error.zig").Error;

const log = std.log.scoped(.wuffs_deflate);

/// Inflate a raw DEFLATE (RFC 1951) stream from `reader` into `writer` and
/// return the number of bytes written.
///
/// Decompression fails with error.Overflow as soon as the output would
/// exceed `max_len` bytes, and with error.WuffsError if the stream is
/// malformed or `reader` ends before it does. Bytes after the end of the
/// stream stay unread in `reader`.
///
/// The decoder reads straight from `reader`'s buffer, which therefore needs
/// a capacity of at least one byte.
pub fn decompress(
    alloc: Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    max_len: u64,
) (Error || error{ ReadFailed, WriteFailed })!u64 {
    // See png.zig: allocate the decoder with the Zig allocator instead of
    // the C malloc-based helpers WUFFS offers.
    const decoder_buf = try alloc.alignedAlloc(
        u8,
        .@"16",
        c.sizeof__wuffs_deflate__decoder(),
    );
    defer alloc.free(decoder_buf);

    const decoder: ?*c.wuffs_deflate__decoder = @ptrCast(decoder_buf.ptr);
    {
        const status = c.wuffs_deflate__decoder__initialize(
            decoder,
            c.sizeof__wuffs_deflate__decoder(),
            c.WUFFS_VERSION,
            0,
        );
        try check(&status);
    }

    const work_buffer = try alloc.alloc(
        u8,
        std.math.cast(
            usize,
            c.wuffs_deflate__decoder__workbuf_len(decoder).max_incl,
        ) orelse return error.OutOfMemory,
    );
    defer alloc.free(work_buffer);
    const work_slice = c.wuffs_base__make_slice_u8(
        work_buffer.ptr,
        work_buffer.len,
    );

    // The decoder keeps its own copy of the history window between calls,
    // so every call can write from the start of this buffer again, as long
    // as `pos` says where in the stream the buffer starts: a match reaching
    // before the buffer is looked up in that history relative to `pos`.
    const output = try alloc.alloc(u8, 64 * 1024);
    defer alloc.free(output);

    var written: u64 = 0;
    var closed = false;
    while (true) {
        const input = reader.buffered();
        var source_buffer: c.wuffs_base__io_buffer = .{
            .data = .{ .ptr = input.ptr, .len = input.len },
            .meta = .{ .wi = input.len, .ri = 0, .pos = 0, .closed = closed },
        };
        var dest_buffer: c.wuffs_base__io_buffer = .{
            .data = .{ .ptr = output.ptr, .len = output.len },
            .meta = .{ .wi = 0, .ri = 0, .pos = written, .closed = false },
        };

        const status = c.wuffs_deflate__decoder__transform_io(
            decoder,
            &dest_buffer,
            &source_buffer,
            work_slice,
        );
        reader.toss(source_buffer.meta.ri);

        const chunk = output[0..dest_buffer.meta.wi];
        if (chunk.len > max_len - written) {
            log.warn("decompressed data exceeds max_len={d}", .{max_len});
            return error.Overflow;
        }
        try writer.writeAll(chunk);
        written += chunk.len;

        if (c.wuffs_base__status__is_ok(&status)) return written;
        if (status.repr == c.wuffs_base__suspension__short_read) {
            // A closed source turns a short read into a truncation error,
            // so this branch only runs while `reader` may have more.
            // WUFFS consumes what it is given before asking for more; a
            // full buffer it did not consume would make fillMore assert.
            if (reader.bufferedLen() == reader.buffer.len) return error.WuffsError;
            reader.fillMore() catch |err| switch (err) {
                error.EndOfStream => closed = true,
                error.ReadFailed => return error.ReadFailed,
            };
        } else if (status.repr != c.wuffs_base__suspension__short_write) {
            try check(&status);
            unreachable;
        }
    }
}

fn check(status: *const c.struct_wuffs_base__status__struct) error{WuffsError}!void {
    return @import("error.zig").check(log, status);
}

/// "hello, wuffs deflate" as raw DEFLATE with one fixed Huffman block.
const hello_deflate = [_]u8{
    0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x28, 0x2f, 0x4d, 0x4b, 0x2b,
    0x56, 0x48, 0x49, 0x4d, 0xcb, 0x49, 0x2c, 0x49, 0x05, 0x00,
};
const hello_plain = "hello, wuffs deflate";

fn decompressHello(alloc: Allocator, input: []const u8, max_len: u64) ![]u8 {
    var reader: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const n = try decompress(alloc, &reader, &out.writer, max_len);
    try std.testing.expectEqual(out.written().len, n);
    return out.toOwnedSlice();
}

test "deflate: decompress" {
    const alloc = std.testing.allocator;
    const out = try decompressHello(alloc, &hello_deflate, 1024);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(hello_plain, out);
}

test "deflate: output of exactly max_len is accepted and one byte less is refused" {
    const alloc = std.testing.allocator;
    const out = try decompressHello(alloc, &hello_deflate, hello_plain.len);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(hello_plain, out);
    try std.testing.expectError(error.Overflow, decompressHello(alloc, &hello_deflate, hello_plain.len - 1));
}

test "deflate: truncated input and garbage are errors" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.WuffsError, decompressHello(alloc, hello_deflate[0 .. hello_deflate.len - 3], 1024));
    try std.testing.expectError(error.WuffsError, decompressHello(alloc, "\xff\xff\xff\xff not deflate", 1024));
}
