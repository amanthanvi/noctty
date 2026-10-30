//! Which local Windows path a program-reported (or noctty-held) path names,
//! and whether noctty may act on it: the directory an OSC 7 or OSC 9;9
//! report names (`pwd`), the file link or quick-select text names
//! (`linkTarget`, `isLocalShape`), and a bounded open on a local drive for
//! the link opener, the editor and the Settings config read (`open`).
//! Only `open` touches the filesystem (`linkTarget` and `Found.storedName`
//! through it). No unchecked reparse target is opened, including targets
//! reached through another local symlink, so nothing it opens contacts a
//! share.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const os_windows = @import("windows.zig");
const os_path = @import("path.zig");

const OBJ_DONT_REPARSE = 0x1000;
const STATUS_REPARSE_POINT_ENCOUNTERED = 0xc000050b;
const IO_REPARSE_TAG_CLOUD = 0x9000001a;

/// What `open` does with a cloud-files placeholder (OneDrive and the like)
/// on the way.
pub const Cloud = enum {
    /// Open it as its provider presents it, which may first recall it from
    /// the provider. The link opener and the editor do.
    open,
    /// Refuse it, and anything else marked for recall from remote storage,
    /// before anything opens it in a way that could recall it: for a read on
    /// the UI thread, where a slow or offline provider would stall the window.
    /// The data is then read through a reopen of the checked handle.
    refuse,
};

pub const How = struct {
    /// Open the file to read its data, not only its attributes.
    data: bool = false,
    cloud: Cloud = .open,
};

/// What `open` found at a path.
pub const Opened = union(enum) {
    found: Found,
    /// Nothing is there: a folder shown to be local lacks the next name. No
    /// link was left unchecked to say so.
    missing,
    /// Not a local drive path, a link on the way leads somewhere that cannot
    /// be shown to be local (a share, a mapped drive, a device), or opening
    /// failed.
    refused,
};

/// The local file or directory `open` found.
pub const Found = struct {
    /// The path as given, resolved: drive-absolute. Owned by the caller.
    path: []u8,
    /// Open for its attributes (and its data with `How.data`), sharing read,
    /// write and delete.
    file: std.fs.File,

    pub fn deinit(self: Found, alloc: Allocator) void {
        self.file.close();
        alloc.free(self.path);
    }

    /// The name the folder stores the last component under, read through a
    /// guarded open of that folder. NTFS also finds a file by its 8.3 alias
    /// (`CMD~1` for `.cmd`), which the shell namespace types by this long
    /// name. Null when there is no such entry, or out of memory.
    pub fn storedName(self: Found, alloc: Allocator) ?[]u8 {
        const leaf = std.fs.path.basename(self.path);
        // The query takes a pattern, so a wildcard would name another entry.
        if (leaf.len == 0 or std.mem.indexOfAny(u8, leaf, "*?<>\"") != null) return null;
        const dir = switch (lookup(alloc, std.fs.path.dirname(self.path) orelse return null, .{ .data = true })) {
            .file => |file| file,
            .missing, .refused => return null,
        };
        defer dir.close();
        const leaf_w = std.unicode.utf8ToUtf16LeAlloc(alloc, leaf) catch return null;
        defer alloc.free(leaf_w);
        var pattern = unicodeString(leaf_w);
        var buffer: [@sizeOf(windows.FILE_DIRECTORY_INFORMATION) + windows.NAME_MAX * 2]u8 align(@alignOf(windows.FILE_DIRECTORY_INFORMATION)) = undefined;
        var io: windows.IO_STATUS_BLOCK = undefined;
        if (windows.ntdll.NtQueryDirectoryFile(dir.handle, null, null, null, &io, &buffer, buffer.len, .FileDirectoryInformation, windows.TRUE, &pattern, windows.TRUE) != .SUCCESS) return null;
        const info: *const windows.FILE_DIRECTORY_INFORMATION = @ptrCast(&buffer);
        const name_w: [*]const u16 = @ptrCast(&info.FileName);
        return std.unicode.utf16LeToUtf8Alloc(alloc, name_w[0 .. info.FileNameLength / 2]) catch null;
    }
};

/// Open what `path` names, on a local drive only. As given, `path` must be
/// drive-absolute (`X:\` or `X:/`) with no `:` after the drive: Zig 0.15.2's
/// `resolve` panics on some other shapes (a share whose second name is the
/// other separator, `\\a\/`). It is then resolved, and refused past
/// PATH_MAX_WIDE bytes. The drive must be fixed, removable, a CD-ROM or a RAM
/// disk; each name is opened under OBJ_DONT_REPARSE relative to its checked
/// parent, a symlink or junction is followed only to a local drive or a
/// direct Volume{GUID} (at most 32 hops and 256 names), and the handle's
/// final path must be local. Nothing waits on a network: `.missing` never
/// comes from a share. Out of memory in the resolve propagates; inside the
/// walk the path is refused.
pub fn open(alloc: Allocator, path: []const u8, how: How) Allocator.Error!Opened {
    if (!os_path.isDriveAbsolutePath(path) or std.mem.indexOfScalar(u8, path[2..], ':') != null) return .refused;
    const resolved = try std.fs.path.resolve(alloc, &.{path});
    const looked = lookup(alloc, resolved, how);
    if (looked != .file) alloc.free(resolved);
    return switch (looked) {
        .file => |file| .{ .found = .{ .path = resolved, .file = file } },
        .missing => .missing,
        .refused => .refused,
    };
}

/// A directory a program reported.
pub const Report = union(enum) {
    /// The decoded path of an OSC 7 (or URL-form OSC 9;9) `file://` or
    /// `kitty-shell-cwd://` URL, whose host the caller showed is this machine
    /// (`os.hostname.isLocal`).
    url_path: []const u8,
    /// An OSC 9;9 value as sent: `C:\x` or `C:/x`, either in one pair of
    /// double quotes (oh-my-posh's `osc99`, nushell), or the
    /// `\\wsl.localhost\Distro\...` / `\\wsl$\...` path `wslpath -w` prints,
    /// the recipe Windows Terminal documents for WSL.
    conemu: []const u8,
};

pub const PwdError = Allocator.Error || error{
    /// `.conemu` only: not a plain path, so the caller reads the value as a
    /// URL (noctty's cmd integration sends `kitty-shell-cwd://localhost/%P`).
    NotPlainPath,
    /// A share or device path, in any spelling, after translation.
    NetworkOrDevicePath,
    /// A C0 or DEL byte, which could split a CreateProcess current directory
    /// or environment value, or a window title.
    UnsafeBytes,
};

/// The pwd to keep for a report, allocated in `alloc`. Touches no file, so it
/// is safe on the io thread. The result is a drive-absolute `X:\...` (a file
/// URI's `/C:/x` and a 9;9 `C:/x` included); a POSIX path a WSL shell
/// (`/home/me`, also from `\\wsl.localhost\D\home\me`) or an MSYS2 shell
/// (`/c/Users/me`) reported, kept POSIX so a later WSL launch can inherit it;
/// or any other spelling that passed the screening, kept as given. Launch code
/// (`spawnCwd`, `shellPwd`, `safeCurrentDirectory`) reads this format, and
/// `linkTarget` reads it back as `Pane.dir`.
pub fn pwd(alloc: Allocator, report: Report) PwdError![]const u8 {
    const path = switch (report) {
        .url_path => |raw| try osc7PathToLocal(alloc, raw),
        .conemu => |value| try conemuPathToLocal(alloc, value) orelse return error.NotPlainPath,
    };
    errdefer alloc.free(path);
    // A network share or device path is not a directory this terminal acts
    // on: spawning already replaces it with the home folder and links to such
    // paths are never opened. Keeping it would let later readers (relative
    // link resolution, session files) touch it.
    if (!os_path.isSafeWindowsPath(path)) return error.UnsafeBytes;
    if (os_path.isNetworkOrDevicePath(path)) return error.NetworkOrDevicePath;
    return path;
}

/// A local path from OSC 7 as a Windows path string. WSL paths stay WSL-style
/// so they can be inherited into later WSL shells.
fn osc7PathToLocal(alloc: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (os_path.isWindowsUriPath(path)) return try os_path.uriPathToWindows(alloc, path);
    // A UNC path carried in a URI keeps the URI's leading `/`. Strip it before
    // the WSL check below, which would otherwise treat the whole string as a
    // POSIX path and hand back an unusable `/\\server\share` cwd.
    if (os_path.isUncUriPath(path)) {
        const unc = path[1..];
        if (os_path.isWslPath(unc)) return try os_path.normalizeWslPath(alloc, unc);
        return try alloc.dupe(u8, unc);
    }
    if (os_path.isWslPath(path)) return try os_path.normalizeWslPath(alloc, path);
    return try alloc.dupe(u8, path);
}

/// The Windows path in the plain form of ConEmu's OSC 9;9 (`Report.conemu`),
/// or null for anything else, which the caller reads as a URL. Only a
/// drive-absolute path qualifies, plus the WSL form, which maps to the
/// distro's own `/home/me` exactly as it does in an OSC 7 URL. Any other UNC
/// path, a device path and a relative path are not taken.
fn conemuPathToLocal(alloc: Allocator, value: []const u8) Allocator.Error!?[]const u8 {
    const path = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
    // A quote left over is not part of any Windows path.
    if (std.mem.indexOfScalar(u8, path, '"') != null) return null;
    if (os_path.isDriveAbsolutePath(path)) return try os_path.drivePathToWindows(alloc, path[0], path[3..]);
    if (std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\")) return try os_path.normalizeWslPath(alloc, path);
    return null;
}

/// The pane link or quick-select text was printed in.
pub const Pane = struct {
    /// The pane's directory, for relative text: a reported pwd, or the launch
    /// or restored directory. Null when it has none.
    dir: ?[]const u8 = null,
    /// The pane's launch command runs WSL (`Surface.launchesWsl`): there
    /// `/c/x` is a Linux path, in any other pane `C:\x`.
    wsl: bool,
};

/// The local path to open for link text, owned by `alloc`, or null, which
/// leaves the text to the opener as written: a URL, an absolute Windows path
/// with no location, or text that names nothing local.
///
/// - A compiler's `file:12:5` or `file(12,5)` is not part of the name, but a
///   name can end that way, so the whole text is tried first.
/// - Relative text is read against `pane.dir`, and is null without one.
///   Absolute text, rooted `\x` included, ignores `pane.dir`.
/// - Outside WSL an MSYS2 or Cygwin drive path is a Windows path:
///   `/c/Users/me` and `/cygdrive/c/Users/me` are `C:\Users\me`, as text and
///   as `pane.dir` (fish under MSYS2 reports `/c/...` in its OSC 7, and `/c`
///   for the drive's root). Such text gives the Windows path even when
///   nothing is there, so the opener refuses it as it refuses that path typed
///   with a drive letter. A drive's root as text (`/c`, as in `cmd /c`) is
///   not read, nor is a `..` above the drive.
///
/// Whether a file is there is asked through `open`, which never contacts a
/// share; call it without the renderer mutex held. No text or directory
/// makes it panic or abort.
pub fn linkTarget(alloc: Allocator, text: []const u8, pane: Pane) Allocator.Error!?[]const u8 {
    const dir: ?[]const u8 = if (std.fs.path.isAbsolute(text)) null else pane.dir orelse return null;
    if (pane.wsl) return resolveOpenPath(alloc, dir, text);
    return resolveMsysOpenPath(alloc, dir, text);
}

/// Whether link text has the shape of a file on this machine, which a click
/// opens through `linkTarget`: a drive path (`C:\x`, `C:/x`), a relative one
/// (`.\x`, `src\main.zig:12`), and outside WSL an MSYS2 or Cygwin drive path
/// (`/c/x`, `/cygdrive/c/x`). It says nothing about whether the file exists
/// or may be opened, and looks at no file. A share, a device path and any
/// other rooted `/x` are not local shapes, and neither is anything that is
/// not only a path, such as a URL.
pub fn isLocalShape(text: []const u8, wsl: bool) bool {
    const path = splitLocation(text) orelse text;
    if (path.len == 0) return false;
    if (!wsl and msysDriveRoot(path, 1) != null)
        return std.mem.indexOfScalar(u8, path, ':') == null;
    if (path.len > 3 and os_path.isDriveAbsolutePath(path))
        return std.mem.indexOfScalar(u8, path[2..], ':') == null;
    const separators = "\\/";
    if (std.mem.indexOfScalar(u8, separators, path[0]) != null) return false;
    if (std.mem.indexOfScalar(u8, path, ':') != null) return false;
    return std.mem.indexOfAny(u8, path, separators) != null;
}

/// `resolveOpenPath` for a pane that is not WSL, reading an MSYS2 or Cygwin
/// drive path as the Windows path it names (`linkTarget`).
fn resolveMsysOpenPath(alloc: Allocator, dir: ?[]const u8, text: []const u8) Allocator.Error!?[]const u8 {
    if (try msysToWindows(alloc, text, 1)) |path| {
        const found = resolveOpenPath(alloc, null, path) catch |err| {
            alloc.free(path);
            return err;
        };
        if (found == null) return path;
        alloc.free(path);
        return found;
    }
    const base = dir orelse return resolveOpenPath(alloc, null, text);
    const windows_base = try msysToWindows(alloc, base, 0);
    defer if (windows_base) |p| alloc.free(p);
    return resolveOpenPath(alloc, windows_base orelse base, text);
}

/// What link text names on disk, as an owned path, or null (`linkTarget`).
/// `dir` is null for an absolute path and the pane's directory for a
/// relative one.
fn resolveOpenPath(alloc: Allocator, dir: ?[]const u8, text: []const u8) Allocator.Error!?[]const u8 {
    const bare = splitLocation(text);
    if (dir == null) {
        // The opener checks an absolute path itself; only a location needs us.
        const stripped = bare orelse return null;
        if (try existingPath(alloc, null, text)) |whole| {
            alloc.free(whole);
            return null;
        }
        return existingPath(alloc, null, stripped);
    }
    if (try existingPath(alloc, dir, text)) |whole| return whole;
    return existingPath(alloc, dir, bare orelse return null);
}

/// `path` as an absolute path, if it exists. Relative to `dir` when that is
/// set.
fn existingPath(alloc: Allocator, dir: ?[]const u8, path: []const u8) Allocator.Error!?[]const u8 {
    // Zig's `resolve` indexes an empty slice (a panic) when a drive-relative
    // name such as `D:x` is joined onto a path (measured with `b:x`, `D:x`).
    // No default pattern produces one, but a custom `link` regex can.
    // Zig's parser takes any byte before the ':' as a drive (`1:x` panics too).
    if (path.len >= 2 and path[1] == ':' and !std.fs.path.isAbsolute(path)) return null;

    // A share or device path is never resolved either: `resolve` unwraps a null
    // on a server whose share is a lone separator (`\\a\/`), and it is the
    // opener's to refuse anyway.
    if (os_path.isNetworkOrDevicePath(path)) return null;

    // The same two panics as a base: a drive with no root (`C:`, `b:x`) and
    // `\\a\/`. A pane's directory should be neither, but a launch directory
    // is not screened like a reported one.
    if (dir) |base| if (!std.fs.path.isAbsolute(base) or os_path.isNetworkOrDevicePath(base)) return null;

    // Always the output of `resolve`, which `windowsPathIsRepresentable`
    // needs: it also folds `.`, `..` and mixed separators out of absolute text.
    const resolved = if (dir) |base|
        try std.fs.path.resolve(alloc, &.{ base, path })
    else
        try std.fs.path.resolve(alloc, &.{path});
    defer alloc.free(resolved);

    // Link text is arbitrary, so resolution can produce a string Windows
    // cannot represent as a path: "https://example.com" becomes
    // "C:\Users\me\https:\example.com". Screen the result before anything
    // hands it to the filesystem.
    if (!windowsPathIsRepresentable(resolved)) return null;

    // The bounded open answers whether it exists, not `accessAbsolute`. It
    // refuses a path that is not on a local drive letter, a mapped network
    // drive, and a symlink or junction that leads to a share
    // (`C:\link\x.txt:12` into a share), all before anything touches the
    // network; `accessAbsolute` follows such a link, and the UI thread would
    // wait on the server first. It also answers with a status where
    // `faccessatW` has an `unreachable`.
    return switch (try open(alloc, resolved, .{})) {
        .found => |found| found: {
            found.file.close();
            break :found found.path;
        },
        .missing, .refused => null,
    };
}

/// Whether `path` is a local path Windows can address, which must be the output
/// of `std.fs.path.resolve`.
///
/// Defence in depth in front of `open`, which refuses every shape this does
/// but a device name, and answers NT's own refusals with a status. It was the
/// one gate while `existingPath` asked `accessAbsolute`, whose `faccessatW`
/// maps `STATUS_OBJECT_NAME_INVALID` to `unreachable` (a process abort), and
/// is kept so that no link text reaches the filesystem in a shape NT calls
/// malformed. Shapes we cannot cheaply prove safe are rejected, which only
/// costs the link its file-path interpretation.
fn windowsPathIsRepresentable(path: []const u8) bool {
    // Also not for a network share or device path. The pwd can no longer be
    // one (the stream handler refuses it), and a launch directory is screened
    // before `resolve` too; this keeps a third gate in front of the open.
    if (os_path.isNetworkOrDevicePath(path)) return false;

    // `resolve` does not always return an absolute path: a pwd opening with
    // `\/` comes back as `server\share\file`.
    if (!std.fs.path.isAbsolute(path)) return false;

    var rest = path;

    if (rest.len >= 2 and rest[1] == ':' and std.ascii.isAlphabetic(rest[0])) {
        rest = rest[2..];
    }

    const leaf_start = if (std.mem.lastIndexOfAny(u8, rest, "/\\")) |i| i + 1 else 0;
    const dirs = rest[0..leaf_start];
    const leaf = rest[leaf_start..];

    // Outside the leaf a ':' names a directory Windows cannot address, which
    // is the shape a URL takes once it is resolved against the terminal pwd.
    if (std.mem.indexOfScalar(u8, dirs, ':') != null) return false;
    if (!windowsNameIsAddressable(dirs)) return false;

    // The leaf may carry one alternate-data-stream separator. NT accepts any
    // character in a stream name, control characters included, but both sides
    // of the ':' must be non-empty, and a second ':' introduces a stream
    // *type* that NT validates against a fixed set ("$DATA" and friends).
    // Rather than model that set we admit a single separator only. (`open`
    // takes no ':' after the drive, so a stream never reaches the disk; these
    // checks only keep the shapes NT calls malformed out of it.)
    const ads = std.mem.indexOfScalar(u8, leaf, ':') orelse
        return !windowsNameIsDevice(leaf) and windowsNameIsAddressable(leaf);
    const name = leaf[0..ads];
    if (windowsNameIsDevice(name)) return false;
    // `resolve` does not fold `.` or `..` when a stream follows (`C:\x\.:12`),
    // and NT answers STATUS_OBJECT_NAME_INVALID for the name (found by a sweep
    // of short strings; `...:x` and `a.:x` are fine).
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    const stream = leaf[ads + 1 ..];
    if (name.len == 0 or stream.len == 0) return false;
    if (std.mem.indexOfScalar(u8, stream, ':') != null) return false;
    // Windows drops trailing dots and spaces from a component, so a stream made
    // of nothing else (`b:.`, `b: `) is empty by the time NT sees it, and NT
    // answers STATUS_OBJECT_NAME_INVALID. `b:x.` and `b: x` are fine
    // (measured: not found).
    if (std.mem.trimRight(u8, stream, ". ").len == 0) return false;
    // A NUL would truncate in a wide-string API, so a check could run against
    // a shorter path than the one we hand back to be opened.
    if (std.mem.indexOfScalar(u8, stream, 0) != null) return false;
    return windowsNameIsAddressable(name);
}

/// Whether a final path component names a DOS device (`NUL`, `con.txt`,
/// `COM1`, `CONOUT$`), however it is spelled: case, trailing spaces, and an
/// extension (older Windows maps `NUL.txt` to NUL too).
///
/// `RtlGetFullPathName_U` turns such a final component into `\\.\nul`, so the
/// path converted is not the one checked (measured with `C:\x\nul:12`,
/// `./nul`, `nul.` and `nul `, which aborted `faccessatW` when it ran here).
/// `con`, `aux`, `prn`, `com9`, `lpt1` and `nul.txt` were not mapped on
/// Windows 11 build 26200, where they are ordinary file names, but older
/// Windows maps them. They are refused too: this is the one place that has to
/// hold on every build, and the only check here that `open` does not repeat.
fn windowsNameIsDevice(name: []const u8) bool {
    const stem = std.mem.trimRight(u8, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len], " ");
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    return stem.len == 4 and std.ascii.isDigit(stem[3]) and
        (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"));
}

/// Whether `name` uses only characters NT accepts in a file name. It may
/// contain path separators, but no drive prefix and no stream separator.
///
/// `<>"|?*` are never legal, and neither are the C0 controls. DEL is legal:
/// NT treats 0x7f like any other byte, so `std.ascii.isControl` would be too
/// broad here.
fn windowsNameIsAddressable(name: []const u8) bool {
    if (std.mem.indexOfAny(u8, name, "<>\"|?*") != null) return false;
    for (name) |c| if (c < 0x20) return false;
    return true;
}

/// The Windows path an MSYS2 or Cygwin program means by `path`, an absolute
/// path on a drive: MSYS2 (Git Bash included) prints `C:\Users\me` as
/// `/c/Users/me`, and Cygwin as `/cygdrive/c/Users/me`. Null unless it names
/// something at least `min_depth` levels below the drive's root (`msysDriveRoot`).
/// The drive is not checked: whatever opens the result refuses a letter that
/// is not a local drive.
fn msysToWindows(alloc: Allocator, path: []const u8, min_depth: usize) Allocator.Error!?[]const u8 {
    const rooted = msysDriveRoot(path, min_depth) orelse return null;
    return try os_path.drivePathToWindows(alloc, std.ascii.toUpper(rooted[1]), rooted[2..]);
}

/// `path` from its `/<letter>` on, without the `/cygdrive` prefix, when it
/// names something at least `min_depth` levels below the drive's root and no
/// `..` leaves the drive. A name of only dots and spaces adds no level:
/// Windows drops a final one (`C:\...` is `C:\`). Link text needs a level
/// (`/c` alone is nearly always a switch: `cmd /c`, `findstr /c:x`), a
/// pane's directory none (`cd /c`). `//server/share` and `/\server` never
/// start with a letter.
fn msysDriveRoot(path: []const u8, min_depth: usize) ?[]const u8 {
    const rooted = if (std.mem.startsWith(u8, path, "/cygdrive/")) path["/cygdrive".len..] else path;
    if (rooted.len < 2 or rooted[0] != '/' or !std.ascii.isAlphabetic(rooted[1])) return null;
    if (rooted.len > 2 and rooted[2] != '/') return null;
    var depth: usize = 0;
    var names = std.mem.tokenizeAny(u8, rooted[2..], "/\\");
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "..")) {
            depth = std.math.sub(usize, depth, 1) catch return null;
        } else if (std.mem.trim(u8, name, ". ").len > 0) {
            depth += 1;
        }
    }
    return if (depth >= min_depth) rooted else null;
}

/// The path in `text` without the location a compiler or test runner appends:
/// `:line`, `:line:col`, `(line)` or `(line,col)`. Null when there is none.
///
/// Nothing here says the rest is a path. A name can end in `(1)`, so a caller
/// that opens something tries the whole text first.
fn splitLocation(text: []const u8) ?[]const u8 {
    var end = text.len;
    if (end > 0 and text[end - 1] == ')') {
        const paren = std.mem.lastIndexOfScalar(u8, text, '(') orelse return null;
        const inner = text[paren + 1 .. end - 1];
        const comma = std.mem.indexOfScalar(u8, inner, ',');
        if (!allDigits(inner[0 .. comma orelse inner.len])) return null;
        if (comma) |i| if (!allDigits(inner[i + 1 ..])) return null;
        end = paren;
    } else {
        for (0..2) |_| {
            const colon = std.mem.lastIndexOfScalar(u8, text[0..end], ':') orelse break;
            if (!allDigits(text[colon + 1 .. end])) break;
            end = colon;
        }
    }
    // A drive letter alone is not a path.
    if (end == text.len or end < 2) return null;
    return text[0..end];
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// What `lookup` found at a resolved path.
const Lookup = union(enum) {
    file: std.fs.File,
    missing,
    refused,
};

fn lookup(alloc: Allocator, path: []const u8, how: How) Lookup {
    // Zig 0.15.2's `sliceToPrefixedFileW` writes past its fixed buffer for a
    // longer path; a WTF-8 byte is at most one unit, so this always fits.
    if (path.len > windows.PATH_MAX_WIDE) return .refused;
    const root_len = localRoot(path) orelse return .refused;
    // Under `.refuse` there is no direct open: an open that follows no link
    // still reaches a placeholder's provider, which can recall it then.
    if (how.cloud == .open) {
        var wide = windows.sliceToPrefixedFileW(null, path) catch return .refused;
        // Windows 10 can reject the DOS drive alias itself under OBJ_DONT_REPARSE.
        // Resolve only that alias; all filesystem components retain the guard.
        if (root_len == 3 and !os_windows.directVolumePath(&wide)) return .refused;
        var handle: windows.HANDLE = undefined;
        const status = create(wide.span(), null, OBJ_DONT_REPARSE, .{ .read_data = how.data }, &handle);
        if (status == .SUCCESS) return .{ .file = .{ .handle = handle } };
        // Under OBJ_DONT_REPARSE a reparse point on the way is reported before a
        // missing name after it, so a missing name here crossed no link.
        if (notFound(status)) return .missing;
        if (@intFromEnum(status) != STATUS_REPARSE_POINT_ENCOUNTERED) return .refused;
    }

    // Walk relative to already opened parents. An absolute prefix-by-prefix
    // scan followed by a normal open would follow unchecked target chains and
    // could race into a share during that scan, before the final-path check.
    // Under `.refuse` each name is opened as itself, for its attributes only,
    // and the data only once the last one has been shown to be no placeholder.
    var state: Walk = .{ .cloud = how.cloud };
    const walk_data = how.data and how.cloud == .open;
    const file = walk(alloc, path, walk_data, 0, &state) orelse return if (state.not_found) .missing else .refused;
    if (!hasLocalFinalPath(file.handle)) {
        file.close();
        return .refused;
    }
    if (how.data and !walk_data) {
        // The same file again, through its handle (an empty name relative to
        // it, as ReOpenFile does), not by its path.
        defer file.close();
        var data: windows.HANDLE = undefined;
        if (create(&.{}, file.handle, 0, .{ .no_follow = true, .read_data = true }, &data) != .SUCCESS) return .refused;
        return .{ .file = .{ .handle = data } };
    }
    return .{ .file = file };
}

fn notFound(status: windows.NTSTATUS) bool {
    return status == .OBJECT_NAME_NOT_FOUND or status == .OBJECT_PATH_NOT_FOUND;
}

/// A walk's budget of components, and whether it stopped at a name that is
/// not there (in a folder it had opened and checked).
const Walk = struct {
    remaining: usize = 256,
    not_found: bool = false,
    cloud: Cloud = .open,
};

const CreateOptions = struct {
    /// Open a reparse point itself instead of what it points at.
    no_follow: bool = false,
    read_data: bool = false,
    pin_reparse: bool = false,
};

fn unicodeString(wide: []const u16) windows.UNICODE_STRING {
    return .{
        .Length = @intCast(wide.len * 2),
        .MaximumLength = @intCast(wide.len * 2),
        .Buffer = @constCast(wide.ptr),
    };
}

fn create(name_w: []const u16, parent: ?windows.HANDLE, attributes: u32, options: CreateOptions, handle: *windows.HANDLE) windows.NTSTATUS {
    var name = unicodeString(name_w);
    var attrs: windows.OBJECT_ATTRIBUTES = .{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = parent,
        .ObjectName = &name,
        .Attributes = attributes,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var io: windows.IO_STATUS_BLOCK = undefined;
    return windows.ntdll.NtCreateFile(
        handle,
        windows.FILE_READ_ATTRIBUTES | windows.SYNCHRONIZE | (if (options.read_data) @as(u32, windows.FILE_READ_DATA) else 0),
        &attrs,
        &io,
        null,
        windows.FILE_ATTRIBUTE_NORMAL,
        // Pin only reparse objects against replacement and reparse-data writes.
        // Ordinary files (including actively written logs) retain shared access.
        if (options.pin_reparse) windows.FILE_SHARE_READ else windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        windows.FILE_OPEN,
        windows.FILE_SYNCHRONOUS_IO_NONALERT | (if (options.no_follow) @as(u32, windows.FILE_OPEN_REPARSE_POINT) else 0),
        null,
        0,
    );
}

fn walk(alloc: Allocator, path: []const u8, read_data: bool, depth: usize, state: *Walk) ?std.fs.File {
    if (depth >= 32) return null;
    const root_len = localRoot(path) orelse return null;
    var root_w = windows.sliceToPrefixedFileW(null, path[0..root_len]) catch return null;
    if (root_len == 3 and !os_windows.directVolumePath(&root_w)) return null;
    if (root_len == 49) {
        // OBJ_DONT_REPARSE rejects the mount manager's Volume{GUID} alias.
        // Read that mapping without opening it, accept only a direct volume
        // device name (no intermediate filesystem path), then keep the guard.
        var alias_w: [44:0]u16 = undefined;
        for (path[4..48], 0..) |ch, i| alias_w[i] = ch;
        alias_w[44] = 0;
        var device: [512]u16 = undefined;
        const volume = os_windows.directVolumeDeviceName(&alias_w, &device) orelse return null;
        @memcpy(root_w.data[0..volume.len], volume);
        root_w.data[volume.len] = '\\';
        root_w.len = volume.len + 1;
        root_w.data[root_w.len] = 0;
    }
    var parent: windows.HANDLE = undefined;
    if (create(root_w.span(), null, OBJ_DONT_REPARSE, .{ .no_follow = true }, &parent) != .SUCCESS) return null;
    var own_parent = true;
    defer if (own_parent) windows.CloseHandle(parent);
    const root_info = attributeTag(parent) orelse return null;
    if (root_info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 or !hasLocalFinalPath(parent)) return null;
    var start = root_len;
    while (start < path.len) {
        if (state.remaining == 0) return null;
        state.remaining -= 1;
        const end = if (std.mem.indexOfScalarPos(u8, path, start, '\\')) |i| i else path.len;
        const last = end == path.len;
        const name_w = std.unicode.utf8ToUtf16LeAlloc(alloc, path[start..end]) catch return null;
        defer alloc.free(name_w);
        var child: windows.HANDLE = undefined;
        const status = create(name_w, parent, 0, .{ .no_follow = true, .read_data = last and read_data }, &child);
        if (status != .SUCCESS) {
            // `parent` is open and was checked: the name is not in it.
            state.not_found = notFound(status);
            return null;
        }
        var own_child = true;
        defer if (own_child) windows.CloseHandle(child);
        const info = componentInfo(child, path[start..end]) orelse return null;
        if (state.cloud == .refuse and recalls(info)) return null;
        if (info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
            var pinned: windows.HANDLE = undefined;
            if (create(name_w, parent, 0, .{ .no_follow = true, .read_data = last and read_data, .pin_reparse = true }, &pinned) != .SUCCESS) return null;
            const still_same = if (componentInfo(pinned, path[start..end])) |pinned_info|
                pinned_info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 and pinned_info.ReparseTag == info.ReparseTag
            else
                false;
            if (!still_same) {
                windows.CloseHandle(pinned);
                return null;
            }
            windows.CloseHandle(child);
            child = pinned;
            if (info.ReparseTag == windows.IO_REPARSE_TAG_SYMLINK or info.ReparseTag == windows.IO_REPARSE_TAG_MOUNT_POINT) {
                var buffer: [windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = @splat(0);
                windows.DeviceIoControl(child, windows.FSCTL_GET_REPARSE_POINT, null, &buffer) catch return null;
                const target = reparseTarget(alloc, &buffer, info.ReparseTag, path[0..start]) orelse return null;
                defer alloc.free(target);
                const joined = std.fs.path.resolve(alloc, &.{ target, path[if (last) end else end + 1..] }) catch return null;
                defer alloc.free(joined);
                // Keep the reparse handle alive while resolving its target.
                return walk(alloc, joined, read_data, depth + 1, state);
            }
            // Cloud tags differ only in their 4-bit variant field. They are
            // provider placeholders, not name-surrogate redirects. Reopen just
            // this component relative to the pinned parent, then verify locality.
            if (!isCloudTag(info.ReparseTag)) return null;
            if (builtin.is_test) test_cloud.reopened += 1;
            var hydrated: windows.HANDLE = undefined;
            if (create(name_w, parent, 0, .{ .read_data = last and read_data }, &hydrated) != .SUCCESS) return null;
            windows.CloseHandle(child);
            child = hydrated;
            if (!hasLocalFinalPath(child)) return null;
        }
        if (last) {
            own_child = false;
            return .{ .handle = child };
        }
        windows.CloseHandle(parent);
        parent = child;
        own_child = false;
        start = end + 1;
    }
    own_parent = false;
    return .{ .handle = parent };
}

fn attributeTag(handle: windows.HANDLE) ?windows.FILE_ATTRIBUTE_TAG_INFO {
    var info: windows.FILE_ATTRIBUTE_TAG_INFO = undefined;
    var io: windows.IO_STATUS_BLOCK = undefined;
    if (windows.ntdll.NtQueryInformationFile(handle, &io, &info, @sizeOf(@TypeOf(info)), .FileAttributeTagInformation) != .SUCCESS) return null;
    return info;
}

fn isCloudTag(tag: u32) bool {
    return tag & ~@as(u32, 0x0000f000) == IO_REPARSE_TAG_CLOUD;
}

/// A cloud placeholder, or anything else marked for recall from remote
/// storage: reading it (for some, opening it) fetches it from there first.
fn recalls(info: windows.FILE_ATTRIBUTE_TAG_INFO) bool {
    if (info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 and isCloudTag(info.ReparseTag)) return true;
    return info.FileAttributes & (windows.FILE_ATTRIBUTE_OFFLINE | windows.FILE_ATTRIBUTE_RECALL_ON_OPEN |
        windows.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS) != 0;
}

/// `attributeTag` for the component `name`, which `test_cloud` can make look
/// like a placeholder.
fn componentInfo(handle: windows.HANDLE, name: []const u8) ?windows.FILE_ATTRIBUTE_TAG_INFO {
    var info = attributeTag(handle) orelse return null;
    if (builtin.is_test) if (test_cloud.name) |cloud| if (std.mem.eql(u8, cloud, name)) {
        info.FileAttributes |= test_cloud.attributes;
        if (test_cloud.attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) info.ReparseTag = test_cloud.tag;
    };
    return info;
}

/// For tests: no real placeholder is made (that needs a sync provider). A
/// component named `name` reads as having `attributes` and `tag`, and
/// `reopened` counts the walk's opens of a placeholder as its provider
/// presents it, the open that can recall it.
pub const test_cloud = struct {
    pub var name: ?[]const u8 = null;
    pub var attributes: u32 = windows.FILE_ATTRIBUTE_REPARSE_POINT | windows.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;
    pub var tag: u32 = IO_REPARSE_TAG_CLOUD | 0x6000;
    pub var reopened: usize = 0;

    pub fn reset() void {
        name = null;
        attributes = windows.FILE_ATTRIBUTE_REPARSE_POINT | windows.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;
        tag = IO_REPARSE_TAG_CLOUD | 0x6000;
        reopened = 0;
    }
};

fn reparseTarget(alloc: Allocator, buffer: []const u8, tag: u32, parent: []const u8) ?[]u8 {
    // Validate the returned buffer before viewing its UTF-16 substitute name.
    if (buffer.len < 20 or std.mem.readInt(u32, buffer[0..4], .little) != tag) return null;
    const length: usize = std.mem.readInt(u16, buffer[4..6], .little);
    const offset: usize = std.mem.readInt(u16, buffer[8..10], .little);
    const name_len: usize = std.mem.readInt(u16, buffer[10..12], .little);
    const base: usize = if (tag == windows.IO_REPARSE_TAG_SYMLINK) 20 else 16;
    if (length + 8 > buffer.len or base + offset + name_len > length + 8 or (offset | name_len) & 1 != 0) return null;
    const name_w: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, buffer[base + offset ..][0..name_len]));
    const target = std.unicode.utf16LeToUtf8Alloc(alloc, name_w) catch return null;
    defer alloc.free(target);
    if (std.mem.indexOfScalar(u8, target, 0) != null) return null;
    const relative = tag == windows.IO_REPARSE_TAG_SYMLINK and std.mem.readInt(u32, buffer[16..20], .little) & windows.SYMLINK_FLAG_RELATIVE != 0;
    if (relative) {
        // Relative targets must not be rooted, drive-relative, streams or UNC.
        if (target.len == 0 or target[0] == '\\' or target[0] == '/' or std.mem.indexOfScalar(u8, target, ':') != null) return null;
        return std.fs.path.resolve(alloc, &.{ parent, target }) catch null;
    }
    const stripped = if (std.mem.startsWith(u8, target, "\\??\\")) target[4..] else target;
    if (os_path.isDriveAbsolutePath(stripped)) return alloc.dupe(u8, stripped) catch null;
    // Volume mount points (including volumes without a drive letter) use this
    // exact local-volume namespace. Other device/NT namespaces remain refused.
    if (tag == windows.IO_REPARSE_TAG_MOUNT_POINT and std.mem.startsWith(u8, stripped, "Volume{"))
        return std.fmt.allocPrint(alloc, "\\\\?\\{s}", .{stripped}) catch null;
    return null;
}

fn localRoot(path: []const u8) ?usize {
    var root_len: usize = undefined;
    if (os_path.isDriveAbsolutePath(path)) {
        root_len = 3;
        if (std.mem.indexOfScalar(u8, path[2..], ':') != null) return null;
    } else {
        if (path.len < 49 or !std.mem.startsWith(u8, path, "\\\\?\\Volume{") or path[47] != '}' or path[48] != '\\') return null;
        for (path[11..47], 0..) |ch, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (ch != '-') return null;
            } else if (!std.ascii.isHex(ch)) return null;
        }
        root_len = 49;
    }
    var root_w: [50:0]u16 = @splat(0);
    for (path[0..root_len], 0..) |ch, i| root_w[i] = ch;
    return switch (os_windows.GetDriveTypeW(&root_w)) {
        os_windows.DRIVE_FIXED, os_windows.DRIVE_REMOVABLE, os_windows.DRIVE_CDROM, os_windows.DRIVE_RAMDISK => root_len,
        else => null,
    };
}

fn hasLocalFinalPath(handle: windows.HANDLE) bool {
    var buffer: [windows.PATH_MAX_WIDE]u16 = undefined;
    // VOLUME_NAME_DOS normally gives a drive path. A mounted local volume may
    // have no drive letter; VOLUME_NAME_GUID still identifies its local root.
    var count = os_windows.GetFinalPathNameByHandleW(handle, &buffer, buffer.len, 0);
    if (count == 0) count = os_windows.GetFinalPathNameByHandleW(handle, &buffer, buffer.len, 1);
    if (count == 0 or count >= buffer.len) return false;
    const name = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, buffer[0..count]) catch return false;
    defer std.heap.page_allocator.free(name);
    const path = if (name.len >= 7 and os_path.isDriveAbsolutePath(name[4..]) and std.mem.startsWith(u8, name, "\\\\?\\")) name[4..] else name;
    return localRoot(path) != null;
}

/// For tests: links written as reparse data only (nothing follows them, so a
/// target that is a share is never contacted).
pub const test_links = struct {
    extern "kernel32" fn CreateSymbolicLinkW(link: [*:0]const u16, target: [*:0]const u16, flags: u32) callconv(.winapi) u8;
    const SYMBOLIC_LINK_FLAG_DIRECTORY = 0x1;
    const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2;

    /// A symlink at `link` (absolute) to `target`. False when the account may
    /// not make one (no SeCreateSymbolicLinkPrivilege and no Developer Mode).
    pub fn symlink(alloc: Allocator, link: []const u8, target: []const u8, is_dir: bool) !bool {
        const link_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, link);
        defer alloc.free(link_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, target);
        defer alloc.free(target_w);
        const flags: u32 = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE | (if (is_dir) @as(u32, SYMBOLIC_LINK_FLAG_DIRECTORY) else 0);
        if (CreateSymbolicLinkW(link_w, target_w, flags) != 0) return true;
        return switch (windows.kernel32.GetLastError()) {
            .PRIVILEGE_NOT_HELD => false,
            else => error.Unexpected,
        };
    }

    /// Make the empty folder `dir` (absolute) a junction to `nt_target`, an
    /// NT path such as `\??\UNC\host\share`. Needs no privilege.
    pub fn junction(alloc: Allocator, dir: []const u8, nt_target: []const u8) !void {
        var dir_w = try windows.sliceToPrefixedFileW(null, dir);
        const handle = try windows.OpenFile(dir_w.span(), .{
            .access_mask = windows.GENERIC_WRITE | windows.SYNCHRONIZE,
            .creation = windows.FILE_OPEN,
            .filter = .dir_only,
            .follow_symlinks = false,
        });
        defer windows.CloseHandle(handle);
        const target_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, nt_target);
        defer alloc.free(target_w);
        const target_bytes = target_w.len * 2;
        // REPARSE_DATA_BUFFER, MountPointReparseBuffer: the substitute name,
        // an empty print name, each NUL-terminated.
        const data_len = 8 + target_bytes + 2 + 2;
        const buffer = try alloc.alloc(u8, 8 + data_len);
        defer alloc.free(buffer);
        @memset(buffer, 0);
        std.mem.writeInt(u32, buffer[0..4], windows.IO_REPARSE_TAG_MOUNT_POINT, .little);
        std.mem.writeInt(u16, buffer[4..6], @intCast(data_len), .little);
        std.mem.writeInt(u16, buffer[10..12], @intCast(target_bytes), .little);
        std.mem.writeInt(u16, buffer[12..14], @intCast(target_bytes + 2), .little);
        @memcpy(buffer[16..][0..target_bytes], std.mem.sliceAsBytes(target_w));
        try windows.DeviceIoControl(handle, windows.FSCTL_SET_REPARSE_POINT, buffer, null);
    }
};

test "local path open refuses links to a share before opening them, and tells a missing file apart" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("real");
    try tmp.dir.writeFile(.{ .sub_path = "real\\config.ghostty", .data = "font-size = 15\n" });
    try tmp.dir.makeDir("to-share");
    try tmp.dir.makeDir("to-real");
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const at = struct {
        fn path(a: Allocator, root: []const u8, rel: []const u8) ![]u8 {
            return std.fs.path.join(a, &.{ root, rel });
        }
    };
    // Links to a share on TEST-NET-1 (RFC 5737), which no route reaches:
    // following one would hang on the connection, so each open is timed.
    const share = "\\\\192.0.2.1\\noctty-test-none$";
    const junction_dir = try at.path(alloc, base, "to-share");
    defer alloc.free(junction_dir);
    try test_links.junction(alloc, junction_dir, "\\??\\UNC\\192.0.2.1\\noctty-test-none$");
    const local_junction = try at.path(alloc, base, "to-real");
    defer alloc.free(local_junction);
    const real_dir = try at.path(alloc, base, "real");
    defer alloc.free(real_dir);
    const real_nt = try std.fmt.allocPrint(alloc, "\\??\\{s}", .{real_dir});
    defer alloc.free(real_nt);
    try test_links.junction(alloc, local_junction, real_nt);
    const file_link = try at.path(alloc, base, "file-to-share");
    defer alloc.free(file_link);
    const dir_link = try at.path(alloc, base, "dir-to-share");
    defer alloc.free(dir_link);
    const symlinks = try test_links.symlink(alloc, file_link, share ++ "\\config.ghostty", false) and
        try test_links.symlink(alloc, dir_link, share, true);
    if (!symlinks) std.log.warn("local path test: this account cannot make symlinks; the junction cases ran alone", .{});
    // The links go first, removed as links (never followed), so the tree's
    // cleanup never reaches the share.
    defer {
        tmp.dir.deleteDir("to-share") catch {};
        tmp.dir.deleteDir("to-real") catch {};
        tmp.dir.deleteFile("file-to-share") catch {};
        tmp.dir.deleteDir("dir-to-share") catch {};
    }

    const Case = struct { rel: []const u8, want: std.meta.Tag(Opened), symlink: bool = false };
    const cases = [_]Case{
        .{ .rel = "real\\config.ghostty", .want = .found },
        .{ .rel = "real\\absent.ghostty", .want = .missing },
        .{ .rel = "absent\\config.ghostty", .want = .missing },
        // A local junction is followed and checked.
        .{ .rel = "to-real\\config.ghostty", .want = .found },
        .{ .rel = "to-real\\absent.ghostty", .want = .missing },
        // An ancestor junction to a share.
        .{ .rel = "to-share\\config.ghostty", .want = .refused },
        // A file symlink and an ancestor directory symlink to a share.
        .{ .rel = "file-to-share", .want = .refused, .symlink = true },
        .{ .rel = "dir-to-share\\config.ghostty", .want = .refused, .symlink = true },
    };
    // Either cloud policy: `.refuse` walks every path and reads the file
    // through a second handle, which must find the same things.
    for (std.enums.values(Cloud)) |cloud| for (cases) |case| {
        if (case.symlink and !symlinks) continue;
        errdefer std.debug.print("local path open of {s} (cloud {t})\n", .{ case.rel, cloud });
        const path = try at.path(alloc, base, case.rel);
        defer alloc.free(path);
        var timer = try std.time.Timer.start();
        const opened = try open(alloc, path, .{ .data = true, .cloud = cloud });
        defer if (opened == .found) opened.found.deinit(alloc);
        try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
        try std.testing.expectEqual(case.want, std.meta.activeTag(opened));
        if (opened == .found) {
            try std.testing.expectEqualStrings(path, opened.found.path);
            var buf: [32]u8 = undefined;
            try std.testing.expectEqualStrings("font-size = 15\n", buf[0..try opened.found.file.readAll(&buf)]);
        }
    };
}

test "local path open refuses a path past PATH_MAX_WIDE before converting it" {
    const alloc = std.testing.allocator;
    // Zig 0.15.2 converts a path into a fixed buffer of PATH_MAX_WIDE units
    // without checking that it fits, and a longer name overflows the walk's
    // 16-bit name length: either panic ends the process.
    for ([_]usize{ windows.PATH_MAX_WIDE + 1, 40000 }) |len| {
        const path = try alloc.alloc(u8, len);
        defer alloc.free(path);
        @memset(path, 'a');
        @memcpy(path[0..3], "C:\\");
        for (std.enums.values(Cloud)) |cloud| {
            try std.testing.expectEqual(Opened.refused, try open(alloc, path, .{ .cloud = cloud }));
        }
    }

    // A path at the bound is looked at: the walk finds no such folder.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const path = try alloc.alloc(u8, windows.PATH_MAX_WIDE);
    defer alloc.free(path);
    @memset(path, 'a');
    _ = try std.fmt.bufPrint(path, "{s}\\absent\\", .{base});
    try std.testing.expectEqual(Opened.missing, try open(alloc, path, .{ .cloud = .refuse }));
}

test "local path open refuses a cloud placeholder before opening it as its provider presents it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("real");
    try tmp.dir.writeFile(.{ .sub_path = "real\\cloud.ghostty", .data = "font-size = 15\n" });
    try tmp.dir.makeDir("to-real");
    defer tmp.dir.deleteDir("to-real") catch {};
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const real_dir = try std.fs.path.join(alloc, &.{ base, "real" });
    defer alloc.free(real_dir);
    const junction_dir = try std.fs.path.join(alloc, &.{ base, "to-real" });
    defer alloc.free(junction_dir);
    const real_nt = try std.fmt.allocPrint(alloc, "\\??\\{s}", .{real_dir});
    defer alloc.free(real_nt);
    try test_links.junction(alloc, junction_dir, real_nt);
    defer test_cloud.reset();

    // A plain local file made to read as a placeholder. Behind a junction
    // the direct open stops at the link, so `.open` walks to it too.
    const Case = struct { name: []const u8, attributes: u32, rel: []const u8 };
    const placeholder = windows.FILE_ATTRIBUTE_REPARSE_POINT | windows.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS;
    for ([_]Case{
        .{ .name = "cloud.ghostty", .attributes = placeholder, .rel = "to-real\\cloud.ghostty" },
        .{ .name = "cloud.ghostty", .attributes = placeholder, .rel = "real\\cloud.ghostty" },
        // A placeholder folder on the way.
        .{ .name = "real", .attributes = windows.FILE_ATTRIBUTE_REPARSE_POINT | windows.FILE_ATTRIBUTE_RECALL_ON_OPEN, .rel = "to-real\\cloud.ghostty" },
        // Marked for recall without a cloud tag (another provider).
        .{ .name = "cloud.ghostty", .attributes = windows.FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS, .rel = "real\\cloud.ghostty" },
        .{ .name = "cloud.ghostty", .attributes = windows.FILE_ATTRIBUTE_OFFLINE, .rel = "real\\cloud.ghostty" },
    }) |case| {
        errdefer std.debug.print("local path open of {s} with {s} as a placeholder ({x})\n", .{ case.rel, case.name, case.attributes });
        test_cloud.reset();
        test_cloud.name = case.name;
        test_cloud.attributes = case.attributes;
        const path = try std.fs.path.join(alloc, &.{ base, case.rel });
        defer alloc.free(path);
        for ([_]bool{ true, false }) |data| {
            try std.testing.expectEqual(Opened.refused, try open(alloc, path, .{ .data = data, .cloud = .refuse }));
        }
        try std.testing.expectEqual(@as(usize, 0), test_cloud.reopened);
    }

    // `.open` (the link opener and the editor) still opens a placeholder as
    // its provider presents it.
    test_cloud.reset();
    test_cloud.name = "cloud.ghostty";
    const behind = try std.fs.path.join(alloc, &.{ base, "to-real\\cloud.ghostty" });
    defer alloc.free(behind);
    switch (try open(alloc, behind, .{ .data = true })) {
        .found => |found| found.deinit(alloc),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), test_cloud.reopened);
}

test "local path open maps DOS roots on production fast opens without fallback" {
    try testProductionDosMapping(.open);
}

test "local path open maps DOS roots on production walked opens without fallback" {
    // `.refuse` never opens the whole path at once: every name is walked.
    try testProductionDosMapping(.refuse);
}

fn testProductionDosMapping(cloud: Cloud) !void {
    const Reject = struct {
        fn map(_: [*:0]const u16, _: []u16) ?[]const u16 {
            return null;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "safe.txt", .data = "safe" });
    const path = try tmp.dir.realpathAlloc(alloc, "safe.txt");
    defer alloc.free(path);
    const how: How = .{ .data = true, .cloud = cloud };
    // Enter the actual production path, injecting only the OS device query.
    os_windows.TestHooks.direct_volume_mapping = Reject.map;
    defer os_windows.TestHooks.direct_volume_mapping = null;
    const refused = try open(alloc, path, how);
    defer if (refused == .found) refused.found.deinit(alloc);
    try std.testing.expect(refused != .found);
    // Consulting a mapped copy but opening the original DOS path must fail
    // too, even on Windows 11 where that original path would open normally.
    os_windows.TestHooks.direct_volume_mapping = os_windows.TestHooks.unavailableVolume;
    const redirected = try open(alloc, path, how);
    defer if (redirected == .found) redirected.found.deinit(alloc);
    try std.testing.expect(redirected != .found);
    os_windows.TestHooks.direct_volume_mapping = null;
    const opened = switch (try open(alloc, path, how)) {
        .found => |hit| hit,
        else => return error.TestUnexpectedResult,
    };
    defer opened.deinit(alloc);
    var data: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try opened.file.read(&data));
    try std.testing.expectEqualStrings("safe", &data);
}

test "local path open allows only the cloud reparse tag family" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("real");
    try tmp.dir.writeFile(.{ .sub_path = "real\\cloud.ghostty", .data = "" });
    try tmp.dir.makeDir("to-real");
    defer tmp.dir.deleteDir("to-real") catch {};
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    const real_dir = try std.fs.path.join(alloc, &.{ base, "real" });
    defer alloc.free(real_dir);
    const junction_dir = try std.fs.path.join(alloc, &.{ base, "to-real" });
    defer alloc.free(junction_dir);
    const real_nt = try std.fmt.allocPrint(alloc, "\\??\\{s}", .{real_dir});
    defer alloc.free(real_nt);
    try test_links.junction(alloc, junction_dir, real_nt);
    // Behind a junction `.open` walks to the name, which reads its tag.
    const path = try std.fs.path.join(alloc, &.{ base, "to-real\\cloud.ghostty" });
    defer alloc.free(path);
    defer test_cloud.reset();

    // Cloud tags differ only in their 4-bit variant field: each is reopened
    // as its provider presents it under `.open`, and refused under `.refuse`.
    for (0..16) |variant| {
        errdefer std.debug.print("local path open of a cloud tag variant {d}\n", .{variant});
        test_cloud.reset();
        test_cloud.name = "cloud.ghostty";
        test_cloud.tag = IO_REPARSE_TAG_CLOUD | (@as(u32, @intCast(variant)) << 12);
        switch (try open(alloc, path, .{})) {
            .found => |found| found.deinit(alloc),
            else => return error.TestUnexpectedResult,
        }
        try std.testing.expectEqual(@as(usize, 1), test_cloud.reopened);
        try std.testing.expectEqual(Opened.refused, try open(alloc, path, .{ .cloud = .refuse }));
    }
    // Any other tag on a file that is no link is refused, under either policy.
    for ([_]u32{ windows.IO_REPARSE_TAG_SYMLINK, windows.IO_REPARSE_TAG_MOUNT_POINT, 0x9000001b, 0x9001001a, 0xa000001a }) |tag| {
        errdefer std.debug.print("local path open of a reparse tag {x}\n", .{tag});
        test_cloud.reset();
        test_cloud.name = "cloud.ghostty";
        test_cloud.tag = tag;
        for (std.enums.values(Cloud)) |cloud| {
            try std.testing.expectEqual(Opened.refused, try open(alloc, path, .{ .cloud = cloud }));
        }
        try std.testing.expectEqual(@as(usize, 0), test_cloud.reopened);
    }
}

test "local path open walks local volume GUID mount targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("real");
    try tmp.dir.writeFile(.{ .sub_path = "real\\safe.txt", .data = "safe" });
    try tmp.dir.makeDir("by-volume");
    defer tmp.dir.deleteDir("by-volume") catch {};
    const base = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(base);
    // A junction to the folder by its volume's GUID, as a mount point names a
    // volume (`\??\Volume{...}\`): the walk reaches the folder through the
    // volume's own root, with no drive letter on the way.
    var real = try tmp.dir.openDir("real", .{});
    defer real.close();
    var wide: [windows.PATH_MAX_WIDE]u16 = undefined;
    const count = os_windows.GetFinalPathNameByHandleW(real.fd, &wide, wide.len, 1);
    try std.testing.expect(count > 0 and count < wide.len);
    const by_guid = try std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..count]);
    defer alloc.free(by_guid);
    try std.testing.expect(std.mem.startsWith(u8, by_guid, "\\\\?\\Volume{"));
    const guid_nt = try std.fmt.allocPrint(alloc, "\\??\\{s}", .{by_guid[4..]});
    defer alloc.free(guid_nt);
    const junction_dir = try std.fs.path.join(alloc, &.{ base, "by-volume" });
    defer alloc.free(junction_dir);
    try test_links.junction(alloc, junction_dir, guid_nt);

    const path = try std.fs.path.join(alloc, &.{ junction_dir, "safe.txt" });
    defer alloc.free(path);
    for (std.enums.values(Cloud)) |cloud| {
        errdefer std.debug.print("local path open through a volume GUID junction (cloud {t})\n", .{cloud});
        const opened = switch (try open(alloc, path, .{ .data = true, .cloud = cloud })) {
            .found => |hit| hit,
            else => return error.TestUnexpectedResult,
        };
        defer opened.deinit(alloc);
        var data: [4]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 4), try opened.file.read(&data));
        try std.testing.expectEqualStrings("safe", &data);
    }

    // The same file named by that volume path is refused as given: only a
    // drive path is taken, and no caller hands `open` another.
    const guid_file = try std.fs.path.join(alloc, &.{ by_guid, "safe.txt" });
    defer alloc.free(guid_file);
    try std.testing.expectEqual(Opened.refused, try open(alloc, guid_file, .{}));
}

test "local path open finds the name its folder stores" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "Mixed Case.txt", .data = "" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const spelled = try std.fs.path.join(alloc, &.{ root, "mixed case.TXT" });
    defer alloc.free(spelled);
    const found = switch (try open(alloc, spelled, .{})) {
        .found => |hit| hit,
        else => return error.TestUnexpectedResult,
    };
    defer found.deinit(alloc);
    const stored = found.storedName(alloc) orelse return error.TestUnexpectedResult;
    defer alloc.free(stored);
    try std.testing.expectEqualStrings("Mixed Case.txt", stored);

    // A pattern character never matches another entry: no such name opens.
    for ([_][]const u8{ "missing.txt", "*.txt", "Mixed Case.tx?", "Mixed Case<txt" }) |name| {
        errdefer std.debug.print("local path open of {s}\n", .{name});
        const path = try std.fs.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        const opened = try open(alloc, path, .{});
        defer if (opened == .found) opened.found.deinit(alloc);
        try std.testing.expect(opened != .found);
    }

    // A folder at a drive's root, whose parent is the root itself.
    const system_root = try std.process.getEnvVarOwned(alloc, "SystemRoot");
    defer alloc.free(system_root);
    const windows_dir = switch (try open(alloc, system_root, .{})) {
        .found => |hit| hit,
        else => return error.TestUnexpectedResult,
    };
    defer windows_dir.deinit(alloc);
    const windows_name = windows_dir.storedName(alloc) orelse return error.TestUnexpectedResult;
    defer alloc.free(windows_name);
    try std.testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.basename(system_root), windows_name));
}

/// `pwd(report)` is `want`.
fn expectPwd(want: []const u8, report: Report) !void {
    const alloc = std.testing.allocator;
    const got = pwd(alloc, report) catch |err| {
        std.debug.print("pwd of {s}: {t}\n", .{ switch (report) {
            inline else => |text| text,
        }, err });
        return err;
    };
    defer alloc.free(got);
    try std.testing.expectEqualStrings(want, got);
}

/// The raw path of an OSC 7 URL, decoded as the stream handler does.
fn testUrlPath(alloc: Allocator, url: []const u8) ![]const u8 {
    const uri = try @import("uri.zig").parse(url, .{
        .mac_address = false,
        .raw_path = std.mem.startsWith(u8, url, "kitty-shell-cwd://"),
    });
    return uri.path.toRawMaybeAlloc(alloc);
}

test "pwd keeps a file URI's drive path as a Windows path, with a single fallback allocator" {
    // `std.heap.stackFallback(...).get()` is single-use, so the decode and
    // `pwd` share the one allocator the stream handler takes from it.
    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    var stack_alloc = std.heap.stackFallback(1024, arena_alloc.allocator());
    const scratch = stack_alloc.get();
    const raw = try testUrlPath(scratch, "file://localhost/C:/Users/test/project");
    try std.testing.expectEqualStrings("C:\\Users\\test\\project", try pwd(scratch, .{ .url_path = raw }));
    try expectPwd("C:\\Users\\aman\\src", .{ .url_path = "/C:/Users/aman/src" });
}

test "pwd of an OSC 7 path keeps WSL and POSIX paths and refuses shares and devices" {
    const alloc = std.testing.allocator;
    for ([_]struct { []const u8, []const u8 }{
        .{ "kitty-shell-cwd://localhost/C:\\Users\\me", "C:\\Users\\me" },
        .{ "file://localhost/C:/Users/me", "C:\\Users\\me" },
        .{ "file://localhost/home/me", "/home/me" },
        .{ "kitty-shell-cwd://localhost/\\\\wsl.localhost\\Ubuntu\\home\\me", "/home/me" },
        // fish under MSYS2 reports `/c/...`; it stays POSIX (`linkTarget`
        // reads it back as `C:\...` outside WSL).
        .{ "file://localhost/c/Users/me", "/c/Users/me" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        try expectPwd(case[1], .{ .url_path = try testUrlPath(arena.allocator(), case[0]) });
    }
    // A UNC path carried in a URI loses the URI's `/`, so it is the share it
    // names and is refused; one into WSL is still the distro's own path.
    try expectPwd("/home/aman", .{ .url_path = "/\\\\wsl.localhost\\Ubuntu\\home\\aman" });
    try expectPwd("/home/aman/src", .{ .url_path = "/home/aman/src" });
    for ([_][]const u8{
        "/\\\\server\\share\\dir",
        "/\\\\server\\share",
        // Backslashes are legal in POSIX names, so `/\\server/share` stays the
        // POSIX path it spells, which is still a share's shape to Windows.
        "/\\\\server/share",
        "/\\\\server",
        "/\\\\server\\",
    }) |raw| try std.testing.expectError(error.NetworkOrDevicePath, pwd(alloc, .{ .url_path = raw }));

    // Every share and device spelling, after the URL's percent-decoding.
    for ([_][]const u8{
        "kitty-shell-cwd://localhost/\\\\server\\share",
        "kitty-shell-cwd://localhost/\\\\server\\share\\dir",
        "kitty-shell-cwd://localhost/\\\\?\\UNC\\server\\share\\dir",
        "kitty-shell-cwd://localhost/\\\\?\\C:\\Users\\me",
        "kitty-shell-cwd://localhost/\\\\.\\pipe\\x",
        "kitty-shell-cwd://localhost/\\\\.\\GLOBALROOT\\Device\\Mup\\server\\share",
        "kitty-shell-cwd://localhost/\\\\server/share",
        "kitty-shell-cwd://localhost//server/share",
        "kitty-shell-cwd://localhost/\\/server/share",
        "file://localhost/%5C%5Cserver%5Cshare",
        "file://localhost/%5C%5C%3F%5CUNC%5Cserver%5Cshare",
        "file://localhost/%5C%5C.%5Cpipe%5Cx",
        "file://localhost//server/share",
        "file://localhost/%2F%2Fserver/share",
        "file://localhost/%2F/server/share",
        "file://localhost/%5C/server/share",
        "file://localhost/%3F%3F/UNC/server/share",
        "file://localhost/%3F%3F/GLOBALROOT/Device/Mup/server/share",
        "kitty-shell-cwd://localhost//??/UNC/server/share",
    }) |url| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const raw = try testUrlPath(arena.allocator(), url);
        std.testing.expectError(error.NetworkOrDevicePath, pwd(arena.allocator(), .{ .url_path = raw })) catch |err| {
            std.debug.print("accepted: {s}\n", .{url});
            return err;
        };
    }
}

test "security regression pwd refuses percent-decoded control bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const raw = try testUrlPath(arena.allocator(), "file://localhost/C:/evil%00INJ=1%0Ab");
    try std.testing.expectError(error.UnsafeBytes, pwd(arena.allocator(), .{ .url_path = raw }));
    // DEL is the one control byte the OSC parser passes on.
    try std.testing.expectError(error.UnsafeBytes, pwd(std.testing.allocator, .{ .conemu = "C:\\a\x7fb" }));
    try std.testing.expectError(error.UnsafeBytes, pwd(std.testing.allocator, .{ .conemu = "C:\\a\x01b" }));
}

test "pwd reads the plain path of OSC 9;9" {
    for ([_]struct { []const u8, []const u8 }{
        .{ "C:\\Users\\aman\\src", "C:\\Users\\aman\\src" },
        // oh-my-posh quotes the path.
        .{ "\"C:\\Users\\aman\\src\"", "C:\\Users\\aman\\src" },
        .{ "\"C:\\Users\\test\\my project\"", "C:\\Users\\test\\my project" },
        // A path with spaces needs no quotes of its own.
        .{ "C:\\Program Files\\Git", "C:\\Program Files\\Git" },
        // A forward slash is the other separator, and the letter keeps its case.
        .{ "d:/work/noctty", "d:\\work\\noctty" },
        .{ "D:/work/noctty", "D:\\work\\noctty" },
        .{ "C:\\", "C:\\" },
        .{ "C:/", "C:\\" },
        // The UNC form `wslpath -w` prints is the distro's own path.
        .{ "\\\\wsl.localhost\\Ubuntu\\home\\aman\\src", "/home/aman/src" },
        .{ "\\\\wsl$\\Ubuntu\\home\\aman", "/home/aman" },
        .{ "\"\\\\wsl.localhost\\Ubuntu-24.04\\mnt\\data\"", "/mnt/data" },
        .{ "\\\\wsl.localhost\\Ubuntu", "/" },
    }) |case| try expectPwd(case[1], .{ .conemu = case[0] });
}

test "pwd leaves every OSC 9;9 value but a plain path to the URL parse" {
    for ([_][]const u8{
        // The URL forms, including the one noctty's cmd integration sends.
        "kitty-shell-cwd://localhost/C:\\Users\\aman",
        "file://localhost/C:/Users/aman",
        // Not drive-absolute, and not WSL's own UNC form: a share or device
        // path, which the URL parse then refuses.
        "",
        "\"\"",
        "C:",
        "C:Users",
        "C:Users\\me",
        "Users\\aman",
        "\\Users\\aman",
        "/mnt/c/Users",
        "\\\\server\\share",
        "\\\\server\\share\\dir",
        "\"\\\\server\\share\"",
        "\\\\server\\wsl.localhost\\share",
        "\\\\?\\C:\\Users\\me",
        "\\\\?\\UNC\\server\\share",
        "\\\\.\\pipe\\x",
        "\\\\.\\GLOBALROOT\\Device\\Mup\\server\\share",
        "//server/share",
        "\\\\wsl",
        // One pair of quotes only, and both of them.
        "\"\"C:\\Users\"\"",
        "\"C:\\Users",
        "C:\\Users\"",
    }) |value| std.testing.expectError(error.NotPlainPath, pwd(std.testing.allocator, .{ .conemu = value })) catch |err| {
        std.debug.print("taken: {s}\n", .{value});
        return err;
    };
}

/// `linkTarget(text, pane)` is `want`, or null when `want` is.
fn expectLinkTarget(want: ?[]const u8, text: []const u8, pane: Pane) !void {
    const alloc = std.testing.allocator;
    const got = try linkTarget(alloc, text, pane);
    defer if (got) |p| alloc.free(p);
    std.testing.expectEqualStrings(want orelse "(null)", got orelse "(null)") catch |err| {
        std.debug.print("link target of {s} (dir {s}, wsl {})\n", .{ text, pane.dir orelse "(none)", pane.wsl });
        return err;
    };
}

/// For tests: `windows_path` as MSYS2 prints it (`/c/x/y`), after `prefix`
/// (`/cygdrive` for Cygwin's form).
pub fn testMsysPath(alloc: Allocator, prefix: []const u8, windows_path: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/{c}{s}", .{
        prefix,
        std.ascii.toLower(windows_path[0]),
        windows_path[2..],
    });
    std.mem.replaceScalar(u8, path, '\\', '/');
    return path;
}

test "link target: text Windows cannot name gives null, and no text aborts" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    // Positive controls: near misses of the refused shapes are ordinary
    // names, found with and without a location. DEL is legal in a name.
    for ([_][]const u8{ "leaf\x7f", "nul1", "nulls.txt", "console", "com", "com10", "lpt", "aux1.txt", "...x", "a.b" }) |name| {
        try tmp.dir.writeFile(.{ .sub_path = name, .data = "" });
        const want = try std.fs.path.join(alloc, &.{ dir, name });
        defer alloc.free(want);
        const absolute = try std.fmt.allocPrint(alloc, "{s}:12", .{want});
        defer alloc.free(absolute);
        const relative = try std.fmt.allocPrint(alloc, "{s}(3,4)", .{name});
        defer alloc.free(relative);
        for ([_]bool{ false, true }) |wsl| {
            try expectLinkTarget(want, absolute, .{ .wsl = wsl });
            try expectLinkTarget(want, relative, .{ .dir = dir, .wsl = wsl });
        }
    }

    // A final name older Windows maps to a DOS device gives null even where
    // it is an ordinary file, as these are on Windows 11: `open` would find
    // them, and this is the one refusal it does not repeat.
    for ([_][]const u8{ "con", "Aux.log", "prn", "com9", "LPT1.txt", "nul.txt" }) |name| {
        try tmp.dir.writeFile(.{ .sub_path = name, .data = "" });
        const absolute = try std.fmt.allocPrint(alloc, "{s}\\{s}:12", .{ dir, name });
        defer alloc.free(absolute);
        const relative = try std.fmt.allocPrint(alloc, "{s}(1,2)", .{name});
        defer alloc.free(relative);
        for ([_]bool{ false, true }) |wsl| {
            try expectLinkTarget(null, absolute, .{ .wsl = wsl });
            try expectLinkTarget(null, relative, .{ .dir = dir, .wsl = wsl });
        }
    }

    // Each of these, as written and in the pane's directory, with a location
    // so the resolver looks: a ':' in a directory (a URL resolved against the
    // pwd), a wildcard, a C0 control, a stream (the open takes no ':' after
    // the drive), a stream on `.` or `..` or of only dots and spaces, and a
    // DOS device leaf (NT rejects them; `faccessatW` turned each rejection
    // into `unreachable`). None may abort, and none names a file.
    for ([_][]const u8{
        "https:\\example.com",
        "foo\\bar:baz\\qux",
        "a*b",
        "dir*x\\leaf",
        "bad\x01name\\leaf",
        "leaf\x1f",
        "file.txt:stream",
        "file.txt:str\x01eam",
        "magnet:?xt=urn",
        "a:",
        ":stream",
        "a:b:c",
        "magnet:?xt=urn:btih:0000",
        "file.txt:str\x00eam",
        "b:.",
        "b: ",
        "b:..",
        "b:. .",
        "b:x.",
        "b: x",
        "nul",
        "NUL",
        "nul.",
        "nul ",
        "nul.txt",
        "con",
        "Aux.log",
        "prn",
        "com1",
        "LPT9.txt",
        "conin$",
        "CONOUT$",
        ".:x",
        "..:a",
        "...:x",
        "a.:x",
    }) |name| {
        const absolute = try std.fmt.allocPrint(alloc, "{s}\\{s}:12", .{ dir, name });
        defer alloc.free(absolute);
        const relative = try std.fmt.allocPrint(alloc, "{s}(1,2)", .{name});
        defer alloc.free(relative);
        for ([_]bool{ false, true }) |wsl| {
            try expectLinkTarget(null, absolute, .{ .wsl = wsl });
            try expectLinkTarget(null, relative, .{ .dir = dir, .wsl = wsl });
        }
    }

    // Text longer than Windows can name, with a location so it is looked at
    // without one: Zig's path conversion would write past its buffer.
    const long = try alloc.alloc(u8, 40000);
    defer alloc.free(long);
    @memset(long, 'a');
    @memcpy(long[0..3], "C:\\");
    @memcpy(long[long.len - 3 ..], ":12");
    for ([_]bool{ false, true }) |wsl| try expectLinkTarget(null, long, .{ .wsl = wsl });

    // Shares and device paths, in every spelling `resolve` can leave, are
    // never looked at.
    for ([_][]const u8{
        "\\\\server\\share\\file:1",
        "//server/share/file:1",
        "\\\\?\\UNC\\server\\share\\file:1",
        "\\\\?\\C:\\Users\\me\\Documents:1",
        "\\\\.\\pipe\\x:1",
        "\\\\.\\GLOBALROOT\\Device\\Mup\\server\\share\\file:1",
    }) |text| for ([_]bool{ false, true }) |wsl| try expectLinkTarget(null, text, .{ .dir = dir, .wsl = wsl });
}

test "link target: link text resolves to the file it names, without its line and column" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "weird(1)", .data = "" });
    try tmp.dir.makePath("sub dir");
    try tmp.dir.writeFile(.{ .sub_path = "sub dir/b.zig", .data = "" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    // Text that is not MSYS2's reads the same in every pane.
    for ([_]bool{ false, true }) |wsl| {
        const Case = struct { text: []const u8, expect: ?[]const u8 };
        for ([_]Case{
            .{ .text = "a.txt", .expect = "a.txt" },
            .{ .text = ".\\a.txt", .expect = "a.txt" },
            .{ .text = "a.txt:12:5", .expect = "a.txt" },
            .{ .text = "a.txt:12", .expect = "a.txt" },
            .{ .text = "sub dir\\b.zig(3,4)", .expect = "sub dir\\b.zig" },
            .{ .text = "sub dir/b.zig:7", .expect = "sub dir\\b.zig" },
            .{ .text = "sub dir\\b.zig(12)", .expect = "sub dir\\b.zig" },
            // A name that ends like a location is tried whole first.
            .{ .text = "weird(1)", .expect = "weird(1)" },
            .{ .text = "missing.txt:1", .expect = null },
            .{ .text = "missing(3,4)", .expect = null },
            // Two location groups at most, and only digits make one.
            .{ .text = "a.txt:1:2:3", .expect = null },
            .{ .text = "a.txt:x", .expect = null },
            .{ .text = "a.txt(1,)", .expect = null },
            // A URL has no such file, and must not reach the filesystem as a path.
            .{ .text = "https://example.com/a:1", .expect = null },
        }) |case| {
            const want = if (case.expect) |name| try std.fs.path.join(alloc, &.{ dir, name }) else null;
            defer if (want) |p| alloc.free(p);
            try expectLinkTarget(want, case.text, .{ .dir = dir, .wsl = wsl });
        }
        // No directory, no relative link.
        try expectLinkTarget(null, "a.txt", .{ .wsl = wsl });

        // An absolute path is left to the opener unless a location has to go.
        for ([_][]const u8{ "a.txt", "weird(1)", "sub dir\\b.zig" }) |name| {
            const absolute = try std.fs.path.join(alloc, &.{ dir, name });
            defer alloc.free(absolute);
            try expectLinkTarget(null, absolute, .{ .dir = dir, .wsl = wsl });
        }
        for ([_]struct { name: []const u8, suffix: []const u8 }{
            .{ .name = "a.txt", .suffix = ":12:5" },
            .{ .name = "sub dir\\b.zig", .suffix = "(3,4)" },
        }) |case| {
            const text = try std.fmt.allocPrint(alloc, "{s}\\{s}{s}", .{ dir, case.name, case.suffix });
            defer alloc.free(text);
            const want = try std.fs.path.join(alloc, &.{ dir, case.name });
            defer alloc.free(want);
            try expectLinkTarget(want, text, .{ .wsl = wsl });
        }
        {
            const missing = try std.fmt.allocPrint(alloc, "{s}\\missing.txt:12", .{dir});
            defer alloc.free(missing);
            try expectLinkTarget(null, missing, .{ .wsl = wsl });
        }

        // Text a program can print must never abort the process: a location
        // can leave a stream of only dots and spaces (`b:.`), a DOS device
        // leaf, or a share whose second name is a lone separator, on which
        // `resolve` unwraps a null. None needs a file on disk.
        for ([_][]const u8{
            "/pkg42-nowhere/b:.:1",
            "C:\\pkg42-nowhere\\b: :12",
            "C:\\pkg42-nowhere\\b: (1,2)",
            "C:/pkg42-nowhere/./b:..:3",
            "C:\\pkg42-nowhere\\nul:12",
            "C:\\pkg42-nowhere\\nul(1,2)",
            "/pkg42-nowhere/nul:1",
            "C:\\pkg42-nowhere\\NUL.",
            // A path with no drive letter is the opener's to refuse.
            "/pkg42-nowhere/a.txt:1",
            "\\\\a\\/",
            "\\\\a\\/:12",
            "\\\\a\\/:12:5",
            "\\\\a\\/(3,4)",
            "//C/\\:12",
            "//./\\(3,4)",
        }) |text| try expectLinkTarget(null, text, .{ .wsl = wsl });
        // A stream on `.` or `..` is invalid to NT (and `resolve` keeps it), so
        // the whole text is never looked at; its location-less form is the
        // folder it names, which exists. Nothing may abort or leak.
        for ([_][]const u8{ "C:\\.:12", "C:/.:12", "C:\\\\.:12", "C:\\..:12" }) |text| {
            const got = try linkTarget(alloc, text, .{ .wsl = wsl });
            defer if (got) |p| alloc.free(p);
            if (got) |p| try std.testing.expectEqualStrings("C:\\", p);
        }
        // A drive-relative name has no sensible meaning against the pane's
        // directory, and `resolve` panics on one.
        for ([_][]const u8{
            "./b:.:1",
            "./b:.",
            "b: :12",
            ".\\b: (1,2)",
            "D:x",
            "b:x:12",
            "1:x",
            "_:x:12",
            "./nul",
            ".\\nul:3",
            "nul",
        }) |text| try expectLinkTarget(null, text, .{ .dir = dir, .wsl = wsl });
        for ([_][]const u8{ "./.:12", ".\\.:12", "..\\.:12", ".\\..:12" }) |text| {
            const got = try linkTarget(alloc, text, .{ .dir = dir, .wsl = wsl });
            if (got) |p| alloc.free(p);
        }
        // A share or device path is never looked at, with or without a location.
        for ([_][]const u8{
            "\\\\server\\share\\a.txt:1",
            "//server/share/a.txt:1",
            "\\\\?\\UNC\\server\\share\\a.txt(1,2)",
            "\\\\.\\pipe\\x:3",
        }) |text| try expectLinkTarget(null, text, .{ .wsl = wsl });
    }
}

test "link target: rooted text ignores the pane's directory" {
    const alloc = std.testing.allocator;
    const system_root = try std.process.getEnvVarOwned(alloc, "SystemRoot");
    defer alloc.free(system_root);
    if (!os_path.isDriveAbsolutePath(system_root)) return error.SkipZigTest;
    // Rooted text names the hosts file on the pane's drive; read against the
    // pane's directory, as relative text is, it would be found.
    const hosts = try std.fmt.allocPrint(alloc, "{s}\\System32\\drivers\\etc\\hosts", .{system_root});
    defer alloc.free(hosts);
    const users = try std.fmt.allocPrint(alloc, "{s}\\Users", .{system_root[0..2]});
    defer alloc.free(users);
    for ([_][]const u8{ "", ":12", "(3,4)" }) |suffix| {
        const rooted = try std.fmt.allocPrint(alloc, "{s}{s}", .{ hosts[2..], suffix });
        defer alloc.free(rooted);
        for ([_]bool{ false, true }) |wsl| try expectLinkTarget(null, rooted, .{ .dir = users, .wsl = wsl });
    }
    // Positive control: with its drive letter and a location it is found.
    const located = try std.fmt.allocPrint(alloc, "{s}:12", .{hosts});
    defer alloc.free(located);
    try expectLinkTarget(hosts, located, .{ .dir = users, .wsl = false });
}

test "link target: an MSYS2 or Cygwin drive path is the Windows path it names (#514)" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "" });
    try tmp.dir.makePath("conf.d");
    try tmp.dir.writeFile(.{ .sub_path = "conf.d/b.zig", .data = "" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    if (!os_path.isDriveAbsolutePath(dir)) return error.SkipZigTest;

    const Case = struct { prefix: []const u8 = "", text: []const u8, expect: []const u8 };
    for ([_]Case{
        // The reporter's case: `pwd` printed a folder.
        .{ .text = "conf.d", .expect = "conf.d" },
        .{ .text = "a.txt", .expect = "a.txt" },
        .{ .prefix = "/cygdrive", .text = "a.txt", .expect = "a.txt" },
        // A location comes off, as for the same path with a drive letter.
        .{ .text = "conf.d\\b.zig:12:5", .expect = "conf.d\\b.zig" },
        .{ .prefix = "/cygdrive", .text = "conf.d\\b.zig(3,4)", .expect = "conf.d\\b.zig" },
        // A missing file is still the Windows path, for the opener to refuse
        // as it refuses that path typed with a drive letter.
        .{ .text = "missing.txt", .expect = "missing.txt" },
        .{ .text = "missing.txt:12", .expect = "missing.txt:12" },
    }) |case| {
        const windows_text = try std.fs.path.join(alloc, &.{ dir, case.text });
        defer alloc.free(windows_text);
        const text = try testMsysPath(alloc, case.prefix, windows_text);
        defer alloc.free(text);
        const want = try std.fs.path.join(alloc, &.{ dir, case.expect });
        defer alloc.free(want);
        want[0] = std.ascii.toUpper(want[0]);
        try expectLinkTarget(want, text, .{ .wsl = false });
        // In WSL (and before #514) the text goes to the opener as written,
        // which refuses it.
        try expectLinkTarget(null, text, .{ .wsl = true });
    }

    // Only the form MSYS2 and Cygwin print; the drive is not checked, so a
    // letter that is no drive gives its Windows path for the opener to refuse.
    for ([_]struct { []const u8, []const u8 }{
        .{ "/c/Users/noctty-msys-test/.config/fish/conf.d", "C:\\Users\\noctty-msys-test\\.config\\fish\\conf.d" },
        .{ "/cygdrive/c/Users/noctty-msys-test", "C:\\Users\\noctty-msys-test" },
        .{ "/D/noctty-msys-test", "D:\\noctty-msys-test" },
        // A location stays on when nothing is there without it either.
        .{ "/c/noctty-msys-test/main.zig:12:5", "C:\\noctty-msys-test\\main.zig:12:5" },
        // A doubled separator never makes a share out of the rest.
        .{ "/c//server/share", "C:\\server\\share" },
        // `..` is fine while it stays below the drive's root.
        .{ "/c/noctty-msys-test/../y", "C:\\noctty-msys-test\\..\\y" },
        .{ "/c/.../noctty-msys-test", "C:\\...\\noctty-msys-test" },
    }) |case| {
        try expectLinkTarget(case[1], case[0], .{ .wsl = false });
        try std.testing.expect(isLocalShape(case[0], false));
    }

    // A relative link in a pane whose directory is an MSYS2 path (fish under
    // MSYS2 reports `/c/...` in its OSC 7) resolves against the Windows path.
    {
        const msys_dir = try testMsysPath(alloc, "", dir);
        defer alloc.free(msys_dir);
        const want = try std.fs.path.join(alloc, &.{ dir, "conf.d\\b.zig" });
        defer alloc.free(want);
        want[0] = std.ascii.toUpper(want[0]);
        try expectLinkTarget(want, "conf.d/b.zig:7", .{ .dir = msys_dir, .wsl = false });
        try expectLinkTarget(null, "conf.d/b.zig:7", .{ .dir = msys_dir, .wsl = true });
        // A Windows directory still works.
        const plain = try std.fs.path.join(alloc, &.{ dir, "a.txt" });
        defer alloc.free(plain);
        try expectLinkTarget(plain, "a.txt", .{ .dir = dir, .wsl = false });
    }

    // A drive's root is a directory a shell reports (`cd /c; pwd`), in every
    // spelling: a `.`, or a `..` back to the root.
    {
        const below_root = try std.fs.path.join(alloc, &.{ dir[3..], "a.txt" });
        defer alloc.free(below_root);
        const letter = std.ascii.toLower(dir[0]);
        for ([_][]const u8{ "/{c}", "/{c}/", "/cygdrive/{c}", "/cygdrive/{c}/", "/{c}/.", "/{c}/x/.." }) |form| {
            const root = try std.mem.replaceOwned(u8, alloc, form, "{c}", &.{letter});
            defer alloc.free(root);
            const got = try linkTarget(alloc, below_root, .{ .dir = root, .wsl = false });
            defer if (got) |p| alloc.free(p);
            const found: []const u8 = got orelse "C:\\(null)";
            std.testing.expect(std.ascii.eqlIgnoreCase(found[3..], below_root)) catch |err| {
                std.debug.print("pane directory {s}\n", .{root});
                return err;
            };
        }
    }

    // A drive's root is not read from link text: a lone `/c` is nearly always
    // a switch (`cmd /c "x"`, `findstr /c:x`, `xcopy /s /e`), and a `..` above
    // the drive is MSYS2's own root. The opener gets the text as written and
    // refuses it (#520 review).
    for ([_][]const u8{
        "/c",      "/C",        "/d",         "/s",    "/e",       "/c/",        "/cygdrive/c",    "/cygdrive/c/",
        "/c/x/..", "/c/..",     "/c/...",     "/c/.",  "/c/ .",    "/c/x/../..", "/c/x/../../y",   "/cygdrive/c/..",
        "/",       "/cygdrive", "/cygdrive/", "/cd/x", "/home/me", "/usr/bin",   "/cygdrive/cd/x", "/1/x",
        "/_/x",    "/C:/Users",
    }) |text| {
        try expectLinkTarget(null, text, .{ .wsl = false });
        try std.testing.expect(!isLocalShape(text, false));
    }

    // A letter that is no drive here is the Windows path too, which the opener
    // refuses; nothing is looked up for it.
    for ("BHJKMNOPQRSTUVWY") |letter| {
        if (os_windows.driveTypeForLetter(letter) != os_windows.DRIVE_NO_ROOT_DIR) continue;
        const text = try std.fmt.allocPrint(alloc, "/{c}/file.txt:3", .{std.ascii.toLower(letter)});
        defer alloc.free(text);
        const want = try std.fmt.allocPrint(alloc, "{c}:\\file.txt:3", .{letter});
        defer alloc.free(want);
        try expectLinkTarget(want, text, .{ .wsl = false });
        break;
    }

    // Shares, devices and rooted paths that are not drives stay as they are,
    // as text and as the pane's directory.
    for ([_][]const u8{
        "//server/share/a.txt",
        "//server/share/a.txt:1",
        "//c/share/a.txt",
        "/\\server\\share\\a.txt",
        "//?/UNC/server/share/a.txt",
        "//./pipe/x",
        "/home/me/a.txt",
        "/cd/a.txt:1",
        "/cygdrive/cd/a.txt",
        "\\c\\Users",
        "c/Users",
    }) |text| try expectLinkTarget(null, text, .{ .wsl = false });
    for ([_][]const u8{ "//server/share", "/\\server\\share", "//c/share", "//?/UNC/server/share", "\\\\.\\pipe\\x", "/home/me", "c/Users" }) |share| {
        try expectLinkTarget(null, "a.txt", .{ .dir = share, .wsl = false });
    }
}

test "link target: a link through a symlink to a share is never stat-ed" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.symLink("\\\\pkg42-no-such-host\\share", "link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest, // no symlink privilege
        else => return err,
    };
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    // `accessAbsolute` follows the link and waits on the (here nonexistent)
    // server on the calling thread; `open` refuses it first, which is also
    // why this has a bound.
    var timer = try std.time.Timer.start();
    for ([_][]const u8{ "link\\report.txt:12", "link/report.txt", "link\\sub\\a.cs(3,4)" }) |text| {
        try expectLinkTarget(null, text, .{ .dir = dir, .wsl = false });
        const absolute = try std.fs.path.join(alloc, &.{ dir, text });
        defer alloc.free(absolute);
        try expectLinkTarget(null, absolute, .{ .wsl = false });
    }
    try std.testing.expect(timer.read() < 2 * std.time.ns_per_s);
}

test "link target: a relative link never resolves onto a network or device pwd" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = "" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    for ([_]bool{ false, true }) |wsl| {
        for ([_][]const u8{
            "\\\\server\\share",
            "//server/share",
            "\\\\?\\UNC\\server\\share\\dir",
            "\\\\.\\pipe",
            "\\/server/share",
            "/\\\\server/share",
            // The NT namespace prefix is reachable from a reported pwd of
            // `/??/UNC/server/share`, which `resolve` turns into `\??\UNC\...`.
            "/??/UNC/server/share",
            "\\??\\UNC\\server\\share",
        }) |reported| try expectLinkTarget(null, "file.txt", .{ .dir = reported, .wsl = wsl });
        // A local pwd still resolves.
        const want = try std.fs.path.join(alloc, &.{ dir, "file.txt" });
        defer alloc.free(want);
        try expectLinkTarget(want, "file.txt", .{ .dir = dir, .wsl = wsl });
    }
}

test "link target: a pwd that is no absolute local path gives null and never aborts" {
    // `resolve` does not always return an absolute path (a pwd that opens
    // with `\/` comes back as `server\share\file.txt`), and it panics on a
    // base that is a drive with no root (`C:`, `b:x`) or a share whose second
    // name is the other separator (`\\a\/`).
    for ([_]bool{ false, true }) |wsl| for ([_][]const u8{
        "#x",
        "relative",
        "",
        "/\\\\server/share",
        "kitty-shell-cwd:",
        "\\/server/share",
        "/\\server\\share",
        "C:",
        "b:x",
        "1:x",
        "\\\\a\\/",
        "//a/\\",
    }) |reported| {
        try expectLinkTarget(null, "file.txt", .{ .dir = reported, .wsl = wsl });
        try expectLinkTarget(null, "file.txt:12", .{ .dir = reported, .wsl = wsl });
    };
}

test "link target: quick select's local shapes are the ones a click opens" {
    for ([_]bool{ false, true }) |wsl| {
        for ([_][]const u8{
            "C:\\work\\notes.txt",
            "c:/work/notes.txt",
            "C:\\work\\notes.txt:3:4",
            ".\\a.txt",
            "..\\a.txt",
            "src/config/url.zig",
            "src\\main.zig(12,5)",
            "src\\main.cs(12)",
            "src/main.zig:7",
            ".\\src\\main.zig:12:5",
            // Not a location, so the whole text is the path.
            "C:\\a\\x(foo)",
            "C:\\a\\x(1,)",
            "C:\\Program Files (x86)",
        }) |text| std.testing.expect(isLocalShape(text, wsl)) catch |err| {
            std.debug.print("shape of {s} (wsl {})\n", .{ text, wsl });
            return err;
        };

        for ([_][]const u8{
            "",
            "C:",
            "C:\\",
            "C:5",
            ":12",
            "\\\\server\\share\\x",
            "//server/share/x",
            "/\\server\\share\\x",
            "\\\\?\\C:\\x",
            "/Users/x",
            "/cd/x",
            // A drive's root never is, like `C:\` (#520 review): these are
            // switches far more often (`cmd /c`, `xcopy /s /e`).
            "/c",
            "/c/",
            "/cygdrive/c",
            "/c/..",
            "/c/x/..",
            "C:\\a\\b.txt:stream",
            "C:\\a\\b.zig:",
            "C:\\a\\b.zig:x",
            "/c/a/b.txt:stream",
            "a.zig:1:2:3",
            "https://example.com/a",
            "file:///C:/x",
            "notes.txt",
            "deadbeef",
            "192.168.1.10",
            "2001:db8::1",
        }) |text| std.testing.expect(!isLocalShape(text, wsl)) catch |err| {
            std.debug.print("shape of {s} (wsl {})\n", .{ text, wsl });
            return err;
        };
    }

    // An MSYS2 or Cygwin drive path is local only outside WSL (#514).
    for ([_][]const u8{ "/c/work/notes.txt", "/c/work/notes.txt:3:4", "/cygdrive/c/work", "/c/w" }) |text| {
        try std.testing.expect(isLocalShape(text, false));
        try std.testing.expect(!isLocalShape(text, true));
    }
}

/// The longest string a sweep builds.
const sweep_max_len = 16;

/// `each(context, s)` for every string `s` over `alphabet` of up to `max_len`
/// bytes, shortest first. Returns how many strings that was.
fn forEachString(alphabet: []const u8, max_len: usize, context: anytype, comptime each: anytype) !usize {
    if (max_len > sweep_max_len) return error.SweepTooLong;
    var text: [sweep_max_len]u8 = undefined;
    var indexes: [sweep_max_len]usize = undefined;
    var count: usize = 0;
    for (0..max_len + 1) |len| {
        @memset(indexes[0..len], 0);
        while (true) {
            for (indexes[0..len], 0..) |index, i| text[i] = alphabet[index];
            try each(context, text[0..len]);
            count += 1;
            var i = len;
            while (i > 0) : (i -= 1) {
                indexes[i - 1] += 1;
                if (indexes[i - 1] < alphabet.len) break;
                indexes[i - 1] = 0;
            } else break;
        }
    }
    return count;
}

/// `text`, bare and with each location suffix, through `isLocalShape` and
/// through `linkTarget` in each kind of pane against each of `dirs`.
fn sweepOne(dirs: []const ?[]const u8, text: []const u8) !void {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "", ":12", ":12:5", "(3,4)" }) |suffix| {
        var buf: [64]u8 = undefined;
        const full = try std.fmt.bufPrint(&buf, "{s}{s}", .{ text, suffix });
        for ([_]bool{ false, true }) |wsl| {
            _ = isLocalShape(full, wsl);
            // Absolute text ignores the directory: one pass is enough.
            const each = if (std.fs.path.isAbsolute(full)) dirs[0..1] else dirs;
            for (each) |base| {
                const got = try linkTarget(alloc, full, .{ .dir = base, .wsl = wsl });
                if (got) |p| alloc.free(p);
            }
        }
    }
}

/// The sets a sweep runs through `sweepOne`.
const SweepSizes = struct {
    /// Every string over the alphabet of up to this many bytes.
    length: usize,
    /// Every `url.regex` match, once, in every string over the alphabet of
    /// up to this many bytes (0: none).
    regex_length: usize = 0,
    /// The first `random` strings of up to `sweep_random_len` bytes drawn
    /// from `seed`, of which this run takes each one whose index is `part`
    /// modulo `parts`: runs that differ only in `part` split them.
    random: usize = 0,
    seed: u64 = 0x514,
    part: usize = 0,
    parts: usize = 1,
};

/// How many strings each set of a sweep took through `sweepOne`, and how
/// many strings the regex was searched in.
const SweepCount = struct { strings: usize, searched: usize = 0, matches: usize = 0, random: usize = 0 };

/// The longest random string a sweep draws.
const sweep_random_len = 8;

/// The sets of `sizes` over `alphabet` through `sweepOne` against no
/// directory, a tmp dir, a share and an MSYS root: no panic, no abort, no
/// leak (`std.testing.allocator`).
fn sweepLinkText(alphabet: []const u8, sizes: SweepSizes) !SweepCount {
    if (sizes.parts == 0 or sizes.part >= sizes.parts) return error.SweepPart;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const bases = [_]?[]const u8{ null, dir, "\\/server/share", "/c" };
    var count: SweepCount = .{
        .strings = try forEachString(alphabet, sizes.length, @as([]const ?[]const u8, &bases), sweepOne),
    };
    if (sizes.regex_length > 0) count.searched, count.matches = try sweepRegexMatches(alphabet, sizes.regex_length, &bases);
    var text: [sweep_random_len]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(sizes.seed);
    const r = prng.random();
    for (0..sizes.random) |i| {
        const len = r.uintAtMost(usize, sweep_random_len);
        for (text[0..len]) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        if (i % sizes.parts != sizes.part) continue;
        try sweepOne(&bases, text[0..len]);
        count.random += 1;
    }
    return count;
}

/// Every distinct `url.regex` match in every string over `alphabet` of up to
/// `max_len` bytes through `sweepOne`: the link text a click or quick select
/// on such a line can give. Each string is searched from its start and again
/// from the end of each match, as quick select does; the renderer searches
/// the rest of a line as a string of its own, a shorter string here. Returns
/// how many strings were searched and how many matches ran.
fn sweepRegexMatches(alphabet: []const u8, max_len: usize, dirs: []const ?[]const u8) !struct { usize, usize } {
    const oni = @import("oniguruma");
    const url = @import("../config/url.zig");
    const alloc = std.testing.allocator;
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(url.regex, .{}, oni.Encoding.utf8, oni.Syntax.default, null);
    defer re.deinit();
    // A match is a string over the alphabet too: one bit per such string,
    // at its number in bijective base `alphabet.len`, runs each match once
    // however many strings hold it.
    var digit = [_]usize{0} ** 256;
    for (alphabet, 1..) |c, d| digit[c] = d;
    var total: usize = 1;
    for (0..max_len) |_| total = try std.math.add(usize, try std.math.mul(usize, total, alphabet.len), 1);
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(alloc, total);
    defer seen.deinit(alloc);
    const Search = struct {
        re: *oni.Regex,
        region: oni.Region = .{},
        digit: *const [256]usize,
        base: usize,
        seen: *std.DynamicBitSetUnmanaged,
        dirs: []const ?[]const u8,
        matches: usize = 0,

        fn each(self: *@This(), text: []const u8) !void {
            var offset: usize = 0;
            while (offset < text.len) {
                _ = self.re.searchAdvanced(text, offset, text.len, &self.region, .{}) catch |err| switch (err) {
                    error.Mismatch => return,
                    else => return err,
                };
                const start: usize = @intCast(self.region.starts()[0]);
                const end: usize = @intCast(self.region.ends()[0]);
                if (end <= start) return;
                const match = text[start..end];
                var number: usize = 0;
                for (match) |c| number = number * self.base + self.digit[c];
                if (!self.seen.isSet(number)) {
                    self.seen.set(number);
                    try sweepOne(self.dirs, match);
                    self.matches += 1;
                }
                offset = end;
            }
        }
    };
    var search: Search = .{ .re = &re, .digit = &digit, .base = alphabet.len, .seen = &seen, .dirs = dirs };
    defer search.region.deinit();
    const searched = try forEachString(alphabet, max_len, &search, Search.each);
    return .{ searched, search.matches };
}

const sweep_alphabet = "Cc:\\/. nul<*?\"|\x01\x7f(1,)";

test "link target: no short text aborts or leaks" {
    _ = try sweepLinkText(sweep_alphabet, .{ .length = 3 });
}

test "link target: no short pane directory aborts or leaks" {
    // No directory makes `linkTarget` abort, and `Pane.dir` is whatever a
    // launch or a report left: every directory of up to 3 bytes over the
    // sweep's alphabet, under relative text with and without a location, in
    // both kinds of pane.
    const Each = struct {
        fn dir(_: void, base: []const u8) !void {
            const alloc = std.testing.allocator;
            for ([_][]const u8{ "a.txt", "a.txt:12", "..\\a(3,4)" }) |text| {
                for ([_]bool{ false, true }) |wsl| {
                    const got = try linkTarget(alloc, text, .{ .dir = base, .wsl = wsl });
                    if (got) |p| alloc.free(p);
                }
            }
        }
    };
    _ = try forEachString(sweep_alphabet, 3, {}, Each.dir);
}

test "link target: no text in the full sweep aborts or leaks" {
    // The PKG-42 sweep's sizes, rerun for every new path-to-filesystem seam:
    // hours, so only on request (`NOCTTY_RUN_LOCAL_PATH_SWEEP=1`). Its sets
    // are sized by `NOCTTY_LOCAL_PATH_SWEEP_LENGTH`, `_REGEX_LENGTH` and
    // `_RANDOM` (`SweepSizes`); `_SEED`, `_PART` and `_PARTS` let processes
    // split the random strings.
    const alloc = std.testing.allocator;
    const run = std.process.getEnvVarOwned(alloc, "NOCTTY_RUN_LOCAL_PATH_SWEEP") catch return error.SkipZigTest;
    defer alloc.free(run);
    if (!std.mem.eql(u8, run, "1")) return error.SkipZigTest;
    const Env = struct {
        fn number(a: Allocator, name: []const u8, default: usize) !usize {
            const value = std.process.getEnvVarOwned(a, name) catch return default;
            defer a.free(value);
            return std.fmt.parseInt(usize, value, 0);
        }
    };
    const sizes: SweepSizes = .{
        .length = try Env.number(alloc, "NOCTTY_LOCAL_PATH_SWEEP_LENGTH", 5),
        .regex_length = try Env.number(alloc, "NOCTTY_LOCAL_PATH_SWEEP_REGEX_LENGTH", 6),
        .random = try Env.number(alloc, "NOCTTY_LOCAL_PATH_SWEEP_RANDOM", 22_000_000),
        .seed = try Env.number(alloc, "NOCTTY_LOCAL_PATH_SWEEP_SEED", 0x514),
        .part = try Env.number(alloc, "NOCTTY_LOCAL_PATH_SWEEP_PART", 0),
        .parts = try Env.number(alloc, "NOCTTY_LOCAL_PATH_SWEEP_PARTS", 1),
    };
    const count = try sweepLinkText(sweep_alphabet, sizes);
    std.debug.print("local path sweep: {d} strings of up to {d} bytes; {d} url.regex matches in {d} strings of up to {d}; " ++
        "{d} random of {d} (seed 0x{x}, part {d} of {d})\n", .{
        count.strings, sizes.length, count.matches, count.searched, sizes.regex_length,
        count.random,  sizes.random, sizes.seed,    sizes.part,     sizes.parts,
    });
}
