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
    /// Whether the defaults lack this binding (`identity`): the config file
    /// made it (`@modified` finds it).
    differs: bool = false,
    /// What the binding is, which its text does not always tell.
    identity: Identity = .{},
    /// The row's id, never 0, and no other row's (`Model.build`): a rebuild
    /// gives a row its last id only when it is the same binding (`identity`),
    /// and a new one otherwise. Not its place: a rebuild that sorts another
    /// binding in before it moves the row, and what UIA holds of the row must
    /// not then name that other one.
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

/// A binding as the config's binding set tells bindings apart: its table, its
/// flags, its keys, each with its whole modifier value (`Trigger.foldedEqual`),
/// and its actions in order (`Action.equal`, floats aside: `actionEql`). Its
/// text does not do: it prints only Super, Ctrl, Alt and Shift
/// (`Trigger.format`), so `caps_lock+ctrl+f12` and `ctrl+f12`, two bindings,
/// are written the same. Copied into the model's arena, so a rebuild can
/// compare its bindings with the last one's.
pub const Identity = struct {
    table: []const u8 = "",
    flags: Binding.Flags = .{},
    keys: []const Binding.Trigger = &.{},
    actions: []const Binding.Action = &.{},

    fn copy(alloc: std.mem.Allocator, table: ?[]const u8, flags: Binding.Flags, keys: []const Binding.Trigger, actions: []const Binding.Action) !Identity {
        const cloned = try alloc.alloc(Binding.Action, actions.len);
        for (actions, cloned) |action, *into| into.* = try action.clone(alloc);
        return .{
            .table = try alloc.dupe(u8, table orelse ""),
            .flags = flags,
            .keys = try alloc.dupe(Binding.Trigger, keys),
            .actions = cloned,
        };
    }

    pub fn eql(a: Identity, b: Identity) bool {
        if (!std.mem.eql(u8, a.table, b.table)) return false;
        if (!std.meta.eql(a.flags, b.flags)) return false;
        if (a.keys.len != b.keys.len or a.actions.len != b.actions.len) return false;
        for (a.keys, b.keys) |x, y| if (!x.foldedEqual(y)) return false;
        for (a.actions, b.actions) |x, y| if (!actionEql(x, y)) return false;
        return true;
    }

    /// Equal identities hash alike. Only for finding candidates: `eql`
    /// decides.
    fn hash(self: Identity) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.table);
        for (self.keys) |key| std.hash.autoHash(&hasher, key.hash());
        for (self.actions) |action| std.hash.autoHash(&hasher, actionHash(action));
        return hasher.final();
    }
};

/// Whether two actions are one for `Identity`: `Action.equal`, except for a
/// float parameter (`scroll_page_fractional:-0`), which it compares with `==`.
/// Under `==`, `-0` is `0` while `Action.hash` hashes their bits apart, so the
/// lookup would not find an equal binding; and NaN is not even itself, so a
/// binding with a NaN parameter would never be the same binding again. Here
/// `-0` is `0`, every NaN is every other, and `actionHash` agrees.
fn actionEql(a: Binding.Action, b: Binding.Action) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        inline else => |value, tag| switch (@TypeOf(value)) {
            f32, f64 => value == @field(b, @tagName(tag)) or
                (std.math.isNan(value) and std.math.isNan(@field(b, @tagName(tag)))),
            else => a.equal(b),
        },
    };
}

/// `Action.hash`, with a float parameter hashed by a value equal ones share
/// (`actionEql`): `-0` as `0`, and every NaN alike. Floats are only ever the
/// whole parameter: `Action.hash` hashes anything else with `autoHash`, which
/// takes no floats.
fn actionHash(action: Binding.Action) u64 {
    return switch (action) {
        inline else => |value, tag| switch (@TypeOf(value)) {
            f32, f64 => hash: {
                const Float = @TypeOf(value);
                const same: Float = if (std.math.isNan(value)) std.math.nan(Float) else if (value == 0) 0 else value;
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, tag);
                std.hash.autoHash(&hasher, @as(std.meta.Int(.unsigned, @bitSizeOf(Float)), @bitCast(same)));
                break :hash hasher.final();
            },
            else => action.hash(),
        },
    };
}

/// Find a row whose binding equals another: the hash finds the candidates,
/// `Identity.eql` decides.
const Lookup = struct {
    rows: []const Row,
    first: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// The next row with the same hash.
    next: []?u32 = &.{},

    fn init(gpa: std.mem.Allocator, rows: []const Row) !Lookup {
        var self: Lookup = .{ .rows = rows };
        errdefer self.deinit(gpa);
        self.next = try gpa.alloc(?u32, rows.len);
        for (rows, 0..) |row, index| {
            const entry = try self.first.getOrPut(gpa, row.identity.hash());
            self.next[index] = if (entry.found_existing) entry.value_ptr.* else null;
            entry.value_ptr.* = @intCast(index);
        }
        return self;
    }

    fn deinit(self: *Lookup, gpa: std.mem.Allocator) void {
        self.first.deinit(gpa);
        gpa.free(self.next);
    }

    fn find(self: *const Lookup, identity: Identity) ?*const Row {
        var at = self.first.get(identity.hash());
        while (at) |index| : (at = self.next[index]) {
            if (self.rows[index].identity.eql(identity)) return &self.rows[index];
        }
        return null;
    }
};

pub const Model = struct {
    arena: ?std.heap.ArenaAllocator = null,
    rows: []const Row = &.{},
    /// Whether the rows were compared with the defaults (`Row.differs`).
    compared: bool = false,
    /// The id the next new binding gets. It outlives the rows, so no id is
    /// ever given to a second binding.
    next_id: u64 = 1,

    pub fn deinit(self: *Model) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{ .next_id = self.next_id };
    }

    pub fn built(self: *const Model) bool {
        return self.arena != null;
    }

    /// Build a row for every binding in `keybinds`, the root set's first and
    /// then each key table's, each group in order of action and then keys.
    /// A row differs when `defaults` (the bindings of `Config.default`, null
    /// when there are none to compare with: nothing then differs) lacks it.
    /// On failure the model is left empty.
    /// A row that is the same binding as one of the last build's keeps that
    /// row's id; any other row gets a new one (`next_id`).
    pub fn build(self: *Model, gpa: std.mem.Allocator, keybinds: *const Config.Keybinds, defaults: ?*const Config.Keybinds) !void {
        errdefer self.deinit();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        var builder: Builder = .{ .alloc = arena.allocator(), .scratch = .init(gpa) };
        defer builder.scratch.deinit();
        try builder.addKeybinds(keybinds);
        if (defaults) |default_keybinds| {
            // The defaults' bindings alone, in an arena of their own, to
            // compare with: nothing else of them is kept.
            var scratch_arena: std.heap.ArenaAllocator = .init(gpa);
            defer scratch_arena.deinit();
            var default_builder: Builder = .{ .alloc = scratch_arena.allocator(), .scratch = .init(gpa), .identities_only = true };
            defer default_builder.scratch.deinit();
            try default_builder.addKeybinds(default_keybinds);
            var lookup: Lookup = try .init(gpa, default_builder.rows.items);
            defer lookup.deinit(gpa);
            for (builder.rows.items) |*row| row.differs = lookup.find(row.identity) == null;
        }
        {
            var lookup: Lookup = try .init(gpa, self.rows);
            defer lookup.deinit(gpa);
            for (builder.rows.items) |*row| {
                if (lookup.find(row.identity)) |last| {
                    row.id = last.id;
                } else {
                    row.id = self.next_id;
                    self.next_id += 1;
                }
            }
        }
        self.deinit();
        self.rows = builder.rows.items;
        self.compared = defaults != null;
        self.arena = arena;
    }
};

const Builder = struct {
    alloc: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    /// Make only each row's `identity` (the defaults, to compare with),
    /// unsorted.
    identities_only: bool = false,
    /// Each action's documentation as plain text, made once.
    docs: [action_count]?[]const u8 = @splat(null),
    scratch: std.Io.Writer.Allocating,

    fn addKeybinds(self: *Builder, keybinds: *const Config.Keybinds) !void {
        try self.addSet(&keybinds.set, null);
        if (!self.identities_only) std.sort.pdq(Row, self.rows.items, {}, Row.lessThan);
        var tables = keybinds.tables.iterator();
        while (tables.next()) |table| {
            const start = self.rows.items.len;
            try self.addSet(table.value_ptr, table.key_ptr.*);
            if (!self.identities_only) std.sort.pdq(Row, self.rows.items[start..], {}, Row.lessThan);
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
        const identity: Identity = try .copy(alloc, table, flags, keys, actions);
        if (self.identities_only) {
            try self.rows.append(alloc, .{ .trigger = "", .action = "", .doc = "", .summary = "", .entry = "", .search = "", .identity = identity });
            return;
        }
        var trigger: std.Io.Writer.Allocating = .init(alloc);
        if (table) |name| try trigger.writer.print("{s}/", .{name});
        try writeFlags(&trigger.writer, flags);
        for (keys, 0..) |key, i| try trigger.writer.print("{s}{f}", .{ if (i == 0) "" else ">", key });

        var action: std.Io.Writer.Allocating = .init(alloc);
        for (actions, 0..) |item, i| try action.writer.print("{s}{f}", .{ if (i == 0) "" else ", then ", item });

        var entry: std.Io.Writer.Allocating = .init(alloc);
        try entry.writer.print("keybind = {s}={f}", .{ trigger.written(), actions[0] });
        for (actions[1..]) |item| try entry.writer.print("\nkeybind = chain={f}", .{item});
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
            .identity = identity,
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

test "keybinds a binding with a lock modifier is a binding of its own, though its text is another's" {
    const alloc = std.testing.allocator;
    var config = try Config.default(alloc);
    defer config.deinit();
    const arena = config._arena.?.allocator();
    try config.keybind.parseCLI(arena, "clear");
    try config.keybind.parseCLI(arena, "ctrl+f12=new_tab");
    try config.keybind.parseCLI(arena, "caps_lock+ctrl+f12=new_tab");
    // The defaults to compare with have the plain one only.
    var defaults = try Config.default(alloc);
    defer defaults.deinit();
    try defaults.keybind.parseCLI(defaults._arena.?.allocator(), "clear");
    try defaults.keybind.parseCLI(defaults._arena.?.allocator(), "ctrl+f12=new_tab");
    var model: Model = .{};
    defer model.deinit();
    try model.build(alloc, &config.keybind, &defaults.keybind);
    // Two bindings, which the config file writes the same way (the lock
    // modifier is not printed), with two ids.
    try std.testing.expectEqual(@as(usize, 2), model.rows.len);
    for (model.rows) |row| try std.testing.expectEqualStrings("keybind = ctrl+f12=new_tab", row.entry);
    try std.testing.expect(model.rows[0].id != model.rows[1].id);
    try std.testing.expect(!model.rows[0].identity.eql(model.rows[1].identity));
    // The defaults have one of them, and lack the other.
    for (model.rows) |row| try std.testing.expectEqual(row.identity.keys[0].mods.caps_lock, row.differs);
}

test "keybinds a rebuild keeps a binding's id, and gives it to no other binding" {
    const alloc = std.testing.allocator;
    const Ids = struct {
        /// The id of the row whose key has `caps_lock` as asked, if any.
        fn of(model: *const Model, caps_lock: bool) ?u64 {
            for (model.rows) |row| if (row.identity.keys[0].mods.caps_lock == caps_lock) return row.id;
            return null;
        }
    };
    var model: Model = .{};
    defer model.deinit();
    var both = try Config.default(alloc);
    defer both.deinit();
    try both.keybind.parseCLI(both._arena.?.allocator(), "clear");
    try both.keybind.parseCLI(both._arena.?.allocator(), "ctrl+f12=new_tab");
    try both.keybind.parseCLI(both._arena.?.allocator(), "caps_lock+ctrl+f12=new_tab");
    try model.build(alloc, &both.keybind, null);
    const plain = Ids.of(&model, false).?;
    const locked = Ids.of(&model, true).?;
    try std.testing.expect(plain != 0 and locked != 0 and plain != locked);
    // The same bindings: the same ids.
    try model.build(alloc, &both.keybind, null);
    try std.testing.expectEqual(plain, Ids.of(&model, false).?);
    try std.testing.expectEqual(locked, Ids.of(&model, true).?);
    // The locked one alone keeps its id.
    var only_locked = try Config.default(alloc);
    defer only_locked.deinit();
    try only_locked.keybind.parseCLI(only_locked._arena.?.allocator(), "clear");
    try only_locked.keybind.parseCLI(only_locked._arena.?.allocator(), "caps_lock+ctrl+f12=new_tab");
    try model.build(alloc, &only_locked.keybind, null);
    try std.testing.expectEqual(@as(usize, 1), model.rows.len);
    try std.testing.expectEqual(locked, model.rows[0].id);
    // Replaced by the plain one, written the same: a new id, neither of
    // the others.
    var only_plain = try Config.default(alloc);
    defer only_plain.deinit();
    try only_plain.keybind.parseCLI(only_plain._arena.?.allocator(), "clear");
    try only_plain.keybind.parseCLI(only_plain._arena.?.allocator(), "ctrl+f12=new_tab");
    try model.build(alloc, &only_plain.keybind, null);
    try std.testing.expectEqual(@as(usize, 1), model.rows.len);
    try std.testing.expect(model.rows[0].id != locked and model.rows[0].id != plain);
    // Nor does going without the model start the ids again.
    const last = model.rows[0].id;
    model.deinit();
    try model.build(alloc, &only_plain.keybind, null);
    try std.testing.expect(model.rows[0].id > last);
    // The same keys and action with another flag: another binding. Flags
    // are not in the lookup's hash, so only equality tells them apart.
    const unflagged = model.rows[0].id;
    var flagged = try Config.default(alloc);
    defer flagged.deinit();
    try flagged.keybind.parseCLI(flagged._arena.?.allocator(), "clear");
    try flagged.keybind.parseCLI(flagged._arena.?.allocator(), "unconsumed:ctrl+f12=new_tab");
    try model.build(alloc, &flagged.keybind, null);
    try std.testing.expectEqual(@as(usize, 1), model.rows.len);
    try std.testing.expect(model.rows[0].id != unflagged);
}

test "keybinds a float parameter is the same binding with a zero of either sign, and with any NaN" {
    const key: Binding.Trigger = .{ .mods = .{ .ctrl = true }, .key = .{ .physical = .f12 } };
    const Pair = struct { a: f32, b: f32 };
    const other_nan: f32 = @bitCast(@as(u32, 0x7fc0_0001));
    for ([_]Pair{
        .{ .a = 0.0, .b = -0.0 },
        .{ .a = std.math.nan(f32), .b = std.math.nan(f32) },
        .{ .a = std.math.nan(f32), .b = other_nan },
    }, 0..) |pair, index| {
        errdefer std.debug.print("keybinds float pair {d}\n", .{index});
        const a: Identity = .{ .keys = &.{key}, .actions = &.{.{ .scroll_page_fractional = pair.a }} };
        const b: Identity = .{ .keys = &.{key}, .actions = &.{.{ .scroll_page_fractional = pair.b }} };
        try std.testing.expect(a.eql(b) and b.eql(a));
        try std.testing.expect(a.eql(a));
        try std.testing.expectEqual(a.hash(), b.hash());
    }
    // Still not one for another value, or another action.
    const half: Identity = .{ .keys = &.{key}, .actions = &.{.{ .scroll_page_fractional = 0.5 }} };
    try std.testing.expect(!half.eql(.{ .keys = &.{key}, .actions = &.{.{ .scroll_page_fractional = 0.0 }} }));
    try std.testing.expect(!half.eql(.{ .keys = &.{key}, .actions = &.{.{ .set_font_size = 0.5 }} }));
}

test "keybinds a reload that only flips a float parameter's zero, or reads nan again, keeps the id, and defaults written the other way do not differ" {
    const alloc = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "ctrl+f12=scroll_page_fractional:0", "ctrl+f12=scroll_page_fractional:-0" },
        .{ "ctrl+f12=scroll_page_fractional:nan", "ctrl+f12=scroll_page_fractional:nan" },
    }) |lines| {
        errdefer std.debug.print("keybinds float lines {s} then {s}\n", .{ lines[0], lines[1] });
        var first = try Config.default(alloc);
        defer first.deinit();
        try first.keybind.parseCLI(first._arena.?.allocator(), "clear");
        try first.keybind.parseCLI(first._arena.?.allocator(), lines[0]);
        var second = try Config.default(alloc);
        defer second.deinit();
        try second.keybind.parseCLI(second._arena.?.allocator(), "clear");
        try second.keybind.parseCLI(second._arena.?.allocator(), lines[1]);
        var model: Model = .{};
        defer model.deinit();
        try model.build(alloc, &first.keybind, &second.keybind);
        try std.testing.expectEqual(@as(usize, 1), model.rows.len);
        try std.testing.expect(!model.rows[0].differs);
        const id = model.rows[0].id;
        try model.build(alloc, &second.keybind, &first.keybind);
        try std.testing.expectEqual(id, model.rows[0].id);
        try std.testing.expect(!model.rows[0].differs);
    }
}

test "keybinds an identity is the table, the flags, every modifier of every key and each action" {
    const key: Binding.Trigger = .{ .mods = .{ .ctrl = true }, .key = .{ .physical = .f12 } };
    const base: Identity = .{ .keys = &.{key}, .actions = &.{.new_tab} };
    try std.testing.expect(base.eql(.{ .keys = &.{key}, .actions = &.{.new_tab} }));
    try std.testing.expectEqual(base.hash(), (Identity{ .keys = &.{key}, .actions = &.{.new_tab} }).hash());
    // A key the set folds to the same one is the same binding.
    const lower: Binding.Trigger = .{ .mods = .{ .ctrl = true }, .key = .{ .unicode = 'a' } };
    const upper: Binding.Trigger = .{ .mods = .{ .ctrl = true }, .key = .{ .unicode = 'A' } };
    try std.testing.expect((Identity{ .keys = &.{lower}, .actions = &.{.new_tab} }).eql(.{ .keys = &.{upper}, .actions = &.{.new_tab} }));

    var caps = key;
    caps.mods.caps_lock = true;
    var num = key;
    num.mods.num_lock = true;
    var shift = key;
    shift.mods.shift = true;
    var f11 = key;
    f11.key = .{ .physical = .f11 };
    for ([_]Identity{
        .{ .table = "other", .keys = &.{key}, .actions = &.{.new_tab} },
        .{ .flags = .{ .global = true }, .keys = &.{key}, .actions = &.{.new_tab} },
        .{ .flags = .{ .consumed = false }, .keys = &.{key}, .actions = &.{.new_tab} },
        .{ .keys = &.{caps}, .actions = &.{.new_tab} },
        .{ .keys = &.{num}, .actions = &.{.new_tab} },
        .{ .keys = &.{shift}, .actions = &.{.new_tab} },
        .{ .keys = &.{f11}, .actions = &.{.new_tab} },
        .{ .keys = &.{ key, key }, .actions = &.{.new_tab} },
        .{ .keys = &.{key}, .actions = &.{.new_window} },
        .{ .keys = &.{key}, .actions = &.{ .new_tab, .new_window } },
    }, 0..) |other, index| {
        errdefer std.debug.print("keybinds identity {d} equals the base\n", .{index});
        try std.testing.expect(!base.eql(other));
        try std.testing.expect(!other.eql(base));
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
    // The same keys and action in a second table: another binding.
    try config.keybind.parseCLI(arena, "other/ctrl+b=reset");
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

    // One trigger in two tables is two bindings, with two ids.
    var in_tables: [2]u64 = undefined;
    var found: usize = 0;
    for (model.rows) |row| {
        if (std.mem.endsWith(u8, row.trigger, "/ctrl+b") and std.mem.eql(u8, row.action, "reset")) {
            in_tables[found] = row.id;
            found += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), found);
    try std.testing.expect(in_tables[0] != in_tables[1]);
    // A rebuild gives every binding its id again, each table's its own.
    const before = try alloc.alloc(u64, model.rows.len);
    defer alloc.free(before);
    for (model.rows, before) |row, *id| id.* = row.id;
    try model.build(alloc, &config.keybind, &defaults.keybind);
    for (model.rows, before) |row, id| try std.testing.expectEqual(id, row.id);

    // The default table's bindings by action, then each other table's (the
    // defaults have `copy_mode`), the one added last last.
    try std.testing.expectEqualStrings("", model.rows[0].table);
    try std.testing.expectEqualStrings("other", model.rows[model.rows.len - 1].table);
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
