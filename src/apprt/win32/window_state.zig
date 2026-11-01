//! Win32 window state, extracted without changing transition order.
const win32 = @import("../win32.zig");
const build_config = @import("../../build_config.zig");
const win32_types = @import("../win32_types.zig");
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
const SurfaceInitOptions = runtime.SurfaceInitOptions;
const UINT = runtime.UINT;
const WINDOWPLACEMENT = runtime.WINDOWPLACEMENT;
const WS_OVERLAPPEDWINDOW = runtime.WS_OVERLAPPEDWINDOW;
const alphaByteForOpacity = runtime.alphaByteForOpacity;
const apprt = runtime.apprt;
const c = runtime.c;
const child_window = @import("child_window.zig");
const configpkg = runtime.configpkg;
const configuredHostWindowPosition = runtime.configuredHostWindowPosition;
const effectiveBackgroundOpacity = runtime.effectiveBackgroundOpacity;
const forwardedArgvSetsKey = runtime.forwardedArgvSetsKey;
const lastError = child_window.lastError;
const log = runtime.log;
const scaleInitialClientSize = runtime.scaleInitialClientSize;
const std = runtime.std;
const sys = runtime.sys;
const win32_theme = runtime.win32_theme;
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
const createTestHostWindow = test_runtime.createTestHostWindow;
const default_title = test_runtime.default_title;
const deinitTestHostWindowFixture = test_runtime.deinitTestHostWindowFixture;
const initTestHostWindowFixture = test_runtime.initTestHostWindowFixture;
const monitorInfo = test_runtime.monitorInfo;
const placementTestApp = test_runtime.placementTestApp;
const placementTestSurface = test_runtime.placementTestSurface;
const prompt_label_class = child_window.prompt_label_class;
const runOnHiddenDesktop = test_runtime.runOnHiddenDesktop;
const testHostIsLayered = test_runtime.testHostIsLayered;
const testLayeredAlpha = test_runtime.testLayeredAlpha;
const testWindowStyle = test_runtime.testWindowStyle;
const win32_quick_terminal = test_runtime.win32_quick_terminal;
const win32_terminal_handoff = test_runtime.win32_terminal_handoff;

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

pub fn decorationsVisibleForConfig(value: configpkg.Config.WindowDecoration) bool {
    return value != .none;
}

pub fn initialDecorationsVisibleForSource(config: *const configpkg.Config, clone_state_from: ?*const Surface) bool {
    if (clone_state_from) |source| return source.decorations_visible;
    return decorationsVisibleForConfig(config.@"window-decoration");
}

pub fn startupHostWindowStyle(framed: bool, fullscreen: bool) u32 {
    return effectiveHostWindowStyle(framed, fullscreen, true) & ~@as(u32, c.WS_VISIBLE);
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
/// afterwards through `Surface.applyWindowStyle`. Creating the host as `WS_POPUP` instead would
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
/// `createdHostWindowStyleCorrection`). `App.createHost` calls this while
/// the host is still hidden and has no tabs, so no terminal is sized
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

/// `framed` picks the system frame: decorated windows, and on Windows 11
/// undecorated ones too (`undecoratedKeepsFrame`).
pub fn effectiveHostWindowStyle(
    framed: bool,
    fullscreen: bool,
    hosted: bool,
) u32 {
    if (fullscreen) {
        return if (hosted)
            c.WS_VISIBLE | c.WS_POPUP | c.WS_CLIPCHILDREN
        else
            c.WS_VISIBLE | c.WS_POPUP;
    }

    if (framed) {
        return if (hosted)
            c.WS_VISIBLE | WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN
        else
            c.WS_VISIBLE | WS_OVERLAPPEDWINDOW;
    }

    return if (hosted)
        c.WS_VISIBLE | c.WS_OVERLAPPED | c.WS_CLIPCHILDREN
    else
        c.WS_VISIBLE | c.WS_OVERLAPPED;
}

pub fn sharesHostWindowState(dst_host_id: ?u32, src_host_id: ?u32) bool {
    return dst_host_id != null and src_host_id != null and dst_host_id.? == src_host_id.?;
}

pub fn sizeLimitEquals(a: apprt.action.SizeLimit, b: apprt.action.SizeLimit) bool {
    return a.min_width == b.min_width and
        a.min_height == b.min_height and
        a.max_width == b.max_width and
        a.max_height == b.max_height;
}

pub fn shouldResizeHostForInitialSize(host_surface_count: usize) bool {
    return host_surface_count == 1;
}

pub fn sharedHostWindowFrameStateEquals(a: *const Surface, b: *const Surface) bool {
    return a.decorations_visible == b.decorations_visible and
        a.fullscreen == b.fullscreen and
        sizeLimitEquals(a.size_limit, b.size_limit);
}

pub fn sharedHostWindowTopmostEquals(a: *const Surface, b: *const Surface) bool {
    return a.topmost == b.topmost;
}

pub fn sharedHostWindowOpacityEquals(a: *const Surface, b: *const Surface) bool {
    return alphaByteForOpacity(effectiveBackgroundOpacity(
        a.background_opacity_default,
        a.background_opacity_force_opaque,
    )) == alphaByteForOpacity(effectiveBackgroundOpacity(
        b.background_opacity_default,
        b.background_opacity_force_opaque,
    ));
}

pub fn shouldPropagateSharedHostWindowState(source: *const Surface) bool {
    const host = source.host orelse return true;
    return host.activeSurface() == source;
}

pub fn shouldApplyConfigDecorations(decorations_visible_overridden: bool) bool {
    return !decorations_visible_overridden;
}

/// `positioned`: `WindowKeeps.position`.
pub fn inheritHostWindowState(self: *App, destination: *Host, source: *Host, positioned: bool, config: *const configpkg.Config) !void {
    const dst_hwnd = destination.hwnd orelse return;
    const src_hwnd = source.hwnd orelse return;
    const fullscreen = if (source.activeSurface()) |surface| surface.fullscreen else false;
    var placed = try newWindowPlacement(self, src_hwnd, fullscreen, dst_hwnd, null);
    // The destination renderer is not initialized yet. Avoid initially
    // showing a monitor-sized OpenGL clone; the later surface placement
    // corrects this provisional choice against the actual backend.
    if (fullscreen and src_hwnd != dst_hwnd) {
        const candidate = config.@"window-show-tab-bar" == .never and config.renderer == .opengl;
        placed.rect = fullscreenRectForCandidate(placed.rect, candidate);
    }
    if (sys.SetWindowPos(
        dst_hwnd,
        null,
        placed.rect.left,
        placed.rect.top,
        placed.rect.right - placed.rect.left,
        placed.rect.bottom - placed.rect.top,
        newWindowSetPosFlags(positioned, false, placed),
    ) == 0) {
        return lastError();
    }
}

pub fn syncHostWindowState(self: *App, source: *Surface) !void {
    if (!shouldPropagateSharedHostWindowState(source)) return;
    var host_surfaces = try self.registry.collectHostSurfaces(self.core_app.alloc, source.host_id);
    defer host_surfaces.deinit(self.core_app.alloc);
    for (host_surfaces.items) |candidate| {
        if (candidate == source) continue;
        try candidate.inheritWindowStateFrom(source, .{});
    }
}

const HWND_NOTOPMOST: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

/// What a new window keeps of its own config over the state it copies from
/// the window it is opened from (`new_window`, a forwarded launch, a profile
/// in a new window; `Surface.inheritWindowStateFrom`). By default it copies
/// that window's size, one cascade step off it, its maximized or fullscreen
/// state, its decorations and its background opacity.
pub const WindowKeeps = struct {
    /// `window-position-x/y` place it: it stays where `App.createHost` put
    /// it and takes only the size.
    position: bool = false,
    /// The size core init gave it from its `window-width`/`window-height`.
    /// Its state is still the source's: maximized or fullscreen, it returns
    /// to that size.
    size: bool = false,
    /// Its own `window-decoration`.
    decoration: bool = false,
    /// Its own `background-opacity`.
    background_opacity: bool = false,

    /// What a window `Surface.init` creates keeps: its position whenever its
    /// config places it, as for every new window, and the rest when a
    /// forwarded launch set them. docs/windows.md ("Forwarded arguments")
    /// says the running noctty honors them, and copying the source dropped
    /// them all. The same keys from the app config are still the source's.
    pub fn forNewSurface(config: *const configpkg.Config, opts: SurfaceInitOptions) WindowKeeps {
        const argv = opts.forwarded_arguments orelse &.{};
        return .{
            .position = configuredHostWindowPosition(config) != null,
            // Core init sizes the window only when both are set.
            .size = (forwardedArgvSetsKey(argv, "window-width") or forwardedArgvSetsKey(argv, "window-height")) and
                config.@"window-width" > 0 and config.@"window-height" > 0,
            .decoration = forwardedArgvSetsKey(argv, "window-decoration"),
            .background_opacity = forwardedArgvSetsKey(argv, "background-opacity"),
        };
    }
};

test "win32 a new window keeps the forwarded window keys and the configured position" {
    var config = try configpkg.Config.default(std.testing.allocator);
    defer config.deinit();
    try std.testing.expectEqual(WindowKeeps{}, WindowKeeps.forNewSurface(&config, .{}));
    const argv: []const [:0]const u8 = &.{ "--window-width=80", "--window-decoration=none", "--background-opacity=0.5" };
    // A size needs both keys in the window's config, as core init does.
    try std.testing.expectEqual(
        WindowKeeps{ .decoration = true, .background_opacity = true },
        WindowKeeps.forNewSurface(&config, .{ .forwarded_arguments = argv }),
    );
    config.@"window-width" = 80;
    config.@"window-height" = 24;
    try std.testing.expectEqual(
        WindowKeeps{ .size = true, .decoration = true, .background_opacity = true },
        WindowKeeps.forNewSurface(&config, .{ .forwarded_arguments = argv }),
    );
    // From the app config they stay the source's; the position is the
    // window's either way.
    config.@"window-position-x" = 10;
    try std.testing.expectEqual(WindowKeeps{}, WindowKeeps.forNewSurface(&config, .{}));
    config.@"window-position-y" = 20;
    try std.testing.expectEqual(WindowKeeps{ .position = true }, WindowKeeps.forNewSurface(&config, .{}));
}

/// The state a new top-level window starts in from its config's `maximize`
/// and `fullscreen` (#496). Both apply to every new window, restored and
/// forwarded ones included, but never to a tab, a split, the quick terminal
/// or a handed-off console, which keeps the show state its client asked for.
/// A config reload does not change the windows already open.
pub const WindowStart = struct {
    maximize: bool = false,
    fullscreen: bool = false,

    pub fn fromConfig(config: *const configpkg.Config) WindowStart {
        return .{ .maximize = config.maximize, .fullscreen = config.fullscreen != .false };
    }

    /// What `Surface.init` applies to the window it creates.
    pub fn forNewSurface(config: *const configpkg.Config, opts: SurfaceInitOptions) WindowStart {
        if (opts.host_id != null or opts.quick_terminal or opts.adopted_session != null or
            !opts.config_window_start) return .{};
        return fromConfig(config);
    }
};

test "win32 maximize and fullscreen start only a new ordinary window" {
    var config = try configpkg.Config.default(std.testing.allocator);
    defer config.deinit();
    config.maximize = true;
    config.fullscreen = .true;
    const both: WindowStart = .{ .maximize = true, .fullscreen = true };
    try std.testing.expectEqual(both, WindowStart.forNewSurface(&config, .{}));
    // A clone of another window takes them too (after it copies the
    // source's state), and so does a window a forwarded argv configured.
    var source: Surface = undefined;
    try std.testing.expectEqual(both, WindowStart.forNewSurface(&config, .{ .clone_state_from = &source }));
    // Not a tab or a split of a window that is already open, the quick
    // terminal, a handed-off console, or a restored window, which applies
    // them once it is at its saved rect.
    var pending: win32_terminal_handoff.PendingSession = undefined;
    for ([_]SurfaceInitOptions{
        .{ .host_id = 1 },
        .{ .host_id = 1, .tab_id = 1, .clone_state_from = &source },
        .{ .quick_terminal = true },
        .{ .adopted_session = &pending },
        .{ .config_window_start = false },
    }) |opts| {
        try std.testing.expectEqual(WindowStart{}, WindowStart.forNewSurface(&config, opts));
    }
    config.maximize = false;
    config.fullscreen = .false;
    try std.testing.expectEqual(WindowStart{}, WindowStart.forNewSurface(&config, .{}));
}

pub const FullscreenMonitor = struct {
    monitor: sys.HMONITOR,
    info: MONITORINFO,
    dpi: u32,
};

pub fn fullscreenRestoreRect(rect: RECT, old_work: RECT, new_work: RECT, old_dpi: u32, new_dpi: u32) RECT {
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;
    const scale = old_dpi > 0 and new_dpi > 0;
    return fitRectInWork(
        rect.left + new_work.left - old_work.left,
        rect.top + new_work.top - old_work.top,
        if (scale) sys.MulDiv(width, @intCast(new_dpi), @intCast(old_dpi)) else width,
        if (scale) sys.MulDiv(height, @intCast(new_dpi), @intCast(old_dpi)) else height,
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
    return sys.MulDiv(32, @intCast(@max(dpi, 96)), 96);
}

/// A rect in workspace coordinates (what `GetWindowPlacement` reports for a
/// window without `WS_EX_TOOLWINDOW`) as screen coordinates, for the monitor
/// the window is on. This is the convention `leaveFullscreen` uses.
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
    placement.rcNormalPosition = Surface.screenRectToWorkspace(rect, info);
    placement.showCmd = c.SW_SHOWMINNOACTIVE;
    if (sys.SetWindowPlacement(hwnd, &placement) == 0) return lastError();
}

/// `SetWindowPos` flags for a window placed like the one it was opened from.
/// `window-position-x/y` says where every new window goes, so when its config
/// sets them (`positioned`, `WindowKeeps.position`) the window keeps that
/// place and takes only the size. With a size of its own as well (`sized`,
/// `WindowKeeps.size`) it takes neither: core init already gave it that size
/// where it is, which can be another monitor than the source's, whose work
/// area `newWindowPlacement` fits the rect to. A fullscreen window covers its
/// monitor wherever the config would put it.
pub fn newWindowSetPosFlags(positioned: bool, sized: bool, placed: NewWindowPlacement) UINT {
    var flags: UINT = c.SWP_NOACTIVATE;
    if (!placed.copied and positioned) {
        flags |= c.SWP_NOMOVE;
        if (sized) flags |= c.SWP_NOSIZE;
    }
    return flags;
}

test "win32 a new window placed and sized by its own config takes neither from the window it copies" {
    const cascaded: NewWindowPlacement = .{ .rect = std.mem.zeroes(RECT), .maximize = null };
    const fullscreen: NewWindowPlacement = .{ .rect = std.mem.zeroes(RECT), .maximize = null, .copied = true };
    try std.testing.expectEqual(@as(UINT, c.SWP_NOACTIVATE), newWindowSetPosFlags(false, false, cascaded));
    // A size alone is still moved one cascade step off the source and
    // fitted to its monitor, where the window goes.
    try std.testing.expectEqual(@as(UINT, c.SWP_NOACTIVATE), newWindowSetPosFlags(false, true, cascaded));
    try std.testing.expectEqual(@as(UINT, c.SWP_NOACTIVATE | c.SWP_NOMOVE), newWindowSetPosFlags(true, false, cascaded));
    try std.testing.expectEqual(@as(UINT, c.SWP_NOACTIVATE | c.SWP_NOMOVE | c.SWP_NOSIZE), newWindowSetPosFlags(true, true, cascaded));
    // A fullscreen window covers the source's monitor all the same.
    try std.testing.expectEqual(@as(UINT, c.SWP_NOACTIVATE), newWindowSetPosFlags(true, true, fullscreen));
}

/// A window's outer size, in physical pixels.
pub const WindowSize = struct { width: i32, height: i32 };

/// `rect` with its top-left corner kept and its size `size`.
pub fn rectWithSize(rect: RECT, size: WindowSize) RECT {
    return .{ .left = rect.left, .top = rect.top, .right = rect.left + size.width, .bottom = rect.top + size.height };
}

/// Where a window opened from another one (`new_window`, a profile in a new
/// window) starts.
pub const NewWindowPlacement = struct {
    /// In screen coordinates: the size the source has when it is a normal
    /// window, one cascade step down and right so the new window does not
    /// sit exactly on it, kept inside the source's monitor. Never the rect of
    /// a minimized source, which is not on screen, nor the monitor-sized rect
    /// of a maximized one.
    rect: RECT,
    /// Set when the source is, or restores to, maximized: its placement,
    /// for `maximizeWithPlacement`.
    maximize: ?WINDOWPLACEMENT,
    /// `rect` is the source's own, unchanged: it is fullscreen, so the new
    /// window is too and covers the same monitor.
    copied: bool = false,
};

/// `destination` is the window being placed, if it already exists: it is not
/// one of the windows the new one steps past. `size` is the window's own
/// size (`WindowKeeps.size`), which replaces the source's. A fullscreen window
/// covers the monitor whatever its size.
pub fn newWindowPlacement(app: *App, source: HWND, fullscreen: bool, destination: ?HWND, size: ?WindowSize) !NewWindowPlacement {
    var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
    placement.length = @sizeOf(WINDOWPLACEMENT);
    if (sys.GetWindowPlacement(source, &placement) == 0) return lastError();
    // For a minimized window this is the monitor it was on, not the one its
    // icon is on.
    const monitor = sys.MonitorFromWindow(source, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
    var info: MONITORINFO = std.mem.zeroes(MONITORINFO);
    info.cbSize = @sizeOf(MONITORINFO);
    if (sys.GetMonitorInfoW(monitor, &info) == 0) return lastError();

    // The monitor, not the source's rect, which is a sliver under the
    // taskbar once the source is minimized.
    if (fullscreen) return .{ .rect = info.rcMonitor, .maximize = null, .copied = true };

    const iconic = sys.IsIconic(source) != 0;
    if (restoresMaximized(source, &placement)) {
        // It is maximized again, never minimized with it.
        placement.showCmd = c.SW_MAXIMIZE;
        var normal = workspaceRectToScreen(placement.rcNormalPosition, info);
        if (size) |own| {
            normal = fitRectInWork(normal.left, normal.top, own.width, own.height, info.rcWork);
            placement.rcNormalPosition = Surface.screenRectToWorkspace(normal, info);
        }
        return .{ .rect = normal, .maximize = placement };
    }

    var rect: RECT = undefined;
    if (iconic) {
        rect = workspaceRectToScreen(placement.rcNormalPosition, info);
    } else if (sys.GetWindowRect(source, &rect) == 0) {
        return lastError();
    }
    if (size) |own| rect = rectWithSize(rect, own);
    const step = cascadeStep(sys.GetDpiForWindow(source));
    // One step off the source, and on past any window already there: one
    // window can be the source of several, as when the user goes back to it
    // and opens another, or when Windows does not activate a forwarded one.
    var placed = cascadedRect(rect, step, info.rcWork);
    var steps: u8 = 0;
    while (steps < 8 and app.registry.windowStartsAt(placed, destination)) : (steps += 1) {
        placed = cascadedRect(placed, step, info.rcWork);
    }
    return .{ .rect = placed, .maximize = null };
}

/// `rect` moved `step` down and right, kept inside `work`.
pub fn cascadedRect(rect: RECT, step: i32, work: RECT) RECT {
    return fitRectInWork(rect.left + step, rect.top + step, rect.right - rect.left, rect.bottom - rect.top, work);
}

test "win32 fullscreen restore translates work areas and scales size to fit" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
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
}

/// Whether the window is, or when restored becomes, maximized. A window
/// minimized from maximized restores to maximized. The flag alone says
/// nothing about a window that was restored since: Windows keeps it set on a
/// normal window.
pub fn restoresMaximized(hwnd: HWND, placement: *const WINDOWPLACEMENT) bool {
    return sys.IsZoomed(hwnd) != 0 or
        (sys.IsIconic(hwnd) != 0 and (placement.flags & c.WPF_RESTORETOMAXIMIZED) != 0);
}

pub fn toggleMaximize(self: *Surface) void {
    const hwnd = self.windowHwnd() orelse return;
    if (self.fullscreen) return;
    _ = sys.ShowWindow(hwnd, if (sys.IsZoomed(hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE);
}

pub fn toggleBackgroundOpacity(self: *Surface) !bool {
    if (self.background_opacity_default >= 0.999) return false;
    self.background_opacity_force_opaque = !self.background_opacity_force_opaque;
    try self.applyBackgroundOpacity();
    return true;
}

pub fn toggleFullscreen(self: *Surface, mode: apprt.action.Fullscreen) !void {
    _ = mode;
    if (self.fullscreen) {
        try self.leaveFullscreen();
        return;
    }
    try self.enterFullscreen();
}

pub fn toggleDecorations(self: *Surface) !void {
    try self.setDecorationsVisible(!self.decorations_visible);
    self.decorations_visible_overridden = true;
}

pub fn setInitialSize(self: *Surface, size: apprt.action.InitialSize) !void {
    self.default_client_size = .{
        .width = @intCast(size.width),
        .height = @intCast(size.height),
    };
    if (self.fullscreen or
        (if (self.windowHwnd()) |hwnd| sys.IsZoomed(hwnd) != 0 else false) or
        !shouldResizeHostForInitialSize(self.hostSurfaceCount())) return;
    const client_size = scaleInitialClientSize(self.default_client_size.?, self.content_scale);
    try self.resizeClientArea(client_size.width, client_size.height);
}

pub fn hostSurfaceCount(self: *const Surface) usize {
    const host = self.host orelse return 1;
    var count: usize = 0;
    for (host.tabs.items) |*tab| count += tab.leafCount();
    return count;
}

pub fn resetWindowSize(self: *Surface) !void {
    const size = self.default_client_size orelse return;
    if (self.fullscreen) try self.leaveFullscreen();
    if (self.windowHwnd()) |hwnd| _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
    const client_size = scaleInitialClientSize(size, self.content_scale);
    try self.resizeClientArea(client_size.width, client_size.height);
}

pub fn setSizeLimit(self: *Surface, limit: apprt.action.SizeLimit) void {
    if (sizeLimitEquals(self.size_limit, limit)) return;
    self.size_limit = limit;
    if (self.host != null) {
        self.refreshSharedWindowFrame();
        return;
    }
    const hwnd = self.windowHwnd() orelse return;
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

pub fn setFloatWindow(self: *Surface, mode: apprt.action.FloatWindow) !void {
    self.topmost = switch (mode) {
        .on => true,
        .off => false,
        .toggle => !self.topmost,
    };
    try self.applyTopmost();
}

/// Puts a new top-level window in the state `maximize` and `fullscreen`
/// ask for (`WindowStart`), on top of the state it already has: a window
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
pub fn applyWindowStart(self: *Surface, start: WindowStart) void {
    const hwnd = self.windowHwnd() orelse return;
    if (start.fullscreen and !self.fullscreen) {
        // A launcher's show command (`start /min`, a shortcut set to Run:
        // Minimized or Maximized) goes to the first framed top-level
        // window the process calls ShowWindow on. A popup's show does not
        // take it, so the next framed window would: Settings, or a window
        // opened from this one after it left fullscreen, would open
        // minimized. SW_HIDE takes it while this window is still framed,
        // and shows nothing.
        if (sys.IsWindowVisible(hwnd) == 0) _ = sys.ShowWindow(hwnd, c.SW_HIDE);
        self.enterFullscreen() catch |err| {
            log.warn("win32 startup fullscreen failed err={}", .{err});
        };
    }
    if (start.maximize) {
        if (self.fullscreen) {
            // `leaveFullscreen` maximizes a window whose placement says
            // it was maximized.
            self.restore_placement.showCmd = c.SW_MAXIMIZE;
        } else if (sys.IsZoomed(hwnd) == 0) {
            _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
        }
    }
}

// Candidate workaround: extend only into a row or column that intersects no
// other monitor. This is geometry, not proof that the driver stays composed.
const FullscreenEdges = struct {
    monitor: RECT,
    bottom: bool = true,
    right: bool = true,
    top: bool = true,
    left: bool = true,

    fn consider(self: *FullscreenEdges, other: RECT) void {
        const m = self.monitor;
        if (std.meta.eql(m, other)) return;
        const horizontal = other.left < m.right and other.right > m.left;
        const vertical = other.top < m.bottom and other.bottom > m.top;
        if (horizontal and other.top <= m.bottom and other.bottom > m.bottom) self.bottom = false;
        if (vertical and other.left <= m.right and other.right > m.right) self.right = false;
        if (horizontal and other.top < m.top and other.bottom >= m.top) self.top = false;
        if (vertical and other.left < m.left and other.right >= m.left) self.left = false;
    }

    fn extended(self: FullscreenEdges) ?RECT {
        var rect = self.monitor;
        // Fail closed at the integer limits, including unusual virtual-display
        // coordinates; never overflow while applying optional geometry.
        if (self.bottom and rect.bottom < std.math.maxInt(i32)) {
            rect.bottom += 1;
        } else if (self.right and rect.right < std.math.maxInt(i32)) {
            rect.right += 1;
        } else if (self.top and rect.top > std.math.minInt(i32)) {
            rect.top -= 1;
        } else if (self.left and rect.left > std.math.minInt(i32)) {
            rect.left -= 1;
        } else return null;
        return rect;
    }
};

fn candidateFullscreenRect(monitor: RECT) ?RECT {
    const Collector = struct {
        fn visit(_: sys.HMONITOR, _: win32_types.HDC, rect: *RECT, data: LPARAM) callconv(.winapi) win32_types.BOOL {
            const edges: *FullscreenEdges = @ptrFromInt(@as(usize, @bitCast(data)));
            edges.consider(rect.*);
            return 1;
        }
    };
    var edges: FullscreenEdges = .{ .monitor = monitor };
    if (sys.EnumDisplayMonitors(null, null, Collector.visit, @bitCast(@intFromPtr(&edges))) == 0) return null;
    return edges.extended();
}

test "win32 fullscreen candidate chooses an unoccupied edge" {
    const m: RECT = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 };
    var edges: FullscreenEdges = .{ .monitor = m };
    // A corner touch or a gap leaves the whole extra row available.
    edges.consider(.{ .left = 100, .top = 100, .right = 200, .bottom = 200 });
    edges.consider(.{ .left = 0, .top = 101, .right = 100, .bottom = 200 });
    try std.testing.expectEqualDeep(RECT{ .left = 0, .top = 0, .right = 100, .bottom = 101 }, edges.extended().?);
    edges.consider(.{ .left = 0, .top = 100, .right = 100, .bottom = 200 });
    try std.testing.expectEqualDeep(RECT{ .left = 0, .top = 0, .right = 101, .bottom = 100 }, edges.extended().?);
    edges.consider(.{ .left = 100, .top = 25, .right = 200, .bottom = 75 });
    try std.testing.expectEqualDeep(RECT{ .left = 0, .top = -1, .right = 100, .bottom = 100 }, edges.extended().?);
    edges.consider(.{ .left = 0, .top = -100, .right = 100, .bottom = 0 });
    try std.testing.expectEqualDeep(RECT{ .left = -1, .top = 0, .right = 100, .bottom = 100 }, edges.extended().?);
    edges.consider(.{ .left = -100, .top = 0, .right = 0, .bottom = 100 });
    try std.testing.expect(edges.extended() == null);
}

fn fullscreenCandidateWanted(tab_bar_shown: bool, core_initialized: bool, opengl_active: bool) bool {
    return !tab_bar_shown and core_initialized and opengl_active;
}

test "win32 fullscreen candidate gate requires hidden tabs and initialized OpenGL" {
    const cases = [_]struct { tabs: bool, core: bool, gl: bool, expected: bool }{
        .{ .tabs = false, .core = false, .gl = false, .expected = false },
        .{ .tabs = false, .core = false, .gl = true, .expected = false },
        .{ .tabs = false, .core = true, .gl = false, .expected = false },
        .{ .tabs = false, .core = true, .gl = true, .expected = true },
        .{ .tabs = true, .core = false, .gl = false, .expected = false },
        .{ .tabs = true, .core = false, .gl = true, .expected = false },
        .{ .tabs = true, .core = true, .gl = false, .expected = false },
        .{ .tabs = true, .core = true, .gl = true, .expected = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, fullscreenCandidateWanted(case.tabs, case.core, case.gl));
}

fn surfaceWantsFullscreenCandidate(self: *const Surface) bool {
    const host = self.host orelse return false;
    // Do not read the uninitialized core. The renderer may have fallen back
    // from the configured backend, so check the active backend instead.
    const opengl_active = if (!self.core_initialized) false else if (comptime build_config.d3d11)
        self.core_surface.renderer.opengl.load(.acquire) != null
    else
        true;
    return fullscreenCandidateWanted(host.shouldShowTabBar(), self.core_initialized, opengl_active);
}

test "win32 fullscreen candidate surface gate handles absent and uninitialized core" {
    var app = placementTestApp();
    var host: Host = .{ .app = &app, .id = 1 };
    var surface: Surface = .{ .app = &app, .host = null, .core_initialized = false };
    try std.testing.expect(!surfaceWantsFullscreenCandidate(&surface));
    surface.host = &host;
    try std.testing.expect(!surfaceWantsFullscreenCandidate(&surface));
}

fn fullscreenRectForCandidate(screen: RECT, candidate: bool) RECT {
    if (!candidate) return screen;
    if (candidateFullscreenRect(screen)) |extended| return extended;
    log.debug("fullscreen composition candidate: no free monitor edge or monitor enumeration failed", .{});
    return screen;
}

pub fn enterFullscreen(self: *Surface) !void {
    return enterFullscreenWithCandidate(self, surfaceWantsFullscreenCandidate(self));
}

fn enterFullscreenWithCandidate(self: *Surface, candidate: bool) !void {
    const hwnd = self.windowHwnd() orelse return;
    // A minimized window comes back first. SetWindowPos would move only
    // its icon, and it would return from the taskbar as a popup at its
    // normal rect. A restored session's first window is minimized here
    // under a minimized launch (`applyRestoredWindowPlacement`).
    if (sys.IsIconic(hwnd) != 0) _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
    // Captured before the style write below, which drops WS_MAXIMIZE:
    // the monitor-sized SetWindowPos after it would otherwise land on a
    // normal window and overwrite its normal rect.
    self.restore_placement.length = @sizeOf(WINDOWPLACEMENT);
    if (sys.GetWindowPlacement(hwnd, &self.restore_placement) == 0 or
        sys.GetWindowRect(hwnd, &self.restore_rect) == 0) return lastError();
    const monitor = try windowMonitor(hwnd);
    self.restore_monitor = monitor;
    self.fullscreen = true;
    try self.applyWindowStyle();

    const screen = fullscreenRectForCandidate(monitor.info.rcMonitor, candidate);
    if (sys.SetWindowPos(
        hwnd,
        if (self.topmost) HWND_TOPMOST else null,
        screen.left,
        screen.top,
        screen.right - screen.left,
        screen.bottom - screen.top,
        c.SWP_FRAMECHANGED | c.SWP_NOACTIVATE,
    ) == 0) {
        return lastError();
    }
}

/// The window leaving fullscreen gives back: the one it was when it
/// entered fullscreen, moved to the monitor it is on now.
pub const FullscreenReturn = struct {
    /// Its rect, in screen coordinates.
    rect: RECT,
    /// Its placement. `rcNormalPosition` is in the workspace coordinates
    /// of `monitor`.
    placement: WINDOWPLACEMENT,
    /// The monitor it is on now, if entering fullscreen recorded one.
    monitor: ?MONITORINFO,
};

pub fn fullscreenReturn(self: *const Surface, hwnd: HWND) !FullscreenReturn {
    var back: FullscreenReturn = .{ .rect = self.restore_rect, .placement = self.restore_placement, .monitor = null };
    const source = self.restore_monitor orelse return back;
    const target = try windowMonitor(hwnd);
    back.monitor = target.info;
    if (target.monitor != source.monitor or target.dpi != source.dpi) {
        back.rect = fullscreenRestoreRect(back.rect, source.info.rcWork, target.info.rcWork, source.dpi, target.dpi);
        // WINDOWPLACEMENT uses workspace coordinates for a normal
        // host (no WS_EX_TOOLWINDOW). Convert to screen coordinates
        // before the work-area translation, and back afterwards.
        const normal = workspaceRectToScreen(back.placement.rcNormalPosition, source.info);
        back.placement.rcNormalPosition = screenRectToWorkspace(
            fullscreenRestoreRect(normal, source.info.rcWork, target.info.rcWork, source.dpi, target.dpi),
            target.info,
        );
    }
    return back;
}

pub fn leaveFullscreen(self: *Surface) !void {
    const hwnd = self.windowHwnd() orelse return;
    const back = try self.fullscreenReturn(hwnd);
    const rect = back.rect;
    const placement = back.placement;
    self.fullscreen = false;
    try self.applyWindowStyle();

    // A maximized window is maximized again and given back the normal
    // rect it had before. Moving it to its maximized rect first, while
    // it was a normal window, made that rect its normal rect, so a
    // later restore kept it maximized-size. Any other window returns to
    // its exact rect: the placement of a snapped window holds its
    // pre-snap rect.
    if (placement.showCmd == c.SW_MAXIMIZE) {
        return maximizeWithPlacement(hwnd, &placement);
    }
    if (sys.SetWindowPos(
        hwnd,
        if (self.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
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
pub fn windowMonitor(hwnd: HWND) !FullscreenMonitor {
    const monitor = sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
    var info: MONITORINFO = std.mem.zeroes(MONITORINFO);
    info.cbSize = @sizeOf(MONITORINFO);
    if (sys.GetMonitorInfoW(monitor, &info) == 0) return lastError();
    return .{ .monitor = monitor, .info = info, .dpi = sys.GetDpiForWindow(hwnd) };
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

pub fn setDecorationsVisible(self: *Surface, visible: bool) !void {
    if (self.decorations_visible == visible) return;

    const previous_visible = self.decorations_visible;
    const host = self.host;
    const should_refresh_host = shouldPropagateSharedHostWindowState(self);
    const used_integrated_titlebar_before = if (should_refresh_host and host != null)
        host.?.usingIntegratedTitlebar()
    else
        false;

    self.decorations_visible = visible;

    if (!should_refresh_host) return;
    self.applyWindowStyle() catch |err| {
        self.rollbackDecorationsVisible(previous_visible, host, false);
        return err;
    };

    if (host) |value| {
        const integrated_titlebar_changed = used_integrated_titlebar_before != value.usingIntegratedTitlebar();
        if (integrated_titlebar_changed) {
            // Switching between stock and app-owned caption chrome can
            // strand hover state until the next NC leave.
            value.handleNcMouseLeave();
        }
        value.layout() catch |err| {
            self.rollbackDecorationsVisible(previous_visible, host, integrated_titlebar_changed);
            return err;
        };
        value.refreshChrome() catch |err| {
            self.rollbackDecorationsVisible(previous_visible, host, integrated_titlebar_changed);
            return err;
        };
        value.cached_decorations_visible = visible;
        value.scheduleCaptionUiaSync();
    }
}

pub fn rollbackDecorationsVisible(
    self: *Surface,
    previous_visible: bool,
    host: ?*Host,
    integrated_titlebar_changed: bool,
) void {
    self.decorations_visible = previous_visible;
    self.applyWindowStyle() catch |err| {
        log.warn("win32 decoration rollback style update failed err={}", .{err});
    };

    if (host) |value| {
        value.cached_decorations_visible = previous_visible;
        if (integrated_titlebar_changed) value.handleNcMouseLeave();
        value.layout() catch |err| {
            log.warn("win32 decoration rollback layout failed err={}", .{err});
        };
        value.refreshChrome() catch |err| {
            log.warn("win32 decoration rollback chrome refresh failed err={}", .{err});
        };
        value.scheduleCaptionUiaSync();
    }
}

pub fn resizeClientArea(self: *Surface, client_width: u32, client_height: u32) !void {
    const hwnd = self.windowHwnd() orelse return;
    const hosted = self.host != null;
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

    if (hosted) {
        const host = self.host orelse unreachable;
        try host.layout();
        host.syncVisibleSurfaceCoreSizesFromClientRects();
    } else {
        self.syncCoreSizeFromClientRect();
    }
}

/// Takes the window state of `source`, but what `keeps` names stays this
/// surface's own.
pub fn copySharedWindowStateFrom(self: *Surface, source: *const Surface, keeps: WindowKeeps) void {
    if (!keeps.decoration) {
        self.decorations_visible = source.decorations_visible;
        self.decorations_visible_overridden = source.decorations_visible_overridden;
    }
    if (self.host) |host| {
        if (host.activeSurface() == self) {
            host.cached_decorations_visible = self.decorations_visible;
        }
    }
    self.fullscreen = source.fullscreen;
    self.topmost = source.topmost;
    self.restore_rect = source.restore_rect;
    self.restore_placement = source.restore_placement;
    self.restore_monitor = source.restore_monitor;
    if (!keeps.size) self.default_client_size = source.default_client_size;
    self.cell_size_pixels = source.cell_size_pixels;
    if (!keeps.background_opacity) {
        self.background_opacity_default = source.background_opacity_default;
        self.background_opacity_force_opaque = source.background_opacity_force_opaque;
    }
    self.size_limit = source.size_limit;
}

pub fn activeSharedHostWindowHwnd(self: *const Surface) ?HWND {
    const host = self.host orelse return self.hwnd;
    if (host.activeSurface() != self) return null;
    return host.hwnd;
}

pub fn syncSharedHostWindowState(self: *Surface, previous_surface: ?*const Surface) void {
    const host = self.host orelse return;
    if (host.activeSurface() != self) return;

    if (previous_surface == null or
        !sharedHostWindowFrameStateEquals(previous_surface.?, self))
    {
        self.refreshSharedWindowFrame();
    }
    if (previous_surface == null or
        !sharedHostWindowTopmostEquals(previous_surface.?, self))
    {
        self.applyTopmost() catch |err| {
            log.warn("win32 shared host topmost sync failed err={}", .{err});
        };
    }
    if (previous_surface == null or
        !sharedHostWindowOpacityEquals(previous_surface.?, self))
    {
        self.applyBackgroundOpacity() catch |err| {
            log.warn("win32 shared host opacity sync failed err={}", .{err});
        };
    }
}

pub fn refreshSharedWindowFrame(self: *Surface) void {
    const hwnd = self.windowHwnd() orelse return;
    const host = self.host orelse return;
    if (host.activeSurface() != self) return;
    if (self.keepsFrameUndecorated()) {
        win32_theme.WindowThemeAdapter.setHostBorderVisible(hwnd, self.decorations_visible);
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

/// Gives this surface's window the state of `source`'s, keeping what
/// `keeps` names.
pub fn inheritWindowStateFrom(self: *Surface, source: *const Surface, keeps: WindowKeeps) !void {
    return inheritWindowStateFromWithCandidate(self, source, keeps, null);
}

fn inheritWindowStateFromWithCandidate(self: *Surface, source: *const Surface, keeps: WindowKeeps, candidate: ?bool) !void {
    // The size core init gave the window, before it takes the source's
    // state.
    var own_size: ?WindowSize = null;
    if (keeps.size) if (self.windowHwnd()) |hwnd| {
        var rect: RECT = undefined;
        if (sys.GetWindowRect(hwnd, &rect) == 0) return lastError();
        own_size = .{ .width = rect.right - rect.left, .height = rect.bottom - rect.top };
    };
    self.copySharedWindowStateFrom(source, keeps);
    if (own_size) |size| if (self.fullscreen) if (self.windowHwnd()) |hwnd| {
        // It leaves fullscreen to that size, where the source would, and
        // inside the work area there, as a window opened from a normal
        // or maximized source is. The source's return is in the pixels
        // of the monitor it entered fullscreen on, which leaving scales
        // from, and `size` is in this window's, on the monitor the
        // source covers now. So the return is first taken as leaving
        // fullscreen here gives it, then sized and fitted here, and
        // leaving does not scale `size` too.
        const back = try self.fullscreenReturn(hwnd);
        const here = try windowMonitor(hwnd);
        const work = here.info.rcWork;
        self.restore_monitor = here;
        self.restore_rect = fitRectInWork(back.rect.left, back.rect.top, size.width, size.height, work);
        self.restore_placement = back.placement;
        const normal = workspaceRectToScreen(back.placement.rcNormalPosition, here.info);
        self.restore_placement.rcNormalPosition = screenRectToWorkspace(
            fitRectInWork(normal.left, normal.top, size.width, size.height, work),
            here.info,
        );
    };

    try self.applyWindowStyle();
    try self.applyTopmost();
    try self.applyBackgroundOpacity();

    const hwnd = self.windowHwnd() orelse return;
    const source_hwnd = source.windowHwnd() orelse return;
    var placed = try newWindowPlacement(self.app, source_hwnd, source.fullscreen, hwnd, own_size);
    if (source.fullscreen and hwnd != source_hwnd) {
        placed.rect = fullscreenRectForCandidate(placed.rect, candidate orelse surfaceWantsFullscreenCandidate(self));
    }
    var flags = newWindowSetPosFlags(keeps.position, own_size != null, placed) | c.SWP_FRAMECHANGED;
    // Another tab of the source's own window is already where it goes.
    if (hwnd == source_hwnd) flags |= c.SWP_NOMOVE | c.SWP_NOSIZE;
    if (sys.SetWindowPos(
        hwnd,
        if (self.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
        placed.rect.left,
        placed.rect.top,
        placed.rect.right - placed.rect.left,
        placed.rect.bottom - placed.rect.top,
        flags,
    ) == 0) {
        return lastError();
    }

    if (!self.fullscreen) {
        if (placed.maximize) |*placement| {
            // The source's normal rect, not the monitor-sized one.
            try maximizeWithPlacement(hwnd, placement);
        } else {
            _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
        }
    }
}

pub fn updateMinMaxInfo(self: *Surface, lParam: LPARAM) void {
    if (self.size_limit.min_width == 0 and
        self.size_limit.min_height == 0 and
        self.size_limit.max_width == 0 and
        self.size_limit.max_height == 0) return;

    const info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const hwnd = self.windowHwnd() orelse return;
    var client_rect: RECT = undefined;
    var window_rect: RECT = undefined;
    if (sys.GetClientRect(hwnd, &client_rect) == 0) return;
    if (sys.GetWindowRect(hwnd, &window_rect) == 0) return;

    const frame_width = (window_rect.right - window_rect.left) - (client_rect.right - client_rect.left);
    const frame_height = (window_rect.bottom - window_rect.top) - (client_rect.bottom - client_rect.top);

    if (self.size_limit.min_width > 0) {
        info.ptMinTrackSize.x = @as(i32, @intCast(self.size_limit.min_width)) + frame_width;
    }
    if (self.size_limit.min_height > 0) {
        info.ptMinTrackSize.y = @as(i32, @intCast(self.size_limit.min_height)) + frame_height;
    }
    if (self.size_limit.max_width > 0) {
        info.ptMaxTrackSize.x = @as(i32, @intCast(self.size_limit.max_width)) + frame_width;
    }
    if (self.size_limit.max_height > 0) {
        info.ptMaxTrackSize.y = @as(i32, @intCast(self.size_limit.max_height)) + frame_height;
    }
}

/// `undecoratedKeepsFrame` for this surface's host window. The quick
/// terminal flag is the host's: a split or tab opened inside the quick
/// terminal is an ordinary surface in the quick terminal's window.
pub fn keepsFrameUndecorated(self: *const Surface) bool {
    const quick_terminal = if (self.host) |host| host.quick_terminal else false;
    return undecoratedKeepsFrame(self.app.os_build, quick_terminal);
}

pub fn applyWindowStyle(self: *Surface) !void {
    const hwnd = self.activeSharedHostWindowHwnd() orelse return;
    const keeps_frame = self.keepsFrameUndecorated();
    const current: u32 = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE))));
    // The write keeps the window's own visibility. Forcing WS_VISIBLE on
    // showed a hidden quick terminal on a config reload without its
    // surface knowing (see `App.toggleQuickTerminal`).
    const style = (effectiveHostWindowStyle(
        self.decorations_visible or keeps_frame,
        self.fullscreen,
        self.host != null,
    ) & ~@as(u32, c.WS_VISIBLE)) | (current & c.WS_VISIBLE);
    // On Windows 11 a decoration toggle keeps the frame, so the style is
    // already right, and writing it anyway would drop WS_MAXIMIZE: a
    // maximized window left un-maximized in its maximized rect.
    const state_bits: u32 = c.WS_VISIBLE | c.WS_MAXIMIZE | c.WS_MINIMIZE | c.WS_CLIPSIBLINGS;
    if ((current & ~state_bits) != (style & ~state_bits)) {
        _ = sys.SetWindowLongPtrW(hwnd, c.GWL_STYLE, @bitCast(@as(isize, @intCast(style))));
    }
    if (keeps_frame) win32_theme.WindowThemeAdapter.setHostBorderVisible(hwnd, self.decorations_visible);
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

/// Give a brand-new host window its `background-opacity` before the
/// window is shown for the first time.
///
/// On Win32 the host window's layered alpha is the only mechanism that
/// makes `background-opacity` visible: DWM discards the GL child's
/// framebuffer alpha and nothing here opts into
/// `DwmExtendFrameIntoClientArea` or `WS_EX_NOREDIRECTIONBITMAP`.
/// `App.createHost` passes `dwExStyle = 0`, and the only callers of
/// `applyBackgroundOpacity` used to be config reload, tab/window
/// activation and `inheritWindowStateFrom` — none of which a
/// cold-start window reaches — so window 1 stayed fully opaque while
/// every later window faded (issue #234).
///
/// Only `Surface.init`'s `activate_during_init` branch may call this: it
/// is the one path that owns a brand-new host window. A same-host tab or
/// split inherits an HWND whose alpha is already correct, and for a split
/// `tab.focused` already points at the new surface, so calling this there
/// would write to the live window rather than no-op through
/// `activeSharedHostWindowHwnd`.
///
/// The unit tests cover this function against a live HWND, but nothing
/// unit-testable reaches `Surface.init` (it needs a GL context and a real
/// `CoreSurface`), so neither the call site nor its ordering against the
/// first show is machine-checked. Both were verified by running the app
/// and reading back `GWL_EXSTYLE` / `GetLayeredWindowAttributes`.
///
/// Failure is logged rather than propagated: a window that could not be
/// layered is still a usable window.
pub fn applyInitialBackgroundOpacity(self: *Surface, clone_state_from: ?*const Surface) void {
    if (clone_state_from) |source| {
        // `inheritWindowStateFrom` copies the source's opacity wholesale,
        // but it only runs after the clone is already on screen. Seed it
        // here so a clone of a window the user forced opaque with
        // `toggle_background_opacity` is never briefly shown faded.
        self.background_opacity_default = source.background_opacity_default;
        self.background_opacity_force_opaque = source.background_opacity_force_opaque;
    }
    self.applyBackgroundOpacity() catch |err| {
        log.warn("win32 initial background opacity failed err={}", .{err});
    };
}

pub fn applyBackgroundOpacity(self: *Surface) !void {
    const hwnd = self.activeSharedHostWindowHwnd() orelse return;
    const opacity = effectiveBackgroundOpacity(
        self.background_opacity_default,
        self.background_opacity_force_opaque,
    );
    const ex_style_raw = sys.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
    var ex_style: u32 = @intCast(@as(usize, @bitCast(ex_style_raw)));

    if (opacity >= 0.999) {
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
    }

    if ((ex_style & c.WS_EX_LAYERED) == 0) {
        ex_style |= c.WS_EX_LAYERED;
        _ = sys.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, @bitCast(@as(isize, @intCast(ex_style))));
    }

    if (sys.SetLayeredWindowAttributes(hwnd, 0, alphaByteForOpacity(opacity), c.LWA_ALPHA) == 0) {
        return lastError();
    }
}

pub fn applyTopmost(self: *Surface) !void {
    const hwnd = self.activeSharedHostWindowHwnd() orelse return;
    if (sys.SetWindowPos(
        hwnd,
        if (self.topmost) HWND_TOPMOST else HWND_NOTOPMOST,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    ) == 0) {
        return lastError();
    }
}

test "win32 decorationsVisibleForConfig only hides none" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(decorationsVisibleForConfig(.auto));
    try std.testing.expect(decorationsVisibleForConfig(.client));
    try std.testing.expect(decorationsVisibleForConfig(.server));
    try std.testing.expect(!decorationsVisibleForConfig(.none));
}

test "win32 startupHostWindowStyle respects decoration and fullscreen frame state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(
        effectiveHostWindowStyle(true, false, true) & ~@as(u32, c.WS_VISIBLE),
        startupHostWindowStyle(true, false),
    );
    try std.testing.expectEqual(
        effectiveHostWindowStyle(false, false, true) & ~@as(u32, c.WS_VISIBLE),
        startupHostWindowStyle(false, false),
    );
    try std.testing.expectEqual(
        effectiveHostWindowStyle(false, true, true) & ~@as(u32, c.WS_VISIBLE),
        startupHostWindowStyle(false, true),
    );
    try std.testing.expect((startupHostWindowStyle(true, false) & c.WS_CLIPCHILDREN) != 0);
    try std.testing.expect((startupHostWindowStyle(true, false) & c.WS_VISIBLE) == 0);
}

test "win32 createdHostWindowStyleCorrection takes back only what CreateWindowEx added" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Measured: `CreateWindowEx` answers the undecorated request with
    // 0x06C00000, i.e. the request plus WS_CAPTION and WS_CLIPSIBLINGS.
    const undecorated = startupHostWindowStyle(false, false);
    try std.testing.expectEqual(
        @as(?u32, undecorated),
        createdHostWindowStyleCorrection(undecorated, undecorated | c.WS_CAPTION | c.WS_CLIPSIBLINGS),
    );
    try std.testing.expectEqual(@as(?u32, null), createdHostWindowStyleCorrection(undecorated, undecorated));

    // Decorated and fullscreen requests come back with only the
    // WS_CLIPSIBLINGS every top-level window carries, and stay untouched.
    const decorated = startupHostWindowStyle(true, false);
    try std.testing.expectEqual(@as(?u32, null), createdHostWindowStyleCorrection(decorated, decorated | c.WS_CLIPSIBLINGS));
    const fullscreen = startupHostWindowStyle(false, true);
    try std.testing.expectEqual(@as(?u32, null), createdHostWindowStyleCorrection(fullscreen, fullscreen | c.WS_CLIPSIBLINGS));
}

test "win32 restoreRequestedHostWindowStyle removes the caption CreateWindowEx adds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Never shown, so it reaches neither the desktop nor the taskbar.
    const requested = startupHostWindowStyle(false, false);
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

test "win32 initialDecorationsVisible follows startup source" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var config: configpkg.Config = .{};

    config.@"window-decoration" = .none;
    try std.testing.expect(!Surface.initialDecorationsVisible(&config, .{}));

    config.@"window-decoration" = .auto;
    try std.testing.expect(Surface.initialDecorationsVisible(&config, .{}));

    var source: Surface = undefined;
    source.host = null;
    source.decorations_visible = false;
    try std.testing.expect(!Surface.initialDecorationsVisible(
        &config,
        .{ .clone_state_from = &source },
    ));

    source.decorations_visible = true;
    try std.testing.expect(Surface.initialDecorationsVisible(
        &config,
        .{
            .host_id = 7,
            .clone_state_from = &source,
        },
    ));

    // A forwarded `--window-decoration` (already applied to `config`) wins
    // over the source's.
    config.@"window-decoration" = .none;
    try std.testing.expect(!Surface.initialDecorationsVisible(
        &config,
        .{ .clone_state_from = &source, .forwarded_arguments = &.{"--window-decoration=none"} },
    ));
    try std.testing.expect(Surface.initialDecorationsVisible(&config, .{ .clone_state_from = &source }));

    config.@"window-decoration" = .none;
    try std.testing.expect(!Surface.initialDecorationsVisible(
        &config,
        .{ .host_id = 7 },
    ));

    config.@"window-decoration" = .auto;
    try std.testing.expect(Surface.initialDecorationsVisible(
        &config,
        .{ .host_id = 7 },
    ));
}

test "win32 effectiveHostWindowStyle preserves clipchildren for hosted surfaces" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect((effectiveHostWindowStyle(true, false, true) & c.WS_CLIPCHILDREN) != 0);
    try std.testing.expect((effectiveHostWindowStyle(false, false, true) & c.WS_CLIPCHILDREN) != 0);
    try std.testing.expect((effectiveHostWindowStyle(true, true, true) & c.WS_CLIPCHILDREN) != 0);
    try std.testing.expect((effectiveHostWindowStyle(true, false, false) & c.WS_CLIPCHILDREN) == 0);
}

test "win32 sharesHostWindowState only for same-host clones" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(sharesHostWindowState(7, 7));
    try std.testing.expect(!sharesHostWindowState(7, 8));
    try std.testing.expect(!sharesHostWindowState(7, null));
    try std.testing.expect(!sharesHostWindowState(null, 7));
}

test "win32 copySharedWindowStateFrom clones host-scoped window fields" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var source: Surface = undefined;
    source.decorations_visible = false;
    source.decorations_visible_overridden = true;
    source.fullscreen = true;
    source.topmost = true;
    source.restore_rect = .{ .left = 10, .top = 20, .right = 30, .bottom = 40 };
    source.restore_monitor = .{ .monitor = @ptrFromInt(1), .info = std.mem.zeroes(MONITORINFO), .dpi = 144 };
    source.restore_placement = std.mem.zeroes(WINDOWPLACEMENT);
    source.restore_placement.showCmd = c.SW_MAXIMIZE;
    source.restore_placement.rcNormalPosition = .{ .left = 50, .top = 60, .right = 70, .bottom = 80 };
    source.default_client_size = .{ .width = 123, .height = 456 };
    source.cell_size_pixels = .{ .width = 9, .height = 21 };
    source.background_opacity_default = 0.75;
    source.background_opacity_force_opaque = true;
    source.size_limit = .{
        .min_width = 111,
        .min_height = 222,
        .max_width = 333,
        .max_height = 444,
    };
    var dest: Surface = undefined;
    dest.host = null;

    dest.copySharedWindowStateFrom(&source, .{});

    try std.testing.expectEqual(source.decorations_visible, dest.decorations_visible);
    try std.testing.expectEqual(source.decorations_visible_overridden, dest.decorations_visible_overridden);
    try std.testing.expectEqual(source.fullscreen, dest.fullscreen);
    try std.testing.expectEqual(source.topmost, dest.topmost);
    try std.testing.expectEqualDeep(source.restore_rect, dest.restore_rect);
    try std.testing.expectEqualDeep(source.restore_placement, dest.restore_placement);
    try std.testing.expectEqualDeep(source.restore_monitor, dest.restore_monitor);
    try std.testing.expectEqualDeep(source.default_client_size, dest.default_client_size);
    try std.testing.expectEqualDeep(source.cell_size_pixels, dest.cell_size_pixels);
    try std.testing.expectEqual(source.background_opacity_default, dest.background_opacity_default);
    try std.testing.expectEqual(source.background_opacity_force_opaque, dest.background_opacity_force_opaque);
    try std.testing.expect(sizeLimitEquals(source.size_limit, dest.size_limit));

    // What a forwarded launch set stays the window's own; the state and the
    // rest are still the source's.
    var own: Surface = undefined;
    own.host = null;
    own.decorations_visible = true;
    own.decorations_visible_overridden = false;
    own.default_client_size = .{ .width = 7, .height = 8 };
    own.background_opacity_default = 0.5;
    own.background_opacity_force_opaque = false;
    own.copySharedWindowStateFrom(&source, .{ .position = true, .size = true, .decoration = true, .background_opacity = true });
    try std.testing.expect(own.decorations_visible and !own.decorations_visible_overridden);
    try std.testing.expectEqualDeep(@as(?apprt.SurfaceSize, .{ .width = 7, .height = 8 }), own.default_client_size);
    try std.testing.expectEqual(@as(f64, 0.5), own.background_opacity_default);
    try std.testing.expect(!own.background_opacity_force_opaque);
    try std.testing.expectEqual(source.fullscreen, own.fullscreen);
    try std.testing.expectEqualDeep(source.restore_placement, own.restore_placement);
    try std.testing.expect(sizeLimitEquals(source.size_limit, own.size_limit));
}

test "win32 leaveFullscreen and new_window keep the normal rect of a maximized window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Maximizing shows a window, so these live on a desktop of their own and
    // never reach the user's.
    try runOnHiddenDesktop(struct {
        fn window(app: *App, origin: i32) !Surface {
            var surface: Surface = undefined;
            surface.app = app;
            surface.host = null;
            surface.hwnd = sys.CreateWindowExW(
                0,
                prompt_label_class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                WS_OVERLAPPEDWINDOW,
                origin,
                origin,
                640,
                480,
                null,
                null,
                sys.GetModuleHandleW(null),
                null,
            ) orelse return lastError();
            surface.decorations_visible = true;
            surface.fullscreen = false;
            surface.topmost = false;
            surface.background_opacity_default = 1.0;
            surface.background_opacity_force_opaque = false;
            return surface;
        }

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
            var surface = try window(&app, 100);
            const hwnd = surface.hwnd.?;
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
                const monitor = try windowMonitor(hwnd);
                try enterFullscreenWithCandidate(&surface, true);
                var fullscreen_rect: RECT = undefined;
                try std.testing.expect(sys.GetWindowRect(hwnd, &fullscreen_rect) != 0);
                try std.testing.expectEqualDeep(candidateFullscreenRect(monitor.info.rcMonitor) orelse monitor.info.rcMonitor, fullscreen_rect);
                var client: RECT = undefined;
                try std.testing.expect(sys.GetClientRect(hwnd, &client) != 0);
                try std.testing.expectEqual(fullscreen_rect.right - fullscreen_rect.left, client.right - client.left);
                try std.testing.expectEqual(fullscreen_rect.bottom - fullscreen_rect.top, client.bottom - client.top);
                // A single unzoomed pane, without search or chrome, occupies
                // the entire fullscreen host client, including the extra pixel.
                const layout = @import("../win32_layout.zig");
                const pane = layout.splitSurfacePlacement(
                    .{ .left = 0, .top = 0, .right = client.right, .bottom = client.bottom },
                    .{ .x = 0, .y = 0, .width = 1, .height = 1 },
                    false,
                    false,
                    0,
                );
                try std.testing.expectEqual(client.right, pane.pane_rect.right);
                try std.testing.expectEqual(client.bottom, pane.pane_rect.bottom);
                try surface.leaveFullscreen();
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
            var clone = try window(&app, 200);
            defer _ = sys.DestroyWindow(clone.hwnd.?);
            _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
            try clone.inheritWindowStateFrom(&surface, .{});
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
                            try surface.enterFullscreen();
                            try std.testing.expect(sys.SetWindowPos(hwnd, null, dest_info.full_rect.left, dest_info.full_rect.top, dest_info.full_rect.width(), dest_info.full_rect.height(), c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
                            const dest_dpi = sys.GetDpiForWindow(hwnd);
                            try surface.leaveFullscreen();
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

test "win32 a window opened from a minimized one starts on screen at its restored size" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            var source = try placementTestSurface(&app, 50, 50);
            defer _ = sys.DestroyWindow(source.hwnd.?);
            var clone = try placementTestSurface(&app, 700, 300);
            defer _ = sys.DestroyWindow(clone.hwnd.?);

            _ = sys.ShowWindow(source.hwnd.?, c.SW_SHOWNOACTIVATE);
            var restored: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source.hwnd.?, &restored) != 0);
            _ = sys.ShowWindow(source.hwnd.?, c.SW_SHOWMINNOACTIVE);
            try std.testing.expect(sys.IsIconic(source.hwnd.?) != 0);

            try clone.inheritWindowStateFrom(&source, .{});

            // The iconic rect is near (-32000, -32000); what the source
            // restores to is its normal rect.
            try std.testing.expect(sys.IsIconic(clone.hwnd.?) == 0);
            var rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(clone.hwnd.?, &rect) != 0);
            try std.testing.expectEqual(restored.right - restored.left, rect.right - rect.left);
            try std.testing.expectEqual(restored.bottom - restored.top, rect.bottom - rect.top);
            // One cascade step down and right, so it does not cover the
            // source's restored place.
            const dx = rect.left - restored.left;
            const dy = rect.top - restored.top;
            try std.testing.expect(dx > 0 and dx <= 96);
            try std.testing.expect(dy > 0 and dy <= 96);
        }
    }.body);
}

test "win32 a new window cascades from its source, stays on its monitor and follows its state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            var source = try placementTestSurface(&app, 50, 50);
            defer _ = sys.DestroyWindow(source.hwnd.?);
            var clone = try placementTestSurface(&app, 700, 300);
            defer _ = sys.DestroyWindow(clone.hwnd.?);
            const source_hwnd = source.hwnd.?;
            const clone_hwnd = clone.hwnd.?;
            _ = sys.ShowWindow(source_hwnd, c.SW_SHOWNOACTIVATE);
            var restored: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source_hwnd, &restored) != 0);
            const step = sys.MulDiv(32, @intCast(sys.GetDpiForWindow(source_hwnd)), 96);

            // A normal source: one step down and right, same size.
            try clone.inheritWindowStateFrom(&source, .{});
            var rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(clone_hwnd, &rect) != 0);
            try std.testing.expectEqual(restored.left + step, rect.left);
            try std.testing.expectEqual(restored.top + step, rect.top);
            try std.testing.expectEqual(restored.right - restored.left, rect.right - rect.left);
            try std.testing.expectEqual(restored.bottom - restored.top, rect.bottom - rect.top);

            // At the corner of its monitor there is no room to step: the new
            // window stays on the monitor, at the same size.
            const monitor = sys.MonitorFromWindow(source_hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
            const info = monitorInfo(monitor) orelse return lastError();
            try std.testing.expect(sys.SetWindowPos(source_hwnd, null, info.work_area.right - 640, info.work_area.bottom - 480, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
            try clone.inheritWindowStateFrom(&source, .{});
            try std.testing.expect(sys.GetWindowRect(clone_hwnd, &rect) != 0);
            try std.testing.expect(rect.left >= info.work_area.left and rect.right <= info.work_area.right);
            try std.testing.expect(rect.top >= info.work_area.top and rect.bottom <= info.work_area.bottom);
            try std.testing.expectEqual(@as(i32, 640), rect.right - rect.left);
            try std.testing.expectEqual(@as(i32, 480), rect.bottom - rect.top);

            // `window-position-x/y` still says where it goes (`createHost`
            // put it there); only the size comes from the source.
            try std.testing.expect(sys.SetWindowPos(source_hwnd, null, 80, 90, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
            try std.testing.expect(sys.SetWindowPos(clone_hwnd, null, 300, 310, 400, 300, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
            try clone.inheritWindowStateFrom(&source, .{ .position = true });
            try std.testing.expect(sys.GetWindowRect(clone_hwnd, &rect) != 0);
            try std.testing.expectEqual(@as(i32, 300), rect.left);
            try std.testing.expectEqual(@as(i32, 310), rect.top);
            try std.testing.expectEqual(@as(i32, 640), rect.right - rect.left);
            try std.testing.expectEqual(@as(i32, 480), rect.bottom - rect.top);

            // A source minimized from maximized restores to maximized, so
            // the new window is maximized, with the source's normal rect.
            var normal_placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
            normal_placement.length = @sizeOf(WINDOWPLACEMENT);
            try std.testing.expect(sys.GetWindowPlacement(source_hwnd, &normal_placement) != 0);
            _ = sys.ShowWindow(source_hwnd, c.SW_MAXIMIZE);
            _ = sys.ShowWindow(source_hwnd, c.SW_SHOWMINNOACTIVE);
            try std.testing.expect(sys.IsIconic(source_hwnd) != 0);
            try clone.inheritWindowStateFrom(&source, .{});
            try std.testing.expect(sys.IsIconic(clone_hwnd) == 0);
            try std.testing.expect(sys.IsZoomed(clone_hwnd) != 0);
            var clone_placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
            clone_placement.length = @sizeOf(WINDOWPLACEMENT);
            try std.testing.expect(sys.GetWindowPlacement(clone_hwnd, &clone_placement) != 0);
            try std.testing.expectEqualDeep(normal_placement.rcNormalPosition, clone_placement.rcNormalPosition);
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
            const source = try app.createHost(title, &app.config, .{});
            const hwnd = source.hwnd.?;
            try std.testing.expect(sys.SetWindowPos(hwnd, null, 60, 70, 700, 500, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
            _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
            var restored: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(hwnd, &restored) != 0);
            _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
            try std.testing.expect(sys.IsIconic(hwnd) != 0);

            // `createHost` gives the new host the source's place before
            // anything is shown.
            const clone = try app.createHost(title, &app.config, .{});
            try app.inheritHostWindowState(clone, source, false, &app.config);
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
        var clone_state_from: ?*const Surface = null;

        fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, opts: SurfaceInitOptions) anyerror!*Surface {
            calls += 1;
            clone_state_from = opts.clone_state_from;
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
    try std.testing.expect(Hook.clone_state_from == &surface);

    // With no ordinary window it is an ordinary new window.
    _ = app.registry.hosts.orderedRemove(1);
    _ = app.performAction(.app, .new_window, .{}) catch {};
    try std.testing.expectEqual(@as(usize, 2), Hook.calls);
    try std.testing.expect(Hook.clone_state_from == null);

    // An ordinary window is what a new one copies.
    app.registry.hosts.clearRetainingCapacity();
    try app.registry.addHost(std.testing.allocator, &host);
    _ = app.performAction(.app, .new_window, .{}) catch {};
    try std.testing.expectEqual(@as(usize, 3), Hook.calls);
    try std.testing.expect(Hook.clone_state_from == &surface);
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
        var clone_state_from: ?*const Surface = null;

        fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, opts: SurfaceInitOptions) anyerror!*Surface {
            clone_state_from = opts.clone_state_from;
            return error.TestWindowCreateFailed;
        }

        fn source(a: *App, target: apprt.Target) !?*const Surface {
            clone_state_from = null;
            _ = a.performAction(target, .new_window, .{}) catch {};
            return clone_state_from;
        }
    };
    app.test_create_window_surface = &Hook.createSurface;

    // Never activated: the first ordinary window with a pane, in list order.
    try std.testing.expect(try Hook.source(&app, .app) == &first);

    // The ordinary window activated last, though the empty window and the
    // quick terminal were activated after it. Before, the empty window in
    // the first slot gave nothing to copy.
    first_host.activated = 1;
    second_host.activated = 2;
    quick_host.activated = 3;
    empty_host.activated = 4;
    try std.testing.expect(try Hook.source(&app, .app) == &second);
    first_host.activated = 5;
    try std.testing.expect(try Hook.source(&app, .app) == &first);

    // From the quick terminal too. Before, that was the first ordinary
    // window in the list.
    second_host.activated = 6;
    try std.testing.expect(try Hook.source(&app, .{ .surface = quick_surface.core() }) == &second);
    // From an ordinary window, that window, whenever it was activated.
    try std.testing.expect(try Hook.source(&app, .{ .surface = first.core() }) == &first);
}

test "win32 a new window is not maximized by a restore-to-maximized flag left on a normal window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            var source = try placementTestSurface(&app, 50, 50);
            defer _ = sys.DestroyWindow(source.hwnd.?);
            var clone = try placementTestSurface(&app, 700, 300);
            defer _ = sys.DestroyWindow(clone.hwnd.?);
            const hwnd = source.hwnd.?;

            // Maximize, minimize, restore (back to maximized), restore again.
            // Windows keeps WPF_RESTORETOMAXIMIZED in the placement of the
            // normal window this leaves.
            _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
            _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
            _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
            _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
            try std.testing.expect(sys.IsZoomed(hwnd) != 0);
            _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
            try std.testing.expect(sys.IsZoomed(hwnd) == 0 and sys.IsIconic(hwnd) == 0);

            try clone.inheritWindowStateFrom(&source, .{});
            try std.testing.expect(sys.IsZoomed(clone.hwnd.?) == 0);

            // Another tab of the same window syncing its state does not
            // maximize the window either.
            var twin = source;
            try twin.inheritWindowStateFrom(&source, .{});
            try std.testing.expect(sys.IsZoomed(hwnd) == 0);
        }
    }.body);
}

test "win32 fullscreen clone host receives provisional candidate before show" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var core_app: CoreApp = undefined;
            var app: App = undefined;
            var source_host: Host = undefined;
            var clone_host: Host = undefined;
            var source: Surface = undefined;
            var session: TestSession = .{};
            try session.init(.{
                .core_app = &core_app,
                .app = &app,
                .hosts = &.{ .{ .storage = &source_host, .id = 1 }, .{ .storage = &clone_host, .id = 2 } },
                .surfaces = &.{.{ .storage = &source, .host = &source_host }},
                .tabs = &.{.{ .host = &source_host, .surface = &source, .id = 1 }},
            });
            defer session.deinit();
            const source_window = try placementTestSurface(&app, 50, 50);
            defer _ = sys.DestroyWindow(source_window.hwnd.?);
            const clone_window = try placementTestSurface(&app, 700, 300);
            defer _ = sys.DestroyWindow(clone_window.hwnd.?);
            source_host.hwnd = source_window.hwnd;
            clone_host.hwnd = clone_window.hwnd;
            source.fullscreen = true;
            const monitor = try windowMonitor(source_window.hwnd.?);
            const screen = monitor.info.rcMonitor;
            const cases = [_]struct { tabs: configpkg.Config.WindowShowTabBar, renderer: configpkg.Config.RendererBackend, candidate: bool }{
                .{ .tabs = .never, .renderer = .opengl, .candidate = true },
                .{ .tabs = .always, .renderer = .opengl, .candidate = false },
                .{ .tabs = .never, .renderer = .d3d11, .candidate = false },
            };
            var config = app.config;
            for (cases) |case| {
                config.@"window-show-tab-bar" = case.tabs;
                config.renderer = case.renderer;
                try inheritHostWindowState(&app, &clone_host, &source_host, false, &config);
                var rect: RECT = undefined;
                try std.testing.expect(sys.GetWindowRect(clone_window.hwnd.?, &rect) != 0);
                const expected = if (case.candidate) candidateFullscreenRect(screen) orelse screen else screen;
                try std.testing.expectEqualDeep(expected, rect);
                try std.testing.expect(sys.IsWindowVisible(clone_window.hwnd.?) == 0);
            }
        }
    }.body);
}

test "win32 a new window from a fullscreen window covers the same monitor" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            var source = try placementTestSurface(&app, 50, 50);
            defer _ = sys.DestroyWindow(source.hwnd.?);
            var clone = try placementTestSurface(&app, 700, 300);
            defer _ = sys.DestroyWindow(clone.hwnd.?);
            const monitor = sys.MonitorFromWindow(source.hwnd.?, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
            const full = (monitorInfo(monitor) orelse return lastError()).full_rect;
            _ = sys.ShowWindow(source.hwnd.?, c.SW_SHOWNOACTIVATE);
            source.fullscreen = true;
            try std.testing.expect(sys.SetWindowPos(source.hwnd.?, null, full.left, full.top, full.width(), full.height(), c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);

            // Not stepped down and fitted to the work area, which would show
            // the taskbar under a window that is meant to be fullscreen, and
            // not moved by `window-position-x/y`.
            for ([_]bool{ false, true }) |configured| {
                try std.testing.expect(sys.SetWindowPos(clone.hwnd.?, null, 700, 300, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
                try clone.inheritWindowStateFrom(&source, .{ .position = configured });
                try std.testing.expect(clone.fullscreen);
                var rect: RECT = undefined;
                try std.testing.expect(sys.GetWindowRect(clone.hwnd.?, &rect) != 0);
                try std.testing.expectEqualDeep(RECT{ .left = full.left, .top = full.top, .right = full.right, .bottom = full.bottom }, rect);
            }

            // Use nonzero return state so the copy assertions can fail if
            // inheritance drops it.
            source.restore_rect = .{ .left = 30, .top = 40, .right = 670, .bottom = 520 };
            source.restore_placement.rcNormalPosition = .{ .left = 31, .top = 41, .right = 671, .bottom = 521 };
            source.restore_placement.showCmd = c.SW_MAXIMIZE;
            // An OpenGL clone with hidden tabs uses the same candidate as
            // entering fullscreen. Its return geometry remains the source's.
            const screen: RECT = .{ .left = full.left, .top = full.top, .right = full.right, .bottom = full.bottom };
            const candidate_rect = candidateFullscreenRect(screen) orelse screen;
            try inheritWindowStateFromWithCandidate(&clone, &source, .{}, true);
            var candidate_actual: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(clone.hwnd.?, &candidate_actual) != 0);
            try std.testing.expectEqualDeep(candidate_rect, candidate_actual);
            try std.testing.expectEqualDeep(source.restore_rect, clone.restore_rect);
            try std.testing.expectEqualDeep(source.restore_placement, clone.restore_placement);

            // Minimized, the source's own rect is a sliver under the
            // taskbar; the monitor is still where it is fullscreen.
            _ = sys.ShowWindow(source.hwnd.?, c.SW_SHOWMINNOACTIVE);
            try std.testing.expect(sys.IsIconic(source.hwnd.?) != 0);
            try clone.inheritWindowStateFrom(&source, .{});
            var rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(clone.hwnd.?, &rect) != 0);
            try std.testing.expectEqualDeep(RECT{ .left = full.left, .top = full.top, .right = full.right, .bottom = full.bottom }, rect);
        }
    }.body);
}

test "win32 new windows from one source step past the windows already there" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            _ = sys.SetThreadDpiAwarenessContext(-4);
            var app = placementTestApp();
            defer app.registry.hosts.deinit(std.testing.allocator);
            var source = try placementTestSurface(&app, 50, 50);
            defer _ = sys.DestroyWindow(source.hwnd.?);
            var clone = try placementTestSurface(&app, 700, 300);
            defer _ = sys.DestroyWindow(clone.hwnd.?);
            _ = sys.ShowWindow(source.hwnd.?, c.SW_SHOWNOACTIVATE);
            var origin: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source.hwnd.?, &origin) != 0);
            const step = sys.MulDiv(32, @intCast(sys.GetDpiForWindow(source.hwnd.?)), 96);

            // Several new windows opened from the same window: the next one
            // goes where the last one is not.
            var rect: RECT = undefined;
            for ([_]i32{ 1, 2, 3 }) |n| {
                try clone.inheritWindowStateFrom(&source, .{});
                try std.testing.expect(sys.GetWindowRect(clone.hwnd.?, &rect) != 0);
                try std.testing.expectEqual(origin.left + n * step, rect.left);
                try std.testing.expectEqual(origin.top + n * step, rect.top);
                var opened = try placementTestSurface(&app, rect.left, rect.top);
                _ = sys.ShowWindow(opened.hwnd.?, c.SW_SHOWNOACTIVATE);
                const host = try std.testing.allocator.create(Host);
                host.* = .{ .app = &app, .id = @intCast(n), .hwnd = opened.hwnd };
                try app.registry.addHost(std.testing.allocator, host);
                // Kept until the end of the body: `opened` is a copy of the
                // window handle, destroyed with the loop's other windows.
                _ = &opened;
            }
            for (app.registry.hosts.items) |host| {
                _ = sys.DestroyWindow(host.hwnd.?);
                std.testing.allocator.destroy(host);
            }
            app.registry.hosts.clearRetainingCapacity();
        }
    }.body);
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

                try std.testing.expectEqual(fullscreen, surface.fullscreen);
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
                    try surface.toggleFullscreen(.native);
                    try std.testing.expect(!surface.fullscreen);
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
                try std.testing.expectEqual(case.fullscreen, clone.fullscreen);
                if (case.fullscreen) {
                    // On the source's monitor, and back to the cascaded
                    // window when it leaves, maximized with both.
                    try std.testing.expectEqualDeep(screen, try Fixture.screenRect(hwnd));
                    try std.testing.expect(sys.IsZoomed(hwnd) == 0);
                    try clone.toggleFullscreen(.native);
                }
                // Before the fix every one of these ended in the source's
                // SW_RESTORE.
                try std.testing.expectEqual(case.maximized, sys.IsZoomed(hwnd) != 0);
                try std.testing.expectEqualDeep(cascaded, try Fixture.normalRect(hwnd));
                // The source is left as it was.
                try std.testing.expect(sys.IsZoomed(source_hwnd) == 0 and !source.fullscreen);
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
        return effectiveHostWindowStyle(surface.keepsFrameUndecorated(), false, true) & ~@as(u32, c.WS_VISIBLE);
    }

    /// The monitors of the desktop, at most `buf.len`. A CI runner has one,
    /// so the legs that need two run only on a machine with more.
    fn monitors(buf: *[8]MONITORINFO) ![]const MONITORINFO {
        const Collect = struct {
            infos: *[8]MONITORINFO,
            count: usize = 0,
            failed: bool = false,

            fn add(monitor: sys.HMONITOR, _: HDC, _: *RECT, data: LPARAM) callconv(.winapi) BOOL {
                const self: *@This() = @ptrFromInt(@as(usize, @bitCast(data)));
                if (self.count == self.infos.len) return 0;
                var info: MONITORINFO = std.mem.zeroes(MONITORINFO);
                info.cbSize = @sizeOf(MONITORINFO);
                if (sys.GetMonitorInfoW(monitor, &info) == 0) {
                    self.failed = true;
                    return 0;
                }
                self.infos[self.count] = info;
                self.count += 1;
                return 1;
            }
        };
        var collect: Collect = .{ .infos = buf };
        _ = sys.EnumDisplayMonitors(null, null, Collect.add, @bitCast(@intFromPtr(&collect)));
        if (collect.failed) return lastError();
        return buf[0..collect.count];
    }

    /// Moves the source, a normal window, to (100, 100) in `work`, asking
    /// for 800x600 (onto a monitor of another DPI it takes the size its DPI
    /// change scales that to), and returns its DPI there.
    fn moveSource(self: *ForwardedKeysTest, work: RECT) !u32 {
        const hwnd = self.source.windowHwnd().?;
        if (sys.SetWindowPos(hwnd, null, work.left + 100, work.top + 100, 800, 600, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return lastError();
        return sys.GetDpiForWindow(hwnd);
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
            try t.source.toggleFullscreen(.native);
            {
                const clone = try t.forward(ForwardedKeysTest.sized, ForwardedKeysTest.own);
                const hwnd = clone.windowHwnd().?;
                try std.testing.expect(clone.fullscreen);
                try std.testing.expectEqualDeep(try Fixture.monitorRect(hwnd), try Fixture.screenRect(hwnd));
                try clone.toggleFullscreen(.native);
                try std.testing.expect(!clone.fullscreen and sys.IsZoomed(hwnd) == 0);
                try std.testing.expectEqualDeep(ForwardedKeysTest.ownClient(clone), try ForwardedKeysTest.clientSize(hwnd));
                const rect = try Fixture.screenRect(hwnd);
                try std.testing.expectEqual(t.source_rect.left, rect.left);
                try std.testing.expectEqual(t.source_rect.top, rect.top);
                t.fixture.closeWindow(clone);
            }
            try t.source.toggleFullscreen(.native);
        }
    }.body);
}

test "win32 a forwarded size from a fullscreen window is in the pixels of the monitor the new window is on" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        /// Moves the source, a normal window, near the far corner of `work`,
        /// where its rect fits and a new window of the forwarded size does
        /// not, also on a 1024x768 runner at 96 DPI.
        fn toCorner(hwnd: HWND, work: RECT) !void {
            if (sys.SetWindowPos(hwnd, null, work.right - 300, work.bottom - 200, 280, 180, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return lastError();
        }

        /// The new window leaves fullscreen, maximized if the source was
        /// before it went fullscreen, and is then restored: it has the client
        /// its forwarded size gives it, inside `work`. Returns its rect.
        fn leaveInside(clone: *Surface, maximized: bool, work: RECT) !RECT {
            const hwnd = clone.windowHwnd().?;
            try std.testing.expect(clone.fullscreen);
            try clone.toggleFullscreen(.native);
            try std.testing.expect(!clone.fullscreen);
            try std.testing.expectEqual(maximized, sys.IsZoomed(hwnd) != 0);
            if (maximized) _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
            try std.testing.expectEqualDeep(ForwardedKeysTest.ownClient(clone), try ForwardedKeysTest.clientSize(hwnd));
            const rect = try ForwardedKeysTest.Fixture.screenRect(hwnd);
            try std.testing.expect(rect.left >= work.left and rect.top >= work.top);
            try std.testing.expect(rect.right <= work.right and rect.bottom <= work.bottom);
            return rect;
        }

        /// The source leaves fullscreen too. `rect`, the new window's, is
        /// where the source comes back to, moved only as far as its own
        /// size needs to stay inside `work`.
        fn expectAtSource(t: *ForwardedKeysTest, maximized: bool, rect: RECT, work: RECT) !void {
            const hwnd = t.source.windowHwnd().?;
            try t.source.toggleFullscreen(.native);
            const back = if (maximized) try ForwardedKeysTest.Fixture.normalRect(hwnd) else try ForwardedKeysTest.Fixture.screenRect(hwnd);
            try std.testing.expectEqualDeep(fitRectInWork(back.left, back.top, rect.right - rect.left, rect.bottom - rect.top, work), rect);
            if (maximized) _ = sys.ShowWindow(hwnd, c.SW_RESTORE);
        }

        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();
            const Fixture = ForwardedKeysTest.Fixture;
            const source_hwnd = t.source.windowHwnd().?;

            // The source entered fullscreen while its monitor's scale was
            // twice what it is now, so leaving gives it its rect at half the
            // size. The new window's forwarded size is its own, in pixels of
            // the scale it has now. Before the fix it was halved too.
            try t.source.toggleFullscreen(.native);
            const dpi = t.source.restore_monitor.?.dpi;
            t.source.restore_monitor.?.dpi = dpi * 2;
            {
                const clone = try t.forward(ForwardedKeysTest.sized, ForwardedKeysTest.own);
                t.source.restore_monitor.?.dpi = dpi;
                const hwnd = clone.windowHwnd().?;
                try std.testing.expect(clone.fullscreen);
                try clone.toggleFullscreen(.native);
                try std.testing.expect(!clone.fullscreen and sys.IsZoomed(hwnd) == 0);
                try std.testing.expectEqualDeep(ForwardedKeysTest.ownClient(clone), try ForwardedKeysTest.clientSize(hwnd));
                const rect = try Fixture.screenRect(hwnd);
                try std.testing.expectEqual(t.source_rect.left, rect.left);
                try std.testing.expectEqual(t.source_rect.top, rect.top);
                t.fixture.closeWindow(clone);
            }
            try t.source.toggleFullscreen(.native);

            // Near the far corner of the work area the source fits and the
            // new window does not, so it comes back moved inside, as one
            // opened from a normal or maximized source is. Also from a source
            // maximized before it went fullscreen, which leaves to its
            // placement, and at the doubled scale above. Before the fix it
            // reached past the work area at either scale, and from the
            // maximized source at the doubled scale its client was halved.
            const work = (try Surface.windowMonitor(source_hwnd)).info.rcWork;
            for ([_]bool{ false, true }) |maximized| {
                for ([_]u32{ 1, 2 }) |scale| {
                    try toCorner(source_hwnd, work);
                    if (maximized) _ = sys.ShowWindow(source_hwnd, c.SW_MAXIMIZE);
                    try t.source.toggleFullscreen(.native);
                    t.source.restore_monitor.?.dpi = dpi * scale;
                    const clone = try t.forward(ForwardedKeysTest.sized, ForwardedKeysTest.own);
                    t.source.restore_monitor.?.dpi = dpi;
                    const rect = try leaveInside(clone, maximized, work);
                    t.fixture.closeWindow(clone);
                    try expectAtSource(&t, maximized, rect, work);
                }
            }

            // The same with real monitors: the source entered fullscreen on
            // one and was moved to another while fullscreen. Measured on
            // main with a 144 DPI and two 96 DPI monitors: the new window
            // left fullscreen with a 261x187 client on a 96 DPI monitor and
            // 911x703 on the 144 DPI one, where 400x300 and 600x450 were
            // asked for. Monitors of the same DPI were right before the fix.
            // The maximized source pins the placement's half of the fix.
            var buf: [8]MONITORINFO = undefined;
            const monitors = try ForwardedKeysTest.monitors(&buf);
            for (monitors) |entered| {
                for (monitors) |now| {
                    if (std.meta.eql(entered.rcMonitor, now.rcMonitor)) continue;
                    for ([_]bool{ false, true }) |maximized| {
                        _ = try t.moveSource(entered.rcWork);
                        try toCorner(source_hwnd, entered.rcWork);
                        if (maximized) _ = sys.ShowWindow(source_hwnd, c.SW_MAXIMIZE);
                        try t.source.toggleFullscreen(.native);
                        const screen = now.rcMonitor;
                        if (sys.SetWindowPos(source_hwnd, null, screen.left, screen.top, screen.right - screen.left, screen.bottom - screen.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return lastError();
                        const now_dpi = sys.GetDpiForWindow(source_hwnd);
                        const clone = try t.forward(ForwardedKeysTest.sized, ForwardedKeysTest.own);
                        const hwnd = clone.windowHwnd().?;
                        try std.testing.expectEqualDeep(screen, try Fixture.screenRect(hwnd));
                        const rect = try leaveInside(clone, maximized, now.rcWork);
                        try std.testing.expectEqualDeep(screen, try Fixture.monitorRect(hwnd));
                        try std.testing.expectEqual(now_dpi, sys.GetDpiForWindow(hwnd));
                        t.fixture.closeWindow(clone);
                        try expectAtSource(&t, maximized, rect, now.rcWork);
                    }
                }
            }
        }
    }.body);
}

test "win32 a new window placed and sized by forwarded arguments keeps that size on any monitor" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn forwardAt(t: *ForwardedKeysTest, x: i32, y: i32, size: apprt.action.InitialSize) !void {
            var buf: [2][32]u8 = undefined;
            const placed = try ForwardedKeysTest.placedAt(&buf, x, y);
            const clone = try t.forward(&.{ placed[0], placed[1], ForwardedKeysTest.sized[0], ForwardedKeysTest.sized[1] }, size);
            const hwnd = clone.windowHwnd().?;
            const rect = try ForwardedKeysTest.Fixture.screenRect(hwnd);
            try std.testing.expectEqual(x, rect.left);
            try std.testing.expectEqual(y, rect.top);
            try std.testing.expectEqualDeep(
                scaleInitialClientSize(.{ .width = size.width, .height = size.height }, clone.content_scale),
                try ForwardedKeysTest.clientSize(hwnd),
            );
            t.fixture.closeWindow(clone);
        }

        fn body() !void {
            var t: ForwardedKeysTest = .{};
            try t.init();
            defer t.deinit();
            const source_hwnd = t.source.windowHwnd().?;

            // Placed where the arguments say, a window keeps the size they
            // give it, as a first window would, even where it does not fit
            // the source's work area: the cascade that fits a new window to
            // that area does not place this one. Before the fix it was cut
            // to that area. On the source's monitor, that is a window taller
            // than the work area, up to the tallest a window can be.
            {
                const monitor = try Surface.windowMonitor(source_hwnd);
                const work = monitor.info.rcWork;
                const scale: apprt.ContentScale = .{
                    .x = @as(f32, @floatFromInt(monitor.dpi)) / 96.0,
                    .y = @as(f32, @floatFromInt(monitor.dpi)) / 96.0,
                };
                const frame_height = (t.source_rect.bottom - t.source_rect.top) -
                    @as(i32, @intCast((try ForwardedKeysTest.clientSize(source_hwnd)).height));
                const height: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(work.bottom - work.top - frame_height + 1)) / scale.y));
                const client = scaleInitialClientSize(.{ .width = ForwardedKeysTest.own.width, .height = height }, scale);
                // SM_CYMAXTRACK.
                const tallest = sys.GetSystemMetricsForDpi(60, monitor.dpi);
                if (@as(i32, @intCast(client.height)) + frame_height <= tallest) {
                    try forwardAt(&t, work.left + 40, work.top, .{ .width = ForwardedKeysTest.own.width, .height = height });
                }
            }

            // Placed on another monitor, larger than the source's work area
            // and inside its own. Measured on main with 3840x2088,
            // 1920x1032 and 1080x1872 work areas: every window larger than
            // the source's work area was cut to it, at the right place.
            var buf: [8]MONITORINFO = undefined;
            const monitors = try ForwardedKeysTest.monitors(&buf);
            for (monitors) |source| {
                for (monitors) |target| {
                    if (std.meta.eql(source.rcMonitor, target.rcMonitor)) continue;
                    const target_dpi: i32 = @intCast(try t.moveSource(target.rcWork));
                    _ = try t.moveSource(source.rcWork);
                    const width = @min(target.rcWork.right - target.rcWork.left - 120, @max(source.rcWork.right - source.rcWork.left + 60, 600));
                    const height = @min(target.rcWork.bottom - target.rcWork.top - 120, @max(source.rcWork.bottom - source.rcWork.top + 40, 400));
                    try forwardAt(&t, target.rcWork.left + 40, target.rcWork.top + 30, .{
                        .width = @intCast(@divTrunc(width * 96, target_dpi)),
                        .height = @intCast(@divTrunc(height * 96, target_dpi)),
                    });
                }
            }
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
            const framed = effectiveHostWindowStyle(true, false, true) & ~@as(u32, c.WS_VISIBLE);

            // Windows 10's frameless undecorated window, and Windows 11's,
            // which keeps the frame (`undecoratedKeepsFrame`), so there only
            // the decoration state tells the two apart: a style check passes
            // either way.
            for ([_]u32{ 19045, c.OS_BUILD_WIN11_21H2 }) |os_build| {
                t.fixture.app.os_build = os_build;
                // Before the fix a new window always took the source's.
                {
                    const clone = try t.forward(&.{"--window-decoration=none"}, null);
                    try std.testing.expect(!clone.decorations_visible and !clone.host.?.cached_decorations_visible);
                    try std.testing.expectEqual(undecorated(clone), style(clone.windowHwnd().?));
                    try std.testing.expectEqual(clone.keepsFrameUndecorated(), undecorated(clone) == framed);
                    t.fixture.closeWindow(clone);
                }
                try t.source.toggleDecorations();
                // The control: without them it copies the source's.
                {
                    const clone = try t.forward(null, null);
                    try std.testing.expect(!clone.decorations_visible);
                    try std.testing.expectEqual(undecorated(clone), style(clone.windowHwnd().?));
                    t.fixture.closeWindow(clone);
                }
                {
                    const clone = try t.forward(&.{"--window-decoration=auto"}, null);
                    try std.testing.expect(clone.decorations_visible and clone.host.?.cached_decorations_visible);
                    try std.testing.expectEqual(framed, style(clone.windowHwnd().?));
                    // A config reload gives it the config's decorations
                    // again, as it does a window that took them from the
                    // config.
                    try std.testing.expect(!clone.decorations_visible_overridden);
                    t.fixture.closeWindow(clone);
                }
                try t.source.toggleDecorations();
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
                try std.testing.expectEqual(@as(f64, 0.5), clone.background_opacity_default);
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
            try std.testing.expect(!clone.decorations_visible and !clone.host.?.cached_decorations_visible);
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
        /// kept in its work area as `newWindowPlacement` keeps it.
        fn expectCopies(t: *ForwardedKeysTest, source: *Surface) !void {
            const hwnd = source.windowHwnd().?;
            const rect = try ForwardedKeysTest.Fixture.screenRect(hwnd);
            const work = (try Surface.windowMonitor(hwnd)).info.rcWork;
            const clone = try t.forward(null, null);
            try std.testing.expectEqualDeep(cascadedRect(rect, cascadeStep(sys.GetDpiForWindow(hwnd)), work), try ForwardedKeysTest.Fixture.screenRect(clone.windowHwnd().?));
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
            try std.testing.expect(sys.IsZoomed(plain_hwnd) == 0 and !plain.fullscreen);
            try std.testing.expectEqualDeep(plain_rect, try Fixture.screenRect(plain_hwnd));

            // A window opened after the reload takes them.
            try app.createWindow(default_title);
            const started = fixture.newest();
            const started_hwnd = started.windowHwnd().?;
            try std.testing.expect(started.fullscreen);
            const started_rect = try Fixture.screenRect(started_hwnd);

            // Turned off: neither window changes, and the second still
            // leaves fullscreen to a maximized window, as it started.
            var neither = try app.config.clone(std.testing.allocator);
            defer neither.deinit();
            neither.maximize = false;
            neither.fullscreen = .false;
            try reload(app, &neither);
            try std.testing.expect(started.fullscreen and sys.IsZoomed(started_hwnd) == 0);
            try std.testing.expectEqualDeep(started_rect, try Fixture.screenRect(started_hwnd));
            try std.testing.expect(sys.IsZoomed(plain_hwnd) == 0 and !plain.fullscreen);
            try std.testing.expectEqualDeep(plain_rect, try Fixture.screenRect(plain_hwnd));
            try started.toggleFullscreen(.native);
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

test "win32 shouldPropagateSharedHostWindowState only for active shared-host surfaces" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var standalone: Surface = undefined;
    standalone.host = null;
    try std.testing.expect(shouldPropagateSharedHostWindowState(&standalone));

    var host: Host = undefined;
    host.tabs = .empty;
    host.active_tab = 0;
    defer {
        for (host.tabs.items) |*tab| tab.deinit();
        host.tabs.deinit(std.testing.allocator);
    }

    var active_surface: Surface = undefined;
    active_surface.host = &host;
    var inactive_surface: Surface = undefined;
    inactive_surface.host = &host;

    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &active_surface));
    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &inactive_surface));

    try std.testing.expect(shouldPropagateSharedHostWindowState(&active_surface));
    try std.testing.expect(!shouldPropagateSharedHostWindowState(&inactive_surface));

    host.active_tab = 1;
    try std.testing.expect(!shouldPropagateSharedHostWindowState(&active_surface));
    try std.testing.expect(shouldPropagateSharedHostWindowState(&inactive_surface));
}

test "win32 config decoration reload respects runtime override" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(shouldApplyConfigDecorations(false));
    try std.testing.expect(!shouldApplyConfigDecorations(true));
}

test "win32 shouldResizeHostForInitialSize only for single-surface hosts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(!shouldResizeHostForInitialSize(0));
    try std.testing.expect(shouldResizeHostForInitialSize(1));
    try std.testing.expect(!shouldResizeHostForInitialSize(2));
    try std.testing.expect(!shouldResizeHostForInitialSize(8));
}

test "win32 sharedHostWindowFrameStateEquals ignores non-frame host state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var a: Surface = undefined;
    a.decorations_visible = true;
    a.fullscreen = false;
    a.topmost = false;
    a.background_opacity_default = 1.0;
    a.background_opacity_force_opaque = false;
    a.size_limit = .{
        .min_width = 0,
        .min_height = 0,
        .max_width = 0,
        .max_height = 0,
    };

    var b: Surface = a;
    b.topmost = true;
    b.background_opacity_default = 0.6;
    b.background_opacity_force_opaque = true;

    try std.testing.expect(sharedHostWindowFrameStateEquals(&a, &b));

    b.decorations_visible = false;
    try std.testing.expect(!sharedHostWindowFrameStateEquals(&a, &b));
    b.decorations_visible = a.decorations_visible;

    b.size_limit = .{ .min_width = 123, .min_height = 0, .max_width = 0, .max_height = 0 };
    try std.testing.expect(!sharedHostWindowFrameStateEquals(&a, &b));
}

test "win32 applyInitialBackgroundOpacity layers the cold-start host window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(hwnd);

    var host: Host = undefined;
    var surface: Surface = undefined;
    try initTestHostWindowFixture(&host, &surface, hwnd);
    defer deinitTestHostWindowFixture(&host);

    // Regression for #234: a cold-start window never reached
    // `applyBackgroundOpacity`, so it stayed opaque while cloned windows
    // faded. `WS_EX_LAYERED` plus `LWA_ALPHA` is the whole mechanism.
    surface.background_opacity_default = 0.75;
    surface.applyInitialBackgroundOpacity(null);
    try std.testing.expect(testHostIsLayered(hwnd));
    try std.testing.expectEqual(@as(?u8, 191), testLayeredAlpha(hwnd));

    // `toggle_background_opacity` forces the window opaque, which must drop
    // the layered style entirely rather than set alpha 255.
    try std.testing.expect(try surface.toggleBackgroundOpacity());
    try std.testing.expect(!testHostIsLayered(hwnd));

    try std.testing.expect(try surface.toggleBackgroundOpacity());
    try std.testing.expect(testHostIsLayered(hwnd));
    try std.testing.expectEqual(@as(?u8, 191), testLayeredAlpha(hwnd));
}

test "win32 applyInitialBackgroundOpacity leaves a fully opaque window unlayered" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(hwnd);

    var host: Host = undefined;
    var surface: Surface = undefined;
    try initTestHostWindowFixture(&host, &surface, hwnd);
    defer deinitTestHostWindowFixture(&host);

    // The default configuration must not start layering every window: that
    // would put all of Win32 on a composition path it does not need.
    surface.applyInitialBackgroundOpacity(null);
    try std.testing.expect(!testHostIsLayered(hwnd));
    try std.testing.expectEqual(@as(?u8, null), testLayeredAlpha(hwnd));
}

test "win32 applyInitialBackgroundOpacity seeds a clone from its source window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(hwnd);

    var host: Host = undefined;
    var surface: Surface = undefined;
    try initTestHostWindowFixture(&host, &surface, hwnd);
    defer deinitTestHostWindowFixture(&host);

    // `new_window` from an existing surface presents the clone before
    // `inheritWindowStateFrom` runs, so the source's opacity has to be seeded
    // up front. The fixture left the clone on the configured 1.0, so reading
    // 0.6 back off the clone is the seed and nothing else.
    var source: Surface = undefined;
    source.background_opacity_default = 0.6;
    source.background_opacity_force_opaque = false;

    surface.applyInitialBackgroundOpacity(&source);
    try std.testing.expectEqual(@as(f64, 0.6), surface.background_opacity_default);
    try std.testing.expect(testHostIsLayered(hwnd));
    try std.testing.expectEqual(@as(?u8, 153), testLayeredAlpha(hwnd));

    // Cloning a window the user forced opaque with
    // `toggle_background_opacity` must not flash the clone translucent.
    var opaque_source: Surface = undefined;
    opaque_source.background_opacity_default = 0.6;
    opaque_source.background_opacity_force_opaque = true;

    surface.applyInitialBackgroundOpacity(&opaque_source);
    try std.testing.expect(surface.background_opacity_force_opaque);
    try std.testing.expect(!testHostIsLayered(hwnd));
}

test "win32 shared host topmost and opacity equality track separate window state" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var a: Surface = undefined;
    a.topmost = false;
    a.background_opacity_default = 0.5;
    a.background_opacity_force_opaque = false;

    var b: Surface = a;
    try std.testing.expect(sharedHostWindowTopmostEquals(&a, &b));
    try std.testing.expect(sharedHostWindowOpacityEquals(&a, &b));

    b.topmost = true;
    try std.testing.expect(!sharedHostWindowTopmostEquals(&a, &b));
    try std.testing.expect(sharedHostWindowOpacityEquals(&a, &b));

    b.topmost = a.topmost;
    b.background_opacity_force_opaque = true;
    try std.testing.expect(sharedHostWindowTopmostEquals(&a, &b));
    try std.testing.expect(!sharedHostWindowOpacityEquals(&a, &b));

    b.background_opacity_force_opaque = false;
    b.background_opacity_default = 0.5001;
    try std.testing.expect(sharedHostWindowOpacityEquals(&a, &b));
}

test "win32 hostSurfaceCount tracks surfaces attached to one host" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var host: Host = undefined;
    host.id = 42;
    host.tabs = .empty;
    host.active_tab = 0;
    defer {
        for (host.tabs.items) |*tab| tab.deinit();
        host.tabs.deinit(std.testing.allocator);
    }

    var first: Surface = undefined;
    first.host = &host;
    first.host_id = host.id;

    var second: Surface = undefined;
    second.host = &host;
    second.host_id = host.id;

    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &first));
    try std.testing.expectEqual(@as(usize, 1), first.hostSurfaceCount());
    try std.testing.expect(shouldResizeHostForInitialSize(first.hostSurfaceCount()));

    try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &second));
    try std.testing.expectEqual(@as(usize, 2), first.hostSurfaceCount());
    try std.testing.expect(!shouldResizeHostForInitialSize(first.hostSurfaceCount()));
}
