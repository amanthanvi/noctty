//! Current IO adapter. Selected by explicit Terminal API shape, never compiler.
const std = @import("std");
const vt = @import("ghostty-vt");
const api = @import("oracle_api").api;
pub const Context = struct { io: std.Io };
pub const alloc = std.heap.page_allocator;
pub const conpty_no_pull_supported = true;
pub const option_names = @typeInfo(vt.options).@"struct".decl_names;
pub const scrollback_bytes = @import("oracle_settings").scrollback_bytes;

pub fn Entry(comptime run: anytype) type {
    return struct {
        pub fn main(init: std.process.Init) !void {
            try run(.{ .io = init.io });
        }
    };
}

pub fn readRequest(ctx: Context) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, "request.bin", alloc, .limited(512 * 1024 * 1024));
}

pub fn writeResponse(ctx: Context, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(ctx.io, "response.bin", .{ .exclusive = true });
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, bytes);
}

pub fn initTerminal(ctx: Context, cols: u16, rows: u16) !vt.Terminal {
    return .init(ctx.io, alloc, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = scrollback_bytes });
}

pub fn setConpty(term: *vt.Terminal, enabled: bool) void {
    term.flags.resize_pull_scrollback = !enabled;
}

pub fn resize(term: *vt.Terminal, cols: u16, rows: u16) !void {
    switch (api) {
        .v140 => try term.resize(alloc, .{ .cols = cols, .rows = rows }),
        .v140_fork => try term.resize(alloc, cols, rows),
        else => @compileError("current adapter requires v140 or v140_fork"),
    }
}
