//! The pacer's test adapter: a modelled renderer thread for `Pacer.turn`.
//! It stands in for renderer.Thread.Frame and for what drives it, so the
//! tests cross the seam production does. It models what was measured:
//! - one loop pass runs the due timers, then the async wake (renderer.md
//!   2026-10-15 LAT-02 (3); the real-loop test below pins it), and a
//!   waiting loop wakes on the first 15.625 ms system tick at or after a
//!   deadline (PKG-37 (2)). A deadline lies on the millisecond the pacer
//!   computed it from, and of two due at once the one armed first runs
//!   first, as #297 inferred (renderer.md 2026-10-08);
//! - a present hands the apprt's repaint reservation to a paint the UI
//!   thread completes after the pass. A frame asked for meanwhile coalesces,
//!   and the paint's completion wakes the renderer (`apprt_repaint_retry`);
//! - termio records the wake for its output under the lock, by its own rule
//!   (`Termio.shouldWakeRendererAfterOutput`), then stamps the notify.
//! A run fails on a seam violation: a timer armed twice in one turn, a
//! pending deadline moved later, a pending blink completion run again, or
//! Clock.saver read outside `auto`.
const Sim = @This();

const std = @import("std");
const configpkg = @import("../config.zig");
const xev = @import("../global.zig").xev;
const Pacer = @import("Pacer.zig");
const State = @import("State.zig");
const Termio = @import("../termio/Termio.zig");

const ns_per_ms = std.time.ns_per_ms;
const tick_ns = 15_625_000;

/// The clock. It starts at 1 s: 0 is "never" to the pacer.
now_ns: u64 = std.time.ns_per_s,
saver: bool = false,

// Thread.flags and Thread.config.
focused: bool = true,
visible: bool = true,
config: Pacer.Config = .{ .unfocused_render_fps = 30, .power_saver_rendering = .auto },
/// The loaded custom shader's `custom-shader-animation`; null for none.
shader: ?configpkg.CustomShaderAnimation = null,
/// The D3D11 backend has an occluded frame to present again.
presentation_pending: bool = false,
presentation_changed: bool = false,

// The mailbox.
messages: [16]Message = undefined,
message_count: usize = 0,
/// The next drain fails after applying its messages.
fail_drain: bool = false,

// The terminal, which termio and the renderer share under State.mutex.
/// Something the next frame update draws (`render_dirty.needsFrame`).
work: bool = false,
/// Synchronized output (mode 2026) holds the frame.
sync: bool = false,
/// The cursor's blinking mode.
blinking: bool = false,
wake_sources: u32 = 0,
notified_ns: u64 = 0,
/// The wakeup async was notified and its callback has not run.
woken: bool = false,

// The apprt's repaint reservation and the UI thread's paint.
reserved: bool = false,
retry: bool = false,
painting: bool = false,
/// The UI thread is busy: a queued paint waits for `releasePaint`.
paint_held: bool = false,

// The loop.
deadlines: std.EnumArray(Pacer.Timer, ?u64) = .initFill(null),
armed_at: std.EnumArray(Pacer.Timer, u64) = .initFill(0),
arm_count: u64 = 0,
armed: std.EnumSet(Pacer.Timer) = .{},
trigger: ?Pacer.Trigger = null,
violation: ?[]const u8 = null,

// What happened.
log: [4096]Present = undefined,
log_len: usize = 0,
/// A drain showed the pane since the last present.
shown: bool = false,
/// The blink phase the last frame update drew.
drawn_blink_visible: ?bool = null,
/// When the pacer woke the renderer for the blink.
blink_wakes: [64]u64 = undefined,
blink_wake_count: usize = 0,
/// Frame updates run in follow-up turns, held ones included.
followup_updates: u32 = 0,
turns: std.EnumArray(Pacer.Timer, u32) = .initFill(0),

pub const Present = struct {
    ns: u64,
    /// The turn that presented.
    trigger: Pacer.Trigger,
    /// It presented a frame update, not only the current frame data.
    update: bool,
    /// The pane was shown again just before it.
    after_show: bool,
};

pub const Message = union(enum) {
    focus: bool,
    visible: bool,
    config: struct { pacing: Pacer.Config, shader: ?configpkg.CustomShaderAnimation },
    split_dimmed,
    reset_cursor_blink,
    /// A message pacing does not read that changes the frame without
    /// marking anything dirty (a search highlight).
    search,
};

pub const Output = struct {
    /// It changes what the next frame draws: cells, or the cursor or the
    /// colors (`render_dirty.Undirtied`).
    work: bool = true,
    /// It begins (BSU) or ends (ESU) synchronized output.
    bsu: bool = false,
    esu: bool = false,
    /// It sets the cursor's blinking mode (DECSCUSR).
    blinking: ?bool = null,
};

pub fn clock(sim: *Sim) Pacer.Clock {
    return .{ .ctx = sim, .now_ns = clockNs, .saver = clockSaver };
}

/// The first wake, as threadMain_ sends it.
pub fn start(sim: *Sim) void {
    sim.notify(.thread_start);
}

/// termio processing one read: under the lock the terminal changes and the
/// wake is recorded, then queueRender stamps the notify and wakes.
pub fn output(sim: *Sim, o: Output) void {
    const had_work = sim.work;
    const was_sync = sim.sync;
    if (o.bsu) sim.sync = true;
    if (o.work) sim.work = true;
    if (o.blinking) |blinking| sim.blinking = blinking;
    if (o.esu) sim.sync = false;
    if (!Termio.shouldWakeRendererAfterOutput(
        had_work,
        sim.work,
        false,
        sim.sync,
        was_sync and !sim.sync,
        o.bsu and !sim.sync,
    )) return;
    sim.notify(.io_output);
    sim.notified_ns = sim.now_ns;
}

/// A change that needs a frame and asks for no wake (before LAT-02 (1), a
/// cursor moved within its row).
pub fn touch(sim: *Sim) void {
    sim.work = true;
}

/// Thread.send: the message, then the wake.
pub fn send(sim: *Sim, message: Message) void {
    sim.messages[sim.message_count] = message;
    sim.message_count += 1;
    sim.notify(.mailbox);
}

/// A WM_PAINT that found no frame reserved, as an expose sends it.
pub fn expose(sim: *Sim) void {
    sim.wakeFrom(.apprt_paint_retry);
}

/// A producer records `source`, then notifies the wakeup async.
pub fn wakeFrom(sim: *Sim, source: State.WakeSource) void {
    sim.notify(source);
}

/// Windows.setPresentationPending: the flag, then a wake with no source.
pub fn setPresentationPending(sim: *Sim, value: bool) void {
    if (sim.presentation_pending == value) return;
    sim.presentation_pending = value;
    sim.presentation_changed = true;
    sim.woken = true;
}

pub fn holdPaint(sim: *Sim) void {
    sim.paint_held = true;
}

pub fn releasePaint(sim: *Sim) void {
    sim.paint_held = false;
    sim.paint();
}

/// The clock moves while the loop is busy elsewhere: nothing runs.
pub fn advance(sim: *Sim, ms: u64) void {
    sim.now_ns += ms * ns_per_ms;
}

pub fn advanceTo(sim: *Sim, ns: u64) void {
    sim.now_ns = @max(sim.now_ns, ns);
}

/// Run the loop for `ms` of clock time.
pub fn run(sim: *Sim, pacer: *Pacer, ms: u64) !void {
    const end_ns = sim.now_ns + ms * ns_per_ms;
    while (sim.nextPassNs()) |at| {
        if (at > end_ns) break;
        sim.now_ns = @max(sim.now_ns, at);
        sim.pass(pacer);
        if (sim.violation) |violation| {
            std.debug.print("pacer_sim: {s}\n", .{violation});
            return error.SeamViolation;
        }
    }
    sim.now_ns = end_ns;
}

pub fn pending(sim: *const Sim, timer: Pacer.Timer) bool {
    return sim.deadlines.get(timer) != null;
}

pub fn dueNs(sim: *const Sim, timer: Pacer.Timer) ?u64 {
    return sim.deadlines.get(timer);
}

/// When a waiting loop runs the timer: the first system tick at or after
/// its deadline.
pub fn runsAtNs(sim: *const Sim, timer: Pacer.Timer) ?u64 {
    const due = sim.deadlines.get(timer) orelse return null;
    return (due + tick_ns - 1) / tick_ns * tick_ns;
}

pub fn presents(sim: *const Sim) []const Present {
    return sim.log[0..sim.log_len];
}

pub fn blinkWakes(sim: *const Sim) []const u64 {
    return sim.blink_wakes[0..sim.blink_wake_count];
}

pub fn lastUpdateNs(sim: *const Sim) u64 {
    var i = sim.log_len;
    while (i > 0) {
        i -= 1;
        if (sim.log[i].update) return sim.log[i].ns;
    }
    return 0;
}

fn nextPassNs(sim: *const Sim) ?u64 {
    if (sim.woken) return sim.now_ns;
    var next: ?u64 = null;
    for (std.enums.values(Pacer.Timer)) |timer| {
        const at = sim.runsAtNs(timer) orelse continue;
        next = if (next) |n| @min(n, at) else at;
    }
    return next;
}

fn pass(sim: *Sim, pacer: *Pacer) void {
    var due: [std.enums.values(Pacer.Timer).len]Pacer.Timer = undefined;
    var due_len: usize = 0;
    for (std.enums.values(Pacer.Timer)) |timer| {
        const at = sim.deadlines.get(timer) orelse continue;
        if (at > sim.now_ns) continue;
        due[due_len] = timer;
        due_len += 1;
    }
    std.mem.sort(Pacer.Timer, due[0..due_len], @as(*const Sim, sim), runsFirst);
    for (due[0..due_len]) |timer| {
        sim.deadlines.set(timer, null);
        sim.turns.getPtr(timer).* += 1;
        sim.turn(pacer, .{ .due = timer });
    }
    if (sim.woken) {
        sim.woken = false;
        const sources = sim.wake_sources;
        sim.wake_sources = 0;
        sim.turn(pacer, .{ .wake = sources });
    }
    sim.paint();
}

fn runsFirst(sim: *const Sim, a: Pacer.Timer, b: Pacer.Timer) bool {
    const a_at = sim.deadlines.get(a).?;
    const b_at = sim.deadlines.get(b).?;
    if (a_at != b_at) return a_at < b_at;
    return sim.armed_at.get(a) < sim.armed_at.get(b);
}

fn turn(sim: *Sim, pacer: *Pacer, trigger: Pacer.Trigger) void {
    sim.armed = .{};
    sim.trigger = trigger;
    pacer.turn(trigger, sim);
    sim.trigger = null;
}

/// The UI thread paints the queued frame, which finishes the reservation;
/// a frame asked for meanwhile gets its wake now.
fn paint(sim: *Sim) void {
    if (!sim.painting or sim.paint_held) return;
    sim.painting = false;
    sim.reserved = false;
    if (sim.retry) {
        sim.retry = false;
        sim.notify(.apprt_repaint_retry);
    }
}

fn notify(sim: *Sim, source: State.WakeSource) void {
    sim.wake_sources |= source.bit();
    sim.woken = true;
}

fn fail(sim: *Sim, violation: []const u8) void {
    if (sim.violation == null) sim.violation = violation;
}

fn clockNs(ctx: ?*anyopaque) u64 {
    const sim: *Sim = @ptrCast(@alignCast(ctx.?));
    return sim.now_ns;
}

fn clockSaver(ctx: ?*anyopaque) bool {
    const sim: *Sim = @ptrCast(@alignCast(ctx.?));
    if (sim.config.power_saver_rendering != .auto) sim.fail("Clock.saver read outside auto");
    return sim.saver;
}

// The frame port (`Pacer.turn`).

pub fn drain(sim: *Sim) Pacer.Drained {
    var drained: Pacer.Drained = .{};
    for (sim.messages[0..sim.message_count]) |message| switch (message) {
        .focus => |v| if (sim.focused != v) {
            sim.focused = v;
            drained.changes.insert(.focus);
        },
        .visible => |v| if (sim.visible != v) {
            sim.visible = v;
            if (v) sim.shown = true;
            drained.changes.insert(.visibility);
        },
        .config => |config| {
            sim.config = config.pacing;
            sim.shader = config.shader;
            drained.changes.insert(.config);
        },
        .split_dimmed => drained.changes.insert(.repaint),
        .reset_cursor_blink => drained.changes.insert(.blink_reset),
        .search => {},
    };
    sim.message_count = 0;
    drained.failed = sim.fail_drain;
    sim.fail_drain = false;
    if (sim.presentation_changed) {
        sim.presentation_changed = false;
        drained.changes.insert(.presentation);
    }
    return drained;
}

pub fn inputs(sim: *Sim) Pacer.Inputs {
    return .{
        .focused = sim.focused,
        .visible = sim.visible,
        .config = sim.config,
        .notified_ns = sim.notified_ns,
    };
}

pub fn screen(sim: *Sim) Pacer.Screen {
    return .{
        .needs_frame = sim.work,
        .cursor_blinking = sim.blinking,
        .wake_pending = sim.wake_sources != 0,
    };
}

pub fn animation(sim: *Sim) ?Pacer.AnimationWake {
    if (sim.presentation_pending) return .{ .delay_ms = 250 };
    return switch (sim.shader orelse return null) {
        .always => .{ .delay_ms = 0 },
        .true => if (sim.focused) .{ .delay_ms = 0 } else null,
        .false => null,
    };
}

pub fn update(sim: *Sim, request: Pacer.Update) Pacer.UpdateResult {
    if (!sim.reserve()) return .coalesced;
    sim.drawn_blink_visible = request.blink_visible;
    if (sim.trigger.? == .due and sim.trigger.?.due == .followup) sim.followup_updates += 1;
    // updateFrame draws the work, unless synchronized output holds the
    // frame.
    if (!sim.sync) sim.work = false;
    if (sim.sync and !request.present_held) {
        sim.reserved = false;
        return .{ .updated = .{ .cursor_blinking = sim.blinking, .held = true, .presented = false } };
    }
    sim.present(true);
    return .{ .updated = .{ .cursor_blinking = sim.blinking, .held = sim.sync, .presented = true } };
}

pub fn draw(sim: *Sim) bool {
    if (!sim.reserve()) return false;
    sim.present(false);
    return true;
}

pub fn arm(sim: *Sim, timer: Pacer.Timer, delay_ms: u64) void {
    if (sim.armed.contains(timer)) return sim.fail("a timer armed twice in one turn");
    sim.armed.insert(timer);
    // On the millisecond the pacer computed it from.
    const due = (sim.now_ns / ns_per_ms + delay_ms) * ns_per_ms;
    if (sim.deadlines.get(timer)) |previous| {
        if (timer == .blink) return sim.fail("a pending blink completion armed again");
        if (due >= previous) return sim.fail("a pending deadline moved later");
    }
    sim.deadlines.set(timer, due);
    sim.arm_count += 1;
    sim.armed_at.set(timer, sim.arm_count);
}

pub fn wake(sim: *Sim, source: State.WakeSource) void {
    if (source == .cursor_blink) {
        if (sim.blink_wake_count == sim.blink_wakes.len) return sim.fail("blink log full");
        sim.blink_wakes[sim.blink_wake_count] = sim.now_ns;
        sim.blink_wake_count += 1;
    }
    sim.notify(source);
}

fn reserve(sim: *Sim) bool {
    if (sim.reserved) {
        sim.retry = true;
        return false;
    }
    sim.reserved = true;
    return true;
}

fn present(sim: *Sim, updated: bool) void {
    sim.painting = true;
    if (sim.log_len == sim.log.len) return sim.fail("present log full");
    sim.log[sim.log_len] = .{
        .ns = sim.now_ns,
        .trigger = sim.trigger.?,
        .update = updated,
        .after_show = sim.shown,
    };
    sim.log_len += 1;
    sim.shown = false;
}

test "libxev runs a due timer before an async wake notified in the same pass" {
    // The order the Sim's loop models (renderer.md 2026-10-15 LAT-02 (3)),
    // on the real IOCP loop. `.once` returns after a pass that completed
    // something, here the timer, which is due before the loop runs; a
    // `.no_wait` run never reaches the wait on IOCP (test-harnesses.md
    // 2026-09-23 #261 trap 1).
    const Order = struct {
        seen: [2]u8 = undefined,
        len: usize = 0,

        fn note(self: *@This(), event: u8) void {
            self.seen[self.len] = event;
            self.len += 1;
        }

        fn onTimer(
            self_: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = r catch unreachable;
            self_.?.note('T');
            return .disarm;
        }

        fn onWake(
            self_: ?*@This(),
            _: *xev.Loop,
            _: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            _ = r catch unreachable;
            self_.?.note('W');
            return .disarm;
        }
    };

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var timer = try xev.Timer.init();
    defer timer.deinit();
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();

    var order: Order = .{};
    var timer_c: xev.Completion = .{};
    var wakeup_c: xev.Completion = .{};
    wakeup.wait(&loop, &wakeup_c, Order, &order, Order.onWake);
    timer.run(&loop, &timer_c, 1, Order, &order, Order.onTimer);
    std.Thread.sleep(20 * ns_per_ms);
    try wakeup.notify();
    try loop.run(.once);
    try std.testing.expectEqualStrings("TW", order.seen[0..order.len]);
}
