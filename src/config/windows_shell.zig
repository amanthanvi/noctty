const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const win32 = @import("../os/windows.zig");
const Command = @import("command.zig").Command;
const windows_shell_types = @import("windows_shell_types.zig");
const windows_ssh_hosts = @import("windows_ssh_hosts.zig");
const log = std.log.scoped(.windows_shell);
const windows = std.os.windows;

const wsl_probe_timeout_ms: windows.DWORD = 1500;
const wsl_list_timeout_ms: windows.DWORD = 1500;
var wsl_probe_mutex: std.Thread.Mutex = .{};
var wsl_probe_cache: ?bool = null;
var wsl_profile_probe_cache: ?bool = null;
var ssh_missing_mutex: std.Thread.Mutex = .{};
var ssh_missing_logged = false;
const wsl_shell_integration_next_step =
    "Enable shell integration inside the selected WSL shell startup.";

pub const ProfileKind = windows_shell_types.ProfileKind;
pub const Utf8Console = windows_shell_types.Utf8Console;

/// ANSI/OEM code pages where forcing 65001 would mojibake legacy programs.
/// 932 Shift-JIS, 936 GBK, 949 Unified Hangul Code, 950 Big5, 1361 Johab.
const legacy_cjk_code_pages = [_]u32{ 932, 936, 949, 950, 1361 };

pub fn shouldApplyUtf8Console(
    mode: Utf8Console,
    ansi_code_page: u32,
    oem_code_page: u32,
) bool {
    return switch (mode) {
        .never => false,
        .always => true,
        .auto => !isLegacyCjkCodePage(ansi_code_page) and
            !isLegacyCjkCodePage(oem_code_page),
    };
}

pub fn shouldApplyUtf8ConsoleForCurrentSystem(mode: Utf8Console) bool {
    if (comptime builtin.os.tag != .windows) return false;
    return shouldApplyUtf8Console(mode, win32.GetACP(), win32.GetOEMCP());
}

fn isLegacyCjkCodePage(code_page: u32) bool {
    for (legacy_cjk_code_pages) |legacy| {
        if (code_page == legacy) return true;
    }
    return false;
}

pub const ShellIntegrationSupport = enum {
    automatic,
    shell_managed,
    manual,
    unavailable,
};

pub const ShellIntegrationDiagnostic = struct {
    support: ShellIntegrationSupport,
    summary: []const u8,
    next_step: ?[]const u8 = null,
};

pub const Profile = struct {
    kind: ProfileKind,
    key: []const u8,
    label: []const u8,
    palette_title: ?[]const u8 = null,
    command: Command,

    pub fn deinit(self: *Profile, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.label);
        if (self.palette_title) |value| alloc.free(value);
        self.command.deinit(alloc);
    }
};

pub const ProfileDiscovery = struct {
    profiles: []Profile,
    complete: bool,
};

/// The command a terminal runs when `command` is unset: PowerShell 7+
/// (`pwsh.exe`), else Windows PowerShell, else Command Prompt. WSL is never
/// chosen here, because `wsl.exe --status` can report a healthy installation
/// when launching a session would still fail; a distribution is picked from
/// the profile picker or by `command = wsl.exe`.
///
/// Nothing is launched, and `PATH` entries that are network or device paths,
/// or folder links to one, are never searched, so this is safe on the UI thread
/// while the configuration loads. A direct command skips the `cmd.exe /C`
/// trampoline.
pub fn defaultCommand(alloc: Allocator) !Command {
    return try defaultCommandWithHost(alloc, DefaultShellHost);
}

/// The command safe mode runs: always Command Prompt, as `cmd.exe /D`. Recovery
/// has to work when the user's own startup files are what broke. PowerShell
/// loads `$PROFILE` even under the shell integration's `-NoExit -Command`;
/// `cmd.exe` reads no profile, and `/D` also skips the `AutoRun` command that
/// a registry value or Clink can hang there.
pub fn recoveryCommand(alloc: Allocator) !Command {
    return try commandPromptWithHost(alloc, DefaultShellHost, &.{"/D"});
}

pub fn listProfiles(alloc: Allocator, include_ssh_hosts: bool) ![]Profile {
    const order_hint = detectProfileOrderHint(alloc);
    defer if (order_hint) |value| alloc.free(value);

    const shell_profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookupExecutable,
        probeWslExecutableCached,
        listWslDistros,
        order_hint,
        null,
    );
    return try appendConfiguredSshProfiles(alloc, shell_profiles, include_ssh_hosts, null);
}

pub fn discoverProfiles(alloc: Allocator, include_ssh_hosts: bool) !ProfileDiscovery {
    const order_hint = detectProfileOrderHint(alloc);
    defer if (order_hint) |value| alloc.free(value);

    var complete = true;
    const shell_profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookupExecutable,
        probeWslExecutableForProfiles,
        listWslDistros,
        order_hint,
        &complete,
    );
    return .{
        .profiles = try appendConfiguredSshProfiles(alloc, shell_profiles, include_ssh_hosts, &complete),
        .complete = complete,
    };
}

fn appendConfiguredSshProfiles(
    alloc: Allocator,
    shell_profiles: []Profile,
    include_ssh_hosts: bool,
    complete: ?*bool,
) ![]Profile {
    if (!include_ssh_hosts) return shell_profiles;

    // SSH discovery is additive. Any failure below degrades to the detected
    // shells rather than propagating, because the caller treats an error as
    // "no profiles at all" and would leave the user with no picker.
    const hosts = windows_ssh_hosts.load(alloc) catch |err| {
        // Busy: another discovery was reading the config at the same
        // moment. Not worth a warning; the incomplete list is retried.
        if (err != error.SshConfigReadBusy) warnSshDiscoveryOnce(err);
        if (complete) |value| value.* = false;
        return shell_profiles;
    };
    defer windows_ssh_hosts.deinitHosts(alloc, hosts);
    if (hosts.len == 0) return shell_profiles;

    const ssh_path = resolveSshExecutable(alloc, lookupExecutable, accessAbsolute) catch |err| {
        warnSshDiscoveryOnce(err);
        if (complete) |value| value.* = false;
        return shell_profiles;
    };
    if (ssh_path == null) {
        warnMissingSshOnce();
        return shell_profiles;
    }
    defer alloc.free(ssh_path.?);
    return try appendSshProfiles(alloc, shell_profiles, hosts, ssh_path.?);
}

/// The profile that is the shell `defaultCommand` chose, so the picker's
/// starting selection names what a new tab really runs instead of the first
/// entry in the list (WSL, when it is installed). Null when the command is
/// none of the three shells it chooses between, or the list has no such profile.
pub fn profileIndexForDefaultCommand(profiles: []const Profile, command: Command) ?usize {
    if (command != .direct or command.direct.len == 0) return null;
    const base = std.fs.path.basename(command.direct[0]);
    const kind: ProfileKind = if (std.ascii.eqlIgnoreCase(base, "pwsh.exe"))
        .pwsh
    else if (std.ascii.eqlIgnoreCase(base, "powershell.exe"))
        .powershell
    else if (std.ascii.eqlIgnoreCase(base, "cmd.exe"))
        .cmd
    else
        return null;
    for (profiles, 0..) |profile, index| {
        if (profile.kind == kind) return index;
    }
    return null;
}

pub fn deinitProfiles(alloc: Allocator, profiles: []Profile) void {
    for (profiles) |*profile| profile.deinit(alloc);
    alloc.free(profiles);
}

/// Deep-copy `profiles` into `alloc` (a discovery that ran on another
/// thread allocates from its own allocator).
pub fn cloneProfiles(alloc: Allocator, profiles: []const Profile) ![]Profile {
    const out = try alloc.alloc(Profile, profiles.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |*profile| profile.deinit(alloc);
        alloc.free(out);
    }
    for (profiles, out) |src, *dst| {
        const key = try alloc.dupe(u8, src.key);
        errdefer alloc.free(key);
        const label = try alloc.dupe(u8, src.label);
        errdefer alloc.free(label);
        const palette_title = if (src.palette_title) |value| try alloc.dupe(u8, value) else null;
        errdefer if (palette_title) |value| alloc.free(value);
        dst.* = .{
            .kind = src.kind,
            .key = key,
            .label = label,
            .palette_title = palette_title,
            .command = try src.command.clone(alloc),
        };
        copied += 1;
    }
    return out;
}

test "cloneProfiles copies every field into the target allocator" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const src_alloc = arena.allocator();
    const argv = try src_alloc.alloc([:0]const u8, 2);
    argv[0] = try src_alloc.dupeZ(u8, "wsl.exe");
    argv[1] = try src_alloc.dupeZ(u8, "-d");
    const source = [_]Profile{
        .{ .kind = .pwsh, .key = "pwsh", .label = "PowerShell", .command = .{ .shell = try src_alloc.dupeZ(u8, "pwsh.exe") } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "Ubuntu", .palette_title = "WSL: Ubuntu", .command = .{ .direct = argv } },
    };
    const copy = try cloneProfiles(testing.allocator, &source);
    // Freeing the copy with the testing allocator proves nothing still
    // points into the arena.
    defer deinitProfiles(testing.allocator, copy);
    try testing.expectEqual(source.len, copy.len);
    for (source, copy) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqualStrings(a.key, b.key);
        try testing.expectEqualStrings(a.label, b.label);
        try testing.expect(a.key.ptr != b.key.ptr);
    }
    try testing.expectEqualStrings("WSL: Ubuntu", copy[1].palette_title.?);
    try testing.expectEqualStrings("-d", copy[1].command.direct[1]);
    try testing.expectEqualStrings("pwsh.exe", copy[0].command.shell);
}

test "cloneProfiles frees what it copied when an allocation fails" {
    const source = [_]Profile{
        .{ .kind = .pwsh, .key = "pwsh", .label = "PowerShell", .palette_title = "PS", .command = .{ .shell = "pwsh.exe" } },
        .{ .kind = .powershell, .key = "powershell", .label = "Windows PowerShell", .command = .{ .shell = "powershell.exe" } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "Ubuntu", .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } } },
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const copy = cloneProfiles(failing.allocator(), &source) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        deinitProfiles(failing.allocator(), copy);
        break;
    }
}

pub fn shellIntegrationDiagnostic(kind: ProfileKind) ShellIntegrationDiagnostic {
    return switch (kind) {
        .wsl_default, .wsl_distro => .{
            .support = .shell_managed,
            .summary = switch (kind) {
                .wsl_default => "WSL default profile; shell integration depends on the Linux shell",
                .wsl_distro => "WSL distro profile; shell integration depends on the Linux shell",
                else => unreachable,
            },
            .next_step = wsl_shell_integration_next_step,
        },
        .pwsh => .{
            .support = .automatic,
            .summary = "PowerShell profile with automatic shell integration",
        },
        .powershell => .{
            .support = .automatic,
            .summary = "Windows PowerShell profile with automatic shell integration",
        },
        .git_bash => .{
            .support = .automatic,
            .summary = "Git Bash profile with automatic shell integration",
        },
        .cmd => .{
            .support = .automatic,
            .summary = "Command Prompt profile with PROMPT-based shell integration; Clink adds command-start/finish and exit-code marks",
        },
        .ssh => .{
            .support = .unavailable,
            .summary = "SSH profile; shell integration is disabled for remote sessions",
            .next_step = "Enable shell integration inside the remote shell's own startup files.",
        },
    };
}

/// Config string quoting is removed before Command parsing. Recover a whole
/// executable path before splitting it, while preserving actual cmd strings.
/// The result may borrow command; new argv storage belongs to the arena.
pub fn executableCommand(alloc: Allocator, command: Command) !Command {
    if (builtin.os.tag != .windows or command == .direct) return command;
    var path = std.mem.trim(u8, command.shell, " \t");
    if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"')
        path = path[1 .. path.len - 1];
    // A relative executable is resolved against the pane's cwd by cmd, not
    // the app's cwd used by this probe and lpApplicationName. Keep that
    // existing contract, including drive-relative and root-relative values.
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or
        (path[2] != '\\' and path[2] != '/')) return command;
    const ext = std.fs.path.extension(path);
    if (!std.ascii.eqlIgnoreCase(ext, ".exe") and
        !std.ascii.eqlIgnoreCase(ext, ".com")) return command;
    // Screen these before querying attributes. A command value must not
    // introduce a network timeout on the terminal's startup path.
    if (internal_os.path.isNetworkOrDevicePath(path)) return command;
    if (internal_os.windows.driveTypeForLetter(path[0]) == internal_os.windows.DRIVE_REMOTE)
        return command;
    if (!windowsNonDirectoryPathExists(path)) return command;
    const argv = try alloc.alloc([:0]const u8, 1);
    errdefer alloc.free(argv);
    argv[0] = try alloc.dupeZ(u8, path);
    return .{ .direct = argv };
}

/// Resolve a bare integration executable using the child's search environment.
/// Never consult the app's PATH or cwd, and never probe a network PATH entry.
/// A batch/script match keeps the caller on its original shell launch path.
pub fn lookupChildExecutable(alloc: Allocator, exe: []const u8, env: *const std.process.EnvMap) !?[:0]const u8 {
    if (builtin.os.tag != .windows or exe.len == 0 or
        std.mem.indexOfAny(u8, exe, "\\/:") != null) return null;
    const path = env.get("PATH") orelse return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = searchPath(&buf, exe, path, env.get("PATHEXT"), false, acceptAnyPath) orelse return null;
    return try alloc.dupeZ(u8, found);
}

fn acceptAnyPath(_: []const u8) bool {
    return true;
}

/// The first file `exe` names in the `path` list (`PATH` syntax), as a slice of
/// `buf`. Only absolute local-drive entries are searched: a relative entry
/// would mean the current directory, and a network or device entry could stall
/// the caller. `pathext` is `PATHEXT` and only matters when `exe` has no
/// extension. `accept` can refuse a file that exists, and then the search goes
/// on in the next directory.
fn searchPath(
    buf: *[std.fs.max_path_bytes]u8,
    exe: []const u8,
    path: []const u8,
    pathext: ?[]const u8,
    comptime discovery: bool,
    accept: anytype,
) ?[]const u8 {
    const error_mode = struct {
        extern "kernel32" fn SetThreadErrorMode(mode: u32, previous: ?*u32) callconv(.winapi) windows.BOOL;
    };
    var previous_mode: u32 = 0;
    const suppressed = error_mode.SetThreadErrorMode(0x0001 | 0x8000, &previous_mode) != 0;
    defer if (suppressed) {
        _ = error_mode.SetThreadErrorMode(previous_mode, null);
    };
    const extension = std.fs.path.extension(exe);
    var dirs = std.mem.splitScalar(u8, path, ';');
    dirs: while (dirs.next()) |raw_dir| {
        var dir = std.mem.trim(u8, raw_dir, " \t");
        if (dir.len >= 2 and dir[0] == '"' and dir[dir.len - 1] == '"')
            dir = dir[1 .. dir.len - 1];
        if (internal_os.path.isNetworkOrDevicePath(dir) or dir.len < 3 or
            !std.ascii.isAlphabetic(dir[0]) or dir[1] != ':' or
            (dir[2] != '\\' and dir[2] != '/')) continue;
        const drive_type = internal_os.windows.driveTypeForLetter(dir[0]);
        if (drive_type == internal_os.windows.DRIVE_REMOTE) continue;
        // Discovery never spins up removable/optical media on the UI thread.
        if (discovery and drive_type != internal_os.windows.DRIVE_FIXED and
            drive_type != internal_os.windows.DRIVE_RAMDISK) continue;
        if (discovery and !isLocalSearchDirectory(dir)) continue;
        var extensions = std.mem.splitScalar(u8, if (extension.len > 0) "" else pathext orelse ".COM;.EXE;.BAT;.CMD", ';');
        while (extensions.next()) |raw_ext| {
            const ext = std.mem.trim(u8, raw_ext, " \t");
            if (extension.len == 0) {
                if (ext.len < 2 or ext[0] != '.') continue;
                // PATHEXT supplies suffixes, not paths or cmd syntax.
                var valid = true;
                for (ext[1..]) |c| if (!std.ascii.isAlphanumeric(c)) {
                    valid = false;
                    break;
                };
                if (!valid) continue;
            }
            const candidate = std.fmt.bufPrint(buf, "{s}\\{s}{s}", .{ dir, exe, ext }) catch continue;
            if (discovery) {
                const attributes = pathAttributes(candidate) orelse continue;
                if (attributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) continue;
            } else if (!windowsNonDirectoryPathExists(candidate)) continue;
            const found_ext = if (extension.len > 0) extension else ext;
            if (!std.ascii.eqlIgnoreCase(found_ext, ".exe") and
                !std.ascii.eqlIgnoreCase(found_ext, ".com")) return null;
            if (!accept(candidate)) continue :dirs;
            return candidate;
        }
    }
    return null;
}

/// Disable cmd's implicit cwd executable search for the final shell wrapper.
/// Keep this in its environment: clearing it before the target immediately
/// restores cwd lookup. Explicit paths and PATH entries retain cmd semantics.
pub fn configureShellSearch(env: *std.process.EnvMap, windows_cmd_shell: bool) !void {
    if (builtin.os.tag == .windows and windows_cmd_shell and
        env.get("NoDefaultCurrentDirectoryInExePath") == null)
        try env.put("NoDefaultCurrentDirectoryInExePath", "1");
}

test "PKG48 only shell wrappers receive the inherited cwd search guard" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "relative;C:\\Tools!;%literal%");
    try configureShellSearch(&env, false);
    try std.testing.expect(env.get("NoDefaultCurrentDirectoryInExePath") == null);
    try configureShellSearch(&env, true);
    try std.testing.expectEqualStrings("1", env.get("NoDefaultCurrentDirectoryInExePath").?);
    inline for (.{ "user-value", "" }) |value| {
        try env.put("NoDefaultCurrentDirectoryInExePath", value);
        try configureShellSearch(&env, true);
        try std.testing.expectEqualStrings(value, env.get("NoDefaultCurrentDirectoryInExePath").?);
    }
    try std.testing.expectEqualStrings("relative;C:\\Tools!;%literal%", env.get("PATH").?);
}

/// App Execution Aliases are reparse points whose target cannot be opened
/// or stat'ed as an ordinary file. Query the path itself, accepting aliases.
/// Callers must screen network/device paths and remote drives first.
fn windowsNonDirectoryPathExists(path: []const u8) bool {
    // Explicit commands retain Windows link semantics, including Scoop's
    // current junction and paths with spaces. Only discovery refuses redirects.
    const path_w = windows.sliceToPrefixedFileW(null, path) catch return false;
    const attributes = windows.kernel32.GetFileAttributesW(path_w.span().ptr);
    if (attributes == windows.INVALID_FILE_ATTRIBUTES) return false;
    return attributes & windows.FILE_ATTRIBUTE_DIRECTORY == 0;
}

/// Open only the final object, refusing every reparse ancestor in the kernel.
/// FILE_OPEN_REPARSE_POINT lets us inspect a final Store alias without following
/// it. OBJ_DONT_REPARSE prevents even a metadata query from traversing an
/// ancestor link into a share or an unchecked redirect chain.
fn openPathNoRedirect(path: []const u8) ?windows.HANDLE {
    if (!isDriveAbsolutePath(path) or internal_os.path.isNetworkOrDevicePath(path)) return null;
    const drive_type = internal_os.windows.driveTypeForLetter(path[0]);
    if (drive_type != internal_os.windows.DRIVE_FIXED and drive_type != internal_os.windows.DRIVE_RAMDISK) return null;
    var wide = windows.sliceToPrefixedFileW(null, path) catch return null;
    // Older Windows also treats the DOS drive-letter mapping as a reparse.
    // Resolve just that mapping without opening a filesystem target, and accept
    // only a direct local volume device. The rest keeps the kernel guard.
    if (!internal_os.windows.directVolumePath(&wide)) return null;
    var name: windows.UNICODE_STRING = .{
        .Length = @intCast(wide.span().len * 2),
        .MaximumLength = @intCast(wide.span().len * 2),
        .Buffer = @constCast(wide.span().ptr),
    };
    var attrs: windows.OBJECT_ATTRIBUTES = .{
        .Length = @sizeOf(windows.OBJECT_ATTRIBUTES),
        .RootDirectory = null,
        .ObjectName = &name,
        .Attributes = 0x1000, // OBJ_DONT_REPARSE
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var io: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    const status = windows.ntdll.NtCreateFile(
        &handle,
        windows.FILE_READ_ATTRIBUTES | windows.SYNCHRONIZE,
        &attrs,
        &io,
        null,
        windows.FILE_ATTRIBUTE_NORMAL,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        windows.FILE_OPEN,
        windows.FILE_OPEN_REPARSE_POINT | windows.FILE_SYNCHRONOUS_IO_NONALERT,
        null,
        0,
    );
    return if (status == .SUCCESS) handle else null;
}

/// Attributes of the final object, with no ancestor or final link followed.
fn pathInfo(path: []const u8) ?windows.FILE_ATTRIBUTE_TAG_INFO {
    const handle = openPathNoRedirect(path) orelse return null;
    defer windows.CloseHandle(handle);
    var info: windows.FILE_ATTRIBUTE_TAG_INFO = undefined;
    var io: windows.IO_STATUS_BLOCK = undefined;
    if (windows.ntdll.NtQueryInformationFile(handle, &io, &info, @sizeOf(@TypeOf(info)), .FileAttributeTagInformation) != .SUCCESS) return null;
    return info;
}

fn pathAttributes(path: []const u8) ?windows.DWORD {
    return (pathInfo(path) orelse return null).FileAttributes;
}

/// A file `CreateProcess` can start. Besides local data reparse tags, accept an App
/// Execution Alias whose package is installed: the Store's PowerShell and the
/// Python launcher put one on `PATH`, and an alias can stay behind after its
/// package is gone. Following a symlink or junction would open its target,
/// which can be on a network share, so those are not accepted.
/// The caller screens network and device paths first.
fn isLaunchableFile(path: []const u8) bool {
    const info = pathInfo(path) orelse return false;
    if (isLocalExecutableInfo(info)) return true;
    if (info.FileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) return false;
    return appExecLinkTargetExists(path);
}

/// WOF compression and deduplication keep file data on the local volume.
/// Neither is a name redirect or a cloud placeholder that can fetch data.
fn isLocalExecutableInfo(info: windows.FILE_ATTRIBUTE_TAG_INFO) bool {
    if (info.FileAttributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) return false;
    return info.FileAttributes & windows.FILE_ATTRIBUTE_REPARSE_POINT == 0 or
        info.ReparseTag == 0x80000017 or info.ReparseTag == 0x80000013;
}

/// The reparse data of the open reparse point `handle`, as the slice of `buf`
/// the call filled, or null.
fn readReparseData(handle: windows.HANDLE, buf: []align(4) u8) ?[]const u8 {
    var returned: windows.DWORD = 0;
    if (internal_os.windows.DeviceIoControl(
        handle,
        windows.FSCTL_GET_REPARSE_POINT,
        null,
        0,
        buf.ptr,
        @intCast(buf.len),
        &returned,
        null,
    ) == 0) return null;
    return buf[0..@min(returned, buf.len)];
}

/// Only ordinary local folders are searched. Reparse ancestors are rejected
/// by openPathNoRedirect; final folder links and cloud placeholders are skipped.
fn isLocalSearchDirectory(dir: []const u8) bool {
    const attributes = pathAttributes(dir) orelse return false;
    return attributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0 and
        attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT == 0;
}

const IO_REPARSE_TAG_APPEXECLINK: u32 = 0x8000001b;

/// Whether the alias at `path` points at a file that exists. Reads the alias's
/// reparse data and never launches it (an alias to a missing package can open
/// the Store).
fn appExecLinkTargetExists(path: []const u8) bool {
    const handle = openPathNoRedirect(path) orelse return false;
    defer windows.CloseHandle(handle);
    var data: [windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = @splat(0);
    const record = readReparseData(handle, &data) orelse return false;
    var target_w: [1024]u16 = undefined;
    const target_len = appExecLinkTarget(record, &target_w) orelse return false;
    var target_buf: [3 * target_w.len]u8 = undefined;
    const target_end = std.unicode.utf16LeToUtf8(&target_buf, target_w[0..target_len]) catch return false;
    const target = target_buf[0..target_end];
    // A local file only; the screen is the one for any path a program reports.
    if (!isDriveAbsolutePath(target) or internal_os.path.isNetworkOrDevicePath(target)) return false;
    if (internal_os.windows.driveTypeForLetter(target[0]) == internal_os.windows.DRIVE_REMOTE) return false;
    return isLocalExecutableInfo(pathInfo(target) orelse return false);
}

/// The target of an App Execution Alias, copied as UTF-16 into `out`, from the
/// output of `FSCTL_GET_REPARSE_POINT`: the reparse header (tag, data length,
/// reserved), a version `3`, and four NUL-terminated UTF-16 strings, namely
/// the package family name, the AppUserModelID, the target path and the
/// application type. Layout as read from the aliases of installed packages
/// (the same one libuv reads). Returns the length of the target, or null for
/// any other tag, a version, or a record that is not exactly those four
/// strings: the buffer is zeroed before the call, so a length header that
/// claims more than the call returned reads as empty strings and fails here.
fn appExecLinkTarget(data: []const u8, out: []u16) ?usize {
    if (data.len < 12 or std.mem.readInt(u32, data[0..4], .little) != IO_REPARSE_TAG_APPEXECLINK) return null;
    const end = 8 + @as(usize, std.mem.readInt(u16, data[4..6], .little));
    if (end > data.len or end < 12 or std.mem.readInt(u32, data[8..12], .little) != 3) return null;
    const strings = data[12..end];
    var index: usize = 0;
    var start: usize = 0;
    var fields: usize = 0;
    var target: []const u8 = &.{};
    while (index + 2 <= strings.len and fields < 4) : (index += 2) {
        if (strings[index] != 0 or strings[index + 1] != 0) continue;
        if (fields == 2) target = strings[start..index];
        fields += 1;
        start = index + 2;
    }
    if (fields != 4 or start != strings.len or target.len == 0 or target.len / 2 > out.len) return null;
    for (0..target.len / 2) |i| out[i] = std.mem.readInt(u16, target[2 * i ..][0..2], .little);
    return target.len / 2;
}

test "PKG08 round2 child executable lookup respects PATHEXT and local PATH" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "nu.exe", .data = "exe" });
    try tmp.dir.writeFile(.{ .sub_path = "nu.com", .data = "com" });
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    var env = std.process.EnvMap.init(alloc);
    try env.put("PATH", try std.fmt.allocPrint(alloc, "relative;;\\\\server\\share;\\??\\UNC\\server\\share;\"{s}\"", .{dir}));
    try env.put("PATHEXT", ".com;.exe");
    try std.testing.expectEqualStrings(try tmp.dir.realpathAlloc(alloc, "nu.com"), (try lookupChildExecutable(alloc, "nu", &env)).?);
    try env.put("PATHEXT", ".exe;.com");
    try std.testing.expectEqualStrings(try tmp.dir.realpathAlloc(alloc, "nu.exe"), (try lookupChildExecutable(alloc, "nu", &env)).?);
    // An explicit extension is looked up exactly, regardless of PATHEXT.
    try env.put("PATHEXT", ".com");
    try std.testing.expectEqualStrings(try tmp.dir.realpathAlloc(alloc, "nu.exe"), (try lookupChildExecutable(alloc, "nu.exe", &env)).?);
    // Preserve a cmd/batch wrapper that wins PATHEXT instead of skipping it.
    try tmp.dir.writeFile(.{ .sub_path = "nu.cmd", .data = "wrapper" });
    try env.put("PATHEXT", ".cmd;.exe");
    try std.testing.expect(try lookupChildExecutable(alloc, "nu", &env) == null);
    try std.testing.expect(try lookupChildExecutable(alloc, "missing", &env) == null);
    try tmp.dir.makeDir("directory.exe");
    try std.testing.expect(try lookupChildExecutable(alloc, "directory.exe", &env) == null);
    for ([_][]const u8{ "C:nu", ".\\nu", "\\nu", "\\\\server\\nu" }) |value|
        try std.testing.expect(try lookupChildExecutable(alloc, value, &env) == null);
}

test "PKG08 round3 child lookup accepts a real App Execution Alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var host_env = try std.process.getEnvMap(alloc);
    const local_app_data = host_env.get("LOCALAPPDATA") orelse return error.SkipZigTest;
    const dir = try std.fs.path.join(alloc, &.{ local_app_data, "Microsoft", "WindowsApps" });
    if (internal_os.path.isNetworkOrDevicePath(dir) or
        dir.len < 3 or dir[1] != ':' or
        internal_os.windows.driveTypeForLetter(dir[0]) == internal_os.windows.DRIVE_REMOTE)
        return error.SkipZigTest;
    var env = std.process.EnvMap.init(alloc);
    try env.put("PATH", dir);
    try env.put("PATHEXT", ".EXE");
    // These aliases are installed by Store PowerShell or the Windows Python
    // launcher. Do not launch them: an unconfigured alias can open the Store.
    for ([_][]const u8{ "pwsh.exe", "python.exe", "python3.exe" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ dir, name });
        const attributes = windows.GetFileAttributes(path) catch continue;
        if (attributes & windows.FILE_ATTRIBUTE_REPARSE_POINT == 0 or
            attributes & windows.FILE_ATTRIBUTE_DIRECTORY != 0) continue;
        const result = try lookupChildExecutable(alloc, name, &env);
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings(path, result.?);
        const normalized = try executableCommand(alloc, .{ .shell = try alloc.dupeZ(u8, path) });
        try std.testing.expect(normalized == .direct);
        try std.testing.expectEqualStrings(path, normalized.direct[0]);
        return;
    }
    return error.SkipZigTest;
}

test "PKG08 whole executable path with spaces launches directly" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("PowerShell 7");
    const exe = try tmp.dir.createFile("PowerShell 7/pwsh.exe", .{});
    exe.close();
    const path = try tmp.dir.realpathAlloc(alloc, "PowerShell 7/pwsh.exe");
    const input: Command = .{ .shell = try alloc.dupeZ(u8, path) };
    const result = try prepareCommandWithLookup(std.testing.allocator, input, null, false, false, lookupExecutable);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result == .direct);
    try std.testing.expectEqual(@as(usize, 1), result.direct.len);
    try std.testing.expectEqualStrings(path, result.direct[0]);
    const current = try std.process.getCwdAlloc(alloc);
    const relative = try std.fs.path.relative(alloc, current, path);
    const relative_input: Command = .{ .shell = try alloc.dupeZ(u8, relative) };
    const preserved = try executableCommand(alloc, relative_input);
    try std.testing.expect(preserved == .shell);
    try std.testing.expectEqualStrings(relative, preserved.shell);
    for ([_][:0]const u8{ "C:pwsh.exe", "\\pwsh.exe", "\\\\server\\share\\pwsh.exe" }) |value| {
        try std.testing.expect((try executableCommand(alloc, .{ .shell = value })) == .shell);
    }
}

/// Prepare a command for Windows spawning. This applies the guarded UTF-8
/// preamble to payload-free cmd launches and translates WSL working
/// directories into `wsl.exe --cd ...` without paying a shell trampoline cost.
pub fn prepareCommand(
    alloc: Allocator,
    command: Command,
    cwd: ?[]const u8,
    working_directory_home: bool,
    utf8_console: bool,
) !Command {
    return try prepareCommandWithLookup(
        alloc,
        command,
        cwd,
        working_directory_home,
        utf8_console,
        lookupExecutable,
    );
}

/// Determine a safe Windows host cwd for launching a command. This is
/// primarily needed for WSL, where the terminal cwd may be a WSL path or
/// `home` while CreateProcess still requires a Windows-local directory.
pub fn spawnCwd(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
) !?[]const u8 {
    if (cwd) |v| {
        if (isWindowsUriPath(v)) return try uriPathToWindows(alloc, v);
        if (isDriveAbsolutePath(v)) return try alloc.dupe(u8, v);
        if (isWslPath(v)) return try defaultWindowsHome(alloc);
        return try defaultWindowsHome(alloc);
    }

    _ = working_directory_home;
    return try defaultWindowsHome(alloc);
}

/// Determine a safe shell-visible PWD for Windows launches.
///
/// Non-WSL shells should only receive native Windows paths. WSL launches can
/// receive normalized WSL-style paths or the home sentinel. Obviously invalid
/// Windows cwd values such as `\\` are dropped entirely.
pub fn shellPwd(
    alloc: Allocator,
    cwd: ?[]const u8,
    is_wsl: bool,
) !?[]const u8 {
    const value = cwd orelse return null;

    const result: ?[]const u8 = result: {
        if (isWindowsUriPath(value)) break :result try uriPathToWindows(alloc, value);
        if (isDriveAbsolutePath(value)) break :result try alloc.dupe(u8, value);
        if (!is_wsl) break :result null;
        if (std.mem.eql(u8, value, "~")) break :result try alloc.dupe(u8, value);
        if (isWslPath(value)) break :result try normalizeWslPath(alloc, value);
        log.warn("dropping unsupported windows shell pwd cwd={s} is_wsl={}", .{ value, is_wsl });
        break :result null;
    };
    if (result) |path| {
        if (!isSafeWindowsPath(path)) {
            log.warn("dropping windows shell pwd with unsafe path bytes len={}", .{path.len});
            alloc.free(path);
            return null;
        }
    }
    return result;
}

/// Determine a safe CreateProcess cwd for Windows launches while preserving
/// inherit semantics when the caller did not request a specific cwd.
pub fn safeCurrentDirectory(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
    is_wsl: bool,
) !?[]const u8 {
    const current = try currentWindowsDirectory(alloc);

    const result = try safeCurrentDirectoryWithCurrent(
        alloc,
        cwd,
        working_directory_home,
        is_wsl,
        current,
    );
    if (result) |path| {
        if (!isSafeWindowsPath(path)) {
            log.warn("dropping windows current directory with unsafe path bytes len={}", .{path.len});
            alloc.free(path);
            return null;
        }
    }
    return result;
}

/// Takes ownership of `current` and frees it on every path.
fn safeCurrentDirectoryWithCurrent(
    alloc: Allocator,
    cwd: ?[]const u8,
    working_directory_home: bool,
    is_wsl: bool,
    current: ?[]const u8,
) !?[]const u8 {
    defer if (current) |value| alloc.free(value);

    if (cwd) |value| {
        if (isWindowsUriPath(value)) return try uriPathToWindows(alloc, value);
        if (isDriveAbsolutePath(value)) return try alloc.dupe(u8, value);
        if (is_wsl or isWslPath(value) or isObviouslyInvalidWindowsCurrentDirectory(value)) {
            log.warn("falling back to windows home for unsafe cwd cwd={s} is_wsl={}", .{ value, is_wsl });
            return try defaultWindowsHome(alloc);
        }

        log.warn("falling back to windows home for unsupported cwd cwd={s} is_wsl={}", .{ value, is_wsl });
        return try defaultWindowsHome(alloc);
    }

    if (current) |value| {
        if (isDriveAbsolutePath(value)) return try alloc.dupe(u8, value);
        if (isWindowsUriPath(value)) return try uriPathToWindows(alloc, value);
        if (isObviouslyInvalidWindowsCurrentDirectory(value)) {
            log.warn("falling back to windows home for inherited unsafe cwd cwd={s} is_wsl={}", .{ value, is_wsl });
            return try defaultWindowsHome(alloc);
        }

        log.warn("using inherited windows cwd cwd={s} is_wsl={}", .{ value, is_wsl });
        return try alloc.dupe(u8, value);
    }

    if (working_directory_home or is_wsl) return try defaultWindowsHome(alloc);
    return null;
}

fn currentWindowsDirectory(alloc: Allocator) !?[]const u8 {
    return std.process.getCwdAlloc(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            log.warn("failed to read current windows cwd err={}", .{err});
            return null;
        },
    };
}

fn prepareCommandWithLookup(
    alloc: Allocator,
    command_: Command,
    cwd: ?[]const u8,
    working_directory_home: bool,
    utf8_console: bool,
    lookup: anytype,
) !Command {
    const command = try executableCommand(alloc, command_);
    defer if (command_ == .shell and command == .direct) command.deinit(alloc);
    if (utf8_console) {
        if (try prepareCmdUtf8(alloc, command)) |prepared| return prepared;
    }

    if (!isWslCommand(command)) return try command.clone(alloc);

    const target_cwd: ?[]const u8 = cwd_: {
        if (cwd) |v| break :cwd_ try pathToWsl(alloc, v);
        if (working_directory_home) break :cwd_ try alloc.dupe(u8, "~");
        break :cwd_ null;
    };
    defer if (target_cwd) |v| alloc.free(v);

    return switch (command) {
        .direct => |argv| try prepareWslDirect(alloc, argv, target_cwd, lookup),

        // We only auto-rewrite WSL direct launches. A shell command is assumed
        // to be user-authored and remains untouched.
        .shell => try command.clone(alloc),
    };
}

/// The silent code-page switch we run before an interactive Command Prompt
/// draws its first prompt. `chcp` is idempotent, so this is a no-op when the
/// console already uses code page 65001.
const cmd_utf8_preamble = "chcp 65001 >nul";

/// Build the UTF-8 preamble form of a `cmd.exe` launch, or `null` when the
/// launch must be left byte-for-byte unchanged.
///
/// Only an interactive Command Prompt that carries no command payload of its
/// own is rewritten. Non-payload switches (`/d`, `/q`, `/v:on`, ...) are kept
/// in their original order and `/K "chcp 65001 >nul"` is appended after them.
fn prepareCmdUtf8(alloc: Allocator, command: Command) !?Command {
    var arg_iter = try command.argIterator(alloc);
    defer arg_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);

    const argv0 = arg_iter.next() orelse return null;
    if (!isExecutableName(argv0, "cmd") and
        !isExecutableName(argv0, "cmd.exe")) return null;
    try args.append(alloc, argv0);

    while (arg_iter.next()) |arg| {
        if (classifyCmdArg(arg) == .unsupported) return null;
        try args.append(alloc, arg);
    }

    try args.append(alloc, "/K");
    try args.append(alloc, cmd_utf8_preamble);
    return try directCommand(alloc, args.items);
}

const CmdArg = enum {
    /// A switch run carrying only non-payload options. Safe to preserve and
    /// to append our own `/K` after.
    option,

    /// A command payload switch or a token we don't recognize. The launch is
    /// left untouched.
    unsupported,
};

/// Classify one `cmd.exe` argument.
///
/// `cmd.exe` only treats `/` as a switch prefix (`-c` is a positional), and it
/// accepts fused switch runs such as `/d/q/c` and `/v:on/c`, so a run has to be
/// walked to the end before it can be called payload-free.
fn classifyCmdArg(arg: []const u8) CmdArg {
    if (arg.len < 2 or arg[0] != '/') return .unsupported;

    var i: usize = 0;
    while (i < arg.len) {
        // A fused run repeats the `/` separator: `/d/q/v:on`.
        if (arg[i] == '/') {
            i += 1;
            if (i >= arg.len) return .unsupported;
        }

        switch (std.ascii.toLower(arg[i])) {
            // `/c` and `/r` run a command and terminate; `/k` runs a command
            // and stays interactive. All three carry the user's own payload,
            // which we never touch.
            'c', 'r', 'k' => return .unsupported,

            // Valueless options: ANSI/Unicode piped output, quiet echo,
            // AutoRun suppression, and quoting mode. `/x` and `/y` are the
            // OS/2-compatibility spellings of `/e:on` and `/e:off`, which
            // `cmd /?` documents and which take no value.
            'a', 'u', 'q', 'd', 's', 'x', 'y' => i += 1,

            // `/e:on`, `/f:off`, `/v:on`.
            'e', 'f', 'v' => {
                i += 1;
                if (i >= arg.len or arg[i] != ':') return .unsupported;
                i += 1;
                if (asciiStartsWithIgnoreCase(arg[i..], "off")) {
                    i += "off".len;
                } else if (asciiStartsWithIgnoreCase(arg[i..], "on")) {
                    i += "on".len;
                } else return .unsupported;
            },

            // `/t:fg` takes one or two hex color digits.
            't' => {
                i += 1;
                if (i >= arg.len or arg[i] != ':') return .unsupported;
                i += 1;
                var digits: usize = 0;
                while (digits < 2 and i < arg.len and std.ascii.isHex(arg[i])) {
                    i += 1;
                    digits += 1;
                }
                if (digits == 0) return .unsupported;
            },

            else => return .unsupported,
        }

        // A run either ends here or continues with another `/`. Anything else
        // is a fused payload such as `/cecho hi`.
        if (i < arg.len and arg[i] != '/') return .unsupported;
    }

    return .option;
}

pub fn isWslCommand(command: Command) bool {
    return switch (command) {
        .direct => |argv| isWslArgv(argv),
        .shell => false,
    };
}

pub fn isWslArgv(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    return isExecutableName(argv[0], "wsl") or isExecutableName(argv[0], "wsl.exe");
}

pub fn isWslPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/") or
        std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\");
}

/// Convert a local path coming from OSC 7 into a Windows-local path string.
/// WSL paths stay WSL-style so they can be inherited into later WSL shells.
pub fn osc7PathToLocal(alloc: Allocator, path: []const u8) ![]const u8 {
    if (isWindowsUriPath(path)) return try uriPathToWindows(alloc, path);
    // A UNC path carried in a URI keeps the URI's leading `/`. Strip it before
    // the WSL check below, which would otherwise treat the whole string as a
    // POSIX path and hand back an unusable `/\\server\share` cwd.
    if (isUncUriPath(path)) {
        const unc = path[1..];
        if (isWslPath(unc)) return try normalizeWslPath(alloc, unc);
        return try alloc.dupe(u8, unc);
    }
    if (isWslPath(path)) return try normalizeWslPath(alloc, path);
    return try alloc.dupe(u8, path);
}

/// Translate a Windows or WSL-style path into a WSL path. Returns `null` for
/// paths we can't confidently map.
pub fn pathToWsl(alloc: Allocator, path: []const u8) !?[]const u8 {
    if (path.len == 0) return null;
    if (isWindowsUriPath(path)) return try pathToWsl(alloc, path[1..]);
    if (isUncUriPath(path)) return try pathToWsl(alloc, path[1..]);
    if (isWslPath(path)) return try normalizeWslPath(alloc, path);

    if (!isDriveAbsolutePath(path)) return null;

    const rest = trimLeadingSeparators(path[2..]);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "/mnt/");
    try buf.append(alloc, std.ascii.toLower(path[0]));
    if (rest.len == 0) {
        return try buf.toOwnedSlice(alloc);
    }

    try buf.append(alloc, '/');
    try appendNormalizedPath(&buf, alloc, rest);
    return try buf.toOwnedSlice(alloc);
}

/// Machine lookups return owned paths or null, and fail only on allocation.
/// Discovery requires guarded metadata; the final cmd fallback uses the system
/// path even when that metadata is unavailable, avoiding a current-dir search.
const DefaultShellHost = struct {
    /// `pwsh.exe` on the process's `PATH`.
    fn findPwsh(alloc: Allocator) !?[]u8 {
        return try lookupExecutable(alloc, "pwsh.exe");
    }

    /// `relative` below the Windows system directory. The built-in shells are
    /// taken from there, not from `PATH`, so a `powershell.exe` or `cmd.exe`
    /// placed earlier on `PATH` does not become the default shell.
    fn systemShell(alloc: Allocator, relative: []const u8) !?[]u8 {
        const path = (try systemPath(alloc, relative)) orelse return null;
        if (isLaunchableFile(path)) return path;
        alloc.free(path);
        return null;
    }

    fn systemPath(alloc: Allocator, relative: []const u8) !?[]u8 {
        if (builtin.os.tag != .windows) return null;
        var buf: [windows.MAX_PATH:0]u16 = undefined;
        const len = windows.kernel32.GetSystemDirectoryW(&buf, buf.len);
        if (len == 0 or len >= buf.len) return null;
        const dir = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..len]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer alloc.free(dir);
        return try std.fs.path.join(alloc, &.{ dir, relative });
    }
};

const windows_powershell_relative = "WindowsPowerShell\\v1.0\\powershell.exe";

fn defaultCommandWithHost(alloc: Allocator, comptime Host: type) !Command {
    if (try Host.findPwsh(alloc)) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }
    if (try Host.systemShell(alloc, windows_powershell_relative)) |path| {
        defer alloc.free(path);
        return try directCommand(alloc, &.{path});
    }
    return try commandPromptWithHost(alloc, Host, &.{});
}

fn commandPromptWithHost(alloc: Allocator, comptime Host: type, switches: []const []const u8) !Command {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    const found = (try Host.systemShell(alloc, "cmd.exe")) orelse
        try Host.systemPath(alloc, "cmd.exe");
    defer if (found) |path| alloc.free(path);
    // Only an unavailable system directory leaves a bare-name fallback.
    try argv.append(alloc, found orelse "cmd.exe");
    try argv.appendSlice(alloc, switches);
    return try directCommand(alloc, argv.items);
}

fn listProfilesWithLookupAndProbeAndWslList(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
    list_wsl: anytype,
) ![]Profile {
    return try listProfilesWithLookupAndProbeAndWslListAndOrder(
        alloc,
        lookup,
        probe,
        list_wsl,
        null,
        null,
    );
}

fn listProfilesWithLookupAndProbeAndWslListAndOrder(
    alloc: Allocator,
    lookup: anytype,
    probe: anytype,
    list_wsl: anytype,
    order_hint: ?[]const u8,
    complete: ?*bool,
) ![]Profile {
    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |*profile| profile.deinit(alloc);
        profiles.deinit(alloc);
    }

    if (try lookup(alloc, "wsl.exe")) |path| {
        defer alloc.free(path);

        const wsl_ready = try probe(alloc, path);
        if (!wsl_ready) {
            if (complete) |value| value.* = false;
        } else {
            try appendProfile(
                alloc,
                &profiles,
                .wsl_default,
                "wsl-default",
                "WSL (Default)",
                &.{path},
            );

            const distros = try list_wsl(alloc, path);
            defer deinitOwnedStringList(alloc, distros);

            for (distros) |distro| {
                const key = try std.fmt.allocPrint(alloc, "wsl:{s}", .{distro});
                defer alloc.free(key);
                const label = try std.fmt.allocPrint(alloc, "WSL: {s}", .{distro});
                defer alloc.free(label);
                try appendProfile(
                    alloc,
                    &profiles,
                    .wsl_distro,
                    key,
                    label,
                    &.{ path, "-d", distro },
                );
            }
        }
    }

    try appendProfileIfFound(alloc, &profiles, lookup, .pwsh, "pwsh.exe", "PowerShell");
    try appendProfileIfFound(alloc, &profiles, lookup, .powershell, "powershell.exe", "Windows PowerShell");

    if (try lookupGitBash(alloc, lookup)) |path| {
        defer alloc.free(path);
        try appendProfile(
            alloc,
            &profiles,
            .git_bash,
            "git-bash",
            "Git Bash",
            &.{ path, "--login", "-i" },
        );
    }

    try appendProfileIfFound(alloc, &profiles, lookup, .cmd, "cmd.exe", "Command Prompt");

    if (order_hint) |hint| applyProfileOrderHint(profiles.items, hint);

    return try profiles.toOwnedSlice(alloc);
}

fn appendProfileIfFound(
    alloc: Allocator,
    profiles: *std.ArrayList(Profile),
    lookup: anytype,
    kind: ProfileKind,
    exe: []const u8,
    label: []const u8,
) !void {
    if (try lookup(alloc, exe)) |path| {
        defer alloc.free(path);
        try appendProfile(alloc, profiles, kind, exe, label, &.{path});
    }
}

fn appendProfile(
    alloc: Allocator,
    profiles: *std.ArrayList(Profile),
    kind: ProfileKind,
    key: []const u8,
    label: []const u8,
    argv: []const []const u8,
) !void {
    try profiles.append(alloc, .{
        .kind = kind,
        .key = try alloc.dupe(u8, key),
        .label = try alloc.dupe(u8, label),
        .command = try directCommand(alloc, argv),
    });
}

fn appendSshProfiles(
    alloc: Allocator,
    shell_profiles: []Profile,
    hosts: []const windows_ssh_hosts.Host,
    ssh_path: []const u8,
) ![]Profile {
    var profiles: std.ArrayList(Profile) = .empty;
    profiles.ensureTotalCapacity(alloc, shell_profiles.len + hosts.len) catch |err| {
        deinitProfiles(alloc, shell_profiles);
        return err;
    };
    profiles.appendSliceAssumeCapacity(shell_profiles);
    alloc.free(shell_profiles);
    errdefer deinitProfileList(alloc, &profiles);

    for (hosts) |host| {
        const key = try std.fmt.allocPrint(alloc, "ssh:{s}", .{host.alias});
        defer alloc.free(key);
        const label = try std.fmt.allocPrint(alloc, "SSH: {s}", .{host.alias});
        defer alloc.free(label);
        const palette_title = try std.fmt.allocPrint(alloc, "Connect to {s}", .{host.alias});
        defer alloc.free(palette_title);
        try appendProfile(
            alloc,
            &profiles,
            .ssh,
            key,
            label,
            &.{ ssh_path, host.alias },
        );
        profiles.items[profiles.items.len - 1].palette_title = try alloc.dupe(u8, palette_title);
    }

    return try profiles.toOwnedSlice(alloc);
}

fn resolveSshExecutable(alloc: Allocator, lookup: anytype, access: anytype) !?[]u8 {
    const path_result = lookup(alloc, "ssh.exe") catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
    if (path_result) |path| return path;

    const fallback = "C:\\Windows\\System32\\OpenSSH\\ssh.exe";
    access(fallback) catch return null;
    return try alloc.dupe(u8, fallback);
}

fn accessAbsolute(path: []const u8) !void {
    try std.fs.accessAbsolute(path, .{});
}

fn warnSshDiscoveryOnce(err: anyerror) void {
    ssh_missing_mutex.lock();
    defer ssh_missing_mutex.unlock();
    if (ssh_missing_logged) return;
    ssh_missing_logged = true;
    log.warn("SSH hosts skipped: discovery failed err={}", .{err});
}

fn warnMissingSshOnce() void {
    ssh_missing_mutex.lock();
    defer ssh_missing_mutex.unlock();
    if (ssh_missing_logged) return;
    ssh_missing_logged = true;
    log.warn("SSH hosts skipped: ssh.exe was not found on PATH or in Windows OpenSSH", .{});
}

fn deinitProfileList(alloc: Allocator, profiles: *std.ArrayList(Profile)) void {
    for (profiles.items) |*profile| profile.deinit(alloc);
    profiles.deinit(alloc);
}

fn detectProfileOrderHint(alloc: Allocator) ?[]u8 {
    const raw = std.process.getEnvVarOwned(alloc, "NOCTTY_WIN32_PROFILE_ORDER") catch
        return null;
    errdefer alloc.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        alloc.free(raw);
        return null;
    }

    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;

    const copy = alloc.dupe(u8, trimmed) catch return null;
    alloc.free(raw);
    return copy;
}

fn applyProfileOrderHint(profiles: []Profile, order_hint: []const u8) void {
    if (profiles.len <= 1 or order_hint.len == 0) return;

    var i: usize = 1;
    while (i < profiles.len) : (i += 1) {
        var j = i;
        while (j > 0 and shouldProfileSortBefore(order_hint, profiles[j], profiles[j - 1])) : (j -= 1) {
            std.mem.swap(Profile, &profiles[j], &profiles[j - 1]);
        }
    }
}

fn shouldProfileSortBefore(order_hint: []const u8, lhs: Profile, rhs: Profile) bool {
    const lhs_rank = profileOrderRank(order_hint, lhs);
    const rhs_rank = profileOrderRank(order_hint, rhs);
    if (lhs_rank != rhs_rank) return lhs_rank < rhs_rank;
    return false;
}

fn profileOrderRank(order_hint: []const u8, profile: Profile) usize {
    var index: usize = 0;
    var it = std.mem.splitAny(u8, order_hint, ",;");
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        if (profileOrderTokenMatches(token, profile)) return index;
        index += 1;
    }
    return std.math.maxInt(usize);
}

fn profileOrderTokenMatches(token: []const u8, profile: Profile) bool {
    if (std.ascii.eqlIgnoreCase(token, profile.key)) return true;
    if (std.ascii.eqlIgnoreCase(token, profile.label)) return true;
    if (profile.kind == .wsl_distro) {
        if (profile.key.len > 4 and std.ascii.eqlIgnoreCase(profile.key[0..4], "wsl:")) {
            if (std.ascii.eqlIgnoreCase(token, profile.key[4..])) return true;
        }
        if (profile.label.len > 5 and std.ascii.eqlIgnoreCase(profile.label[0..5], "WSL: ")) {
            if (std.ascii.eqlIgnoreCase(token, profile.label[5..])) return true;
        }
    }

    return switch (profile.kind) {
        .wsl_default => std.ascii.eqlIgnoreCase(token, "wsl") or
            std.ascii.eqlIgnoreCase(token, "wsl-default") or
            std.ascii.eqlIgnoreCase(token, "default-wsl"),
        .wsl_distro => std.ascii.eqlIgnoreCase(token, "wsl-distro") or
            std.ascii.eqlIgnoreCase(token, "distro") or
            std.ascii.eqlIgnoreCase(token, "wsl"),
        .pwsh => std.ascii.eqlIgnoreCase(token, "pwsh") or
            std.ascii.eqlIgnoreCase(token, "powershell-7") or
            std.ascii.eqlIgnoreCase(token, "powershell-core"),
        .powershell => std.ascii.eqlIgnoreCase(token, "powershell") or
            std.ascii.eqlIgnoreCase(token, "windows-powershell") or
            std.ascii.eqlIgnoreCase(token, "ps"),
        .git_bash => std.ascii.eqlIgnoreCase(token, "git-bash") or
            std.ascii.eqlIgnoreCase(token, "gitbash") or
            std.ascii.eqlIgnoreCase(token, "git"),
        .cmd => std.ascii.eqlIgnoreCase(token, "cmd") or
            std.ascii.eqlIgnoreCase(token, "cmd.exe") or
            std.ascii.eqlIgnoreCase(token, "command-prompt"),
        .ssh => false,
    };
}

fn probeWslExecutableCached(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    wsl_probe_mutex.lock();
    defer wsl_probe_mutex.unlock();

    if (wsl_probe_cache) |cached| return cached;

    const result = try probeWslExecutable(alloc, exe_path);
    wsl_probe_cache = result;
    return result;
}

fn probeWslExecutableForProfiles(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    wsl_probe_mutex.lock();
    defer wsl_probe_mutex.unlock();

    if ((wsl_profile_probe_cache orelse false) or (wsl_probe_cache orelse false)) return true;

    const result = try probeWslExecutable(alloc, exe_path);
    // Profile discovery keeps transient negative results retryable while a
    // successful probe remains stable for later palette/jump-list refreshes.
    if (result) wsl_profile_probe_cache = true;
    return result;
}

fn probeWslExecutable(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;

    var child = std.process.Child.init(&.{ exe_path, "--status" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;

    win32.spawnChildHoldingInheritLock(&child) catch |err| {
        log.warn("failed to probe wsl responsiveness exe={s} err={}", .{ exe_path, err });
        return false;
    };
    errdefer {
        _ = child.kill() catch {};
    }

    windows.WaitForSingleObjectEx(child.id, wsl_probe_timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            log.warn("skipping unresponsive wsl default shell exe={s} timeout_ms={}", .{
                exe_path,
                wsl_probe_timeout_ms,
            });
            _ = child.kill() catch {};
            return false;
        },

        else => {
            log.warn("wsl probe wait failed exe={s} err={}", .{ exe_path, err });
            _ = child.kill() catch {};
            return false;
        },
    };

    _ = child.wait() catch |err| {
        log.warn("wsl probe wait cleanup failed exe={s} err={}", .{ exe_path, err });
        return false;
    };
    return true;
}

fn prepareWslDirect(
    alloc: Allocator,
    argv: []const [:0]const u8,
    target_cwd: ?[]const u8,
    lookup: anytype,
) !Command {
    const resolved_exe = try resolveExecutableForArgv0(alloc, argv, lookup);
    defer if (resolved_exe) |path| alloc.free(path);
    const target_home = if (target_cwd) |cwd| std.mem.eql(u8, cwd, "~") else false;

    if (argv.len == 0) {
        if (resolved_exe) |path| return try directCommand(alloc, &.{path});
        return try directCommand(alloc, &.{"wsl.exe"});
    }

    var count: usize = 1;
    if (target_cwd != null) count += 2;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (isCdFlag(argv[i])) {
            if (std.mem.eql(u8, argv[i], "--cd") and i + 1 < argv.len) i += 1;
            continue;
        }

        if (std.mem.eql(u8, argv[i], "~")) {
            // Treat a bare "~" as our legacy home sentinel for WSL launches.
            // Modern WSL expects "--cd ~" instead of a positional "~".
            continue;
        }

        count += 1;
    }

    const args = try alloc.alloc([:0]const u8, count);
    var j: usize = 0;
    if (resolved_exe) |path| {
        args[j] = try alloc.dupeZ(u8, path);
    } else {
        args[j] = try alloc.dupeZ(u8, argv[0]);
    }
    j += 1;

    if (target_cwd) |cwd| {
        _ = target_home;
        args[j] = try alloc.dupeZ(u8, "--cd");
        j += 1;
        args[j] = try alloc.dupeZ(u8, cwd);
        j += 1;
    }

    i = 1;
    while (i < argv.len) : (i += 1) {
        if (isCdFlag(argv[i])) {
            if (std.mem.eql(u8, argv[i], "--cd") and i + 1 < argv.len) i += 1;
            continue;
        }

        if (std.mem.eql(u8, argv[i], "~")) {
            continue;
        }

        args[j] = try alloc.dupeZ(u8, argv[i]);
        j += 1;
    }

    std.debug.assert(j == count);
    return .{ .direct = args };
}

fn resolveExecutableForArgv0(
    alloc: Allocator,
    argv: []const [:0]const u8,
    lookup: anytype,
) !?[]u8 {
    if (argv.len == 0) return try lookup(alloc, "wsl.exe");
    if (!isExecutableName(argv[0], "wsl") and !isExecutableName(argv[0], "wsl.exe")) return null;
    if (std.fs.path.isAbsolute(argv[0])) return try alloc.dupe(u8, argv[0]);
    return try lookup(alloc, "wsl.exe");
}

fn directCommand(alloc: Allocator, argv: []const []const u8) !Command {
    const args = try alloc.alloc([:0]const u8, argv.len);
    for (argv, 0..) |arg, i| args[i] = try alloc.dupeZ(u8, arg);
    return .{ .direct = args };
}

/// A program by bare name, for the profile list and the SSH lookup. The same
/// search `defaultCommand` uses for pwsh.exe, so the picker and a new tab agree
/// on what is installed: local absolute `PATH` entries only, quoted entries
/// understood, and guarded metadata handles (no reparse ancestor is followed).
fn lookupExecutable(alloc: Allocator, exe: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows or std.mem.indexOfAny(u8, exe, "\\/:") != null)
        return try internal_os.path.expand(alloc, exe);
    // The built-in shells live in the system directory, where `defaultCommand`
    // takes them from, so the picker lists exactly the executable a new tab runs.
    if (std.ascii.eqlIgnoreCase(exe, "cmd.exe")) {
        return try DefaultShellHost.systemShell(alloc, "cmd.exe");
    } else if (std.ascii.eqlIgnoreCase(exe, "powershell.exe")) {
        return try DefaultShellHost.systemShell(alloc, windows_powershell_relative);
    }
    const path = std.process.getEnvVarOwned(alloc, "PATH") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(path);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = searchPath(&buf, exe, path, null, true, isLaunchableFile) orelse return null;
    return try alloc.dupe(u8, found);
}

/// Git for Windows' `bash.exe`, from the most to the least trustworthy source:
/// the install that `git.exe` on PATH belongs to, the install its installer
/// registered, and last a `bash.exe` on PATH that is not a WSL launcher.
///
/// The last source can name a `bash.exe` that is not Git's, such as MSYS2's or
/// Cygwin's; it is still offered as the "Git Bash" profile, as it was before
/// this lookup existed, and gets the same automatic shell integration.
///
/// A plain PATH search is not enough. The installer puts only `Git\cmd` on
/// PATH, so on a machine with WSL the first `bash.exe` is the launcher in
/// System32, and the "Git Bash" profile would open a Linux distribution.
fn lookupGitBash(alloc: Allocator, lookup: anytype) !?[]u8 {
    return try lookupGitBashWithHost(alloc, lookup, GitBashHost);
}

/// Hives `GitBashHost.registryInstallRoot` reads: HKCU, then HKLM.
const git_registry_hives = 2;

const GitBashHost = struct {
    fn fileExists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// `InstallPath` of the Git for Windows installer in hive `index`: the
    /// per-user install (0) is tried before the all-users one (1).
    fn registryInstallRoot(alloc: Allocator, index: usize) !?[]u8 {
        // Tests must not depend on whether this machine has Git installed.
        if (builtin.is_test) return null;
        const hives = [git_registry_hives]windows.HKEY{ windows.HKEY_CURRENT_USER, windows.HKEY_LOCAL_MACHINE };
        return try registryString(
            alloc,
            hives[index],
            std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\GitForWindows"),
            std.unicode.utf8ToUtf16LeStringLiteral("InstallPath"),
        );
    }

    fn systemRoot(alloc: Allocator) ![]u8 {
        return std.process.getEnvVarOwned(alloc, "SystemRoot") catch |err| switch (err) {
            error.EnvironmentVariableNotFound, error.InvalidWtf8 => try alloc.dupe(u8, "C:\\Windows"),
            else => |e| return e,
        };
    }
};

/// A non-empty `REG_SZ` value as UTF-8, or null when the key or value is
/// missing, not a string, or empty.
fn registryString(
    alloc: Allocator,
    hive: windows.HKEY,
    subkey: [*:0]const u16,
    name: [*:0]const u16,
) !?[]u8 {
    var buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    var bytes: windows.DWORD = @sizeOf(@TypeOf(buf));
    const status = windows.advapi32.RegGetValueW(
        hive,
        subkey,
        name,
        windows.advapi32.RRF.RT_REG_SZ | windows.advapi32.RRF.ZEROONFAILURE,
        null,
        @ptrCast(&buf),
        &bytes,
    );
    if (status != @intFromEnum(windows.Win32Error.SUCCESS)) return null;
    // The size counts the terminator.
    if (bytes < @sizeOf(u16) or bytes % @sizeOf(u16) != 0) return null;
    const len = bytes / @sizeOf(u16) - 1;
    if (len == 0) return null;
    // WTF-8 holds any registry text, an unpaired surrogate included.
    return try std.unicode.wtf16LeToWtf8Alloc(alloc, buf[0..len]);
}

fn lookupGitBashWithHost(alloc: Allocator, lookup: anytype, comptime Host: type) !?[]u8 {
    if (try lookup(alloc, "git.exe")) |git_path| {
        defer alloc.free(git_path);
        if (try gitBashBesideGit(alloc, git_path, Host)) |path| return path;
    }

    // A hive can name an install that was removed while the other holds a
    // working one, so each root is checked before the next hive is read.
    for (0..git_registry_hives) |hive| {
        const root = (try Host.registryInstallRoot(alloc, hive)) orelse continue;
        defer alloc.free(root);
        const candidate = try std.fs.path.join(alloc, &.{ root, "bin", "bash.exe" });
        if (Host.fileExists(candidate)) return candidate;
        alloc.free(candidate);
    }

    const path = (try lookup(alloc, "bash.exe")) orelse return null;
    errdefer alloc.free(path);
    const system_root = try Host.systemRoot(alloc);
    defer alloc.free(system_root);
    if (isWslBashLauncher(path, system_root)) {
        alloc.free(path);
        return null;
    }
    return path;
}

/// `bin\bash.exe` of the Git install `git_path` belongs to. `git.exe` lives in
/// `cmd` (what the installer adds to PATH), in `bin`, or in a MinGW
/// environment's `bin` (`mingw64\bin`); any other folder is not recognised as
/// part of an install, so a shim or an unrelated `git.exe` leads nowhere.
fn gitBashBesideGit(alloc: Allocator, git_path: []const u8, comptime Host: type) !?[]u8 {
    const dir = std.fs.path.dirname(git_path) orelse return null;
    var root = std.fs.path.dirname(dir) orelse return null;
    const leaf = std.fs.path.basename(dir);
    if (std.ascii.eqlIgnoreCase(leaf, "bin")) {
        const env = std.fs.path.basename(root);
        if (std.ascii.startsWithIgnoreCase(env, "mingw") or
            std.ascii.eqlIgnoreCase(env, "ucrt64") or
            std.ascii.eqlIgnoreCase(env, "clang64") or
            std.ascii.eqlIgnoreCase(env, "clangarm64"))
        {
            root = std.fs.path.dirname(root) orelse return null;
        }
    } else if (!std.ascii.eqlIgnoreCase(leaf, "cmd")) {
        return null;
    }

    const candidate = try std.fs.path.join(alloc, &.{ root, "bin", "bash.exe" });
    if (Host.fileExists(candidate)) return candidate;
    alloc.free(candidate);
    return null;
}

/// True for the `bash.exe` that starts WSL: the launcher in System32 (or its
/// SysWOW64 and Sysnative views) and the WindowsApps alias. Neither is Git
/// Bash, and shell integration cannot reach into the Linux side (the
/// environment it relies on does not cross into WSL), so a bash started there
/// would stay in POSIX mode.
fn isWslBashLauncher(path: []const u8, system_root: []const u8) bool {
    if (pathIsUnder(path, system_root)) return true;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, "WindowsApps")) return true;
    }
    return false;
}

/// Whether `path` is `dir` or below it, ignoring case and the kind of
/// separator, as Windows does.
fn pathIsUnder(path: []const u8, dir: []const u8) bool {
    const root = std.mem.trimRight(u8, dir, "/\\");
    if (root.len == 0 or path.len <= root.len) return false;
    for (root, path[0..root.len]) |a, b| {
        if (isSeparator(a) and isSeparator(b)) continue;
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return isSeparator(path[root.len]);
}

/// `isWslBashLauncher` for a path from the command line, which shell
/// integration must leave alone.
pub fn isWslBashLauncherPath(alloc: Allocator, path: []const u8) !bool {
    const system_root = try GitBashHost.systemRoot(alloc);
    defer alloc.free(system_root);
    return isWslBashLauncher(path, system_root);
}

const WslOutputDrain = struct {
    stdout: std.fs.File,
    bytes: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *WslOutputDrain) void {
        self.bytes = self.stdout.readToEndAlloc(std.heap.page_allocator, 64 * 1024) catch |err| {
            self.err = err;
            return;
        };
    }

    fn deinit(self: *WslOutputDrain) void {
        if (self.bytes) |bytes| std.heap.page_allocator.free(bytes);
    }
};

fn listWslDistros(alloc: Allocator, exe_path: []const u8) ![][]u8 {
    var child = std.process.Child.init(&.{ exe_path, "-l", "-q" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;

    try win32.spawnChildHoldingInheritLock(&child);
    var child_running = true;
    errdefer {
        if (child_running) _ = child.kill() catch {};
    }

    const stdout = child.stdout orelse {
        _ = child.kill() catch {};
        return error.Unexpected;
    };

    // Drain concurrently so a large distro list cannot fill the anonymous
    // pipe and prevent wsl.exe from reaching the signaled state below.
    var drain: WslOutputDrain = .{ .stdout = stdout };
    const drain_thread = try std.Thread.spawn(.{}, WslOutputDrain.run, .{&drain});
    var drain_joined = false;
    defer {
        if (!drain_joined) drain_thread.join();
        drain.deinit();
    }

    windows.WaitForSingleObjectEx(child.id, wsl_list_timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            log.warn("WSL distro enumeration timed out exe={s} timeout_ms={}", .{
                exe_path,
                wsl_list_timeout_ms,
            });
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            child_running = false;
            drain_thread.join();
            drain_joined = true;
            return error.WslListTimeout;
        },
        else => {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            child_running = false;
            drain_thread.join();
            drain_joined = true;
            return err;
        },
    };

    drain_thread.join();
    drain_joined = true;
    const term = try child.wait();
    child_running = false;
    if (drain.err) |err| {
        return err;
    }
    if (!childTermSucceeded(term)) {
        log.warn("WSL distro enumeration exited unsuccessfully exe={s}", .{exe_path});
        return error.WslListFailed;
    }
    const raw_bytes = drain.bytes orelse return error.Unexpected;

    // wsl.exe outputs UTF-16LE. Convert to UTF-8 before parsing.
    // bytesAsSlice returns align(1) u16, but utf16LeToUtf8Alloc needs align(2).
    // Copy into a properly-aligned buffer first.
    const output = if (raw_bytes.len >= 2 and raw_bytes.len % 2 == 0) blk: {
        const unaligned = std.mem.bytesAsSlice(u16, raw_bytes);
        const aligned = try alloc.alloc(u16, unaligned.len);
        defer alloc.free(aligned);
        @memcpy(aligned, unaligned);
        // Skip BOM if present
        const data: []const u16 = if (aligned.len > 0 and aligned[0] == 0xFEFF) aligned[1..] else aligned;
        break :blk std.unicode.utf16LeToUtf8Alloc(alloc, data) catch {
            // Fallback: treat as raw UTF-8 if conversion fails
            break :blk try alloc.dupe(u8, raw_bytes);
        };
    } else try alloc.dupe(u8, raw_bytes);
    defer alloc.free(output);

    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        deinitOwnedStringList(alloc, result.items);
        result.deinit(alloc);
    }

    var it = std.mem.splitAny(u8, output, "\r\n");
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n\x00");
        if (line.len == 0) continue;
        // Filter out Docker Desktop and Rancher Desktop service distros
        // (matches Windows Terminal behavior)
        if (isWslServiceDistro(line)) continue;
        try result.append(alloc, try alloc.dupe(u8, line));
    }

    return try result.toOwnedSlice(alloc);
}

fn childTermSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Returns true for WSL distros that are internal service distributions
/// (not intended for interactive use). Matches Windows Terminal's filtering.
fn isWslServiceDistro(name: []const u8) bool {
    return asciiStartsWithIgnoreCase(name, "docker-desktop") or
        asciiStartsWithIgnoreCase(name, "rancher-desktop");
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn deinitOwnedStringList(alloc: Allocator, values: []const []u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn defaultWindowsHome(alloc: Allocator) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (try internal_os.windows.knownFolderPathUtf8(
        &internal_os.windows.FOLDERID_Profile,
        &buf,
    )) |path| {
        return try alloc.dupe(u8, path);
    }

    return null;
}

fn isExecutableName(path: []const u8, exe: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basename(path), exe);
}

fn isCdFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--cd") or std.mem.startsWith(u8, arg, "--cd=");
}

fn isWindowsUriPath(path: []const u8) bool {
    return path.len >= 4 and
        path[0] == '/' and
        std.ascii.isAlphabetic(path[1]) and
        path[2] == ':' and
        isSeparator(path[3]);
}

/// True for a UNC path that still carries the leading `/` of the URI it came
/// from, e.g. `/\\server\share\dir`. cmd's `$P` expands to a raw UNC path, so
/// `kitty-shell-cwd://localhost/$P` yields exactly this shape.
/// A `kitty-shell-cwd` path whose body is a Windows UNC path, i.e. the URI
/// separator followed by `\\server\share...`.
///
/// The remainder must be backslash-separated. Backslashes are legal in POSIX
/// filenames, so a WSL or POSIX shell could in principle report a directory
/// such as `/\\server/share`; requiring that no forward slash appears after
/// the URI separator keeps that case on the WSL path where it belongs, while
/// still matching everything cmd's `$P` can produce (cmd always emits
/// backslashes).
fn isUncUriPath(path: []const u8) bool {
    if (path.len < 4) return false;
    if (path[0] != '/' or path[1] != '\\' or path[2] != '\\') return false;
    if (isSeparator(path[3])) return false;

    // Must be backslash-separated throughout: a forward slash proves this is a
    // POSIX path that merely begins with backslashes, not the form cmd's `$P`
    // produces.
    if (std.mem.indexOfScalar(u8, path[3..], '/') != null) return false;

    // A UNC path needs both a host and a non-empty share (`\\server\share`).
    // `/\\server` alone is a legal POSIX filename, never a usable UNC path.
    const host = path[3..];
    const sep = std.mem.indexOfScalar(u8, host, '\\') orelse return false;
    return sep + 1 < host.len;
}

pub fn isDriveAbsolutePath(path: []const u8) bool {
    return path.len >= 3 and
        std.ascii.isAlphabetic(path[0]) and
        path[1] == ':' and
        isSeparator(path[2]);
}

/// Return true when a Windows path contains no bytes that can terminate or
/// split a CreateProcess environment/current-directory value or a window title.
pub fn isSafeWindowsPath(path: []const u8) bool {
    for (path) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

fn isObviouslyInvalidWindowsCurrentDirectory(path: []const u8) bool {
    return path.len == 0 or
        std.mem.eql(u8, path, "\\") or
        std.mem.eql(u8, path, "\\\\") or
        std.mem.eql(u8, path, "/") or
        std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\");
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '\\';
}

fn trimLeadingSeparators(path: []const u8) []const u8 {
    return std.mem.trimLeft(u8, path, "/\\");
}

fn normalizeWslPath(alloc: Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) return try alloc.dupe(u8, path);

    for ([_][]const u8{
        "\\\\wsl.localhost\\",
        "\\\\wsl$\\",
    }) |prefix| {
        if (!std.mem.startsWith(u8, path, prefix)) continue;

        const rest = path[prefix.len..];
        const distro_sep = std.mem.indexOfAny(u8, rest, "/\\") orelse return try alloc.dupe(u8, "/");
        const distro_rest = trimLeadingSeparators(rest[distro_sep..]);
        if (distro_rest.len == 0) return try alloc.dupe(u8, "/");

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try buf.append(alloc, '/');
        try appendNormalizedPath(&buf, alloc, distro_rest);
        return try buf.toOwnedSlice(alloc);
    }

    return try alloc.dupe(u8, path);
}

fn uriPathToWindows(alloc: Allocator, path: []const u8) ![]const u8 {
    return try drivePathToWindows(alloc, path[1], path[3..]);
}

/// `rest` is what follows the `X:` and its first separator.
fn drivePathToWindows(alloc: Allocator, drive: u8, rest: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try buf.append(alloc, drive);
    try buf.appendSlice(alloc, ":\\");
    try appendWindowsPath(&buf, alloc, trimLeadingSeparators(rest));
    return try buf.toOwnedSlice(alloc);
}

/// The Windows path in the plain form of ConEmu's OSC 9;9: `C:\Users\me`,
/// `C:/Users/me`, or either in one pair of double quotes, as oh-my-posh's
/// `osc99` and nushell send it. Returns null for anything else, which the
/// caller then reads as a URL (noctty's cmd integration sends
/// `kitty-shell-cwd://localhost/%P`).
///
/// Only a drive-absolute path qualifies, plus the WSL form: `wslpath -w`, the
/// recipe Windows Terminal documents for WSL, prints `\\wsl.localhost\Ubuntu\home\me`,
/// which maps to the distro's own `/home/me` exactly as it does in an OSC 7
/// URL (`osc7PathToLocal`). Any other UNC path, a device path and a relative
/// path are not taken. The result is not checked for control bytes or a
/// network shape; `isSafeWindowsPath` and `os.path.isNetworkOrDevicePath` do
/// that.
pub fn conemuPathToLocal(alloc: Allocator, value: []const u8) !?[]const u8 {
    var path = value;
    if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
        path = path[1 .. path.len - 1];
    }
    // A quote left over is not part of any Windows path.
    if (std.mem.indexOfScalar(u8, path, '"') != null) return null;
    if (isDriveAbsolutePath(path)) return try drivePathToWindows(alloc, path[0], path[3..]);
    if (std.mem.startsWith(u8, path, "\\\\wsl.localhost\\") or
        std.mem.startsWith(u8, path, "\\\\wsl$\\")) return try normalizeWslPath(alloc, path);
    return null;
}

fn appendNormalizedPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) !void {
    for (path) |c| try buf.append(alloc, if (c == '\\') '/' else c);
}

fn appendWindowsPath(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    path: []const u8,
) !void {
    for (path) |c| try buf.append(alloc, if (c == '/') '\\' else c);
}

/// A machine for `defaultCommandWithHost`: the `pwsh.exe` on `PATH` (null when
/// none is launchable) and which shells live in the system directory. Asking
/// for `wsl.exe` fails the test: the default never looks for it.
fn FakeDefaultShellHost(
    comptime pwsh: ?[]const u8,
    comptime system_shells: []const []const u8,
) type {
    return struct {
        fn findPwsh(a: Allocator) !?[]u8 {
            return if (pwsh) |path| try a.dupe(u8, path) else null;
        }

        fn systemShell(a: Allocator, relative: []const u8) !?[]u8 {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(relative, "wsl.exe"));
            inline for (system_shells) |shell| {
                if (std.mem.eql(u8, shell, relative))
                    return try std.fs.path.join(a, &.{ "C:\\WINDOWS\\system32", relative });
            }
            return null;
        }

        fn systemPath(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    };
}

fn expectDefaultShell(expected: []const u8, command: Command) !void {
    defer command.deinit(std.testing.allocator);
    try std.testing.expect(command == .direct);
    try std.testing.expectEqual(@as(usize, 1), command.direct.len);
    try std.testing.expectEqualStrings(expected, command.direct[0]);
}

const test_pwsh = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
const test_windows_powershell = "C:\\WINDOWS\\system32\\WindowsPowerShell\\v1.0\\powershell.exe";
const test_cmd = "C:\\WINDOWS\\system32\\cmd.exe";

test "default command prefers pwsh, then Windows PowerShell, then cmd" {
    const alloc = std.testing.allocator;
    const all_system = [_][]const u8{ windows_powershell_relative, "cmd.exe" };

    try expectDefaultShell(test_pwsh, try defaultCommandWithHost(alloc, FakeDefaultShellHost(test_pwsh, &all_system)));
    try expectDefaultShell(test_windows_powershell, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &all_system)));
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &.{"cmd.exe"})));
    // pwsh and cmd alone: pwsh still wins over the shells that are missing.
    try expectDefaultShell(test_pwsh, try defaultCommandWithHost(alloc, FakeDefaultShellHost(test_pwsh, &.{"cmd.exe"})));
}

test "default command falls back to bare cmd.exe when the system directory is unavailable" {
    try expectDefaultShell("cmd.exe", try defaultCommandWithHost(std.testing.allocator, FakeDefaultShellHost(null, &.{})));
}

test "cmd fallback uses absolute system path when guarded discovery rejects it" {
    const Host = struct {
        fn findPwsh(_: Allocator) !?[]u8 {
            return null;
        }
        fn systemShell(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
        fn systemPath(a: Allocator, relative: []const u8) !?[]u8 {
            try std.testing.expectEqualStrings("cmd.exe", relative);
            return try a.dupe(u8, test_cmd);
        }
    };
    const alloc = std.testing.allocator;
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, Host));
    const recovery = try commandPromptWithHost(alloc, Host, &.{"/D"});
    defer recovery.deinit(alloc);
    try std.testing.expectEqualStrings(test_cmd, recovery.direct[0]);
    try std.testing.expectEqualStrings("/D", recovery.direct[1]);
}

test "default command never picks WSL, which only the picker or an explicit command starts" {
    // wsl.exe is installed and answering as far as the profile picker is
    // concerned; the fake host fails the test if the default asks for it.
    const alloc = std.testing.allocator;
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &.{ "wsl.exe", "cmd.exe" })));
    try expectDefaultShell(test_pwsh, try defaultCommandWithHost(alloc, FakeDefaultShellHost(test_pwsh, &.{ "wsl.exe", "cmd.exe" })));
}

test "the picker starts on the profile the default command runs, not on WSL" {
    const profiles = [_]Profile{
        .{ .kind = .wsl_default, .key = "wsl-default", .label = "WSL (Default)", .command = .{ .direct = &.{"C:\\WINDOWS\\system32\\wsl.exe"} } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "WSL: Ubuntu", .command = .{ .direct = &.{ "C:\\WINDOWS\\system32\\wsl.exe", "-d", "Ubuntu" } } },
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{test_pwsh} } },
        .{ .kind = .powershell, .key = "powershell.exe", .label = "Windows PowerShell", .command = .{ .direct = &.{test_windows_powershell} } },
        .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{test_cmd} } },
    };
    try std.testing.expectEqual(@as(?usize, 2), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{test_pwsh} }));
    try std.testing.expectEqual(@as(?usize, 3), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{test_windows_powershell} }));
    try std.testing.expectEqual(@as(?usize, 4), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{"cmd.exe"} }));
    // A pwsh that is not in the list (the picker found none) leaves the choice to the caller.
    try std.testing.expectEqual(@as(?usize, null), profileIndexForDefaultCommand(profiles[0..2], .{ .direct = &.{test_pwsh} }));
    // A command that is none of the three shells is not this function's to map.
    try std.testing.expectEqual(@as(?usize, null), profileIndexForDefaultCommand(&profiles, .{ .direct = &.{"C:\\WINDOWS\\system32\\wsl.exe"} }));
    try std.testing.expectEqual(@as(?usize, null), profileIndexForDefaultCommand(&profiles, .{ .shell = "pwsh.exe" }));
}

test "the recovery command keeps /D through launch preparation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const recovery = try recoveryCommand(alloc);
    defer recovery.deinit(alloc);
    for ([_]bool{ false, true }) |utf8_console| {
        const prepared = try prepareCommand(alloc, recovery, null, false, utf8_console);
        defer if (prepared.direct.ptr != recovery.direct.ptr) prepared.deinit(alloc);
        try std.testing.expect(prepared == .direct);
        try std.testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.basename(prepared.direct[0]), "cmd.exe"));
        // /D stays the first switch, ahead of anything the UTF-8 preamble adds.
        try std.testing.expectEqualStrings("/D", prepared.direct[1]);
    }
}

test "recovery command is cmd /D even when PowerShell is installed" {
    const alloc = std.testing.allocator;
    const all_system = [_][]const u8{ windows_powershell_relative, "cmd.exe" };
    const with_cmd = try commandPromptWithHost(alloc, FakeDefaultShellHost(test_pwsh, &all_system), &.{"/D"});
    defer with_cmd.deinit(alloc);
    try std.testing.expect(with_cmd == .direct);
    try std.testing.expectEqual(@as(usize, 2), with_cmd.direct.len);
    try std.testing.expectEqualStrings(test_cmd, with_cmd.direct[0]);
    try std.testing.expectEqualStrings("/D", with_cmd.direct[1]);

    const bare = try commandPromptWithHost(alloc, FakeDefaultShellHost(test_pwsh, &.{windows_powershell_relative}), &.{"/D"});
    defer bare.deinit(alloc);
    try std.testing.expectEqualStrings("cmd.exe", bare.direct[0]);
    try std.testing.expectEqualStrings("/D", bare.direct[1]);

    // The default command itself carries no switch.
    try expectDefaultShell(test_cmd, try defaultCommandWithHost(alloc, FakeDefaultShellHost(null, &.{"cmd.exe"})));
}

/// The bytes `FSCTL_GET_REPARSE_POINT` returns for an App Execution Alias made
/// of `strings`: header, version 3, each string NUL-terminated.
fn appExecLinkRecord(alloc: Allocator, strings: []const []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try body.appendSlice(alloc, &.{ 3, 0, 0, 0 });
    for (strings) |text| {
        const wide = try std.unicode.utf8ToUtf16LeAlloc(alloc, text);
        defer alloc.free(wide);
        try body.appendSlice(alloc, std.mem.sliceAsBytes(wide));
        try body.appendSlice(alloc, &.{ 0, 0 });
    }
    var record: std.ArrayList(u8) = .empty;
    errdefer record.deinit(alloc);
    try record.appendSlice(alloc, &.{ 0x1b, 0x00, 0x00, 0x80 });
    try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(body.items.len))));
    try record.appendSlice(alloc, &.{ 0, 0 });
    try record.appendSlice(alloc, body.items);
    return try record.toOwnedSlice(alloc);
}

/// Creates an empty file `name` in `dir` and makes it an App Execution Alias to
/// `target`, as the Store does for an installed package. Skips the test where
/// the volume refuses a reparse point.
fn createTestAppExecLink(dir: std.fs.Dir, name: []const u8, target: []const u8) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Reopen it for the reparse write, without following what it will become.
    (try dir.createFile(name, .{})).close();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try dir.realpath(name, &path_buf);
    const path_w = try windows.sliceToPrefixedFileW(null, path);
    const handle = windows.kernel32.CreateFileW(
        path_w.span().ptr,
        windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_OPEN_REPARSE_POINT,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.SkipZigTest;
    defer windows.CloseHandle(handle);

    const alloc = std.testing.allocator;
    const record = try appExecLinkRecord(alloc, &.{ "Test.Pkg_abc", "Test.Pkg_abc!App", target, "0" });
    defer alloc.free(record);

    const FSCTL_SET_REPARSE_POINT: windows.DWORD = 0x900a4;
    windows.DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, record, null) catch return error.SkipZigTest;
}

test "appExecLinkTarget reads the third string and rejects a cut, foreign or odd record" {
    const alloc = std.testing.allocator;
    const target = "C:\\Program Files\\WindowsApps\\x\\pwsh.exe";
    const record = try appExecLinkRecord(alloc, &.{ "Microsoft.PowerShell_8wekyb3d8bbwe", "Microsoft.PowerShell_8wekyb3d8bbwe!App", target, "0" });
    defer alloc.free(record);

    var out: [128]u16 = undefined;
    const len = appExecLinkTarget(record, &out).?;
    var utf8: [128]u8 = undefined;
    const end = try std.unicode.utf16LeToUtf8(&utf8, out[0..len]);
    try std.testing.expectEqualStrings(target, utf8[0..end]);

    // Another tag, a wrong version, a length past the buffer and a record cut
    // short are all refused.
    var other = try alloc.dupe(u8, record);
    defer alloc.free(other);
    other[3] = 0xa0;
    try std.testing.expect(appExecLinkTarget(other, &out) == null);
    var version = try alloc.dupe(u8, record);
    defer alloc.free(version);
    version[8] = 2;
    try std.testing.expect(appExecLinkTarget(version, &out) == null);
    try std.testing.expect(appExecLinkTarget(record[0 .. record.len - 40], &out) == null);
    // Even the last terminator missing: only what the call returned counts.
    try std.testing.expect(appExecLinkTarget(record[0 .. record.len - 2], &out) == null);
    try std.testing.expect(appExecLinkTarget(record[0..8], &out) == null);
    var tiny: [4]u16 = undefined;
    try std.testing.expect(appExecLinkTarget(record, &tiny) == null);

    // A record that is not exactly four terminated strings is not one Windows
    // wrote, even when its length header fits: no application type, bytes after
    // it, an empty target.
    const three = try appExecLinkRecord(alloc, &.{ "pkg", "pkg!App", target });
    defer alloc.free(three);
    try std.testing.expect(appExecLinkTarget(three, &out) == null);
    const five = try appExecLinkRecord(alloc, &.{ "pkg", "pkg!App", target, "0", "extra" });
    defer alloc.free(five);
    try std.testing.expect(appExecLinkTarget(five, &out) == null);
    const empty = try appExecLinkRecord(alloc, &.{ "pkg", "pkg!App", "", "0" });
    defer alloc.free(empty);
    try std.testing.expect(appExecLinkTarget(empty, &out) == null);
    // The unfilled tail of the zeroed buffer after a short call reads as empty strings.
    var zeroed = [_]u8{0} ** 512;
    @memcpy(zeroed[0..40], record[0..40]);
    try std.testing.expect(appExecLinkTarget(&zeroed, &out) == null);
}

test "shell discovery refuses reparse ancestors before reading the target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("real/bin");
    try tmp.dir.writeFile(.{ .sub_path = "real/bin/pwsh.exe", .data = "MZ" });
    tmp.dir.symLink("real", "link", .{ .is_directory = true }) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fmt.allocPrint(alloc, "{s}\\link\\bin\\pwsh.exe", .{root});
    defer alloc.free(path);
    // Even a local ancestor link is refused: the kernel guard must reject
    // traversal before any metadata query can contact an unchecked target.
    try std.testing.expect(pathAttributes(path) == null);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.path.dirname(path).?;
    try std.testing.expect(searchPath(&buf, "pwsh.exe", dir, null, true, isLaunchableFile) == null);
}

test "shell discovery searches only ordinary local folders" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    // A real folder passes, a missing one does not (nothing to search).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    try std.testing.expect(isLocalSearchDirectory(root));
    const missing = try std.fmt.allocPrint(alloc, "{s}\\absent", .{root});
    defer alloc.free(missing);
    try std.testing.expect(!isLocalSearchDirectory(missing));
}

test "explicit commands and child PATH keep junctions with spaces" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("real");
    try tmp.dir.makePath("current tools");
    try tmp.dir.writeFile(.{ .sub_path = "real/pwsh.exe", .data = "MZ" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const link = try std.fmt.allocPrint(alloc, "{s}\\current tools", .{root});
    defer alloc.free(link);
    const target = try std.fmt.allocPrint(alloc, "\\??\\{s}\\real", .{root});
    defer alloc.free(target);
    const target_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, target);
    defer alloc.free(target_w);
    const link_w = try windows.sliceToPrefixedFileW(null, link);
    const handle = windows.kernel32.CreateFileW(link_w.span().ptr, windows.GENERIC_WRITE, 0, null, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT | windows.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.AccessDenied;
    {
        defer windows.CloseHandle(handle);
        const bytes: u16 = @intCast(target_w.len * 2);
        var record: std.ArrayList(u8) = .empty;
        defer record.deinit(alloc);
        try record.appendSlice(alloc, &.{ 3, 0, 0, 0xa0 }); // mount point
        try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, bytes + 12)));
        try record.appendSlice(alloc, &.{ 0, 0, 0, 0 }); // reserved, substitute offset
        try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, bytes)));
        try record.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u16, bytes + 2)));
        try record.appendSlice(alloc, &.{ 0, 0 }); // empty print name
        try record.appendSlice(alloc, std.mem.sliceAsBytes(target_w));
        try record.appendSlice(alloc, &.{ 0, 0, 0, 0 }); // terminators
        try windows.DeviceIoControl(handle, 0x900a4, record.items, null);
    }
    const exe = try std.fmt.allocPrintSentinel(alloc, "{s}\\pwsh.exe", .{link}, 0);
    defer alloc.free(exe);
    const command = try executableCommand(alloc, .{ .shell = exe });
    defer command.deinit(alloc);
    try std.testing.expect(command == .direct);
    try std.testing.expectEqualStrings(exe, command.direct[0]);
    var env = std.process.EnvMap.init(alloc);
    defer env.deinit();
    try env.put("PATH", link);
    const child = (try lookupChildExecutable(alloc, "pwsh.exe", &env)).?;
    defer alloc.free(child);
    try std.testing.expectEqualStrings(exe, child);
    // The same layout is deliberately excluded from automatic discovery.
    try std.testing.expect(!isLaunchableFile(exe));
}

test "local executable data reparse tags exclude redirects and cloud files" {
    for ([_]u32{ 0x80000017, 0x80000013 }) |tag| {
        try std.testing.expect(isLocalExecutableInfo(.{ .FileAttributes = windows.FILE_ATTRIBUTE_REPARSE_POINT, .ReparseTag = tag }));
        try std.testing.expect(!isLocalExecutableInfo(.{ .FileAttributes = windows.FILE_ATTRIBUTE_REPARSE_POINT | windows.FILE_ATTRIBUTE_DIRECTORY, .ReparseTag = tag }));
    }
    for ([_]u32{ 0xa000000c, 0xa0000003, 0x9000001a, 0x8000001b }) |tag|
        try std.testing.expect(!isLocalExecutableInfo(.{ .FileAttributes = windows.FILE_ATTRIBUTE_REPARSE_POINT, .ReparseTag = tag }));
}

test "shell discovery uses the production DOS mapping before metadata opens" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Reject = struct {
        fn map(_: [*:0]const u16, _: []u16) ?[]const u16 {
            return null;
        }
    };
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "pwsh.exe", .data = "not executed" });
    const path = try tmp.dir.realpathAlloc(alloc, "pwsh.exe");
    defer alloc.free(path);
    win32.TestHooks.direct_volume_mapping = Reject.map;
    defer win32.TestHooks.direct_volume_mapping = null;
    try std.testing.expectEqual(null, pathInfo(path));
    win32.TestHooks.direct_volume_mapping = win32.TestHooks.unavailableVolume;
    try std.testing.expectEqual(null, pathInfo(path));
    win32.TestHooks.direct_volume_mapping = null;
    try std.testing.expect(pathInfo(path) != null);
}

test "shell discovery accepts a real installed Store execution alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const local = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch return error.SkipZigTest;
    defer alloc.free(local);
    for ([_][]const u8{ "wt.exe", "winget.exe" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ local, "Microsoft", "WindowsApps", name });
        defer alloc.free(path);
        if (!windowsNonDirectoryPathExists(path)) continue;
        const info = pathInfo(path) orelse return error.TestUnexpectedResult;
        if (info.ReparseTag != IO_REPARSE_TAG_APPEXECLINK) continue;
        const handle = openPathNoRedirect(path) orelse return error.TestUnexpectedResult;
        defer windows.CloseHandle(handle);
        var data: [windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = @splat(0);
        const record = readReparseData(handle, &data) orelse return error.TestUnexpectedResult;
        var target_w: [1024]u16 = undefined;
        const len = appExecLinkTarget(record, &target_w) orelse return error.TestUnexpectedResult;
        var target_buf: [3 * target_w.len]u8 = undefined;
        const target_len = try std.unicode.utf16LeToUtf8(&target_buf, target_w[0..len]);
        const target = target_buf[0..target_len];
        // Even a real alias's record is untrusted: screen its target before
        // the independent existence check can touch it.
        const checked = openPathNoRedirect(target) orelse {
            try std.testing.expect(!isLaunchableFile(path));
            continue;
        };
        defer windows.CloseHandle(checked);
        // A stale alias is valid evidence of layout, but not an installed
        // target. Its rejection is intentional; try another installed alias.
        if (!windowsNonDirectoryPathExists(target)) {
            try std.testing.expect(!isLaunchableFile(path));
            continue;
        }
        try std.testing.expect(isLaunchableFile(path));
        var search_buf: [std.fs.max_path_bytes]u8 = undefined;
        const found = searchPath(&search_buf, name, std.fs.path.dirname(path).?, null, true, isLaunchableFile) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(path, found);
        return;
    }
    return error.SkipZigTest;
}

test "pwsh search skips what cannot start and keeps going down PATH" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1: a directory named pwsh.exe. 2: an alias whose package is gone.
    // 3: the real thing. 4: one that must not be reached.
    try tmp.dir.makePath("dir/pwsh.exe");
    try tmp.dir.makePath("gone");
    try createTestAppExecLink(tmp.dir, "gone/pwsh.exe", "C:\\Program Files\\WindowsApps\\Missing.Package_1.0.0.0_x64__abc\\pwsh.exe");
    try tmp.dir.makePath("real");
    try tmp.dir.writeFile(.{ .sub_path = "real/pwsh.exe", .data = "MZ" });
    try tmp.dir.makePath("later");
    try tmp.dir.writeFile(.{ .sub_path = "later/pwsh.exe", .data = "MZ" });

    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const path = try std.fmt.allocPrint(
        alloc,
        "\\\\server\\share;relative;\\??\\UNC\\server\\share;{s}\\dir;{s}\\gone;\"{s}\\real\";{s}\\later",
        .{ root, root, root, root },
    );
    defer alloc.free(path);
    const expected = try std.fmt.allocPrint(alloc, "{s}\\real\\pwsh.exe", .{root});
    defer alloc.free(expected);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(expected, searchPath(&buf, "pwsh.exe", path, null, true, isLaunchableFile).?);

    // With only the dead alias and the directory on PATH nothing is found, so
    // the default moves on to Windows PowerShell instead of a shell that fails.
    const dead = try std.fmt.allocPrint(alloc, "{s}\\dir;{s}\\gone", .{ root, root });
    defer alloc.free(dead);
    try std.testing.expect(searchPath(&buf, "pwsh.exe", dead, null, true, isLaunchableFile) == null);
}

test "an App Execution Alias counts only while its target exists" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("pkg");
    try tmp.dir.writeFile(.{ .sub_path = "pkg/pwsh.exe", .data = "MZ" });
    try tmp.dir.makePath("pkg/folder");
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);

    const present = try std.fmt.allocPrint(alloc, "{s}\\pkg\\pwsh.exe", .{root});
    defer alloc.free(present);
    const missing = try std.fmt.allocPrint(alloc, "{s}\\pkg\\nope.exe", .{root});
    defer alloc.free(missing);
    const folder = try std.fmt.allocPrint(alloc, "{s}\\pkg\\folder", .{root});
    defer alloc.free(folder);

    try createTestAppExecLink(tmp.dir, "to-present.exe", present);
    try createTestAppExecLink(tmp.dir, "to-missing.exe", missing);
    try createTestAppExecLink(tmp.dir, "to-folder.exe", folder);
    try createTestAppExecLink(tmp.dir, "to-network.exe", "\\\\server\\share\\pwsh.exe");
    try createTestAppExecLink(tmp.dir, "to-relative.exe", "pkg\\pwsh.exe");

    const check = struct {
        fn launchable(a: Allocator, dir: []const u8, name: []const u8) !bool {
            const full = try std.fmt.allocPrint(a, "{s}\\{s}", .{ dir, name });
            defer a.free(full);
            return isLaunchableFile(full);
        }
    }.launchable;
    try std.testing.expect(try check(alloc, root, "to-present.exe"));
    try std.testing.expect(!try check(alloc, root, "to-missing.exe"));
    try std.testing.expect(!try check(alloc, root, "to-folder.exe"));
    try std.testing.expect(!try check(alloc, root, "to-network.exe"));
    try std.testing.expect(!try check(alloc, root, "to-relative.exe"));
    // A plain file starts, a folder and a missing name do not.
    try std.testing.expect(try check(alloc, root, "pkg\\pwsh.exe"));
    try std.testing.expect(!try check(alloc, root, "pkg\\folder"));
    try std.testing.expect(!try check(alloc, root, "pkg\\absent.exe"));
}

test "the real machine yields a default command that exists" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const command = try defaultCommand(alloc);
    defer command.deinit(alloc);
    try std.testing.expect(command == .direct and command.direct.len == 1);
    const exe = std.fs.path.basename(command.direct[0]);
    try std.testing.expect(std.ascii.eqlIgnoreCase(exe, "pwsh.exe") or
        std.ascii.eqlIgnoreCase(exe, "powershell.exe") or std.ascii.eqlIgnoreCase(exe, "cmd.exe"));
    try std.testing.expect(isLaunchableFile(command.direct[0]));

    const recovery = try recoveryCommand(alloc);
    defer recovery.deinit(alloc);
    try std.testing.expect(std.ascii.eqlIgnoreCase(std.fs.path.basename(recovery.direct[0]), "cmd.exe"));
    try std.testing.expectEqualStrings("/D", recovery.direct[1]);
}

/// A machine for `lookupGitBashWithHost`: the files that exist and the install
/// the Git installer registered in HKCU and HKLM. SystemRoot is `C:\WINDOWS`.
fn FakeGitBashHost(
    comptime files: []const []const u8,
    comptime registry: [git_registry_hives]?[]const u8,
) type {
    return struct {
        fn fileExists(path: []const u8) bool {
            inline for (files) |file| {
                if (std.ascii.eqlIgnoreCase(file, path)) return true;
            }
            return false;
        }

        fn registryInstallRoot(a: Allocator, index: usize) !?[]u8 {
            return if (registry[index]) |root| try a.dupe(u8, root) else null;
        }

        fn systemRoot(a: Allocator) ![]u8 {
            return try a.dupe(u8, "C:\\WINDOWS");
        }
    };
}

/// A PATH holding `git` and `bash`, each possibly absent.
fn PathLookup(comptime git: ?[]const u8, comptime bash: ?[]const u8) type {
    return struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            const found = if (std.mem.eql(u8, exe, "git.exe")) git else if (std.mem.eql(u8, exe, "bash.exe")) bash else null;
            return if (found) |path| try a.dupe(u8, path) else null;
        }
    };
}

fn expectGitBash(expected: ?[]const u8, actual: ?[]u8) !void {
    defer if (actual) |path| std.testing.allocator.free(path);
    if (expected) |want| {
        try std.testing.expectEqualStrings(want, actual orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expect(actual == null);
    }
}

const test_wsl_launcher = "C:\\WINDOWS\\system32\\bash.exe";
const test_git_bash = "C:\\Program Files\\Git\\bin\\bash.exe";

test "lookupGitBash takes the install git.exe belongs to over a WSL launcher earlier on PATH" {
    const alloc = std.testing.allocator;
    // The installer puts only Git\cmd on PATH; System32 holds WSL's bash.exe.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Program Files\\Git\\cmd\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, null }),
    ));
    // git.exe in bin, and in mingw64\bin, name the same install.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Program Files\\Git\\bin\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, null }),
    ));
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Program Files\\Git\\mingw64\\bin\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, null }),
    ));
    // A MinGit without bash does not borrow a bash.exe from a folder above its install.
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\X\\Git\\cmd\\git.exe", null).lookup,
        FakeGitBashHost(&.{"C:\\X\\bin\\bash.exe"}, .{ null, null }),
    ));
}

test "lookupGitBash falls back to the registered install, then to a PATH bash that is not WSL" {
    const alloc = std.testing.allocator;
    // No git.exe on PATH (the installer's "Git Bash only" choice): the registry names the install.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, "C:\\Program Files\\Git" }),
    ));
    // A git.exe whose install has no bash.exe (a shim, a stale entry) is skipped.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup("C:\\Users\\me\\scoop\\shims\\git.exe", test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ null, "C:\\Program Files\\Git" }),
    ));
    // HKCU names a removed per-user install; the all-users one in HKLM still works.
    try expectGitBash(test_git_bash, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, test_wsl_launcher).lookup,
        FakeGitBashHost(&.{test_git_bash}, .{ "C:\\Users\\me\\AppData\\Local\\Programs\\Git", "C:\\Program Files\\Git" }),
    ));
    // The registry points at deleted installs: PATH is next.
    try expectGitBash("C:\\msys64\\usr\\bin\\bash.exe", try lookupGitBashWithHost(
        alloc,
        PathLookup(null, "C:\\msys64\\usr\\bin\\bash.exe").lookup,
        FakeGitBashHost(&.{}, .{ "C:\\Gone\\Git", "C:\\Gone\\Too" }),
    ));
}

test "lookupGitBash offers no Git Bash when only WSL's bash.exe exists" {
    const alloc = std.testing.allocator;
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, test_wsl_launcher).lookup,
        FakeGitBashHost(&.{}, .{ null, null }),
    ));
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, "C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe").lookup,
        FakeGitBashHost(&.{}, .{ null, null }),
    ));
    try expectGitBash(null, try lookupGitBashWithHost(
        alloc,
        PathLookup(null, null).lookup,
        FakeGitBashHost(&.{}, .{ null, null }),
    ));
}

test "registryString reads a string value and nothing else" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const testing = std.testing;
    const alloc = testing.allocator;
    const Reg = struct {
        extern "advapi32" fn RegCreateKeyExW(
            key: windows.HKEY,
            sub: [*:0]const u16,
            reserved: windows.DWORD,
            class: ?[*:0]const u16,
            options: windows.DWORD,
            sam: windows.DWORD,
            security: ?*anyopaque,
            result: *windows.HKEY,
            disposition: ?*windows.DWORD,
        ) callconv(.winapi) i32;
        extern "advapi32" fn RegSetValueExW(
            key: windows.HKEY,
            name: [*:0]const u16,
            reserved: windows.DWORD,
            kind: windows.DWORD,
            data: [*]const u8,
            size: windows.DWORD,
        ) callconv(.winapi) i32;
        extern "advapi32" fn RegDeleteKeyW(key: windows.HKEY, sub: [*:0]const u16) callconv(.winapi) i32;
    };
    const reg_sz: windows.DWORD = 1;
    const reg_dword: windows.DWORD = 4;
    const key_write: windows.DWORD = 0x20006;

    // A key of this test's own, under HKCU, deleted at the end.
    const key_name = try std.fmt.allocPrint(alloc, "Software\\noctty-test-pkg17-{d}", .{windows.GetCurrentProcessId()});
    defer alloc.free(key_name);
    const subkey = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_name);
    defer alloc.free(subkey);
    const value = std.unicode.utf8ToUtf16LeStringLiteral("InstallPath");

    try testing.expect((try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)) == null);

    var key: windows.HKEY = undefined;
    try testing.expectEqual(@as(i32, 0), Reg.RegCreateKeyExW(windows.HKEY_CURRENT_USER, subkey, 0, null, 0, key_write, null, &key, null));
    defer _ = Reg.RegDeleteKeyW(windows.HKEY_CURRENT_USER, subkey);
    defer _ = windows.advapi32.RegCloseKey(key);

    // Present but not a string.
    const number: windows.DWORD = 7;
    try testing.expectEqual(@as(i32, 0), Reg.RegSetValueExW(key, value, 0, reg_dword, @ptrCast(&number), @sizeOf(windows.DWORD)));
    try testing.expect((try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)) == null);

    // Empty.
    const empty = [_]u16{0};
    try testing.expectEqual(@as(i32, 0), Reg.RegSetValueExW(key, value, 0, reg_sz, @ptrCast(&empty), @sizeOf(@TypeOf(empty))));
    try testing.expect((try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)) == null);

    const root = std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Git");
    try testing.expectEqual(@as(i32, 0), Reg.RegSetValueExW(key, value, 0, reg_sz, @ptrCast(root), @intCast((root.len + 1) * @sizeOf(u16))));
    const got = (try registryString(alloc, windows.HKEY_CURRENT_USER, subkey, value)).?;
    defer alloc.free(got);
    try testing.expectEqualStrings("C:\\Program Files\\Git", got);
}

test "isWslBashLauncher matches the Windows folders whatever the case or separator" {
    const root = "C:\\WINDOWS";
    try std.testing.expect(isWslBashLauncher("C:\\WINDOWS\\system32\\bash.exe", root));
    try std.testing.expect(isWslBashLauncher("c:\\windows\\System32\\bash.exe", root));
    try std.testing.expect(isWslBashLauncher("C:/Windows/Sysnative/bash.exe", root));
    try std.testing.expect(isWslBashLauncher("C:\\Windows\\SysWOW64\\bash.exe", "C:\\Windows\\"));
    try std.testing.expect(isWslBashLauncher("C:\\Users\\me\\AppData\\Local\\Microsoft\\windowsapps\\bash.exe", root));

    try std.testing.expect(!isWslBashLauncher("C:\\Program Files\\Git\\usr\\bin\\bash.exe", root));
    // A sibling folder that only shares the prefix, and the root itself.
    try std.testing.expect(!isWslBashLauncher("C:\\Windows.old\\bash.exe", root));
    try std.testing.expect(!isWslBashLauncher("C:\\WINDOWS", root));
}

test "listProfilesWithLookupAndProbeAndWslList enumerates windows profiles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const profiles = try listProfilesWithLookupAndProbeAndWslList(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "powershell.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (std.mem.eql(u8, exe, "bash.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\bin\\bash.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, exe: []const u8) !bool {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            return true;
        }
    }.probe, struct {
        fn list(alloc_: Allocator, exe: []const u8) ![][]u8 {
            try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", exe);
            var values: std.ArrayList([]u8) = .empty;
            try values.append(alloc_, try alloc_.dupe(u8, "Ubuntu"));
            try values.append(alloc_, try alloc_.dupe(u8, "Debian"));
            return try values.toOwnedSlice(alloc_);
        }
    }.list);
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 7), profiles.len);
    try testing.expectEqual(ProfileKind.wsl_default, profiles[0].kind);
    try testing.expectEqualStrings("WSL (Default)", profiles[0].label);
    try testing.expectEqual(@as(usize, 1), profiles[0].command.direct.len);

    try testing.expectEqual(ProfileKind.wsl_distro, profiles[1].kind);
    try testing.expectEqualStrings("WSL: Ubuntu", profiles[1].label);
    try testing.expectEqual(@as(usize, 3), profiles[1].command.direct.len);
    try testing.expectEqualStrings("-d", profiles[1].command.direct[1]);
    try testing.expectEqualStrings("Ubuntu", profiles[1].command.direct[2]);

    try testing.expectEqual(ProfileKind.wsl_distro, profiles[2].kind);
    try testing.expectEqualStrings("WSL: Debian", profiles[2].label);
    try testing.expectEqual(ProfileKind.pwsh, profiles[3].kind);
    try testing.expectEqual(ProfileKind.powershell, profiles[4].kind);
    try testing.expectEqual(ProfileKind.git_bash, profiles[5].kind);
    try testing.expectEqual(ProfileKind.cmd, profiles[6].kind);
}

test "profile discovery reports a retryable WSL probe failure" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var complete = true;
    const profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return false;
        }
    }.probe, struct {
        fn list(_: Allocator, _: []const u8) ![][]u8 {
            return error.UnexpectedWslList;
        }
    }.list, null, &complete);
    defer deinitProfiles(alloc, profiles);

    try testing.expect(!complete);
    try testing.expectEqual(@as(usize, 1), profiles.len);
    try testing.expectEqual(ProfileKind.cmd, profiles[0].kind);

    complete = true;
    const recovered = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return true;
        }
    }.probe, struct {
        fn list(a: Allocator, _: []const u8) ![][]u8 {
            return try a.alloc([]u8, 0);
        }
    }.list, null, &complete);
    defer deinitProfiles(alloc, recovered);
    try testing.expect(complete);
    try testing.expectEqual(@as(usize, 2), recovered.len);
    try testing.expectEqual(ProfileKind.wsl_default, recovered[0].kind);
}

test "WSL enumeration requires a successful child exit" {
    try std.testing.expect(childTermSucceeded(.{ .Exited = 0 }));
    try std.testing.expect(!childTermSucceeded(.{ .Exited = 1 }));
    try std.testing.expect(!childTermSucceeded(.{ .Unknown = 1 }));
}

test "ssh profiles append after shells with alias-only argv" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const shell_profiles = try alloc.alloc(Profile, 1);
    shell_profiles[0] = .{
        .kind = .cmd,
        .key = try alloc.dupe(u8, "cmd.exe"),
        .label = try alloc.dupe(u8, "Command Prompt"),
        .command = try directCommand(alloc, &.{"cmd.exe"}),
    };
    const hosts = [_]windows_ssh_hosts.Host{.{ .alias = "production" }};
    const profiles = try appendSshProfiles(
        alloc,
        shell_profiles,
        &hosts,
        "C:\\Windows\\System32\\OpenSSH\\ssh.exe",
    );
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 2), profiles.len);
    try testing.expectEqual(ProfileKind.cmd, profiles[0].kind);
    try testing.expectEqual(ProfileKind.ssh, profiles[1].kind);
    try testing.expectEqualStrings("ssh:production", profiles[1].key);
    try testing.expectEqualStrings("SSH: production", profiles[1].label);
    try testing.expectEqualStrings("Connect to production", profiles[1].palette_title.?);
    try testing.expectEqual(@as(usize, 2), profiles[1].command.direct.len);
    try testing.expectEqualStrings(
        "C:\\Windows\\System32\\OpenSSH\\ssh.exe",
        profiles[1].command.direct[0],
    );
    try testing.expectEqualStrings("production", profiles[1].command.direct[1]);
}

test "ssh executable resolution prefers PATH then System32 fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const from_path = (try resolveSshExecutable(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            try testing.expectEqualStrings("ssh.exe", exe);
            return try a.dupe(u8, "C:\\Tools\\OpenSSH\\ssh.exe");
        }
    }.lookup, struct {
        fn access(_: []const u8) !void {
            return error.Unexpected;
        }
    }.access)).?;
    defer alloc.free(from_path);
    try testing.expectEqualStrings("C:\\Tools\\OpenSSH\\ssh.exe", from_path);

    const fallback = (try resolveSshExecutable(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup, struct {
        fn access(path: []const u8) !void {
            try testing.expectEqualStrings(
                "C:\\Windows\\System32\\OpenSSH\\ssh.exe",
                path,
            );
        }
    }.access)).?;
    defer alloc.free(fallback);
    try testing.expectEqualStrings("C:\\Windows\\System32\\OpenSSH\\ssh.exe", fallback);

    // A PATH lookup error is not fatal: it falls through to the same fallback.
    const after_lookup_error = (try resolveSshExecutable(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) anyerror!?[]u8 {
            return error.AccessDenied;
        }
    }.lookup, struct {
        fn access(_: []const u8) !void {}
    }.access)).?;
    defer alloc.free(after_lookup_error);
    try testing.expectEqualStrings("C:\\Windows\\System32\\OpenSSH\\ssh.exe", after_lookup_error);

    // Neither present: no SSH entries are produced at all.
    try testing.expectEqual(@as(?[]u8, null), try resolveSshExecutable(alloc, struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup, struct {
        fn access(_: []const u8) !void {
            return error.FileNotFound;
        }
    }.access));
}

test "profileOrderTokenMatches supports Windows profile aliases" {
    const testing = std.testing;

    try testing.expect(profileOrderTokenMatches("pwsh", .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("git", .{
        .kind = .git_bash,
        .key = "git-bash",
        .label = "Git Bash",
        .command = .{ .direct = &.{"bash.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("windows-powershell", .{
        .kind = .powershell,
        .key = "powershell.exe",
        .label = "Windows PowerShell",
        .command = .{ .direct = &.{"powershell.exe"} },
    }));
    try testing.expect(profileOrderTokenMatches("Ubuntu", .{
        .kind = .wsl_distro,
        .key = "Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "~" } },
    }));
    try testing.expect(!profileOrderTokenMatches("cmd", .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    }));
}

test "listProfilesWithLookupAndProbeAndWslListAndOrder reorders windows profiles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const profiles = try listProfilesWithLookupAndProbeAndWslListAndOrder(alloc, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            if (std.mem.eql(u8, exe, "pwsh.exe")) return try a.dupe(u8, "C:\\Program Files\\PowerShell\\7\\pwsh.exe");
            if (std.mem.eql(u8, exe, "powershell.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
            if (std.mem.eql(u8, exe, "bash.exe")) return try a.dupe(u8, "C:\\Program Files\\Git\\bin\\bash.exe");
            if (std.mem.eql(u8, exe, "cmd.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\cmd.exe");
            return null;
        }
    }.lookup, struct {
        fn probe(_: Allocator, _: []const u8) !bool {
            return true;
        }
    }.probe, struct {
        fn list(alloc_: Allocator, _: []const u8) ![][]u8 {
            var values: std.ArrayList([]u8) = .empty;
            try values.append(alloc_, try alloc_.dupe(u8, "Ubuntu"));
            try values.append(alloc_, try alloc_.dupe(u8, "Debian"));
            return try values.toOwnedSlice(alloc_);
        }
    }.list, "git,pwsh,Ubuntu,cmd", null);
    defer deinitProfiles(alloc, profiles);

    try testing.expectEqual(@as(usize, 7), profiles.len);
    try testing.expectEqual(ProfileKind.git_bash, profiles[0].kind);
    try testing.expectEqual(ProfileKind.pwsh, profiles[1].kind);
    try testing.expectEqualStrings("WSL: Ubuntu", profiles[2].label);
    try testing.expectEqual(ProfileKind.cmd, profiles[3].kind);
    try testing.expectEqual(ProfileKind.wsl_default, profiles[4].kind);
}

test "pathToWsl converts windows drive path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try pathToWsl(alloc, "C:\\Users\\aman\\src")).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/mnt/c/Users/aman/src", result);
}

test "pathToWsl converts wsl unc path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try pathToWsl(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman\\src")).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/home/aman/src", result);
}

test "osc7PathToLocal converts windows file uri path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try osc7PathToLocal(alloc, "/C:/Users/aman/src");
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\Users\\aman\\src", result);
}

test "conemuPathToLocal reads the plain path of OSC 9;9" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "C:\\Users\\aman\\src", "C:\\Users\\aman\\src" },
        // oh-my-posh quotes the path.
        .{ "\"C:\\Users\\aman\\src\"", "C:\\Users\\aman\\src" },
        // A path with spaces needs no quotes of its own.
        .{ "C:\\Program Files\\Git", "C:\\Program Files\\Git" },
        // A forward slash is the other separator, and the letter keeps its case.
        .{ "d:/work/noctty", "d:\\work\\noctty" },
        .{ "C:\\", "C:\\" },
        .{ "C:/", "C:\\" },
    };
    for (cases) |case| {
        const result = (try conemuPathToLocal(alloc, case[0])).?;
        defer alloc.free(result);
        try testing.expectEqualStrings(case[1], result);
    }
}

test "conemuPathToLocal maps the UNC form wslpath prints to the distro's own path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\\\\wsl.localhost\\Ubuntu\\home\\aman\\src", "/home/aman/src" },
        .{ "\\\\wsl$\\Ubuntu\\home\\aman", "/home/aman" },
        .{ "\"\\\\wsl.localhost\\Ubuntu-24.04\\mnt\\data\"", "/mnt/data" },
        .{ "\\\\wsl.localhost\\Ubuntu", "/" },
    };
    for (cases) |case| {
        const result = (try conemuPathToLocal(alloc, case[0])).?;
        defer alloc.free(result);
        try testing.expectEqualStrings(case[1], result);
    }
}

test "conemuPathToLocal leaves everything but a drive-absolute path to the caller" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_][]const u8{
        // The URL forms, including the one noctty's cmd integration sends.
        "kitty-shell-cwd://localhost/C:\\Users\\aman",
        "file://localhost/C:/Users/aman",
        // Not drive-absolute, and not WSL's own UNC form.
        "",
        "\"\"",
        "C:",
        "C:Users",
        "Users\\aman",
        "\\Users\\aman",
        "/mnt/c/Users",
        "\\\\server\\share",
        "\\\\server\\wsl.localhost\\share",
        "\\\\?\\UNC\\server\\share",
        "\\\\.\\pipe\\x",
        "\\\\wsl",
        // One pair of quotes only, and both of them.
        "\"\"C:\\Users\"\"",
        "\"C:\\Users",
        "C:\\Users\"",
    }) |value| {
        try testing.expect(try conemuPathToLocal(alloc, value) == null);
    }
}

test "osc7PathToLocal strips the uri slash from a unc path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const share = try osc7PathToLocal(alloc, "/\\\\server\\share\\dir");
    defer alloc.free(share);
    try testing.expectEqualStrings("\\\\server\\share\\dir", share);

    const root = try osc7PathToLocal(alloc, "/\\\\server\\share");
    defer alloc.free(root);
    try testing.expectEqualStrings("\\\\server\\share", root);

    // A UNC path pointing back into WSL is still normalized to a WSL path.
    const wsl = try osc7PathToLocal(alloc, "/\\\\wsl.localhost\\Ubuntu\\home\\aman");
    defer alloc.free(wsl);
    try testing.expectEqualStrings("/home/aman", wsl);

    // Real POSIX paths must not be mistaken for UNC.
    const posix = try osc7PathToLocal(alloc, "/home/aman/src");
    defer alloc.free(posix);
    try testing.expectEqualStrings("/home/aman/src", posix);

    // Backslashes are legal in POSIX filenames, so a POSIX cwd can start with
    // two of them. A forward slash later in the path proves it is not the
    // backslash-separated UNC form cmd's `$P` produces, so it stays POSIX.
    const posix_backslashes = try osc7PathToLocal(alloc, "/\\\\server/share");
    defer alloc.free(posix_backslashes);
    try testing.expectEqualStrings("/\\\\server/share", posix_backslashes);

    // A host with no share is not a usable UNC path, so it is a POSIX name.
    for ([_][]const u8{ "/\\\\server", "/\\\\server\\" }) |path| {
        const kept = try osc7PathToLocal(alloc, path);
        defer alloc.free(kept);
        try testing.expectEqualStrings(path, kept);
    }
}

test "isUncUriPath only matches uri-carried unc paths" {
    const testing = std.testing;

    try testing.expect(isUncUriPath("/\\\\server\\share"));
    try testing.expect(isUncUriPath("/\\\\s\\a"));
    try testing.expect(!isUncUriPath("/home/aman"));
    try testing.expect(!isUncUriPath("//server/share"));
    try testing.expect(!isUncUriPath("\\\\server\\share"));
    try testing.expect(!isUncUriPath("/\\\\"));
    try testing.expect(!isUncUriPath("/\\\\\\share"));
    try testing.expect(!isUncUriPath("/C:/Users"));
}

test "pathToWsl rejects a uri-carried unc path" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expect(try pathToWsl(alloc, "/\\\\server\\share\\dir") == null);

    const wsl = (try pathToWsl(alloc, "/\\\\wsl.localhost\\Ubuntu\\home\\aman")).?;
    defer alloc.free(wsl);
    try testing.expectEqualStrings("/home/aman", wsl);
}

test "shellPwd drops invalid non-wsl cwd roots" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try shellPwd(alloc, "\\\\", false);
    try testing.expectEqual(@as(?[]const u8, null), result);
}

test "shellPwd preserves normalized wsl pwd for wsl launches" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try shellPwd(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman", true)).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("/home/aman", result);
}

test "security regression windows shell pwd rejects control-bearing paths" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_][]const u8{
        "C:\\evil\x00INJ=1\x0Ab",
        "C:\\evil\x01child",
        "C:\\evil\tchild",
        "C:\\evil\rchild",
        "C:\\evil\nchild",
        "C:\\evil\x1Fchild",
        "C:\\evil\x7Fchild",
    }) |path| {
        try testing.expectEqual(@as(?[]const u8, null), try shellPwd(alloc, path, false));
    }

    const ordinary = (try shellPwd(alloc, "C:\\Users\\aman\\src", false)).?;
    defer alloc.free(ordinary);
    try testing.expectEqualStrings("C:\\Users\\aman\\src", ordinary);
}

test "security regression windows current directory rejects control-bearing paths" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectEqual(
        @as(?[]const u8, null),
        try safeCurrentDirectory(alloc, "C:\\evil\x00INJ=1\x0Ab", false, false),
    );
}

test "safeCurrentDirectory keeps inherit semantics for non-wsl shells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectoryWithCurrent(alloc, null, false, false, try alloc.dupe(u8, "C:\\Users\\amant"))).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\Users\\amant", result);
}

test "safeCurrentDirectory keeps an inherited cwd ahead of a home request" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // SSH launches ask for home with an explicit path rather than this flag,
    // so the pre-existing "inherited cwd wins" precedence stays intact.
    const result = (try safeCurrentDirectoryWithCurrent(
        alloc,
        null,
        true,
        false,
        try alloc.dupe(u8, "C:\\work"),
    )).?;
    defer alloc.free(result);

    try testing.expectEqualStrings("C:\\work", result);
}

test "safeCurrentDirectory falls back to home for invalid cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectory(alloc, "\\\\", false, false)).?;
    defer alloc.free(result);

    try testing.expect(result.len > 2);
    try testing.expect(std.ascii.isAlphabetic(result[0]));
    try testing.expectEqual(@as(u8, ':'), result[1]);
}

test "safeCurrentDirectory falls back to home for inherited invalid cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = (try safeCurrentDirectoryWithCurrent(alloc, null, false, false, try alloc.dupe(u8, "\\\\"))).?;
    defer alloc.free(result);

    try testing.expect(result.len > 2);
    try testing.expect(std.ascii.isAlphabetic(result[0]));
    try testing.expectEqual(@as(u8, ':'), result[1]);
}

test "prepareCommand injects translated cwd for wsl direct command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{"wsl.exe"});
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "D:\\work\\noctty", false, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/mnt/d/work/noctty", prepared.direct[2]);
}

test "prepareCommand replaces default wsl home sentinel with explicit cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "~" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "D:\\work\\noctty", false, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/mnt/d/work/noctty", prepared.direct[2]);
}

test "prepareCommand rewrites wsl home sentinel to explicit --cd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "~" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, null, true, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 3), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("~", prepared.direct[2]);
}

test "prepareCommand replaces existing wsl --cd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const command = try directCommand(alloc, &.{ "wsl.exe", "--cd", "~", "--", "bash" });
    defer command.deinit(alloc);
    const prepared = try prepareCommandWithLookup(alloc, command, "/home/aman/src", false, false, struct {
        fn lookup(a: Allocator, exe: []const u8) !?[]u8 {
            if (std.mem.eql(u8, exe, "wsl.exe")) return try a.dupe(u8, "C:\\Windows\\System32\\wsl.exe");
            return null;
        }
    }.lookup);
    defer prepared.deinit(alloc);

    try testing.expect(prepared == .direct);
    try testing.expectEqual(@as(usize, 5), prepared.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\wsl.exe", prepared.direct[0]);
    try testing.expectEqualStrings("--cd", prepared.direct[1]);
    try testing.expectEqualStrings("/home/aman/src", prepared.direct[2]);
    try testing.expectEqualStrings("--", prepared.direct[3]);
    try testing.expectEqualStrings("bash", prepared.direct[4]);
}

test "spawnCwd uses home for wsl-style cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "\\\\wsl.localhost\\Ubuntu\\home\\aman", false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "spawnCwd preserves drive cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "C:\\Users\\aman\\src", false);
    defer if (result) |v| alloc.free(v);

    try testing.expect(result != null);
    try testing.expectEqualStrings("C:\\Users\\aman\\src", result.?);
}

test "spawnCwd uses home when cwd is unset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, null, false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "spawnCwd uses home for non-absolute cwd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const result = try spawnCwd(alloc, "\\\\", false);
    defer if (result) |v| alloc.free(v);

    if (builtin.os.tag == .windows) {
        try testing.expect(result != null);
    }
}

test "shellIntegrationDiagnostic reports automatic PowerShell support" {
    const testing = std.testing;

    const pwsh = shellIntegrationDiagnostic(.pwsh);
    try testing.expectEqual(ShellIntegrationSupport.automatic, pwsh.support);
    try testing.expectEqualStrings(
        "PowerShell profile with automatic shell integration",
        pwsh.summary,
    );
    try testing.expectEqual(@as(?[]const u8, null), pwsh.next_step);

    const powershell = shellIntegrationDiagnostic(.powershell);
    try testing.expectEqual(ShellIntegrationSupport.automatic, powershell.support);
    try testing.expectEqualStrings(
        "Windows PowerShell profile with automatic shell integration",
        powershell.summary,
    );
}

test "shellIntegrationDiagnostic differentiates WSL Git Bash and cmd support" {
    const testing = std.testing;

    const wsl_default = shellIntegrationDiagnostic(.wsl_default);
    try testing.expectEqual(ShellIntegrationSupport.shell_managed, wsl_default.support);
    try testing.expectEqualStrings(
        "WSL default profile; shell integration depends on the Linux shell",
        wsl_default.summary,
    );
    try testing.expectEqualStrings(
        wsl_shell_integration_next_step,
        wsl_default.next_step.?,
    );

    const wsl = shellIntegrationDiagnostic(.wsl_distro);
    try testing.expectEqual(ShellIntegrationSupport.shell_managed, wsl.support);
    try testing.expectEqualStrings(
        "WSL distro profile; shell integration depends on the Linux shell",
        wsl.summary,
    );
    try testing.expectEqualStrings(wsl_shell_integration_next_step, wsl.next_step.?);

    const git_bash = shellIntegrationDiagnostic(.git_bash);
    try testing.expectEqual(ShellIntegrationSupport.automatic, git_bash.support);
    try testing.expectEqualStrings(
        "Git Bash profile with automatic shell integration",
        git_bash.summary,
    );
    try testing.expectEqual(@as(?[]const u8, null), git_bash.next_step);

    const cmd = shellIntegrationDiagnostic(.cmd);
    try testing.expectEqual(ShellIntegrationSupport.automatic, cmd.support);
    try testing.expectEqualStrings(
        "Command Prompt profile with PROMPT-based shell integration; Clink adds command-start/finish and exit-code marks",
        cmd.summary,
    );
    try testing.expectEqual(@as(?[]const u8, null), cmd.next_step);
}

test "utf8-console decision covers modes and guarded code pages" {
    const testing = std.testing;

    const cases = [_]struct {
        mode: Utf8Console,
        western: bool,
        cjk: bool,
        utf8: bool,
    }{
        .{ .mode = .auto, .western = true, .cjk = false, .utf8 = true },
        .{ .mode = .always, .western = true, .cjk = true, .utf8 = true },
        .{ .mode = .never, .western = false, .cjk = false, .utf8 = false },
    };

    for (cases) |case| {
        try testing.expectEqual(case.western, shouldApplyUtf8Console(case.mode, 1252, 437));
        try testing.expectEqual(case.cjk, shouldApplyUtf8Console(case.mode, 932, 932));
        try testing.expectEqual(case.utf8, shouldApplyUtf8Console(case.mode, 65001, 65001));
    }

    for ([_]u32{ 932, 936, 949, 950, 1361 }) |code_page| {
        try testing.expect(!shouldApplyUtf8Console(.auto, code_page, 437));
        try testing.expect(!shouldApplyUtf8Console(.auto, 1252, code_page));
    }

    for ([_]Utf8Console{ .auto, .always }) |mode| {
        try testing.expect(shouldApplyUtf8Console(mode, 65001, 437));
        try testing.expect(shouldApplyUtf8Console(mode, 1252, 65001));
    }

    try testing.expect(!shouldApplyUtf8Console(.never, 65001, 437));
    try testing.expect(!shouldApplyUtf8Console(.never, 1252, 65001));
}

test "utf8-console cmd preamble leaves payload launches unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const lookup = struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup;

    const bare = try directCommand(alloc, &.{"cmd.exe"});
    defer bare.deinit(alloc);
    const prepared_bare = try prepareCommandWithLookup(alloc, bare, null, false, true, lookup);
    defer prepared_bare.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), prepared_bare.direct.len);
    try testing.expectEqualStrings("cmd.exe", prepared_bare.direct[0]);
    try testing.expectEqualStrings("/K", prepared_bare.direct[1]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_bare.direct[2]);

    const prepared_never = try prepareCommandWithLookup(
        alloc,
        bare,
        null,
        false,
        shouldApplyUtf8Console(.never, 1252, 437),
        lookup,
    );
    defer prepared_never.deinit(alloc);

    try testing.expect(prepared_never == .direct);
    try testing.expectEqual(@as(usize, 1), prepared_never.direct.len);
    try testing.expectEqualStrings("cmd.exe", prepared_never.direct[0]);

    const with_tail = try directCommand(alloc, &.{ "cmd.exe", "/c", "echo ok" });
    defer with_tail.deinit(alloc);
    const prepared_tail = try prepareCommandWithLookup(alloc, with_tail, null, false, true, lookup);
    defer prepared_tail.deinit(alloc);

    try testing.expectEqual(with_tail.direct.len, prepared_tail.direct.len);
    for (with_tail.direct, prepared_tail.direct) |expected, actual| {
        try testing.expectEqualStrings(expected, actual);
    }

    const shell_bare: Command = .{ .shell = "\"C:\\Windows\\System32\\cmd.exe\"" };
    const prepared_shell_bare = try prepareCommandWithLookup(alloc, shell_bare, null, false, true, lookup);
    defer prepared_shell_bare.deinit(alloc);

    try testing.expect(prepared_shell_bare == .direct);
    try testing.expectEqual(@as(usize, 3), prepared_shell_bare.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe", prepared_shell_bare.direct[0]);
    try testing.expectEqualStrings("/K", prepared_shell_bare.direct[1]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_shell_bare.direct[2]);

    const trampoline: Command = .{ .shell = "cmd.exe /c echo ok" };
    const prepared_trampoline = try prepareCommandWithLookup(alloc, trampoline, null, false, true, lookup);
    defer prepared_trampoline.deinit(alloc);

    try testing.expect(prepared_trampoline == .shell);
    try testing.expectEqualStrings("cmd.exe /c echo ok", prepared_trampoline.shell);
}

test "classifyCmdArg separates option-only switches from payload switches" {
    const testing = std.testing;

    for ([_][]const u8{
        "/d",      "/Q",      "/a",    "/u",      "/s",
        "/d/q",    "/D/Q/A",  "/e:on", "/E:OFF",  "/f:off",
        "/v:on",   "/t:0A",   "/t:f",  "/d/v:on", "/v:on/q",
        "/t:0a/q", "/s/d",
        // `cmd /?`: "for compatibility reasons, /X is the same as /E:ON,
        // /Y is the same as /E:OFF". Both are valueless.
           "/x",    "/Y",      "/x/q",
        "/d/y",    "/x/v:on",
    }) |arg| {
        try testing.expectEqual(CmdArg.option, classifyCmdArg(arg));
    }

    for ([_][]const u8{
        // Payload switches, separate and fused.
        "/c",       "/K",         "/r",     "/d/q/c", "/v:on/c",
        "/e:on/k",  "/cecho",     "/Kchcp", "/s/c",
        // Not a switch at all: cmd has no `-` prefix.
          "-c",
        "-d",       "script.bat",
        // Malformed or unknown switch runs.
        "/",      "/z",     "/e",
        "/e:maybe", "/t",         "/t:",    "/t:zz",  "/d/",
        "/v:onx",
    }) |arg| {
        try testing.expectEqual(CmdArg.unsupported, classifyCmdArg(arg));
    }
}

test "utf8-console cmd preamble preserves option-only switches" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const lookup = struct {
        fn lookup(_: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    }.lookup;

    // Separate switches keep their order and gain the preamble.
    const separate = try directCommand(alloc, &.{ "cmd.exe", "/d", "/q" });
    defer separate.deinit(alloc);
    const prepared_separate = try prepareCommandWithLookup(alloc, separate, null, false, true, lookup);
    defer prepared_separate.deinit(alloc);

    try testing.expectEqual(@as(usize, 5), prepared_separate.direct.len);
    try testing.expectEqualStrings("cmd.exe", prepared_separate.direct[0]);
    try testing.expectEqualStrings("/d", prepared_separate.direct[1]);
    try testing.expectEqualStrings("/q", prepared_separate.direct[2]);
    try testing.expectEqualStrings("/K", prepared_separate.direct[3]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_separate.direct[4]);

    // Combined switch runs are preserved verbatim.
    const combined = try directCommand(alloc, &.{ "cmd.exe", "/d/q", "/v:on" });
    defer combined.deinit(alloc);
    const prepared_combined = try prepareCommandWithLookup(alloc, combined, null, false, true, lookup);
    defer prepared_combined.deinit(alloc);

    try testing.expectEqual(@as(usize, 5), prepared_combined.direct.len);
    try testing.expectEqualStrings("/d/q", prepared_combined.direct[1]);
    try testing.expectEqualStrings("/v:on", prepared_combined.direct[2]);
    try testing.expectEqualStrings("/K", prepared_combined.direct[3]);
    try testing.expectEqualStrings("chcp 65001 >nul", prepared_combined.direct[4]);

    // A shell-form option-only launch normalizes into direct argv.
    const shell_options: Command = .{ .shell = "\"C:\\Windows\\System32\\cmd.exe\" /d /q" };
    const prepared_shell = try prepareCommandWithLookup(alloc, shell_options, null, false, true, lookup);
    defer prepared_shell.deinit(alloc);

    try testing.expect(prepared_shell == .direct);
    try testing.expectEqual(@as(usize, 5), prepared_shell.direct.len);
    try testing.expectEqualStrings("C:\\Windows\\System32\\cmd.exe", prepared_shell.direct[0]);
    try testing.expectEqualStrings("/K", prepared_shell.direct[3]);

    // A fused payload switch after options is still left untouched.
    for ([_][]const []const u8{
        &.{ "cmd.exe", "/d", "/q", "/c", "echo ok" },
        &.{ "cmd.exe", "/d/q/c", "echo ok" },
        &.{ "cmd.exe", "/v:on/c", "echo ok" },
        &.{ "cmd.exe", "/k", "echo ok" },
        &.{ "cmd.exe", "/cecho ok" },
    }) |argv| {
        const original = try directCommand(alloc, argv);
        defer original.deinit(alloc);
        const prepared = try prepareCommandWithLookup(alloc, original, null, false, true, lookup);
        defer prepared.deinit(alloc);

        try testing.expectEqual(original.direct.len, prepared.direct.len);
        for (original.direct, prepared.direct) |expected, actual| {
            try testing.expectEqualStrings(expected, actual);
        }
    }
}
