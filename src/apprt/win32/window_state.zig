//! Win32 window state, extracted without changing transition order.
const win32 = @import("../win32.zig");
const runtime = win32.window_state_runtime;
const App = runtime.App;
const HWND = runtime.HWND;
const HWND_TOPMOST = runtime.HWND_TOPMOST;
const Host = runtime.Host;
const LPARAM = runtime.LPARAM;
const MINMAXINFO = runtime.MINMAXINFO;
const MONITORINFO = runtime.MONITORINFO;
const POINT = runtime.POINT;
const RECT = runtime.RECT;
const Surface = runtime.Surface;
const UINT = runtime.UINT;
const WINDOWPLACEMENT = runtime.WINDOWPLACEMENT;
const apprt = runtime.apprt;
const c = runtime.c;
const child_window = @import("child_window.zig");
const configpkg = runtime.configpkg;
const configuredHostWindowPosition = runtime.configuredHostWindowPosition;
const forwardedArgvSetsKey = runtime.forwardedArgvSetsKey;
const lastError = child_window.lastError;
const log = runtime.log;
const scaleInitialClientSize = runtime.scaleInitialClientSize;
const std = runtime.std;
const sys = runtime.sys;
const win32_theme = runtime.win32_theme;
const window_start = @import("window_start.zig");
const test_runtime = if (@import("builtin").is_test) win32.window_state_test_runtime else struct {};
const BOOL = test_runtime.BOOL;
const CoreApp = test_runtime.CoreApp;
const HDC = test_runtime.HDC;
const LPCWSTR = test_runtime.LPCWSTR;
const SafeModeAppFixture = test_runtime.SafeModeAppFixture;
const Tab = test_runtime.Tab;
const TestSession = test_runtime.TestSession;
const WindowStartTestApp = test_runtime.WindowStartTestApp;
const builtin = test_runtime.builtin;
const cascadeStep = window_start.cascadeStep;
const default_title = test_runtime.default_title;
const monitorInfo = test_runtime.monitorInfo;
const placementTestApp = test_runtime.placementTestApp;
const placementTestHost = test_runtime.placementTestHost;
const prompt_label_class = child_window.prompt_label_class;
const runOnHiddenDesktop = test_runtime.runOnHiddenDesktop;
const testHostIsLayered = test_runtime.testHostIsLayered;
const testLayeredAlpha = test_runtime.testLayeredAlpha;
const testWindowStyle = test_runtime.testWindowStyle;
const win32_quick_terminal = test_runtime.win32_quick_terminal;

pub const TopLevel = window_start.TopLevel;
pub const InitialShow = window_start.InitialShow;
pub const Enter = window_start.Enter;
pub const undecoratedKeepsFrame = window_start.undecoratedKeepsFrame;
pub const hostStyle = window_start.hostStyle;
pub const fitRectInWork = window_start.fitRectInWork;
pub const workspaceRectToScreen = window_start.workspaceRectToScreen;
pub const screenRectToWorkspace = window_start.screenRectToWorkspace;

/// Where a new window comes from, which decides how it starts (`begin`).
pub const Origin = union(window_start.Kind) {
    /// An ordinary new window: the first one, or a new tab with no window to
    /// open it in.
    fresh,
    /// Opened from `source`: `new_window`, a forwarded launch, a profile in
    /// a new window. `forwarded` is the argv a forwarded launch applied to
    /// the new window's config.
    copy: struct { source: *const Host, forwarded: []const [:0]const u8 = &.{} },
    /// A restored session's or launched layout's window. Session restore
    /// places it, and gives it `maximize` and `fullscreen`, once its tabs are
    /// there.
    restore,
    /// The quick terminal, first shown as asked.
    quick_terminal: InitialShow,
    /// A handed-off console's window, first shown as its client asked.
    adopted: InitialShow,
};

/// A pane's metrics, from its own font: core init's `cell_size`,
/// `size_limit` and `initial_size`.
pub const PaneMetrics = struct {
    cell_size_pixels: apprt.action.CellSize,
    size_limit: apprt.action.SizeLimit,
    default_client_size: ?apprt.SurfaceSize,
};

pub fn paneMetrics(pane: *const Surface) PaneMetrics {
    return .{
        .cell_size_pixels = pane.cell_size_pixels,
        .size_limit = pane.size_limit,
        .default_client_size = pane.default_client_size,
    };
}

/// A new window's start between `begin` and its last stage, kept on its
/// Host (`Host.pending_start`).
pub const Pending = struct {
    plan: window_start.Plan,
    /// The corners of the windows on screen when a copy begins, which its
    /// cascade steps past (`Registry.windowCorners`).
    occupied: [32]POINT = undefined,
    occupied_len: usize = 0,
    /// The metrics of the source's active pane, which a copy's first pane
    /// takes.
    source_pane: ?PaneMetrics = null,
    /// The last stage carried out.
    reached: ?Stage = null,

    fn corners(self: *const Pending) []const POINT {
        return self.occupied[0..self.occupied_len];
    }
};

/// What `begin` decides before the window exists: the state and style it is
/// created with, and where (`CW_USEDEFAULT` unless `window-position-x/y`).
pub const Start = struct {
    top_level: TopLevel,
    style: u32,
    x: i32,
    y: i32,
    pending: Pending,
};

/// What `config` asks of how its window starts.
pub fn wants(config: *const configpkg.Config) window_start.Wants {
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
pub fn forwardedKeys(argv: []const [:0]const u8) window_start.Forwarded {
    return .{
        .size = forwardedArgvSetsKey(argv, "window-width") or forwardedArgvSetsKey(argv, "window-height"),
        .decoration = forwardedArgvSetsKey(argv, "window-decoration"),
        .opacity = forwardedArgvSetsKey(argv, "background-opacity"),
    };
}

/// Decides how a new window with `config` starts, before it exists. A copy
/// reads its source here, once: the window's state and geometry, the corners
/// of the windows on screen and its active pane's metrics.
pub fn begin(app: *const App, config: *const configpkg.Config, origin: Origin) !Start {
    var pending: Pending = .{ .plan = undefined };
    var snapshot: ?window_start.Snapshot = null;
    var argv: []const [:0]const u8 = &.{};
    var show: InitialShow = .activate;
    switch (origin) {
        .copy => |copy| {
            snapshot = try snapshotOf(copy.source);
            pending.occupied_len = app.registry.windowCorners(&pending.occupied).len;
            if (copy.source.activeSurface()) |pane| pending.source_pane = paneMetrics(pane);
            argv = copy.forwarded;
        },
        .quick_terminal, .adopted => |first_show| show = first_show,
        .fresh, .restore => {},
    }
    pending.plan = window_start.plan(
        std.meta.activeTag(origin),
        wants(config),
        forwardedKeys(argv),
        if (snapshot) |*source| source else null,
        show,
        app.os_build,
    );
    const position = pending.plan.position;
    return .{
        .top_level = pending.plan.top_level,
        .style = pending.plan.style,
        .x = if (position) |at| at.x else c.CW_USEDEFAULT,
        .y = if (position) |at| at.y else c.CW_USEDEFAULT,
        .pending = pending,
    };
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
};

/// Whether the pane that first showed its window presents it with focus.
pub const Focus = enum { take, leave };

/// Carries out the `at` stage of the start `begin` decided for `host`.
pub fn advance(host: *Host, comptime at: Stage) !(if (at == .before_show) Focus else void) {
    const pending = &host.pending_start.?;
    std.debug.assert(pending.reached == null or @intFromEnum(pending.reached.?) < @intFromEnum(at));
    pending.reached = at;
    return switch (at) {
        .created => onCreated(host, pending),
        .before_show => beforeShow(host, pending),
        .after_show => afterShow(host, pending),
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
    const placed = window_start.place(&pending.plan, pending.corners(), null);
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
fn beforeShow(host: *Host, pending: *const Pending) !Focus {
    // Layered before any show: layering a window already on screen shows
    // it opaque and then fades it (#234). The layered alpha is the only
    // thing that makes `background-opacity` visible: DWM discards the GL
    // child's alpha. A window that could not be layered is still usable.
    applyBackgroundOpacity(host) catch |err| {
        log.warn("win32 initial background opacity failed err={}", .{err});
    };
    try host.refreshChrome();
    try host.layout();
    // `maximize` and `fullscreen` (#496), before the first show, so the
    // window first appears in that state. Core init has already given it
    // `window-width`/`window-height`, so that is the normal rect it returns
    // to. A copy takes them after its source's state.
    if (pending.plan.kind != .copy) applyWindowStart(host, pending.plan.enter);
    const show = pending.plan.show;
    if (show.showCommand()) |command| if (host.hwnd) |hwnd| {
        _ = sys.ShowWindow(hwnd, command);
        _ = sys.UpdateWindow(hwnd);
    };
    return if (show.takesFocus()) .take else .leave;
}

fn afterShow(host: *Host, pending: *const Pending) !void {
    defer host.pending_start = null;
    if (pending.plan.source == null) return;
    if (pending.source_pane) |metrics| if (host.activeSurface()) |pane| copyPaneMetrics(pane, metrics, pending.plan.keeps);
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
pub fn createdHostWindowStyleCorrection(requested: u32, created: u32) ?u32 {
    const forced: u32 = c.WS_CLIPSIBLINGS;
    if ((requested & ~forced) == (created & ~forced)) return null;
    return requested;
}

/// Put back the host style `CreateWindowEx` altered (see
/// `createdHostWindowStyleCorrection`). The `.created` stage calls this
/// while the host is still hidden and has no tabs, so no terminal is sized
/// against, or shown with, the frame Windows added.
pub fn restoreRequestedHostWindowStyle(hwnd: HWND, requested: u32) void {
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

pub fn sizeLimitEquals(a: apprt.action.SizeLimit, b: apprt.action.SizeLimit) bool {
    return a.min_width == b.min_width and
        a.min_height == b.min_height and
        a.max_width == b.max_width and
        a.max_height == b.max_height;
}

/// A window action from any pane of `host`'s window. The window's own
/// actions change the Window, whichever of its panes asked. `size_limit` and
/// `initial_size` come from one pane's font: they are kept on that pane, and
/// the Window acts on them as before (the active pane's limit is the window's
/// minimum track size; an initial size resizes a window of one pane).
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
            if (host.top_level.opacity >= 0.999) return false;
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
    if (host.top_level.opacity >= 0.999) host.top_level.force_opaque = false;
    try applyBackgroundOpacity(host);
}

/// `WM_GETMINMAXINFO`: the active pane's `size_limit`, which is in client
/// pixels, plus this window's frame.
pub fn updateMinMaxInfo(host: *Host, lParam: LPARAM) void {
    const limit = (host.activeSurface() orelse return).size_limit;
    if (limit.min_width == 0 and
        limit.min_height == 0 and
        limit.max_width == 0 and
        limit.max_height == 0) return;

    const info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const hwnd = host.hwnd orelse return;
    var client_rect: RECT = undefined;
    var window_rect: RECT = undefined;
    if (sys.GetClientRect(hwnd, &client_rect) == 0) return;
    if (sys.GetWindowRect(hwnd, &window_rect) == 0) return;

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
}

const HWND_NOTOPMOST: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// Makes `rect` (screen coordinates) the rect the minimized `hwnd` returns
/// to, and leaves it minimized.
pub fn setMinimizedNormalRect(hwnd: HWND, rect: RECT) !void {
    var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
    placement.length = @sizeOf(WINDOWPLACEMENT);
    if (sys.GetWindowPlacement(hwnd, &placement) == 0) return lastError();
    // Workspace coordinates of the monitor the rect is on, as
    // `sessionWindowPlacementOn` reads them.
    const center: POINT = .{
        .x = @divTrunc(rect.left, 2) + @divTrunc(rect.right, 2),
        .y = @divTrunc(rect.top, 2) + @divTrunc(rect.bottom, 2),
    };
    const monitor = sys.MonitorFromPoint(center, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
    var info: MONITORINFO = std.mem.zeroes(MONITORINFO);
    info.cbSize = @sizeOf(MONITORINFO);
    if (sys.GetMonitorInfoW(monitor, &info) == 0) return lastError();
    placement.rcNormalPosition = screenRectToWorkspace(rect, info);
    placement.showCmd = c.SW_SHOWMINNOACTIVE;
    if (sys.SetWindowPlacement(hwnd, &placement) == 0) return lastError();
}

/// `window_start.restoresMaximized` for the window `hwnd`.
pub fn restoresMaximized(hwnd: HWND, placement: *const WINDOWPLACEMENT) bool {
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

fn setInitialSize(host: *Host, pane: *Surface, size: apprt.action.InitialSize) !void {
    pane.default_client_size = .{
        .width = @intCast(size.width),
        .height = @intCast(size.height),
    };
    const hwnd = host.hwnd orelse return;
    if (host.top_level.isFullscreen() or sys.IsZoomed(hwnd) != 0 or paneCount(host) != 1) return;
    const client_size = scaleInitialClientSize(pane.default_client_size.?, pane.content_scale);
    try resizeClientArea(host, client_size.width, client_size.height);
}

fn resetWindowSize(host: *Host, pane: *const Surface) !void {
    const size = pane.default_client_size orelse return;
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
    if (sizeLimitEquals(pane.size_limit, limit)) return;
    pane.size_limit = limit;
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
pub fn applyWindowStart(host: *Host, start: Enter) void {
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
    // A minimized window comes back first. SetWindowPos would move only
    // its icon, and it would return from the taskbar as a popup at its
    // normal rect. A restored session's first window is minimized here
    // under a minimized launch (`applyRestoredWindowPlacement`).
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

    const screen = monitor.info.rcMonitor;
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

/// What `hwnd`, fullscreen since `saved`, returns to when it leaves
/// fullscreen on the monitor it is on now (`window_start.returnOn`).
pub fn fullscreenReturn(saved: TopLevel.Return, hwnd: HWND) !TopLevel.Return {
    if (saved.monitor == null) return saved;
    return window_start.returnOn(saved, try windowMonitor(hwnd));
}

fn leaveFullscreen(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
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
    var info: MONITORINFO = std.mem.zeroes(MONITORINFO);
    info.cbSize = @sizeOf(MONITORINFO);
    if (sys.GetMonitorInfoW(monitor, &info) == 0) return lastError();
    return .{ .id = @intFromPtr(monitor), .info = info, .dpi = sys.GetDpiForWindow(hwnd) };
}

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

pub fn resizeClientArea(host: *Host, client_width: u32, client_height: u32) !void {
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

/// Gives a copy the state of the window it is opened from, keeping what
/// `keeps` names, and puts it where `window_start.place` says.
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
    const placed = window_start.place(&pending.plan, pending.corners(), own);
    const from = pending.plan.source.?.state;
    const top_level = &host.top_level;
    if (!keeps.decoration) {
        top_level.decorations_visible = from.decorations_visible;
        top_level.decorations_overridden = from.decorations_overridden;
    }
    top_level.fullscreen = placed.fullscreen;
    top_level.topmost = from.topmost;
    if (!keeps.opacity) {
        top_level.opacity = from.opacity;
        top_level.force_opaque = from.force_opaque;
    }

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

/// Gives `pane` `source`, the metrics of a pane of the window it is opened
/// from, keeping its own client size when `keeps.size` says so.
pub fn copyPaneMetrics(pane: *Surface, source: PaneMetrics, keeps: window_start.Keeps) void {
    if (!keeps.size) pane.default_client_size = source.default_client_size;
    pane.cell_size_pixels = source.cell_size_pixels;
    pane.size_limit = source.size_limit;
}

/// `undecoratedKeepsFrame` for `host`. The quick terminal flag is the
/// host's: a split or tab opened inside the quick terminal is an ordinary
/// surface in the quick terminal's window.
pub fn keepsFrameUndecorated(host: *const Host) bool {
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

fn applyBackgroundOpacity(host: *Host) !void {
    const hwnd = host.hwnd orelse return;
    const ex_style_raw = sys.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
    var ex_style: u32 = @intCast(@as(usize, @bitCast(ex_style_raw)));

    const alpha = host.top_level.alpha() orelse {
        if ((ex_style & c.WS_EX_LAYERED) != 0) {
            ex_style &= ~@as(u32, c.WS_EX_LAYERED);
            _ = sys.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex_style))));
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
        return;
    };

    if ((ex_style & c.WS_EX_LAYERED) == 0) {
        ex_style |= c.WS_EX_LAYERED;
        _ = sys.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex_style))));
    }

    if (sys.SetLayeredWindowAttributes(hwnd, 0, alpha, c.LWA_ALPHA) == 0) {
        return lastError();
    }
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
            try takeSourceState(&clone, &start.pending);
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
                try std.testing.expectEqualDeep(@as(?apprt.SurfaceSize, .{ .width = ForwardedKeysTest.own.width, .height = ForwardedKeysTest.own.height }), clone.default_client_size);
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
                try std.testing.expect(!testHostIsLayered(clone.windowHwnd().?));
                t.fixture.closeWindow(clone);
            }
            // Before the fix the copy stayed opaque.
            {
                const clone = try t.forward(&.{"--background-opacity=0.5"}, null);
                const hwnd = clone.windowHwnd().?;
                try std.testing.expectEqual(@as(f64, 0.5), clone.host.?.top_level.opacity);
                try std.testing.expect(testHostIsLayered(hwnd));
                try std.testing.expect((testLayeredAlpha(hwnd) orelse 255) < 255);
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
            try reload(app, &both);
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
            try reload(app, &neither);
            try std.testing.expect(started.host.?.top_level.isFullscreen() and sys.IsZoomed(started_hwnd) == 0);
            try std.testing.expectEqualDeep(started_rect, try Fixture.screenRect(started_hwnd));
            try std.testing.expect(sys.IsZoomed(plain_hwnd) == 0 and !plain.host.?.top_level.isFullscreen());
            try std.testing.expectEqualDeep(plain_rect, try Fixture.screenRect(plain_hwnd));
            _ = try perform(started.host.?, started, .toggle_fullscreen, .native);
            try std.testing.expect(sys.IsZoomed(started_hwnd) != 0);
        }

        /// What a reload does once the file is read (`CoreApp.updateConfig`):
        /// each pane's config change, then the app's.
        fn reload(app: *App, config: *const configpkg.Config) !void {
            for (app.registry.windows.items) |surface| {
                try std.testing.expect(try app.performAction(.{ .surface = surface.core() }, .config_change, .{ .config = config }));
            }
            try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = config }));
        }
    }.body);
}

// One copy of the window state, on the Window. Every pane used to keep its
// own, and each window action, `.cell_size`, `.size_limit`, `.initial_size`
// and a pane's `config_change` copied the acting pane's into every other pane
// of its window, ending in `ShowWindow(SW_RESTORE)` or `maximizeWithPlacement`
// on the same HWND; `goto_tab` re-applied the new pane's copy. The tests below
// were measured on that code first; the ones that changed say what it did.

test "win32 a first window and a window opened from it are layered at their opacity at the first show" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const Fixture = WindowStartTestApp;

            // The default, opaque, is never layered: that would put every
            // window on a composition path it does not need.
            try app.createWindow(default_title);
            var shown = Fixture.first_show orelse return error.TestWindowNeverShown;
            try std.testing.expect(shown.ex_style & c.WS_EX_LAYERED == 0);
            try std.testing.expectEqual(@as(?u8, null), shown.alpha);
            fixture.closeWindow(fixture.newest());

            // Layered before any show (#234): no opaque frame, then a fade.
            app.config.@"background-opacity" = 0.5;
            try app.createWindow(default_title);
            const source = fixture.newest();
            shown = Fixture.first_show orelse return error.TestWindowNeverShown;
            try std.testing.expect(shown.ex_style & c.WS_EX_LAYERED != 0);
            try std.testing.expectEqual(@as(?u8, 128), shown.alpha);

            // A copy shows at its source's opacity before it takes the
            // source's state.
            try std.testing.expect(try app.performAction(.app, .new_window, .{ .arguments = null }));
            shown = Fixture.first_show orelse return error.TestWindowNeverShown;
            try std.testing.expect(shown.ex_style & c.WS_EX_LAYERED != 0);
            try std.testing.expectEqual(@as(?u8, 128), shown.alpha);
            fixture.closeWindow(fixture.newest());

            // A copy of a window the user forced opaque is never shown faded.
            // Forced opaque, a window drops the layered style, not just its
            // alpha to 255, and takes both back with the toggle.
            try std.testing.expect(try app.performAction(.{ .surface = source.core() }, .toggle_background_opacity, {}));
            try std.testing.expect(!testHostIsLayered(source.windowHwnd().?));
            try std.testing.expect(try app.performAction(.app, .new_window, .{ .arguments = null }));
            shown = Fixture.first_show orelse return error.TestWindowNeverShown;
            try std.testing.expect(shown.ex_style & c.WS_EX_LAYERED == 0);
            try std.testing.expectEqual(@as(?u8, null), shown.alpha);
            try std.testing.expect(try app.performAction(.{ .surface = source.core() }, .toggle_background_opacity, {}));
            try std.testing.expect(testHostIsLayered(source.windowHwnd().?));
            try std.testing.expectEqual(@as(?u8, 128), testLayeredAlpha(source.windowHwnd().?));
        }
    }.body);
}

test "win32 a config change or size limit on the active pane of a minimized window leaves it minimized" {
    // Measured before one copy: the copy into the other pane ended in
    // SW_RESTORE on the same HWND and brought the two-pane window back,
    // while the one-pane window, with no other pane, stayed minimized.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const limit: apprt.action.SizeLimit = .{ .min_width = 120, .min_height = 60, .max_width = 0, .max_height = 0 };

            try app.createWindow(default_title);
            const single = fixture.newest();
            const single_hwnd = single.windowHwnd().?;
            try app.createWindow(default_title);
            const pair = fixture.newest();
            const pair_hwnd = pair.windowHwnd().?;
            _ = try app.createWindowSurface(&app.config, default_title, .{ .host_id = pair.host_id });
            try std.testing.expectEqual(pair, pair.host.?.activeSurface().?);

            for ([_]*Surface{ single, pair }) |pane| {
                const hwnd = pane.windowHwnd().?;
                _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
                try std.testing.expect(sys.IsIconic(hwnd) != 0);
                try std.testing.expect(try app.performAction(.{ .surface = pane.core() }, .config_change, .{ .config = &app.config }));
            }
            try std.testing.expect(sys.IsIconic(single_hwnd) != 0);
            try std.testing.expect(sys.IsIconic(pair_hwnd) != 0);

            for ([_]*Surface{ single, pair }) |pane| {
                const hwnd = pane.windowHwnd().?;
                _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
                try std.testing.expect(sys.IsIconic(hwnd) != 0);
                try std.testing.expect(try app.performAction(.{ .surface = pane.core() }, .size_limit, limit));
            }
            try std.testing.expect(sys.IsIconic(single_hwnd) != 0);
            try std.testing.expect(sys.IsIconic(pair_hwnd) != 0);
        }
    }.body);
}

test "win32 a reload leaves the active window active and a minimized window minimized" {
    // Measured before one copy: each two-pane window's copy ended in
    // SW_RESTORE on its HWND. On a normal window that changed nothing; a
    // minimized one was restored and activated, which also showed that this
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
            try reload(app);
            try std.testing.expectEqual(@as(?HWND, older), sys.GetActiveWindow());

            _ = sys.ShowWindow(newer, c.SW_SHOWMINNOACTIVE);
            _ = sys.SetActiveWindow(older);
            try std.testing.expectEqual(@as(?HWND, older), sys.GetActiveWindow());
            try reload(app);
            try std.testing.expect(sys.IsIconic(newer) != 0);
            try std.testing.expectEqual(@as(?HWND, older), sys.GetActiveWindow());
        }

        /// A reload: each pane's config change, then the app's.
        fn reload(app: *App) !void {
            for (app.registry.windows.items) |pane| {
                try std.testing.expect(try app.performAction(.{ .surface = pane.core() }, .config_change, .{ .config = &app.config }));
            }
            try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &app.config }));
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
            try std.testing.expectEqual(source.cell_size_pixels, clone.cell_size_pixels);
            try std.testing.expect(sizeLimitEquals(source.size_limit, clone.size_limit));
            try std.testing.expectEqual(source.default_client_size, clone.default_client_size);
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
    // Measured before one copy: the background tab's config change changed
    // its own copy, and goto_tab, not a tab click, gave the window that
    // copy's opacity (alpha 128).
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
            try std.testing.expect(!testHostIsLayered(hwnd));

            // Nor does showing that tab.
            try std.testing.expect(host.activateTabIndex(1));
            try std.testing.expect(!testHostIsLayered(hwnd));
            try std.testing.expect(host.activateTabIndex(0));
            try std.testing.expect(!testHostIsLayered(hwnd));

            try std.testing.expect(try app.performAction(.{ .surface = first.core() }, .goto_tab, .next));
            try std.testing.expectEqual(second, host.activeSurface().?);
            try std.testing.expect(!testHostIsLayered(hwnd));
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
                try std.testing.expectEqual(@as(?apprt.SurfaceSize, .{ .width = case.size.width, .height = case.size.height }), pane.default_client_size);
                const resizes = !case.zoomed and !case.fullscreen and case.panes == 1;
                const expected = if (resizes) scaleInitialClientSize(pane.default_client_size.?, pane.content_scale) else before;
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
