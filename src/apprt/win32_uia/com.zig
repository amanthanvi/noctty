//! Minimal COM vtable declarations for Windows UI Automation.
//!
//! Only interfaces with active providers are declared here. Add each
//! additional UIA interface with the widget or provider that consumes it.

const std = @import("std");
const windows = std.os.windows;

pub const HRESULT = windows.HRESULT;
pub const HWND = windows.HWND;
pub const GUID = windows.GUID;
pub const BOOL = windows.BOOL;
pub const LRESULT = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const BSTR = ?[*:0]u16;

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040201));
pub const UIA_E_ELEMENTNOTENABLED: HRESULT = @bitCast(@as(u32, 0x80040200));
pub const UIA_E_INVALIDOPERATION: HRESULT = @bitCast(@as(u32, 0x80131509));
pub const RPC_E_CANTCALLOUT_ININPUTSYNCCALL: HRESULT = @bitCast(@as(u32, 0x8001010D));

// COM GUIDs (IID = interface ID).
pub const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
pub const IID_IRawElementProviderSimple = GUID.parse("{D6DD68D1-86FD-4332-8666-9ABEDEA2D24C}");
pub const IID_IRawElementProviderFragment = GUID.parse("{F7063DA8-8359-439C-9297-BBC5299A7D87}");
pub const IID_IRawElementProviderFragmentRoot = GUID.parse("{620CE2A5-AB8F-40A9-86CB-DE3C75599B58}");
pub const IID_ISelectionProvider = GUID.parse("{FB8B03AF-3BDF-48D4-BD36-1A65793BE168}");
pub const IID_ISelectionItemProvider = GUID.parse("{2ACAD808-B2D4-452D-A407-91FF1AD167B2}");
pub const IID_IValueProvider = GUID.parse("{C7935180-6FB3-4201-B174-7DF73ADBF64A}");
pub const IID_ITextProvider = GUID.parse("{3589C92C-63F3-4367-99BB-ADA653B77CF2}");
pub const IID_ITextProvider2 = GUID.parse("{0DC5E6ED-3E16-4BF1-8F9A-A979878BC195}");
pub const IID_ITextRangeProvider = GUID.parse("{5347AD7B-C355-46F8-AFF5-909033582F63}");

/// UIA object IDs passed as WM_GETOBJECT.lParam by the system / client.
/// These are negative in the Windows headers; cast to LPARAM via bitcast.
pub const UiaRootObjectId: LPARAM = -25;

/// ProviderOptions flags for IRawElementProviderSimple::get_ProviderOptions.
pub const ProviderOptions_ServerSideProvider: i32 = 0x2;

/// VARIANT variant-type tags that we actually emit.
pub const VT_EMPTY: u16 = 0;
pub const VT_I4: u16 = 3;
pub const VT_R8: u16 = 5;
pub const VT_BSTR: u16 = 8;
pub const VT_BOOL: u16 = 11;
pub const VT_UNKNOWN: u16 = 13;

pub const VARIANT_TRUE: i16 = -1;
pub const VARIANT_FALSE: i16 = 0;

/// Simplified VARIANT covering only the fields we populate (I4, BSTR, BOOL).
/// The true OAIDL VARIANT is a 16-byte-header (vt + 3 reserved words) +
/// 8-byte payload union on 64-bit Windows. We mirror that layout.
///
/// We deliberately do NOT include a `raw` fill member — adding a second
/// pointer-sized field would blow the union past the real ABI size and
/// corrupt VARIANTs returned to the UIA host.
pub const VARIANT = extern struct {
    vt: u16,
    wReserved1: u16 = 0,
    wReserved2: u16 = 0,
    wReserved3: u16 = 0,
    value: extern union {
        i4: i32,
        bstr: BSTR,
        bool_val: i16,
        unknown: ?*IUnknown,
    },

    pub fn empty() VARIANT {
        return .{ .vt = VT_EMPTY, .value = .{ .bstr = null } };
    }

    pub fn fromI4(v: i32) VARIANT {
        return .{ .vt = VT_I4, .value = .{ .i4 = v } };
    }

    pub fn fromBstr(s: BSTR) VARIANT {
        return .{ .vt = VT_BSTR, .value = .{ .bstr = s } };
    }

    pub fn fromBool(b: bool) VARIANT {
        return .{
            .vt = VT_BOOL,
            .value = .{ .bool_val = if (b) VARIANT_TRUE else VARIANT_FALSE },
        };
    }

    pub fn fromUnknown(p: ?*IUnknown) VARIANT {
        return .{ .vt = VT_UNKNOWN, .value = .{ .unknown = p } };
    }

    // Compile-time assertion that our VARIANT matches the Windows ABI
    // layout: 8-byte header + 8-byte payload on x64 = 16 bytes.
    comptime {
        const expected_size: usize = if (@sizeOf(usize) == 8) 16 else 16;
        if (@sizeOf(VARIANT) != expected_size) {
            @compileError(std.fmt.comptimePrint(
                "VARIANT size mismatch: got {d}, expected {d}",
                .{ @sizeOf(VARIANT), expected_size },
            ));
        }
    }
};

// ── IUnknown ────────────────────────────────────────────────────────────

pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IUnknown) callconv(.winapi) u32,
    Release: *const fn (*IUnknown) callconv(.winapi) u32,
};

pub const IUnknown = extern struct {
    vtbl: *const IUnknownVtbl,
};

// ── IRawElementProviderSimple ───────────────────────────────────────────

pub const IRawElementProviderSimpleVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*IRawElementProviderSimple, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IRawElementProviderSimple) callconv(.winapi) u32,
    Release: *const fn (*IRawElementProviderSimple) callconv(.winapi) u32,

    // IRawElementProviderSimple
    get_ProviderOptions: *const fn (*IRawElementProviderSimple, *i32) callconv(.winapi) HRESULT,
    GetPatternProvider: *const fn (*IRawElementProviderSimple, i32, *?*IUnknown) callconv(.winapi) HRESULT,
    GetPropertyValue: *const fn (*IRawElementProviderSimple, i32, *VARIANT) callconv(.winapi) HRESULT,
    get_HostRawElementProvider: *const fn (*IRawElementProviderSimple, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT,
};

pub const IRawElementProviderSimple = extern struct {
    vtbl: *const IRawElementProviderSimpleVtbl,
};

// ── Fragment providers ─────────────────────────────────────────────────

pub const NavigateDirection_Parent: i32 = 0;
pub const NavigateDirection_NextSibling: i32 = 1;
pub const NavigateDirection_PreviousSibling: i32 = 2;
pub const NavigateDirection_FirstChild: i32 = 3;
pub const NavigateDirection_LastChild: i32 = 4;
pub const UiaAppendRuntimeId: i32 = 3;

pub const UiaRect = extern struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,
};

pub const IRawElementProviderFragmentVtbl = extern struct {
    QueryInterface: *const fn (*IRawElementProviderFragment, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IRawElementProviderFragment) callconv(.winapi) u32,
    Release: *const fn (*IRawElementProviderFragment) callconv(.winapi) u32,
    Navigate: *const fn (*IRawElementProviderFragment, i32, *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
    GetRuntimeId: *const fn (*IRawElementProviderFragment, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    get_BoundingRectangle: *const fn (*IRawElementProviderFragment, *UiaRect) callconv(.winapi) HRESULT,
    GetEmbeddedFragmentRoots: *const fn (*IRawElementProviderFragment, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    SetFocus: *const fn (*IRawElementProviderFragment) callconv(.winapi) HRESULT,
    get_FragmentRoot: *const fn (*IRawElementProviderFragment, *?*IRawElementProviderFragmentRoot) callconv(.winapi) HRESULT,
};

pub const IRawElementProviderFragment = extern struct {
    vtbl: *const IRawElementProviderFragmentVtbl,
};

pub const IRawElementProviderFragmentRootVtbl = extern struct {
    QueryInterface: *const fn (*IRawElementProviderFragmentRoot, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IRawElementProviderFragmentRoot) callconv(.winapi) u32,
    Release: *const fn (*IRawElementProviderFragmentRoot) callconv(.winapi) u32,
    ElementProviderFromPoint: *const fn (*IRawElementProviderFragmentRoot, f64, f64, *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
    GetFocus: *const fn (*IRawElementProviderFragmentRoot, *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
};

pub const IRawElementProviderFragmentRoot = extern struct {
    vtbl: *const IRawElementProviderFragmentRootVtbl,
};

// ── ISelectionProvider / ISelectionItemProvider ────────────────────────

pub const ISelectionProviderVtbl = extern struct {
    QueryInterface: *const fn (*ISelectionProvider, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ISelectionProvider) callconv(.winapi) u32,
    Release: *const fn (*ISelectionProvider) callconv(.winapi) u32,
    GetSelection: *const fn (*ISelectionProvider, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    get_CanSelectMultiple: *const fn (*ISelectionProvider, *BOOL) callconv(.winapi) HRESULT,
    get_IsSelectionRequired: *const fn (*ISelectionProvider, *BOOL) callconv(.winapi) HRESULT,
};

pub const ISelectionProvider = extern struct {
    vtbl: *const ISelectionProviderVtbl,
};

pub const ISelectionItemProviderVtbl = extern struct {
    QueryInterface: *const fn (*ISelectionItemProvider, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ISelectionItemProvider) callconv(.winapi) u32,
    Release: *const fn (*ISelectionItemProvider) callconv(.winapi) u32,
    Select: *const fn (*ISelectionItemProvider) callconv(.winapi) HRESULT,
    AddToSelection: *const fn (*ISelectionItemProvider) callconv(.winapi) HRESULT,
    RemoveFromSelection: *const fn (*ISelectionItemProvider) callconv(.winapi) HRESULT,
    get_IsSelected: *const fn (*ISelectionItemProvider, *BOOL) callconv(.winapi) HRESULT,
    get_SelectionContainer: *const fn (*ISelectionItemProvider, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT,
};

pub const ISelectionItemProvider = extern struct {
    vtbl: *const ISelectionItemProviderVtbl,
};

// ── IValueProvider ─────────────────────────────────────────────────────

pub const IValueProviderVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*IValueProvider, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IValueProvider) callconv(.winapi) u32,
    Release: *const fn (*IValueProvider) callconv(.winapi) u32,

    // IValueProvider
    SetValue: *const fn (*IValueProvider, [*:0]const u16) callconv(.winapi) HRESULT,
    get_Value: *const fn (*IValueProvider, *?[*:0]u16) callconv(.winapi) HRESULT,
    get_IsReadOnly: *const fn (*IValueProvider, *BOOL) callconv(.winapi) HRESULT,
};

pub const IValueProvider = extern struct {
    vtbl: *const IValueProviderVtbl,
};

// ── ITextProvider / ITextRangeProvider ─────────────────────────────────

pub const SAFEARRAY = opaque {};

pub const UiaPoint = extern struct {
    x: f64,
    y: f64,
};

pub const TextUnit_Character: i32 = 0;
pub const TextUnit_Format: i32 = 1;
pub const TextUnit_Word: i32 = 2;
pub const TextUnit_Line: i32 = 3;
pub const TextUnit_Paragraph: i32 = 4;
pub const TextUnit_Page: i32 = 5;
pub const TextUnit_Document: i32 = 6;

pub const TextPatternRangeEndpoint_Start: i32 = 0;
pub const TextPatternRangeEndpoint_End: i32 = 1;

pub const SupportedTextSelection_None: i32 = 0;
pub const SupportedTextSelection_Single: i32 = 1;
pub const SupportedTextSelection_Multiple: i32 = 2;

pub const ITextProviderVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ITextProvider, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ITextProvider) callconv(.winapi) u32,
    Release: *const fn (*ITextProvider) callconv(.winapi) u32,

    // ITextProvider
    GetSelection: *const fn (*ITextProvider, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    GetVisibleRanges: *const fn (*ITextProvider, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    RangeFromChild: *const fn (*ITextProvider, ?*IRawElementProviderSimple, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    RangeFromPoint: *const fn (*ITextProvider, UiaPoint, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    get_DocumentRange: *const fn (*ITextProvider, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    get_SupportedTextSelection: *const fn (*ITextProvider, *i32) callconv(.winapi) HRESULT,
};

pub const ITextProvider = extern struct {
    vtbl: *const ITextProviderVtbl,
};

pub const ITextProvider2Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ITextProvider2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ITextProvider2) callconv(.winapi) u32,
    Release: *const fn (*ITextProvider2) callconv(.winapi) u32,

    // ITextProvider
    GetSelection: *const fn (*ITextProvider2, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    GetVisibleRanges: *const fn (*ITextProvider2, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    RangeFromChild: *const fn (*ITextProvider2, ?*IRawElementProviderSimple, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    RangeFromPoint: *const fn (*ITextProvider2, UiaPoint, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    get_DocumentRange: *const fn (*ITextProvider2, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    get_SupportedTextSelection: *const fn (*ITextProvider2, *i32) callconv(.winapi) HRESULT,

    // ITextProvider2
    RangeFromAnnotation: *const fn (*ITextProvider2, ?*IRawElementProviderSimple, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    GetCaretRange: *const fn (*ITextProvider2, *BOOL, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
};

pub const ITextProvider2 = extern struct {
    vtbl: *const ITextProvider2Vtbl,
};

pub const ITextRangeProviderVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*ITextRangeProvider, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ITextRangeProvider) callconv(.winapi) u32,
    Release: *const fn (*ITextRangeProvider) callconv(.winapi) u32,

    // ITextRangeProvider
    Clone: *const fn (*ITextRangeProvider, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    Compare: *const fn (*ITextRangeProvider, ?*ITextRangeProvider, *BOOL) callconv(.winapi) HRESULT,
    CompareEndpoints: *const fn (*ITextRangeProvider, i32, ?*ITextRangeProvider, i32, *i32) callconv(.winapi) HRESULT,
    ExpandToEnclosingUnit: *const fn (*ITextRangeProvider, i32) callconv(.winapi) HRESULT,
    FindAttribute: *const fn (*ITextRangeProvider, i32, VARIANT, BOOL, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    FindText: *const fn (*ITextRangeProvider, ?[*]const u16, BOOL, BOOL, *?*ITextRangeProvider) callconv(.winapi) HRESULT,
    GetAttributeValue: *const fn (*ITextRangeProvider, i32, *VARIANT) callconv(.winapi) HRESULT,
    GetBoundingRectangles: *const fn (*ITextRangeProvider, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    GetEnclosingElement: *const fn (*ITextRangeProvider, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT,
    GetText: *const fn (*ITextRangeProvider, i32, *?[*:0]u16) callconv(.winapi) HRESULT,
    Move: *const fn (*ITextRangeProvider, i32, i32, *i32) callconv(.winapi) HRESULT,
    MoveEndpointByUnit: *const fn (*ITextRangeProvider, i32, i32, i32, *i32) callconv(.winapi) HRESULT,
    MoveEndpointByRange: *const fn (*ITextRangeProvider, i32, ?*ITextRangeProvider, i32) callconv(.winapi) HRESULT,
    Select: *const fn (*ITextRangeProvider) callconv(.winapi) HRESULT,
    AddToSelection: *const fn (*ITextRangeProvider) callconv(.winapi) HRESULT,
    RemoveFromSelection: *const fn (*ITextRangeProvider) callconv(.winapi) HRESULT,
    ScrollIntoView: *const fn (*ITextRangeProvider, BOOL) callconv(.winapi) HRESULT,
    GetChildren: *const fn (*ITextRangeProvider, *?*SAFEARRAY) callconv(.winapi) HRESULT,
};

pub const ITextRangeProvider = extern struct {
    vtbl: *const ITextRangeProviderVtbl,
};

// ── StructureChangeType ─────────────────────────────────────────────────
// Values for UiaRaiseStructureChangedEvent's second parameter. From
// uiautomationcore.h.

pub const StructureChangeType_ChildAdded: i32 = 0;
pub const StructureChangeType_ChildRemoved: i32 = 1;
pub const StructureChangeType_ChildrenInvalidated: i32 = 2;
pub const StructureChangeType_ChildrenBulkAdded: i32 = 3;
pub const StructureChangeType_ChildrenBulkRemoved: i32 = 4;
pub const StructureChangeType_ChildrenReordered: i32 = 5;

pub const NotificationKind_ActionCompleted: i32 = 2;
pub const NotificationKind_ActionAborted: i32 = 3;
pub const NotificationKind_Other: i32 = 4;
pub const NotificationProcessing_MostRecent: i32 = 3;

// ── UIA externs ─────────────────────────────────────────────────────────

/// `UiaReturnRawElementProvider` packages our provider together with the
/// default host provider and returns the LRESULT the WM_GETOBJECT handler
/// should return.
pub extern "uiautomationcore" fn UiaReturnRawElementProvider(
    hwnd: HWND,
    wParam: WPARAM,
    lParam: LPARAM,
    el: ?*IRawElementProviderSimple,
) callconv(.winapi) LRESULT;

/// `UiaHostProviderFromHwnd` returns the system's default provider for
/// a top-level window. Our root provider chains to it via
/// `get_HostRawElementProvider`.
pub extern "uiautomationcore" fn UiaHostProviderFromHwnd(
    hwnd: HWND,
    out: *?*IRawElementProviderSimple,
) callconv(.winapi) HRESULT;

/// Raise a plain automation event (focus changed, selection invalidated,
/// etc.). The eventId must come from the `UIA_*EventId` constants.
pub extern "uiautomationcore" fn UiaRaiseAutomationEvent(
    provider: *IRawElementProviderSimple,
    eventId: i32,
) callconv(.winapi) HRESULT;

/// Raise a structure-changed event. For ChildAdded / ChildRemoved the
/// runtimeId of the affected child may be passed; pass null + 0 for the
/// ChildrenInvalidated form.
pub extern "uiautomationcore" fn UiaRaiseStructureChangedEvent(
    provider: *IRawElementProviderSimple,
    structureChangeType: i32,
    pRuntimeId: ?[*]i32,
    cRuntimeIdLen: i32,
) callconv(.winapi) HRESULT;

/// Raise a property-changed event (value toggles, name updates, etc.).
/// The VARIANTs are passed by value; uiautomationcore owns no copies.
pub extern "uiautomationcore" fn UiaRaiseAutomationPropertyChangedEvent(
    provider: *IRawElementProviderSimple,
    propertyId: i32,
    oldValue: VARIANT,
    newValue: VARIANT,
) callconv(.winapi) HRESULT;

pub extern "uiautomationcore" fn UiaRaiseNotificationEvent(
    provider: *IRawElementProviderSimple,
    notification_kind: i32,
    notification_processing: i32,
    display_string: BSTR,
    activity_id: BSTR,
) callconv(.winapi) HRESULT;

/// Report whether a UIA client is currently listening for a given event
/// so we can skip the raise entirely when nobody cares.
pub extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) BOOL;
pub extern "uiautomationcore" fn UiaDisconnectProvider(provider: *IRawElementProviderSimple) callconv(.winapi) HRESULT;
pub extern "uiautomationcore" fn UiaDisconnectAllProviders() callconv(.winapi) HRESULT;
pub extern "uiautomationcore" fn UiaGetReservedNotSupportedValue(value: *?*IUnknown) callconv(.winapi) HRESULT;

/// BSTR alloc / free helpers for the string properties (Name, LocalizedControlType).
pub extern "oleaut32" fn SysAllocString(psz: [*:0]const u16) callconv(.winapi) BSTR;
pub extern "oleaut32" fn SysAllocStringLen(psz: ?[*]const u16, len: u32) callconv(.winapi) BSTR;
pub extern "oleaut32" fn SysFreeString(bstr: BSTR) callconv(.winapi) void;
pub extern "oleaut32" fn SysStringLen(bstr: ?[*]const u16) callconv(.winapi) u32;
pub extern "oleaut32" fn SafeArrayCreateVector(vt: u16, lLbound: i32, cElements: u32) callconv(.winapi) ?*SAFEARRAY;
pub extern "oleaut32" fn SafeArrayPutElement(psa: *SAFEARRAY, rgIndices: *i32, pv: ?*anyopaque) callconv(.winapi) HRESULT;
pub extern "oleaut32" fn SafeArrayGetElement(psa: *SAFEARRAY, rgIndices: *i32, pv: *anyopaque) callconv(.winapi) HRESULT;
pub extern "oleaut32" fn SafeArrayGetLBound(psa: *SAFEARRAY, nDim: u32, plLbound: *i32) callconv(.winapi) HRESULT;
pub extern "oleaut32" fn SafeArrayGetUBound(psa: *SAFEARRAY, nDim: u32, plUbound: *i32) callconv(.winapi) HRESULT;
pub extern "oleaut32" fn SafeArrayDestroy(psa: ?*SAFEARRAY) callconv(.winapi) HRESULT;

/// Live HWND text query. Used by the UIA Name provider so screen
/// readers see the current window title after a rename.
pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) i32;
pub extern "user32" fn GetWindowTextW(
    hWnd: HWND,
    lpString: [*]u16,
    nMaxCount: i32,
) callconv(.winapi) i32;

test "HRESULT error constants" {
    try std.testing.expect(E_NOTIMPL != S_OK);
    try std.testing.expect(E_POINTER != S_OK);
    try std.testing.expect(E_NOINTERFACE != S_OK);
    try std.testing.expect(E_OUTOFMEMORY != S_OK);
}

test "VARIANT empty has zero vt" {
    const v = VARIANT.empty();
    try std.testing.expectEqual(@as(u16, VT_EMPTY), v.vt);
}

test "VARIANT fromI4 stores integer" {
    const v = VARIANT.fromI4(42);
    try std.testing.expectEqual(@as(u16, VT_I4), v.vt);
    try std.testing.expectEqual(@as(i32, 42), v.value.i4);
}

test "VARIANT fromBstr stores pointer" {
    const sample = std.unicode.utf8ToUtf16LeStringLiteral("hello");
    const v = VARIANT.fromBstr(@constCast(sample));
    try std.testing.expectEqual(@as(u16, VT_BSTR), v.vt);
    try std.testing.expectEqual(@as(?[*:0]u16, @constCast(sample)), v.value.bstr);
}
