//! The state of each top-level window, kept once on its Host
//! (`Host.top_level`), the actions that change it (`perform`, `applyConfig`),
//! the window's `WM_GETMINMAXINFO` answer (`updateMinMaxInfo`), how a new
//! window starts (`begin`, `advance`) and how the session saves one
//! (`sessionPlacement`). The decisions are window_start.zig's, from values;
//! this file carries them out through Win32.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("../win32.zig");
const apprt = @import("../../apprt.zig");
const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const c = @import("consts.zig");
const child_window = @import("child_window.zig");
const chrome_layout = @import("chrome_layout.zig");
const sys = @import("sys.zig");
const win32_theme = @import("../win32_theme.zig");
const win32_types = @import("../win32_types.zig");
const window_start = @import("window_start.zig");
const App = win32.App;
const BOOL = win32_types.BOOL;
const HDC = win32_types.HDC;
const HWND = win32_types.HWND;
const Host = win32.Host;
const LPARAM = win32_types.LPARAM;
const MINMAXINFO = sys.MINMAXINFO;
const MONITORINFO = sys.MONITORINFO;
const POINT = sys.POINT;
const RECT = sys.RECT;
const Surface = win32.Surface;
const UINT = win32_types.UINT;
const WINDOWPLACEMENT = sys.WINDOWPLACEMENT;
const configuredHostWindowPosition = win32.configuredHostWindowPosition;
const forwardedArgvSetsKey = @import("ipc_server.zig").forwardedArgvSetsKey;
const lastError = child_window.lastError;
const log = win32.log;
const test_support = win32.test_support;
const CoreApp = @import("../../App.zig");
const LPCWSTR = win32_types.LPCWSTR;
const SafeModeAppFixture = test_support.SafeModeAppFixture;
const TestSession = test_support.TestSession;
const WindowStartTestApp = test_support.WindowStartTestApp;
const cascadeStep = window_start.cascadeStep;
const default_title = win32.default_title;
const monitorInfo = @import("quick_terminal_host.zig").monitorInfo;
const placementTestApp = test_support.placementTestApp;
const placementTestHost = test_support.placementTestHost;
const prompt_label_class = child_window.prompt_label_class;
const rectEquals = chrome_layout.rectEquals;
const runOnHiddenDesktop = test_support.runOnHiddenDesktop;
const testBackgroundAlpha = test_support.testBackgroundAlpha;
const testHostIsLayered = test_support.testHostIsLayered;
const testLayeredAlpha = test_support.testLayeredAlpha;
const testWindowStyle = test_support.testWindowStyle;
const win32_quick_terminal = @import("../win32_quick_terminal.zig");

pub const TopLevel = window_start.TopLevel;
pub const InitialShow = window_start.InitialShow;
const Enter = window_start.Enter;
pub const undecoratedKeepsFrame = window_start.undecoratedKeepsFrame;
pub const hostStyle = window_start.hostStyle;
const fitRectInWork = window_start.fitRectInWork;
pub const workspaceRectToScreen = window_start.workspaceRectToScreen;
const screenRectToWorkspace = window_start.screenRectToWorkspace;
pub const SavedPlacement = window_start.SavedPlacement;

/// Where a new window comes from, which decides how it starts (`begin`).
pub const Origin = union(window_start.Kind) {
    /// An ordinary new window: the first one, or a new tab with no window to
    /// open it in.
    fresh,
    /// Opened from `source`: `new_window`, a forwarded launch, a profile in
    /// a new window. `forwarded` is the argv a forwarded launch applied to
    /// the new window's config.
    copy: struct { source: *const Host, forwarded: []const [:0]const u8 = &.{} },
    /// A restored session's or launched layout's window, as it was saved.
    /// Session restore places it once its first tab is there
    /// (`.restore_placed`) and gives it `maximize` and `fullscreen` once all
    /// are (`.restore_complete`).
    restore: SavedPlacement,
    /// The quick terminal, first shown as asked.
    quick_terminal: InitialShow,
    /// A handed-off console's window, first shown as its client asked.
    adopted: InitialShow,

    /// A copy of `source`, or a fresh window when there is none to copy
    /// (`Registry.newWindowSource`).
    pub fn from(source: ?*const Host, forwarded: []const [:0]const u8) Origin {
        const host = source orelse return .fresh;
        return .{ .copy = .{ .source = host, .forwarded = forwarded } };
    }
};

/// A pane's metrics, from its own font: core init's `initial_size`,
/// `cell_size` and `size_limit` (`Surface.metrics`). A tab or split starts
/// with those of the pane it is opened from, and a copy's first pane with
/// those of its source's active pane.
pub const PaneMetrics = struct {
    /// The client size `reset_window_size` returns to.
    default_client_size: ?apprt.SurfaceSize = null,
    cell_size_pixels: apprt.action.CellSize = .{ .width = 0, .height = 0 },
    size_limit: apprt.action.SizeLimit = .{ .min_width = 0, .min_height = 0, .max_width = 0, .max_height = 0 },
};

/// How a new window starts, decided by `begin` before it exists: it is
/// created in `plan.top_level` with `plan.style`, at `plan.position` (else
/// `CW_USEDEFAULT`), and its Host keeps the rest (`Host.pending_start`) for
/// `advance` until its last stage.
pub const Pending = struct {
    plan: window_start.Plan,
    /// The metrics of the source's active pane, which a copy's first pane
    /// takes.
    source_pane: ?PaneMetrics = null,
    /// A restored window's saved placement, and what it enters once its tabs
    /// are there (`window_start.forRestore`).
    restore: ?struct { saved: SavedPlacement, enter: Enter } = null,
    /// The last stage carried out.
    reached: ?Stage = null,
};

/// What `config` asks of how its window starts.
fn wants(config: *const configpkg.Config) window_start.Wants {
    return .{
        .position = if (configuredHostWindowPosition(config)) |position| .{ .x = position.x, .y = position.y } else null,
        .decorated = config.@"window-decoration" != .none,
        .opacity = std.math.clamp(config.@"background-opacity", 0.0, 1.0),
        .maximize = config.maximize,
        .fullscreen = config.fullscreen != .false,
        .sized = config.@"window-width" > 0 and config.@"window-height" > 0,
    };
}

/// The window keys `argv`, a forwarded launch's, names. Read from the argv,
/// not from a config that differs from the app's: a forwarded value equal to
/// the app config's would be lost (window-frame.md 2026-10-20, trap 1).
fn forwardedKeys(argv: []const [:0]const u8) window_start.Forwarded {
    return .{
        .size = forwardedArgvSetsKey(argv, "window-width") or forwardedArgvSetsKey(argv, "window-height"),
        .decoration = forwardedArgvSetsKey(argv, "window-decoration"),
        .opacity = forwardedArgvSetsKey(argv, "background-opacity"),
    };
}

/// Decides how a new window with `config` starts, before it exists. A copy
/// reads its source here, once: the window's state and geometry and its
/// active pane's metrics. The windows its cascade steps past are asked when
/// it is placed (`occupiedAround`).
pub fn begin(app: *const App, config: *const configpkg.Config, origin: Origin) !Pending {
    var pending: Pending = .{ .plan = undefined };
    var snapshot: ?window_start.Snapshot = null;
    var argv: []const [:0]const u8 = &.{};
    var show: InitialShow = .activate;
    const wanted = wants(config);
    switch (origin) {
        .copy => |copy| {
            snapshot = try snapshotOf(copy.source);
            if (copy.source.activeSurface()) |pane| pending.source_pane = pane.metrics;
            argv = copy.forwarded;
        },
        .quick_terminal, .adopted => |first_show| show = first_show,
        .restore => |saved| pending.restore = .{ .saved = saved, .enter = window_start.forRestore(wanted, saved) },
        .fresh => {},
    }
    pending.plan = window_start.plan(
        std.meta.activeTag(origin),
        wanted,
        forwardedKeys(argv),
        if (snapshot) |*source| source else null,
        show,
        app.os_build,
    );
    return pending;
}

fn snapshotOf(source: *const Host) !window_start.Snapshot {
    const hwnd = source.hwnd orelse return error.InvalidHost;
    var snapshot: window_start.Snapshot = .{
        .state = source.top_level,
        .iconic = sys.IsIconic(hwnd) != 0,
        .zoomed = sys.IsZoomed(hwnd) != 0,
        // For a minimized window this is the monitor it was on, not the one
        // its icon is on.
        .monitor = try windowMonitor(hwnd),
    };
    snapshot.placement.length = @sizeOf(WINDOWPLACEMENT);
    if (sys.GetWindowPlacement(hwnd, &snapshot.placement) == 0 or
        sys.GetWindowRect(hwnd, &snapshot.rect) == 0) return lastError();
    return snapshot;
}

/// The windows the copy `host` steps past, asked as it is placed: every
/// window on screen but the copy itself (`Registry.windowStartsAt`).
fn occupiedAround(host: *const Host) window_start.Occupied {
    return .{ .ctx = host, .startsAt = struct {
        fn startsAt(ctx: *const anyopaque, corner: POINT) bool {
            const copy: *const Host = @ptrCast(@alignCast(ctx));
            return copy.app.registry.windowStartsAt(corner, copy.hwnd);
        }
    }.startsAt };
}

/// The steps of a new window's start that need the window, in this order,
/// each once.
pub const Stage = enum {
    /// In `App.createHost`, right after `CreateWindowEx` and the shell
    /// compositor attach, while the window is hidden and has no tab.
    created,
    /// In the `Surface.init` that created the window, after core init: the
    /// window's first show.
    before_show,
    /// Right after it: a copy takes its source's state.
    after_show,
    /// A restored window, once its first tab is there: its saved rect and
    /// maximize (as the rect it returns to if a minimized launch minimized
    /// it).
    restore_placed,
    /// A restored window, once all its tabs are there: `maximize` and
    /// `fullscreen`.
    restore_complete,
};

/// Carries out the `at` stage of the start `begin` decided for `host`, which
/// `App.createHost` keeps in `Host.pending_start`. The last stage
/// (`.after_show`, or `.restore_complete` for a restored window) clears it,
/// and a host with no start pending fails with `error.NoWindowStart`.
/// `.before_show` returns whether the pane that first shows the window
/// presents it with focus.
pub fn advance(host: *Host, comptime at: Stage) !(if (at == .before_show) bool else void) {
    const pending = if (host.pending_start) |*start| start else return error.NoWindowStart;
    std.debug.assert(pending.reached == null or @intFromEnum(pending.reached.?) < @intFromEnum(at));
    std.debug.assert(@intFromEnum(at) < @intFromEnum(Stage.restore_placed) or pending.plan.kind == .restore);
    const last: Stage = if (pending.plan.kind == .restore) .restore_complete else .after_show;
    defer {
        if (at == last) host.pending_start = null;
    }
    pending.reached = at;
    return switch (at) {
        .created => onCreated(host, pending),
        .before_show => beforeShow(host, pending),
        .after_show => afterShow(host, pending),
        .restore_placed => placeRestored(host, pending.restore.?.saved),
        .restore_complete => applyWindowStart(host, pending.restore.?.enter),
    };
}

fn onCreated(host: *Host, pending: *const Pending) !void {
    const hwnd = host.hwnd orelse return;
    if (pending.plan.hide_border) win32_theme.WindowThemeAdapter.setHostBorderVisible(hwnd, false);
    // After the shell compositor attach: the frame change resizes the
    // client area, and the host's WM_SIZE resizes its compositor target
    // (window-frame.md 2026-09-23).
    restoreRequestedHostWindowStyle(hwnd, pending.plan.style);
    // A copy starts hidden where it will show, on its source's monitor, so
    // core init runs at that monitor's DPI.
    if (pending.plan.source == null) return;
    const placed = window_start.place(&pending.plan, occupiedAround(host), null);
    if (sys.SetWindowPos(
        hwnd,
        null,
        placed.rect.left,
        placed.rect.top,
        placed.rect.right - placed.rect.left,
        placed.rect.bottom - placed.rect.top,
        placed.flags,
    ) == 0) {
        return lastError();
    }
}

/// The window is shown only now, once GL and core init have succeeded, so a
/// startup failure reaches the fatal dialog without a blank window first.
fn beforeShow(host: *Host, pending: *const Pending) !bool {
    // Translucent before any show, so the window never shows opaque and
    // then fades (#234).
    applyBackgroundOpacity(host) catch |err| {
        log.warn("win32 initial background opacity failed err={}", .{err});
    };
    // A copy of a fullscreen window is a popup over its monitor from
    // `.created`, and shows there first: at the rect it covers fullscreen on
    // the monitor it is on, as its own pane decides (`takeSourceState` keeps
    // it there). `WS_POPUP` is exactly that copy today: `window_start.plan`
    // gives it only to a copy of a fullscreen source without a size of its
    // own; `window-decoration = none` is a bare `WS_OVERLAPPED` (framed on
    // Windows 11), and a config's `fullscreen` starts framed until
    // `enterFullscreen`. The table test "win32
    // a new window is created framed, bare or a popup as its state and Windows
    // build say" pins that; a change there that makes another window a popup
    // widens this gate.
    if (pending.plan.style & c.WS_POPUP != 0) {
        placeFullscreenCopy(host) catch |err| {
            log.warn("win32 fullscreen copy placement failed err={}", .{err});
        };
    }
    try host.refreshChrome();
    try host.layout();
    // `maximize` and `fullscreen` (#496), before the first show, so the
    // window first appears in that state. Core init has already given it
    // `window-width`/`window-height`, so that is the normal rect it returns
    // to. A copy takes them after its source's state.
    if (pending.plan.source == null) applyWindowStart(host, pending.plan.enter);
    const show = pending.plan.show;
    if (show.showCommand()) |command| if (host.hwnd) |hwnd| {
        _ = sys.ShowWindow(hwnd, command);
        _ = sys.UpdateWindow(hwnd);
    };
    return show.takesFocus();
}

fn placeFullscreenCopy(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
    const screen = (try windowMonitor(hwnd)).info.rcMonitor;
    const rect = fullscreenRect(host, screen);
    if (rectEquals(rect, screen)) return;
    if (sys.SetWindowPos(
        hwnd,
        null,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    ) == 0) {
        return lastError();
    }
}

fn afterShow(host: *Host, pending: *const Pending) !void {
    if (pending.plan.source == null) return;
    // Its first pane takes the metrics of its source's active pane, but
    // for a client size of its own.
    if (pending.source_pane) |metrics| if (host.activeSurface()) |pane| {
        const own = pane.metrics.default_client_size;
        pane.metrics = metrics;
        if (pending.plan.keeps.size) pane.metrics.default_client_size = own;
    };
    try takeSourceState(host, pending);
    // After it: a normal source ends in SW_RESTORE.
    applyWindowStart(host, pending.plan.enter);
}

/// The style to write back over the one `CreateWindowEx` gave a host
/// created with `requested`, or null when it kept the request.
///
/// `WS_OVERLAPPED` is 0, so the undecorated host style on Windows 10 (see
/// `undecoratedKeepsFrame`) is a top-level window with neither `WS_POPUP`
/// nor `WS_CHILD`, and `CreateWindowEx` gives every such window
/// `WS_CAPTION` whatever the request says.
/// `SetWindowLongPtr` does not. So with `window-decoration = none`, every
/// window created with no window to copy (the first one, the quick
/// terminal, a restored or adopted window) had a title bar, and a
/// `new_window` clone did not: it and every runtime toggle set the style
/// afterwards through `applyWindowStyle`. Creating the host as `WS_POPUP` instead would
/// avoid the added caption, but `CW_USEDEFAULT` puts a popup at (0, 0)
/// rather than at the next default position, so the first window would
/// move. Windows also forces `WS_CLIPSIBLINGS` on every top-level window,
/// through either API, so that bit is ignored here.
fn createdHostWindowStyleCorrection(requested: u32, created: u32) ?u32 {
    const forced: u32 = c.WS_CLIPSIBLINGS;
    if ((requested & ~forced) == (created & ~forced)) return null;
    return requested;
}

/// Put back the host style `CreateWindowEx` altered (see
/// `createdHostWindowStyleCorrection`). The `.created` stage calls this
/// while the host is still hidden and has no tabs, so no terminal is sized
/// against, or shown with, the frame Windows added.
fn restoreRequestedHostWindowStyle(hwnd: HWND, requested: u32) void {
    const created: u32 = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE))));
    const style = createdHostWindowStyleCorrection(requested, created) orelse return;
    _ = sys.SetWindowLongPtrW(hwnd, c.GWL_STYLE, @bitCast(@as(usize, style)));
    if (sys.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    ) == 0) {
        log.warn("win32 host style restore failed err={}", .{lastError()});
    }
}

fn sizeLimitEquals(a: apprt.action.SizeLimit, b: apprt.action.SizeLimit) bool {
    return a.min_width == b.min_width and
        a.min_height == b.min_height and
        a.max_width == b.max_width and
        a.max_height == b.max_height;
}

/// A window action from any pane of `host`'s window. The window's own
/// actions change the Window, whichever of its panes asked. `size_limit` and
/// `initial_size` come from one pane's font: they are kept on that pane, and
/// the Window acts on them (the active pane's limit is the window's minimum
/// track size; an initial size resizes a window of one pane).
/// Returns false only for `toggle_background_opacity` on an opaque window.
pub fn perform(
    host: *Host,
    pane: *Surface,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .toggle_maximize => toggleMaximize(host),
        .toggle_fullscreen => if (host.top_level.isFullscreen()) try leaveFullscreen(host) else try enterFullscreen(host),
        .toggle_window_decorations => {
            // The style write changes the frame: blur-behind is asserted
            // again after it, whatever it ends in.
            defer refreshBackgroundOpacity(host);
            try setDecorationsVisible(host, !host.top_level.decorations_visible);
            host.top_level.decorations_overridden = true;
        },
        .float_window => {
            host.top_level.topmost = switch (value) {
                .on => true,
                .off => false,
                .toggle => !host.top_level.topmost,
            };
            try applyTopmost(host);
        },
        .toggle_background_opacity => {
            if (!host.top_level.translucent()) return false;
            host.top_level.force_opaque = !host.top_level.force_opaque;
            try applyBackgroundOpacity(host);
        },
        .reset_window_size => try resetWindowSize(host, pane),
        .initial_size => try setInitialSize(host, pane, value),
        .size_limit => setSizeLimit(host, pane, value),
        else => @compileError("not a window action: " ++ @tagName(action)),
    }
    return true;
}

/// The window half of a config change: `window-decoration`, unless a toggle
/// chose the decorations, and `background-opacity` as the window shows it
/// (`App.shownBackgroundOpacity`: a Settings preview of it wins). A
/// decoration failure is logged; an opacity failure is returned.
pub fn applyConfig(host: *Host, config: *const configpkg.Config) !void {
    if (!host.top_level.decorations_overridden) {
        setDecorationsVisible(host, config.@"window-decoration" != .none) catch |err| {
            log.warn("win32 decoration update failed during config reload err={}", .{err});
        };
    }
    host.top_level.opacity = std.math.clamp(host.app.shownBackgroundOpacity(config), 0.0, 1.0);
    if (!host.top_level.translucent()) host.top_level.force_opaque = false;
    try applyBackgroundOpacity(host);
}

/// `WM_GETMINMAXINFO`: the active pane's `size_limit`, which is in client
/// pixels, plus this window's frame. Returns false for a window with no
/// pane, whose limits are Windows' own (`DefWindowProc`).
pub fn updateMinMaxInfo(host: *Host, lParam: LPARAM) bool {
    const limit = (host.activeSurface() orelse return false).metrics.size_limit;
    if (limit.min_width == 0 and
        limit.min_height == 0 and
        limit.max_width == 0 and
        limit.max_height == 0) return true;

    const info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const hwnd = host.hwnd orelse return true;
    var client_rect: RECT = undefined;
    var window_rect: RECT = undefined;
    if (sys.GetClientRect(hwnd, &client_rect) == 0) return true;
    if (sys.GetWindowRect(hwnd, &window_rect) == 0) return true;

    const frame_width = (window_rect.right - window_rect.left) - (client_rect.right - client_rect.left);
    const frame_height = (window_rect.bottom - window_rect.top) - (client_rect.bottom - client_rect.top);

    if (limit.min_width > 0) {
        info.ptMinTrackSize.x = @as(i32, @intCast(limit.min_width)) + frame_width;
    }
    if (limit.min_height > 0) {
        info.ptMinTrackSize.y = @as(i32, @intCast(limit.min_height)) + frame_height;
    }
    if (limit.max_width > 0) {
        info.ptMaxTrackSize.x = @as(i32, @intCast(limit.max_width)) + frame_width;
    }
    if (limit.max_height > 0) {
        info.ptMaxTrackSize.y = @as(i32, @intCast(limit.max_height)) + frame_height;
    }
    return true;
}

const HWND_TOPMOST: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const HWND_NOTOPMOST: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// Makes `rect` (screen coordinates) the rect the minimized `hwnd` returns
/// to, and leaves it minimized.
fn setMinimizedNormalRect(hwnd: HWND, rect: RECT) !void {
    var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
    placement.length = @sizeOf(WINDOWPLACEMENT);
    if (sys.GetWindowPlacement(hwnd, &placement) == 0) return lastError();
    // Workspace coordinates of the monitor the rect is on, as
    // `sessionPlacement` reads them.
    const center: POINT = .{
        .x = @divTrunc(rect.left, 2) + @divTrunc(rect.right, 2),
        .y = @divTrunc(rect.top, 2) + @divTrunc(rect.bottom, 2),
    };
    const monitor = sys.MonitorFromPoint(center, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
    const info = monitorInfoOf(monitor) orelse return lastError();
    placement.rcNormalPosition = screenRectToWorkspace(rect, info);
    placement.showCmd = c.SW_SHOWMINNOACTIVE;
    if (sys.SetWindowPlacement(hwnd, &placement) == 0) return lastError();
}

/// The work areas of the monitors there are now, in screen coordinates.
pub const WorkAreas = MonitorRectList("rcWork");
/// The whole rects of the monitors there are now, in screen coordinates: what
/// a fullscreen window's edges are checked against (`fullscreenRect`).
const MonitorRects = MonitorRectList("rcMonitor");

/// One rect of each monitor there is now, `MONITORINFO.<field>`. `complete`
/// is false when Windows did not give every monitor's.
fn MonitorRectList(comptime field: []const u8) type {
    return struct {
        const List = @This();
        rects: [16]RECT = undefined,
        count: usize = 0,
        complete: bool = true,

        pub fn collect() List {
            var list: List = .{};
            if (sys.EnumDisplayMonitors(null, null, enumProc, @as(LPARAM, @bitCast(@intFromPtr(&list)))) == 0) list.complete = false;
            return list;
        }

        pub fn slice(self: *const List) []const RECT {
            return self.rects[0..self.count];
        }

        fn enumProc(monitor: sys.HMONITOR, _: HDC, _: *RECT, data: LPARAM) callconv(.winapi) BOOL {
            const list: *List = @ptrFromInt(@as(usize, @bitCast(data)));
            if (list.count == list.rects.len) {
                list.complete = false;
                return 0;
            }
            const info = monitorInfoOf(monitor) orelse {
                list.complete = false;
                return 1;
            };
            list.rects[list.count] = @field(info, field);
            list.count += 1;
            return 1;
        }
    };
}

/// Puts a restored window at the rect it was saved at, moved onto a monitor
/// if its own is gone, and maximizes it if it was.
fn placeRestored(host: *Host, saved: SavedPlacement) !void {
    const hwnd = host.hwnd orelse return;
    if (saved.rect) |rect| {
        // The saved rect is where the window was, not where there is room
        // for it now: its monitor may be gone.
        const works = WorkAreas.collect();
        const dpi_before = sys.GetDpiForWindow(hwnd);
        var target = window_start.restoredRectOnScreen(rect, works.slice(), window_start.restore_grab);
        if (sys.IsIconic(hwnd) != 0) {
            // A launch that asked for a minimized window (`start /min`,
            // a shortcut set to Run: Minimized) has Windows minimize the
            // first window's first show. SetWindowPos on a minimized
            // window moves its icon, and it would come back from the
            // taskbar where it was created: give it the rect to return to.
            try setMinimizedNormalRect(hwnd, target);
        } else {
            // The rect is in the pixels of the monitor it was saved on, and is
            // where the window goes: a crossing from the monitor the host was
            // created on must not swap in the DPI suggestion's rescaled size.
            host.restore_placing = true;
            defer host.restore_placing = false;
            for (0..3) |attempt| {
                if (sys.SetWindowPos(
                    hwnd,
                    null,
                    target.left,
                    target.top,
                    target.right - target.left,
                    target.bottom - target.top,
                    c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                ) == 0) return lastError();
                // Windows caps what it is given (a left edge to 16 bits, a
                // width to the largest window), so whether the title bar can
                // be reached is judged on the rect the window ended up with.
                var actual: RECT = undefined;
                if (sys.GetWindowRect(hwnd, &actual) == 0) return lastError();
                const moved = window_start.restoredRectOnScreen(actual, works.slice(), window_start.restore_grab);
                if (!rectEquals(moved, actual)) {
                    if (attempt == 2) {
                        log.warn("win32 session restore: window stayed off every monitor", .{});
                        break;
                    }
                    target = moved;
                    continue;
                }
                // The layout that follows a DPI change can resize it once
                // more: apply the same rect again once.
                if (sys.GetDpiForWindow(hwnd) == dpi_before or rectEquals(actual, target)) break;
            }
        }
    }
    if (saved.maximized) _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
}

/// How the session saves `host`'s window, as a restored window starts
/// (`Origin.restore`). `monitor` stands in for the monitor of a window that
/// is not fullscreen, so a test can give it the taskbar this machine lacks.
pub fn sessionPlacement(host: *Host, monitor: ?MONITORINFO) ?SavedPlacement {
    const hwnd = host.hwnd orelse return null;
    // Fullscreen is kept apart from the window it returns to: the popup's
    // rect covers its monitor and is not its normal rect.
    if (host.top_level.fullscreen) |saved| {
        const back = fullscreenReturn(saved, hwnd) catch |err| fallback: {
            log.warn("win32 session save: fullscreen window placement failed; using captured placement err={}", .{err});
            break :fallback saved;
        };
        return window_start.savedFullscreen(back);
    }
    var maximized = sys.IsZoomed(hwnd) != 0;
    var rect: RECT = undefined;
    if (maximized or sys.IsIconic(hwnd) != 0) {
        var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
        placement.length = @sizeOf(WINDOWPLACEMENT);
        if (sys.GetWindowPlacement(hwnd, &placement) != 0) {
            maximized = restoresMaximized(hwnd, &placement);
            // Workspace coordinates, offset from the screen's by a taskbar
            // on the top or left. Every other state saves screen
            // coordinates, and restore applies them as such.
            rect = placement.rcNormalPosition;
            if (monitor) |info| {
                rect = workspaceRectToScreen(rect, info);
            } else if (windowMonitor(hwnd)) |here| {
                rect = workspaceRectToScreen(rect, here.info);
            } else |_| {}
        } else if (sys.GetWindowRect(hwnd, &rect) == 0) {
            return .{ .rect = null, .maximized = maximized };
        }
    } else if (sys.GetWindowRect(hwnd, &rect) == 0) {
        return .{ .rect = null, .maximized = maximized };
    }

    if (rect.right <= rect.left or rect.bottom <= rect.top) return .{ .rect = null, .maximized = maximized };
    return .{ .rect = rect, .maximized = maximized };
}

/// `window_start.restoresMaximized` for the window `hwnd`.
fn restoresMaximized(hwnd: HWND, placement: *const WINDOWPLACEMENT) bool {
    return window_start.restoresMaximized(sys.IsZoomed(hwnd) != 0, sys.IsIconic(hwnd) != 0, placement);
}

fn toggleMaximize(host: *Host) void {
    const hwnd = host.hwnd orelse return;
    if (host.top_level.isFullscreen()) return;
    _ = sys.ShowWindow(hwnd, if (sys.IsZoomed(hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
}

/// How many panes `host`'s window holds, in all its tabs.
fn paneCount(host: *const Host) usize {
    var count: usize = 0;
    for (host.tabs.items) |*tab| count += tab.leafCount();
    return count;
}

fn scaleInitialClientSize(size: apprt.SurfaceSize, scale: apprt.ContentScale) apprt.SurfaceSize {
    return .{
        .width = scaleInitialClientAxis(size.width, scale.x),
        .height = scaleInitialClientAxis(size.height, scale.y),
    };
}

fn scaleInitialClientAxis(value: u32, scale: f32) u32 {
    const scaled = @ceil(@as(f64, @floatFromInt(value)) * @as(f64, @floatCast(scale)));
    const max_u32: f64 = @floatFromInt(std.math.maxInt(u32));
    return @intFromFloat(@min(max_u32, @max(1, scaled)));
}

fn setInitialSize(host: *Host, pane: *Surface, size: apprt.action.InitialSize) !void {
    pane.metrics.default_client_size = .{
        .width = @intCast(size.width),
        .height = @intCast(size.height),
    };
    const hwnd = host.hwnd orelse return;
    if (host.top_level.isFullscreen() or sys.IsZoomed(hwnd) != 0 or paneCount(host) != 1) return;
    const client_size = scaleInitialClientSize(pane.metrics.default_client_size.?, pane.content_scale);
    try resizeClientArea(host, client_size.width, client_size.height);
}

fn resetWindowSize(host: *Host, pane: *const Surface) !void {
    const size = pane.metrics.default_client_size orelse return;
    if (host.top_level.isFullscreen()) try leaveFullscreen(host);
    if (host.hwnd) |hwnd| _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
    const client_size = scaleInitialClientSize(size, pane.content_scale);
    try resizeClientArea(host, client_size.width, client_size.height);
}

/// Only the active pane's limit is the window's (`updateMinMaxInfo`), so only
/// it refreshes the frame. A window's first pane sends its limit during core
/// init, and that frame refresh is what gives the window its integrated frame
/// before the pty opens (2026-09-23, #262).
fn setSizeLimit(host: *Host, pane: *Surface, limit: apprt.action.SizeLimit) void {
    if (sizeLimitEquals(pane.metrics.size_limit, limit)) return;
    pane.metrics.size_limit = limit;
    if (host.activeSurface() == pane) refreshFrame(host);
}

/// Puts a new top-level window in the state `maximize` and `fullscreen`
/// ask for (`Enter`), on top of the state it already has: a window
/// that is maximized stays so, and one that is fullscreen stays so.
///
/// A window that is still hidden is made fullscreen in place: it was
/// created framed, and its first show is then at the monitor's rect. The
/// host is never created with the popup style (`CW_USEDEFAULT` puts a
/// popup at (0,0), which would be the rect leaving fullscreen returns to)
/// and a popup is never maximized (that covers only the work area and
/// sets `WS_MAXIMIZE` on a fullscreen window). With both, the window
/// leaves fullscreen maximized, over the normal rect it has now.
///
/// A failure is logged: how a window starts is a preference, and a
/// window in its ordinary state is still a usable window.
fn applyWindowStart(host: *Host, start: Enter) void {
    const hwnd = host.hwnd orelse return;
    if (start.fullscreen and !host.top_level.isFullscreen()) {
        // A launcher's show command (`start /min`, a shortcut set to Run:
        // Minimized or Maximized) goes to the first framed top-level
        // window the process calls ShowWindow on. A popup's show does not
        // take it, so the next framed window would: Settings, or a window
        // opened from this one after it left fullscreen, would open
        // minimized. SW_HIDE takes it while this window is still framed,
        // and shows nothing.
        if (sys.IsWindowVisible(hwnd) == 0) _ = sys.ShowWindow(hwnd, c.SW_HIDE);
        enterFullscreen(host) catch |err| {
            log.warn("win32 startup fullscreen failed err={}", .{err});
        };
    }
    if (start.maximize) {
        if (host.top_level.fullscreen) |*back| {
            // `leaveFullscreen` maximizes a window whose placement says
            // it was maximized.
            back.placement.showCmd = c.SW_MAXIMIZE;
        } else if (sys.IsZoomed(hwnd) == 0) {
            _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
        }
    }
}

fn enterFullscreen(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
    // The style writes below change the frame; blur-behind is asserted
    // again after them, whatever they end in.
    defer refreshBackgroundOpacity(host);
    // A minimized window comes back first. SetWindowPos would move only
    // its icon, and it would return from the taskbar as a popup at its
    // normal rect. A restored session's first window is minimized here
    // under a minimized launch (`placeRestored`).
    if (sys.IsIconic(hwnd) != 0) _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
    // Captured before the style write below, which drops WS_MAXIMIZE:
    // the monitor-sized SetWindowPos after it would otherwise land on a
    // normal window and overwrite its normal rect.
    var back: TopLevel.Return = .{ .rect = undefined, .placement = std.mem.zeroes(WINDOWPLACEMENT), .monitor = null };
    back.placement.length = @sizeOf(WINDOWPLACEMENT);
    if (sys.GetWindowPlacement(hwnd, &back.placement) == 0 or
        sys.GetWindowRect(hwnd, &back.rect) == 0) return lastError();
    const monitor = try windowMonitor(hwnd);
    back.monitor = monitor;
    host.top_level.fullscreen = back;
    try applyWindowStyle(host);

    const screen = fullscreenRect(host, monitor.info.rcMonitor);
    if (sys.SetWindowPos(
        hwnd,
        if (host.top_level.topmost) HWND_TOPMOST else null,
        screen.left,
        screen.top,
        screen.right - screen.left,
        screen.bottom - screen.top,
        c.SWP_FRAMECHANGED | c.SWP_NOACTIVATE,
    ) == 0) {
        return lastError();
    }
}

/// Whether `host`'s window, fullscreen, covers 1 px more than its monitor
/// (`window_start.composedFullscreenRect`, #598): its tab bar is hidden
/// (`window-show-tab-bar = never`), so its active pane fills the window, and
/// that pane renders with OpenGL, whose presents Windows can take out of
/// composition when they cover a monitor exactly. It is read as the window
/// enters fullscreen and as a copy of a fullscreen window opens, never again
/// while it stays fullscreen: a config reload, a renderer fallback, a DPI or
/// monitor change keep the rect it has.
fn keepsFullscreenComposed(host: *const Host) bool {
    if (builtin.is_test and test_keeps_fullscreen_composed) return true;
    return composesFullscreen(host.shouldShowTabBar(), paneRenderer(host.activeSurface()));
}

/// `keepsFullscreenComposed`'s decision: the tab bar hidden, and the active
/// pane running OpenGL.
fn composesFullscreen(tab_bar_shown: bool, renderer: PaneRenderer) bool {
    return !tab_bar_shown and renderer == .opengl;
}

/// What a window's active pane renders with.
const PaneRenderer = enum {
    /// No pane: a window kept empty for undo.
    none,
    /// Its core init has not finished, so no renderer runs yet.
    starting,
    opengl,
    d3d11,

    /// The backend that runs, which a fallback can have changed from the
    /// configured one. Once OpenGL runs, it stays: a fallback goes only from
    /// D3D11 to OpenGL.
    fn of(pane: ?*const Surface) PaneRenderer {
        const surface = pane orelse return .none;
        if (!surface.core_initialized) return .starting;
        if (comptime !build_config.d3d11) return .opengl;
        return if (surface.core_surface.renderer.opengl.load(.acquire) != null) .opengl else .d3d11;
    }
};

/// Turns `keepsFullscreenComposed` on in a test, whose panes have no renderer
/// to ask. Off by default, so every other test keeps the exact monitor rect.
var test_keeps_fullscreen_composed = false;

/// What every pane renders with in a test, whose panes have no renderer to
/// ask (`PaneRenderer.of` reads them as starting), but `test_d3d11_pane`,
/// which runs D3D11. Both null by default.
var test_pane_renderer: ?PaneRenderer = null;
var test_d3d11_pane: ?*const Surface = null;

/// Every `DwmEnableBlurBehindWindow` that turns it on, in a test: counted,
/// and failed while `test_blur_behind_fails`. DWM has no call that reads
/// blur-behind back.
var test_blur_behind_asserts: usize = 0;
var test_blur_behind_fails = false;

/// Every `applyBackgroundOpacity` on a window, in a test, and the opacity it
/// applied last.
var test_background_opacity_applies: usize = 0;
var test_background_opacity_applied: f64 = 1.0;

fn paneRenderer(pane: ?*const Surface) PaneRenderer {
    if (builtin.is_test) {
        if (test_d3d11_pane != null and pane == test_d3d11_pane) return .d3d11;
        if (test_pane_renderer) |renderer| return renderer;
    }
    return .of(pane);
}

/// The rect `host`'s window covers fullscreen on the monitor whose rect is
/// `screen`: `screen`, or with `keepsFullscreenComposed` 1 px more past the
/// first edge no other monitor is past. With a monitor missing from the list,
/// `screen`: the pixel could land on it.
fn fullscreenRect(host: *const Host, screen: RECT) RECT {
    if (!keepsFullscreenComposed(host)) return screen;
    const monitors = MonitorRects.collect();
    if (!monitors.complete) return screen;
    return window_start.composedFullscreenRect(screen, monitors.slice()) orelse screen;
}

/// What `hwnd`, fullscreen since `saved`, returns to when it leaves
/// fullscreen on the monitor it is on now (`window_start.returnOn`).
fn fullscreenReturn(saved: TopLevel.Return, hwnd: HWND) !TopLevel.Return {
    if (saved.monitor == null) return saved;
    return window_start.returnOn(saved, try windowMonitor(hwnd));
}

fn leaveFullscreen(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
    defer refreshBackgroundOpacity(host);
    const back = try fullscreenReturn(host.top_level.fullscreen.?, hwnd);
    host.top_level.fullscreen = null;
    try applyWindowStyle(host);

    // A maximized window is maximized again and given back the normal
    // rect it had before. Moving it to its maximized rect first, while
    // it was a normal window, made that rect its normal rect, so a
    // later restore kept it maximized-size. Any other window returns to
    // its exact rect: the placement of a snapped window holds its
    // pre-snap rect.
    if (back.placement.showCmd == c.SW_MAXIMIZE) {
        return maximizeWithPlacement(hwnd, &back.placement);
    }
    const rect = back.rect;
    if (sys.SetWindowPos(
        hwnd,
        if (host.top_level.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        c.SWP_FRAMECHANGED | c.SWP_NOACTIVATE,
    ) == 0) {
        return lastError();
    }
}

/// Maximizes `hwnd` with the normal rect of `placement`. Maximizing
/// first leaves SetWindowPlacement only the normal rect to write: on a
/// normal window it moves the window to that rect before maximizing it,
/// a second resize that also changes monitor if the rect is on another.
fn maximizeWithPlacement(hwnd: HWND, placement: *const WINDOWPLACEMENT) !void {
    _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
    if (sys.SetWindowPlacement(hwnd, placement) == 0) return lastError();
}

/// The monitor nearest `hwnd`, its info and the window's DPI.
pub fn windowMonitor(hwnd: HWND) !window_start.Monitor {
    const monitor = sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
    const info = monitorInfoOf(monitor) orelse return lastError();
    return .{ .id = @intFromPtr(monitor), .info = info, .dpi = sys.GetDpiForWindow(hwnd) };
}

/// `monitor`'s rects, or null when Windows cannot give them.
fn monitorInfoOf(monitor: sys.HMONITOR) ?MONITORINFO {
    var info: MONITORINFO = std.mem.zeroes(MONITORINFO);
    info.cbSize = @sizeOf(MONITORINFO);
    if (sys.GetMonitorInfoW(monitor, &info) == 0) return null;
    return info;
}

/// Its callers show the window's opacity again after it, since its style
/// write changes the frame: the toggle through a defer, `applyConfig` through
/// its own apply, once and at the new opacity.
fn setDecorationsVisible(host: *Host, visible: bool) !void {
    if (host.top_level.decorations_visible == visible) return;

    const previous_visible = host.top_level.decorations_visible;
    const used_integrated_titlebar_before = host.usingIntegratedTitlebar();
    host.top_level.decorations_visible = visible;

    applyWindowStyle(host) catch |err| {
        rollbackDecorationsVisible(host, previous_visible, false);
        return err;
    };
    const integrated_titlebar_changed = used_integrated_titlebar_before != host.usingIntegratedTitlebar();
    if (integrated_titlebar_changed) {
        // Switching between stock and app-owned caption chrome can
        // strand hover state until the next NC leave.
        host.handleNcMouseLeave();
    }
    host.layout() catch |err| {
        rollbackDecorationsVisible(host, previous_visible, integrated_titlebar_changed);
        return err;
    };
    host.refreshChrome() catch |err| {
        rollbackDecorationsVisible(host, previous_visible, integrated_titlebar_changed);
        return err;
    };
    host.scheduleCaptionUiaSync();
}

fn rollbackDecorationsVisible(host: *Host, previous_visible: bool, integrated_titlebar_changed: bool) void {
    host.top_level.decorations_visible = previous_visible;
    applyWindowStyle(host) catch |err| {
        log.warn("win32 decoration rollback style update failed err={}", .{err});
    };
    if (integrated_titlebar_changed) host.handleNcMouseLeave();
    host.layout() catch |err| {
        log.warn("win32 decoration rollback layout failed err={}", .{err});
    };
    host.refreshChrome() catch |err| {
        log.warn("win32 decoration rollback chrome refresh failed err={}", .{err});
    };
    host.scheduleCaptionUiaSync();
}

fn resizeClientArea(host: *Host, client_width: u32, client_height: u32) !void {
    const hwnd = host.hwnd orelse return;
    var client_rect: RECT = undefined;
    if (sys.GetClientRect(hwnd, &client_rect) == 0) {
        return lastError();
    }
    var window_rect: RECT = undefined;
    if (sys.GetWindowRect(hwnd, &window_rect) == 0) {
        return lastError();
    }

    const current_client_width = client_rect.right - client_rect.left;
    const current_client_height = client_rect.bottom - client_rect.top;
    const current_window_width = window_rect.right - window_rect.left;
    const current_window_height = window_rect.bottom - window_rect.top;
    const frame_width = current_window_width - current_client_width;
    const frame_height = current_window_height - current_client_height;

    if (sys.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        @as(i32, @intCast(client_width)) + frame_width,
        @as(i32, @intCast(client_height)) + frame_height,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
    ) == 0) {
        return lastError();
    }

    try host.layout();
    host.syncVisibleSurfaceCoreSizesFromClientRects();
}

fn refreshFrame(host: *Host) void {
    const hwnd = host.hwnd orelse return;
    if (keepsFrameUndecorated(host)) {
        win32_theme.WindowThemeAdapter.setHostBorderVisible(hwnd, host.top_level.decorations_visible);
    }

    _ = sys.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    );
}

/// Puts a copy where `window_start.place` says, fullscreen when its source
/// is, and shows it in the rest of its source's state, which it was created
/// with (`window_start.plan`).
fn takeSourceState(host: *Host, pending: *const Pending) !void {
    const hwnd = host.hwnd orelse return;
    const keeps = pending.plan.keeps;
    // The size core init gave the window, measured before it takes the
    // source's state (window-frame.md 2026-10-20 #496 part 2, trap 2).
    var own: ?window_start.Own = null;
    if (keeps.size) {
        var rect: RECT = undefined;
        if (sys.GetWindowRect(hwnd, &rect) == 0) return lastError();
        own = .{
            .size = .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top },
            .here = try windowMonitor(hwnd),
        };
    }
    var placed = window_start.place(&pending.plan, occupiedAround(host), own);
    // Fullscreen on the monitor `place` gives, as this window's own pane
    // decides, not its source's.
    if (placed.fullscreen != null) placed.rect = fullscreenRect(host, placed.rect);
    const top_level = &host.top_level;
    top_level.fullscreen = placed.fullscreen;

    try applyWindowStyle(host);
    try applyTopmost(host);
    try applyBackgroundOpacity(host);

    if (sys.SetWindowPos(
        hwnd,
        if (top_level.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
        placed.rect.left,
        placed.rect.top,
        placed.rect.right - placed.rect.left,
        placed.rect.bottom - placed.rect.top,
        placed.flags | c.SWP_FRAMECHANGED,
    ) == 0) {
        return lastError();
    }

    if (!top_level.isFullscreen()) {
        if (placed.maximize) |*placement| {
            // The source's normal rect, not the monitor-sized one.
            try maximizeWithPlacement(hwnd, placement);
        } else {
            _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
        }
    }
}

/// `undecoratedKeepsFrame` for `host`. The quick terminal flag is the
/// host's: a split or tab opened inside the quick terminal is an ordinary
/// surface in the quick terminal's window.
fn keepsFrameUndecorated(host: *const Host) bool {
    return undecoratedKeepsFrame(host.app.os_build, host.quick_terminal);
}

fn applyWindowStyle(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
    const keeps_frame = keepsFrameUndecorated(host);
    const current: u32 = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE))));
    // The write keeps the window's own visibility. Forcing WS_VISIBLE on
    // showed a hidden quick terminal on a config reload without its
    // surface knowing (see `App.toggleQuickTerminal`).
    const style = hostStyle(
        host.top_level.decorations_visible or keeps_frame,
        host.top_level.isFullscreen(),
    ) | (current & c.WS_VISIBLE);
    // On Windows 11 a decoration toggle keeps the frame, so the style is
    // already right, and writing it anyway would drop WS_MAXIMIZE: a
    // maximized window left un-maximized in its maximized rect.
    const state_bits: u32 = c.WS_VISIBLE | c.WS_MAXIMIZE | c.WS_MINIMIZE | c.WS_CLIPSIBLINGS;
    if ((current & ~state_bits) != (style & ~state_bits)) {
        _ = sys.SetWindowLongPtrW(hwnd, c.GWL_STYLE, @bitCast(@as(isize, @intCast(style))));
    }
    if (keeps_frame) win32_theme.WindowThemeAdapter.setHostBorderVisible(hwnd, host.top_level.decorations_visible);
    if (sys.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    ) == 0) {
        return lastError();
    }
}

/// Shows `host`'s opacity as `TopLevel.shows` decides from its panes'
/// renderers. Every Win32 side effect of `background-opacity` is here: the
/// layered fade of a D3D11 window; the blur-behind, buffered chrome paint and
/// solid child controls of a window whose background alone is translucent;
/// and what each pane's renderer draws its background at. An opaque window
/// makes none of these calls once it is opaque. Only the layered alpha can
/// fail, and it is applied last, after everything the window shows is set.
fn applyBackgroundOpacity(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
    if (builtin.is_test) {
        test_background_opacity_applies += 1;
        test_background_opacity_applied = host.top_level.opacity;
    }
    var shown = shownOpacity(host);
    if (shown.background != null) {
        // Not layered before blur-behind starts, so the ex-style change
        // cannot drop it.
        unlayer(hwnd);
        // Asserted again while it is on, a DWM call per apply while
        // translucent: nothing is known to reset it, but a window that
        // lost it would draw its panes' alpha dark.
        const kept = if (host.chrome_alpha != null) setBlurBehind(hwnd, true) else beginBackgroundAlpha(hwnd);
        if (!kept) {
            host.blur_behind_failed = true;
            log.warn("win32 blur-behind failed; this window's background-opacity fades it whole until the system theme changes", .{});
            shown = shownOpacity(host);
        }
    }
    if (shown.background == null and host.chrome_alpha != null) endBackgroundAlpha(hwnd);
    if (host.chrome_alpha != shown.background) {
        host.chrome_alpha = shown.background;
        // Every control repaints with the alpha it needs now, panes too:
        // pixels GDI drew while the window was opaque have alpha 0.
        _ = sys.RedrawWindow(hwnd, null, null, c.RDW_INVALIDATE | c.RDW_ALLCHILDREN);
    }
    for (host.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| entry.view.setBackgroundOpacity(shown.pane_opacity);
    }
    try setLayered(hwnd, shown.layered);
}

/// `TopLevel.shows` for `host` as it stands.
fn shownOpacity(host: *Host) TopLevel.Shows {
    return host.top_level.shows(panesDrawAlpha(host), win32.isHighContrastActive(), host.blur_behind_failed);
}

/// `Host.deinit`: ends the buffered paint a translucent window still holds
/// (`beginBackgroundAlpha`).
pub fn releaseBackgroundOpacity(host: *Host) void {
    if (host.chrome_alpha == null) return;
    host.chrome_alpha = null;
    _ = sys.BufferedPaintUnInit();
}

/// Shows `host`'s opacity again after something `TopLevel.shows` reads
/// changed without a window action: a pane's renderer started or switched to
/// OpenGL, or High Contrast turned on or off (`App.reconfigureTheme`).
pub fn refreshBackgroundOpacity(host: *Host) void {
    applyBackgroundOpacity(host) catch |err| {
        log.warn("win32 background opacity refresh failed err={}", .{err});
    };
}

/// `refreshBackgroundOpacity`, where a failed blur-behind
/// (`Host.blur_behind_failed`) tries once more; failing again latches it
/// again, with one warning.
pub fn retryBackgroundOpacity(host: *Host) void {
    host.blur_behind_failed = false;
    refreshBackgroundOpacity(host);
}

/// A child control `host`'s window made: made solid while the window's
/// background alone is translucent (`solidChild`).
pub fn childCreated(host: *const Host, child: HWND) void {
    if (host.chrome_alpha != null) _ = solidChild(child, 1);
}

/// Whether every pane of `host` whose renderer runs draws with OpenGL
/// (`TopLevel.shows`). A pane still starting is not counted: its core init
/// asks again once its renderer runs (`refreshBackgroundOpacity`). A
/// fallback goes only from D3D11 to OpenGL, and posts that it did.
fn panesDrawAlpha(host: *Host) bool {
    for (host.tabs.items) |*tab| {
        var it = tab.tree.iterator();
        while (it.next()) |entry| if (paneRenderer(entry.view) == .d3d11) return false;
    }
    return true;
}

/// What lets DWM keep the client area's alpha, so the panes' translucent
/// background shows: blur-behind with an empty region, which blurs nothing
/// (`DwmExtendFrameIntoClientArea` would turn the native title bar to glass
/// too); the buffered paint that gives the GDI chrome its alpha
/// (`chrome_scene.AlphaPaint`), which `Host.deinit` ends if the window still
/// has it; and the child controls made solid. Returns false, with nothing
/// changed, if it cannot.
fn beginBackgroundAlpha(hwnd: HWND) bool {
    if (sys.BufferedPaintInit() < 0) return false;
    if (!setBlurBehind(hwnd, true)) {
        _ = sys.BufferedPaintUnInit();
        return false;
    }
    _ = sys.EnumChildWindows(hwnd, solidChild, 1);
    return true;
}

fn endBackgroundAlpha(hwnd: HWND) void {
    _ = setBlurBehind(hwnd, false);
    _ = sys.EnumChildWindows(hwnd, solidChild, 0);
    _ = sys.BufferedPaintUnInit();
}

fn setBlurBehind(hwnd: HWND, on: bool) bool {
    if (builtin.is_test and on) {
        test_blur_behind_asserts += 1;
        if (test_blur_behind_fails) return false;
    }
    // An empty region: what is behind shows through unblurred.
    const region = if (on) (sys.CreateRectRgn(0, 0, -1, -1) orelse return false) else null;
    defer if (region) |r| {
        _ = sys.DeleteObject(r);
    };
    const blur: sys.DWM_BLURBEHIND = .{
        .dwFlags = sys.DWM_BB_ENABLE | sys.DWM_BB_BLURREGION,
        .fEnable = @intFromBool(on),
        .hRgnBlur = region,
        .fTransitionOnMaximized = 0,
    };
    return sys.DwmEnableBlurBehindWindow(hwnd, &blur) >= 0;
}

fn unlayer(hwnd: HWND) void {
    const ex_style: u32 = @intCast(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE))));
    if ((ex_style & c.WS_EX_LAYERED) == 0) return;
    _ = sys.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex_style & ~@as(u32, c.WS_EX_LAYERED)))));
    _ = sys.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    );
}

/// The whole window layered at `alpha`, or not layered at all.
fn setLayered(hwnd: HWND, alpha: ?u8) !void {
    const layered = alpha orelse return unlayer(hwnd);
    const ex_style: u32 = @intCast(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE))));
    if ((ex_style & c.WS_EX_LAYERED) == 0) {
        _ = sys.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex_style | c.WS_EX_LAYERED))));
    }
    if (sys.SetLayeredWindowAttributes(hwnd, 0, layered, c.LWA_ALPHA) == 0) {
        return lastError();
    }
}

/// `EnumChildWindows` over a window whose background alone is translucent:
/// `solid` 1 layers each child control that paints itself at alpha 255, and 0
/// takes that back. GDI leaves alpha 0, which DWM shows through, but DWM
/// composes a layered child from its own surface, opaque. Owner-drawn
/// controls stay unlayered, since some overlap others, and
/// `chrome_scene.AlphaPaint` gives their `WM_DRAWITEM` its alpha
/// (`solidifies`).
fn solidChild(child: HWND, solid: LPARAM) callconv(.winapi) BOOL {
    var name: [64]u16 = undefined;
    const len = sys.GetClassNameW(child, &name, name.len);
    const style: u32 = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(child, c.GWL_STYLE))));
    if (!solidifies(name[0..@intCast(@max(0, len))], style)) return 1;
    const ex: u32 = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(child, c.GWL_EXSTYLE))));
    const layered = (ex & c.WS_EX_LAYERED) != 0;
    if (solid != 0) {
        // A child layered for its own sake keeps its own alpha.
        if (layered) return 1;
        _ = sys.SetWindowLongPtrW(child, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex | c.WS_EX_LAYERED))));
        // A layered window with no attributes shows nothing: one that cannot
        // take them stays unlayered, readable if not solid.
        if (sys.SetLayeredWindowAttributes(child, 0, 255, c.LWA_ALPHA) == 0) {
            _ = sys.SetWindowLongPtrW(child, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex))));
        }
        return 1;
    }
    if (!layered) return 1;
    var key: u32 = 0;
    var alpha: u8 = 0;
    var flags: u32 = 0;
    if (sys.GetLayeredWindowAttributes(child, &key, &alpha, &flags) == 0) return 1;
    // Only what `solid` 1 made: every child layered for its own sake has a
    // color key or another alpha (the overlay scrollbar, quick-select, the
    // tab drop preview).
    if (flags != c.LWA_ALPHA or alpha != 255) return 1;
    _ = sys.SetWindowLongPtrW(child, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex & ~@as(u32, c.WS_EX_LAYERED)))));
    return 1;
}

/// Whether a child control of this class and style is layered while its
/// window's background alone is translucent (`solidChild`): one that paints
/// itself (an EDIT, a plain STATIC, the palette list). Not an owner-drawn
/// BUTTON or STATIC, whose `WM_DRAWITEM` `chrome_scene.AlphaPaint` gives its
/// alpha, and not a terminal pane, which draws its own alpha.
fn solidifies(class: []const u16, style: u32) bool {
    if (std.mem.eql(u16, class, win32.class_name)) return false;
    if (classIs(class, "BUTTON")) return style & 0xF != c.BS_OWNERDRAW;
    if (classIs(class, "STATIC")) return style & 0x1F != c.SS_OWNERDRAW;
    return true;
}

fn classIs(class: []const u16, comptime name: []const u8) bool {
    if (class.len != name.len) return false;
    for (class, name) |unit, char| {
        if (unit > 0x7F or std.ascii.toUpper(@intCast(unit)) != char) return false;
    }
    return true;
}

fn applyTopmost(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
    if (sys.SetWindowPos(
        hwnd,
        if (host.top_level.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    ) == 0) {
        return lastError();
    }
}

test "win32 a window's config and a forward's argv say how it wants to start" {
    var config = try configpkg.Config.default(std.testing.allocator);
    defer config.deinit();
    try std.testing.expectEqual(window_start.Wants{}, wants(&config));
    config.@"window-decoration" = .none;
    config.@"background-opacity" = 1.5;
    config.maximize = true;
    config.fullscreen = .true;
    // A position and a size each need both keys.
    config.@"window-position-x" = 10;
    config.@"window-width" = 80;
    try std.testing.expectEqual(window_start.Wants{ .decorated = false, .opacity = 1.0, .maximize = true, .fullscreen = true }, wants(&config));
    config.@"window-position-y" = 20;
    config.@"window-height" = 24;
    try std.testing.expectEqual(window_start.Wants{ .position = .{ .x = 10, .y = 20 }, .decorated = false, .opacity = 1.0, .maximize = true, .fullscreen = true, .sized = true }, wants(&config));

    try std.testing.expectEqual(window_start.Forwarded{}, forwardedKeys(&.{}));
    try std.testing.expectEqual(window_start.Forwarded{ .size = true }, forwardedKeys(&.{"--window-height=20"}));
    try std.testing.expectEqual(
        window_start.Forwarded{ .size = true, .decoration = true, .opacity = true },
        forwardedKeys(&.{ "--window-width=80", "--window-decoration=none", "--background-opacity=0.5" }),
    );
}

test "win32 createdHostWindowStyleCorrection takes back only what CreateWindowEx added" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Measured: `CreateWindowEx` answers the undecorated request with
    // 0x06C00000, i.e. the request plus WS_CAPTION and WS_CLIPSIBLINGS.
    const undecorated = hostStyle(false, false);
    try std.testing.expectEqual(
        @as(?u32, undecorated),
        createdHostWindowStyleCorrection(undecorated, undecorated | c.WS_CAPTION | c.WS_CLIPSIBLINGS),
    );
    try std.testing.expectEqual(@as(?u32, null), createdHostWindowStyleCorrection(undecorated, undecorated));

    // Decorated and fullscreen requests come back with only the
    // WS_CLIPSIBLINGS every top-level window carries, and stay untouched.
    const decorated = hostStyle(true, false);
    try std.testing.expectEqual(@as(?u32, null), createdHostWindowStyleCorrection(decorated, decorated | c.WS_CLIPSIBLINGS));
    const fullscreen = hostStyle(false, true);
    try std.testing.expectEqual(@as(?u32, null), createdHostWindowStyleCorrection(fullscreen, fullscreen | c.WS_CLIPSIBLINGS));
}

test "win32 restoreRequestedHostWindowStyle removes the caption CreateWindowEx adds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Never shown, so it reaches neither the desktop nor the taskbar.
    const requested = hostStyle(false, false);
    const hwnd = sys.CreateWindowExW(
        0,
        prompt_label_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        requested,
        0,
        0,
        640,
        400,
        null,
        null,
        sys.GetModuleHandleW(null),
        null,
    ) orelse return lastError();
    defer _ = sys.DestroyWindow(hwnd);

    // The premise of the bug: nothing in the request asks for a caption,
    // and the window has one anyway, eating into the client area.
    try std.testing.expectEqual(@as(u32, c.WS_CAPTION), testWindowStyle(hwnd) & c.WS_CAPTION);
    var client: RECT = undefined;
    try std.testing.expect(sys.GetClientRect(hwnd, &client) != 0);
    try std.testing.expect(client.bottom < 400);

    restoreRequestedHostWindowStyle(hwnd, requested);
    try std.testing.expectEqual(requested, testWindowStyle(hwnd) & ~@as(u32, c.WS_CLIPSIBLINGS));
    try std.testing.expect(sys.GetClientRect(hwnd, &client) != 0);
    try std.testing.expectEqual(@as(i32, 640), client.right - client.left);
    try std.testing.expectEqual(@as(i32, 400), client.bottom - client.top);

    // Already right: nothing to do, and the style stays put.
    restoreRequestedHostWindowStyle(hwnd, requested);
    try std.testing.expectEqual(requested, testWindowStyle(hwnd) & ~@as(u32, c.WS_CLIPSIBLINGS));
}

test "win32 leaveFullscreen and new_window keep the normal rect of a maximized window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Maximizing shows a window, so these live on a desktop of their own and
    // never reach the user's.
    try runOnHiddenDesktop(struct {
        fn normalRect(hwnd: HWND) !RECT {
            var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
            placement.length = @sizeOf(WINDOWPLACEMENT);
            if (sys.GetWindowPlacement(hwnd, &placement) == 0) return lastError();
            return placement.rcNormalPosition;
        }

        const Monitors = struct {
            handles: [8]sys.HMONITOR = undefined,
            count: usize = 0,

            fn collect(monitor: sys.HMONITOR, _: HDC, _: *RECT, data: LPARAM) callconv(.winapi) BOOL {
                const self: *@This() = @ptrFromInt(@as(usize, @bitCast(data)));
                if (self.count == self.handles.len) return 0;
                self.handles[self.count] = monitor;
                self.count += 1;
                return 1;
            }
        };

        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            var window = try placementTestHost(&app, 100, 100);
            const hwnd = window.hwnd.?;
            defer _ = sys.DestroyWindow(hwnd);

            _ = sys.ShowWindow(hwnd, c.SW_SHOW);
            var normal_rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(hwnd, &normal_rect) != 0);
            const normal = try normalRect(hwnd);

            // Before the fix, the maximized rect became the normal one.
            for ([_]bool{ false, true }) |maximized| {
                if (maximized) _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
                try std.testing.expectEqual(maximized, sys.IsZoomed(hwnd) != 0);
                var before: RECT = undefined;
                try std.testing.expect(sys.GetWindowRect(hwnd, &before) != 0);
                try enterFullscreen(&window);
                try leaveFullscreen(&window);
                try std.testing.expectEqual(maximized, sys.IsZoomed(hwnd) != 0);
                var rect: RECT = undefined;
                try std.testing.expect(sys.GetWindowRect(hwnd, &rect) != 0);
                try std.testing.expectEqualDeep(before, rect);
                try std.testing.expectEqualDeep(normal, try normalRect(hwnd));
                if (maximized) _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
                try std.testing.expect(sys.GetWindowRect(hwnd, &rect) != 0);
                try std.testing.expectEqualDeep(normal_rect, rect);
            }

            // new_window from a maximized window, into a window created
            // elsewhere, so it has to take the source's normal rect.
            var clone = try placementTestHost(&app, 200, 200);
            defer _ = sys.DestroyWindow(clone.hwnd.?);
            _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
            const start = try begin(&app, &app.config, .{ .copy = .{ .source = &window } });
            clone.top_level = start.plan.top_level;
            try takeSourceState(&clone, &start);
            try std.testing.expect(sys.IsZoomed(clone.hwnd.?) != 0);
            try std.testing.expectEqualDeep(normal, try normalRect(clone.hwnd.?));

            // Exercise real monitor/DPI transitions on this hidden desktop.
            var monitors: Monitors = .{};
            _ = sys.EnumDisplayMonitors(null, null, Monitors.collect, @bitCast(@intFromPtr(&monitors)));
            for (monitors.handles[0..monitors.count]) |source_monitor| {
                const source_info = monitorInfo(source_monitor) orelse return lastError();
                for (monitors.handles[0..monitors.count]) |dest_monitor| {
                    if (source_monitor == dest_monitor) continue;
                    const dest_info = monitorInfo(dest_monitor) orelse return lastError();
                    for ([_]i32{ 600, source_info.work_area.width() - 40 }) |normal_width| {
                        for ([_]bool{ false, true }) |maximized| {
                            _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
                            try std.testing.expect(sys.SetWindowPos(hwnd, null, source_info.work_area.left + 100, source_info.work_area.top + 100, normal_width, 400, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
                            const source_dpi = sys.GetDpiForWindow(hwnd);
                            var before: RECT = undefined;
                            try std.testing.expect(sys.GetWindowRect(hwnd, &before) != 0);
                            if (maximized) _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
                            try enterFullscreen(&window);
                            try std.testing.expect(sys.SetWindowPos(hwnd, null, dest_info.full_rect.left, dest_info.full_rect.top, dest_info.full_rect.width(), dest_info.full_rect.height(), c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
                            const dest_dpi = sys.GetDpiForWindow(hwnd);
                            try leaveFullscreen(&window);
                            try std.testing.expectEqual(maximized, sys.IsZoomed(hwnd) != 0);
                            try std.testing.expectEqual(dest_monitor, sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST).?);
                            const width = @min(dest_info.work_area.width(), sys.MulDiv(before.right - before.left, @intCast(dest_dpi), @intCast(source_dpi)));
                            const height = @min(dest_info.work_area.height(), sys.MulDiv(before.bottom - before.top, @intCast(dest_dpi), @intCast(source_dpi)));
                            const expected_left = @max(dest_info.work_area.left, @min(before.left + dest_info.work_area.left - source_info.work_area.left, dest_info.work_area.right - width));
                            const expected_top = @max(dest_info.work_area.top, @min(before.top + dest_info.work_area.top - source_info.work_area.top, dest_info.work_area.bottom - height));
                            if (maximized) {
                                const placed = try normalRect(hwnd);
                                try std.testing.expectEqual(expected_left - (dest_info.work_area.left - dest_info.full_rect.left), placed.left);
                                try std.testing.expectEqual(expected_top - (dest_info.work_area.top - dest_info.full_rect.top), placed.top);
                                try std.testing.expectEqual(width, placed.right - placed.left);
                                try std.testing.expectEqual(height, placed.bottom - placed.top);
                                _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
                                try std.testing.expectEqual(dest_monitor, sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST).?);
                            } else {
                                var restored: RECT = undefined;
                                try std.testing.expect(sys.GetWindowRect(hwnd, &restored) != 0);
                                try std.testing.expectEqual(expected_left, restored.left);
                                try std.testing.expectEqual(expected_top, restored.top);
                                try std.testing.expectEqual(width, restored.right - restored.left);
                                try std.testing.expectEqual(height, restored.bottom - restored.top);
                            }
                        }
                    }
                }
            }
        }
    }.body);
}

test "win32 a composed fullscreen window covers 1 px past its monitor, and saves and leaves fullscreen to exactly the window it was" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn placementOf(hwnd: HWND) !WINDOWPLACEMENT {
            var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
            placement.length = @sizeOf(WINDOWPLACEMENT);
            if (sys.GetWindowPlacement(hwnd, &placement) == 0) return lastError();
            return placement;
        }

        fn rectOf(hwnd: HWND) !RECT {
            var rect: RECT = undefined;
            if (sys.GetWindowRect(hwnd, &rect) == 0) return lastError();
            return rect;
        }

        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            app.config.@"window-show-tab-bar" = .never;
            var window = try placementTestHost(&app, 100, 100);
            const hwnd = window.hwnd.?;
            defer _ = sys.DestroyWindow(hwnd);
            _ = sys.ShowWindow(hwnd, c.SW_SHOW);
            const screen = (try windowMonitor(hwnd)).info.rcMonitor;

            // Off unless a test turns it on, even with the tab bar hidden:
            // no test window has a pane whose renderer runs, so every other
            // test sees the monitor's exact rect.
            try std.testing.expect(!keepsFullscreenComposed(&window));
            try enterFullscreen(&window);
            try std.testing.expectEqualDeep(screen, try rectOf(hwnd));
            try leaveFullscreen(&window);

            test_keeps_fullscreen_composed = true;
            defer test_keeps_fullscreen_composed = false;
            const monitors = MonitorRects.collect();
            try std.testing.expect(monitors.complete and monitors.count > 0);
            // With a monitor past every edge it would keep the exact rect.
            const grown = window_start.composedFullscreenRect(screen, monitors.slice()) orelse screen;
            for ([_]bool{ false, true }) |maximized| {
                if (maximized) _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
                try std.testing.expectEqual(maximized, sys.IsZoomed(hwnd) != 0);
                const before = try placementOf(hwnd);
                const before_rect = try rectOf(hwnd);
                try enterFullscreen(&window);
                try std.testing.expectEqualDeep(grown, try rectOf(hwnd));
                // A popup has no frame: the client a single pane fills has
                // the extra pixel too.
                var client: RECT = undefined;
                try std.testing.expect(sys.GetClientRect(hwnd, &client) != 0);
                try std.testing.expectEqual(grown.right - grown.left, client.right - client.left);
                try std.testing.expectEqual(grown.bottom - grown.top, client.bottom - client.top);

                // What it returns to, and what the session saves, is the
                // window it was, never the grown rect.
                const back = window.top_level.fullscreen.?;
                try std.testing.expectEqualDeep(before_rect, back.rect);
                try std.testing.expectEqualDeep(before, back.placement);
                const saved = sessionPlacement(&window, null).?;
                try std.testing.expect(saved.fullscreen and !saved.maximized);
                try std.testing.expectEqual(maximized, saved.fullscreen_maximized);
                const normal = if (maximized) workspaceRectToScreen(before.rcNormalPosition, back.monitor.?.info) else before_rect;
                try std.testing.expectEqualDeep(normal, saved.rect.?);

                try leaveFullscreen(&window);
                try std.testing.expectEqualDeep(before, try placementOf(hwnd));
                try std.testing.expectEqualDeep(before_rect, try rectOf(hwnd));
                if (maximized) _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
            }
        }
    }.body);
}

test "win32 a copy of a composed fullscreen window first shows, and stays, 1 px past a free edge of the monitor it is on" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;
            test_keeps_fullscreen_composed = true;
            defer test_keeps_fullscreen_composed = false;

            try app.createWindow(default_title);
            const source = fixture.newest();
            const source_hwnd = source.windowHwnd().?;
            const monitors = MonitorRects.collect();
            const works = WorkAreas.collect();
            try std.testing.expect(monitors.complete and works.count > 0);
            // On each monitor in turn: a copy is created where Windows puts
            // it and moved, hidden, to its source's monitor, and grows from
            // that one's edges.
            for (works.slice()) |work| {
                try std.testing.expect(sys.SetWindowPos(source_hwnd, null, work.left + 48, work.top + 40, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
                const source_rect = try Fixture.screenRect(source_hwnd);
                try std.testing.expect(try perform(source.host.?, source, .toggle_fullscreen, .native));
                const screen = try Fixture.monitorRect(source_hwnd);
                const grown = window_start.composedFullscreenRect(screen, monitors.slice()) orelse screen;
                try std.testing.expectEqualDeep(grown, try Fixture.screenRect(source_hwnd));

                try std.testing.expect(try app.performAction(.app, .new_window, .{ .arguments = null }));
                const clone = fixture.newest();
                try std.testing.expect(clone != source);
                const hwnd = clone.windowHwnd().?;
                // Never shown at the monitor's exact rect first.
                const shown = Fixture.first_show orelse return error.TestWindowNeverShown;
                try std.testing.expect(shown.style & c.WS_POPUP != 0);
                try std.testing.expectEqualDeep(grown, shown.rect);
                try std.testing.expect(clone.host.?.top_level.isFullscreen());
                try std.testing.expectEqualDeep(grown, try Fixture.screenRect(hwnd));
                // It leaves fullscreen to its source's window, never to the
                // grown rect.
                try std.testing.expectEqualDeep(source.host.?.top_level.fullscreen.?, clone.host.?.top_level.fullscreen.?);
                try std.testing.expect(try perform(clone.host.?, clone, .toggle_fullscreen, .native));
                try std.testing.expectEqualDeep(source_rect, try Fixture.screenRect(hwnd));
                fixture.closeWindow(clone);

                try std.testing.expect(try perform(source.host.?, source, .toggle_fullscreen, .native));
                try std.testing.expectEqualDeep(source_rect, try Fixture.screenRect(source_hwnd));
            }
        }
    }.body);
}

test "win32 a translucent OpenGL window fullscreen with its tab bar hidden is unlayered, keeps blur-behind and grows 1 px" {
    // #608's rule held only an unlayered window to need the extra pixel; a
    // translucent window was layered then. With #640 it is not, so both hold
    // at once, through the production decisions: no test flag forces the
    // composed rect here.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;
            test_pane_renderer = .opengl;
            defer test_pane_renderer = null;
            app.config.@"window-show-tab-bar" = .never;
            app.config.@"background-opacity" = 0.5;

            try app.createWindow(default_title);
            const pane = fixture.newest();
            const host = pane.host.?;
            const hwnd = host.hwnd.?;
            try std.testing.expect(keepsFullscreenComposed(host));
            // The fullscreen style write changes the frame: blur-behind is
            // asserted again after it.
            const asserts = test_blur_behind_asserts;
            try std.testing.expect(try perform(host, pane, .toggle_fullscreen, .native));
            try std.testing.expect(test_blur_behind_asserts > asserts);
            const screen = try Fixture.monitorRect(hwnd);
            const monitors = MonitorRects.collect();
            try std.testing.expect(monitors.complete);
            // With a monitor past every edge there is no pixel to grow by.
            const grown = window_start.composedFullscreenRect(screen, monitors.slice()) orelse return error.SkipZigTest;
            try std.testing.expectEqualDeep(grown, try Fixture.screenRect(hwnd));
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            try std.testing.expectEqual(@as(?f64, 0.5), pane.background_opacity);
            // So it is after leaving fullscreen, and after a decorations
            // toggle.
            for ([_]apprt.Action.Key{ .toggle_fullscreen, .toggle_window_decorations, .toggle_window_decorations }) |key| {
                const before = test_blur_behind_asserts;
                switch (key) {
                    .toggle_fullscreen => try std.testing.expect(try perform(host, pane, .toggle_fullscreen, .native)),
                    .toggle_window_decorations => try std.testing.expect(try perform(host, pane, .toggle_window_decorations, {})),
                    else => unreachable,
                }
                try std.testing.expect(test_blur_behind_asserts > before);
                try std.testing.expect(!testHostIsLayered(hwnd));
                try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            }
        }
    }.body);
}

test "win32 a fullscreen window grows only with its tab bar hidden and its active pane on OpenGL" {
    // The decision the window tests above force on.
    const Case = struct { tab_bar_shown: bool, renderer: PaneRenderer, grows: bool };
    for ([_]Case{
        .{ .tab_bar_shown = false, .renderer = .opengl, .grows = true },
        // With the tab bar shown the pane is smaller than the monitor.
        .{ .tab_bar_shown = true, .renderer = .opengl, .grows = false },
        // D3D11 presents through composition anyway.
        .{ .tab_bar_shown = false, .renderer = .d3d11, .grows = false },
        .{ .tab_bar_shown = true, .renderer = .d3d11, .grows = false },
        // No pane, or one whose renderer does not run yet.
        .{ .tab_bar_shown = false, .renderer = .none, .grows = false },
        .{ .tab_bar_shown = false, .renderer = .starting, .grows = false },
    }) |case| {
        try std.testing.expectEqual(case.grows, composesFullscreen(case.tab_bar_shown, case.renderer));
    }

    // Through a window: `window-show-tab-bar` is what hides the tab bar, and
    // a window with no pane never grows.
    var app = placementTestApp();
    var host: Host = .{ .app = &app, .id = 1 };
    for ([_]configpkg.Config.WindowShowTabBar{ .always, .auto, .never }) |tabs| {
        app.config.@"window-show-tab-bar" = tabs;
        try std.testing.expectEqual(tabs != .never, host.shouldShowTabBar());
        try std.testing.expect(!keepsFullscreenComposed(&host));
    }
}

test "win32 a window's active pane reads as no renderer, one starting, OpenGL or D3D11" {
    try std.testing.expectEqual(PaneRenderer.none, PaneRenderer.of(null));
    var pane: Surface = .{ .app = undefined };
    try std.testing.expectEqual(PaneRenderer.starting, PaneRenderer.of(&pane));
    pane.core_initialized = true;
    if (comptime !build_config.d3d11) {
        try std.testing.expectEqual(PaneRenderer.opengl, PaneRenderer.of(&pane));
        return;
    }
    // Only the renderer's `opengl` pointer is read, never what it points at:
    // null while D3D11 runs, set once OpenGL does.
    const opengl = &pane.core_surface.renderer.opengl;
    opengl.* = .init(null);
    try std.testing.expectEqual(PaneRenderer.d3d11, PaneRenderer.of(&pane));
    opengl.store(@ptrFromInt(0x1000), .release);
    try std.testing.expectEqual(PaneRenderer.opengl, PaneRenderer.of(&pane));
}

test "win32 a host opened from a minimized host starts on screen" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: SafeModeAppFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const title = std.unicode.utf8ToUtf16LeStringLiteral("");
            const source = try app.createHost(title, &app.config, .fresh);
            const hwnd = source.hwnd.?;
            try std.testing.expect(sys.SetWindowPos(hwnd, null, 60, 70, 700, 500, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
            _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
            var restored: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(hwnd, &restored) != 0);
            _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
            try std.testing.expect(sys.IsIconic(hwnd) != 0);

            // `createHost` gives the new host the source's place before
            // anything is shown.
            const clone = try app.createHost(title, &app.config, .{ .copy = .{ .source = source } });
            var rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(clone.hwnd.?, &rect) != 0);
            try std.testing.expectEqual(restored.right - restored.left, rect.right - rect.left);
            try std.testing.expectEqual(restored.bottom - restored.top, rect.bottom - rect.top);
            try std.testing.expect(rect.left > restored.left and rect.left <= restored.left + 96);
            try std.testing.expect(rect.top > restored.top and rect.top <= restored.top + 96);
        }
    }.body);
}

test "win32 new_window does not copy state from a quick terminal" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var quick_host: Host = undefined;
    var host: Host = undefined;
    var quick_surface: Surface = undefined;
    var surface: Surface = undefined;
    var session: TestSession = .{};
    try session.init(.{
        .core_app = &core_app,
        .app = &app,
        // The quick terminal comes first, so it is what the app target
        // resolves to.
        .hosts = &.{
            .{ .storage = &quick_host, .id = 1, .register = true, .next_tab_id = 2 },
            .{ .storage = &host, .id = 2, .register = true, .next_tab_id = 2 },
        },
        .surfaces = &.{
            .{ .storage = &quick_surface, .host = &quick_host, .register = true },
            .{ .storage = &surface, .host = &host, .register = true },
        },
        .tabs = &.{
            .{ .host = &quick_host, .surface = &quick_surface, .id = 1 },
            .{ .host = &host, .surface = &surface, .id = 1 },
        },
    });
    defer session.deinit();
    quick_host.quick_terminal = true;

    const Hook = struct {
        var calls: usize = 0;
        var source: ?*const Host = null;

        fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, opts: win32.SurfaceInitOptions) anyerror!*Surface {
            calls += 1;
            source = switch (opts.window) {
                .copy => |copy| copy.source,
                else => null,
            };
            return error.TestWindowCreateFailed;
        }
    };
    app.test_create_window_surface = &Hook.createSurface;

    // The quick terminal is a floating strip pinned to a screen edge: a
    // window copied from it would be topmost and sit on that strip. A new
    // window opened from it follows an ordinary one.
    Hook.calls = 0;
    _ = app.performAction(.app, .new_window, .{}) catch {};
    try std.testing.expectEqual(@as(usize, 1), Hook.calls);
    try std.testing.expect(Hook.source == &host);

    // With no ordinary window it is an ordinary new window.
    _ = app.registry.hosts.orderedRemove(1);
    _ = app.performAction(.app, .new_window, .{}) catch {};
    try std.testing.expectEqual(@as(usize, 2), Hook.calls);
    try std.testing.expect(Hook.source == null);

    // An ordinary window is what a new one copies.
    app.registry.hosts.clearRetainingCapacity();
    try app.registry.addHost(std.testing.allocator, &host);
    _ = app.performAction(.app, .new_window, .{}) catch {};
    try std.testing.expectEqual(@as(usize, 3), Hook.calls);
    try std.testing.expect(Hook.source == &host);
}

test "win32 new_window from the app copies the window activated last, never the quick terminal or a window kept empty for undo" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var empty_host: Host = undefined;
    var quick_host: Host = undefined;
    var first_host: Host = undefined;
    var second_host: Host = undefined;
    var quick_surface: Surface = undefined;
    var first: Surface = undefined;
    var second: Surface = undefined;
    var session: TestSession = .{};
    try session.init(.{
        .core_app = &core_app,
        .app = &app,
        // First in the list: a window whose last tab was closed and is kept
        // for undo, then the quick terminal. Neither has a pane to copy.
        .hosts = &.{
            .{ .storage = &empty_host, .id = 1, .register = true, .next_tab_id = 2 },
            .{ .storage = &quick_host, .id = 2, .register = true, .next_tab_id = 2 },
            .{ .storage = &first_host, .id = 3, .register = true, .next_tab_id = 2 },
            .{ .storage = &second_host, .id = 4, .register = true, .next_tab_id = 2 },
        },
        .surfaces = &.{
            .{ .storage = &quick_surface, .host = &quick_host, .register = true },
            .{ .storage = &first, .host = &first_host, .register = true },
            .{ .storage = &second, .host = &second_host, .register = true },
        },
        .tabs = &.{
            .{ .host = &quick_host, .surface = &quick_surface, .id = 1 },
            .{ .host = &first_host, .surface = &first, .id = 1 },
            .{ .host = &second_host, .surface = &second, .id = 1 },
        },
    });
    defer session.deinit();
    quick_host.quick_terminal = true;

    const Hook = struct {
        var copied: ?*const Host = null;

        fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, opts: win32.SurfaceInitOptions) anyerror!*Surface {
            copied = switch (opts.window) {
                .copy => |copy| copy.source,
                else => null,
            };
            return error.TestWindowCreateFailed;
        }

        fn source(a: *App, target: apprt.Target) !?*const Host {
            copied = null;
            _ = a.performAction(target, .new_window, .{}) catch {};
            return copied;
        }
    };
    app.test_create_window_surface = &Hook.createSurface;

    // Never activated: the first ordinary window with a pane, in list order.
    try std.testing.expect(try Hook.source(&app, .app) == &first_host);

    // The ordinary window activated last, though the empty window and the
    // quick terminal were activated after it. Before, the empty window in
    // the first slot gave nothing to copy.
    first_host.activated = 1;
    second_host.activated = 2;
    quick_host.activated = 3;
    empty_host.activated = 4;
    try std.testing.expect(try Hook.source(&app, .app) == &second_host);
    first_host.activated = 5;
    try std.testing.expect(try Hook.source(&app, .app) == &first_host);

    // From the quick terminal too. Before, that was the first ordinary
    // window in the list.
    second_host.activated = 6;
    try std.testing.expect(try Hook.source(&app, .{ .surface = quick_surface.core() }) == &second_host);
    // From an ordinary window, that window, whenever it was activated.
    try std.testing.expect(try Hook.source(&app, .{ .surface = first.core() }) == &first_host);
}

test "win32 maximize and fullscreen start a new window in that state at its first show" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true }, .{ true, true } }) |case| {
                const maximize, const fullscreen = case;
                app.config.maximize = maximize;
                app.config.fullscreen = if (fullscreen) .true else .false;
                try app.createWindow(default_title);
                const surface = fixture.newest();
                const hwnd = surface.windowHwnd().?;
                const created = Fixture.hidden_rect;
                const shown = Fixture.first_show orelse return error.TestWindowNeverShown;
                const screen = try Fixture.monitorRect(hwnd);

                try std.testing.expectEqual(fullscreen, surface.host.?.top_level.isFullscreen());
                if (fullscreen) {
                    // Shown at the monitor's rect, without a frame: no
                    // framed window first. And never a maximized popup,
                    // which covers only the work area.
                    try std.testing.expectEqualDeep(screen, shown.rect);
                    try std.testing.expect(shown.style & c.WS_POPUP != 0 and shown.style & c.WS_CAPTION == 0);
                    try std.testing.expect(!shown.zoomed);
                    try std.testing.expect(sys.IsZoomed(hwnd) == 0);
                    try std.testing.expectEqualDeep(screen, try Fixture.screenRect(hwnd));
                    // Leaving it gives back the window it was created as,
                    // maximized with both.
                    _ = try perform(surface.host.?, surface, .toggle_fullscreen, .native);
                    try std.testing.expect(!surface.host.?.top_level.isFullscreen());
                    try std.testing.expect(Fixture.framed(hwnd));
                    try std.testing.expectEqual(maximize, sys.IsZoomed(hwnd) != 0);
                    try std.testing.expectEqualDeep(created, try Fixture.normalRect(hwnd));
                    if (!maximize) try std.testing.expectEqualDeep(created, try Fixture.screenRect(hwnd));
                } else {
                    // Already maximized when it first appeared: no normal
                    // window first.
                    try std.testing.expectEqual(maximize, shown.zoomed);
                    try std.testing.expectEqual(maximize, sys.IsZoomed(hwnd) != 0);
                    try std.testing.expectEqualDeep(created, try Fixture.normalRect(hwnd));
                    if (!maximize) try std.testing.expectEqualDeep(created, shown.rect);
                }

                if (maximize and !fullscreen) {
                    // The state is the window's start, not a rule: a tab
                    // opened in a window the user restored leaves it so.
                    _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
                    try std.testing.expect(sys.IsZoomed(hwnd) == 0);
                    _ = try app.createWindowSurface(&app.config, default_title, .{ .host_id = surface.host_id });
                    try std.testing.expect(sys.IsZoomed(hwnd) == 0);
                    try std.testing.expectEqualDeep(created, try Fixture.screenRect(hwnd));
                }
                fixture.closeWindows();
            }
        }
    }.body);
}

test "win32 a new window from a normal one takes maximize, and a forwarded --maximize or --fullscreen=true" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            try app.createWindow(default_title);
            const source = fixture.newest();
            const source_hwnd = source.windowHwnd().?;
            const source_rect = try Fixture.screenRect(source_hwnd);
            const step = cascadeStep(sys.GetDpiForWindow(source_hwnd));
            const cascaded: RECT = .{
                .left = source_rect.left + step,
                .top = source_rect.top + step,
                .right = source_rect.right + step,
                .bottom = source_rect.bottom + step,
            };
            const screen = try Fixture.monitorRect(source_hwnd);

            const Case = struct {
                config_maximize: bool = false,
                arguments: ?[]const [:0]const u8 = null,
                maximized: bool = false,
                fullscreen: bool = false,
            };
            for ([_]Case{
                // Neither: a normal window, cascaded from the source.
                .{},
                .{ .config_maximize = true, .maximized = true },
                .{ .arguments = &.{"--maximize"}, .maximized = true },
                .{ .arguments = &.{"--fullscreen=true"}, .fullscreen = true },
                .{ .arguments = &.{ "--maximize", "--fullscreen=true" }, .maximized = true, .fullscreen = true },
            }) |case| {
                app.config.maximize = case.config_maximize;
                try std.testing.expect(try app.performAction(.app, .new_window, .{ .arguments = case.arguments }));
                const clone = fixture.newest();
                try std.testing.expect(clone != source);
                const hwnd = clone.windowHwnd().?;
                try std.testing.expectEqual(case.fullscreen, clone.host.?.top_level.isFullscreen());
                if (case.fullscreen) {
                    // On the source's monitor, and back to the cascaded
                    // window when it leaves, maximized with both.
                    try std.testing.expectEqualDeep(screen, try Fixture.screenRect(hwnd));
                    try std.testing.expect(sys.IsZoomed(hwnd) == 0);
                    _ = try perform(clone.host.?, clone, .toggle_fullscreen, .native);
                }
                // Before the fix every one of these ended in the source's
                // SW_RESTORE.
                try std.testing.expectEqual(case.maximized, sys.IsZoomed(hwnd) != 0);
                try std.testing.expectEqualDeep(cascaded, try Fixture.normalRect(hwnd));
                // The source is left as it was.
                try std.testing.expect(sys.IsZoomed(source_hwnd) == 0 and !source.host.?.top_level.isFullscreen());
                try std.testing.expectEqualDeep(source_rect, try Fixture.screenRect(source_hwnd));
                fixture.closeWindow(clone);
            }
        }
    }.body);
}

/// A running app with one normal window, for the tests of what a new window
/// opened from it keeps of the keys a forwarded launch gives it (#496): a
/// second `noctty` or `noctty +new-window` while one runs.
const ForwardedKeysTest = struct {
    fixture: WindowStartTestApp = .{},
    source: *Surface = undefined,
    /// The source window's rect, and that rect one cascade step off it.
    source_rect: RECT = undefined,
    cascaded: RECT = undefined,
    work: win32_quick_terminal.Rect = undefined,

    const Fixture = WindowStartTestApp;
    /// What core init asks for when the window's config has both
    /// `window-width` and `window-height`, as `sized` gives it.
    const own: apprt.action.InitialSize = .{ .width = 400, .height = 300 };
    const sized: []const [:0]const u8 = &.{ "--window-width=50", "--window-height=15" };

    fn init(self: *ForwardedKeysTest) !void {
        _ = sys.SetThreadDpiAwarenessContext(-4);
        try self.fixture.init();
        errdefer self.fixture.deinit();
        try self.fixture.app.createWindow(default_title);
        self.source = self.fixture.newest();
        const hwnd = self.source.windowHwnd().?;
        self.source_rect = try Fixture.screenRect(hwnd);
        const step = cascadeStep(sys.GetDpiForWindow(hwnd));
        self.cascaded = at(self.source_rect, self.source_rect.left + step, self.source_rect.top + step);
        const monitor = sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
        self.work = (monitorInfo(monitor) orelse return lastError()).work_area;
    }

    fn deinit(self: *ForwardedKeysTest) void {
        self.fixture.deinit();
    }

    /// A `new_window` with `arguments` as its forwarded argv. With `size`,
    /// core init asks for that client size, as it does when the window's
    /// config has `window-width` and `window-height`.
    fn forward(self: *ForwardedKeysTest, arguments: ?[]const [:0]const u8, size: ?apprt.action.InitialSize) !*Surface {
        const count = self.fixture.app.registry.windows.items.len;
        Fixture.initial_size = size;
        defer Fixture.initial_size = null;
        try std.testing.expect(try self.fixture.app.performAction(.app, .new_window, .{ .arguments = arguments }));
        try std.testing.expectEqual(count + 1, self.fixture.app.registry.windows.items.len);
        return self.fixture.newest();
    }

    /// `--window-position-x/y` at (`x`, `y`), formatted into `buf`.
    fn placedAt(buf: *[2][32]u8, x: i32, y: i32) ![2][:0]const u8 {
        return .{
            try std.fmt.bufPrintZ(&buf[0], "--window-position-x={d}", .{x}),
            try std.fmt.bufPrintZ(&buf[1], "--window-position-y={d}", .{y}),
        };
    }

    fn at(rect: RECT, left: i32, top: i32) RECT {
        return .{ .left = left, .top = top, .right = left + rect.right - rect.left, .bottom = top + rect.bottom - rect.top };
    }

    fn clientSize(hwnd: HWND) !apprt.SurfaceSize {
        var rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &rect) == 0) return lastError();
        return .{ .width = @intCast(rect.right - rect.left), .height = @intCast(rect.bottom - rect.top) };
    }

    /// The client size `own` gives a window at its DPI.
    fn ownClient(surface: *const Surface) apprt.SurfaceSize {
        return scaleInitialClientSize(.{ .width = own.width, .height = own.height }, surface.content_scale);
    }

    fn style(hwnd: HWND) u32 {
        return testWindowStyle(hwnd) & ~@as(u32, c.WS_VISIBLE | c.WS_CLIPSIBLINGS);
    }

    fn undecoratedStyle(surface: *const Surface) u32 {
        return hostStyle(keepsFrameUndecorated(surface.host.?), false);
    }
};

test "win32 a forwarded window position places a new window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();
            const app = &t.fixture.app;

            // Controls, as before the fix: with nothing forwarded a new window
            // is one cascade step off the source at its size, and
            // `window-position-x/y` in the config place it at that size.
            {
                const clone = try t.forward(null, null);
                try std.testing.expectEqualDeep(t.cascaded, try ForwardedKeysTest.Fixture.screenRect(clone.windowHwnd().?));
                t.fixture.closeWindow(clone);
            }
            app.config.@"window-position-x" = @intCast(t.work.left + 200);
            app.config.@"window-position-y" = @intCast(t.work.top + 100);
            {
                const clone = try t.forward(null, null);
                try std.testing.expectEqualDeep(ForwardedKeysTest.at(t.source_rect, t.work.left + 200, t.work.top + 100), try ForwardedKeysTest.Fixture.screenRect(clone.windowHwnd().?));
                t.fixture.closeWindow(clone);
            }

            // A forwarded position places it, at the source's size, over the
            // config's as well. Before the fix it went where the config said,
            // or one cascade step off the source. The first pass runs with the
            // config's position still set.
            for ([_]bool{ true, false }) |configured| {
                if (!configured) {
                    app.config.@"window-position-x" = null;
                    app.config.@"window-position-y" = null;
                }
                var buf: [2][32]u8 = undefined;
                const x = t.work.left + 300;
                const y = t.work.top + 200;
                const placed = try ForwardedKeysTest.placedAt(&buf, x, y);
                const clone = try t.forward(&placed, null);
                try std.testing.expectEqualDeep(ForwardedKeysTest.at(t.source_rect, x, y), try ForwardedKeysTest.Fixture.screenRect(clone.windowHwnd().?));
                t.fixture.closeWindow(clone);
            }
        }
    }.body);
}

test "win32 a forwarded window size sizes a new window, also one opened from a maximized or fullscreen window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();
            const Fixture = ForwardedKeysTest.Fixture;
            const source_hwnd = t.source.windowHwnd().?;

            // The client core init asked for, one cascade step off the source.
            // Before the fix it took the source's size.
            {
                const clone = try t.forward(ForwardedKeysTest.sized, ForwardedKeysTest.own);
                const hwnd = clone.windowHwnd().?;
                try std.testing.expectEqualDeep(ForwardedKeysTest.ownClient(clone), try ForwardedKeysTest.clientSize(hwnd));
                const rect = try Fixture.screenRect(hwnd);
                try std.testing.expectEqual(t.cascaded.left, rect.left);
                try std.testing.expectEqual(t.cascaded.top, rect.top);
                // And what `reset_window_size` returns to.
                try std.testing.expectEqualDeep(@as(?apprt.SurfaceSize, .{ .width = ForwardedKeysTest.own.width, .height = ForwardedKeysTest.own.height }), clone.metrics.default_client_size);
                t.fixture.closeWindow(clone);
            }

            // From a maximized source: the normal rect the maximized new
            // window returns to, where the source's is.
            _ = sys.ShowWindow(source_hwnd, c.SW_MAXIMIZE);
            const source_normal = try Fixture.normalRect(source_hwnd);
            {
                const clone = try t.forward(ForwardedKeysTest.sized, ForwardedKeysTest.own);
                const hwnd = clone.windowHwnd().?;
                try std.testing.expect(sys.IsZoomed(hwnd) != 0);
                const normal = try Fixture.normalRect(hwnd);
                try std.testing.expectEqual(source_normal.left, normal.left);
                try std.testing.expectEqual(source_normal.top, normal.top);
                _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
                try std.testing.expectEqualDeep(ForwardedKeysTest.ownClient(clone), try ForwardedKeysTest.clientSize(hwnd));
                t.fixture.closeWindow(clone);
            }
            _ = sys.ShowWindow(source_hwnd, c.SW_RESTORE);
            try std.testing.expectEqualDeep(t.source_rect, try Fixture.screenRect(source_hwnd));

            // From a fullscreen source: the window the fullscreen new window
            // leaves fullscreen to, where the source's is.
            _ = try perform(t.source.host.?, t.source, .toggle_fullscreen, .native);
            {
                const clone = try t.forward(ForwardedKeysTest.sized, ForwardedKeysTest.own);
                const hwnd = clone.windowHwnd().?;
                try std.testing.expect(clone.host.?.top_level.isFullscreen());
                try std.testing.expectEqualDeep(try Fixture.monitorRect(hwnd), try Fixture.screenRect(hwnd));
                _ = try perform(clone.host.?, clone, .toggle_fullscreen, .native);
                try std.testing.expect(!clone.host.?.top_level.isFullscreen() and sys.IsZoomed(hwnd) == 0);
                try std.testing.expectEqualDeep(ForwardedKeysTest.ownClient(clone), try ForwardedKeysTest.clientSize(hwnd));
                const rect = try Fixture.screenRect(hwnd);
                try std.testing.expectEqual(t.source_rect.left, rect.left);
                try std.testing.expectEqual(t.source_rect.top, rect.top);
                t.fixture.closeWindow(clone);
            }
            _ = try perform(t.source.host.?, t.source, .toggle_fullscreen, .native);
        }
    }.body);
}

test "win32 forwarded window decorations win over the ones a new window copies" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();
            const style = ForwardedKeysTest.style;
            const undecorated = ForwardedKeysTest.undecoratedStyle;
            const framed = hostStyle(true, false);

            // Windows 10's frameless undecorated window, and Windows 11's,
            // which keeps the frame (`undecoratedKeepsFrame`), so there only
            // the decoration state tells the two apart: a style check passes
            // either way.
            for ([_]u32{ 19045, c.OS_BUILD_WIN11_21H2 }) |os_build| {
                t.fixture.app.os_build = os_build;
                // Before the fix a new window always took the source's.
                {
                    const clone = try t.forward(&.{"--window-decoration=none"}, null);
                    try std.testing.expect(!clone.host.?.top_level.decorations_visible);
                    try std.testing.expectEqual(undecorated(clone), style(clone.windowHwnd().?));
                    try std.testing.expectEqual(keepsFrameUndecorated(clone.host.?), undecorated(clone) == framed);
                    t.fixture.closeWindow(clone);
                }
                try std.testing.expect(try perform(t.source.host.?, t.source, .toggle_window_decorations, {}));
                // The control: without them it copies the source's.
                {
                    const clone = try t.forward(null, null);
                    try std.testing.expect(!clone.host.?.top_level.decorations_visible);
                    try std.testing.expectEqual(undecorated(clone), style(clone.windowHwnd().?));
                    t.fixture.closeWindow(clone);
                }
                {
                    const clone = try t.forward(&.{"--window-decoration=auto"}, null);
                    try std.testing.expect(clone.host.?.top_level.decorations_visible);
                    try std.testing.expectEqual(framed, style(clone.windowHwnd().?));
                    // A config reload gives it the config's decorations
                    // again, as it does a window that took them from the
                    // config.
                    try std.testing.expect(!clone.host.?.top_level.decorations_overridden);
                    t.fixture.closeWindow(clone);
                }
                try std.testing.expect(try perform(t.source.host.?, t.source, .toggle_window_decorations, {}));
            }
        }
    }.body);
}

test "win32 a forwarded window background opacity wins over the one a new window copies" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();

            // The control: an opaque source, an opaque copy.
            {
                const clone = try t.forward(null, null);
                try std.testing.expectEqual(@as(?u8, null), shownAlpha(clone.windowHwnd().?));
                t.fixture.closeWindow(clone);
            }
            // Before the fix the copy stayed opaque. Its background alone is
            // translucent (#640), and its pane is told so.
            {
                const clone = try t.forward(&.{"--background-opacity=0.5"}, null);
                const hwnd = clone.windowHwnd().?;
                try std.testing.expectEqual(@as(f64, 0.5), clone.host.?.top_level.opacity);
                try std.testing.expect(!testHostIsLayered(hwnd));
                try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
                try std.testing.expectEqual(@as(?f64, 0.5), clone.background_opacity);
                t.fixture.closeWindow(clone);
            }
        }
    }.body);
}

test "win32 forwarded window keys apply to a new window when no window is open" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();

            // Nothing to copy: before the fix the window took the app
            // config's position and decorations instead.
            t.fixture.closeWindows();
            var buf: [2][32]u8 = undefined;
            const x = t.work.left + 300;
            const y = t.work.top + 200;
            const placed = try ForwardedKeysTest.placedAt(&buf, x, y);
            const clone = try t.forward(&.{ placed[0], placed[1], ForwardedKeysTest.sized[0], ForwardedKeysTest.sized[1], "--window-decoration=none" }, ForwardedKeysTest.own);
            const hwnd = clone.windowHwnd().?;
            const rect = try ForwardedKeysTest.Fixture.screenRect(hwnd);
            try std.testing.expectEqual(x, rect.left);
            try std.testing.expectEqual(y, rect.top);
            try std.testing.expectEqualDeep(ForwardedKeysTest.ownClient(clone), try ForwardedKeysTest.clientSize(hwnd));
            try std.testing.expect(!clone.host.?.top_level.decorations_visible);
            try std.testing.expectEqual(ForwardedKeysTest.undecoratedStyle(clone), ForwardedKeysTest.style(hwnd));
        }
    }.body);
}

test "win32 a forwarded window copies the window activated last, not the first in the list" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();
            const app = &t.fixture.app;

            // Two more windows, each where no copy is cascaded onto, and with
            // room for a copy of `second` on a 1024x768 runner.
            var buf: [2][2][32]u8 = undefined;
            const second_at = try ForwardedKeysTest.placedAt(&buf[0], t.work.left + 240, t.work.top + 140);
            const second = try t.forward(&second_at, null);
            const third_at = try ForwardedKeysTest.placedAt(&buf[1], t.work.left + 120, t.work.top + 120);
            const third = try t.forward(&third_at, null);

            // The first window is first in the list, and was copied before.
            try activate(second);
            try expectCopies(&t, second);

            // Closing the first window moves the newest into its slot.
            try activate(second);
            t.fixture.closeWindow(t.source);
            try std.testing.expect(app.registry.hosts.items[0] == third.host.?);
            try expectCopies(&t, second);

            // A window kept with no tab for undo has no pane to copy, even
            // first in the list and activated last. Before, the forwarded
            // window then opened as if no window were open.
            const kept = third.host.?;
            var entry = kept.detachTabForUndo(0).?;
            // Back in its window before teardown closes it, if a check fails.
            errdefer _ = kept.restoreClosedTabEntryNative(&entry.payload.close_tab) catch false;
            try activate(second);
            try activateHost(kept);
            try expectCopies(&t, second);
            try std.testing.expect(try kept.restoreClosedTabEntryNative(&entry.payload.close_tab));
        }

        fn activate(surface: *Surface) !void {
            try activateHost(surface.host.?);
        }

        /// Real activation: `WM_ACTIVATE` from the window manager.
        fn activateHost(host: *Host) !void {
            const hwnd = host.hwnd.?;
            _ = sys.SetActiveWindow(hwnd);
            try std.testing.expect(sys.GetActiveWindow() == hwnd);
            try std.testing.expectEqual(host.app.activations, host.activated);
        }

        /// A plain forward is one cascade step off `source`, at its size,
        /// kept in its work area as `window_start.place` keeps it.
        fn expectCopies(t: *ForwardedKeysTest, source: *Surface) !void {
            const hwnd = source.windowHwnd().?;
            const rect = try ForwardedKeysTest.Fixture.screenRect(hwnd);
            const work = (try windowMonitor(hwnd)).info.rcWork;
            const clone = try t.forward(null, null);
            const step = cascadeStep(sys.GetDpiForWindow(hwnd));
            try std.testing.expectEqualDeep(fitRectInWork(rect.left + step, rect.top + step, rect.right - rect.left, rect.bottom - rect.top, work), try ForwardedKeysTest.Fixture.screenRect(clone.windowHwnd().?));
            t.fixture.closeWindow(clone);
        }
    }.body);
}

test "win32 a config reload of maximize and fullscreen leaves the windows already open alone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            try app.createWindow(default_title);
            const plain = fixture.newest();
            const plain_hwnd = plain.windowHwnd().?;
            const plain_rect = try Fixture.screenRect(plain_hwnd);

            // Turned on: the window that is open stays as it is.
            var both = try app.config.clone(std.testing.allocator);
            defer both.deinit();
            both.maximize = true;
            both.fullscreen = .true;
            try reloadConfig(app, &both);
            try std.testing.expect(app.config.maximize and app.config.fullscreen == .true);
            try std.testing.expect(sys.IsZoomed(plain_hwnd) == 0 and !plain.host.?.top_level.isFullscreen());
            try std.testing.expectEqualDeep(plain_rect, try Fixture.screenRect(plain_hwnd));

            // A window opened after the reload takes them.
            try app.createWindow(default_title);
            const started = fixture.newest();
            const started_hwnd = started.windowHwnd().?;
            try std.testing.expect(started.host.?.top_level.isFullscreen());
            const started_rect = try Fixture.screenRect(started_hwnd);

            // Turned off: neither window changes, and the second still
            // leaves fullscreen to a maximized window, as it started.
            var neither = try app.config.clone(std.testing.allocator);
            defer neither.deinit();
            neither.maximize = false;
            neither.fullscreen = .false;
            try reloadConfig(app, &neither);
            try std.testing.expect(started.host.?.top_level.isFullscreen() and sys.IsZoomed(started_hwnd) == 0);
            try std.testing.expectEqualDeep(started_rect, try Fixture.screenRect(started_hwnd));
            try std.testing.expect(sys.IsZoomed(plain_hwnd) == 0 and !plain.host.?.top_level.isFullscreen());
            try std.testing.expectEqualDeep(plain_rect, try Fixture.screenRect(plain_hwnd));
            _ = try perform(started.host.?, started, .toggle_fullscreen, .native);
            try std.testing.expect(sys.IsZoomed(started_hwnd) != 0);
        }
    }.body);
}

/// What a reload does once the file is read (`CoreApp.updateConfig`): each
/// pane's config change, then the app's.
fn reloadConfig(app: *App, config: *const configpkg.Config) !void {
    for (app.registry.windows.items) |pane| {
        try std.testing.expect(try app.performAction(.{ .surface = pane.core() }, .config_change, .{ .config = config }));
    }
    try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = config }));
}

/// The alpha `hwnd`'s window shows at, either way: layered whole, or its
/// background alone under blur-behind.
fn shownAlpha(hwnd: HWND) ?u8 {
    return if (testHostIsLayered(hwnd)) testLayeredAlpha(hwnd) else testBackgroundAlpha(hwnd);
}

test "win32 a first window and a window opened from it show their opacity at the first show" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            // OpenGL panes: the background alone is translucent, and the
            // window is never layered (#640). D3D11 panes: the whole window
            // fades, layered, as before.
            for ([_]PaneRenderer{ .opengl, .d3d11 }) |renderer| {
                test_pane_renderer = renderer;
                defer test_pane_renderer = null;
                const layered: ?u8 = if (renderer == .d3d11) 128 else null;
                const background: ?u8 = if (renderer == .opengl) 128 else null;

                // The default, opaque, is neither: layering would put every
                // window on a composition path it does not need.
                app.config.@"background-opacity" = 1;
                try app.createWindow(default_title);
                var shown = Fixture.first_show orelse return error.TestWindowNeverShown;
                try std.testing.expect(shown.ex_style & c.WS_EX_LAYERED == 0);
                try std.testing.expectEqual(@as(?u8, null), shown.alpha);
                try std.testing.expectEqual(@as(?u8, null), shown.background_alpha);
                fixture.closeWindow(fixture.newest());

                // Translucent before any show (#234): no opaque frame, then a
                // fade.
                app.config.@"background-opacity" = 0.5;
                try app.createWindow(default_title);
                const source = fixture.newest();
                shown = Fixture.first_show orelse return error.TestWindowNeverShown;
                try std.testing.expectEqual(layered != null, shown.ex_style & c.WS_EX_LAYERED != 0);
                try std.testing.expectEqual(layered, shown.alpha);
                try std.testing.expectEqual(background, shown.background_alpha);

                // A copy shows at its source's opacity before it takes the
                // source's state.
                try std.testing.expect(try app.performAction(.app, .new_window, .{ .arguments = null }));
                shown = Fixture.first_show orelse return error.TestWindowNeverShown;
                try std.testing.expectEqual(layered != null, shown.ex_style & c.WS_EX_LAYERED != 0);
                try std.testing.expectEqual(layered, shown.alpha);
                try std.testing.expectEqual(background, shown.background_alpha);
                fixture.closeWindow(fixture.newest());

                // A copy of a window the user forced opaque is never shown
                // faded. Forced opaque, a window drops the layered style and
                // blur-behind, not just its alpha to 255, and takes them back
                // with the toggle.
                const hwnd = source.windowHwnd().?;
                try std.testing.expect(try app.performAction(.{ .surface = source.core() }, .toggle_background_opacity, {}));
                try std.testing.expect(!testHostIsLayered(hwnd));
                try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));
                try std.testing.expect(try app.performAction(.app, .new_window, .{ .arguments = null }));
                shown = Fixture.first_show orelse return error.TestWindowNeverShown;
                try std.testing.expect(shown.ex_style & c.WS_EX_LAYERED == 0);
                try std.testing.expectEqual(@as(?u8, null), shown.alpha);
                try std.testing.expectEqual(@as(?u8, null), shown.background_alpha);
                fixture.closeWindow(fixture.newest());
                try std.testing.expect(try app.performAction(.{ .surface = source.core() }, .toggle_background_opacity, {}));
                try std.testing.expectEqual(layered != null, testHostIsLayered(hwnd));
                try std.testing.expectEqual(layered orelse background, shownAlpha(hwnd));
                fixture.closeWindow(source);
            }
        }
    }.body);
}

test "win32 an OpenGL window's background alone shows its opacity, in every pane, through a toggle, a reload, a preview, a new tab and a split" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn panesAt(host: *Host, opacity: ?f64) !void {
            var count: usize = 0;
            for (host.tabs.items) |*tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| {
                    try std.testing.expectEqual(opacity, entry.view.background_opacity);
                    count += 1;
                }
            }
            try std.testing.expect(count > 0);
        }

        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            test_pane_renderer = .opengl;
            defer test_pane_renderer = null;

            // A config load: the window is never layered, blur-behind keeps
            // the panes' alpha, and the pane draws its background at the
            // window's opacity.
            app.config.@"background-opacity" = 0.5;
            try app.createWindow(default_title);
            const first = fixture.newest();
            const host = first.host.?;
            const hwnd = host.hwnd.?;
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            try panesAt(host, 0.5);

            // The toggle: no blur-behind, and the pane at 1 rather than the
            // config's 0.5, which would draw a darker background DWM drops
            // the alpha of.
            try std.testing.expect(try app.performAction(.{ .surface = first.core() }, .toggle_background_opacity, {}));
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));
            try panesAt(host, 1.0);

            // A tab made after the toggle starts at what its window shows.
            try std.testing.expect(try app.performAction(.{ .surface = first.core() }, .new_tab, {}));
            const tab = host.activeSurface().?;
            try std.testing.expect(tab != first);
            try std.testing.expectEqual(@as(?f64, 1.0), tab.background_opacity);
            try std.testing.expect(try app.performAction(.{ .surface = tab.core() }, .toggle_background_opacity, {}));
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            try panesAt(host, 0.5);

            // So does a split (made as `createNewSplit` makes it, without the
            // working directory a test pane has no core to read).
            const split = try app.createWindowSurface(&app.config, default_title, .{
                .host_id = tab.host_id,
                .tab_id = host.activeTab().?.id,
                .clone_state_from = tab,
            });
            try std.testing.expectEqual(@as(usize, 2), host.activeTab().?.leafCount());
            try std.testing.expectEqual(@as(?f64, 0.5), split.background_opacity);

            // A reload keeps the window's opacity in its panes: the
            // renderer keeps it apart from the config a reload replaces.
            var reloaded = try app.config.clone(std.testing.allocator);
            defer reloaded.deinit();
            try reloadConfig(app, &reloaded);
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            try panesAt(host, 0.5);

            // A Settings preview reaches the panes without the config.
            win32.settingsPreviewFieldThunk(app, .background_opacity, .{ .background_opacity = 0.7 });
            try std.testing.expectEqual(@as(?u8, 179), testBackgroundAlpha(hwnd));
            try panesAt(host, 0.7);
            win32.settingsPreviewFieldThunk(app, .background_opacity, .{ .background_opacity = 0.5 });
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            try panesAt(host, 0.5);

            // Back to opaque: no blur-behind, nothing layered, panes at 1.
            reloaded.@"background-opacity" = 1;
            try reloadConfig(app, &reloaded);
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));
            try panesAt(host, 1.0);
        }
    }.body);
}

test "win32 a window with a D3D11 pane fades whole and leaves its panes at their config's opacity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn perPixel(hwnd: HWND, pane: *const Surface) !void {
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            try std.testing.expectEqual(@as(?f64, 0.5), pane.background_opacity);
        }

        fn faded(hwnd: HWND, pane: *const Surface) !void {
            try std.testing.expectEqual(@as(?u8, 128), testLayeredAlpha(hwnd));
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));
            try std.testing.expectEqual(@as(?f64, null), pane.background_opacity);
        }

        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            defer test_pane_renderer = null;
            defer test_d3d11_pane = null;

            test_pane_renderer = .d3d11;
            app.config.@"background-opacity" = 0.5;
            try app.createWindow(default_title);
            const pane = fixture.newest();
            const host = pane.host.?;
            const hwnd = host.hwnd.?;
            try faded(hwnd, pane);

            // Its pane falls back to OpenGL. The fallback posts that it did,
            // and the window, from its message loop, shows the background
            // alone translucent now.
            test_pane_renderer = .opengl;
            pane.rendererSwitchedToOpenGL();
            var msg: sys.MSG = undefined;
            try std.testing.expect(sys.PeekMessageW(&msg, hwnd, c.WM_WINHOSTTY_RENDERER_SWITCHED, c.WM_WINHOSTTY_RENDERER_SWITCHED, c.PM_REMOVE) != 0);
            _ = sys.DispatchMessageW(&msg);
            try perPixel(hwnd, pane);

            // A tab on D3D11 joins it: the whole window fades as the tab's
            // renderer starts, and the OpenGL pane goes back to its config's
            // opacity.
            test_pane_renderer = .d3d11;
            const tab = try app.createWindowSurface(&app.config, default_title, .{ .host_id = pane.host_id });
            test_d3d11_pane = tab;
            test_pane_renderer = .opengl;
            try faded(hwnd, pane);

            // It goes into undo history, as a closed tab does, and comes
            // back, as an undo or a close that rolled back puts it.
            var entry = host.detachTabForUndo(1).?;
            errdefer _ = host.restoreClosedTabEntryNative(&entry.payload.close_tab) catch false;
            try perPixel(hwnd, pane);
            try std.testing.expect(try host.restoreClosedTabEntryNative(&entry.payload.close_tab));
            try faded(hwnd, pane);

            // That tab closes: every pane left draws with OpenGL again.
            fixture.core_app.deleteSurface(tab);
            _ = sys.DestroyWindow(tab.hwnd.?);
            test_d3d11_pane = null;
            try perPixel(hwnd, pane);
        }
    }.body);
}

test "win32 a window closing whole shows no opacity as its panes go, and a pane closing in a window that stays shows it once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        /// A window whose first tab runs D3D11 and its `others` OpenGL: it
        /// fades whole.
        fn window(fixture: *WindowStartTestApp, others: []*Surface) !*Surface {
            const app = &fixture.app;
            test_pane_renderer = .d3d11;
            try app.createWindow(default_title);
            const d3d11 = fixture.newest();
            test_d3d11_pane = d3d11;
            test_pane_renderer = .opengl;
            for (others) |*other| other.* = try app.createWindowSurface(&app.config, default_title, .{ .host_id = d3d11.host_id });
            try std.testing.expectEqual(@as(?u8, 128), testLayeredAlpha(d3d11.host.?.hwnd.?));
            return d3d11;
        }

        /// One pane's window is destroyed, as at the end of any pane close
        /// (`App.windowDestroyed`).
        fn closePane(fixture: *WindowStartTestApp, pane: *Surface, applies: usize) !void {
            const before = test_background_opacity_applies;
            fixture.core_app.deleteSurface(pane);
            _ = sys.DestroyWindow(pane.hwnd.?);
            try std.testing.expectEqual(before + applies, test_background_opacity_applies);
        }

        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            defer test_pane_renderer = null;
            defer test_d3d11_pane = null;
            app.config.@"background-opacity" = 0.5;

            var tabs: [4]*Surface = undefined;
            const d3d11 = try window(&fixture, &tabs);
            const host = d3d11.host.?;

            // A pane of a window that stays: the window shows its opacity
            // again, once.
            try closePane(&fixture, tabs[3], 1);

            // A window close that asks and is cancelled closes nothing, and a
            // pane closing after it still shows the opacity again.
            host.askBeforeClosing(.window, 1, &win32.hostCloseConfirmAccept, host);
            try std.testing.expect(host.confirm_payload != null);
            host.invokeConfirmCancel();
            try std.testing.expectEqual(@as(usize, 4), host.tabs.items.len);
            try closePane(&fixture, tabs[2], 1);

            // The window closes whole, its D3D11 pane first: nothing shows
            // its opacity on the way, so it never turns per-pixel for the
            // moment before it goes.
            const id = host.id;
            for ([_]*Surface{ d3d11, tabs[0], tabs[1] }) |pane| fixture.core_app.deleteSurface(pane);
            var applies = test_background_opacity_applies;
            var asserts = test_blur_behind_asserts;
            host.closeConfirmed();
            try std.testing.expect(app.registry.findHostById(id) == null);
            try std.testing.expectEqual(applies, test_background_opacity_applies);
            try std.testing.expectEqual(asserts, test_blur_behind_asserts);

            // A pane whose close is refused (`requestClose` refuses one with
            // no window, among others) keeps its window, which shows its
            // opacity once, for the panes it has: with the D3D11 pane gone,
            // the background alone is translucent.
            var kept: [1]*Surface = undefined;
            const faded = try window(&fixture, &kept);
            const stays = faded.host.?;
            const refused = kept[0].hwnd.?;
            kept[0].hwnd = null;
            fixture.core_app.deleteSurface(faded);
            applies = test_background_opacity_applies;
            asserts = test_blur_behind_asserts;
            stays.closeConfirmed();
            kept[0].hwnd = refused;
            try std.testing.expectEqual(@as(usize, 1), stays.tabs.items.len);
            try std.testing.expectEqual(applies + 1, test_background_opacity_applies);
            try std.testing.expectEqual(asserts + 1, test_blur_behind_asserts);
            try std.testing.expect(!testHostIsLayered(stays.hwnd.?));
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(stays.hwnd.?));

            // And it is an ordinary window again: a pane of it closing later
            // shows its opacity again.
            const later = try app.createWindowSurface(&app.config, default_title, .{ .host_id = stays.id });
            try closePane(&fixture, later, 1);
        }
    }.body);
}

test "win32 a config change that toggles decorations and changes opacity applies the opacity once, at its new value" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            test_pane_renderer = .opengl;
            defer test_pane_renderer = null;

            app.config.@"background-opacity" = 0.5;
            try app.createWindow(default_title);
            const pane = fixture.newest();
            const host = pane.host.?;
            const hwnd = host.hwnd.?;
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));

            // Both ways: undecorated and opaque, then decorated and
            // translucent again. Each applies once, at the config's opacity,
            // and blur-behind is never asserted at the old one on the way.
            for ([_]struct { decoration: configpkg.Config.WindowDecoration, opacity: f64, shown: ?u8 }{
                .{ .decoration = .none, .opacity = 1.0, .shown = null },
                .{ .decoration = .auto, .opacity = 0.5, .shown = 128 },
            }) |step| {
                var config = try app.config.clone(std.testing.allocator);
                defer config.deinit();
                config.@"window-decoration" = step.decoration;
                config.@"background-opacity" = step.opacity;
                const applies = test_background_opacity_applies;
                const asserts = test_blur_behind_asserts;
                try applyConfig(host, &config);
                try std.testing.expectEqual(step.decoration != .none, host.top_level.decorations_visible);
                try std.testing.expectEqual(applies + 1, test_background_opacity_applies);
                try std.testing.expectEqual(step.opacity, test_background_opacity_applied);
                try std.testing.expectEqual(asserts + @intFromBool(step.shown != null), test_blur_behind_asserts);
                try std.testing.expect(!testHostIsLayered(hwnd));
                try std.testing.expectEqual(step.shown, testBackgroundAlpha(hwnd));
            }
        }
    }.body);
}

test "win32 a theme change or a reload that flips the frame mode asserts blur-behind after the frame write" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        /// `test_blur_behind_asserts` when the window's frame last changed.
        var asserts_at_frame: ?usize = null;
        var previous: ?*const anyopaque = null;

        fn proc(hwnd: HWND, msg: UINT, wp: usize, lp: LPARAM) callconv(.winapi) isize {
            if (msg == c.WM_WINDOWPOSCHANGED) {
                const pos: *const sys.WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lp)));
                if (pos.flags & c.SWP_FRAMECHANGED != 0) asserts_at_frame = test_blur_behind_asserts;
            }
            return sys.CallWindowProcW(previous, hwnd, msg, wp, lp);
        }

        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            test_pane_renderer = .opengl;
            defer test_pane_renderer = null;

            app.config.@"background-opacity" = 0.5;
            try app.createWindow(default_title);
            const hwnd = fixture.newest().host.?.hwnd.?;
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            previous = @ptrFromInt(@as(usize, @bitCast(sys.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&proc))))));

            // On Windows 11 the tab strip shown is the integrated titlebar and
            // hidden the stock frame: each way, the frame changes, and the
            // window applies its opacity once, after it. A theme rebuild that
            // refreshes it does so itself; a reload's leaves it to the
            // `applyConfig` that follows.
            app.os_build = c.OS_BUILD_WIN11_21H2;
            for ([_]bool{ false, true }) |reload| {
                for ([_]configpkg.Config.WindowShowTabBar{ .auto, .never }) |tabs| {
                    const integrated = app.use_integrated_titlebar;
                    const applies = test_background_opacity_applies;
                    asserts_at_frame = null;
                    if (reload) {
                        var config = try app.config.clone(std.testing.allocator);
                        defer config.deinit();
                        config.@"window-show-tab-bar" = tabs;
                        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &config }));
                    } else {
                        app.config.@"window-show-tab-bar" = tabs;
                        app.reconfigureTheme(.refresh);
                    }
                    try std.testing.expect(app.use_integrated_titlebar != integrated);
                    const at_frame = asserts_at_frame orelse return error.TestFrameNeverChanged;
                    try std.testing.expect(test_blur_behind_asserts > at_frame);
                    try std.testing.expectEqual(applies + 1, test_background_opacity_applies);
                    try std.testing.expect(!testHostIsLayered(hwnd));
                    try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
                }
            }
        }
    }.body);
}

test "win32 the app's config change applies each window's opacity once, at its new value" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            test_pane_renderer = .opengl;
            defer test_pane_renderer = null;

            app.config.@"background-opacity" = 0.5;
            try app.createWindow(default_title);
            const hwnd = fixture.newest().host.?.hwnd.?;
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));

            // The app's half of a reload (each pane's own config change
            // applies the opacity too, at the new value): its theme rebuild
            // leaves the opacity to `applyConfig`, which applies it once, so
            // blur-behind is asserted only where the window ends translucent,
            // never at the opacity it leaves.
            for ([_]struct { opacity: f64, shown: ?u8 }{
                .{ .opacity = 1.0, .shown = null },
                .{ .opacity = 0.5, .shown = 128 },
            }) |step| {
                var config = try app.config.clone(std.testing.allocator);
                defer config.deinit();
                config.@"background-opacity" = step.opacity;
                const applies = test_background_opacity_applies;
                const asserts = test_blur_behind_asserts;
                try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &config }));
                try std.testing.expectEqual(applies + 1, test_background_opacity_applies);
                try std.testing.expectEqual(step.opacity, test_background_opacity_applied);
                try std.testing.expectEqual(asserts + @intFromBool(step.shown != null), test_blur_behind_asserts);
                try std.testing.expectEqual(step.shown, testBackgroundAlpha(hwnd));
            }
        }
    }.body);
}

test "win32 a Settings preview of a theme and an opacity that ends applies the opacity once, at the saved value" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            test_pane_renderer = .opengl;
            defer test_pane_renderer = null;

            app.config.@"window-theme" = .dark;
            try app.createWindow(default_title);
            const hwnd = fixture.newest().host.?.hwnd.?;
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));

            // Settings previews a translucent opacity and another theme.
            try std.testing.expect(app.previewSetting(.{ .background_opacity = 0.5 }));
            app.refreshSettingsPreview(.opacity);
            try std.testing.expect(app.previewSetting(.{ .window_theme = .light }));
            app.refreshSettingsPreview(.theme);
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));

            // A save without a reload (safe mode) ends both together, at the
            // saved, opaque config: the window applies its opacity once, and
            // never asserts blur-behind at the previewed one on the way.
            const applies = test_background_opacity_applies;
            const asserts = test_blur_behind_asserts;
            app.endSettingsPreview();
            try std.testing.expect(app.settings_preview == null);
            try std.testing.expectEqual(applies + 1, test_background_opacity_applies);
            try std.testing.expectEqual(@as(f64, 1.0), test_background_opacity_applied);
            try std.testing.expectEqual(asserts, test_blur_behind_asserts);
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));
        }
    }.body);
}

test "win32 a window whose blur-behind failed fades whole, and tries it again only at a system theme change" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        /// A system theme message, `changed` or only finding a resource
        /// missing, with blur-behind failing or not: it applies the opacity
        /// once and tries blur-behind `tries` times.
        fn themeMessage(app: *App, host: *Host, changed: bool, fails: bool, tries: usize) !void {
            test_blur_behind_fails = fails;
            if (changed) app.system_theme_refresh = .{} else {
                _ = sys.DeleteObject(host.chrome_brush.?);
                host.chrome_brush = null;
            }
            const applies = test_background_opacity_applies;
            const asserts = test_blur_behind_asserts;
            app.reconfigureSystemTheme();
            try std.testing.expectEqual(applies + 1, test_background_opacity_applies);
            try std.testing.expectEqual(asserts + tries, test_blur_behind_asserts);
        }

        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            test_pane_renderer = .opengl;
            defer test_pane_renderer = null;
            test_blur_behind_fails = true;
            defer test_blur_behind_fails = false;

            app.config.@"background-opacity" = 0.5;
            try app.createWindow(default_title);
            const pane = fixture.newest();
            const host = pane.host.?;
            const hwnd = host.hwnd.?;
            try std.testing.expect(host.blur_behind_failed);
            try std.testing.expectEqual(@as(?u8, 128), testLayeredAlpha(hwnd));
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));
            try std.testing.expectEqual(@as(?f64, null), pane.background_opacity);

            // Latched: with blur-behind working again, a reload neither
            // tries it nor changes how the window shows its opacity.
            test_blur_behind_fails = false;
            const asserts = test_blur_behind_asserts;
            var reloaded = try app.config.clone(std.testing.allocator);
            defer reloaded.deinit();
            try reloadConfig(app, &reloaded);
            try std.testing.expectEqual(asserts, test_blur_behind_asserts);
            try std.testing.expectEqual(@as(?u8, 128), testLayeredAlpha(hwnd));
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));

            // A system theme change tries it again. Where it fails again, the
            // window latches again after one try, so one warning, and still
            // fades whole.
            try themeMessage(app, host, true, true, 1);
            try std.testing.expect(host.blur_behind_failed);
            try std.testing.expectEqual(@as(?u8, 128), testLayeredAlpha(hwnd));
            try std.testing.expectEqual(@as(?u8, null), testBackgroundAlpha(hwnd));

            // A theme message that changed nothing but finds a resource
            // missing rebuilds the theme without trying.
            try themeMessage(app, host, false, false, 0);
            try std.testing.expect(host.blur_behind_failed);
            try std.testing.expectEqual(@as(?u8, 128), testLayeredAlpha(hwnd));

            // Where DWM works again, the next theme change shows the
            // background alone translucent.
            try themeMessage(app, host, true, false, 1);
            try std.testing.expect(!host.blur_behind_failed);
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expectEqual(@as(?u8, 128), testBackgroundAlpha(hwnd));
            try std.testing.expectEqual(@as(?f64, 0.5), pane.background_opacity);
        }
    }.body);
}

test "win32 DWM_BLURBEHIND matches dwmapi.h, which packs it to 1" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(sys.DWM_BLURBEHIND));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(sys.DWM_BLURBEHIND, "fEnable"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(sys.DWM_BLURBEHIND, "hRgnBlur"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(sys.DWM_BLURBEHIND, "fTransitionOnMaximized"));
}

test "win32 a translucent background makes solid the child controls that paint themselves, and gives back only those" {
    const ascii = std.unicode.utf8ToUtf16LeStringLiteral;
    // Classes as `GetClassNameW` gives them, whatever case they were made
    // with.
    try std.testing.expect(solidifies(ascii("Edit"), c.ES_AUTOHSCROLL));
    try std.testing.expect(solidifies(ascii("Static"), c.SS_RIGHT));
    try std.testing.expect(solidifies(win32.palette_list_class_name, 0));
    try std.testing.expect(!solidifies(ascii("Button"), c.BS_OWNERDRAW));
    try std.testing.expect(!solidifies(ascii("Static"), c.SS_OWNERDRAW));
    try std.testing.expect(!solidifies(ascii("STATIC"), c.SS_OWNERDRAW | c.WS_CHILD));
    try std.testing.expect(!solidifies(win32.class_name, 0));
}

test "win32 a size limit on the active pane of a minimized window leaves it minimized" {
    // A pane's own action never restores its window, whatever other panes
    // the window holds.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const limit: apprt.action.SizeLimit = .{ .min_width = 120, .min_height = 60, .max_width = 0, .max_height = 0 };

            try app.createWindow(default_title);
            const pair = fixture.newest();
            const hwnd = pair.windowHwnd().?;
            _ = try app.createWindowSurface(&app.config, default_title, .{ .host_id = pair.host_id });
            try std.testing.expectEqual(pair, pair.host.?.activeSurface().?);

            _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
            try std.testing.expect(sys.IsIconic(hwnd) != 0);
            try std.testing.expect(try app.performAction(.{ .surface = pair.core() }, .size_limit, limit));
            try std.testing.expect(sys.IsIconic(hwnd) != 0);
        }
    }.body);
}

test "win32 a reload leaves the active window active and a minimized window minimized" {
    // A reload sends every pane of a two-pane window a config change, the
    // pane it shows included: none of them restores or activates a window.
    // A minimized window that is restored becomes the active one, so this
    // probe sees an activation.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;

            var firsts: [2]*Surface = undefined;
            for (&firsts) |*first| {
                try app.createWindow(default_title);
                first.* = fixture.newest();
                _ = try app.createWindowSurface(&app.config, default_title, .{ .host_id = first.*.host_id });
            }
            const older = firsts[0].windowHwnd().?;
            const newer = firsts[1].windowHwnd().?;
            _ = sys.SetActiveWindow(older);
            try std.testing.expectEqual(@as(?HWND, older), sys.GetActiveWindow());
            try reloadConfig(app, &app.config);
            try std.testing.expectEqual(@as(?HWND, older), sys.GetActiveWindow());

            _ = sys.ShowWindow(newer, c.SW_SHOWMINNOACTIVE);
            _ = sys.SetActiveWindow(older);
            try std.testing.expectEqual(@as(?HWND, older), sys.GetActiveWindow());
            try reloadConfig(app, &app.config);
            try std.testing.expect(sys.IsIconic(newer) != 0);
            try std.testing.expectEqual(@as(?HWND, older), sys.GetActiveWindow());
        }
    }.body);
}

test "win32 a new window takes the pane metrics of the pane it is opened from" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            try app.createWindow(default_title);
            const source = fixture.newest();
            const target: apprt.Target = .{ .surface = source.core() };
            try std.testing.expect(try app.performAction(target, .cell_size, .{ .width = 9, .height = 18 }));
            try std.testing.expect(try app.performAction(target, .size_limit, .{ .min_width = 90, .min_height = 72, .max_width = 0, .max_height = 0 }));
            try std.testing.expect(try app.performAction(target, .initial_size, .{ .width = 640, .height = 400 }));

            // Its own core init asks for another client size, as a font of
            // its own would.
            Fixture.initial_size = .{ .width = 500, .height = 300 };
            defer Fixture.initial_size = null;
            try std.testing.expect(try app.performAction(.app, .new_window, .{ .arguments = null }));
            const clone = fixture.newest();
            try std.testing.expect(clone != source);
            try std.testing.expectEqual(source.metrics.cell_size_pixels, clone.metrics.cell_size_pixels);
            try std.testing.expect(sizeLimitEquals(source.metrics.size_limit, clone.metrics.size_limit));
            try std.testing.expectEqual(source.metrics.default_client_size, clone.metrics.default_client_size);
        }
    }.body);
}

test "win32 Windows sends WM_GETMINMAXINFO to a top-level window and never to a terminal child on SetWindowPos" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Counter = struct {
        var top_level: usize = 0;
        var child: usize = 0;
        var top_prev: ?*const anyopaque = null;
        var child_prev: ?*const anyopaque = null;

        fn topProc(hwnd: HWND, msg: UINT, wp: usize, lp: LPARAM) callconv(.winapi) isize {
            if (msg == c.WM_GETMINMAXINFO) top_level += 1;
            return sys.CallWindowProcW(top_prev, hwnd, msg, wp, lp);
        }

        fn childProc(hwnd: HWND, msg: UINT, wp: usize, lp: LPARAM) callconv(.winapi) isize {
            if (msg == c.WM_GETMINMAXINFO) child += 1;
            return sys.CallWindowProcW(child_prev, hwnd, msg, wp, lp);
        }

        fn subclass(hwnd: HWND, proc: anytype) ?*const anyopaque {
            return @ptrFromInt(@as(usize, @bitCast(sys.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(proc))))));
        }
    };
    const top = sys.CreateWindowExW(0, prompt_label_class, std.unicode.utf8ToUtf16LeStringLiteral(""), hostStyle(true, false), 0, 0, 640, 480, null, null, sys.GetModuleHandleW(null), null) orelse return lastError();
    defer _ = sys.DestroyWindow(top);
    const child = sys.CreateWindowExW(0, prompt_label_class, std.unicode.utf8ToUtf16LeStringLiteral(""), win32.surfaceWindowStyle(), 0, 0, 100, 100, top, null, sys.GetModuleHandleW(null), null) orelse return lastError();
    Counter.top_prev = Counter.subclass(top, &Counter.topProc);
    Counter.child_prev = Counter.subclass(child, &Counter.childProc);
    const flags: UINT = c.SWP_NOZORDER | c.SWP_NOACTIVATE;
    // The positive control: the top-level window is asked.
    if (sys.SetWindowPos(top, null, 10, 10, 600, 400, flags) == 0) return lastError();
    try std.testing.expect(Counter.top_level > 0);
    for ([_][2]i32{ .{ 300, 200 }, .{ 40, 30 }, .{ 2000, 1500 } }) |size| {
        if (sys.SetWindowPos(child, null, 5, 5, size[0], size[1], flags) == 0) return lastError();
    }
    if (sys.SetWindowPos(child, null, 0, 0, 0, 0, flags | c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_FRAMECHANGED | c.SWP_SHOWWINDOW) == 0) return lastError();
    try std.testing.expectEqual(@as(usize, 0), Counter.child);
}

test "win32 a background tab's config change, goto_tab and a tab click leave the window's state alone" {
    // A window's state is the window's: a config change from a tab behind
    // the front one does not reach it, and showing that tab gives the
    // window nothing of it (alpha 128 would).
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;

            try app.createWindow(default_title);
            const first = fixture.newest();
            const host = first.host.?;
            const hwnd = host.hwnd.?;
            const second = try app.createWindowSurface(&app.config, default_title, .{ .host_id = first.host_id });
            try std.testing.expectEqual(first, host.activeSurface().?);

            // A config change of the background tab does not reach its
            // window, which takes config from the pane it shows.
            var faded = try app.config.clone(std.testing.allocator);
            defer faded.deinit();
            faded.@"background-opacity" = 0.5;
            try std.testing.expect(try app.performAction(.{ .surface = second.core() }, .config_change, .{ .config = &faded }));
            try std.testing.expectEqual(@as(?u8, null), shownAlpha(hwnd));

            // Nor does showing that tab.
            try std.testing.expect(host.activateTabIndex(1));
            try std.testing.expectEqual(@as(?u8, null), shownAlpha(hwnd));
            try std.testing.expect(host.activateTabIndex(0));
            try std.testing.expectEqual(@as(?u8, null), shownAlpha(hwnd));

            try std.testing.expect(try app.performAction(.{ .surface = first.core() }, .goto_tab, .next));
            try std.testing.expectEqual(second, host.activeSurface().?);
            try std.testing.expectEqual(@as(?u8, null), shownAlpha(hwnd));
        }
    }.body);
}

test "win32 a config reload decorates a window unless a toggle chose its decorations" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;

            try app.createWindow(default_title);
            const plain = fixture.newest().host.?;
            try app.createWindow(default_title);
            const toggled_pane = fixture.newest();
            const toggled = toggled_pane.host.?;
            try std.testing.expect(try perform(toggled, toggled_pane, .toggle_window_decorations, {}));
            try std.testing.expect(!toggled.top_level.decorations_visible and toggled.top_level.decorations_overridden);

            var config = try app.config.clone(std.testing.allocator);
            defer config.deinit();
            for ([_]configpkg.Config.WindowDecoration{ .none, .auto }) |decoration| {
                config.@"window-decoration" = decoration;
                for ([_]*Host{ plain, toggled }) |host| try applyConfig(host, &config);
                try std.testing.expectEqual(decoration != .none, plain.top_level.decorations_visible);
                try std.testing.expect(!toggled.top_level.decorations_visible);
            }
        }
    }.body);
}

test "win32 scaleInitialClientSize converts logical initial size to physical pixels" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualDeep(
        apprt.SurfaceSize{ .width = 1680, .height = 810 },
        scaleInitialClientSize(
            .{ .width = 1120, .height = 540 },
            .{ .x = 1.5, .y = 1.5 },
        ),
    );
    try std.testing.expectEqualDeep(
        apprt.SurfaceSize{ .width = 701, .height = 300 },
        scaleInitialClientSize(
            .{ .width = 467, .height = 200 },
            .{ .x = 1.5, .y = 1.5 },
        ),
    );
    try std.testing.expectEqualDeep(
        apprt.SurfaceSize{
            .width = std.math.maxInt(u32),
            .height = std.math.maxInt(u32),
        },
        scaleInitialClientSize(
            .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) },
            .{ .x = 2.0, .y = 2.0 },
        ),
    );
}

test "win32 an initial size resizes a window of one pane that is neither zoomed nor fullscreen" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;

            try app.createWindow(default_title);
            const pane = fixture.newest();
            const host = pane.host.?;
            const hwnd = host.hwnd.?;
            const Case = struct { size: apprt.action.InitialSize, zoomed: bool = false, fullscreen: bool = false, panes: usize = 1 };
            for ([_]Case{
                .{ .size = .{ .width = 500, .height = 300 } },
                .{ .size = .{ .width = 520, .height = 320 }, .zoomed = true },
                .{ .size = .{ .width = 540, .height = 340 }, .fullscreen = true },
                .{ .size = .{ .width = 560, .height = 360 }, .panes = 2 },
            }) |case| {
                if (case.zoomed) _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
                if (case.fullscreen) try std.testing.expect(try perform(host, pane, .toggle_fullscreen, .native));
                if (case.panes == 2) _ = try app.createWindowSurface(&app.config, default_title, .{ .host_id = host.id });
                const before = try ForwardedKeysTest.clientSize(hwnd);
                try std.testing.expect(try perform(host, pane, .initial_size, case.size));
                try std.testing.expectEqual(@as(?apprt.SurfaceSize, .{ .width = case.size.width, .height = case.size.height }), pane.metrics.default_client_size);
                const resizes = !case.zoomed and !case.fullscreen and case.panes == 1;
                const expected = if (resizes) scaleInitialClientSize(pane.metrics.default_client_size.?, pane.content_scale) else before;
                try std.testing.expectEqual(expected, try ForwardedKeysTest.clientSize(hwnd));
                if (case.zoomed) _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
                if (case.fullscreen) try std.testing.expect(try perform(host, pane, .toggle_fullscreen, .native));
            }
        }
    }.body);
}

test "win32 window actions and tab switches leave a fullscreen window where it is" {
    // tabs-panes.md 2026-04-29: a tab's own actions must not drop its
    // window out of its state. The window's state is one copy, so no tab
    // switch or tab action writes it.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        var moves: usize = 0;
        var previous: ?*const anyopaque = null;
        const swp_hidewindow: UINT = 0x0080;

        fn proc(hwnd: HWND, msg: UINT, wp: usize, lp: LPARAM) callconv(.winapi) isize {
            if (msg == c.WM_WINDOWPOSCHANGED) {
                const pos: *const sys.WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lp)));
                const still: UINT = c.SWP_NOMOVE | c.SWP_NOSIZE;
                if (pos.flags & still != still or pos.flags & (c.SWP_SHOWWINDOW | swp_hidewindow) != 0) moves += 1;
            }
            return sys.CallWindowProcW(previous, hwnd, msg, wp, lp);
        }

        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            try app.createWindow(default_title);
            const first = fixture.newest();
            const host = first.host.?;
            const hwnd = host.hwnd.?;
            _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
            const normal = try Fixture.normalRect(hwnd);
            const second = try app.createWindowSurface(&app.config, default_title, .{ .host_id = host.id });
            try std.testing.expect(try app.performAction(.{ .surface = first.core() }, .toggle_fullscreen, .native));
            const screen = try Fixture.screenRect(hwnd);

            moves = 0;
            previous = @ptrFromInt(@as(usize, @bitCast(sys.SetWindowLongPtrW(hwnd, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&proc))))));
            try std.testing.expect(try app.performAction(.{ .surface = first.core() }, .goto_tab, .next));
            try std.testing.expectEqual(second, host.activeSurface().?);
            try std.testing.expect(host.activateTabIndex(0));
            // A new background tab's core init sends its size limit.
            const third = try app.createWindowSurface(&app.config, default_title, .{ .host_id = host.id });
            try std.testing.expect(try app.performAction(.{ .surface = third.core() }, .size_limit, .{ .min_width = 90, .min_height = 72, .max_width = 0, .max_height = 0 }));
            try std.testing.expect(try app.performAction(.{ .surface = first.core() }, .goto_tab, .last));
            try std.testing.expectEqual(third, host.activeSurface().?);
            try std.testing.expectEqual(@as(usize, 0), moves);
            try std.testing.expect(host.top_level.isFullscreen());
            try std.testing.expectEqualDeep(screen, try Fixture.screenRect(hwnd));

            // It leaves fullscreen to the window it was.
            try std.testing.expect(try app.performAction(.{ .surface = third.core() }, .toggle_fullscreen, .native));
            try std.testing.expect(sys.IsZoomed(hwnd) != 0);
            try std.testing.expectEqualDeep(normal, try Fixture.normalRect(hwnd));
        }
    }.body);
}
