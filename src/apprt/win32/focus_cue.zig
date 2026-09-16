//! Keyboard-versus-pointer focus cue policy for owner-drawn chrome.
//!
//! Windows shows a focus rectangle on a native control only while the
//! user is navigating with the keyboard: `WM_UPDATEUISTATE` carries
//! `UISF_HIDEFOCUS` until the first Tab or arrow key, and a mouse click
//! sets it again. Owner-drawn controls opt out of that machinery -- they
//! paint whatever they like on `ODS_FOCUS` -- so every button in this
//! runtime drew its ring the moment it held focus, including the tab that
//! was just clicked and the `[▾]` button whose menu was just dismissed.
//! A ring that follows the pointer is not a focus cue; it is chrome the
//! user did not ask for.
//!
//! This module is the pure decision. The host and the settings window
//! own an `InputMode` each, flip it from the messages they already
//! receive, and consult `showRing` where they paint.

const std = @import("std");

/// How the user last reached a control.
pub const InputMode = enum {
    /// The last input was a pointer press: rings stay hidden.
    pointer,
    /// The last input was a navigation key: rings show on the focused
    /// control.
    keyboard,
};

/// Whether a focused, enabled, owner-drawn control should paint its
/// focus ring.
///
/// High Contrast bypasses the pointer gate. Its users rely on the ring as
/// the only affordance that reads at all, and the system's own controls
/// keep it visible there too.
pub fn showRing(focused: bool, disabled: bool, mode: InputMode, high_contrast: bool) bool {
    if (!focused or disabled) return false;
    if (high_contrast) return true;
    return mode == .keyboard;
}

/// Whether a key that just arrived counts as navigation for the purpose
/// of revealing rings. Character keys do not: typing into the palette
/// query must not light the Close button next to it. The tab strip's own
/// verbs count too: Delete closes the focused tab and moves focus to its
/// neighbour, F2 renames it, Apps opens the overview, and each leaves
/// keyboard focus on a control the user has to be able to find.
pub fn keyRevealsRing(vk: u32) bool {
    return switch (vk) {
        vk_tab, vk_return, vk_space, vk_escape => true,
        vk_prior, vk_next, vk_end, vk_home => true,
        vk_left, vk_up, vk_right, vk_down => true,
        vk_delete, vk_f2, vk_f6, vk_apps => true,
        else => false,
    };
}

pub const vk_tab: u32 = 0x09;
pub const vk_return: u32 = 0x0D;
pub const vk_escape: u32 = 0x1B;
pub const vk_space: u32 = 0x20;
pub const vk_prior: u32 = 0x21;
pub const vk_next: u32 = 0x22;
pub const vk_end: u32 = 0x23;
pub const vk_home: u32 = 0x24;
pub const vk_left: u32 = 0x25;
pub const vk_up: u32 = 0x26;
pub const vk_right: u32 = 0x27;
pub const vk_down: u32 = 0x28;
pub const vk_delete: u32 = 0x2E;
pub const vk_apps: u32 = 0x5D;
pub const vk_f2: u32 = 0x71;
pub const vk_f6: u32 = 0x75;

test "focus cue rings follow keyboard input, not the pointer" {
    try std.testing.expect(showRing(true, false, .keyboard, false));
    try std.testing.expect(!showRing(true, false, .pointer, false));
    // Unfocused or disabled controls never ring in any mode.
    try std.testing.expect(!showRing(false, false, .keyboard, false));
    try std.testing.expect(!showRing(true, true, .keyboard, false));
    try std.testing.expect(!showRing(false, false, .pointer, true));
}

test "focus cue high contrast keeps the ring on pointer focus" {
    try std.testing.expect(showRing(true, false, .pointer, true));
    try std.testing.expect(!showRing(true, true, .pointer, true));
}

test "focus cue navigation keys reveal rings and text keys do not" {
    try std.testing.expect(keyRevealsRing(vk_tab));
    try std.testing.expect(keyRevealsRing(vk_f6));
    try std.testing.expect(keyRevealsRing(vk_left));
    try std.testing.expect(keyRevealsRing(vk_return));
    try std.testing.expect(keyRevealsRing(vk_delete));
    try std.testing.expect(keyRevealsRing(vk_f2));
    try std.testing.expect(keyRevealsRing(vk_apps));
    try std.testing.expect(!keyRevealsRing('a'));
    try std.testing.expect(!keyRevealsRing(0x10)); // VK_SHIFT
    try std.testing.expect(!keyRevealsRing(0x11)); // VK_CONTROL
}
