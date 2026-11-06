const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const windows_shell = @import("../../config/windows_shell.zig");
const input = @import("../../input.zig");

const win32_theme = @import("../win32_theme.zig");
const win32_palette = @import("../win32_palette.zig");
const win32_taskbar_progress = @import("../win32_taskbar_progress.zig");
const win32_types = @import("../win32_types.zig");
const c = @import("consts.zig");
const docked_search = @import("docked_search.zig");
const overlay_view = @import("overlay_view.zig");
const paint_text = @import("text.zig");
const profile_pick = @import("profile_pick.zig");
const tab_label = @import("tab_label.zig");

const HostOverlayMode = win32_theme.HostOverlayMode;
const OpenTarget = profile_pick.OpenTarget;
const rgb = win32_theme.rgb;
const PaletteStableId = @TypeOf((@as(win32_palette.catalog.Item, undefined)).id);
const palette_max_tokens = win32_palette.max_tokens;
const tokenizePaletteQuery = win32_palette.tokenizeQuery;
const rankPaletteEntry = win32_palette.rankEntry;
const RECT = win32_types.RECT;
const ownedStringEquals = paint_text.ownedStringEquals;
const WPARAM = usize;

pub const PaletteCompletion = struct {
    text: []const u8,
    id: PaletteStableId,
};

pub const command_palette_unknown_action = "Unknown Noctty action. Example: new_tab or toggle_fullscreen";

pub const host_banner_inspector_inactive = "Inspector hidden. Terminal view is active.";

/// A link or path the opener refused: missing, a program or script, or on the
/// network.
pub const open_refused_banner = "Not opened: only known link types and existing documents or folders can be opened.";
pub const quick_select_no_targets_banner = "No quick-select targets in view.";
pub const quick_select_too_many_banner = "Too many quick-select targets in view to label. Clear or narrow the screen.";

const TabButtonKeyAction = enum {
    activate,
    previous,
    next,
    first,
    last,
    move_previous,
    move_next,
    move_first,
    move_last,
    rename,
    close,
    /// Apps and Shift+F10: the menu a right click on the tab opens.
    context_menu,
    /// Tab and Shift+Tab walk the strip's stops without activating a tab.
    focus_next,
    focus_previous,
};

pub const KeyMods = docked_search.Mods;

/// What Enter and Tab do on a tab-strip action button ([+], [v]) or a docked
/// search button. Space is not here: the BUTTON class clicks on its key-up.
pub const ChromeButtonKeyAction = enum {
    click,
    focus_next,
    focus_previous,
};

pub const FocusStep = enum { next, previous };

pub const LaunchTargetButtonKeyAction = enum {
    previous,
    next,
    first,
    last,
};

pub fn tabButtonKeyAction(vk: WPARAM, mods: KeyMods) ?TabButtonKeyAction {
    // Alt chords belong to the window's menu, not to the tab.
    if (mods.alt) return null;
    return switch (vk) {
        // Enter and Space activate the focused tab, matching every other
        // Win32 tab control. Ctrl is ignored here: Ctrl+Enter and
        // Ctrl+Space have no tab meaning and must not silently activate.
        c.VK_RETURN, c.VK_SPACE => if (mods.ctrl) null else .activate,
        c.VK_LEFT => if (mods.ctrl) .move_previous else .previous,
        c.VK_RIGHT => if (mods.ctrl) .move_next else .next,
        c.VK_HOME => if (mods.ctrl) .move_first else .first,
        c.VK_END => if (mods.ctrl) .move_last else .last,
        c.VK_F2 => .rename,
        c.VK_DELETE => .close,
        // The overview is a palette action; the menu key opens the tab's
        // context menu, as it does on every other Windows control.
        // Shift+F10 is the same request. F10 is a system key, so it arrives
        // as WM_SYSKEYDOWN, and plain F10 stays with the window.
        c.VK_APPS, c.VK_F10 => if (tabContextMenuKey(vk, mods)) .context_menu else null,
        c.VK_TAB => switch (tabFocusStep(vk, mods) orelse return null) {
            .next => .focus_next,
            .previous => .focus_previous,
        },
        else => null,
    };
}

/// Tab and Shift+Tab, which move through a chrome region's stops. Ctrl+Tab
/// and Alt+Tab are other chords.
pub fn tabFocusStep(vk: WPARAM, mods: KeyMods) ?FocusStep {
    if (vk != c.VK_TAB or mods.ctrl or mods.alt) return null;
    return if (mods.shift) .previous else .next;
}

pub fn chromeButtonKeyAction(vk: WPARAM, mods: KeyMods) ?ChromeButtonKeyAction {
    if (mods.ctrl or mods.alt) return null;
    if (tabFocusStep(vk, mods)) |step| return switch (step) {
        .next => .focus_next,
        .previous => .focus_previous,
    };
    return if (vk == c.VK_RETURN) .click else null;
}

/// The key-ups that must not reach `DefWindowProc` on a tab button: it turns
/// the menu key's release (and Shift+F10's) into a second WM_CONTEXTMENU after
/// the key-down already opened the menu.
pub fn tabButtonSwallowsKeyUp(vk: WPARAM, mods: KeyMods) bool {
    return tabContextMenuKey(vk, mods);
}

/// The menu key, or Shift+F10 without Ctrl or Alt.
fn tabContextMenuKey(vk: WPARAM, mods: KeyMods) bool {
    return vk == c.VK_APPS or (vk == c.VK_F10 and mods.shift and !mods.ctrl and !mods.alt);
}

/// The first stop after `current` that `available` accepts, in the direction
/// of `reverse` and wrapping, or null when no other stop is available. A stop
/// is any focusable thing in one region; the caller owns what they are.
pub fn nextFocusStop(
    count: usize,
    current: usize,
    reverse: bool,
    ctx: anytype,
    comptime available: fn (@TypeOf(ctx), usize) bool,
) ?usize {
    if (count < 2 or current >= count) return null;
    var step: usize = 1;
    while (step < count) : (step += 1) {
        const candidate = if (reverse) (current + count - step) % count else (current + step) % count;
        if (available(ctx, candidate)) return candidate;
    }
    return null;
}

/// After a tab's context menu closes, keyboard focus goes back to the strip
/// when the menu came from the keyboard, unless a command opened an overlay
/// (rename, a close that asks first) that owns the keyboard now.
pub fn tabContextMenuRestoresStripFocus(from_keyboard: bool, overlay_open: bool) bool {
    return from_keyboard and !overlay_open;
}

/// What the tab strip's two action buttons are called to UIA and in their
/// hover tooltips, so the two always agree.
pub const TabStripAction = enum { new_tab, more_tabs };

pub fn tabStripActionName(action: TabStripAction) []const u8 {
    return switch (action) {
        .new_tab => "New tab",
        .more_tabs => "More tabs",
    };
}

pub fn moveTabAmountToEdge(total: usize, current: usize, toward_start: bool) isize {
    if (total <= 1 or current >= total) return 0;
    if (toward_start) return -@as(isize, @intCast(current));
    return @as(isize, @intCast((total - 1) - current));
}

/// The banner for the last tab of a window being closed. It names the key bound
/// to `undo` (the first one found, in the way a hint is written: `Ctrl+Shift+Z`)
/// and falls back when `undo` is unbound or customization makes dispatch ambiguous.
/// With `undo-timeout = 0` nothing can be restored, so it offers nothing.
pub fn tabClosedMessage(set: *const input.Binding.Set, options: struct { has_modifier_remaps: bool = false, us_layout: bool = false, undo_available: bool = true }, buf: []u8) []const u8 {
    if (!options.undo_available) return "Tab closed.";
    const fallback = "Tab closed. Use undo to restore it.";
    if (options.has_modifier_remaps) return fallback;
    var it = set.bindings.iterator();
    const trigger = while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .leaf => |leaf| if (leaf.action == .undo) break entry.key_ptr.*,
            else => {},
        }
    } else return fallback;

    switch (trigger.key) {
        .unicode => |cp| {
            // Only the exact US layout establishes these physical/text
            // identities. Other layouts (including US-International and
            // Turkish Q) can produce this letter from a different key or
            // different shifted text, so use generic wording there.
            if (!options.us_layout) return fallback;
            if (cp < 'a' or cp > 'z') return fallback;
            var overrides = set.bindings.iterator();
            while (overrides.next()) |entry| {
                if (!entry.key_ptr.mods.binding().equal(trigger.mods.binding())) continue;
                switch (entry.key_ptr.key) {
                    .physical => |key| if (key == input.Key.fromASCII(@intCast(cp)).?) return fallback,
                    .unicode => |other| if (other == std.ascii.toUpper(@intCast(cp)) or
                        (trigger.mods.ctrl and other == (cp & 0x1f))) return fallback,
                    .catch_all => {},
                }
            }
        },
        .physical => |key| if (key.printable()) return fallback,
        .catch_all => return fallback,
    }

    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll("Tab closed. Press ") catch return fallback;
    const key_start = writer.end;
    writer.print("{f}", .{trigger}) catch return fallback;
    // `Trigger.format` writes the config spelling, `ctrl+shift+z`.
    for (buf[key_start..writer.end], key_start..) |*byte, i| {
        if (i == key_start or buf[i - 1] == '+') byte.* = std.ascii.toUpper(byte.*);
    }
    writer.writeAll(" to undo.") catch return fallback;
    return writer.buffered();
}

pub fn inspectorPanelVisibleForState(overlay_mode: HostOverlayMode, active_tab_has_inspector: bool) bool {
    return overlay_mode == .none and active_tab_has_inspector;
}

pub fn inspectorBannerStateChanged(
    overlay_mode: HostOverlayMode,
    banner_kind: overlay_view.BannerKind,
    banner_text: ?[:0]const u8,
    visible: bool,
) bool {
    if (overlay_mode != .none) return false;
    if (visible) return banner_kind != .none or banner_text != null;
    return banner_kind != .info or !ownedStringEquals(banner_text, host_banner_inspector_inactive);
}

pub fn bindingActionsToggleCommandPalette(actions: []const input.Binding.Action) bool {
    for (actions) |action| switch (action) {
        .toggle_command_palette => return true,
        else => {},
    };
    return false;
}

/// Apply `key-remap` to a key event the same way `Surface.keyCallback` does.
/// Two Win32 paths hand events to the core without going through a surface:
/// the empty-host app-input path and the command-palette toggle lookup. Both
/// must see remapped modifiers or a remapped chord silently misses there.
pub fn remapWin32KeyEvent(
    event_orig: input.KeyEvent,
    remaps: *const input.KeyRemapSet,
) input.KeyEvent {
    var event = event_orig;
    event.mods = remaps.apply(event_orig.mods);
    if (event_orig.binding_mods) |binding_mods| {
        event.binding_mods = remaps.apply(binding_mods);
    }
    return event;
}

pub fn keyEventTogglesCommandPalette(
    event_orig: input.KeyEvent,
    keybinds: *const input.Binding.Set,
    remaps: *const input.KeyRemapSet,
) bool {
    const event = remapWin32KeyEvent(event_orig, remaps);
    const entry = keybinds.getEvent(event) orelse return false;
    const actions: []const input.Binding.Action = switch (entry.value_ptr.*) {
        .leader => return false,
        inline .leaf, .leaf_chained => |leaf| leaf.generic().actionsSlice(),
    };
    return bindingActionsToggleCommandPalette(actions);
}

pub fn profileShortcutIndexFromKey(vk: WPARAM) ?usize {
    if (vk >= @as(WPARAM, '1') and vk <= @as(WPARAM, '9')) {
        return @as(usize, @intCast(vk - @as(WPARAM, '1')));
    }
    if (vk >= 0x61 and vk <= 0x69) {
        return @as(usize, @intCast(vk - 0x61));
    }
    return null;
}

pub fn quickSlotShortcutProfileIndex(
    profiles_len: usize,
    selected_index: ?usize,
    vk: WPARAM,
    alt_pressed: bool,
) ?usize {
    if (!alt_pressed) return null;
    const slot_ordinal = profileShortcutIndexFromKey(vk) orelse return null;
    return profile_pick.quickSlot(profiles_len, selected_index, slot_ordinal);
}

pub fn quickSlotPinOrdinalFromKey(vk: WPARAM, alt_pressed: bool, shift_pressed: bool) ?usize {
    if (!alt_pressed or !shift_pressed) return null;
    const slot_ordinal = profileShortcutIndexFromKey(vk) orelse return null;
    if (slot_ordinal >= profile_pick.quick_slots) return null;
    return slot_ordinal;
}

pub fn clearQuickSlotPinsRequested(vk: WPARAM, alt_pressed: bool, shift_pressed: bool) bool {
    if (!alt_pressed or !shift_pressed) return false;
    return vk == c.VK_0 or vk == c.VK_NUMPAD0;
}

pub fn paletteCompletionText(descriptor: win32_palette.catalog.Descriptor) []const u8 {
    return switch (descriptor.payload) {
        .action => |payload| payload.action,
        .recent_command => |payload| payload.action,
        .profile => |key| key,
        .theme => |name| name,
        .layout => |name| name,
        // A setting's payload is its internal tag; the title is what the row
        // says and what the query has to match.
        .tab, .pane, .help, .setting => descriptor.item.title,
    };
}

pub fn buildInspectorPanelTitleText(
    alloc: Allocator,
    host: tab_label.TabStatus,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  {d} panes  •  zoomed",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  {d} panes",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (zoomed) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector  •  tab {d}/{d}  •  zoomed",
            .{ host.index + 1, host.total },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "Inspector  •  tab {d}/{d}",
        .{ host.index + 1, host.total },
    );
}

pub fn buildInspectorPanelHintText(
    alloc: Allocator,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed) {
        return try alloc.dupe(
            u8,
            "Core inspector is live for the zoomed pane. Toggle Inspect to return to terminal-only view.",
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Core inspector is live across {d} panes in this tab. Toggle Inspect to return to terminal-only view.",
            .{pane_count},
        );
    }
    return try alloc.dupe(u8, "Core inspector is live for this tab. Toggle Inspect to return to terminal-only view.");
}

/// A menu item's text: the label, then the shortcut after a tab. In a menu
/// `&` marks the next character as the mnemonic and a tab starts the
/// shortcut column, and a `profile-name` may contain either, so the label
/// doubles `&` and turns a tab into a space.
pub fn buildDropdownProfileLabel(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    index: usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (profile.label) |byte| switch (byte) {
        '&' => try out.appendSlice(alloc, "&&"),
        '\t' => try out.append(alloc, ' '),
        else => try out.append(alloc, byte),
    };
    if (index < 9) try out.print(alloc, "\tCtrl+Shift+{d}", .{index + 1});
    return try out.toOwnedSlice(alloc);
}

test "win32 a profile's menu item keeps an ampersand and a tab in its label" {
    const alloc = std.testing.allocator;
    const profile: windows_shell.Profile = .{
        .kind = .user,
        .key = "user:qa",
        .label = "Q&A\tshell",
        .command = .{ .shell = "cmd.exe" },
    };
    const first = try buildDropdownProfileLabel(alloc, &profile, 0);
    defer alloc.free(first);
    try std.testing.expectEqualStrings("Q&&A shell\tCtrl+Shift+1", first);
    const tenth = try buildDropdownProfileLabel(alloc, &profile, 9);
    defer alloc.free(tenth);
    try std.testing.expectEqualStrings("Q&&A shell", tenth);
}

fn targetButtonLabelRightInset(target: ?OpenTarget) i32 {
    return if (target != null) 12 else 0;
}

pub fn buttonLabelRightInset(pinned_slot_ordinal: ?usize, target: ?OpenTarget) i32 {
    const slot_inset: i32 = if (pinnedSlotBadgeDigit(pinned_slot_ordinal) != null) 16 else 0;
    return @max(targetButtonLabelRightInset(target), slot_inset);
}

pub fn pinnedSlotBadgeDigit(pinned_slot_ordinal: ?usize) ?u8 {
    const ordinal = pinned_slot_ordinal orelse return null;
    if (ordinal >= 9) return null;
    return @as(u8, @intCast('1' + ordinal));
}

pub fn profileOpenTargetMarkerColor(target: OpenTarget) u32 {
    return switch (target) {
        .tab => rgb(132, 172, 238),
        .window => rgb(236, 182, 118),
        .split => rgb(126, 204, 148),
    };
}

pub fn profileOpenTargetBadgeGlyph(target: OpenTarget) u8 {
    return switch (target) {
        .tab => 'T',
        .window => 'W',
        .split => 'S',
    };
}

pub fn nextTabOverviewSelection(current: usize, total: usize, reverse: bool) usize {
    if (total == 0) return 0;
    const clamped = std.math.clamp(current, @as(usize, 1), total);
    if (reverse) {
        return if (clamped <= 1) total else clamped - 1;
    }
    return if (clamped >= total) 1 else clamped + 1;
}

pub fn tabDirectionFromWheelDelta(delta: i16) apprt.action.GotoTab {
    return if (delta > 0) .previous else .next;
}

test "win32 profileShortcutIndexFromKey supports top row and numpad digits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), profileShortcutIndexFromKey('1'));
    try std.testing.expectEqual(@as(?usize, 4), profileShortcutIndexFromKey('5'));
    try std.testing.expectEqual(@as(?usize, 8), profileShortcutIndexFromKey('9'));
    try std.testing.expectEqual(@as(?usize, 0), profileShortcutIndexFromKey(0x61));
    try std.testing.expectEqual(@as(?usize, 8), profileShortcutIndexFromKey(0x69));
    try std.testing.expectEqual(@as(?usize, null), profileShortcutIndexFromKey('0'));
    try std.testing.expectEqual(@as(?usize, null), profileShortcutIndexFromKey('A'));
}

test "win32 quickSlotShortcutProfileIndex maps visible launcher slots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 1), quickSlotShortcutProfileIndex(5, 0, '1', true));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotShortcutProfileIndex(5, 0, '2', true));
    try std.testing.expectEqual(@as(?usize, 3), quickSlotShortcutProfileIndex(5, 0, '3', true));
    try std.testing.expectEqual(@as(?usize, 0), quickSlotShortcutProfileIndex(5, 3, '1', true));
    try std.testing.expectEqual(@as(?usize, 1), quickSlotShortcutProfileIndex(5, 3, '2', true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotShortcutProfileIndex(5, 0, '4', true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotShortcutProfileIndex(5, 0, '1', false));
}

test "win32 quickSlotPinOrdinalFromKey maps visible pin slots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), quickSlotPinOrdinalFromKey('1', true, true));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotPinOrdinalFromKey('3', true, true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotPinOrdinalFromKey('4', true, true));
    try std.testing.expectEqual(@as(?usize, null), quickSlotPinOrdinalFromKey('1', true, false));
    try std.testing.expectEqual(@as(?usize, null), quickSlotPinOrdinalFromKey('1', false, true));
}

test "win32 clearQuickSlotPinsRequested detects clear shortcut" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(clearQuickSlotPinsRequested(c.VK_0, true, true));
    try std.testing.expect(clearQuickSlotPinsRequested(c.VK_NUMPAD0, true, true));
    try std.testing.expect(!clearQuickSlotPinsRequested('1', true, true));
    try std.testing.expect(!clearQuickSlotPinsRequested(c.VK_0, true, false));
    try std.testing.expect(!clearQuickSlotPinsRequested(c.VK_0, false, true));
}

test "win32 taskbar mapping clamps percent to shell range" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const report: win32_taskbar_progress.ProgressReport = .{
        .state = .set,
        .progress = 255,
    };

    const mapped = win32_taskbar_progress.mapProgressReport(report);
    try std.testing.expectEqual(@as(u64, 100), mapped.value.?.completed);
    try std.testing.expectEqual(@as(u64, 100), mapped.value.?.total);
}

test "win32 targetButtonLabelRightInset reserves target badge space" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(i32, 0), targetButtonLabelRightInset(null));
    try std.testing.expectEqual(@as(i32, 12), targetButtonLabelRightInset(.tab));
    try std.testing.expectEqual(@as(i32, 12), targetButtonLabelRightInset(.window));
    try std.testing.expectEqual(@as(i32, 12), targetButtonLabelRightInset(.split));
}

test "win32 buttonLabelRightInset reserves slot and target badge space" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(i32, 0), buttonLabelRightInset(null, null));
    try std.testing.expectEqual(@as(i32, 12), buttonLabelRightInset(null, .tab));
    try std.testing.expectEqual(@as(i32, 16), buttonLabelRightInset(0, null));
    try std.testing.expectEqual(@as(i32, 16), buttonLabelRightInset(0, .split));
    try std.testing.expectEqual(@as(i32, 12), buttonLabelRightInset(9, .window));
}

test "win32 profileOpenTargetMarkerColor reflects launcher target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(rgb(132, 172, 238), profileOpenTargetMarkerColor(.tab));
    try std.testing.expectEqual(rgb(236, 182, 118), profileOpenTargetMarkerColor(.window));
    try std.testing.expectEqual(rgb(126, 204, 148), profileOpenTargetMarkerColor(.split));
}

test "win32 profileOpenTargetBadgeGlyph reflects launcher target" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(u8, 'T'), profileOpenTargetBadgeGlyph(.tab));
    try std.testing.expectEqual(@as(u8, 'W'), profileOpenTargetBadgeGlyph(.window));
    try std.testing.expectEqual(@as(u8, 'S'), profileOpenTargetBadgeGlyph(.split));
}

test "win32 pinnedSlotBadgeDigit reflects visible quick slot ordinals" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?u8, '1'), pinnedSlotBadgeDigit(0));
    try std.testing.expectEqual(@as(?u8, '3'), pinnedSlotBadgeDigit(2));
    try std.testing.expectEqual(@as(?u8, null), pinnedSlotBadgeDigit(null));
    try std.testing.expectEqual(@as(?u8, null), pinnedSlotBadgeDigit(9));
}

test "win32 nextTabOverviewSelection wraps and clamps" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 2), nextTabOverviewSelection(1, 4, false));
    try std.testing.expectEqual(@as(usize, 4), nextTabOverviewSelection(1, 4, true));
    try std.testing.expectEqual(@as(usize, 1), nextTabOverviewSelection(4, 4, false));
    try std.testing.expectEqual(@as(usize, 1), nextTabOverviewSelection(9, 4, false));
}

test "win32 tabDirectionFromWheelDelta maps wheel direction to tab navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(apprt.action.GotoTab.previous, tabDirectionFromWheelDelta(120));
    try std.testing.expectEqual(apprt.action.GotoTab.next, tabDirectionFromWheelDelta(-120));
}

test "win32 tabButtonKeyAction maps focused-tab keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const none: KeyMods = .{};
    const ctrl: KeyMods = .{ .ctrl = true };
    try std.testing.expectEqual(TabButtonKeyAction.activate, tabButtonKeyAction(c.VK_RETURN, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.activate, tabButtonKeyAction(c.VK_SPACE, none).?);
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_RETURN, ctrl));
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_SPACE, ctrl));
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_F6, none));
    try std.testing.expectEqual(TabButtonKeyAction.previous, tabButtonKeyAction(c.VK_LEFT, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_previous, tabButtonKeyAction(c.VK_LEFT, ctrl).?);
    try std.testing.expectEqual(TabButtonKeyAction.next, tabButtonKeyAction(c.VK_RIGHT, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_next, tabButtonKeyAction(c.VK_RIGHT, ctrl).?);
    try std.testing.expectEqual(TabButtonKeyAction.first, tabButtonKeyAction(c.VK_HOME, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_first, tabButtonKeyAction(c.VK_HOME, ctrl).?);
    try std.testing.expectEqual(TabButtonKeyAction.last, tabButtonKeyAction(c.VK_END, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_last, tabButtonKeyAction(c.VK_END, ctrl).?);
    try std.testing.expectEqual(TabButtonKeyAction.rename, tabButtonKeyAction(c.VK_F2, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.close, tabButtonKeyAction(c.VK_DELETE, none).?);
}

test "win32 tab button keys: the menu key and Shift+F10 open the context menu, Tab walks the strip" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const none: KeyMods = .{};
    const shift: KeyMods = .{ .shift = true };
    const ctrl: KeyMods = .{ .ctrl = true };
    const alt: KeyMods = .{ .alt = true };
    // Apps is the context menu now; the overview is only a palette action.
    try std.testing.expectEqual(TabButtonKeyAction.context_menu, tabButtonKeyAction(c.VK_APPS, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.context_menu, tabButtonKeyAction(c.VK_APPS, shift).?);
    try std.testing.expectEqual(TabButtonKeyAction.context_menu, tabButtonKeyAction(c.VK_F10, shift).?);
    // Plain F10 and Ctrl+Shift+F10 are not the request.
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_F10, none));
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_F10, .{ .shift = true, .ctrl = true }));
    try std.testing.expectEqual(TabButtonKeyAction.focus_next, tabButtonKeyAction(c.VK_TAB, none).?);
    try std.testing.expectEqual(TabButtonKeyAction.focus_previous, tabButtonKeyAction(c.VK_TAB, shift).?);
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_TAB, ctrl));
    // Alt keeps every tab key out: those chords are the window's.
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_TAB, alt));
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_LEFT, alt));
    // Left and Right still wrap through the tabs and Enter activates.
    try std.testing.expectEqual(TabButtonKeyAction.previous, tabButtonKeyAction(c.VK_LEFT, shift).?);
    try std.testing.expectEqual(TabButtonKeyAction.activate, tabButtonKeyAction(c.VK_RETURN, shift).?);

    // DefWindowProc turns the release of the menu key and of F10 into a
    // second WM_CONTEXTMENU once the key-down already opened the menu.
    try std.testing.expect(tabButtonSwallowsKeyUp(c.VK_APPS, none));
    try std.testing.expect(!tabButtonSwallowsKeyUp(c.VK_F10, none));
    try std.testing.expect(tabButtonSwallowsKeyUp(c.VK_F10, shift));
    try std.testing.expect(!tabButtonSwallowsKeyUp(c.VK_F10, .{ .shift = true, .ctrl = true }));
    try std.testing.expect(!tabButtonSwallowsKeyUp(c.VK_RETURN, none));
}

test "win32 chrome button keys: Enter clicks and Tab moves, Ctrl and Alt do neither" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const none: KeyMods = .{};
    try std.testing.expectEqual(ChromeButtonKeyAction.click, chromeButtonKeyAction(c.VK_RETURN, none).?);
    try std.testing.expectEqual(ChromeButtonKeyAction.focus_next, chromeButtonKeyAction(c.VK_TAB, none).?);
    try std.testing.expectEqual(ChromeButtonKeyAction.focus_previous, chromeButtonKeyAction(c.VK_TAB, .{ .shift = true }).?);
    try std.testing.expectEqual(@as(?ChromeButtonKeyAction, null), chromeButtonKeyAction(c.VK_RETURN, .{ .ctrl = true }));
    try std.testing.expectEqual(@as(?ChromeButtonKeyAction, null), chromeButtonKeyAction(c.VK_TAB, .{ .ctrl = true }));
    try std.testing.expectEqual(@as(?ChromeButtonKeyAction, null), chromeButtonKeyAction(c.VK_TAB, .{ .alt = true }));
    // Space is the BUTTON class's own (it clicks on the key-up).
    try std.testing.expectEqual(@as(?ChromeButtonKeyAction, null), chromeButtonKeyAction(c.VK_SPACE, none));
    try std.testing.expectEqual(@as(?FocusStep, FocusStep.previous), tabFocusStep(c.VK_TAB, .{ .shift = true }));
    try std.testing.expectEqual(@as(?FocusStep, null), tabFocusStep(c.VK_RETURN, none));
}

test "win32 focus stops step in order, wrap, and skip hidden stops" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const Stops = struct {
        visible: []const bool,
        fn available(self: @This(), stop: usize) bool {
            return self.visible[stop];
        }
    };
    const all: Stops = .{ .visible = &.{ true, true, true, true } };
    try std.testing.expectEqual(@as(?usize, 1), nextFocusStop(4, 0, false, all, Stops.available));
    try std.testing.expectEqual(@as(?usize, 0), nextFocusStop(4, 3, false, all, Stops.available));
    try std.testing.expectEqual(@as(?usize, 3), nextFocusStop(4, 0, true, all, Stops.available));
    try std.testing.expectEqual(@as(?usize, 1), nextFocusStop(4, 2, true, all, Stops.available));
    const gaps: Stops = .{ .visible = &.{ true, false, false, true } };
    try std.testing.expectEqual(@as(?usize, 3), nextFocusStop(4, 0, false, gaps, Stops.available));
    try std.testing.expectEqual(@as(?usize, 0), nextFocusStop(4, 3, false, gaps, Stops.available));
    try std.testing.expectEqual(@as(?usize, 0), nextFocusStop(4, 3, true, gaps, Stops.available));
    // Nothing else to land on: stay.
    const alone: Stops = .{ .visible = &.{ true, false, false, false } };
    try std.testing.expectEqual(@as(?usize, null), nextFocusStop(4, 0, false, alone, Stops.available));
    try std.testing.expectEqual(@as(?usize, null), nextFocusStop(1, 0, false, all, Stops.available));
    try std.testing.expectEqual(@as(?usize, null), nextFocusStop(4, 9, false, all, Stops.available));
}

test "win32 a tab context menu hands focus back to the strip only from the keyboard and without an overlay" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(tabContextMenuRestoresStripFocus(true, false));
    try std.testing.expect(!tabContextMenuRestoresStripFocus(true, true));
    try std.testing.expect(!tabContextMenuRestoresStripFocus(false, false));
}

test "win32 tab strip action names are the UIA names the tooltips show" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings("New tab", tabStripActionName(.new_tab));
    try std.testing.expectEqualStrings("More tabs", tabStripActionName(.more_tabs));
}

test "win32 moveTabAmountToEdge computes direct host reorder delta" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(isize, -2), moveTabAmountToEdge(4, 2, true));
    try std.testing.expectEqual(@as(isize, 1), moveTabAmountToEdge(4, 2, false));
    try std.testing.expectEqual(@as(isize, 0), moveTabAmountToEdge(4, 0, true));
    try std.testing.expectEqual(@as(isize, 0), moveTabAmountToEdge(4, 3, false));
}

test "win32 command palette toggle binding is recognized inside action chains" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const absent = [_]input.Binding.Action{ .{ .copy_to_clipboard = .mixed }, .paste_from_clipboard };
    const present = [_]input.Binding.Action{ .{ .copy_to_clipboard = .mixed }, .toggle_command_palette };
    try std.testing.expect(!bindingActionsToggleCommandPalette(&absent));
    try std.testing.expect(bindingActionsToggleCommandPalette(&present));
}

// Differential, not tautological: the same event misses the default
// ctrl+shift+p binding with an empty remap set and matches it with alt=ctrl.
test "win32 key-remap applies to command palette toggle lookup" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const configpkg = @import("../../config.zig");
    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var remaps: input.KeyRemapSet = .empty;
    try remaps.parseCLI(arena.allocator(), "alt=ctrl");
    remaps.finalize();

    const event: input.KeyEvent = .{
        .key = .key_p,
        .mods = .{ .shift = true, .alt = true },
        .unshifted_codepoint = 'p',
    };
    const no_remaps: input.KeyRemapSet = .empty;
    try std.testing.expect(!keyEventTogglesCommandPalette(event, &cfg.keybind.set, &no_remaps));
    try std.testing.expect(keyEventTogglesCommandPalette(event, &cfg.keybind.set, &remaps));
}

test "win32 inspector panel visibility is tab scoped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(inspectorPanelVisibleForState(.none, true));
    try std.testing.expect(!inspectorPanelVisibleForState(.none, false));
    try std.testing.expect(!inspectorPanelVisibleForState(.command_palette, true));
}

test "win32 inspectorBannerStateChanged only trips on actual banner deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!inspectorBannerStateChanged(.none, .none, null, true));
    try std.testing.expect(inspectorBannerStateChanged(.none, .none, null, false));
    try std.testing.expect(!inspectorBannerStateChanged(.none, .info, host_banner_inspector_inactive, false));
    try std.testing.expect(inspectorBannerStateChanged(.none, .err, "error", false));
    try std.testing.expect(!inspectorBannerStateChanged(.search, .none, null, true));
}

test "win32 buildInspectorPanelTitleText reflects host inspector context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildInspectorPanelTitleText(std.testing.allocator, .{ .index = 1, .total = 4 }, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "Inspector") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "tab 2/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorPanelTitleText(std.testing.allocator, .{ .index = 0, .total = 2 }, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoomed") != null);
}

test "win32 buildInspectorPanelHintText reflects live inspector scope" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const single = try buildInspectorPanelHintText(std.testing.allocator, 1, false);
    defer std.testing.allocator.free(single);
    try std.testing.expect(std.mem.indexOf(u8, single, "this tab") != null);

    const multi = try buildInspectorPanelHintText(std.testing.allocator, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorPanelHintText(std.testing.allocator, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoomed pane") != null);
}

// End of labels declarations.

test "tabClosedMessage names the key bound to undo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [96]u8 = undefined;

    var set: input.Binding.Set = .{};
    try std.testing.expectEqualStrings(
        "Tab closed. Use undo to restore it.",
        tabClosedMessage(&set, .{ .us_layout = true }, &buf),
    );

    try set.put(arena.allocator(), .{ .key = .{ .unicode = 't' }, .mods = .{ .ctrl = true } }, .{ .new_tab = {} });
    try std.testing.expectEqualStrings(
        "Tab closed. Use undo to restore it.",
        tabClosedMessage(&set, .{ .us_layout = true }, &buf),
    );

    try set.putFlags(
        arena.allocator(),
        .{ .key = .{ .unicode = 'z' }, .mods = .{ .ctrl = true, .shift = true } },
        .{ .undo = {} },
        .{ .performable = true },
    );
    try std.testing.expectEqualStrings(
        "Tab closed. Press Ctrl+Shift+Z to undo.",
        tabClosedMessage(&set, .{ .us_layout = true }, &buf),
    );

    // `undo-timeout = 0`: bound or not, there is nothing to undo.
    try std.testing.expectEqualStrings(
        "Tab closed.",
        tabClosedMessage(&set, .{ .us_layout = true, .undo_available = false }, &buf),
    );
    var unbound: input.Binding.Set = .{};
    try std.testing.expectEqualStrings(
        "Tab closed.",
        tabClosedMessage(&unbound, .{ .undo_available = false }, &buf),
    );

    // A physical key, and a buffer too small for the hint.
    var other: input.Binding.Set = .{};
    try other.put(arena.allocator(), .{ .key = .{ .physical = .f9 }, .mods = .{ .alt = true } }, .{ .undo = {} });
    try std.testing.expectEqualStrings(
        "Tab closed. Press Alt+F9 to undo.",
        tabClosedMessage(&other, .{ .us_layout = true }, &buf),
    );
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Tab closed. Use undo to restore it.",
        tabClosedMessage(&other, .{ .us_layout = true }, &tiny),
    );
}

test "PKG32 tabClosedMessage does not advertise a shadowed or remapped undo chord" {
    var cfg = try @import("../../config.zig").Config.default(std.testing.allocator);
    defer cfg.deinit();
    var buf: [96]u8 = undefined;
    const fallback = "Tab closed. Use undo to restore it.";
    const set = &cfg.keybind.set;
    try set.put(cfg._arena.?.allocator(), .{
        .key = .{ .physical = .key_z },
        .mods = .{ .ctrl = true, .shift = true },
    }, .ignore);
    try std.testing.expectEqualStrings(fallback, tabClosedMessage(set, .{ .us_layout = true }, &buf));

    // Restore an unambiguous default, then introduce an actual modifier map.
    set.remove(cfg._arena.?.allocator(), .{ .key = .{ .physical = .key_z }, .mods = .{ .ctrl = true, .shift = true } });
    try std.testing.expectEqualStrings("Tab closed. Press Ctrl+Shift+Z to undo.", tabClosedMessage(set, .{ .us_layout = true }, &buf));
    for ([_]u21{ 'Z', 0x1a }) |cp| {
        const trigger: input.Binding.Trigger = .{ .key = .{ .unicode = cp }, .mods = .{ .ctrl = true, .shift = true } };
        try set.put(cfg._arena.?.allocator(), trigger, .ignore);
        try std.testing.expectEqualStrings(fallback, tabClosedMessage(set, .{ .us_layout = true }, &buf));
        set.remove(cfg._arena.?.allocator(), trigger);
    }
    try cfg.@"key-remap".parse(cfg._arena.?.allocator(), "ctrl=alt");
    try std.testing.expectEqualStrings(
        fallback,
        tabClosedMessage(set, .{ .us_layout = true, .has_modifier_remaps = cfg.@"key-remap".map.count() != 0 }, &buf),
    );
}

test "PKG32 tabClosedMessage falls back for layout-dependent physical and text overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var set: input.Binding.Set = .{};
    const mods: input.Mods = .{ .ctrl = true, .shift = true };
    try set.put(alloc, .{ .key = .{ .unicode = 'i' }, .mods = mods }, .undo);
    const physical: input.Binding.Trigger = .{ .key = .{ .physical = .quote }, .mods = mods };
    try set.put(alloc, physical, .ignore);
    // Turkish Q: the dotted i is VK_OEM_7 and its shifted text is U+0130.
    const event: input.KeyEvent = .{
        .action = .press,
        .key = .quote,
        .mods = mods,
        .unshifted_codepoint = 'i',
        .utf8 = "İ",
    };
    var buf: [96]u8 = undefined;
    const fallback = "Tab closed. Use undo to restore it.";
    try std.testing.expectEqual(input.Binding.Action.ignore, set.getEvent(event).?.value_ptr.leaf.action);
    try std.testing.expectEqualStrings(fallback, tabClosedMessage(&set, .{}, &buf));
    set.remove(alloc, physical);
    try set.put(alloc, .{ .key = .{ .unicode = 'İ' }, .mods = mods }, .ignore);
    try std.testing.expectEqual(input.Binding.Action.ignore, set.getEvent(event).?.value_ptr.leaf.action);
    try std.testing.expectEqualStrings(fallback, tabClosedMessage(&set, .{}, &buf));
}
