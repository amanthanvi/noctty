//! The value type of the `profile-*` config keys: one entry per user profile
//! id, kept in the order the id first appeared.
//!
//! Every value is `<id>: <text>`. The id ends at the first `:` and the text
//! after it is kept exactly as written, with only the surrounding whitespace
//! trimmed: nothing is unquoted or unescaped, so a Windows command line can be
//! pasted from Windows Terminal or a shortcut as it is. (A label, which is not
//! a command line, loses one surrounding pair of `"`.) `<id>:` with nothing
//! after it removes that id. Ids compare ASCII case-insensitively, and the
//! first spelling seen is the one kept.
//!
//! `profile-command` removes a profile whole: `<id>:` leaves a tombstone in the
//! id's slot, so the profile's other lines go dormant (also ones a later file
//! adds) and a later definition brings it back in the same place; an empty
//! value (`profile-command =`) tombstones every profile defined so far.
//!
//! Every check that needs only the line runs here, so the loader reports it
//! with its file and line. Whether a field's id has a `profile-command` is
//! checked by `Config.finalize`, since a file may set a field before the line
//! that defines the profile, or in another file.
const std = @import("std");
const Allocator = std.mem.Allocator;

const RepeatableStringMap = @import("RepeatableStringMap.zig");
const formatterpkg = @import("formatter.zig");

/// The longest id a profile can have.
pub const max_id_len = 64;

/// The ids a user profile may not take, compared without case. A user
/// profile's key is `user:<id>`, but a reference to a profile may be a bare
/// word, which must name one thing.
pub const reserved_ids = [_][]const u8{
    // The keys of the detected profiles.
    "pwsh.exe",
    "powershell.exe",
    "cmd.exe",
    "git-bash",
    "wsl-default",
    // The prefixes of the other keys (`user:<id>`, `wsl:<distribution>`,
    // `ssh:<alias>`, `vs:...`), so a key written where an id goes is
    // reported instead of becoming the id `wsl` or `user`.
    "user",
    "wsl",
    "ssh",
    "vs",
    // The fixed words that name a detected profile
    // (`windows_shell.profile_alias_words`; a test there checks that every
    // one of them is reserved here).
    "pwsh",
    "powershell",
    "powershell-7",
    "powershell-core",
    "windows-powershell",
    "ps",
    "git",
    "gitbash",
    "cmd",
    "command-prompt",
    "default-wsl",
    "wsl-distro",
    "distro",
};

/// 1 to 64 characters of `[A-Za-z0-9._-]`.
pub fn isValidId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    for (id) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

pub fn isReservedId(id: []const u8) bool {
    for (reserved_ids) |reserved| {
        if (std.ascii.eqlIgnoreCase(id, reserved)) return true;
    }
    return false;
}

pub const Kind = enum {
    /// `profile-command`: the command line per id, with tombstones.
    command,
    /// `profile-name`: the label per id, one surrounding pair of `"` removed.
    name,
    /// `profile-working-directory`: one string per id, as written.
    text,
    /// `env` entries per id (`profile-env`): `<id>: KEY=VALUE` sets one,
    /// `<id>: KEY=` removes one, `<id>:` removes all of that id's entries.
    /// Names compare ASCII case-insensitively, as Windows compares them.
    env,
};

pub const Command = ProfileMap(.command);
pub const Name = ProfileMap(.name);
pub const Text = ProfileMap(.text);
pub const Env = ProfileMap(.env);

/// Why a `profile-*` value was refused. `src/cli/args.zig` turns each into a
/// message that names at most the id (only once it is a valid one) or a
/// single drive letter, never the rest of the value: a line written without
/// an id starts with its command line, which may hold a token.
pub const Error = error{
    /// No `:` at all.
    MissingProfileId,
    /// The text before the first `:` is not 1 to 64 of `[A-Za-z0-9._-]`.
    InvalidProfileId,
    /// A one-letter id followed by `\` or `/`: a path written without an id
    /// (`C:\Tools\x.exe`).
    ProfileIdLooksLikeDrive,
    /// One of `reserved_ids`.
    ReservedProfileId,
    /// `profile-command` text that starts with `direct:` or `shell:`.
    ProfileCommandPrefix,
    /// `profile-command` text whose first argument is empty (`""`).
    ProfileNoProgram,
    /// `profile-env` text without `=`.
    ValueRequired,
};

/// A value that passed the checks: its id and its text, both trimmed.
/// `text` is empty for `<id>:`.
pub const Parsed = struct {
    id: []const u8,
    text: []const u8,
};

/// Run the checks that need only the line on a non-empty `profile-*` value.
pub fn check(comptime kind: Kind, value: []const u8) Error!Parsed {
    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.MissingProfileId;
    const id = std.mem.trim(u8, value[0..colon], &std.ascii.whitespace);
    const text = std.mem.trim(u8, value[colon + 1 ..], &std.ascii.whitespace);
    if (!isValidId(id)) return error.InvalidProfileId;
    if (id.len == 1 and std.ascii.isAlphabetic(id[0]) and text.len > 0 and (text[0] == '\\' or text[0] == '/'))
        return error.ProfileIdLooksLikeDrive;
    if (isReservedId(id)) return error.ReservedProfileId;
    if (text.len > 0) switch (kind) {
        .command => {
            if (std.ascii.startsWithIgnoreCase(text, "direct:") or std.ascii.startsWithIgnoreCase(text, "shell:"))
                return error.ProfileCommandPrefix;
            if (firstArgumentIsEmpty(text)) return error.ProfileNoProgram;
        },
        .env => if (std.mem.indexOfScalar(u8, text, '=') == null) return error.ValueRequired,
        .name, .text => {},
    };
    return .{ .id = id, .text = text };
}

/// Whether the program name of a Windows command line is empty, as
/// `CommandLineToArgvW` reads it: the first argument ends at a space or tab
/// outside quotes, takes no backslash escapes, and loses its quotes, so
/// `""` and `"" x` name no program. `line` is already trimmed.
fn firstArgumentIsEmpty(line: []const u8) bool {
    var quoted = false;
    for (line) |byte| switch (byte) {
        '"' => quoted = !quoted,
        ' ', '\t' => if (!quoted) return true else return false,
        else => return false,
    };
    return true;
}

/// One pair of `"` around the whole of `text` removed, as the loader does
/// for other values.
fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

/// Whether a label would change if written as it is and loaded again: one
/// that starts or ends with `"` or whitespace.
fn nameNeedsQuotes(text: []const u8) bool {
    if (text.len == 0) return false;
    for ([_]u8{ text[0], text[text.len - 1] }) |byte| {
        if (byte == '"' or std.ascii.isWhitespace(byte)) return true;
    }
    return false;
}

/// Remove every variable of `map` whose name equals `name` in any case.
fn removeEnvName(map: *RepeatableStringMap, name: []const u8) void {
    var index: usize = 0;
    while (index < map.map.count()) {
        if (std.ascii.eqlIgnoreCase(map.map.keys()[index], name)) {
            map.map.orderedRemoveAt(index);
        } else index += 1;
    }
}

pub fn ProfileMap(comptime kind: Kind) type {
    return struct {
        const Self = @This();

        pub const Value = switch (kind) {
            .command, .name, .text => [:0]const u8,
            .env => RepeatableStringMap,
        };

        pub const Entry = struct {
            id: [:0]const u8,
            value: Value,
            /// `.command` only: `<id>:` removed the profile. The entry keeps
            /// its slot (and the last command it had, which nothing reads),
            /// so a later definition comes back in the same place.
            removed: bool = false,
        };

        /// Allocated in the parent config's arena, like every config value.
        entries: std.ArrayListUnmanaged(Entry) = .empty,

        /// An empty value (`key =`): the loader calls this instead of
        /// resetting the field to its default. For `profile-command` every
        /// profile defined so far is removed whole, as `<id>:` removes one,
        /// so a field a later file sets for one of them stays dormant. The
        /// other keys are cleared, as a reset would.
        pub fn init(self: *Self, alloc: Allocator) Allocator.Error!void {
            _ = alloc;
            switch (kind) {
                .command => for (self.entries.items) |*entry| {
                    entry.removed = true;
                },
                .name, .text, .env => self.entries.clearRetainingCapacity(),
            }
        }

        pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) (Error || Allocator.Error)!void {
            const raw = input orelse return error.ValueRequired;
            const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (value.len == 0) return try self.init(alloc);
            const parsed = try check(kind, value);
            const id = parsed.id;
            const text = if (kind == .name) unquote(parsed.text) else parsed.text;

            if (text.len == 0) {
                const index = self.indexOf(id) orelse {
                    // A removal of a profile not defined yet: a later file
                    // may define it, and must not bring it back.
                    if (kind == .command) try self.entries.append(alloc, .{
                        .id = try alloc.dupeZ(u8, id),
                        .value = "",
                        .removed = true,
                    });
                    return;
                };
                if (kind == .command) {
                    self.entries.items[index].removed = true;
                } else {
                    _ = self.entries.orderedRemove(index);
                }
                return;
            }

            switch (kind) {
                .command, .name, .text => {
                    const copy = try alloc.dupeZ(u8, text);
                    if (self.indexOf(id)) |index| {
                        self.entries.items[index].value = copy;
                        self.entries.items[index].removed = false;
                        return;
                    }
                    try self.entries.append(alloc, .{ .id = try alloc.dupeZ(u8, id), .value = copy });
                },
                .env => {
                    const eq = std.mem.indexOfScalar(u8, text, '=').?;
                    const name = std.mem.trim(u8, text[0..eq], &std.ascii.whitespace);
                    // An id whose last variable was removed (`<id>: KEY=`)
                    // goes, as `<id>:` would: an empty entry formats to no
                    // line, so it could not round-trip and `equal` would
                    // tell two identical configs apart.
                    if (self.indexOf(id)) |index| {
                        const map = &self.entries.items[index].value;
                        removeEnvName(map, name);
                        try map.parseCLI(alloc, text);
                        if (map.count() == 0) _ = self.entries.orderedRemove(index);
                        return;
                    }
                    var map: RepeatableStringMap = .{};
                    try map.parseCLI(alloc, text);
                    if (map.count() == 0) return;
                    try self.entries.append(alloc, .{ .id = try alloc.dupeZ(u8, id), .value = map });
                },
            }
        }

        /// The slot of `id`, also when `profile-command` removed it.
        pub fn indexOf(self: Self, id: []const u8) ?usize {
            for (self.entries.items, 0..) |entry, index| {
                if (std.ascii.eqlIgnoreCase(entry.id, id)) return index;
            }
            return null;
        }

        /// The value of `id`, or null when it has none or was removed.
        pub fn get(self: Self, id: []const u8) ?Value {
            const index = self.indexOf(id) orelse return null;
            const entry = self.entries.items[index];
            if (entry.removed) return null;
            return entry.value;
        }

        /// Whether a line named `id`, defining or removing it.
        pub fn contains(self: Self, id: []const u8) bool {
            return self.indexOf(id) != null;
        }

        /// The number of ids, removed ones included.
        pub fn count(self: Self) usize {
            return self.entries.items.len;
        }

        pub fn remove(self: *Self, id: []const u8) void {
            if (self.indexOf(id)) |index| _ = self.entries.orderedRemove(index);
        }

        /// Deep copy of the struct. Required by Config.
        pub fn clone(self: *const Self, alloc: Allocator) Allocator.Error!Self {
            var out: Self = .{};
            try out.entries.ensureTotalCapacity(alloc, self.entries.items.len);
            for (self.entries.items) |entry| {
                out.entries.appendAssumeCapacity(.{
                    .id = try alloc.dupeZ(u8, entry.id),
                    .value = switch (kind) {
                        .command, .name, .text => try alloc.dupeZ(u8, entry.value),
                        .env => try entry.value.clone(alloc),
                    },
                    .removed = entry.removed,
                });
            }
            return out;
        }

        /// Compare if two of our value are equal. Required by Config. Order
        /// counts: it is the order the picker lists the profiles in. A
        /// removed profile equals another removed one whatever command it
        /// had, since `+show-config` writes neither.
        pub fn equal(self: Self, other: Self) bool {
            if (self.entries.items.len != other.entries.items.len) return false;
            for (self.entries.items, other.entries.items) |a, b| {
                if (!std.mem.eql(u8, a.id, b.id)) return false;
                if (a.removed != b.removed) return false;
                switch (kind) {
                    .command, .name, .text => if (!a.removed and !std.mem.eql(u8, a.value, b.value)) return false,
                    .env => {
                        if (a.value.count() != b.value.count()) return false;
                        var ait = a.value.iterator();
                        var bit = b.value.iterator();
                        while (ait.next()) |ae| {
                            const be = bit.next().?;
                            if (!std.mem.eql(u8, ae.key_ptr.*, be.key_ptr.*)) return false;
                            if (!std.mem.eql(u8, ae.value_ptr.*, be.value_ptr.*)) return false;
                        }
                    },
                }
            }
            return true;
        }

        /// Used by formatter. Writes the line directly, so a value of any
        /// length the config reader accepts round-trips. A removed profile
        /// is written as its removal, `<id>:`.
        pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
            if (self.entries.items.len == 0) {
                try formatter.formatEntry(void, {});
                return;
            }
            for (self.entries.items) |entry| switch (kind) {
                .command, .name, .text => if (entry.removed)
                    try formatter.writer.print("{s} = {s}:\n", .{ formatter.name, entry.id })
                else if (kind == .name and nameNeedsQuotes(entry.value))
                    // Loading removes one surrounding pair of quotes and
                    // the outer whitespace, so give it a pair to remove.
                    try formatter.writer.print("{s} = {s}: \"{s}\"\n", .{ formatter.name, entry.id, entry.value })
                else
                    try formatter.writer.print("{s} = {s}: {s}\n", .{ formatter.name, entry.id, entry.value }),
                .env => {
                    var it = entry.value.iterator();
                    while (it.next()) |kv| {
                        try formatter.writer.print("{s} = {s}: {s}={s}\n", .{
                            formatter.name,
                            entry.id,
                            kv.key_ptr.*,
                            kv.value_ptr.*,
                        });
                    }
                },
            };
        }
    };
}

test "profile map: text values are kept byte for byte and keep first-seen order" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map: Text = .{};
    try map.parseCLI(alloc, "b: cmd.exe /k \"C:\\a b\\x.cmd\" \"y&z\" %PATH% \\");
    try map.parseCLI(alloc, "A: one");
    try map.parseCLI(alloc, "B: two:with:colons");
    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expectEqualStrings("b", map.entries.items[0].id);
    try testing.expectEqualStrings("two:with:colons", map.get("b").?);
    try testing.expectEqualStrings("one", map.get("a").?);

    try map.parseCLI(alloc, "B:");
    try testing.expectEqual(@as(usize, 1), map.count());
    try testing.expect(map.get("b") == null);

    try testing.expectError(error.MissingProfileId, map.parseCLI(alloc, "no colon here"));
    try map.parseCLI(alloc, "");
    try testing.expectEqual(@as(usize, 0), map.count());
}

test "profile map: env values follow env semantics per id" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map: Env = .{};
    try map.parseCLI(alloc, "py: PATH=C:\\Python312;%PATH%");
    try map.parseCLI(alloc, "py: A=1");
    try map.parseCLI(alloc, "other: B=2");
    try map.parseCLI(alloc, "PY: A=");
    const py = map.get("py").?;
    try testing.expectEqual(@as(usize, 1), py.count());
    try testing.expectEqualStrings("C:\\Python312;%PATH%", py.map.get("PATH").?);
    try testing.expectError(error.ValueRequired, map.parseCLI(alloc, "py: NOEQUALS"));
    try map.parseCLI(alloc, "py:");
    try testing.expect(map.get("py") == null);
    try testing.expectEqual(@as(usize, 1), map.count());

    // Removing an id's last variable removes the id, so the map equals one
    // that never had it, and formats to the same (no) lines.
    try map.parseCLI(alloc, "other: B=");
    try testing.expectEqual(@as(usize, 0), map.count());
    try map.parseCLI(alloc, "new: GONE=");
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expect(map.equal(.{}));
}

test "profile map: env names compare without case within a profile" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The latest spelling and value win, as Windows would see them.
    var map: Env = .{};
    try map.parseCLI(alloc, "py: Path=first");
    try map.parseCLI(alloc, "py: PATH=second");
    try map.parseCLI(alloc, "py: Path=third");
    const py = map.get("py").?;
    try testing.expectEqual(@as(usize, 1), py.count());
    try testing.expectEqualStrings("third", py.map.get("Path").?);
    try testing.expect(py.map.get("PATH") == null);

    // `KEY=` takes the variable back whatever case either line used.
    var removed: Env = .{};
    try removed.parseCLI(alloc, "py: Path=first");
    try removed.parseCLI(alloc, "py: PATH=");
    try testing.expect(removed.get("py") == null);
}

test "profile map: a removed command keeps its slot until it is defined again" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map: Command = .{};
    try map.parseCLI(alloc, "a: a.exe");
    try map.parseCLI(alloc, "b: b.exe");
    try map.parseCLI(alloc, "A:");
    try testing.expect(map.get("a") == null);
    try testing.expect(map.contains("a"));
    try testing.expectEqual(@as(usize, 2), map.count());

    // A removal of an id nobody defined yet is kept too.
    try map.parseCLI(alloc, "later:");
    try testing.expect(map.contains("later") and map.get("later") == null);

    // Defining it again brings it back in its first place.
    try map.parseCLI(alloc, "a: again.exe");
    try testing.expectEqualStrings("a", map.entries.items[0].id);
    try testing.expectEqualStrings("again.exe", map.get("a").?);

    // An empty value removes every profile defined so far; later ones live.
    try map.init(alloc);
    try map.parseCLI(alloc, "c: c.exe");
    try testing.expect(map.get("a") == null and map.get("b") == null);
    try testing.expectEqualStrings("c.exe", map.get("c").?);

    // A removed entry equals a removed one whatever command it last had.
    var other: Command = .{};
    try other.parseCLI(alloc, "a: x.exe");
    try other.parseCLI(alloc, "b: y.exe");
    try other.parseCLI(alloc, "later:");
    try other.init(alloc);
    try other.parseCLI(alloc, "c: c.exe");
    try testing.expect(map.equal(other));
    const copy = try map.clone(alloc);
    try testing.expect(copy.equal(map));
    try testing.expect(copy.contains("later") and copy.get("later") == null);
    var live: Command = try map.clone(alloc);
    try live.parseCLI(alloc, "later: l.exe");
    try testing.expect(!live.equal(map));
}

test "profile map: a label loses one surrounding pair of quotes" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var map: Name = .{};
    try map.parseCLI(alloc, "x: \"Build Box\"");
    try map.parseCLI(alloc, "y: a \"b\" c");
    try map.parseCLI(alloc, "z: \"\"Quoted\"\"");
    try testing.expectEqualStrings("Build Box", map.get("x").?);
    try testing.expectEqualStrings("a \"b\" c", map.get("y").?);
    try testing.expectEqualStrings("\"Quoted\"", map.get("z").?);

    // A label that loading would change again is written with a pair of
    // quotes for the next load to remove.
    try map.parseCLI(alloc, "w: \"  spaced  \"");
    try testing.expectEqualStrings("  spaced  ", map.get("w").?);
    var out: std.Io.Writer.Allocating = .init(alloc);
    try map.formatEntry(formatterpkg.entryFormatter("profile-name", &out.writer));
    const written = out.written();
    try testing.expect(std.mem.indexOf(u8, written, "profile-name = x: Build Box\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "profile-name = z: \"\"Quoted\"\"\n") != null);
    var again: Name = .{};
    var lines = std.mem.splitScalar(u8, written, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try again.parseCLI(alloc, line["profile-name = ".len..]);
    }
    try testing.expect(again.equal(map));
}

test "profile map: lines the loader reports at once" {
    const testing = std.testing;
    const Case = struct { kind: Kind, value: []const u8, err: Error };
    for ([_]Case{
        .{ .kind = .command, .value = "no colon here", .err = error.MissingProfileId },
        .{ .kind = .command, .value = "C:\\Tools\\x.exe", .err = error.ProfileIdLooksLikeDrive },
        .{ .kind = .command, .value = "c:/tools/x.exe", .err = error.ProfileIdLooksLikeDrive },
        .{ .kind = .text, .value = "D:\\My Projects\\api", .err = error.ProfileIdLooksLikeDrive },
        .{ .kind = .command, .value = "pwsh -File D:\\x.ps1", .err = error.InvalidProfileId },
        .{ .kind = .env, .value = "PYTHONHOME=C:\\Python312", .err = error.InvalidProfileId },
        .{ .kind = .command, .value = "caf\xc3\xa9: cmd.exe", .err = error.InvalidProfileId },
        .{ .kind = .command, .value = ("x" ** 65) ++ ": cmd.exe", .err = error.InvalidProfileId },
        .{ .kind = .command, .value = "CMD.EXE: x", .err = error.ReservedProfileId },
        .{ .kind = .command, .value = "pwsh: x", .err = error.ReservedProfileId },
        .{ .kind = .name, .value = "wsl:Ubuntu: X", .err = error.ReservedProfileId },
        .{ .kind = .command, .value = "user:py: cmd.exe", .err = error.ReservedProfileId },
        .{ .kind = .command, .value = "d1: direct:cmd.exe", .err = error.ProfileCommandPrefix },
        .{ .kind = .command, .value = "s1: SHELL:cmd.exe", .err = error.ProfileCommandPrefix },
        .{ .kind = .command, .value = "p: \"\"", .err = error.ProfileNoProgram },
        .{ .kind = .command, .value = "p: \"\" arg", .err = error.ProfileNoProgram },
        .{ .kind = .env, .value = "p: NOEQUALS", .err = error.ValueRequired },
    }) |case| {
        const got = switch (case.kind) {
            inline else => |kind| check(kind, case.value),
        };
        testing.expectError(case.err, got) catch |err| {
            std.debug.print("value: {s}\n", .{case.value});
            return err;
        };
    }

    // What passes: a one-letter id whose text is not a path, a removal of a
    // reserved-looking but valid id with no text, a program in quotes.
    _ = try check(.command, "x: cmd.exe");
    _ = try check(.command, "p: \"\"a");
    _ = try check(.command, "p: \"C:\\a b\\t.exe\" x");
    _ = try check(.text, "x: home");
    _ = try check(.command, "gone:");
    // A known false positive of the drive-letter check: a one-letter id
    // running a program from a share. The message says to use a longer id.
    try testing.expectError(error.ProfileIdLooksLikeDrive, check(.command, "x: \\\\server\\share\\tool.exe"));
}

test "profile map: ids" {
    const testing = std.testing;
    try testing.expect(isValidId("vs18-cmd"));
    try testing.expect(isValidId("Py_3.12"));
    try testing.expect(!isValidId(""));
    try testing.expect(!isValidId("has space"));
    try testing.expect(!isValidId("a/b"));
    try testing.expect(!isValidId("x" ** 65));
    try testing.expect(isValidId("x" ** 64));
    try testing.expect(isReservedId("CMD.EXE"));
    try testing.expect(isReservedId("wsl-default"));
    try testing.expect(isReservedId("Cmd"));
    try testing.expect(isReservedId("USER"));
    try testing.expect(!isReservedId("cmd2"));
}
