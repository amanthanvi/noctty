//! Shared Win32 test fixtures. Production runtime dependencies are bound
//! explicitly by win32.zig so the runtime's implementation stays private.
const std = @import("std");
const Allocator = std.mem.Allocator;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const win32_settings = @import("../win32_settings.zig");
const win32_link_preview = @import("../win32_link_preview.zig");
const win32_compositor_native = @import("../win32_compositor_native.zig");
const win32_compositor = @import("../win32_compositor.zig");
const win32_shell = @import("../win32_shell.zig");
const win32_palette = @import("../win32_palette.zig");
const win32_undo = @import("../win32_undo.zig");
const win32_search_bar = @import("../win32_search_bar.zig");
const win32_surface_drop_target = @import("../win32_surface_drop_target.zig");
const types = @import("../win32_types.zig");
const sys = @import("sys.zig");
const c = @import("consts.zig");
const HWND = types.HWND;
const BOOL = types.BOOL;
const UINT = types.UINT;
const WPARAM = types.WPARAM;
const LPARAM = types.LPARAM;
const LRESULT = types.LRESULT;
const RECT = sys.RECT;
const WINDOWPOS = sys.WINDOWPOS;
const WINDOWPLACEMENT = sys.WINDOWPLACEMENT;

/// Bind the private runtime types and operations once, keeping one fixture
/// implementation for tests that remain in win32.zig and tests moved later.
pub fn Fixtures(comptime runtime: anytype) type {
    return struct {
        const App = runtime.App;
        const Host = runtime.Host;
        const Surface = runtime.Surface;
        const Tab = runtime.Tab;
        const SurfaceInitStage = runtime.SurfaceInitStage;
        const PaletteItem = runtime.PaletteItem;
        const PalettePayload = runtime.PalettePayload;
        const PaletteRanked = runtime.PaletteRanked;
        const palette_catalog_capacity = runtime.palette_catalog_capacity;
        const WS_OVERLAPPEDWINDOW = runtime.WS_OVERLAPPEDWINDOW;
        const class_name = runtime.class_name;
        const host_class_name = runtime.host_class_name;
        const palette_list_class_name = runtime.palette_list_class_name;
        const scrollbar_class_name = runtime.scrollbar_class_name;
        const prompt_label_class = runtime.prompt_label_class;
        const lastError = runtime.lastError;
        const appendOwnedString = runtime.appendOwnedString;
        const surfaceDropPayloadCallback = runtime.surfaceDropPayloadCallback;
        const workspaceRectToScreen = runtime.workspaceRectToScreen;
        const monitorInfo = runtime.monitorInfo;
        const settingsAppIconThunk = runtime.settingsAppIconThunk;
        const settingsChromeBgThunk = runtime.settingsChromeBgThunk;
        const settingsConfigProblemsThunk = runtime.settingsConfigProblemsThunk;
        const settingsConfigRevisionThunk = runtime.settingsConfigRevisionThunk;
        const settingsCurrentConfigThunk = runtime.settingsCurrentConfigThunk;
        const settingsCustomUiaProvidersEnabledThunk = runtime.settingsCustomUiaProvidersEnabledThunk;
        const settingsDeferUiaDisconnectThunk = runtime.settingsDeferUiaDisconnectThunk;
        const settingsFailureDetailThunk = runtime.settingsFailureDetailThunk;
        const settingsHighContrastThunk = runtime.settingsHighContrastThunk;
        const settingsMaskedKeysThunk = runtime.settingsMaskedKeysThunk;
        const settingsNotifyConflictThunk = runtime.settingsNotifyConflictThunk;
        const settingsNotifySuccessThunk = runtime.settingsNotifySuccessThunk;
        const settingsOnClosedThunk = runtime.settingsOnClosedThunk;
        const settingsOpenInEditorThunk = runtime.settingsOpenInEditorThunk;
        const settingsOwnerWindowThunk = runtime.settingsOwnerWindowThunk;
        const settingsPreviewFieldThunk = runtime.settingsPreviewFieldThunk;
        const settingsProfileChoicesThunk = runtime.settingsProfileChoicesThunk;
        const settingsReconcileDiskThunk = runtime.settingsReconcileDiskThunk;
        const settingsSaveAndReloadThunk = runtime.settingsSaveAndReloadThunk;
        const settingsSaveTargetThunk = runtime.settingsSaveTargetThunk;
        const settingsTextPrimaryThunk = runtime.settingsTextPrimaryThunk;
        const settingsThemeColorsThunk = runtime.settingsThemeColorsThunk;

        /// Runs `body` on a thread attached to a desktop of its own, so a test can
        /// show, hide and minimize windows without touching the user's desktop.
        /// `SetThreadDesktop` fails on a thread that owns a window, so the runner's
        /// own thread cannot do it (AGENTS.md 2026-10-06).
        pub fn runOnHiddenDesktop(comptime body: anytype) !void {
            const Desktop = struct {
                extern "user32" fn CreateDesktopW(name: [*:0]const u16, device: ?*anyopaque, mode: ?*anyopaque, flags: u32, access: u32, attributes: ?*anyopaque) callconv(.winapi) ?*anyopaque;
                extern "user32" fn SetThreadDesktop(desktop: *anyopaque) callconv(.winapi) BOOL;
                extern "user32" fn CloseDesktop(desktop: *anyopaque) callconv(.winapi) BOOL;

                fn run(desktop: *anyopaque, result: *anyerror!void) void {
                    if (SetThreadDesktop(desktop) == 0) {
                        result.* = lastError();
                        return;
                    }
                    body() catch |err| {
                        // The test fails at `return result` on the runner's thread;
                        // this trace shows which check failed.
                        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
                        result.* = err;
                    };
                }
            };
            var name_buf: [80]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "noctty-pkg43-test-{x}-{d}", .{ @intFromPtr(&name_buf), sys.GetTickCount64() });
            const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, name);
            defer std.testing.allocator.free(wide_name);
            const desktop = Desktop.CreateDesktopW(wide_name.ptr, null, null, 0, 0x10000000, null) orelse return error.SkipZigTest;
            defer _ = Desktop.CloseDesktop(desktop);
            var result: anyerror!void = {};
            const thread = try std.Thread.spawn(.{}, Desktop.run, .{ desktop, &result });
            thread.join();
            return result;
        }

        /// A quick terminal host that a test has put on screen, with the pieces a
        /// toggle needs: a registered host, one tab, and the surface that tab shows.
        /// `other` is a second host with a window and no tab, not registered until a
        /// test appends it to `app.hosts`.
        pub const QuickTerminalToggleFixture = struct {
            core_app: CoreApp = undefined,
            app: App = undefined,
            host: Host = undefined,
            other: Host = undefined,
            surface: Surface = undefined,
            /// What `QuickTerminalFreshTab` hands back as a tab created later.
            fresh: Surface = undefined,
            session: TestSession = .{},

            pub fn init(self: *QuickTerminalToggleFixture) !void {
                try self.session.init(.{
                    .core_app = &self.core_app,
                    .app = &self.app,
                    .hosts = &.{
                        .{ .storage = &self.host, .register = true, .next_tab_id = 2 },
                        .{ .storage = &self.other, .id = 2 },
                    },
                    .surfaces = &.{
                        .{ .storage = &self.surface, .host = &self.host, .register = true },
                        .{ .storage = &self.fresh, .host = &self.host, .window_visible = false },
                    },
                    .tabs = &.{.{ .host = &self.host, .surface = &self.surface, .id = 1 }},
                });
                errdefer self.session.deinit();
                // `none` shows the window without the activation machinery, which
                // needs a real chrome the fixture does not have.
                self.app.config.@"quick-terminal-keyboard-interactivity" = .none;
                self.host.quick_terminal = true;
                self.host.hwnd = try createTestHostWindow();
                errdefer _ = sys.DestroyWindow(self.host.hwnd.?);
                // Showing a tab refreshes the chrome, which creates the tab-strip
                // container as a layered child; this manifest-less test binary
                // cannot (AGENTS.md 2026-10-01), so a plain one takes its slot.
                self.host.tab_container_hwnd = try createTestChromeChild(self.host.hwnd.?, prompt_label_class);
                self.other.hwnd = try createTestHostWindow();
                _ = sys.ShowWindow(self.host.hwnd.?, c.SW_SHOWNOACTIVATE);
                _ = sys.ShowWindow(self.other.hwnd.?, c.SW_SHOWNOACTIVATE);
            }

            pub fn deinit(self: *QuickTerminalToggleFixture) void {
                _ = sys.DestroyWindow(self.other.hwnd.?);
                _ = sys.DestroyWindow(self.host.hwnd.?);
                self.session.deinit();
            }

            pub fn visible(self: *const QuickTerminalToggleFixture) bool {
                return sys.IsWindowVisible(self.host.hwnd.?) != 0;
            }

            pub fn otherVisible(self: *const QuickTerminalToggleFixture) bool {
                return sys.IsWindowVisible(self.other.hwnd.?) != 0;
            }
        };

        /// Byte-zeroed storage used only where no valid headless initializer or
        /// declared default exists. The returned value is NOT a valid instance;
        /// reading it before a real value is written is illegal behavior. Palette
        /// counts guard their unused slots, and `core_initialized = false` guards the
        /// inert `CoreSurface` field.
        pub fn uninitializedInertStorage(comptime T: type) T {
            var value: T = undefined;
            @memset(std.mem.asBytes(&value), 0);
            return value;
        }

        /// Headless CoreApp/App/Host/Surface fixture for Win32 action and
        /// structural-history tests. Caller-owned storage keeps the familiar local
        /// names used by assertions while this fixture owns initialized resources and
        /// their teardown. Guarded CoreSurface and unused palette slots are inert
        /// storage, not valid live instances.
        pub const TestSession = struct {
            pub const max_hosts = 4;
            pub const max_surfaces = 12;

            pub const HostOptions = struct {
                storage: *Host,
                id: u32 = 1,
                register: bool = false,
                active_tab: usize = 0,
                next_tab_id: u32 = 1,
            };

            pub const SurfaceOptions = struct {
                storage: *Surface,
                host: ?*Host = null,
                register: bool = false,
                window_visible: bool = true,
                host_active: bool = true,
                window_focused: bool = false,
                undo_allocator: ?Allocator = null,
                free_launch_profile_key_on_deinit: bool = false,
            };

            pub const TabOptions = struct {
                host: *Host,
                surface: *Surface,
                id: u32,
            };

            pub const Options = struct {
                core_app: *CoreApp,
                app: *App,
                hosts: []const HostOptions = &.{},
                surfaces: []const SurfaceOptions = &.{},
                tabs: []const TabOptions = &.{},
                focused: bool = true,
                shell_runtime_initialized: bool = false,
            };

            pub const SurfaceRecord = struct {
                surface: *Surface,
                undo_initialized: bool = true,
                free_launch_profile_key: bool = false,
            };

            allocator: Allocator = std.testing.allocator,
            core_app: ?*CoreApp = null,
            app: ?*App = null,
            core_app_initialized: bool = false,
            app_initialized: bool = false,
            hosts: [max_hosts]?*Host = .{null} ** max_hosts,
            host_count: usize = 0,
            surfaces: [max_surfaces]?SurfaceRecord = .{null} ** max_surfaces,
            surface_count: usize = 0,

            pub fn init(self: *TestSession, options: Options) !void {
                self.* = .{};
                if (options.hosts.len > max_hosts or options.surfaces.len > max_surfaces) {
                    return error.TestSessionCapacityExceeded;
                }

                self.core_app = options.core_app;
                try options.core_app.init(self.allocator);
                self.core_app_initialized = true;
                errdefer self.deinit();
                options.core_app.focused = options.focused;

                const app_config = try configpkg.Config.default(self.allocator);
                options.app.* = .{
                    .core_app = options.core_app,
                    .config = app_config,
                    .hinstance = sys.GetModuleHandleW(null),
                    // These initializers only establish inert model state; they do not
                    // create windows, initialize COM, or start compositor devices.
                    .settings_window = win32_settings.SettingsWindow.init(.{
                        .ctx = @ptrCast(options.app),
                        .alloc = self.allocator,
                        .hinstance = sys.GetModuleHandleW(null),
                        .ownerWindow = &settingsOwnerWindowThunk,
                        .appIcon = &settingsAppIconThunk,
                        .chromeBg = &settingsChromeBgThunk,
                        .textPrimary = &settingsTextPrimaryThunk,
                        .themeColors = &settingsThemeColorsThunk,
                        .highContrast = &settingsHighContrastThunk,
                        .openInEditor = &settingsOpenInEditorThunk,
                        .currentConfig = &settingsCurrentConfigThunk,
                        .saveAndReload = &settingsSaveAndReloadThunk,
                        .configRevision = &settingsConfigRevisionThunk,
                        .previewField = &settingsPreviewFieldThunk,
                        .notifyConflict = &settingsNotifyConflictThunk,
                        .reconcileDisk = &settingsReconcileDiskThunk,
                        .failureDetail = &settingsFailureDetailThunk,
                        .maskedKeys = &settingsMaskedKeysThunk,
                        .saveTarget = &settingsSaveTargetThunk,
                        .configProblems = &settingsConfigProblemsThunk,
                        .profileChoices = &settingsProfileChoicesThunk,
                        .notifySuccess = &settingsNotifySuccessThunk,
                        .customUiaProvidersEnabled = &settingsCustomUiaProvidersEnabledThunk,
                        .deferUiaDisconnect = &settingsDeferUiaDisconnectThunk,
                        .onClosed = &settingsOnClosedThunk,
                    }),
                    .link_hover_tracker = win32_link_preview.HoverTracker.init(),
                    .shell_compositor_driver = win32_compositor_native.NativeDriver.init(self.allocator),
                    .shell_compositor = win32_compositor.Backend.init(.{}, null),
                    .shell_runtime = win32_shell.runtime.Runtime.init(self.allocator),
                    .shell_runtime_initialized = options.shell_runtime_initialized,
                };
                self.app = options.app;
                self.app_initialized = true;

                for (options.hosts) |host_options| {
                    const host = host_options.storage;
                    host.* = .{
                        .app = options.app,
                        .id = host_options.id,
                        .active_tab = host_options.active_tab,
                        .next_tab_id = host_options.next_tab_id,
                        // Item, tagged-payload, and ranked elements have no declared
                        // defaults. Zero counts/catalog guard these invalid slots from
                        // reads until production code overwrites them. Label bytes do
                        // have a valid zero value, so their array uses valid elements.
                        .palette_catalog_items = uninitializedInertStorage([palette_catalog_capacity]PaletteItem),
                        .palette_catalog_payloads = uninitializedInertStorage([palette_catalog_capacity]PalettePayload),
                        .palette_catalog_labels = @splat(@splat(0)),
                        .palette_list_ranked = uninitializedInertStorage([win32_palette.max_ranked]PaletteRanked),
                    };
                    host.tween_sched.init(self.allocator);
                    self.hosts[self.host_count] = host;
                    self.host_count += 1;
                    if (host_options.register) try options.app.hosts.append(self.allocator, host);
                }

                for (options.surfaces) |surface_options| {
                    const surface = surface_options.storage;
                    const undo_allocator = surface_options.undo_allocator orelse self.allocator;
                    surface.* = .{
                        .app = options.app,
                        .host = surface_options.host,
                        .host_id = if (surface_options.host) |host| host.id else 0,
                        .window_visible = surface_options.window_visible,
                        .host_active = surface_options.host_active,
                        .window_focused = surface_options.window_focused,
                        // No valid headless CoreSurface initializer exists. This
                        // byte-zeroed field is NOT a valid CoreSurface;
                        // core_initialized=false guards it, and reading it is illegal
                        // behavior while that guard remains false.
                        .core_surface = uninitializedInertStorage(CoreSurface),
                        .undo_stack = win32_undo.UndoStack.init(undo_allocator),
                        .search_bar = win32_search_bar.SearchBar.init(self.allocator),
                        .drop_target = try win32_surface_drop_target.DropTarget.create(
                            self.allocator,
                            @ptrCast(surface),
                            &surfaceDropPayloadCallback,
                        ),
                    };
                    self.surfaces[self.surface_count] = .{
                        .surface = surface,
                        .free_launch_profile_key = surface_options.free_launch_profile_key_on_deinit,
                    };
                    self.surface_count += 1;
                    if (surface_options.register) try options.app.windows.append(self.allocator, surface);
                }

                for (options.tabs) |tab_options| {
                    try tab_options.host.tabs.append(
                        self.allocator,
                        try runtime.tabInit(self.allocator, tab_options.id, tab_options.surface),
                    );
                }
            }

            pub fn deinitSurfaceUndo(self: *TestSession, surface: *Surface) void {
                for (self.surfaces[0..self.surface_count]) |*maybe_record| {
                    if (maybe_record.*) |*record| {
                        if (record.surface != surface or !record.undo_initialized) continue;
                        record.surface.undo_stack.deinit();
                        record.undo_initialized = false;
                        return;
                    }
                }
            }

            pub fn deinit(self: *TestSession) void {
                var surface_index = self.surface_count;
                while (surface_index > 0) {
                    surface_index -= 1;
                    if (self.surfaces[surface_index]) |*record| {
                        appendOwnedString(self.allocator, &record.surface.key_table_name, null) catch unreachable;
                        if (record.free_launch_profile_key) {
                            if (record.surface.launch_profile_key) |value| self.allocator.free(value);
                            record.surface.launch_profile_key = null;
                        }
                        if (record.undo_initialized) record.surface.undo_stack.deinit();
                        record.surface.search_bar.deinit();
                        if (record.surface.drop_target) |target| target.deinit();
                        record.surface.drop_target = null;
                    }
                }

                var host_index = self.host_count;
                while (host_index > 0) {
                    host_index -= 1;
                    const host = self.hosts[host_index] orelse continue;
                    appendOwnedString(self.allocator, &host.mode_indicator_text, null) catch unreachable;
                    appendOwnedString(self.allocator, &host.config_problems_text, null) catch unreachable;
                    runtime.hostSetBanner(host, .none, null) catch {};
                    runtime.hostClearStructuralHistory(host, .normal);
                    host.structural_undo_entries.deinit(self.allocator);
                    host.structural_redo_entries.deinit(self.allocator);
                    while (host.tabs.items.len > 0) {
                        var tab = host.tabs.orderedRemove(0);
                        runtime.tabDeinit(&tab);
                    }
                    runtime.hostKillTweenTimer(host);
                    host.tween_sched.deinit();
                    host.tabs.deinit(self.allocator);
                }

                if (self.app_initialized) {
                    const app = self.app.?;
                    app.shell_runtime.deinit();
                    runtime.appDropSettingsPreview(app);
                    app.config.deinit();
                    app.hosts.deinit(self.allocator);
                    app.windows.deinit(self.allocator);
                    app.toast_removals.deinit(self.allocator);
                    runtime.appDiscardDeferredOpens(app);
                }
                if (self.core_app_initialized) self.core_app.?.deinit();
                self.* = .{};
            }
        };

        pub fn testWindowStyle(hwnd: HWND) u32 {
            return @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE))));
        }

        /// The hostless app the placement tests' surfaces point at, with only the
        /// fields window placement reads set.
        pub fn placementTestApp() App {
            var app: App = undefined;
            app.os_build = c.OS_BUILD_WIN11_21H2;
            app.config = .{};
            app.hosts = .empty;
            return app;
        }

        /// A hostless surface whose top-level window sits at (`left`, `top`) and is
        /// 640x480, with every field `inheritWindowStateFrom` copies set.
        pub fn placementTestSurface(app: *App, left: i32, top: i32) !Surface {
            var surface: Surface = undefined;
            surface.app = app;
            surface.host = null;
            surface.hwnd = sys.CreateWindowExW(
                0,
                prompt_label_class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                WS_OVERLAPPEDWINDOW,
                left,
                top,
                640,
                480,
                null,
                null,
                sys.GetModuleHandleW(null),
                null,
            ) orelse return lastError();
            surface.decorations_visible = true;
            surface.decorations_visible_overridden = false;
            surface.fullscreen = false;
            surface.topmost = false;
            surface.restore_rect = std.mem.zeroes(RECT);
            surface.restore_placement = std.mem.zeroes(WINDOWPLACEMENT);
            surface.restore_monitor = null;
            surface.default_client_size = null;
            surface.cell_size_pixels = .{ .width = 0, .height = 0 };
            surface.background_opacity_default = 1.0;
            surface.background_opacity_force_opaque = false;
            surface.size_limit = .{ .min_width = 0, .min_height = 0, .max_width = 0, .max_height = 0 };
            return surface;
        }

        /// A started app for tests that create real hosts with `createHost`. Safe
        /// mode starts from the default config rather than the developer's own,
        /// whose tab bar or decoration settings could turn the integrated titlebar
        /// off.
        pub const SafeModeAppFixture = struct {
            core: *CoreApp = undefined,
            app: App = undefined,

            pub fn init(self: *SafeModeAppFixture) !void {
                self.core = try CoreApp.create(std.testing.allocator);
                errdefer self.core.destroy();
                try self.app.init(self.core, .{ .safe_mode = true });
            }

            pub fn deinit(self: *SafeModeAppFixture) void {
                const hinstance = self.app.hinstance;
                self.app.terminate();
                // `createHost` registers these and nothing unregisters them, so a
                // later test could not create a host of its own.
                _ = sys.UnregisterClassW(host_class_name, hinstance);
                _ = sys.UnregisterClassW(palette_list_class_name, hinstance);
                _ = sys.UnregisterClassW(scrollbar_class_name, hinstance);
                self.core.destroy();
            }
        };

        /// An app whose windows run the real `Surface.init`, with stand-ins for the
        /// GL context and the core (`App.test_surface_init_stage`), for the tests of
        /// the state a new window starts in (#496). Its windows show, so a test that
        /// uses it runs on a desktop of its own (`runOnHiddenDesktop`).
        pub const WindowStartTestApp = struct {
            core_app: CoreApp = undefined,
            app: App = undefined,
            session: TestSession = .{},

            /// The newest host window, its rect while it was still hidden, and how
            /// it first appeared: at the first `WM_WINDOWPOSCHANGED` that showed it.
            pub var watched: ?HWND = null;
            pub var hidden_rect: RECT = undefined;
            pub var first_show: ?FirstShow = null;
            pub var previous_proc: ?*const anyopaque = null;
            /// Minimizes the watched window as it first shows, as Windows does to a
            /// process's first show when its launcher asked for a minimized window
            /// (`STARTUPINFO` `SW_SHOWMINNOACTIVE`: `start /min`, a shortcut set to
            /// Run: Minimized).
            pub var minimize_first_show = false;
            /// The client size core init asks a new window for, as it does for a
            /// config with both `window-width` and `window-height`: an `initial_size`
            /// action, which keeps the window where it is. Null leaves a clone where
            /// `createHost` put it and a first window at the fixed rect below.
            pub var initial_size: ?apprt.action.InitialSize = null;

            pub const FirstShow = struct { rect: RECT, zoomed: bool, style: u32 };
            pub const swp_showwindow: UINT = 0x0040;

            pub fn init(self: *WindowStartTestApp) !void {
                try self.session.init(.{ .core_app = &self.core_app, .app = &self.app });
                errdefer self.session.deinit();
                // The apartment the app's UI thread has, on this thread. Without it
                // the full suite (not a filtered run, where the register fails)
                // leaked every pane's drop target: its `RevokeDragDrop` failed with
                // RPC_E_WRONG_THREAD.
                runtime.appInitComApartment(&self.app);
                errdefer if (self.app.com_initialized) sys.OleUninitialize();
                try runtime.appEnsureWindowClass(&self.app);
                self.app.test_surface_init_stage = &stage;
                watched = null;
                first_show = null;
                minimize_first_show = false;
                initial_size = null;
            }

            pub fn deinit(self: *WindowStartTestApp) void {
                self.closeWindows();
                if (self.app.com_initialized) sys.OleUninitialize();
                const instance = self.app.hinstance;
                self.session.deinit();
                // `createHost` registers these and nothing unregisters them.
                _ = sys.UnregisterClassW(class_name, instance);
                _ = sys.UnregisterClassW(host_class_name, instance);
                _ = sys.UnregisterClassW(palette_list_class_name, instance);
                _ = sys.UnregisterClassW(scrollbar_class_name, instance);
            }

            pub fn newest(self: *WindowStartTestApp) *Surface {
                return self.app.windows.items[self.app.windows.items.len - 1];
            }

            /// Closes the window `surface` is in, a pane at a time as closing its
            /// panes does: the last one's teardown destroys and removes the host.
            /// `destroy` unregisters only a surface whose core it stopped.
            pub fn closeWindow(self: *WindowStartTestApp, surface: *Surface) void {
                const host = surface.host.?;
                var left: usize = 16;
                while (left > 0) : (left -= 1) {
                    const pane = for (self.app.windows.items) |other| {
                        if (other.host == host) break other;
                    } else break;
                    self.core_app.deleteSurface(pane);
                    _ = sys.DestroyWindow(pane.hwnd.?);
                }
            }

            pub fn closeWindows(self: *WindowStartTestApp) void {
                var left: usize = 16;
                while (self.app.windows.items.len > 0 and left > 0) : (left -= 1) self.closeWindow(self.newest());
            }

            pub fn stage(surface: *Surface, at: SurfaceInitStage) anyerror!void {
                const host = surface.host.?;
                const hwnd = host.hwnd.?;
                switch (at) {
                    // The test executable has no manifest for the layered tab strip.
                    .gl_context => if (host.tab_container_hwnd == null) {
                        host.tab_container_hwnd = try createTestChromeChild(hwnd, prompt_label_class);
                    },
                    .core_surface => {
                        // A tab of a window that is already open.
                        if (sys.IsWindowVisible(hwnd) != 0) return;
                        // What core init does with `window-width`/`window-height`:
                        // `initial_size` when the test sets one, or else, for a first
                        // window, a fixed rect inside the work area, where a small CI
                        // screen cannot cap it. A clone is otherwise where
                        // `createHost` cascaded it.
                        if (initial_size) |size| {
                            try runtime.surfaceSetInitialSize(surface, size);
                        } else if (surface.app.hosts.items.len == 1) {
                            const monitor = sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return lastError();
                            const work = (monitorInfo(monitor) orelse return lastError()).work_area;
                            if (sys.SetWindowPos(hwnd, null, work.left + 48, work.top + 40, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE) == 0) return lastError();
                        }
                        if (sys.GetWindowRect(hwnd, &hidden_rect) == 0) return lastError();
                        watched = hwnd;
                        first_show = null;
                        previous_proc = @ptrFromInt(@as(usize, @bitCast(sys.SetWindowLongPtrW(
                            hwnd,
                            c.GWLP_WNDPROC,
                            @bitCast(@intFromPtr(&proc)),
                        ))));
                    },
                }
            }

            pub fn proc(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
                var shown = false;
                if (msg == c.WM_WINDOWPOSCHANGED and hwnd == watched and first_show == null) {
                    const pos: *const WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lp)));
                    if (pos.flags & swp_showwindow != 0) {
                        var rect: RECT = undefined;
                        _ = sys.GetWindowRect(hwnd, &rect);
                        first_show = .{
                            .rect = rect,
                            .zoomed = sys.IsZoomed(hwnd) != 0,
                            .style = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE)))),
                        };
                        shown = true;
                    }
                }
                const result = sys.CallWindowProcW(previous_proc, hwnd, msg, wp, lp);
                if (shown and minimize_first_show) _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
                return result;
            }

            pub fn screenRect(hwnd: HWND) !RECT {
                var rect: RECT = undefined;
                if (sys.GetWindowRect(hwnd, &rect) == 0) return lastError();
                return rect;
            }

            /// The rect the window returns to when it is not maximized, in screen
            /// coordinates.
            pub fn normalRect(hwnd: HWND) !RECT {
                var placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT);
                placement.length = @sizeOf(WINDOWPLACEMENT);
                if (sys.GetWindowPlacement(hwnd, &placement) == 0) return lastError();
                return workspaceRectToScreen(placement.rcNormalPosition, (try runtime.surfaceWindowMonitor(hwnd)).info);
            }

            pub fn monitorRect(hwnd: HWND) !RECT {
                return (try runtime.surfaceWindowMonitor(hwnd)).info.rcMonitor;
            }

            pub fn framed(hwnd: HWND) bool {
                const style: u32 = @truncate(@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE))));
                return style & c.WS_CAPTION == c.WS_CAPTION and style & c.WS_POPUP == 0;
            }
        };

        pub fn testHostExStyle(hwnd: HWND) u32 {
            // Same checked cast `applyBackgroundOpacity` uses, so the test reads the
            // ex-style exactly the way production writes it.
            const raw = sys.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
            return @intCast(@as(usize, @bitCast(raw)));
        }

        pub fn testHostIsLayered(hwnd: HWND) bool {
            return (testHostExStyle(hwnd) & c.WS_EX_LAYERED) != 0;
        }

        pub fn testLayeredAlpha(hwnd: HWND) ?u8 {
            var alpha: u8 = 0;
            var flags: u32 = 0;
            if (sys.GetLayeredWindowAttributes(hwnd, null, &alpha, &flags) == 0) return null;
            if ((flags & c.LWA_ALPHA) == 0) return null;
            return alpha;
        }

        pub fn createTestChromeChild(parent: HWND, class: [*:0]const u16) !HWND {
            return sys.CreateWindowExW(
                0,
                class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                c.WS_CHILD | c.WS_VISIBLE,
                0,
                0,
                100,
                24,
                parent,
                null,
                sys.GetModuleHandleW(null),
                null,
            ) orelse lastError();
        }

        pub fn createTestHostWindow() !HWND {
            const hwnd = sys.CreateWindowExW(
                0,
                prompt_label_class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                c.WS_POPUP,
                0,
                0,
                320,
                240,
                null,
                null,
                sys.GetModuleHandleW(null),
                null,
            ) orelse return lastError();
            return hwnd;
        }

        pub fn expectTestChildOrder(parent: HWND, expected: []const HWND) !void {
            var child = sys.GetWindow(parent, c.GW_CHILD);
            for (expected) |want| {
                try std.testing.expectEqual(@as(?HWND, want), child);
                child = sys.GetWindow(child.?, c.GW_HWNDNEXT);
            }
            try std.testing.expectEqual(@as(?HWND, null), child);
        }

        /// Assemble the state `Surface.init` has built by the time it calls
        /// `applyInitialBackgroundOpacity`: a freshly created host window whose
        /// single tab already focuses this surface. That last part is the gate the
        /// fix depends on — without it `activeSharedHostWindowHwnd` returns null
        /// and the call is a silent no-op. Caller owns `host.tabs`.
        pub fn initTestHostWindowFixture(host: *Host, surface: *Surface, hwnd: HWND) !void {
            host.id = 234;
            host.hwnd = hwnd;
            host.tabs = .empty;
            host.active_tab = 0;
            // The caller can only register its own teardown once this returns, so a
            // precondition that fails below would otherwise leak the Tab and its
            // split tree and report an allocator leak on top of the real failure.
            errdefer deinitTestHostWindowFixture(host);

            surface.host = host;
            surface.host_id = host.id;
            // Deliberately null: the layered alpha has to land on the top-level host
            // window, never on the GL child.
            surface.hwnd = null;
            surface.background_opacity_default = 1.0;
            surface.background_opacity_force_opaque = false;

            try host.tabs.append(std.testing.allocator, try runtime.tabInit(std.testing.allocator, 1, surface));

            try std.testing.expectEqual(@as(?*Surface, surface), runtime.hostActiveSurface(host));
            try std.testing.expectEqual(@as(?HWND, hwnd), runtime.surfaceActiveSharedHostWindowHwnd(surface));
            try std.testing.expect(!testHostIsLayered(hwnd));
        }

        pub fn deinitTestHostWindowFixture(host: *Host) void {
            for (host.tabs.items) |*tab| runtime.tabDeinit(tab);
            host.tabs.deinit(std.testing.allocator);
        }
    };
}
