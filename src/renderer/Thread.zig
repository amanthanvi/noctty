//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("../global.zig").xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const rendererpkg = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;
const App = @import("../App.zig");
const terminalpkg = @import("../terminal/main.zig");
const terminal_render_dirty = @import("../terminal/render_dirty.zig");
const win32_power = @import("../apprt/win32_power.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);
const darwin = if (builtin.os.tag.isDarwin()) struct {
    const objc = @import("objc");
    const AutoreleasePool = objc.AutoreleasePool;
    const QosClass = internal_os.macos.QosClass;

    fn beginAutoreleasePool() AutoreleasePool {
        return AutoreleasePool.init();
    }

    fn endAutoreleasePool(pool: AutoreleasePool) void {
        pool.deinit();
    }

    fn setThreadName(name: [*:0]const u8) void {
        internal_os.macos.pthread_setname_np(name);
    }

    fn setQosClass(class: QosClass) !void {
        try internal_os.macos.setQosClass(class);
    }
} else struct {
    const AutoreleasePool = void;
    const QosClass = enum {
        user_interactive,
        user_initiated,
        utility,
    };

    fn beginAutoreleasePool() AutoreleasePool {
        return {};
    }

    fn endAutoreleasePool(_: AutoreleasePool) void {}

    fn setThreadName(_: [*:0]const u8) void {}

    fn setQosClass(_: QosClass) !void {}
};

const DRAW_INTERVAL = 8; // 120 FPS
const CURSOR_BLINK_INTERVAL = 600;
const RENDER_FOLLOWUP_BURST_MS = 128;

comptime {
    // The power policy returns this same interval for focused, non-saver
    // surfaces so their pacing stays exactly what it was before adaptive
    // rendering existed. Keep the two constants in lockstep.
    std.debug.assert(DRAW_INTERVAL == win32_power.DEFAULT_PRESENT_INTERVAL_MS);
}

/// Whether calls to `drawFrame` must be done from the app thread.
///
/// If this is `true` then we send a `redraw_surface` message to the apprt
/// whenever we need to draw instead of calling `drawFrame` directly.
const must_draw_from_app_thread =
    if (@hasDecl(apprt.App, "must_draw_from_app_thread"))
        apprt.App.must_draw_from_app_thread
    else
        false;

/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(rendererpkg.Message, 64);

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the renderer on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for rendering
render_h: xev.Timer,
render_c: xev.Completion = .{},
render_reset_c: xev.Completion = .{},
render_followup_pending: bool = false,
/// Absolute Win32 tick when the active render follow-up should fire.
render_timer_due_ms: u64 = 0,
last_present_request_ms: u64 = 0,

/// The timer used for draw calls. Draw calls don't update from the
/// terminal state so they're much cheaper. They're used for animation
/// and are paused when the terminal is not focused.
draw_h: xev.Timer,
draw_c: xev.Completion = .{},
draw_reset_c: xev.Completion = .{},
draw_active: bool = false,
/// Absolute Win32 tick when the active draw timer should fire. This lets a
/// focus or power-policy change shorten an already-queued slow interval.
draw_timer_due_ms: u64 = 0,

/// This async is used to force a draw immediately. This does not
/// coalesce like the wakeup does.
draw_now: xev.Async,
draw_now_c: xev.Completion = .{},

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
/// The most recent request to restart the cursor blink interval. We keep
/// this as logical state instead of resetting the xev completion: on IOCP a
/// completed timer remains `.active` until its callback is popped, so reusing
/// it from another callback can corrupt libxev's intrusive completion queue.
cursor_blink_reset_at: ?std.time.Instant = null,

/// The surface we're rendering to.
surface: *apprt.Surface,

/// Search generation shared with the surface so stale async search payloads
/// can be dropped after a query is replaced or cleared.
search_generation: *const std.atomic.Value(u64),

/// The underlying renderer implementation.
renderer: *rendererpkg.Renderer,

/// Pointer to the shared state that is used to generate the final render.
state: *rendererpkg.State,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Mailbox to send messages to the app thread
app_mailbox: App.Mailbox,

/// Configuration we need derived from the main config.
config: DerivedConfig,

flags: packed struct {
    /// This is true when a blinking cursor should be visible and false
    /// when it should not be visible. This is toggled on a timer by the
    /// thread automatically.
    cursor_blink_visible: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,

    /// This is true when the view is visible. This is used to determine
    /// if we should be rendering or not.
    visible: bool = true,

    /// This is true when the view is focused. This defaults to true
    /// and it is up to the apprt to set the correct value.
    focused: bool = true,
} = .{},

pub const DerivedConfig = struct {
    custom_shader_animation: configpkg.CustomShaderAnimation,
    unfocused_render_fps: u32,
    power_saver_rendering: configpkg.PowerSaverRendering,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .custom_shader_animation = config.@"custom-shader-animation",
            .unfocused_render_fps = config.@"unfocused-render-fps",
            .power_saver_rendering = config.@"power-saver-rendering",
        };
    }
};

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    config: *const configpkg.Config,
    surface: *apprt.Surface,
    renderer_impl: *rendererpkg.Renderer,
    state: *rendererpkg.State,
    app_mailbox: App.Mailbox,
    search_generation: *const std.atomic.Value(u64),
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // The primary timer for rendering.
    var render_h = try xev.Timer.init();
    errdefer render_h.deinit();

    // Draw timer, see comments.
    var draw_h = try xev.Timer.init();
    errdefer draw_h.deinit();

    // Draw now async, see comments.
    var draw_now = try xev.Async.init();
    errdefer draw_now.deinit();

    // Setup a timer for blinking the cursor
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    return .{
        .alloc = alloc,
        .config = .init(config),
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_h = draw_h,
        .draw_now = draw_now,
        .cursor_h = cursor_timer,
        .surface = surface,
        .search_generation = search_generation,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
        .app_mailbox = app_mailbox,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_h.deinit();
    self.draw_now.deinit();
    self.cursor_h.deinit();
    self.loop.deinit();

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("renderer thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        darwin.setThreadName("renderer");
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .renderer,
        .surface = self.renderer.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Setup our thread QoS
    self.setQosClass();

    // Run our loop start/end callbacks if the renderer cares.
    const has_loop = @hasDecl(rendererpkg.Renderer, "loopEnter");
    if (has_loop) try self.renderer.loopEnter(self);
    defer if (has_loop) self.renderer.loopExit();

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    try self.renderer.threadEnter(self.surface);
    defer self.renderer.threadExit();

    // Start the async handlers
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);

    // Send an initial wakeup message so that we render right away.
    try self.wakeup.notify();

    // Start blinking only when the terminal's cursor mode requests it.
    // Steady cursors must not keep a 500 ms renderer wake loop alive.
    if (self.cursorShouldBlink()) {
        self.armCursorTimerIfDead(cursorBlinkInterval());
    }

    // Start the draw timer
    self.syncDrawTimer();

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("starting renderer thread shutdown", .{});
    _ = try self.loop.run(.until_done);
}

fn setQosClass(self: *const Thread) void {
    // Thread QoS classes are only relevant on macOS.
    if (comptime !builtin.target.os.tag.isDarwin()) return;

    const class: darwin.QosClass = class: {
        // If we aren't visible (our view is fully occluded) then we
        // always drop our rendering priority down because it's just
        // mostly wasted work.
        //
        // The renderer itself should be doing this as well, but this also
        // helps with general forced updates and CPU usage i.e. a rebuild cells call.
        if (!self.flags.visible) break :class .utility;

        // If we're not focused, but we're visible, then we set a higher
        // than default priority because framerates still matter but it isn't
        // as important as when we're focused.
        if (!self.flags.focused) break :class .user_initiated;

        // We are focused and visible, we are the definition of user interactive.
        break :class .user_interactive;
    };

    if (darwin.setQosClass(class)) {
        log.debug("thread QoS class set class={}", .{class});
    } else |err| {
        log.warn("error setting QoS class err={}", .{err});
    }
}

fn syncDrawTimer(self: *Thread) void {
    if (!self.flags.visible) {
        self.draw_active = false;
        return;
    }

    skip: {
        // If our renderer supports animations and has them, then we
        // can apply draw timer based on custom shader animation configuration.
        if (@hasDecl(rendererpkg.Renderer, "hasAnimations") and
            self.renderer.hasAnimations())
        {
            // If our config says to always animate, we do so.
            switch (self.config.custom_shader_animation) {
                // Always animate
                .always => break :skip,
                // Only when focused
                .true => if (self.flags.focused) break :skip,
                // Never animate
                .false => {},
            }
        }

        // We're skipping the draw timer. Stop it on the next iteration.
        self.draw_active = false;
        return;
    }

    // Set our active state so it knows we're running. We set this before
    // even checking the active state in case we have a pending shutdown.
    self.draw_active = true;

    const delay_ms = self.nextPresentTimerDelayMs() orelse {
        self.draw_active = false;
        return;
    };

    if (self.draw_c.state() == .active) {
        if (apprt.runtime != apprt.win32) return;

        const now_ms = win32_power.tickCountMs();
        if (!timerNeedsEarlierDeadline(now_ms, self.draw_timer_due_ms, delay_ms)) return;
        self.draw_h.reset(
            &self.loop,
            &self.draw_c,
            &self.draw_reset_c,
            delay_ms,
            Thread,
            self,
            drawCallback,
        );
        self.draw_timer_due_ms = now_ms +| delay_ms;
        return;
    }

    // Start the timer which loops.
    self.draw_h.run(
        &self.loop,
        &self.draw_c,
        delay_ms,
        Thread,
        self,
        drawCallback,
    );
    if (apprt.runtime == apprt.win32) {
        self.draw_timer_due_ms = win32_power.tickCountMs() +| delay_ms;
    }
}

fn timerNeedsEarlierDeadline(now_ms: u64, due_ms: u64, next_delay_ms: u64) bool {
    if (due_ms == 0) return true;
    return next_delay_ms < due_ms -| now_ms;
}

/// Enqueue a message and wake the renderer to process it.
///
/// The first notification lets the renderer make room if the mailbox is
/// full. The second covers the case where that notification is processed
/// before the message is enqueued.
pub fn send(self: *Thread, msg: rendererpkg.Message) void {
    sendMessage(&self.wakeup, self.mailbox, msg);
}

/// Enqueue a message through a shared renderer wake handle.
pub fn sendMessage(
    wakeup: *xev.Async,
    mailbox: *Mailbox,
    msg: rendererpkg.Message,
) void {
    notify(wakeup);

    // Renderer messages may transfer ownership or required state.
    _ = mailbox.push(msg, .{ .forever = {} });

    notify(wakeup);
}

fn notify(wakeup: *xev.Async) void {
    wakeup.notify() catch |err| {
        log.warn("error notifying renderer thread err={}", .{err});
    };
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !bool {
    // There's probably a more elegant way to do this...
    //
    // This is effectively an @autoreleasepool{} block, which we need in
    // order to ensure that autoreleased objects are properly released.
    const pool = darwin.beginAutoreleasePool();
    defer darwin.endAutoreleasePool(pool);

    var handled_any = false;
    while (self.mailbox.pop()) |message| {
        handled_any = true;
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .crash => @panic("crash request, crashing intentionally"),

            .visible => |v| visible: {
                // If our state didn't change we do nothing.
                if (self.flags.visible == v) break :visible;

                // Set our visible state
                self.flags.visible = v;

                // Visibility affects our QoS class
                self.setQosClass();

                // Becoming visible used to draw immediately here, on the
                // assumption that frame data kept updating while hidden.
                // It no longer does — hidden surfaces skip `updateFrame`
                // entirely — so drawing now would present a stale frame AND
                // start the throttle clock, deferring the real repaint by a
                // full interval. `drainMailbox` is only ever called from
                // `renderOnce`, which does `updateFrame` + `drawFrame` right
                // after this, so the first visible frame is both fresh and
                // immediate.
                if (v) self.last_present_request_ms = 0;

                // Notify the renderer so it can update any state.
                self.renderer.setVisible(v);

                // Visibility changes can suppress or restart animation draws.
                self.syncDrawTimer();
            },

            .focus => |v| focus: {
                // If our state didn't change we do nothing.
                if (self.flags.focused == v) break :focus;

                // Set our state
                self.flags.focused = v;

                // Focus affects our QoS class
                self.setQosClass();

                // Set it on the renderer
                try self.renderer.setFocus(v);

                // We always resync our draw timer (may disable it)
                self.syncDrawTimer();

                if (!v) {
                    // Let an already-queued one-shot timer expire and disarm
                    // itself. Reusing its completion here is unsafe on IOCP.
                    self.flags.cursor_blink_visible = true;
                    self.cursor_blink_reset_at = null;
                } else {
                    // If we're focused, we immediately show the cursor again
                    // and restart the logical interval. If the completion is
                    // active, its callback owns the eventual rearm.
                    self.flags.cursor_blink_visible = true;
                    self.cursor_blink_reset_at = std.time.Instant.now() catch null;
                    if (self.cursorShouldBlink()) {
                        self.armCursorTimerIfDead(cursorBlinkInterval());
                    }
                }
            },

            .reset_cursor_blink => {
                self.flags.cursor_blink_visible = true;
                if (self.flags.focused and self.cursorShouldBlink()) {
                    self.cursor_blink_reset_at = std.time.Instant.now() catch null;
                    self.armCursorTimerIfDead(cursorBlinkInterval());
                }
            },

            .font_grid => |grid| {
                self.renderer.setFontGrid(grid.grid);
                grid.set.deref(grid.old_key);
            },

            .resize => |v| self.renderer.setScreenSize(v),

            .change_config => |config| {
                defer config.alloc.destroy(config.thread);
                defer config.alloc.destroy(config.impl);
                try self.changeConfig(config.thread);
                try self.renderer.changeConfig(config.impl);

                // Stop and start the draw timer to capture the new
                // hasAnimations value.
                self.syncDrawTimer();
            },

            .search_viewport_matches => |v| search: {
                var payload = v;
                if (!self.shouldAcceptSearchGeneration(payload.generation)) {
                    payload.deinit();
                    break :search;
                }

                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_matches) |*m| m.deinit();
                self.renderer.search_matches = payload;
                self.renderer.search_matches_dirty = true;
            },

            .search_selected_match => |v| search: {
                var payload = v;
                if (!self.shouldAcceptSearchGeneration(payload.generation)) {
                    payload.deinit();
                    break :search;
                }

                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_selected_match) |*m| m.arena.deinit();
                self.renderer.search_selected_match = payload.match;
                self.renderer.search_matches_dirty = true;
            },

            .search_clear => |generation| search: {
                if (!self.shouldAcceptSearchGeneration(generation)) break :search;
                if (self.renderer.search_matches) |*m| m.deinit();
                self.renderer.search_matches = null;
                if (self.renderer.search_selected_match) |*m| m.arena.deinit();
                self.renderer.search_selected_match = null;
                self.renderer.search_matches_dirty = true;
            },

            .inspector => |v| {
                self.flags.has_inspector = v;
            },

            .macos_display_id => |v| {
                if (@hasDecl(rendererpkg.Renderer, "setMacOSDisplayID")) {
                    try self.renderer.setMacOSDisplayID(v);
                }
            },
        }
    }

    return handled_any;
}

fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    self.config = config.*;
}

fn shouldAcceptSearchGeneration(self: *const Thread, generation: u64) bool {
    return self.search_generation.load(.acquire) == generation;
}

fn powerSnapshot(self: *const Thread) win32_power.Snapshot {
    _ = self;
    if (apprt.runtime != apprt.win32) return .{};
    win32_power.pollIfStale();
    return win32_power.snapshot();
}

fn minimumPresentIntervalMs(self: *const Thread) ?u64 {
    if (apprt.runtime != apprt.win32) {
        return if (self.flags.visible) DRAW_INTERVAL else null;
    }
    return win32_power.minimumPresentIntervalMs(
        self.flags.focused,
        self.flags.visible,
        self.powerSnapshot(),
        .{
            .unfocused_render_fps = self.config.unfocused_render_fps,
            .power_saver_rendering = self.config.power_saver_rendering,
        },
    );
}

fn presentWaitMs(self: *const Thread, interval_ms: u64) u64 {
    if (interval_ms <= DRAW_INTERVAL or self.last_present_request_ms == 0) return 0;
    const elapsed_ms = win32_power.tickCountMs() -| self.last_present_request_ms;
    return interval_ms -| elapsed_ms;
}

fn nextPresentTimerDelayMs(self: *const Thread) ?u64 {
    const interval_ms = self.minimumPresentIntervalMs() orelse return null;
    const wait_ms = self.presentWaitMs(interval_ms);
    return if (wait_ms > 0) wait_ms else interval_ms;
}

fn notePresentRequest(self: *Thread, interval_ms: u64) void {
    if (interval_ms <= DRAW_INTERVAL) {
        self.last_present_request_ms = 0;
        return;
    }
    self.last_present_request_ms = win32_power.tickCountMs();
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) void {
    self.drawFrameWithReservation(now, false);
}

fn drawFrameWithReservation(self: *Thread, now: bool, repaint_reserved: bool) void {
    // A caller-held reservation must be released on every path that does not
    // hand it to a paint. Leaking one leaves renderer_repaint_requested set
    // forever, after which every later repaint coalesces into a request that
    // is never finished and the pane stops updating until a resize-settle or
    // health recovery cancels it.
    var reservation_held = repaint_reserved;
    defer if (reservation_held) {
        if (comptime @hasDecl(apprt.Surface, "cancelRendererRepaintRequest")) {
            self.surface.cancelRendererRepaintRequest();
        }
    };

    const interval_ms = self.minimumPresentIntervalMs() orelse return;

    // `now` is the forced, vsync-bypassing path (`drawNowCallback`): a
    // resize, a damage event, something the user is looking at right this
    // moment. Dropping it would leave visible artifacts on screen for up to a
    // full interval — a whole second at `unfocused-render-fps = 1` — so
    // pacing does not apply. Forced draws are event-driven, not timer-driven,
    // so this cannot become a busy loop.
    if (!now and self.presentWaitMs(interval_ms) > 0) return;

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`.
    if (!now and self.renderer.hasVsync()) return;

    if (must_draw_from_app_thread) {
        if (comptime @hasDecl(apprt.Surface, "noteRendererDrawRequest")) {
            self.surface.noteRendererDrawRequest();
        }
        if (comptime @hasDecl(apprt.Surface, "beginRendererRepaintRequest")) {
            if (!repaint_reserved and !self.surface.beginRendererRepaintRequest()) return;
        }

        // From here the reservation belongs to the queued paint: either the
        // paint completes it, or the failed push below cancels it.
        reservation_held = false;

        if (self.app_mailbox.push(
            .{ .redraw_surface = self.surface },
            .{ .instant = {} },
        ) == 0) {
            if (comptime @hasDecl(apprt.Surface, "cancelRendererRepaintRequest")) {
                self.surface.cancelRendererRepaintRequest();
            }
        } else {
            self.notePresentRequest(interval_ms);
        }
    } else {
        // Nothing will complete a reservation on this path, so the deferred
        // cancel above releases it once the synchronous draw returns.
        self.renderer.drawFrame(false) catch |err| {
            log.warn("error drawing err={}", .{err});
            return;
        };
        self.notePresentRequest(interval_ms);
    }
}

fn scheduleRenderFollowup(self: *Thread) void {
    const delay_ms = self.nextPresentTimerDelayMs() orelse return;

    if (self.render_followup_pending) {
        if (apprt.runtime != apprt.win32) return;

        const now_ms = win32_power.tickCountMs();
        if (!timerNeedsEarlierDeadline(now_ms, self.render_timer_due_ms, delay_ms)) return;
        self.render_h.reset(
            &self.loop,
            &self.render_c,
            &self.render_reset_c,
            delay_ms,
            Thread,
            self,
            renderCallback,
        );
        self.render_timer_due_ms = now_ms +| delay_ms;
        return;
    }

    self.render_followup_pending = true;
    self.render_h.run(
        &self.loop,
        &self.render_c,
        delay_ms,
        Thread,
        self,
        renderCallback,
    );
    if (apprt.runtime == apprt.win32) {
        self.render_timer_due_ms = win32_power.tickCountMs() +| delay_ms;
    }
}

/// Arm the cursor's one-shot timer only when libxev no longer owns the
/// completion. In particular, `.active` can mean "already completed but still
/// queued for its callback" on IOCP, so callers must never reset or reinitialize
/// an active cursor completion.
fn armCursorTimerIfDead(self: *Thread, delay_ms: u64) void {
    if (self.cursor_c.state() != .dead) return;
    self.cursor_h.run(
        &self.loop,
        &self.cursor_c,
        delay_ms,
        Thread,
        self,
        cursorTimerCallback,
    );
}

fn cursorShouldBlink(self: *Thread) bool {
    self.state.mutex.lock();
    defer self.state.mutex.unlock();
    return self.state.terminal.modes.get(.cursor_blinking);
}

fn refreshRenderFollowupDeadline(self: *Thread) void {
    if (apprt.runtime != apprt.win32 or !self.flags.visible) return;
    self.state.noteRenderWakeupNotify();
}

fn renderFollowupWindowActive(self: *const Thread) bool {
    if (apprt.runtime != apprt.win32 or !self.flags.visible) return false;
    return self.state.renderWakeupNotifiedRecently(RENDER_FOLLOWUP_BURST_MS);
}

fn shouldContinueRenderFollowup(self: *Thread) bool {
    if (apprt.runtime != apprt.win32 or !self.flags.visible) return false;

    self.state.mutex.lock();
    defer self.state.mutex.unlock();
    return terminal_render_dirty.needsRendererWake(self.state.terminal);
}

fn renderOnce(self: *Thread, from_wakeup: bool) bool {
    // Drain mailbox work first so message-driven state changes are reflected
    // in the same frame as terminal output wakes.
    _ = self.drainMailbox() catch |err| {
        log.err("error draining mailbox err={}", .{err});
        return false;
    };

    // Invisible surfaces retain terminal state but do no renderer work. A
    // throttled surface defers both updateFrame and presentation through the
    // existing follow-up timer so background output cannot burn CPU at the
    // uncapped wakeup rate.
    const interval_ms = self.minimumPresentIntervalMs() orelse return false;
    if (self.presentWaitMs(interval_ms) > 0) return true;

    var repaint_reserved = false;
    if (must_draw_from_app_thread and self.flags.visible and !self.renderer.hasVsync()) {
        if (comptime @hasDecl(apprt.Surface, "beginRendererFrameUpdate")) {
            if (!self.surface.beginRendererFrameUpdate()) {
                const keep_due_to_dirty = self.shouldContinueRenderFollowup();
                if (from_wakeup and keep_due_to_dirty) self.refreshRenderFollowupDeadline();
                return keep_due_to_dirty or self.renderFollowupWindowActive();
            }
            repaint_reserved = true;
        }
    }

    if (comptime @hasDecl(apprt.Surface, "noteRendererUpdateFrame")) {
        self.surface.noteRendererUpdateFrame();
    }

    // updateFrame returns the cursor mode from the same locked terminal
    // snapshot used to rebuild this frame.
    const frame_update: ?rendererpkg.Renderer.FrameUpdate = self.renderer.updateFrame(
        self.state,
        self.flags.cursor_blink_visible,
    ) catch |err| frame_update: {
        log.warn("error rendering err={}", .{err});
        break :frame_update null;
    };
    const cursor_blinking = if (frame_update) |update|
        update.cursor_blinking
    else
        self.cursorShouldBlink();
    if (!cursor_blinking) self.flags.cursor_blink_visible = true;
    if (self.flags.focused and cursor_blinking) {
        self.armCursorTimerIfDead(cursorBlinkInterval());
    }

    // Draw.
    self.drawFrameWithReservation(false, repaint_reserved);

    // On Win32, xev async wakes can coalesce while a render pass is still
    // in flight. If terminal dirtiness reappeared during the pass, keep a
    // short follow-up timer active so streaming output doesn't collapse to a
    // fraction of the intended frame rate.
    const keep_due_to_dirty = self.shouldContinueRenderFollowup();
    if (from_wakeup and keep_due_to_dirty) self.refreshRenderFollowupDeadline();
    return keep_due_to_dirty or self.renderFollowupWindowActive();
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const t = self_.?;
    if (comptime @hasDecl(apprt.Surface, "noteRendererWakeupCallback")) {
        t.surface.noteRendererWakeupCallback();
    }
    if (t.renderOnce(true)) {
        t.scheduleRenderFollowup();
    }

    return .rearm;
}

fn drawNowCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in draw now err={}", .{err});
        return .rearm;
    };

    // Draw immediately
    const t = self_.?;
    t.drawFrame(true);

    return .rearm;
}

fn drawCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // `Timer.reset` cancels the previous completion before rearming it.
        // The replacement timer is already scheduled; this callback belongs
        // only to the canceled run.
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };
    t.draw_timer_due_ms = 0;

    // Draw
    t.drawFrame(false);

    // Only continue if we're still active
    if (t.draw_active) {
        if (t.nextPresentTimerDelayMs()) |delay_ms| {
            t.draw_h.run(&t.loop, &t.draw_c, delay_ms, Thread, t, drawCallback);
            if (apprt.runtime == apprt.win32) {
                t.draw_timer_due_ms = win32_power.tickCountMs() +| delay_ms;
            }
        } else {
            t.draw_active = false;
        }
    }

    return .disarm;
}

test "draw timer shortens an active slow interval" {
    try std.testing.expect(timerNeedsEarlierDeadline(100, 1100, 8));
    try std.testing.expect(!timerNeedsEarlierDeadline(1095, 1100, 8));
    try std.testing.expect(!timerNeedsEarlierDeadline(100, 108, 8));
    try std.testing.expect(timerNeedsEarlierDeadline(100, 0, 8));
}

test "render follow-up timer shortens an active slow interval" {
    // A focus/config change from 1 fps to focused cadence must replace the
    // pending one-second follow-up with an 8 ms deadline.
    try std.testing.expect(timerNeedsEarlierDeadline(200, 1200, DRAW_INTERVAL));
    // Never postpone an already-earlier follow-up or reset an equal deadline.
    try std.testing.expect(!timerNeedsEarlierDeadline(200, 208, 1000));
    try std.testing.expect(!timerNeedsEarlierDeadline(200, 208, DRAW_INTERVAL));
}

fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // A reset has already armed the replacement follow-up. Leave its
        // pending flag and deadline intact when the canceled run reports back.
        error.Canceled => return .disarm,
        else => unreachable,
    };
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };
    t.render_followup_pending = false;
    t.render_timer_due_ms = 0;
    if (comptime @hasDecl(apprt.Surface, "noteRendererFollowupCallback")) {
        t.surface.noteRendererFollowupCallback();
    }
    switch (renderFollowupDecision(
        t.shouldContinueRenderFollowup(),
        t.renderFollowupWindowActive(),
    )) {
        .render => if (t.renderOnce(false)) t.scheduleRenderFollowup(),
        .poll => t.scheduleRenderFollowup(),
        .stop => {},
    }

    return .disarm;
}

const RenderFollowupDecision = enum { stop, poll, render };

fn renderFollowupDecision(dirty: bool, window_active: bool) RenderFollowupDecision {
    if (dirty) return .render;
    if (window_active) return .poll;
    return .stop;
}

fn cursorTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in cursor timer callback err={}", .{err});
            unreachable;
        },
    };

    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };

    // Input or focus regain may have requested a fresh interval while this
    // completion was already queued. Honor the remaining logical delay here,
    // from the timer's own callback, rather than resetting the queued object.
    const reset_elapsed_ns: ?u64 = if (t.flags.focused)
        if (t.cursor_blink_reset_at) |reset_at| elapsed: {
            const now = std.time.Instant.now() catch break :elapsed 0;
            break :elapsed now.since(reset_at);
        } else null
    else
        null;
    switch (cursorBlinkTimerDecision(
        t.flags.focused,
        t.cursorShouldBlink(),
        cursorBlinkInterval(),
        reset_elapsed_ns,
    )) {
        .disarm => {
            // An unfocused surface needs no recurring cursor timer. Focus
            // regain will arm a new one once this callback has been popped.
            const was_visible = t.flags.cursor_blink_visible;
            t.flags.cursor_blink_visible = true;
            t.cursor_blink_reset_at = null;
            if (!was_visible) {
                t.wakeup.notify() catch {};
            }
            return .disarm;
        },
        .rearm_after => |delay_ms| {
            t.armCursorTimerIfDead(delay_ms);
            return .disarm;
        },
        .toggle => t.cursor_blink_reset_at = null,
    }

    t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;
    t.wakeup.notify() catch {};

    t.armCursorTimerIfDead(cursorBlinkInterval());
    return .disarm;
}

// fn prepFrameCallback(h: *libuv.Prepare) void {
//     _ = h;
//
//     tracy.frameMark();
// }

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

/// Returns the interval for the blinking cursor in milliseconds.
fn cursorBlinkInterval() u64 {
    var interval: u64 = CURSOR_BLINK_INTERVAL;
    if (std.valgrind.runningOnValgrind() > 0) {
        // If we're running under Valgrind, the cursor blink adds enough
        // churn that it makes some stalls annoying unless you're on a
        // super powerful computer, so we delay it.
        //
        // This is a hack, we should change some of our cursor timer
        // logic to be more efficient:
        // https://github.com/ghostty-org/ghostty/issues/8003
        interval *= 5;
    }

    return interval;
}

fn cursorBlinkRemainingMs(interval_ms: u64, elapsed_ns: u64) u64 {
    const interval_ns = interval_ms *| std.time.ns_per_ms;
    const remaining_ns = interval_ns -| elapsed_ns;
    return remaining_ns / std.time.ns_per_ms +
        @intFromBool(remaining_ns % std.time.ns_per_ms != 0);
}

const CursorBlinkTimerDecision = union(enum) {
    disarm,
    rearm_after: u64,
    toggle,
};

fn cursorBlinkTimerDecision(
    focused: bool,
    blinking: bool,
    interval_ms: u64,
    reset_elapsed_ns: ?u64,
) CursorBlinkTimerDecision {
    if (!focused or !blinking) return .disarm;
    if (reset_elapsed_ns) |elapsed_ns| {
        const remaining_ms = cursorBlinkRemainingMs(interval_ms, elapsed_ns);
        if (remaining_ms > 0) return .{ .rearm_after = remaining_ms };
    }
    return .toggle;
}

test "cursor blink reset deadline rounds up and clamps" {
    const testing = std.testing;

    try testing.expectEqual(@as(u64, 500), cursorBlinkRemainingMs(500, 0));
    try testing.expectEqual(@as(u64, 500), cursorBlinkRemainingMs(500, 1));
    try testing.expectEqual(
        @as(u64, 1),
        cursorBlinkRemainingMs(500, 500 * std.time.ns_per_ms - 1),
    );
    try testing.expectEqual(
        @as(u64, 0),
        cursorBlinkRemainingMs(500, 500 * std.time.ns_per_ms),
    );
    try testing.expectEqual(
        @as(u64, 0),
        cursorBlinkRemainingMs(500, 750 * std.time.ns_per_ms),
    );
}

test "cursor blink timer decision preserves focus and reset state" {
    const testing = std.testing;

    try testing.expectEqual(
        CursorBlinkTimerDecision.disarm,
        cursorBlinkTimerDecision(false, true, 500, 1),
    );
    try testing.expectEqual(
        CursorBlinkTimerDecision.toggle,
        cursorBlinkTimerDecision(true, true, 500, null),
    );
    try testing.expectEqual(
        CursorBlinkTimerDecision{ .rearm_after = 500 },
        cursorBlinkTimerDecision(true, true, 500, 1),
    );
    try testing.expectEqual(
        CursorBlinkTimerDecision.toggle,
        cursorBlinkTimerDecision(true, true, 500, 500 * std.time.ns_per_ms),
    );
}

test "cursor blink timer disarms for a steady cursor" {
    const testing = std.testing;

    try testing.expectEqual(
        CursorBlinkTimerDecision.disarm,
        cursorBlinkTimerDecision(true, false, 500, null),
    );
}

test "render followup does not redraw a clean terminal" {
    const testing = std.testing;

    try testing.expectEqual(RenderFollowupDecision.poll, renderFollowupDecision(false, true));
    try testing.expectEqual(RenderFollowupDecision.render, renderFollowupDecision(true, true));
    try testing.expectEqual(RenderFollowupDecision.stop, renderFollowupDecision(false, false));
}

test "renderer follow-up check tracks visible terminal dirtiness" {
    const testing = std.testing;

    var term = try terminalpkg.Terminal.init(testing.allocator, .{
        .cols = 4,
        .rows = 3,
    });
    defer term.deinit(testing.allocator);

    try testing.expect(!terminal_render_dirty.needsRendererWake(&term));

    term.flags.dirty.palette = true;
    try testing.expect(terminal_render_dirty.needsRendererWake(&term));
    term.flags.dirty = .{};

    term.screens.active.kitty_images.dirty = true;
    try testing.expect(terminal_render_dirty.needsRendererWake(&term));
    term.screens.active.kitty_images.dirty = false;

    try term.printString("x");
    try testing.expect(terminal_render_dirty.needsRendererWake(&term));
}

test "send wakes the renderer before waiting on a full mailbox" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // This is the deadlock from the original bug, in miniature: a full
    // mailbox whose consumer is asleep and only drains once woken. If
    // `send` pushes before notifying, nothing ever wakes the consumer and
    // the push waits forever.
    var mailbox = try Mailbox.create(alloc);
    defer mailbox.destroy(alloc);

    var filled: usize = 0;
    while (mailbox.push(.{ .reset_cursor_blink = {} }, .{ .instant = {} }) != 0) {
        filled += 1;
    }
    try testing.expect(filled > 0);

    // Confirm the mailbox really is full before we test the blocking path.
    try testing.expectEqual(
        @as(Mailbox.Size, 0),
        mailbox.push(.{ .focus = true }, .{ .instant = {} }),
    );

    const Consumer = struct {
        loop: xev.Loop,
        wakeup: *xev.Async,
        wakeup_c: xev.Completion = .{},
        guard: xev.Timer,
        guard_c: xev.Completion = .{},
        mailbox: *Mailbox,
        to_drain: usize,
        woken: bool = false,
        ready: std.atomic.Value(bool) = .init(false),

        const Consumer = @This();

        /// Pop exactly the messages we pre-filled, leaving whatever the
        /// sender adds. Draining until empty would race the sender's push.
        fn drain(self: *Consumer) void {
            for (0..self.to_drain) |_| _ = self.mailbox.pop();
            self.loop.stop();
        }

        fn onWake(
            self_: ?*Consumer,
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            _ = r catch {};
            const self = self_.?;
            self.woken = true;
            self.drain();
            return .disarm;
        }

        fn onGuard(
            self_: ?*Consumer,
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = r catch {};
            // Safety valve. On a regression the wakeup never arrives, so we
            // drain anyway and let the `woken` assertion fail rather than
            // hanging the test suite forever.
            self_.?.drain();
            return .disarm;
        }

        fn run(self: *Consumer) void {
            self.wakeup.wait(&self.loop, &self.wakeup_c, Consumer, self, onWake);
            self.guard.run(&self.loop, &self.guard_c, 5000, Consumer, self, onGuard);
            self.ready.store(true, .release);
            self.loop.run(.until_done) catch {};
        }
    };

    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    var consumer: Consumer = .{
        .loop = try xev.Loop.init(.{}),
        .wakeup = &wakeup,
        .guard = try xev.Timer.init(),
        .mailbox = mailbox,
        .to_drain = filled,
    };
    defer consumer.loop.deinit();
    defer consumer.guard.deinit();

    const consumer_thread = try std.Thread.spawn(.{}, Consumer.run, .{&consumer});
    while (!consumer.ready.load(.acquire)) std.Thread.yield() catch {};

    sendMessage(&wakeup, mailbox, .{ .focus = true });
    consumer_thread.join();

    // The consumer was woken by `send`, not by the safety valve.
    try testing.expect(consumer.woken);

    // And the message was delivered rather than dropped.
    const delivered = mailbox.pop();
    try testing.expect(delivered != null);
    try testing.expect(std.meta.activeTag(delivered.?) == .focus);
    try testing.expect(mailbox.pop() == null);
}
