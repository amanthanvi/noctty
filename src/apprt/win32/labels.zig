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
const paint_text = @import("text.zig");
const profile_pick = @import("profile_pick.zig");
const tab_label = @import("tab_label.zig");

const HostOverlayMode = win32_theme.HostOverlayMode;
const OpenTarget = profile_pick.OpenTarget;
const rgb = win32_theme.rgb;
const PaletteSnapshot = win32_palette.Snapshot;
const RankedIndex = win32_palette.RankedIndex;
const PaletteStableId = @TypeOf((@as(win32_palette.catalog.Item, undefined)).id);
const palette_max_tokens = win32_palette.max_tokens;
const palette_max_ranked = win32_palette.max_ranked;
const tokenizePaletteQuery = win32_palette.tokenizeQuery;
const rankPaletteEntry = win32_palette.rankEntry;
const rankedIndicesForQuery = win32_palette.rankedForQuery;
const RECT = win32_types.RECT;
const ownedStringEquals = paint_text.ownedStringEquals;
const compactHostLabel = paint_text.compactHostLabel;
const WPARAM = usize;

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

pub const host_banner_inspector_inactive = "Inspector hidden. Terminal view is active.";

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

/// Keyboard focus stops inside the overlay row, in tab order.
/// `preview` is the confirm pane: it takes focus so a keyboard user
/// can scroll the payload before deciding, and so that clicking it
/// to scroll does not strand focus outside the cycle.
pub const OverlayFocusSlot = enum { edit, preview, accept, cancel };

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

pub fn buildTabOverviewOverlayLabel(
    alloc: Allocator,
    current_index: usize,
    total: usize,
) ![]u8 {
    if (total <= 1) return try alloc.dupe(u8, "Tab");
    return try std.fmt.allocPrint(alloc, "Tab {d}/{d}", .{ current_index + 1, total });
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

pub fn buildOverlayPaintLabelText(
    alloc: Allocator,
    mode: HostOverlayMode,
    input_text: []const u8,
    host_status: tab_label.TabStatus,
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
        .search => try alloc.dupe(u8, "Find"),
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
    host_status: tab_label.TabStatus,
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
        .search => if (input_text.len == 0)
            try alloc.dupe(u8, "Close")
        else
            try alloc.dupe(u8, "Find"),
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
    host_status: tab_label.TabStatus,
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
        .search => if (input_text.len == 0)
            try alloc.dupe(u8, "Type to search live. Enter repeats the current match. Escape closes.")
        else
            try alloc.dupe(u8, "No matches yet. Keep typing to search live."),
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

fn profileKindBadge(kind: windows_shell.ProfileKind) []const u8 {
    return switch (kind) {
        .wsl_default, .wsl_distro => "WSL",
        .pwsh => "PWSH",
        .powershell => "PS",
        .git_bash => "GIT",
        .cmd => "CMD",
        .ssh => "SSH",
        .user => "USER",
        .vs_dev_cmd, .vs_dev_shell => "VS",
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
        // A profile of the user's own: no shell is implied.
        .user => "*>",
        // The shell each one runs, as for cmd and Windows PowerShell.
        .vs_dev_cmd => "C>",
        .vs_dev_shell => ">_",
    };
}

pub fn buildProfileChromeBadgeText(alloc: Allocator, kind: windows_shell.ProfileKind) ![]u8 {
    return try std.fmt.allocPrint(alloc, "{s} {s}", .{
        profileKindBadge(kind),
        profileKindGlyph(kind),
    });
}

fn profileOpenTargetActionText(target: OpenTarget) []const u8 {
    return switch (target) {
        .tab => "new tab",
        .window => "new window",
        .split => "split",
    };
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
    return switch (profile_pick.byTyped(profiles, input_text, selected_index)) {
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
    default_target: OpenTarget,
) ![]u8 {
    const profiles = profiles_opt orelse return try alloc.dupe(u8, "Check");
    if (profiles.len == 0) return try alloc.dupe(u8, "Check");
    return switch (profile_pick.byTyped(profiles, input_text, selected_index)) {
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
    default_target: OpenTarget,
    pinned_slot_keys: [profile_pick.quick_slots]?[:0]const u8,
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
    return switch (profile_pick.byTyped(profiles, input_text, selected_index)) {
        .exact => |index| blk: {
            const preview = try buildProfileCommandPreviewText(alloc, &profiles[index], 36);
            defer alloc.free(preview);
            const badge = try buildProfileChromeBadgeText(alloc, profiles[index].kind);
            defer alloc.free(badge);
            const pinned_slot = try buildPinnedProfileSlotText(
                alloc,
                profile_pick.pinByKey(&pinned_slot_keys, profiles[index].key),
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

test "win32 buildProfileChromeBadgeText adds profile glyph treatment" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const pwsh = try buildProfileChromeBadgeText(std.testing.allocator, .pwsh);
    defer std.testing.allocator.free(pwsh);
    try std.testing.expectEqualStrings("PWSH >>", pwsh);

    const wsl = try buildProfileChromeBadgeText(std.testing.allocator, .wsl_distro);
    defer std.testing.allocator.free(wsl);
    try std.testing.expectEqualStrings("WSL <>", wsl);
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
        .{},
        .{},
        null,
    );
    defer std.testing.allocator.free(search);
    try std.testing.expectEqualStrings("Find", search);

    const title = try buildOverlayPaintLabelText(
        std.testing.allocator,
        .surface_title,
        "",
        .{},
        .{},
        null,
    );
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("Window title", title);
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
        .{},
        1,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("", body);
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
        .{},
        1,
        snap,
        empty_mru,
        .{},
        null,
    );
    defer std.testing.allocator.free(fallback);
    // With no banner the line is the mode's own hint.
    try std.testing.expectEqualStrings("No matches yet. Keep typing to search live.", fallback);
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

    const palette_idle = try buildOverlayAcceptLabel(std.testing.allocator, .command_palette, "", .{});
    defer std.testing.allocator.free(palette_idle);
    try std.testing.expectEqualStrings("Close", palette_idle);

    const palette_run = try buildOverlayAcceptLabel(
        std.testing.allocator,
        .command_palette,
        "new_tab",
        .{ .match_count = 1, .title = "New tab", .subtitle = "Action", .available = true },
    );
    defer std.testing.allocator.free(palette_run);
    try std.testing.expectEqualStrings("Activate", palette_run);

    const palette_matches = try buildOverlayAcceptLabel(
        std.testing.allocator,
        .command_palette,
        "0x96f",
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    );
    defer std.testing.allocator.free(palette_matches);
    try std.testing.expectEqualStrings("Activate", palette_matches);

    const palette_hidden = try buildOverlayAcceptLabel(
        std.testing.allocator,
        .command_palette,
        "0x96f",
        .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme" },
    );
    defer std.testing.allocator.free(palette_hidden);
    try std.testing.expectEqualStrings("Resize", palette_hidden);

    const search_find = try buildOverlayAcceptLabel(std.testing.allocator, .search, "other", .{});
    defer std.testing.allocator.free(search_find);
    try std.testing.expectEqualStrings("Find", search_find);

    const tab_go = try buildOverlayAcceptLabel(std.testing.allocator, .tab_overview, "2", .{});
    defer std.testing.allocator.free(tab_go);
    try std.testing.expectEqualStrings("Go", tab_go);

    const title_apply = try buildOverlayAcceptLabel(std.testing.allocator, .surface_title, "logs", .{});
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
        .{},
        1,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(command_unique);
    try std.testing.expect(std.mem.indexOf(u8, command_unique, "reload_config") != null);

    const search_typed = try buildOverlayHintText(
        std.testing.allocator,
        .search,
        "needle",
        .{},
        1,
        snap,
        empty_mru,
        null,
    );
    defer std.testing.allocator.free(search_typed);
    try std.testing.expectEqualStrings("No matches yet. Keep typing to search live.", search_typed);

    const tab_invalid = try buildOverlayHintText(
        std.testing.allocator,
        .tab_overview,
        "8",
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
