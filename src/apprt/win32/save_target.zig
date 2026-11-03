//! Where a Settings save lands, and how the bytes get there.
//!
//! The configured path can be a symbolic link (a config kept in a dotfiles
//! repository) or one of several hard links to the same file. Replacing that
//! name with a new file swaps a symbolic link for a plain file and leaves every
//! other hard link on the old bytes, so the save followed the link only until
//! the first time. `resolve` finds the file the name reaches, `write` puts the
//! bytes there.
const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;
const sys = @import("sys.zig");
const c = @import("consts.zig");

const log = std.log.scoped(.save_target);

extern "kernel32" fn GetFileInformationByHandle(
    handle: windows.HANDLE,
    info: *windows.BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) windows.BOOL;

pub const Target = struct {
    /// The file the configured name reaches now, as `C:\...` or
    /// `\\server\share\...`, or the name itself while no file exists yet.
    /// Owned.
    path: []u8,
    /// Another name reaches the same file, so only writing into the file keeps
    /// the names together.
    hard_linked: bool = false,

    pub fn deinit(self: Target, alloc: Allocator) void {
        alloc.free(self.path);
    }
};

pub const ResolveError = error{
    /// The name is a link whose target is missing. Writing "to" it would
    /// replace the link, which is what resolving exists to avoid.
    DanglingLink,
} || Allocator.Error;

pub const WriteError = error{
    TempCreateFailed,
    SerializeFailed,
    ReplaceFailed,
    /// The in-place rewrite failed after its first byte: the file may hold new
    /// bytes followed by old ones, and the complete text is in the kept copy.
    IncompleteWrite,
    /// The file no longer holds what the caller read (`writeOver`), so another
    /// program edited it since: nothing was written.
    Changed,
} || Allocator.Error;

pub const ReadError = error{
    ReadFailed,
    /// Larger than any config file a save reads (`max_bytes`).
    TooLarge,
    /// The file's size changed while it was read: another program is
    /// writing it, and what was read is not what it holds.
    Unstable,
} || Allocator.Error;

/// The most bytes a save reads of a config file.
pub const max_bytes = 16 * 1024 * 1024;

/// What a save read of a file, to tell whether it still holds that: the
/// SHA-256 of its bytes.
pub const Digest = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub fn digestOf(bytes: []const u8) Digest {
    var out: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

/// The bytes of the file at `path` (a `Target.path`) as a save reads them: a
/// file that is not there reads as empty. Owned. Read to its end (within
/// `max_bytes`), not to the size a stat gave: bytes another program appends
/// meanwhile are read too. A size that differs before, during and after the
/// read is `Unstable`.
pub fn read(alloc: Allocator, path: []const u8) ReadError![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return alloc.dupe(u8, ""),
        else => return error.ReadFailed,
    };
    defer file.close();
    const before = file.stat() catch return error.ReadFailed;
    if (before.size > max_bytes) return error.TooLarge;
    if (@import("builtin").is_test) if (test_during_read) |hook| hook();
    const bytes = file.readToEndAlloc(alloc, max_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileTooBig => return error.TooLarge,
        else => return error.ReadFailed,
    };
    errdefer alloc.free(bytes);
    const after = file.stat() catch return error.ReadFailed;
    if (before.size != bytes.len or after.size != bytes.len) return error.Unstable;
    return bytes;
}

/// The digest of what the file the configured `path` reaches holds now, as a
/// save would read it.
pub fn digestNow(alloc: Allocator, path: []const u8) (ReadError || ResolveError)!Digest {
    const target = try resolve(alloc, path);
    defer target.deinit(alloc);
    const bytes = try read(alloc, target.path);
    defer alloc.free(bytes);
    return digestOf(bytes);
}

/// A test's stand-in for another program: run by `writeOver` just before it
/// compares the file with what was read (SETTINGS-SAVE-TOCTOU).
pub threadlocal var test_before_compare: if (@import("builtin").is_test) ?*const fn () void else void =
    if (@import("builtin").is_test) null else {};

/// The same, run by `read` between its first stat and the read.
pub threadlocal var test_during_read: if (@import("builtin").is_test) ?*const fn () void else void =
    if (@import("builtin").is_test) null else {};

/// Follow `path` to the file it names. A name with no file behind it is the
/// first save and resolves to itself. What cannot be learned (a volume that
/// does not answer the final-path query, a name that is not valid text) leaves
/// the name as it was: the read and the write that follow report the real
/// problem, as they did before links were followed.
pub fn resolve(alloc: Allocator, path: []const u8) ResolveError!Target {
    const wide = windows.sliceToPrefixedFileW(null, path) catch return named(alloc, path);
    // No access is asked for, so a read-only or busy file still opens; the
    // handle only answers questions about the file.
    const handle = windows.kernel32.CreateFileW(
        wide.span().ptr,
        0,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND => {
            // The open follows a link and fails on a missing target, so it
            // cannot tell a first save from a dangling link; the attributes of
            // the name itself can.
            const attributes = windows.kernel32.GetFileAttributesW(wide.span().ptr);
            if (attributes != windows.INVALID_FILE_ATTRIBUTES and
                attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) return error.DanglingLink;
            return named(alloc, path);
        },
        else => return named(alloc, path),
    };
    defer windows.CloseHandle(handle);

    var info: windows.BY_HANDLE_FILE_INFORMATION = undefined;
    const hard_linked = GetFileInformationByHandle(handle, &info) != 0 and info.nNumberOfLinks > 1;
    const final = finalPath(alloc, handle) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unresolved => return .{ .path = try alloc.dupe(u8, path), .hard_linked = hard_linked },
    };
    return .{ .path = final, .hard_linked = hard_linked };
}

fn named(alloc: Allocator, path: []const u8) Allocator.Error!Target {
    return .{ .path = try alloc.dupe(u8, path) };
}

/// The path of the file `handle` is open on, as `plain` writes it. Owned.
fn finalPath(alloc: Allocator, handle: windows.HANDLE) error{ OutOfMemory, Unresolved }![]u8 {
    var storage = try alloc.alloc(u16, 512);
    defer alloc.free(storage);
    const final = while (true) {
        // Success is the length without the terminator; a buffer that is too
        // small gets the length it needs, terminator included.
        const length = sys.GetFinalPathNameByHandleW(handle, storage.ptr, @intCast(storage.len), 0);
        if (length == 0) return error.Unresolved;
        if (length < storage.len) break storage[0..length];
        storage = try alloc.realloc(storage, length);
    };
    const name = std.unicode.utf16LeToUtf8Alloc(alloc, final) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unresolved, // A name with a lone surrogate is not text the program can pass on.
    };
    defer alloc.free(name);
    return alloc.dupe(u8, plain(name));
}

/// The final-path API answers in the `\\?\` namespace; every other path in the
/// program is `C:\...` or `\\server\share\...`. Names that are neither (a
/// volume with no drive letter) stay as they are, which the file APIs accept.
/// So does a name that only the extended form reaches: one too long for the
/// plain form (the replace calls take the path as written, and without a
/// long-path manifest only the extended form lets them past MAX_PATH), or one
/// that Win32 name normalization would turn into another file. Edits `name` in
/// place.
fn plain(name: []u8) []u8 {
    const unc = "\\\\?\\UNC\\";
    const extended = "\\\\?\\";
    // Room for the temporary file's suffix under MAX_PATH (260).
    const max_plain = 230;
    if (name.len - @min(name.len, extended.len) > max_plain) return name;
    if (std.mem.startsWith(u8, name, unc)) {
        if (!survivesNormalization(name[unc.len..])) return name;
        // \\?\UNC\server\share is \\server\share: the "C\" of the prefix
        // becomes the second separator.
        name[unc.len - 2] = '\\';
        return name[unc.len - 2 ..];
    }
    if (name.len >= extended.len + 3 and std.mem.startsWith(u8, name, extended) and
        std.ascii.isAlphabetic(name[extended.len]) and
        name[extended.len + 1] == ':' and name[extended.len + 2] == '\\')
    {
        if (!survivesNormalization(name[extended.len + 3 ..])) return name;
        return name[extended.len..];
    }
    return name;
}

/// Whether `path` (the part after the root) names the same file without the
/// extended prefix. Normalization drops trailing dots and spaces from a
/// component, so `config.` would reach `config`, and reads CON, NUL, COM1 and
/// the like as devices, so a file called that is reachable only through the
/// prefix.
fn survivesNormalization(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '\\');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        if (isDeviceName(part)) return false;
    }
    return true;
}

fn isDeviceName(component: []const u8) bool {
    // A device name is the stem before the first dot, whatever follows, and
    // trailing spaces do not count.
    const stem = std.mem.trimRight(u8, component[0 .. std.mem.indexOfScalar(u8, component, '.') orelse component.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    return stem.len == 4 and stem[3] >= '1' and stem[3] <= '9' and
        (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT"));
}

/// Make the file at `target` hold exactly `bytes`.
///
/// The bytes go to a synced temporary file beside it first. A name with one
/// link is then replaced atomically, so a crash never leaves a half-written
/// config; a hard-linked file is rewritten in place, because a replacement
/// would leave the other names on the old bytes. That rewrite is not atomic:
/// the temporary file stays if it fails, as the only complete copy, and
/// `kept_copy` (when given) receives its path: owned by the caller.
pub fn write(alloc: Allocator, target: Target, bytes: []const u8, kept_copy: ?*?[]u8) WriteError!void {
    return writeOver(alloc, target, bytes, kept_copy, null);
}

/// `write`, when the file still holds what was read of it as `read_as`. That
/// is compared once the new bytes are safely in the temporary file, just
/// before they take the file's place, so an edit another program made before
/// that last read is not written over: then nothing is written (`Changed`).
/// One made after it, before the replace, still is. A file that cannot be
/// read at that moment is not written either.
pub fn writeOver(alloc: Allocator, target: Target, bytes: []const u8, kept_copy: ?*?[]u8, read_as: ?Digest) WriteError!void {
    const tmp_path = try std.fmt.allocPrint(
        alloc,
        "{s}.tmp-{x}-{x}",
        .{ target.path, sys.GetCurrentProcessId(), @as(u64, @intCast(@max(std.time.milliTimestamp(), 0))) },
    );
    defer alloc.free(tmp_path);

    // Closed before the replace: Windows blocks it while the temp handle is open.
    var temp_pending = false;
    defer if (temp_pending) std.fs.cwd().deleteFile(tmp_path) catch {}; // Best-effort temp cleanup.
    {
        const tmp = std.fs.cwd().createFile(tmp_path, .{}) catch return error.TempCreateFailed;
        temp_pending = true;
        defer tmp.close();
        var write_buf: [4096]u8 = undefined;
        var fw = tmp.writer(&write_buf);
        fw.interface.writeAll(bytes) catch return error.SerializeFailed;
        fw.interface.flush() catch return error.SerializeFailed;
        tmp.sync() catch return error.SerializeFailed;
    }

    if (read_as) |digest| {
        if (@import("builtin").is_test) if (test_before_compare) |hook| hook();
        const now = read(alloc, target.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Being written as it was read: changed.
            error.Unstable => return error.Changed,
            else => return error.ReplaceFailed,
        };
        defer alloc.free(now);
        if (!std.mem.eql(u8, &digestOf(now), &digest)) return error.Changed;
    }

    if (target.hard_linked) {
        // Opened without truncating, which also works for a hidden or system
        // file (creating over one fails). A file that cannot be opened is
        // untouched, so the copy goes with it; from the first byte on the copy
        // is the only complete one, and the log says where it is.
        const file = std.fs.cwd().openFile(target.path, .{ .mode = .write_only }) catch return error.ReplaceFailed;
        defer file.close();
        temp_pending = false;
        try rewriteOpened(alloc, file, target.path, tmp_path, bytes, kept_copy);
        std.fs.cwd().deleteFile(tmp_path) catch {}; // The rewrite finished: the copy is no longer needed.
        return;
    }

    const target_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, target.path) catch return error.OutOfMemory;
    defer alloc.free(target_w);
    const tmp_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, tmp_path) catch return error.OutOfMemory;
    defer alloc.free(tmp_w);
    if (sys.ReplaceFileW(target_w, tmp_w, null, 0, null, null) == 0) {
        // Likely ERROR_FILE_NOT_FOUND if the user didn't have a
        // config file yet. Fall back to MoveFileExW.
        if (sys.MoveFileExW(tmp_w, target_w, c.MOVEFILE_REPLACE_EXISTING) == 0) {
            return error.ReplaceFailed;
        }
    }
    temp_pending = false;
}

/// Put `bytes` into the opened `file`. From the first byte on the file may be
/// half old and half new, so a failure is `IncompleteWrite`: logged, with the
/// complete copy's path handed to `kept_copy`.
fn rewriteOpened(
    alloc: Allocator,
    file: std.fs.File,
    target_path: []const u8,
    tmp_path: []const u8,
    bytes: []const u8,
    kept_copy: ?*?[]u8,
) WriteError!void {
    replaceContents(file, bytes) catch {
        log.warn("rewriting {s} in place failed; the complete new text is in {s}", .{ target_path, tmp_path });
        if (kept_copy) |out| out.* = alloc.dupe(u8, tmp_path) catch null;
        return error.IncompleteWrite;
    };
}

fn replaceContents(file: std.fs.File, bytes: []const u8) !void {
    try file.writeAll(bytes);
    try file.setEndPos(bytes.len);
    try file.sync();
}

const testing = std.testing;

extern "kernel32" fn CreateSymbolicLinkW(link: [*:0]const u16, target: [*:0]const u16, flags: u32) callconv(.winapi) windows.BOOLEAN;
extern "kernel32" fn CreateHardLinkW(link: [*:0]const u16, existing: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) windows.BOOL;

/// A scratch directory and the absolute path of a name in it. Public for the
/// tests of the code that saves through it.
pub const Scratch = struct {
    tmp: testing.TmpDir,
    /// The directory's absolute path.
    root: []u8,

    pub fn init() !Scratch {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realpathAlloc(testing.allocator, ".") };
    }

    pub fn deinit(self: *Scratch) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    pub fn path(self: *const Scratch, name: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.root, name });
    }

    /// `path(name)` as UTF-16, for the Win32 calls.
    fn pathW(self: *const Scratch, name: []const u8) ![:0]u16 {
        const p = try self.path(name);
        defer testing.allocator.free(p);
        return std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, p);
    }

    pub fn symlink(self: *const Scratch, link: []const u8, target: []const u8) !void {
        const link_w = try self.pathW(link);
        defer testing.allocator.free(link_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, target);
        defer testing.allocator.free(target_w);
        // ALLOW_UNPRIVILEGED_CREATE: works with Developer Mode, no elevation.
        if (CreateSymbolicLinkW(link_w, target_w, 0x2) == 0) {
            if (windows.GetLastError() == .PRIVILEGE_NOT_HELD) return error.SkipZigTest;
            return error.SymlinkFailed;
        }
    }

    pub fn hardlink(self: *const Scratch, link: []const u8, existing: []const u8) !void {
        const link_w = try self.pathW(link);
        defer testing.allocator.free(link_w);
        const existing_w = try self.pathW(existing);
        defer testing.allocator.free(existing_w);
        if (CreateHardLinkW(link_w, existing_w, null) == 0) return error.HardLinkFailed;
    }

    /// Whether the name itself, not what it reaches, is a reparse point.
    pub fn isLink(self: *const Scratch, name: []const u8) !bool {
        const w = try self.pathW(name);
        defer testing.allocator.free(w);
        const attributes = windows.kernel32.GetFileAttributesW(w);
        return attributes != windows.INVALID_FILE_ATTRIBUTES and attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0;
    }

    pub fn expectContent(self: *const Scratch, name: []const u8, expected: []const u8) !void {
        const content = try self.tmp.dir.readFileAlloc(testing.allocator, name, 1 << 20);
        defer testing.allocator.free(content);
        try testing.expectEqualStrings(expected, content);
    }

    /// The entries of the scratch directory, to show a save left nothing else.
    pub fn expectNames(self: *const Scratch, expected: []const []const u8) !void {
        var names: std.ArrayListUnmanaged([]u8) = .{};
        defer {
            for (names.items) |name| testing.allocator.free(name);
            names.deinit(testing.allocator);
        }
        var dir = try self.tmp.dir.openDir(".", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| try names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
        std.mem.sort([]u8, names.items, {}, struct {
            fn less(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        try testing.expectEqual(expected.len, names.items.len);
        for (expected, names.items) |want, got| try testing.expectEqualStrings(want, got);
    }
};

test "a read during which the file grows is unstable" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "font-size = 12\n" });
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);
    const Grow = struct {
        threadlocal var target: []const u8 = "";
        fn append() void {
            test_during_read = null;
            const file = std.fs.openFileAbsolute(target, .{ .mode = .read_write }) catch return;
            defer file.close();
            file.seekFromEnd(0) catch return;
            file.writeAll("copy-on-select = true\n") catch return;
        }
    };
    Grow.target = path;
    test_during_read = Grow.append;
    defer test_during_read = null;
    try testing.expectError(error.Unstable, read(testing.allocator, path));
    // Read again, still: the whole file.
    const bytes = try read(testing.allocator, path);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("font-size = 12\ncopy-on-select = true\n", bytes);
}

test "save target of a missing file is the name itself, and the first save creates it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expectEqualStrings(path, target.path);
    try testing.expect(!target.hard_linked);

    try write(testing.allocator, target, "font-size = 14\n", null);
    try scratch.expectContent("config.ghostty", "font-size = 14\n");
    try scratch.expectNames(&.{"config.ghostty"});
}

test "save target of a plain file is replaced atomically and leaves no temporary file" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "old\n" });
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expect(std.ascii.eqlIgnoreCase(path, target.path));
    try testing.expect(!target.hard_linked);
    try write(testing.allocator, target, "new\n", null);
    try scratch.expectContent("config.ghostty", "new\n");
    try scratch.expectNames(&.{"config.ghostty"});
}

test "save target follows a symbolic link and keeps it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.makeDir("dotfiles");
    try scratch.tmp.dir.writeFile(.{ .sub_path = "dotfiles/config.ghostty", .data = "old\n" });
    // A relative link, as a dotfiles manager makes it.
    try scratch.symlink("config.ghostty", "dotfiles\\config.ghostty");
    try testing.expect(try scratch.isLink("config.ghostty"));
    const link = try scratch.path("config.ghostty");
    defer testing.allocator.free(link);
    const real = try scratch.path("dotfiles\\config.ghostty");
    defer testing.allocator.free(real);

    const target = try resolve(testing.allocator, link);
    defer target.deinit(testing.allocator);
    try testing.expect(std.ascii.eqlIgnoreCase(real, target.path));
    try testing.expect(!target.hard_linked);

    try write(testing.allocator, target, "new\n", null);
    // The link is still a link, both names read the new bytes, and the
    // temporary file was made beside the real file, not beside the link.
    try testing.expect(try scratch.isLink("config.ghostty"));
    try scratch.expectContent("config.ghostty", "new\n");
    try scratch.expectContent("dotfiles/config.ghostty", "new\n");
    try scratch.expectNames(&.{ "config.ghostty", "dotfiles" });
    var dotfiles = try scratch.tmp.dir.openDir("dotfiles", .{ .iterate = true });
    defer dotfiles.close();
    var it = dotfiles.iterate();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "save target follows a chain of links" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "real.conf", .data = "old\n" });
    try scratch.symlink("middle.conf", "real.conf");
    try scratch.symlink("config.ghostty", "middle.conf");
    const link = try scratch.path("config.ghostty");
    defer testing.allocator.free(link);
    const real = try scratch.path("real.conf");
    defer testing.allocator.free(real);

    const target = try resolve(testing.allocator, link);
    defer target.deinit(testing.allocator);
    try testing.expect(std.ascii.eqlIgnoreCase(real, target.path));
    try write(testing.allocator, target, "new\n", null);
    try testing.expect(try scratch.isLink("config.ghostty"));
    try testing.expect(try scratch.isLink("middle.conf"));
    try scratch.expectContent("real.conf", "new\n");
}

test "save target refuses a dangling link instead of replacing it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.symlink("config.ghostty", "missing\\config.ghostty");
    const link = try scratch.path("config.ghostty");
    defer testing.allocator.free(link);

    try testing.expectError(error.DanglingLink, resolve(testing.allocator, link));
    try testing.expect(try scratch.isLink("config.ghostty"));
}

test "save target writes through hard links so every name sees the bytes" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "old\n" });
    try scratch.hardlink("dotfile", "config.ghostty");
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expect(target.hard_linked);

    try write(testing.allocator, target, "new, and longer than before\n", null);
    try scratch.expectContent("config.ghostty", "new, and longer than before\n");
    try scratch.expectContent("dotfile", "new, and longer than before\n");
    // A shorter rewrite truncates: nothing of the old bytes is left behind.
    try write(testing.allocator, target, "x\n", null);
    try scratch.expectContent("dotfile", "x\n");
    try scratch.expectNames(&.{ "config.ghostty", "dotfile" });
}

extern "kernel32" fn SetFileAttributesW(name: [*:0]const u16, attributes: u32) callconv(.winapi) windows.BOOL;

test "save target keeps a hard-linked file that cannot be opened as it was, with no copy left behind" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "old\n" });
    try scratch.hardlink("dotfile", "config.ghostty");
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, path);
    defer testing.allocator.free(path_w);
    // The attribute belongs to the file, so both names are read-only.
    try testing.expect(SetFileAttributesW(path_w, windows.FILE_ATTRIBUTE_READONLY) != 0);
    defer _ = SetFileAttributesW(path_w, windows.FILE_ATTRIBUTE_NORMAL);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expect(target.hard_linked);
    try testing.expectError(error.ReplaceFailed, write(testing.allocator, target, "new\n", null));
    try scratch.expectContent("config.ghostty", "old\n");
    try scratch.expectNames(&.{ "config.ghostty", "dotfile" });
}

test "save target rewrites a hidden hard-linked file in place" {
    // Creating over a hidden file fails with access denied; opening it does not.
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "old and longer than the new text\n" });
    try scratch.hardlink("dotfile", "config.ghostty");
    const path = try scratch.path("config.ghostty");
    defer testing.allocator.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(testing.allocator, path);
    defer testing.allocator.free(path_w);
    try testing.expect(SetFileAttributesW(path_w, windows.FILE_ATTRIBUTE_HIDDEN) != 0);
    defer _ = SetFileAttributesW(path_w, windows.FILE_ATTRIBUTE_NORMAL);

    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expect(target.hard_linked);
    try write(testing.allocator, target, "new\n", null);
    try scratch.expectContent("config.ghostty", "new\n");
    try scratch.expectContent("dotfile", "new\n");
    try scratch.expectNames(&.{ "config.ghostty", "dotfile" });
}

test "an in-place rewrite that fails after it started reports where the complete copy is" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "old\n" });
    // A handle that cannot write stands in for a disk that fills up part way.
    const file = try scratch.tmp.dir.openFile("config.ghostty", .{ .mode = .read_only });
    defer file.close();

    var kept: ?[]u8 = null;
    defer if (kept) |path| testing.allocator.free(path);
    try testing.expectError(
        error.IncompleteWrite,
        rewriteOpened(testing.allocator, file, "C:\\x\\config.ghostty", "C:\\x\\config.ghostty.tmp-1-2", "new\n", &kept),
    );
    try testing.expectEqualStrings("C:\\x\\config.ghostty.tmp-1-2", kept.?);

    // Nobody listening is fine too.
    try testing.expectError(
        error.IncompleteWrite,
        rewriteOpened(testing.allocator, file, "C:\\x\\config.ghostty", "C:\\x\\config.ghostty.tmp-1-2", "new\n", null),
    );
}

test "save target keeps the extended form for a name with a trailing dot and writes that file" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    // `config.` and `config` are two files; only the extended form reaches the
    // first. A link to it resolves to this name, and the plain spelling would
    // be the other file.
    const dotted = try std.fmt.allocPrint(testing.allocator, "\\\\?\\{s}\\config.", .{scratch.root});
    defer testing.allocator.free(dotted);
    try std.fs.cwd().writeFile(.{ .sub_path = dotted, .data = "old\n" });
    try scratch.tmp.dir.writeFile(.{ .sub_path = "config", .data = "sibling\n" });

    const target = try resolve(testing.allocator, dotted);
    defer target.deinit(testing.allocator);
    try testing.expectEqualStrings(dotted, target.path);
    try write(testing.allocator, target, "new\n", null);

    const written = try std.fs.cwd().readFileAlloc(testing.allocator, dotted, 1024);
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("new\n", written);
    try scratch.expectContent("config", "sibling\n");
    try scratch.expectNames(&.{ "config", "config." });
}

test "save target of a name in a missing directory is the name itself" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const path = try scratch.path("new-dir\\custom.conf");
    defer testing.allocator.free(path);
    const target = try resolve(testing.allocator, path);
    defer target.deinit(testing.allocator);
    try testing.expectEqualStrings(path, target.path);
}

test "final path names lose the extended-length prefix and keep other shapes" {
    const cases = [_]struct { name: []const u8, plain: []const u8 }{
        .{ .name = "\\\\?\\C:\\Users\\a\\config.ghostty", .plain = "C:\\Users\\a\\config.ghostty" },
        .{ .name = "\\\\?\\UNC\\server\\share\\dir\\config.ghostty", .plain = "\\\\server\\share\\dir\\config.ghostty" },
        // A volume without a drive letter has no shorter spelling.
        .{ .name = "\\\\?\\Volume{01234567-89ab-cdef-0123-456789abcdef}\\a.conf", .plain = "\\\\?\\Volume{01234567-89ab-cdef-0123-456789abcdef}\\a.conf" },
        .{ .name = "C:\\already\\plain.conf", .plain = "C:\\already\\plain.conf" },
        .{ .name = "\\\\?\\C:", .plain = "\\\\?\\C:" },
        // Names Win32 normalization would change keep the extended form.
        .{ .name = "\\\\?\\C:\\dotfiles\\config.", .plain = "\\\\?\\C:\\dotfiles\\config." },
        .{ .name = "\\\\?\\C:\\dotfiles\\config ", .plain = "\\\\?\\C:\\dotfiles\\config " },
        .{ .name = "\\\\?\\C:\\dotfiles.\\config", .plain = "\\\\?\\C:\\dotfiles.\\config" },
        .{ .name = "\\\\?\\C:\\dotfiles\\nul", .plain = "\\\\?\\C:\\dotfiles\\nul" },
        .{ .name = "\\\\?\\C:\\dotfiles\\Aux.conf", .plain = "\\\\?\\C:\\dotfiles\\Aux.conf" },
        .{ .name = "\\\\?\\C:\\dotfiles\\com1", .plain = "\\\\?\\C:\\dotfiles\\com1" },
        .{ .name = "\\\\?\\UNC\\server\\share\\config.", .plain = "\\\\?\\UNC\\server\\share\\config." },
        // Near misses are ordinary names.
        .{ .name = "\\\\?\\C:\\dotfiles\\.config\\com0.conf", .plain = "C:\\dotfiles\\.config\\com0.conf" },
        .{ .name = "\\\\?\\C:\\dotfiles\\console\\auxiliary.conf", .plain = "C:\\dotfiles\\console\\auxiliary.conf" },
        .{ .name = "\\\\?\\C:\\dotfiles\\com10", .plain = "C:\\dotfiles\\com10" },
        // Too long for MAX_PATH once plain: the extended form stays.
        .{ .name = "\\\\?\\C:\\" ++ "d" ** 240 ++ "\\config.ghostty", .plain = "\\\\?\\C:\\" ++ "d" ** 240 ++ "\\config.ghostty" },
        .{ .name = "\\\\?\\UNC\\server\\share\\" ++ "d" ** 240, .plain = "\\\\?\\UNC\\server\\share\\" ++ "d" ** 240 },
    };
    for (cases) |case| {
        const buffer = try testing.allocator.dupe(u8, case.name);
        defer testing.allocator.free(buffer);
        try testing.expectEqualStrings(case.plain, plain(buffer));
    }
}
