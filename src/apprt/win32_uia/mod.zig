//! noctty UI Automation — public module.
//!
//! Exposes enough of the UIA contract that:
//!   * The host HWND answers WM_GETOBJECT with a working root provider.
//!   * Narrator / NVDA can reach the window and see ControlType=Window.
//!   * The system's built-in host provider chains in, so the stock
//!     caption is still announced.
//!   * The integrated titlebar's custom-painted caption buttons, which
//!     have no HWND at all, are fragment children of that root.
//!
//! Per-widget providers (tabs, command palette rows, settings fields)
//! are added with the widgets they expose. Terminal text is exposed by
//! `TerminalProvider` as a read-only `ITextProvider` / `ITextRangeProvider`
//! over a bounded `AccessibleTextSnapshot`.

const std = @import("std");
const com = @import("com.zig");
const constants = @import("constants.zig");
const root = @import("root.zig");
const text = @import("text.zig");
pub const events = @import("events.zig");
pub const widgets = @import("widgets.zig");

pub const RootProvider = root.RootProvider;
pub const CaptionButtonProvider = root.CaptionButtonProvider;
pub const CaptionButtonKind = root.CaptionButtonKind;
pub const CaptionButtonsState = root.CaptionButtonsState;
pub const captionButtonName = root.captionButtonName;
pub const UiaRect = com.UiaRect;
pub const OffsetRange = text.OffsetRange;
pub const AccessibleTextSnapshot = text.AccessibleTextSnapshot;
pub const TerminalCellPosition = text.TerminalCellPosition;
pub const PaletteListProvider = widgets.PaletteListProvider;
pub const PaletteListState = widgets.PaletteListState;
pub const PaletteListGeometry = widgets.PaletteListGeometry;
pub const PaletteListRowBounds = widgets.PaletteListRowBounds;
pub const SettingsSectionGroupProvider = widgets.SettingsSectionGroupProvider;
pub const SettingsSectionProvider = widgets.SettingsSectionProvider;
pub const SettingsSectionMarker = widgets.SettingsSectionMarker;
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
pub const returnTerminalProvider = widgets.returnTerminalProvider;
pub const returnRootProvider = root.returnProvider;
pub const HRESULT = com.HRESULT;
pub const S_OK = com.S_OK;
pub const RPC_E_CANTCALLOUT_ININPUTSYNCCALL = com.RPC_E_CANTCALLOUT_ININPUTSYNCCALL;
pub const UiaRootObjectId = com.UiaRootObjectId;
pub const IRawElementProviderSimple = com.IRawElementProviderSimple;
pub const disconnectAllProviders = com.UiaDisconnectAllProviders;
pub const snapshotTerminalAccessiblePlainText = text.snapshotTerminalAccessiblePlainText;

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
