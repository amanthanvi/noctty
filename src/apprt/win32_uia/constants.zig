//! Windows UIA control-type / property IDs.
//!
//! Values come from uiautomationclient.h. Only the IDs we actually use
//! from this codebase are declared; the full tables live in the SDK.

// ── Control types ───────────────────────────────────────────────────────
// UIA_ControlTypeId values. 50000-series.

pub const UIA_ListControlTypeId: i32 = 50008;
pub const UIA_DocumentControlTypeId: i32 = 50030;
pub const UIA_WindowControlTypeId: i32 = 50032;

// ── Pattern IDs ────────────────────────────────────────────────────────

pub const UIA_ValuePatternId: i32 = 10002;

// ── Properties ──────────────────────────────────────────────────────────
// UIA_PropertyId values. 30000-series.

pub const UIA_ControlTypePropertyId: i32 = 30003;
pub const UIA_LocalizedControlTypePropertyId: i32 = 30004;
pub const UIA_NamePropertyId: i32 = 30005;
pub const UIA_IsKeyboardFocusablePropertyId: i32 = 30009;
pub const UIA_HasKeyboardFocusPropertyId: i32 = 30008;
pub const UIA_IsEnabledPropertyId: i32 = 30010;
pub const UIA_HelpTextPropertyId: i32 = 30013;
pub const UIA_FrameworkIdPropertyId: i32 = 30024;
pub const UIA_ValueValuePropertyId: i32 = 30045;
pub const UIA_ValueIsReadOnlyPropertyId: i32 = 30046;
pub const UIA_IsControlElementPropertyId: i32 = 30016;
pub const UIA_IsContentElementPropertyId: i32 = 30017;

// ── Event IDs ──────────────────────────────────────────────────────────

pub const UIA_AutomationFocusChangedEventId: i32 = 20005;
pub const UIA_StructureChangedEventId: i32 = 20002;
pub const UIA_Selection_InvalidatedEventId: i32 = 20013;
