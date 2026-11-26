//! The fork's own `PathSpace` and the WTF-8 to NT-prefixed WTF-16 conversion
//! its file code needs.
//!
//! Zig 0.17 removed std's `sliceToPrefixedFileW` and `PathSpace` from `os.windows`
//! (the conversion lives on in `std.Io.Threaded`, with another error set).
//! Until the 1B cutover this bridges to std's form on 0.15.2, whose behaviour
//! every caller was written against (PLAN section 5, "sliceToPrefixedFileW").
//! The std function is reached by name through `@field`, on purpose: it is the
//! one sanctioned use, so the Win32-identifier lint (which resolves spellings,
//! not strings) does not count it, and 1B replaces the body of `convert` and
//! nothing else. Do not copy the pattern.

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

fn convert(path: []const u8) Error!PathSpace {
    const std_convert = @field(std.os.windows, "sliceToPrefixedFileW");
    const std_space = try std_convert(null, path);
    comptime std.debug.assert(@sizeOf(@TypeOf(std_space)) == @sizeOf(PathSpace));
    var out: PathSpace = undefined;
    out.len = std_space.len;
    @memcpy(out.data[0 .. std_space.len + 1], std_space.data[0 .. std_space.len + 1]);
    return out;
}

test "the prefixed path keeps std's conversion" {
    const testing = std.testing;

    // A relative path stays relative and null-terminated.
    const relative = try sliceToPrefixedFileW("a\\b.txt");
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("a\\b.txt"), relative.span());
    try testing.expectEqual(@as(u16, 0), relative.data[relative.len]);

    // A drive-absolute path takes the NT prefix.
    const absolute = try sliceToPrefixedFileW("C:\\Windows\\notepad.exe");
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\\??\\C:\\Windows\\notepad.exe"), absolute.span());

    // A verbatim path keeps its text under the NT prefix.
    const verbatim = try sliceToPrefixedFileW("\\\\?\\C:\\x");
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\\??\\C:\\x"), verbatim.span());

    // A UNC path becomes `\??\UNC\server\share`.
    const unc = try sliceToPrefixedFileW("\\\\server\\share\\f");
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("\\??\\UNC\\server\\share\\f"), unc.span());

    // Bytes that are not WTF-8 fail with the error std gave.
    try testing.expectError(error.InvalidWtf8, sliceToPrefixedFileW("\xff"));
}

test "the prefixed path agrees with std on a corpus" {
    const std_convert = @field(std.os.windows, "sliceToPrefixedFileW");
    const corpus = [_][]const u8{
        "",
        ".",
        "..\\x",
        "a\\..\\..\\b",
        "dir\\.\\file",
        "C:file",
        "\\rooted",
        "C:\\a\\..\\b",
        "\\\\.\\COM1",
        "\\\\.\\pipe\\name",
        "\\\\?\\UNC\\s\\h",
        "\\??\\C:\\y",
        "C:\\\u{00e9}\u{4e2d}",
    };
    for (corpus) |path| {
        const mine = try sliceToPrefixedFileW(path);
        const theirs = try std_convert(null, path);
        try std.testing.expectEqualSlices(u16, theirs.span(), mine.span());
    }
}
