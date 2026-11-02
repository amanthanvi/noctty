//! The decisions a Window's state is made of, from values. The Win32 calls
//! that carry them out are window_state.zig's, the one file that imports this
//! one (it re-exports `TopLevel`). This file imports no `sys`, so the compiler
//! keeps it free of them, and its tests need no window.
const std = @import("std");
const c = @import("consts.zig");
const types = @import("../win32_types.zig");

const MONITORINFO = types.MONITORINFO;
const POINT = types.POINT;
const RECT = types.RECT;
const WINDOWPLACEMENT = types.WINDOWPLACEMENT;

/// The state of one top-level window, kept once, on its `Host`
/// (`Host.top_level`), whichever of its panes acts on it.
pub const TopLevel = struct {
    decorations_visible: bool = true,
    /// `toggle_window_decorations` chose them, so a reload leaves them.
    decorations_overridden: bool = false,
    /// `float_window`: above every window that is not topmost.
    topmost: bool = false,
    /// `background-opacity`, clamped to 0..1.
    opacity: f64 = 1.0,
    /// `toggle_background_opacity` shows the window opaque whatever
    /// `opacity` says. A reload to an opaque config clears it.
    force_opaque: bool = false,
    /// What leaving fullscreen gives back, set exactly while the window is
    /// fullscreen.
    fullscreen: ?Return = null,

    /// The window as it was when it entered fullscreen.
    pub const Return = struct {
        /// Its rect, in screen coordinates.
        rect: RECT,
        /// Its placement, captured before the style write that drops
        /// `WS_MAXIMIZE`. `rcNormalPosition` is in the workspace coordinates
        /// of `monitor`.
        placement: WINDOWPLACEMENT,
        /// The monitor it entered fullscreen on.
        monitor: ?Monitor,
    };

    pub fn isFullscreen(self: *const TopLevel) bool {
        return self.fullscreen != null;
    }

    /// The layered alpha the window shows, or null when it shows opaque and
    /// so is not layered at all (#234: layering is the only mechanism, and an
    /// opaque window must not pay for it).
    pub fn alpha(self: *const TopLevel) ?u8 {
        if (self.force_opaque or self.opacity >= 0.999) return null;
        return @intFromFloat(@round(std.math.clamp(self.opacity, 0.0, 1.0) * 255.0));
    }
};

/// A monitor as a window on it sees it. `id` is its `HMONITOR`.
pub const Monitor = struct { id: usize, info: MONITORINFO, dpi: u32 };

/// Whether `window-decoration = none` keeps the system frame and only
/// collapses its caption, the integrated titlebar's mechanism with a 0 px
/// row. The frame gives the window its resize edges, shadow, Snap,
/// work-area maximize and the Alt+Space window menu, with nothing to
/// paint. Windows 11 only: Windows 10 draws its window border inside the
/// non-client top this would remove, and stays frameless. So does the
/// quick terminal, which is sized from config and placed flush with a
/// screen edge by its window rect: the frame's invisible resize margins
/// would pull it in from that edge.
pub fn undecoratedKeepsFrame(os_build: u32, quick_terminal: bool) bool {
    return os_build >= c.OS_BUILD_WIN11_21H2 and !quick_terminal;
}

const WS_OVERLAPPEDWINDOW = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_THICKFRAME | c.WS_MINIMIZEBOX | c.WS_MAXIMIZEBOX;

/// A host window's style: a popup while fullscreen, else the system frame
/// when `framed` (decorated, and on Windows 11 undecorated too:
/// `undecoratedKeepsFrame`), else a bare overlapped window. `WS_VISIBLE` is
/// the caller's to keep.
pub fn hostStyle(framed: bool, fullscreen: bool) u32 {
    if (fullscreen) return c.WS_POPUP | c.WS_CLIPCHILDREN;
    if (framed) return WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN;
    return c.WS_OVERLAPPED | c.WS_CLIPCHILDREN;
}

/// Where a new top-level window comes from (`window_state.Origin`).
pub const Kind = enum { fresh, copy, restore, quick_terminal, adopted };

/// The first show of a new host window.
pub const InitialShow = enum {
    /// Shown and presented with focus.
    activate,
    /// Visible without stealing focus from the caller's foreground window.
    no_activate,
    /// Minimized, without activation: the window exists but stays out of the
    /// way, and the taskbar button is all the user sees.
    minimized,
    /// Maximized, with focus.
    maximized,

    /// The `ShowWindow` command for the first show, if it is not left to
    /// `presentWindow`. A maximize is followed by `presentWindow` for focus.
    pub fn showCommand(self: InitialShow) ?i32 {
        return switch (self) {
            .activate => null,
            .no_activate => c.SW_SHOWNOACTIVATE,
            .minimized => c.SW_SHOWMINNOACTIVE,
            .maximized => c.SW_MAXIMIZE,
        };
    }

    pub fn takesFocus(self: InitialShow) bool {
        return self == .activate or self == .maximized;
    }
};

/// What a window's own config asks of how it starts (`window_state.wants`).
pub const Wants = struct {
    /// `window-position-x/y`, when both are set.
    position: ?POINT = null,
    /// `window-decoration` is not `none`.
    decorated: bool = true,
    /// `background-opacity`, clamped to 0..1.
    opacity: f64 = 1.0,
    maximize: bool = false,
    fullscreen: bool = false,
    /// Both `window-width` and `window-height`: core init sizes the window.
    sized: bool = false,
};

/// The window keys a forwarded launch's argv names (a second `noctty`, or
/// `noctty +new-window`; `ipc_server.forwardedArgvSetsKey`). The same keys
/// from the app config do not count: a copy still takes those from its
/// source (window-frame.md 2026-10-20 #496 part 2, trap 1).
pub const Forwarded = packed struct(u3) {
    size: bool = false,
    decoration: bool = false,
    opacity: bool = false,
};

/// The window a copy is opened from, read once when the copy begins.
pub const Snapshot = struct { state: TopLevel };

/// What a new window keeps of its own config over the state it copies
/// from the window it is opened from. By default it copies that window's
/// size, one cascade step off it, its maximized or fullscreen state, its
/// decorations and its background opacity.
pub const Keeps = struct {
    /// `window-position-x/y` place it: it stays where it was created and
    /// takes only the size.
    position: bool = false,
    /// The size core init gave it from its `window-width`/`window-height`.
    /// Its state is still the source's: maximized or fullscreen, it returns
    /// to that size.
    size: bool = false,
    /// Its own `window-decoration`.
    decoration: bool = false,
    /// Its own `background-opacity`.
    opacity: bool = false,
};

/// `maximize` and `fullscreen` (#496): a new fresh or copied window enters
/// them once it has its rect. A tab, a split, the quick terminal and a
/// handed-off console never do, and a restored window does once it is at
/// its saved rect. A config reload changes no open window.
pub const Enter = struct {
    maximize: bool = false,
    fullscreen: bool = false,
};

/// How one new window starts: decided by `plan` before the window exists,
/// and carried out by `window_state` at its creation and first show.
pub const Plan = struct {
    kind: Kind,
    keeps: Keeps,
    enter: Enter,
    show: InitialShow,
    /// The state it is created in, set before `CreateWindowEx` so the first
    /// `WM_NCCALCSIZE` already sees its decorations (#266). A copy takes the
    /// rest of its source's state after its first show.
    top_level: TopLevel,
    /// The style it is created with, without `WS_VISIBLE`, and written back
    /// after `CreateWindowEx` (window-frame.md 2026-09-23). A copy of a
    /// fullscreen window with no size of its own starts as a popup;
    /// otherwise it starts framed, so core init sizes the window it leaves
    /// fullscreen to.
    style: u32,
    /// Undecorated on the system frame: the frame's border is hidden.
    hide_border: bool,
    /// `window-position-x/y`, where it is created; else `CW_USEDEFAULT`.
    position: ?POINT,
    /// The window a copy is opened from.
    source: ?Snapshot,
};

pub fn plan(kind: Kind, wants: Wants, forwarded: Forwarded, source: ?*const Snapshot, show: InitialShow, os_build: u32) Plan {
    const keeps: Keeps = .{
        .position = wants.position != null,
        // Core init sizes the window only when both are set.
        .size = forwarded.size and wants.sized,
        .decoration = forwarded.decoration,
        .opacity = forwarded.opacity,
    };
    const copied: ?Snapshot = if (kind == .copy) if (source) |from| from.* else null else null;
    var top_level: TopLevel = .{ .decorations_visible = wants.decorated, .opacity = wants.opacity };
    var popup = false;
    if (copied) |from| {
        if (!keeps.decoration) top_level.decorations_visible = from.state.decorations_visible;
        // Shown at its source's opacity before it takes the rest of its
        // state: a copy of a window forced opaque never shows faded.
        if (!keeps.opacity) {
            top_level.opacity = from.state.opacity;
            top_level.force_opaque = from.state.force_opaque;
        }
        popup = from.state.isFullscreen() and !keeps.size;
    }
    const framed = top_level.decorations_visible or undecoratedKeepsFrame(os_build, kind == .quick_terminal);
    return .{
        .kind = kind,
        .keeps = keeps,
        .enter = switch (kind) {
            .fresh, .copy => .{ .maximize = wants.maximize, .fullscreen = wants.fullscreen },
            .restore, .quick_terminal, .adopted => .{},
        },
        .show = show,
        .top_level = top_level,
        .style = hostStyle(framed, popup),
        .hide_border = !top_level.decorations_visible and framed,
        .position = wants.position,
        .source = copied,
    };
}

test "win32 a new window keeps what its own config places and a forward sets, and copies the rest" {
    const sized: Wants = .{ .sized = true };
    try std.testing.expectEqual(Keeps{}, plan(.copy, .{}, .{}, null, .activate, 0).keeps);
    // A size needs both keys in the window's config, as core init does.
    try std.testing.expectEqual(Keeps{ .decoration = true, .opacity = true }, plan(.copy, .{}, .{ .size = true, .decoration = true, .opacity = true }, null, .activate, 0).keeps);
    try std.testing.expectEqual(Keeps{ .size = true, .decoration = true, .opacity = true }, plan(.copy, sized, .{ .size = true, .decoration = true, .opacity = true }, null, .activate, 0).keeps);
    // From the app config the keys stay the source's; the position is the
    // window's either way.
    try std.testing.expectEqual(Keeps{}, plan(.copy, sized, .{}, null, .activate, 0).keeps);
    try std.testing.expectEqual(Keeps{ .position = true }, plan(.copy, .{ .position = .{ .x = 10, .y = 20 } }, .{}, null, .activate, 0).keeps);

    // What it takes from its source before its first show, and what it keeps.
    const source: Snapshot = .{ .state = .{ .decorations_visible = false, .opacity = 0.6, .force_opaque = true } };
    var copy = plan(.copy, .{ .opacity = 0.8 }, .{}, &source, .activate, 0);
    try std.testing.expectEqual(TopLevel{ .decorations_visible = false, .opacity = 0.6, .force_opaque = true }, copy.top_level);
    try std.testing.expectEqual(source, copy.source.?);
    copy = plan(.copy, .{ .opacity = 0.8 }, .{ .decoration = true, .opacity = true }, &source, .activate, 0);
    try std.testing.expectEqual(TopLevel{ .opacity = 0.8 }, copy.top_level);
    // Only a copy has a source.
    for ([_]Kind{ .fresh, .restore, .quick_terminal, .adopted }) |kind| {
        const p = plan(kind, .{ .decorated = false, .opacity = 0.8 }, .{}, &source, .no_activate, 0);
        try std.testing.expectEqual(TopLevel{ .decorations_visible = false, .opacity = 0.8 }, p.top_level);
        try std.testing.expect(p.source == null);
        try std.testing.expectEqual(InitialShow.no_activate, p.show);
    }
}

test "win32 maximize and fullscreen start only a fresh or copied window" {
    const both: Wants = .{ .maximize = true, .fullscreen = true };
    for ([_]Kind{ .fresh, .copy }) |kind| {
        try std.testing.expectEqual(Enter{ .maximize = true, .fullscreen = true }, plan(kind, both, .{}, null, .activate, 0).enter);
        try std.testing.expectEqual(Enter{}, plan(kind, .{}, .{}, null, .activate, 0).enter);
    }
    // Not the quick terminal or a handed-off console, which keeps the show
    // state its client asked for, and not a restored window, which enters
    // them once it is at its saved rect.
    for ([_]Kind{ .restore, .quick_terminal, .adopted }) |kind| {
        try std.testing.expectEqual(Enter{}, plan(kind, both, .{}, null, .activate, 0).enter);
    }
}

test "win32 a new window is created framed, bare or a popup as its state and Windows build say" {
    const framed = WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN;
    const bare = c.WS_OVERLAPPED | c.WS_CLIPCHILDREN;
    const popup = c.WS_POPUP | c.WS_CLIPCHILDREN;
    const fullscreen: Snapshot = .{ .state = .{ .fullscreen = .{ .rect = std.mem.zeroes(RECT), .placement = std.mem.zeroes(WINDOWPLACEMENT), .monitor = null } } };
    const Case = struct { kind: Kind = .fresh, wants: Wants = .{}, forwarded: Forwarded = .{}, source: ?*const Snapshot = null, os_build: u32, style: u32, hide_border: bool = false };
    for ([_]Case{
        .{ .os_build = 0, .style = framed },
        .{ .os_build = c.OS_BUILD_WIN11_21H2, .style = framed },
        // Undecorated: Windows 11 keeps the frame and hides its border;
        // Windows 10 and the quick terminal stay frameless.
        .{ .wants = .{ .decorated = false }, .os_build = 0, .style = bare },
        .{ .wants = .{ .decorated = false }, .os_build = c.OS_BUILD_WIN11_21H2, .style = framed, .hide_border = true },
        .{ .kind = .quick_terminal, .wants = .{ .decorated = false }, .os_build = c.OS_BUILD_WIN11_21H2, .style = bare },
        // A copy of a fullscreen window is a popup, unless a size of its own
        // must be measured on the frame first.
        .{ .kind = .copy, .source = &fullscreen, .os_build = c.OS_BUILD_WIN11_21H2, .style = popup },
        .{ .kind = .copy, .wants = .{ .sized = true }, .forwarded = .{ .size = true }, .source = &fullscreen, .os_build = c.OS_BUILD_WIN11_21H2, .style = framed },
        // A config's fullscreen is entered after the first show, never at
        // creation.
        .{ .wants = .{ .fullscreen = true }, .os_build = 0, .style = framed },
    }) |case| {
        const p = plan(case.kind, case.wants, case.forwarded, case.source, .activate, case.os_build);
        try std.testing.expectEqual(case.style, p.style);
        try std.testing.expectEqual(case.hide_border, p.hide_border);
        try std.testing.expect(p.style & c.WS_VISIBLE == 0);
    }
}

test "win32 a window shows its opacity as a layered alpha, and opaque unlayered" {
    var top_level: TopLevel = .{ .opacity = 0.5 };
    try std.testing.expectEqual(@as(?u8, 128), top_level.alpha());
    top_level.opacity = 0.75;
    try std.testing.expectEqual(@as(?u8, 191), top_level.alpha());
    // `toggle_background_opacity`, and an opacity that rounds to opaque.
    top_level.force_opaque = true;
    try std.testing.expectEqual(@as(?u8, null), top_level.alpha());
    top_level = .{ .opacity = 0.9995 };
    try std.testing.expectEqual(@as(?u8, null), top_level.alpha());
    try std.testing.expectEqual(@as(?u8, 0), (TopLevel{ .opacity = 0 }).alpha());
}
