//! The model behind the Keybindings page's list: every key binding in effect
//! (`Config.keybind`, the defaults with the config file's changes), the action
//! it runs, and that action's documentation as plain text. No windows here:
//! `win32_settings.zig` draws the list and owns its HWND.

const std = @import("std");
const Config = @import("../config/Config.zig");
const Binding = @import("../input/Binding.zig");
const help_strings = @import("help_strings");
const settings_reference = @import("win32_settings_reference.zig");

/// One binding: the keys and what they run.
pub const Row = struct {
    /// The key table the binding is in; empty for the default one.
    table: []const u8 = "",
    /// The keys to press, as the config file writes them: a key table's name
    /// and `/` first, then any flags (`global:`, `all:`, `unconsumed:`,
    /// `performable:`), then the keys, with `>` between those of a sequence.
    trigger: []const u8,
    /// The action as the config file writes it. A chain's later actions
    /// follow, each after ", then ".
    action: []const u8,
    /// The documentation as plain text: the first action's, and for a chain
    /// each later action's after "Then <action>:". Its first sentence (the
    /// first action's).
    doc: []const u8,
    summary: []const u8,
    /// The binding as config lines (`keybind = ...`, a chain's later actions
    /// on `keybind = chain=...` lines), for copying.
    entry: []const u8,
    /// What the search finds the row by, in lower case: the keys, the
    /// actions and the documentation.
    search: []const u8,
    /// Whether the defaults lack this binding, keys, flags and actions alike:
    /// the config file made it (`@modified` finds it).
    differs: bool = false,
    /// The binding's identity, from its `keybind` lines (table, flags, keys
    /// and actions; no two bindings in effect share them), never 0. Not its
    /// place: a rebuild that sorts another binding in before it moves the
    /// row, and what UIA holds of the row must not then name that other one.
    id: u64 = 0,

    /// By action, then by keys, so an action's bindings are together.
    fn lessThan(_: void, a: Row, b: Row) bool {
        return switch (std.mem.order(u8, a.action, b.action)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.order(u8, a.trigger, b.trigger) == .lt,
        };
    }
};

pub const Model = struct {
    arena: ?std.heap.ArenaAllocator = null,
    rows: []const Row = &.{},
    /// Whether the rows were compared with the defaults (`Row.differs`).
    compared: bool = false,

    pub fn deinit(self: *Model) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    pub fn built(self: *const Model) bool {
        return self.arena != null;
    }

    /// Build a row for every binding in `keybinds`, the root set's first and
    /// then each key table's, each group in order of action and then keys.
    /// A row differs when `defaults` (the bindings of `Config.default`, null
    /// when there are none to compare with: nothing then differs) lacks it.
    /// On failure the model is left empty.
    pub fn build(self: *Model, gpa: std.mem.Allocator, keybinds: *const Config.Keybinds, defaults: ?*const Config.Keybinds) !void {
        self.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var builder: Builder = .{ .alloc = arena.allocator(), .scratch = .init(gpa) };
        defer builder.scratch.deinit();
        try builder.addKeybinds(keybinds);
        if (defaults) |default_keybinds| {
            // The defaults' config lines alone, in an arena of their own, to
            // compare with: nothing else of them is kept.
            var scratch_arena: std.heap.ArenaAllocator = .init(gpa);
            defer scratch_arena.deinit();
            var default_builder: Builder = .{ .alloc = scratch_arena.allocator(), .scratch = .init(gpa), .entries_only = true };
            defer default_builder.scratch.deinit();
            try default_builder.addKeybinds(default_keybinds);
            var entries: std.StringHashMapUnmanaged(void) = .empty;
            defer entries.deinit(gpa);
            for (default_builder.rows.items) |row| try entries.put(gpa, row.entry, {});
            for (builder.rows.items) |*row| row.differs = !entries.contains(row.entry);
        }
        self.rows = builder.rows.items;
        self.compared = defaults != null;
        self.arena = arena;
    }
};

const Builder = struct {
    alloc: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// Make only each row's `trigger` and `entry` (the defaults, to compare
    /// with), unsorted.
    entries_only: bool = false,
    /// Each action's documentation as plain text, made once.
    docs: [action_count]?[]const u8 = @splat(null),
    scratch: std.Io.Writer.Allocating,

    fn addKeybinds(self: *Builder, keybinds: *const Config.Keybinds) !void {
        try self.addSet(&keybinds.set, null);
        if (!self.entries_only) std.sort.pdq(Row, self.rows.items, {}, Row.lessThan);
        var tables = keybinds.tables.iterator();
        while (tables.next()) |table| {
            const start = self.rows.items.len;
            try self.addSet(table.value_ptr, table.key_ptr.*);
            if (!self.entries_only) std.sort.pdq(Row, self.rows.items[start..], {}, Row.lessThan);
        }
    }

    fn addSet(self: *Builder, set: *const Binding.Set, table: ?[]const u8) !void {
        var keys: std.ArrayListUnmanaged(Binding.Trigger) = .empty;
        defer keys.deinit(self.alloc);
        try self.addBindings(set, table, &keys);
    }

    /// Every binding of `set`, its keys after `prefix` (the leader keys of a
    /// sequence).
    fn addBindings(self: *Builder, set: *const Binding.Set, table: ?[]const u8, prefix: *std.ArrayListUnmanaged(Binding.Trigger)) !void {
        var iter = set.bindings.iterator();
        while (iter.next()) |entry| {
            try prefix.append(self.alloc, entry.key_ptr.*);
            defer _ = prefix.pop();
            switch (entry.value_ptr.*) {
                .leader => |leader| try self.addBindings(leader, table, prefix),
                .leaf => |leaf| try self.addRow(table, prefix.items, leaf.flags, &.{leaf.action}),
                .leaf_chained => |leaf| try self.addRow(table, prefix.items, leaf.flags, leaf.actions.items),
            }
        }
    }

    fn addRow(self: *Builder, table: ?[]const u8, keys: []const Binding.Trigger, flags: Binding.Flags, actions: []const Binding.Action) !void {
        if (actions.len == 0) return;
        const alloc = self.alloc;
        var trigger: std.Io.Writer.Allocating = .init(alloc);
        if (table) |name| try trigger.writer.print("{s}/", .{name});
        try writeFlags(&trigger.writer, flags);
        for (keys, 0..) |key, i| try trigger.writer.print("{s}{f}", .{ if (i == 0) "" else ">", key });

        var action: std.Io.Writer.Allocating = .init(alloc);
        for (actions, 0..) |item, i| try action.writer.print("{s}{f}", .{ if (i == 0) "" else ", then ", item });

        var entry: std.Io.Writer.Allocating = .init(alloc);
        try entry.writer.print("keybind = {s}={f}", .{ trigger.written(), actions[0] });
        for (actions[1..]) |item| try entry.writer.print("\nkeybind = chain={f}", .{item});
        if (self.entries_only) {
            try self.rows.append(alloc, .{ .trigger = trigger.written(), .action = "", .doc = "", .summary = "", .entry = entry.written(), .search = "" });
            return;
        }

        const first_doc = try self.actionDoc(actions[0]);
        const doc = if (actions.len == 1) first_doc else chained: {
            var all: std.Io.Writer.Allocating = .init(alloc);
            try all.writer.writeAll(first_doc);
            for (actions[1..]) |item| try all.writer.print("\n\nThen {f}: {s}", .{ item, try self.actionDoc(item) });
            break :chained all.written();
        };
        var search: std.Io.Writer.Allocating = .init(alloc);
        try search.writer.print("{s}\n{s}\n{s}", .{ trigger.written(), action.written(), doc });
        const lowered = search.written();
        for (lowered) |*c| c.* = std.ascii.toLower(c.*);

        try self.rows.append(alloc, .{
            .id = bindingId(entry.written()),
            .table = table orelse "",
            .trigger = trigger.written(),
            .action = action.written(),
            .doc = doc,
            .summary = settings_reference.summaryOf(first_doc),
            .entry = entry.written(),
            .search = lowered,
        });
    }

    fn actionDoc(self: *Builder, action: Binding.Action) ![]const u8 {
        const tag = @intFromEnum(std.meta.activeTag(action));
        if (self.docs[tag]) |doc| return doc;
        self.scratch.clearRetainingCapacity();
        try settings_reference.writePlain(&self.scratch.writer, action_raw_docs[tag]);
        const doc = try self.alloc.dupe(u8, self.scratch.written());
        self.docs[tag] = doc;
        return doc;
    }
};

/// `Row.id` for a binding written as `entry`.
fn bindingId(entry: []const u8) u64 {
    const hash = std.hash.Wyhash.hash(0, entry);
    return if (hash == 0) 1 else hash;
}

/// The flags a binding was written with, as the config file writes them
/// before its keys. A binding consumes its keys unless it says otherwise.
fn writeFlags(writer: *std.Io.Writer, flags: Binding.Flags) !void {
    if (flags.global) try writer.writeAll("global:");
    if (flags.all) try writer.writeAll("all:");
    if (!flags.consumed) try writer.writeAll("unconsumed:");
    if (flags.performable) try writer.writeAll("performable:");
}

const action_tags = std.meta.fields(std.meta.Tag(Binding.Action));
const action_count = action_tags.len;

/// Each action's documentation as `help_strings` holds it (Markdown-ish text
/// from its doc comment), by tag; empty for an internal action (`_` first),
/// which the generator leaves out.
const action_raw_docs: [action_count][]const u8 = docs: {
    @setEvalBranchQuota(100_000);
    var result: [action_count][]const u8 = undefined;
    for (action_tags) |tag| {
        result[tag.value] = if (@hasDecl(help_strings.KeybindAction, tag.name)) @field(help_strings.KeybindAction, tag.name) else "";
    }
    break :docs result;
};

comptime {
    // `action_raw_docs` is indexed by tag value.
    for (action_tags, 0..) |tag, i| if (tag.value != i) @compileError("Binding.Action's tags are not dense");
}

test "keybinds every action has documentation the list shows as plain text" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    inline for (action_tags) |tag| {
        const raw = action_raw_docs[tag.value];
        if (tag.name[0] == '_') continue;
        errdefer std.debug.print("keybind action {s}\n", .{tag.name});
        writer.clearRetainingCapacity();
        try settings_reference.writePlain(&writer.writer, raw);
        try std.testing.expect(writer.written().len != 0);
        try std.testing.expect(std.mem.indexOf(u8, writer.written(), "**") == null);
        try std.testing.expect(settings_reference.summaryOf(writer.written()).len != 0);
    }
}

test "keybinds the list holds every binding in effect, sequences, chains, flags and tables included" {
    const alloc = std.testing.allocator;
    var config = try Config.default(alloc);
    defer config.deinit();
    const arena = config._arena.?.allocator();
    try config.keybind.parseCLI(arena, "ctrl+a>n=new_window");
    try config.keybind.parseCLI(arena, "global:ctrl+alt+z=toggle_quick_terminal");
    try config.keybind.parseCLI(arena, "ctrl+alt+y=new_tab");
    try config.keybind.parseCLI(arena, "chain=close_surface");
    try config.keybind.parseCLI(arena, "mine/ctrl+b=reset");
    var defaults = try Config.default(alloc);
    defer defaults.deinit();
    var model: Model = .{};
    defer model.deinit();
    try model.build(alloc, &config.keybind, &defaults.keybind);
    try std.testing.expect(model.built());
    try std.testing.expect(model.compared);
    // Every binding its own identity (`Row.id`), never 0.
    var ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer ids.deinit(alloc);
    for (model.rows) |row| {
        try std.testing.expect(row.id != 0);
        try std.testing.expect(!(try ids.getOrPut(alloc, row.id)).found_existing);
    }

    const Want = struct { trigger: []const u8, action: []const u8, entry: []const u8, differs: bool = true };
    for ([_]Want{
        .{ .trigger = "performable:ctrl+shift+c", .action = "copy_to_clipboard:mixed", .entry = "keybind = performable:ctrl+shift+c=copy_to_clipboard:mixed", .differs = false },
        .{ .trigger = "ctrl+a>n", .action = "new_window", .entry = "keybind = ctrl+a>n=new_window" },
        .{ .trigger = "global:ctrl+alt+z", .action = "toggle_quick_terminal", .entry = "keybind = global:ctrl+alt+z=toggle_quick_terminal" },
        .{ .trigger = "ctrl+alt+y", .action = "new_tab, then close_surface", .entry = "keybind = ctrl+alt+y=new_tab\nkeybind = chain=close_surface" },
        .{ .trigger = "mine/ctrl+b", .action = "reset", .entry = "keybind = mine/ctrl+b=reset" },
    }) |want| {
        errdefer std.debug.print("keybinds row {s}\n", .{want.trigger});
        const row = for (model.rows) |row| {
            if (std.mem.eql(u8, row.trigger, want.trigger)) break row;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(want.action, row.action);
        try std.testing.expectEqualStrings(want.entry, row.entry);
        try std.testing.expectEqual(want.differs, row.differs);
        try std.testing.expect(row.doc.len != 0 and row.summary.len != 0);
        try std.testing.expect(std.mem.startsWith(u8, row.doc, row.summary));
        // Found by its keys, its action and a word of its documentation.
        try std.testing.expect(std.mem.indexOf(u8, row.search, want.trigger) != null);
        try std.testing.expect(std.mem.indexOf(u8, row.search, want.action) != null);
    }
    // A chain's row has every action's documentation, in its text and its
    // search, and its first sentence is the first action's.
    const chain = for (model.rows) |row| {
        if (std.mem.eql(u8, row.trigger, "ctrl+alt+y")) break row;
    } else return error.TestUnexpectedResult;
    var close_doc: std.Io.Writer.Allocating = .init(alloc);
    defer close_doc.deinit();
    try settings_reference.writePlain(&close_doc.writer, action_raw_docs[@intFromEnum(Binding.Action.close_surface)]);
    const close_summary = settings_reference.summaryOf(close_doc.written());
    try std.testing.expect(std.mem.indexOf(u8, chain.doc, "\n\nThen close_surface: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain.doc, close_summary) != null);
    const lower_summary = try std.ascii.allocLowerString(alloc, close_summary);
    defer alloc.free(lower_summary);
    try std.testing.expect(std.mem.indexOf(u8, chain.search, lower_summary) != null);
    try std.testing.expect(std.mem.indexOf(u8, chain.summary, close_summary) == null);

    // The default table's bindings by action, then each other table's (the
    // defaults have `copy_mode`), the one added last last.
    try std.testing.expectEqualStrings("", model.rows[0].table);
    try std.testing.expectEqualStrings("mine", model.rows[model.rows.len - 1].table);
    var tables_seen: usize = 0;
    for (model.rows[0 .. model.rows.len - 1], model.rows[1..]) |a, b| {
        errdefer std.debug.print("keybinds rows out of order: {s}={s} before {s}={s}\n", .{ a.trigger, a.action, b.trigger, b.action });
        if (!std.mem.eql(u8, a.table, b.table)) {
            tables_seen += 1;
            continue;
        }
        try std.testing.expect(!Row.lessThan({}, b, a));
    }
    try std.testing.expectEqual(config.keybind.tables.count(), tables_seen);
}
