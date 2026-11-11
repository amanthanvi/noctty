//! What the host overlay says and shows in each mode: the text of its label,
//! Accept, Cancel and hint controls and the label, feedback line and profile
//! badge chrome paint draws (`compose`), the "Info: " and "Error: " spelling of
//! a banner (`bannerLine`), which controls a mode has and what it does with an
//! empty query or a tab switch (`shape`), and where Tab moves keyboard focus
//! (`nextFocus`). `Host.overlayFacts` in overlay_session.zig fills the `Facts`
//! from the Host, its App and the active terminal. Nothing here touches a
//! window.
const std = @import("std");
const Allocator = std.mem.Allocator;
const windows_shell = @import("../../config/windows_shell.zig");
const win32_theme = @import("../win32_theme.zig");
const paint_text = @import("text.zig");
const profile_pick = @import("profile_pick.zig");
const tab_label = @import("tab_label.zig");

const Mode = win32_theme.HostOverlayMode;
const compactHostLabel = paint_text.compactHostLabel;

pub const BannerKind = enum {
    none,
    info,
    err,
};

/// What the overlay's text is made from. Its strings are borrowed from the
/// Host (the query, the confirm payload, the palette rows, the profile list);
/// the `Text` that `compose` returns may borrow the confirm prompt's words,
/// so use it before the payload is dropped.
pub const Facts = struct {
    mode: Mode,
    /// The query, trimmed (`Host.overlayFacts` trims the EDIT's text).
    typed: []const u8 = "",
    banner_kind: BannerKind = .none,
    banner: ?[]const u8 = null,
    /// Where the active terminal's tab sits.
    tab: tab_label.TabStatus = .{},
    /// Panes in the active tab.
    pane_count: usize = 1,
    palette: Presentation = .{},
    /// The palette's hint line is on (`command-palette-hint`).
    palette_hint: bool = true,
    /// The newest palette action, if any.
    recent: ?[]const u8 = null,
    profiles: Profiles = .unavailable,
    /// The open confirm prompt's words. Null once its payload is dropped,
    /// which teardown does before the last repaint.
    confirm: ?Confirm = null,

    /// The palette's ranked results as its list shows them.
    pub const Presentation = struct {
        match_count: usize = 0,
        /// The selected row's title and subtitle.
        title: ?[]const u8 = null,
        subtitle: ?[]const u8 = null,
        /// A row is on screen, so Enter has one to activate.
        available: bool = false,
    };

    /// The profile list the picker shows.
    pub const Profiles = union(enum) {
        /// No profile to show: none was asked for, or the list is empty.
        unavailable,
        /// No list yet: discovery was asked for.
        detecting,
        shown: struct {
            /// The shown profiles (`Host.shownProfiles`), never empty.
            list: []const windows_shell.Profile,
            /// The selected one (`Host.selectedProfileIndex`).
            selected: usize,
            /// Where Enter opens the pick.
            target: profile_pick.OpenTarget,
            /// The keys pinned to the quick slots.
            pinned: [profile_pick.quick_slots]?[:0]const u8,
        },
    };

    /// What `confirm_text` worded for the prompt.
    pub const Confirm = struct {
        title: []const u8,
        body: []const u8,
        accept: []const u8,
        cancel: []const u8,
        /// The size of the payload the preview pane shows
        /// (`confirm_text.Preview.caption`); empty when there is none.
        caption: []const u8 = "",
    };
};

/// Every line the overlay shows. The controls (`label`, `buttons`, `hint`)
/// and chrome paint (`paint_label`, `feedback`, `badge`) read the same facts
/// and still differ where they always have: paint's label drops the label
/// control's colon, and paint's feedback line puts a banner first and says
/// nothing of a discovery in progress. A confirm prompt's `hint` and
/// `feedback` are one line, banner included.
pub const Text = struct {
    /// The label control's text, or null to leave the control as it is
    /// (search).
    label: ?[]const u8,
    /// The label chrome paint draws.
    paint_label: []const u8,
    /// The Accept and Cancel buttons' text, or null to leave both as they
    /// are (a confirm prompt whose payload is gone).
    buttons: ?Buttons,
    /// The hint control's text.
    hint: []const u8,
    /// The feedback line chrome paint draws.
    feedback: []const u8,
    /// The profile badge chrome paint draws: null outside the profile
    /// overlay and while no profile is shown.
    badge: ?[]const u8,
};

const Buttons = struct { accept: []const u8, cancel: []const u8 };

/// The overlay's text for `facts`, allocated in `arena` where it is not a
/// constant.
pub fn compose(arena: Allocator, facts: Facts) Allocator.Error!Text {
    const hint = try hintLine(arena, facts);
    return .{
        .label = try controlLabel(arena, facts),
        .paint_label = try paintLabel(arena, facts),
        .buttons = buttons(facts),
        .hint = hint,
        .feedback = try feedbackLine(arena, facts, hint),
        .badge = try profileBadge(arena, facts),
    };
}

/// A banner message as the banner and the overlay's feedback line draw it.
pub fn bannerLine(alloc: Allocator, kind: BannerKind, text: []const u8) Allocator.Error![]u8 {
    return switch (kind) {
        .none => try alloc.dupe(u8, text),
        .info => try std.fmt.allocPrint(alloc, "Info: {s}", .{text}),
        .err => try std.fmt.allocPrint(alloc, "Error: {s}", .{text}),
    };
}

pub const Shape = struct {
    /// The Accept button is shown. The palette's Enter activates its
    /// selected row instead.
    accept_visible: bool,
    /// The query EDIT and its painted frame are shown. A confirm prompt has
    /// no query, so its focus starts on a button.
    edit_visible: bool,
    /// Enter on an empty query closes the overlay. A confirm prompt's EDIT
    /// is hidden and always empty, so closing on "empty" would run neither
    /// of its callbacks and strand the caller's pending operation.
    empty_submit_dismisses: bool,
    /// The text is filled from the active surface and written back to it,
    /// so it refills when the active surface changes, or submit writes one
    /// surface's title onto another.
    follows_active_surface: bool,
};

/// Which controls `mode` shows and what it does with an empty query and a
/// tab switch. Every mode states each answer: none is inherited.
pub fn shape(mode: Mode) Shape {
    return switch (mode) {
        .none, .tab_overview => .{
            .accept_visible = true,
            .edit_visible = true,
            .empty_submit_dismisses = true,
            .follows_active_surface = false,
        },
        .command_palette => .{
            .accept_visible = false,
            .edit_visible = true,
            .empty_submit_dismisses = false,
            .follows_active_surface = false,
        },
        .profile, .search => .{
            .accept_visible = true,
            .edit_visible = true,
            .empty_submit_dismisses = false,
            .follows_active_surface = false,
        },
        .surface_title, .tab_title => .{
            .accept_visible = true,
            .edit_visible = true,
            .empty_submit_dismisses = true,
            .follows_active_surface = true,
        },
        .confirm => .{
            .accept_visible = true,
            .edit_visible = false,
            .empty_submit_dismisses = false,
            .follows_active_surface = false,
        },
    };
}

/// The overlay band has its second row, the line under the query, which
/// says what `compose`'s `feedback` says. Only the command palette goes
/// without it: with its hint line off (`palette_hint`) it has nothing to say
/// there until a message is raised (`banner`), which has no other place on
/// screen while an overlay is open (`Host.bannerShown`).
pub fn feedbackRow(mode: Mode, palette_hint: bool, banner: bool) bool {
    return mode != .command_palette or palette_hint or banner;
}

/// Keyboard focus stops inside the overlay row, in tab order.
/// `preview` is the confirm pane: it takes focus so a keyboard user
/// can scroll the payload before deciding, and so that clicking it
/// to scroll does not strand focus outside the cycle.
pub const Slot = enum { edit, preview, accept, cancel };

/// Which of the ring's stops are visible.
const Visible = struct { edit: bool, preview: bool, accept: bool, cancel: bool };

/// The next visible stop after `from` in `mode`'s ring, or null when no
/// other stop is visible.
pub fn nextFocus(mode: Mode, from: Slot, reverse: bool, visible: Visible) ?Slot {
    var candidate = from;
    // One iteration per slot: a full lap proves nothing else is visible.
    for (0..@typeInfo(Slot).@"enum".fields.len) |_| {
        candidate = ringStep(mode, candidate, reverse);
        const shown = switch (candidate) {
            .edit => visible.edit,
            .preview => visible.preview,
            .accept => visible.accept,
            .cancel => visible.cancel,
        };
        if (candidate != from and shown) return candidate;
    }
    return null;
}

fn ringStep(mode: Mode, current: Slot, reverse: bool) Slot {
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
    if (!shape(mode).accept_visible) return if (current == .edit) .cancel else .edit;
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

fn controlLabel(arena: Allocator, facts: Facts) Allocator.Error!?[]const u8 {
    return switch (facts.mode) {
        .none => "Command:",
        .command_palette => try paletteLabel(arena, facts),
        .profile => switch (facts.profiles) {
            .shown => try profileLabel(arena, facts),
            .unavailable, .detecting => "Profile:",
        },
        .search => null,
        .surface_title => "Window title:",
        .tab_title => "Tab title:",
        .tab_overview => try tabOverviewLabel(arena, facts.tab),
        .confirm => confirmTitle(facts),
    };
}

fn paintLabel(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    return switch (facts.mode) {
        .none => "",
        .command_palette => try paletteLabel(arena, facts),
        .profile => try profileLabel(arena, facts),
        .search => "Find",
        .surface_title => "Window title",
        .tab_title => "Tab title",
        .tab_overview => try tabOverviewLabel(arena, facts.tab),
        .confirm => confirmTitle(facts),
    };
}

/// A confirm prompt's title is its payload's: a prompt has no fixed wording,
/// so the caller's title is what says what is being confirmed. The
/// placeholder is for a payload already dropped.
fn confirmTitle(facts: Facts) []const u8 {
    return if (facts.confirm) |confirm| confirm.title else "Confirm";
}

fn buttons(facts: Facts) ?Buttons {
    const typed = facts.typed;
    return switch (facts.mode) {
        // The exact words the caller chose, such as "Close" for a
        // destructive Accept.
        .confirm => if (facts.confirm) |confirm| .{ .accept = confirm.accept, .cancel = confirm.cancel } else null,
        .none => .{ .accept = "OK", .cancel = "Cancel" },
        .command_palette => .{ .accept = paletteAccept(facts), .cancel = "Close" },
        .profile => .{ .accept = profileAccept(facts), .cancel = "Close" },
        .search => .{ .accept = if (typed.len == 0) "Close" else "Find", .cancel = "Close" },
        .surface_title, .tab_title => .{ .accept = if (typed.len == 0) "Close" else "Apply", .cancel = "Cancel" },
        .tab_overview => .{ .accept = if (typed.len == 0) "Close" else "Go", .cancel = "Close" },
    };
}

fn hintLine(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    const typed = facts.typed;
    const tab = facts.tab;
    return switch (facts.mode) {
        .none => "",
        .command_palette => if (facts.palette_hint) try paletteFeedback(arena, facts) else "",
        .profile => if (facts.profiles == .detecting)
            "Detecting Windows profiles..."
        else
            try profileHint(arena, facts),
        .search => if (typed.len == 0)
            "Type to search live. Enter repeats the current match. Escape closes."
        else
            "No matches yet. Keep typing to search live.",
        .surface_title => "Apply a window title override for this host. Submit empty text to clear it.",
        .tab_title => if (facts.pane_count > 1)
            try std.fmt.allocPrint(
                arena,
                "Rename tab {d}/{d}. This tab currently has {d} panes. Submit empty text to clear the override.",
                .{ tab.index + 1, tab.total, facts.pane_count },
            )
        else
            try std.fmt.allocPrint(
                arena,
                "Rename tab {d}/{d}. Submit empty text to clear the override.",
                .{ tab.index + 1, tab.total },
            ),
        .tab_overview => blk: {
            if (tab.total <= 1) break :blk "Only one tab is open in this window.";
            if (typed.len == 0) {
                break :blk try std.fmt.allocPrint(
                    arena,
                    "Jump directly to a tab number. Current tab: {d}/{d}.",
                    .{ tab.index + 1, tab.total },
                );
            }
            const requested = std.fmt.parseUnsigned(usize, typed, 10) catch {
                break :blk try std.fmt.allocPrint(
                    arena,
                    "Enter a tab number from 1 to {d}. Current tab: {d}/{d}.",
                    .{ tab.total, tab.index + 1, tab.total },
                );
            };
            if (requested == 0 or requested > tab.total) {
                break :blk try std.fmt.allocPrint(
                    arena,
                    "Tab {d} is out of range. Valid range: 1 to {d}.",
                    .{ requested, tab.total },
                );
            }
            break :blk try std.fmt.allocPrint(
                arena,
                "Jump to tab {d} of {d}.",
                .{ requested, tab.total },
            );
        },
        .confirm => try confirmBody(arena, facts),
    };
}

fn feedbackLine(arena: Allocator, facts: Facts, hint: []const u8) Allocator.Error![]const u8 {
    // The body STATIC shows the hint, and paint draws the same line where
    // that control cannot be placed, so a screen reader never says what the
    // screen does not.
    if (facts.mode == .confirm) return hint;
    if (facts.banner) |banner| return try bannerLine(arena, facts.banner_kind, banner);
    // Paint says what the list holds while discovery runs.
    if (facts.mode == .profile and facts.profiles == .detecting) return try profileHint(arena, facts);
    return hint;
}

/// The confirm prompt's body line: a banner raised while the prompt is
/// open, else the payload's body and the size of what the preview pane
/// shows, which may be only its head.
fn confirmBody(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    if (facts.banner) |banner| return try bannerLine(arena, facts.banner_kind, banner);
    const confirm = facts.confirm orelse return "";
    if (confirm.caption.len == 0) return confirm.body;
    return try std.fmt.allocPrint(arena, "{s}  ({s})", .{ confirm.body, confirm.caption });
}

fn tabOverviewLabel(arena: Allocator, tab: tab_label.TabStatus) Allocator.Error![]const u8 {
    if (tab.total <= 1) return "Tab";
    return try std.fmt.allocPrint(arena, "Tab {d}/{d}", .{ tab.index + 1, tab.total });
}

fn paletteLabel(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    if (facts.typed.len == 0) return "Command";
    if (facts.palette.match_count > 0) {
        return try std.fmt.allocPrint(arena, "Command {d}", .{facts.palette.match_count});
    }
    return "Command ?";
}

fn paletteAccept(facts: Facts) []const u8 {
    const results = facts.palette;
    if (facts.typed.len == 0) return "Close";
    if (results.match_count > 0 and !results.available) return "Resize";
    if (results.match_count > 0) return "Activate";
    return "Check";
}

fn paletteFeedback(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    const results = facts.palette;
    if (facts.typed.len == 0) {
        if (facts.recent) |action| {
            return try std.fmt.allocPrint(
                arena,
                "Recent: {s}. Type to search actions, themes, tabs, panes, settings, and help.",
                .{action},
            );
        }
        return "Type to search actions, themes, tabs, panes, settings, and help.";
    }
    if (results.match_count == 0) {
        return "No matching command. Try > actions, % themes, @ tabs, / panes, : settings, or ? help.";
    }
    if (!results.available) {
        return try std.fmt.allocPrint(
            arena,
            "{d} matches. Make the window larger to show and activate results.",
            .{results.match_count},
        );
    }

    const title = results.title orelse "Selected result";
    const subtitle = results.subtitle orelse "";
    if (results.match_count == 1) {
        if (subtitle.len > 0) {
            return try std.fmt.allocPrint(
                arena,
                "{s} — {s}{s} Enter activates; Escape closes.",
                .{ title, subtitle, sentenceStop(subtitle) },
            );
        }
        return try std.fmt.allocPrint(
            arena,
            "{s}. Enter activates; Escape closes.",
            .{title},
        );
    }
    if (subtitle.len > 0) {
        return try std.fmt.allocPrint(
            arena,
            "{d} matches. Selected: {s} — {s}{s} Up/Down selects; Enter activates.",
            .{ results.match_count, title, subtitle, sentenceStop(subtitle) },
        );
    }
    return try std.fmt.allocPrint(
        arena,
        "{d} matches. Selected: {s}. Up/Down selects; Enter activates.",
        .{ results.match_count, title },
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

/// The profile label paint draws: "Profile" while no profile is shown.
fn profileLabel(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    const shown = switch (facts.profiles) {
        .shown => |value| value,
        .unavailable, .detecting => return "Profile",
    };
    return switch (profile_pick.byTyped(shown.list, facts.typed, shown.selected)) {
        .exact => |index| try std.fmt.allocPrint(
            arena,
            "Profile {d}/{d} {s}",
            .{ index + 1, shown.list.len, try kindBadge(arena, shown.list[index].kind) },
        ),
        .ambiguous => |count| try std.fmt.allocPrint(arena, "Profile {d}", .{count}),
        .invalid => "Profile ?",
    };
}

fn profileAccept(facts: Facts) []const u8 {
    const shown = switch (facts.profiles) {
        .shown => |value| value,
        .unavailable, .detecting => return "Check",
    };
    return switch (profile_pick.byTyped(shown.list, facts.typed, shown.selected)) {
        .exact => switch (shown.target) {
            .tab => "Open Tab",
            .window => "Open Win",
            .split => "Split",
        },
        .ambiguous => "Pick",
        .invalid => "Check",
    };
}

/// The keys that launch and pin profiles, which every profile hint lists.
const pick_keys = "Ctrl+1-9 launches directly. Alt+1-3 launches visible slots. Alt+Shift+1-3 pins the current profile. Alt+Shift+0 clears pinning.";

/// The profile hint, which paint draws during discovery too.
fn profileHint(arena: Allocator, facts: Facts) Allocator.Error![]const u8 {
    const shown = switch (facts.profiles) {
        .shown => |value| value,
        .unavailable, .detecting => return "No supported Windows profiles detected.",
    };
    const quick_suffix = try std.fmt.allocPrint(arena, " Quick picks: {s}.", .{try quickPicks(arena, shown.list)});
    return switch (profile_pick.byTyped(shown.list, facts.typed, shown.selected)) {
        .exact => |index| blk: {
            const profile = &shown.list[index];
            const pinned_slot = if (profile_pick.pinByKey(&shown.pinned, profile.key)) |ordinal|
                try std.fmt.allocPrint(arena, " Pinned slot {d}.", .{ordinal + 1})
            else
                "";
            break :blk try std.fmt.allocPrint(
                arena,
                "{s} {s} | key {s} | run {s}.{s} Enter opens a {s}. Ctrl+Enter splits here. Shift+Enter opens a new window. " ++ pick_keys ++ "{s}",
                .{
                    try kindBadge(arena, profile.kind),
                    profile.label,
                    profile.key,
                    try compactHostLabel(arena, try profile.command.string(arena), 36),
                    pinned_slot,
                    targetAction(shown.target),
                    quick_suffix,
                },
            );
        },
        .ambiguous => |count| try std.fmt.allocPrint(
            arena,
            "{d} profiles match. Keep typing a name or use Up/Down to cycle the current selection. " ++ pick_keys ++ "{s}",
            .{ count, quick_suffix },
        ),
        .invalid => try std.fmt.allocPrint(
            arena,
            "No matching profile. Try 1-{d} or a profile name like pwsh, ubuntu, git, or cmd. " ++ pick_keys ++ " Space keeps the picker open.{s}",
            .{ shown.list.len, quick_suffix },
        ),
    };
}

/// The first four profiles, numbered, with their badges and labels cut to
/// ten cells; "..." when there are more.
fn quickPicks(arena: Allocator, profiles: []const windows_shell.Profile) Allocator.Error![]const u8 {
    var parts: std.ArrayList(u8) = .empty;
    const limit = @min(profiles.len, 4);
    for (profiles[0..limit], 0..) |profile, index| {
        if (index > 0) try parts.appendSlice(arena, " | ");
        try parts.print(arena, "{d} {s} {s}", .{
            index + 1,
            try kindBadge(arena, profile.kind),
            try compactHostLabel(arena, profile.label, 10),
        });
    }
    if (limit < profiles.len) try parts.appendSlice(arena, " | ...");
    return parts.items;
}

fn targetAction(target: profile_pick.OpenTarget) []const u8 {
    return switch (target) {
        .tab => "new tab",
        .window => "new window",
        .split => "split",
    };
}

fn profileBadge(arena: Allocator, facts: Facts) Allocator.Error!?[]const u8 {
    if (facts.mode != .profile) return null;
    const shown = switch (facts.profiles) {
        .shown => |value| value,
        .unavailable, .detecting => return null,
    };
    return try kindBadge(arena, shown.list[shown.selected].kind);
}

fn kindBadge(arena: Allocator, kind: windows_shell.ProfileKind) Allocator.Error![]const u8 {
    const name = switch (kind) {
        .wsl_default, .wsl_distro => "WSL",
        .pwsh => "PWSH",
        .powershell => "PS",
        .git_bash => "GIT",
        .cmd => "CMD",
        .ssh => "SSH",
        .user => "USER",
        .vs_dev_cmd, .vs_dev_shell => "VS",
    };
    const glyph = switch (kind) {
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
    return try std.fmt.allocPrint(arena, "{s} {s}", .{ name, glyph });
}

test "win32 overlay paint label reflects live overlay mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const command = try compose(a, .{
        .mode = .command_palette,
        .typed = "toggle_",
        .palette = .{ .match_count = 4, .title = "Toggle fullscreen", .subtitle = "Fullscreen", .available = true },
    });
    try std.testing.expectEqualStrings("Command 4", command.paint_label);
    try std.testing.expectEqualStrings("Command 4", command.label.?);

    const search = try compose(a, .{ .mode = .search });
    try std.testing.expectEqualStrings("Find", search.paint_label);
    // The search overlay leaves its label control as it is.
    try std.testing.expect(search.label == null);

    // The label control names the field; paint draws the name bare.
    const title = try compose(a, .{ .mode = .surface_title });
    try std.testing.expectEqualStrings("Window title", title.paint_label);
    try std.testing.expectEqualStrings("Window title:", title.label.?);
    const tab = try compose(a, .{ .mode = .tab_title });
    try std.testing.expectEqualStrings("Tab title", tab.paint_label);
    try std.testing.expectEqualStrings("Tab title:", tab.label.?);
    const none = try compose(a, .{ .mode = .none });
    try std.testing.expectEqualStrings("", none.paint_label);
    try std.testing.expectEqualStrings("Command:", none.label.?);
}

test "win32 overlay shape: which controls each mode shows and what an empty query and a tab switch do" {
    const Row = struct { mode: Mode, accept: bool, edit: bool, dismisses: bool, follows: bool };
    const rows = [_]Row{
        .{ .mode = .none, .accept = true, .edit = true, .dismisses = true, .follows = false },
        // The palette's Enter activates its selected row, so its Accept
        // button would only duplicate it.
        .{ .mode = .command_palette, .accept = false, .edit = true, .dismisses = false, .follows = false },
        // A search query, a profile key or a tab number is what the user is
        // typing, not a property of the tab, so switching tabs keeps it.
        .{ .mode = .profile, .accept = true, .edit = true, .dismisses = false, .follows = false },
        .{ .mode = .search, .accept = true, .edit = true, .dismisses = false, .follows = false },
        // Prefilled from the active surface and written back to it on
        // submit; an empty one means "cancel".
        .{ .mode = .surface_title, .accept = true, .edit = true, .dismisses = true, .follows = true },
        .{ .mode = .tab_title, .accept = true, .edit = true, .dismisses = true, .follows = true },
        .{ .mode = .tab_overview, .accept = true, .edit = true, .dismisses = true, .follows = false },
        // A confirm's EDIT is hidden and always empty, so dismissing on
        // "empty" would close the prompt without dispatching either
        // callback.
        .{ .mode = .confirm, .accept = true, .edit = false, .dismisses = false, .follows = false },
    };
    try std.testing.expectEqual(@typeInfo(Mode).@"enum".fields.len, rows.len);
    for (rows) |row| {
        errdefer std.debug.print("mode {s}\n", .{@tagName(row.mode)});
        const got = shape(row.mode);
        try std.testing.expectEqual(row.accept, got.accept_visible);
        try std.testing.expectEqual(row.edit, got.edit_visible);
        try std.testing.expectEqual(row.dismisses, got.empty_submit_dismisses);
        try std.testing.expectEqual(row.follows, got.follows_active_surface);
    }
}

test "win32 confirm overlay paints its payload title and body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const confirm: Facts.Confirm = .{
        .title = "Allow clipboard paste?",
        .body = "noctty needs confirmation before completing this clipboard paste or read request.",
        .accept = "Allow",
        .cancel = "Cancel",
    };

    // Every confirm prompt used to paint the same "Confirm" placeholder, so
    // a close prompt and a clipboard prompt were indistinguishable.
    const text = try compose(arena.allocator(), .{ .mode = .confirm, .confirm = confirm });
    try std.testing.expectEqualStrings("Allow clipboard paste?", text.paint_label);
    try std.testing.expectEqualStrings("Allow clipboard paste?", text.label.?);
    try std.testing.expectEqualStrings(confirm.body, text.feedback);
    try std.testing.expectEqualStrings(confirm.body, text.hint);
    // The buttons say what the caller chose.
    try std.testing.expectEqualStrings("Allow", text.buttons.?.accept);
    try std.testing.expectEqualStrings("Cancel", text.buttons.?.cancel);
}

test "win32 confirm overlay falls back once its payload is dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Teardown drops the payload before the last repaint can run, so the
    // placeholders still have to be reachable, and the buttons keep their
    // last words.
    const text = try compose(arena.allocator(), .{ .mode = .confirm });
    try std.testing.expectEqualStrings("Confirm", text.paint_label);
    try std.testing.expectEqualStrings("Confirm", text.label.?);
    try std.testing.expectEqualStrings("", text.feedback);
    try std.testing.expectEqualStrings("", text.hint);
    try std.testing.expect(text.buttons == null);
}

test "win32 the confirm hint is the body line chrome paint draws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The confirm body STATIC reports its own window text (the hint) as its
    // UIA name, and chrome paint is still the fallback renderer for the same
    // line. If the two ever diverged a screen reader would narrate something
    // the screen does not say.
    const confirm: Facts.Confirm = .{
        .title = "Allow clipboard paste?",
        .body = "noctty needs confirmation before completing this clipboard paste or read request.",
        .accept = "Allow",
        .cancel = "Cancel",
        .caption = "3 bytes",
    };
    const cases = [_]struct { kind: BannerKind, text: ?[]const u8 }{
        .{ .kind = .none, .text = null },
        .{ .kind = .none, .text = "Plain notice" },
        .{ .kind = .info, .text = "Heads up" },
        .{ .kind = .err, .text = "Something went wrong" },
    };
    for (cases) |case| {
        const text = try compose(a, .{ .mode = .confirm, .banner_kind = case.kind, .banner = case.text, .confirm = confirm });
        try std.testing.expectEqualStrings(text.feedback, text.hint);
    }

    // No banner: body plus the preview caption, which is how the amount
    // being approved stays visible when the pane only shows its head.
    const plain = try compose(a, .{ .mode = .confirm, .confirm = confirm });
    try std.testing.expectEqualStrings(
        "noctty needs confirmation before completing this clipboard paste or read request.  (3 bytes)",
        plain.hint,
    );

    // A banner raised while the prompt is open takes the line, prefix and
    // all.
    const banner = try compose(a, .{ .mode = .confirm, .banner_kind = .err, .banner = "Clipboard unavailable", .confirm = confirm });
    try std.testing.expectEqualStrings("Error: Clipboard unavailable", banner.hint);

    // Mid-teardown the payload is already gone.
    const dropped = try compose(a, .{ .mode = .confirm });
    try std.testing.expectEqualStrings("", dropped.hint);
}

test "win32 overlay feedback line prefers inline banner state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const info = try compose(a, .{ .mode = .command_palette, .banner_kind = .info, .banner = "Try: new_tab" });
    try std.testing.expectEqualStrings("Info: Try: new_tab", info.feedback);

    const err = try compose(a, .{
        .mode = .command_palette,
        .banner_kind = .err,
        .banner = "Unknown Noctty action. Example: new_tab or toggle_fullscreen",
    });
    try std.testing.expectEqualStrings(
        "Error: Unknown Noctty action. Example: new_tab or toggle_fullscreen",
        err.feedback,
    );
    // The hint control has no banner: the palette's keeps its status line.
    try std.testing.expectEqualStrings("Type to search actions, themes, tabs, panes, settings, and help.", err.hint);

    // With no banner the line is the mode's own hint.
    const fallback = try compose(a, .{ .mode = .search, .typed = "needle" });
    try std.testing.expectEqualStrings("No matches yet. Keep typing to search live.", fallback.feedback);

    // The profile overlay's line takes a banner too; its hint control does
    // not.
    const profile = try compose(a, .{ .mode = .profile, .banner = "Plain notice" });
    try std.testing.expectEqualStrings("Plain notice", profile.feedback);
    try std.testing.expectEqualStrings("No supported Windows profiles detected.", profile.hint);
}

test "win32 command-palette-hint = false empties the palette's line and its row until a message needs them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every state of the palette's own line goes: the empty query, a query
    // with no match, and one with a selected result.
    const empty = try compose(a, .{ .mode = .command_palette, .palette_hint = false, .recent = "new_tab" });
    try std.testing.expectEqualStrings("", empty.feedback);
    try std.testing.expectEqualStrings("", empty.hint);
    const unmatched = try compose(a, .{ .mode = .command_palette, .palette_hint = false, .typed = "zzz" });
    try std.testing.expectEqualStrings("", unmatched.feedback);
    const matched = try compose(a, .{
        .mode = .command_palette,
        .palette_hint = false,
        .typed = "split",
        .palette = .{ .match_count = 3, .title = "Split Right", .available = true },
    });
    try std.testing.expectEqualStrings("", matched.feedback);
    // The rest of the palette is as it was.
    try std.testing.expectEqualStrings("Command 3", matched.paint_label);
    try std.testing.expectEqualStrings("Activate", matched.buttons.?.accept);

    // A message still shows on that line.
    const message = try compose(a, .{
        .mode = .command_palette,
        .palette_hint = false,
        .banner_kind = .info,
        .banner = "Keyboard shortcuts are configured in Settings > Keybindings.",
    });
    try std.testing.expectEqualStrings("Info: Keyboard shortcuts are configured in Settings > Keybindings.", message.feedback);

    // The row goes with the line, and comes back for a message.
    try std.testing.expect(feedbackRow(.command_palette, true, false));
    try std.testing.expect(!feedbackRow(.command_palette, false, false));
    try std.testing.expect(feedbackRow(.command_palette, false, true));
    // The key is the palette's: every other overlay keeps its line.
    for ([_]Mode{ .none, .profile, .search, .surface_title, .tab_title, .tab_overview, .confirm }) |mode| {
        try std.testing.expect(feedbackRow(mode, false, false));
        const text = try compose(a, .{ .mode = mode, .palette_hint = false, .typed = "x" });
        const shown = try compose(a, .{ .mode = mode, .typed = "x" });
        try std.testing.expectEqualStrings(shown.feedback, text.feedback);
    }
}

test "win32 overlay accept label reflects overlay action state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const palette_idle = try compose(a, .{ .mode = .command_palette });
    try std.testing.expectEqualStrings("Close", palette_idle.buttons.?.accept);

    const palette_run = try compose(a, .{
        .mode = .command_palette,
        .typed = "new_tab",
        .palette = .{ .match_count = 1, .title = "New tab", .subtitle = "Action", .available = true },
    });
    try std.testing.expectEqualStrings("Activate", palette_run.buttons.?.accept);

    const palette_matches = try compose(a, .{
        .mode = .command_palette,
        .typed = "0x96f",
        .palette = .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    });
    try std.testing.expectEqualStrings("Activate", palette_matches.buttons.?.accept);

    const palette_hidden = try compose(a, .{
        .mode = .command_palette,
        .typed = "0x96f",
        .palette = .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme" },
    });
    try std.testing.expectEqualStrings("Resize", palette_hidden.buttons.?.accept);

    const palette_miss = try compose(a, .{ .mode = .command_palette, .typed = "zzz" });
    try std.testing.expectEqualStrings("Check", palette_miss.buttons.?.accept);

    const search_find = try compose(a, .{ .mode = .search, .typed = "other" });
    try std.testing.expectEqualStrings("Find", search_find.buttons.?.accept);

    const tab_go = try compose(a, .{ .mode = .tab_overview, .typed = "2" });
    try std.testing.expectEqualStrings("Go", tab_go.buttons.?.accept);

    const title_apply = try compose(a, .{ .mode = .surface_title, .typed = "logs" });
    try std.testing.expectEqualStrings("Apply", title_apply.buttons.?.accept);
}

test "win32 overlay hint reflects live overlay guidance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const search_typed = try compose(a, .{ .mode = .search, .typed = "needle" });
    try std.testing.expectEqualStrings("No matches yet. Keep typing to search live.", search_typed.hint);

    const tab_invalid = try compose(a, .{ .mode = .tab_overview, .typed = "8", .tab = .{ .index = 1, .total = 4 }, .pane_count = 2 });
    try std.testing.expect(std.mem.indexOf(u8, tab_invalid.hint, "out of range") != null);

    const tab_title = try compose(a, .{ .mode = .tab_title, .typed = "logs", .tab = .{ .index = 0, .total = 3 }, .pane_count = 2 });
    try std.testing.expect(std.mem.indexOf(u8, tab_title.hint, "tab 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, tab_title.hint, "2 panes") != null);
}

test "win32 overlay cancel label reflects overlay mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings("Close", (try compose(arena.allocator(), .{ .mode = .search })).buttons.?.cancel);
    try std.testing.expectEqualStrings("Cancel", (try compose(arena.allocator(), .{ .mode = .surface_title })).buttons.?.cancel);
}

test "win32 command palette label reflects palette state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const idle = try compose(a, .{ .mode = .command_palette });
    try std.testing.expectEqualStrings("Command", idle.label.?);

    const matches = try compose(a, .{
        .mode = .command_palette,
        .typed = "0x96f",
        .palette = .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    });
    try std.testing.expectEqualStrings("Command 1", matches.label.?);

    const invalid = try compose(a, .{ .mode = .command_palette, .typed = "definitely_not_real" });
    try std.testing.expectEqualStrings("Command ?", invalid.label.?);
}

test "win32 command palette rich feedback never calls a theme an action miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shown = try compose(a, .{
        .mode = .command_palette,
        .typed = "0x96f",
        .palette = .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    });
    try std.testing.expect(std.mem.indexOf(u8, shown.hint, "0x96f") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.hint, "Bundled theme") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown.hint, "No matching action") == null);

    const hidden = try compose(a, .{
        .mode = .command_palette,
        .typed = "0x96f",
        .palette = .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme" },
    });
    try std.testing.expect(std.mem.indexOf(u8, hidden.hint, "window larger") != null);
}

test "win32 command palette feedback does not double a description's full stop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prose = try compose(a, .{
        .mode = .command_palette,
        .typed = "open",
        .palette = .{ .match_count = 3, .title = "Open Config", .subtitle = "Open the config file.", .available = true },
    });
    try std.testing.expectEqualStrings(
        "3 matches. Selected: Open Config — Open the config file. Up/Down selects; Enter activates.",
        prose.hint,
    );

    const label = try compose(a, .{
        .mode = .command_palette,
        .typed = "0x96f",
        .palette = .{ .match_count = 1, .title = "0x96f", .subtitle = "Bundled theme", .available = true },
    });
    try std.testing.expectEqualStrings("0x96f — Bundled theme. Enter activates; Escape closes.", label.hint);
}

test "win32 tab overview label reflects current host tab" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const multi = try compose(a, .{ .mode = .tab_overview, .tab = .{ .index = 1, .total = 4 } });
    try std.testing.expectEqualStrings("Tab 2/4", multi.label.?);
    try std.testing.expectEqualStrings("Tab 2/4", multi.paint_label);

    const single = try compose(a, .{ .mode = .tab_overview, .tab = .{ .index = 0, .total = 1 } });
    try std.testing.expectEqualStrings("Tab", single.label.?);
}

test "win32 profile overlay label and hint reflect selected profile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

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

    const text = try compose(arena.allocator(), .{
        .mode = .profile,
        .typed = "cmd",
        .profiles = .{ .shown = .{ .list = &profiles, .selected = 0, .target = .window, .pinned = .{ "pwsh.exe", "cmd.exe", null } } },
    });
    try std.testing.expectEqualStrings("Profile 2/2 CMD C>", text.label.?);
    try std.testing.expectEqualStrings("Profile 2/2 CMD C>", text.paint_label);
    try std.testing.expectEqualStrings("Open Win", text.buttons.?.accept);

    const hint = text.hint;
    try std.testing.expectEqualStrings(hint, text.feedback);
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

test "win32 profile hint compacts the shell command preview" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const profiles = [_]windows_shell.Profile{.{
        .kind = .wsl_distro,
        .key = "Ubuntu",
        .label = "WSL: Ubuntu",
        .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu-24.04", "--cd", "~", "--exec", "/bin/bash", "-l" } },
    }};
    const text = try compose(arena.allocator(), .{
        .mode = .profile,
        .profiles = .{ .shown = .{ .list = &profiles, .selected = 0, .target = .tab, .pinned = @splat(null) } },
    });
    try std.testing.expect(std.mem.indexOf(u8, text.hint, "| run wsl.exe -d Ubuntu-24.04 --cd ~ --.... Enter opens a new tab.") != null);
}

test "win32 profile hint lists the first launcher profiles as quick picks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

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

    const text = try compose(arena.allocator(), .{
        .mode = .profile,
        .profiles = .{ .shown = .{ .list = &profiles, .selected = 0, .target = .tab, .pinned = @splat(null) } },
    });
    try std.testing.expect(std.mem.endsWith(
        u8,
        text.hint,
        " Quick picks: 1 GIT $> Git Bash | 2 PWSH >> PowerShell | 3 WSL <> WSL: Ub... | 4 CMD C> Command... | ....",
    ));
}

test "win32 profile badge adds the profile glyph treatment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const profiles = [_]windows_shell.Profile{
        .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{"pwsh.exe"} } },
        .{ .kind = .wsl_distro, .key = "wsl:Ubuntu", .label = "WSL: Ubuntu", .command = .{ .direct = &.{"wsl.exe"} } },
    };
    // The badge is the selected profile's, whatever the query names.
    const pwsh = try compose(a, .{
        .mode = .profile,
        .typed = "wsl",
        .profiles = .{ .shown = .{ .list = &profiles, .selected = 0, .target = .tab, .pinned = @splat(null) } },
    });
    try std.testing.expectEqualStrings("PWSH >>", pwsh.badge.?);

    const wsl = try compose(a, .{
        .mode = .profile,
        .profiles = .{ .shown = .{ .list = &profiles, .selected = 1, .target = .tab, .pinned = @splat(null) } },
    });
    try std.testing.expectEqualStrings("WSL <>", wsl.badge.?);

    // Only the profile overlay draws one, and only with a profile shown.
    const palette = try compose(a, .{
        .mode = .command_palette,
        .profiles = .{ .shown = .{ .list = &profiles, .selected = 1, .target = .tab, .pinned = @splat(null) } },
    });
    try std.testing.expect(palette.badge == null);
}

test "win32 the profile overlay says it is detecting profiles only in its hint control" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Discovery was asked for and no list has landed: the hint control says
    // so, and chrome paint's line says what the list holds.
    const detecting = try compose(a, .{ .mode = .profile, .profiles = .detecting });
    try std.testing.expectEqualStrings("Detecting Windows profiles...", detecting.hint);
    try std.testing.expectEqualStrings("No supported Windows profiles detected.", detecting.feedback);
    try std.testing.expectEqualStrings("Profile:", detecting.label.?);
    try std.testing.expectEqualStrings("Profile", detecting.paint_label);
    try std.testing.expectEqualStrings("Check", detecting.buttons.?.accept);
    try std.testing.expect(detecting.badge == null);

    // No profile to show: both lines say there is none.
    const unavailable = try compose(a, .{ .mode = .profile, .profiles = .unavailable });
    try std.testing.expectEqualStrings("No supported Windows profiles detected.", unavailable.hint);
    try std.testing.expectEqualStrings("No supported Windows profiles detected.", unavailable.feedback);
    try std.testing.expectEqualStrings("Profile:", unavailable.label.?);
}

test "win32 banner line prefixes info and error banners" {
    const plain = try bannerLine(std.testing.allocator, .none, "ready");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("ready", plain);

    const info = try bannerLine(std.testing.allocator, .info, "ready");
    defer std.testing.allocator.free(info);
    try std.testing.expectEqualStrings("Info: ready", info);

    const err = try bannerLine(std.testing.allocator, .err, "ready");
    defer std.testing.allocator.free(err);
    try std.testing.expectEqualStrings("Error: ready", err);
}

test "win32 transient overlay focus ring includes every visible control" {
    const all: Visible = .{ .edit = true, .preview = true, .accept = true, .cancel = true };
    try std.testing.expectEqual(Slot.accept, nextFocus(.profile, .edit, false, all));
    try std.testing.expectEqual(Slot.cancel, nextFocus(.profile, .accept, false, all));
    try std.testing.expectEqual(Slot.edit, nextFocus(.profile, .cancel, false, all));
    try std.testing.expectEqual(Slot.cancel, nextFocus(.profile, .edit, true, all));
    try std.testing.expectEqual(Slot.edit, nextFocus(.profile, .accept, true, all));
    try std.testing.expectEqual(Slot.accept, nextFocus(.profile, .cancel, true, all));

    try std.testing.expectEqual(Slot.cancel, nextFocus(.command_palette, .edit, false, all));
    try std.testing.expectEqual(Slot.edit, nextFocus(.command_palette, .cancel, true, all));
    try std.testing.expectEqual(Slot.cancel, nextFocus(.confirm, .accept, false, all));
    try std.testing.expectEqual(Slot.accept, nextFocus(.confirm, .cancel, true, all));
    // A confirm's preview is a stop of its own, so the keyboard reaches the
    // payload, both ways; hidden, it is skipped both ways.
    try std.testing.expectEqual(Slot.preview, nextFocus(.confirm, .cancel, false, all));
    try std.testing.expectEqual(Slot.accept, nextFocus(.confirm, .preview, false, all));
    try std.testing.expectEqual(Slot.preview, nextFocus(.confirm, .accept, true, all));
    try std.testing.expectEqual(Slot.cancel, nextFocus(.confirm, .preview, true, all));
    const no_preview: Visible = .{ .edit = false, .preview = false, .accept = true, .cancel = true };
    try std.testing.expectEqual(Slot.accept, nextFocus(.confirm, .cancel, false, no_preview));
    try std.testing.expectEqual(Slot.cancel, nextFocus(.confirm, .accept, true, no_preview));

    try std.testing.expectEqual(Slot.cancel, nextFocus(.profile, .edit, false, .{ .edit = true, .preview = false, .accept = false, .cancel = true }));
    try std.testing.expectEqual(Slot.cancel, nextFocus(.confirm, .accept, false, .{ .edit = false, .preview = false, .accept = false, .cancel = true }));
    try std.testing.expectEqual(Slot.accept, nextFocus(.confirm, .cancel, true, .{ .edit = false, .preview = false, .accept = true, .cancel = true }));
    try std.testing.expectEqual(null, nextFocus(.command_palette, .edit, false, .{ .edit = true, .preview = false, .accept = false, .cancel = false }));
    try std.testing.expectEqual(null, nextFocus(.confirm, .cancel, false, .{ .edit = false, .preview = false, .accept = false, .cancel = true }));
}
