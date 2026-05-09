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

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));

// COM GUIDs (IID = interface ID).
pub const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
pub const IID_IRawElementProviderSimple = GUID.parse("{D6DD68D1-86FD-4332-8666-9ABEDEA2D24C}");
pub const IID_IValueProvider = GUID.parse("{C7935180-6FB3-4201-B174-7DF73ADBF64A}");

/// UIA object IDs passed as WM_GETOBJECT.lParam by the system / client.
/// These are negative in the Windows headers; cast to LPARAM via bitcast.
pub const UiaRootObjectId: LPARAM = -25;

/// ProviderOptions flags for IRawElementProviderSimple::get_ProviderOptions.
pub const ProviderOptions_ServerSideProvider: i32 = 0x2;

/// VARIANT variant-type tags that we actually emit.
pub const VT_EMPTY: u16 = 0;
pub const VT_I4: u16 = 3;
pub const VT_BSTR: u16 = 8;
pub const VT_BOOL: u16 = 11;

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
        bstr: ?[*:0]u16,
        bool_val: i16,
    },

    pub fn empty() VARIANT {
        return .{ .vt = VT_EMPTY, .value = .{ .bstr = null } };
    }

    pub fn fromI4(v: i32) VARIANT {
        return .{ .vt = VT_I4, .value = .{ .i4 = v } };
    }

    pub fn fromBstr(s: ?[*:0]u16) VARIANT {
        return .{ .vt = VT_BSTR, .value = .{ .bstr = s } };
    }

    pub fn fromBool(b: bool) VARIANT {
        return .{
            .vt = VT_BOOL,
            .value = .{ .bool_val = if (b) VARIANT_TRUE else VARIANT_FALSE },
        };
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

// ── StructureChangeType ─────────────────────────────────────────────────
// Values for UiaRaiseStructureChangedEvent's second parameter. From
// uiautomationcore.h.

pub const StructureChangeType_ChildAdded: i32 = 0;
pub const StructureChangeType_ChildRemoved: i32 = 1;
pub const StructureChangeType_ChildrenInvalidated: i32 = 2;
pub const StructureChangeType_ChildrenBulkAdded: i32 = 3;
pub const StructureChangeType_ChildrenBulkRemoved: i32 = 4;
pub const StructureChangeType_ChildrenReordered: i32 = 5;

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

/// Report whether a UIA client is currently listening for a given event
/// so we can skip the raise entirely when nobody cares.
pub extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) BOOL;

/// BSTR alloc / free helpers for the string properties (Name, LocalizedControlType).
pub extern "oleaut32" fn SysAllocString(psz: [*:0]const u16) callconv(.winapi) ?[*:0]u16;
pub extern "oleaut32" fn SysFreeString(bstr: ?[*:0]u16) callconv(.winapi) void;

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
