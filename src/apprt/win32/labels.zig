const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const windows_shell = @import("../../config/windows_shell.zig");
const input = @import("../../input.zig");
const unicode = @import("../../unicode/main.zig");

const win32_elevation = @import("../win32_elevation.zig");
const win32_theme = @import("../win32_theme.zig");
const win32_palette = @import("../win32_palette.zig");
const win32_chrome_state = @import("../win32_chrome_state.zig");
const win32_taskbar_progress = @import("../win32_taskbar_progress.zig");
const win32_search_bar = @import("../win32_search_bar.zig");
const win32_types = @import("../win32_types.zig");
const c = @import("consts.zig");

const ThemeColors = win32_theme.ThemeColors;
const HostOverlayMode = win32_theme.HostOverlayMode;
const darkTheme = win32_theme.darkTheme;
const adjustColor = win32_theme.adjustColor;
const overlayAccentColor = win32_theme.overlayAccentColor;
const rgb = win32_theme.rgb;
const LayoutChildPaintPlan = win32_chrome_state.LayoutChildPaintPlan;
const PaletteSnapshot = win32_palette.Snapshot;
const RankedIndex = win32_palette.RankedIndex;
const PaletteStableId = @TypeOf((@as(win32_palette.catalog.Item, undefined)).id);
const palette_max_tokens = win32_palette.max_tokens;
const palette_max_ranked = win32_palette.max_ranked;
const tokenizePaletteQuery = win32_palette.tokenizeQuery;
const rankPaletteEntry = win32_palette.rankEntry;
const rankedIndicesForQuery = win32_palette.rankedForQuery;
const RECT = win32_types.RECT;
const LPCWSTR = win32_types.LPCWSTR;
const WPARAM = usize;

const default_metrics: win32_theme.ThemeMetrics = .{};
const host_tab_label_max_width: usize = default_metrics.tab_label_max_width;
const host_tab_min_button_width: i32 = default_metrics.tab_min_width;

pub const PalettePresentation = struct {
    match_count: usize = 0,
    title: ?[]const u8 = null,
    subtitle: ?[]const u8 = null,
    available: bool = false,
};

pub const PaletteCompletion = struct {
    text: []const u8,
    id: PaletteStableId,
};

pub const command_palette_unknown_action = "Unknown Noctty action. Example: new_tab or toggle_fullscreen";

const search_prev_label = std.unicode.utf8ToUtf16LeStringLiteral("Prev match");
const search_next_label = std.unicode.utf8ToUtf16LeStringLiteral("Next match");
const search_regex_label = std.unicode.utf8ToUtf16LeStringLiteral("Regex");
const search_case_label = std.unicode.utf8ToUtf16LeStringLiteral("Case sensitive");
const search_word_label = std.unicode.utf8ToUtf16LeStringLiteral("Whole word");
const search_close_label = std.unicode.utf8ToUtf16LeStringLiteral("Close search");

pub const host_banner_inspector_inactive = "Inspector hidden. Terminal view is active.";
const search_results_idle = "Type to search";
const search_results_pending = "Searching";
const search_results_none = "No matches";
const search_results_invalid = "Invalid pattern";

pub const HostTabStatus = struct {
    index: usize = 0,
    total: usize = 1,
};

const VisibleTabRange = struct {
    start: usize,
    count: usize,
};

pub const HostBannerKind = enum {
    none,
    info,
    err,
};

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
    overview,
};

const SearchButtonKeyAction = enum {
    next,
    previous,
    dismiss,
};

pub const LaunchTargetButtonKeyAction = enum {
    previous,
    next,
    first,
    last,
};

pub const ProfileOpenTarget = enum {
    tab,
    window,
    split,
};

pub const ProfileSelection = union(enum) {
    exact: usize,
    ambiguous: usize,
    invalid,
};

pub fn ownedStringEquals(current: ?[:0]const u8, value: []const u8) bool {
    return if (current) |existing|
        std.mem.eql(u8, existing, value)
    else
        false;
}

/// Keyboard focus stops inside the overlay row, in tab order.
/// `preview` is the confirm pane: it takes focus so a keyboard user
/// can scroll the payload before deciding, and so that clicking it
/// to scroll does not strand focus outside the cycle.
pub const OverlayFocusSlot = enum { edit, preview, accept, cancel };

const ResizeSplitFallbackDelta = struct {
    width: i32 = 0,
    height: i32 = 0,
};

pub const SearchBarResultsVisual = struct {
    bg: u32,
    border: u32,
    fg: u32,
};

pub const SearchBarToolbarVisual = struct {
    bg: u32,
    border: u32,
    separator: u32,
};

pub const SearchBarButtonRole = enum {
    prev,
    next,
    regex,
    case_sensitive,
    whole_word,
    close,
};

pub fn tabButtonKeyAction(vk: WPARAM, ctrl_pressed: bool) ?TabButtonKeyAction {
    return switch (vk) {
        // Enter and Space activate the focused tab, matching every other
        // Win32 tab control. Ctrl is ignored here: Ctrl+Enter and
        // Ctrl+Space have no tab meaning and must not silently activate.
        c.VK_RETURN, c.VK_SPACE => if (ctrl_pressed) null else .activate,
        c.VK_LEFT => if (ctrl_pressed) .move_previous else .previous,
        c.VK_RIGHT => if (ctrl_pressed) .move_next else .next,
        c.VK_HOME => if (ctrl_pressed) .move_first else .first,
        c.VK_END => if (ctrl_pressed) .move_last else .last,
        c.VK_F2 => .rename,
        c.VK_DELETE => .close,
        c.VK_APPS => .overview,
        else => null,
    };
}

pub fn moveTabAmountToEdge(total: usize, current: usize, toward_start: bool) isize {
    if (total <= 1 or current >= total) return 0;
    if (toward_start) return -@as(isize, @intCast(current));
    return @as(isize, @intCast((total - 1) - current));
}

pub fn searchButtonKeyAction(vk: WPARAM, shift_pressed: bool) ?SearchButtonKeyAction {
    return switch (vk) {
        c.VK_F3 => if (shift_pressed) .previous else .next,
        c.VK_ESCAPE => .dismiss,
        else => null,
    };
}

pub fn dockedSearchCoreDirectionFromKeyAction(action: SearchButtonKeyAction) ?input.Binding.Action.NavigateSearch {
    return switch (action) {
        .previous => dockedSearchButtonDirection(c.SEARCH_PREV_ID),
        .next => dockedSearchButtonDirection(c.SEARCH_NEXT_ID),
        .dismiss => null,
    };
}

pub fn dockedSearchButtonDirection(command_id: usize) ?input.Binding.Action.NavigateSearch {
    // Core scrollback search indexes matches newest-first
    // (`.previous` => newer/down, `.next` => older/up). The docked
    // search bar is laid out as visible up/down navigation, so the
    // button IDs map to the opposite core enum.
    return switch (command_id) {
        c.SEARCH_PREV_ID => .next,
        c.SEARCH_NEXT_ID => .previous,
        else => null,
    };
}

pub fn dockedSearchEnterDirection(shift_pressed: bool) input.Binding.Action.NavigateSearch {
    return dockedSearchArrowDirection(if (shift_pressed) c.VK_UP else c.VK_DOWN).?;
}

pub fn dockedSearchArrowDirection(vk: WPARAM) ?input.Binding.Action.NavigateSearch {
    return switch (vk) {
        c.VK_UP => dockedSearchButtonDirection(c.SEARCH_PREV_ID),
        c.VK_DOWN => dockedSearchButtonDirection(c.SEARCH_NEXT_ID),
        else => null,
    };
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

pub fn searchSelectedRawFromCoreDisplay(selected: ?usize) ?usize {
    const value = selected orelse return null;
    if (value == 0) return null;
    return value - 1;
}

pub fn searchSelectedDisplayFromRaw(raw: ?usize, total: ?usize) ?usize {
    const idx = raw orelse return null;
    const count = total orelse return null;
    if (count == 0 or idx >= count) return null;
    return idx + 1;
}

pub fn advanceSearchSelectedRaw(
    raw: ?usize,
    total: ?usize,
    dir: input.Binding.Action.NavigateSearch,
    wrap: bool,
) ?usize {
    const idx = raw orelse return null;
    const count = total orelse return null;
    if (count == 0 or idx >= count) return null;
    const last = count - 1;
    return switch (dir) {
        .next => if (idx >= last) if (wrap) 0 else idx else idx + 1,
        .previous => if (idx == 0) if (wrap) last else 0 else idx - 1,
    };
}

pub fn searchBarSearchedStateForTotal(total: ?usize) bool {
    return total != null;
}

pub fn searchBarSearchedStateForSelected(selected: ?usize, total: ?usize) bool {
    return selected != null or total != null;
}

pub fn searchBarDisplayStateChanged(
    search_bar: *const win32_search_bar.SearchBar,
    searched: bool,
    total: ?usize,
    selected: ?usize,
) bool {
    return search_bar.searched != searched or
        search_bar.total != total or
        search_bar.selected != selected;
}

pub fn profileChromeVisible(overlay_mode: HostOverlayMode) bool {
    return win32_chrome_state.profileVisible(overlay_mode);
}

pub fn inspectorVisibilityChangeNeedsHostRelayout(changed: bool) bool {
    return changed;
}

pub fn inspectorPanelVisibleForState(overlay_mode: HostOverlayMode, active_tab_has_inspector: bool) bool {
    return overlay_mode == .none and active_tab_has_inspector;
}

pub fn layoutChildPaintPlan(chrome_changed: bool, content_changed: bool) LayoutChildPaintPlan {
    return win32_chrome_state.layoutChildPaintPlan(chrome_changed, content_changed);
}

pub fn overlayAcceptButtonVisible(mode: HostOverlayMode) bool {
    return mode != .command_palette;
}

/// Whether submitting an empty query field should close the overlay
/// instead of acting on it.
///
/// A confirm prompt has no query field: the EDIT is hidden and always
/// empty, so treating "empty" as "nothing to do" dismisses the prompt
/// without dispatching either callback and strands the caller's pending
/// operation. The switch is exhaustive on purpose — a new mode has to
/// state its answer rather than silently inherit the dismissing one.
pub fn overlayEmptySubmitDismisses(mode: HostOverlayMode) bool {
    return switch (mode) {
        .search, .profile, .command_palette, .confirm => false,
        .none, .surface_title, .tab_title, .tab_overview => true,
    };
}

/// Whether the overlay's text is prefilled from the active surface and
/// written back to the active surface on submit. Those prompts must refill
/// when the active surface changes (a tab switch or focus moving to another
/// split pane) while they are open, or submit writes one surface's title
/// onto another. Exhaustive for the same reason as
/// `overlayEmptySubmitDismisses`.
pub fn overlayTextFollowsActiveSurface(mode: HostOverlayMode) bool {
    return switch (mode) {
        .surface_title, .tab_title => true,
        .none, .command_palette, .profile, .search, .tab_overview, .confirm => false,
    };
}

/// Whether an open title prompt has to refill its text: the prompt follows
/// the active surface, there is one, and it is not the surface the text was
/// last filled from, i.e. the active surface changed (a tab switch or focus
/// moving to another split pane). A refresh on the same surface leaves what
/// the user typed alone. Surfaces are compared by identity only.
pub fn overlayTextNeedsRefill(
    mode: HostOverlayMode,
    filled_from: ?*const anyopaque,
    active: ?*const anyopaque,
) bool {
    if (!overlayTextFollowsActiveSurface(mode)) return false;
    const surface = active orelse return false;
    return filled_from != surface;
}

pub fn overlayEditFrameVisible(mode: HostOverlayMode) bool {
    return mode != .confirm;
}

fn nextOverlayFocusSlot(mode: HostOverlayMode, current: OverlayFocusSlot, reverse: bool) OverlayFocusSlot {
    if (mode == .confirm) {
        // preview -> accept -> cancel -> preview. `.edit` is hidden in
        // this mode and only appears here as a landing correction when
        // focus arrives from somewhere outside the cycle.
        return if (reverse)
            switch (current) {
                .accept => .preview,
                .cancel => .accept,
                .preview, .edit => .cancel,
            }
        else switch (current) {
            .preview, .edit => .accept,
            .accept => .cancel,
            .cancel => .preview,
        };
    }
    // The preview pane exists only for confirm prompts, so outside that
    // mode it is just another way of saying "back to the query field".
    if (!overlayAcceptButtonVisible(mode)) return if (current == .edit) .cancel else .edit;
    return if (reverse)
        switch (current) {
            .edit => .cancel,
            .accept => .edit,
            .cancel => .accept,
            .preview => .edit,
        }
    else switch (current) {
        .edit => .accept,
        .accept => .cancel,
        .cancel => .edit,
        .preview => .edit,
    };
}

fn overlayFocusSlotVisible(
    slot: OverlayFocusSlot,
    edit_visible: bool,
    preview_visible: bool,
    accept_visible: bool,
    cancel_visible: bool,
) bool {
    return switch (slot) {
        .edit => edit_visible,
        .preview => preview_visible,
        .accept => accept_visible,
        .cancel => cancel_visible,
    };
}

pub fn nextVisibleOverlayFocusSlot(
    mode: HostOverlayMode,
    current: OverlayFocusSlot,
    reverse: bool,
    edit_visible: bool,
    preview_visible: bool,
    accept_visible: bool,
    cancel_visible: bool,
) ?OverlayFocusSlot {
    var candidate = current;
    // One iteration per slot: a full lap proves nothing else is visible.
    for (0..@typeInfo(OverlayFocusSlot).@"enum".fields.len) |_| {
        candidate = nextOverlayFocusSlot(mode, candidate, reverse);
        if (candidate != current and overlayFocusSlotVisible(
            candidate,
            edit_visible,
            preview_visible,
            accept_visible,
            cancel_visible,
        )) return candidate;
    }
    return null;
}

pub fn inspectorChromeVisible(overlay_mode: HostOverlayMode) bool {
    return win32_chrome_state.inspectorVisible(overlay_mode);
}

pub fn inspectorBannerStateChanged(
    overlay_mode: HostOverlayMode,
    banner_kind: HostBannerKind,
    banner_text: ?[:0]const u8,
    visible: bool,
) bool {
    if (overlay_mode != .none) return false;
    if (visible) return banner_kind != .none or banner_text != null;
    return banner_kind != .info or !ownedStringEquals(banner_text, host_banner_inspector_inactive);
}

pub fn windowTitleSyncChanged(current: ?[:0]const u8, next: []const u8) bool {
    return !ownedStringEquals(current, next);
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
    if (slot_ordinal >= 3) return null;
    return quickSlotProfileIndex(profiles_len, selected_index, slot_ordinal, 3);
}

pub fn quickSlotPinOrdinalFromKey(vk: WPARAM, alt_pressed: bool, shift_pressed: bool) ?usize {
    if (!alt_pressed or !shift_pressed) return null;
    const slot_ordinal = profileShortcutIndexFromKey(vk) orelse return null;
    if (slot_ordinal >= 3) return null;
    return slot_ordinal;
}

pub fn clearQuickSlotPinsRequested(vk: WPARAM, alt_pressed: bool, shift_pressed: bool) bool {
    if (!alt_pressed or !shift_pressed) return false;
    return vk == c.VK_0 or vk == c.VK_NUMPAD0;
}

pub fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (prefix.len > haystack.len) return false;
    for (haystack[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

pub fn storedProfileKeyEquals(a: []const u8, b: []const u8) bool {
    if (startsWithIgnoreCase(a, "ssh:") or startsWithIgnoreCase(b, "ssh:")) {
        return std.mem.eql(u8, a, b);
    }
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn profileKeyEquals(profile: windows_shell.Profile, key: []const u8) bool {
    if (profile.kind == .ssh) return std.mem.eql(u8, profile.key, key);
    return storedProfileKeyEquals(profile.key, key);
}

pub fn resolveProfileSelection(
    profiles: []const windows_shell.Profile,
    input_text: []const u8,
    fallback_index: usize,
) ProfileSelection {
    if (profiles.len == 0) return .invalid;
    const fallback = @min(fallback_index, profiles.len - 1);
    if (input_text.len == 0) return .{ .exact = fallback };

    const requested = std.fmt.parseUnsigned(usize, input_text, 10) catch null;
    if (requested) |value| {
        if (value == 0 or value > profiles.len) return .invalid;
        return .{ .exact = value - 1 };
    }

    var exact_match: ?usize = null;
    var unique_match: ?usize = null;
    var match_count: usize = 0;
    for (profiles, 0..) |profile, index| {
        const label_matches = if (profile.kind == .ssh)
            std.mem.eql(u8, profile.label, input_text)
        else
            std.ascii.eqlIgnoreCase(profile.label, input_text);
        if (profileKeyEquals(profile, input_text) or label_matches) {
            exact_match = index;
            break;
        }
        if (startsWithIgnoreCase(profile.key, input_text) or
            startsWithIgnoreCase(profile.label, input_text))
        {
            unique_match = index;
            match_count += 1;
        }
    }
    if (exact_match) |index| return .{ .exact = index };
    if (match_count == 1) return .{ .exact = unique_match.? };
    if (match_count > 1) return .{ .ambiguous = match_count };
    return .invalid;
}

pub fn profileIndexByKey(profiles: []const windows_shell.Profile, key: []const u8) ?usize {
    for (profiles, 0..) |profile, index| {
        if (profileKeyEquals(profile, key)) return index;
    }
    return null;
}

pub fn preferredProfileIndex(
    profiles: []const windows_shell.Profile,
    selected_key: ?[]const u8,
    app_key: ?[]const u8,
    hint: ?[]const u8,
    fallback_index: usize,
) ?usize {
    if (profiles.len == 0) return null;

    const preferred_key = if (selected_key) |key|
        key
    else if (app_key) |key|
        key
    else
        null;
    if (preferred_key) |key| {
        for (profiles, 0..) |profile, index| {
            if (profileKeyEquals(profile, key)) return index;
        }
    }

    if (hint) |value| {
        return switch (resolveProfileSelection(profiles, value, fallback_index)) {
            .exact => |index| index,
            .ambiguous, .invalid => null,
        };
    }

    return null;
}

pub fn quickSlotProfileIndex(
    profiles_len: usize,
    selected_index: ?usize,
    slot_ordinal: usize,
    max_slots: usize,
) ?usize {
    if (profiles_len == 0 or slot_ordinal >= max_slots) return null;
    var drawn: usize = 0;
    var index: usize = 0;
    while (index < profiles_len) : (index += 1) {
        if (selected_index != null and index == selected_index.?) continue;
        if (drawn == slot_ordinal) return index;
        drawn += 1;
        if (drawn >= max_slots) break;
    }
    return null;
}

pub fn resolveWindowBaseTitle(
    terminal_title: ?[:0]const u8,
    surface_override: ?[:0]const u8,
    tab_override: ?[:0]const u8,
) ?[:0]const u8 {
    return tab_override orelse surface_override orelse terminal_title;
}

pub fn normalizedBackgroundOpacity(value: f64) f64 {
    return std.math.clamp(value, 0.0, 1.0);
}

pub fn effectiveBackgroundOpacity(configured: f64, force_opaque: bool) f64 {
    return if (force_opaque) 1.0 else configured;
}

pub fn alphaByteForOpacity(value: f64) u8 {
    return @intFromFloat(@round(normalizedBackgroundOpacity(value) * 255.0));
}

pub fn resizeSplitFallbackDelta(value: apprt.action.ResizeSplit) ResizeSplitFallbackDelta {
    const amount: i32 = @intCast(value.amount);
    return switch (value.direction) {
        .left => .{ .width = -amount },
        .right => .{ .width = amount },
        .up => .{ .height = -amount },
        .down => .{ .height = amount },
    };
}

fn nextInspectorVisible(current: bool, mode: apprt.action.Inspector) bool {
    return switch (mode) {
        .toggle => !current,
        .show => true,
        .hide => false,
    };
}

pub fn nextTabInspectorVisible(active_tab_has_inspector: bool, mode: apprt.action.Inspector) bool {
    return nextInspectorVisible(active_tab_has_inspector, mode);
}

pub fn buildHostAwareBaseTitle(
    alloc: Allocator,
    base_title: ?[]const u8,
    host: HostTabStatus,
    elevated: bool,
) ![]u8 {
    const normalized_title = if (base_title) |value|
        if (elevated and std.mem.startsWith(u8, value, win32_elevation.title_prefix))
            value[win32_elevation.title_prefix.len..]
        else
            value
    else
        null;
    const composed = if (host.total <= 1)
        try alloc.dupe(u8, normalized_title orelse "noctty")
    else
        try std.fmt.allocPrint(
            alloc,
            "[{d}/{d}] {s}",
            .{ host.index + 1, host.total, normalized_title orelse "noctty" },
        );
    defer alloc.free(composed);
    return try win32_elevation.allocPrefixedTitle(alloc, composed, elevated);
}

/// Compact `value` to `max_width` display cells, ending in an ellipsis when it
/// had to cut. The budget is cells, not bytes or codepoints: callers derive it
/// from a pixel width (see `hostTabLabelMaxWidth`), and cells are what a pixel
/// budget actually buys. Counting bytes would hand a CJK title a third of the
/// room it can use -- 24 bytes is 8 kana -- while counting codepoints would let
/// the same title overrun the space reserved for it.
fn compactHostLabel(
    alloc: Allocator,
    value: []const u8,
    max_width: usize,
) ![]u8 {
    if (displayWidth(value) <= max_width) return try alloc.dupe(u8, value);
    if (max_width <= 3) return try alloc.dupe(u8, "...");
    const cut = displayWidthFloor(value, max_width - 3);
    return try std.fmt.allocPrint(alloc, "{s}...", .{value[0..cut]});
}

/// Display width of `value` in cells.
///
/// Bytes that do not decode count as one cell each: a title that arrived
/// mangled still gets compacted against a sane budget instead of failing the
/// caller.
fn displayWidth(value: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (decodeCodepoint(value, i)) |decoded| {
            width += codepointWidth(decoded.cp);
            i += decoded.len;
        } else {
            width += 1;
            i += 1;
        }
    }
    return width;
}

/// Byte index of the longest prefix of `value` that fits in `max_width` cells.
///
/// The cut always lands on a UTF-8 sequence boundary. Labels are later
/// converted with `utf8ToUtf16LeAllocZ`, which rejects the result with
/// `error.InvalidUtf8` when the cut landed inside a multi-byte codepoint. Any
/// non-ASCII title -- CJK, an emoji, an accented path -- hits that on the tab
/// strip as soon as a tab is narrow enough to truncate. A double-width
/// codepoint that would straddle the budget is left out rather than allowed to
/// spill one cell past it.
fn displayWidthFloor(value: []const u8, max_width: usize) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        const decoded = decodeCodepoint(value, i) orelse {
            if (width + 1 > max_width) return i;
            width += 1;
            i += 1;
            continue;
        };
        const cell_width = codepointWidth(decoded.cp);
        if (width + cell_width > max_width) return i;
        width += cell_width;
        i += decoded.len;
    }
    return value.len;
}

const DecodedCodepoint = struct {
    cp: u21,
    len: usize,
};

fn decodeCodepoint(value: []const u8, index: usize) ?DecodedCodepoint {
    const len = std.unicode.utf8ByteSequenceLength(value[index]) catch return null;
    if (index + len > value.len) return null;
    const cp = std.unicode.utf8Decode(value[index..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

/// Cells one codepoint occupies, read from the same table the terminal grid
/// uses so the chrome and the grid agree on what "wide" means.
fn codepointWidth(cp: u21) usize {
    if (cp <= 0xFF) return 1;
    return @intCast(unicode.table.get(cp).width);
}

/// Cell budget for a tab label drawn into a `button_width` pixel button.
///
/// The divisor is an average glyph advance, so the budget is an estimate; GDI
/// still applies `DT_END_ELLIPSIS` when the estimate ran long.
pub fn hostTabLabelMaxWidth(button_width: i32, dpi: u32) usize {
    const estimated = @as(usize, @intCast(@max(6, @divTrunc(button_width - win32_chrome_state.scaled(26, dpi), @max(1, win32_chrome_state.scaled(8, dpi))))));
    return std.math.clamp(estimated, @as(usize, 6), @as(usize, host_tab_label_max_width));
}

/// Widest tooltip title the tab strip will build. A title past this is
/// pathological -- a runaway OSC 0 sequence, say -- and the popup would run off
/// the window long before it was readable.
pub const tab_tooltip_max_width: usize = 240;

/// Whether `value` has to be compacted to fit `max_width` cells, i.e. whether
/// the drawn label is hiding part of the title. This is what decides if a tab
/// has anything to say in a tooltip.
///
/// Feed it the bare title and the budget that title was actually compacted to
/// (`tabButtonTitleBudget`). Feeding it the decorated label and the button's
/// own budget compares two different things: the label carries the index, the
/// active marker and the pane count, and `buildTabButtonLabel` already keeps
/// the whole label inside the button.
pub fn hostLabelIsCompacted(value: []const u8, max_width: usize) bool {
    return displayWidth(value) > max_width;
}

/// UIA name for one tab item, written into the provider's stack buffer.
///
/// The name carries the tab's 1-based index and its FULL title -- assistive
/// technology has no button to run out of -- plus the pane count the drawn
/// label shows, because "2: pwsh" and "2: pwsh (3)" are different tabs to a
/// screen-reader user and only the second one is split. Returns null when
/// `buf` cannot hold the result so the caller can fall back to the drawn
/// label.
pub fn buildTabItemUiaName(
    buf: []u8,
    index: usize,
    title: []const u8,
    pane_count: usize,
) ?[]const u8 {
    if (pane_count > 1) {
        return std.fmt.bufPrint(
            buf,
            "{d}: {s} ({d})",
            .{ index + 1, title, pane_count },
        ) catch null;
    }
    return std.fmt.bufPrint(buf, "{d}: {s}", .{ index + 1, title }) catch null;
}

/// Whether the name `buildTabItemUiaName` builds differs between a tab's
/// previously cached inputs and its current ones.
///
/// The drawn label cannot answer this. `shouldShowPaneCount` keeps the count
/// out of a narrow tab's label, so splitting such a tab moves the name while
/// the label stays byte-identical, and a reader driven by NameChanged events
/// keeps announcing the old one. Keep these inputs in step with
/// `buildTabItemUiaName`.
pub fn tabItemUiaNameChanged(
    cached_title: ?[:0]const u8,
    cached_index: usize,
    cached_pane_count: usize,
    title: ?[]const u8,
    index: usize,
    pane_count: usize,
) bool {
    if (cached_index != index) return true;
    if (cached_pane_count != pane_count) return true;
    // A tab with no title falls back to the drawn label, which the caller
    // already compares.
    const value = title orelse return cached_title != null;
    return !ownedStringEquals(cached_title, value);
}

/// Title text for a tab's hover tooltip: the whole thing, bounded only by
/// `tab_tooltip_max_width`.
pub fn buildTabTooltipText(alloc: Allocator, value: []const u8) ![]u8 {
    return try compactHostLabel(alloc, value, tab_tooltip_max_width);
}

pub fn shouldShowPaneCount(button_width: i32, pane_count: usize, dpi: u32) bool {
    return pane_count > 1 and button_width >= win32_chrome_state.scaled(140, dpi);
}

pub fn visibleTabRange(tab_count: usize, active_index: usize, tab_area_width: i32, dpi: u32) VisibleTabRange {
    if (tab_count == 0) return .{ .start = 0, .count = 0 };
    const max_visible = std.math.clamp(
        @as(usize, @intCast(@max(1, @divTrunc(tab_area_width, @max(1, win32_chrome_state.scaled(host_tab_min_button_width, dpi)))))),
        @as(usize, 1),
        tab_count,
    );
    if (tab_count <= max_visible) return .{ .start = 0, .count = tab_count };

    const clamped_active = @min(active_index, tab_count - 1);
    var start = clamped_active;
    if (max_visible > 1) start = clamped_active -| @divTrunc(max_visible - 1, 2);
    if (start + max_visible > tab_count) start = tab_count - max_visible;
    return .{ .start = start, .count = max_visible };
}

const tab_button_label_fmt = "{s}{d}: {s}";
const tab_button_label_pane_fmt = "{s}{d}: {s} ({d})";

/// Smallest title budget `tabButtonTitleBudget` will hand back. A button too
/// narrow to hold even its own decorations still shows an ellipsis rather than
/// nothing; the label then overflows, which is exactly what the tab strip's
/// `DT_END_ELLIPSIS` is there for.
const tab_button_min_title_width: usize = 3;

/// Cells left for the title after `buildTabButtonLabel`'s decorations --
/// the `"* "` active marker, the `"N: "` index prefix and the `" (N)"` pane
/// count -- are paid for out of `max_width`.
///
/// `max_width` is what the BUTTON can draw. Compacting the bare title to all
/// of it and only then adding the decorations spent up to nine cells the
/// button never had: the drawn label overflowed, and because the tooltip gate
/// measures the drawn label against this same budget, the active tab claimed
/// it was hiding part of a title that its inactive neighbour -- same title,
/// two cells cheaper -- reported as fitting. Charge the decorations first and
/// both the label and the gate stay inside the button.
pub fn tabButtonTitleBudget(
    index: usize,
    active: bool,
    pane_count: usize,
    max_width: usize,
    show_pane_count: bool,
) usize {
    // Render the decorations around an empty title so the measurement can
    // never drift from the format strings below, and measure them with the
    // same `displayWidth` the compaction spends its budget in.
    var buf: [96]u8 = undefined;
    const decoration = if (show_pane_count and pane_count > 1)
        std.fmt.bufPrint(
            &buf,
            tab_button_label_pane_fmt,
            .{ tabButtonActiveMarker(active), index + 1, "", pane_count },
        )
    else
        std.fmt.bufPrint(
            &buf,
            tab_button_label_fmt,
            .{ tabButtonActiveMarker(active), index + 1, "" },
        );
    // `buf` holds the widest decoration two `usize` decimals can produce, so
    // the error arm is unreachable in practice; charging the whole budget
    // keeps it conservative rather than silently restoring the old overflow.
    const decoration_width = if (decoration) |text| displayWidth(text) else |_| max_width;
    return @max(tab_button_min_title_width, max_width -| decoration_width);
}

fn tabButtonActiveMarker(active: bool) []const u8 {
    return if (active) "* " else "";
}

pub fn buildTabButtonLabel(
    alloc: Allocator,
    base_title: ?[]const u8,
    index: usize,
    active: bool,
    pane_count: usize,
    max_width: usize,
    show_pane_count: bool,
) ![]u8 {
    const budget = tabButtonTitleBudget(index, active, pane_count, max_width, show_pane_count);
    const compact = try compactHostLabel(alloc, base_title orelse "noctty", budget);
    defer alloc.free(compact);
    if (show_pane_count and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            tab_button_label_pane_fmt,
            .{
                tabButtonActiveMarker(active),
                index + 1,
                compact,
                pane_count,
            },
        );
    }

    return try std.fmt.allocPrint(
        alloc,
        tab_button_label_fmt,
        .{
            tabButtonActiveMarker(active),
            index + 1,
            compact,
        },
    );
}

pub fn buildSearchOverlayLabel(
    alloc: Allocator,
    total: ?usize,
    selected: ?usize,
) ![]u8 {
    if (selected) |current| {
        if (total) |count| return try std.fmt.allocPrint(alloc, "Find {d}/{d}", .{ current, count });
    }
    if (total) |count| return try std.fmt.allocPrint(alloc, "Find {d}", .{count});
    return try alloc.dupe(u8, "Find");
}

pub fn buildSearchBarResultsText(
    alloc: Allocator,
    bar: *const win32_search_bar.SearchBar,
) ![]u8 {
    if (bar.query.len == 0) return try alloc.dupe(u8, search_results_idle);
    if (!bar.searched or bar.total == null) return try alloc.dupe(u8, search_results_pending);

    if (bar.invalid) return try alloc.dupe(u8, search_results_invalid);
    const total = bar.total.?;
    if (total == 0) return try alloc.dupe(u8, search_results_none);
    if (bar.selected) |selected| return try std.fmt.allocPrint(alloc, "{d}/{d}", .{ selected, total });
    return try std.fmt.allocPrint(alloc, "{d}", .{total});
}

pub fn searchBarButtonCommandId(role: SearchBarButtonRole) usize {
    return switch (role) {
        .prev => c.SEARCH_PREV_ID,
        .next => c.SEARCH_NEXT_ID,
        .regex => c.SEARCH_REGEX_ID,
        .case_sensitive => c.SEARCH_CASE_ID,
        .whole_word => c.SEARCH_WORD_ID,
        .close => c.SEARCH_CLOSE_ID,
    };
}

pub fn searchBarButtonLabel(role: SearchBarButtonRole) LPCWSTR {
    return switch (role) {
        .prev => search_prev_label,
        .next => search_next_label,
        .regex => search_regex_label,
        .case_sensitive => search_case_label,
        .whole_word => search_word_label,
        .close => search_close_label,
    };
}

/// What a search bar button does, in words: its UIA name, and the hover
/// tooltip that spells out its icon, so those two always agree. The window
/// text, which a wide button draws as its label and MSAA reports as its
/// name, comes from `searchBarButtonLabel` instead.
pub fn searchBarButtonName(role: SearchBarButtonRole) []const u8 {
    return switch (role) {
        .prev => "Previous match",
        .next => "Next match",
        .regex => "Regular expression",
        .case_sensitive => "Case sensitive",
        .whole_word => "Whole word",
        .close => "Close search",
    };
}

pub fn showSearchBarResults(bar: *const win32_search_bar.SearchBar) bool {
    return bar.query.len > 0;
}

/// Docked-search geometry only changes when the fixed-width results slot
/// appears or disappears. Query text updates within the non-empty state
/// repaint child HWNDs but do not move controls.
pub fn searchBarNeedsRelayoutForQueryChange(previous_query_len: usize, next_query_len: usize) bool {
    return (previous_query_len == 0) != (next_query_len == 0);
}

/// Once a query has reached core search, any edit must invalidate it until the
/// debounced replacement query runs.
pub fn searchBarShouldInvalidateCoreSearchOnEdit(previous_query_len: usize, next_query_len: usize) bool {
    _ = next_query_len;
    return previous_query_len > 0;
}

pub fn shouldAcceptCoreSearchUpdates(bar: *const win32_search_bar.SearchBar) bool {
    return bar.query.len == 0 or bar.searched;
}

pub fn searchBarButtonShowsLabel(role: SearchBarButtonRole, button_width: i32) bool {
    _ = role;
    _ = button_width;
    return false;
}

pub fn rectInset(rect: RECT, inset_x: i32, inset_y: i32) RECT {
    return .{
        .left = rect.left + inset_x,
        .top = rect.top + inset_y,
        .right = rect.right - inset_x,
        .bottom = rect.bottom - inset_y,
    };
}

pub fn rectUnion(a: RECT, b: RECT) RECT {
    return .{
        .left = @min(a.left, b.left),
        .top = @min(a.top, b.top),
        .right = @max(a.right, b.right),
        .bottom = @max(a.bottom, b.bottom),
    };
}

pub fn rectOffset(rect: RECT, dx: i32, dy: i32) RECT {
    return .{
        .left = rect.left + dx,
        .top = rect.top + dy,
        .right = rect.right + dx,
        .bottom = rect.bottom + dy,
    };
}

pub fn searchBarResultsVisual(
    theme: *const ThemeColors,
    bar: *const win32_search_bar.SearchBar,
) SearchBarResultsVisual {
    const accent = overlayAccentColor(.search, theme.is_dark);
    if (!bar.searched or bar.total == null) {
        return .{
            .bg = if (theme.is_dark)
                adjustColor(theme.overlay_bg, 8, 10, 10)
            else
                adjustColor(theme.overlay_bg, -6, -4, -2),
            .border = accent,
            .fg = theme.overlay_label_fg,
        };
    }

    if (bar.total.? == 0) {
        return .{
            .bg = if (theme.is_dark)
                rgb(48, 28, 30)
            else
                rgb(252, 236, 236),
            .border = theme.error_fg,
            .fg = theme.error_fg,
        };
    }

    return .{
        .bg = if (theme.is_dark)
            adjustColor(theme.edit_frame_bg, 10, 14, 10)
        else
            adjustColor(theme.edit_frame_bg, -6, -2, -4),
        .border = accent,
        .fg = theme.overlay_label_fg,
    };
}

pub fn searchBarToolbarVisual(theme: *const ThemeColors) SearchBarToolbarVisual {
    return .{
        .bg = if (theme.is_dark)
            adjustColor(theme.edit_frame_bg, 6, 8, 10)
        else
            adjustColor(theme.edit_frame_bg, -4, -2, -2),
        .border = if (theme.is_dark)
            adjustColor(theme.overlay_border, 18, 18, 20)
        else
            adjustColor(theme.overlay_border, -18, -18, -18),
        .separator = if (theme.is_dark)
            adjustColor(theme.overlay_border, 30, 30, 34)
        else
            adjustColor(theme.overlay_border, -26, -26, -26),
    };
}

pub fn searchBarFrameBg(theme: *const ThemeColors) u32 {
    return if (theme.is_dark)
        adjustColor(theme.overlay_bg, 3, 3, 5)
    else
        adjustColor(theme.overlay_bg, -2, -2, -1);
}

pub fn searchBarFrameBorder(theme: *const ThemeColors) u32 {
    return if (theme.is_dark)
        adjustColor(theme.overlay_border, 10, 10, 12)
    else
        adjustColor(theme.overlay_border, -14, -14, -14);
}

pub fn searchBarBottomLine(theme: *const ThemeColors) u32 {
    return if (theme.is_dark)
        adjustColor(theme.overlay_border, -10, -10, -8)
    else
        adjustColor(theme.overlay_border, 10, 10, 10);
}

pub fn searchBarButtonParentBg(theme: *const ThemeColors, role: SearchBarButtonRole) u32 {
    return switch (role) {
        .close => theme.overlay_bg,
        else => searchBarToolbarVisual(theme).bg,
    };
}

pub fn buildTabOverviewOverlayLabel(
    alloc: Allocator,
    current_index: usize,
    total: usize,
) ![]u8 {
    if (total <= 1) return try alloc.dupe(u8, "Tab");
    return try std.fmt.allocPrint(alloc, "Tab {d}/{d}", .{ current_index + 1, total });
}

/// The longest prefix of `text` that fits `limit` bytes without splitting
/// a UTF-8 sequence.
///
/// For UI Automation names, which are converted to a `BSTR` and rejected
/// outright if the conversion fails: a name that overflows its caller's
/// buffer has to come back shortened, never empty, because the caller is
/// usually a live region that is about to be announced.
///
/// Deliberately simpler than the back-off in `buildConfirmPreview`, which
/// must not drag its cut through orphan continuation bytes because it is
/// showing arbitrary payload bytes and reports how many it showed. Names
/// come from strings this process built, so a plain walk is enough.
pub fn utf8BoundedPrefix(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    // A UTF-8 sequence is at most 4 bytes, so the lead byte is at most 3
    // positions back.
    var steps: usize = 0;
    while (steps < 4 and end > 0) : (steps += 1) {
        if ((text[end] & 0xC0) != 0x80) break;
        end -= 1;
    }
    return text[0..end];
}

/// The prompt text carried by an active confirm overlay. Chrome paint
/// renders these directly: a confirm prompt has no fixed wording, so the
/// caller-supplied title and body are the only text that identifies what
/// is being confirmed. A null value means no payload is installed (the
/// overlay is mid-teardown) and the placeholders below stand in.
pub const ConfirmText = struct {
    title: []const u8,
    body: []const u8,
    /// Size of the payload the preview pane is showing, appended to the
    /// body line so the amount being approved is stated even when the
    /// pane only shows the head of it. Empty for prompts with no
    /// payload, and for a dropped payload mid-teardown.
    preview_caption: []const u8 = "",
};

/// How much of a confirm payload the preview pane renders. A paste can
/// be megabytes; a Win32 EDIT chokes long before that, and nobody reads
/// a megabyte before clicking Allow. Only the DISPLAY is capped — the
/// bytes actually delivered on Accept come from the Surface's pending
/// clipboard op, never from this preview.
pub const confirm_preview_limit: usize = 64 * 1024;

/// A confirm payload rendered for display.
pub const ConfirmPreview = struct {
    /// UTF-8 that is safe to hand to a Win32 EDIT: always valid
    /// encoding, never contains NUL, never contains bidirectional
    /// formatting characters that could reorder the displayed payload,
    /// and uses CRLF line endings so the control breaks lines where the
    /// payload does. Other control characters pass through and may
    /// render as a box or as nothing; see `buildConfirmPreview`.
    text: []u8,
    /// How many source bytes `text` represents.
    shown_bytes: usize,
    /// How many bytes the source had in total.
    total_bytes: usize,

    pub fn truncated(self: ConfirmPreview) bool {
        return self.shown_bytes < self.total_bytes;
    }

    pub fn deinit(self: *ConfirmPreview, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

/// Unicode bidirectional formatting characters.
///
/// These are invisible and reorder the text around them, so a preview
/// containing them can display something other than what the payload
/// actually says — the precise failure this pane exists to prevent
/// (CVE-2021-42574, "Trojan Source"). Ordinary control characters are
/// left alone: they render as a box or as nothing, but they do not lie
/// about the order of what surrounds them.
///
/// This is a real trade-off, not a pure win: these characters appear in
/// legitimate right-to-left text too, so a genuine RTL payload shows
/// U+FFFD where its directional marks were. The pane's job is to be
/// trustworthy about order rather than pretty, and the substitution is
/// documented in `docs/windows-capability-matrix.md` so the behaviour is
/// not a surprise.
fn isBidiFormatting(cp: u21) bool {
    return switch (cp) {
        0x061C, // ARABIC LETTER MARK
        0x200E, // LEFT-TO-RIGHT MARK
        0x200F, // RIGHT-TO-LEFT MARK
        0x202A...0x202E, // LRE, RLE, PDF, LRO, RLO
        0x2066...0x2069, // LRI, RLI, FSI, PDI
        => true,
        else => false,
    };
}

fn appendCodepoint(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(alloc, buf[0..len]);
}

/// What a program in the terminal asked to do with the clipboard (OSC 52).
pub const ProgramClipboardRequest = enum { read, write };

/// Its own wording, so the prompt cannot be taken for the one the user's
/// own unsafe paste raises.
pub fn programClipboardPromptTitle(request: ProgramClipboardRequest) []const u8 {
    return switch (request) {
        .read => "Let a program read your clipboard?",
        .write => "Let a program change your clipboard?",
    };
}

/// Cells, and code points, of the tab title a program's clipboard prompt
/// quotes.
const program_prompt_title_width = 24;

/// A tab as a prompt names it, by its number and title as the tab strip
/// shows them: `Tab 2 (vim)`. The title is the program's own text, so it may
/// not crowd out or disguise the words around it: it is cut to
/// `program_prompt_title_width` cells and as many code points (zero-width
/// marks take no cell, and stacked they draw over the line), and controls,
/// line and paragraph separators, and bidirectional formatting characters
/// (which would reorder the words after it; see `isBidiFormatting`) become
/// U+FFFD. Any prompt that can come from a tab other than the one in front
/// names it this way.
pub fn promptTabName(alloc: Allocator, tab_number: usize, tab_title: ?[]const u8) ![]u8 {
    const raw = tab_title orelse "noctty";
    const limit = program_prompt_title_width;
    var title: std.ArrayListUnmanaged(u8) = .empty;
    defer title.deinit(alloc);
    var cells: usize = 0;
    var count: usize = 0;
    // Where "..." goes if the title turns out not to fit.
    var cut: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        const decoded = decodeCodepoint(raw, i) orelse DecodedCodepoint{ .cp = 0xFFFD, .len = 1 };
        i += decoded.len;
        const cp = switch (decoded.cp) {
            0...0x1F, 0x7F...0x9F, 0x2028, 0x2029 => 0xFFFD, // controls, line and paragraph separators
            else => if (isBidiFormatting(decoded.cp)) 0xFFFD else decoded.cp,
        };
        cells += codepointWidth(cp);
        count += 1;
        if (cells > limit or count > limit) {
            title.shrinkRetainingCapacity(cut);
            try title.appendSlice(alloc, "...");
            break;
        }
        try appendCodepoint(alloc, &title, cp);
        if (cells <= limit - 3 and count <= limit - 3) cut = title.items.len;
    }
    return std.fmt.allocPrint(alloc, "Tab {d} ({s})", .{ tab_number, title.items });
}

/// The body of a program's clipboard prompt, which names the tab that asked.
pub fn buildProgramClipboardPromptBody(
    alloc: Allocator,
    request: ProgramClipboardRequest,
    tab_number: usize,
    tab_title: ?[]const u8,
) ![]u8 {
    const tab = try promptTabName(alloc, tab_number, tab_title);
    defer alloc.free(tab);
    return switch (request) {
        .read => std.fmt.allocPrint(alloc, "{s} asked to read your clipboard. Allow sends it the text below.", .{tab}),
        .write => std.fmt.allocPrint(alloc, "{s} asked to replace your clipboard with the text below.", .{tab}),
    };
}

/// The title of the prompt for closing a tab that is not the one in front
/// (`close_tab:this` from its button), which has to say which tab.
pub fn backgroundTabClosePromptTitle(buf: *[32]u8, tab_number: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Close tab {d}?", .{tab_number}) catch "Close a tab?";
}

/// The same for a terminal that closes by itself in a tab that is not the
/// one in front (a read-only terminal whose program exited asks first).
pub fn backgroundTerminalClosePromptTitle(buf: *[32]u8, tab_number: usize) []const u8 {
    return std.fmt.bufPrint(buf, "Close terminal in tab {d}?", .{tab_number}) catch "Close a terminal?";
}

pub fn buildBackgroundTerminalClosePromptBody(
    alloc: Allocator,
    tab_number: usize,
    tab_title: ?[]const u8,
    program_exited: bool,
) ![]u8 {
    const tab = try promptTabName(alloc, tab_number, tab_title);
    defer alloc.free(tab);
    // Read-only mode is why a terminal whose program has exited still asks.
    return if (program_exited)
        std.fmt.allocPrint(alloc, "The program in {s} has exited. Read-only mode makes closing that terminal ask first.", .{tab})
    else
        std.fmt.allocPrint(alloc, "A process is still running in {s}. Closing that terminal will terminate it.", .{tab});
}

/// Its body, for `count` terminals the tab would end, with undo off.
pub fn buildBackgroundTabClosePromptBody(
    alloc: Allocator,
    count: usize,
    tab_number: usize,
    tab_title: ?[]const u8,
) ![]u8 {
    const tab = try promptTabName(alloc, tab_number, tab_title);
    defer alloc.free(tab);
    return if (count <= 1)
        std.fmt.allocPrint(alloc, "A process is still running in {s}. Closing that tab will terminate it, and undo is off.", .{tab})
    else
        std.fmt.allocPrint(alloc, "Processes are still running in {d} terminals in {s}. Closing that tab will terminate them, and undo is off.", .{ count, tab });
}

test "a program's clipboard prompt names its tab and cannot be reordered by its title" {
    const alloc = std.testing.allocator;

    const read = try buildProgramClipboardPromptBody(alloc, .read, 2, "vim");
    defer alloc.free(read);
    try std.testing.expectEqualStrings("Tab 2 (vim) asked to read your clipboard. Allow sends it the text below.", read);

    const write = try buildProgramClipboardPromptBody(alloc, .write, 1, null);
    defer alloc.free(write);
    try std.testing.expectEqualStrings("Tab 1 (noctty) asked to replace your clipboard with the text below.", write);

    const long = try buildProgramClipboardPromptBody(alloc, .read, 3, "\u{202E}abcdefghijklmnopqrstuvwxyz0123456789");
    defer alloc.free(long);
    try std.testing.expectEqualStrings(
        "Tab 3 (\u{FFFD}abcdefghijklmnopqrst...) asked to read your clipboard. Allow sends it the text below.",
        long,
    );

    // Marks that take no cell are cut by count.
    const marks = "x" ++ "\u{0301}" ** 50;
    const stacked = try buildProgramClipboardPromptBody(alloc, .write, 4, marks);
    defer alloc.free(stacked);
    try std.testing.expectEqualStrings(
        "Tab 4 (x" ++ "\u{0301}" ** 20 ++ "...) asked to replace your clipboard with the text below.",
        stacked,
    );

    const control = try buildProgramClipboardPromptBody(alloc, .read, 5, "a\x1b[2Jb\u{9B}c\u{2028}d");
    defer alloc.free(control);
    try std.testing.expectEqualStrings(
        "Tab 5 (a\u{FFFD}[2Jb\u{FFFD}c\u{FFFD}d) asked to read your clipboard. Allow sends it the text below.",
        control,
    );
}

test "the close prompt for a tab behind the front one names it as the clipboard prompt does" {
    const alloc = std.testing.allocator;
    var title_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Close tab 3?", backgroundTabClosePromptTitle(&title_buf, 3));
    try std.testing.expectEqualStrings("Close terminal in tab 3?", backgroundTerminalClosePromptTitle(&title_buf, 3));

    const one = try buildBackgroundTabClosePromptBody(alloc, 1, 3, "vim");
    defer alloc.free(one);
    try std.testing.expectEqualStrings(
        "A process is still running in Tab 3 (vim). Closing that tab will terminate it, and undo is off.",
        one,
    );

    const many = try buildBackgroundTabClosePromptBody(alloc, 2, 12, null);
    defer alloc.free(many);
    try std.testing.expectEqualStrings(
        "Processes are still running in 2 terminals in Tab 12 (noctty). Closing that tab will terminate them, and undo is off.",
        many,
    );

    const running = try buildBackgroundTerminalClosePromptBody(alloc, 2, "vim", false);
    defer alloc.free(running);
    try std.testing.expectEqualStrings(
        "A process is still running in Tab 2 (vim). Closing that terminal will terminate it.",
        running,
    );
    const exited = try buildBackgroundTerminalClosePromptBody(alloc, 2, "vim", true);
    defer alloc.free(exited);
    try std.testing.expectEqualStrings(
        "The program in Tab 2 (vim) has exited. Read-only mode makes closing that terminal ask first.",
        exited,
    );

    // The title is the program's own text: bounded and stripped the same way.
    const hostile = try buildBackgroundTabClosePromptBody(alloc, 1, 4, "\u{202E}abcdefghijklmnopqrstuvwxyz0123456789");
    defer alloc.free(hostile);
    try std.testing.expectEqualStrings(
        "A process is still running in Tab 4 (\u{FFFD}abcdefghijklmnopqrst...). Closing that tab will terminate it, and undo is off.",
        hostile,
    );
}

/// Render `data` for the confirm preview pane.
///
/// The payload is shown as it is, matching upstream Ghostty's GTK and
/// macOS confirmation dialogs. Three things are replaced with U+FFFD
/// rather than given an invented glyph, each because showing them
/// literally would defeat the pane instead of serving it:
///
///   - Invalid UTF-8. OSC 52 write payloads are base64-decoded bytes
///     from the terminal and need not be text at all; the UTF-16
///     conversion on the way to the control would fail outright and
///     show nothing at all.
///   - NUL. The control takes a NUL-terminated string, so a literal NUL
///     would silently drop the entire remainder of the payload — the
///     opposite of what a preview is for.
///   - Bidirectional formatting characters. They are invisible and
///     reorder what is displayed, so the pane could show a different
///     reading order than the payload has. See `isBidiFormatting`.
///
/// Line endings are normalised to CRLF for display. A Win32 multiline
/// EDIT breaks a line only on CRLF: a lone LF is zero-width and a lone
/// CR is swallowed, so `ls -l<spaces>\nrm -rf ~` would read as one
/// padded command. LF-only payloads are the common case (VS Code on an
/// LF file, anything routed through WSL, OSC 52 writes) and a newline
/// is precisely what `input.paste.isSafe` raises this prompt for, so
/// the pane must not be the one place it becomes invisible. Only the
/// display text changes; `shown_bytes` still counts source bytes.
///
/// Every other control character, DEL included, is passed through.
pub fn buildConfirmPreview(
    alloc: Allocator,
    data: []const u8,
    limit: usize,
) !ConfirmPreview {
    // Back off so the tail is never a split codepoint — but only for a
    // sequence that STARTS before `end` and crosses it.
    //
    // Walking back on every continuation byte at the boundary looks
    // identical for well-formed text and destroys malformed text: a run
    // of orphan continuation bytes there drags `end` back through all of
    // them, and a payload that is nothing but continuation bytes drags it
    // to zero and shows an empty pane. Those bytes are displayable as
    // U+FFFD, and the reported byte count has to match what is shown.
    var end = @min(limit, data.len);
    if (end < data.len and end > 0) {
        // A UTF-8 sequence is at most 4 bytes, so the lead byte is at
        // most 3 positions back from the last included byte.
        var scan = end;
        var steps: usize = 0;
        while (steps < 4 and scan > 0) : (steps += 1) {
            scan -= 1;
            const lead = data[scan];
            if ((lead & 0xC0) == 0x80) continue; // still inside a sequence
            const seq_len = std.unicode.utf8ByteSequenceLength(lead) catch break;
            // Back off only for a sequence that is actually whole and
            // valid in `data`. A malformed lead byte at the boundary is
            // rendered as U+FFFD like any other, instead of dragging
            // `end` back over the bytes before it.
            if (scan + seq_len > end and scan + seq_len <= data.len) {
                _ = std.unicode.utf8Decode(data[scan .. scan + seq_len]) catch break;
                end = scan;
            }
            break;
        }
    }
    const src = data[0..end];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, src.len);

    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        if (b < 0x80) {
            switch (b) {
                0 => try appendCodepoint(alloc, &out, 0xFFFD),
                '\r' => {
                    try out.appendSlice(alloc, "\r\n");
                    // Consume the LF of a CRLF so it is not doubled.
                    if (i + 1 < src.len and src[i + 1] == '\n') i += 1;
                },
                '\n' => try out.appendSlice(alloc, "\r\n"),
                else => try out.append(alloc, b),
            }
            i += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch {
            try appendCodepoint(alloc, &out, 0xFFFD);
            i += 1;
            continue;
        };
        if (i + seq_len > src.len) {
            try appendCodepoint(alloc, &out, 0xFFFD);
            i += 1;
            continue;
        }
        // `utf8Decode` validates as it decodes, so this replaces the
        // separate validity check as well as yielding the codepoint the
        // bidi test needs.
        const cp = std.unicode.utf8Decode(src[i .. i + seq_len]) catch {
            try appendCodepoint(alloc, &out, 0xFFFD);
            i += 1;
            continue;
        };
        if (isBidiFormatting(cp)) {
            try appendCodepoint(alloc, &out, 0xFFFD);
        } else {
            try out.appendSlice(alloc, src[i .. i + seq_len]);
        }
        i += seq_len;
    }

    return .{
        .text = try out.toOwnedSlice(alloc),
        .shown_bytes = end,
        .total_bytes = data.len,
    };
}

/// One-line caption above the preview pane, so the size of what is
/// being approved is visible even when the pane only shows its head.
pub fn buildConfirmPreviewCaption(
    alloc: Allocator,
    preview: ConfirmPreview,
) ![]u8 {
    if (preview.truncated()) {
        return try std.fmt.allocPrint(
            alloc,
            "Showing the first {d} of {d} bytes",
            .{ preview.shown_bytes, preview.total_bytes },
        );
    }
    if (preview.total_bytes == 1) return try alloc.dupe(u8, "1 byte");
    return try std.fmt.allocPrint(alloc, "{d} bytes", .{preview.total_bytes});
}

pub fn buildOverlayPaintLabelText(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    search_total: ?usize,
    search_selected: ?usize,
    host_status: HostTabStatus,
    palette_presentation: PalettePresentation,
    confirm: ?ConfirmText,
) ![]u8 {
    return switch (mode) {
        .none => try alloc.dupe(u8, ""),
        .surface_title => try alloc.dupe(u8, "Window title"),
        .tab_title => try alloc.dupe(u8, "Tab title"),
        .command_palette => try buildCommandPaletteOverlayLabel(
            alloc,
            input_text,
            palette_presentation,
        ),
        .profile => try alloc.dupe(u8, "Profile"),
        .search => try buildSearchOverlayLabel(alloc, search_total, search_selected),
        .tab_overview => try buildTabOverviewOverlayLabel(alloc, host_status.index, host_status.total),
        // Confirm overlays take their prompt title from the payload.
        // The placeholder only appears when the payload has already
        // been dropped (mid-teardown).
        .confirm => if (confirm) |text|
            try alloc.dupe(u8, text.title)
        else
            try alloc.dupe(u8, "Confirm"),
    };
}

pub fn buildOverlayFeedbackText(
    alloc: Allocator,
    banner_kind: HostBannerKind,
    banner_text: ?[]const u8,
    mode: HostOverlayMode,
    input_text: []const u8,
    active_search_needle: ?[]const u8,
    search_total: ?usize,
    search_selected: ?usize,
    host_status: HostTabStatus,
    pane_count: usize,
    palette: PaletteSnapshot,
    mru: []const []const u8,
    palette_presentation: PalettePresentation,
    confirm: ?ConfirmText,
) ![]u8 {
    if (mode == .confirm) return try buildConfirmBodyText(alloc, banner_kind, banner_text, confirm);
    if (banner_text) |value| {
        return switch (banner_kind) {
            .err => try std.fmt.allocPrint(alloc, "Error: {s}", .{value}),
            .info => try std.fmt.allocPrint(alloc, "Info: {s}", .{value}),
            .none => try alloc.dupe(u8, value),
        };
    }
    if (mode == .command_palette) {
        return try buildCommandPaletteFeedbackText(
            alloc,
            input_text,
            mru,
            palette_presentation,
        );
    }
    return try buildOverlayHintText(
        alloc,
        mode,
        input_text,
        active_search_needle,
        search_total,
        search_selected,
        host_status,
        pane_count,
        palette,
        mru,
        confirm,
    );
}

/// The confirm prompt's body line: the payload body plus its preview
/// caption, or a live banner when one overrides it.
///
/// Both renderers of that line go through here. Chrome paint reaches it
/// via `buildOverlayFeedbackText`; the body STATIC that carries the line
/// for UI Automation calls it directly. Two independent spellings would
/// let the name a screen reader reports drift from the text on screen,
/// which is the failure this whole path exists to avoid.
pub fn buildConfirmBodyText(
    alloc: Allocator,
    banner_kind: HostBannerKind,
    banner_text: ?[]const u8,
    confirm: ?ConfirmText,
) ![]u8 {
    if (banner_text) |value| return try buildHostBannerText(alloc, banner_kind, value);
    return try buildOverlayHintText(
        alloc,
        .confirm,
        "",
        null,
        null,
        null,
        .{},
        1,
        .{ .commands = &.{}, .cvals = &.{} },
        &.{},
        confirm,
    );
}

pub fn buildOverlayAcceptLabel(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    active_search_needle: ?[]const u8,
    search_total: ?usize,
    search_selected: ?usize,
    palette_presentation: PalettePresentation,
) ![]u8 {
    return switch (mode) {
        .none => try alloc.dupe(u8, "OK"),
        .command_palette => blk: {
            if (input_text.len == 0) break :blk try alloc.dupe(u8, "Close");
            if (palette_presentation.match_count > 0 and !palette_presentation.available) {
                break :blk try alloc.dupe(u8, "Resize");
            }
            if (palette_presentation.match_count > 0) break :blk try alloc.dupe(u8, "Activate");
            break :blk try alloc.dupe(u8, "Check");
        },
        .profile => try alloc.dupe(u8, "Open"),
        .search => blk: {
            if (input_text.len == 0) break :blk try alloc.dupe(u8, "Close");
            if (active_search_needle) |needle| {
                if (std.mem.eql(u8, needle, input_text) and search_selected != null and search_total != null) {
                    break :blk try alloc.dupe(u8, "Next");
                }
            }
            if (search_total != null) break :blk try alloc.dupe(u8, "Find");
            break :blk try alloc.dupe(u8, "Find");
        },
        .surface_title, .tab_title => if (input_text.len == 0)
            try alloc.dupe(u8, "Close")
        else
            try alloc.dupe(u8, "Apply"),
        .tab_overview => if (input_text.len == 0)
            try alloc.dupe(u8, "Close")
        else
            try alloc.dupe(u8, "Go"),
        // Confirm overlays source accept/cancel labels from the
        // payload. This default is never visible because
        // `syncOverlayButtons` has a special-case branch for the
        // `.confirm` mode that reads the payload directly; the
        // switch just needs coverage to compile.
        .confirm => try alloc.dupe(u8, "OK"),
    };
}

pub fn buildOverlayHintText(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    active_search_needle: ?[]const u8,
    search_total: ?usize,
    search_selected: ?usize,
    host_status: HostTabStatus,
    pane_count: usize,
    palette: PaletteSnapshot,
    mru: []const []const u8,
    confirm: ?ConfirmText,
) ![]u8 {
    return switch (mode) {
        .none => try alloc.dupe(u8, ""),
        .command_palette => blk: {
            if (try commandPaletteBannerText(alloc, palette, input_text, mru)) |text| break :blk text;
            break :blk try alloc.dupe(u8, "No matching action. Try: new_tab, start_search, reload_config");
        },
        .profile => try alloc.dupe(u8, "Choose a profile by number or name. Enter opens a new tab."),
        .search => blk: {
            if (input_text.len == 0) break :blk try alloc.dupe(u8, "Type to search live. Enter repeats the current match. Escape closes.");
            if (search_selected) |selected| {
                if (search_total) |total| {
                    if (active_search_needle) |needle| {
                        if (std.mem.eql(u8, needle, input_text)) {
                            break :blk try std.fmt.allocPrint(
                                alloc,
                                "Live matches {d}/{d}. Enter jumps to the next match. Escape closes.",
                                .{ selected, total },
                            );
                        }
                    }
                    break :blk try std.fmt.allocPrint(
                        alloc,
                        "Live matches {d}/{d}. Enter keeps this needle active.",
                        .{ selected, total },
                    );
                }
            }
            if (search_total) |total| {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Live matches {d}. Enter keeps this needle active.",
                    .{total},
                );
            }
            break :blk try alloc.dupe(u8, "No matches yet. Keep typing to search live.");
        },
        .surface_title => try alloc.dupe(u8, "Apply a window title override for this host. Submit empty text to clear it."),
        .tab_title => blk: {
            if (pane_count > 1) {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Rename tab {d}/{d}. This tab currently has {d} panes. Submit empty text to clear the override.",
                    .{ host_status.index + 1, host_status.total, pane_count },
                );
            }
            break :blk try std.fmt.allocPrint(
                alloc,
                "Rename tab {d}/{d}. Submit empty text to clear the override.",
                .{ host_status.index + 1, host_status.total },
            );
        },
        .tab_overview => blk: {
            if (host_status.total <= 1) break :blk try alloc.dupe(u8, "Only one tab is open in this window.");
            if (input_text.len == 0) {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Jump directly to a tab number. Current tab: {d}/{d}.",
                    .{ host_status.index + 1, host_status.total },
                );
            }
            const requested = std.fmt.parseUnsigned(usize, input_text, 10) catch {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Enter a tab number from 1 to {d}. Current tab: {d}/{d}.",
                    .{ host_status.total, host_status.index + 1, host_status.total },
                );
            };
            if (requested == 0 or requested > host_status.total) {
                break :blk try std.fmt.allocPrint(
                    alloc,
                    "Tab {d} is out of range. Valid range: 1 to {d}.",
                    .{ requested, host_status.total },
                );
            }
            break :blk try std.fmt.allocPrint(
                alloc,
                "Jump to tab {d} of {d}.",
                .{ requested, host_status.total },
            );
        },
        // Confirm overlays take their body line from the payload. The
        // empty placeholder only appears when the payload has already
        // been dropped (mid-teardown).
        .confirm => if (confirm) |text|
            if (text.preview_caption.len == 0)
                try alloc.dupe(u8, text.body)
            else
                try std.fmt.allocPrint(
                    alloc,
                    "{s}  ({s})",
                    .{ text.body, text.preview_caption },
                )
        else
            try alloc.dupe(u8, ""),
    };
}

pub fn overlayCancelLabel(mode: HostOverlayMode) []const u8 {
    return switch (mode) {
        .none => "Cancel",
        .command_palette, .profile, .search, .tab_overview => "Close",
        .surface_title, .tab_title => "Cancel",
        // Confirm overlays override this via the payload.
        .confirm => "Cancel",
    };
}

pub fn buildHostBannerText(
    alloc: Allocator,
    banner_kind: HostBannerKind,
    value: []const u8,
) ![]u8 {
    return switch (banner_kind) {
        .none => try alloc.dupe(u8, value),
        .info => try std.fmt.allocPrint(alloc, "Info: {s}", .{value}),
        .err => try std.fmt.allocPrint(alloc, "Error: {s}", .{value}),
    };
}

/// Look up the Command.description for a given formatted action string.
/// Returns null if no entry matches or the description is empty.
fn commandPaletteDescriptionFor(snap: PaletteSnapshot, action_text: []const u8) ?[]const u8 {
    for (snap.commands, snap.cvals) |cmd, cval| {
        const action = std.mem.span(cval.action);
        if (!std.mem.eql(u8, action, action_text)) continue;
        const desc: []const u8 = cmd.description;
        return if (desc.len == 0) null else desc;
    }
    return null;
}

pub fn buildCommandPaletteOverlayLabel(
    alloc: Allocator,
    input_text: []const u8,
    presentation: PalettePresentation,
) ![]u8 {
    if (input_text.len == 0) return try alloc.dupe(u8, "Command");
    if (presentation.match_count > 0) {
        return try std.fmt.allocPrint(alloc, "Command {d}", .{presentation.match_count});
    }
    return try alloc.dupe(u8, "Command ?");
}

pub fn buildCommandPaletteFeedbackText(
    alloc: Allocator,
    input_text: []const u8,
    mru: []const []const u8,
    presentation: PalettePresentation,
) ![]u8 {
    if (input_text.len == 0) {
        if (mru.len > 0) {
            return try std.fmt.allocPrint(
                alloc,
                "Recent: {s}. Type to search actions, themes, tabs, panes, settings, and help.",
                .{mru[0]},
            );
        }
        return try alloc.dupe(
            u8,
            "Type to search actions, themes, tabs, panes, settings, and help.",
        );
    }
    if (presentation.match_count == 0) {
        return try alloc.dupe(
            u8,
            "No matching command. Try > actions, % themes, @ tabs, / panes, : settings, or ? help.",
        );
    }
    if (!presentation.available) {
        return try std.fmt.allocPrint(
            alloc,
            "{d} matches. Make the window larger to show and activate results.",
            .{presentation.match_count},
        );
    }

    const title = presentation.title orelse "Selected result";
    const subtitle = presentation.subtitle orelse "";
    if (presentation.match_count == 1) {
        if (subtitle.len > 0) {
            return try std.fmt.allocPrint(
                alloc,
                "{s} — {s}{s} Enter activates; Escape closes.",
                .{ title, subtitle, sentenceStop(subtitle) },
            );
        }
        return try std.fmt.allocPrint(
            alloc,
            "{s}. Enter activates; Escape closes.",
            .{title},
        );
    }
    if (subtitle.len > 0) {
        return try std.fmt.allocPrint(
            alloc,
            "{d} matches. Selected: {s} — {s}{s} Up/Down selects; Enter activates.",
            .{ presentation.match_count, title, subtitle, sentenceStop(subtitle) },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "{d} matches. Selected: {s}. Up/Down selects; Enter activates.",
        .{ presentation.match_count, title },
    );
}

/// The full stop to put after a fragment that is spliced into a sentence.
/// Command descriptions are prose ("Open the config file.") while theme
/// and setting subtitles are labels ("Bundled theme"); appending a period
/// to both produced "Open the config file.." in the hint line.
fn sentenceStop(text: []const u8) []const u8 {
    if (text.len == 0) return ".";
    return switch (text[text.len - 1]) {
        '.', '!', '?' => "",
        else => ".",
    };
}

test "win32 command palette feedback does not double a description's full stop" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const prose = try buildCommandPaletteFeedbackText(
        std.testing.allocator,
        "open",
        &.{},
        .{ .match_count = 3, .title = "Open Config", .subtitle = "Open the config file.", .available = true },
    );
    defer std.testing.allocator.free(prose);
    try std.testing.expectEqualStrings(
        "3 matches. Selected: Open Config — Open the config file. Up/Down selects; Enter activates.",
        prose,
    );

    const label = try buildCommandPaletteFeedbackText(
        std.testing.allocator,
        "0x96f",
        &.{},
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    );
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("0x96f — Bundled theme. Enter activates; Escape closes.", label);
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

pub fn commandPaletteBannerText(
    alloc: Allocator,
    snap: PaletteSnapshot,
    input_text: []const u8,
    mru: []const []const u8,
) !?[]u8 {
    if (input_text.len == 0) {
        if (mru.len == 0) {
            return try alloc.dupe(u8, "Try: new_tab (new tab), start_search (find), toggle_tab_overview (tab list)");
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);
        try buf.appendSlice(alloc, "Recent: ");
        const visible = @min(mru.len, 5);
        for (mru[0..visible], 0..) |action, i| {
            if (i > 0) try buf.appendSlice(alloc, ", ");
            try buf.appendSlice(alloc, action);
        }
        return try buf.toOwnedSlice(alloc);
    }

    if (input.Binding.Action.parse(input_text)) |_| {
        if (commandPaletteDescriptionFor(snap, input_text)) |summary| {
            return try std.fmt.allocPrint(alloc, "Ready: {s} - {s}", .{ input_text, summary });
        }
        return try std.fmt.allocPrint(alloc, "Ready to run: {s}", .{input_text});
    } else |_| {}

    // Cap visible matches to keep the banner readable. With ~90
    // entries a bare query like "t" can rank dozens of matches;
    // showing all of them produces a wall of text.
    const max_visible: usize = 5;
    var ranked_buf: [palette_max_ranked]RankedIndex = undefined;
    const ranked = rankedIndicesForQuery(snap, input_text, &ranked_buf);
    if (ranked.len == 0) return null;

    // Single match → "Ready: {action} - {description}" so Enter
    // telegraphs what it'll run. Multi-match falls through to the
    // "Matches: …" list so the user sees the candidate set.
    if (ranked.len == 1) {
        const action = std.mem.span(snap.cvals[ranked[0].index].action);
        if (commandPaletteDescriptionFor(snap, action)) |summary| {
            return try std.fmt.allocPrint(alloc, "Ready: {s} - {s}", .{ action, summary });
        }
        return try std.fmt.allocPrint(alloc, "Ready to run: {s}", .{action});
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "Matches: ");
    const visible_len = @min(ranked.len, max_visible);
    for (ranked[0..visible_len], 0..) |r, i| {
        const action = std.mem.span(snap.cvals[r.index].action);
        if (i > 0) try buf.appendSlice(alloc, ", ");
        try buf.appendSlice(alloc, action);
        if (commandPaletteDescriptionFor(snap, action)) |summary| {
            try buf.appendSlice(alloc, " (");
            try buf.appendSlice(alloc, summary);
            try buf.appendSlice(alloc, ")");
        }
    }
    if (ranked.len > visible_len) {
        const rest = ranked.len - visible_len;
        try std.fmt.format(buf.writer(alloc), " + {d} more", .{rest});
    }
    return try buf.toOwnedSlice(alloc);
}

pub fn overlayPaintCacheDirty(
    overlay_text_dirty: bool,
    overlay_mode: HostOverlayMode,
    cached_label_w: ?[:0]const u16,
    cached_feedback_w: ?[:0]const u16,
    cached_badge_w: ?[:0]const u16,
) bool {
    return win32_chrome_state.overlayPaintCacheDirty(
        overlay_text_dirty,
        overlay_mode,
        cached_label_w != null,
        cached_feedback_w != null,
        cached_badge_w != null,
    );
}

pub fn buildInspectorPanelTitleText(
    alloc: Allocator,
    host: HostTabStatus,
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

fn profileKindBadge(kind: windows_shell.ProfileKind) []const u8 {
    return switch (kind) {
        .wsl_default, .wsl_distro => "WSL",
        .pwsh => "PWSH",
        .powershell => "PS",
        .git_bash => "GIT",
        .cmd => "CMD",
        .ssh => "SSH",
    };
}

fn profileKindGlyph(kind: windows_shell.ProfileKind) []const u8 {
    return switch (kind) {
        .wsl_default, .wsl_distro => "<>",
        .pwsh => ">>",
        .powershell => ">_",
        .git_bash => "$>",
        .cmd => "C>",
        // Distinct from WSL's "<>": this is the one kind that opens a network
        // session, so it should not share another kind's cue.
        .ssh => "->",
    };
}

pub fn buildProfileChromeBadgeText(alloc: Allocator, kind: windows_shell.ProfileKind) ![]u8 {
    return try std.fmt.allocPrint(alloc, "{s} {s}", .{
        profileKindBadge(kind),
        profileKindGlyph(kind),
    });
}

fn profileOpenTargetActionText(target: ProfileOpenTarget) []const u8 {
    return switch (target) {
        .tab => "new tab",
        .window => "new window",
        .split => "split",
    };
}

pub fn buildDropdownProfileLabel(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    index: usize,
) ![]u8 {
    if (index < 9) {
        return try std.fmt.allocPrint(alloc, "{s}\tCtrl+Shift+{d}", .{ profile.label, index + 1 });
    }
    return try alloc.dupe(u8, profile.label);
}

fn targetButtonLabelRightInset(target: ?ProfileOpenTarget) i32 {
    return if (target != null) 12 else 0;
}

pub fn buttonLabelRightInset(pinned_slot_ordinal: ?usize, target: ?ProfileOpenTarget) i32 {
    const slot_inset: i32 = if (pinnedSlotBadgeDigit(pinned_slot_ordinal) != null) 16 else 0;
    return @max(targetButtonLabelRightInset(target), slot_inset);
}

pub fn pinnedSlotBadgeDigit(pinned_slot_ordinal: ?usize) ?u8 {
    const ordinal = pinned_slot_ordinal orelse return null;
    if (ordinal >= 9) return null;
    return @as(u8, @intCast('1' + ordinal));
}

pub fn profileOpenTargetMarkerColor(target: ProfileOpenTarget) u32 {
    return switch (target) {
        .tab => rgb(132, 172, 238),
        .window => rgb(236, 182, 118),
        .split => rgb(126, 204, 148),
    };
}

pub fn profileOpenTargetBadgeGlyph(target: ProfileOpenTarget) u8 {
    return switch (target) {
        .tab => 'T',
        .window => 'W',
        .split => 'S',
    };
}

fn buildProfileCommandPreviewText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    max_width: usize,
) ![]u8 {
    const command = try profile.command.string(alloc);
    defer alloc.free(command);
    return try compactHostLabel(alloc, command, max_width);
}

fn buildProfileQuickPickText(
    alloc: Allocator,
    profiles: []const windows_shell.Profile,
    max_items: usize,
    max_label_len: usize,
) !?[]u8 {
    if (profiles.len == 0 or max_items == 0) return null;

    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(alloc);

    const limit = @min(@min(max_items, profiles.len), 9);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const badge = try buildProfileChromeBadgeText(alloc, profiles[index].kind);
        defer alloc.free(badge);
        const label = try compactHostLabel(alloc, profiles[index].label, max_label_len);
        defer alloc.free(label);

        if (parts.items.len > 0) try parts.appendSlice(alloc, " | ");
        const item = try std.fmt.allocPrint(alloc, "{d} {s} {s}", .{
            index + 1,
            badge,
            label,
        });
        defer alloc.free(item);
        try parts.appendSlice(alloc, item);
    }

    if (limit < profiles.len) try parts.appendSlice(alloc, " | ...");
    return try parts.toOwnedSlice(alloc);
}

pub fn buildProfileOverlayLabel(
    alloc: Allocator,
    profiles: []const windows_shell.Profile,
    input_text: []const u8,
    selected_index: usize,
) ![]u8 {
    if (profiles.len == 0) return try alloc.dupe(u8, "Profile");
    return switch (resolveProfileSelection(profiles, input_text, selected_index)) {
        .exact => |index| blk: {
            const badge = try buildProfileChromeBadgeText(alloc, profiles[index].kind);
            defer alloc.free(badge);
            break :blk try std.fmt.allocPrint(
                alloc,
                "Profile {d}/{d} {s}",
                .{ index + 1, profiles.len, badge },
            );
        },
        .ambiguous => |count| try std.fmt.allocPrint(alloc, "Profile {d}", .{count}),
        .invalid => try alloc.dupe(u8, "Profile ?"),
    };
}

pub fn buildProfileAcceptLabel(
    alloc: Allocator,
    profiles_opt: ?[]const windows_shell.Profile,
    input_text: []const u8,
    selected_index: usize,
    default_target: ProfileOpenTarget,
) ![]u8 {
    const profiles = profiles_opt orelse return try alloc.dupe(u8, "Check");
    if (profiles.len == 0) return try alloc.dupe(u8, "Check");
    return switch (resolveProfileSelection(profiles, input_text, selected_index)) {
        .exact => switch (default_target) {
            .tab => try alloc.dupe(u8, "Open Tab"),
            .window => try alloc.dupe(u8, "Open Win"),
            .split => try alloc.dupe(u8, "Split"),
        },
        .ambiguous => try alloc.dupe(u8, "Pick"),
        .invalid => try alloc.dupe(u8, "Check"),
    };
}

pub fn buildProfileHintText(
    alloc: Allocator,
    profiles_opt: ?[]const windows_shell.Profile,
    input_text: []const u8,
    selected_index: usize,
    default_target: ProfileOpenTarget,
    pinned_slot_keys: [3]?[:0]const u8,
) ![]u8 {
    const profiles = profiles_opt orelse return try alloc.dupe(u8, "No supported Windows profiles detected.");
    if (profiles.len == 0) return try alloc.dupe(u8, "No supported Windows profiles detected.");
    const quick_picks = try buildProfileQuickPickText(alloc, profiles, 4, 10);
    defer if (quick_picks) |value| alloc.free(value);
    const quick_suffix = if (quick_picks) |value|
        try std.fmt.allocPrint(alloc, " Quick picks: {s}.", .{value})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(quick_suffix);
    return switch (resolveProfileSelection(profiles, input_text, selected_index)) {
        .exact => |index| blk: {
            const preview = try buildProfileCommandPreviewText(alloc, &profiles[index], 36);
            defer alloc.free(preview);
            const badge = try buildProfileChromeBadgeText(alloc, profiles[index].kind);
            defer alloc.free(badge);
            const pinned_slot = try buildPinnedProfileSlotText(
                alloc,
                findLauncherQuickSlotOrdinal(pinned_slot_keys, profiles[index].key),
            );
            defer alloc.free(pinned_slot);
            break :blk try std.fmt.allocPrint(
                alloc,
                "{s} {s} | key {s} | run {s}.{s} Enter opens a {s}. Ctrl+Enter splits here. Shift+Enter opens a new window. Ctrl+1-9 launches directly. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
                .{
                    badge,
                    profiles[index].label,
                    profiles[index].key,
                    preview,
                    pinned_slot,
                    profileOpenTargetActionText(default_target),
                    quick_suffix,
                },
            );
        },
        .ambiguous => |count| try std.fmt.allocPrint(
            alloc,
            "{d} profiles match. Keep typing a name or use Up/Down to cycle the current selection. Ctrl+1-9 launches directly. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
            .{ count, quick_suffix },
        ),
        .invalid => try std.fmt.allocPrint(
            alloc,
            "No matching profile. Try 1-{d} or a profile name like pwsh, ubuntu, git, or cmd. Ctrl+1-9 launches directly. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning. Space keeps the picker open.{s}",
            .{ profiles.len, quick_suffix },
        ),
    };
}

fn buildPinnedProfileSlotText(alloc: Allocator, pinned_slot_ordinal: ?usize) ![]u8 {
    if (pinned_slot_ordinal) |ordinal| {
        return try std.fmt.allocPrint(alloc, " Pinned slot {d}.", .{ordinal + 1});
    }
    return try alloc.dupe(u8, "");
}

pub fn findLauncherQuickSlotOrdinal(slot_keys: [3]?[:0]const u8, key: []const u8) ?usize {
    for (slot_keys, 0..) |slot_key, index| {
        if (slot_key) |value| {
            if (storedProfileKeyEquals(value, key)) return index;
        }
    }
    return null;
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

test "win32 profileIndexByKey finds launch profile key" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var profiles = [_]windows_shell.Profile{
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .shell = "cmd.exe" },
        },
        .{
            .kind = .wsl_distro,
            .key = "wsl:Ubuntu",
            .label = "Ubuntu",
            .command = .{ .shell = "wsl.exe" },
        },
        .{
            .kind = .ssh,
            .key = "ssh:PROD",
            .label = "SSH: PROD",
            .command = .{ .shell = "ssh.exe PROD" },
        },
        .{
            .kind = .ssh,
            .key = "ssh:prod",
            .label = "SSH: prod",
            .command = .{ .shell = "ssh.exe prod" },
        },
    };

    try std.testing.expectEqual(@as(?usize, 1), profileIndexByKey(&profiles, "wsl:Ubuntu"));
    try std.testing.expectEqual(@as(?usize, 1), profileIndexByKey(&profiles, "WSL:UBUNTU"));
    try std.testing.expectEqual(@as(?usize, 2), profileIndexByKey(&profiles, "ssh:PROD"));
    try std.testing.expectEqual(@as(?usize, 3), profileIndexByKey(&profiles, "ssh:prod"));
    try std.testing.expectEqual(@as(?usize, null), profileIndexByKey(&profiles, "SSH:prod"));
    try std.testing.expectEqual(@as(?usize, null), profileIndexByKey(&profiles, "missing"));
}

test "win32 resolveWindowBaseTitle prefers tab then surface override" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings(
        "tab",
        resolveWindowBaseTitle("terminal", "surface", "tab").?,
    );
    try std.testing.expectEqualStrings(
        "surface",
        resolveWindowBaseTitle("terminal", "surface", null).?,
    );
    try std.testing.expectEqualStrings(
        "terminal",
        resolveWindowBaseTitle("terminal", null, null).?,
    );
}

test "win32 effectiveBackgroundOpacity respects opaque override" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(f64, 0.4), effectiveBackgroundOpacity(0.4, false));
    try std.testing.expectEqual(@as(f64, 1.0), effectiveBackgroundOpacity(0.4, true));
    try std.testing.expectEqual(@as(u8, 128), alphaByteForOpacity(0.5));
}

test "win32 resizeSplitFallbackDelta maps directions to window deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualDeep(
        ResizeSplitFallbackDelta{ .width = -24, .height = 0 },
        resizeSplitFallbackDelta(.{ .amount = 24, .direction = .left }),
    );
    try std.testing.expectEqualDeep(
        ResizeSplitFallbackDelta{ .width = 0, .height = 12 },
        resizeSplitFallbackDelta(.{ .amount = 12, .direction = .down }),
    );
}

test "win32 nextInspectorVisible follows requested mode" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(nextInspectorVisible(false, .toggle));
    try std.testing.expect(!nextInspectorVisible(true, .toggle));
    try std.testing.expect(nextInspectorVisible(false, .show));
    try std.testing.expect(!nextInspectorVisible(true, .hide));
}

test "win32 tab inspector toggle hides any active pane inspector" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(nextTabInspectorVisible(false, .toggle));
    try std.testing.expect(!nextTabInspectorVisible(true, .toggle));
    try std.testing.expect(nextTabInspectorVisible(true, .show));
    try std.testing.expect(!nextTabInspectorVisible(false, .hide));
}

test "win32 buildHostAwareBaseTitle prefixes host tab position" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const titled = try buildHostAwareBaseTitle(std.testing.allocator, "pwsh", .{
        .index = 1,
        .total = 3,
    }, false);
    defer std.testing.allocator.free(titled);
    try std.testing.expectEqualStrings("[2/3] pwsh", titled);

    const single = try buildHostAwareBaseTitle(std.testing.allocator, "pwsh", .{
        .index = 0,
        .total = 1,
    }, false);
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("pwsh", single);
}

test "win32 elevated host title prefixes surface and default title once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const surface = try buildHostAwareBaseTitle(std.testing.allocator, "pwsh", .{
        .index = 1,
        .total = 3,
    }, true);
    defer std.testing.allocator.free(surface);
    try std.testing.expectEqualStrings("Administrator: [2/3] pwsh", surface);

    const default = try buildHostAwareBaseTitle(std.testing.allocator, null, .{
        .index = 0,
        .total = 1,
    }, true);
    defer std.testing.allocator.free(default);
    try std.testing.expectEqualStrings("Administrator: noctty", default);

    const idempotent = try buildHostAwareBaseTitle(std.testing.allocator, "Administrator: pwsh", .{
        .index = 1,
        .total = 3,
    }, true);
    defer std.testing.allocator.free(idempotent);
    try std.testing.expectEqualStrings("Administrator: [2/3] pwsh", idempotent);
}

test "win32 buildTabButtonLabel marks active tab and pane count" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "pwsh", 1, true, 3, 24, true);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("* 2: pwsh (3)", title);
}

test "win32 buildTabButtonLabel omits pane count for single pane tabs" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "pwsh", 0, false, 1, 24, false);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("1: pwsh", title);
}

test "win32 buildTabButtonLabel compacts long titles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "this-is-a-very-long-terminal-title", 0, false, 1, 24, false);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("1: this-is-a-very-lon...", title);
}

test "win32 compactHostLabel keeps the cut on a codepoint boundary" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Three-byte codepoints: a byte-wise cut inside the budget would land on
    // a continuation byte and fail the later UTF-16 conversion.
    const label = try compactHostLabel(std.testing.allocator, "\u{3042}\u{3044}\u{3046}\u{3048}\u{304a}", 6);
    defer std.testing.allocator.free(label);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    try std.testing.expectEqualStrings("\u{3042}...", label);
}

test "win32 compactHostLabel spends the budget in cells, not bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Twelve kana are 36 bytes but 24 cells, so the whole title fits the
    // widest tab budget. The byte budget this replaced cut it at the eighth.
    const value = "\u{3042}\u{3044}\u{3046}\u{3048}\u{304a}\u{304b}\u{304d}\u{304f}\u{3051}\u{3053}\u{3055}\u{3057}";
    const label = try compactHostLabel(std.testing.allocator, value, 24);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings(value, label);
}

test "win32 compactHostLabel drops a wide codepoint that straddles the budget" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // A budget of 8 leaves 5 cells ahead of the ellipsis. The third kana would
    // end on cell 6, so it is dropped instead of spilling past the button.
    const label = try compactHostLabel(std.testing.allocator, "\u{3042}\u{3044}\u{3046}\u{3048}\u{304a}", 8);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("\u{3042}\u{3044}...", label);
    try std.testing.expectEqual(@as(usize, 7), displayWidth(label));
}

test "win32 displayWidth counts wide codepoints and mangled bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 2), displayWidth("ab"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\u{3042}\u{3044}"));
    // A truncated three-byte sequence. Each stray byte still costs a cell, so
    // a mangled title cannot escape the budget.
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xe3\x81"));
}

test "win32 buildTabButtonLabel keeps narrow CJK titles valid UTF-8" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(
        std.testing.allocator,
        "\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{30bf}\u{30a4}\u{30c8}\u{30eb}",
        0,
        false,
        1,
        9,
        false,
    );
    defer std.testing.allocator.free(title);
    try std.testing.expect(std.unicode.utf8ValidateSlice(title));
    try std.testing.expectEqualStrings("1: \u{65e5}...", title);
}

test "win32 buildTabButtonLabel drops pane count when tabs are narrow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "logs-and-output-pane", 1, false, 3, 9, false);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("2: log...", title);
}

test "win32 hostLabelIsCompacted tracks what the drawn label hides" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!hostLabelIsCompacted("build", 24));
    // Eight kana are sixteen cells: they fit the widest tab but not the nine a
    // narrow one gets, and that gap is exactly when a tooltip has something to
    // add.
    const kana = "\u{65e5}\u{672c}\u{8a9e}\u{306e}\u{30bf}\u{30a4}\u{30c8}\u{30eb}";
    try std.testing.expect(!hostLabelIsCompacted(kana, 24));
    try std.testing.expect(hostLabelIsCompacted(kana, 9));
}

test "win32 tabButtonTitleBudget charges the label's decorations" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // "* " + "1: " + " (3)" is nine cells the title cannot also spend.
    try std.testing.expectEqual(@as(usize, 15), tabButtonTitleBudget(0, true, 3, 24, true));
    try std.testing.expectEqual(@as(usize, 19), tabButtonTitleBudget(0, true, 3, 24, false));
    try std.testing.expectEqual(@as(usize, 21), tabButtonTitleBudget(1, false, 1, 24, false));
    // A button too narrow for its own decorations still shows an ellipsis.
    try std.testing.expectEqual(@as(usize, 3), tabButtonTitleBudget(0, true, 3, 6, true));

    // The decorated label stays inside the button either way; it used to run
    // up to nine cells past it.
    const long = "a" ** 40;
    for ([_]bool{ true, false }) |active| {
        const label = try buildTabButtonLabel(std.testing.allocator, long, 0, active, 3, 24, true);
        defer std.testing.allocator.free(label);
        try std.testing.expect(displayWidth(label) <= 24);
    }
}

test "win32 tab tooltip decision matches for an active tab and its neighbour" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const max_width: usize = 24;
    // Eighteen cells, so the title fits even the active tab's 19-cell budget:
    // nothing is hidden and neither tab has anything to say in a tooltip.
    const fits = "session-alpha-1234";
    const active_label = try buildTabButtonLabel(std.testing.allocator, fits, 0, true, 1, max_width, false);
    defer std.testing.allocator.free(active_label);
    const inactive_label = try buildTabButtonLabel(std.testing.allocator, fits, 1, false, 1, max_width, false);
    defer std.testing.allocator.free(inactive_label);
    try std.testing.expectEqualStrings("* 1: session-alpha-1234", active_label);
    try std.testing.expectEqualStrings("2: session-alpha-1234", inactive_label);
    try std.testing.expect(displayWidth(active_label) <= max_width);
    try std.testing.expect(displayWidth(inactive_label) <= max_width);

    // The gate the tab strip runs: the bare title against the budget it was
    // actually compacted to. Measuring the decorated label against the button
    // budget instead made this pair disagree -- tooltip on the active tab,
    // none on its neighbour, same title.
    const active_budget = tabButtonTitleBudget(0, true, 1, max_width, false);
    const inactive_budget = tabButtonTitleBudget(1, false, 1, max_width, false);
    try std.testing.expectEqual(
        hostLabelIsCompacted(fits, active_budget),
        hostLabelIsCompacted(fits, inactive_budget),
    );
    try std.testing.expect(!hostLabelIsCompacted(fits, active_budget));

    const long = "session-alpha-1234-beta-5678";
    try std.testing.expectEqual(
        hostLabelIsCompacted(long, active_budget),
        hostLabelIsCompacted(long, inactive_budget),
    );
    try std.testing.expect(hostLabelIsCompacted(long, active_budget));
}

test "win32 buildTabItemUiaName keeps the pane count the drawn label shows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2: pwsh (3)", buildTabItemUiaName(&buf, 1, "pwsh", 3).?);
    // One pane is the ordinary case and carries no count, matching the label.
    try std.testing.expectEqualStrings("1: pwsh", buildTabItemUiaName(&buf, 0, "pwsh", 1).?);
    // The name is the full title, not the compacted one the button draws.
    const long = "a" ** 40;
    try std.testing.expectEqualStrings("1: " ++ long, buildTabItemUiaName(&buf, 0, long, 1).?);
    // A title too long for the provider's buffer is refused so the caller can
    // fall back to the drawn label instead of reporting a cut name.
    var tiny: [4]u8 = undefined;
    try std.testing.expect(buildTabItemUiaName(&tiny, 0, "pwsh", 1) == null);
}

test "win32 tabItemUiaNameChanged tracks a split the drawn label hides" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title: [:0]const u8 = "pwsh";
    // Splitting a narrow tab: `shouldShowPaneCount` keeps the count out of the
    // label, so the drawn text is byte-identical and only this predicate can
    // tell the UIA name moved.
    try std.testing.expect(!shouldShowPaneCount(120, 2, 96));
    const before = try buildTabButtonLabel(std.testing.allocator, title, 0, false, 1, 24, false);
    defer std.testing.allocator.free(before);
    const after = try buildTabButtonLabel(std.testing.allocator, title, 0, false, 2, 24, false);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expect(tabItemUiaNameChanged(title, 0, 1, title, 0, 2));

    // And the predicate agrees with the names themselves.
    var before_buf: [64]u8 = undefined;
    var after_buf: [64]u8 = undefined;
    try std.testing.expect(!std.mem.eql(
        u8,
        buildTabItemUiaName(&before_buf, 0, title, 1).?,
        buildTabItemUiaName(&after_buf, 0, title, 2).?,
    ));

    // Nothing moved: no event, or every layout pass would announce the tab.
    try std.testing.expect(!tabItemUiaNameChanged(title, 0, 1, title, 0, 1));
    // A reorder and a retitle both change the name.
    try std.testing.expect(tabItemUiaNameChanged(title, 0, 1, title, 1, 1));
    try std.testing.expect(tabItemUiaNameChanged(title, 0, 1, "bash", 0, 1));
    // A tab with no title rides on the drawn-label fallback the caller checks.
    try std.testing.expect(!tabItemUiaNameChanged(null, 0, 1, null, 0, 1));
    try std.testing.expect(tabItemUiaNameChanged(null, 0, 1, title, 0, 1));
}

test "win32 buildTabTooltipText keeps a runaway title bounded" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const long = "a" ** 600;
    const text = try buildTabTooltipText(std.testing.allocator, long);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(tab_tooltip_max_width, displayWidth(text));
    try std.testing.expect(std.mem.endsWith(u8, text, "..."));
}

test "CHROME57 tab budgets and overflow use device-independent widths" {
    for ([_]u32{ 96, 144, 192 }) |dpi| {
        const scale = @import("../win32_chrome_state.zig").scaled;
        try std.testing.expectEqualDeep(VisibleTabRange{ .start = 2, .count = 3 }, visibleTabRange(6, 3, scale(324, dpi), dpi));
        try std.testing.expectEqual(@as(usize, 24), hostTabLabelMaxWidth(scale(260, dpi), dpi));
        try std.testing.expectEqual(@as(usize, 9), hostTabLabelMaxWidth(scale(98, dpi), dpi));
        try std.testing.expect(!shouldShowPaneCount(scale(139, dpi), 2, dpi));
        try std.testing.expect(shouldShowPaneCount(scale(140, dpi), 2, dpi));
        try std.testing.expectEqual(@as(usize, 1), visibleTabRange(6, 5, 1, dpi).count);
    }
}

test "win32 hostTabLabelMaxWidth shrinks with narrow tab widths" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 24), hostTabLabelMaxWidth(260, 96));
    try std.testing.expectEqual(@as(usize, 9), hostTabLabelMaxWidth(98, 96));
    try std.testing.expectEqual(@as(usize, 6), hostTabLabelMaxWidth(40, 96));
    try std.testing.expect(shouldShowPaneCount(180, 3, 96));
    try std.testing.expect(!shouldShowPaneCount(120, 3, 96));
}

test "win32 visibleTabRange windows tabs around the active tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 0, .count = 3 }, visibleTabRange(6, 0, 324, 96));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 2, .count = 3 }, visibleTabRange(6, 3, 324, 96));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 3, .count = 3 }, visibleTabRange(6, 5, 324, 96));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 0, .count = 2 }, visibleTabRange(2, 1, 500, 96));
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

test "win32 preferredProfileIndex respects host key then app key then hint" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .direct = &.{"cmd.exe"} },
        },
    };

    try std.testing.expectEqual(@as(?usize, 1), preferredProfileIndex(&profiles, "git-bash", null, "cmd", 0));
    try std.testing.expectEqual(@as(?usize, 2), preferredProfileIndex(&profiles, null, "cmd.exe", "pwsh", 0));
    try std.testing.expectEqual(@as(?usize, 0), preferredProfileIndex(&profiles, null, null, "power", 2));
    try std.testing.expectEqual(@as(?usize, null), preferredProfileIndex(&profiles, null, null, "definitely_not_real", 1));
}

test "win32 resolveProfileSelection supports index and prefix matching" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "~" } },
        },
        .{
            .kind = .wsl_distro,
            .key = "Ubuntu-Preview",
            .label = "WSL: Ubuntu Preview",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu-Preview", "~" } },
        },
    };

    try std.testing.expectEqualDeep(ProfileSelection{ .exact = 0 }, resolveProfileSelection(&profiles, "", 0));
    try std.testing.expectEqualDeep(ProfileSelection{ .exact = 1 }, resolveProfileSelection(&profiles, "2", 0));
    try std.testing.expectEqualDeep(ProfileSelection{ .exact = 0 }, resolveProfileSelection(&profiles, "powers", 1));
    try std.testing.expectEqualDeep(ProfileSelection{ .ambiguous = 2 }, resolveProfileSelection(&profiles, "ubu", 0));
    try std.testing.expectEqualDeep(ProfileSelection.invalid, resolveProfileSelection(&profiles, "9", 0));
}

test "win32 buildProfileOverlayLabel and hint reflect selected profile" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .direct = &.{"cmd.exe"} },
        },
    };

    const label = try buildProfileOverlayLabel(std.testing.allocator, &profiles, "cmd", 0);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqualStrings("Profile 2/2 CMD C>", label);

    const hint = try buildProfileHintText(std.testing.allocator, &profiles, "cmd", 0, .window, .{ "pwsh.exe", "cmd.exe", null });
    defer std.testing.allocator.free(hint);
    try std.testing.expect(std.mem.indexOf(u8, hint, "CMD C>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Command Prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "run cmd.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Pinned slot 2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "opens a new window") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Alt+1-3 launches visible slots") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Alt+Shift+1-3 pins the current profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Alt+Shift+0 clears pinning") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Quick picks: 1 PWSH >>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "2 CMD C>") != null);
}

test "win32 buildProfileCommandPreviewText compacts shell command preview" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .wsl_distro,
        .key = "Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "--cd", "~" } },
    };

    const preview = try buildProfileCommandPreviewText(std.testing.allocator, &profile, 14);
    defer std.testing.allocator.free(preview);
    try std.testing.expectEqualStrings("wsl.exe -d ...", preview);
}

test "win32 buildProfileQuickPickText reflects ordered launcher profiles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "wsl:Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
        },
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .direct = &.{"cmd.exe"} },
        },
        .{
            .kind = .powershell,
            .key = "powershell.exe",
            .label = "Windows PowerShell",
            .command = .{ .direct = &.{"powershell.exe"} },
        },
    };

    const quick = (try buildProfileQuickPickText(std.testing.allocator, &profiles, 4, 10)).?;
    defer std.testing.allocator.free(quick);
    try std.testing.expectEqualStrings(
        "1 GIT $> Git Bash | 2 PWSH >> PowerShell | 3 WSL <> WSL: Ub... | 4 CMD C> Command... | ...",
        quick,
    );
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

test "win32 quickSlotProfileIndex skips the selected profile and preserves order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 1), quickSlotProfileIndex(5, 0, 0, 3));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotProfileIndex(5, 0, 1, 3));
    try std.testing.expectEqual(@as(?usize, 3), quickSlotProfileIndex(5, 0, 2, 3));
    try std.testing.expectEqual(@as(?usize, 0), quickSlotProfileIndex(5, 3, 0, 3));
    try std.testing.expectEqual(@as(?usize, 1), quickSlotProfileIndex(5, 3, 1, 3));
    try std.testing.expectEqual(@as(?usize, 2), quickSlotProfileIndex(5, 3, 2, 3));
    try std.testing.expectEqual(@as(?usize, null), quickSlotProfileIndex(1, 0, 0, 3));
}

test "win32 findLauncherQuickSlotOrdinal finds runtime-pinned slots" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), findLauncherQuickSlotOrdinal(.{ "git-bash", "cmd.exe", null }, "git-bash"));
    try std.testing.expectEqual(@as(?usize, 1), findLauncherQuickSlotOrdinal(.{ "git-bash", "cmd.exe", null }, "CMD.EXE"));
    try std.testing.expectEqual(@as(?usize, null), findLauncherQuickSlotOrdinal(.{ "git-bash", "cmd.exe", null }, "pwsh.exe"));
}

test "win32 buildProfileChromeBadgeText adds profile glyph treatment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pwsh = try buildProfileChromeBadgeText(std.testing.allocator, .pwsh);
    defer std.testing.allocator.free(pwsh);
    try std.testing.expectEqualStrings("PWSH >>", pwsh);

    const wsl = try buildProfileChromeBadgeText(std.testing.allocator, .wsl_distro);
    defer std.testing.allocator.free(wsl);
    try std.testing.expectEqualStrings("WSL <>", wsl);
}

test "win32 buildSearchOverlayLabel reflects match counts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildSearchOverlayLabel(std.testing.allocator, 8, 2);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("Find 2/8", active);

    const passive = try buildSearchOverlayLabel(std.testing.allocator, 5, null);
    defer std.testing.allocator.free(passive);
    try std.testing.expectEqualStrings("Find 5", passive);

    const idle = try buildSearchOverlayLabel(std.testing.allocator, null, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Find", idle);
}

test "win32 buildSearchBarResultsText reflects docked search states" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var bar = win32_search_bar.SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    const idle = try buildSearchBarResultsText(std.testing.allocator, &bar);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings(search_results_idle, idle);

    try bar.setQuery("foo", 10);
    const pending = try buildSearchBarResultsText(std.testing.allocator, &bar);
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqualStrings(search_results_pending, pending);

    bar.searched = true;
    bar.total = 0;
    const none = try buildSearchBarResultsText(std.testing.allocator, &bar);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqualStrings(search_results_none, none);

    // An unparsable pattern also reports no matches; it must not read as one.
    bar.invalid = true;
    const invalid = try buildSearchBarResultsText(std.testing.allocator, &bar);
    defer std.testing.allocator.free(invalid);
    try std.testing.expectEqualStrings(search_results_invalid, invalid);
    // The next edit clears it, and the debounce shows "Searching" again.
    try bar.setQuery("foo(", 20);
    const retyped = try buildSearchBarResultsText(std.testing.allocator, &bar);
    defer std.testing.allocator.free(retyped);
    try std.testing.expectEqualStrings(search_results_pending, retyped);
    bar.searched = true;

    bar.total = 12;
    bar.selected = 3;
    const active = try buildSearchBarResultsText(std.testing.allocator, &bar);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("3/12", active);
}

test "win32 showSearchBarResults only shows status chip for non-empty queries" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var bar = win32_search_bar.SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try std.testing.expect(!showSearchBarResults(&bar));
    try bar.setQuery("search-open", 10);
    try std.testing.expect(showSearchBarResults(&bar));
}

test "win32 searchBarNeedsRelayoutForQueryChange only trips on empty-state transitions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!searchBarNeedsRelayoutForQueryChange(0, 0));
    try std.testing.expect(searchBarNeedsRelayoutForQueryChange(0, 1));
    try std.testing.expect(!searchBarNeedsRelayoutForQueryChange(4, 9));
    try std.testing.expect(searchBarNeedsRelayoutForQueryChange(3, 0));
}

test "win32 searchBarShouldInvalidateCoreSearchOnEdit invalidates active query edits" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!searchBarShouldInvalidateCoreSearchOnEdit(0, 0));
    try std.testing.expect(!searchBarShouldInvalidateCoreSearchOnEdit(0, 1));
    try std.testing.expect(searchBarShouldInvalidateCoreSearchOnEdit(5, 2));
    try std.testing.expect(searchBarShouldInvalidateCoreSearchOnEdit(5, 0));
}

test "win32 shouldAcceptCoreSearchUpdates rejects pending docked search state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var bar = win32_search_bar.SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try std.testing.expect(shouldAcceptCoreSearchUpdates(&bar));

    try bar.setQuery("search-open", 10);
    try std.testing.expect(!shouldAcceptCoreSearchUpdates(&bar));

    bar.searched = true;
    try std.testing.expect(shouldAcceptCoreSearchUpdates(&bar));
}

test "win32 searchBarResultsVisual marks no-match state with error colors" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var bar = win32_search_bar.SearchBar.init(std.testing.allocator);
    defer bar.deinit();

    try bar.setQuery("zzzzz", 10);
    bar.searched = true;
    bar.total = 0;

    const theme = darkTheme();
    const visual = searchBarResultsVisual(&theme, &bar);
    try std.testing.expectEqual(theme.error_fg, visual.border);
    try std.testing.expectEqual(theme.error_fg, visual.fg);
}

test "win32 searchBarButtonShowsLabel keeps docked search buttons icon-only" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!searchBarButtonShowsLabel(.prev, 80));
    try std.testing.expect(!searchBarButtonShowsLabel(.close, 80));
    try std.testing.expect(!searchBarButtonShowsLabel(.regex, 40));
    try std.testing.expect(!searchBarButtonShowsLabel(.regex, 64));
    try std.testing.expect(!searchBarButtonShowsLabel(.case_sensitive, 72));
    try std.testing.expect(!searchBarButtonShowsLabel(.whole_word, 80));
}

test "win32 buildTabOverviewOverlayLabel reflects current host tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildTabOverviewOverlayLabel(std.testing.allocator, 1, 4);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("Tab 2/4", multi);

    const single = try buildTabOverviewOverlayLabel(std.testing.allocator, 0, 1);
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("Tab", single);
}

test "win32 buildOverlayPaintLabelText reflects live overlay mode" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const command = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .command_palette,
        "toggle_",
        null,
        null,
        .{},
        .{ .match_count = 4, .title = "Toggle fullscreen", .subtitle = "Fullscreen", .available = true },
        null,
    );
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("Command 4", command);

    const search = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .search,
        "",
        8,
        2,
        .{},
        .{},
        null,
    );
    defer std.testing.allocator.free(search);
    try std.testing.expectEqualStrings("Find 2/8", search);

    const title = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .surface_title,
        "",
        null,
        null,
        .{},
        .{},
        null,
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Window title", title);
}

test "win32 confirm preview passes ordinary text through untouched" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var preview = try buildConfirmPreview(
        std.testing.allocator,
        "echo one\r\necho two\r\n",
        confirm_preview_limit,
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("echo one\r\necho two\r\n", preview.text);
    try std.testing.expectEqual(@as(usize, 20), preview.shown_bytes);
    try std.testing.expectEqual(@as(usize, 20), preview.total_bytes);
    try std.testing.expect(!preview.truncated());
}

test "win32 confirm preview passes control characters through, except NUL" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Upstream's GTK and macOS dialogs show the payload as it is, so BEL,
    // DEL, tab, CR and LF all survive verbatim. NUL cannot: the EDIT takes
    // a NUL-terminated string and would drop everything after it.
    var preview = try buildConfirmPreview(
        std.testing.allocator,
        "a\x00b\x07c\td\x7fe\r\n",
        confirm_preview_limit,
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("a\u{FFFD}b\x07c\td\x7fe\r\n", preview.text);
    try std.testing.expect(std.mem.indexOfScalar(u8, preview.text, 0) == null);
    // The bytes after the NUL must still be there — that is the point.
    try std.testing.expect(std.mem.endsWith(u8, preview.text, "e\r\n"));
}

test "win32 confirm preview replaces invalid UTF-8 rather than failing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // OSC 52 write payloads are base64-decoded bytes from the terminal
    // and need not be text at all. The UTF-16 conversion on the way to
    // the EDIT would reject them and show nothing.
    var preview = try buildConfirmPreview(
        std.testing.allocator,
        "ok\xffbad\xe3\x81",
        confirm_preview_limit,
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ok\u{FFFD}bad\u{FFFD}\u{FFFD}", preview.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview.text));
}

test "win32 confirm preview keeps its prefix when the boundary byte is an orphan" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Regression: backing off on any continuation byte at the boundary
    // threw away valid bytes before it. Here only one byte is excluded,
    // and it is not part of any sequence that starts inside the prefix.
    var preview = try buildConfirmPreview(std.testing.allocator, "aaaaaaaa\x80", 8);
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("aaaaaaaa", preview.text);
    try std.testing.expectEqual(@as(usize, 8), preview.shown_bytes);
    try std.testing.expectEqual(@as(usize, 9), preview.total_bytes);
}

test "win32 confirm preview survives a run of orphan continuation bytes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // The old scan walked back through the whole run, so a payload with
    // a long run at the boundary lost that much displayable content.
    var run = try buildConfirmPreview(std.testing.allocator, "aaaa\x80\x80\x80\x80\x80\x80\x80\x80", 8);
    defer run.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8), run.shown_bytes);
    try std.testing.expectEqualStrings("aaaa\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}", run.text);

    // The pathological case: nothing but continuation bytes used to drag
    // the boundary to zero and show an empty pane.
    var all = try buildConfirmPreview(std.testing.allocator, "\x80" ** 12, 8);
    defer all.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8), all.shown_bytes);
    try std.testing.expectEqual(@as(usize, 12), all.total_bytes);
    try std.testing.expect(all.text.len > 0);
}

test "win32 confirm preview leaves the boundary alone when a sequence ends on it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Three bytes in, three bytes out: the sequence ends exactly at the
    // limit, so there is nothing to back off from.
    var preview = try buildConfirmPreview(std.testing.allocator, "\u{3042}\u{3042}", 3);
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\u{3042}", preview.text);
    try std.testing.expectEqual(@as(usize, 3), preview.shown_bytes);
}

test "win32 confirm preview replaces bidirectional formatting characters" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Trojan Source (CVE-2021-42574): these are invisible and reorder the
    // text around them, so the pane would show a different reading order
    // than the payload actually has.
    var preview = try buildConfirmPreview(
        std.testing.allocator,
        "echo \u{202E}dlrow olleh\u{202C}",
        confirm_preview_limit,
    );
    defer preview.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("echo \u{FFFD}dlrow olleh\u{FFFD}", preview.text);

    const bidi = [_]u21{
        0x061C, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C,
        0x202D, 0x202E, 0x2066,
        0x2067, 0x2068, 0x2069,
    };
    for (bidi) |cp| {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        var one = try buildConfirmPreview(std.testing.allocator, buf[0..len], confirm_preview_limit);
        defer one.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("\u{FFFD}", one.text);
    }

    // Neighbouring codepoints outside the set must survive untouched, or
    // the ranges have been written too wide.
    for ([_]u21{ 0x061B, 0x061D, 0x200D, 0x2010, 0x2029, 0x202F, 0x2065, 0x206A }) |cp| {
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        var one = try buildConfirmPreview(std.testing.allocator, buf[0..len], confirm_preview_limit);
        defer one.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(buf[0..len], one.text);
    }
}

test "win32 searchBarButtonName names every search button distinctly" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Each button's tooltip and UIA name come from here, so every role needs
    // its own non-empty name; two icons sharing a name would defeat the
    // tooltip that exists to tell them apart.
    const roles = std.enums.values(SearchBarButtonRole);
    for (roles, 0..) |role, i| {
        const name = searchBarButtonName(role);
        try std.testing.expect(name.len > 0);
        for (roles[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, name, searchBarButtonName(other)));
        }
    }
    try std.testing.expectEqualStrings("Previous match", searchBarButtonName(.prev));
    try std.testing.expectEqualStrings("Regular expression", searchBarButtonName(.regex));
}

test "win32 overlayEmptySubmitDismisses spares prompts with no query field" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // A confirm's EDIT is hidden and always empty, so dismissing on
    // "empty" would close the prompt without dispatching either callback.
    try std.testing.expect(!overlayEmptySubmitDismisses(.confirm));
    try std.testing.expect(!overlayEmptySubmitDismisses(.search));
    try std.testing.expect(!overlayEmptySubmitDismisses(.profile));
    try std.testing.expect(!overlayEmptySubmitDismisses(.command_palette));

    // These do carry a query field, and an empty one means "cancel".
    try std.testing.expect(overlayEmptySubmitDismisses(.surface_title));
    try std.testing.expect(overlayEmptySubmitDismisses(.tab_title));
    try std.testing.expect(overlayEmptySubmitDismisses(.tab_overview));
    try std.testing.expect(overlayEmptySubmitDismisses(.none));
}

test "win32 overlayTextFollowsActiveSurface covers only the title prompts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Prefilled from the active surface and written back to it on submit.
    try std.testing.expect(overlayTextFollowsActiveSurface(.tab_title));
    try std.testing.expect(overlayTextFollowsActiveSurface(.surface_title));

    // A search query, a profile key or a tab number is what the user is
    // typing, not a property of the tab, so switching tabs keeps it.
    try std.testing.expect(!overlayTextFollowsActiveSurface(.search));
    try std.testing.expect(!overlayTextFollowsActiveSurface(.profile));
    try std.testing.expect(!overlayTextFollowsActiveSurface(.command_palette));
    try std.testing.expect(!overlayTextFollowsActiveSurface(.tab_overview));
    try std.testing.expect(!overlayTextFollowsActiveSurface(.confirm));
    try std.testing.expect(!overlayTextFollowsActiveSurface(.none));
}

test "win32 overlayTextNeedsRefill refills on a tab switch and keeps typing otherwise" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tab_one: u8 = 0;
    var tab_two: u8 = 0;
    const one: *const anyopaque = &tab_one;
    const two: *const anyopaque = &tab_two;

    // The prompt was filled from tab one and tab two became active: refill.
    try std.testing.expect(overlayTextNeedsRefill(.tab_title, one, two));
    try std.testing.expect(overlayTextNeedsRefill(.surface_title, one, two));

    // Still on tab one: a chrome refresh must not replace what was typed.
    try std.testing.expect(!overlayTextNeedsRefill(.tab_title, one, one));

    // Nothing recorded yet (or a failed refill left it unrecorded): fill.
    try std.testing.expect(overlayTextNeedsRefill(.tab_title, null, one));

    // No active surface: nothing to fill from.
    try std.testing.expect(!overlayTextNeedsRefill(.tab_title, one, null));

    // Prompts whose text is the user's own query never refill.
    try std.testing.expect(!overlayTextNeedsRefill(.search, one, two));
    try std.testing.expect(!overlayTextNeedsRefill(.command_palette, one, two));
    try std.testing.expect(!overlayTextNeedsRefill(.tab_overview, one, two));
}

test "win32 confirm preview truncates on a codepoint boundary" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Two 3-byte codepoints, cut at 4 bytes: backing off to 3 keeps the
    // first whole and never emits a split sequence.
    var preview = try buildConfirmPreview(std.testing.allocator, "\u{3042}\u{3042}", 4);
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\u{3042}", preview.text);
    try std.testing.expectEqual(@as(usize, 3), preview.shown_bytes);
    try std.testing.expectEqual(@as(usize, 6), preview.total_bytes);
    try std.testing.expect(preview.truncated());
    try std.testing.expect(std.unicode.utf8ValidateSlice(preview.text));
}

test "win32 confirm preview normalises line endings to CRLF" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // A Win32 EDIT breaks lines only on CRLF. A lone LF renders as
    // nothing and a lone CR is swallowed, which would hide the one
    // structural fact the paste prompt exists to show.
    var preview = try buildConfirmPreview(
        std.testing.allocator,
        "one\ntwo\rthree\r\nfour\n\nfive\r\r\nsix",
        confirm_preview_limit,
    );
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "one\r\ntwo\r\nthree\r\nfour\r\n\r\nfive\r\n\r\nsix",
        preview.text,
    );
    // The caption still counts source bytes, not display bytes.
    try std.testing.expectEqual(@as(usize, 31), preview.shown_bytes);
    try std.testing.expectEqual(@as(usize, 31), preview.total_bytes);
    try std.testing.expect(!preview.truncated());
}

test "win32 confirm preview keeps a malformed lead byte at the boundary" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // A lead byte whose sequence crosses the limit is backed off only
    // when the sequence is whole and valid. A malformed one is shown as
    // U+FFFD instead of dragging the boundary back over the bytes
    // before it -- here all the way to an empty pane.
    var preview = try buildConfirmPreview(std.testing.allocator, "\xE0\x80x", 2);
    defer preview.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD}", preview.text);
    try std.testing.expectEqual(@as(usize, 2), preview.shown_bytes);
    try std.testing.expectEqual(@as(usize, 3), preview.total_bytes);
    try std.testing.expect(preview.truncated());

    // A sequence that is cut by the end of the data itself is malformed
    // too, and likewise must not move the boundary.
    var cut = try buildConfirmPreview(std.testing.allocator, "abc\xE3\x81", 4);
    defer cut.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abc\u{FFFD}", cut.text);
    try std.testing.expectEqual(@as(usize, 4), cut.shown_bytes);
}

test "win32 confirm preview caption reports what is being approved" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const whole = try buildConfirmPreviewCaption(
        std.testing.allocator,
        .{ .text = "", .shown_bytes = 12, .total_bytes = 12 },
    );
    defer std.testing.allocator.free(whole);
    try std.testing.expectEqualStrings("12 bytes", whole);

    const single = try buildConfirmPreviewCaption(
        std.testing.allocator,
        .{ .text = "", .shown_bytes = 1, .total_bytes = 1 },
    );
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("1 byte", single);

    const cut = try buildConfirmPreviewCaption(
        std.testing.allocator,
        .{ .text = "", .shown_bytes = 65536, .total_bytes = 3145728 },
    );
    defer std.testing.allocator.free(cut);
    try std.testing.expectEqualStrings("Showing the first 65536 of 3145728 bytes", cut);
}

test "win32 confirm overlay paints its payload title and body" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};
    const confirm: ConfirmText = .{
        .title = "Allow clipboard paste?",
        .body = "noctty needs confirmation before completing this clipboard paste or read request.",
    };

    const title = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .confirm,
        "",
        null,
        null,
        .{},
        .{},
        confirm,
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Allow clipboard paste?", title);

    const body = try buildOverlayFeedbackText(
        std.testing.allocator,
        .none,
        null,
        .confirm,
        "",
        null,
        null,
        null,
        .{},
        1,
        snap,
        empty_mru,
        .{},
        confirm,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(confirm.body, body);
}

test "win32 confirm overlay states the payload size next to the body" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};

    const body = try buildOverlayFeedbackText(
        std.testing.allocator,
        .none,
        null,
        .confirm,
        "",
        null,
        null,
        null,
        .{},
        1,
        snap,
        empty_mru,
        .{},
        .{
            .title = "Allow clipboard paste?",
            .body = "Confirm this paste.",
            .preview_caption = "Showing the first 65536 of 3145728 bytes",
        },
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "Confirm this paste.  (Showing the first 65536 of 3145728 bytes)",
        body,
    );
}

test "win32 confirm overlay distinguishes the three prompts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Every confirm prompt used to paint the same "Confirm" placeholder,
    // so a close prompt and a clipboard prompt were indistinguishable.
    const prompts = [_]ConfirmText{
        .{ .title = "Close this terminal?", .body = "A process is still running." },
        .{ .title = "Allow clipboard paste?", .body = "Confirm this paste." },
        .{ .title = "Allow clipboard write?", .body = "Confirm this write." },
    };
    for (prompts) |prompt| {
        const title = try buildOverlayPaintLabelText(
            std.testing.allocator,
            .confirm,
            "",
            null,
            null,
            .{},
            .{},
            prompt,
        );
        defer std.testing.allocator.free(title);
        try std.testing.expectEqualStrings(prompt.title, title);
        try std.testing.expect(!std.mem.eql(u8, "Confirm", title));
    }
}

test "win32 confirm overlay falls back once its payload is dropped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};

    // Teardown drops the payload before the last repaint can run, so the
    // placeholders still have to be reachable.
    const title = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .confirm,
        "",
        null,
        null,
        .{},
        .{},
        null,
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Confirm", title);

    const body = try buildOverlayHintText(
        std.testing.allocator,
        .confirm,
        "",
        null,
        null,
        null,
        .{},
        1,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("", body);
}

test "win32 utf8BoundedPrefix never splits a codepoint" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings("abc", utf8BoundedPrefix("abc", 8));
    try std.testing.expectEqualStrings("abc", utf8BoundedPrefix("abc", 3));
    try std.testing.expectEqualStrings("ab", utf8BoundedPrefix("abc", 2));
    try std.testing.expectEqualStrings("", utf8BoundedPrefix("abc", 0));

    // "aé" is 3 bytes; a 2-byte limit lands mid-sequence and has to back
    // off to 1 rather than hand back half a codepoint.
    const accented = "a\u{e9}b";
    try std.testing.expectEqualStrings("a", utf8BoundedPrefix(accented, 2));
    try std.testing.expectEqualStrings("a\u{e9}", utf8BoundedPrefix(accented, 3));

    // A 4-byte sequence, cut at every interior offset.
    const emoji = "x\u{1f600}y";
    try std.testing.expectEqualStrings("x", utf8BoundedPrefix(emoji, 2));
    try std.testing.expectEqualStrings("x", utf8BoundedPrefix(emoji, 3));
    try std.testing.expectEqualStrings("x", utf8BoundedPrefix(emoji, 4));
    try std.testing.expectEqualStrings("x\u{1f600}", utf8BoundedPrefix(emoji, 5));

    // Every result is valid UTF-8, which is what the BSTR conversion needs.
    for (0..emoji.len + 2) |limit| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(utf8BoundedPrefix(emoji, limit)));
    }
}

test "win32 confirm body text is the one the overlay feedback lane draws" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // The confirm body STATIC reports its own window text as its UIA
    // name, and chrome paint is still the fallback renderer for the same
    // line. Both go through `buildConfirmBodyText`; if the two ever
    // diverged a screen reader would narrate something the screen does
    // not say, so pin the delegation rather than the strings.
    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};
    const confirm: ConfirmText = .{
        .title = "Allow clipboard paste?",
        .body = "noctty needs confirmation before completing this clipboard paste or read request.",
        .preview_caption = "3 bytes",
    };

    const cases = [_]struct { kind: HostBannerKind, text: ?[]const u8 }{
        .{ .kind = .none, .text = null },
        .{ .kind = .none, .text = "Plain notice" },
        .{ .kind = .info, .text = "Heads up" },
        .{ .kind = .err, .text = "Something went wrong" },
    };
    for (cases) |case| {
        const direct = try buildConfirmBodyText(
            std.testing.allocator,
            case.kind,
            case.text,
            confirm,
        );
        defer std.testing.allocator.free(direct);
        const painted = try buildOverlayFeedbackText(
            std.testing.allocator,
            case.kind,
            case.text,
            .confirm,
            "",
            null,
            null,
            null,
            .{},
            1,
            snap,
            empty_mru,
            .{},
            confirm,
        );
        defer std.testing.allocator.free(painted);
        try std.testing.expectEqualStrings(painted, direct);
    }

    // No banner: body plus the preview caption, which is how the amount
    // being approved stays visible when the pane only shows its head.
    const plain = try buildConfirmBodyText(std.testing.allocator, .none, null, confirm);
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings(
        "noctty needs confirmation before completing this clipboard paste or read request.  (3 bytes)",
        plain,
    );

    // A banner raised while the prompt is open takes the line, prefix and
    // all, exactly as the painted lane did.
    const banner = try buildConfirmBodyText(std.testing.allocator, .err, "Clipboard unavailable", confirm);
    defer std.testing.allocator.free(banner);
    try std.testing.expectEqualStrings("Error: Clipboard unavailable", banner);

    // Mid-teardown the payload is already gone.
    const dropped = try buildConfirmBodyText(std.testing.allocator, .none, null, null);
    defer std.testing.allocator.free(dropped);
    try std.testing.expectEqualStrings("", dropped);
}

test "win32 confirm overlay keeps banner precedence over the payload body" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};

    const body = try buildOverlayFeedbackText(
        std.testing.allocator,
        .err,
        "Something went wrong",
        .confirm,
        "",
        null,
        null,
        null,
        .{},
        1,
        snap,
        empty_mru,
        .{},
        .{ .title = "Allow clipboard paste?", .body = "Confirm this paste." },
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("Error: Something went wrong", body);
}

test "win32 buildOverlayFeedbackText prefers inline banner state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};

    const info = try buildOverlayFeedbackText(
        std.testing.allocator,
        .info,
        "Try: new_tab",
        .command_palette,
        "",
        null,
        null,
        null,
        .{},
        1,
        snap,
        empty_mru,
        .{},
        null,
    );
    defer std.testing.allocator.free(info);
    try std.testing.expectEqualStrings("Info: Try: new_tab", info);

    const err = try buildOverlayFeedbackText(
        std.testing.allocator,
        .err,
        command_palette_unknown_action,
        .command_palette,
        "",
        null,
        null,
        null,
        .{},
        1,
        snap,
        empty_mru,
        .{},
        null,
    );
    defer std.testing.allocator.free(err);
    try std.testing.expectEqualStrings(
        "Error: Unknown Noctty action. Example: new_tab or toggle_fullscreen",
        err,
    );

    const fallback = try buildOverlayFeedbackText(
        std.testing.allocator,
        .none,
        null,
        .search,
        "needle",
        "needle",
        8,
        2,
        .{},
        1,
        snap,
        empty_mru,
        .{},
        null,
    );
    defer std.testing.allocator.free(fallback);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "next match") != null);
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

test "win32 searchBarSearchedState helpers preserve pending searches on null callbacks" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!searchBarSearchedStateForTotal(null));
    try std.testing.expect(searchBarSearchedStateForTotal(0));

    try std.testing.expect(!searchBarSearchedStateForSelected(null, null));
    try std.testing.expect(searchBarSearchedStateForSelected(null, 5));
    try std.testing.expect(searchBarSearchedStateForSelected(2, null));
}

test "win32 searchBarDisplayStateChanged only trips on visible results changes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const same = win32_search_bar.SearchBar{
        .searched = true,
        .total = 12,
        .selected = 3,
        .alloc = std.testing.allocator,
    };
    try std.testing.expect(!searchBarDisplayStateChanged(&same, true, 12, 3));
    try std.testing.expect(searchBarDisplayStateChanged(&same, false, 12, 3));
    try std.testing.expect(searchBarDisplayStateChanged(&same, true, 11, 3));
    try std.testing.expect(searchBarDisplayStateChanged(&same, true, 12, 4));
}

test "win32 tabButtonKeyAction maps focused-tab keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(TabButtonKeyAction.activate, tabButtonKeyAction(c.VK_RETURN, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.activate, tabButtonKeyAction(c.VK_SPACE, false).?);
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_RETURN, true));
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_SPACE, true));
    try std.testing.expectEqual(@as(?TabButtonKeyAction, null), tabButtonKeyAction(c.VK_F6, false));
    try std.testing.expectEqual(TabButtonKeyAction.previous, tabButtonKeyAction(c.VK_LEFT, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_previous, tabButtonKeyAction(c.VK_LEFT, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.next, tabButtonKeyAction(c.VK_RIGHT, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_next, tabButtonKeyAction(c.VK_RIGHT, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.first, tabButtonKeyAction(c.VK_HOME, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_first, tabButtonKeyAction(c.VK_HOME, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.last, tabButtonKeyAction(c.VK_END, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.move_last, tabButtonKeyAction(c.VK_END, true).?);
    try std.testing.expectEqual(TabButtonKeyAction.rename, tabButtonKeyAction(c.VK_F2, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.close, tabButtonKeyAction(c.VK_DELETE, false).?);
    try std.testing.expectEqual(TabButtonKeyAction.overview, tabButtonKeyAction(c.VK_APPS, false).?);
    try std.testing.expect(tabButtonKeyAction(c.VK_TAB, false) == null);
}

test "win32 moveTabAmountToEdge computes direct host reorder delta" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(isize, -2), moveTabAmountToEdge(4, 2, true));
    try std.testing.expectEqual(@as(isize, 1), moveTabAmountToEdge(4, 2, false));
    try std.testing.expectEqual(@as(isize, 0), moveTabAmountToEdge(4, 0, true));
    try std.testing.expectEqual(@as(isize, 0), moveTabAmountToEdge(4, 3, false));
}

test "win32 searchButtonKeyAction maps focused search button keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(SearchButtonKeyAction.next, searchButtonKeyAction(c.VK_F3, false).?);
    try std.testing.expectEqual(SearchButtonKeyAction.previous, searchButtonKeyAction(c.VK_F3, true).?);
    try std.testing.expectEqual(SearchButtonKeyAction.dismiss, searchButtonKeyAction(c.VK_ESCAPE, false).?);
    try std.testing.expect(searchButtonKeyAction(c.VK_RETURN, false) == null);
}

test "win32 docked search key actions preserve semantic next and previous navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        input.Binding.Action.NavigateSearch.previous,
        dockedSearchCoreDirectionFromKeyAction(.next).?,
    );
    try std.testing.expectEqual(
        input.Binding.Action.NavigateSearch.next,
        dockedSearchCoreDirectionFromKeyAction(.previous).?,
    );
    try std.testing.expect(dockedSearchCoreDirectionFromKeyAction(.dismiss) == null);
}

test "win32 docked search arrow buttons follow visible up and down navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        input.Binding.Action.NavigateSearch.next,
        dockedSearchButtonDirection(c.SEARCH_PREV_ID).?,
    );
    try std.testing.expectEqual(
        input.Binding.Action.NavigateSearch.previous,
        dockedSearchButtonDirection(c.SEARCH_NEXT_ID).?,
    );
    try std.testing.expect(dockedSearchButtonDirection(0) == null);
}

test "win32 docked search Enter and Shift+Enter follow the arrow-key contract" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        dockedSearchArrowDirection(c.VK_DOWN).?,
        dockedSearchEnterDirection(false),
    );
    try std.testing.expectEqual(
        dockedSearchArrowDirection(c.VK_UP).?,
        dockedSearchEnterDirection(true),
    );
}

test "win32 docked search Up and Down keys follow the visible button contract" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        input.Binding.Action.NavigateSearch.next,
        dockedSearchArrowDirection(c.VK_UP).?,
    );
    try std.testing.expectEqual(
        input.Binding.Action.NavigateSearch.previous,
        dockedSearchArrowDirection(c.VK_DOWN).?,
    );
    try std.testing.expect(dockedSearchArrowDirection(c.VK_LEFT) == null);
}

test "win32 docked search selection preserves newest-first visible numbering" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 0), searchSelectedRawFromCoreDisplay(1));
    try std.testing.expectEqual(@as(?usize, 7), searchSelectedRawFromCoreDisplay(8));
    try std.testing.expectEqual(@as(?usize, 1), searchSelectedDisplayFromRaw(0, 8));
    try std.testing.expectEqual(@as(?usize, 8), searchSelectedDisplayFromRaw(7, 8));
}

test "win32 docked search preview advances visible numbering with navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?usize, 6), advanceSearchSelectedRaw(7, 8, .previous, true));
    try std.testing.expectEqual(@as(?usize, 0), advanceSearchSelectedRaw(7, 8, .next, true));
    try std.testing.expectEqual(@as(?usize, 7), searchSelectedDisplayFromRaw(
        advanceSearchSelectedRaw(7, 8, .previous, true),
        8,
    ));
    try std.testing.expectEqual(@as(?usize, 1), searchSelectedDisplayFromRaw(
        advanceSearchSelectedRaw(7, 8, .next, true),
        8,
    ));
}

test "win32 docked search sequential visible order increments while moving older and up" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const total: ?usize = 2500;
    var raw: ?usize = null;

    try std.testing.expectEqual(@as(?usize, null), searchSelectedDisplayFromRaw(raw, total));

    raw = searchSelectedRawFromCoreDisplay(1);
    try std.testing.expectEqual(@as(?usize, 1), searchSelectedDisplayFromRaw(raw, total));

    raw = advanceSearchSelectedRaw(raw, total, .next, true);
    try std.testing.expectEqual(@as(?usize, 2), searchSelectedDisplayFromRaw(raw, total));

    raw = advanceSearchSelectedRaw(raw, total, .next, true);
    try std.testing.expectEqual(@as(?usize, 3), searchSelectedDisplayFromRaw(raw, total));

    raw = advanceSearchSelectedRaw(raw, total, .previous, true);
    try std.testing.expectEqual(@as(?usize, 2), searchSelectedDisplayFromRaw(raw, total));

    raw = advanceSearchSelectedRaw(raw, total, .previous, true);
    try std.testing.expectEqual(@as(?usize, 1), searchSelectedDisplayFromRaw(raw, total));
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

test "win32 buildHostBannerText prefixes info and error banners" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const plain = try buildHostBannerText(std.testing.allocator, .none, "ready");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("ready", plain);

    const info = try buildHostBannerText(std.testing.allocator, .info, "ready");
    defer std.testing.allocator.free(info);
    try std.testing.expectEqualStrings("Info: ready", info);

    const err = try buildHostBannerText(std.testing.allocator, .err, "ready");
    defer std.testing.allocator.free(err);
    try std.testing.expectEqualStrings("Error: ready", err);
}

test "win32 overlayPaintCacheDirty ignores repaint-only dirtiness" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const cached = std.unicode.utf8ToUtf16LeStringLiteral("ok");

    try std.testing.expect(!overlayPaintCacheDirty(false, .search, cached, cached, null));
    try std.testing.expect(!overlayPaintCacheDirty(false, .profile, cached, cached, cached));

    try std.testing.expect(overlayPaintCacheDirty(true, .search, cached, cached, null));
    try std.testing.expect(overlayPaintCacheDirty(false, .search, null, cached, null));
    try std.testing.expect(overlayPaintCacheDirty(false, .profile, cached, cached, null));
}

test "win32 profile chrome visibility requires the profile overlay" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    inline for (std.meta.tags(HostOverlayMode)) |mode| {
        try std.testing.expectEqual(mode == .profile, profileChromeVisible(mode));
    }
}

test "win32 inspector chrome visibility requires no overlay" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    inline for (std.meta.tags(HostOverlayMode)) |mode| {
        try std.testing.expectEqual(mode == .none, inspectorChromeVisible(mode));
    }
}

test "win32 inspector visibility changes require host relayout" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(inspectorVisibilityChangeNeedsHostRelayout(true));
    try std.testing.expect(!inspectorVisibilityChangeNeedsHostRelayout(false));
}

test "win32 inspector panel visibility is tab scoped" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(inspectorPanelVisibleForState(.none, true));
    try std.testing.expect(!inspectorPanelVisibleForState(.none, false));
    try std.testing.expect(!inspectorPanelVisibleForState(.command_palette, true));
}

test "win32 command palette hides duplicate accept button" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!overlayAcceptButtonVisible(.command_palette));
    try std.testing.expect(overlayAcceptButtonVisible(.profile));
    try std.testing.expect(overlayAcceptButtonVisible(.search));
    try std.testing.expect(overlayAcceptButtonVisible(.confirm));
    try std.testing.expect(!overlayEditFrameVisible(.confirm));
    try std.testing.expect(overlayEditFrameVisible(.command_palette));
    try std.testing.expect(overlayEditFrameVisible(.profile));
}

test "win32 transient overlay focus ring includes every visible control" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(OverlayFocusSlot.accept, nextOverlayFocusSlot(.profile, .edit, false));
    try std.testing.expectEqual(OverlayFocusSlot.cancel, nextOverlayFocusSlot(.profile, .accept, false));
    try std.testing.expectEqual(OverlayFocusSlot.edit, nextOverlayFocusSlot(.profile, .cancel, false));
    try std.testing.expectEqual(OverlayFocusSlot.cancel, nextOverlayFocusSlot(.profile, .edit, true));
    try std.testing.expectEqual(OverlayFocusSlot.edit, nextOverlayFocusSlot(.profile, .accept, true));
    try std.testing.expectEqual(OverlayFocusSlot.accept, nextOverlayFocusSlot(.profile, .cancel, true));

    try std.testing.expectEqual(OverlayFocusSlot.cancel, nextOverlayFocusSlot(.command_palette, .edit, false));
    try std.testing.expectEqual(OverlayFocusSlot.edit, nextOverlayFocusSlot(.command_palette, .cancel, true));
    try std.testing.expectEqual(OverlayFocusSlot.cancel, nextOverlayFocusSlot(.confirm, .accept, false));
    try std.testing.expectEqual(OverlayFocusSlot.accept, nextOverlayFocusSlot(.confirm, .cancel, true));

    try std.testing.expectEqual(
        OverlayFocusSlot.cancel,
        nextVisibleOverlayFocusSlot(.profile, .edit, false, true, false, false, true),
    );
    try std.testing.expectEqual(
        OverlayFocusSlot.cancel,
        nextVisibleOverlayFocusSlot(.confirm, .accept, false, false, false, false, true),
    );
    try std.testing.expectEqual(
        OverlayFocusSlot.accept,
        nextVisibleOverlayFocusSlot(.confirm, .cancel, true, false, false, true, true),
    );
    try std.testing.expectEqual(
        null,
        nextVisibleOverlayFocusSlot(.command_palette, .edit, false, true, false, false, false),
    );
    try std.testing.expectEqual(
        null,
        nextVisibleOverlayFocusSlot(.confirm, .cancel, false, false, false, false, true),
    );
}

test "win32 inspectorBannerStateChanged only trips on actual banner deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!inspectorBannerStateChanged(.none, .none, null, true));
    try std.testing.expect(inspectorBannerStateChanged(.none, .none, null, false));
    try std.testing.expect(!inspectorBannerStateChanged(.none, .info, host_banner_inspector_inactive, false));
    try std.testing.expect(inspectorBannerStateChanged(.none, .err, "error", false));
    try std.testing.expect(!inspectorBannerStateChanged(.search, .none, null, true));
}

test "win32 windowTitleSyncChanged only trips on actual title deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(windowTitleSyncChanged(null, "noctty"));
    try std.testing.expect(!windowTitleSyncChanged("noctty", "noctty"));
    try std.testing.expect(windowTitleSyncChanged("noctty", "noctty - 2"));
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

test "win32 buildOverlayAcceptLabel reflects overlay action state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const palette_idle = try buildOverlayAcceptLabel(std.testing.allocator, .command_palette, "", null, null, null, .{});
    defer std.testing.allocator.free(palette_idle);
    try std.testing.expectEqualStrings("Close", palette_idle);

    const palette_run = try buildOverlayAcceptLabel(
        std.testing.allocator,
        .command_palette,
        "new_tab",
        null,
        null,
        null,
        .{ .match_count = 1, .title = "New tab", .subtitle = "Action", .available = true },
    );
    defer std.testing.allocator.free(palette_run);
    try std.testing.expectEqualStrings("Activate", palette_run);

    const palette_matches = try buildOverlayAcceptLabel(
        std.testing.allocator,
        .command_palette,
        "0x96f",
        null,
        null,
        null,
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    );
    defer std.testing.allocator.free(palette_matches);
    try std.testing.expectEqualStrings("Activate", palette_matches);

    const palette_hidden = try buildOverlayAcceptLabel(
        std.testing.allocator,
        .command_palette,
        "0x96f",
        null,
        null,
        null,
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme" },
    );
    defer std.testing.allocator.free(palette_hidden);
    try std.testing.expectEqualStrings("Resize", palette_hidden);

    const search_next = try buildOverlayAcceptLabel(std.testing.allocator, .search, "needle", "needle", 8, 2, .{});
    defer std.testing.allocator.free(search_next);
    try std.testing.expectEqualStrings("Next", search_next);

    const search_find = try buildOverlayAcceptLabel(std.testing.allocator, .search, "other", "needle", 8, 2, .{});
    defer std.testing.allocator.free(search_find);
    try std.testing.expectEqualStrings("Find", search_find);

    const tab_go = try buildOverlayAcceptLabel(std.testing.allocator, .tab_overview, "2", null, null, null, .{});
    defer std.testing.allocator.free(tab_go);
    try std.testing.expectEqualStrings("Go", tab_go);

    const title_apply = try buildOverlayAcceptLabel(std.testing.allocator, .surface_title, "logs", null, null, null, .{});
    defer std.testing.allocator.free(title_apply);
    try std.testing.expectEqualStrings("Apply", title_apply);
}

test "win32 buildOverlayHintText reflects live overlay guidance" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};

    const command_unique = try buildOverlayHintText(
        std.testing.allocator,
        .command_palette,
        "reload_",
        null,
        null,
        null,
        .{},
        1,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(command_unique);
    try std.testing.expect(std.mem.indexOf(u8, command_unique, "reload_config") != null);

    const search_next = try buildOverlayHintText(
        std.testing.allocator,
        .search,
        "needle",
        "needle",
        8,
        2,
        .{},
        1,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(search_next);
    try std.testing.expect(std.mem.indexOf(u8, search_next, "2/8") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_next, "next match") != null);

    const tab_invalid = try buildOverlayHintText(
        std.testing.allocator,
        .tab_overview,
        "8",
        null,
        null,
        null,
        .{ .index = 1, .total = 4 },
        2,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(tab_invalid);
    try std.testing.expect(std.mem.indexOf(u8, tab_invalid, "out of range") != null);

    const tab_title = try buildOverlayHintText(
        std.testing.allocator,
        .tab_title,
        "logs",
        null,
        null,
        null,
        .{ .index = 0, .total = 3 },
        2,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(tab_title);
    try std.testing.expect(std.mem.indexOf(u8, tab_title, "tab 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_title, "2 panes") != null);
}

test "win32 overlayCancelLabel reflects overlay mode" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings("Close", overlayCancelLabel(.search));
    try std.testing.expectEqualStrings("Cancel", overlayCancelLabel(.surface_title));
}

test "win32 buildCommandPaletteOverlayLabel reflects palette state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const idle = try buildCommandPaletteOverlayLabel(std.testing.allocator, "", .{});
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Command", idle);

    const matches = try buildCommandPaletteOverlayLabel(
        std.testing.allocator,
        "0x96f",
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    );
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqualStrings("Command 1", matches);

    const invalid = try buildCommandPaletteOverlayLabel(
        std.testing.allocator,
        "definitely_not_real",
        .{},
    );
    defer std.testing.allocator.free(invalid);
    try std.testing.expectEqualStrings("Command ?", invalid);
}

test "win32 command palette rich feedback never calls a theme an action miss" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const feedback = try buildCommandPaletteFeedbackText(
        std.testing.allocator,
        "0x96f",
        &.{},
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    );
    defer std.testing.allocator.free(feedback);
    try std.testing.expect(std.mem.indexOf(u8, feedback, "0x96f") != null);
    try std.testing.expect(std.mem.indexOf(u8, feedback, "Bundled theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, feedback, "No matching action") == null);

    const hidden_feedback = try buildCommandPaletteFeedbackText(
        std.testing.allocator,
        "0x96f",
        &.{},
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme" },
    );
    defer std.testing.allocator.free(hidden_feedback);
    try std.testing.expect(std.mem.indexOf(u8, hidden_feedback, "window larger") != null);
}

test "win32 commandPaletteBannerText shows ready banner for valid action" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};
    const banner = (try commandPaletteBannerText(std.testing.allocator, snap, "new_tab", empty_mru)).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expect(std.mem.startsWith(u8, banner, "Ready: new_tab"));
    try std.testing.expect(std.mem.indexOf(u8, banner, "Open a new tab") != null);
}

test "win32 commandPaletteBannerText suggests matching actions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};
    const banner = (try commandPaletteBannerText(std.testing.allocator, snap, "new_", empty_mru)).?;
    defer std.testing.allocator.free(banner);
    // Top-5 match cap means a specific "new_split:*" may or may not
    // appear, but the banner should list at least new_tab and at
    // least one new_split variant.
    try std.testing.expect(std.mem.indexOf(u8, banner, "new_tab") != null);
    try std.testing.expect(std.mem.indexOf(u8, banner, "new_split") != null);
}

test "win32 commandPaletteBannerText resolves unique prefix" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};
    const banner = (try commandPaletteBannerText(std.testing.allocator, snap, "reload_", empty_mru)).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expect(std.mem.startsWith(u8, banner, "Ready: reload_config"));
    try std.testing.expect(std.mem.indexOf(u8, banner, "Reload") != null);
}

test "win32 commandPaletteBannerText uses fullscreen description" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};
    const banner = (try commandPaletteBannerText(std.testing.allocator, snap, "toggle_fullscreen", empty_mru)).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expect(std.mem.startsWith(u8, banner, "Ready: toggle_fullscreen"));
    try std.testing.expect(std.mem.indexOf(u8, banner, "fullscreen") != null);
}

test "win32 commandPaletteBannerText suggests tab overview action" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();
    const empty_mru: []const []const u8 = &.{};
    const banner = (try commandPaletteBannerText(std.testing.allocator, snap, "toggle_tab", empty_mru)).?;
    defer std.testing.allocator.free(banner);
    try std.testing.expect(std.mem.indexOf(u8, banner, "toggle_tab_overview") != null);
    // "tab overview" is part of the default description verbatim.
    try std.testing.expect(std.mem.indexOf(u8, banner, "tab overview") != null);
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

test "PKG32 default F3 and Shift+F3 match the docked search F3 and Enter directions" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var cfg = try @import("../../config.zig").Config.default(std.testing.allocator);
    defer cfg.deinit();
    const set = &cfg.keybind.set;

    const f3 = set.get(.{ .key = .{ .physical = .f3 } }) orelse return error.F3Unbound;
    const shift_f3 = set.get(.{ .key = .{ .physical = .f3 }, .mods = .{ .shift = true } }) orelse
        return error.ShiftF3Unbound;
    try std.testing.expectEqual(dockedSearchEnterDirection(false), f3.value_ptr.leaf.action.navigate_search);
    try std.testing.expectEqual(dockedSearchEnterDirection(true), shift_f3.value_ptr.leaf.action.navigate_search);
    try std.testing.expectEqual(
        f3.value_ptr.leaf.action.navigate_search,
        dockedSearchCoreDirectionFromKeyAction(searchButtonKeyAction(c.VK_F3, false).?).?,
    );
    try std.testing.expectEqual(
        shift_f3.value_ptr.leaf.action.navigate_search,
        dockedSearchCoreDirectionFromKeyAction(searchButtonKeyAction(c.VK_F3, true).?).?,
    );
}
