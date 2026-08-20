//! UTF-8 console preamble policy for Windows shells (C06).
//!
//! `auto` forces UTF-8 except on legacy CJK ANSI code pages, where
//! changing the OEM page silently breaks existing tools. `always` /
//! `never` are unconditional.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");

pub const Mode = enum {
    auto,
    always,
    never,
};

/// Japanese (932), Simplified Chinese (936), Korean (949),
/// Traditional Chinese (950).
pub const cjk_ansi_code_pages = [_]u32{ 932, 936, 949, 950 };

pub fn isCjkAnsiCodePage(code_page: u32) bool {
    return switch (code_page) {
        932, 936, 949, 950 => true,
        else => false,
    };
}

pub fn currentOutputCodePage() u32 {
    if (comptime builtin.os.tag != .windows) return 65001;
    return GetConsoleOutputCP();
}

extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;

const cmd_chcp = "chcp 65001>nul";

/// Wrap an interactive `cmd.exe` launch so the first command is `chcp 65001`.
/// Leaves `/c` and `/command` launches untouched. Other shells are unchanged
/// (PowerShell reads `GHOSTTY_UTF8_CONSOLE` from integration.ps1).
pub fn wrapCmdForUtf8(alloc: std.mem.Allocator, command: config.Command) !config.Command {
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    const exe = iter.next() orelse return try command.clone(alloc);
    const base = std.fs.path.basename(exe);
    if (!(std.ascii.eqlIgnoreCase(base, "cmd") or std.ascii.eqlIgnoreCase(base, "cmd.exe"))) {
        return try command.clone(alloc);
    }

    var args: std.ArrayList([:0]const u8) = .empty;
    defer args.deinit(alloc);
    try args.append(alloc, exe);

    var saw_k = false;
    var rest_start: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (isCmdSlashC(arg)) return try command.clone(alloc);
        if (isCmdSlashK(arg)) {
            saw_k = true;
            rest_start = iter.next();
            break;
        }
        try args.append(alloc, arg);
    }

    try args.append(alloc, "/d");
    try args.append(alloc, "/k");
    if (saw_k) {
        if (rest_start) |rest| {
            const joined = try std.fmt.allocPrint(alloc, "{s} & {s}", .{ cmd_chcp, rest });
            try args.append(alloc, try alloc.dupeZ(u8, joined));
        } else {
            try args.append(alloc, cmd_chcp);
        }
        while (iter.next()) |arg| try args.append(alloc, arg);
    } else {
        try args.append(alloc, cmd_chcp);
    }

    const owned = try alloc.alloc([:0]const u8, args.items.len);
    for (args.items, 0..) |arg, i| {
        owned[i] = try alloc.dupeZ(u8, arg);
    }
    return .{ .direct = owned };
}

fn isCmdSlashC(arg: []const u8) bool {
    if (arg.len < 2) return false;
    if (arg[0] != '/' and arg[0] != '-') return false;
    return std.ascii.eqlIgnoreCase(arg[1..], "c") or
        std.ascii.eqlIgnoreCase(arg[1..], "command");
}

fn isCmdSlashK(arg: []const u8) bool {
    if (arg.len < 2) return false;
    if (arg[0] != '/' and arg[0] != '-') return false;
    return std.ascii.eqlIgnoreCase(arg[1..], "k");
}

/// Whether the launch should inject a UTF-8 console preamble.
pub fn shouldForceUtf8(mode: Mode, output_code_page: u32) bool {
    return switch (mode) {
        .never => false,
        .always => true,
        .auto => !isCjkAnsiCodePage(output_code_page),
    };
}

test "auto skips CJK ANSI pages" {
    const testing = std.testing;
    for (cjk_ansi_code_pages) |cp| {
        try testing.expect(!shouldForceUtf8(.auto, cp));
        try testing.expect(shouldForceUtf8(.always, cp));
        try testing.expect(!shouldForceUtf8(.never, cp));
    }
}

test "auto forces UTF-8 on Western and UTF-8 pages" {
    const testing = std.testing;
    for ([_]u32{ 437, 850, 1252, 65001 }) |cp| {
        try testing.expect(shouldForceUtf8(.auto, cp));
        try testing.expect(!shouldForceUtf8(.never, cp));
    }
}

test "wrapCmdForUtf8 wraps bare cmd and leaves /c alone" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const wrapped = try wrapCmdForUtf8(alloc, .{ .direct = &.{"cmd.exe"} });
    try testing.expectEqualStrings("cmd.exe", wrapped.direct[0]);
    try testing.expectEqualStrings("/d", wrapped.direct[1]);
    try testing.expectEqualStrings("/k", wrapped.direct[2]);
    try testing.expectEqualStrings(cmd_chcp, wrapped.direct[3]);

    const skipped = try wrapCmdForUtf8(alloc, .{ .direct = &.{ "cmd.exe", "/c", "echo" } });
    try testing.expectEqual(@as(usize, 3), skipped.direct.len);

    const pwsh = try wrapCmdForUtf8(alloc, .{ .direct = &.{"pwsh.exe"} });
    try testing.expectEqualStrings("pwsh.exe", pwsh.direct[0]);
    try testing.expectEqual(@as(usize, 1), pwsh.direct.len);
}
