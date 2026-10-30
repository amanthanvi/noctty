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
const Pacer = @import("Pacer.zig");

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

const CURSOR_BLINK_INTERVAL = 600;
const RENDER_FOLLOWUP_BURST_MS = 128;

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
/// Absolute `pacingClockMs` time when the active render follow-up should fire.
render_timer_due_ms: u64 = 0,
present_pacer: PresentPacer = .{},
/// Set when pacing deferred a frame update (`renderOnce` found the present
/// slot taken) and cleared when one runs. The animation draw timer checks it:
/// a draw-only tick that takes the slot would otherwise present stale frame
/// data and push the deferred update out again, every interval (#297).
frame_update_deferred: bool = false,
/// Which passes present a frame synchronized output holds.
held_frame: HeldFrame = .{},

/// The timer used for draw calls. Draw calls don't update from the
/// terminal state so they're much cheaper. They're used for animation
/// and are paused when the terminal is not focused.
draw_h: xev.Timer,
draw_c: xev.Completion = .{},
draw_reset_c: xev.Completion = .{},
draw_active: bool = false,
/// Absolute `pacingClockMs` time when the active draw timer should fire.
/// This lets a focus or power-policy change shorten an already-queued slow
/// interval.
draw_timer_due_ms: u64 = 0,

/// This async is used to force a draw immediately. This does not
/// coalesce like the wakeup does. Only a display link notifies it, so it
/// never fires on Win32.
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

/// Time and power for pacing, from the apprt when it has them.
clock: Pacer.Clock,

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
    pacing: Pacer.Config,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .custom_shader_animation = config.@"custom-shader-animation",
            .pacing = .init(config),
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
        .clock = if (@hasDecl(apprt.App, "renderer_pacing_clock"))
            apprt.App.renderer_pacing_clock
        else
            .monotonic,
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
    self.state.noteWakeSource(.thread_start);
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
        if (comptime @hasDecl(rendererpkg.Renderer, "hasPendingPresentation")) {
            if (self.renderer.hasPendingPresentation()) break :skip;
        }
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

    const delay_ms = self.nextDrawTimerDelayMs() orelse {
        self.draw_active = false;
        return;
    };

    if (self.draw_c.state() == .active) {
        if (apprt.runtime != apprt.win32) return;

        const now_ms = self.pacingClockMs();
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
        self.draw_timer_due_ms = self.pacingClockMs() +| delay_ms;
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
    self.state.noteWakeSource(.mailbox);
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
        self.held_frame.noteMessage(std.meta.activeTag(message));
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
                if (v) self.present_pacer = .{};

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

            .split_dimmed => |v| self.renderer.setSplitDimmed(v),

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
                self.renderer.setSearchMatches(payload);
            },

            .search_selected_match => |v| search: {
                var payload = v;
                if (!self.shouldAcceptSearchGeneration(payload.generation)) {
                    payload.deinit();
                    break :search;
                }

                // Note we don't free the new value because we expect our
                // allocators to match.
                self.renderer.setSearchSelectedMatch(payload.match);
            },

            .search_clear => |generation| search: {
                if (!self.shouldAcceptSearchGeneration(generation)) break :search;
                self.renderer.setSearchMatches(null);
                self.renderer.setSearchSelectedMatch(null);
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

fn pacingClockMs(self: *const Thread) u64 {
    return self.clock.now_ns(self.clock.ctx) / std.time.ns_per_ms;
}

fn minimumPresentIntervalMs(self: *const Thread) ?u64 {
    if (apprt.runtime != apprt.win32) {
        return if (self.flags.visible) Pacer.draw_interval_ms else null;
    }
    return Pacer.minimumPresentIntervalMs(
        self.flags.focused,
        self.flags.visible,
        self.clock.saver(self.clock.ctx),
        self.config.pacing,
    );
}

fn presentWaitMs(self: *const Thread, interval_ms: u64) u64 {
    return self.present_pacer.waitMs(self.pacingClockMs(), interval_ms);
}

fn nextPresentTimerDelayMs(self: *const Thread) ?u64 {
    const interval_ms = self.minimumPresentIntervalMs() orelse return null;
    const wait_ms = self.presentWaitMs(interval_ms);
    return if (wait_ms > 0) wait_ms else interval_ms;
}

fn nextDrawTimerDelayMs(self: *const Thread) ?u64 {
    const delay = self.nextPresentTimerDelayMs() orelse return null;
    if (comptime @hasDecl(rendererpkg.Renderer, "hasPendingPresentation")) {
        if (self.renderer.hasPendingPresentation()) return @max(250, delay);
    }
    return delay;
}

fn notePresentRequest(self: *Thread, interval_ms: u64) void {
    self.present_pacer.take(self.pacingClockMs(), interval_ms);
}

/// When a throttled surface may present again. It takes the clock as an
/// argument so the tests can drive it.
const PresentPacer = struct {
    /// Start of the present slot taken last, or 0 when the next present
    /// need not wait.
    slot_ms: u64 = 0,

    /// How long a present must still wait. Intervals at or below
    /// `Pacer.draw_interval_ms` are not paced.
    fn waitMs(self: PresentPacer, now_ms: u64, interval_ms: u64) u64 {
        if (interval_ms <= Pacer.draw_interval_ms or self.slot_ms == 0) return 0;
        return interval_ms -| (now_ms -| self.slot_ms);
    }

    /// Take the slot for a present requested at `now_ms`. The timer that
    /// wakes a throttled surface expires on a system tick (15.6 ms), so a
    /// present can land most of a tick after its slot opened. Starting the
    /// slot when it opened rather than when the present came keeps the
    /// configured rate; without it every interval grew to the next tick, 34
    /// to 47 ms. A present later than that (output that came late, idle)
    /// starts a new cadence, so no catch-up burst follows it.
    fn take(self: *PresentPacer, now_ms: u64, interval_ms: u64) void {
        if (interval_ms <= Pacer.draw_interval_ms) {
            self.slot_ms = 0;
            return;
        }
        const late_ms = if (self.slot_ms == 0) 0 else now_ms -| (self.slot_ms +| interval_ms);
        const credit = late_ms <= timer_tick_ms and late_ms < interval_ms;
        self.slot_ms = if (credit) now_ms - late_ms else now_ms;
    }

    /// The default system timer tick, 15.625 ms, rounded up.
    const timer_tick_ms = 16;
};

test "present pacer paces only throttled intervals" {
    const testing = std.testing;

    var pacer: PresentPacer = .{};
    try testing.expectEqual(@as(u64, 0), pacer.waitMs(1000, 34));
    pacer.take(1000, 34);
    try testing.expectEqual(@as(u64, 24), pacer.waitMs(1010, 34));
    try testing.expectEqual(@as(u64, 0), pacer.waitMs(1034, 34));

    // A focused surface is not paced, and its presents leave no slot behind.
    try testing.expectEqual(@as(u64, 0), pacer.waitMs(1010, Pacer.draw_interval_ms));
    pacer.take(1010, Pacer.draw_interval_ms);
    try testing.expectEqual(@as(u64, 0), pacer.waitMs(1011, 34));
}

test "present pacer keeps its rate when wakes land on the system tick" {
    const testing = std.testing;

    // Timer-driven presents (a deferred follow-up, a paced shader
    // animation): xev's IOCP timer wakes on the first 15.625 ms system tick
    // at or after its deadline, so each present lands up to a tick late.
    const tick = struct {
        fn atOrAfter(ms: u64) u64 {
            const k = (ms * 1000 + 15624) / 15625;
            return k * 15625 / 1000;
        }
    };

    // 60, 50, 30 (the default and the saver's 34 ms), 20 and 15 fps.
    for ([_]u64{ 17, 20, 34, 50, 67 }) |interval_ms| {
        var pacer: PresentPacer = .{};
        const start_ms: u64 = 1000;
        var now_ms = start_ms;
        pacer.take(now_ms, interval_ms);
        var previous_ms = now_ms;
        const presents = 300;
        for (0..presents) |_| {
            while (pacer.waitMs(now_ms, interval_ms) > 0) {
                now_ms = tick.atOrAfter(now_ms + pacer.waitMs(now_ms, interval_ms));
            }
            pacer.take(now_ms, interval_ms);
            // Credit for a late present never brings two in one tick.
            try testing.expect(now_ms - previous_ms >= 15);
            previous_ms = now_ms;
        }

        // The configured interval on average, not the next tick after it
        // (34 ms measured from each present would be 46.875 ms, 17 ms 31.25).
        const average_ms = (now_ms - start_ms) / presents;
        try testing.expect(average_ms >= interval_ms - 1 and average_ms <= interval_ms);
    }
}

test "present pacer credits only a timer tick of lateness" {
    const testing = std.testing;

    var pacer: PresentPacer = .{};
    pacer.take(1000, 34);
    // 10 ms late, as a tick-bound timer is: the next slot opens 34 ms
    // after this one should have.
    pacer.take(1044, 34);
    try testing.expectEqual(@as(u64, 24), pacer.waitMs(1044, 34));
    // More than a tick late (output came late): a full interval from now,
    // so the next present cannot follow this one almost at once.
    pacer.take(1088, 34);
    try testing.expectEqual(@as(u64, 34), pacer.waitMs(1088, 34));
    pacer.take(5000, 1000);
    pacer.take(6999, 1000);
    try testing.expectEqual(@as(u64, 1000), pacer.waitMs(6999, 1000));
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) void {
    _ = self.drawFrameWithReservation(now, false);
}

/// Release a repaint reservation no paint will complete.
fn cancelRepaintReservation(self: *Thread) void {
    if (comptime @hasDecl(apprt.Surface, "cancelRendererRepaintRequest")) {
        self.surface.cancelRendererRepaintRequest();
    }
}

/// Returns whether a paint was queued (or, off the app thread, drawn).
fn drawFrameWithReservation(self: *Thread, now: bool, repaint_reserved: bool) bool {
    // A caller-held reservation must be released on every path that does not
    // hand it to a paint. Leaking one leaves renderer_repaint_requested set
    // forever, after which every later repaint coalesces into a request that
    // is never finished and the pane stops updating until a resize-settle or
    // health recovery cancels it.
    var reservation_held = repaint_reserved;
    defer if (reservation_held) self.cancelRepaintReservation();

    const interval_ms = self.minimumPresentIntervalMs() orelse return false;

    // `now` is upstream's forced path (`drawNowCallback`), which pacing does
    // not apply to. Only a display link notifies `draw_now`, and the Win32
    // renderer has none (`DisplayLink` is void), so on Win32 every draw is
    // paced here, including the ones the apprt asks for with a wake when a
    // WM_PAINT finds no frame reserved.
    if (!now and self.presentWaitMs(interval_ms) > 0) return false;

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`. Never true on Win32 (`hasVsync`).
    if (!now and self.renderer.hasVsync()) return false;

    if (must_draw_from_app_thread) {
        if (comptime @hasDecl(apprt.Surface, "noteRendererDrawRequest")) {
            self.surface.noteRendererDrawRequest();
        }
        if (comptime @hasDecl(apprt.Surface, "beginRendererRepaintRequest")) {
            if (!repaint_reserved and !self.surface.beginRendererRepaintRequest()) return false;
        }

        // From here the reservation belongs to the queued paint: either the
        // paint completes it, or the failed push below cancels it.
        reservation_held = false;

        if (self.app_mailbox.push(
            .{ .redraw_surface = self.surface },
            .{ .instant = {} },
        ) == 0) {
            self.cancelRepaintReservation();
            return false;
        }
        self.notePresentRequest(interval_ms);
        return true;
    } else {
        // Not taken on Win32, which draws from the app thread. Nothing will
        // complete a reservation on this path, so the deferred cancel above
        // releases it once the synchronous draw returns.
        self.renderer.drawFrame(false) catch |err| {
            log.warn("error drawing err={}", .{err});
            return false;
        };
        self.notePresentRequest(interval_ms);
        return true;
    }
}

fn scheduleRenderFollowup(self: *Thread) void {
    const delay_ms = self.nextPresentTimerDelayMs() orelse return;

    if (self.render_followup_pending) {
        if (apprt.runtime != apprt.win32) return;

        const now_ms = self.pacingClockMs();
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
        self.render_timer_due_ms = self.pacingClockMs() +| delay_ms;
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

    if (followupOwesFrameUpdate(self.frame_update_deferred, self.draw_active)) return true;

    self.state.mutex.lock();
    defer self.state.mutex.unlock();
    return terminal_render_dirty.needsFrame(self.state.terminal, self.state.drawn_undirtied);
}

/// What runs a render pass.
const RenderPass = union(enum) {
    /// A wake, with the sources it was asked for.
    wake: u32,
    /// The render follow-up timer.
    followup,
    /// The custom-shader draw timer, carrying a deferred frame update.
    animation,
};

fn renderOnce(self: *Thread, pass: RenderPass) bool {
    const from_wakeup = pass == .wake;
    self.held_frame.noteWake(pass);

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
    if (self.presentWaitMs(interval_ms) > 0) {
        self.frame_update_deferred = true;
        return true;
    }

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

    // updateFrame returns the cursor mode from the same locked terminal
    // snapshot used to rebuild this frame.
    self.frame_update_deferred = false;
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
    if (frame_update) |update| {
        if (comptime @hasDecl(apprt.Surface, "noteRendererUpdateFrame")) {
            self.surface.noteRendererUpdateFrame(update.output_progress, cursor_blinking);
        }
    }
    if (!cursor_blinking) self.flags.cursor_blink_visible = true;
    if (self.flags.focused and cursor_blinking) {
        self.armCursorTimerIfDead(cursorBlinkInterval());
    }

    // Synchronized output held the frame, so a present would show the same
    // pixels again, once per follow-up until it ends. termio's 1 s reset
    // always wakes the renderer, an ESU only when it brings dirt, so the
    // update stays owed and the follow-up polls for a clean ESU.
    const held = if (frame_update) |update| update.synchronized_output else false;
    if (held) self.frame_update_deferred = true;
    if (held and !self.held_frame.presents(pass, self.draw_active)) {
        if (repaint_reserved) self.cancelRepaintReservation();
        return true;
    }

    // Draw. An owed repaint stays owed when no paint could be queued (a
    // full app mailbox), so a later pass presents the held frame.
    if (self.drawFrameWithReservation(false, repaint_reserved)) self.held_frame.notePresent();

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
    // Take the accumulated reasons on every wake, so a later wake is never
    // blamed on an earlier notify.
    const wake_sources = t.state.takeWakeSources();
    if (comptime @hasDecl(apprt.Surface, "noteRendererWakeupCallback")) {
        t.surface.noteRendererWakeupCallback(wake_sources);
    }
    if (t.renderOnce(.{ .wake = wake_sources })) {
        t.scheduleRenderFollowup();
    }
    // A UI-thread backend atomically requests presentation retries. Reconcile
    // after every wake rather than relying on room in the bounded mailbox.
    if (comptime @hasDecl(rendererpkg.Renderer, "hasPendingPresentation")) {
        if (t.renderer.takePresentationPendingChanged()) t.syncDrawTimer();
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

    // Draw. When pacing has deferred a frame update, this tick carries it
    // instead: both paths share one present slot per interval, and a
    // draw-only tick would keep the slot while presenting stale frame data.
    if (t.frame_update_deferred) {
        if (t.renderOnce(.animation)) t.scheduleRenderFollowup();
    } else {
        t.drawFrame(false);
    }

    // Only continue if we're still active. `renderOnce` drains the mailbox,
    // and a focus, visibility or config message there runs `syncDrawTimer`,
    // which may already have re-armed this (dead) completion. Running it a
    // second time would corrupt libxev's timer queue.
    if (t.draw_active and t.draw_c.state() == .dead) {
        if (t.nextDrawTimerDelayMs()) |delay_ms| {
            t.draw_h.run(&t.loop, &t.draw_c, delay_ms, Thread, t, drawCallback);
            if (apprt.runtime == apprt.win32) {
                t.draw_timer_due_ms = t.pacingClockMs() +| delay_ms;
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
    try std.testing.expect(timerNeedsEarlierDeadline(200, 1200, Pacer.draw_interval_ms));
    // Never postpone an already-earlier follow-up or reset an equal deadline.
    try std.testing.expect(!timerNeedsEarlierDeadline(200, 208, 1000));
    try std.testing.expect(!timerNeedsEarlierDeadline(200, 208, Pacer.draw_interval_ms));
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
        t.state.wakePending(),
    )) {
        .render => if (t.renderOnce(.followup)) t.scheduleRenderFollowup(),
        .poll => t.scheduleRenderFollowup(),
        .stop => {},
    }

    return .disarm;
}

const RenderFollowupDecision = enum { stop, poll, render };

/// `wake_pending`: a wake has been asked for and its callback has not run
/// yet. The loop runs a due follow-up timer before that callback, so output
/// that both made the terminal dirty and asked for the wake reaches the
/// timer first. The wake renders it; if the timer did too, the wake would
/// find the paint slot taken and present the same frame again after it.
fn renderFollowupDecision(dirty: bool, window_active: bool, wake_pending: bool) RenderFollowupDecision {
    if (dirty and !wake_pending) return .render;
    if (dirty or window_active) return .poll;
    return .stop;
}

/// A frame update pacing put off is still owed, dirt or not (a search
/// highlight, a config change, a scroll to the bottom, a blink). The
/// custom-shader draw timer carries it while it runs (#297); without it
/// only the follow-up will.
fn followupOwesFrameUpdate(deferred: bool, draw_active: bool) bool {
    return deferred and !draw_active;
}

/// Which render passes present a frame synchronized output holds: the
/// custom-shader draw timer's, which animates over it, and any pass while
/// the apprt is owed pixels.
const HeldFrame = struct {
    /// The apprt woke the renderer because a window needs its pixels drawn
    /// (`wakeNeedsPixels`) and no present was queued since. A WM_PAINT that
    /// finds no frame reserved draws nothing itself, so without this an
    /// exposed or newly shown pane stays blank until the hold ends. It
    /// outlives a pass pacing puts off, so the follow-up that runs the
    /// deferred update presents for it.
    repaint_owed: bool = false,

    fn noteWake(self: *HeldFrame, pass: RenderPass) void {
        switch (pass) {
            .wake => |sources| if (wakeNeedsPixels(sources)) {
                self.repaint_owed = true;
            },
            .followup, .animation => {},
        }
    }

    /// A mailbox message that changes what the frame shows by itself (a
    /// split's dim): the terminal holding its output does not hold that
    /// back, and the message's wake alone does not present a held frame.
    fn noteMessage(self: *HeldFrame, message: std.meta.Tag(rendererpkg.Message)) void {
        if (message == .split_dimmed) self.repaint_owed = true;
    }

    fn presents(self: HeldFrame, pass: RenderPass, draw_active: bool) bool {
        return self.repaint_owed or (pass == .animation and draw_active);
    }

    fn notePresent(self: *HeldFrame) void {
        self.repaint_owed = false;
    }
};

/// Wakes from the apprt for a window that needs its pixels drawn again
/// (exposed, newly shown, resized, recovering): a frame synchronized output
/// holds is presented anyway for these.
fn wakeNeedsPixels(wake_sources: u32) bool {
    const Source = rendererpkg.State.WakeSource;
    const pixels = Source.apprt_paint_retry.bit() |
        Source.apprt_first_show.bit() |
        Source.apprt_resize_settle.bit() |
        Source.apprt_health_recovery.bit();
    return wake_sources & pixels != 0;
}

test "render follow-up carries a deferred update unless the shader timer does" {
    const testing = std.testing;

    // A throttled surface whose only change is renderer-side: nothing is
    // dirty, so only the owed update keeps the follow-up rendering.
    try testing.expect(followupOwesFrameUpdate(true, false));
    try testing.expectEqual(RenderFollowupDecision.render, renderFollowupDecision(followupOwesFrameUpdate(true, false), false, false));
    // The draw timer runs renderOnce for it; the follow-up would re-defer
    // at every slot the timer took.
    try testing.expect(!followupOwesFrameUpdate(true, true));
    try testing.expect(!followupOwesFrameUpdate(false, false));
}

test "a frame synchronized output holds is presented only for animation and owed repaints" {
    const testing = std.testing;
    const Source = rendererpkg.State.WakeSource;

    var held: HeldFrame = .{};
    // Output, a blink or the follow-up: the held frame is not presented.
    held.noteWake(.{ .wake = Source.io_output.bit() | Source.cursor_blink.bit() });
    try testing.expect(!held.presents(.{ .wake = Source.io_output.bit() }, false));
    try testing.expect(!held.presents(.followup, false));
    // The shader draw timer's pass animates over it, but not once the
    // timer has stopped (focus left a `custom-shader-animation = true` pane).
    try testing.expect(held.presents(.animation, true));
    try testing.expect(!held.presents(.animation, false));
    // A follow-up while the draw timer runs does not present it twice.
    try testing.expect(!held.presents(.followup, true));

    // An expose: its wake's pass is put off by pacing, so the repaint stays
    // owed and the follow-up that runs next presents the held frame.
    held.noteWake(.{ .wake = Source.apprt_paint_retry.bit() });
    try testing.expect(held.presents(.followup, false));
    held.noteWake(.followup);
    try testing.expect(held.presents(.followup, false));
    held.notePresent();
    try testing.expect(!held.presents(.followup, false));
}

test "a split dim change presents a frame synchronized output holds" {
    const testing = std.testing;
    const Source = rendererpkg.State.WakeSource;

    // The change arrives as a mailbox message, whose wake alone does not
    // present a held frame; the message makes the pass present it. Messages
    // that change no pixels the renderer draws by itself do not.
    var held: HeldFrame = .{};
    held.noteWake(.{ .wake = Source.mailbox.bit() });
    try testing.expect(!held.presents(.{ .wake = Source.mailbox.bit() }, false));
    held.noteMessage(.focus);
    held.noteMessage(.visible);
    held.noteMessage(.reset_cursor_blink);
    try testing.expect(!held.presents(.{ .wake = Source.mailbox.bit() }, false));
    held.noteMessage(std.meta.activeTag(rendererpkg.Message{ .split_dimmed = true }));
    try testing.expect(held.presents(.{ .wake = Source.mailbox.bit() }, false));
    // Pacing put the pass off: the follow-up that runs it presents.
    try testing.expect(held.presents(.followup, false));
    held.notePresent();
    try testing.expect(!held.presents(.followup, false));
}

test "only apprt repaint wakes present a frame synchronized output holds" {
    const testing = std.testing;
    const Source = rendererpkg.State.WakeSource;

    try testing.expect(!wakeNeedsPixels(0));
    try testing.expect(!wakeNeedsPixels(Source.io_output.bit() | Source.mailbox.bit()));
    try testing.expect(!wakeNeedsPixels(Source.cursor_blink.bit() | Source.core_surface.bit()));
    // A paint completing behind a newer frame is the renderer's own retry,
    // and a paint request folded into a pending one forces that paint,
    // whose WM_PAINT asks again (`apprt_paint_retry`) if it has no frame.
    try testing.expect(!wakeNeedsPixels(Source.apprt_repaint_retry.bit()));
    try testing.expect(!wakeNeedsPixels(Source.apprt_paint_pending.bit()));
    try testing.expect(wakeNeedsPixels(Source.apprt_paint_retry.bit()));
    try testing.expect(wakeNeedsPixels(Source.io_output.bit() | Source.apprt_first_show.bit()));
    try testing.expect(wakeNeedsPixels(Source.apprt_resize_settle.bit()));
    try testing.expect(wakeNeedsPixels(Source.apprt_health_recovery.bit()));
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
                t.state.noteWakeSource(.cursor_blink);
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
    t.state.noteWakeSource(.cursor_blink);
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

    try testing.expectEqual(RenderFollowupDecision.poll, renderFollowupDecision(false, true, false));
    try testing.expectEqual(RenderFollowupDecision.render, renderFollowupDecision(true, true, false));
    try testing.expectEqual(RenderFollowupDecision.stop, renderFollowupDecision(false, false, false));
}

test "render followup leaves dirt to a wake already on its way" {
    const testing = std.testing;

    try testing.expectEqual(RenderFollowupDecision.render, renderFollowupDecision(true, false, false));
    try testing.expectEqual(RenderFollowupDecision.poll, renderFollowupDecision(true, true, true));
    try testing.expectEqual(RenderFollowupDecision.poll, renderFollowupDecision(true, false, true));
    try testing.expectEqual(RenderFollowupDecision.poll, renderFollowupDecision(false, true, true));
    try testing.expectEqual(RenderFollowupDecision.stop, renderFollowupDecision(false, false, true));
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
