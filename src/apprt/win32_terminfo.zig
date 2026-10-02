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
//! it. The per-user directory is searched by those tools from every drive and
//! adds no lookup path for any other program.
//!
//! The install never replaces a file it did not write. It records the
//! SHA-256 of the entry it wrote and updates a file only while that file
//! still holds those bytes. Standalone MSYS2 and Cygwin keep HOME in their
//! own `/home` and do not see the entry.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminfo = @import("../terminfo/main.zig");
const log = std.log.scoped(.win32_terminfo);

/// The `.terminfo` directory under the HOME Git for Windows gives its tools,
/// for the environment `env`. When HOME is unset, git.exe sets it to
/// HOMEDRIVE + HOMEPATH if that is a directory and to USERPROFILE otherwise
/// (compat/mingw.c). Returns null when that HOME is not an absolute Windows
/// path: Git's tools would not find a file under it either.
pub fn homeTerminfoDir(
    alloc: Allocator,
    env: *const std.process.EnvMap,
) Allocator.Error!?[]u8 {
    const home = try homeDir(alloc, env) orelse return null;
    defer alloc.free(home);
    return try std.fs.path.join(alloc, &.{ home, ".terminfo" });
}

fn homeDir(alloc: Allocator, env: *const std.process.EnvMap) Allocator.Error!?[]u8 {
    if (getEnv(env, "HOME")) |home| {
        return if (isAbsolute(home)) try alloc.dupe(u8, home) else null;
    }

    if (getEnv(env, "HOMEDRIVE")) |drive| {
        if (getEnv(env, "HOMEPATH")) |path| {
            const joined = try std.mem.concat(alloc, u8, &.{ drive, path });
            if (isAbsolute(joined) and isDirectory(joined)) return joined;
            alloc.free(joined);
        }
    }

    const profile = getEnv(env, "USERPROFILE") orelse return null;
    return if (isAbsolute(profile)) try alloc.dupe(u8, profile) else null;
}

fn getEnv(env: *const std.process.EnvMap, key: []const u8) ?[]const u8 {
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

fn isSeparator(c: u8) bool {
    return c == '\\' or c == '/';
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Whether the database in `terminfo_dir` has a compiled entry for `term`: a
/// file that starts with a terminfo header. An empty or foreign file there
/// would leave ncurses without an entry just the same.
pub fn hasEntry(terminfo_dir: []const u8, term: []const u8) bool {
    if (term.len == 0) return false;
    var dir = std.fs.openDirAbsolute(terminfo_dir, .{}) catch return false;
    defer dir.close();
    const hex = terminfo.compiled.hexDir(term);
    var sub_dir = dir.openDir(&hex, .{}) catch return false;
    defer sub_dir.close();
    const file = sub_dir.openFile(term, .{}) catch return false;
    defer file.close();
    var header: [terminfo.compiled.header_size]u8 = undefined;
    const len = file.readAll(&header) catch return false;
    return terminfo.compiled.isHeader(header[0..len]);
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

/// Install the compiled `source` into the database directory `dir_path`,
/// one file per name (see `terminfo.compiled.fileNames`), without replacing a
/// file noctty did not write. `state_path` records the SHA-256 of the entry
/// noctty last installed. A file is written when it is missing or when it
/// holds exactly the recorded entry, as an older noctty left it; any other
/// file that differs is kept. The entry is recorded once noctty's files hold
/// it, and a file that already held it counts as noctty's.
pub fn install(
    alloc: Allocator,
    source: terminfo.Source,
    dir_path: []const u8,
    state_path: []const u8,
) InstallResult {
    return installFiles(alloc, source, dir_path, state_path) catch |err| {
        log.warn("terminfo install failed dir={s} err={}", .{ dir_path, err });
        return .failed;
    };
}

fn installFiles(
    alloc: Allocator,
    source: terminfo.Source,
    dir_path: []const u8,
    state_path: []const u8,
) !InstallResult {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try terminfo.compiled.encode(alloc, source, &out.writer);
    const entry = out.written();
    const recorded = readRecordedHash(state_path);

    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
    defer dir.close();

    var result: InstallResult = .current;
    // Whether any file holds the entry once the loop is done.
    var holding = false;
    for (try terminfo.compiled.fileNames(source)) |name| {
        const hex = terminfo.compiled.hexDir(name);
        var sub_dir = try dir.makeOpenPath(&hex, .{});
        defer sub_dir.close();

        const existing = sub_dir.readFileAlloc(alloc, name, 64 * 1024) catch |err| switch (err) {
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
    if (unrecorded and holding) try writeRecordedHash(state_path, hash);
    return result;
}

fn sha256(data: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

fn readRecordedHash(state_path: []const u8) ?[32]u8 {
    var buf: [128]u8 = undefined;
    const contents = std.fs.cwd().readFile(state_path, &buf) catch return null;
    const hex = std.mem.trim(u8, contents, &std.ascii.whitespace);
    var hash: [32]u8 = undefined;
    const decoded = std.fmt.hexToBytes(&hash, hex) catch return null;
    if (decoded.len != hash.len) return null;
    return hash;
}

fn writeRecordedHash(state_path: []const u8, hash: [32]u8) !void {
    if (std.fs.path.dirname(state_path)) |parent| try std.fs.cwd().makePath(parent);
    var line: [hash.len * 2 + 1]u8 = undefined;
    line[0 .. hash.len * 2].* = std.fmt.bytesToHex(hash, .lower);
    line[hash.len * 2] = '\n';
    try std.fs.cwd().writeFile(.{ .sub_path = state_path, .data = &line });
}

/// Write through a temporary file and a rename, so a reader never sees a
/// partial entry.
fn writeAtomically(dir: std.fs.Dir, name: []const u8, data: []const u8) !void {
    var tmp_buf: [std.fs.max_name_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.noctty.tmp", .{name});
    errdefer dir.deleteFile(tmp) catch {};
    try dir.writeFile(.{ .sub_path = tmp, .data = data });
    try dir.rename(tmp, name);
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
    root: []u8,
    db: []u8,
    state: []u8,

    fn init() !TestPaths {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
        errdefer testing.allocator.free(root);
        const db = try std.fs.path.join(testing.allocator, &.{ root, ".terminfo" });
        errdefer testing.allocator.free(db);
        const state = try std.fs.path.join(testing.allocator, &.{ root, "state", "terminfo-install.sha256" });
        return .{ .tmp = tmp, .root = root, .db = db, .state = state };
    }

    fn deinit(self: *TestPaths) void {
        testing.allocator.free(self.state);
        testing.allocator.free(self.db);
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn read(self: *TestPaths, path: []const u8) ![]u8 {
        var dir = try std.fs.openDirAbsolute(self.db, .{});
        defer dir.close();
        return dir.readFileAlloc(testing.allocator, path, 64 * 1024);
    }

    fn put(self: *TestPaths, path: []const u8, data: []const u8) !void {
        var dir = try std.fs.cwd().makeOpenPath(self.db, .{});
        defer dir.close();
        if (std.fs.path.dirname(path)) |parent| try dir.makePath(parent);
        try dir.writeFile(.{ .sub_path = path, .data = data });
    }
};

fn testEntry() ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try terminfo.compiled.encode(testing.allocator, test_source, &out.writer);
    return testing.allocator.dupe(u8, out.written());
}

test "install writes every name and then finds them current" {
    var paths: TestPaths = try .init();
    defer paths.deinit();
    const entry = try testEntry();
    defer testing.allocator.free(entry);

    try testing.expectEqual(.installed, install(testing.allocator, test_source, paths.db, paths.state));
    for ([_][]const u8{ "78/xterm-test", "74/test" }) |path| {
        const data = try paths.read(path);
        defer testing.allocator.free(data);
        try testing.expectEqualSlices(u8, entry, data);
    }
    try testing.expectEqual(sha256(entry), readRecordedHash(paths.state).?);
    try testing.expect(hasEntry(paths.db, "xterm-test"));
    try testing.expect(hasEntry(paths.db, "test"));
    try testing.expect(!hasEntry(paths.db, "Test Terminal"));

    try testing.expectEqual(.current, install(testing.allocator, test_source, paths.db, paths.state));
}

test "install updates a file it wrote and keeps one it did not" {
    var paths: TestPaths = try .init();
    defer paths.deinit();
    const entry = try testEntry();
    defer testing.allocator.free(entry);

    // An older noctty wrote "old" into both files and recorded it.
    const old = "old entry";
    try paths.put("78/xterm-test", old);
    try paths.put("74/test", old);
    try writeRecordedHash(paths.state, sha256(old));

    // Since then the user replaced one of them.
    try paths.put("74/test", "the user's entry");

    try testing.expectEqual(.kept, install(testing.allocator, test_source, paths.db, paths.state));
    const updated = try paths.read("78/xterm-test");
    defer testing.allocator.free(updated);
    try testing.expectEqualSlices(u8, entry, updated);
    const kept = try paths.read("74/test");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("the user's entry", kept);
    try testing.expectEqual(sha256(entry), readRecordedHash(paths.state).?);
}

test "install keeps entries that were there before it ever wrote one" {
    var paths: TestPaths = try .init();
    defer paths.deinit();

    try paths.put("78/xterm-test", "the user's entry");
    try testing.expectEqual(.kept, install(testing.allocator, test_source, paths.db, paths.state));
    const kept = try paths.read("78/xterm-test");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("the user's entry", kept);

    // The missing one was written.
    try testing.expect(hasEntry(paths.db, "test"));
}

test "install counts a file that already holds the entry as its own" {
    var paths: TestPaths = try .init();
    defer paths.deinit();
    const entry = try testEntry();
    defer testing.allocator.free(entry);

    // Copied by hand from share\terminfo, next to an entry of the user's.
    try paths.put("78/xterm-test", entry);
    try paths.put("74/test", "the user's entry");
    try testing.expectEqual(.kept, install(testing.allocator, test_source, paths.db, paths.state));
    try testing.expectEqual(sha256(entry), readRecordedHash(paths.state).?);

    // A later version updates the copy and still keeps the user's entry.
    const next: terminfo.Source = .{
        .names = test_source.names,
        .capabilities = &.{.{ .name = "am", .value = .{ .boolean = {} } }},
    };
    try testing.expectEqual(.kept, install(testing.allocator, next, paths.db, paths.state));
    const updated = try paths.read("78/xterm-test");
    defer testing.allocator.free(updated);
    try testing.expect(!std.mem.eql(u8, entry, updated));
    const kept = try paths.read("74/test");
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("the user's entry", kept);
}

test "install reports a failure instead of returning an error" {
    var paths: TestPaths = try .init();
    defer paths.deinit();

    // A file where the database directory should be.
    try paths.tmp.dir.writeFile(.{ .sub_path = ".terminfo", .data = "" });
    try testing.expectEqual(.failed, install(testing.allocator, test_source, paths.db, paths.state));
}

test "hasEntry wants a compiled entry" {
    var paths: TestPaths = try .init();
    defer paths.deinit();

    try paths.put("78/xterm-test", "");
    try testing.expect(!hasEntry(paths.db, "xterm-test"));
    try paths.put("78/xterm-test", "not a terminfo entry at all");
    try testing.expect(!hasEntry(paths.db, "xterm-test"));

    const entry = try testEntry();
    defer testing.allocator.free(entry);
    try paths.put("78/xterm-test", entry);
    try testing.expect(hasEntry(paths.db, "xterm-test"));
    try testing.expect(!hasEntry(paths.db, "xterm-other"));
}

test "homeTerminfoDir follows git.exe's HOME" {
    var paths: TestPaths = try .init();
    defer paths.deinit();
    var env: std.process.EnvMap = .init(testing.allocator);
    defer env.deinit();

    // Nothing usable.
    try testing.expectEqual(null, try homeTerminfoDir(testing.allocator, &env));

    try env.put("USERPROFILE", "C:\\Users\\me");
    {
        const dir = (try homeTerminfoDir(testing.allocator, &env)).?;
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("C:\\Users\\me\\.terminfo", dir);
    }

    // HOMEDRIVE + HOMEPATH wins when it is a directory, as on a home share.
    try env.put("HOMEDRIVE", paths.root[0..2]);
    try env.put("HOMEPATH", paths.root[2..]);
    {
        const dir = (try homeTerminfoDir(testing.allocator, &env)).?;
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings(paths.db, dir);
    }
    try env.put("HOMEPATH", "\\does\\not\\exist");
    {
        const dir = (try homeTerminfoDir(testing.allocator, &env)).?;
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("C:\\Users\\me\\.terminfo", dir);
    }

    // HOME wins over both, and one Git's tools cannot use gives nothing.
    try env.put("HOME", "D:\\home");
    {
        const dir = (try homeTerminfoDir(testing.allocator, &env)).?;
        defer testing.allocator.free(dir);
        try testing.expectEqualStrings("D:\\home\\.terminfo", dir);
    }
    try env.put("HOME", "/c/Users/me");
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
