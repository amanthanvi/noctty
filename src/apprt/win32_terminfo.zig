//! Puts noctty's compiled terminfo entries where the ncurses tools of Git for
//! Windows look for them: the `.terminfo` directory under the HOME that
//! git.exe and the MSYS2 runtime give those tools.
//!
//! Without an entry, less (git's pager), vim, nano and tput print
//! `'xterm-ghostty': unknown terminal type.` (#286). Pointing TERMINFO at the
//! entries that ship in `share\terminfo` is not safe. Those tools' ncurses
//! splits TERMINFO on ':', so a `C:\...` value is searched as a directory `C`
//! relative to the current directory, where a cloned repository can supply
//! the entry. A `/proc/cygdrive/c/...` value, which they read as absolute, is
//! resolved by native Windows programs that honor TERMINFO (Neovim, Helix)
//! against the root of the current drive, where another account can create
//! it. The per-user directory adds no lookup path for any other program.
//!
//! The install never replaces a file it did not write. It records the
//! SHA-256 of the entry it installed in `.noctty-installed` beside the
//! entries, so the record travels with them on a roaming or shared home, and
//! updates a file only while that file still holds the recorded entry.
//! Standalone MSYS2 and Cygwin keep HOME in their own `/home` and do not see
//! the entry.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");
const terminfo = @import("../terminfo/main.zig");
const win32_sys = @import("win32/sys.zig");
const log = std.log.scoped(.win32_terminfo);

/// The file, in the database directory, that records the SHA-256 of the
/// entry noctty last installed there.
const record_name = ".noctty-installed";

/// The `.terminfo` directory where Git for Windows' tools look, for the
/// environment `env`, or null where noctty should not install or rely on one.
///
/// When HOME is unset, git.exe sets it to HOMEDRIVE + HOMEPATH if that is a
/// directory and to USERPROFILE otherwise (compat/mingw.c), while the MSYS2
/// runtime, which gives HOME to a tool started directly (PowerShell running
/// less), takes HOMEDRIVE + HOMEPATH without that check. So this returns null
/// where the two can disagree: HOMEDRIVE + HOMEPATH set but not a directory,
/// or only one of them set. It also returns null for a HOME that is not an
/// absolute Windows path, and for a UNC path or mapped network drive: this
/// runs on the UI thread at startup and for every new terminal, and a
/// disconnected home share would block it for a network timeout.
/// `GetDriveTypeW` answers from the local drive table without contacting the
/// server.
pub fn homeTerminfoDir(
    alloc: Allocator,
    env: *const std.process.Environ.Map,
) Allocator.Error!?[]u8 {
    const home = try homeDir(alloc, env) orelse return null;
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{ home, ".terminfo" });
}

fn homeDir(alloc: Allocator, env: *const std.process.Environ.Map) Allocator.Error!?[]u8 {
    // git.exe keeps a HOME that is set even when it is empty, so an empty one
    // gives none rather than the fallbacks below.
    if (env.get("HOME")) |home| return try localAbsolute(alloc, home);

    const drive = getEnv(env, "HOMEDRIVE");
    const path = getEnv(env, "HOMEPATH");
    if (drive != null or path != null) {
        const joined = try std.mem.concat(alloc, u8, &.{ drive orelse return null, path orelse return null });
        if (isAbsolute(joined) and !isRemote(joined) and isDirectory(joined)) return joined;
        alloc.free(joined);
        return null;
    }

    return try localAbsolute(alloc, getEnv(env, "USERPROFILE") orelse return null);
}

fn localAbsolute(alloc: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    if (!isAbsolute(path) or isRemote(path)) return null;
    return try alloc.dupe(u8, path);
}

fn getEnv(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

/// A drive path (`C:\...`) or a UNC path (`\\server\share`). A rooted or
/// drive-relative path depends on the current directory.
fn isAbsolute(path: []const u8) bool {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        isSeparator(path[2])) return true;
    return path.len > 2 and isSeparator(path[0]) and isSeparator(path[1]) and
        !isSeparator(path[2]);
}

/// A UNC path or a drive letter mapped to a network share. This does not see
/// a junction or `subst` alias whose target is remote.
fn isRemote(path: []const u8) bool {
    if (path.len >= 2 and isSeparator(path[0]) and isSeparator(path[1])) return true;
    if (comptime builtin.os.tag != .windows) return false;
    return internal_os.windows_ext.driveTypeForLetter(path[0]) == internal_os.windows_ext.DRIVE_REMOTE;
}

fn isSeparator(c: u8) bool {
    return c == '\\' or c == '/';
}

fn isDirectory(path: []const u8) bool {
    const io = global.io();
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Whether the database in `terminfo_dir` has a compiled entry for `term`
/// (see `terminfo.compiled.isEntry`). An empty, foreign or cut-off file there
/// would leave ncurses without an entry just the same.
pub fn hasEntry(alloc: Allocator, terminfo_dir: []const u8, term: []const u8) bool {
    if (term.len == 0) return false;
    const io = global.io();
    var dir = std.Io.Dir.openDirAbsolute(io, terminfo_dir, .{}) catch return false;
    defer dir.close(io);
    const hex = terminfo.compiled.hexDir(term);
    var sub_dir = dir.openDir(io, &hex, .{}) catch return false;
    defer sub_dir.close(io);
    const data = sub_dir.readFileAlloc(io, term, alloc, .limited(terminfo.compiled.max_entry_size + 1)) catch return false;
    defer alloc.free(data);
    return terminfo.compiled.isEntry(data);
}

pub const InstallResult = enum {
    /// Every file already held the entry.
    current,

    /// At least one file was written.
    installed,

    /// At least one file holds an entry noctty did not write, and was left
    /// alone.
    kept,

    /// Something could not be read or written; see the log.
    failed,
};

/// Install the compiled `source` into the database directory `dir_path`, one
/// file per name (see `terminfo.compiled.fileNames`), without replacing a file
/// noctty did not write. The directory's parent, the home, must exist; only
/// the database directory and its subdirectories are created.
///
/// A file is written when it is missing or when it holds exactly the entry
/// recorded in `.noctty-installed`, as an older noctty left it; any other file
/// that differs is kept. The entry is recorded once noctty's files hold it,
/// and a file that already held it counts as noctty's.
pub fn install(
    alloc: Allocator,
    source: terminfo.Source,
    dir_path: []const u8,
) InstallResult {
    return installFiles(alloc, source, dir_path) catch |err| {
        log.warn("terminfo install failed dir={s} err={}", .{ dir_path, err });
        return .failed;
    };
}

fn installFiles(
    alloc: Allocator,
    source: terminfo.Source,
    dir_path: []const u8,
) !InstallResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try terminfo.compiled.encode(alloc, source, &out.writer);
    const entry = out.written();

    const io = global.io();
    var home = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(dir_path) orelse
        return error.InvalidPath, .{});
    defer home.close(io);
    var dir = try home.createDirPathOpen(io, std.fs.path.basename(dir_path), .{});
    defer dir.close(io);
    const recorded = readRecordedHash(dir);

    var result: InstallResult = .current;
    // Whether any file holds the entry once the loop is done.
    var holding = false;
    for (try terminfo.compiled.fileNames(source)) |name| {
        const hex = terminfo.compiled.hexDir(name);
        var sub_dir = try dir.createDirPathOpen(io, &hex, .{});
        defer sub_dir.close(io);

        const existing = readFileAllocOnce(sub_dir, name, alloc, .limited(64 * 1024 + 1)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (existing) |data| alloc.free(data);
        if (existing) |data| {
            if (std.mem.eql(u8, data, entry)) {
                holding = true;
                continue;
            }
            const ours = if (recorded) |hash| std.mem.eql(u8, &sha256(data), &hash) else false;
            if (!ours) {
                log.info("terminfo install keeping an entry noctty did not write path={s}\\{s}\\{s}", .{
                    dir_path, &hex, name,
                });
                result = .kept;
                continue;
            }
        }

        try writeAtomically(sub_dir, name, entry);
        holding = true;
        if (result == .current) result = .installed;
    }

    // Recorded last, so an install interrupted between files still finds the
    // older entry recorded and updates the rest next time.
    const hash = sha256(entry);
    const unrecorded = if (recorded) |r| !std.mem.eql(u8, &r, &hash) else true;
    if (unrecorded and holding) {
        var line: [hash.len * 2 + 1]u8 = undefined;
        line[0 .. hash.len * 2].* = std.fmt.bytesToHex(hash, .lower);
        line[hash.len * 2] = '\n';
        try writeAtomically(dir, record_name, &line);
    }
    return result;
}

fn sha256(data: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

fn readRecordedHash(dir: std.Io.Dir) ?[32]u8 {
    var buf: [128]u8 = undefined;
    const contents = readFileOnce(dir, record_name, &buf) catch return null;
    const hex = std.mem.trim(u8, contents, &std.ascii.whitespace);
    var hash: [32]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&hash, hex) catch return null;
    if (decoded.len != hash.len) return null;
    return hash;
}

/// `dir.readFileAlloc` with one attempt at the open (`win32_sys.dirOpenFileOnce`;
/// re-check item 34): the install runs on the UI thread at start, and a file
/// another program holds without sharing reads, or one left pending delete, is
/// `FileBusy` at once, where std 0.17 would wait about four seconds first. The
/// install fails and the next start tries again.
fn readFileAllocOnce(dir: std.Io.Dir, name: []const u8, alloc: Allocator, limit: std.Io.Limit) ![]u8 {
    const io = global.io();
    const file = try win32_sys.dirOpenFileOnce(dir, name, .{ .allow_directory = false });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(alloc, limit) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        error.OutOfMemory, error.StreamTooLong => |e| return e,
    };
}

/// `dir.readFile` with one attempt at the open, as `readFileAllocOnce`.
fn readFileOnce(dir: std.Io.Dir, name: []const u8, buffer: []u8) ![]u8 {
    const io = global.io();
    const file = try win32_sys.dirOpenFileOnce(dir, name, .{ .allow_directory = false });
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(buffer) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
    return buffer[0..n];
}

/// Write through a temporary file and a rename, so a reader never sees a
/// partial file. The temporary name is random and created exclusively, so
/// two noctty processes never write into the same one, and an existing file
/// or link of that name is never followed.
pub fn writeAtomically(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    const io = global.io();
    var random: [8]u8 = undefined;
    io.random(&random);
    const random_hex = std.fmt.bytesToHex(random, .lower);
    var tmp_buf: [std.fs.max_name_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.{s}.tmp", .{ name, &random_hex });

    const file = try dir.createFile(io, tmp, .{ .exclusive = true });
    file.writeStreamingAll(io, data) catch |err| {
        file.close(io);
        dir.deleteFile(io, tmp) catch {};
        return err;
    };
    file.close(io);
    dir.rename(tmp, dir, name, io) catch |err| {
        dir.deleteFile(io, tmp) catch {};
        return err;
    };
}

const testing = std.testing;

const test_source: terminfo.Source = .{
    .names = &.{ "xterm-test", "test", "Test Terminal" },
    .capabilities = &.{
        .{ .name = "am", .value = .{ .boolean = {} } },
        .{ .name = "colors", .value = .{ .numeric = 256 } },
    },
};

const TestPaths = struct {
    tmp: testing.TmpDir,
    root: [:0]u8,
    db: []u8,

    fn init() !TestPaths {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        const db = try std.fs.path.join(testing.allocator, &.{ root, ".terminfo" });
        return .{ .tmp = tmp, .root = root, .db = db };
    }

    fn deinit(self: *TestPaths) void {
        testing.allocator.free(self.db);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn read(self: *TestPaths, path: []const u8) ![]u8 {
        var dir = try std.Io.Dir.openDirAbsolute(testing.io, self.db, .{});
        defer dir.close(testing.io);
        return dir.readFileAlloc(testing.io, path, testing.allocator, .limited(64 * 1024));
    }

    fn put(self: *TestPaths, path: []const u8, data: []const u8) !void {
        var dir = try std.Io.Dir.cwd().createDirPathOpen(testing.io, self.db, .{});
        defer dir.close(testing.io);
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(testing.io, parent);
        try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn recorded(self: *TestPaths) ?[32]u8 {
        var dir = std.Io.Dir.openDirAbsolute(testing.io, self.db, .{}) catch return null;
        defer dir.close(testing.io);
        return readRecordedHash(dir);
    }

    fn record(self: *TestPaths, data: []const u8) !void {
        const hex = std.fmt.bytesToHex(sha256(data), .lower);
        try self.put(record_name, &hex);
    }
};

fn testEntry(source: terminfo.Source) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try terminfo.compiled.encode(testing.allocator, source, &out.writer);
    return testing.allocator.dupe(u8, out.written());
}

test "install writes every name and then finds them current" {
    var paths: TestPaths = try .init();
    defer paths.deinit();
    const entry = try testEntry(test_source);
    defer testing.allocator.free(entry);

    try testing.expectEqual(.installed, install(testing.allocator, test_source, paths.db));
    for ([_][]const u8{ "78/xterm-test", "74/test" }) |path| {
        const data = try paths.read(path);
        defer testing.allocator.free(data);
        try testing.expectEqualSlices(u8, entry, data);
    }
    try testing.expectEqual(sha256(entry), paths.recorded().?);
    try testing.expect(hasEntry(testing.allocator, paths.db, "xterm-test"));
    try testing.expect(hasEntry(testing.allocator, paths.db, "test"));
    try testing.expect(!hasEntry(testing.allocator, paths.db, "Test Terminal"));

    try testing.expectEqual(.current, install(testing.allocator, test_source, paths.db));

    // No temporary file is left behind.
    var dir = try std.Io.Dir.openDirAbsolute(testing.io, paths.db, .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    while (try it.next(testing.io)) |item| try testing.expect(!std.mem.endsWith(u8, item.name, ".tmp"));
}

test "install updates a file it wrote and keeps one it did not" {
    var paths: TestPaths = try .init();
    defer paths.deinit();
    const entry = try testEntry(test_source);
    defer testing.allocator.free(entry);

    // An older noctty wrote "old" into both files and recorded it.
    const old = "old entry";
    try paths.put("78/xterm-test", old);
    try paths.put("74/test", old);
    try paths.record(old);

    // Since then the user replaced one of them.
    try paths.put("74/test", "the user's entry");

    try testing.expectEqual(.kept, install(testing.allocator, test_source, paths.db));
    const updated = try paths.read("78/xterm-test");
    defer testing.allocator.free(updated);
    try testing.expectEqualSlices(u8, entry, updated);
    const kept = try paths.read("74/test");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("the user's entry", kept);
    try testing.expectEqual(sha256(entry), paths.recorded().?);
}

test "install keeps entries that were there before it ever wrote one" {
    var paths: TestPaths = try .init();
    defer paths.deinit();

    try paths.put("78/xterm-test", "the user's entry");
    try testing.expectEqual(.kept, install(testing.allocator, test_source, paths.db));
    const kept = try paths.read("78/xterm-test");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("the user's entry", kept);

    // The missing one was written.
    try testing.expect(hasEntry(testing.allocator, paths.db, "test"));
}

test "install counts a file that already holds the entry as its own" {
    var paths: TestPaths = try .init();
    defer paths.deinit();
    const entry = try testEntry(test_source);
    defer testing.allocator.free(entry);

    // Copied by hand from share\terminfo, next to an entry of the user's.
    try paths.put("78/xterm-test", entry);
    try paths.put("74/test", "the user's entry");
    try testing.expectEqual(.kept, install(testing.allocator, test_source, paths.db));
    try testing.expectEqual(sha256(entry), paths.recorded().?);

    // A later version updates the copy and still keeps the user's entry.
    const next: terminfo.Source = .{
        .names = test_source.names,
        .capabilities = &.{.{ .name = "am", .value = .{ .boolean = {} } }},
    };
    try testing.expectEqual(.kept, install(testing.allocator, next, paths.db));
    const next_entry = try testEntry(next);
    defer testing.allocator.free(next_entry);
    const updated = try paths.read("78/xterm-test");
    defer testing.allocator.free(updated);
    try testing.expectEqualSlices(u8, next_entry, updated);
    const kept = try paths.read("74/test");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("the user's entry", kept);
}

test "held file: install fails at once on an entry another handle holds (re-check item 34)" {
    // The install runs on the UI thread at start: an entry that cannot be
    // read now fails it at once, and the next start installs.
    for ([_]win32_sys.HeldFile.Kind{ .deny_read, .delete_pending }) |kind| {
        var paths: TestPaths = try .init();
        defer paths.deinit();
        try paths.put("78/xterm-test", "old entry");
        try paths.record("old entry");
        const entry_path = try std.fs.path.join(testing.allocator, &.{ paths.db, "78", "xterm-test" });
        defer testing.allocator.free(entry_path);
        {
            const held = try win32_sys.HeldFile.hold(entry_path, kind);
            defer held.release();
            const start = win32_sys.HeldFile.now();
            try testing.expectEqual(.failed, install(testing.allocator, test_source, paths.db));
            const ms = win32_sys.HeldFile.msSince(start);
            std.debug.print("held file: terminfo install against {t}: failed after {d} ms\n", .{ kind, ms });
            try testing.expect(ms < win32_sys.HeldFile.once_bound_ms);
        }
        try testing.expect(install(testing.allocator, test_source, paths.db) != .failed);
        try testing.expect(hasEntry(testing.allocator, paths.db, "xterm-test"));
    }
}

test "install does not create a missing home" {
    var paths: TestPaths = try .init();
    defer paths.deinit();

    const db = try std.fs.path.join(testing.allocator, &.{ paths.root, "no", "such", "home", ".terminfo" });
    defer testing.allocator.free(db);
    try testing.expectEqual(.failed, install(testing.allocator, test_source, db));
    try testing.expectError(error.FileNotFound, paths.tmp.dir.access(testing.io, "no", .{}));
}

test "install reports a failure instead of returning an error" {
    var paths: TestPaths = try .init();
    defer paths.deinit();

    // A file where the database directory should be.
    try paths.tmp.dir.writeFile(testing.io, .{ .sub_path = ".terminfo", .data = "" });
    try testing.expectEqual(.failed, install(testing.allocator, test_source, paths.db));
}

test "hasEntry wants a compiled entry" {
    var paths: TestPaths = try .init();
    defer paths.deinit();

    try paths.put("78/xterm-test", "");
    try testing.expect(!hasEntry(testing.allocator, paths.db, "xterm-test"));
    try paths.put("78/xterm-test", "not a terminfo entry at all");
    try testing.expect(!hasEntry(testing.allocator, paths.db, "xterm-test"));

    const entry = try testEntry(test_source);
    defer testing.allocator.free(entry);
    try paths.put("78/xterm-test", entry[0 .. entry.len - 1]);
    try testing.expect(!hasEntry(testing.allocator, paths.db, "xterm-test"));
    try paths.put("78/xterm-test", entry);
    try testing.expect(hasEntry(testing.allocator, paths.db, "xterm-test"));
    try testing.expect(!hasEntry(testing.allocator, paths.db, "xterm-other"));
}

test "homeTerminfoDir follows where Git's tools look" {
    // Windows paths, and drive types only Windows can report.
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var paths: TestPaths = try .init();
    defer paths.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();

    // Nothing usable.
    try testing.expectEqual(null, try homeTerminfoDir(testing.allocator, &env));

    try env.put("USERPROFILE", "C:\\Users\\me");
    {
        const dir = (try homeTerminfoDir(testing.allocator, &env)).?;
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("C:\\Users\\me\\.terminfo", dir);
    }

    // HOMEDRIVE + HOMEPATH wins when it is a directory.
    try env.put("HOMEDRIVE", paths.root[0..2]);
    try env.put("HOMEPATH", paths.root[2..]);
    {
        const dir = (try homeTerminfoDir(testing.allocator, &env)).?;
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings(paths.db, dir);
    }

    // Where git.exe and the MSYS2 runtime would disagree, there is none.
    try env.put("HOMEPATH", "\\does\\not\\exist");
    try testing.expectEqual(null, try homeTerminfoDir(testing.allocator, &env));
    _ = env.swapRemove("HOMEDRIVE");
    try testing.expectEqual(null, try homeTerminfoDir(testing.allocator, &env));

    // HOME wins over all of them; one Git's tools cannot use, or a remote
    // one, gives none.
    try env.put("HOME", "D:\\home");
    {
        const dir = (try homeTerminfoDir(testing.allocator, &env)).?;
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("D:\\home\\.terminfo", dir);
    }
    try env.put("HOME", "/c/Users/me");
    try testing.expectEqual(null, try homeTerminfoDir(testing.allocator, &env));
    try env.put("HOME", "\\\\server\\homes\\me");
    try testing.expectEqual(null, try homeTerminfoDir(testing.allocator, &env));

    // git.exe keeps an empty HOME rather than looking further.
    try env.put("HOME", "");
    try env.put("HOMEDRIVE", paths.root[0..2]);
    try env.put("HOMEPATH", paths.root[2..]);
    try testing.expectEqual(null, try homeTerminfoDir(testing.allocator, &env));
}

test "isAbsolute" {
    try testing.expect(isAbsolute("C:\\Users\\a"));
    try testing.expect(isAbsolute("c:/Users/a"));
    try testing.expect(isAbsolute("\\\\server\\home\\a"));
    try testing.expect(!isAbsolute("\\Users\\a"));
    try testing.expect(!isAbsolute("C:Users"));
    try testing.expect(!isAbsolute("/c/Users/a"));
    try testing.expect(!isAbsolute("~"));
}
