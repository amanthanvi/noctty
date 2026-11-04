//! Which profile the app picks, and where it opens: the profile a stored key
//! names (a pane's launch key, a palette row's, an elevated window's, a
//! quick slot's pin), the one text typed in the picker names, where the
//! picker starts, which profile each quick slot opens, and the tab, window or
//! split it opens in. Keys, a `new_window_elevated:<key>` binding's included,
//! are compared by `windows_shell.profileKeyEquals` (a pin by
//! `storedProfileKeyEquals`); a reference written in the config is read by
//! `windows_shell.referenceProfileIndex` instead. Look keys up in the whole
//! list (`Host.profiles`), so a hidden profile still resolves; the picker,
//! the typed text and the quick slots read the shown ones
//! (`Host.shownProfiles`). Nothing here touches a window.
const std = @import("std");
const windows_shell = @import("../../config/windows_shell.zig");

/// Where a picked profile opens.
pub const OpenTarget = enum {
    tab,
    window,
    split,

    /// The target a name such as `NOCTTY_WIN32_DEFAULT_PROFILE_TARGET`'s
    /// names, in any case: `tab`, `window` or `win`, `split` or `pane`.
    pub fn parse(raw: []const u8) ?OpenTarget {
        if (std.ascii.eqlIgnoreCase(raw, "tab")) return .tab;
        if (std.ascii.eqlIgnoreCase(raw, "window") or std.ascii.eqlIgnoreCase(raw, "win")) return .window;
        if (std.ascii.eqlIgnoreCase(raw, "split") or std.ascii.eqlIgnoreCase(raw, "pane")) return .split;
        return null;
    }

    /// Where Enter opens the pick: Ctrl+Enter in a split, Shift+Enter in a
    /// window, else this target.
    pub fn withModifiers(self: OpenTarget, shift: bool, control: bool) OpenTarget {
        if (control) return .split;
        if (shift) return .window;
        return self;
    }

    /// The target after this one in the target button's order (tab, window,
    /// split, then tab again), or before it when `reverse`.
    pub fn cycle(self: OpenTarget, reverse: bool) OpenTarget {
        return switch (self) {
            .tab => if (reverse) .split else .window,
            .window => if (reverse) .tab else .split,
            .split => if (reverse) .window else .tab,
        };
    }
};

/// The quick slots a picker shows (Alt+1 to Alt+3), and so the pins the app
/// keeps for them (`App.launcher_quick_slot_keys`, Alt+Shift+1 to 3).
pub const quick_slots = 3;

/// What typed text names.
const Selection = union(enum) {
    exact: usize,
    /// How many profiles the text starts.
    ambiguous: usize,
    invalid,
};

/// What the picker starts from, in the order `preferred` tries it.
const Preference = struct {
    /// The profile chosen last in this window.
    window_key: ?[]const u8 = null,
    /// The profile chosen last in any window, tried only when this window
    /// has chosen none.
    app_key: ?[]const u8 = null,
    /// `default-profile`'s profile, as the config load resolved it.
    default_key: ?[]const u8 = null,
    /// `NOCTTY_WIN32_DEFAULT_PROFILE`, read as typed text.
    hint: ?[]const u8 = null,
    /// The place an empty hint names.
    fallback: usize = 0,
};

/// The profile `key` names.
pub fn byKey(profiles: []const windows_shell.Profile, key: []const u8) ?usize {
    for (profiles, 0..) |profile, index| {
        if (windows_shell.profileKeyEquals(profile, key)) return index;
    }
    return null;
}

/// The quick slot pinned to `key`.
pub fn pinByKey(pins: []const ?[:0]const u8, key: []const u8) ?usize {
    for (pins, 0..) |pin, index| {
        if (pin) |value| {
            if (windows_shell.storedProfileKeyEquals(value, key)) return index;
        }
    }
    return null;
}

/// What `typed` names: no text the profile at `fallback` (the last when it
/// is past the end), a number the profile at that place counted from 1,
/// else the first profile whose key (`profileKeyEquals`) or label (an SSH
/// profile's exactly, another's in any case) is the text, else the one
/// profile whose key or label starts with it in any case.
pub fn byTyped(profiles: []const windows_shell.Profile, typed: []const u8, fallback: usize) Selection {
    if (profiles.len == 0) return .invalid;
    const clamped = @min(fallback, profiles.len - 1);
    if (typed.len == 0) return .{ .exact = clamped };

    const requested = std.fmt.parseUnsigned(usize, typed, 10) catch null;
    if (requested) |value| {
        if (value == 0 or value > profiles.len) return .invalid;
        return .{ .exact = value - 1 };
    }

    var exact_match: ?usize = null;
    var unique_match: ?usize = null;
    var match_count: usize = 0;
    for (profiles, 0..) |profile, index| {
        const label_matches = if (profile.kind == .ssh)
            std.mem.eql(u8, profile.label, typed)
        else
            std.ascii.eqlIgnoreCase(profile.label, typed);
        if (windows_shell.profileKeyEquals(profile, typed) or label_matches) {
            exact_match = index;
            break;
        }
        if (std.ascii.startsWithIgnoreCase(profile.key, typed) or
            std.ascii.startsWithIgnoreCase(profile.label, typed))
        {
            unique_match = index;
            match_count += 1;
        }
    }
    if (exact_match) |index| return .{ .exact = index };
    if (match_count == 1) return .{ .exact = unique_match.? };
    if (match_count > 1) return .{ .ambiguous = match_count };
    return .invalid;
}

/// Where the picker starts in `profiles` (the shown ones): the profile
/// `window_key` names (`app_key` when it is null), else `default_key`'s,
/// else the one `hint` names. Null when none of them is listed;
/// `Host.selectPreferredProfile` then takes the automatic default's shell
/// or keeps its place. Host asks for the chosen keys and for the rest
/// apart, because only a choice the user made is stored as the selection.
pub fn preferred(profiles: []const windows_shell.Profile, pref: Preference) ?usize {
    if (pref.window_key orelse pref.app_key) |key| {
        if (byKey(profiles, key)) |index| return index;
    }
    if (pref.default_key) |key| {
        if (byKey(profiles, key)) |index| return index;
    }
    const hint = pref.hint orelse return null;
    return switch (byTyped(profiles, hint, pref.fallback)) {
        .exact => |index| index,
        .ambiguous, .invalid => null,
    };
}

/// The place in the shown profiles that quick slot `ordinal` (from 0)
/// opens: the list in order with the `selected` profile left out, so
/// `ordinal` itself, or the place after it when the selected profile is at
/// or before it. The pinned profiles are first because
/// `App.applyLauncherQuickSlotPreferences` moved them there.
pub fn quickSlot(profiles_len: usize, selected: ?usize, ordinal: usize) ?usize {
    if (ordinal >= quick_slots) return null;
    const index = ordinal + @intFromBool(selected != null and selected.? <= ordinal);
    return if (index < profiles_len) index else null;
}

test "win32 a key names its profile in any case, an SSH profile's only exactly" {
    var profiles = [_]windows_shell.Profile{
        .{
            .kind = .cmd,
            .key = "cmd.exe",
            .label = "Command Prompt",
            .command = .{ .shell = "cmd.exe" },
        },
        .{
            .kind = .wsl_distro,
            .key = "wsl:Ubuntu",
            .label = "Ubuntu",
            .command = .{ .shell = "wsl.exe" },
        },
        .{
            .kind = .ssh,
            .key = "ssh:PROD",
            .label = "SSH: PROD",
            .command = .{ .shell = "ssh.exe PROD" },
        },
        .{
            .kind = .ssh,
            .key = "ssh:prod",
            .label = "SSH: prod",
            .command = .{ .shell = "ssh.exe prod" },
        },
    };

    try std.testing.expectEqual(@as(?usize, 1), byKey(&profiles, "wsl:Ubuntu"));
    try std.testing.expectEqual(@as(?usize, 1), byKey(&profiles, "WSL:UBUNTU"));
    try std.testing.expectEqual(@as(?usize, 2), byKey(&profiles, "ssh:PROD"));
    try std.testing.expectEqual(@as(?usize, 3), byKey(&profiles, "ssh:prod"));
    try std.testing.expectEqual(@as(?usize, null), byKey(&profiles, "SSH:prod"));
    try std.testing.expectEqual(@as(?usize, null), byKey(&profiles, "missing"));
}

/// The profiles the two `preferred` tests pick from.
const test_shells = [_]windows_shell.Profile{
    .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{"pwsh.exe"} } },
    .{ .kind = .git_bash, .key = "git-bash", .label = "Git Bash", .command = .{ .direct = &.{"bash.exe"} } },
    .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{"cmd.exe"} } },
};

test "win32 the picker starts on this window's choice, then the app's, then the hint" {
    try std.testing.expectEqual(@as(?usize, 1), preferred(&test_shells, .{ .window_key = "git-bash", .hint = "cmd" }));
    try std.testing.expectEqual(@as(?usize, 2), preferred(&test_shells, .{ .app_key = "cmd.exe", .hint = "pwsh" }));
    try std.testing.expectEqual(@as(?usize, 0), preferred(&test_shells, .{ .hint = "power", .fallback = 2 }));
    try std.testing.expectEqual(@as(?usize, null), preferred(&test_shells, .{ .hint = "definitely_not_real", .fallback = 1 }));
    // A choice this window made that the list lacks is not the app's.
    try std.testing.expectEqual(@as(?usize, 0), preferred(&test_shells, .{ .window_key = "gone", .app_key = "cmd.exe", .hint = "pwsh" }));
}

test "win32 the picker starts on default-profile after a choice and before the hint" {
    // `default-profile` comes after a choice the user made and before the
    // `NOCTTY_WIN32_DEFAULT_PROFILE` hint, in any case of its key.
    try std.testing.expectEqual(@as(?usize, 1), preferred(&test_shells, .{ .default_key = "GIT-BASH", .hint = "cmd" }));
    try std.testing.expectEqual(@as(?usize, 2), preferred(&test_shells, .{ .window_key = "cmd.exe", .default_key = "git-bash", .hint = "pwsh" }));
    try std.testing.expectEqual(@as(?usize, 0), preferred(&test_shells, .{ .app_key = "pwsh.exe", .default_key = "git-bash", .fallback = 1 }));
    // One the list does not show (hidden, or gone) leaves the hint.
    try std.testing.expectEqual(@as(?usize, 2), preferred(&test_shells, .{ .default_key = "user:gone", .hint = "cmd" }));
    try std.testing.expectEqual(@as(?usize, null), preferred(&test_shells, .{ .default_key = "user:gone" }));
}

test "win32 typed text picks a profile by place, key, label or a unique prefix" {
    const profiles = [_]windows_shell.Profile{
        .{
            .kind = .pwsh,
            .key = "pwsh.exe",
            .label = "PowerShell",
            .command = .{ .direct = &.{"pwsh.exe"} },
        },
        .{
            .kind = .wsl_distro,
            .key = "Ubuntu",
            .label = "WSL: Ubuntu",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu", "~" } },
        },
        .{
            .kind = .wsl_distro,
            .key = "Ubuntu-Preview",
            .label = "WSL: Ubuntu Preview",
            .command = .{ .direct = &.{ "wsl.exe", "-d", "Ubuntu-Preview", "~" } },
        },
    };

    try std.testing.expectEqualDeep(Selection{ .exact = 0 }, byTyped(&profiles, "", 0));
    try std.testing.expectEqualDeep(Selection{ .exact = 1 }, byTyped(&profiles, "2", 0));
    try std.testing.expectEqualDeep(Selection{ .exact = 0 }, byTyped(&profiles, "powers", 1));
    try std.testing.expectEqualDeep(Selection{ .ambiguous = 2 }, byTyped(&profiles, "ubu", 0));
    try std.testing.expectEqualDeep(Selection.invalid, byTyped(&profiles, "9", 0));
}

test "win32 quick slots skip the selected profile and keep the list's order" {
    try std.testing.expectEqual(@as(?usize, 1), quickSlot(5, 0, 0));
    try std.testing.expectEqual(@as(?usize, 2), quickSlot(5, 0, 1));
    try std.testing.expectEqual(@as(?usize, 3), quickSlot(5, 0, 2));
    try std.testing.expectEqual(@as(?usize, 0), quickSlot(5, 3, 0));
    try std.testing.expectEqual(@as(?usize, 1), quickSlot(5, 3, 1));
    try std.testing.expectEqual(@as(?usize, 2), quickSlot(5, 3, 2));
    try std.testing.expectEqual(@as(?usize, null), quickSlot(1, 0, 0));
    // Three slots, however long the list.
    try std.testing.expectEqual(@as(?usize, null), quickSlot(5, null, 3));
}

test "win32 a pinned key finds its quick slot in any case, an ssh: key only exactly" {
    try std.testing.expectEqual(@as(?usize, 0), pinByKey(&.{ "git-bash", "cmd.exe", null }, "git-bash"));
    try std.testing.expectEqual(@as(?usize, 1), pinByKey(&.{ "git-bash", "cmd.exe", null }, "CMD.EXE"));
    try std.testing.expectEqual(@as(?usize, null), pinByKey(&.{ "git-bash", "cmd.exe", null }, "pwsh.exe"));
    try std.testing.expectEqual(@as(?usize, 2), pinByKey(&.{ null, "cmd.exe", "ssh:prod" }, "ssh:prod"));
    try std.testing.expectEqual(@as(?usize, null), pinByKey(&.{ null, "cmd.exe", "ssh:prod" }, "SSH:prod"));
    try std.testing.expectEqual(@as(?usize, null), pinByKey(&.{ null, "cmd.exe", "ssh:prod" }, "ssh:PROD"));
}

test "win32 Enter opens a pick in a split with Ctrl, else in a window with Shift" {
    try std.testing.expectEqual(OpenTarget.tab, OpenTarget.tab.withModifiers(false, false));
    try std.testing.expectEqual(OpenTarget.window, OpenTarget.tab.withModifiers(true, false));
    try std.testing.expectEqual(OpenTarget.split, OpenTarget.tab.withModifiers(false, true));
    try std.testing.expectEqual(OpenTarget.split, OpenTarget.window.withModifiers(true, true));
}

test "win32 the target button cycles tab, window and split both ways" {
    try std.testing.expectEqual(OpenTarget.window, OpenTarget.tab.cycle(false));
    try std.testing.expectEqual(OpenTarget.split, OpenTarget.window.cycle(false));
    try std.testing.expectEqual(OpenTarget.tab, OpenTarget.split.cycle(false));
    try std.testing.expectEqual(OpenTarget.split, OpenTarget.tab.cycle(true));
    try std.testing.expectEqual(OpenTarget.tab, OpenTarget.window.cycle(true));
    try std.testing.expectEqual(OpenTarget.window, OpenTarget.split.cycle(true));
}

test "win32 a launch target is read by name in any case, win for a window and pane for a split" {
    // Optionals, not `.?`: a null would end the test binary, not this test.
    try std.testing.expectEqual(@as(?OpenTarget, .tab), OpenTarget.parse("tab"));
    try std.testing.expectEqual(@as(?OpenTarget, .window), OpenTarget.parse("window"));
    try std.testing.expectEqual(@as(?OpenTarget, .window), OpenTarget.parse("win"));
    try std.testing.expectEqual(@as(?OpenTarget, .split), OpenTarget.parse("split"));
    try std.testing.expectEqual(@as(?OpenTarget, .split), OpenTarget.parse("pane"));
    try std.testing.expectEqual(@as(?OpenTarget, .split), OpenTarget.parse("PANE"));
    try std.testing.expectEqual(@as(?OpenTarget, null), OpenTarget.parse("definitely_not_real"));
}
