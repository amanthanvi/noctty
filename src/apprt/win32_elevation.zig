//! Elevation as a designed surface (C14).
//!
//! Mixed-elevation tabs are out. An elevated session is a separate
//! process/window launched with the `runas` verb. Restore never
//! relaunches elevated windows.

const std = @import("std");
const builtin = @import("builtin");

pub const elevated_title_prefix = "[Administrator] ";

pub fn quoteArg(arg: []const u8, out: []u8) ![]const u8 {
    const needs_quotes = std.mem.indexOfAny(u8, arg, " \t\"") != null;
    if (!needs_quotes) {
        if (arg.len > out.len) return error.BufferTooSmall;
        @memcpy(out[0..arg.len], arg);
        return out[0..arg.len];
    }

    var i: usize = 0;
    if (i >= out.len) return error.BufferTooSmall;
    out[i] = '"';
    i += 1;
    for (arg) |c| {
        if (c == '"') {
            if (i >= out.len) return error.BufferTooSmall;
            out[i] = '\\';
            i += 1;
        }
        if (i >= out.len) return error.BufferTooSmall;
        out[i] = c;
        i += 1;
    }
    if (i >= out.len) return error.BufferTooSmall;
    out[i] = '"';
    return out[0 .. i + 1];
}

pub fn buildRunasArgs(exe: []const u8, extra: []const []const u8, out: []u8) ![]const u8 {
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    const quoted_exe = try quoteArg(exe, &buf);
    if (quoted_exe.len > out.len) return error.BufferTooSmall;
    @memcpy(out[0..quoted_exe.len], quoted_exe);
    i = quoted_exe.len;
    for (extra) |arg| {
        if (i >= out.len) return error.BufferTooSmall;
        out[i] = ' ';
        i += 1;
        const quoted = try quoteArg(arg, &buf);
        if (i + quoted.len > out.len) return error.BufferTooSmall;
        @memcpy(out[i..][0..quoted.len], quoted);
        i += quoted.len;
    }
    return out[0..i];
}

pub fn markTitle(title: []const u8, out: []u8) []const u8 {
    if (std.mem.startsWith(u8, title, elevated_title_prefix)) {
        if (title.len > out.len) return title[0..out.len];
        @memcpy(out[0..title.len], title);
        return out[0..title.len];
    }
    const needed = elevated_title_prefix.len + title.len;
    if (needed > out.len) return title;
    @memcpy(out[0..elevated_title_prefix.len], elevated_title_prefix);
    @memcpy(out[elevated_title_prefix.len..][0..title.len], title);
    return out[0..needed];
}

pub fn isElevated() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return IsUserAnAdmin() != 0;
}

extern "shell32" fn IsUserAnAdmin() callconv(.winapi) i32;

test "quoteArg wraps spaces" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cmd", try quoteArg("cmd", &buf));
    try std.testing.expectEqualStrings("\"C:\\Program Files\\a.exe\"", try quoteArg("C:\\Program Files\\a.exe", &buf));
}

test "markTitle prefixes once" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[Administrator] pwsh", markTitle("pwsh", &buf));
    try std.testing.expectEqualStrings("[Administrator] pwsh", markTitle("[Administrator] pwsh", &buf));
}
