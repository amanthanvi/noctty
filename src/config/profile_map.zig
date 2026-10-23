//! The value type of the `profile-*` config keys: one entry per user profile
//! id, kept in the order the id first appeared.
//!
//! Every value is `<id>: <text>`. The id ends at the first `:` and the text
//! after it is kept exactly as written, with only the surrounding whitespace
//! trimmed: nothing is unquoted or unescaped, so a Windows command line can be
//! pasted from Windows Terminal or a shortcut as it is. `<id>:` with nothing
//! after it removes that id; an empty value clears the key (the loader resets
//! a field to its default). Ids compare ASCII case-insensitively, and the
//! first spelling seen is the one kept.
//!
//! Which ids are valid is checked by `Config.finalize`, not here, so a file can
//! still set a field before or after the line that defines the profile.
const std = @import("std");
const Allocator = std.mem.Allocator;

const RepeatableStringMap = @import("RepeatableStringMap.zig");
const formatterpkg = @import("formatter.zig");

/// The longest id a profile can have.
pub const max_id_len = 64;

/// The keys of the profiles noctty detects. A user id may not reuse one: the
/// stored key of a user profile is `user:<id>`, but the order and default
/// references of part 2 accept a bare word, which must name one profile.
pub const reserved_ids = [_][]const u8{
    "pwsh.exe",
    "powershell.exe",
    "cmd.exe",
    "git-bash",
    "wsl-default",
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
    /// One string per id (`profile-command`, `profile-name`,
    /// `profile-working-directory`).
    text,
    /// `env` entries per id (`profile-env`): `<id>: KEY=VALUE` sets one,
    /// `<id>: KEY=` removes one, `<id>:` removes all of that id's entries.
    env,
};

pub const Text = ProfileMap(.text);
pub const Env = ProfileMap(.env);

pub fn ProfileMap(comptime kind: Kind) type {
    return struct {
        const Self = @This();

        pub const Value = switch (kind) {
            .text => [:0]const u8,
            .env => RepeatableStringMap,
        };

        pub const Entry = struct {
            id: [:0]const u8,
            value: Value,
        };

        /// Allocated in the parent config's arena, like every config value.
        entries: std.ArrayListUnmanaged(Entry) = .empty,

        pub fn parseCLI(self: *Self, alloc: Allocator, input: ?[]const u8) !void {
            const raw = input orelse return error.ValueRequired;
            const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (value.len == 0) {
                self.entries.clearRetainingCapacity();
                return;
            }
            const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidValue;
            const id = std.mem.trim(u8, value[0..colon], &std.ascii.whitespace);
            const text = std.mem.trim(u8, value[colon + 1 ..], &std.ascii.whitespace);

            if (text.len == 0) {
                if (self.indexOf(id)) |index| _ = self.entries.orderedRemove(index);
                return;
            }

            switch (kind) {
                .text => {
                    const copy = try alloc.dupeZ(u8, text);
                    if (self.indexOf(id)) |index| {
                        self.entries.items[index].value = copy;
                        return;
                    }
                    try self.entries.append(alloc, .{ .id = try alloc.dupeZ(u8, id), .value = copy });
                },
                .env => {
                    // An id whose last variable was removed (`<id>: KEY=`)
                    // goes, as `<id>:` would: an empty entry formats to no
                    // line, so it could not round-trip and `equal` would
                    // tell two identical configs apart.
                    if (self.indexOf(id)) |index| {
                        const map = &self.entries.items[index].value;
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

        pub fn indexOf(self: Self, id: []const u8) ?usize {
            for (self.entries.items, 0..) |entry, index| {
                if (std.ascii.eqlIgnoreCase(entry.id, id)) return index;
            }
            return null;
        }

        pub fn get(self: Self, id: []const u8) ?Value {
            const index = self.indexOf(id) orelse return null;
            return self.entries.items[index].value;
        }

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
                        .text => try alloc.dupeZ(u8, entry.value),
                        .env => try entry.value.clone(alloc),
                    },
                });
            }
            return out;
        }

        /// Compare if two of our value are equal. Required by Config. Order
        /// counts: it is the order the picker lists the profiles in.
        pub fn equal(self: Self, other: Self) bool {
            if (self.entries.items.len != other.entries.items.len) return false;
            for (self.entries.items, other.entries.items) |a, b| {
                if (!std.mem.eql(u8, a.id, b.id)) return false;
                switch (kind) {
                    .text => if (!std.mem.eql(u8, a.value, b.value)) return false,
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
        /// length the config reader accepts round-trips.
        pub fn formatEntry(self: Self, formatter: formatterpkg.EntryFormatter) !void {
            if (self.entries.items.len == 0) {
                try formatter.formatEntry(void, {});
                return;
            }
            for (self.entries.items) |entry| switch (kind) {
                .text => try formatter.writer.print("{s} = {s}: {s}\n", .{ formatter.name, entry.id, entry.value }),
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

    try testing.expectError(error.InvalidValue, map.parseCLI(alloc, "no colon here"));
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
    try testing.expect(!isReservedId("cmd"));
}
