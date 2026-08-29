//! Win32 power-state sampling, notifications, and render pacing policy.

const std = @import("std");
const configpkg = @import("../config.zig");

const log = std.log.scoped(.win32_power);
const windows = std.os.windows;

const BOOL = windows.BOOL;
const BYTE = windows.BYTE;
const DWORD = windows.DWORD;
const GUID = windows.GUID;
const HANDLE = windows.HANDLE;
const HRESULT = windows.HRESULT;
const HWND = windows.HWND;

pub const WM_POWERBROADCAST: windows.UINT = 0x0218;
pub const PBT_POWERSETTINGCHANGE: windows.WPARAM = 0x8013;

const DEVICE_NOTIFY_WINDOW_HANDLE: DWORD = 0;
const DWMWA_CLOAKED: DWORD = 14;
const POLL_INTERVAL_MS: u64 = 30 * std.time.ms_per_s;
/// Focused, non-saver surfaces keep this cadence, which must stay equal to
/// the renderer thread's DRAW_INTERVAL (asserted there at comptime).
pub const DEFAULT_PRESENT_INTERVAL_MS: u64 = 8;
const SAVER_PRESENT_INTERVAL_MS: u64 = 34;

const GUID_ACDC_POWER_SOURCE = GUID.parse("{5D3E9A59-E9D5-4B00-A6BD-FF34FF516548}");
const GUID_POWER_SAVING_STATUS = GUID.parse("{E00958C0-C213-4ACE-AC77-FECCED2EEEA5}");

pub const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: BYTE,
    BatteryFlag: BYTE,
    BatteryLifePercent: BYTE,
    SystemStatusFlag: BYTE,
    BatteryLifeTime: DWORD,
    BatteryFullLifeTime: DWORD,
};

const POWERBROADCAST_SETTING = extern struct {
    PowerSetting: GUID,
    DataLength: DWORD,
    Data: [1]BYTE,
};

comptime {
    std.debug.assert(@sizeOf(SYSTEM_POWER_STATUS) == 12);
    std.debug.assert(@offsetOf(POWERBROADCAST_SETTING, "Data") == 20);
    std.debug.assert(@sizeOf(POWERBROADCAST_SETTING) == 24);
}

extern "kernel32" fn GetSystemPowerStatus(status: *SYSTEM_POWER_STATUS) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "user32" fn RegisterPowerSettingNotification(
    recipient: HANDLE,
    power_setting_guid: *const GUID,
    flags: DWORD,
) callconv(.winapi) ?HANDLE;
extern "user32" fn UnregisterPowerSettingNotification(handle: HANDLE) callconv(.winapi) BOOL;
extern "user32" fn IsWindowVisible(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
extern "dwmapi" fn DwmGetWindowAttribute(
    hwnd: HWND,
    attribute: DWORD,
    value: *anyopaque,
    value_size: DWORD,
) callconv(.winapi) HRESULT;

const on_battery_bit: u8 = 1 << 0;
const saver_bit: u8 = 1 << 1;

var snapshot_bits = std.atomic.Value(u8).init(0);
var last_poll_tick_ms = std.atomic.Value(u64).init(0);

/// Process-wide power state. This is packed into one atomic byte so renderer
/// threads read a coherent, lock-free snapshot.
pub const Snapshot = struct {
    on_battery: bool = false,
    is_saver: bool = false,
};

pub const PolicyConfig = struct {
    unfocused_render_fps: u32,
    power_saver_rendering: configpkg.PowerSaverRendering,
};

pub const SettingUpdate = union(enum) {
    on_battery: bool,
    is_saver: bool,
};

pub const HostVisibility = struct {
    visible: bool,
    cloaked: bool,
};

/// Owns the two notification registrations associated with one host HWND.
pub const Notifications = struct {
    acdc: ?HANDLE = null,
    saver: ?HANDLE = null,

    pub fn init(hwnd: HWND) Notifications {
        pollIfStale();

        const acdc = RegisterPowerSettingNotification(
            @ptrCast(hwnd),
            &GUID_ACDC_POWER_SOURCE,
            DEVICE_NOTIFY_WINDOW_HANDLE,
        );
        if (acdc == null) {
            log.warn("AC/DC power notifications unavailable err={}", .{windows.kernel32.GetLastError()});
        }

        const saver = RegisterPowerSettingNotification(
            @ptrCast(hwnd),
            &GUID_POWER_SAVING_STATUS,
            DEVICE_NOTIFY_WINDOW_HANDLE,
        );
        if (saver == null) {
            log.warn("power-saver notifications unavailable err={}", .{windows.kernel32.GetLastError()});
        }

        return .{ .acdc = acdc, .saver = saver };
    }

    pub fn deinit(self: *Notifications) void {
        if (self.acdc) |handle| {
            if (UnregisterPowerSettingNotification(handle) == 0) {
                log.warn("failed to unregister AC/DC power notification err={}", .{windows.kernel32.GetLastError()});
            }
        }
        if (self.saver) |handle| {
            if (UnregisterPowerSettingNotification(handle) == 0) {
                log.warn("failed to unregister power-saver notification err={}", .{windows.kernel32.GetLastError()});
            }
        }
        self.* = .{};
    }
};

/// Convert the raw Win32 status structure without performing I/O. Unknown AC
/// state preserves the last known source while the saver flag follows the
/// documented exact `SystemStatusFlag == 1` contract.
pub fn parseSystemPowerStatus(raw: SYSTEM_POWER_STATUS, previous: Snapshot) Snapshot {
    return .{
        .on_battery = switch (raw.ACLineStatus) {
            0, 2 => true,
            1 => false,
            else => previous.on_battery,
        },
        .is_saver = raw.SystemStatusFlag == 1,
    };
}

/// Parse the variable-length payload delivered with
/// `PBT_POWERSETTINGCHANGE`. Both settings used here carry one DWORD.
pub fn parsePowerSettingNotification(payload: []const u8) ?SettingUpdate {
    const length_offset = @offsetOf(POWERBROADCAST_SETTING, "DataLength");
    const data_offset = @offsetOf(POWERBROADCAST_SETTING, "Data");
    const value_size = @sizeOf(DWORD);
    if (payload.len < data_offset + value_size) return null;
    const declared_len = std.mem.readInt(DWORD, payload[length_offset..][0..@sizeOf(DWORD)], .little);
    if (declared_len != value_size) return null;

    const value = std.mem.readInt(DWORD, payload[data_offset..][0..value_size], .little);
    const guid_bytes = payload[@offsetOf(POWERBROADCAST_SETTING, "PowerSetting")..][0..@sizeOf(GUID)];
    if (std.mem.eql(u8, guid_bytes, std.mem.asBytes(&GUID_ACDC_POWER_SOURCE))) {
        return .{ .on_battery = switch (value) {
            0 => false,
            1, 2 => true,
            else => return null,
        } };
    }
    if (std.mem.eql(u8, guid_bytes, std.mem.asBytes(&GUID_POWER_SAVING_STATUS))) {
        return .{ .is_saver = switch (value) {
            0 => false,
            1 => true,
            else => return null,
        } };
    }
    return null;
}

/// Apply a power-setting message to the process snapshot. The message payload
/// is borrowed only for the duration of the window-procedure call.
pub fn handlePowerSettingChange(l_param: windows.LPARAM) bool {
    if (l_param == 0) return false;
    const payload: *const [@sizeOf(POWERBROADCAST_SETTING)]u8 =
        @ptrFromInt(@as(usize, @bitCast(l_param)));
    const update = parsePowerSettingNotification(payload) orelse return false;
    publishSetting(update);
    return true;
}

/// Return the current process power state with one atomic load.
pub fn snapshot() Snapshot {
    return unpackSnapshot(snapshot_bits.load(.acquire));
}

/// Opportunistic fallback for systems where notifications are unavailable or
/// missed. The atomic claim ensures calls cannot query more often than once per
/// 30 seconds across all renderer threads.
pub fn pollIfStale() void {
    const now = GetTickCount64();
    var previous = last_poll_tick_ms.load(.acquire);
    if (previous != 0 and now -| previous < POLL_INTERVAL_MS) return;
    while (true) {
        if (last_poll_tick_ms.cmpxchgWeak(previous, now, .acq_rel, .acquire)) |observed| {
            previous = observed;
            if (previous != 0 and now -| previous < POLL_INTERVAL_MS) return;
            continue;
        }
        break;
    }

    var raw: SYSTEM_POWER_STATUS = undefined;
    if (GetSystemPowerStatus(&raw) == 0) return;
    publishSnapshot(parseSystemPowerStatus(raw, snapshot()));
}

/// Monotonic millisecond clock shared with Win32 notification and visibility
/// code. Renderer pacing uses this only when throttling is active.
pub fn tickCountMs() u64 {
    return GetTickCount64();
}

/// Whether saver-specific pacing is active for the current configuration.
pub fn saverRenderingActive(mode: configpkg.PowerSaverRendering, state: Snapshot) bool {
    return switch (mode) {
        .auto => state.is_saver,
        .on => true,
        .off => false,
    };
}

/// Pure render-pacing policy. `null` means the surface must not present.
/// Focused, visible, non-saver surfaces retain the existing 8 ms cadence.
pub fn minimumPresentIntervalMs(
    focused: bool,
    visible: bool,
    state: Snapshot,
    config: PolicyConfig,
) ?u64 {
    if (!visible) return null;

    const saver_active = saverRenderingActive(config.power_saver_rendering, state);
    if (focused and !saver_active) return DEFAULT_PRESENT_INTERVAL_MS;

    const unfocused_interval = fpsIntervalMs(config.unfocused_render_fps);
    if (!focused and !saver_active) return unfocused_interval;

    return if (focused)
        SAVER_PRESENT_INTERVAL_MS
    else
        @max(SAVER_PRESENT_INTERVAL_MS, unfocused_interval);
}

/// Pure host-window visibility decision. A host presents only while its
/// window is shown, not minimized, and not DWM-cloaked. Logical tab/split
/// visibility is tracked separately per surface and ANDed with this.
pub fn hostVisible(window_visible: bool, minimized: bool, cloaked: bool) bool {
    return window_visible and !minimized and !cloaked;
}

/// Query host visibility while preserving the last cloak result if DWM cannot
/// answer transiently.
pub fn queryHostVisibility(hwnd: HWND, previous_cloaked: bool) HostVisibility {
    var cloak_reason: DWORD = 0;
    const result = DwmGetWindowAttribute(
        hwnd,
        DWMWA_CLOAKED,
        &cloak_reason,
        @sizeOf(DWORD),
    );
    const cloaked = if (result >= 0) cloak_reason != 0 else previous_cloaked;
    return .{
        .visible = hostVisible(
            IsWindowVisible(hwnd) != 0,
            IsIconic(hwnd) != 0,
            cloaked,
        ),
        .cloaked = cloaked,
    };
}

fn fpsIntervalMs(fps: u32) u64 {
    const normalized: u64 = @max(1, @as(u64, fps));
    return @max(
        DEFAULT_PRESENT_INTERVAL_MS,
        (std.time.ms_per_s + normalized - 1) / normalized,
    );
}

fn packSnapshot(value: Snapshot) u8 {
    return @as(u8, @intFromBool(value.on_battery)) * on_battery_bit |
        @as(u8, @intFromBool(value.is_saver)) * saver_bit;
}

fn unpackSnapshot(bits: u8) Snapshot {
    return .{
        .on_battery = bits & on_battery_bit != 0,
        .is_saver = bits & saver_bit != 0,
    };
}

fn publishSnapshot(value: Snapshot) void {
    snapshot_bits.store(packSnapshot(value), .release);
}

fn publishSetting(update: SettingUpdate) void {
    var current = snapshot_bits.load(.acquire);
    while (true) {
        var next = current;
        switch (update) {
            .on_battery => |value| {
                if (value) next |= on_battery_bit else next &= ~on_battery_bit;
            },
            .is_saver => |value| {
                if (value) next |= saver_bit else next &= ~saver_bit;
            },
        }
        current = snapshot_bits.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return;
    }
}

fn settingPayload(guid: GUID, value: DWORD) [@sizeOf(POWERBROADCAST_SETTING)]u8 {
    var payload = [_]u8{0} ** @sizeOf(POWERBROADCAST_SETTING);
    @memcpy(
        payload[@offsetOf(POWERBROADCAST_SETTING, "PowerSetting")..][0..@sizeOf(GUID)],
        std.mem.asBytes(&guid),
    );
    std.mem.writeInt(
        DWORD,
        payload[@offsetOf(POWERBROADCAST_SETTING, "DataLength")..][0..@sizeOf(DWORD)],
        @sizeOf(DWORD),
        .little,
    );
    std.mem.writeInt(
        DWORD,
        payload[@offsetOf(POWERBROADCAST_SETTING, "Data")..][0..@sizeOf(DWORD)],
        value,
        .little,
    );
    return payload;
}

test "power status parsing preserves unknown AC state" {
    const previous: Snapshot = .{ .on_battery = true, .is_saver = false };
    try std.testing.expectEqual(
        Snapshot{ .on_battery = false, .is_saver = true },
        parseSystemPowerStatus(.{
            .ACLineStatus = 1,
            .BatteryFlag = 0,
            .BatteryLifePercent = 80,
            .SystemStatusFlag = 1,
            .BatteryLifeTime = 0,
            .BatteryFullLifeTime = 0,
        }, previous),
    );
    try std.testing.expectEqual(
        Snapshot{ .on_battery = true, .is_saver = false },
        parseSystemPowerStatus(.{
            .ACLineStatus = 0xff,
            .BatteryFlag = 0xff,
            .BatteryLifePercent = 0xff,
            .SystemStatusFlag = 2,
            .BatteryLifeTime = 0xffff_ffff,
            .BatteryFullLifeTime = 0xffff_ffff,
        }, previous),
    );
}

test "power notification parsing accepts registered settings" {
    const acdc = settingPayload(GUID_ACDC_POWER_SOURCE, 1);
    try std.testing.expectEqual(
        SettingUpdate{ .on_battery = true },
        parsePowerSettingNotification(&acdc).?,
    );

    const saver = settingPayload(GUID_POWER_SAVING_STATUS, 0);
    try std.testing.expectEqual(
        SettingUpdate{ .is_saver = false },
        parsePowerSettingNotification(&saver).?,
    );

    const saver_on = settingPayload(GUID_POWER_SAVING_STATUS, 1);
    try std.testing.expectEqual(
        SettingUpdate{ .is_saver = true },
        parsePowerSettingNotification(&saver_on).?,
    );

    var malformed = settingPayload(GUID_POWER_SAVING_STATUS, 1);
    std.mem.writeInt(
        DWORD,
        malformed[@offsetOf(POWERBROADCAST_SETTING, "DataLength")..][0..@sizeOf(DWORD)],
        8,
        .little,
    );
    try std.testing.expect(parsePowerSettingNotification(&malformed) == null);
}

test "power render policy preserves focused non-saver pacing" {
    const config: PolicyConfig = .{
        .unfocused_render_fps = 30,
        .power_saver_rendering = .auto,
    };
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        true,
        true,
        .{ .on_battery = false, .is_saver = false },
        config,
    ));
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        true,
        true,
        .{ .on_battery = true, .is_saver = false },
        config,
    ));
    try std.testing.expectEqual(@as(?u64, null), minimumPresentIntervalMs(
        true,
        false,
        .{ .on_battery = true, .is_saver = true },
        config,
    ));
}

test "power render policy caps saver and unfocused surfaces" {
    const sixty_fps: PolicyConfig = .{
        .unfocused_render_fps = 60,
        .power_saver_rendering = .auto,
    };
    try std.testing.expectEqual(@as(?u64, 17), minimumPresentIntervalMs(
        false,
        true,
        .{},
        sixty_fps,
    ));
    var uncapped = sixty_fps;
    uncapped.unfocused_render_fps = 1000;
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        false,
        true,
        .{},
        uncapped,
    ));
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        true,
        true,
        .{ .on_battery = true, .is_saver = true },
        sixty_fps,
    ));
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        false,
        true,
        .{ .on_battery = true, .is_saver = true },
        sixty_fps,
    ));

    var forced = sixty_fps;
    forced.power_saver_rendering = .on;
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        true,
        true,
        .{},
        forced,
    ));

    forced.power_saver_rendering = .off;
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        true,
        true,
        .{ .is_saver = true },
        forced,
    ));
}

test "power visibility policy rejects hidden minimized and cloaked hosts" {
    try std.testing.expect(hostVisible(true, false, false));
    try std.testing.expect(!hostVisible(false, false, false));
    try std.testing.expect(!hostVisible(true, true, false));
    try std.testing.expect(!hostVisible(true, false, true));
    try std.testing.expect(!hostVisible(true, true, true));
}
