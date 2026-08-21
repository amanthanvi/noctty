const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../../apprt.zig");
const windows_shell = @import("../../config/windows_shell.zig");
const input = @import("../../input.zig");
const terminal = @import("../../terminal/main.zig");

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
const host_tab_label_max_len: usize = default_metrics.tab_label_max_len;
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

pub const SearchStatus = struct {
    active: bool = false,
    needle: ?[]const u8 = null,
    total: ?usize = null,
    selected: ?usize = null,
};

pub const SurfaceStatus = struct {
    pwd: ?[]const u8 = null,
    scrollbar: terminal.Scrollbar = .zero,
    readonly: bool = false,
    secure_input: bool = false,
    key_sequence_active: bool = false,
    key_table_name: ?[]const u8 = null,
    search: SearchStatus = .{},
    progress: ?[]const u8 = null,
};

pub const HostTabStatus = struct {
    index: usize = 0,
    total: usize = 1,
};

const VisibleTabRange = struct {
    start: usize,
    count: usize,
};

const TabOverviewEntry = struct {
    title: ?[]const u8 = null,
    pane_count: usize = 1,
    active: bool = false,
};

pub const HostBannerKind = enum {
    none,
    info,
    err,
};

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

const TabsButtonKeyAction = enum {
    previous,
    next,
    rename,
    overview,
};

const CommandButtonKeyAction = enum {
    toggle,
    previous,
    next,
    dismiss,
};

const ProfilesButtonKeyAction = enum {
    open,
    toggle,
    previous,
    next,
    first,
    last,
};

const QuickSlotFocusKeyAction = enum {
    previous,
    next,
    first,
    last,
    open,
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

pub const OverlayFocusSlot = enum { edit, accept, cancel };

const ScrollStatusKey = struct {
    visible: bool,
    percent: usize,
};

const ResizeSplitFallbackDelta = struct {
    width: i32 = 0,
    height: i32 = 0,
};

const SurfaceOrderEntry = struct {
    host_id: u32,
    host_active: bool,
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
        .previous => .previous,
        .next => .next,
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

fn searchDirectionFromWheelDelta(delta: i16) input.Binding.Action.NavigateSearch {
    return if (delta > 0)
        .next
    else
        .previous;
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

pub fn profileChromeVisible(overlay_mode: HostOverlayMode, status_bar_height: i32) bool {
    return win32_chrome_state.profileVisible(overlay_mode, status_bar_height);
}

pub fn profileChromeNeedsFullTextInvalidation(overlay_mode: HostOverlayMode, status_bar_height: i32) bool {
    return win32_chrome_state.profileNeedsFullTextInvalidation(overlay_mode, status_bar_height);
}

pub fn chromeTextNeedsFullInvalidation(status_bar_height: i32) bool {
    return win32_chrome_state.textNeedsFullInvalidation(status_bar_height);
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

pub fn overlayEditFrameVisible(mode: HostOverlayMode) bool {
    return mode != .confirm;
}

fn nextOverlayFocusSlot(mode: HostOverlayMode, current: OverlayFocusSlot, reverse: bool) OverlayFocusSlot {
    if (mode == .confirm) return if (current == .accept) .cancel else .accept;
    if (!overlayAcceptButtonVisible(mode)) return if (current == .edit) .cancel else .edit;
    return if (reverse)
        switch (current) {
            .edit => .cancel,
            .accept => .edit,
            .cancel => .accept,
        }
    else switch (current) {
        .edit => .accept,
        .accept => .cancel,
        .cancel => .edit,
    };
}

fn overlayFocusSlotVisible(
    slot: OverlayFocusSlot,
    edit_visible: bool,
    accept_visible: bool,
    cancel_visible: bool,
) bool {
    return switch (slot) {
        .edit => edit_visible,
        .accept => accept_visible,
        .cancel => cancel_visible,
    };
}

pub fn nextVisibleOverlayFocusSlot(
    mode: HostOverlayMode,
    current: OverlayFocusSlot,
    reverse: bool,
    edit_visible: bool,
    accept_visible: bool,
    cancel_visible: bool,
) ?OverlayFocusSlot {
    var candidate = current;
    for (0..3) |_| {
        candidate = nextOverlayFocusSlot(mode, candidate, reverse);
        if (candidate != current and overlayFocusSlotVisible(
            candidate,
            edit_visible,
            accept_visible,
            cancel_visible,
        )) return candidate;
    }
    return null;
}

pub fn inspectorChromeVisible(overlay_mode: HostOverlayMode, status_bar_height: i32) bool {
    return win32_chrome_state.inspectorVisible(overlay_mode, status_bar_height);
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

fn scrollStatusKey(scrollbar: terminal.Scrollbar) ScrollStatusKey {
    const visible = scrollbar.total > scrollbar.len and
        scrollbar.offset + scrollbar.len < scrollbar.total;
    const percent = if (visible and scrollbar.total > 0)
        (scrollbar.offset * 100) / scrollbar.total
    else
        0;
    return .{
        .visible = visible,
        .percent = percent,
    };
}

pub fn scrollStatusTextChanged(previous: terminal.Scrollbar, next: terminal.Scrollbar) bool {
    return !std.meta.eql(scrollStatusKey(previous), scrollStatusKey(next));
}

fn tabsButtonKeyAction(vk: WPARAM) ?TabsButtonKeyAction {
    return switch (vk) {
        c.VK_LEFT, c.VK_UP => .previous,
        c.VK_RIGHT, c.VK_DOWN => .next,
        c.VK_F2 => .rename,
        c.VK_APPS => .overview,
        else => null,
    };
}

fn commandButtonKeyAction(vk: WPARAM) ?CommandButtonKeyAction {
    return switch (vk) {
        c.VK_RETURN, c.VK_SPACE => .toggle,
        c.VK_UP => .previous,
        c.VK_DOWN => .next,
        c.VK_ESCAPE => .dismiss,
        else => null,
    };
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

fn commandPaletteDirectionFromWheelDelta(delta: i16) bool {
    return delta > 0;
}

fn profileDirectionFromWheelDelta(delta: i16) bool {
    return delta > 0;
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

fn quickSlotFocusKeyAction(vk: WPARAM) ?QuickSlotFocusKeyAction {
    return switch (vk) {
        c.VK_LEFT, c.VK_UP => .previous,
        c.VK_RIGHT, c.VK_DOWN => .next,
        c.VK_HOME => .first,
        c.VK_END => .last,
        c.VK_RETURN => .open,
        else => null,
    };
}

fn profilesButtonKeyAction(vk: WPARAM) ?ProfilesButtonKeyAction {
    return switch (vk) {
        c.VK_RETURN => .open,
        c.VK_SPACE, c.VK_APPS => .toggle,
        c.VK_LEFT, c.VK_UP => .previous,
        c.VK_RIGHT, c.VK_DOWN => .next,
        c.VK_HOME => .first,
        c.VK_END => .last,
        else => null,
    };
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

pub fn formatProgressStatus(
    alloc: Allocator,
    value: win32_taskbar_progress.ProgressReport,
) !?[]u8 {
    const progress = win32_taskbar_progress.clampPercent(value.progress);
    return switch (value.state) {
        .remove => null,
        .set => if (progress) |value_|
            try std.fmt.allocPrint(alloc, "progress:{d}%", .{value_})
        else
            try alloc.dupe(u8, "progress"),
        .@"error" => if (progress) |value_|
            try std.fmt.allocPrint(alloc, "progress error:{d}%", .{value_})
        else
            try alloc.dupe(u8, "progress error"),
        .indeterminate => try alloc.dupe(u8, "progress:busy"),
        .pause => if (progress) |value_|
            try std.fmt.allocPrint(alloc, "progress paused:{d}%", .{value_})
        else
            try alloc.dupe(u8, "progress paused"),
    };
}

fn buildWindowTitle(
    alloc: Allocator,
    base_title: ?[]const u8,
    status: SurfaceStatus,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, base_title orelse "noctty");

    const appendStatus = struct {
        fn call(
            list: *std.ArrayListUnmanaged(u8),
            alloc_: Allocator,
            comptime fmt: []const u8,
            args: anytype,
        ) !void {
            try list.appendSlice(alloc_, " | ");
            try list.writer(alloc_).print(fmt, args);
        }
    }.call;

    if (status.readonly) try appendStatus(&buf, alloc, "readonly", .{});
    if (status.secure_input) try appendStatus(&buf, alloc, "sensitive", .{});
    if (status.key_sequence_active) try appendStatus(&buf, alloc, "keys", .{});
    if (status.key_table_name) |name| try appendStatus(&buf, alloc, "table:{s}", .{name});
    if (status.pwd) |pwd| try appendStatus(&buf, alloc, "cwd:{s}", .{pwd});
    if (status.search.active) {
        if (status.search.needle) |needle| {
            if (status.search.selected) |selected| {
                if (status.search.total) |total| {
                    try appendStatus(&buf, alloc, "find:{s} ({d}/{d})", .{ needle, selected, total });
                } else {
                    try appendStatus(&buf, alloc, "find:{s} ({d})", .{ needle, selected });
                }
            } else if (status.search.total) |total| {
                try appendStatus(&buf, alloc, "find:{s} ({d})", .{ needle, total });
            } else {
                try appendStatus(&buf, alloc, "find:{s}", .{needle});
            }
        } else {
            try appendStatus(&buf, alloc, "find", .{});
        }
    }
    if (status.progress) |progress| try appendStatus(&buf, alloc, "{s}", .{progress});

    return buf.toOwnedSlice(alloc);
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

pub fn hiddenScrollbarAlphaByte() u8 {
    // Keep the layered child hit-testable while visually hidden.
    // Windows won't deliver real hover input to an alpha-0 layered
    // child, so a true zero here strands the dynamic scrollbar in the
    // hidden state until some non-mouse activity wakes it up.
    return 1;
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

fn primarySurfaceIndex(entries: []const SurfaceOrderEntry) ?usize {
    if (entries.len == 0) return null;
    const first_host_id = entries[0].host_id;
    for (entries, 0..) |entry, i| {
        if (entry.host_id == first_host_id and entry.host_active) return i;
    }
    return 0;
}

pub fn buildHostAwareBaseTitle(
    alloc: Allocator,
    base_title: ?[]const u8,
    host: HostTabStatus,
) ![]u8 {
    if (host.total <= 1) return try alloc.dupe(u8, base_title orelse "noctty");
    return try std.fmt.allocPrint(
        alloc,
        "[{d}/{d}] {s}",
        .{ host.index + 1, host.total, base_title orelse "noctty" },
    );
}

/// Compact `value` to `max_len` bytes, ending in an ellipsis when it had to
/// cut. The budget is bytes, not codepoints: callers derive it from a pixel
/// width at roughly one byte per drawn cell (see `hostTabLabelMaxLen`), so
/// counting codepoints would let a CJK label overrun the space reserved for
/// it. `compactHostLabelLen` reports the same length without allocating.
fn compactHostLabel(
    alloc: Allocator,
    value: []const u8,
    max_len: usize,
) ![]u8 {
    if (value.len <= max_len) return try alloc.dupe(u8, value);
    if (max_len <= 3) return try alloc.dupe(u8, "...");
    const cut = utf8BoundaryFloor(value, max_len - 3);
    return try std.fmt.allocPrint(alloc, "{s}...", .{value[0..cut]});
}

/// Round `len` down to a UTF-8 sequence boundary in `value`.
///
/// Labels are compacted against a byte budget but are later converted with
/// `utf8ToUtf16LeAllocZ`, which rejects the result with `error.InvalidUtf8`
/// when the cut landed inside a multi-byte codepoint. Any non-ASCII title --
/// CJK, an emoji, an accented path -- hits that on the tab strip as soon as
/// a tab is narrow enough to truncate.
fn utf8BoundaryFloor(value: []const u8, len: usize) usize {
    if (len >= value.len) return value.len;
    var i = len;
    while (i > 0 and value[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

fn compactHostLabelLen(value: []const u8, max_len: usize) usize {
    if (value.len <= max_len) return value.len;
    if (max_len <= 3) return 3;
    // Must track `compactHostLabel` exactly: `profileStatusBadgeTextLen`
    // reserves chip width from this, and a cut rounded back off a multi-byte
    // codepoint makes the real label shorter than the byte budget.
    return utf8BoundaryFloor(value, max_len - 3) + 3;
}

pub fn hostTabLabelMaxLen(button_width: i32) usize {
    const estimated = @as(usize, @intCast(@max(6, @divTrunc(button_width - 26, 8))));
    return std.math.clamp(estimated, @as(usize, 6), @as(usize, host_tab_label_max_len));
}

pub fn shouldShowPaneCount(button_width: i32, pane_count: usize) bool {
    return pane_count > 1 and button_width >= 140;
}

pub fn visibleTabRange(tab_count: usize, active_index: usize, tab_area_width: i32) VisibleTabRange {
    if (tab_count == 0) return .{ .start = 0, .count = 0 };
    const max_visible = std.math.clamp(
        @as(usize, @intCast(@max(1, @divTrunc(tab_area_width, host_tab_min_button_width)))),
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

pub fn buildTabButtonLabel(
    alloc: Allocator,
    base_title: ?[]const u8,
    index: usize,
    active: bool,
    pane_count: usize,
    max_len: usize,
    show_pane_count: bool,
) ![]u8 {
    const compact = try compactHostLabel(alloc, base_title orelse "noctty", max_len);
    defer alloc.free(compact);
    if (show_pane_count and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "{s}{d}: {s} ({d})",
            .{
                if (active) "* " else "",
                index + 1,
                compact,
                pane_count,
            },
        );
    }

    return try std.fmt.allocPrint(
        alloc,
        "{s}{d}: {s}",
        .{
            if (active) "* " else "",
            index + 1,
            compact,
        },
    );
}

fn buildTabOverviewBannerText(
    alloc: Allocator,
    entries: []const TabOverviewEntry,
) ![]u8 {
    if (entries.len == 0) return try alloc.dupe(u8, "Tabs: none");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, "Tabs: ");
    for (entries, 0..) |entry, i| {
        if (i > 0) try buf.appendSlice(alloc, " | ");
        const compact = try compactHostLabel(alloc, entry.title orelse "noctty", 18);
        defer alloc.free(compact);
        try buf.writer(alloc).print("{s}{d}:{s}", .{
            if (entry.active) "*" else "",
            i + 1,
            compact,
        });
        if (entry.pane_count > 1) {
            try buf.writer(alloc).print(" ({d})", .{entry.pane_count});
        }
    }
    return try buf.toOwnedSlice(alloc);
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

pub fn buildOverlayPaintLabelText(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    search_total: ?usize,
    search_selected: ?usize,
    host_status: HostTabStatus,
    palette_presentation: PalettePresentation,
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
        // Confirm overlays source their prompt title from the payload
        // at paint time; this default only appears when the payload
        // has already been dropped (mid-teardown).
        .confirm => try alloc.dupe(u8, "Confirm"),
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
) ![]u8 {
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
        // Confirm overlays source their hint text from the payload
        // body at paint time (the hint HWND is re-used as the body
        // line). This helper produces a default so the promptTitle
        // call doesn't need a special case; the real text lives on
        // the payload.
        .confirm => try alloc.dupe(u8, ""),
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

fn commandPaletteCompletionCandidate(
    snap: PaletteSnapshot,
    seed: []const u8,
    current_text: []const u8,
    reverse: bool,
) ?[]const u8 {
    var ranked_buf: [palette_max_ranked]RankedIndex = undefined;
    const ranked = rankedIndicesForQuery(snap, seed, &ranked_buf);
    if (ranked.len == 0) return null;
    if (ranked.len == 1) return std.mem.span(snap.cvals[ranked[0].index].action);

    var current_rank_index: ?usize = null;
    for (ranked, 0..) |r, i| {
        const action = std.mem.span(snap.cvals[r.index].action);
        if (std.mem.eql(u8, action, current_text)) {
            current_rank_index = i;
            break;
        }
    }

    const target = if (current_rank_index) |value|
        if (reverse)
            (value + ranked.len - 1) % ranked.len
        else
            (value + 1) % ranked.len
    else if (reverse)
        ranked.len - 1
    else
        0;
    return std.mem.span(snap.cvals[ranked[target].index].action);
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
                "{s} — {s}. Enter activates; Escape closes.",
                .{ title, subtitle },
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
            "{d} matches. Selected: {s} — {s}. Up/Down selects; Enter activates.",
            .{ presentation.match_count, title, subtitle },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "{d} matches. Selected: {s}. Up/Down selects; Enter activates.",
        .{ presentation.match_count, title },
    );
}

pub fn paletteCompletionText(descriptor: win32_palette.catalog.Descriptor) []const u8 {
    return switch (descriptor.payload) {
        .action => |payload| payload.action,
        .recent_command => |payload| payload.action,
        .profile => |key| key,
        .setting => |key| key,
        .theme => |name| name,
        .layout => |name| name,
        .tab, .pane, .help => descriptor.item.title,
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

pub fn buildInspectorBannerText(
    alloc: Allocator,
    host: HostTabStatus,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector active | tab {d}/{d} | panes {d} | zoomed | toggle Inspect to return",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector active | tab {d}/{d} | panes {d} | toggle Inspect to return",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "Inspector active | tab {d}/{d} | toggle Inspect to return",
        .{ host.index + 1, host.total },
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

pub fn buildInspectorDetailText(
    alloc: Allocator,
    host: HostTabStatus,
    pane_count: usize,
    zoomed: bool,
) ![]u8 {
    if (zoomed and pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector is attached to tab {d}/{d}. This tab has {d} panes and split zoom is active.",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    if (pane_count > 1) {
        return try std.fmt.allocPrint(
            alloc,
            "Inspector is attached to tab {d}/{d}. This tab currently has {d} panes.",
            .{ host.index + 1, host.total, pane_count },
        );
    }
    return try std.fmt.allocPrint(
        alloc,
        "Inspector is attached to tab {d}/{d}. Toggle Inspect to return to the normal terminal view.",
        .{ host.index + 1, host.total },
    );
}

pub fn buildSearchDetailText(
    alloc: Allocator,
    needle: ?[]const u8,
    total: ?usize,
    selected: ?usize,
) ![]u8 {
    if (needle) |value| {
        if (selected) |current| {
            if (total) |count| {
                return try std.fmt.allocPrint(
                    alloc,
                    "Live search for \"{s}\" is active. Match {d} of {d}. Enter moves to the next match.",
                    .{ value, current, count },
                );
            }
        }
        if (total) |count| {
            return try std.fmt.allocPrint(
                alloc,
                "Live search for \"{s}\" is active. {d} matches currently visible.",
                .{ value, count },
            );
        }
        return try std.fmt.allocPrint(
            alloc,
            "Live search for \"{s}\" is active. Keep typing to refine the current needle.",
            .{value},
        );
    }
    return try alloc.dupe(u8, "Live search is active. Keep typing to refine the current needle.");
}

fn buildCommandButtonLabel(
    alloc: Allocator,
    active: bool,
    input_text: ?[]const u8,
) ![]u8 {
    if (active) {
        if (input_text) |value| {
            if (value.len > 0) {
                const compact = try compactHostLabel(alloc, value, 9);
                defer alloc.free(compact);
                return try std.fmt.allocPrint(alloc, "Cmd {s}", .{compact});
            }
        }
        return try alloc.dupe(u8, "[Cmd]");
    }
    return try alloc.dupe(u8, "Cmd");
}

fn buildProfilesButtonLabel(
    alloc: Allocator,
    active: bool,
    profiles_opt: ?[]const windows_shell.Profile,
    selected_index: ?usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    _ = pinned_slot_ordinal;
    const profiles = profiles_opt orelse return try alloc.dupe(u8, if (active) "Pick shell" else "Launch");
    if (profiles.len == 0) return try alloc.dupe(u8, if (active) "Pick shell" else "Launch");
    const index = selected_index orelse 0;
    const profile = profiles[@min(index, profiles.len - 1)];
    const compact = try compactHostLabel(alloc, profile.label, 8);
    defer alloc.free(compact);
    if (active) return try std.fmt.allocPrint(alloc, "Pick {s}", .{compact});
    return try std.fmt.allocPrint(alloc, "Launch {s}", .{compact});
}

fn launchTargetButtonLabel(
    alloc: Allocator,
    target: ProfileOpenTarget,
    selected_index: ?usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    const base = switch (target) {
        .tab => "Tab",
        .window => "Win",
        .split => "Pane",
    };
    if (selected_index) |index| {
        if (index < 9) {
            if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == index) {
                return try std.fmt.allocPrint(alloc, "*{d} {s}", .{ index + 1, base });
            }
            return try std.fmt.allocPrint(alloc, "{d} {s}", .{ index + 1, base });
        }
    }
    return try alloc.dupe(u8, base);
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

fn profileKindDetail(kind: windows_shell.ProfileKind) windows_shell.ShellIntegrationDiagnostic {
    return windows_shell.shellIntegrationDiagnostic(kind);
}

fn profileOpenTargetActionText(target: ProfileOpenTarget) []const u8 {
    return switch (target) {
        .tab => "new tab",
        .window => "new window",
        .split => "split",
    };
}

pub fn buildProfileStatusBadgeText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    selected_index: ?usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    _ = selected_index;
    _ = pinned_slot_ordinal;
    const compact = try compactHostLabel(alloc, profile.label, 12);
    defer alloc.free(compact);
    return try alloc.dupe(u8, compact);
}

pub fn profileStatusBadgeTextLen(
    profile: *const windows_shell.Profile,
    selected_index: ?usize,
    pinned_slot_ordinal: ?usize,
) usize {
    _ = selected_index;
    _ = pinned_slot_ordinal;
    return compactHostLabelLen(profile.label, 12);
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

pub fn buildProfileQuickSlotChipText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    slot_index: usize,
    pinned_slot_ordinal: ?usize,
) ![]u8 {
    if (slot_index < 9) {
        if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == slot_index) {
            return try std.fmt.allocPrint(alloc, "*{d} {s}", .{
                slot_index + 1,
                profileKindBadge(profile.kind),
            });
        }
        return try std.fmt.allocPrint(alloc, "{d} {s}", .{
            slot_index + 1,
            profileKindBadge(profile.kind),
        });
    }
    return try alloc.dupe(u8, profileKindBadge(profile.kind));
}

pub fn profileQuickSlotChipTextLen(
    profile: *const windows_shell.Profile,
    slot_index: usize,
    pinned_slot_ordinal: ?usize,
) usize {
    const badge_len = profileKindBadge(profile.kind).len;
    if (slot_index < 9) {
        return badge_len + 2 + if (pinned_slot_ordinal != null and pinned_slot_ordinal.? == slot_index) @as(usize, 1) else 0;
    }
    return badge_len;
}

pub fn launcherChipRightInset(has_slot_badge: bool, has_target_marker: bool) i32 {
    if (has_slot_badge) return 16;
    if (has_target_marker) return 12;
    return 5;
}

fn targetButtonLabelRightInset(target: ?ProfileOpenTarget) i32 {
    return if (target != null) 12 else 0;
}

pub fn buttonLabelRightInset(pinned_slot_ordinal: ?usize, target: ?ProfileOpenTarget) i32 {
    const slot_inset: i32 = if (pinnedSlotBadgeDigit(pinned_slot_ordinal) != null) 16 else 0;
    return @max(targetButtonLabelRightInset(target), slot_inset);
}

pub fn shouldPaintQuickSlotTargetMarker(hovered: bool, focused: bool) bool {
    return hovered or focused;
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
    max_len: usize,
) ![]u8 {
    const command = try profile.command.string(alloc);
    defer alloc.free(command);
    return try compactHostLabel(alloc, command, max_len);
}

fn buildProfileOrderSummaryText(
    alloc: Allocator,
    order_hint_opt: ?[]const u8,
    max_items: usize,
) !?[]u8 {
    const order_hint = order_hint_opt orelse return null;
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(alloc);

    var count: usize = 0;
    var more = false;
    var it = std.mem.splitAny(u8, order_hint, ",;");
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t\r\n");
        if (token.len == 0) continue;
        if (count >= max_items) {
            more = true;
            break;
        }
        const compact = try compactHostLabel(alloc, token, 12);
        defer alloc.free(compact);
        if (parts.items.len > 0) try parts.appendSlice(alloc, " > ");
        try parts.appendSlice(alloc, compact);
        count += 1;
    }

    if (count == 0) return null;
    if (more) try parts.appendSlice(alloc, " > ...");
    return try parts.toOwnedSlice(alloc);
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

fn buildSearchButtonLabel(
    alloc: Allocator,
    active: bool,
    total: ?usize,
    selected: ?usize,
) ![]u8 {
    if (selected) |current| {
        if (total) |count| {
            return try std.fmt.allocPrint(alloc, "{s}{d}/{d}", .{
                if (active) "[F] " else "Find ",
                current,
                count,
            });
        }
    }
    if (total) |count| {
        return try std.fmt.allocPrint(alloc, "{s}{d}", .{
            if (active) "[F] " else "Find ",
            count,
        });
    }
    return try alloc.dupe(u8, if (active) "[Find]" else "Find");
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

pub fn buildProfileDetailText(
    alloc: Allocator,
    profile: *const windows_shell.Profile,
    profiles_opt: ?[]const windows_shell.Profile,
    overlay_open: bool,
    default_target: ProfileOpenTarget,
    order_hint: ?[]const u8,
    pinned_slot_keys: [3]?[:0]const u8,
) ![]u8 {
    const preview = try buildProfileCommandPreviewText(alloc, profile, 32);
    defer alloc.free(preview);
    const badge = try buildProfileChromeBadgeText(alloc, profile.kind);
    defer alloc.free(badge);
    const pinned_slot = try buildPinnedProfileSlotText(
        alloc,
        findLauncherQuickSlotOrdinal(pinned_slot_keys, profile.key),
    );
    defer alloc.free(pinned_slot);
    const quick_picks = if (overlay_open)
        try buildProfileQuickPickText(alloc, profiles_opt orelse &.{}, 4, 10)
    else
        try buildProfileQuickPickText(alloc, profiles_opt orelse &.{}, 3, 9);
    defer if (quick_picks) |value| alloc.free(value);
    const quick_suffix = if (overlay_open)
        if (quick_picks) |value|
            try std.fmt.allocPrint(alloc, " Quick picks: {s}.", .{value})
        else
            try alloc.dupe(u8, "")
    else if (quick_picks) |value|
        try std.fmt.allocPrint(alloc, " Top slots: {s}.", .{value})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(quick_suffix);
    const order_summary = try buildProfileOrderSummaryText(alloc, order_hint, 4);
    defer if (order_summary) |value| alloc.free(value);
    const order_suffix = if (order_summary) |value|
        try std.fmt.allocPrint(alloc, " Order: {s}.", .{value})
    else
        try alloc.dupe(u8, "");
    defer alloc.free(order_suffix);
    const overlay_suffix = try std.fmt.allocPrint(alloc, "{s}{s}", .{ quick_suffix, order_suffix });
    defer alloc.free(overlay_suffix);
    const idle_suffix = try std.fmt.allocPrint(alloc, "{s}{s}", .{ quick_suffix, order_suffix });
    defer alloc.free(idle_suffix);
    const detail = profileKindDetail(profile.kind);
    return if (overlay_open)
        std.fmt.allocPrint(
            alloc,
            "Selected profile: {s} {s}. Run {s}.{s} Enter opens a {s}, Ctrl+Enter splits here, and Shift+Enter opens a new window. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
            .{
                badge,
                profile.label,
                preview,
                pinned_slot,
                profileOpenTargetActionText(default_target),
                overlay_suffix,
            },
        )
    else
        std.fmt.allocPrint(
            alloc,
            "Default profile: {s} {s}. Run {s}.{s} New hosts inherit this {s}.{s}{s} + opens a {s}, middle-click + splits here, and right-click + opens a new window. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.{s}",
            .{
                badge,
                profile.label,
                preview,
                pinned_slot,
                detail.summary,
                if (detail.next_step != null) " " else "",
                detail.next_step orelse "",
                profileOpenTargetActionText(default_target),
                idle_suffix,
            },
        );
}

fn buildPinnedProfileSlotText(alloc: Allocator, pinned_slot_ordinal: ?usize) ![]u8 {
    if (pinned_slot_ordinal) |ordinal| {
        return try std.fmt.allocPrint(alloc, " Pinned slot {d}.", .{ordinal + 1});
    }
    return try alloc.dupe(u8, "");
}

fn buildInspectorButtonLabel(
    alloc: Allocator,
    visible: bool,
    pane_count: usize,
) ![]u8 {
    if (visible and pane_count > 1) {
        return try std.fmt.allocPrint(alloc, "[Inspect {d}]", .{pane_count});
    }
    if (visible) return try alloc.dupe(u8, "[Inspect]");
    if (pane_count > 1) return try std.fmt.allocPrint(alloc, "Inspect {d}", .{pane_count});
    return try alloc.dupe(u8, "Inspect");
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

test "win32 buildWindowTitle appends active status segments" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildWindowTitle(std.testing.allocator, "pwsh", .{
        .pwd = "/Users/amant",
        .scrollbar = .{
            .total = 200,
            .offset = 50,
            .len = 40,
        },
        .readonly = true,
        .secure_input = true,
        .key_sequence_active = true,
        .key_table_name = "resize",
        .search = .{
            .active = true,
            .needle = "foo",
            .total = 4,
            .selected = 2,
        },
        .progress = "progress:35%",
    });
    defer std.testing.allocator.free(title);

    try std.testing.expectEqualStrings(
        "pwsh | readonly | sensitive | keys | table:resize | cwd:/Users/amant | find:foo (2/4) | progress:35%",
        title,
    );
}

test "win32 buildWindowTitle uses default title when base is null" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildWindowTitle(std.testing.allocator, null, .{});
    defer std.testing.allocator.free(title);

    try std.testing.expectEqualStrings("noctty", title);
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
    try std.testing.expectEqual(@as(u8, 1), hiddenScrollbarAlphaByte());
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

test "win32 primarySurfaceIndex prefers active tab of first host" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const entries = [_]SurfaceOrderEntry{
        .{ .host_id = 11, .host_active = false },
        .{ .host_id = 22, .host_active = true },
        .{ .host_id = 11, .host_active = true },
    };
    try std.testing.expectEqual(@as(?usize, 2), primarySurfaceIndex(&entries));

    const fallback = [_]SurfaceOrderEntry{
        .{ .host_id = 11, .host_active = false },
        .{ .host_id = 22, .host_active = true },
    };
    try std.testing.expectEqual(@as(?usize, 0), primarySurfaceIndex(&fallback));
}

test "win32 buildHostAwareBaseTitle prefixes host tab position" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const titled = try buildHostAwareBaseTitle(std.testing.allocator, "pwsh", .{
        .index = 1,
        .total = 3,
    });
    defer std.testing.allocator.free(titled);
    try std.testing.expectEqualStrings("[2/3] pwsh", titled);

    const single = try buildHostAwareBaseTitle(std.testing.allocator, "pwsh", .{
        .index = 0,
        .total = 1,
    });
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("pwsh", single);
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
    try std.testing.expectEqualStrings("1: this-is-a-very-long-t...", title);
}

test "win32 compactHostLabel keeps the cut on a codepoint boundary" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Three-byte codepoints: a byte-wise cut at `max_len - 3` == 8 would
    // land on the last byte of the third character.
    const label = try compactHostLabel(std.testing.allocator, "\u{3042}\u{3044}\u{3046}\u{3048}\u{304a}", 11);
    defer std.testing.allocator.free(label);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label));
    try std.testing.expectEqualStrings("\u{3042}\u{3044}...", label);
}

test "win32 compactHostLabelLen matches the compacted label on a multi-byte cut" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const value = "\u{3042}\u{3044}\u{3046}\u{3048}\u{304a}";
    const label = try compactHostLabel(std.testing.allocator, value, 11);
    defer std.testing.allocator.free(label);
    try std.testing.expectEqual(label.len, compactHostLabelLen(value, 11));
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
    try std.testing.expectEqualStrings("1: \u{65e5}\u{672c}...", title);
}

test "win32 buildTabButtonLabel drops pane count when tabs are narrow" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const title = try buildTabButtonLabel(std.testing.allocator, "logs-and-output-pane", 1, false, 3, 9, false);
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("2: logs-a...", title);
}

test "win32 hostTabLabelMaxLen shrinks with narrow tab widths" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 24), hostTabLabelMaxLen(260));
    try std.testing.expectEqual(@as(usize, 9), hostTabLabelMaxLen(98));
    try std.testing.expectEqual(@as(usize, 6), hostTabLabelMaxLen(40));
    try std.testing.expect(shouldShowPaneCount(180, 3));
    try std.testing.expect(!shouldShowPaneCount(120, 3));
}

test "win32 visibleTabRange windows tabs around the active tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 0, .count = 3 }, visibleTabRange(6, 0, 324));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 2, .count = 3 }, visibleTabRange(6, 3, 324));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 3, .count = 3 }, visibleTabRange(6, 5, 324));
    try std.testing.expectEqualDeep(VisibleTabRange{ .start = 0, .count = 2 }, visibleTabRange(2, 1, 500));
}

test "win32 buildTabOverviewBannerText lists active tabs and pane counts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const banner = try buildTabOverviewBannerText(std.testing.allocator, &.{
        .{ .title = "pwsh", .pane_count = 1, .active = true },
        .{ .title = "logs-and-output-pane", .pane_count = 3, .active = false },
    });
    defer std.testing.allocator.free(banner);
    try std.testing.expectEqualStrings("Tabs: *1:pwsh | 2:logs-and-output... (3)", banner);
}

test "win32 buildSearchButtonLabel reflects active search state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildSearchButtonLabel(std.testing.allocator, true, 8, 2);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("[F] 2/8", active);

    const passive = try buildSearchButtonLabel(std.testing.allocator, false, 5, null);
    defer std.testing.allocator.free(passive);
    try std.testing.expectEqualStrings("Find 5", passive);

    const idle = try buildSearchButtonLabel(std.testing.allocator, false, null, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Find", idle);
}

test "win32 buildProfilesButtonLabel reflects selected cached profile" {
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
    };

    const active = try buildProfilesButtonLabel(std.testing.allocator, true, &profiles, 1, 1);
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("Pick Git Bash", active);

    const idle = try buildProfilesButtonLabel(std.testing.allocator, false, &profiles, 0, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Launch Power...", idle);
}

test "win32 profilesButtonKeyAction maps focused launcher keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(ProfilesButtonKeyAction.open, profilesButtonKeyAction(c.VK_RETURN).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.toggle, profilesButtonKeyAction(c.VK_SPACE).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.previous, profilesButtonKeyAction(c.VK_LEFT).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.next, profilesButtonKeyAction(c.VK_DOWN).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.first, profilesButtonKeyAction(c.VK_HOME).?);
    try std.testing.expectEqual(ProfilesButtonKeyAction.last, profilesButtonKeyAction(c.VK_END).?);
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

test "win32 quickSlotFocusKeyAction maps painted quick slot focus keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(QuickSlotFocusKeyAction.previous, quickSlotFocusKeyAction(c.VK_LEFT).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.previous, quickSlotFocusKeyAction(c.VK_UP).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.next, quickSlotFocusKeyAction(c.VK_RIGHT).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.next, quickSlotFocusKeyAction(c.VK_DOWN).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.first, quickSlotFocusKeyAction(c.VK_HOME).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.last, quickSlotFocusKeyAction(c.VK_END).?);
    try std.testing.expectEqual(QuickSlotFocusKeyAction.open, quickSlotFocusKeyAction(c.VK_RETURN).?);
    try std.testing.expect(quickSlotFocusKeyAction(c.VK_SPACE) == null);
}

test "win32 progress status and taskbar mapping clamp percent to shell range" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const report: terminal.osc.Command.ProgressReport = .{
        .state = .set,
        .progress = 255,
    };

    const mapped = win32_taskbar_progress.mapProgressReport(report);
    try std.testing.expectEqual(@as(u64, 100), mapped.value.?.completed);
    try std.testing.expectEqual(@as(u64, 100), mapped.value.?.total);

    const status = try formatProgressStatus(std.testing.allocator, report);
    defer if (status) |owned| std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("progress:100%", status.?);
}

test "win32 launchTargetButtonLabel reflects selected launcher slot" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pane = try launchTargetButtonLabel(std.testing.allocator, .split, 2, 2);
    defer std.testing.allocator.free(pane);
    try std.testing.expectEqualStrings("*3 Pane", pane);

    const tab = try launchTargetButtonLabel(std.testing.allocator, .tab, null, null);
    defer std.testing.allocator.free(tab);
    try std.testing.expectEqualStrings("Tab", tab);
}

test "win32 launchTargetButtonLabel reflects Windows-style target wording" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const tab = try launchTargetButtonLabel(std.testing.allocator, .tab, null, null);
    defer std.testing.allocator.free(tab);
    try std.testing.expectEqualStrings("Tab", tab);

    const win = try launchTargetButtonLabel(std.testing.allocator, .window, null, null);
    defer std.testing.allocator.free(win);
    try std.testing.expectEqualStrings("Win", win);

    const pane = try launchTargetButtonLabel(std.testing.allocator, .split, null, null);
    defer std.testing.allocator.free(pane);
    try std.testing.expectEqualStrings("Pane", pane);
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

test "win32 buildProfileDetailText reflects selected launcher state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .pwsh,
        .key = "pwsh.exe",
        .label = "PowerShell",
        .command = .{ .direct = &.{"pwsh.exe"} },
    };
    const profiles = [_]windows_shell.Profile{
        profile,
        .{
            .kind = .git_bash,
            .key = "git-bash",
            .label = "Git Bash",
            .command = .{ .direct = &.{"bash.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "wsl:Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
        },
    };

    const overlay = try buildProfileDetailText(std.testing.allocator, &profile, &profiles, true, .split, "git,pwsh,Ubuntu,cmd", .{ "pwsh.exe", "git-bash", null });
    defer std.testing.allocator.free(overlay);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Selected profile: PWSH >> PowerShell") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Run pwsh.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Pinned slot 1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "opens a split") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Alt+1-3 launches visible slots") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Alt+Shift+1-3 pins the current profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Alt+Shift+0 clears pinning") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Quick picks: 1 PWSH >> PowerShell") != null);
    try std.testing.expect(std.mem.indexOf(u8, overlay, "Order: git > pwsh > Ubuntu > cmd.") != null);

    const idle = try buildProfileDetailText(std.testing.allocator, &profile, &profiles, false, .window, "git,pwsh,Ubuntu,cmd", .{ "pwsh.exe", "git-bash", null });
    defer std.testing.allocator.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Default profile: PWSH >> PowerShell") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Run pwsh.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Pinned slot 1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "New hosts inherit this PowerShell profile with automatic shell integration.") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "opens a new window") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Alt+1-3 launches visible slots") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Alt+Shift+1-3 pins the current profile") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Alt+Shift+0 clears pinning") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Top slots: 1 PWSH >>") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "2 GIT $> Git Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Order: git > pwsh > Ubuntu > cmd.") != null);
}

test "win32 buildProfileDetailText appends shell integration guidance when present" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .wsl_default,
        .key = "wsl.exe",
        .label = "WSL",
        .command = .{ .direct = &.{"wsl.exe"} },
    };

    const detail = try buildProfileDetailText(
        std.testing.allocator,
        &profile,
        &.{profile},
        false,
        .tab,
        null,
        .{ null, null, null },
    );
    defer std.testing.allocator.free(detail);

    try std.testing.expect(std.mem.indexOf(
        u8,
        detail,
        "New hosts inherit this WSL default profile; shell integration depends on the Linux shell.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        detail,
        "Enable shell integration inside the selected WSL shell startup.",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "+ opens a new tab") != null);
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

test "win32 buildProfileOrderSummaryText compacts launcher order" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const summary = (try buildProfileOrderSummaryText(
        std.testing.allocator,
        "git,pwsh,Ubuntu,cmd,powershell",
        4,
    )).?;
    defer std.testing.allocator.free(summary);
    try std.testing.expectEqualStrings("git > pwsh > Ubuntu > cmd > ...", summary);
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

test "win32 buildProfileStatusBadgeText reflects selected profile kind" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .git_bash,
        .key = "git-bash",
        .label = "Git Bash",
        .command = .{ .direct = &.{"bash.exe"} },
    };

    const badge = try buildProfileStatusBadgeText(std.testing.allocator, &profile, 0, 0);
    defer std.testing.allocator.free(badge);
    try std.testing.expectEqualStrings("Git Bash", badge);
}

test "win32 profileStatusBadgeTextLen matches built text" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .git_bash,
        .key = "git-bash",
        .label = "Git Bash",
        .command = .{ .direct = &.{"bash.exe"} },
    };

    const badge = try buildProfileStatusBadgeText(std.testing.allocator, &profile, 0, 0);
    defer std.testing.allocator.free(badge);
    try std.testing.expectEqual(badge.len, profileStatusBadgeTextLen(&profile, 0, 0));
}

test "win32 buildProfileQuickSlotChipText reflects ordered quick slot badge" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .wsl_distro,
        .key = "wsl:Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
    };

    const chip = try buildProfileQuickSlotChipText(std.testing.allocator, &profile, 2, 2);
    defer std.testing.allocator.free(chip);
    try std.testing.expectEqualStrings("*3 WSL", chip);
}

test "win32 profileQuickSlotChipTextLen matches built text" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const profile: windows_shell.Profile = .{
        .kind = .wsl_distro,
        .key = "wsl:Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu" } },
    };

    const pinned = try buildProfileQuickSlotChipText(std.testing.allocator, &profile, 2, 2);
    defer std.testing.allocator.free(pinned);
    try std.testing.expectEqual(pinned.len, profileQuickSlotChipTextLen(&profile, 2, 2));

    const unpinned = try buildProfileQuickSlotChipText(std.testing.allocator, &profile, 1, null);
    defer std.testing.allocator.free(unpinned);
    try std.testing.expectEqual(unpinned.len, profileQuickSlotChipTextLen(&profile, 1, null));
}

test "win32 launcherChipRightInset reserves badge and target space" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(i32, 5), launcherChipRightInset(false, false));
    try std.testing.expectEqual(@as(i32, 12), launcherChipRightInset(false, true));
    try std.testing.expectEqual(@as(i32, 16), launcherChipRightInset(true, false));
    try std.testing.expectEqual(@as(i32, 16), launcherChipRightInset(true, true));
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

test "win32 shouldPaintQuickSlotTargetMarker follows active chip state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!shouldPaintQuickSlotTargetMarker(false, false));
    try std.testing.expect(shouldPaintQuickSlotTargetMarker(true, false));
    try std.testing.expect(shouldPaintQuickSlotTargetMarker(false, true));
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

test "win32 profileKindDetail exposes shell integration posture" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pwsh = profileKindDetail(.pwsh);
    try std.testing.expectEqualStrings(
        "PowerShell profile with automatic shell integration",
        pwsh.summary,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), pwsh.next_step);

    const wsl = profileKindDetail(.wsl_distro);
    try std.testing.expectEqualStrings(
        "WSL distro profile; shell integration depends on the Linux shell",
        wsl.summary,
    );
    try std.testing.expectEqualStrings(
        "Enable shell integration inside the selected WSL shell startup.",
        wsl.next_step.?,
    );

    const git_bash = profileKindDetail(.git_bash);
    try std.testing.expectEqualStrings(
        "Git Bash profile with automatic shell integration",
        git_bash.summary,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), git_bash.next_step);

    const cmd = profileKindDetail(.cmd);
    try std.testing.expectEqualStrings(
        "Command Prompt profile with PROMPT-based shell integration; Clink adds command-start/finish and exit-code marks",
        cmd.summary,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), cmd.next_step);
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

test "win32 profileChromeNeedsFullTextInvalidation only trips for status-only profile chrome" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!profileChromeNeedsFullTextInvalidation(.profile, 0));
    try std.testing.expect(!profileChromeNeedsFullTextInvalidation(.profile, 24));
    try std.testing.expect(!profileChromeNeedsFullTextInvalidation(.none, 0));
    try std.testing.expect(profileChromeNeedsFullTextInvalidation(.none, 24));
}

test "win32 chromeTextNeedsFullInvalidation only trips when status bar is visible" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!chromeTextNeedsFullInvalidation(0));
    try std.testing.expect(chromeTextNeedsFullInvalidation(24));
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
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Window title", title);
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

test "win32 searchDirectionFromWheelDelta maps wheel direction to search navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(input.Binding.Action.NavigateSearch.next, searchDirectionFromWheelDelta(120));
    try std.testing.expectEqual(input.Binding.Action.NavigateSearch.previous, searchDirectionFromWheelDelta(-120));
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

test "win32 scrollStatusTextChanged only trips on indicator visibility or percent deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const hidden_bottom: terminal.Scrollbar = .{ .total = 2000, .len = 21, .offset = 1979 };
    const hidden_short: terminal.Scrollbar = .{ .total = 21, .len = 21, .offset = 0 };
    const visible_50: terminal.Scrollbar = .{ .total = 2000, .len = 21, .offset = 1000 };
    const visible_50_neighbor: terminal.Scrollbar = .{ .total = 2000, .len = 21, .offset = 1001 };
    const visible_51: terminal.Scrollbar = .{ .total = 2000, .len = 21, .offset = 1020 };

    try std.testing.expect(!scrollStatusTextChanged(hidden_short, hidden_bottom));
    try std.testing.expect(scrollStatusTextChanged(hidden_bottom, visible_50));
    try std.testing.expect(!scrollStatusTextChanged(visible_50, visible_50_neighbor));
    try std.testing.expect(scrollStatusTextChanged(visible_50, visible_51));
}

test "win32 commandPaletteDirectionFromWheelDelta maps wheel direction to completion direction" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(commandPaletteDirectionFromWheelDelta(120));
    try std.testing.expect(!commandPaletteDirectionFromWheelDelta(-120));
}

test "win32 profileDirectionFromWheelDelta maps wheel direction to profile navigation" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(profileDirectionFromWheelDelta(120));
    try std.testing.expect(!profileDirectionFromWheelDelta(-120));
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
        input.Binding.Action.NavigateSearch.next,
        dockedSearchCoreDirectionFromKeyAction(.next).?,
    );
    try std.testing.expectEqual(
        input.Binding.Action.NavigateSearch.previous,
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

test "win32 tabsButtonKeyAction maps focused tabs button keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(TabsButtonKeyAction.previous, tabsButtonKeyAction(c.VK_LEFT).?);
    try std.testing.expectEqual(TabsButtonKeyAction.previous, tabsButtonKeyAction(c.VK_UP).?);
    try std.testing.expectEqual(TabsButtonKeyAction.next, tabsButtonKeyAction(c.VK_RIGHT).?);
    try std.testing.expectEqual(TabsButtonKeyAction.next, tabsButtonKeyAction(c.VK_DOWN).?);
    try std.testing.expectEqual(TabsButtonKeyAction.rename, tabsButtonKeyAction(c.VK_F2).?);
    try std.testing.expectEqual(TabsButtonKeyAction.overview, tabsButtonKeyAction(c.VK_APPS).?);
    try std.testing.expect(tabsButtonKeyAction(c.VK_RETURN) == null);
}

test "win32 commandButtonKeyAction maps focused command button keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(CommandButtonKeyAction.toggle, commandButtonKeyAction(c.VK_RETURN).?);
    try std.testing.expectEqual(CommandButtonKeyAction.toggle, commandButtonKeyAction(c.VK_SPACE).?);
    try std.testing.expectEqual(CommandButtonKeyAction.previous, commandButtonKeyAction(c.VK_UP).?);
    try std.testing.expectEqual(CommandButtonKeyAction.next, commandButtonKeyAction(c.VK_DOWN).?);
    try std.testing.expectEqual(CommandButtonKeyAction.dismiss, commandButtonKeyAction(c.VK_ESCAPE).?);
    try std.testing.expect(commandButtonKeyAction(c.VK_F2) == null);
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

test "win32 buildInspectorBannerText reflects host inspector context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildInspectorBannerText(std.testing.allocator, .{ .index = 1, .total = 4 }, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("Inspector active | tab 2/4 | panes 3 | toggle Inspect to return", multi);

    const zoomed = try buildInspectorBannerText(std.testing.allocator, .{ .index = 0, .total = 2 }, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expectEqualStrings("Inspector active | tab 1/2 | panes 2 | zoomed | toggle Inspect to return", zoomed);

    const single = try buildInspectorBannerText(std.testing.allocator, .{ .index = 0, .total = 1 }, 1, false);
    defer std.testing.allocator.free(single);
    try std.testing.expectEqualStrings("Inspector active | tab 1/1 | toggle Inspect to return", single);
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

test "win32 profileChromeVisible only trips for profile overlay or visible status bar" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(profileChromeVisible(.profile, 0));
    try std.testing.expect(profileChromeVisible(.none, 24));
    try std.testing.expect(!profileChromeVisible(.none, 0));
    try std.testing.expect(!profileChromeVisible(.search, 0));
}

test "win32 inspector chrome visibility only trips for banner or visible status bar" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(inspectorChromeVisible(.none, 0));
    try std.testing.expect(inspectorChromeVisible(.search, 24));
    try std.testing.expect(!inspectorChromeVisible(.search, 0));
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
        nextVisibleOverlayFocusSlot(.profile, .edit, false, true, false, true),
    );
    try std.testing.expectEqual(
        OverlayFocusSlot.cancel,
        nextVisibleOverlayFocusSlot(.confirm, .accept, false, false, false, true),
    );
    try std.testing.expectEqual(
        OverlayFocusSlot.accept,
        nextVisibleOverlayFocusSlot(.confirm, .cancel, true, false, true, true),
    );
    try std.testing.expectEqual(
        null,
        nextVisibleOverlayFocusSlot(.command_palette, .edit, false, true, false, false),
    );
    try std.testing.expectEqual(
        null,
        nextVisibleOverlayFocusSlot(.confirm, .cancel, false, false, false, true),
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

test "win32 buildInspectorDetailText reflects pane and zoom context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const multi = try buildInspectorDetailText(std.testing.allocator, .{ .index = 1, .total = 4 }, 3, false);
    defer std.testing.allocator.free(multi);
    try std.testing.expect(std.mem.indexOf(u8, multi, "tab 2/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "3 panes") != null);

    const zoomed = try buildInspectorDetailText(std.testing.allocator, .{ .index = 0, .total = 2 }, 2, true);
    defer std.testing.allocator.free(zoomed);
    try std.testing.expect(std.mem.indexOf(u8, zoomed, "zoom") != null);
}

test "win32 buildSearchDetailText reflects live search context" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildSearchDetailText(std.testing.allocator, "needle", 8, 2);
    defer std.testing.allocator.free(active);
    try std.testing.expect(std.mem.indexOf(u8, active, "needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, active, "2 of 8") != null);

    const pending = try buildSearchDetailText(std.testing.allocator, "logs", null, null);
    defer std.testing.allocator.free(pending);
    try std.testing.expect(std.mem.indexOf(u8, pending, "refine") != null);
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

test "win32 buildCommandButtonLabel reflects live palette state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const active = try buildCommandButtonLabel(std.testing.allocator, true, "toggle_fullscreen");
    defer std.testing.allocator.free(active);
    try std.testing.expectEqualStrings("Cmd toggle...", active);

    const armed = try buildCommandButtonLabel(std.testing.allocator, true, "");
    defer std.testing.allocator.free(armed);
    try std.testing.expectEqualStrings("[Cmd]", armed);

    const idle = try buildCommandButtonLabel(std.testing.allocator, false, null);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Cmd", idle);
}

test "win32 buildInspectorButtonLabel reflects inspector and pane state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const visible = try buildInspectorButtonLabel(std.testing.allocator, true, 3);
    defer std.testing.allocator.free(visible);
    try std.testing.expectEqualStrings("[Inspect 3]", visible);

    const multi = try buildInspectorButtonLabel(std.testing.allocator, false, 2);
    defer std.testing.allocator.free(multi);
    try std.testing.expectEqualStrings("Inspect 2", multi);

    const idle = try buildInspectorButtonLabel(std.testing.allocator, false, 1);
    defer std.testing.allocator.free(idle);
    try std.testing.expectEqualStrings("Inspect", idle);
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

test "win32 commandPaletteCompletionCandidate resolves and cycles defaults" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const snap = PaletteSnapshot.fromDefaults();

    try std.testing.expectEqualStrings(
        "reload_config",
        commandPaletteCompletionCandidate(snap, "reload_", "reload_", false).?,
    );

    // toggle_* has multiple matches in defaults; first-next/reverse should
    // land on entries that all begin with "toggle_".
    const first = commandPaletteCompletionCandidate(snap, "toggle_", "toggle_", false).?;
    try std.testing.expect(std.mem.startsWith(u8, first, "toggle_"));

    const second = commandPaletteCompletionCandidate(snap, "toggle_", first, false).?;
    try std.testing.expect(std.mem.startsWith(u8, second, "toggle_"));
    try std.testing.expect(!std.mem.eql(u8, first, second));

    const reverse = commandPaletteCompletionCandidate(snap, "toggle_", first, true).?;
    try std.testing.expect(std.mem.startsWith(u8, reverse, "toggle_"));
    try std.testing.expect(!std.mem.eql(u8, reverse, first));
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
