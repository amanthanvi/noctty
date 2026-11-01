//! Quick-terminal host toggle, placement, focus and monitor policy.
const win32 = @import("../win32.zig");
const runtime = win32.quick_terminal_host_runtime;
const App = runtime.App;
const BOOL = runtime.BOOL;
const CoreApp = runtime.CoreApp;
const HDC = runtime.HDC;
const HWND = runtime.HWND;
const HWND_TOPMOST = runtime.HWND_TOPMOST;
const Host = runtime.Host;
const LPARAM = runtime.LPARAM;
const LPCWSTR = runtime.LPCWSTR;
const MONITORINFO = runtime.MONITORINFO;
const POINT = runtime.POINT;
const QuickTerminalToggleFixture = win32.test_support.QuickTerminalToggleFixture;
const RECT = runtime.RECT;
const SplitTreeSurface = runtime.SplitTreeSurface;
const Surface = runtime.Surface;
const SurfaceInitOptions = runtime.SurfaceInitOptions;
const Tab = runtime.Tab;
const appendOwnedString = paint_text.appendOwnedString;
const apprt = runtime.apprt;
const builtin = runtime.builtin;
const c = runtime.c;
const child_window = @import("child_window.zig");
const configpkg = runtime.configpkg;
const getHost = runtime.getHost;
const hostWindowProc = runtime.hostWindowProc;
const host_class_name = runtime.host_class_name;
const log = runtime.log;
const paint_text = @import("text.zig");
const palette_list_class_name = runtime.palette_list_class_name;
const rectEqual = runtime.rectEqual;
const runOnHiddenDesktop = win32.test_support.runOnHiddenDesktop;
const scrollbar_class_name = runtime.scrollbar_class_name;
const setWindowData = child_window.setWindowData;
const std = runtime.std;
const sys = runtime.sys;
const win32_quick_terminal = runtime.win32_quick_terminal;
const win32_theme = runtime.win32_theme;
const win32_tween = runtime.win32_tween;

pub const quick_terminal_title = std.unicode.utf8ToUtf16LeStringLiteral("noctty quick terminal");

pub fn hideQuickTerminalHost(host: *Host) void {
    host.cancelQuickTerminalAnimation();
    host.setVisible(false);
}

/// Puts the quick terminal window on its screen edge and shows it.
pub fn showQuickTerminalWindow(self: *App, top_level: HWND, want_focus: bool) void {
    self.windows_hidden = false;
    self.applyQuickTerminalGeometry(top_level, true) catch |err| {
        std.log.warn("QT geometry failed err={}", .{err});
    };
    _ = sys.ShowWindow(
        top_level,
        if (want_focus) c.SW_SHOW else c.SW_SHOWNOACTIVATE,
    );
}

pub fn quickTerminalFocusPolicy(self: *App) win32_quick_terminal.FocusPolicy {
    return win32_quick_terminal.focusPolicy(switch (self.config.@"quick-terminal-keyboard-interactivity") {
        .@"on-demand" => .on_demand,
        .exclusive => .always,
        .none => .never,
    });
}

pub fn toggleQuickTerminal(self: *App) !void {
    // `quick-terminal-keyboard-interactivity`:
    //   * on-demand → show + focus (our `.present()` path)
    //   * exclusive → show + focus (no global input grab)
    //   * none      → show WITHOUT stealing focus; the window
    //                 becomes a visible passive log / reference
    //                 the user can glance at without losing their
    //                 typing context.
    // The snapshot + branch below centralises the focus-or-not
    // decision so both the reuse path and the create path honour
    // the config.
    const focus_policy = self.quickTerminalFocusPolicy();
    const want_focus = focus_policy.activate_window;
    if (focus_policy.diagnostic == .exclusive_keyboard_grab_unsupported and
        !self.quick_terminal_keyboard_diagnostic_logged)
    {
        self.quick_terminal_keyboard_diagnostic_logged = true;
        std.log.warn("quick-terminal-keyboard-interactivity=exclusive maps to focused input on Win32; global keyboard capture is unsupported", .{});
    }

    if (self.registry.quickTerminalHost()) |host| {
        // The quick terminal is its host window, an outer frame around
        // child GL surfaces. Visibility + geometry apply to the HOST
        // hwnd: using a child hwnd would leave an empty host window on
        // screen when hidden, and would run `MonitorFromWindow` /
        // `SetWindowPos` against the wrong target when showing.
        const visible = if (host.hwnd) |top_level| sys.IsWindowVisible(top_level) != 0 else false;
        const surface = host.activeSurface() orelse {
            // `close_tab:this` on its last tab keeps the host, and the
            // surface detached from it, for undo. The detached surface
            // is not something to show: dismiss the empty window, or
            // open a fresh tab in it.
            if (visible) {
                hideQuickTerminalHost(host);
                return;
            }
            var config = try apprt.surface.newConfig(
                self.core_app,
                &self.config,
                .window,
            );
            defer config.deinit();
            const launch = try configpkg.pane_launch.prepare(&config, .{ .fresh = .{} }, self.launchContext(null));
            const fresh = try self.createWindowSurface(&config, quick_terminal_title, .{
                .host_id = host.id,
                .launch = launch,
            });
            // Floating is the surface's state: the window follows the
            // active tab's.
            try fresh.setFloatWindow(.on);
            if (host.hwnd) |top_level| self.showQuickTerminalWindow(top_level, want_focus);
            self.showHostSurface(fresh, want_focus);
            self.auditCreationAfterActivation();
            return;
        };
        const top_level = host.hwnd orelse return;
        if (visible) {
            hideQuickTerminalHost(host);
        } else {
            self.showQuickTerminalWindow(top_level, want_focus);
            // Mirror the hide-side invariant: tell every pane of the
            // active tab it's visible so the renderer wakes and the
            // occlusion callback flips back to "not occluded".
            // Hiding marked every pane not visible, including the ones a
            // zoom keeps out of view.
            if (host.activeTab()) |tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| {
                    entry.view.setVisible(tab.tree.zoomed == null or tab.tree.zoomed.? == entry.handle);
                }
            }
            if (want_focus) surface.present();
        }
        return;
    }

    var config = try apprt.surface.newConfig(
        self.core_app,
        &self.config,
        .window,
    );
    defer config.deinit();
    const launch = try configpkg.pane_launch.prepare(&config, .{ .fresh = .{} }, self.launchContext(null));
    const surface = try self.createWindowSurface(&config, quick_terminal_title, .{
        .quick_terminal = true,
        // Passive first-show: `Surface.init` uses `SW_SHOWNOACTIVATE`
        // after GL and core initialization, so the new HWND appears
        // without taking focus. Without this, the very first toggle-on
        // with `keyboard-interactivity = none` would still activate the
        // window even though the later `present()` call is skipped.
        .show = if (want_focus) .activate else .no_activate,
        .launch = launch,
    });
    try surface.setFloatWindow(.on);
    if (surface.windowHwnd()) |top_level| {
        self.applyQuickTerminalGeometry(top_level, true) catch |err| {
            std.log.warn("QT geometry failed err={}", .{err});
        };
    }
    if (want_focus) surface.present();
}

/// Resolve the 7 `quick-terminal-*` config fields into a concrete
/// end rect via `win32_quick_terminal` and apply it immediately
/// with `SetWindowPos`.
pub fn applyQuickTerminalGeometry(self: *App, hwnd: HWND, animate: bool) !void {
    var qt_cfg = win32_quick_terminal.QuickTerminalConfig{
        .position = switch (self.config.@"quick-terminal-position") {
            .top => .top,
            .bottom => .bottom,
            .left => .left,
            .right => .right,
            .center => .center,
        },
        .screen = switch (self.config.@"quick-terminal-screen") {
            .main => .main,
            // `mouse` config value → our module's `.focused` semantic:
            // pick the monitor containing the current input focus /
            // cursor. Matches the documented config intent.
            .mouse => .focused,
            .all => .all,
        },
        .animation_duration_s = self.config.@"quick-terminal-animation-duration",
        .autohide = self.config.@"quick-terminal-autohide",
        // Stored but never read: no code follows virtual-desktop switches,
        // so `quick-terminal-space-behavior` has no Windows effect
        // (docs/windows-capability-matrix.md).
        .space_behavior = switch (self.config.@"quick-terminal-space-behavior") {
            .move => .move,
            // `remain` config value → our module's `.ignore`:
            // don't follow virtual-desktop changes.
            .remain => .ignore,
        },
        .keyboard_interactivity = switch (self.config.@"quick-terminal-keyboard-interactivity") {
            .@"on-demand" => .on_demand,
            .exclusive => .always,
            .none => .never,
        },
    };

    // Resolve monitor per the config's documented semantic:
    //   * `.main`   → the OS PRIMARY monitor, regardless of
    //                 where this window last was or where the
    //                 virtual-desktop origin lives.
    //   * `.focused` (config's `mouse`) → the monitor under
    //                 the cursor via `GetCursorPos` +
    //                 `MonitorFromPoint(MONITOR_DEFAULTTONEAREST)`.
    //   * `.all`    → the union of all connected monitors' work
    //                 areas, matching the full virtual desktop.
    const mi = switch (qt_cfg.screen) {
        .focused => blk: {
            var pt: POINT = .{ .x = 0, .y = 0 };
            if (sys.GetCursorPos(&pt) == 0) {
                const monitor = sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse
                    return error.MonitorLookupFailed;
                break :blk monitorInfo(monitor) orelse return error.MonitorInfoFailed;
            }
            const monitor = sys.MonitorFromPoint(pt, c.MONITOR_DEFAULTTONEAREST) orelse
                return error.MonitorLookupFailed;
            break :blk monitorInfo(monitor) orelse return error.MonitorInfoFailed;
        },
        .main => blk: {
            const monitor = primaryMonitor() orelse return error.MonitorLookupFailed;
            break :blk monitorInfo(monitor) orelse return error.MonitorInfoFailed;
        },
        .all => allMonitorsInfo() orelse return error.MonitorLookupFailed,
    };
    const dims: configpkg.Config.QuickTerminalSize.Dimensions = .{
        .width = @intCast(@max(1, mi.work_area.width())),
        .height = @intCast(@max(1, mi.work_area.height())),
    };
    const resolved_size = quickTerminalSizeForGeometry(
        self.config.@"quick-terminal-size",
        self.config.@"quick-terminal-position",
        dims,
    );
    qt_cfg.size = resolved_size.primary;
    qt_cfg.size_secondary = resolved_size.secondary;

    const end = win32_quick_terminal.computeEndRect(qt_cfg, mi);
    const start = win32_quick_terminal.computeStartRect(qt_cfg, mi);
    const duration_ms = win32_quick_terminal.animationDurationMs(qt_cfg.animation_duration_s);
    if (!animate or duration_ms == 0 or rectEqual(start, end)) {
        if (getHost(hwnd)) |host| host.cancelQuickTerminalAnimation();
        setQuickTerminalRect(hwnd, end);
        return;
    }

    const host = getHost(hwnd) orelse {
        setQuickTerminalRect(hwnd, end);
        return;
    };

    const effective_duration_ms = host.effectiveTweenDuration(duration_ms);
    if (effective_duration_ms == 0) {
        host.cancelQuickTerminalAnimation();
        setQuickTerminalRect(hwnd, end);
        return;
    }

    host.cancelQuickTerminalAnimation();
    setQuickTerminalRect(hwnd, start);
    if (host.addTween(
        0.0,
        1.0,
        effective_duration_ms,
        (win32_theme.ThemeMotion{}).easing_decelerate,
    )) |id| {
        host.quick_terminal_animation = .{
            .id = id,
            .start = start,
            .end = end,
        };
    } else {
        host.cancelQuickTerminalAnimation();
        setQuickTerminalRect(hwnd, end);
    }
}

pub const QuickTerminalAnimation = struct {
    id: win32_tween.TweenId,
    start: RECT,
    end: RECT,
};

pub fn cancelQuickTerminalAnimation(self: *Host) void {
    if (self.quick_terminal_animation) |anim| {
        self.tween_sched.cancel(anim.id);
        self.quick_terminal_animation = null;
        if (self.tween_sched.isEmpty()) self.killTweenTimer();
    }
}

pub const QuickTerminalGeometrySize = struct {
    primary: win32_quick_terminal.SizePercent,
    secondary: ?win32_quick_terminal.SizePercent,
};

pub fn quickTerminalSizeForGeometry(
    qts: configpkg.Config.QuickTerminalSize,
    position: configpkg.Config.QuickTerminalPosition,
    dims: configpkg.Config.QuickTerminalSize.Dimensions,
) QuickTerminalGeometrySize {
    if (position == .center and dims.width < dims.height) {
        return .{
            .primary = if (qts.secondary) |value| sizeToGeometry(value) else .{ .pixels = 400 },
            .secondary = if (qts.primary) |value| sizeToGeometry(value) else .{ .pixels = 800 },
        };
    }

    return .{
        .primary = if (qts.primary) |value|
            sizeToGeometry(value)
        else
            .{ .pixels = if (position == .center) 800 else 400 },
        .secondary = if (qts.secondary) |value|
            sizeToGeometry(value)
        else if (position == .center)
            .{ .pixels = 400 }
        else
            null,
    };
}

pub fn sizeToGeometry(sz: configpkg.Config.QuickTerminalSize.Size) win32_quick_terminal.SizePercent {
    return switch (sz) {
        .percentage => |v| .{ .percent = v },
        .pixels => |v| .{ .pixels = v },
    };
}

/// A QT rect is computed in physical pixels. WM_DPICHANGED still updates
/// fonts/layout during this call, but must not substitute its suggested size.
pub fn setQuickTerminalRect(hwnd: HWND, rect: RECT) void {
    const host = getHost(hwnd);
    const was_placing = if (host) |v| v.quick_terminal_placing else false;
    if (host) |v| v.quick_terminal_placing = true;
    defer if (host) |v| {
        v.quick_terminal_placing = was_placing;
    };
    const dpi_before = sys.GetDpiForWindow(hwnd);
    _ = sys.SetWindowPos(hwnd, HWND_TOPMOST, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOACTIVATE);
    // Settle the computed rectangle after nested DPI scale/layout updates.
    if (sys.GetDpiForWindow(hwnd) != dpi_before) {
        _ = sys.SetWindowPos(hwnd, HWND_TOPMOST, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, c.SWP_NOACTIVATE);
    }
}

test "win32 DPI suggestions preserve a quick terminal tween but resize ordinary moves" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const previous_dpi_context = sys.SetThreadDpiAwarenessContext(-4);
    defer _ = sys.SetThreadDpiAwarenessContext(previous_dpi_context);
    const core = try CoreApp.create(std.testing.allocator);
    defer core.destroy();
    var app: App = undefined;
    try app.init(core, .{ .safe_mode = true });
    const hinstance = app.hinstance;
    defer {
        app.terminate();
        _ = sys.UnregisterClassW(host_class_name, hinstance);
        _ = sys.UnregisterClassW(palette_list_class_name, hinstance);
        _ = sys.UnregisterClassW(scrollbar_class_name, hinstance);
    }
    const host = try app.createHost(std.unicode.utf8ToUtf16LeStringLiteral(""), &app.config, .{ .quick_terminal = true });
    const hwnd = host.hwnd.?;
    var before: RECT = undefined;
    try std.testing.expect(sys.GetWindowRect(hwnd, &before) != 0);
    const suggested: RECT = .{ .left = before.left + 40, .top = before.top + 30, .right = before.left + 40 + 1600, .bottom = before.top + 30 + 1000 };
    // DefWindowProc caps the tracking size on small/headless displays. Use
    // a direct native placement as the ordinary-move oracle, rather than
    // assuming this monitor permits the requested physical dimensions.
    try std.testing.expect(sys.SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    var ordinary: RECT = undefined;
    try std.testing.expect(sys.GetWindowRect(hwnd, &ordinary) != 0);
    // Creation can also permit an oversized rect that a subsequent move
    // would cap. Establish and read back a smaller native starting rect.
    try std.testing.expect(sys.SetWindowPos(hwnd, null, before.left, before.top, @divTrunc(ordinary.right - ordinary.left, 2), @divTrunc(ordinary.bottom - ordinary.top, 2), c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    try std.testing.expect(sys.GetWindowRect(hwnd, &before) != 0);
    try std.testing.expect(!rectEqual(before, ordinary));
    const param: LPARAM = @bitCast(@intFromPtr(&suggested));
    // A delivered DPI message between tween frames must not override the
    // physical dimensions. This reaches the native handler even when the
    // OS disables animation on a hidden desktop.
    host.quick_terminal_animation = .{ .id = 1, .start = before, .end = before };
    _ = hostWindowProc(hwnd, c.WM_DPICHANGED, 0, param);
    var actual: RECT = undefined;
    try std.testing.expect(sys.GetWindowRect(hwnd, &actual) != 0);
    try std.testing.expectEqualDeep(before, actual);
    host.quick_terminal_animation = null;
    // A user move of that same QT still follows the ordinary DPI policy.
    _ = hostWindowProc(hwnd, c.WM_DPICHANGED, 0, param);
    try std.testing.expect(sys.GetWindowRect(hwnd, &actual) != 0);
    try std.testing.expectEqualDeep(ordinary, actual);
    // So does a restored window's saved rect while it is being applied.
    try std.testing.expect(sys.SetWindowPos(hwnd, null, before.left, before.top, before.right - before.left, before.bottom - before.top, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
    host.restore_placing = true;
    _ = hostWindowProc(hwnd, c.WM_DPICHANGED, 0, param);
    try std.testing.expect(sys.GetWindowRect(hwnd, &actual) != 0);
    try std.testing.expectEqualDeep(before, actual);
    host.restore_placing = false;
    try std.testing.expect(!host.quick_terminal_placing);
    try std.testing.expect(sys.IsWindowVisible(hwnd) == 0);
}

const QuickTerminalCreateCounter = struct {
    var calls: usize = 0;
    var host_id: ?u32 = null;

    fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, opts: SurfaceInitOptions) anyerror!*Surface {
        calls += 1;
        host_id = opts.host_id;
        return error.TestWindowCreateFailed;
    }
};

test "win32 toggle_quick_terminal follows its host after the first pane is gone" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: QuickTerminalToggleFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            // Only the pane the window was created with ever carried the
            // per-surface flag. This tab was opened in the quick terminal
            // later, so its surface is not flagged, but its host is.
            QuickTerminalCreateCounter.calls = 0;
            fixture.app.test_create_window_surface = &QuickTerminalCreateCounter.createSurface;

            try std.testing.expect(fixture.visible());
            try fixture.app.toggleQuickTerminal();
            try std.testing.expect(!fixture.visible());
            try std.testing.expect(!fixture.surface.window_visible);
            try fixture.app.toggleQuickTerminal();
            try std.testing.expect(fixture.visible());
            try std.testing.expect(fixture.surface.window_visible);
            // A second quick terminal was never made.
            try std.testing.expectEqual(@as(usize, 0), QuickTerminalCreateCounter.calls);
            try std.testing.expectEqual(@as(usize, 1), fixture.app.registry.hosts.items.len);
        }
    }.body);
}

/// Stands in for the tab `toggleQuickTerminal` opens in an empty quick
/// terminal host: `fixture.fresh`, inserted as the host's only tab.
const QuickTerminalFreshTab = struct {
    var fixture: *QuickTerminalToggleFixture = undefined;
    var calls: usize = 0;
    var host_id: ?u32 = null;

    fn createSurface(app: *App, _: *const configpkg.Config, _: LPCWSTR, opts: SurfaceInitOptions) anyerror!*Surface {
        calls += 1;
        host_id = opts.host_id;
        const surface = &fixture.fresh;
        var prepared = (try app.prepareShellSurfaceCreate(&fixture.host, opts)).?;
        defer prepared.deinit();
        try app.registry.addWindow(app.core_app.alloc, surface);
        try fixture.host.tabs.insert(
            app.core_app.alloc,
            0,
            try Tab.init(app.core_app.alloc, fixture.host.nextTabId(), surface),
        );
        try prepared.commit(&app.shell_runtime);
        surface.shell_id = prepared.created.pane;
        surface.shell_committed = true;
        fixture.host.tabs.items[0].shell_id = prepared.created.tab;
        // Surface.init leaves the audit to the caller that shows the tab.
        app.shell_audit_after_activation = true;
        return surface;
    }
};

test "win32 toggle_quick_terminal opens a fresh floating tab instead of showing one detached for undo" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: QuickTerminalToggleFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            // `close_tab:this` on the only tab keeps the host and the
            // surface for undo, and nothing in the host shows it.
            fixture.app.shell_runtime_initialized = true;
            var window = try fixture.app.shell_runtime.prepare(.create_window);
            defer window.deinit();
            try window.commit(&fixture.app.shell_runtime);
            fixture.host.shell_id = window.created.window;
            var close = try fixture.app.shell_runtime.prepare(.{ .detach_tab = window.created.tab.? });
            defer close.deinit();
            try close.commit(&fixture.app.shell_runtime);
            var detached = fixture.host.tabs.orderedRemove(0);
            defer detached.deinit();
            fixture.surface.window_visible = false;

            QuickTerminalFreshTab.fixture = &fixture;
            QuickTerminalFreshTab.calls = 0;
            QuickTerminalFreshTab.host_id = null;
            fixture.app.test_create_window_surface = &QuickTerminalFreshTab.createSurface;

            // On screen and empty, the toggle dismisses it.
            try fixture.app.toggleQuickTerminal();
            try std.testing.expect(!fixture.visible());
            try std.testing.expectEqual(@as(usize, 0), QuickTerminalFreshTab.calls);

            // Dismissed, it opens a fresh tab and shows that, never the
            // surface that was detached.
            defer appendOwnedString(std.testing.allocator, &fixture.host.cached_window_title, null) catch unreachable;
            try fixture.app.toggleQuickTerminal();
            try std.testing.expectEqual(@as(usize, 1), QuickTerminalFreshTab.calls);
            try std.testing.expectEqual(@as(?u32, fixture.host.id), QuickTerminalFreshTab.host_id);
            try std.testing.expect(!fixture.surface.window_visible);
            try std.testing.expect(fixture.visible());
            try std.testing.expect(fixture.fresh.window_visible);
            try std.testing.expect(fixture.host.activeSurface() == &fixture.fresh);
            // Passive showing bypasses activateSurface, but must complete
            // the pending structural audit before returning to the pump.
            try std.testing.expect(!fixture.app.shell_audit_after_activation);
            try fixture.app.validateShellNativeMapping();
            // The window floats with the tab it shows, so a tab switch or
            // undo does not drop it below other windows.
            try std.testing.expect(fixture.fresh.topmost);
        }
    }.body);
}

/// What a quick terminal toggle hands `createWindowSurface`, for the
/// `default-profile` test: the launch key, the program, the profile's
/// variable and the pinned directory.
const QuickTerminalDefaultProfile = struct {
    /// Copies: the config is freed when the toggle returns.
    var arena: std.heap.ArenaAllocator = undefined;
    var key: ?[]const u8 = null;
    var program: ?[]const u8 = null;
    var mode: ?[]const u8 = null;
    var dir: ?[]const u8 = null;

    fn see(config: *const configpkg.Config, opts: SurfaceInitOptions) !void {
        const a = arena.allocator();
        key = if (opts.launch.key) |value| try a.dupe(u8, value) else null;
        program = try a.dupe(u8, config.command.?.direct[0]);
        mode = if (config.env.map.get("MODE")) |value| try a.dupe(u8, value) else null;
        dir = if (config.@"working-directory") |wd| switch (wd) {
            .path => |path| try a.dupe(u8, path),
            else => null,
        } else null;
    }

    fn fresh(app: *App, config: *const configpkg.Config, title: LPCWSTR, opts: SurfaceInitOptions) anyerror!*Surface {
        try see(config, opts);
        return try QuickTerminalFreshTab.createSurface(app, config, title, opts);
    }

    fn create(_: *App, config: *const configpkg.Config, _: LPCWSTR, opts: SurfaceInitOptions) anyerror!*Surface {
        try see(config, opts);
        try std.testing.expect(opts.host_id == null);
        return error.TestWindowCreateFailed;
    }
};

test "win32 toggle_quick_terminal runs default-profile in a new window and a fresh tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: QuickTerminalToggleFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            const alloc = fixture.app.core_app.alloc;
            const arena = fixture.app.config._arena.?.allocator();
            try fixture.app.config.@"profile-command".parseCLI(arena, "py: cmd.exe /k py");
            try fixture.app.config.@"profile-env".parseCLI(arena, "py: MODE=profile");
            try fixture.app.config.@"profile-working-directory".parseCLI(arena, "py: D:\\pinned");
            fixture.app.config.@"default-profile" = "py";
            try fixture.app.config.finalize();
            try std.testing.expectEqualStrings("user:py", if (configpkg.pane_launch.defaultProfile(&fixture.app.config)) |profile| profile.key else "");
            QuickTerminalDefaultProfile.arena = .init(std.testing.allocator);
            defer QuickTerminalDefaultProfile.arena.deinit();

            // An empty quick terminal host, as the fresh-tab test makes it.
            fixture.app.shell_runtime_initialized = true;
            var window = try fixture.app.shell_runtime.prepare(.create_window);
            defer window.deinit();
            try window.commit(&fixture.app.shell_runtime);
            fixture.host.shell_id = window.created.window;
            var close = try fixture.app.shell_runtime.prepare(.{ .detach_tab = window.created.tab.? });
            defer close.deinit();
            try close.commit(&fixture.app.shell_runtime);
            var detached = fixture.host.tabs.orderedRemove(0);
            defer detached.deinit();
            fixture.surface.window_visible = false;
            try fixture.app.toggleQuickTerminal();
            try std.testing.expect(!fixture.visible());

            // The fresh tab it opens is a fresh pane (`pane_launch.prepare`):
            // the profile in its pinned directory, whose key the tab keeps.
            QuickTerminalFreshTab.fixture = &fixture;
            QuickTerminalFreshTab.calls = 0;
            QuickTerminalDefaultProfile.key = null;
            fixture.app.test_create_window_surface = &QuickTerminalDefaultProfile.fresh;
            defer appendOwnedString(alloc, &fixture.host.cached_window_title, null) catch unreachable;
            defer appendOwnedString(alloc, &fixture.fresh.launch_profile_key, null) catch unreachable;
            try fixture.app.toggleQuickTerminal();
            try std.testing.expectEqual(@as(usize, 1), QuickTerminalFreshTab.calls);
            try std.testing.expectEqualStrings("user:py", QuickTerminalDefaultProfile.key orelse "");
            try std.testing.expectEqualStrings("cmd.exe", QuickTerminalDefaultProfile.program orelse "");
            try std.testing.expectEqualStrings("profile", QuickTerminalDefaultProfile.mode orelse "");
            try std.testing.expectEqualStrings("D:\\pinned", QuickTerminalDefaultProfile.dir orelse "");
            try std.testing.expectEqualStrings("user:py", fixture.fresh.launch_profile_key orelse "");

            // With no quick terminal yet, the window it creates is one too.
            fixture.host.quick_terminal = false;
            defer fixture.host.quick_terminal = true;
            QuickTerminalDefaultProfile.key = null;
            fixture.app.test_create_window_surface = &QuickTerminalDefaultProfile.create;
            try std.testing.expectError(error.TestWindowCreateFailed, fixture.app.toggleQuickTerminal());
            try std.testing.expectEqualStrings("user:py", QuickTerminalDefaultProfile.key orelse "");
            try std.testing.expectEqualStrings("cmd.exe", QuickTerminalDefaultProfile.program orelse "");
            try std.testing.expectEqualStrings("profile", QuickTerminalDefaultProfile.mode orelse "");
            try std.testing.expectEqualStrings("D:\\pinned", QuickTerminalDefaultProfile.dir orelse "");
            // The app config is left as it was.
            try std.testing.expect(fixture.app.config.env.map.get("MODE") == null);
        }
    }.body);
}

test "win32 toggle_quick_terminal keeps a pane a zoom hides out of view" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: QuickTerminalToggleFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            // Two panes in the one tab, the first zoomed.
            const inserted = try SplitTreeSurface.init(std.testing.allocator, &fixture.fresh);
            defer {
                var cleanup = inserted;
                cleanup.deinit();
            }
            const tab = &fixture.host.tabs.items[0];
            const next_tree = try tab.tree.split(std.testing.allocator, .root, .right, 0.5, &inserted);
            tab.tree.deinit();
            tab.tree = next_tree;
            tab.focused = tab.findHandle(&fixture.surface) orelse tab.focused;
            tab.tree.zoom(tab.findHandle(&fixture.surface));
            fixture.fresh.window_visible = false;

            try fixture.app.toggleQuickTerminal();
            try fixture.app.toggleQuickTerminal();
            try std.testing.expect(fixture.surface.window_visible);
            try std.testing.expect(!fixture.fresh.window_visible);
        }
    }.body);
}

test "win32 quick-terminal-autohide hides the quick terminal host, not a flagged pane" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: QuickTerminalToggleFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            fixture.app.config.@"quick-terminal-autohide" = true;
            const hwnd = fixture.host.hwnd.?;
            setWindowData(hwnd, &fixture.host);
            defer setWindowData(hwnd, null);

            try std.testing.expect(fixture.visible());
            _ = hostWindowProc(hwnd, c.WM_ACTIVATE, c.WA_INACTIVE, 0);
            try std.testing.expect(!fixture.visible());
        }
    }.body);
}

test "win32 toggle_visibility does not show a quick terminal the user dismissed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: QuickTerminalToggleFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            // An ordinary window beside it. Neither host has anything to
            // activate once the windows are back, since `other` has no tab
            // and the quick terminal's surface has no window.
            try fixture.app.registry.addHost(std.testing.allocator, &fixture.other);
            // The quick terminal is dismissed by its own toggle.
            _ = sys.ShowWindow(fixture.host.hwnd.?, c.SW_HIDE);

            try std.testing.expect(try fixture.app.performAction(.app, .toggle_visibility, {}));
            try std.testing.expect(!fixture.visible());
            try std.testing.expect(!fixture.otherVisible());
            try std.testing.expect(try fixture.app.performAction(.app, .toggle_visibility, {}));
            try std.testing.expect(fixture.otherVisible());
            try std.testing.expect(!fixture.visible());

            // One that was on screen when the windows were hidden comes back
            // with them. (Its tab is detached first: laying out a tab needs
            // the chrome windows this fixture does not create.)
            var detached = fixture.host.tabs.orderedRemove(0);
            defer detached.deinit();
            _ = sys.ShowWindow(fixture.host.hwnd.?, c.SW_SHOWNOACTIVATE);
            try std.testing.expect(try fixture.app.performAction(.app, .toggle_visibility, {}));
            try std.testing.expect(!fixture.visible());
            try std.testing.expect(!fixture.otherVisible());
            try std.testing.expect(try fixture.app.performAction(.app, .toggle_visibility, {}));
            try std.testing.expect(fixture.visible());
            try std.testing.expect(fixture.otherVisible());

            // The windows are hidden, then something shows one of them alone
            // and clears `windows_hidden`, as the quick terminal's own toggle
            // does. Hiding them again must not forget the ordinary window
            // that is still waiting to come back.
            try std.testing.expect(try fixture.app.performAction(.app, .toggle_visibility, {}));
            try std.testing.expect(!fixture.visible() and !fixture.otherVisible());
            _ = sys.ShowWindow(fixture.host.hwnd.?, c.SW_SHOWNOACTIVATE);
            // What `WM_SHOWWINDOW` does on the real host window.
            fixture.host.hidden_by_toggle = false;
            fixture.app.windows_hidden = false;
            try std.testing.expect(try fixture.app.performAction(.app, .toggle_visibility, {}));
            try std.testing.expect(!fixture.visible() and !fixture.otherVisible());
            try std.testing.expect(try fixture.app.performAction(.app, .toggle_visibility, {}));
            try std.testing.expect(fixture.visible());
            try std.testing.expect(fixture.otherVisible());
        }
    }.body);
}

test "win32 showing a host window by any other means ends its wait for toggle_visibility" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: QuickTerminalToggleFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            const hwnd = fixture.other.hwnd.?;
            setWindowData(hwnd, &fixture.other);
            defer setWindowData(hwnd, null);

            fixture.other.hideForToggle();
            try std.testing.expect(fixture.other.hidden_by_toggle);
            // Hiding it again keeps the mark: it is not on screen to read.
            fixture.other.hideForToggle();
            try std.testing.expect(fixture.other.hidden_by_toggle);

            _ = hostWindowProc(hwnd, c.WM_SHOWWINDOW, 0, 0);
            try std.testing.expect(fixture.other.hidden_by_toggle);
            _ = hostWindowProc(hwnd, c.WM_SHOWWINDOW, 1, 0);
            try std.testing.expect(!fixture.other.hidden_by_toggle);
        }
    }.body);
}

pub fn monitorInfo(monitor: sys.HMONITOR) ?win32_quick_terminal.MonitorInfo {
    var info: MONITORINFO = .{
        .cbSize = @sizeOf(MONITORINFO),
        .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .dwFlags = 0,
    };
    if (sys.GetMonitorInfoW(monitor, &info) == 0) return null;

    return .{
        .work_area = .{
            .left = info.rcWork.left,
            .top = info.rcWork.top,
            .right = info.rcWork.right,
            .bottom = info.rcWork.bottom,
        },
        .full_rect = .{
            .left = info.rcMonitor.left,
            .top = info.rcMonitor.top,
            .right = info.rcMonitor.right,
            .bottom = info.rcMonitor.bottom,
        },
    };
}

pub const PrimaryMonitorSearch = struct {
    found: ?sys.HMONITOR = null,
};

pub fn primaryMonitorEnumProc(
    monitor: sys.HMONITOR,
    _: HDC,
    _: *RECT,
    data: LPARAM,
) callconv(.winapi) BOOL {
    const search: *PrimaryMonitorSearch = @ptrFromInt(@as(usize, @bitCast(data)));
    var info: MONITORINFO = .{
        .cbSize = @sizeOf(MONITORINFO),
        .rcMonitor = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .rcWork = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .dwFlags = 0,
    };
    if (sys.GetMonitorInfoW(monitor, &info) == 0) return 1;
    if ((info.dwFlags & c.MONITORINFOF_PRIMARY) == 0) return 1;
    search.found = monitor;
    return 0;
}

pub fn primaryMonitor() ?sys.HMONITOR {
    var search: PrimaryMonitorSearch = .{};
    _ = sys.EnumDisplayMonitors(
        null,
        null,
        primaryMonitorEnumProc,
        @as(LPARAM, @bitCast(@intFromPtr(&search))),
    );
    return search.found orelse sys.MonitorFromPoint(.{ .x = 0, .y = 0 }, c.MONITOR_DEFAULTTOPRIMARY);
}

pub const AllMonitorsSearch = struct {
    found: bool = false,
    failed: bool = false,
    info: win32_quick_terminal.MonitorInfo = undefined,
};

pub fn isVisibleMonitorInfo(info: win32_quick_terminal.MonitorInfo) bool {
    return info.full_rect.width() > 0 and info.full_rect.height() > 0 and
        info.work_area.width() > 0 and info.work_area.height() > 0;
}

pub fn allMonitorsEnumProc(
    monitor: sys.HMONITOR,
    _: HDC,
    _: *RECT,
    data: LPARAM,
) callconv(.winapi) BOOL {
    const search: *AllMonitorsSearch = @ptrFromInt(@as(usize, @bitCast(data)));
    const info = monitorInfo(monitor) orelse {
        log.warn("quick-terminal-screen=all: failed to query monitor info", .{});
        search.failed = true;
        return 0;
    };
    if (!isVisibleMonitorInfo(info)) return 1;
    if (!search.found) {
        search.info = info;
        search.found = true;
        return 1;
    }
    const monitors = [_]win32_quick_terminal.MonitorInfo{ search.info, info };
    search.info = win32_quick_terminal.unionMonitors(&monitors);
    return 1;
}

pub fn allMonitorsInfo() ?win32_quick_terminal.MonitorInfo {
    var search: AllMonitorsSearch = .{};
    if (sys.EnumDisplayMonitors(
        null,
        null,
        allMonitorsEnumProc,
        @as(LPARAM, @bitCast(@intFromPtr(&search))),
    ) == 0) return null;
    if (search.failed) return null;
    if (!search.found) return null;
    return search.info;
}

test "win32 quick terminal size adapter preserves primary and secondary axes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const size: configpkg.Config.QuickTerminalSize = .{
        .primary = .{ .percentage = 50 },
        .secondary = .{ .pixels = 640 },
    };
    const resolved = quickTerminalSizeForGeometry(
        size,
        .center,
        .{ .width = 1920, .height = 1080 },
    );
    try std.testing.expectEqual(
        win32_quick_terminal.SizePercent{ .percent = 50 },
        resolved.primary,
    );
    try std.testing.expectEqual(
        win32_quick_terminal.SizePercent{ .pixels = 640 },
        resolved.secondary.?,
    );
}

test "win32 quick terminal default size matches core fixed-pixel defaults" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const top = quickTerminalSizeForGeometry(.{}, .top, .{ .width = 1920, .height = 1080 });
    try std.testing.expectEqual(
        win32_quick_terminal.SizePercent{ .pixels = 400 },
        top.primary,
    );
    try std.testing.expectEqual(@as(?win32_quick_terminal.SizePercent, null), top.secondary);

    const landscape = quickTerminalSizeForGeometry(.{}, .center, .{ .width = 1920, .height = 1080 });
    try std.testing.expectEqual(win32_quick_terminal.SizePercent{ .pixels = 800 }, landscape.primary);
    try std.testing.expectEqual(win32_quick_terminal.SizePercent{ .pixels = 400 }, landscape.secondary.?);

    const portrait = quickTerminalSizeForGeometry(.{}, .center, .{ .width = 1080, .height = 1920 });
    try std.testing.expectEqual(win32_quick_terminal.SizePercent{ .pixels = 400 }, portrait.primary);
    try std.testing.expectEqual(win32_quick_terminal.SizePercent{ .pixels = 800 }, portrait.secondary.?);
}

/// The inactive host's WM_ACTIVATE autohide branch.
pub fn autohideQuickTerminal(v: *Host, hwnd: HWND) void {
    if (v.quick_terminal and v.app.config.@"quick-terminal-autohide") {
        if (sys.IsWindowVisible(hwnd) != 0) App.hideQuickTerminalHost(v);
    }
}
