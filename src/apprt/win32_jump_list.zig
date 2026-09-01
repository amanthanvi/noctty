//! Taskbar jump list: a "Recent" category of working directories and a
//! "Profiles" category of detected shells.
//!
//! Recent entries come from the terminal's pwd stream, which means a program
//! running inside a session can emit OSC 7 for any path it likes and seed a
//! persistent, user-visible entry. That is inherent to the data source and the
//! blast radius is small (activating an entry only sets noctty's working
//! directory), but titles are rendered by the shell, so `buildTitleAlloc`
//! strips Unicode bidi/isolate controls to keep a seeded entry from
//! misrepresenting where it points.

const std = @import("std");
const windows = std.os.windows;
const windows_shell = @import("../config/windows_shell.zig");
const windows_ssh_hosts = @import("../config/windows_ssh_hosts.zig");
const Command = @import("../config/command.zig").Command;
const win32_aumid = @import("win32_aumid.zig");
const persistence = @import("win32_session_persistence.zig");
const sys = @import("win32/sys.zig");

const Allocator = std.mem.Allocator;
const DWORD = u32;
const HRESULT = windows.HRESULT;
const GUID = windows.GUID;
const HWND = ?*anyopaque;
const UINT = u32;
const UINT_PTR = usize;
const WORD = u16;

const log = std.log.scoped(.win32_jump_list);

pub const state_filename = "jump-list-recents.json";
pub const max_recents: usize = 10;
pub const max_state_bytes: usize = 64 * 1024;
pub const debounce_ms: UINT = 500;
const max_profile_tombstones: usize = 128;
const max_profile_events: usize = max_profile_tombstones * 2;
const max_rebuild_retries: u8 = 3;
const max_shell_link_chars: usize = 32_768;
const profile_description_prefix = "noctty-profile:";

const CLSCTX_INPROC_SERVER: DWORD = 0x1;
const CO_E_NOTINITIALIZED: HRESULT = @bitCast(@as(u32, 0x800401F0));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const VT_LPWSTR: u16 = 31;

const CLSID_DestinationList = GUID.parse("{77F10CF0-3DB5-4966-B520-B7C54FD35ED6}");
const IID_ICustomDestinationList = GUID.parse("{6332DEBF-87B5-4670-90C0-5E57B408A49E}");
const CLSID_EnumerableObjectCollection = GUID.parse("{2D3468C1-36A7-43B6-AC24-D3F02FD9607A}");
const IID_IObjectCollection = GUID.parse("{5632B1A4-E38A-400A-928A-D4CD63230295}");
const IID_IObjectArray = GUID.parse("{92CA9DCD-5622-4BBA-A805-5E9F541BD8C9}");
const CLSID_ShellLink = GUID.parse("{00021401-0000-0000-C000-000000000046}");
const IID_IShellLinkW = GUID.parse("{000214F9-0000-0000-C000-000000000046}");
const IID_IPropertyStore = GUID.parse("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}");

const PROPERTYKEY = extern struct {
    fmtid: GUID,
    pid: DWORD,
};

const PKEY_Title = PROPERTYKEY{
    .fmtid = GUID.parse("{F29F85E0-4FF9-1068-AB91-08002B27B3D9}"),
    .pid = 2,
};
const PKEY_AppUserModel_ID = PROPERTYKEY{
    .fmtid = GUID.parse("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"),
    .pid = 5,
};

const PROPVARIANT = extern struct {
    vt: u16,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    value: extern union {
        pwsz: [*:0]const u16,
        raw: [2]usize,
    },

    fn fromString(value: [:0]const u16) PROPVARIANT {
        return .{
            .vt = VT_LPWSTR,
            .value = .{ .pwsz = value.ptr },
        };
    }
};

// Aliased from the shared Win32 surface rather than re-declared, so this
// module cannot drift from src/apprt/win32/sys.zig.
const CoCreateInstance = sys.CoCreateInstance;
const GetCurrentProcessId = sys.GetCurrentProcessId;
const SetTimer = sys.SetTimer;
const KillTimer = sys.KillTimer;

// Only this module needs ordinal string comparison, so it stays local.
extern "kernel32" fn CompareStringOrdinal(
    [*]const u16,
    i32,
    [*]const u16,
    i32,
    i32,
) callconv(.winapi) i32;

const IObjectArrayVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetCount: *const fn (*anyopaque, *UINT) callconv(.winapi) HRESULT,
    GetAt: *const fn (*anyopaque, UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
};

const IObjectArray = extern struct {
    vtbl: *const IObjectArrayVtbl,

    fn fromRaw(raw: *anyopaque) *IObjectArray {
        return @ptrCast(@alignCast(raw));
    }

    fn asRaw(self: *IObjectArray) *anyopaque {
        return @ptrCast(self);
    }

    fn release(self: *IObjectArray) void {
        _ = self.vtbl.Release(self.asRaw());
    }
};

const IObjectCollectionVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetCount: *const fn (*anyopaque, *UINT) callconv(.winapi) HRESULT,
    GetAt: *const fn (*anyopaque, UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddObject: *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT,
    AddFromArray: *const fn (*anyopaque, *IObjectArray) callconv(.winapi) HRESULT,
    RemoveObjectAt: *const fn (*anyopaque, UINT) callconv(.winapi) HRESULT,
    Clear: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

const IObjectCollection = extern struct {
    vtbl: *const IObjectCollectionVtbl,

    fn fromRaw(raw: *anyopaque) *IObjectCollection {
        return @ptrCast(@alignCast(raw));
    }

    fn asRaw(self: *IObjectCollection) *anyopaque {
        return @ptrCast(self);
    }

    fn asArray(self: *IObjectCollection) *IObjectArray {
        return @ptrCast(self);
    }

    fn release(self: *IObjectCollection) void {
        _ = self.vtbl.Release(self.asRaw());
    }

    fn addObject(self: *IObjectCollection, object: *anyopaque) HRESULT {
        return self.vtbl.AddObject(self.asRaw(), object);
    }
};

const ICustomDestinationListVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    SetAppID: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    BeginList: *const fn (*anyopaque, *UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AppendCategory: *const fn (*anyopaque, [*:0]const u16, *IObjectArray) callconv(.winapi) HRESULT,
    AppendKnownCategory: *const fn (*anyopaque, i32) callconv(.winapi) HRESULT,
    AddUserTasks: *const fn (*anyopaque, *IObjectArray) callconv(.winapi) HRESULT,
    CommitList: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    GetRemovedDestinations: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    DeleteList: *const fn (*anyopaque, ?[*:0]const u16) callconv(.winapi) HRESULT,
    AbortList: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

const ICustomDestinationList = extern struct {
    vtbl: *const ICustomDestinationListVtbl,

    fn fromRaw(raw: *anyopaque) *ICustomDestinationList {
        return @ptrCast(@alignCast(raw));
    }

    fn asRaw(self: *ICustomDestinationList) *anyopaque {
        return @ptrCast(self);
    }

    fn release(self: *ICustomDestinationList) void {
        _ = self.vtbl.Release(self.asRaw());
    }
};

const IShellLinkWVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetPath: *const fn (*anyopaque, [*]u16, i32, ?*anyopaque, DWORD) callconv(.winapi) HRESULT,
    GetIDList: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    SetIDList: *const fn (*anyopaque, ?*const anyopaque) callconv(.winapi) HRESULT,
    GetDescription: *const fn (*anyopaque, [*]u16, i32) callconv(.winapi) HRESULT,
    SetDescription: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetWorkingDirectory: *const fn (*anyopaque, [*]u16, i32) callconv(.winapi) HRESULT,
    SetWorkingDirectory: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetArguments: *const fn (*anyopaque, [*]u16, i32) callconv(.winapi) HRESULT,
    SetArguments: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
    GetHotkey: *const fn (*anyopaque, *WORD) callconv(.winapi) HRESULT,
    SetHotkey: *const fn (*anyopaque, WORD) callconv(.winapi) HRESULT,
    GetShowCmd: *const fn (*anyopaque, *i32) callconv(.winapi) HRESULT,
    SetShowCmd: *const fn (*anyopaque, i32) callconv(.winapi) HRESULT,
    GetIconLocation: *const fn (*anyopaque, [*]u16, i32, *i32) callconv(.winapi) HRESULT,
    SetIconLocation: *const fn (*anyopaque, [*:0]const u16, i32) callconv(.winapi) HRESULT,
    SetRelativePath: *const fn (*anyopaque, [*:0]const u16, DWORD) callconv(.winapi) HRESULT,
    Resolve: *const fn (*anyopaque, HWND, DWORD) callconv(.winapi) HRESULT,
    SetPath: *const fn (*anyopaque, [*:0]const u16) callconv(.winapi) HRESULT,
};

const IShellLinkW = extern struct {
    vtbl: *const IShellLinkWVtbl,

    fn fromRaw(raw: *anyopaque) *IShellLinkW {
        return @ptrCast(@alignCast(raw));
    }

    fn asRaw(self: *IShellLinkW) *anyopaque {
        return @ptrCast(self);
    }

    fn release(self: *IShellLinkW) void {
        _ = self.vtbl.Release(self.asRaw());
    }
};

const IPropertyStoreVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
    GetCount: *const fn (*anyopaque, *DWORD) callconv(.winapi) HRESULT,
    GetAt: *const fn (*anyopaque, DWORD, *PROPERTYKEY) callconv(.winapi) HRESULT,
    GetValue: *const fn (*anyopaque, *const PROPERTYKEY, *PROPVARIANT) callconv(.winapi) HRESULT,
    SetValue: *const fn (*anyopaque, *const PROPERTYKEY, *const PROPVARIANT) callconv(.winapi) HRESULT,
    Commit: *const fn (*anyopaque) callconv(.winapi) HRESULT,
};

const IPropertyStore = extern struct {
    vtbl: *const IPropertyStoreVtbl,

    fn fromRaw(raw: *anyopaque) *IPropertyStore {
        return @ptrCast(@alignCast(raw));
    }

    fn asRaw(self: *IPropertyStore) *anyopaque {
        return @ptrCast(self);
    }

    fn release(self: *IPropertyStore) void {
        _ = self.vtbl.Release(self.asRaw());
    }

    fn setValue(self: *IPropertyStore, key: *const PROPERTYKEY, value: *const PROPVARIANT) HRESULT {
        return self.vtbl.SetValue(self.asRaw(), key, value);
    }
};

const RecentState = struct {
    schema_version: u32 = 1,
    directories: []const []const u8 = &.{},
    removed_directories: []const []const u8 = &.{},
    hidden_profiles: []const []const u8 = &.{},
    recent_events: []const RecentEvent = &.{},
    profile_events: []const ProfileEvent = &.{},
};

const RecentEventKind = enum {
    used,
    removed,
};

const RecentEvent = struct {
    path: []const u8,
    kind: RecentEventKind,
    changed_ns: i64,
};

const ProfileEventKind = enum {
    hidden,
    used,
};

const ProfileEvent = struct {
    key: []const u8,
    kind: ProfileEventKind,
    changed_ns: i64,
};

const VersionHeader = struct {
    schema_version: u32,
};

fn parseRecentStateAlloc(alloc: Allocator, raw: []const u8) !std.json.Parsed(RecentState) {
    var header = try std.json.parseFromSlice(VersionHeader, alloc, raw, .{
        .ignore_unknown_fields = true,
    });
    defer header.deinit();
    if (header.value.schema_version != 1) return error.UnsupportedVersion;

    return try std.json.parseFromSlice(RecentState, alloc, raw, .{
        .ignore_unknown_fields = false,
    });
}

fn encodeRecentStateAlloc(
    alloc: Allocator,
    directories: []const []const u8,
    removed_directories: []const []const u8,
    hidden_profiles: []const []const u8,
    recent_events: []const RecentEvent,
    profile_events: []const ProfileEvent,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(RecentState{
        .directories = directories,
        .removed_directories = removed_directories,
        .hidden_profiles = hidden_profiles,
        .recent_events = recent_events,
        .profile_events = profile_events,
    }, .{
        .whitespace = .minified,
    }, &out.writer);
    if (out.written().len > max_state_bytes) return error.StateTooLarge;
    return try out.toOwnedSlice();
}

const RecentList = struct {
    items: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *RecentList, alloc: Allocator) void {
        for (self.items.items) |item| alloc.free(item);
        self.items.deinit(alloc);
        self.* = .{};
    }

    fn insert(self: *RecentList, alloc: Allocator, path: []const u8) !bool {
        if (!isRecentLocalPath(path)) return false;
        const normalized = try normalizeRecentPathAlloc(alloc, path);
        var normalized_owned = true;
        defer if (normalized_owned) alloc.free(normalized);

        for (self.items.items, 0..) |item, index| {
            if (!try pathsEqualIgnoreCase(alloc, item, normalized)) continue;
            if (index == 0) return false;
            var i = index;
            while (i > 0) : (i -= 1) self.items.items[i] = self.items.items[i - 1];
            self.items.items[0] = item;
            return true;
        }

        if (self.items.items.len < max_recents) {
            try self.items.append(alloc, normalized);
        } else {
            alloc.free(self.items.items[max_recents - 1]);
        }

        var i = @min(self.items.items.len, max_recents) - 1;
        while (i > 0) : (i -= 1) self.items.items[i] = self.items.items[i - 1];
        self.items.items[0] = normalized;
        normalized_owned = false;
        return true;
    }

    fn appendLoaded(self: *RecentList, alloc: Allocator, path: []const u8) !void {
        if (self.items.items.len >= max_recents or !isRecentLocalPath(path)) return;
        const normalized = try normalizeRecentPathAlloc(alloc, path);
        errdefer alloc.free(normalized);
        for (self.items.items) |item| {
            if (try pathsEqualIgnoreCase(alloc, item, normalized)) {
                alloc.free(normalized);
                return;
            }
        }
        try self.items.append(alloc, normalized);
    }

    fn contains(self: *const RecentList, alloc: Allocator, path: []const u8) !bool {
        for (self.items.items) |item| {
            if (try pathsEqualIgnoreCase(alloc, item, path)) return true;
        }
        return false;
    }

    fn removePath(self: *RecentList, alloc: Allocator, path: []const u8) !bool {
        for (self.items.items, 0..) |item, index| {
            if (!try pathsEqualIgnoreCase(alloc, item, path)) continue;
            alloc.free(item);
            _ = self.items.orderedRemove(index);
            return true;
        }
        return false;
    }

    fn removeArguments(
        self: *RecentList,
        alloc: Allocator,
        removed_arguments: []const []const u8,
        protected: *const RecentList,
        pending_removals: *RecentList,
    ) !bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.items.items.len) {
            const arguments = try buildWorkingDirectoryArgumentsAlloc(alloc, self.items.items[index]);
            defer alloc.free(arguments);
            if (!containsArguments(removed_arguments, arguments)) {
                index += 1;
                continue;
            }

            if (try protected.contains(alloc, self.items.items[index])) {
                index += 1;
                continue;
            }

            _ = try pending_removals.insert(alloc, self.items.items[index]);
            alloc.free(self.items.items[index]);
            _ = self.items.orderedRemove(index);
            changed = true;
        }
        return changed;
    }
};

const RecentEventList = struct {
    items: std.ArrayListUnmanaged(RecentEvent) = .empty,

    fn deinit(self: *RecentEventList, alloc: Allocator) void {
        for (self.items.items) |item| alloc.free(item.path);
        self.items.deinit(alloc);
        self.* = .{};
    }

    fn latest(self: *const RecentEventList, alloc: Allocator, path: []const u8) !?RecentEvent {
        for (self.items.items) |item| {
            if (try pathsEqualIgnoreCase(alloc, item.path, path)) return item;
        }
        return null;
    }

    fn upsert(
        self: *RecentEventList,
        alloc: Allocator,
        path: []const u8,
        kind: RecentEventKind,
        changed_ns: i64,
    ) !void {
        if (!isRecentLocalPath(path)) return;
        const normalized = try normalizeRecentPathAlloc(alloc, path);
        var normalized_owned = true;
        defer if (normalized_owned) alloc.free(normalized);
        for (self.items.items, 0..) |item, index| {
            if (!try pathsEqualIgnoreCase(alloc, item.path, normalized)) continue;
            if (item.changed_ns > changed_ns) return;
            alloc.free(item.path);
            _ = self.items.orderedRemove(index);
            break;
        }

        try self.items.append(alloc, .{
            .path = normalized,
            .kind = kind,
            .changed_ns = changed_ns,
        });
        normalized_owned = false;
        if (self.items.items.len > max_recents * 2) {
            var oldest: usize = 0;
            for (self.items.items[1..], 1..) |item, index| {
                if (item.changed_ns < self.items.items[oldest].changed_ns) oldest = index;
            }
            alloc.free(self.items.orderedRemove(oldest).path);
        }
    }
};

const ProfileEventList = struct {
    items: std.ArrayListUnmanaged(ProfileEvent) = .empty,

    fn deinit(self: *ProfileEventList, alloc: Allocator) void {
        for (self.items.items) |item| alloc.free(item.key);
        self.items.deinit(alloc);
        self.* = .{};
    }

    fn latest(self: *const ProfileEventList, key: []const u8) ?ProfileEvent {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.key, key)) return item;
        }
        return null;
    }

    fn upsert(
        self: *ProfileEventList,
        alloc: Allocator,
        key: []const u8,
        kind: ProfileEventKind,
        changed_ns: i64,
    ) !void {
        for (self.items.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.key, key)) continue;
            if (item.changed_ns > changed_ns) return;
            alloc.free(item.key);
            _ = self.items.orderedRemove(index);
            break;
        }

        const owned = try alloc.dupe(u8, key);
        errdefer alloc.free(owned);
        try self.items.append(alloc, .{
            .key = owned,
            .kind = kind,
            .changed_ns = changed_ns,
        });
        if (self.items.items.len > max_profile_events) {
            var oldest: usize = 0;
            for (self.items.items[1..], 1..) |item, index| {
                if (item.changed_ns < self.items.items[oldest].changed_ns) oldest = index;
            }
            alloc.free(self.items.orderedRemove(oldest).key);
        }
    }
};

const ProfileTombstones = struct {
    items: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *ProfileTombstones, alloc: Allocator) void {
        for (self.items.items) |item| alloc.free(item);
        self.items.deinit(alloc);
        self.* = .{};
    }

    fn contains(self: *const ProfileTombstones, key: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item, key)) return true;
        }
        return false;
    }

    fn insert(self: *ProfileTombstones, alloc: Allocator, key: []const u8) !bool {
        if (key.len == 0 or self.contains(key)) return false;
        const owned = try alloc.dupe(u8, key);
        errdefer alloc.free(owned);
        if (self.items.items.len == max_profile_tombstones) {
            alloc.free(self.items.orderedRemove(0));
        }
        try self.items.append(alloc, owned);
        return true;
    }

    fn remove(self: *ProfileTombstones, alloc: Allocator, key: []const u8) bool {
        for (self.items.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item, key)) continue;
            alloc.free(item);
            _ = self.items.orderedRemove(index);
            return true;
        }
        return false;
    }
};

const LoadedState = struct {
    recents: RecentList = .{},
    removed_recents: RecentList = .{},
    hidden_profiles: ProfileTombstones = .{},
    recent_events: RecentEventList = .{},
    profile_events: ProfileEventList = .{},

    fn deinit(self: *LoadedState, alloc: Allocator) void {
        self.recents.deinit(alloc);
        self.removed_recents.deinit(alloc);
        self.hidden_profiles.deinit(alloc);
        self.recent_events.deinit(alloc);
        self.profile_events.deinit(alloc);
        self.* = .{};
    }
};

fn stringSlicesEqual(lhs: []const []const u8, rhs: []const []const u8) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn recentListsEqual(lhs: *const RecentList, rhs: *const RecentList) bool {
    return stringSlicesEqual(lhs.items.items, rhs.items.items);
}

fn profileTombstonesEqual(lhs: *const ProfileTombstones, rhs: *const ProfileTombstones) bool {
    return stringSlicesEqual(lhs.items.items, rhs.items.items);
}

fn decodeStateAlloc(alloc: Allocator, raw: []const u8) !LoadedState {
    var result: LoadedState = .{};
    errdefer result.deinit(alloc);
    var parsed = try parseRecentStateAlloc(alloc, raw);
    defer parsed.deinit();

    for (parsed.value.directories) |directory| try result.recents.appendLoaded(alloc, directory);
    for (parsed.value.removed_directories) |directory| try result.removed_recents.appendLoaded(alloc, directory);
    for (parsed.value.hidden_profiles) |key| _ = try result.hidden_profiles.insert(alloc, key);
    for (parsed.value.recent_events) |event| {
        try result.recent_events.upsert(alloc, event.path, event.kind, event.changed_ns);
    }
    for (parsed.value.profile_events) |event| {
        try result.profile_events.upsert(alloc, event.key, event.kind, event.changed_ns);
    }
    return result;
}

fn loadStateForMergeAlloc(alloc: Allocator, path: []const u8) !LoadedState {
    const raw = persistence.readFileBoundedAlloc(alloc, path, max_state_bytes) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer alloc.free(raw);
    return try decodeStateAlloc(alloc, raw);
}

fn loadStateAlloc(alloc: Allocator, path: []const u8) LoadedState {
    const raw = persistence.readFileBoundedAlloc(alloc, path, max_state_bytes) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            error.FileTooBig => log.warn("jump list recent state exceeds size limit path={s}", .{path}),
            else => log.warn("jump list recent state read failed path={s} err={}", .{ path, err }),
        }
        return .{};
    };
    defer alloc.free(raw);

    return decodeStateAlloc(alloc, raw) catch |err| {
        switch (err) {
            error.OutOfMemory => log.warn("jump list recent state parse allocation failed path={s}", .{path}),
            else => log.warn("jump list recent state ignored path={s} err={}", .{ path, err }),
        }
        return .{};
    };
}

pub fn isRecentLocalPath(path: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or
        (path[2] != '\\' and path[2] != '/'))
    {
        return false;
    }
    for (path, 0..) |byte, index| {
        if (byte < 32) return false;
        switch (byte) {
            '"', '<', '>', '|', '?', '*' => return false,
            ':' => if (index != 1) return false,
            else => {},
        }
    }
    return true;
}

fn normalizeRecentPathAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    var end = path.len;
    while (end > 3 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    const normalized = try alloc.dupe(u8, path[0..end]);
    for (normalized[2..]) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    }
    return normalized;
}

fn pathsEqualIgnoreCase(alloc: Allocator, lhs: []const u8, rhs: []const u8) !bool {
    const lhs_normalized = try normalizeRecentPathAlloc(alloc, lhs);
    defer alloc.free(lhs_normalized);
    const rhs_normalized = try normalizeRecentPathAlloc(alloc, rhs);
    defer alloc.free(rhs_normalized);
    const lhs_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, lhs_normalized);
    defer alloc.free(lhs_w);
    const rhs_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, rhs_normalized);
    defer alloc.free(rhs_w);
    const result = CompareStringOrdinal(
        lhs_w.ptr,
        @intCast(lhs_w.len),
        rhs_w.ptr,
        @intCast(rhs_w.len),
        1,
    );
    if (result == 0) return error.PathComparisonFailed;
    return result == 2;
}

/// Unicode controls that reorder or isolate the text around them. A jump-list
/// title is drawn by the shell, so leaving these in lets a seeded Recent entry
/// render as a path it does not point at.
fn isBidiControl(cp: u21) bool {
    return switch (cp) {
        0x061C, 0x200E, 0x200F => true,
        0x202A...0x202E => true,
        0x2066...0x2069 => true,
        else => false,
    };
}

/// Copy `text` for use as a jump-list item title, dropping bidi controls.
pub fn buildTitleAlloc(alloc: Allocator, text: []const u8) ![]u8 {
    var view = std.unicode.Utf8View.init(text) catch {
        // Not valid UTF-8; nothing to reorder, so copy it through unchanged.
        return try alloc.dupe(u8, text);
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var iter = view.iterator();
    while (iter.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch continue;
        if (isBidiControl(cp)) continue;
        try out.writer.writeAll(slice);
    }
    return try out.toOwnedSlice();
}

pub fn buildWorkingDirectoryArgumentsAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    if (!isRecentLocalPath(path)) return error.InvalidWorkingDirectory;
    const option = try std.fmt.allocPrint(alloc, "--working-directory={s}", .{path});
    defer alloc.free(option);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try Command.writeDirectArg(&out.writer, option);
    return try out.toOwnedSlice();
}

pub fn buildProfileArgumentsAlloc(alloc: Allocator, command: Command) ![]u8 {
    return buildProfileArgumentsWithLaunchConfigAlloc(alloc, command, "home", false);
}

fn buildProfileArgumentsForProfileAlloc(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
) ![]u8 {
    if (profile.kind != .ssh) return buildProfileArgumentsAlloc(alloc, profile.command);
    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = (try windows_ssh_hosts.userProfileDir(&home_buf)) orelse
        return error.UnsupportedProfileCommand;
    return buildProfileArgumentsWithLaunchConfigAlloc(alloc, profile.command, home, true);
}

fn buildProfileArgumentsWithLaunchConfigAlloc(
    alloc: Allocator,
    command: Command,
    working_directory: []const u8,
    disable_shell_integration: bool,
) ![]u8 {
    const argv = switch (command) {
        .direct => |value| value,
        .shell => return error.UnsupportedProfileCommand,
    };
    if (argv.len == 0) return error.UnsupportedProfileCommand;

    var command_value: std.Io.Writer.Allocating = .init(alloc);
    defer command_value.deinit();
    try command_value.writer.writeAll("direct:");
    for (argv, 0..) |arg, index| {
        if (index > 0) try command_value.writer.writeByte(' ');
        try Command.writeDirectArg(&command_value.writer, arg);
    }

    const command_option = try std.fmt.allocPrint(
        alloc,
        "--command={s}",
        .{command_value.written()},
    );
    defer alloc.free(command_option);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    // Profile command arguments are intentionally excluded from the
    // single-instance forwarding allowlist. Keep this shell link in its own
    // process so the selected command reaches the new surface unchanged.
    try out.writer.writeAll("--single-instance=false ");
    // Match in-app profile launches: start at home instead of inheriting the caller's cwd.
    const working_directory_option = try std.fmt.allocPrint(
        alloc,
        "--working-directory={s}",
        .{working_directory},
    );
    defer alloc.free(working_directory_option);
    try Command.writeDirectArg(&out.writer, working_directory_option);
    try out.writer.writeByte(' ');
    if (disable_shell_integration) {
        try out.writer.writeAll("--shell-integration=none ");
    }
    try Command.writeDirectArg(&out.writer, command_option);
    try out.writer.writeByte(' ');
    const initial_command_option = try std.fmt.allocPrint(
        alloc,
        "--initial-command={s}",
        .{command_value.written()},
    );
    defer alloc.free(initial_command_option);
    try Command.writeDirectArg(&out.writer, initial_command_option);
    return try out.toOwnedSlice();
}

fn containsArguments(values: []const []const u8, arguments: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, arguments)) return true;
    }
    return false;
}

fn recentSlotCount(slot_budget: UINT, recent_count: usize, profile_count: usize) usize {
    const slots: usize = slot_budget;
    if (slots == 0 or recent_count == 0) return 0;
    if (profile_count == 0 or slots == 1) return @min(recent_count, slots);
    const reserved_profiles = @min(slots - 1, profile_count);
    return @min(recent_count, slots - reserved_profiles);
}

fn profileSlotCount(slot_budget: UINT, recent_count: usize, profile_count: usize) usize {
    return @min(profile_count, @as(usize, slot_budget) -| recent_count);
}

fn nextRebuildRetryCount(current: u8) ?u8 {
    if (current >= max_rebuild_retries) return null;
    return current + 1;
}

const RemovedArguments = struct {
    items: std.ArrayListUnmanaged([]u8) = .empty,
    profile_keys: ProfileTombstones = .{},
    complete: bool = true,

    fn deinit(self: *RemovedArguments, alloc: Allocator) void {
        for (self.items.items) |item| alloc.free(item);
        self.items.deinit(alloc);
        self.profile_keys.deinit(alloc);
        self.* = .{};
    }
};

const ProfileItem = struct {
    key: []u8,
    title: []u8,
    arguments: []u8,

    fn deinit(self: *ProfileItem, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.title);
        alloc.free(self.arguments);
        self.* = undefined;
    }
};

pub const JumpList = struct {
    alloc: Allocator,
    state_path: []u8,
    exe_path: ?[]u8,
    recents: RecentList,
    removed_recents: RecentList,
    hidden_profiles: ProfileTombstones,
    recent_events: RecentEventList = .{},
    profile_events: ProfileEventList = .{},
    pending_recent_additions: RecentList = .{},
    pending_recent_removals: RecentList = .{},
    pending_recent_uses: RecentList = .{},
    pending_recent_events: RecentEventList = .{},
    pending_profile_events: ProfileEventList = .{},
    pending_profile_hides: ProfileTombstones = .{},
    pending_profile_uses: ProfileTombstones = .{},
    profiles: std.ArrayListUnmanaged(ProfileItem) = .empty,
    timer_id: ?UINT_PTR = null,
    persist_dirty: bool = false,
    rebuild_dirty: bool = true,
    rebuild_retry_count: u8 = 0,
    com_disabled: bool = false,
    startup_profile_discovery_pending: bool = false,
    startup_profile_discovery_retry_count: u8 = 0,
    use_guards_rebuild_committed: bool = false,

    pub fn init(alloc: Allocator, state_path: []const u8) !JumpList {
        const owned_state_path = try alloc.dupe(u8, state_path);
        errdefer alloc.free(owned_state_path);
        const loaded = loadStateAlloc(alloc, state_path);
        return .{
            .alloc = alloc,
            .state_path = owned_state_path,
            .exe_path = std.fs.selfExePathAlloc(alloc) catch |err| exe: {
                log.warn("jump list executable path unavailable err={}", .{err});
                break :exe null;
            },
            .recents = loaded.recents,
            .removed_recents = loaded.removed_recents,
            .hidden_profiles = loaded.hidden_profiles,
            .recent_events = loaded.recent_events,
            .profile_events = loaded.profile_events,
        };
    }

    pub fn deinit(self: *JumpList) void {
        self.stopTimer();
        if (self.persist_dirty) _ = self.persist();
        self.stopTimer();
        self.recents.deinit(self.alloc);
        self.removed_recents.deinit(self.alloc);
        self.hidden_profiles.deinit(self.alloc);
        self.recent_events.deinit(self.alloc);
        self.profile_events.deinit(self.alloc);
        self.pending_recent_additions.deinit(self.alloc);
        self.pending_recent_removals.deinit(self.alloc);
        self.pending_recent_uses.deinit(self.alloc);
        self.pending_recent_events.deinit(self.alloc);
        self.pending_profile_events.deinit(self.alloc);
        self.pending_profile_hides.deinit(self.alloc);
        self.pending_profile_uses.deinit(self.alloc);
        self.clearProfiles();
        self.profiles.deinit(self.alloc);
        if (self.exe_path) |path| self.alloc.free(path);
        self.alloc.free(self.state_path);
        self.* = undefined;
    }

    pub fn startup(self: *JumpList) void {
        self.stopTimer();
        self.flush();
        self.startup_profile_discovery_pending = true;
        self.startup_profile_discovery_retry_count = 0;
        self.schedule();
    }

    pub fn startupProfileDiscoveryPending(self: *const JumpList) bool {
        return self.startup_profile_discovery_pending;
    }

    pub fn completeStartupProfileDiscovery(self: *JumpList) void {
        self.startup_profile_discovery_pending = false;
        self.startup_profile_discovery_retry_count = 0;
    }

    pub fn retryStartupProfileDiscovery(self: *JumpList) void {
        if (!self.startup_profile_discovery_pending) return;
        if (nextRebuildRetryCount(self.startup_profile_discovery_retry_count)) |next| {
            self.startup_profile_discovery_retry_count = next;
            self.schedule();
        } else {
            log.warn("jump list profile discovery retries exhausted; waiting for a new host", .{});
        }
    }

    pub fn updateProfiles(self: *JumpList, profiles: []const windows_shell.Profile) void {
        self.updateProfilesAlloc(profiles) catch |err| {
            log.warn("jump list profile snapshot failed err={}", .{err});
        };
    }

    fn updateProfilesAlloc(self: *JumpList, profiles: []const windows_shell.Profile) !void {
        var next: std.ArrayListUnmanaged(ProfileItem) = .empty;
        errdefer {
            for (next.items) |*item| item.deinit(self.alloc);
            next.deinit(self.alloc);
        }

        for (profiles) |profile| {
            const title = try buildTitleAlloc(self.alloc, profile.label);
            const key = self.alloc.dupe(u8, profile.key) catch |err| {
                self.alloc.free(title);
                return err;
            };
            const arguments = buildProfileArgumentsForProfileAlloc(self.alloc, &profile) catch |err| switch (err) {
                error.UnsupportedProfileCommand => {
                    self.alloc.free(key);
                    self.alloc.free(title);
                    continue;
                },
                else => {
                    self.alloc.free(key);
                    self.alloc.free(title);
                    return err;
                },
            };
            next.append(self.alloc, .{ .key = key, .title = title, .arguments = arguments }) catch |err| {
                self.alloc.free(key);
                self.alloc.free(title);
                self.alloc.free(arguments);
                return err;
            };
        }

        if (profileItemsEqual(self.profiles.items, next.items)) {
            for (next.items) |*item| item.deinit(self.alloc);
            next.deinit(self.alloc);
            return;
        }

        self.clearProfiles();
        self.profiles.deinit(self.alloc);
        self.profiles = next;
        self.rebuild_retry_count = 0;
        self.rebuild_dirty = true;
        self.schedule();
    }

    pub fn noteProfileUsed(self: *JumpList, key: []const u8) void {
        const changed_ns: i64 = @intCast(std.time.nanoTimestamp());
        const removed = self.hidden_profiles.remove(self.alloc, key);
        _ = self.pending_profile_hides.remove(self.alloc, key);
        const recorded = self.pending_profile_uses.insert(self.alloc, key) catch |err| {
            log.warn("jump list profile-use snapshot failed err={}", .{err});
            return;
        };
        self.pending_profile_events.upsert(self.alloc, key, .used, changed_ns) catch |err| {
            log.warn("jump list profile event snapshot failed err={}", .{err});
            return;
        };
        _ = removed;
        _ = recorded;
        self.persist_dirty = true;
        self.rebuild_retry_count = 0;
        self.rebuild_dirty = true;
        self.schedule();
    }

    pub fn noteRecent(self: *JumpList, path: []const u8) void {
        if (!isRecentLocalPath(path)) return;
        const normalized = normalizeRecentPathAlloc(self.alloc, path) catch |err| {
            log.warn("jump list recent normalization failed err={}", .{err});
            return;
        };
        defer self.alloc.free(normalized);
        const changed_ns: i64 = @intCast(std.time.nanoTimestamp());
        const reinstated = self.removed_recents.removePath(self.alloc, normalized) catch |err| {
            log.warn("jump list recent reinstatement failed err={}", .{err});
            return;
        };
        if (reinstated) {
            _ = self.pending_recent_removals.removePath(self.alloc, normalized) catch {};
        }
        _ = self.pending_recent_uses.insert(self.alloc, normalized) catch |err| {
            log.warn("jump list recent-use snapshot failed err={}", .{err});
            return;
        };
        const changed = self.recents.insert(self.alloc, normalized) catch |err| {
            log.warn("jump list recent update failed err={}", .{err});
            return;
        };
        // A pwd report is also a use event when this process's stale MRU
        // already has the path at the front. Record it so a newer tombstone
        // written by another process is removed during the next merge.
        const recorded = self.pending_recent_additions.insert(self.alloc, normalized) catch |err| {
            log.warn("jump list recent persistence snapshot failed err={}", .{err});
            return;
        };
        self.pending_recent_events.upsert(self.alloc, normalized, .used, changed_ns) catch |err| {
            log.warn("jump list recent event snapshot failed err={}", .{err});
            return;
        };
        if (!changed and !reinstated and !recorded) return;
        self.persist_dirty = true;
        self.rebuild_retry_count = 0;
        self.rebuild_dirty = true;
        self.schedule();
    }

    pub fn handleTimer(self: *JumpList, timer_id: UINT_PTR) bool {
        if (self.timer_id == null or timer_id != self.timer_id.?) return false;
        self.stopTimer();
        self.flush();
        return true;
    }

    pub fn flush(self: *JumpList) void {
        var rebuild_committed = false;
        if (self.rebuild_dirty and !self.com_disabled) {
            if (self.rebuildCom()) |_| {
                self.rebuild_dirty = false;
                self.rebuild_retry_count = 0;
                rebuild_committed = true;
            } else |err| switch (err) {
                error.ComNotInitialized => {
                    self.com_disabled = true;
                    log.warn("jump list COM unavailable; disabling rebuilds for this process", .{});
                },
                else => {
                    log.warn("jump list rebuild unavailable err={}", .{err});
                    if (nextRebuildRetryCount(self.rebuild_retry_count)) |next| {
                        self.rebuild_retry_count = next;
                        self.schedule();
                    } else {
                        log.warn("jump list rebuild retries exhausted; waiting for a model change", .{});
                    }
                },
            }
        }
        const persisted = if (self.persist_dirty) self.persist() else true;
        if (!persisted) self.schedule();
        if (rebuild_committed) self.use_guards_rebuild_committed = true;
        self.finishUseGuards(persisted);
    }

    fn finishUseGuards(self: *JumpList, persisted: bool) void {
        if (self.use_guards_rebuild_committed and persisted) {
            self.pending_recent_uses.deinit(self.alloc);
            self.pending_profile_uses.deinit(self.alloc);
            self.use_guards_rebuild_committed = false;
        }
    }

    /// Re-arm the debounce if the deferred startup profile discovery still
    /// has not found a host. Called when one is created, so an
    /// `initial-window=false` launch is not stranded without a Profiles
    /// category until something else happens to dirty the model.
    pub fn scheduleIfStartupPending(self: *JumpList) void {
        if (self.startup_profile_discovery_pending) {
            self.startup_profile_discovery_retry_count = 0;
            self.schedule();
        }
    }

    fn schedule(self: *JumpList) void {
        self.stopTimer();
        const timer_id = SetTimer(null, 0, debounce_ms, null);
        if (timer_id == 0) {
            log.warn("jump list debounce timer unavailable", .{});
            return;
        }
        self.timer_id = timer_id;
    }

    fn stopTimer(self: *JumpList) void {
        if (self.timer_id) |timer_id| {
            _ = KillTimer(null, timer_id);
            self.timer_id = null;
        }
    }

    /// Serialize the cross-process read-modify-write transaction, reload the
    /// latest snapshot, and apply only this process's pending model events.
    /// This preserves another process's newer entries without letting a stale
    /// in-memory snapshot overwrite them.
    fn persist(self: *JumpList) bool {
        if (std.fs.path.dirname(self.state_path)) |directory| {
            std.fs.makeDirAbsolute(directory) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    log.warn("jump list recent directory create failed path={s} err={}", .{ directory, err });
                    return false;
                },
            };
        }

        const lock_path = std.fmt.allocPrint(self.alloc, "{s}.lock", .{self.state_path}) catch |err| {
            log.warn("jump list state lock path allocation failed err={}", .{err});
            return false;
        };
        defer self.alloc.free(lock_path);
        const lock_file = std.fs.createFileAbsolute(lock_path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| {
            log.warn("jump list state lock unavailable path={s} err={}", .{ lock_path, err });
            return false;
        };
        defer lock_file.close();

        var merged = loadStateForMergeAlloc(self.alloc, self.state_path) catch |err| {
            log.warn("jump list state reload failed; preserving prior snapshot path={s} err={}", .{
                self.state_path,
                err,
            });
            return false;
        };
        defer merged.deinit(self.alloc);
        self.applyPendingState(&merged) catch |err| {
            log.warn("jump list state merge failed err={}", .{err});
            return false;
        };

        const model_changed = !recentListsEqual(&self.recents, &merged.recents) or
            !recentListsEqual(&self.removed_recents, &merged.removed_recents) or
            !profileTombstonesEqual(&self.hidden_profiles, &merged.hidden_profiles);
        const encoded = encodeRecentStateAlloc(
            self.alloc,
            merged.recents.items.items,
            merged.removed_recents.items.items,
            merged.hidden_profiles.items.items,
            merged.recent_events.items.items,
            merged.profile_events.items.items,
        ) catch |err| {
            log.warn("jump list recent encode failed err={}", .{err});
            return false;
        };
        defer self.alloc.free(encoded);

        const temporary_path = std.fmt.allocPrint(
            self.alloc,
            "{s}.tmp-{x}-{x}",
            .{ self.state_path, GetCurrentProcessId(), @as(u64, @bitCast(std.time.milliTimestamp())) },
        ) catch |err| {
            log.warn("jump list recent temp path allocation failed err={}", .{err});
            return false;
        };
        defer self.alloc.free(temporary_path);

        persistence.writeFileAtomic(self.state_path, temporary_path, encoded) catch |err| {
            log.warn("jump list recent write failed path={s} err={}", .{ self.state_path, err });
            return false;
        };

        self.recents.deinit(self.alloc);
        self.recents = merged.recents;
        merged.recents = .{};
        self.removed_recents.deinit(self.alloc);
        self.removed_recents = merged.removed_recents;
        merged.removed_recents = .{};
        self.hidden_profiles.deinit(self.alloc);
        self.hidden_profiles = merged.hidden_profiles;
        merged.hidden_profiles = .{};
        self.recent_events.deinit(self.alloc);
        self.recent_events = merged.recent_events;
        merged.recent_events = .{};
        self.profile_events.deinit(self.alloc);
        self.profile_events = merged.profile_events;
        merged.profile_events = .{};

        self.pending_recent_additions.deinit(self.alloc);
        self.pending_recent_removals.deinit(self.alloc);
        self.pending_recent_events.deinit(self.alloc);
        self.pending_profile_events.deinit(self.alloc);
        self.pending_profile_hides.deinit(self.alloc);
        self.persist_dirty = false;
        if (model_changed) {
            self.rebuild_retry_count = 0;
            self.rebuild_dirty = true;
            self.schedule();
        }
        return true;
    }

    fn applyPendingState(self: *const JumpList, merged: *LoadedState) !void {
        for (self.pending_recent_events.items.items) |event| {
            if (try merged.recent_events.latest(self.alloc, event.path)) |latest| {
                if (latest.changed_ns > event.changed_ns) continue;
            }
            switch (event.kind) {
                .used => {
                    _ = try merged.removed_recents.removePath(self.alloc, event.path);
                },
                .removed => {
                    _ = try merged.recents.removePath(self.alloc, event.path);
                    _ = try merged.removed_recents.insert(self.alloc, event.path);
                },
            }
            try merged.recent_events.upsert(
                self.alloc,
                event.path,
                event.kind,
                event.changed_ns,
            );
        }
        try self.rebuildMergedRecents(merged);
        for (self.pending_profile_events.items.items) |event| {
            if (merged.profile_events.latest(event.key)) |latest| {
                if (latest.changed_ns > event.changed_ns) continue;
            }
            switch (event.kind) {
                .hidden => _ = try merged.hidden_profiles.insert(self.alloc, event.key),
                .used => _ = merged.hidden_profiles.remove(self.alloc, event.key),
            }
            try merged.profile_events.upsert(
                self.alloc,
                event.key,
                event.kind,
                event.changed_ns,
            );
        }
    }

    fn rebuildMergedRecents(self: *const JumpList, merged: *LoadedState) !void {
        var next: RecentList = .{};
        errdefer next.deinit(self.alloc);

        while (next.items.items.len < max_recents) {
            var chosen: ?usize = null;
            for (merged.recent_events.items.items, 0..) |event, index| {
                if (event.kind != .used or
                    !isRecentLocalPath(event.path) or
                    try merged.removed_recents.contains(self.alloc, event.path) or
                    try next.contains(self.alloc, event.path)) continue;
                const current = if (chosen) |value| merged.recent_events.items.items[value] else {
                    chosen = index;
                    continue;
                };
                if (event.changed_ns >= current.changed_ns) chosen = index;
            }
            const index = chosen orelse break;
            try next.appendLoaded(self.alloc, merged.recent_events.items.items[index].path);
        }

        // Preserve legacy schema-v1 entries until they receive a timestamped
        // use/removal event. They follow all globally ordered event entries.
        for (merged.recents.items.items) |path| {
            if (next.items.items.len >= max_recents) break;
            if (try merged.recent_events.latest(self.alloc, path) != null) continue;
            try next.appendLoaded(self.alloc, path);
        }

        merged.recents.deinit(self.alloc);
        merged.recents = next;
    }

    fn clearProfiles(self: *JumpList) void {
        for (self.profiles.items) |*item| item.deinit(self.alloc);
        self.profiles.clearRetainingCapacity();
    }

    fn rebuildCom(self: *JumpList) !void {
        const exe_path = self.exe_path orelse return error.ExecutableUnavailable;
        const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, exe_path);
        defer self.alloc.free(exe_w);
        const aumid_w = std.unicode.utf8ToUtf16LeStringLiteral(win32_aumid.aumid_utf8);

        var raw_destination: ?*anyopaque = null;
        const create_hr = CoCreateInstance(
            &CLSID_DestinationList,
            null,
            CLSCTX_INPROC_SERVER,
            &IID_ICustomDestinationList,
            &raw_destination,
        );
        if (create_hr == CO_E_NOTINITIALIZED) return error.ComNotInitialized;
        if (create_hr < 0 or raw_destination == null) return error.DestinationListUnavailable;
        const destination = ICustomDestinationList.fromRaw(raw_destination.?);
        defer destination.release();

        if (destination.vtbl.SetAppID(destination.asRaw(), aumid_w) < 0) {
            return error.SetAppIdFailed;
        }

        var slot_budget: UINT = 0;
        var raw_removed: ?*anyopaque = null;
        if (destination.vtbl.BeginList(
            destination.asRaw(),
            &slot_budget,
            &IID_IObjectArray,
            &raw_removed,
        ) < 0) return error.BeginListFailed;

        var transaction_open = true;
        defer if (transaction_open) {
            const abort_hr = destination.vtbl.AbortList(destination.asRaw());
            if (abort_hr < 0) log.debug("jump list AbortList failed hr=0x{x}", .{@as(u32, @bitCast(abort_hr))});
        };

        var removed_arguments: RemovedArguments = .{};
        defer removed_arguments.deinit(self.alloc);
        if (raw_removed) |raw| {
            const removed = IObjectArray.fromRaw(raw);
            defer removed.release();
            removed_arguments = try self.readRemovedArguments(removed);
        }
        if (try self.recents.removeArguments(
            self.alloc,
            removed_arguments.items.items,
            &self.pending_recent_uses,
            &self.pending_recent_removals,
        )) {
            for (self.pending_recent_removals.items.items) |path| {
                _ = try self.removed_recents.insert(self.alloc, path);
                _ = self.pending_recent_additions.removePath(self.alloc, path) catch false;
                try self.pending_recent_events.upsert(
                    self.alloc,
                    path,
                    .removed,
                    @intCast(std.time.nanoTimestamp()),
                );
            }
            self.persist_dirty = true;
        }
        for (self.profiles.items) |item| {
            if (!removed_arguments.profile_keys.contains(item.key) and
                !containsArguments(removed_arguments.items.items, item.arguments)) continue;
            if (self.pending_profile_uses.contains(item.key)) continue;
            if (try self.hidden_profiles.insert(self.alloc, item.key)) {
                _ = try self.pending_profile_hides.insert(self.alloc, item.key);
                try self.pending_profile_events.upsert(
                    self.alloc,
                    item.key,
                    .hidden,
                    @intCast(std.time.nanoTimestamp()),
                );
                self.persist_dirty = true;
            }
        }
        if (!removed_arguments.complete) return error.RemovedDestinationsIncomplete;

        var visible_profile_count: usize = 0;
        for (self.profiles.items) |item| {
            if (!self.hidden_profiles.contains(item.key)) visible_profile_count += 1;
        }
        const recent_count = recentSlotCount(
            slot_budget,
            self.recents.items.items.len,
            visible_profile_count,
        );
        if (recent_count > 0) {
            try self.appendRecentCategory(destination, exe_w, recent_count);
        }
        const profile_count = profileSlotCount(slot_budget, recent_count, visible_profile_count);
        if (profile_count > 0) {
            try self.appendProfilesCategory(destination, exe_w, profile_count);
        }
        // Named layouts (C17, #133) will add a third category here, built
        // from win32_layouts.listNamesAlloc + launchArgvAlloc rather than
        // any layout enumeration of our own.

        if (destination.vtbl.CommitList(destination.asRaw()) < 0) return error.CommitListFailed;
        transaction_open = false;
    }

    fn appendRecentCategory(
        self: *JumpList,
        destination: *ICustomDestinationList,
        exe_w: [:0]const u16,
        count: usize,
    ) !void {
        const collection = try createObjectCollection();
        defer collection.release();

        for (self.recents.items.items[0..count]) |path| {
            const title = try buildTitleAlloc(self.alloc, path);
            defer self.alloc.free(title);
            const arguments = try buildWorkingDirectoryArgumentsAlloc(self.alloc, path);
            defer self.alloc.free(arguments);
            const link = try self.createShellLink(exe_w, arguments, title, path, null);
            defer link.release();
            if (collection.addObject(link.asRaw()) < 0) return error.AddRecentLinkFailed;
        }

        const category = std.unicode.utf8ToUtf16LeStringLiteral("Recent");
        if (destination.vtbl.AppendCategory(destination.asRaw(), category, collection.asArray()) < 0) {
            return error.AppendRecentCategoryFailed;
        }
    }

    fn appendProfilesCategory(
        self: *JumpList,
        destination: *ICustomDestinationList,
        exe_w: [:0]const u16,
        count: usize,
    ) !void {
        const collection = try createObjectCollection();
        defer collection.release();

        var appended: usize = 0;
        for (self.profiles.items) |item| {
            if (self.hidden_profiles.contains(item.key)) continue;
            if (appended == count) break;
            const link = try self.createShellLink(exe_w, item.arguments, item.title, null, item.key);
            defer link.release();
            if (collection.addObject(link.asRaw()) < 0) return error.AddProfileLinkFailed;
            appended += 1;
        }

        const category = std.unicode.utf8ToUtf16LeStringLiteral("Profiles");
        if (destination.vtbl.AppendCategory(destination.asRaw(), category, collection.asArray()) < 0) {
            return error.AppendProfilesCategoryFailed;
        }
    }

    fn readRemovedArguments(
        self: *JumpList,
        removed: *IObjectArray,
    ) !RemovedArguments {
        var result: RemovedArguments = .{};
        errdefer result.deinit(self.alloc);

        var count: UINT = 0;
        if (removed.vtbl.GetCount(removed.asRaw(), &count) < 0) {
            log.debug("jump list removed item count unavailable", .{});
            result.complete = false;
            return result;
        }
        const arguments_buffer = try self.alloc.alloc(u16, max_shell_link_chars);
        defer self.alloc.free(arguments_buffer);

        for (0..count) |index| {
            var raw_link: ?*anyopaque = null;
            const get_hr = removed.vtbl.GetAt(
                removed.asRaw(),
                @intCast(index),
                &IID_IShellLinkW,
                &raw_link,
            );
            if (get_hr == E_NOINTERFACE) continue;
            if (get_hr < 0 or raw_link == null) {
                log.debug("jump list removed item ignored index={d} hr=0x{x}", .{
                    index,
                    @as(u32, @bitCast(get_hr)),
                });
                result.complete = false;
                continue;
            }
            const link = IShellLinkW.fromRaw(raw_link.?);
            defer link.release();

            @memset(arguments_buffer, 0);
            if (link.vtbl.GetArguments(
                link.asRaw(),
                arguments_buffer.ptr,
                @intCast(arguments_buffer.len),
            ) < 0) {
                log.debug("jump list removed link arguments unavailable index={d}", .{index});
                result.complete = false;
                continue;
            }
            const arguments_len = std.mem.indexOfScalar(u16, arguments_buffer, 0) orelse {
                log.debug("jump list removed link arguments too long index={d}", .{index});
                result.complete = false;
                continue;
            };
            const arguments = std.unicode.utf16LeToUtf8Alloc(
                self.alloc,
                arguments_buffer[0..arguments_len],
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {
                    log.debug("jump list removed link arguments invalid index={d} err={}", .{ index, err });
                    result.complete = false;
                    continue;
                },
            };
            var arguments_owned = true;
            errdefer if (arguments_owned) self.alloc.free(arguments);
            try result.items.append(self.alloc, arguments);
            arguments_owned = false;

            @memset(arguments_buffer, 0);
            if (link.vtbl.GetDescription(
                link.asRaw(),
                arguments_buffer.ptr,
                @intCast(arguments_buffer.len),
            ) >= 0) {
                const description_len = std.mem.indexOfScalar(u16, arguments_buffer, 0) orelse continue;
                const description = std.unicode.utf16LeToUtf8Alloc(
                    self.alloc,
                    arguments_buffer[0..description_len],
                ) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => continue,
                };
                defer self.alloc.free(description);
                if (std.mem.startsWith(u8, description, profile_description_prefix)) {
                    const key = description[profile_description_prefix.len..];
                    _ = try result.profile_keys.insert(self.alloc, key);
                }
            }
        }
        return result;
    }

    fn createShellLink(
        self: *JumpList,
        exe_w: [:0]const u16,
        arguments: []const u8,
        title: []const u8,
        working_directory: ?[]const u8,
        profile_key: ?[]const u8,
    ) !*IShellLinkW {
        var raw_link: ?*anyopaque = null;
        const create_hr = CoCreateInstance(
            &CLSID_ShellLink,
            null,
            CLSCTX_INPROC_SERVER,
            &IID_IShellLinkW,
            &raw_link,
        );
        if (create_hr == CO_E_NOTINITIALIZED) return error.ComNotInitialized;
        if (create_hr < 0 or raw_link == null) return error.ShellLinkUnavailable;
        const link = IShellLinkW.fromRaw(raw_link.?);
        errdefer link.release();

        const arguments_w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, arguments);
        defer self.alloc.free(arguments_w);
        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, title);
        defer self.alloc.free(title_w);

        if (link.vtbl.SetPath(link.asRaw(), exe_w.ptr) < 0) return error.SetLinkPathFailed;
        if (link.vtbl.SetArguments(link.asRaw(), arguments_w.ptr) < 0) return error.SetLinkArgumentsFailed;
        if (link.vtbl.SetIconLocation(link.asRaw(), exe_w.ptr, 0) < 0) return error.SetLinkIconFailed;

        if (profile_key) |key| {
            const description = try std.fmt.allocPrint(
                self.alloc,
                "{s}{s}",
                .{ profile_description_prefix, key },
            );
            defer self.alloc.free(description);
            const description_w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, description);
            defer self.alloc.free(description_w);
            if (link.vtbl.SetDescription(link.asRaw(), description_w.ptr) < 0) {
                return error.SetLinkDescriptionFailed;
            }
        }

        if (working_directory) |path| {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, path);
            defer self.alloc.free(path_w);
            if (link.vtbl.SetWorkingDirectory(link.asRaw(), path_w.ptr) < 0) {
                return error.SetLinkWorkingDirectoryFailed;
            }
        }

        var raw_store: ?*anyopaque = null;
        if (link.vtbl.QueryInterface(link.asRaw(), &IID_IPropertyStore, &raw_store) < 0 or raw_store == null) {
            return error.PropertyStoreUnavailable;
        }
        const store = IPropertyStore.fromRaw(raw_store.?);
        defer store.release();

        const aumid_w = std.unicode.utf8ToUtf16LeStringLiteral(win32_aumid.aumid_utf8);
        const aumid_value = PROPVARIANT.fromString(aumid_w);
        if (store.setValue(&PKEY_AppUserModel_ID, &aumid_value) < 0) return error.SetLinkAumidFailed;
        const title_value = PROPVARIANT.fromString(title_w);
        if (store.setValue(&PKEY_Title, &title_value) < 0) return error.SetLinkTitleFailed;
        if (store.vtbl.Commit(store.asRaw()) < 0) return error.CommitLinkPropertiesFailed;

        return link;
    }
};

fn profileItemsEqual(lhs: []const ProfileItem, rhs: []const ProfileItem) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        if (!std.mem.eql(u8, left.key, right.key) or
            !std.mem.eql(u8, left.title, right.title) or
            !std.mem.eql(u8, left.arguments, right.arguments)) return false;
    }
    return true;
}

fn createObjectCollection() !*IObjectCollection {
    var raw_collection: ?*anyopaque = null;
    const create_hr = CoCreateInstance(
        &CLSID_EnumerableObjectCollection,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IObjectCollection,
        &raw_collection,
    );
    if (create_hr == CO_E_NOTINITIALIZED) return error.ComNotInitialized;
    if (create_hr < 0 or raw_collection == null) return error.ObjectCollectionUnavailable;
    return IObjectCollection.fromRaw(raw_collection.?);
}

test "jump_list recent insert dedupes case insensitively and keeps newest first" {
    var recent: RecentList = .{};
    defer recent.deinit(std.testing.allocator);

    try std.testing.expect(try recent.insert(std.testing.allocator, "C:\\one"));
    try std.testing.expect(try recent.insert(std.testing.allocator, "D:\\two"));
    try std.testing.expect(try recent.insert(std.testing.allocator, "E:\\three"));
    try std.testing.expect(try recent.insert(std.testing.allocator, "c:\\ONE"));
    try std.testing.expect(!try recent.insert(std.testing.allocator, "C:\\one"));

    try std.testing.expectEqual(@as(usize, 3), recent.items.items.len);
    try std.testing.expectEqualStrings("C:\\one", recent.items.items[0]);
    try std.testing.expectEqualStrings("E:\\three", recent.items.items[1]);
    try std.testing.expectEqualStrings("D:\\two", recent.items.items[2]);

    var unicode: RecentList = .{};
    defer unicode.deinit(std.testing.allocator);
    try std.testing.expect(try unicode.insert(std.testing.allocator, "C:\\Üser\\Source"));
    try std.testing.expect(!try unicode.insert(std.testing.allocator, "c:\\üSER\\source"));
    try std.testing.expectEqual(@as(usize, 1), unicode.items.items.len);
}

test "jump_list recent insert caps at ten and rejects nonlocal paths" {
    var recent: RecentList = .{};
    defer recent.deinit(std.testing.allocator);

    try std.testing.expect(!try recent.insert(std.testing.allocator, "relative\\path"));
    try std.testing.expect(!try recent.insert(std.testing.allocator, "\\\\server\\share"));
    try std.testing.expect(!try recent.insert(std.testing.allocator, "/mnt/c/project"));
    try std.testing.expect(!try recent.insert(std.testing.allocator, "C:relative"));
    try std.testing.expect(!try recent.insert(std.testing.allocator, "C:\\bad*name"));
    try std.testing.expect(!try recent.insert(std.testing.allocator, "C:\\bad\tname"));
    const invalid_utf8 = [_]u8{ 'C', ':', '\\', 0xFF };
    try std.testing.expect(!try recent.insert(std.testing.allocator, &invalid_utf8));

    var buffer: [32]u8 = undefined;
    for (0..12) |index| {
        const path = try std.fmt.bufPrint(&buffer, "C:\\project-{d}", .{index});
        try std.testing.expect(try recent.insert(std.testing.allocator, path));
    }
    try std.testing.expectEqual(max_recents, recent.items.items.len);
    try std.testing.expectEqualStrings("C:\\project-11", recent.items.items[0]);
    try std.testing.expectEqualStrings("C:\\project-2", recent.items.items[9]);
}

test "jump_list JSON round trips and corrupt or oversized state starts empty" {
    const values = [_][]const u8{ "C:\\src\\noctty", "D:\\work" };
    const hidden_profiles = [_][]const u8{"wsl:Ubuntu"};
    const removed_values = [_][]const u8{"E:\\removed"};
    const recent_events = [_]RecentEvent{.{
        .path = "E:\\removed",
        .kind = .removed,
        .changed_ns = 42,
    }};
    const profile_events = [_]ProfileEvent{.{
        .key = "wsl:Ubuntu",
        .kind = .hidden,
        .changed_ns = 43,
    }};
    const encoded = try encodeRecentStateAlloc(
        std.testing.allocator,
        &values,
        &removed_values,
        &hidden_profiles,
        &recent_events,
        &profile_events,
    );
    defer std.testing.allocator.free(encoded);
    var parsed = try parseRecentStateAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(values[0], parsed.value.directories[0]);
    try std.testing.expectEqualStrings(values[1], parsed.value.directories[1]);
    try std.testing.expectEqualStrings(removed_values[0], parsed.value.removed_directories[0]);
    try std.testing.expectEqualStrings(hidden_profiles[0], parsed.value.hidden_profiles[0]);
    try std.testing.expectEqualStrings(recent_events[0].path, parsed.value.recent_events[0].path);
    try std.testing.expectEqual(recent_events[0].kind, parsed.value.recent_events[0].kind);
    try std.testing.expectEqual(recent_events[0].changed_ns, parsed.value.recent_events[0].changed_ns);
    try std.testing.expectEqualStrings(profile_events[0].key, parsed.value.profile_events[0].key);
    try std.testing.expectEqual(profile_events[0].kind, parsed.value.profile_events[0].kind);
    try std.testing.expectEqual(profile_events[0].changed_ns, parsed.value.profile_events[0].changed_ns);
    try std.testing.expectError(
        error.SyntaxError,
        parseRecentStateAlloc(std.testing.allocator, "{not json"),
    );

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var file = try tmp.dir.createFile("corrupt.json", .{});
        defer file.close();
        try file.writeAll("{not json");
    }
    const corrupt_path = try tmp.dir.realpathAlloc(std.testing.allocator, "corrupt.json");
    defer std.testing.allocator.free(corrupt_path);
    var corrupt = loadStateAlloc(std.testing.allocator, corrupt_path);
    defer corrupt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), corrupt.recents.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), corrupt.hidden_profiles.items.items.len);
    try std.testing.expectError(
        error.SyntaxError,
        loadStateForMergeAlloc(std.testing.allocator, corrupt_path),
    );

    {
        var file = try tmp.dir.createFile("oversized.json", .{});
        defer file.close();
        var remaining = max_state_bytes + 1;
        const chunk = [_]u8{'x'} ** 1024;
        while (remaining > 0) {
            const count = @min(remaining, chunk.len);
            try file.writeAll(chunk[0..count]);
            remaining -= count;
        }
    }
    const oversized_path = try tmp.dir.realpathAlloc(std.testing.allocator, "oversized.json");
    defer std.testing.allocator.free(oversized_path);
    var oversized = loadStateAlloc(std.testing.allocator, oversized_path);
    defer oversized.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), oversized.recents.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), oversized.hidden_profiles.items.items.len);

    const oversized_key = try std.testing.allocator.alloc(u8, max_state_bytes);
    defer std.testing.allocator.free(oversized_key);
    @memset(oversized_key, 'x');
    try std.testing.expectError(
        error.StateTooLarge,
        encodeRecentStateAlloc(std.testing.allocator, &.{}, &.{}, &.{oversized_key}, &.{}, &.{}),
    );
}

test "jump_list titles drop bidi controls and keep everything else" {
    const testing = std.testing;

    // U+202E RIGHT-TO-LEFT OVERRIDE around a segment is what lets a seeded
    // entry render as a path it does not point at.
    const spoofed = try buildTitleAlloc(
        testing.allocator,
        "C:\\Users\\a\\\u{202E}gpj.exe\u{202C}",
    );
    defer testing.allocator.free(spoofed);
    try testing.expectEqualStrings("C:\\Users\\a\\gpj.exe", spoofed);

    // Ordinary non-ASCII is untouched.
    const unicode_path = try buildTitleAlloc(testing.allocator, "D:\\\u{9805}\u{76EE}\\\u{1F680}");
    defer testing.allocator.free(unicode_path);
    try testing.expectEqualStrings("D:\\\u{9805}\u{76EE}\\\u{1F680}", unicode_path);

    // Invalid UTF-8 is copied through rather than silently emptied.
    const invalid = try buildTitleAlloc(testing.allocator, "C:\\bad\xff");
    defer testing.allocator.free(invalid);
    try testing.expectEqualStrings("C:\\bad\xff", invalid);
}

test "jump_list argument builders preserve Windows argv boundaries" {
    const recent = try buildWorkingDirectoryArgumentsAlloc(
        std.testing.allocator,
        "C:\\Users\\Aman Thanvi\\src",
    );
    defer std.testing.allocator.free(recent);
    try std.testing.expectEqualStrings(
        "\"--working-directory=C:\\Users\\Aman Thanvi\\src\"",
        recent,
    );

    const profile = try buildProfileArgumentsAlloc(std.testing.allocator, .{
        .direct = &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo", "a b" },
    });
    defer std.testing.allocator.free(profile);
    try std.testing.expectEqualStrings(
        "--single-instance=false --working-directory=home \"--command=direct:\\\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\\\" -NoLogo \\\"a b\\\"\" \"--initial-command=direct:\\\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\\\" -NoLogo \\\"a b\\\"\"",
        profile,
    );

    var argv = try std.process.ArgIteratorGeneral(.{}).init(std.testing.allocator, profile);
    defer argv.deinit();
    try std.testing.expectEqualStrings("--single-instance=false", argv.next().?);
    try std.testing.expectEqualStrings("--working-directory=home", argv.next().?);
    const command_option = argv.next().?;
    const initial_command_option = argv.next().?;
    try std.testing.expect(argv.next() == null);
    try std.testing.expect(std.mem.startsWith(u8, command_option, "--command="));
    try std.testing.expect(std.mem.startsWith(u8, initial_command_option, "--initial-command="));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parsed_command: Command = undefined;
    try parsed_command.parseCLI(arena.allocator(), command_option["--command=".len..]);
    try std.testing.expect(parsed_command == .direct);
    try std.testing.expectEqual(@as(usize, 3), parsed_command.direct.len);
    try std.testing.expectEqualStrings("C:\\Program Files\\PowerShell\\7\\pwsh.exe", parsed_command.direct[0]);
    try std.testing.expectEqualStrings("-NoLogo", parsed_command.direct[1]);
    try std.testing.expectEqualStrings("a b", parsed_command.direct[2]);
    var parsed_initial_command: Command = undefined;
    try parsed_initial_command.parseCLI(
        arena.allocator(),
        initial_command_option["--initial-command=".len..],
    );
    try std.testing.expectEqualDeep(parsed_command, parsed_initial_command);

    const ssh_profile = try buildProfileArgumentsWithLaunchConfigAlloc(
        std.testing.allocator,
        .{ .direct = &.{ "C:\\Windows\\System32\\OpenSSH\\ssh.exe", "production" } },
        "C:\\Users\\Aman Thanvi",
        true,
    );
    defer std.testing.allocator.free(ssh_profile);
    var ssh_argv = try std.process.ArgIteratorGeneral(.{}).init(std.testing.allocator, ssh_profile);
    defer ssh_argv.deinit();
    try std.testing.expectEqualStrings("--single-instance=false", ssh_argv.next().?);
    try std.testing.expectEqualStrings("--working-directory=C:\\Users\\Aman Thanvi", ssh_argv.next().?);
    try std.testing.expectEqualStrings("--shell-integration=none", ssh_argv.next().?);
    try std.testing.expect(std.mem.startsWith(u8, ssh_argv.next().?, "--command="));
    try std.testing.expect(std.mem.startsWith(u8, ssh_argv.next().?, "--initial-command="));
    try std.testing.expect(ssh_argv.next() == null);

    try std.testing.expectError(
        error.UnsupportedProfileCommand,
        buildProfileArgumentsAlloc(std.testing.allocator, .{ .shell = "pwsh.exe" }),
    );
}

test "jump_list removed recent arguments clear tracked entries" {
    var recent: RecentList = .{};
    defer recent.deinit(std.testing.allocator);
    var protected: RecentList = .{};
    defer protected.deinit(std.testing.allocator);
    var pending_removals: RecentList = .{};
    defer pending_removals.deinit(std.testing.allocator);
    try std.testing.expect(try recent.insert(std.testing.allocator, "C:\\one"));
    try std.testing.expect(try recent.insert(std.testing.allocator, "D:\\two"));
    const removed = try buildWorkingDirectoryArgumentsAlloc(std.testing.allocator, "C:\\one");
    defer std.testing.allocator.free(removed);

    try std.testing.expect(try recent.removeArguments(
        std.testing.allocator,
        &.{removed},
        &protected,
        &pending_removals,
    ));
    try std.testing.expectEqual(@as(usize, 1), recent.items.items.len);
    try std.testing.expectEqualStrings("D:\\two", recent.items.items[0]);
    try std.testing.expect(try pending_removals.contains(std.testing.allocator, "C:\\one"));
    try std.testing.expect(!try recent.removeArguments(
        std.testing.allocator,
        &.{removed},
        &protected,
        &pending_removals,
    ));
}

test "jump_list persistence merge applies local events to the latest snapshot" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer jump.deinit();

    try std.testing.expect(try jump.pending_recent_additions.insert(alloc, "D:\\local"));
    try std.testing.expect(try jump.pending_recent_removals.insert(alloc, "C:\\removed"));
    try jump.pending_recent_events.upsert(alloc, "D:\\local", .used, 20);
    try jump.pending_recent_events.upsert(alloc, "C:\\removed", .removed, 21);
    try std.testing.expect(try jump.pending_profile_hides.insert(alloc, "wsl:new-hidden"));
    try std.testing.expect(try jump.pending_profile_uses.insert(alloc, "wsl:used"));
    try jump.pending_profile_events.upsert(alloc, "wsl:new-hidden", .hidden, 22);
    try jump.pending_profile_events.upsert(alloc, "wsl:used", .used, 23);

    var merged: LoadedState = .{};
    defer merged.deinit(alloc);
    try merged.recents.appendLoaded(alloc, "C:\\removed");
    try merged.recents.appendLoaded(alloc, "E:\\other-process");
    try std.testing.expect(try merged.hidden_profiles.insert(alloc, "wsl:used"));

    try jump.applyPendingState(&merged);
    try std.testing.expectEqual(@as(usize, 2), merged.recents.items.items.len);
    try std.testing.expectEqualStrings("D:\\local", merged.recents.items.items[0]);
    try std.testing.expectEqualStrings("E:\\other-process", merged.recents.items.items[1]);
    try std.testing.expect(try merged.removed_recents.contains(alloc, "C:\\removed"));
    try std.testing.expect(merged.hidden_profiles.contains("wsl:new-hidden"));
    try std.testing.expect(!merged.hidden_profiles.contains("wsl:used"));
}

test "jump_list persistence keeps the newer cross-process recent event" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer jump.deinit();

    // Process A observed the directory first, then process B removed it and
    // persisted that newer event before A acquired the state-file lock.
    try jump.pending_recent_events.upsert(alloc, "C:\\stale", .used, 10);
    var merged: LoadedState = .{};
    defer merged.deinit(alloc);
    try merged.removed_recents.appendLoaded(alloc, "C:\\stale");
    try merged.recent_events.upsert(alloc, "C:\\stale", .removed, 20);

    try jump.applyPendingState(&merged);
    try std.testing.expectEqual(@as(usize, 0), merged.recents.items.items.len);
    try std.testing.expect(try merged.removed_recents.contains(alloc, "C:\\stale"));
    const latest = (try merged.recent_events.latest(alloc, "C:\\stale")).?;
    try std.testing.expectEqual(RecentEventKind.removed, latest.kind);
    try std.testing.expectEqual(@as(i64, 20), latest.changed_ns);
}

test "jump_list persistence orders recent destinations across paths" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer jump.deinit();
    try jump.pending_recent_events.upsert(alloc, "D:\\older", .used, 10);

    var merged: LoadedState = .{};
    defer merged.deinit(alloc);
    var buffer: [32]u8 = undefined;
    for (0..max_recents) |index| {
        const path = try std.fmt.bufPrint(&buffer, "C:\\newer-{d}", .{index});
        try merged.recents.appendLoaded(alloc, path);
        try merged.recent_events.upsert(alloc, path, .used, @intCast(20 + index));
    }

    try jump.applyPendingState(&merged);
    try std.testing.expectEqual(max_recents, merged.recents.items.items.len);
    try std.testing.expectEqualStrings("C:\\newer-9", merged.recents.items.items[0]);
    try std.testing.expect(!try merged.recents.contains(alloc, "D:\\older"));
}

test "jump_list persistence keeps the newer cross-process profile event" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer jump.deinit();
    try jump.pending_profile_events.upsert(alloc, "wsl:Ubuntu", .hidden, 10);

    var merged: LoadedState = .{};
    defer merged.deinit(alloc);
    try merged.profile_events.upsert(alloc, "wsl:Ubuntu", .used, 20);

    try jump.applyPendingState(&merged);
    try std.testing.expect(!merged.hidden_profiles.contains("wsl:Ubuntu"));
    const latest = merged.profile_events.latest("wsl:Ubuntu").?;
    try std.testing.expectEqual(ProfileEventKind.used, latest.kind);
    try std.testing.expectEqual(@as(i64, 20), latest.changed_ns);

    // The inverse ordering must also hold: an older delayed use cannot
    // unhide a profile removed later by another process.
    try jump.pending_profile_events.upsert(alloc, "wsl:Ubuntu", .used, 30);
    try merged.profile_events.upsert(alloc, "wsl:Ubuntu", .hidden, 40);
    try std.testing.expect(try merged.hidden_profiles.insert(alloc, "wsl:Ubuntu"));
    try jump.applyPendingState(&merged);
    try std.testing.expect(merged.hidden_profiles.contains("wsl:Ubuntu"));
    try std.testing.expectEqual(ProfileEventKind.hidden, merged.profile_events.latest("wsl:Ubuntu").?.kind);
}

test "jump_list unchanged recent directory still records a use event" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer {
        // This test exercises the in-memory event seam only.
        jump.persist_dirty = false;
        jump.deinit();
    }

    try std.testing.expect(try jump.recents.insert(alloc, "D:\\same-head"));
    jump.noteRecent("D:\\same-head");
    try std.testing.expect(jump.persist_dirty);
    try std.testing.expect(try jump.pending_recent_additions.contains(alloc, "D:\\same-head"));
    try std.testing.expect(try jump.pending_recent_uses.contains(alloc, "D:\\same-head"));
}

test "jump_list rejects invalid recent use before queuing events" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer jump.deinit();

    jump.noteRecent("/home/user");
    try std.testing.expectEqual(@as(usize, 0), jump.pending_recent_events.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), jump.pending_recent_uses.items.items.len);
    try std.testing.expect(!jump.persist_dirty);
}

test "jump_list normalizes separators and trailing directory syntax" {
    const alloc = std.testing.allocator;
    var recents: RecentList = .{};
    defer recents.deinit(alloc);

    try std.testing.expect(try recents.insert(alloc, "C:/work/"));
    try std.testing.expectEqualStrings("C:\\work", recents.items.items[0]);
    try std.testing.expect(!try recents.insert(alloc, "c:\\WORK\\"));
    try std.testing.expectEqual(@as(usize, 1), recents.items.items.len);
}

test "jump_list rebuild skips an invalid persisted recent event" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer jump.deinit();
    var merged: LoadedState = .{};
    defer merged.deinit(alloc);

    try merged.recent_events.items.append(alloc, .{
        .path = try alloc.dupe(u8, "/home/user"),
        .kind = .used,
        .changed_ns = 2,
    });
    try merged.recent_events.upsert(alloc, "C:\\valid", .used, 1);
    try jump.rebuildMergedRecents(&merged);
    try std.testing.expectEqual(@as(usize, 1), merged.recents.items.items.len);
    try std.testing.expectEqualStrings("C:\\valid", merged.recents.items.items[0]);
}

test "jump_list clears use guards after a committed rebuild is persisted later" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
    };
    defer jump.deinit();

    try std.testing.expect(try jump.pending_recent_uses.insert(alloc, "C:\\used"));
    try std.testing.expect(try jump.pending_profile_uses.insert(alloc, "wsl:used"));
    jump.use_guards_rebuild_committed = true;
    jump.finishUseGuards(false);
    try std.testing.expectEqual(@as(usize, 1), jump.pending_recent_uses.items.items.len);
    jump.finishUseGuards(true);
    try std.testing.expectEqual(@as(usize, 0), jump.pending_recent_uses.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), jump.pending_profile_uses.items.items.len);
    try std.testing.expect(!jump.use_guards_rebuild_committed);
}

test "jump_list slot budget reserves profiles before recents" {
    try std.testing.expectEqual(@as(usize, 5), recentSlotCount(10, 10, 5));
    try std.testing.expectEqual(@as(usize, 1), recentSlotCount(3, 10, 5));
    try std.testing.expectEqual(@as(usize, 3), recentSlotCount(3, 10, 0));
    try std.testing.expectEqual(@as(usize, 0), recentSlotCount(0, 10, 2));
    try std.testing.expectEqual(@as(usize, 1), recentSlotCount(1, 10, 2));
    try std.testing.expectEqual(@as(usize, 2), recentSlotCount(10, 2, 2));
    try std.testing.expectEqual(@as(usize, 2), profileSlotCount(3, 1, 5));
    try std.testing.expectEqual(@as(usize, 0), profileSlotCount(3, 3, 5));
}

test "jump_list removed profile tombstone persists until profile use" {
    var hidden: ProfileTombstones = .{};
    defer hidden.deinit(std.testing.allocator);
    try std.testing.expect(try hidden.insert(std.testing.allocator, "wsl:Ubuntu"));
    try std.testing.expect(!try hidden.insert(std.testing.allocator, "wsl:Ubuntu"));
    try std.testing.expect(hidden.contains("wsl:Ubuntu"));
    try std.testing.expect(hidden.remove(std.testing.allocator, "wsl:Ubuntu"));
    try std.testing.expect(!hidden.contains("wsl:Ubuntu"));
    try std.testing.expect(!hidden.remove(std.testing.allocator, "wsl:Ubuntu"));

    var key_buffer: [32]u8 = undefined;
    for (0..max_profile_tombstones + 1) |index| {
        const key = try std.fmt.bufPrint(&key_buffer, "wsl:distro-{d}", .{index});
        try std.testing.expect(try hidden.insert(std.testing.allocator, key));
    }
    try std.testing.expectEqual(max_profile_tombstones, hidden.items.items.len);
    try std.testing.expect(!hidden.contains("wsl:distro-0"));
    try std.testing.expect(hidden.contains("wsl:distro-128"));
}

test "jump_list rebuild retry budget is bounded" {
    var retry_count: u8 = 0;
    var expected: u8 = 1;
    while (expected <= max_rebuild_retries) : (expected += 1) {
        retry_count = nextRebuildRetryCount(retry_count).?;
        try std.testing.expectEqual(expected, retry_count);
    }
    try std.testing.expect(nextRebuildRetryCount(retry_count) == null);
}

test "jump_list startup profile discovery stays pending until completion" {
    const alloc = std.testing.allocator;
    var jump: JumpList = .{
        .alloc = alloc,
        .state_path = try alloc.dupe(u8, "unused"),
        .exe_path = null,
        .recents = .{},
        .removed_recents = .{},
        .hidden_profiles = .{},
        .startup_profile_discovery_pending = true,
    };
    defer jump.deinit();

    try std.testing.expect(jump.startupProfileDiscoveryPending());
    jump.startup_profile_discovery_retry_count = max_rebuild_retries;
    jump.retryStartupProfileDiscovery();
    try std.testing.expect(jump.timer_id == null);
    try std.testing.expectEqual(max_rebuild_retries, jump.startup_profile_discovery_retry_count);
    // A failed discovery leaves the request untouched; only the caller's
    // explicit success transition consumes it.
    try std.testing.expect(jump.startupProfileDiscoveryPending());
    jump.completeStartupProfileDiscovery();
    try std.testing.expect(!jump.startupProfileDiscoveryPending());
}

test "jump_list raw COM interfaces preserve pointer layout and PROPVARIANT ABI" {
    const pointer_size = @sizeOf(*anyopaque);

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(ICustomDestinationList, "vtbl"));
    try std.testing.expectEqual(3 * pointer_size, @offsetOf(ICustomDestinationListVtbl, "SetAppID"));
    try std.testing.expectEqual(4 * pointer_size, @offsetOf(ICustomDestinationListVtbl, "BeginList"));
    try std.testing.expectEqual(5 * pointer_size, @offsetOf(ICustomDestinationListVtbl, "AppendCategory"));
    try std.testing.expectEqual(8 * pointer_size, @offsetOf(ICustomDestinationListVtbl, "CommitList"));
    try std.testing.expectEqual(9 * pointer_size, @offsetOf(ICustomDestinationListVtbl, "GetRemovedDestinations"));
    try std.testing.expectEqual(11 * pointer_size, @offsetOf(ICustomDestinationListVtbl, "AbortList"));
    try std.testing.expectEqual(5 * pointer_size, @offsetOf(IObjectCollectionVtbl, "AddObject"));
    try std.testing.expectEqual(10 * pointer_size, @offsetOf(IShellLinkWVtbl, "GetArguments"));
    try std.testing.expectEqual(11 * pointer_size, @offsetOf(IShellLinkWVtbl, "SetArguments"));
    try std.testing.expectEqual(17 * pointer_size, @offsetOf(IShellLinkWVtbl, "SetIconLocation"));
    try std.testing.expectEqual(20 * pointer_size, @offsetOf(IShellLinkWVtbl, "SetPath"));
    try std.testing.expectEqual(6 * pointer_size, @offsetOf(IPropertyStoreVtbl, "SetValue"));
    try std.testing.expectEqual(7 * pointer_size, @offsetOf(IPropertyStoreVtbl, "Commit"));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(PROPERTYKEY, "fmtid"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(PROPERTYKEY, "pid"));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(PROPERTYKEY));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(PROPVARIANT, "vt"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(PROPVARIANT, "reserved1"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(PROPVARIANT, "reserved2"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(PROPVARIANT, "reserved3"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(PROPVARIANT, "value"));
    try std.testing.expectEqual(if (@sizeOf(usize) == 8) @as(usize, 24) else 16, @sizeOf(PROPVARIANT));
}

test "jump_list property keys and AUMID match Windows shell contracts" {
    try std.testing.expectEqualDeep(
        GUID.parse("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"),
        PKEY_AppUserModel_ID.fmtid,
    );
    try std.testing.expectEqual(@as(DWORD, 5), PKEY_AppUserModel_ID.pid);
    try std.testing.expectEqualDeep(
        GUID.parse("{F29F85E0-4FF9-1068-AB91-08002B27B3D9}"),
        PKEY_Title.fmtid,
    );
    try std.testing.expectEqualStrings("io.github.amanthanvi.noctty", win32_aumid.aumid_utf8);
}
