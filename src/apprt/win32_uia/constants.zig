//! Windows UIA control-type / property IDs.
//!
//! Values come from uiautomationclient.h. Only the IDs we actually use
//! from this codebase are declared; the full tables live in the SDK.

const std = @import("std");

// ── Control types ───────────────────────────────────────────────────────
// UIA_ControlTypeId values. 50000-series.

pub const UIA_ButtonControlTypeId: i32 = 50000;
pub const UIA_CheckBoxControlTypeId: i32 = 50002;
pub const UIA_ComboBoxControlTypeId: i32 = 50003;
pub const UIA_ListControlTypeId: i32 = 50008;
pub const UIA_ListItemControlTypeId: i32 = 50007;
pub const UIA_EditControlTypeId: i32 = 50004;
pub const UIA_RadioButtonControlTypeId: i32 = 50013;
pub const UIA_ScrollBarControlTypeId: i32 = 50014;
pub const UIA_TabControlTypeId: i32 = 50018;
pub const UIA_TabItemControlTypeId: i32 = 50019;
pub const UIA_TextControlTypeId: i32 = 50020;
pub const UIA_DocumentControlTypeId: i32 = 50030;
pub const UIA_WindowControlTypeId: i32 = 50032;
pub const UIA_PaneControlTypeId: i32 = 50033;
pub const UIA_ToolTipControlTypeId: i32 = 50022;

// ── Pattern IDs ────────────────────────────────────────────────────────

pub const UIA_ValuePatternId: i32 = 10002;
pub const UIA_InvokePatternId: i32 = 10000;
pub const UIA_SelectionPatternId: i32 = 10001;
pub const UIA_TextPatternId: i32 = 10014;
pub const UIA_TextPattern2Id: i32 = 10024;
pub const UIA_SelectionItemPatternId: i32 = 10010;
pub const UIA_RangeValuePatternId: i32 = 10003;
pub const UIA_TogglePatternId: i32 = 10015;

// ── Properties ──────────────────────────────────────────────────────────
// UIA_PropertyId values. 30000-series.

pub const UIA_ControlTypePropertyId: i32 = 30003;
pub const UIA_LocalizedControlTypePropertyId: i32 = 30004;
pub const UIA_NamePropertyId: i32 = 30005;
pub const UIA_IsKeyboardFocusablePropertyId: i32 = 30009;
pub const UIA_IsOffscreenPropertyId: i32 = 30022;
pub const UIA_LabeledByPropertyId: i32 = 30018;
pub const UIA_HasKeyboardFocusPropertyId: i32 = 30008;
pub const UIA_IsEnabledPropertyId: i32 = 30010;
pub const UIA_HelpTextPropertyId: i32 = 30013;
pub const UIA_ItemStatusPropertyId: i32 = 30026;
pub const UIA_IsDataValidForFormPropertyId: i32 = 30103;
pub const UIA_FrameworkIdPropertyId: i32 = 30024;
pub const UIA_ValueValuePropertyId: i32 = 30045;
pub const UIA_ValueIsReadOnlyPropertyId: i32 = 30046;
pub const UIA_IsControlElementPropertyId: i32 = 30016;
pub const UIA_IsContentElementPropertyId: i32 = 30017;
pub const UIA_SelectionItemIsSelectedPropertyId: i32 = 30079;
pub const UIA_RangeValueValuePropertyId: i32 = 30047;
pub const UIA_RangeValueIsReadOnlyPropertyId: i32 = 30048;
pub const UIA_RangeValueMinimumPropertyId: i32 = 30049;
pub const UIA_RangeValueMaximumPropertyId: i32 = 30050;
pub const UIA_RangeValueLargeChangePropertyId: i32 = 30051;
pub const UIA_RangeValueSmallChangePropertyId: i32 = 30052;
pub const UIA_ToggleToggleStatePropertyId: i32 = 30086;
pub const UIA_LiveSettingPropertyId: i32 = 30135;

pub const LiveSetting_Off: i32 = 0;
pub const LiveSetting_Polite: i32 = 1;
pub const LiveSetting_Assertive: i32 = 2;

// ── Event IDs ──────────────────────────────────────────────────────────

pub const UIA_Invoke_InvokedEventId: i32 = 20009;
pub const UIA_AutomationFocusChangedEventId: i32 = 20005;
pub const UIA_StructureChangedEventId: i32 = 20002;
pub const UIA_Selection_InvalidatedEventId: i32 = 20013;
pub const UIA_SelectionItem_ElementSelectedEventId: i32 = 20012;
pub const UIA_Text_TextChangedEventId: i32 = 20015;
pub const UIA_Text_TextSelectionChangedEventId: i32 = 20014;
pub const UIA_LiveRegionChangedEventId: i32 = 20024;

test "ids match the Windows SDK headers" {
    @setEvalBranchQuota(20_000);
    // Values from UIAutomationClient.h (control types, patterns, properties,
    // events) and UIAutomationCore.h (LiveSetting), Windows SDK 10.0.26100.0.
    // A typo here is invisible to the compiler and reaches screen readers as
    // an undefined id (the tooltip was 50042 where the SDK says 50022), so
    // every constant is pinned and a new one fails here until it is added.
    const sdk = [_]struct { []const u8, i32 }{
        .{ "UIA_ButtonControlTypeId", 50000 },
        .{ "UIA_CheckBoxControlTypeId", 50002 },
        .{ "UIA_ComboBoxControlTypeId", 50003 },
        .{ "UIA_ListControlTypeId", 50008 },
        .{ "UIA_ListItemControlTypeId", 50007 },
        .{ "UIA_EditControlTypeId", 50004 },
        .{ "UIA_RadioButtonControlTypeId", 50013 },
        .{ "UIA_ScrollBarControlTypeId", 50014 },
        .{ "UIA_TabControlTypeId", 50018 },
        .{ "UIA_TabItemControlTypeId", 50019 },
        .{ "UIA_TextControlTypeId", 50020 },
        .{ "UIA_DocumentControlTypeId", 50030 },
        .{ "UIA_WindowControlTypeId", 50032 },
        .{ "UIA_PaneControlTypeId", 50033 },
        .{ "UIA_ToolTipControlTypeId", 50022 },
        .{ "UIA_ValuePatternId", 10002 },
        .{ "UIA_InvokePatternId", 10000 },
        .{ "UIA_SelectionPatternId", 10001 },
        .{ "UIA_TextPatternId", 10014 },
        .{ "UIA_TextPattern2Id", 10024 },
        .{ "UIA_SelectionItemPatternId", 10010 },
        .{ "UIA_RangeValuePatternId", 10003 },
        .{ "UIA_TogglePatternId", 10015 },
        .{ "UIA_ControlTypePropertyId", 30003 },
        .{ "UIA_LocalizedControlTypePropertyId", 30004 },
        .{ "UIA_NamePropertyId", 30005 },
        .{ "UIA_IsKeyboardFocusablePropertyId", 30009 },
        .{ "UIA_IsOffscreenPropertyId", 30022 },
        .{ "UIA_LabeledByPropertyId", 30018 },
        .{ "UIA_HasKeyboardFocusPropertyId", 30008 },
        .{ "UIA_IsEnabledPropertyId", 30010 },
        .{ "UIA_HelpTextPropertyId", 30013 },
        .{ "UIA_ItemStatusPropertyId", 30026 },
        .{ "UIA_IsDataValidForFormPropertyId", 30103 },
        .{ "UIA_FrameworkIdPropertyId", 30024 },
        .{ "UIA_ValueValuePropertyId", 30045 },
        .{ "UIA_ValueIsReadOnlyPropertyId", 30046 },
        .{ "UIA_IsControlElementPropertyId", 30016 },
        .{ "UIA_IsContentElementPropertyId", 30017 },
        .{ "UIA_SelectionItemIsSelectedPropertyId", 30079 },
        .{ "UIA_RangeValueValuePropertyId", 30047 },
        .{ "UIA_RangeValueIsReadOnlyPropertyId", 30048 },
        .{ "UIA_RangeValueMinimumPropertyId", 30049 },
        .{ "UIA_RangeValueMaximumPropertyId", 30050 },
        .{ "UIA_RangeValueLargeChangePropertyId", 30051 },
        .{ "UIA_RangeValueSmallChangePropertyId", 30052 },
        .{ "UIA_ToggleToggleStatePropertyId", 30086 },
        .{ "UIA_LiveSettingPropertyId", 30135 },
        .{ "LiveSetting_Off", 0 },
        .{ "LiveSetting_Polite", 1 },
        .{ "LiveSetting_Assertive", 2 },
        .{ "UIA_Invoke_InvokedEventId", 20009 },
        .{ "UIA_AutomationFocusChangedEventId", 20005 },
        .{ "UIA_StructureChangedEventId", 20002 },
        .{ "UIA_Selection_InvalidatedEventId", 20013 },
        .{ "UIA_SelectionItem_ElementSelectedEventId", 20012 },
        .{ "UIA_Text_TextChangedEventId", 20015 },
        .{ "UIA_Text_TextSelectionChangedEventId", 20014 },
        .{ "UIA_LiveRegionChangedEventId", 20024 },
    };
    inline for (sdk) |entry| {
        try std.testing.expectEqual(entry[1], @field(@This(), entry[0]));
    }
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        if (@TypeOf(@field(@This(), decl.name)) != i32) continue;
        const pinned = inline for (sdk) |entry| {
            if (comptime std.mem.eql(u8, entry[0], decl.name)) break true;
        } else false;
        try std.testing.expect(pinned);
    }
}
