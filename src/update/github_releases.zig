const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
pub const portable_apply = @import("portable_apply.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const log = std.log.scoped(.update_github_releases);

pub const latest_stable_api_url = "https://api.github.com/repos/amanthanvi/noctty/releases/latest";
pub const releases_url = "https://github.com/amanthanvi/noctty/releases";
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
    // SHA-256(SubjectPublicKeyInfo DER) for the pre-rename
    // "CN=winghostty Local Dev Signing" certificate (that is the actual
    // Subject on the existing key; the project is now Noctty),
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
    release_feed_url: ?[]u8 = null,
    release_url: ?[]u8 = null,
    dismissed_version: ?[]u8 = null,
    staged_version: ?[]u8 = null,
    staged_kind: ?portable_apply.StagedKind = null,
    staged_installer_path: ?[]u8 = null,
    staged_portable_path: ?[]u8 = null,
    staged_payload_path: ?[]u8 = null,
    staged_sha256: ?[]u8 = null,
    /// Feed URL the staged installer came from. State written before this
    /// field existed has no value; that state can only have come from the
    /// compiled-in default, so `stagedFeedUrl` reports the default for it.
    staged_feed_url: ?[]u8 = null,
    staged_at: i64 = 0,
    apply_requested_at: i64 = 0,
    portable_apply_phase: ?portable_apply.Phase = null,
    portable_backup_path: ?[]u8 = null,
    portable_confirmation_token: ?[]u8 = null,
    portable_watcher_pid: u32 = 0,
    portable_watcher_started_at: u64 = 0,

    pub fn stagedFeedUrl(self: *const State) []const u8 {
        return self.staged_feed_url orelse latest_stable_api_url;
    }

    /// Drop every staged-install field. Returns true when something was
    /// cleared, so the caller knows the on-disk state must be rewritten and
    /// any live update notice for that staged install is now stale.
    pub fn clearStagedInstall(self: *State, alloc: Allocator) bool {
        var cleared = false;
        inline for (.{
            "staged_version",
            "staged_installer_path",
            "staged_portable_path",
            "staged_payload_path",
            "staged_sha256",
            "staged_feed_url",
        }) |field| {
            if (@field(self, field)) |value| {
                alloc.free(value);
                @field(self, field) = null;
                cleared = true;
            }
        }
        if (self.staged_kind != null) {
            self.staged_kind = null;
            cleared = true;
        }
        if (self.staged_at != 0) {
            self.staged_at = 0;
            cleared = true;
        }
        if (self.apply_requested_at != 0) {
            self.apply_requested_at = 0;
            cleared = true;
        }
        return cleared;
    }

    pub fn deinit(self: *State, alloc: Allocator) void {
        if (self.last_seen_version) |value| alloc.free(value);
        if (self.release_feed_url) |value| alloc.free(value);
        if (self.release_url) |value| alloc.free(value);
        if (self.dismissed_version) |value| alloc.free(value);
        if (self.staged_version) |value| alloc.free(value);
        if (self.staged_installer_path) |value| alloc.free(value);
        if (self.staged_portable_path) |value| alloc.free(value);
        if (self.staged_payload_path) |value| alloc.free(value);
        if (self.staged_sha256) |value| alloc.free(value);
        if (self.staged_feed_url) |value| alloc.free(value);
        if (self.portable_backup_path) |value| alloc.free(value);
        if (self.portable_confirmation_token) |value| alloc.free(value);
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
    portable_name: ?[]u8 = null,
    portable_url: ?[]u8 = null,
    portable_manifest_name: ?[]u8 = null,
    portable_manifest_url: ?[]u8 = null,
    checksums_url: []u8,

    pub fn deinit(self: *WindowsInstallCandidate, alloc: Allocator) void {
        alloc.free(self.installer_name);
        alloc.free(self.installer_url);
        if (self.portable_name) |value| alloc.free(value);
        if (self.portable_url) |value| alloc.free(value);
        if (self.portable_manifest_name) |value| alloc.free(value);
        if (self.portable_manifest_url) |value| alloc.free(value);
        alloc.free(self.checksums_url);
        self.* = undefined;
    }
};

pub const StagedWindowsInstall = struct {
    kind: portable_apply.StagedKind,
    version_text: []u8,
    artifact_path: []u8,
    payload_path: ?[]u8 = null,
    sha256_hex: []u8,
    locked_stage_dir: ?std.fs.File = null,
    locked_file: ?std.fs.File = null,

    pub fn deinit(self: *StagedWindowsInstall, alloc: Allocator) void {
        if (self.locked_file) |file| file.close();
        if (self.locked_stage_dir) |file| file.close();
        alloc.free(self.version_text);
        alloc.free(self.artifact_path);
        if (self.payload_path) |value| alloc.free(value);
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

/// Outcome of one check, plus whatever the caller has to react to beyond the
/// result itself.
pub const CheckOutcome = struct {
    result: CheckResult,
    /// State belonging to a previously configured feed (a cached release, a
    /// dismissal, or a staged installer) was discarded during this check.
    /// Any live update notice came from that same feed, so the caller must
    /// drop it.
    feed_state_invalidated: bool = false,

    pub fn deinit(self: *CheckOutcome, alloc: Allocator) void {
        self.result.deinit(alloc);
        self.* = undefined;
    }
};

pub const CheckOptions = struct {
    current_version: std.SemanticVersion,
    release_feed_url: []const u8,
    force: bool = false,
    respect_dismissal: bool = true,
    now: i64 = 0,
};

/// Which of the three precedence levels supplied the effective feed URL.
pub const FeedSource = enum { configured, environment, default };

pub const ResolvedFeed = struct {
    url: []u8,
    source: FeedSource,
    /// Set when a feed URL was supplied but rejected because it is not a
    /// valid HTTPS URL. `url` is then the compiled-in default and this names
    /// the level whose value was ignored.
    ignored_non_https: ?FeedSource = null,

    pub fn deinit(self: *ResolvedFeed, alloc: Allocator) void {
        alloc.free(self.url);
        self.* = undefined;
    }
};

/// Resolve the effective release feed URL. Precedence is the explicit
/// `auto-update-feed-url`, then a non-empty `NOCTTY_UPDATE_FEED_URL`, then
/// the compiled-in default; a blank value at either level falls through to
/// the next, and a non-HTTPS value falls back to the default.
pub fn resolveReleaseFeed(alloc: Allocator, configured: ?[]const u8) !ResolvedFeed {
    const configured_value = if (configured) |value|
        std.mem.trim(u8, value, &std.ascii.whitespace)
    else
        "";
    const env_value = if (configured_value.len == 0)
        try internal_os.getEnvVarOwnedTrimmedNotEmpty(
            alloc,
            "NOCTTY_UPDATE_FEED_URL",
        )
    else
        null;
    defer if (env_value) |value| alloc.free(value);

    const source: FeedSource = if (configured_value.len > 0)
        .configured
    else if (env_value != null)
        .environment
    else
        .default;
    const candidate = switch (source) {
        .configured => configured_value,
        .environment => env_value.?,
        .default => "",
    };
    if (source == .default) return .{
        .url = try alloc.dupe(u8, latest_stable_api_url),
        .source = .default,
    };

    _ = validateHttpsUrl(candidate) catch {
        log.warn("ignoring non-HTTPS update feed URL; using the default release feed", .{});
        return .{
            .url = try alloc.dupe(u8, latest_stable_api_url),
            .source = .default,
            .ignored_non_https = source,
        };
    };

    return .{ .url = try alloc.dupe(u8, candidate), .source = source };
}

pub fn resolveReleaseFeedUrl(alloc: Allocator, configured: ?[]const u8) ![]u8 {
    const resolved = try resolveReleaseFeed(alloc, configured);
    return resolved.url;
}

pub fn defaultStatePath(alloc: Allocator) ![]u8 {
    return internal_os.xdg.state(alloc, .{
        .subdir = build_config.data_dir_name ++ "/update-state.json",
    });
}

fn openStateLock(path: []const u8) !std.fs.File {
    if (std.fs.path.dirname(path)) |dir_path| try std.fs.cwd().makePath(dir_path);
    var lock_path_buf: [std.fs.max_path_bytes + ".lock".len]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&lock_path_buf, "{s}.lock", .{path});
    return std.fs.createFileAbsolute(lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
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
    errdefer state.deinit(alloc);
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
    if (root.get("release_feed_url")) |value| {
        switch (value) {
            .string => |text| state.release_feed_url = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("release_url")) |value| {
        switch (value) {
            .string => |text| state.release_url = try alloc.dupe(u8, text),
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
    if (root.get("staged_kind")) |value| {
        switch (value) {
            .string => |text| state.staged_kind = std.meta.stringToEnum(portable_apply.StagedKind, text),
            else => {},
        }
    }
    if (root.get("staged_installer_path")) |value| {
        switch (value) {
            .string => |text| state.staged_installer_path = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("staged_portable_path")) |value| {
        switch (value) {
            .string => |text| state.staged_portable_path = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("staged_payload_path")) |value| {
        switch (value) {
            .string => |text| state.staged_payload_path = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("staged_sha256")) |value| {
        switch (value) {
            .string => |text| state.staged_sha256 = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("staged_feed_url")) |value| {
        switch (value) {
            .string => |text| state.staged_feed_url = try alloc.dupe(u8, text),
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
    if (root.get("portable_apply_phase")) |value| {
        switch (value) {
            .string => |text| state.portable_apply_phase = std.meta.stringToEnum(portable_apply.Phase, text),
            else => {},
        }
    }
    if (root.get("portable_backup_path")) |value| {
        switch (value) {
            .string => |text| state.portable_backup_path = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("portable_confirmation_token")) |value| {
        switch (value) {
            .string => |text| state.portable_confirmation_token = try alloc.dupe(u8, text),
            else => {},
        }
    }
    if (root.get("portable_watcher_pid")) |value| {
        switch (value) {
            .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u32)) {
                state.portable_watcher_pid = @intCast(integer);
            },
            else => {},
        }
    }
    if (root.get("portable_watcher_started_at")) |value| {
        switch (value) {
            .integer => |integer| if (integer >= 0) {
                state.portable_watcher_started_at = @intCast(integer);
            },
            else => {},
        }
    }

    return state;
}

pub fn saveState(path: []const u8, state: *const State) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    var temp_path_buf: [std.fs.max_path_bytes + ".tmp".len]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&temp_path_buf, "{s}.tmp", .{path});
    errdefer std.fs.deleteFileAbsolute(temp_path) catch {};

    {
        const file = try std.fs.createFileAbsolute(temp_path, .{ .truncate = true });
        defer file.close();

        var buf: [1024]u8 = undefined;
        var file_writer = file.writer(&buf);
        const writer = &file_writer.interface;

        try writer.writeAll("{\"last_checked_at\":");
        try writer.print("{d}", .{state.last_checked_at});
        try writer.writeAll(",\"last_seen_version\":");
        try writeOptionalJsonString(writer, state.last_seen_version);
        try writer.writeAll(",\"release_feed_url\":");
        try writeOptionalJsonString(writer, state.release_feed_url);
        try writer.writeAll(",\"release_url\":");
        try writeOptionalJsonString(writer, state.release_url);
        try writer.writeAll(",\"dismissed_version\":");
        try writeOptionalJsonString(writer, state.dismissed_version);
        try writer.writeAll(",\"staged_version\":");
        try writeOptionalJsonString(writer, state.staged_version);
        try writer.writeAll(",\"staged_kind\":");
        try writeOptionalEnum(writer, state.staged_kind);
        try writer.writeAll(",\"staged_installer_path\":");
        try writeOptionalJsonString(writer, state.staged_installer_path);
        try writer.writeAll(",\"staged_portable_path\":");
        try writeOptionalJsonString(writer, state.staged_portable_path);
        try writer.writeAll(",\"staged_payload_path\":");
        try writeOptionalJsonString(writer, state.staged_payload_path);
        try writer.writeAll(",\"staged_sha256\":");
        try writeOptionalJsonString(writer, state.staged_sha256);
        try writer.writeAll(",\"staged_feed_url\":");
        try writeOptionalJsonString(writer, state.staged_feed_url);
        try writer.writeAll(",\"staged_at\":");
        try writer.print("{d}", .{state.staged_at});
        try writer.writeAll(",\"apply_requested_at\":");
        try writer.print("{d}", .{state.apply_requested_at});
        try writer.writeAll(",\"portable_apply_phase\":");
        try writeOptionalEnum(writer, state.portable_apply_phase);
        try writer.writeAll(",\"portable_backup_path\":");
        try writeOptionalJsonString(writer, state.portable_backup_path);
        try writer.writeAll(",\"portable_confirmation_token\":");
        try writeOptionalJsonString(writer, state.portable_confirmation_token);
        try writer.writeAll(",\"portable_watcher_pid\":");
        try writer.print("{d}", .{state.portable_watcher_pid});
        try writer.writeAll(",\"portable_watcher_started_at\":");
        try writer.print("{d}", .{state.portable_watcher_started_at});
        try writer.writeAll("}");
        try writer.flush();
        try file.sync();
    }
    try std.fs.renameAbsolute(temp_path, path);
}

pub fn recordDismissal(alloc: Allocator, path: []const u8, version_text: []const u8) !void {
    const state_lock = try openStateLock(path);
    defer state_lock.close();
    var state = try loadState(alloc, path);
    defer state.deinit(alloc);
    if (state.dismissed_version) |value| alloc.free(value);
    state.dismissed_version = try alloc.dupe(u8, version_text);
    try saveState(path, &state);
}

pub fn clearDismissal(alloc: Allocator, path: []const u8) !void {
    const state_lock = try openStateLock(path);
    defer state_lock.close();
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
) !CheckOutcome {
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    const now = if (options.now > 0) options.now else std.time.timestamp();

    // Staged installers, the dismissal, and the cached release all describe
    // one feed. Once the effective feed URL changes, none of them say
    // anything about the new feed, and leaving the staged installer around
    // would keep an Install action from the old feed live. Drop them before
    // anything else looks at them.
    const feed_state_invalidated = try invalidateForeignFeedState(
        alloc,
        state_path,
        &state,
        options.release_feed_url,
    );

    if (!options.force and !shouldCheckNetwork(&state, options.release_feed_url, now)) {
        if (try cachedAvailableRelease(alloc, &state, options.current_version, options.respect_dismissal)) |release| {
            return .{ .result = .{ .update_available = release }, .feed_state_invalidated = feed_state_invalidated };
        }
        return .{ .result = .throttled, .feed_state_invalidated = feed_state_invalidated };
    }

    var release = try fetchLatestStableRelease(alloc, options.release_feed_url);
    errdefer release.deinit(alloc);

    {
        const state_lock = try openStateLock(state_path);
        defer state_lock.close();
        var fresh = try loadState(alloc, state_path);
        errdefer fresh.deinit(alloc);
        fresh.last_checked_at = now;
        replaceOptionalOwned(alloc, &fresh.last_seen_version, try alloc.dupe(u8, release.version_text));
        replaceOptionalOwned(alloc, &fresh.release_feed_url, try alloc.dupe(u8, options.release_feed_url));
        replaceOptionalOwned(alloc, &fresh.release_url, try alloc.dupe(u8, release.release_url));
        try saveState(state_path, &fresh);
        state.deinit(alloc);
        state = fresh;
    }

    const latest_version = try parseVersionText(release.version_text);
    if (options.current_version.order(latest_version) != .lt) {
        release.deinit(alloc);
        return .{ .result = .up_to_date, .feed_state_invalidated = feed_state_invalidated };
    }

    if (options.respect_dismissal) {
        if (state.dismissed_version) |dismissed| {
            if (std.mem.eql(u8, dismissed, release.version_text)) {
                release.deinit(alloc);
                return .{ .result = .up_to_date, .feed_state_invalidated = feed_state_invalidated };
            }
        }
    }

    return .{ .result = .{ .update_available = release }, .feed_state_invalidated = feed_state_invalidated };
}

/// Drop state that belongs to a feed other than `release_feed_url` and
/// persist the result. Returns true when a staged install was discarded.
fn invalidateForeignFeedState(
    alloc: Allocator,
    state_path: []const u8,
    state: *State,
    release_feed_url: []const u8,
) !bool {
    const cached_feed_url = state.release_feed_url orelse return false;
    if (std.mem.eql(u8, cached_feed_url, release_feed_url)) return false;

    var dirty = false;
    if (state.staged_version != null or
        state.staged_installer_path != null or
        state.staged_sha256 != null)
    {
        // Best-effort: the download can be re-staged from the new feed, and
        // a leftover file under the stage directory is never trusted without
        // the metadata that clearStagedInstall removes.
        if (state.staged_installer_path) |path| {
            if (std.fs.path.isAbsolute(path)) {
                std.fs.deleteFileAbsolute(path) catch {};
            }
        }
    }
    if (state.clearStagedInstall(alloc)) dirty = true;
    if (state.dismissed_version) |value| {
        alloc.free(value);
        state.dismissed_version = null;
        dirty = true;
    }
    if (state.last_seen_version) |value| {
        alloc.free(value);
        state.last_seen_version = null;
        dirty = true;
    }
    if (state.release_url) |value| {
        alloc.free(value);
        state.release_url = null;
        dirty = true;
    }
    if (dirty) try saveState(state_path, state);
    return dirty;
}

pub fn stageWindowsInstall(
    alloc: Allocator,
    state_path: []const u8,
    release_feed_url: []const u8,
    release: *const Release,
    kind: portable_apply.StagedKind,
) !StagedWindowsInstall {
    const candidate = release.windows_install orelse return error.WindowsInstallNotEligible;
    if (!std.fs.path.isAbsolute(state_path)) return error.InvalidStatePath;
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    if (state.portable_apply_phase != null) return error.PortableUpdateTransactionActive;

    const asset_name, const asset_url = switch (kind) {
        .installer => .{ candidate.installer_name, candidate.installer_url },
        .portable => .{
            candidate.portable_name orelse return error.PortableInstallNotEligible,
            candidate.portable_url orelse return error.PortableInstallNotEligible,
        },
    };
    if (kind == .portable and
        (candidate.portable_manifest_name == null or candidate.portable_manifest_url == null))
    {
        return error.PortablePayloadManifestUnavailable;
    }

    const state_dir = std.fs.path.dirname(state_path) orelse return error.InvalidStatePath;
    const stage_dir = try std.fs.path.join(alloc, &.{ state_dir, "updates", release.version_text });
    defer alloc.free(stage_dir);
    try std.fs.cwd().makePath(stage_dir);
    if (kind == .portable) try validatePortableStageDirectory(alloc, stage_dir);

    const artifact_path = try std.fs.path.join(alloc, &.{ stage_dir, asset_name });
    errdefer alloc.free(artifact_path);
    const checksums_path = try std.fs.path.join(alloc, &.{ stage_dir, windowsChecksumsAssetName() });
    defer alloc.free(checksums_path);
    const manifest_path = if (kind == .portable) manifest: {
        const manifest_name = candidate.portable_manifest_name.?;
        break :manifest try std.fs.path.join(alloc, &.{ stage_dir, manifest_name });
    } else null;
    defer if (manifest_path) |value| alloc.free(value);

    try downloadUrlToFile(alloc, candidate.checksums_url, checksums_path);
    if (manifest_path) |path| {
        try downloadUrlToFile(alloc, candidate.portable_manifest_url.?, path);
        try verifyPortablePayloadManifest(path);
    }
    try downloadUrlToFile(alloc, asset_url, artifact_path);

    const checksums = try std.fs.cwd().readFileAlloc(alloc, checksums_path, 1024 * 1024);
    defer alloc.free(checksums);
    const expected_digest = try parseExpectedSha256(checksums, asset_name);

    const actual_digest = try sha256File(artifact_path);
    if (!std.mem.eql(u8, &expected_digest, &actual_digest)) return error.InstallerChecksumMismatch;

    const payload_path = switch (kind) {
        .installer => installer: {
            if (builtin.os.tag == .windows) {
                try verifyAuthenticodeSignature(artifact_path, null);
            } else {
                return error.AuthenticodeRequiresWindows;
            }
            break :installer null;
        },
        .portable => try extractAndVerifyPortableZip(alloc, artifact_path, stage_dir, manifest_path.?),
    };
    errdefer if (payload_path) |value| alloc.free(value);

    // Downgrade guard: a feed can claim any tag while serving an older but
    // legitimately signed build, so the binary's own version must be at least
    // the version the feed claimed. For the portable channel the version-bearing
    // binary is the extracted noctty.exe.
    const version_check_path = switch (kind) {
        .installer => try alloc.dupe(u8, artifact_path),
        .portable => try std.fs.path.join(alloc, &.{ payload_path.?, "noctty.exe" }),
    };
    defer alloc.free(version_check_path);
    const installer_version = try readWindowsFileVersion(alloc, version_check_path);
    const claimed_version = try parseVersionText(release.version_text);
    if (!installerVersionAtLeastClaim(installer_version, claimed_version)) {
        return error.InstallerVersionOlderThanRelease;
    }

    const sha256_hex = try alloc.dupe(u8, &std.fmt.bytesToHex(actual_digest, .lower));
    errdefer alloc.free(sha256_hex);

    replaceOptionalOwned(alloc, &state.staged_version, try alloc.dupe(u8, release.version_text));
    state.staged_kind = kind;
    clearOptionalOwned(alloc, &state.staged_installer_path);
    clearOptionalOwned(alloc, &state.staged_portable_path);
    clearOptionalOwned(alloc, &state.staged_payload_path);
    switch (kind) {
        .installer => replaceOptionalOwned(alloc, &state.staged_installer_path, try alloc.dupe(u8, artifact_path)),
        .portable => {
            replaceOptionalOwned(alloc, &state.staged_portable_path, try alloc.dupe(u8, artifact_path));
            replaceOptionalOwned(alloc, &state.staged_payload_path, try alloc.dupe(u8, payload_path.?));
        },
    }
    replaceOptionalOwned(alloc, &state.staged_sha256, try alloc.dupe(u8, sha256_hex));
    replaceOptionalOwned(alloc, &state.staged_feed_url, try alloc.dupe(u8, release_feed_url));
    state.staged_at = std.time.timestamp();
    state.apply_requested_at = 0;
    state.portable_apply_phase = null;
    clearOptionalOwned(alloc, &state.portable_backup_path);
    clearOptionalOwned(alloc, &state.portable_confirmation_token);
    state.portable_watcher_pid = 0;
    state.portable_watcher_started_at = 0;
    try saveState(state_path, &state);

    return .{
        .kind = kind,
        .version_text = try alloc.dupe(u8, release.version_text),
        .artifact_path = artifact_path,
        .payload_path = payload_path,
        .sha256_hex = sha256_hex,
    };
}

/// `release_feed_url` is the feed in effect right now. A staged installer
/// that came from a different feed is refused rather than applied: the user
/// re-pointed the updater, so nothing the old feed vouched for is still
/// authoritative.
pub fn verifyStagedWindowsInstall(
    alloc: Allocator,
    state_path: []const u8,
    release_feed_url: []const u8,
    expected_kind: portable_apply.StagedKind,
) !StagedWindowsInstall {
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);

    if (!std.mem.eql(u8, state.stagedFeedUrl(), release_feed_url)) {
        return error.StagedInstallFeedMismatch;
    }

    const version_text = state.staged_version orelse return error.NoStagedWindowsInstall;
    const kind = state.staged_kind orelse return error.StagedKindMismatch;
    if (kind != expected_kind) return error.StagedKindMismatch;
    var portable_layout: ?PortableStageLayout = null;
    defer if (portable_layout) |*layout| layout.deinit(alloc);
    if (kind == .portable) {
        portable_layout = try portableStageLayout(alloc, state_path, &state);
    }
    const artifact_path = switch (kind) {
        .installer => state.staged_installer_path orelse return error.NoStagedWindowsInstall,
        .portable => portable_layout.?.artifact_path,
    };
    const sha256_hex = state.staged_sha256 orelse return error.NoStagedWindowsInstall;
    if (!std.fs.path.isAbsolute(artifact_path)) return error.InvalidStagedInstallerPath;

    const stage_dir = switch (kind) {
        .installer => std.fs.path.dirname(artifact_path) orelse return error.InvalidStagedInstallerPath,
        .portable => portable_layout.?.stage_dir,
    };
    var locked_stage_dir = try openLockedStageDirectory(stage_dir);
    errdefer locked_stage_dir.close();
    if (!try lockedHandleMatchesPath(alloc, stage_dir, locked_stage_dir.handle)) {
        return error.InvalidStagedInstallerPath;
    }

    var locked_file = try openLockedInstaller(artifact_path);
    errdefer locked_file.close();
    if (!try lockedHandleMatchesPath(alloc, artifact_path, locked_file.handle)) {
        return error.InvalidStagedInstallerPath;
    }

    const expected_digest = try parseSha256Hex(sha256_hex);
    const actual_digest = try sha256OpenFile(&locked_file);
    if (!std.mem.eql(u8, &expected_digest, &actual_digest)) return error.InstallerChecksumMismatch;

    const payload_path = switch (kind) {
        .installer => installer: {
            if (builtin.os.tag == .windows) {
                try verifyAuthenticodeSignature(artifact_path, locked_file.handle);
            } else {
                return error.AuthenticodeRequiresWindows;
            }
            break :installer null;
        },
        .portable => try extractAndVerifyPortableZip(
            alloc,
            artifact_path,
            stage_dir,
            portable_layout.?.manifest_path,
        ),
    };
    errdefer if (payload_path) |value| alloc.free(value);

    return .{
        .kind = kind,
        .version_text = try alloc.dupe(u8, version_text),
        .artifact_path = try alloc.dupe(u8, artifact_path),
        .payload_path = payload_path,
        .sha256_hex = try alloc.dupe(u8, sha256_hex),
        .locked_stage_dir = locked_stage_dir,
        .locked_file = locked_file,
    };
}

pub fn recordStagedApplyRequested(alloc: Allocator, state_path: []const u8, now: i64) !void {
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);

    if (state.staged_kind != .installer or
        state.staged_version == null or
        state.staged_installer_path == null or
        state.staged_sha256 == null)
    {
        return error.NoStagedWindowsInstall;
    }

    state.apply_requested_at = if (now > 0) now else std.time.timestamp();
    try saveState(state_path, &state);
}

pub fn hasStagedWindowsInstall(
    alloc: Allocator,
    state_path: []const u8,
    expected_kind: portable_apply.StagedKind,
) bool {
    var state = loadState(alloc, state_path) catch return false;
    defer state.deinit(alloc);
    if (state.staged_kind != expected_kind or
        state.staged_version == null or
        state.staged_sha256 == null) return false;
    return switch (expected_kind) {
        .installer => state.staged_installer_path != null,
        .portable => portable: {
            if (state.staged_portable_path == null or state.staged_payload_path == null) break :portable false;
            var layout = portableStageLayout(alloc, state_path, &state) catch break :portable false;
            defer layout.deinit(alloc);
            const stat = std.fs.cwd().statFile(layout.manifest_path) catch break :portable false;
            break :portable stat.kind == .file;
        },
    };
}

const PortableStageLayout = struct {
    stage_dir: []u8,
    artifact_path: []u8,
    payload_path: []u8,
    manifest_path: []u8,
    backup_path: []u8,
    displaced_path: []u8,
    helper_path: []u8,
    launch_lock_path: []u8,

    fn deinit(self: *PortableStageLayout, alloc: Allocator) void {
        alloc.free(self.stage_dir);
        alloc.free(self.artifact_path);
        alloc.free(self.payload_path);
        alloc.free(self.manifest_path);
        alloc.free(self.backup_path);
        alloc.free(self.displaced_path);
        alloc.free(self.helper_path);
        alloc.free(self.launch_lock_path);
        self.* = undefined;
    }
};

fn portableStageLayout(
    alloc: Allocator,
    state_path: []const u8,
    state: *const State,
) !PortableStageLayout {
    if (!std.fs.path.isAbsolute(state_path)) return error.InvalidStatePath;
    const state_dir = std.fs.path.dirname(state_path) orelse return error.InvalidStatePath;
    const version_text = state.staged_version orelse return error.NoStagedPortableInstall;
    if (std.mem.indexOfScalar(u8, version_text, '/') != null or
        std.mem.indexOfScalar(u8, version_text, '\\') != null or
        std.mem.indexOfScalar(u8, version_text, ':') != null or
        !std.mem.eql(u8, std.fs.path.basename(version_text), version_text))
    {
        return error.InvalidStagedVersion;
    }
    _ = parseVersionText(version_text) catch return error.InvalidStagedVersion;

    const stage_dir = try std.fs.path.join(alloc, &.{ state_dir, "updates", version_text });
    errdefer alloc.free(stage_dir);
    const artifact_name = try std.fmt.allocPrint(
        alloc,
        "noctty-{s}-windows-{s}-portable.zip",
        .{ version_text, windowsInstallerArch() },
    );
    defer alloc.free(artifact_name);
    const artifact_path = try std.fs.path.join(alloc, &.{ stage_dir, artifact_name });
    errdefer alloc.free(artifact_path);
    const payload_path = try std.fs.path.join(alloc, &.{ stage_dir, "payload", "noctty" });
    errdefer alloc.free(payload_path);
    const manifest_name = try portableManifestNameAlloc(alloc, version_text);
    defer alloc.free(manifest_name);
    const manifest_path = try std.fs.path.join(alloc, &.{ stage_dir, manifest_name });
    errdefer alloc.free(manifest_path);
    const backup_path = try std.fs.path.join(alloc, &.{ stage_dir, "backup" });
    errdefer alloc.free(backup_path);
    const displaced_path = try std.fs.path.join(alloc, &.{ stage_dir, "displaced" });
    errdefer alloc.free(displaced_path);
    const helper_path = try std.fs.path.join(alloc, &.{ stage_dir, "portable-update-helper.exe" });
    errdefer alloc.free(helper_path);
    const launch_lock_path = try std.fs.path.join(alloc, &.{ stage_dir, "portable-update-launch.lock" });
    errdefer alloc.free(launch_lock_path);

    if (!windowsPathEqual(state.staged_portable_path orelse return error.NoStagedPortableInstall, artifact_path) or
        !windowsPathEqual(state.staged_payload_path orelse return error.NoStagedPortableInstall, payload_path) or
        (state.portable_backup_path != null and
            !windowsPathEqual(state.portable_backup_path.?, backup_path)))
    {
        return error.InvalidPortableUpdatePath;
    }

    return .{
        .stage_dir = stage_dir,
        .artifact_path = artifact_path,
        .payload_path = payload_path,
        .manifest_path = manifest_path,
        .backup_path = backup_path,
        .displaced_path = displaced_path,
        .helper_path = helper_path,
        .launch_lock_path = launch_lock_path,
    };
}

fn windowsPathEqual(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn validatePortableStageDirectory(alloc: Allocator, stage_dir: []const u8) !void {
    var locked = try openLockedStageDirectory(stage_dir);
    defer locked.close();
    if (!try lockedHandleMatchesPath(alloc, stage_dir, locked.handle)) {
        return error.InvalidPortableUpdatePath;
    }
}

fn validatePortableInstallAndStateRoots(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
) !void {
    if (!std.fs.path.isAbsolute(state_path) or !std.fs.path.isAbsolute(install_root)) {
        return error.InvalidPortableUpdatePath;
    }
    const expected_state_path = try std.fs.path.join(alloc, &.{ install_root, "update-state.json" });
    defer alloc.free(expected_state_path);
    if (!windowsPathEqual(state_path, expected_state_path)) {
        return error.InvalidPortableUpdatePath;
    }
}

pub fn recordPortableApplyPending(alloc: Allocator, state_path: []const u8, now: i64) !void {
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    if (state.staged_kind != .portable or
        state.staged_version == null or
        state.staged_portable_path == null or
        state.staged_payload_path == null or
        state.staged_sha256 == null)
    {
        return error.NoStagedPortableInstall;
    }
    if (state.portable_apply_phase != null) return error.InvalidPortableApplyTransition;

    var layout = try portableStageLayout(alloc, state_path, &state);
    defer layout.deinit(alloc);
    try validatePortableStageDirectory(alloc, layout.stage_dir);
    try portable_apply.cleanupBackup(layout.backup_path);
    try portable_apply.cleanupUpdatePath(layout.displaced_path);
    var token_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&token_bytes);
    const token = try alloc.dupe(u8, &std.fmt.bytesToHex(token_bytes, .lower));
    var token_owned = true;
    errdefer if (token_owned) alloc.free(token);

    replaceOptionalOwned(alloc, &state.portable_backup_path, try alloc.dupe(u8, layout.backup_path));
    replaceOptionalOwned(alloc, &state.portable_confirmation_token, token);
    token_owned = false;
    state.portable_apply_phase = .pending;
    state.portable_watcher_pid = 0;
    state.portable_watcher_started_at = 0;
    state.apply_requested_at = if (now > 0) now else std.time.timestamp();
    try saveState(state_path, &state);
}

const portable_helper_arg = "--noctty-portable-update-helper";
const portable_confirmation_env = "NOCTTY_PORTABLE_UPDATE_CONFIRM";
const portable_failure_env = "NOCTTY_PORTABLE_UPDATE_FAILURE";
const portable_bypass_env = "NOCTTY_PORTABLE_UPDATE_BYPASS";

pub fn maybeRunPortableUpdateHelper(alloc: Allocator) !?u8 {
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2 or !std.mem.eql(u8, args[1], portable_helper_arg)) return null;
    if (args.len < 6) return 1;

    const parent_pid = std.fmt.parseInt(u32, args[5], 10) catch return 1;
    const mode = std.meta.stringToEnum(PortableHelperMode, args[4]) orelse return 1;
    const original_args = args[6..];
    claimPortableHelperWatcher(alloc, args[2], args[3], mode) catch |err|
        return try recoverPendingPortableFailure(alloc, args[2], args[3], original_args, err);
    waitForProcessExit(parent_pid, 30_000) catch |err|
        return try recoverPendingPortableFailure(alloc, args[2], args[3], original_args, err);
    return runPortableUpdateHelper(alloc, args[2], args[3], mode, original_args) catch |err|
        try recoverPendingPortableFailure(alloc, args[2], args[3], original_args, err);
}

pub fn preflightPortableUpdateStartup(
    alloc: Allocator,
    running_version: []const u8,
) !bool {
    if (builtin.os.tag != .windows) return false;
    if (std.process.getEnvVarOwned(alloc, portable_bypass_env)) |value| {
        alloc.free(value);
        _ = internal_os.unsetenv(portable_bypass_env);
        return false;
    } else |_| {}
    const portable_root = try internal_os.xdg.portableRoot(alloc) orelse return false;
    defer alloc.free(portable_root);
    const state_path = try defaultStatePath(alloc);
    defer alloc.free(state_path);
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    const phase = state.portable_apply_phase orelse return false;
    const target_version = state.staged_version orelse {
        if (phase != .pending) return error.NoStagedPortableInstall;
        _ = abandonPendingPortableApply(alloc, state_path, portable_root) catch false;
        setPortableFailureEnvironment(alloc, error.NoStagedPortableInstall) catch {};
        return false;
    };
    if (state.staged_kind != .portable) {
        if (phase != .pending) return error.StagedKindMismatch;
        _ = abandonPendingPortableApply(alloc, state_path, portable_root) catch false;
        setPortableFailureEnvironment(alloc, error.StagedKindMismatch) catch {};
        return false;
    }

    const env_token = std.process.getEnvVarOwned(alloc, portable_confirmation_env) catch null;
    defer if (env_token) |value| alloc.free(value);
    const token_matches = if (state.portable_confirmation_token) |expected|
        if (env_token) |actual| std.mem.eql(u8, expected, actual) else false
    else
        false;
    const watcher_active = portableStateWatcherIsActive(&state);
    if (phase == .pending and state.portable_watcher_pid != 0 and !watcher_active) {
        _ = abandonPendingPortableApply(alloc, state_path, portable_root) catch false;
        setPortableFailureEnvironment(alloc, error.PortableUpdateHelperFailed) catch {};
        return false;
    }
    if (watcher_active and !(phase == .swapped and token_matches)) {
        // The helper still owns the bounded failure window. Concurrent starts
        // must not clean or roll back its backup while it is watching.
        return true;
    }

    const decision = switch (phase) {
        .pending => try portable_apply.decide(.portable, phase, .next_launch),
        .swapped => try portable_apply.decide(.portable, phase, .{ .startup = .{
            .running_version = running_version,
            .target_version = target_version,
            .confirmation_token_matches = token_matches,
        } }),
        .confirmed => try portable_apply.decide(.portable, phase, .next_launch),
        .rollback => try portable_apply.decide(.portable, phase, .next_launch),
    };
    return switch (decision) {
        .continue_for_confirmation => false,
        .swap => launchPortableHelper(alloc, state_path, portable_root, .swap) catch |err| {
            _ = abandonPendingPortableApply(alloc, state_path, portable_root) catch false;
            setPortableFailureEnvironment(alloc, err) catch {};
            return false;
        },
        .rollback => launchPortableHelper(alloc, state_path, portable_root, .rollback),
        .cleanup => cleanup: {
            finalizePortableConfirmation(alloc, state_path) catch |err| {
                log.warn("portable update confirmation cleanup deferred err={}", .{err});
            };
            break :cleanup false;
        },
        else => error.InvalidPortableApplyTransition,
    };
}

pub fn takePortableUpdateFailure(alloc: Allocator) !?[]u8 {
    const failure = std.process.getEnvVarOwned(alloc, portable_failure_env) catch return null;
    defer alloc.free(failure);
    _ = internal_os.unsetenv(portable_failure_env);
    if (std.mem.eql(u8, failure, @errorName(error.PortableUpdateRecoveryUnavailable))) {
        const message = try alloc.dupe(
            u8,
            "Portable update recovery files are missing. Noctty abandoned automatic rollback and launched the installed build; reinstall or update manually if it does not work correctly.",
        );
        return message;
    }
    const message = try std.fmt.allocPrint(
        alloc,
        "The portable update could not be applied ({s}); the current noctty build is still running. Open the release page to update manually.",
        .{failure},
    );
    return message;
}

fn setPortableFailureEnvironment(alloc: Allocator, err: anyerror) !void {
    const value = try alloc.dupeZ(u8, @errorName(err));
    defer alloc.free(value);
    if (internal_os.setenv(portable_failure_env, value) < 0) return error.EnvironmentUpdateFailed;
}

pub fn confirmPortableUpdateStartup(
    alloc: Allocator,
    running_version: []const u8,
) !void {
    if (builtin.os.tag != .windows) return;
    const portable_root = try internal_os.xdg.portableRoot(alloc) orelse return;
    alloc.free(portable_root);
    const state_path = try defaultStatePath(alloc);
    defer alloc.free(state_path);
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    if (state.portable_apply_phase != .swapped) return;
    const target_version = state.staged_version orelse return error.NoStagedPortableInstall;
    const env_token = std.process.getEnvVarOwned(alloc, portable_confirmation_env) catch return;
    defer alloc.free(env_token);
    const expected_token = state.portable_confirmation_token orelse return;
    const decision = try portable_apply.confirmationDecision(
        state.staged_kind,
        .swapped,
        running_version,
        target_version,
        std.mem.eql(u8, env_token, expected_token),
    );
    if (decision != .confirm) return error.PortableUpdateConfirmationFailed;

    state.portable_apply_phase = .confirmed;
    try saveState(state_path, &state);
}

const PortableHelperMode = enum { swap, rollback };

fn launchPortableHelper(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
    mode: PortableHelperMode,
) !bool {
    if (try abandonUnrecoverablePortableApply(alloc, state_path, install_root)) {
        setPortableFailureEnvironment(alloc, error.PortableUpdateRecoveryUnavailable) catch {};
        return false;
    }
    var initial_state = try loadState(alloc, state_path);
    defer initial_state.deinit(alloc);
    var initial_layout = try portableStageLayout(alloc, state_path, &initial_state);
    defer initial_layout.deinit(alloc);
    try validatePortableInstallAndStateRoots(alloc, state_path, install_root);
    try validatePortableStageDirectory(alloc, initial_layout.stage_dir);

    var launch_lock = (try openPortableLaunchLock(initial_layout.launch_lock_path, true)) orelse
        return true;
    defer launch_lock.close();

    // Re-read only after winning the lock. Another launcher may have completed
    // the handoff between this process's preflight read and lock acquisition.
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    var layout = try portableStageLayout(alloc, state_path, &state);
    defer layout.deinit(alloc);
    if (portableStateWatcherIsActive(&state)) return true;
    const phase = state.portable_apply_phase orelse return false;
    switch (mode) {
        .swap => if (phase != .pending) return true,
        .rollback => if (phase != .swapped and phase != .confirmed and phase != .rollback) return true,
    }

    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);
    try verifyAuthenticodeSignature(self_path, null);
    try std.fs.copyFileAbsolute(self_path, layout.helper_path, .{});
    try verifyAuthenticodeSignature(layout.helper_path, null);

    const parent_pid = try std.fmt.allocPrint(alloc, "{d}", .{std.os.windows.GetCurrentProcessId()});
    defer alloc.free(parent_pid);
    const original_process_args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, original_process_args);
    var helper_args: std.ArrayList([]const u8) = .empty;
    defer helper_args.deinit(alloc);
    try helper_args.appendSlice(alloc, &.{
        layout.helper_path,
        portable_helper_arg,
        state_path,
        install_root,
        @tagName(mode),
        parent_pid,
    });
    try helper_args.appendSlice(alloc, original_process_args[1..]);
    var child = std.process.Child.init(helper_args.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
    var child_open = true;
    errdefer if (child_open) {
        std.os.windows.TerminateProcess(child.id, 1) catch {};
        std.os.windows.CloseHandle(child.thread_handle);
        std.os.windows.CloseHandle(child.id);
    };
    const child_pid = GetProcessId(child.id);
    if (child_pid == 0) return error.PortableUpdateWatcherIdentityUnavailable;
    const child_started_at = processCreationTime(child.id) orelse
        return error.PortableUpdateWatcherIdentityUnavailable;
    state.portable_watcher_pid = child_pid;
    state.portable_watcher_started_at = child_started_at;
    try saveState(state_path, &state);
    std.os.windows.CloseHandle(child.thread_handle);
    std.os.windows.CloseHandle(child.id);
    child_open = false;
    return true;
}

fn openPortableLaunchLock(path: []const u8, nonblocking: bool) !?std.fs.File {
    return std.fs.createFileAbsolute(path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = nonblocking,
    }) catch |err| switch (err) {
        error.WouldBlock => null,
        else => return err,
    };
}

fn claimPortableHelperWatcher(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
    mode: PortableHelperMode,
) !void {
    var initial_state = try loadState(alloc, state_path);
    defer initial_state.deinit(alloc);
    var initial_layout = try portableStageLayout(alloc, state_path, &initial_state);
    defer initial_layout.deinit(alloc);
    try validatePortableInstallAndStateRoots(alloc, state_path, install_root);
    try validatePortableStageDirectory(alloc, initial_layout.stage_dir);

    var launch_lock = (try openPortableLaunchLock(initial_layout.launch_lock_path, false)).?;
    defer launch_lock.close();

    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    var layout = try portableStageLayout(alloc, state_path, &state);
    defer layout.deinit(alloc);
    const phase = state.portable_apply_phase orelse return error.InvalidPortableApplyTransition;
    switch (mode) {
        .swap => if (phase != .pending) return error.InvalidPortableApplyTransition,
        .rollback => if (phase != .swapped and phase != .confirmed and phase != .rollback)
            return error.InvalidPortableApplyTransition,
    }

    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);
    if (!windowsPathEqual(self_path, layout.helper_path)) {
        return error.InvalidPortableUpdateHelperPath;
    }
    const self_pid = std.os.windows.GetCurrentProcessId();
    const self_started_at = processCreationTime(std.os.windows.GetCurrentProcess()) orelse
        return error.PortableUpdateWatcherIdentityUnavailable;
    if (portableStateWatcherIsActive(&state) and
        (state.portable_watcher_pid != self_pid or
            state.portable_watcher_started_at != self_started_at))
    {
        return error.PortableUpdateTransactionOwned;
    }
    state.portable_watcher_pid = self_pid;
    state.portable_watcher_started_at = self_started_at;
    try saveState(state_path, &state);
}

fn runPortableUpdateHelper(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
    mode: PortableHelperMode,
    original_args: []const []const u8,
) !u8 {
    var invocation_state = try loadState(alloc, state_path);
    defer invocation_state.deinit(alloc);
    var invocation_layout = try portableStageLayout(alloc, state_path, &invocation_state);
    defer invocation_layout.deinit(alloc);
    try validatePortableInstallAndStateRoots(alloc, state_path, install_root);
    try validatePortableStageDirectory(alloc, invocation_layout.stage_dir);
    const self_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(self_path);
    if (!windowsPathEqual(self_path, invocation_layout.helper_path)) {
        return error.InvalidPortableUpdateHelperPath;
    }
    const watcher_started_at = invocation_state.portable_watcher_started_at;
    if (!portableStateWatcherIsActive(&invocation_state) or
        invocation_state.portable_watcher_pid != std.os.windows.GetCurrentProcessId())
    {
        return error.PortableUpdateTransactionOwned;
    }

    return switch (mode) {
        .rollback => try rollbackPortableUpdateAndRelaunch(alloc, state_path, install_root, original_args),
        .swap => swap: {
            const state_lock = try openStateLock(state_path);
            var state_locked = true;
            defer if (state_locked) state_lock.close();
            var state = try loadState(alloc, state_path);
            defer state.deinit(alloc);
            if (state.staged_kind != .portable or state.portable_apply_phase != .pending)
                return error.StagedKindMismatch;
            const backup_path = state.portable_backup_path orelse return error.NoStagedPortableInstall;
            const confirmation_token = state.portable_confirmation_token orelse return error.NoStagedPortableInstall;

            var staged = try verifyStagedWindowsInstall(alloc, state_path, .portable);
            var staged_open = true;
            defer if (staged_open) staged.deinit(alloc);
            const payload_path = staged.payload_path orelse return error.IncompletePortablePayload;

            try portable_apply.prepareBackup(alloc, install_root, backup_path);
            _ = try portable_apply.decide(.portable, .pending, .backup_completed);
            state.portable_apply_phase = .swapped;
            state.portable_watcher_pid = std.os.windows.GetCurrentProcessId();
            state.portable_watcher_started_at = watcher_started_at;
            try saveState(state_path, &state);
            state_lock.close();
            state_locked = false;
            portable_apply.swapPayload(
                alloc,
                install_root,
                payload_path,
                backup_path,
                invocation_layout.displaced_path,
            ) catch |err| {
                markPortableRollback(alloc, state_path) catch {};
                _ = rollbackPortableUpdateAndRelaunch(alloc, state_path, install_root, original_args) catch {};
                return err;
            };
            staged.deinit(alloc);
            staged_open = false;

            var child = spawnInstalledNoctty(
                alloc,
                install_root,
                original_args,
                confirmation_token,
                null,
            ) catch |err| {
                try markPortableRollback(alloc, state_path);
                _ = try rollbackPortableUpdateAndRelaunch(alloc, state_path, install_root, original_args);
                return err;
            };
            std.os.windows.WaitForSingleObject(child.id, 15_000) catch |err| switch (err) {
                error.WaitTimeOut => {
                    std.os.windows.CloseHandle(child.thread_handle);
                    std.os.windows.CloseHandle(child.id);
                    var after = try loadState(alloc, state_path);
                    const confirmed = after.portable_apply_phase == .confirmed;
                    after.deinit(alloc);
                    if (confirmed) try finalizePortableConfirmation(alloc, state_path);
                    break :swap 0;
                },
                else => return err,
            };
            const term = try child.wait();
            var after = try loadState(alloc, state_path);
            defer after.deinit(alloc);
            const failed = switch (term) {
                .Exited => |code| code != 0,
                else => true,
            };
            if (failed and
                (after.portable_apply_phase == .swapped or after.portable_apply_phase == .confirmed))
            {
                try markPortableRollback(alloc, state_path);
                break :swap try rollbackPortableUpdateAndRelaunch(alloc, state_path, install_root, original_args);
            }
            if (!failed and after.portable_apply_phase == .confirmed) {
                try finalizePortableConfirmation(alloc, state_path);
                break :swap 0;
            }
            break :swap 0;
        },
    };
}

fn markPortableRollback(alloc: Allocator, state_path: []const u8) !void {
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    if (state.portable_apply_phase != .swapped and state.portable_apply_phase != .confirmed and
        state.portable_apply_phase != .rollback)
    {
        return error.InvalidPortableApplyTransition;
    }
    state.portable_apply_phase = .rollback;
    try saveState(state_path, &state);
}

fn abandonPendingPortableApply(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
) !bool {
    try validatePortableInstallAndStateRoots(alloc, state_path, install_root);
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    if (state.staged_kind != .portable or state.portable_apply_phase != .pending) return false;
    state.portable_apply_phase = null;
    state.apply_requested_at = 0;
    state.portable_watcher_pid = 0;
    state.portable_watcher_started_at = 0;
    clearOptionalOwned(alloc, &state.portable_confirmation_token);
    try saveState(state_path, &state);
    return true;
}

fn abandonUnrecoverablePortableApply(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
) !bool {
    try validatePortableInstallAndStateRoots(alloc, state_path, install_root);
    const state_lock = try openStateLock(state_path);
    defer state_lock.close();
    var state = try loadState(alloc, state_path);
    defer state.deinit(alloc);
    if (state.staged_kind != .portable) return false;
    const phase = state.portable_apply_phase orelse return false;
    if (phase != .swapped and phase != .rollback) return false;
    if (portableStateWatcherIsActive(&state)) return false;

    var layout = try portableStageLayout(alloc, state_path, &state);
    defer layout.deinit(alloc);
    portable_apply.validateBackup(alloc, layout.backup_path) catch |err| switch (err) {
        error.FileNotFound, error.IncompletePortableUpdateBackup => {
            clearStagedPortableState(alloc, &state);
            try saveState(state_path, &state);
            return true;
        },
        else => return err,
    };
    return false;
}

fn recoverPendingPortableFailure(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
    original_args: []const []const u8,
    err: anyerror,
) !u8 {
    const pending = abandonPendingPortableApply(alloc, state_path, install_root) catch pending: {
        var state = loadState(alloc, state_path) catch break :pending false;
        defer state.deinit(alloc);
        break :pending state.staged_kind == .portable and state.portable_apply_phase == .pending;
    };
    if (!pending) return 1;
    const child = try spawnInstalledNoctty(
        alloc,
        install_root,
        original_args,
        null,
        @errorName(err),
    );
    std.os.windows.CloseHandle(child.thread_handle);
    std.os.windows.CloseHandle(child.id);
    return 0;
}

fn rollbackPortableUpdateAndRelaunch(
    alloc: Allocator,
    state_path: []const u8,
    install_root: []const u8,
    original_args: []const []const u8,
) !u8 {
    var layout = layout: {
        const state_lock = try openStateLock(state_path);
        defer state_lock.close();
        var state = try loadState(alloc, state_path);
        defer state.deinit(alloc);
        if (state.staged_kind != .portable) return error.StagedKindMismatch;
        const value = try portableStageLayout(alloc, state_path, &state);
        state.portable_apply_phase = .rollback;
        try saveState(state_path, &state);
        break :layout value;
    };
    defer layout.deinit(alloc);
    try validatePortableInstallAndStateRoots(alloc, state_path, install_root);
    try validatePortableStageDirectory(alloc, layout.stage_dir);

    try portable_apply.rollback(alloc, install_root, layout.backup_path);
    _ = try portable_apply.decide(.portable, .rollback, .rollback_completed);
    {
        const state_lock = try openStateLock(state_path);
        defer state_lock.close();
        var state = try loadState(alloc, state_path);
        defer state.deinit(alloc);
        if (state.portable_apply_phase != .rollback) return error.InvalidPortableApplyTransition;
        state.portable_apply_phase = null;
        state.apply_requested_at = 0;
        state.portable_watcher_pid = 0;
        state.portable_watcher_started_at = 0;
        clearOptionalOwned(alloc, &state.portable_confirmation_token);
        try saveState(state_path, &state);
    }
    portable_apply.cleanupBackup(layout.backup_path) catch |err| {
        log.warn("portable update rollback backup cleanup failed path={s} err={}", .{ layout.backup_path, err });
    };

    const child = try spawnInstalledNoctty(alloc, install_root, original_args, null, null);
    std.os.windows.CloseHandle(child.thread_handle);
    std.os.windows.CloseHandle(child.id);
    return 0;
}

fn spawnInstalledNoctty(
    alloc: Allocator,
    install_root: []const u8,
    original_args: []const []const u8,
    confirmation_token: ?[]const u8,
    failure_name: ?[]const u8,
) !std.process.Child {
    const exe_path = try std.fs.path.join(alloc, &.{ install_root, "noctty.exe" });
    defer alloc.free(exe_path);
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    if (confirmation_token) |token|
        try env.put(portable_confirmation_env, token)
    else
        env.remove(portable_confirmation_env);
    if (failure_name) |failure| {
        try env.put(portable_failure_env, failure);
        try env.put(portable_bypass_env, "1");
    } else {
        env.remove(portable_failure_env);
        env.remove(portable_bypass_env);
    }
    const child_args = try buildInstalledNocttyArgv(alloc, exe_path, original_args);
    defer alloc.free(child_args);
    var child = std.process.Child.init(child_args, alloc);
    child.env_map = &env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    child.env_map = null;
    return child;
}

fn buildInstalledNocttyArgv(
    alloc: Allocator,
    exe_path: []const u8,
    original_args: []const []const u8,
) ![][]const u8 {
    const result = try alloc.alloc([]const u8, original_args.len + 1);
    result[0] = exe_path;
    @memcpy(result[1..], original_args);
    return result;
}

fn waitForProcessExit(pid: u32, timeout_ms: u32) !void {
    const handle = OpenProcess(std.os.windows.SYNCHRONIZE, 0, pid) orelse return;
    defer std.os.windows.CloseHandle(handle);
    return std.os.windows.WaitForSingleObject(handle, timeout_ms);
}

fn portableWatcherIsRunning(pid: u32, expected_started_at: u64) bool {
    const handle = OpenProcess(
        std.os.windows.SYNCHRONIZE | process_query_limited_information,
        0,
        pid,
    ) orelse return false;
    defer std.os.windows.CloseHandle(handle);
    const started_at = processCreationTime(handle) orelse return false;
    if (started_at != expected_started_at) return false;
    std.os.windows.WaitForSingleObject(handle, 0) catch |err| return err == error.WaitTimeOut;
    return false;
}

fn portableStateWatcherIsActive(state: *const State) bool {
    return state.portable_watcher_pid != 0 and
        state.portable_watcher_started_at != 0 and
        portableWatcherIsRunning(
            state.portable_watcher_pid,
            state.portable_watcher_started_at,
        );
}

fn processCreationTime(handle: std.os.windows.HANDLE) ?u64 {
    var creation: std.os.windows.FILETIME = undefined;
    var exit_time: std.os.windows.FILETIME = undefined;
    var kernel: std.os.windows.FILETIME = undefined;
    var user: std.os.windows.FILETIME = undefined;
    if (GetProcessTimes(handle, &creation, &exit_time, &kernel, &user) == 0) return null;
    return @as(u64, creation.dwHighDateTime) << 32 | creation.dwLowDateTime;
}

fn clearStagedPortableState(alloc: Allocator, state: *State) void {
    clearOptionalOwned(alloc, &state.staged_version);
    state.staged_kind = null;
    clearOptionalOwned(alloc, &state.staged_portable_path);
    clearOptionalOwned(alloc, &state.staged_payload_path);
    clearOptionalOwned(alloc, &state.staged_sha256);
    state.staged_at = 0;
    state.apply_requested_at = 0;
    state.portable_apply_phase = null;
    state.portable_watcher_pid = 0;
    state.portable_watcher_started_at = 0;
    clearOptionalOwned(alloc, &state.portable_backup_path);
    clearOptionalOwned(alloc, &state.portable_confirmation_token);
}

fn finalizePortableConfirmation(alloc: Allocator, state_path: []const u8) !void {
    var cleanup_paths: ?struct { backup: []u8, displaced: []u8 } = null;
    defer if (cleanup_paths) |paths| {
        alloc.free(paths.backup);
        alloc.free(paths.displaced);
    };
    {
        const state_lock = try openStateLock(state_path);
        defer state_lock.close();
        var state = try loadState(alloc, state_path);
        defer state.deinit(alloc);
        if (state.portable_apply_phase != .confirmed) return;
        var layout = try portableStageLayout(alloc, state_path, &state);
        defer layout.deinit(alloc);
        try validatePortableStageDirectory(alloc, layout.stage_dir);
        const backup = try alloc.dupe(u8, layout.backup_path);
        errdefer alloc.free(backup);
        const displaced = try alloc.dupe(u8, layout.displaced_path);
        cleanup_paths = .{ .backup = backup, .displaced = displaced };
        clearStagedPortableState(alloc, &state);
        try saveState(state_path, &state);
    }
    const paths = cleanup_paths.?;
    portable_apply.cleanupBackup(paths.backup) catch |err| {
        log.warn("portable update backup cleanup failed path={s} err={}", .{ paths.backup, err });
    };
    portable_apply.cleanupUpdatePath(paths.displaced) catch |err| {
        log.warn("portable update displaced cleanup failed path={s} err={}", .{ paths.displaced, err });
    };
}

extern "kernel32" fn OpenProcess(
    desired_access: u32,
    inherit_handle: i32,
    process_id: u32,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn GetProcessId(process: std.os.windows.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetProcessTimes(
    process: std.os.windows.HANDLE,
    creation_time: *std.os.windows.FILETIME,
    exit_time: *std.os.windows.FILETIME,
    kernel_time: *std.os.windows.FILETIME,
    user_time: *std.os.windows.FILETIME,
) callconv(.winapi) std.os.windows.BOOL;

const process_query_limited_information: u32 = 0x1000;

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

fn writeOptionalEnum(writer: *std.Io.Writer, value: anytype) !void {
    if (value) |tag| return writeOptionalJsonString(writer, @tagName(tag));
    return writeOptionalJsonString(writer, null);
}

fn replaceOptionalOwned(alloc: Allocator, slot: *?[]u8, value: []u8) void {
    if (slot.*) |old| alloc.free(old);
    slot.* = value;
}

fn resolveRedirectTarget(
    alloc: Allocator,
    base_url: []const u8,
    location: []const u8,
) ![]u8 {
    const base_uri = try validateHttpsUrl(base_url);
    const combined_len = std.math.add(
        usize,
        base_url.len,
        location.len,
    ) catch return error.OutOfMemory;
    const resolution_len = std.math.mul(
        usize,
        3,
        std.math.add(usize, combined_len, 1) catch return error.OutOfMemory,
    ) catch return error.OutOfMemory;
    const resolution_buf = try alloc.alloc(u8, resolution_len);
    defer alloc.free(resolution_buf);
    @memcpy(resolution_buf[0..location.len], location);
    var aux_buf = resolution_buf;
    const resolved = base_uri.resolveInPlace(location.len, &aux_buf) catch
        return error.InvalidUpdateUrl;

    const resolved_url = try std.fmt.allocPrint(
        alloc,
        "{f}",
        .{resolved.fmt(.all)},
    );
    errdefer alloc.free(resolved_url);
    _ = try validateHttpsUrl(resolved_url);
    return resolved_url;
}

/// Response body caps. `std.Io.Reader.streamRemaining` pumps until EOF with
/// no limit, so an oversized or hostile response would otherwise grow the
/// caller's buffer (metadata) or the staged file (download) without bound.
/// Every body read below goes through `streamBounded` with one of these.
const max_metadata_response_bytes: u64 = 4 * 1024 * 1024;
const max_download_response_bytes: u64 = 512 * 1024 * 1024;
const max_redirect_body_bytes: u64 = 1024 * 1024;

/// Pump `reader` into `writer`, refusing a body longer than `max_bytes`.
/// At most one byte past the cap reaches `writer` before the error, and
/// every caller discards its destination on error.
fn streamBounded(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    max_bytes: u64,
) !void {
    var streamed: u64 = 0;
    while (true) {
        const room = max_bytes + 1 - streamed;
        if (room == 0) return error.HttpResponseTooLarge;
        streamed += reader.stream(writer, .limited64(room)) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |other| return other,
        };
        if (streamed > max_bytes) return error.HttpResponseTooLarge;
    }
}

fn clearOptionalOwned(alloc: Allocator, slot: *?[]u8) void {
    if (slot.*) |old| alloc.free(old);
    slot.* = null;
}

fn fetchHttps(
    alloc: Allocator,
    context: []const u8,
    initial_url: []const u8,
    extra_headers: []const std.http.Header,
    response_writer: *std.Io.Writer,
    max_response_bytes: u64,
) !void {
    _ = try validateHttpsUrl(initial_url);

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var current_url = try alloc.dupe(u8, initial_url);
    defer alloc.free(current_url);

    var redirect_count: u8 = 0;
    while (true) {
        var next_url: ?[]u8 = null;
        {
            const uri = try validateHttpsUrl(current_url);
            var request = try client.request(.GET, uri, .{
                .redirect_behavior = .unhandled,
                .extra_headers = extra_headers,
            });
            defer request.deinit();

            try request.sendBodiless();
            var response = try request.receiveHead(&.{});

            if (response.head.status.class() == .redirect) {
                if (redirect_count >= 3) return error.TooManyHttpRedirects;
                const location = response.head.location orelse return error.HttpRedirectLocationMissing;
                next_url = try resolveRedirectTarget(alloc, current_url, location);
                errdefer if (next_url) |value| alloc.free(value);

                const redirect_reader = response.reader(&.{});
                var discarded: u64 = 0;
                while (true) {
                    const room = max_redirect_body_bytes + 1 - discarded;
                    if (room == 0) return error.HttpResponseTooLarge;
                    discarded += redirect_reader.discard(.limited64(room)) catch |err| switch (err) {
                        error.EndOfStream => break,
                        error.ReadFailed => return response.bodyErr().?,
                    };
                    if (discarded > max_redirect_body_bytes) return error.HttpResponseTooLarge;
                }
                redirect_count += 1;
            } else {
                try requireOkHttpStatus(context, current_url, response.head.status);

                const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                    .identity => &.{},
                    .zstd => try alloc.alloc(u8, std.compress.zstd.default_window_len),
                    .deflate, .gzip => try alloc.alloc(u8, std.compress.flate.max_window_len),
                    .compress => return error.UnsupportedCompressionMethod,
                };
                defer if (decompress_buffer.len > 0) alloc.free(decompress_buffer);

                var transfer_buffer: [64]u8 = undefined;
                var decompress: std.http.Decompress = undefined;
                const body_reader = response.readerDecompressing(
                    &transfer_buffer,
                    &decompress,
                    decompress_buffer,
                );
                streamBounded(body_reader, response_writer, max_response_bytes) catch |err| switch (err) {
                    error.ReadFailed => return response.bodyErr().?,
                    else => |other| return other,
                };
                return;
            }
        }

        const replacement = next_url orelse unreachable;
        alloc.free(current_url);
        current_url = replacement;
    }
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

    var file_buf: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(&file_buf);
    try fetchHttps(
        alloc,
        "download",
        url,
        &.{
            .{ .name = "accept", .value = "application/octet-stream" },
            .{ .name = "user-agent", .value = "noctty-updater" },
        },
        &file_writer.interface,
        max_download_response_bytes,
    );
    try file_writer.interface.flush();
    file.close();
    file_open = false;

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

        const checksum = checksumLine(line) orelse continue;
        if (!std.mem.eql(u8, checksum.filename, installer_name)) continue;
        if (matched != null) return error.InstallerChecksumDuplicate;
        matched = try parseSha256Hex(checksum.hex);
    }

    return matched orelse error.InstallerChecksumMissing;
}

const ChecksumLine = struct {
    hex: []const u8,
    filename: []const u8,
};

fn checksumLine(line: []const u8) ?ChecksumLine {
    const separator = std.mem.indexOfAny(u8, line, " \t") orelse return null;
    const hex = line[0..separator];
    const raw_filename = std.mem.trimLeft(u8, line[separator..], " \t");
    if (raw_filename.len == 0) return null;
    const filename = if (raw_filename[0] == '*') raw_filename[1..] else raw_filename;
    if (filename.len == 0) return null;
    return .{ .hex = hex, .filename = filename };
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

const max_portable_zip_bytes: u64 = 128 * 1024 * 1024;
const max_portable_expanded_bytes: u64 = 256 * 1024 * 1024;
const max_portable_entry_bytes: u64 = 128 * 1024 * 1024;
const max_portable_entries: u64 = 4096;
const max_portable_name_bytes: usize = 4096;
const max_portable_compression_ratio: u64 = 200;
const max_portable_manifest_bytes: usize = 2 * 1024 * 1024;

fn extractAndVerifyPortableZip(
    alloc: Allocator,
    zip_path: []const u8,
    stage_dir: []const u8,
    manifest_path: []const u8,
) ![]u8 {
    if (builtin.os.tag != .windows) return error.AuthenticodeRequiresWindows;
    try validatePortableZipEntries(alloc, zip_path);

    const partial_root = try std.fs.path.join(alloc, &.{ stage_dir, "payload.partial" });
    defer alloc.free(partial_root);
    const extracted_root = try std.fs.path.join(alloc, &.{ stage_dir, "payload" });
    defer alloc.free(extracted_root);
    try portable_apply.cleanupUpdatePath(partial_root);
    try portable_apply.cleanupUpdatePath(extracted_root);
    errdefer portable_apply.cleanupUpdatePath(partial_root) catch {};
    try std.fs.cwd().makePath(partial_root);

    var destination = try std.fs.openDirAbsolute(partial_root, .{});
    var destination_open = true;
    defer if (destination_open) destination.close();
    var zip_file = try std.fs.openFileAbsolute(zip_path, .{});
    defer zip_file.close();
    var reader_buffer: [64 * 1024]u8 = undefined;
    var zip_reader = zip_file.reader(&reader_buffer);
    var diagnostics: std.zip.Diagnostics = .{ .allocator = alloc };
    defer diagnostics.deinit();
    try std.zip.extract(destination, &zip_reader, .{ .diagnostics = &diagnostics });
    if (!std.mem.eql(u8, diagnostics.root_dir, "noctty")) return error.InvalidPortableArchiveRoot;
    destination.close();
    destination_open = false;

    const partial_payload = try std.fs.path.join(alloc, &.{ partial_root, "noctty" });
    defer alloc.free(partial_payload);
    try verifyPortablePayload(alloc, partial_payload, manifest_path);
    try std.fs.renameAbsolute(partial_root, extracted_root);
    return std.fs.path.join(alloc, &.{ extracted_root, "noctty" });
}

fn validatePortableZipEntries(alloc: Allocator, zip_path: []const u8) !void {
    var file = try std.fs.openFileAbsolute(zip_path, .{});
    defer file.close();
    if ((try file.stat()).size > max_portable_zip_bytes) return error.PortableArchiveTooLarge;
    var reader_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(&reader_buffer);
    var iterator = std.zip.Iterator.init(&reader) catch return error.InvalidPortableArchive;
    if (iterator.cd_record_count == 0) return error.InvalidPortableArchive;
    if (iterator.cd_record_count > max_portable_entries) return error.PortableArchiveTooLarge;

    var names: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var keys = names.keyIterator();
        while (keys.next()) |key| alloc.free(key.*);
        names.deinit(alloc);
    }
    var expanded_bytes: u64 = 0;
    while (iterator.next() catch return error.InvalidPortableArchive) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > max_portable_name_bytes) {
            return error.UnsafePortableArchiveEntry;
        }
        var name_buffer: [max_portable_name_bytes]u8 = undefined;
        const name = name_buffer[0..entry.filename_len];
        reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch
            return error.InvalidPortableArchive;
        reader.interface.readSliceAll(name) catch return error.InvalidPortableArchive;
        if (!portable_apply.isSafeZipEntryPath(name)) return error.UnsafePortableArchiveEntry;
        switch (entry.compression_method) {
            .store, .deflate => {},
            else => return error.UnsupportedPortableArchive,
        }
        if (entry.uncompressed_size > max_portable_entry_bytes) return error.PortableArchiveTooLarge;
        if (entry.uncompressed_size > 0) {
            if (entry.compressed_size == 0) return error.PortableArchiveTooLarge;
            const ratio_limit = std.math.mul(
                u64,
                entry.compressed_size,
                max_portable_compression_ratio,
            ) catch std.math.maxInt(u64);
            if (entry.uncompressed_size > ratio_limit) return error.PortableArchiveTooLarge;
        }
        expanded_bytes = std.math.add(u64, expanded_bytes, entry.uncompressed_size) catch
            return error.PortableArchiveTooLarge;
        if (expanded_bytes > max_portable_expanded_bytes) return error.PortableArchiveTooLarge;
        const key = try std.ascii.allocLowerString(alloc, name);
        const gop = try names.getOrPut(alloc, key);
        if (gop.found_existing) {
            alloc.free(key);
            return error.DuplicatePortableArchiveEntry;
        }
    }
}

fn verifyPortablePayloadManifest(path: []const u8) !void {
    var locked = try openLockedInstaller(path);
    defer locked.close();
    if (!try lockedHandleMatchesPath(std.heap.page_allocator, path, locked.handle)) {
        return error.InvalidPortablePayloadManifest;
    }
    try verifyAuthenticodeSignature(path, locked.handle);
}

fn verifiedPortablePayloadManifestAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    var locked = try openLockedInstaller(path);
    defer locked.close();
    if (!try lockedHandleMatchesPath(alloc, path, locked.handle)) {
        return error.InvalidPortablePayloadManifest;
    }
    try verifyAuthenticodeSignature(path, locked.handle);
    try locked.seekTo(0);
    return locked.readToEndAlloc(alloc, max_portable_manifest_bytes);
}

fn verifyPortablePayload(
    alloc: Allocator,
    payload_root: []const u8,
    manifest_path: []const u8,
) !void {
    const manifest = try verifiedPortablePayloadManifestAlloc(alloc, manifest_path);
    defer alloc.free(manifest);
    for (portable_apply.managed_entries) |entry| {
        const path = try std.fs.path.join(alloc, &.{ payload_root, entry });
        defer alloc.free(path);
        std.fs.accessAbsolute(path, .{}) catch return error.IncompletePortablePayload;
    }
    try verifyPortablePayloadAgainstManifest(alloc, payload_root, manifest);
    try verifyPortablePayloadBinaries(alloc, payload_root);
}

fn verifyPortablePayloadAgainstManifest(
    alloc: Allocator,
    payload_root: []const u8,
    manifest: []const u8,
) !void {
    var payload_dir = try std.fs.openDirAbsolute(payload_root, .{ .iterate = true });
    defer payload_dir.close();
    var walker = try payload_dir.walk(alloc);
    defer walker.deinit();
    var manifest_file_count: usize = 0;
    var manifest_lines = std.mem.splitScalar(u8, manifest, '\n');
    while (manifest_lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const checksum = checksumLine(line) orelse continue;
        _ = parseSha256Hex(checksum.hex) catch continue;
        if (!portable_apply.isManagedRelativePath(checksum.filename)) {
            return error.InvalidPortablePayloadManifest;
        }
        manifest_file_count += 1;
    }

    var payload_file_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.InvalidPortablePayload;
        const relative = try portableRelativePathAlloc(alloc, entry.path);
        defer alloc.free(relative);
        if (!portable_apply.isManagedRelativePath(relative)) return error.InvalidPortablePayload;
        const path = try std.fs.path.join(alloc, &.{ payload_root, entry.path });
        defer alloc.free(path);
        const expected = parseExpectedSha256(manifest, relative) catch |err| switch (err) {
            error.InstallerChecksumMissing => return error.PortablePayloadManifestEntryMissing,
            error.InstallerChecksumDuplicate => return error.PortablePayloadManifestEntryDuplicate,
            else => return err,
        };
        const actual = try sha256File(path);
        if (!std.mem.eql(u8, &expected, &actual)) return error.PortablePayloadManifestMismatch;
        payload_file_count += 1;
    }
    if (payload_file_count != manifest_file_count) return error.PortablePayloadManifestFileSetMismatch;
}

fn verifyPortablePayloadBinaries(alloc: Allocator, payload_root: []const u8) !void {
    var payload_dir = try std.fs.openDirAbsolute(payload_root, .{ .iterate = true });
    defer payload_dir.close();
    var walker = try payload_dir.walk(alloc);
    defer walker.deinit();
    var verified_binary_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.InvalidPortablePayload;
        const extension = std.fs.path.extension(entry.basename);
        if (!std.ascii.eqlIgnoreCase(extension, ".exe") and
            !std.ascii.eqlIgnoreCase(extension, ".com") and
            !std.ascii.eqlIgnoreCase(extension, ".dll")) continue;
        const path = try std.fs.path.join(alloc, &.{ payload_root, entry.path });
        defer alloc.free(path);
        try verifyAuthenticodeSignature(path, null);
        verified_binary_count += 1;
    }
    if (verified_binary_count == 0) return error.IncompletePortablePayload;
}

fn portableRelativePathAlloc(alloc: Allocator, path: []const u8) ![]u8 {
    const result = try alloc.dupe(u8, path);
    for (result) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }
    return result;
}

fn openLockedInstaller(path: []const u8) !std.fs.File {
    if (builtin.os.tag != .windows) return error.AuthenticodeRequiresWindows;

    const windows = std.os.windows;
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

fn lockedHandleMatchesPath(alloc: Allocator, path: []const u8, handle: std.os.windows.HANDLE) !bool {
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

const WindowsFileVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,
    build: u16,
};

fn installerVersionAtLeastClaim(
    installer: WindowsFileVersion,
    claimed: std.SemanticVersion,
) bool {
    const installer_parts = [_]u64{
        installer.major,
        installer.minor,
        installer.patch,
        installer.build,
    };
    const claimed_parts = [_]u64{
        claimed.major,
        claimed.minor,
        claimed.patch,
        0,
    };
    for (installer_parts, claimed_parts) |actual, expected| {
        if (actual != expected) return actual > expected;
    }
    return true;
}

fn readWindowsFileVersion(alloc: Allocator, path: []const u8) !WindowsFileVersion {
    if (builtin.os.tag != .windows) return error.AuthenticodeRequiresWindows;

    const windows = std.os.windows;
    const GetFileVersionInfoSizeWFn = *const fn ([*:0]const u16, *u32) callconv(.winapi) u32;
    const GetFileVersionInfoWFn = *const fn ([*:0]const u16, u32, u32, *anyopaque) callconv(.winapi) windows.BOOL;
    const VerQueryValueWFn = *const fn (*const anyopaque, [*:0]const u16, *?*anyopaque, *u32) callconv(.winapi) windows.BOOL;

    const module = windows.LoadLibraryW(
        std.unicode.utf8ToUtf16LeStringLiteral("version.dll"),
    ) catch return error.InstallerVersionInfoUnavailable;
    defer windows.FreeLibrary(module);

    const size_proc = windows.kernel32.GetProcAddress(module, "GetFileVersionInfoSizeW") orelse
        return error.InstallerVersionInfoUnavailable;
    const info_proc = windows.kernel32.GetProcAddress(module, "GetFileVersionInfoW") orelse
        return error.InstallerVersionInfoUnavailable;
    const query_proc = windows.kernel32.GetProcAddress(module, "VerQueryValueW") orelse
        return error.InstallerVersionInfoUnavailable;
    const getFileVersionInfoSize: GetFileVersionInfoSizeWFn = @ptrCast(@alignCast(size_proc));
    const getFileVersionInfo: GetFileVersionInfoWFn = @ptrCast(@alignCast(info_proc));
    const verQueryValue: VerQueryValueWFn = @ptrCast(@alignCast(query_proc));

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);

    var unused_handle: u32 = 0;
    const info_size = getFileVersionInfoSize(path_w.ptr, &unused_handle);
    if (info_size == 0) return error.InstallerVersionInfoUnavailable;

    const info = try alloc.alignedAlloc(u8, std.mem.Alignment.of(VsFixedFileInfo), info_size);
    defer alloc.free(info);
    if (getFileVersionInfo(path_w.ptr, 0, info_size, info.ptr) == 0) {
        return error.InstallerVersionInfoUnavailable;
    }

    var fixed_raw: ?*anyopaque = null;
    var fixed_len: u32 = 0;
    if (verQueryValue(
        info.ptr,
        std.unicode.utf8ToUtf16LeStringLiteral("\\"),
        &fixed_raw,
        &fixed_len,
    ) == 0 or fixed_raw == null or fixed_len < @sizeOf(VsFixedFileInfo)) {
        return error.InstallerVersionInfoUnavailable;
    }

    const fixed: *const VsFixedFileInfo = @ptrCast(@alignCast(fixed_raw.?));
    if (fixed.signature != vs_fixed_file_info_signature) {
        return error.InstallerVersionInfoUnavailable;
    }
    return .{
        .major = @truncate(fixed.file_version_ms >> 16),
        .minor = @truncate(fixed.file_version_ms),
        .patch = @truncate(fixed.file_version_ls >> 16),
        .build = @truncate(fixed.file_version_ls),
    };
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
    if (start > buf.len or buf.len - start < 2) return error.InvalidDer;

    const tag = buf[start];
    var offset = start + 1;
    const len_byte = buf[offset];
    offset += 1;

    var len: usize = 0;
    if ((len_byte & 0x80) == 0) {
        len = len_byte;
    } else {
        const len_len: usize = len_byte & 0x7f;
        if (len_len == 0 or len_len > @sizeOf(usize) or len_len > buf.len - offset) {
            return error.InvalidDer;
        }
        for (buf[offset .. offset + len_len]) |b| {
            len = (len << 8) | b;
        }
        offset += len_len;
    }

    if (len > buf.len - offset) return error.InvalidDer;
    const end = offset + len;
    return .{
        .tag = tag,
        .start = start,
        .content_start = offset,
        .content_end = end,
        .end = end,
    };
}

const WTD_UI_NONE: u32 = 2;
const WTD_REVOKE_WHOLECHAIN: u32 = 1;
const WTD_CHOICE_FILE: u32 = 1;
const WTD_STATEACTION_VERIFY: u32 = 1;
const WTD_STATEACTION_CLOSE: u32 = 2;
const cert_e_untrusted_root: i32 = @bitCast(@as(u32, 0x800B0109));
const vs_fixed_file_info_signature: u32 = 0xFEEF04BD;
const VsFixedFileInfo = extern struct {
    signature: u32,
    struct_version: u32,
    file_version_ms: u32,
    file_version_ls: u32,
    product_version_ms: u32,
    product_version_ls: u32,
    file_flags_mask: u32,
    file_flags: u32,
    file_os: u32,
    file_type: u32,
    file_subtype: u32,
    file_date_ms: u32,
    file_date_ls: u32,
};
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
    fCommercial: i32,
    fTrustedRoot: i32,
    fSelfSigned: i32,
    fTestCert: i32,
    dwRevokedReason: u32,
    dwConfidence: u32,
    dwError: u32,
    pTrustListContext: ?*anyopaque,
    fTrustListSignerCert: i32,
    pCtlContext: ?*const anyopaque,
    dwCtlError: u32,
    fIsCyclic: i32,
    pChainElement: ?*const anyopaque,
};

fn shouldCheckNetwork(state: *const State, release_feed_url: []const u8, now: i64) bool {
    const cached_feed_url = state.release_feed_url orelse return true;
    if (state.release_url == null) return true;
    if (!std.mem.eql(u8, cached_feed_url, release_feed_url)) return true;
    if (state.last_checked_at <= 0) return true;
    if (now <= state.last_checked_at) return true;
    return now - state.last_checked_at >= throttle_seconds;
}

fn cachedAvailableRelease(
    alloc: Allocator,
    state: *const State,
    current_version: std.SemanticVersion,
    respect_dismissal: bool,
) !?Release {
    const last_seen = state.last_seen_version orelse return null;
    const cached_release_url = state.release_url orelse return null;
    _ = validateHttpsUrl(cached_release_url) catch return null;
    const latest_version = parseVersionText(last_seen) catch return null;
    if (current_version.order(latest_version) != .lt) return null;
    if (respect_dismissal) {
        if (state.dismissed_version) |dismissed| {
            if (std.mem.eql(u8, dismissed, last_seen)) return null;
        }
    }

    const version_text = try alloc.dupe(u8, last_seen);
    errdefer alloc.free(version_text);
    const release_url = try alloc.dupe(u8, cached_release_url);

    // Cached state does not persist asset-scoped installer metadata.
    return .{
        .version_text = version_text,
        .release_url = release_url,
    };
}

fn fetchLatestStableRelease(alloc: Allocator, release_feed_url: []const u8) !Release {
    var response_buf: std.Io.Writer.Allocating = .init(alloc);
    defer response_buf.deinit();

    try fetchHttps(
        alloc,
        "release metadata",
        release_feed_url,
        &.{
            .{ .name = "accept", .value = "application/vnd.github+json" },
            .{ .name = "user-agent", .value = "noctty-updater" },
            .{ .name = "x-github-api-version", .value = "2022-11-28" },
        },
        &response_buf.writer,
        max_metadata_response_bytes,
    );

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
    _ = try validateHttpsUrl(html_url);

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
        "noctty-{s}-windows-{s}-setup.exe",
        .{ version_text, windowsInstallerArch() },
    );
    errdefer alloc.free(expected_installer_name);
    const expected_portable_name = try std.fmt.allocPrint(
        alloc,
        "noctty-{s}-windows-{s}-portable.zip",
        .{ version_text, windowsInstallerArch() },
    );
    errdefer alloc.free(expected_portable_name);
    const expected_portable_manifest_name = try portableManifestNameAlloc(alloc, version_text);
    errdefer alloc.free(expected_portable_manifest_name);
    const expected_checksums_name = windowsChecksumsAssetName();

    var installer_url: ?[]const u8 = null;
    var portable_url: ?[]const u8 = null;
    var portable_manifest_url: ?[]const u8 = null;
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
            _ = try validateHttpsUrl(browser_download_url);
            installer_url = browser_download_url;
            continue;
        }
        if (std.mem.eql(u8, name, expected_portable_name)) {
            _ = try validateHttpsUrl(browser_download_url);
            portable_url = browser_download_url;
            continue;
        }
        if (std.mem.eql(u8, name, expected_portable_manifest_name)) {
            _ = try validateHttpsUrl(browser_download_url);
            portable_manifest_url = browser_download_url;
            continue;
        }
        if (std.mem.eql(u8, name, expected_checksums_name)) {
            _ = try validateHttpsUrl(browser_download_url);
            checksums_url = browser_download_url;
            continue;
        }
        if (checksums_url == null and
            std.mem.eql(u8, windowsInstallerArch(), "x64") and
            std.mem.eql(u8, name, windows_checksums_asset_name_legacy))
        {
            _ = try validateHttpsUrl(browser_download_url);
            checksums_url = browser_download_url;
            continue;
        }
    }

    if (installer_url == null or checksums_url == null) {
        alloc.free(expected_installer_name);
        alloc.free(expected_portable_name);
        alloc.free(expected_portable_manifest_name);
        return null;
    }

    const owned_installer_url = try alloc.dupe(u8, installer_url.?);
    errdefer alloc.free(owned_installer_url);
    const owned_checksums_url = try alloc.dupe(u8, checksums_url.?);
    errdefer alloc.free(owned_checksums_url);
    const owned_portable_url = if (portable_url) |url|
        try alloc.dupe(u8, url)
    else
        null;
    errdefer if (owned_portable_url) |value| alloc.free(value);
    const owned_portable_manifest_url = if (portable_manifest_url) |url|
        try alloc.dupe(u8, url)
    else
        null;
    errdefer if (owned_portable_manifest_url) |value| alloc.free(value);
    const owned_portable_name: ?[]u8 = if (owned_portable_url != null)
        expected_portable_name
    else blk: {
        alloc.free(expected_portable_name);
        break :blk null;
    };
    const owned_portable_manifest_name: ?[]u8 = if (owned_portable_manifest_url != null)
        expected_portable_manifest_name
    else blk: {
        alloc.free(expected_portable_manifest_name);
        break :blk null;
    };

    return .{
        .installer_name = expected_installer_name,
        .installer_url = owned_installer_url,
        .portable_name = owned_portable_name,
        .portable_url = owned_portable_url,
        .portable_manifest_name = owned_portable_manifest_name,
        .portable_manifest_url = owned_portable_manifest_url,
        .checksums_url = owned_checksums_url,
    };
}

fn windowsInstallerArch() []const u8 {
    return windows_asset_metadata.arch;
}

fn windowsChecksumsAssetName() []const u8 {
    return windows_asset_metadata.checksums_asset_name;
}

fn portableManifestNameAlloc(alloc: Allocator, version_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "noctty-{s}-windows-{s}-portable.manifest.ps1",
        .{ version_text, windowsInstallerArch() },
    );
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

fn validateHttpsUrl(url: []const u8) !std.Uri {
    const uri = std.Uri.parse(url) catch return error.InvalidUpdateUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUpdateUrl;
    const host = uri.host orelse return error.InvalidUpdateUrl;
    if (host.isEmpty()) return error.InvalidUpdateUrl;
    return uri;
}

test "canonical version strips v prefix" {
    const alloc = std.testing.allocator;
    const version_text = try canonicalVersionText(alloc, "v1.2.3");
    defer alloc.free(version_text);
    try std.testing.expectEqualStrings("1.2.3", version_text);
}

test "update release feed resolution" {
    const alloc = std.testing.allocator;
    const env_name = "NOCTTY_UPDATE_FEED_URL";
    const saved_env = std.process.getEnvVarOwned(alloc, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer {
        if (saved_env) |value| {
            const sentinel = alloc.dupeZ(u8, value) catch unreachable;
            defer alloc.free(sentinel);
            _ = internal_os.setenv(env_name, sentinel);
            alloc.free(value);
        } else {
            _ = internal_os.unsetenv(env_name);
        }
    }

    const cases = [_]struct {
        env: ?[:0]const u8,
        configured: ?[]const u8,
        expected: []const u8,
    }{
        .{ .env = "https://env.example/latest", .configured = "https://config.example/latest", .expected = "https://config.example/latest" },
        .{ .env = null, .configured = "https://config.example/latest", .expected = "https://config.example/latest" },
        .{ .env = null, .configured = null, .expected = latest_stable_api_url },
        .{ .env = " \t\r\n ", .configured = "  https://config.example/latest  ", .expected = "https://config.example/latest" },
        .{ .env = "https://env.example/latest", .configured = " \t\r\n ", .expected = "https://env.example/latest" },
        .{ .env = " \t\r\n ", .configured = " \t\r\n ", .expected = latest_stable_api_url },
        .{ .env = "http://env.example/latest", .configured = "https://config.example/latest", .expected = "https://config.example/latest" },
        .{ .env = "https://env.example/latest", .configured = "file:///tmp/latest", .expected = latest_stable_api_url },
        .{ .env = "http://env.example/latest", .configured = null, .expected = latest_stable_api_url },
        .{ .env = null, .configured = "file:///tmp/latest", .expected = latest_stable_api_url },
    };

    for (cases) |case| {
        if (case.env) |value| {
            _ = internal_os.setenv(env_name, value);
        } else {
            _ = internal_os.unsetenv(env_name);
        }

        const resolved = try resolveReleaseFeedUrl(alloc, case.configured);
        defer alloc.free(resolved);
        try std.testing.expectEqualStrings(case.expected, resolved);
    }

    // The ignored-feed signal names the level whose value was dropped, not
    // just the configuration level: an environment feed is also a feed.
    const signal_cases = [_]struct {
        env: ?[:0]const u8,
        configured: ?[]const u8,
        source: FeedSource,
        ignored: ?FeedSource,
    }{
        .{ .env = null, .configured = null, .source = .default, .ignored = null },
        .{ .env = null, .configured = "https://config.example/latest", .source = .configured, .ignored = null },
        .{ .env = "https://env.example/latest", .configured = null, .source = .environment, .ignored = null },
        .{ .env = null, .configured = "http://config.example/latest", .source = .default, .ignored = .configured },
        .{ .env = "http://env.example/latest", .configured = null, .source = .default, .ignored = .environment },
        .{ .env = "not a url", .configured = null, .source = .default, .ignored = .environment },
    };

    for (signal_cases) |case| {
        if (case.env) |value| {
            _ = internal_os.setenv(env_name, value);
        } else {
            _ = internal_os.unsetenv(env_name);
        }

        var resolved = try resolveReleaseFeed(alloc, case.configured);
        defer resolved.deinit(alloc);
        try std.testing.expectEqual(case.source, resolved.source);
        try std.testing.expectEqual(case.ignored, resolved.ignored_non_https);
    }
}

test "bounded response streaming refuses an oversized body" {
    const alloc = std.testing.allocator;
    const body = "0123456789";

    // Exactly at the cap is accepted.
    {
        var reader: std.Io.Reader = .fixed(body);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try streamBounded(&reader, &out.writer, body.len);
        try std.testing.expectEqualStrings(body, out.written());
    }

    // One byte over the cap is refused.
    {
        var reader: std.Io.Reader = .fixed(body);
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try std.testing.expectError(
            error.HttpResponseTooLarge,
            streamBounded(&reader, &out.writer, body.len - 1),
        );
    }
}

test "update installer version must meet the claimed release version" {
    const claimed = try std.SemanticVersion.parse("1.3.100");
    try std.testing.expect(installerVersionAtLeastClaim(.{
        .major = 1,
        .minor = 3,
        .patch = 100,
        .build = 0,
    }, claimed));
    try std.testing.expect(installerVersionAtLeastClaim(.{
        .major = 1,
        .minor = 3,
        .patch = 100,
        .build = 7,
    }, claimed));
    try std.testing.expect(installerVersionAtLeastClaim(.{
        .major = 1,
        .minor = 4,
        .patch = 0,
        .build = 0,
    }, claimed));
    try std.testing.expect(!installerVersionAtLeastClaim(.{
        .major = 1,
        .minor = 3,
        .patch = 99,
        .build = 65535,
    }, claimed));
}

test "cached update respects dismissal" {
    const alloc = std.testing.allocator;
    var state: State = .{
        .last_seen_version = try alloc.dupe(u8, "1.2.3"),
        .release_url = try alloc.dupe(u8, "https://updates.example/releases/1.2.3"),
        .dismissed_version = try alloc.dupe(u8, "1.2.3"),
    };
    defer state.deinit(alloc);

    const current = try std.SemanticVersion.parse("1.2.2");
    try std.testing.expect((try cachedAvailableRelease(alloc, &state, current, true)) == null);
}

test "cached update returns persisted release URL" {
    const alloc = std.testing.allocator;
    var state: State = .{
        .last_seen_version = try alloc.dupe(u8, "1.2.3"),
        .release_url = try alloc.dupe(u8, "https://updates.example/releases/1.2.3"),
    };
    defer state.deinit(alloc);

    const current = try std.SemanticVersion.parse("1.2.2");
    var release = (try cachedAvailableRelease(alloc, &state, current, true)).?;
    defer release.deinit(alloc);
    try std.testing.expectEqualStrings(state.release_url.?, release.release_url);
}

test "changed release feed bypasses throttle" {
    const alloc = std.testing.allocator;
    const now: i64 = 1_000_000;
    var state: State = .{
        .last_checked_at = now - 1,
        .release_feed_url = try alloc.dupe(u8, "https://updates.example/feed-a"),
        .release_url = try alloc.dupe(u8, "https://updates.example/releases/1.2.3"),
    };
    defer state.deinit(alloc);

    try std.testing.expect(!shouldCheckNetwork(&state, "https://updates.example/feed-a", now));
    try std.testing.expect(shouldCheckNetwork(&state, "https://updates.example/feed-b", now));

    const legacy_state: State = .{ .last_checked_at = now - 1 };
    try std.testing.expect(shouldCheckNetwork(&legacy_state, "https://updates.example/feed-a", now));

    alloc.free(state.release_url.?);
    state.release_url = null;
    try std.testing.expect(shouldCheckNetwork(&state, "https://updates.example/feed-a", now));
}

test "state persists staged windows install metadata with escaped path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "noctty-test", "update-state.json" });
    defer alloc.free(state_path);

    var state: State = .{
        .last_checked_at = 123,
        .last_seen_version = try alloc.dupe(u8, "1.3.100"),
        .release_feed_url = try alloc.dupe(u8, "https://updates.example/latest?channel=\"stable\""),
        .release_url = try alloc.dupe(u8, "https://updates.example/releases/1.3.100"),
        .staged_version = try alloc.dupe(u8, "1.3.101"),
        .staged_kind = .installer,
        .staged_installer_path = try alloc.dupe(u8, "C:\\Users\\Aman\\updates\\noctty-1.3.101-windows-x64-setup.exe"),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        .staged_feed_url = try alloc.dupe(u8, "https://updates.example/latest?channel=\"stable\""),
        .staged_at = 456,
        .apply_requested_at = 789,
        .portable_watcher_pid = 4242,
        .portable_watcher_started_at = 123_456_789,
    };
    defer state.deinit(alloc);

    try saveState(state_path, &state);
    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(@as(i64, 123), loaded.last_checked_at);
    try std.testing.expectEqual(@as(i64, 456), loaded.staged_at);
    try std.testing.expectEqual(@as(i64, 789), loaded.apply_requested_at);
    try std.testing.expectEqual(@as(u32, 4242), loaded.portable_watcher_pid);
    try std.testing.expectEqual(@as(u64, 123_456_789), loaded.portable_watcher_started_at);
    try std.testing.expectEqualStrings(state.release_feed_url.?, loaded.release_feed_url.?);
    try std.testing.expectEqualStrings(state.release_url.?, loaded.release_url.?);
    try std.testing.expectEqualStrings("1.3.101", loaded.staged_version.?);
    try std.testing.expectEqual(portable_apply.StagedKind.installer, loaded.staged_kind.?);
    try std.testing.expectEqualStrings(state.staged_installer_path.?, loaded.staged_installer_path.?);
    try std.testing.expectEqualStrings(state.staged_sha256.?, loaded.staged_sha256.?);
    try std.testing.expectEqualStrings(state.staged_feed_url.?, loaded.staged_feed_url.?);
}

test "staged install without a recorded feed is attributed to the default feed" {
    const alloc = std.testing.allocator;
    var legacy: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.101"),
    };
    defer legacy.deinit(alloc);
    try std.testing.expectEqualStrings(latest_stable_api_url, legacy.stagedFeedUrl());

    var bound: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.101"),
        .staged_feed_url = try alloc.dupe(u8, "https://updates.example/feed-b"),
    };
    defer bound.deinit(alloc);
    try std.testing.expectEqualStrings("https://updates.example/feed-b", bound.stagedFeedUrl());
}

test "changing the feed discards the previous feed's staged install and notice state" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "noctty-test", "update-state.json" });
    defer alloc.free(state_path);
    const installer_path = try std.fs.path.join(alloc, &.{ tmp_path, "staged-installer.exe" });
    defer alloc.free(installer_path);
    try tmp.dir.writeFile(.{ .sub_path = "staged-installer.exe", .data = "not a real installer" });

    var state: State = .{
        .last_checked_at = 123,
        .last_seen_version = try alloc.dupe(u8, "1.3.101"),
        .release_feed_url = try alloc.dupe(u8, "https://updates.example/feed-a"),
        .release_url = try alloc.dupe(u8, "https://updates.example/releases/1.3.101"),
        .dismissed_version = try alloc.dupe(u8, "1.3.101"),
        .staged_version = try alloc.dupe(u8, "1.3.101"),
        .staged_installer_path = try alloc.dupe(u8, installer_path),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        .staged_feed_url = try alloc.dupe(u8, "https://updates.example/feed-a"),
        .staged_at = 456,
        .apply_requested_at = 789,
    };
    defer state.deinit(alloc);

    // Same feed: nothing is touched.
    try std.testing.expect(!try invalidateForeignFeedState(
        alloc,
        state_path,
        &state,
        "https://updates.example/feed-a",
    ));
    try std.testing.expect(state.staged_version != null);

    // Different feed: the staged install, the dismissal, and the cached
    // release all belonged to feed A and are dropped.
    try std.testing.expect(try invalidateForeignFeedState(
        alloc,
        state_path,
        &state,
        "https://updates.example/feed-b",
    ));
    try std.testing.expect(state.staged_version == null);
    try std.testing.expect(state.staged_installer_path == null);
    try std.testing.expect(state.staged_sha256 == null);
    try std.testing.expect(state.staged_feed_url == null);
    try std.testing.expectEqual(@as(i64, 0), state.staged_at);
    try std.testing.expectEqual(@as(i64, 0), state.apply_requested_at);
    try std.testing.expect(state.dismissed_version == null);
    try std.testing.expect(state.last_seen_version == null);
    try std.testing.expect(state.release_url == null);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access("staged-installer.exe", .{}),
    );

    // It was persisted, not just cleared in memory.
    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.staged_version == null);
    try std.testing.expect(loaded.dismissed_version == null);

    // Idempotent: a second pass has nothing left to discard.
    try std.testing.expect(!try invalidateForeignFeedState(
        alloc,
        state_path,
        &state,
        "https://updates.example/feed-b",
    ));
}

test "staged install from another feed is refused at apply time" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "noctty-test", "update-state.json" });
    defer alloc.free(state_path);

    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.101"),
        .staged_installer_path = try alloc.dupe(u8, "C:\\updates\\noctty-setup.exe"),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        .staged_feed_url = try alloc.dupe(u8, "https://updates.example/feed-a"),
    };
    defer state.deinit(alloc);
    try saveState(state_path, &state);

    try std.testing.expectError(
        error.StagedInstallFeedMismatch,
        verifyStagedWindowsInstall(alloc, state_path, "https://updates.example/feed-b"),
    );
}

test "record staged apply request requires staged installer metadata" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "noctty-test", "update-state.json" });
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
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "noctty-test", "update-state.json" });
    defer alloc.free(state_path);

    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.101"),
        .staged_kind = .installer,
        .staged_installer_path = try alloc.dupe(u8, "C:\\Users\\Aman\\updates\\noctty-1.3.101-windows-x64-setup.exe"),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
    };
    defer state.deinit(alloc);
    try saveState(state_path, &state);

    try recordStagedApplyRequested(alloc, state_path, 1234);

    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 1234), loaded.apply_requested_at);
}

test "portable update rejects persisted paths outside its stage" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const state_path = try std.fs.path.join(alloc, &.{ root, "update-state.json" });
    defer alloc.free(state_path);
    const stage_dir = try std.fs.path.join(alloc, &.{ root, "updates", "1.3.200" });
    defer alloc.free(stage_dir);
    const artifact_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.200-windows-{s}-portable.zip",
        .{windowsInstallerArch()},
    );
    defer alloc.free(artifact_name);

    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.200"),
        .staged_kind = .portable,
        .staged_portable_path = try std.fs.path.join(alloc, &.{ stage_dir, artifact_name }),
        .staged_payload_path = try std.fs.path.join(alloc, &.{ stage_dir, "payload", "noctty" }),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        .portable_backup_path = try std.fs.path.join(alloc, &.{ root, "unrelated-user-data" }),
    };
    defer state.deinit(alloc);

    try std.testing.expectError(
        error.InvalidPortableUpdatePath,
        portableStageLayout(alloc, state_path, &state),
    );
}

test "portable update ZIP preflight binds EOCD to archive end" {
    const alloc = std.testing.allocator;
    const name = "noctty/";
    const central_len = 46 + name.len;
    var archive: [central_len + 22]u8 = @splat(0);
    std.mem.writeInt(u32, archive[0..4], 0x02014b50, .little);
    std.mem.writeInt(u16, archive[28..30], name.len, .little);
    @memcpy(archive[46..central_len], name);
    std.mem.writeInt(u32, archive[central_len..][0..4], 0x06054b50, .little);
    std.mem.writeInt(u16, archive[central_len + 8 ..][0..2], 1, .little);
    std.mem.writeInt(u16, archive[central_len + 10 ..][0..2], 1, .little);
    std.mem.writeInt(u32, archive[central_len + 12 ..][0..4], central_len, .little);
    std.mem.writeInt(u32, archive[central_len + 16 ..][0..4], 0, .little);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "valid.zip", .data = &archive });
    const valid_path = try tmp.dir.realpathAlloc(alloc, "valid.zip");
    defer alloc.free(valid_path);
    try validatePortableZipEntries(alloc, valid_path);

    var with_trailing_byte: [archive.len + 1]u8 = undefined;
    @memcpy(with_trailing_byte[0..archive.len], &archive);
    with_trailing_byte[archive.len] = 0;
    try tmp.dir.writeFile(.{ .sub_path = "trailing.zip", .data = &with_trailing_byte });
    const trailing_path = try tmp.dir.realpathAlloc(alloc, "trailing.zip");
    defer alloc.free(trailing_path);
    try std.testing.expectError(
        error.InvalidPortableArchive,
        validatePortableZipEntries(alloc, trailing_path),
    );
}

test "portable update serializes helper launch handoff" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const lock_path = try std.fs.path.join(alloc, &.{ root, "portable-update-launch.lock" });
    defer alloc.free(lock_path);

    var first = (try openPortableLaunchLock(lock_path, true)).?;
    defer first.close();
    try std.testing.expect((try openPortableLaunchLock(lock_path, true)) == null);
}

test "portable pre-swap failure clears pending intent" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const install_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(install_root);
    const state_path = try std.fs.path.join(alloc, &.{ install_root, "update-state.json" });
    defer alloc.free(state_path);
    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.200"),
        .staged_kind = .portable,
        .portable_apply_phase = .pending,
        .portable_confirmation_token = try alloc.dupe(u8, "token"),
        .portable_watcher_pid = 4242,
        .portable_watcher_started_at = 99,
        .apply_requested_at = 123,
    };
    defer state.deinit(alloc);
    try saveState(state_path, &state);

    try std.testing.expect(try abandonPendingPortableApply(alloc, state_path, install_root));
    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.portable_apply_phase == null);
    try std.testing.expect(loaded.portable_confirmation_token == null);
    try std.testing.expectEqual(@as(u32, 0), loaded.portable_watcher_pid);
    try std.testing.expectEqual(@as(u64, 0), loaded.portable_watcher_started_at);
    try std.testing.expectEqual(@as(i64, 0), loaded.apply_requested_at);
}

test "portable recovery abandons stranded swapped transaction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const install_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(install_root);
    const state_path = try std.fs.path.join(alloc, &.{ install_root, "update-state.json" });
    defer alloc.free(state_path);
    const stage_dir = try std.fs.path.join(alloc, &.{ install_root, "updates", "1.3.200" });
    defer alloc.free(stage_dir);
    const artifact_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.200-windows-{s}-portable.zip",
        .{windowsInstallerArch()},
    );
    defer alloc.free(artifact_name);
    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.200"),
        .staged_kind = .portable,
        .staged_portable_path = try std.fs.path.join(alloc, &.{ stage_dir, artifact_name }),
        .staged_payload_path = try std.fs.path.join(alloc, &.{ stage_dir, "payload", "noctty" }),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        .portable_apply_phase = .swapped,
        .portable_backup_path = try std.fs.path.join(alloc, &.{ stage_dir, "backup" }),
        .portable_confirmation_token = try alloc.dupe(u8, "token"),
        .apply_requested_at = 123,
    };
    defer state.deinit(alloc);
    for ([_]portable_apply.Phase{ .swapped, .rollback }) |phase| {
        if (phase == .rollback) try tmp.dir.makePath("updates/1.3.200");
        state.portable_apply_phase = phase;
        try saveState(state_path, &state);

        try std.testing.expect(!(try launchPortableHelper(alloc, state_path, install_root, .rollback)));
        const message = (try takePortableUpdateFailure(alloc)).?;
        defer alloc.free(message);
        try std.testing.expect(std.mem.indexOf(u8, message, "recovery files are missing") != null);

        var loaded = try loadState(alloc, state_path);
        defer loaded.deinit(alloc);
        try std.testing.expect(loaded.portable_apply_phase == null);
        try std.testing.expect(loaded.staged_version == null);
        try std.testing.expect(loaded.staged_kind == null);
        try std.testing.expect(loaded.portable_backup_path == null);
        try std.testing.expect(loaded.portable_confirmation_token == null);
        try std.testing.expectEqual(@as(i64, 0), loaded.apply_requested_at);
    }

    try tmp.dir.makePath("updates/1.3.200/backup");
    try tmp.dir.writeFile(.{
        .sub_path = "updates/1.3.200/backup/.complete",
        .data = "locked",
    });
    const marker_path = try std.fs.path.join(alloc, &.{ stage_dir, "backup", ".complete" });
    defer alloc.free(marker_path);
    const marker_path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, marker_path);
    defer alloc.free(marker_path_w);
    // dwShareMode=0 denies subsequent opens per the Microsoft CreateFileW
    // contract, giving this test a deterministic transient access failure.
    const held = std.os.windows.kernel32.CreateFileW(
        marker_path_w.ptr,
        std.os.windows.GENERIC_READ,
        0,
        null,
        std.os.windows.OPEN_EXISTING,
        std.os.windows.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (held == std.os.windows.INVALID_HANDLE_VALUE) {
        return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
    }
    defer std.os.windows.CloseHandle(held);

    state.portable_apply_phase = .swapped;
    try saveState(state_path, &state);
    try std.testing.expectError(
        error.AccessDenied,
        abandonUnrecoverablePortableApply(alloc, state_path, install_root),
    );
    {
        var loaded = try loadState(alloc, state_path);
        defer loaded.deinit(alloc);
        try std.testing.expectEqual(portable_apply.Phase.swapped, loaded.portable_apply_phase.?);
    }

    state.portable_watcher_pid = std.os.windows.GetCurrentProcessId();
    state.portable_watcher_started_at = processCreationTime(std.os.windows.GetCurrentProcess()).?;
    try saveState(state_path, &state);
    try std.testing.expect(!(try abandonUnrecoverablePortableApply(alloc, state_path, install_root)));
    var owned = try loadState(alloc, state_path);
    defer owned.deinit(alloc);
    try std.testing.expectEqual(portable_apply.Phase.swapped, owned.portable_apply_phase.?);
    try std.testing.expectEqual(state.portable_watcher_pid, owned.portable_watcher_pid);
    try std.testing.expectEqual(state.portable_watcher_started_at, owned.portable_watcher_started_at);
}

test "portable recovery preserves complete rollback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "noctty.com", .data = "old-build" });
    const install_root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(install_root);
    const state_path = try std.fs.path.join(alloc, &.{ install_root, "update-state.json" });
    defer alloc.free(state_path);
    const stage_dir = try std.fs.path.join(alloc, &.{ install_root, "updates", "1.3.200" });
    defer alloc.free(stage_dir);
    const backup_path = try std.fs.path.join(alloc, &.{ stage_dir, "backup" });
    defer alloc.free(backup_path);
    try portable_apply.prepareBackup(alloc, install_root, backup_path);
    const artifact_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.200-windows-{s}-portable.zip",
        .{windowsInstallerArch()},
    );
    defer alloc.free(artifact_name);
    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.200"),
        .staged_kind = .portable,
        .staged_portable_path = try std.fs.path.join(alloc, &.{ stage_dir, artifact_name }),
        .staged_payload_path = try std.fs.path.join(alloc, &.{ stage_dir, "payload", "noctty" }),
        .staged_sha256 = try alloc.dupe(u8, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
        .staged_at = 456,
        .apply_requested_at = 123,
        .portable_apply_phase = .swapped,
        .portable_backup_path = try alloc.dupe(u8, backup_path),
        .portable_confirmation_token = try alloc.dupe(u8, "token"),
    };
    defer state.deinit(alloc);

    for ([_]portable_apply.Phase{ .swapped, .rollback }) |phase| {
        try tmp.dir.writeFile(.{ .sub_path = "noctty.com", .data = "broken-new-build" });
        state.portable_apply_phase = phase;
        try saveState(state_path, &state);

        try std.testing.expect(!(try abandonUnrecoverablePortableApply(
            alloc,
            state_path,
            install_root,
        )));
        var loaded = try loadState(alloc, state_path);
        defer loaded.deinit(alloc);
        try std.testing.expectEqualStrings(state.staged_version.?, loaded.staged_version.?);
        try std.testing.expectEqual(state.staged_kind.?, loaded.staged_kind.?);
        try std.testing.expectEqualStrings(state.staged_portable_path.?, loaded.staged_portable_path.?);
        try std.testing.expectEqualStrings(state.staged_payload_path.?, loaded.staged_payload_path.?);
        try std.testing.expectEqualStrings(state.staged_sha256.?, loaded.staged_sha256.?);
        try std.testing.expectEqual(state.staged_at, loaded.staged_at);
        try std.testing.expectEqual(state.apply_requested_at, loaded.apply_requested_at);
        try std.testing.expectEqual(phase, loaded.portable_apply_phase.?);
        try std.testing.expectEqualStrings(state.portable_backup_path.?, loaded.portable_backup_path.?);
        try std.testing.expectEqualStrings(state.portable_confirmation_token.?, loaded.portable_confirmation_token.?);
        try std.testing.expectEqual(state.portable_watcher_pid, loaded.portable_watcher_pid);
        try std.testing.expectEqual(state.portable_watcher_started_at, loaded.portable_watcher_started_at);

        try portable_apply.rollback(alloc, install_root, backup_path);
        const restored = try tmp.dir.readFileAlloc(alloc, "noctty.com", 32);
        defer alloc.free(restored);
        try std.testing.expectEqualStrings("old-build", restored);
    }
}

test "confirmed portable cleanup failure cannot rearm startup gating" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("updates/1.3.200/backup");
    try tmp.dir.writeFile(.{ .sub_path = "updates/1.3.200/backup/held.txt", .data = "held" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const state_path = try std.fs.path.join(alloc, &.{ root, "update-state.json" });
    defer alloc.free(state_path);
    const stage_dir = try std.fs.path.join(alloc, &.{ root, "updates", "1.3.200" });
    defer alloc.free(stage_dir);
    const artifact_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.200-windows-{s}-portable.zip",
        .{windowsInstallerArch()},
    );
    defer alloc.free(artifact_name);
    var state: State = .{
        .staged_version = try alloc.dupe(u8, "1.3.200"),
        .staged_kind = .portable,
        .staged_portable_path = try std.fs.path.join(alloc, &.{ stage_dir, artifact_name }),
        .staged_payload_path = try std.fs.path.join(alloc, &.{ stage_dir, "payload", "noctty" }),
        .portable_apply_phase = .confirmed,
        .portable_backup_path = try std.fs.path.join(alloc, &.{ stage_dir, "backup" }),
    };
    defer state.deinit(alloc);
    try saveState(state_path, &state);

    const held_path = try std.fs.path.join(alloc, &.{ stage_dir, "backup", "held.txt" });
    defer alloc.free(held_path);
    const held = try openLockedInstaller(held_path);
    defer held.close();
    try finalizePortableConfirmation(alloc, state_path);

    var loaded = try loadState(alloc, state_path);
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.portable_apply_phase == null);
    try std.testing.expect(loaded.staged_version == null);
    try std.testing.expect(loaded.staged_kind == null);
    try std.fs.accessAbsolute(held_path, .{});
}

test "portable relaunch replays original argv" {
    const alloc = std.testing.allocator;
    const original = [_][]const u8{
        "-e",
        "C:\\Program Files\\Tool\\tool.exe",
        "argument with spaces",
        "--working-directory=C:\\work tree",
        "--window-width=120",
        "--config-file",
        "C:\\config files\\noctty.conf",
    };
    const argv = try buildInstalledNocttyArgv(alloc, "D:\\portable\\noctty.exe", &original);
    defer alloc.free(argv);
    try std.testing.expectEqual(@as(usize, original.len + 1), argv.len);
    try std.testing.expectEqualStrings("D:\\portable\\noctty.exe", argv[0]);
    for (original, 0..) |expected, index| {
        try std.testing.expectEqualStrings(expected, argv[index + 1]);
    }
}

test "authenticated portable manifest rejects mismatched non-PE resource" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("payload/share/shell-integration/powershell");
    try tmp.dir.writeFile(.{
        .sub_path = "payload/share/shell-integration/powershell/integration.ps1",
        .data = "malicious replacement",
    });
    const payload_root = try tmp.dir.realpathAlloc(alloc, "payload");
    defer alloc.free(payload_root);
    try std.testing.expectError(
        error.PortablePayloadManifestMismatch,
        verifyPortablePayloadAgainstManifest(
            alloc,
            payload_root,
            "0000000000000000000000000000000000000000000000000000000000000000 *share/shell-integration/powershell/integration.ps1\n",
        ),
    );
}

test "state JSON writer escapes ASCII control characters" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const state_path = try std.fs.path.join(alloc, &.{ tmp_path, "noctty-test", "update-state.json" });
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
        \\d00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00d *noctty-1.3.100-windows-x64-setup.exe
        \\00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *other.exe
    ,
        "noctty-1.3.100-windows-x64-setup.exe",
    );
    try std.testing.expectEqualStrings(
        "d00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00d",
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "checksum parser preserves spaces in manifest paths" {
    const digest = try parseExpectedSha256(
        "d00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00dd00df00d *share/ghostty/themes/12-bit Rainbow\n",
        "share/ghostty/themes/12-bit Rainbow",
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
            "noctty-1.3.100-windows-x64-setup.exe",
        ),
    );
}

test "checksum parser rejects duplicate installer entries" {
    try std.testing.expectError(
        error.InstallerChecksumDuplicate,
        parseExpectedSha256(
            \\00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff *noctty-1.3.100-windows-x64-setup.exe
            \\ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100 *noctty-1.3.100-windows-x64-setup.exe
        ,
            "noctty-1.3.100-windows-x64-setup.exe",
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

test "update redirect target resolution accepts absolute HTTPS URL" {
    const alloc = std.testing.allocator;
    const resolved = try resolveRedirectTarget(
        alloc,
        "https://updates.example/releases/latest",
        "https://cdn.example/noctty/latest.json",
    );
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("https://cdn.example/noctty/latest.json", resolved);
}

test "update redirect target resolution resolves a relative URL" {
    const alloc = std.testing.allocator;
    const resolved = try resolveRedirectTarget(
        alloc,
        "https://updates.example/releases/stable/latest.json",
        "../next.json",
    );
    defer alloc.free(resolved);
    try std.testing.expectEqualStrings("https://updates.example/releases/next.json", resolved);
}

test "update redirect target resolution refuses plaintext HTTP" {
    try std.testing.expectError(
        error.InvalidUpdateUrl,
        resolveRedirectTarget(
            std.testing.allocator,
            "https://updates.example/releases/latest",
            "http://updates.example/releases/latest",
        ),
    );
}

test "update redirect target resolution refuses garbage target" {
    try std.testing.expectError(
        error.InvalidUpdateUrl,
        resolveRedirectTarget(
            std.testing.allocator,
            "https://updates.example/releases/latest",
            "//[",
        ),
    );
}

test "windows install staging rejects relative state path before download" {
    const alloc = std.testing.allocator;
    var release: Release = .{
        .version_text = try alloc.dupe(u8, "1.3.100"),
        .release_url = try alloc.dupe(u8, "https://example.invalid/release"),
        .windows_install = .{
            .installer_name = try alloc.dupe(u8, "noctty-1.3.100-windows-x64-setup.exe"),
            .installer_url = try alloc.dupe(u8, "https://example.invalid/noctty-1.3.100-windows-x64-setup.exe"),
            .checksums_url = try alloc.dupe(u8, "https://example.invalid/SHA256SUMS.txt"),
        },
    };
    defer release.deinit(alloc);

    try std.testing.expectError(
        error.InvalidStatePath,
        stageWindowsInstall(alloc, "relative-update-state.json", latest_stable_api_url, &release, .installer),
    );
}

test "portable staging fails closed before download without signed manifest asset" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const state_path = try std.fs.path.join(alloc, &.{ root, "update-state.json" });
    defer alloc.free(state_path);
    var release: Release = .{
        .version_text = try alloc.dupe(u8, "1.3.200"),
        .release_url = try alloc.dupe(u8, "https://example.invalid/release"),
        .windows_install = .{
            .installer_name = try alloc.dupe(u8, "setup.exe"),
            .installer_url = try alloc.dupe(u8, "https://example.invalid/setup.exe"),
            .portable_name = try alloc.dupe(u8, "noctty-1.3.200-windows-x64-portable.zip"),
            .portable_url = try alloc.dupe(u8, "https://example.invalid/portable.zip"),
            .checksums_url = try alloc.dupe(u8, "https://example.invalid/SHA256SUMS.txt"),
        },
    };
    defer release.deinit(alloc);

    try std.testing.expectError(
        error.PortablePayloadManifestUnavailable,
        stageWindowsInstall(alloc, state_path, &release, .portable),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("updates", .{}));
}

test "portable staging refuses every active apply phase" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const state_path = try std.fs.path.join(alloc, &.{ root, "update-state.json" });
    defer alloc.free(state_path);
    var release: Release = .{
        .version_text = try alloc.dupe(u8, "1.3.200"),
        .release_url = try alloc.dupe(u8, "https://example.invalid/release"),
        .windows_install = .{
            .installer_name = try alloc.dupe(u8, "setup.exe"),
            .installer_url = try alloc.dupe(u8, "https://example.invalid/setup.exe"),
            .checksums_url = try alloc.dupe(u8, "https://example.invalid/SHA256SUMS.txt"),
        },
    };
    defer release.deinit(alloc);

    for (std.enums.values(portable_apply.Phase)) |phase| {
        var state: State = .{ .portable_apply_phase = phase };
        try saveState(state_path, &state);
        try std.testing.expectError(
            error.PortableUpdateTransactionActive,
            stageWindowsInstall(alloc, state_path, &release, .installer),
        );
    }
}

test "release parser does not invent a portable payload manifest" {
    const alloc = std.testing.allocator;
    const installer_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const portable_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.100-windows-{s}-portable.zip",
        .{windowsInstallerArch()},
    );
    defer alloc.free(portable_name);
    const checksum_name = windowsChecksumsAssetName();
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/noctty/releases/tag/v1.3.100",
        \\  "assets": [
        \\    {{
        \\      "name": "{s}",
        \\      "browser_download_url": "https://example.invalid/{s}"
        \\    }},
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
        .{ installer_name, installer_name, portable_name, portable_name, checksum_name, checksum_name },
    );
    defer alloc.free(body);

    var release = try parseLatestStableReleaseResponse(alloc, body);
    defer release.deinit(alloc);

    try std.testing.expect(release.windows_install != null);
    try std.testing.expectEqualStrings(portable_name, release.windows_install.?.portable_name.?);
    const portable_url = try std.fmt.allocPrint(alloc, "https://example.invalid/{s}", .{portable_name});
    defer alloc.free(portable_url);
    try std.testing.expectEqualStrings(portable_url, release.windows_install.?.portable_url.?);
    try std.testing.expect(release.windows_install.?.portable_manifest_name == null);
    try std.testing.expect(release.windows_install.?.portable_manifest_url == null);
}

test "release parser rejects non-HTTPS release URL" {
    try std.testing.expectError(
        error.InvalidUpdateUrl,
        parseLatestStableReleaseResponse(
            std.testing.allocator,
            \\{
            \\  "tag_name": "v1.3.100",
            \\  "html_url": "http://updates.example/releases/1.3.100",
            \\  "assets": []
            \\}
            ,
        ),
    );
}

test "release parser rejects non-HTTPS Windows asset URLs" {
    const alloc = std.testing.allocator;
    const installer_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();

    const cases = [_]struct {
        installer_scheme: []const u8,
        checksums_scheme: []const u8,
    }{
        .{ .installer_scheme = "http", .checksums_scheme = "https" },
        .{ .installer_scheme = "https", .checksums_scheme = "http" },
    };

    for (cases) |case| {
        const body = try std.fmt.allocPrint(
            alloc,
            \\{{
            \\  "tag_name": "v1.3.100",
            \\  "html_url": "https://updates.example/releases/1.3.100",
            \\  "assets": [
            \\    {{
            \\      "name": "{s}",
            \\      "browser_download_url": "{s}://updates.example/{s}"
            \\    }},
            \\    {{
            \\      "name": "{s}",
            \\      "browser_download_url": "{s}://updates.example/{s}"
            \\    }}
            \\  ]
            \\}}
        ,
            .{
                installer_name,
                case.installer_scheme,
                installer_name,
                checksum_name,
                case.checksums_scheme,
                checksum_name,
            },
        );
        defer alloc.free(body);

        try std.testing.expectError(
            error.InvalidUpdateUrl,
            parseLatestStableReleaseResponse(alloc, body),
        );
    }
}

test "release parser selects windows install candidate when checksum metadata is present" {
    const alloc = std.testing.allocator;
    const installer_name = try std.fmt.allocPrint(
        alloc,
        "noctty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/noctty/releases/tag/v1.3.100",
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
        "noctty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/noctty/releases/tag/v1.3.100",
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
        "noctty-1.3.100-windows-{s}-setup.exe",
        .{windowsInstallerArch()},
    );
    defer alloc.free(installer_name);
    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v1.3.100",
        \\  "html_url": "https://github.com/amanthanvi/noctty/releases/tag/v1.3.100",
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
        "noctty-{s}-windows-{s}-setup.exe",
        .{ version_text, windowsInstallerArch() },
    );
    defer alloc.free(installer_name);
    const checksum_name = windowsChecksumsAssetName();

    const body = try std.fmt.allocPrint(
        alloc,
        \\{{
        \\  "tag_name": "v{s}",
        \\  "html_url": "https://github.com/amanthanvi/noctty/releases/tag/v{s}",
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

test "WinTrust certificate chain entry matches SDK ABI" {
    const expected_size: usize = if (@sizeOf(usize) == 8) 88 else 60;
    const expected_cert_offset: usize = if (@sizeOf(usize) == 8) 8 else 4;
    const expected_chain_offset: usize = if (@sizeOf(usize) == 8) 80 else 56;

    try std.testing.expectEqual(expected_size, @sizeOf(CryptProviderCert));
    try std.testing.expectEqual(expected_cert_offset, @offsetOf(CryptProviderCert, "pCert"));
    try std.testing.expectEqual(expected_chain_offset, @offsetOf(CryptProviderCert, "pChainElement"));
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

test "DER element rejects overflowing offsets and lengths" {
    const short = [_]u8{ der_tag_sequence, 0 };
    try std.testing.expectError(error.InvalidDer, readDerElement(&short, std.math.maxInt(usize)));

    const maximal_length = [_]u8{
        der_tag_sequence, 0x88,
        0xff,             0xff,
        0xff,             0xff,
        0xff,             0xff,
        0xff,             0xff,
    };
    try std.testing.expectError(error.InvalidDer, readDerElement(&maximal_length, 0));
}
