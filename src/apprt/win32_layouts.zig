//! Pure helpers for Windows named layouts.
//!
//! Layout documents use the existing `win32_session_state.SessionState` JSON
//! schema and live below `%LOCALAPPDATA%\noctty\layouts`. The saved-name
//! enumerator and launch-argv builder are the integration point for the future
//! C12 jump-list work; this module deliberately contains no jump-list UI.

const std = @import("std");
const session_persistence = @import("win32_session_persistence.zig");
const session_state = @import("win32_session_state.zig");

const Allocator = std.mem.Allocator;

pub const max_name_bytes: usize = 64;
pub const max_palette_entries: usize = 64;

pub const NameError = error{
    EmptyName,
    NameTooLong,
    InvalidCharacter,
    LeadingOrTrailingSpaceOrDot,
    ReservedDeviceName,
};

/// Validate a layout name before it reaches the filesystem.
pub fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > max_name_bytes) return error.NameTooLong;
    if (name[0] == ' ' or name[0] == '.' or
        name[name.len - 1] == ' ' or name[name.len - 1] == '.')
    {
        return error.LeadingOrTrailingSpaceOrDot;
    }

    for (name) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', ' ', '.', '_', '-' => {},
        else => return error.InvalidCharacter,
    };

    const extension_index = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const device_stem = std.mem.trimRight(u8, name[0..extension_index], " .");
    if (isReservedDeviceName(device_stem)) return error.ReservedDeviceName;
}

fn isReservedDeviceName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "CON") or
        std.ascii.eqlIgnoreCase(name, "PRN") or
        std.ascii.eqlIgnoreCase(name, "AUX") or
        std.ascii.eqlIgnoreCase(name, "NUL"))
    {
        return true;
    }
    // Current Windows naming rules reserve COM0-COM9 and LPT0-LPT9.
    if (name.len != 4 or name[3] < '0' or name[3] > '9') return false;
    return std.ascii.eqlIgnoreCase(name[0..3], "COM") or
        std.ascii.eqlIgnoreCase(name[0..3], "LPT");
}

/// Compose `layouts\<name>.json` after validating the name.
pub fn relativePathAlloc(alloc: Allocator, name: []const u8) (NameError || Allocator.Error)![]u8 {
    try validateName(name);
    const file_name = try std.fmt.allocPrint(alloc, "{s}.json", .{name});
    defer alloc.free(file_name);
    return try std.fs.path.join(alloc, &.{ "layouts", file_name });
}

/// Return at most `limit` valid layout names from an absolute layouts
/// directory. Results and every name are caller-owned and sorted by raw UTF-8
/// bytes. Missing directories produce an empty result. Selection stays
/// deterministic under the cap by retaining the lexicographically first names.
///
/// This is the saved-name enumeration hook for C12 jump-list integration.
pub fn listNamesAlloc(
    alloc: Allocator,
    absolute_directory: []const u8,
    limit: usize,
) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    if (limit == 0) return try names.toOwnedSlice(alloc);

    var directory = std.fs.openDirAbsolute(absolute_directory, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try names.toOwnedSlice(alloc),
        else => return err,
    };
    defer directory.close();

    var iterator = directory.iterate();
    entries: while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        // Match only the exact extension `relativePathAlloc` writes, so every
        // enumerated name maps back to a launchable path even on a
        // case-sensitive directory.
        const extension = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, extension, ".json")) continue;
        const stem = entry.name[0 .. entry.name.len - extension.len];
        validateName(stem) catch continue;

        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, stem)) continue :entries;
        }

        if (names.items.len < limit) {
            const owned_name = try alloc.dupe(u8, stem);
            names.append(alloc, owned_name) catch |err| {
                alloc.free(owned_name);
                return err;
            };
            continue;
        }

        var greatest_index: usize = 0;
        for (names.items[1..], 1..) |existing, index| {
            if (std.mem.order(u8, names.items[greatest_index], existing) == .lt) {
                greatest_index = index;
            }
        }
        if (std.mem.order(u8, stem, names.items[greatest_index]) != .lt) continue;

        const replacement = try alloc.dupe(u8, stem);
        alloc.free(names.items[greatest_index]);
        names.items[greatest_index] = replacement;
    }

    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
    return try names.toOwnedSlice(alloc);
}

/// Build the argv consumed by a named-layout jump-list entry:
/// `{ "+new-window", "--launch-layout=<name>" }`.
/// The caller owns each sentinel string and the returned outer slice.
pub fn launchArgvAlloc(
    alloc: Allocator,
    name: []const u8,
) (NameError || Allocator.Error)![][:0]u8 {
    try validateName(name);
    const argv = try alloc.alloc([:0]u8, 2);
    errdefer alloc.free(argv);
    argv[0] = try alloc.dupeZ(u8, "+new-window");
    errdefer alloc.free(argv[0]);
    argv[1] = try std.fmt.allocPrintSentinel(alloc, "--launch-layout={s}", .{name}, 0);
    return argv;
}

fn freeNames(alloc: Allocator, names: [][]u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

fn freeArgv(alloc: Allocator, argv: [][:0]u8) void {
    for (argv) |arg| alloc.free(arg);
    alloc.free(argv);
}

test "named layout name validation rejects unsafe Windows paths and devices" {
    try validateName("Project 1.dev_x-y");

    try std.testing.expectError(error.EmptyName, validateName(""));
    const edge_invalid = [_][]const u8{
        ".",
        "..",
        "../demo",
        ".hidden",
        "demo.",
        " demo",
        "demo ",
    };
    for (edge_invalid) |name| try std.testing.expectError(
        error.LeadingOrTrailingSpaceOrDot,
        validateName(name),
    );

    const character_invalid = [_][]const u8{
        "demo/other",
        "demo\\other",
        "C:demo",
        "bad!name",
    };
    for (character_invalid) |name| try std.testing.expectError(
        error.InvalidCharacter,
        validateName(name),
    );

    const reserved = [_][]const u8{
        "CON",
        "con.txt",
        "PRN.backup",
        "aux",
        "NUL.data",
        "COM0",
        "COM1",
        "com9.log",
        "LPT0",
        "LPT1",
        "lpt9.txt",
    };
    for (reserved) |name| try std.testing.expectError(
        error.ReservedDeviceName,
        validateName(name),
    );

    var overlong: [max_name_bytes + 1]u8 = undefined;
    @memset(&overlong, 'a');
    try std.testing.expectError(error.NameTooLong, validateName(&overlong));

    const relative = try relativePathAlloc(std.testing.allocator, "demo");
    defer std.testing.allocator.free(relative);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "layouts", "demo.json" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, relative);
}

test "named layout schema save load round-trip preserves approved pane fields" {
    const nodes = [_]session_state.Node{
        .{ .split = .{
            .axis = .horizontal,
            .ratio = 0.4,
            .first = 1,
            .second = 2,
        } },
        .{ .pane = .{
            .cwd = "C:\\src\\noctty",
            .profile = "pwsh",
            .title_override = "Build",
            .tab_title_override = "Project",
        } },
        .{ .pane = .{
            .cwd = "C:\\logs",
            .profile = "cmd",
        } },
    };
    const tabs = [_]session_state.Tab{.{
        .selected_leaf = 1,
        .layout = .{ .root = 0, .nodes = &nodes },
    }};
    const windows = [_]session_state.Window{.{
        .selected_tab = 0,
        .tabs = &tabs,
    }};
    const encoded = try session_state.encodeAlloc(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"width\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"state\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"command\"") == null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "demo.json" });
    defer std.testing.allocator.free(path);
    const temporary = try std.mem.concat(std.testing.allocator, u8, &.{ path, ".tmp" });
    defer std.testing.allocator.free(temporary);
    try session_persistence.writeFileAtomic(path, temporary, encoded);

    var loaded = session_persistence.loadAlloc(
        std.testing.allocator,
        path,
        session_persistence.default_max_state_bytes,
    );
    defer loaded.deinit();
    const parsed = switch (loaded) {
        .loaded => |value| value.value,
        else => return error.TestExpectedEqual,
    };
    try std.testing.expectEqual(@as(usize, 1), parsed.windows.len);
    try std.testing.expect(parsed.windows[0].x == null);
    try std.testing.expect(parsed.windows[0].state == null);
    try std.testing.expectEqual(@as(usize, 3), parsed.windows[0].tabs[0].layout.nodes.len);
    const left = parsed.windows[0].tabs[0].layout.nodes[1].pane;
    try std.testing.expectEqualStrings("C:\\src\\noctty", left.cwd.?);
    try std.testing.expectEqualStrings("pwsh", left.profile.?);
    try std.testing.expectEqualStrings("Build", left.title_override.?);
    try std.testing.expectEqualStrings("Project", left.tab_title_override.?);
}

test "named layout directory enumeration is valid sorted and bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "zeta.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "bad!.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "Alpha Layout.json", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "beta.JSON", .data = "{}" });
    try tmp.dir.writeFile(.{ .sub_path = "ignored.txt", .data = "{}" });
    try tmp.dir.makeDir("directory.json");
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    // `beta.JSON`, `bad!.json`, `ignored.txt`, and the `directory.json`
    // directory are all skipped, so the cap of two keeps the two valid names.
    const names = try listNamesAlloc(std.testing.allocator, root, 2);
    defer freeNames(std.testing.allocator, names);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Alpha Layout", names[0]);
    try std.testing.expectEqualStrings("zeta", names[1]);

    const capped = try listNamesAlloc(std.testing.allocator, root, 1);
    defer freeNames(std.testing.allocator, capped);
    try std.testing.expectEqual(@as(usize, 1), capped.len);
    try std.testing.expectEqualStrings("Alpha Layout", capped[0]);
}

test "named layout jump list argv uses the shared new-window CLI" {
    const argv = try launchArgvAlloc(std.testing.allocator, "demo");
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 2), argv.len);
    try std.testing.expectEqualStrings("+new-window", argv[0]);
    try std.testing.expectEqualStrings("--launch-layout=demo", argv[1]);
    try std.testing.expectError(
        error.LeadingOrTrailingSpaceOrDot,
        launchArgvAlloc(std.testing.allocator, "../demo"),
    );
}
