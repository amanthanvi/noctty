const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const windows = @import("windows.zig");

const log = std.log.scoped(.os);

pub const rlimit = if (@hasDecl(posix.system, "rlimit")) posix.rlimit else struct {};

/// This maximizes the number of file descriptors we can have open. We
/// need to do this because each window consumes at least a handful of fds.
/// This is extracted from the Zig compiler source code.
pub fn fixMaxFiles() ?rlimit {
    if (!@hasDecl(posix.system, "rlimit") or
        posix.system.rlimit == void) return null;

    const old = posix.getrlimit(.NOFILE) catch {
        log.warn("failed to query file handle limit, may limit max windows", .{});
        return null; // Oh well; we tried.
    };

    // If we're already at the max, we're done.
    if (old.cur >= old.max) {
        log.debug("file handle limit already maximized value={}", .{old.cur});
        return old;
    }

    // Do a binary search for the limit.
    var lim = old;
    var min: posix.rlim_t = lim.cur;
    var max: posix.rlim_t = 1 << 20;
    // But if there's a defined upper bound, don't search, just set it.
    if (lim.max != posix.RLIM.INFINITY) {
        min = lim.max;
        max = lim.max;
    }

    while (true) {
        lim.cur = min + @divTrunc(max - min, 2); // on freebsd rlim_t is signed
        if (posix.setrlimit(.NOFILE, lim)) |_| {
            min = lim.cur;
        } else |_| {
            max = lim.cur;
        }
        if (min + 1 >= max) break;
    }

    log.debug("file handle limit raised value={}", .{lim.cur});
    return old;
}

pub fn restoreMaxFiles(lim: rlimit) void {
    if (!@hasDecl(posix.system, "rlimit")) return;
    posix.setrlimit(.NOFILE, lim) catch {};
}

/// Return the recommended path for temporary files. Any trailing
/// path separator is stripped so callers can safely join with their
/// own separator (e.g. `"{tmp}/{name}"`).
///
/// On Windows this calls `GetTempPathW` and allocates a UTF-8 copy
/// (or duplicates a hard-fallback string if the syscall fails). On
/// POSIX this returns `$TMPDIR`/`$TMP` (or `"/tmp"` as a fallback)
/// without allocating. Always pair with `freeTmpDir` to release any
/// allocation.
pub fn allocTmpDir(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    if (builtin.os.tag == .windows) {
        // GetTempPathW guarantees the result fits in MAX_PATH+1.
        var buf: [windows.MAX_PATH + 1:0]u16 = undefined;
        const len = windows.exp.kernel32.GetTempPathW(buf.len, &buf);
        if (len > 0) {
            // Trim the UTF-16 string before encoding as UT8-8 so that the
            // returned slice's length matches its underlying allocation.
            const trimmed = std.mem.trimEnd(u16, buf[0..len], &.{std.fs.path.sep});
            if (std.unicode.utf16LeToUtf8Alloc(allocator, trimmed)) |utf8| {
                return utf8;
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => log.warn("failed to convert temp dir path from windows string: {}", .{e}),
            }
        }
        return allocator.dupe(u8, "C:\\Windows\\Temp");
    }
    const tmpdir = posix.getenv("TMPDIR") orelse posix.getenv("TMP") orelse return "/tmp";
    return std.mem.trimEnd(u8, tmpdir, &.{std.fs.path.sep});
}

/// Free a path returned by `allocTmpDir` if it allocated memory.
/// This is a no-op on POSIX.
pub fn freeTmpDir(allocator: std.mem.Allocator, dir: []const u8) void {
    if (builtin.os.tag != .windows) return;
    allocator.free(dir);
}

test "allocTmpDir without TMP follows GetTempPathW to TEMP" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const kernel32 = std.os.windows.kernel32;
    const tmp_name = std.unicode.utf8ToUtf16LeStringLiteral("TMP");
    const temp_name = std.unicode.utf8ToUtf16LeStringLiteral("TEMP");

    // getenvW points into the environment block, which a change can move.
    const saved_tmp = if (std.process.getenvW(tmp_name)) |v| try alloc.dupeZ(u16, v) else null;
    defer if (saved_tmp) |v| alloc.free(v);
    const saved_temp = if (std.process.getenvW(temp_name)) |v| try alloc.dupeZ(u16, v) else null;
    defer if (saved_temp) |v| alloc.free(v);
    defer _ = kernel32.SetEnvironmentVariableW(tmp_name, if (saved_tmp) |v| v.ptr else null);
    defer _ = kernel32.SetEnvironmentVariableW(temp_name, if (saved_temp) |v| v.ptr else null);

    // GetTempPathW does not check that the directory exists, and its
    // result always ends in a separator.
    try testing.expect(kernel32.SetEnvironmentVariableW(tmp_name, null) != 0);
    try testing.expect(kernel32.SetEnvironmentVariableW(
        temp_name,
        std.unicode.utf8ToUtf16LeStringLiteral("C:\\noctty-test-temp\\"),
    ) != 0);

    const dir = try allocTmpDir(alloc);
    defer freeTmpDir(alloc, dir);
    try testing.expectEqualStrings("C:\\noctty-test-temp", dir);
}
