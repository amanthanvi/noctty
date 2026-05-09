//! Shared tween/animation scaffold for the Win32 apprt.
//!
//! One `Tween` represents a scalar animated value. `Scheduler` owns the
//! set of active tweens for a given `HWND` and drives a 16 ms
//! `SetTimer(hwnd, timer_id, 16, null)` while non-empty. When the last
//! tween completes, the timer is stopped; no idle CPU.
//!
//! Typical use:
//!
//!     var sched: Scheduler = .{};
//!     sched.init(my_alloc);
//!     // on show:
//!     const id = try sched.add(hwnd, .{
//!         .from = 0.0,
//!         .to = 1.0,
//!         .duration_ms = theme.motion.duration_standard_ms,
//!         .easing = theme.motion.easing_decelerate,
//!     });
//!     // on WM_TIMER: sched.tick(hwnd, GetTickCount64());
//!     // on paint: const alpha = sched.value(id) orelse 1.0;
//!
//! Reduced motion (SPI_GETCLIENTAREAANIMATION = FALSE, or HC mode)
//! collapses every tween's duration to 0; `value()` reports `.to`
//! immediately. The ThemeMotion struct already has `reduced()` to
//! return that collapsed shape.

const std = @import("std");
const win32_theme = @import("win32_theme.zig");

/// Cubic Bézier-like easing. `c` is the same 4-element array shape as
/// `ThemeMotion.easing_*` tokens (x1, y1, x2, y2).
pub fn bezier(c: [4]f32, t: f32) f32 {
    // Newton-Raphson inversion of the cubic Bézier x(t) to solve for
    // parameter `u` given `x = t`, then evaluate y(u). Fast, allocation-
    // free, monotonic input → monotonic output for well-formed curves.
    const tt = std.math.clamp(t, 0.0, 1.0);

    // sample x(u) for a given parameter u
    const ax = 1.0 - 3.0 * c[2] + 3.0 * c[0];
    const bx = 3.0 * c[2] - 6.0 * c[0];
    const cx = 3.0 * c[0];

    const ay = 1.0 - 3.0 * c[3] + 3.0 * c[1];
    const by = 3.0 * c[3] - 6.0 * c[1];
    const cy = 3.0 * c[1];

    // Solve x(u) = tt for u via Newton-Raphson with 6 iterations.
    var u: f32 = tt;
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        const xu = ((ax * u + bx) * u + cx) * u;
        const dx = (3.0 * ax * u + 2.0 * bx) * u + cx;
        if (@abs(dx) < 1e-6) break;
        u -= (xu - tt) / dx;
        u = std.math.clamp(u, 0.0, 1.0);
    }

    return ((ay * u + by) * u + cy) * u;
}

pub const TweenId = u32;

pub const Tween = struct {
    from: f32,
    to: f32,
    /// Absolute start time in ms (GetTickCount64 or equivalent).
    start_ms: u64 = 0,
    /// Logical duration in ms. 0 = snap immediately to `to`.
    duration_ms: u16,
    /// Bézier easing coefficients (x1, y1, x2, y2). Pulled from
    /// ThemeMotion.easing_* tokens.
    easing: [4]f32,
    /// Completed flag; set when the scheduler observes t >= 1.0.
    done: bool = false,

    pub fn value(self: *const Tween, now_ms: u64) f32 {
        if (self.duration_ms == 0) return self.to;
        if (now_ms <= self.start_ms) return self.from;
        const elapsed = now_ms - self.start_ms;
        if (elapsed >= self.duration_ms) return self.to;
        const t: f32 = @as(f32, @floatFromInt(elapsed)) /
            @as(f32, @floatFromInt(self.duration_ms));
        const eased = bezier(self.easing, t);
        return self.from + (self.to - self.from) * eased;
    }

    pub fn finished(self: *const Tween, now_ms: u64) bool {
        return self.duration_ms == 0 or
            (now_ms >= self.start_ms and (now_ms - self.start_ms) >= self.duration_ms);
    }
};

/// Per-HWND tween scheduler. Not thread-safe; must be touched only from
/// the main (UI) thread, which is where all Win32 animations run given
/// `must_draw_from_app_thread = true`.
pub const Scheduler = struct {
    alloc: std.mem.Allocator = undefined,
    tweens: std.AutoHashMapUnmanaged(TweenId, Tween) = .{},
    next_id: TweenId = 1,
    timer_active: bool = false,

    pub fn init(self: *Scheduler, alloc: std.mem.Allocator) void {
        self.* = .{ .alloc = alloc };
    }

    pub fn deinit(self: *Scheduler) void {
        self.tweens.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn add(self: *Scheduler, now_ms: u64, t: Tween) !TweenId {
        var inst = t;
        inst.start_ms = now_ms;
        const id = self.next_id;
        self.next_id +%= 1;
        try self.tweens.put(self.alloc, id, inst);
        return id;
    }

    /// Return the current value of a tween. Returns null if the id no
    /// longer exists (completed tweens auto-remove on tick).
    pub fn value(self: *const Scheduler, id: TweenId, now_ms: u64) ?f32 {
        const t = self.tweens.getPtr(id) orelse return null;
        return t.value(now_ms);
    }

    /// Remove finished tweens. Returns true if the scheduler still has
    /// active tweens (caller should keep the WM_TIMER alive).
    pub fn tick(self: *Scheduler, now_ms: u64) bool {
        var it = self.tweens.iterator();
        var to_remove: [32]TweenId = undefined;
        var n: usize = 0;
        while (it.next()) |entry| {
            if (entry.value_ptr.finished(now_ms)) {
                if (n < to_remove.len) {
                    to_remove[n] = entry.key_ptr.*;
                    n += 1;
                }
            }
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = self.tweens.remove(to_remove[i]);
        }
        return self.tweens.count() > 0;
    }

    pub fn isEmpty(self: *const Scheduler) bool {
        return self.tweens.count() == 0;
    }

    pub fn cancel(self: *Scheduler, id: TweenId) void {
        _ = self.tweens.remove(id);
    }
};

test "bezier: endpoints and monotonicity for Fluent 'standard' curve" {
    const c = [_]f32{ 0.33, 0.00, 0.67, 1.00 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), bezier(c, 0.0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bezier(c, 1.0), 0.01);

    var last: f32 = 0.0;
    var i: u32 = 0;
    while (i <= 10) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 10.0;
        const y = bezier(c, t);
        try std.testing.expect(y >= last - 0.001);
        last = y;
    }
}

test "tween: zero duration snaps to target" {
    const t: Tween = .{
        .from = 0.0,
        .to = 1.0,
        .duration_ms = 0,
        .easing = .{ 0.0, 0.0, 1.0, 1.0 },
    };
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), t.value(0), 1e-6);
    try std.testing.expect(t.finished(0));
}

test "tween: interpolates across midpoint" {
    const t: Tween = .{
        .from = 0.0,
        .to = 100.0,
        .start_ms = 1_000,
        .duration_ms = 200,
        .easing = .{ 0.33, 0.0, 0.67, 1.0 },
    };
    // Midpoint should be roughly at 50% of the range.
    const mid = t.value(1_100);
    try std.testing.expect(mid > 30.0 and mid < 70.0);
    try std.testing.expect(!t.finished(1_100));
    try std.testing.expect(t.finished(1_300));
}

test "scheduler: add, tick, expire" {
    var sched: Scheduler = .{};
    sched.init(std.testing.allocator);
    defer sched.deinit();

    const id = try sched.add(0, .{
        .from = 0.0,
        .to = 1.0,
        .duration_ms = 100,
        .easing = .{ 0.33, 0.0, 0.67, 1.0 },
    });
    try std.testing.expect(!sched.isEmpty());
    try std.testing.expect(sched.value(id, 50) != null);

    // After duration elapses, tick returns false (no active tweens).
    try std.testing.expect(!sched.tick(200));
    try std.testing.expect(sched.isEmpty());
    try std.testing.expect(sched.value(id, 200) == null);
}

test "scheduler: cancel removes only the requested tween" {
    var sched: Scheduler = .{};
    sched.init(std.testing.allocator);
    defer sched.deinit();

    const first = try sched.add(0, .{
        .from = 0.0,
        .to = 1.0,
        .duration_ms = 100,
        .easing = .{ 0.33, 0.0, 0.67, 1.0 },
    });
    const second = try sched.add(0, .{
        .from = 0.0,
        .to = 1.0,
        .duration_ms = 100,
        .easing = .{ 0.33, 0.0, 0.67, 1.0 },
    });

    sched.cancel(first);

    try std.testing.expect(sched.value(first, 50) == null);
    try std.testing.expect(sched.value(second, 50) != null);
    try std.testing.expect(!sched.isEmpty());
}

test "bezier: matches motion tokens shape" {
    // The ThemeMotion default curves must produce sensible values.
    const motion: win32_theme.ThemeMotion = .{};
    const quick_mid = bezier(motion.easing_standard, 0.5);
    const decel_mid = bezier(motion.easing_decelerate, 0.5);
    // decelerate curve pushes progress earlier: y(0.5) > standard's y(0.5)
    try std.testing.expect(decel_mid >= quick_mid);
}
