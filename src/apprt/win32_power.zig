//! Power/battery awareness (C02).
//!
//! `GetSystemPowerStatus` is the OS source of truth. On battery we
//! throttle unfocused repaints; AC + focused stays at the normal path.
//!
//! ponytail: idle wattage is published by `scripts/bench-windows.ps1`
//! once a same-machine baseline exists. This module only classifies
//! the current power state.

const std = @import("std");
const builtin = @import("builtin");

pub const State = struct {
    on_battery: bool = false,
    battery_percent: u8 = 255,
};

pub const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: u8,
    BatteryFlag: u8,
    BatteryLifePercent: u8,
    SystemStatusFlag: u8,
    BatteryLifeTime: u32,
    BatteryFullLifeTime: u32,
};

pub fn fromStatus(status: SYSTEM_POWER_STATUS) State {
    return .{
        .on_battery = status.ACLineStatus == 0,
        .battery_percent = status.BatteryLifePercent,
    };
}

/// Unfocused panes skip extra renderer wakes while on battery.
pub fn shouldThrottleUnfocused(state: State, focused: bool) bool {
    return state.on_battery and !focused;
}

pub fn query() State {
    if (comptime builtin.os.tag != .windows) return .{};
    var status: SYSTEM_POWER_STATUS = std.mem.zeroes(SYSTEM_POWER_STATUS);
    if (GetSystemPowerStatus(&status) == 0) return .{};
    return fromStatus(status);
}

extern "kernel32" fn GetSystemPowerStatus(lpSystemPowerStatus: *SYSTEM_POWER_STATUS) callconv(.winapi) i32;

test "fromStatus treats ACLineStatus 0 as battery" {
    const battery = fromStatus(.{
        .ACLineStatus = 0,
        .BatteryFlag = 1,
        .BatteryLifePercent = 40,
        .SystemStatusFlag = 0,
        .BatteryLifeTime = 0,
        .BatteryFullLifeTime = 0,
    });
    try std.testing.expect(battery.on_battery);
    try std.testing.expectEqual(@as(u8, 40), battery.battery_percent);
    try std.testing.expect(shouldThrottleUnfocused(battery, false));
    try std.testing.expect(!shouldThrottleUnfocused(battery, true));

    const ac = fromStatus(.{
        .ACLineStatus = 1,
        .BatteryFlag = 8,
        .BatteryLifePercent = 100,
        .SystemStatusFlag = 0,
        .BatteryLifeTime = 0,
        .BatteryFullLifeTime = 0,
    });
    try std.testing.expect(!ac.on_battery);
    try std.testing.expect(!shouldThrottleUnfocused(ac, false));
}
