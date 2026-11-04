//! The lines Settings' profile editor writes to the config file it saves to:
//! user profile definitions (`profile-command`, `profile-name`,
//! `profile-working-directory`, `profile-env`), patched by identity, so a save
//! never touches another profile's lines, a comment or an unrelated line.
//!
//! A field's identity is (key, id) for the three keys that hold one value per
//! profile, and (key, id, variable name) for `profile-env`. Ids and variable
//! names compare ASCII case-insensitively, as the loader compares them
//! (`config/profile_map.zig`). A line is read as the loader reads it
//! (`cli.args.LineIterator`): trimmed, the key ending at the first `=`, one
//! pair of quotes around the whole value removed; a line the loader would
//! refuse (`profile_map.check`) is never matched or changed.
//!
//! `patchOrAppendEdits` (win32.zig), which patches every other setting by key
//! alone, never sees these keys: they are not among Settings' editable keys.
//!
//! `profile-order` and `profile-hidden` are lists, not fields of one profile:
//! a save that changed either writes it whole (`Edit.Op.list`). The file's own
//! lines for the key go, and `key =` (which clears what any earlier layer
//! gave) then one line per value take the place of the first of them.
const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const Key = Config.Key;
const profile_map = @import("../../config/profile_map.zig");
const origin = @import("../../config/origin.zig");
const windows_shell = @import("../../config/windows_shell.zig");
const LineIterator = @import("../../cli/args.zig").LineIterator;

/// One of the four `profile-*` keys that give each profile a value, or one
/// of the two lists (`order`, `hidden`).
pub const Field = enum {
    command,
    name,
    folder,
    env,
    /// `profile-order`: written whole (`Edit.Op.list`).
    order,
    /// `profile-hidden`: written whole (`Edit.Op.list`).
    hidden,

    pub fn key(self: Field) Key {
        return switch (self) {
            .command => .@"profile-command",
            .name => .@"profile-name",
            .folder => .@"profile-working-directory",
            .env => .@"profile-env",
            .order => .@"profile-order",
            .hidden => .@"profile-hidden",
        };
    }

    /// Whether it is one of the lists, written whole.
    pub fn isList(self: Field) bool {
        return self == .order or self == .hidden;
    }

    fn kind(comptime self: Field) profile_map.Kind {
        return switch (self) {
            .command => .command,
            .name => .name,
            .folder => .text,
            .env => .env,
            .order, .hidden => @compileError("a list gives no profile a value"),
        };
    }

    /// The per-profile field a line's key names: never a list, which is not
    /// matched by identity.
    fn fromName(name: []const u8) ?Field {
        inline for (.{ Field.command, Field.name, Field.folder, Field.env }) |field| {
            if (std.mem.eql(u8, name, @tagName(comptime field.key()))) return field;
        }
        return null;
    }
};

/// What a save does to one field of one profile in the file it writes.
pub const Edit = struct {
    field: Field,
    id: []const u8,
    /// `profile-env`: the variable. Null only with `.delete`, for every
    /// variable of the profile.
    name: ?[]const u8 = null,
    op: Op,
    /// A field deleted because its profile is removed: a removed profile's
    /// fields stay dormant in other files, so after the save it is not
    /// checked (`editHeld`).
    with_profile: bool = false,
    /// A list edit: the app's profiles, which tell what a value a later
    /// layer adds names (`listCheck`): `pwsh` hides `pwsh.exe` as the save's
    /// own `pwsh.exe` does. Empty: values are compared as written.
    profiles: []const windows_shell.Profile = &.{},
    /// Whether `profiles` is the app's whole list. Without it (a discovery
    /// ended without some profiles, or no window has a list), what a value a
    /// later layer adds to the hidden list names is not known, so the check
    /// is unavailable for it (`Check.unchecked`), neither held nor masked.
    profiles_complete: bool = true,

    pub const Op = union(enum) {
        /// Give the field this value (for `profile-env`, the variable's
        /// value): the last line of the file that writes the field becomes
        /// `key = id: value`.
        set: []const u8,
        /// Take the field back where another file still gives it a value:
        /// the last line that writes it becomes its removal, `key = id:` or
        /// `profile-env = id: NAME=` (for `profile-command`, the profile's
        /// tombstone).
        unset,
        /// Take the file's own lines for the field out, where no other file
        /// gives it a value.
        delete,
        /// `profile-order`, `profile-hidden` (`Field.isList`): the file's own
        /// lines for the key go, and `key =`, then one line per value, take
        /// the place of the first. `id` is empty.
        list: []const []const u8,
    };
};

const Ending = enum { lf, crlf, none };

/// What a line of the file writes, read as the loader reads it.
const Info = struct {
    field: Field,
    /// Empty for `.key`.
    id: []const u8,
    /// `profile-env`, `.exact`: the variable.
    name: ?[]const u8 = null,
    scope: Scope,

    const Scope = enum {
        /// One field: a value or its removal (`id:` for the three scalar
        /// keys, `id: NAME=` for a variable).
        exact,
        /// `profile-env = id:`: every variable of the profile.
        profile,
        /// `key =`: every profile's field.
        key,
    };
};

const Line = struct {
    text: []const u8,
    ending: Ending,
    info: ?Info,
    deleted: bool = false,
};

const whitespace = " \t";

/// What `text` (one line, without its line ending) writes to a `profile-*`
/// key, if anything the loader would take.
fn readLine(segment: []const u8) ?Info {
    // A line longer than the reader takes is skipped whole. `segment` is the
    // line as the reader sees it, every CR before its `\n` included.
    if (!LineIterator.takes(segment)) return null;
    const trimmed = std.mem.trim(u8, segment, whitespace ++ "\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    const field = Field.fromName(std.mem.trim(u8, trimmed[0..eq], whitespace)) orelse return null;
    var value = std.mem.trim(u8, trimmed[eq + 1 ..], whitespace);
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    // `ProfileMap.parseCLI` trims what the reader hands it: `" "` is empty.
    value = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (value.len == 0) return .{ .field = field, .id = "", .scope = .key };
    const parsed = switch (field) {
        .order, .hidden => unreachable,
        inline else => |f| profile_map.check(comptime f.kind(), value),
    } catch return null;
    if (field != .env) return .{ .field = field, .id = parsed.id, .scope = .exact };
    if (parsed.text.len == 0) return .{ .field = field, .id = parsed.id, .scope = .profile };
    const sign = std.mem.indexOfScalar(u8, parsed.text, '=').?;
    return .{
        .field = field,
        .id = parsed.id,
        .name = std.mem.trim(u8, parsed.text[0..sign], &std.ascii.whitespace),
        .scope = .exact,
    };
}

/// Whether `info` writes exactly the field `edit` names.
fn exact(edit: Edit, info: Info) bool {
    if (info.field != edit.field or info.scope != .exact or !std.ascii.eqlIgnoreCase(info.id, edit.id)) return false;
    if (edit.field != .env) return true;
    const name = edit.name orelse return false;
    return std.ascii.eqlIgnoreCase(info.name.?, name);
}

/// Whether `info` changes the field `edit` names: writes it, or takes it back
/// with others (`key =`, `profile-env = id:`).
fn affects(edit: Edit, info: Info) bool {
    if (exact(edit, info)) return true;
    if (info.field != edit.field) return false;
    return switch (info.scope) {
        .exact => false,
        .profile => std.ascii.eqlIgnoreCase(info.id, edit.id),
        .key => true,
    };
}

/// Whether `info` is a line of the profile `edit` names, any field.
fn sameProfile(edit: Edit, info: Info) bool {
    return info.scope != .key and std.ascii.eqlIgnoreCase(info.id, edit.id);
}

/// Whether a `.delete` of `edit` takes `info`'s line out.
fn deletes(edit: Edit, info: Info) bool {
    if (edit.field == .env and edit.name == null)
        return info.field == .env and info.scope != .key and std.ascii.eqlIgnoreCase(info.id, edit.id);
    return exact(edit, info);
}

/// Whether `text` (one line, without its line ending) is a line the loader
/// reads as setting `name`: a value for it, or `name =`, which clears it.
fn setsKey(text: []const u8, name: []const u8) bool {
    if (!LineIterator.takes(text)) return false;
    const trimmed = std.mem.trim(u8, text, whitespace ++ "\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, trimmed[0..eq], whitespace), name);
}

/// Whether `value` can be written as one line of the list `field` and read
/// back as it is: not empty (which would clear the list), no line ending or
/// NUL, nothing the loader trims, no quotes it would take off, and a line no
/// longer than it reads.
fn listValueWritable(field: Field, value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return false;
    if (!std.mem.eql(u8, std.mem.trim(u8, value, &std.ascii.whitespace), value)) return false;
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return false;
    return @tagName(field.key()).len + " = ".len + value.len <= LineIterator.max_line_len;
}

/// Whether two values of a list name the same thing, as the loader compares
/// references: without case.
fn listValueEql(a_raw: []const u8, b_raw: []const u8) bool {
    const a = std.mem.trim(u8, a_raw, &std.ascii.whitespace);
    const b = std.mem.trim(u8, b_raw, &std.ascii.whitespace);
    // An `ssh:` alias exactly, as OpenSSH aliases are case-sensitive; its
    // prefix in any case, as the loader takes it.
    const prefix = "ssh:";
    if (std.ascii.startsWithIgnoreCase(a, prefix) or std.ascii.startsWithIgnoreCase(b, prefix)) {
        return a.len == b.len and std.ascii.startsWithIgnoreCase(a, prefix) and std.ascii.startsWithIgnoreCase(b, prefix) and
            std.mem.eql(u8, a[prefix.len..], b[prefix.len..]);
    }
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The list `config` gives `field` (`order` or `hidden`).
fn listOf(field: Field, config: *const Config) []const [:0]const u8 {
    return switch (field) {
        .order => config.@"profile-order".list.items,
        .hidden => config.@"profile-hidden".list.items,
        else => unreachable,
    };
}

/// Whether `a` and `b` give the list `field` the same values, in order.
fn listEql(field: Field, a: *const Config, b: *const Config) bool {
    const left = listOf(field, a);
    const right = listOf(field, b);
    if (left.len != right.len) return false;
    for (left, right) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// What the check after a save found of an edit (`editCheck`): its value
/// holds, a later layer masks it, or, for a hidden list, a later layer adds a
/// value whose profiles the app has not all found, so whether it hides more
/// than the save cannot be told.
pub const Check = enum { held, masked, unchecked };

/// Whether `reloaded` holds the list a save wrote (`values`): a layer read
/// after the file (an include, the command line) may add to it, but not
/// clear it. The values come first, in their order, so what they name keeps
/// its place; for `profile-hidden` anything added must name one of them, or
/// it hides a profile the save shows. That is told from `profiles` when they
/// are the app's whole list (`complete`); otherwise an added value the save's
/// list does not hold as written leaves the check unavailable.
fn listCheck(field: Field, values: []const []const u8, reloaded: *const Config, profiles: []const windows_shell.Profile, complete: bool) Check {
    const now = listOf(field, reloaded);
    if (now.len < values.len) return .masked;
    for (values, now[0..values.len]) |value, held| if (!listValueEql(value, held)) return .masked;
    if (field == .order) return .held;
    var check: Check = .held;
    for (now[values.len..]) |extra| {
        for (values) |value| {
            if (listValueEql(value, extra)) break;
        } else if (!complete) {
            check = .unchecked;
        } else if (!namesOnlyNamed(extra, values, profiles)) return .masked;
    }
    return check;
}

/// Whether `extra`, a hidden value a later layer adds, names profiles, and
/// only ones `values` (the save's hidden list) names too, as the app reads
/// them (`windows_shell.referenceNames`): `pwsh` after a saved `pwsh.exe`
/// hides nothing more. One that names none of `profiles` is not known to be.
fn namesOnlyNamed(extra: []const u8, values: []const []const u8, profiles: []const windows_shell.Profile) bool {
    var names_any = false;
    for (profiles) |profile| {
        if (!windows_shell.referenceNames(profiles, extra, profile)) continue;
        names_any = true;
        for (values) |value| {
            if (windows_shell.referenceNames(profiles, value, profile)) break;
        } else return false;
    }
    return names_any;
}

/// Whether a save of `pending` writes the lists (`listEdits`): it holds
/// either otherwise than `original`.
pub fn listsChanged(original: *const Config, pending: *const Config) bool {
    return !listEql(.order, original, pending) or !listEql(.hidden, original, pending);
}

/// Why Settings cannot change the profiles' order and visibility
/// (`listsForeign`). A save writes both lists into the file it saves to,
/// whole, after a clear (the maintainer's decision 2), so a value another
/// layer gives either list would become the file's own, and apply where that
/// layer does not.
pub const ListsForeign = enum {
    /// The command line sets one (`--profile-order`, `--profile-hidden`).
    command_line,
    /// A config file read after the one Settings saves to sets one: a later
    /// `--config-file`, or a file `config-file` includes.
    later_file,
    /// They differ between the light and the dark state: a theme sets one
    /// for one state only.
    theme,
    /// They could not be read in both states: a theme that could not be
    /// read whole, or no memory to read it.
    unread,
    /// The order the config files loaded in cannot be worked out: a file (or
    /// the command line) cleared `config-file` while they loaded, so a file
    /// it named before is no longer in the list that places it.
    unordered,

    /// The reason, as the status line says it.
    pub fn text(self: ListsForeign) []const u8 {
        return switch (self) {
            .command_line => "The command line sets the profile order or the hidden profiles, so Settings can't change them: a save would copy its values into the config file.",
            .later_file => "A config file read after the one Settings saves to sets the profile order or the hidden profiles, so Settings can't change them: a save would copy its values into the config file.",
            .theme => "The light and dark themes give different profile orders or hidden profiles, so Settings can't change them: a save would make one theme's choice apply in both.",
            .unread => "The profile order and the hidden profiles could not be read in both the light and dark states, so Settings can't change them.",
            .unordered => "A config file or the command line clears config-file, so the order the config files load in couldn't be worked out: a later one may set the profile order or the hidden profiles, so Settings can't change them.",
        };
    }
};

/// Whether the profiles' order and visibility, as `config` (the running
/// config, or a fresh read of the layers) gives them, are what the file
/// `path` and the layers read before it give, alone and the same in the light
/// and dark states: null when they are, and a save may write both lists into
/// `path`; otherwise why not.
///
/// The command line's value for either list is this launch's choice alone,
/// whatever the load order: a save that wrote it into the file would keep it
/// for every later launch, also when the file is a `--config-file` the
/// loader reads after the command line.
///
/// Other files are placed in the loader's order by what they are, not by
/// their lines, so a file Settings saves to that gives no line (empty,
/// comments only, or not there yet) is placed too (`loadOrder`). The default
/// config files come first (Settings saves to the last of them), then the
/// command line, then each file `config-file` names, in that list's order.
/// A line of another file that sets either list is a later layer's when that
/// file loads after `path`. A theme's lines come first (`loadTheme` replays
/// the config over them); the light/dark comparison judges them.
///
/// That order is rebuilt from the `config-file` list as loading left it. A
/// step that cleared the list (`config-file =`, in a file or on the command
/// line) can have dropped a file that loaded after `path` from it, which
/// would then pass for a default file read before: so while any other file
/// sets a list and the list was cleared, the order counts as unknown, and
/// the lists as foreign (`.unordered`). The config is not changed to record
/// the order (it is shared with upstream).
pub fn listsForeign(config: *const Config, path: []const u8, same: origin.SamePath) Allocator.Error!?ListsForeign {
    const steps = config._replay_steps.items;
    const target = loadOrder(config, path, same);
    var foreign: ?ListsForeign = null;
    var cleared = false;
    var set_elsewhere = false;
    for (steps) |step| {
        if (step == .@"-e") break;
        const arg = appliedArg(config, step) orelse continue;
        if (clearsIncludes(arg.text)) cleared = true;
        if (!setsList(arg.text)) continue;
        switch (arg.location) {
            // A line with no place counts as the command line's.
            .cli, .none => return .command_line,
            .file => |file| {
                if (same(file.path, path)) continue;
                set_elsewhere = true;
                if (loadOrder(config, file.path, same).after(target)) foreign = foreign orelse .later_file;
            },
        }
    }
    if (cleared and set_elsewhere) return .unordered;
    if (foreign) |why| return why;
    // The same in both states.
    var switched: [2]?Config = .{ null, null };
    defer for (&switched) |*value| if (value.*) |*reading| reading.deinit();
    var readings: [2]*const Config = undefined;
    for ([_]@FieldType(configpkg.ConditionalState, "theme"){ .light, .dark }, 0..) |theme, i| {
        var state = config._conditional_state;
        state.theme = theme;
        switched[i] = config.changeConditionalState(state) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .unread;
        };
        readings[i] = if (switched[i]) |*reading| reading else config;
        if (unreadTheme(readings[i]) != null) return .unread;
    }
    if (!listEql(.order, readings[0], readings[1]) or !listEql(.hidden, readings[0], readings[1])) return .theme;
    return null;
}

/// Where a file loads among `config`'s layers (`listsForeign`): a default
/// config file (or a theme, which loads before them all), read before the
/// command line and every file `config-file` names; or the `index`th of
/// those, which load in that list's order (`Config.loadRecursiveFiles`
/// appends what each names, and reads them in turn).
const LoadOrder = union(enum) {
    default,
    included: usize,

    /// Whether a file in this place loads after one in `other`. Of two
    /// default files, none: Settings saves to the last of them
    /// (`file_load.preferredDefaultFilePath`, read after the legacy one).
    fn after(self: LoadOrder, other: LoadOrder) bool {
        return switch (self) {
            .default => false,
            .included => |at| switch (other) {
                .default => true,
                .included => |target| at > target,
            },
        };
    }
};

fn loadOrder(config: *const Config, path: []const u8, same: origin.SamePath) LoadOrder {
    for (config.@"config-file".value.items, 0..) |entry, at| {
        const named = switch (entry) {
            .optional, .required => |named| named,
        };
        if (same(named, path)) return .{ .included = at };
    }
    return .default;
}

/// A step's argument and place, when it applies now: an argument, or a
/// conditional one whose conditions match `config`'s state.
fn appliedArg(config: *const Config, step: anytype) ?struct { text: []const u8, location: @import("../../cli/diagnostics.zig").Location } {
    return switch (step) {
        .arg => |arg| .{ .text = arg.value, .location = arg.location },
        .conditional_arg => |arg| for (arg.conditions) |cond| {
            if (!config._conditional_state.match(cond)) break null;
        } else .{ .text = arg.arg, .location = arg.location },
        else => null,
    };
}

/// Whether a step's argument clears `config-file` (an empty value), which
/// drops every file it named so far from the list.
fn clearsIncludes(text: []const u8) bool {
    const key = "--config-file";
    if (!std.mem.startsWith(u8, text, key)) return false;
    const rest = text[key.len..];
    return rest.len > 0 and rest[0] == '=' and std.mem.trim(u8, rest[1..], &std.ascii.whitespace).len == 0;
}

/// Whether a step's argument (`--key=value`) sets `profile-order` or
/// `profile-hidden`.
fn setsList(text: []const u8) bool {
    for ([_][]const u8{ "--profile-order", "--profile-hidden" }) |key| {
        if (std.mem.startsWith(u8, text, key) and (text.len == key.len or text[key.len] == '=')) return true;
    }
    return false;
}

/// `profiles` (a window's whole list) with a user profile for each the
/// draft (`pending`) has and the list does not: a profile the save adds is
/// no window's yet, and the overridden check (`listCheck`) must know what
/// names it. From `arena`.
pub fn withDraftProfiles(arena: Allocator, profiles: []const windows_shell.Profile, pending: *const Config) Allocator.Error![]const windows_shell.Profile {
    var out: std.ArrayListUnmanaged(windows_shell.Profile) = .empty;
    try out.appendSlice(arena, profiles);
    for (pending.@"profile-command".entries.items) |entry| {
        if (entry.removed) continue;
        const key = try std.fmt.allocPrint(arena, "user:{s}", .{entry.id});
        const known = for (profiles) |profile| {
            if (profile.kind == .user and std.ascii.eqlIgnoreCase(profile.key, key)) break true;
        } else false;
        if (!known) try out.append(arena, .{ .kind = .user, .key = key, .label = entry.id, .command = .{ .direct = &.{} } });
    }
    return out.items;
}

/// The list edits a save of `pending` makes: each list it holds otherwise
/// than `original`, written whole. From `arena`.
fn listEdits(arena: Allocator, original: *const Config, pending: *const Config) ![]Edit {
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    // Both blocks or neither: a move or a hide gives the page's order and
    // visibility whole, and each block is conflict-checked (`changedUnder`).
    if (listEql(.order, original, pending) and listEql(.hidden, original, pending)) return edits.toOwnedSlice(arena);
    for ([_]Field{ .order, .hidden }) |field| {
        const items = listOf(field, pending);
        const values = try arena.alloc([]const u8, items.len);
        for (items, values) |item, *value| value.* = try arena.dupe(u8, item);
        try edits.append(arena, .{ .field = field, .id = "", .op = .{ .list = values } });
    }
    return edits.toOwnedSlice(arena);
}

/// How a config file's text ends. A save that patches profile lines keeps
/// it (`persistSettings`): it hands both patchers the text ending in a
/// complete line ending (`terminate`), so neither ever sees a last line
/// without one, and gives the result the file's own ending once
/// (`restore`). That ending belongs to the file's last line: it stays with
/// that line, or the line now after it, and goes with it when the line is
/// deleted.
pub const FileEnd = enum {
    /// Nothing past a byte order mark, or an LF last.
    terminated,
    /// Text after the last line ending.
    none,
    /// A CR with no LF after it.
    bare_cr,

    pub fn of(raw: []const u8) FileEnd {
        const text = if (std.mem.startsWith(u8, raw, utf8_bom)) raw[utf8_bom.len..] else raw;
        if (text.len == 0 or text[text.len - 1] == '\n') return .terminated;
        return if (text[text.len - 1] == '\r') .bare_cr else .none;
    }

    /// The comment lines `terminate` puts before and after the file's last
    /// line, so `restore` can tell whether the patches kept it. Both
    /// patchers copy a comment as it is. A NUL is in neither the file
    /// (`persistSettings` refuses one) nor any line the save writes
    /// (`patchProfileEdits` and `writeProfileLine` refuse one), so no other
    /// line holds one of these; `restore` still matches only whole lines, and
    /// fails if a NUL is left once the marks are out.
    const before_last = "#\x00 the file's last line follows";
    const after_last = "#\x00 the file's last line was above";

    /// `raw` into `out`, its last line ended and marked. A bare CR gets its
    /// LF, and a last line with no ending gets the one most of the file's
    /// lines have; a comment line goes before it and one after
    /// (`before_last`, `after_last`), ending as most lines then do, so no
    /// patcher's choice of line ending changes. A file that ends in a line
    /// ending is copied as it is.
    pub fn terminate(self: FileEnd, alloc: Allocator, raw: []const u8, out: *std.ArrayListUnmanaged(u8)) Allocator.Error!void {
        if (self == .terminated) return out.appendSlice(alloc, raw);
        var crlf, var lf = lineEndings(raw);
        const last_ending: []const u8 = if (self == .bare_cr) "\n" else if (crlf > lf) "\r\n" else "\n";
        if (self == .bare_cr or crlf > lf) crlf += 1 else lf += 1;
        const ending: []const u8 = if (crlf > lf) "\r\n" else "\n";
        const last = if (std.mem.lastIndexOfScalar(u8, raw, '\n')) |at| at + 1 else if (std.mem.startsWith(u8, raw, utf8_bom)) utf8_bom.len else 0;
        try out.appendSlice(alloc, raw[0..last]);
        try out.appendSlice(alloc, before_last);
        try out.appendSlice(alloc, ending);
        try out.appendSlice(alloc, raw[last..]);
        try out.appendSlice(alloc, last_ending);
        try out.appendSlice(alloc, after_last);
        try out.appendSlice(alloc, ending);
    }

    /// Give `text`, patched from what `terminate` made, the file's own
    /// ending, and take the marks out. Only the last line itself, kept or
    /// changed in place, is ever between the marks: a line patched in after
    /// it goes after the second mark (`patchProfileEdits`), and the ordinary
    /// patcher adds lines only at the end. So when anything is between them,
    /// the last line survived, and the line that is last now ends as the file
    /// did: exactly one line ending comes off for `.none`, and for `.bare_cr`
    /// the last one becomes a CR, whether that line is the old last line or
    /// one added after it. When nothing is, the last line was deleted, and
    /// every line left keeps its own ending. Fails, and the save with it, if
    /// a mark is not found as a whole line, or a NUL is left once the marks
    /// are out.
    pub fn restore(self: FileEnd, text: *std.ArrayListUnmanaged(u8)) error{MarksDisturbed}!void {
        if (self == .terminated) return;
        const before = markLine(text.items, 0, before_last) orelse return error.MarksDisturbed;
        const before_end = lineEnd(text.items, before);
        const after = markLine(text.items, before_end, after_last) orelse return error.MarksDisturbed;
        const after_end = lineEnd(text.items, after);
        const kept = after > before_end;
        removeRange(text, after, after_end);
        removeRange(text, before, before_end);
        if (std.mem.indexOfScalar(u8, text.items, 0) != null) return error.MarksDisturbed;
        if (!kept) return;
        const ending: usize = if (std.mem.endsWith(u8, text.items, "\r\n")) 2 else if (std.mem.endsWith(u8, text.items, "\n")) 1 else 0;
        if (ending == 0) return;
        text.shrinkRetainingCapacity(text.items.len - ending);
        if (self == .bare_cr) text.appendAssumeCapacity('\r');
    }

    /// The start of the first line from `from` that is exactly `mark`, with
    /// its line ending; a match inside another line is none.
    fn markLine(items: []const u8, from: usize, mark: []const u8) ?usize {
        var at = from;
        while (std.mem.indexOfPos(u8, items, at, mark)) |found| : (at = found + 1) {
            const starts = found == 0 or items[found - 1] == '\n' or
                (found == utf8_bom.len and std.mem.startsWith(u8, items, utf8_bom));
            const rest = items[found + mark.len ..];
            if (starts and (std.mem.startsWith(u8, rest, "\n") or std.mem.startsWith(u8, rest, "\r\n"))) return found;
        }
        return null;
    }

    /// Whether `text`, a line without its ending, is one of the marks: no
    /// line of the file, so no line a new block needs a blank line after.
    fn isMark(text: []const u8) bool {
        return std.mem.eql(u8, text, before_last) or std.mem.eql(u8, text, after_last);
    }

    /// The index just past the line ending of the line at `at`.
    fn lineEnd(items: []const u8, at: usize) usize {
        return if (std.mem.indexOfScalarPos(u8, items, at, '\n')) |lf| lf + 1 else items.len;
    }

    fn removeRange(text: *std.ArrayListUnmanaged(u8), from: usize, to: usize) void {
        std.mem.copyForwards(u8, text.items[from..], text.items[to..]);
        text.shrinkRetainingCapacity(text.items.len - (to - from));
    }
};

const utf8_bom = "\xef\xbb\xbf";

/// How many of `raw`'s line endings are CRLF and how many LF, as the
/// patchers count them.
fn lineEndings(raw: []const u8) struct { usize, usize } {
    var crlf: usize = 0;
    var lf: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, start, '\n')) |at| : (start = at + 1) {
        if (at > start and raw[at - 1] == '\r') crlf += 1 else lf += 1;
    }
    return .{ crlf, lf };
}

/// The line `edit` writes, without its line ending, from `arena`.
fn editLine(arena: Allocator, edit: Edit) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const text: []const u8 = switch (edit.op) {
        .set => |value| if (edit.field == .env) try std.fmt.allocPrint(arena, "{s}={s}", .{ edit.name.?, value }) else value,
        .unset => if (edit.field == .env) try std.fmt.allocPrint(arena, "{s}=", .{edit.name.?}) else "",
        .delete, .list => unreachable,
    };
    switch (edit.field) {
        .order, .hidden => unreachable,
        inline else => |field| try profile_map.writeProfileLine(&out.writer, comptime field.kind(), @tagName(comptime field.key()), edit.id, text),
    }
    return std.mem.trimEnd(u8, out.written(), "\n");
}

/// Patch `raw`, the text of the config file Settings saves to, with `edits`,
/// in order, into `out`.
///
/// - `.set` and `.unset` write the field's line where it becomes the last
///   line of the file that changes the field. When that last line writes
///   exactly the field, it is replaced in place, keeping its indentation and
///   line ending. When a line that takes the field back with others comes
///   later (`key =`, `profile-env = id:`), the new line goes right after it,
///   so the file does not take back what it was given. A field the file has
///   no line for goes after the profile's last line, or, for a profile the
///   file has no line for, at the end of the file, after a blank line, so a
///   new profile's lines stay together in the order of `edits`.
/// - `.delete` takes out every line that writes exactly the field (for
///   `profile-env` with no name, every variable line of the profile and its
///   `profile-env = id:`), never a `key =` line.
///
/// Every other line is copied byte for byte: comments, blank lines, other
/// keys, other profiles, lines the loader refuses, earlier lines for the same
/// field (they do not take effect). A UTF-8 byte order mark is kept, and new
/// lines take the ending most of the file's lines have. A last line with no
/// line ending gets the file's when a line goes after it. A save never hands
/// the patcher such a line: `persistSettings` gives it text that ends in a
/// line ending and restores the file's own ending after (`FileEnd`).
pub fn patchProfileEdits(alloc: Allocator, raw: []const u8, edits: []const Edit, out: *std.ArrayListUnmanaged(u8)) !void {
    // A NUL is no config text, and could be taken for `FileEnd`'s marks:
    // an edit holding one (a variable name a file loaded, say) is refused
    // before anything is patched, so nothing of it is written.
    for (edits) |e| {
        const set_value: []const u8 = switch (e.op) {
            .set => |value| value,
            else => "",
        };
        for ([_][]const u8{ e.id, e.name orelse "", set_value }) |part| {
            if (std.mem.indexOfScalar(u8, part, 0) != null) return error.NulByte;
        }
        // A list value is one line: no line ending, nothing the loader
        // would trim or unquote, and no longer than it reads.
        if (e.op == .list) for (e.op.list) |value| {
            if (!listValueWritable(e.field, value)) return error.UnwritableListValue;
        };
    }

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bom = std.mem.startsWith(u8, raw, utf8_bom);
    const text = if (bom) raw[utf8_bom.len..] else raw;

    var lines: std.ArrayListUnmanaged(Line) = .empty;
    var crlf_count: usize = 0;
    var lf_count: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |segment| {
        const last = it.index == null;
        // The text after a final newline is no line.
        if (last and segment.len == 0) break;
        const crlf = !last and std.mem.endsWith(u8, segment, "\r");
        if (!last) {
            if (crlf) crlf_count += 1 else lf_count += 1;
        }
        const body = if (crlf) segment[0 .. segment.len - 1] else segment;
        try lines.append(arena, .{
            .text = body,
            .ending = if (last) .none else if (crlf) .crlf else .lf,
            // Read as the loader reads it: all of `segment`, the CRLF line's
            // CR too (`LineIterator.takes`).
            .info = readLine(segment),
        });
    }
    const dominant: Ending = if (crlf_count > lf_count) .crlf else .lf;

    for (edits) |edit| switch (edit.op) {
        .list => |values| {
            const name = @tagName(edit.field.key());
            var block: std.ArrayListUnmanaged(Line) = .empty;
            try block.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} =", .{name}), .ending = dominant, .info = null });
            for (values) |value| try block.append(arena, .{ .text = try std.fmt.allocPrint(arena, "{s} = {s}", .{ name, value }), .ending = dominant, .info = null });
            // The file's own lines for the key go; the block takes the place
            // of the first.
            var first: ?usize = null;
            for (lines.items, 0..) |*line, index| {
                if (line.deleted or !setsKey(line.text, name)) continue;
                if (first == null) first = index;
                line.deleted = true;
            }
            if (first) |index| {
                // Where the first was, which may be the file's marked last
                // line: the block's last line then ends as the file did
                // (`FileEnd.restore`).
                try lines.insertSlice(arena, index, block.items);
                continue;
            }
            // None: a block of its own at the end of the file.
            var last_kept: ?*Line = null;
            for (lines.items) |*line| {
                if (!line.deleted and !FileEnd.isMark(line.text)) last_kept = line;
            }
            if (last_kept) |line| {
                if (line.ending == .none) line.ending = dominant;
                if (std.mem.trim(u8, line.text, whitespace).len != 0)
                    try lines.append(arena, .{ .text = "", .ending = dominant, .info = null });
            }
            try lines.appendSlice(arena, block.items);
        },
        .delete => for (lines.items) |*line| {
            if (line.deleted) continue;
            const info = line.info orelse continue;
            if (deletes(edit, info)) line.deleted = true;
        },
        .set, .unset => {
            const new_text = try editLine(arena, edit);
            var last_affecting: ?usize = null;
            var last_of_profile: ?usize = null;
            for (lines.items, 0..) |line, index| {
                if (line.deleted) continue;
                const info = line.info orelse continue;
                if (affects(edit, info)) last_affecting = index;
                if (sameProfile(edit, info)) last_of_profile = index;
            }
            if (last_affecting) |index| if (exact(edit, lines.items[index].info.?)) {
                const line = &lines.items[index];
                const kept = line.text[0 .. line.text.len - std.mem.trimStart(u8, line.text, whitespace).len];
                // Kept unless it would make the line longer than the reader
                // takes.
                const indent = if (kept.len + new_text.len > LineIterator.max_line_len) "" else kept;
                line.text = try std.mem.concat(arena, u8, &.{ indent, new_text });
                line.info = readLine(line.text);
                continue;
            };
            const after: ?usize = if (last_affecting) |a| (if (last_of_profile) |p| @max(a, p) else a) else last_of_profile;
            const new_line: Line = .{ .text = new_text, .ending = dominant, .info = readLine(new_text) };
            if (after) |index| {
                if (lines.items[index].ending == .none) lines.items[index].ending = dominant;
                // After the file's marked last line, the new line goes after
                // the mark that follows it: only that line is ever between
                // the marks (`FileEnd.restore`).
                var at = index + 1;
                if (at < lines.items.len and std.mem.eql(u8, lines.items[at].text, FileEnd.after_last)) at += 1;
                try lines.insert(arena, at, new_line);
                continue;
            }
            // A profile this file has no line for: a block of its own at the
            // end of the file.
            var last_kept: ?*Line = null;
            for (lines.items) |*line| {
                if (!line.deleted and !FileEnd.isMark(line.text)) last_kept = line;
            }
            if (last_kept) |line| {
                if (line.ending == .none) line.ending = dominant;
                if (std.mem.trim(u8, line.text, whitespace).len != 0)
                    try lines.append(arena, .{ .text = "", .ending = dominant, .info = null });
            }
            try lines.append(arena, new_line);
        },
    };

    if (bom) try out.appendSlice(alloc, utf8_bom);
    for (lines.items) |line| {
        if (line.deleted) continue;
        try out.appendSlice(alloc, line.text);
        try out.appendSlice(alloc, switch (line.ending) {
            .lf => "\n",
            .crlf => "\r\n",
            .none => "",
        });
    }
}

/// The edits that make the file Settings saves to (`path`; `same` compares
/// paths) hold `pending`'s user profiles where they differ from `original`'s,
/// the config Settings was opened on, whose loader problems `problems`
/// indexes. From `arena`.
///
/// - A profile whose command line changed, or a new one: `.set` on its
///   command. Commands come first, so a new profile's block starts with its
///   `profile-command` line.
/// - A profile removed: its command is taken back. Its line is deleted when
///   nothing else names the id; otherwise `profile-command = <id>:` is
///   written, so the id stays known to the loader and nothing that names it
///   becomes a problem: another file or the command line still defines the
///   profile or gives one of its fields a value
///   (`origin.Index.givesElsewhere`), or `profile-order`, `profile-hidden`
///   or `default-profile` names it. This file's lines for its other fields
///   are deleted; a tombstone leaves any other file's dormant.
/// - A label, folder or variable changed or added: `.set`. One taken out:
///   its removal where another file still gives it a value, else `.delete`.
pub fn profileEdits(arena: Allocator, problems: []const origin.Index, original: *const Config, pending: *const Config, path: []const u8, same: origin.SamePath) ![]Edit {
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;
    const takeBack = struct {
        fn op(readings: []const origin.Index, field: Field, id: []const u8, name: ?[]const u8, target: []const u8, s: origin.SamePath) Edit.Op {
            for (readings) |*p| if (p.givesElsewhere(field.key(), id, name, target, s)) return .unset;
            return .delete;
        }
    }.op;

    // Commands, and whole profiles.
    const pending_commands = &pending.@"profile-command";
    const original_commands = &original.@"profile-command";
    for (pending_commands.entries.items) |entry| {
        const was = original_commands.get(entry.id);
        if (!entry.removed) {
            if (was == null or !std.mem.eql(u8, was.?, entry.value))
                try edits.append(arena, .{ .field = .command, .id = entry.id, .op = .{ .set = entry.value } });
        } else if (was != null) {
            try removed.append(arena, entry.id);
            const keep = referencedElsewhere(problems, entry.id, path, same);
            try edits.append(arena, .{ .field = .command, .id = entry.id, .op = if (keep) .unset else .delete });
            for ([_]Field{ .name, .folder, .env }) |field|
                try edits.append(arena, .{ .field = field, .id = entry.id, .op = .delete, .with_profile = true });
        }
    }

    const isRemoved = struct {
        fn check(list: []const []const u8, id: []const u8) bool {
            for (list) |gone| {
                if (std.ascii.eqlIgnoreCase(gone, id)) return true;
            }
            return false;
        }
    }.check;

    // Labels and folders.
    inline for (.{ .{ Field.name, "profile-name" }, .{ Field.folder, "profile-working-directory" } }) |pair| {
        const field = pair[0];
        const now = &@field(pending, pair[1]);
        const before = &@field(original, pair[1]);
        for (now.entries.items) |entry| {
            if (isRemoved(removed.items, entry.id)) continue;
            const was = before.get(entry.id);
            if (was == null or !std.mem.eql(u8, was.?, entry.value))
                try edits.append(arena, .{ .field = field, .id = entry.id, .op = .{ .set = entry.value } });
        }
        for (before.entries.items) |entry| {
            if (isRemoved(removed.items, entry.id) or now.get(entry.id) != null) continue;
            try edits.append(arena, .{ .field = field, .id = entry.id, .op = takeBack(problems, field, entry.id, null, path, same) });
        }
    }

    // Variables, by folded name.
    const findVar = struct {
        fn find(map: anytype, name: []const u8) ?[]const u8 {
            var it = map.iterator();
            while (it.next()) |kv| {
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) return kv.value_ptr.*;
            }
            return null;
        }
    }.find;
    for (pending.@"profile-env".entries.items) |entry| {
        if (isRemoved(removed.items, entry.id)) continue;
        const before = original.@"profile-env".get(entry.id);
        var it = entry.value.iterator();
        while (it.next()) |kv| {
            const was = if (before) |map| findVar(map, kv.key_ptr.*) else null;
            if (was == null or !std.mem.eql(u8, was.?, kv.value_ptr.*))
                try edits.append(arena, .{ .field = .env, .id = entry.id, .name = kv.key_ptr.*, .op = .{ .set = kv.value_ptr.* } });
        }
    }
    for (original.@"profile-env".entries.items) |entry| {
        if (isRemoved(removed.items, entry.id)) continue;
        const now = pending.@"profile-env".get(entry.id);
        var it = entry.value.iterator();
        while (it.next()) |kv| {
            if (now != null and findVar(now.?, kv.key_ptr.*) != null) continue;
            try edits.append(arena, .{ .field = .env, .id = entry.id, .name = kv.key_ptr.*, .op = takeBack(problems, .env, entry.id, kv.key_ptr.*, path, same) });
        }
    }
    return edits.toOwnedSlice(arena);
}

/// A file a load found and could not read whole (`unreadConfigFile`).
pub const Unread = struct {
    kind: Kind,
    path: []const u8,
    /// UTF-16 text that does not decode (`Config._undecodable_file`): the
    /// file was skipped whole.
    undecodable: bool = false,

    pub const Kind = enum { config, include, theme };

    /// How the status line names it: "the config file <path>", "the
    /// included file <path>" or "the theme file <path>", no value.
    pub fn describe(self: Unread, alloc: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ self.noun(), self.path });
    }

    /// The words `describe` puts before the path.
    pub fn noun(self: Unread) []const u8 {
        return switch (self.kind) {
            .config => "the config file",
            .include => "the included file",
            .theme => "the theme file",
        };
    }
};

/// The steps of a Settings save after it wrote the file
/// (`App.settingsSaveAndReload`): naming the settings a later layer overrides,
/// the reload report, naming a file it could not read whole, and applying
/// the reload.
pub const PostWriteStep = enum { masked_check, report, describe, apply };

/// Tests only: called just before each `PostWriteStep`, so a test can make
/// that step, and only it, fail.
pub threadlocal var test_post_write: if (@import("builtin").is_test) ?*const fn (PostWriteStep) void else void =
    if (@import("builtin").is_test) null else {};

/// Tests only: how the App loads the config for a Settings save (its check,
/// its fresh profile layers and its reload), instead of the real config
/// files, so a test of the save never reaches the real profile.
pub threadlocal var test_config_load: if (@import("builtin").is_test) ?*const fn (Allocator) anyerror!Config else void =
    if (@import("builtin").is_test) null else {};

/// What a save that wrote `edits` says of them after its reload (`reload`,
/// in the app's light/dark state, and `loaded`, the reload as it was read:
/// the switch drops the record of a file that did not decode). A file the reload could not read whole
/// comes first, for any save, one of ordinary settings alone too: a field
/// or a reset it missed is no override, so the save names that file
/// (`.unread`) and nothing as overridden, and keeps the running settings.
/// `loaded`, when the app runs the other state, is asked only about the
/// files every state reads (`unreadFiles`): its theme is not the one the
/// app applies, and `reload` read the app's own again.
/// Otherwise the fields another layer overrides go to `masked`
/// (`writeMasked`, after a separator when `after`), and the report is
/// `.masked`, or `.held` when there are none; `.unchecked` when none is
/// masked and the check was unavailable for a hidden list (`listCheck`).
pub fn reloadReport(masked: *std.Io.Writer, edits: []const Edit, reload: *const Config, loaded: *const Config, after: bool) std.Io.Writer.Error!union(enum) { held, masked, unchecked, unread: Unread } {
    if (loaded == reload) {
        if (unreadConfigFile(reload)) |unread| return .{ .unread = unread };
    } else {
        if (unreadFiles(loaded)) |unread| return .{ .unread = unread };
        if (unreadConfigFile(reload)) |unread| return .{ .unread = unread };
    }
    if (edits.len == 0) return .held;
    return switch (try writeMasked(masked, edits, reload, after)) {
        .held => .held,
        .masked => .masked,
        .unchecked => .unchecked,
    };
}

/// A file `config`'s load found and could not read whole, if any: a default
/// config file, `config-file` or theme that is there and would not open, or
/// one whose read failed partway through (`LineIterator.read_failed`, which
/// reads as the end of the file). The loader records each as a problem and goes on,
/// so the layers miss what the file says, and a save that decided from them
/// whether another file still names a removed profile would decide blind: it
/// stops instead. A missing include (`FileNotFound`) or a directory (`IsDir`)
/// is the loader's to report, as the disk check before a save lets them
/// through (`settingsDiskVerdict`).
pub fn unreadConfigFile(config: *const Config) ?Unread {
    return unreadOf(config, .any);
}

/// `unreadConfigFile`, for the theme alone: what a light/dark switch reads
/// itself (`finalize` reads the state's theme again), as against a config
/// file's problem, which a switch replays from the load it came from.
pub fn unreadTheme(config: *const Config) ?Unread {
    return unreadOf(config, .theme);
}

/// `unreadConfigFile`, for the files every light/dark state reads (the
/// config files and their includes) and not the theme: what a reading in
/// one state says of a save the app applies in another.
pub fn unreadFiles(config: *const Config) ?Unread {
    return unreadOf(config, .files);
}

const UnreadScope = enum { any, theme, files };

fn unreadOf(config: *const Config, scope: UnreadScope) ?Unread {
    const files = scope != .theme;
    const themes = scope != .files;
    // Skipped whole: UTF-16 that does not decode. One predicate for the
    // check before a save and the report after it, so they cannot drift.
    // The light/dark switch does not carry the config file's record over
    // (`changeConditionalState`), so its replayed problem is read below too;
    // that problem also says which file it was (`undecodableConfigFile`).
    if (files) if (config._undecodable_file) |path| return .{ .kind = undecodableKind(config, path), .path = path, .undecodable = true };
    if (themes) if (config._undecodable_theme) |path| return .{ .kind = .theme, .path = path, .undecodable = true };
    for (config._diagnostics.items()) |diag| {
        const message: []const u8 = diag.message;
        // A config file skipped as UTF-16 that does not decode, as its
        // problem says (`Config.invalidUtf16`): kept in the replay log, so a
        // config switched to the other light/dark state, or the app's after
        // a live switch, still shows it. A theme's stays out of that log.
        if (files) if (undecodableConfigFile(message)) |found| return .{ .kind = found.kind, .path = found.path, .undecodable = true };
        if (!themes and (std.mem.startsWith(u8, message, "failed to load theme ") or
            std.mem.startsWith(u8, message, "not reading theme from ") or
            std.mem.startsWith(u8, message, "error reading theme "))) continue;
        // A theme the load could not open (`themepkg.open`): the light/dark
        // switch reads it again after the save's probe, and it may have
        // become unopenable in between. The path is the last quoted name,
        // just before the error.
        if (std.mem.startsWith(u8, message, "failed to load theme ") or std.mem.startsWith(u8, message, "not reading theme from ")) {
            const quote_end = std.mem.lastIndexOf(u8, message, "\": error.") orelse continue;
            const theme_err = message[quote_end + 3 ..];
            if (std.mem.eql(u8, theme_err, "error.FileNotFound") or std.mem.eql(u8, theme_err, "error.IsDir")) continue;
            const quote_start = std.mem.lastIndexOfScalar(u8, message[0..quote_end], '"') orelse continue;
            return .{ .kind = .theme, .path = message[quote_start + 1 .. quote_end] };
        }
        if (scope == .theme and !std.mem.startsWith(u8, message, "error reading theme ")) continue;
        const prefix_len, const kind = for ([_]struct { []const u8, Unread.Kind }{
            .{ "error opening config-file ", .include },
            .{ "error reading config-file ", .include },
            .{ "error reading theme ", .theme },
            // A default config file that is there and will not open
            // (`Config.loadOptionalFile`), or whose read failed partway.
            .{ "error opening config file ", .config },
            .{ "error reading config file ", .config },
        }) |prefix| {
            if (std.mem.startsWith(u8, message, prefix[0])) break .{ prefix[0].len, prefix[1] };
        } else continue;
        const end_at = std.mem.lastIndexOf(u8, message, ": error.") orelse continue;
        if (end_at < prefix_len) continue;
        // Missing, or a directory: what the disk check lets through too.
        const err = message[end_at + 2 ..];
        if (std.mem.eql(u8, err, "error.FileNotFound") or std.mem.eql(u8, err, "error.IsDir")) continue;
        return .{ .kind = kind, .path = message[prefix_len..end_at] };
    }
    return null;
}

/// The file in `Config.invalidUtf16`'s problem for a config file, and which
/// file it is, or null: "config file <path> <reason>; not reading it. Save it
/// as UTF-8" for a config file the load was given (the default one),
/// "config-file <path> ..." for an include.
fn undecodableConfigFile(message: []const u8) ?struct { path: []const u8, kind: Unread.Kind } {
    const suffix = "; not reading it. Save it as UTF-8";
    if (!std.mem.endsWith(u8, message, suffix)) return null;
    const prefix: []const u8, const kind: Unread.Kind = if (std.mem.startsWith(u8, message, "config file "))
        .{ "config file ", .config }
    else if (std.mem.startsWith(u8, message, "config-file "))
        .{ "config-file ", .include }
    else
        return null;
    const body = message[prefix.len .. message.len - suffix.len];
    for ([_][]const u8{ " is not valid UTF-16", " is too large" }) |reason| {
        if (std.mem.endsWith(u8, body, reason)) return .{ .path = body[0 .. body.len - reason.len], .kind = kind };
    }
    return null;
}

/// Which file `path`, the config's record of a file that did not decode, is:
/// as its problem says, or an include when no problem says.
fn undecodableKind(config: *const Config, path: []const u8) Unread.Kind {
    for (config._diagnostics.items()) |diag| {
        const found = undecodableConfigFile(diag.message) orelse continue;
        if (std.mem.eql(u8, found.path, path)) return found.kind;
    }
    return .include;
}

/// Whether anything but this file's lines names profile `id`, in any of
/// `readings`: another layer defines it or gives one of its fields a value,
/// or a reference names it (`profile-order`, `profile-hidden`,
/// `default-profile`, as the config the index was made from holds them).
/// Deleting its last `profile-command` line would then leave the loader
/// something that names no profile. A reading that could not read every
/// file (`unreadConfigFile`) may have missed what names it, so it counts as
/// naming it: the line becomes a tombstone, one line more at worst. The
/// config as last read is one, since its markers are from that read and
/// the files may have been repaired since; a fresh reading with one never
/// gets here (the save stops on it).
fn referencedElsewhere(readings: []const origin.Index, id: []const u8, path: []const u8, same: origin.SamePath) bool {
    for (readings) |*problems| {
        if (unreadConfigFile(problems.config) != null) return true;
        for ([_]Field{ .command, .name, .folder, .env }) |field| {
            if (problems.givesElsewhere(field.key(), id, null, path, same)) return true;
        }
        const config = problems.config;
        if (config.@"default-profile") |value| if (namesProfile(value, id)) return true;
        for ([_][]const [:0]const u8{ config.@"profile-order".list.items, config.@"profile-hidden".list.items }) |values| {
            for (values) |value| if (namesProfile(value, id)) return true;
        }
    }
    return false;
}

/// Whether a reference value names user profile `id`: its id or `user:<id>`,
/// without case.
fn namesProfile(value: []const u8, id: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(value, id)) return true;
    return value.len == "user:".len + id.len and std.ascii.startsWithIgnoreCase(value, "user:") and std.ascii.eqlIgnoreCase(value["user:".len..], id);
}

/// Whether `reloaded`, the config read again after the save, holds the
/// field as `edit` left it. One that does not was masked: a file read after
/// the one saved to, or the command line, sets it again. A hidden list can be
/// unchecked instead (`listCheck`).
pub fn editCheck(edit: Edit, reloaded: *const Config) Check {
    if (edit.with_profile) return .held;
    if (edit.field == .env and edit.name == null) return .held;
    if (edit.op == .list) return listCheck(edit.field, edit.op.list, reloaded, edit.profiles, edit.profiles_complete);
    const now = editValue(edit, &.of(reloaded));
    const held = switch (edit.op) {
        .set => |value| now != null and std.mem.eql(u8, now.?, value),
        .unset, .delete => now == null,
        .list => unreachable,
    };
    return if (held) .held else .masked;
}

/// Whether `editCheck` found `edit` held.
pub fn editHeld(edit: Edit, reloaded: *const Config) bool {
    return editCheck(edit, reloaded) == .held;
}

/// The value `values` give the field `edit` writes: the profile's command
/// line, label or folder, or for `profile-env` the variable's value. Null
/// when they give none.
fn editValue(edit: Edit, values: *const ProfileValues) ?[]const u8 {
    return switch (edit.field) {
        .command => values.command.get(edit.id),
        .name => values.name.get(edit.id),
        .folder => values.folder.get(edit.id),
        .order, .hidden => unreachable,
        .env => env: {
            const name = edit.name orelse break :env null;
            const map = values.env.get(edit.id) orelse break :env null;
            var it = map.iterator();
            while (it.next()) |kv| {
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) break :env kv.value_ptr.*;
            }
            break :env null;
        },
    };
}

/// Whether `a` and `b` give the field `edit` writes the same value. For
/// `profile-env` with no variable (every variable of the profile), all of
/// them.
fn editEql(edit: Edit, a: *const ProfileValues, b: *const ProfileValues) bool {
    if (edit.field == .env and edit.name == null) {
        const left = a.env.get(edit.id);
        const right = b.env.get(edit.id);
        if (left == null or right == null) return left == null and right == null;
        if (left.?.map.count() != right.?.map.count()) return false;
        // Names compare without case, as the loader takes them (`Path` and
        // `PATH` are one variable).
        var it = left.?.map.iterator();
        outer: while (it.next()) |kv| {
            var other_it = right.?.map.iterator();
            while (other_it.next()) |other| {
                if (!std.ascii.eqlIgnoreCase(kv.key_ptr.*, other.key_ptr.*)) continue;
                if (!std.mem.eql(u8, kv.value_ptr.*, other.value_ptr.*)) return false;
                continue :outer;
            }
            return false;
        }
        return true;
    }
    const left = editValue(edit, a);
    const right = editValue(edit, b);
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

/// The first of `edits` whose field `disk` gives a value that neither the
/// draft's baseline for it (`baselines`) nor the draft (`pending`) gives:
/// another program changed what the draft changes. There is no Keep mine /
/// Use disk for a profile field, so a save that finds one stops
/// (SETTINGS-SAVE-TOCTOU): asked of every fresh read of the layers, so an
/// edit made after Settings read the config and before the save counts too.
///
/// Each field is compared with its own record (`Baselines`), and `disk` is
/// read in the light/dark state that record was read in: a dark theme's
/// line, read only because the app's state changed since, is no change to
/// any file. Switching it reads that state's theme again, and a theme that
/// read could not read whole stops the save (`error.ThemeUnread`) rather
/// than compare without its lines.
pub fn changedUnder(edits: []const Edit, baselines: *const Baselines, pending: *const Config, disk: *const Config, path: []const u8, same: origin.SamePath) !?Edit {
    var readings: StateReadings = .{ .disk = disk };
    defer readings.deinit();
    const drafted: ProfileValues = .of(pending);
    for (edits) |edit| {
        // A field deleted only because its profile is removed (its label,
        // folder and variables, `with_profile`) is not one the draft
        // changes: the removal covers whatever another layer or program
        // gives it now. The removal's own command line is still checked.
        if (edit.with_profile) continue;
        if (edit.field.isList()) {
            const base = baselines.list(edit.field);
            const now = try readings.in(base.state);
            // A list is written whole, both blocks or neither, after a clear
            // that drops what every earlier file gives it: a list the draft
            // left as it was is checked too, in every file that gives it
            // (an earlier file's line, written over by that clear, counts).
            const values = listOf(edit.field, now);
            if (!stringsEql(values, base.values) and !stringsEql(values, listOf(edit.field, pending))) return edit;
            // The file's own lines for the list, which the save replaces:
            // another program's edit to them is written over even when a
            // later layer masks the list, so it stops the save too.
            if (!ownLinesEql(edit.field.key(), now._launch.profile_places.items, base.places, path, same)) return edit;
            continue;
        }
        const base = &baselines.profiles;
        const now: ProfileValues = .of(try readings.in(base.state));
        if (!editEql(edit, &now, &base.values) and !editEql(edit, &now, &drafted)) return edit;
    }
    return null;
}

/// The values of the four keys that give each user profile a value, as one
/// config gives them: a profile field's baseline (`Baselines.profiles`).
/// The maps are the config's own, not copies.
pub const ProfileValues = struct {
    command: @FieldType(Config, "profile-command"),
    name: @FieldType(Config, "profile-name"),
    folder: @FieldType(Config, "profile-working-directory"),
    env: @FieldType(Config, "profile-env"),

    pub fn of(config: *const Config) ProfileValues {
        return .{
            .command = config.@"profile-command",
            .name = config.@"profile-name",
            .folder = config.@"profile-working-directory",
            .env = config.@"profile-env",
        };
    }
};

/// What a save checks one group of profile keys against for another
/// program's change (`changedUnder`): the values the draft started from,
/// where each profile line of that reading was read
/// (`_launch.profile_places`; the check reads the group's own keys), and
/// the light/dark state of that reading. A group follows the file on its own
/// (`settings_profiles.followFile`), which replaces its record whole, never
/// one part of it.
pub fn Baseline(comptime Values: type) type {
    return struct {
        values: Values,
        places: []const configpkg.pane_launch.ProfilePlace,
        state: configpkg.ConditionalState,
    };
}

/// The draft's baseline for each group of profile keys: the profiles' four
/// keys, `profile-order` and `profile-hidden`. Each record is borrowed from
/// the config it was read from (the window's baseline, whose arena outlives
/// it).
pub const Baselines = struct {
    profiles: Baseline(ProfileValues),
    order: Baseline([]const [:0]const u8),
    hidden: Baseline([]const [:0]const u8),

    /// Every group as `config` gives it, in its state: a config none of
    /// whose groups has followed a file since it was read.
    pub fn of(config: *const Config) Baselines {
        const places = config._launch.profile_places.items;
        const state = config._conditional_state;
        return .{
            .profiles = .{ .values = .of(config), .places = places, .state = state },
            .order = .{ .values = config.@"profile-order".list.items, .places = places, .state = state },
            .hidden = .{ .values = config.@"profile-hidden".list.items, .places = places, .state = state },
        };
    }

    /// The record of the list `field`.
    pub fn list(self: *const Baselines, field: Field) *const Baseline([]const [:0]const u8) {
        return switch (field) {
            .order => &self.order,
            .hidden => &self.hidden,
            else => unreachable,
        };
    }
};

/// `disk` in each light/dark state a record asks for, switched once per
/// state (`Config.changeConditionalState`); `disk` itself when it is in that
/// state already.
const StateReadings = struct {
    disk: *const Config,
    made: [3]Made = undefined,
    count: usize = 0,

    const Made = struct { state: configpkg.ConditionalState, config: ?Config };

    fn in(self: *StateReadings, state: configpkg.ConditionalState) !*const Config {
        const reading = for (self.made[0..self.count]) |*known| {
            if (std.meta.eql(known.state, state)) break known;
        } else made: {
            // One per record at most.
            std.debug.assert(self.count < self.made.len);
            self.made[self.count] = .{ .state = state, .config = try self.disk.changeConditionalState(state) };
            self.count += 1;
            const fresh = &self.made[self.count - 1];
            if (fresh.config) |*config| if (unreadTheme(config) != null) return error.ThemeUnread;
            break :made fresh;
        };
        return if (reading.config) |*config| config else self.disk;
    }

    fn deinit(self: *StateReadings) void {
        for (self.made[0..self.count]) |*made| if (made.config) |*config| config.deinit();
    }
};

/// Whether two lists hold the same values, in order.
fn stringsEql(a: []const [:0]const u8, b: []const [:0]const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Whether `a` and `b`, where two readings recorded their profile lines
/// (`_launch.profile_places`), read the same lines of the file `path` for
/// `key` (`profile-order` or `profile-hidden`): its values, clears too, in
/// order.
fn ownLinesEql(key: Config.Key, a: []const configpkg.pane_launch.ProfilePlace, b: []const configpkg.pane_launch.ProfilePlace, path: []const u8, same: origin.SamePath) bool {
    var it_a = OwnLines{ .places = a, .key = @tagName(key), .path = path, .same = same };
    var it_b = OwnLines{ .places = b, .key = @tagName(key), .path = path, .same = same };
    while (true) {
        const x = it_a.next();
        const y = it_b.next();
        if (x == null or y == null) return x == null and y == null;
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}

/// The values a reading recorded (`places`) for `key` from the file `path`,
/// a clear as "".
const OwnLines = struct {
    places: []const configpkg.pane_launch.ProfilePlace,
    key: []const u8,
    path: []const u8,
    same: origin.SamePath,
    at: usize = 0,

    fn next(self: *OwnLines) ?[]const u8 {
        const places = self.places;
        while (self.at < places.len) {
            const place = places[self.at];
            self.at += 1;
            if (!std.mem.eql(u8, place.key, self.key)) continue;
            switch (place.location) {
                .file => |file| if (self.same(file.path, self.path)) return place.id,
                else => {},
            }
        }
        return null;
    }
};

/// How the save's status names an edit's field: its key, the profile id and,
/// for `profile-env`, the variable's name. Never the value, which can hold a
/// secret.
pub fn writeEditName(writer: *std.Io.Writer, edit: Edit) !void {
    // A list is the key alone.
    if (edit.field.isList()) return writer.writeAll(@tagName(edit.field.key()));
    try writer.print("{s} {s}", .{ @tagName(edit.field.key()), edit.id });
    if (edit.name) |name| try writer.print(" {s}", .{name});
}

/// The edits a save of `pending` makes to the file `path` (`profileEdits`),
/// from `arena`; none, without indexing anything, when no profile changed.
///
/// `readings` are the config's layers as read: the config read last (the
/// app's) and, for a save, the files read again just before it. A removal
/// keeps a line (its tombstone, or a take-back) when any reading shows
/// another layer naming what is removed, and lines are deleted only when
/// none does: a read that went wrong can miss a definition (an include the
/// loader stopped reading partway through looks like its end, follow-up
/// CONFIG-READ-ERROR-TRUNCATES), but cannot invent one. Each reading is
/// taken in `state`, the light/dark state the app applies now
/// (`CoreApp.config_conditional_state`): a `theme = light:A,dark:B` file can
/// define a profile in one state only, `Config.load` hands over the light
/// one, and the state may have changed since Settings opened.
pub fn editsForSave(arena: Allocator, alloc: Allocator, readings: []const *const Config, state: configpkg.ConditionalState, original: *const Config, pending: *const Config, path: []const u8, same: origin.SamePath) ![]Edit {
    // `profile-order` and `profile-hidden` changed are written whole, after
    // the profiles' own edits.
    const lists = try listEdits(arena, original, pending);
    if (original.@"profile-command".equal(pending.@"profile-command") and
        original.@"profile-name".equal(pending.@"profile-name") and
        original.@"profile-working-directory".equal(pending.@"profile-working-directory") and
        original.@"profile-env".equal(pending.@"profile-env")) return lists;
    std.debug.assert(readings.len != 0 and readings.len <= max_readings);
    var conditioned: [max_readings]?Config = @splat(null);
    defer for (&conditioned) |*value| if (value.*) |*config| config.deinit();
    var indexes: [max_readings]origin.Index = undefined;
    var made: usize = 0;
    defer for (indexes[0..made]) |*index| index.deinit(alloc);
    for (readings, 0..) |reading, i| {
        conditioned[i] = try reading.changeConditionalState(state);
        indexes[i] = try origin.Index.init(alloc, if (conditioned[i]) |*config| config else reading);
        made += 1;
    }
    const edits = try profileEdits(arena, indexes[0..made], original, pending, path, same);
    if (lists.len == 0) return edits;
    return std.mem.concat(arena, Edit, &.{ edits, lists });
}

/// The most readings of the layers `editsForSave` takes.
const max_readings = 2;

/// Name each field of `edits` that `reloaded` masks (`editCheck`), comma
/// separated, after a separator when `after`. Returns `.masked` when it
/// named one, else `.unchecked` when the check was unavailable for one, else
/// `.held`.
pub fn writeMasked(writer: *std.Io.Writer, edits: []const Edit, reloaded: *const Config, after: bool) !Check {
    var separate = after;
    var found: Check = .held;
    for (edits) |edit| switch (editCheck(edit, reloaded)) {
        .held => {},
        .unchecked => if (found == .held) {
            found = .unchecked;
        },
        .masked => {
            if (separate) try writer.writeAll(", ");
            separate = true;
            found = .masked;
            try writeEditName(writer, edit);
        },
    };
    return found;
}

// Tests.

const testing = std.testing;

/// Assert two texts are the same without printing either: a profile's command
/// line or a variable's value can be a secret, and a failed
/// `expectEqualStrings` prints both strings. Every test of profile text uses
/// this, for row text, file bytes and messages alike.
fn expectSameText(expected: []const u8, actual: []const u8) !void {
    try testing.expect(std.mem.eql(u8, expected, actual));
}

fn testPatch(raw: []const u8, edits: []const Edit, expected: []const u8) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try patchProfileEdits(testing.allocator, raw, edits, &out);
    try expectSameText(expected, out.items);
}

test "settings patch: a field's last line is replaced, and another profile's lines are not touched" {
    // `py`'s label is replaced; `work`'s label after it stays. A rule of one
    // line per key would have replaced `work`'s.
    try testPatch(
        "# profiles\nprofile-command = py: cmd.exe\nprofile-name = py: Old\nprofile-command = work: pwsh.exe\nprofile-name = work: Work\n",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = "Python 3.12" } }},
        "# profiles\nprofile-command = py: cmd.exe\nprofile-name = py: Python 3.12\nprofile-command = work: pwsh.exe\nprofile-name = work: Work\n",
    );
    // Ids compare without case, and only the last of two lines changes.
    try testPatch(
        "profile-name = PY: First\nprofile-name = Py: Second\n",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = "Third" } }},
        "profile-name = PY: First\nprofile-name = py: Third\n",
    );
    // A whole value in quotes is read as the loader reads it, and the line
    // keeps its indentation.
    try testPatch(
        "  profile-working-directory = \"py: C:\\old\"\n",
        &.{.{ .field = .folder, .id = "py", .op = .{ .set = "home" } }},
        "  profile-working-directory = py: home\n",
    );
}

test "settings patch: a list is written whole, in place of the file's own lines for it" {
    const order: Edit = .{ .field = .order, .id = "", .op = .{ .list = &.{ "user:py", "pwsh.exe", "wsl:Ubuntu" } } };
    const hidden: Edit = .{ .field = .hidden, .id = "", .op = .{ .list = &.{"cmd.exe"} } };
    // The file's lines for the key, a clear among them, go; the block takes
    // the first one's place. Comments, other keys and a line for another key
    // that only starts the same stay.
    try testPatch(
        "font-size = 12\nprofile-order = cmd.exe\n# keep\nprofile-order =\n  profile-order = user:old\nprofile-orders = x\n",
        &.{order},
        "font-size = 12\nprofile-order =\nprofile-order = user:py\nprofile-order = pwsh.exe\nprofile-order = wsl:Ubuntu\n# keep\nprofile-orders = x\n",
    );
    // A file without the key gets a block at its end, after a blank line, in
    // the line ending most of its lines have.
    try testPatch(
        "font-size = 12\r\nprofile-command = py: python.exe\r\n",
        &.{ order, hidden },
        "font-size = 12\r\nprofile-command = py: python.exe\r\n\r\nprofile-order =\r\nprofile-order = user:py\r\nprofile-order = pwsh.exe\r\nprofile-order = wsl:Ubuntu\r\n\r\nprofile-hidden =\r\nprofile-hidden = cmd.exe\r\n",
    );
    // An empty list is the clear alone.
    try testPatch("profile-hidden = cmd.exe\n", &.{.{ .field = .hidden, .id = "", .op = .{ .list = &.{} } }}, "profile-hidden =\n");
    // A value that would not read back as written is refused, and nothing is
    // patched.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    for ([_][]const u8{ "", " pwsh.exe", "a\nprofile-order = b", "\"quoted\"" }) |bad| {
        try testing.expectError(error.UnwritableListValue, patchProfileEdits(testing.allocator, "x = 1\n", &.{.{ .field = .order, .id = "", .op = .{ .list = &.{bad} } }}, &out));
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "settings patch: a save that changed either list writes both, whole, and one that changed neither writes none" {
    const alloc = testing.allocator;
    var original = try Config.default(alloc);
    defer original.deinit();
    try original.@"profile-order".parseCLI(original._arena.?.allocator(), "pwsh.exe");
    try original.@"profile-hidden".parseCLI(original._arena.?.allocator(), "cmd.exe");
    var pending = try original.clone(alloc);
    defer pending.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = "C:\\noctty-test\\config";
    try testing.expectEqual(@as(usize, 0), (try editsForSave(arena, alloc, &.{&original}, .{}, &original, &pending, path, &testSamePath)).len);
    // The order changes: both lists are written whole, the hidden one as
    // the draft has it, so each is checked for another program's edit.
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "");
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "user:py");
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "pwsh.exe");
    const edits = try editsForSave(arena, alloc, &.{&original}, .{}, &original, &pending, path, &testSamePath);
    try testing.expectEqual(@as(usize, 2), edits.len);
    try testing.expect(edits[0].field == .order);
    try testing.expectEqual(@as(usize, 2), edits[0].op.list.len);
    try expectSameText("user:py", edits[0].op.list[0]);
    try expectSameText("pwsh.exe", edits[0].op.list[1]);
    try testing.expect(edits[1].field == .hidden);
    try testing.expectEqual(@as(usize, 1), edits[1].op.list.len);
    try expectSameText("cmd.exe", edits[1].op.list[0]);
    // With a profile's own edit, the lists come after it.
    try pending.@"profile-name".parseCLI(pending._arena.?.allocator(), "py: Python");
    try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py: python.exe");
    const both = try editsForSave(arena, alloc, &.{&original}, .{}, &original, &pending, path, &testSamePath);
    try testing.expect(both.len >= 3);
    try testing.expect(both[both.len - 2].field == .order and both[both.len - 1].field == .hidden);
    for (both[0 .. both.len - 2]) |e| try testing.expect(!e.field.isList());
}

test "settings patch: a list another program changed stops the save; one a later layer only adds to is held" {
    const alloc = testing.allocator;
    var original = try Config.default(alloc);
    defer original.deinit();
    try original.@"profile-order".parseCLI(original._arena.?.allocator(), "pwsh.exe");
    var pending = try original.clone(alloc);
    defer pending.deinit();
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "");
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "user:py");
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "pwsh.exe");
    const order: Edit = .{ .field = .order, .id = "", .op = .{ .list = &.{ "user:py", "pwsh.exe" } } };
    // Read again as Settings read it: no change under the edit.
    var disk = try original.clone(alloc);
    defer disk.deinit();
    try testing.expect(try changedUnder(&.{order}, &.of(&original), &pending, &disk, "", &testSamePath) == null);
    // Another program added to it since: the save stops, naming the key.
    try disk.@"profile-order".parseCLI(disk._arena.?.allocator(), "cmd.exe");
    const changed = try changedUnder(&.{order}, &.of(&original), &pending, &disk, "", &testSamePath) orelse return error.TestExpectedChange;
    var name: std.Io.Writer.Allocating = .init(alloc);
    defer name.deinit();
    try writeEditName(&name.writer, changed);
    try expectSameText("profile-order", name.written());

    // After the save: a later layer that adds to the order keeps what the
    // save named first, so it is held; one that cleared it or put another
    // order first is not.
    const Case = struct { values: []const []const u8, held: bool };
    for ([_]Case{
        .{ .values = &.{ "user:py", "pwsh.exe", "cmd.exe" }, .held = true },
        .{ .values = &.{ "USER:PY", "pwsh.exe" }, .held = true },
        .{ .values = &.{"cmd.exe"}, .held = false },
        .{ .values = &.{ "pwsh.exe", "user:py" }, .held = false },
    }) |case| {
        var reloaded = try Config.default(alloc);
        defer reloaded.deinit();
        for (case.values) |value| try reloaded.@"profile-order".parseCLI(reloaded._arena.?.allocator(), value);
        try testing.expectEqual(case.held, editHeld(order, &reloaded));
    }
    // For `profile-hidden`, an addition must name what the save hid: one
    // that hides another profile masks it.
    const hidden: Edit = .{ .field = .hidden, .id = "", .op = .{ .list = &.{"cmd.exe"} } };
    for ([_]Case{
        .{ .values = &.{ "cmd.exe", "CMD.EXE" }, .held = true },
        .{ .values = &.{ "cmd.exe", "wsl" }, .held = false },
        .{ .values = &.{}, .held = false },
    }) |case| {
        var reloaded = try Config.default(alloc);
        defer reloaded.deinit();
        for (case.values) |value| try reloaded.@"profile-hidden".parseCLI(reloaded._arena.?.allocator(), value);
        try testing.expectEqual(case.held, editHeld(hidden, &reloaded));
        if (!case.held) {
            var masked: std.Io.Writer.Allocating = .init(alloc);
            defer masked.deinit();
            try testing.expect(try writeMasked(&masked.writer, &.{hidden}, &reloaded, false) == .masked);
            try expectSameText("profile-hidden", masked.written());
        }
    }
    // An SSH alias in another case is another profile; its prefix in another
    // case is not.
    const hidden_ssh: Edit = .{ .field = .hidden, .id = "", .op = .{ .list = &.{"ssh:prod"} } };
    for ([_]Case{
        .{ .values = &.{ "ssh:prod", "SSH:prod" }, .held = true },
        .{ .values = &.{ "ssh:prod", "ssh:Prod" }, .held = false },
        .{ .values = &.{"ssh:Prod"}, .held = false },
    }) |case| {
        var reloaded = try Config.default(alloc);
        defer reloaded.deinit();
        for (case.values) |value| try reloaded.@"profile-hidden".parseCLI(reloaded._arena.?.allocator(), value);
        try testing.expectEqual(case.held, editHeld(hidden_ssh, &reloaded));
    }
}

test "settings patch: an edit to the file's own list lines that a later file masks stops the save" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "earlier", .data = "# read first\n" });
    try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "profile-order =\nprofile-order = pwsh.exe\n" });
    const later = try tmp.dir.realpathAlloc(alloc, "later.conf");
    defer alloc.free(later);
    const text = try std.fmt.allocPrint(alloc, "profile-order = cmd.exe\nconfig-file = {s}\n", .{later});
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const earlier = try tmp.dir.realpathAlloc(alloc, "earlier");
    defer alloc.free(earlier);
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    var original = try testLoad(alloc, earlier, path);
    defer original.deinit();
    var pending = try original.clone(alloc);
    defer pending.deinit();
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "");
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "user:py");
    const order: Edit = .{ .field = .order, .id = "", .op = .{ .list = &.{"user:py"} } };
    {
        // Nothing changed: the save goes on.
        var disk = try testLoad(alloc, earlier, path);
        defer disk.deinit();
        try testing.expect(try changedUnder(&.{order}, &.of(&original), &pending, &disk, path, &testSamePath) == null);
    }
    // Another program edits the file's own line, which the later file masks:
    // the list in effect is the same, and the save would write over it.
    for ([_][]const u8{ "profile-order = git-bash\n", "profile-order =\nprofile-order = cmd.exe\n" }) |own| {
        const changed = try std.fmt.allocPrint(alloc, "{s}config-file = {s}\n", .{ own, later });
        defer alloc.free(changed);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = changed });
        var disk = try testLoad(alloc, earlier, path);
        defer disk.deinit();
        try testing.expect(listEql(.order, &disk, &original));
        const stopped = try changedUnder(&.{order}, &.of(&original), &pending, &disk, path, &testSamePath) orelse return error.TestExpectedChange;
        try testing.expect(stopped.field == .order);
    }
}

test "settings patch: a dark theme's hidden list, read only because the app went dark, stops no save of the lists, changed or not" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
    // The dark theme hides another profile.
    try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "profile-hidden = pwsh.exe\n" });
    const light = try tmp.dir.realpathAlloc(alloc, "light");
    defer alloc.free(light);
    const dark = try tmp.dir.realpathAlloc(alloc, "dark");
    defer alloc.free(dark);
    const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\nprofile-hidden = cmd.exe\n", .{ light, dark });
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
    defer alloc.free(none);
    var original = try testLoad(alloc, none, path);
    defer original.deinit();
    var pending = try original.clone(alloc);
    defer pending.deinit();
    // Only the order changes; both blocks are written.
    try pending.@"profile-order".parseCLI(pending._arena.?.allocator(), "user:py");
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const edits = try editsForSave(arena_state.allocator(), alloc, &.{&original}, .{}, &original, &pending, path, &testSamePath);
    try testing.expectEqual(@as(usize, 2), edits.len);
    // The app runs dark: the fresh reading in its state hides PowerShell
    // too. The hidden list the draft left alone raises no conflict.
    var fresh = try testLoad(alloc, none, path);
    defer fresh.deinit();
    var switched = (try fresh.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
    defer switched.deinit();
    try testing.expect(!listEql(.hidden, &switched, &original));
    try testing.expect(try changedUnder(edits, &.of(&original), &pending, &switched, path, &testSamePath) == null);
    // A draft that changes the hidden list itself is not stopped by it
    // either: the reading is compared in the light state Settings read the
    // config in.
    {
        var hides = try original.clone(alloc);
        defer hides.deinit();
        try hides.@"profile-hidden".parseCLI(hides._arena.?.allocator(), "wsl");
        const hide_edits = try editsForSave(arena_state.allocator(), alloc, &.{&original}, .{}, &original, &hides, path, &testSamePath);
        try testing.expectEqual(@as(usize, 2), hide_edits.len);
        try testing.expect(try changedUnder(hide_edits, &.of(&original), &hides, &switched, path, &testSamePath) == null);
    }
    // Another program's edit to the file's lines still stops the save.
    const changed = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\nprofile-hidden = wsl\n", .{ light, dark });
    defer alloc.free(changed);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = changed });
    var edited = try testLoad(alloc, none, path);
    defer edited.deinit();
    var edited_dark = (try edited.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
    defer edited_dark.deinit();
    const stopped = try changedUnder(edits, &.of(&original), &pending, &edited_dark, path, &testSamePath) orelse return error.TestExpectedChange;
    try testing.expect(stopped.field == .hidden);
}

test "settings patch: an alias a later layer adds for a profile the save hid hides nothing more" {
    const alloc = testing.allocator;
    const profiles = [_]windows_shell.Profile{
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{} } },
        .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{} } },
    };
    var hidden: Edit = .{ .field = .hidden, .id = "", .op = .{ .list = &.{"pwsh.exe"} } };
    const Case = struct { added: []const u8, held_with_profiles: bool };
    for ([_]Case{
        // `pwsh` is PowerShell, which the save hid.
        .{ .added = "pwsh", .held_with_profiles = true },
        // `cmd` hides another profile: masked.
        .{ .added = "cmd", .held_with_profiles = false },
        // A value that names no profile listed is not known to hide nothing.
        .{ .added = "ssh:elsewhere", .held_with_profiles = false },
    }) |case| {
        var reloaded = try Config.default(alloc);
        defer reloaded.deinit();
        try reloaded.@"profile-hidden".parseCLI(reloaded._arena.?.allocator(), "pwsh.exe");
        try reloaded.@"profile-hidden".parseCLI(reloaded._arena.?.allocator(), case.added);
        // Without the profiles, the spelling decides.
        hidden.profiles = &.{};
        try testing.expect(!editHeld(hidden, &reloaded));
        hidden.profiles = &profiles;
        try testing.expectEqual(case.held_with_profiles, editHeld(hidden, &reloaded));
    }
}

test "settings patch: a variable is matched without case, and never written twice" {
    try testPatch(
        "profile-env = py: Path=C:\\a\nprofile-env = py: HOME=h\n",
        &.{.{ .field = .env, .id = "py", .name = "PATH", .op = .{ .set = "C:\\b" } }},
        "profile-env = py: PATH=C:\\b\nprofile-env = py: HOME=h\n",
    );
}

test "settings patch: a value goes after a later line that takes it back" {
    // `py:` takes back every variable of py, and `profile-name =` every
    // label: a value written before them would not take effect.
    try testPatch(
        "profile-env = py: K=1\nprofile-env = py:\nprofile-command = py: cmd.exe\n",
        &.{.{ .field = .env, .id = "py", .name = "K", .op = .{ .set = "2" } }},
        "profile-env = py: K=1\nprofile-env = py:\nprofile-command = py: cmd.exe\nprofile-env = py: K=2\n",
    );
    try testPatch(
        "profile-name = py: A\nprofile-name =\n# end\n",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = "B" } }},
        "profile-name = py: A\nprofile-name =\nprofile-name = py: B\n# end\n",
    );
}

test "settings patch: a new field joins its profile's lines, and a new profile gets a block at the end" {
    try testPatch(
        "profile-command = py: cmd.exe\nprofile-name = py: Python\n\nfont-size = 12\n",
        &.{.{ .field = .folder, .id = "py", .op = .{ .set = "~/src" } }},
        "profile-command = py: cmd.exe\nprofile-name = py: Python\nprofile-working-directory = py: ~/src\n\nfont-size = 12\n",
    );
    try testPatch(
        "font-size = 12",
        &.{
            .{ .field = .command, .id = "dev", .op = .{ .set = "pwsh.exe -NoLogo" } },
            .{ .field = .name, .id = "dev", .op = .{ .set = " Dev " } },
            .{ .field = .env, .id = "dev", .name = "MODE", .op = .{ .set = "x" } },
        },
        "font-size = 12\n\nprofile-command = dev: pwsh.exe -NoLogo\nprofile-name = dev: \" Dev \"\nprofile-env = dev: MODE=x\n",
    );
    // An empty file.
    try testPatch("", &.{.{ .field = .command, .id = "a", .op = .{ .set = "x.exe" } }}, "profile-command = a: x.exe\n");
}

test "settings patch: removing a profile deletes its lines, or writes its tombstone" {
    const text = "profile-command = py: cmd.exe\nprofile-name = py: P\nprofile-env = py: A=1\nprofile-env = py:\nprofile-command = keep: k.exe\nprofile-env = keep: A=1\nprofile-name =\n";
    // Defined only here: every line of py goes, `profile-name =` stays.
    try testPatch(text, &.{
        .{ .field = .command, .id = "PY", .op = .delete },
        .{ .field = .name, .id = "py", .op = .delete },
        .{ .field = .folder, .id = "py", .op = .delete },
        .{ .field = .env, .id = "py", .op = .delete },
    }, "profile-command = keep: k.exe\nprofile-env = keep: A=1\nprofile-name =\n");
    // Defined in another file too: the command line becomes the tombstone.
    try testPatch(text, &.{
        .{ .field = .command, .id = "py", .op = .unset },
        .{ .field = .name, .id = "py", .op = .delete },
        .{ .field = .env, .id = "py", .op = .delete },
    }, "profile-command = py:\nprofile-command = keep: k.exe\nprofile-env = keep: A=1\nprofile-name =\n");
    // A variable another file gives: its removal.
    try testPatch(
        "profile-command = py: cmd.exe\n",
        &.{.{ .field = .env, .id = "py", .name = "PATH", .op = .unset }},
        "profile-command = py: cmd.exe\nprofile-env = py: PATH=\n",
    );
}

test "settings patch: every other byte is kept" {
    // CRLF lines (and a new line takes CRLF), a byte order mark, a comment, a
    // blank line, a line the loader refuses (a reserved id), and no newline
    // at the end.
    try testPatch(
        "\xef\xbb\xbf# mine\r\n\r\nprofile-name = cmd: refused\r\nprofile-command = py: cmd.exe\r\nfont-size = 12",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = "P" } }},
        "\xef\xbb\xbf# mine\r\n\r\nprofile-name = cmd: refused\r\nprofile-command = py: cmd.exe\r\nprofile-name = py: P\r\nfont-size = 12",
    );
    // No edit: the same bytes.
    const odd = "a = b\r\n\n  # c\n\tprofile-command = x: y\nz";
    try testPatch(odd, &.{}, odd);
}

/// The four profile maps the `profile-*` lines of `text` give, read line by
/// line as the loader reads them.
const TestMaps = struct {
    command: profile_map.Command = .{},
    name: profile_map.Name = .{},
    folder: profile_map.Text = .{},
    env: profile_map.Env = .{},

    fn read(alloc: Allocator, text: []const u8) !TestMaps {
        var maps: TestMaps = .{};
        var reader: std.Io.Reader = .fixed(text);
        var lines: LineIterator = .{ .r = &reader };
        while (lines.next()) |arg| {
            const body = arg[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
            const field = Field.fromName(body[0..eq]) orelse continue;
            const value = body[eq + 1 ..];
            switch (field) {
                .command => maps.command.parseCLI(alloc, value) catch {},
                .name => maps.name.parseCLI(alloc, value) catch {},
                .folder => maps.folder.parseCLI(alloc, value) catch {},
                .env => maps.env.parseCLI(alloc, value) catch {},
                // `fromName` names a per-profile field only.
                .order, .hidden => unreachable,
            }
        }
        return maps;
    }

    /// The commands in the same order (the picker's), and every other field
    /// with the same value by id and variable: the order of the other maps'
    /// entries follows where lines are written, and nothing reads it.
    fn expectEqual(self: TestMaps, other: TestMaps) !void {
        try testing.expect(self.command.equal(other.command));
        inline for (.{ "name", "folder" }) |field| {
            for ([_]*const TestMaps{ &self, &other }) |maps| for (@field(maps, field).entries.items) |entry| {
                const a = @field(self, field).get(entry.id) orelse return error.TestExpectedEqual;
                const b = @field(other, field).get(entry.id) orelse return error.TestExpectedEqual;
                try expectSameText(a, b);
            };
        }
        for ([_]*const TestMaps{ &self, &other }) |maps| for (maps.env.entries.items) |entry| {
            const a = self.env.get(entry.id) orelse return error.TestExpectedEqual;
            const b = other.env.get(entry.id) orelse return error.TestExpectedEqual;
            try testing.expectEqual(a.count(), b.count());
            var it = a.iterator();
            while (it.next()) |kv| {
                var found = false;
                var other_it = b.iterator();
                while (other_it.next()) |okv| {
                    if (!std.ascii.eqlIgnoreCase(kv.key_ptr.*, okv.key_ptr.*)) continue;
                    try expectSameText(kv.value_ptr.*, okv.value_ptr.*);
                    found = true;
                }
                try testing.expect(found);
            }
        };
    }
};

test "settings patch: what a patched file reads back as is what the edits asked for" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const text = "profile-command = py: cmd.exe\nprofile-env = py: Path=a\nprofile-env = py:\nprofile-env = py: HOME=h\nprofile-name = work: W\nprofile-command = work: w.exe\n";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try patchProfileEdits(testing.allocator, text, &.{
        .{ .field = .env, .id = "py", .name = "path", .op = .{ .set = "b" } },
        .{ .field = .name, .id = "py", .op = .{ .set = "Python" } },
        .{ .field = .command, .id = "work", .op = .{ .set = "w2.exe" } },
        .{ .field = .env, .id = "py", .name = "HOME", .op = .delete },
    }, &out);
    const got = try TestMaps.read(alloc, out.items);
    // The same edits made to the maps the original file gives.
    var want = try TestMaps.read(alloc, text);
    try want.env.parseCLI(alloc, "py: path=b");
    try want.name.parseCLI(alloc, "py: Python");
    try want.command.parseCLI(alloc, "work: w2.exe");
    try want.env.parseCLI(alloc, "py: HOME=");
    try got.expectEqual(want);
}

/// Load `earlier` (a file read before the config file, as a default file
/// is), the config file `path` and the files it includes, as the app does.
fn testLoad(alloc: Allocator, earlier: []const u8, path: []const u8) !Config {
    var cfg = try Config.default(alloc);
    errdefer cfg.deinit();
    try cfg.loadFile(alloc, earlier);
    try cfg.loadFile(alloc, path);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();
    return cfg;
}

test "settings patch: an earlier file's lists are the save's to write, though the file it saves to is empty, comments only or not there" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A default file read first orders and hides profiles.
    try tmp.dir.writeFile(.{ .sub_path = "earlier", .data = "profile-order = cmd.exe\nprofile-hidden = pwsh.exe\n" });
    try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "profile-order = git-bash\n" });
    const earlier = try tmp.dir.realpathAlloc(alloc, "earlier");
    defer alloc.free(earlier);
    const later = try tmp.dir.realpathAlloc(alloc, "later.conf");
    defer alloc.free(later);
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "target" });
    defer alloc.free(path);
    const Target = enum { empty, comments, missing };
    for ([_]Target{ .empty, .comments, .missing }) |target| {
        tmp.dir.deleteFile("target") catch {};
        switch (target) {
            .empty => try tmp.dir.writeFile(.{ .sub_path = "target", .data = "" }),
            .comments => try tmp.dir.writeFile(.{ .sub_path = "target", .data = "# Settings saves here\n" }),
            .missing => {},
        }
        // As the app reads its default files: an empty or missing one is
        // skipped, and gives the loader no line.
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadFile(alloc, earlier);
        if (target == .comments) try cfg.loadFile(alloc, path);
        try cfg.finalize();
        try testing.expect(cfg.@"profile-order".list.items.len == 1);
        try testing.expectEqual(@as(?ListsForeign, null), try listsForeign(&cfg, path, &testSamePath));
        // A file that includes one setting the order still is a later one.
        var with_later = try Config.default(alloc);
        defer with_later.deinit();
        try with_later.loadFile(alloc, earlier);
        if (target == .comments) try with_later.loadFile(alloc, path);
        try with_later.@"config-file".parseCLI(with_later._arena.?.allocator(), later);
        try with_later.loadRecursiveFiles(alloc);
        try with_later.finalize();
        try testing.expectEqual(@as(?ListsForeign, .later_file), try listsForeign(&with_later, path, &testSamePath));
    }
    // A file `config-file` names: one it names before is earlier, one after
    // is later, the file Settings saves to empty or not there.
    try tmp.dir.writeFile(.{ .sub_path = "first.conf", .data = "profile-hidden = pwsh.exe\n" });
    const first = try tmp.dir.realpathAlloc(alloc, "first.conf");
    defer alloc.free(first);
    for ([_]Target{ .empty, .missing }) |target| {
        tmp.dir.deleteFile("target") catch {};
        if (target == .empty) try tmp.dir.writeFile(.{ .sub_path = "target", .data = "" });
        for ([_]struct { after: bool, want: ?ListsForeign }{
            .{ .after = false, .want = null },
            .{ .after = true, .want = .later_file },
        }) |case| {
            var cfg = try Config.default(alloc);
            defer cfg.deinit();
            const a = cfg._arena.?.allocator();
            const optional_target = try std.fmt.allocPrint(alloc, "?{s}", .{path});
            defer alloc.free(optional_target);
            if (case.after) {
                try cfg.@"config-file".parseCLI(a, optional_target);
                try cfg.@"config-file".parseCLI(a, first);
            } else {
                try cfg.@"config-file".parseCLI(a, first);
                try cfg.@"config-file".parseCLI(a, optional_target);
            }
            try cfg.loadRecursiveFiles(alloc);
            try cfg.finalize();
            try testing.expectEqual(case.want, try listsForeign(&cfg, path, &testSamePath));
        }
    }
}

test "settings patch: the load order is unknown, and the lists another layer's, when a file clears config-file" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);
    const path = try std.fs.path.join(alloc, &.{ dir, "target" });
    defer alloc.free(path);
    // (Terra) The file Settings saves to includes one that orders the
    // profiles and then clears `config-file`. That file still loads after
    // the target, but it is gone from the list that places it, and would
    // pass for a default file read before. The order is unknown: refused.
    try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "profile-order =\nprofile-order = cmd.exe\nconfig-file =\n" });
    const later = try tmp.dir.realpathAlloc(alloc, "later.conf");
    defer alloc.free(later);
    const text = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nconfig-file = {s}\n", .{later});
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "target", .data = text });
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadFile(alloc, path);
        try cfg.loadRecursiveFiles(alloc);
        try cfg.finalize();
        // Its lines are in the replay; its path is not in the list.
        try testing.expectEqual(@as(usize, 0), cfg.@"config-file".value.items.len);
        try testing.expectEqual(@as(usize, 1), cfg.@"profile-order".list.items.len);
        try testing.expectEqual(@as(?ListsForeign, .unordered), try listsForeign(&cfg, path, &testSamePath));
    }
    // A clear while no other file sets either list leaves the order moot.
    try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "font-size = 13\nconfig-file =\n" });
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadFile(alloc, path);
        try cfg.loadRecursiveFiles(alloc);
        try cfg.finalize();
        try testing.expectEqual(@as(?ListsForeign, null), try listsForeign(&cfg, path, &testSamePath));
    }
    // A file's quotes come off before the value is parsed: `config-file =
    // ""` clears the list too. `?""` (an optional path, empty once its quotes
    // are off) names no file and clears nothing, so the file stays placed.
    for ([_]struct { line: []const u8, kept: usize, want: ListsForeign }{
        .{ .line = "config-file = \"\"\n", .kept = 0, .want = .unordered },
        .{ .line = "config-file = ?\"\"\n", .kept = 1, .want = .later_file },
    }) |case| {
        const data = try std.fmt.allocPrint(alloc, "profile-order = cmd.exe\n{s}", .{case.line});
        defer alloc.free(data);
        try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = data });
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadFile(alloc, path);
        try cfg.loadRecursiveFiles(alloc);
        try cfg.finalize();
        try testing.expectEqual(case.kept, cfg.@"config-file".value.items.len);
        try testing.expectEqual(@as(?ListsForeign, case.want), try listsForeign(&cfg, path, &testSamePath));
    }
}

test "settings patch: the lists are another layer's when the command line, a later config file or one theme sets them" {
    const alloc = testing.allocator;
    const cli_args = @import("../../cli/args.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A file read first orders the profiles: the save's own to write over.
    try tmp.dir.writeFile(.{ .sub_path = "earlier", .data = "profile-order = cmd.exe\n" });
    try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "profile-order = git-bash\n" });
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "# light\n" });
    try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "profile-hidden = pwsh.exe\n" });
    try tmp.dir.writeFile(.{ .sub_path = "both", .data = "profile-hidden = pwsh.exe\n" });
    var names: [5][]u8 = undefined;
    for ([_][]const u8{ "earlier", "later.conf", "light", "dark", "both" }, &names) |name, *full| full.* = try tmp.dir.realpathAlloc(alloc, name);
    defer for (names) |full| alloc.free(full);
    const later_line = try std.fmt.allocPrint(alloc, "config-file = {s}\n", .{names[1]});
    defer alloc.free(later_line);
    const dark_line = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\n", .{ names[2], names[3] });
    defer alloc.free(dark_line);
    const both_line = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\n", .{ names[4], names[4] });
    defer alloc.free(both_line);
    const Case = struct { lines: []const u8, cli: []const []const u8 = &.{}, want: ?ListsForeign };
    for ([_]Case{
        // The file and the layers before it alone.
        .{ .lines = "", .want = null },
        // The command line clears the hidden list.
        .{ .lines = "", .cli = &.{"--profile-hidden="}, .want = .command_line },
        // The command line sets something else: no matter.
        .{ .lines = "", .cli = &.{"--font-size=13"}, .want = null },
        // A file the config file includes orders the profiles.
        .{ .lines = later_line, .want = .later_file },
        // The dark theme hides a profile the light one does not.
        .{ .lines = dark_line, .want = .theme },
        // Both themes hide it: the same in both states, an earlier layer.
        .{ .lines = both_line, .want = null },
    }) |case| {
        const text = try std.mem.concat(alloc, u8, &.{ "profile-command = py: python.exe\nprofile-hidden = cmd.exe\n", case.lines });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        // As the app loads them: the default files, the command line, the
        // files they include, then the theme.
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadFile(alloc, names[0]);
        try cfg.loadFile(alloc, path);
        var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(case.cli) };
        try cfg.loadIter(alloc, &args);
        try cfg.loadRecursiveFiles(alloc);
        try cfg.finalize();
        try testing.expectEqual(case.want, try listsForeign(&cfg, path, &testSamePath));
    }
    // The file a `--config-file` names, which the loader reads after the
    // command line: a command-line list is still this launch's alone, and
    // the file does not set the order itself.
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "profile-command = py: python.exe\nprofile-hidden = cmd.exe\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const config_arg = try std.fmt.allocPrint(alloc, "--config-file={s}", .{path});
    defer alloc.free(config_arg);
    const Cli = struct { args: []const []const u8, want: ?ListsForeign };
    for ([_]Cli{
        .{ .args = &.{ "--profile-order=cmd.exe", config_arg }, .want = .command_line },
        .{ .args = &.{ config_arg, "--profile-hidden=" }, .want = .command_line },
        // `--config-file` itself sets no list.
        .{ .args = &.{config_arg}, .want = null },
    }) |case| {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadFile(alloc, names[0]);
        var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(case.args) };
        try cfg.loadIter(alloc, &args);
        try cfg.loadRecursiveFiles(alloc);
        try cfg.finalize();
        try testing.expectEqual(case.want, try listsForeign(&cfg, path, &testSamePath));
    }
}

fn testSamePath(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "settings patch: profileEdits writes what the editor staged, and the loader reads it back" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Read before the config file: py, and a variable of it.
    try tmp.dir.writeFile(.{ .sub_path = "earlier.conf", .data = "profile-command = py: early.exe\nprofile-env = py: E=1\n" });
    // Read after it: team, and its label.
    try tmp.dir.writeFile(.{ .sub_path = "x.conf", .data = "profile-command = team: t.exe\nprofile-name = team: Team\n" });
    const text = "# mine\nprofile-command = py: cmd.exe\nprofile-name = py: P\nprofile-command = solo: s.exe\nprofile-env = solo: K=1\nconfig-file = x.conf\n";
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const earlier = try tmp.dir.realpathAlloc(alloc, "earlier.conf");
    defer alloc.free(earlier);

    var original = try testLoad(alloc, earlier, path);
    defer original.deinit();
    var pending = try original.clone(alloc);
    defer pending.deinit();
    const arena = pending._arena.?.allocator();
    // Remove py (a file read before this one defines it too) and solo (only
    // here, with a variable), relabel team (a file read later labels it),
    // and add dev.
    try pending.@"profile-command".parseCLI(arena, "py:");
    try pending.@"profile-command".parseCLI(arena, "solo:");
    try pending.@"profile-name".parseCLI(arena, "team: Mine");
    try pending.@"profile-command".parseCLI(arena, "dev: d.exe /k");
    try pending.@"profile-name".parseCLI(arena, "dev: Dev");
    try pending.@"profile-env".parseCLI(arena, "dev: MODE=1");

    var problems = try origin.Index.init(alloc, &original);
    defer problems.deinit(alloc);
    var edit_arena: std.heap.ArenaAllocator = .init(alloc);
    defer edit_arena.deinit();
    const edits = try profileEdits(edit_arena.allocator(), &.{problems}, &original, &pending, path, &testSamePath);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try patchProfileEdits(alloc, text, edits, &out);
    // py keeps a tombstone, since the file read before this one defines it;
    // solo's lines go; dev gets a block, and so does team's label, which
    // this file had no line for.
    try expectSameText(
        "# mine\nprofile-command = py:\nconfig-file = x.conf\n\nprofile-command = dev: d.exe /k\nprofile-name = dev: Dev\nprofile-env = dev: MODE=1\n\nprofile-name = team: Mine\n",
        out.items,
    );

    try tmp.dir.writeFile(.{ .sub_path = "config", .data = out.items });
    var reloaded = try testLoad(alloc, earlier, path);
    defer reloaded.deinit();
    try testing.expect(reloaded.@"profile-command".get("py") == null);
    try testing.expect(reloaded.@"profile-command".get("solo") == null);
    try expectSameText("d.exe /k", reloaded.@"profile-command".get("dev").?);
    try expectSameText("Dev", reloaded.@"profile-name".get("dev").?);
    try expectSameText("1", reloaded.@"profile-env".get("dev").?.map.get("MODE").?);
    // The file read later still gives team's label: the edit is masked, and
    // the status names that field alone.
    try expectSameText("Team", reloaded.@"profile-name".get("team").?);
    var masked: std.Io.Writer.Allocating = .init(alloc);
    defer masked.deinit();
    try testing.expect(try writeMasked(&masked.writer, edits, &reloaded, false) == .masked);
    try expectSameText("profile-name team", masked.written());

    // A save works out the same edits, and none when nothing changed.
    const again = try editsForSave(edit_arena.allocator(), alloc, &.{&original}, .{}, &original, &pending, path, &testSamePath);
    try testing.expectEqual(edits.len, again.len);
    try testing.expectEqual(@as(usize, 0), (try editsForSave(edit_arena.allocator(), alloc, &.{&original}, .{}, &original, &original, path, &testSamePath)).len);
}

test "settings patch: lines are read as the loader reads them" {
    // `" "` is an empty value once its quotes go (`parseCLI` trims): it takes
    // every label back, so the new label goes after it.
    try testPatch(
        "profile-name = py: A\nprofile-name = \" \"\n",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = "B" } }},
        "profile-name = py: A\nprofile-name = \" \"\nprofile-name = py: B\n",
    );
    // A last line without a newline loses a CR at its end, as the reader's
    // trim does: it is the label's line, replaced in place.
    try testPatch(
        "profile-name = py: A\r",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = "B" } }},
        "profile-name = py: B",
    );
    // A line longer than the reader takes is skipped by the loader: never
    // matched, never changed.
    const long = "profile-name = py: " ++ "x" ** 4080;
    try testPatch(
        long ++ "\n",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = "B" } }},
        long ++ "\n\nprofile-name = py: B\n",
    );
    // A line replaced in place keeps its indentation unless that would make
    // it longer than the reader takes.
    const value = "y" ** 4073;
    try testPatch(
        "    profile-name = py: A\n",
        &.{.{ .field = .name, .id = "py", .op = .{ .set = value } }},
        "profile-name = py: " ++ value ++ "\n",
    );
}

test "settings patch: a line the loader skips for its two CRs is never matched or changed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // 4,096 bytes before the LF: one more than the reader holds, so the
    // loader skips the line, though less one CR it would be 4,095.
    const refused = "profile-name = py: " ++ "x" ** 4075 ++ "\r\r";
    try testing.expectEqual(@as(usize, LineIterator.max_line_len + 2), refused.len);
    const raw = "profile-command = py: python.exe\r\n" ++ refused ++ "\n";
    var reader: std.Io.Reader = .fixed(raw);
    var lines: LineIterator = .{ .r = &reader };
    try expectSameText("--profile-command=py: python.exe", lines.next().?);
    try testing.expect(lines.next().?.ptr == LineIterator.skipped_line.ptr);
    try testing.expect(lines.next() == null);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(testing.allocator);
    try patchProfileEdits(testing.allocator, raw, &.{.{ .field = .name, .id = "py", .op = .{ .set = "Python" } }}, &out);
    // The skipped line's bytes are kept, and the label goes after the
    // profile's last line the loader reads.
    try expectSameText("profile-command = py: python.exe\r\nprofile-name = py: Python\r\n" ++ refused ++ "\n", out.items);
    const got = try TestMaps.read(alloc, out.items);
    try expectSameText("Python", got.name.get("py").?);
}

test "settings patch: FileEnd hands the patchers a complete, marked last line, and its ending stays with that line" {
    const alloc = testing.allocator;
    // A file that ends in a line ending is handed over as it is; one that
    // does not gets its last line ended and marked, and comes back the same
    // when nothing is patched.
    for ([_]struct { raw: []const u8, end: FileEnd }{
        .{ .raw = "", .end = .terminated },
        .{ .raw = "\xef\xbb\xbf", .end = .terminated },
        .{ .raw = "a\n", .end = .terminated },
        .{ .raw = "a\r\n", .end = .terminated },
        .{ .raw = "a", .end = .none },
        .{ .raw = "a\r\nb", .end = .none },
        .{ .raw = "\xef\xbb\xbfa\r\nb", .end = .none },
        .{ .raw = "\xef\xbb\xbfb", .end = .none },
        .{ .raw = "a\r", .end = .bare_cr },
        .{ .raw = "a\nb\r", .end = .bare_cr },
    }) |case| {
        try testing.expectEqual(case.end, FileEnd.of(case.raw));
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try case.end.terminate(alloc, case.raw, &out);
        if (case.end == .terminated) try expectSameText(case.raw, out.items) else {
            // Every line ends; the last line sits between the marks.
            try testing.expect(std.mem.endsWith(u8, out.items, "\n"));
            try testing.expect(std.mem.indexOf(u8, out.items, FileEnd.before_last) != null);
        }
        try case.end.restore(&out);
        try expectSameText(case.raw, out.items);
    }
    // The last line deleted: nothing is taken off, so the blank line before
    // it keeps its LF. Kept, with a line added after it: the added line ends
    // as the file did.
    for ([_]struct { raw: []const u8, delete_last: bool, append: []const u8, restored: []const u8 }{
        .{ .raw = "# keep\n\nlast", .delete_last = true, .append = "", .restored = "# keep\n\n" },
        .{ .raw = "# keep\r\n\r\nlast", .delete_last = true, .append = "", .restored = "# keep\r\n\r\n" },
        .{ .raw = "a\nlast", .delete_last = true, .append = "new\n", .restored = "a\nnew\n" },
        .{ .raw = "last", .delete_last = true, .append = "", .restored = "" },
        .{ .raw = "a\nlast\r", .delete_last = true, .append = "", .restored = "a\n" },
        .{ .raw = "a\nlast", .delete_last = false, .append = "new\n", .restored = "a\nlast\nnew" },
        .{ .raw = "a\r\nlast\r", .delete_last = false, .append = "new\r\n", .restored = "a\r\nlast\r\nnew\r" },
    }) |case| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        const end_kind = FileEnd.of(case.raw);
        try end_kind.terminate(alloc, case.raw, &out);
        // What the patchers would do: take out the marked line, add at the
        // end.
        if (case.delete_last) {
            const from = std.mem.indexOf(u8, out.items, FileEnd.before_last).?;
            const first = FileEnd.lineEnd(out.items, from);
            const to = FileEnd.lineEnd(out.items, first);
            FileEnd.removeRange(&out, first, to);
        }
        try out.appendSlice(alloc, case.append);
        try end_kind.restore(&out);
        try expectSameText(case.restored, out.items);
    }
}

/// A config file `theme = light:<light>,dark:<dark>` that defines `py`, in
/// `tmp` as `config`, where only the dark theme defines `py` too. Returns its
/// path, the caller's to free.
fn testThemedProfile(tmp: *std.testing.TmpDir) ![]u8 {
    const alloc = testing.allocator;
    try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "profile-command = py: python.exe -X dark\n" });
    const light = try tmp.dir.realpathAlloc(alloc, "light");
    defer alloc.free(light);
    const dark = try tmp.dir.realpathAlloc(alloc, "dark");
    defer alloc.free(dark);
    const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, dark });
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    return tmp.dir.realpathAlloc(alloc, "config");
}

/// The op `editsForSave` gives the removal of `py`'s command, read from
/// `readings` in `state`, for a draft made in `opened`.
fn testRemovalOp(readings: []const *const Config, state: configpkg.ConditionalState, opened: *const Config, path: []const u8) !Edit.Op {
    const alloc = testing.allocator;
    var pending = try opened.clone(alloc);
    defer pending.deinit();
    try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
    var edit_arena: std.heap.ArenaAllocator = .init(alloc);
    defer edit_arena.deinit();
    const edits = try editsForSave(edit_arena.allocator(), alloc, readings, state, opened, &pending, path, &testSamePath);
    for (edits) |e| if (e.field == .command) return e.op;
    return error.TestExpectedRemoval;
}

test "settings patch: FileEnd.restore matches only whole mark lines, and fails when a mark or a NUL is left" {
    const alloc = testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try FileEnd.none.terminate(alloc, "a\nlast", &out);
    // A line that holds the second mark's text inside it, ahead of the real
    // mark, is not taken for it; the mark goes, the NUL it holds stays, and
    // the save fails.
    const planted = "profile-env = py: " ++ FileEnd.after_last ++ "=\n";
    const at = std.mem.indexOf(u8, out.items, FileEnd.before_last).?;
    const first = FileEnd.lineEnd(out.items, at);
    try out.insertSlice(alloc, FileEnd.lineEnd(out.items, first), planted);
    try testing.expectError(error.MarksDisturbed, FileEnd.none.restore(&out));
    // A mark that is gone fails it too.
    out.clearRetainingCapacity();
    try out.appendSlice(alloc, "a\nlast\n");
    try testing.expectError(error.MarksDisturbed, FileEnd.none.restore(&out));
    try testing.expectError(error.MarksDisturbed, FileEnd.bare_cr.restore(&out));
}

test "settings patch: a theme the light/dark switch could not open is named, a missing one is not" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "profile-command = py: python.exe -X dark\n" });
    const light = try tmp.dir.realpathAlloc(alloc, "light");
    defer alloc.free(light);
    const dark = try tmp.dir.realpathAlloc(alloc, "dark");
    defer alloc.free(dark);
    const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, dark });
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
    defer alloc.free(none);
    var fresh = try testLoad(alloc, none, path);
    defer fresh.deinit();
    try testing.expect(unreadConfigFile(&fresh) == null);
    // Another program holds the dark theme with no sharing as the switch to
    // dark reads it, after the save's probe: it does not open.
    {
        const wide = try std.os.windows.sliceToPrefixedFileW(null, dark);
        const handle = std.os.windows.kernel32.CreateFileW(wide.span().ptr, std.os.windows.GENERIC_READ, 0, null, std.os.windows.OPEN_EXISTING, 0, null);
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.CouldNotHoldFile;
        defer std.os.windows.CloseHandle(handle);
        var switched = (try fresh.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
        defer switched.deinit();
        const unread = unreadConfigFile(&switched) orelse return error.TestExpectedUnread;
        try testing.expect(unread.kind == .theme);
        try expectSameText(dark, unread.path);
    }
    // Every other case through the loader as well, so a change to its
    // wording fails here: a dark theme by name, searched for in the user's
    // theme directory (`XDG_CONFIG_HOME` points at this test's for its
    // length, then back), and by path.
    const os = @import("../../os/main.zig");
    if (try os.xdg.portableRoot(alloc)) |portable| {
        alloc.free(portable);
        return error.SkipZigTest;
    }
    const saved: ?[:0]u8 = saved: {
        const value = std.process.getEnvVarOwned(alloc, "XDG_CONFIG_HOME") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :saved null,
            else => return err,
        };
        defer alloc.free(value);
        break :saved try alloc.dupeZ(u8, value);
    };
    defer if (saved) |value| alloc.free(value);
    defer _ = if (saved) |value| os.setenv("XDG_CONFIG_HOME", value) else os.unsetenv("XDG_CONFIG_HOME");
    const themes_dir = try std.fs.path.join(alloc, &.{ "xdg", @import("../../build_config.zig").data_dir_name, "themes" });
    defer alloc.free(themes_dir);
    try tmp.dir.makePath(themes_dir);
    var themes = try tmp.dir.openDir(themes_dir, .{});
    defer themes.close();
    try themes.writeFile(.{ .sub_path = "Mine", .data = "font-size = 14\n" });
    try themes.makeDir("Dir");
    try tmp.dir.makeDir("dir");
    const xdg_path = try tmp.dir.realpathAlloc(alloc, "xdg");
    defer alloc.free(xdg_path);
    const xdg = try alloc.dupeZ(u8, xdg_path);
    defer alloc.free(xdg);
    try testing.expectEqual(@as(c_int, 0), os.setenv("XDG_CONFIG_HOME", xdg));
    const mine = try themes.realpathAlloc(alloc, "Mine");
    defer alloc.free(mine);
    const gone = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(dark) orelse return error.TestExpectedDir, "gone" });
    defer alloc.free(gone);
    const dir = try tmp.dir.realpathAlloc(alloc, "dir");
    defer alloc.free(dir);
    const check = struct {
        /// The switch to dark, with `dark_theme` as the dark half, names
        /// `expected` as the unread theme, or nothing when it is null.
        fn darkTheme(a: Allocator, at: std.fs.Dir, earlier: []const u8, light_theme: []const u8, dark_theme: []const u8, expected: ?[]const u8) !void {
            const config_text = try std.fmt.allocPrint(a, "theme = light:{s},dark:{s}\n", .{ light_theme, dark_theme });
            defer a.free(config_text);
            try at.writeFile(.{ .sub_path = "config", .data = config_text });
            const config_path = try at.realpathAlloc(a, "config");
            defer a.free(config_path);
            var loaded = try testLoad(a, earlier, config_path);
            defer loaded.deinit();
            var switched = (try loaded.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
            defer switched.deinit();
            const unread = unreadConfigFile(&switched);
            if (expected) |want| {
                const got = unread orelse return error.TestExpectedUnread;
                try testing.expect(got.kind == .theme);
                try expectSameText(want, got.path);
            } else if (unread != null) return error.TestUnexpectedUnread;
        }
    }.darkTheme;
    // Not there, or a directory: the loader's to report, not named.
    try check(alloc, tmp.dir, none, light, gone, null);
    try check(alloc, tmp.dir, none, light, dir, null);
    try check(alloc, tmp.dir, none, light, "Gone", null);
    try check(alloc, tmp.dir, none, light, "Dir", null);
    // Found by name and held with no sharing: named, by the path it was
    // found at.
    try check(alloc, tmp.dir, none, light, "Mine", null);
    const wide = try std.os.windows.sliceToPrefixedFileW(null, mine);
    const handle = std.os.windows.kernel32.CreateFileW(wide.span().ptr, std.os.windows.GENERIC_READ, 0, null, std.os.windows.OPEN_EXISTING, 0, null);
    if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.CouldNotHoldFile;
    defer std.os.windows.CloseHandle(handle);
    try check(alloc, tmp.dir, none, light, "Mine", mine);
}

test "settings patch: an include whose read failed is still named after the light/dark switch" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "font-size = 13\n" });
    try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "font-size = 14\n" });
    try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "copy-on-select = true\n" });
    try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
    const light = try tmp.dir.realpathAlloc(alloc, "light");
    defer alloc.free(light);
    const dark = try tmp.dir.realpathAlloc(alloc, "dark");
    defer alloc.free(dark);
    const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
    defer alloc.free(more);
    const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
    defer alloc.free(none);
    const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nconfig-file = {s}\n", .{ light, dark, more });
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    // The include's bytes are locked while the layers are read.
    var lock = try tmp.dir.openFile("more.conf", .{ .mode = .read_write, .lock = .exclusive });
    var loaded = blk: {
        defer lock.close();
        break :blk try testLoad(alloc, none, path);
    };
    defer loaded.deinit();
    try testing.expect(unreadConfigFile(&loaded) != null);
    // The switch to dark replays the layers; the include is still named.
    var switched = (try loaded.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
    defer switched.deinit();
    const unread = unreadConfigFile(&switched) orelse return error.TestExpectedUnread;
    try expectSameText(more, unread.path);
}

test "settings patch: a profile's variables compare without case, and a removal covers its other fields" {
    const alloc = testing.allocator;
    var original = try Config.default(alloc);
    defer original.deinit();
    try original.@"profile-command".parseCLI(original._arena.?.allocator(), "py: python.exe");
    try original.@"profile-env".parseCLI(original._arena.?.allocator(), "py: Path=C:\\bin");
    var pending = try original.clone(alloc);
    defer pending.deinit();
    var disk = try original.clone(alloc);
    defer disk.deinit();
    // Another program wrote the same variable with its name in capitals.
    try disk.@"profile-env".parseCLI(disk._arena.?.allocator(), "py:");
    try disk.@"profile-env".parseCLI(disk._arena.?.allocator(), "py: PATH=C:\\bin");
    const whole: Edit = .{ .field = .env, .id = "py", .op = .delete };
    try testing.expect(try changedUnder(&.{whole}, &.of(&original), &pending, &disk, "", &testSamePath) == null);
    // A value that did change is one.
    var changed = try original.clone(alloc);
    defer changed.deinit();
    try changed.@"profile-env".parseCLI(changed._arena.?.allocator(), "py:");
    try changed.@"profile-env".parseCLI(changed._arena.?.allocator(), "py: PATH=D:\\bin");
    try testing.expect(try changedUnder(&.{whole}, &.of(&original), &pending, &changed, "", &testSamePath) != null);
    // The same field, deleted only because the profile is removed: covered.
    const with_profile: Edit = .{ .field = .env, .id = "py", .op = .delete, .with_profile = true };
    try testing.expect(try changedUnder(&.{with_profile}, &.of(&original), &pending, &changed, "", &testSamePath) == null);
}

test "settings patch: a config file that did not decode is still named after the light/dark switch, and a theme alone is asked of the switch" {
    const alloc = testing.allocator;
    var config = try Config.default(alloc);
    defer config.deinit();
    const arena = config._arena.?.allocator();
    // What `Config.invalidUtf16` records for a config file, as a replay brings
    // it back without the marker.
    try config._diagnostics.append(arena, .{ .message = try arena.dupeZ(u8, "config-file C:\\noctty-test\\more.conf is not valid UTF-16; not reading it. Save it as UTF-8") });
    const unread = unreadConfigFile(&config) orelse return error.TestExpectedUnread;
    try testing.expect(unread.undecodable and unread.kind == .include);
    try expectSameText("C:\\noctty-test\\more.conf", unread.path);
    // A config file's problem is not the theme's.
    try testing.expect(unreadTheme(&config) == null);
    try config._diagnostics.append(arena, .{ .message = try arena.dupeZ(u8, "error reading theme C:\\noctty-test\\dark: error.ReadFailed") });
    try expectSameText("C:\\noctty-test\\dark", (unreadTheme(&config) orelse return error.TestExpectedUnread).path);
}

test "settings patch: the report after a save names a file only the reload as read records as undecodable" {
    const alloc = testing.allocator;
    var masked: std.Io.Writer.Allocating = .init(alloc);
    defer masked.deinit();
    // The light/dark switch drops the record; the reload as read has it.
    var loaded = try Config.default(alloc);
    defer loaded.deinit();
    loaded._undecodable_file = try loaded._arena.?.allocator().dupeZ(u8, "C:\\noctty-test\\more.conf");
    var switched = try Config.default(alloc);
    defer switched.deinit();
    switch (try reloadReport(&masked.writer, &.{}, &switched, &loaded, false)) {
        .unread => |unread| {
            try testing.expect(unread.undecodable);
            try expectSameText("C:\\noctty-test\\more.conf", unread.path);
        },
        else => return error.TestExpectedUnread,
    }
    // With neither reading recording one, nothing.
    var clean = try Config.default(alloc);
    defer clean.deinit();
    try testing.expect(try reloadReport(&masked.writer, &.{}, &switched, &clean, false) == .held);
}

test "settings patch: a default config file that did not decode is named as the config file, before and after the light/dark switch" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\xff\xfe\x00\xd8a\x00" });
    try tmp.dir.writeFile(.{ .sub_path = "light", .data = "font-size = 13\n" });
    try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "font-size = 14\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const light = try tmp.dir.realpathAlloc(alloc, "light");
    defer alloc.free(light);
    const dark = try tmp.dir.realpathAlloc(alloc, "dark");
    defer alloc.free(dark);
    const themes_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\n", .{ light, dark });
    defer alloc.free(themes_text);
    try tmp.dir.writeFile(.{ .sub_path = "themes", .data = themes_text });
    const themes = try tmp.dir.realpathAlloc(alloc, "themes");
    defer alloc.free(themes);
    // The default config file is skipped whole; a later file names the
    // themes, so the config has a light/dark switch to make.
    var loaded = try Config.default(alloc);
    defer loaded.deinit();
    _ = loaded.loadOptionalFile(alloc, path);
    try loaded.loadFile(alloc, themes);
    try loaded.finalize();
    var switched = (try loaded.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
    defer switched.deinit();
    const expected = try std.fmt.allocPrint(alloc, "the config file {s}", .{path});
    defer alloc.free(expected);
    var masked: std.Io.Writer.Allocating = .init(alloc);
    defer masked.deinit();
    // As the status after a save names it: from the load, which records the
    // file, and from the reading in the other state, which has only the
    // problem the switch replays.
    for ([_]*const Config{ &loaded, &switched }) |reading| {
        switch (try reloadReport(&masked.writer, &.{}, reading, reading, false)) {
            .unread => |unread| {
                try testing.expect(unread.undecodable);
                const text = try unread.describe(alloc);
                defer alloc.free(text);
                try expectSameText(expected, text);
            },
            else => return error.TestExpectedUnread,
        }
    }
}

test "settings patch: a reload that could not read a file whole reports the file, not an override" {
    const alloc = testing.allocator;
    const edits = [_]Edit{.{ .field = .name, .id = "py", .op = .{ .set = "Python" } }};
    // The reload's read of the included file failed partway, before the
    // saved label: the label is missing, and that is no override.
    var reload = try Config.default(alloc);
    defer reload.deinit();
    var buf: [16]u8 = undefined;
    var failing = @import("../../cli/args.zig").TestFailingReader.init("profile-command = py: python.exe\nprofile-na", &buf);
    try reload.loadReader(alloc, &failing.interface, "C:\\noctty-test\\more.conf");
    var masked: std.Io.Writer.Allocating = .init(alloc);
    defer masked.deinit();
    switch (try reloadReport(&masked.writer, &edits, &reload, &reload, false)) {
        .unread => |unread| {
            const text = try unread.describe(alloc);
            defer alloc.free(text);
            try expectSameText("the included file C:\\noctty-test\\more.conf", text);
        },
        else => return error.TestExpectedUnread,
    }
    try testing.expectEqual(@as(usize, 0), masked.written().len);
    // Read whole, the same missing label is an override, named.
    var whole = try Config.default(alloc);
    defer whole.deinit();
    var reader: std.Io.Reader = .fixed("profile-command = py: python.exe\n");
    try whole.loadReader(alloc, &reader, "C:\\noctty-test\\more.conf");
    try testing.expect(try reloadReport(&masked.writer, &edits, &whole, &whole, false) == .masked);
    try expectSameText("profile-name py", masked.written());
    // A save of ordinary settings alone is told the same: it used to be
    // `.held`, and the partial reload was applied.
    try testing.expect(try reloadReport(&masked.writer, &.{}, &reload, &reload, false) == .unread);
    try testing.expect(try reloadReport(&masked.writer, &.{}, &whole, &whole, false) == .held);
}

test "settings patch: a removal is decided in the light/dark state the app applies, so a profile only the dark theme defines keeps its tombstone" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testThemedProfile(&tmp);
    defer alloc.free(path);
    const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
    defer alloc.free(none);
    // What a read from disk hands over: the light state.
    var layers = try testLoad(alloc, none, path);
    defer layers.deinit();
    try testing.expectEqual(@TypeOf(layers._conditional_state.theme).light, layers._conditional_state.theme);
    var dark = (try layers.changeConditionalState(.{ .theme = .dark })).?;
    defer dark.deinit();

    // Dark: the dark theme still defines `py`, so its line becomes the
    // tombstone. Light: nothing else does, and the line goes.
    try testing.expectEqual(Edit.Op.unset, std.meta.activeTag(try testRemovalOp(&.{&layers}, .{ .theme = .dark }, &dark, path)));
    try testing.expectEqual(Edit.Op.delete, std.meta.activeTag(try testRemovalOp(&.{&layers}, .{ .theme = .light }, &layers, path)));
    // A reload in the dark state holds the dark theme's `py`: the masking
    // check names a deletion it would have undone.
    var masked: std.Io.Writer.Allocating = .init(alloc);
    defer masked.deinit();
    const deletion = [_]Edit{.{ .field = .command, .id = "py", .op = .delete }};
    try testing.expect(try writeMasked(&masked.writer, &deletion, &dark, false) == .masked);
    try expectSameText("profile-command py", masked.written());
}

test "settings patch: a removal made in Settings opened in one light/dark state is decided in the one the app switched to, for a profile and each of its fields" {
    const alloc = testing.allocator;
    const Theme = @FieldType(configpkg.ConditionalState, "theme");
    const defines = "profile-command = py: python.exe -X theme\nprofile-name = py: Themed\nprofile-working-directory = py: C:\\theme\nprofile-env = py: V=theme\n";
    for ([_][2]Theme{ .{ .light, .dark }, .{ .dark, .light } }) |pair| {
        const opened_in, const now = pair;
        errdefer std.debug.print("opened in {t}, now {t}\n", .{ opened_in, now });
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        // Only the theme of the state the app switched to defines `py` and
        // its fields again.
        try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = if (now == .light) defines else "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = if (now == .dark) defines else "\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\nprofile-name = py: Python\nprofile-working-directory = py: C:\\src\nprofile-env = py: V=1\n", .{ light, dark });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
        defer alloc.free(none);
        // The save's fresh read: the light state, as `Config.load` hands it.
        var fresh = try testLoad(alloc, none, path);
        defer fresh.deinit();
        // The config Settings opened on, in the state it was then.
        var opened = (try fresh.changeConditionalState(.{ .theme = opened_in })) orelse try fresh.clone(alloc);
        defer opened.deinit();

        // The whole profile: decided now, the theme keeps its tombstone; in
        // the state Settings opened in, the line would go.
        try testing.expectEqual(Edit.Op.unset, std.meta.activeTag(try testRemovalOp(&.{&fresh}, .{ .theme = now }, &opened, path)));
        try testing.expectEqual(Edit.Op.delete, std.meta.activeTag(try testRemovalOp(&.{&fresh}, .{ .theme = opened_in }, &opened, path)));

        // Its name, folder and variable taken out, the profile kept.
        var pending = try opened.clone(alloc);
        defer pending.deinit();
        pending.@"profile-name".remove("py");
        pending.@"profile-working-directory".remove("py");
        try pending.@"profile-env".parseCLI(pending._arena.?.allocator(), "py: V=");
        for ([_]struct { Theme, Edit.Op }{ .{ now, .unset }, .{ opened_in, .delete } }) |decided| {
            var edit_arena: std.heap.ArenaAllocator = .init(alloc);
            defer edit_arena.deinit();
            const edits = try editsForSave(edit_arena.allocator(), alloc, &.{&fresh}, .{ .theme = decided[0] }, &opened, &pending, path, &testSamePath);
            var seen: usize = 0;
            for (edits) |e| {
                try testing.expect(e.field != .command);
                try testing.expectEqual(std.meta.activeTag(decided[1]), std.meta.activeTag(e.op));
                seen += 1;
            }
            try testing.expectEqual(@as(usize, 3), seen);
        }
    }
}

test "settings patch: a removal keeps its tombstone when the config as last read names the profile, though the fresh read missed it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "profile-name = py: Python\n" });
    const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
    defer alloc.free(more);
    const text = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nconfig-file = {s}\n", .{more});
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
    defer alloc.free(none);
    // The config as last read: the include labels `py`.
    var held = try testLoad(alloc, none, path);
    defer held.deinit();
    // A read that missed the include's line, as one that stopped partway
    // through would: no problem recorded, and no label.
    try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "\n" });
    var fresh = try testLoad(alloc, none, path);
    defer fresh.deinit();
    try testing.expect(fresh._diagnostics.empty());
    try testing.expect(fresh.@"profile-name".get("py") == null);

    // Either reading naming `py` keeps the tombstone; deleted only when
    // neither does.
    try testing.expectEqual(Edit.Op.unset, std.meta.activeTag(try testRemovalOp(&.{ &fresh, &held }, .{}, &held, path)));
    try testing.expectEqual(Edit.Op.delete, std.meta.activeTag(try testRemovalOp(&.{&fresh}, .{}, &held, path)));
}

test "settings patch: a config-file the load could not open or read whole, or a theme it could not read whole, is named, and a missing one or a directory is not" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "held.conf", .data = "profile-command = py: python.exe\n" });
    try tmp.dir.makeDir("dir");
    const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
    defer alloc.free(none);
    const held = try tmp.dir.realpathAlloc(alloc, "held.conf");
    defer alloc.free(held);
    const dir = try tmp.dir.realpathAlloc(alloc, "dir");
    defer alloc.free(dir);
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const missing = try std.fs.path.join(alloc, &.{ root, "missing.conf" });
    defer alloc.free(missing);

    // A missing include and a directory: the loader's to report.
    {
        const text = try std.fmt.allocPrint(alloc, "config-file = {s}\nconfig-file = {s}\n", .{ missing, dir });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        var config = try testLoad(alloc, none, path);
        defer config.deinit();
        try testing.expect(!config._diagnostics.empty());
        try testing.expect(unreadConfigFile(&config) == null);
    }
    // One another program holds with no sharing while the load runs: named.
    // (`std`'s `.lock` is a byte-range lock on Windows: the open succeeds,
    // and the read fails the whole load.)
    {
        const text = try std.fmt.allocPrint(alloc, "config-file = {s}\n", .{held});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        const wide = try std.os.windows.sliceToPrefixedFileW(null, held);
        const handle = std.os.windows.kernel32.CreateFileW(wide.span().ptr, std.os.windows.GENERIC_READ, 0, null, std.os.windows.OPEN_EXISTING, 0, null);
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.CouldNotHoldFile;
        defer std.os.windows.CloseHandle(handle);
        var config = try testLoad(alloc, none, path);
        defer config.deinit();
        try testing.expect(config.@"profile-command".get("py") == null);
        const unread = unreadConfigFile(&config) orelse return error.TestExpectedUnreadFile;
        try expectSameText(held, unread.path);
        try testing.expect(unread.kind == .include);
    }
    // One whose read fails partway through: named, though it opened; and a
    // theme the same.
    {
        var config = try Config.default(alloc);
        defer config.deinit();
        var buf: [16]u8 = undefined;
        var failing = @import("../../cli/args.zig").TestFailingReader.init("profile-name = py: P\nprofile-comm", &buf);
        try config.loadReader(alloc, &failing.interface, held);
        const unread = unreadConfigFile(&config) orelse return error.TestExpectedUnreadFile;
        try expectSameText(held, unread.path);
        try testing.expect(unread.kind == .include);

        var themed = try Config.default(alloc);
        defer themed.deinit();
        const arena = themed._arena.?.allocator();
        const message = try std.fmt.allocPrintSentinel(arena, "error reading theme {s}: error.ReadFailed", .{held}, 0);
        try themed._diagnostics.append(arena, .{ .message = message });
        const theme = unreadConfigFile(&themed) orelse return error.TestExpectedUnreadFile;
        try expectSameText(held, theme.path);
        try testing.expect(theme.kind == .theme);
    }
}

test "settings patch: a removed profile keeps its tombstone while anything else names it" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The config Settings was opened on had no earlier file; the one read
    // last (the app's) has one, which labels `labelled`.
    try tmp.dir.writeFile(.{ .sub_path = "none.conf", .data = "\n" });
    try tmp.dir.writeFile(.{ .sub_path = "earlier.conf", .data = "profile-name = labelled: L\n" });
    const text = "profile-command = labelled: l.exe\nprofile-command = solo: s.exe\nprofile-command = hid: h.exe\nprofile-hidden = hid\nprofile-command = ordered: o.exe\nprofile-order = user:Ordered\n";
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const none = try tmp.dir.realpathAlloc(alloc, "none.conf");
    defer alloc.free(none);
    const earlier = try tmp.dir.realpathAlloc(alloc, "earlier.conf");
    defer alloc.free(earlier);
    var original = try testLoad(alloc, none, path);
    defer original.deinit();
    var layers = try testLoad(alloc, earlier, path);
    defer layers.deinit();
    var pending = try original.clone(alloc);
    defer pending.deinit();
    const arena = pending._arena.?.allocator();
    for ([_][]const u8{ "labelled:", "solo:", "hid:", "ordered:" }) |line| try pending.@"profile-command".parseCLI(arena, line);

    var edit_arena: std.heap.ArenaAllocator = .init(alloc);
    defer edit_arena.deinit();
    const edits = try editsForSave(edit_arena.allocator(), alloc, &.{&layers}, .{}, &original, &pending, path, &testSamePath);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try patchProfileEdits(alloc, text, edits, &out);
    // `solo`, named by nothing else, goes; the others keep their tombstones:
    // another file's label, `profile-hidden` and `profile-order` (read from
    // the config read last) still name them.
    try expectSameText(
        "profile-command = labelled:\nprofile-command = hid:\nprofile-hidden = hid\nprofile-command = ordered:\nprofile-order = user:Ordered\n",
        out.items,
    );
}

test "settings patch: an edit holding a line break is refused, and nothing is written" {
    for ([_]Edit{
        .{ .field = .command, .id = "py", .op = .{ .set = "cmd.exe\nfont-size = 99" } },
        .{ .field = .name, .id = "py", .op = .{ .set = "P\r" } },
        .{ .field = .env, .id = "py", .name = "A\nB", .op = .unset },
        .{ .field = .folder, .id = "py\n", .op = .{ .set = "C:\\x" } },
    }) |line_break| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(testing.allocator);
        try testing.expectError(error.LineBreak, patchProfileEdits(testing.allocator, "profile-command = py: python.exe\n", &.{line_break}, &out));
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "settings patch: a masked field is named by key, id and variable, never by its value" {
    const alloc = testing.allocator;
    var reloaded = try Config.default(alloc);
    defer reloaded.deinit();
    const arena = reloaded._arena.?.allocator();
    try reloaded.@"profile-command".parseCLI(arena, "gone: g.exe");
    try reloaded.@"profile-command".parseCLI(arena, "team: t.exe");
    try reloaded.@"profile-name".parseCLI(arena, "team: T");
    try reloaded.@"profile-env".parseCLI(arena, "team: X=later");
    try reloaded.@"profile-env".parseCLI(arena, "team: Y=kept");
    const edits = [_]Edit{
        // Masked: a later layer sets the variable again.
        .{ .field = .env, .id = "team", .name = "x", .op = .{ .set = "secret-value" } },
        // Held: the value saved is the value read back.
        .{ .field = .env, .id = "team", .name = "Y", .op = .{ .set = "kept" } },
        // Masked: a deleted command another layer still defines.
        .{ .field = .command, .id = "gone", .op = .delete },
        // Not checked: a removed profile's field, dormant elsewhere.
        .{ .field = .name, .id = "team", .op = .delete, .with_profile = true },
        // Held: taken back, and nothing gives it a value.
        .{ .field = .folder, .id = "team", .op = .unset },
    };
    var masked: std.Io.Writer.Allocating = .init(alloc);
    defer masked.deinit();
    try masked.writer.writeAll("font-size");
    try testing.expect(try writeMasked(&masked.writer, &edits, &reloaded, true) == .masked);
    try testing.expect(std.mem.indexOf(u8, masked.written(), "secret") == null);
    try expectSameText("font-size, profile-env team x, profile-command gone", masked.written());

    var none: std.Io.Writer.Allocating = .init(alloc);
    defer none.deinit();
    try testing.expect(try writeMasked(&none.writer, edits[1..2], &reloaded, false) == .held);
    try expectSameText("", none.written());
}
