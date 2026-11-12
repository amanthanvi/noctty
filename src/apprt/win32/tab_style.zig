//! A tab's profile color and icon. Settings' profile window keeps them among
//! the profile's variables (`windows_shell.tab_color_env`, `tab_icon_env`),
//! as it keeps its zoom: the color as `#RRGGBB`, drawn as a stripe along the
//! top of the tab; the icon as a file (`.ico`, or an `.exe`/`.dll` with an
//! optional `,<index>`), a short text such as an emoji, or `none`. Without
//! one, the tab shows the icon of the program the profile runs.
//!
//! Nothing here logs a path or a command line.
const std = @import("std");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const BOOL = win32_types.BOOL;
/// An icon handle, never null (`win32_types.HICON` is the nullable one).
pub const IconHandle = *anyopaque;

/// A COLORREF (0x00BBGGRR) from `#RRGGBB` or `RRGGBB`; null otherwise.
pub fn parseColor(text_in: []const u8) ?u32 {
    const text = std.mem.trim(u8, text_in, " \t");
    const hex = if (text.len != 0 and text[0] == '#') text[1..] else text;
    if (hex.len != 6) return null;
    const rgb = std.fmt.parseInt(u32, hex, 16) catch return null;
    const r = (rgb >> 16) & 0xFF;
    const g = (rgb >> 8) & 0xFF;
    const b = rgb & 0xFF;
    return r | (g << 8) | (b << 16);
}

/// `#RRGGBB` for a COLORREF, in `buf`.
pub fn formatColor(buf: *[7]u8, colorref: u32) []const u8 {
    const r = colorref & 0xFF;
    const g = (colorref >> 8) & 0xFF;
    const b = (colorref >> 16) & 0xFF;
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch unreachable;
}

pub const Icon = union(enum) {
    /// The icon of the program the profile runs.
    auto,
    none,
    file: struct { path: []const u8, index: i32 },
    /// A short text drawn in the icon's place, such as an emoji.
    glyph: []const u8,
};

/// The longest text an icon may be, in bytes (an emoji with its modifiers).
pub const max_glyph_len = 32;

/// What the icon variable says. A value with a path separator, or ending in
/// `.ico`, `.exe` or `.dll` (with an optional `,<index>`), is a file.
pub fn parseIcon(text_in: ?[]const u8) Icon {
    const text = std.mem.trim(u8, text_in orelse return .auto, " \t\"");
    if (text.len == 0) return .auto;
    if (std.ascii.eqlIgnoreCase(text, "none")) return .none;
    var path = text;
    var index: i32 = 0;
    if (std.mem.lastIndexOfScalar(u8, text, ',')) |comma| {
        if (std.fmt.parseInt(i32, std.mem.trim(u8, text[comma + 1 ..], " "), 10)) |n| {
            path = std.mem.trim(u8, text[0..comma], " \"");
            index = n;
        } else |_| {}
    }
    const is_file = std.mem.indexOfAny(u8, path, "\\/") != null or
        endsWithIgnoreCase(path, ".ico") or endsWithIgnoreCase(path, ".exe") or endsWithIgnoreCase(path, ".dll");
    if (is_file) return .{ .file = .{ .path = path, .index = index } };
    if (text.len > max_glyph_len) return .none;
    return .{ .glyph = text };
}

/// Whether `text` is an icon value the profile window can keep.
pub fn validIcon(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\"");
    if (trimmed.len == 0) return true;
    return switch (parseIcon(trimmed)) {
        .none => std.ascii.eqlIgnoreCase(trimmed, "none"),
        .glyph => std.unicode.utf8ValidateSlice(trimmed),
        else => true,
    };
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

/// The program a Windows command line starts: its first word, without
/// quotes.
pub fn programOf(command_line: []const u8) []const u8 {
    const line = std.mem.trimLeft(u8, command_line, " \t");
    if (line.len == 0) return line;
    if (line[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse line.len;
        return line[1..end];
    }
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    return line[0..end];
}

extern "kernel32" fn SearchPathW(path: ?[*:0]const u16, file: [*:0]const u16, ext: ?[*:0]const u16, len: u32, buf: [*]u16, part: ?*?[*]u16) callconv(.winapi) u32;
extern "kernel32" fn ExpandEnvironmentStringsW(src: [*:0]const u16, dst: ?[*]u16, size: u32) callconv(.winapi) u32;
extern "shell32" fn SHDefExtractIconW(file: [*:0]const u16, index: i32, flags: u32, large: ?*?IconHandle, small: ?*?IconHandle, size: u32) callconv(.winapi) i32;
pub extern "user32" fn DestroyIcon(icon: IconHandle) callconv(.winapi) BOOL;
pub extern "user32" fn DrawIconEx(hdc: win32_types.HDC, x: i32, y: i32, icon: IconHandle, cx: i32, cy: i32, step: u32, brush: ?*anyopaque, flags: u32) callconv(.winapi) BOOL;
pub const DI_NORMAL: u32 = 0x3;

/// The icon at `index` of the file `path` (a bare program name is looked up
/// as Windows would run it), `px` pixels square; null when there is none.
pub fn loadIcon(alloc: Allocator, path: []const u8, index: i32, px: i32) ?IconHandle {
    if (path.len == 0 or px <= 0) return null;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return null;
    defer alloc.free(wide);
    var expanded: [1024]u16 = undefined;
    const exp_len = ExpandEnvironmentStringsW(wide.ptr, &expanded, expanded.len);
    const source: [*:0]const u16 = if (exp_len != 0 and exp_len <= expanded.len) @ptrCast(&expanded) else wide.ptr;
    var found: [1024]u16 = undefined;
    const has_dir = std.mem.indexOfAny(u8, path, "\\/:") != null;
    const file: [*:0]const u16 = if (has_dir) source else blk: {
        const len = SearchPathW(null, source, std.unicode.utf8ToUtf16LeStringLiteral(".exe"), found.len, &found, null);
        if (len == 0 or len >= found.len) return null;
        break :blk @ptrCast(&found);
    };
    var icon: ?IconHandle = null;
    const size: u32 = @intCast(@min(px, 256));
    if (SHDefExtractIconW(file, index, 0, &icon, null, size) != 0) return null;
    return icon;
}

test "tab style: colors are #RRGGBB, kept as COLORREF" {
    try std.testing.expectEqual(@as(?u32, 0x00332211), parseColor("#112233"));
    try std.testing.expectEqual(@as(?u32, 0x00332211), parseColor(" 112233 "));
    try std.testing.expectEqual(@as(?u32, null), parseColor("#12345"));
    try std.testing.expectEqual(@as(?u32, null), parseColor("red"));
    var buf: [7]u8 = undefined;
    try std.testing.expectEqualStrings("#112233", formatColor(&buf, 0x00332211));
}

test "tab style: an icon is a file, a glyph, none, or the program's" {
    try std.testing.expect(parseIcon(null) == .auto);
    try std.testing.expect(parseIcon("  ") == .auto);
    try std.testing.expect(parseIcon("NONE") == .none);
    const ico = parseIcon("C:\\icons\\db.ico").file;
    try std.testing.expectEqualStrings("C:\\icons\\db.ico", ico.path);
    try std.testing.expectEqual(@as(i32, 0), ico.index);
    const dll = parseIcon("\"shell32.dll\", 12").file;
    try std.testing.expectEqualStrings("shell32.dll", dll.path);
    try std.testing.expectEqual(@as(i32, 12), dll.index);
    try std.testing.expectEqualStrings("⚡", parseIcon("⚡").glyph);
    try std.testing.expect(validIcon(""));
    try std.testing.expect(validIcon("🖥"));
}

test "tab style: the program is the command line's first word" {
    try std.testing.expectEqualStrings("pwsh.exe", programOf("pwsh.exe -NoLogo"));
    try std.testing.expectEqualStrings("C:\\Program Files\\Git\\bin\\bash.exe", programOf("\"C:\\Program Files\\Git\\bin\\bash.exe\" --login"));
    try std.testing.expectEqualStrings("mstsc.exe", programOf("  mstsc.exe /v:host"));
}
