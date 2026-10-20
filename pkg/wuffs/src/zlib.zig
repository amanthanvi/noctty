const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const Error = @import("error.zig").Error;

const log = std.log.scoped(.wuffs_zlib);

/// Decompress a complete zlib (RFC 1950) stream held in memory.
///
/// The returned slice is owned by the caller. Decompression fails with
/// error.Overflow if the output would exceed `max_len` bytes and with
/// error.WuffsError if the stream is malformed or truncated (including an
/// Adler-32 mismatch).
pub fn decompress(alloc: Allocator, data: []const u8, max_len: usize) Error![]u8 {
    // Most inputs are pixel data that compresses a few times over, so start
    // near the likely size and grow from there.
    const initial = @min(max_len, @max(4096, data.len *| 4));
    return decompressWithInitialCapacity(alloc, data, max_len, initial);
}

fn decompressWithInitialCapacity(
    alloc: Allocator,
    data: []const u8,
    max_len: usize,
    initial_capacity: usize,
) Error![]u8 {
    // See png.zig: allocate the decoder with the Zig allocator instead of
    // the C malloc-based helpers WUFFS offers.
    const decoder_buf = try alloc.alignedAlloc(
        u8,
        .@"16",
        c.sizeof__wuffs_zlib__decoder(),
    );
    defer alloc.free(decoder_buf);

    const decoder: ?*c.wuffs_zlib__decoder = @ptrCast(decoder_buf.ptr);
    {
        const status = c.wuffs_zlib__decoder__initialize(
            decoder,
            c.sizeof__wuffs_zlib__decoder(),
            c.WUFFS_VERSION,
            0,
        );
        try check(&status);
    }

    const work_buffer = try alloc.alloc(
        u8,
        std.math.cast(
            usize,
            c.wuffs_zlib__decoder__workbuf_len(decoder).max_incl,
        ) orelse return error.OutOfMemory,
    );
    defer alloc.free(work_buffer);
    const work_slice = c.wuffs_base__make_slice_u8(
        work_buffer.ptr,
        work_buffer.len,
    );

    var source_buffer: c.wuffs_base__io_buffer = .{
        .data = .{ .ptr = @ptrCast(@constCast(data.ptr)), .len = data.len },
        .meta = .{
            .wi = data.len,
            .ri = 0,
            .pos = 0,
            .closed = true,
        },
    };

    const limit = max_len +| 1;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try list.ensureTotalCapacity(alloc, @max(1, @min(limit, initial_capacity)));

    while (true) {
        // The destination may move when the list grows. That is fine: the
        // decoder keeps its own copy of the history window between calls.
        const dst = list.allocatedSlice();
        var dest_buffer: c.wuffs_base__io_buffer = .{
            .data = .{ .ptr = dst.ptr, .len = dst.len },
            .meta = .{
                .wi = list.items.len,
                .ri = 0,
                .pos = 0,
                .closed = false,
            },
        };

        const status = c.wuffs_zlib__decoder__transform_io(
            decoder,
            &dest_buffer,
            &source_buffer,
            work_slice,
        );
        list.items.len = dest_buffer.meta.wi;

        if (c.wuffs_base__status__is_ok(&status)) break;
        if (!c.wuffs_base__status__is_suspension(&status)) {
            try check(&status);
            unreachable;
        }

        // The source is the whole stream and is already closed, so the only
        // suspension we can recover from is a full destination.
        // If the destination buffer has room left, the source ended prematurely
        // (truncated input or corrupt stream).
        if (dest_buffer.meta.wi < dest_buffer.data.len) {
            log.warn("decode err=truncated zlib input or unexpected suspension: {s}", .{
                c.wuffs_base__status__message(&status),
            });
            return error.WuffsError;
        }

        // Grow up to one byte past max_len so that a stream ending exactly
        // at max_len still completes and anything longer is detected.
        if (list.items.len >= limit) {
            log.warn("decompressed data exceeds max_len={d}", .{max_len});
            return error.Overflow;
        }
        const grow = @min(limit - list.items.len, @max(4096, list.capacity));
        try list.ensureUnusedCapacity(alloc, grow);
    }

    // The list may have grown past the limit we asked for.
    if (list.items.len > max_len) {
        log.warn("decompressed data exceeds max_len={d}", .{max_len});
        return error.Overflow;
    }

    return try list.toOwnedSlice(alloc);
}

fn check(status: *const c.struct_wuffs_base__status__struct) error{WuffsError}!void {
    return @import("error.zig").check(log, status);
}

const hello_zlib = [_]u8{
    0x78, 0xda, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x28, 0x2f, 0x4d, 0x4b,
    0x2b, 0x56, 0xa8, 0xca, 0xc9, 0x4c, 0x02, 0x00, 0x39, 0x07, 0x06, 0x5d,
};
const hello_plain = "hello, wuffs zlib";

test "zlib: decompress" {
    const alloc = std.testing.allocator;
    const out = try decompress(alloc, &hello_zlib, 1024);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(hello_plain, out);
}

test "zlib: decompress grows the destination one byte at a time" {
    const alloc = std.testing.allocator;
    const out = try decompressWithInitialCapacity(alloc, &hello_zlib, 1024, 1);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(hello_plain, out);
}

test "zlib: output larger than max_len is refused" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.Overflow,
        decompressWithInitialCapacity(alloc, &hello_zlib, hello_plain.len - 1, 1),
    );
}

test "zlib: output of exactly max_len is accepted" {
    const alloc = std.testing.allocator;
    const out = try decompressWithInitialCapacity(alloc, &hello_zlib, hello_plain.len, 1);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(hello_plain, out);
}

test "zlib: truncated input is an error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.WuffsError,
        decompress(alloc, hello_zlib[0 .. hello_zlib.len - 6], 1024),
    );
}

test "zlib: corrupt checksum is an error" {
    const alloc = std.testing.allocator;
    var corrupt = hello_zlib;
    corrupt[corrupt.len - 1] ^= 0xff;
    try std.testing.expectError(error.WuffsError, decompress(alloc, &corrupt, 1024));
}

test "zlib: garbage is an error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.WuffsError, decompress(alloc, "not zlib at all", 1024));
}
