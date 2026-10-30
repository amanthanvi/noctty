const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Search for "cmd" in the PATH and return the absolute path. This will
/// always allocate if there is a non-null result. The caller must free the
/// resulting value.
pub fn expand(alloc: Allocator, cmd: []const u8) !?[]u8 {
    // If the command already contains a slash, then we return it as-is
    // because it is assumed to be absolute or relative.
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return try alloc.dupe(u8, cmd);
    }

    const PATH = switch (builtin.os.tag) {
        .windows => blk: {
            const win_path = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("PATH")) orelse return null;
            const path = try std.unicode.utf16LeToUtf8Alloc(alloc, win_path);
            break :blk path;
        },
        else => std.posix.getenvZ("PATH") orelse return null,
    };
    defer if (builtin.os.tag == .windows) alloc.free(PATH);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, PATH, std.fs.path.delimiter);
    var seen_eacces = false;
    while (it.next()) |search_path| {
        // We need enough space in our path buffer to store this
        const path_len = search_path.len + cmd.len + 1;
        if (path_buf.len < path_len) return error.PathTooLong;

        // Copy in the full path
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = std.fs.path.sep;
        @memcpy(path_buf[search_path.len + 1 ..][0..cmd.len], cmd);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0];

        // Stat it
        const f = std.fs.cwd().openFile(
            full_path,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.AccessDenied => {
                // Accumulate this and return it later so we can try other
                // paths that we have access to.
                seen_eacces = true;
                continue;
            },
            else => return err,
        };
        defer f.close();
        const stat = try f.stat();
        if (stat.kind != .directory and isExecutable(stat.mode)) {
            return try alloc.dupe(u8, full_path);
        }
    }

    if (seen_eacces) return error.AccessDenied;

    return null;
}

/// Whether `path` names a Windows network share or device namespace rather
/// than a local drive: `\\server\share`, `//server/share`, `\\?\UNC\...`,
/// `\\.\pipe\x` and the mixed-separator spellings, all of which start with two
/// path separators. Windows treats `/` and `\` alike there, so `\/` and `/\`
/// count too, and so does the NT namespace prefix `\??\`. Opening such a path reaches the network or a device, so paths
/// that a program reports (working directory, image file) are screened with
/// this before the filesystem is touched.
///
/// Pure and platform independent: a POSIX `//x` is legal, so callers that can
/// run elsewhere must gate on Windows themselves.
pub fn isNetworkOrDevicePath(path: []const u8) bool {
    if (path.len >= 2 and isSeparator(path[0]) and isSeparator(path[1])) return true;

    // The NT object namespace prefix `\??\` is passed to the kernel unchanged
    // by the path conversion, so `\??\UNC\server\share` reaches the share too.
    return path.len >= 4 and isSeparator(path[0]) and path[1] == '?' and
        path[2] == '?' and isSeparator(path[3]);
}

/// Whether `path` is a Windows drive-absolute path: a letter, `:` and a
/// separator of either kind (`C:\x`, `c:/x`).
pub fn isDriveAbsolutePath(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        isSeparator(path[2]);
}

/// The Windows path a drive path written another way names (`/C:/x` in a
/// file URI, `/c/x` from MSYS2). `rest` is what follows the `X:` and its
/// first separator.
pub fn drivePathToWindows(alloc: Allocator, drive: u8, rest: []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, drive);
    try buf.appendSlice(alloc, ":\\");
    try appendWindowsPath(&buf, alloc, trimLeadingSeparators(rest));
    return try buf.toOwnedSlice(alloc);
}

/// Whether a reported directory is one a WSL shell gives: POSIX (`/home/me`),
/// or the UNC form Windows names a distro's files by.
pub fn isWslPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/") or
        std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\");
}

/// A distro's `\\wsl.localhost\D\rest` or `\\wsl$\D\rest` as its own `/rest`;
/// any other path as it is.
pub fn normalizeWslPath(alloc: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) return try alloc.dupe(u8, path);

    for ([_][]const u8{
        "\\\\wsl.localhost\\",
        "\\\\wsl$\\",
    }) |prefix| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;

        const rest = path[prefix.len..];
        const distro_sep = std.mem.indexOfAny(u8, rest, "/\\") orelse return try alloc.dupe(u8, "/");
        const distro_rest = trimLeadingSeparators(rest[distro_sep..]);
        if (distro_rest.len == 0) return try alloc.dupe(u8, "/");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.append(alloc, '/');
        try appendNormalizedPath(&buf, alloc, distro_rest);
        return try buf.toOwnedSlice(alloc);
    }

    return try alloc.dupe(u8, path);
}

/// Whether `path` is a file URI's path to a drive (`/C:/x`).
pub fn isWindowsUriPath(path: []const u8) bool {
    return path.len >= 4 and
        path[0] == '/' and
        std.ascii.isAlphabetic(path[1]) and
        path[2] == ':' and
        isSeparator(path[3]);
}

/// The Windows path of a file URI's drive path (`/C:/x` is `C:\x`).
pub fn uriPathToWindows(alloc: Allocator, path: []const u8) Allocator.Error![]const u8 {
    return try drivePathToWindows(alloc, path[1], path[3..]);
}

/// True for a UNC path that still carries the leading `/` of the URI it came
/// from, e.g. `/\\server\share\dir`. cmd's `$P` expands to a raw UNC path, so
/// `kitty-shell-cwd://localhost/$P` yields exactly this shape.
///
/// The remainder must be backslash-separated. Backslashes are legal in POSIX
/// filenames, so a WSL or POSIX shell could in principle report a directory
/// such as `/\\server/share`; requiring that no forward slash appears after
/// the URI separator keeps that case on the WSL path where it belongs, while
/// still matching everything cmd's `$P` can produce (cmd always emits
/// backslashes).
pub fn isUncUriPath(path: []const u8) bool {
    if (path.len < 4) return false;
    if (path[0] != '/' or path[1] != '\\' or path[2] != '\\') return false;
    if (isSeparator(path[3])) return false;

    // Must be backslash-separated throughout: a forward slash proves this is a
    // POSIX path that merely begins with backslashes, not the form cmd's `$P`
    // produces.
    if (std.mem.indexOfScalar(u8, path[3..], '/') != null) return false;

    // A UNC path needs both a host and a non-empty share (`\\server\share`).
    // `/\\server` alone is a legal POSIX filename, never a usable UNC path.
    const host = path[3..];
    const sep = std.mem.indexOfScalar(u8, host, '\\') orelse return false;
    return sep + 1 < host.len;
}

/// Return true when a Windows path contains no bytes that can terminate or
/// split a CreateProcess environment/current-directory value or a window title.
pub fn isSafeWindowsPath(path: []const u8) bool {
    for (path) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

fn trimLeadingSeparators(path: []const u8) []const u8 {
    return std.mem.trimLeft(u8, path, "/\\");
}

fn appendWindowsPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) Allocator.Error!void {
    for (path) |c| try buf.append(alloc, if (c == '/') '\\' else c);
}

fn appendNormalizedPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) Allocator.Error!void {
    for (path) |c| try buf.append(alloc, if (c == '\\') '/' else c);
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn isExecutable(mode: std.fs.File.Mode) bool {
    if (builtin.os.tag == .windows) return true;
    return mode & 0o0111 != 0;
}

// `uname -n` is the *nix equivalent of `hostname.exe` on Windows
test "expand: hostname" {
    const executable = if (builtin.os.tag == .windows) "hostname.exe" else "uname";
    const path = (try expand(testing.allocator, executable)).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len > executable.len);
}

test "expand: does not exist" {
    const path = try expand(testing.allocator, "thisreallyprobablydoesntexist123");
    try testing.expect(path == null);
}

test "expand: slash" {
    const path = (try expand(testing.allocator, "foo/env")).?;
    defer testing.allocator.free(path);
    try testing.expect(path.len == 7);
}

test "isNetworkOrDevicePath" {
    for ([_][]const u8{
        "\\\\server\\share",
        "\\\\server\\share\\dir\\file.png",
        "//server/share",
        "\\/server/share",
        "/\\server\\share",
        "/\\\\server/share",
        "\\\\?\\UNC\\server\\share",
        "\\\\?\\unc\\server\\share",
        "\\\\?\\C:\\Users\\me",
        "\\\\.\\pipe\\x",
        "\\\\.\\GLOBALROOT\\Device\\Mup\\server\\share",
        "\\\\",
        "//",
        "\\??\\UNC\\server\\share",
        "\\??\\GLOBALROOT\\Device\\Mup\\server\\share",
        "/??/UNC/server/share",
        "\\??\\C:\\Users\\me",
    }) |p| try testing.expect(isNetworkOrDevicePath(p));

    for ([_][]const u8{
        "",
        "/",
        "\\",
        "C:\\Users\\me",
        "C:/Users/me",
        "c:\\",
        "/home/me",
        "/C:/Users/me",
        "relative\\dir",
        "\\single",
        "x\\\\y",
        "\\??",
        "\\?\\x",
        "/?x",
    }) |p| try testing.expect(!isNetworkOrDevicePath(p));
}

test "isUncUriPath only matches uri-carried unc paths" {
    try testing.expect(isUncUriPath("/\\\\server\\share"));
    try testing.expect(isUncUriPath("/\\\\s\\a"));
    try testing.expect(!isUncUriPath("/home/aman"));
    try testing.expect(!isUncUriPath("//server/share"));
    try testing.expect(!isUncUriPath("\\\\server\\share"));
    try testing.expect(!isUncUriPath("/\\\\"));
    try testing.expect(!isUncUriPath("/\\\\\\share"));
    try testing.expect(!isUncUriPath("/C:/Users"));
}
