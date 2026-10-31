//! The model behind Settings' "All settings" page: every config key
//! (`Config.Key`), its documentation as plain text, its effective value, the
//! lines of the config file that set it, and what Windows does with it. No
//! windows here: `win32_settings.zig` draws the list and owns its HWND.

const std = @import("std");
const Config = @import("../config/Config.zig");
const origin = @import("../config/origin.zig");
const formatter = @import("../config/formatter.zig");
const help_strings = @import("help_strings");
const field_model = @import("win32_settings_fields.zig");

pub const Key = Config.Key;
/// Every key, in the order `Config.zig` declares them (the order of the
/// generated reference).
pub const keys = std.enums.values(Key);
pub const key_count = keys.len;

/// Each key's documentation as `help_strings` holds it (Markdown-ish text from
/// its doc comment). A key with no doc comment of its own shares the one of
/// the key before it, as the generated reference groups them
/// (`font-family-bold` with `font-family`, `clipboard-write` with
/// `clipboard-read`).
pub const raw_docs: [key_count][]const u8 = docs: {
    @setEvalBranchQuota(200_000);
    var result: [key_count][]const u8 = undefined;
    var last: []const u8 = "";
    for (keys, 0..) |key, i| {
        const name = @tagName(key);
        if (@hasDecl(help_strings.Config, name)) last = @field(help_strings.Config, name);
        if (last.len == 0) @compileError("config key has no documentation: " ++ name);
        result[i] = last;
    }
    break :docs result;
};

pub fn index(key: Key) usize {
    return @intFromEnum(key);
}

comptime {
    // `index` relies on the key enum counting from zero in declaration order.
    for (keys, 0..) |key, i| if (@intFromEnum(key) != i) @compileError("Config.Key is not dense");
}

/// What Windows does with a config key that it accepts but does not honour
/// in full. The keys are the ones `docs/windows-capability-matrix.md` lists
/// under "Settings accepted without effect" (a contract test keeps the two
/// the same), which include the two whose Settings controls are disabled as
/// "not supported on Windows" (`field_model.Support`).
pub const WindowsNote = struct {
    /// A `Config` field name: `_xdg-terminal-exec` is internal and has no row.
    key: []const u8,
    note: []const u8,
};

const no_effect = "Has no effect on Windows.";
const gtk_only = "Has no effect on Windows: it belongs to the Linux GTK runtime, which this build does not have. It is kept so a shared config file still loads.";

pub const windows_notes = [_]WindowsNote{
    .{ .key = "background-blur", .note = "Has no effect on Windows: no window here can show a blur behind it. Setting it logs a warning." },
    .{ .key = "link-previews", .note = "On Windows, links open, but no preview pops up." },
    .{ .key = "bell-features", .note = "On Windows, the border feature has no effect; the others work." },
    .{ .key = "focus-follows-mouse", .note = no_effect },
    .{ .key = "window-inherit-font-size", .note = no_effect ++ " A new window or tab starts with the configured font size." },
    .{ .key = "resize-overlay", .note = no_effect },
    .{ .key = "resize-overlay-position", .note = no_effect },
    .{ .key = "resize-overlay-duration", .note = no_effect },
    .{ .key = "quick-terminal-space-behavior", .note = no_effect },
    .{ .key = "accent-follow-system", .note = "Retired: it has no effect. The tab strip no longer uses an accent colour; the active tab takes the terminal's background instead. It is kept so a config file that sets it still loads." },
    .{ .key = "window-subtitle", .note = no_effect },
    .{ .key = "window-step-resize", .note = no_effect },
    .{ .key = "drag-handle", .note = "Has no effect on Windows: it belongs to the split drag handles of upstream Ghostty's macOS and GTK apps. It is kept so a shared config file still loads." },
    .{ .key = "scrollback-compression", .note = "Has no effect on Windows: this build does not compress scrollback. It is kept so a shared config file still loads." },
    .{ .key = "gtk-opengl-debug", .note = gtk_only },
    .{ .key = "gtk-custom-css", .note = gtk_only },
    .{ .key = "gtk-quick-terminal-layer", .note = gtk_only },
    .{ .key = "gtk-quick-terminal-namespace", .note = gtk_only },
    .{ .key = "gtk-titlebar", .note = gtk_only },
    .{ .key = "gtk-titlebar-style", .note = gtk_only },
    .{ .key = "gtk-titlebar-hide-when-maximized", .note = gtk_only },
    .{ .key = "gtk-toolbar-style", .note = gtk_only },
    .{ .key = "gtk-tabs-location", .note = gtk_only },
    .{ .key = "gtk-tabs-inverted", .note = gtk_only },
    .{ .key = "gtk-wide-tabs", .note = gtk_only },
    .{ .key = "gtk-horizontal-tab-scroll", .note = gtk_only },
    .{ .key = "x11-instance-name", .note = "Has no effect on Windows: it names an X11 window class." },
    .{ .key = "async-backend", .note = no_effect },
    .{ .key = "_xdg-terminal-exec", .note = no_effect },
};

/// Each key's Windows note, or null when Windows honours it as documented.
pub const notes: [key_count]?[]const u8 = notes: {
    @setEvalBranchQuota(100_000);
    var result: [key_count]?[]const u8 = @splat(null);
    for (windows_notes, 0..) |entry, i| {
        if (!@hasField(Config, entry.key)) @compileError("Windows note for a key Config does not have: " ++ entry.key);
        for (windows_notes[0..i]) |other| if (std.mem.eql(u8, other.key, entry.key)) @compileError("Windows note listed twice: " ++ entry.key);
        if (@hasField(Key, entry.key)) result[index(@field(Key, entry.key))] = entry.note;
    }
    // One list, not two: a Settings control Windows does not support is a key
    // with a note, and a key with a note that has a control is disabled.
    for (field_model.descriptors) |spec| {
        const noted = result[index(spec.key)] != null;
        if (noted != (spec.support == .unsupported_on_windows))
            @compileError("Settings support and the Windows note disagree for " ++ @tagName(spec.key));
    }
    break :notes result;
};

/// Keys whose value `Config.finalize` works out when nothing sets them (the
/// shell found on this machine, the home directory, the double-click time,
/// this build's update channel).
/// Their effective value differs from `Config.default` without anything
/// having changed it, so they count as changed only when the config file
/// sets them.
pub const resolved_when_unset = [_]Key{
    .command,
    .@"working-directory",
    .@"single-instance",
    .@"gtk-single-instance",
    .@"click-repeat-interval",
    .term,
    .@"font-family-bold",
    .@"font-family-italic",
    .@"font-family-bold-italic",
    .@"auto-update-channel",
};

fn resolvedWhenUnset(key: Key) bool {
    return std.mem.indexOfScalar(Key, &resolved_when_unset, key) != null;
}

/// Write `raw` (a doc comment from `help_strings`) as plain text: inline code
/// keeps its text without the backticks, `**bold**` and `*emphasis*` lose
/// their stars, a link keeps its label and its address in parentheses, a
/// bullet starts a line with "•", a heading is a line of its own, and an
/// indented block (code) keeps its lines. The lines of a paragraph join with
/// spaces; paragraphs are separated by a blank line.
pub fn writePlain(writer: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, raw, '\n');
    const Block = enum { none, text, code };
    var block: Block = .none;
    var wrote_any = false;
    // Whether the output line in progress holds text.
    var line_open = false;
    // A heading ends its line, so the text after it starts a new one.
    var after_heading = false;
    while (lines.next()) |line_crlf| {
        const line = std.mem.trimRight(u8, line_crlf, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) {
            block = .none;
            continue;
        }
        if (block == .none) {
            if (wrote_any) try writer.writeAll("\n\n");
            block = if (std.mem.startsWith(u8, line, "    ")) .code else .text;
            line_open = false;
            after_heading = false;
        }
        wrote_any = true;
        switch (block) {
            .none => unreachable,
            .code => {
                if (line_open) try writer.writeByte('\n');
                try writer.writeAll("  ");
                try writer.writeAll(if (std.mem.startsWith(u8, line, "    ")) line[4..] else std.mem.trimLeft(u8, line, " \t"));
                line_open = true;
            },
            .text => {
                const trimmed = std.mem.trimLeft(u8, line, " \t");
                if (bulletText(trimmed)) |item| {
                    if (line_open) try writer.writeByte('\n');
                    try writer.writeAll("\u{2022} ");
                    try writeInline(writer, item);
                    after_heading = false;
                } else if (trimmed[0] == '#') {
                    if (line_open) try writer.writeByte('\n');
                    try writeInline(writer, std.mem.trimLeft(u8, std.mem.trimLeft(u8, trimmed, "#"), " \t"));
                    after_heading = true;
                } else {
                    if (line_open) try writer.writeByte(if (after_heading) '\n' else ' ');
                    try writeInline(writer, trimmed);
                    after_heading = false;
                }
                line_open = true;
            },
        }
    }
}

fn bulletText(trimmed: []const u8) ?[]const u8 {
    if (trimmed.len >= 2 and (trimmed[0] == '*' or trimmed[0] == '-' or trimmed[0] == '+') and trimmed[1] == ' ')
        return std.mem.trimLeft(u8, trimmed[2..], " \t");
    return null;
}

fn writeInline(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '`' => {
                // Inline code: its text as it is. An unpaired backtick goes.
                const end = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse {
                    i += 1;
                    continue;
                };
                try writer.writeAll(text[i + 1 .. end]);
                i = end + 1;
            },
            '*' => {
                if (i + 1 < text.len and text[i + 1] == '*') {
                    i += 2;
                    continue;
                }
                const before: u8 = if (i == 0) ' ' else text[i - 1];
                const after: u8 = if (i + 1 < text.len) text[i + 1] else ' ';
                const opens = !isWordByte(before) and isWordByte(after);
                const closes = isWordByte(before) and !isWordByte(after);
                if (!opens and !closes) try writer.writeByte('*');
                i += 1;
            },
            '[' => {
                // [label](address) -> label (address)
                if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close| {
                    if (close + 1 < text.len and text[close + 1] == '(') {
                        if (std.mem.indexOfScalarPos(u8, text, close + 2, ')')) |end| {
                            try writeInline(writer, text[i + 1 .. close]);
                            try writer.print(" ({s})", .{text[close + 2 .. end]});
                            i = end + 1;
                            continue;
                        }
                    }
                }
                try writer.writeByte('[');
                i += 1;
            },
            else => {
                try writer.writeByte(c);
                i += 1;
            },
        }
    }
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// The first sentence of `plain`, or its first line: what a row shows of the
/// documentation until it is selected.
pub fn summaryOf(plain: []const u8) []const u8 {
    const line_end = std.mem.indexOfScalar(u8, plain, '\n') orelse plain.len;
    const line = plain[0..line_end];
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, line, i, '.')) |dot| : (i = dot + 1) {
        if (dot + 1 == line.len or line[dot + 1] == ' ') return line[0 .. dot + 1];
    }
    return line;
}

/// The lines of a config file that set each key: how many, and the last.
pub const Lines = struct {
    count: u32 = 0,
    last: u32 = 0,
};

/// The config file Settings saves to, as the All settings page could read it.
pub const ConfigFile = union(enum) {
    /// Settings names no file: nothing is said about where a key is set.
    none,
    /// The file does not exist yet, so it sets nothing.
    missing,
    /// The file is there but was not read here (a share or a mapped network
    /// drive, a file too large, an error), so where it sets a key is not known.
    unavailable,
    /// The file's bytes, as read.
    bytes: []const u8,
};

/// The config file the All settings page reads, as the app found it: its
/// complete path (never shortened for display) and what reading it gave. Both
/// are owned by the allocator the app was given.
pub const ConfigSource = struct {
    /// Null when Settings could not name the file (for example, when a
    /// default-path candidate could not be shown to be local).
    path: ?[]const u8 = null,
    file: ConfigFile = .none,

    pub fn deinit(self: *ConfigSource, alloc: std.mem.Allocator) void {
        if (self.path) |path| alloc.free(path);
        if (self.file == .bytes) alloc.free(self.file.bytes);
        self.* = .{};
    }
};

/// The text of a config file read as `bytes`, as `Config.loadReader` reads it:
/// without a UTF-8 byte order mark, and UTF-16 that starts with a byte order
/// mark decoded (a trailing odd byte dropped). A line of the file is a line of
/// the text, so line numbers stay the file's. Null for UTF-16 that does not
/// decode, which `Config` skips whole. The text is `bytes` itself, or memory
/// from `alloc`.
pub fn decodeConfigText(alloc: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const text = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
    const order: std.builtin.Endian = if (std.mem.startsWith(u8, text, "\xff\xfe"))
        .little
    else if (std.mem.startsWith(u8, text, "\xfe\xff"))
        .big
    else
        return text;
    const body = text[2..];
    const units = try alloc.alloc(u16, body.len / 2);
    defer alloc.free(units);
    for (units, 0..) |*unit, i| unit.* = std.mem.nativeToLittle(u16, std.mem.readInt(u16, body[i * 2 ..][0..2], order));
    return std.unicode.utf16LeToUtf8Alloc(alloc, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// Count the lines of config file `text` that set each key. A line sets a
/// key when, without the spaces around it, it starts with the key's name
/// followed by `=` (or is the name alone); lines starting with `#` are
/// comments.
pub fn scanLines(text: []const u8, out: *[key_count]Lines) void {
    out.* = @splat(.{});
    var number: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        number +|= 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const name = std.mem.trimRight(u8, trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '=') orelse trimmed.len], " \t");
        const key = std.meta.stringToEnum(Key, name) orelse continue;
        const entry = &out[index(key)];
        entry.count +|= 1;
        entry.last = number;
    }
}

/// Write `key`'s value in `config` the way a config file sets it: a line
/// `key = value` for each value (a repeatable key has one per entry).
pub fn writeEntries(writer: *std.Io.Writer, config: *const Config, key: Key) !void {
    switch (key) {
        inline else => |tag| try formatter.formatEntry(
            Config.Value(tag),
            @tagName(tag),
            @field(config, @tagName(tag)),
            writer,
        ),
    }
}

/// The values `entries` (from `writeEntries`) holds for `name`, one at a time.
pub const EntryIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    name: []const u8,

    pub fn init(entries: []const u8, name: []const u8) EntryIterator {
        return .{ .lines = std.mem.splitScalar(u8, entries, '\n'), .name = name };
    }

    pub fn next(self: *EntryIterator) ?[]const u8 {
        while (self.lines.next()) |line| {
            if (line.len == 0) continue;
            var value = line;
            if (std.mem.startsWith(u8, value, self.name)) {
                value = value[self.name.len..];
                if (std.mem.startsWith(u8, value, " = ")) value = value[3..] else if (std.mem.startsWith(u8, value, " =")) value = value[2..];
            }
            return value;
        }
        return null;
    }
};

/// One key's row.
pub const Row = struct {
    /// The documentation as plain text (`writePlain`).
    doc: []const u8 = "",
    /// Its first sentence (`summaryOf`).
    summary: []const u8 = "",
    /// The first value, as the config file writes it; empty when the key has
    /// none.
    value: []const u8 = "",
    /// How many values follow the first (a repeatable key).
    more: u32 = 0,
    /// What the search finds the row by, in lower case: the name, every
    /// value, the Windows note, the documentation and the words of the
    /// key's Settings controls.
    search: []const u8 = "",
    /// Whether the effective value differs from the default
    /// (`resolved_when_unset` keys: whether the config file sets them, when
    /// that is known; else their value too).
    differs: bool = false,
    /// The lines of the config file Settings saves to that set the key.
    lines: Lines = .{},
    /// Where the effective value came from (`config.origin`); a file's path
    /// is the model's own copy.
    origin: origin.Origin = .default,
    /// Whether the key's lines can add up rather than replace one another
    /// (`accumulates`): the last line is then not always the only one that
    /// counts.
    accumulates: bool = false,
};

pub const Model = struct {
    arena: ?std.heap.ArenaAllocator = null,
    rows: [key_count]Row = @splat(.{}),
    /// The config file Settings saves to, when it names one.
    file: ?[]const u8 = null,
    /// Whether the rows' `lines` are the file's: false when it could not be
    /// read or decoded.
    lines_known: bool = true,

    pub fn deinit(self: *Model) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub fn built(self: *const Model) bool {
        return self.arena != null;
    }

    /// Build every row from `current` (the effective config) and `defaults`
    /// (`Config.default`, null when it could not be made: nothing then
    /// counts as changed). `file` is the config file at `file_path` (`.none`
    /// without a path); `extra_search` adds words to each key's search text
    /// (the Settings controls' names and keywords). On failure the model is
    /// left empty.
    pub fn build(
        self: *Model,
        gpa: std.mem.Allocator,
        current: *const Config,
        defaults: ?*const Config,
        file_path: ?[]const u8,
        file: ConfigFile,
        extra_search: *const [key_count][]const u8,
    ) !void {
        self.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var lines: [key_count]Lines = @splat(.{});
        const lines_known = switch (file) {
            .none, .missing => true,
            .unavailable => false,
            .bytes => |bytes| known: {
                const text = try decodeConfigText(alloc, bytes) orelse break :known false;
                scanLines(text, &lines);
                break :known true;
            },
        };
        var rows: [key_count]Row = undefined;
        var current_entries: std.Io.Writer.Allocating = .init(gpa);
        defer current_entries.deinit();
        var default_entries: std.Io.Writer.Allocating = .init(gpa);
        defer default_entries.deinit();
        var doc: std.Io.Writer.Allocating = .init(gpa);
        defer doc.deinit();
        for (keys, 0..) |key, i| {
            const name = @tagName(key);
            doc.clearRetainingCapacity();
            try writePlain(&doc.writer, raw_docs[i]);
            const plain = try alloc.dupe(u8, doc.written());

            current_entries.clearRetainingCapacity();
            try writeEntries(&current_entries.writer, current, key);
            var values = EntryIterator.init(current_entries.written(), name);
            const first = values.next() orelse "";
            var more: u32 = 0;
            while (values.next()) |_| more +|= 1;

            // A key `finalize` works out differs when the file sets it. With
            // the file unread that is not known, so its value decides, as
            // for any other key: shown as changed rather than hidden.
            const differs = if (resolvedWhenUnset(key) and lines_known) lines[i].count != 0 else if (defaults) |config| changed: {
                default_entries.clearRetainingCapacity();
                try writeEntries(&default_entries.writer, config, key);
                break :changed !std.mem.eql(u8, current_entries.written(), default_entries.written());
            } else false;

            var search: std.Io.Writer.Allocating = .init(alloc);
            const w = &search.writer;
            try w.writeAll(name);
            try w.writeByte('\n');
            var all_values = EntryIterator.init(current_entries.written(), name);
            while (all_values.next()) |value| {
                try w.writeAll(value);
                try w.writeByte('\n');
            }
            if (notes[i]) |note| {
                try w.writeAll(note);
                try w.writeByte('\n');
            }
            try w.writeAll(plain);
            try w.writeByte('\n');
            try w.writeAll(extra_search[i]);
            const search_text = try search.toOwnedSlice();
            for (search_text) |*c| c.* = std.ascii.toLower(c.*);

            rows[i] = .{
                .doc = plain,
                .summary = summaryOf(plain),
                .value = try alloc.dupe(u8, first),
                .more = more,
                .search = search_text,
                .differs = differs,
                .lines = lines[i],
                .accumulates = accumulates(key),
                .origin = switch (savedOrigin(current, key, defaults)) {
                    .file => |place| .{ .file = .{ .path = try alloc.dupe(u8, place.path), .line = place.line, .kind = place.kind } },
                    // Only `finalize` gives a key a value no step set, and
                    // only these keys; any other such value was written into
                    // the config in memory, which is not where it came from.
                    .derived => |how| if (resolvedWhenUnset(key)) .{ .derived = how } else .default,
                    else => |other| other,
                },
            };
        }
        self.file = if (file_path) |path| try alloc.dupe(u8, path) else null;
        self.lines_known = lines_known;
        self.rows = rows;
        self.arena = arena;
    }

    /// What `row` says about where its key is set, written to `writer`;
    /// nothing when Settings names no config file and reads none. A value
    /// that comes from somewhere other than that file (`Row.origin`: a file
    /// `config-file` names, the theme, another default config file, the
    /// command line) is named with its file and line, and a line of this file
    /// that it overrides is said not to take effect.
    pub fn writeLocation(self: *const Model, writer: *std.Io.Writer, row: *const Row) !void {
        switch (row.origin) {
            .file => |file| if (self.file == null or !samePath(file.path, self.file.?)) {
                try writer.print("Set on line {d} of {s}{s}", .{ file.line, file.path, switch (file.kind) {
                    .included => ", a file config-file names.",
                    .theme => ", the theme.",
                    .config => ".",
                } });
                return self.writeOverridden(writer, row);
            },
            .cli => {
                try writer.writeAll("Set on the command line.");
                return self.writeOverridden(writer, row);
            },
            .derived => if (self.file != null and self.lines_known and row.lines.count == 0) {
                return writer.print("Not set in {s}: noctty chose this value when it read the config.", .{self.file.?});
            },
            .unplaced => return writer.writeAll("Set, but not in a file or on the command line."),
            .default => {},
        }
        const path = self.file orelse {
            if (!self.lines_known) try writer.writeAll("Not known where it is set: Settings could not tell which config file to read.");
            return;
        };
        if (!self.lines_known) return writer.print("Not known where {s} sets it: Settings reads only a file on a local drive, as text, and could not read this one.", .{path});
        switch (row.lines.count) {
            0 => try writer.print("Not set in {s}.", .{path}),
            1 => try writer.print("Set on line {d} of {s}.", .{ row.lines.last, path }),
            else => try writer.print("Set on {d} lines of {s}, the last on line {d}.", .{ row.lines.count, path, row.lines.last }),
        }
    }

    /// For a value from elsewhere: the line of this file that it overrides,
    /// or, for a key whose lines can add up, only that this file has one too.
    /// Whether such a line still counts depends on the lines after it, which
    /// the replay log does not say. An empty value resets by each field's own
    /// rule (`font-family =` clears the families; `keybind =` and
    /// `command-palette-entry =` put the defaults back, and `keybind = clear`
    /// clears every binding), a command-line `font-family` replaces the
    /// families before it, and a later `keybind` for the same keys replaces
    /// the entry.
    fn writeOverridden(self: *const Model, writer: *std.Io.Writer, row: *const Row) !void {
        const path = self.file orelse return;
        if (!self.lines_known or row.lines.count == 0) return;
        if (row.accumulates) return writer.print(" {s} also has a setting for it, on line {d}.", .{ path, row.lines.last });
        try writer.print(" Line {d} of {s} sets it too, and does not take effect.", .{ row.lines.last, path });
    }
};

/// Where the value Settings shows for `key` comes from (`config.origin.of`).
/// When noctty's command line named a `default-profile` for this process,
/// Settings shows the config files' value instead
/// (`Config.defaultProfileFromFiles`), which that argument did not set: its
/// origin is the last file line that set it (`config.origin.ofFiles`).
pub fn savedOrigin(config: *const Config, key: Key, defaults: ?*const Config) origin.Origin {
    if (key == .@"default-profile" and config._default_profile_cli != null) return origin.ofFiles(config, key);
    return origin.of(config, key, defaults);
}

/// Whether `key`'s lines can add up rather than replace one another: a list
/// (`font-family`, `config-file`, `link`), or a map that each line adds an
/// entry to (`keybind`, `palette`, `key-remap`, the `profile-*` keys). Packed
/// flags (`app-notifications`) start from the default on every line, and
/// replace.
pub fn accumulates(key: Key) bool {
    return switch (key) {
        inline else => |k| comptime typeAccumulates(@FieldType(Config, @tagName(k))),
    };
}

fn typeAccumulates(comptime T: type) bool {
    @setEvalBranchQuota(20000);
    const U = switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
    if (@typeInfo(U) != .@"struct") return false;
    const name = @typeName(U);
    for ([_][]const u8{ "Repeatable", "profile_map", "Keybinds", "Palette", "RemapSet", "QuickSelectPatterns" }) |part| {
        if (std.mem.indexOf(u8, name, part) != null) return true;
    }
    return false;
}

test "settings reference knows which keys' lines add up" {
    for ([_]Key{ .@"font-family", .@"config-file", .keybind, .palette, .@"key-remap", .@"quick-select-patterns", .@"profile-command", .env, .link, .@"command-palette-entry", .input }) |key| {
        errdefer std.debug.print("expected {s} to accumulate\n", .{@tagName(key)});
        try testing.expect(accumulates(key));
    }
    for ([_]Key{ .@"font-size", .@"window-padding-x", .@"app-notifications", .theme, .command, .background, .@"default-profile", .@"cursor-style" }) |key| {
        errdefer std.debug.print("expected {s} to replace\n", .{@tagName(key)});
        try testing.expect(!accumulates(key));
    }
}

/// Whether two Windows paths name the same file as written: letters in any
/// case, and `/` for `\`. The loader and Settings each name the config file
/// by its absolute path, but not always with the same letters.
fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '/') '\\' else std.ascii.toLower(x);
        const ny = if (y == '/') '\\' else std.ascii.toLower(y);
        if (nx != ny) return false;
    }
    return true;
}

/// The value as a row shows it: the first value, and how many more there
/// are; "not set" for none.
pub fn writeValue(writer: *std.Io.Writer, row: *const Row) !void {
    if (row.value.len == 0 and row.more == 0) return writer.writeAll("not set");
    try writer.writeAll(if (row.value.len == 0) "(empty)" else row.value);
    if (row.more != 0) try writer.print(", and {d} more", .{row.more});
}

const testing = std.testing;

fn plainOf(raw: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writePlain(&out.writer, raw);
    return out.toOwnedSlice();
}

test "settings reference documentation reads as plain text" {
    const cases = [_][2][]const u8{
        .{ "Use `font-size` to set it.", "Use font-size to set it." },
        .{ "One line\nand the next.\n\nA second paragraph.", "One line and the next.\n\nA second paragraph." },
        .{ "Valid values are:\n\n  * `true`, the default\n  * `false`, which\n    wraps here\n", "Valid values are:\n\n\u{2022} true, the default\n\u{2022} false, which wraps here" },
        .{ "Example:\n\n    font-family = \"\"\n    font-family = \"My Font\"\n\nAfter.", "Example:\n\n  font-family = \"\"\n  font-family = \"My Font\"\n\nAfter." },
        .{ "See [the spec](https://example.com/x).", "See the spec (https://example.com/x)." },
        .{ "**THIS IS IMPORTANT.** Really.", "THIS IS IMPORTANT. Really." },
        .{ "the *blur intensity* value", "the blur intensity value" },
        .{ "## Key Tables\nA table holds bindings.", "Key Tables\nA table holds bindings." },
        .{ "Glob `*.txt` and a lone * star", "Glob *.txt and a lone * star" },
        .{ "Line one\r\nline two\r\n", "Line one line two" },
    };
    for (cases) |case| {
        const plain = try plainOf(case[0]);
        defer testing.allocator.free(plain);
        try testing.expectEqualStrings(case[1], plain);
    }
}

test "settings reference every key has documentation, plain and summarised" {
    for (keys, 0..) |key, i| {
        const plain = try plainOf(raw_docs[i]);
        defer testing.allocator.free(plain);
        if (plain.len == 0) {
            std.debug.print("no plain documentation for {s}\n", .{@tagName(key)});
            return error.TestExpectedEqual;
        }
        try testing.expect(summaryOf(plain).len != 0);
        // No Markdown markers survive in prose.
        try testing.expect(std.mem.indexOf(u8, plain, "**") == null);
        try testing.expect(std.mem.indexOf(u8, plain, "](") == null);
    }
    // A key without a doc comment shares the one before it.
    try testing.expectEqualStrings(raw_docs[index(.@"font-family")], raw_docs[index(.@"font-family-bold")]);
    try testing.expectEqualStrings(raw_docs[index(.@"clipboard-read")], raw_docs[index(.@"clipboard-write")]);
}

test "settings reference summary is the first sentence" {
    try testing.expectEqualStrings("The first.", summaryOf("The first. The second."));
    try testing.expectEqualStrings("Ends without a dot", summaryOf("Ends without a dot\n\nMore."));
    try testing.expectEqualStrings("Version 1.2.0 is out.", summaryOf("Version 1.2.0 is out. More."));
}

test "settings reference counts the lines of the config file that set each key" {
    var lines: [key_count]Lines = undefined;
    scanLines(
        "# font-size = 99 is a comment\r\n" ++
            "font-size = 14\r\n" ++
            "\r\n" ++
            "  keybind = ctrl+a=copy_to_clipboard\r\n" ++
            "keybind=ctrl+b=paste_from_clipboard\r\n" ++
            "not-a-key = 1\r\n" ++
            "font-size=15",
        &lines,
    );
    try testing.expectEqual(Lines{ .count = 2, .last = 7 }, lines[index(.@"font-size")]);
    try testing.expectEqual(Lines{ .count = 2, .last = 5 }, lines[index(.keybind)]);
    try testing.expectEqual(Lines{}, lines[index(.theme)]);
}

test "settings reference rows carry the effective value, its count and the location" {
    var current = try Config.default(testing.allocator);
    defer current.deinit();
    var defaults = try Config.default(testing.allocator);
    defer defaults.deinit();
    current.@"font-size" = 15;
    const extra: [key_count][]const u8 = @splat("");
    var model: Model = .{};
    defer model.deinit();
    try model.build(testing.allocator, &current, &defaults, "C:\\cfg\\config", .{ .bytes = "font-size = 15\n" }, &extra);

    const font = &model.rows[index(.@"font-size")];
    try testing.expectEqualStrings("15", font.value);
    try testing.expect(font.differs);
    try testing.expectEqual(@as(u32, 1), font.lines.count);
    try testing.expect(std.mem.indexOf(u8, font.search, "font-size\n15\n") != null);

    const scrollback = &model.rows[index(.@"scrollback-limit")];
    try testing.expect(!scrollback.differs);

    // A repeatable key shows its first value and how many follow.
    const palette = &model.rows[index(.palette)];
    try testing.expect(palette.more > 0);

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try model.writeLocation(&writer, font);
    try testing.expectEqualStrings("Set on line 1 of C:\\cfg\\config.", writer.buffered());
    writer = .fixed(&buf);
    try model.writeLocation(&writer, scrollback);
    try testing.expectEqualStrings("Not set in C:\\cfg\\config.", writer.buffered());

    // A key Windows does not honour says so in what the search reads.
    const blur = &model.rows[index(.@"background-blur")];
    try testing.expect(std.mem.indexOf(u8, blur.search, "has no effect on windows") != null);
}

test "settings reference a config that sets nothing has no key away from its default" {
    // What `Config.finalize` works out on this machine (the shell, the home
    // directory, the double-click time) is no change: a key it resolves that
    // `resolved_when_unset` misses fails here.
    var current = try Config.default(testing.allocator);
    defer current.deinit();
    try current.finalize();
    var defaults = try Config.default(testing.allocator);
    defer defaults.deinit();
    const extra: [key_count][]const u8 = @splat("");
    var model: Model = .{};
    defer model.deinit();
    try model.build(testing.allocator, &current, &defaults, null, .none, &extra);
    var failed = false;
    for (keys, 0..) |key, i| if (model.rows[i].differs) {
        std.debug.print("settings reference: {s} differs from its default with nothing set\n", .{@tagName(key)});
        failed = true;
    };
    try testing.expect(!failed);
}

test "settings reference keys the app works out when unset count as changed only when the file sets them" {
    var current = try Config.default(testing.allocator);
    defer current.deinit();
    var defaults = try Config.default(testing.allocator);
    defer defaults.deinit();
    current.@"click-repeat-interval" = 500;
    const extra: [key_count][]const u8 = @splat("");
    var model: Model = .{};
    defer model.deinit();
    try model.build(testing.allocator, &current, &defaults, null, .none, &extra);
    try testing.expect(!model.rows[index(.@"click-repeat-interval")].differs);
    try model.build(testing.allocator, &current, &defaults, "f", .{ .bytes = "click-repeat-interval = 500" }, &extra);
    try testing.expect(model.rows[index(.@"click-repeat-interval")].differs);
}

/// `text` as the bytes of a UTF-16 file in `order`, byte order mark first.
fn utf16File(comptime text: []const u8, comptime order: std.builtin.Endian) [2 + 2 * text.len]u8 {
    var out: [2 + 2 * text.len]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], 0xFEFF, order);
    for (text, 0..) |c, i| std.mem.writeInt(u16, out[2 + 2 * i ..][0..2], c, order);
    return out;
}

test "settings reference reads the config file in the encodings Config reads" {
    const text = "# a comment\r\nfont-size = 15\r\nclick-repeat-interval = 500\r\n";
    const files = [_][]const u8{
        text,
        "\xef\xbb\xbf" ++ text,
        &utf16File(text, .little),
        &utf16File(text, .big),
        // An odd byte at the end, as a cut-off write leaves, goes as in Config.
        &utf16File(text, .little) ++ "\x00",
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (files) |file| try testing.expectEqualStrings(text, (try decodeConfigText(arena.allocator(), file)).?);
    // UTF-16 that does not decode (a lone surrogate) is no text at all.
    const lone = [_]u8{ 0xff, 0xfe, 0x00, 0xd8, 'a', 0 };
    try testing.expectEqual(@as(?[]const u8, null), try decodeConfigText(arena.allocator(), &lone));
}

test "settings reference finds where a BOM or UTF-16 config sets a key, and @modified with it" {
    var current = try Config.default(testing.allocator);
    defer current.deinit();
    var defaults = try Config.default(testing.allocator);
    defer defaults.deinit();
    // As `Config` leaves it after reading the file below: `finalize` would set
    // the interval from the system when the file did not.
    current.@"font-size" = 15;
    current.@"click-repeat-interval" = 500;
    const extra: [key_count][]const u8 = @splat("");
    const text = "click-repeat-interval = 500\r\nfont-size = 15\r\n";
    const files = [_][]const u8{ "\xef\xbb\xbf" ++ text, &utf16File(text, .little), &utf16File(text, .big) };
    var buf: [256]u8 = undefined;
    for (files) |file| {
        var model: Model = .{};
        defer model.deinit();
        try model.build(testing.allocator, &current, &defaults, "f", .{ .bytes = file }, &extra);
        const interval = &model.rows[index(.@"click-repeat-interval")];
        // The first line's key is found, so it is changed, and where.
        try testing.expect(interval.differs);
        var writer: std.Io.Writer = .fixed(&buf);
        try model.writeLocation(&writer, interval);
        try testing.expectEqualStrings("Set on line 1 of f.", writer.buffered());
        writer = .fixed(&buf);
        try model.writeLocation(&writer, &model.rows[index(.@"font-size")]);
        try testing.expectEqualStrings("Set on line 2 of f.", writer.buffered());
    }

    // A file that is there but cannot be read as text: where a key is set is
    // not known, so it is not said to be unset, and a key `finalize` works out
    // is changed by its value.
    for ([_]ConfigFile{ .unavailable, .{ .bytes = &[_]u8{ 0xff, 0xfe, 0x00, 0xd8 } } }) |file| {
        var model: Model = .{};
        defer model.deinit();
        try model.build(testing.allocator, &current, &defaults, "f", file, &extra);
        try testing.expect(!model.lines_known);
        try testing.expect(model.rows[index(.@"click-repeat-interval")].differs);
        try testing.expect(!model.rows[index(.term)].differs);
        var writer: std.Io.Writer = .fixed(&buf);
        try model.writeLocation(&writer, &model.rows[index(.@"font-size")]);
        try testing.expectEqualStrings("Not known where f sets it: Settings reads only a file on a local drive, as text, and could not read this one.", writer.buffered());
    }

    // No file yet: it sets nothing.
    var model: Model = .{};
    defer model.deinit();
    try model.build(testing.allocator, &current, &defaults, "f", .missing, &extra);
    try testing.expect(!model.rows[index(.@"click-repeat-interval")].differs);
    var writer: std.Io.Writer = .fixed(&buf);
    try model.writeLocation(&writer, &model.rows[index(.@"font-size")]);
    try testing.expectEqualStrings("Not set in f.", writer.buffered());
}

/// Command-line arguments with the places the loader gives them.
const TestArgs = struct {
    list: []const []const u8,
    at: usize = 0,

    pub fn next(self: *TestArgs) ?[]const u8 {
        if (self.at >= self.list.len) return null;
        defer self.at += 1;
        return self.list[self.at];
    }

    pub fn location(self: *const TestArgs, _: std.mem.Allocator) std.mem.Allocator.Error!?@import("../cli/diagnostics.zig").Location {
        return .{ .cli = self.at - 1 };
    }
};

test "settings reference says where a value comes from: an included file, the theme, the command line, and the line of this file it overrides" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\n" });
    try tmp.dir.writeFile(.{ .sub_path = "included.conf", .data = "\nfont-size = 15\nkeybind = ctrl+shift+y=new_tab\n" });
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = included.conf\ntheme = {s}\nkeybind = ctrl+shift+u=new_tab\n", .{theme_path});
    defer alloc.free(text);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "included.conf");
    defer alloc.free(included_path);

    var current = try Config.default(alloc);
    defer current.deinit();
    try current.loadFile(alloc, path);
    var args: TestArgs = .{ .list = &.{"--scrollback-limit=7"} };
    try current.loadIter(alloc, &args);
    try current.loadRecursiveFiles(alloc);
    try current.finalize();
    var defaults = try Config.default(alloc);
    defer defaults.deinit();

    // Settings names the file in other letters than the loader did.
    const named = try std.ascii.allocUpperString(alloc, path);
    defer alloc.free(named);
    const extra: [key_count][]const u8 = @splat("");
    var model: Model = .{};
    defer model.deinit();
    try model.build(alloc, &current, &defaults, named, .{ .bytes = text }, &extra);

    var buf: [1024]u8 = undefined;
    var expected: [1024]u8 = undefined;
    const Case = struct { key: Key, text: []const u8 };
    for ([_]Case{
        .{ .key = .@"font-size", .text = try std.fmt.bufPrint(expected[0..512], "Set on line 2 of {s}, a file config-file names. Line 1 of {s} sets it too, and does not take effect.", .{ included_path, named }) },
        .{ .key = .background, .text = try std.fmt.bufPrint(expected[512..], "Set on line 1 of {s}, the theme.", .{theme_path}) },
    }) |case| {
        errdefer std.debug.print("settings reference origin of {s}\n", .{@tagName(case.key)});
        var writer: std.Io.Writer = .fixed(&buf);
        try model.writeLocation(&writer, &model.rows[index(case.key)]);
        try testing.expectEqualStrings(case.text, writer.buffered());
    }
    var writer: std.Io.Writer = .fixed(&buf);
    try model.writeLocation(&writer, &model.rows[index(.@"scrollback-limit")]);
    try testing.expectEqualStrings("Set on the command line.", writer.buffered());
    // A key whose lines can add up: the included file's line is the last
    // one, and this file's is only said to be there, for whether it still
    // counts depends on what came after it.
    writer = .fixed(&buf);
    try model.writeLocation(&writer, &model.rows[index(.keybind)]);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Set on line 3 of {s}, a file config-file names. {s} also has a setting for it, on line 4.", .{ included_path, named }), writer.buffered());
    // A line of the file itself is said as before.
    writer = .fixed(&buf);
    try model.writeLocation(&writer, &model.rows[index(.theme)]);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Set on line 3 of {s}.", .{named}), writer.buffered());
    // A value `finalize` works out, which no line sets: the keys it fills in
    // even in a test build.
    var derived: usize = 0;
    for (resolved_when_unset) |key| if (model.rows[index(key)].origin == .derived) {
        derived += 1;
        writer = .fixed(&buf);
        try model.writeLocation(&writer, &model.rows[index(key)]);
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Not set in {s}: noctty chose this value when it read the config.", .{named}), writer.buffered());
    };
    try testing.expect(derived > 0);
    // Any other key's value no step set reads as the default.
    for (keys, 0..) |key, i| if (model.rows[i].origin == .derived) try testing.expect(resolvedWhenUnset(key));
}

test "settings reference does not claim a reset accumulating assignment still contributes" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The included file clears both lists the config file added to.
    try tmp.dir.writeFile(.{ .sub_path = "included.conf", .data = "keybind = clear\nfont-family =\n" });
    const text = "keybind = ctrl+shift+u=new_tab\nfont-family = Cascadia Code\nconfig-file = included.conf\n";
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "included.conf");
    defer alloc.free(included_path);

    var current = try Config.default(alloc);
    defer current.deinit();
    try current.loadFile(alloc, path);
    try current.loadRecursiveFiles(alloc);
    try current.finalize();
    try testing.expectEqual(@as(usize, 0), current.keybind.set.bindings.count());
    try testing.expectEqual(@as(usize, 0), current.@"font-family".list.items.len);

    const extra: [key_count][]const u8 = @splat("");
    var model: Model = .{};
    defer model.deinit();
    try model.build(alloc, &current, null, path, .{ .bytes = text }, &extra);
    var buf: [1024]u8 = undefined;
    var expected: [1024]u8 = undefined;
    const Case = struct { key: Key, included_line: usize, line: usize };
    for ([_]Case{
        .{ .key = .keybind, .included_line = 1, .line = 1 },
        .{ .key = .@"font-family", .included_line = 2, .line = 2 },
    }) |case| {
        errdefer std.debug.print("settings reference reset of {s}\n", .{@tagName(case.key)});
        var writer: std.Io.Writer = .fixed(&buf);
        try model.writeLocation(&writer, &model.rows[index(case.key)]);
        try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Set on line {d} of {s}, a file config-file names. {s} also has a setting for it, on line {d}.", .{ case.included_line, included_path, path, case.line }), writer.buffered());
    }
}

test "settings reference default-profile's shown value and location, with and without a command-line override" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "included.conf", .data = "default-profile = pwsh.exe\n" });
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "included.conf");
    defer alloc.free(included_path);

    const Where = union(enum) {
        /// Line 1 of the included file, and the line of the config file it
        /// overrides, if any.
        included: ?usize,
        /// A line of the config file.
        target: usize,
        not_set,
    };
    const Case = struct { text: []const u8, cli: bool, value: ?[]const u8, where: Where };
    for ([_]Case{
        // `config-file` after the config file's own line, and before it: the
        // included file is read after the whole config file either way.
        .{ .text = "font-size = 12\ndefault-profile = cmd.exe\nconfig-file = included.conf\n", .cli = true, .value = "pwsh.exe", .where = .{ .included = 2 } },
        .{ .text = "config-file = included.conf\ndefault-profile = cmd.exe\n", .cli = true, .value = "pwsh.exe", .where = .{ .included = 2 } },
        // The same without the command line's value.
        .{ .text = "config-file = included.conf\ndefault-profile = cmd.exe\n", .cli = false, .value = "pwsh.exe", .where = .{ .included = 2 } },
        // Only the included file sets it.
        .{ .text = "config-file = included.conf\n", .cli = true, .value = "pwsh.exe", .where = .{ .included = null } },
        // No file sets it.
        .{ .text = "font-size = 12\n", .cli = true, .value = null, .where = .not_set },
        // An optional include that is missing sets nothing.
        .{ .text = "default-profile = cmd.exe\nconfig-file = ?missing.conf\n", .cli = true, .value = "cmd.exe", .where = .{ .target = 1 } },
    }, 0..) |case, n| {
        errdefer std.debug.print("settings reference default-profile case {d}\n", .{n});
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = case.text });
        var current = try Config.default(alloc);
        defer current.deinit();
        try current.loadFile(alloc, path);
        const cli_args: []const []const u8 = if (case.cli) &.{"--default-profile=user:py312"} else &.{};
        var args: TestArgs = .{ .list = cli_args };
        try current.loadIter(alloc, &args);
        try current.loadRecursiveFiles(alloc);
        try current.finalize();
        // The value Settings shows (`useSavedValues`).
        const shown = current.defaultProfileFromFiles();
        if (case.value) |want|
            try testing.expectEqualStrings(want, shown orelse return error.TestUnexpectedResult)
        else
            try testing.expect(shown == null);

        const extra: [key_count][]const u8 = @splat("");
        var model: Model = .{};
        defer model.deinit();
        try model.build(alloc, &current, null, path, .{ .bytes = case.text }, &extra);
        var buf: [1024]u8 = undefined;
        var expected: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try model.writeLocation(&writer, &model.rows[index(.@"default-profile")]);
        const want = switch (case.where) {
            .included => |overridden| if (overridden) |line|
                try std.fmt.bufPrint(&expected, "Set on line 1 of {s}, a file config-file names. Line {d} of {s} sets it too, and does not take effect.", .{ included_path, line, path })
            else
                try std.fmt.bufPrint(&expected, "Set on line 1 of {s}, a file config-file names.", .{included_path}),
            .target => |line| try std.fmt.bufPrint(&expected, "Set on line {d} of {s}.", .{ line, path }),
            .not_set => try std.fmt.bufPrint(&expected, "Not set in {s}.", .{path}),
        };
        try testing.expectEqualStrings(want, writer.buffered());
    }
}

test "settings reference names -e for the shell-integration it set, and the file for a none it left" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "mytheme", .data = "background = #101010\n" });
    const theme_path = try tmp.dir.realpathAlloc(alloc, "mytheme");
    defer alloc.free(theme_path);
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = "\n" });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const themed = try std.fmt.allocPrint(alloc, "config-file = included.conf\ntheme = {s}\n", .{theme_path});
    defer alloc.free(themed);

    const Case = struct { include: []const u8, by_e: bool };
    for ([_]Case{
        .{ .include = "shell-integration = fish\n", .by_e = true },
        .{ .include = "shell-integration = none\n", .by_e = false },
    }) |case| {
        try tmp.dir.writeFile(.{ .sub_path = "included.conf", .data = case.include });
        const included_path = try tmp.dir.realpathAlloc(alloc, "included.conf");
        defer alloc.free(included_path);
        for ([_][]const u8{ "config-file = included.conf\n", themed }) |text| {
            errdefer std.debug.print("settings reference -e shell-integration case {s}", .{case.include});
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            var current = try Config.default(alloc);
            defer current.deinit();
            try current.loadFile(alloc, path);
            var args: TestArgs = .{ .list = &.{ "-e", "cmd.exe" } };
            try current.loadIter(alloc, &args);
            try current.loadRecursiveFiles(alloc);
            try current.finalize();

            const extra: [key_count][]const u8 = @splat("");
            var model: Model = .{};
            defer model.deinit();
            try model.build(alloc, &current, null, path, .{ .bytes = text }, &extra);
            var buf: [1024]u8 = undefined;
            var expected: [1024]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            try model.writeLocation(&writer, &model.rows[index(.@"shell-integration")]);
            const want = if (case.by_e)
                "Set on the command line."
            else
                try std.fmt.bufPrint(&expected, "Set on line 1 of {s}, a file config-file names.", .{included_path});
            try testing.expectEqualStrings(want, writer.buffered());
        }
    }
}

test "settings reference saved default-profile keeps its included-file origin under a CLI override" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The config file names A, a file it includes names B, and noctty's
    // command line names C.
    try tmp.dir.writeFile(.{ .sub_path = "included.conf", .data = "default-profile = pwsh.exe\n" });
    const text = "font-size = 12\ndefault-profile = cmd.exe\nconfig-file = included.conf\n";
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "config");
    defer alloc.free(path);
    const included_path = try tmp.dir.realpathAlloc(alloc, "included.conf");
    defer alloc.free(included_path);

    var current = try Config.default(alloc);
    defer current.deinit();
    try current.loadFile(alloc, path);
    var args: TestArgs = .{ .list = &.{ "--default-profile=user:py312", "--font-size=14" } };
    try current.loadIter(alloc, &args);
    try current.loadRecursiveFiles(alloc);
    try current.finalize();
    // The command line's value is the one in effect in this process, but
    // Settings shows, and saves over, the files': B, the included file's,
    // read last. That is where it comes from, not the config file's A.
    try testing.expectEqualStrings("user:py312", current.@"default-profile".?);
    try testing.expectEqual(origin.Origin{ .cli = 0 }, origin.of(&current, .@"default-profile", null));
    try testing.expectEqualStrings("pwsh.exe", current.defaultProfileFromFiles().?);
    const shown = savedOrigin(&current, .@"default-profile", null);
    try testing.expect(shown == .file);
    try testing.expectEqualStrings(included_path, shown.file.path);
    try testing.expectEqual(@as(usize, 1), shown.file.line);
    // Any other key the command line sets keeps that origin.
    try testing.expectEqual(@as(usize, 1), savedOrigin(&current, .@"font-size", null).cli);

    const extra: [key_count][]const u8 = @splat("");
    var model: Model = .{};
    defer model.deinit();
    try model.build(alloc, &current, null, path, .{ .bytes = text }, &extra);
    var buf: [1024]u8 = undefined;
    var expected: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try model.writeLocation(&writer, &model.rows[index(.@"default-profile")]);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Set on line 1 of {s}, a file config-file names. Line 2 of {s} sets it too, and does not take effect.", .{ included_path, path }), writer.buffered());

    // With no `default-profile` line in the config file, the included file's
    // line is still named, not "Not set".
    const bare = "config-file = included.conf\n";
    try tmp.dir.writeFile(.{ .sub_path = "config", .data = bare });
    var only_included = try Config.default(alloc);
    defer only_included.deinit();
    try only_included.loadFile(alloc, path);
    var again: TestArgs = .{ .list = &.{"--default-profile=user:py312"} };
    try only_included.loadIter(alloc, &again);
    try only_included.loadRecursiveFiles(alloc);
    try only_included.finalize();
    var bare_model: Model = .{};
    defer bare_model.deinit();
    try bare_model.build(alloc, &only_included, null, path, .{ .bytes = bare }, &extra);
    writer = .fixed(&buf);
    try bare_model.writeLocation(&writer, &bare_model.rows[index(.@"default-profile")]);
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "Set on line 1 of {s}, a file config-file names.", .{included_path}), writer.buffered());
}
