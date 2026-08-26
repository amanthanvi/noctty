//! Standalone conpty-host increment (Wave 2 / durable-session spike).
//!
//! Owns a ring buffer and a named-pipe attach protocol so a UI client
//! can detach and reattach. The next slice wraps `src/pty.zig` +
//! `Command.zig` to hold one pwsh under ConPTY.
//!
//! ponytail: this increment proves the broker protocol, not process
//! survival. Green graduates C16 planning; wrapping Pty.open is the
//! upgrade path.

const std = @import("std");

pub const default_pipe_name = "\\\\.\\pipe\\winghostty-conpty-host";
pub const ring_capacity = 64 * 1024;

pub const Ring = struct {
    buf: []u8,
    start: usize = 0,
    len: usize = 0,

    pub fn init(buf: []u8) Ring {
        return .{ .buf = buf };
    }

    pub fn write(self: *Ring, bytes: []const u8) void {
        for (bytes) |b| {
            if (self.len == self.buf.len) {
                self.start = (self.start + 1) % self.buf.len;
                self.len -= 1;
            }
            const idx = (self.start + self.len) % self.buf.len;
            self.buf[idx] = b;
            self.len += 1;
        }
    }

    pub fn snapshot(self: *const Ring, out: []u8) usize {
        const n = @min(out.len, self.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = self.buf[(self.start + i) % self.buf.len];
        }
        return n;
    }
};

pub const FrameKind = enum(u8) {
    hello = 1,
    attach = 2,
    detach = 3,
    output = 4,
    resize = 5,
};

pub const Frame = struct {
    kind: FrameKind,
    payload: []const u8,
};

pub fn encodeFrame(kind: FrameKind, payload: []const u8, out: []u8) ![]const u8 {
    if (out.len < 5 + payload.len) return error.BufferTooSmall;
    out[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, out[1..5], @intCast(payload.len), .little);
    @memcpy(out[5..][0..payload.len], payload);
    return out[0 .. 5 + payload.len];
}

pub fn decodeFrame(bytes: []const u8) !Frame {
    if (bytes.len < 5) return error.ShortFrame;
    const kind = std.meta.intToEnum(FrameKind, bytes[0]) catch return error.UnknownFrame;
    const len = std.mem.readInt(u32, bytes[1..5], .little);
    if (5 + len > bytes.len) return error.ShortFrame;
    return .{ .kind = kind, .payload = bytes[5 .. 5 + len] };
}

/// Reply to one client frame. Attach/hello emit the current ring window.
pub fn handleRequest(kind: FrameKind, ring: *const Ring, out: []u8) ![]const u8 {
    switch (kind) {
        .hello, .attach => {
            var snap: [ring_capacity]u8 = undefined;
            const n = ring.snapshot(&snap);
            return encodeFrame(.output, snap[0..n], out);
        },
        .detach => return encodeFrame(.hello, "bye", out),
        .resize, .output => return encodeFrame(.hello, "ok", out),
    }
}

pub fn main() !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    try stdout.interface.print("conpty-host protocol-ready pipe={s}\n", .{default_pipe_name});
    try stdout.interface.flush();
}

test "ring wraps and snapshot is newest window" {
    var storage: [4]u8 = undefined;
    var ring = Ring.init(&storage);
    ring.write("abc");
    ring.write("de");
    var out: [8]u8 = undefined;
    const n = ring.snapshot(&out);
    try std.testing.expectEqualStrings("bcde", out[0..n]);
}

test "frame encode/decode round-trips" {
    var buf: [32]u8 = undefined;
    const encoded = try encodeFrame(.attach, "ok", &buf);
    const frame = try decodeFrame(encoded);
    try std.testing.expectEqual(FrameKind.attach, frame.kind);
    try std.testing.expectEqualStrings("ok", frame.payload);
}

test "handleRequest attach returns ring snapshot" {
    var storage: [8]u8 = undefined;
    var ring = Ring.init(&storage);
    ring.write("hello");
    var out: [64]u8 = undefined;
    const encoded = try handleRequest(.attach, &ring, &out);
    const frame = try decodeFrame(encoded);
    try std.testing.expectEqual(FrameKind.output, frame.kind);
    try std.testing.expectEqualStrings("hello", frame.payload);
}
