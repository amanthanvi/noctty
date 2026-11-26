const std = @import("std");
const builtin = @import("builtin");
const win32_repeat = @import("../apprt/win32_repeat.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The `Io` the updater's file, process, clock and event calls take. The
/// portable update helper runs before the global state exists
/// (`main_ghostty.zig` runs `maybeRunPortableUpdateHelper` ahead of
/// `global.init`), and the check, stage and apply paths run on threads that
/// have no `Io` of their own, so `global.io()` is not available to all of
/// them. On Zig 0.15 none of these calls could be canceled; this instance has
/// no cancelation either, and every call blocks on the calling thread as it
/// did. Tests take `std.testing.io`.
pub fn updateIo() std.Io {
    if (builtin.is_test) return std.testing.io;
    return std.Io.Threaded.global_single_threaded.io();
}

/// The live process environment, as 0.15's `std.process.getEnvVarOwned` and
/// `std.process.getEnvMap` read it. On Windows `std.process.Environ` reads
/// the PEB's block at each call (`Environ.GlobalBlock`), so a variable this
/// process set or removed since start-up reads as it is now. It is the block
/// `global.environ()` names once the global state exists, and unlike that it
/// is usable before.
pub fn processEnviron() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => @compileError("the updater reads the live environment on Windows only"),
    };
}

/// The process command line, the PEB's, which `main_ghostty.zig` also hands
/// `global.init`. 0.15's `std.process.argsAlloc` read the same line, and so
/// does this before the global state exists (the portable update helper).
pub fn processArgs() std.process.Args {
    return switch (builtin.os.tag) {
        .windows => .{ .vector = std.os.windows.peb().ProcessParameters.CommandLine.slice() },
        else => @compileError("the updater reads the command line on Windows only"),
    };
}

/// Moves `file`'s own cursor to `offset`, as 0.15's `File.seekTo` did. Zig
/// 0.17's `Io.File` has no method for it; this is the call its streaming
/// readers and writers make (`File.Reader.seekTo`, `File.Writer.seekTo`).
pub fn seekFileTo(io: std.Io, file: std.Io.File, offset: u64) std.Io.File.SeekError!void {
    return io.vtable.fileSeekTo(io.userdata, file, offset);
}

/// 0.15's `File.readToEndAlloc(alloc, max_bytes)`: the rest of `file` from
/// its own cursor, a file of exactly `max_bytes` accepted and a longer one
/// refused with `error.FileTooBig`, and a failed read reported as its own
/// error rather than `error.ReadFailed`.
pub fn readToEndAlloc(file: std.Io.File, alloc: Allocator, max_bytes: usize) ![]u8 {
    var reader = file.readerStreaming(updateIo(), &.{});
    // `allocRemaining` accepts exactly its limit, as 0.15 did.
    return reader.interface.allocRemaining(alloc, .limited(max_bytes)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.StreamTooLong => return error.FileTooBig,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub fn portableRelativePathAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    const result = try alloc.dupe(u8, path);
    for (result) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return result;
}

pub fn parseSha256Hex(hex: []const u8) ![Sha256.digest_length]u8 {
    if (hex.len != Sha256.digest_length * 2) return error.InvalidChecksum;
    var digest: [Sha256.digest_length]u8 = undefined;
    for (&digest, 0..) |*byte, i| {
        byte.* = (try hexNibble(hex[i * 2]) << 4) | try hexNibble(hex[i * 2 + 1]);
    }
    return digest;
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidChecksum,
    };
}

pub fn sha256File(path: []const u8) ![Sha256.digest_length]u8 {
    const io = updateIo();
    // 0.15's `openFileAbsolute` refused a directory (`error.IsDir`); 0.17's
    // opens one unless told not to.
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false });
    defer file.close(io);

    return sha256OpenFile(&file);
}

/// Hash the whole file, leaving its cursor at zero on success. Installer trust
/// verification reuses a locked file handle after hashing it.
pub fn sha256OpenFile(file: *std.Io.File) ![Sha256.digest_length]u8 {
    const io = updateIo();
    try seekFileTo(io, file.*, 0);

    var hasher = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const len = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        hasher.update(buf[0..len]);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    try seekFileTo(io, file.*, 0);
    return digest;
}

test "update util parses mixed-case SHA-256 hex and rejects invalid checksums" {
    const testing = std.testing;
    const digest = try parseSha256Hex(comptime win32_repeat.repeat("01aB", 16));
    var expected: [32]u8 = undefined;
    for (&expected, 0..) |*byte, i| byte.* = if (i % 2 == 0) 0x01 else 0xab;
    try testing.expectEqualSlices(u8, &expected, &digest);
    for ([_][]const u8{
        "",
        comptime win32_repeat.repeat("a", 63),
        comptime win32_repeat.repeat("a", 65),
        "g" ++ comptime win32_repeat.repeat("a", 63),
        comptime win32_repeat.repeat("a", 63) ++ "/",
    }) |invalid| {
        try testing.expectError(error.InvalidChecksum, parseSha256Hex(invalid));
    }
}

test "update util portable relative paths replace only backslashes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "share\\ghostty/themes\\MiXeD", .expected = "share/ghostty/themes/MiXeD" },
        .{ .input = "share/../unchanged", .expected = "share/../unchanged" },
        .{ .input = "", .expected = "" },
    };
    for (cases) |case| {
        const result = try portableRelativePathAlloc(alloc, case.input);
        defer alloc.free(result);
        try std.testing.expectEqualStrings(case.expected, result);
    }
}

test "update util hashes whole open file from midfile and resets cursor" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const contents = "portable updater hash fixture";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "payload", .data = contents });

    var file = try tmp.dir.openFile(std.testing.io, "payload", .{});
    defer file.close(std.testing.io);
    try seekFileTo(std.testing.io, file, 7);
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(contents, &expected, .{});
    const actual = try sha256OpenFile(&file);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    // 0.17's `Io.File` has no `getPos`: a read from the file's own cursor
    // returning the file's first bytes shows the cursor is back at zero.
    var head: [7]u8 = undefined;
    try std.testing.expectEqual(@as(usize, head.len), try file.readStreaming(std.testing.io, &.{&head}));
    try std.testing.expectEqualStrings(contents[0..head.len], &head);

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "payload", alloc);
    defer alloc.free(path);
    const from_path = try sha256File(path);
    try std.testing.expectEqualSlices(u8, &expected, &from_path);
}
