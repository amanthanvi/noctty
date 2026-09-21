const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// Export any constants or functions we need from the Windows API so
// we can just import one file.
pub const kernel32 = windows.kernel32;
pub const unexpectedError = windows.unexpectedError;
pub const OpenFile = windows.OpenFile;
pub const CloseHandle = windows.CloseHandle;
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const SetHandleInformation = windows.SetHandleInformation;
pub const DWORD = windows.DWORD;
pub const FILE_ATTRIBUTE_NORMAL = windows.FILE_ATTRIBUTE_NORMAL;
pub const FILE_FLAG_OVERLAPPED = windows.FILE_FLAG_OVERLAPPED;
pub const FILE_SHARE_READ = windows.FILE_SHARE_READ;
pub const GENERIC_READ = windows.GENERIC_READ;
pub const HANDLE = windows.HANDLE;
pub const HMODULE = windows.HMODULE;
pub const HANDLE_FLAG_INHERIT = windows.HANDLE_FLAG_INHERIT;
pub const INFINITE = windows.INFINITE;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const OPEN_EXISTING = windows.OPEN_EXISTING;
pub const PIPE_ACCESS_OUTBOUND = windows.PIPE_ACCESS_OUTBOUND;
pub const PIPE_TYPE_BYTE = windows.PIPE_TYPE_BYTE;
pub const PROCESS_INFORMATION = windows.PROCESS_INFORMATION;
pub const S_OK = windows.S_OK;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const SYNCHRONIZE = windows.SYNCHRONIZE;
pub const WAIT_FAILED = windows.WAIT_FAILED;
pub const FALSE = windows.FALSE;
pub const TRUE = windows.TRUE;
pub const FOLDERID_Profile = windows.GUID.parse("{5E6C858F-0E22-4760-9AFE-EA3317B67173}");
pub const FOLDERID_LocalAppData = windows.FOLDERID_LocalAppData;

pub extern "kernel32" fn GetACP() callconv(.winapi) windows.UINT;
pub extern "kernel32" fn GetOEMCP() callconv(.winapi) windows.UINT;
pub extern "kernel32" fn GetDriveTypeW(
    lpRootPathName: ?windows.LPCWSTR,
) callconv(.winapi) windows.UINT;

/// `GetDriveTypeW` return values, as documented at
/// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getdrivetypew
pub const DRIVE_UNKNOWN: windows.UINT = 0;
pub const DRIVE_NO_ROOT_DIR: windows.UINT = 1;
pub const DRIVE_REMOVABLE: windows.UINT = 2;
pub const DRIVE_FIXED: windows.UINT = 3;
pub const DRIVE_REMOTE: windows.UINT = 4;
pub const DRIVE_CDROM: windows.UINT = 5;
pub const DRIVE_RAMDISK: windows.UINT = 6;

/// Classify the drive named by an ASCII drive letter such as 'C'. This only
/// reads the local drive/mount table, so it does not touch the network even
/// for a disconnected mapped drive. Returns `DRIVE_UNKNOWN` for anything that
/// is not a drive letter.
pub fn driveTypeForLetter(letter: u8) windows.UINT {
    if (builtin.os.tag != .windows) return DRIVE_UNKNOWN;
    if (!std.ascii.isAlphabetic(letter)) return DRIVE_UNKNOWN;

    // GetDriveTypeW requires the trailing backslash.
    const root: [3:0]u16 = .{ letter, ':', '\\' };
    return GetDriveTypeW(&root);
}

/// `IMAGE_FILE_MACHINE_*` codes from `winnt.h`. `IsWow64Process2` reports the
/// process and native architecture using these values.
pub const IMAGE_FILE_MACHINE_UNKNOWN: u16 = 0x0000;
pub const IMAGE_FILE_MACHINE_I386: u16 = 0x014c;
pub const IMAGE_FILE_MACHINE_ARMNT: u16 = 0x01c4;
pub const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
pub const IMAGE_FILE_MACHINE_ARM64: u16 = 0xaa64;

/// The `IMAGE_FILE_MACHINE_*` code this binary was built for. Comparing it
/// against the native machine separates a native ARM64 build from an x64
/// build running under Windows on ARM emulation, and it is the only
/// architecture fact available when `IsWow64Process2` cannot be resolved.
pub const build_machine: u16 = switch (builtin.target.cpu.arch) {
    .x86_64 => IMAGE_FILE_MACHINE_AMD64,
    .aarch64 => IMAGE_FILE_MACHINE_ARM64,
    .x86 => IMAGE_FILE_MACHINE_I386,
    .arm, .thumb => IMAGE_FILE_MACHINE_ARMNT,
    else => IMAGE_FILE_MACHINE_UNKNOWN,
};

/// Name for an `IMAGE_FILE_MACHINE_*` code using the vocabulary Windows shows
/// users and the release artifacts already use ("x64", not "AMD64").
///
/// Returns null for a code this build does not know so callers report the raw
/// value instead of inventing a name. `IMAGE_FILE_MACHINE_UNKNOWN` maps to
/// "unknown", which is only ever right for a native machine; a process
/// machine must go through `resolveProcessArchitecture` first.
pub fn machineArchitectureName(machine: u16) ?[]const u8 {
    return switch (machine) {
        IMAGE_FILE_MACHINE_UNKNOWN => "unknown",
        IMAGE_FILE_MACHINE_I386 => "x86",
        IMAGE_FILE_MACHINE_ARMNT => "ARM32",
        IMAGE_FILE_MACHINE_AMD64 => "x64",
        IMAGE_FILE_MACHINE_ARM64 => "ARM64",
        else => null,
    };
}

/// `machineArchitectureName` with a rendered fallback for codes this build
/// does not name. A 24-byte `buf` always holds the fallback.
pub fn machineArchitectureLabel(buf: []u8, machine: u16) []const u8 {
    if (machineArchitectureName(machine)) |name| return name;
    return std.fmt.bufPrint(buf, "machine 0x{x:0>4}", .{machine}) catch "unrecognized machine";
}

/// The architecture this process runs as and the architecture of the machine
/// under it, after `IsWow64Process2`'s ambiguous process machine has been
/// resolved by `resolveProcessArchitecture`.
pub const ProcessArchitecture = struct {
    process_machine: u16,
    native_machine: u16,

    /// Whether this process runs on a machine of a different architecture.
    pub fn emulated(self: ProcessArchitecture) bool {
        return self.native_machine != IMAGE_FILE_MACHINE_UNKNOWN and
            self.process_machine != IMAGE_FILE_MACHINE_UNKNOWN and
            self.process_machine != self.native_machine;
    }
};

/// Turn a raw `IsWow64Process2` result into a `ProcessArchitecture`.
///
/// Windows documents `pProcessMachine` as `IMAGE_FILE_MACHINE_UNKNOWN` when
/// "the target process is not a WOW64 process" and says nothing about which
/// emulation modes count, so the field cannot be trusted to separate a native
/// ARM64 process from an emulated x64 one on Windows on ARM: both may report
/// UNKNOWN. `process_build_machine` is comptime-certain for the running
/// binary, so resolving through it is right under either behaviour, and it
/// keeps a native process from being shown the word "unknown".
///
/// Split out from `detectProcessArchitecture` so the resolution rule is
/// testable without the Win32 call.
pub fn resolveProcessArchitecture(
    raw_process_machine: u16,
    native_machine: u16,
    process_build_machine: u16,
) ProcessArchitecture {
    return .{
        .process_machine = if (raw_process_machine == IMAGE_FILE_MACHINE_UNKNOWN)
            process_build_machine
        else
            raw_process_machine,
        .native_machine = native_machine,
    };
}

const IsWow64Process2Fn = *const fn (
    hProcess: windows.HANDLE,
    pProcessMachine: *u16,
    pNativeMachine: *u16,
) callconv(.winapi) windows.BOOL;

/// Ask Windows for the process and native machine architecture, or null when
/// it cannot be determined.
///
/// `IsWow64Process2` needs Windows 10 1709, below noctty's own Windows 10 1809
/// floor, so this should always succeed in practice. It is still resolved
/// through `GetProcAddress` rather than statically imported, because a static
/// import turns a missing export into a process-load failure for every user,
/// and a diagnostic aid must never be the reason noctty cannot start.
pub fn detectProcessArchitecture() ?ProcessArchitecture {
    if (comptime builtin.os.tag != .windows) return null;

    const module = windows.kernel32.GetModuleHandleW(
        std.unicode.utf8ToUtf16LeStringLiteral("kernel32.dll"),
    ) orelse return null;
    const entry = windows.kernel32.GetProcAddress(
        module,
        "IsWow64Process2",
    ) orelse return null;
    const isWow64Process2: IsWow64Process2Fn = @ptrCast(entry);

    var process_machine: u16 = IMAGE_FILE_MACHINE_UNKNOWN;
    var native_machine: u16 = IMAGE_FILE_MACHINE_UNKNOWN;
    if (isWow64Process2(
        windows.GetCurrentProcess(),
        &process_machine,
        &native_machine,
    ) == 0) return null;

    return resolveProcessArchitecture(process_machine, native_machine, build_machine);
}

test "Windows machine architecture names use the release artifact vocabulary" {
    try std.testing.expectEqualStrings("x64", machineArchitectureName(IMAGE_FILE_MACHINE_AMD64).?);
    try std.testing.expectEqualStrings("ARM64", machineArchitectureName(IMAGE_FILE_MACHINE_ARM64).?);
    try std.testing.expectEqualStrings("x86", machineArchitectureName(IMAGE_FILE_MACHINE_I386).?);
    try std.testing.expectEqualStrings("ARM32", machineArchitectureName(IMAGE_FILE_MACHINE_ARMNT).?);
    try std.testing.expectEqualStrings("unknown", machineArchitectureName(IMAGE_FILE_MACHINE_UNKNOWN).?);
    try std.testing.expect(machineArchitectureName(0x5032) == null);

    // The raw code survives for anything unnamed so a bug report stays useful.
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("x64", machineArchitectureLabel(&buf, IMAGE_FILE_MACHINE_AMD64));
    try std.testing.expectEqualStrings("machine 0x5032", machineArchitectureLabel(&buf, 0x5032));
    try std.testing.expectEqualStrings("machine 0x0001", machineArchitectureLabel(&buf, 1));
}

test "Windows process architecture resolves the UNKNOWN process machine from the build target" {
    // A native ARM64 process: Windows reports UNKNOWN for its own machine and
    // the user must never be shown that as "unknown".
    const native = resolveProcessArchitecture(
        IMAGE_FILE_MACHINE_UNKNOWN,
        IMAGE_FILE_MACHINE_ARM64,
        IMAGE_FILE_MACHINE_ARM64,
    );
    try std.testing.expectEqual(IMAGE_FILE_MACHINE_ARM64, native.process_machine);
    try std.testing.expect(!native.emulated());

    // An x64 build on ARM64 Windows. Windows may report UNKNOWN here too,
    // exactly as it does for the native case above, so only the build target
    // separates them.
    const emulated_silently = resolveProcessArchitecture(
        IMAGE_FILE_MACHINE_UNKNOWN,
        IMAGE_FILE_MACHINE_ARM64,
        IMAGE_FILE_MACHINE_AMD64,
    );
    try std.testing.expectEqual(IMAGE_FILE_MACHINE_AMD64, emulated_silently.process_machine);
    try std.testing.expect(emulated_silently.emulated());

    // The same machine when Windows does name the WOW process type.
    const emulated_reported = resolveProcessArchitecture(
        IMAGE_FILE_MACHINE_AMD64,
        IMAGE_FILE_MACHINE_ARM64,
        IMAGE_FILE_MACHINE_AMD64,
    );
    try std.testing.expectEqual(emulated_silently, emulated_reported);

    // A 32-bit process under classic WOW64 on x64.
    const wow64 = resolveProcessArchitecture(
        IMAGE_FILE_MACHINE_I386,
        IMAGE_FILE_MACHINE_AMD64,
        IMAGE_FILE_MACHINE_I386,
    );
    try std.testing.expectEqual(IMAGE_FILE_MACHINE_I386, wow64.process_machine);
    try std.testing.expect(wow64.emulated());

    // Nothing is emulated when Windows did not name a native machine.
    try std.testing.expect(!resolveProcessArchitecture(
        IMAGE_FILE_MACHINE_UNKNOWN,
        IMAGE_FILE_MACHINE_UNKNOWN,
        IMAGE_FILE_MACHINE_AMD64,
    ).emulated());
}

test "Windows process architecture detection reaches IsWow64Process2" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(build_machine != IMAGE_FILE_MACHINE_UNKNOWN);

    // IsWow64Process2 needs Windows 10 1709 and noctty's own floor is 1809,
    // so on any machine that can run this suite the export exists and the
    // call succeeds. Accepting null here would let a broken signature, a bad
    // cast, or a misspelled export name pass unnoticed.
    const detected = detectProcessArchitecture() orelse
        return error.IsWow64Process2Unavailable;

    // A wrong interop would leave these as garbage rather than a machine code
    // Windows actually defines.
    try std.testing.expect(detected.native_machine != IMAGE_FILE_MACHINE_UNKNOWN);
    try std.testing.expect(machineArchitectureName(detected.native_machine) != null);
    try std.testing.expectEqual(build_machine, detected.process_machine);
}

pub const KnownFolderPathError = error{
    BufferTooSmall,
};

extern "shell32" fn SHGetKnownFolderPath(
    rfid: *const windows.KNOWNFOLDERID,
    dwFlags: windows.DWORD,
    hToken: ?windows.HANDLE,
    ppszPath: *?windows.PWSTR,
) callconv(.winapi) windows.HRESULT;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

pub fn knownFolderPathUtf8(
    folder_id: *const windows.KNOWNFOLDERID,
    buf: []u8,
) KnownFolderPathError!?[]const u8 {
    var path_w: ?windows.PWSTR = null;
    const hr = SHGetKnownFolderPath(
        folder_id,
        windows.KF_FLAG_DONT_VERIFY,
        null,
        &path_w,
    );
    if (hr != windows.S_OK) return null;

    const w = path_w orelse return null;
    defer CoTaskMemFree(w);

    const slice_w = std.mem.sliceTo(w, 0);
    if (slice_w.len * 3 > buf.len) return error.BufferTooSmall;

    const len = std.unicode.utf16LeToUtf8(buf, slice_w) catch {
        return null;
    };

    return buf[0..len];
}

pub fn isInstallerManagedInstallDir(install_dir: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    var dir = std.fs.openDirAbsolute(install_dir, .{ .iterate = true }) catch return false;
    defer dir.close();

    var has_uninstaller_exe = false;
    var has_uninstaller_dat = false;
    var iter = dir.iterate();
    while (iter.next() catch return false) |entry| {
        if (entry.kind != .file) continue;
        has_uninstaller_exe = has_uninstaller_exe or isInnoUninstallerFileName(entry.name, ".exe");
        has_uninstaller_dat = has_uninstaller_dat or isInnoUninstallerFileName(entry.name, ".dat");
        if (has_uninstaller_exe and has_uninstaller_dat) return true;
    }

    return false;
}

fn isInnoUninstallerFileName(name: []const u8, extension: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "unins") and
        name.len > "unins".len + extension.len and
        std.ascii.eqlIgnoreCase(name[name.len - extension.len ..], extension);
}

pub fn innoUninstallRegistryMatchesInstallDir(install_dir: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    // dist/windows/noctty.iss deliberately retains this AppId. Inno appends
    // `_is1` to AppId for its uninstall key and records InstallLocation there.
    const uninstall_subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\io.github.amanthanvi.winghostty_is1",
    );
    const install_location_name = std.unicode.utf8ToUtf16LeStringLiteral("InstallLocation");
    var registered_buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    var registered_bytes: windows.DWORD = @sizeOf(@TypeOf(registered_buf));
    const status = windows.advapi32.RegGetValueW(
        windows.HKEY_LOCAL_MACHINE,
        uninstall_subkey,
        install_location_name,
        windows.advapi32.RRF.RT_REG_SZ |
            windows.advapi32.RRF.SUBKEY_WOW6464KEY |
            windows.advapi32.RRF.ZEROONFAILURE,
        null,
        @ptrCast(&registered_buf),
        &registered_bytes,
    );
    if (status != @intFromEnum(windows.Win32Error.SUCCESS)) return false;
    if (registered_bytes < @sizeOf(u16) or
        registered_bytes > @sizeOf(@TypeOf(registered_buf)) or
        registered_bytes % @sizeOf(u16) != 0)
    {
        return false;
    }
    const registered_len = registered_bytes / @sizeOf(u16);
    if (registered_buf[registered_len - 1] != 0) return false;

    return registeredInstallLocationMatchesWtf8(
        registered_buf[0 .. registered_len - 1],
        install_dir,
    );
}

fn registeredInstallLocationMatchesWtf8(registered: []const u16, install_dir: []const u8) bool {
    var install_buf: [windows.PATH_MAX_WIDE]u16 = undefined;
    const install_len = std.unicode.wtf8ToWtf16Le(&install_buf, install_dir) catch return false;
    return windowsInstallPathsEqual(registered, install_buf[0..install_len]);
}

fn windowsInstallPathsEqual(a_raw: []const u16, b_raw: []const u16) bool {
    const a = trimTrailingWindowsSeparators(a_raw);
    const b = trimTrailingWindowsSeparators(b_raw);
    return CompareStringOrdinal(
        a.ptr,
        @intCast(a.len),
        b.ptr,
        @intCast(b.len),
        windows.TRUE,
    ) == cstr_equal;
}

fn trimTrailingWindowsSeparators(path: []const u16) []const u16 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    return path[0..end];
}

// CSTR_EQUAL from CompareStringOrdinal's Microsoft Win32 contract.
const cstr_equal: i32 = 2;

extern "kernel32" fn CompareStringOrdinal(
    string1: [*]const u16,
    length1: i32,
    string2: [*]const u16,
    length2: i32,
    ignore_case: windows.BOOL,
) callconv(.winapi) i32;

test "Windows installer management recognizes Inno uninstaller markers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(isInnoUninstallerFileName("unins000.exe", ".exe"));
    try std.testing.expect(isInnoUninstallerFileName("UNINS001.DAT", ".dat"));
    try std.testing.expect(!isInnoUninstallerFileName("noctty.exe", ".exe"));
    try std.testing.expect(!isInnoUninstallerFileName("unins.exe", ".exe"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const install_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(install_dir);
    try tmp.dir.writeFile(.{ .sub_path = "unins000.exe", .data = "uninstaller executable" });
    try std.testing.expect(!isInstallerManagedInstallDir(install_dir));
    try tmp.dir.writeFile(.{ .sub_path = "unins000.dat", .data = "uninstaller data" });
    try std.testing.expect(isInstallerManagedInstallDir(install_dir));
}

test "Windows installer registry paths compare case-insensitively with trailing separators" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(windowsInstallPathsEqual(
        std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Noctty\\"),
        std.unicode.utf8ToUtf16LeStringLiteral("c:\\program files\\noctty"),
    ));
    try std.testing.expect(!windowsInstallPathsEqual(
        std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Noctty-old"),
        std.unicode.utf8ToUtf16LeStringLiteral("C:\\Program Files\\Noctty"),
    ));
    try std.testing.expect(registeredInstallLocationMatchesWtf8(
        &[_]u16{ 'C', ':', '\\', 0xd800 },
        "C:\\\xed\xa0\x80",
    ));
}

pub const exp = struct {
    pub const HPCON = windows.LPVOID;

    pub const CreatePseudoConsoleFn = *const fn (
        size: windows.COORD,
        hInput: windows.HANDLE,
        hOutput: windows.HANDLE,
        dwFlags: windows.DWORD,
        phPC: *HPCON,
    ) callconv(.winapi) windows.HRESULT;
    pub const ResizePseudoConsoleFn = *const fn (
        hPC: HPCON,
        size: windows.COORD,
    ) callconv(.winapi) windows.HRESULT;
    pub const ClosePseudoConsoleFn = *const fn (
        hPC: HPCON,
    ) callconv(.winapi) void;

    pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    pub const CREATE_SUSPENDED = 0x00000004;
    pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
    pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
    pub const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x00000100;
    pub const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;

    pub const STATUS_PENDING = 0x00000103;
    pub const STILL_ACTIVE = STATUS_PENDING;

    pub const STARTUPINFOEX = extern struct {
        StartupInfo: windows.STARTUPINFOW,
        lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    };

    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *windows.HANDLE,
            hWritePipe: *windows.HANDLE,
            lpPipeAttributes: ?*const windows.SECURITY_ATTRIBUTES,
            nSize: windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: windows.COORD,
            hInput: windows.HANDLE,
            hOutput: windows.HANDLE,
            dwFlags: windows.DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: windows.COORD) callconv(.winapi) windows.HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: windows.DWORD,
            dwFlags: windows.DWORD,
            lpSize: *windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: windows.DWORD,
            Attribute: windows.DWORD_PTR,
            lpValue: windows.PVOID,
            cbSize: windows.SIZE_T,
            lpPreviousValue: ?windows.PVOID,
            lpReturnSize: ?*windows.SIZE_T,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: windows.HANDLE,
            lpBuffer: ?windows.LPVOID,
            nBufferSize: windows.DWORD,
            lpBytesRead: ?*windows.DWORD,
            lpTotalBytesAvail: ?*windows.DWORD,
            lpBytesLeftThisMessage: ?*windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
        pub extern "kernel32" fn ResumeThread(
            hThread: windows.HANDLE,
        ) callconv(.winapi) windows.DWORD;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?windows.LPWSTR,
            lpCommandLine: ?windows.LPWSTR,
            lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
            bInheritHandles: windows.BOOL,
            dwCreationFlags: windows.DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?windows.LPWSTR,
            lpStartupInfo: *windows.STARTUPINFOW,
            lpProcessInformation: *windows.PROCESS_INFORMATION,
        ) callconv(.winapi) windows.BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: windows.LPSTR,
            nSize: *windows.DWORD,
        ) callconv(.winapi) windows.BOOL;
    };

    pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
    pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
    pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
    pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;

    pub const ProcThreadAttributeNumber = enum(windows.DWORD) {
        ProcThreadAttributePseudoConsole = 22,
        _,
    };

    /// Corresponds to the ProcThreadAttributeValue define in WinBase.h
    pub fn ProcThreadAttributeValue(
        comptime attribute: ProcThreadAttributeNumber,
        comptime thread: bool,
        comptime input: bool,
        comptime additive: bool,
    ) windows.DWORD {
        return (@intFromEnum(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
            (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
            (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
            (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
    }

    pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(.ProcThreadAttributePseudoConsole, false, true, false);
};
