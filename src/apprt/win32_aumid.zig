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
//!      with `DisplayName` + `IconUri` + `ShowInSettings=1`. Written
//!      once at first-run; kept out of the Start Menu-shortcut writer
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
const windows = std.os.windows;
const win32_types = @import("win32_types.zig");
const sys = @import("win32/sys.zig");

const HRESULT = windows.HRESULT;
const LPCWSTR = win32_types.LPCWSTR;
const HKEY = sys.HKEY;
const REGSAM = u32;
const DWORD = win32_types.DWORD;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_WRITE: REGSAM = 0x20006;
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

/// Write `HKCU\Software\Classes\AppUserModelId\io.github.amanthanvi.noctty`
/// with DisplayName + IconUri + ShowInSettings. Idempotent; writes every
/// launch (cost is negligible and this keeps shell attribution in sync
/// with the active dev/build path).
pub fn registerAumidDisplayName(alloc: std.mem.Allocator) void {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Classes\\AppUserModelId\\io.github.amanthanvi.noctty",
    );

    var hkey: HKEY = undefined;
    const open_rc = sys.RegCreateKeyExW(
        HKEY_CURRENT_USER,
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
        return;
    }
    defer _ = sys.RegCloseKey(hkey);

    const display_name = std.unicode.utf8ToUtf16LeStringLiteral("noctty");
    const set_rc = writeRegSz(hkey, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"), display_name);
    if (set_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: write DisplayName failed rc={d}", .{set_rc});
    }

    if (std.fs.selfExePathAlloc(alloc)) |exe_path| {
        defer alloc.free(exe_path);

        const icon_path = iconUriPath(alloc, exe_path) catch |err| blk: {
            std.log.warn("AUMID: sibling icon path unavailable err={}; leaving IconUri unchanged", .{err});
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
                if (icon_rc != ERROR_SUCCESS) {
                    std.log.warn("AUMID: write IconUri failed rc={d}", .{icon_rc});
                }
            } else |err| {
                std.log.warn("AUMID: IconUri utf16 conversion failed err={}", .{err});
            }
        }
    } else |err| {
        std.log.warn("AUMID: self exe path unavailable for IconUri err={}", .{err});
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
    }
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
    std.fs.accessAbsolute(icon_path, .{}) catch |err| {
        std.log.info("AUMID: {s} not found next to exe ({}); leaving IconUri unchanged", .{ icon_file_name, err });
        alloc.free(icon_path);
        return null;
    };
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
