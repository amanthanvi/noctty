//! The decisions a Window's state is made of, from values: how a new window
//! starts (`plan`), where a copy goes (`place`), the rect a fullscreen window
//! covers (`composedFullscreenRect`), what leaving fullscreen returns to
//! (`returnOn`) and how the session saves and restores a window
//! (`SavedPlacement`, `forRestore`). The Win32 calls that carry them out are
//! window_state.zig's, which re-exports what the runtime uses. This file
//! imports no `sys`, so the compiler keeps it free of them, and its tests
//! need no window.
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

    /// Whether `opacity` shows at all: one that rounds to opaque does not,
    /// and `toggle_background_opacity` has nothing to toggle.
    pub fn translucent(self: *const TopLevel) bool {
        return self.opacity < 0.999;
    }

    /// The alpha `opacity` shows at, or null when the window shows opaque.
    /// `shows` says how the window shows it.
    pub fn alpha(self: *const TopLevel) ?u8 {
        if (self.force_opaque or !self.translucent()) return null;
        return @intFromFloat(@round(self.opacity * 255.0));
    }

    /// How a window shows `alpha()` (#640). At most one of `background` and
    /// `layered` is set; an opaque window has neither and pays for neither.
    pub const Shows = struct {
        /// Only the terminal background is translucent: each pane's renderer
        /// draws it at `pane_opacity`, blur-behind with an empty region makes
        /// DWM keep that alpha for the client area, and the chrome is painted
        /// solid except its own background in the terminal lane, which takes
        /// this alpha (`Host.chrome_alpha`).
        background: ?u8 = null,
        /// The whole window fades, text and chrome included, as a layered
        /// window at this alpha: a D3D11 pane presents through
        /// DirectComposition with its alpha ignored (`DXGI_ALPHA_MODE_IGNORE`),
        /// so it can show no per-pixel alpha.
        layered: ?u8 = null,
        /// What each pane's renderer draws its background at, or null for its
        /// own config's `background-opacity`, as before #640.
        pane_opacity: ?f64 = null,
    };

    /// `panes_draw_alpha`: every pane of the window whose renderer runs
    /// draws with OpenGL, whose alpha reaches DWM. `blur_behind_failed`: the
    /// window could not turn blur-behind on, without which DWM drops that
    /// alpha (`Host.blur_behind_failed`, latched). High Contrast shows the
    /// window opaque, deliberately: its system colors are for legibility,
    /// and before #640 a translucent window faded under it too.
    pub fn shows(self: *const TopLevel, panes_draw_alpha: bool, high_contrast: bool, blur_behind_failed: bool) Shows {
        // An opaque window's panes draw at 1, on either backend: no alpha
        // reaches DWM, and a background drawn at the config's opacity would
        // show darker.
        const alpha_shown = (if (high_contrast) null else self.alpha()) orelse return .{ .pane_opacity = 1.0 };
        // A D3D11 window, or one without blur-behind, fades whole, its panes
        // at their config's opacity, as before.
        if (!panes_draw_alpha or blur_behind_failed) return .{ .layered = alpha_shown };
        return .{ .background = alpha_shown, .pane_opacity = self.opacity };
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
pub const Snapshot = struct {
    state: TopLevel,
    /// Its rect, in screen coordinates. Once it is minimized this is a sliver
    /// under the taskbar, not its place (window-frame.md 2026-10-15).
    rect: RECT = std.mem.zeroes(RECT),
    /// Its placement. `rcNormalPosition` is in the workspace coordinates of
    /// `monitor`.
    placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT),
    iconic: bool = false,
    zoomed: bool = false,
    /// The monitor it is on (minimized, the one it was on), at its DPI.
    monitor: Monitor = .{ .id = 0, .info = std.mem.zeroes(MONITORINFO), .dpi = 96 },
};

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
    /// `WM_NCCALCSIZE` already sees its decorations (#266). A copy's is its
    /// source's, but for what it keeps of its own and for fullscreen, which
    /// it takes with its place after its first show (`place`).
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
    const copied: ?Snapshot = if (kind == .copy and source != null) source.?.* else null;
    var top_level: TopLevel = .{ .decorations_visible = wants.decorated, .opacity = wants.opacity };
    var popup = false;
    if (copied) |from| {
        // Shown at its source's opacity before it takes its place: a copy of
        // a window forced opaque never shows faded.
        top_level = from.state;
        top_level.fullscreen = null;
        if (keeps.decoration) {
            top_level.decorations_visible = wants.decorated;
            top_level.decorations_overridden = false;
        }
        if (keeps.opacity) {
            top_level.opacity = wants.opacity;
            top_level.force_opaque = false;
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

/// A window's outer size, in physical pixels.
pub const WindowSize = struct { width: i32, height: i32 };

/// A copy's own size (`Keeps.size`), measured where core init sized it,
/// before it takes its source's state, and the monitor it is on there.
pub const Own = struct { size: WindowSize, here: Monitor };

/// Where a copy goes, and what it leaves fullscreen to (`place`).
pub const Placement = struct {
    /// In screen coordinates.
    rect: RECT,
    /// `SetWindowPos` flags.
    flags: u32,
    /// Set when the source is, or restores to, maximized: its placement,
    /// which the copy is maximized with, so its normal rect is the source's.
    maximize: ?WINDOWPLACEMENT = null,
    /// The source's fullscreen return, when the source is fullscreen.
    fullscreen: ?TopLevel.Return = null,
};

/// The windows a copy's cascade steps past, asked when the copy is placed:
/// whether one of them has its top-left corner at `corner`. window_state.zig
/// asks the Registry about every window then on screen but the copy; `of`
/// answers from a list, for a test.
pub const Occupied = struct {
    ctx: *const anyopaque,
    startsAt: *const fn (ctx: *const anyopaque, corner: POINT) bool,

    /// No window to step past.
    pub const none: Occupied = .of(&no_corners);
    const no_corners: []const POINT = &.{};

    /// The windows whose top-left corners are `corners.*`.
    pub fn of(corners: *const []const POINT) Occupied {
        return .{ .ctx = @ptrCast(corners), .startsAt = listStartsAt };
    }

    fn listStartsAt(ctx: *const anyopaque, corner: POINT) bool {
        const corners: *const []const POINT = @ptrCast(@alignCast(ctx));
        for (corners.*) |at| {
            if (at.x == corner.x and at.y == corner.y) return true;
        }
        return false;
    }
};

/// Where the copy `p` plans goes. A normal source gives its size, one
/// cascade step down and right so the copy does not sit on it, on past any
/// window `occupied` says starts there (one window can be the source of
/// several), inside the source's work area. A minimized source
/// gives the rect it restores to; a source that is, or restores to,
/// maximized gives its placement. A fullscreen source gives its monitor's
/// rect, and the copy is fullscreen there too.
///
/// `window-position-x/y` say where every new window goes, so with them
/// (`Keeps.position`) the copy keeps the place it was created at and takes
/// only the size; with a size of its own as well (`own`) it takes neither,
/// because core init sized it where it is, which can be another monitor than
/// the one whose work area the cascade fits to (window-frame.md 2026-10-20
/// FWDGEOM2). A fullscreen copy covers the monitor wherever its config
/// would put it.
pub fn place(p: *const Plan, occupied: Occupied, own: ?Own) Placement {
    const source = p.source.?;
    const info = source.monitor.info;
    if (source.state.fullscreen) |back| return .{
        .rect = info.rcMonitor,
        .flags = c.SWP_NOACTIVATE,
        .fullscreen = if (own) |mine| sizedReturn(back, mine) else back,
    };

    var placed: Placement = .{ .rect = undefined, .flags = c.SWP_NOACTIVATE };
    if (restoresMaximized(source.zoomed, source.iconic, &source.placement)) {
        // It is maximized again, never minimized with it.
        var placement = source.placement;
        placement.showCmd = c.SW_MAXIMIZE;
        placed.rect = workspaceRectToScreen(placement.rcNormalPosition, info);
        if (own) |mine| {
            placed.rect = fitRectInWork(placed.rect.left, placed.rect.top, mine.size.width, mine.size.height, info.rcWork);
            placement.rcNormalPosition = screenRectToWorkspace(placed.rect, info);
        }
        placed.maximize = placement;
    } else {
        var rect = if (source.iconic) workspaceRectToScreen(source.placement.rcNormalPosition, info) else source.rect;
        if (own) |mine| {
            rect.right = rect.left + mine.size.width;
            rect.bottom = rect.top + mine.size.height;
        }
        const step = cascadeStep(source.monitor.dpi);
        placed.rect = cascadedRect(rect, step, info.rcWork);
        var steps: u8 = 0;
        while (steps < 8 and occupied.startsAt(occupied.ctx, .{ .x = placed.rect.left, .y = placed.rect.top })) : (steps += 1) {
            placed.rect = cascadedRect(placed.rect, step, info.rcWork);
        }
    }
    if (p.keeps.position) {
        placed.flags |= c.SWP_NOMOVE;
        if (own != null) placed.flags |= c.SWP_NOSIZE;
    }
    return placed;
}

/// Whether a window is, or when restored becomes, maximized. A window
/// minimized from maximized restores to maximized. The flag alone says
/// nothing about a window that was restored since: Windows keeps it set on a
/// normal window.
pub fn restoresMaximized(zoomed: bool, iconic: bool, placement: *const WINDOWPLACEMENT) bool {
    return zoomed or (iconic and placement.flags & c.WPF_RESTORETOMAXIMIZED != 0);
}

/// What a window that entered fullscreen as `back` returns to when it
/// leaves fullscreen on `here`: on another monitor or DPI, moved by the
/// work areas' offset, scaled by the DPIs and fitted to `here`'s work area
/// (window-frame.md 2026-10-11). `rcNormalPosition` goes from the workspace
/// coordinates of the monitor it entered on to `here`'s.
pub fn returnOn(back: TopLevel.Return, here: Monitor) TopLevel.Return {
    const from = back.monitor orelse return back;
    var moved = back;
    moved.monitor = here;
    if (here.id != from.id or here.dpi != from.dpi) {
        moved.rect = fullscreenRestoreRect(back.rect, from.info.rcWork, here.info.rcWork, from.dpi, here.dpi);
        const normal = workspaceRectToScreen(back.placement.rcNormalPosition, from.info);
        moved.placement.rcNormalPosition = screenRectToWorkspace(
            fullscreenRestoreRect(normal, from.info.rcWork, here.info.rcWork, from.dpi, here.dpi),
            here.info,
        );
    }
    return moved;
}

/// The return a copy with a size of its own takes from a fullscreen source:
/// the source's, as leaving fullscreen where the copy is gives it, then at
/// the copy's size and inside the work area there. The source's return is in
/// the pixels of the monitor it entered fullscreen on, which leaving scales
/// from, and the size is in the copy's, so leaving must not scale it again
/// (window-frame.md 2026-10-20 FWDGEOM2).
fn sizedReturn(back: TopLevel.Return, own: Own) TopLevel.Return {
    var sized = returnOn(back, own.here);
    const info = own.here.info;
    const size = own.size;
    sized.monitor = own.here;
    sized.rect = fitRectInWork(sized.rect.left, sized.rect.top, size.width, size.height, info.rcWork);
    const normal = workspaceRectToScreen(sized.placement.rcNormalPosition, info);
    sized.placement.rcNormalPosition = screenRectToWorkspace(
        fitRectInWork(normal.left, normal.top, size.width, size.height, info.rcWork),
        info,
    );
    return sized;
}

/// The rect a fullscreen window takes on the monitor whose rect is `monitor`
/// so that it does not cover that monitor exactly, or null to keep `monitor`
/// (#598). Windows can take a window whose OpenGL surface covers a monitor
/// exactly out of desktop composition (PresentMon: "Hardware: Legacy Flip"),
/// and every switch back into it (Alt+Tab, an IME candidate window) shows
/// black. One physical pixel past an edge kept every present composed on the
/// reporter's machine. The edge is the first of bottom, right, top and left
/// that has no neighbour, so the extra pixel lands on no monitor.
///
/// A neighbour on an edge is another monitor in `others` that intersects the
/// one-pixel row or column just past that edge, along the edge's whole length:
/// it overlaps the edge's span by at least one pixel and covers the first
/// pixel past it. A monitor that touches only at a corner, or that lies past a
/// gap, is no neighbour. `others` may hold `monitor` itself, which never
/// reaches past its own edges. An edge at the i32 limit cannot grow and the
/// next is tried. Null when no edge is free.
pub fn composedFullscreenRect(monitor: RECT, others: []const RECT) ?RECT {
    for ([_]enum { bottom, right, top, left }{ .bottom, .right, .top, .left }) |edge| {
        var strip = monitor;
        switch (edge) {
            .bottom => {
                strip.top = monitor.bottom;
                strip.bottom = std.math.add(i32, monitor.bottom, 1) catch continue;
            },
            .right => {
                strip.left = monitor.right;
                strip.right = std.math.add(i32, monitor.right, 1) catch continue;
            },
            .top => {
                strip.bottom = monitor.top;
                strip.top = std.math.sub(i32, monitor.top, 1) catch continue;
            },
            .left => {
                strip.right = monitor.left;
                strip.left = std.math.sub(i32, monitor.left, 1) catch continue;
            },
        }
        for (others) |other| {
            if (strip.left < other.right and other.left < strip.right and
                strip.top < other.bottom and other.top < strip.bottom) break;
        } else return .{
            .left = @min(monitor.left, strip.left),
            .top = @min(monitor.top, strip.top),
            .right = @max(monitor.right, strip.right),
            .bottom = @max(monitor.bottom, strip.bottom),
        };
    }
    return null;
}

fn fullscreenRestoreRect(rect: RECT, old_work: RECT, new_work: RECT, old_dpi: u32, new_dpi: u32) RECT {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    const scale = old_dpi > 0 and new_dpi > 0;
    return fitRectInWork(
        rect.left + new_work.left - old_work.left,
        rect.top + new_work.top - old_work.top,
        if (scale) mulDiv(width, new_dpi, old_dpi) else width,
        if (scale) mulDiv(height, new_dpi, old_dpi) else height,
        new_work,
    );
}

/// The rect at (`left`, `top`) of the given size, moved to the nearest place
/// inside `work`. Keep the logical size when it fits. An oversized rectangle
/// can overlap a neighbour more than this monitor, causing Windows to select
/// that neighbour's DPI again; cap it to the work area.
pub fn fitRectInWork(left: i32, top: i32, width: i32, height: i32, work: RECT) RECT {
    const fitted_width = @min(width, work.right - work.left);
    const fitted_height = @min(height, work.bottom - work.top);
    const fitted_left = @max(work.left, @min(left, work.right - fitted_width));
    const fitted_top = @max(work.top, @min(top, work.bottom - fitted_height));
    return .{
        .left = fitted_left,
        .top = fitted_top,
        .right = fitted_left + fitted_width,
        .bottom = fitted_top + fitted_height,
    };
}

/// How far a new window sits below and right of the one it was opened from,
/// about a caption height.
pub fn cascadeStep(dpi: u32) i32 {
    return mulDiv(32, @max(dpi, 96), 96);
}

/// `rect` moved `step` down and right, kept inside `work`.
fn cascadedRect(rect: RECT, step: i32, work: RECT) RECT {
    return fitRectInWork(rect.left + step, rect.top + step, rect.right - rect.left, rect.bottom - rect.top, work);
}

/// A rect in workspace coordinates (what `GetWindowPlacement` reports for a
/// window without `WS_EX_TOOLWINDOW`) as screen coordinates, for the monitor
/// the window is on. This is the convention leaving fullscreen uses.
pub fn workspaceRectToScreen(rect: RECT, monitor: MONITORINFO) RECT {
    const dx = monitor.rcWork.left - monitor.rcMonitor.left;
    const dy = monitor.rcWork.top - monitor.rcMonitor.top;
    return .{
        .left = rect.left + dx,
        .top = rect.top + dy,
        .right = rect.right + dx,
        .bottom = rect.bottom + dy,
    };
}

/// The inverse of `workspaceRectToScreen`.
pub fn screenRectToWorkspace(rect: RECT, info: MONITORINFO) RECT {
    const dx = info.rcWork.left - info.rcMonitor.left;
    const dy = info.rcWork.top - info.rcMonitor.top;
    return .{
        .left = rect.left - dx,
        .top = rect.top - dy,
        .right = rect.right - dx,
        .bottom = rect.bottom - dy,
    };
}

/// `value * numerator / denominator` as kernel32's `MulDiv` (which this
/// file cannot call) gives it for a denominator above zero: the product in
/// 64 bits, rounded half away from zero, and -1 for a result that does not
/// fit. Every caller scales by DPIs, which are above zero.
fn mulDiv(value: i32, numerator: u32, denominator: u32) i32 {
    std.debug.assert(denominator > 0);
    const product = @as(i64, value) * numerator;
    const half: i64 = denominator / 2;
    const rounded = if (product < 0) product - half else product + half;
    return std.math.cast(i32, @divTrunc(rounded, @as(i64, denominator))) orelse -1;
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
    // Fullscreen comes with its place, after its first show (`place`).
    const back: TopLevel.Return = .{ .rect = std.mem.zeroes(RECT), .placement = std.mem.zeroes(WINDOWPLACEMENT), .monitor = null };
    const source: Snapshot = .{ .state = .{ .decorations_visible = false, .decorations_overridden = true, .topmost = true, .opacity = 0.6, .force_opaque = true, .fullscreen = back } };
    var copy = plan(.copy, .{ .opacity = 0.8 }, .{}, &source, .activate, 0);
    try std.testing.expectEqual(TopLevel{ .decorations_visible = false, .decorations_overridden = true, .topmost = true, .opacity = 0.6, .force_opaque = true }, copy.top_level);
    try std.testing.expectEqualDeep(source, copy.source.?);
    // A forward's decorations and opacity are the copy's own, so a reload
    // gives it the config's decorations again; it still floats as its
    // source does.
    copy = plan(.copy, .{ .opacity = 0.8 }, .{ .decoration = true, .opacity = true }, &source, .activate, 0);
    try std.testing.expectEqual(TopLevel{ .topmost = true, .opacity = 0.8 }, copy.top_level);
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

/// How the session saves a window and how a restored one starts: its normal
/// rect in screen coordinates, whether it is (or restores to) maximized, and
/// whether it is fullscreen and leaves fullscreen maximized, as the file's
/// `state` and `fullscreen_maximized` say. What capture gives
/// (`window_state.sessionPlacement`) is what restore takes
/// (`window_state.Origin.restore`).
pub const SavedPlacement = struct {
    rect: ?RECT,
    maximized: bool,
    fullscreen: bool = false,
    fullscreen_maximized: bool = false,
};

/// How a fullscreen window is saved: fullscreen, with the window it leaves
/// fullscreen to, `back`, as its normal rect, never the popup's monitor rect
/// (window-frame.md 2026-10-25 FULLSCREEN-SESSION-01). A maximized return's
/// normal rect is in the workspace coordinates of the monitor `back` is on.
/// With no area there is no trustworthy rect, and nothing is saved.
pub fn savedFullscreen(back: TopLevel.Return) ?SavedPlacement {
    const maximized = back.placement.showCmd == c.SW_MAXIMIZE;
    var rect = back.rect;
    if (maximized) {
        rect = back.placement.rcNormalPosition;
        if (back.monitor) |here| rect = workspaceRectToScreen(rect, here.info);
    }
    if (rect.right <= rect.left or rect.bottom <= rect.top) return null;
    return .{ .rect = rect, .maximized = false, .fullscreen = true, .fullscreen_maximized = maximized };
}

/// What a restored window, or a launched layout's, enters once all its tabs
/// are there: `maximize` and `fullscreen` from its config, as any new window
/// (#496), and a saved fullscreen, maximized when it left fullscreen so. Its
/// saved rect is in place by then, so that is the normal rect it returns to.
pub fn forRestore(wants: Wants, saved: SavedPlacement) Enter {
    return .{
        .maximize = wants.maximize or (saved.fullscreen and saved.fullscreen_maximized),
        .fullscreen = wants.fullscreen or saved.fullscreen,
    };
}

/// How much of a restored window's title bar must be on a monitor for the
/// user to be able to grab it: this wide and half as tall, in physical
/// pixels. The saved rect is in the pixels of a monitor this process may not
/// have seen yet, and the host being placed is on another, so no DPI is
/// right to scale by; a caption at 100%, still a target at 300%.
pub const restore_grab: i32 = 48;

/// Where a window saved at `rect` (screen coordinates) goes now that the
/// monitors' work areas are `works`. One whose title bar can still be grabbed
/// stays exactly where it was, whatever its other edges do: a snapped window
/// overhangs its monitor by its invisible frame. One that cannot (its monitor
/// was unplugged, or the layout changed) moves to the nearest work area, its
/// size capped to it.
pub fn restoredRectOnScreen(rect: RECT, works: []const RECT, grab: i32) RECT {
    if (works.len == 0) return rect;
    // The rect comes from a file on disk: any i32 is possible, so differences
    // of coordinates are taken in 64 bits.
    const grab_width = @min(grab, rect.right - rect.left);
    var nearest = works[0];
    var nearest_gap: i64 = std.math.maxInt(i64);
    for (works) |work| {
        const visible_width = @as(i64, @min(rect.right, work.right)) - @max(rect.left, work.left);
        const visible_height = @as(i64, @min(rect.top, work.bottom - grab) + grab) - @max(rect.top, work.top);
        if (visible_width >= grab_width and visible_height >= @divTrunc(grab, 2)) return rect;

        const gap_x: i64 = @max(0, @max(@as(i64, work.left) - rect.right, @as(i64, rect.left) - work.right));
        const gap_y: i64 = @max(0, @max(@as(i64, work.top) - rect.bottom, @as(i64, rect.top) - work.bottom));
        const gap = gap_x + gap_y;
        if (gap < nearest_gap) {
            nearest = work;
            nearest_gap = gap;
        }
    }
    return fitRectInWork(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, nearest);
}

fn testRect(left: i32, top: i32, right: i32, bottom: i32) RECT {
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn testMonitor(id: usize, dpi: u32, monitor: RECT, work: RECT) Monitor {
    return .{ .id = id, .dpi = dpi, .info = .{ .cbSize = @sizeOf(MONITORINFO), .rcMonitor = monitor, .rcWork = work, .dwFlags = 0 } };
}

fn testPlacement(normal: RECT, flags: u32, show_cmd: u32) WINDOWPLACEMENT {
    var placement = std.mem.zeroes(WINDOWPLACEMENT);
    placement.length = @sizeOf(WINDOWPLACEMENT);
    placement.flags = flags;
    placement.showCmd = show_cmd;
    placement.rcNormalPosition = normal;
    return placement;
}

/// The three monitors window-frame.md 2026-10-20 (FWDGEOM2) measured on: a
/// 3840x2160 at 144 DPI, a 1920x1080 at 96 DPI right of it, and a portrait
/// 1080x1920 at 96 DPI left of it whose taskbar is at the top, so that
/// workspace and screen coordinates differ there. As values they run on a
/// runner with one monitor.
const test_monitors = struct {
    const big = testMonitor(1, 144, testRect(0, 0, 3840, 2160), testRect(0, 0, 3840, 2088));
    const side = testMonitor(2, 96, testRect(3840, 0, 5760, 1080), testRect(3840, 0, 5760, 1032));
    const portrait = testMonitor(3, 96, testRect(-1080, 0, 0, 1920), testRect(-1080, 48, 0, 1920));
};

test "win32 a copy goes one cascade step off its source, inside its work area, past the windows already there" {
    const big = test_monitors.big;
    const own: Own = .{ .size = .{ .width = 900, .height = 700 }, .here = big };
    const normal: Snapshot = .{ .state = .{}, .rect = testRect(100, 100, 1380, 900), .monitor = big };
    const Case = struct {
        source: Snapshot,
        wants: Wants = .{},
        forwarded: Forwarded = .{},
        occupied: []const POINT = &.{},
        own: ?Own = null,
        rect: RECT,
        flags: u32 = c.SWP_NOACTIVATE,
    };
    for ([_]Case{
        // One step, 48 px at 144 DPI, at the source's size.
        .{ .source = normal, .rect = testRect(148, 148, 1428, 948) },
        // On past the windows already there, so the third copy of one
        // window goes where the first two are not.
        .{ .source = normal, .occupied = &.{ .{ .x = 148, .y = 148 }, .{ .x = 196, .y = 196 } }, .rect = testRect(244, 244, 1524, 1044) },
        // At the corner of its work area there is no room to step: it stays
        // on the monitor, at the same size, over the source.
        .{
            .source = .{ .state = .{}, .rect = testRect(3200, 1608, 3840, 2088), .monitor = big },
            .occupied = &.{.{ .x = 3200, .y = 1608 }},
            .rect = testRect(3200, 1608, 3840, 2088),
        },
        // Minimized: the rect it restores to, from workspace to screen
        // coordinates under the portrait's top taskbar, not the sliver it
        // has under the taskbar.
        .{
            .source = .{
                .state = .{},
                .rect = testRect(-1080, 1880, -843, 1919),
                .placement = testPlacement(testRect(-980, 52, -340, 532), 0, c.SW_SHOWMINIMIZED),
                .iconic = true,
                .monitor = test_monitors.portrait,
            },
            .rect = testRect(-948, 132, -308, 612),
        },
        // Maximized, minimized and restored twice, a normal window keeps
        // WPF_RESTORETOMAXIMIZED in its placement: its copy is normal too.
        .{
            .source = .{ .state = .{}, .rect = testRect(100, 100, 1380, 900), .placement = testPlacement(testRect(100, 100, 1380, 900), c.WPF_RESTORETOMAXIMIZED, c.SW_RESTORE), .monitor = big },
            .rect = testRect(148, 148, 1428, 948),
        },
        // `window-position-x/y` keep the place it was created at; the size
        // is the source's.
        .{ .source = normal, .wants = .{ .position = .{ .x = 300, .y = 310 } }, .rect = testRect(148, 148, 1428, 948), .flags = c.SWP_NOACTIVATE | c.SWP_NOMOVE },
        // A size of its own replaces the source's, one step off it.
        .{ .source = normal, .wants = .{ .sized = true }, .forwarded = .{ .size = true }, .own = own, .rect = testRect(148, 148, 1048, 848) },
        // Placed and sized by its own config it takes neither: core init
        // sized it where it is, which can be past this work area.
        .{
            .source = normal,
            .wants = .{ .position = .{ .x = 300, .y = 310 }, .sized = true },
            .forwarded = .{ .size = true },
            .own = own,
            .rect = testRect(148, 148, 1048, 848),
            .flags = c.SWP_NOACTIVATE | c.SWP_NOMOVE | c.SWP_NOSIZE,
        },
    }) |case| {
        const p = plan(.copy, case.wants, case.forwarded, &case.source, .activate, c.OS_BUILD_WIN11_21H2);
        const placed = place(&p, .of(&case.occupied), case.own);
        try std.testing.expectEqualDeep(case.rect, placed.rect);
        try std.testing.expectEqual(case.flags, placed.flags);
        try std.testing.expect(placed.maximize == null and placed.fullscreen == null);
    }
}

test "win32 a copy of a maximized or fullscreen window starts in that state, and its own size stays its own" {
    const sized: Wants = .{ .sized = true };
    const forwarded: Forwarded = .{ .size = true };

    // Maximized, or minimized from maximized: maximized again, never
    // minimized with it, over the source's normal rect, which the window
    // is placed at first (in screen coordinates) and keeps (in workspace
    // ones).
    const portrait = test_monitors.portrait;
    const normal = testRect(-980, 52, -340, 532);
    for ([_]Snapshot{
        .{ .state = .{}, .placement = testPlacement(normal, 0, c.SW_MAXIMIZE), .zoomed = true, .monitor = portrait },
        .{ .state = .{}, .placement = testPlacement(normal, c.WPF_RESTORETOMAXIMIZED, c.SW_SHOWMINIMIZED), .iconic = true, .monitor = portrait },
    }) |source| {
        const copy = plan(.copy, .{}, .{}, &source, .activate, c.OS_BUILD_WIN11_21H2);
        var placed = place(&copy, .none, null);
        try std.testing.expectEqualDeep(testRect(-980, 100, -340, 580), placed.rect);
        try std.testing.expectEqual(@as(u32, c.SW_MAXIMIZE), placed.maximize.?.showCmd);
        try std.testing.expectEqualDeep(normal, placed.maximize.?.rcNormalPosition);
        // Its own size, at the source's normal top-left.
        const own_copy = plan(.copy, sized, forwarded, &source, .activate, c.OS_BUILD_WIN11_21H2);
        placed = place(&own_copy, .none, .{ .size = .{ .width = 600, .height = 400 }, .here = portrait });
        try std.testing.expectEqualDeep(testRect(-980, 100, -380, 500), placed.rect);
        try std.testing.expectEqualDeep(testRect(-980, 52, -380, 452), placed.maximize.?.rcNormalPosition);
    }

    // Fullscreen: its monitor's rect, wherever `window-position-x/y` would
    // put it and also once the source is minimized (its own rect is then a
    // sliver), and it leaves fullscreen to the source's return.
    const big = test_monitors.big;
    const side = test_monitors.side;
    const corner = testRect(3540, 1888, 3820, 2068);
    const back: TopLevel.Return = .{ .rect = corner, .placement = testPlacement(corner, 0, c.SW_RESTORE), .monitor = big };
    for ([_]bool{ false, true }) |iconic| {
        const source: Snapshot = .{
            .state = .{ .fullscreen = back },
            .rect = if (iconic) testRect(3840, 1040, 4077, 1079) else side.info.rcMonitor,
            .iconic = iconic,
            .monitor = side,
        };
        const copy = plan(.copy, .{ .position = .{ .x = 10, .y = 20 } }, .{}, &source, .activate, c.OS_BUILD_WIN11_21H2);
        const placed = place(&copy, .none, null);
        try std.testing.expectEqualDeep(side.info.rcMonitor, placed.rect);
        try std.testing.expectEqual(@as(u32, c.SWP_NOACTIVATE), placed.flags);
        try std.testing.expectEqualDeep(back, placed.fullscreen.?);
    }

    // With a size of its own it leaves fullscreen to that size where the
    // source's return lands on the monitor it is on, inside the work area
    // there, and that return is no longer scaled from the monitor the source
    // entered fullscreen on (FWDGEOM2: a 400x300 client came back 261x187
    // at 96 DPI). The source entered at 144 DPI near the far corner. Moved
    // to the 96 DPI monitor, the return is moved and scaled there; on its
    // own monitor it is only fitted.
    for ([_]struct { Monitor, RECT }{
        .{ side, testRect(5160, 582, 5760, 1032) },
        .{ big, testRect(3240, 1638, 3840, 2088) },
    }) |case| {
        const here, const expected = case;
        const source: Snapshot = .{ .state = .{ .fullscreen = back }, .rect = here.info.rcMonitor, .monitor = here };
        const copy = plan(.copy, sized, forwarded, &source, .activate, c.OS_BUILD_WIN11_21H2);
        const placed = place(&copy, .none, .{ .size = .{ .width = 600, .height = 450 }, .here = here });
        try std.testing.expectEqualDeep(here.info.rcMonitor, placed.rect);
        const sized_back = placed.fullscreen.?;
        try std.testing.expectEqualDeep(expected, sized_back.rect);
        // Neither monitor offsets its workspace coordinates.
        try std.testing.expectEqualDeep(expected, sized_back.placement.rcNormalPosition);
        try std.testing.expectEqual(here.id, sized_back.monitor.?.id);
    }
}

test "win32 fullscreen restore translates work areas and scales size to fit" {
    const old_work: RECT = .{ .left = 0, .top = 40, .right = 3840, .bottom = 2160 };
    const new_work: RECT = .{ .left = -1920, .top = -1080, .right = 0, .bottom = 0 };
    const rect: RECT = .{ .left = 100, .top = 140, .right = 1500, .bottom = 1040 };
    try std.testing.expectEqualDeep(rect, fullscreenRestoreRect(rect, old_work, old_work, 144, 144));
    const moved = fullscreenRestoreRect(rect, old_work, new_work, 144, 96);
    try std.testing.expectEqualDeep(RECT{ .left = -1820, .top = -980, .right = -887, .bottom = -380 }, moved);
    // MulDiv rounds the fractional width. Returning to the old scale is
    // within one physical pixel and never scales absolute desktop origins.
    const back = fullscreenRestoreRect(moved, new_work, old_work, 96, 144);
    try std.testing.expectEqualDeep(rect, back);
    const portrait: RECT = .{ .left = -1080, .top = 0, .right = 0, .bottom = 1872 };
    const edge: RECT = .{ .left = 3000, .top = 1700, .right = 3800, .bottom = 2100 };
    const clamped = fullscreenRestoreRect(edge, old_work, portrait, 144, 96);
    try std.testing.expectEqualDeep(RECT{ .left = -533, .top = 1605, .right = 0, .bottom = 1872 }, clamped);
    const oversized: RECT = .{ .left = 150, .top = 190, .right = 3950, .bottom = 1390 };
    try std.testing.expectEqualDeep(RECT{ .left = -1080, .top = 150, .right = 0, .bottom = 950 }, fullscreenRestoreRect(oversized, old_work, portrait, 144, 96));

    // `returnOn`: the monitor and DPI it entered on give the return back as
    // it was, and so does a window that recorded no monitor.
    const left = test_monitors.portrait;
    const entered: TopLevel.Return = .{
        .rect = testRect(-980, 100, -340, 580),
        .placement = testPlacement(testRect(-980, 52, -340, 532), 0, c.SW_MAXIMIZE),
        .monitor = left,
    };
    try std.testing.expectEqualDeep(entered, returnOn(entered, left));
    var unrecorded = entered;
    unrecorded.monitor = null;
    try std.testing.expectEqualDeep(unrecorded, returnOn(unrecorded, test_monitors.side));
    // On another monitor the normal rect goes from the workspace coordinates
    // under the portrait's top taskbar to screen ones before it moves, and to
    // the other monitor's after, so the taskbar's offset is not added twice
    // (2026-10-11).
    const moved_back = returnOn(entered, test_monitors.side);
    try std.testing.expectEqualDeep(testRect(3940, 52, 4580, 532), moved_back.rect);
    try std.testing.expectEqualDeep(testRect(3940, 52, 4580, 532), moved_back.placement.rcNormalPosition);
    try std.testing.expectEqual(@as(usize, 2), moved_back.monitor.?.id);
}

test "win32 a composed fullscreen window grows 1 px past its first free edge: bottom, right, top, then left" {
    const m = testRect(0, 0, 1920, 1080);
    const Case = struct { others: []const RECT, grown: RECT };
    for ([_]Case{
        // Alone, or listed among the monitors: the bottom.
        .{ .others = &.{}, .grown = testRect(0, 0, 1920, 1081) },
        .{ .others = &.{m}, .grown = testRect(0, 0, 1920, 1081) },
        // Each neighbour moves it to the next edge in order.
        .{ .others = &.{ m, testRect(0, 1080, 1920, 2160) }, .grown = testRect(0, 0, 1921, 1080) },
        .{ .others = &.{ testRect(0, 1080, 1920, 2160), testRect(1920, 0, 3840, 1080) }, .grown = testRect(0, -1, 1920, 1080) },
        .{ .others = &.{ testRect(0, 1080, 1920, 2160), testRect(1920, 0, 3840, 1080), testRect(0, -1080, 1920, 0) }, .grown = testRect(-1, 0, 1920, 1080) },
        // A neighbour along part of the edge is enough: one row of it.
        .{ .others = &.{testRect(1919, 1080, 2560, 1081)}, .grown = testRect(0, 0, 1921, 1080) },
        // A neighbour on one edge leaves the others: only the left one.
        .{ .others = &.{testRect(-2560, 0, 0, 1440)}, .grown = testRect(0, 0, 1920, 1081) },
        // A monitor that touches only at a corner, or past a gap of one
        // pixel, is no neighbour: the pixel past the edge is on no monitor.
        .{ .others = &.{ testRect(1920, 1080, 3840, 2160), testRect(-1920, 1080, 0, 2160) }, .grown = testRect(0, 0, 1920, 1081) },
        .{ .others = &.{testRect(0, 1081, 1920, 2161)}, .grown = testRect(0, 0, 1920, 1081) },
        // A monitor that overlaps the edge, not only one that abuts it.
        .{ .others = &.{testRect(100, 1000, 900, 1600)}, .grown = testRect(0, 0, 1921, 1080) },
    }) |case| {
        try std.testing.expectEqualDeep(@as(?RECT, case.grown), composedFullscreenRect(m, case.others));
    }

    // A monitor that is not the primary, at negative coordinates: the
    // portrait one left of the 3840x2160 one. That one is beside the row
    // below it, not in it, so it grows at the bottom.
    const portrait = test_monitors.portrait.info.rcMonitor;
    const all = [_]RECT{ test_monitors.big.info.rcMonitor, test_monitors.side.info.rcMonitor, portrait };
    try std.testing.expectEqualDeep(@as(?RECT, testRect(-1080, 0, 0, 1921)), composedFullscreenRect(portrait, &all));
    // So for the 1920x1080 one right of it, though the big one reaches
    // below its bottom.
    try std.testing.expectEqualDeep(@as(?RECT, testRect(3840, 0, 5760, 1081)), composedFullscreenRect(test_monitors.side.info.rcMonitor, &all));
    // Stacked on top of the big one, at negative y: it grows at the right,
    // and with a monitor there too, at the top, further into negative y.
    const above = testRect(0, -1080, 1920, 0);
    try std.testing.expectEqualDeep(@as(?RECT, testRect(0, -1080, 1921, 0)), composedFullscreenRect(above, &.{ test_monitors.big.info.rcMonitor, above }));
    try std.testing.expectEqualDeep(@as(?RECT, testRect(0, -1081, 1920, 0)), composedFullscreenRect(above, &.{ test_monitors.big.info.rcMonitor, testRect(1920, -1080, 3840, 0) }));
}

test "win32 a composed fullscreen window with no free edge gets null and keeps today's exact monitor rect" {
    const m = testRect(0, 0, 1920, 1080);
    // A monitor past every edge: a 3x3 wall, this one in the middle.
    const wall = [_]RECT{
        testRect(-1920, -1080, 0, 0),   testRect(0, -1080, 1920, 0),   testRect(1920, -1080, 3840, 0),
        testRect(-1920, 0, 0, 1080),    m,                             testRect(1920, 0, 3840, 1080),
        testRect(-1920, 1080, 0, 2160), testRect(0, 1080, 1920, 2160), testRect(1920, 1080, 3840, 2160),
    };
    try std.testing.expectEqual(@as(?RECT, null), composedFullscreenRect(m, &wall));
    // Just the four edge neighbours, without the corners.
    try std.testing.expectEqual(@as(?RECT, null), composedFullscreenRect(m, &.{ wall[1], wall[3], wall[5], wall[7] }));

    // Integer overflow: an edge at the i32 limit cannot grow, so the next
    // free edge does, and with all four there, none does.
    const max = std.math.maxInt(i32);
    const min = std.math.minInt(i32);
    try std.testing.expectEqualDeep(@as(?RECT, testRect(0, 0, 1921, max)), composedFullscreenRect(testRect(0, 0, 1920, max), &.{}));
    try std.testing.expectEqualDeep(@as(?RECT, testRect(min, -1, max, max)), composedFullscreenRect(testRect(min, 0, max, max), &.{}));
    try std.testing.expectEqual(@as(?RECT, null), composedFullscreenRect(testRect(min, min, max, max), &.{}));
}

test "win32 a saved window rect on a monitor that is gone moves to the nearest work area" {
    const grab = restore_grab;
    // A laptop's screen with a second monitor to its left, taskbar at the bottom.
    const left: RECT = .{ .left = -1920, .top = 0, .right = 0, .bottom = 1040 };
    const main_work: RECT = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 };
    const works = [_]RECT{ main_work, left };
    const wide: RECT = .{ .left = 100, .top = 100, .right = 900, .bottom = 700 };

    // Where there is a monitor, the rect is kept as saved.
    try std.testing.expectEqualDeep(wide, restoredRectOnScreen(wide, &works, grab));
    const straddling: RECT = .{ .left = -400, .top = 50, .right = 400, .bottom = 650 };
    try std.testing.expectEqualDeep(straddling, restoredRectOnScreen(straddling, &works, grab));
    // A snapped window overhangs its monitor by its invisible frame.
    const snapped: RECT = .{ .left = -7, .top = 0, .right = 967, .bottom = 1047 };
    try std.testing.expectEqualDeep(snapped, restoredRectOnScreen(snapped, &works, grab));
    // The caption on a monitor and the body hanging off the bottom stays too.
    const hanging: RECT = .{ .left = 100, .top = 900, .right = 900, .bottom = 1500 };
    try std.testing.expectEqualDeep(hanging, restoredRectOnScreen(hanging, &works, grab));

    // Saved on a monitor to the right that was unplugged.
    const unplugged: RECT = .{ .left = 2100, .top = 200, .right = 2900, .bottom = 800 };
    try std.testing.expectEqualDeep(
        RECT{ .left = 1120, .top = 200, .right = 1920, .bottom = 800 },
        restoredRectOnScreen(unplugged, &works, grab),
    );
    // Below every monitor, and above them.
    try std.testing.expectEqualDeep(
        RECT{ .left = 100, .top = 440, .right = 900, .bottom = 1040 },
        restoredRectOnScreen(.{ .left = 100, .top = 3000, .right = 900, .bottom = 3600 }, &works, grab),
    );
    try std.testing.expectEqualDeep(
        RECT{ .left = 100, .top = 0, .right = 900, .bottom = 600 },
        restoredRectOnScreen(.{ .left = 100, .top = -900, .right = 900, .bottom = -300 }, &works, grab),
    );
    // Only a sliver of the title bar on a monitor is not enough to grab.
    try std.testing.expectEqualDeep(
        RECT{ .left = 1120, .top = 100, .right = 1920, .bottom = 700 },
        restoredRectOnScreen(.{ .left = 1900, .top = 100, .right = 2700, .bottom = 700 }, &works, grab),
    );
    // The nearest is the monitor to the left when that is where it was.
    try std.testing.expectEqualDeep(
        RECT{ .left = -1920, .top = 100, .right = -1120, .bottom = 700 },
        restoredRectOnScreen(.{ .left = -4000, .top = 100, .right = -3200, .bottom = 700 }, &works, grab),
    );
    // Larger than the monitor it lands on: capped to it.
    try std.testing.expectEqualDeep(
        left,
        restoredRectOnScreen(.{ .left = -9000, .top = -50, .right = -4000, .bottom = 3000 }, &works, grab),
    );
    // No monitor list, no opinion.
    try std.testing.expectEqualDeep(unplugged, restoredRectOnScreen(unplugged, &.{}, grab));

    // The file can say anything an i32 holds, and a window cannot be that far
    // away: no differences of these overflow.
    const min: i32 = std.math.minInt(i32);
    const max: i32 = std.math.maxInt(i32);
    try std.testing.expectEqualDeep(
        RECT{ .left = -1920, .top = 100, .right = -1120, .bottom = 700 },
        restoredRectOnScreen(.{ .left = min, .top = 100, .right = min + 800, .bottom = 700 }, &works, grab),
    );
    try std.testing.expectEqualDeep(
        RECT{ .left = 1120, .top = 440, .right = 1920, .bottom = 1040 },
        restoredRectOnScreen(.{ .left = max - 800, .top = max - 600, .right = max, .bottom = max }, &works, grab),
    );
    try std.testing.expectEqualDeep(
        main_work,
        restoredRectOnScreen(.{ .left = min, .top = min, .right = -1, .bottom = -1 }, &.{main_work}, grab),
    );
}

test "win32 a fullscreen window is saved with the window it leaves fullscreen to, never its popup rect" {
    const normal: RECT = .{ .left = 100, .top = 200, .right = 740, .bottom = 680 };
    // A taskbar on the left, so workspace and screen coordinates differ.
    var back: TopLevel.Return = .{ .rect = normal, .placement = testPlacement(std.mem.zeroes(RECT), 0, c.SW_RESTORE), .monitor = testMonitor(1, 96, testRect(0, 0, 1920, 1080), testRect(48, 0, 1920, 1080)) };
    try std.testing.expectEqual(SavedPlacement{ .rect = normal, .maximized = false, .fullscreen = true }, savedFullscreen(back).?);

    // A maximized return's normal rect is in its monitor's workspace.
    back.placement.showCmd = c.SW_MAXIMIZE;
    back.placement.rcNormalPosition = testRect(52, 200, 692, 680);
    try std.testing.expectEqual(SavedPlacement{ .rect = normal, .maximized = false, .fullscreen = true, .fullscreen_maximized = true }, savedFullscreen(back).?);

    // No trustworthy return rect: no placement, rather than fullscreen with
    // an invented normal rect or the popup's bounds.
    back.placement.rcNormalPosition = std.mem.zeroes(RECT);
    try std.testing.expect(savedFullscreen(back) == null);
    back.placement.showCmd = c.SW_RESTORE;
    back.rect = std.mem.zeroes(RECT);
    try std.testing.expect(savedFullscreen(back) == null);
}

test "win32 a restored window enters its config's maximize and fullscreen, and a saved fullscreen" {
    const normal: SavedPlacement = .{ .rect = null, .maximized = false };
    const fullscreen: SavedPlacement = .{ .rect = null, .maximized = false, .fullscreen = true };
    const fullscreen_maximized: SavedPlacement = .{ .rect = null, .maximized = false, .fullscreen = true, .fullscreen_maximized = true };
    const Case = struct { wants: Wants = .{}, saved: SavedPlacement, enter: Enter };
    for ([_]Case{
        .{ .saved = normal, .enter = .{} },
        // A saved maximize is the placement's, applied with the saved rect,
        // not a start.
        .{ .saved = .{ .rect = null, .maximized = true }, .enter = .{} },
        .{ .wants = .{ .maximize = true }, .saved = normal, .enter = .{ .maximize = true } },
        .{ .wants = .{ .fullscreen = true }, .saved = normal, .enter = .{ .fullscreen = true } },
        // A saved fullscreen comes back with `fullscreen = false` in the
        // config, leaving fullscreen maximized when it was.
        .{ .saved = fullscreen, .enter = .{ .fullscreen = true } },
        .{ .saved = fullscreen_maximized, .enter = .{ .maximize = true, .fullscreen = true } },
        .{ .wants = .{ .maximize = true }, .saved = fullscreen, .enter = .{ .maximize = true, .fullscreen = true } },
    }) |case| {
        try std.testing.expectEqual(case.enter, forRestore(case.wants, case.saved));
    }
}

test "win32 a window shows its opacity as an alpha, and opaque none" {
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

test "win32 an OpenGL window shows its opacity in the background only, a D3D11 window fades whole, High Contrast neither" {
    const Shows = TopLevel.Shows;
    const Case = struct { top_level: TopLevel, opengl: bool, high_contrast: bool = false, blur_behind_failed: bool = false, shows: Shows };
    for ([_]Case{
        // OpenGL panes draw the background at the window's opacity, and the
        // window is never layered.
        .{ .top_level = .{ .opacity = 0.5 }, .opengl = true, .shows = .{ .background = 128, .pane_opacity = 0.5 } },
        // Opaque, toggled opaque or High Contrast: no blur-behind, and the
        // panes draw at 1 whatever their config says.
        .{ .top_level = .{}, .opengl = true, .shows = .{ .pane_opacity = 1.0 } },
        .{ .top_level = .{ .opacity = 0.5, .force_opaque = true }, .opengl = true, .shows = .{ .pane_opacity = 1.0 } },
        .{ .top_level = .{ .opacity = 0.5 }, .opengl = true, .high_contrast = true, .shows = .{ .pane_opacity = 1.0 } },
        // A pane on D3D11: the whole window fades, as before #640, and its
        // panes keep their config's opacity; opaque, they draw at 1 too.
        .{ .top_level = .{ .opacity = 0.5 }, .opengl = false, .shows = .{ .layered = 128 } },
        .{ .top_level = .{}, .opengl = false, .shows = .{ .pane_opacity = 1.0 } },
        .{ .top_level = .{ .opacity = 0.5, .force_opaque = true }, .opengl = false, .shows = .{ .pane_opacity = 1.0 } },
        .{ .top_level = .{ .opacity = 0.5 }, .opengl = false, .high_contrast = true, .shows = .{ .pane_opacity = 1.0 } },
        // Blur-behind failed on this window: OpenGL panes fade whole too,
        // and opaque is still opaque.
        .{ .top_level = .{ .opacity = 0.5 }, .opengl = true, .blur_behind_failed = true, .shows = .{ .layered = 128 } },
        .{ .top_level = .{}, .opengl = true, .blur_behind_failed = true, .shows = .{ .pane_opacity = 1.0 } },
        .{ .top_level = .{ .opacity = 0.5 }, .opengl = true, .high_contrast = true, .blur_behind_failed = true, .shows = .{ .pane_opacity = 1.0 } },
    }) |case| {
        try std.testing.expectEqualDeep(case.shows, case.top_level.shows(case.opengl, case.high_contrast, case.blur_behind_failed));
    }
}
