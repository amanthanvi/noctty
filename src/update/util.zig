const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

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
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    return sha256OpenFile(&file);
}

/// Hash the whole file, leaving its cursor at zero on success. Installer trust
/// verification reuses a locked file handle after hashing it.
pub fn sha256OpenFile(file: *std.fs.File) ![Sha256.digest_length]u8 {
    try file.seekTo(0);

    var hasher = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const len = try file.read(&buf);
        if (len == 0) break;
        hasher.update(buf[0..len]);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    try file.seekTo(0);
    return digest;
}

test "update util parses mixed-case SHA-256 hex and rejects invalid checksums" {
    const testing = std.testing;
    const digest = try parseSha256Hex("01aB" ** 16);
    try testing.expectEqualSlices(u8, &([_]u8{ 0x01, 0xab } ** 16), &digest);
    for ([_][]const u8{
        "",
        "a" ** 63,
        "a" ** 65,
        "g" ++ "a" ** 63,
        "a" ** 63 ++ "/",
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
    try tmp.dir.writeFile(.{ .sub_path = "payload", .data = contents });

    var file = try tmp.dir.openFile("payload", .{});
    defer file.close();
    try file.seekTo(7);
    var expected: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(contents, &expected, .{});
    const actual = try sha256OpenFile(&file);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expectEqual(@as(u64, 0), try file.getPos());

    const path = try tmp.dir.realpathAlloc(alloc, "payload");
    defer alloc.free(path);
    const from_path = try sha256File(path);
    try std.testing.expectEqualSlices(u8, &expected, &from_path);
}
