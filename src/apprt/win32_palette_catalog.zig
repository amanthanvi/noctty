//! Production adapter between Ghostty action snapshots and the universal
//! Win32 palette ranker.
//!
//! The catalog borrows all display and payload strings. Callers own parallel
//! item/payload storage and must keep source data alive until the catalog is
//! reset. No HWND or terminal Surface references are retained.

const std = @import("std");
const universal = @import("win32_universal_palette.zig");

pub const Kind = universal.Kind;
pub const Item = universal.Item;
pub const Ranked = universal.Ranked;
pub const RankOptions = universal.Options;

pub const TransferDirection = enum { left, right, up, down };

pub const TabTransfer = struct {
    source_tab: u64,
    target_pane: u64,
    direction: TransferDirection,
};

pub const ActionPayload = struct {
    snapshot_index: ?usize = null,
    /// Canonical binding-action text accepted by the existing dispatcher.
    action: []const u8 = "",
    /// Built-in shell transaction that has no Ghostty binding-action syntax.
    tab_transfer: ?TabTransfer = null,
};

/// Closed, reviewed destinations. Runtime integration must map these values to
/// native UI or known documentation URLs; no catalog string is executable.
pub const HelpTarget = enum {
    keyboard_shortcuts,
    settings,
    configuration,
    troubleshooting,
    diagnostics,
    accessibility,
};

pub const ThemeEntry = struct {
    /// Installed theme name from a caller-owned snapshot.
    name: []const u8,
    description: []const u8 = "Theme",
    enabled: bool = true,
    disabled_reason: ?[]const u8 = null,
};

pub const Payload = union(Kind) {
    action: ActionPayload,
    tab: u64,
    pane: u64,
    profile: []const u8,
    setting: []const u8,
    theme: []const u8,
    help: HelpTarget,
    /// Always resolved against a current action snapshot before dispatch.
    /// This is action MRU, never arbitrary shell command history.
    recent_command: ActionPayload,
};

pub const Descriptor = struct {
    item: Item,
    payload: Payload,
};

pub const Error = error{
    StorageLengthMismatch,
    StorageTooSmall,
    SnapshotLengthMismatch,
    DuplicateStableId,
    PayloadKindMismatch,
    DisabledReasonMissing,
    InvalidShortcut,
};

pub const reviewed_help = [_]struct {
    target: HelpTarget,
    title: []const u8,
    description: []const u8,
    keywords: []const u8,
}{
    .{ .target = .keyboard_shortcuts, .title = "Keyboard shortcuts", .description = "Review keyboard navigation and bindings", .keywords = "keys keybindings commands" },
    .{ .target = .settings, .title = "Open settings", .description = "Configure winghostty", .keywords = "preferences options" },
    .{ .target = .configuration, .title = "Configuration guide", .description = "Learn the winghostty configuration format", .keywords = "config file syntax" },
    .{ .target = .troubleshooting, .title = "Troubleshooting", .description = "Resolve common terminal problems", .keywords = "help repair support" },
    .{ .target = .diagnostics, .title = "Export diagnostics", .description = "Create a local redacted diagnostic bundle", .keywords = "logs debug bundle" },
    .{ .target = .accessibility, .title = "Accessibility", .description = "Keyboard, screen reader, contrast, and motion guidance", .keywords = "narrator nvda contrast reduced motion" },
};

/// Caller-owned, allocation-free palette catalog. `items()` is directly
/// consumable by the universal ranker; payloads remain parallel and are
/// checked against ranked stable IDs before dispatch.
pub const Catalog = struct {
    item_storage: []Item,
    payload_storage: []Payload,
    count: usize = 0,

    pub fn init(item_storage: []Item, payload_storage: []Payload) Error!Catalog {
        if (item_storage.len != payload_storage.len) return error.StorageLengthMismatch;
        return .{
            .item_storage = item_storage,
            .payload_storage = payload_storage,
        };
    }

    pub fn reset(self: *Catalog) void {
        self.count = 0;
    }

    pub fn capacity(self: *const Catalog) usize {
        return self.item_storage.len;
    }

    pub fn items(self: *const Catalog) []const Item {
        return self.item_storage[0..self.count];
    }

    pub fn append(self: *Catalog, descriptor: Descriptor) Error!void {
        try validateDescriptor(descriptor);
        if (self.count == self.item_storage.len) return error.StorageTooSmall;
        if (self.containsId(descriptor.item.id)) return error.DuplicateStableId;
        self.item_storage[self.count] = descriptor.item;
        self.payload_storage[self.count] = descriptor.payload;
        self.count += 1;
    }

    /// Append an existing `win32_palette.Snapshot` without coupling this module
    /// to the legacy `zf` matcher. The generic contract is the snapshot's
    /// `commands` and `cvals` fields; strings remain borrowed.
    pub fn appendActionSnapshot(self: *Catalog, snapshot: anytype) Error!void {
        if (snapshot.commands.len != snapshot.cvals.len) return error.SnapshotLengthMismatch;
        if (snapshot.commands.len > self.item_storage.len - self.count) return error.StorageTooSmall;

        // Preflight the complete batch so errors never leave a partial catalog.
        for (snapshot.commands, snapshot.cvals, 0..) |command, cval, index| {
            const action = std.mem.span(cval.action);
            const id = actionStableId(command.title, action);
            if (self.containsId(id)) return error.DuplicateStableId;
            var previous: usize = 0;
            while (previous < index) : (previous += 1) {
                const previous_action = std.mem.span(snapshot.cvals[previous].action);
                if (actionStableId(snapshot.commands[previous].title, previous_action).eql(id)) {
                    return error.DuplicateStableId;
                }
            }
        }

        for (snapshot.commands, snapshot.cvals, 0..) |command, cval, index| {
            const action = std.mem.span(cval.action);
            const descriptor: Descriptor = .{
                .item = .{
                    .id = actionStableId(command.title, action),
                    .title = command.title,
                    .subtitle = command.description,
                    .keywords = action,
                    .destructive = actionIsDestructive(action),
                },
                .payload = .{ .action = .{
                    .snapshot_index = index,
                    .action = action,
                } },
            };
            // Capacity, uniqueness, and descriptor shape were preflighted.
            self.item_storage[self.count] = descriptor.item;
            self.payload_storage[self.count] = descriptor.payload;
            self.count += 1;
        }
    }

    /// Append a caller-supplied snapshot of themes that are actually installed
    /// and selectable. All strings are borrowed until reset; callers must keep
    /// the snapshot backing storage alive through rank, paint, UIA, and invoke.
    pub fn appendThemes(self: *Catalog, themes: []const ThemeEntry) Error!void {
        if (themes.len > self.item_storage.len - self.count) return error.StorageTooSmall;
        for (themes, 0..) |theme, index| {
            const id = stableStringId(.theme, theme.name);
            if (self.containsId(id)) return error.DuplicateStableId;
            if (!theme.enabled and (theme.disabled_reason == null or theme.disabled_reason.?.len == 0)) {
                return error.DisabledReasonMissing;
            }
            for (themes[0..index]) |previous| {
                if (stableStringId(.theme, previous.name).eql(id)) return error.DuplicateStableId;
            }
        }
        for (themes) |theme| {
            self.item_storage[self.count] = .{
                .id = stableStringId(.theme, theme.name),
                .title = theme.name,
                .subtitle = theme.description,
                .keywords = "theme appearance colors",
                .enabled = theme.enabled,
                .disabled_reason = theme.disabled_reason,
            };
            self.payload_storage[self.count] = .{ .theme = theme.name };
            self.count += 1;
        }
    }

    /// Append the built-in reviewed help surface. Titles and targets have
    /// static lifetime and cannot encode arbitrary URLs or commands.
    pub fn appendReviewedHelp(self: *Catalog) Error!void {
        if (reviewed_help.len > self.item_storage.len - self.count) return error.StorageTooSmall;
        for (reviewed_help) |entry| {
            if (self.containsId(stableStringId(.help, @tagName(entry.target)))) {
                return error.DuplicateStableId;
            }
        }
        for (reviewed_help) |entry| {
            self.item_storage[self.count] = .{
                .id = stableStringId(.help, @tagName(entry.target)),
                .title = entry.title,
                .subtitle = entry.description,
                .keywords = entry.keywords,
            };
            self.payload_storage[self.count] = .{ .help = entry.target };
            self.count += 1;
        }
    }

    /// Append action MRU entries only when each string exactly matches the
    /// current reviewed palette action snapshot. Unknown/stale history is
    /// ignored; it is never interpreted as a shell command.
    pub fn appendRecentActionMru(
        self: *Catalog,
        snapshot: anytype,
        newest_first: []const []const u8,
    ) Error!void {
        if (snapshot.commands.len != snapshot.cvals.len) return error.SnapshotLengthMismatch;
        var accepted: usize = 0;
        for (newest_first, 0..) |action, mru_index| {
            const snapshot_index = findAction(snapshot, action) orelse continue;
            _ = snapshot_index;
            if (seenRecentBefore(newest_first[0..mru_index], action)) continue;
            const id = stableStringId(.recent_command, action);
            if (self.containsId(id)) return error.DuplicateStableId;
            accepted += 1;
        }
        if (accepted > self.item_storage.len - self.count) return error.StorageTooSmall;

        for (newest_first, 0..) |action, mru_index| {
            const snapshot_index = findAction(snapshot, action) orelse continue;
            if (seenRecentBefore(newest_first[0..mru_index], action)) continue;
            self.item_storage[self.count] = .{
                .id = stableStringId(.recent_command, action),
                .title = snapshot.commands[snapshot_index].title,
                .subtitle = "Recent action",
                .keywords = action,
                .recency = .{
                    .mru_rank = @intCast(@min(mru_index, std.math.maxInt(u16))),
                },
            };
            self.payload_storage[self.count] = .{ .recent_command = .{
                .snapshot_index = snapshot_index,
                .action = std.mem.span(snapshot.cvals[snapshot_index].action),
            } };
            self.count += 1;
        }
    }

    pub fn rank(
        self: *const Catalog,
        query: []const u8,
        options: RankOptions,
        output: []Ranked,
    ) []Ranked {
        return universal.rank(self.items(), query, options, output);
    }

    /// Resolve a result from the current catalog. The ID comparison rejects a
    /// ranked result retained across reset/rebuild even when its index is valid.
    pub fn payloadFor(self: *const Catalog, result: Ranked) ?Payload {
        if (result.index >= self.count) return null;
        if (!self.item_storage[result.index].id.eql(result.id)) return null;
        return self.payload_storage[result.index];
    }

    pub fn descriptorFor(self: *const Catalog, result: Ranked) ?Descriptor {
        const payload = self.payloadFor(result) orelse return null;
        return .{
            .item = self.item_storage[result.index],
            .payload = payload,
        };
    }

    pub fn payloadById(self: *const Catalog, id: universal.StableId) ?Payload {
        for (self.items(), 0..) |item, index| {
            if (item.id.eql(id)) return self.payload_storage[index];
        }
        return null;
    }

    fn containsId(self: *const Catalog, id: universal.StableId) bool {
        return self.payloadById(id) != null;
    }
};

pub fn actionStableId(title: []const u8, action: []const u8) universal.StableId {
    const title_hash = std.hash.Wyhash.hash(0x7769_6e67_686f_7374, title);
    return .{
        .kind = .action,
        .value = std.hash.Wyhash.hash(title_hash, action),
    };
}

pub fn stableStringId(kind: Kind, key: []const u8) universal.StableId {
    return .{
        .kind = kind,
        .value = std.hash.Wyhash.hash(
            @as(u64, 0x7061_6c65_7474_6500) + @intFromEnum(kind),
            key,
        ),
    };
}

pub fn actionIsDestructive(action: []const u8) bool {
    const destructive = [_][]const u8{
        "close_window",
        "close_tab",
        "close_surface",
        "quit",
        "reset",
        "clear_screen",
    };
    for (destructive) |prefix| {
        if (std.mem.startsWith(u8, action, prefix) and
            (action.len == prefix.len or action[prefix.len] == ':')) return true;
    }
    return false;
}

fn validateDescriptor(descriptor: Descriptor) Error!void {
    if (std.meta.activeTag(descriptor.payload) != descriptor.item.id.kind) {
        return error.PayloadKindMismatch;
    }
    if (!descriptor.item.enabled) {
        const reason = descriptor.item.disabled_reason orelse return error.DisabledReasonMissing;
        if (reason.len == 0) return error.DisabledReasonMissing;
    }
    if (descriptor.item.shortcut) |shortcut| {
        if (shortcut.chord_count == 0 or shortcut.label.len == 0) return error.InvalidShortcut;
    }
}

fn findAction(snapshot: anytype, action: []const u8) ?usize {
    for (snapshot.cvals, 0..) |cval, index| {
        if (std.mem.eql(u8, std.mem.span(cval.action), action)) return index;
    }
    return null;
}

fn seenRecentBefore(previous: []const []const u8, action: []const u8) bool {
    for (previous) |value| {
        if (std.mem.eql(u8, value, action)) return true;
    }
    return false;
}

const FakeCommand = struct {
    title: []const u8,
    description: []const u8 = "",
};

const FakeCval = struct {
    action: [*:0]const u8,
};

test "action snapshot and blended targets share one ranked catalog" {
    const commands = [_]FakeCommand{
        .{ .title = "New Tab", .description = "Open a terminal tab" },
        .{ .title = "Close Tab", .description = "Close the active tab" },
    };
    const cvals = [_]FakeCval{
        .{ .action = "new_tab" },
        .{ .action = "close_tab" },
    };
    const snapshot = .{ .commands = &commands, .cvals = &cvals };
    var item_storage: [8]Item = undefined;
    var payload_storage: [8]Payload = undefined;
    var catalog = try Catalog.init(&item_storage, &payload_storage);
    try catalog.appendActionSnapshot(snapshot);
    try catalog.append(.{
        .item = .{
            .id = .{ .kind = .tab, .value = 42 },
            .title = "Build server",
            .subtitle = "PowerShell",
            .recency = .{ .mru_rank = 0 },
        },
        .payload = .{ .tab = 42 },
    });
    try catalog.append(.{
        .item = .{
            .id = stableStringId(.theme, "Winghostty Dark"),
            .title = "Winghostty Dark",
            .keywords = "appearance",
        },
        .payload = .{ .theme = "Winghostty Dark" },
    });

    var ranked_storage: [8]Ranked = undefined;
    const action_results = catalog.rank("new tab", .{}, &ranked_storage);
    try std.testing.expect(action_results.len > 0);
    const action = catalog.payloadFor(action_results[0]).?.action;
    try std.testing.expectEqualStrings("new_tab", action.action);
    try std.testing.expectEqual(@as(?usize, 0), action.snapshot_index);

    const tab_results = catalog.rank("@build", .{}, &ranked_storage);
    try std.testing.expectEqual(@as(usize, 1), tab_results.len);
    try std.testing.expectEqual(@as(u64, 42), catalog.payloadFor(tab_results[0]).?.tab);

    const theme_results = catalog.rank("%appearance", .{}, &ranked_storage);
    try std.testing.expectEqualStrings("Winghostty Dark", catalog.payloadFor(theme_results[0]).?.theme);
}

test "snapshot append is transactional on duplicate IDs" {
    const commands = [_]FakeCommand{
        .{ .title = "New Tab" },
        .{ .title = "New Tab" },
    };
    const cvals = [_]FakeCval{
        .{ .action = "new_tab" },
        .{ .action = "new_tab" },
    };
    var item_storage: [4]Item = undefined;
    var payload_storage: [4]Payload = undefined;
    var catalog = try Catalog.init(&item_storage, &payload_storage);
    try std.testing.expectError(
        error.DuplicateStableId,
        catalog.appendActionSnapshot(.{ .commands = &commands, .cvals = &cvals }),
    );
    try std.testing.expectEqual(@as(usize, 0), catalog.items().len);
}

test "descriptor validation and stale ranked results fail closed" {
    var item_storage: [2]Item = undefined;
    var payload_storage: [2]Payload = undefined;
    var catalog = try Catalog.init(&item_storage, &payload_storage);
    try std.testing.expectError(error.PayloadKindMismatch, catalog.append(.{
        .item = .{ .id = .{ .kind = .pane, .value = 1 }, .title = "Pane" },
        .payload = .{ .tab = 1 },
    }));
    try std.testing.expectError(error.DisabledReasonMissing, catalog.append(.{
        .item = .{
            .id = .{ .kind = .setting, .value = 2 },
            .title = "Managed setting",
            .enabled = false,
        },
        .payload = .{ .setting = "managed-setting" },
    }));

    try catalog.append(.{
        .item = .{ .id = .{ .kind = .pane, .value = 1 }, .title = "Pane" },
        .payload = .{ .pane = 1 },
    });
    var ranked_storage: [1]Ranked = undefined;
    const stale = catalog.rank("pane", .{}, &ranked_storage)[0];
    catalog.reset();
    try catalog.append(.{
        .item = .{ .id = .{ .kind = .pane, .value = 2 }, .title = "Pane" },
        .payload = .{ .pane = 2 },
    });
    try std.testing.expectEqual(@as(?Payload, null), catalog.payloadFor(stale));
}

test "installed theme snapshot and reviewed help produce typed payloads" {
    const themes = [_]ThemeEntry{
        .{ .name = "Winghostty Dark", .description = "Dark built-in theme" },
        .{ .name = "Managed Light", .enabled = false, .disabled_reason = "Managed by policy" },
    };
    var item_storage: [16]Item = undefined;
    var payload_storage: [16]Payload = undefined;
    var catalog = try Catalog.init(&item_storage, &payload_storage);
    try catalog.appendThemes(&themes);
    try catalog.appendReviewedHelp();

    var ranked_storage: [16]Ranked = undefined;
    const theme_results = catalog.rank("%dark", .{}, &ranked_storage);
    try std.testing.expectEqualStrings("Winghostty Dark", catalog.payloadFor(theme_results[0]).?.theme);
    const help_results = catalog.rank("?keyboard", .{}, &ranked_storage);
    try std.testing.expectEqual(HelpTarget.keyboard_shortcuts, catalog.payloadFor(help_results[0]).?.help);
}

test "recent history accepts only exact current palette actions" {
    const commands = [_]FakeCommand{
        .{ .title = "New Tab" },
        .{ .title = "Close Tab" },
    };
    const cvals = [_]FakeCval{
        .{ .action = "new_tab" },
        .{ .action = "close_tab" },
    };
    const snapshot = .{ .commands = &commands, .cvals = &cvals };
    const mru = [_][]const u8{ "new_tab", "echo arbitrary", "new_tab", "close_tab" };
    var item_storage: [8]Item = undefined;
    var payload_storage: [8]Payload = undefined;
    var catalog = try Catalog.init(&item_storage, &payload_storage);
    try catalog.appendRecentActionMru(snapshot, &mru);
    try std.testing.expectEqual(@as(usize, 2), catalog.items().len);

    var ranked_storage: [8]Ranked = undefined;
    const results = catalog.rank("!new", .{}, &ranked_storage);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    const payload = catalog.payloadFor(results[0]).?.recent_command;
    try std.testing.expectEqual(@as(usize, 0), payload.snapshot_index);
    try std.testing.expectEqualStrings("new_tab", payload.action);
}

test "provider batches fail before mutation when capacity is exhausted" {
    const commands = [_]FakeCommand{
        .{ .title = "New Tab" },
        .{ .title = "Close Tab" },
    };
    const cvals = [_]FakeCval{
        .{ .action = "new_tab" },
        .{ .action = "close_tab" },
    };
    const snapshot = .{ .commands = &commands, .cvals = &cvals };
    var item_storage: [1]Item = undefined;
    var payload_storage: [1]Payload = undefined;
    var catalog = try Catalog.init(&item_storage, &payload_storage);

    try std.testing.expectError(error.StorageTooSmall, catalog.appendThemes(&.{
        .{ .name = "Dark" },
        .{ .name = "Light" },
    }));
    try std.testing.expectEqual(@as(usize, 0), catalog.items().len);
    try std.testing.expectError(error.StorageTooSmall, catalog.appendReviewedHelp());
    try std.testing.expectEqual(@as(usize, 0), catalog.items().len);
    try std.testing.expectError(
        error.StorageTooSmall,
        catalog.appendRecentActionMru(snapshot, &.{ "new_tab", "close_tab" }),
    );
    try std.testing.expectEqual(@as(usize, 0), catalog.items().len);
}
