//! noctty UI Automation — public module.
//!
//! Exposes enough of the UIA contract that:
//!   * The host HWND answers WM_GETOBJECT with a working root provider.
//!   * Narrator / NVDA can reach the window and see ControlType=Window.
//!   * The system's built-in host provider chains in, so caption
//!     buttons are still announced.
//!
//! Per-widget providers (tabs, command palette rows, settings fields)
//! are added with the widgets they expose. Terminal text is exposed
//! through a read-only `ITextProvider` / `ITextRangeProvider` slice.

const std = @import("std");
const com = @import("com.zig");
const constants = @import("constants.zig");
const root = @import("root.zig");
const text = @import("text.zig");
pub const events = @import("events.zig");
pub const widgets = @import("widgets.zig");

pub const RootProvider = root.RootProvider;
pub const OffsetRange = text.OffsetRange;
pub const TerminalTextSnapshot = text.TerminalTextSnapshot;
pub const AccessibleTextSnapshot = text.AccessibleTextSnapshot;
pub const TerminalCellPosition = text.TerminalCellPosition;
pub const PaletteListProvider = widgets.PaletteListProvider;
pub const PaletteListState = widgets.PaletteListState;
pub const PaletteListGeometry = widgets.PaletteListGeometry;
pub const PaletteListRowBounds = widgets.PaletteListRowBounds;
pub const SettingsSectionGroupProvider = widgets.SettingsSectionGroupProvider;
pub const SettingsSectionProvider = widgets.SettingsSectionProvider;
pub const SettingsControlProvider = widgets.SettingsControlProvider;
pub const ChromeControlProvider = widgets.ChromeControlProvider;
pub const ChromeControlState = widgets.ChromeControlState;
pub const ChromeRangeValue = widgets.ChromeRangeValue;
pub const TerminalProvider = widgets.TerminalProvider;
pub const TerminalState = widgets.TerminalState;
pub const TerminalSnapshot = widgets.TerminalSnapshot;
pub const handlePaletteListGetObject = widgets.handlePaletteListGetObject;
pub const returnSettingsSectionProvider = widgets.returnSettingsSectionProvider;
pub const returnSettingsSectionGroupProvider = widgets.returnSettingsSectionGroupProvider;
pub const returnSettingsControlProvider = widgets.returnSettingsControlProvider;
pub const returnPaletteListProvider = widgets.returnPaletteListProvider;
pub const returnChromeControlProvider = widgets.returnChromeControlProvider;
pub const handleTerminalGetObject = widgets.handleTerminalGetObject;
pub const returnTerminalProvider = widgets.returnTerminalProvider;
pub const returnRootProvider = root.returnProvider;
pub const HRESULT = com.HRESULT;
pub const S_OK = com.S_OK;
pub const RPC_E_CANTCALLOUT_ININPUTSYNCCALL = com.RPC_E_CANTCALLOUT_ININPUTSYNCCALL;
pub const UiaRootObjectId = com.UiaRootObjectId;
pub const IRawElementProviderSimple = com.IRawElementProviderSimple;
pub const disconnectAllProviders = com.UiaDisconnectAllProviders;
pub const snapshotTerminalPlainText = text.snapshotTerminalPlainText;
pub const snapshotTerminalVisiblePlainText = text.snapshotTerminalVisiblePlainText;
pub const snapshotTerminalAccessiblePlainText = text.snapshotTerminalAccessiblePlainText;
pub const visibleRangeInDocument = text.visibleRangeInDocument;

/// Handle `WM_GETOBJECT` for the main host HWND. Returns `null` if the
/// caller should fall through to `DefWindowProcW`; otherwise returns
/// the `LRESULT` the window proc should return directly.
///
/// Creates a new `RootProvider` per call; `UiaReturnRawElementProvider`
/// takes an AddRef internally so we drop our local reference before
/// returning. If the provider cannot be built (OOM, WinRT-less sandbox),
/// returns `null` and lets the system fall back to its default
/// accessibility tree — that is safer than returning a partial provider
/// for unsupported UIA surface.
pub fn handleGetObject(
    alloc: std.mem.Allocator,
    hwnd: com.HWND,
    wParam: com.WPARAM,
    lParam: com.LPARAM,
) ?com.LRESULT {
    // Only the UIA root object ID is handled here; other
    // accessibility queries (MSAA IAccessible, etc.) fall through.
    if (lParam != com.UiaRootObjectId) return null;

    const provider = root.RootProvider.create(alloc, hwnd) catch |err| {
        std.log.warn("uia: RootProvider.create failed err={}", .{err});
        return null;
    };
    defer _ = root.RootProvider.Release(&provider.base);

    const lr = com.UiaReturnRawElementProvider(hwnd, wParam, lParam, &provider.base);
    return lr;
}

test {
    // Force comptime analysis of the child modules so their tests are
    // discoverable from the UIA module entry.
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(com);
    std.testing.refAllDecls(constants);
    std.testing.refAllDecls(root);
    std.testing.refAllDecls(text);
    std.testing.refAllDecls(events);
    std.testing.refAllDecls(widgets);
}
