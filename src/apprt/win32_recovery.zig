//! Pure recovery policy and persistence contracts for the Win32 runtime.
//!
//! Integration order matters:
//!   1. Load and parse the previous record.
//!   2. Call `decide` before appending the current attempt.
//!   3. Append the current attempt and persist it (`persistRecoveryRecordAtPath`
//!      in win32.zig, under the ledger lock).
//!   4. Around restoring the saved session, mark the attempt with
//!      `mergeMarkAttempt` (began, then finished), and mark it with
//!      `mergeMarkReady` only after normal startup is usable.
//!
//! An attempt without `ready_at_unix_ms` is evidence that the process ended
//! before reaching the ready marker, unless it records that OpenGL could not
//! start (`opengl_unavailable_at_unix_ms`). This module performs no filesystem
//! work.

const std = @import("std");
const win32_repeat = @import("win32_repeat.zig");
const Allocator = std.mem.Allocator;

pub const current_schema_version: u32 = 1;
pub const max_attempts: usize = 16;

pub const Policy = struct {
    failure_threshold: usize = 3,
    max_failure_age_ms: u64 = 7 * std.time.ms_per_day,
};

pub const Decision = enum {
    normal,
    safe_mode,
    /// Safe mode, and set the saved session aside: the failures that selected
    /// safe mode all ended while restoring it.
    quarantine_session,
};

pub const StartupPhase = enum {
    init,
    /// A session restore this attempt began has finished. (Older builds wrote
    /// it once the first window existed, restore or not.)
    window_created,
    ready,
    ready_persist_failed,
};

pub const StartupAttempt = struct {
    started_at_unix_ms: u64,
    ready_at_unix_ms: ?u64 = null,
    phase: StartupPhase = .init,
    last_win32_error: ?u32 = null,
    /// When this attempt began restoring the saved session. Written before the
    /// first window is restored, so a launch that ends during restore keeps it.
    session_restore_at_unix_ms: ?u64 = null,
    /// When this attempt gave up because OpenGL could not start, the failure
    /// the startup dialog reports. Such an attempt is no evidence for safe
    /// mode, which starts the same renderer.
    opengl_unavailable_at_unix_ms: ?u64 = null,
    /// The build that recorded the attempt.
    version: ?BuildVersion = null,
};

/// A build's `version_string`, so a ledger shows which build wrote each
/// attempt. Stored inline because attempts are copied out of the parse arena
/// and outlive it.
pub const BuildVersion = struct {
    bytes: [capacity]u8 = undefined,
    len: u8 = 0,

    pub const capacity = 64;

    /// A longer value keeps a prefix that ends on a UTF-8 boundary.
    pub fn init(value: []const u8) BuildVersion {
        var len = @min(value.len, capacity);
        while (len > 0 and len < value.len and value[len] & 0xC0 == 0x80) len -= 1;
        var result: BuildVersion = .{ .len = @intCast(len) };
        @memcpy(result.bytes[0..len], value[0..len]);
        return result;
    }

    pub fn slice(self: *const BuildVersion) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn jsonStringify(self: BuildVersion, jws: anytype) !void {
        try jws.write(self.slice());
    }

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) !BuildVersion {
        return .init(try std.json.innerParse([]const u8, alloc, source, options));
    }
};

pub const StartupAttemptRecord = struct {
    schema_version: u32 = current_schema_version,
    attempts: []const StartupAttempt = &.{},
};

const VersionHeader = struct {
    schema_version: u32,
};

pub const ValidationError = error{
    UnsupportedVersion,
    TooManyAttempts,
    AttemptsOutOfOrder,
    ReadyBeforeStart,
};

pub const AppendError = error{
    OutputBufferTooSmall,
    AttemptBeforeHistory,
};

pub const MergeReadyError = error{
    OutputBufferTooSmall,
    TargetAttemptMissing,
};

pub fn validate(record: StartupAttemptRecord) ValidationError!void {
    if (record.schema_version != current_schema_version) {
        return error.UnsupportedVersion;
    }
    if (record.attempts.len > max_attempts) return error.TooManyAttempts;

    var previous_start: ?u64 = null;
    for (record.attempts) |attempt| {
        if (previous_start) |previous| {
            if (attempt.started_at_unix_ms < previous) {
                return error.AttemptsOutOfOrder;
            }
        }
        if (attempt.ready_at_unix_ms) |ready_at| {
            if (ready_at < attempt.started_at_unix_ms) {
                return error.ReadyBeforeStart;
            }
        }
        previous_start = attempt.started_at_unix_ms;
    }
}

pub fn encodeAlloc(alloc: Allocator, record: StartupAttemptRecord) ![]u8 {
    try validate(record);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try std.json.Stringify.value(record, .{
        .whitespace = .minified,
        .emit_null_optional_fields = false,
    }, &out.writer);

    return try out.toOwnedSlice();
}

pub fn parseAlloc(
    alloc: Allocator,
    raw: []const u8,
) !std.json.Parsed(StartupAttemptRecord) {
    var header = try std.json.parseFromSlice(VersionHeader, alloc, raw, .{
        .ignore_unknown_fields = true,
    });
    defer header.deinit();

    if (header.value.schema_version > current_schema_version) return error.NewerSchema;
    if (header.value.schema_version != current_schema_version) {
        return error.UnsupportedVersion;
    }

    // A field a later build adds within this version must not make an older
    // build read the history as empty and replace it.
    var parsed = try std.json.parseFromSlice(StartupAttemptRecord, alloc, raw, .{
        .ignore_unknown_fields = true,
    });
    errdefer parsed.deinit();

    try validate(parsed.value);
    return parsed;
}

/// Copy the newest bounded history into `out` and append `attempt`.
/// `out` may be larger than `max_attempts`, but only the first
/// `max_attempts` slots can be returned.
pub fn appendBounded(
    record: StartupAttemptRecord,
    attempt: StartupAttempt,
    out: []StartupAttempt,
) (ValidationError || AppendError)!StartupAttemptRecord {
    try validate(record);
    if (out.len < max_attempts) return error.OutputBufferTooSmall;
    if (record.attempts.len > 0 and
        attempt.started_at_unix_ms < record.attempts[record.attempts.len - 1].started_at_unix_ms)
    {
        return error.AttemptBeforeHistory;
    }
    if (attempt.ready_at_unix_ms) |ready_at| {
        if (ready_at < attempt.started_at_unix_ms) return error.ReadyBeforeStart;
    }

    var retained_count = record.attempts.len;
    if (retained_count >= max_attempts) retained_count = max_attempts - 1;
    const output_count = retained_count + 1;
    const retained_start = record.attempts.len - retained_count;
    // Stage through fixed-size scratch so callers may reuse the record's
    // backing array as output without invoking overlapping-copy undefined
    // behavior when the oldest entry is trimmed.
    var retained: [max_attempts]StartupAttempt = undefined;
    @memcpy(retained[0..retained_count], record.attempts[retained_start..]);
    @memcpy(out[0..retained_count], retained[0..retained_count]);
    out[retained_count] = attempt;

    return .{
        .attempts = out[0..output_count],
    };
}

/// Merge two independently observed histories. Duplicate start markers name
/// the same attempt; retain the furthest lifecycle phase, any ready marker,
/// the raw persistence diagnosis, the restore and OpenGL flags and the version. The newest bounded history is returned.
pub fn mergeRecords(
    first: StartupAttemptRecord,
    second: StartupAttemptRecord,
    out: []StartupAttempt,
) (ValidationError || MergeReadyError)!StartupAttemptRecord {
    try validate(first);
    try validate(second);
    if (out.len < max_attempts) return error.OutputBufferTooSmall;

    var merged: [max_attempts * 2]StartupAttempt = undefined;
    var count: usize = 0;
    var first_i: usize = 0;
    var second_i: usize = 0;
    while (first_i < first.attempts.len or second_i < second.attempts.len) {
        const next = if (second_i >= second.attempts.len or
            (first_i < first.attempts.len and
                first.attempts[first_i].started_at_unix_ms <= second.attempts[second_i].started_at_unix_ms))
        blk: {
            const value = first.attempts[first_i];
            first_i += 1;
            break :blk value;
        } else blk: {
            const value = second.attempts[second_i];
            second_i += 1;
            break :blk value;
        };

        if (count > 0 and merged[count - 1].started_at_unix_ms == next.started_at_unix_ms) {
            const current = &merged[count - 1];
            if (next.ready_at_unix_ms) |next_ready| {
                if (current.ready_at_unix_ms == null or next_ready > current.ready_at_unix_ms.?) {
                    current.ready_at_unix_ms = next_ready;
                }
            }
            const phase_order = std.math.order(
                @intFromEnum(next.phase),
                @intFromEnum(current.phase),
            );
            if (phase_order == .gt) {
                current.phase = next.phase;
                current.last_win32_error = next.last_win32_error;
            } else if (phase_order == .eq and current.last_win32_error == null) {
                current.last_win32_error = next.last_win32_error;
            }
            current.session_restore_at_unix_ms = current.session_restore_at_unix_ms orelse next.session_restore_at_unix_ms;
            current.opengl_unavailable_at_unix_ms = current.opengl_unavailable_at_unix_ms orelse next.opengl_unavailable_at_unix_ms;
            current.version = current.version orelse next.version;
            continue;
        }
        merged[count] = next;
        count += 1;
    }

    const retained_count = @min(count, max_attempts);
    @memcpy(out[0..retained_count], merged[count - retained_count .. count]);
    const result: StartupAttemptRecord = .{ .attempts = out[0..retained_count] };
    try validate(result);
    return result;
}

/// Merge the startup snapshot retained by this process with a freshly-read
/// disk record, then mark this process's attempt ready. Attempts are keyed by
/// their monotonic wall-clock start marker; duplicate observations collapse,
/// preferring the observation that already reached ready. The newest bounded
/// history is returned in `out`.
pub fn mergeMarkReady(
    disk: StartupAttemptRecord,
    memory: StartupAttemptRecord,
    target_started_at_unix_ms: u64,
    ready_at_unix_ms: u64,
    out: []StartupAttempt,
) (ValidationError || MergeReadyError)!StartupAttemptRecord {
    const merged = try mergeRecords(disk, memory, out);
    const attempt = try findAttempt(out[0..merged.attempts.len], target_started_at_unix_ms);
    // A start can lie ahead of the clock: it is moved past the previous
    // attempt's (see win32.zig `beginRecoveryStartupAtPath`), and the clock can
    // be set back. Readiness must still land, or a healthy launch would count
    // as a failure once the clock catches up.
    attempt.ready_at_unix_ms = @max(ready_at_unix_ms, attempt.started_at_unix_ms);
    attempt.phase = .ready;
    attempt.last_win32_error = null;
    return merged;
}

/// What a marker records on this process's attempt around a session restore.
pub const AttemptMark = union(enum) {
    /// Began restoring the saved session at this time.
    session_restore: u64,
    /// Finished restoring it, whether or not any window came back.
    session_restored,
    /// Gave up at this time because OpenGL could not start.
    opengl_unavailable: u64,
};

/// As `mergeMarkReady`, but record `mark` on this process's attempt. A mark
/// never moves an attempt back: an earlier restore time stays, and only an
/// `init` attempt moves to `window_created`.
pub fn mergeMarkAttempt(
    disk: StartupAttemptRecord,
    memory: StartupAttemptRecord,
    target_started_at_unix_ms: u64,
    mark: AttemptMark,
    out: []StartupAttempt,
) (ValidationError || MergeReadyError)!StartupAttemptRecord {
    const merged = try mergeRecords(disk, memory, out);
    applyMark(try findAttempt(out[0..merged.attempts.len], target_started_at_unix_ms), mark);
    return merged;
}

pub fn applyMark(attempt: *StartupAttempt, mark: AttemptMark) void {
    switch (mark) {
        .session_restore => |at| if (attempt.session_restore_at_unix_ms == null) {
            attempt.session_restore_at_unix_ms = at;
        },
        .session_restored => if (attempt.phase == .init) {
            attempt.phase = .window_created;
        },
        .opengl_unavailable => |at| if (attempt.opengl_unavailable_at_unix_ms == null) {
            attempt.opengl_unavailable_at_unix_ms = at;
        },
    }
}

fn findAttempt(attempts: []StartupAttempt, started_at_unix_ms: u64) error{TargetAttemptMissing}!*StartupAttempt {
    for (attempts) |*attempt| {
        if (attempt.started_at_unix_ms == started_at_unix_ms) return attempt;
    }
    return error.TargetAttemptMissing;
}

/// The unresolved attempts that count toward safe mode, newest first. The walk
/// stops at the first ready attempt, future timestamp, or attempt older than
/// the policy window, which keeps old isolated crashes from accumulating
/// forever. An attempt that gave up because OpenGL could not start is passed
/// over: it is no evidence for safe mode, and it does not end a streak of
/// failures that are.
const RecentFailures = struct {
    attempts: []const StartupAttempt,
    now_unix_ms: u64,
    max_age_ms: u64,

    fn init(record: StartupAttemptRecord, now_unix_ms: u64, max_age_ms: u64) RecentFailures {
        return .{ .attempts = record.attempts, .now_unix_ms = now_unix_ms, .max_age_ms = max_age_ms };
    }

    fn next(self: *RecentFailures) ?StartupAttempt {
        while (self.attempts.len > 0) {
            const attempt = self.attempts[self.attempts.len - 1];
            if (attempt.ready_at_unix_ms != null) break;
            if (attempt.started_at_unix_ms > self.now_unix_ms) break;
            if (self.now_unix_ms - attempt.started_at_unix_ms > self.max_age_ms) break;
            self.attempts.len -= 1;
            if (attempt.opengl_unavailable_at_unix_ms == null) return attempt;
        }
        self.attempts.len = 0;
        return null;
    }
};

pub fn recentFailureCount(
    record: StartupAttemptRecord,
    now_unix_ms: u64,
    max_age_ms: u64,
) usize {
    var failures: RecentFailures = .init(record, now_unix_ms, max_age_ms);
    var count: usize = 0;
    while (failures.next() != null) count += 1;
    return count;
}

/// Repeated pre-ready failures select safe mode. When the latest of them all
/// ended after they began restoring the saved session and before the restore
/// finished, safe mode alone only postpones the next round: the session is set
/// aside as well.
pub fn decide(
    record: StartupAttemptRecord,
    now_unix_ms: u64,
    policy: Policy,
) Decision {
    if (policy.failure_threshold == 0) return .normal;
    var failures: RecentFailures = .init(record, now_unix_ms, policy.max_failure_age_ms);
    var all_ended_restoring = true;
    for (0..policy.failure_threshold) |_| {
        const attempt = failures.next() orelse return .normal;
        if (attempt.session_restore_at_unix_ms == null or attempt.phase != .init) all_ended_restoring = false;
    }
    return if (all_ended_restoring) .quarantine_session else .safe_mode;
}

test "win32 recovery record round trips strict schema v1" {
    const attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .ready_at_unix_ms = 120 },
        .{
            .started_at_unix_ms = 200,
            .phase = .ready_persist_failed,
            .last_win32_error = 32,
        },
    };
    const record: StartupAttemptRecord = .{ .attempts = &attempts };

    const encoded = try encodeAlloc(std.testing.allocator, record);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"attempts\":[{\"started_at_unix_ms\":100,\"ready_at_unix_ms\":120,\"phase\":\"init\"},{\"started_at_unix_ms\":200,\"phase\":\"ready_persist_failed\",\"last_win32_error\":32}]}",
        encoded,
    );

    var parsed = try parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.attempts.len);
    try std.testing.expectEqual(@as(?u64, 120), parsed.value.attempts[0].ready_at_unix_ms);
    try std.testing.expectEqual(@as(?u64, null), parsed.value.attempts[1].ready_at_unix_ms);
    try std.testing.expectEqual(StartupPhase.ready_persist_failed, parsed.value.attempts[1].phase);
    try std.testing.expectEqual(@as(?u32, 32), parsed.value.attempts[1].last_win32_error);
}

test "win32 recovery schema v1 defaults diagnosis for legacy attempts" {
    var parsed = try parseAlloc(
        std.testing.allocator,
        "{\"schema_version\":1,\"attempts\":[{\"started_at_unix_ms\":100},{\"started_at_unix_ms\":200,\"ready_at_unix_ms\":220}]}",
    );
    defer parsed.deinit();

    try std.testing.expectEqual(StartupPhase.init, parsed.value.attempts[0].phase);
    try std.testing.expectEqual(@as(?u32, null), parsed.value.attempts[0].last_win32_error);
    try std.testing.expectEqual(StartupPhase.init, parsed.value.attempts[1].phase);
    try std.testing.expectEqual(@as(?u32, null), parsed.value.attempts[1].last_win32_error);
}

test "win32 recovery ready merge preserves a concurrent attempt" {
    const memory_attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .ready_at_unix_ms = 120 },
        .{ .started_at_unix_ms = 200 },
    };
    const disk_attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .ready_at_unix_ms = 120 },
        .{ .started_at_unix_ms = 200 },
        .{ .started_at_unix_ms = 300 },
    };
    var out: [max_attempts]StartupAttempt = undefined;
    const merged = try mergeMarkReady(
        .{ .attempts = &disk_attempts },
        .{ .attempts = &memory_attempts },
        200,
        250,
        &out,
    );

    try std.testing.expectEqual(@as(usize, 3), merged.attempts.len);
    try std.testing.expectEqual(@as(?u64, 250), merged.attempts[1].ready_at_unix_ms);
    try std.testing.expectEqual(@as(u64, 300), merged.attempts[2].started_at_unix_ms);
    try std.testing.expectEqual(@as(?u64, null), merged.attempts[2].ready_at_unix_ms);
}

test "win32 recovery ready marker lands on a start ahead of the clock" {
    // The clock was set back: this launch started at max(now, last + 1).
    const attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 1000, .ready_at_unix_ms = 1100 },
        .{ .started_at_unix_ms = 1101 },
    };
    var out: [max_attempts]StartupAttempt = undefined;
    const merged = try mergeMarkReady(.{ .attempts = &attempts }, .{ .attempts = &attempts }, 1101, 600, &out);
    try std.testing.expectEqual(@as(?u64, 1101), merged.attempts[1].ready_at_unix_ms);
    try std.testing.expectEqual(StartupPhase.ready, merged.attempts[1].phase);
    // Resolved, so it never counts as a failure once the clock catches up.
    try std.testing.expectEqual(@as(usize, 0), recentFailureCount(merged, 5000, 10_000));
}

test "win32 recovery merge carries failed persistence diagnosis into next startup" {
    const disk_attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .phase = .window_created },
        .{ .started_at_unix_ms = 200, .phase = .window_created },
    };
    const pending_attempts = [_]StartupAttempt{
        .{
            .started_at_unix_ms = 200,
            .ready_at_unix_ms = 240,
            .phase = .ready_persist_failed,
            .last_win32_error = 32,
        },
    };
    var out: [max_attempts]StartupAttempt = undefined;
    const merged = try mergeRecords(
        .{ .attempts = &disk_attempts },
        .{ .attempts = &pending_attempts },
        &out,
    );

    try std.testing.expectEqual(@as(usize, 2), merged.attempts.len);
    try std.testing.expectEqual(@as(?u64, 240), merged.attempts[1].ready_at_unix_ms);
    try std.testing.expectEqual(StartupPhase.ready_persist_failed, merged.attempts[1].phase);
    try std.testing.expectEqual(@as(?u32, 32), merged.attempts[1].last_win32_error);
}

test "win32 recovery merge keeps error coupled to furthest phase" {
    const window_created = StartupAttempt{
        .started_at_unix_ms = 200,
        .phase = .window_created,
        .last_win32_error = 5,
    };
    const ready_failed = StartupAttempt{
        .started_at_unix_ms = 200,
        .ready_at_unix_ms = 240,
        .phase = .ready_persist_failed,
        .last_win32_error = 32,
    };
    var out: [max_attempts]StartupAttempt = undefined;
    const forward = try mergeRecords(
        .{ .attempts = &.{window_created} },
        .{ .attempts = &.{ready_failed} },
        &out,
    );
    try std.testing.expectEqual(StartupPhase.ready_persist_failed, forward.attempts[0].phase);
    try std.testing.expectEqual(@as(?u32, 32), forward.attempts[0].last_win32_error);

    const reverse = try mergeRecords(
        .{ .attempts = &.{ready_failed} },
        .{ .attempts = &.{window_created} },
        &out,
    );
    try std.testing.expectEqual(StartupPhase.ready_persist_failed, reverse.attempts[0].phase);
    try std.testing.expectEqual(@as(?u32, 32), reverse.attempts[0].last_win32_error);
}

test "win32 recovery parser separates newer schema and skips unknown fields" {
    try std.testing.expectError(
        error.NewerSchema,
        parseAlloc(std.testing.allocator, "{\"schema_version\":2,\"attempts\":[]}"),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        parseAlloc(std.testing.allocator, "{\"schema_version\":0,\"attempts\":[]}"),
    );

    var parsed = try parseAlloc(
        std.testing.allocator,
        "{\"schema_version\":1,\"future\":true,\"attempts\":[{\"started_at_unix_ms\":100,\"ready_at_unix_ms\":120,\"build\":\"1.4.0\"}]}",
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.attempts.len);
    try std.testing.expectEqual(@as(?u64, 120), parsed.value.attempts[0].ready_at_unix_ms);
}

test "win32 recovery validation rejects malformed history" {
    const out_of_order = [_]StartupAttempt{
        .{ .started_at_unix_ms = 200 },
        .{ .started_at_unix_ms = 100 },
    };
    try std.testing.expectError(
        error.AttemptsOutOfOrder,
        validate(.{ .attempts = &out_of_order }),
    );

    const ready_before_start = [_]StartupAttempt{
        .{ .started_at_unix_ms = 200, .ready_at_unix_ms = 199 },
    };
    try std.testing.expectError(
        error.ReadyBeforeStart,
        validate(.{ .attempts = &ready_before_start }),
    );
}

test "win32 recovery append retains newest bounded history" {
    var attempts: [max_attempts]StartupAttempt = undefined;
    for (&attempts, 0..) |*attempt, i| {
        attempt.* = .{ .started_at_unix_ms = @intCast(i + 1) };
    }
    var out: [max_attempts]StartupAttempt = undefined;
    const next = try appendBounded(
        .{ .attempts = &attempts },
        .{ .started_at_unix_ms = max_attempts + 1 },
        &out,
    );

    try std.testing.expectEqual(max_attempts, next.attempts.len);
    try std.testing.expectEqual(@as(u64, 2), next.attempts[0].started_at_unix_ms);
    try std.testing.expectEqual(@as(u64, max_attempts + 1), next.attempts[max_attempts - 1].started_at_unix_ms);
}

test "win32 recovery bounded append permits aliased input and output" {
    var attempts: [max_attempts]StartupAttempt = undefined;
    for (&attempts, 0..) |*attempt, i| {
        attempt.* = .{ .started_at_unix_ms = @intCast(i + 1) };
    }

    const next = try appendBounded(
        .{ .attempts = &attempts },
        .{ .started_at_unix_ms = max_attempts + 1 },
        &attempts,
    );
    try std.testing.expectEqual(max_attempts, next.attempts.len);
    try std.testing.expectEqual(@as(u64, 2), next.attempts[0].started_at_unix_ms);
    try std.testing.expectEqual(@as(u64, max_attempts + 1), next.attempts[max_attempts - 1].started_at_unix_ms);
}

test "win32 recovery ready attempt breaks consecutive failure count" {
    const attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200, .ready_at_unix_ms = 220 },
        .{ .started_at_unix_ms = 300 },
        .{ .started_at_unix_ms = 400 },
    };
    const record: StartupAttemptRecord = .{ .attempts = &attempts };
    try std.testing.expectEqual(@as(usize, 2), recentFailureCount(record, 500, 1_000));
    try std.testing.expectEqual(Decision.normal, decide(record, 500, .{}));
}

test "win32 recovery decision triggers safe mode after three recent failures" {
    const attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200 },
        .{ .started_at_unix_ms = 300 },
    };
    const record: StartupAttemptRecord = .{ .attempts = &attempts };
    try std.testing.expectEqual(Decision.safe_mode, decide(record, 400, .{
        .max_failure_age_ms = 1_000,
    }));
    try std.testing.expectEqual(Decision.normal, decide(record, 10_000, .{
        .max_failure_age_ms = 1_000,
    }));
}

test "win32 recovery sets the session aside only when the latest failures all restored it" {
    const restoring = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200, .session_restore_at_unix_ms = 210 },
        .{ .started_at_unix_ms = 300, .session_restore_at_unix_ms = 310 },
        .{ .started_at_unix_ms = 400, .session_restore_at_unix_ms = 410 },
    };
    // The unflagged fourth-newest failure is outside the threshold window.
    try std.testing.expectEqual(
        Decision.quarantine_session,
        decide(.{ .attempts = &restoring }, 500, .{}),
    );
    // Below the threshold nothing changes, flags or not.
    try std.testing.expectEqual(
        Decision.normal,
        decide(.{ .attempts = restoring[2..] }, 500, .{}),
    );

    // One of them finished its restore and ended later: not the session.
    var finished = restoring;
    finished[2].phase = .window_created;
    try std.testing.expectEqual(
        Decision.safe_mode,
        decide(.{ .attempts = &finished }, 500, .{}),
    );

    // The newest failure (a safe-mode launch that died) restored nothing.
    const safe_mode_died = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .session_restore_at_unix_ms = 110 },
        .{ .started_at_unix_ms = 200, .session_restore_at_unix_ms = 210 },
        .{ .started_at_unix_ms = 300, .session_restore_at_unix_ms = 310 },
        .{ .started_at_unix_ms = 400 },
    };
    try std.testing.expectEqual(
        Decision.safe_mode,
        decide(.{ .attempts = &safe_mode_died }, 500, .{}),
    );
}

test "win32 recovery never counts a start that failed for want of OpenGL" {
    // Three clean OpenGL start failures: safe mode uses the same renderer, so
    // it could not help, and the next launch stays normal.
    const no_opengl = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .opengl_unavailable_at_unix_ms = 110 },
        .{ .started_at_unix_ms = 200, .opengl_unavailable_at_unix_ms = 210 },
        .{ .started_at_unix_ms = 300, .opengl_unavailable_at_unix_ms = 310 },
    };
    try std.testing.expectEqual(@as(usize, 0), recentFailureCount(.{ .attempts = &no_opengl }, 400, 1_000));
    try std.testing.expectEqual(Decision.normal, decide(.{ .attempts = &no_opengl }, 400, .{}));

    // It does not end a streak either: real failures on both sides of it
    // still add up to safe mode.
    const crashes_around = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200, .opengl_unavailable_at_unix_ms = 210 },
        .{ .started_at_unix_ms = 300 },
        .{ .started_at_unix_ms = 400, .opengl_unavailable_at_unix_ms = 410 },
        .{ .started_at_unix_ms = 500 },
    };
    try std.testing.expectEqual(@as(usize, 3), recentFailureCount(.{ .attempts = &crashes_around }, 600, 1_000));
    try std.testing.expectEqual(Decision.safe_mode, decide(.{ .attempts = &crashes_around }, 600, .{}));

    // The age window and a ready attempt still end the count behind it.
    try std.testing.expectEqual(@as(usize, 1), recentFailureCount(.{ .attempts = &crashes_around }, 1_450, 1_000));
    var ready_behind = crashes_around;
    ready_behind[1].ready_at_unix_ms = 220;
    try std.testing.expectEqual(@as(usize, 2), recentFailureCount(.{ .attempts = &ready_behind }, 600, 1_000));
    // An attempt exactly at the window's edge still counts; one past it, or
    // one ahead of the clock, ends the walk even behind a skipped attempt.
    try std.testing.expectEqual(@as(usize, 3), recentFailureCount(.{ .attempts = &crashes_around }, 1_100, 1_000));
    try std.testing.expectEqual(@as(usize, 2), recentFailureCount(.{ .attempts = &crashes_around }, 1_101, 1_000));
    try std.testing.expectEqual(@as(usize, 0), recentFailureCount(.{ .attempts = &crashes_around }, 450, 1_000));
    try std.testing.expectEqual(Decision.normal, decide(.{ .attempts = &crashes_around }, 600, .{ .failure_threshold = 0 }));
}

test "win32 recovery judges the session by the failures it counted" {
    // The newest attempt failed for want of OpenGL; the three failures it
    // skips all ended restoring the session, so the session is set aside.
    const restoring = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .session_restore_at_unix_ms = 110 },
        .{ .started_at_unix_ms = 200, .session_restore_at_unix_ms = 210 },
        .{ .started_at_unix_ms = 300, .session_restore_at_unix_ms = 310 },
        .{ .started_at_unix_ms = 400, .opengl_unavailable_at_unix_ms = 410 },
    };
    try std.testing.expectEqual(Decision.quarantine_session, decide(.{ .attempts = &restoring }, 500, .{}));

    // A skipped attempt that also began a restore does not stand in for a
    // counted one that did not.
    const mixed = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200, .session_restore_at_unix_ms = 210 },
        .{ .started_at_unix_ms = 300, .session_restore_at_unix_ms = 310, .opengl_unavailable_at_unix_ms = 320 },
        .{ .started_at_unix_ms = 400, .session_restore_at_unix_ms = 410 },
    };
    try std.testing.expectEqual(Decision.safe_mode, decide(.{ .attempts = &mixed }, 500, .{}));
}

test "win32 recovery OpenGL marker round trips, merges and never moves" {
    const attempts = [_]StartupAttempt{.{ .started_at_unix_ms = 100, .opengl_unavailable_at_unix_ms = 140 }};
    const encoded = try encodeAlloc(std.testing.allocator, .{ .attempts = &attempts });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"attempts\":[{\"started_at_unix_ms\":100,\"phase\":\"init\",\"opengl_unavailable_at_unix_ms\":140}]}",
        encoded,
    );
    var parsed = try parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 140), parsed.value.attempts[0].opengl_unavailable_at_unix_ms);

    // Only the disk copy carries it; the ready merge keeps it.
    const memory = [_]StartupAttempt{.{ .started_at_unix_ms = 100 }};
    var out: [max_attempts]StartupAttempt = undefined;
    const merged = try mergeRecords(.{ .attempts = &memory }, .{ .attempts = &attempts }, &out);
    try std.testing.expectEqual(@as(?u64, 140), merged.attempts[0].opengl_unavailable_at_unix_ms);

    const marked = try mergeMarkAttempt(.{}, .{ .attempts = &memory }, 100, .{ .opengl_unavailable = 150 }, &out);
    try std.testing.expectEqual(@as(?u64, 150), marked.attempts[0].opengl_unavailable_at_unix_ms);
    applyMark(&out[0], .{ .opengl_unavailable = 999 });
    try std.testing.expectEqual(@as(?u64, 150), out[0].opengl_unavailable_at_unix_ms);
}

test "win32 recovery attempt marks flag this attempt and keep a concurrent one" {
    const memory_attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .ready_at_unix_ms = 120 },
        .{ .started_at_unix_ms = 200 },
    };
    const disk_attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .ready_at_unix_ms = 120 },
        .{ .started_at_unix_ms = 200 },
        .{ .started_at_unix_ms = 300 },
    };
    var out: [max_attempts]StartupAttempt = undefined;
    const merged = try mergeMarkAttempt(
        .{ .attempts = &disk_attempts },
        .{ .attempts = &memory_attempts },
        200,
        .{ .session_restore = 250 },
        &out,
    );
    try std.testing.expectEqual(@as(usize, 3), merged.attempts.len);
    try std.testing.expectEqual(@as(?u64, 250), merged.attempts[1].session_restore_at_unix_ms);
    try std.testing.expectEqual(@as(?u64, null), merged.attempts[2].session_restore_at_unix_ms);

    // The ready merge keeps the flag that only the disk copy carries.
    var ready_out: [max_attempts]StartupAttempt = undefined;
    const ready = try mergeMarkReady(merged, .{ .attempts = &memory_attempts }, 200, 260, &ready_out);
    try std.testing.expectEqual(@as(?u64, 250), ready.attempts[1].session_restore_at_unix_ms);
    try std.testing.expectEqual(@as(?u64, 260), ready.attempts[1].ready_at_unix_ms);
    try std.testing.expectError(
        error.TargetAttemptMissing,
        mergeMarkAttempt(merged, .{}, 999, .session_restored, &out),
    );

    // Finishing the restore moves `init` on, never a phase already past it,
    // and a second restore time does not replace the first.
    var attempt: StartupAttempt = .{ .started_at_unix_ms = 1, .session_restore_at_unix_ms = 5 };
    applyMark(&attempt, .{ .session_restore = 9 });
    applyMark(&attempt, .session_restored);
    try std.testing.expectEqual(@as(?u64, 5), attempt.session_restore_at_unix_ms);
    try std.testing.expectEqual(StartupPhase.window_created, attempt.phase);
    attempt.phase = .ready_persist_failed;
    applyMark(&attempt, .session_restored);
    try std.testing.expectEqual(StartupPhase.ready_persist_failed, attempt.phase);
}

test "win32 recovery attempt version round trips and stays bounded" {
    const attempts = [_]StartupAttempt{.{
        .started_at_unix_ms = 100,
        .session_restore_at_unix_ms = 110,
        .version = .init("1.3.2-dev+abc"),
    }};
    const encoded = try encodeAlloc(std.testing.allocator, .{ .attempts = &attempts });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"attempts\":[{\"started_at_unix_ms\":100,\"phase\":\"init\",\"session_restore_at_unix_ms\":110,\"version\":\"1.3.2-dev+abc\"}]}",
        encoded,
    );
    var parsed = try parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("1.3.2-dev+abc", parsed.value.attempts[0].version.?.slice());
    try std.testing.expectEqual(@as(?u64, 110), parsed.value.attempts[0].session_restore_at_unix_ms);

    // A longer value from some other build is cut, never rejected, and never
    // in the middle of a UTF-8 sequence.
    const long = "v" ++ comptime win32_repeat.repeat("\u{e9}", BuildVersion.capacity);
    const bounded = BuildVersion.init(long);
    try std.testing.expect(bounded.len < BuildVersion.capacity);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bounded.slice()));
    try std.testing.expect(std.mem.startsWith(u8, long, bounded.slice()));
    const raw = "{\"schema_version\":1,\"attempts\":[{\"started_at_unix_ms\":1,\"version\":\"" ++ long ++ "\"}]}";
    var long_parsed = try parseAlloc(std.testing.allocator, raw);
    defer long_parsed.deinit();
    try std.testing.expectEqualStrings(bounded.slice(), long_parsed.value.attempts[0].version.?.slice());
}
