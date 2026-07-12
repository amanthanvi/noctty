const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const log = std.log.scoped(.update_github_releases);

pub const repo_owner = "amanthanvi";
pub const repo_name = "winghostty";
pub const latest_stable_api_url = "https://api.github.com/repos/amanthanvi/winghostty/releases/latest";
pub const releases_url = "https://github.com/amanthanvi/winghostty/releases";
pub const windows_checksums_asset_name_legacy = "SHA256SUMS.txt";
const windows_asset_metadata = switch (builtin.cpu.arch) {
    .aarch64 => .{
        .arch = "arm64",
        .checksums_asset_name = "SHA256SUMS-windows-arm64.txt",
    },
    .x86_64 => .{
        .arch = "x64",
        .checksums_asset_name = "SHA256SUMS-windows-x64.txt",
    },
    else => @compileError("unsupported Windows architecture for installer assets"),
};

pub const throttle_seconds: i64 = 24 * 60 * 60;
const pinned_publisher_spki_sha256 = [_][Sha256.digest_length]u8{
    // SHA-256(SubjectPublicKeyInfo DER) for CN=winghostty Local Dev Signing,
    // valid 2026-04-30..2029-04-30. Extracted from v1.3.117 Windows setup asset.
    .{
        0x67, 0x1e, 0xc8, 0x22, 0xc4, 0x1f, 0x39, 0xb1,
        0xd7, 0x9c, 0x31, 0xd2, 0x71, 0x69, 0xb3, 0x74,
        0x86, 0x33, 0x3c, 0x00, 0x8c, 0x7a, 0x03, 0x82,
        0x61, 0xb4, 0xfa, 0xe5, 0x38, 0x18, 0xce, 0x2a,
    },
};

pub const State = struct {
    last_checked_at: i64 = 0,
    last_seen_version: ?[]u8 = null,
    dismissed_version: ?[]u8 = null,
    staged_version: ?[]u8 = null,
    staged_installer_path: ?[]u8 = null,
    staged_sha256: ?[]u8 = null,
    staged_at: i64 = 0,
    apply_requested_at: i64 = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.last_seen_version) |value| alloc.free(value);
        if (self.dismissed_version) |value| alloc.free(value);
        if (self.staged_version) |value| alloc.free(value);
        if (self.staged_installer_path) |value| alloc.free(value);
        if (self.staged_sha256) |value| alloc.free(value);
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

    pub fn deinit(self: *WindowsInstallCandidate, alloc: Allocator) void {
        alloc.free(self.installer_name);
        alloc.free(self.installer_url);
        alloc.free(self.checksums_url);
        self.* = undefined;
    }
};

pub const StagedWindowsInstall = struct {
    version_text: []u8,
    installer_path: []u8,
    sha256_hex: []u8,
    locked_stage_dir: ?std.fs.File = null,
    locked_file: ?std.fs.File = null,

    pub fn deinit(self: *StagedWindowsInstall, alloc: Allocator) void {
        if (self.locked_file) |file| file.close();
        if (self.locked_stage_dir) |file| file.close();
        alloc.free(self.version_text);
        alloc.free(self.installer_path);
        alloc.free(self.sha256_hex);
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
    if (root.get("staged_version")) |value| {
        switch (value) {
            .string => |text| state.staged_version = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("staged_installer_path")) |value| {
        switch (value) {
            .string => |text| state.staged_installer_path = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("staged_sha256")) |value| {
        switch (value) {
            .string => |text| state.staged_sha256 = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("staged_at")) |value| {
        switch (value) {
            .integer => |integer| state.staged_at = @intCast(integer),
            else => {},
        }
    }
    if (root.get("apply_requested_at")) |value| {
        switch (value) {
            .integer => |integer| state.apply_requested_at = @intCast(integer),
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
    try writer.writeAll(",\"staged_version\":");
    try writeOptionalJsonString(writer, state.staged_version);
    try writer.writeAll(",\"staged_installer_path\":");
    try writeOptionalJsonString(writer, state.staged_installer_path);
    try writer.writeAll(",\"staged_sha256\":");
    try writeOptionalJsonString(writer, state.staged_sha256);
    try writer.writeAll(",\"staged_at\":");
    try writer.print("{d}", .{state.staged_at});
    try writer.writeAll(",\"apply_requested_at\":");
    try writer.print("{d}", .{state.apply_requested_at});
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

pub fn stageWindowsInstall(
    alloc: Allocator,
    state_path: []const u8,
    release: *const Release,
) !StagedWindowsInstall {
    const candidate = release.windows_install orelse return error.WindowsInstallNotEligible;
    if (!std.fs.path.isAbsolute(state_path)) return error.InvalidStatePath;

    const state_dir = std.fs.path.dirname(state_path) orelse return error.InvalidStatePath;
    const stage_dir = try std.fs.path.join(alloc, &.{ state_dir, "updates", release.version_text });
    defer alloc.free(stage_dir);
    try std.fs.cwd().makePath(stage_dir);

    const installer_path = try std.fs.path.join(alloc, &.{ stage_dir, candidate.installer_name });
    errdefer alloc.free(installer_path);
    const checksums_path = try std.fs.path.join(alloc, &.{ stage_dir, windowsChecksumsAssetName() });
    defer alloc.free(checksums_path);

    try downloadUrlToFile(alloc, candidate.checksums_url, checksums_path);
    try downloadUrlToFile(alloc, candidate.installer_url, installer_path);

    const checksums = try std.fs.cwd().readFileAlloc(alloc, checksums_path, 1024 * 1024);
    defer alloc.free(checksums);
    const expected_digest = try parseExpectedSha256(checksums, candidate.installer_name);

    const actual_digest = try sha256File(installer_path);
    if (!std.mem.eql(u8, &expected_digest, &actual_digest)) return error.InstallerChecksumMismatch;

    if (builtin.os.tag == .windows) {
        try verifyAuthenticodeSignature(installer_path, null);
    } else {
        return error.AuthenticodeRequiresWindows;
    }

    const sha256_hex = try alloc.dupe(u8, &std.fmt.bytesToHex(actual_digest, .lower));
    errdefer alloc.free(sha256_hex);

    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    replaceOptionalOwned(alloc, &state.staged_version, try alloc.dupe(u8, release.version_text));
    replaceOptionalOwned(alloc, &state.staged_installer_path, try alloc.dupe(u8, installer_path));
    replaceOptionalOwned(alloc, &state.staged_sha256, try alloc.dupe(u8, sha256_hex));
    state.staged_at = std.time.timestamp();
    state.apply_requested_at = 0;
    try saveState(state_path, &state);

    return .{
        .version_text = try alloc.dupe(u8, release.version_text),
        .installer_path = installer_path,
        .sha256_hex = sha256_hex,
    };
}

pub fn verifyStagedWindowsInstall(
    alloc: Allocator,
    state_path: []const u8,
) !StagedWindowsInstall {
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);

    const version_text = state.staged_version orelse return error.NoStagedWindowsInstall;
    const installer_path = state.staged_installer_path orelse return error.NoStagedWindowsInstall;
    const sha256_hex = state.staged_sha256 orelse return error.NoStagedWindowsInstall;
    if (!std.fs.path.isAbsolute(installer_path)) return error.InvalidStagedInstallerPath;

    const stage_dir = std.fs.path.dirname(installer_path) orelse return error.InvalidStagedInstallerPath;
    var locked_stage_dir = try openLockedStageDirectory(stage_dir);
    errdefer locked_stage_dir.close();

    var locked_file = try openLockedInstaller(installer_path);
    errdefer locked_file.close();
    if (!try lockedFileMatchesPath(alloc, installer_path, locked_file.handle)) {
        return error.InvalidStagedInstallerPath;
    }

    const expected_digest = try parseSha256Hex(sha256_hex);
    const actual_digest = try sha256OpenFile(&locked_file);
    if (!std.mem.eql(u8, &expected_digest, &actual_digest)) return error.InstallerChecksumMismatch;

    if (builtin.os.tag == .windows) {
        try verifyAuthenticodeSignature(installer_path, locked_file.handle);
    } else {
        return error.AuthenticodeRequiresWindows;
    }

    return .{
        .version_text = try alloc.dupe(u8, version_text),
        .installer_path = try alloc.dupe(u8, installer_path),
        .sha256_hex = try alloc.dupe(u8, sha256_hex),
        .locked_stage_dir = locked_stage_dir,
        .locked_file = locked_file,
    };
}

pub fn recordStagedApplyRequested(alloc: Allocator, state_path: []const u8, now: i64) !void {
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);

    if (state.staged_version == null or
        state.staged_installer_path == null or
        state.staged_sha256 == null)
    {
        return error.NoStagedWindowsInstall;
    }

    state.apply_requested_at = if (now > 0) now else std.time.timestamp();
    try saveState(state_path, &state);
}

fn writeOptionalJsonString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writer.writeByte('"');
        for (text) |c| {
            switch (c) {
                '\\', '"' => {
                    try writer.writeByte('\\');
                    try writer.writeByte(c);
                },
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x08 => try writer.writeAll("\\b"),
                0x0C => try writer.writeAll("\\f"),
                0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
        return;
    }

    try writer.writeAll("null");
}

fn replaceOptionalOwned(alloc: Allocator, slot: *?[]u8, value: []u8) void {
    if (slot.*) |old| alloc.free(old);
    slot.* = value;
}

fn downloadUrlToFile(alloc: Allocator, url: []const u8, dest_path: []const u8) !void {
    if (!std.fs.path.isAbsolute(dest_path)) return error.InvalidDownloadPath;

    const temp_path = try std.fmt.allocPrint(alloc, "{s}.part", .{dest_path});
    defer alloc.free(temp_path);
    var committed = false;
    defer if (!committed) {
        std.fs.deleteFileAbsolute(temp_path) catch {};
    };
    std.fs.deleteFileAbsolute(temp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    if (std.fs.path.dirname(dest_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    var file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
    var file_open = true;
    errdefer if (file_open) file.close();

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var file_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(&file_buf);
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "accept", .value = "application/octet-stream" },
            .{ .name = "user-agent", .value = "winghostty-updater" },
        },
        .response_writer = &file_writer.interface,
    });
    try file_writer.interface.flush();
    file.close();
    file_open = false;

    try requireOkHttpStatus("download", url, result.status);

    std.fs.deleteFileAbsolute(dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(temp_path, dest_path);
    committed = true;
}

fn requireOkHttpStatus(context: []const u8, url: []const u8, status: std.http.Status) !void {
    if (status == .ok) return;

    log.warn("{s} HTTP request failed status={} phrase={s} url={s}", .{
        context,
        @intFromEnum(status),
        status.phrase() orelse "unknown",
        url,
    });

    return switch (status) {
        .unauthorized => error.UpdateHttpUnauthorized,
        .forbidden => error.UpdateHttpForbidden,
        .not_found => error.UpdateHttpNotFound,
        .too_many_requests => error.UpdateHttpRateLimited,
        else => error.UnexpectedHttpStatus,
    };
}

fn parseExpectedSha256(checksums: []const u8, installer_name: []const u8) ![Sha256.digest_length]u8 {
    var matched: ?[Sha256.digest_length]u8 = null;
    var lines = std.mem.splitScalar(u8, checksums, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const hex = parts.next() orelse continue;
        const filename_raw = parts.next() orelse continue;
        const filename = if (filename_raw.len > 0 and filename_raw[0] == '*')
            filename_raw[1..]
        else
            filename_raw;

        if (!std.mem.eql(u8, filename, installer_name)) continue;
        if (matched != null) return error.InstallerChecksumDuplicate;
        matched = try parseSha256Hex(hex);
    }

    return matched orelse error.InstallerChecksumMissing;
}

fn parseSha256Hex(hex: []const u8) ![Sha256.digest_length]u8 {
    if (hex.len != Sha256.digest_length * 2) return error.InvalidChecksum;
    var digest: [Sha256.digest_length]u8 = undefined;
    for (&digest, 0..) |*byte, i| {
        byte.* = (try hexNibble(hex[i * 2]) << 4) | try hexNibble(hex[i * 2 + 1]);
    }
    return digest;
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidChecksum,
    };
}

fn sha256File(path: []const u8) ![Sha256.digest_length]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    return sha256OpenFile(&file);
}

fn sha256OpenFile(file: *std.fs.File) ![Sha256.digest_length]u8 {
    try file.seekTo(0);

    var hasher = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const len = try file.read(&buf);
        if (len == 0) break;
        hasher.update(buf[0..len]);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    try file.seekTo(0);
    return digest;
}

fn openLockedInstaller(path: []const u8) !std.fs.File {
    if (builtin.os.tag != .windows) return error.AuthenticodeRequiresWindows;

    const windows = std.os.windows;
    try rejectReparsePoint(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(path_w);

    const handle = windows.kernel32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ,
        windows.FILE_SHARE_READ,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    return .{ .handle = handle };
}

fn openLockedStageDirectory(path: []const u8) !std.fs.File {
    if (builtin.os.tag != .windows) return error.AuthenticodeRequiresWindows;

    const windows = std.os.windows;
    try rejectReparsePoint(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(path_w);

    const handle = windows.kernel32.CreateFileW(
        path_w.ptr,
        windows.GENERIC_READ,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return windows.unexpectedError(windows.kernel32.GetLastError());
    }
    return .{ .handle = handle };
}

fn rejectReparsePoint(path: []const u8) !void {
    const windows = std.os.windows;
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(path_w);
    const attrs = try windows.GetFileAttributesW(path_w.ptr);
    if ((attrs & windows.FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return error.StagedInstallerReparsePoint;
    }
}

fn lockedFileMatchesPath(alloc: Allocator, path: []const u8, handle: std.os.windows.HANDLE) !bool {
    var final_buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined;
    const final_w = try std.os.windows.GetFinalPathNameByHandle(
        handle,
        .{ .volume_name = .Dos },
        &final_buf,
    );
    const final_utf8 = try std.unicode.utf16LeToUtf8Alloc(alloc, final_w);
    defer alloc.free(final_utf8);
    const final_path = if (std.mem.startsWith(u8, final_utf8, "\\\\?\\")) final_utf8[4..] else final_utf8;
    return std.ascii.eqlIgnoreCase(final_path, path);
}

fn verifyAuthenticodeSignature(
    path: []const u8,
    file_handle: ?std.os.windows.HANDLE,
) !void {
    if (builtin.os.tag != .windows) return error.AuthenticodeRequiresWindows;

    const windows = std.os.windows;
    const WinVerifyTrustFn = *const fn (?windows.HWND, *windows.GUID, *WinTrustData) callconv(.winapi) i32;
    const WTHelperProvDataFromStateDataFn = *const fn (windows.HANDLE) callconv(.winapi) ?*CryptProviderData;
    const WTHelperGetProvSignerFromChainFn = *const fn (
        *CryptProviderData,
        u32,
        windows.BOOL,
        u32,
    ) callconv(.winapi) ?*CryptProviderSgnr;
    const module = try windows.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("wintrust.dll"));
    defer windows.FreeLibrary(module);

    const proc = windows.kernel32.GetProcAddress(module, "WinVerifyTrust") orelse return error.SignatureVerifierUnavailable;
    const winVerifyTrust: WinVerifyTrustFn = @ptrCast(@alignCast(proc));
    const prov_data_proc = windows.kernel32.GetProcAddress(module, "WTHelperProvDataFromStateData") orelse return error.SignatureVerifierUnavailable;
    const signer_proc = windows.kernel32.GetProcAddress(module, "WTHelperGetProvSignerFromChain") orelse return error.SignatureVerifierUnavailable;
    const wtHelperProvDataFromStateData: WTHelperProvDataFromStateDataFn = @ptrCast(@alignCast(prov_data_proc));
    const wtHelperGetProvSignerFromChain: WTHelperGetProvSignerFromChainFn = @ptrCast(@alignCast(signer_proc));

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(path_w);

    var action = windows.GUID.parse("{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}");
    var file_info: WinTrustFileInfo = .{
        .cbStruct = @sizeOf(WinTrustFileInfo),
        .pcwszFilePath = path_w.ptr,
        .hFile = file_handle,
        .pgKnownSubject = null,
    };
    var data: WinTrustData = .{
        .cbStruct = @sizeOf(WinTrustData),
        .pPolicyCallbackData = null,
        .pSIPClientData = null,
        .dwUIChoice = WTD_UI_NONE,
        .fdwRevocationChecks = WTD_REVOKE_WHOLECHAIN,
        .dwUnionChoice = WTD_CHOICE_FILE,
        .pFile = &file_info,
        .dwStateAction = WTD_STATEACTION_VERIFY,
        .hWVTStateData = null,
        .pwszURLReference = null,
        .dwProvFlags = 0,
        .dwUIContext = 0,
        .pSignatureSettings = null,
    };
    defer {
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        _ = winVerifyTrust(null, &action, &data);
    }

    const trust_status = winVerifyTrust(null, &action, &data);
    if (!authenticodeStatusAllowsPinnedPublisherCheck(trust_status)) {
        return error.InvalidAuthenticodeSignature;
    }
    try verifyPinnedPublisherIdentityFromState(
        data.hWVTStateData orelse return error.UpdatePublisherIdentityUnavailable,
        wtHelperProvDataFromStateData,
        wtHelperGetProvSignerFromChain,
    );
}

fn verifyPinnedPublisherIdentityFromState(
    state: std.os.windows.HANDLE,
    wtHelperProvDataFromStateData: *const fn (std.os.windows.HANDLE) callconv(.winapi) ?*CryptProviderData,
    wtHelperGetProvSignerFromChain: *const fn (
        *CryptProviderData,
        u32,
        std.os.windows.BOOL,
        u32,
    ) callconv(.winapi) ?*CryptProviderSgnr,
) !void {
    if (pinned_publisher_spki_sha256.len == 0) return error.UpdatePublisherPinUnavailable;

    const provider = wtHelperProvDataFromStateData(state) orelse return error.UpdatePublisherIdentityUnavailable;
    const signer = wtHelperGetProvSignerFromChain(provider, 0, 0, 0) orelse return error.UpdatePublisherIdentityUnavailable;
    if (signer.csCertChain == 0 or signer.pasCertChain == null) return error.UpdatePublisherIdentityUnavailable;

    const signer_cert = signer.pasCertChain.?[0].pCert orelse return error.UpdatePublisherIdentityUnavailable;
    const der = signer_cert.pbCertEncoded[0..signer_cert.cbCertEncoded];
    const spki_hash = try certificateSpkiSha256(der);
    if (!publisherSpkiHashAllowed(&spki_hash)) return error.UntrustedUpdatePublisher;
}

fn publisherSpkiHashAllowed(spki_hash: *const [Sha256.digest_length]u8) bool {
    for (pinned_publisher_spki_sha256) |pinned| {
        if (std.mem.eql(u8, &pinned, spki_hash)) return true;
    }
    return false;
}

fn authenticodeStatusAllowsPinnedPublisherCheck(status: i32) bool {
    return status == 0 or status == cert_e_untrusted_root;
}

fn certificateSpkiSha256(cert_der: []const u8) ![Sha256.digest_length]u8 {
    const cert = try readDerElement(cert_der, 0);
    if (cert.tag != der_tag_sequence) return error.InvalidCertificate;

    const tbs = try readDerElement(cert_der, cert.content_start);
    if (tbs.tag != der_tag_sequence or tbs.end > cert.content_end) return error.InvalidCertificate;

    var offset = tbs.content_start;
    if (offset < tbs.content_end and cert_der[offset] == der_tag_context_0) {
        const version = try readDerElement(cert_der, offset);
        if (version.end > tbs.content_end) return error.InvalidCertificate;
        offset = version.end;
    }

    // TBSCertificate fields before subjectPublicKeyInfo:
    // serialNumber, signature, issuer, validity, subject.
    var fields_to_skip: usize = 5;
    while (fields_to_skip > 0) : (fields_to_skip -= 1) {
        const field = try readDerElement(cert_der, offset);
        if (field.end > tbs.content_end) return error.InvalidCertificate;
        offset = field.end;
    }

    const spki = try readDerElement(cert_der, offset);
    if (spki.tag != der_tag_sequence or spki.end > tbs.content_end) return error.InvalidCertificate;

    var hasher = Sha256.init(.{});
    hasher.update(cert_der[spki.start..spki.end]);
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

const DerElement = struct {
    tag: u8,
    start: usize,
    content_start: usize,
    content_end: usize,
    end: usize,
};

const der_tag_sequence: u8 = 0x30;
const der_tag_context_0: u8 = 0xa0;

fn readDerElement(buf: []const u8, start: usize) !DerElement {
    if (start + 2 > buf.len) return error.InvalidDer;

    const tag = buf[start];
    var offset = start + 1;
    const len_byte = buf[offset];
    offset += 1;

    var len: usize = 0;
    if ((len_byte & 0x80) == 0) {
        len = len_byte;
    } else {
        const len_len: usize = len_byte & 0x7f;
        if (len_len == 0 or len_len > @sizeOf(usize) or offset + len_len > buf.len) {
            return error.InvalidDer;
        }
        for (buf[offset .. offset + len_len]) |b| {
            len = (len << 8) | b;
        }
        offset += len_len;
    }

    if (offset + len > buf.len) return error.InvalidDer;
    return .{
        .tag = tag,
        .start = start,
        .content_start = offset,
        .content_end = offset + len,
        .end = offset + len,
    };
}

const WTD_UI_NONE: u32 = 2;
const WTD_REVOKE_WHOLECHAIN: u32 = 1;
const WTD_CHOICE_FILE: u32 = 1;
const WTD_STATEACTION_VERIFY: u32 = 1;
const WTD_STATEACTION_CLOSE: u32 = 2;
const cert_e_untrusted_root: i32 = @bitCast(@as(u32, 0x800B0109));
const WinTrustFileInfo = extern struct {
    cbStruct: u32,
    pcwszFilePath: [*:0]const u16,
    hFile: ?std.os.windows.HANDLE,
    pgKnownSubject: ?*std.os.windows.GUID,
};

const WinTrustData = extern struct {
    cbStruct: u32,
    pPolicyCallbackData: ?*anyopaque,
    pSIPClientData: ?*anyopaque,
    dwUIChoice: u32,
    fdwRevocationChecks: u32,
    dwUnionChoice: u32,
    pFile: *WinTrustFileInfo,
    dwStateAction: u32,
    hWVTStateData: ?std.os.windows.HANDLE,
    pwszURLReference: ?[*:0]const u16,
    dwProvFlags: u32,
    dwUIContext: u32,
    pSignatureSettings: ?*anyopaque,
};

const CertContext = extern struct {
    dwCertEncodingType: u32,
    pbCertEncoded: [*]const u8,
    cbCertEncoded: u32,
    pCertInfo: ?*anyopaque,
    hCertStore: ?*anyopaque,
};

const FileTime = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

const CryptProviderData = opaque {};

const CryptProviderSgnr = extern struct {
    cbStruct: u32,
    sftVerifyAsOf: FileTime,
    csCertChain: u32,
    pasCertChain: ?[*]CryptProviderCert,
    dwSignerType: u32,
    psSigner: ?*anyopaque,
    dwError: u32,
    csCounterSigners: u32,
    pasCounterSigners: ?*CryptProviderSgnr,
    pChainContext: ?*anyopaque,
};

const CryptProviderCert = extern struct {
    cbStruct: u32,
    pCert: ?*const CertContext,
};

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

    try requireOkHttpStatus("release metadata", latest_stable_api_url, result.status);

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
        "winghostty-{s}-windows-{s}-setup.exe",
        .{ version_text, windowsInstallerArch() },
    );
    errdefer alloc.free(expected_installer_name);
    const expected_checksums_name = windowsChecksumsAssetName();

    var installer_url: ?[]const u8 = null;
    var checksums_url: ?[]const u8 = null;

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
        if (std.mem.eql(u8, name, expected_checksums_name)) {
            checksums_url = browser_download_url;
            continue;
        }
        if (checksums_url == null and
            std.mem.eql(u8, windowsInstallerArch(), "x64") and
            std.mem.eql(u8, name, windows_checksums_asset_name_legacy))
        {
            checksums_url = browser_download_url;
            continue;
        }
    }

    if (installer_url == null or checksums_url == null) {
        alloc.free(expected_installer_name);
        return null;
    }

    const owned_installer_url = try alloc.dupe(u8, installer_url.?);
    errdefer alloc.free(owned_installer_url);
    const owned_checksums_url = try alloc.dupe(u8, checksums_url.?);
    errdefer alloc.free(owned_checksums_url);

    return .{
        .installer_name = expected_installer_name,
        .installer_url = owned_installer_url,
        .checksums_url = owned_checksums_url,
    };
}

fn windowsInstallerArch() []const u8 {
    return windows_asset_metadata.arch;
}

fn windowsChecksumsAssetName() []const u8 {
    return windows_asset_metadata.checksums_asset_name;
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

test "state persists staged windows install metadata with escaped path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "winghostty-test", "update-state.json" });
    defer alloc.free(state_path);

    var state: State = .{
        .last_checked_at = 123,
        .last_seen_version = try alloc.dupe(u8, "1.3.100"),
        .staged_version = try alloc.dupe(u8, "1.3.101"),
        .staged_installer_path = try alloc.dupe(u8, "C:\\Users\\Aman\\updates\\winghostty-1.3.101-windows-x64-setup.exe"),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        .staged_at = 456,
        .apply_requested_at = 789,
    };
    defer state.deinit(alloc);

    try saveState(state_path, &state);
    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(@as(i64, 123), loaded.last_checked_at);
    try std.testing.expectEqual(@as(i64, 456), loaded.staged_at);
    try std.testing.expectEqual(@as(i64, 789), loaded.apply_requested_at);
    try std.testing.expectEqualStrings("1.3.101", loaded.staged_version.?);
    try std.testing.expectEqualStrings(state.staged_installer_path.?, loaded.staged_installer_path.?);
    try std.testing.expectEqualStrings(state.staged_sha256.?, loaded.staged_sha256.?);
}

test "record staged apply request requires staged installer metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "winghostty-test", "update-state.json" });
    defer alloc.free(state_path);

    var state: State = .{
        .last_seen_version = try alloc.dupe(u8, "1.3.101"),
    };
    defer state.deinit(alloc);
    try saveState(state_path, &state);

    try std.testing.expectError(
        error.NoStagedWindowsInstall,
        recordStagedApplyRequested(alloc, state_path, 123),
    );
}

test "record staged apply request persists timestamp" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "winghostty-test", "update-state.json" });
    defer alloc.free(state_path);

    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.101"),
        .staged_installer_path = try alloc.dupe(u8, "C:\\Users\\Aman\\updates\\winghostty-1.3.101-windows-x64-setup.exe"),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
    };
    defer state.deinit(alloc);
    try saveState(state_path, &state);

    try recordStagedApplyRequested(alloc, state_path, 1234);

    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 1234), loaded.apply_requested_at);
}

test "state JSON writer escapes ASCII control characters" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "winghostty-test", "update-state.json" });
    defer alloc.free(state_path);

    var state: State = .{
        .last_seen_version = try alloc.dupe(u8, "1.3.101"),
        .staged_installer_path = try alloc.dupe(u8, "a\x00b\x08c\x0Bd\x0Ce\x1Ff"),
    };
    defer state.deinit(alloc);

    try saveState(state_path, &state);
    const contents = try std.fs.cwd().readFileAlloc(alloc, state_path, 16 * 1024);
    defer alloc.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\u0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\b") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\u000b") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\f") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\\u001f") != null);

    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings(state.staged_installer_path.?, loaded.staged_installer_path.?);
}

test "checksum parser accepts sha256 star filename lines" {
    const digest = try parseExpectedSha256(
        \\d00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00d *winghostty-1.3.100-windows-x64-setup.exe
        \\00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *other.exe
    ,
        "winghostty-1.3.100-windows-x64-setup.exe",
    );
    try std.testing.expectEqualStrings(
        "d00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00d",
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "checksum parser rejects missing installer entry" {
    try std.testing.expectError(
        error.InstallerChecksumMissing,
        parseExpectedSha256(
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *other.exe",
            "winghostty-1.3.100-windows-x64-setup.exe",
        ),
    );
}

test "checksum parser rejects duplicate installer entries" {
    try std.testing.expectError(
        error.InstallerChecksumDuplicate,
        parseExpectedSha256(
            \\00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *winghostty-1.3.100-windows-x64-setup.exe
            \\ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100 *winghostty-1.3.100-windows-x64-setup.exe
        ,
            "winghostty-1.3.100-windows-x64-setup.exe",
        ),
    );
}

test "http status mapping distinguishes update response failures" {
    try requireOkHttpStatus("test", "https://example.invalid/ok", .ok);
    try std.testing.expectError(
        error.UpdateHttpUnauthorized,
        requireOkHttpStatus("test", "https://example.invalid/unauthorized", .unauthorized),
    );
    try std.testing.expectError(
        error.UpdateHttpForbidden,
        requireOkHttpStatus("test", "https://example.invalid/forbidden", .forbidden),
    );
    try std.testing.expectError(
        error.UpdateHttpNotFound,
        requireOkHttpStatus("test", "https://example.invalid/not-found", .not_found),
    );
    try std.testing.expectError(
        error.UpdateHttpRateLimited,
        requireOkHttpStatus("test", "https://example.invalid/rate-limit", .too_many_requests),
    );
    try std.testing.expectError(
        error.UnexpectedHttpStatus,
        requireOkHttpStatus("test", "https://example.invalid/server-error", .service_unavailable),
    );
    try std.testing.expectError(
        error.UnexpectedHttpStatus,
        requireOkHttpStatus("test", "https://example.invalid/client-error", .bad_request),
    );
}

test "windows install staging rejects relative state path before download" {
    const alloc = std.testing.allocator;
    var release: Release = .{
        .version_text = try alloc.dupe(u8, "1.3.100"),
        .release_url = try alloc.dupe(u8, "https://example.invalid/release"),
        .windows_install = .{
            .installer_name = try alloc.dupe(u8, "winghostty-1.3.100-windows-x64-setup.exe"),
            .installer_url = try alloc.dupe(u8, "https://example.invalid/winghostty-1.3.100-windows-x64-setup.exe"),
            .checksums_url = try alloc.dupe(u8, "https://example.invalid/SHA256SUMS.txt"),
        },
    };
    defer release.deinit(alloc);

    try std.testing.expectError(
        error.InvalidStatePath,
        stageWindowsInstall(alloc, "relative-update-state.json", &release),
    );
}

test "release parser accepts checksum metadata without detached signature" {
    const alloc = std.testing.allocator;
    const installer_name = try std.fmt.allocPrint(
        alloc,
        "winghostty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/winghostty/releases/tag/v1.3.100",
        \\  "assets": [
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }},
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }}
        \\  ]
        \\}}
    ,
        .{ installer_name, installer_name, checksum_name, checksum_name },
    );
    defer alloc.free(body);

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
}

test "release parser selects windows install candidate when checksum metadata is present" {
    const alloc = std.testing.allocator;
    const installer_name = try std.fmt.allocPrint(
        alloc,
        "winghostty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/winghostty/releases/tag/v1.3.100",
        \\  "assets": [
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }},
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }}
        \\  ]
        \\}}
    ,
        .{ installer_name, installer_name, checksum_name, checksum_name },
    );
    defer alloc.free(body);

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
    const windows_install = release.windows_install.?;
    try std.testing.expectEqualStrings(installer_name, windows_install.installer_name);
    const installer_url = try std.fmt.allocPrint(alloc, "https://example.invalid/{s}", .{installer_name});
    defer alloc.free(installer_url);
    try std.testing.expectEqualStrings(installer_url, windows_install.installer_url);
    const checksum_url = try std.fmt.allocPrint(alloc, "https://example.invalid/{s}", .{checksum_name});
    defer alloc.free(checksum_url);
    try std.testing.expectEqualStrings(checksum_url, windows_install.checksums_url);
}

test "release parser prefers architecture checksum metadata over legacy x64 metadata" {
    const alloc = std.testing.allocator;
    const installer_name = try std.fmt.allocPrint(
        alloc,
        "winghostty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/winghostty/releases/tag/v1.3.100",
        \\  "assets": [
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }},
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/arch-checksums.txt"
        \\    }},
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/legacy-checksums.txt"
        \\    }}
        \\  ]
        \\}}
    ,
        .{ installer_name, installer_name, checksum_name, windows_checksums_asset_name_legacy },
    );
    defer alloc.free(body);

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
    try std.testing.expectEqualStrings(
        "https://example.invalid/arch-checksums.txt",
        release.windows_install.?.checksums_url,
    );
}

test "release parser accepts legacy checksum metadata for x64 install candidate" {
    if (!std.mem.eql(u8, windowsInstallerArch(), "x64")) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const installer_name = try std.fmt.allocPrint(
        alloc,
        "winghostty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/winghostty/releases/tag/v1.3.100",
        \\  "assets": [
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }},
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/legacy-checksums.txt"
        \\    }}
        \\  ]
        \\}}
    ,
        .{ installer_name, installer_name, windows_checksums_asset_name_legacy },
    );
    defer alloc.free(body);

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
    try std.testing.expectEqualStrings(
        "https://example.invalid/legacy-checksums.txt",
        release.windows_install.?.checksums_url,
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
        "winghostty-{s}-windows-{s}-setup.exe",
        .{ version_text, windowsInstallerArch() },
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();

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
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }}
        \\  ]
        \\}}
    ,
        .{ version_text, version_text, installer_name, installer_name, checksum_name, checksum_name },
    );
    defer alloc.free(body);

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
    try std.testing.expectEqualStrings(installer_name, release.windows_install.?.installer_name);
}

test "locked staged installer rejects replacement until launch handoff" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("installer.exe", .{});
    try file.writeAll("test installer bytes");
    file.close();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "installer.exe");
    defer std.testing.allocator.free(path);
    const stage_dir = std.fs.path.dirname(path) orelse return error.InvalidStagedInstallerPath;
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_w);

    var locked_stage_dir = try openLockedStageDirectory(stage_dir);
    var locked_stage_dir_open = true;
    defer if (locked_stage_dir_open) locked_stage_dir.close();

    var locked = try openLockedInstaller(path);
    var locked_open = true;
    defer if (locked_open) locked.close();

    const renamed_stage_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}.renamed", .{stage_dir});
    defer std.testing.allocator.free(renamed_stage_dir);
    try std.testing.expectError(
        error.Unexpected,
        std.fs.renameAbsolute(stage_dir, renamed_stage_dir),
    );

    const replacement = std.os.windows.kernel32.CreateFileW(
        path_w.ptr,
        std.os.windows.GENERIC_WRITE,
        std.os.windows.FILE_SHARE_READ |
            std.os.windows.FILE_SHARE_WRITE |
            std.os.windows.FILE_SHARE_DELETE,
        null,
        std.os.windows.OPEN_EXISTING,
        std.os.windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    try std.testing.expectEqual(std.os.windows.INVALID_HANDLE_VALUE, replacement);
    try std.testing.expectEqual(
        std.os.windows.Win32Error.SHARING_VIOLATION,
        std.os.windows.kernel32.GetLastError(),
    );

    locked.close();
    locked_open = false;
    locked_stage_dir.close();
    locked_stage_dir_open = false;
    const after_release = std.os.windows.kernel32.CreateFileW(
        path_w.ptr,
        std.os.windows.GENERIC_WRITE,
        std.os.windows.FILE_SHARE_READ |
            std.os.windows.FILE_SHARE_WRITE |
            std.os.windows.FILE_SHARE_DELETE,
        null,
        std.os.windows.OPEN_EXISTING,
        std.os.windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    try std.testing.expect(after_release != std.os.windows.INVALID_HANDLE_VALUE);
    _ = std.os.windows.CloseHandle(after_release);
}

test "windows updater publisher SPKI pin allowlist is fail closed" {
    var allowed = pinned_publisher_spki_sha256[0];
    try std.testing.expect(publisherSpkiHashAllowed(&allowed));

    var rejected = allowed;
    rejected[0] ^= 0xff;
    try std.testing.expect(!publisherSpkiHashAllowed(&rejected));
}

test "windows updater publisher pin only overrides untrusted root" {
    try std.testing.expect(authenticodeStatusAllowsPinnedPublisherCheck(0));
    try std.testing.expect(authenticodeStatusAllowsPinnedPublisherCheck(cert_e_untrusted_root));
    try std.testing.expect(!authenticodeStatusAllowsPinnedPublisherCheck(@bitCast(@as(u32, 0x800B0100))));
}

test "windows updater extracts SPKI hash from certificate DER" {
    const cert_der = [_]u8{
        0x30, 0x1d,
        0x30, 0x15,
        0x02, 0x01,
        0x01, 0x30,
        0x00, 0x30,
        0x00, 0x30,
        0x00, 0x30,
        0x00, 0x30,
        0x08, 0x30,
        0x00, 0x03,
        0x04, 0x00,
        0xaa, 0xbb,
        0xcc, 0x30,
        0x00, 0x03,
        0x02, 0x00,
        0x00,
    };
    const spki_der = cert_der[15..25];

    var hasher = Sha256.init(.{});
    hasher.update(spki_der);
    var expected: [Sha256.digest_length]u8 = undefined;
    hasher.final(&expected);

    const actual = try certificateSpkiSha256(&cert_der);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
