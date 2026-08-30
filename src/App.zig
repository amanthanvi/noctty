//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const Surface = @import("Surface.zig");
const input = @import("input.zig");
const configpkg = @import("config.zig");
const Config = configpkg.Config;
const BlockingQueue = @import("datastruct/main.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");

const log = std.log.scoped(.app);

const SurfaceList = std.ArrayListUnmanaged(*apprt.Surface);

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

/// This is true if the app that Ghostty is in is focused. This may
/// mean that no surfaces (terminals) are focused but the app is still
/// focused, i.e. may an about window. On macOS, this concept is known
/// as the "active" app while focused windows are known as the
/// "main" window.
///
/// This is used to determine if keyboard shortcuts that are non-global
/// should be processed. If the app is not focused, then we don't want
/// to process keyboard shortcuts that are not global.
///
/// This defaults to true since we assume that the app is focused when
/// Ghostty is initialized but a well behaved apprt should call
/// focusEvent to set this to the correct value right away.
focused: bool = true,

/// The last focused surface. This surface may not be valid;
/// you must always call hasSurface to validate it.
focused_surface: ?*Surface = null,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: Mailbox.Queue,

/// The set of font GroupCache instances shared by surfaces with the
/// same font configuration.
font_grid_set: font.SharedGridSet,

// Used to rate limit desktop notifications. Some platforms (notably macOS) will
// run out of resources if desktop notifications are sent too fast and the OS
// will kill Ghostty.
last_notification_time: ?std.time.Instant = null,
last_notification_digest: u64 = 0,

/// The conditional state of the configuration. See the equivalent field
/// in the Surface struct for more information. In this case, this applies
/// to the app-level config and as a default for new surfaces.
config_conditional_state: configpkg.ConditionalState,

/// Set to false once we've created at least one surface. This
/// never goes true again. This can be used by surfaces to determine
/// if they are the first surface.
first: bool = true,

pub const CreateError = Allocator.Error || font.SharedGridSet.InitError;

/// Create a new app instance. This returns a stable pointer to the app
/// instance which is required for callbacks.
pub fn create(alloc: Allocator) CreateError!*App {
    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    try app.init(alloc);
    app.font_grid_set.startDiscoveryPrefetch();
    return app;
}

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
///
/// After calling this function, well behaved apprts should then call
/// `focusEvent` to set the initial focus state of the app.
pub fn init(
    self: *App,
    alloc: Allocator,
) CreateError!void {
    var font_grid_set = try font.SharedGridSet.init(alloc);
    errdefer font_grid_set.deinit();

    self.* = .{
        .alloc = alloc,
        .surfaces = .{},
        .mailbox = .{},
        .font_grid_set = font_grid_set,
        .config_conditional_state = .{},
    };
}

pub fn deinit(self: *App) void {
    while (self.mailbox.pop()) |message| message.deinit(self.alloc);

    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);

    // Clean up our font group cache
    // We should have zero items in the grid set at this point because
    // destroy only gets called when the app is shutting down and this
    // should gracefully close all surfaces.
    assert(self.font_grid_set.count() == 0);
    self.font_grid_set.deinit();
}

pub fn destroy(self: *App) void {
    // Deinitialize the app
    self.deinit();

    // Free the app memory
    self.alloc.destroy(self);
}

test "App create overlaps Windows font discovery with runtime startup" {
    if (comptime builtin.target.os.tag != .windows or
        !@hasDecl(font.Discover, "refresh")) return;

    const app = try create(std.testing.allocator);
    defer app.destroy();
    try std.testing.expect(app.font_grid_set.discoveryPrefetchStarted());
}

/// Tick ticks the app loop. This will drain our mailbox and process those
/// events. This should be called by the application runtime on every loop
/// tick.
pub fn tick(self: *App, rt_app: *apprt.App) !void {
    // Drain our mailbox
    try self.drainMailbox(rt_app);
}

/// Update the configuration associated with the app. This can only be
/// called from the main thread. The caller owns the config memory. The
/// memory can be freed immediately when this returns.
pub fn updateConfig(self: *App, rt_app: *apprt.App, config: *const Config) !void {
    // Go through and update all of the surface configurations.
    for (self.surfaces.items) |surface| {
        try surface.core().handleMessage(.{ .change_config = config });
    }

    // Apply our conditional state. If we fail to apply the conditional state
    // then we log and attempt to move forward with the old config.
    // We only apply this to the app-level config because the surface
    // config applies its own conditional state.
    var applied_: ?configpkg.Config = config.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (applied_) |*c| c.deinit();
    const applied: *const configpkg.Config = if (applied_) |*c| c else config;

    // Notify the apprt that the app has changed configuration.
    _ = try rt_app.performAction(
        .app,
        .config_change,
        .{ .config = applied },
    );
}

/// Add an initialized surface. This is really only for the runtime
/// implementations to call and should NOT be called by general app users.
/// The surface must be from the pool.
pub fn addSurface(
    self: *App,
    rt_surface: *apprt.Surface,
) Allocator.Error!void {
    try self.surfaces.append(self.alloc, rt_surface);

    // Since we have non-zero surfaces, we can cancel the quit timer.
    // It is up to the apprt if there is a quit timer at all and if it
    // should be canceled.
    _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .stop,
    ) catch |err| {
        log.warn("error stopping quit timer err={}", .{err});
    };
}

/// Delete the surface from the known surface list. This will NOT call the
/// destructor or free the memory.
pub fn deleteSurface(self: *App, rt_surface: *apprt.Surface) void {
    // If this surface is the focused surface then we need to clear it.
    // There was a bug where we relied on hasSurface to return false and
    // just let focused surface be but the allocator was reusing addresses
    // after free and giving false positives, so we must clear it.
    if (self.focused_surface) |focused| {
        if (focused == rt_surface.core()) {
            self.focused_surface = null;
        }
    }

    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        if (self.surfaces.items[i] == rt_surface) {
            _ = self.surfaces.swapRemove(i);
            continue;
        }

        i += 1;
    }

    // If we have no surfaces, we can start the quit timer. It is up to the
    // apprt to determine if this is necessary.
    if (self.surfaces.items.len == 0) _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .start,
    ) catch |err| {
        log.warn("error starting quit timer err={}", .{err});
    };
}

/// The last focused surface. This is only valid while on the main thread
/// before tick is called.
pub fn focusedSurface(self: *const App) ?*Surface {
    const surface = self.focused_surface orelse return null;
    if (!self.hasSurface(surface)) return null;
    return surface;
}

test "automation-action safety rejects terminal input and crash actions" {
    try std.testing.expect(isSafeAutomationAction(.new_tab));
    try std.testing.expect(isSafeAutomationAction(.toggle_fullscreen));
    try std.testing.expect(isSafeAutomationAction(.quit));
    try std.testing.expect(!isSafeAutomationAction(.unbind));
    try std.testing.expect(!isSafeAutomationAction(.{ .text = "hello" }));
    try std.testing.expect(!isSafeAutomationAction(.{ .csi = "0m" }));
    try std.testing.expect(!isSafeAutomationAction(.paste_from_clipboard));
    try std.testing.expect(!isSafeAutomationAction(.{ .write_screen_file = .copy }));
    try std.testing.expect(!isSafeAutomationAction(.{ .crash = .main }));

    // end_key_sequence flushes the queued key-sequence writes to the pty,
    // so it is terminal input even though it takes no argument.
    try std.testing.expect(!isSafeAutomationAction(.end_key_sequence));

    // clear_screen writes 0x0C to the child at a prompt and erases the
    // full scrollback, so it is terminal input too.
    try std.testing.expect(!isSafeAutomationAction(.clear_screen));

    // undo/redo REPLAY a previously captured action, so allowlisting them
    // would re-open every action they can replay. The Win32 undo stack can
    // hold a `clear_screen` entry, and redoing it calls
    // `reapplyUndoableAction`, which queues the same
    // `.clear_screen{ .history = true }` io message the direct action does
    // (src/apprt/win32.zig `reapplyUndoableAction`) -- i.e. a pty write and a
    // full scrollback erase, reachable without ever naming `clear_screen`.
    // Undo additionally restores a snapshot title straight into the apprt
    // cache, bypassing the title sanitizer these setters otherwise enforce.
    // Gating on the replayed entry would mean plumbing the automation origin
    // through the whole apprt action dispatch; refusing both is the
    // deny-by-default answer and costs only IPC-driven undo/redo.
    try std.testing.expect(!isSafeAutomationAction(.undo));
    try std.testing.expect(!isSafeAutomationAction(.redo));

    // Key table actions only move the binding stack and stay allowed.
    try std.testing.expect(isSafeAutomationAction(.deactivate_all_key_tables));
}

test "automation-action safety rejects end_key_sequence parsed from IPC text" {
    const action = try input.Binding.Action.parse("end_key_sequence");
    try std.testing.expect(!isSafeAutomationAction(action));
}

/// An App with just enough state for `performAutomationAction` to run its
/// pre-dispatch checks. `font_grid_set` is untouched on that path, so this
/// avoids standing up the font subsystem for a pure gating test.
fn testAutomationApp() App {
    return .{
        .alloc = std.testing.allocator,
        .surfaces = .{},
        .mailbox = .{},
        .font_grid_set = undefined,
        .config_conditional_state = .{},
    };
}

test "automation-action dispatch rejects unsafe actions before dispatching" {
    var app = testAutomationApp();
    defer app.surfaces.deinit(app.alloc);

    // `performAutomationAction` returns before it touches `rt_app` for every
    // outcome asserted here: the safety gate rejects first, and with no
    // focused surface the fallback is a surface-scope check. A dangling but
    // correctly aligned pointer is therefore never dereferenced.
    const rt_app: *apprt.App = @ptrFromInt(@alignOf(apprt.App));

    // These go through the real IPC entry point, so deleting the
    // `isSafeAutomationAction` gate inside `performAutomationAction` fails
    // this test rather than leaving the parse-only tests above green.
    for ([_][]const u8{
        "end_key_sequence",
        "clear_screen",
        "paste_from_clipboard",
        // Reachable pty writes by replay rather than by name.
        "undo",
        "redo",
    }) |action_text| {
        try std.testing.expectError(
            error.UnsafeAutomationAction,
            app.performAutomationAction(rt_app, .focused, action_text),
        );
        try std.testing.expectError(
            error.UnsafeAutomationAction,
            app.performAutomationAction(rt_app, .{ .surface_id = 1 }, action_text),
        );
    }

    // An allowlisted surface-scoped action gets past the gate and fails
    // later for lack of a target, which is what proves the gate is what
    // rejected the actions above.
    try std.testing.expectError(
        error.NoAutomationTarget,
        app.performAutomationAction(rt_app, .focused, "scroll_to_top"),
    );

    // Unparseable action text is rejected before the gate.
    try std.testing.expectError(
        error.InvalidAutomationAction,
        app.performAutomationAction(rt_app, .focused, "no_such_action_zz"),
    );
}

test "automation-action surface id targets reject app scoped actions" {
    const action = try input.Binding.Action.parse("quit");
    try std.testing.expectEqual(input.Binding.Action.Scope.app, action.scope());
    try std.testing.expectEqual(
        error.InvalidAutomationTarget,
        automationActionTargetError(.{ .surface_id = 42 }, action).?,
    );
    try std.testing.expectEqual(
        null,
        automationActionTargetError(.focused, action),
    );
    try std.testing.expectEqual(
        null,
        automationActionTargetError(.{ .surface_id = 42 }, .new_tab),
    );
}

/// Returns true if confirmation is needed to quit the app. It is up to
/// the apprt to call this.
pub fn needsConfirmQuit(self: *const App) bool {
    for (self.surfaces.items) |v| {
        if (v.core().needsConfirmQuit()) return true;
    }

    return false;
}

/// Drain the mailbox.
fn drainMailbox(self: *App, rt_app: *apprt.App) !void {
    while (self.mailbox.pop()) |message| {
        if (comptime std.log.logEnabled(.debug, .app)) {
            switch (message) {
                // these tend to be way too verbose for normal debugging
                .redraw_surface => {},
                else => log.debug("mailbox message={t}", .{message}),
            }
        }
        switch (message) {
            .open_config => try self.performAction(rt_app, .open_config),
            .new_window => |msg| {
                defer msg.deinit(self.alloc);
                try self.newWindow(rt_app, msg);
            },
            .automation_window_list => |request| {
                request.result = rt_app.buildAutomationWindowListJson(request.alloc) catch |err| blk: {
                    request.err = err;
                    break :blk null;
                };
                request.completed.store(true, .release);
                request.release();
            },
            .automation_action => |request| {
                self.performAutomationAction(
                    rt_app,
                    request.target,
                    request.action_text,
                ) catch |err| {
                    request.err = err;
                };
                request.completed.store(true, .release);
                request.release();
            },
            .close => |surface| self.closeSurface(surface),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
            .redraw_surface => |surface| try self.redrawSurface(rt_app, surface),

            // If we're quitting, then we set the quit flag and stop
            // draining the mailbox immediately. This lets us defer
            // mailbox processing to the next tick so that the apprt
            // can try to quit as quickly as possible.
            .quit => {
                log.info("quit message received, short circuiting mailbox drain", .{});
                try self.performAction(rt_app, .quit);
                return;
            },
        }
    }
}

pub fn closeSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    surface.close();
}

pub fn focusSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    self.focused_surface = surface;
}

fn redrawSurface(
    self: *App,
    rt_app: *apprt.App,
    surface: *apprt.Surface,
) !void {
    if (!self.hasRtSurface(surface)) return;

    _ = try rt_app.performAction(
        .{ .surface = surface.core() },
        .render,
        {},
    );
}

/// Create a new window
pub fn newWindow(self: *App, rt_app: *apprt.App, msg: Message.NewWindow) !void {
    const target: apprt.Target = target: {
        const parent = msg.parent orelse break :target .app;
        if (self.hasSurface(parent)) break :target .{ .surface = parent };
        break :target .app;
    };

    _ = try rt_app.performAction(
        target,
        .new_window,
        .{ .arguments = msg.arguments },
    );
}

/// Handle an app-level focus event. This should be called whenever
/// the focus state of the entire app containing Ghostty changes.
/// This is separate from surface focus events. See the `focused`
/// field for more information.
pub fn focusEvent(self: *App, focused: bool) void {
    // Prevent redundant focus events
    if (self.focused == focused) return;

    log.debug("focus event focused={}", .{focused});
    self.focused = focused;
}

/// Returns true if the given key event would trigger a keybinding
/// if it were to be processed. This is useful for determining if
/// a key event should be sent to the terminal or not.
pub fn keyEventIsBinding(
    self: *App,
    rt_app: *apprt.App,
    event: input.KeyEvent,
) bool {
    _ = self;

    switch (event.action) {
        .release => return false,
        .press, .repeat => {},
    }

    // If we have a keybinding for this event then we return true.
    return rt_app.config.keybind.set.getEvent(event) != null;
}

/// Handle a key event at the app-scope. If this key event is used,
/// this will return true and the caller shouldn't continue processing
/// the event. If the event is not used, this will return false.
///
/// If the app currently has focus then all key events are processed.
/// If the app does not have focus then only global key events are
/// processed.
pub fn keyEvent(
    self: *App,
    rt_app: *apprt.App,
    event: input.KeyEvent,
) bool {
    switch (event.action) {
        // We don't care about key release events.
        .release => return false,

        // Continue processing key press events.
        .press, .repeat => {},
    }

    // Get the keybind entry for this event. We don't support key sequences
    // so we can look directly in the top-level set.
    const entry = rt_app.config.keybind.set.getEvent(event) orelse return false;
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        // Sequences aren't supported. Our configuration parser verifies
        // this for global keybinds but we may still get an entry for
        // a non-global keybind.
        .leader => return false,

        // Leaf entries are good
        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };
    const actions: []const input.Binding.Action = leaf.actionsSlice();
    assert(actions.len > 0);

    // If we aren't focused, then we only process global keybinds.
    if (!self.focused and !leaf.flags.global) return false;

    // Global keybinds are done using performAll so that they
    // can target all surfaces too.
    if (leaf.flags.global) {
        self.performAllChainedAction(rt_app, actions);
        return true;
    }

    // Must be focused to process non-global keybinds
    assert(self.focused);
    assert(!leaf.flags.global);

    // If we are focused, then we process keybinds only if they are
    // app-scoped. Otherwise, we do nothing. Surface-scoped should
    // be processed by Surface.keyEvent. For chained actions, all
    // actions must be app-scoped.
    for (actions) |action| if (action.scoped(.app) == null) return false;
    for (actions) |action| {
        self.performAction(
            rt_app,
            action.scoped(.app).?,
        ) catch |err| {
            log.warn("error performing app keybind action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }

    return true;
}

/// Call to notify Ghostty that the color scheme for the app has changed.
/// "Color scheme" in this case refers to system themes such as "light/dark".
pub fn colorSchemeEvent(
    self: *App,
    rt_app: *apprt.App,
    scheme: apprt.ColorScheme,
) !void {
    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };

    // If our scheme didn't change, then we don't do anything.
    if (self.config_conditional_state.theme == new_scheme) return;

    // Setup our conditional state which has the current color theme.
    self.config_conditional_state.theme = new_scheme;

    // Request our configuration be reloaded because the new scheme may
    // impact the colors of the app.
    _ = try rt_app.performAction(
        .app,
        .reload_config,
        .{ .soft = true },
    );
}

/// Build the `+new-window` argument that materializes a saved named layout.
/// Both the app-scoped and surface-scoped `launch_layout` handlers use this so
/// the flag spelling has a single definition. Caller owns the result.
pub fn launchLayoutArgument(alloc: Allocator, name: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(alloc, "--launch-layout={s}", .{name}, 0);
}

/// Perform a binding action. This only accepts actions that are scoped
/// to the app. Callers can use performAllAction to perform any action
/// and any non-app-scoped actions will be performed on all surfaces.
pub fn performAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action.Scoped(.app),
) !void {
    switch (action) {
        .unbind => unreachable,
        .ignore => {},
        .quit => _ = try rt_app.performAction(.app, .quit, {}),
        .new_window => _ = try self.newWindow(rt_app, .{ .parent = null }),
        .launch_layout => |name| {
            const argument = try launchLayoutArgument(self.alloc, name);
            defer self.alloc.free(argument);
            const arguments = [_][:0]const u8{argument};
            try self.newWindow(rt_app, .{ .parent = null, .arguments = &arguments });
        },
        .open_config => _ = try rt_app.performAction(.app, .open_config, {}),
        .reload_config => _ = try rt_app.performAction(.app, .reload_config, .{}),
        .close_all_windows => _ = try rt_app.performAction(.app, .close_all_windows, {}),
        .toggle_quick_terminal => _ = try rt_app.performAction(.app, .toggle_quick_terminal, {}),
        .toggle_visibility => _ = try rt_app.performAction(.app, .toggle_visibility, {}),
        .check_for_updates => _ = try rt_app.performAction(.app, .check_for_updates, {}),
        .show_gtk_inspector => _ = try rt_app.performAction(.app, .show_gtk_inspector, {}),
        .undo => _ = try rt_app.performAction(.app, .undo, {}),

        .redo => _ = try rt_app.performAction(.app, .redo, {}),
    }
}

/// Performs a chained action. We will continue executing each action
/// even if there is a failure in a prior action.
pub fn performAllChainedAction(
    self: *App,
    rt_app: *apprt.App,
    actions: []const input.Binding.Action,
) void {
    for (actions) |action| {
        self.performAllAction(rt_app, action) catch |err| {
            log.warn("error performing chained action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }
}

/// Perform an app-wide binding action. If the action is surface-specific
/// then it will be performed on all surfaces. To perform only app-scoped
/// actions, use performAction.
pub fn performAllAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action,
) !void {
    // A named layout is always a snapshot of the focused window. Global
    // bindings normally fan surface actions out to every surface, which would
    // rewrite the same layout once per pane and make iteration order observable.
    if (action == .save_layout) {
        if (self.focusedSurface()) |surface| {
            _ = try surface.performBindingAction(action);
        }
        return;
    }

    switch (action.scope()) {
        // App-scoped actions are handled by the app so that they aren't
        // repeated for each surface (since each surface forwards
        // app-scoped actions back up).
        .app => try self.performAction(
            rt_app,
            action.scoped(.app).?, // asserted through the scope match
        ),

        // Surface-scoped actions are performed on all surfaces. Errors
        // are logged but processing continues.
        .surface => for (self.surfaces.items) |surface| {
            _ = surface.core().performBindingAction(action) catch |err| {
                log.warn("error performing binding action on surface ptr={X} err={}", .{
                    @intFromPtr(surface),
                    err,
                });
            };
        },
    }
}

fn performAutomationAction(
    self: *App,
    rt_app: *apprt.App,
    target: apprt.ipc.AutomationActionTarget,
    action_text: []const u8,
) !void {
    const action = input.Binding.Action.parse(action_text) catch |err| switch (err) {
        error.InvalidAction, error.InvalidFormat => return error.InvalidAutomationAction,
        else => return err,
    };
    if (!isSafeAutomationAction(action)) return error.UnsafeAutomationAction;
    if (automationActionTargetError(target, action)) |err| return err;

    switch (target) {
        .focused => {
            if (self.focusedSurface()) |surface| {
                _ = try surface.performBindingAction(action);
            } else {
                if (action.scope() != .app) return error.NoAutomationTarget;
                try self.performAction(rt_app, action.scoped(.app).?);
            }
        },
        .surface_id => |id| {
            const surface = self.findSurfaceByID(id) orelse return error.NoAutomationTarget;
            _ = try surface.performBindingAction(action);
        },
    }
}

fn automationActionTargetError(
    target: apprt.ipc.AutomationActionTarget,
    action: input.Binding.Action,
) ?anyerror {
    return switch (target) {
        .focused => null,
        .surface_id => if (action.scope() == .app or action == .save_layout)
            error.InvalidAutomationTarget
        else
            null,
    };
}

/// Actions that `+perform-action` may invoke over IPC.
///
/// Anything that can put bytes on the pty is excluded:
///
///   - `end_key_sequence` resolves to `endKeySequence(.flush, ...)`, which
///     writes the pending key-sequence queue to the terminal.
///   - `clear_screen` reaches `Termio.clearScreen`, which sends `0x0C` (FF)
///     to the child when the cursor is at a prompt, and also erases the
///     full scrollback without regard to `readonly`.
///
/// This is only the boundary for the `.perform_action` IPC request kind.
/// The `.new_window` kind on the same pipe carries argv and is filtered
/// separately in `apprt/win32.zig` (`applyNewWindowArguments`); the pipe
/// itself is restricted to the same user and is not a privilege boundary.
///
/// New action variants default to unsafe until they are reviewed.
fn isSafeAutomationAction(action: input.Binding.Action) bool {
    return switch (action) {
        .ignore,
        .search,
        .navigate_search,
        .search_selection,
        .start_search,
        .end_search,
        .reset,
        .copy_to_clipboard,
        .copy_url_to_clipboard,
        .copy_title_to_clipboard,
        .increase_font_size,
        .decrease_font_size,
        .reset_font_size,
        .set_font_size,
        .prompt_surface_title,
        .prompt_tab_title,
        .set_surface_title,
        .set_tab_title,
        .select_all,
        .scroll_to_top,
        .scroll_to_bottom,
        .scroll_to_selection,
        .scroll_to_row,
        .scroll_page_up,
        .scroll_page_down,
        .scroll_page_fractional,
        .scroll_page_lines,
        .adjust_selection,
        .jump_to_prompt,
        .new_window,
        .launch_layout,
        .save_layout,
        .new_tab,
        .previous_tab,
        .next_tab,
        .last_tab,
        .goto_tab,
        .move_tab,
        .toggle_tab_overview,
        .new_split,
        .goto_split,
        .goto_window,
        .toggle_split_zoom,
        .toggle_readonly,
        .resize_split,
        .equalize_splits,
        .reset_window_size,
        .inspector,
        .show_gtk_inspector,
        .show_on_screen_keyboard,
        .open_config,
        .reload_config,
        .close_surface,
        .close_tab,
        .close_window,
        .close_all_windows,
        .toggle_maximize,
        .toggle_fullscreen,
        .toggle_window_decorations,
        .toggle_window_float_on_top,
        .toggle_secure_input,
        .toggle_mouse_reporting,
        .toggle_command_palette,
        .toggle_quick_terminal,
        .toggle_visibility,
        .toggle_background_opacity,
        .check_for_updates,
        .activate_key_table,
        .activate_key_table_once,
        .deactivate_key_table,
        .deactivate_all_key_tables,
        .quit,
        => true,

        else => false,
    };
}

test "named layout automation save requires the focused target" {
    const action = try input.Binding.Action.parse("save_layout:demo");
    try std.testing.expect(automationActionTargetError(.focused, action) == null);
    try std.testing.expectEqual(
        error.InvalidAutomationTarget,
        automationActionTargetError(.{ .surface_id = 42 }, action).?,
    );
}

/// Handle a window message
fn surfaceMessage(self: *App, surface: *Surface, msg: apprt.surface.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    if (self.hasSurface(surface)) {
        try surface.handleMessage(msg);
        return;
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem, but the queued payload may own memory.
    var dropped = msg;
    dropped.deinit();
}

fn hasSurface(self: *const App, surface: *const Surface) bool {
    for (self.surfaces.items) |v| {
        if (v.core() == surface) return true;
    }

    return false;
}

/// Search for a surface by a 64 bit unique ID.
pub fn findSurfaceByID(self: *const App, id: u64) ?*Surface {
    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        if (surface.id == id) return surface;
    }

    return null;
}

fn hasRtSurface(self: *const App, surface: *apprt.Surface) bool {
    for (self.surfaces.items) |v| {
        if (v == surface) return true;
    }

    return false;
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    // Open the configuration file
    open_config: void,

    /// Create a new terminal window.
    new_window: NewWindow,

    /// Produce a read-only automation window snapshot on the app thread.
    automation_window_list: *AutomationWindowListRequest,

    /// Perform a safe parsed keybinding action on the app thread.
    automation_action: *AutomationActionRequest,

    /// Close a surface. This notifies the runtime that a surface
    /// should close.
    close: *Surface,

    /// Quit
    quit: void,

    /// A message for a specific surface.
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },

    /// Redraw a surface. This only has an effect for runtimes that
    /// use single-threaded draws. To redraw a surface for all runtimes,
    /// wake up the renderer thread. The renderer thread will send this
    /// message if it needs to.
    redraw_surface: *apprt.Surface,

    pub fn deinit(self: Message, alloc: Allocator) void {
        switch (self) {
            .new_window => |message| message.deinit(alloc),
            .automation_window_list => |request| request.release(),
            .automation_action => |request| request.release(),
            .surface_message => |payload| {
                var message = payload.message;
                message.deinit();
            },
            else => {},
        }
    }

    pub const AutomationWindowListRequest = struct {
        alloc: Allocator,
        refs: std.atomic.Value(u32) = .init(1),
        completed: std.atomic.Value(bool) = .init(false),
        result: ?[]u8 = null,
        err: ?anyerror = null,

        pub fn create(alloc: Allocator) !*@This() {
            const request = try alloc.create(@This());
            request.* = .{ .alloc = alloc };
            return request;
        }

        pub fn retain(self: *@This()) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        pub fn release(self: *@This()) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            if (self.result) |result| self.alloc.free(result);
            self.alloc.destroy(self);
        }

        pub fn takeResult(self: *@This()) ?[]u8 {
            const result = self.result;
            self.result = null;
            return result;
        }
    };

    pub const AutomationActionRequest = struct {
        alloc: Allocator,
        refs: std.atomic.Value(u32) = .init(1),
        target: apprt.ipc.AutomationActionTarget,
        action_text: []const u8,
        completed: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,

        pub fn create(
            alloc: Allocator,
            target: apprt.ipc.AutomationActionTarget,
            action_text: []const u8,
        ) !*@This() {
            const request = try alloc.create(@This());
            errdefer alloc.destroy(request);
            request.* = .{
                .alloc = alloc,
                .target = target,
                .action_text = try alloc.dupe(u8, action_text),
            };
            return request;
        }

        pub fn retain(self: *@This()) void {
            _ = self.refs.fetchAdd(1, .monotonic);
        }

        pub fn release(self: *@This()) void {
            if (self.refs.fetchSub(1, .acq_rel) != 1) return;
            self.alloc.free(self.action_text);
            self.alloc.destroy(self);
        }
    };

    const NewWindow = struct {
        /// The parent surface
        parent: ?*Surface = null,

        /// Optional CLI-style arguments forwarded from a platform IPC path.
        arguments: ?[]const [:0]const u8 = null,

        pub fn deinit(self: NewWindow, alloc: Allocator) void {
            if (self.arguments) |arguments| {
                for (arguments) |arg| alloc.free(arg);
                alloc.free(arguments);
            }
        }
    };
};

test "queued automation messages release consumer ownership during teardown" {
    const action_request = try Message.AutomationActionRequest.create(
        std.testing.allocator,
        .focused,
        "new_tab",
    );
    action_request.retain();
    action_request.release();
    (Message{ .automation_action = action_request }).deinit(std.testing.allocator);

    const list_request = try Message.AutomationWindowListRequest.create(std.testing.allocator);
    list_request.retain();
    list_request.release();
    (Message{ .automation_window_list = list_request }).deinit(std.testing.allocator);
}

/// Mailbox is the way that other threads send the app thread messages.
pub const Mailbox = struct {
    /// The type used for sending messages to the app thread.
    pub const Queue = BlockingQueue(Message, 64);

    rt_app: *apprt.App,
    mailbox: *Queue,

    /// Send a message to the surface.
    pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
        const result = self.mailbox.push(msg, timeout);

        // Wake up our app loop
        self.rt_app.wakeup();

        return result;
    }
};

// Wasm API.
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;

    // export fn app_new(config: *Config) ?*App {
    //     return app_new_(config) catch |err| { log.err("error initializing app err={}", .{err});
    //         return null;
    //     };
    // }
    //
    // fn app_new_(config: *Config) !*App {
    //     const app = try App.create(alloc, config);
    //     errdefer app.destroy();
    //
    //     const result = try alloc.create(App);
    //     result.* = app;
    //     return result;
    // }
    //
    // export fn app_free(ptr: ?*App) void {
    //     if (ptr) |v| {
    //         v.destroy();
    //         alloc.destroy(v);
    //     }
    // }
};
