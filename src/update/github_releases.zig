const std = @import("std");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");

const Allocator = std.mem.Allocator;

pub const repo_owner = "amanthanvi";
pub const repo_name = "winghostty";
pub const latest_stable_api_url = "https://api.github.com/repos/amanthanvi/winghostty/releases/latest";
pub const releases_url = "https://github.com/amanthanvi/winghostty/releases";
pub const windows_checksums_asset_name = "SHA256SUMS.txt";
pub const windows_checksums_signature_asset_name = "SHA256SUMS.txt.sig";

pub const throttle_seconds: i64 = 24 * 60 * 60;

pub const State = struct {
    last_checked_at: i64 = 0,
    last_seen_version: ?[]u8 = null,
    dismissed_version: ?[]u8 = null,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.last_seen_version) |value| alloc.free(value);
        if (self.dismissed_version) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Release = struct {
    version_text: []u8,
    release_url: []u8,
    windows_install: ?WindowsInstallCandidate = null,

    pub fn deinit(self: *Release, alloc: Allocator) void {
        if (self.windows_install) |*candidate| candidate.deinit(alloc);
        alloc.free(self.version_text);
        alloc.free(self.release_url);
        self.* = undefined;
    }
};

pub const WindowsInstallCandidate = struct {
    installer_name: []u8,
    installer_url: []u8,
    checksums_url: []u8,
    checksums_signature_url: []u8,

    pub fn deinit(self: *WindowsInstallCandidate, alloc: Allocator) void {
        alloc.free(self.installer_name);
        alloc.free(self.installer_url);
        alloc.free(self.checksums_url);
        alloc.free(self.checksums_signature_url);
        self.* = undefined;
    }
};

pub const CheckResult = union(enum) {
    up_to_date,
    throttled,
    update_available: Release,

    pub fn deinit(self: *CheckResult, alloc: Allocator) void {
        switch (self.*) {
            .update_available => |*release| release.deinit(alloc),
            else => {},
        }
        self.* = undefined;
    }
};

pub const CheckOptions = struct {
    current_version: std.SemanticVersion,
    force: bool = false,
    respect_dismissal: bool = true,
    now: i64 = 0,
};

pub fn defaultStatePath(alloc: Allocator) ![]u8 {
    return internal_os.xdg.state(alloc, .{
        .subdir = build_config.data_dir_name ++ "/update-state.json",
    });
}

pub fn loadState(alloc: Allocator, path: []const u8) !State {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(alloc, 16 * 1024);
    defer alloc.free(contents);
    if (contents.len == 0) return .{};

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, contents, .{}) catch {
        return .{};
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return .{},
    };

    var state: State = .{};
    if (root.get("last_checked_at")) |value| {
        switch (value) {
            .integer => |integer| state.last_checked_at = @intCast(integer),
            else => {},
        }
    }
    if (root.get("last_seen_version")) |value| {
        switch (value) {
            .string => |text| state.last_seen_version = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("dismissed_version")) |value| {
        switch (value) {
            .string => |text| state.dismissed_version = try alloc.dupe(u8, text),
            else => {},
        }
    }

    return state;
}

pub fn saveState(path: []const u8, state: *const State) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    var buf: [1024]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    try writer.writeAll("{\"last_checked_at\":");
    try writer.print("{d}", .{state.last_checked_at});
    try writer.writeAll(",\"last_seen_version\":");
    try writeOptionalJsonString(writer, state.last_seen_version);
    try writer.writeAll(",\"dismissed_version\":");
    try writeOptionalJsonString(writer, state.dismissed_version);
    try writer.writeAll("}");
    try writer.flush();
}

pub fn recordDismissal(alloc: Allocator, path: []const u8, version_text: []const u8) !void {
    var state = try loadState(alloc, path);
    defer state.deinit(alloc);
    if (state.dismissed_version) |value| alloc.free(value);
    state.dismissed_version = try alloc.dupe(u8, version_text);
    try saveState(path, &state);
}

pub fn clearDismissal(alloc: Allocator, path: []const u8) !void {
    var state = try loadState(alloc, path);
    defer state.deinit(alloc);
    if (state.dismissed_version) |value| {
        alloc.free(value);
        state.dismissed_version = null;
        try saveState(path, &state);
    }
}

pub fn checkLatestStableRelease(
    alloc: Allocator,
    state_path: []const u8,
    options: CheckOptions,
) !CheckResult {
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    const now = if (options.now > 0) options.now else std.time.timestamp();

    if (!options.force and !shouldCheckNetwork(state.last_checked_at, now)) {
        if (try cachedAvailableRelease(alloc, &state, options.current_version, options.respect_dismissal)) |release| {
            return .{ .update_available = release };
        }
        return .throttled;
    }

    var release = try fetchLatestStableRelease(alloc);
    errdefer release.deinit(alloc);

    state.last_checked_at = now;
    if (state.last_seen_version) |value| alloc.free(value);
    state.last_seen_version = try alloc.dupe(u8, release.version_text);
    try saveState(state_path, &state);

    const latest_version = try parseVersionText(release.version_text);
    if (options.current_version.order(latest_version) != .lt) {
        release.deinit(alloc);
        return .up_to_date;
    }

    if (options.respect_dismissal) {
        if (state.dismissed_version) |dismissed| {
            if (std.mem.eql(u8, dismissed, release.version_text)) {
                release.deinit(alloc);
                return .up_to_date;
            }
        }
    }

    return .{ .update_available = release };
}

pub fn releaseUrlForVersion(alloc: Allocator, version_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "https://github.com/{s}/{s}/releases/tag/v{s}",
        .{ repo_owner, repo_name, version_text },
    );
}

fn writeOptionalJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.writeByte('"');
        try writer.writeAll(text);
        try writer.writeByte('"');
        return;
    }

    try writer.writeAll("null");
}

fn shouldCheckNetwork(last_checked_at: i64, now: i64) bool {
    if (last_checked_at <= 0) return true;
    if (now <= last_checked_at) return true;
    return now - last_checked_at >= throttle_seconds;
}

fn cachedAvailableRelease(
    alloc: Allocator,
    state: *const State,
    current_version: std.SemanticVersion,
    respect_dismissal: bool,
) !?Release {
    const last_seen = state.last_seen_version orelse return null;
    const latest_version = parseVersionText(last_seen) catch return null;
    if (current_version.order(latest_version) != .lt) return null;
    if (respect_dismissal) {
        if (state.dismissed_version) |dismissed| {
            if (std.mem.eql(u8, dismissed, last_seen)) return null;
        }
    }

    // Cached state only persists the version string, so throttled responses
    // cannot reconstruct asset-scoped installer metadata.
    return .{
        .version_text = try alloc.dupe(u8, last_seen),
        .release_url = try releaseUrlForVersion(alloc, last_seen),
    };
}

fn fetchLatestStableRelease(alloc: Allocator) !Release {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var response_buf: std.Io.Writer.Allocating = .init(alloc);
    defer response_buf.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = latest_stable_api_url },
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
            .{ .name = "user-agent", .value = "winghostty-updater" },
            .{ .name = "x-github-api-version", .value = "2022-11-28" },
        },
        .response_writer = &response_buf.writer,
    });

    if (result.status != .ok) return error.BadGateway;

    const body = try response_buf.toOwnedSlice();
    defer alloc.free(body);

    return parseLatestStableReleaseResponse(alloc, body);
}

fn parseLatestStableReleaseResponse(alloc: Allocator, body: []const u8) !Release {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidReleaseResponse,
    };

    const tag_name = switch (root.get("tag_name") orelse return error.InvalidReleaseResponse) {
        .string => |value| value,
        else => return error.InvalidReleaseResponse,
    };
    const html_url = switch (root.get("html_url") orelse return error.InvalidReleaseResponse) {
        .string => |value| value,
        else => return error.InvalidReleaseResponse,
    };

    const version_text = try canonicalVersionText(alloc, tag_name);
    errdefer alloc.free(version_text);
    _ = try parseVersionText(version_text);
    const release_url = try alloc.dupe(u8, html_url);
    errdefer alloc.free(release_url);

    return .{
        .version_text = version_text,
        .release_url = release_url,
        .windows_install = try parseWindowsInstallCandidate(alloc, root, version_text),
    };
}

fn parseWindowsInstallCandidate(
    alloc: Allocator,
    root: anytype,
    version_text: []const u8,
) !?WindowsInstallCandidate {
    const assets_value = root.get("assets") orelse return null;
    const assets = switch (assets_value) {
        .array => |value| value,
        else => return null,
    };

    const expected_installer_name = try std.fmt.allocPrint(
        alloc,
        "winghostty-{s}-windows-x64-setup.exe",
        .{version_text},
    );
    errdefer alloc.free(expected_installer_name);

    var installer_url: ?[]const u8 = null;
    var checksums_url: ?[]const u8 = null;
    var checksums_signature_url: ?[]const u8 = null;

    for (assets.items) |asset_value| {
        const asset = switch (asset_value) {
            .object => |value| value,
            else => continue,
        };

        const name = switch (asset.get("name") orelse continue) {
            .string => |value| value,
            else => continue,
        };
        const browser_download_url = switch (asset.get("browser_download_url") orelse continue) {
            .string => |value| value,
            else => continue,
        };

        if (std.mem.eql(u8, name, expected_installer_name)) {
            installer_url = browser_download_url;
            continue;
        }
        if (std.mem.eql(u8, name, windows_checksums_asset_name)) {
            checksums_url = browser_download_url;
            continue;
        }
        if (std.mem.eql(u8, name, windows_checksums_signature_asset_name)) {
            checksums_signature_url = browser_download_url;
        }
    }

    if (installer_url == null or checksums_url == null or checksums_signature_url == null) {
        alloc.free(expected_installer_name);
        return null;
    }

    const owned_installer_url = try alloc.dupe(u8, installer_url.?);
    errdefer alloc.free(owned_installer_url);
    const owned_checksums_url = try alloc.dupe(u8, checksums_url.?);
    errdefer alloc.free(owned_checksums_url);
    const owned_checksums_signature_url = try alloc.dupe(u8, checksums_signature_url.?);
    errdefer alloc.free(owned_checksums_signature_url);

    return .{
        .installer_name = expected_installer_name,
        .installer_url = owned_installer_url,
        .checksums_url = owned_checksums_url,
        .checksums_signature_url = owned_checksums_signature_url,
    };
}

fn canonicalVersionText(alloc: Allocator, raw_tag: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_tag, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidVersion;
    const without_v = if (trimmed[0] == 'v' or trimmed[0] == 'V') trimmed[1..] else trimmed;
    if (without_v.len == 0) return error.InvalidVersion;
    return alloc.dupe(u8, without_v);
}

fn parseVersionText(version_text: []const u8) !std.SemanticVersion {
    return std.SemanticVersion.parse(version_text);
}

test "canonical version strips v prefix" {
    const alloc = std.testing.allocator;
    const version_text = try canonicalVersionText(alloc, "v1.2.3");
    defer alloc.free(version_text);
    try std.testing.expectEqualStrings("1.2.3", version_text);
}

test "cached update respects dismissal" {
    const alloc = std.testing.allocator;
    var state: State = .{
        .last_seen_version = try alloc.dupe(u8, "1.2.3"),
        .dismissed_version = try alloc.dupe(u8, "1.2.3"),
    };
    defer state.deinit(alloc);

    const current = try std.SemanticVersion.parse("1.2.2");
    try std.testing.expect((try cachedAvailableRelease(alloc, &state, current, true)) == null);
}

test "release parser requires signed checksum metadata for windows install candidate" {
    const alloc = std.testing.allocator;
    const body =
        \\{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/winghostty/releases/tag/v1.3.100",
        \\  "assets": [
        \\    {
        \\      "name": "winghostty-1.3.100-windows-x64-setup.exe",
        \\      "browser_download_url": "https://example.invalid/winghostty-1.3.100-windows-x64-setup.exe"
        \\    },
        \\    {
        \\      "name": "SHA256SUMS.txt",
        \\      "browser_download_url": "https://example.invalid/SHA256SUMS.txt"
        \\    }
        \\  ]
        \\}
    ;

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install == null);
}

test "release parser selects windows install candidate when signed checksum metadata is present" {
    const alloc = std.testing.allocator;
    const body =
        \\{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/winghostty/releases/tag/v1.3.100",
        \\  "assets": [
        \\    {
        \\      "name": "winghostty-1.3.100-windows-x64-setup.exe",
        \\      "browser_download_url": "https://example.invalid/winghostty-1.3.100-windows-x64-setup.exe"
        \\    },
        \\    {
        \\      "name": "SHA256SUMS.txt",
        \\      "browser_download_url": "https://example.invalid/SHA256SUMS.txt"
        \\    },
        \\    {
        \\      "name": "SHA256SUMS.txt.sig",
        \\      "browser_download_url": "https://example.invalid/SHA256SUMS.txt.sig"
        \\    }
        \\  ]
        \\}
    ;

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
    const windows_install = release.windows_install.?;
    try std.testing.expectEqualStrings(
        "winghostty-1.3.100-windows-x64-setup.exe",
        windows_install.installer_name,
    );
    try std.testing.expectEqualStrings(
        "https://example.invalid/winghostty-1.3.100-windows-x64-setup.exe",
        windows_install.installer_url,
    );
    try std.testing.expectEqualStrings(
        "https://example.invalid/SHA256SUMS.txt",
        windows_install.checksums_url,
    );
    try std.testing.expectEqualStrings(
        "https://example.invalid/SHA256SUMS.txt.sig",
        windows_install.checksums_signature_url,
    );
}

test "release parser accepts long semver tags for windows install candidate" {
    const alloc = std.testing.allocator;

    var version_text_buf: std.ArrayList(u8) = .empty;
    defer version_text_buf.deinit(alloc);
    try version_text_buf.appendSlice(alloc, "1.3.100-");
    try version_text_buf.appendNTimes(alloc, 'a', 128);
    const version_text = try version_text_buf.toOwnedSlice(alloc);
    defer alloc.free(version_text);

    const installer_name = try std.fmt.allocPrint(
        alloc,
        "winghostty-{s}-windows-x64-setup.exe",
        .{version_text},
    );
    defer alloc.free(installer_name);

    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v{s}",
        \\  "html_url": "https://github.com/amanthanvi/winghostty/releases/tag/v{s}",
        \\  "assets": [
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }},
        \\    {{
        \\      "name": "SHA256SUMS.txt",
        \\      "browser_download_url": "https://example.invalid/SHA256SUMS.txt"
        \\    }},
        \\    {{
        \\      "name": "SHA256SUMS.txt.sig",
        \\      "browser_download_url": "https://example.invalid/SHA256SUMS.txt.sig"
        \\    }}
        \\  ]
        \\}}
    ,
        .{ version_text, version_text, installer_name, installer_name },
    );
    defer alloc.free(body);

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
    try std.testing.expectEqualStrings(installer_name, release.windows_install.?.installer_name);
}
