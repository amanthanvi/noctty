const std = @import("std");
const builtin = @import("builtin");

const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const input = @import("../../input.zig");

const sys = @import("sys.zig");
const c = @import("consts.zig");

const windows = std.os.windows;
const UINT = sys.UINT;
const WPARAM = sys.WPARAM;
const LPARAM = sys.LPARAM;

pub const SystemWheelSettings = struct {
    lines: u32 = 3,
    chars: u32 = 3,
};

const MouseWheelAxis = enum {
    horizontal,
    vertical,
};

pub const WheelNormalizationContext = struct {
    settings: SystemWheelSettings = .{},
    cell_size: apprt.action.CellSize = .{ .width = 0, .height = 0 },
    viewport: apprt.SurfaceSize = .{ .width = 0, .height = 0 },
};

pub const NormalizedWheelScroll = struct {
    xoff: f64 = 0,
    yoff: f64 = 0,
    mods: input.ScrollMods = .{},
};

pub const GlobalHotkeySpec = struct {
    modifiers: UINT,
    vk: UINT,
};

pub const RegisteredGlobalHotkey = struct {
    id: i32,
    trigger: input.Binding.Trigger,
    spec: GlobalHotkeySpec,
    binding: *const input.Binding.Set.Value,
};

/// `ToUnicode` is given a four-unit buffer, so the most text one key can
/// produce is four BMP characters (12 bytes of UTF-8) or two supplementary
/// ones (8 bytes). 16 bytes covers either.
const text_capacity = 16;

const KeyText = struct {
    /// UTF-8 for every code unit the layout produced for this key, not just
    /// the first one: an accent that cannot combine with the key that
    /// follows it yields both characters in one translation.
    utf8: [text_capacity]u8 = [_]u8{0} ** text_capacity,
    len: usize = 0,
    consumed_mods: input.Mods = .{},
    unshifted_codepoint: u21 = 0,
    deferred_utf16_units: usize = 0,
    /// The layout reported a dead key. There is no text yet; the composed
    /// character arrives with the next key.
    dead_key: bool = false,
};

pub const DeferredCharState = struct {
    pending_units: usize = 0,
    high_surrogate: ?u16 = null,

    pub fn authorize(self: *DeferredCharState, expected_units: usize) void {
        self.pending_units = self.pending_units +| expected_units;
    }

    pub fn clear(self: *DeferredCharState) void {
        self.* = .{};
    }

    pub fn consumeDeadChar(self: *DeferredCharState) void {
        if (self.pending_units > 0) self.pending_units -= 1;
        self.high_surrogate = null;
    }

    pub fn consumeCodeUnit(
        self: *DeferredCharState,
        code_unit: u16,
        ime_composing: bool,
    ) ?u21 {
        if (ime_composing) {
            self.clear();
            return null;
        }
        if (self.pending_units == 0) {
            self.high_surrogate = null;
            return null;
        }
        self.pending_units -= 1;

        if (self.high_surrogate) |high| {
            if (!std.unicode.utf16IsLowSurrogate(code_unit)) {
                self.clear();
                return null;
            }
            const codepoint = std.unicode.utf16DecodeSurrogatePair(
                &.{ high, code_unit },
            ) catch {
                self.clear();
                return null;
            };
            self.high_surrogate = null;
            return codepoint;
        }

        if (std.unicode.utf16IsHighSurrogate(code_unit)) {
            self.high_surrogate = code_unit;
            return null;
        }
        if (std.unicode.utf16IsLowSurrogate(code_unit)) {
            self.clear();
            return null;
        }

        return code_unit;
    }
};

pub const Win32KeyMessage = struct {
    event: input.KeyEvent,
    deferred_utf16_units: usize = 0,

    /// Translated key text travels inline, not as a slice. `event.utf8` is a
    /// borrowed slice and `keyEventFromWin32Message` returns its message by
    /// value, so a slice into the `KeyText` local it translated from dangles
    /// the instant it returns. The bytes are carried here instead and the
    /// slice is rebased by `bindText` once the value has landed in the frame
    /// that actually uses it.
    text: [text_capacity]u8 = [_]u8{0} ** text_capacity,
    text_len: usize = 0,

    /// Point `event.utf8` at this value's own storage. Must be called on the
    /// caller's copy, after the message has been returned, and that copy must
    /// outlive every use of `event.utf8`.
    pub fn bindText(self: *Win32KeyMessage) void {
        self.event.utf8 = self.text[0..self.text_len];
    }
};

pub fn lParamBits(lParam: LPARAM) usize {
    return @as(usize, @bitCast(lParam));
}

pub fn highWord(value: usize) u16 {
    return @truncate((value >> 16) & 0xFFFF);
}

fn scanCodeFromLParam(lParam: LPARAM) u32 {
    return @as(u32, highWord(lParamBits(lParam))) & 0xFF;
}

fn isExtendedKey(lParam: LPARAM) bool {
    return (lParamBits(lParam) & c.KF_EXTENDED) != 0;
}

fn isRepeatedKey(lParam: LPARAM) bool {
    return (lParamBits(lParam) & c.KF_REPEAT) != 0;
}

pub fn readSystemWheelSetting(action: UINT, fallback: u32) u32 {
    var value: UINT = fallback;
    if (sys.SystemParametersInfoW(action, 0, @ptrCast(&value), 0) == 0) {
        return fallback;
    }
    return value;
}

pub fn wheelDeltaFromWParam(wParam: WPARAM) i16 {
    const bits = @as(usize, @intCast(wParam));
    return @bitCast(highWord(bits));
}

fn wheelSettingForAxis(settings: SystemWheelSettings, axis: MouseWheelAxis) u32 {
    return switch (axis) {
        .vertical => settings.lines,
        .horizontal => settings.chars,
    };
}

fn wheelUnitSize(ctx: WheelNormalizationContext, axis: MouseWheelAxis) f64 {
    const dim: u32 = switch (axis) {
        .vertical => ctx.cell_size.height,
        .horizontal => ctx.cell_size.width,
    };
    return @floatFromInt(@max(dim, 1));
}

fn wheelViewportSize(ctx: WheelNormalizationContext, axis: MouseWheelAxis) f64 {
    const dim: u32 = switch (axis) {
        .vertical => ctx.viewport.height,
        .horizontal => ctx.viewport.width,
    };
    const viewport: f64 = @floatFromInt(@max(dim, 1));
    const unit = wheelUnitSize(ctx, axis);
    return @max(unit, viewport - unit);
}

pub fn normalizeWheelDelta(
    ctx: WheelNormalizationContext,
    axis: MouseWheelAxis,
    delta: i16,
) NormalizedWheelScroll {
    if (delta == 0) return .{};

    const precision = @rem(delta, c.WHEEL_DELTA) != 0;
    const notch_delta = @as(f64, @floatFromInt(delta)) / c.WHEEL_DELTA;
    const pixels = if (precision)
        notch_delta * wheelUnitSize(ctx, axis)
    else discrete: {
        const setting = wheelSettingForAxis(ctx.settings, axis);
        if (setting == 0) return .{};

        break :discrete if (setting == c.WHEEL_PAGESCROLL)
            notch_delta * wheelViewportSize(ctx, axis)
        else
            notch_delta * @as(f64, @floatFromInt(setting)) * wheelUnitSize(ctx, axis);
    };

    return switch (axis) {
        .vertical => .{
            .yoff = pixels,
            .mods = .{
                .precision = precision,
                .pixel_delta = true,
            },
        },
        .horizontal => .{
            .xoff = pixels,
            .mods = .{
                .precision = precision,
                .pixel_delta = true,
            },
        },
    };
}

pub fn keyPressed(vk: i32) bool {
    return sys.GetKeyState(vk) < 0;
}

fn keyToggled(vk: i32) bool {
    return (sys.GetKeyState(vk) & 1) != 0;
}

fn modsFromKeyboardState(state: *const [256]u8) input.Mods {
    const pressed = struct {
        fn check(state_: *const [256]u8, vk: usize) bool {
            return (state_[vk] & 0x80) != 0;
        }
    };

    return .{
        .shift = pressed.check(state, c.VK_SHIFT),
        .ctrl = pressed.check(state, c.VK_CONTROL),
        .alt = pressed.check(state, c.VK_MENU),
        .super = pressed.check(state, c.VK_LWIN) or pressed.check(state, c.VK_RWIN),
        .caps_lock = (state[c.VK_CAPITAL] & 1) != 0,
        .num_lock = (state[c.VK_NUMLOCK] & 1) != 0,
        .sides = .{
            .shift = if (pressed.check(state, c.VK_RSHIFT)) .right else .left,
            .ctrl = if (pressed.check(state, c.VK_RCONTROL)) .right else .left,
            .alt = if (pressed.check(state, c.VK_RMENU)) .right else .left,
            .super = if (pressed.check(state, c.VK_RWIN)) .right else .left,
        },
    };
}

/// Windows synthesizes left Ctrl + right Alt whenever AltGr is pressed on a
/// layout that has one. That pair is a layout shift, not a Ctrl+Alt chord.
fn isAltGr(mods: input.Mods) bool {
    return mods.ctrl and mods.alt and
        mods.sides.ctrl == .left and mods.sides.alt == .right;
}

/// Whether the active layout defines any AltGr mappings.
///
/// Windows only injects the synthetic left Ctrl on layouts that have an AltGr,
/// so on a layout without one (plain US, for instance) a left Ctrl plus right
/// Alt can only be a chord the user physically pressed, and collapsing it would
/// silently turn `ctrl+ralt+x` into a literal "x". Probing is cheap and needs no
/// cached state: it only runs while both keys are held, and the answer follows
/// the layout automatically because it is measured from the layout itself.
fn layoutHasAltGrMappings() bool {
    var state: [256]u8 = [_]u8{0} ** 256;
    state[c.VK_CONTROL] = 0x80;
    state[c.VK_LCONTROL] = 0x80;
    state[c.VK_MENU] = 0x80;
    state[c.VK_RMENU] = 0x80;

    // The printable ranges plus the OEM keys cover every key layouts actually
    // put an AltGr character on.
    for (c.VK_0..c.VK_9 + 1) |vk| {
        if (altGrProbeProducesText(@intCast(vk), &state)) return true;
    }
    for (c.VK_A..c.VK_Z + 1) |vk| {
        if (altGrProbeProducesText(@intCast(vk), &state)) return true;
    }
    for (c.VK_OEM_1..c.VK_OEM_7 + 1) |vk| {
        if (altGrProbeProducesText(@intCast(vk), &state)) return true;
    }
    return altGrProbeProducesText(c.VK_OEM_102, &state);
}

fn altGrProbeProducesText(vk: UINT, state: *const [256]u8) bool {
    return probeAltGrShiftStates(vk, state, altGrProbeProducesTextForState);
}

fn probeAltGrShiftStates(
    vk: UINT,
    state: *const [256]u8,
    comptime probe: anytype,
) bool {
    if (probe(vk, state)) return true;

    var shifted = state.*;
    shifted[c.VK_SHIFT] = 0x80;
    shifted[c.VK_LSHIFT] = 0x80;
    return probe(vk, &shifted);
}

fn altGrProbeProducesTextForState(vk: UINT, state: *const [256]u8) bool {
    var utf16: [4]u16 = [_]u16{0} ** 4;
    const scan_code = sys.MapVirtualKeyW(vk, c.MAPVK_VK_TO_VSC);
    return translateKeyTextToUnicode(vk, scan_code, state, &utf16) != 0;
}

fn testingShiftOnlyAltGrProbe(_: UINT, state: *const [256]u8) bool {
    return state[c.VK_SHIFT] & 0x80 != 0 and
        state[c.VK_LSHIFT] & 0x80 != 0;
}

test "win32 AltGr layout probe checks shifted mappings" {
    const state: [256]u8 = [_]u8{0} ** 256;
    try std.testing.expect(probeAltGrShiftStates(
        c.VK_A,
        &state,
        testingShiftOnlyAltGrProbe,
    ));
}

/// Drop the Ctrl+Alt that Windows synthesizes for AltGr. Reporting it verbatim
/// makes the encoder treat every AltGr combination as a Ctrl+Alt chord, which
/// encodes as ESC plus a C0 byte -- that is why AltGr+backspace arrived as
/// "Alt + Control" instead of a plain backspace. The raw keyboard state is left
/// untouched so the layout translation still produces the AltGr character.
fn withoutSyntheticAltGr(mods: input.Mods) input.Mods {
    if (!isAltGr(mods)) return mods;
    var result = mods;
    result.ctrl = false;
    result.alt = false;
    result.sides.ctrl = .left;
    result.sides.alt = .left;
    return result;
}

/// Apply the AltGr collapse only when the active layout actually has an AltGr.
/// The layout probe is behind the cheap modifier check so it only runs while
/// left Ctrl and right Alt are both held.
fn normalizeAltGrMods(mods: input.Mods) input.Mods {
    if (!isAltGr(mods)) return mods;
    if (!layoutHasAltGrMappings()) return mods;
    return withoutSyntheticAltGr(mods);
}

fn bindingModsOverride(raw_mods: input.Mods, encoded_mods: input.Mods) ?input.Mods {
    return if (!raw_mods.equal(encoded_mods)) raw_mods else null;
}

fn fallbackMods() input.Mods {
    return .{
        .shift = keyPressed(c.VK_SHIFT),
        .ctrl = keyPressed(c.VK_CONTROL),
        .alt = keyPressed(c.VK_MENU),
        .super = keyPressed(c.VK_LWIN) or keyPressed(c.VK_RWIN),
        .caps_lock = keyToggled(c.VK_CAPITAL),
        .num_lock = keyToggled(c.VK_NUMLOCK),
        .sides = .{
            .shift = if (keyPressed(c.VK_RSHIFT)) .right else .left,
            .ctrl = if (keyPressed(c.VK_RCONTROL)) .right else .left,
            .alt = if (keyPressed(c.VK_RMENU)) .right else .left,
            .super = if (keyPressed(c.VK_RWIN)) .right else .left,
        },
    };
}

fn currentKeyboardState(state: *[256]u8) ?*const [256]u8 {
    if (sys.GetKeyboardState(state) == 0) return null;
    return state;
}

fn currentModsFromKeyboardState(state: ?*const [256]u8) input.Mods {
    return if (state) |keyboard_state| modsFromKeyboardState(keyboard_state) else fallbackMods();
}

pub fn currentMods() input.Mods {
    var state: [256]u8 = [_]u8{0} ** 256;
    return currentModsFromKeyboardState(currentKeyboardState(&state));
}

fn quickSelectAltGrPressed(state: *const [256]u8) bool {
    return (state[c.VK_RMENU] & 0x80) != 0 and
        (state[c.VK_CONTROL] & 0x80) != 0;
}

fn quickSelectActionModsFromKeyboardState(state: *const [256]u8) input.Mods {
    return normalizeAltGrMods(modsFromKeyboardState(state));
}

pub fn quickSelectActionMods() input.Mods {
    var state: [256]u8 = [_]u8{0} ** 256;
    if (currentKeyboardState(&state)) |keyboard_state| {
        return quickSelectActionModsFromKeyboardState(keyboard_state);
    }

    return normalizeAltGrMods(fallbackMods());
}

/// Translate a key event into the single printable ASCII character a
/// quick-select label is typed with, or null when the key is not one.
///
/// Ctrl and Alt select the action a completed label performs, so ordinary
/// action modifiers are masked before translation. AltGr is preserved because
/// Windows represents it as synthetic Ctrl + right Alt and layouts need that
/// chord to produce printable label characters.
pub fn quickSelectAsciiFromKey(wParam: WPARAM, lParam: LPARAM) ?u8 {
    const vk: UINT = @intCast(wParam & 0xFFFF);
    var state: [256]u8 = [_]u8{0} ** 256;
    const keyboard_state = currentKeyboardState(&state) orelse {
        const codepoint = unshiftedCodepointForVirtualKey(vk);
        return if (codepoint >= 0x20 and codepoint < 0x7F)
            @intCast(codepoint)
        else
            null;
    };

    if (!quickSelectAltGrPressed(keyboard_state)) {
        state[c.VK_CONTROL] = 0;
        state[c.VK_LCONTROL] = 0;
        state[c.VK_RCONTROL] = 0;
        state[c.VK_MENU] = 0;
        state[c.VK_LMENU] = 0;
        state[c.VK_RMENU] = 0;
    }
    var translation_mods = modsFromKeyboardState(keyboard_state);
    if (quickSelectAltGrPressed(keyboard_state)) {
        // Preserve the raw Ctrl+right-Alt keyboard state for ToUnicodeEx, but
        // prevent translateKeyText's ordinary Ctrl-chord remasking from
        // stripping the layout's AltGr mapping back to the unmodified key.
        translation_mods.ctrl = false;
        translation_mods.alt = false;
    }
    const translated = translateKeyText(
        vk,
        lParam,
        translation_mods,
        keyboard_state,
    );
    if (translated.len != 1) return null;
    const char = translated.utf8[0];
    return if (char >= 0x20 and char < 0x7F) char else null;
}

fn keyFromVirtualKey(vk: UINT, lParam: LPARAM) input.Key {
    return switch (vk) {
        c.VK_BACK => .backspace,
        c.VK_TAB => .tab,
        c.VK_RETURN => if (isExtendedKey(lParam)) .numpad_enter else .enter,
        c.VK_SHIFT => if (scanCodeFromLParam(lParam) == 0x36) .shift_right else .shift_left,
        c.VK_LSHIFT => .shift_left,
        c.VK_RSHIFT => .shift_right,
        c.VK_CONTROL, c.VK_LCONTROL => if (isExtendedKey(lParam) or vk == c.VK_RCONTROL) .control_right else .control_left,
        c.VK_RCONTROL => .control_right,
        c.VK_MENU, c.VK_LMENU => if (isExtendedKey(lParam) or vk == c.VK_RMENU) .alt_right else .alt_left,
        c.VK_RMENU => .alt_right,
        c.VK_PAUSE => .pause,
        c.VK_CAPITAL => .caps_lock,
        c.VK_ESCAPE => .escape,
        c.VK_SPACE => .space,
        c.VK_PRIOR => .page_up,
        c.VK_NEXT => .page_down,
        c.VK_END => .end,
        c.VK_HOME => .home,
        c.VK_LEFT => .arrow_left,
        c.VK_UP => .arrow_up,
        c.VK_RIGHT => .arrow_right,
        c.VK_DOWN => .arrow_down,
        c.VK_SNAPSHOT => .print_screen,
        c.VK_INSERT => .insert,
        c.VK_DELETE => .delete,
        c.VK_LWIN => .meta_left,
        c.VK_RWIN => .meta_right,
        c.VK_APPS => .context_menu,
        c.VK_MULTIPLY => .numpad_multiply,
        c.VK_ADD => .numpad_add,
        c.VK_SEPARATOR => .numpad_separator,
        c.VK_SUBTRACT => .numpad_subtract,
        c.VK_DECIMAL => .numpad_decimal,
        c.VK_DIVIDE => .numpad_divide,
        c.VK_NUMLOCK => .num_lock,
        c.VK_SCROLL => .scroll_lock,
        c.VK_OEM_1 => .semicolon,
        c.VK_OEM_PLUS => .equal,
        c.VK_OEM_COMMA => .comma,
        c.VK_OEM_MINUS => .minus,
        c.VK_OEM_PERIOD => .period,
        c.VK_OEM_2 => .slash,
        c.VK_OEM_3 => .backquote,
        c.VK_OEM_4 => .bracket_left,
        c.VK_OEM_5 => .backslash,
        c.VK_OEM_6 => .bracket_right,
        c.VK_OEM_7 => .quote,
        c.VK_0...c.VK_9 => input.Key.fromASCII(@as(u8, @intCast('0' + (vk - c.VK_0)))) orelse .unidentified,
        c.VK_A...c.VK_Z => input.Key.fromASCII(@as(u8, @intCast('a' + (vk - c.VK_A)))) orelse .unidentified,
        c.VK_NUMPAD0...c.VK_NUMPAD9 => @enumFromInt(
            @intFromEnum(input.Key.numpad_0) + @as(c_int, @intCast(vk - c.VK_NUMPAD0)),
        ),
        c.VK_F1...c.VK_F24 => @enumFromInt(
            @intFromEnum(input.Key.f1) + @as(c_int, @intCast(vk - c.VK_F1)),
        ),
        else => .unidentified,
    };
}

fn unshiftedCodepointForVirtualKey(vk: UINT) u21 {
    return switch (vk) {
        c.VK_0...c.VK_9 => @as(u21, @intCast('0' + (vk - c.VK_0))),
        c.VK_A...c.VK_Z => @as(u21, @intCast('a' + (vk - c.VK_A))),
        c.VK_SPACE => ' ',
        c.VK_OEM_1 => ';',
        c.VK_OEM_PLUS => '=',
        c.VK_OEM_COMMA => ',',
        c.VK_OEM_MINUS => '-',
        c.VK_OEM_PERIOD => '.',
        c.VK_OEM_2 => '/',
        c.VK_OEM_3 => '`',
        c.VK_OEM_4 => '[',
        c.VK_OEM_5 => '\\',
        c.VK_OEM_6 => ']',
        c.VK_OEM_7 => '\'',
        else => 0,
    };
}

fn hotkeyModifiers(mods: input.Mods) UINT {
    var result: UINT = 0;
    if (mods.alt) result |= c.MOD_ALT;
    if (mods.ctrl) result |= c.MOD_CONTROL;
    if (mods.shift) result |= c.MOD_SHIFT;
    if (mods.super) result |= c.MOD_WIN;
    return result;
}

fn hotkeyPhysicalVirtualKey(key: input.Key) ?UINT {
    const key_int = @intFromEnum(key);
    if (key_int >= @intFromEnum(input.Key.key_a) and key_int <= @intFromEnum(input.Key.key_z)) {
        return c.VK_A + @as(UINT, @intCast(key_int - @intFromEnum(input.Key.key_a)));
    }
    if (key_int >= @intFromEnum(input.Key.digit_0) and key_int <= @intFromEnum(input.Key.digit_9)) {
        return c.VK_0 + @as(UINT, @intCast(key_int - @intFromEnum(input.Key.digit_0)));
    }
    if (key_int >= @intFromEnum(input.Key.numpad_0) and key_int <= @intFromEnum(input.Key.numpad_9)) {
        return c.VK_NUMPAD0 + @as(UINT, @intCast(key_int - @intFromEnum(input.Key.numpad_0)));
    }
    if (key_int >= @intFromEnum(input.Key.f1) and key_int <= @intFromEnum(input.Key.f24)) {
        return c.VK_F1 + @as(UINT, @intCast(key_int - @intFromEnum(input.Key.f1)));
    }

    return switch (key) {
        .backspace => c.VK_BACK,
        .tab => c.VK_TAB,
        .enter, .numpad_enter => c.VK_RETURN,
        .escape => c.VK_ESCAPE,
        .space => c.VK_SPACE,
        .page_up, .numpad_page_up => c.VK_PRIOR,
        .page_down, .numpad_page_down => c.VK_NEXT,
        .end, .numpad_end => c.VK_END,
        .home, .numpad_home => c.VK_HOME,
        .arrow_left, .numpad_left => c.VK_LEFT,
        .arrow_up, .numpad_up => c.VK_UP,
        .arrow_right, .numpad_right => c.VK_RIGHT,
        .arrow_down, .numpad_down => c.VK_DOWN,
        .print_screen => c.VK_SNAPSHOT,
        .insert, .numpad_insert => c.VK_INSERT,
        .delete, .numpad_delete => c.VK_DELETE,
        .meta_left => c.VK_LWIN,
        .meta_right => c.VK_RWIN,
        .context_menu => c.VK_APPS,
        .numpad_multiply => c.VK_MULTIPLY,
        .numpad_add => c.VK_ADD,
        .numpad_separator => c.VK_SEPARATOR,
        .numpad_subtract => c.VK_SUBTRACT,
        .numpad_decimal => c.VK_DECIMAL,
        .numpad_divide => c.VK_DIVIDE,
        .num_lock => c.VK_NUMLOCK,
        .scroll_lock => c.VK_SCROLL,
        .semicolon => c.VK_OEM_1,
        .equal => c.VK_OEM_PLUS,
        .comma => c.VK_OEM_COMMA,
        .minus => c.VK_OEM_MINUS,
        .period => c.VK_OEM_PERIOD,
        .slash => c.VK_OEM_2,
        .backquote => c.VK_OEM_3,
        .bracket_left => c.VK_OEM_4,
        .backslash => c.VK_OEM_5,
        .bracket_right => c.VK_OEM_6,
        .quote => c.VK_OEM_7,
        else => null,
    };
}

fn hotkeyUnicodeVirtualKey(cp: u21) ?struct { vk: UINT, shift: bool } {
    return switch (cp) {
        'a'...'z' => .{ .vk = c.VK_A + @as(UINT, @intCast(cp - 'a')), .shift = false },
        'A'...'Z' => .{ .vk = c.VK_A + @as(UINT, @intCast(cp - 'A')), .shift = true },
        '0'...'9' => .{ .vk = c.VK_0 + @as(UINT, @intCast(cp - '0')), .shift = false },
        ')' => .{ .vk = c.VK_0, .shift = true },
        '!' => .{ .vk = c.VK_0 + 1, .shift = true },
        '@' => .{ .vk = c.VK_0 + 2, .shift = true },
        '#' => .{ .vk = c.VK_0 + 3, .shift = true },
        '$' => .{ .vk = c.VK_0 + 4, .shift = true },
        '%' => .{ .vk = c.VK_0 + 5, .shift = true },
        '^' => .{ .vk = c.VK_0 + 6, .shift = true },
        '&' => .{ .vk = c.VK_0 + 7, .shift = true },
        '*' => .{ .vk = c.VK_0 + 8, .shift = true },
        '(' => .{ .vk = c.VK_0 + 9, .shift = true },
        ' ' => .{ .vk = c.VK_SPACE, .shift = false },
        ';' => .{ .vk = c.VK_OEM_1, .shift = false },
        ':' => .{ .vk = c.VK_OEM_1, .shift = true },
        '=' => .{ .vk = c.VK_OEM_PLUS, .shift = false },
        '+' => .{ .vk = c.VK_OEM_PLUS, .shift = true },
        ',' => .{ .vk = c.VK_OEM_COMMA, .shift = false },
        '<' => .{ .vk = c.VK_OEM_COMMA, .shift = true },
        '-' => .{ .vk = c.VK_OEM_MINUS, .shift = false },
        '_' => .{ .vk = c.VK_OEM_MINUS, .shift = true },
        '.' => .{ .vk = c.VK_OEM_PERIOD, .shift = false },
        '>' => .{ .vk = c.VK_OEM_PERIOD, .shift = true },
        '/' => .{ .vk = c.VK_OEM_2, .shift = false },
        '?' => .{ .vk = c.VK_OEM_2, .shift = true },
        '`' => .{ .vk = c.VK_OEM_3, .shift = false },
        '~' => .{ .vk = c.VK_OEM_3, .shift = true },
        '[' => .{ .vk = c.VK_OEM_4, .shift = false },
        '{' => .{ .vk = c.VK_OEM_4, .shift = true },
        '\\' => .{ .vk = c.VK_OEM_5, .shift = false },
        '|' => .{ .vk = c.VK_OEM_5, .shift = true },
        ']' => .{ .vk = c.VK_OEM_6, .shift = false },
        '}' => .{ .vk = c.VK_OEM_6, .shift = true },
        '\'' => .{ .vk = c.VK_OEM_7, .shift = false },
        '"' => .{ .vk = c.VK_OEM_7, .shift = true },
        else => null,
    };
}

pub fn hotkeySpecForTrigger(trigger: input.Binding.Trigger) ?GlobalHotkeySpec {
    var mods = trigger.mods.binding();
    const vk = switch (trigger.key) {
        .catch_all => return null,
        .physical => |key| hotkeyPhysicalVirtualKey(key) orelse return null,
        .unicode => |cp| unicode: {
            const mapped = hotkeyUnicodeVirtualKey(cp) orelse return null;
            if (mapped.shift) mods.shift = true;
            break :unicode mapped.vk;
        },
    };

    return .{
        .modifiers = hotkeyModifiers(mods),
        .vk = vk,
    };
}

pub fn hotkeySpecEql(a: GlobalHotkeySpec, b: GlobalHotkeySpec) bool {
    return a.modifiers == b.modifiers and a.vk == b.vk;
}

pub fn hotkeyRegistrationFailureReason(err: windows.Win32Error) []const u8 {
    return switch (err) {
        .HOTKEY_ALREADY_REGISTERED => "already registered by another app or another noctty instance",
        .ACCESS_DENIED => "access denied; hotkey may be reserved, occupied by an elevated app, or blocked by policy",
        .INVALID_PARAMETER => "invalid modifier or virtual-key combination",
        else => "unknown Win32 RegisterHotKey failure",
    };
}

fn isControlCodepoint(codepoint: u21) bool {
    return codepoint < 0x20 or codepoint == 0x7F;
}

fn utf16CodeUnitCount(codepoint: u21) usize {
    if (codepoint == 0) return 0;
    return if (codepoint <= std.math.maxInt(u16)) 1 else 2;
}

/// Whether plain typed text should be committed by the following `WM_CHAR`
/// instead of travelling on the physical key event.
///
/// `allow_defer` is false while a Kitty `report_all` client is active. The
/// synthetic `WM_CHAR` commit event carries no physical key and no modifiers,
/// so deferring would split one keystroke into a press with identity but no
/// text and a commit with text but no identity, and the release would never
/// pair with either. AltGr needs no exception here: the synthetic Ctrl+Alt pair
/// has already been collapsed by `normalizeAltGrMods` on layouts that have an
/// AltGr, so the physical event carries the layout text (`@` for German
/// `AltGr+Q`) with empty modifiers and the same key identity as its release.
fn shouldDeferTextToCharMessage(
    action: input.Action,
    key: input.Key,
    mods: input.Mods,
    translated: KeyText,
    allow_defer: bool,
) bool {
    if (action == .release) return false;
    if (!allow_defer) return false;
    // AltGr has already been normalized for layouts that use it. Any
    // modifiers still present here describe a terminal chord.
    if (mods.super or mods.ctrl or mods.alt) return false;
    if (key.modifier()) return false;

    switch (key) {
        .enter, .backspace, .tab, .escape => return false,
        else => {},
    }

    if (translated.deferred_utf16_units == 0) return false;
    if (translated.len > 0) return true;
    if (translated.unshifted_codepoint == 0) return true;
    return !isControlCodepoint(translated.unshifted_codepoint);
}

/// Plain text is committed by `WM_CHAR` unless a Kitty `report_all` client is
/// active. IME composition keeps deferring either way: its commit is text
/// without a physical key by design.
pub fn deferPlainTextToCharMessage(kitty_report_all: bool, ime_composing: bool) bool {
    return !kitty_report_all or ime_composing;
}

fn applyTranslatedKeyText(
    result: *Win32KeyMessage,
    translated: KeyText,
    defer_text: bool,
) void {
    // Copy the bytes rather than slicing `translated`: it is a by-value
    // parameter whose storage does not outlive this call, and `result` is
    // about to be returned by value anyway. `event.utf8` is left empty here
    // and bound to the caller's own copy via `bindText`.
    @memcpy(result.text[0..translated.len], translated.utf8[0..translated.len]);
    result.text_len = translated.len;
    result.event.utf8 = "";
    result.event.consumed_mods = translated.consumed_mods;
    if (defer_text) {
        // Keep the physical-key event visible to bindings/modifier state
        // but defer text emission to WM_CHAR so plain typing doesn't rely
        // on ToUnicode/GetKeyboardState timing.
        result.text_len = 0;
        result.event.consumed_mods = .{};
    }
    // A dead key is composing whether or not text is deferred: without the
    // flag the encoder would emit a bare `CSI <unshifted> u` for the accent
    // press before the composed character arrives.
    if (defer_text or translated.dead_key) {
        result.event.composing = true;
        result.deferred_utf16_units = translated.deferred_utf16_units;
    }
}

pub fn shouldAuthorizeDeferredCharMessage(effect: CoreSurface.InputEffect) bool {
    return effect == .ignored;
}

pub fn charCommitEvent(
    codepoint: u21,
    lParam: LPARAM,
    utf8_buf: *[8]u8,
) ?input.KeyEvent {
    const utf8_len = std.unicode.utf8Encode(codepoint, utf8_buf) catch return null;
    return .{
        .action = if (isRepeatedKey(lParam)) .repeat else .press,
        .key = .unidentified,
        .mods = .{},
        .unshifted_codepoint = codepoint,
        .utf8 = utf8_buf[0..utf8_len],
    };
}

fn translateKeyTextToUnicode(
    vk: UINT,
    scan_code: UINT,
    state: *const [256]u8,
    utf16: *[4]u16,
) i32 {
    // TranslateMessage owns the stateful dead-key composition path. This
    // helper only probes text metadata for key events, so it must not consume
    // or reset the layout's pending dead key.
    return sys.ToUnicode(vk, scan_code, state, utf16, utf16.len, c.TO_UNICODE_NO_STATE_CHANGE);
}

/// Which modifiers to blank out of a copy of the live keyboard state before
/// asking the layout to translate a key.
const KeyStateMask = struct {
    /// Clear Ctrl and Alt (including the synthetic AltGr pair).
    control: bool = false,
    /// Clear Shift. Implies `caps_lock`, because the two together are what
    /// "unshifted" means.
    shift: bool = false,
    /// Clear Caps Lock on its own.
    ///
    /// Caps Lock must not change the identity of a control chord: fixterms
    /// sends the fixterms-excluded letters as CSI u built from the event text,
    /// so leaving Caps Lock live would encode ctrl+m as `CSI 77;5u` ("M")
    /// instead of `CSI 109;5u` ("m") purely because the lock was on.
    caps_lock: bool = false,
};

fn maskedKeyboardState(state: *const [256]u8, mask: KeyStateMask) [256]u8 {
    var copy = state.*;
    if (mask.control) {
        copy[c.VK_CONTROL] = 0;
        copy[c.VK_LCONTROL] = 0;
        copy[c.VK_RCONTROL] = 0;
        copy[c.VK_MENU] = 0;
        copy[c.VK_LMENU] = 0;
        copy[c.VK_RMENU] = 0;
    }
    if (mask.shift) {
        copy[c.VK_SHIFT] = 0;
        copy[c.VK_LSHIFT] = 0;
        copy[c.VK_RSHIFT] = 0;
    }
    if (mask.shift or mask.caps_lock) copy[c.VK_CAPITAL] = 0;
    return copy;
}

/// Decode the UTF-16 units the layout produced into a single codepoint,
/// rejecting control characters. Control results are dropped because the core
/// encoder derives C0 bytes itself from the key and modifiers.
fn printableCodepoint(units: []const u16) ?u21 {
    if (units.len == 0) return null;
    const codepoint: u21 = cp: {
        if (units.len >= 2 and
            std.unicode.utf16IsHighSurrogate(units[0]) and
            std.unicode.utf16IsLowSurrogate(units[1]))
        {
            break :cp std.unicode.utf16DecodeSurrogatePair(
                &.{ units[0], units[1] },
            ) catch return null;
        }
        break :cp units[0];
    };
    if (isControlCodepoint(codepoint)) return null;
    return codepoint;
}

/// Decode every UTF-16 unit the layout produced into `buf` and return the
/// UTF-8 length. The whole result is rejected (0) when any codepoint is a
/// control character, because the core encoder derives C0 bytes itself from
/// the key and modifiers, or when a surrogate is unpaired.
fn printableText(units: []const u16, buf: *[text_capacity]u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < units.len) {
        const codepoint: u21 = cp: {
            if (i + 1 < units.len and
                std.unicode.utf16IsHighSurrogate(units[i]) and
                std.unicode.utf16IsLowSurrogate(units[i + 1]))
            {
                const pair = std.unicode.utf16DecodeSurrogatePair(
                    &.{ units[i], units[i + 1] },
                ) catch return 0;
                i += 2;
                break :cp pair;
            }
            const unit = units[i];
            i += 1;
            break :cp unit;
        };
        if (isControlCodepoint(codepoint)) return 0;
        len += std.unicode.utf8Encode(codepoint, buf[len..]) catch return 0;
    }
    return len;
}

/// Translate `vk` against a masked copy of the keyboard state and return the
/// printable codepoint it produces, if any.
fn translatePrintableCodepoint(
    vk: UINT,
    scan_code: UINT,
    state: *const [256]u8,
    mask: KeyStateMask,
) ?u21 {
    const masked = maskedKeyboardState(state, mask);
    var utf16: [4]u16 = [_]u16{0} ** 4;
    const count = translateKeyTextToUnicode(vk, scan_code, &masked, &utf16);
    if (count <= 0) return null;
    return printableCodepoint(utf16[0..@min(@as(usize, @intCast(count)), utf16.len)]);
}

/// The codepoint this key produces with every modifier cleared, taken from the
/// active layout so non-US layouts report their own key codes: ctrl+ő on a
/// Hungarian layout must report U+0151, not '['. Falls back to the static US
/// table when the layout produces nothing printable (dead keys, function keys).
///
/// This must be derived identically for press, repeat and release. The Kitty
/// encoder builds its key code from this field, so a press/release pair that
/// disagreed would look like two different keys to an application pairing them.
fn unshiftedCodepoint(
    vk: UINT,
    scan_code: UINT,
    keyboard_state: ?*const [256]u8,
) u21 {
    const state = keyboard_state orelse return unshiftedCodepointForVirtualKey(vk);
    return translatePrintableCodepoint(
        vk,
        scan_code,
        state,
        .{ .control = true, .shift = true },
    ) orelse unshiftedCodepointForVirtualKey(vk);
}

fn translateKeyText(
    vk: UINT,
    lParam: LPARAM,
    mods: input.Mods,
    keyboard_state: ?*const [256]u8,
) KeyText {
    const state = keyboard_state orelse {
        const unshifted = unshiftedCodepointForVirtualKey(vk);
        return .{
            .unshifted_codepoint = unshifted,
            .deferred_utf16_units = utf16CodeUnitCount(unshifted),
        };
    };

    const scan_code = scanCodeFromLParam(lParam);

    var result: KeyText = .{
        .unshifted_codepoint = unshiftedCodepoint(vk, scan_code, state),
    };

    var utf16: [4]u16 = [_]u16{0} ** 4;
    const count = translateKeyTextToUnicode(vk, scan_code, state, &utf16);
    if (count < 0) {
        // Dead key. The composed text arrives later as WM_CHAR.
        result.deferred_utf16_units = 1;
        result.dead_key = true;
        return result;
    }
    if (count > 0) result.deferred_utf16_units = @intCast(count);

    // Text for the event. Windows folds Ctrl into the layout translation
    // (ctrl+a becomes U+0001, ctrl+backspace becomes U+007F) or refuses to
    // translate at all (ctrl+comma yields nothing). Every other apprt hands the
    // core the *unmodified* layout text and lets key_encode derive the C0 byte
    // or the CSI u form, so re-translate Ctrl chords with Ctrl and Alt masked
    // out. Without this, ctrl+comma, ctrl+period, ctrl+m and friends reach the
    // encoder with no text at all and encode to nothing.
    // Caps Lock is masked with Ctrl but Shift is not: in a Ctrl chord Shift is
    // part of the chord the user typed, while Caps Lock is ambient state that
    // must not change which key the chord reports.
    if (mods.ctrl) {
        if (translatePrintableCodepoint(vk, scan_code, state, .{
            .control = true,
            .caps_lock = true,
        })) |cp| {
            result.len = std.unicode.utf8Encode(cp, &result.utf8) catch 0;
        }
        return result;
    }

    // Keep every unit the layout produced. A dead key that cannot combine with
    // this key yields the accent and the key together (`´x`); when the text
    // rides on the physical event instead of `WM_CHAR`, dropping the second
    // character would lose the key that was actually pressed.
    result.len = printableText(
        utf16[0..@min(@as(usize, @intCast(count)), utf16.len)],
        &result.utf8,
    );
    // Shift is only consumed when the layout used it to produce the text.
    // In a Ctrl chord shift is part of the chord, so it stays live.
    if (result.len > 0) result.consumed_mods = .{ .shift = mods.shift };

    return result;
}

fn packetKeyMessage(action: input.Action) Win32KeyMessage {
    const commit_pending = action != .release;
    return .{
        .event = .{
            .action = action,
            .key = .unidentified,
            .mods = .{},
            .consumed_mods = .{},
            .unshifted_codepoint = 0,
            .utf8 = "",
            .composing = commit_pending,
        },
        .deferred_utf16_units = if (commit_pending) 1 else 0,
    };
}

/// Build the key event for a `WM_(SYS)KEYDOWN` / `WM_(SYS)KEYUP` message.
/// The returned value owns its text; call `bindText` on the copy that will
/// outlive every read of `event.utf8`. `defer_plain_text` comes from
/// `deferPlainTextToCharMessage`.
pub fn keyEventFromWin32Message(
    msg: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    defer_plain_text: bool,
) ?Win32KeyMessage {
    const action: input.Action = switch (msg) {
        c.WM_KEYUP, c.WM_SYSKEYUP => .release,
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => if (isRepeatedKey(lParam)) .repeat else .press,
        else => return null,
    };

    const vk: UINT = @intCast(wParam & 0xFFFF);
    // KEYEVENTF_UNICODE arrives as VK_PACKET followed by one WM_CHAR UTF-16
    // code unit. Authorize that unit explicitly without consulting live
    // keyboard modifiers or ToUnicode; both belong to physical-key handling.
    if (vk == c.VK_PACKET) return packetKeyMessage(action);

    const key = keyFromVirtualKey(vk, lParam);
    var keyboard_state_storage: [256]u8 = [_]u8{0} ** 256;
    const keyboard_state = currentKeyboardState(&keyboard_state_storage);
    const raw_mods = currentModsFromKeyboardState(keyboard_state);
    const mods = normalizeAltGrMods(raw_mods);

    var result: Win32KeyMessage = .{
        .event = .{
            .action = action,
            .key = key,
            .mods = mods,
            // Windows' synthetic Ctrl+right-Alt pair must remain visible to
            // bindings so a deferred AltGr key cannot match a plain binding,
            // and press/release hashes must use the same physical identity.
            // Terminal encoding still uses the normalized modifiers above.
            .binding_mods = bindingModsOverride(raw_mods, mods),
            // Derived for release events too, not just press/repeat: see
            // unshiftedCodepoint.
            .unshifted_codepoint = unshiftedCodepoint(
                vk,
                scanCodeFromLParam(lParam),
                keyboard_state,
            ),
        },
    };

    if (action != .release) {
        const translated = translateKeyText(vk, lParam, mods, keyboard_state);
        applyTranslatedKeyText(
            &result,
            translated,
            shouldDeferTextToCharMessage(action, key, mods, translated, defer_plain_text),
        );
    }

    return result;
}

test "win32 keyFromVirtualKey maps core keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(input.Key.key_a, keyFromVirtualKey(c.VK_A, 0));
    try std.testing.expectEqual(input.Key.enter, keyFromVirtualKey(c.VK_RETURN, 0));
    try std.testing.expectEqual(input.Key.numpad_enter, keyFromVirtualKey(c.VK_RETURN, c.KF_EXTENDED));
    try std.testing.expectEqual(input.Key.arrow_left, keyFromVirtualKey(c.VK_LEFT, 0));
    try std.testing.expectEqual(input.Key.f12, keyFromVirtualKey(c.VK_F1 + 11, 0));
    try std.testing.expectEqual(input.Key.quote, keyFromVirtualKey(c.VK_OEM_7, 0));
}

/// The layout-sensitive tests below assert plain-US results, so skip them on any
/// other layout. The full HKL is compared rather than just the language id
/// because US-International, Dvorak and Colemak share LANGID 0x0409 but
/// translate differently.
fn testingUsLayout() bool {
    if (comptime builtin.os.tag != .windows) return false;
    return sys.GetKeyboardLayout(0) == 0x04090409;
}

fn testingKeyboardState(mods: input.Mods) [256]u8 {
    var state: [256]u8 = [_]u8{0} ** 256;
    if (mods.shift) {
        state[c.VK_SHIFT] = 0x80;
        state[if (mods.sides.shift == .right) c.VK_RSHIFT else c.VK_LSHIFT] = 0x80;
    }
    if (mods.ctrl) {
        state[c.VK_CONTROL] = 0x80;
        state[if (mods.sides.ctrl == .right) c.VK_RCONTROL else c.VK_LCONTROL] = 0x80;
    }
    if (mods.alt) {
        state[c.VK_MENU] = 0x80;
        state[if (mods.sides.alt == .right) c.VK_RMENU else c.VK_LMENU] = 0x80;
    }
    if (mods.caps_lock) state[c.VK_CAPITAL] = 0x01;
    return state;
}

/// Build the key event the window procedure would hand the core surface, but
/// from an explicit modifier set instead of the live keyboard. `text` is owned
/// by the caller because the event borrows its UTF-8 buffer.
///
/// The AltGr collapse is applied unconditionally here so the table below can
/// assert AltGr semantics on any runner. Whether the collapse fires in
/// production is the layout probe's job and is covered separately.
fn testingKeyEvent(vk: UINT, raw_mods: input.Mods, text: *KeyText) input.KeyEvent {
    const state = testingKeyboardState(raw_mods);
    const mods = withoutSyntheticAltGr(raw_mods);
    text.* = translateKeyText(vk, testingScanCode(vk), mods, &state);
    return .{
        .action = .press,
        .key = keyFromVirtualKey(vk, 0),
        .mods = mods,
        .consumed_mods = text.consumed_mods,
        .unshifted_codepoint = text.unshifted_codepoint,
        .utf8 = text.utf8[0..text.len],
    };
}

/// lParam carrying the layout scan code for `vk` in the position
/// `scanCodeFromLParam` reads it from.
fn testingScanCode(vk: UINT) LPARAM {
    const scan = sys.MapVirtualKeyW(vk, c.MAPVK_VK_TO_VSC);
    return @bitCast(@as(usize, scan) << 16);
}

// The Kitty encoder builds its key code from unshifted_codepoint, so press and
// release have to agree. VK_DIVIDE is the regression probe: it is absent from
// unshiftedCodepointForVirtualKey's table (which would report 0) but the layout
// translates it to '/', so a release path still using the table shows up here.
test "win32 unshifted codepoint agrees across press and release" {
    if (!testingUsLayout()) return error.SkipZigTest;

    const keys = [_]UINT{ c.VK_DIVIDE, c.VK_MULTIPLY, c.VK_ADD, c.VK_A, c.VK_OEM_COMMA };
    for (keys) |vk| {
        const lParam = testingScanCode(vk);
        const press = keyEventFromWin32Message(c.WM_KEYDOWN, vk, lParam, true).?;
        const release = keyEventFromWin32Message(c.WM_KEYUP, vk, lParam, true).?;
        try std.testing.expectEqual(
            press.event.unshifted_codepoint,
            release.event.unshifted_codepoint,
        );
        try std.testing.expect(release.event.unshifted_codepoint != 0);
    }

    // Pin the layout-derived value for a key the static table does not carry.
    const divide = keyEventFromWin32Message(
        c.WM_KEYUP,
        c.VK_DIVIDE,
        testingScanCode(c.VK_DIVIDE),
        true,
    ).?;
    try std.testing.expectEqual(@as(u21, '/'), divide.event.unshifted_codepoint);
    try std.testing.expectEqual(@as(u21, 0), unshiftedCodepointForVirtualKey(c.VK_DIVIDE));
}

test "win32 AltGr collapse only applies to layouts that have an AltGr" {
    if (!testingUsLayout()) return error.SkipZigTest;

    // Plain US has no AltGr mappings, so left Ctrl + right Alt can only be a
    // chord the user physically pressed and must survive as one.
    try std.testing.expect(!layoutHasAltGrMappings());

    const altgr: input.Mods = .{
        .ctrl = true,
        .alt = true,
        .sides = .{ .ctrl = .left, .alt = .right },
    };
    const normalized = normalizeAltGrMods(altgr);
    try std.testing.expect(normalized.ctrl);
    try std.testing.expect(normalized.alt);
}

// Every combination the reporter of #178 listed, plus the ones that already
// worked, pinned to the bytes the terminal is supposed to receive.
test "win32 issue 178 key combinations encode correctly" {
    if (!testingUsLayout()) return error.SkipZigTest;

    const alt: input.Mods = .{ .alt = true };
    const ctrl: input.Mods = .{ .ctrl = true };
    const altgr: input.Mods = .{
        .ctrl = true,
        .alt = true,
        .sides = .{ .ctrl = .left, .alt = .right },
    };
    const ctrl_alt: input.Mods = .{ .ctrl = true, .alt = true };

    const cases = [_]struct {
        name: []const u8,
        vk: UINT,
        mods: input.Mods,
        expect: []const u8,
    }{
        // Control: this one was already reported as working.
        .{ .name = "alt+backspace", .vk = c.VK_BACK, .mods = alt, .expect = "\x1b\x7f" },
        // Alt+<letter> must be an ESC prefix, never ESC + C0 (which conhost
        // decodes back as "Alt + Control").
        .{ .name = "alt+a", .vk = c.VK_A, .mods = alt, .expect = "\x1ba" },
        .{ .name = "alt+comma", .vk = c.VK_OEM_COMMA, .mods = alt, .expect = "\x1b," },
        // AltGr is a layout shift: its synthetic Ctrl+Alt must not survive.
        .{ .name = "altgr+backspace", .vk = c.VK_BACK, .mods = altgr, .expect = "\x7f" },
        // A real Ctrl+Alt chord still encodes as ESC + C0.
        .{ .name = "ctrl+alt+c", .vk = c.VK_A + 2, .mods = ctrl_alt, .expect = "\x1b\x03" },
        // Ctrl+backspace keeps the xterm/upstream 0x08 encoding.
        .{ .name = "ctrl+backspace", .vk = c.VK_BACK, .mods = ctrl, .expect = "\x08" },
        // These four produced no bytes at all before the fix.
        .{ .name = "ctrl+comma", .vk = c.VK_OEM_COMMA, .mods = ctrl, .expect = "\x1b[44;5u" },
        .{ .name = "ctrl+period", .vk = c.VK_OEM_PERIOD, .mods = ctrl, .expect = "\x1b[46;5u" },
        .{ .name = "ctrl+semicolon", .vk = c.VK_OEM_1, .mods = ctrl, .expect = "\x1b[59;5u" },
        .{ .name = "ctrl+m", .vk = c.VK_A + 12, .mods = ctrl, .expect = "\x1b[109;5u" },
        .{ .name = "ctrl+i", .vk = c.VK_A + 8, .mods = ctrl, .expect = "\x1b[105;5u" },
        .{ .name = "ctrl+bracket_left", .vk = c.VK_OEM_4, .mods = ctrl, .expect = "\x1b[91;5u" },
        // Ctrl+letter C0 bytes are unchanged.
        .{ .name = "ctrl+c", .vk = c.VK_A + 2, .mods = ctrl, .expect = "\x03" },
        .{ .name = "ctrl+a", .vk = c.VK_A, .mods = ctrl, .expect = "\x01" },
        .{ .name = "ctrl+slash", .vk = c.VK_OEM_2, .mods = ctrl, .expect = "\x1f" },
        .{ .name = "ctrl+space", .vk = c.VK_SPACE, .mods = ctrl, .expect = "\x00" },
        // Shift stays live inside a Ctrl chord.
        .{
            .name = "ctrl+shift+minus",
            .vk = c.VK_OEM_MINUS,
            .mods = .{ .ctrl = true, .shift = true },
            .expect = "\x1f",
        },
        .{
            .name = "ctrl+shift+2",
            .vk = c.VK_0 + 2,
            .mods = .{ .ctrl = true, .shift = true },
            .expect = "\x1b[64;5u",
        },
        // Plain typing is untouched.
        .{ .name = "plain a", .vk = c.VK_A, .mods = .{}, .expect = "a" },
        .{
            .name = "shift+a",
            .vk = c.VK_A,
            .mods = .{ .shift = true },
            .expect = "A",
        },
    };

    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var text: KeyText = .{};
        try input.key_encode.encode(
            &writer,
            testingKeyEvent(case.vk, case.mods, &text),
            .{ .alt_esc_prefix = true },
        );
        std.testing.expectEqualStrings(case.expect, writer.buffered()) catch |err| {
            std.debug.print("win32 issue 178 case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "win32 control chords carry the unmodified layout text" {
    if (!testingUsLayout()) return error.SkipZigTest;

    const ctrl: input.Mods = .{ .ctrl = true };
    const state = testingKeyboardState(ctrl);

    // Ctrl+comma does not translate at all under Windows...
    const comma = translateKeyText(c.VK_OEM_COMMA, testingScanCode(c.VK_OEM_COMMA), ctrl, &state);
    try std.testing.expectEqualStrings(",", comma.utf8[0..comma.len]);
    try std.testing.expectEqual(@as(u21, ','), comma.unshifted_codepoint);

    // ...and ctrl+m translates to a control character. Both must still reach
    // the core as the plain layout text.
    const m = translateKeyText(c.VK_A + 12, testingScanCode(c.VK_A + 12), ctrl, &state);
    try std.testing.expectEqualStrings("m", m.utf8[0..m.len]);
    try std.testing.expectEqual(@as(u21, 'm'), m.unshifted_codepoint);

    // Keys whose unmodified translation is itself a control character stay
    // text-free so the PC-style function key tables still win.
    const backspace = translateKeyText(c.VK_BACK, testingScanCode(c.VK_BACK), ctrl, &state);
    try std.testing.expectEqual(@as(usize, 0), backspace.len);
    const enter = translateKeyText(c.VK_RETURN, testingScanCode(c.VK_RETURN), ctrl, &state);
    try std.testing.expectEqual(@as(usize, 0), enter.len);
    const tab = translateKeyText(c.VK_TAB, testingScanCode(c.VK_TAB), ctrl, &state);
    try std.testing.expectEqual(@as(usize, 0), tab.len);
}

// Caps Lock is ambient state, not part of the chord the user typed. The Ctrl
// re-translation asks the layout for the text again, so an unmasked Caps Lock
// turned ctrl+m into "M" and encoded CSI 77;5u instead of CSI 109;5u -- the
// lock silently changed which key the application saw.
test "win32 caps lock does not change control chord identity" {
    if (!testingUsLayout()) return error.SkipZigTest;

    const caps_ctrl: input.Mods = .{ .ctrl = true, .caps_lock = true };
    const caps_ctrl_shift: input.Mods = .{ .ctrl = true, .shift = true, .caps_lock = true };

    const cases = [_]struct {
        name: []const u8,
        vk: UINT,
        mods: input.Mods,
        expect: []const u8,
    }{
        // The fixterms-excluded letters go out as CSI u built from the text.
        .{ .name = "caps+ctrl+m", .vk = c.VK_A + 12, .mods = caps_ctrl, .expect = "\x1b[109;5u" },
        .{ .name = "caps+ctrl+i", .vk = c.VK_A + 8, .mods = caps_ctrl, .expect = "\x1b[105;5u" },
        // Shift is still part of the chord and still reported.
        .{ .name = "caps+ctrl+shift+m", .vk = c.VK_A + 12, .mods = caps_ctrl_shift, .expect = "\x1b[109;6u" },
        // C0 letters were already caps-insensitive; keep them that way.
        .{ .name = "caps+ctrl+a", .vk = c.VK_A, .mods = caps_ctrl, .expect = "\x01" },
        .{ .name = "caps+ctrl+c", .vk = c.VK_A + 2, .mods = caps_ctrl, .expect = "\x03" },
    };

    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var text: KeyText = .{};
        try input.key_encode.encode(
            &writer,
            testingKeyEvent(case.vk, case.mods, &text),
            .{ .alt_esc_prefix = true },
        );
        std.testing.expectEqualStrings(case.expect, writer.buffered()) catch |err| {
            std.debug.print("win32 caps lock case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "win32 synthetic AltGr modifiers are not a ctrl+alt chord" {
    const altgr: input.Mods = .{
        .ctrl = true,
        .alt = true,
        .sides = .{ .ctrl = .left, .alt = .right },
    };
    try std.testing.expect(isAltGr(altgr));
    const stripped = withoutSyntheticAltGr(altgr);
    try std.testing.expect(!stripped.ctrl);
    try std.testing.expect(!stripped.alt);

    // A deliberate ctrl+alt chord (left alt, or right ctrl) is left alone.
    const left_alt: input.Mods = .{ .ctrl = true, .alt = true };
    try std.testing.expect(!isAltGr(left_alt));
    try std.testing.expect(std.meta.eql(left_alt, withoutSyntheticAltGr(left_alt)));

    const right_ctrl: input.Mods = .{
        .ctrl = true,
        .alt = true,
        .sides = .{ .ctrl = .right, .alt = .right },
    };
    try std.testing.expect(!isAltGr(right_ctrl));
    try std.testing.expect(std.meta.eql(right_ctrl, withoutSyntheticAltGr(right_ctrl)));

    // Ctrl or alt alone is never AltGr.
    try std.testing.expect(!isAltGr(.{ .ctrl = true }));
    try std.testing.expect(!isAltGr(.{ .alt = true, .sides = .{ .alt = .right } }));
}

test "win32 shouldDeferTextToCharMessage only defers plain text keys" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 1), utf16CodeUnitCount('a'));
    try std.testing.expectEqual(@as(usize, 2), utf16CodeUnitCount(0x1F642));
    try std.testing.expect(shouldDeferTextToCharMessage(
        .press,
        .key_a,
        .{},
        .{ .len = 1, .unshifted_codepoint = 'a', .deferred_utf16_units = 1 },
        true,
    ));
    try std.testing.expect(shouldDeferTextToCharMessage(
        .repeat,
        .space,
        .{},
        .{ .len = 1, .unshifted_codepoint = ' ', .deferred_utf16_units = 1 },
        true,
    ));
    try std.testing.expect(shouldDeferTextToCharMessage(
        .press,
        .quote,
        .{},
        .{ .unshifted_codepoint = '\'', .deferred_utf16_units = 1 },
        true,
    ));
    try std.testing.expect(!shouldDeferTextToCharMessage(
        .press,
        .digit_2,
        .{ .ctrl = true, .alt = true },
        .{ .unshifted_codepoint = '2', .deferred_utf16_units = 1 },
        true,
    ));
    const raw_alt_gr: input.Mods = .{
        .ctrl = true,
        .alt = true,
        .sides = .{ .ctrl = .left, .alt = .right },
    };
    try std.testing.expect(!shouldDeferTextToCharMessage(
        .press,
        .equal,
        raw_alt_gr,
        .{ .len = 1, .unshifted_codepoint = '=', .deferred_utf16_units = 1 },
        true,
    ));
    try std.testing.expect(shouldDeferTextToCharMessage(
        .press,
        .equal,
        withoutSyntheticAltGr(raw_alt_gr),
        .{ .len = 1, .unshifted_codepoint = '=', .deferred_utf16_units = 1 },
        true,
    ));
    try std.testing.expect(!shouldDeferTextToCharMessage(
        .press,
        .equal,
        .{ .alt = true, .sides = .{ .alt = .right } },
        .{ .len = 1, .unshifted_codepoint = '=', .deferred_utf16_units = 1 },
        true,
    ));
    try std.testing.expect(!shouldDeferTextToCharMessage(
        .press,
        .equal,
        .{
            .ctrl = true,
            .alt = true,
            .sides = .{ .ctrl = .right, .alt = .right },
        },
        .{ .len = 1, .unshifted_codepoint = '=', .deferred_utf16_units = 1 },
        true,
    ));
    try std.testing.expect(!shouldDeferTextToCharMessage(
        .press,
        .enter,
        .{},
        .{ .unshifted_codepoint = 0x0D },
        true,
    ));
}

test "win32 kitty-report-all skips WM_CHAR deferral" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(deferPlainTextToCharMessage(false, false));
    try std.testing.expect(!deferPlainTextToCharMessage(true, false));
    try std.testing.expect(deferPlainTextToCharMessage(true, true));
    try std.testing.expect(!shouldDeferTextToCharMessage(
        .press,
        .key_a,
        .{ .shift = true, .caps_lock = true },
        .{ .len = 1, .unshifted_codepoint = 'a', .deferred_utf16_units = 1 },
        false,
    ));
}

// A dead key produces no text yet, so its press must stay `composing` even
// when plain text is no longer deferred: otherwise the encoder emits a bare
// `CSI <unshifted> u` for the accent before the composed character arrives.
test "win32 kitty-report-all dead key remains composing" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var message: Win32KeyMessage = .{ .event = .{
        .action = .press,
        .key = .quote,
        .unshifted_codepoint = '\'',
    } };
    applyTranslatedKeyText(
        &message,
        .{ .unshifted_codepoint = '\'', .deferred_utf16_units = 1, .dead_key = true },
        false,
    );
    message.bindText();

    try std.testing.expect(message.event.composing);
    try std.testing.expectEqualStrings("", message.event.utf8);
    try std.testing.expectEqual(@as(usize, 1), message.deferred_utf16_units);
}

// Under kitty `report_all` the translated text is no longer suppressed, so it
// is read on the ordinary typing path. `event.utf8` is a borrowed slice and
// `keyEventFromWin32Message` returns its message by value, so the bytes must
// live in the message itself: a slice into the `KeyText` local would dangle
// before `keyCallback` ever saw it.
test "win32 translated key text is owned by the message it travels in" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var translated: KeyText = .{
        .len = 1,
        .unshifted_codepoint = 'a',
        .deferred_utf16_units = 1,
    };
    translated.utf8[0] = 'a';

    var message: Win32KeyMessage = .{ .event = .{
        .action = .press,
        .key = .key_a,
    } };
    applyTranslatedKeyText(&message, translated, false);

    // Nothing points at `translated`; the bytes were copied out.
    try std.testing.expectEqualStrings("", message.event.utf8);
    try std.testing.expectEqual(@as(usize, 1), message.text_len);

    message.bindText();
    try std.testing.expectEqualStrings("a", message.event.utf8);
    try std.testing.expectEqual(
        @intFromPtr(&message.text),
        @intFromPtr(message.event.utf8.ptr),
    );

    // A copy, which is what every caller of `keyEventFromWin32Message` gets,
    // must rebase onto its own storage, not keep pointing at the original.
    var copy = message;
    copy.bindText();
    try std.testing.expectEqualStrings("a", copy.event.utf8);
    try std.testing.expectEqual(
        @intFromPtr(&copy.text),
        @intFromPtr(copy.event.utf8.ptr),
    );

    // Deferral to WM_CHAR still suppresses the text after binding.
    var deferred: Win32KeyMessage = .{ .event = .{
        .action = .press,
        .key = .key_a,
    } };
    applyTranslatedKeyText(&deferred, translated, true);
    deferred.bindText();
    try std.testing.expectEqualStrings("", deferred.event.utf8);
    try std.testing.expect(deferred.event.composing);
}

// ToUnicode returns more than one unit when a dead key cannot combine with the
// key that follows it (acute accent then `x` on US-International yields both).
// When the text rides on the physical event, every unit has to survive,
// because the WM_CHARs that would otherwise have carried them are no longer
// authorized.
test "win32 translated key text keeps every unit ToUnicode returned" {
    var buf: [text_capacity]u8 = undefined;

    const accent_then_x = [_]u16{ 0x00B4, 'x' };
    try std.testing.expectEqualStrings("\u{B4}x", buf[0..printableText(&accent_then_x, &buf)]);

    const pair = [_]u16{ 0xD83D, 0xDE42 };
    try std.testing.expectEqualStrings("\u{1F642}", buf[0..printableText(&pair, &buf)]);

    const four = [_]u16{ 'a', 'b', 'c', 'd' };
    try std.testing.expectEqualStrings("abcd", buf[0..printableText(&four, &buf)]);

    // Control characters and unpaired surrogates reject the whole result; the
    // encoder derives C0 bytes from the key and modifiers itself.
    const control = [_]u16{ 'a', 0x01 };
    try std.testing.expectEqual(@as(usize, 0), printableText(&control, &buf));
    const lone_high = [_]u16{0xD83D};
    try std.testing.expectEqual(@as(usize, 0), printableText(&lone_high, &buf));
    try std.testing.expectEqual(@as(usize, 0), printableText(&.{}, &buf));
}

// German AltGr+Q under `report_all`: the physical press carries "@" with the
// synthetic Ctrl+Alt collapsed, and the release hashes to the same binding
// identity, so a client pairing press and release sees one key.
test "win32 kitty-report-all AltGr press carries text on the physical event" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const raw_alt_gr: input.Mods = .{
        .ctrl = true,
        .alt = true,
        .sides = .{ .ctrl = .left, .alt = .right },
    };
    const mods = withoutSyntheticAltGr(raw_alt_gr);
    var translated: KeyText = .{
        .len = 1,
        .unshifted_codepoint = 'q',
        .deferred_utf16_units = 1,
    };
    translated.utf8[0] = '@';

    try std.testing.expect(!shouldDeferTextToCharMessage(.press, .key_q, mods, translated, false));

    var press: Win32KeyMessage = .{ .event = .{
        .action = .press,
        .key = .key_q,
        .mods = mods,
        .binding_mods = bindingModsOverride(raw_alt_gr, mods),
        .unshifted_codepoint = 'q',
    } };
    applyTranslatedKeyText(&press, translated, false);
    press.bindText();
    const release: input.KeyEvent = .{
        .action = .release,
        .key = .key_q,
        .mods = mods,
        .binding_mods = bindingModsOverride(raw_alt_gr, mods),
        .unshifted_codepoint = 'q',
    };

    try std.testing.expect(!press.event.composing);
    try std.testing.expectEqualStrings("@", press.event.utf8);
    try std.testing.expectEqual(@as(usize, 0), press.deferred_utf16_units);
    try std.testing.expectEqual(press.event.bindingHash(), release.bindingHash());

    const flags: @import("../../terminal/kitty/key.zig").Flags = .{
        .disambiguate = true,
        .report_events = true,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    };
    var press_buf: [64]u8 = undefined;
    var press_writer: std.Io.Writer = .fixed(&press_buf);
    try input.key_encode.encode(&press_writer, press.event, .{ .kitty_flags = flags });
    // Key code is the unshifted `q`; no modifiers; associated text is `@`.
    try std.testing.expectEqualStrings("\x1b[113;;64u", press_writer.buffered());

    var release_buf: [64]u8 = undefined;
    var release_writer: std.Io.Writer = .fixed(&release_buf);
    try input.key_encode.encode(&release_writer, release, .{ .kitty_flags = flags });
    try std.testing.expectEqualStrings("\x1b[113;1:3u", release_writer.buffered());
}

test "win32 deferred char authorization respects key handling effect" {
    try std.testing.expect(shouldAuthorizeDeferredCharMessage(.ignored));
    try std.testing.expect(!shouldAuthorizeDeferredCharMessage(.consumed));
    try std.testing.expect(!shouldAuthorizeDeferredCharMessage(.closed));
}

test "win32 AltGr binding identity agrees across deferred press and release" {
    const raw_alt_gr: input.Mods = .{
        .ctrl = true,
        .alt = true,
        .sides = .{ .ctrl = .left, .alt = .right },
    };
    const normalized = withoutSyntheticAltGr(raw_alt_gr);
    var press: Win32KeyMessage = .{ .event = .{
        .action = .press,
        .key = .key_a,
        .mods = normalized,
        .binding_mods = bindingModsOverride(raw_alt_gr, normalized),
        .unshifted_codepoint = 'a',
    } };
    const release: input.KeyEvent = .{
        .action = .release,
        .key = .key_a,
        .mods = normalized,
        .binding_mods = bindingModsOverride(raw_alt_gr, normalized),
        .unshifted_codepoint = 'a',
    };

    applyTranslatedKeyText(&press, .{ .deferred_utf16_units = 1 }, true);

    try std.testing.expect(std.meta.eql(normalized, press.event.mods));
    try std.testing.expect(std.meta.eql(raw_alt_gr, press.event.bindingMods()));
    try std.testing.expect(std.meta.eql(raw_alt_gr, release.bindingMods()));
    try std.testing.expectEqual(press.event.bindingHash(), release.bindingHash());
    try std.testing.expect(press.event.composing);
    try std.testing.expectEqualStrings("", press.event.utf8);
    try std.testing.expectEqual(@as(usize, 1), press.deferred_utf16_units);

    // The binding-only override must not leak the synthetic Ctrl+Alt pair into
    // Kitty release reporting. Its bytes stay identical to the normalized
    // event that existed before binding identity was separated.
    var expected_buf: [64]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buf);
    var normalized_release = release;
    normalized_release.binding_mods = null;
    try input.key_encode.encode(&expected, normalized_release, .{
        .kitty_flags = .{ .disambiguate = true, .report_events = true },
    });

    var actual_buf: [64]u8 = undefined;
    var actual: std.Io.Writer = .fixed(&actual_buf);
    try input.key_encode.encode(&actual, release, .{
        .kitty_flags = .{ .disambiguate = true, .report_events = true },
    });
    try std.testing.expect(actual.buffered().len > 0);
    try std.testing.expectEqualStrings(expected.buffered(), actual.buffered());
}

test "win32 VK_PACKET key down authorizes one unit without direct text or modifiers" {
    const message = keyEventFromWin32Message(c.WM_KEYDOWN, c.VK_PACKET, 0, true).?;
    try std.testing.expectEqual(input.Action.press, message.event.action);
    try std.testing.expectEqual(input.Key.unidentified, message.event.key);
    try std.testing.expectEqualStrings("", message.event.utf8);
    try std.testing.expect(message.event.composing);
    try std.testing.expectEqual(@as(u21, 0), message.event.unshifted_codepoint);
    try std.testing.expect(std.meta.eql(input.Mods{}, message.event.mods));
    try std.testing.expect(std.meta.eql(input.Mods{}, message.event.consumed_mods));
    try std.testing.expectEqual(@as(usize, 1), message.deferred_utf16_units);
}

test "win32 VK_PACKET key up authorizes no units or text" {
    const message = keyEventFromWin32Message(c.WM_KEYUP, c.VK_PACKET, 0, true).?;
    try std.testing.expectEqual(input.Action.release, message.event.action);
    try std.testing.expectEqual(input.Key.unidentified, message.event.key);
    try std.testing.expectEqualStrings("", message.event.utf8);
    try std.testing.expect(!message.event.composing);
    try std.testing.expectEqual(@as(u21, 0), message.event.unshifted_codepoint);
    try std.testing.expect(std.meta.eql(input.Mods{}, message.event.mods));
    try std.testing.expect(std.meta.eql(input.Mods{}, message.event.consumed_mods));
    try std.testing.expectEqual(@as(usize, 0), message.deferred_utf16_units);
}

test "win32 authorized char commit preserves packet control characters" {
    var utf8_buf: [8]u8 = undefined;
    const fixtures = [_]struct { codepoint: u21, expected: []const u8 }{
        .{ .codepoint = '\r', .expected = "\r" },
        .{ .codepoint = '\n', .expected = "\n" },
        .{ .codepoint = '\t', .expected = "\t" },
        .{ .codepoint = 0x08, .expected = "\x08" },
        .{ .codepoint = 0x1B, .expected = "\x1B" },
    };
    for (fixtures) |fixture| {
        const event = charCommitEvent(fixture.codepoint, 0, &utf8_buf).?;
        try std.testing.expectEqual(input.Key.unidentified, event.key);
        try std.testing.expectEqual(fixture.codepoint, event.unshifted_codepoint);
        try std.testing.expectEqualStrings(fixture.expected, event.utf8);
    }
}

test "win32 deferred char authorization preserves pending units across non-text events" {
    var state: DeferredCharState = .{};
    state.authorize(1);
    // Release and unrelated non-text key messages authorize zero units.
    state.authorize(0);
    try std.testing.expectEqual(@as(usize, 1), state.pending_units);
    try std.testing.expectEqual(@as(?u21, 'a'), state.consumeCodeUnit('a', false));
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);
}

test "win32 deferred char dead key and composition consume exact units" {
    var state: DeferredCharState = .{};
    state.authorize(1);
    state.consumeDeadChar();
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);

    state.authorize(1);
    try std.testing.expectEqual(@as(?u21, 0x00E9), state.consumeCodeUnit(0x00E9, false));
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);
}

test "win32 deferred char authorization blocks unsolicited and IME text" {
    var state: DeferredCharState = .{};
    try std.testing.expectEqual(@as(?u21, null), state.consumeCodeUnit('a', false));

    state.authorize(1);
    try std.testing.expectEqual(@as(?u21, null), state.consumeCodeUnit('a', true));
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);
    try std.testing.expectEqual(@as(?u21, null), state.consumeCodeUnit('a', false));
}

test "win32 deferred char two surrogate keydowns consume two code units" {
    var state: DeferredCharState = .{};
    state.authorize(1);
    state.authorize(1);
    try std.testing.expectEqual(@as(?u21, null), state.consumeCodeUnit(0xD83D, false));
    try std.testing.expectEqual(@as(usize, 1), state.pending_units);
    try std.testing.expectEqual(@as(?u21, 0x1F642), state.consumeCodeUnit(0xDE42, false));
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);
}

test "win32 deferred char supplementary expectation authorizes both units" {
    var state: DeferredCharState = .{};
    state.authorize(2);
    try std.testing.expectEqual(@as(?u21, null), state.consumeCodeUnit(0xD83D, false));
    try std.testing.expectEqual(@as(usize, 1), state.pending_units);
    try std.testing.expectEqual(@as(?u21, 0x1F642), state.consumeCodeUnit(0xDE42, false));
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);
}

test "win32 deferred char commits 256 delayed BMP authorizations" {
    var state: DeferredCharState = .{};
    for (0..256) |_| state.authorize(1);
    try std.testing.expectEqual(@as(usize, 256), state.pending_units);

    for (0..256) |_| {
        try std.testing.expectEqual(@as(?u21, 'a'), state.consumeCodeUnit('a', false));
    }
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);
}

test "win32 deferred char malformed surrogate clears authorization state" {
    var state: DeferredCharState = .{};
    state.authorize(3);
    try std.testing.expectEqual(@as(?u21, null), state.consumeCodeUnit(0xD83D, false));
    try std.testing.expectEqual(@as(?u21, null), state.consumeCodeUnit('a', false));
    try std.testing.expectEqual(@as(usize, 0), state.pending_units);
    try std.testing.expectEqual(@as(?u16, null), state.high_surrogate);
}

test "win32 deferred char authorization saturates only at usize maximum" {
    var state: DeferredCharState = .{
        .pending_units = std.math.maxInt(usize) - 1,
    };
    state.authorize(2);
    try std.testing.expectEqual(std.math.maxInt(usize), state.pending_units);
}

test "win32 hotkeySpecForTrigger maps physical key triggers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const spec = hotkeySpecForTrigger(.{
        .key = .{ .physical = .key_a },
        .mods = .{ .ctrl = true, .shift = true },
    }).?;

    try std.testing.expectEqual(@as(UINT, c.MOD_CONTROL | c.MOD_SHIFT), spec.modifiers);
    try std.testing.expectEqual(@as(UINT, c.VK_A), spec.vk);
}

test "win32 hotkeySpecForTrigger maps unicode triggers with implicit shift" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const spec = hotkeySpecForTrigger(.{
        .key = .{ .unicode = '+' },
        .mods = .{ .alt = true },
    }).?;

    try std.testing.expectEqual(@as(UINT, c.MOD_ALT | c.MOD_SHIFT), spec.modifiers);
    try std.testing.expectEqual(@as(UINT, c.VK_OEM_PLUS), spec.vk);
}

test "win32 hotkeySpecForTrigger rejects unsupported catch-all triggers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(hotkeySpecForTrigger(.{
        .key = .catch_all,
        .mods = .{ .ctrl = true },
    }) == null);
}

test "win32 hotkeySpecEql detects duplicate resolved triggers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const physical = hotkeySpecForTrigger(.{
        .key = .{ .physical = .backquote },
        .mods = .{ .ctrl = true },
    }).?;
    const unicode = hotkeySpecForTrigger(.{
        .key = .{ .unicode = '`' },
        .mods = .{ .ctrl = true },
    }).?;
    const shifted = hotkeySpecForTrigger(.{
        .key = .{ .unicode = '~' },
        .mods = .{ .ctrl = true },
    }).?;

    try std.testing.expect(hotkeySpecEql(physical, unicode));
    try std.testing.expect(!hotkeySpecEql(physical, shifted));
}

test "win32 hotkeyRegistrationFailureReason names conflicts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expectEqualStrings(
        "already registered by another app or another noctty instance",
        hotkeyRegistrationFailureReason(.HOTKEY_ALREADY_REGISTERED),
    );
    try std.testing.expectEqualStrings(
        "access denied; hotkey may be reserved, occupied by an elevated app, or blocked by policy",
        hotkeyRegistrationFailureReason(.ACCESS_DENIED),
    );
}

test "win32 XButton wParam decoding maps forward and back buttons" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // XBUTTON1 in HIWORD of wParam
    const wp1 = (@as(usize, c.XBUTTON1) << 16) | @as(usize, c.MK_XBUTTON1);
    try std.testing.expectEqual(c.XBUTTON1, highWord(wp1));

    // XBUTTON2 in HIWORD of wParam
    const wp2 = (@as(usize, c.XBUTTON2) << 16) | @as(usize, c.MK_XBUTTON2);
    try std.testing.expectEqual(c.XBUTTON2, highWord(wp2));
}

test "win32 quick select treats synthetic AltGr as label text instead of an action" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var state: [256]u8 = [_]u8{0} ** 256;
    state[c.VK_CONTROL] = 0x80;
    state[c.VK_LCONTROL] = 0x80;
    state[c.VK_MENU] = 0x80;
    state[c.VK_RMENU] = 0x80;
    const altgr = withoutSyntheticAltGr(modsFromKeyboardState(&state));
    try std.testing.expect(!altgr.ctrl);
    try std.testing.expect(!altgr.alt);

    state[c.VK_RMENU] = 0;
    state[c.VK_LMENU] = 0x80;
    const explicit = withoutSyntheticAltGr(modsFromKeyboardState(&state));
    try std.testing.expect(explicit.ctrl);
    try std.testing.expect(explicit.alt);
}

test "win32 normalizeWheelDelta maps discrete wheel steps to pixel deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 3, .chars = 5 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 120);

    try std.testing.expectApproxEqAbs(48.0, event.yoff, 0.0001);
    try std.testing.expectEqual(@as(f64, 0), event.xoff);
    try std.testing.expect(!event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta maps horizontal wheel steps to pixel deltas" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 3, .chars = 5 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .horizontal, 120);

    try std.testing.expectApproxEqAbs(40.0, event.xoff, 0.0001);
    try std.testing.expectEqual(@as(f64, 0), event.yoff);
    try std.testing.expect(!event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta scales high-resolution input proportionally" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 3, .chars = 3 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 40);

    try std.testing.expectApproxEqAbs(16.0 / 3.0, event.yoff, 0.0001);
    try std.testing.expect(event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta honors page scroll settings" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = c.WHEEL_PAGESCROLL, .chars = 3 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 120);

    try std.testing.expectApproxEqAbs(584.0, event.yoff, 0.0001);
    try std.testing.expect(!event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta ignores page scroll settings for high-resolution input" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = c.WHEEL_PAGESCROLL, .chars = 3 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 40);

    try std.testing.expectApproxEqAbs(16.0 / 3.0, event.yoff, 0.0001);
    try std.testing.expect(event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

test "win32 normalizeWheelDelta ignores disabled notch settings for high-resolution input" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const event = normalizeWheelDelta(.{
        .settings = .{ .lines = 0, .chars = 0 },
        .cell_size = .{ .width = 8, .height = 16 },
        .viewport = .{ .width = 800, .height = 600 },
    }, .vertical, 40);

    try std.testing.expectApproxEqAbs(16.0 / 3.0, event.yoff, 0.0001);
    try std.testing.expect(event.mods.precision);
    try std.testing.expect(event.mods.pixel_delta);
}

// End of input declarations.
