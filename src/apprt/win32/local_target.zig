//! Bounded local-only handle lookup for the link opener. No unchecked reparse
//! target is opened, including targets reached through another local symlink.
const std = @import("std");
const windows = std.os.windows;
const os_windows = @import("../../os/windows.zig");
const shell = @import("../../config/windows_shell.zig");

const OBJ_DONT_REPARSE = 0x1000;
const STATUS_REPARSE_POINT_ENCOUNTERED = 0xc000050b;
const IO_REPARSE_TAG_CLOUD = 0x9000001a;

extern "kernel32" fn GetFinalPathNameByHandleW(handle: windows.HANDLE, path: [*]u16, size: u32, flags: u32) callconv(.winapi) u32;
extern "kernel32" fn QueryDosDeviceW(name: [*:0]const u16, target: [*]u16, size: u32) callconv(.winapi) u32;

pub fn open(alloc: std.mem.Allocator, path: []const u8, read_data: bool) ?std.fs.File {
    if (localRoot(path) == null) return null;
    const wide = windows.sliceToPrefixedFileW(null, path) catch return null;
    var handle: windows.HANDLE = undefined;
    const status = create(wide.span(), null, OBJ_DONT_REPARSE, false, read_data, false, &handle);
    if (status == .SUCCESS) return .{ .handle = handle };
    if (@intFromEnum(status) != STATUS_REPARSE_POINT_ENCOUNTERED) return null;

    // Walk relative to already opened parents. An absolute prefix-by-prefix
    // scan followed by a normal open would follow unchecked target chains and
    // could race into a share during that scan, before the final-path check.
    var remaining: usize = 256;
    const file = walk(alloc, path, read_data, 0, &remaining) orelse return null;
    if (!hasLocalFinalPath(file.handle)) {
        file.close();
        return null;
    }
    return file;
}

fn create(name_w: []const u16, parent: ?windows.HANDLE, attributes: u32, no_follow: bool, read_data: bool, pin_reparse: bool, handle: *windows.HANDLE) windows.NTSTATUS {
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
        windows.FILE_READ_ATTRIBUTES | windows.SYNCHRONIZE | (if (read_data) @as(u32, windows.FILE_READ_DATA) else 0),
        &attrs,
        &io,
        null,
        windows.FILE_ATTRIBUTE_NORMAL,
        // Pin only reparse objects against replacement and reparse-data writes.
        // Ordinary files (including actively written logs) retain shared access.
        if (pin_reparse) windows.FILE_SHARE_READ else windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        windows.FILE_OPEN,
        windows.FILE_SYNCHRONOUS_IO_NONALERT | (if (no_follow) @as(u32, windows.FILE_OPEN_REPARSE_POINT) else 0),
        null,
        0,
    );
}

fn walk(alloc: std.mem.Allocator, path: []const u8, read_data: bool, depth: usize, remaining: *usize) ?std.fs.File {
    if (depth >= 32) return null;
    const root_len = localRoot(path) orelse return null;
    var root_w = windows.sliceToPrefixedFileW(null, path[0..root_len]) catch return null;
    if (root_len == 49) {
        // OBJ_DONT_REPARSE rejects the mount manager's Volume{GUID} alias.
        // Read that mapping without opening it, accept only a direct volume
        // device name (no intermediate filesystem path), then keep the guard.
        var alias_w: [44:0]u16 = undefined;
        for (path[4..48], 0..) |ch, i| alias_w[i] = ch;
        alias_w[44] = 0;
        var device: [512]u16 = undefined;
        const count = QueryDosDeviceW(&alias_w, &device, device.len);
        if (count == 0 or count > device.len) return null;
        const end = std.mem.indexOfScalar(u16, device[0..count], 0) orelse return null;
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\");
        if (end <= prefix.len or !std.mem.startsWith(u16, device[0..end], prefix) or
            std.mem.indexOfAny(u16, device[prefix.len..end], &.{ '\\', '/', ':', '?' }) != null) return null;
        @memcpy(root_w.data[0..end], device[0..end]);
        root_w.data[end] = '\\';
        root_w.len = end + 1;
        root_w.data[root_w.len] = 0;
    }
    var parent: windows.HANDLE = undefined;
    if (create(root_w.span(), null, OBJ_DONT_REPARSE, true, false, false, &parent) != .SUCCESS) return null;
    var own_parent = true;
    defer if (own_parent) windows.CloseHandle(parent);
    if (root_len == 49) {
        var info: windows.FILE_ATTRIBUTE_TAG_INFO = undefined;
        var io: windows.IO_STATUS_BLOCK = undefined;
        if (windows.ntdll.NtQueryInformationFile(parent, &io, &info, @sizeOf(@TypeOf(info)), .FileAttributeTagInformation) != .SUCCESS or
            info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 or !hasLocalFinalPath(parent)) return null;
    }
    var start = root_len;
    while (start < path.len) {
        if (remaining.* == 0) return null;
        remaining.* -= 1;
        const end = if (std.mem.indexOfScalarPos(u8, path, start, '\\')) |i| i else path.len;
        const last = end == path.len;
        const name_w = std.unicode.utf8ToUtf16LeAlloc(alloc, path[start..end]) catch return null;
        defer alloc.free(name_w);
        var child: windows.HANDLE = undefined;
        if (create(name_w, parent, 0, true, last and read_data, false, &child) != .SUCCESS) return null;
        var own_child = true;
        defer if (own_child) windows.CloseHandle(child);
        var info: windows.FILE_ATTRIBUTE_TAG_INFO = undefined;
        var io: windows.IO_STATUS_BLOCK = undefined;
        if (windows.ntdll.NtQueryInformationFile(child, &io, &info, @sizeOf(@TypeOf(info)), .FileAttributeTagInformation) != .SUCCESS) return null;
        if (info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT != 0) {
            var pinned: windows.HANDLE = undefined;
            if (create(name_w, parent, 0, true, last and read_data, true, &pinned) != .SUCCESS) return null;
            var pinned_info: windows.FILE_ATTRIBUTE_TAG_INFO = undefined;
            if (windows.ntdll.NtQueryInformationFile(pinned, &io, &pinned_info, @sizeOf(@TypeOf(pinned_info)), .FileAttributeTagInformation) != .SUCCESS or
                pinned_info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT == 0 or pinned_info.ReparseTag != info.ReparseTag)
            {
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
                return walk(alloc, joined, read_data, depth + 1, remaining);
            }
            // Cloud tags differ only in their 4-bit variant field. They are
            // provider placeholders, not name-surrogate redirects. Reopen just
            // this component relative to the pinned parent, then verify locality.
            if (!isCloudTag(info.ReparseTag)) return null;
            var hydrated: windows.HANDLE = undefined;
            if (create(name_w, parent, 0, false, last and read_data, false, &hydrated) != .SUCCESS) return null;
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

fn isCloudTag(tag: u32) bool {
    return tag & ~@as(u32, 0x0000f000) == IO_REPARSE_TAG_CLOUD;
}

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
    var count = GetFinalPathNameByHandleW(handle, &buffer, buffer.len, 0);
    if (count == 0) count = GetFinalPathNameByHandleW(handle, &buffer, buffer.len, 1);
    if (count == 0 or count >= buffer.len) return false;
    const name = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, buffer[0..count]) catch return false;
    defer std.heap.page_allocator.free(name);
    const path = if (name.len >= 7 and shell.isDriveAbsolutePath(name[4..]) and std.mem.startsWith(u8, name, "\\\\?\\")) name[4..] else name;
    return localRoot(path) != null;
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
    const count = GetFinalPathNameByHandleW(file.handle, &wide, wide.len, 1);
    try std.testing.expect(count > 0 and count < wide.len);
    const name = try std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..count]);
    defer alloc.free(name);
    const normalized = try std.fs.path.resolve(alloc, &.{ name, "" });
    defer alloc.free(normalized);
    try std.testing.expect(localRoot(normalized) != null);
    var remaining: usize = 256;
    const opened = walk(alloc, normalized, false, 0, &remaining) orelse return error.TestUnexpectedResult;
    defer opened.close();
    try std.testing.expect(hasLocalFinalPath(opened.handle));
}
