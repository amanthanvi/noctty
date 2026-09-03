//! Windows UIA control-type / property IDs.
//!
//! Values come from uiautomationclient.h. Only the IDs we actually use
//! from this codebase are declared; the full tables live in the SDK.

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
pub const UIA_HasKeyboardFocusPropertyId: i32 = 30008;
pub const UIA_IsEnabledPropertyId: i32 = 30010;
pub const UIA_HelpTextPropertyId: i32 = 30013;
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
