//! Pure recovery policy and persistence contracts for the Win32 runtime.
//!
//! Integration order matters:
//!   1. Load and parse the previous record.
//!   2. Call `decide` before appending the current attempt.
//!   3. Append the current attempt and persist it through `writePlanAlloc`.
//!   4. Mark the latest attempt ready only after normal startup is usable.
//!
//! An attempt without `ready_at_unix_ms` is evidence that the process ended
//! before reaching the ready marker. This module performs no filesystem work;
//! callers execute its atomic-write and quarantine plans. In particular, a
//! quarantine plan is a sibling move, never a deletion contract.

const std = @import("std");
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
    quarantine_session,
};

pub const StartupAttempt = struct {
    started_at_unix_ms: u64,
    ready_at_unix_ms: ?u64 = null,
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

pub const MarkReadyError = error{
    NoAttempt,
    AlreadyReady,
    ReadyBeforeStart,
};

pub const MergeReadyError = error{
    OutputBufferTooSmall,
    TargetAttemptMissing,
    ReadyBeforeStart,
};

/// A caller-owned atomic replacement contract. Write `contents` to
/// `temporary_path`, flush and close it, then atomically replace `target_path`.
/// If replacement fails, remove only the temporary file; never remove the
/// existing target.
pub const AtomicWritePlan = struct {
    alloc: Allocator,
    target_path: []u8,
    temporary_path: []u8,
    contents: []u8,

    pub fn deinit(self: *AtomicWritePlan) void {
        self.alloc.free(self.target_path);
        self.alloc.free(self.temporary_path);
        self.alloc.free(self.contents);
        self.* = undefined;
    }
};

/// A caller-owned, non-destructive quarantine contract. Move `source_path` to
/// `destination_path` only after the session payload has independently failed
/// validation. A failed move leaves the source untouched.
pub const QuarantinePlan = struct {
    alloc: Allocator,
    source_path: []u8,
    destination_path: []u8,

    pub fn deinit(self: *QuarantinePlan) void {
        self.alloc.free(self.source_path);
        self.alloc.free(self.destination_path);
        self.* = undefined;
    }
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

    if (header.value.schema_version != current_schema_version) {
        return error.UnsupportedVersion;
    }

    var parsed = try std.json.parseFromSlice(StartupAttemptRecord, alloc, raw, .{
        .ignore_unknown_fields = false,
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

/// Mark the newest caller-owned attempt ready. Persist the containing record
/// after this succeeds; earlier attempts are deliberately immutable evidence.
pub fn markLatestReady(
    attempts: []StartupAttempt,
    ready_at_unix_ms: u64,
) MarkReadyError!void {
    if (attempts.len == 0) return error.NoAttempt;
    const latest = &attempts[attempts.len - 1];
    if (latest.ready_at_unix_ms != null) return error.AlreadyReady;
    if (ready_at_unix_ms < latest.started_at_unix_ms) {
        return error.ReadyBeforeStart;
    }
    latest.ready_at_unix_ms = ready_at_unix_ms;
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
    try validate(disk);
    try validate(memory);
    if (out.len < max_attempts) return error.OutputBufferTooSmall;

    var merged: [max_attempts * 2]StartupAttempt = undefined;
    var count: usize = 0;
    var disk_i: usize = 0;
    var memory_i: usize = 0;
    while (disk_i < disk.attempts.len or memory_i < memory.attempts.len) {
        const next = if (memory_i >= memory.attempts.len or
            (disk_i < disk.attempts.len and
                disk.attempts[disk_i].started_at_unix_ms <= memory.attempts[memory_i].started_at_unix_ms))
        blk: {
            const value = disk.attempts[disk_i];
            disk_i += 1;
            break :blk value;
        } else blk: {
            const value = memory.attempts[memory_i];
            memory_i += 1;
            break :blk value;
        };

        if (count > 0 and merged[count - 1].started_at_unix_ms == next.started_at_unix_ms) {
            if (merged[count - 1].ready_at_unix_ms == null and next.ready_at_unix_ms != null) {
                merged[count - 1].ready_at_unix_ms = next.ready_at_unix_ms;
            }
            continue;
        }
        merged[count] = next;
        count += 1;
    }

    var found = false;
    for (merged[0..count]) |*attempt| {
        if (attempt.started_at_unix_ms != target_started_at_unix_ms) continue;
        if (ready_at_unix_ms < attempt.started_at_unix_ms) return error.ReadyBeforeStart;
        attempt.ready_at_unix_ms = ready_at_unix_ms;
        found = true;
        break;
    }
    if (!found) return error.TargetAttemptMissing;

    const retained_count = @min(count, max_attempts);
    @memcpy(out[0..retained_count], merged[count - retained_count .. count]);
    const result: StartupAttemptRecord = .{ .attempts = out[0..retained_count] };
    try validate(result);
    return result;
}

/// Count consecutive unresolved attempts from newest to oldest. Counting stops
/// at the first ready attempt, future timestamp, or attempt older than the
/// policy window. This prevents old isolated crashes from accumulating forever.
pub fn recentFailureCount(
    record: StartupAttemptRecord,
    now_unix_ms: u64,
    max_age_ms: u64,
) usize {
    var count: usize = 0;
    var i = record.attempts.len;
    while (i > 0) {
        i -= 1;
        const attempt = record.attempts[i];
        if (attempt.ready_at_unix_ms != null) break;
        if (attempt.started_at_unix_ms > now_unix_ms) break;
        if (now_unix_ms - attempt.started_at_unix_ms > max_age_ms) break;
        count += 1;
    }
    return count;
}

/// Invalid session data takes precedence so the caller can preserve it under a
/// quarantine name before continuing. Otherwise repeated pre-ready failures
/// select safe mode.
pub fn decide(
    record: StartupAttemptRecord,
    now_unix_ms: u64,
    session_invalid: bool,
    policy: Policy,
) Decision {
    if (session_invalid) return .quarantine_session;
    if (policy.failure_threshold > 0 and
        recentFailureCount(record, now_unix_ms, policy.max_failure_age_ms) >= policy.failure_threshold)
    {
        return .safe_mode;
    }
    return .normal;
}

pub fn writePlanAlloc(
    alloc: Allocator,
    target_path: []const u8,
    record: StartupAttemptRecord,
    nonce: u64,
) !AtomicWritePlan {
    const target_owned = try alloc.dupe(u8, target_path);
    errdefer alloc.free(target_owned);

    // The caller supplies a per-attempt nonce (for example a process/startup
    // tuple hash). This keeps concurrent writers in the same directory from
    // truncating or replacing each other's temporary file.
    const temporary_path = try std.fmt.allocPrint(alloc, "{s}.tmp-{x}", .{ target_path, nonce });
    errdefer alloc.free(temporary_path);

    const contents = try encodeAlloc(alloc, record);
    errdefer alloc.free(contents);

    return .{
        .alloc = alloc,
        .target_path = target_owned,
        .temporary_path = temporary_path,
        .contents = contents,
    };
}

pub fn quarantinePlanAlloc(
    alloc: Allocator,
    session_path: []const u8,
    now_unix_ms: u64,
) !QuarantinePlan {
    const source_path = try alloc.dupe(u8, session_path);
    errdefer alloc.free(source_path);

    const destination_path = try std.fmt.allocPrint(
        alloc,
        "{s}.invalid-{d}",
        .{ session_path, now_unix_ms },
    );
    errdefer alloc.free(destination_path);

    return .{
        .alloc = alloc,
        .source_path = source_path,
        .destination_path = destination_path,
    };
}

test "win32 recovery record round trips strict schema v1" {
    const attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100, .ready_at_unix_ms = 120 },
        .{ .started_at_unix_ms = 200 },
    };
    const record: StartupAttemptRecord = .{ .attempts = &attempts };

    const encoded = try encodeAlloc(std.testing.allocator, record);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"schema_version\":1,\"attempts\":[{\"started_at_unix_ms\":100,\"ready_at_unix_ms\":120},{\"started_at_unix_ms\":200}]}",
        encoded,
    );

    var parsed = try parseAlloc(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.attempts.len);
    try std.testing.expectEqual(@as(?u64, 120), parsed.value.attempts[0].ready_at_unix_ms);
    try std.testing.expectEqual(@as(?u64, null), parsed.value.attempts[1].ready_at_unix_ms);
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

test "win32 recovery parser rejects unsupported and unknown schema" {
    try std.testing.expectError(
        error.UnsupportedVersion,
        parseAlloc(std.testing.allocator, "{\"schema_version\":2,\"attempts\":[]}"),
    );
    try std.testing.expectError(
        error.UnknownField,
        parseAlloc(std.testing.allocator, "{\"schema_version\":1,\"attempts\":[],\"future\":true}"),
    );
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
    try std.testing.expectEqual(Decision.normal, decide(record, 500, false, .{}));
}

test "win32 recovery decision triggers safe mode after three recent failures" {
    const attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200 },
        .{ .started_at_unix_ms = 300 },
    };
    const record: StartupAttemptRecord = .{ .attempts = &attempts };
    try std.testing.expectEqual(Decision.safe_mode, decide(record, 400, false, .{
        .max_failure_age_ms = 1_000,
    }));
    try std.testing.expectEqual(Decision.normal, decide(record, 10_000, false, .{
        .max_failure_age_ms = 1_000,
    }));
}

test "win32 recovery invalid session takes decision precedence" {
    const attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200 },
        .{ .started_at_unix_ms = 300 },
    };
    try std.testing.expectEqual(
        Decision.quarantine_session,
        decide(.{ .attempts = &attempts }, 400, true, .{}),
    );
}

test "win32 recovery mark ready mutates only newest attempt" {
    var attempts = [_]StartupAttempt{
        .{ .started_at_unix_ms = 100 },
        .{ .started_at_unix_ms = 200 },
    };
    try markLatestReady(&attempts, 250);
    try std.testing.expectEqual(@as(?u64, null), attempts[0].ready_at_unix_ms);
    try std.testing.expectEqual(@as(?u64, 250), attempts[1].ready_at_unix_ms);
    try std.testing.expectError(error.AlreadyReady, markLatestReady(&attempts, 260));
}

test "win32 recovery plans preserve target and session source paths" {
    const attempts = [_]StartupAttempt{.{ .started_at_unix_ms = 100 }};
    var write_plan = try writePlanAlloc(
        std.testing.allocator,
        "C:\\state\\startup-attempts.json",
        .{ .attempts = &attempts },
        0x1234,
    );
    defer write_plan.deinit();
    try std.testing.expectEqualStrings("C:\\state\\startup-attempts.json", write_plan.target_path);
    try std.testing.expectEqualStrings("C:\\state\\startup-attempts.json.tmp-1234", write_plan.temporary_path);

    var second_write_plan = try writePlanAlloc(
        std.testing.allocator,
        "C:\\state\\startup-attempts.json",
        .{ .attempts = &attempts },
        0x5678,
    );
    defer second_write_plan.deinit();
    try std.testing.expect(!std.mem.eql(u8, write_plan.temporary_path, second_write_plan.temporary_path));

    var quarantine = try quarantinePlanAlloc(
        std.testing.allocator,
        "C:\\state\\session-state.json",
        1234,
    );
    defer quarantine.deinit();
    try std.testing.expectEqualStrings("C:\\state\\session-state.json", quarantine.source_path);
    try std.testing.expectEqualStrings(
        "C:\\state\\session-state.json.invalid-1234",
        quarantine.destination_path,
    );
}
