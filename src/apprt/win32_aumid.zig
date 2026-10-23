//! AppUserModelID (AUMID) registration for noctty.
//!
//! AUMID is the Windows identity that drives:
//!   * Taskbar grouping (duplicates collapse under one icon).
//!   * Action Center toast attribution (toasts fired by this process
//!     show up with our display name + icon, not "Application Host").
//!   * Cold-start toast activation (Windows launches the Start Menu
//!     shortcut; the shortcut's AUMID property routes the click back
//!     to us instead of spawning a generic new process).
//!
//! Two-part registration:
//!   1. Per-process: `SetCurrentProcessExplicitAppUserModelID` — must
//!      run BEFORE any window creation. Cheap, no disk I/O.
//!   2. Per-user registry: `HKCU\Software\Classes\AppUserModelId\<aumid>`
//!      with `DisplayName` + `IconUri` + `ShowInSettings=1`. Installed
//!      copies write it on every launch. The key is per user, not per
//!      install, so a portable copy only creates it where nothing has
//!      registered the AUMID yet, and never changes an existing one
//!      (D12; with no registration at all a toast is not shown). Kept
//!      out of the Start Menu-shortcut writer
//!      because some corporate lockdowns block shortcut creation but
//!      allow HKCU writes, and the registry entry alone is enough for
//!      warm-start toast attribution to look correct.
//!
//!      `IconUri` must name an image file (`.ico` / `.png`). The
//!      notification platform does not extract the icon resource from
//!      an exe path: the toast header renders without an icon, and the
//!      "no icon" resolution is then cached per AUMID, so a later
//!      registry fix is not picked up by the running session (a reboot
//!      cleared it in testing; sign-out alone was not measured). We
//!      point it at the `noctty.ico` that the installer, the portable
//!      ZIP and `zig build` all stage next to the exe. When that file is
//!      missing the value is left as it was: the key is per user, not
//!      per install, so a bare copy of the exe writing its own path
//!      would strip the icon from every other noctty on the machine.
//!
//! The AUMID string `io.github.amanthanvi.noctty` lives in a namespace
//! we own (matching the instance/bundle id) rather than any
//! Ghostty-owned reverse-DNS prefix, so it cannot collide with — or
//! imply affiliation with — an upstream Ghostty install.
//!
//! Start Menu shortcut creation is intentionally NOT here — it's
//! installer-side work that belongs in `scripts/package-windows.ps1`,
//! not in our runtime init path. A packaged build writes the shortcut
//! once with the correct AUMID property via Inno Setup; dev builds
//! run without a shortcut and fall back to explicit-AUMID-only toast
//! attribution (still works for warm-start, fails for cold-start).

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const win32_types = @import("win32_types.zig");
const sys = @import("win32/sys.zig");
const win32_elevation = @import("win32_elevation.zig");
const win32_toast_activator = @import("win32_toast_activator.zig");
const os_windows = @import("../os/windows.zig");

const HRESULT = windows.HRESULT;
const LPCWSTR = win32_types.LPCWSTR;
const HKEY = sys.HKEY;
const REGSAM = u32;
const DWORD = win32_types.DWORD;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_WRITE: REGSAM = 0x20006;
const KEY_QUERY_VALUE: REGSAM = 0x0001;
const REG_OPTION_NON_VOLATILE: DWORD = 0;
const REG_SZ: DWORD = 1;
const REG_DWORD: DWORD = 4;
const ERROR_SUCCESS: i32 = 0;

const aumid_wide: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");
pub const aumid_utf8 = "io.github.amanthanvi.noctty";

/// Set the AUMID for the current process. Must run before any HWND is
/// created; Windows copies the identity into the process's taskbar-
/// integration state at first window-creation time. Return value is
/// advisory — we log and proceed on failure rather than abort, since
/// toasts are not essential for the app to function.
pub fn setProcessAumid() void {
    const hr = sys.SetCurrentProcessExplicitAppUserModelID(aumid_wide);
    if (hr < 0) {
        std.log.warn("AUMID: SetCurrentProcessExplicitAppUserModelID failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
    }
}

/// Write `HKCU\Software\Classes\AppUserModelId\<aumid>` with DisplayName +
/// IconUri + ShowInSettings. An installed copy always writes; a portable
/// copy only creates the key when it does not exist yet
/// (`App.claimSharedIdentity`). A copy the installer put in place, unless
/// elevated, also writes `CustomActivator`, the CLSID Action Center
/// activates for a click on one of its toasts (`win32_toast_activator.zig`);
/// the measurement build's early return skips that too.
pub fn registerAumidDisplayName(alloc: std.mem.Allocator, portable: bool) void {
    const exe_path = std.fs.selfExePathAlloc(alloc) catch return;
    defer alloc.free(exe_path);
    const parent = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Classes\\AppUserModelId");
    const name = std.unicode.utf8ToUtf16LeStringLiteral(aumid_utf8);
    const elevated = win32_elevation.isProcessElevated() catch true;
    const installer_managed = if (std.fs.path.dirname(exe_path)) |dir|
        os_windows.isInstallerManagedInstallDir(dir)
    else
        false;
    // A test that starts a real App reaches this; it must never name an
    // activator in the developer's real registration.
    const activator = if (builtin.is_test) null else activatorFor(installer_managed, portable, elevated);
    _ = register(alloc, parent, name, exe_path, portable, activator) catch |err| {
        std.log.warn("AUMID: registration failed err={}", .{err});
    };
}

/// The `CustomActivator` this copy writes, if any: the same rule as the
/// class object it points at (`win32_toast_activator.shouldRegister`).
fn activatorFor(installer_managed: bool, portable: bool, elevated: bool) ?[:0]const u16 {
    if (!win32_toast_activator.shouldRegister(installer_managed, portable, elevated)) return null;
    return std.unicode.utf8ToUtf16LeStringLiteral(win32_toast_activator.clsid_text);
}

/// Returns whether this call wrote the registration. `activator` is the
/// `CustomActivator` CLSID an installed copy writes; it is never written for
/// a portable copy.
fn register(
    alloc: std.mem.Allocator,
    parent: [:0]const u16,
    name: [:0]const u16,
    exe_path: []const u8,
    portable: bool,
    activator: ?[:0]const u16,
) !bool {
    var parent_key: HKEY = undefined;
    if (sys.RegCreateKeyExW(HKEY_CURRENT_USER, parent, 0, null, REG_OPTION_NON_VOLATILE, KEY_WRITE, null, &parent_key, null) != ERROR_SUCCESS)
        return error.RegistryOpenFailed;
    defer _ = sys.RegCloseKey(parent_key);
    if (!portable) {
        _ = try registerForExe(alloc, parent_key, name, exe_path, activator);
        return true;
    }

    // A portable copy leaves an existing registration alone, whoever wrote
    // it. Where there is none, it fills a complete key under a private name
    // and renames it into place. The rename fails once the name exists, so
    // of copies starting together only the first registers, and an
    // installed copy, which always writes, overwrites it afterwards. A copy
    // with no icon beside it publishes nothing: later copies could not add
    // the icon to a registration that exists.
    var existing: HKEY = undefined;
    if (sys.RegOpenKeyExW(parent_key, name, 0, KEY_QUERY_VALUE, &existing) == ERROR_SUCCESS) {
        _ = sys.RegCloseKey(existing);
        return false;
    }
    var random: [8]u8 = undefined;
    std.crypto.random.bytes(&random);
    var suffix_buf: [32]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&suffix_buf, ".pending-{x}", .{random});
    const pending_w = try alloc.allocSentinel(u16, name.len + suffix.len, 0);
    defer alloc.free(pending_w);
    @memcpy(pending_w[0..name.len], name);
    for (suffix, pending_w[name.len..]) |c, *w| w.* = c;
    const published = if (registerForExe(alloc, parent_key, pending_w, exe_path, null)) |wrote_icon|
        wrote_icon and RegRenameKey(parent_key, pending_w, name) == ERROR_SUCCESS
    else |_|
        false;
    if (!published) _ = RegDeleteKeyW(parent_key, pending_w);
    return published;
}

extern "advapi32" fn RegRenameKey(key: HKEY, sub_key: ?LPCWSTR, new_name: LPCWSTR) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteKeyW(key: HKEY, sub_key: LPCWSTR) callconv(.winapi) i32;

/// Returns whether `IconUri` was written (there was an icon beside the exe).
fn registerForExe(alloc: std.mem.Allocator, root: HKEY, subkey: LPCWSTR, exe_path: []const u8, activator: ?[:0]const u16) !bool {
    var hkey: HKEY = undefined;
    const open_rc = sys.RegCreateKeyExW(
        root,
        subkey,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE,
        null,
        &hkey,
        null,
    );
    if (open_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: RegCreateKeyExW failed rc={d}", .{open_rc});
        return error.RegistryOpenFailed;
    }
    defer _ = sys.RegCloseKey(hkey);

    // Every write is attempted; a failed one is reported at the end.
    var complete = true;
    var wrote_icon = false;
    const display_name = std.unicode.utf8ToUtf16LeStringLiteral("noctty");
    const set_rc = writeRegSz(hkey, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"), display_name);
    if (set_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: write DisplayName failed rc={d}", .{set_rc});
        complete = false;
    }

    {
        const icon_path = iconUriPath(alloc, exe_path) catch |err| blk: {
            std.log.warn("AUMID: sibling icon path unavailable err={}; leaving IconUri unchanged", .{err});
            complete = false;
            break :blk null;
        };
        defer if (icon_path) |path| alloc.free(path);

        // No sibling icon (a cached dev artifact, or a bare exe copied
        // somewhere on its own): keep whatever `IconUri` already holds.
        // Writing this exe's path instead would register a value the
        // notification platform cannot render, and because the key is
        // shared by every noctty the user runs, it would take the icon
        // away from the installed build too.
        if (icon_path) |icon_source| {
            if (std.unicode.utf8ToUtf16LeAllocZ(alloc, icon_source)) |icon_uri| {
                defer alloc.free(icon_uri);

                const icon_rc = writeRegSz(hkey, std.unicode.utf8ToUtf16LeStringLiteral("IconUri"), icon_uri);
                if (icon_rc == ERROR_SUCCESS) {
                    wrote_icon = true;
                } else {
                    std.log.warn("AUMID: write IconUri failed rc={d}", .{icon_rc});
                    complete = false;
                }
            } else |err| {
                std.log.warn("AUMID: IconUri utf16 conversion failed err={}", .{err});
                complete = false;
            }
        }
    }

    // Never removed here: a copy that does not write it (portable, elevated,
    // not set up by the installer) leaves an installed copy's value alone.
    if (activator) |clsid| {
        const activator_rc = writeRegSz(hkey, std.unicode.utf8ToUtf16LeStringLiteral("CustomActivator"), clsid);
        if (activator_rc != ERROR_SUCCESS) {
            std.log.warn("AUMID: write CustomActivator failed rc={d}", .{activator_rc});
            complete = false;
        }
    }

    var show_in_settings: u32 = 1;
    const show_rc = sys.RegSetValueExW(
        hkey,
        std.unicode.utf8ToUtf16LeStringLiteral("ShowInSettings"),
        0,
        REG_DWORD,
        @ptrCast(&show_in_settings),
        @sizeOf(u32),
    );
    if (show_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: write ShowInSettings failed rc={d}", .{show_rc});
        complete = false;
    }
    if (!complete) return error.RegistryWriteFailed;
    return wrote_icon;
}

fn writeRegSz(hkey: HKEY, value_name: LPCWSTR, value: [:0]const u16) i32 {
    return sys.RegSetValueExW(
        hkey,
        value_name,
        0,
        REG_SZ,
        @ptrCast(value.ptr),
        @intCast((value.len + 1) * @sizeOf(u16)),
    );
}

/// The icon file staged next to `noctty.exe` by `scripts/package-windows.ps1`
/// (installer + portable ZIP) and by the `zig build` install step.
pub const icon_file_name = "noctty.ico";

/// `<dir of exe_path>\noctty.ico`. Caller owns the returned slice.
fn siblingIconPath(alloc: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(exe_path) orelse ".";
    return try std.fs.path.join(alloc, &.{ dir, icon_file_name });
}

/// Resolve the value to write into `IconUri`: the sibling `noctty.ico`
/// when it exists on disk, otherwise `null` so the caller leaves the
/// registry value alone (a dev tree that never ran the install step, or
/// a bare copy of the exe). Caller owns a non-null result.
fn iconUriPath(alloc: std.mem.Allocator, exe_path: []const u8) !?[]u8 {
    const icon_path = try siblingIconPath(alloc, exe_path);
    errdefer alloc.free(icon_path);
    // A stat, not an access check: `IconUri` has to name an image file,
    // and a directory that happens to be called `noctty.ico` passes
    // `accessAbsolute` just the same.
    const stat = std.fs.cwd().statFile(icon_path) catch |err| {
        std.log.info("AUMID: {s} not found next to exe ({}); leaving IconUri unchanged", .{ icon_file_name, err });
        alloc.free(icon_path);
        return null;
    };
    if (stat.kind != .file) {
        std.log.info("AUMID: {s} next to exe is not a regular file ({s}); leaving IconUri unchanged", .{ icon_file_name, @tagName(stat.kind) });
        alloc.free(icon_path);
        return null;
    }
    return icon_path;
}

test "aumid sibling icon path sits next to the exe" {
    const testing = std.testing;
    const sep = std.fs.path.sep_str;

    const exe_path = try std.mem.join(testing.allocator, sep, &.{ "C:", "Program Files", "noctty", "noctty.exe" });
    defer testing.allocator.free(exe_path);
    const expected = try std.mem.join(testing.allocator, sep, &.{ "C:", "Program Files", "noctty", "noctty.ico" });
    defer testing.allocator.free(expected);

    const actual = try siblingIconPath(testing.allocator, exe_path);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "aumid icon uri is absent when the sibling icon is missing" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const exe_path = try std.fs.path.join(testing.allocator, &.{ dir, "noctty.exe" });
    defer testing.allocator.free(exe_path);

    // No noctty.ico yet: the caller must leave IconUri as it is.
    try testing.expectEqual(@as(?[]u8, null), try iconUriPath(testing.allocator, exe_path));

    // A directory of that name is not an icon either.
    try tmp.dir.makeDir(icon_file_name);
    try testing.expectEqual(@as(?[]u8, null), try iconUriPath(testing.allocator, exe_path));
    try tmp.dir.deleteDir(icon_file_name);

    // Once the icon is staged next to the exe it is preferred.
    try tmp.dir.writeFile(.{ .sub_path = icon_file_name, .data = "ico" });
    const resolved = (try iconUriPath(testing.allocator, exe_path)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.endsWith(u8, resolved, icon_file_name));
    try testing.expectEqualStrings(dir, std.fs.path.dirname(resolved).?);
}

test "aumid string shape" {
    const testing = std.testing;
    try testing.expectEqualStrings("io.github.amanthanvi.noctty", aumid_utf8);
}

const TestRegistry = struct {
    const parent_prefix = "Software\\noctty-aumid-test-";
    const name = std.unicode.utf8ToUtf16LeStringLiteral("app");

    extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub_key: ?LPCWSTR) callconv(.winapi) i32;
    extern "advapi32" fn RegQueryInfoKeyW(key: HKEY, class: ?[*]u16, class_len: ?*DWORD, reserved: ?*DWORD, sub_keys: ?*DWORD, max_sub_key_len: ?*DWORD, max_class_len: ?*DWORD, values: ?*DWORD, max_value_name_len: ?*DWORD, max_value_len: ?*DWORD, security: ?*DWORD, last_write: ?*u64) callconv(.winapi) i32;

    /// A unique scratch parent under HKCU\Software, deleted with `deinit`.
    parent: [:0]u16,

    fn init(alloc: std.mem.Allocator) !TestRegistry {
        var random: [16]u8 = undefined;
        std.crypto.random.bytes(&random);
        const utf8 = try std.fmt.allocPrint(alloc, parent_prefix ++ "{x}", .{random});
        defer alloc.free(utf8);
        return .{ .parent = try std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8) };
    }

    fn deinit(self: TestRegistry, alloc: std.mem.Allocator) void {
        // Only ever delete the scratch subtree `init` named.
        const prefix = std.unicode.utf8ToUtf16LeStringLiteral(parent_prefix);
        std.debug.assert(self.parent.len > prefix.len and std.mem.startsWith(u16, self.parent, prefix));
        _ = RegDeleteTreeW(HKEY_CURRENT_USER, self.parent);
        alloc.free(self.parent);
    }

    fn open(self: TestRegistry, sub_key: ?[:0]const u16) !HKEY {
        var parent: HKEY = undefined;
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegOpenKeyExW(HKEY_CURRENT_USER, self.parent, 0, KEY_QUERY_VALUE | 0x0008, &parent));
        const child = sub_key orelse return parent;
        defer _ = sys.RegCloseKey(parent);
        var key: HKEY = undefined;
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegOpenKeyExW(parent, child, 0, KEY_QUERY_VALUE, &key));
        return key;
    }

    fn expectSz(key: HKEY, value_name: []const u8, expected: []const u8) !void {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, value_name);
        defer std.testing.allocator.free(wide);
        var buf: [512]u16 = undefined;
        var kind: DWORD = 0;
        var bytes: DWORD = @sizeOf(@TypeOf(buf));
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegQueryValueExW(key, wide, null, &kind, @ptrCast(&buf), &bytes));
        try std.testing.expectEqual(REG_SZ, kind);
        const value = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, buf[0 .. bytes / 2 - 1]);
        defer std.testing.allocator.free(value);
        try std.testing.expectEqualStrings(expected, value);
    }

    /// The number of keys under the scratch parent: the registration, plus
    /// any pending key left behind.
    fn subkeyCount(self: TestRegistry) !DWORD {
        const parent = try self.open(null);
        defer _ = sys.RegCloseKey(parent);
        var subkeys: DWORD = 99;
        try std.testing.expectEqual(ERROR_SUCCESS, RegQueryInfoKeyW(parent, null, null, null, &subkeys, null, null, null, null, null, null, null));
        return subkeys;
    }

    const Snapshot = struct { icon: [512]u16 = undefined, icon_bytes: DWORD = 1024, written: u64 = 0, siblings: DWORD = 0 };

    /// The registration's icon, its last-write time, and the number of keys
    /// under the scratch parent (a leftover pending key shows up here).
    fn snapshot(self: TestRegistry) !Snapshot {
        const parent = try self.open(null);
        defer _ = sys.RegCloseKey(parent);
        const key = try self.open(name);
        defer _ = sys.RegCloseKey(key);
        var out: Snapshot = .{};
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegQueryValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("IconUri"), null, null, @ptrCast(&out.icon), &out.icon_bytes));
        try std.testing.expectEqual(ERROR_SUCCESS, RegQueryInfoKeyW(key, null, null, null, null, null, null, null, null, null, null, &out.written));
        try std.testing.expectEqual(ERROR_SUCCESS, RegQueryInfoKeyW(parent, null, null, null, &out.siblings, null, null, null, null, null, null, null));
        return out;
    }
};

test "portable and elevated copies register no toast activator" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = icon_file_name, .data = "ico" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const exe = try std.fs.path.join(alloc, &.{ root, "noctty.exe" });
    defer alloc.free(exe);
    const custom_activator = std.unicode.utf8ToUtf16LeStringLiteral("CustomActivator");

    const Case = struct { installer_managed: bool, portable: bool, elevated: bool, writes: bool };
    for ([_]Case{
        .{ .installer_managed = true, .portable = false, .elevated = false, .writes = true },
        .{ .installer_managed = true, .portable = false, .elevated = true, .writes = false },
        .{ .installer_managed = true, .portable = true, .elevated = false, .writes = false },
        .{ .installer_managed = false, .portable = true, .elevated = false, .writes = false },
        // Scoop, a ZIP without its marker, a dev build: no class is registered
        // for it, so it must not name one.
        .{ .installer_managed = false, .portable = false, .elevated = false, .writes = false },
    }) |case| {
        const reg = try TestRegistry.init(alloc);
        defer reg.deinit(alloc);
        try std.testing.expect(try register(alloc, reg.parent, TestRegistry.name, exe, case.portable, activatorFor(case.installer_managed, case.portable, case.elevated)));
        const key = try reg.open(TestRegistry.name);
        defer _ = sys.RegCloseKey(key);
        try TestRegistry.expectSz(key, "DisplayName", "noctty");
        if (case.writes) {
            try TestRegistry.expectSz(key, "CustomActivator", win32_toast_activator.clsid_text);
        } else {
            try std.testing.expect(sys.RegQueryValueExW(key, custom_activator, null, null, null, null) != ERROR_SUCCESS);
        }
    }

    // A copy that does not write it leaves an installed copy's value alone.
    {
        const reg = try TestRegistry.init(alloc);
        defer reg.deinit(alloc);
        try std.testing.expect(try register(alloc, reg.parent, TestRegistry.name, exe, false, activatorFor(true, false, false)));
        try std.testing.expect(try register(alloc, reg.parent, TestRegistry.name, exe, false, activatorFor(true, false, true)));
        try std.testing.expect(!try register(alloc, reg.parent, TestRegistry.name, exe, true, activatorFor(true, true, false)));
        const key = try reg.open(TestRegistry.name);
        defer _ = sys.RegCloseKey(key);
        try TestRegistry.expectSz(key, "CustomActivator", win32_toast_activator.clsid_text);
    }
}

test "aumid registration: installed copies always write, portable copies only create" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    var exes: [5][]u8 = undefined;
    var icons: [5][]u8 = undefined;
    var icon_buf: [64]u8 = undefined;
    for (&exes, &icons, [_][]const u8{ "installed", "p1", "p2", "p3", "bare" }) |*exe, *icon, dir| {
        if (!std.mem.eql(u8, dir, "bare")) {
            try tmp.dir.makeDir(dir);
            try tmp.dir.writeFile(.{ .sub_path = try std.fmt.bufPrint(&icon_buf, "{s}/{s}", .{ dir, icon_file_name }), .data = dir });
        }
        exe.* = try std.fs.path.join(alloc, &.{ root, dir, "noctty.exe" });
        icon.* = try siblingIconPath(alloc, exe.*);
    }
    defer for (exes, icons) |exe, icon| {
        alloc.free(exe);
        alloc.free(icon);
    };
    const installed, const p1, const p2, const bare = .{ exes[0], exes[1], exes[2], exes[4] };

    // Absent: a portable copy creates it, once, with its own icon, and no
    // pending key is left behind.
    {
        const reg = try TestRegistry.init(alloc);
        defer reg.deinit(alloc);
        // A portable copy with no icon beside it creates nothing, so the next
        // one can still register with its icon.
        try std.testing.expect(!try register(alloc, reg.parent, TestRegistry.name, bare, true, null));
        try std.testing.expectEqual(@as(DWORD, 0), try reg.subkeyCount());
        try std.testing.expect(try register(alloc, reg.parent, TestRegistry.name, p1, true, null));
        const key = try reg.open(TestRegistry.name);
        defer _ = sys.RegCloseKey(key);
        try TestRegistry.expectSz(key, "DisplayName", "noctty");
        try TestRegistry.expectSz(key, "IconUri", icons[1]);
        var show: u32 = 0;
        var show_bytes: DWORD = @sizeOf(u32);
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegQueryValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("ShowInSettings"), null, null, @ptrCast(&show), &show_bytes));
        try std.testing.expectEqual(@as(u32, 1), show);
        const created = try reg.snapshot();
        try std.testing.expectEqual(@as(DWORD, 1), created.siblings);

        // Present: another portable copy changes no value and not even the
        // key's last-write time, including values it would not have written.
        std.Thread.sleep(20 * std.time.ns_per_ms);
        try std.testing.expect(!try register(alloc, reg.parent, TestRegistry.name, p2, true, null));
        const kept = try reg.snapshot();
        try std.testing.expectEqualSlices(u16, created.icon[0 .. created.icon_bytes / 2], kept.icon[0 .. kept.icon_bytes / 2]);
        try std.testing.expectEqual(created.written, kept.written);
        try std.testing.expectEqual(@as(DWORD, 1), kept.siblings);

        // An installed copy always writes: its own icon replaces the portable
        // one, and an exe with no icon beside it leaves IconUri alone.
        try std.testing.expect(try register(alloc, reg.parent, TestRegistry.name, installed, false, null));
        try TestRegistry.expectSz(key, "IconUri", icons[0]);
        try std.testing.expect(try register(alloc, reg.parent, TestRegistry.name, bare, false, null));
        try TestRegistry.expectSz(key, "IconUri", icons[0]);
        try std.testing.expect(!try register(alloc, reg.parent, TestRegistry.name, p1, true, null));
        try TestRegistry.expectSz(key, "IconUri", icons[0]);

        // Not even a registration whose icon has gone is repaired.
        try tmp.dir.deleteFile("installed/" ++ icon_file_name);
        const broken = try reg.snapshot();
        try std.testing.expect(!try register(alloc, reg.parent, TestRegistry.name, p1, true, null));
        try TestRegistry.expectSz(key, "IconUri", icons[0]);
        try std.testing.expectEqual(broken.written, (try reg.snapshot()).written);
        try tmp.dir.writeFile(.{ .sub_path = "installed/" ++ icon_file_name, .data = "installed" });
    }

    // Copies starting together, released at once: portable copies alone
    // publish exactly one registration; with an installed copy among them
    // at most one portable copy publishes and the installed values win.
    // Either way nothing pending is left.
    for ([_]bool{ false, true }) |with_installed| {
        for (0..8) |_| {
            const reg = try TestRegistry.init(alloc);
            defer reg.deinit(alloc);
            const Run = struct {
                fn run(gate: *std.Thread.ResetEvent, a: std.mem.Allocator, parent: [:0]const u16, exe: []const u8, portable: bool, out: *?bool) void {
                    gate.wait();
                    out.* = register(a, parent, TestRegistry.name, exe, portable, null) catch null;
                }
            };
            var gate: std.Thread.ResetEvent = .{};
            var published: [4]?bool = .{ null, null, null, null };
            var threads: [4]std.Thread = undefined;
            var spawned: usize = 0;
            defer {
                gate.set();
                for (threads[0..spawned]) |t| t.join();
            }
            const first: usize = if (with_installed) 0 else 1;
            for (first..4) |i| {
                threads[spawned] = try std.Thread.spawn(.{}, Run.run, .{ &gate, alloc, reg.parent, exes[i], i != 0, &published[i] });
                spawned += 1;
            }
            gate.set();
            for (threads[0..spawned]) |t| t.join();
            spawned = 0;

            var portable_published: usize = 0;
            for (published[1..]) |p| portable_published += @intFromBool((p orelse return error.TestUnexpectedResult));
            const key = try reg.open(TestRegistry.name);
            defer _ = sys.RegCloseKey(key);
            if (with_installed) {
                try std.testing.expect(published[0].?);
                try std.testing.expect(portable_published <= 1);
                try TestRegistry.expectSz(key, "IconUri", icons[0]);
            } else {
                try std.testing.expectEqual(@as(usize, 1), portable_published);
                const winner = for (published[1..], 1..) |p, i| {
                    if (p.?) break i;
                } else unreachable;
                try TestRegistry.expectSz(key, "IconUri", icons[winner]);
            }
            try std.testing.expectEqual(@as(DWORD, 1), (try reg.snapshot()).siblings);
        }
    }

    // A portable copy that cannot write every value publishes nothing and
    // leaves no pending key, at every allocation that can fail.
    for (0..64) |fail_index| {
        const reg = try TestRegistry.init(alloc);
        defer reg.deinit(alloc);
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
        const published = register(failing.allocator(), reg.parent, TestRegistry.name, p1, true, null) catch false;
        if (published) {
            try std.testing.expect(!failing.has_induced_failure);
            const key = try reg.open(TestRegistry.name);
            defer _ = sys.RegCloseKey(key);
            try TestRegistry.expectSz(key, "IconUri", icons[1]);
            break;
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(DWORD, 0), try reg.subkeyCount());
    } else return error.TestUnexpectedResult;

    // The guard itself: renaming onto a name that exists fails.
    {
        const reg = try TestRegistry.init(alloc);
        defer reg.deinit(alloc);
        try std.testing.expect(try register(alloc, reg.parent, TestRegistry.name, p1, true, null));
        var parent: HKEY = undefined;
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegCreateKeyExW(HKEY_CURRENT_USER, reg.parent, 0, null, 0, KEY_WRITE, null, &parent, null));
        defer _ = sys.RegCloseKey(parent);
        const other = std.unicode.utf8ToUtf16LeStringLiteral("other");
        var created: HKEY = undefined;
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegCreateKeyExW(parent, other, 0, null, 0, KEY_WRITE, null, &created, null));
        _ = sys.RegCloseKey(created);
        try std.testing.expect(RegRenameKey(parent, other, TestRegistry.name) != ERROR_SUCCESS);
    }
}
