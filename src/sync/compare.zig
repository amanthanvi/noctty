//! The in-process compare of an isolated child's own dump directory (PLAN.md
//! §2.7 RQ15, §19.3): the run rules `tools\role_compare3.py --isolated`
//! specifies, run inside the test exe without Python. An isolated parent
//! (`isolated.zig`) symbolises its child's dumps (`symbolise.zig`) and hands
//! them here with the reviewed table.
//!
//! The rules, as the prototype words them (its lines are reproduced here, so
//! a parent asserts the line the prototype would print):
//! - every dump in the directory is a child's (`kind=child`), else
//!   NOT-CHILD-DUMP; at least one exists, else MISSING-DUMP; each holds a
//!   pair, else EMPTY-DUMP; a dump without a header is BAD-DUMP;
//! - a header with a `problem=` field is BAD-DUMP too, its pairs not
//!   compared: the symboliser could not name them, or the child's writer
//!   failed to write one (`problem=append_failed`, `dump.Dump.append`), so
//!   the dump is a prefix whose lost pair could be off the table. This rule
//!   is this file's, not the prototype's: `role_compare3.py` reads only a
//!   header's first three fields and fails such a dump through the
//!   symboliser's unqualified keys (`symbolise.lost_line`) instead;
//! - each pair `<function key> <role>` is compared with the table: a key
//!   that names no `.zig` file is UNQUALIFIED-KEY, a pair the table does not
//!   hold PAIR-OUTSIDE-TABLE;
//! - the table: the reviewed seven-column one read in a phase's scope
//!   (`Scope`), or the two-column form of the prototype's fixtures (no
//!   scope); a row of the wrong form is BAD-TABLE, a key without its file
//!   UNQUALIFIED-KEY, and two rows that normalise to one identity, counted by
//!   row occurrence, DUPLICATE-IDENTITY.
//!
//! A function key is `<file>:<bare symbol>`, an instantiation suffix
//! (`__anon_N`, `__func_N`) stripped; a test block is `<file>:test:<name>`,
//! which matches `std.debug`'s `<file>:test.<name>`, the name compared
//! exactly (§2.7 RQ13). The run compare's own rules (the launch manifest, its
//! seal, the run spec, CHILD-DUMP-IN-RUN) are the Python tool's and are not
//! here: an isolated child's directory has no manifest.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The phase whose rows a seven-column table is read in (the gate's scope
/// order: an earlier scope shadows a later one for one identity; `test` rows
/// apply in every phase).
pub const Scope = enum {
    fork,
    @"1a",
    @"1b",

    fn order(self: Scope) []const []const u8 {
        return switch (self) {
            .fork => &.{ "fork", "all" },
            .@"1a" => &.{ "merged", "fork", "all" },
            .@"1b" => &.{ "merged-1b", "merged", "fork", "all" },
        };
    }
};

/// The scope the test exe's own compares read the table in, and the one
/// place this code names its tree. This is the 1B branch (v1.4.0 merged on
/// 1A's tree), whose `merged-1b` rows apply before 1A's `merged` ones; 1A's
/// tree read `.@"1a"` here and the fork-head control branch `.fork`.
/// Nothing fails if a port forgets, since the isolated children's rows are
/// `test` rows, which apply in every scope (test-harnesses.md, 2026-11-20
/// ISOLATED-CHILD-01).
pub const tree_scope: Scope = .@"1b";

pub const Kind = enum {
    bad_table,
    unqualified_key,
    duplicate_identity,
    bad_dump,
    not_child_dump,
    empty_dump,
    pair_outside_table,
    missing_dump,

    /// The name the prototype prints.
    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .bad_table => "BAD-TABLE",
            .unqualified_key => "UNQUALIFIED-KEY",
            .duplicate_identity => "DUPLICATE-IDENTITY",
            .bad_dump => "BAD-DUMP",
            .not_child_dump => "NOT-CHILD-DUMP",
            .empty_dump => "EMPTY-DUMP",
            .pair_outside_table => "PAIR-OUTSIDE-TABLE",
            .missing_dump => "MISSING-DUMP",
        };
    }
};

pub const Failure = struct {
    kind: Kind,
    /// The whole line, `FAIL <KIND> ...`, as the prototype prints it.
    line: []const u8,
};

/// A symbolised dump, as `symbolise.zig` writes it: `# kind=<k> pid=<p>
/// start=<s>` (more fields may follow), then `<function key> <role>` lines.
pub const Dump = struct {
    /// Its file name.
    name: []const u8,
    text: []const u8,
};

pub const Options = struct {
    /// Strip an instantiation suffix before matching (the prototype's
    /// default; `--no-strip` turns it off).
    strip: bool = true,
};

/// What a compare found.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    failures: std.ArrayListUnmanaged(Failure) = .empty,
    child_dumps: usize = 0,
    distinct_pairs: usize = 0,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    pub fn passed(self: *const Report) bool {
        return self.failures.items.len == 0;
    }

    pub fn count(self: *const Report, kind: Kind) usize {
        var n: usize = 0;
        for (self.failures.items) |f| n += @intFromBool(f.kind == kind);
        return n;
    }

    /// Whether the report holds exactly this line.
    pub fn hasLine(self: *const Report, line: []const u8) bool {
        for (self.failures.items) |f| {
            if (std.mem.eql(u8, f.line, line)) return true;
        }
        return false;
    }

    /// The prototype's output: each FAIL line, its summary line and its
    /// RESULT line.
    pub fn format(self: *const Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.failures.items) |f| try writer.print("{s}\n", .{f.line});
        // The prototype prints its counter as a Python dict, empty at 0.
        try writer.writeAll("run (isolated): 0 launch rows, 0 joined; with pairs ");
        if (self.child_dumps == 0) {
            try writer.writeAll("{}");
        } else {
            try writer.print("{{'child-dumps': {d}}}", .{self.child_dumps});
        }
        try writer.print("; {d} distinct pairs\n", .{self.distinct_pairs});
        if (self.passed()) return writer.writeAll("RESULT PASS (0 failures)\n");
        try writer.print("RESULT FAIL ({d} failures)", .{self.failures.items.len});
        for (std.enums.values(Kind)) |kind| {
            const n = self.count(kind);
            if (n > 0) try writer.print(" {s}={d}", .{ kind.text(), n });
        }
        try writer.writeByte('\n');
    }

    fn fail(self: *Report, kind: Kind, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const a = self.arena.allocator();
        const line = try std.fmt.allocPrint(a, "FAIL {s} " ++ fmt, .{kind.text()} ++ args);
        try self.failures.append(a, .{ .kind = kind, .line = line });
    }
};

/// Compares an isolated child's dumps with `table_text`: the reviewed
/// seven-column table read in `scope`, or with a null scope the two-column
/// form. `dumps` are taken in name order, as the prototype lists a
/// directory.
pub fn isolated(
    alloc: Allocator,
    table_text: []const u8,
    scope: ?Scope,
    dumps: []const Dump,
    options: Options,
) Allocator.Error!Report {
    var report: Report = .{ .arena = .init(alloc) };
    errdefer report.deinit();
    const a = report.arena.allocator();

    const table = try Table.parse(a, table_text, scope, options, &report);

    const sorted = try a.dupe(Dump, dumps);
    std.mem.sort(Dump, sorted, {}, struct {
        fn less(_: void, x: Dump, y: Dump) bool {
            return std.mem.order(u8, x.name, y.name) == .lt;
        }
    }.less);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (sorted) |d| {
        if (!std.mem.endsWith(u8, d.name, ".pairs")) continue;
        var lines = Lines.init(d.text);
        const first = lines.next() orelse {
            try report.fail(.bad_dump, "{s}: no header", .{d.name});
            continue;
        };
        const header = parseHeader(first) orelse {
            try report.fail(.bad_dump, "{s}: no header", .{d.name});
            continue;
        };
        if (!std.mem.eql(u8, header.kind, "child")) {
            try report.fail(.not_child_dump, "{s}: kind {s} in an isolated child's directory (pid {s})", .{
                d.name, header.kind, header.pid,
            });
            continue;
        }
        report.child_dumps += 1;
        if (headerProblem(first)) |problem| {
            try report.fail(.bad_dump, "{s}: the symboliser found a problem ({s}); its pairs are not compared", .{
                d.name, problem,
            });
            continue;
        }
        var pairs: usize = 0;
        var rest = lines;
        while (rest.next()) |_| pairs += 1;
        if (pairs == 0) {
            try report.fail(.empty_dump, "{s}: the isolated child (pid {s}) recorded no pair", .{ d.name, header.pid });
        }
        while (lines.next()) |line| {
            // A test key holds spaces; the role is the last word.
            const space = std.mem.lastIndexOfScalar(u8, line, ' ') orelse {
                try report.fail(.bad_dump, "{s}: a pair line with no role", .{d.name});
                continue;
            };
            const fn_key = line[0..space];
            const role = line[space + 1 ..];
            if (!qualified(fn_key)) {
                try report.fail(.unqualified_key, "{s}: ({s}, {s}) names no .zig file", .{ d.name, fn_key, role });
                continue;
            }
            const pair = try pairKey(a, try key(a, fn_key, options), role);
            try seen.put(a, pair, {});
            if (!table.allowed.contains(pair)) {
                try report.fail(.pair_outside_table, "{s}: ({s}, {s})", .{ d.name, fn_key, role });
            }
        }
    }
    if (report.child_dumps == 0) {
        try report.fail(.missing_dump, "isolated child: no child dump in its directory", .{});
    }
    report.distinct_pairs = seen.count();
    return report;
}

/// The table's allowed (function key, role) pairs.
const Table = struct {
    allowed: std.StringHashMapUnmanaged(void) = .empty,

    const Entry = struct { fn_key: []const u8, roles: []const u8, row: usize };

    fn parse(a: Allocator, text: []const u8, scope: ?Scope, options: Options, report: *Report) Allocator.Error!Table {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        if (scope) |s| {
            try readScoped(a, text, s, &entries, report);
        } else {
            var it = std.mem.splitScalar(u8, text, '\n');
            var row: usize = 0;
            while (it.next()) |raw| {
                row += 1;
                if (std.mem.trim(u8, raw, " \t\r\n").len == 0 or raw[0] == '#') continue;
                var cols: [8][]const u8 = undefined;
                const n = splitTabs(raw, &cols);
                if (n >= 5) {
                    try report.fail(.bad_table, "row {d}: a row of the reviewed seven-column table; read that table " ++
                        "with --table-scope fork|1a|1b", .{row});
                    continue;
                }
                try entries.append(a, .{ .fn_key = cols[0], .roles = if (n > 1) cols[1] else "", .row = row });
            }
        }

        var table: Table = .{};
        // Each identity's rows, in order, for DUPLICATE-IDENTITY.
        var identity: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(usize)) = .empty;
        for (entries.items) |e| {
            if (!qualified(e.fn_key)) {
                try report.fail(.unqualified_key, "table row '{s}': a key names its .zig file", .{e.fn_key});
                continue;
            }
            const k = try key(a, e.fn_key, options);
            const slot = try identity.getOrPut(a, k);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(a, e.row);
            var roles = std.mem.splitScalar(u8, e.roles, '|');
            while (roles.next()) |role| {
                if (role.len > 0) try table.allowed.put(a, try pairKey(a, k, role), {});
            }
        }
        // Sorted by identity, as the prototype prints them.
        const Sort = struct {
            keys: [][]const u8,
            pub fn lessThan(ctx: @This(), x: usize, y: usize) bool {
                return std.mem.order(u8, ctx.keys[x], ctx.keys[y]) == .lt;
            }
        };
        identity.sort(Sort{ .keys = identity.keys() });
        for (identity.keys(), identity.values()) |k, rows| {
            if (rows.items.len < 2) continue;
            var list: std.Io.Writer.Allocating = .init(a);
            list.writer.writeByte('[') catch return error.OutOfMemory;
            for (rows.items, 0..) |row, i| {
                list.writer.print("{s}{d}", .{ if (i == 0) "" else ", ", row }) catch return error.OutOfMemory;
            }
            list.writer.writeByte(']') catch return error.OutOfMemory;
            try report.fail(.duplicate_identity, "{s}: table rows {s} normalise to one identity", .{ k, list.written() });
        }
        return table;
    }

    /// The reviewed table in `scope`: the rows the gate selects, every
    /// `test` row, wildcard rows `*[f1,...]` expanded.
    fn readScoped(a: Allocator, text: []const u8, scope: Scope, entries: *std.ArrayListUnmanaged(Entry), report: *Report) Allocator.Error!void {
        const order = scope.order();
        const Best = struct { rank: usize, rows: std.ArrayListUnmanaged(Entry) };
        var best: std.StringArrayHashMapUnmanaged(Best) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        var row: usize = 0;
        while (it.next()) |raw| {
            row += 1;
            if (std.mem.trim(u8, raw, " \t\r\n").len == 0 or raw[0] == '#') continue;
            var cols: [8][]const u8 = @splat("");
            const n = splitTabs(raw, &cols);
            if (n < 5) {
                try report.fail(.bad_table, "row {d}: not a row of the reviewed seven-column table", .{row});
                continue;
            }
            const file = cols[0];
            const function = cols[1];
            const threads = cols[3];
            const row_scope = cols[4];
            const chain = cols[6];
            const roles = try rolesOf(a, threads);
            var names = std.mem.splitScalar(u8, function, ',');
            const wildcard = std.mem.startsWith(u8, function, "*[") and std.mem.endsWith(u8, function, "]");
            if (wildcard) names = std.mem.splitScalar(u8, function[2 .. function.len - 1], ',');
            if (std.mem.eql(u8, row_scope, "test")) {
                while (nextName(&names, wildcard, function)) |name| {
                    if (!std.mem.eql(u8, name, "(test)")) {
                        try entries.append(a, .{ .fn_key = try join(a, file, name), .roles = roles, .row = row });
                    } else if (std.mem.startsWith(u8, chain, "test:")) {
                        const k = try std.fmt.allocPrint(a, "{s}:test:{s}", .{ file, chain["test:".len..] });
                        try entries.append(a, .{ .fn_key = k, .roles = roles, .row = row });
                    } else {
                        try report.fail(.bad_table, "row {d}: a test row's chain names no test (test:<name>)", .{row});
                    }
                }
                continue;
            }
            const rank = for (order, 0..) |name, i| {
                if (std.mem.eql(u8, name, row_scope)) break i;
            } else continue;
            while (nextName(&names, wildcard, function)) |name| {
                const k = try join(a, file, name);
                const slot = try best.getOrPut(a, k);
                const entry: Entry = .{ .fn_key = k, .roles = roles, .row = row };
                if (!slot.found_existing or rank < slot.value_ptr.rank) {
                    slot.value_ptr.* = .{ .rank = rank, .rows = .empty };
                    try slot.value_ptr.rows.append(a, entry);
                } else if (rank == slot.value_ptr.rank) {
                    try slot.value_ptr.rows.append(a, entry);
                }
            }
        }
        const Sort = struct {
            keys: [][]const u8,
            pub fn lessThan(ctx: @This(), x: usize, y: usize) bool {
                return std.mem.order(u8, ctx.keys[x], ctx.keys[y]) == .lt;
            }
        };
        best.sort(Sort{ .keys = best.keys() });
        for (best.values()) |b| try entries.appendSlice(a, b.rows.items);
    }

    /// The next of a row's function names: the whole field, or a wildcard's
    /// items one by one.
    fn nextName(names: *std.mem.SplitIterator(u8, .scalar), wildcard: bool, function: []const u8) ?[]const u8 {
        if (wildcard) return names.next();
        if (names.index == null) return null;
        names.index = null;
        return function;
    }

    /// A row's roles: its threads without `never-on-win32`.
    fn rolesOf(a: Allocator, threads: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        var it = std.mem.splitScalar(u8, threads, '|');
        while (it.next()) |role| {
            if (role.len == 0 or std.mem.eql(u8, role, "never-on-win32")) continue;
            if (out.items.len > 0) try out.append(a, '|');
            try out.appendSlice(a, role);
        }
        return out.items;
    }
};

/// Splits a table row on tabs into `cols`; the column count (at most
/// `cols.len`, the rest of the row kept in the last).
fn splitTabs(raw: []const u8, cols: [][]const u8) usize {
    const row = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
    var it = std.mem.splitScalar(u8, row, '\t');
    var n: usize = 0;
    while (it.next()) |col| {
        if (n == cols.len) break;
        cols[n] = col;
        n += 1;
    }
    return n;
}

fn join(a: Allocator, file: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{s}", .{ file, name });
}

fn pairKey(a: Allocator, fn_key: []const u8, role: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ fn_key, role });
}

/// `<file>.zig:test.<name>` or `<file>.zig:test:<name>`: the file ends at
/// the first `.zig` that such a marker follows (the prototype's lazy match).
fn testKey(k: []const u8) ?struct { file: []const u8, name: []const u8 } {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, k, from, ".zig:test")) |i| {
        const after = i + ".zig:test".len;
        if (after < k.len and (k[after] == '.' or k[after] == ':')) {
            return .{ .file = k[0 .. i + ".zig".len], .name = k[after + 1 ..] };
        }
        from = i + 1;
    }
    return null;
}

/// Whether a key names its file: a test key, or `<file>.zig:<name>` whose
/// name holds no colon.
pub fn qualified(k: []const u8) bool {
    if (testKey(k) != null) return true;
    const colon = std.mem.lastIndexOfScalar(u8, k, ':') orelse return false;
    return colon + 1 < k.len and std.mem.endsWith(u8, k[0..colon], ".zig");
}

/// A key as the table and the dumps are matched: a test as
/// `<file>:test:<name>`, a function with its instantiation suffix stripped.
pub fn key(a: Allocator, k: []const u8, options: Options) Allocator.Error![]const u8 {
    if (testKey(k)) |t| return std.fmt.allocPrint(a, "{s}:test:{s}", .{ t.file, t.name });
    return if (options.strip) stripInstantiation(k) else k;
}

/// `name__anon_N` or `name__func_N` (N decimal, at the end) as `name`.
pub fn stripInstantiation(k: []const u8) []const u8 {
    var end = k.len;
    while (end > 0 and std.ascii.isDigit(k[end - 1])) end -= 1;
    if (end == k.len) return k;
    inline for (.{ "__anon_", "__func_" }) |suffix| {
        if (std.mem.endsWith(u8, k[0..end], suffix)) return k[0 .. end - suffix.len];
    }
    return k;
}

/// The header's first three fields, which is all the compare reads.
const Header = struct { kind: []const u8, pid: []const u8, start: []const u8 };

fn parseHeader(line: []const u8) ?Header {
    var rest = line;
    const kind = headerField(&rest, "# kind=") orelse return null;
    const pid = headerField(&rest, " pid=") orelse return null;
    const start = headerField(&rest, " start=") orelse return null;
    return .{ .kind = kind, .pid = pid, .start = start };
}

/// The value of a header's `problem=` field, which the symboliser writes
/// when it could not name a dump's pairs.
fn headerProblem(line: []const u8) ?[]const u8 {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    while (fields.next()) |f| {
        if (std.mem.startsWith(u8, f, "problem=")) return f["problem=".len..];
    }
    return null;
}

/// `prefix` then one or more non-space bytes.
fn headerField(rest: *[]const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rest.*, prefix)) return null;
    const value = rest.*[prefix.len..];
    var n: usize = 0;
    while (n < value.len and !std.ascii.isWhitespace(value[n])) n += 1;
    if (n == 0) return null;
    rest.* = value[n..];
    return value[0..n];
}

/// A dump's lines without the blank ones, as the prototype reads them.
const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    fn init(text: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, text, '\n') };
    }

    fn next(self: *Lines) ?[]const u8 {
        while (self.it.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r\n\x0b\x0c").len > 0) return line;
        }
        return null;
    }
};

const testing = std.testing;

/// The prototype's fixture table (`tools\controls.py` `CMP_TABLE`).
const cmp_table =
    "src/renderer/generic.zig:updateFrame\trenderer|ui\n" ++
    "src/Surface.zig:keyCallback\tui\n" ++
    "src/Surface.zig:confirmQuitAnswer\tui\n" ++
    "src/termio/mailbox.zig:send\tui|reader\n" ++
    "src/renderer/Thread.zig:step\trenderer\n" ++
    "src/terminal/search/query_search.zig:step\tsearch\n" ++
    "src/termio/stream_handler.zig:test:a stopped reader gives up waiting on a full mailbox and sends nothing " ++
    "after\treader\n";
/// Test 4's deliberate wrong-role pair, recorded by a child (`CHILD`).
const child_dump = "# kind=child pid=900 start=134070000000000900\n" ++
    "src/Surface.zig:keyCallback termio\n";
/// Test 12's two in-table sites, then its panic (`CHILD12`).
const child12_dump = "# kind=child pid=901 start=134070000000000901\n" ++
    "src/Surface.zig:keyCallback ui\n" ++
    "src/termio/mailbox.zig:send reader\n";
const gui_dump = "# kind=gui pid=700 start=134070000000000700\nsrc/Surface.zig:keyCallback ui\n";

fn expectReport(dumps: []const Dump, table: []const u8, scope: ?Scope, expected: []const struct { Kind, usize }) !Report {
    var report = try isolated(testing.allocator, table, scope, dumps, .{});
    errdefer report.deinit();
    var total: usize = 0;
    for (expected) |e| {
        try testing.expectEqual(e[1], report.count(e[0]));
        total += e[1];
    }
    try testing.expectEqual(total, report.failures.items.len);
    return report;
}

test "control 59: an off-table child fails one PAIR-OUTSIDE-TABLE naming the pair" {
    var report = try expectReport(&.{.{ .name = "child-900.pairs", .text = child_dump }}, cmp_table, null, &.{
        .{ .pair_outside_table, 1 },
    });
    defer report.deinit();
    try testing.expect(report.hasLine("FAIL PAIR-OUTSIDE-TABLE child-900.pairs: (src/Surface.zig:keyCallback, termio)"));
    try testing.expect(!report.passed());
}

test "control 60: a panic variant's child whose pairs are in the table passes" {
    var report = try expectReport(&.{.{ .name = "child-901.pairs", .text = child12_dump }}, cmp_table, null, &.{});
    defer report.deinit();
    try testing.expect(report.passed());
    try testing.expectEqual(@as(usize, 1), report.child_dumps);
    try testing.expectEqual(@as(usize, 2), report.distinct_pairs);
}

test "control 61: a directory that holds a dump of another kind fails NOT-CHILD-DUMP" {
    var report = try expectReport(&.{
        .{ .name = "child-901.pairs", .text = child12_dump },
        .{ .name = "gui-700.pairs", .text = gui_dump },
    }, cmp_table, null, &.{.{ .not_child_dump, 1 }});
    defer report.deinit();
    try testing.expect(report.hasLine("FAIL NOT-CHILD-DUMP gui-700.pairs: kind gui in an isolated child's directory (pid 700)"));
}

test "control 62: a child that left no dump fails MISSING-DUMP" {
    var report = try expectReport(&.{}, cmp_table, null, &.{.{ .missing_dump, 1 }});
    defer report.deinit();
    try testing.expect(report.hasLine("FAIL MISSING-DUMP isolated child: no child dump in its directory"));
    // A file that is not a dump is not read.
    var other = try expectReport(&.{.{ .name = "child-900.txt", .text = child_dump }}, cmp_table, null, &.{.{ .missing_dump, 1 }});
    defer other.deinit();
}

test "control 70: a child dump with no pair fails EMPTY-DUMP" {
    var report = try expectReport(&.{
        .{ .name = "child-902.pairs", .text = "# kind=child pid=902 start=134070000000000902\n" },
    }, cmp_table, null, &.{.{ .empty_dump, 1 }});
    defer report.deinit();
    try testing.expect(report.hasLine("FAIL EMPTY-DUMP child-902.pairs: the isolated child (pid 902) recorded no pair"));
}

test "a dump the symboliser found a problem in fails BAD-DUMP, its pairs not compared" {
    // A child's writer failed after one pair the table holds: the
    // symbolised dump keeps that pair, and must not pass.
    const failed = "# kind=child pid=903 start=134070000000000903 format=sym-1 exe=ghostty-test.exe " ++
        "pdb_guid=none pdb_age=0 problem=append_failed\n" ++
        "?append_failed:pairs-lost none\n" ++
        "?append_failed:0x00007ff600001000 ui\n";
    var report = try expectReport(&.{.{ .name = "child-903.pairs", .text = failed }}, cmp_table, null, &.{
        .{ .bad_dump, 1 },
    });
    defer report.deinit();
    try testing.expect(report.hasLine("FAIL BAD-DUMP child-903.pairs: the symboliser found a problem " ++
        "(append_failed); its pairs are not compared"));
    try testing.expectEqual(@as(usize, 1), report.child_dumps);
    // The same dump's pairs, had they been named and the header kept its
    // problem: still BAD-DUMP, whatever its pairs.
    const named = "# kind=child pid=901 start=134070000000000901 problem=pdb_mismatch\n" ++
        "src/Surface.zig:keyCallback ui\n";
    var other = try expectReport(&.{.{ .name = "child-901.pairs", .text = named }}, cmp_table, null, &.{
        .{ .bad_dump, 1 },
    });
    defer other.deinit();
    // A problem field anywhere in the header, not in a pair.
    try testing.expectEqualStrings("append_failed", headerProblem("# kind=child pid=1 start=2 problem=append_failed").?);
    try testing.expectEqual(@as(?[]const u8, null), headerProblem("# kind=child pid=1 start=2 format=sym-1"));
}

test "the pair rules: suffix stripping, test keys, another file's same name, a key without its file, no header" {
    // Control 46's shape in a child: a comptime instantiation matches only
    // with its suffix stripped.
    const suffixed = "# kind=child pid=1 start=2\nsrc/Surface.zig:confirmQuitAnswer__anon_30924 ui\n" ++
        "src/Surface.zig:confirmQuitAnswer__func_721 ui\n";
    var stripped = try expectReport(&.{.{ .name = "c.pairs", .text = suffixed }}, cmp_table, null, &.{});
    defer stripped.deinit();
    try testing.expectEqual(@as(usize, 1), stripped.distinct_pairs);
    var raw = try isolated(testing.allocator, cmp_table, null, &.{.{ .name = "c.pairs", .text = suffixed }}, .{ .strip = false });
    defer raw.deinit();
    try testing.expectEqual(@as(usize, 2), raw.count(.pair_outside_table));

    // Control 53's shape: another file's function of the same bare name.
    var collide = try expectReport(&.{.{
        .name = "c.pairs",
        .text = "# kind=child pid=1 start=2\nsrc/terminal/search/query_search.zig:step renderer\n",
    }}, cmp_table, null, &.{.{ .pair_outside_table, 1 }});
    defer collide.deinit();

    // Control 55's shape: std.debug's `test.<name>` matches its own file's
    // test key, exactly; another test name or another file's does not.
    const tests = "# kind=child pid=1 start=2\n" ++
        "src/termio/stream_handler.zig:test.a stopped reader gives up waiting on a full mailbox and sends nothing after reader\n" ++
        "src/termio/stream_handler.zig:test:a stopped reader gives up waiting on a full mailbox and sends nothing after reader\n" ++
        "src/termio/stream_handler.zig:test.a stopped reader gives up waiting on a full mailbox and sends nothing after  reader\n" ++
        "src/termio/mailbox.zig:test.a stopped reader gives up waiting on a full mailbox and sends nothing after reader\n";
    var keyed = try expectReport(&.{.{ .name = "c.pairs", .text = tests }}, cmp_table, null, &.{.{ .pair_outside_table, 2 }});
    defer keyed.deinit();
    try testing.expectEqual(@as(usize, 3), keyed.distinct_pairs);

    // A key without its file; a pair line without a role; no header.
    var bad = try expectReport(&.{
        .{ .name = "a.pairs", .text = "# kind=child pid=1 start=2\nkeyCallback ui\nsrc/Surface.zig:keyCallback\n" },
        .{ .name = "b.pairs", .text = "src/termio/mailbox.zig:send reader\n" },
        .{ .name = "c.pairs", .text = "" },
    }, cmp_table, null, &.{ .{ .unqualified_key, 1 }, .{ .bad_dump, 3 } });
    defer bad.deinit();
    try testing.expect(bad.hasLine("FAIL UNQUALIFIED-KEY a.pairs: (keyCallback, ui) names no .zig file"));
    try testing.expect(bad.hasLine("FAIL BAD-DUMP b.pairs: no header"));
}

test "a two-column table: BAD-TABLE for a seven-column row, UNQUALIFIED-KEY, DUPLICATE-IDENTITY by occurrence" {
    const table = "src/a.zig:f\tui\n" ++
        "# a comment\n\n" ++
        "src/a.zig:f\tui\n" ++
        "g\tui\n" ++
        "src/b.zig:h__anon_12\tui\n" ++
        "src/b.zig:h\ttermio\n" ++
        "src/c.zig\tf\tx\tui\tfork\treason\tchain\n";
    var report = try expectReport(&.{.{ .name = "c.pairs", .text = child12_dump }}, table, null, &.{
        .{ .bad_table, 1 },          .{ .unqualified_key, 1 },
        .{ .duplicate_identity, 2 }, .{ .pair_outside_table, 2 },
    });
    defer report.deinit();
    try testing.expect(report.hasLine("FAIL DUPLICATE-IDENTITY src/a.zig:f: table rows [1, 4] normalise to one identity"));
    try testing.expect(report.hasLine("FAIL DUPLICATE-IDENTITY src/b.zig:h: table rows [6, 7] normalise to one identity"));
    try testing.expect(report.hasLine("FAIL UNQUALIFIED-KEY table row 'g': a key names its .zig file"));
    try testing.expect(report.hasLine("FAIL BAD-TABLE row 8: a row of the reviewed seven-column table; read that " ++
        "table with --table-scope fork|1a|1b"));
}

test "the seven-column table in a scope: scope order, test rows, wildcards, never-on-win32" {
    const table = "# file\tfunction\tfingerprint\tthreads\tscope\treason\tchain\n" ++
        "src/termio/mailbox.zig\tsend\tfp\tui|reader\tfork\tr\tc\n" ++
        "src/termio/mailbox.zig\tsend\tfp\tui\tmerged\tr\tc\n" ++
        "src/Surface.zig\t*[keyCallback,mouseButtonCallback]\tfp\tui\tall\tr\tc\n" ++
        "src/renderer/Thread.zig\trendererOnly\tfp\tnever-on-win32\tfork\tr\tc\n" ++
        "src/apprt/win32.zig\t(test)\t@renderer-state.lock:1\tui\ttest\tr\ttest:win32 a Restart Manager query\n" ++
        "src/sync/isolated.zig\tisolatedFirstSite\t@renderer-state.lock:1\tui\ttest\tr\ttest:x\n" ++
        "src/x.zig\t(test)\tfp\tui\ttest\tr\tno chain\n" ++
        "src/y.zig\tshort\n";
    const dump_text = "# kind=child pid=1 start=2\n" ++
        "src/termio/mailbox.zig:send reader\n" ++
        "src/Surface.zig:mouseButtonCallback ui\n" ++
        "src/apprt/win32.zig:test.win32 a Restart Manager query ui\n" ++
        "src/sync/isolated.zig:isolatedFirstSite ui\n" ++
        "src/renderer/Thread.zig:rendererOnly renderer\n";
    // Fork: `send` keeps its fork row; `rendererOnly` has no role.
    var fork = try expectReport(&.{.{ .name = "c.pairs", .text = dump_text }}, table, .fork, &.{
        .{ .bad_table, 2 }, .{ .pair_outside_table, 1 },
    });
    defer fork.deinit();
    try testing.expect(fork.hasLine("FAIL BAD-TABLE row 8: a test row's chain names no test (test:<name>)"));
    try testing.expect(fork.hasLine("FAIL BAD-TABLE row 9: not a row of the reviewed seven-column table"));
    try testing.expect(fork.hasLine("FAIL PAIR-OUTSIDE-TABLE c.pairs: (src/renderer/Thread.zig:rendererOnly, renderer)"));
    // 1A: the merged row shadows the fork row, so `send` is `ui` only.
    var merged = try expectReport(&.{.{ .name = "c.pairs", .text = dump_text }}, table, .@"1a", &.{
        .{ .bad_table, 2 }, .{ .pair_outside_table, 2 },
    });
    defer merged.deinit();
    try testing.expect(merged.hasLine("FAIL PAIR-OUTSIDE-TABLE c.pairs: (src/termio/mailbox.zig:send, reader)"));
    // A seven-column table read with no scope fails BAD-TABLE.
    var unscoped = try isolated(testing.allocator, table, null, &.{.{ .name = "c.pairs", .text = dump_text }}, .{});
    defer unscoped.deinit();
    try testing.expectEqual(@as(usize, 7), unscoped.count(.bad_table));
}

test "the report prints the prototype's lines" {
    var report = try expectReport(&.{.{ .name = "child-900.pairs", .text = child_dump }}, cmp_table, null, &.{
        .{ .pair_outside_table, 1 },
    });
    defer report.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report.format(&out.writer);
    try testing.expectEqualStrings(
        "FAIL PAIR-OUTSIDE-TABLE child-900.pairs: (src/Surface.zig:keyCallback, termio)\n" ++
            "run (isolated): 0 launch rows, 0 joined; with pairs {'child-dumps': 1}; 1 distinct pairs\n" ++
            "RESULT FAIL (1 failures) PAIR-OUTSIDE-TABLE=1\n",
        out.written(),
    );
}

test "qualified keys and suffix stripping" {
    try testing.expect(qualified("src/a.zig:f"));
    try testing.expect(qualified("src/a.zig:test.a b: c"));
    try testing.expect(qualified("src/a.zig:test:a b"));
    try testing.expect(!qualified("src/a.zig:"));
    try testing.expect(!qualified("src/a.zig:f:g"));
    try testing.expect(!qualified("f"));
    try testing.expect(!qualified("src/a.zag:f"));
    try testing.expectEqualStrings("f", stripInstantiation("f__anon_123"));
    try testing.expectEqualStrings("f", stripInstantiation("f__func_9"));
    try testing.expectEqualStrings("f__anon_", stripInstantiation("f__anon_"));
    try testing.expectEqualStrings("f__other_1", stripInstantiation("f__other_1"));
    try testing.expectEqualStrings("f1", stripInstantiation("f1"));
}
