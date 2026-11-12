//! A profile's login (user name and password), never in the config file.
//! An installed koreterm keeps it in the Windows Credential Manager (a generic
//! credential per profile). A portable one (`koreterm.portable` beside the
//! executable) keeps everything in its own folder: the login is a file,
//! `credentials\<id>.cred`, encrypted with DPAPI for the Windows user, so it
//! opens only for that user (on another computer, sign in again or import
//! again). The Terminals import stores one (`terminals_import.zig`), a
//! Remote Desktop pane reads it, and the export writes it back in plain text.
//! Nothing here logs a password, a user name or a target.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const xdg = @import("../../os/xdg.zig");
const BOOL = win32_types.BOOL;
const DWORD = win32_types.DWORD;

const FILETIME = extern struct { low: DWORD, high: DWORD };

/// wincred.h's CREDENTIALW, natural alignment (80 bytes on x64, pinned
/// below).
const CREDENTIALW = extern struct {
    Flags: DWORD = 0,
    Type: DWORD = 0,
    TargetName: ?[*:0]const u16 = null,
    Comment: ?[*:0]const u16 = null,
    LastWritten: FILETIME = .{ .low = 0, .high = 0 },
    CredentialBlobSize: DWORD = 0,
    CredentialBlob: ?[*]const u8 = null,
    Persist: DWORD = 0,
    AttributeCount: DWORD = 0,
    Attributes: ?*anyopaque = null,
    TargetAlias: ?[*:0]const u16 = null,
    UserName: ?[*:0]const u16 = null,
};

const CRED_TYPE_GENERIC: DWORD = 1;
const CRED_PERSIST_LOCAL_MACHINE: DWORD = 2;
const CRED_MAX_CREDENTIAL_BLOB_SIZE: usize = 5 * 512;

extern "advapi32" fn CredWriteW(credential: *const CREDENTIALW, flags: DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn CredReadW(target: [*:0]const u16, kind: DWORD, flags: DWORD, credential: *?*CREDENTIALW) callconv(.winapi) BOOL;
extern "advapi32" fn CredDeleteW(target: [*:0]const u16, kind: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "advapi32" fn CredFree(buffer: ?*anyopaque) callconv(.winapi) void;

pub const max_password_len = CRED_MAX_CREDENTIAL_BLOB_SIZE;

/// The credential's target for profile `id` (any case): `koreterm:profile:<id>`
/// in lower case.
fn target(buf: []u16, id: []const u8) ?[:0]const u16 {
    var name: [128]u8 = undefined;
    const prefix = "koreterm:profile:";
    if (id.len == 0 or prefix.len + id.len > name.len) return null;
    @memcpy(name[0..prefix.len], prefix);
    for (id, name[prefix.len..][0..id.len]) |byte, *out| out.* = std.ascii.toLower(byte);
    const len = std.unicode.utf8ToUtf16Le(buf, name[0 .. prefix.len + id.len]) catch return null;
    if (len >= buf.len) return null;
    buf[len] = 0;
    return buf[0..len :0];
}

pub const Error = error{ TooLong, InvalidId, Unexpected };

/// Keep `password` (UTF-8) for profile `id`, replacing any kept before.
fn vaultStore(id: []const u8, user: []const u8, password: []const u8) Error!void {
    if (password.len > max_password_len) return error.TooLong;
    var target_buf: [160]u16 = undefined;
    const name = target(&target_buf, id) orelse return error.InvalidId;
    var user_buf: [514]u16 = undefined;
    const user_w: ?[*:0]const u16 = user: {
        if (user.len == 0) break :user null;
        const len = std.unicode.utf8ToUtf16Le(user_buf[0 .. user_buf.len - 1], user) catch break :user null;
        user_buf[len] = 0;
        break :user user_buf[0..len :0].ptr;
    };
    const credential: CREDENTIALW = .{
        .Type = CRED_TYPE_GENERIC,
        .TargetName = name.ptr,
        .Comment = std.unicode.utf8ToUtf16LeStringLiteral("koreterm profile password"),
        .CredentialBlobSize = @intCast(password.len),
        .CredentialBlob = if (password.len == 0) null else password.ptr,
        .Persist = CRED_PERSIST_LOCAL_MACHINE,
        .UserName = user_w,
    };
    if (CredWriteW(&credential, 0) == 0) return error.Unexpected;
}

/// The password kept for profile `id`, in `alloc`, or null when none is.
pub fn read(alloc: Allocator, id: []const u8) Allocator.Error!?[]u8 {
    const entry = (try readEntry(alloc, id)) orelse return null;
    alloc.free(entry.user);
    return entry.password;
}

/// A kept login: the user name it was kept with, and its password.
pub const Entry = struct {
    user: []u8,
    password: []u8,

    pub fn deinit(self: Entry, alloc: Allocator) void {
        @memset(self.password, 0);
        alloc.free(self.password);
        alloc.free(self.user);
    }
};

/// Profile `id`'s kept user name and password, in `alloc`, or null when none
/// is kept.
fn vaultReadEntry(alloc: Allocator, id: []const u8) Allocator.Error!?Entry {
    var target_buf: [160]u16 = undefined;
    const name = target(&target_buf, id) orelse return null;
    var found: ?*CREDENTIALW = null;
    if (CredReadW(name.ptr, CRED_TYPE_GENERIC, 0, &found) == 0) return null;
    const credential = found orelse return null;
    defer CredFree(credential);
    const password = if (credential.CredentialBlob) |blob| try alloc.dupe(u8, blob[0..credential.CredentialBlobSize]) else try alloc.dupe(u8, "");
    errdefer alloc.free(password);
    const user = if (credential.UserName) |user_w|
        std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.span(user_w)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try alloc.dupe(u8, ""),
        }
    else
        try alloc.dupe(u8, "");
    return .{ .user = user, .password = password };
}

/// Forget profile `id`'s password, if one is kept.
fn vaultRemove(id: []const u8) void {
    var target_buf: [160]u16 = undefined;
    const name = target(&target_buf, id) orelse return;
    _ = CredDeleteW(name.ptr, CRED_TYPE_GENERIC, 0);
}

/// Keep `user` and `password` (UTF-8) for profile `id`, replacing any kept
/// before: in the portable folder, or in the Credential Manager.
pub fn store(id: []const u8, user: []const u8, password: []const u8) Error!void {
    if (password.len > max_password_len) return error.TooLong;
    if (xdg.portableModeActive()) return fileStore(id, user, password);
    return vaultStore(id, user, password);
}

/// Profile `id`'s kept user name and password, in `alloc`, or null when none
/// is kept.
pub fn readEntry(alloc: Allocator, id: []const u8) Allocator.Error!?Entry {
    if (xdg.portableModeActive()) return fileReadEntry(alloc, id);
    return vaultReadEntry(alloc, id);
}

/// Forget profile `id`'s login, if one is kept.
pub fn remove(id: []const u8) void {
    if (xdg.portableModeActive()) return fileRemove(id);
    vaultRemove(id);
}

// --- The portable folder's files ------------------------------------------

const DATA_BLOB = extern struct { cbData: DWORD, pbData: ?[*]u8 };
const CRYPTPROTECT_UI_FORBIDDEN: DWORD = 0x1;
extern "crypt32" fn CryptProtectData(in: *const DATA_BLOB, description: ?[*:0]const u16, entropy: ?*const DATA_BLOB, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: DWORD, out: *DATA_BLOB) callconv(.winapi) BOOL;
extern "crypt32" fn CryptUnprotectData(in: *const DATA_BLOB, description: ?*?[*:0]u16, entropy: ?*const DATA_BLOB, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: DWORD, out: *DATA_BLOB) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

/// The login's file in the portable folder: `credentials\<id>.cred`, the id
/// in lower case. Null for an id that is not a profile id.
fn filePath(alloc: Allocator, id: []const u8) Allocator.Error!?[]u8 {
    if (id.len == 0 or id.len > 64) return null;
    var lower: [64]u8 = undefined;
    for (id, lower[0..id.len]) |byte, *out| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => {},
            else => return null,
        }
        out.* = std.ascii.toLower(byte);
    }
    const root = (xdg.portableRoot(alloc) catch return null) orelse return null;
    defer alloc.free(root);
    const name = try std.fmt.allocPrint(alloc, "{s}.cred", .{lower[0..id.len]});
    defer alloc.free(name);
    return try std.fs.path.join(alloc, &.{ root, "credentials", name });
}

/// The DPAPI blob of `user`, a NUL and `password`, written whole.
fn fileStore(id: []const u8, user: []const u8, password: []const u8) Error!void {
    const alloc = std.heap.page_allocator;
    const path = (filePath(alloc, id) catch return error.Unexpected) orelse return error.InvalidId;
    defer alloc.free(path);
    const plain = alloc.alloc(u8, user.len + 1 + password.len) catch return error.Unexpected;
    defer {
        @memset(plain, 0);
        alloc.free(plain);
    }
    @memcpy(plain[0..user.len], user);
    plain[user.len] = 0;
    @memcpy(plain[user.len + 1 ..], password);
    const in: DATA_BLOB = .{ .cbData = @intCast(plain.len), .pbData = plain.ptr };
    var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
    if (CryptProtectData(&in, std.unicode.utf8ToUtf16LeStringLiteral("koreterm profile login"), null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) return error.Unexpected;
    defer _ = LocalFree(out.pbData);
    const blob = (out.pbData orelse return error.Unexpected)[0..out.cbData];
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch return error.Unexpected;
    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return error.Unexpected;
    defer file.close();
    file.writeAll(blob) catch return error.Unexpected;
}

fn fileReadEntry(alloc: Allocator, id: []const u8) Allocator.Error!?Entry {
    const path = (try filePath(alloc, id)) orelse return null;
    defer alloc.free(path);
    const blob = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(blob);
    const in: DATA_BLOB = .{ .cbData = @intCast(blob.len), .pbData = blob.ptr };
    var out: DATA_BLOB = .{ .cbData = 0, .pbData = null };
    if (CryptUnprotectData(&in, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &out) == 0) return null;
    const plain = (out.pbData orelse return null)[0..out.cbData];
    defer {
        @memset(plain, 0);
        _ = LocalFree(out.pbData);
    }
    const nul = std.mem.indexOfScalar(u8, plain, 0) orelse return null;
    const user = try alloc.dupe(u8, plain[0..nul]);
    errdefer alloc.free(user);
    const password = try alloc.dupe(u8, plain[nul + 1 ..]);
    return .{ .user = user, .password = password };
}

fn fileRemove(id: []const u8) void {
    const alloc = std.heap.page_allocator;
    const path = (filePath(alloc, id) catch return) orelse return;
    defer alloc.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

test "profile credentials: CREDENTIALW matches the SDK" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(CREDENTIALW));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(CREDENTIALW, "CredentialBlobSize"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(CREDENTIALW, "CredentialBlob"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(CREDENTIALW, "UserName"));
}

test "profile credentials: the target is the lower-case id under koreterm's prefix" {
    var buf: [160]u16 = undefined;
    const name = target(&buf, "Coletor-NF").?;
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("koreterm:profile:coletor-nf");
    try std.testing.expectEqualSlices(u16, expected, name);
    try std.testing.expect(target(&buf, "") == null);
}

test "profile credentials: store, read and remove a password" {
    const alloc = std.testing.allocator;
    // A random id, so a real profile's credential is never touched.
    var id_buf: [40]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "zz-test-{x}", .{std.crypto.random.int(u64)}) catch unreachable;
    defer remove(id);
    try store(id, "user", "s3cr&t");
    const got = (try read(alloc, id)).?;
    defer alloc.free(got);
    try std.testing.expect(std.mem.eql(u8, "s3cr&t", got));
    const entry = (try readEntry(alloc, id)).?;
    defer entry.deinit(alloc);
    try std.testing.expectEqualStrings("user", entry.user);
    try std.testing.expect(std.mem.eql(u8, "s3cr&t", entry.password));
    remove(id);
    try std.testing.expect((try read(alloc, id)) == null);
}
