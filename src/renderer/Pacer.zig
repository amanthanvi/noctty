//! Win32 frame pacing for one renderer thread: whether a wake or a timer
//! run updates the frame, presents it, waits or stops, when the follow-up,
//! animation and blink timers run next, and the cursor's blink phase.
//! One per renderer.Thread, used only on that thread; OpenGL and the D3D11
//! beta share it through Thread.
//!
//! Callers learn `init` and `turn`. `turn` drives the frame port its caller
//! passes (listed on `turn`): renderer.Thread.Frame in production and
//! pacer_sim.zig in the tests below.
const Pacer = @This();

const std = @import("std");
const configpkg = @import("../config.zig");
const os_monotonic = @import("../os/monotonic.zig");
const State = @import("State.zig");

const ns_per_ms = std.time.ns_per_ms;

/// A focused pane outside saver pacing presents at most this often (120
/// fps). Intervals at or below it are not paced.
const draw_interval_ms = 8;

/// Saver pacing, about 30 fps.
const saver_interval_ms = 34;

/// How long after the last wake notify the follow-up keeps polling: xev's
/// async wakes coalesce under steady output (renderer.md 2026-04-29).
const followup_burst_ms = 128;

/// The default system timer tick, 15.625 ms, rounded up.
const timer_tick_ms = 16;

const blink_interval_ms = 600;

pub const Timer = enum { followup, animation, blink };

pub const Trigger = union(enum) {
    /// The wakeup async fired with these State.takeWakeSources() bits. 0 is
    /// allowed (Windows.setPresentationPending notifies with no source).
    wake: u32,
    /// A run of this timer ended: it expired, or a cancel dropped it. On
    /// IOCP a Timer.reset re-adds its completion without a callback, so an
    /// error.Canceled is a run that is gone, and callbacks deliver it too:
    /// the deadline stays pending until a run arrives.
    due: Timer,
};

/// Time and power, the two facts pacing reads from the OS.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// Monotonic ns in the os/monotonic.zig timebase (QPC on Windows).
    now_ns: *const fn (?*anyopaque) u64,
    /// Battery Saver or Energy Saver is on (never plain battery). May poll.
    /// Every renderer thread shares the production adapter, so it must be
    /// safe to call concurrently (win32_power is atomic).
    saver: *const fn (?*anyopaque) bool,

    /// For a runtime with no power signal (apprt.none, compile-only today).
    pub const monotonic: Clock = .{ .now_ns = monotonicNs, .saver = never };

    fn monotonicNs(_: ?*anyopaque) u64 {
        return os_monotonic.nowNs();
    }

    fn never(_: ?*anyopaque) bool {
        return false;
    }
};

pub const Config = struct {
    unfocused_render_fps: u32,
    power_saver_rendering: configpkg.PowerSaverRendering,

    pub fn init(config: *const configpkg.Config) Config {
        return .{
            .unfocused_render_fps = config.@"unfocused-render-fps",
            .power_saver_rendering = config.@"power-saver-rendering",
        };
    }
};

/// What a drain applied that pacing reads.
pub const Change = enum {
    visibility,
    focus,
    config,
    /// The D3D11 backend's pending presentation started or ended.
    presentation,
    /// What the frame shows changed by itself (a split's dim), so a frame
    /// synchronized output holds is presented anyway.
    repaint,
    /// Input asked for the cursor to show and its blink to restart.
    blink_reset,
};

pub const Drained = struct {
    changes: std.EnumSet(Change) = .{},
    /// A message failed; `changes` holds what applied before it.
    failed: bool = false,
};

/// The animation timer is wanted, presenting at most this often (upstream's
/// name, aee7bf347).
pub const AnimationWake = struct { delay_ms: u64 };

pub const Inputs = struct {
    focused: bool,
    visible: bool,
    config: Config,
    /// When a producer last notified a wake (State.last_render_wakeup_notify_ns),
    /// in `Clock.now_ns`'s timebase; 0 = never.
    notified_ns: u64,
};

pub const Screen = struct {
    needs_frame: bool,
    cursor_blinking: bool,
    /// Read under the same lock, after `needs_frame`.
    wake_pending: bool,
};

/// `frame.update`: updateFrame, then present unless synchronized output
/// held it and !present_held. A blinking cursor is drawn when
/// `blink_visible`.
pub const Update = struct { blink_visible: bool, present_held: bool };

pub const UpdateResult = union(enum) {
    /// A queued paint still holds the repaint reservation. Nothing ran.
    coalesced,
    /// `cursor_blinking` is the mode in the snapshot the update drew.
    updated: struct { cursor_blinking: bool, held: bool, presented: bool },
};

clock: Clock,

/// Start of the present slot taken last, or 0 when the next present need
/// not wait.
slot_ms: u64 = 0,

/// An update pacing put off, or one synchronized output held, is still
/// owed.
update_owed: bool = false,

/// The apprt is owed pixels (a `wakeNeedsPixels` wake, a `.repaint` change)
/// and no present was queued since. A WM_PAINT that finds no frame reserved
/// draws nothing itself, so without this an exposed or newly shown pane
/// stays blank until a hold ends. It outlives a pass pacing puts off.
repaint_owed: bool = false,

/// What `frame.animation()` reported when an input it depends on last
/// changed. The animation timer runs while it is set.
animating: ?AnimationWake = null,

followup: Deadline = .{},
animation: Deadline = .{},

/// A blinking cursor is drawn now. It toggles on the blink timer.
blink_visible: bool = false,
/// The blink timer is armed and its run not delivered yet. It is never
/// reset: an active IOCP completion can be queued for its callback already,
/// and reusing it corrupts libxev's completion queue.
blink_pending: bool = false,
/// The latest request to restart the blink interval, in `clock` ns. The
/// queued run waits out the rest of the interval from its own turn.
blink_reset_ns: ?u64 = null,

/// When a wake last left work behind: the follow-up burst runs from it as
/// from a notify.
refreshed_ns: u64 = 0,

started: bool = false,

const Deadline = struct {
    /// Armed, and its run not delivered yet.
    pending: bool = false,
    /// `clock` ms when the pending run is due.
    due_ms: u64 = 0,
};

/// What one turn asks of the timers, armed once at its end.
const Turn = struct {
    followup: bool = false,
    animation: bool = false,
    /// Arm the blink timer in this many ms; the first request wins, as
    /// only a dead completion can run.
    blink: ?u64 = null,
};

const Pass = enum { wake, followup, animation };

pub fn init(clock: Clock) Pacer {
    return .{ .clock = clock };
}

/// One wake or timer run. Call it only on the renderer thread, never
/// re-entrantly; the first turn must be the thread_start wake, and it
/// starts the timers. Timers are armed at the end of the turn, each at most
/// once, and the follow-up and animation deadlines only ever move earlier.
///
/// `frame` is a value or pointer with these methods:
/// - `drain() Drained`: the mailbox; each message pacing reads inserts its
///   Change. It arms no timer and never calls `turn`.
/// - `inputs() Inputs`: takes no lock.
/// - `screen() Screen`: takes State.mutex once.
/// - `cursorBlinking() bool`: the cursor mode alone, under State.mutex,
///   for blink decisions that do not need `screen`'s dirt check.
/// - `animation() ?AnimationWake`: may take the D3D11 dispatcher mutex, so
///   `turn` calls it only when an input it depends on changed, on the first
///   turn and when the animation timer comes due.
/// - `update(Update) UpdateResult` and `draw() bool` (whether a present was
///   queued): they own the apprt repaint reservation and release every one
///   they do not hand to a queued paint.
/// - `arm(Timer, delay_ms: u64) void`: runs a dead completion, resets an
///   active follow-up or animation one. `turn` never arms a pending blink.
/// - `wake(State.WakeSource) void`: records the source, then notifies the
///   wakeup async.
/// Producers record a wake source before its notify, and termio records
/// `io_output` before it releases State.mutex.
pub fn turn(self: *Pacer, trigger: Trigger, frame: anytype) void {
    var t: Turn = .{};
    if (!self.started) {
        self.started = true;
        self.reconcileAnimation(&t, frame, frame.inputs());
        // Only a blinking cursor arms its timer: a steady one must not keep
        // a renderer wake loop alive.
        if (frame.cursorBlinking()) self.armBlink(&t, blinkIntervalMs());
    }
    switch (trigger) {
        .wake => |sources| {
            if (wakeNeedsPixels(sources)) self.repaint_owed = true;
            t.followup = self.pass(&t, .wake, frame);
        },
        .due => |timer| switch (timer) {
            .followup => {
                self.followup = .{};
                t.followup = self.followupDue(&t, frame);
            },
            .animation => {
                self.animation = .{};
                // When pacing put an update off, this tick carries it: both
                // share one present slot per interval, and a draw-only tick
                // would keep the slot while presenting stale frame data
                // (#297).
                if (self.update_owed) {
                    t.followup = self.pass(&t, .animation, frame);
                } else {
                    self.draw(frame);
                }
                if (!t.animation) self.reconcileAnimation(&t, frame, frame.inputs());
            },
            .blink => self.blinkDue(&t, frame),
        },
    }
    self.arm(&t, frame);
}

/// Drain, reconcile, then update and present the frame unless pacing puts
/// it off. Returns whether the follow-up should run.
fn pass(self: *Pacer, t: *Turn, kind: Pass, frame: anytype) bool {
    const drained = frame.drain();
    const in = frame.inputs();
    self.reconcile(t, drained.changes, frame, in);
    if (drained.failed) return false;

    // Hidden panes keep terminal state but do no renderer work. A throttled
    // pane puts both the update and the present off to the follow-up, so
    // background output cannot burn CPU at the uncapped wake rate.
    const interval_ms = self.intervalMs(in) orelse return false;
    if (self.waitMs(interval_ms) > 0) {
        self.update_owed = true;
        return true;
    }

    // A frame synchronized output holds is presented by the animation
    // tick, which animates over it, and by any pass while pixels are owed.
    const present_held = self.repaint_owed or (kind == .animation and self.animating != null);
    switch (frame.update(.{
        .blink_visible = self.blink_visible,
        .present_held = present_held,
    })) {
        .coalesced => {},
        .updated => |updated| {
            if (!updated.cursor_blinking) self.blink_visible = true;
            if (in.focused and updated.cursor_blinking) self.armBlink(t, blinkIntervalMs());
            // A held update stays owed: termio's 1 s reset always wakes the
            // renderer, an ESU only when it brings dirt, so the follow-up
            // polls for a clean ESU.
            self.update_owed = updated.held;
            if (updated.held and !present_held) return true;
            // An owed repaint stays owed when no paint could be queued (a
            // full app mailbox), so a later pass presents the held frame.
            if (updated.presented) {
                self.repaint_owed = false;
                self.takeSlot(interval_ms);
            }
        },
    }
    return self.keepFollowup(kind == .wake, frame);
}

/// xev's async wakes coalesce while a pass is in flight: keep the follow-up
/// while work remains or output notified recently, so streaming output
/// does not collapse to a fraction of the frame rate.
fn keepFollowup(self: *Pacer, from_wake: bool, frame: anytype) bool {
    const work = self.owesUpdate() or frame.screen().needs_frame;
    if (from_wake and work) self.refreshed_ns = self.nowNs();
    return work or self.burst(frame.inputs());
}

/// The follow-up renders, polls or stops. A wake on its way gets the work:
/// the loop runs a due timer before the wakes of the same pass, so output
/// that asked for a wake reaches the follow-up first, and rendering it here
/// would leave that wake to present the same frame again (LAT-02 (3)).
fn followupDue(self: *Pacer, t: *Turn, frame: anytype) bool {
    const in = frame.inputs();
    if (!in.visible) return false;
    const screen = frame.screen();
    const work = self.owesUpdate() or screen.needs_frame;
    if (work and !screen.wake_pending) return self.pass(t, .followup, frame);
    return work or self.burst(in);
}

/// An update pacing put off is owed, work or not (a search highlight, a
/// config change, a scroll to the bottom). The animation tick carries it
/// while that timer runs (#297); otherwise the follow-up does.
fn owesUpdate(self: *const Pacer) bool {
    return self.update_owed and self.animating == null;
}

fn burst(self: *const Pacer, in: Inputs) bool {
    const last = @max(in.notified_ns, self.refreshed_ns);
    return last != 0 and self.nowNs() -| last < followup_burst_ms * ns_per_ms;
}

/// Present the current frame data, paced.
fn draw(self: *Pacer, frame: anytype) void {
    const interval_ms = self.intervalMs(frame.inputs()) orelse return;
    if (self.waitMs(interval_ms) > 0) return;
    if (frame.draw()) self.takeSlot(interval_ms);
}

/// Apply what a drain changed, against the inputs after it, so a flip and
/// back inside one drain reconciles once.
fn reconcile(
    self: *Pacer,
    t: *Turn,
    changes: std.EnumSet(Change),
    frame: anytype,
    in: Inputs,
) void {
    // Hidden panes skip updateFrame, so a pane shown again presents a fresh
    // frame at once rather than an interval after its last one.
    if (changes.contains(.visibility) and in.visible) self.slot_ms = 0;
    if (changes.contains(.repaint)) self.repaint_owed = true;
    // Focus and input show the cursor and restart its blink; losing focus
    // lets a queued blink run lapse.
    if (changes.contains(.focus) or changes.contains(.blink_reset)) {
        self.blink_visible = true;
        if (!in.focused) {
            if (changes.contains(.focus)) self.blink_reset_ns = null;
        } else {
            const blinking = frame.cursorBlinking();
            if (changes.contains(.focus) or blinking) self.blink_reset_ns = self.nowNs();
            if (blinking) self.armBlink(t, blinkIntervalMs());
        }
    }
    const animation_inputs: std.EnumSet(Change) = .initMany(&.{ .visibility, .focus, .config, .presentation });
    if (changes.intersectWith(animation_inputs).count() != 0) self.reconcileAnimation(t, frame, in);
}

fn reconcileAnimation(self: *Pacer, t: *Turn, frame: anytype, in: Inputs) void {
    self.animating = if (in.visible) frame.animation() else null;
    t.animation = true;
}

/// A blink run: toggle, wait out a restart, or stop for an unfocused or
/// steady cursor, shown. A toggle wakes the renderer to draw it.
fn blinkDue(self: *Pacer, t: *Turn, frame: anytype) void {
    self.blink_pending = false;
    if (!frame.inputs().focused or !frame.cursorBlinking()) {
        const was_visible = self.blink_visible;
        self.blink_visible = true;
        self.blink_reset_ns = null;
        if (!was_visible) frame.wake(.cursor_blink);
        return;
    }
    if (self.blink_reset_ns) |reset_ns| {
        const remaining_ns = blinkIntervalMs() * ns_per_ms -| (self.nowNs() -| reset_ns);
        const remaining_ms = (remaining_ns + ns_per_ms - 1) / ns_per_ms;
        if (remaining_ms > 0) return self.armBlink(t, remaining_ms);
        self.blink_reset_ns = null;
    }
    self.blink_visible = !self.blink_visible;
    frame.wake(.cursor_blink);
    self.armBlink(t, blinkIntervalMs());
}

fn armBlink(self: *const Pacer, t: *Turn, delay_ms: u64) void {
    if (!self.blink_pending and t.blink == null) t.blink = delay_ms;
}

fn blinkIntervalMs() u64 {
    // Under Valgrind the blink adds enough churn to make stalls annoying
    // (https://github.com/ghostty-org/ghostty/issues/8003).
    return if (std.valgrind.runningOnValgrind() > 0) 5 * blink_interval_ms else blink_interval_ms;
}

fn arm(self: *Pacer, t: *Turn, frame: anytype) void {
    if (t.blink) |delay_ms| {
        frame.arm(.blink, delay_ms);
        self.blink_pending = true;
    }
    if (!t.followup and !t.animation) return;
    const delay_ms = self.presentDelayMs(frame.inputs()) orelse return;
    if (t.followup) self.armDeadline(frame, .followup, &self.followup, delay_ms);
    if (t.animation) if (self.animating) |wake| {
        self.armDeadline(frame, .animation, &self.animation, @max(wake.delay_ms, delay_ms));
    };
}

/// A focus or power change can shorten a slow pending deadline; nothing
/// postpones an earlier one.
fn armDeadline(self: *Pacer, frame: anytype, timer: Timer, deadline: *Deadline, delay_ms: u64) void {
    const now_ms = self.nowMs();
    if (deadline.pending and delay_ms >= deadline.due_ms -| now_ms) return;
    frame.arm(timer, delay_ms);
    deadline.* = .{ .pending = true, .due_ms = now_ms +| delay_ms };
}

/// When the next present may come: the rest of the slot, or an interval.
fn presentDelayMs(self: *const Pacer, in: Inputs) ?u64 {
    const interval_ms = self.intervalMs(in) orelse return null;
    const wait_ms = self.waitMs(interval_ms);
    return if (wait_ms > 0) wait_ms else interval_ms;
}

/// How often the pane may present, or null while it is hidden. A focused
/// pane outside saver pacing keeps `draw_interval_ms`.
fn intervalMs(self: *const Pacer, in: Inputs) ?u64 {
    if (!in.visible) return null;
    const saver = switch (in.config.power_saver_rendering) {
        // `auto` follows Battery Saver or Energy Saver, never plain battery.
        .auto => self.clock.saver(self.clock.ctx),
        .on => true,
        .off => false,
    };
    if (in.focused and !saver) return draw_interval_ms;

    const fps: u64 = @max(1, in.config.unfocused_render_fps);
    const unfocused_ms = @max(draw_interval_ms, (std.time.ms_per_s + fps - 1) / fps);
    if (!saver) return unfocused_ms;
    return if (in.focused) saver_interval_ms else @max(saver_interval_ms, unfocused_ms);
}

/// How long a present must still wait.
fn waitMs(self: *const Pacer, interval_ms: u64) u64 {
    if (interval_ms <= draw_interval_ms or self.slot_ms == 0) return 0;
    return interval_ms -| (self.nowMs() -| self.slot_ms);
}

/// Take the slot for a present. The timer that wakes a throttled pane
/// expires on a system tick (15.6 ms), so a present can land most of a tick
/// after its slot opened. Starting the slot when it opened rather than when
/// the present came keeps the configured rate; without it every interval
/// grew to the next tick, 34 to 47 ms. A present later than that (output
/// that came late, idle) starts a new cadence, so no catch-up burst follows
/// it.
fn takeSlot(self: *Pacer, interval_ms: u64) void {
    if (interval_ms <= draw_interval_ms) {
        self.slot_ms = 0;
        return;
    }
    const now_ms = self.nowMs();
    const late_ms = if (self.slot_ms == 0) 0 else now_ms -| (self.slot_ms +| interval_ms);
    const credit = late_ms <= timer_tick_ms and late_ms < interval_ms;
    self.slot_ms = if (credit) now_ms - late_ms else now_ms;
}

fn nowNs(self: *const Pacer) u64 {
    return self.clock.now_ns(self.clock.ctx);
}

fn nowMs(self: *const Pacer) u64 {
    return self.nowNs() / ns_per_ms;
}

/// Wakes from the apprt for a window that needs its pixels drawn again
/// (exposed, newly shown, resized, recovering): a frame synchronized output
/// holds is presented anyway for these. `apprt_paint_pending` is not one:
/// it forces the pending paint, whose WM_PAINT asks again if it has no
/// frame.
fn wakeNeedsPixels(wake_sources: u32) bool {
    const Source = State.WakeSource;
    const pixels = Source.apprt_paint_retry.bit() |
        Source.apprt_first_show.bit() |
        Source.apprt_resize_settle.bit() |
        Source.apprt_health_recovery.bit();
    return wake_sources & pixels != 0;
}

// The interface tests: `init` and `turn`, driven through pacer_sim.zig.
// Each names the measured trap it pins.

const testing = std.testing;
const Sim = @import("pacer_sim.zig");

/// A pacer whose first turn has run and whose start-up burst is over.
fn settled(sim: *Sim) !Pacer {
    var pacer: Pacer = .init(sim.clock());
    sim.start();
    try sim.run(&pacer, 500);
    return pacer;
}

/// Output every millisecond for a second: the presents it gets, and the
/// shortest gap between two.
fn spacing(sim: *Sim, pacer: *Pacer) !struct { count: usize, min_gap_ms: u64 } {
    const first = sim.presents().len;
    for (0..1000) |_| {
        sim.output(.{});
        try sim.run(pacer, 1);
    }
    const log = sim.presents()[first..];
    var min_gap_ms: u64 = std.math.maxInt(u64);
    for (log[1..], log[0 .. log.len - 1]) |b, a| min_gap_ms = @min(min_gap_ms, (b.ns - a.ns) / ns_per_ms);
    return .{ .count = log.len, .min_gap_ms = min_gap_ms };
}

/// Presents under steady output are `interval_ms` apart, or come on every
/// output's wake when it is not paced.
fn expectInterval(sim: *Sim, interval_ms: u64) !void {
    var pacer = try settled(sim);
    const observed = try spacing(sim, &pacer);
    if (interval_ms <= draw_interval_ms) {
        try testing.expectEqual(@as(usize, 1000), observed.count);
        try testing.expectEqual(@as(u64, 1), observed.min_gap_ms);
        return;
    }
    try testing.expect(observed.min_gap_ms >= interval_ms - 1);
    try testing.expect(observed.count >= 1000 / interval_ms - 1);
    try testing.expect(observed.count <= 1000 / interval_ms + 1);
}

test "a follow-up due in the same pass as output's wake leaves the work to the wake" {
    // LAT-02 (3): IOCP runs a due timer before the async wakes of the same
    // pass. A follow-up that drew the output found the wake's frame
    // reserved, and its retry presented the same frame again.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    const before = sim.presents().len;
    sim.output(.{});
    try sim.run(&pacer, 0);
    sim.advanceTo(sim.dueNs(.followup).?);
    sim.output(.{});
    try sim.run(&pacer, 50);
    try testing.expectEqual(before + 2, sim.presents().len);
}

test "the follow-up polls until 128 ms after the last notify, not the last wake" {
    // 2026-04-29: xev's async wakes coalesce under steady output, so the
    // burst runs from the notifies, not from the wake callbacks.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    for (0..10) |_| {
        sim.output(.{});
        try sim.run(&pacer, 40);
        try testing.expect(sim.pending(.followup));
    }
    // The last output's wake runs 60 ms after its notify.
    sim.output(.{});
    sim.advance(60);
    try sim.run(&pacer, 60);
    try testing.expect(sim.pending(.followup));
    try sim.run(&pacer, 40);
    try testing.expect(!sim.pending(.followup));
}

test "work no wake is coming for is drawn by the follow-up" {
    // LAT-02 (1): a change that needs a frame but marks nothing dirty is
    // work to the follow-up too.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    sim.output(.{});
    try sim.run(&pacer, 0);
    const before = sim.presents().len;
    sim.touch();
    try sim.run(&pacer, 40);
    try testing.expectEqual(before + 1, sim.presents().len);
}

test "paced presents keep their rate against the system tick" {
    // PKG-37 (2): a paced animation's presents are timer-driven, each on
    // the first 15.625 ms tick after its slot opens. Measured from each
    // present, 34 ms became 46.875 and 17 ms 31.25.
    for ([_]u32{ 60, 50, 30, 20, 15 }, [_]u64{ 17, 20, 34, 50, 67 }) |fps, interval_ms| {
        var sim: Sim = .{ .focused = false, .shader = .always };
        sim.config.unfocused_render_fps = fps;
        var pacer = try settled(&sim);
        const first = sim.presents().len;
        try sim.run(&pacer, 300 * interval_ms);
        const log = sim.presents()[first..];
        // Credit for a late present never brings two in one tick.
        for (log[1..], log[0 .. log.len - 1]) |b, a| try testing.expect(b.ns - a.ns >= 15 * ns_per_ms);
        const average_ms = (log[log.len - 1].ns - log[0].ns) / (log.len - 1) / ns_per_ms;
        try testing.expect(average_ms >= interval_ms - 1 and average_ms <= interval_ms);
    }
}

test "a present more than a tick late starts a new cadence" {
    // PKG-37 (2): crediting up to a whole interval let a late wake-driven
    // present be followed almost at once, two presents 1 ms apart at 1 fps.
    var sim: Sim = .{ .focused = false };
    sim.config.unfocused_render_fps = 1;
    var pacer = try settled(&sim);
    sim.output(.{});
    try sim.run(&pacer, 3999 - sim.now_ns / ns_per_ms);
    const before = sim.presents().len;
    sim.output(.{});
    try sim.run(&pacer, 1);
    try testing.expectEqual(before + 1, sim.presents().len);
    sim.output(.{});
    try sim.run(&pacer, 0);
    try testing.expectEqual(before + 1, sim.presents().len);
}

test "the interval policy, observed as present spacing" {
    const Case = struct { focused: bool = true, saver: bool = false, config: Config, interval_ms: u64 };
    for ([_]Case{
        .{ .config = .{ .unfocused_render_fps = 30, .power_saver_rendering = .auto }, .interval_ms = 8 },
        .{ .focused = false, .config = .{ .unfocused_render_fps = 60, .power_saver_rendering = .auto }, .interval_ms = 17 },
        .{ .saver = true, .config = .{ .unfocused_render_fps = 30, .power_saver_rendering = .auto }, .interval_ms = 34 },
        .{ .focused = false, .saver = true, .config = .{ .unfocused_render_fps = 20, .power_saver_rendering = .auto }, .interval_ms = 50 },
        .{ .focused = false, .saver = true, .config = .{ .unfocused_render_fps = 60, .power_saver_rendering = .auto }, .interval_ms = 34 },
        .{ .focused = false, .config = .{ .unfocused_render_fps = 1000, .power_saver_rendering = .auto }, .interval_ms = 8 },
        // `on` and `off` override the saver signal. (`auto` never follows
        // plain battery: win32_power's `Snapshot.isSaver`, which
        // `Clock.saver` reports.)
        .{ .config = .{ .unfocused_render_fps = 30, .power_saver_rendering = .on }, .interval_ms = 34 },
        .{ .saver = true, .config = .{ .unfocused_render_fps = 30, .power_saver_rendering = .off }, .interval_ms = 8 },
    }) |case| {
        var sim: Sim = .{ .focused = case.focused, .saver = case.saver, .config = case.config };
        try expectInterval(&sim, case.interval_ms);
    }
    // Hidden: nothing presents and nothing is armed.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    sim.send(.{ .visible = false });
    try sim.run(&pacer, 200);
    const before = sim.presents().len;
    for (0..10) |_| {
        sim.output(.{});
        try sim.run(&pacer, 10);
    }
    try testing.expectEqual(before, sim.presents().len);
    try testing.expect(!sim.pending(.followup) and !sim.pending(.animation));
}

test "regaining focus moves slow pending timers earlier and never later" {
    var sim: Sim = .{ .focused = false, .shader = .always };
    sim.config.unfocused_render_fps = 1;
    var pacer = try settled(&sim);
    // An animation tick takes the 1 s slot; output 10 ms later is put off
    // to a follow-up a second away.
    try sim.run(&pacer, (sim.dueNs(.animation).? - sim.now_ns) / ns_per_ms + 16);
    sim.output(.{});
    try sim.run(&pacer, 10);
    try testing.expect(sim.dueNs(.followup).? > sim.now_ns + 900 * ns_per_ms);
    try testing.expect(sim.dueNs(.animation).? > sim.now_ns + 900 * ns_per_ms);
    sim.send(.{ .focus = true });
    try sim.run(&pacer, 0);
    try testing.expect(sim.dueNs(.followup).? <= sim.now_ns + 8 * ns_per_ms);
    try testing.expect(sim.dueNs(.animation).? <= sim.now_ns + 8 * ns_per_ms);
    // Losing focus again leaves the earlier deadline alone (the Sim fails
    // a run that moves one later).
    const due = sim.dueNs(.followup).?;
    sim.send(.{ .focus = false });
    try sim.run(&pacer, 0);
    try testing.expectEqual(due, sim.dueNs(.followup).?);
}

test "synchronized output presents nothing inside its holds" {
    // PKG-37 (1): a program holding BSU for 200 ms across four writes, ten
    // times, got 127-141 presents inside the holds; every cycle must still
    // show, once.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    for (0..10) |_| {
        const before = sim.presents().len;
        sim.output(.{ .bsu = true });
        try sim.run(&pacer, 50);
        for (0..3) |_| {
            sim.output(.{});
            try sim.run(&pacer, 50);
        }
        try testing.expectEqual(before, sim.presents().len);
        sim.output(.{ .esu = true });
        try sim.run(&pacer, 100);
        try testing.expectEqual(before + 1, sim.presents().len);
    }
    // A clean ESU after a renderer-side change brings no work and asks for
    // no wake: the follow-up's poll finds the held update and presents it.
    const before = sim.presents().len;
    sim.output(.{ .bsu = true, .work = false });
    sim.send(.search);
    try sim.run(&pacer, 100);
    try testing.expectEqual(before, sim.presents().len);
    sim.output(.{ .esu = true, .work = false });
    try sim.run(&pacer, 100);
    try testing.expectEqual(before + 1, sim.presents().len);
}

test "an expose during a hold presents the held frame once, also under saver pacing" {
    // PKG-37 (1): a WM_PAINT with no frame reserved only wakes the
    // renderer, so an exposed pane stayed blank until the hold ended; under
    // saver pacing the expose's pass is put off and the follow-up presents.
    for ([_]bool{ false, true }) |saver| {
        var sim: Sim = .{ .saver = saver };
        var pacer = try settled(&sim);
        sim.output(.{});
        try sim.run(&pacer, 0);
        sim.output(.{ .bsu = true });
        const before = sim.presents().len;
        sim.expose();
        try sim.run(&pacer, 100);
        try testing.expectEqual(before + 1, sim.presents().len);
    }
}

test "a split-dim change presents a held frame and other messages do not" {
    // #408 trap (3): a mailbox wake does not present a held frame; a
    // split's dim changes pixels the hold does not hold back.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    sim.output(.{ .bsu = true });
    try sim.run(&pacer, 0);
    const before = sim.presents().len;
    sim.send(.search);
    sim.send(.{ .focus = false });
    try sim.run(&pacer, 50);
    try testing.expectEqual(before, sim.presents().len);
    sim.send(.split_dimmed);
    try sim.run(&pacer, 50);
    try testing.expectEqual(before + 1, sim.presents().len);
}

test "only the apprt's pixel wakes present a frame synchronized output holds" {
    // PKG-37 (1): exposed, newly shown, resized and recovering windows need
    // their pixels. `apprt_paint_pending` is not a pixels request: it forces
    // the pending paint, whose WM_PAINT asks again if it has no frame.
    for (std.enums.values(State.WakeSource)) |source| {
        const presents = switch (source) {
            .apprt_paint_retry,
            .apprt_first_show,
            .apprt_resize_settle,
            .apprt_health_recovery,
            => true,
            .thread_start,
            .core_surface,
            .mailbox,
            .io_output,
            .cursor_blink,
            .apprt_repaint_retry,
            .apprt_paint_pending,
            .inspector,
            => false,
        };
        var sim: Sim = .{};
        var pacer = try settled(&sim);
        sim.output(.{ .bsu = true });
        try sim.run(&pacer, 50);
        const before = sim.presents().len;
        sim.wakeFrom(source);
        try sim.run(&pacer, 50);
        try testing.expectEqual(before + @intFromBool(presents), sim.presents().len);
    }
}

test "a shader's ticks present a held frame only while the animation timer runs" {
    // PKG-37 (1): the animation tick animates over a frame synchronized
    // output holds; the follow-up polling the hold does not present it as
    // well, and neither does a tick left over after focus stopped a `true`
    // shader's timer.
    var sim: Sim = .{ .shader = .true };
    var pacer = try settled(&sim);
    // A pass inside the hold leaves the held update owed, so each tick
    // updates the frame rather than only drawing it.
    sim.output(.{ .bsu = true });
    sim.send(.search);
    try sim.run(&pacer, 0);
    const before = sim.presents().len;
    const ticks = sim.turns.get(.animation);
    try sim.run(&pacer, 200);
    const held_ticks = sim.turns.get(.animation) - ticks;
    try testing.expect(held_ticks >= 10);
    try testing.expectEqual(before + held_ticks, sim.presents().len);
    for (sim.presents()[before..]) |present| {
        try testing.expectEqual(Trigger{ .due = .animation }, present.trigger);
    }

    // Focus goes right after a tick, so the next one is already queued;
    // the hold goes on.
    const last = sim.turns.get(.animation);
    while (sim.turns.get(.animation) == last) try sim.run(&pacer, 1);
    sim.send(.{ .focus = false });
    try sim.run(&pacer, 0);
    const stopped = sim.presents().len;
    const stale = sim.turns.get(.animation);
    try testing.expect(sim.pending(.animation));
    try sim.run(&pacer, 200);
    try testing.expect(sim.turns.get(.animation) > stale);
    try testing.expectEqual(stopped, sim.presents().len);
    try testing.expect(!sim.pending(.animation));

    // Between the 4 Hz ticks of a pending D3D11 presentation the follow-up
    // polls the hold, updating the frame, and presents nothing.
    var retry: Sim = .{};
    var retry_pacer = try settled(&retry);
    retry.setPresentationPending(true);
    retry.output(.{ .bsu = true });
    retry.send(.search);
    try retry.run(&retry_pacer, 0);
    const held_from = retry.presents().len;
    const polls = retry.followup_updates;
    try retry.run(&retry_pacer, 1000);
    try testing.expect(retry.followup_updates > polls);
    try testing.expect(retry.presents().len > held_from);
    for (retry.presents()[held_from..]) |present| {
        try testing.expectEqual(Trigger{ .due = .animation }, present.trigger);
    }
}

test "a config change starts and stops the shader's animation timer" {
    var sim: Sim = .{ .shader = .false };
    var pacer = try settled(&sim);
    try testing.expect(!sim.pending(.animation));
    sim.send(.{ .config = .{ .pacing = sim.config, .shader = .always } });
    try sim.run(&pacer, 0);
    try testing.expect(sim.pending(.animation));
    sim.send(.{ .config = .{ .pacing = sim.config, .shader = .false } });
    try sim.run(&pacer, 100);
    try testing.expect(!sim.pending(.animation));
}

test "under saver pacing a shader's tick carries typed output and keeps its rate" {
    // #297: the draw-only tick took the shared slot and pushed the update
    // out every interval, so typed output never showed. LAT-02 (4): the
    // follow-up does not also carry the update while the tick runs.
    var sim: Sim = .{ .saver = true, .shader = .true };
    var pacer = try settled(&sim);
    const first = sim.presents().len;
    const start_ns = sim.now_ns;
    for (0..10) |_| {
        try sim.run(&pacer, 17);
        sim.output(.{});
        const typed_ns = sim.now_ns;
        try sim.run(&pacer, 2 * saver_interval_ms);
        try testing.expect(sim.lastUpdateNs() >= typed_ns);
    }
    try testing.expectEqual(@as(u32, 0), sim.followup_updates);
    const presented = sim.presents().len - first;
    const elapsed_ms = (sim.now_ns - start_ns) / ns_per_ms;
    try testing.expect(presented + 1 >= elapsed_ms / saver_interval_ms);
}

test "a change drained inside a shader tick arms the animation timer once" {
    // 2026-04-29 and #297: a drain inside the tick re-armed its completion,
    // and a second submit corrupted libxev's queue. The drain now only
    // reports, the pacer arms once at the end of the turn (the Sim fails a
    // second arm), after the present took the slot.
    var sim: Sim = .{ .saver = true, .shader = .always };
    var pacer = try settled(&sim);
    sim.output(.{});
    try sim.run(&pacer, 0);
    sim.advanceTo(sim.dueNs(.animation).?);
    sim.send(.{ .focus = false });
    sim.send(.{ .focus = true });
    try sim.run(&pacer, 0);
    try testing.expect(sim.dueNs(.animation).? >= sim.now_ns + (saver_interval_ms - 1) * ns_per_ms);
    // A change drained by a wake while the tick is pending does not move
    // it later.
    const due = sim.dueNs(.animation).?;
    sim.send(.{ .focus = false });
    try sim.run(&pacer, 0);
    try testing.expectEqual(due, sim.dueNs(.animation).?);
}

test "a pending D3D11 presentation keeps a 4 Hz retry; clearing it lets the timer lapse" {
    // 2026-10-10: an occluded frame still needs a later Present(TEST), with
    // a steady cursor and no output.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    sim.setPresentationPending(true);
    try sim.run(&pacer, 0);
    const before = sim.turns.get(.animation);
    try sim.run(&pacer, 2000);
    const ticks = sim.turns.get(.animation) - before;
    try testing.expect(ticks >= 7 and ticks <= 8);
    sim.setPresentationPending(false);
    try sim.run(&pacer, 600);
    try testing.expect(!sim.pending(.animation));
}

test "a pane shown again presents at once, even when paced" {
    var sim: Sim = .{ .saver = true };
    var pacer = try settled(&sim);
    sim.output(.{});
    try sim.run(&pacer, 0);
    sim.send(.{ .visible = false });
    sim.output(.{});
    try sim.run(&pacer, 5);
    const before = sim.presents().len;
    sim.send(.{ .visible = true });
    try sim.run(&pacer, 0);
    try testing.expectEqual(before + 1, sim.presents().len);
}

test "a coalesced frame keeps the follow-up only while work or the burst remains" {
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    // The UI thread is slow to paint, so the next frame coalesces.
    sim.holdPaint();
    sim.expose();
    try sim.run(&pacer, 0);
    const before = sim.presents().len;
    sim.expose();
    try sim.run(&pacer, 0);
    try testing.expect(!sim.pending(.followup));
    sim.output(.{});
    try sim.run(&pacer, 0);
    try testing.expect(sim.pending(.followup));
    // The paint completes, and its retry wake presents.
    sim.releasePaint();
    try sim.run(&pacer, 0);
    try testing.expectEqual(before + 1, sim.presents().len);
}

test "a drain that fails after a focus change still reconciles it and ends the pass" {
    var sim: Sim = .{ .focused = false, .shader = .true };
    var pacer = try settled(&sim);
    try testing.expect(!sim.pending(.animation));
    const before = sim.presents().len;
    sim.fail_drain = true;
    sim.send(.{ .focus = true });
    try sim.run(&pacer, 0);
    try testing.expect(sim.pending(.animation));
    try testing.expectEqual(before, sim.presents().len);
    try testing.expect(!sim.pending(.followup));
}

test "seeded event sequences keep the pacing invariants" {
    // Saver pacing at 30 fps paces every focus state at 34 ms. Output,
    // holds, focus, visibility, exposes and a shader in random order: no
    // two presents in one slot (a slot may start up to a tick late, and a
    // pane shown again starts a new one), every update owed is presented
    // once events stop, and no run arms twice or moves a deadline later.
    var prng: std.Random.DefaultPrng = .init(0x7ace_2026);
    const random = prng.random();
    for (0..40) |_| {
        var sim: Sim = .{ .saver = true, .shader = if (random.boolean()) .true else null };
        var pacer = try settled(&sim);
        const first = sim.presents().len;
        for (0..150) |_| {
            switch (random.uintLessThan(u8, 7)) {
                0, 1 => sim.output(.{}),
                2 => sim.output(.{ .bsu = true }),
                3 => sim.output(.{ .esu = true }),
                4 => sim.send(.{ .focus = !sim.focused }),
                5 => sim.send(.{ .visible = !sim.visible }),
                else => sim.expose(),
            }
            try sim.run(&pacer, random.uintLessThan(u64, 40));
        }
        sim.output(.{ .esu = true, .work = false });
        sim.send(.{ .visible = true });
        try sim.run(&pacer, 3 * saver_interval_ms + 2 * timer_tick_ms);
        try testing.expect(!sim.work);
        const log = sim.presents()[first..];
        for (log[1..], log[0 .. log.len - 1]) |b, a| {
            if (!b.after_show) try testing.expect(b.ns - a.ns >= (saver_interval_ms - timer_tick_ms) * ns_per_ms);
        }
    }
}

test "a steady cursor arms no blink timer and keeps no wake loop" {
    // #134: steady cursors must not keep a renderer wake loop alive.
    var sim: Sim = .{};
    var pacer = try settled(&sim);
    try testing.expect(!sim.pending(.blink));
    const before = sim.presents().len;
    try sim.run(&pacer, 3000);
    try testing.expect(!sim.pending(.blink));
    try testing.expectEqual(@as(usize, 0), sim.blinkWakes().len);
    try testing.expectEqual(before, sim.presents().len);
}

test "a focused blinking cursor toggles every 600 ms, each toggle waking the renderer once" {
    var sim: Sim = .{ .blinking = true };
    var pacer = try settled(&sim);
    const first = sim.blinkWakes().len;
    const presented = sim.presents().len;
    try sim.run(&pacer, 3000);
    const wakes = sim.blinkWakes()[first..];
    try testing.expect(wakes.len >= 4 and wakes.len <= 5);
    for (wakes[1..], wakes[0 .. wakes.len - 1]) |b, a| {
        try testing.expect(b - a >= blink_interval_ms * ns_per_ms);
        try testing.expect(b - a < (blink_interval_ms + timer_tick_ms) * ns_per_ms);
    }
    // Each toggle's wake presents the new phase.
    try testing.expectEqual(presented + wakes.len, sim.presents().len);
    // The first frame drew the cursor hidden; each toggle flips it.
    try testing.expectEqual(@as(?bool, wakes.len % 2 == 1), sim.drawn_blink_visible);
}

test "a blink restart while the run is queued shows the cursor for a whole interval" {
    // Input restarts the blink with the run already queued: it waits out the
    // interval from its own turn, rounded up to a whole ms, and never arms
    // the queued completion again (on IOCP it stays active until its
    // callback runs; the Sim fails a run that arms it).
    var sim: Sim = .{ .blinking = true };
    var pacer = try settled(&sim);
    while (sim.blinkWakes().len == 0) try sim.run(&pacer, 10);
    const runs_ns = sim.runsAtNs(.blink).?;
    // The restart lands 599.5 ms before the queued run: half a millisecond
    // of the interval is left when it runs.
    sim.advanceTo(runs_ns - blink_interval_ms * ns_per_ms + ns_per_ms / 2);
    const reset_ns = sim.now_ns;
    sim.send(.reset_cursor_blink);
    try sim.run(&pacer, 0);
    try testing.expectEqual(@as(?bool, true), sim.drawn_blink_visible);
    const first = sim.blinkWakes().len;
    try sim.run(&pacer, 2 * blink_interval_ms);
    const wakes = sim.blinkWakes()[first..];
    try testing.expect(wakes.len >= 1);
    try testing.expect(wakes[0] >= reset_ns + blink_interval_ms * ns_per_ms);
}

test "losing focus shows the cursor and lets the blink timer lapse" {
    var sim: Sim = .{ .blinking = true };
    var pacer = try settled(&sim);
    // Run to a toggle that hides the cursor.
    while (sim.drawn_blink_visible != false) try sim.run(&pacer, 50);
    const wakes = sim.blinkWakes().len;
    sim.send(.{ .focus = false });
    try sim.run(&pacer, 0);
    try testing.expectEqual(@as(?bool, true), sim.drawn_blink_visible);
    try sim.run(&pacer, 2 * blink_interval_ms);
    try testing.expect(!sim.pending(.blink));
    try testing.expectEqual(wakes, sim.blinkWakes().len);

    // A cursor that turns steady while hidden is shown by the next run,
    // with one wake, and its timer lapses.
    sim.send(.{ .focus = true });
    try sim.run(&pacer, 0);
    while (sim.drawn_blink_visible != false) try sim.run(&pacer, 50);
    sim.blinking = false;
    const steady = sim.blinkWakes().len;
    try sim.run(&pacer, 2 * blink_interval_ms);
    try testing.expectEqual(steady + 1, sim.blinkWakes().len);
    try testing.expectEqual(@as(?bool, true), sim.drawn_blink_visible);
    try testing.expect(!sim.pending(.blink));
}
