//! Win32 power-state sampling, notifications, and render pacing policy.

const std = @import("std");
const configpkg = @import("../config.zig");
const sys = @import("win32/sys.zig");

const log = std.log.scoped(.win32_power);
const windows = std.os.windows;

const BOOL = windows.BOOL;
const BYTE = windows.BYTE;
const DWORD = windows.DWORD;
const GUID = windows.GUID;
const HANDLE = windows.HANDLE;
const HRESULT = windows.HRESULT;
const HWND = windows.HWND;
const LONG = windows.LONG;

pub const WM_POWERBROADCAST: windows.UINT = 0x0218;
pub const PBT_POWERSETTINGCHANGE: windows.WPARAM = 0x8013;

const DEVICE_NOTIFY_WINDOW_HANDLE: DWORD = 0;
const DWMWA_CLOAKED: DWORD = 14;

/// DWM cloak transitions (virtual-desktop switches, shell show/hide
/// animations, suspended UWP hosts) have NO window message. The documented
/// signal is this WinEvent pair, so a cloak-aware presenter has to hook it.
const EVENT_OBJECT_CLOAKED: DWORD = 0x8017;
const EVENT_OBJECT_UNCLOAKED: DWORD = 0x8018;
const WINEVENT_OUTOFCONTEXT: DWORD = 0x0000;
const OBJID_WINDOW: LONG = 0;
const CHILDID_SELF: LONG = 0;

const POLL_INTERVAL_MS: u64 = 30 * std.time.ms_per_s;
/// Focused, non-saver surfaces keep this cadence, which must stay equal to
/// the renderer thread's DRAW_INTERVAL (asserted there at comptime).
pub const DEFAULT_PRESENT_INTERVAL_MS: u64 = 8;
const SAVER_PRESENT_INTERVAL_MS: u64 = 34;

const GUID_ACDC_POWER_SOURCE = GUID.parse("{5D3E9A59-E9D5-4B00-A6BD-FF34FF516548}");
const GUID_POWER_SAVING_STATUS = GUID.parse("{E00958C0-C213-4ACE-AC77-FECCED2EEEA5}");
/// Windows 11 "Energy Saver", which unlike legacy battery saver can engage
/// while plugged in. Microsoft documents this GUID on the Power Setting GUIDs
/// (WinNT.h) page with exactly this value -- it happens to coincide with the
/// RFC 4122 example UUID -- but marks it PRERELEASE, so it may change.
/// Registration simply fails on builds that predate it, which is why that
/// failure is logged at debug rather than warn.
const GUID_ENERGY_SAVER_STATUS = GUID.parse("{550E8400-E29B-41D4-A716-446655440000}");

/// ENERGY_SAVER_STATUS, the Data payload of GUID_ENERGY_SAVER_STATUS.
const ENERGY_SAVER_OFF: DWORD = 0;
const ENERGY_SAVER_STANDARD: DWORD = 1;
const ENERGY_SAVER_HIGH_SAVINGS: DWORD = 2;

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
extern "user32" fn RegisterPowerSettingNotification(
    recipient: HANDLE,
    power_setting_guid: *const GUID,
    flags: DWORD,
) callconv(.winapi) ?HANDLE;
extern "user32" fn UnregisterPowerSettingNotification(handle: HANDLE) callconv(.winapi) BOOL;
extern "dwmapi" fn DwmGetWindowAttribute(
    hwnd: HWND,
    attribute: DWORD,
    value: *anyopaque,
    value_size: DWORD,
) callconv(.winapi) HRESULT;

const WinEventProc = *const fn (
    hook: ?HANDLE,
    event: DWORD,
    hwnd: ?HWND,
    id_object: LONG,
    id_child: LONG,
    event_thread: DWORD,
    event_time_ms: DWORD,
) callconv(.winapi) void;

extern "user32" fn SetWinEventHook(
    event_min: DWORD,
    event_max: DWORD,
    module: ?HANDLE,
    callback: WinEventProc,
    process_id: DWORD,
    thread_id: DWORD,
    flags: DWORD,
) callconv(.winapi) ?HANDLE;
extern "user32" fn UnhookWinEvent(hook: HANDLE) callconv(.winapi) BOOL;

const on_battery_bit: u8 = 1 << 0;
/// Legacy "Battery Saver" (GUID_POWER_SAVING_STATUS and the
/// `SYSTEM_POWER_STATUS.SystemStatusFlag` poll fallback).
const battery_saver_bit: u8 = 1 << 1;
/// Windows 11 "Energy Saver" (GUID_ENERGY_SAVER_STATUS). Independent of the
/// bit above: either source alone means saver pacing applies.
const energy_saver_bit: u8 = 1 << 2;

var snapshot_bits = std.atomic.Value(u8).init(0);
var last_poll_tick_ms = std.atomic.Value(u64).init(0);
/// Bumped by every notification-driven update so a slower poll can detect
/// that it raced a push and is therefore stale.
var push_generation = std.atomic.Value(u32).init(0);

/// Process-wide power state. This is packed into one atomic byte so renderer
/// threads read a coherent, lock-free snapshot.
pub const Snapshot = struct {
    on_battery: bool = false,
    /// Legacy Battery Saver. Reported by GUID_POWER_SAVING_STATUS and by
    /// `SYSTEM_POWER_STATUS.SystemStatusFlag`.
    battery_saver: bool = false,
    /// Windows 11 Energy Saver. Reported only by GUID_ENERGY_SAVER_STATUS;
    /// there is no `GetSystemPowerStatus` field for it.
    energy_saver: bool = false,

    /// Effective saver state: the union of the two independent sources.
    ///
    /// They must stay separate in storage. Windows reports them through
    /// different notifications that can disagree, so folding them into one
    /// flag at write time lets whichever notification arrives last erase the
    /// other -- e.g. Energy Saver turning OFF would clear saver pacing while
    /// Battery Saver is still on.
    ///
    /// `on_battery` is deliberately NOT a source here: `auto` follows the
    /// saver signals only, never plain battery power. See `Config.zig` and
    /// `docs/windows.md`.
    pub fn isSaver(self: Snapshot) bool {
        return self.battery_saver or self.energy_saver;
    }
};

pub const PolicyConfig = struct {
    unfocused_render_fps: u32,
    power_saver_rendering: configpkg.PowerSaverRendering,
};

/// A single-source update. Each variant writes only its own bit, so one
/// source can never clear another.
pub const SettingUpdate = union(enum) {
    on_battery: bool,
    battery_saver: bool,
    energy_saver: bool,
};

pub const HostVisibility = struct {
    visible: bool,
    cloaked: bool,
};

/// Called on the UI thread when DWM reports that one of our own top-level
/// windows was cloaked or uncloaked. Installed by the apprt, which owns the
/// HWND -> host mapping this module deliberately knows nothing about.
///
/// `cloaked` is the transition the event itself carried, and must be passed
/// through rather than discarded: it is the only recovery path when the
/// follow-up `DwmGetWindowAttribute` query fails. See `resolveCloaked`.
pub const CloakEventHandler = *const fn (hwnd: HWND, cloaked: bool) void;

/// All of the following are touched only from the UI/pump thread: hosts are
/// created and destroyed there, and `WINEVENT_OUTOFCONTEXT` callbacks are
/// delivered through that same thread's message queue. Plain (non-atomic)
/// state is therefore correct here; see `cloakWinEventProc`.
var cloak_handler: ?CloakEventHandler = null;
var cloak_hook: ?HANDLE = null;
var cloak_hook_refs: usize = 0;

/// Install (or clear) the cloak handler. Safe to call before any host exists;
/// events that arrive with no handler installed are dropped.
pub fn setCloakEventHandler(handler: ?CloakEventHandler) void {
    cloak_handler = handler;
}

/// Pure WinEvent filter. The hook range also carries events for accessible
/// child objects, which are not window cloak transitions and must be ignored.
pub fn isHostCloakEvent(event: DWORD, id_object: LONG, id_child: LONG) bool {
    if (event != EVENT_OBJECT_CLOAKED and event != EVENT_OBJECT_UNCLOAKED) return false;
    return id_object == OBJID_WINDOW and id_child == CHILDID_SELF;
}

fn cloakWinEventProc(
    hook: ?HANDLE,
    event: DWORD,
    hwnd: ?HWND,
    id_object: LONG,
    id_child: LONG,
    event_thread: DWORD,
    event_time_ms: DWORD,
) callconv(.winapi) void {
    _ = hook;
    _ = event_thread;
    _ = event_time_ms;
    if (!isHostCloakEvent(event, id_object, id_child)) return;
    const target = hwnd orelse return;
    const handler = cloak_handler orelse return;
    // The hook is registered WINEVENT_OUTOFCONTEXT and scoped to this
    // thread, so Windows delivers this from inside our own message pump.
    // We are on the UI thread and may touch host state directly; nothing
    // here may be moved to another thread.
    //
    // Forward WHICH transition fired. `isHostCloakEvent` has already
    // narrowed `event` to exactly one of the two.
    handler(target, event == EVENT_OBJECT_CLOAKED);
}

/// Reference-counted because one thread-scoped hook already covers every host
/// window on the pump thread; registering one per host would multiply every
/// callback by the window count.
fn acquireCloakHook() void {
    cloak_hook_refs += 1;
    if (cloak_hook != null or cloak_hook_refs != 1) return;
    cloak_hook = SetWinEventHook(
        EVENT_OBJECT_CLOAKED,
        EVENT_OBJECT_UNCLOAKED,
        null,
        cloakWinEventProc,
        sys.GetCurrentProcessId(),
        sys.GetCurrentThreadId(),
        WINEVENT_OUTOFCONTEXT,
    );
    if (cloak_hook == null) {
        // Degrade to the message-driven refreshes (WM_ACTIVATE,
        // WM_SHOWWINDOW, WM_WINDOWPOSCHANGED, WM_EXITSIZEMOVE) rather than
        // failing window creation.
        log.warn(
            "DWM cloak notifications unavailable err={}",
            .{windows.kernel32.GetLastError()},
        );
    }
}

fn releaseCloakHook() void {
    if (cloak_hook_refs == 0) return;
    cloak_hook_refs -= 1;
    if (cloak_hook_refs != 0) return;
    if (cloak_hook) |hook| {
        if (UnhookWinEvent(hook) == 0) {
            log.warn(
                "failed to unhook DWM cloak notifications err={}",
                .{windows.kernel32.GetLastError()},
            );
        }
        cloak_hook = null;
    }
}

/// Owns the power notification registrations and the shared cloak WinEvent
/// reference associated with one host HWND.
pub const Notifications = struct {
    acdc: ?HANDLE = null,
    saver: ?HANDLE = null,
    energy_saver: ?HANDLE = null,
    /// Guards against the second `deinit` (WM_DESTROY plus Host.deinit)
    /// dropping a reference twice, matching the handle fields' reset below.
    cloak_hook_held: bool = false,

    pub fn init(hwnd: HWND) Notifications {
        pollIfStale();
        acquireCloakHook();

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
            log.warn("battery-saver notifications unavailable err={}", .{windows.kernel32.GetLastError()});
        }

        // Expected to fail on Windows builds without Energy Saver. Battery
        // saver above still covers those, so this is not a warning.
        const energy_saver = RegisterPowerSettingNotification(
            @ptrCast(hwnd),
            &GUID_ENERGY_SAVER_STATUS,
            DEVICE_NOTIFY_WINDOW_HANDLE,
        );
        if (energy_saver == null) {
            log.debug("energy-saver notifications unavailable err={}", .{windows.kernel32.GetLastError()});
        }

        return .{
            .acdc = acdc,
            .saver = saver,
            .energy_saver = energy_saver,
            .cloak_hook_held = true,
        };
    }

    pub fn deinit(self: *Notifications) void {
        if (self.cloak_hook_held) releaseCloakHook();
        if (self.acdc) |handle| {
            if (UnregisterPowerSettingNotification(handle) == 0) {
                log.warn("failed to unregister AC/DC power notification err={}", .{windows.kernel32.GetLastError()});
            }
        }
        if (self.saver) |handle| {
            if (UnregisterPowerSettingNotification(handle) == 0) {
                log.warn("failed to unregister battery-saver notification err={}", .{windows.kernel32.GetLastError()});
            }
        }
        if (self.energy_saver) |handle| {
            if (UnregisterPowerSettingNotification(handle) == 0) {
                log.warn("failed to unregister energy-saver notification err={}", .{windows.kernel32.GetLastError()});
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
            0 => true,
            1 => false,
            // 255 is "unknown"; anything else is undocumented. Keep the last
            // known source rather than guessing. (The value 2 means
            // "short term / UPS" in the GUID_ACDC_POWER_SOURCE notification
            // payload, not here — see parsePowerSettingNotification.)
            else => previous.on_battery,
        },
        // SystemStatusFlag is the legacy Battery Saver indicator only.
        .battery_saver = raw.SystemStatusFlag == 1,
        // `GetSystemPowerStatus` has no Energy Saver field, so a poll must
        // carry the last notified value forward instead of clearing it.
        .energy_saver = previous.energy_saver,
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
        return .{ .battery_saver = switch (value) {
            0 => false,
            1 => true,
            else => return null,
        } };
    }
    if (std.mem.eql(u8, guid_bytes, std.mem.asBytes(&GUID_ENERGY_SAVER_STATUS))) {
        // Both saving modes throttle. STANDARD asks for savings where the
        // user-experience cost is minimal, which capping an unfocused or
        // idle terminal present rate satisfies.
        return .{ .energy_saver = switch (value) {
            ENERGY_SAVER_OFF => false,
            ENERGY_SAVER_STANDARD, ENERGY_SAVER_HIGH_SAVINGS => true,
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
    pollIfStaleWith(sys.GetTickCount64(), readSystemPowerStatus);
}

/// Reader indirection so the slot-accounting policy above can be tested
/// without a real `GetSystemPowerStatus`.
const PowerStatusReader = *const fn (status: *SYSTEM_POWER_STATUS) bool;

fn readSystemPowerStatus(status: *SYSTEM_POWER_STATUS) bool {
    return GetSystemPowerStatus(status) != 0;
}

fn pollIfStaleWith(now: u64, read: PowerStatusReader) void {
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

    // Claiming the slot up front keeps concurrent renderer threads from
    // stampeding the syscall, but a failed query should not cost us the
    // next 30 seconds of fallback, so hand the slot back on failure.
    const generation = push_generation.load(.acquire);
    var raw: SYSTEM_POWER_STATUS = undefined;
    if (!read(&raw)) {
        last_poll_tick_ms.store(previous, .release);
        return;
    }

    // A WM_POWERBROADCAST push that landed while we were inside the
    // syscall is strictly fresher than what we just read. Drop the poll
    // rather than overwrite it; the next poll or push corrects us anyway.
    publishPolledSnapshot(parseSystemPowerStatus(raw, snapshot()), generation);
}

/// Monotonic millisecond clock shared with Win32 notification and visibility
/// code. Renderer pacing uses this only when throttling is active.
pub fn tickCountMs() u64 {
    return sys.GetTickCount64();
}

/// Whether saver-specific pacing is active for the current configuration.
pub fn saverRenderingActive(mode: configpkg.PowerSaverRendering, state: Snapshot) bool {
    return switch (mode) {
        // `auto` follows Battery Saver OR Energy Saver, never plain battery.
        .auto => state.isSaver(),
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

/// Pure cloak-resolution policy.
///
/// `query` is the `DwmGetWindowAttribute(DWMWA_CLOAKED)` result, or `null`
/// when DWM could not answer. `observed` is the transition a WinEvent just
/// reported, or `null` for a refresh not driven by a cloak event.
///
/// Precedence, and why:
///
///  1. A successful query wins. It is the current truth and may be newer
///     than the event that triggered this refresh.
///  2. Otherwise the observed transition wins. Windows documents
///     EVENT_OBJECT_UNCLOAKED as being raised after the window has been
///     uncloaked, so the event is a valid statement about cloak state on its
///     own and does not need the query to succeed.
///  3. Only with neither do we preserve the previous value.
///
/// Rule 2 exists because falling back to `previous` on an UNCLOAKED event is
/// unrecoverable rather than merely stale: a preserved `cloaked = true`
/// leaves the host's surfaces hidden, hidden surfaces do no renderer work,
/// and no further cloak event is coming for a window that is already
/// uncloaked -- so nothing would ever re-query and the terminal stays frozen
/// until an unrelated window message happens to arrive. The failure mode of
/// guessing wrong in the other direction is bounded: a spuriously visible
/// host merely presents until the next refresh corrects it.
///
/// NOTE: this precedence is argued from the documented WinEvent contract and
/// from the code paths above, not from an observed repro. No desktop session
/// was available to this change; the covering test below exercises the
/// policy, not DWM itself.
pub fn resolveCloaked(query: ?bool, observed: ?bool, previous: bool) bool {
    return query orelse observed orelse previous;
}

/// Raw DWM cloak query. `null` means DWM could not answer transiently.
fn queryCloaked(hwnd: HWND) ?bool {
    var cloak_reason: DWORD = 0;
    const result = DwmGetWindowAttribute(
        hwnd,
        DWMWA_CLOAKED,
        &cloak_reason,
        @sizeOf(DWORD),
    );
    return if (result >= 0) cloak_reason != 0 else null;
}

/// Query host visibility. `observed_cloaked` carries the transition from a
/// cloak WinEvent when this refresh was triggered by one; see
/// `resolveCloaked` for how a failed DWM query is resolved.
pub fn queryHostVisibility(
    hwnd: HWND,
    previous_cloaked: bool,
    observed_cloaked: ?bool,
) HostVisibility {
    const cloaked = resolveCloaked(
        queryCloaked(hwnd),
        observed_cloaked,
        previous_cloaked,
    );
    return .{
        .visible = hostVisible(
            sys.IsWindowVisible(hwnd) != 0,
            sys.IsIconic(hwnd) != 0,
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
        @as(u8, @intFromBool(value.battery_saver)) * battery_saver_bit |
        @as(u8, @intFromBool(value.energy_saver)) * energy_saver_bit;
}

fn unpackSnapshot(bits: u8) Snapshot {
    return .{
        .on_battery = bits & on_battery_bit != 0,
        .battery_saver = bits & battery_saver_bit != 0,
        .energy_saver = bits & energy_saver_bit != 0,
    };
}

/// Publish a polled snapshot only if no notification landed since the caller
/// sampled `generation`.
///
/// A plain store guarded by a preceding generation load is NOT enough: a push
/// can bump the generation and complete its own update in the window between
/// that load and the store, and the full-byte store would then erase it. The
/// compare-exchange closes that window. `publishSetting` bumps the generation
/// BEFORE it mutates the byte, so any push whose write could land after ours
/// has already made the generation check below fail, and any push that lands
/// between our load and our exchange makes the exchange itself fail and sends
/// us back through that check.
fn publishPolledSnapshot(value: Snapshot, generation: u32) void {
    const next = packSnapshot(value);
    var current = snapshot_bits.load(.acquire);
    while (true) {
        if (push_generation.load(.acquire) != generation) return;
        if (current == next) return;
        current = snapshot_bits.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return;
    }
}

fn publishSetting(update: SettingUpdate) void {
    // Bump before the store so a poll that started earlier and is about to
    // publish observes the change and backs off. Bumping after would leave a
    // window where the poll sees the old generation and clobbers this update.
    _ = push_generation.fetchAdd(1, .acq_rel);

    var current = snapshot_bits.load(.acquire);
    while (true) {
        var next = current;
        switch (update) {
            .on_battery => |value| {
                if (value) next |= on_battery_bit else next &= ~on_battery_bit;
            },
            // Each source owns exactly one bit, so a read-modify-write here
            // leaves the other source untouched.
            .battery_saver => |value| {
                if (value) next |= battery_saver_bit else next &= ~battery_saver_bit;
            },
            .energy_saver => |value| {
                if (value) next |= energy_saver_bit else next &= ~energy_saver_bit;
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
    const previous: Snapshot = .{ .on_battery = true, .battery_saver = false };
    try std.testing.expectEqual(
        Snapshot{ .on_battery = false, .battery_saver = true },
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
        Snapshot{ .on_battery = true, .battery_saver = false },
        parseSystemPowerStatus(.{
            .ACLineStatus = 0xff,
            .BatteryFlag = 0xff,
            .BatteryLifePercent = 0xff,
            .SystemStatusFlag = 2,
            .BatteryLifeTime = 0xffff_ffff,
            .BatteryFullLifeTime = 0xffff_ffff,
        }, previous),
    );

    // `GetSystemPowerStatus` cannot see Energy Saver, so a poll must carry
    // the last notified value through rather than clearing it. Without this
    // the 30 s fallback poll would silently cancel Energy Saver pacing.
    try std.testing.expectEqual(
        Snapshot{ .on_battery = false, .battery_saver = false, .energy_saver = true },
        parseSystemPowerStatus(.{
            .ACLineStatus = 1,
            .BatteryFlag = 0,
            .BatteryLifePercent = 80,
            .SystemStatusFlag = 0,
            .BatteryLifeTime = 0,
            .BatteryFullLifeTime = 0,
        }, .{ .energy_saver = true }),
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
        SettingUpdate{ .battery_saver = false },
        parsePowerSettingNotification(&saver).?,
    );

    const saver_on = settingPayload(GUID_POWER_SAVING_STATUS, 1);
    try std.testing.expectEqual(
        SettingUpdate{ .battery_saver = true },
        parsePowerSettingNotification(&saver_on).?,
    );

    // Energy Saver (prerelease GUID) maps its three-state enum onto its OWN
    // flag: off is off, both savings modes throttle. It must not share a
    // field with Battery Saver above -- see the union test below.
    const energy_off = settingPayload(GUID_ENERGY_SAVER_STATUS, ENERGY_SAVER_OFF);
    try std.testing.expectEqual(
        SettingUpdate{ .energy_saver = false },
        parsePowerSettingNotification(&energy_off).?,
    );
    const energy_standard = settingPayload(GUID_ENERGY_SAVER_STATUS, ENERGY_SAVER_STANDARD);
    try std.testing.expectEqual(
        SettingUpdate{ .energy_saver = true },
        parsePowerSettingNotification(&energy_standard).?,
    );
    const energy_high = settingPayload(GUID_ENERGY_SAVER_STATUS, ENERGY_SAVER_HIGH_SAVINGS);
    try std.testing.expectEqual(
        SettingUpdate{ .energy_saver = true },
        parsePowerSettingNotification(&energy_high).?,
    );
    const energy_bogus = settingPayload(GUID_ENERGY_SAVER_STATUS, 7);
    try std.testing.expect(parsePowerSettingNotification(&energy_bogus) == null);

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
        .{ .on_battery = false },
        config,
    ));
    // Battery alone is NOT a saver trigger. `auto` is documented in
    // Config.zig ("Battery Saver is active, or ... Energy Saver is active")
    // and docs/windows.md as following the saver signals only, so an
    // unplugged laptop with saver off keeps its full cadence, focused or not.
    try std.testing.expectEqual(@as(?u64, 8), minimumPresentIntervalMs(
        true,
        true,
        .{ .on_battery = true },
        config,
    ));
    // 60 fps here so the expected value distinguishes the unfocused cap (17)
    // from saver pacing (34) instead of colliding with it at 30 fps.
    var sixty = config;
    sixty.unfocused_render_fps = 60;
    try std.testing.expectEqual(@as(?u64, 17), minimumPresentIntervalMs(
        false,
        true,
        .{ .on_battery = true },
        sixty,
    ));
    try std.testing.expect(!saverRenderingActive(.auto, .{ .on_battery = true }));
    // Either saver source alone drives `auto`.
    try std.testing.expect(saverRenderingActive(.auto, .{ .battery_saver = true }));
    try std.testing.expect(saverRenderingActive(.auto, .{ .energy_saver = true }));
    try std.testing.expectEqual(@as(?u64, null), minimumPresentIntervalMs(
        true,
        false,
        .{ .on_battery = true, .battery_saver = true },
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
        .{ .on_battery = true, .battery_saver = true },
        sixty_fps,
    ));
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        false,
        true,
        .{ .on_battery = true, .battery_saver = true },
        sixty_fps,
    ));
    // Energy Saver on AC power paces identically; the source does not matter
    // once either is set.
    try std.testing.expectEqual(@as(?u64, 34), minimumPresentIntervalMs(
        true,
        true,
        .{ .on_battery = false, .energy_saver = true },
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
        .{ .battery_saver = true, .energy_saver = true },
        forced,
    ));
}

test "power saver sources do not erase each other in either order" {
    resetPowerGlobalsForTest();
    defer resetPowerGlobalsForTest();

    // Battery Saver on, then Energy Saver reports OFF. Energy Saver was
    // never on; its "off" must not cancel Battery Saver's pacing.
    publishSetting(.{ .battery_saver = true });
    publishSetting(.{ .energy_saver = false });
    try std.testing.expectEqual(
        Snapshot{ .battery_saver = true, .energy_saver = false },
        snapshot(),
    );
    try std.testing.expect(snapshot().isSaver());
    try std.testing.expect(saverRenderingActive(.auto, snapshot()));

    // ...and the reverse ordering: Energy Saver on, then Battery Saver OFF.
    resetPowerGlobalsForTest();
    publishSetting(.{ .energy_saver = true });
    publishSetting(.{ .battery_saver = false });
    try std.testing.expectEqual(
        Snapshot{ .battery_saver = false, .energy_saver = true },
        snapshot(),
    );
    try std.testing.expect(snapshot().isSaver());
    try std.testing.expect(saverRenderingActive(.auto, snapshot()));

    // Both on, then only one clears: still saver.
    resetPowerGlobalsForTest();
    publishSetting(.{ .battery_saver = true });
    publishSetting(.{ .energy_saver = true });
    publishSetting(.{ .battery_saver = false });
    try std.testing.expect(snapshot().isSaver());

    // Only when the last remaining source clears does pacing release.
    publishSetting(.{ .energy_saver = false });
    try std.testing.expect(!snapshot().isSaver());

    // `on_battery` is not a saver source and never contributes.
    publishSetting(.{ .on_battery = true });
    try std.testing.expect(!snapshot().isSaver());
    try std.testing.expect(!saverRenderingActive(.auto, snapshot()));
}

fn resetPowerGlobalsForTest() void {
    last_poll_tick_ms.store(0, .release);
    snapshot_bits.store(0, .release);
    push_generation.store(0, .release);
}

test "power poll claims the 30 s slot only on a successful read" {
    const readers = struct {
        var calls: usize = 0;

        fn fail(status: *SYSTEM_POWER_STATUS) bool {
            calls += 1;
            status.* = std.mem.zeroes(SYSTEM_POWER_STATUS);
            return false;
        }

        fn ok(status: *SYSTEM_POWER_STATUS) bool {
            calls += 1;
            status.* = .{
                .ACLineStatus = 0,
                .BatteryFlag = 1,
                .BatteryLifePercent = 50,
                .SystemStatusFlag = 1,
                .BatteryLifeTime = 0,
                .BatteryFullLifeTime = 0,
            };
            return true;
        }
    };

    resetPowerGlobalsForTest();
    defer resetPowerGlobalsForTest();

    // A failed query must hand the slot back instead of costing the next
    // 30 seconds of fallback coverage.
    readers.calls = 0;
    pollIfStaleWith(1_000, readers.fail);
    try std.testing.expectEqual(@as(usize, 1), readers.calls);
    try std.testing.expectEqual(@as(u64, 0), last_poll_tick_ms.load(.acquire));

    // ...so the very next caller still gets to poll.
    readers.calls = 0;
    pollIfStaleWith(1_001, readers.ok);
    try std.testing.expectEqual(@as(usize, 1), readers.calls);
    try std.testing.expectEqual(@as(u64, 1_001), last_poll_tick_ms.load(.acquire));
    try std.testing.expectEqual(
        Snapshot{ .on_battery = true, .battery_saver = true },
        snapshot(),
    );

    // A successful query does hold the slot for the whole interval.
    readers.calls = 0;
    pollIfStaleWith(1_002, readers.ok);
    try std.testing.expectEqual(@as(usize, 0), readers.calls);
    pollIfStaleWith(1_001 + POLL_INTERVAL_MS, readers.ok);
    try std.testing.expectEqual(@as(usize, 1), readers.calls);
}

test "power poll publication yields to a notification that raced it" {
    resetPowerGlobalsForTest();
    defer resetPowerGlobalsForTest();

    // The push lands while the poll is still inside the status syscall: it
    // bumps the generation and wins the byte, and the poll must not undo it.
    const raced = push_generation.load(.acquire);
    publishSetting(.{ .battery_saver = true });
    publishPolledSnapshot(.{ .on_battery = true, .battery_saver = false }, raced);
    try std.testing.expectEqual(
        Snapshot{ .on_battery = false, .battery_saver = true },
        snapshot(),
    );

    // With no racing push the poll publishes normally.
    const quiet = push_generation.load(.acquire);
    publishPolledSnapshot(.{ .on_battery = true, .battery_saver = false }, quiet);
    try std.testing.expectEqual(
        Snapshot{ .on_battery = true, .battery_saver = false },
        snapshot(),
    );

    // Widening the snapshot to a third bit must not have broken the CAS: an
    // Energy Saver push still wins the byte against a stale poll that only
    // knows about the two GetSystemPowerStatus-visible fields.
    const raced_energy = push_generation.load(.acquire);
    publishSetting(.{ .energy_saver = true });
    publishPolledSnapshot(.{ .on_battery = true, .battery_saver = true }, raced_energy);
    try std.testing.expectEqual(
        Snapshot{ .on_battery = true, .battery_saver = false, .energy_saver = true },
        snapshot(),
    );
}

test "power cloak resolution recovers from a failed query on uncloak" {
    // The window was cloaked; DWM then raises EVENT_OBJECT_UNCLOAKED but the
    // follow-up DwmGetWindowAttribute query fails. Preserving `previous`
    // here is unrecoverable -- hidden surfaces do no renderer work and no
    // second uncloak event is coming -- so the observed transition wins.
    try std.testing.expectEqual(false, resolveCloaked(null, false, true));
    try std.testing.expect(hostVisible(true, false, resolveCloaked(null, false, true)));

    // The symmetric case: a failed query on CLOAKED adopts cloaked. This
    // direction is safe either way (a stale visible host merely presents
    // until the next refresh), but the event is still the better answer.
    try std.testing.expectEqual(true, resolveCloaked(null, true, false));

    // A successful query is the current truth and outranks the event that
    // triggered the refresh, including when they disagree because the window
    // was re-cloaked between the two.
    try std.testing.expectEqual(true, resolveCloaked(true, false, false));
    try std.testing.expectEqual(false, resolveCloaked(false, true, true));

    // Message-driven refreshes observe no transition. With a working query
    // they follow it; with a failed query they preserve the last known value,
    // which is the pre-existing behaviour and stays correct because some
    // other window message will drive the next refresh.
    try std.testing.expectEqual(true, resolveCloaked(true, null, false));
    try std.testing.expectEqual(false, resolveCloaked(false, null, true));
    try std.testing.expectEqual(true, resolveCloaked(null, null, true));
    try std.testing.expectEqual(false, resolveCloaked(null, null, false));
}

test "power cloak winevent filter accepts only window-level cloak transitions" {
    try std.testing.expect(isHostCloakEvent(EVENT_OBJECT_CLOAKED, OBJID_WINDOW, CHILDID_SELF));
    try std.testing.expect(isHostCloakEvent(EVENT_OBJECT_UNCLOAKED, OBJID_WINDOW, CHILDID_SELF));
    // Accessible child/sub-objects share the hooked event range.
    try std.testing.expect(!isHostCloakEvent(EVENT_OBJECT_UNCLOAKED, OBJID_WINDOW, 3));
    try std.testing.expect(!isHostCloakEvent(EVENT_OBJECT_CLOAKED, -4, CHILDID_SELF));
    // Neighbouring EVENT_OBJECT_* values must not refresh visibility.
    try std.testing.expect(!isHostCloakEvent(EVENT_OBJECT_CLOAKED - 1, OBJID_WINDOW, CHILDID_SELF));
    try std.testing.expect(!isHostCloakEvent(EVENT_OBJECT_UNCLOAKED + 1, OBJID_WINDOW, CHILDID_SELF));
}

test "power visibility policy rejects hidden minimized and cloaked hosts" {
    try std.testing.expect(hostVisible(true, false, false));
    try std.testing.expect(!hostVisible(false, false, false));
    try std.testing.expect(!hostVisible(true, true, false));
    try std.testing.expect(!hostVisible(true, false, true));
    try std.testing.expect(!hostVisible(true, true, true));
}
