//! The color scheme Windows reports for apps (Settings > Personalization >
//! Colors > Choose your mode), read from the registry.
//!
//! The app and the command line actions share this lookup, because both
//! build the configuration the same way: it is loaded in the light
//! conditional state, and `Config.changeConditionalState` then applies the
//! scheme Windows reports. A `theme = light:A,dark:B` file can set any key, so
//! a config that skips that step can differ from the app's. The lookup only
//! reads: it creates no window and starts no COM.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const Scheme = enum { light, dark };

/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`,
/// `AppsUseLightTheme`: 0 is dark, anything else light. A value that is
/// missing or unreadable is dark, as the app has always taken it.
pub fn apps() Scheme {
    if (comptime builtin.os.tag != .windows) return .light;
    return schemeOf(readAppsUseLightTheme());
}

pub fn isDark() bool {
    return apps() == .dark;
}

/// The scheme a value of `AppsUseLightTheme` means; null is a value that
/// could not be read.
fn schemeOf(value: ?u32) Scheme {
    const data = value orelse return .dark;
    return if (data == 0) .dark else .light;
}

fn readAppsUseLightTheme() ?u32 {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
    const value_name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: windows.HKEY = undefined;
    if (windows.advapi32.RegOpenKeyExW(windows.HKEY_CURRENT_USER, subkey, 0, windows.KEY_READ, &hkey) != 0) return null;
    defer _ = windows.advapi32.RegCloseKey(hkey);

    var data: u32 = 0;
    var data_size: windows.DWORD = @sizeOf(u32);
    var reg_type: windows.DWORD = 0;
    if (windows.advapi32.RegQueryValueExW(hkey, value_name, null, &reg_type, @ptrCast(&data), &data_size) != 0) return null;
    if (reg_type != windows.REG.DWORD or data_size != @sizeOf(u32)) return null;
    return data;
}

test "AppsUseLightTheme 0 is dark, any other value light, and a value that cannot be read is dark" {
    const testing = std.testing;
    try testing.expectEqual(Scheme.dark, schemeOf(0));
    try testing.expectEqual(Scheme.light, schemeOf(1));
    try testing.expectEqual(Scheme.light, schemeOf(2));
    try testing.expectEqual(Scheme.dark, schemeOf(null));
}

test "the registry lookup answers without a window or COM" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // Either answer is right on a given machine; the call must return one.
    const scheme = apps();
    try std.testing.expectEqual(scheme == .dark, isDark());
}
