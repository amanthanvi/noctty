//! This CLI is used to generate data that is used by the build process.
//!
//! We used to do this directly in our `build.zig` but the problem with
//! that approach is that any changes to the dependencies of this data would
//! force a rebuild of our build binary. If we're just doing something like
//! running tests and not emitting any of the info below, then that is a
//! complete waste.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");

pub const Action = enum {
    // Shell completions
    bash,
    fish,
    zsh,

    // Editor syntax files
    sublime,
    @"vim-syntax",
    @"vim-ftdetect",
    @"vim-ftplugin",
    @"vim-compiler",

    // Other
    terminfo,

    /// Compiled terminfo database, written to the directory named by the
    /// last argument. Used on Windows, which has no `tic`.
    @"terminfo-database",
};

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc);
    const action = action_ orelse return error.NoAction;

    // Our output always goes to stdout, except for the terminfo database.
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&buffer);
    const writer = &stdout_writer.interface;
    switch (action) {
        .bash => try writer.writeAll(@import("extra/bash.zig").completions),
        .fish => try writer.writeAll(@import("extra/fish.zig").completions),
        .zsh => try writer.writeAll(@import("extra/zsh.zig").completions),
        .sublime => try writer.writeAll(@import("extra/sublime.zig").syntax),
        .@"vim-syntax" => try writer.writeAll(@import("extra/vim.zig").syntax),
        .@"vim-ftdetect" => try writer.writeAll(@import("extra/vim.zig").ftdetect),
        .@"vim-ftplugin" => try writer.writeAll(@import("extra/vim.zig").ftplugin),
        .@"vim-compiler" => try writer.writeAll(@import("extra/vim.zig").compiler),
        .terminfo => try @import("terminfo/ghostty.zig").ghostty.encode(writer),
        .@"terminfo-database" => try writeTerminfoDatabase(alloc),
    }
    try stdout_writer.end();
}

fn writeTerminfoDatabase(alloc: Allocator) !void {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 3) return error.MissingOutputDirectory;

    var dir = try std.fs.cwd().makeOpenPath(args[args.len - 1], .{});
    defer dir.close();
    try @import("terminfo/compiled.zig").writeDatabase(
        alloc,
        @import("terminfo/ghostty.zig").ghostty,
        dir,
    );
}
