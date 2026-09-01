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
const RegSetValueExW = sys.RegSetValueExW;
const RegCloseKey = sys.RegCloseKey;

// Only this module deletes registry keys, so this one stays local.
extern "advapi32" fn RegDeleteKeyExW(
    hKey: HKEY,
    lpSubKey: LPCWSTR,
    samDesired: REGSAM,
    Reserved: DWORD,
) callconv(.winapi) i32;

extern "shell32" fn SHChangeNotify(
    wEventId: i32,
    uFlags: u32,
    dwItem1: ?*const anyopaque,
    dwItem2: ?*const anyopaque,
) callconv(.winapi) void;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(consts.HKEY_CURRENT_USER);
const KEY_WRITE: REGSAM = 0x20006;
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
    failure: ?RegistryFailure = null,
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
pub fn commandValueAlloc(alloc: Allocator, exe_path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        alloc,
        "\"{s}\" --working-directory=\"%V\\.\"",
        .{exe_path},
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

    inline for (verb_key_paths, command_key_paths) |verb_path, command_path| {
        const verb = try writeVerbKey(alloc, verb_path, exe_path);
        if (verb.failure) |failure| {
            rollbackCreatedKeys(alloc, &created);
            return .{ .failure = failure };
        }

        const command = try writeDefaultValue(alloc, command_path, command_value);
        if (command.failure) |failure| {
            rollbackCreatedKeys(alloc, &created);
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
        KEY_WRITE,
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

    const display_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, display_name);
    defer alloc.free(display_wide);
    const display_status = writeRegSz(key, null, display_wide);
    if (display_status != ERROR_SUCCESS) return .{ .created = created, .failure = .{
        .operation = .set_value,
        .key_path = key_path,
        .status = display_status,
    } };

    const exe_path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, exe_path);
    defer alloc.free(exe_path_wide);
    const icon_status = writeRegSz(
        key,
        std.unicode.utf8ToUtf16LeStringLiteral("Icon"),
        exe_path_wide,
    );
    if (icon_status != ERROR_SUCCESS) return .{ .created = created, .failure = .{
        .operation = .set_value,
        .key_path = key_path,
        .status = icon_status,
    } };

    return .{ .created = created };
}

fn writeDefaultValue(
    alloc: Allocator,
    key_path: []const u8,
    value: []const u8,
) !WriteResult {
    const key_path_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, key_path);
    defer alloc.free(key_path_wide);

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

    const value_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value);
    defer alloc.free(value_wide);
    const set_status = writeRegSz(key, null, value_wide);
    if (set_status != ERROR_SUCCESS) return .{ .created = created, .failure = .{
        .operation = .set_value,
        .key_path = key_path,
        .status = set_status,
    } };

    return .{ .created = created };
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
}

test "shell-menu command quotes an executable path containing spaces" {
    const testing = std.testing;
    const value = try commandValueAlloc(
        testing.allocator,
        "C:\\Program Files\\noctty\\noctty.exe",
    );
    defer testing.allocator.free(value);

    try testing.expectEqualStrings(
        "\"C:\\Program Files\\noctty\\noctty.exe\" --working-directory=\"%V\\.\"",
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
    const expanded = try std.mem.replaceOwned(u8, alloc, command_value, "%V", target);
    defer alloc.free(expanded);

    const expanded_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, expanded);
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

test "shell-menu command survives Windows argv parsing for folders and drive roots" {
    const testing = std.testing;
    const exe = "C:\\Program Files\\noctty\\noctty.exe";
    const value = try commandValueAlloc(testing.allocator, exe);
    defer testing.allocator.free(value);

    // A drive root is the case a bare `"%V"` gets wrong: Explorer expands it
    // with a trailing backslash, which would escape the closing quote.
    {
        const argv = try expandAndParseForTest(testing.allocator, value, "C:\\");
        defer freeParsedForTest(testing.allocator, argv);
        try testing.expectEqual(@as(usize, 2), argv.len);
        try testing.expectEqualStrings(exe, argv[0]);
        try testing.expectEqualStrings("--working-directory=C:\\\\.", argv[1]);
    }

    // A normal folder, including one whose name contains a space.
    {
        const argv = try expandAndParseForTest(
            testing.allocator,
            value,
            "D:\\My Projects\\noctty",
        );
        defer freeParsedForTest(testing.allocator, argv);
        try testing.expectEqual(@as(usize, 2), argv.len);
        try testing.expectEqualStrings(exe, argv[0]);
        try testing.expectEqualStrings("--working-directory=D:\\My Projects\\noctty\\.", argv[1]);
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
        try testing.expectEqual(@as(usize, 2), argv.len);
        try testing.expectEqualStrings(exe, argv[0]);
        try testing.expectEqualStrings(
            "--working-directory=E:\\\u{9805}\u{76EE} \u{1F680}\\\u{5F00}\u{53D1}\\.",
            argv[1],
        );
    }
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
