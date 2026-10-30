//! Win32 frame pacing for one renderer thread: how often a pane may present,
//! read through the clock its runtime provides. OpenGL and the D3D11 beta
//! share it through renderer.Thread.
const Pacer = @This();

const std = @import("std");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");

/// A focused pane outside saver pacing presents at most this often (120
/// fps). Intervals at or below it are not paced.
pub const draw_interval_ms = 8;

/// Saver pacing, about 30 fps.
const saver_interval_ms = 34;

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
        return internal_os.monotonic.nowNs();
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

/// How often a pane may present, or null when it must not (hidden). A
/// focused pane outside saver pacing keeps `draw_interval_ms`. `saver` is
/// what `Clock.saver` reports.
pub fn minimumPresentIntervalMs(focused: bool, visible: bool, saver: bool, config: Config) ?u64 {
    if (!visible) return null;

    const saver_active = switch (config.power_saver_rendering) {
        // `auto` follows Battery Saver or Energy Saver, never plain battery.
        .auto => saver,
        .on => true,
        .off => false,
    };
    if (focused and !saver_active) return draw_interval_ms;

    const unfocused_interval = fpsIntervalMs(config.unfocused_render_fps);
    if (!focused and !saver_active) return unfocused_interval;

    return if (focused)
        saver_interval_ms
    else
        @max(saver_interval_ms, unfocused_interval);
}

fn fpsIntervalMs(fps: u32) u64 {
    const normalized: u64 = @max(1, @as(u64, fps));
    return @max(
        draw_interval_ms,
        (std.time.ms_per_s + normalized - 1) / normalized,
    );
}

test "power render policy preserves focused non-saver pacing" {
    const config: Config = .{
        .unfocused_render_fps = 30,
        .power_saver_rendering = .auto,
    };
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        true,
        true,
        false,
        config,
    ));
    // 60 fps here so the expected value distinguishes the unfocused cap (17)
    // from saver pacing (34) instead of colliding with it at 30 fps.
    var sixty = config;
    sixty.unfocused_render_fps = 60;
    try std.testing.expectEqual(@as(?u64, 17), minimumPresentIntervalMs(
        false,
        true,
        false,
        sixty,
    ));
    // Either saver source drives `auto`: `Clock.saver` reports their union.
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        true,
        true,
        true,
        config,
    ));
    try std.testing.expectEqual(@as(?u64, null), minimumPresentIntervalMs(
        true,
        false,
        true,
        config,
    ));
}

test "power render policy caps saver and unfocused surfaces" {
    const sixty_fps: Config = .{
        .unfocused_render_fps = 60,
        .power_saver_rendering = .auto,
    };
    try std.testing.expectEqual(@as(?u64, 17), minimumPresentIntervalMs(
        false,
        true,
        false,
        sixty_fps,
    ));
    var uncapped = sixty_fps;
    uncapped.unfocused_render_fps = 1000;
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        false,
        true,
        false,
        uncapped,
    ));
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        true,
        true,
        true,
        sixty_fps,
    ));
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        false,
        true,
        true,
        sixty_fps,
    ));

    var forced = sixty_fps;
    forced.power_saver_rendering = .on;
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        true,
        true,
        false,
        forced,
    ));

    forced.power_saver_rendering = .off;
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        true,
        true,
        true,
        forced,
    ));
}
