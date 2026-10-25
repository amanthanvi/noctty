//! Visual Studio's developer shells, found the way Windows Terminal's Visual
//! Studio profile generator finds them (microsoft/terminal 10630264af:
//! `VsSetupConfiguration.cpp`, `VsDevCmdGenerator.cpp`,
//! `VsDevShellGenerator.cpp`): the Setup Configuration COM API lists the
//! installed instances, and nothing is started to find them (no `vswhere`,
//! `VsDevCmd.bat` or `Enter-VsDevShell`).
//!
//! This file holds the instance model, the COM adapter that fills it
//! (`ComSource`) and the pure rules (order, names, arguments);
//! `windows_shell.appendVisualStudioProfiles` makes the profiles.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const log = std.log.scoped(.windows_visual_studio);

/// `visual-studio-profiles`.
pub const Mode = enum {
    /// Every instance, with all but the newest hidden (Windows Terminal's
    /// default): the hidden ones are not listed but a saved session,
    /// `default-profile` or `profile-order` can still name them.
    newest,
    /// Every instance, shown.
    all,
    /// None, and Visual Studio is never asked.
    none,
};

/// The architecture the developer environment targets (`-arch`) and the one
/// its tools run on (`-host_arch`): the one noctty was built for, as in
/// Windows Terminal.
pub const Arch = enum { x64, arm64 };

pub const build_arch: Arch = if (builtin.cpu.arch == .aarch64) .arm64 else .x64;

/// One installed Visual Studio, as Setup Configuration reports it.
pub const Instance = struct {
    /// `ISetupInstance.GetInstanceId`: stable across updates and moves.
    id: []const u8,
    /// `ISetupInstance.GetInstallationPath`.
    path: []const u8,
    /// `ISetupInstance.GetInstallationVersion` as written (`18.0.11205.157`).
    version_text: []const u8,
    /// The same, through `ISetupHelper.ParseVersion`: four 16-bit fields,
    /// major first, so versions compare as integers (`version`).
    version: u64,
    /// `ISetupInstance.GetInstallDate`, as FILETIME ticks.
    install_date: u64,
    /// What follows "for VS " in the profile names (`nameSuffix`).
    suffix: []const u8,
};

/// What a query found. `complete` is false when the list may lack an
/// instance (the query failed), so the profile list is asked for again later,
/// as for a busy SSH config; a machine without Visual Studio is complete.
pub const Discovery = struct {
    instances: []Instance = &.{},
    complete: bool = true,
    /// Whether Setup Configuration is installed at all.
    registered: bool = true,
};

/// A version as `ISetupHelper.ParseVersion` packs it, for comparisons.
pub fn version(major: u16, minor: u16) u64 {
    return @as(u64, major) << 48 | @as(u64, minor) << 32;
}

/// Newest first: by version, then by install date (Windows Terminal's order).
pub fn sortNewestFirst(instances: []Instance) void {
    std.sort.insertion(Instance, instances, {}, struct {
        fn newer(_: void, a: Instance, b: Instance) bool {
            if (a.version != b.version) return a.version > b.version;
            return a.install_date > b.install_date;
        }
    }.newer);
}

/// The text after "for VS " in an instance's profile names, by Windows
/// Terminal's `BuildProfileNameSuffix`: the catalog's `productLineVersion`
/// (`2022`, `18`), then ` (<nickname>)` when the instance has one, else
/// ` [<channel>]` for a channel other than Release (`[Preview]`). Without a
/// catalog (`product_line` null) it is the version.
pub fn nameSuffix(
    alloc: Allocator,
    product_line: ?[]const u8,
    nickname: []const u8,
    channel_id: []const u8,
    version_text: []const u8,
) Allocator.Error![]u8 {
    const line = product_line orelse return try alloc.dupe(u8, version_text);
    if (nickname.len > 0) return try std.fmt.allocPrint(alloc, "{s} ({s})", .{ line, nickname });
    // `channelId` is `<product>.<major>.<channel>`.
    const channel = if (std.mem.lastIndexOfScalar(u8, channel_id, '.')) |dot| channel_id[dot + 1 ..] else "";
    if (channel.len == 0 or std.mem.eql(u8, channel, "Release")) return try alloc.dupe(u8, line);
    return try std.fmt.allocPrint(alloc, "{s} [{s}]", .{ line, channel });
}

pub fn commandPromptLabel(alloc: Allocator, instance: Instance) Allocator.Error![]u8 {
    return try std.fmt.allocPrint(alloc, "Developer Command Prompt for VS {s}", .{instance.suffix});
}

pub fn powerShellLabel(alloc: Allocator, instance: Instance) Allocator.Error![]u8 {
    return try std.fmt.allocPrint(alloc, "Developer PowerShell for VS {s}", .{instance.suffix});
}

/// `VsDevCmd.bat` under an installation.
pub const dev_cmd_relative = "Common7\\Tools\\VsDevCmd.bat";

/// The DevShell module under an installation: it moved in 16.3.
pub fn devShellModuleRelative(instance_version: u64) []const u8 {
    return if (instance_version >= version(16, 3))
        "Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll"
    else
        "Common7\\Tools\\vsdevshell\\Microsoft.VisualStudio.DevShell.dll";
}

/// Developer PowerShell (`Enter-VsDevShell`) came with 16.2.
pub fn hasDevShell(instance_version: u64) bool {
    return instance_version >= version(16, 2);
}

/// `-arch=` and `-host_arch=` for `VsDevCmd.bat`: on ARM64 the tools run
/// natively from 17.4 and under x64 emulation before.
pub fn devCmdArguments(arch: Arch, instance_version: u64) [2][]const u8 {
    return switch (arch) {
        .x64 => .{ "-arch=x64", "-host_arch=x64" },
        .arm64 => .{
            "-arch=arm64",
            if (instance_version >= version(17, 4)) "-host_arch=arm64" else "-host_arch=x64",
        },
    };
}

/// The flags a Developer PowerShell profile gives its shell, before its
/// script (`devShellScript`): `<shell> -NoExit -Command <script>`.
pub const dev_shell_flags = [_][]const u8{ "-NoExit", "-Command" };

// The fixed text of `devShellScript`, around the module path, the instance
// id and the `VsDevCmd.bat` arguments. The id is quoted too: PowerShell
// reads a bare argument made of digits, or of digits and a `d` or `e`, as a
// number, so `01234567` would reach Enter-VsDevShell as `1234567` and
// `1234567d` as `1234567` (measured with the parser, both hosts).
const dev_shell_import = "&{Import-Module '";
const dev_shell_enter = "'; Enter-VsDevShell '";
const dev_shell_arguments = "' -SkipAutomaticLocation -DevCmdArguments '";
const dev_shell_end = "'}";

/// The quote characters a PowerShell single-quoted string opens and closes
/// with: `'` and the typographic single quotes.
fn isPowerShellSingleQuote(cp: u21) bool {
    return switch (cp) {
        '\'', 0x2018, 0x2019, 0x201A, 0x201B => true,
        else => false,
    };
}

/// The `-Command` script of a Developer PowerShell profile. The module path
/// goes in a PowerShell single-quoted string, in which nothing is expanded:
/// a `$` or a backtick in an install path stays as written. The quote
/// characters PowerShell accepts there (`'` and the typographic single
/// quotes) are doubled, which is how such a string holds one.
pub fn devShellScript(
    alloc: Allocator,
    module_path: []const u8,
    instance: Instance,
    arch: Arch,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, dev_shell_import);
    var view = std.unicode.Wtf8View.initUnchecked(module_path);
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        try out.appendSlice(alloc, slice);
        const cp = std.unicode.wtf8Decode(slice) catch continue;
        if (isPowerShellSingleQuote(cp)) try out.appendSlice(alloc, slice);
    }
    const args = devCmdArguments(arch, instance.version);
    for ([_][]const u8{ dev_shell_enter, instance.id, dev_shell_arguments, args[0], " ", args[1], dev_shell_end }) |part| {
        try out.appendSlice(alloc, part);
    }
    return try out.toOwnedSlice(alloc);
}

/// The script of a Developer PowerShell profile's argv (a slice of strings,
/// with or without sentinels): `dev_shell_flags` after the shell, then a
/// script `isDevShellScript` accepts. Null for any other argv.
///
/// It is the one `-Command` line shell integration wraps
/// (`shell_integration.setupPowerShell`): the script runs first, as it does
/// on its own, and the integration loads after it. noctty wrote it, and all
/// it does is import a module from a path that is never expanded and enter
/// the developer environment, which sets variables and leaves the prompt
/// and the directory as they were, so nothing the integration adds changes
/// what it does or when the shell exits. A line a user wrote in exactly
/// this form is the same line and gets the same. Any other line, a variant
/// of this one included, is the user's own script, which runs as written.
pub fn devShellPrelude(argv: anytype) ?[]const u8 {
    if (argv.len != 1 + dev_shell_flags.len + 1) return null;
    for (dev_shell_flags, argv[1 .. argv.len - 1]) |flag, arg| {
        if (!std.mem.eql(u8, flag, arg)) return null;
    }
    const script: []const u8 = argv[argv.len - 1];
    return if (isDevShellScript(script)) script else null;
}

/// Whether `script` is what `devShellScript` builds for some module path, a
/// plain instance id (`isPlainInstanceId`) and the `VsDevCmd.bat` arguments
/// of an architecture (`devCmdArguments`), exactly.
pub fn isDevShellScript(script: []const u8) bool {
    if (!std.mem.startsWith(u8, script, dev_shell_import)) return false;
    // The module path: a doubled quote character is one quote in it, as
    // `devShellScript` writes them, and the first quote that is not doubled
    // ends it. PowerShell also reads two different quote characters as one
    // quote (measured with the parser, both hosts). noctty never writes
    // that, and such a path ends here at a quote the checks below refuse,
    // so up to an accepted end PowerShell reads the same string.
    const body = script[dev_shell_import.len..];
    var view = std.unicode.Wtf8View.init(body) catch return false;
    var it = view.iterator();
    const closed = while (it.nextCodepointSlice()) |slice| {
        const cp = std.unicode.wtf8Decode(slice) catch return false;
        if (!isPowerShellSingleQuote(cp)) continue;
        const quote_at = it.i - slice.len;
        const next = it.nextCodepoint() orelse break quote_at;
        if (next != cp) break quote_at;
    } else return false;
    // `devShellScript` closes the string with `'`.
    var rest = body[closed..];
    if (!std.mem.startsWith(u8, rest, dev_shell_enter)) return false;
    rest = rest[dev_shell_enter.len..];
    const id_end = std.mem.indexOfScalar(u8, rest, '\'') orelse return false;
    if (!isPlainInstanceId(rest[0..id_end])) return false;
    rest = rest[id_end..];
    if (!std.mem.startsWith(u8, rest, dev_shell_arguments)) return false;
    rest = rest[dev_shell_arguments.len..];
    if (!std.mem.endsWith(u8, rest, dev_shell_end)) return false;
    return isDevCmdArgumentsText(rest[0 .. rest.len - dev_shell_end.len]);
}

/// Whether `text` is `devCmdArguments` of some architecture and version,
/// as `devShellScript` joins them.
fn isDevCmdArgumentsText(text: []const u8) bool {
    for ([_]Arch{ .x64, .arm64 }) |arch| {
        for ([_]u64{ 0, version(17, 4) }) |instance_version| {
            const args = devCmdArguments(arch, instance_version);
            if (text.len == args[0].len + 1 + args[1].len and
                std.mem.startsWith(u8, text, args[0]) and
                text[args[0].len] == ' ' and
                std.mem.endsWith(u8, text, args[1])) return true;
        }
    }
    return false;
}

/// An instance id noctty puts in a profile key and a PowerShell script:
/// letters and digits only (Setup Configuration's are eight hex digits).
pub fn isPlainInstanceId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Setup Configuration (Setup.Configuration.h, Microsoft.VisualStudio.Setup.Configuration.Native).

const HRESULT = windows.HRESULT;
const GUID = windows.GUID;

const S_OK: HRESULT = 0;
const S_FALSE: HRESULT = 1;
const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));
const REGDB_E_CLASSNOTREG: HRESULT = @bitCast(@as(u32, 0x80040154));
/// The class is registered but its DLL cannot be loaded (a test case:
/// incomplete, like any failure but `REGDB_E_CLASSNOTREG`).
const HRESULT_MOD_NOT_FOUND: HRESULT = @bitCast(@as(u32, 0x8007007E));
const HRESULT_FILE_NOT_FOUND: HRESULT = @bitCast(@as(u32, 0x80070002));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const COINIT_MULTITHREADED: u32 = 0x0;
const CLSCTX_INPROC_SERVER: u32 = 0x1;
const VT_BSTR: u16 = 8;

const CLSID_SetupConfiguration = GUID.parse("{177F0C4A-1CD3-4DE7-A32C-71DBBB9FA36D}");
const IID_ISetupConfiguration2 = GUID.parse("{26AAB78C-4A60-49D6-AF3B-3C35BC93365D}");
const IID_ISetupInstance2 = GUID.parse("{89143C9A-05AF-49B0-B717-72E218A2185C}");
const IID_ISetupInstanceCatalog = GUID.parse("{9AD8E40F-39A2-40F1-BF64-0A6C50DD9EEB}");
const IID_ISetupPropertyStore = GUID.parse("{C601C175-A3BE-44BC-91F6-4568D230FC83}");
const IID_ISetupHelper = GUID.parse("{42B21B78-6192-463E-87BF-D577838F1D5C}");

const BSTR = ?[*:0]u16;

/// OAIDL's VARIANT: an 8-byte header and a union two pointers wide (its
/// record arm), 24 bytes on 64-bit Windows. `GetValue` writes into it, so it
/// must be the full size.
const VARIANT = extern struct {
    vt: u16 = 0,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    value: extern union {
        bstr: BSTR,
        record: [2]?*anyopaque,
        i64_val: i64,
    } = .{ .record = .{ null, null } },
};

const IUnknownMethods = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

const ISetupConfiguration2Vtbl = extern struct {
    unknown: IUnknownMethods,
    EnumInstances: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetInstanceForCurrentProcess: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetInstanceForPath: *const fn (*anyopaque, [*:0]const u16, *?*anyopaque) callconv(.winapi) HRESULT,
    EnumAllInstances: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const IEnumSetupInstancesVtbl = extern struct {
    unknown: IUnknownMethods,
    Next: *const fn (*anyopaque, u32, *?*anyopaque, ?*u32) callconv(.winapi) HRESULT,
    Skip: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT,
    Reset: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    Clone: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
};

const ISetupInstanceVtbl = extern struct {
    unknown: IUnknownMethods,
    GetInstanceId: *const fn (*anyopaque, *BSTR) callconv(.winapi) HRESULT,
    GetInstallDate: *const fn (*anyopaque, *windows.FILETIME) callconv(.winapi) HRESULT,
    GetInstallationName: *const fn (*anyopaque, *BSTR) callconv(.winapi) HRESULT,
    GetInstallationPath: *const fn (*anyopaque, *BSTR) callconv(.winapi) HRESULT,
    GetInstallationVersion: *const fn (*anyopaque, *BSTR) callconv(.winapi) HRESULT,
    GetDisplayName: *const fn (*anyopaque, u32, *BSTR) callconv(.winapi) HRESULT,
    GetDescription: *const fn (*anyopaque, u32, *BSTR) callconv(.winapi) HRESULT,
    ResolvePath: *const fn (*anyopaque, ?[*:0]const u16, *BSTR) callconv(.winapi) HRESULT,
};

const ISetupInstance2Vtbl = extern struct {
    instance: ISetupInstanceVtbl,
    GetState: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
    GetPackages: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetProduct: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetProductPath: *const fn (*anyopaque, *BSTR) callconv(.winapi) HRESULT,
    GetErrors: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    IsLaunchable: *const fn (*anyopaque, *i16) callconv(.winapi) HRESULT,
    IsComplete: *const fn (*anyopaque, *i16) callconv(.winapi) HRESULT,
    GetProperties: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetEnginePath: *const fn (*anyopaque, *BSTR) callconv(.winapi) HRESULT,
};

const ISetupInstanceCatalogVtbl = extern struct {
    unknown: IUnknownMethods,
    GetCatalogInfo: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    IsPrerelease: *const fn (*anyopaque, *i16) callconv(.winapi) HRESULT,
};

const ISetupPropertyStoreVtbl = extern struct {
    unknown: IUnknownMethods,
    GetNames: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
    GetValue: *const fn (*anyopaque, [*:0]const u16, *VARIANT) callconv(.winapi) HRESULT,
};

const ISetupHelperVtbl = extern struct {
    unknown: IUnknownMethods,
    ParseVersion: *const fn (*anyopaque, [*:0]const u16, *u64) callconv(.winapi) HRESULT,
    ParseVersionRange: *const fn (*anyopaque, [*:0]const u16, *u64, *u64) callconv(.winapi) HRESULT,
};

/// A COM interface pointer: its first field points at the vtable.
fn Interface(comptime Vtbl: type) type {
    return extern struct {
        vtbl: *const Vtbl,

        const Self = @This();

        fn from(ptr: *anyopaque) *Self {
            return @ptrCast(@alignCast(ptr));
        }

        fn raw(self: *Self) *anyopaque {
            return @ptrCast(self);
        }

        fn unknown(self: *Self) *const IUnknownMethods {
            return @ptrCast(@alignCast(self.vtbl));
        }

        fn release(self: *Self) void {
            _ = self.unknown().Release(self.raw());
        }

        fn query(self: *Self, comptime Other: type, iid: *const GUID) ?*Other {
            var out: ?*anyopaque = null;
            if (self.unknown().QueryInterface(self.raw(), iid, &out) < 0) return null;
            return Other.from(out orelse return null);
        }
    };
}

const SetupConfiguration2 = Interface(ISetupConfiguration2Vtbl);
const EnumSetupInstances = Interface(IEnumSetupInstancesVtbl);
const SetupInstance = Interface(ISetupInstanceVtbl);
const SetupInstance2 = Interface(ISetupInstance2Vtbl);
const SetupInstanceCatalog = Interface(ISetupInstanceCatalogVtbl);
const SetupPropertyStore = Interface(ISetupPropertyStoreVtbl);
const SetupHelper = Interface(ISetupHelperVtbl);

/// The process-wide calls `query` makes; tests pass their own.
const SystemCom = struct {
    extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoCreateInstance(
        class_id: *const GUID,
        outer: ?*anyopaque,
        context: u32,
        interface_id: *const GUID,
        result: *?*anyopaque,
    ) callconv(.winapi) HRESULT;
    extern "oleaut32" fn SysFreeString(value: BSTR) callconv(.winapi) void;
    extern "oleaut32" fn SysStringLen(value: BSTR) callconv(.winapi) u32;
    extern "oleaut32" fn VariantClear(value: *VARIANT) callconv(.winapi) HRESULT;

    pub fn initialize() HRESULT {
        return CoInitializeEx(null, COINIT_MULTITHREADED);
    }

    pub fn uninitialize() void {
        CoUninitialize();
    }

    pub fn create(out: *?*anyopaque) HRESULT {
        return CoCreateInstance(&CLSID_SetupConfiguration, null, CLSCTX_INPROC_SERVER, &IID_ISetupConfiguration2, out);
    }

    pub fn freeString(value: BSTR) void {
        SysFreeString(value);
    }

    pub fn stringLen(value: BSTR) u32 {
        return SysStringLen(value);
    }

    pub fn clearVariant(value: *VARIANT) void {
        _ = VariantClear(value);
    }
};

var warned = std.atomic.Value(bool).init(false);

/// A failed query is asked again at the next profile refresh, so it is
/// reported once per process, as the SSH discovery's failures are.
fn warnOnce(comptime fmt: []const u8, args: anytype) void {
    if (warned.swap(true, .monotonic)) return;
    log.warn(fmt, args);
}

/// The real instance list, through Setup Configuration.
pub const ComSource = struct {
    pub fn query(_: ComSource, alloc: Allocator) Allocator.Error!Discovery {
        if (comptime builtin.os.tag != .windows) return .{ .registered = false };
        return try queryWith(alloc, SystemCom);
    }
};

/// Ask Setup Configuration for every launchable instance (`EnumInstances`,
/// which leaves out incomplete installs), in its order. COM is set up for
/// the calling thread for the length of the call: a discovery worker joins
/// the multithreaded apartment and leaves it after. A thread that already
/// has an apartment keeps it (`RPC_E_CHANGED_MODE` from the UI thread's
/// single-threaded one), which works because the class is registered with
/// ThreadingModel Both. Only an `S_OK` or `S_FALSE` is balanced with
/// `CoUninitialize`. Strings are copied into `alloc`.
fn queryWith(alloc: Allocator, comptime Com: type) Allocator.Error!Discovery {
    const init = Com.initialize();
    const initialized = init == S_OK or init == S_FALSE;
    defer if (initialized) Com.uninitialize();
    if (!initialized and init != RPC_E_CHANGED_MODE) {
        warnOnce("Visual Studio profiles skipped: COM unavailable hr=0x{x}", .{@as(u32, @bitCast(init))});
        return .{ .complete = false };
    }

    var raw: ?*anyopaque = null;
    const created = Com.create(&raw);
    if (created < 0 or raw == null) {
        // No Visual Studio 2017 or later: nothing registered the class.
        // Nothing to list, and that is final. Anything else, a DLL the
        // registration names but that is missing too (the Installer may be
        // replacing it), is asked again.
        if (created == REGDB_E_CLASSNOTREG) return .{ .registered = false };
        warnOnce("Visual Studio profiles skipped: Setup Configuration unavailable hr=0x{x}", .{@as(u32, @bitCast(created))});
        return .{ .complete = false };
    }
    const config = SetupConfiguration2.from(raw.?);
    defer config.release();

    var enum_raw: ?*anyopaque = null;
    const enumerated = config.vtbl.EnumInstances(config.raw(), &enum_raw);
    if (enumerated < 0 or enum_raw == null) {
        warnOnce("Visual Studio profiles skipped: instance enumeration failed hr=0x{x}", .{@as(u32, @bitCast(enumerated))});
        return .{ .complete = false };
    }
    const instances = EnumSetupInstances.from(enum_raw.?);
    defer instances.release();
    const helper = config.query(SetupHelper, &IID_ISetupHelper) orelse {
        warnOnce("Visual Studio profiles skipped: no version helper", .{});
        return .{ .complete = false };
    };
    defer helper.release();

    var list: std.ArrayList(Instance) = .empty;
    errdefer list.deinit(alloc);
    var complete = true;
    while (true) {
        var item: ?*anyopaque = null;
        const hr = instances.vtbl.Next(instances.raw(), 1, &item, null);
        if (hr != S_OK or item == null) {
            if (hr < 0) {
                warnOnce("Visual Studio profiles incomplete: enumeration failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                complete = false;
            }
            break;
        }
        const instance = SetupInstance.from(item.?);
        defer instance.release();
        // An instance Setup Configuration cannot describe now is left out,
        // and the list asked for again; the others still make profiles.
        const entry = (try readInstance(alloc, Com, instance, helper, &complete)) orelse {
            warnOnce("Visual Studio profiles incomplete: an instance could not be read", .{});
            complete = false;
            continue;
        };
        try list.append(alloc, entry);
    }
    return .{ .instances = try list.toOwnedSlice(alloc), .complete = complete };
}

/// Null when a value a profile needs (id, path, version) cannot be read;
/// an install date that cannot be read leaves the instance in, ordered as
/// the oldest of its version, and `complete` false.
fn readInstance(
    alloc: Allocator,
    comptime Com: type,
    instance: *SetupInstance,
    helper: *SetupHelper,
    complete: *bool,
) Allocator.Error!?Instance {
    const id = (try readString(alloc, Com, instance, instance.vtbl.GetInstanceId)) orelse return null;
    const path = (try readString(alloc, Com, instance, instance.vtbl.GetInstallationPath)) orelse return null;
    const version_text = (try readString(alloc, Com, instance, instance.vtbl.GetInstallationVersion)) orelse return null;

    const version_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, version_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer alloc.free(version_w);
    var parsed: u64 = 0;
    if (helper.vtbl.ParseVersion(helper.raw(), version_w.ptr, &parsed) < 0) return null;

    var date: windows.FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
    if (instance.vtbl.GetInstallDate(instance.raw(), &date) < 0) {
        warnOnce("Visual Studio profiles incomplete: an install date could not be read", .{});
        complete.* = false;
        date = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 };
    }

    // Windows Terminal's suffix sources: the catalog's product line, the
    // instance's own nickname, and its channel.
    var product_line: ?[]const u8 = null;
    if (instance.query(SetupInstanceCatalog, &IID_ISetupInstanceCatalog)) |catalog| {
        defer catalog.release();
        var store_raw: ?*anyopaque = null;
        const hr = catalog.vtbl.GetCatalogInfo(catalog.raw(), &store_raw);
        if (hr >= 0 and store_raw != null) {
            const store = SetupPropertyStore.from(store_raw.?);
            defer store.release();
            product_line = try readProperty(alloc, Com, store, "productLineVersion");
        }
    }
    var nickname: []const u8 = "";
    if (instance.query(SetupInstance2, &IID_ISetupInstance2)) |instance2| {
        defer instance2.release();
        var store_raw: ?*anyopaque = null;
        const hr = instance2.vtbl.GetProperties(instance2.raw(), &store_raw);
        if (hr >= 0 and store_raw != null) {
            const store = SetupPropertyStore.from(store_raw.?);
            defer store.release();
            nickname = try readProperty(alloc, Com, store, "nickname");
        }
    }
    var channel_id: []const u8 = "";
    if (instance.query(SetupPropertyStore, &IID_ISetupPropertyStore)) |store| {
        defer store.release();
        channel_id = try readProperty(alloc, Com, store, "channelId");
    }

    return .{
        .id = id,
        .path = path,
        .version_text = version_text,
        .version = parsed,
        .install_date = @as(u64, date.dwHighDateTime) << 32 | date.dwLowDateTime,
        .suffix = try nameSuffix(alloc, product_line, nickname, channel_id, version_text),
    };
}

fn readString(
    alloc: Allocator,
    comptime Com: type,
    instance: *SetupInstance,
    getter: *const fn (*anyopaque, *BSTR) callconv(.winapi) HRESULT,
) Allocator.Error!?[]const u8 {
    var value: BSTR = null;
    if (getter(instance.raw(), &value) < 0) return null;
    defer Com.freeString(value);
    return try bstrToUtf8(alloc, Com, value);
}

/// A string property, or "" when the store has none (Windows Terminal's
/// `GetStringProperty`).
fn readProperty(alloc: Allocator, comptime Com: type, store: *SetupPropertyStore, comptime name: []const u8) Allocator.Error![]const u8 {
    var value: VARIANT = .{};
    const hr = store.vtbl.GetValue(store.raw(), std.unicode.utf8ToUtf16LeStringLiteral(name), &value);
    defer Com.clearVariant(&value);
    if (hr < 0 or value.vt != VT_BSTR) return "";
    return (try bstrToUtf8(alloc, Com, value.value.bstr)) orelse "";
}

fn bstrToUtf8(alloc: Allocator, comptime Com: type, value: BSTR) Allocator.Error!?[]const u8 {
    const ptr = value orelse return null;
    const len = Com.stringLen(value);
    return try std.unicode.wtf16LeToWtf8Alloc(alloc, ptr[0..len]);
}

test "VARIANT and the interface vtables have their SDK layout" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 16), @sizeOf(VARIANT));
    try testing.expectEqual(@as(usize, 8), @offsetOf(VARIANT, "value"));
    const slot = @sizeOf(usize);
    try testing.expectEqual(7 * slot, @sizeOf(ISetupConfiguration2Vtbl));
    try testing.expectEqual(3 * slot, @offsetOf(ISetupConfiguration2Vtbl, "EnumInstances"));
    try testing.expectEqual(3 * slot, @offsetOf(IEnumSetupInstancesVtbl, "Next"));
    try testing.expectEqual(11 * slot, @sizeOf(ISetupInstanceVtbl));
    try testing.expectEqual(3 * slot, @offsetOf(ISetupInstanceVtbl, "GetInstanceId"));
    try testing.expectEqual(6 * slot, @offsetOf(ISetupInstanceVtbl, "GetInstallationPath"));
    try testing.expectEqual(7 * slot, @offsetOf(ISetupInstanceVtbl, "GetInstallationVersion"));
    try testing.expectEqual(18 * slot, @offsetOf(ISetupInstance2Vtbl, "GetProperties"));
    try testing.expectEqual(3 * slot, @offsetOf(ISetupInstanceCatalogVtbl, "GetCatalogInfo"));
    try testing.expectEqual(4 * slot, @offsetOf(ISetupPropertyStoreVtbl, "GetValue"));
    try testing.expectEqual(3 * slot, @offsetOf(ISetupHelperVtbl, "ParseVersion"));
}

test "Visual Studio name suffixes follow Windows Terminal" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Case = struct { line: ?[]const u8, nick: []const u8, channel: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .line = "18", .nick = "", .channel = "VisualStudio.18.Release", .want = "18" },
        .{ .line = "2022", .nick = "", .channel = "VisualStudio.17.Preview", .want = "2022 [Preview]" },
        .{ .line = "2022", .nick = "Work", .channel = "VisualStudio.17.Preview", .want = "2022 (Work)" },
        .{ .line = "2022", .nick = "", .channel = "", .want = "2022" },
        .{ .line = "2022", .nick = "", .channel = "NoDots", .want = "2022" },
        .{ .line = "", .nick = "", .channel = "VisualStudio.17.Release", .want = "" },
        .{ .line = null, .nick = "Work", .channel = "VisualStudio.17.Preview", .want = "17.14.36414.22" },
    }) |case| {
        const got = try nameSuffix(alloc, case.line, case.nick, case.channel, "17.14.36414.22");
        defer alloc.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "the Developer PowerShell script quotes the module path for PowerShell" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const instance: Instance = .{ .id = "6bb7cfd9", .path = "", .version_text = "", .version = version(18, 0), .install_date = 0, .suffix = "18" };
    const plain = try devShellScript(alloc, "C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll", instance, .x64);
    defer alloc.free(plain);
    try testing.expectEqualStrings(
        "&{Import-Module 'C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        plain,
    );
    // `'` (and its typographic forms) doubled; `$`, a backtick and `"` kept.
    const odd = try devShellScript(alloc, "D:\\VS 'o\u{2019}$env:x`n\\m.dll", instance, .arm64);
    defer alloc.free(odd);
    try testing.expectEqualStrings(
        "&{Import-Module 'D:\\VS ''o\u{2019}\u{2019}$env:x`n\\m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=arm64 -host_arch=arm64'}",
        odd,
    );
    // An id PowerShell would read as a number if it were bare.
    var numeric = instance;
    numeric.id = "01234567";
    const quoted = try devShellScript(alloc, "C:\\m.dll", numeric, .x64);
    defer alloc.free(quoted);
    try testing.expectEqualStrings(
        "&{Import-Module 'C:\\m.dll'; Enter-VsDevShell '01234567' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        quoted,
    );
}

test "every Developer PowerShell script noctty builds is recognised as its own" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const paths = [_][]const u8{
        "C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll",
        "C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\BuildTools\\Common7\\Tools\\vsdevshell\\Microsoft.VisualStudio.DevShell.dll",
        "D:\\VS 'o\u{2019}$env:x`n\\m.dll",
        // Every quote PowerShell pairs, at the end, before the closing one.
        "D:\\a'\u{2018}\u{2019}\u{201A}\u{201B}",
        "D:\\'; Enter-VsDevShell x -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        "D:\\\u{00E9}\u{1F600}\"$(Remove-Item x)\\m.dll",
        "",
    };
    for (paths) |path| {
        for ([_]Arch{ .x64, .arm64 }) |arch| {
            for ([_]u64{ version(16, 2), version(17, 4), version(18, 10) }, [_][]const u8{ "6bb7cfd9", "01234567", "1234567d" }) |instance_version, id| {
                const instance: Instance = .{ .id = id, .path = "", .version_text = "", .version = instance_version, .install_date = 0, .suffix = "" };
                const script = try devShellScript(alloc, path, instance, arch);
                defer alloc.free(script);
                try testing.expect(isDevShellScript(script));
                const argv = [_][]const u8{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoExit", "-Command", script };
                try testing.expectEqualStrings(script, devShellPrelude(&argv).?);
            }
        }
    }
}

test "a script noctty did not build is not a Developer PowerShell prelude" {
    const testing = std.testing;
    const ok = "&{Import-Module 'C:\\VS\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}";
    try testing.expect(isDevShellScript(ok));
    for ([_][]const u8{
        // Windows Terminal's line, as the shell receives it: double-quoted,
        // so expandable, strings.
        "&{Import-Module \"C:\\VS\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll\"; Enter-VsDevShell 6bb7cfd9 -SkipAutomaticLocation -DevCmdArguments \"-arch=x64 -host_arch=x64\"}",
        // A user's variants: another architecture, another start directory,
        // another statement, a space too many.
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x86 -host_arch=x64'}",
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '6bb7cfd9' -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}; Set-Location C:\\src",
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'} ",
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64  -host_arch=x64'}",
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=arm64'}",
        // A lone quote ends the path, so the rest is code.
        "&{Import-Module 'C:\\VS\\'; Remove-Item x; 'm.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        // A typographic quote closes it too, where noctty closes with `'`.
        "&{Import-Module 'C:\\VS\\m.dll\u{2019}; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        // Two different quote characters, which PowerShell reads as one
        // quote and noctty never writes.
        "&{Import-Module 'C:\\VS\\a'\u{2019}m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        "&{Import-Module 'C:\\VS\\a\u{2019}'m.dll'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        // An id that is not one word of letters and digits.
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '$(Remove-Item x)' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell '6bb7'cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        // A bare id, which PowerShell may read as a number.
        "&{Import-Module 'C:\\VS\\m.dll'; Enter-VsDevShell 01234567 -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
        // Unclosed, cut short, empty, not text.
        "&{Import-Module 'C:\\VS\\m.dll",
        "&{Import-Module 'C:\\VS\\m.dll''",
        ok[0 .. ok.len - 1],
        "",
        "&{Import-Module '\xff'; Enter-VsDevShell '6bb7cfd9' -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'}",
    }) |script| {
        try testing.expect(!isDevShellScript(script));
    }

    // The argv must be the profile's: the shell, `-NoExit -Command`, the
    // script, and nothing else.
    const shell = "C:\\Program Files\\PowerShell\\7\\pwsh.exe";
    const profile_argv = [_][:0]const u8{ shell, "-NoExit", "-Command", ok };
    try testing.expectEqualStrings(ok, devShellPrelude(&profile_argv).?);
    for ([_][]const []const u8{
        &.{ shell, "-NoExit", "-Command" },
        &.{ shell, "-NoExit", "-Command", ok, "x" },
        &.{ shell, "-NoLogo", "-NoExit", "-Command", ok },
        &.{ shell, "-noexit", "-command", ok },
        &.{ shell, "-Command", "-NoExit", ok },
        &.{ shell, "-NoExit", "-c", ok },
        &.{ shell, "-NoExit", "-Command", ok[0 .. ok.len - 1] },
    }) |argv| {
        try testing.expect(devShellPrelude(argv) == null);
    }
}

test "instances sort newest first, by version then install date" {
    var list = [_]Instance{
        .{ .id = "a", .path = "", .version_text = "", .version = version(17, 14), .install_date = 5, .suffix = "" },
        .{ .id = "b", .path = "", .version_text = "", .version = version(18, 10), .install_date = 1, .suffix = "" },
        .{ .id = "c", .path = "", .version_text = "", .version = version(17, 14), .install_date = 9, .suffix = "" },
        .{ .id = "d", .path = "", .version_text = "", .version = version(16, 11), .install_date = 99, .suffix = "" },
    };
    sortNewestFirst(&list);
    for (list, [_][]const u8{ "b", "c", "a", "d" }) |instance, id| try std.testing.expectEqualStrings(id, instance.id);
}

/// One instance a fake Setup Configuration lists: its path is `C:\VS\<id>`,
/// it has no catalog or properties (so its suffix is its version), and
/// `fail` names the one call that fails for it (`parse`: `ParseVersion`).
const FakeInstanceSpec = struct {
    id: []const u8,
    version: []const u8 = "17.14.1.2",
    fail: enum { none, id, path, version, parse, date } = .none,
};

/// `SystemCom` with fixed answers, counting the apartment calls and every
/// `Release`. `EnumInstances` lists `specs` when it succeeds.
fn FakeCom(
    comptime init_hr: HRESULT,
    comptime create_hr: HRESULT,
    comptime enum_hr: HRESULT,
    comptime specs: []const FakeInstanceSpec,
) type {
    return struct {
        var initialized: usize = 0;
        var uninitialized: usize = 0;
        var created: usize = 0;
        var released: usize = 0;

        const unknown: IUnknownMethods = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release };
        const Config = struct {
            iface: SetupConfiguration2 = .{ .vtbl = &vtbl },
            const vtbl: ISetupConfiguration2Vtbl = .{
                .unknown = .{ .QueryInterface = configQueryInterface, .AddRef = addRef, .Release = release },
                .EnumInstances = enumInstances,
                .GetInstanceForCurrentProcess = noInstance,
                .GetInstanceForPath = noInstanceForPath,
                .EnumAllInstances = enumInstances,
            };
        };
        var config: Config = .{};

        const Helper = struct {
            iface: SetupHelper = .{ .vtbl = &vtbl },
            const vtbl: ISetupHelperVtbl = .{ .unknown = unknown, .ParseVersion = parseVersion, .ParseVersionRange = parseVersionRange };
        };
        var helper: Helper = .{};

        const Enumerator = struct {
            iface: EnumSetupInstances = .{ .vtbl = &vtbl },
            next: usize = 0,
            const vtbl: IEnumSetupInstancesVtbl = .{ .unknown = unknown, .Next = next, .Skip = skip, .Reset = reset, .Clone = noInstance };
        };
        var enumerator: Enumerator = .{};

        const Object = struct {
            iface: SetupInstance = .{ .vtbl = &vtbl },
            id: [:0]const u16,
            path: [:0]const u16,
            version: [:0]const u16,
            fail: @FieldType(FakeInstanceSpec, "fail"),
            const vtbl: ISetupInstanceVtbl = .{
                .unknown = unknown,
                .GetInstanceId = getId,
                .GetInstallDate = getDate,
                .GetInstallationName = noString,
                .GetInstallationPath = getPath,
                .GetInstallationVersion = getVersion,
                .GetDisplayName = noLocalizedString,
                .GetDescription = noLocalizedString,
                .ResolvePath = noResolvedPath,
            };
            fn of(ptr: *anyopaque) *Object {
                return @fieldParentPtr("iface", SetupInstance.from(ptr));
            }
        };
        var objects: [specs.len]Object = list: {
            var list: [specs.len]Object = undefined;
            for (specs, &list) |spec, *object| object.* = .{
                .id = std.unicode.utf8ToUtf16LeStringLiteral(spec.id),
                .path = std.unicode.utf8ToUtf16LeStringLiteral("C:\\VS\\" ++ spec.id),
                .version = std.unicode.utf8ToUtf16LeStringLiteral(if (spec.fail == .parse) "x" else spec.version),
                .fail = spec.fail,
            };
            break :list list;
        };

        fn queryInterface(_: *anyopaque, _: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            out.* = null;
            return E_NOINTERFACE;
        }
        fn configQueryInterface(_: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            if (!std.mem.eql(u8, std.mem.asBytes(iid), std.mem.asBytes(&IID_ISetupHelper))) {
                out.* = null;
                return E_NOINTERFACE;
            }
            out.* = helper.iface.raw();
            return S_OK;
        }
        fn addRef(_: *anyopaque) callconv(.winapi) u32 {
            return 2;
        }
        fn release(_: *anyopaque) callconv(.winapi) u32 {
            released += 1;
            return 1;
        }
        fn enumInstances(_: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
            out.* = if (enum_hr >= 0) enumerator.iface.raw() else null;
            return enum_hr;
        }
        fn noInstance(_: *anyopaque, out: *?*anyopaque) callconv(.winapi) HRESULT {
            out.* = null;
            return E_FAIL;
        }
        fn noInstanceForPath(_: *anyopaque, _: [*:0]const u16, out: *?*anyopaque) callconv(.winapi) HRESULT {
            out.* = null;
            return E_FAIL;
        }
        fn next(_: *anyopaque, _: u32, out: *?*anyopaque, fetched: ?*u32) callconv(.winapi) HRESULT {
            const index = enumerator.next;
            if (fetched) |count| count.* = if (index < objects.len) 1 else 0;
            if (comptime specs.len == 0) {
                out.* = null;
                return S_FALSE;
            }
            if (index == objects.len) {
                out.* = null;
                return S_FALSE;
            }
            enumerator.next += 1;
            out.* = objects[index].iface.raw();
            return S_OK;
        }
        fn skip(_: *anyopaque, _: u32) callconv(.winapi) HRESULT {
            return E_FAIL;
        }
        fn reset(_: *anyopaque) callconv(.winapi) HRESULT {
            return E_FAIL;
        }
        fn answer(out: *BSTR, value: [:0]const u16, failed: bool) HRESULT {
            out.* = if (failed) null else @constCast(value.ptr);
            return if (failed) E_FAIL else S_OK;
        }
        fn getId(ptr: *anyopaque, out: *BSTR) callconv(.winapi) HRESULT {
            const object = Object.of(ptr);
            return answer(out, object.id, object.fail == .id);
        }
        fn getPath(ptr: *anyopaque, out: *BSTR) callconv(.winapi) HRESULT {
            const object = Object.of(ptr);
            return answer(out, object.path, object.fail == .path);
        }
        fn getVersion(ptr: *anyopaque, out: *BSTR) callconv(.winapi) HRESULT {
            const object = Object.of(ptr);
            return answer(out, object.version, object.fail == .version);
        }
        fn getDate(ptr: *anyopaque, out: *windows.FILETIME) callconv(.winapi) HRESULT {
            if (Object.of(ptr).fail == .date) return E_FAIL;
            out.* = .{ .dwLowDateTime = 1, .dwHighDateTime = 0 };
            return S_OK;
        }
        fn noString(_: *anyopaque, out: *BSTR) callconv(.winapi) HRESULT {
            out.* = null;
            return E_FAIL;
        }
        fn noLocalizedString(_: *anyopaque, _: u32, out: *BSTR) callconv(.winapi) HRESULT {
            out.* = null;
            return E_FAIL;
        }
        fn noResolvedPath(_: *anyopaque, _: ?[*:0]const u16, out: *BSTR) callconv(.winapi) HRESULT {
            out.* = null;
            return E_FAIL;
        }
        /// `major.minor[...]`, as the real helper packs it; anything else fails.
        fn parseVersion(_: *anyopaque, text: [*:0]const u16, out: *u64) callconv(.winapi) HRESULT {
            var fields = [2]u16{ 0, 0 };
            var field: usize = 0;
            var index: usize = 0;
            while (text[index] != 0 and field < fields.len) : (index += 1) {
                const ch = text[index];
                if (ch == '.') {
                    field += 1;
                } else if (ch >= '0' and ch <= '9') {
                    fields[field] = fields[field] * 10 + @as(u16, @intCast(ch - '0'));
                } else return E_FAIL;
            }
            if (index == 0) return E_FAIL;
            out.* = version(fields[0], fields[1]);
            return S_OK;
        }
        fn parseVersionRange(_: *anyopaque, _: [*:0]const u16, _: *u64, _: *u64) callconv(.winapi) HRESULT {
            return E_FAIL;
        }

        pub fn initialize() HRESULT {
            initialized += 1;
            return init_hr;
        }
        pub fn uninitialize() void {
            uninitialized += 1;
        }
        pub fn create(out: *?*anyopaque) HRESULT {
            created += 1;
            out.* = if (create_hr >= 0) config.iface.raw() else null;
            return create_hr;
        }
        pub fn freeString(_: BSTR) void {}
        pub fn stringLen(value: BSTR) u32 {
            return @intCast(std.mem.len(value.?));
        }
        pub fn clearVariant(_: *VARIANT) void {}
    };
}

test "Setup Configuration not registered is an empty, complete list; a failed enumeration is incomplete" {
    const testing = std.testing;
    const alloc = testing.allocator;
    {
        const Com = FakeCom(S_OK, REGDB_E_CLASSNOTREG, S_OK, &.{});
        const found = try queryWith(alloc, Com);
        try testing.expect(found.complete and !found.registered);
        try testing.expectEqual(@as(usize, 0), found.instances.len);
        // The apartment the call joined is left again.
        try testing.expectEqual(@as(usize, 1), Com.uninitialized);
    }
    {
        // On the UI thread, whose single-threaded apartment stays as it is.
        const Com = FakeCom(RPC_E_CHANGED_MODE, REGDB_E_CLASSNOTREG, S_OK, &.{});
        const found = try queryWith(alloc, Com);
        try testing.expect(found.complete and !found.registered);
        try testing.expectEqual(@as(usize, 1), Com.created);
        try testing.expectEqual(@as(usize, 0), Com.uninitialized);
    }
    {
        const Com = FakeCom(S_FALSE, S_OK, E_FAIL, &.{});
        const found = try queryWith(alloc, Com);
        try testing.expect(!found.complete and found.registered);
        try testing.expectEqual(@as(usize, 0), found.instances.len);
        try testing.expectEqual(@as(usize, 1), Com.uninitialized);
        // The configuration object is released.
        try testing.expectEqual(@as(usize, 1), Com.released);
    }
    // Any other failure to create it is worth asking again: a registration
    // whose DLL cannot be loaded now too.
    inline for (.{ E_FAIL, HRESULT_MOD_NOT_FOUND, HRESULT_FILE_NOT_FOUND }) |hr| {
        const Com = FakeCom(S_OK, hr, S_OK, &.{});
        const found = try queryWith(alloc, Com);
        try testing.expect(!found.complete and found.registered);
        try testing.expectEqual(@as(usize, 1), Com.uninitialized);
    }
    {
        // COM refused the apartment: nothing is created.
        const Com = FakeCom(E_FAIL, S_OK, S_OK, &.{});
        const found = try queryWith(alloc, Com);
        try testing.expect(!found.complete);
        try testing.expectEqual(@as(usize, 0), Com.created);
        try testing.expectEqual(@as(usize, 0), Com.uninitialized);
    }
}

test "an instance Setup Configuration cannot read is left out, and the list is asked for again" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    {
        const Com = FakeCom(S_OK, S_OK, S_OK, &.{ .{ .id = "aa" }, .{ .id = "bb", .version = "18.10.3.4" }, .{ .id = "cc" } });
        const found = try queryWith(alloc, Com);
        try testing.expect(found.complete and found.registered);
        try testing.expectEqual(@as(usize, 3), found.instances.len);
        const bb = found.instances[1];
        try testing.expectEqualStrings("bb", bb.id);
        try testing.expectEqualStrings("C:\\VS\\bb", bb.path);
        try testing.expectEqualStrings("18.10.3.4", bb.version_text);
        try testing.expectEqual(version(18, 10), bb.version);
        try testing.expectEqual(@as(u64, 1), bb.install_date);
        // No catalog: the version names it.
        try testing.expectEqualStrings("18.10.3.4", bb.suffix);
        // Three instances, the enumerator, the helper and the configuration.
        try testing.expectEqual(@as(usize, 6), Com.released);
    }
    // A value a profile needs: the instance is left out, the others listed.
    inline for (.{ .id, .path, .version, .parse }) |failure| {
        const Com = FakeCom(S_OK, S_OK, S_OK, &.{ .{ .id = "aa" }, .{ .id = "bb", .fail = failure }, .{ .id = "cc" } });
        const found = try queryWith(alloc, Com);
        try testing.expect(!found.complete);
        try testing.expectEqual(@as(usize, 2), found.instances.len);
        try testing.expectEqualStrings("aa", found.instances[0].id);
        try testing.expectEqualStrings("cc", found.instances[1].id);
        try testing.expectEqual(@as(usize, 6), Com.released);
    }
    // The install date only orders: the instance stays, as the oldest.
    {
        const Com = FakeCom(S_OK, S_OK, S_OK, &.{ .{ .id = "aa" }, .{ .id = "bb", .fail = .date } });
        const found = try queryWith(alloc, Com);
        try testing.expect(!found.complete);
        try testing.expectEqual(@as(usize, 2), found.instances.len);
        try testing.expectEqual(@as(u64, 0), found.instances[1].install_date);
    }
}

test "the machine's Visual Studio instances, as Setup Configuration lists them" {
    // Only enumerates: nothing is started. GitHub's x64 runner has Visual
    // Studio; a machine without it skips.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const found = try ComSource.query(.{}, arena.allocator());
    // Skips where Setup Configuration is absent or does not answer in full
    // (a registration whose DLL is gone, an instance it cannot read). Only
    // the version is checked: an instance's id, folder and name suffix are
    // what the profiles check before they keep it.
    if (!found.registered or !found.complete) return error.SkipZigTest;
    for (found.instances) |instance| {
        // ParseVersion's packing, against the text it parsed.
        var parts = std.mem.splitScalar(u8, instance.version_text, '.');
        const major = try std.fmt.parseInt(u16, parts.next().?, 10);
        const minor = try std.fmt.parseInt(u16, parts.next() orelse "0", 10);
        try std.testing.expectEqual(version(major, minor), instance.version & 0xFFFF_FFFF_0000_0000);
        try std.testing.expect(major >= 15);
    }
}
