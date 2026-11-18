//! The oracle's only version-specific surface. No GUI, PTY or host IO.
const std = @import("std");
const vt = @import("ghostty-vt");
pub const modern = @import("builtin").zig_version.minor >= 17;
pub const Context = if (modern) struct { io: std.Io } else struct {};
pub const alloc = std.heap.page_allocator;

pub fn Entry(comptime run: anytype) type {
    return struct {
        pub fn legacy() !void {
            try run(.{});
        }
        pub fn current(init: std.process.Init) !void {
            try run(.{ .io = init.io });
        }
    };
}

pub fn readRequest(ctx: Context) ![]u8 {
    if (modern) {
        return std.Io.Dir.cwd().readFileAlloc(ctx.io, "request.bin", alloc, .limited(512 * 1024 * 1024));
    } else {
        return std.fs.cwd().readFileAlloc(alloc, "request.bin", 512 * 1024 * 1024);
    }
}

pub fn writeResponse(ctx: Context, bytes: []const u8) !void {
    if (modern) {
        const file = try std.Io.Dir.cwd().createFile(ctx.io, "response.bin", .{ .exclusive = true });
        defer file.close(ctx.io);
        try file.writeStreamingAll(ctx.io, bytes);
    } else {
        const file = try std.fs.cwd().createFile("response.bin", .{ .exclusive = true });
        defer file.close();
        try file.writeAll(bytes);
    }
}

pub fn initTerminal(ctx: Context, cols: u16, rows: u16) !vt.Terminal {
    if (modern) {
        return .init(ctx.io, alloc, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = 10_000 });
    } else {
        return .init(alloc, .{ .cols = cols, .rows = rows, .max_scrollback = 10_000 });
    }
}

pub fn resize(term: *vt.Terminal, cols: u16, rows: u16) !void {
    if (modern) {
        try term.resize(alloc, .{ .cols = cols, .rows = rows });
    } else {
        try term.resize(alloc, cols, rows);
    }
}
