//! A bounded open on a local drive, for the link opener, the editor and the
//! Settings config read: no unchecked reparse target is opened, including
//! targets reached through another local symlink, so nothing it opens
//! contacts a share.
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
