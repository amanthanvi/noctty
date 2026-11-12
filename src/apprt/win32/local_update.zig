//! Updating from an `update.zip` dropped beside `koreterm.exe`, with no
//! server: at start the app looks for one (`find`), and when it holds a newer
//! version than this one it shows what is new and asks (`ask`). Update hands
//! the swap to a small PowerShell script (`apply`) that waits for koreterm to
//! close, copies the package's files over the program's, deletes the ZIP and
//! starts koreterm again. Ignore remembers the version in `update.ignored`, so
//! the same package does not ask again.
//!
//! The package holds the portable program files, `version.txt` (the new
//! version, `major.minor.patch`) and `whats-new.txt` (what to show), the two
//! text files stored uncompressed (`scripts/make-update-zip.ps1` makes it so).
//! The program's data (config, logins, session) is not in it, so an update
//! leaves it alone.
const std = @import("std");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const HWND = win32_types.HWND;
const BOOL = win32_types.BOOL;

pub const zip_name = "update.zip";
pub const ignored_name = "update.ignored";

pub const Pending = struct {
    dir: []const u8,
    zip_path: []const u8,
    version: []const u8,
    notes: []const u8,
};

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) ?Version {
        const trimmed = std.mem.trim(u8, text, " \t\r\n\xEF\xBB\xBF");
        // `1.3.139`, maybe with `-something` after it.
        const core = trimmed[0 .. std.mem.indexOfAny(u8, trimmed, "-+") orelse trimmed.len];
        var parts = std.mem.splitScalar(u8, core, '.');
        const major = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
        const minor = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
        const patch = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
        if (parts.next() != null) return null;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn newerThan(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch > other.patch;
    }
};

/// An `update.zip` beside the executable whose version is newer than
/// `current` and not ignored, read in `a` (an arena). Null otherwise.
pub fn find(a: Allocator, current: []const u8) ?Pending {
    const dir = std.fs.selfExeDirPathAlloc(a) catch return null;
    const zip_path = std.fs.path.join(a, &.{ dir, zip_name }) catch return null;
    const bytes = std.fs.cwd().readFileAlloc(a, zip_path, 512 * 1024 * 1024) catch return null;
    const version_text = storedEntry(bytes, "version.txt") orelse return null;
    const version = std.mem.trim(u8, version_text, " \t\r\n\xEF\xBB\xBF");
    const new = Version.parse(version) orelse return null;
    const now = Version.parse(current) orelse return null;
    if (!new.newerThan(now)) return null;
    const ignored_path = std.fs.path.join(a, &.{ dir, ignored_name }) catch return null;
    if (std.fs.cwd().readFileAlloc(a, ignored_path, 256)) |ignored| {
        if (std.mem.eql(u8, std.mem.trim(u8, ignored, " \t\r\n"), version)) return null;
    } else |_| {}
    const notes = storedEntry(bytes, "whats-new.txt") orelse "";
    return .{ .dir = dir, .zip_path = zip_path, .version = version, .notes = std.mem.trim(u8, notes, " \t\r\n\xEF\xBB\xBF") };
}

/// The bytes of `name` (any case, at the archive's root or one folder deep)
/// in the ZIP `bytes`, when it is stored uncompressed.
pub fn storedEntry(bytes: []const u8, name: []const u8) ?[]const u8 {
    if (bytes.len < 22) return null;
    // The end record, within the last 64 KiB (its comment can be that long).
    var end: usize = bytes.len - 22;
    const floor = bytes.len -| (22 + 65535);
    while (true) : (end -= 1) {
        if (std.mem.readInt(u32, bytes[end..][0..4], .little) == 0x06054b50) break;
        if (end == floor) return null;
    }
    const count = std.mem.readInt(u16, bytes[end + 10 ..][0..2], .little);
    var at: usize = std.mem.readInt(u32, bytes[end + 16 ..][0..4], .little);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (at + 46 > bytes.len or std.mem.readInt(u32, bytes[at..][0..4], .little) != 0x02014b50) return null;
        const method = std.mem.readInt(u16, bytes[at + 10 ..][0..2], .little);
        const size = std.mem.readInt(u32, bytes[at + 20 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, bytes[at + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, bytes[at + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, bytes[at + 32 ..][0..2], .little);
        const local: usize = std.mem.readInt(u32, bytes[at + 42 ..][0..4], .little);
        if (at + 46 + name_len > bytes.len) return null;
        const entry_name = bytes[at + 46 ..][0..name_len];
        at += 46 + name_len + extra_len + comment_len;
        const base = if (std.mem.lastIndexOfAny(u8, entry_name, "/\\")) |slash| entry_name[slash + 1 ..] else entry_name;
        const depth = std.mem.count(u8, entry_name, "/") + std.mem.count(u8, entry_name, "\\");
        if (depth > 1 or !std.ascii.eqlIgnoreCase(base, name)) continue;
        if (method != 0) return null;
        if (local + 30 > bytes.len) return null;
        const local_name = std.mem.readInt(u16, bytes[local + 26 ..][0..2], .little);
        const local_extra = std.mem.readInt(u16, bytes[local + 28 ..][0..2], .little);
        const start = local + 30 + local_name + local_extra;
        if (start + size > bytes.len) return null;
        return bytes[start..][0..size];
    }
    return null;
}

extern "user32" fn MessageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;

pub const Answer = enum { update, ignore };

/// Windows' dialog: the new version, what is new, Update (Yes) or Ignore
/// (No).
pub fn ask(a: Allocator, owner: ?HWND, pending: Pending, current: []const u8) Answer {
    const notes = if (pending.notes.len == 0) "(no notes)" else pending.notes;
    const shown = notes[0..@min(notes.len, 3000)];
    const text = std.fmt.allocPrint(a, "koreterm {s} is ready to install (this is {s}).\n\nWhat's new:\n{s}\n\nUpdate now? koreterm closes, updates and opens again.\nNo ignores this version.", .{ pending.version, current, shown }) catch return .ignore;
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(a, text) catch return .ignore;
    const MB_YESNO: u32 = 0x4;
    const MB_ICONINFORMATION: u32 = 0x40;
    const MB_SETFOREGROUND: u32 = 0x10000;
    const IDYES: i32 = 6;
    const answer = MessageBoxW(owner, text_w.ptr, std.unicode.utf8ToUtf16LeStringLiteral("koreterm update"), MB_YESNO | MB_ICONINFORMATION | MB_SETFOREGROUND);
    return if (answer == IDYES) .update else .ignore;
}

/// Ignore: the next start does not ask about `pending.version` again.
pub fn ignore(a: Allocator, pending: Pending) void {
    const path = std.fs.path.join(a, &.{ pending.dir, ignored_name }) catch return;
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = pending.version }) catch {};
}

const update_script =
    \\param([int]$ProcessId, [string]$Zip, [string]$Target, [string]$Exe)
    \\$ErrorActionPreference = 'Stop'
    \\try { Wait-Process -Id $ProcessId -Timeout 120 -ErrorAction SilentlyContinue } catch {}
    \\Start-Sleep -Milliseconds 700
    \\$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('koreterm-update-' + [guid]::NewGuid())
    \\try {
    \\  Expand-Archive -LiteralPath $Zip -DestinationPath $tmp -Force
    \\  $src = $tmp
    \\  if (-not (Test-Path -LiteralPath (Join-Path $tmp 'koreterm.exe'))) {
    \\    $inner = Get-ChildItem -LiteralPath $tmp -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'koreterm.exe') } | Select-Object -First 1
    \\    if ($inner) { $src = $inner.FullName }
    \\  }
    \\  & robocopy.exe $src $Target /E /XF version.txt whats-new.txt /R:20 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    \\  Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
    \\  Remove-Item -LiteralPath (Join-Path $Target 'update.ignored') -Force -ErrorAction SilentlyContinue
    \\} finally {
    \\  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    \\  $current = Join-Path $Target 'koreterm.exe'
    \\  if (Test-Path -LiteralPath $current) { $Exe = $current }
    \\  Start-Process -FilePath $Exe -WorkingDirectory $Target
    \\}
;

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?*anyopaque = null,
    hStdOutput: ?*anyopaque = null,
    hStdError: ?*anyopaque = null,
};
const PROCESS_INFORMATION = extern struct {
    hProcess: ?*anyopaque,
    hThread: ?*anyopaque,
    dwProcessId: u32,
    dwThreadId: u32,
};
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

/// Update: write the script to the temp folder and start it, hidden and
/// detached. The caller quits koreterm right after; the script waits for
/// this process to end.
pub fn apply(a: Allocator, pending: Pending) !void {
    const tmp_dir = std.process.getEnvVarOwned(a, "TEMP") catch try a.dupe(u8, pending.dir);
    const script_path = try std.fmt.allocPrint(a, "{s}\\koreterm-update-{d}.ps1", .{ tmp_dir, GetCurrentProcessId() });
    try std.fs.cwd().writeFile(.{ .sub_path = script_path, .data = update_script });
    const exe = try std.fs.selfExePathAlloc(a);
    const command = try std.fmt.allocPrint(
        a,
        "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{s}\" -ProcessId {d} -Zip \"{s}\" -Target \"{s}\" -Exe \"{s}\"",
        .{ script_path, GetCurrentProcessId(), pending.zip_path, pending.dir, exe },
    );
    const command_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, command);
    var si: STARTUPINFOW = .{ .cb = @sizeOf(STARTUPINFOW), .dwFlags = 0x1, .wShowWindow = 0 }; // STARTF_USESHOWWINDOW, SW_HIDE
    var pi: PROCESS_INFORMATION = undefined;
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x01000000;
    if (CreateProcessW(null, command_w.ptr, null, null, 0, CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB, null, null, &si, &pi) == 0) {
        // A job that refuses breakaway: start it inside the job instead.
        if (CreateProcessW(null, command_w.ptr, null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi) == 0) return error.UpdaterNotStarted;
    }
    _ = CloseHandle(pi.hThread);
    _ = CloseHandle(pi.hProcess);
}

test "local update: versions compare by number" {
    const a = Version.parse("1.3.139").?;
    const b = Version.parse("1.3.138").?;
    try std.testing.expect(a.newerThan(b));
    try std.testing.expect(!b.newerThan(a));
    try std.testing.expect(Version.parse("1.10.0").?.newerThan(Version.parse("1.9.99").?));
    try std.testing.expect(Version.parse("1.3.138-dev").?.patch == 138);
    try std.testing.expect(Version.parse("1.3") == null);
}

test "local update: a stored entry is read from the archive" {
    const backup = @import("settings_backup.zig");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try backup.writeZip(&out.writer, &.{
        .{ .name = "koreterm/koreterm.exe", .data = "MZ..." },
        .{ .name = "version.txt", .data = "1.3.139\r\n" },
        .{ .name = "whats-new.txt", .data = "- RDP tabs" },
    }, 1762900000);
    try std.testing.expectEqualStrings("1.3.139\r\n", storedEntry(out.written(), "version.txt").?);
    try std.testing.expectEqualStrings("- RDP tabs", storedEntry(out.written(), "WHATS-NEW.TXT").?);
    try std.testing.expect(storedEntry(out.written(), "missing.txt") == null);
}
