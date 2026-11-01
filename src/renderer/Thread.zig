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

/// The render follow-up timer: it keeps rendering while output streams in
/// faster than the async wakes deliver it, and runs an update pacing put off.
followup_h: xev.Timer,
followup_c: xev.Completion = .{},
followup_reset_c: xev.Completion = .{},

/// The timer used for draw calls. Draw calls don't update from the
/// terminal state so they're much cheaper. They're used for animation
/// and are paused when the terminal is not focused.
draw_h: xev.Timer,
draw_c: xev.Completion = .{},
draw_reset_c: xev.Completion = .{},

/// This async is used to force a draw immediately. This does not
/// coalesce like the wakeup does. Only a display link notifies it, so it
/// never fires on Win32.
draw_now: xev.Async,
draw_now_c: xev.Completion = .{},

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},

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

/// When this thread updates and presents frames, and arms its timers.
pacer: Pacer,

flags: packed struct {
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

    // The render follow-up timer.
    var followup_h = try xev.Timer.init();
    errdefer followup_h.deinit();

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
        .pacer = .init(if (@hasDecl(apprt.App, "renderer_pacing_clock"))
            apprt.App.renderer_pacing_clock
        else
            .monotonic),
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .followup_h = followup_h,
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
    self.followup_h.deinit();
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

/// Drain the mailbox, reporting in `changes` what pacing reads.
fn drainMailbox(self: *Thread, changes: *std.EnumSet(Pacer.Change)) !void {
    // There's probably a more elegant way to do this...
    //
    // This is effectively an @autoreleasepool{} block, which we need in
    // order to ensure that autoreleased objects are properly released.
    const pool = darwin.beginAutoreleasePool();
    defer darwin.endAutoreleasePool(pool);

    while (self.mailbox.pop()) |message| {
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
                // It no longer does (hidden surfaces skip `updateFrame`), so
                // the pacer's pass after this drain updates and presents at
                // once, unpaced.
                changes.insert(.visibility);

                // Notify the renderer so it can update any state.
                self.renderer.setVisible(v);
            },

            .focus => |v| focus: {
                // If our state didn't change we do nothing.
                if (self.flags.focused == v) break :focus;

                // Set our state
                self.flags.focused = v;

                // Focus affects our QoS class
                self.setQosClass();
                changes.insert(.focus);

                // Set it on the renderer
                try self.renderer.setFocus(v);
            },

            .split_dimmed => |v| {
                self.renderer.setSplitDimmed(v);
                changes.insert(.repaint);
            },

            .reset_cursor_blink => changes.insert(.blink_reset),

            .font_grid => |grid| {
                self.renderer.setFontGrid(grid.grid);
                grid.set.deref(grid.old_key);
            },

            .resize => |v| self.renderer.setScreenSize(v),

            .change_config => |config| {
                defer config.alloc.destroy(config.thread);
                defer config.alloc.destroy(config.impl);
                try self.changeConfig(config.thread);
                changes.insert(.config);
                try self.renderer.changeConfig(config.impl);
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
}

fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    self.config = config.*;
}

fn shouldAcceptSearchGeneration(self: *const Thread, generation: u64) bool {
    return self.search_generation.load(.acquire) == generation;
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
        return true;
    } else {
        // Not taken on Win32, which draws from the app thread. Nothing will
        // complete a reservation on this path, so the deferred cancel above
        // releases it once the synchronous draw returns.
        self.renderer.drawFrame(false) catch |err| {
            log.warn("error drawing err={}", .{err});
            return false;
        };
        return true;
    }
}

/// renderer.Thread's adapter at the pacer's frame seam (`Pacer.turn`): the
/// mailbox drain, the terminal reads, the frame update and its present, and
/// the libxev timers.
const Frame = struct {
    t: *Thread,

    pub fn drain(f: Frame) Pacer.Drained {
        var drained: Pacer.Drained = .{};
        f.t.drainMailbox(&drained.changes) catch |err| {
            log.err("error draining mailbox err={}", .{err});
            drained.failed = true;
        };
        // A UI-thread backend requests presentation retries atomically,
        // not through the bounded mailbox.
        if (comptime @hasDecl(rendererpkg.Renderer, "hasPendingPresentation")) {
            if (f.t.renderer.takePresentationPendingChanged()) drained.changes.insert(.presentation);
        }
        return drained;
    }

    pub fn inputs(f: Frame) Pacer.Inputs {
        return .{
            .focused = f.t.flags.focused,
            .visible = f.t.flags.visible,
            .config = f.t.config.pacing,
            .notified_ns = f.t.state.last_render_wakeup_notify_ns.load(.acquire),
        };
    }

    /// Takes State.mutex once.
    pub fn screen(f: Frame) Pacer.Screen {
        const state = f.t.state;
        state.mutex.lock();
        defer state.mutex.unlock();
        return .{
            .needs_frame = terminal_render_dirty.needsFrame(state.terminal, state.drawn_undirtied),
            .cursor_blinking = state.terminal.modes.get(.cursor_blinking),
            // After the dirt: termio records the wake for its output before
            // it unlocks.
            .wake_pending = state.wakePending(),
        };
    }

    /// Reads only the mode, so a blink decision does not walk the rows
    /// `needsFrame` checks on a clean terminal.
    pub fn cursorBlinking(f: Frame) bool {
        const state = f.t.state;
        state.mutex.lock();
        defer state.mutex.unlock();
        return state.terminal.modes.get(.cursor_blinking);
    }

    /// Null when the animation timer is not wanted.
    pub fn animation(f: Frame) ?Pacer.AnimationWake {
        const t = f.t;
        if (comptime @hasDecl(rendererpkg.Renderer, "hasPendingPresentation")) {
            // An occluded frame still needs a later Present(TEST), even with
            // a steady cursor and no output: retry at 4 Hz.
            if (t.renderer.hasPendingPresentation()) return .{ .delay_ms = 250 };
        }
        // If our renderer supports animations and has them, then we
        // can apply draw timer based on custom shader animation configuration.
        if (@hasDecl(rendererpkg.Renderer, "hasAnimations") and
            t.renderer.hasAnimations())
        {
            // If our config says to always animate, we do so.
            switch (t.config.custom_shader_animation) {
                // Always animate
                .always => return .{ .delay_ms = 0 },
                // Only when focused
                .true => if (t.flags.focused) return .{ .delay_ms = 0 },
                // Never animate
                .false => {},
            }
        }
        return null;
    }

    /// Owns the apprt repaint reservation: releases every one it does not
    /// hand to a queued paint.
    pub fn update(f: Frame, request: Pacer.Update) Pacer.UpdateResult {
        const t = f.t;
        var repaint_reserved = false;
        if (must_draw_from_app_thread and t.flags.visible and !t.renderer.hasVsync()) {
            if (comptime @hasDecl(apprt.Surface, "beginRendererFrameUpdate")) {
                if (!t.surface.beginRendererFrameUpdate()) return .coalesced;
                repaint_reserved = true;
            }
        }

        // updateFrame returns the cursor mode from the same locked terminal
        // snapshot used to rebuild this frame.
        const frame_update: ?rendererpkg.Renderer.FrameUpdate = t.renderer.updateFrame(
            t.state,
            request.blink_visible,
        ) catch |err| frame_update: {
            log.warn("error rendering err={}", .{err});
            break :frame_update null;
        };
        const cursor_blinking = if (frame_update) |done|
            done.cursor_blinking
        else
            f.screen().cursor_blinking;
        if (frame_update) |done| {
            if (comptime @hasDecl(apprt.Surface, "noteRendererUpdateFrame")) {
                t.surface.noteRendererUpdateFrame(done.output_progress, cursor_blinking);
            }
        }

        const held = if (frame_update) |done| done.synchronized_output else false;
        if (held and !request.present_held) {
            if (repaint_reserved) t.cancelRepaintReservation();
            return .{ .updated = .{
                .cursor_blinking = cursor_blinking,
                .held = true,
                .presented = false,
            } };
        }

        // Draw. An owed repaint stays owed when no paint could be queued (a
        // full app mailbox), so a later pass presents the held frame.
        return .{ .updated = .{
            .cursor_blinking = cursor_blinking,
            .held = held,
            .presented = t.drawFrameWithReservation(false, repaint_reserved),
        } };
    }

    /// Present the current frame data without updating it. Returns whether
    /// a paint was queued.
    pub fn draw(f: Frame) bool {
        return f.t.drawFrameWithReservation(false, false);
    }

    /// A dead completion runs. An active follow-up or animation completion
    /// is reset through its reset completion; an active cursor completion is
    /// left alone, because on IOCP `.active` can mean completed and queued
    /// for its callback, and reusing it corrupts libxev's completion queue.
    pub fn arm(f: Frame, timer: Pacer.Timer, delay_ms: u64) void {
        const t = f.t;
        switch (timer) {
            .followup => runOrReset(t, &t.followup_h, &t.followup_c, &t.followup_reset_c, delay_ms, timerCallback(.followup)),
            .animation => runOrReset(t, &t.draw_h, &t.draw_c, &t.draw_reset_c, delay_ms, timerCallback(.animation)),
            .blink => if (t.cursor_c.state() == .dead) {
                t.cursor_h.run(&t.loop, &t.cursor_c, delay_ms, Thread, t, timerCallback(.blink));
            },
        }
    }

    /// Record the source, then notify the wakeup async.
    pub fn wake(f: Frame, source: rendererpkg.State.WakeSource) void {
        f.t.state.noteWakeSource(source);
        notify(&f.t.wakeup);
    }
};

const TimerCallback = TimerCallbackOf(Thread);

fn TimerCallbackOf(comptime R: type) type {
    return *const fn (?*R, *xev.Loop, *xev.Completion, xev.Timer.RunError!void) xev.CallbackAction;
}

fn runOrReset(
    t: *Thread,
    h: *xev.Timer,
    c: *xev.Completion,
    reset_c: *xev.Completion,
    delay_ms: u64,
    comptime cb: TimerCallback,
) void {
    if (c.state() == .dead) {
        h.run(&t.loop, c, delay_ms, Thread, t, cb);
    } else {
        h.reset(&t.loop, c, reset_c, delay_ms, Thread, t, cb);
    }
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
    t.pacer.turn(.{ .wake = wake_sources }, Frame{ .t = t });

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

    // Draw immediately, outside the pacer. Only a display link notifies
    // draw_now, and Win32 has none (renderer.md 2026-10-15 PKG-37 (3)).
    _ = self_.?.drawFrameWithReservation(true, false);

    return .rearm;
}

/// A follow-up, animation or blink run: one `turn`. A run that
/// error.Canceled ends is still a run (`Pacer.Trigger.due`). On IOCP a
/// Timer.reset re-adds its completion without a callback, so a Canceled
/// means a cancel dropped this completion and nothing else is armed for it.
/// A reset does that when it lands in the pass its timer falls due in
/// (libxev measures a deadline from the pass start, the pacer from its
/// clock, so a long turn arms one earlier than the pacer counts): the timer
/// still runs on its old deadline, its turn runs the completion again, and
/// the reset's cancel drops that run on the next tick. Dropping the
/// Canceled left the pacer's deadline pending for good, and the timer never
/// ran again. The blink is never reset or canceled.
fn timerCallback(comptime timer: Pacer.Timer) TimerCallback {
    return timerRunCallback(Thread, timer);
}

/// timerCallback over any receiver with `timerDue`, so a test can drive
/// the production callback without a Thread.
fn timerRunCallback(comptime R: type, comptime timer: Pacer.Timer) TimerCallbackOf(R) {
    return struct {
        fn callback(
            self_: ?*R,
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = r catch |err| switch (err) {
                error.Canceled => {},
                else => unreachable,
            };
            self_.?.timerDue(timer);
            return .disarm;
        }
    }.callback;
}

fn timerDue(t: *Thread, comptime timer: Pacer.Timer) void {
    if (comptime timer == .followup and @hasDecl(apprt.Surface, "noteRendererFollowupCallback")) {
        t.surface.noteRendererFollowupCallback();
    }
    t.pacer.turn(.{ .due = timer }, Frame{ .t = t });
}

test "timerCallback hands the pacer a run that error.Canceled ends, as due" {
    // The real-loop test below pins that libxev reports the dropped run as
    // Canceled; this pins what the production callback does with it.
    const Recorder = struct {
        seen: [4]Pacer.Timer = undefined,
        len: usize = 0,

        fn timerDue(self: *@This(), comptime timer: Pacer.Timer) void {
            self.seen[self.len] = timer;
            self.len += 1;
        }
    };
    var recorder: Recorder = .{};
    var loop: xev.Loop = undefined;
    var c: xev.Completion = .{};
    inline for (.{ Pacer.Timer.followup, Pacer.Timer.animation }) |timer| {
        const cb = timerRunCallback(Recorder, timer);
        try std.testing.expectEqual(xev.CallbackAction.disarm, cb(&recorder, &loop, &c, error.Canceled));
        try std.testing.expectEqual(xev.CallbackAction.disarm, cb(&recorder, &loop, &c, {}));
    }
    try std.testing.expectEqualSlices(
        Pacer.Timer,
        &.{ .followup, .followup, .animation, .animation },
        recorder.seen[0..recorder.len],
    );
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

test "a timer reset in the pass it falls due loses the run its callback arms next, as Canceled" {
    // What timerCallback relies on (libxev IOCP: tick, timer_reset,
    // process_cancellations, submit). B is due in the same pass as A, and
    // A's callback resets it: the reset only queues a cancel, so B still
    // runs on its old deadline. B's callback runs B again, as its turn arms
    // it, and on the next tick the queued cancel drops that run, reported
    // as error.Canceled. The completion is then dead and runs again.
    const Probe = struct {
        a: xev.Timer,
        b: xev.Timer,
        a_c: xev.Completion = .{},
        b_c: xev.Completion = .{},
        b_reset_c: xev.Completion = .{},
        seen: [3]u8 = undefined,
        len: usize = 0,

        fn onA(
            self_: ?*@This(),
            loop: *xev.Loop,
            _: *xev.Completion,
            r: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = r catch unreachable;
            const self = self_.?;
            self.b.reset(loop, &self.b_c, &self.b_reset_c, 1, @This(), self, onB);
            return .disarm;
        }

        fn onB(
            self_: ?*@This(),
            loop: *xev.Loop,
            _: *xev.Completion,
            r: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            const self = self_.?;
            self.seen[self.len] = if (r) |_| 'R' else |err| switch (err) {
                error.Canceled => 'C',
                else => unreachable,
            };
            self.len += 1;
            if (self.len < self.seen.len) self.b.run(loop, &self.b_c, 1, @This(), self, onB);
            return .disarm;
        }
    };

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var probe: Probe = .{ .a = try xev.Timer.init(), .b = try xev.Timer.init() };
    defer probe.a.deinit();
    defer probe.b.deinit();
    probe.a.run(&loop, &probe.a_c, 1, Probe, &probe, Probe.onA);
    probe.b.run(&loop, &probe.b_c, 2, Probe, &probe, Probe.onB);
    std.Thread.sleep(20 * std.time.ns_per_ms);
    try loop.run(.until_done);
    try std.testing.expectEqualStrings("RCR", probe.seen[0..probe.len]);
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
