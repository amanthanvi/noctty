//! The Profiles page of Settings: the user profiles of the draft config
//! (`profile-command`, `profile-name`, `profile-working-directory`,
//! `profile-env`), a row for each profile and each of its fields, and the
//! changes the page makes to the draft. A save writes them into the config
//! file by identity (`win32/settings_patch.zig`), and the list that shows the
//! rows is `win32_settings.zig`'s `ReferenceList` (`ListKind.profiles`).
//!
//! A command line or a variable's value can hold a secret. Nothing here logs
//! one, and the messages the checks return name the field, never its value.
//! A row's UIA Name names the field and its profile, never a value: what the
//! row shows is its read-only Value (`writeRowValue`), read on request. A
//! variable's value is masked in the row and in that Value
//! (`masked_value`), and shown only in the text field while it is typed
//! into; the search does not find a variable by its value.
//! `profile-order` and `profile-hidden` are shown, not edited.
const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const profile_map = @import("../config/profile_map.zig");
const LineIterator = @import("../cli/args.zig").LineIterator;

pub const RowKind = enum {
    /// "New profile", the first row.
    new_profile,
    /// A profile: its label (or its id) and its command line.
    profile,
    command,
    name,
    folder,
    variable,
    add_variable,

    /// Whether the row is one of a profile's fields, drawn under it.
    pub fn isField(self: RowKind) bool {
        return switch (self) {
            .new_profile, .profile => false,
            else => true,
        };
    }
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
    /// Not what the draft started with: changed here, not saved yet.
    changed: bool,
};

pub const Profile = struct {
    id: []const u8,
    command: []const u8,
    label: ?[]const u8,
    folder: ?[]const u8,
    variables: []const Variable,
    /// `default-profile` names it.
    default: bool,
    /// `profile-hidden` names it.
    hidden: bool,
    /// Its command line comes from noctty's command line: shown, not edited,
    /// since a save would write it into the config file.
    read_only: bool,
    /// Which fields are not what the draft started with.
    changed: Changed,

    pub const Changed = packed struct {
        /// A profile the draft did not have.
        new: bool = false,
        command: bool = false,
        name: bool = false,
        folder: bool = false,
        /// A variable changed, added or taken out.
        variables: bool = false,

        pub fn any(self: Changed) bool {
            return self.new or self.command or self.name or self.folder or self.variables;
        }
    };
};

pub const Row = struct {
    kind: RowKind,
    /// Its profile: an index into `Model.profiles` (none for `.new_profile`).
    profile: u32 = 0,
    /// `.variable`: an index into its profile's `variables`.
    variable: u32 = 0,
    /// What UIA knows the row by across rebuilds: its kind, its profile's
    /// id and its variable's name, without case (`identity`).
    identity: u64,
    /// What the search finds it by, in lower case.
    search: []const u8,
};

/// The rows of the Profiles page, built from the draft config.
pub const Model = struct {
    arena: ?std.heap.ArenaAllocator = null,
    profiles: []const Profile = &.{},
    rows: []const Row = &.{},

    /// The most rows a model holds: the list knows a row by a `u16`.
    pub const max_rows: usize = std.math.maxInt(u16);

    pub fn built(self: *const Model) bool {
        return self.arena != null;
    }

    pub fn deinit(self: *Model) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    /// The rows for `draft`'s user profiles, in the order the picker lists
    /// them before `profile-order` (the order of their first
    /// `profile-command` line), removed ones left out; `original` (the
    /// config the draft started from) tells which fields changed. A config
    /// with more rows than `max_rows` lists the profiles that fit.
    pub fn build(self: *Model, alloc: Allocator, draft: *const Config, original: ?*const Config) Allocator.Error!void {
        self.deinit();
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        var profiles: std.ArrayListUnmanaged(Profile) = .empty;
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        try rows.append(a, .{ .kind = .new_profile, .identity = identity(.new_profile, "", null), .search = "new profile add create" });
        const cli = try commandLineIds(a, draft);
        for (draft.@"profile-command".entries.items) |entry| {
            if (entry.removed) continue;
            const env = draft.@"profile-env".get(entry.id);
            const variable_count = if (env) |map| map.count() else 0;
            // The profile's own row, its three fields, its variables and
            // "Add variable".
            if (rows.items.len + 5 + variable_count > max_rows) break;
            // Copies: the draft may be replaced while the page shows them.
            const id = try a.dupe(u8, entry.id);
            const command = try a.dupe(u8, entry.value);
            const label = try dupeOptional(a, draft.@"profile-name".get(entry.id));
            const folder = try dupeOptional(a, draft.@"profile-working-directory".get(entry.id));
            var changed: Profile.Changed = .{};
            if (original) |was| {
                const was_command = was.@"profile-command".get(entry.id);
                changed.new = was_command == null;
                changed.command = !changed.new and !std.mem.eql(u8, was_command.?, command);
                changed.name = !optionalEql(was.@"profile-name".get(entry.id), label);
                changed.folder = !optionalEql(was.@"profile-working-directory".get(entry.id), folder);
            }
            const was_env = if (original) |was| was.@"profile-env".get(entry.id) else null;
            const variables = try a.alloc(Variable, variable_count);
            if (env) |map| {
                var it = map.iterator();
                var index: usize = 0;
                while (it.next()) |kv| : (index += 1) {
                    const was_value = if (was_env) |was| envGet(was, kv.key_ptr.*) else null;
                    variables[index] = .{
                        .name = try a.dupe(u8, kv.key_ptr.*),
                        .value = try a.dupe(u8, kv.value_ptr.*),
                        .changed = original != null and !optionalEql(was_value, kv.value_ptr.*),
                    };
                    if (variables[index].changed) changed.variables = true;
                }
            }
            // A variable taken out leaves no row, but the profile changed.
            if (was_env) |was| {
                var it = was.iterator();
                while (it.next()) |kv| {
                    if (env == null or envGet(env.?, kv.key_ptr.*) == null) changed.variables = true;
                }
            }
            const index: u32 = @intCast(profiles.items.len);
            try profiles.append(a, .{
                .id = id,
                .command = command,
                .label = label,
                .folder = folder,
                .variables = variables,
                .default = namesProfile(draft.@"default-profile", entry.id),
                .hidden = hiddenIn(draft, entry.id),
                .read_only = containsId(cli, entry.id),
                .changed = changed,
            });
            const profile = &profiles.items[index];
            const shown = label orelse id;
            try rows.append(a, .{ .kind = .profile, .profile = index, .identity = identity(.profile, id, null), .search = try lower(a, &.{ shown, "\n", id, "\nuser:", id, "\n", command }) });
            try rows.append(a, .{ .kind = .command, .profile = index, .identity = identity(.command, id, null), .search = try lower(a, &.{ "command line\n", shown, "\n", id, "\n", command }) });
            try rows.append(a, .{ .kind = .name, .profile = index, .identity = identity(.name, id, null), .search = try lower(a, &.{ "name label\n", shown, "\n", id }) });
            try rows.append(a, .{ .kind = .folder, .profile = index, .identity = identity(.folder, id, null), .search = try lower(a, &.{ "starting folder working directory\n", shown, "\n", id, "\n", folder orelse "" }) });
            for (profile.variables, 0..) |variable, variable_index| {
                try rows.append(a, .{
                    .kind = .variable,
                    .profile = index,
                    .variable = @intCast(variable_index),
                    .identity = identity(.variable, id, variable.name),
                    .search = try lower(a, &.{ "environment variable\n", shown, "\n", id, "\n", variable.name }),
                });
            }
            try rows.append(a, .{ .kind = .add_variable, .profile = index, .identity = identity(.add_variable, id, null), .search = try lower(a, &.{ "add environment variable\n", shown, "\n", id }) });
        }
        self.* = .{ .arena = arena, .profiles = profiles.items, .rows = rows.items };
    }

    /// The row known as `wanted` (`Row.identity`), if the model has it.
    pub fn find(self: *const Model, wanted: u64) ?u16 {
        for (self.rows, 0..) |row, index| {
            if (row.identity == wanted) return @intCast(index);
        }
        return null;
    }

    /// The row of profile `id`'s field `kind` (its variable `name`).
    pub fn findField(self: *const Model, kind: RowKind, id: []const u8, name: ?[]const u8) ?u16 {
        return self.find(identity(kind, id, name));
    }

    pub fn profileOf(self: *const Model, row: Row) ?*const Profile {
        if (row.kind == .new_profile) return null;
        return &self.profiles[row.profile];
    }

    /// The row's first line, left: what it is.
    pub fn title(self: *const Model, row: Row) []const u8 {
        return switch (row.kind) {
            .new_profile => "New profile",
            .profile => self.profiles[row.profile].label orelse self.profiles[row.profile].id,
            .command => "Command line",
            .name => "Name",
            .folder => "Starting folder",
            .variable => self.profiles[row.profile].variables[row.variable].name,
            .add_variable => "Add variable",
        };
    }

    /// The row's first line, right: its value, and for a profile its key and
    /// what is true of it. Empty for a field with no value (`emptyValue`).
    pub fn writeValue(self: *const Model, row: Row, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (row.kind) {
            .new_profile, .add_variable => {},
            .profile => {
                const profile = &self.profiles[row.profile];
                try writer.print("user:{s}", .{profile.id});
                try writeMarks(profile, writer, " (", ")");
            },
            .command => {
                try writer.writeAll(self.profiles[row.profile].command);
                if (self.profiles[row.profile].changed.command) try writer.writeAll(changed_mark);
            },
            .name => {
                const profile = &self.profiles[row.profile];
                try writer.writeAll(profile.label orelse "");
                if (profile.changed.name) try writer.writeAll(changed_mark);
            },
            .folder => {
                const profile = &self.profiles[row.profile];
                try writer.writeAll(profile.folder orelse "");
                if (profile.changed.folder) try writer.writeAll(changed_mark);
            },
            .variable => {
                const variable = &self.profiles[row.profile].variables[row.variable];
                try writer.writeAll(masked_value);
                if (variable.changed) try writer.writeAll(changed_mark);
            },
        }
    }

    /// Whether the row's field has no value (drawn in the secondary colour,
    /// with the summary saying what that means).
    pub fn emptyValue(self: *const Model, row: Row) bool {
        return switch (row.kind) {
            .name => self.profiles[row.profile].label == null,
            .folder => self.profiles[row.profile].folder == null,
            else => false,
        };
    }

    /// The row's second line.
    pub fn summary(self: *const Model, row: Row) []const u8 {
        return switch (row.kind) {
            .new_profile => "Add a profile: Enter asks for its id, then for its command line.",
            .profile => self.profiles[row.profile].command,
            .command => "The program and arguments the profile starts.",
            .name => if (self.profiles[row.profile].label == null) "None: the picker shows the profile's id." else "The profile's label in the picker and the palette.",
            .folder => if (self.profiles[row.profile].folder == null) "None: the profile starts in the home folder." else "Where the profile starts: home, inherit or a folder.",
            .variable => "An environment variable of the profile.",
            .add_variable => "Enter asks for the variable as NAME=VALUE.",
        };
    }

    /// The open row's text: what the row is and what its keys do.
    pub fn writeHelp(self: *const Model, row: Row, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (row.kind == .new_profile) return writer.writeAll(
            "A profile is a command line with a name, a starting folder and environment variables of its own. " ++
                "New tabs start one from the profile picker, the command palette or the Default profile setting. " ++
                "Enter asks for the new profile's id (1 to 64 letters, digits, dots, hyphens or underscores, which cannot be changed later), then for its command line.",
        );
        const profile = &self.profiles[row.profile];
        if (profile.read_only) return writer.print(
            "Profile user:{s} comes from noctty's command line, so Settings does not change it: a change saved to the config file would not be used while that command line names it.",
            .{profile.id},
        );
        switch (row.kind) {
            .new_profile => unreachable,
            .profile => {
                try writer.print("Profile user:{s}. Its id cannot be changed: sessions, layouts and the taskbar's jump list name the profile by it. Enter edits its command line; Delete removes the profile.", .{profile.id});
                if (profile.default) try writer.writeAll(" Default profile names it: once it is removed, new tabs open the automatic shell.");
                if (profile.hidden) try writer.writeAll(" profile-hidden leaves it out of the picker, the palette and the jump list; change that in the config file.");
            },
            .command => try writer.writeAll("A Windows command line, used exactly as written: nothing is unquoted or unescaped, and %NAME% is replaced by the variable's value. Enter edits it."),
            .name => try writer.writeAll("The profile's label in the picker and the palette; without one they show its id. Enter edits it; Delete takes it out."),
            .folder => try writer.writeAll("home, inherit, or a folder (~/ is your home folder, %NAME% is replaced, a folder with spaces needs no quotes). Without one, the profile starts in the home folder. Enter edits it; Delete takes it out."),
            .variable => try writer.writeAll("An environment variable the profile's shell gets. Names are compared without case. %NAME% in the value is replaced by the value the shell would get without this profile. Enter edits the value; Delete takes the variable out."),
            .add_variable => try writer.writeAll("Enter asks for a variable as NAME=VALUE. A name the profile has already gets the new value."),
        }
    }

    /// The row's UIA name: what it is, whose it is and what is true of it,
    /// never a value ("Command line of py312", "Variable PATH of py312").
    /// What the row shows is its Value (`writeRowValue`).
    pub fn writeUiaName(self: *const Model, row: Row, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (row.kind) {
            .new_profile => try writer.writeAll("New profile"),
            .profile => {
                const profile = &self.profiles[row.profile];
                try writer.print("{s}, profile user:{s}", .{ profile.label orelse profile.id, profile.id });
                try writeMarks(profile, writer, ", ", "");
            },
            .add_variable => try writer.print("Add variable to {s}", .{self.profiles[row.profile].id}),
            .command, .name, .folder, .variable => {
                const profile = &self.profiles[row.profile];
                if (row.kind == .variable)
                    try writer.print("Variable {s} of {s}", .{ profile.variables[row.variable].name, profile.id })
                else
                    try writer.print("{s} of {s}", .{ self.title(row), profile.id });
                const changed = switch (row.kind) {
                    .command => profile.changed.command,
                    .name => profile.changed.name,
                    .folder => profile.changed.folder,
                    .variable => profile.variables[row.variable].changed,
                    else => unreachable,
                };
                if (changed) try writer.writeAll(", changed here, not saved yet");
            },
        }
    }

    /// The row's read-only UIA Value, what it shows: the command line (a
    /// profile's row shows it too), the label or the starting folder ("none"
    /// for neither), `value_hidden` for a variable. False for a row with no
    /// value (New profile, Add variable).
    pub fn writeRowValue(self: *const Model, row: Row, writer: *std.Io.Writer) std.Io.Writer.Error!bool {
        switch (row.kind) {
            .new_profile, .add_variable => return false,
            .profile => try writer.writeAll(self.profiles[row.profile].command),
            .variable => try writer.writeAll(value_hidden),
            .command, .name, .folder => if (self.emptyValue(row)) try writer.writeAll("none") else try self.writeValueText(row, writer),
        }
        return true;
    }

    /// The field's value alone, without the mark `writeValue` adds.
    fn writeValueText(self: *const Model, row: Row, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const profile = &self.profiles[row.profile];
        try writer.writeAll(switch (row.kind) {
            .command => profile.command,
            .name => profile.label orelse "",
            .folder => profile.folder orelse "",
            .variable => profile.variables[row.variable].value,
            else => "",
        });
    }
};

const changed_mark = " (changed here, not saved yet)";

/// How a row shows a variable's value: masked, so a screenshot or someone
/// looking on does not get it. The text field shows it while it is typed
/// into.
pub const masked_value = "\u{2022}" ** 6;
/// A variable row's UIA Value, in words.
pub const value_hidden = "value hidden";

/// What is true of a profile, in words, between `open` and `close`:
/// "(default profile, hidden)".
fn writeMarks(profile: *const Profile, writer: *std.Io.Writer, open: []const u8, close: []const u8) std.Io.Writer.Error!void {
    var first = true;
    const marks = [_]struct { on: bool, text: []const u8 }{
        .{ .on = profile.default, .text = "default profile" },
        .{ .on = profile.hidden, .text = "hidden" },
        .{ .on = profile.read_only, .text = "from the command line, read-only" },
        .{ .on = profile.changed.any(), .text = if (profile.changed.new) "new, not saved yet" else "changed here, not saved yet" },
    };
    for (marks) |mark| {
        if (!mark.on) continue;
        try writer.writeAll(if (first) open else ", ");
        first = false;
        try writer.writeAll(mark.text);
    }
    if (!first) try writer.writeAll(close);
}

/// What UIA knows a row by: its kind, its profile's id and its variable's
/// name, without case, which is how the loader tells them apart.
pub fn identity(kind: RowKind, id: []const u8, name: ?[]const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(&.{@intFromEnum(kind)});
    for (id) |c| hasher.update(&.{std.ascii.toLower(c)});
    if (name) |text| {
        hasher.update(&.{0});
        for (text) |c| hasher.update(&.{std.ascii.toLower(c)});
    }
    return hasher.final();
}

fn dupeOptional(a: Allocator, text: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (text) |value| try a.dupe(u8, value) else null;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The value of variable `name` (any case) in `map`.
fn envGet(map: anytype, name: []const u8) ?[]const u8 {
    var it = map.iterator();
    while (it.next()) |kv| {
        if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) return kv.value_ptr.*;
    }
    return null;
}

fn lower(a: Allocator, parts: []const []const u8) Allocator.Error![]const u8 {
    const text = try std.mem.concat(a, u8, parts);
    for (text) |*c| c.* = std.ascii.toLower(c.*);
    return text;
}

/// Whether `value` (a `default-profile` or `profile-hidden` value) names user
/// profile `id`: its id or `user:<id>`, without case.
fn namesProfile(value: ?[]const u8, id: []const u8) bool {
    const text = value orelse return false;
    if (std.ascii.eqlIgnoreCase(text, id)) return true;
    return text.len == "user:".len + id.len and std.ascii.startsWithIgnoreCase(text, "user:") and std.ascii.eqlIgnoreCase(text["user:".len..], id);
}

fn hiddenIn(config: *const Config, id: []const u8) bool {
    for (config.@"profile-hidden".list.items) |value| {
        if (namesProfile(value, id)) return true;
    }
    return false;
}

/// The ids whose `profile-command` was last written by noctty's command line
/// (`pane_launch.ProfilePlace`), in lower case.
fn commandLineIds(a: Allocator, config: *const Config) Allocator.Error!std.StringHashMapUnmanaged(void) {
    var last: std.StringHashMapUnmanaged(bool) = .empty;
    for (config._launch.profile_places.items) |place| {
        if (!std.mem.eql(u8, place.key, @tagName(Config.Key.@"profile-command"))) continue;
        const key = try a.dupe(u8, place.id);
        for (key) |*c| c.* = std.ascii.toLower(c.*);
        try last.put(a, key, place.location == .cli);
    }
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var it = last.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.*) try ids.put(a, kv.key_ptr.*, {});
    }
    return ids;
}

fn containsId(ids: std.StringHashMapUnmanaged(void), id: []const u8) bool {
    var buf: [profile_map.max_id_len]u8 = undefined;
    if (id.len > buf.len) return false;
    for (id, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return ids.contains(buf[0..id.len]);
}

/// Whether `draft` changed a profile field (`changedFieldCount`): what a save
/// would write. A profile added and removed again is no change.
pub fn draftChanged(original: *const Config, draft: *const Config) bool {
    return changedFieldCount(original, draft) != 0;
}

/// How many profile fields `draft` changed: a command line (a profile added
/// or removed counts as its command), a label, a starting folder, and each
/// variable. What the close prompt and the Advanced page count.
pub fn changedFieldCount(original: *const Config, draft: *const Config) usize {
    var count: usize = textChanges(.command, &original.@"profile-command", &draft.@"profile-command");
    count += textChanges(.name, &original.@"profile-name", &draft.@"profile-name");
    count += textChanges(.text, &original.@"profile-working-directory", &draft.@"profile-working-directory");
    // Each variable either side has, once.
    const was_env = &original.@"profile-env";
    const now_env = &draft.@"profile-env";
    for (now_env.entries.items, 0..) |entry, at| {
        const was = if (sameSlot(.env, was_env, at, entry.id) orelse was_env.indexOf(entry.id)) |index| was_env.entries.items[index].value else null;
        var it = entry.value.iterator();
        while (it.next()) |kv| {
            const before = if (was) |map| envGet(map, kv.key_ptr.*) else null;
            if (!optionalEql(before, kv.value_ptr.*)) count += 1;
        }
    }
    for (was_env.entries.items, 0..) |entry, at| {
        const now = if (sameSlot(.env, now_env, at, entry.id) orelse now_env.indexOf(entry.id)) |index| now_env.entries.items[index].value else null;
        var it = entry.value.iterator();
        while (it.next()) |kv| {
            if (now == null or envGet(now.?, kv.key_ptr.*) == null) count += 1;
        }
    }
    return count;
}

/// The ids whose text differs between `was` and `now`, a removed command
/// counting as none.
fn textChanges(comptime kind: profile_map.Kind, was: *const profile_map.ProfileMap(kind), now: *const profile_map.ProfileMap(kind)) usize {
    var count: usize = 0;
    for (now.entries.items, 0..) |entry, at| {
        const before = sameSlot(kind, was, at, entry.id) orelse was.indexOf(entry.id);
        if (!optionalEql(liveText(kind, was, before), liveText(kind, now, at))) count += 1;
    }
    for (was.entries.items, 0..) |entry, at| {
        if (entry.removed) continue;
        if (sameSlot(kind, now, at, entry.id) == null and now.indexOf(entry.id) == null) count += 1;
    }
    return count;
}

/// `at`, when `map` has `id` there: a draft keeps its original's order, so
/// most lookups end here instead of in a scan of every id (`indexOf`).
fn sameSlot(comptime kind: profile_map.Kind, map: *const profile_map.ProfileMap(kind), at: usize, id: []const u8) ?usize {
    if (at < map.entries.items.len and std.ascii.eqlIgnoreCase(map.entries.items[at].id, id)) return at;
    return null;
}

/// The text of the entry at `index`, when there is one and it is not removed.
fn liveText(comptime kind: profile_map.Kind, map: *const profile_map.ProfileMap(kind), index: ?usize) ?[]const u8 {
    const entry = map.entries.items[index orelse return null];
    return if (entry.removed) null else entry.value;
}

/// The config file changed while Settings was open (`replacement` is what it
/// says now): when the draft changed no profile, `original` and `draft` take
/// the file's profiles, as an unedited setting takes the file's value. A
/// draft that changed one keeps every profile as it was, and a save writes
/// only what the page changed (`settings_patch.profileEdits`). The marks the
/// page shows (`default-profile` aside, which is a setting of its own) follow
/// the file either way.
pub fn followFile(original: *Config, draft: *Config, replacement: *const Config) Allocator.Error!void {
    const follow_profiles = !draftChanged(original, draft);
    for ([_]*Config{ original, draft }) |config| {
        const a = arenaOf(config);
        config.@"profile-hidden" = try replacement.@"profile-hidden".clone(a);
        config.@"profile-order" = try replacement.@"profile-order".clone(a);
        if (!follow_profiles) continue;
        config.@"profile-command" = try replacement.@"profile-command".clone(a);
        config.@"profile-name" = try replacement.@"profile-name".clone(a);
        config.@"profile-working-directory" = try replacement.@"profile-working-directory".clone(a);
        config.@"profile-env" = try replacement.@"profile-env".clone(a);
        // Where those lines were read goes with them; the ledger's copy
        // is the public way to take it (`pane_launch.Ledger.clone`), and the
        // rest of that copy stays in the draft's arena unused.
        config._launch.profile_places = (try replacement._launch.clone(a)).profile_places;
    }
}

// Checks. Each returns the message the status line shows for a value Settings
// refuses, which names the field and never holds the value.

/// What an edit of `kind`'s text for profile `id` would write, refused: a
/// line break, a line too long for the config reader, and what the loader
/// refuses (`profile_map.check`). `text` is trimmed. Null when it is fine.
pub fn checkText(comptime kind: profile_map.Kind, id: []const u8, text: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return "A value cannot hold a line break.";
    if (!std.unicode.utf8ValidateSlice(text)) return "That text cannot be saved.";
    const key = switch (kind) {
        .command => "profile-command",
        .name => "profile-name",
        .text => "profile-working-directory",
        .env => "profile-env",
    };
    if (!fitsOneLine(kind, key, id, text)) return "That is too long for one line of the config file.";
    var buf: [LineIterator.max_line_len]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{s}: {s}", .{ id, text }) catch return "That is too long for one line of the config file.";
    _ = profile_map.check(kind, value) catch |err| return switch (err) {
        error.MissingProfileId, error.InvalidProfileId => "A profile id is 1 to 64 letters, digits, dots, hyphens or underscores.",
        error.ReservedProfileId => "That id names one of noctty's detected profiles: choose another.",
        error.ProfileIdLooksLikeDrive => "A one-letter profile id cannot have a value that starts with \\ or /: it reads as a drive. Choose a longer id.",
        error.ProfileCommandPrefix => "A profile's command line cannot start with direct: or shell:.",
        error.ProfileNoProgram => "The command line names no program.",
        error.ValueRequired => "Type the variable as NAME=VALUE.",
        error.ProfileEnvNoName => "The variable needs a name before its =.",
        error.ProfileNotUtf8 => "That text cannot be saved.",
    };
    return null;
}

/// Whether the line Save writes for `text` (`profile_map.writeProfileLine`,
/// in whichever form it picks, with a label's quotes when it needs them) is
/// one the config reader takes: measured, not reckoned.
fn fitsOneLine(comptime kind: profile_map.Kind, key: []const u8, id: []const u8, text: []const u8) bool {
    // The longest line the reader takes, and its `\n`.
    var buf: [LineIterator.max_line_len + 1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    profile_map.writeProfileLine(&writer, kind, key, id, text) catch return false;
    return true;
}

/// A new profile's id, refused: not 1 to 64 of `[A-Za-z0-9._-]`, reserved, or
/// the id of a profile `draft` lists (without case). A removed one's id may
/// be used again: the profile comes back with the fields it had.
pub fn checkNewId(draft: *const Config, id: []const u8) ?[]const u8 {
    if (id.len == 0) return "Type the new profile's id.";
    if (!profile_map.isValidId(id)) return "A profile id is 1 to 64 letters, digits, dots, hyphens or underscores.";
    if (profile_map.isReservedId(id)) return "That id names one of noctty's detected profiles: choose another.";
    if (draft.@"profile-command".get(id) != null) return "A profile with that id exists already.";
    return null;
}

/// A command line, refused: empty, or what `checkText` refuses.
pub fn checkCommand(id: []const u8, text: []const u8) ?[]const u8 {
    if (text.len == 0) return "A profile needs a command line. Delete on the profile's row removes the profile.";
    return checkText(.command, id, text);
}

/// `NAME=VALUE` as the add-variable field holds it, trimmed.
pub const VariableText = struct { name: []const u8, value: []const u8 };

/// A new variable, refused: no `=`, no name, no value, or what `checkText`
/// refuses.
pub fn checkNewVariable(id: []const u8, text: []const u8) union(enum) { ok: VariableText, refused: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return .{ .refused = "Type the variable as NAME=VALUE." };
    const name = std.mem.trim(u8, text[0..eq], &std.ascii.whitespace);
    const value = std.mem.trim(u8, text[eq + 1 ..], &std.ascii.whitespace);
    if (name.len == 0) return .{ .refused = "The variable needs a name before its =." };
    if (value.len == 0) return .{ .refused = "Give the variable a value. Delete on a variable's row takes it out." };
    if (checkVariableValue(id, name, value)) |message| return .{ .refused = message };
    return .{ .ok = .{ .name = name, .value = value } };
}

/// A variable's value, refused: empty, or what `checkText` refuses.
pub fn checkVariableValue(id: []const u8, name: []const u8, value: []const u8) ?[]const u8 {
    if (value.len == 0) return "Give the variable a value. Delete on a variable's row takes it out.";
    if (std.mem.indexOfAny(u8, name, "\r\n") != null or std.mem.indexOfAny(u8, value, "\r\n") != null) return "A value cannot hold a line break.";
    if (name.len + 1 + value.len > LineIterator.max_line_len) return "That is too long for one line of the config file.";
    var buf: [LineIterator.max_line_len + 1]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}={s}", .{ name, value }) catch return "That is too long for one line of the config file.";
    return checkText(.env, id, text);
}

/// Assert two texts are the same without printing either: a profile's command
/// line or a variable's value can be a secret, and a failed
/// `expectEqualStrings` prints both strings. Every test of profile text uses
/// this, for row text, file bytes and messages alike.
fn expectSameText(expected: []const u8, actual: []const u8) !void {
    try testing.expect(std.mem.eql(u8, expected, actual));
}

test "profile checks take a line of exactly the reader's length, and refuse one byte more" {
    const too_long = "That is too long for one line of the config file.";
    const max = LineIterator.max_line_len;
    // What Save writes, less its `\n`.
    const written = struct {
        fn len(comptime kind: profile_map.Kind, key: []const u8, text: []const u8) !usize {
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try profile_map.writeProfileLine(&out.writer, kind, key, "py", text);
            return out.written().len - 1;
        }
    }.len;
    var buf: [max + 8]u8 = undefined;
    // Lines of 4,092 to 4,095 bytes, each in the compact form: a command, a
    // variable `V`, and a label that needs its quotes.
    for (0..4) |extra| {
        const accepted = max - 2 + extra <= max;
        const command = buf[0 .. 4073 + extra];
        @memset(command, 'x');
        try std.testing.expectEqual(max - 2 + extra, try written(.command, "profile-command", command));
        if (accepted) {
            try std.testing.expect(checkCommand("py", command) == null);
        } else try expectSameText(too_long, checkCommand("py", command).?);

        const value = buf[0 .. 4075 + extra];
        @memset(value, 'v');
        var text_buf: [max + 8]u8 = undefined;
        const variable = try std.fmt.bufPrint(&text_buf, "V={s}", .{value});
        try std.testing.expectEqual(max - 2 + extra, try written(.env, "profile-env", variable));
        if (accepted) {
            try std.testing.expect(checkVariableValue("py", "V", value) == null);
        } else try expectSameText(too_long, checkVariableValue("py", "V", value).?);

        const label = buf[0 .. 4072 + extra + 2];
        @memset(label, 'n');
        label[0] = '"';
        label[label.len - 1] = '"';
        try std.testing.expectEqual(max - 2 + extra, try written(.name, "profile-name", label));
        if (accepted) {
            try std.testing.expect(checkText(.name, "py", label) == null);
        } else try expectSameText(too_long, checkText(.name, "py", label).?);
    }
}

// Changes to the draft. Each takes a value its check passed, and allocates in
// the draft's arena, as the loader does.

fn arenaOf(draft: *Config) Allocator {
    return draft._arena.?.allocator();
}

/// Profile `id`'s command line is `text`; a profile the draft does not have,
/// or removed, is defined (a removed one comes back with its fields).
pub fn setCommand(draft: *Config, id: []const u8, text: []const u8) Allocator.Error!void {
    try draft.@"profile-command".put(arenaOf(draft), id, text);
}

/// Profile `id`'s label (`.name`) or starting folder (`.folder`) is `text`;
/// an empty one takes it out.
pub fn setField(draft: *Config, field: enum { name, folder }, id: []const u8, text: []const u8) Allocator.Error!void {
    const a = arenaOf(draft);
    switch (field) {
        .name => if (text.len == 0) draft.@"profile-name".remove(id) else try draft.@"profile-name".put(a, id, text),
        .folder => if (text.len == 0) draft.@"profile-working-directory".remove(id) else try draft.@"profile-working-directory".put(a, id, text),
    }
}

/// Profile `id`'s variable `name` (any case) is `value`: in its place when
/// the profile has it, so the rows keep their order, else last.
pub fn setVariable(draft: *Config, id: []const u8, name: []const u8, value: []const u8) (Allocator.Error || profile_map.Error)!void {
    const a = arenaOf(draft);
    const env = &draft.@"profile-env";
    if (env.indexOf(id)) |index| {
        const map = &env.entries.items[index].value.map;
        for (map.keys(), 0..) |key, at| {
            if (!std.ascii.eqlIgnoreCase(key, name)) continue;
            map.values()[at] = try a.dupeZ(u8, value);
            return;
        }
        try map.put(a, try a.dupeZ(u8, name), try a.dupeZ(u8, value));
        return;
    }
    const line = try std.fmt.allocPrint(a, "{s}: {s}={s}", .{ id, name, value });
    try env.parseCLI(a, line);
}

/// Take profile `id`'s variable `name` (any case) out.
pub fn removeVariable(draft: *Config, id: []const u8, name: []const u8) (Allocator.Error || profile_map.Error)!void {
    const a = arenaOf(draft);
    const line = try std.fmt.allocPrint(a, "{s}: {s}=", .{ id, name });
    try draft.@"profile-env".parseCLI(a, line);
}

/// Remove profile `id` whole, as `profile-command = <id>:` does: its other
/// fields stay in the draft, dormant. One the draft brought in (`original`
/// has no profile `id`, or only its tombstone) goes back to what `original`
/// had for it, every field, as if it had never been added.
pub fn removeProfile(original: *const Config, draft: *Config, id: []const u8) (Allocator.Error || profile_map.Error)!void {
    if (original.@"profile-command".get(id) == null) {
        const a = arenaOf(draft);
        try restoreEntry(.command, a, &original.@"profile-command", &draft.@"profile-command", id);
        try restoreEntry(.name, a, &original.@"profile-name", &draft.@"profile-name", id);
        try restoreEntry(.text, a, &original.@"profile-working-directory", &draft.@"profile-working-directory", id);
        try restoreEntry(.env, a, &original.@"profile-env", &draft.@"profile-env", id);
        return;
    }
    const a = arenaOf(draft);
    const line = try std.fmt.allocPrint(a, "{s}:", .{id});
    try draft.@"profile-command".parseCLI(a, line);
}

/// `draft`'s entry for `id` becomes a copy of `original`'s, or goes when
/// `original` has none.
fn restoreEntry(comptime kind: profile_map.Kind, a: Allocator, original: *const profile_map.ProfileMap(kind), draft: *profile_map.ProfileMap(kind), id: []const u8) Allocator.Error!void {
    const was = original.indexOf(id) orelse return draft.remove(id);
    const entry = original.entries.items[was];
    const copy: profile_map.ProfileMap(kind).Entry = .{
        .id = try a.dupeZ(u8, entry.id),
        .value = switch (kind) {
            .command, .name, .text => try a.dupeZ(u8, entry.value),
            .env => try entry.value.clone(a),
        },
        .removed = entry.removed,
    };
    if (draft.indexOf(id)) |index| {
        draft.entries.items[index] = copy;
    } else try draft.entries.append(a, copy);
}

// Tests.

const testing = std.testing;

fn testConfig(alloc: Allocator, text: []const u8, args: []const []const u8) !Config {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    var config = try Config.default(alloc);
    errdefer config.deinit();
    try config.loadFile(alloc, path);
    const cli_args = @import("../cli/args.zig");
    var iter: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(args) };
    try config.loadIter(alloc, &iter);
    try config.finalize();
    return config;
}

fn testRowsText(alloc: Allocator, model: *const Model) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (model.rows) |row| {
        try out.writer.print("{t} {s} =", .{ row.kind, model.title(row) });
        var value: std.Io.Writer.Allocating = .init(alloc);
        defer value.deinit();
        try model.writeValue(row, &value.writer);
        if (value.written().len != 0) try out.writer.print(" {s}", .{value.written()});
        // A variable's value as the draft holds it, which the row masks.
        if (row.kind == .variable) try out.writer.print(" [{s}]", .{model.profiles[row.profile].variables[row.variable].value});
        try out.writer.writeAll("\n");
    }
    return out.toOwnedSlice();
}

test "settings profiles: a row for each profile and each of its fields, in definition order" {
    const alloc = testing.allocator;
    var config = try testConfig(alloc,
        \\profile-command = py: python.exe
        \\profile-name = py: Python
        \\profile-env = py: PATH=C:\py;%PATH%
        \\profile-env = py: MODE=1
        \\profile-command = gone: g.exe
        \\profile-command = dev: cmd.exe /k
        \\profile-working-directory = dev: ~/src
        \\profile-command = gone:
        \\default-profile = user:DEV
        \\profile-hidden = py
        \\
    , &.{"--profile-command=cli: c.exe"});
    defer config.deinit();
    var model: Model = .{};
    defer model.deinit();
    try model.build(alloc, &config, &config);
    const text = try testRowsText(alloc, &model);
    defer alloc.free(text);
    try expectSameText(
        \\new_profile New profile =
        \\profile Python = user:py (hidden)
        \\command Command line = python.exe
        \\name Name = Python
        \\folder Starting folder =
        \\variable PATH = •••••• [C:\py;%PATH%]
        \\variable MODE = •••••• [1]
        \\add_variable Add variable =
        \\profile dev = user:dev (default profile)
        \\command Command line = cmd.exe /k
        \\name Name =
        \\folder Starting folder = ~/src
        \\add_variable Add variable =
        \\profile cli = user:cli (from the command line, read-only)
        \\command Command line = c.exe
        \\name Name =
        \\folder Starting folder =
        \\add_variable Add variable =
        \\
    , text);
    try testing.expect(model.emptyValue(model.rows[4]));
    try testing.expectEqual(@as(?u16, 5), model.findField(.variable, "PY", "path"));
    try testing.expectEqual(@as(?u16, null), model.findField(.profile, "gone", null));
}

test "settings profiles: what the draft changed is marked, and a removed variable marks its profile" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-env = py: A=1\nprofile-env = py: B=2\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    try setCommand(&draft, "py", "python.exe -X utf8");
    try setVariable(&draft, "PY", "a", "10");
    try removeVariable(&draft, "py", "B");
    try setField(&draft, .name, "py", "Python");
    try setCommand(&draft, "new", "n.exe");
    var model: Model = .{};
    defer model.deinit();
    try model.build(alloc, &draft, &original);
    const text = try testRowsText(alloc, &model);
    defer alloc.free(text);
    try expectSameText(
        \\new_profile New profile =
        \\profile Python = user:py (changed here, not saved yet)
        \\command Command line = python.exe -X utf8 (changed here, not saved yet)
        \\name Name = Python (changed here, not saved yet)
        \\folder Starting folder =
        \\variable A = •••••• (changed here, not saved yet) [10]
        \\add_variable Add variable =
        \\profile new = user:new (new, not saved yet)
        \\command Command line = n.exe
        \\name Name =
        \\folder Starting folder =
        \\add_variable Add variable =
        \\
    , text);
    // The variable keeps its place and its spelling.
    try expectSameText("A", draft.@"profile-env".get("py").?.map.keys()[0]);
    // A removed profile goes from the rows; defining it again brings it back.
    try removeProfile(&original, &draft, "py");
    try model.build(alloc, &draft, &original);
    try testing.expectEqual(@as(?u16, null), model.findField(.profile, "py", null));
    try setCommand(&draft, "py", "python.exe");
    try model.build(alloc, &draft, &original);
    try testing.expect(model.findField(.name, "py", null) != null);
}

test "settings profiles: the checks refuse what the loader would, and never repeat the value" {
    const alloc = testing.allocator;
    var config = try testConfig(alloc, "profile-command = py: python.exe\n", &.{});
    defer config.deinit();
    const secret = "s3cr3t-token";
    const Case = struct { message: ?[]const u8, refused: bool };
    const cases = [_]Case{
        .{ .message = checkNewId(&config, ""), .refused = true },
        .{ .message = checkNewId(&config, "has space"), .refused = true },
        .{ .message = checkNewId(&config, "x" ** 65), .refused = true },
        .{ .message = checkNewId(&config, "PWSH"), .refused = true },
        .{ .message = checkNewId(&config, "PY"), .refused = true },
        .{ .message = checkNewId(&config, "py2"), .refused = false },
        .{ .message = checkCommand("py", ""), .refused = true },
        .{ .message = checkCommand("py", "direct:" ++ secret), .refused = true },
        .{ .message = checkCommand("py", "\"\" " ++ secret), .refused = true },
        .{ .message = checkCommand("c", "\\tools\\" ++ secret), .refused = true },
        .{ .message = checkCommand("py", secret ++ "\r\nx"), .refused = true },
        .{ .message = checkCommand("py", "x" ** 4090), .refused = true },
        .{ .message = checkCommand("py", "cmd.exe /k " ++ secret), .refused = false },
        .{ .message = checkText(.name, "py", "\"" ++ secret ++ "\""), .refused = false },
        .{ .message = checkText(.text, "py", "~/" ++ secret), .refused = false },
        .{ .message = checkVariableValue("py", "TOKEN", ""), .refused = true },
        .{ .message = checkVariableValue("py", "TOKEN", secret ++ "\n"), .refused = true },
        .{ .message = checkVariableValue("py", "TOKEN", secret), .refused = false },
    };
    for (cases, 0..) |case, index| {
        errdefer std.debug.print("case {d}\n", .{index});
        try testing.expectEqual(case.refused, case.message != null);
        if (case.message) |message| try testing.expect(std.mem.indexOf(u8, message, secret) == null);
    }
    for ([_][]const u8{ "", "=1", "TOKEN=", "TOKEN" }) |text| {
        try testing.expect(checkNewVariable("py", text) == .refused);
    }
    const ok = switch (checkNewVariable("py", " TOKEN = " ++ secret ++ " ")) {
        .ok => |variable| variable,
        .refused => return error.TestUnexpectedResult,
    };
    try expectSameText("TOKEN", ok.name);
    try expectSameText(secret, ok.value);
}

test "settings profiles: a draft the page changed saves and reads back as the page shows it" {
    const settings_patch = @import("win32/settings_patch.zig");
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "# mine\nprofile-command = tomb:\nprofile-command = py: python.exe\nprofile-name = py: Py\nprofile-env = py: A=1\nprofile-env = py: B=2\nprofile-command = old: o.exe\n";
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    var original = try Config.default(alloc);
    defer original.deinit();
    try original.loadFile(alloc, path);
    try original.finalize();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    try setCommand(&draft, "py", "python.exe -X utf8");
    try setField(&draft, .name, "py", "\" Quoted \"");
    try setField(&draft, .folder, "py", "~/src");
    try setVariable(&draft, "py", "a", "10");
    try removeVariable(&draft, "py", "b");
    try setVariable(&draft, "py", "C", "3");
    try removeProfile(&original, &draft, "old");
    // A profile added and removed again leaves nothing behind.
    try setCommand(&draft, "gone", "g.exe");
    try setField(&draft, .name, "gone", "Gone");
    try removeProfile(&original, &draft, "gone");
    try testing.expect(draft.@"profile-command".indexOf("gone") == null);
    try testing.expect(draft.@"profile-name".indexOf("gone") == null);
    // So does one on an id the file had removed: it goes back to that.
    try setCommand(&draft, "tomb", "t.exe");
    try setField(&draft, .name, "tomb", "Tomb");
    try removeProfile(&original, &draft, "tomb");
    try testing.expect(draft.@"profile-command".entries.items[draft.@"profile-command".indexOf("tomb").?].removed);
    try testing.expect(draft.@"profile-name".indexOf("tomb") == null);
    try setCommand(&draft, "new", "n.exe");
    try setField(&draft, .name, "new", "New");

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const edits = try settings_patch.editsForSave(arena.allocator(), alloc, &.{&original}, .{}, &original, &draft, path, &struct {
        fn same(a: []const u8, b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    }.same);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try settings_patch.patchProfileEdits(alloc, text, edits, &out);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = out.items });
    var reloaded = try Config.default(alloc);
    defer reloaded.deinit();
    try reloaded.loadFile(alloc, path);
    try reloaded.finalize();

    var shown: Model = .{};
    defer shown.deinit();
    try shown.build(alloc, &draft, null);
    var saved: Model = .{};
    defer saved.deinit();
    try saved.build(alloc, &reloaded, null);
    const shown_text = try testRowsText(alloc, &shown);
    defer alloc.free(shown_text);
    const saved_text = try testRowsText(alloc, &saved);
    defer alloc.free(saved_text);
    try expectSameText(shown_text, saved_text);
    try expectSameText("\" Quoted \"", reloaded.@"profile-name".get("py").?);
}
