//! Zig 0.15.2 IO adapter; delete this whole file at the 1B.3/1B.5 cutover.
const std = @import("std");
const vt = @import("ghostty-vt");
const api = @import("oracle_api").api;
pub const Context = struct {};
pub const alloc = std.heap.page_allocator;
pub const conpty_no_pull_supported = api == .fork;

pub fn Entry(comptime run: anytype) type {
    return struct {
        pub fn main() !void {
            try run(.{});
        }
    };
}

pub fn readRequest(_: Context) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, "request.bin", 512 * 1024 * 1024);
}

pub fn writeResponse(_: Context, bytes: []const u8) !void {
    const file = try std.fs.cwd().createFile("response.bin", .{ .exclusive = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn initTerminal(_: Context, cols: u16, rows: u16) !vt.Terminal {
    return .init(alloc, .{ .cols = cols, .rows = rows, .max_scrollback = 10_000 });
}

pub fn setConpty(term: *vt.Terminal, enabled: bool) void {
    switch (api) {
        .fork => term.flags.resize_pull_scrollback = !enabled,
        .stone => {}, // This app API has no resize-pull flag. Record that shape.
        else => @compileError("legacy adapter requires fork or stone"),
    }
}

pub fn resize(term: *vt.Terminal, cols: u16, rows: u16) !void {
    switch (api) {
        .fork => try term.resize(alloc, cols, rows),
        .stone => try term.resize(alloc, .{ .cols = cols, .rows = rows }),
        else => @compileError("legacy adapter requires fork or stone"),
    }
}
