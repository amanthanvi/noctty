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
