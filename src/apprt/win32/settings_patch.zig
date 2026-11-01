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
const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const Key = Config.Key;
const profile_map = @import("../../config/profile_map.zig");
const origin = @import("../../config/origin.zig");
const LineIterator = @import("../../cli/args.zig").LineIterator;

/// One of the four `profile-*` keys.
pub const Field = enum {
    command,
    name,
    folder,
    env,

    pub fn key(self: Field) Key {
        return switch (self) {
            .command => .@"profile-command",
            .name => .@"profile-name",
            .folder => .@"profile-working-directory",
            .env => .@"profile-env",
        };
    }

    fn kind(comptime self: Field) profile_map.Kind {
        return switch (self) {
            .command => .command,
            .name => .name,
            .folder => .text,
            .env => .env,
        };
    }

    fn fromName(name: []const u8) ?Field {
        inline for (comptime std.enums.values(Field)) |field| {
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

/// How a config file's text ends. A save that patches profile lines keeps
/// it (`persistSettings`): it hands both patchers the text ending in a
/// complete line ending (`terminate`), so neither ever sees a last line
/// without one, and gives the result the file's own ending once
/// (`restore`).
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

    /// `raw`, ending in a complete line ending, into `out`: a bare CR gets
    /// its LF, and a last line with no ending gets the one most of the
    /// file's lines have.
    pub fn terminate(self: FileEnd, alloc: Allocator, raw: []const u8, out: *std.ArrayListUnmanaged(u8)) Allocator.Error!void {
        try out.appendSlice(alloc, raw);
        switch (self) {
            .terminated => {},
            .bare_cr => try out.append(alloc, '\n'),
            .none => try out.appendSlice(alloc, if (mostlyCrlf(raw)) "\r\n" else "\n"),
        }
    }

    /// Give `text`, patched from what `terminate` made, the file's own
    /// ending: for `.none` exactly one line ending comes off the end, and for
    /// `.bare_cr` the last one becomes a CR. Text that ends in none (every
    /// line deleted) is left as it is.
    pub fn restore(self: FileEnd, text: *std.ArrayListUnmanaged(u8)) void {
        const ending: usize = if (std.mem.endsWith(u8, text.items, "\r\n")) 2 else if (std.mem.endsWith(u8, text.items, "\n")) 1 else 0;
        if (ending == 0) return;
        switch (self) {
            .terminated => {},
            .none => text.shrinkRetainingCapacity(text.items.len - ending),
            .bare_cr => {
                text.shrinkRetainingCapacity(text.items.len - ending);
                text.appendAssumeCapacity('\r');
            },
        }
    }
};

const utf8_bom = "\xef\xbb\xbf";

/// Whether more of `raw`'s line endings are CRLF than LF, as the patchers
/// count them.
fn mostlyCrlf(raw: []const u8) bool {
    var crlf: usize = 0;
    var lf: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, start, '\n')) |at| : (start = at + 1) {
        if (at > start and raw[at - 1] == '\r') crlf += 1 else lf += 1;
    }
    return crlf > lf;
}

/// The line `edit` writes, without its line ending, from `arena`.
fn editLine(arena: Allocator, edit: Edit) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const text: []const u8 = switch (edit.op) {
        .set => |value| if (edit.field == .env) try std.fmt.allocPrint(arena, "{s}={s}", .{ edit.name.?, value }) else value,
        .unset => if (edit.field == .env) try std.fmt.allocPrint(arena, "{s}=", .{edit.name.?}) else "",
        .delete => unreachable,
    };
    switch (edit.field) {
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
                try lines.insert(arena, index + 1, new_line);
                continue;
            }
            // A profile this file has no line for: a block of its own at the
            // end of the file.
            var last_kept: ?*Line = null;
            for (lines.items) |*line| {
                if (!line.deleted) last_kept = line;
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
pub fn profileEdits(arena: Allocator, problems: *const origin.Index, original: *const Config, pending: *const Config, path: []const u8, same: origin.SamePath) ![]Edit {
    var edits: std.ArrayListUnmanaged(Edit) = .empty;
    var removed: std.ArrayListUnmanaged([]const u8) = .empty;
    const takeBack = struct {
        fn op(p: *const origin.Index, field: Field, id: []const u8, name: ?[]const u8, target: []const u8, s: origin.SamePath) Edit.Op {
            return if (p.givesElsewhere(field.key(), id, name, target, s)) .unset else .delete;
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

/// The path of a `config-file` that is there and that `config`'s load could
/// not open, if any. The loader records it as a problem and goes past it
/// (`Config.loadRecursiveFiles`), so the layers miss what it says, and a save
/// that decided from them whether another file still names a removed
/// profile would decide blind: it stops instead. A missing one
/// (`FileNotFound`) or a directory (`IsDir`) is the loader's to report, as
/// the disk check before a save lets them through (`settingsDiskVerdict`).
pub fn unopenedConfigFile(config: *const Config) ?[]const u8 {
    const prefix = "error opening config-file ";
    for (config._diagnostics.items()) |diag| {
        const message: []const u8 = diag.message;
        if (!std.mem.startsWith(u8, message, prefix)) continue;
        const end = std.mem.lastIndexOf(u8, message, ": error.") orelse continue;
        // Missing, or a directory: what the disk check lets through too
        // (`settingsFileProbe`).
        const err = message[end + 2 ..];
        if (std.mem.eql(u8, err, "error.FileNotFound") or std.mem.eql(u8, err, "error.IsDir")) continue;
        return message[prefix.len..end];
    }
    return null;
}

/// Whether anything but this file's lines names profile `id`: another layer
/// defines it or gives one of its fields a value, or a reference names it
/// (`profile-order`, `profile-hidden`, `default-profile`, as the config the
/// index was made from holds them). Deleting its last `profile-command`
/// line would then leave the loader something that names no profile.
fn referencedElsewhere(problems: *const origin.Index, id: []const u8, path: []const u8, same: origin.SamePath) bool {
    for ([_]Field{ .command, .name, .folder, .env }) |field| {
        if (problems.givesElsewhere(field.key(), id, null, path, same)) return true;
    }
    const config = problems.config;
    if (config.@"default-profile") |value| if (namesProfile(value, id)) return true;
    for ([_][]const [:0]const u8{ config.@"profile-order".list.items, config.@"profile-hidden".list.items }) |values| {
        for (values) |value| if (namesProfile(value, id)) return true;
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
/// the one saved to, or the command line, sets it again.
pub fn editHeld(edit: Edit, reloaded: *const Config) bool {
    if (edit.with_profile) return true;
    const now: ?[]const u8 = switch (edit.field) {
        .command => reloaded.@"profile-command".get(edit.id),
        .name => reloaded.@"profile-name".get(edit.id),
        .folder => reloaded.@"profile-working-directory".get(edit.id),
        .env => env: {
            const name = edit.name orelse return true;
            const map = reloaded.@"profile-env".get(edit.id) orelse break :env null;
            var it = map.iterator();
            while (it.next()) |kv| {
                if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, name)) break :env kv.value_ptr.*;
            }
            break :env null;
        },
    };
    return switch (edit.op) {
        .set => |value| now != null and std.mem.eql(u8, now.?, value),
        .unset, .delete => now == null,
    };
}

/// How the save's status names an edit's field: its key, the profile id and,
/// for `profile-env`, the variable's name. Never the value, which can hold a
/// secret.
pub fn writeEditName(writer: *std.Io.Writer, edit: Edit) !void {
    try writer.print("{s} {s}", .{ @tagName(edit.field.key()), edit.id });
    if (edit.name) |name| try writer.print(" {s}", .{name});
}

/// The edits a save of `pending` makes to the file `path` (`profileEdits`),
/// from `arena`; none, without indexing anything, when no profile changed.
/// `layers` is the config as it was read last (the app's), which tells what
/// the other files and the command line say now: an external reload since
/// `original` was copied may have changed them.
pub fn editsForSave(arena: Allocator, alloc: Allocator, layers: *const Config, original: *const Config, pending: *const Config, path: []const u8, same: origin.SamePath) ![]Edit {
    if (original.@"profile-command".equal(pending.@"profile-command") and
        original.@"profile-name".equal(pending.@"profile-name") and
        original.@"profile-working-directory".equal(pending.@"profile-working-directory") and
        original.@"profile-env".equal(pending.@"profile-env")) return &.{};
    // The layers as the app applies them, in the light/dark state of the
    // config Settings was opened on (the app's, which `updateConfig`
    // conditions): a `theme = light:A,dark:B` file can define a profile in
    // one state only, and `Config.load` hands over the light one.
    var conditioned = try layers.changeConditionalState(original._conditional_state);
    defer if (conditioned) |*value| value.deinit();
    var problems = try origin.Index.init(alloc, if (conditioned) |*value| value else layers);
    defer problems.deinit(alloc);
    return profileEdits(arena, &problems, original, pending, path, same);
}

/// Name each field of `edits` that `reloaded` does not hold (`editHeld`),
/// comma separated, after a separator when `after`. Returns whether it
/// named one.
pub fn writeMasked(writer: *std.Io.Writer, edits: []const Edit, reloaded: *const Config, after: bool) !bool {
    var separate = after;
    var named = false;
    for (edits) |edit| {
        if (editHeld(edit, reloaded)) continue;
        if (separate) try writer.writeAll(", ");
        separate = true;
        named = true;
        try writeEditName(writer, edit);
    }
    return named;
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
    const edits = try profileEdits(edit_arena.allocator(), &problems, &original, &pending, path, &testSamePath);
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
    try testing.expect(try writeMasked(&masked.writer, edits, &reloaded, false));
    try expectSameText("profile-name team", masked.written());

    // A save works out the same edits, and none when nothing changed.
    const again = try editsForSave(edit_arena.allocator(), alloc, &original, &original, &pending, path, &testSamePath);
    try testing.expectEqual(edits.len, again.len);
    try testing.expectEqual(@as(usize, 0), (try editsForSave(edit_arena.allocator(), alloc, &original, &original, &original, path, &testSamePath)).len);
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

test "settings patch: FileEnd hands the patchers a complete last line and gives the result the file's own ending once" {
    const alloc = testing.allocator;
    const Case = struct { raw: []const u8, end: FileEnd, terminated: []const u8 };
    for ([_]Case{
        .{ .raw = "", .end = .terminated, .terminated = "" },
        .{ .raw = "\xef\xbb\xbf", .end = .terminated, .terminated = "\xef\xbb\xbf" },
        .{ .raw = "a\n", .end = .terminated, .terminated = "a\n" },
        .{ .raw = "a\r\n", .end = .terminated, .terminated = "a\r\n" },
        .{ .raw = "a", .end = .none, .terminated = "a\n" },
        .{ .raw = "a\r\nb", .end = .none, .terminated = "a\r\nb\r\n" },
        .{ .raw = "\xef\xbb\xbfa\r\nb", .end = .none, .terminated = "\xef\xbb\xbfa\r\nb\r\n" },
        .{ .raw = "a\r", .end = .bare_cr, .terminated = "a\r\n" },
        .{ .raw = "a\nb\r", .end = .bare_cr, .terminated = "a\nb\r\n" },
    }) |case| {
        try testing.expectEqual(case.end, FileEnd.of(case.raw));
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try case.end.terminate(alloc, case.raw, &out);
        try expectSameText(case.terminated, out.items);
        // Restored with nothing patched, the bytes are the file's again.
        case.end.restore(&out);
        try expectSameText(case.raw, out.items);
    }
    // Exactly one line ending comes off, and a bare CR's CRLF or LF becomes
    // a CR; text that ends in none is left alone.
    for ([_]struct { end: FileEnd, patched: []const u8, restored: []const u8 }{
        .{ .end = .none, .patched = "# keep\n\n", .restored = "# keep\n" },
        .{ .end = .none, .patched = "# keep\r\n\r\n", .restored = "# keep\r\n" },
        .{ .end = .none, .patched = "", .restored = "" },
        .{ .end = .bare_cr, .patched = "a\r\nb\r\n", .restored = "a\r\nb\r" },
        .{ .end = .bare_cr, .patched = "a\nb\n", .restored = "a\nb\r" },
        .{ .end = .bare_cr, .patched = "\xef\xbb\xbf", .restored = "\xef\xbb\xbf" },
        .{ .end = .terminated, .patched = "a\n", .restored = "a\n" },
    }) |case| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, case.patched);
        case.end.restore(&out);
        try expectSameText(case.restored, out.items);
    }
}

test "settings patch: a removal is decided in the light/dark state Settings was opened in, so a profile only the dark theme defines keeps its tombstone" {
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
    // What a read from disk hands over: the light state.
    var layers = try testLoad(alloc, none, path);
    defer layers.deinit();
    try testing.expectEqual(@TypeOf(layers._conditional_state.theme).light, layers._conditional_state.theme);

    for ([_]@TypeOf(layers._conditional_state.theme){ .dark, .light }) |theme| {
        // The config Settings was opened on, in the state the app applied.
        var applied = (try layers.changeConditionalState(.{ .theme = theme })) orelse try layers.clone(alloc);
        defer applied.deinit();
        var pending = try applied.clone(alloc);
        defer pending.deinit();
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");

        var edit_arena: std.heap.ArenaAllocator = .init(alloc);
        defer edit_arena.deinit();
        const edits = try editsForSave(edit_arena.allocator(), alloc, &layers, &applied, &pending, path, &testSamePath);
        var command: ?Edit = null;
        for (edits) |e| if (e.field == .command) {
            command = e;
        };
        // Dark: the dark theme still defines `py`, so its line becomes the
        // tombstone. Light: nothing else does, and the line goes.
        try testing.expect(command != null);
        try testing.expectEqual(if (theme == .dark) Edit.Op.unset else Edit.Op.delete, std.meta.activeTag(command.?.op));
        // A reload in the dark state holds the dark theme's `py`: the
        // masking check names a deletion it would have undone.
        if (theme == .dark) {
            var masked: std.Io.Writer.Allocating = .init(alloc);
            defer masked.deinit();
            const deletion = [_]Edit{.{ .field = .command, .id = "py", .op = .delete }};
            try testing.expect(try writeMasked(&masked.writer, &deletion, &applied, false));
            try expectSameText("profile-command py", masked.written());
        }
    }
}

test "settings patch: a config-file the load found and could not open is named, and a missing one or a directory is not" {
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
        try testing.expect(unopenedConfigFile(&config) == null);
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
        try expectSameText(held, unopenedConfigFile(&config) orelse return error.TestExpectedUnopenedFile);
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
    const edits = try editsForSave(edit_arena.allocator(), alloc, &layers, &original, &pending, path, &testSamePath);
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
    try testing.expect(try writeMasked(&masked.writer, &edits, &reloaded, true));
    try testing.expect(std.mem.indexOf(u8, masked.written(), "secret") == null);
    try expectSameText("font-size, profile-env team x, profile-command gone", masked.written());

    var none: std.Io.Writer.Allocating = .init(alloc);
    defer none.deinit();
    try testing.expect(!try writeMasked(&none.writer, edits[1..2], &reloaded, false));
    try expectSameText("", none.written());
}
