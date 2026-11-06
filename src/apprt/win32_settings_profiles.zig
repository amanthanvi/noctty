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
//! With the app's list of profiles (`Listed`, `Model.buildListed`) the page
//! shows every profile, in the picker's order with the hidden ones last:
//! user profiles with their fields, and the ones noctty finds (shells, WSL,
//! Visual Studio, SSH hosts) as one row each. Moving a profile or hiding it
//! writes `profile-order` and `profile-hidden` whole into the draft
//! (`moveProfile`, `setProfileHidden`), which a save writes to the file.
const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const pane_launch = configpkg.pane_launch;
const profile_map = @import("../config/profile_map.zig");
const windows_shell = @import("../config/windows_shell.zig");
const LineIterator = @import("../cli/args.zig").LineIterator;
const settings_patch = @import("win32/settings_patch.zig");

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

/// A profile as the app lists it (`AppHandle.profileChoices`), in the
/// picker's order: hidden ones last, and up to three quick-slot ones first.
pub const Listed = struct {
    /// The picker's key: `user:<id>` for a user profile (its id in lower
    /// case), else what noctty found (`pwsh.exe`, `wsl:Ubuntu`, ...).
    key: []const u8,
    label: []const u8,
    hidden: bool = false,
    /// The launcher's quick slot that pins it to the front (1 to 3).
    quick_slot: ?u8 = null,
    /// Hidden by noctty itself, not by `profile-hidden`: an older Visual
    /// Studio under `visual-studio-profiles = newest`. The page shows it
    /// last among the hidden ones, and neither list it writes names it.
    found_hidden: bool = false,
    /// The one `default-profile` starts, an alias (`pwsh`, `wsl`,
    /// `vs:newest:cmd`) resolved as the app resolves it.
    default: bool = false,
};

/// What a `profile-order` or `profile-hidden` value names, as the app reads
/// it (`windows_shell.referenceNames`): the keys of the listed profiles. An
/// alias (`wsl`, `pwsh`, `vs:newest:cmd`) is read with it, and kept as
/// written.
pub const Reference = struct {
    value: []const u8,
    keys: []const []const u8,

    pub fn deinit(self: Reference, alloc: Allocator) void {
        for (self.keys) |key| alloc.free(key);
        alloc.free(self.keys);
        alloc.free(self.value);
    }
};

/// The app's reading of the values of both lists (`Reference`).
pub const References = struct {
    order: []const Reference = &.{},
    hidden: []const Reference = &.{},
};

/// A list's `Reference`s by value, the first for each, trimmed: one lookup
/// per value read, not a pass over the list.
const RefMap = std.StringHashMapUnmanaged(*const Reference);
const RefMaps = struct { order: RefMap = .empty, hidden: RefMap = .empty };

fn refMap(a: Allocator, refs: []const Reference) Allocator.Error!RefMap {
    var map: RefMap = .empty;
    for (refs) |*ref| {
        const entry = try map.getOrPut(a, std.mem.trim(u8, ref.value, &std.ascii.whitespace));
        if (!entry.found_existing) entry.value_ptr.* = ref;
    }
    return map;
}

pub const Profile = struct {
    /// A user profile's id; for one noctty found, its key.
    id: []const u8,
    /// The picker's key: `user:<id>`, or what noctty found.
    key: []const u8 = "",
    /// Found by noctty, not a user profile: no fields to edit, only its
    /// place and whether it is hidden.
    detected: bool = false,
    /// The launcher's quick slot that pins it to the front of the picker.
    quick_slot: ?u8 = null,
    /// Hidden by noctty itself (`Listed.found_hidden`): it stays hidden and
    /// does not move.
    found_hidden: bool = false,
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
    /// Built from the app's whole list (`buildListed` with `complete`): a
    /// profile can be moved or hidden. Not while the profiles noctty finds
    /// are still being looked for, or with no list at all.
    complete: bool = false,
    /// The page's order and hidden profiles as the draft started them
    /// (`original`), as `state` gives them: a move or a hide that comes back
    /// to it puts the draft's lists back as they were, so it is no change.
    base: ?Lists = null,
    /// The app's reading of the values of both lists, which the page reads
    /// and writes aliases by (`References`), by value.
    maps: RefMaps = .{},

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
        return self.buildListed(alloc, draft, original, &.{}, false);
    }

    /// `build`, with the app's list of profiles (`listed`, in the picker's
    /// order; empty for none): every profile it lists, in that order, the
    /// hidden ones last, with the user profiles the draft adds after the
    /// last shown user profile and those it removes left out. Once the draft
    /// has its own `profile-order` or `profile-hidden` (the page moved or hid
    /// one), those decide, as they will once saved. `complete`: the list is
    /// the app's whole list, so profiles can be moved and hidden.
    pub fn buildListed(self: *Model, alloc: Allocator, draft: *const Config, original: ?*const Config, listed: []const Listed, complete: bool) Allocator.Error!void {
        return self.buildReferenced(alloc, draft, original, listed, .{}, complete);
    }

    /// `buildListed`, with the app's reading of the lists' values (`refs`),
    /// by which the page reads an alias the draft holds.
    pub fn buildReferenced(self: *Model, alloc: Allocator, draft: *const Config, original: ?*const Config, listed: []const Listed, refs_in: References, complete: bool) Allocator.Error!void {
        self.deinit();
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const refs: References = .{ .order = try copyReferences(a, refs_in.order), .hidden = try copyReferences(a, refs_in.hidden) };
        const maps: RefMaps = .{ .order = try refMap(a, refs.order), .hidden = try refMap(a, refs.hidden) };
        var profiles: std.ArrayListUnmanaged(Profile) = .empty;
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        try rows.append(a, .{ .kind = .new_profile, .identity = identity(.new_profile, "", null), .search = "new profile add create" });
        const cli = try commandLineIds(a, draft);
        const entries = try pageEntries(a, draft, original, listed, &maps);
        // Cut short at `max_rows`: the page does not list every profile, so
        // none is moved or hidden (a written list would leave the rest out).
        var truncated = false;
        for (entries) |page_entry| {
            if (page_entry.user == null) {
                // A profile noctty found: one row.
                if (rows.items.len + 1 > max_rows) {
                    truncated = true;
                    break;
                }
                const item = page_entry.listed.?;
                const index: u32 = @intCast(profiles.items.len);
                const key = try a.dupe(u8, item.key);
                try profiles.append(a, .{
                    .id = key,
                    .key = key,
                    .detected = true,
                    .quick_slot = item.quick_slot,
                    .command = "",
                    .label = try a.dupe(u8, item.label),
                    .folder = null,
                    .variables = &.{},
                    .default = item.default or if (draft.@"default-profile") |value| sameKey(std.mem.trim(u8, value, " \t"), key) else false,
                    .found_hidden = item.found_hidden,
                    .hidden = page_entry.hidden,
                    .read_only = false,
                    .changed = .{},
                });
                try rows.append(a, .{ .kind = .profile, .profile = index, .identity = identity(.profile, key, null), .search = try lower(a, &.{ item.label, "\n", key }) });
                continue;
            }
            const entry = draft.@"profile-command".entries.items[page_entry.user.?];
            const env = draft.@"profile-env".get(entry.id);
            const variable_count = if (env) |map| map.count() else 0;
            // The profile's own row, its three fields, its variables and
            // "Add variable".
            if (rows.items.len + 5 + variable_count > max_rows) {
                truncated = true;
                break;
            }
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
                .key = try std.fmt.allocPrint(a, "user:{s}", .{id}),
                .quick_slot = if (page_entry.listed) |item| item.quick_slot else null,
                .command = command,
                .label = label,
                .folder = folder,
                .variables = variables,
                .default = namesProfile(draft.@"default-profile", entry.id) or (page_entry.listed != null and page_entry.listed.?.default),
                .hidden = page_entry.hidden,
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
        // The page's state for the arrangement the draft started from.
        const base: ?Lists = if (original) |was| if (listed.len != 0) try stateOf(a, was, try pageEntries(a, was, null, listed, &maps)) else null else null;
        // `profiles` is in page order: the shown ones, then the hidden ones.
        self.* = .{
            .arena = arena,
            .profiles = profiles.items,
            .rows = rows.items,
            .complete = complete and listed.len != 0 and !truncated,
            .base = base,
            .maps = maps,
        };
    }

    /// The page's state now: the keys of its profiles in its order and of
    /// the hidden ones, none that noctty hides itself (as `moved` and
    /// `toggledHidden` give it). From `a`.
    pub fn state(self: *const Model, a: Allocator) Allocator.Error!Lists {
        var order: std.ArrayListUnmanaged([]const u8) = .empty;
        var hidden: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.profiles) |profile| {
            if (profile.found_hidden) continue;
            try order.append(a, profile.key);
            if (profile.hidden) try hidden.append(a, profile.key);
        }
        return .{ .order = order.items, .hidden = hidden.items };
    }

    /// What the draft's `profile-order` and `profile-hidden` become for the
    /// page's `state` (`moved`, `toggledHidden`, `state`): the values the
    /// draft started with (`original`), edited, never rewritten from the
    /// page's rows.
    /// - `profile-order`: the page's keys in its order. A value that names
    ///   none of them (a profile this computer does not list, or only ones
    ///   noctty hides itself) keeps its place after the value before it. An
    ///   alias that names several (`wsl`) stays as written, after the last
    ///   of them, so it orders only profiles found later.
    /// - `profile-hidden`: every value as written, but one that names a
    ///   profile the page now shows gives way to the keys of those it names
    ///   that stay hidden. Then the key of each profile the page hides that
    ///   no value names.
    /// - A value that names a user profile the draft removed goes, from both.
    /// From `a`.
    pub fn writtenLists(self: *const Model, a: Allocator, original: *const Config, draft: *const Config, page: Lists) Allocator.Error!Lists {
        // Lookups by key, so a long list costs a pass, not a pass per value.
        var order_at: std.StringHashMapUnmanaged(usize) = .empty;
        for (page.order, 0..) |key, at| try order_at.put(a, try keyId(a, key), at);
        var page_hidden: std.StringHashMapUnmanaged(void) = .empty;
        for (page.hidden) |key| try page_hidden.put(a, try keyId(a, key), {});
        const names_index: NameIndex = try .of(a, self.profiles);
        const profile_at = &names_index.by_key;
        // `profile-order`.
        var front: std.ArrayListUnmanaged([]const u8) = .empty;
        const after = try a.alloc(std.ArrayListUnmanaged([]const u8), page.order.len);
        @memset(after, .empty);
        var anchor: ?usize = null;
        for (original.@"profile-order".list.items) |raw| {
            const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (value.len == 0 or namesRemovedProfile(original, draft, value)) continue;
            const names = try self.namedKeys(a, &names_index, &self.maps.order, value);
            var last: ?usize = null;
            for (names) |key| {
                const at = order_at.get(try keyId(a, key)) orelse continue;
                if (last == null or at > last.?) last = at;
            }
            if (last) |at| {
                // One profile's own key or id: the page's key stands for it.
                if (names.len == 1 and self.plainName(value, names[0])) {
                    anchor = at;
                    continue;
                }
                try after[at].append(a, value);
                anchor = at;
                continue;
            }
            if (anchor) |at| try after[at].append(a, value) else try front.append(a, value);
        }
        var order: std.ArrayListUnmanaged([]const u8) = .empty;
        try order.appendSlice(a, front.items);
        for (page.order, after) |key, kept| {
            try order.append(a, key);
            try order.appendSlice(a, kept.items);
        }
        // `profile-hidden`, and the keys its values so far name.
        var hidden: std.ArrayListUnmanaged([]const u8) = .empty;
        var named: std.StringHashMapUnmanaged(void) = .empty;
        for (original.@"profile-hidden".list.items) |raw| {
            const value = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (value.len == 0 or namesRemovedProfile(original, draft, value)) continue;
            const names = try self.namedKeys(a, &names_index, &self.maps.hidden, value);
            const shows_one = for (names) |key| {
                const id = try keyId(a, key);
                const index = profile_at.get(id) orelse continue;
                if (self.profiles[index].found_hidden) continue;
                if (!page_hidden.contains(id)) break true;
            } else false;
            if (!shows_one) {
                try hidden.append(a, value);
                for (names) |key| try named.put(a, try keyId(a, key), {});
                continue;
            }
            for (names) |key| {
                const id = try keyId(a, key);
                const index = profile_at.get(id) orelse continue;
                const still = self.profiles[index].found_hidden or page_hidden.contains(id);
                if (!still or named.contains(id)) continue;
                try hidden.append(a, key);
                try named.put(a, id, {});
            }
        }
        for (page.hidden) |key| {
            const id = try keyId(a, key);
            if (named.contains(id)) continue;
            try hidden.append(a, key);
            try named.put(a, id, {});
        }
        return .{ .order = order.items, .hidden = hidden.items };
    }

    /// The keys of the page's profiles `value` (trimmed) names, in the
    /// page's order, as `refNames` reads it for each: by its own key, id or
    /// `user:` id, else as the app read it (`refs`). Looked up in `index`,
    /// the page's profiles by key and id, not by a pass over them.
    fn namedKeys(self: *const Model, a: Allocator, index: *const NameIndex, map: *const RefMap, value: []const u8) Allocator.Error![]const []const u8 {
        var found: std.ArrayListUnmanaged(usize) = .empty;
        if (index.by_key.get(try keyId(a, value))) |at| try found.append(a, at);
        if (index.by_id.get(try std.ascii.allocLowerString(a, value))) |at| try found.append(a, at);
        if (std.ascii.startsWithIgnoreCase(value, "user:")) {
            if (index.by_id.get(try std.ascii.allocLowerString(a, value["user:".len..]))) |at| try found.append(a, at);
        }
        if (map.get(value)) |ref| for (ref.keys) |named| {
            if (index.by_key.get(try keyId(a, named))) |at| try found.append(a, at);
        };
        std.mem.sort(usize, found.items, {}, std.sort.asc(usize));
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        for (found.items, 0..) |at, i| {
            if (i != 0 and found.items[i - 1] == at) continue;
            try keys.append(a, self.profiles[at].key);
        }
        return keys.items;
    }

    /// Whether `value` is the profile with `key` by its own key or id, not
    /// by an alias that could name others too.
    fn plainName(self: *const Model, value: []const u8, key: []const u8) bool {
        if (sameKey(value, key)) return true;
        const index = self.profileByKey(key) orelse return false;
        const profile = &self.profiles[index];
        return !profile.detected and namesProfile(value, profile.id);
    }

    /// Where profile `index` is in the page's order, counted from 1, and how
    /// many there are: "Python moved to 3 of 9".
    pub fn place(self: *const Model, index: u32) struct { at: usize, of: usize } {
        return .{ .at = index + 1, .of = self.profiles.len };
    }

    /// The profile whose key is `key` (without case, but an `ssh:` alias
    /// exactly, as OpenSSH takes it), if the page has it.
    pub fn profileByKey(self: *const Model, key: []const u8) ?u32 {
        for (self.profiles, 0..) |profile, index| {
            if (sameKey(profile.key, key)) return @intCast(index);
        }
        return null;
    }

    /// Where profile `index` may move by `step` (-1 up, +1 down), or null:
    /// only within the shown profiles or within the hidden ones, and never
    /// past a quick-slot profile, which the picker shows first whatever its
    /// place (`applyQuickSlotPreferenceOrder`), nor a quick-slot one itself;
    /// nor one noctty hides itself, which stays last (`found_hidden`). Not
    /// before the list is complete.
    pub fn moveTarget(self: *const Model, index: u32, step: i2) ?u32 {
        if (!self.complete) return null;
        const profile = &self.profiles[index];
        if (pinnedFirst(profile) or profile.found_hidden) return null;
        const next = @as(i64, index) + step;
        if (next < 0 or next >= self.profiles.len) return null;
        const other = &self.profiles[@intCast(next)];
        if (other.hidden != profile.hidden or pinnedFirst(other) or other.found_hidden) return null;
        return @intCast(next);
    }

    /// The pinned profile that stops profile `index` moving by `step`, if
    /// that is what stops it: the note names it.
    pub fn pinBlocking(self: *const Model, index: u32, step: i2) ?*const Profile {
        const next = @as(i64, index) + step;
        if (next < 0 or next >= self.profiles.len) return null;
        const other = &self.profiles[@intCast(next)];
        return if (pinnedFirst(other) and !self.profiles[index].hidden) other else null;
    }

    /// The keys of the page's profiles in its order with profile `index`
    /// moved to `target` (`moveTarget`), and the hidden ones: what the draft's
    /// `profile-order` and `profile-hidden` become. From `a`.
    pub fn moved(self: *const Model, a: Allocator, index: u32, target: u32) Allocator.Error!Lists {
        const places = try a.alloc(u32, self.profiles.len);
        for (places, 0..) |*place_of, at| place_of.* = @intCast(at);
        std.mem.swap(u32, &places[index], &places[target]);
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var hidden: std.ArrayListUnmanaged([]const u8) = .empty;
        for (places) |at| {
            const profile = &self.profiles[at];
            // One noctty hides itself is not the page's to write.
            if (profile.found_hidden) continue;
            try keys.append(a, profile.key);
            if (profile.hidden) try hidden.append(a, profile.key);
        }
        return .{ .order = keys.items, .hidden = hidden.items };
    }

    /// The lists with profile `index` hidden (`hide`) or shown: a profile
    /// hidden goes first among the hidden ones, and one shown last among the
    /// shown ones, or among the quick-slot ones in its slot's place, as the
    /// picker shows it then.
    pub fn toggledHidden(self: *const Model, a: Allocator, index: u32, hide: bool) Allocator.Error!Lists {
        var shown: std.ArrayListUnmanaged([]const u8) = .empty;
        var hidden: std.ArrayListUnmanaged([]const u8) = .empty;
        const profile = &self.profiles[index];
        if (hide) try hidden.append(a, profile.key);
        for (self.profiles, 0..) |other, at| {
            if (at == index or other.found_hidden) continue;
            try (if (other.hidden) &hidden else &shown).append(a, other.key);
        }
        if (!hide) {
            // Last among the shown, or in its quick slot's place among the
            // quick-slot ones the picker shows first.
            var at = shown.items.len;
            if (profile.quick_slot) |slot| {
                at = 0;
                for (self.profiles, 0..) |other, position| {
                    if (position == index or !pinnedFirst(&other)) continue;
                    if (other.quick_slot.? < slot) at += 1;
                }
            }
            try shown.insert(a, at, profile.key);
        }
        const order = try std.mem.concat(a, []const u8, &.{ shown.items, hidden.items });
        return .{ .order = order, .hidden = hidden.items };
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
                if (profile.detected) try writer.writeAll(profile.key) else try writer.print("user:{s}", .{profile.id});
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
            .profile => if (self.profiles[row.profile].detected) "Found by noctty on this computer." else self.profiles[row.profile].command,
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
        if (profile.detected) {
            try writer.print("Profile {s}, which noctty found on this computer: its command line, name and folder are noctty's, so Settings does not change them. ", .{profile.key});
            return writeOrderHelp(profile, writer);
        }
        if (profile.read_only and row.kind != .profile) return writer.print(
            "Profile user:{s} comes from noctty's command line, so Settings does not change it: a change saved to the config file would not be used while that command line names it.",
            .{profile.id},
        );
        switch (row.kind) {
            .new_profile => unreachable,
            .profile => {
                if (profile.read_only)
                    try writer.print("Profile user:{s} comes from noctty's command line, so Settings does not change its fields. ", .{profile.id})
                else {
                    try writer.print("Profile user:{s}. Its id cannot be changed: sessions, layouts and the taskbar's jump list name the profile by it. Enter edits its command line; Delete removes the profile.", .{profile.id});
                    if (profile.default) try writer.writeAll(" Default profile names it: once it is removed, new tabs open the automatic shell.");
                    try writer.writeAll(" ");
                }
                try writeOrderHelp(profile, writer);
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
                if (profile.detected)
                    try writer.print("{s}, profile {s}", .{ profile.label orelse profile.id, profile.key })
                else
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
            .profile => {
                const profile = &self.profiles[row.profile];
                try writer.writeAll(if (profile.detected) profile.key else profile.command);
            },
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

/// What a move or a hide makes the draft's two lists (`Model.moved`,
/// `Model.toggledHidden`).
pub const Lists = struct {
    order: []const []const u8,
    hidden: []const []const u8,

    pub fn eql(self: Lists, other: Lists) bool {
        return keysEql(self.order, other.order) and keysEql(self.hidden, other.hidden);
    }

    fn keysEql(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        return true;
    }
};

/// The page's state for `entries` (`pageEntries` of `config`), as
/// `Model.state` gives it: every profile's key in page order and the hidden
/// ones', none that noctty hides itself.
fn stateOf(a: Allocator, config: *const Config, entries: []const PageEntry) Allocator.Error!Lists {
    const commands = config.@"profile-command".entries.items;
    var order: std.ArrayListUnmanaged([]const u8) = .empty;
    var hidden: std.ArrayListUnmanaged([]const u8) = .empty;
    for (entries) |entry| {
        if (entry.listed) |item| if (item.found_hidden) continue;
        // Copies: the app's list goes once the page is built.
        const key = if (entry.user) |index| try std.fmt.allocPrint(a, "user:{s}", .{commands[index].id}) else try a.dupe(u8, entry.listed.?.key);
        try order.append(a, key);
        if (entry.hidden) try hidden.append(a, key);
    }
    return .{ .order = order.items, .hidden = hidden.items };
}

/// Whether the picker shows `profile` first, pinned by a quick slot: a shown
/// one (a hidden one is not in the picker to pin).
fn pinnedFirst(profile: *const Profile) bool {
    return profile.quick_slot != null and !profile.hidden;
}

/// One profile in page order (`pageEntries`): the app's list item, if the
/// app lists it, and the draft's `profile-command` entry, for a user profile.
const PageEntry = struct {
    listed: ?*const Listed = null,
    user: ?usize = null,
    hidden: bool,
    rank: usize = std.math.maxInt(usize),

    fn foundHidden(self: PageEntry) bool {
        return if (self.listed) |item| item.found_hidden else false;
    }

    /// Shown or hidden: the picker shows the shown ones first, then the
    /// hidden ones, each in their order (`arrangeProfiles`' partition), those
    /// noctty hides itself among them.
    fn group(self: PageEntry) u1 {
        return @intFromBool(self.hidden or self.foundHidden());
    }

    /// A shown profile's quick slot, which pulls it to the front.
    fn slot(self: PageEntry) u8 {
        if (self.hidden) return std.math.maxInt(u8);
        const item = self.listed orelse return std.math.maxInt(u8);
        return item.quick_slot orelse std.math.maxInt(u8);
    }
};

/// The profiles of the page in its order (`Model.buildListed`).
fn pageEntries(a: Allocator, draft: *const Config, original: ?*const Config, listed: []const Listed, maps: *const RefMaps) Allocator.Error![]PageEntry {
    var entries: std.ArrayListUnmanaged(PageEntry) = .empty;
    const commands = draft.@"profile-command".entries.items;
    if (listed.len == 0) {
        // No list: the user profiles in definition order, as before.
        for (commands, 0..) |entry, index| {
            if (entry.removed) continue;
            try entries.append(a, .{ .user = index, .hidden = hiddenIn(draft, entry.id) });
        }
        return entries.items;
    }
    const placed = try a.alloc(bool, commands.len);
    @memset(placed, false);
    for (listed) |*item| {
        if (userId(item.key)) |id| {
            const index = for (commands, 0..) |entry, at| {
                if (!entry.removed and std.ascii.eqlIgnoreCase(entry.id, id)) break at;
            } else continue;
            placed[index] = true;
            try entries.append(a, .{ .listed = item, .user = index, .hidden = item.hidden });
            continue;
        }
        try entries.append(a, .{ .listed = item, .hidden = item.hidden });
    }
    // The draft's new profiles, after the last shown user profile (where the
    // picker lists a profile no `profile-order` names), else before the
    // first hidden one.
    for (commands, 0..) |entry, index| {
        if (entry.removed or placed[index]) continue;
        var after_user: ?usize = null;
        for (entries.items, 0..) |other, position| {
            if (other.hidden) break;
            if (other.user != null) after_user = position + 1;
        }
        const at = after_user orelse for (entries.items, 0..) |other, position| {
            if (other.hidden) break position;
        } else entries.items.len;
        try entries.insert(a, at, .{ .user = index, .hidden = hiddenIn(draft, entry.id) });
    }
    // A draft list of its own (the page moved or hid one) decides, as the
    // loader will once it is saved: it names every profile by its key. A
    // list the page left as it was keeps the app's answer, which reads the
    // file's aliases (`wsl`, `pwsh`) as the page cannot.
    const order_edited = if (original) |was| !was.@"profile-order".equal(draft.@"profile-order") else false;
    const hidden_edited = if (original) |was| !was.@"profile-hidden".equal(draft.@"profile-hidden") else false;
    for (entries.items, 0..) |*entry, position| {
        const key = entryKey(commands, entry.*);
        const id = if (entry.user) |index| commands[index].id else null;
        entry.rank = if (order_edited) for (draft.@"profile-order".list.items, 0..) |value, at| {
            if (refNames(&maps.order, value, key, id)) break at;
        } else std.math.maxInt(usize) else position;
        if (hidden_edited) entry.hidden = entry.foundHidden() or for (draft.@"profile-hidden".list.items) |value| {
            if (refNames(&maps.hidden, value, key, id)) break true;
        } else false;
    }
    // The picker's order: the shown profiles, the quick-slot ones first in
    // slot order, as the picker pulls them (`applyQuickSlotPreferenceOrder`);
    // then the hidden ones, those noctty hides itself last. A new profile
    // placed among the pinned ones goes after them.
    std.sort.insertion(PageEntry, entries.items, {}, struct {
        fn lessThan(_: void, x: PageEntry, y: PageEntry) bool {
            if (x.group() != y.group()) return x.group() < y.group();
            if (x.slot() != y.slot()) return x.slot() < y.slot();
            return x.rank < y.rank;
        }
    }.lessThan);
    return entries.items;
}

/// The page's profiles by what a list value names one by itself, for
/// `Model.namedKeys`: its key as `sameKey` compares it (`keyId`), and a user
/// profile's id in lower case (`namesProfile`). Profile ids are unique
/// without case, as the config keeps them. From `a`.
const NameIndex = struct {
    by_key: std.StringHashMapUnmanaged(usize) = .empty,
    by_id: std.StringHashMapUnmanaged(usize) = .empty,

    fn of(a: Allocator, profiles: []const Profile) Allocator.Error!NameIndex {
        var index: NameIndex = .{};
        for (profiles, 0..) |profile, at| {
            const key = try index.by_key.getOrPut(a, try keyId(a, profile.key));
            if (!key.found_existing) key.value_ptr.* = at;
            if (profile.detected) continue;
            const id = try index.by_id.getOrPut(a, try std.ascii.allocLowerString(a, profile.id));
            if (!id.found_existing) id.value_ptr.* = at;
        }
        return index;
    }
};

/// Whether `value` names the profile with `key` (and user `id`): by its own
/// key or id (`namesKey`) first, which also finds a profile the draft added
/// since the app read the value; else as the app read it (`refs`), which is
/// how an alias names its profiles.
fn refNames(map: *const RefMap, value_raw: []const u8, key: []const u8, id: ?[]const u8) bool {
    const value = std.mem.trim(u8, value_raw, &std.ascii.whitespace);
    if (namesKey(value, key, id)) return true;
    const ref = map.get(value) orelse return false;
    for (ref.keys) |named| {
        if (sameKey(named, key)) return true;
    }
    return false;
}

/// `key` as `sameKey` compares it: an `ssh:` key's alias as written after a
/// lower-case prefix, any other key in lower case. From `a`.
fn keyId(a: Allocator, key: []const u8) Allocator.Error![]const u8 {
    const out = try a.dupe(u8, key);
    const lower_to = if (std.ascii.startsWithIgnoreCase(key, "ssh:")) "ssh:".len else out.len;
    for (out[0..lower_to]) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// `refs` copied into `a`.
fn copyReferences(a: Allocator, refs: []const Reference) Allocator.Error![]const Reference {
    const out = try a.alloc(Reference, refs.len);
    for (refs, out) |ref, *copy| {
        const keys = try a.alloc([]const u8, ref.keys.len);
        for (ref.keys, keys) |key, *dup| dup.* = try a.dupe(u8, key);
        copy.* = .{ .value = try a.dupe(u8, ref.value), .keys = keys };
    }
    return out;
}

/// Whether `value` names a user profile `original` has and `draft` removed:
/// the value goes with it.
fn namesRemovedProfile(original: *const Config, draft: *const Config, value: []const u8) bool {
    for (original.@"profile-command".entries.items) |entry| {
        if (entry.removed or draft.@"profile-command".get(entry.id) != null) continue;
        if (namesProfile(value, entry.id)) return true;
    }
    return false;
}

/// The picker's key of `entry`: the app's, or `user:<id>` for a new one.
fn entryKey(commands: anytype, entry: PageEntry) []const u8 {
    if (entry.listed) |item| return item.key;
    return commands[entry.user.?].id;
}

/// A user profile key's id (`user:<id>`), or null for any other key.
fn userId(key: []const u8) ?[]const u8 {
    if (key.len <= "user:".len or !std.ascii.startsWithIgnoreCase(key, "user:")) return null;
    return key["user:".len..];
}

/// Whether `a` and `b` are one profile's key: without case, but an `ssh:`
/// key's alias exactly, as OpenSSH aliases are case-sensitive (the prefix in
/// any case, as `windows_shell.referenceNames` takes it).
fn sameKey(a: []const u8, b: []const u8) bool {
    const prefix = "ssh:";
    if (std.ascii.startsWithIgnoreCase(a, prefix) or std.ascii.startsWithIgnoreCase(b, prefix)) {
        return a.len == b.len and std.ascii.startsWithIgnoreCase(a, prefix) and std.ascii.startsWithIgnoreCase(b, prefix) and
            std.mem.eql(u8, a[prefix.len..], b[prefix.len..]);
    }
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Whether a `profile-order` or `profile-hidden` value names the profile
/// with `key` (for a user profile, `id` too: its bare id or `user:<id>`),
/// without case, but an `ssh:` alias exactly.
fn namesKey(value: []const u8, key: []const u8, id: ?[]const u8) bool {
    const text = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (sameKey(text, key)) return true;
    return if (id) |user| namesProfile(text, user) else false;
}

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
    var slot_buf: [16]u8 = undefined;
    const slot_text: []const u8 = if (profile.quick_slot) |slot| std.fmt.bufPrint(&slot_buf, "quick slot {d}", .{slot}) catch "quick slot" else "";
    const marks = [_]struct { on: bool, text: []const u8 }{
        .{ .on = profile.default, .text = "default profile" },
        .{ .on = profile.hidden, .text = if (profile.found_hidden) "hidden by noctty" else "hidden" },
        .{ .on = profile.quick_slot != null and !profile.hidden, .text = slot_text },
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

/// The open row's words on a profile's place and visibility: what moves
/// it and hides it, and what is true of it there.
fn writeOrderHelp(profile: *const Profile, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (profile.found_hidden) {
        try writer.writeAll(found_hidden_help);
        if (profile.default) try writer.writeAll(" Default profile names it, so new tabs still start it.");
        return;
    }
    if (profile.quick_slot != null and !profile.hidden)
        try writer.writeAll("A quick slot pins it, so the picker shows it first, and it does not move here. ")
    else
        try writer.writeAll("Alt+Up and Alt+Down move it in the picker's order. ");
    try writer.writeAll(if (profile.hidden)
        "It is hidden: the picker, the palette and the jump list leave it out. Ctrl+H shows it."
    else
        "Ctrl+H hides it from the picker, the palette and the jump list.");
    if (profile.hidden and profile.default) try writer.writeAll(" Default profile names it, so new tabs still start it.");
}

/// Why a profile noctty hides itself stays hidden.
pub const found_hidden_help = "noctty hides it: with visual-studio-profiles = newest it lists only the newest Visual Studio. Set visual-studio-profiles = all to list the others.";

/// What UIA knows a row by: its kind, its profile's id and its variable's
/// name, without case, which is how the loader tells them apart; an `ssh:`
/// alias with its case, as OpenSSH tells them apart.
pub fn identity(kind: RowKind, id: []const u8, name: ?[]const u8) u64 {
    var hasher: std.hash.Wyhash = .init(0);
    hasher.update(&.{@intFromEnum(kind)});
    const exact_from: usize = if (std.ascii.startsWithIgnoreCase(id, "ssh:")) "ssh:".len else id.len;
    for (id[0..exact_from]) |c| hasher.update(&.{std.ascii.toLower(c)});
    hasher.update(id[exact_from..]);
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
/// or removed counts as its command), a label, a starting folder, each
/// variable, and the order and the hidden profiles, one each. What the close
/// prompt and the Advanced page count.
pub fn changedFieldCount(original: *const Config, draft: *const Config) usize {
    var count = profileFieldChanges(original, draft);
    if (!original.@"profile-order".equal(draft.@"profile-order")) count += 1;
    if (!original.@"profile-hidden".equal(draft.@"profile-hidden")) count += 1;
    return count;
}

/// `changedFieldCount` for the profiles' own fields: not the order or the
/// hidden profiles.
fn profileFieldChanges(original: *const Config, draft: *const Config) usize {
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

/// The draft's baseline for each group of profile keys, which a save checks
/// another program's change against (`settings_patch.Baselines`).
pub const Baselines = settings_patch.Baselines;

/// The config file changed while Settings was open (`replacement` is what it
/// says now): when the draft changed no profile, `original` and `draft` take
/// the file's profiles, as an unedited setting takes the file's value. A
/// draft that changed one keeps every profile as it was, and a save writes
/// only what the page changed (`settings_patch.profileEdits`). The order and
/// the hidden profiles follow the file the same way, each on its own: one
/// the draft changed stays as the draft has it (a save checks it against
/// the file, `settings_patch.changedUnder`).
///
/// A group that follows the file takes a new record in `baselines`, whole:
/// the values `original` now holds, where `replacement` read each line, and
/// the light/dark state `replacement` was read in. A group that does not
/// keeps its record as it was, every part of it. The save's check reads
/// only these records, so a group's values cannot move on without its
/// lines and state. Where each line was read (`_launch.profile_places`) also
/// goes with what it wrote in both configs: the page reads the draft's.
/// Everything is made before anything is put in place.
pub fn followFile(original: *Config, draft: *Config, replacement: *const Config, baselines: *Baselines) Allocator.Error!void {
    const follow_profiles = profileFieldChanges(original, draft) == 0;
    const follow_order = original.@"profile-order".equal(draft.@"profile-order");
    const follow_hidden = original.@"profile-hidden".equal(draft.@"profile-hidden");
    const follows: Follows = .{ .profiles = follow_profiles, .order = follow_order, .hidden = follow_hidden };
    const Next = struct {
        fresh: []const pane_launch.ProfilePlace,
        places: @FieldType(pane_launch.Ledger, "profile_places"),
        hidden: @FieldType(Config, "profile-hidden"),
        order: @FieldType(Config, "profile-order"),
        profiles: ?settings_patch.ProfileValues,
    };
    var next: [2]Next = undefined;
    for ([_]*Config{ original, draft }, &next) |config, *made| {
        const a = arenaOf(config);
        const fresh = (try replacement._launch.clone(a)).profile_places;
        var places: @TypeOf(config._launch.profile_places) = .empty;
        for (config._launch.profile_places.items) |place| {
            if (!follows.of(place.key)) try places.append(a, place);
        }
        for (fresh.items) |place| {
            if (follows.of(place.key)) try places.append(a, place);
        }
        made.* = .{
            .fresh = fresh.items,
            .places = places,
            .hidden = if (follow_hidden) try replacement.@"profile-hidden".clone(a) else config.@"profile-hidden",
            .order = if (follow_order) try replacement.@"profile-order".clone(a) else config.@"profile-order",
            .profiles = if (follow_profiles) .{
                .command = try replacement.@"profile-command".clone(a),
                .name = try replacement.@"profile-name".clone(a),
                .folder = try replacement.@"profile-working-directory".clone(a),
                .env = try replacement.@"profile-env".clone(a),
            } else null,
        };
    }
    // Put in place: nothing from here on can fail.
    for ([_]*Config{ original, draft }, next) |config, made| {
        if (made.profiles) |values| {
            config.@"profile-command" = values.command;
            config.@"profile-name" = values.name;
            config.@"profile-working-directory" = values.folder;
            config.@"profile-env" = values.env;
        }
        config.@"profile-hidden" = made.hidden;
        config.@"profile-order" = made.order;
        config._launch.profile_places = made.places;
    }
    const state = replacement._conditional_state;
    const fresh = next[0].fresh;
    if (follow_profiles) baselines.profiles = .{ .values = .of(original), .places = fresh, .state = state };
    if (follow_order) baselines.order = .{ .values = original.@"profile-order".list.items, .places = fresh, .state = state };
    if (follow_hidden) baselines.hidden = .{ .values = original.@"profile-hidden".list.items, .places = fresh, .state = state };
}

/// Which of a config's profile keys follow the file (`followFile`).
const Follows = struct {
    profiles: bool,
    order: bool,
    hidden: bool,

    /// Whether the lines read for `key` follow the file.
    fn of(self: Follows, key: []const u8) bool {
        if (std.mem.eql(u8, key, "profile-order")) return self.order;
        if (std.mem.eql(u8, key, "profile-hidden")) return self.hidden;
        return self.profiles;
    }
};

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
/// Make `draft`'s `profile-order` exactly `keys`, in that order: what the
/// page's order is written as (`settings_patch` writes it whole).
pub fn setOrder(draft: *Config, keys: []const []const u8) Allocator.Error!void {
    try setList(draft, &draft.@"profile-order", keys);
}

/// Make `draft`'s `profile-hidden` exactly `keys`.
pub fn setHidden(draft: *Config, keys: []const []const u8) Allocator.Error!void {
    try setList(draft, &draft.@"profile-hidden", keys);
}

/// Make `draft`'s `profile-order` `order` and its `profile-hidden` `hidden`,
/// both or neither: each is made whole before either is put in place, so one
/// that runs out of memory leaves the draft as it was. Slices of any string.
pub fn setLists(draft: *Config, order: anytype, hidden: anytype) Allocator.Error!void {
    const a = arenaOf(draft);
    var next_order: Config.RepeatableString = .{};
    for (order) |key| try next_order.list.append(a, try a.dupeZ(u8, key));
    var next_hidden: Config.RepeatableString = .{};
    for (hidden) |key| try next_hidden.list.append(a, try a.dupeZ(u8, key));
    draft.@"profile-order" = next_order;
    draft.@"profile-hidden" = next_hidden;
}

fn setList(draft: *Config, list: *Config.RepeatableString, keys: []const []const u8) Allocator.Error!void {
    const a = arenaOf(draft);
    var next: Config.RepeatableString = .{};
    for (keys) |key| try next.list.append(a, try a.dupeZ(u8, key));
    list.* = next;
}

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
/// fields stay in the draft, dormant, and a list the page wrote no longer
/// names it. One the draft brought in (`original`
/// has no profile `id`, or only its tombstone) goes back to what `original`
/// had for it, every field, as if it had never been added.
pub fn removeProfile(original: *const Config, draft: *Config, id: []const u8) (Allocator.Error || profile_map.Error)!void {
    try removeProfileEntries(original, draft, id);
    // A list the page wrote names it: it leaves the list, or the saved list
    // would name a profile that is gone. In place, after the removal, which
    // may run out of memory: this allocates nothing, so the two go together.
    for ([_]struct { was: *const Config.RepeatableString, now: *Config.RepeatableString }{
        .{ .was = &original.@"profile-order", .now = &draft.@"profile-order" },
        .{ .was = &original.@"profile-hidden", .now = &draft.@"profile-hidden" },
    }) |pair| {
        if (pair.was.equal(pair.now.*)) continue;
        var kept: usize = 0;
        for (pair.now.list.items) |value| {
            if (namesProfile(std.mem.trim(u8, value, &std.ascii.whitespace), id)) continue;
            pair.now.list.items[kept] = value;
            kept += 1;
        }
        pair.now.list.shrinkRetainingCapacity(kept);
    }
}

fn removeProfileEntries(original: *const Config, draft: *Config, id: []const u8) (Allocator.Error || profile_map.Error)!void {
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

/// The keys of `model`'s profiles in page order, one per line, each with
/// " (hidden)" when it is.
fn testKeysText(alloc: Allocator, model: *const Model) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (model.profiles) |profile| try out.writer.print("{s}{s}\n", .{ profile.key, if (profile.hidden) " (hidden)" else "" });
    return out.toOwnedSlice();
}

fn testApply(draft: *Config, lists: Lists) !void {
    try setOrder(draft, lists.order);
    try setHidden(draft, lists.hidden);
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

test "settings profiles: with the app's list, every profile in the picker's order, the hidden ones last" {
    const alloc = testing.allocator;
    var draft = try testConfig(alloc, "profile-command = py: python.exe\nprofile-command = node: node.exe\n", &.{});
    defer draft.deinit();
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "ssh:prod", .label = "prod" },
        .{ .key = "cmd.exe", .label = "Command Prompt", .hidden = true },
    };
    var model: Model = .{};
    defer model.deinit();
    try model.buildListed(alloc, &draft, &draft, &listed, true);
    try testing.expect(model.complete);
    // `node`, which the app does not list yet, goes after the last shown
    // user profile.
    const keys = try testKeysText(alloc, &model);
    defer alloc.free(keys);
    try expectSameText("pwsh.exe\nuser:py\nuser:node\nssh:prod\ncmd.exe (hidden)\n", keys);
    // A profile noctty found is one row; a user profile keeps its fields.
    const text = try testRowsText(alloc, &model);
    defer alloc.free(text);
    try expectSameText(
        \\new_profile New profile =
        \\profile PowerShell = pwsh.exe
        \\profile py = user:py
        \\command Command line = python.exe
        \\name Name =
        \\folder Starting folder =
        \\add_variable Add variable =
        \\profile node = user:node
        \\command Command line = node.exe
        \\name Name =
        \\folder Starting folder =
        \\add_variable Add variable =
        \\profile prod = ssh:prod
        \\profile Command Prompt = cmd.exe (hidden)
        \\
    , text);
    // Without the whole list, nothing moves or hides.
    try model.buildListed(alloc, &draft, &draft, &listed, false);
    try testing.expect(model.moveTarget(1, -1) == null);
}

test "settings profiles: a move or a hide gives the draft both lists whole, and the page follows them" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-command = node: node.exe\nprofile-hidden = cmd.exe\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "user:node", .label = "node" },
        .{ .key = "cmd.exe", .label = "Command Prompt", .hidden = true },
    };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try model.buildListed(alloc, &draft, &original, &listed, true);
    // The first goes no higher, and a shown one does not cross into the
    // hidden ones.
    try testing.expect(model.moveTarget(0, -1) == null);
    try testing.expect(model.moveTarget(2, 1) == null);
    try testing.expect(model.moveTarget(3, -1) == null);
    // py up, above PowerShell.
    try testing.expectEqual(@as(?u32, 0), model.moveTarget(1, -1));
    try testApply(&draft, try model.moved(a, 1, 0));
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe\nuser:node\ncmd.exe (hidden)\n", keys);
    }
    // Both lists name every profile, in that order.
    try testing.expectEqual(@as(usize, 4), draft.@"profile-order".list.items.len);
    try expectSameText("user:py", draft.@"profile-order".list.items[0]);
    try testing.expectEqual(@as(usize, 1), draft.@"profile-hidden".list.items.len);
    try expectSameText("cmd.exe", draft.@"profile-hidden".list.items[0]);
    // PowerShell hidden: first among the hidden ones.
    try testApply(&draft, try model.toggledHidden(a, 1, true));
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\nuser:node\npwsh.exe (hidden)\ncmd.exe (hidden)\n", keys);
    }
    // Command Prompt shown: last among the shown ones.
    try testApply(&draft, try model.toggledHidden(a, 3, false));
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\nuser:node\ncmd.exe\npwsh.exe (hidden)\n", keys);
    }
    // The draft counts its two lists as two changes, and its profiles as
    // none.
    try testing.expectEqual(@as(usize, 2), changedFieldCount(&original, &draft));
}

test "settings profiles: a quick slot's profile stays first, does not move, and goes back first when shown" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    const listed = [_]Listed{
        .{ .key = "user:py", .label = "py", .quick_slot = 1 },
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "cmd.exe", .label = "Command Prompt" },
    };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try model.buildListed(alloc, &draft, &original, &listed, true);
    try testing.expect(model.moveTarget(0, 1) == null);
    try testing.expect(model.moveTarget(1, -1) == null);
    try testing.expectEqual(@as(?u32, 2), model.moveTarget(1, 1));
    // Hidden, it is in the picker no more, and no slot pins it.
    try testApply(&draft, try model.toggledHidden(a, 0, true));
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("pwsh.exe\ncmd.exe\nuser:py (hidden)\n", keys);
    }
    // Shown again, its slot puts it first.
    try testApply(&draft, try model.toggledHidden(a, 2, false));
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe\ncmd.exe\n", keys);
    }
}

test "settings profiles: the pinned profiles stay first whatever the draft's order, and a new profile goes after them" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    try setCommand(&draft, "dev", "dev.exe");
    const listed = [_]Listed{
        .{ .key = "user:py", .label = "py", .quick_slot = 1 },
        .{ .key = "pwsh.exe", .label = "PowerShell", .quick_slot = 2 },
        .{ .key = "cmd.exe", .label = "Command Prompt" },
    };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The new profile goes after py, its user profile, but not between the
    // two the picker pulls first.
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe\nuser:dev\ncmd.exe\n", keys);
    }
    // It does not move above them, and PowerShell is what stops it.
    try testing.expect(model.moveTarget(2, -1) == null);
    try expectSameText("pwsh.exe", (model.pinBlocking(2, -1) orelse return error.TestExpectedPin).key);
    try testing.expect(model.pinBlocking(3, -1) == null);
    // Command Prompt moves above it.
    try testApply(&draft, try model.moved(a, 3, 2));
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe\ncmd.exe\nuser:dev\n", keys);
    }
    // A draft order that names the pinned ones last still shows them first,
    // as the picker does.
    try setOrder(&draft, &.{ "cmd.exe", "user:dev", "pwsh.exe", "user:py" });
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe\ncmd.exe\nuser:dev\n", keys);
    }
}

test "settings profiles: a profile noctty hides itself keeps the app's place among the hidden ones, and its explicit name" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-hidden = cmd.exe\nprofile-hidden = vs:old:cmd\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    // As the app arranges them: the hidden ones after the shown ones, in
    // its order, the one noctty hides among them.
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "vs:old:cmd", .label = "Developer Command Prompt (2019)", .hidden = true, .found_hidden = true },
        .{ .key = "cmd.exe", .label = "Command Prompt", .hidden = true },
    };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("pwsh.exe\nuser:py\nvs:old:cmd (hidden)\ncmd.exe (hidden)\n", keys);
    }
    // It does not move, nor does anything move past it.
    try testing.expect(model.moveTarget(2, 1) == null);
    try testing.expect(model.moveTarget(3, -1) == null);
    // A move writes every other profile in order, and keeps the explicit
    // name the file gives it, which `profile-hidden = vs:old:cmd` is, in
    // its place: switching to `visual-studio-profiles = all` keeps it hidden.
    const lists = try model.writtenLists(a, &original, &draft, try model.moved(a, 1, 0));
    {
        const order = try testJoin(alloc, lists.order);
        defer alloc.free(order);
        try expectSameText("user:py\npwsh.exe\ncmd.exe\n", order);
        const hidden = try testJoin(alloc, lists.hidden);
        defer alloc.free(hidden);
        try expectSameText("cmd.exe\nvs:old:cmd\n", hidden);
    }
    try setLists(&draft, lists.order, lists.hidden);
    try model.buildListed(alloc, &draft, &original, &listed, true);
    {
        // As the app arranges the saved lists: the named hidden one, then
        // the one only discovery hides, which `profile-order` does not name.
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe\ncmd.exe (hidden)\nvs:old:cmd (hidden)\n", keys);
    }
    try testing.expect(model.profiles[3].found_hidden);
    // Command Prompt shown: it leaves the hidden list, the explicit name stays.
    const shown = try model.writtenLists(a, &original, &draft, try model.toggledHidden(a, 2, false));
    const hidden = try testJoin(alloc, shown.hidden);
    defer alloc.free(hidden);
    try expectSameText("vs:old:cmd\n", hidden);
}

/// `values`, one a line.
fn testJoin(alloc: Allocator, values: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (values) |value| try out.writer.print("{s}\n", .{value});
    return out.toOwnedSlice();
}

test "settings profiles: a move that comes back is the start again, and a removed profile leaves the lists" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-command = node: node.exe\nprofile-hidden = cmd.exe\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "user:node", .label = "node" },
        .{ .key = "cmd.exe", .label = "Command Prompt", .hidden = true },
    };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try model.buildListed(alloc, &draft, &original, &listed, true);
    // py up, then down again: the lists are the start's.
    const up = try model.moved(a, 1, 0);
    try testing.expect(!up.eql(model.base.?));
    try testApply(&draft, up);
    try model.buildListed(alloc, &draft, &original, &listed, true);
    try testing.expect((try model.moved(a, 0, 1)).eql(model.base.?));
    // node removed after the move: neither list names it any more.
    try removeProfile(&original, &draft, "node");
    for (draft.@"profile-order".list.items) |value| try testing.expect(!std.mem.eql(u8, value, "user:node"));
    try testing.expectEqual(@as(usize, 3), draft.@"profile-order".list.items.len);
    try testing.expectEqual(@as(usize, 1), draft.@"profile-hidden".list.items.len);
    // A list the page left as the file has it is not touched.
    var untouched = try original.clone(alloc);
    defer untouched.deinit();
    try removeProfile(&original, &untouched, "node");
    try testing.expect(original.@"profile-hidden".equal(untouched.@"profile-hidden"));
}

test "settings profiles: a written list keeps the names this computer does not list, in their place" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-order = pwsh.exe\nprofile-order = ssh:elsewhere\nprofile-order = user:py\nprofile-hidden = wsl:Gone\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "cmd.exe", .label = "Command Prompt" },
    };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try model.buildListed(alloc, &draft, &original, &listed, true);
    // py up: `ssh:elsewhere` (a host another computer has) stays after
    // PowerShell, the name before it; `wsl:Gone` stays hidden.
    const lists = try model.writtenLists(a, &original, &draft, try model.moved(a, 1, 0));
    const order = try testJoin(alloc, lists.order);
    defer alloc.free(order);
    try expectSameText("user:py\npwsh.exe\nssh:elsewhere\ncmd.exe\n", order);
    const hidden = try testJoin(alloc, lists.hidden);
    defer alloc.free(hidden);
    try expectSameText("wsl:Gone\n", hidden);
    // Command Prompt hidden: after the names the file had.
    const hid = try model.writtenLists(a, &original, &draft, try model.toggledHidden(a, 2, true));
    const more = try testJoin(alloc, hid.hidden);
    defer alloc.free(more);
    try expectSameText("wsl:Gone\ncmd.exe\n", more);
}

test "settings profiles: an alias stays as written, is read as the app reads it, and gives way only to a profile shown" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-order = wsl\nprofile-hidden = wsl\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "wsl:Ubuntu", .label = "Ubuntu", .hidden = true },
        .{ .key = "wsl:Debian", .label = "Debian", .hidden = true },
    };
    // `wsl` names both distributions, as the app reads it.
    const distros = [_][]const u8{ "wsl:Ubuntu", "wsl:Debian" };
    const refs: References = .{
        .order = &.{.{ .value = "wsl", .keys = &distros }},
        .hidden = &.{.{ .value = "wsl", .keys = &distros }},
    };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try model.buildReferenced(alloc, &draft, &original, &listed, refs, true);
    // py up: `wsl` is kept, after the last distribution in the order (so it
    // orders only distributions installed later), and as the hidden list.
    const lists = try model.writtenLists(a, &original, &draft, try model.moved(a, 1, 0));
    {
        const order = try testJoin(alloc, lists.order);
        defer alloc.free(order);
        try expectSameText("user:py\npwsh.exe\nwsl:Ubuntu\nwsl:Debian\nwsl\n", order);
        const hidden = try testJoin(alloc, lists.hidden);
        defer alloc.free(hidden);
        try expectSameText("wsl\n", hidden);
    }
    // The page reads the kept alias: both distributions stay hidden.
    try setLists(&draft, lists.order, lists.hidden);
    try model.buildReferenced(alloc, &draft, &original, &listed, refs, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe\nwsl:Ubuntu (hidden)\nwsl:Debian (hidden)\n", keys);
    }
    // PowerShell hidden too: the hidden list is the draft's own now, `wsl`
    // and PowerShell's key, and the page reads `wsl` as the app does.
    const more = try model.writtenLists(a, &original, &draft, try model.toggledHidden(a, 1, true));
    {
        const hidden = try testJoin(alloc, more.hidden);
        defer alloc.free(hidden);
        try expectSameText("wsl\npwsh.exe\n", hidden);
    }
    try setLists(&draft, more.order, more.hidden);
    try model.buildReferenced(alloc, &draft, &original, &listed, refs, true);
    {
        const keys = try testKeysText(alloc, &model);
        defer alloc.free(keys);
        try expectSameText("user:py\npwsh.exe (hidden)\nwsl:Ubuntu (hidden)\nwsl:Debian (hidden)\n", keys);
    }
    // Ubuntu shown: `wsl` would hide it again, so it gives way to the one it
    // still hides.
    const ubuntu = model.profileByKey("wsl:Ubuntu") orelse return error.TestExpectedProfile;
    const shown = try model.writtenLists(a, &original, &draft, try model.toggledHidden(a, ubuntu, false));
    const hidden = try testJoin(alloc, shown.hidden);
    defer alloc.free(hidden);
    try expectSameText("wsl:Debian\npwsh.exe\n", hidden);
}

test "settings profiles: a profile the draft adds that a saved name hides is hidden on the page, in the saved list, and in the app's picker" {
    const alloc = testing.allocator;
    // `profile-hidden = user:dev` names no profile yet: the app read it as
    // naming none.
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-hidden = user:dev\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "cmd.exe", .label = "Command Prompt" },
    };
    const refs: References = .{ .hidden = &.{.{ .value = "user:dev", .keys = &.{} }} };
    var model: Model = .{};
    defer model.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The draft adds `dev`: the saved name hides it.
    try setCommand(&draft, "dev", "dev.exe");
    try model.buildReferenced(alloc, &draft, &original, &listed, refs, true);
    try testing.expect(model.profiles[model.profileByKey("user:dev").?].hidden);
    // Command Prompt hidden: the draft's lists are the page's now, and the
    // page still reads `user:dev` as hiding `dev`.
    const lists = try model.writtenLists(a, &original, &draft, try model.toggledHidden(a, model.profileByKey("cmd.exe").?, true));
    {
        const hidden = try testJoin(alloc, lists.hidden);
        defer alloc.free(hidden);
        try expectSameText("user:dev\ncmd.exe\n", hidden);
    }
    try setLists(&draft, lists.order, lists.hidden);
    try model.buildReferenced(alloc, &draft, &original, &listed, refs, true);
    // The page, the saved lists and the app's picker after the reload agree
    // on every profile.
    var profiles = [_]windows_shell.Profile{
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{} } },
        .{ .kind = .user, .key = "user:py", .label = "py", .command = .{ .direct = &.{} } },
        .{ .kind = .user, .key = "user:dev", .label = "dev", .command = .{ .direct = &.{} } },
        .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{} } },
    };
    windows_shell.arrangeProfiles(&profiles, lists.order, lists.hidden);
    for (profiles) |profile| {
        const page = model.profiles[model.profileByKey(profile.key) orelse return error.TestExpectedProfile];
        try testing.expectEqual(profile.hidden, page.hidden);
    }
    try testing.expect(model.profiles[model.profileByKey("user:dev").?].hidden);
}

test "settings profiles: a list's recorded lines follow the file with that list, so a masked outside edit stops the save and an untouched list raises no false conflict" {
    const alloc = testing.allocator;
    const Load = struct {
        fn same(x: []const u8, y: []const u8) bool {
            return std.ascii.eqlIgnoreCase(x, y);
        }

        fn config(a: Allocator, earlier: []const u8, path: []const u8) !Config {
            var cfg = try Config.default(a);
            errdefer cfg.deinit();
            try cfg.loadFile(a, earlier);
            try cfg.loadFile(a, path);
            try cfg.loadRecursiveFiles(a);
            try cfg.finalize();
            return cfg;
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "earlier", .data = "# read first\n" });
    // A later file clears the order and gives its own: the config file's
    // own order line is masked.
    try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "profile-order =\nprofile-order = pwsh.exe\n" });
    const later = try tmp.dir.realpathAlloc(alloc, "later.conf");
    defer alloc.free(later);
    const before = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nprofile-order = cmd.exe\nconfig-file = {s}\n", .{later});
    defer alloc.free(before);
    const after = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nprofile-order = git-bash\nconfig-file = {s}\n", .{later});
    defer alloc.free(after);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = before });
    const earlier = try tmp.dir.realpathAlloc(alloc, "earlier");
    defer alloc.free(earlier);
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);

    // 1. The page moved a profile; another program changes the file's own
    // order line, under the mask; the window takes the reload in. The order
    // keeps its baseline, and the lines it was read from with it: the save
    // sees the outside edit and stops.
    {
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = before });
        var original = try Load.config(alloc, earlier, path);
        defer original.deinit();
        var draft = try original.clone(alloc);
        defer draft.deinit();
        try setOrder(&draft, &.{ "user:py", "pwsh.exe" });
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = after });
        var replacement = try Load.config(alloc, earlier, path);
        defer replacement.deinit();
        var baselines: Baselines = .of(&original);
        try followFile(&original, &draft, &replacement, &baselines);
        var disk = try Load.config(alloc, earlier, path);
        defer disk.deinit();
        const order: settings_patch.Edit = .{ .field = .order, .id = "", .op = .{ .list = &.{ "user:py", "pwsh.exe" } } };
        try testing.expect(try settings_patch.changedUnder(&.{order}, &baselines, &draft, &disk, path, &Load.same) != null);
    }
    // 2. The page changed a profile's command line, not the order; the
    // outside edit comes, and the untouched order follows the file, its
    // lines too. A move after that is checked against the file as it is
    // now: no conflict.
    {
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = before });
        var original = try Load.config(alloc, earlier, path);
        defer original.deinit();
        var draft = try original.clone(alloc);
        defer draft.deinit();
        try setCommand(&draft, "py", "python3.exe");
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = after });
        var replacement = try Load.config(alloc, earlier, path);
        defer replacement.deinit();
        var baselines: Baselines = .of(&original);
        try followFile(&original, &draft, &replacement, &baselines);
        try setOrder(&draft, &.{"user:py"});
        var disk = try Load.config(alloc, earlier, path);
        defer disk.deinit();
        const order: settings_patch.Edit = .{ .field = .order, .id = "", .op = .{ .list = &.{"user:py"} } };
        try testing.expect(try settings_patch.changedUnder(&.{order}, &baselines, &draft, &disk, path, &Load.same) == null);
    }
}

test "settings profiles: both lists are set together, or neither when memory runs out" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var draft = try Config.default(failing.allocator());
    defer draft.deinit();
    try draft.@"profile-order".parseCLI(draft._arena.?.allocator(), "pwsh.exe");
    // Room in the draft's arena for the order, none for a large hidden list.
    const arena = draft._arena.?.allocator();
    arena.free(try arena.alloc(u8, 64 * 1024));
    const large = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(large);
    @memset(large, 'x');
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, setLists(&draft, &[_][]const u8{"cmd.exe"}, &[_][]const u8{large}));
    // The order is as it was.
    try testing.expectEqual(@as(usize, 1), draft.@"profile-order".list.items.len);
    try expectSameText("pwsh.exe", draft.@"profile-order".list.items[0]);
    try testing.expectEqual(@as(usize, 0), draft.@"profile-hidden".list.items.len);
}

test "settings profiles: a list the page left alone keeps the app's answer, aliases and all" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-hidden = wsl\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    // `wsl` hides the default distribution: the app says so, the page
    // cannot tell from the word.
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "user:py", .label = "py" },
        .{ .key = "wsl:Ubuntu", .label = "Ubuntu", .hidden = true },
    };
    // The draft's order is its own; its hidden list is the file's, as when
    // the file's changed and the draft followed it (`followFile`).
    try setOrder(&draft, &.{ "user:py", "pwsh.exe", "wsl:Ubuntu" });
    var model: Model = .{};
    defer model.deinit();
    try model.buildListed(alloc, &draft, &original, &listed, true);
    const keys = try testKeysText(alloc, &model);
    defer alloc.free(keys);
    try expectSameText("user:py\npwsh.exe\nwsl:Ubuntu (hidden)\n", keys);
}

test "settings profiles: SSH aliases that differ only in case are two profiles, and a default alias marks its profile" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "default-profile = pwsh\n", &.{});
    defer original.deinit();
    const listed = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell", .default = true },
        .{ .key = "ssh:prod", .label = "prod" },
        .{ .key = "ssh:Prod", .label = "Prod" },
    };
    var model: Model = .{};
    defer model.deinit();
    try model.buildListed(alloc, &original, &original, &listed, true);
    try testing.expectEqual(@as(?u32, 1), model.profileByKey("ssh:prod"));
    try testing.expectEqual(@as(?u32, 2), model.profileByKey("ssh:Prod"));
    try testing.expectEqual(@as(?u32, 1), model.profileByKey("SSH:prod"));
    try testing.expect(model.rows[2].identity != model.rows[3].identity);
    // `default-profile = pwsh` starts PowerShell (the app's answer).
    try testing.expect(model.profiles[0].default);
    try testing.expect(!model.profiles[1].default);
    // A draft that names another profile marks that one, though the list
    // (no answer for it here) marks none.
    var draft = try testConfig(alloc, "default-profile = ssh:Prod\n", &.{});
    defer draft.deinit();
    const unmarked = [_]Listed{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "ssh:prod", .label = "prod" },
        .{ .key = "ssh:Prod", .label = "Prod" },
    };
    try model.buildListed(alloc, &draft, &original, &unmarked, true);
    try testing.expect(!model.profiles[0].default);
    try testing.expect(!model.profiles[1].default);
    try testing.expect(model.profiles[2].default);
}

test "settings profiles: a draft's own order outlives a change to the file, and an untouched list follows it" {
    const alloc = testing.allocator;
    var original = try testConfig(alloc, "profile-command = py: python.exe\nprofile-order = cmd.exe\nprofile-hidden = pwsh.exe\n", &.{});
    defer original.deinit();
    var draft = try original.clone(alloc);
    defer draft.deinit();
    // The page moved a profile: the draft's order is its own.
    try setOrder(&draft, &.{ "user:py", "cmd.exe" });
    // The file changes both lists meanwhile.
    var replacement = try testConfig(alloc, "profile-command = py: python.exe\nprofile-order = wsl\nprofile-hidden = cmd.exe\n", &.{});
    defer replacement.deinit();
    var baselines: Baselines = .of(&original);
    try followFile(&original, &draft, &replacement, &baselines);
    // The order stays the draft's, over the baseline it started from (which
    // a save checks against the file); the hidden list, untouched, follows.
    try expectSameText("user:py", draft.@"profile-order".list.items[0]);
    try expectSameText("cmd.exe", original.@"profile-order".list.items[0]);
    try expectSameText("cmd.exe", draft.@"profile-hidden".list.items[0]);
    try expectSameText("cmd.exe", original.@"profile-hidden".list.items[0]);
}
