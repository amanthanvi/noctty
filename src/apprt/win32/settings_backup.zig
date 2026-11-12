//! Back up every setting into one ZIP: noctty's config and state folders
//! (in portable mode, the data files of the folder beside the executable:
//! the config, the logins under `credentials\`, the session and the rest),
//! plus whatever the caller adds (Settings adds the Terminals export of the
//! profiles, with their passwords). Executables, libraries, symbols and the
//! cache are left out.
//!
//! The ZIP stores each file as it is (no compression), with UTF-8 names.
//! Nothing here logs a path or a file's contents.
const std = @import("std");
const Allocator = std.mem.Allocator;

const xdg = @import("../../os/xdg.zig");

pub const Entry = struct {
    /// The name in the archive, with `/` between folders.
    name: []const u8,
    data: []const u8,
};

/// The largest file the backup takes; a bigger one is left out.
pub const max_file_bytes: usize = 32 * 1024 * 1024;

/// Every data file of noctty's folders, each named `<folder>/<relative
/// path>`, appended to `entries` in `a` (an arena: nothing is freed one by
/// one).
pub fn collect(a: Allocator, entries: *std.ArrayListUnmanaged(Entry)) !void {
    if (try xdg.portableRoot(a)) |root| {
        try walk(a, entries, root, "noctty");
        return;
    }
    const config_dir = try xdg.config(a, .{ .subdir = "noctty" });
    const state_dir = try xdg.state(a, .{ .subdir = "noctty" });
    try walk(a, entries, config_dir, "config");
    if (!std.ascii.eqlIgnoreCase(config_dir, state_dir)) try walk(a, entries, state_dir, "state");
}

/// Whether the file `name` (any case) is program, not data.
fn skipped(name: []const u8) bool {
    const program_exts = [_][]const u8{ ".exe", ".dll", ".com", ".pdb", ".zip", ".ico", ".tmp" };
    for (program_exts) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    const program_files = [_][]const u8{ "LICENSE", "LICENSE-conpty.txt", "README.md", "config-template.ghostty", "noctty.portable", "portable.txt" };
    for (program_files) |file| if (std.ascii.eqlIgnoreCase(name, file)) return true;
    return false;
}

/// Whether the folder `name` holds no settings (bundled resources, the
/// cache, dumps).
fn skippedDir(name: []const u8) bool {
    const dirs = [_][]const u8{ "share", "cache", "crash", "crashes", "dumps", "update", "updates", "ghostty-vt-stub" };
    for (dirs) |dir| if (std.ascii.eqlIgnoreCase(name, dir)) return true;
    return false;
}

fn walk(a: Allocator, entries: *std.ArrayListUnmanaged(Entry), root: []const u8, prefix: []const u8) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    walk: while (try walker.next()) |item| {
        if (item.kind != .file) continue;
        // Under a skipped folder, at any depth.
        var parts = std.mem.tokenizeAny(u8, item.path, "\\/");
        var depth: usize = 0;
        while (parts.next()) |part| : (depth += 1) {
            if (parts.peek() == null) break;
            if (skippedDir(part)) continue :walk;
        }
        if (skipped(item.basename)) continue;
        const data = item.dir.readFileAlloc(a, item.basename, max_file_bytes) catch continue;
        const name = try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, item.path });
        std.mem.replaceScalar(u8, name, '\\', '/');
        try entries.append(a, .{ .name = name, .data = data });
    }
}

/// A ZIP of `entries`, stored (no compression), dated `timestamp` (seconds
/// since the Unix epoch, as local time goes in a ZIP).
pub fn writeZip(writer: *std.Io.Writer, entries: []const Entry, timestamp: i64) !void {
    const dos = dosDateTime(timestamp);
    var offsets: [4096]u32 = undefined;
    if (entries.len > offsets.len) return error.TooManyFiles;
    var offset: u64 = 0;
    for (entries, 0..) |entry, i| {
        if (entry.data.len > std.math.maxInt(u32) or entry.name.len > std.math.maxInt(u16)) return error.FileTooBig;
        offsets[i] = std.math.cast(u32, offset) orelse return error.FileTooBig;
        const crc = std.hash.Crc32.hash(entry.data);
        try writer.writeInt(u32, 0x04034b50, .little);
        try writer.writeInt(u16, 20, .little); // version needed
        try writer.writeInt(u16, 0x0800, .little); // UTF-8 names
        try writer.writeInt(u16, 0, .little); // stored
        try writer.writeInt(u16, dos.time, .little);
        try writer.writeInt(u16, dos.date, .little);
        try writer.writeInt(u32, crc, .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeAll(entry.name);
        try writer.writeAll(entry.data);
        offset += 30 + entry.name.len + entry.data.len;
    }
    const directory_start = std.math.cast(u32, offset) orelse return error.FileTooBig;
    var directory_size: u64 = 0;
    for (entries, 0..) |entry, i| {
        try writer.writeInt(u32, 0x02014b50, .little);
        try writer.writeInt(u16, 20, .little); // made by
        try writer.writeInt(u16, 20, .little); // needed
        try writer.writeInt(u16, 0x0800, .little);
        try writer.writeInt(u16, 0, .little);
        try writer.writeInt(u16, dos.time, .little);
        try writer.writeInt(u16, dos.date, .little);
        try writer.writeInt(u32, std.hash.Crc32.hash(entry.data), .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u32, @intCast(entry.data.len), .little);
        try writer.writeInt(u16, @intCast(entry.name.len), .little);
        try writer.writeInt(u16, 0, .little); // extra
        try writer.writeInt(u16, 0, .little); // comment
        try writer.writeInt(u16, 0, .little); // disk
        try writer.writeInt(u16, 0, .little); // internal attributes
        try writer.writeInt(u32, 0, .little); // external attributes
        try writer.writeInt(u32, offsets[i], .little);
        try writer.writeAll(entry.name);
        directory_size += 46 + entry.name.len;
    }
    try writer.writeInt(u32, 0x06054b50, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, @intCast(entries.len), .little);
    try writer.writeInt(u16, @intCast(entries.len), .little);
    try writer.writeInt(u32, std.math.cast(u32, directory_size) orelse return error.FileTooBig, .little);
    try writer.writeInt(u32, directory_start, .little);
    try writer.writeInt(u16, 0, .little);
}

const DosDateTime = struct { date: u16, time: u16 };

fn dosDateTime(timestamp: i64) DosDateTime {
    const seconds: u64 = @intCast(@max(timestamp, 315532800)); // 1980-01-01, ZIP's first day
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    return .{
        .date = @intCast(((day.year - 1980) << 9) | (@as(u16, month_day.month.numeric()) << 5) | (month_day.day_index + 1)),
        .time = @intCast((@as(u16, clock.getHoursIntoDay()) << 11) | (@as(u16, clock.getMinutesIntoHour()) << 5) | (clock.getSecondsIntoMinute() / 2)),
    };
}

test "settings backup: a stored ZIP lists its files and their bytes" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeZip(&out.writer, &.{
        .{ .name = "noctty/config.ghostty", .data = "font-size = 13\n" },
        .{ .name = "noctty/credentials/coletor-nf.cred", .data = "\x01\x02\x03" },
    }, 1762900000);
    const bytes = out.written();
    try std.testing.expect(std.mem.startsWith(u8, bytes, "PK\x03\x04"));
    // The end record counts both files.
    const end = bytes[bytes.len - 22 ..];
    try std.testing.expectEqual(@as(u32, 0x06054b50), std.mem.readInt(u32, end[0..4], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, end[10..12], .little));
    // Stored: each file's bytes are in the archive as they are.
    try std.testing.expect(std.mem.indexOf(u8, bytes, "font-size = 13\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "noctty/credentials/coletor-nf.cred") != null);
}

test "settings backup: program files and folders are left out" {
    try std.testing.expect(skipped("noctty.exe"));
    try std.testing.expect(skipped("conpty.DLL"));
    try std.testing.expect(skipped("noctty.portable"));
    try std.testing.expect(!skipped("config.ghostty"));
    try std.testing.expect(!skipped("session-state.json"));
    try std.testing.expect(skippedDir("share"));
    try std.testing.expect(!skippedDir("credentials"));
}
