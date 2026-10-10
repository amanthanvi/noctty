//! Program status records (OSC 7501) for one terminal, and the pure parts
//! of how noctty presents them.
//!
//! Specification: https://www.superlogical.com/rex/docs/build/program-status
//!
//! The terminal core only validates reports (see
//! `terminal/osc/parsers/program_status.zig`). The embedder keeps the
//! records, so `Records` here applies the specification's record and
//! lifetime rules:
//!
//! - one record per id, the root record has no id;
//! - each report replaces its record completely;
//! - `state=clear` removes the record and every record beneath it, and
//!   without an id removes every record;
//! - a new shell prompt or the program's exit removes working, blocked and
//!   idle records, and done and error records survive both;
//! - a full reset removes every record;
//! - at `max_records` the least recently updated record makes room.
//!
//! Done and error records stay until the user has seen them, which the
//! caller signals with `acknowledge` (the tab became visible in a
//! foreground window).
//!
//! Everything else in this file is presentation that does not need Win32:
//! the indicator a tab shows, the taskbar progress for a root record, the
//! text for notifications and UI Automation, and notification rate limits.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const progress_report = @import("../progress_report.zig");

const osc = terminal.osc;
const program_status = osc.program_status;
pub const Report = osc.Command.ProgramStatus.Report;
pub const State = osc.Command.ProgramStatus.State;
pub const Kind = osc.Command.ProgramStatus.Kind;

/// The most records one terminal keeps. This is the specification's
/// default; it also requires at least 64.
pub const max_records = 256;

/// One program status record. Every string is a slice of `buf`, which the
/// record owns, so replacing a record is one allocation.
pub const Record = struct {
    buf: []u8,

    /// Empty for the root record.
    id: []const u8,
    state: State,
    kind: ?Kind,
    progress: ?u8,

    /// The record's own `app`, not inherited. See `Records.app`.
    app: ?[]const u8,

    /// Decoded UTF-8 without control characters, still untrusted.
    title: ?[]const u8,
    msg: ?[]const u8,

    /// `Records.seq` when a report last replaced this record.
    updated: u64,

    fn init(alloc: Allocator, report: Report, updated: u64) Allocator.Error!Record {
        // The parser validated the report, so these can't fail and fit.
        var title_buf: [program_status.max_title_bytes]u8 = undefined;
        var title_writer: std.Io.Writer = .fixed(&title_buf);
        report.writeText(.title, &title_writer) catch unreachable;
        var msg_buf: [program_status.max_msg_bytes]u8 = undefined;
        var msg_writer: std.Io.Writer = .fixed(&msg_buf);
        report.writeText(.msg, &msg_writer) catch unreachable;

        const id = report.readOption(.id) orelse "";
        const app = report.readOption(.app) orelse "";
        const title = title_writer.buffered();
        const msg = msg_writer.buffered();

        const buf = try alloc.alloc(u8, id.len + app.len + title.len + msg.len);
        var parts: Parts = .{ .buf = buf };
        return .{
            .buf = buf,
            .id = parts.take(id),
            .state = report.state,
            .kind = report.readOption(.kind),
            .progress = report.readOption(.progress),
            .app = optional(parts.take(app)),
            .title = optional(parts.take(title)),
            .msg = optional(parts.take(msg)),
            .updated = updated,
        };
    }

    fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.buf);
        self.* = undefined;
    }

    /// Whether this record is `id` itself or beneath it. Every record is
    /// beneath the root.
    fn within(self: *const Record, id: []const u8) bool {
        if (id.len == 0) return true;
        if (!std.mem.startsWith(u8, self.id, id)) return false;
        return self.id.len == id.len or self.id[id.len] == '/';
    }

    /// Blocked, done and error are what a user is told about.
    fn needsUser(self: *const Record) bool {
        return switch (self.state) {
            .blocked, .done, .@"error" => true,
            .idle, .working, .clear => false,
        };
    }

    const Parts = struct {
        buf: []u8,
        pos: usize = 0,

        fn take(self: *Parts, value: []const u8) []const u8 {
            const out = self.buf[self.pos..][0..value.len];
            @memcpy(out, value);
            self.pos += value.len;
            return out;
        }
    };

    fn optional(value: []const u8) ?[]const u8 {
        return if (value.len == 0) null else value;
    }
};

/// The records of one terminal.
pub const Records = struct {
    list: std.ArrayListUnmanaged(Record) = .empty,

    /// Bumped by every report, so `Record.updated` orders records by
    /// how recently a report replaced them.
    seq: u64 = 0,

    /// Whether a report arrived since the last full reset. From the first
    /// report on, OSC 9;4 no longer drives the taskbar: a mapped 9;4 would
    /// erase what the program reported.
    reported: bool = false,

    /// Frees every record and leaves the records empty rather than
    /// undefined: a screen reader can ask a tab for its status at any time,
    /// including while a surface is torn down but still in its tab.
    pub fn deinit(self: *Records, alloc: Allocator) void {
        for (self.list.items) |*record| record.deinit(alloc);
        self.list.deinit(alloc);
        self.* = .{};
    }

    /// Apply a validated report. Returns the record when the report brought
    /// something new for the user: it put the record into blocked, done or
    /// error, the record was not already saying the same thing, and it is
    /// not a step of work that is still going (see `stepOfRunningWork`).
    /// The pointer is valid until the records next change.
    pub fn apply(
        self: *Records,
        alloc: Allocator,
        report: Report,
    ) Allocator.Error!?*const Record {
        self.reported = true;
        if (report.state == .clear) {
            self.clear(alloc, report.readOption(.id) orelse "");
            return null;
        }

        self.seq += 1;
        var record = try Record.init(alloc, report, self.seq);
        if (self.find(record.id)) |i| {
            const slot = &self.list.items[i];
            const repeated = sameNews(slot, &record);
            slot.deinit(alloc);
            slot.* = record;
            return if (!repeated and self.isNews(slot)) slot else null;
        }

        errdefer record.deinit(alloc);
        if (self.list.items.len >= max_records) self.evictOldest(alloc);
        try self.list.append(alloc, record);
        const slot = &self.list.items[self.list.items.len - 1];
        return if (self.isNews(slot)) slot else null;
    }

    fn isNews(self: *const Records, record: *const Record) bool {
        return record.needsUser() and !self.stepOfRunningWork(record);
    }

    /// Whether `record` is done or failed beneath a record that is still
    /// working or blocked, such as one region of a deploy that is still
    /// going. Such a step neither leads what the terminal shows nor is news:
    /// the work it belongs to reports when it ends.
    fn stepOfRunningWork(self: *const Records, record: *const Record) bool {
        if (record.state != .done and record.state != .@"error") return false;
        var id = record.id;
        while (id.len > 0) {
            id = parentId(id);
            const i = self.find(id) orelse continue;
            switch (self.list.items[i].state) {
                .working, .blocked => return true,
                .idle, .done, .@"error", .clear => {},
            }
        }
        return false;
    }

    /// A new shell prompt started, or the program running in the terminal
    /// exited. Working and blocked records end with the program that set
    /// them, and so does idle: the program sitting at its own prompt is
    /// gone. Done and error stay until the user has seen them.
    pub fn programEnded(self: *Records, alloc: Allocator) bool {
        return self.removeWhere(alloc, struct {
            fn f(record: *const Record) bool {
                return switch (record.state) {
                    .working, .blocked, .idle => true,
                    .done, .@"error", .clear => false,
                };
            }
        }.f);
    }

    /// The user has seen this terminal: stop showing done and error. The
    /// records turn idle rather than go, so their `app` still names the
    /// records beneath them; a new done or error from the program is news
    /// again, and idle records end with the program.
    pub fn acknowledge(self: *Records) bool {
        var changed = false;
        for (self.list.items) |*record| {
            if (record.state != .done and record.state != .@"error") continue;
            record.state = .idle;
            changed = true;
        }
        return changed;
    }

    /// A full reset (RIS) removes every record and lets OSC 9;4 drive the
    /// taskbar again.
    pub fn reset(self: *Records, alloc: Allocator) void {
        for (self.list.items) |*record| record.deinit(alloc);
        self.list.clearRetainingCapacity();
        self.reported = false;
    }

    pub fn root(self: *const Records) ?*const Record {
        const i = self.find("") orelse return null;
        return &self.list.items[i];
    }

    /// The record that decides what this terminal shows: the most urgent
    /// state, then the root record, then the most recently updated one.
    /// Idle records never lead, because idle shows nothing, and neither do
    /// steps of work that is still going.
    pub fn headline(self: *const Records) ?*const Record {
        var best: ?*const Record = null;
        for (self.list.items) |*record| {
            if (record.state == .idle or self.stepOfRunningWork(record)) continue;
            const current = best orelse {
                best = record;
                continue;
            };
            const rank = Indicator.of(record).rank();
            const best_rank = Indicator.of(current).rank();
            if (rank != best_rank) {
                if (rank > best_rank) best = record;
                continue;
            }
            if (current.id.len == 0) continue;
            if (record.id.len == 0 or record.updated > current.updated) best = record;
        }
        return best;
    }

    pub fn indicator(self: *const Records) Indicator {
        return .of(self.headline());
    }

    /// The record's `app`, or the nearest ancestor's when it has none. The
    /// root record is the ancestor of every other record.
    pub fn app(self: *const Records, record: *const Record) ?[]const u8 {
        if (record.app) |value| return value;
        var id = record.id;
        while (id.len > 0) {
            id = parentId(id);
            const i = self.find(id) orelse continue;
            if (self.list.items[i].app) |value| return value;
        }
        return null;
    }

    fn find(self: *const Records, id: []const u8) ?usize {
        for (self.list.items, 0..) |*record, i| {
            if (std.mem.eql(u8, record.id, id)) return i;
        }
        return null;
    }

    fn clear(self: *Records, alloc: Allocator, id: []const u8) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            if (self.list.items[i].within(id)) {
                self.list.items[i].deinit(alloc);
                _ = self.list.swapRemove(i);
            } else i += 1;
        }
    }

    fn removeWhere(
        self: *Records,
        alloc: Allocator,
        comptime pred: fn (*const Record) bool,
    ) bool {
        var removed = false;
        var i: usize = 0;
        while (i < self.list.items.len) {
            if (pred(&self.list.items[i])) {
                self.list.items[i].deinit(alloc);
                _ = self.list.swapRemove(i);
                removed = true;
            } else i += 1;
        }
        return removed;
    }

    fn evictOldest(self: *Records, alloc: Allocator) void {
        var oldest: usize = 0;
        for (self.list.items, 0..) |*record, i| {
            if (record.updated < self.list.items[oldest].updated) oldest = i;
        }
        self.list.items[oldest].deinit(alloc);
        _ = self.list.swapRemove(oldest);
    }

    fn sameNews(old: *const Record, new: *const Record) bool {
        return old.state == new.state and
            old.kind == new.kind and
            optionalEql(old.msg, new.msg);
    }
};

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

/// The id of `id`'s parent; the root record, "", is every record's
/// ancestor.
fn parentId(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '/')) |slash| id[0..slash] else "";
}

/// What a tab shows for its terminals. Blocked outranks error, which
/// outranks done, which outranks working.
pub const Indicator = union(enum) {
    none,
    working: ?u8,
    done,
    failed,
    blocked: ?Kind,

    pub fn of(record: ?*const Record) Indicator {
        const r = record orelse return .none;
        return switch (r.state) {
            .idle, .clear => .none,
            .working => .{ .working = r.progress },
            .done => .done,
            .@"error" => .failed,
            .blocked => .{ .blocked = r.kind },
        };
    }

    pub fn rank(self: Indicator) u8 {
        return switch (self) {
            .none => 0,
            .working => 1,
            .done => 2,
            .failed => 3,
            .blocked => 4,
        };
    }

    pub fn eql(a: Indicator, b: Indicator) bool {
        return std.meta.eql(a, b);
    }

    /// Whether `a` and `b` read the same aside from progress, which is
    /// what decides if assistive technology hears about a change.
    pub fn sameKind(a: Indicator, b: Indicator) bool {
        return switch (a) {
            .working => b == .working,
            else => a.eql(b),
        };
    }

    /// Blocked, failed and done tabs are the ones that need the user.
    pub fn needsUser(self: Indicator) bool {
        return self.rank() >= Indicator.rank(.done);
    }
};

/// The color of a tab's status badge, as GDI's 0x00BBGGRR. Working takes
/// the tab accent and failed the theme's error color; blocked and done use
/// Windows 11's caution and success colors for the theme, so they read like
/// the system's own status badges. High contrast ignores this and draws
/// every badge in the text color: the badges differ in shape, too.
pub fn badgeColor(indicator: Indicator, is_dark: bool, accent: u32, error_color: u32) u32 {
    return switch (indicator) {
        .none, .working => accent,
        .failed => error_color,
        .blocked => if (is_dark) colorref(0xFC, 0xE1, 0x00) else colorref(0x9D, 0x5D, 0x00),
        .done => if (is_dark) colorref(0x6C, 0xCB, 0x5F) else colorref(0x0F, 0x7B, 0x0F),
    };
}

fn colorref(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);
}

/// Where "go to the tab that needs attention" goes: the most urgent of
/// `indicators` other than `current` (blocked, then failed, then done), and
/// among equally urgent ones the first after `current` in order, wrapping
/// around. Leaving the current tab out lets repeating the action move on
/// from a tab that still needs the user. Null when no other tab needs them.
pub fn nextNeedingUser(indicators: []const Indicator, current: ?usize) ?usize {
    const begin = if (current) |i| i + 1 else 0;
    var best: ?usize = null;
    for (0..indicators.len) |step| {
        const i = (begin + step) % indicators.len;
        if (current == i or !indicators[i].needsUser()) continue;
        if (best) |b| if (indicators[i].rank() <= indicators[b].rank()) continue;
        best = i;
    }
    return best;
}

/// The taskbar progress for a terminal's root record, as an OSC 9;4
/// report so the existing taskbar code shows it. Working maps to normal
/// or indeterminate progress, blocked to the paused (yellow) bar and error
/// to the error (red) bar, both full when the program sent no progress so
/// the state is visible at all. Idle and done show no progress.
pub fn taskbarReport(root: ?*const Record) ?progress_report.Report {
    const record = root orelse return null;
    return switch (record.state) {
        .working => if (record.progress) |value|
            .{ .state = .set, .progress = value }
        else
            .{ .state = .indeterminate },
        .blocked => .{ .state = .pause, .progress = record.progress orelse 100 },
        .@"error" => .{ .state = .@"error", .progress = 100 },
        .idle, .done, .clear => null,
    };
}

/// What a record says about itself, for a person: "needs permission",
/// "failed".
fn statePhrase(state: State, kind: ?Kind) []const u8 {
    return switch (state) {
        .working => "is working",
        .idle, .clear => "is idle",
        .done => "is done",
        .@"error" => "failed",
        .blocked => if (kind) |k| switch (k) {
            .permission => "needs permission",
            .question => "has a question",
            .auth => "needs you to sign in",
        } else "needs your input",
    };
}

/// The longest program-supplied text noctty shows outside the grid, in
/// bytes. A notification or a screen reader has no use for 2 KiB of it.
pub const max_shown_text_bytes = 240;

/// Write `text` for display outside the terminal grid: without bidi
/// controls and invisible formatting characters, so a program can't
/// reorder or hide what the notification says, and with line and
/// paragraph separators as spaces. Cuts at `max_bytes` on a codepoint
/// boundary and marks the cut with an ellipsis. Text that isn't valid
/// UTF-8 is skipped byte by byte; the parser only lets valid UTF-8 through.
pub fn writeSanitized(
    writer: *std.Io.Writer,
    text: []const u8,
    max_bytes: usize,
) std.Io.Writer.Error!void {
    const ellipsis = "\u{2026}";
    var written: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            continue;
        };
        const bytes = text[i..][0..len];
        i += len;
        if (isHidden(cp)) continue;
        const out: []const u8 = if (cp == 0x2028 or cp == 0x2029) " " else bytes;
        if (written + out.len > max_bytes) {
            try writer.writeAll(ellipsis);
            return;
        }
        try writer.writeAll(out);
        written += out.len;
    }
}

/// Bidi controls and characters that draw nothing: Unicode's format
/// characters (general category Cf), the combining grapheme joiner, the
/// variation selectors, the Mongolian free variation selectors, the Khmer
/// inherent vowels, and the Hangul fillers that render as blank.
fn isHidden(cp: u21) bool {
    return switch (cp) {
        0x00AD,
        0x034F,
        0x0600...0x0605,
        0x061C,
        0x06DD,
        0x070F,
        0x0890...0x0891,
        0x08E2,
        0x115F,
        0x1160,
        0x17B4,
        0x17B5,
        0x180B...0x180F,
        0x200B...0x200F,
        0x202A...0x202E,
        0x2060...0x2064,
        0x2066...0x206F,
        0x3164,
        0xFE00...0xFE0F,
        0xFEFF,
        0xFFA0,
        0xFFF9...0xFFFB,
        0x110BD,
        0x110CD,
        0x13430...0x1343F,
        0x1BCA0...0x1BCA3,
        0x1D173...0x1D17A,
        0xE0001,
        0xE0020...0xE007F,
        0xE0100...0xE01EF,
        => true,
        else => false,
    };
}

/// Who a record speaks for: its title, else its (inherited) app.
pub fn subject(records: *const Records, record: *const Record) ?[]const u8 {
    return record.title orelse records.app(record);
}

/// The same as `statePhrase`, to start a line with: "Needs permission".
fn stateLabel(state: State, kind: ?Kind) []const u8 {
    return switch (state) {
        .working => "Working",
        .idle, .clear => "Idle",
        .done => "Done",
        .@"error" => "Failed",
        .blocked => if (kind) |k| switch (k) {
            .permission => "Needs permission",
            .question => "Has a question",
            .auth => "Needs you to sign in",
        } else "Needs your input",
    };
}

/// One line saying what `record` is doing, such as
/// `cargo is working, 40%` or `claude needs permission: Allow edit?`.
/// Used for the tab's UI Automation status and a notification's title
/// (without the message there). `fallback` names the record when it has
/// no title or app; without one the line starts with the state, as in
/// `Needs permission: Allow edit?`.
pub fn writeStatusLine(
    writer: *std.Io.Writer,
    records: *const Records,
    record: *const Record,
    fallback: ?[]const u8,
    with_msg: bool,
) std.Io.Writer.Error!void {
    if (subject(records, record) orelse fallback) |name| {
        try writeSanitized(writer, name, 64);
        try writer.writeByte(' ');
        try writer.writeAll(statePhrase(record.state, record.kind));
    } else {
        try writer.writeAll(stateLabel(record.state, record.kind));
    }
    if (record.state == .working or record.state == .blocked) {
        if (record.progress) |value| try writer.print(", {d}%", .{value});
    }
    if (with_msg) if (record.msg) |msg| {
        try writer.writeAll(": ");
        try writeSanitized(writer, msg, max_shown_text_bytes);
    };
}

/// Limits how often program status notifications reach the desktop: one
/// per terminal per `per_terminal_ms`, and at most `burst` across the app
/// in any `window_ms`. A program flapping between states can't spam, and
/// several agents finishing together still each get a notification.
pub const NotifyLimiter = struct {
    pub const per_terminal_ms = 5 * std.time.ms_per_s;
    pub const window_ms = 10 * std.time.ms_per_s;
    pub const burst = 3;

    /// When the app last let a notification through, oldest first.
    recent: [burst]?u64 = @splat(null),

    /// Whether a terminal that last notified at `last` may notify at
    /// `now`. Records the notification when it may.
    pub fn allow(self: *NotifyLimiter, last: *?u64, now: u64) bool {
        if (last.*) |prev| if (now -| prev < per_terminal_ms) return false;
        if (self.recent[0]) |oldest| if (now -| oldest < window_ms) return false;
        std.mem.copyForwards(?u64, self.recent[0 .. burst - 1], self.recent[1..]);
        self.recent[burst - 1] = now;
        last.* = now;
        return true;
    }
};

const testing = std.testing;

/// Parse `body` (everything after `7501;`) and apply it. Returns whether
/// the report was news.
fn testApply(records: *Records, body: []const u8) !bool {
    var p: osc.Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7501;");
    p.nextSlice(body);
    const cmd = p.end('\x1b') orelse return error.InvalidReport;
    return try records.apply(testing.allocator, cmd.program_status.report) != null;
}

fn testFind(records: *const Records, id: []const u8) ?*const Record {
    const i = records.find(id) orelse return null;
    return &records.list.items[i];
}

test "a report replaces its record completely" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    // "Plan"
    _ = try testApply(&records, "state=working:progress=40:app=cargo:title=UGxhbg");
    try testing.expect(records.reported);
    _ = try testApply(&records, "state=working");
    const root = records.root().?;
    try testing.expect(root.progress == null);
    try testing.expect(root.app == null);
    try testing.expect(root.title == null);
    try testing.expectEqual(@as(usize, 1), records.list.items.len);
}

test "root and child records coexist and children inherit app" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=working:app=terraform");
    _ = try testApply(&records, "state=working:id=deploy/us-east");
    _ = try testApply(&records, "state=working:id=deploy:app=tf");
    try testing.expectEqual(@as(usize, 3), records.list.items.len);
    const child = testFind(&records, "deploy/us-east").?;
    try testing.expectEqualStrings("tf", records.app(child).?);
    _ = try testApply(&records, "state=clear:id=deploy");
    _ = try testApply(&records, "state=working:id=other/x");
    try testing.expectEqualStrings("terraform", records.app(testFind(&records, "other/x").?).?);
}

test "clear is hierarchical and without an id clears everything" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=working");
    _ = try testApply(&records, "state=working:id=build");
    _ = try testApply(&records, "state=working:id=build/test");
    _ = try testApply(&records, "state=working:id=builder");
    _ = try testApply(&records, "state=clear:id=build");
    try testing.expect(testFind(&records, "build") == null);
    try testing.expect(testFind(&records, "build/test") == null);
    try testing.expect(testFind(&records, "builder") != null);
    try testing.expect(records.root() != null);

    _ = try testApply(&records, "state=clear");
    try testing.expectEqual(@as(usize, 0), records.list.items.len);
    // A clear is still a report: OSC 9;4 stays unmapped until a reset.
    try testing.expect(records.reported);
}

test "a new prompt or exit drops working, blocked and idle but keeps done and error" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=working:id=a");
    _ = try testApply(&records, "state=blocked:id=b");
    _ = try testApply(&records, "state=idle:id=c");
    _ = try testApply(&records, "state=done:id=d");
    _ = try testApply(&records, "state=error:id=e");
    try testing.expect(records.programEnded(testing.allocator));
    try testing.expectEqual(@as(usize, 2), records.list.items.len);
    try testing.expect(testFind(&records, "d") != null);
    try testing.expect(testFind(&records, "e") != null);
    try testing.expect(!records.programEnded(testing.allocator));

    // Seen, they go idle and show nothing; the next prompt ends them.
    try testing.expect(records.acknowledge());
    try testing.expect(!records.acknowledge());
    try testing.expect(records.indicator().eql(.none));
    try testing.expect(records.programEnded(testing.allocator));
    try testing.expectEqual(@as(usize, 0), records.list.items.len);
}

test "an acknowledged record still names the records beneath it" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=done:app=claude");
    _ = try testApply(&records, "state=blocked:id=tool");
    try testing.expect(records.acknowledge());
    try testing.expectEqualStrings("claude", records.app(testFind(&records, "tool").?).?);
    // The same done again, after the user saw the first, is news.
    try testing.expect(try testApply(&records, "state=done:app=claude"));
}

test "a step that ends inside running work is neither news nor shown" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=working:id=deploy");
    try testing.expect(!try testApply(&records, "state=done:id=deploy/us-east"));
    try testing.expect(!try testApply(&records, "state=error:id=deploy/eu"));
    try testing.expect(records.indicator().eql(.{ .working = null }));

    // A blocked step needs the user whatever its parent is doing.
    try testing.expect(try testApply(&records, "state=blocked:id=deploy/ap"));
    _ = try testApply(&records, "state=clear:id=deploy/ap");

    // Once the work ends, its steps show; the job's own end is the news.
    try testing.expect(try testApply(&records, "state=done:id=deploy"));
    try testing.expect(records.indicator().eql(.failed));

    // A working root holds back steps at any depth.
    records.reset(testing.allocator);
    _ = try testApply(&records, "state=working");
    try testing.expect(!try testApply(&records, "state=done:id=a/b/c"));
    try testing.expect(records.indicator().eql(.{ .working = null }));
}

test "reset clears every record and re-enables OSC 9;4" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    _ = try testApply(&records, "state=done");
    records.reset(testing.allocator);
    try testing.expectEqual(@as(usize, 0), records.list.items.len);
    try testing.expect(!records.reported);
}

test "the least recently updated record makes room at the cap" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    var buf: [64]u8 = undefined;
    for (0..max_records) |i| {
        _ = try testApply(&records, try std.fmt.bufPrint(&buf, "state=working:id=r{d}", .{i}));
    }
    // Touch r0 so r1 is now the oldest.
    _ = try testApply(&records, "state=working:id=r0");
    _ = try testApply(&records, "state=working:id=new");
    try testing.expectEqual(@as(usize, max_records), records.list.items.len);
    try testing.expect(testFind(&records, "r0") != null);
    try testing.expect(testFind(&records, "r1") == null);
    try testing.expect(testFind(&records, "new") != null);
}

test "news is a record newly blocked, done or failed" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    try testing.expect(!try testApply(&records, "state=working"));
    // "Allow?"
    try testing.expect(try testApply(&records, "state=blocked:kind=permission:msg=QWxsb3c/"));
    // The same request again is not news, even with new progress.
    try testing.expect(!try testApply(&records, "state=blocked:kind=permission:msg=QWxsb3c/:progress=5"));
    // A different question is.
    try testing.expect(try testApply(&records, "state=blocked:kind=question:msg=QWxsb3c/"));
    try testing.expect(!try testApply(&records, "state=working"));
    try testing.expect(try testApply(&records, "state=done"));
    try testing.expect(try testApply(&records, "state=error:id=child"));
    try testing.expect(!try testApply(&records, "state=clear"));
}

test "the headline is the most urgent record, then root, then most recent" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    try testing.expect(records.indicator().eql(.none));
    _ = try testApply(&records, "state=idle");
    try testing.expect(records.indicator().eql(.none));
    _ = try testApply(&records, "state=working:id=a:progress=10");
    _ = try testApply(&records, "state=working:progress=50");
    _ = try testApply(&records, "state=working:id=b:progress=90");
    // Root wins among working records.
    try testing.expect(records.indicator().eql(.{ .working = 50 }));
    // Done and failed outrank working when they aren't steps of it.
    _ = try testApply(&records, "state=idle");
    _ = try testApply(&records, "state=done:id=c");
    try testing.expect(records.indicator().eql(.done));
    _ = try testApply(&records, "state=error:id=d");
    try testing.expect(records.indicator().eql(.failed));
    _ = try testApply(&records, "state=blocked:id=e:kind=auth");
    _ = try testApply(&records, "state=blocked:id=f");
    // The most recently updated blocked record wins.
    try testing.expect(records.indicator().eql(.{ .blocked = null }));
    _ = try testApply(&records, "state=blocked:id=e:kind=auth");
    try testing.expect(records.indicator().eql(.{ .blocked = .auth }));
}

test "indicator ranks and kinds" {
    try testing.expect(Indicator.sameKind(.{ .working = 1 }, .{ .working = 2 }));
    try testing.expect(!Indicator.sameKind(.{ .working = 1 }, .done));
    try testing.expect(!Indicator.sameKind(.{ .blocked = .auth }, .{ .blocked = null }));
    try testing.expect(!Indicator.needsUser(.{ .working = null }));
    try testing.expect(Indicator.needsUser(.done));
    try testing.expect(Indicator.needsUser(.failed));
    try testing.expect(Indicator.needsUser(.{ .blocked = null }));
}

test "the next tab needing attention is the most urgent, then the next in order" {
    const tabs = [_]Indicator{
        .done, // 0
        .{ .working = 50 }, // 1
        .{ .blocked = null }, // 2
        .none, // 3
        .{ .blocked = .auth }, // 4
        .failed, // 5
    };
    // Blocked tabs come first, in order after the current tab.
    try testing.expectEqual(@as(?usize, 2), nextNeedingUser(&tabs, 0));
    try testing.expectEqual(@as(?usize, 4), nextNeedingUser(&tabs, 2));
    try testing.expectEqual(@as(?usize, 2), nextNeedingUser(&tabs, 4));
    // Without a current tab, from the start.
    try testing.expectEqual(@as(?usize, 2), nextNeedingUser(&tabs, null));

    // The current tab is never the target, so the only blocked tab hands
    // over to the next most urgent one, and a lone one goes nowhere.
    const one_blocked = [_]Indicator{ .done, .{ .blocked = null }, .failed };
    try testing.expectEqual(@as(?usize, 2), nextNeedingUser(&one_blocked, 1));
    const one = [_]Indicator{ .none, .{ .blocked = null } };
    try testing.expectEqual(@as(?usize, null), nextNeedingUser(&one, 1));

    // Failed before done; working and idle never.
    const rest = [_]Indicator{ .done, .{ .working = null }, .failed, .done };
    try testing.expectEqual(@as(?usize, 3), nextNeedingUser(&rest, 2));
    try testing.expectEqual(@as(?usize, 2), nextNeedingUser(&rest, 0));
    const quiet = [_]Indicator{ .none, .{ .working = 10 } };
    try testing.expectEqual(@as(?usize, null), nextNeedingUser(&quiet, 0));
    try testing.expectEqual(@as(?usize, null), nextNeedingUser(&.{}, null));
}

test "taskbar progress for the root record" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);

    try testing.expect(taskbarReport(records.root()) == null);
    _ = try testApply(&records, "state=working");
    try testing.expectEqual(progress_report.State.indeterminate, taskbarReport(records.root()).?.state);
    _ = try testApply(&records, "state=working:progress=30");
    try testing.expectEqual(@as(?u8, 30), taskbarReport(records.root()).?.progress);
    _ = try testApply(&records, "state=blocked");
    try testing.expectEqual(progress_report.State.pause, taskbarReport(records.root()).?.state);
    try testing.expectEqual(@as(?u8, 100), taskbarReport(records.root()).?.progress);
    _ = try testApply(&records, "state=blocked:progress=20");
    try testing.expectEqual(@as(?u8, 20), taskbarReport(records.root()).?.progress);
    _ = try testApply(&records, "state=error");
    try testing.expectEqual(progress_report.State.@"error", taskbarReport(records.root()).?.state);
    _ = try testApply(&records, "state=done");
    try testing.expect(taskbarReport(records.root()) == null);
    _ = try testApply(&records, "state=idle");
    try testing.expect(taskbarReport(records.root()) == null);
}

test "sanitized text drops bidi controls and invisible characters" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSanitized(&w, "ok\u{202E}gpj.exe\u{2066}\u{200B}\u{FEFF}\u{00AD}!\u{2028}x\u{E0041}", 100);
    try testing.expectEqualStrings("okgpj.exe! x", w.buffered());

    w = .fixed(&buf);
    try writeSanitized(&w, "a\u{FE0F}\u{17B4}\u{180B}\u{E0100}b", 100);
    try testing.expectEqualStrings("ab", w.buffered());

    w = .fixed(&buf);
    try writeSanitized(&w, "安全な文", 7);
    try testing.expectEqualStrings("安全\u{2026}", w.buffered());

    w = .fixed(&buf);
    try writeSanitized(&w, "abc", 3);
    try testing.expectEqualStrings("abc", w.buffered());
}

test "status lines name the record and say what it needs" {
    var records: Records = .{};
    defer records.deinit(testing.allocator);
    var buf: [512]u8 = undefined;

    // "Allow edit?"
    _ = try testApply(&records, "state=blocked:kind=permission:app=claude:msg=QWxsb3cgZWRpdD8");
    var w: std.Io.Writer = .fixed(&buf);
    try writeStatusLine(&w, &records, records.root().?, "pwsh", true);
    try testing.expectEqualStrings("claude needs permission: Allow edit?", w.buffered());

    // A title of "a\u{202E}b", with a right-to-left override.
    _ = try testApply(&records, "state=working:progress=40:title=YeKArmI");
    w = .fixed(&buf);
    try writeStatusLine(&w, &records, records.root().?, "pwsh", true);
    try testing.expectEqualStrings("ab is working, 40%", w.buffered());

    // "Build broke"
    _ = try testApply(&records, "state=error:msg=QnVpbGQgYnJva2U");
    w = .fixed(&buf);
    try writeStatusLine(&w, &records, records.root().?, "pwsh", false);
    try testing.expectEqualStrings("pwsh failed", w.buffered());
    w = .fixed(&buf);
    try writeStatusLine(&w, &records, records.root().?, null, true);
    try testing.expectEqualStrings("Failed: Build broke", w.buffered());

    _ = try testApply(&records, "state=blocked:kind=auth:app=gh");
    w = .fixed(&buf);
    try writeStatusLine(&w, &records, records.root().?, "pwsh", false);
    try testing.expectEqualStrings("gh needs you to sign in", w.buffered());
}

test "notifications are rate limited per terminal and across the app" {
    var limiter: NotifyLimiter = .{};
    var a: ?u64 = null;
    var b: ?u64 = null;
    var c: ?u64 = null;
    var d: ?u64 = null;

    try testing.expect(limiter.allow(&a, 1000));
    // The same terminal has to wait.
    try testing.expect(!limiter.allow(&a, 2000));
    // Others don't, up to the burst.
    try testing.expect(limiter.allow(&b, 2000));
    try testing.expect(limiter.allow(&c, 3000));
    try testing.expect(!limiter.allow(&d, 4000));
    try testing.expect(d == null);
    // The window moves on.
    try testing.expect(limiter.allow(&d, 11_000));
    try testing.expect(limiter.allow(&a, 12_000));
}
