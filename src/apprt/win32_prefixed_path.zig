//! The fork's own `PathSpace` and the WTF-8 to NT-prefixed WTF-16 conversion
//! its file code needs.
//!
//! Zig 0.17 removed `sliceToPrefixedFileW` and `PathSpace` from
//! `std.os.windows` (the conversion lives on in `std.Io.Threaded`, with another
//! error set). Until the 1B cutover `convert` was the PLAN section 5 wrapper
//! "calling std's `os.windows` form on 0.15.2". 1B replaced the body of
//! `convert` and nothing else: it converts WTF-8 to WTF-16 itself, so bytes
//! that are not WTF-8 still fail with `error.InvalidWtf8` (0.17's
//! `sliceToPrefixedFileW` reports `error.BadPathName`), and hands the WTF-16
//! form to `std.Io.Threaded.wToPrefixedFileW`, the 0.15.2 conversion's
//! successor.

const std = @import("std");

/// `PATH_MAX_WIDE` of std's 0.15.2 `PathSpace`: the longest path the NT
/// prefixed forms allow, in UTF-16 code units.
pub const path_max_wide = 32767;

pub const PathSpace = struct {
    data: [path_max_wide:0]u16,
    len: usize,

    pub fn span(self: *const PathSpace) [:0]const u16 {
        return self.data[0..self.len :0];
    }
};

pub const Error = error{
    InvalidWtf8,
    AccessDenied,
    BadPathName,
    FileNotFound,
    NameTooLong,
    Unexpected,
};

/// `path` as a null-terminated WTF-16 path, with the NT-style prefix `\??\`
/// when it is anything but a relative path. The error set is std's former
/// `Wtf8ToPrefixedFileWError`.
pub fn sliceToPrefixedFileW(path: []const u8) Error!PathSpace {
    return convert(path);
}

/// Its frame holds two path spaces (the WTF-16 form and std's result, about
/// 128 KiB) and it returns a third. No caller runs on a termio or renderer
/// thread; measure it against that thread's stack (`stackUse` in
/// `os/main.zig`) before one does.
fn convert(path: []const u8) Error!PathSpace {
    // The conversion writes into a fixed buffer, so a path longer than the NT
    // forms allow is refused before anything converts it (PATH-BOUND, the
    // 2026-10-30 entry in launch-and-paths.md: 40,000 bytes ended the Debug
    // test binary with "index out of bounds" in 0.15.2's conversion;
    // ReleaseFast would write past the buffer, inferred).
    if ((std.unicode.calcWtf16LeLen(path) catch return error.InvalidWtf8) > path_max_wide)
        return error.NameTooLong;
    var wide: std.Io.Threaded.WindowsPathSpace = undefined;
    wide.len = try std.unicode.wtf8ToWtf16Le(&wide.data, path);
    wide.data[wide.len] = 0;
    const std_space = std.Io.Threaded.wToPrefixedFileW(null, wide.span(), .{}) catch |err| switch (err) {
        // With no directory handle the conversion makes no cancelable call.
        error.Canceled => return error.Unexpected,
        else => |e| return e,
    };
    comptime std.debug.assert(@sizeOf(@TypeOf(std_space)) == @sizeOf(PathSpace));
    var out: PathSpace = undefined;
    out.len = std_space.len;
    @memcpy(out.data[0 .. std_space.len + 1], std_space.data[0 .. std_space.len + 1]);
    return out;
}

fn expectConverts(path: []const u8, expected: []const u8) !void {
    const space = try sliceToPrefixedFileW(path);
    try std.testing.expectEqual(@as(u16, 0), space.data[space.len]);
    var buf: [256]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&buf, space.span());
    try std.testing.expectEqualStrings(expected, buf[0..n]);
}

// Each expected value is what std 0.15.2's own `sliceToPrefixedFileW` returned
// for the input on 2026-11-26 (read from a run of the std function itself), so
// these tests pin the conversion against a drift on either side of the 1B
// cutover. Cases that depend on the working directory are left out.
test "the prefixed path keeps std's conversion" {
    // Relative paths stay relative and are normalized.
    try expectConverts("a\\b.txt", "a\\b.txt");
    try expectConverts("", "");
    try expectConverts(".", "");
    try expectConverts("dir\\.\\file", "dir\\file");
    try expectConverts("a\\..\\b", "b");
    // Drive-absolute and rooted forms take the NT prefix and are normalized.
    try expectConverts("C:\\Windows\\notepad.exe", "\\??\\C:\\Windows\\notepad.exe");
    try expectConverts("C:\\a\\..\\b", "\\??\\C:\\b");
    try expectConverts("C:\\a\\.\\b\\", "\\??\\C:\\a\\b\\");
    try expectConverts("C:/a/b", "\\??\\C:\\a\\b");
    try expectConverts("C:\\\u{e9}\u{4e2d}", "\\??\\C:\\\u{e9}\u{4e2d}");
    // UNC paths become `\??\UNC\server\share`.
    try expectConverts("\\\\server\\share\\f", "\\??\\UNC\\server\\share\\f");
    try expectConverts("\\\\server\\share\\a\\..\\b", "\\??\\UNC\\server\\share\\b");
    // Local-device and verbatim forms keep their text under the NT prefix; a
    // verbatim path is not normalized.
    try expectConverts("\\\\.\\COM1", "\\??\\COM1");
    try expectConverts("\\\\.\\pipe\\name", "\\??\\pipe\\name");
    try expectConverts("\\\\?\\C:\\x", "\\??\\C:\\x");
    try expectConverts("\\\\?\\UNC\\s\\h", "\\??\\UNC\\s\\h");
    try expectConverts("\\\\?\\C:\\a\\..\\b", "\\??\\C:\\a\\..\\b");
    try expectConverts("//?/C:/x", "\\??\\C:\\x");
    try expectConverts("\\??\\C:\\y", "\\??\\C:\\y");
}

test "a path longer than the NT forms allow is refused before it converts" {
    // 40,000 bytes, as PATH-BOUND measured: refused, not converted.
    const long: [40000]u8 = @splat('a');
    try std.testing.expectError(error.NameTooLong, sliceToPrefixedFileW(&long));
    // Exactly `path_max_wide` units of a relative name still converts.
    const at_limit: [path_max_wide]u8 = @splat('b');
    const space = try sliceToPrefixedFileW(&at_limit);
    try std.testing.expectEqual(@as(usize, path_max_wide), space.len);
    // One unit over is refused.
    const over: [path_max_wide + 1]u8 = @splat('b');
    try std.testing.expectError(error.NameTooLong, sliceToPrefixedFileW(&over));
    // A two-byte UTF-8 sequence is one unit, so the bound counts units, not bytes.
    var two_byte: [path_max_wide * 2]u8 = undefined;
    for (0..path_max_wide) |i| two_byte[i * 2 ..][0..2].* = "\xc3\xa9".*;
    _ = try sliceToPrefixedFileW(&two_byte);
}

test "bytes that are not WTF-8 fail with the error std gave" {
    try std.testing.expectError(error.InvalidWtf8, sliceToPrefixedFileW("\xff"));
}
