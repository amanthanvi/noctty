//! Bounded local-only handle lookup for the link opener, the editor and the
//! Settings config read. No unchecked reparse target is opened, including
//! targets reached through another local symlink.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const os_windows = @import("../../os/windows.zig");
const shell = @import("../../config/windows_shell.zig");
const sys = @import("sys.zig");

const OBJ_DONT_REPARSE = 0x1000;
const STATUS_REPARSE_POINT_ENCOUNTERED = 0xc000050b;
const IO_REPARSE_TAG_CLOUD = 0x9000001a;

pub fn open(alloc: std.mem.Allocator, path: []const u8, read_data: bool) ?std.fs.File {
    return switch (lookup(alloc, path, .{ .read_data = read_data })) {
        .file => |file| file,
        .missing, .refused => null,
    };
}

/// What a lookup does with a cloud-files placeholder (OneDrive and the like)
/// on the way.
pub const Cloud = enum {
    /// Open it as its provider presents it, which may first recall it from
    /// the provider. The link opener and the editor do.
    open,
    /// Refuse it, and anything else marked for recall from remote storage,
    /// before anything opens it in a way that could recall it: for a read on
    /// the UI thread, where a slow or offline provider would stall the window.
    refuse,
};

pub const Options = struct {
    /// Open the result to read its data, not only its attributes.
    read_data: bool = false,
    cloud: Cloud = .open,
};

/// What `lookup` found at a path.
pub const Lookup = union(enum) {
    /// The local file or directory, opened.
    file: std.fs.File,
    /// Nothing is there: the walk reached a local, verified folder in which
    /// the next name does not exist. No link was left unchecked to say so.
    missing,
    /// The path or a link on it leads somewhere that cannot be shown to be
    /// local (a share, a mapped drive, a device), or opening failed.
    refused,
};

/// `open`, telling a missing file from one that could not be opened as local.
pub fn lookup(alloc: std.mem.Allocator, path: []const u8, options: Options) Lookup {
    const root_len = localRoot(path) orelse return .refused;
    // Under `.refuse` there is no direct open: an open that follows no link
    // still reaches a placeholder's provider, which can recall it then.
    if (options.cloud == .open) {
        var wide = windows.sliceToPrefixedFileW(null, path) catch return .refused;
        // Windows 10 can reject the DOS drive alias itself under OBJ_DONT_REPARSE.
        // Resolve only that alias; all filesystem components retain the guard.
        if (root_len == 3 and !os_windows.directVolumePath(&wide)) return .refused;
        var handle: windows.HANDLE = undefined;
        const status = create(wide.span(), null, OBJ_DONT_REPARSE, .{ .read_data = options.read_data }, &handle);
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
    var state: Walk = .{ .cloud = options.cloud };
    const walk_data = options.read_data and options.cloud == .open;
    const file = walk(alloc, path, walk_data, 0, &state) orelse return if (state.not_found) .missing else .refused;
    if (!hasLocalFinalPath(file.handle)) {
        file.close();
        return .refused;
    }
    if (options.read_data and !walk_data) {
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

fn create(name_w: []const u16, parent: ?windows.HANDLE, attributes: u32, options: CreateOptions, handle: *windows.HANDLE) windows.NTSTATUS {
    var name: windows.UNICODE_STRING = .{
        .Length = @intCast(name_w.len * 2),
        .MaximumLength = @intCast(name_w.len * 2),
        .Buffer = @constCast(name_w.ptr),
    };
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

fn walk(alloc: std.mem.Allocator, path: []const u8, read_data: bool, depth: usize, state: *Walk) ?std.fs.File {
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

fn reparseTarget(alloc: std.mem.Allocator, buffer: []const u8, tag: u32, parent: []const u8) ?[]u8 {
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
    if (shell.isDriveAbsolutePath(stripped)) return alloc.dupe(u8, stripped) catch null;
    // Volume mount points (including volumes without a drive letter) use this
    // exact local-volume namespace. Other device/NT namespaces remain refused.
    if (tag == windows.IO_REPARSE_TAG_MOUNT_POINT and std.mem.startsWith(u8, stripped, "Volume{"))
        return std.fmt.allocPrint(alloc, "\\\\?\\{s}", .{stripped}) catch null;
    return null;
}

fn localRoot(path: []const u8) ?usize {
    var root_len: usize = undefined;
    if (shell.isDriveAbsolutePath(path)) {
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
    var count = sys.GetFinalPathNameByHandleW(handle, &buffer, buffer.len, 0);
    if (count == 0) count = sys.GetFinalPathNameByHandleW(handle, &buffer, buffer.len, 1);
    if (count == 0 or count >= buffer.len) return false;
    const name = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, buffer[0..count]) catch return false;
    defer std.heap.page_allocator.free(name);
    const path = if (name.len >= 7 and shell.isDriveAbsolutePath(name[4..]) and std.mem.startsWith(u8, name, "\\\\?\\")) name[4..] else name;
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
    pub fn symlink(alloc: std.mem.Allocator, link: []const u8, target: []const u8, is_dir: bool) !bool {
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
    pub fn junction(alloc: std.mem.Allocator, dir: []const u8, nt_target: []const u8) !void {
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

test "local target lookup refuses links to a share before opening them, and tells a missing file apart" {
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
        fn path(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
            return std.fs.path.join(a, &.{ root, rel });
        }
    };
    // Links to a share on TEST-NET-1 (RFC 5737), which no route reaches:
    // following one would hang on the connection, so each lookup is timed.
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
    if (!symlinks) std.log.warn("local target test: this account cannot make symlinks; the junction cases ran alone", .{});
    // The links go first, removed as links (never followed), so the tree's
    // cleanup never reaches the share.
    defer {
        tmp.dir.deleteDir("to-share") catch {};
        tmp.dir.deleteDir("to-real") catch {};
        tmp.dir.deleteFile("file-to-share") catch {};
        tmp.dir.deleteDir("dir-to-share") catch {};
    }

    const Case = struct { rel: []const u8, want: std.meta.Tag(Lookup), symlink: bool = false };
    const cases = [_]Case{
        .{ .rel = "real\\config.ghostty", .want = .file },
        .{ .rel = "real\\absent.ghostty", .want = .missing },
        .{ .rel = "absent\\config.ghostty", .want = .missing },
        // A local junction is followed and checked.
        .{ .rel = "to-real\\config.ghostty", .want = .file },
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
        errdefer std.debug.print("local target lookup of {s} (cloud {t})\n", .{ case.rel, cloud });
        const path = try at.path(alloc, base, case.rel);
        defer alloc.free(path);
        var timer = try std.time.Timer.start();
        const found = lookup(alloc, path, .{ .read_data = true, .cloud = cloud });
        defer if (found == .file) found.file.close();
        try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
        try std.testing.expectEqual(case.want, std.meta.activeTag(found));
        if (found == .file) {
            var buf: [32]u8 = undefined;
            try std.testing.expectEqualStrings("font-size = 15\n", buf[0..try found.file.readAll(&buf)]);
        }
    };
}

test "local target lookup refuses a cloud placeholder before opening it as its provider presents it" {
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
        errdefer std.debug.print("local target lookup of {s} with {s} as a placeholder ({x})\n", .{ case.rel, case.name, case.attributes });
        test_cloud.reset();
        test_cloud.name = case.name;
        test_cloud.attributes = case.attributes;
        const path = try std.fs.path.join(alloc, &.{ base, case.rel });
        defer alloc.free(path);
        for ([_]bool{ true, false }) |read_data| {
            try std.testing.expectEqual(Lookup.refused, lookup(alloc, path, .{ .read_data = read_data, .cloud = .refuse }));
        }
        try std.testing.expectEqual(@as(usize, 0), test_cloud.reopened);
    }

    // `.open` (the link opener and the editor, through `open`) still opens a
    // placeholder as its provider presents it.
    test_cloud.reset();
    test_cloud.name = "cloud.ghostty";
    const behind = try std.fs.path.join(alloc, &.{ base, "to-real\\cloud.ghostty" });
    defer alloc.free(behind);
    const opened = open(alloc, behind, true) orelse return error.TestUnexpectedResult;
    opened.close();
    try std.testing.expectEqual(@as(usize, 1), test_cloud.reopened);
}

test "link opener maps DOS roots on production fast opens without fallback" {
    try testProductionDosMapping(false);
}

test "link opener maps DOS roots on production walked opens without fallback" {
    try testProductionDosMapping(true);
}

fn testProductionDosMapping(comptime walked: bool) !void {
    const Reject = struct {
        fn map(_: [*:0]const u16, _: []u16) ?[]const u16 {
            return null;
        }
    };
    const Opener = struct {
        fn run(alloc: std.mem.Allocator, path: []const u8, state: *Walk) ?std.fs.File {
            return if (walked) walk(alloc, path, true, 0, state) else open(alloc, path, true);
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "safe.txt", .data = "safe" });
    const path = try tmp.dir.realpathAlloc(alloc, "safe.txt");
    defer alloc.free(path);
    var state: Walk = .{};
    // Enter the actual production path, injecting only the OS device query.
    os_windows.TestHooks.direct_volume_mapping = Reject.map;
    defer os_windows.TestHooks.direct_volume_mapping = null;
    const refused = Opener.run(alloc, path, &state);
    defer if (refused) |file| file.close();
    try std.testing.expectEqual(null, refused);
    // Consulting a mapped copy but opening the original DOS path must fail
    // too, even on Windows 11 where that original path would open normally.
    os_windows.TestHooks.direct_volume_mapping = os_windows.TestHooks.unavailableVolume;
    const redirected = Opener.run(alloc, path, &state);
    defer if (redirected) |file| file.close();
    try std.testing.expectEqual(null, redirected);
    os_windows.TestHooks.direct_volume_mapping = null;
    const opened = Opener.run(alloc, path, &state) orelse return error.TestUnexpectedResult;
    defer opened.close();
    var data: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try opened.read(&data));
    try std.testing.expectEqualStrings("safe", &data);
    try std.testing.expect(hasLocalFinalPath(opened.handle));
}

test "link opener allows only the cloud reparse tag family" {
    for (0..16) |variant| {
        try std.testing.expect(isCloudTag(IO_REPARSE_TAG_CLOUD | (@as(u32, @intCast(variant)) << 12)));
    }
    for ([_]u32{ windows.IO_REPARSE_TAG_SYMLINK, windows.IO_REPARSE_TAG_MOUNT_POINT, 0x9000001b, 0x9001001a, 0xa000001a }) |tag| {
        try std.testing.expect(!isCloudTag(tag));
    }
}

test "link opener walks local volume GUID mount targets" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "safe.txt", .data = "safe" });
    const file = try tmp.dir.openFile("safe.txt", .{});
    defer file.close();
    var wide: [windows.PATH_MAX_WIDE]u16 = undefined;
    const count = sys.GetFinalPathNameByHandleW(file.handle, &wide, wide.len, 1);
    try std.testing.expect(count > 0 and count < wide.len);
    const name = try std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..count]);
    defer alloc.free(name);
    const normalized = try std.fs.path.resolve(alloc, &.{ name, "" });
    defer alloc.free(normalized);
    try std.testing.expect(localRoot(normalized) != null);
    var state: Walk = .{};
    const opened = walk(alloc, normalized, false, 0, &state) orelse return error.TestUnexpectedResult;
    defer opened.close();
    try std.testing.expect(hasLocalFinalPath(opened.handle));
}
