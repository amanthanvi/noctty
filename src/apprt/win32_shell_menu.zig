//! Classic Explorer context-menu registration for noctty.
//!
//! The CLI actions use HKCU only. Installer registration is owned by Inno
//! Setup so its registry root follows the selected install scope.

const std = @import("std");
const win32_types = @import("win32_types.zig");
const consts = @import("win32/consts.zig");
const sys = @import("win32/sys.zig");

const Allocator = std.mem.Allocator;
const DWORD = win32_types.DWORD;
const LPCWSTR = win32_types.LPCWSTR;
const HKEY = sys.HKEY;
const REGSAM = u32;

// Aliased from the shared Win32 surface rather than re-declared, so this
// module cannot drift from src/apprt/win32/sys.zig.
const RegCreateKeyExW = sys.RegCreateKeyExW;
const RegOpenKeyExW = sys.RegOpenKeyExW;
const RegSetValueExW = sys.RegSetValueExW;
const RegCloseKey = sys.RegCloseKey;

// Only this module deletes registry keys, so this one stays local.
extern "advapi32" fn RegDeleteKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    samDesired: REGSAM,
    Reserved: DWORD,
) callconv(.winapi) i32;

extern "advapi32" fn RegDeleteValueW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
) callconv(.winapi) i32;

extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
    lpReserved: ?*DWORD,
    lpType: ?*DWORD,
    lpData: ?*u8,
    lpcbData: ?*DWORD,
) callconv(.winapi) i32;

extern "shell32" fn SHChangeNotify(
    wEventId: i32,
    uFlags: u32,
    dwItem1: ?*const anyopaque,
    dwItem2: ?*const anyopaque,
) callconv(.winapi) void;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(consts.HKEY_CURRENT_USER);
const KEY_WRITE: REGSAM = 0x20006;
const KEY_READ: REGSAM = 0x20019;
const REG_OPTION_NON_VOLATILE: DWORD = 0;
const REG_SZ: DWORD = 1;
const ERROR_SUCCESS: i32 = consts.ERROR_SUCCESS;
const ERROR_FILE_NOT_FOUND: i32 = consts.ERROR_FILE_NOT_FOUND;
const ERROR_PATH_NOT_FOUND: i32 = 3;
const REG_CREATED_NEW_KEY: DWORD = 1;
const SHCNE_ASSOCCHANGED: i32 = 0x08000000;
const SHCNF_IDLIST: u32 = 0;

pub const display_name = "Open noctty here";

pub const verb_key_paths = [_][]const u8{
    "Software\\Classes\\Directory\\shell\\noctty",
    "Software\\Classes\\Directory\\Background\\shell\\noctty",
    "Software\\Classes\\Drive\\shell\\noctty",
};

pub const command_key_paths = [_][]const u8{
    "Software\\Classes\\Directory\\shell\\noctty\\command",
    "Software\\Classes\\Directory\\Background\\shell\\noctty\\command",
    "Software\\Classes\\Drive\\shell\\noctty\\command",
};

pub const register_key_paths = [_][]const u8{
    verb_key_paths[0],
    command_key_paths[0],
    verb_key_paths[1],
    command_key_paths[1],
    verb_key_paths[2],
    command_key_paths[2],
};

/// Delete child keys before their parents. This exact list is deliberately
/// non-recursive so unexpected subkeys are preserved and reported as errors.
pub const unregister_key_paths = [_][]const u8{
    command_key_paths[0],
    verb_key_paths[0],
    command_key_paths[1],
    verb_key_paths[1],
    command_key_paths[2],
    verb_key_paths[2],
};

pub const RegistryOperation = enum {
    create_key,
    query_value,
    set_value,
};

pub const RegistryFailure = struct {
    operation: RegistryOperation,
    key_path: []const u8,
    status: i32,
};

pub const RegisterResult = union(enum) {
    success,
    failure: RegistryFailure,
};

pub const DeleteResult = union(enum) {
    removed,
    absent,
    failed: i32,
};

const WriteResult = struct {
    created: bool,
    mutated: bool = false,
    failure: ?RegistryFailure = null,
};

const ValueName = enum { default, icon };

const ValueSpec = struct {
    key_index: usize,
    name: ValueName,
};

const value_specs = [_]ValueSpec{
    .{ .key_index = 0, .name = .default },
    .{ .key_index = 0, .name = .icon },
    .{ .key_index = 1, .name = .default },
    .{ .key_index = 2, .name = .default },
    .{ .key_index = 2, .name = .icon },
    .{ .key_index = 3, .name = .default },
    .{ .key_index = 4, .name = .default },
    .{ .key_index = 4, .name = .icon },
    .{ .key_index = 5, .name = .default },
};

const ValueSnapshot = struct {
    value_type: DWORD = REG_SZ,
    data: ?[]u8 = null,

    fn deinit(self: *ValueSnapshot, alloc: Allocator) void {
        if (self.data) |data| alloc.free(data);
        self.* = .{};
    }
};

const SnapshotResult = union(enum) {
    snapshot: ValueSnapshot,
    failure: RegistryFailure,
};

/// Resolve the GUI executable next to the current launcher. This intentionally
/// avoids registering `noctty.com` when the action was reached through PATH.
pub fn executablePathAlloc(alloc: Allocator, self_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(self_path) orelse return error.FileNotFound;
    return try std.fs.path.join(alloc, &.{ dir, "noctty.exe" });
}

/// Build the `command` default value.
///
/// The trailing `\.` is load-bearing. Explorer expands `%V` to a drive root
/// as `C:\`, so a bare `"%V"` would end the quoted argument with a backslash
/// immediately before the closing quote — `CommandLineToArgvW` reads that as
/// an escaped quote and hands us `--working-directory=C:"`. Appending `\.`
/// keeps the last character before the quote non-backslash for every target,
/// and `C:\\.` / `C:\dir\.` both resolve to the intended directory.
/// `--single-instance=false` keeps the selected path in this new process rather
/// than sending it through the IPC working-directory allowlist. That preserves
/// an intentional Explorer launch from a UNC folder without weakening IPC.
pub fn commandValueAlloc(alloc: Allocator, exe_path: []const u8) ![]u8 {
    // The Shell command template treats `%%` as one literal percent. Escape
    // the executable path before adding our one intentional `%V` target.
    const escaped_exe_path = try std.mem.replaceOwned(u8, alloc, exe_path, "%", "%%");
    defer alloc.free(escaped_exe_path);
    return try std.fmt.allocPrint(
        alloc,
        "\"{s}\" --single-instance=false --working-directory=\"%V\\.\"",
        .{escaped_exe_path},
    );
}

/// Register the three per-user classic Explorer verbs.
pub fn register(alloc: Allocator, exe_path: []const u8) !RegisterResult {
    const command_value = try commandValueAlloc(alloc, exe_path);
    defer alloc.free(command_value);

    var created = [_]bool{false} ** register_key_paths.len;
    errdefer rollbackCreatedKeys(alloc, &created);
    // Prove all six keys are writable before overwriting any existing values.
    // Newly created empty keys are tracked and rolled back if preflight or a
    // later value write fails.
    for (register_key_paths, 0..) |path, index| {
        const preflight = try ensureWritableKey(alloc, path);
        created[index] = preflight.created;
        if (preflight.failure) |failure| {
            rollbackCreatedKeys(alloc, &created);
            return .{ .failure = failure };
        }
    }

    var snapshots: [value_specs.len]ValueSnapshot = undefined;
    var snapshot_count: usize = 0;
    defer for (snapshots[0..snapshot_count]) |*snapshot| snapshot.deinit(alloc);
    for (value_specs) |spec| {
        const captured = try captureValue(alloc, spec);
        switch (captured) {
            .snapshot => |snapshot| {
                snapshots[snapshot_count] = snapshot;
                snapshot_count += 1;
            },
            .failure => |failure| {
                rollbackCreatedKeys(alloc, &created);
                return .{ .failure = failure };
            },
        }
    }

    var mutated = false;
    errdefer {
        rollbackValues(alloc, &snapshots, &created);
        if (mutated) notifyExplorerAssociationsChanged();
    }
    inline for (verb_key_paths, command_key_paths) |verb_path, command_path| {
        const verb = try writeVerbKey(alloc, verb_path, exe_path);
        mutated = mutated or verb.mutated;
        if (verb.failure) |failure| {
            rollbackValues(alloc, &snapshots, &created);
            rollbackCreatedKeys(alloc, &created);
            if (mutated) notifyExplorerAssociationsChanged();
            return .{ .failure = failure };
        }

        const command = try writeDefaultValue(alloc, command_path, command_value);
        mutated = mutated or command.mutated;
        if (command.failure) |failure| {
            rollbackValues(alloc, &snapshots, &created);
            rollbackCreatedKeys(alloc, &created);
            if (mutated) notifyExplorerAssociationsChanged();
            return .{ .failure = failure };
        }
    }

    notifyExplorerAssociationsChanged();
    return .success;
}

fn ensureWritableKey(alloc: Allocator, key_path: []const u8) !WriteResult {
    const key_path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_path);
    defer alloc.free(key_path_wide);

    var key: HKEY = undefined;
    var disposition: DWORD = 0;
    const status = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        key_path_wide,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_READ | KEY_WRITE,
        null,
        &key,
        &disposition,
    );
    if (status != ERROR_SUCCESS) return .{ .created = false, .failure = .{
        .operation = .create_key,
        .key_path = key_path,
        .status = status,
    } };
    defer _ = RegCloseKey(key);
    return .{ .created = disposition == REG_CREATED_NEW_KEY };
}

fn valueNameWide(name: ValueName) ?LPCWSTR {
    return switch (name) {
        .default => null,
        .icon => std.unicode.utf8ToUtf16LeStringLiteral("Icon"),
    };
}

fn captureValue(alloc: Allocator, spec: ValueSpec) !SnapshotResult {
    const key_path = register_key_paths[spec.key_index];
    const key_path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_path);
    defer alloc.free(key_path_wide);
    var key: HKEY = undefined;
    const open_status = RegOpenKeyExW(HKEY_CURRENT_USER, key_path_wide, 0, KEY_READ, &key);
    if (open_status != ERROR_SUCCESS) return .{ .failure = .{
        .operation = .query_value,
        .key_path = key_path,
        .status = open_status,
    } };
    defer _ = RegCloseKey(key);

    var value_type: DWORD = 0;
    var size: DWORD = 0;
    const query_status = RegQueryValueExW(
        key,
        valueNameWide(spec.name),
        null,
        &value_type,
        null,
        &size,
    );
    if (query_status == ERROR_FILE_NOT_FOUND) return .{ .snapshot = .{} };
    if (query_status != ERROR_SUCCESS) return .{ .failure = .{
        .operation = .query_value,
        .key_path = key_path,
        .status = query_status,
    } };

    const data = try alloc.alloc(u8, size);
    errdefer alloc.free(data);
    var read_size = size;
    const read_status = RegQueryValueExW(
        key,
        valueNameWide(spec.name),
        null,
        &value_type,
        if (data.len == 0) null else &data[0],
        &read_size,
    );
    if (read_status != ERROR_SUCCESS) return .{ .failure = .{
        .operation = .query_value,
        .key_path = key_path,
        .status = read_status,
    } };
    return .{ .snapshot = .{ .value_type = value_type, .data = data } };
}

fn rollbackValues(
    alloc: Allocator,
    snapshots: *const [value_specs.len]ValueSnapshot,
    created: *const [register_key_paths.len]bool,
) void {
    var index = value_specs.len;
    while (index > 0) {
        index -= 1;
        const spec = value_specs[index];
        if (created[spec.key_index]) continue;
        restoreValueBestEffort(alloc, spec, snapshots[index]);
    }
}

fn restoreValueBestEffort(alloc: Allocator, spec: ValueSpec, snapshot: ValueSnapshot) void {
    const key_path = register_key_paths[spec.key_index];
    const key_path_wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, key_path) catch return;
    defer alloc.free(key_path_wide);
    var key: HKEY = undefined;
    const open_status = RegOpenKeyExW(HKEY_CURRENT_USER, key_path_wide, 0, KEY_WRITE, &key);
    if (open_status != ERROR_SUCCESS) return;
    defer _ = RegCloseKey(key);

    const status = if (snapshot.data) |data|
        RegSetValueExW(
            key,
            valueNameWide(spec.name),
            0,
            snapshot.value_type,
            data.ptr,
            @intCast(data.len),
        )
    else
        RegDeleteValueW(key, valueNameWide(spec.name));
    if (status != ERROR_SUCCESS and status != ERROR_FILE_NOT_FOUND) {
        std.log.scoped(.win32_shell_menu).warn(
            "shell-menu value rollback failed path={s} status={d}",
            .{ key_path, status },
        );
    }
}

/// Remove only the six keys owned by `register`, in leaf-first order.
/// Missing keys are successful no-ops.
pub fn unregister(alloc: Allocator) ![unregister_key_paths.len]DeleteResult {
    var results: [unregister_key_paths.len]DeleteResult = undefined;
    var removed_any = false;
    for (unregister_key_paths, 0..) |path, i| {
        const path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        defer alloc.free(path_wide);

        results[i] = switch (RegDeleteKeyExW(
            HKEY_CURRENT_USER,
            path_wide,
            0,
            0,
        )) {
            ERROR_SUCCESS => removed: {
                removed_any = true;
                break :removed .removed;
            },
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => .absent,
            else => |status| .{ .failed = status },
        };
    }
    if (removed_any) notifyExplorerAssociationsChanged();
    return results;
}

fn notifyExplorerAssociationsChanged() void {
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, null, null);
}

fn writeVerbKey(
    alloc: Allocator,
    key_path: []const u8,
    exe_path: []const u8,
) !WriteResult {
    const key_path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_path);
    defer alloc.free(key_path_wide);
    const display_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, display_name);
    defer alloc.free(display_wide);
    const exe_path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path);
    defer alloc.free(exe_path_wide);

    var key: HKEY = undefined;
    var disposition: DWORD = 0;
    const create_status = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        key_path_wide,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE,
        null,
        &key,
        &disposition,
    );
    if (create_status != ERROR_SUCCESS) return .{ .created = false, .failure = .{
        .operation = .create_key,
        .key_path = key_path,
        .status = create_status,
    } };
    const created = disposition == REG_CREATED_NEW_KEY;
    errdefer if (created) deleteKeyBestEffort(alloc, key_path);
    defer _ = RegCloseKey(key);

    const display_status = writeRegSz(key, null, display_wide);
    if (display_status != ERROR_SUCCESS) return .{ .created = created, .failure = .{
        .operation = .set_value,
        .key_path = key_path,
        .status = display_status,
    } };

    const icon_status = writeRegSz(
        key,
        std.unicode.utf8ToUtf16LeStringLiteral("Icon"),
        exe_path_wide,
    );
    if (icon_status != ERROR_SUCCESS) return .{ .created = created, .mutated = true, .failure = .{
        .operation = .set_value,
        .key_path = key_path,
        .status = icon_status,
    } };

    return .{ .created = created, .mutated = true };
}

fn writeDefaultValue(
    alloc: Allocator,
    key_path: []const u8,
    value: []const u8,
) !WriteResult {
    const key_path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_path);
    defer alloc.free(key_path_wide);
    const value_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value);
    defer alloc.free(value_wide);

    var key: HKEY = undefined;
    var disposition: DWORD = 0;
    const create_status = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        key_path_wide,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE,
        null,
        &key,
        &disposition,
    );
    if (create_status != ERROR_SUCCESS) return .{ .created = false, .failure = .{
        .operation = .create_key,
        .key_path = key_path,
        .status = create_status,
    } };
    const created = disposition == REG_CREATED_NEW_KEY;
    errdefer if (created) deleteKeyBestEffort(alloc, key_path);
    defer _ = RegCloseKey(key);

    const set_status = writeRegSz(key, null, value_wide);
    if (set_status != ERROR_SUCCESS) return .{ .created = created, .failure = .{
        .operation = .set_value,
        .key_path = key_path,
        .status = set_status,
    } };

    return .{ .created = created, .mutated = true };
}

fn previousCreatedPath(created: []const bool, before: *usize) ?[]const u8 {
    while (before.* > 0) {
        before.* -= 1;
        if (created[before.*]) return register_key_paths[before.*];
    }
    return null;
}

fn rollbackCreatedKeys(alloc: Allocator, created: []const bool) void {
    var before = created.len;
    while (previousCreatedPath(created, &before)) |path| {
        deleteKeyBestEffort(alloc, path);
    }
}

fn deleteKeyBestEffort(alloc: Allocator, path: []const u8) void {
    const path_wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch |err| {
        std.log.scoped(.win32_shell_menu).warn(
            "shell-menu registration rollback path allocation failed path={s} err={}",
            .{ path, err },
        );
        return;
    };
    defer alloc.free(path_wide);
    const status = RegDeleteKeyExW(HKEY_CURRENT_USER, path_wide, 0, 0);
    if (status != ERROR_SUCCESS and
        status != ERROR_FILE_NOT_FOUND and
        status != ERROR_PATH_NOT_FOUND)
    {
        std.log.scoped(.win32_shell_menu).warn(
            "shell-menu registration rollback failed path={s} status={d}",
            .{ path, status },
        );
    }
}

fn writeRegSz(hkey: HKEY, value_name: ?LPCWSTR, value: [:0]const u16) i32 {
    return RegSetValueExW(
        hkey,
        value_name,
        0,
        REG_SZ,
        @ptrCast(value.ptr),
        @intCast((value.len + 1) * @sizeOf(u16)),
    );
}

test "shell-menu key paths cover folders backgrounds and drives" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 3), verb_key_paths.len);
    try testing.expectEqualStrings(
        "Software\\Classes\\Directory\\shell\\noctty",
        verb_key_paths[0],
    );
    try testing.expectEqualStrings(
        "Software\\Classes\\Directory\\Background\\shell\\noctty",
        verb_key_paths[1],
    );
    try testing.expectEqualStrings(
        "Software\\Classes\\Drive\\shell\\noctty",
        verb_key_paths[2],
    );
    try testing.expectEqual(@as(usize, 9), value_specs.len);
    var values_per_key = [_]usize{0} ** register_key_paths.len;
    for (value_specs) |spec| values_per_key[spec.key_index] += 1;
    try testing.expectEqualSlices(usize, &.{ 2, 1, 2, 1, 2, 1 }, &values_per_key);
}

test "shell-menu command quotes an executable path containing spaces" {
    const testing = std.testing;
    const value = try commandValueAlloc(
        testing.allocator,
        "C:\\Program Files\\noctty\\noctty.exe",
    );
    defer testing.allocator.free(value);

    try testing.expectEqualStrings(
        "\"C:\\Program Files\\noctty\\noctty.exe\" --single-instance=false --working-directory=\"%V\\.\"",
        value,
    );
}

/// Expand Explorer's `%V` and parse the result the way Windows does, so the
/// tests below assert what noctty actually receives in `argv`.
fn expandAndParseForTest(
    alloc: Allocator,
    command_value: []const u8,
    target: []const u8,
) ![]const []const u8 {
    var expanded: std.Io.Writer.Allocating = .init(alloc);
    defer expanded.deinit();
    var index: usize = 0;
    while (index < command_value.len) {
        if (command_value[index] == '%' and index + 1 < command_value.len) {
            switch (command_value[index + 1]) {
                '%' => {
                    try expanded.writer.writeByte('%');
                    index += 2;
                    continue;
                },
                'V', 'v' => {
                    try expanded.writer.writeAll(target);
                    index += 2;
                    continue;
                },
                else => {},
            }
        }
        try expanded.writer.writeByte(command_value[index]);
        index += 1;
    }

    const expanded_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, expanded.written());
    defer alloc.free(expanded_w);

    var iter = try std.process.ArgIteratorWindows.init(alloc, expanded_w);
    defer iter.deinit();

    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |item| alloc.free(item);
        argv.deinit(alloc);
    }
    while (iter.next()) |arg| try argv.append(alloc, try alloc.dupe(u8, arg));
    return try argv.toOwnedSlice(alloc);
}

fn freeParsedForTest(alloc: Allocator, argv: []const []const u8) void {
    for (argv) |item| alloc.free(item);
    alloc.free(argv);
}

test "shell-menu command survives Windows argv parsing for local and UNC folders" {
    const testing = std.testing;
    const exe = "C:\\Program Files\\noctty\\noctty.exe";
    const value = try commandValueAlloc(testing.allocator, exe);
    defer testing.allocator.free(value);

    // A drive root is the case a bare `"%V"` gets wrong: Explorer expands it
    // with a trailing backslash, which would escape the closing quote.
    {
        const argv = try expandAndParseForTest(testing.allocator, value, "C:\\");
        defer freeParsedForTest(testing.allocator, argv);
        try testing.expectEqual(@as(usize, 3), argv.len);
        try testing.expectEqualStrings(exe, argv[0]);
        try testing.expectEqualStrings("--single-instance=false", argv[1]);
        try testing.expectEqualStrings("--working-directory=C:\\\\.", argv[2]);
    }

    // A normal folder, including one whose name contains a space.
    {
        const argv = try expandAndParseForTest(
            testing.allocator,
            value,
            "D:\\My Projects\\noctty",
        );
        defer freeParsedForTest(testing.allocator, argv);
        try testing.expectEqual(@as(usize, 3), argv.len);
        try testing.expectEqualStrings(exe, argv[0]);
        try testing.expectEqualStrings("--single-instance=false", argv[1]);
        try testing.expectEqualStrings("--working-directory=D:\\My Projects\\noctty\\.", argv[2]);
    }

    // Non-ASCII folder names survive the UTF-8 -> UTF-16 -> argv round trip.
    // `"` is illegal in an NTFS name, so there is no quote to break out with;
    // these are the realistic hostile-looking names.
    {
        const argv = try expandAndParseForTest(
            testing.allocator,
            value,
            "E:\\\u{9805}\u{76EE} \u{1F680}\\\u{5F00}\u{53D1}",
        );
        defer freeParsedForTest(testing.allocator, argv);
        try testing.expectEqual(@as(usize, 3), argv.len);
        try testing.expectEqualStrings(exe, argv[0]);
        try testing.expectEqualStrings("--single-instance=false", argv[1]);
        try testing.expectEqualStrings(
            "--working-directory=E:\\\u{9805}\u{76EE} \u{1F680}\\\u{5F00}\u{53D1}\\.",
            argv[2],
        );
    }

    // UNC targets stay in this new process instead of crossing the IPC
    // working-directory boundary, which deliberately rejects UNC syntax.
    {
        const argv = try expandAndParseForTest(
            testing.allocator,
            value,
            "\\\\server\\share\\project",
        );
        defer freeParsedForTest(testing.allocator, argv);
        try testing.expectEqual(@as(usize, 3), argv.len);
        try testing.expectEqualStrings(exe, argv[0]);
        try testing.expectEqualStrings("--single-instance=false", argv[1]);
        try testing.expectEqualStrings(
            "--working-directory=\\\\server\\share\\project\\.",
            argv[2],
        );
    }
}

test "shell-menu command preserves percent placeholders in the executable path" {
    const testing = std.testing;
    const exe = "C:\\Apps\\100%Valid\\noctty.exe";
    const value = try commandValueAlloc(testing.allocator, exe);
    defer testing.allocator.free(value);
    try testing.expectEqualStrings(
        "\"C:\\Apps\\100%%Valid\\noctty.exe\" --single-instance=false --working-directory=\"%V\\.\"",
        value,
    );

    const argv = try expandAndParseForTest(testing.allocator, value, "D:\\Work");
    defer freeParsedForTest(testing.allocator, argv);
    try testing.expectEqual(@as(usize, 3), argv.len);
    try testing.expectEqualStrings(exe, argv[0]);
    try testing.expectEqualStrings("--single-instance=false", argv[1]);
    try testing.expectEqualStrings("--working-directory=D:\\Work\\.", argv[2]);
}

test "shell-menu display name is stable" {
    try std.testing.expectEqualStrings("Open noctty here", display_name);
}

test "shell-menu register key list is exact" {
    const testing = std.testing;
    const expected = [_][]const u8{
        "Software\\Classes\\Directory\\shell\\noctty",
        "Software\\Classes\\Directory\\shell\\noctty\\command",
        "Software\\Classes\\Directory\\Background\\shell\\noctty",
        "Software\\Classes\\Directory\\Background\\shell\\noctty\\command",
        "Software\\Classes\\Drive\\shell\\noctty",
        "Software\\Classes\\Drive\\shell\\noctty\\command",
    };
    try testing.expectEqual(expected.len, register_key_paths.len);
    for (expected, register_key_paths) |want, actual| {
        try testing.expectEqualStrings(want, actual);
    }
}

test "shell-menu unregister key list is exact and leaf first" {
    const testing = std.testing;
    const expected = [_][]const u8{
        "Software\\Classes\\Directory\\shell\\noctty\\command",
        "Software\\Classes\\Directory\\shell\\noctty",
        "Software\\Classes\\Directory\\Background\\shell\\noctty\\command",
        "Software\\Classes\\Directory\\Background\\shell\\noctty",
        "Software\\Classes\\Drive\\shell\\noctty\\command",
        "Software\\Classes\\Drive\\shell\\noctty",
    };
    try testing.expectEqual(expected.len, unregister_key_paths.len);
    for (expected, unregister_key_paths) |want, actual| {
        try testing.expectEqualStrings(want, actual);
    }
}

test "shell-menu registration rollback visits only newly created keys leaf first" {
    const testing = std.testing;
    const created = [_]bool{ true, true, false, true, false, false };
    const expected = [_][]const u8{
        command_key_paths[1],
        command_key_paths[0],
        verb_key_paths[0],
    };

    var before = created.len;
    for (expected) |path| {
        try testing.expectEqualStrings(path, previousCreatedPath(&created, &before).?);
    }
    try testing.expect(previousCreatedPath(&created, &before) == null);
}

test "shell-menu executable path targets the GUI binary" {
    const testing = std.testing;
    const path = try executablePathAlloc(
        testing.allocator,
        "C:\\Tools\\noctty\\noctty.com",
    );
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("C:\\Tools\\noctty\\noctty.exe", path);
}
