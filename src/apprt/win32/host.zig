//! Win32 host window and chrome state.
const win32 = @import("../win32.zig");
const Allocator = win32.Allocator;
const App = win32.App;
const BOOL = win32.BOOL;
const BannerButton = win32.BannerButton;
const ButtonTooltipAction = win32.ButtonTooltipAction;
const CaptionButton = win32.CaptionButton;
const ChildPlacement = win32.ChildPlacement;
const ChromeRepaintMask = win32.ChromeRepaintMask;
const ChromeTextDirty = win32.ChromeTextDirty;
const CloseScope = win32.CloseScope;
const ConfirmPayload = win32.ConfirmPayload;
const ConfirmPrompt = win32.ConfirmPrompt;
const ConfirmTextPlacement = win32.ConfirmTextPlacement;
const DRAWITEMSTRUCT = win32.DRAWITEMSTRUCT;
const DWORD = win32.DWORD;
const HBRUSH = win32.HBRUSH;
const HDC = win32.HDC;
const HGDIOBJ = win32.HGDIOBJ;
const HWND = win32.HWND;
const HostBannerKind = win32.HostBannerKind;
const HostOverlayMode = win32.HostOverlayMode;
const IconFontChoice = win32.IconFontChoice;
const LOGFONTW = win32.LOGFONTW;
const LONG_PTR = win32.LONG_PTR;
const LPARAM = win32.LPARAM;
const LPCWSTR = win32.LPCWSTR;
const LRESULT = win32.LRESULT;
const NCCALCSIZE_PARAMS = win32.NCCALCSIZE_PARAMS;
const NONCLIENTMETRICSW = win32.NONCLIENTMETRICSW;
const PAINTSTRUCT = win32.PAINTSTRUCT;
const POINT = win32.POINT;
const PaletteCatalog = win32.PaletteCatalog;
const PaletteItem = win32.PaletteItem;
const PalettePayload = win32.PalettePayload;
const PaletteRanked = win32.PaletteRanked;
const PaletteStableId = win32.PaletteStableId;
const ProfileOpenTarget = win32.ProfileOpenTarget;
const QuickTerminalAnimation = win32.QuickTerminalAnimation;
const RECT = win32.RECT;
const SplitTreeSurface = win32.SplitTreeSurface;
const Surface = win32.Surface;
const TRACKMOUSEEVENT = win32.TRACKMOUSEEVENT;
const Tab = win32.Tab;
const ThemeColors = win32.ThemeColors;
const TitlebarButtonRole = win32.TitlebarButtonRole;
const TitlebarGlyphKind = win32.TitlebarGlyphKind;
const UINT = win32.UINT;
const WNDPROC = win32.WNDPROC;
const WPARAM = win32.WPARAM;
const activeTabAfterRemoval = win32.activeTabAfterRemoval;
const activeTabTheme = win32.activeTabTheme;
const adjustColor = win32.adjustColor;
const appendOwnedString = win32.appendOwnedString;
const applyChildRect = win32.applyChildRect;
const applyChildVisibility = win32.applyChildVisibility;
const applyChromeChildRect = win32.applyChromeChildRect;
const applyProfileChromeAccent = win32.applyProfileChromeAccent;
const apprt = @import("../../apprt.zig");
const bannerButtonKey = win32.bannerButtonKey;
const bannerMessageDurationMs = win32.bannerMessageDurationMs;
const blendColorRGB = win32.blendColorRGB;
const buildDropdownProfileLabel = win32.buildDropdownProfileLabel;
const buildHostAwareBaseTitle = win32.buildHostAwareBaseTitle;
const buildHostBannerText = win32.buildHostBannerText;
const builtin = @import("builtin");
const buttonColorsFromTheme = win32.buttonColorsFromTheme;
const buttonLabelRightInset = win32.buttonLabelRightInset;
const c = @import("consts.zig");
const captionButtonBoundsThunk = win32.captionButtonBoundsThunk;
const captionButtonInvokeThunk = win32.captionButtonInvokeThunk;
const captionButtonZoomedThunk = win32.captionButtonZoomedThunk;
const captionButtonsPaintedThunk = win32.captionButtonsPaintedThunk;
const childRect = win32.childRect;
const chromeSyncOrLog = win32.chromeSyncOrLog;
const chrome_layout = @import("chrome_layout.zig");
const chrome_scene = @import("chrome_scene.zig");
const clampPaletteViewport = win32.clampPaletteViewport;
const clampTabInsertIndex = win32.clampTabInsertIndex;
const clientTitlebarTheme = win32.clientTitlebarTheme;
const closeScopePrompt = win32.closeScopePrompt;
const configpkg = @import("../../config.zig");
const confirmBodyPaintRect = win32.confirmBodyPaintRect;
const confirmPreviewRect = win32.confirmPreviewRect;
const confirmPromptLineColor = win32.confirmPromptLineColor;
const confirmPromptLineOwnedByChild = win32.confirmPromptLineOwnedByChild;
const confirmTextPlacement = win32.confirmTextPlacement;
const confirmTitlePaintRect = win32.confirmTitlePaintRect;
const confirm_prompt_text_format = win32.confirm_prompt_text_format;
const createIconFontWithGlyphs = win32.createIconFontWithGlyphs;
const cycleProfileOpenTarget = win32.cycleProfileOpenTarget;
const decorationVisibilityForChromeValue = win32.decorationVisibilityForChromeValue;
const desiredTabIndex = win32.desiredTabIndex;
const destroyChildWindow = win32.destroyChildWindow;
const destroySubclassedWindow = win32.destroySubclassedWindow;
const destroySubclassedWindowWithPrev = win32.destroySubclassedWindowWithPrev;
const detachChromeControlProvider = win32.detachChromeControlProvider;
const drawRoundedRect = win32.drawRoundedRect;
const drawTextWz = win32.drawTextWz;
const fillSolidRect = win32.fillSolidRect;
const focus_cue = @import("focus_cue.zig");
const focus_region = @import("focus_region.zig");
const focusableHwnd = win32.focusableHwnd;
const gdi = @import("gdi.zig");
const hostBannerProc = win32.hostBannerProc;
const hostButtonProc = win32.hostButtonProc;
const hostCloseConfirmAccept = win32.hostCloseConfirmAccept;
const hostCompositionRedrawFlags = win32.hostCompositionRedrawFlags;
const hostLayoutClientRect = win32.hostLayoutClientRect;
const hostPresentShowCommand = win32.hostPresentShowCommand;
const hostTabLabelMaxWidth = win32.hostTabLabelMaxWidth;
const host_caption_button_h = win32.host_caption_button_h;
const host_inspector_panel_height = win32.host_inspector_panel_height;
const host_overlay_accept_width = win32.host_overlay_accept_width;
const host_overlay_cancel_width = win32.host_overlay_cancel_width;
const host_overlay_height = win32.host_overlay_height;
const host_overlay_label_width = win32.host_overlay_label_width;
const host_overlay_padding = win32.host_overlay_padding;
const host_overlay_row_height = win32.host_overlay_row_height;
const host_search_bar_height = win32.host_search_bar_height;
const host_tab_close_zone_width = win32.host_tab_close_zone_width;
const host_tab_height_integrated = win32.host_tab_height_integrated;
const host_tab_max_button_width = win32.host_tab_max_button_width;
const host_titlebar_action_button_size = win32.host_titlebar_action_button_size;
const infoBannersExpire = win32.infoBannersExpire;
const input = @import("../../input.zig");
const inspectorPanelVisibleForState = win32.inspectorPanelVisibleForState;
const internal_os = @import("../../os/main.zig");
const isHighContrastActive = win32.isHighContrastActive;
const keepProfileSources = win32.keepProfileSources;
const keyEventFromWin32Message = win32.keyEventFromWin32Message;
const keyEventTogglesCommandPalette = win32.keyEventTogglesCommandPalette;
const keyPressed = win32.keyPressed;
const lParamBits = win32.lParamBits;
const labels = @import("labels.zig");
const lastError = win32.lastError;
const layoutChildPaintPlan = win32.layoutChildPaintPlan;
const layoutRectToWin32 = win32.layoutRectToWin32;
const log = win32.log;
const logUiActionError = win32.logUiActionError;
const movedIndexAfterReorder = win32.movedIndexAfterReorder;
const nativeSplitDirection = win32.nativeSplitDirection;
const ncRectToWin32 = win32.ncRectToWin32;
const nextTabOverviewSelection = win32.nextTabOverviewSelection;
const optionalOwnedStringEquals = win32.optionalOwnedStringEquals;
const overlayActionLayoutForWidth = win32.overlayActionLayoutForWidth;
const overlayButtonDisconnectThunk = win32.overlayButtonDisconnectThunk;
const overlayButtonReleaseThunk = win32.overlayButtonReleaseThunk;
const overlayEditChildRectFromFrame = win32.overlayEditChildRectFromFrame;
const overlayEditFrameRect = win32.overlayEditFrameRect;
const overlayEditText = win32.overlayEditText;
const overlayEmptySubmitDismisses = win32.overlayEmptySubmitDismisses;
const overlayLabelReservation = win32.overlayLabelReservation;
const overlayPanelInterior = win32.overlayPanelInterior;
const overlayTextNeedsRefill = win32.overlayTextNeedsRefill;
const overlay_session = @import("overlay_session.zig");
const ownedStringEquals = win32.ownedStringEquals;
const paintPinnedSlotBadge = win32.paintPinnedSlotBadge;
const paintTargetButtonBadge = win32.paintTargetButtonBadge;
const paint_text = @import("text.zig");
const paletteDisconnectThunk = win32.paletteDisconnectThunk;
const paletteListRect = win32.paletteListRect;
const paletteListWidthIsReadable = win32.paletteListWidthIsReadable;
const paletteReleaseThunk = win32.paletteReleaseThunk;
const paletteThemeSaveFailureMessage = win32.paletteThemeSaveFailureMessage;
const paletteVisibleRowCapacity = win32.paletteVisibleRowCapacity;
const palette_catalog_label_bytes = win32.palette_catalog_label_bytes;
const palette_controller = @import("palette_controller.zig");
const palette_row_height = win32.palette_row_height;
const pinnedSlotBadgeDigit = win32.pinnedSlotBadgeDigit;
const preferredProfileIndex = win32.preferredProfileIndex;
const profileChromeStripeColor = win32.profileChromeStripeColor;
const profileChromeVisible = win32.profileChromeVisible;
const profileIndexByKey = win32.profileIndexByKey;
const profileKindFocusRingColor = win32.profileKindFocusRingColor;
const profileKindLabelColor = win32.profileKindLabelColor;
const profileOpenTargetBadgeGlyph = win32.profileOpenTargetBadgeGlyph;
const profileOpenTargetMarkerColor = win32.profileOpenTargetMarkerColor;
const prompt_button_class = win32.prompt_button_class;
const prompt_label_class = win32.prompt_label_class;
const quick_terminal_host = @import("quick_terminal_host.zig");
const raiseChildToTop = win32.raiseChildToTop;
const rectInset = win32.rectInset;
const refocusActiveSurface = win32.refocusActiveSurface;
const refocusHostAfterActivation = win32.refocusHostAfterActivation;
const remapWin32KeyEvent = win32.remapWin32KeyEvent;
const resolveProfileSelection = win32.resolveProfileSelection;
const rootDisconnectThunk = win32.rootDisconnectThunk;
const rootReleaseThunk = win32.rootReleaseThunk;
const runUiActionOrLog = win32.runUiActionOrLog;
const scheduleDeferredUiaDisconnect = win32.scheduleDeferredUiaDisconnect;
const searchFocusStopAvailable = win32.searchFocusStopAvailable;
const searchFocusStopHwnd = win32.searchFocusStopHwnd;
const search_controls = @import("search_controls.zig");
const selectedProfileSelectionNeedsChange = win32.selectedProfileSelectionNeedsChange;
const setQuickTerminalRect = win32.setQuickTerminalRect;
const setWindowData = win32.setWindowData;
const shellSplitDirection = win32.shellSplitDirection;
const shouldShowPaneCount = win32.shouldShowPaneCount;
const std = @import("std");
const surfaceLayoutRuntimeSync = win32.surfaceLayoutRuntimeSync;
const surface_presentation = @import("surface_presentation.zig");
const sys = @import("sys.zig");
const tabBarVisibleForConfig = win32.tabBarVisibleForConfig;
const tabButtonProc = win32.tabButtonProc;
const tabCloseAction = win32.tabCloseAction;
const tabContainerProc = win32.tabContainerProc;
const tabDirectionFromWheelDelta = win32.tabDirectionFromWheelDelta;
const tabStatusBadgeColor = win32.tabStatusBadgeColor;
const tabStatusHeadline = win32.tabStatusHeadline;
const tabStatusKey = win32.tabStatusKey;
const tabStripChildVisible = win32.tabStripChildVisible;
const tab_tooltip_class_name = win32.tab_tooltip_class_name;
const tabsCloseConfirmCount = win32.tabsCloseConfirmCount;
const takeOverlayButtonUiaProviders = win32.takeOverlayButtonUiaProviders;
const terminalDisconnectThunk = win32.terminalDisconnectThunk;
const terminalReleaseThunk = win32.terminalReleaseThunk;
const themeSurface = win32.themeSurface;
const themepkg = @import("../../config/theme.zig");
const titlebarButtonVisual = win32.titlebarButtonVisual;
const titlebarCaptionFromHitTest = win32.titlebarCaptionFromHitTest;
const titlebarRoleFromCaption = win32.titlebarRoleFromCaption;
const titlebar_icon_faces = win32.titlebar_icon_faces;
const titlebar_icon_glyphs = win32.titlebar_icon_glyphs;
const undecoratedKeepsFrame = win32.undecoratedKeepsFrame;
const usesIntegratedTitlebar = win32.usesIntegratedTitlebar;
const utf8BoundedPrefix = win32.utf8BoundedPrefix;
const visibleTabRange = win32.visibleTabRange;
const win32RectToNc = win32.win32RectToNc;
const win32_bell = @import("../win32_bell.zig");
const win32_chrome_state = @import("../win32_chrome_state.zig");
const win32_icons = @import("../win32_icons.zig");
const win32_input = @import("input.zig");
const win32_layout = @import("../win32_layout.zig");
const win32_nc_layout = @import("../win32_nc_layout.zig");
const win32_palette = @import("../win32_palette.zig");
const win32_power = @import("../win32_power.zig");
const win32_program_status = @import("../win32_program_status.zig");
const win32_quick_terminal = @import("../win32_quick_terminal.zig");
const win32_settings = @import("../win32_settings.zig");
const win32_shell = @import("../win32_shell.zig");
const win32_structural_history = @import("../win32_structural_history.zig");
const win32_tab_drop_zones = @import("../win32_tab_drop_zones.zig");
const win32_tab_tooltip = @import("../win32_tab_tooltip.zig");
const win32_tab_visual = @import("../win32_tab_visual.zig");
const win32_theme = @import("../win32_theme.zig");
const win32_tween = @import("../win32_tween.zig");
const win32_uia = @import("../win32_uia/mod.zig");
const win32_undo = @import("../win32_undo.zig");
const windowTitleSyncChanged = win32.windowTitleSyncChanged;
const windows_shell = @import("../../config/windows_shell.zig");

// Test dependencies.
const windows = win32.windows;
const GlyphCoverage = win32.GlyphCoverage;
const fontGlyphCoverage = win32.fontGlyphCoverage;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const UpdateNotice = win32.UpdateNotice;
const build_config = @import("../../build_config.zig");
const hostWindowProc = win32.hostWindowProc;
const palette_list_class_name = win32.palette_list_class_name;
const TestSession = win32.TestSession;
const createTestChromeChild = win32.createTestChromeChild;
const createTestHostWindow = win32.createTestHostWindow;
const fontIsFaceForTest = win32.fontIsFaceForTest;
const icon_font_test_missing_face = win32.icon_font_test_missing_face;
const installedTitlebarIconFaceForTest = win32.installedTitlebarIconFaceForTest;
const ToastTestWindow = win32.ToastTestWindow;
const applyDefaultProfileConfig = win32.applyDefaultProfileConfig;
const buttonTooltipAction = win32.buttonTooltipAction;
const cli_args = @import("../../cli/args.zig");
const detachHostReference = win32.detachHostReference;
const expectedToastRemoval = win32.expectedToastRemoval;
const highContrastThemeFromSysColors = win32.highContrastThemeFromSysColors;
const patchOrAppendEdits = win32.patchOrAppendEdits;
const rgb = win32.rgb;
const tabSeenWithForeground = win32.tabSeenWithForeground;
const testExpectNoLaunchLayout = win32.testExpectNoLaunchLayout;
const toastTestSplit = win32.toastTestSplit;
const userProfileKeysChanged = win32.userProfileKeysChanged;

const overlay_edit_child_inset_x_base = chrome_layout.overlay_edit_child_inset_x_base;

const overlay_edit_child_inset_y_base = chrome_layout.overlay_edit_child_inset_y_base;

const empty_confirm_text_placement = chrome_layout.empty_confirm_text_placement;

const host_tab_height: i32 = (win32_theme.ThemeMetrics{}).height_tab;

const host_tab_small_button_width: i32 = (win32_theme.ThemeMetrics{}).tab_small_button_width;

const host_tab_overflow_button_width: i32 = (win32_theme.ThemeMetrics{}).tab_overflow_button_width;

pub const palette_catalog_capacity: usize = 768;

const palette_catalog_label_capacity: usize = 768;

/// The program status badge a tab draws before its label, and the room it
/// takes from the label with the gap after it, in DIPs and in label cells
/// (about 7 DIPs each in the chrome font).
const tab_status_badge_size: i32 = 10;

const tab_status_badge_slot: i32 = tab_status_badge_size + 5;

const tab_status_badge_cells: usize = 2;

/// The fewest cells `hostTabLabelMaxWidth` gives a label.
const tab_label_min_cells: usize = 6;

const host_tab_new_button_label = std.unicode.utf8ToUtf16LeStringLiteral("+");

const host_tab_dropdown_button_label = std.unicode.utf8ToUtf16LeStringLiteral("\u{25BE}"); // dropdown chevron

const titlebar_hover_fade_ms: u16 = 150;

/// An even status key cannot collide with a program status's odd hash.
const tab_bell_status_key: u64 = 2;

const PaletteCatalogConfigSource = enum {
    /// Catalog strings borrow the current `app.config`.
    live,
    /// Catalog strings borrow `palette_theme_preview_original`.
    preview_original,
    /// Catalog strings borrow `palette_catalog_retained_config`.
    retained,
};

const TitlebarHoverFade = struct {
    active: bool = false,
    started_ms: u64 = 0,
    duration_ms: u16 = 0,

    fn start(self: *TitlebarHoverFade, now_ms: u64, duration_ms: u16) void {
        self.* = .{
            .active = duration_ms > 0,
            .started_ms = now_ms,
            .duration_ms = duration_ms,
        };
    }

    fn alphaAt(self: TitlebarHoverFade, now_ms: u64) f32 {
        if (!self.active or self.duration_ms == 0) return 0.0;
        if (now_ms <= self.started_ms) return 1.0;
        const elapsed = now_ms - self.started_ms;
        if (elapsed >= self.duration_ms) return 0.0;
        const t = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms));
        return 1.0 - std.math.clamp(t, 0.0, 1.0);
    }

    fn animating(self: TitlebarHoverFade, now_ms: u64) bool {
        if (!self.active or self.duration_ms == 0) return false;
        if (now_ms <= self.started_ms) return true;
        return now_ms - self.started_ms < self.duration_ms;
    }
};

/// Client-space rects of the three painted caption buttons.
const CaptionButtonRects = struct {
    minimize: RECT,
    maximize: RECT,
    close: RECT,

    pub fn get(self: CaptionButtonRects, kind: win32_uia.CaptionButtonKind) RECT {
        return switch (kind) {
            .minimize => self.minimize,
            .maximize => self.maximize,
            .close => self.close,
        };
    }
};

pub const Host = struct {
    app: *App,
    id: u32,
    shell_id: ?win32_shell.model.WindowId = null,
    hwnd: ?HWND = null,
    power_notifications: win32_power.Notifications = .{},
    surfaces_visible: bool = true,
    dwm_cloaked: bool = false,
    cached_decorations_visible: bool = true,
    /// This host is the quick terminal. Its tabs and splits are all part of
    /// it, so this, not a flag on one surface, says what the window is.
    quick_terminal: bool = false,
    /// The window was on screen when `toggle_visibility` hid every window,
    /// so showing them again brings it back. A window hidden before that,
    /// such as a dismissed quick terminal, stays hidden. Anything else that
    /// shows the window (`WM_SHOWWINDOW`) clears it: the window is not
    /// waiting for the toggle any more.
    hidden_by_toggle: bool = false,
    tabs: std.ArrayListUnmanaged(Tab) = .empty,
    active_tab: usize = 0,
    next_tab_id: u32 = 1,
    /// True while THIS host is drag-resizing (between its own
    /// `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`). Surfaces owned by
    /// this Host short-circuit `requestRepaint` while the flag is
    /// set. Per-host rather than per-App so dragging window A does
    /// not freeze unrelated background windows B / C. Atomic
    /// because the renderer thread reads it from outside the UI
    /// pump.
    is_live_resize: std.atomic.Value(bool) = .init(false),
    /// One-shot guard used by `WM_EXITSIZEMOVE`: the final layout
    /// must still defer terminal surface repaints so the explicit
    /// post-layout flush owns the single repaint request.
    defer_surface_repaints_until_flush: bool = false,
    overlay_mode: HostOverlayMode = .none,
    /// Surface a title prompt's text was last filled from, while
    /// `overlayTextFollowsActiveSurface(overlay_mode)`, so the text refills
    /// when the active surface changes (a tab switch or focus moving to
    /// another split pane). Only compared with `activeSurface()`, never
    /// dereferenced.
    overlay_text_surface: ?*const Surface = null,
    /// Active confirm overlay payload when `overlay_mode == .confirm`.
    /// Owned byte slices (`title`, `body`, `accept_label`,
    /// `cancel_label`) are allocated via `app.core_app.alloc` and
    /// freed when the overlay closes or the Host deinits.
    confirm_payload: ?ConfirmPayload = null,
    /// STATIC that carries the confirm prompt's title. Laid out and
    /// shown only in `.confirm` mode; in every other overlay mode it
    /// stays hidden and exists purely so `syncOverlayLabel`'s
    /// changed-return can drive the chrome paint-text cache.
    overlay_label_hwnd: ?HWND = null,
    overlay_label_prev_proc: ?*const anyopaque = null,
    /// ControlType Text provider for the confirm title. Named from the
    /// payload so a screen reader can report what is being approved.
    overlay_title_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    overlay_edit_hwnd: ?HWND = null,
    overlay_edit_prev_proc: ?*const anyopaque = null,
    overlay_preview_prev_proc: ?*const anyopaque = null,
    overlay_edit_uia_provider: ?*win32_uia.TerminalProvider = null,
    overlay_edit_uia_selection: ?[2]u32 = null,
    cached_overlay_edit: ?[:0]const u8 = null,
    /// Guard flag: set true while `setOverlayEditText` drives a
    /// programmatic `SetWindowTextW` on the overlay EDIT. That call
    /// synchronously fires `EN_CHANGE`; without this gate the nested
    /// handler would invalidate `cached_overlay_edit`, re-run
    /// `rebuildPaletteList` / `syncOverlay*` mid-write, and leave the
    /// outer caller racing its own sync. Matches the precedent in
    /// `win32_settings.zig` (AGENTS.md:75).
    suppress_edit_events: bool = false,
    /// STATIC that carries the confirm prompt's body. Same visibility
    /// contract as `overlay_label_hwnd`.
    overlay_hint_hwnd: ?HWND = null,
    overlay_hint_prev_proc: ?*const anyopaque = null,
    /// Live-region provider for the confirm body, so opening a prompt
    /// announces it instead of leaving the user on an unexplained
    /// Allow button.
    overlay_body_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    /// Read-only multiline EDIT that shows the payload a confirm
    /// prompt is about. An EDIT rather than an owner-drawn panel so
    /// scrolling, selection and UIA come from the control instead of
    /// being hand-written.
    overlay_preview_hwnd: ?HWND = null,
    overlay_accept_hwnd: ?HWND = null,
    overlay_cancel_hwnd: ?HWND = null,
    overlay_accept_uia_provider: ?*win32_uia.SettingsControlProvider = null,
    overlay_cancel_uia_provider: ?*win32_uia.SettingsControlProvider = null,
    /// The preview pane as a read-only Edit labelled by the prompt's
    /// title; without it UIA saw a Pane named after its contents.
    overlay_preview_uia_provider: ?*win32_uia.SettingsControlProvider = null,
    overlay_button_prev_proc: ?*const anyopaque = null,
    cached_overlay_label: ?[:0]const u8 = null,
    cached_overlay_hint: ?[:0]const u8 = null,
    cached_overlay_preview: ?[:0]const u8 = null,
    cached_overlay_accept: ?[:0]const u8 = null,
    cached_overlay_cancel: ?[:0]const u8 = null,
    overlay_completion_seed: ?[:0]const u8 = null,
    overlay_completion_value: ?[:0]const u8 = null,
    overlay_completion_result_id: ?PaletteStableId = null,
    profiles: ?[]windows_shell.Profile = null,
    profiles_complete: bool = false,
    /// The picker or the palette asked the discovery worker for a list;
    /// its result is applied here even when a list is already loaded.
    profiles_requested: bool = false,
    selected_profile: usize = 0,
    selected_profile_key: ?[:0]const u8 = null,
    chrome_brush: HBRUSH = null,
    overlay_brush: HBRUSH = null,
    edit_brush: HBRUSH = null,
    current_dpi: u32 = 96,
    /// Set by `WM_GETDPISCALEDSIZE`, cleared once `WM_DPICHANGED` has put in
    /// the new DPI's font. In between, the terminals keep their grid: see
    /// `Surface.syncCoreSizeFromClientRect`.
    dpi_change_pending: bool = false,
    /// The last client rect with an area, which layout keeps using while the
    /// window is minimized. See `chrome_layout.hostLayoutClientRect`.
    last_layout_client_rect: ?RECT = null,
    chrome_font: ?*anyopaque = null, // HFONT, owned
    /// Monospace HFONT for the confirm preview. The chrome font is
    /// proportional, which would misrepresent whitespace and column
    /// alignment in the very bytes the user is judging.
    preview_font: ?*anyopaque = null, // HFONT, owned
    /// Icon fonts for the caption buttons and the tab row's new-tab and
    /// dropdown buttons (`recreateTitlebarIconFonts`). Null when no face has
    /// the glyphs, and `win32_icons` draws them.
    titlebar_caption_icon_font: ?*anyopaque = null, // HFONT, owned
    titlebar_action_icon_font: ?*anyopaque = null, // HFONT, owned
    /// Both titlebar icon fonts are null because no icon face has the
    /// glyphs, not because GDI failed to create or check one, so
    /// `reconfigureSystemTheme` does not count them as missing.
    titlebar_icons_geometric: bool = false,
    /// Codicons for the search bar buttons (`search_icon_font_face`). Null
    /// until first use (`searchIconFont`), and when the font is unavailable.
    search_icon_font: ?*anyopaque = null, // HFONT, owned
    /// Whether `search_icon_font` has been created, or found unavailable,
    /// since the last DPI or theme change.
    search_icon_font_resolved: bool = false,

    // Cached chrome paint strings — rebuilt only when their per-zone
    // dirty bits are set, so WM_PAINT can skip unrelated UTF-16 churn.
    chrome_repaint_dirty: bool = true,
    chrome_paint_pending: bool = false,
    chrome_paint_mask: ChromeRepaintMask = .{},
    chrome_text_dirty: ChromeTextDirty = .{},
    cached_inspector_title_w: ?[:0]const u16 = null,
    cached_inspector_hint_w: ?[:0]const u16 = null,
    cached_overlay_paint_badge_w: ?[:0]const u16 = null,
    cached_overlay_paint_label_w: ?[:0]const u16 = null,
    cached_overlay_paint_feedback_w: ?[:0]const u16 = null,
    cached_window_title: ?[:0]const u8 = null,
    /// The caption currently carries the bell glyph; see `syncWindowTitle`.
    caption_bell: bool = false,

    overflow_hwnd: ?HWND = null, // dropdown chevron (▾)
    overflow_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    overflow_placement: ChildPlacement = .{},
    chrome_button_prev_proc: ?*const anyopaque = null,
    new_tab_hwnd: ?HWND = null,
    new_tab_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    new_tab_placement: ChildPlacement = .{},
    overlay_label_placement: ChildPlacement = .{},
    /// Where the confirm title's text sits inside its child window.
    /// Written by `layout`, read by the owner-draw handler.
    overlay_label_text: ConfirmTextPlacement = empty_confirm_text_placement,
    overlay_edit_placement: ChildPlacement = .{},
    overlay_hint_placement: ChildPlacement = .{},
    /// Where the confirm body's text sits inside its child window.
    overlay_hint_text: ConfirmTextPlacement = empty_confirm_text_placement,
    overlay_preview_placement: ChildPlacement = .{},
    overlay_accept_placement: ChildPlacement = .{},
    overlay_cancel_placement: ChildPlacement = .{},
    hovered_button_hwnd: ?HWND = null,
    /// How the user last reached a chrome control. Owner-drawn buttons
    /// paint their focus ring only in `.keyboard` mode, the way native
    /// controls honour `UISF_HIDEFOCUS`: a tab that was just clicked or
    /// a `[▾]` whose menu was just dismissed holds focus but shows no
    /// ring. Any navigation key flips it back (`focus_cue.keyRevealsRing`),
    /// any pointer press on a chrome control clears it.
    focus_input_mode: focus_cue.InputMode = .pointer,
    /// Native window activation, independent of the selected terminal tab.
    window_active: bool = false,
    /// `App.activations` when this window was last activated, 0 if never:
    /// which window a forwarded launch copies (`App.newWindowSource`).
    activated: u64 = 0,
    /// Fade state for the tab the user is currently hovering. Paint
    /// reads `alphaAt(now)` + pre-composites the glyph colour against
    /// the tab bg so the close X visibly fades in with
    /// `win32_tab_visual.close_fade_ms` (120 ms) cubic ease-in-out.
    tab_close_hover: win32_tab_visual.CloseState = .{},
    tab_close_hover_hwnd: ?HWND = null,
    /// Where the band last painted the active tab's join to its terminal
    /// (`activeTabJoin`), so a layout that moves it repaints the old place.
    tab_join: ?TabJoin = null,
    /// Which caption button the cursor is currently hovering, when
    /// this host is actively using the integrated titlebar. Drives
    /// hover-tint paint in `paintChrome` and is cleared on
    /// `WM_NCMOUSELEAVE`.
    caption_hover: CaptionButton = .none,
    caption_pressed: CaptionButton = .none,
    /// Last zoomed state the caption buttons were announced with. The
    /// middle button's UIA name is "Maximize" or "Restore", so a flip has
    /// to raise a Name property-changed event.
    caption_zoomed: bool = false,
    /// Last painted state the caption children were announced with. The
    /// UIA root exposes them only while they are painted, so a client
    /// that cached the fragment tree needs a structure-changed event
    /// whenever this flips.
    caption_painted: bool = false,
    /// One `WM_WINHOSTTY_UIA_CAPTION_SYNC` in flight is enough: the
    /// handler re-reads the live state, so a second post would only make
    /// the same comparison again. Keeps the frequent callers (every
    /// `WM_WINDOWPOSCHANGED`) from queueing a message per event.
    caption_sync_pending: bool = false,
    /// Registered for WM_NCMOUSELEAVE via `TrackMouseEvent(TME_NONCLIENT
    /// | TME_LEAVE)` so we can clear `caption_hover` when the cursor
    /// exits the non-client area. Only re-armed when it becomes false.
    caption_track_armed: bool = false,
    titlebar_hover_fade: TitlebarHoverFade = .{},
    titlebar_hover_fade_role: TitlebarButtonRole = .none,
    /// Fade-OUT state for the tab the user JUST left, so rapid
    /// A → B hover transitions animate BOTH tabs concurrently
    /// (A fades out 1 → 0 while B fades in 0 → 1) instead of A
    /// snapping to 0 the moment the mouse enters B. One slot is
    /// enough in practice — at 120 ms per fade, the user would need
    /// sub-frame hover chains to require more parallel animations.
    tab_close_prev: win32_tab_visual.CloseState = .{},
    tab_close_prev_hwnd: ?HWND = null,
    banner_kind: HostBannerKind = .none,
    banner_text: ?[:0]const u8 = null,
    /// Persistent input mode, separate from transient/error notifications.
    mode_indicator_text: ?[:0]const u8 = null,
    mode_indicator_surface: ?*Surface = null,
    mode_timer_active: bool = false,
    /// This host's config problems, behind an earlier error until it is
    /// dismissed. Owned separately from the ordinary single banner slot.
    config_problems_text: ?[:0]const u8 = null,
    banner_hwnd: ?HWND = null,
    banner_placement: ChildPlacement = .{},
    banner_prev_proc: ?*const anyopaque = null,
    banner_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    /// Open Release or Install (control 1914) and the close button or
    /// Dismiss (1915): BUTTON children of the banner, indexed by
    /// `BannerButton`.
    banner_buttons: [2]?HWND = .{ null, null },
    banner_button_placements: [2]ChildPlacement = .{ .{}, .{} },
    banner_button_uia_providers: [2]?*win32_uia.ChromeControlProvider = .{ null, null },
    /// The content area and top `layout` last gave the banner;
    /// `placeBanner` sizes it within that.
    banner_area: ?struct { content: RECT, top: i32 } = null,
    /// The pointer is over the banner; `TME_LEAVE` is armed while it is.
    banner_pointer_inside: bool = false,
    /// A banner button holds keyboard focus (tracked from `WM_SETFOCUS`
    /// and `WM_KILLFOCUS`).
    banner_focused: bool = false,
    /// A new update notice to announce once the banner is on screen.
    banner_announce_pending: bool = false,
    /// When the running `.info` countdown ends (`GetTickCount64`), null
    /// while none runs. See `syncBannerExpiry`.
    banner_expires_at: ?u64 = null,
    /// The banner has had a `WM_PAINT` since its message was set or it was
    /// last hidden. An `.info` countdown starts only then: a UI thread busy
    /// for longer than the countdown would otherwise find the timer overdue
    /// at its first turn, and `GetMessage` hands out a pending paint before
    /// a due timer, so the message would be painted once and cleared.
    banner_painted: bool = false,
    tab_drag_index: ?usize = null,
    tab_drag_start_x: i32 = 0,
    tab_drag_start_y: i32 = 0,
    tab_drag_active: bool = false,
    tab_wheel_steps: win32_input.WheelSteps = .{},
    tab_wheel_horizontal: bool = false,
    tab_drop_operation: win32_tab_drop_zones.Operation = .none,
    tab_drop_target_surface: ?*Surface = null,
    tab_drop_preview_hwnd: ?HWND = null,

    // Hover tooltip for the tab strip. Created on the first hover that has
    // something to show and reused after that; `tab_tooltip_tab_id` names the
    // tab it currently describes.
    tab_tooltip_hwnd: ?HWND = null,
    tab_tooltip_tab_id: ?u32 = null,
    /// The text the popup currently holds, so a refresh that leaves it
    /// unchanged neither re-announces the name nor repaints.
    tab_tooltip_text: ?[:0]const u8 = null,
    tab_tooltip_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    /// The chrome button the same popup describes instead of a tab (the
    /// search bar's icon buttons), and the button a click keeps it down for.
    button_tooltip: ButtonTooltip = .{},

    // Command palette list UI. Backed by a custom child HWND shown
    // only while the palette is open. `palette_list_ranked` caches the
    // current query's ranked matches so the paint path doesn't re-rank
    // on every WM_PAINT; rebuilt on EDIT text change.
    palette_list_hwnd: ?HWND = null,
    root_uia_provider: ?*win32_uia.RootProvider = null,
    tab_container_hwnd: ?HWND = null,
    tab_container_placement: ChildPlacement = .{},
    tab_container_prev_proc: ?*const anyopaque = null,
    tab_container_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    palette_list_uia_provider: ?*win32_uia.PaletteListProvider = null,
    palette_list_placement: ChildPlacement = .{},
    palette_catalog_items: [palette_catalog_capacity]PaletteItem = undefined,
    palette_catalog_payloads: [palette_catalog_capacity]PalettePayload = undefined,
    palette_catalog: ?PaletteCatalog = null,
    palette_catalog_labels: [palette_catalog_label_capacity][palette_catalog_label_bytes]u8 = undefined,
    palette_catalog_label_count: usize = 0,
    /// Owned installed-theme snapshot backing exact catalog payload names.
    palette_installed_themes: ?[]themepkg.Entry = null,
    /// Owned saved-layout names backing exact catalog payload names.
    palette_layout_names: ?[][]u8 = null,
    palette_list_ranked: [win32_palette.max_ranked]PaletteRanked = undefined,
    palette_list_ranked_count: usize = 0,
    /// Rows that physically fit in the current palette List HWND. This can be
    /// lower than `palette_max_visible_rows` at large DPI or in short windows.
    palette_list_visible_rows: usize = 0,
    palette_list_scroll: usize = 0,
    palette_wheel_steps: win32_input.WheelSteps = .{},
    /// Currently-selected row (absolute index into ranked). Enter runs
    /// this entry; click overrides both selection and invocation.
    palette_list_selected: usize = 0,
    /// Original app config while a palette theme row is being previewed.
    /// Owned by this host until committed or reverted.
    palette_theme_preview_original: ?configpkg.Config = null,
    /// A swapped-out config kept alive only while current catalog strings
    /// borrow it. Cleared immediately after the catalog resets or hides.
    palette_catalog_retained_config: ?configpkg.Config = null,
    palette_catalog_config_source: PaletteCatalogConfigSource = .live,

    // Single SetTimer-driven tween scheduler; see Tween scheduler block
    // in the method section. Matches Win32's main-thread-paint model.
    tween_sched: win32_tween.Scheduler = .{},
    quick_terminal_animation: ?QuickTerminalAnimation = null,
    /// Programmatic QT rectangles are already in target-monitor pixels.
    quick_terminal_placing: bool = false,
    /// A restored window's saved rect is being applied; same reason.
    restore_placing: bool = false,
    tween_timer_active: bool = false,
    search_timer_active: bool = false,
    scrollbar_timer_active: bool = false,
    resize_settle_timer_active: bool = false,
    resize_settle_repaint_ticks: u8 = 0,
    /// `GetTickCount64` past which resize-settle paint mode is over even while
    /// its timer is still armed. WM_TIMER is the lowest-priority message, so a
    /// busy pump can hold off the timer's last tick indefinitely, and settle
    /// mode used to last exactly that long.
    resize_settle_until_ms: u64 = 0,
    structural_history_disposing: bool = false,
    destroy_after_structural_dispose: bool = false,
    structural_undo_entries: win32_structural_history.List(StructuralUndoEntry) = .empty,
    structural_redo_entries: win32_structural_history.List(StructuralUndoEntry) = .empty,

    const StructuralHistoryDisposeMode = enum {
        normal,
        host_destroy,
    };

    const StructuralUndoKind = enum {
        close_tab,
        split_create,
        tab_subtree_transfer,
    };

    pub const CloseTabUndo = struct {
        tab: ?Tab = null,
        index: usize,
        tab_id: u32,
        shell_id: ?win32_shell.model.TabId = null,
        /// The tab was in front when it closed. Closing a background tab
        /// from its button leaves the front tab alone, so undoing that close
        /// must not bring the tab to the front either, or redo would then
        /// close the front tab and hand the front to its neighbour.
        was_active: bool = true,
    };

    /// The created pane keeps its shell model ID through the undo: its
    /// window retains the ID while the pane waits in redo history, the redo
    /// brings the pane back under it, and disposing the detached entry
    /// releases it.
    pub const SplitCreateUndo = struct {
        source_surface: *Surface,
        created_surface: *Surface,
        /// The two panes' shell model IDs, taken when the split was made. An
        /// entry can outlive its source pane, or (in undo history) its
        /// created one: another entry's disposal may free it (a redo older
        /// than this one expires first, or a history clear stops part way),
        /// and that pane's entries are left to their own disposal. So a
        /// replay finds both among this window's live panes, by pointer and
        /// then by generational ID, before it reads either
        /// (`livePaneTabIndex`); the ID tells a pane from a newer one that
        /// reused its memory.
        source_pane: ?win32_shell.model.PaneId = null,
        created_pane: ?win32_shell.model.PaneId = null,
        direction: SplitTreeSurface.Split.Direction = .right,
        detached: bool = false,
    };

    const TabSubtreeTransferUndo = struct {
        source_tab: ?Tab,
        source_index: usize,
        source_tab_id: u32,
        target_tab_id: u32,
        alternate_tree: SplitTreeSurface,
        alternate_focus: SplitTreeSurface.Node.Handle,
        source_root: win32_shell.model.NodeId,
        applied: bool = true,
    };

    const StructuralUndoEntry = struct {
        kind: StructuralUndoKind,
        timestamp_ms: u64,
        sequence_id: u64 = 0,
        payload: union(StructuralUndoKind) {
            close_tab: CloseTabUndo,
            split_create: SplitCreateUndo,
            tab_subtree_transfer: TabSubtreeTransferUndo,
        },

        pub fn dispose(
            self: *StructuralUndoEntry,
            host: *Host,
            mode: StructuralHistoryDisposeMode,
        ) !void {
            switch (self.payload) {
                .close_tab => |*value| {
                    if (value.tab) |*tab| {
                        switch (mode) {
                            .normal => try host.disposeDetachedUndoTab(tab),
                            .host_destroy => tab.deinit(),
                        }
                        value.tab = null;
                    }
                },

                .split_create => |*value| {
                    if (!value.detached) return;
                    switch (mode) {
                        .normal => host.disposeDetachedUndoSurface(value.created_surface),
                        .host_destroy => {},
                    }
                    value.detached = false;
                },

                .tab_subtree_transfer => |*value| {
                    if (mode == .normal) {
                        var shell_discard: ?win32_shell.runtime.Prepared = null;
                        if (host.app.shell_runtime_initialized) {
                            shell_discard = try host.app.shell_runtime.prepare(.{ .discard_transfer = value.source_root });
                        }
                        defer if (shell_discard) |*prepared| prepared.deinit();
                        if (shell_discard) |*prepared| try prepared.commit(&host.app.shell_runtime);
                    }

                    // Both the detached source Tab (applied phase) and the
                    // alternate tree are duplicate references. Moved Surfaces
                    // remain owned by the live tree and must never be closed.
                    // A tree here may name a pane another entry's disposal
                    // freed: deinit reads none, as `Surface.ref`/`unref` are
                    // no-ops.
                    if (value.source_tab) |*tab| {
                        tab.deinit();
                        value.source_tab = null;
                    }
                    value.alternate_tree.deinit();
                },
            }
        }

        fn referencesSurface(
            self: *const StructuralUndoEntry,
            host: *Host,
            surface: *Surface,
        ) bool {
            return switch (self.payload) {
                .close_tab => |value| close_tab: {
                    if (value.tab) |tab| break :close_tab tab.findHandle(surface) != null;
                    const index = host.findTabIndexById(value.tab_id) orelse return false;
                    break :close_tab host.tabs.items[index].findHandle(surface) != null;
                },

                .split_create => |value| value.source_surface == surface or value.created_surface == surface,
                .tab_subtree_transfer => |value| transfer: {
                    if (value.source_tab) |tab| {
                        if (tab.findHandle(surface) != null) break :transfer true;
                    }
                    var it = value.alternate_tree.iterator();
                    while (it.next()) |entry| if (entry.view == surface) break :transfer true;
                    break :transfer false;
                },
            };
        }
    };

    pub fn nextTabId(self: *Host) u32 {
        const id = self.next_tab_id;
        self.next_tab_id +%= 1;
        if (self.next_tab_id == 0) self.next_tab_id = 1;
        return id;
    }

    pub fn findTabIndexById(self: *const Host, id: u32) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.id == id) return i;
        }
        return null;
    }

    /// Cannot fail, as on main. The model releases the ID it kept for this
    /// redo first, so nothing the surface's close does can address it. A
    /// release that fails (out of memory) is not a reason to keep the entry,
    /// unlike a detached tab's (`disposeDetachedUndoTab`): a history clear
    /// that stopped here would leave the entries after it naming panes it
    /// had already freed, and keep refusing pane closes (`requestClose`).
    /// The ID then stays retained by its window, unreachable, until the
    /// window goes.
    fn disposeDetachedUndoSurface(self: *Host, surface: *Surface) void {
        if (self.app.shell_runtime_initialized) if (surface.shell_id) |pane_id| {
            self.app.releaseRetainedShellPane(pane_id);
        };
        surface.shell_id = null;
        self.structural_history_disposing = true;
        defer self.structural_history_disposing = false;
        surface.close(false);
    }

    fn disposeDetachedUndoTab(self: *Host, tab: *Tab) !void {
        var shell_discard: ?win32_shell.runtime.Prepared = null;
        if (self.app.shell_runtime_initialized) {
            const shell_id = tab.shell_id orelse return error.ShellStateOutOfSync;
            shell_discard = try self.app.shell_runtime.prepare(.{ .discard_detached_tab = shell_id });
        }
        defer if (shell_discard) |*prepared| prepared.deinit();

        // Commit first: after this allocation-free state swap the retained
        // native objects are deliberately unaddressable by ShellState. Their
        // synchronous HWND teardown cannot issue a second model close.
        if (shell_discard) |*prepared| try prepared.commit(&self.app.shell_runtime);
        self.structural_history_disposing = true;
        defer self.structural_history_disposing = false;

        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            entry.view.close(false);
        }
        tab.deinit();
    }

    fn disposeStructuralNormalLogged(self: *Host, entry: *StructuralUndoEntry) !void {
        entry.dispose(self, .normal) catch |err| {
            log.err("structural history disposal deferred err={}", .{err});
            return err;
        };
    }

    fn disposeStructuralHostDestroyLogged(self: *Host, entry: *StructuralUndoEntry) !void {
        entry.dispose(self, .host_destroy) catch |err| {
            log.err("structural history host-destroy disposal deferred err={}", .{err});
            return err;
        };
    }

    fn discardNewestStructuralUndo(self: *Host) bool {
        return win32_structural_history.discardNewest(
            StructuralUndoEntry,
            &self.structural_undo_entries,
            self,
            disposeStructuralNormalLogged,
        );
    }

    fn discardNewestStructuralRedo(self: *Host) bool {
        return win32_structural_history.discardNewest(
            StructuralUndoEntry,
            &self.structural_redo_entries,
            self,
            disposeStructuralNormalLogged,
        );
    }

    pub fn clearStructuralRedo(self: *Host) bool {
        while (self.structural_redo_entries.items.len > 0) {
            if (!self.discardNewestStructuralRedo()) return false;
        }
        return true;
    }

    pub fn tryClearStructuralHistory(
        self: *Host,
        mode: StructuralHistoryDisposeMode,
    ) bool {
        const undo_complete = switch (mode) {
            .normal => win32_structural_history.clear(
                StructuralUndoEntry,
                &self.structural_undo_entries,
                self,
                disposeStructuralNormalLogged,
            ),
            .host_destroy => win32_structural_history.clear(
                StructuralUndoEntry,
                &self.structural_undo_entries,
                self,
                disposeStructuralHostDestroyLogged,
            ),
        };
        const redo_complete = switch (mode) {
            .normal => win32_structural_history.clear(
                StructuralUndoEntry,
                &self.structural_redo_entries,
                self,
                disposeStructuralNormalLogged,
            ),
            .host_destroy => win32_structural_history.clear(
                StructuralUndoEntry,
                &self.structural_redo_entries,
                self,
                disposeStructuralHostDestroyLogged,
            ),
        };
        return undo_complete and redo_complete;
    }

    pub fn clearStructuralHistory(
        self: *Host,
        mode: StructuralHistoryDisposeMode,
    ) void {
        _ = self.tryClearStructuralHistory(mode);
    }

    fn discardExpiredStructuralEntries(
        self: *Host,
        list: *win32_structural_history.List(StructuralUndoEntry),
        min_timestamp_ms: u64,
    ) bool {
        return win32_structural_history.pruneExpired(
            StructuralUndoEntry,
            list,
            min_timestamp_ms,
            self,
            disposeStructuralNormalLogged,
        );
    }

    pub fn oldestStructuralTimestamp(self: *const Host) ?u64 {
        return win32_structural_history.oldestTimestamp(
            StructuralUndoEntry,
            &self.structural_undo_entries,
            &self.structural_redo_entries,
        );
    }

    pub fn hasStructuralHistory(self: *const Host) bool {
        return win32_structural_history.hasHistory(
            StructuralUndoEntry,
            &self.structural_undo_entries,
            &self.structural_redo_entries,
        );
    }

    pub fn pruneStructuralHistoryBefore(self: *Host, min_timestamp_ms: u64) bool {
        const undo_complete = self.discardExpiredStructuralEntries(&self.structural_undo_entries, min_timestamp_ms);
        const redo_complete = self.discardExpiredStructuralEntries(&self.structural_redo_entries, min_timestamp_ms);
        return undo_complete and redo_complete;
    }

    fn pruneStructuralHistory(self: *Host) bool {
        return self.pruneStructuralHistoryBefore(self.app.undoCutoffTimestampMs());
    }

    pub fn pushStructuralUndo(self: *Host, entry: StructuralUndoEntry) !*StructuralUndoEntry {
        try self.reserveStructuralUndoSlot();
        return self.appendStructuralUndoAssumeCapacity(entry);
    }

    fn reserveStructuralUndoSlot(self: *Host) !void {
        if (!self.pruneStructuralHistory()) return error.HistoryDisposalDeferred;
        try self.structural_undo_entries.ensureUnusedCapacity(self.app.core_app.alloc, 1);
        if (!self.clearStructuralRedo()) return error.HistoryDisposalDeferred;
        while (self.structural_undo_entries.items.len >= win32_undo.max_entries) {
            try win32_structural_history.evictOldest(
                StructuralUndoEntry,
                &self.structural_undo_entries,
                self,
                disposeStructuralNormalLogged,
            );
        }
    }

    fn appendStructuralUndoAssumeCapacity(self: *Host, entry: StructuralUndoEntry) *StructuralUndoEntry {
        const stored = win32_structural_history.appendAssumeCapacity(
            StructuralUndoEntry,
            &self.structural_undo_entries,
            entry,
        );
        self.app.scheduleUndoPruneTimer();
        return stored;
    }

    pub fn peekStructuralUndo(self: *const Host) ?*const StructuralUndoEntry {
        return win32_structural_history.peek(StructuralUndoEntry, &self.structural_undo_entries);
    }

    pub fn peekStructuralRedo(self: *const Host) ?*const StructuralUndoEntry {
        return win32_structural_history.peek(StructuralUndoEntry, &self.structural_redo_entries);
    }

    fn popStructuralUndo(self: *Host) Allocator.Error!?*StructuralUndoEntry {
        return win32_structural_history.moveNewest(
            StructuralUndoEntry,
            &self.structural_undo_entries,
            &self.structural_redo_entries,
            self.app.core_app.alloc,
        );
    }

    fn popStructuralRedo(self: *Host) Allocator.Error!?*StructuralUndoEntry {
        return win32_structural_history.moveNewest(
            StructuralUndoEntry,
            &self.structural_redo_entries,
            &self.structural_undo_entries,
            self.app.core_app.alloc,
        );
    }

    fn restoreLastStructuralUndoPop(self: *Host) void {
        win32_structural_history.restoreNewestMove(
            StructuralUndoEntry,
            &self.structural_redo_entries,
            &self.structural_undo_entries,
            self.app.core_app.alloc,
        );
    }

    fn restoreLastStructuralRedoPop(self: *Host) void {
        win32_structural_history.restoreNewestMove(
            StructuralUndoEntry,
            &self.structural_undo_entries,
            &self.structural_redo_entries,
            self.app.core_app.alloc,
        );
    }

    pub fn discardStructuralEntriesReferencing(self: *Host, surface: *Surface) void {
        if (self.structural_history_disposing) return;

        var i: usize = 0;
        while (i < self.structural_undo_entries.items.len) {
            if (!self.structural_undo_entries.items[i].referencesSurface(self, surface)) {
                i += 1;
                continue;
            }

            self.structural_undo_entries.items[i].dispose(self, .normal) catch |err| {
                log.err("referenced structural undo disposal deferred err={}", .{err});
                i += 1;
                continue;
            };
            _ = self.structural_undo_entries.orderedRemove(i);
        }

        i = 0;
        while (i < self.structural_redo_entries.items.len) {
            if (!self.structural_redo_entries.items[i].referencesSurface(self, surface)) {
                i += 1;
                continue;
            }

            self.structural_redo_entries.items[i].dispose(self, .normal) catch |err| {
                log.err("referenced structural redo disposal deferred err={}", .{err});
                i += 1;
                continue;
            };
            _ = self.structural_redo_entries.orderedRemove(i);
        }
    }

    pub fn detachTabForUndo(self: *Host, index: usize) ?StructuralUndoEntry {
        // Load-bearing guard: detached tabs retain their surface
        // allocations + host pointers so undo can reinsert them
        // without replaying process startup. Detaching the last tab
        // leaves an empty Host alive as the keybinding target for
        // undo/redo; the app-level prune timer owns the timeout path
        // so hidden surfaces cannot live past `undo-timeout`.
        if (index >= self.tabs.items.len) return null;
        // A prompt one of its terminals raised goes with the tab, while the
        // tab is still in place for the layout this runs: its Allow would
        // otherwise answer a terminal that is now only undo history.
        self.cancelConfirmFromTab(&self.tabs.items[index]);

        const previous_tab_id = if (self.active_tab < self.tabs.items.len)
            self.tabs.items[self.active_tab].id
        else
            null;
        const was_active = index == self.active_tab;
        var removed = self.tabs.orderedRemove(index);
        const tab_id = removed.id;
        self.destroyTabButton(&removed);
        removed.button_placement = .{};
        removed.button_label_cache_valid = false;

        var it = removed.tree.iterator();
        while (it.next()) |entry| {
            entry.view.host_active = false;
            entry.view.setVisible(false);
        }
        // Its panes live on in undo history, where a click on their toasts
        // has nothing to show, and an undo does not bring the toasts back.
        self.app.forgetTabToasts(&removed);

        self.active_tab = activeTabAfterRemoval(self.active_tab, index, self.tabs.items.len);
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);

        return .{
            .kind = .close_tab,
            .timestamp_ms = sys.GetTickCount64(),
            .sequence_id = self.app.nextUndoSequence(),
            .payload = .{ .close_tab = .{
                .tab = removed,
                .index = index,
                .tab_id = tab_id,
                .shell_id = removed.shell_id,
                .was_active = was_active,
            } },
        };
    }

    pub fn restoreClosedTabEntryNative(self: *Host, value: *CloseTabUndo) Allocator.Error!bool {
        const tab = value.tab orelse return false;
        const insert_index = clampTabInsertIndex(value.index, self.tabs.items.len);
        // A tab that closed behind the front one comes back behind it.
        const keeps_front = !value.was_active and self.tabs.items.len > 0;
        try self.tabs.insert(self.app.core_app.alloc, insert_index, tab);
        value.tab = null;
        value.index = insert_index;
        if (!keeps_front) {
            self.active_tab = insert_index;
        } else if (insert_index <= self.active_tab) {
            self.active_tab += 1;
        }
        // Its programs may have ended while the tab waited in undo history.
        self.refreshTabStatus(insert_index);
        return self.activeSurface() != null;
    }

    pub fn restoreClosedTabEntry(self: *Host, value: *CloseTabUndo) !bool {
        const insert_index = clampTabInsertIndex(value.index, self.tabs.items.len);
        const previous_tab_id = if (self.active_tab < self.tabs.items.len)
            self.tabs.items[self.active_tab].id
        else
            null;
        var shell_prepared: ?win32_shell.runtime.Prepared = null;
        if (self.app.shell_runtime_initialized) {
            const shell_id = value.shell_id orelse return error.ShellStateOutOfSync;
            shell_prepared = try self.app.shell_runtime.prepare(.{ .restore_tab = .{
                .tab = shell_id,
                .index = insert_index,
                .activate = value.was_active,
            } });
        }
        defer if (shell_prepared) |*prepared| prepared.deinit();
        const previous_active = self.active_tab;
        if (!(try self.restoreClosedTabEntryNative(value))) return false;
        if (shell_prepared) |*prepared| prepared.commit(&self.app.shell_runtime) catch |err| {
            value.tab = self.tabs.orderedRemove(insert_index);
            self.active_tab = previous_active;
            return err;
        };
        if (shell_prepared) |*prepared| self.app.applyShellEffects(prepared.effects(), .{});
        // The session is open again: the next close saves it, and checkpoints
        // resume. The quick terminal is never part of it.
        if (!self.quick_terminal) self.app.session_state_saved_before_last_host_close = false;
        // Detaching destroys the tab button and its UIA provider. Rebuild the
        // restored button before raising the selected-item notification so
        // assistive clients receive the event from a live provider.
        self.prepareActiveTabVisibility(self.active_tab);
        self.layout() catch |err| log.warn("tab restore layout sync failed err={}", .{err});
        self.refreshChrome() catch |err| log.warn("tab restore chrome sync failed err={}", .{err});
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        return self.activeSurface() != null;
    }

    pub fn redoClosedTabEntry(self: *Host, value: *CloseTabUndo) !bool {
        if (value.tab != null) return false;
        const index = self.findTabIndexById(value.tab_id) orelse return false;
        const previous_tab_id = if (self.active_tab < self.tabs.items.len)
            self.tabs.items[self.active_tab].id
        else
            null;
        // Read before the panes are hidden: the focus message that follows
        // can move `active_tab`.
        const previous_active = self.active_tab;
        var shell_prepared: ?win32_shell.runtime.Prepared = null;
        if (self.app.shell_runtime_initialized) {
            const shell_id = value.shell_id orelse return error.ShellStateOutOfSync;
            shell_prepared = try self.app.shell_runtime.prepare(.{ .detach_tab = shell_id });
        }
        defer if (shell_prepared) |*prepared| prepared.deinit();
        // As the close it redoes: the session's last tab is saved as it goes.
        const saved_here = self.tabs.items.len == 1 and self.app.closingEndsSession(self);
        if (saved_here) self.app.saveSessionAsItEnds();
        errdefer if (saved_here) {
            self.app.session_state_saved_before_last_host_close = false;
        };
        var removed = self.tabs.orderedRemove(index);
        self.destroyTabButton(&removed);
        removed.button_placement = .{};
        removed.button_label_cache_valid = false;

        var it = removed.tree.iterator();
        while (it.next()) |entry| {
            entry.view.host_active = false;
            entry.view.setVisible(false);
        }

        value.index = index;
        value.tab = removed;
        // What the next undo has to put back is the tab as it stands now.
        value.was_active = index == previous_active;
        self.active_tab = activeTabAfterRemoval(previous_active, index, self.tabs.items.len);
        // Hiding the panes of a tab that was in front moves the keyboard to
        // the next one, and that focus message commits to the model between
        // the prepare above and this commit, as it can for a pane's close.
        if (self.app.test_before_structural_shell_commit) |hook| {
            if (self.activeSurface()) |next| if (next.shell_id) |pane| try hook(self.app, pane);
        }
        if (shell_prepared) |*prepared| prepared.commitRetryingInterleavedFocus(&self.app.shell_runtime) catch |err| {
            try self.tabs.insert(self.app.core_app.alloc, index, removed);
            value.tab = null;
            self.active_tab = previous_active;
            var restored_it = self.tabs.items[index].tree.iterator();
            while (restored_it.next()) |entry| entry.view.host_active = true;
            return err;
        };
        if (shell_prepared) |*prepared| self.app.applyShellEffects(prepared.effects(), .{});
        // As the close it redoes (`detachTabForUndo`).
        if (value.tab) |*tab| self.app.forgetTabToasts(tab);
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        self.notifyTabListUiaChanged();
        return true;
    }

    pub fn undoSplitCreateEntry(self: *Host, value: *SplitCreateUndo) !bool {
        if (value.detached) return false;
        // Both panes are found live in one of this window's tabs before
        // either is read: the entry may outlive them.
        const tab_index = self.livePaneTabIndex(value.source_surface, value.source_pane) orelse return false;
        const created_tab = self.livePaneTabIndex(value.created_surface, value.created_pane) orelse return false;
        if (created_tab != tab_index) return false;
        const previous_tab_id = if (self.active_tab < self.tabs.items.len)
            self.tabs.items[self.active_tab].id
        else
            null;
        if (self.app.shell_runtime_initialized) {
            var prepared = try self.app.shell_runtime.prepare(.{ .detach_pane = value.created_pane.? });
            defer prepared.deinit();
            if (self.app.test_before_structural_shell_commit) |hook| {
                try hook(self.app, value.source_pane.?);
            }
            // The model keeps the pane's ID for the redo, and focus follows
            // the close rule: the user's pane stays focused unless it was the
            // one removed.
            try prepared.commitRetryingStale(&self.app.shell_runtime);
            try self.applyCommittedSplitHistory(&prepared, value.created_surface);
        } else {
            // Without a shell model (headless fixtures), as before it: the
            // pane the split came from is focused.
            const edit = try self.buildSplitHistoryEdit(.detach, value.created_surface);
            self.installSplitHistoryEdit(edit, .detach, value.created_surface);
            const tab = &self.tabs.items[edit.tab_index];
            tab.focused = tab.findHandle(value.source_surface) orelse tab.focused;
            self.active_tab = edit.tab_index;
            hideDetachedSplitSurface(value.created_surface);
        }
        value.detached = true;
        // The pane waits in redo history now, like a closed tab's panes.
        self.app.forgetSurfaceToast(value.created_surface);
        // The neighbours take the removed pane's space now: activating a pane
        // that is already focused and shown takes a fast path with no layout.
        self.layout() catch |err| log.warn("split-create undo layout failed err={}", .{err});
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        return true;
    }

    pub fn redoSplitCreateEntry(self: *Host, value: *SplitCreateUndo) !bool {
        if (!value.detached) return false;
        // The detached pane is this entry's own; the pane it splits again
        // is found live before it is read, as the entry may outlive it.
        _ = self.livePaneTabIndex(value.source_surface, value.source_pane) orelse return false;
        const previous_tab_id = if (self.active_tab < self.tabs.items.len)
            self.tabs.items[self.active_tab].id
        else
            null;
        if (self.app.shell_runtime_initialized) {
            var prepared = try self.app.shell_runtime.prepare(.{ .restore_pane = .{
                .pane = value.created_pane orelse return false,
                .at = value.source_pane.?,
                .direction = shellSplitDirection(value.direction),
            } });
            defer prepared.deinit();
            if (self.app.test_before_structural_shell_commit) |hook| try hook(self.app, value.source_pane.?);
            // The pane comes back focused, under the ID the undo kept.
            try prepared.commitRetryingStale(&self.app.shell_runtime);
            try self.applyCommittedSplitHistory(&prepared, value.created_surface);
        } else {
            const change: SplitHistoryChange = .{ .attach = .{
                .beside = value.source_surface,
                .direction = value.direction,
            } };
            const edit = try self.buildSplitHistoryEdit(change, value.created_surface);
            self.installSplitHistoryEdit(edit, change, value.created_surface);
            self.active_tab = edit.tab_index;
        }
        value.detached = false;
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        return true;
    }

    /// The index of the tab of this window that holds `surface` live, found
    /// without reading `surface`: a history entry can name a pane another
    /// entry's disposal freed. Tab trees hold only live panes, so once found
    /// the pane can be read, and with the shell model it must still carry
    /// `pane_id`, the generational ID the entry took, or it is a newer pane
    /// that reused the memory. Without the shell model (headless fixtures
    /// only) the check is the pointer alone, which reused memory passes.
    fn livePaneTabIndex(self: *const Host, surface: *Surface, pane_id: ?win32_shell.model.PaneId) ?usize {
        for (self.tabs.items, 0..) |*tab, index| {
            if (tab.findHandle(surface) == null) continue;
            if (!self.app.shell_runtime_initialized) return index;
            const expected = pane_id orelse return null;
            const live = surface.shell_id orelse return null;
            return if (live.eql(expected)) index else null;
        }
        return null;
    }

    /// Whether `trees` name exactly the panes the shell model holds in
    /// `tabs`, each live in this window: only then may a transfer's replay
    /// put the trees in. Each pane is found by pointer before it is read,
    /// as another entry's disposal may have freed it (`SplitTree` refs a
    /// pane without reading it); its shell ID then tells it from a newer
    /// pane that reused the memory, and the count catches a live pane the
    /// trees would drop. Without the shell model (headless fixtures only)
    /// just the pointers are checked.
    fn transferTreesMatchModel(
        self: *const Host,
        trees: []const *const SplitTreeSurface,
        tabs: []const ?win32_shell.model.TabId,
    ) bool {
        const modeled = self.app.shell_runtime_initialized;
        const state = &self.app.shell_runtime.state;
        if (modeled) {
            for (tabs) |tab| if (tab == null) return false;
        }
        var named: usize = 0;
        for (trees) |tree| {
            var it = tree.iterator();
            while (it.next()) |entry| {
                const live = for (self.tabs.items) |*tab| {
                    if (tab.findHandle(entry.view) != null) break true;
                } else false;
                if (!live) return false;
                if (!modeled) continue;
                const pane = state.paneConst(entry.view.shell_id orelse return false) orelse return false;
                if (!modelTabListed(tabs, pane.tab)) return false;
                named += 1;
            }
        }
        if (!modeled) return true;
        var held: usize = 0;
        for (state.panes.items) |pane| {
            if (modelTabListed(tabs, pane.tab)) held += 1;
        }
        return named == held;
    }

    fn modelTabListed(tabs: []const ?win32_shell.model.TabId, id: win32_shell.model.TabId) bool {
        for (tabs) |tab| if (tab.?.eql(id)) return true;
        return false;
    }

    /// What a split-create history step does to the native split tree:
    /// the pane leaves its tab, or joins the tab of `beside` again, on the
    /// `direction` side of it.
    const SplitHistoryChange = union(enum) {
        detach,
        attach: struct {
            beside: *Surface,
            direction: SplitTreeSurface.Split.Direction,
        },
    };

    /// The tree a `SplitHistoryChange` gives the tab at `tab_index`, built
    /// but not yet installed.
    const SplitHistoryEdit = struct {
        tab_index: usize,
        next: SplitTreeSurface,
    };

    /// The native half of a committed split-create history step (decision
    /// D7). The shell model has decided which pane leaves its tab or joins
    /// it again, where, and which pane is focused after; the native split
    /// tree follows the committed effects, matched by stable pane ID. Native
    /// geometry stays native: the tree is edited, never rebuilt from the
    /// model, so the other splits keep their ratios and a zoom on a pane that
    /// stays survives a removal (`SplitTree.remove` carries it over), while
    /// a pane that joins again splits its neighbour in half and resets the
    /// zoom, as every new split does. If the native tree cannot be built, the
    /// commit is taken back (`Prepared.rollback`): neither side has changed,
    /// and the caller leaves the history entry where it was.
    fn applyCommittedSplitHistory(
        self: *Host,
        prepared: *win32_shell.runtime.Prepared,
        surface: *Surface,
    ) !void {
        const effects = prepared.effects();
        errdefer prepared.rollback(&self.app.shell_runtime) catch |err| {
            log.err("split history rollback failed err={}", .{err});
        };
        const change = try self.splitHistoryChange(effects, surface);
        const edit = try self.buildSplitHistoryEdit(change, surface);

        self.installSplitHistoryEdit(edit, change, surface);
        // Focus and the tab in front follow the model before a pane that
        // leaves is hidden. Hiding the pane that has the keyboard can move
        // the keyboard (the 2026-10-15 SMALL-04 B log entry measured it for a
        // tab's panes), and a host that gets it passes it on to its active
        // tab's focused pane (`refocusHostAfterActivation`): by then the
        // model's choice.
        self.app.applyShellEffects(effects, .{});
        switch (change) {
            .detach => hideDetachedSplitSurface(surface),
            .attach => surface.shell_committed = true,
        }
    }

    /// The change the committed effects ask of the native tree. The pane
    /// itself is the history entry's (`surface`), which must carry the
    /// model's ID; `beside` is found among this window's panes.
    fn splitHistoryChange(
        self: *Host,
        effects: []const win32_shell.effect.Effect,
        surface: *const Surface,
    ) !SplitHistoryChange {
        const pane_id = surface.shell_id orelse return error.ShellStateOutOfSync;
        for (effects) |effect| switch (effect) {
            .detach_surface => |pane| {
                if (!pane.eql(pane_id)) return error.ShellStateOutOfSync;
                return .detach;
            },
            .attach_surface => |attach| {
                if (!attach.pane.eql(pane_id)) return error.ShellStateOutOfSync;
                return .{ .attach = .{
                    .beside = self.findPaneSurface(attach.beside) orelse return error.ShellStateOutOfSync,
                    .direction = nativeSplitDirection(attach.direction),
                } };
            },
            else => {},
        };
        return error.ShellStateOutOfSync;
    }

    /// The live pane with shell model ID `pane_id`, in any of this window's
    /// tabs.
    fn findPaneSurface(self: *Host, pane_id: win32_shell.model.PaneId) ?*Surface {
        for (self.tabs.items) |*tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const id = entry.view.shell_id orelse continue;
                if (id.eql(pane_id)) return entry.view;
            }
        }
        return null;
    }

    /// Everything a `SplitHistoryChange` can fail at: building the new tree.
    fn buildSplitHistoryEdit(self: *Host, change: SplitHistoryChange, surface: *Surface) !SplitHistoryEdit {
        const alloc = self.app.core_app.alloc;
        for (self.tabs.items, 0..) |*tab, index| switch (change) {
            .detach => {
                const handle = tab.findHandle(surface) orelse continue;
                return .{ .tab_index = index, .next = try tab.tree.remove(alloc, handle) };
            },
            .attach => |attach| {
                const handle = tab.findHandle(attach.beside) orelse continue;
                var inserted = try SplitTreeSurface.init(alloc, surface);
                defer inserted.deinit();
                return .{
                    .tab_index = index,
                    .next = try tab.tree.split(alloc, handle, attach.direction, 0.5, &inserted),
                };
            },
        };
        return error.ShellStateOutOfSync;
    }

    /// Installs a built tree; cannot fail. The tab keeps its focused pane
    /// if it stays (the handles are renumbered, so it is found again), a
    /// pane that joins is focused, and otherwise the first pane stands in
    /// until the focus is applied.
    fn installSplitHistoryEdit(self: *Host, edit: SplitHistoryEdit, change: SplitHistoryChange, surface: *Surface) void {
        const tab = &self.tabs.items[edit.tab_index];
        const focused = tab.focusedSurface();
        tab.tree.deinit();
        tab.tree = edit.next;
        var first = tab.tree.iterator();
        tab.focused = switch (change) {
            .attach => tab.findHandle(surface).?,
            .detach => (if (focused) |kept| tab.findHandle(kept) else null) orelse first.next().?.handle,
        };
    }

    /// A pane taken out of its tab waits hidden in redo history. It keeps
    /// its shell ID, which the model retains, but commits no focus.
    fn hideDetachedSplitSurface(surface: *Surface) void {
        surface.shell_committed = false;
        surface.host_active = false;
        surface.setVisible(false);
    }

    fn undoTabSubtreeTransferEntry(self: *Host, value: *TabSubtreeTransferUndo) !bool {
        if (!value.applied) return false;
        const source_tab = value.source_tab orelse return false;
        const target_index = self.findTabIndexById(value.target_tab_id) orelse return false;
        // Together the two trees name the panes the combined target tab
        // holds now; one another entry's disposal freed must not go back.
        if (!self.transferTreesMatchModel(
            &.{ &value.alternate_tree, &source_tab.tree },
            &.{self.tabs.items[target_index].shell_id},
        )) return false;
        try self.tabs.ensureUnusedCapacity(self.app.core_app.alloc, 1);
        var shell_prepared: ?win32_shell.runtime.Prepared = null;
        if (self.app.shell_runtime_initialized) {
            shell_prepared = try self.app.shell_runtime.prepare(.{ .set_transfer_applied = .{
                .source_root = value.source_root,
                .applied = false,
            } });
        }
        defer if (shell_prepared) |*prepared| prepared.deinit();

        const old_active = self.active_tab;
        const previous_tab_id = if (old_active < self.tabs.items.len)
            self.tabs.items[old_active].id
        else
            null;
        std.mem.swap(SplitTreeSurface, &self.tabs.items[target_index].tree, &value.alternate_tree);
        std.mem.swap(SplitTreeSurface.Node.Handle, &self.tabs.items[target_index].focused, &value.alternate_focus);
        const insert_index = clampTabInsertIndex(value.source_index, self.tabs.items.len);
        self.tabs.insertAssumeCapacity(insert_index, source_tab);
        value.source_tab = null;
        value.source_index = insert_index;
        value.applied = false;
        self.active_tab = insert_index;
        var source_it = self.tabs.items[insert_index].tree.iterator();
        while (source_it.next()) |entry| entry.view.host_active = true;

        if (shell_prepared) |*prepared| prepared.commit(&self.app.shell_runtime) catch |err| {
            value.source_tab = self.tabs.orderedRemove(insert_index);
            const rollback_target = self.findTabIndexById(value.target_tab_id) orelse return err;
            std.mem.swap(SplitTreeSurface, &self.tabs.items[rollback_target].tree, &value.alternate_tree);
            std.mem.swap(SplitTreeSurface.Node.Handle, &self.tabs.items[rollback_target].focused, &value.alternate_focus);
            value.applied = true;
            self.active_tab = old_active;
            return err;
        };
        if (shell_prepared) |*prepared| self.app.applyShellEffects(prepared.effects(), .{});
        // The moved pane stayed visible throughout the drag, so the normal
        // activation fast path cannot infer that the restored target tab must
        // be hidden. Re-establish tab visibility and recreate the detached
        // tab button before focus returns to the source tab.
        self.prepareActiveTabVisibility(self.active_tab);
        self.layout() catch |err| log.warn("tab split transfer undo layout sync failed err={}", .{err});
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        self.refreshChrome() catch |err| log.warn("tab split transfer undo chrome sync failed err={}", .{err});
        return true;
    }

    fn redoTabSubtreeTransferEntry(self: *Host, value: *TabSubtreeTransferUndo) !bool {
        if (value.applied or value.source_tab != null) return false;
        const source_index = self.findTabIndexById(value.source_tab_id) orelse return false;
        const live_target = self.findTabIndexById(value.target_tab_id) orelse return false;
        // As for the undo: the combined tree names the panes the two tabs
        // hold now, all live.
        if (!self.transferTreesMatchModel(
            &.{&value.alternate_tree},
            &.{ self.tabs.items[live_target].shell_id, self.tabs.items[source_index].shell_id },
        )) return false;
        var shell_prepared: ?win32_shell.runtime.Prepared = null;
        if (self.app.shell_runtime_initialized) {
            shell_prepared = try self.app.shell_runtime.prepare(.{ .set_transfer_applied = .{
                .source_root = value.source_root,
                .applied = true,
            } });
        }
        defer if (shell_prepared) |*prepared| prepared.deinit();

        const old_active = self.active_tab;
        const previous_tab_id = if (old_active < self.tabs.items.len)
            self.tabs.items[old_active].id
        else
            null;
        var removed = self.tabs.orderedRemove(source_index);
        self.destroyTabButton(&removed);
        removed.button_placement = .{};
        removed.button_label_cache_valid = false;
        const target_index = self.findTabIndexById(value.target_tab_id) orelse {
            self.tabs.insertAssumeCapacity(source_index, removed);
            return false;
        };
        std.mem.swap(SplitTreeSurface, &self.tabs.items[target_index].tree, &value.alternate_tree);
        std.mem.swap(SplitTreeSurface.Node.Handle, &self.tabs.items[target_index].focused, &value.alternate_focus);
        value.source_tab = removed;
        value.source_index = source_index;
        value.applied = true;
        self.active_tab = target_index;

        if (shell_prepared) |*prepared| prepared.commit(&self.app.shell_runtime) catch |err| {
            std.mem.swap(SplitTreeSurface, &self.tabs.items[target_index].tree, &value.alternate_tree);
            std.mem.swap(SplitTreeSurface.Node.Handle, &self.tabs.items[target_index].focused, &value.alternate_focus);
            self.tabs.insertAssumeCapacity(source_index, value.source_tab.?);
            value.source_tab = null;
            value.applied = false;
            self.active_tab = old_active;
            return err;
        };
        if (shell_prepared) |*prepared| self.app.applyShellEffects(prepared.effects(), .{});
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        self.notifyTabListUiaChanged();
        self.prepareActiveTabVisibility(self.active_tab);
        self.layout() catch |err| log.warn("tab split transfer redo layout sync failed err={}", .{err});
        self.refreshChrome() catch |err| log.warn("tab split transfer redo chrome sync failed err={}", .{err});
        return true;
    }

    pub fn applyLatestStructuralUndo(self: *Host) !?[]const u8 {
        // Replays move panes between tabs; their status badges follow.
        defer self.refreshAllTabStatus();
        // Once the replay's activation is done: an undo may show another
        // tab than the model has in front until it activates it.
        defer self.app.auditShellNativeMapping("structural-undo");
        const entry = (try self.popStructuralUndo()) orelse return null;
        errdefer self.restoreLastStructuralUndoPop();

        switch (entry.payload) {
            .close_tab => |*value| {
                if (!(try self.restoreClosedTabEntry(value))) {
                    _ = self.discardNewestStructuralRedo();
                    return null;
                }
                const surface = self.activeSurface() orelse {
                    _ = self.discardNewestStructuralRedo();
                    return null;
                };
                self.app.activateSurface(surface);
                return "Tab restored.";
            },

            .split_create => |*value| {
                if (!(try self.undoSplitCreateEntry(value))) {
                    _ = self.discardNewestStructuralRedo();
                    return null;
                }
                // The tab the split was in, at the pane the model kept.
                self.app.activateSurface(self.activeSurface() orelse value.source_surface);
                return "New split undone.";
            },

            .tab_subtree_transfer => |*value| {
                if (!(try self.undoTabSubtreeTransferEntry(value))) {
                    log.warn("tab split transfer undo rejected source_tab={any} applied={}", .{
                        value.source_tab != null,
                        value.applied,
                    });
                    _ = self.discardNewestStructuralRedo();
                    return null;
                }
                const source_index = self.findTabIndexById(value.source_tab_id) orelse return null;
                const surface = self.tabs.items[source_index].focusedSurface() orelse return null;
                self.app.activateSurface(surface);
                return "Tab split transfer undone.";
            },
        }
    }

    pub fn applyLatestStructuralRedo(self: *Host) !?[]const u8 {
        // Replays move panes between tabs; their status badges follow.
        defer self.refreshAllTabStatus();
        defer self.app.auditShellNativeMapping("structural-redo");
        const entry = (try self.popStructuralRedo()) orelse return null;
        errdefer self.restoreLastStructuralRedoPop();

        switch (entry.payload) {
            .close_tab => |*value| {
                const shown = self.activeSurface();
                if (!(try self.redoClosedTabEntry(value))) {
                    _ = self.discardNewestStructuralUndo();
                    return null;
                }
                if (self.activeSurface()) |surface| {
                    // A background tab closed again leaves the active tab
                    // as it was, whose activation skips layout.
                    if (surface == shown) {
                        runUiActionOrLog("redo close layout failed", self.layout());
                        runUiActionOrLog("redo close chrome refresh failed", self.refreshChrome());
                    }
                    self.app.activateSurface(surface);
                } else {
                    self.refocusHostWindow();
                    runUiActionOrLog("redo close layout failed", self.layout());
                    runUiActionOrLog("redo close chrome refresh failed", self.refreshChrome());
                }
                return "Tab closed again.";
            },

            .split_create => |*value| {
                if (!(try self.redoSplitCreateEntry(value))) {
                    _ = self.discardNewestStructuralUndo();
                    return null;
                }
                self.app.activateSurface(value.created_surface);
                return "Split restored.";
            },

            .tab_subtree_transfer => |*value| {
                if (!(try self.redoTabSubtreeTransferEntry(value))) {
                    _ = self.discardNewestStructuralUndo();
                    return null;
                }
                const moved = if (value.source_tab) |*tab| tab.focusedSurface() else null;
                if (moved) |surface| self.app.activateSurface(surface);
                return "Tab split transfer restored.";
            },
        }
    }

    // ── Tween scheduler plumbing ───────────────────────────────────────

    pub fn clientAnimationsEnabled() bool {
        var enabled: BOOL = 1;
        if (sys.SystemParametersInfoW(
            c.SPI_GETCLIENTAREAANIMATION,
            0,
            @ptrCast(&enabled),
            0,
        ) == 0) {
            // Fail closed: if we can't read the accessibility setting,
            // honour reduced motion. Accessibility guarantees err toward
            // "less motion", never toward "more".
            return false;
        }
        return enabled != 0;
    }

    pub fn effectiveTweenDuration(self: *Host, duration_ms: u16) u16 {
        return (win32_chrome_state.HighContrastDpiState{
            .high_contrast = isHighContrastActive(),
            .client_animations_enabled = clientAnimationsEnabled(),
            .dpi = self.current_dpi,
        }).effectiveAnimationDuration(duration_ms);
    }

    pub const cancelQuickTerminalAnimation = quick_terminal_host.cancelQuickTerminalAnimation;

    /// Reduced-motion and HC collapse `duration_ms` to 0 (snap).
    pub fn addTween(
        self: *Host,
        from: f32,
        to: f32,
        duration_ms: u16,
        easing: [4]f32,
    ) ?win32_tween.TweenId {
        const now = sys.GetTickCount64();
        const effective_duration = self.effectiveTweenDuration(duration_ms);

        const id = self.tween_sched.add(now, .{
            .from = from,
            .to = to,
            .duration_ms = effective_duration,
            .easing = easing,
        }) catch return null;

        self.ensureTweenTimer();
        return id;
    }

    fn ensureTweenTimer(self: *Host) void {
        if (self.tween_timer_active) return;
        const hwnd = self.hwnd orelse return;
        const prev = sys.SetTimer(hwnd, c.TWEEN_TIMER_ID, c.TWEEN_TIMER_INTERVAL_MS, null);
        if (prev == 0) {
            std.log.warn("tween: SetTimer failed; animations will be static this tick", .{});
            return;
        }
        self.tween_timer_active = true;
    }

    pub fn killTweenTimer(self: *Host) void {
        if (!self.tween_timer_active) return;
        const hwnd = self.hwnd orelse {
            self.tween_timer_active = false;
            return;
        };
        _ = sys.KillTimer(hwnd, c.TWEEN_TIMER_ID);
        self.tween_timer_active = false;
    }

    pub fn tickTweens(self: *Host) void {
        const now = sys.GetTickCount64();
        var quick_terminal_finished = false;
        if (self.quick_terminal_animation) |anim| {
            if (self.tween_sched.value(anim.id, now)) |value| {
                const rect = win32_quick_terminal.lerpRect(anim.start, anim.end, value);
                if (self.hwnd) |hwnd| {
                    setQuickTerminalRect(hwnd, rect);
                }
                quick_terminal_finished = value >= 1.0;
            } else {
                quick_terminal_finished = true;
            }
        }
        const still_alive = self.tween_sched.tick(now);
        if (quick_terminal_finished) {
            if (self.quick_terminal_animation) |anim| {
                if (self.hwnd) |hwnd| {
                    setQuickTerminalRect(hwnd, anim.end);
                }
                self.quick_terminal_animation = null;
            }
        }
        // Every tween repaints only what it animates: the quick terminal
        // moves its window, a caption button fade invalidates its button,
        // and a close-button fade its tab. A host-level InvalidateRect
        // doesn't cascade to child button HWNDs (flag = 0 so no
        // WS_CLIPCHILDREN bubble), so each fading tab button is invalidated
        // here and its WM_DRAWITEM path re-reads `CloseState.alphaAt(now)`
        // each frame. When both slots converge, we stop forcing repaints.
        if (self.tab_close_hover_hwnd) |tab_hwnd| {
            if (self.tab_close_hover.animating(now)) {
                _ = sys.InvalidateRect(tab_hwnd, null, 0);
            } else {
                self.tab_close_hover_hwnd = null;
            }
        }
        if (self.tab_close_prev_hwnd) |prev_hwnd| {
            if (self.tab_close_prev.animating(now)) {
                _ = sys.InvalidateRect(prev_hwnd, null, 0);
            } else {
                self.tab_close_prev_hwnd = null;
            }
        }
        if (self.titlebar_hover_fade_role != .none) {
            const role = self.titlebar_hover_fade_role;
            self.invalidateTitlebarButtonRole(role);
            if (!self.titlebar_hover_fade.animating(now)) {
                self.titlebar_hover_fade = .{};
                self.titlebar_hover_fade_role = .none;
                self.invalidateTitlebarButtonRole(role);
            }
        }
        if (!still_alive) self.killTweenTimer();
    }

    pub const ensureResizeSettleTimer = surface_presentation.ensureResizeSettleTimer;

    pub const killResizeSettleTimer = surface_presentation.killResizeSettleTimer;

    pub const startResizeSettleRepaints = surface_presentation.startResizeSettleRepaints;

    pub const tickResizeSettleRepaint = surface_presentation.tickResizeSettleRepaint;

    /// The background `tab`'s button takes when it is the active tab: its
    /// focused terminal's (`Surface.tab_background`). Null in High
    /// Contrast, where the active tab keeps the system highlight.
    pub fn tabBackground(tab: *const Tab) ?u32 {
        if (isHighContrastActive()) return null;
        const surface = tab.focusedSurface() orelse return null;
        return surface.tab_background;
    }

    pub const TabJoin = struct { rect: RECT, color: u32 };

    /// The band's part of the active tab: the lane between its button and
    /// the bottom of the band, the separator row included, as wide as the
    /// button paints itself and in the tab's terminal background, so the
    /// tab runs on into the terminal below it with no accent mark (Windows
    /// Terminal's `terminalBackground` tab). Null without an active tab
    /// button on screen and in High Contrast.
    pub fn activeTabJoin(self: *Host) ?TabJoin {
        if (!self.shouldShowTabBar() or self.active_tab >= self.tabs.items.len) return null;
        const tab = &self.tabs.items[self.active_tab];
        const placement = tab.button_placement;
        if (tab.button_hwnd == null or !placement.visible or !placement.rect_known) return null;
        const color = tabBackground(tab) orelse return null;
        // `drawRoundedRect` keeps a one-pixel inset on each side.
        const rect = RECT{
            .left = placement.rect.left + 1,
            .top = placement.rect.bottom,
            .right = placement.rect.right - 1,
            .bottom = self.contentBands(self.tabBarHeight(), 0, 0).overlay_top,
        };
        if (rect.right <= rect.left or rect.bottom <= rect.top) return null;
        return .{ .rect = rect, .color = color };
    }

    /// Repaint the join where it was and where it is now when either moved
    /// (another tab activated, tabs laid out anew, the active terminal or
    /// its background changed), and the active tab's button when the
    /// background it shows changed: focus moved to a pane with another
    /// background keeps the button's label and place, so nothing else
    /// repaints it. The band clips its paint to these rects.
    pub fn syncTabJoin(self: *Host) void {
        const join = self.activeTabJoin();
        const previous = self.tab_join;
        if (std.meta.eql(join, previous)) return;
        self.tab_join = join;
        const hwnd = self.hwnd orelse return;
        if (previous) |old| _ = sys.InvalidateRect(hwnd, &old.rect, 0);
        const new = join orelse return;
        _ = sys.InvalidateRect(hwnd, &new.rect, 0);
        if (previous == null or previous.?.color != new.color) {
            if (self.tabs.items[self.active_tab].button_hwnd) |button| _ = sys.InvalidateRect(button, null, 0);
        }
    }

    /// Focus `handle` in `tab`. A tab shows its focused pane's terminal
    /// background, so its button and join follow (`syncTabJoin`).
    pub fn focusTabPane(self: *Host, tab: *Tab, handle: SplitTreeSurface.Node.Handle) void {
        if (tab.focused == handle) return;
        tab.focused = handle;
        self.syncTabJoin();
    }

    // ── Integrated titlebar (Win11) ─────────────────────────────────────
    //
    // All four handlers below early-return `null` on Win10 / build <
    // 22000; the caller falls through to `DefWindowProcW` and the
    // system paints its default caption.

    pub fn handleNcCalcSize(
        self: *Host,
        hwnd: HWND,
        wParam: WPARAM,
        lParam: LPARAM,
    ) ?LRESULT {
        if (self.clientCaptionHeight() == null) return null;
        // `CreateWindowEx` sends this with wParam FALSE, and lParam then
        // points at a bare RECT: the proposed window rect in, the client rect
        // out. Frame changes and resizes send TRUE with NCCALCSIZE_PARAMS,
        // whose first rect plays the same role. Both forms must take the
        // integrated caption. Leaving the FALSE one to DefWindowProc gave
        // every new host the stock caption's shorter client area until its
        // first SWP_FRAMECHANGED. That comes from the core's init-time
        // `size_limit` action, after the core has read the terminal's size
        // and before it opens the pty, so each new window started short by
        // the caption's height: one row at 150% with the default font.
        const lparam_addr: usize = @bitCast(lParam);
        const rect: *RECT = if (wParam == 0)
            @ptrFromInt(lparam_addr)
        else
            &@as(*NCCALCSIZE_PARAMS, @ptrFromInt(lparam_addr)).rgrc[0];
        const original = rect.*;
        // Let DWP compute the default side/bottom frame…
        _ = sys.DefWindowProcW(hwnd, c.WM_NCCALCSIZE, wParam, lParam);
        // …then compute the top edge through the shared NC-layout
        // math. Side / bottom stay DWP-owned so the stock frame
        // widths survive, while the integrated-caption policy
        // (caption row inside client + maximized invisible-margin
        // compensation) stays centralized in `win32_nc_layout`.
        var metrics = self.ncMetrics();
        // A maximized window overhangs its monitor by the system's frame,
        // the one DWP has just put on its sides. `metricsDefault` scales the
        // 96-DPI frame linearly, 12 px at 144 DPI where Windows uses 11,
        // which left a 1 px sliver of frame across the top of the monitor
        // (6 px at 288 DPI).
        metrics.size_frame_y = rect.left - original.left;
        metrics.padded_border = 0;
        const state: win32_nc_layout.WindowState = if (sys.IsZoomed(hwnd) != 0) .maximized else .normal;
        const adjusted = win32_nc_layout.calcNcClientRect(.{
            .left = rect.left,
            .top = original.top,
            .right = rect.right,
            .bottom = rect.bottom,
        }, metrics, state);
        rect.top = adjusted.top;
        return 0;
    }

    pub fn handleNcHitTest(self: *Host, hwnd: HWND, lParam: LPARAM) ?LRESULT {
        const caption_height = self.clientCaptionHeight() orelse return null;

        // lParam is the cursor in SCREEN coords (WM_NCHITTEST is
        // special-cased — NOT client-relative).
        const bits: u32 = @truncate(@as(u64, @bitCast(lParam)));
        const cx: i32 = @as(i16, @bitCast(@as(u16, @truncate(bits))));
        const cy: i32 = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16))));

        var win_rect: RECT = undefined;
        if (sys.GetWindowRect(hwnd, &win_rect) == 0) return null;

        // The caption row is painted inside the client area, and on Win11
        // the window rect also covers an invisible resize margin. Measure
        // the caption zones from the real client rect in screen space, or
        // every button responds a frame width away from where it is drawn.
        var client_rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client_rect) == 0) return null;
        var client_origin: POINT = .{ .x = client_rect.left, .y = client_rect.top };
        if (sys.ClientToScreen(hwnd, &client_origin) == 0) return null;

        const window_rect = win32RectToNc(win_rect);
        const client_screen_rect: win32_nc_layout.Rect = .{
            .left = client_origin.x,
            .top = client_origin.y,
            .right = client_origin.x + (client_rect.right - client_rect.left),
            .bottom = client_origin.y + (client_rect.bottom - client_rect.top),
        };
        const cursor: win32_nc_layout.Point = .{ .x = cx, .y = cy };
        const metrics = win32_nc_layout.metricsDefault(self.current_dpi, caption_height);
        const state: win32_nc_layout.WindowState =
            if (sys.IsZoomed(hwnd) != 0) .maximized else .normal;
        const ht = win32_nc_layout.hitTest(window_rect, client_screen_rect, cursor, metrics, state);
        // With no caption row, the empty part of the tab strip stands in for
        // the title bar: drag to move, double-click to maximize, right-click
        // for the system menu. The tabs and the [+] / [▾] buttons are child
        // windows and answer their own hit tests before this one runs.
        if (ht == .client and caption_height == 0 and cy < client_screen_rect.top + self.tabBarHeight()) {
            return c.HTCAPTION;
        }
        return switch (ht) {
            .nowhere => c.HTNOWHERE,
            .client => c.HTCLIENT,
            .caption => c.HTCAPTION,
            .sysmenu => c.HTSYSMENU,
            .minbutton => c.HTMINBUTTON,
            .maxbutton => c.HTMAXBUTTON,
            .left => c.HTLEFT,
            .right => c.HTRIGHT,
            .top => c.HTTOP,
            .topleft => c.HTTOPLEFT,
            .topright => c.HTTOPRIGHT,
            .bottom => c.HTBOTTOM,
            .bottomleft => c.HTBOTTOMLEFT,
            .bottomright => c.HTBOTTOMRIGHT,
            .close => c.HTCLOSE,
        };
    }

    pub fn handleNcMouseMove(self: *Host, hwnd: HWND, wParam: WPARAM) ?LRESULT {
        if (!self.usingIntegratedTitlebar()) return null;

        // wParam is the hit-test code returned by our WM_NCHITTEST.
        const ht: i32 = @intCast(@as(i64, @bitCast(wParam)));
        self.setCaptionHover(titlebarCaptionFromHitTest(ht));

        // Arm a one-shot WM_NCMOUSELEAVE so we can clear the hover
        // when the cursor exits the non-client area. Without this the
        // last-hovered button would paint highlighted indefinitely.
        if (!self.caption_track_armed and trackMouseLeave(hwnd, c.TME_LEAVE | c.TME_NONCLIENT)) {
            self.caption_track_armed = true;
        }

        return null; // fall through to DefWindowProcW for native feedback
    }

    /// `TrackMouseEvent` for `hwnd` with `flags` (a leave, its non-client or
    /// cancel form), no hover. True when it succeeded.
    fn trackMouseLeave(hwnd: HWND, flags: DWORD) bool {
        var track: TRACKMOUSEEVENT = .{
            .cbSize = @sizeOf(TRACKMOUSEEVENT),
            .dwFlags = flags,
            .hwndTrack = hwnd,
            .dwHoverTime = 0,
        };
        return sys.TrackMouseEvent(&track) != 0;
    }

    pub fn handleNcMouseLeave(self: *Host) void {
        self.caption_track_armed = false;
        self.setCaptionHover(.none);
        self.clearCaptionPressed();
    }

    pub const paletteSnapshot = palette_controller.HostControls.paletteSnapshot;

    // ── Palette list UI ───────────────────────────────────────────────

    pub const setOverlayEditText = overlay_session.HostControls.setOverlayEditText;

    pub const storePaletteCatalogLabel = palette_controller.HostControls.storePaletteCatalogLabel;

    pub const appendPaletteDescriptor = palette_controller.HostControls.appendPaletteDescriptor;

    pub const releaseRetainedPaletteCatalogConfig = palette_controller.HostControls.releaseRetainedPaletteCatalogConfig;

    pub const resetPaletteCatalogConfigOwner = palette_controller.HostControls.resetPaletteCatalogConfigOwner;

    pub const paletteListRowCapacity = palette_controller.HostControls.paletteListRowCapacity;

    pub const palettePresentation = palette_controller.HostControls.palettePresentation;

    pub const refreshPalettePresentation = palette_controller.HostControls.refreshPalettePresentation;

    pub const rebuildPaletteList = palette_controller.HostControls.rebuildPaletteList;

    pub const setPaletteListSelection = palette_controller.HostControls.setPaletteListSelection;

    pub const moveListSelection = palette_controller.HostControls.moveListSelection;

    pub const buildPaletteListName = palette_controller.HostControls.buildPaletteListName;

    pub const paletteShortcutLabel = palette_controller.HostControls.paletteShortcutLabel;

    pub const buildPaletteRowName = palette_controller.HostControls.buildPaletteRowName;

    pub const paletteListUiaState = palette_controller.HostControls.paletteListUiaState;

    pub const paletteListUiaStateWithThreading = palette_controller.HostControls.paletteListUiaStateWithThreading;

    pub const overlayEditUiaState = overlay_session.HostControls.overlayEditUiaState;

    pub const raiseOverlayEditSelectionChangedIfNeeded = overlay_session.HostControls.raiseOverlayEditSelectionChangedIfNeeded;

    pub const announcePaletteSelection = palette_controller.HostControls.announcePaletteSelection;

    pub const announcePaletteOutcome = palette_controller.HostControls.announcePaletteOutcome;

    pub const abortPaletteAction = palette_controller.HostControls.abortPaletteAction;

    pub const showPaletteHelp = palette_controller.HostControls.showPaletteHelp;

    pub const paletteRowAtY = palette_controller.HostControls.paletteRowAtY;

    pub const invokePaletteRow = palette_controller.HostControls.invokePaletteRow;

    pub const appendInstalledThemesToPalette = palette_controller.HostControls.appendInstalledThemesToPalette;

    pub const appendSavedLayoutsToPalette = palette_controller.HostControls.appendSavedLayoutsToPalette;

    pub const clearPaletteInstalledThemes = palette_controller.HostControls.clearPaletteInstalledThemes;

    pub const clearPaletteLayoutNames = palette_controller.HostControls.clearPaletteLayoutNames;

    const selectedPaletteThemeName = palette_controller.HostControls.selectedPaletteThemeName;

    fn setConfigTheme(config: *configpkg.Config, name: []const u8) !void {
        const arena = config._arena.?.allocator();
        const owned = try arena.dupeZ(u8, name);
        config.theme = .{
            .light = owned,
            .dark = owned,
        };
    }

    fn loadPaletteThemeConfig(self: *Host, name: []const u8) !configpkg.Config {
        const alloc = self.app.core_app.alloc;
        const cwd_before = try std.process.getCwdAlloc(alloc);
        defer alloc.free(cwd_before);

        var changed_cwd = false;
        if (self.app.startup_cwd) |cwd| {
            try std.process.changeCurDir(cwd);
            changed_cwd = true;
        }
        defer if (changed_cwd) std.process.changeCurDir(cwd_before) catch |err| {
            log.warn("palette theme cwd restore failed path={f} err={}", .{ internal_os.redact.bytes(cwd_before), err });
        };

        var preview = try configpkg.Config.default(alloc);
        errdefer preview.deinit();
        try preview.loadDefaultFiles(alloc);
        try preview.loadCliArgs(alloc);
        try preview.loadRecursiveFiles(alloc);
        try finishPaletteThemeConfig(&preview, &self.app.config, name);
        return preview;
    }

    /// Finish `preview`, loaded as `Config.load` loads, with the palette
    /// theme `name`. It parsed the command line again, so it carries a
    /// startup `--launch-layout` (`finalize` replays it with the theme).
    /// `swapRuntimeConfigFromPalette` installs it as the app config without
    /// the `.app` `config_change` that drops the request, so it is dropped
    /// here; left in, a `new_window` while the preview is live would open
    /// the layout. For the same reason it keeps the `running` config's
    /// profile sources (`keepProfileSources`).
    pub fn finishPaletteThemeConfig(
        preview: *configpkg.Config,
        running: *const configpkg.Config,
        name: []const u8,
    ) !void {
        preview._conditional_state = running._conditional_state;
        try setConfigTheme(preview, name);
        try preview.finalize();
        App.forgetLaunchLayout(preview);
        try keepProfileSources(preview, running);
    }

    pub fn swapRuntimeConfigFromPalette(self: *Host, new_config: configpkg.Config) configpkg.Config {
        const old = self.app.config;
        self.app.config = new_config;
        // A Settings preview stays shown over the palette's theme.
        self.app.restoreSettingsPreview();
        self.app.config_revision +%= 1;
        if (self.app.config_revision == 0) self.app.config_revision = 1;
        self.app.reconfigureTheme();
        for (self.app.registry.windows.items) |surface| {
            surface.core().updateConfig(&self.app.config) catch |err| {
                log.warn("palette theme core apply failed err={}", .{err});
            };
            surface.applyRuntimeConfig(&self.app.config) catch |err| {
                log.warn("palette theme runtime apply failed err={}", .{err});
            };
        }
        for (self.app.registry.hosts.items) |host| {
            host.refreshChrome() catch |err| {
                log.warn("palette theme chrome refresh failed err={}", .{err});
            };
        }
        return old;
    }

    fn preserveOrDeinitPaletteCatalogConfig(
        self: *Host,
        old: configpkg.Config,
    ) void {
        if (self.palette_catalog_config_source == .live) {
            std.debug.assert(self.palette_catalog_retained_config == null);
            self.palette_catalog_retained_config = old;
            self.palette_catalog_config_source = .retained;
        } else {
            var disposable = old;
            disposable.deinit();
        }
    }

    fn replaceRuntimeConfigFromPalette(self: *Host, new_config: configpkg.Config) void {
        const old = self.swapRuntimeConfigFromPalette(new_config);
        self.preserveOrDeinitPaletteCatalogConfig(old);
    }

    fn detachLivePaletteCatalogConfig(self: *Host) !void {
        if (self.palette_catalog_config_source != .live) return;
        var clone = try self.app.config.clone(self.app.core_app.alloc);
        errdefer clone.deinit();
        const old = self.swapRuntimeConfigFromPalette(clone);
        std.debug.assert(self.palette_catalog_retained_config == null);
        self.palette_catalog_retained_config = old;
        self.palette_catalog_config_source = .retained;
    }

    pub fn previewSelectedPaletteTheme(self: *Host) void {
        if (isHighContrastActive()) {
            self.revertPaletteThemePreview();
            return;
        }

        const name = self.selectedPaletteThemeName() orelse {
            self.revertPaletteThemePreview();
            return;
        };
        self.previewPaletteTheme(name) catch |err| {
            log.warn("palette theme preview failed theme={s} err={}", .{ name, err });
            self.revertPaletteThemePreview();
            runUiActionOrLog(
                "palette theme preview banner failed",
                self.setBanner(.err, "Theme preview failed; selection was not applied."),
            );
        };
    }

    pub fn previewPaletteTheme(self: *Host, name: []const u8) !void {
        // Recovery must not load user files or replace its runtime config.
        // A theme can still be saved below, to take effect after restart.
        if (self.app.safe_mode) return;
        if (self.app.config.theme) |current| {
            if (std.mem.eql(u8, current.light, name) and std.mem.eql(u8, current.dark, name)) return;
        }

        var preview = try self.loadPaletteThemeConfig(name);
        errdefer preview.deinit();
        if (self.palette_theme_preview_original == null) {
            const original = self.swapRuntimeConfigFromPalette(preview);
            self.palette_theme_preview_original = original;
            if (self.palette_catalog_config_source == .live) {
                self.palette_catalog_config_source = .preview_original;
            }
        } else {
            self.replaceRuntimeConfigFromPalette(preview);
        }
    }

    pub fn revertPaletteThemePreview(self: *Host) void {
        const original = self.palette_theme_preview_original orelse return;
        self.palette_theme_preview_original = null;
        const old = self.swapRuntimeConfigFromPalette(original);
        switch (self.palette_catalog_config_source) {
            .live => {
                std.debug.assert(self.palette_catalog_retained_config == null);
                self.palette_catalog_retained_config = old;
                self.palette_catalog_config_source = .retained;
            },
            .preview_original => {
                var disposable = old;
                disposable.deinit();
                // The catalog still borrows the same original allocation,
                // which is now the live app config.
                self.palette_catalog_config_source = .live;
            },
            .retained => {
                var disposable = old;
                disposable.deinit();
            },
        }
    }

    pub fn commitPaletteTheme(self: *Host, name: []const u8) !void {
        // The save/reload path can synchronously rebuild the palette catalog.
        // Keep logging and post-save messaging independent of its borrowed
        // theme-name storage.
        const theme_name = try self.app.core_app.alloc.dupe(u8, name);
        defer self.app.core_app.alloc.free(theme_name);

        // Clone the reversible baseline first. Do not detach the live preview
        // owner until every fallible preflight allocation has succeeded;
        // otherwise an OOM could strand the preview with no way to restore it.
        var original = if (self.palette_theme_preview_original) |*value|
            try value.clone(self.app.core_app.alloc)
        else
            try self.app.config.clone(self.app.core_app.alloc);
        var original_owned = true;
        defer if (original_owned) original.deinit();

        var pending = try original.clone(self.app.core_app.alloc);
        defer pending.deinit();
        try setConfigTheme(&pending, theme_name);

        // settingsSaveAndReload may replace/deinit the live app config. Keep
        // the generation borrowed by the visible palette alive first.
        if (!self.app.safe_mode) try self.detachLivePaletteCatalogConfig();

        if (self.palette_theme_preview_original) |*value| {
            if (self.palette_catalog_config_source == .preview_original) {
                std.debug.assert(self.palette_catalog_retained_config == null);
                self.palette_catalog_retained_config = value.*;
                self.palette_catalog_config_source = .retained;
            } else {
                value.deinit();
            }
            self.palette_theme_preview_original = null;
        }

        // The Settings window offers Keep mine / Use disk when the file now
        // says something else for a setting being edited; a palette pick has no
        // such prompt, so a theme that changed on disk is refused instead of
        // overwritten, and the running config is left as it is. Recovery skips
        // reconciliation because its defaults are not a snapshot of that file.
        const save_outcome = win32_settings.saveReloadOutcome(blk: {
            self.app.settingsReconcileDisk(&pending, &original, false) catch |err| break :blk err;
            break :blk self.app.settingsSaveAndReload(&pending, &original);
        });
        switch (save_outcome) {
            .completed, .completed_masked => {},
            .failed => |err| {
                log.warn("palette theme save failed theme={s} err={}", .{ theme_name, err });
                // Roll back without another allocation: `original` is already
                // an owned deep clone of the pre-preview baseline. Transfer it
                // into the runtime config and suppress the local deferred deinit.
                if (!self.app.safe_mode) {
                    self.replaceRuntimeConfigFromPalette(original);
                    original_owned = false;
                }
                self.abortPaletteAction(paletteThemeSaveFailureMessage(err));
                return;
            },
        }
        const saved_but_masked = std.meta.activeTag(save_outcome) == .completed_masked;

        if (self.palette_list_uia_provider) |provider| {
            win32_uia.events.raiseNotification(
                &provider.base,
                .action_completed,
                if (saved_but_masked)
                    "Theme saved; a later config layer masks it"
                else if (self.app.safe_mode)
                    "Theme saved; restart noctty to apply it"
                else
                    "Theme applied",
            );
        }
        self.hideOverlay();
        if (self.app.safe_mode) {
            runUiActionOrLog(
                "palette recovery theme banner failed",
                self.setBanner(.info, "Theme saved; restart noctty to apply it."),
            );
        }
        if (saved_but_masked) {
            log.warn("palette theme saved but masked by a later config layer theme={s}", .{theme_name});
            runUiActionOrLog(
                "palette masked theme banner failed",
                self.setBanner(.err, "Theme saved, but a later config layer masks it."),
            );
        }
        self.layout() catch |err| {
            log.warn("palette theme post-save layout failed err={}", .{err});
        };
    }

    pub const invokePaletteAction = palette_controller.HostControls.invokePaletteAction;

    pub fn postDeferredNewTab(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        const source_surface = self.activeSurface();
        const source_surface_id: WPARAM = if (source_surface) |surface|
            @intCast(surface.core().id)
        else
            0;
        if (sys.PostMessageW(hwnd, c.WM_WINHOSTTY_HOST_NEW_TAB, source_surface_id, 0) == 0) {
            if (source_surface) |surface| {
                runUiActionOrLog("deferred new tab fallback failed", self.app.performAction(.{ .surface = surface.core() }, .new_tab, {}));
            }
        }
    }

    pub fn dispatchDeferredNewTab(self: *Host, source_surface_id: ?u64) void {
        if (source_surface_id) |surface_id| {
            if (self.app.registry.findSurfaceById(surface_id)) |surface| {
                runUiActionOrLog("deferred new tab dispatch failed", self.app.performAction(.{ .surface = surface.core() }, .new_tab, {}));
                return;
            }
        }

        if (self.activeSurface()) |surface| {
            runUiActionOrLog("deferred new tab dispatch failed", self.app.performAction(.{ .surface = surface.core() }, .new_tab, {}));
        }
    }

    pub const scrollPaletteList = palette_controller.HostControls.scrollPaletteList;

    pub const scrollPaletteListAt = palette_controller.HostControls.scrollPaletteListAt;

    pub const paintPaletteList = palette_controller.HostControls.paintPaletteList;

    pub fn deinit(self: *Host) void {
        self.power_notifications.deinit();
        // Stop the tween heartbeat timer before we tear down the
        // scheduler — leaving a SetTimer bound to a destroyed HWND
        // would panic the next time it fired.
        if (self.tween_timer_active) {
            if (self.hwnd) |h| _ = sys.KillTimer(h, c.TWEEN_TIMER_ID);
            self.tween_timer_active = false;
        }
        if (self.search_timer_active) {
            if (self.hwnd) |h| _ = sys.KillTimer(h, c.SEARCH_TIMER_ID);
            self.search_timer_active = false;
        }
        if (self.scrollbar_timer_active) {
            if (self.hwnd) |h| _ = sys.KillTimer(h, c.SCROLLBAR_TIMER_ID);
            self.scrollbar_timer_active = false;
        }
        if (self.resize_settle_timer_active) {
            if (self.hwnd) |h| _ = sys.KillTimer(h, c.RESIZE_SETTLE_TIMER_ID);
            self.resize_settle_timer_active = false;
        }
        if (self.banner_expires_at != null) {
            if (self.hwnd) |h| _ = sys.KillTimer(h, c.BANNER_TIMER_ID);
            self.banner_expires_at = null;
        }
        if (self.mode_timer_active) {
            if (self.hwnd) |h| _ = sys.KillTimer(h, c.INPUT_MODE_TIMER_ID);
            self.mode_timer_active = false;
        }
        self.tween_sched.deinit();

        self.revertPaletteThemePreview();
        if (self.palette_catalog) |*catalog| catalog.reset();
        self.resetPaletteCatalogConfigOwner();
        self.clearPaletteInstalledThemes();
        self.clearPaletteLayoutNames();
        self.destroyChildControls();

        if (self.banner_text) |value| self.app.core_app.alloc.free(value);
        if (self.mode_indicator_text) |value| self.app.core_app.alloc.free(value);
        if (self.config_problems_text) |value| self.app.core_app.alloc.free(value);
        // A prompt still open when its window goes, such as a window-close
        // prompt whose last terminal exited meanwhile.
        if (self.confirm_payload) |*payload| payload.deinit(self.app.core_app.alloc);
        if (self.overlay_completion_seed) |value| self.app.core_app.alloc.free(value);
        if (self.overlay_completion_value) |value| self.app.core_app.alloc.free(value);
        if (self.cached_overlay_edit) |value| self.app.core_app.alloc.free(value);
        if (self.cached_overlay_label) |value| self.app.core_app.alloc.free(value);
        if (self.cached_overlay_hint) |value| self.app.core_app.alloc.free(value);
        if (self.cached_overlay_preview) |value| self.app.core_app.alloc.free(value);
        if (self.cached_overlay_accept) |value| self.app.core_app.alloc.free(value);
        if (self.cached_overlay_cancel) |value| self.app.core_app.alloc.free(value);
        if (self.tab_tooltip_text) |value| self.app.core_app.alloc.free(value);
        if (self.profiles) |profiles| windows_shell.deinitProfiles(self.app.core_app.alloc, profiles);
        if (self.selected_profile_key) |value| self.app.core_app.alloc.free(value);
        if (self.cached_window_title) |value| self.app.core_app.alloc.free(value);
        self.freeCachedChromeStrings();
        if (self.chrome_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.overlay_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.edit_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.chrome_font) |font| _ = sys.DeleteObject(font);
        if (self.preview_font) |font| _ = sys.DeleteObject(font);
        if (self.titlebar_caption_icon_font) |font| _ = sys.DeleteObject(font);
        if (self.titlebar_action_icon_font) |font| _ = sys.DeleteObject(font);
        if (self.search_icon_font) |font| _ = sys.DeleteObject(font);
        self.clearStructuralHistory(.host_destroy);
        self.structural_undo_entries.deinit(self.app.core_app.alloc);
        self.structural_redo_entries.deinit(self.app.core_app.alloc);
        for (self.tabs.items) |*tab| tab.deinit();
        self.tabs.deinit(self.app.core_app.alloc);
        self.* = undefined;
    }

    pub fn destroyChildControls(self: *Host) void {
        if (self.hwnd) |hwnd| {
            if (sys.IsWindow(hwnd) != 0) {
                setWindowData(hwnd, null);
            }
        }

        for (self.tabs.items) |*tab| detachChromeControlProvider(self.app, &tab.uia_provider);
        detachChromeControlProvider(self.app, &self.tab_container_uia_provider);
        detachChromeControlProvider(self.app, &self.new_tab_uia_provider);
        detachChromeControlProvider(self.app, &self.overflow_uia_provider);
        detachChromeControlProvider(self.app, &self.banner_uia_provider);
        for (&self.banner_button_uia_providers) |*provider| detachChromeControlProvider(self.app, provider);

        detachChromeControlProvider(self.app, &self.overlay_title_uia_provider);
        detachChromeControlProvider(self.app, &self.overlay_body_uia_provider);
        destroySubclassedWindow(&self.overlay_label_hwnd, &self.overlay_label_prev_proc);
        if (self.overlay_edit_uia_provider) |provider| {
            self.overlay_edit_uia_provider = null;
            self.overlay_edit_uia_selection = null;
            provider.detach();
            scheduleDeferredUiaDisconnect(
                self.app,
                @ptrCast(provider),
                &terminalDisconnectThunk,
                &terminalReleaseThunk,
            );
        }
        destroySubclassedWindow(&self.overlay_edit_hwnd, &self.overlay_edit_prev_proc);
        destroySubclassedWindow(&self.overlay_hint_hwnd, &self.overlay_hint_prev_proc);
        if (self.overlay_preview_uia_provider) |provider| {
            self.overlay_preview_uia_provider = null;
            provider.detach();
            scheduleDeferredUiaDisconnect(
                self.app,
                @ptrCast(provider),
                &overlayButtonDisconnectThunk,
                &overlayButtonReleaseThunk,
            );
        }
        destroySubclassedWindow(&self.overlay_preview_hwnd, &self.overlay_preview_prev_proc);

        const overlay_button_providers = takeOverlayButtonUiaProviders(
            &self.overlay_accept_uia_provider,
            &self.overlay_cancel_uia_provider,
        );
        inline for (.{ overlay_button_providers.accept, overlay_button_providers.cancel }) |provider_opt| {
            if (provider_opt) |provider| {
                provider.detach();
                scheduleDeferredUiaDisconnect(
                    self.app,
                    @ptrCast(provider),
                    &overlayButtonDisconnectThunk,
                    &overlayButtonReleaseThunk,
                );
            }
        }
        const overlay_prev = self.overlay_button_prev_proc;
        self.overlay_button_prev_proc = null;
        destroySubclassedWindowWithPrev(&self.overlay_accept_hwnd, overlay_prev);
        destroySubclassedWindowWithPrev(&self.overlay_cancel_hwnd, overlay_prev);

        const chrome_prev = self.chrome_button_prev_proc;
        self.chrome_button_prev_proc = null;
        destroySubclassedWindowWithPrev(&self.new_tab_hwnd, chrome_prev);
        destroySubclassedWindowWithPrev(&self.overflow_hwnd, chrome_prev);
        for (&self.banner_buttons) |*button| destroySubclassedWindowWithPrev(button, chrome_prev);
        destroySubclassedWindow(&self.banner_hwnd, &self.banner_prev_proc);
        destroySubclassedWindow(&self.tab_container_hwnd, &self.tab_container_prev_proc);

        if (self.root_uia_provider) |provider| {
            self.root_uia_provider = null;
            provider.detach();
            scheduleDeferredUiaDisconnect(
                self.app,
                @ptrCast(provider),
                &rootDisconnectThunk,
                &rootReleaseThunk,
            );
        }
        if (self.palette_list_uia_provider) |provider| {
            self.palette_list_uia_provider = null;
            provider.detach();
            scheduleDeferredUiaDisconnect(
                self.app,
                @ptrCast(provider),
                &paletteDisconnectThunk,
                &paletteReleaseThunk,
            );
        }
        destroyChildWindow(&self.palette_list_hwnd);
        destroyChildWindow(&self.tab_drop_preview_hwnd);
        detachChromeControlProvider(self.app, &self.tab_tooltip_uia_provider);
        destroyChildWindow(&self.tab_tooltip_hwnd);
        self.tab_tooltip_tab_id = null;

        self.hovered_button_hwnd = null;
        self.tab_close_hover_hwnd = null;
        self.tab_close_prev_hwnd = null;
    }

    pub fn activeTab(self: *Host) ?*Tab {
        if (self.tabs.items.len == 0 or self.active_tab >= self.tabs.items.len) return null;
        return &self.tabs.items[self.active_tab];
    }

    pub fn findTabForSurface(surface: *Surface) ?struct { host: *Host, index: usize, tab: *Tab } {
        const host = surface.host orelse return null;
        for (host.tabs.items, 0..) |*tab, index| {
            if (tab.findHandle(surface) != null) {
                return .{ .host = host, .index = index, .tab = tab };
            }
        }
        return null;
    }

    pub fn focusedSurfaceForTab(host: *Host, tab_id: u32) ?*Surface {
        for (host.tabs.items) |*tab| {
            if (tab.id != tab_id) continue;
            return tab.focusedSurface();
        }

        return null;
    }

    pub fn activeSurface(self: *const Host) ?*Surface {
        if (self.tabs.items.len == 0 or self.active_tab >= self.tabs.items.len) return null;
        const tab: *const Tab = &self.tabs.items[self.active_tab];
        return tab.focusedSurface();
    }

    pub fn refocusHostWindow(self: *Host) void {
        if (self.hwnd) |hwnd| {
            _ = sys.SetFocus(hwnd);
        }
    }

    pub fn handleEmptyHostKeyMessage(
        self: *Host,
        msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) bool {
        if (self.activeSurface() != null) return false;
        var message = keyEventFromWin32Message(msg, wParam, lParam, true) orelse return false;
        message.bindText();
        // `App.keyEvent` does not apply `key-remap` itself; only
        // `Surface.keyCallback` does, and there is no surface here.
        const event = remapWin32KeyEvent(message.event, &self.app.config.@"key-remap");
        return self.app.emptyHostKeyEvent(self.id, event);
    }

    pub fn prepareActiveTabVisibility(self: *Host, active_index: usize) void {
        for (self.tabs.items, 0..) |*tab, i| {
            const active = i == active_index;
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                entry.view.host_active = active;
                if (!active) {
                    entry.view.setVisible(false);
                    _ = entry.view.hideSearchBarControls();
                }
            }
        }
    }

    /// Show the panes of `tab`, the active one (only its zoomed pane when it
    /// has one), and lay the window out, with each pane's terminal resizes
    /// held until the whole tab is placed.
    /// `setVisible` puts a pane hidden during a DPI change into the new font
    /// at its old size, and the layout gives it its new size later, after the
    /// other panes' fonts; on their own the first resize is the old pixel
    /// size in the new cells (measured: 32x18 before 49x28 for a split pane
    /// shown by `goto_tab` at a higher DPI, with a slow font build).
    pub fn showTabPanes(self: *Host, tab: *Tab) void {
        // Nothing here starts a core, so a pane whose core runs at the end
        // is one whose batch was opened.
        var batch_it = tab.tree.iterator();
        while (batch_it.next()) |entry| _ = entry.view.beginCoreResizeBatch();
        defer {
            var end_it = tab.tree.iterator();
            while (end_it.next()) |entry| entry.view.endCoreResizeBatch(entry.view.core_initialized);
        }
        var show_it = tab.tree.iterator();
        while (show_it.next()) |entry| {
            // A zoomed tab shows its zoomed pane alone. Showing the others
            // would put the new DPI's font into them at their old size, and
            // the layout hides them again without placing them, so that grid
            // would stay until the zoom ends; hidden, they take the font when
            // a layout places and shows them.
            if (tab.tree.zoomed) |zoomed| if (entry.handle != zoomed) continue;
            entry.view.setVisible(true);
        }
        runUiActionOrLog("tab activation layout failed", self.layout());
    }

    pub fn invalidateActiveSearchBarLayoutCaches(self: *Host) void {
        if (self.activeTab()) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                entry.view.invalidateSearchBarLayoutCache();
            }
        }
    }

    pub fn tabIndexForButton(self: *Host, button_hwnd: HWND) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.button_hwnd == button_hwnd) return i;
        }
        return null;
    }

    pub fn destroyTabButton(self: *Host, tab: *Tab) void {
        if (self.tab_tooltip_tab_id) |shown| {
            if (shown == tab.id) self.hideTabTooltip();
        }
        detachChromeControlProvider(self.app, &tab.uia_provider);
        destroySubclassedWindow(&tab.button_hwnd, &tab.button_prev_proc);
    }

    pub fn tabIndexAtScreenX(self: *Host, screen_x: i32) ?usize {
        if (!self.shouldShowTabBar()) return null;
        for (self.tabs.items, 0..) |tab, i| {
            if (!tab.button_placement.visible_known or !tab.button_placement.visible) continue;
            const btn = tab.button_hwnd orelse continue;
            var rect: RECT = undefined;
            if (sys.GetWindowRect(btn, &rect) == 0) continue;
            // Check if screen_x falls within the button's horizontal midpoint region
            if (screen_x >= rect.left and screen_x < rect.right) return i;
        }
        return null;
    }

    test "chrome pointer drag ignores hidden buttons with stale rectangles" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(tabDragHiddenButtonTestBody);
    }

    fn tabDragHiddenButtonTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host },
                .{ .storage = &surface_b, .host = &host },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
            },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = try host.syncTabButtons();
        // Hidden overflow buttons retain their old rect. Put one under the
        // visible button so an unfiltered lookup incorrectly returns index 0.
        for (host.tabs.items, 0..) |*tab, i| {
            const button = tab.button_hwnd.?;
            _ = applyChildRect(button, &tab.button_placement, .{
                .left = 20,
                .top = 0,
                .right = 120,
                .bottom = 32,
            });
            _ = applyChildVisibility(button, &tab.button_placement, i == 1);
        }
        var rect: RECT = undefined;
        try std.testing.expect(sys.GetWindowRect(host.tabs.items[1].button_hwnd.?, &rect) != 0);
        const x = rect.left + 10;
        try std.testing.expectEqual(@as(?usize, 1), host.tabIndexAtScreenX(x));
        host.tab_wheel_steps.remainder = 60;
        app.config.@"window-show-tab-bar" = .never;
        try host.layout();
        try std.testing.expectEqual(@as(i32, 0), host.tab_wheel_steps.remainder);
        try std.testing.expectEqual(@as(?usize, null), host.tabIndexAtScreenX(x));
    }

    pub fn swapTabs(self: *Host, a: usize, b: usize) void {
        if (a == b) return;
        if (a >= self.tabs.items.len or b >= self.tabs.items.len) return;
        var shell_prepared: ?win32_shell.runtime.Prepared = null;
        if (self.app.shell_runtime_initialized) shell: {
            const shell_id = self.tabs.items[a].shell_id orelse {
                log.err("refusing tab drag reorder: shell tab mapping missing", .{});
                return;
            };
            shell_prepared = self.app.shell_runtime.prepare(.{ .reorder_tab = .{
                .tab = shell_id,
                .index = b,
            } }) catch |err| {
                log.err("refusing tab drag reorder: shell preflight failed err={}", .{err});
                return;
            };
            break :shell;
        }
        defer if (shell_prepared) |*prepared| prepared.deinit();
        if (!self.tryClearStructuralHistory(.normal)) {
            log.err("refusing tab drag reorder: structural history disposal deferred", .{});
            return;
        }

        const old_active = self.active_tab;
        const moved = self.tabs.orderedRemove(a);
        self.tabs.insertAssumeCapacity(b, moved);
        self.active_tab = movedIndexAfterReorder(old_active, a, b);
        // The history clear above can have committed releases (see `moveTab`).
        if (shell_prepared) |*prepared| prepared.commitRetryingStale(&self.app.shell_runtime) catch |err| {
            const rollback = self.tabs.orderedRemove(b);
            self.tabs.insertAssumeCapacity(a, rollback);
            self.active_tab = old_active;
            log.err("tab drag reorder shell commit failed err={}", .{err});
            return;
        };
        if (shell_prepared) |*prepared| self.app.applyShellEffects(prepared.effects(), .{});
        self.tabs.items[a].clearRedoHistory();
        self.tabs.items[b].clearRedoHistory();
        self.app.auditShellNativeMapping("tab-drag-reorder");
        runUiActionOrLog("tab drag reorder layout failed", self.layout());
    }

    /// Hide the tooltip popup if one is up (a tab's title or a chrome button's name).
    pub fn hideTabTooltip(self: *Host) void {
        self.tab_tooltip_tab_id = null;
        self.button_tooltip.shown = null;
        if (self.tab_tooltip_text) |value| {
            self.app.core_app.alloc.free(value);
            self.tab_tooltip_text = null;
        }
        const hwnd = self.tab_tooltip_hwnd orelse return;
        _ = sys.ShowWindow(hwnd, c.SW_HIDE);
    }

    /// The name an icon-only chrome button's hover tooltip spells out: the
    /// search bar's six buttons and the tab strip's [+] and [v]. It is the
    /// button's UIA name, from the same tables, so the two always agree.
    pub fn chromeButtonTooltipName(self: *const Host, button: HWND) ?[]const u8 {
        if (self.new_tab_hwnd == button) return labels.tabStripActionName(.new_tab);
        if (self.overflow_hwnd == button) return labels.tabStripActionName(.more_tabs);
        const role = self.searchBarButtonRole(button) orelse return null;
        return labels.searchBarButtonName(role);
    }

    /// Name an icon-only chrome button in a tooltip under it. The icons
    /// are small drawn glyphs, so the name is otherwise only available to
    /// screen readers. `ButtonTooltip.apply` has already decided the tooltip
    /// should come up for `button`.
    pub fn showChromeButtonTooltip(self: *Host, button: HWND) void {
        const text = self.chromeButtonTooltipName(button) orelse return;
        const name_changed = !ownedStringEquals(self.tab_tooltip_text, text);
        self.presentTooltip(button, sys.IsWindowVisible(button) != 0, text, name_changed, .{ .button = button });
    }

    /// Show the full title of the tab drawn by `button`, under that tab.
    pub fn showTabTooltip(self: *Host, button: HWND) void {
        const index = self.tabIndexForButton(button) orelse return self.hideTabTooltip();
        const tab = &self.tabs.items[index];
        if (self.tab_tooltip_tab_id) |shown| {
            // The hover timer re-arms on every pointer move inside the tab, so
            // this fires repeatedly while the tooltip is already up.
            if (shown == tab.id) return;
        }
        self.presentTabTooltip(index, true);
    }

    /// Bring the tooltip up to date with the tab it is up for, in place.
    ///
    /// `syncTabButtons` calls this after a label rebuild touched that tab. It
    /// used to hide the tooltip instead, which suits a rename but not a title
    /// that animates: Claude Code, among others, spins a glyph through the OSC
    /// title while it works, so the popup went down on every frame and the
    /// next hover dwell brought it back -- a flicker for as long as the pointer
    /// rested on the tab, or a tooltip that never came back when the pointer
    /// held still. `title_changed` is whether the title itself moved rather
    /// than the width budget, so a reader hears NameChanged only when the name
    /// it reports did change.
    fn refreshTabTooltip(self: *Host, title_changed: bool) void {
        const shown = self.tab_tooltip_tab_id orelse return;
        const index = self.findTabIndexById(shown) orelse return self.hideTabTooltip();
        self.presentTabTooltip(index, title_changed);
    }

    /// Show, or update in place, the tooltip for the tab at `index`.
    ///
    /// Only a tab whose label had to be compacted gets one: when the whole
    /// title already fits the button, repeating it under the pointer is noise.
    /// Every step is best-effort. A tooltip that cannot be measured, placed or
    /// created is simply not shown -- this is chrome, and the terminal
    /// underneath has to keep working either way. `name_changed` says whether
    /// the name the popup reports to UIA differs from what it reported before.
    fn presentTabTooltip(self: *Host, index: usize, name_changed: bool) void {
        if (self.hwnd == null) return;
        const tab = &self.tabs.items[index];
        const button = tab.button_hwnd orelse return self.hideTabTooltip();
        const title = tab.cached_button_title orelse return self.hideTabTooltip();
        // Measure the title against the budget the title was actually
        // compacted to, not the drawn label against the button's own budget.
        // The label also carries the tab index, the active marker and the pane
        // count; `buildTabButtonLabel` charges those to the button budget
        // first, so comparing the whole label against that budget asked
        // whether a label that is built to fit fits. It also answered
        // differently for an active tab than for its inactive neighbour
        // showing the same title.
        const budget = labels.tabButtonTitleBudget(
            tab.cached_button_index,
            tab.cached_button_active,
            tab.cached_button_pane_count,
            win32_bell.tabTextWidth(tab.cached_button_label_max_width, tab.cached_button_bell),
            tab.cached_button_show_pane_count,
        );
        if (!labels.hostLabelIsCompacted(title, budget)) {
            return self.hideTabTooltip();
        }

        const alloc = self.app.core_app.alloc;
        const text = labels.buildTabTooltipText(alloc, title) catch return;
        defer alloc.free(text);

        // The strip's own visibility record is consulted, not the rect: a
        // button that scrolled out of `visibleTabRange` (or a strip turned
        // off by config) is hidden with `ShowWindow` alone and keeps its last
        // rect, which now describes some other tab's slot.
        const button_visible = self.shouldShowTabBar() and
            tab.button_placement.visible_known and
            tab.button_placement.visible;
        self.presentTooltip(button, button_visible, text, name_changed, .{ .tab = tab.id });
    }

    /// What the shared tooltip popup currently describes.
    const TooltipOwner = union(enum) {
        /// A tab whose compacted label hides part of its title.
        tab: u32,
        /// A chrome button whose icon needs its name spelled out.
        button: HWND,
    };

    /// Show, or update in place, the tooltip popup with `text` under `anchor`.
    ///
    /// Shared by the tab strip and the icon-only chrome buttons, so both get
    /// the same popup, placement and UIA provider. Every step is best-effort:
    /// a tooltip that cannot be measured, placed or created is simply not
    /// shown.
    fn presentTooltip(
        self: *Host,
        anchor: HWND,
        anchor_visible: bool,
        text: []const u8,
        name_changed: bool,
        owner: TooltipOwner,
    ) void {
        const host_hwnd = self.hwnd orelse return;
        const alloc = self.app.core_app.alloc;
        const text_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, text) catch return;
        defer alloc.free(text_w);

        var button_rect: RECT = undefined;
        if (sys.GetWindowRect(anchor, &button_rect) == 0) return;
        // The tooltip describes what the pointer rests on. A relayout can move
        // the anchor out from under a pointer that has not moved, and the
        // button's WM_MOUSELEAVE for that arrives on the tracker's own clock,
        // so check here rather than re-present the popup under a control
        // nobody points at.
        var cursor: POINT = undefined;
        if (sys.GetCursorPos(&cursor) == 0) return self.hideTabTooltip();
        if (!win32_tab_tooltip.mayPresent(
            anchor_visible,
            .{ .x = cursor.x, .y = cursor.y },
            .{
                .left = button_rect.left,
                .top = button_rect.top,
                .right = button_rect.right,
                .bottom = button_rect.bottom,
            },
        )) return self.hideTabTooltip();
        var anchor_top_left: POINT = .{ .x = button_rect.left, .y = button_rect.top };
        var anchor_bottom_right: POINT = .{ .x = button_rect.right, .y = button_rect.bottom };
        if (sys.ScreenToClient(host_hwnd, &anchor_top_left) == 0) return;
        if (sys.ScreenToClient(host_hwnd, &anchor_bottom_right) == 0) return;

        var client: RECT = undefined;
        if (sys.GetClientRect(host_hwnd, &client) == 0) return;

        const size = self.measureTabTooltip(host_hwnd, text_w) orelse return;
        const placement = win32_tab_tooltip.place(
            .{
                .left = anchor_top_left.x,
                .top = anchor_top_left.y,
                .right = anchor_bottom_right.x,
                .bottom = anchor_bottom_right.y,
            },
            size,
            .{
                .left = client.left,
                .top = client.top,
                .right = client.right,
                .bottom = client.bottom,
            },
            self.scaled(4),
            self.scaled(6),
        );

        if (self.tab_tooltip_hwnd == null) {
            self.app.ensureTabTooltipClass() catch return;
            const created = sys.CreateWindowExW(
                // WS_EX_TRANSPARENT: the popup hangs a few pixels under its
                // tab, and a pointer resting near the tab's bottom edge would
                // otherwise leave the button, hide the tooltip, re-enter, and
                // flicker. NOACTIVATE and TOOLWINDOW keep it out of the focus
                // and taskbar paths.
                c.WS_EX_TRANSPARENT | c.WS_EX_NOACTIVATE | c.WS_EX_TOOLWINDOW,
                tab_tooltip_class_name,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                // Top level, owned by the host. A WS_CHILD popup drew fine and
                // was then painted away by the terminal surface's next frame:
                // the surfaces are siblings that repaint on their own clock,
                // and no Z order among children survives that.
                c.WS_POPUP,
                0,
                0,
                0,
                0,
                host_hwnd,
                null,
                self.app.hinstance,
                null,
            ) orelse return;
            setWindowData(created, self);
            self.tab_tooltip_hwnd = created;
            // AGENTS.md: a new UI widget ships with its provider. The tooltip
            // is not focusable and exposes no pattern -- a reader needs its
            // name and its ToolTip control type, nothing more.
            self.tab_tooltip_uia_provider = self.createChromeUiaProvider(created, .{
                .ctx = @ptrCast(self),
                .role = .tooltip,
                .name = &tabTooltipUiaName,
            });
        }
        const tooltip = self.tab_tooltip_hwnd orelse return;
        // The popup remembers its text so a refresh that leaves it unchanged
        // does not repaint; it is still re-placed below, since the button's
        // rect may have moved. That is a paint decision only: the UIA name
        // is the FULL title (`tabTooltipUiaName`), while `text` is bounded
        // by `tab_tooltip_max_width`, so a title that changed past that
        // bound renders identically and must still announce -- `name_changed`
        // is computed on the full title by the caller for exactly that
        // reason.
        const text_changed = !ownedStringEquals(self.tab_tooltip_text, text);
        appendOwnedString(alloc, &self.tab_tooltip_text, text) catch return;
        _ = sys.SetWindowTextW(tooltip, text_w.ptr);
        switch (owner) {
            .tab => |id| {
                self.tab_tooltip_tab_id = id;
                self.button_tooltip.shown = null;
            },
            .button => |button| {
                self.tab_tooltip_tab_id = null;
                self.button_tooltip.shown = button;
            },
        }
        if (name_changed) {
            if (self.tab_tooltip_uia_provider) |provider| provider.raiseNameChanged();
        }
        // `place` works in the host's client space; the popup is top level.
        var origin: POINT = .{ .x = placement.left, .y = placement.top };
        if (sys.ClientToScreen(host_hwnd, &origin) == 0) return self.hideTabTooltip();
        _ = sys.SetWindowPos(
            tooltip,
            null,
            origin.x,
            origin.y,
            placement.width(),
            placement.height(),
            c.SWP_NOACTIVATE,
        );
        _ = sys.ShowWindow(tooltip, c.SW_SHOWNOACTIVATE);
        if (text_changed) _ = sys.InvalidateRect(tooltip, null, 1);
    }

    /// Size the tooltip popup needs for `text`, in client pixels.
    fn measureTabTooltip(
        self: *Host,
        host_hwnd: HWND,
        text: [:0]const u16,
    ) ?win32_tab_tooltip.Size {
        const len = std.math.cast(i32, text.len) orelse return null;
        const hdc = sys.GetDC(host_hwnd) orelse return null;
        defer _ = sys.ReleaseDC(host_hwnd, hdc);
        if (self.chrome_font) |font| _ = sys.SelectObject(hdc, font);
        var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (sys.DrawTextW(
            hdc,
            text.ptr,
            len,
            &rect,
            c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX,
        ) == 0) return null;
        return .{
            .width = rect.right - rect.left + self.scaled(16),
            .height = rect.bottom - rect.top + self.scaled(8),
        };
    }

    /// Paint the tab title tooltip popup.
    ///
    /// `hwnd` is the window the message was sent to, not `tab_tooltip_hwnd`:
    /// WM_PAINT has to validate the update region of the window it was posted
    /// for. Reading the host's own handle first and returning when it is gone
    /// left the region dirty, and Windows re-posts WM_PAINT for a dirty window
    /// forever -- a spin the message pump cannot leave.
    pub fn paintTabTooltip(self: *Host, hwnd: HWND) void {
        var ps: PAINTSTRUCT = undefined;
        const hdc = sys.BeginPaint(hwnd, &ps);
        defer _ = sys.EndPaint(hwnd, &ps);

        var rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &rect) == 0) return;

        self.ensureThemeBrushes() catch return;
        const theme = &self.app.resolved_theme;
        // DESIGN.md: 6 px corners for overlays.
        drawRoundedRect(
            hdc,
            rect,
            theme.overlay_bg,
            theme.overlay_border,
            self.scaled(6),
        );

        if (self.chrome_font) |font| _ = sys.SelectObject(hdc, font);
        var text_buf: [labels.tab_tooltip_max_width * 2 + 1]u16 = undefined;
        const text_len = sys.GetWindowTextW(hwnd, &text_buf, text_buf.len);
        _ = sys.SetBkMode(hdc, c.TRANSPARENT);
        _ = sys.SetTextColor(hdc, theme.overlay_label_fg);
        var text_rect = rect;
        text_rect.left += self.scaled(8);
        text_rect.right -= self.scaled(8);
        _ = sys.DrawTextW(
            hdc,
            @ptrCast(&text_buf),
            text_len,
            &text_rect,
            c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
        );
    }

    pub fn hideTabDropPreview(self: *Host) void {
        self.tab_drop_operation = .none;
        self.tab_drop_target_surface = null;
        if (self.tab_drop_preview_hwnd) |preview| _ = sys.ShowWindow(preview, c.SW_HIDE);
    }

    pub fn updateTabDropPreview(self: *Host, source_index: usize, screen_point: POINT) void {
        if (source_index >= self.tabs.items.len or
            source_index == self.active_tab)
        {
            self.hideTabDropPreview();
            return;
        }
        const hwnd = self.hwnd orelse return self.hideTabDropPreview();
        var client_point = screen_point;
        if (sys.ScreenToClient(hwnd, &client_point) == 0) return self.hideTabDropPreview();
        const target_surface = target: {
            const tab = self.activeTab() orelse return self.hideTabDropPreview();
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                if (!entry.view.placement.rect_known) continue;
                const rect = entry.view.placement.rect;
                if (client_point.x >= rect.left and client_point.x < rect.right and
                    client_point.y >= rect.top and client_point.y < rect.bottom)
                    break :target entry.view;
            }
            return self.hideTabDropPreview();
        };
        const content = target_surface.placement.rect;
        const target = win32_tab_drop_zones.resolve(
            .{ .left = content.left, .top = content.top, .right = content.right, .bottom = content.bottom },
            .{ .x = client_point.x, .y = client_point.y },
            self.current_dpi,
            self.tab_drop_operation,
            .{},
        );
        switch (target.operation) {
            .split_left, .split_right, .split_up, .split_down => {},
            .none, .new_tab => return self.hideTabDropPreview(),
        }
        const preview_rect = target.preview_rect orelse return self.hideTabDropPreview();
        if (self.tab_drop_preview_hwnd == null) {
            self.tab_drop_preview_hwnd = sys.CreateWindowExW(
                c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT,
                prompt_label_class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                c.WS_CHILD,
                preview_rect.left,
                preview_rect.top,
                preview_rect.right - preview_rect.left,
                preview_rect.bottom - preview_rect.top,
                hwnd,
                null,
                self.app.hinstance,
                null,
            );
            if (self.tab_drop_preview_hwnd) |preview| {
                _ = sys.SetLayeredWindowAttributes(preview, 0, 72, c.LWA_ALPHA);
            }
        }
        const preview = self.tab_drop_preview_hwnd orelse return;
        self.tab_drop_operation = target.operation;
        self.tab_drop_target_surface = target_surface;
        const operation_label: LPCWSTR = switch (target.operation) {
            .split_left => std.unicode.utf8ToUtf16LeStringLiteral("Split left"),
            .split_right => std.unicode.utf8ToUtf16LeStringLiteral("Split right"),
            .split_up => std.unicode.utf8ToUtf16LeStringLiteral("Split above"),
            .split_down => std.unicode.utf8ToUtf16LeStringLiteral("Split below"),
            .none, .new_tab => unreachable,
        };
        _ = sys.SetWindowTextW(preview, operation_label);
        _ = sys.SetWindowPos(
            preview,
            null,
            preview_rect.left,
            preview_rect.top,
            preview_rect.right - preview_rect.left,
            preview_rect.bottom - preview_rect.top,
            c.SWP_NOACTIVATE,
        );
        _ = sys.ShowWindow(preview, c.SW_SHOWNOACTIVATE);
        _ = sys.InvalidateRect(preview, null, 1);
    }

    pub fn commitTabDropSplit(self: *Host, source_index: usize) bool {
        const direction: SplitTreeSurface.Split.Direction = switch (self.tab_drop_operation) {
            .split_left => .left,
            .split_right => .right,
            .split_up => .up,
            .split_down => .down,
            .none, .new_tab => return false,
        };
        if (source_index >= self.tabs.items.len or source_index == self.active_tab) return false;
        const previous_tab_id = self.tabs.items[self.active_tab].id;
        const source_tab_shell = self.tabs.items[source_index].shell_id orelse return false;
        const source_model = self.app.shell_runtime.state.tabConst(source_tab_shell) orelse return false;
        const source_root = source_model.root;
        const source_surface = self.tabs.items[source_index].focusedSurface() orelse return false;
        const target_surface = self.tab_drop_target_surface orelse return false;
        const target_found = Host.findTabForSurface(target_surface) orelse return false;
        if (target_found.host != self or target_found.index != self.active_tab) return false;
        const target_pane = target_surface.shell_id orelse return false;
        const target_tab_id = self.tabs.items[self.active_tab].id;
        const target_handle = self.tabs.items[self.active_tab].findHandle(target_surface) orelse return false;
        var next_tree = self.tabs.items[self.active_tab].tree.split(
            self.app.core_app.alloc,
            target_handle,
            direction,
            0.5,
            &self.tabs.items[source_index].tree,
        ) catch return false;
        self.structural_undo_entries.ensureUnusedCapacity(self.app.core_app.alloc, 1) catch |err| {
            next_tree.deinit();
            log.err("tab split transfer history preflight failed err={}", .{err});
            return false;
        };
        const model_direction: win32_shell.model.Direction = switch (direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        };
        var shell_prepared = self.app.shell_runtime.prepare(.{ .transfer_subtree = .{
            .source_root = source_root,
            .target_pane = target_pane,
            .direction = model_direction,
            .ratio = 0.5,
        } }) catch |err| {
            next_tree.deinit();
            log.err("tab split transfer shell preflight failed err={}", .{err});
            return false;
        };
        defer shell_prepared.deinit();
        if (!self.tryClearStructuralHistory(.normal)) {
            next_tree.deinit();
            log.err("tab split transfer history disposal deferred", .{});
            return false;
        }
        // A prompt one of the dragged tab's terminals raised is about to lose
        // its tab: a close prompt would find the target tab through the same
        // terminal and close all of it.
        self.cancelConfirmFromTab(&self.tabs.items[source_index]);

        const target_node_count = self.tabs.items[self.active_tab].tree.nodes.len;
        const source_focus = self.tabs.items[source_index].focused;
        const prior_target_tree = self.tabs.items[self.active_tab].tree;
        const prior_target_focus = self.tabs.items[self.active_tab].focused;
        self.tabs.items[self.active_tab].tree = next_tree;
        self.tabs.items[self.active_tab].focused = @enumFromInt(target_node_count + source_focus.idx());
        var removed = self.tabs.orderedRemove(source_index);
        self.destroyTabButton(&removed);
        removed.button_placement = .{};
        removed.button_label_cache_valid = false;
        const target_index = self.findTabIndexById(target_tab_id) orelse unreachable;
        self.active_tab = target_index;
        _ = self.appendStructuralUndoAssumeCapacity(.{
            .kind = .tab_subtree_transfer,
            .timestamp_ms = sys.GetTickCount64(),
            .sequence_id = self.app.nextUndoSequence(),
            .payload = .{ .tab_subtree_transfer = .{
                .source_tab = removed,
                .source_index = source_index,
                .source_tab_id = removed.id,
                .target_tab_id = target_tab_id,
                .alternate_tree = prior_target_tree,
                .alternate_focus = prior_target_focus,
                .source_root = source_root,
            } },
        });
        // The history clear above can have committed releases (see `moveTab`).
        shell_prepared.commitRetryingStale(&self.app.shell_runtime) catch |err| {
            var failed = self.structural_undo_entries.pop().?;
            const payload = &failed.payload.tab_subtree_transfer;
            const live_target_index = self.findTabIndexById(target_tab_id) orelse unreachable;
            var combined = self.tabs.items[live_target_index].tree;
            self.tabs.items[live_target_index].tree = payload.alternate_tree;
            self.tabs.items[live_target_index].focused = payload.alternate_focus;
            combined.deinit();
            self.tabs.insertAssumeCapacity(source_index, payload.source_tab.?);
            payload.source_tab = null;
            self.active_tab = self.findTabIndexById(target_tab_id) orelse self.active_tab;
            log.err("tab split transfer shell commit failed err={}", .{err});
            return false;
        };
        self.app.applyShellEffects(shell_prepared.effects(), .{});
        const committed_entry = &self.structural_undo_entries.items[self.structural_undo_entries.items.len - 1];
        if (committed_entry.payload.tab_subtree_transfer.source_tab) |*source_tab| {
            source_tab.clearRedoHistory();
        }
        // The moved panes bring their programs' status with them. Only now:
        // a failed commit above restores the target's own panes.
        self.refreshTabStatus(self.active_tab);
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        self.notifyTabListUiaChanged();
        self.tabs.items[self.active_tab].clearRedoHistory();
        while (self.structural_undo_entries.items.len > win32_undo.max_entries) {
            win32_structural_history.evictOldest(
                StructuralUndoEntry,
                &self.structural_undo_entries,
                self,
                disposeStructuralNormalLogged,
            ) catch break;
        }
        source_surface.host_active = true;
        source_surface.setVisible(true);
        runUiActionOrLog("tab subtree transfer layout failed", self.layout());
        self.app.activateSurface(source_surface);
        self.app.auditShellNativeMapping("tab-subtree-transfer");
        return true;
    }

    pub fn activateTabIndex(self: *Host, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        const previous_index = self.active_tab;
        const previous_tab_id = if (previous_index < self.tabs.items.len)
            self.tabs.items[previous_index].id
        else
            null;
        if (self.active_tab != index) {
            // Hide inactive tab HWNDs/search controls before the active
            // index changes so rapid Ctrl+Tab repeats don't leave previous
            // tab toolbar fragments painted over the next tab.
            self.prepareActiveTabVisibility(index);
        }
        self.active_tab = index;
        self.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        // `layoutChromeForRect` reads `active_tab` to move the active
        // tab's join to its terminal (`syncTabJoin`), so lay out now
        // rather than at the next incidental layout tick.
        runUiActionOrLog("tab activation layout failed", self.layout());
        if (self.tabs.items[index].focusedSurface()) |surface| {
            self.app.activateSurface(surface);
            self.forceHostCompositionPaint();
            return true;
        }
        self.forceHostCompositionPaint();
        return false;
    }

    /// Close tab `index` for a gesture of the tab strip: see
    /// `tabCloseAction`. A window's only tab closes the window, which asks
    /// once, like the window's own close button, when a process in it would
    /// be lost. `self` may be gone when this returns true.
    pub fn closeTabFromStrip(self: *Host, index: usize) bool {
        switch (tabCloseAction(self.tabs.items.len)) {
            .none => return false,
            .close_tab => return self.closeTabInPlace(index),
            .close_window => {
                if (index >= self.tabs.items.len) return false;
                self.close();
                return true;
            },
        }
    }

    /// Close tab `index` from its own button (its X, a middle click, Delete)
    /// where it is, without selecting it first, so closing a background tab
    /// leaves the active tab in front. `close_tab:this` keeps the tab for
    /// undo, and asks only where undo is off (`undo-timeout = 0`).
    pub fn closeTabInPlace(self: *Host, index: usize) bool {
        if (index >= self.tabs.items.len) return false;
        const tab = &self.tabs.items[index];
        const surface = tab.focusedSurface() orelse return false;
        // Delete on a focused background tab destroys the focused button;
        // the keyboard stays in the tab strip rather than jumping away.
        const button_focused = index != self.active_tab and
            tab.button_hwnd != null and sys.GetFocus() == tab.button_hwnd;
        const tab_count = self.tabs.items.len;
        const closed = self.app.closeTab(.{ .surface = surface.core() }, .this) catch |err| {
            log.warn("tab close failed err={}", .{err});
            return false;
        };
        // A close that asked first has closed nothing, and the keys belong to
        // its prompt.
        if (closed and button_focused and self.tabs.items.len < tab_count) {
            if (self.tabStripFocusHwnd()) |next| _ = sys.SetFocus(next);
        }
        return closed;
    }

    test "a background tab close that fails puts the tab back with its button" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(backgroundCloseRollbackTestBody);
    }

    fn backgroundCloseRollbackTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .active_tab = 1 }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
            },
            // The tabs have no shell IDs, so the shell detach fails after
            // the native detach, as a real shell-side failure would.
            .shell_runtime_initialized = true,
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        try host.refreshChrome();
        try std.testing.expect(host.tabs.items[0].button_hwnd != null);
        // B is in front with focus, so activating it again changes nothing.
        surface_b.window_visible = true;
        surface_b.window_focused = true;

        try std.testing.expect(!host.closeTabInPlace(0));
        try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 1), host.active_tab);
        try std.testing.expect(host.tabs.items[0].button_hwnd != null);
    }

    test "a background tab close or its redo lays out the strip and leaves focus and hidden windows alone" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(backgroundCloseStripTestBody);
    }

    fn backgroundCloseStripTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var surface_c: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .active_tab = 2 }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
                .{ .storage = &surface_c, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
                .{ .host = &host, .surface = &surface_c, .id = 3 },
            },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        // Wide enough to show all three tab buttons side by side.
        _ = sys.MoveWindow(window.parent, 0, 0, 1200, 300, 0);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        try host.refreshChrome();
        try host.layout();
        const first_left = host.tabs.items[0].button_placement.rect.left;
        try std.testing.expect(host.tabs.items[1].button_placement.visible);
        try std.testing.expect(host.tabs.items[1].button_placement.rect.left > first_left);
        // C is in front with focus, so activating it again changes nothing.
        // Layout repaints the active tab's panes, which need windows.
        surface_a.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        surface_b.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        surface_c.hwnd = window.pane;
        defer for ([_]*Surface{ &surface_a, &surface_b, &surface_c }) |surface| {
            surface.hwnd = null;
        };
        surface_c.window_visible = true;
        surface_c.window_focused = true;

        // Delete on A's focused button while the windows are hidden: the
        // strip closes the gap, the keyboard stays in the strip, and
        // nothing shows the windows.
        _ = sys.SetFocus(host.tabs.items[0].button_hwnd.?);
        app.windows_hidden = true;
        try std.testing.expect(host.closeTabInPlace(0));
        try std.testing.expect(app.windows_hidden);
        app.windows_hidden = false;
        try std.testing.expectEqual(@as(?*Surface, &surface_c), host.activeSurface());
        try std.testing.expectEqual(first_left, host.tabs.items[0].button_placement.rect.left);
        try std.testing.expectEqual(host.tabStripFocusHwnd(), sys.GetFocus());

        // Undo brings A back behind C, which the close left in front; redo
        // closes A in the background again and the strip closes the gap again.
        _ = try host.applyLatestStructuralUndo();
        try std.testing.expectEqual(@as(?*Surface, &surface_c), host.activeSurface());
        surface_c.window_visible = true;
        surface_c.window_focused = true;
        try std.testing.expect(host.tabs.items[0].button_placement.rect.left == first_left);
        try std.testing.expect(host.tabs.items[1].button_placement.rect.left != first_left);
        _ = try host.applyLatestStructuralRedo();
        try std.testing.expectEqual(@as(?*Surface, &surface_c), host.activeSurface());
        try std.testing.expectEqual(first_left, host.tabs.items[0].button_placement.rect.left);
    }

    test "Tab and Shift+Tab walk the tab strip's visible tabs, [+] and [v]; the menu key's release is swallowed" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(tabStripKeyboardTestBody);
    }

    fn tabStripKeyboardTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var surface_c: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .active_tab = 0 }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
                .{ .storage = &surface_c, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
                .{ .host = &host, .surface = &surface_c, .id = 3 },
            },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.MoveWindow(window.parent, 0, 0, 1200, 300, 0);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        try host.refreshChrome();
        try host.layout();
        surface_a.hwnd = window.pane;
        surface_b.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        surface_c.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        defer for ([_]*Surface{ &surface_a, &surface_b, &surface_c }) |surface| {
            surface.hwnd = null;
        };

        // The stops the walk has to visit, read from live visibility.
        var stops: [8]HWND = undefined;
        var count: usize = 0;
        for (0..host.tabs.items.len + 2) |stop| {
            if (host.tabStripStopHwnd(stop)) |stop_hwnd| {
                stops[count] = stop_hwnd;
                count += 1;
            }
        }
        // All three tabs are on screen, in order, and [+] / [v] follow.
        try std.testing.expect(count >= 3);
        for (host.tabs.items, 0..) |tab, i| {
            try std.testing.expectEqual(tab.button_hwnd.?, stops[i]);
        }

        // Forward: each Tab lands on the next stop and wraps at the end.
        const keyboard = win32_input.TestingKeyboard.pinNone();
        defer keyboard.release();
        _ = sys.SetFocus(stops[0]);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try std.testing.expectEqual(@as(LRESULT, 0), sys.SendMessageW(stops[i], c.WM_KEYDOWN, c.VK_TAB, 0));
            try std.testing.expectEqual(@as(?HWND, stops[(i + 1) % count]), sys.GetFocus());
        }
        // Tab moved focus only: the active tab is still the first.
        try std.testing.expectEqual(@as(usize, 0), host.active_tab);

        // Backward with Shift held.
        var held = [_]u8{0} ** 256;
        held[c.VK_SHIFT] = 0x80;
        keyboard.set(&held);
        _ = sys.SetFocus(stops[0]);
        i = 0;
        while (i < count) : (i += 1) {
            const from = stops[(count - i) % count];
            try std.testing.expectEqual(@as(LRESULT, 0), sys.SendMessageW(from, c.WM_KEYDOWN, c.VK_TAB, 0));
            try std.testing.expectEqual(@as(?HWND, stops[(count - i - 1) % count]), sys.GetFocus());
        }
        keyboard.set(&([_]u8{0} ** 256));

        // Enter is a keyboard activation, not a synthetic mouse press.
        const Clicks = struct {
            threadlocal var click_count: usize = 0;
            threadlocal var previous: WNDPROC = undefined;
            fn proc(h: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
                if (msg == c.WM_COMMAND) {
                    click_count += 1;
                    return 0;
                }
                return sys.CallWindowProcW(previous, h, msg, wp, lp);
            }
        };
        Clicks.click_count = 0;
        Clicks.previous = @ptrFromInt(@as(usize, @intCast(sys.SetWindowLongPtrW(window.parent, c.GWLP_WNDPROC, @intCast(@intFromPtr(&Clicks.proc))))));
        defer _ = sys.SetWindowLongPtrW(window.parent, c.GWLP_WNDPROC, @intCast(@intFromPtr(Clicks.previous)));
        const new_tab = host.new_tab_hwnd.?;
        _ = sys.SetFocus(new_tab);
        host.focus_input_mode = .keyboard;
        try std.testing.expectEqual(@as(LRESULT, 0), sys.SendMessageW(new_tab, c.WM_KEYDOWN, c.VK_RETURN, 0));
        try std.testing.expectEqual(focus_cue.InputMode.keyboard, host.focus_input_mode);
        try std.testing.expect(host.button_tooltip.dismissed == null);
        try std.testing.expectEqual(@as(usize, 1), Clicks.click_count);
        _ = sys.SendMessageW(new_tab, c.WM_KEYDOWN, c.VK_RETURN, c.KF_REPEAT);
        try std.testing.expectEqual(@as(usize, 1), Clicks.click_count);

        // [+] and [v] name themselves for the tooltip as UIA does; a tab does not.
        try std.testing.expectEqualStrings("New tab", host.chromeButtonTooltipName(host.new_tab_hwnd.?).?);
        try std.testing.expectEqualStrings("More tabs", host.chromeButtonTooltipName(host.overflow_hwnd.?).?);
        try std.testing.expect(host.chromeButtonTooltipName(host.tabs.items[0].button_hwnd.?) == null);

        // The menu key opens the menu on its key-down; its release must not
        // post a second WM_CONTEXTMENU (a sent one is swallowed by the proc).
        const tab_button = host.tabs.items[0].button_hwnd.?;
        var queued: sys.MSG = undefined;
        try std.testing.expectEqual(@as(LRESULT, 0), sys.SendMessageW(tab_button, c.WM_KEYUP, c.VK_APPS, 0));
        try std.testing.expectEqual(@as(BOOL, 0), sys.PeekMessageW(&queued, tab_button, c.WM_CONTEXTMENU, c.WM_CONTEXTMENU, c.PM_REMOVE));
        try std.testing.expectEqual(@as(LRESULT, 0), sys.SendMessageW(tab_button, c.WM_SYSKEYUP, c.VK_F10, 0));
        try std.testing.expectEqual(@as(BOOL, 0), sys.PeekMessageW(&queued, tab_button, c.WM_CONTEXTMENU, c.WM_CONTEXTMENU, c.PM_REMOVE));
        try std.testing.expectEqual(@as(LRESULT, 0), sys.SendMessageW(tab_button, c.WM_CONTEXTMENU, @intFromPtr(tab_button), -1));
    }

    test "bell glyph marks the alerted tab and the caption, and nothing stored" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(bellGlyphTestBody);
    }

    fn bellGlyphTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .active_tab = 1 }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
            },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.MoveWindow(window.parent, 0, 0, 1200, 300, 0);
        surface_a.title = "alpha";
        surface_b.title = "beta";
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        try host.refreshChrome();

        const glyph = win32_bell.title_glyph;
        var status_buf: [64]u8 = undefined;
        var caption: [128]u16 = undefined;
        var utf8: [256]u8 = undefined;
        const caption_text = struct {
            fn read(hwnd: HWND, wide: *[128]u16, out: *[256]u8) ![]const u8 {
                const len: usize = @intCast(sys.GetWindowTextW(hwnd, wide, wide.len));
                return out[0..try std.unicode.utf16LeToUtf8(out, wide[0..len])];
            }
        }.read;
        try std.testing.expect(!std.mem.startsWith(u8, host.tabs.items[0].cached_button_label.?, glyph));
        try std.testing.expectEqualStrings("", Host.tabItemUiaItemStatus(&host, 1, &status_buf));

        // A background tab rings: its label and UIA status carry the glyph and
        // "Bell"; the caption (tab B) and the stored titles do not.
        surface_a.setBellRinging(true);
        try std.testing.expect(std.mem.indexOf(u8, host.tabs.items[0].cached_button_label.?, glyph) != null);
        try std.testing.expectEqualStrings("alpha", host.tabs.items[0].cached_button_title.?);
        try std.testing.expectEqualStrings("alpha", surface_a.effectiveTitle().?);
        try std.testing.expect(std.mem.indexOf(u8, host.tabs.items[1].cached_button_label.?, glyph) == null);
        try std.testing.expectEqualStrings("Bell", Host.tabItemUiaItemStatus(&host, 1, &status_buf));
        try std.testing.expect(!std.mem.startsWith(u8, try caption_text(window.parent, &caption, &utf8), glyph));

        // The active tab rings: the caption leads with the glyph, while the
        // title automation reads stays as it was.
        surface_b.setBellRinging(true);
        try std.testing.expect(std.mem.startsWith(u8, try caption_text(window.parent, &caption, &utf8), glyph));
        try std.testing.expect(!std.mem.startsWith(u8, host.cached_window_title.?, glyph));
        try std.testing.expectEqualStrings("beta", surface_b.effectiveTitle().?);

        // An IME can commit without WM_KEYDOWN. Empty results leave the
        // alert alone; real text clears it before the possibly closing call.
        const ImeTarget = struct {
            surface: *Surface,
            commits: usize = 0,

            pub fn preeditCallback(_: *@This(), _: ?[]const u8) void {}

            pub fn keyCallback(self: *@This(), event: input.KeyEvent) !CoreSurface.InputEffect {
                try std.testing.expect(!self.surface.bell_ringing);
                try std.testing.expectEqualStrings("\u{65e5}", event.utf8);
                self.commits += 1;
                return .closed;
            }

            pub fn noteInput(_: *@This(), _: []const u8) void {
                unreachable; // A closed target must never be used again.
            }
        };
        var ime_target: ImeTarget = .{ .surface = &surface_b };
        try std.testing.expectEqual(CoreSurface.InputEffect.ignored, surface_b.commitImeResult(&ime_target, ""));
        try std.testing.expect(surface_b.bell_ringing);
        try std.testing.expectEqual(@as(usize, 0), ime_target.commits);
        try std.testing.expectEqual(CoreSurface.InputEffect.closed, surface_b.commitImeResult(&ime_target, "\u{65e5}"));
        try std.testing.expectEqual(@as(usize, 1), ime_target.commits);
        try std.testing.expect(!surface_b.bell_ringing);
        try std.testing.expect(!std.mem.startsWith(u8, try caption_text(window.parent, &caption, &utf8), glyph));
        try std.testing.expectEqualStrings("", Host.tabItemUiaItemStatus(&host, 2, &status_buf));

        // A reload with `no-title` takes the marks away (here for tab B's)...
        surface_b.setBellRinging(true);
        surface_b.applyBellFeatures(.{ .title = false });
        try std.testing.expect(!surface_b.bell_ringing);
        try std.testing.expect(!std.mem.startsWith(u8, try caption_text(window.parent, &caption, &utf8), glyph));

        // ...and gaining focus answers the bell of tab A (the key press path
        // is the same `clearBell`, run from `handleKeyMessage`, and is
        // measured on a hidden desktop).
        surface_a.focusChanged(true);
        try std.testing.expect(std.mem.indexOf(u8, host.tabs.items[0].cached_button_label.?, glyph) == null);
        try std.testing.expect(!std.mem.startsWith(u8, try caption_text(window.parent, &caption, &utf8), glyph));
        try std.testing.expectEqualStrings("", Host.tabItemUiaItemStatus(&host, 1, &status_buf));
    }

    test "a background tab close that asks leaves the keyboard on its prompt" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(backgroundCloseAskTestBody);
    }

    fn backgroundCloseAskTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .active_tab = 1 }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
            },
        });
        defer session.deinit();
        app.config.@"undo-timeout" = .{ .duration = 0 };
        // The prompt's controls need the palette list's window class.
        try app.ensurePaletteListClass();
        defer _ = sys.UnregisterClassW(palette_list_class_name, app.hinstance);
        // The host is not deinitialized here, so free what the prompt cached.
        defer for ([_]*?[:0]const u8{
            &host.cached_overlay_edit,
            &host.cached_overlay_label,
            &host.cached_overlay_hint,
            &host.cached_overlay_preview,
            &host.cached_overlay_accept,
            &host.cached_overlay_cancel,
        }) |slot| {
            if (slot.*) |value| std.testing.allocator.free(value);
            slot.* = null;
        };
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.MoveWindow(window.parent, 0, 0, 1200, 300, 0);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        try host.refreshChrome();
        try host.layout();
        surface_a.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        surface_b.hwnd = window.pane;
        defer for ([_]*Surface{ &surface_a, &surface_b }) |surface| {
            surface.hwnd = null;
        };
        surface_b.window_visible = true;
        surface_b.window_focused = true;

        // Delete on the focused button of A, a busy tab behind B. Nothing
        // closes yet, so the keys stay with the prompt it opened instead of
        // moving to the strip as they do once a button is destroyed.
        surface_a.core_surface.readonly = true;
        _ = sys.SetFocus(host.tabs.items[0].button_hwnd.?);
        surface_a.core_initialized = true;
        try std.testing.expect(host.closeTabInPlace(0));
        surface_a.core_initialized = false;
        try std.testing.expectEqual(HostOverlayMode.confirm, host.overlay_mode);
        try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
        try std.testing.expect(host.overlay_accept_hwnd != null);
        try std.testing.expectEqual(host.overlay_accept_hwnd, sys.GetFocus());
        host.invokeConfirmCancel();
        try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
    }

    test "a tab button that appears tells UIA the tab list changed" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(tabButtonAddedUiaTestBody);
    }

    fn tabButtonAddedUiaTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var surface_c: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
                .{ .storage = &surface_c, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
            },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        // Layout repaints the active tab's panes, which need windows.
        for ([_]*Surface{ &surface_a, &surface_b, &surface_c }) |surface| {
            surface.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        }
        defer for ([_]*Surface{ &surface_a, &surface_b, &surface_c }) |surface| {
            surface.hwnd = null;
        };
        const root = try win32_uia.RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
        defer _ = win32_uia.RootProvider.Release(&root.base);
        host.root_uia_provider = root;
        defer host.root_uia_provider = null;
        const events = &win32_uia.events;

        // The first chrome pass gives the two tabs their buttons.
        const before = events.testing_structure_changes;
        try host.refreshChrome();
        try std.testing.expect(host.tabs.items[1].button_hwnd != null);
        try std.testing.expectEqual(before + 1, events.testing_structure_changes);

        // A pass that creates no button says nothing.
        try host.refreshChrome();
        try std.testing.expectEqual(before + 1, events.testing_structure_changes);

        // A new tab, as `Surface.init` attaches one: the button that the next
        // chrome pass creates is what a reader's tab list is missing.
        try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 3, &surface_c));
        try host.refreshChrome();
        try std.testing.expect(host.tabs.items[2].button_hwnd != null);
        try std.testing.expectEqual(before + 2, events.testing_structure_changes);

        // Undo of a close builds the restored tab's button anew. Detaching it
        // is the removal, which is told separately (CLOSE-01).
        var entry = host.detachTabForUndo(2).?;
        defer entry.dispose(&host, .host_destroy) catch {}; // Best-effort test teardown.
        const detached = events.testing_structure_changes;
        try std.testing.expect(try host.restoreClosedTabEntry(&entry.payload.close_tab));
        try std.testing.expect(host.tabs.items[2].button_hwnd != null);
        try std.testing.expectEqual(detached + 1, events.testing_structure_changes);
    }

    test "moving the zoom hides the old pane before it shows the new one" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(zoomMoveOrderTestBody);
    }

    test "a pane a layout shows keeps its resize until it is shown, and sends it once" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(shownPaneResizeTestBody);
    }

    test "showing a tab holds its panes' resizes until the whole tab is placed" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(shownTabResizeTestBody);
    }

    test "showing a zoomed tab keeps its other panes hidden until a layout places them" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(shownZoomedTabTestBody);
    }

    /// A stand-in pane window that takes what has reached `watched`'s termio
    /// when it is shown (`WM_SHOWWINDOW`) or resized (`WM_SIZE`), steps of
    /// a layout that come after a font change or after another pane's step
    /// (DPI-HIDDEN-TAB-BATCH-01).
    const PaneQueueRecorder = struct {
        var watched: ?*Surface = null;
        var previous: ?*const anyopaque = null;
        var shows: usize = 0;
        var at_show: usize = 0;
        var sizes: usize = 0;
        var at_size: usize = 0;

        fn install(pane: HWND, surface: *Surface) void {
            watched = surface;
            shows = 0;
            at_show = 0;
            sizes = 0;
            at_size = 0;
            const old = sys.SetWindowLongPtrW(pane, c.GWLP_WNDPROC, @as(LONG_PTR, @intCast(@intFromPtr(&proc))));
            previous = if (old == 0) null else @ptrFromInt(@as(usize, @intCast(old)));
        }

        fn take() usize {
            var count: usize = 0;
            while (watched.?.core_surface.io.mailbox.spsc.queue.pop()) |message| {
                message.deinit();
                count += 1;
            }
            return count;
        }

        fn proc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
            if (msg == c.WM_SHOWWINDOW and wParam != 0) {
                shows += 1;
                at_show += take();
            }
            if (msg == c.WM_SIZE) {
                sizes += 1;
                at_size += take();
            }
            return sys.CallWindowProcW(previous, hwnd, msg, wParam, lParam);
        }
    };

    /// A hidden stand-in pane, as a background tab's, with a started core
    /// that has only what a resize reads: a termio mailbox, cells and
    /// padding. Its font is already the host's and the renderer already knows
    /// it is visible, so neither is called.
    fn startTestPane(surface: *Surface, host: *const Host, parent: HWND) !void {
        const termio = @import("../../termio.zig");
        surface.hwnd = try createTestChromeChild(parent, prompt_label_class);
        _ = sys.ShowWindow(surface.hwnd.?, c.SW_HIDE);
        surface.core_surface.io.mailbox = try termio.Mailbox.initSPSC(std.testing.allocator);
        surface.core_surface.rt_surface = surface;
        surface.core_surface.config.window_padding_balance = .false;
        surface.core_surface.size.cell = .{ .width = 10, .height = 20 };
        const scale: f32 = @as(f32, @floatFromInt(host.current_dpi)) / 96.0;
        surface.content_scale = .{ .x = scale, .y = scale };
        surface.occlusion_visible = true;
        surface.core_initialized = true;
    }

    fn stopTestPane(surface: *Surface) void {
        surface.core_initialized = false;
        surface.core_surface.io.mailbox.deinit(std.testing.allocator);
        surface.hwnd = null;
    }

    /// The one resize a pane sent, at the size the layout gave it, with no
    /// batch left open to hold every later one.
    fn expectOneLaidOutResize(surface: *Surface) !void {
        var client: RECT = undefined;
        _ = sys.GetClientRect(surface.hwnd.?, &client);
        const queue = surface.core_surface.io.mailbox.spsc.queue;
        const resize = (queue.pop() orelse return error.TestExpectedResize).resize;
        try std.testing.expectEqual(@as(u32, @intCast(client.right)), resize.screen.width);
        try std.testing.expectEqual(@as(u32, @intCast(client.bottom)), resize.screen.height);
        try std.testing.expect(queue.pop() == null);
        try std.testing.expectEqual(@as(u8, 0), surface.core_surface.resize_batch.depth);
    }

    fn shownPaneResizeTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{.{ .storage = &surface, .host = &host, .register = true, .window_visible = false }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        host.surfaces_visible = true;
        try startTestPane(&surface, &host, window.parent);
        defer stopTestPane(&surface);

        // `setVisible` puts in the new DPI's font just before it shows the
        // window, after the layout gave the pane its size: nothing may have
        // gone by then, or the size went alone in the old cells.
        PaneQueueRecorder.install(surface.hwnd.?, &surface);
        try host.layout();
        try std.testing.expectEqual(@as(usize, 1), PaneQueueRecorder.shows);
        try std.testing.expectEqual(@as(usize, 0), PaneQueueRecorder.at_show);
        try expectOneLaidOutResize(&surface);
    }

    fn shownTabResizeTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true, .window_visible = false },
                .{ .storage = &surface_b, .host = &host, .register = true, .window_visible = false },
            },
            .tabs = &.{.{ .host = &host, .surface = &surface_a, .id = 1 }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        host.surfaces_visible = true;
        try startTestPane(&surface_a, &host, window.parent);
        defer stopTestPane(&surface_a);
        try startTestPane(&surface_b, &host, window.parent);
        defer stopTestPane(&surface_b);

        // [A | B]: the layout places A, then B.
        var inserted = try SplitTreeSurface.init(std.testing.allocator, &surface_b);
        defer inserted.deinit();
        const tab = &host.tabs.items[0];
        const next_tree = try tab.tree.split(std.testing.allocator, .root, .right, 0.5, &inserted);
        tab.tree.deinit();
        tab.tree = next_tree;
        tab.focused = tab.findHandle(&surface_a).?;
        // The layout dims B; the renderer it would tell is not running here,
        // so B has already told it.
        const high_contrast = isHighContrastActive();
        surface_a.split_dimmed_sent = win32_chrome_state.splitDimmed(2, true, high_contrast);
        surface_b.split_dimmed_sent = win32_chrome_state.splitDimmed(2, false, high_contrast);

        // `showTabPanes` puts every pane's font in (`setVisible`) before the
        // layout gives any pane its size, so B's font build comes between
        // A's font and A's size. When B's layout step runs, A's resize must
        // still be held.
        PaneQueueRecorder.install(surface_b.hwnd.?, &surface_a);
        host.showTabPanes(tab);
        try std.testing.expect(PaneQueueRecorder.sizes > 0);
        try std.testing.expectEqual(@as(usize, 0), PaneQueueRecorder.at_size);
        try expectOneLaidOutResize(&surface_a);
        try expectOneLaidOutResize(&surface_b);
    }

    fn shownZoomedTabTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true, .window_visible = false },
                .{ .storage = &surface_b, .host = &host, .register = true, .window_visible = false },
            },
            .tabs = &.{.{ .host = &host, .surface = &surface_a, .id = 1 }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        host.surfaces_visible = true;
        try startTestPane(&surface_a, &host, window.parent);
        defer stopTestPane(&surface_a);
        try startTestPane(&surface_b, &host, window.parent);
        defer stopTestPane(&surface_b);

        // [A | B], zoomed on A, as `goto_tab` finds a tab it left zoomed.
        var inserted = try SplitTreeSurface.init(std.testing.allocator, &surface_b);
        defer inserted.deinit();
        const tab = &host.tabs.items[0];
        const next_tree = try tab.tree.split(std.testing.allocator, .root, .right, 0.5, &inserted);
        tab.tree.deinit();
        tab.tree = next_tree;
        tab.focused = tab.findHandle(&surface_a).?;
        tab.tree.zoom(tab.focused);
        const high_contrast = isHighContrastActive();
        surface_a.split_dimmed_sent = win32_chrome_state.splitDimmed(2, true, high_contrast);
        surface_b.split_dimmed_sent = win32_chrome_state.splitDimmed(2, false, high_contrast);

        // The layout places and shows A alone. B must not be shown on the
        // way: `setVisible` would put the new DPI's font into it at its old
        // size, which no layout corrects until the zoom ends.
        PaneQueueRecorder.install(surface_b.hwnd.?, &surface_b);
        host.showTabPanes(tab);
        try std.testing.expectEqual(@as(usize, 0), PaneQueueRecorder.shows);
        try std.testing.expect(!surface_b.window_visible);
        try std.testing.expect(sys.IsWindowVisible(surface_b.hwnd.?) == 0);
        try std.testing.expect(surface_b.core_surface.io.mailbox.spsc.queue.pop() == null);
        try std.testing.expectEqual(@as(u8, 0), surface_b.core_surface.resize_batch.depth);
        try expectOneLaidOutResize(&surface_a);
    }

    /// Stand-in pane windows that note when one is about to be shown over
    /// the other, which is on screen: for a moment both would be, on top of
    /// each other (`WM_SHOWWINDOW` comes before the change, at the rect the
    /// window still has).
    const PaneShowRecorder = struct {
        var panes: [2]?HWND = .{ null, null };
        var previous: [2]?*const anyopaque = .{ null, null };
        var overlapped: bool = false;

        fn install(first: HWND, second: HWND) void {
            panes = .{ first, second };
            overlapped = false;
            for (panes, 0..) |pane, i| {
                const old = sys.SetWindowLongPtrW(
                    pane.?,
                    c.GWLP_WNDPROC,
                    @as(LONG_PTR, @intCast(@intFromPtr(&proc))),
                );
                previous[i] = if (old == 0) null else @ptrFromInt(@as(usize, @intCast(old)));
            }
        }

        fn proc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
            if (msg == c.WM_SHOWWINDOW and wParam != 0) {
                var mine: RECT = undefined;
                _ = sys.GetWindowRect(hwnd, &mine);
                for (panes) |other| {
                    if (other.? == hwnd or sys.IsWindowVisible(other.?) == 0) continue;
                    var theirs: RECT = undefined;
                    _ = sys.GetWindowRect(other.?, &theirs);
                    if (mine.left < theirs.right and theirs.left < mine.right and
                        mine.top < theirs.bottom and theirs.top < mine.bottom) overlapped = true;
                }
            }
            for (panes, 0..) |pane, i| {
                if (pane.? == hwnd) return sys.CallWindowProcW(previous[i], hwnd, msg, wParam, lParam);
            }
            return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
        }
    };

    fn zoomMoveOrderTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
            },
            .tabs = &.{.{ .host = &host, .surface = &surface_a, .id = 1 }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        surface_a.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        surface_b.hwnd = try createTestChromeChild(window.parent, prompt_label_class);
        defer for ([_]*Surface{ &surface_a, &surface_b }) |surface| {
            surface.hwnd = null;
        };

        // [A | B], zoomed on B, which comes later in the tree than A.
        var inserted = try SplitTreeSurface.init(std.testing.allocator, &surface_b);
        defer inserted.deinit();
        const tab = &host.tabs.items[0];
        const next_tree = try tab.tree.split(std.testing.allocator, .root, .right, 0.5, &inserted);
        tab.tree.deinit();
        tab.tree = next_tree;
        const handle_a = tab.findHandle(&surface_a).?;
        const handle_b = tab.findHandle(&surface_b).?;
        tab.tree.zoom(handle_b);
        try host.layout();
        try std.testing.expect(sys.IsWindowVisible(surface_b.hwnd.?) != 0);
        try std.testing.expect(sys.IsWindowVisible(surface_a.hwnd.?) == 0);

        // The zoom moves to A, as `goto_split` does with `split-preserve-zoom
        // = navigation`. A is reached first, so B has to be hidden before A
        // is shown, or two GL windows overlap for the length of the pass
        // (the hazard `prepareActiveTabVisibility` is there for).
        PaneShowRecorder.install(surface_a.hwnd.?, surface_b.hwnd.?);
        tab.tree.zoom(handle_a);
        try host.layout();
        try std.testing.expect(!PaneShowRecorder.overlapped);
        try std.testing.expect(sys.IsWindowVisible(surface_a.hwnd.?) != 0);
        try std.testing.expect(sys.IsWindowVisible(surface_b.hwnd.?) == 0);

        // And back: B is shown after A is hidden, as well.
        tab.tree.zoom(handle_b);
        try host.layout();
        try std.testing.expect(!PaneShowRecorder.overlapped);
        try std.testing.expect(sys.IsWindowVisible(surface_b.hwnd.?) != 0);
        try std.testing.expect(sys.IsWindowVisible(surface_a.hwnd.?) == 0);

        // Leaving the zoom, as `goto_split` does by default: the zoomed pane
        // shrinks to its slot, and the other is placed in its own before it
        // comes up, or it would be shown over the zoomed one. Whichever the
        // tree visits first.
        for ([_]SplitTreeSurface.Node.Handle{ handle_b, handle_a }) |zoomed_pane| {
            tab.tree.zoom(zoomed_pane);
            try host.layout();
            tab.tree.zoom(null);
            try host.layout();
            try std.testing.expect(!PaneShowRecorder.overlapped);
            try std.testing.expect(sys.IsWindowVisible(surface_a.hwnd.?) != 0);
            try std.testing.expect(sys.IsWindowVisible(surface_b.hwnd.?) != 0);
        }
    }

    /// Recompute what tab `index` shows for its programs' status (OSC 7501)
    /// and repaint it when that changed. Assistive technology hears when
    /// what `ItemStatus` says changes other than by progress: a new state,
    /// a new request or result, or another record taking the lead.
    pub fn refreshTabStatus(self: *Host, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const tab = &self.tabs.items[index];
        const previous = tab.status_indicator;
        const status = tabStatusHeadline(tab);
        const next: win32_program_status.Indicator = .of(if (status) |value| value.record else null);
        if (!previous.eql(next)) {
            tab.status_indicator = next;
            if ((previous == .none) != (next == .none)) {
                // The badge takes room from the label, so the label is
                // rebuilt against a different budget.
                if (chromeSyncOrLog("tab status label sync failed", self.syncTabButtons())) {
                    self.invalidateTopChromeText();
                }
            }
            if (tab.button_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        }
        // A bell no program status outranks is the tab's status too ("Bell"
        // in `tabItemUiaItemStatus`); its key is even, a program status's odd.
        const key = if (status) |value|
            tabStatusKey(value)
        else if (tab.bellRinging())
            tab_bell_status_key
        else
            0;
        if (key != tab.status_key) {
            tab.status_key = key;
            if (self.shouldShowTabBar()) {
                if (tab.uia_provider) |provider| provider.raiseItemStatusChanged();
            }
        }
    }

    fn refreshAllTabStatus(self: *Host) void {
        for (0..self.tabs.items.len) |index| self.refreshTabStatus(index);
    }

    /// A tab joined or left the strip. Neither needs to change a selection (a
    /// background tab closes, or is restored behind the front one), so
    /// `notifyActiveTabUiaSelectionChanged` can stay silent and a reader's tab
    /// list would go stale. The tab buttons are child windows of the host, not
    /// children of the Selection container, so the host's root is told its
    /// children changed.
    pub fn notifyTabListUiaChanged(self: *Host) void {
        for (self.tabs.items) |tab| {
            if (tab.uia_provider) |provider| provider.syncCloseChild();
        }
        if (!self.shouldShowTabBar()) return;
        if (self.root_uia_provider) |provider| provider.raiseChildrenInvalidated();
    }

    pub fn notifyActiveTabUiaSelectionChanged(self: *Host, previous_tab_id: ?u32) void {
        // A hidden tab strip is not in the UIA tree at all, so these would be
        // cross-process COM raises for elements no reader can reach (#244).
        if (!self.shouldShowTabBar()) return;
        const current = self.activeTab();
        const current_tab_id: ?u32 = if (current) |tab| tab.id else null;
        if (previous_tab_id == current_tab_id) return;
        if (previous_tab_id) |id| {
            if (self.findTabIndexById(id)) |index| {
                if (self.tabs.items[index].uia_provider) |provider| {
                    provider.raiseSelected(true, false);
                }
            }
        }
        if (current) |tab| {
            if (tab.uia_provider) |provider| provider.raiseSelected(false, true);
        }
        if (self.tab_container_uia_provider) |provider| {
            win32_uia.events.raiseSelectionInvalidated(&provider.base);
        }
    }

    pub fn activateTabByDirection(self: *Host, goto: apprt.action.GotoTab) bool {
        if (self.tabs.items.len <= 1) return false;
        const index = desiredTabIndex(self.tabs.items.len, self.active_tab, goto) orelse return false;
        return self.activateTabIndex(index);
    }

    pub fn scrollTabStrip(self: *Host, horizontal: bool, delta: i16) void {
        if (horizontal != self.tab_wheel_horizontal) self.tab_wheel_steps = .{};
        self.tab_wheel_horizontal = horizontal;
        const normalized = win32_input.chromeWheelDelta(horizontal, delta, 1);
        const steps = self.tab_wheel_steps.add(normalized, sys.GetTickCount64());
        // Keep the existing next/previous wrap convention, once per complete
        // notch rather than once per precision-wheel message.
        const direction = tabDirectionFromWheelDelta(if (steps > 0) 120 else -120);
        for (0..@abs(steps)) |_| _ = self.activateTabByDirection(direction);
    }

    pub fn dismissActiveSearch(self: *Host) bool {
        const surface = self.activeSurface() orelse return false;
        if (!surface.search_active and !surface.search_bar.visible) return false;
        surface.closeDockedSearchBar(true, true) catch return false;
        return true;
    }

    fn toggleCommandPaletteFromButton(self: *Host) bool {
        const surface = self.activeSurface() orelse return false;
        _ = surface.toggleCommandPalette() catch return false;
        return true;
    }

    pub fn dismissCommandPalette(self: *Host) bool {
        if (self.overlay_mode != .command_palette) return false;
        self.hideOverlay();
        runUiActionOrLog("command palette dismiss layout failed", self.layout());
        self.forceHostCompositionPaint();
        refocusActiveSurface(self);
        return true;
    }

    pub fn commandPaletteToggleKeyMessage(
        self: *Host,
        msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
    ) bool {
        if (self.overlay_mode != .command_palette) return false;
        var message = keyEventFromWin32Message(msg, wParam, lParam, true) orelse return false;
        message.bindText();
        return keyEventTogglesCommandPalette(
            message.event,
            &self.app.config.keybind.set,
            &self.app.config.@"key-remap",
        );
    }

    fn reloadProfiles(self: *Host) !bool {
        var user = try windows_shell.UserProfiles.init(self.app.core_app.alloc, &self.app.config);
        defer user.deinit();
        return try self.applyProfileDiscovery(try windows_shell.discoverProfiles(
            self.app.core_app.alloc,
            self.app.config.@"ssh-config-hosts",
            &user,
        ));
    }

    /// Takes ownership of `discovery`'s profiles, also on error.
    pub fn applyProfileDiscovery(self: *Host, discovery: windows_shell.ProfileDiscovery) !bool {
        // A discovery still running started from an older list.
        self.app.profiles_generation +%= 1;
        return try self.applyProfiles(discovery);
    }

    /// Takes ownership of `discovery`'s profiles, also on error.
    pub fn applyProfiles(self: *Host, discovery: windows_shell.ProfileDiscovery) !bool {
        const replacing = self.profiles != null;
        const next_profiles = discovery.profiles;
        if (self.profiles) |profiles| windows_shell.deinitProfiles(self.app.core_app.alloc, profiles);
        self.profiles = next_profiles;
        self.profiles_complete = discovery.complete;
        if (self.app.jump_list) |*jump_list| {
            // A later user-initiated load recovers startup discovery after its
            // bounded transient-failure retry budget has been exhausted.
            if (discovery.complete) jump_list.completeStartupProfileDiscovery();
            jump_list.updateProfiles(windows_shell.visibleProfiles(next_profiles), self.app.cli_visual_studio_profiles_arg);
        }
        if (replacing and self.overlay_mode == .command_palette) self.rebuildPaletteList();
        self.app.applyLauncherQuickSlotPreferences(self.shownProfiles().?);
        const profiles = self.shownProfiles().?;
        if (profiles.len == 0) {
            self.selected_profile = 0;
            try appendOwnedString(self.app.core_app.alloc, &self.selected_profile_key, null);
            return false;
        }
        try self.selectPreferredProfile(profiles);
        return true;
    }

    pub fn invalidateProfiles(self: *Host) void {
        self.app.profiles_generation +%= 1;
        if (self.profiles) |profiles| {
            windows_shell.deinitProfiles(self.app.core_app.alloc, profiles);
            self.profiles = null;
        }
        self.profiles_complete = false;
    }

    pub fn reapplyLauncherProfilePreferences(self: *Host) !void {
        const profiles = self.shownProfiles() orelse return;
        if (profiles.len == 0) return;
        self.app.applyLauncherQuickSlotPreferences(profiles);
        try self.selectPreferredProfile(profiles);
    }

    /// Select the profile `preferredProfileIndex` picks, else the default
    /// shell's, else the one at the current index (the first when that is
    /// past the end). `profiles` is not empty. Only a profile chosen in the
    /// picker, the palette or a quick slot is stored as the selection: one
    /// picked here is picked again for each new list, so after a reload that
    /// changes `default-profile` the picker starts on the new one.
    fn selectPreferredProfile(self: *Host, profiles: []const windows_shell.Profile) !void {
        if (preferredProfileIndex(
            profiles,
            self.selected_profile_key,
            self.app.launcher_profile_key,
            null,
            null,
            self.selected_profile,
        )) |chosen| {
            _ = try self.setSelectedProfileIndex(chosen);
            return;
        }
        self.selected_profile = preferredProfileIndex(
            profiles,
            null,
            null,
            if (self.app.config._default_profile) |profile| profile.key else null,
            self.app.launcher_profile_hint,
            self.selected_profile,
        ) orelse self.app.defaultShellProfileIndex(profiles) orelse
            if (self.selected_profile < profiles.len) self.selected_profile else 0;
    }

    /// For actions that need a list now (open a profile by key or index,
    /// pin a quick slot). Borrows another window's list, complete or not,
    /// and discovers on this thread only when no window has one.
    fn ensureProfiles(self: *Host) !bool {
        if (self.profiles == null and
            !self.adoptProfilesFromAnotherHost(true) and
            !self.adoptProfilesFromAnotherHost(false))
        {
            return try self.reloadProfiles();
        }
        return self.clampSelectedProfile();
    }

    /// The picker's and the palette's way to a list: never discovers on
    /// the UI thread. With none loaded it borrows another window's, else
    /// asks the discovery worker and answers false until that list lands.
    pub fn profilesForChrome(self: *Host) bool {
        if (self.profiles == null and !self.adoptProfilesFromAnotherHost(true)) {
            self.requestProfiles();
            // With no worker to run it, the discovery ran on this thread.
            if (self.profiles == null) return false;
        }
        return self.clampSelectedProfile();
    }

    /// Whether the loaded list has a profile to select, with the selection
    /// moved to the first one when it is past the end.
    fn clampSelectedProfile(self: *Host) bool {
        const profiles = self.shownProfiles().?;
        if (profiles.len == 0) return false;
        if (self.selected_profile >= profiles.len) self.selected_profile = 0;
        return true;
    }

    pub fn requestProfiles(self: *Host) void {
        self.profiles_requested = true;
        const previous = self.app.profiles_requesting_host;
        self.app.profiles_requesting_host = self;
        defer self.app.profiles_requesting_host = previous;
        self.app.startProfileDiscovery();
    }

    /// Copy a list another window already has (`complete_only`: only a
    /// complete one). The copy is no newer than a discovery in flight, so it
    /// leaves the generation alone.
    fn adoptProfilesFromAnotherHost(self: *Host, complete_only: bool) bool {
        for (self.app.registry.hosts.items) |other| {
            if (other == self or (complete_only and !other.profiles_complete)) continue;
            const source = other.profiles orelse continue;
            const copy = windows_shell.cloneProfiles(self.app.core_app.alloc, source) catch return false;
            _ = self.applyProfiles(.{ .profiles = copy, .complete = other.profiles_complete }) catch |err| {
                log.warn("profile list copy failed err={}", .{err});
            };
            return self.profiles != null;
        }
        return false;
    }

    /// A list this host asked the discovery worker for arrived, or the
    /// discovery failed. `had_profiles`: a list was already showing.
    pub fn profilesArrived(self: *Host, had_profiles: bool) void {
        switch (self.overlay_mode) {
            .profile => {
                const profiles = self.shownProfiles() orelse &.{};
                if (profiles.len == 0) {
                    self.hideOverlay();
                    runUiActionOrLog("profile overlay dismiss layout failed", self.layout());
                    runUiActionOrLog(
                        "profile availability banner failed",
                        self.setBanner(.err, "No supported Windows profiles detected."),
                    );
                    return;
                }
                self.refreshProfileChrome();
            },
            // Not after a failure: the palette would ask again at once.
            .command_palette => if (!had_profiles and self.profiles != null) self.rebuildPaletteList(),
            else => {},
        }
    }

    pub fn selectedProfileIndex(self: *Host) ?usize {
        const profiles = self.shownProfiles() orelse return null;
        if (profiles.len == 0) return null;
        return @min(self.selected_profile, profiles.len - 1);
    }

    pub fn selectedProfile(self: *Host) ?*windows_shell.Profile {
        const profiles = self.shownProfiles() orelse return null;
        const index = self.selectedProfileIndex() orelse return null;
        return &profiles[index];
    }

    /// The profiles the picker, the palette, the dropdown, the quick slots
    /// and the jump list show: the list without its hidden tail
    /// (`profile-hidden`). Lookups by key use `profiles` itself.
    pub fn shownProfiles(self: *const Host) ?[]windows_shell.Profile {
        return windows_shell.visibleProfiles(self.profiles orelse return null);
    }

    /// The profile `key` names, hidden or not.
    pub fn profileForKey(self: *Host, key: []const u8) !?*windows_shell.Profile {
        // False when no profile is shown; a hidden one can still match.
        _ = try self.ensureProfiles();
        const profiles = self.profiles orelse return null;
        const index = profileIndexByKey(profiles, key) orelse return null;
        return &profiles[index];
    }

    pub fn setSelectedProfileIndex(self: *Host, index: usize) !bool {
        const profiles = self.shownProfiles() orelse return false;
        if (profiles.len == 0) return false;
        const next_index = @min(index, profiles.len - 1);
        const next_key = profiles[next_index].key;
        if (!selectedProfileSelectionNeedsChange(
            self.selected_profile,
            next_index,
            self.selected_profile_key,
            self.app.launcher_profile_key,
            next_key,
        )) return false;
        self.selected_profile = next_index;
        try appendOwnedString(self.app.core_app.alloc, &self.selected_profile_key, next_key);
        try appendOwnedString(self.app.core_app.alloc, &self.app.launcher_profile_key, next_key);
        return true;
    }

    fn setLauncherProfileTarget(self: *Host, target: ProfileOpenTarget) void {
        if (self.app.launcher_profile_target == target) return;
        self.app.launcher_profile_target = target;
        self.refreshProfileChrome();
    }

    pub fn refreshProfileChrome(self: *Host) void {
        if (!profileChromeVisible(self.overlay_mode)) return;
        if (self.overlay_mode == .profile) {
            _ = self.syncOverlayLabel() catch false;
            _ = self.syncOverlayHint() catch false;
            _ = self.syncOverlayButtons() catch false;
        }
        self.invalidateOverlayText();
    }

    fn cycleLauncherProfileTarget(self: *Host, reverse: bool) bool {
        self.setLauncherProfileTarget(cycleProfileOpenTarget(self.app.launcher_profile_target, reverse));
        return true;
    }

    pub fn toggleProfileOverlay(self: *Host) bool {
        if (self.overlay_mode == .profile) {
            self.hideOverlay();
            runUiActionOrLog("profile overlay dismiss layout failed", self.layout());
            self.forceHostCompositionPaint();
            return true;
        }
        // Each opening refreshes the list, so a shell installed meanwhile
        // shows up, but on the discovery worker: until it answers the
        // picker shows the list it has, or says it is detecting one.
        // One request either way: a list borrowed from another window is
        // refreshed too, and with no worker it is one synchronous discovery.
        if (self.profiles == null) _ = self.adoptProfilesFromAnotherHost(true);
        self.requestProfiles();
        const initial = self.overlayInitialText(.profile);
        defer if (initial) |value| self.app.core_app.alloc.free(value);
        self.hideOverlay();
        self.showOverlay(.profile, initial) catch return false;
        return true;
    }

    pub fn stepProfileSelection(self: *Host, reverse: bool) !bool {
        if (self.overlay_mode != .profile) return false;
        if (!self.profilesForChrome()) return false;
        const profiles = self.shownProfiles().?;
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
        const fallback = self.selectedProfileIndex() orelse 0;
        const current_index = switch (resolveProfileSelection(profiles, text, fallback)) {
            .exact => |index| index,
            .ambiguous, .invalid => fallback,
        };
        const next = nextTabOverviewSelection(current_index + 1, profiles.len, reverse) - 1;
        const selection_changed = try self.setSelectedProfileIndex(next);
        _ = try self.setOverlayEditText(profiles[next].key);
        _ = sys.SendMessageW(edit_hwnd, c.EM_SETSEL, 0, -1);
        if (selection_changed) self.refreshProfileChrome();
        return true;
    }

    pub fn openSelectedProfile(self: *Host, open_target: ProfileOpenTarget) bool {
        const profiles_ready = self.ensureProfiles() catch |err| {
            logUiActionError("selected profile load failed", err);
            return false;
        };
        if (!profiles_ready) return false;
        const profile = self.selectedProfile() orelse return false;
        const source = self.activeSurface() orelse return false;
        const surface = self.app.createProfileSurface(.{ .surface = source.core() }, profile, open_target) catch return false;
        if (self.app.jump_list) |*jump_list| jump_list.noteProfileUsed(profile.key);
        if (self.overlay_mode == .profile) {
            self.hideOverlay();
            runUiActionOrLog("profile launch layout failed", self.layout());
        }
        self.app.activateSurface(surface);
        return true;
    }

    pub fn quickOpenProfileIndex(self: *Host, index: usize, open_target: ProfileOpenTarget) bool {
        const profiles_ready = self.ensureProfiles() catch |err| {
            logUiActionError("quick profile load failed", err);
            return false;
        };
        if (!profiles_ready) return false;
        const profiles = self.shownProfiles().?;
        if (index >= profiles.len) return false;
        if (self.setSelectedProfileIndex(index) catch return false) {
            self.refreshProfileChrome();
        }
        return self.openSelectedProfile(open_target);
    }

    pub fn openSelectedProfileOrFallback(self: *Host, open_target: ProfileOpenTarget) bool {
        if (self.openSelectedProfile(open_target)) return true;
        const surface = self.activeSurface() orelse return false;
        switch (open_target) {
            .tab => self.postDeferredNewTab(),
            .window => _ = self.app.performAction(.{ .surface = surface.core() }, .new_window, .{}) catch return false,
            .split => _ = self.app.performAction(.{ .surface = surface.core() }, .new_split, .right) catch return false,
        }
        return true;
    }

    pub fn submitProfileOverlay(self: *Host, open_target: ProfileOpenTarget) !bool {
        if (!self.profilesForChrome()) {
            if (self.profiles_requested) return false;
            try self.setBanner(.err, "No supported Windows profiles detected.");
            return false;
        }
        _ = self.overlay_edit_hwnd orelse return false;
        const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
        const selection = resolveProfileSelection(self.shownProfiles().?, text, self.selectedProfileIndex() orelse 0);
        switch (selection) {
            .exact => |index| {
                _ = try self.setSelectedProfileIndex(index);
            },
            .ambiguous => |count| {
                const message = try std.fmt.allocPrint(
                    self.app.core_app.alloc,
                    "{d} profiles match. Keep typing or use Up/Down to choose one.",
                    .{count},
                );
                defer self.app.core_app.alloc.free(message);
                try self.setBanner(.err, message);
                return false;
            },
            .invalid => {
                try self.setBanner(.err, "Unknown profile. Try a number or a profile name like pwsh, ubuntu, git, or cmd.");
                return false;
            },
        }
        if (!self.openSelectedProfile(open_target)) return false;
        return true;
    }

    pub fn inspectorPanelVisible(self: *Host) bool {
        return inspectorPanelVisibleForState(self.overlay_mode, self.activeTabHasInspector());
    }

    fn activeTabHasInspector(self: *Host) bool {
        const tab = self.activeTab() orelse return false;
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.inspector_visible) return true;
        }
        return false;
    }

    fn isActiveTabButton(self: *Host, child: HWND) bool {
        const tab = self.activeTab() orelse return false;
        return if (tab.button_hwnd) |hwnd| hwnd == child else false;
    }

    fn isTabButton(self: *Host, child: HWND) bool {
        for (self.tabs.items) |*tab| {
            if (tab.button_hwnd) |hwnd| {
                if (hwnd == child) return true;
            }
        }
        return false;
    }

    /// Record that a navigation key reached a chrome control. Rings
    /// appear on the next paint of whatever holds focus.
    pub fn noteChromeKeyInput(self: *Host, vk: WPARAM) void {
        if (!focus_cue.keyRevealsRing(@intCast(vk & 0xFFFF))) return;
        if (self.focus_input_mode == .keyboard) return;
        self.focus_input_mode = .keyboard;
        if (sys.GetFocus()) |focused| _ = sys.InvalidateRect(focused, null, 0);
    }

    /// Record a pointer press on a chrome control. The control may take
    /// focus, but it must not show a ring for it.
    pub fn noteChromePointerInput(self: *Host) void {
        if (self.focus_input_mode == .pointer) return;
        self.focus_input_mode = .pointer;
        if (sys.GetFocus()) |focused| _ = sys.InvalidateRect(focused, null, 0);
    }

    /// Whether a focused chrome control should paint its focus ring now.
    pub fn chromeFocusRingVisible(self: *const Host, focused: bool, disabled: bool) bool {
        return focus_cue.showRing(focused, disabled, self.focus_input_mode, isHighContrastActive());
    }

    pub fn isHoveredButton(self: *Host, child: HWND) bool {
        return self.hovered_button_hwnd != null and child == self.hovered_button_hwnd.?;
    }

    fn titlebarActionButtonRole(self: *Host, child: HWND) TitlebarButtonRole {
        if (!self.usingIntegratedTitlebar()) return .none;
        if (self.new_tab_hwnd != null and child == self.new_tab_hwnd.?) return .new_tab;
        if (self.overflow_hwnd != null and child == self.overflow_hwnd.?) return .dropdown;
        return .none;
    }

    fn titlebarHoverFadeDuration(self: *Host) u16 {
        return (win32_chrome_state.HighContrastDpiState{
            .high_contrast = isHighContrastActive(),
            .client_animations_enabled = clientAnimationsEnabled(),
            .dpi = self.current_dpi,
        }).effectiveAnimationDuration(titlebar_hover_fade_ms);
    }

    fn invalidateTitlebarButtonRole(self: *Host, role: TitlebarButtonRole) void {
        switch (role) {
            .minimize, .maximize, .close => self.repaintTopChrome(),
            .new_tab => {
                if (self.new_tab_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
            },
            .dropdown => {
                if (self.overflow_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
            },
            .none => {},
        }
    }

    fn startTitlebarHoverFade(self: *Host, role: TitlebarButtonRole) void {
        if (role == .none) return;
        const duration = self.titlebarHoverFadeDuration();
        if (duration == 0) {
            self.titlebar_hover_fade = .{};
            self.titlebar_hover_fade_role = .none;
            self.invalidateTitlebarButtonRole(role);
            return;
        }

        self.titlebar_hover_fade.start(sys.GetTickCount64(), duration);
        self.titlebar_hover_fade_role = role;
        self.invalidateTitlebarButtonRole(role);
        _ = self.addTween(0.0, 1.0, duration, .{ 0.0, 0.0, 1.0, 1.0 });
    }

    pub fn titlebarHoverAlpha(self: *Host, role: TitlebarButtonRole, hovered: bool, now_ms: u64) f32 {
        if (hovered) return 1.0;
        if (self.titlebar_hover_fade_role == role) {
            return self.titlebar_hover_fade.alphaAt(now_ms);
        }
        return 0.0;
    }

    fn setCaptionHover(self: *Host, next: CaptionButton) void {
        if (self.caption_hover == next) return;
        const previous_role = titlebarRoleFromCaption(self.caption_hover);
        self.caption_hover = next;
        if (previous_role != .none) self.startTitlebarHoverFade(previous_role);
        self.repaintTopChrome();
    }

    pub fn clearCaptionPressed(self: *Host) void {
        if (self.caption_pressed == .none) return;
        self.caption_pressed = .none;
        self.repaintTopChrome();
    }

    pub fn setHoveredButton(self: *Host, child: ?HWND) void {
        if (self.hovered_button_hwnd == child) return;
        // The tooltip describes whatever the pointer was resting on. Moving to
        // a different button invalidates it; the next dwell arms a new one.
        self.hideTabTooltip();
        const previous = self.hovered_button_hwnd;
        self.hovered_button_hwnd = child;
        if (previous) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        if (child) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        if (self.bannerButtonOf(previous) != null or self.bannerButtonOf(child) != null) self.syncBannerExpiry();

        const previous_titlebar_role = if (previous) |h| self.titlebarActionButtonRole(h) else .none;
        if (previous_titlebar_role != .none) self.startTitlebarHoverFade(previous_titlebar_role);

        // Tab close-button fade: when the hovered button transitions
        // into / out of a TAB button, drive CloseState + kick the
        // tween timer so the 16 ms tick drives repaints while the
        // alpha interpolates. Non-tab buttons (caption action buttons,
        // overlay accept/cancel) use the instant hover visuals.
        const prev_was_tab = if (previous) |h| self.isTabButton(h) else false;
        const new_is_tab = if (child) |h| self.isTabButton(h) else false;
        if (prev_was_tab or new_is_tab) {
            const now = sys.GetTickCount64();
            const animate = self.effectiveTweenDuration(@intCast(win32_tab_visual.close_fade_ms)) != 0;

            if (prev_was_tab and new_is_tab) {
                // Adjacent tab transition: move the previous target
                // into the fade-out slot so both animations run in
                // parallel — fade A out while fading B in.
                self.tab_close_prev = self.tab_close_hover;
                self.tab_close_prev.setHoveredWithMotion(false, now, animate);
                self.tab_close_prev_hwnd = previous;

                self.tab_close_hover = .{};
                self.tab_close_hover.setHoveredWithMotion(true, now, animate);
                self.tab_close_hover_hwnd = child;
            } else {
                // Single-direction transition: (no tab → tab) fade in,
                // (tab → no tab) fade out. Previous-slot stays as-is
                // so an already-in-progress fade-out keeps animating.
                self.tab_close_hover.setHoveredWithMotion(new_is_tab, now, animate);
                self.tab_close_hover_hwnd = if (new_is_tab) child else previous;
            }

            // A snapped fade needs only the invalidations above, no timer.
            if (!animate) {
                self.tab_close_prev.setHoveredWithMotion(false, now, false);
                if (self.tab_close_prev_hwnd) |h| _ = sys.InvalidateRect(h, null, 0);
                self.tab_close_prev_hwnd = null;
                return;
            }
            // Dummy tween keeps the 16 ms heartbeat alive for the
            // fade duration; paint reads `CloseState.alphaAt` each
            // frame directly.
            _ = self.addTween(
                0.0,
                1.0,
                @intCast(win32_tab_visual.close_fade_ms),
                (win32_theme.ThemeMotion{}).easing_standard,
            );
        }
    }

    pub fn assignSelectedProfileToQuickSlot(self: *Host, slot_ordinal: usize) bool {
        const profiles_ready = self.ensureProfiles() catch |err| {
            logUiActionError("quick slot profile load failed", err);
            return false;
        };
        if (!profiles_ready) return false;
        const profile = self.selectedProfile() orelse return false;
        self.app.setLauncherQuickSlotPreference(slot_ordinal, profile.key) catch return false;
        const message = std.fmt.allocPrint(
            self.app.core_app.alloc,
            "Pinned {s} to quick slot {d}.",
            .{ profile.label, slot_ordinal + 1 },
        ) catch return false;
        defer self.app.core_app.alloc.free(message);
        runUiActionOrLog("quick slot pin banner failed", self.setBanner(.info, message));
        return true;
    }

    pub fn clearQuickSlotPins(self: *Host) bool {
        self.app.clearLauncherQuickSlotPreferences();
        runUiActionOrLog("quick slot clear banner failed", self.setBanner(.info, "Cleared quick slot pins."));
        return true;
    }

    pub fn subclassButton(
        self: *Host,
        button_hwnd: HWND,
        proc: WNDPROC,
        prev_slot: *?*const anyopaque,
    ) void {
        setWindowData(button_hwnd, self);
        const previous = sys.SetWindowLongPtrW(
            button_hwnd,
            c.GWLP_WNDPROC,
            @as(LONG_PTR, @intCast(@intFromPtr(proc))),
        );
        prev_slot.* = if (previous == 0)
            null
        else
            @ptrFromInt(@as(usize, @intCast(previous)));
    }

    /// `toggle_visibility` hiding every window: remember which ones were on
    /// screen, and hide them. A window an earlier hide took off screen, and
    /// that nothing has shown since, stays marked.
    pub fn hideForToggle(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        const was_visible = sys.IsWindowVisible(hwnd) != 0;
        self.setVisible(false);
        self.hidden_by_toggle = self.hidden_by_toggle or was_visible;
    }

    /// `toggle_visibility` showing them again: only a window it hid comes
    /// back.
    pub fn showAfterToggle(self: *Host) !void {
        if (!self.hidden_by_toggle) return;
        self.hidden_by_toggle = false;
        self.setVisible(true);
        try self.layout();
    }

    pub fn setVisible(self: *Host, visible: bool) void {
        const hwnd = self.hwnd orelse return;
        if (!visible) {
            for (self.tabs.items) |*tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| entry.view.setVisible(false);
            }
        }
        _ = sys.ShowWindow(hwnd, if (visible) c.SW_SHOW else c.SW_HIDE);
        self.refreshSurfaceVisibility();
    }

    pub fn refreshSurfaceVisibility(self: *Host) void {
        self.refreshSurfaceVisibilityObserving(null);
    }

    /// `observed_cloaked` is the transition a DWM cloak WinEvent just
    /// reported, or `null` for message-driven refreshes that observed no
    /// transition. Passing it through is what lets an uncloak recover when
    /// `DwmGetWindowAttribute` fails; see `win32_power.resolveCloaked`.
    pub fn refreshSurfaceVisibilityObserving(self: *Host, observed_cloaked: ?bool) void {
        const hwnd = self.hwnd orelse return;
        // ConPTY tracks the owning window, including background tabs, not
        // per-pane rendering occlusion or DWM cloaking.
        const console_visible = sys.IsWindowVisible(hwnd) != 0 and sys.IsIconic(hwnd) == 0;
        for (self.tabs.items) |*tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| entry.view.syncConsoleVisibility(console_visible);
        }
        const state = win32_power.queryHostVisibility(
            hwnd,
            self.dwm_cloaked,
            observed_cloaked,
        );
        self.dwm_cloaked = state.cloaked;
        if (self.surfaces_visible != state.visible) {
            self.surfaces_visible = state.visible;
            for (self.tabs.items) |*tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| entry.view.syncOcclusion();
            }
        }
        // An info banner nobody can see waits, and starts over when the
        // window comes back. Outside the transition branch: a window first
        // shown while the flag still holds its initial `true` makes no
        // transition.
        self.syncBannerExpiry();

        // Deliberately outside the transition branch, and deliberately here
        // rather than at the message handlers. "The window is on screen" is
        // the conjunction of shown, not minimized and not cloaked, and the
        // three arrive independently: `ShowWindow` while DWM still reports
        // the window cloaked leaves `surfaces_visible` false, and the uncloak
        // that repairs it arrives as a WinEvent with no window message behind
        // it (`onHostCloakEvent`). This function is the only place that sees
        // every one of those inputs, so whichever of them completes last
        // drives the handshake. `noteFirstFrameShown` is idempotent, so the
        // common case -- already visible, nothing changed -- costs one
        // already-spent latch check per surface.
        if (self.surfaces_visible) self.noteFirstFrameShown();
    }

    pub const noteFirstFrameShown = surface_presentation.noteFirstFrameShown;

    pub fn present(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        if (hostPresentShowCommand(
            sys.IsWindowVisible(hwnd) != 0,
            sys.IsIconic(hwnd) != 0,
            sys.IsZoomed(hwnd) != 0,
        )) |show_cmd| {
            _ = sys.ShowWindow(hwnd, show_cmd);
        }
        self.refreshSurfaceVisibility();
        _ = sys.SetForegroundWindow(hwnd);
        _ = sys.SetFocus(hwnd);
    }

    pub fn setConfigProblemsBanner(self: *Host, text: []const u8) !void {
        try appendOwnedString(self.app.core_app.alloc, &self.config_problems_text, text);
        // A startup layout failure (or another earlier error) remains the
        // first thing to read. Closing it reveals the config problems.
        if (self.banner_kind == .err and self.banner_text != null) return;
        try self.setBanner(.err, text);
    }

    pub fn setBanner(self: *Host, kind: HostBannerKind, text: ?[]const u8) !void {
        var next_text = text;
        var next_kind: HostBannerKind = if (text == null) .none else kind;
        if (text == null) {
            if (self.config_problems_text) |pending| {
                if (self.banner_kind == .err and ownedStringEquals(self.banner_text, pending)) {
                    // Closing the config message acknowledges it on this
                    // window; another window has its own acknowledgement.
                    try appendOwnedString(self.app.core_app.alloc, &self.config_problems_text, null);
                } else {
                    next_text = pending;
                    next_kind = .err;
                }
            }
        }
        if (self.banner_kind == next_kind) {
            if (next_text) |value| {
                if (ownedStringEquals(self.banner_text, value)) {
                    // The same message again (undo pressed twice): a full
                    // countdown again, without announcing it twice.
                    self.stopBannerExpiry();
                    self.syncBannerExpiry();
                    return;
                }
            } else if (self.banner_text == null) {
                return;
            }
        }

        self.banner_kind = next_kind;
        try appendOwnedString(self.app.core_app.alloc, &self.banner_text, next_text);
        // This announces the banner itself, below.
        self.banner_announce_pending = false;
        // A new message gets a full countdown of its own, from its first
        // paint (`bannerPainted`).
        self.banner_painted = false;
        self.stopBannerExpiry();
        self.placeBanner(true);
        if (self.banner_uia_provider) |provider| provider.raiseLiveRegionChanged();
        // While an overlay is open, banner text is rendered inside the
        // overlay feedback lane rather than the ordinary host banner lane.
        if (self.overlay_mode != .none) self.invalidateOverlayText();
        // A confirm prompt's feedback lane is an owner-drawn child rather
        // than chrome paint, so invalidating the paint text is not enough
        // to put a banner raised mid-prompt on screen. Push it into the
        // control now instead of waiting for whatever runs `refreshChrome`
        // next, and announce it there: the host banner's own provider is
        // on an HWND that stays hidden for the whole overlay.
        if (self.overlay_mode == .confirm) {
            _ = chromeSyncOrLog("confirm body banner sync failed", self.syncOverlayHint());
            if (self.confirmBodyTextPlaced()) {
                if (self.overlay_body_uia_provider) |provider| provider.raiseLiveRegionChanged();
            }
        }
    }

    /// The app's update notice appeared, changed or went away. `announce`
    /// is true on one host only, so a reader hears a new notice once.
    pub fn updateNoticeChanged(self: *Host, announce: bool) void {
        // A message set with `setBanner` takes the banner's place, and stays
        // what the banner says and announces. A notice that an overlay keeps
        // off screen is announced when it comes on (`syncBannerChild`).
        self.banner_announce_pending = announce and self.app.update_notice != null and self.banner_text == null;
        self.placeBanner(true);
    }

    pub fn refreshModeIndicator(self: *Host) !void {
        try self.refreshModeIndicatorAt(sys.GetTickCount64());
    }

    fn refreshModeIndicatorAt(self: *Host, now_ms: u64) !void {
        const surface = self.activeSurface();
        // A pending key sequence shows in the banner only after this long;
        // until then a timer comes back for it.
        const sequence_delay_ms = 250;
        const delay: ?u32 = delay: {
            const active = surface orelse break :delay null;
            const start = active.key_sequence_since_ms orelse break :delay null;
            const elapsed = now_ms -| start;
            break :delay if (elapsed < sequence_delay_ms) @intCast(sequence_delay_ms - elapsed) else null;
        };
        // Recompute from the active surface on every tick. A queued tick from
        // a canceled sequence or another tab cannot resurrect its indicator.
        if (self.hwnd) |hwnd| {
            if (delay) |ms| {
                _ = sys.SetTimer(hwnd, c.INPUT_MODE_TIMER_ID, ms, null);
                self.mode_timer_active = true;
            } else if (self.mode_timer_active) {
                _ = sys.KillTimer(hwnd, c.INPUT_MODE_TIMER_ID);
                self.mode_timer_active = false;
            }
        }
        var buf: [512]u8 = undefined;
        const text = if (surface) |s| inputModeText(
            s.key_table_name,
            s.key_table_copy_mode,
            s.key_sequence_active and delay == null,
            &buf,
        ) else null;
        const same_text = optionalOwnedStringEquals(self.mode_indicator_text, text);
        if (same_text and self.mode_indicator_surface == surface) return;
        const announce = self.mode_indicator_text != null or text != null;
        try appendOwnedString(self.app.core_app.alloc, &self.mode_indicator_text, text);
        self.mode_indicator_surface = surface;
        // Never run layout or resize a ConPTY for an input-state change.
        self.placeBanner(true);
        if (announce) if (surface) |s| {
            const message = self.mode_indicator_text orelse "Normal input";
            const announced = if (s.terminal_accessibility) |session| session.announceInputMode(message) else false;
            if (!announced) if (self.banner_uia_provider) |provider| {
                win32_uia.events.raiseInputModeNotification(&provider.base, message);
            };
        };
    }

    fn inputModeText(table: ?[]const u8, copy_mode: bool, sequence: bool, buf: []u8) ?[]const u8 {
        if (table) |name| {
            const is_copy = copy_mode and std.mem.eql(u8, name, "copy_mode");
            const prefix: []const u8 = if (is_copy) "COPY MODE" else if (copy_mode) "COPY MODE; KEY TABLE: " else "KEY TABLE: ";
            return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
                prefix,
                if (is_copy) "" else utf8BoundedPrefix(name, @min(name.len, 384)),
                if (sequence) "; waiting for key" else "",
            }) catch prefix;
        }
        if (copy_mode) return if (sequence) "COPY MODE; waiting for key" else "COPY MODE";
        return if (sequence) "KEY SEQUENCE: waiting for key" else null;
    }

    test "chrome input mode text keeps nested copy mode and pending sequences" {
        var buf: [512]u8 = undefined;
        try std.testing.expectEqualStrings("COPY MODE; KEY TABLE: resize", inputModeText("resize", true, false, &buf).?);
        try std.testing.expectEqualStrings("COPY MODE; waiting for key", inputModeText("copy_mode", true, true, &buf).?);
        try std.testing.expectEqualStrings("KEY SEQUENCE: waiting for key", inputModeText(null, false, true, &buf).?);
        try std.testing.expectEqual(@as(?[]const u8, null), inputModeText(null, false, false, &buf));
    }

    test "chrome input mode native banner follows active surface and delayed sequences" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(inputModeBannerTestBody);
    }

    fn inputModeBannerTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var first: Surface = undefined;
        var second: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
            .surfaces = &.{ .{ .storage = &first, .host = &host }, .{ .storage = &second, .host = &host } },
            .tabs = &.{ .{ .host = &host, .surface = &first, .id = 1 }, .{ .host = &host, .surface = &second, .id = 2 } },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        host.layoutBanner(window.content, window.content.top);
        const banner = host.banner_hwnd.?;
        // TestSession deliberately has no COM apartment. Attach the same
        // live-text provider contract without COM threading for this fixture.
        const provider = try win32_uia.ChromeControlProvider.create(std.testing.allocator, banner, .{
            .ctx = @ptrCast(&host),
            .role = .live_text,
            .name = &bannerUiaName,
        });
        host.banner_uia_provider = provider;
        defer {
            host.banner_uia_provider = null;
            _ = provider.base.vtbl.Release(&provider.base);
        }
        try std.testing.expectEqual(.live_text, provider.state.role);
        var name: [512]u8 = undefined;
        const before = win32_uia.events.testing_input_modes;
        try first.setKeyTable(.{ .activate = "copy_mode" });
        try std.testing.expect(bannerTestVisible(banner));
        try std.testing.expectEqual(.mode, host.bannerActions());
        try std.testing.expect(host.banner_expires_at == null);
        try std.testing.expectEqualStrings("COPY MODE", provider.state.name(provider.state.ctx, provider.state.tag, &name));
        for (host.banner_buttons) |button| try std.testing.expect(!bannerTestVisible(button.?));
        try std.testing.expectEqual(before + 1, win32_uia.events.testing_input_modes);
        try first.setKeyTable(.{ .activate = "copy_mode" });
        try std.testing.expectEqual(before + 1, win32_uia.events.testing_input_modes);
        // A background pane's mode does not replace the active mode.
        try second.setKeyTable(.{ .activate = "resize" });
        try std.testing.expectEqualStrings("COPY MODE", bannerUiaName(@ptrCast(&host), 0, &name));
        host.active_tab = 1;
        try host.refreshModeIndicatorAt(1000);
        try std.testing.expectEqualStrings("KEY TABLE: resize", bannerUiaName(@ptrCast(&host), 0, &name));
        // Error feedback keeps precedence; clearing the mode leaves it intact.
        try host.setBanner(.err, "Failure");
        try second.setKeyTable(.deactivate_all);
        try std.testing.expectEqualStrings("Failure", bannerUiaName(@ptrCast(&host), 0, &name));
        try host.setBanner(.none, null);
        try std.testing.expect(!bannerTestVisible(banner));
        second.key_sequence_active = true;
        second.key_sequence_since_ms = 1000;
        try host.refreshModeIndicatorAt(1249);
        try std.testing.expect(!bannerTestVisible(banner));
        try host.refreshModeIndicatorAt(1250);
        try std.testing.expect(bannerTestVisible(banner));
        try std.testing.expectEqualStrings("KEY SEQUENCE: waiting for key", bannerUiaName(@ptrCast(&host), 0, &name));
        try second.setKeySequenceActive(false);
        try std.testing.expect(!bannerTestVisible(banner));
        // A queued tick after cancellation must not revive the sequence.
        try host.refreshModeIndicatorAt(1500);
        try std.testing.expect(!bannerTestVisible(banner));
        host.active_tab = 0;
        try host.refreshModeIndicatorAt(1600);
        try std.testing.expectEqualStrings("COPY MODE", bannerUiaName(@ptrCast(&host), 0, &name));
        app.update_notice = try UpdateNotice.init(std.testing.allocator, "1.3.200", "https://example.invalid/release", false);
        defer {
            app.update_notice.?.deinit(std.testing.allocator);
            app.update_notice = null;
        }
        host.updateNoticeChanged(true);
        try std.testing.expect(host.banner_announce_pending);
        try std.testing.expectEqual(.mode, host.bannerActions());
        try first.setKeyTable(.deactivate_all);
        try std.testing.expectEqual(.update, host.bannerActions());
        try std.testing.expect(!host.banner_announce_pending);
        try std.testing.expect(bannerTestVisible(banner));
    }

    /// Whether the banner child belongs on screen: message, mode or update
    /// text exists and no overlay owns the feedback lane.
    pub fn bannerShown(self: *const Host) bool {
        if (self.overlay_mode != .none) return false;
        return self.banner_text != null or self.mode_indicator_text != null or self.app.update_notice != null;
    }

    /// The buttons the banner offers: a message set with `setBanner` takes
    /// precedence over the update notice, and has a close button.
    fn bannerActions(self: *const Host) chrome_layout.BannerActions {
        if (self.banner_text == null) {
            if (self.mode_indicator_text != null) return .mode;
            if (self.app.update_notice) |notice| return if (notice.staged) .update_staged else .update;
        }
        return .close;
    }

    pub fn bannerButtonOf(self: *const Host, hwnd: ?HWND) ?BannerButton {
        const value = hwnd orelse return null;
        for (self.banner_buttons, 0..) |button, i| {
            if (button == value) return @enumFromInt(i);
        }
        return null;
    }

    /// Where F6 lands in the banner: its first button on screen.
    fn bannerFocusHwnd(self: *const Host) ?HWND {
        for (self.banner_buttons) |button| {
            if (focusableHwnd(button)) |hwnd| return hwnd;
        }
        return null;
    }

    /// Lay the banner out over the content area at `top`, which is below
    /// any docked search frame that starts there.
    ///
    /// The banner overlays the terminal's top rows rather than reserving a
    /// row of its own: a reserved row resizes the terminal every time a
    /// banner comes or goes, and every resize makes ConPTY and the shell
    /// redraw (#328).
    fn layoutBanner(self: *Host, content_rect: RECT, top: i32) void {
        self.banner_area = .{ .content = content_rect, .top = top };
        self.placeBanner(false);
    }

    /// Size the banner to what it shows now, at the right end of the area
    /// `layoutBanner` last gave it, so a short message leaves the start of
    /// the top rows (where a fresh prompt is) uncovered. Then sync it.
    /// `repaint` is for a change of text, label or kind, which can leave the
    /// rects as they were.
    fn placeBanner(self: *Host, repaint: bool) void {
        const hwnd = self.banner_hwnd orelse return;
        if (self.banner_area) |area| {
            const actions = self.bannerActions();
            const width = chrome_layout.hostBannerWidth(self.bannerTextWidth(hwnd), actions, self.current_dpi);
            const rect = chrome_layout.hostBannerRect(area.content, area.top, width, self.current_dpi);
            const old_rect = self.banner_placement.rect;
            const was_on_screen = self.banner_placement.visible and self.banner_placement.rect_known;
            if (applyChromeChildRect(hwnd, &self.banner_placement, rect) and was_on_screen) {
                // `MoveWindow` without repaint leaves the banner's old image
                // on the terminal it no longer covers (a shorter message, a
                // relayout); have everything under the old rect repaint.
                if (self.hwnd) |parent| _ = sys.RedrawWindow(parent, &old_rect, null, c.RDW_INVALIDATE | c.RDW_ALLCHILDREN);
            }
            const parts = chrome_layout.hostBannerParts(rect.right - rect.left, rect.bottom - rect.top, actions, self.current_dpi);
            const button_rects = [_]?RECT{ parts.primary, parts.dismiss };
            for (self.banner_buttons, &self.banner_button_placements, button_rects) |maybe_button, *placement, maybe_rect| {
                const button = maybe_button orelse continue;
                if (maybe_rect) |button_rect| {
                    _ = applyChromeChildRect(button, placement, button_rect);
                } else if (sys.GetFocus() == button) {
                    // A message replacing the notice takes Install away
                    // from under the keyboard; hiding the focused button
                    // would leave focus on the banner, where no key works.
                    self.focusTerminalOrHost();
                }
                _ = applyChildVisibility(button, placement, maybe_rect != null);
            }
        }
        if (repaint) {
            _ = sys.InvalidateRect(hwnd, null, 0);
            for (self.banner_buttons, self.banner_button_uia_providers) |button, provider| {
                if (button) |value| _ = sys.InvalidateRect(value, null, 0);
                // Their names carry the banner's text.
                if (provider) |value| value.raiseNameChanged();
            }
        }
        self.syncBannerChild();
    }

    /// The width of the banner's line in the chrome font, in pixels.
    fn bannerTextWidth(self: *const Host, hwnd: HWND) i32 {
        var buf: [512]u16 = undefined;
        const text = self.bannerDisplayText(&buf);
        if (text.len == 0) return 0;
        const hdc = sys.GetDC(hwnd) orelse return 0;
        defer _ = sys.ReleaseDC(hwnd, hdc);
        const prev_font = self.selectChromeFont(hdc);
        defer restoreFont(hdc, prev_font);
        var rect = RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = sys.DrawTextW(hdc, text.ptr, @intCast(text.len), &rect, c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX);
        return rect.right - rect.left;
    }

    /// Show the banner child exactly while there is something to show, keep
    /// it above the terminal, and run or stop the `.info` countdown to match.
    pub fn syncBannerChild(self: *Host) void {
        const hwnd = self.banner_hwnd orelse return;
        const shown = self.bannerShown();
        const focus = sys.GetFocus();
        const had_focus = focus != null and (focus == hwnd or self.bannerButtonOf(focus) != null);
        // Keyboard focus must not stay on a hidden window, where keys would
        // go nowhere visible; move it before the hide, not after.
        if (!shown and had_focus) self.focusTerminalOrHost();
        _ = applyChildVisibility(hwnd, &self.banner_placement, shown);
        if (shown) {
            // Over the terminal's top rows (AGENTS.md 2026-09-10: the first
            // surface is the topmost child).
            if (self.hwnd) |parent| raiseChildToTop(parent, hwnd);
        } else {
            // Shown again, it is painted again, and the countdown starts there.
            self.banner_painted = false;
            if (self.banner_pointer_inside) {
                // A leave armed before the hide could otherwise arrive after
                // the next show and start a countdown under a resting pointer.
                _ = trackMouseLeave(hwnd, c.TME_LEAVE | c.TME_CANCEL);
                self.banner_pointer_inside = false;
            }
            // A leave for a hidden button may never come; a stale hover
            // would hold the next message's countdown.
            if (self.bannerButtonOf(self.hovered_button_hwnd) != null) self.setHoveredButton(null);
        }
        if (shown and self.banner_announce_pending and self.mode_indicator_text == null) {
            self.banner_announce_pending = false;
            if (self.banner_uia_provider) |provider| provider.raiseLiveRegionChanged();
        }
        self.syncBannerExpiry();
    }

    fn focusTerminalOrHost(self: *Host) void {
        if (!self.moveFocusToRegion(.terminal)) self.refocusHostWindow();
    }

    /// Count an `.info` message down only while it is on screen and nobody
    /// is reading it: the banner has been painted (`bannerPainted`), the
    /// window is shown, not minimized and not cloaked, the pointer is not
    /// over the banner and it does not hold keyboard focus. Errors and the
    /// update notice stay until dismissed. When any of that ends, the
    /// countdown restarts in full.
    ///
    /// The duration is the system's own notification time, Settings >
    /// Accessibility > Visual effects > "Dismiss notifications after this
    /// amount of time" (`SPI_GETMESSAGEDURATION`, 5 s by default), which
    /// Windows uses for its notification pop-ups and users lengthen when
    /// they need longer to read.
    pub fn syncBannerExpiry(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        // `surfaces_visible` adds DWM cloaking, but it starts out true and is
        // only refreshed by window messages, so the window itself is asked
        // whether it is shown and not minimized.
        const run = self.banner_kind == .info and
            self.banner_text != null and
            self.banner_painted and
            self.banner_placement.visible and
            self.surfaces_visible and
            sys.IsWindowVisible(hwnd) != 0 and
            sys.IsIconic(hwnd) == 0 and
            !self.banner_pointer_inside and
            self.bannerButtonOf(self.hovered_button_hwnd) == null and
            !self.banner_focused;
        if (!run) return self.stopBannerExpiry();
        if (self.banner_expires_at != null) return;
        if (!infoBannersExpire()) return;
        const duration_ms = bannerMessageDurationMs();
        self.banner_expires_at = sys.GetTickCount64() + duration_ms;
        _ = sys.SetTimer(hwnd, c.BANNER_TIMER_ID, duration_ms, null);
    }

    /// The banner child answered `WM_PAINT` (never `WM_PRINTCLIENT`, which
    /// puts nothing on screen): the first one after a message is set, or
    /// after the banner was hidden, starts the `.info` countdown. A message
    /// that a busy UI thread (a slow cold start) could not paint for longer
    /// than the countdown is therefore painted before the countdown starts,
    /// not cleared in the same turn: the OpenGL fallback banner is the only
    /// place a user learns custom shaders and images are off. A banner that
    /// was painted, then waited out a minimized or hidden window, restarts
    /// at once when the window is back, as it always did.
    pub fn bannerPainted(self: *Host) void {
        if (self.banner_painted) return;
        self.banner_painted = true;
        self.syncBannerExpiry();
    }

    fn stopBannerExpiry(self: *Host) void {
        if (self.banner_expires_at == null) return;
        self.banner_expires_at = null;
        if (self.hwnd) |hwnd| _ = sys.KillTimer(hwnd, c.BANNER_TIMER_ID);
    }

    /// `BANNER_TIMER_ID` fired. Honoured only once the current deadline has
    /// passed: every new message, and every end of a hover or focus, writes
    /// a new deadline, so a tick left over from an older countdown finds it
    /// in the future and only re-arms for the rest, and a tick after the
    /// countdown stopped finds none.
    pub fn bannerExpiryTick(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        _ = sys.KillTimer(hwnd, c.BANNER_TIMER_ID);
        const deadline = self.banner_expires_at orelse return;
        const now = sys.GetTickCount64();
        if (now < deadline) {
            _ = sys.SetTimer(hwnd, c.BANNER_TIMER_ID, @intCast(@min(deadline - now, std.math.maxInt(u31))), null);
            return;
        }
        self.banner_expires_at = null;
        runUiActionOrLog("banner expiry failed", self.setBanner(.none, null));
    }

    pub fn bannerPointerMoved(self: *Host) void {
        if (self.banner_pointer_inside) return;
        const hwnd = self.banner_hwnd orelse return;
        _ = trackMouseLeave(hwnd, c.TME_LEAVE);
        self.banner_pointer_inside = true;
        self.syncBannerExpiry();
    }

    pub fn bannerPointerLeft(self: *Host) void {
        self.banner_pointer_inside = false;
        self.syncBannerExpiry();
    }

    /// A banner button was pressed (click, Enter or Space, or UIA Invoke).
    /// Install applies a staged update and destroys every window, this
    /// banner included, so callers must not touch the host after this.
    pub fn activateBannerButton(self: *Host, button: BannerButton) void {
        // UIA Invoke is posted, so it can arrive after the button went away
        // (an overlay opened, the notice changed): a hidden button does
        // nothing.
        if (!self.bannerShown() or !self.banner_button_placements[@intFromEnum(button)].visible) return;
        if (self.banner_text != null) {
            if (button != .dismiss) return;
            const had_focus = self.banner_focused;
            runUiActionOrLog("banner dismiss failed", self.setBanner(.none, null));
            // The update notice can be behind the message, on the same
            // buttons. Without this, the Enter that closed the message is
            // one repeat away from pressing Dismiss or Install.
            if (had_focus and self.banner_focused) self.focusTerminalOrHost();
            return;
        }
        if (self.app.update_notice == null) return;
        switch (button) {
            .primary => {
                // Install can destroy this host; only the app is used after.
                const app = self.app;
                app.update_action_host = self;
                defer app.update_action_host = null;
                app.openUpdateNotice() catch |err| {
                    log.warn("failed to open update notice err={}", .{err});
                };
            },
            .dismiss => self.app.dismissUpdateNotice(),
        }
    }

    /// Keys on a focused banner button; true when consumed. Never touch the
    /// host after a press: see `activateBannerButton`.
    pub fn handleBannerButtonKey(self: *Host, hwnd: HWND, button: BannerButton, vk: WPARAM, lParam: LPARAM) bool {
        const repeat = (lParamBits(lParam) & (1 << 30)) != 0;
        const key = bannerButtonKey(self.banner_text != null, vk, repeat) orelse return false;
        switch (key) {
            .ignore => {},
            .press => self.activateBannerButton(button),
            .dismiss => self.activateBannerButton(.dismiss),
            .other_button => {
                const other: BannerButton = if (button == .primary) .dismiss else .primary;
                if (focusableHwnd(self.banner_buttons[@intFromEnum(other)])) |target| {
                    if (target != hwnd) _ = sys.SetFocus(target);
                }
            },
        }
        return true;
    }

    /// The banner's line as drawn: the message with the same "Info: " or
    /// "Error: " prefix the overlay lane shows, or the update notice.
    /// Bounded by `buf`, so a long message is cut, never overflowed.
    fn bannerDisplayText(self: *const Host, buf: []u16) [:0]const u16 {
        var bytes: [1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&bytes);
        const text: []const u8 = if (self.banner_text) |message|
            buildHostBannerText(fixed.allocator(), self.banner_kind, message) catch message
        else if (self.mode_indicator_text) |mode|
            mode
        else if (self.app.update_notice) |notice|
            notice.message_text orelse ""
        else
            "";
        return buf[0..paint_text.utf8ToUtf16LeBounded(buf, text) :0];
    }

    fn bannerBackground(theme: *const ThemeColors, high_contrast: bool) u32 {
        // High Contrast keeps the system colors as they are; the adjusted
        // panel surface would step off them.
        return if (high_contrast) theme.overlay_bg else themeSurface(theme, .overlay_panel_bg);
    }

    /// Paint the banner child (its buttons paint themselves). Serves
    /// `WM_PAINT` and `WM_PRINTCLIENT`, so `PrintWindow` sees what the
    /// screen does. The child fills its whole rect itself: the host's
    /// `WS_CLIPCHILDREN` keeps the parent's paint out of it (AGENTS.md
    /// 2026-09-14).
    pub fn paintBanner(self: *Host, hdc: HDC, client: RECT, high_contrast: bool) void {
        if (client.right <= client.left or client.bottom <= client.top) return;
        const theme = &self.app.resolved_theme;
        const parts = chrome_layout.hostBannerParts(client.right - client.left, client.bottom - client.top, self.bannerActions(), self.current_dpi);
        fillSolidRect(hdc, client, bannerBackground(theme, high_contrast));
        fillSolidRect(hdc, .{
            .left = client.left,
            .top = client.bottom - 1,
            .right = client.right,
            .bottom = client.bottom,
        }, if (high_contrast) theme.overlay_border else themeSurface(theme, .overlay_panel_border));
        const accent = if (self.banner_text != null and self.banner_kind == .err) theme.error_fg else theme.info_fg;
        fillSolidRect(hdc, parts.stripe, accent);

        const prev_font = self.selectChromeFont(hdc);
        defer restoreFont(hdc, prev_font);
        const prev_bk_mode = sys.SetBkMode(hdc, c.TRANSPARENT);
        defer _ = sys.SetBkMode(hdc, prev_bk_mode);
        const prev_color = sys.SetTextColor(hdc, accent);
        defer _ = sys.SetTextColor(hdc, prev_color);

        var buf: [512]u16 = undefined;
        const text = self.bannerDisplayText(&buf);
        var text_rect = parts.text;
        _ = sys.DrawTextW(
            hdc,
            text.ptr,
            @intCast(text.len),
            &text_rect,
            c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
        );
    }

    /// `WM_DRAWITEM` for a banner button, sent to the banner, its parent.
    pub fn drawBannerButton(self: *Host, draw: *const DRAWITEMSTRUCT) bool {
        const button = self.bannerButtonOf(draw.hwndItem) orelse return false;
        const theme = &self.app.resolved_theme;
        const hovered = self.isHoveredButton(draw.hwndItem);
        const pressed = (draw.itemState & c.ODS_SELECTED) != 0;
        const focused = (draw.itemState & c.ODS_FOCUS) != 0 or sys.GetFocus() == draw.hwndItem;
        const ring = self.chromeFocusRingVisible(focused, false);
        const primary = button == .primary;
        const colors = buttonColorsFromTheme(theme, false, true, hovered, pressed, false, primary, isHighContrastActive());
        fillSolidRect(draw.hDC, draw.rcItem, bannerBackground(theme, isHighContrastActive()));
        // A message's close glyph sits bare until it is pointed at or
        // focused, the way a tab's close button does.
        const bare = self.banner_text != null and !hovered and !pressed and !ring;
        if (!bare) drawRoundedRect(draw.hDC, draw.rcItem, colors.bg, colors.border, self.scaled(4));
        if (ring) {
            const inset = self.scaled(2);
            drawRoundedRect(draw.hDC, .{
                .left = draw.rcItem.left + inset,
                .top = draw.rcItem.top + inset,
                .right = draw.rcItem.right - inset,
                .bottom = draw.rcItem.bottom - inset,
            }, colors.bg, if (primary) theme.button_accept_focus_ring else theme.button_overlay_focus_ring, self.scaled(3));
        }
        const prev_font = self.selectChromeFont(draw.hDC);
        defer restoreFont(draw.hDC, prev_font);
        _ = sys.SetBkMode(draw.hDC, c.TRANSPARENT);
        _ = sys.SetTextColor(draw.hDC, if (bare) theme.text_secondary else colors.fg);
        const label = self.bannerButtonLabel(button);
        var label_rect = draw.rcItem;
        _ = sys.DrawTextW(
            draw.hDC,
            label.ptr,
            @intCast(label.len),
            &label_rect,
            c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX,
        );
        return true;
    }

    fn bannerButtonLabel(self: *const Host, button: BannerButton) [:0]const u16 {
        if (self.banner_text != null) return std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}");
        const staged = if (self.app.update_notice) |notice| notice.staged else false;
        return switch (button) {
            .primary => if (staged)
                std.unicode.utf8ToUtf16LeStringLiteral("Install")
            else
                std.unicode.utf8ToUtf16LeStringLiteral("Open Release"),
            .dismiss => std.unicode.utf8ToUtf16LeStringLiteral("Dismiss"),
        };
    }

    /// A button's UIA name. F6 lands on a button, not on the banner's text,
    /// so the name that is read on landing says what the button is for.
    fn bannerButtonUiaName(ctx: *anyopaque, tag: usize, buf: []u8) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        if (self.banner_text) |text| {
            return std.fmt.bufPrint(buf, "Close: {s}", .{utf8BoundedPrefix(text, buf.len -| 7)}) catch "Close";
        }
        const notice = self.app.update_notice orelse return "";
        const label = if (notice.staged) "Install" else "Open Release";
        return switch (@as(BannerButton, @enumFromInt(tag))) {
            .primary => if (notice.message_text) |text|
                std.fmt.bufPrint(buf, "{s}: {s}", .{ label, utf8BoundedPrefix(text, buf.len -| label.len -| 2) }) catch label
            else
                label,
            .dismiss => "Dismiss update notice",
        };
    }

    /// A hidden top-level window standing in for the host window, with the
    /// real chrome children `ensureChromeButtons` creates and a plain child
    /// over the content rect standing in for the terminal pane, raised to
    /// the top as the first surface is (AGENTS.md 2026-09-10). Nothing is
    /// shown on the desktop.
    pub const BannerTestWindow = struct {
        parent: HWND,
        pane: HWND,
        content: RECT,

        pub fn init(host: *Host) !BannerTestWindow {
            const parent = try createTestHostWindow();
            errdefer _ = sys.DestroyWindow(parent);
            host.hwnd = parent;
            errdefer host.hwnd = null;
            // The tab-strip container is a layered child, which this
            // manifest-less test binary cannot create (AGENTS.md
            // 2026-10-01); a plain one takes its slot.
            host.tab_container_hwnd = try createTestChromeChild(parent, prompt_label_class);
            try host.ensureChromeButtons();
            const content = RECT{ .left = 0, .top = 32, .right = 320, .bottom = 240 };
            const pane = try createTestChromeChild(parent, prompt_label_class);
            _ = sys.MoveWindow(pane, content.left, content.top, content.right - content.left, content.bottom - content.top, 0);
            _ = sys.SetWindowPos(pane, null, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
            return .{ .parent = parent, .pane = pane, .content = content };
        }

        /// Destroys the children with the parent; the host keeps no handle.
        pub fn deinit(self: BannerTestWindow, host: *Host) void {
            host.stopBannerExpiry();
            host.hovered_button_hwnd = null;
            _ = sys.DestroyWindow(self.parent);
            host.hwnd = null;
            host.banner_hwnd = null;
            host.banner_prev_proc = null;
            host.banner_buttons = .{ null, null };
            host.tab_container_hwnd = null;
            host.tab_container_prev_proc = null;
            host.new_tab_hwnd = null;
            host.overflow_hwnd = null;
            host.chrome_button_prev_proc = null;
        }
    };

    /// A 32-bit DIB to print a window into through `WM_PRINTCLIENT`, the path
    /// `PrintWindow` takes, after filling it with a colour the banner never
    /// uses, so untouched pixels show.
    pub const BannerTestCanvas = struct {
        const untouched: u32 = 0x00FF00FF;
        const BITMAPINFOHEADER = extern struct {
            biSize: u32 = @sizeOf(@This()),
            biWidth: i32,
            biHeight: i32,
            biPlanes: u16 = 1,
            biBitCount: u16 = 32,
            biCompression: u32 = 0,
            biSizeImage: u32 = 0,
            biXPelsPerMeter: i32 = 0,
            biYPelsPerMeter: i32 = 0,
            biClrUsed: u32 = 0,
            biClrImportant: u32 = 0,
        };
        pub const raw = struct {
            extern "gdi32" fn CreateDIBSection(hdc: HDC, info: *const BITMAPINFOHEADER, usage: u32, bits: *?[*]u32, section: ?*anyopaque, offset: u32) callconv(.winapi) HGDIOBJ;
            pub extern "gdi32" fn GdiFlush() callconv(.winapi) i32;
        };

        dc: HDC,
        bitmap: HGDIOBJ,
        previous: HGDIOBJ,
        bits: [*]u32,
        width: i32,
        height: i32,

        pub fn init(width: i32, height: i32) !BannerTestCanvas {
            const dc = sys.CreateCompatibleDC(null) orelse return error.SkipZigTest;
            errdefer _ = sys.DeleteDC(dc);
            var bits: ?[*]u32 = null;
            // Top-down, so row 0 is the top of the window.
            const bitmap = raw.CreateDIBSection(dc, &.{ .biWidth = width, .biHeight = -height }, 0, &bits, null, 0) orelse return error.SkipZigTest;
            return .{
                .dc = dc,
                .bitmap = bitmap,
                .previous = sys.SelectObject(dc, bitmap),
                .bits = bits orelse return error.SkipZigTest,
                .width = width,
                .height = height,
            };
        }

        pub fn deinit(self: BannerTestCanvas) void {
            _ = sys.SelectObject(self.dc, self.previous);
            _ = sys.DeleteObject(self.bitmap);
            _ = sys.DeleteDC(self.dc);
        }

        fn print(self: BannerTestCanvas, hwnd: HWND) void {
            fillSolidRect(self.dc, .{ .left = 0, .top = 0, .right = self.width, .bottom = self.height }, untouched);
            _ = sys.SendMessageW(hwnd, c.WM_PRINTCLIENT, @intFromPtr(self.dc), c.PRF_CLIENT);
            _ = raw.GdiFlush();
        }

        /// The pixel at (x, y) as a COLORREF.
        pub fn pixel(self: BannerTestCanvas, x: i32, y: i32) u32 {
            const bgrx = self.bits[@intCast(y * self.width + x)];
            return ((bgrx & 0xFF) << 16) | (bgrx & 0xFF00) | ((bgrx >> 16) & 0xFF);
        }

        /// Pixels in `rect` that are neither `background` nor untouched.
        fn inked(self: BannerTestCanvas, rect: RECT, background: u32) usize {
            var count: usize = 0;
            var y = @max(0, rect.top);
            while (y < @min(self.height, rect.bottom)) : (y += 1) {
                var x = @max(0, rect.left);
                while (x < @min(self.width, rect.right)) : (x += 1) {
                    const value = self.pixel(x, y);
                    if (value != background and value != untouched) count += 1;
                }
            }
            return count;
        }

        fn untouchedCount(self: BannerTestCanvas) usize {
            var count: usize = 0;
            for (self.bits[0..@intCast(self.width * self.height)]) |value| {
                if (value & 0xFFFFFF == 0xFF00FF) count += 1;
            }
            return count;
        }
    };

    fn bannerTestVisible(hwnd: HWND) bool {
        return (sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE) & c.WS_VISIBLE) != 0;
    }

    fn bannerTestClientRect(hwnd: HWND) !RECT {
        var rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &rect) == 0) return error.TestUnexpectedResult;
        return rect;
    }

    /// The paint the message loop delivers once a banner is set or shown:
    /// `WM_PAINT`, which starts an `.info` countdown (`bannerPainted`). Like
    /// the loop, it paints only a banner that was invalidated and is shown,
    /// so a banner that nothing invalidates stays unpainted here too.
    fn bannerTestPaint(host: *Host) void {
        _ = sys.UpdateWindow(host.banner_hwnd.?);
    }

    fn bannerTestPress(host: *Host, button: BannerButton) void {
        const banner = host.banner_hwnd.?;
        const child = host.banner_buttons[@intFromEnum(button)].?;
        const id: usize = 1914 + @as(usize, @intFromEnum(button));
        _ = sys.SendMessageW(banner, c.WM_COMMAND, (c.BN_CLICKED << 16) | id, @bitCast(@intFromPtr(child)));
    }

    test "a banner shows above the terminal, at the right of its top rows, and paints itself" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        const banner = host.banner_hwnd.?;
        const close_button = host.banner_buttons[@intFromEnum(BannerButton.dismiss)].?;

        // Nothing to show: hidden, so F6 skips it.
        host.layoutBanner(window.content, window.content.top);
        try std.testing.expect(!bannerTestVisible(banner));
        try std.testing.expectEqual(@as(?HWND, window.pane), sys.GetWindow(window.parent, c.GW_CHILD));

        try host.setBanner(.err, "Not found.");
        try std.testing.expect(bannerTestVisible(banner));
        // Above the terminal, which would otherwise paint over it.
        try std.testing.expectEqual(@as(?HWND, banner), sys.GetWindow(window.parent, c.GW_CHILD));
        // Over the terminal's top rows, at their right end, so the start of
        // the rows stays uncovered; the terminal keeps its size.
        var banner_rect: RECT = undefined;
        var pane_rect: RECT = undefined;
        try std.testing.expect(sys.GetWindowRect(banner, &banner_rect) != 0);
        try std.testing.expect(sys.GetWindowRect(window.pane, &pane_rect) != 0);
        try std.testing.expectEqual(pane_rect.top, banner_rect.top);
        try std.testing.expectEqual(pane_rect.right, banner_rect.right);
        try std.testing.expect(banner_rect.left > pane_rect.left);
        try std.testing.expectEqual(@as(i32, 32), banner_rect.bottom - banner_rect.top);
        // A close button, nothing else.
        try std.testing.expect(bannerTestVisible(close_button));
        try std.testing.expect(!bannerTestVisible(host.banner_buttons[@intFromEnum(BannerButton.primary)].?));
        // Opaque to the pointer, unlike the hit-transparent child it was.
        const center_x: LPARAM = @divTrunc(banner_rect.left + banner_rect.right, 2);
        const center_y: LPARAM = @divTrunc(banner_rect.top + banner_rect.bottom, 2);
        try std.testing.expectEqual(@as(LRESULT, c.HTCLIENT), sys.SendMessageW(banner, c.WM_NCHITTEST, 0, (center_x & 0xFFFF) | ((center_y & 0xFFFF) << 16)));

        const theme = &app.resolved_theme;
        const background = bannerBackground(theme, isHighContrastActive());
        for ([_]u32{ 96, 144, 192 }) |dpi| {
            host.current_dpi = dpi;
            host.layoutBanner(window.content, window.content.top);
            const client = try bannerTestClientRect(banner);
            try std.testing.expectEqual(host.scaled(chrome_layout.banner_height_base), client.bottom);
            const parts = chrome_layout.hostBannerParts(client.right, client.bottom, .close, dpi);
            const canvas = try BannerTestCanvas.init(client.right, client.bottom);
            defer canvas.deinit();
            canvas.print(banner);
            // The banner owns every pixel of its rect.
            try std.testing.expectEqual(@as(usize, 0), canvas.untouchedCount());
            try std.testing.expectEqual(background, canvas.pixel(@divTrunc(client.right, 2), 0));
            try std.testing.expectEqual(theme.error_fg, canvas.pixel(0, @divTrunc(client.bottom, 2)));
            try std.testing.expect(canvas.inked(parts.text, background) > 0);
            // The close button paints its glyph.
            const close_client = try bannerTestClientRect(close_button);
            const button_canvas = try BannerTestCanvas.init(close_client.right, close_client.bottom);
            defer button_canvas.deinit();
            button_canvas.print(close_button);
            try std.testing.expectEqual(@as(usize, 0), button_canvas.untouchedCount());
            try std.testing.expect(button_canvas.inked(close_client, background) > 0);
        }

        // High Contrast paints on the system colours themselves.
        const saved_theme = app.resolved_theme;
        defer app.resolved_theme = saved_theme;
        app.resolved_theme = highContrastThemeFromSysColors();
        const client = try bannerTestClientRect(banner);
        const canvas = try BannerTestCanvas.init(client.right, client.bottom);
        defer canvas.deinit();
        host.paintBanner(canvas.dc, client, true);
        const window_bg = sys.GetSysColor(c.COLOR_WINDOW);
        try std.testing.expectEqual(window_bg, canvas.pixel(@divTrunc(client.right, 2), 0));
        try std.testing.expectEqual(sys.GetSysColor(c.COLOR_WINDOWTEXT), canvas.pixel(0, @divTrunc(client.bottom, 2)));
        try std.testing.expect(canvas.inked(chrome_layout.hostBannerParts(client.right, client.bottom, .close, host.current_dpi).text, window_bg) > 0);

        // The close button dismisses the message and hides the banner.
        bannerTestPress(&host, .dismiss);
        try std.testing.expectEqual(@as(?[:0]const u8, null), host.banner_text);
        try std.testing.expect(!bannerTestVisible(banner));
    }

    test "the update notice shows in the banner with its two buttons" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        const banner = host.banner_hwnd.?;
        const primary = host.banner_buttons[@intFromEnum(BannerButton.primary)].?;
        const dismiss = host.banner_buttons[@intFromEnum(BannerButton.dismiss)].?;
        host.layoutBanner(window.content, window.content.top);

        // Never press these here: Dismiss writes the real update state and
        // Open Release starts a browser.
        app.update_notice = try UpdateNotice.init(std.testing.allocator, "1.3.200", "https://example.invalid/release", false);
        defer {
            app.update_notice.?.deinit(std.testing.allocator);
            app.update_notice = null;
        }
        host.updateNoticeChanged(true);
        try std.testing.expect(bannerTestVisible(banner));
        try std.testing.expect(bannerTestVisible(primary));
        try std.testing.expect(bannerTestVisible(dismiss));
        var name_buf: [256]u8 = undefined;
        try std.testing.expectEqualStrings(
            "Update available: noctty 1.3.200 is ready on GitHub Releases.",
            bannerUiaName(@ptrCast(&host), 0, &name_buf),
        );
        try std.testing.expectEqualStrings(
            "Open Release: Update available: noctty 1.3.200 is ready on GitHub Releases.",
            bannerButtonUiaName(@ptrCast(&host), @intFromEnum(BannerButton.primary), &name_buf),
        );
        try std.testing.expectEqualStrings("Dismiss update notice", bannerButtonUiaName(@ptrCast(&host), @intFromEnum(BannerButton.dismiss), &name_buf));
        // A staged update offers Install instead, in the label and the name.
        app.update_notice.?.staged = true;
        try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Install"), host.bannerButtonLabel(.primary));
        try std.testing.expect(std.mem.startsWith(u8, bannerButtonUiaName(@ptrCast(&host), @intFromEnum(BannerButton.primary), &name_buf), "Install: "));
        try std.testing.expectEqual(chrome_layout.BannerActions.update_staged, host.bannerActions());
        app.update_notice.?.staged = false;
        // Updates never count down.
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);

        const background = bannerBackground(&app.resolved_theme, isHighContrastActive());
        for ([_]HWND{ banner, primary, dismiss }) |hwnd| {
            const client = try bannerTestClientRect(hwnd);
            const canvas = try BannerTestCanvas.init(client.right, client.bottom);
            defer canvas.deinit();
            canvas.print(hwnd);
            try std.testing.expect(canvas.inked(client, background) > 0);
        }

        // A message takes the banner's place while it is up, with a close
        // button only, and closing it brings the notice back.
        try host.setBanner(.info, "Layout saved.");
        try std.testing.expectEqual(chrome_layout.BannerActions.close, host.bannerActions());
        try std.testing.expect(!bannerTestVisible(primary));
        try std.testing.expectEqualStrings("Close: Layout saved.", bannerButtonUiaName(@ptrCast(&host), @intFromEnum(BannerButton.dismiss), &name_buf));
        // UIA Invoke is posted: one that lands while an overlay hides the
        // banner does nothing.
        host.overlay_mode = .tab_title;
        bannerTestPress(&host, .dismiss);
        try std.testing.expectEqualStrings("Layout saved.", host.banner_text.?);
        host.overlay_mode = .none;
        bannerTestPress(&host, .dismiss);
        try std.testing.expectEqual(chrome_layout.BannerActions.update, host.bannerActions());
        try std.testing.expect(bannerTestVisible(banner));
        try std.testing.expect(bannerTestVisible(primary));

        // A notice an overlay keeps off screen is announced when it comes on.
        host.overlay_mode = .tab_title;
        host.updateNoticeChanged(true);
        try std.testing.expect(!bannerTestVisible(banner));
        try std.testing.expect(host.banner_announce_pending);
        host.overlay_mode = .none;
        host.syncBannerChild();
        try std.testing.expect(bannerTestVisible(banner));
        try std.testing.expect(!host.banner_announce_pending);
    }

    /// Run `body` on a thread attached to a desktop of its own, where it can
    /// show and minimize windows without touching the user's desktop
    /// (AGENTS.md 2026-10-06; `SetThreadDesktop` needs a thread that owns
    /// no window yet).
    pub fn runOnPrivateDesktop(comptime body: anytype) !void {
        const Desktop = struct {
            extern "user32" fn CreateDesktopW(name: [*:0]const u16, device: ?*anyopaque, mode: ?*anyopaque, flags: u32, access: u32, attributes: ?*anyopaque) callconv(.winapi) ?*anyopaque;
            extern "user32" fn SetThreadDesktop(desktop: *anyopaque) callconv(.winapi) BOOL;
            extern "user32" fn CloseDesktop(desktop: *anyopaque) callconv(.winapi) BOOL;
            fn run(desktop: *anyopaque, result: *anyerror!void) void {
                result.* = if (SetThreadDesktop(desktop) == 0) lastError() else body();
            }
        };
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "noctty-banner-test-{x}-{d}", .{ @intFromPtr(&name_buf), sys.GetTickCount64() });
        const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, name);
        defer std.testing.allocator.free(wide_name);
        const desktop = Desktop.CreateDesktopW(wide_name.ptr, null, null, 0, 0x10000000, null) orelse return error.SkipZigTest;
        defer _ = Desktop.CloseDesktop(desktop);
        var result: anyerror!void = {};
        const thread = try std.Thread.spawn(.{}, Desktop.run, .{ desktop, &result });
        thread.join();
        return result;
    }

    test "an info banner counts down only while it is unread; errors stay" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(bannerCountdownTestBody);
    }

    fn bannerCountdownTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        host.layoutBanner(window.content, window.content.top);

        // A window that is not shown yet: nothing counts down, whatever the
        // cached `surfaces_visible` says.
        try host.setBanner(.info, "Nothing to undo.");
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        host.refreshSurfaceVisibility();
        // Shown but not painted: the countdown starts at the paint, so a UI
        // thread that was busy past it finds a full countdown, not an
        // overdue timer. A print into a bitmap (`WM_PRINTCLIENT`) puts
        // nothing on screen and starts nothing.
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        const banner = host.banner_hwnd.?;
        const client = try bannerTestClientRect(banner);
        const canvas = try BannerTestCanvas.init(client.right, client.bottom);
        defer canvas.deinit();
        canvas.print(banner);
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        try std.testing.expect(!host.banner_painted);
        bannerTestPaint(&host);
        const first = host.banner_expires_at orelse return error.TestExpectedCountdown;
        try std.testing.expect(first >= sys.GetTickCount64() + 4000);
        // A paint after that changes nothing.
        _ = sys.InvalidateRect(banner, null, 0);
        bannerTestPaint(&host);
        try std.testing.expectEqual(@as(?u64, first), host.banner_expires_at);
        // The same message again starts it over.
        host.banner_expires_at = 1;
        try host.setBanner(.info, "Nothing to undo.");
        try std.testing.expect(host.banner_expires_at.? >= first);

        // Pointed at (the banner or its button) or focused, it waits; when
        // that ends, it starts over.
        host.bannerPointerMoved();
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        host.bannerPointerLeft();
        try std.testing.expect(host.banner_expires_at != null);
        host.setHoveredButton(host.banner_buttons[@intFromEnum(BannerButton.dismiss)]);
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        host.setHoveredButton(null);
        try std.testing.expect(host.banner_expires_at != null);
        host.banner_focused = true;
        host.syncBannerExpiry();
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        host.banner_focused = false;
        host.syncBannerExpiry();
        try std.testing.expect(host.banner_expires_at != null);
        // Minimized, hidden or cloaked, it waits too, and starts over when
        // the window is back.
        for ([_]i32{ c.SW_SHOWMINNOACTIVE, c.SW_HIDE }) |away| {
            _ = sys.ShowWindow(window.parent, away);
            host.refreshSurfaceVisibility();
            try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
            _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
            if (sys.IsIconic(window.parent) != 0) _ = sys.ShowWindow(window.parent, c.SW_RESTORE);
            host.refreshSurfaceVisibility();
            try std.testing.expect(host.banner_expires_at != null);
        }
        host.surfaces_visible = false;
        host.syncBannerExpiry();
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        host.surfaces_visible = true;
        host.syncBannerExpiry();
        try std.testing.expect(host.banner_expires_at != null);

        // A tick before the deadline (left over from an older countdown,
        // or early) only re-arms.
        host.bannerExpiryTick();
        try std.testing.expectEqualStrings("Nothing to undo.", host.banner_text.?);
        try std.testing.expect(host.banner_expires_at != null);
        // A tick after the countdown stopped does nothing.
        host.stopBannerExpiry();
        host.bannerExpiryTick();
        try std.testing.expect(host.banner_text != null);
        // A tick at the deadline clears the message.
        host.syncBannerExpiry();
        host.banner_expires_at = 1;
        host.bannerExpiryTick();
        try std.testing.expectEqual(@as(?[:0]const u8, null), host.banner_text);
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);

        // Errors stay until dismissed, painted or not, and a later info
        // message is not cleared by the error's (absent) countdown.
        try host.setBanner(.err, "Layout could not be saved.");
        bannerTestPaint(&host);
        try std.testing.expect(host.banner_painted);
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        try host.setBanner(.info, "Layout saved.");
        bannerTestPaint(&host);
        try std.testing.expect(host.banner_expires_at != null);

        // Every new message waits for its own paint, and a banner that was
        // hidden (an overlay owns the feedback lane) for the paint it gets
        // when it comes back.
        try host.setBanner(.info, "Layout saved again.");
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        bannerTestPaint(&host);
        try std.testing.expect(host.banner_expires_at != null);
        host.overlay_mode = .command_palette;
        host.syncBannerChild();
        try std.testing.expect(!bannerTestVisible(host.banner_hwnd.?));
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        host.overlay_mode = .none;
        host.syncBannerChild();
        try std.testing.expect(bannerTestVisible(host.banner_hwnd.?));
        try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
        bannerTestPaint(&host);
        try std.testing.expect(host.banner_expires_at != null);
    }

    test "NOCTTY_RENDERER_KEEP_NOTICES keeps info banners up in test-tools builds only" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(bannerKeepNoticesTestBody);
    }

    fn bannerKeepNoticesTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        host.layoutBanner(window.content, window.content.top);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        host.refreshSurfaceVisibility();

        const name = std.unicode.utf8ToUtf16LeStringLiteral("NOCTTY_RENDERER_KEEP_NOTICES");
        if (windows.kernel32.SetEnvironmentVariableW(name, std.unicode.utf8ToUtf16LeStringLiteral("1")) == 0) return lastError();
        defer _ = windows.kernel32.SetEnvironmentVariableW(name, null);
        try host.setBanner(.info, "OpenGL could not start.");
        bannerTestPaint(&host);
        if (build_config.renderer_test_tools) {
            // No countdown, so nothing clears it, however long the UI
            // thread is busy before a harness reads it.
            try std.testing.expectEqual(@as(?u64, null), host.banner_expires_at);
            try std.testing.expectEqualStrings("OpenGL could not start.", host.banner_text.?);
        } else {
            // Shipped builds never read the switch.
            try std.testing.expect(host.banner_expires_at != null);
        }
    }

    pub const setOverlayDefaultBanner = overlay_session.HostControls.setOverlayDefaultBanner;

    pub const ensureOverlayControls = overlay_session.HostControls.ensureOverlayControls;

    fn tabContainerUiaName(_: *anyopaque, _: usize, _: []u8) []const u8 {
        return "Tabs";
    }

    /// UIA name for one tab item.
    ///
    /// The drawn label is compacted to whatever the button can show, so
    /// reporting it would hand assistive technology the same truncated text a
    /// sighted user is already squinting at. Name the item from the tab's full
    /// title instead and fall back to the drawn label only when the title does
    /// not fit the caller's buffer. The pane count rides along because the
    /// drawn label carries it and a split tab is a different thing to land on
    /// than a single-pane one.
    fn tabItemUiaName(ctx: *anyopaque, tab_id: usize, buf: []u8) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        for (self.tabs.items, 0..) |*tab, index| {
            if (tab.id != tab_id) continue;
            const fallback: []const u8 = if (tab.cached_button_label) |label| label else "Tab";
            const title = tab.cached_button_title orelse return fallback;
            return labels.buildTabItemUiaName(buf, index, title, tab.leafCount()) orelse fallback;
        }
        return "Tab";
    }

    /// UIA `ItemStatus` for a tab: what its programs reported through
    /// OSC 7501, such as "claude needs permission: Allow edit?". Empty when
    /// nothing is shown on the tab.
    fn tabItemUiaItemStatus(ctx: *anyopaque, tab_id: usize, buf: []u8) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const index = self.findTabIndexById(@intCast(tab_id)) orelse return "";
        const tab = &self.tabs.items[index];
        const status = tabStatusHeadline(tab) orelse
            return if (tab.bellRinging()) win32_bell.uia_item_status else "";
        var writer: std.Io.Writer = .fixed(buf);
        win32_program_status.writeStatusLine(
            &writer,
            &status.surface.program_status,
            status.record,
            null,
            true,
        ) catch return "";
        return writer.buffered();
    }

    /// UIA name for the tab title tooltip: the full title it exists to show.
    fn tabTooltipUiaName(ctx: *anyopaque, _: usize, buf: []u8) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        if (self.button_tooltip.shown != null) {
            // A button tooltip shows the button's whole name, unshortened.
            const text = self.tab_tooltip_text orelse return "";
            return std.fmt.bufPrint(buf, "{s}", .{text}) catch "";
        }
        const shown = self.tab_tooltip_tab_id orelse return "";
        for (self.tabs.items) |*tab| {
            if (tab.id != shown) continue;
            const title = tab.cached_button_title orelse return "";
            return std.fmt.bufPrint(buf, "{s}", .{title}) catch "";
        }
        return "";
    }

    fn tabItemUiaSelected(ctx: *anyopaque, tab_id: usize) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        for (self.tabs.items, 0..) |tab, index| {
            if (tab.id == tab_id) return index == self.active_tab;
        }
        return false;
    }

    /// The on-screen button of tab `tab_id` while the tab strip offers its
    /// close button, which is what its UIA close element stands for.
    fn closableTabButton(self: *Host, tab_id: usize) ?HWND {
        if (tabCloseAction(self.tabs.items.len) == .none or !self.shouldShowTabBar()) return null;
        const index = self.findTabIndexById(@intCast(tab_id)) orelse return null;
        const hwnd = self.tabs.items[index].button_hwnd orelse return null;
        if (sys.IsWindowVisible(hwnd) == 0) return null;
        return hwnd;
    }

    pub fn tabCloseUiaBounds(ctx: *anyopaque, tab_id: usize) ?win32_uia.UiaRect {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const hwnd = self.closableTabButton(tab_id) orelse return null;
        var rect: RECT = undefined;
        if (sys.GetWindowRect(hwnd, &rect) == 0) return null;
        // Same close zone as the pointer path, always at full alpha. An
        // inactive tab's fade never changes its accessibility affordance.
        const width = @min(self.scaled(host_tab_close_zone_width), rect.right - rect.left);
        rect.top = @min(rect.bottom, rect.top + self.tabContentTopInset());
        return .{
            .left = @floatFromInt(rect.right - width),
            .top = @floatFromInt(rect.top),
            .width = @floatFromInt(width),
            .height = @floatFromInt(rect.bottom - rect.top),
        };
    }

    fn tabCloseUiaInvoke(ctx: *anyopaque, tab_id: usize) bool {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const hwnd = self.closableTabButton(tab_id) orelse return false;
        return sys.PostMessageW(hwnd, win32_uia.widgets.tab_close_message, tab_id, 0) != 0;
    }

    pub fn tabItemUiaState(self: *Host, tab_id: usize) win32_uia.ChromeControlState {
        return .{
            .ctx = @ptrCast(self),
            .role = .tab_item,
            .tag = tab_id,
            .name = &tabItemUiaName,
            .item_status = &tabItemUiaItemStatus,
            .selected = &tabItemUiaSelected,
            .selection_container = &tabContainerUiaProvider,
            .close_bounds = &tabCloseUiaBounds,
            .close_invoke = &tabCloseUiaInvoke,
        };
    }

    test "PKG71 tab close uses full alpha on inactive tabs and only posts while closable" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(tabCloseUiaTestBody);
    }

    fn tabCloseUiaTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
            },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        const button = try createTestChromeChild(window.parent, prompt_button_class);
        host.tabs.items[1].button_hwnd = button;
        defer host.tabs.items[1].button_hwnd = null;
        const state = host.tabItemUiaState(2);
        try std.testing.expect(!state.selected.?(state.ctx, state.tag));
        try std.testing.expectEqual(@as(f32, 0), host.tab_close_hover.alphaAt(0));
        const bounds = state.close_bounds.?(state.ctx, state.tag).?;
        var rect: RECT = undefined;
        try std.testing.expect(sys.GetWindowRect(button, &rect) != 0);
        try std.testing.expectEqual(@as(f64, @floatFromInt(host.scaled(host_tab_close_zone_width))), bounds.width);
        try std.testing.expectEqual(@as(f64, @floatFromInt(rect.right)), bounds.left + bounds.width);
        try std.testing.expect(state.close_invoke.?(state.ctx, state.tag));
        // Invoke merely queues the same close path; it cannot destroy a tab
        // inside a provider call, and it preserves the active selection.
        try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.active_tab);
        var queued: sys.MSG = undefined;
        try std.testing.expect(sys.PeekMessageW(&queued, button, win32_uia.widgets.tab_close_message, win32_uia.widgets.tab_close_message, c.PM_REMOVE) != 0);
        try std.testing.expectEqual(@as(usize, 2), queued.wParam);
        _ = sys.ShowWindow(button, c.SW_HIDE);
        try std.testing.expect(state.close_bounds.?(state.ctx, state.tag) == null);
        try std.testing.expect(!state.close_invoke.?(state.ctx, state.tag));
        _ = sys.ShowWindow(button, c.SW_SHOWNOACTIVATE);
        const provider = try win32_uia.ChromeControlProvider.create(std.testing.allocator, button, state);
        defer _ = provider.base.vtbl.Release(&provider.base);
        host.tabs.items[1].uia_provider = provider;
        defer host.tabs.items[1].uia_provider = null;
        host.notifyTabListUiaChanged();
        try std.testing.expect(provider.close_child_present);
        const show_tab_bar = app.config.@"window-show-tab-bar";
        app.config.@"window-show-tab-bar" = .never;
        defer app.config.@"window-show-tab-bar" = show_tab_bar;
        try std.testing.expect(state.close_bounds.?(state.ctx, state.tag) == null);
        try std.testing.expect(!state.close_invoke.?(state.ctx, state.tag));
        host.notifyTabListUiaChanged();
        try std.testing.expect(!provider.close_child_present);
        app.config.@"window-show-tab-bar" = show_tab_bar;
        // Execute a stale queued message through the production handler: a
        // mismatched ID after reorder must be harmless.
        setWindowData(button, &host);
        const tab_id = host.tabs.items[1].id;
        host.tabs.items[1].id = 99;
        _ = tabButtonProc(button, win32_uia.widgets.tab_close_message, tab_id, 0);
        try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
        host.tabs.items[1].id = tab_id;
        host.tabs.items.len = 1;
        defer host.tabs.items.len = 2;
        host.tabs.items[0].button_hwnd = button;
        defer host.tabs.items[0].button_hwnd = null;
        // The tab that went away has no element any more. The one left has
        // its own, as the only tab (`soleTabCloseTestBody` closes it).
        try std.testing.expect(state.close_bounds.?(state.ctx, state.tag) == null);
        try std.testing.expect(!state.close_invoke.?(state.ctx, state.tag));
        const sole = host.tabItemUiaState(1);
        try std.testing.expect(sole.close_bounds.?(sole.ctx, sole.tag) != null);
        try std.testing.expect(sole.close_invoke.?(sole.ctx, sole.tag));
        try std.testing.expect(sys.PeekMessageW(&queued, button, win32_uia.widgets.tab_close_message, win32_uia.widgets.tab_close_message, c.PM_REMOVE) != 0);
    }

    test "PKG71 queued close rejects a tab hidden after Invoke" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(struct {
            fn run() !void {
                try queuedCloseHiddenTestBody(false);
            }
        }.run);
    }

    test "PKG71 queued close rejects a strip hidden after Invoke" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(struct {
            fn run() !void {
                try queuedCloseHiddenTestBody(true);
            }
        }.run);
    }

    fn queuedCloseHiddenTestBody(hide_strip: bool) !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host, .register = true },
            },
            .tabs = &.{
                .{ .host = &host, .surface = &surface_a, .id = 1 },
                .{ .host = &host, .surface = &surface_b, .id = 2 },
            },
        });
        defer session.deinit();
        try app.ensurePaletteListClass();
        defer _ = sys.UnregisterClassW(palette_list_class_name, app.hinstance);
        defer for ([_]*?[:0]const u8{
            &host.cached_overlay_edit,
            &host.cached_overlay_label,
            &host.cached_overlay_hint,
            &host.cached_overlay_preview,
            &host.cached_overlay_accept,
            &host.cached_overlay_cancel,
            &host.cached_window_title,
        }) |slot| {
            if (slot.*) |value| std.testing.allocator.free(value);
            slot.* = null;
        };
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        defer host.invokeConfirmCancel();
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        const button = try createTestChromeChild(window.parent, prompt_button_class);
        setWindowData(button, &host);
        host.tabs.items[1].button_hwnd = button;
        defer host.tabs.items[1].button_hwnd = null;
        app.config.@"undo-timeout" = .{ .duration = 0 };
        // A read-only fixture core safely asks before closing: observing the
        // prompt proves whether the production close path was reached.
        surface_b.core_surface.readonly = true;
        surface_b.core_initialized = true;
        defer surface_b.core_initialized = false;
        try std.testing.expect(tabCloseUiaInvoke(&host, 2));
        var queued: sys.MSG = undefined;
        try std.testing.expect(sys.PeekMessageW(&queued, button, win32_uia.widgets.tab_close_message, win32_uia.widgets.tab_close_message, c.PM_REMOVE) != 0);
        const show_tab_bar = app.config.@"window-show-tab-bar";
        if (hide_strip) app.config.@"window-show-tab-bar" = .never else _ = sys.ShowWindow(button, c.SW_HIDE);
        _ = tabButtonProc(button, queued.message, queued.wParam, queued.lParam);
        try std.testing.expectEqual(HostOverlayMode.none, host.overlay_mode);
        try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.active_tab);
        // Positive control: a newly queued close on the visible tab reaches
        // the ordinary confirmation path.
        app.config.@"window-show-tab-bar" = show_tab_bar;
        _ = sys.ShowWindow(button, c.SW_SHOWNOACTIVATE);
        try std.testing.expect(tabCloseUiaInvoke(&host, 2));
        try std.testing.expect(sys.PeekMessageW(&queued, button, win32_uia.widgets.tab_close_message, win32_uia.widgets.tab_close_message, c.PM_REMOVE) != 0);
        _ = tabButtonProc(button, queued.message, queued.wParam, queued.lParam);
        try std.testing.expectEqual(HostOverlayMode.confirm, host.overlay_mode);
        host.invokeConfirmCancel();
    }

    test "TABX the only tab draws its close X, offers it to UIA and closes the window" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(soleTabCloseTestBody);
    }

    fn soleTabCloseTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{.{ .storage = &surface, .host = &host, .register = true }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();
        try app.ensurePaletteListClass();
        defer _ = sys.UnregisterClassW(palette_list_class_name, app.hinstance);
        defer for ([_]*?[:0]const u8{
            &host.cached_overlay_edit,
            &host.cached_overlay_label,
            &host.cached_overlay_hint,
            &host.cached_overlay_preview,
            &host.cached_overlay_accept,
            &host.cached_overlay_cancel,
            &host.cached_window_title,
        }) |slot| {
            if (slot.*) |value| std.testing.allocator.free(value);
            slot.* = null;
        };
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        defer host.invokeConfirmCancel();
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        const width: i32 = 200;
        const height: i32 = 34;
        const button = try createTestChromeChild(window.parent, prompt_button_class);
        _ = sys.MoveWindow(button, 0, 0, width, height, 0);
        setWindowData(button, &host);
        host.tabs.items[0].button_hwnd = button;
        defer host.tabs.items[0].button_hwnd = null;
        const zone = host.scaled(host_tab_close_zone_width);

        // UIA: the tab has its close child, over the same zone the pointer
        // uses, and Invoke queues the close.
        const state = host.tabItemUiaState(1);
        const bounds = state.close_bounds.?(state.ctx, state.tag) orelse return error.TestUnexpectedResult;
        var rect: RECT = undefined;
        try std.testing.expect(sys.GetWindowRect(button, &rect) != 0);
        try std.testing.expectEqual(@as(f64, @floatFromInt(zone)), bounds.width);
        try std.testing.expectEqual(@as(f64, @floatFromInt(rect.right)), bounds.left + bounds.width);
        try std.testing.expect(state.close_invoke.?(state.ctx, state.tag));
        var queued: sys.MSG = undefined;
        try std.testing.expect(sys.PeekMessageW(&queued, button, win32_uia.widgets.tab_close_message, win32_uia.widgets.tab_close_message, c.PM_REMOVE) != 0);

        // Paint: the X is ink in the close zone, on a background the tab
        // paints uniformly there.
        const canvas = try BannerTestCanvas.init(width, height);
        defer canvas.deinit();
        fillSolidRect(canvas.dc, .{ .left = 0, .top = 0, .right = width, .bottom = height }, BannerTestCanvas.untouched);
        const draw: DRAWITEMSTRUCT = .{
            .CtlType = c.ODT_BUTTON,
            .CtlID = 1000,
            .itemID = 0,
            .itemAction = 0,
            .itemState = 0,
            .hwndItem = button,
            .hDC = canvas.dc,
            .rcItem = .{ .left = 0, .top = 0, .right = width, .bottom = height },
            .itemData = 0,
        };
        host.drawButton(&draw);
        _ = BannerTestCanvas.raw.GdiFlush();
        const ink = canvas.inked(
            .{ .left = width - zone + 3, .top = 6, .right = width - 3, .bottom = height - 6 },
            canvas.pixel(width - zone + 1, @divTrunc(height, 2)),
        );
        try std.testing.expect(ink > 0);

        // Every gesture that closes a tab from the strip closes the window
        // when the tab is the only one: a process the setting asks about
        // makes it ask once for the window, and the tab is not detached.
        // With no active tab the prompt has no terminal to bring forward,
        // which the fixture's has no renderer to wake for.
        host.active_tab = 1;
        defer host.active_tab = 0;
        surface.core_surface.readonly = true;
        surface.core_initialized = true;
        defer surface.core_initialized = false;
        _ = tabButtonProc(button, win32_uia.widgets.tab_close_message, 1, 0);
        try expectSoleTabWindowPrompt(&host);
        // The first gesture laid the strip out, so measure the button again.
        var client: RECT = undefined;
        try std.testing.expect(sys.GetClientRect(button, &client) != 0);
        const point: LPARAM = (@as(LPARAM, @divTrunc(client.bottom, 2)) << 16) | @as(LPARAM, client.right - @divTrunc(zone, 2));
        _ = tabButtonProc(button, c.WM_LBUTTONDOWN, 1, point);
        _ = tabButtonProc(button, c.WM_LBUTTONUP, 0, point);
        try expectSoleTabWindowPrompt(&host);
        _ = tabButtonProc(button, c.WM_MBUTTONUP, 0, point);
        try expectSoleTabWindowPrompt(&host);
        _ = tabButtonProc(button, c.WM_KEYDOWN, c.VK_DELETE, 0);
        try expectSoleTabWindowPrompt(&host);
    }

    fn expectSoleTabWindowPrompt(host: *Host) !void {
        try std.testing.expectEqual(HostOverlayMode.confirm, host.overlay_mode);
        try std.testing.expectEqualStrings("Close this window?", host.confirm_payload.?.title);
        try std.testing.expectEqual(@as(usize, 1), host.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 0), host.structural_undo_entries.items.len);
        host.invokeConfirmCancel();
        try std.testing.expectEqual(HostOverlayMode.none, host.overlay_mode);
    }

    fn activeTabUiaProvider(ctx: *anyopaque) ?*win32_uia.ChromeControlProvider {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return if (self.activeTab()) |tab| tab.uia_provider else null;
    }

    fn tabContainerUiaProvider(ctx: *anyopaque) ?*win32_uia.ChromeControlProvider {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.tab_container_uia_provider;
    }

    fn hostActionUiaName(_: *anyopaque, tag: usize, _: []u8) []const u8 {
        return labels.tabStripActionName(if (tag == 0) .new_tab else .more_tabs);
    }

    pub fn bannerUiaName(ctx: *anyopaque, _: usize, buf: []u8) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        if (self.banner_text) |text| return std.fmt.bufPrint(buf, "{s}", .{text}) catch "Notification";
        if (self.mode_indicator_text) |text| return std.fmt.bufPrint(buf, "{s}", .{text}) catch "Input mode";
        const notice = self.app.update_notice orelse return "";
        const message = notice.message_text orelse return "";
        return std.fmt.bufPrint(buf, "{s}", .{message}) catch "Update available";
    }

    pub const announceConfirmPrompt = overlay_session.HostControls.announceConfirmPrompt;

    pub const initOverlayPromptText = overlay_session.HostControls.initOverlayPromptText;

    pub const overlayPromptTextProvider = overlay_session.HostControls.overlayPromptTextProvider;

    pub const overlayPromptTextPrevProc = overlay_session.HostControls.overlayPromptTextPrevProc;

    /// True while one of the confirm prompt's own children owns its rect.
    ///
    /// Chrome paint reads these to skip the GDI string it used to draw
    /// there: the host carries `WS_CLIPCHILDREN`, so a visible child
    /// already clips the parent out of that rect and painting underneath
    /// it would only burn time. They are deliberately per line, not one
    /// gate for both: the title's rect is bounded by the query frame and
    /// collapses on a narrow window while the body's still has room, and
    /// an all-or-nothing gate would answer that by hiding the body too.
    ///
    /// The HWND check is not redundant with the placement. `layout` only
    /// touches a placement it has an HWND for, so the two agree today,
    /// but reading the placement alone makes this correct only as long as
    /// that guard stays where it is.
    pub fn confirmTitleTextPlaced(self: *const Host) bool {
        return confirmPromptLineOwnedByChild(
            self.overlay_mode,
            self.overlay_label_hwnd,
            self.overlay_label_placement,
        );
    }

    pub fn confirmBodyTextPlaced(self: *const Host) bool {
        return confirmPromptLineOwnedByChild(
            self.overlay_mode,
            self.overlay_hint_hwnd,
            self.overlay_hint_placement,
        );
    }

    fn confirmPromptTextColor(self: *const Host, title: bool) u32 {
        return confirmPromptLineColor(
            &self.app.resolved_theme,
            title,
            self.banner_kind,
            self.banner_text != null,
        );
    }

    /// Owner-draw for the confirm prompt's title and body lines.
    ///
    /// Reads the text back off the control rather than off the chrome
    /// paint cache: the control's own text is what `syncOverlayLabel` /
    /// `syncOverlayHint` wrote and what the UIA name reports, so drawing
    /// from it makes the pixels and the spoken name the same string by
    /// construction.
    pub fn drawConfirmPromptText(self: *Host, draw: *const DRAWITEMSTRUCT) bool {
        const title = if (self.overlay_label_hwnd) |label|
            label == draw.hwndItem
        else
            false;
        if (!title) {
            const is_body = if (self.overlay_hint_hwnd) |hint| hint == draw.hwndItem else false;
            if (!is_body) return false;
        }
        const placement = if (title) self.overlay_label_text else self.overlay_hint_text;
        const theme = &self.app.resolved_theme;
        // `WS_CLIPCHILDREN` keeps the parent's panel fill out of this
        // rect, so the child owns every pixel of its own background.
        fillSolidRect(draw.hDC, draw.rcItem, themeSurface(theme, .overlay_panel_bg));

        var buf: [1024]u16 = undefined;
        const copied = sys.GetWindowTextW(draw.hwndItem, &buf, @intCast(buf.len));
        if (copied <= 0) return true;
        const text: [:0]const u16 = buf[0..@intCast(copied) :0];

        // Restore everything this touches. The DC comes from the system
        // cache and is released when the control's `WM_PAINT` returns, so
        // nothing leaks today, but leaving half the state changed is how
        // the next handler added here inherits a surprise.
        const prev_font = self.selectChromeFont(draw.hDC);
        defer restoreFont(draw.hDC, prev_font);
        const prev_bk_mode = sys.SetBkMode(draw.hDC, c.TRANSPARENT);
        defer _ = sys.SetBkMode(draw.hDC, prev_bk_mode);
        const prev_color = sys.SetTextColor(draw.hDC, self.confirmPromptTextColor(title));
        defer _ = sys.SetTextColor(draw.hDC, prev_color);
        var text_rect = placement.text;
        drawTextWz(draw.hDC, text, &text_rect, confirm_prompt_text_format);
        return true;
    }

    pub fn createChromeUiaProvider(
        self: *Host,
        hwnd: HWND,
        state: win32_uia.ChromeControlState,
    ) ?*win32_uia.ChromeControlProvider {
        // Both helpers already bail out unless COM is initialised, so the
        // provider always uses COM threading; callers do not repeat it.
        if (!self.app.com_initialized) return null;
        var threaded_state = state;
        threaded_state.use_com_threading = true;
        return win32_uia.ChromeControlProvider.create(
            std.heap.page_allocator,
            hwnd,
            threaded_state,
        ) catch |err| {
            log.warn("chrome UIA provider unavailable err={}", .{err});
            return null;
        };
    }

    fn ensureChromeButtons(self: *Host) !void {
        const hwnd = self.hwnd orelse return;

        if (self.tab_container_hwnd == null) {
            self.tab_container_hwnd = sys.CreateWindowExW(
                c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT,
                prompt_label_class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                c.WS_CHILD | c.WS_VISIBLE | c.SS_OWNERDRAW,
                0,
                0,
                1,
                1,
                hwnd,
                @ptrFromInt(1912),
                self.app.hinstance,
                null,
            ) orelse return lastError();
            _ = sys.SetLayeredWindowAttributes(self.tab_container_hwnd.?, 0, 0, c.LWA_ALPHA);
            _ = sys.SetWindowLongPtrW(
                self.tab_container_hwnd.?,
                c.GWLP_USERDATA,
                @as(LONG_PTR, @intCast(@intFromPtr(self))),
            );
            const previous = sys.SetWindowLongPtrW(
                self.tab_container_hwnd.?,
                c.GWLP_WNDPROC,
                @as(LONG_PTR, @intCast(@intFromPtr(&tabContainerProc))),
            );
            self.tab_container_prev_proc = if (previous == 0) null else @ptrFromInt(@as(usize, @intCast(previous)));
            self.tab_container_uia_provider = self.createChromeUiaProvider(self.tab_container_hwnd.?, .{
                .ctx = @ptrCast(self),
                .role = .tab_container,
                .name = &tabContainerUiaName,
                .selected_provider = &activeTabUiaProvider,
            });
        }

        if (self.new_tab_hwnd == null) {
            self.new_tab_hwnd = sys.CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_new_button_label,
                c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_OWNERDRAW,
                0,
                0,
                host_tab_small_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1904),
                self.app.hinstance,
                null,
            ) orelse return lastError();
            self.subclassButton(self.new_tab_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
            self.new_tab_uia_provider = self.createChromeUiaProvider(self.new_tab_hwnd.?, .{
                .ctx = @ptrCast(self),
                .role = .button,
                .tag = 0,
                .name = &hostActionUiaName,
            });
        }

        if (self.overflow_hwnd == null) {
            self.overflow_hwnd = sys.CreateWindowExW(
                0,
                prompt_button_class,
                host_tab_dropdown_button_label,
                c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_OWNERDRAW,
                0,
                0,
                host_tab_overflow_button_width,
                host_tab_height - 8,
                hwnd,
                @ptrFromInt(1911),
                self.app.hinstance,
                null,
            ) orelse return lastError();
            self.subclassButton(self.overflow_hwnd.?, &hostButtonProc, &self.chrome_button_prev_proc);
            self.overflow_uia_provider = self.createChromeUiaProvider(self.overflow_hwnd.?, .{
                .ctx = @ptrCast(self),
                .role = .button,
                .tag = 1,
                .name = &hostActionUiaName,
            });
        }

        if (self.banner_hwnd == null) {
            // Painted by `paintBanner` from `hostBannerProc`; shown, placed
            // and raised above the terminal by `layoutBanner`.
            self.banner_hwnd = sys.CreateWindowExW(
                0,
                prompt_label_class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                c.WS_CHILD | c.WS_CLIPSIBLINGS | c.WS_CLIPCHILDREN | c.SS_OWNERDRAW,
                0,
                0,
                1,
                1,
                hwnd,
                @ptrFromInt(1913),
                self.app.hinstance,
                null,
            ) orelse return lastError();
            _ = sys.SetWindowLongPtrW(
                self.banner_hwnd.?,
                c.GWLP_USERDATA,
                @as(LONG_PTR, @intCast(@intFromPtr(self))),
            );
            const previous = sys.SetWindowLongPtrW(
                self.banner_hwnd.?,
                c.GWLP_WNDPROC,
                @as(LONG_PTR, @intCast(@intFromPtr(&hostBannerProc))),
            );
            self.banner_prev_proc = if (previous == 0) null else @ptrFromInt(@as(usize, @intCast(previous)));
            self.banner_uia_provider = self.createChromeUiaProvider(self.banner_hwnd.?, .{
                .ctx = @ptrCast(self),
                .role = .live_text,
                .name = &bannerUiaName,
            });
        }
        // Real buttons, so the keyboard, UIA Invoke and voice control reach
        // them like any other; F6 lands on the first one shown. Outside the
        // banner's own guard, so one that failed to be created is retried.
        if (self.banner_hwnd) |banner| {
            for (&self.banner_buttons, &self.banner_button_uia_providers, 0..) |*slot, *provider, i| {
                if (slot.* != null) continue;
                const button = sys.CreateWindowExW(
                    0,
                    prompt_button_class,
                    std.unicode.utf8ToUtf16LeStringLiteral(""),
                    c.WS_CHILD | c.WS_TABSTOP | c.BS_OWNERDRAW,
                    0,
                    0,
                    1,
                    1,
                    banner,
                    @ptrFromInt(1914 + i),
                    self.app.hinstance,
                    null,
                ) orelse return lastError();
                slot.* = button;
                self.subclassButton(button, &hostButtonProc, &self.chrome_button_prev_proc);
                provider.* = self.createChromeUiaProvider(button, .{
                    .ctx = @ptrCast(self),
                    .role = .button,
                    .tag = i,
                    .name = &bannerButtonUiaName,
                });
            }
        }
    }

    pub const showOverlay = overlay_session.HostControls.showOverlay;

    pub const hideOverlay = overlay_session.HostControls.hideOverlay;

    pub fn invalidateOverlayTransitionPlacementCache(self: *Host) void {
        self.overlay_label_placement.rect_known = false;
        self.overlay_hint_placement.rect_known = false;
        self.overlay_edit_placement.rect_known = false;
        self.overlay_accept_placement.rect_known = false;
        self.overlay_cancel_placement.rect_known = false;
        self.palette_list_placement.rect_known = false;
        if (self.activeTab()) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                entry.view.placement.rect_known = false;
            }
        }
    }

    pub const showConfirm = overlay_session.HostControls.showConfirm;

    pub const showConfirmOverlay = overlay_session.HostControls.showConfirmOverlay;

    pub const invokeConfirmAccept = overlay_session.HostControls.invokeConfirmAccept;

    pub const invokeConfirmCancel = overlay_session.HostControls.invokeConfirmCancel;

    /// Cancel a confirm that a terminal in `tab` asked for.
    fn cancelConfirmFromTab(self: *Host, tab: *Tab) void {
        const payload = self.confirm_payload orelse return;
        const userdata = payload.userdata orelse return;
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (@as(*anyopaque, @ptrCast(entry.view)) == userdata) return self.hideOverlay();
        }
    }

    pub const holdProgramConfirm = overlay_session.HostControls.holdProgramConfirm;

    pub const holdProgramConfirmForKey = overlay_session.HostControls.holdProgramConfirmForKey;

    pub const programConfirmOpen = overlay_session.HostControls.programConfirmOpen;

    pub const cancelConfirmIfOwnedBy = overlay_session.HostControls.cancelConfirmIfOwnedBy;

    pub fn overlayInitialText(self: *Host, mode: HostOverlayMode) ?[]const u8 {
        const surface = self.activeSurface() orelse return null;
        return switch (mode) {
            .none => null,
            .command_palette => null,
            .profile => if (self.selectedProfile()) |profile|
                self.app.core_app.alloc.dupe(u8, profile.key) catch null
            else
                self.app.core_app.alloc.dupe(u8, "") catch null,
            // `.search` remains a theme/UIA role; search uses the docked bar.
            .search => null,
            .surface_title => if (surface.title_override) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else if (surface.title) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else
                self.app.core_app.alloc.dupe(u8, "") catch null,
            .tab_title => if (surface.tab_title_override) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else if (surface.title_override) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else if (surface.title) |value|
                self.app.core_app.alloc.dupe(u8, value) catch null
            else
                self.app.core_app.alloc.dupe(u8, "") catch null,
            .tab_overview => blk: {
                const status = self.app.hostTabStatus(surface);
                break :blk std.fmt.allocPrint(self.app.core_app.alloc, "{d}", .{status.index + 1}) catch null;
            },
            // Confirm overlays don't carry editable text — the body is
            // held by `confirm_payload.body` and painted by the paint
            // branch. Returning null leaves the hidden EDIT empty.
            .confirm => null,
        };
    }

    pub const syncOverlayLabel = overlay_session.HostControls.syncOverlayLabel;

    pub const syncOverlayButtons = overlay_session.HostControls.syncOverlayButtons;

    pub const confirmText = overlay_session.HostControls.confirmText;

    const confirmHasPreview = overlay_session.HostControls.confirmHasPreview;

    pub const syncOverlayPreview = overlay_session.HostControls.syncOverlayPreview;

    pub const syncOverlayHint = overlay_session.HostControls.syncOverlayHint;

    pub const clearOverlayCompletion = palette_controller.HostControls.clearOverlayCompletion;

    pub fn ensureThemeBrushes(self: *Host) !void {
        const theme = &self.app.resolved_theme;
        if (self.chrome_brush == null) {
            self.chrome_brush = sys.CreateSolidBrush(theme.chrome_bg) orelse return lastError();
        }
        if (self.overlay_brush == null) {
            self.overlay_brush = sys.CreateSolidBrush(theme.overlay_bg) orelse return lastError();
        }
        if (self.edit_brush == null) {
            self.edit_brush = sys.CreateSolidBrush(theme.edit_bg) orelse return lastError();
        }
    }

    pub fn rebuildThemeBrushes(self: *Host) void {
        if (self.chrome_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.overlay_brush) |brush| _ = sys.DeleteObject(brush);
        if (self.edit_brush) |brush| _ = sys.DeleteObject(brush);
        self.chrome_brush = null;
        self.overlay_brush = null;
        self.edit_brush = null;
        runUiActionOrLog("theme brush recreation failed", self.ensureThemeBrushes());
    }

    pub fn createChromeFont(self: *Host) ?*anyopaque {
        var lf: LOGFONTW = .{};
        lf.lfHeight = -self.scaled(14);
        lf.lfWeight = c.FW_NORMAL;

        // Try config font family first
        if (self.app.config.@"window-title-font-family") |family| {
            const name_w = std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, family) catch return null;
            defer self.app.core_app.alloc.free(name_w);
            const copy_len = @min(name_w.len, c.LF_FACESIZE - 1);
            @memcpy(lf.lfFaceName[0..copy_len], name_w[0..copy_len]);
        } else {
            // Fallback: system UI font via NONCLIENTMETRICS
            var ncm: NONCLIENTMETRICSW = undefined;
            ncm.cbSize = @sizeOf(NONCLIENTMETRICSW);
            if (sys.SystemParametersInfoW(c.SPI_GETNONCLIENTMETRICS, @sizeOf(NONCLIENTMETRICSW), @ptrCast(&ncm), 0) != 0) {
                lf = ncm.lfMessageFont;
                lf.lfHeight = -self.scaled(14);
                lf.lfQuality = c.CLEARTYPE_QUALITY;
            }
        }

        return sys.CreateFontIndirectW(&lf);
    }

    fn createTitlebarIconFont(self: *Host, faces: []const [*:0]const u16, logical_px: i32) IconFontChoice {
        return createIconFontWithGlyphs(faces, &titlebar_icon_glyphs, self.scaled(logical_px));
    }

    pub const searchIconFont = search_controls.HostControls.searchIconFont;

    /// Select the chrome font into `hdc`, returning what it replaced for
    /// `restoreFont`; null, and nothing selected, when there is none.
    pub fn selectChromeFont(self: *const Host, hdc: HDC) HGDIOBJ {
        const font = self.chrome_font orelse return null;
        return sys.SelectObject(hdc, font);
    }

    pub fn restoreFont(hdc: HDC, previous: HGDIOBJ) void {
        if (previous) |font| _ = sys.SelectObject(hdc, font);
    }

    /// Monospace font for the confirm preview. `window-title-font-family`
    /// is deliberately not consulted: that option names a UI font, and a
    /// proportional face would misrepresent the whitespace and column
    /// alignment of the bytes being judged. Leaving `lfFaceName` empty
    /// with `FIXED_PITCH | FF_MODERN` lets GDI pick the system's fixed
    /// face, which avoids hardcoding a face that may not be installed.
    pub fn createPreviewFont(self: *Host) ?*anyopaque {
        var lf: LOGFONTW = .{};
        lf.lfHeight = -self.scaled(13);
        lf.lfWeight = c.FW_NORMAL;
        lf.lfQuality = c.CLEARTYPE_QUALITY;
        lf.lfPitchAndFamily = c.FIXED_PITCH | c.FF_MODERN;
        return sys.CreateFontIndirectW(&lf);
    }

    pub fn recreateTitlebarIconFonts(self: *Host) void {
        self.recreateTitlebarIconFontsFrom(&titlebar_icon_faces);
    }

    fn recreateTitlebarIconFontsFrom(self: *Host, faces: []const [*:0]const u16) void {
        if (self.titlebar_caption_icon_font) |old| _ = sys.DeleteObject(old);
        if (self.titlebar_action_icon_font) |old| _ = sys.DeleteObject(old);
        if (self.search_icon_font) |old| _ = sys.DeleteObject(old);
        const caption = self.createTitlebarIconFont(faces, 10);
        const action = self.createTitlebarIconFont(faces, 12);
        self.titlebar_caption_icon_font = caption.font;
        self.titlebar_action_icon_font = action.font;
        self.titlebar_icons_geometric = caption.geometric and action.geometric;
        self.search_icon_font = null;
        self.search_icon_font_resolved = false;
    }

    pub fn recreateChromeFont(self: *Host) void {
        if (self.chrome_font) |old| _ = sys.DeleteObject(old);
        self.chrome_font = self.createChromeFont();
        // The preview font tracks DPI the same way, so it is rebuilt on
        // the same trigger rather than growing a second invalidation path.
        if (self.preview_font) |old| _ = sys.DeleteObject(old);
        self.preview_font = self.createPreviewFont();
        if (self.preview_font) |font| {
            if (self.overlay_preview_hwnd) |preview| {
                _ = sys.SendMessageW(preview, c.WM_SETFONT, @intFromPtr(font), 1);
            }
        }
        self.recreateTitlebarIconFonts();
        // Send WM_SETFONT to child controls
        if (self.chrome_font) |font| {
            if (self.overlay_edit_hwnd) |edit| _ = sys.SendMessageW(edit, c.WM_SETFONT, @intFromPtr(font), 1);
            if (self.overlay_label_hwnd) |label| _ = sys.SendMessageW(label, c.WM_SETFONT, @intFromPtr(font), 1);
            if (self.overlay_hint_hwnd) |hint| _ = sys.SendMessageW(hint, c.WM_SETFONT, @intFromPtr(font), 1);
            for (self.app.registry.windows.items) |surface| {
                if (surface.host != self) continue;
                surface.applySearchBarFont(font);
            }
        }
        // The banner is sized to its line in this font.
        self.placeBanner(true);
    }

    fn ensureSearchTimer(self: *Host) void {
        if (self.search_timer_active) return;
        const hwnd = self.hwnd orelse return;
        _ = sys.SetTimer(hwnd, c.SEARCH_TIMER_ID, c.SEARCH_TIMER_INTERVAL_MS, null);
        self.search_timer_active = true;
    }

    fn killSearchTimer(self: *Host) void {
        if (!self.search_timer_active) return;
        if (self.hwnd) |hwnd| _ = sys.KillTimer(hwnd, c.SEARCH_TIMER_ID);
        self.search_timer_active = false;
    }

    pub fn refreshSearchTimerState(self: *Host) void {
        const tab = self.activeTab() orelse {
            self.killSearchTimer();
            return;
        };

        var wants_timer = false;
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (!entry.view.search_bar.visible) continue;
            if (entry.view.search_bar.query.len == 0) continue;
            if (!entry.view.search_bar.searched) {
                wants_timer = true;
                break;
            }
        }

        if (wants_timer) self.ensureSearchTimer() else self.killSearchTimer();
    }

    pub fn tickSearchBars(self: *Host) void {
        const now_ms: i64 = @intCast(sys.GetTickCount64());
        if (self.activeTab()) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                if (!entry.view.search_bar.visible) continue;
                if (!entry.view.search_bar.shouldRunSearch(now_ms)) continue;
                _ = entry.view.runPendingSearchNow() catch |err| {
                    log.warn("win32 search refresh failed err={}", .{err});
                    continue;
                };
            }
        }
        self.refreshSearchTimerState();
    }

    pub fn ensureScrollbarTimer(self: *Host) void {
        if (self.scrollbar_timer_active) return;
        const hwnd = self.hwnd orelse return;
        _ = sys.SetTimer(hwnd, c.SCROLLBAR_TIMER_ID, c.SCROLLBAR_TIMER_INTERVAL_MS, null);
        self.scrollbar_timer_active = true;
    }

    pub fn killScrollbarTimer(self: *Host) void {
        if (!self.scrollbar_timer_active) return;
        if (self.hwnd) |hwnd| _ = sys.KillTimer(hwnd, c.SCROLLBAR_TIMER_ID);
        self.scrollbar_timer_active = false;
    }

    fn refreshScrollbarTimerState(self: *Host) void {
        const tab = self.activeTab() orelse {
            self.killScrollbarTimer();
            return;
        };

        var wants_timer = false;
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.scrollbarNeedsHeartbeat()) {
                wants_timer = true;
                break;
            }
        }

        if (wants_timer) self.ensureScrollbarTimer() else self.killScrollbarTimer();
    }

    pub fn tickScrollbars(self: *Host) void {
        const now_ms = sys.GetTickCount64();
        if (self.activeTab()) |tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                entry.view.tickScrollbar(now_ms);
            }
        }
        self.refreshScrollbarTimerState();
    }

    pub fn showContextMenu(self: *Host, screen_x: i32, screen_y: i32) void {
        const hwnd = self.hwnd orelse return;
        const menu = sys.CreatePopupMenu() orelse return;
        defer _ = sys.DestroyMenu(menu);

        // Check if active surface has a selection
        const has_selection = if (self.activeSurface()) |s| blk: {
            if (!s.core_initialized) break :blk false;
            break :blk s.core_surface.hasSelection();
        } else false;

        _ = sys.AppendMenuW(menu, if (has_selection) c.MF_STRING else c.MF_GRAYED, c.CTX_COPY, std.unicode.utf8ToUtf16LeStringLiteral("Copy\tCtrl+Shift+C"));
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_PASTE, std.unicode.utf8ToUtf16LeStringLiteral("Paste\tCtrl+Shift+V"));
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_SELECT_ALL, std.unicode.utf8ToUtf16LeStringLiteral("Select All"));
        _ = sys.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_FIND, std.unicode.utf8ToUtf16LeStringLiteral("Find...\tCtrl+Shift+F"));
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_COMMAND_PALETTE, std.unicode.utf8ToUtf16LeStringLiteral("Command Palette\tCtrl+Shift+P"));
        _ = sys.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));

        // Split submenu with all four directions
        const split_menu = sys.CreatePopupMenu() orelse return;
        _ = sys.AppendMenuW(split_menu, c.MF_STRING, c.CTX_SPLIT_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Split Right"));
        _ = sys.AppendMenuW(split_menu, c.MF_STRING, c.CTX_SPLIT_DOWN, std.unicode.utf8ToUtf16LeStringLiteral("Split Down"));
        _ = sys.AppendMenuW(split_menu, c.MF_STRING, c.CTX_SPLIT_LEFT, std.unicode.utf8ToUtf16LeStringLiteral("Split Left"));
        _ = sys.AppendMenuW(split_menu, c.MF_STRING, c.CTX_SPLIT_UP, std.unicode.utf8ToUtf16LeStringLiteral("Split Up"));
        _ = sys.AppendMenuW(menu, c.MF_POPUP, @intFromPtr(split_menu), std.unicode.utf8ToUtf16LeStringLiteral("Split"));

        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_NEW_WINDOW, std.unicode.utf8ToUtf16LeStringLiteral("New Window"));

        // Menu must be owned by top-level host HWND to avoid dismiss bugs
        _ = sys.SetForegroundWindow(hwnd);
        const cmd = sys.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_LEFTALIGN | c.TPM_TOPALIGN, screen_x, screen_y, 0, hwnd, null);
        _ = sys.PostMessageW(hwnd, c.WM_NULL, 0, 0);

        // Dispatch command (cmd is 0 on cancel)
        self.handleContextMenuCommand(cmd);
    }

    fn handleContextMenuCommand(self: *Host, cmd: BOOL) void {
        if (cmd <= 0) return; // 0 = cancel/dismiss
        const surface = self.activeSurface() orelse return;
        if (!surface.core_initialized) return;

        switch (@as(usize, @intCast(cmd))) {
            c.CTX_COPY => {
                runUiActionOrLog("context menu copy failed", surface.core_surface.performBindingAction(.{ .copy_to_clipboard = .mixed }));
            },
            c.CTX_PASTE => {
                runUiActionOrLog("context menu paste failed", surface.core_surface.performBindingAction(.{ .paste_from_clipboard = {} }));
            },
            c.CTX_SELECT_ALL => {
                runUiActionOrLog("context menu select all failed", surface.core_surface.performBindingAction(.{ .select_all = {} }));
            },
            c.CTX_FIND => {
                runUiActionOrLog("context menu find failed", surface.showSearchOverlay(""));
            },
            c.CTX_COMMAND_PALETTE => {
                runUiActionOrLog("context menu command palette failed", surface.toggleCommandPalette());
            },
            c.CTX_NEW_TAB => {
                self.postDeferredNewTab();
            },
            c.CTX_SPLIT_RIGHT => {
                runUiActionOrLog("context menu split right failed", self.app.performAction(.{ .surface = surface.core() }, .new_split, .right));
            },
            c.CTX_SPLIT_DOWN => {
                runUiActionOrLog("context menu split down failed", self.app.performAction(.{ .surface = surface.core() }, .new_split, .down));
            },
            c.CTX_SPLIT_LEFT => {
                runUiActionOrLog("context menu split left failed", self.app.performAction(.{ .surface = surface.core() }, .new_split, .left));
            },
            c.CTX_SPLIT_UP => {
                runUiActionOrLog("context menu split up failed", self.app.performAction(.{ .surface = surface.core() }, .new_split, .up));
            },
            c.CTX_NEW_WINDOW => {
                runUiActionOrLog("context menu new window failed", self.app.performAction(.{ .surface = surface.core() }, .new_window, .{}));
            },
            else => {}, // 0 = cancel, ignore
        }
    }

    const TabMenuOrigin = enum { pointer, keyboard };

    /// Open the context menu of the tab at `tab_index`. The tab is activated
    /// first, so every command acts on it and not on whichever tab was in
    /// front. A menu opened from the keyboard hands focus back to the strip
    /// when it closes (`labels.tabContextMenuRestoresStripFocus`), on the
    /// tab the menu was for. Returns false, with the menu not shown, when the
    /// tab could not be activated. `self` may be gone when it returns true:
    /// closing a window's only tab closes the window.
    pub fn showTabContextMenu(self: *Host, button_hwnd: HWND, tab_index: usize, origin: TabMenuOrigin) bool {
        const app = self.app;
        const host_id = self.id;
        const hwnd = self.hwnd orelse return false;
        if (tab_index >= self.tabs.items.len) return false;
        const tab_id = self.tabs.items[tab_index].id;
        if (origin != .keyboard or tab_index != self.active_tab) {
            if (!self.activateTabIndex(tab_index)) return false;
        }
        // The menu answers the question a title tooltip was there for.
        self.hideTabTooltip();
        const menu = sys.CreatePopupMenu() orelse return true;
        defer _ = sys.DestroyMenu(menu);

        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_TAB_RENAME, std.unicode.utf8ToUtf16LeStringLiteral("Rename Tab"));
        _ = sys.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_TAB_MOVE_LEFT, std.unicode.utf8ToUtf16LeStringLiteral("Move Tab Left"));
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_TAB_MOVE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Move Tab Right"));
        _ = sys.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);

        // The only tab closes too: its window goes with it (`tabCloseAction`).
        const close_flag: UINT = if (tabCloseAction(self.tabs.items.len) != .none) c.MF_STRING else c.MF_GRAYED;
        _ = sys.AppendMenuW(menu, close_flag, c.CTX_TAB_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = sys.AppendMenuW(menu, if (self.tabs.items.len > 1) c.MF_STRING else c.MF_GRAYED, c.CTX_TAB_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));

        // Position below the tab button
        var rect: RECT = undefined;
        if (sys.GetWindowRect(button_hwnd, &rect) == 0) return true;

        _ = sys.SetForegroundWindow(hwnd);
        const cmd = sys.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_LEFTALIGN | c.TPM_TOPALIGN, rect.left, rect.bottom, 0, hwnd, null);
        _ = sys.PostMessageW(hwnd, c.WM_NULL, 0, 0);

        // A modal menu pumps window messages. A close can free the Host,
        // so resolve its identity through the still-live App before reading it.
        var live = app.registry.findHostById(host_id) orelse return true;
        if (cmd > 0) {
            // The tabs may have moved while the menu was up: find ours again.
            const index = live.findTabIndexById(tab_id) orelse return true;
            const surface = live.tabs.items[index].focusedSurface() orelse return true;
            if (surface.core_initialized) switch (@as(usize, @intCast(cmd))) {
                c.CTX_TAB_RENAME => {
                    runUiActionOrLog("tab context rename failed", surface.promptTitle(.tab));
                },
                c.CTX_TAB_CLOSE => {
                    if (tabCloseAction(live.tabs.items.len) == .close_window) {
                        live.close();
                        return true;
                    }
                    _ = live.app.closeTab(.{ .surface = surface.core() }, .this) catch |err| {
                        log.warn("close_tab action failed err={}", .{err});
                    };
                },
                c.CTX_TAB_CLOSE_OTHERS => {
                    _ = live.app.closeTab(.{ .surface = surface.core() }, .other) catch |err| {
                        log.warn("close_tab other action failed err={}", .{err});
                    };
                },
                c.CTX_TAB_MOVE_LEFT => {
                    runUiActionOrLog("tab context move left failed", live.app.moveTab(.{ .surface = surface.core() }, .{ .amount = -1 }));
                },
                c.CTX_TAB_MOVE_RIGHT => {
                    runUiActionOrLog("tab context move right failed", live.app.moveTab(.{ .surface = surface.core() }, .{ .amount = 1 }));
                },
                else => {},
            };
        }
        // Escape, a move or a close leaves focus on the terminal the
        // activation put it on, and the next arrow press would go to the
        // PTY. Rename and a close that asks first opened an overlay, which
        // owns the keyboard now.
        live = app.registry.findHostById(host_id) orelse return true;
        if (live.hwnd != null and labels.tabContextMenuRestoresStripFocus(origin == .keyboard, live.overlay_mode != .none)) {
            live.restoreTabStripFocus();
        }
        return true;
    }

    /// The stops of the tab strip in Tab order: each tab, then [+], then [v].
    fn tabStripStopHwnd(self: *const Host, stop: usize) ?HWND {
        if (stop < self.tabs.items.len) return focusableHwnd(self.tabs.items[stop].button_hwnd);
        if (stop == self.tabs.items.len) return focusableHwnd(self.new_tab_hwnd);
        if (stop == self.tabs.items.len + 1) return focusableHwnd(self.overflow_hwnd);
        return null;
    }

    fn tabStripStopAvailable(self: *const Host, stop: usize) bool {
        return self.tabStripStopHwnd(stop) != null;
    }

    fn tabStripStopOf(self: *const Host, button: HWND) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.button_hwnd == button) return i;
        }
        if (self.new_tab_hwnd == button) return self.tabs.items.len;
        if (self.overflow_hwnd == button) return self.tabs.items.len + 1;
        return null;
    }

    fn isTabStripActionButton(self: *const Host, button: HWND) bool {
        return self.new_tab_hwnd == button or self.overflow_hwnd == button;
    }

    /// Move keyboard focus one stop along the tab strip (each visible tab,
    /// then [+] and [v], wrapping), from `from`. Focus only moves: Enter and
    /// the arrow keys still activate. Each landing HWND raises its own UIA
    /// focus event from `WM_SETFOCUS`.
    pub fn stepTabStripFocus(self: *Host, from: HWND, reverse: bool) bool {
        const current = self.tabStripStopOf(from) orelse return false;
        const next = labels.nextFocusStop(
            self.tabs.items.len + 2,
            current,
            reverse,
            @as(*const Host, self),
            tabStripStopAvailable,
        ) orelse return false;
        const target = self.tabStripStopHwnd(next) orelse return false;
        _ = sys.SetFocus(target);
        return sys.GetFocus() == target;
    }

    /// Move keyboard focus one stop along the docked search bar of `surface`
    /// (query, previous, next, regex, case, word, close), skipping hidden
    /// controls and wrapping, from `from`.
    pub fn stepSearchFocus(self: *Host, surface: *Surface, from: HWND, reverse: bool) bool {
        _ = self;
        const current = if (surface.search_bar_edit_hwnd != null and surface.search_bar_edit_hwnd.? == from)
            0
        else if (surface.searchBarButtonRole(from)) |role|
            labels.searchFocusStopOfRole(role)
        else
            return false;
        const next = labels.nextFocusStop(
            labels.search_focus_stop_count,
            current,
            reverse,
            @as(*const Surface, surface),
            searchFocusStopAvailable,
        ) orelse return false;
        const target = searchFocusStopHwnd(surface, next) orelse return false;
        _ = sys.SetFocus(target);
        return sys.GetFocus() == target;
    }

    /// Enter and Tab on a tab-strip action button or a docked search button;
    /// the BUTTON class takes Space itself, on the key-up. Enter has to be
    /// made a click here: it reaches a button only through a dialog manager,
    /// and the host has none. Touch nothing after a click: it can open a
    /// menu, or close the search bar.
    pub fn handleChromeButtonKey(self: *Host, button: HWND, vk: WPARAM, mods: labels.KeyMods, lParam: LPARAM) bool {
        const search_surface = if (self.searchControlSurface(button)) |surface|
            if (surface.searchBarButtonRole(button) != null) surface else null
        else
            null;
        const in_strip = self.isTabStripActionButton(button);
        if (!in_strip and search_surface == null) return false;
        const action = labels.chromeButtonKeyAction(vk, mods) orelse return false;
        switch (action) {
            .click => {
                if ((lParamBits(lParam) & c.KF_REPEAT) != 0) return true;
                const parent = sys.GetParent(button) orelse return false;
                const id = sys.GetDlgCtrlID(button);
                if (id <= 0) return false;
                // BM_CLICK simulates mouse messages, which hide keyboard
                // focus cues and dismiss tooltips. Send its notification
                // directly, and touch nothing after the action runs.
                _ = sys.SendMessageW(parent, c.WM_COMMAND, @as(WPARAM, @intCast(id)) | (@as(WPARAM, c.BN_CLICKED) << 16), @intCast(@intFromPtr(button)));
            },
            .focus_next, .focus_previous => {
                const reverse = action == .focus_previous;
                if (search_surface) |surface| {
                    _ = self.stepSearchFocus(surface, button, reverse);
                } else {
                    _ = self.stepTabStripFocus(button, reverse);
                }
            },
        }
        return true;
    }

    pub fn showOverflowMenu(self: *Host) void {
        const alloc = self.app.core_app.alloc;
        const hwnd = self.hwnd orelse return;
        const button = self.overflow_hwnd orelse return;

        // The menu lists what is loaded; with nothing yet, the discovery
        // worker fills it for the next opening.
        _ = self.profilesForChrome();

        // Position menu below the dropdown chevron button
        var rect: RECT = undefined;
        if (sys.GetWindowRect(button, &rect) == 0) return;

        const menu = sys.CreatePopupMenu() orelse return;
        defer _ = sys.DestroyMenu(menu);

        // Profile list — each profile gets a numbered shortcut hint
        const selected_idx = self.selectedProfileIndex();
        if (self.shownProfiles()) |profiles| {
            for (profiles, 0..) |*profile, i| {
                const label_utf8 = buildDropdownProfileLabel(alloc, profile, i) catch continue;
                defer alloc.free(label_utf8);
                const label_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, label_utf8) catch continue;
                defer alloc.free(label_w);
                const is_selected = selected_idx != null and selected_idx.? == i;
                const flags: UINT = if (is_selected) c.MF_STRING | c.MF_CHECKED else c.MF_STRING;
                _ = sys.AppendMenuW(menu, flags, c.CTX_PROFILE_BASE + i, label_w.ptr);
            }
            if (profiles.len > 0) _ = sys.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        }

        // Utility items
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("Open a new tab"));
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_NEW_WINDOW, std.unicode.utf8ToUtf16LeStringLiteral("New Window"));
        _ = sys.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_COMMAND_PALETTE, std.unicode.utf8ToUtf16LeStringLiteral("Command Palette\tCtrl+Shift+P"));
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_FIND, std.unicode.utf8ToUtf16LeStringLiteral("Find...\tCtrl+Shift+F"));
        _ = sys.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
        _ = sys.AppendMenuW(menu, c.MF_STRING, c.CTX_INSPECTOR, std.unicode.utf8ToUtf16LeStringLiteral("Toggle Inspector"));

        _ = sys.SetForegroundWindow(hwnd);
        const cmd = sys.TrackPopupMenu(menu, c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON | c.TPM_LEFTALIGN | c.TPM_TOPALIGN, rect.left, rect.bottom, 0, hwnd, null);
        _ = sys.PostMessageW(hwnd, c.WM_NULL, 0, 0);

        // Guard: host may have been destroyed during the modal menu loop
        if (self.hwnd == null) return;
        // The BUTTON class takes focus on the click that opened the menu,
        // and nothing gives it back when the menu closes without a
        // command: the next keystroke went to the chevron, not the shell.
        // A chosen command moves focus itself (new tab, palette, find), so
        // only the dismissed case needs the terminal restored, and only
        // when the pointer opened the menu. A keyboard user who reached
        // the chevron with Ctrl+F6 and opened it with Space expects Escape to
        // put them back on the chevron, as every menu does.
        if (cmd <= 0 and self.focus_input_mode == .pointer and sys.GetFocus() == button) {
            refocusHostAfterActivation(self);
        }
        self.handleOverflowMenuCommand(cmd);
    }

    fn handleOverflowMenuCommand(self: *Host, cmd: BOOL) void {
        if (cmd <= 0) return;
        const cmd_id = @as(usize, @intCast(cmd));

        // Profile item dispatch — open the selected profile in a new tab
        if (cmd_id >= c.CTX_PROFILE_BASE and cmd_id < c.CTX_PROFILE_BASE + 100) {
            const profile_index = cmd_id - c.CTX_PROFILE_BASE;
            // Validate index against current profiles (may have changed during modal menu)
            if (self.shownProfiles()) |profiles| {
                if (profile_index < profiles.len) {
                    _ = self.quickOpenProfileIndex(profile_index, .tab);
                }
            }
            return;
        }

        const surface = self.activeSurface() orelse return;
        if (!surface.core_initialized) return;

        switch (cmd_id) {
            c.CTX_COMMAND_PALETTE => {
                runUiActionOrLog("overflow command palette failed", surface.toggleCommandPalette());
            },
            c.CTX_FIND => {
                runUiActionOrLog("overflow find failed", surface.showSearchOverlay(""));
            },
            c.CTX_NEW_TAB => {
                self.postDeferredNewTab();
            },
            c.CTX_NEW_WINDOW => {
                runUiActionOrLog("overflow new window failed", self.app.performAction(.{ .surface = surface.core() }, .new_window, .{}));
            },
            c.CTX_INSPECTOR => {
                runUiActionOrLog("overflow inspector toggle failed", self.app.toggleInspectorForSurface(surface));
            },
            else => {},
        }
    }

    pub const isOverlayButton = overlay_session.HostControls.isOverlayButton;

    pub const overlayFocusSlot = overlay_session.HostControls.overlayFocusSlot;

    pub const focusRelativeOverlayControl = overlay_session.HostControls.focusRelativeOverlayControl;

    /// Which focus regions of this host can take keyboard focus right
    /// now. Availability is read from live window visibility, so the
    /// cycle never lands on a region the user cannot see — a closed
    /// docked search and an absent banner are simply skipped.
    fn focusRegionAvailability(self: *const Host) focus_region.Availability {
        const terminal_available = if (self.activeSurface()) |surface| surface.hwnd != null else false;
        return .{
            .terminal = terminal_available,
            .tab_strip = self.tabStripFocusHwnd() != null,
            .search = self.searchFocusHwnd() != null,
            .banner = self.bannerFocusHwnd() != null,
        };
    }

    /// The tab-strip HWND that takes focus: the active tab's button when
    /// it is on screen, otherwise the first visible tab button, otherwise
    /// the new-tab button. Tabs scrolled out of the strip by overflow have
    /// hidden buttons and cannot be focus targets.
    pub fn tabStripFocusHwnd(self: *const Host) ?HWND {
        if (self.active_tab < self.tabs.items.len) {
            if (focusableHwnd(self.tabs.items[self.active_tab].button_hwnd)) |hwnd| return hwnd;
        }
        for (self.tabs.items) |tab| {
            if (focusableHwnd(tab.button_hwnd)) |hwnd| return hwnd;
        }
        return focusableHwnd(self.new_tab_hwnd);
    }

    fn searchFocusHwnd(self: *const Host) ?HWND {
        const surface = self.activeSurface() orelse return null;
        return focusableHwnd(surface.search_bar_edit_hwnd);
    }

    fn focusRegionHwnd(self: *const Host, region: focus_region.Region) ?HWND {
        return switch (region) {
            .terminal => if (self.activeSurface()) |surface| surface.hwnd else null,
            .tab_strip => self.tabStripFocusHwnd(),
            .search => self.searchFocusHwnd(),
            .banner => self.bannerFocusHwnd(),
        };
    }

    /// The region a focused HWND belongs to, or null when focus is
    /// somewhere this cycle does not own (an overlay, the palette, a
    /// settings window). The tab-strip action buttons count as the tab
    /// strip so Ctrl+F6 from them continues the cycle instead of dead-ending.
    fn focusRegionForHwnd(self: *Host, child: HWND) ?focus_region.Region {
        for (self.app.registry.windows.items) |surface| {
            if (surface.host != self) continue;
            if (surface.hwnd) |surface_hwnd| {
                if (surface_hwnd == child) return .terminal;
            }
        }
        if (self.tabIndexForButton(child) != null) return .tab_strip;
        if (self.new_tab_hwnd) |hwnd| if (hwnd == child) return .tab_strip;
        if (self.overflow_hwnd) |hwnd| if (hwnd == child) return .tab_strip;
        if (self.bannerButtonOf(child) != null) return .banner;
        if (self.searchControlSurface(child) != null) return .search;
        return null;
    }

    /// Move real Win32 focus onto a region. Real focus is the point: each
    /// landing HWND raises its own UIA focus-changed event from
    /// `WM_SETFOCUS`, so a screen reader announces what focus landed on.
    fn moveFocusToRegion(self: *Host, region: focus_region.Region) bool {
        const target = self.focusRegionHwnd(region) orelse return false;
        if (sys.GetFocus() == target) return true;
        _ = sys.SetFocus(target);
        return sys.GetFocus() == target;
    }

    fn cycleFocusRegion(
        self: *Host,
        direction: focus_region.Direction,
        current: ?focus_region.Region,
    ) bool {
        const target = focus_region.next(
            self.focusRegionAvailability(),
            current,
            direction,
        ) orelse return false;
        return self.moveFocusToRegion(target);
    }

    /// Entry point for the `cycle_focus_region` keybind action, which only
    /// reaches us while the terminal owns focus. The current region is
    /// resolved from live focus rather than assumed, so a binding invoked
    /// through automation while chrome holds focus still moves correctly.
    pub fn cycleFocusRegionFromCurrentFocus(self: *Host, direction: focus_region.Direction) bool {
        // This is the keybind path (Ctrl+F6 from the terminal). The key never
        // reaches a chrome control's own WM_KEYDOWN, but the control it
        // lands on is being reached by keyboard and must show its ring.
        self.focus_input_mode = .keyboard;
        const current = if (sys.GetFocus()) |hwnd| self.focusRegionForHwnd(hwnd) else null;
        return self.cycleFocusRegion(direction, current);
    }

    /// Ctrl+F6 / Ctrl+Shift+F6 and Escape while a chrome region holds focus.
    ///
    /// Chrome controls are native HWNDs that never reach the core keybind
    /// path, so these keys are fixed here rather than rebindable; the
    /// terminal end of the cycle goes through the `cycle_focus_region`
    /// keybind action instead. `allow_escape` is false where the control
    /// already owns Escape (the docked search dismisses itself).
    pub fn handleFocusRegionKey(self: *Host, child: HWND, vk: WPARAM, allow_escape: bool) bool {
        const current = self.focusRegionForHwnd(child) orelse return false;
        switch (vk) {
            c.VK_F6 => {
                const direction = focus_region.chordDirection(
                    keyPressed(c.VK_CONTROL),
                    keyPressed(c.VK_SHIFT),
                ) orelse return false;
                return self.cycleFocusRegion(direction, current);
            },
            c.VK_ESCAPE => {
                if (!allow_escape) return false;
                const target = focus_region.escapeTarget(
                    self.focusRegionAvailability(),
                    current,
                ) orelse return false;
                return self.moveFocusToRegion(target);
            },
            else => return false,
        }
    }

    /// Put focus back on the tab strip after an activation moved it to the
    /// newly active terminal. Without this, one Left/Right press would
    /// leave the strip and the next one would go to the PTY.
    pub fn restoreTabStripFocus(self: *Host) void {
        _ = self.moveFocusToRegion(.tab_strip);
    }

    pub fn searchControlSurface(self: *const Host, child: HWND) ?*Surface {
        for (self.app.registry.windows.items) |surface| {
            if (surface.host != self) continue;
            if (surface.ownsSearchBarControl(child)) return surface;
        }
        return null;
    }

    pub fn searchBarBackgroundSurface(self: *const Host, child: HWND) ?*Surface {
        for (self.app.registry.windows.items) |surface| {
            if (surface.host != self) continue;
            if (surface.search_bar_bg_hwnd != null and child == surface.search_bar_bg_hwnd.?) {
                return surface;
            }
        }
        return null;
    }

    pub const isSearchBarButton = search_controls.HostControls.isSearchBarButton;

    pub const isSearchBarResultsLabel = search_controls.HostControls.isSearchBarResultsLabel;

    pub fn chromeUiaProviderForHwnd(self: *Host, child: HWND) ?*win32_uia.ChromeControlProvider {
        if (self.new_tab_hwnd == child) return self.new_tab_uia_provider;
        if (self.overflow_hwnd == child) return self.overflow_uia_provider;
        if (self.bannerButtonOf(child)) |button| return self.banner_button_uia_providers[@intFromEnum(button)];
        const surface = self.searchControlSurface(child) orelse return null;
        const role = surface.searchBarButtonRole(child) orelse return null;
        return surface.search_bar_button_uia_providers[@intFromEnum(role)];
    }

    pub const searchBarButtonRole = search_controls.HostControls.searchBarButtonRole;

    const searchBarButtonIcon = search_controls.HostControls.searchBarButtonIcon;

    pub const searchBarButtonColors = search_controls.HostControls.searchBarButtonColors;

    pub const drawSearchBarBackground = search_controls.HostControls.drawSearchBarBackground;

    const drawSearchBarButton = search_controls.HostControls.drawSearchBarButton;

    pub const drawSearchButtonGlyph = search_controls.HostControls.drawSearchButtonGlyph;

    pub fn isOverlayStyledButton(self: *const Host, child: HWND) bool {
        return self.isOverlayButton(child) or self.isSearchBarButton(child);
    }

    pub fn isActiveChromeButton(self: *Host, child: HWND) bool {
        if (self.isActiveTabButton(child)) return true;
        const surface = self.searchControlSurface(child) orelse return false;
        const role = surface.searchBarButtonRole(child) orelse return false;
        return surface.searchBarButtonActive(role);
    }

    fn drawTitlebarActionButton(
        self: *Host,
        draw: *const DRAWITEMSTRUCT,
        role: TitlebarButtonRole,
        disabled: bool,
        pressed: bool,
        focused: bool,
        hovered: bool,
    ) void {
        const titlebar_theme = clientTitlebarTheme(
            &self.app.resolved_theme,
            self.app.shownConfig(),
            self.usingIntegratedTitlebar(),
            isHighContrastActive(),
        );
        const theme = &titlebar_theme;
        const parent_bg = theme.chrome_bg;
        const is_hc = isHighContrastActive();
        fillSolidRect(draw.hDC, draw.rcItem, parent_bg);

        var visual = titlebarButtonVisual(
            theme,
            role,
            parent_bg,
            self.titlebarHoverAlpha(role, hovered, sys.GetTickCount64()),
            pressed,
            is_hc,
            self.window_active,
        );
        if (disabled) {
            visual = .{ .bg = null, .glyph = theme.text_disabled };
        }

        if (visual.bg) |bg| {
            drawRoundedRect(draw.hDC, draw.rcItem, bg, bg, self.scaled(4));
        }
        if (self.chromeFocusRingVisible(focused, disabled)) {
            drawRoundedRect(
                draw.hDC,
                rectInset(draw.rcItem, self.scaled(2), self.scaled(2)),
                visual.bg orelse parent_bg,
                theme.button_focus_ring,
                self.scaled(3),
            );
        }

        const glyph: TitlebarGlyphKind = switch (role) {
            .new_tab => .new_tab,
            .dropdown => .dropdown,
            else => return,
        };
        self.drawTitlebarGlyph(draw.hDC, draw.rcItem, glyph, visual.glyph, false);
    }

    pub fn drawButton(self: *Host, draw: *const DRAWITEMSTRUCT) void {
        if (draw.CtlType != c.ODT_BUTTON) return;
        self.ensureThemeBrushes() catch return;
        if (self.chrome_font) |font| _ = sys.SelectObject(draw.hDC, font);

        const is_hc = isHighContrastActive();
        const disabled = (draw.itemState & c.ODS_DISABLED) != 0;
        const pressed = (draw.itemState & c.ODS_SELECTED) != 0;
        const focused = (draw.itemState & c.ODS_FOCUS) != 0 or sys.GetFocus() == draw.hwndItem;
        const active = self.isActiveChromeButton(draw.hwndItem);
        const overlay = self.isOverlayStyledButton(draw.hwndItem);
        const hovered = self.isHoveredButton(draw.hwndItem);
        const accept = draw.hwndItem == self.overlay_accept_hwnd;
        const profile_kind = self.buttonProfileKind(draw.hwndItem);
        const pinned_slot_ordinal = self.buttonPinnedSlotOrdinal(draw.hwndItem);
        const launcher_target = self.buttonLauncherTarget(draw.hwndItem);
        const tab_button = self.isTabButton(draw.hwndItem);
        const search_role = self.searchBarButtonRole(draw.hwndItem);
        const icon = self.searchBarButtonIcon(draw.hwndItem);
        const titlebar_theme = clientTitlebarTheme(
            &self.app.resolved_theme,
            self.app.shownConfig(),
            tab_button and self.usingIntegratedTitlebar(),
            is_hc,
        );
        const theme = &titlebar_theme;
        if (search_role) |role| {
            self.drawSearchBarButton(
                draw,
                role,
                icon.?,
                disabled,
                pressed,
                focused,
                hovered,
                active,
            );
            return;
        }
        const titlebar_role = self.titlebarActionButtonRole(draw.hwndItem);
        if (titlebar_role != .none) {
            self.drawTitlebarActionButton(
                draw,
                titlebar_role,
                disabled,
                pressed,
                focused,
                hovered,
            );
            return;
        }
        var colors = buttonColorsFromTheme(
            theme,
            active,
            overlay,
            hovered,
            pressed,
            disabled,
            accept,
            is_hc,
        );
        if (!is_hc) if (profile_kind) |kind| {
            colors = applyProfileChromeAccent(colors, kind, theme.is_dark, active, hovered, pressed, disabled);
        };
        // The active tab takes its terminal's background and runs on into
        // it through the band (`activeTabJoin`): no border, square lower
        // corners, and its label, badge and focus ring in colors readable
        // on that background. High Contrast keeps the system highlight.
        const tab_background: ?u32 = if (tab_button and active and !disabled)
            if (self.tabIndexForButton(draw.hwndItem)) |index| tabBackground(&self.tabs.items[index]) else null
        else
            null;
        const tab_theme_value = if (tab_background) |background| activeTabTheme(theme, background) else theme.*;
        const tab_theme = &tab_theme_value;
        if (tab_button and !disabled and !is_hc) {
            colors.fg = if (active or hovered) tab_theme.text_primary else theme.button_chrome_fg;
            if (active) {
                colors.bg = tab_background orelse if (theme.is_dark)
                    adjustColor(theme.chrome_bg, 18, 18, 22)
                else
                    adjustColor(theme.chrome_bg, 12, 12, 12);
                colors.border = colors.bg;
            } else if (hovered) {
                colors.bg = if (theme.is_dark)
                    adjustColor(theme.chrome_bg, 10, 10, 12)
                else
                    adjustColor(theme.chrome_bg, 7, 7, 7);
                colors.border = if (theme.is_dark)
                    adjustColor(theme.chrome_border, 20, 20, 22)
                else
                    adjustColor(theme.chrome_border, -22, -22, -22);
            } else {
                colors.bg = if (theme.is_dark)
                    adjustColor(theme.chrome_bg, 4, 4, 6)
                else
                    adjustColor(theme.chrome_bg, 3, 3, 3);
                colors.border = if (theme.is_dark)
                    adjustColor(theme.chrome_border, 8, 8, 10)
                else
                    adjustColor(theme.chrome_border, -14, -14, -14);
            }
        }
        if (tab_button and !disabled) colors.fg = win32_theme.windowChromeTextColor(tab_theme, colors.fg, self.window_active, is_hc);
        const bg = colors.bg;
        const border = colors.border;
        const fg = colors.fg;

        const content_top_inset = if (tab_button) self.tabContentTopInset() else 0;
        // Erase with parent background, then draw rounded button
        const parent_bg = if (overlay) theme.overlay_bg else theme.chrome_bg;
        fillSolidRect(draw.hDC, draw.rcItem, parent_bg);
        if (tab_button) {
            gdi.drawTabButton(draw.hDC, draw.rcItem, bg, border, self.scaled(4), self.tabsFlushWithTop());
            // Square lower corners and the last row, which the rounded
            // rectangle's inset leaves to the parent color, so the tab meets
            // the join below it without a notch.
            if (tab_background != null) fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.left + 1,
                .top = @max(draw.rcItem.top, draw.rcItem.bottom - 1 - self.scaled(4)),
                .right = draw.rcItem.right - 1,
                .bottom = draw.rcItem.bottom,
            }, bg);
        } else {
            drawRoundedRect(draw.hDC, draw.rcItem, bg, border, self.scaled(4));
        }
        if (tab_button and !overlay and !disabled and hovered and !active) {
            fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.left + self.scaled(5),
                .top = draw.rcItem.top + content_top_inset + self.scaled(3),
                .right = draw.rcItem.right - self.scaled(5),
                .bottom = draw.rcItem.top + content_top_inset + self.scaled(5),
            }, border);
        }
        // An overlay button is the default button of a modal prompt: focus
        // lands on Allow programmatically and Enter presses whatever holds
        // it, so the ring is the only thing that says what Enter will do.
        // Native dialogs keep their default button visibly marked under
        // `UISF_HIDEFOCUS` for the same reason; the pointer gate applies
        // to the tab strip and the search bar, not here.
        const ring_visible = if (overlay)
            focused and !disabled
        else
            self.chromeFocusRingVisible(focused, disabled);
        if (ring_visible) {
            const focus = if (profile_kind) |kind|
                profileKindFocusRingColor(kind, theme.is_dark)
            else if (accept)
                theme.button_accept_focus_ring
            else if (active)
                tab_theme.button_active_focus_ring
            else if (overlay)
                theme.button_overlay_focus_ring
            else
                theme.button_focus_ring;
            // Rounded focus ring inset inside the button, matching corner radius
            const inset_rect = RECT{
                .left = draw.rcItem.left + self.scaled(2),
                .top = draw.rcItem.top + content_top_inset + self.scaled(2),
                .right = draw.rcItem.right - self.scaled(2),
                .bottom = draw.rcItem.bottom - self.scaled(2),
            };
            gdi.drawRoundedOutline(draw.hDC, inset_rect, focus, self.scaled(3));
        }

        if (profile_kind) |kind| {
            const stripe = profileChromeStripeColor(kind, theme.is_dark, active, hovered, pressed, disabled);
            // Inset stripe to fit inside rounded corners
            const corner_inset = self.scaled(4);
            fillSolidRect(draw.hDC, .{
                .left = draw.rcItem.left + 2,
                .top = draw.rcItem.top + corner_inset,
                .right = draw.rcItem.left + self.scaled(4),
                .bottom = draw.rcItem.bottom - corner_inset,
            }, stripe);
            if (pinnedSlotBadgeDigit(pinned_slot_ordinal)) |digit| {
                paintPinnedSlotBadge(
                    draw.hDC,
                    draw.rcItem,
                    digit,
                    colors.border,
                    colors.bg,
                    profileKindLabelColor(kind, theme.is_dark),
                    self.current_dpi,
                );
            }
            if (launcher_target) |target| {
                paintTargetButtonBadge(
                    draw.hDC,
                    draw.rcItem,
                    profileOpenTargetBadgeGlyph(target),
                    colors.border,
                    colors.bg,
                    profileOpenTargetMarkerColor(target),
                    self.current_dpi,
                );
            }
        }
        // Per-tab close button: reserve space and determine if close zone is active
        const can_close_tab = tab_button and !overlay and tabCloseAction(self.tabs.items.len) != .none;
        const close_zone_width = if (can_close_tab) self.scaled(host_tab_close_zone_width) else 0;

        var text_buf: [160]u16 = undefined;
        const text_len = sys.GetWindowTextW(draw.hwndItem, &text_buf, text_buf.len);
        _ = sys.SetBkMode(draw.hDC, c.TRANSPARENT);
        _ = sys.SetTextColor(draw.hDC, fg);
        var text_rect = draw.rcItem;
        text_rect.top += content_top_inset;
        if (!overlay) {
            text_rect.left += self.scaled(6);
            text_rect.right -= self.scaled(6);
        }
        if (profile_kind != null) {
            text_rect.left += self.scaled(4);
        }
        text_rect.right -= buttonLabelRightInset(pinned_slot_ordinal, launcher_target);
        text_rect.right -= close_zone_width; // leave room for per-tab close X
        if (icon) |kind| {
            win32_icons.drawIcon(
                kind,
                draw.hDC.?,
                .{
                    .left = text_rect.left,
                    .top = text_rect.top,
                    .right = text_rect.right,
                    .bottom = text_rect.bottom,
                },
                fg,
                isHighContrastActive(),
            );
        } else {
            if (tab_button and !overlay) {
                if (self.tabIndexForButton(draw.hwndItem)) |index| {
                    const status = self.tabs.items[index].status_indicator;
                    self.drawTabStatusBadge(draw.hDC, &text_rect, @ptrCast(&text_buf), text_len, status, tab_theme, fg, bg);
                }
            }
            _ = sys.DrawTextW(
                draw.hDC,
                @ptrCast(&text_buf),
                text_len,
                &text_rect,
                c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX | c.DT_END_ELLIPSIS,
            );
        }

        // Per-tab close X glyph. Active tabs keep the X fully opaque
        // (it's a permanent affordance the user can always click).
        // Inactive tabs fade the X in/out based on hover via
        // `win32_tab_visual.CloseState` — matches Windows Terminal's
        // hover treatment. On non-hovered + non-active tabs the alpha
        // drops to 0 so the X vanishes entirely.
        if (can_close_tab) {
            const now = sys.GetTickCount64();
            // Two animation slots: the incoming hover target
            // (`tab_close_hover_*` fades 0 → 1) and the departing tab
            // on adjacent transitions (`tab_close_prev_*` fades
            // 1 → 0). Tabs that match neither slot use alpha 0 for
            // idle and 1 for active.
            const is_hover_target = self.tab_close_hover_hwnd != null and
                self.tab_close_hover_hwnd.? == draw.hwndItem;
            const is_prev_target = self.tab_close_prev_hwnd != null and
                self.tab_close_prev_hwnd.? == draw.hwndItem;
            const alpha: f32 = if (active)
                1.0
            else if (is_hover_target)
                self.tab_close_hover.alphaAt(now)
            else if (is_prev_target)
                self.tab_close_prev.alphaAt(now)
            else if (hovered)
                1.0 // hovered but not via CloseState (e.g. first paint)
            else
                0.0;
            if (alpha > 0.01) {
                const close_glyph = comptime std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"); // ×
                const close_fg_full = colors.fg;
                // Alpha-blend the glyph colour against the tab bg —
                // GDI's DrawTextW has no alpha channel, so we
                // pre-composite.
                const blended = blendColorRGB(bg, close_fg_full, alpha);
                _ = sys.SetTextColor(draw.hDC, blended);
                var close_rect = RECT{
                    .left = draw.rcItem.right - close_zone_width,
                    .top = text_rect.top,
                    .right = draw.rcItem.right - self.scaled(2),
                    .bottom = draw.rcItem.bottom,
                };
                _ = sys.DrawTextW(
                    draw.hDC,
                    close_glyph,
                    1,
                    &close_rect,
                    c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX,
                );
            }
        }
    }

    /// Draw a tab's program status badge (OSC 7501) before its label, and
    /// narrow `text_rect` to where the label goes, so the badge and the
    /// label are centered together the way the label alone is.
    fn drawTabStatusBadge(
        self: *Host,
        hdc: HDC,
        text_rect: *RECT,
        text: [*:0]const u16,
        text_len: i32,
        status: win32_program_status.Indicator,
        theme: *const ThemeColors,
        fg: u32,
        bg: u32,
    ) void {
        const badge: gdi.StatusBadge = switch (status) {
            .none => return,
            .working => |progress| .{ .ring = progress },
            .blocked => .disc,
            .done => .check,
            .failed => .cross,
        };
        const size = self.scaled(tab_status_badge_size);
        const slot = self.scaled(tab_status_badge_slot);
        var measure: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = sys.DrawTextW(
            hdc,
            text,
            text_len,
            &measure,
            c.DT_CALCRECT | c.DT_SINGLELINE | c.DT_NOPREFIX,
        );
        const room = text_rect.right - text_rect.left;
        const group = @min(room, slot + (measure.right - measure.left));
        const left = text_rect.left + @divTrunc(room - group, 2);
        const top = @divTrunc(text_rect.top + text_rect.bottom - size, 2);
        // High contrast draws every badge in the text color; the shapes
        // still tell the states apart.
        const high_contrast = isHighContrastActive();
        const color = if (high_contrast) fg else tabStatusBadgeColor(status, theme, bg);
        gdi.drawStatusBadge(
            hdc,
            .{ .left = left, .top = top, .right = left + size, .bottom = top + size },
            badge,
            color,
            bg,
            @max(2, self.scaled(2)),
            high_contrast,
        );
        text_rect.left = left + slot;
        text_rect.right = left + group;
    }

    fn buttonProfileKind(self: *Host, hwnd: HWND) ?windows_shell.ProfileKind {
        const profile = self.selectedProfile() orelse return null;
        if (self.overlay_mode == .profile and self.overlay_accept_hwnd != null and hwnd == self.overlay_accept_hwnd.?) {
            return profile.kind;
        }
        return null;
    }

    fn buttonPinnedSlotOrdinal(self: *Host, hwnd: HWND) ?usize {
        const profile = self.selectedProfile() orelse return null;
        if (self.overlay_mode == .profile and self.overlay_accept_hwnd != null and hwnd == self.overlay_accept_hwnd.?) {
            return self.app.launcherQuickSlotOrdinal(profile.key);
        }
        return null;
    }

    fn buttonLauncherTarget(self: *Host, hwnd: HWND) ?ProfileOpenTarget {
        if (self.overlay_mode == .profile and self.overlay_accept_hwnd != null and hwnd == self.overlay_accept_hwnd.?) {
            return self.app.launcher_profile_target;
        }
        return null;
    }

    pub const syncOverlayCompletionState = palette_controller.HostControls.syncOverlayCompletionState;

    pub const completeCommandPalette = palette_controller.HostControls.completeCommandPalette;

    pub const richPaletteCompletionCandidate = palette_controller.HostControls.richPaletteCompletionCandidate;

    pub fn stepTabOverviewSelection(self: *Host, reverse: bool) !bool {
        if (self.overlay_mode != .tab_overview) return false;
        const edit_hwnd = self.overlay_edit_hwnd orelse return false;
        const total = self.tabs.items.len;
        if (total == 0) return false;

        const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");

        const current: usize = std.fmt.parseUnsigned(usize, text, 10) catch self.active_tab + 1;
        const next = nextTabOverviewSelection(current, total, reverse);
        const next_text = try std.fmt.allocPrint(self.app.core_app.alloc, "{d}", .{next});
        defer self.app.core_app.alloc.free(next_text);
        _ = try self.setOverlayEditText(next_text);
        _ = sys.SendMessageW(edit_hwnd, c.EM_SETSEL, 0, -1);
        _ = try self.syncOverlayLabel();
        _ = try self.syncOverlayHint();
        _ = try self.syncOverlayButtons();
        return true;
    }

    pub const syncCommandPaletteBanner = palette_controller.HostControls.syncCommandPaletteBanner;

    pub fn submitOverlay(self: *Host) !bool {
        _ = self.overlay_edit_hwnd orelse return false;
        const text = std.mem.trim(u8, try overlayEditText(self), " \t\r\n");
        // Confirm prompts must NOT take this path: their query EDIT is
        // hidden and always empty, so dismissing on "empty" would close
        // the prompt without dispatching accept or cancel. Reachable
        // since the preview pane joined the focus cycle and routes Enter
        // through `submitOverlay`.
        if (text.len == 0 and overlayEmptySubmitDismisses(self.overlay_mode)) {
            self.hideOverlay();
            try self.layout();
            return false;
        }

        const surface = self.activeSurface() orelse return false;
        switch (self.overlay_mode) {
            .none => return false,
            .command_palette => {
                // Prefer the currently-selected list row (what the user
                // sees highlighted). Fall back to parsing the raw query
                // so users who type a full action name and press Enter
                // before the list rebuild completes still get dispatch.
                if (self.palette_list_ranked_count > 0 and self.palette_list_visible_rows > 0) {
                    const row = @min(
                        self.palette_list_selected,
                        self.palette_list_ranked_count - 1,
                    );
                    try self.invokePaletteRow(row);
                    // Do NOT access `self` after dispatch.
                    return true;
                }
                if (self.palette_list_ranked_count > 0) {
                    self.abortPaletteAction("Make the window larger to show and activate palette results.");
                    return false;
                }
                const action = input.Binding.Action.parse(text) catch |err| {
                    log.warn("win32 command palette invalid action action={s} err={}", .{ text, err });
                    try self.setBanner(.err, labels.command_palette_unknown_action);
                    if (self.palette_list_uia_provider) |provider| {
                        win32_uia.events.raiseNotification(&provider.base, .action_aborted, "Unknown command");
                    }
                    return false;
                };
                self.app.pushPaletteMru(text) catch |err| {
                    std.log.warn("palette MRU push failed err={}", .{err});
                };
                self.hideOverlay();
                runUiActionOrLog("palette action layout failed", self.layout());
                if (action == .new_tab) {
                    self.postDeferredNewTab();
                    return true;
                }
                surface.noteProgramInput();
                _ = try surface.core_surface.performBindingAction(action);
                return true;
            },
            .profile => {
                return try self.submitProfileOverlay(self.app.launcher_profile_target);
            },
            .search => return false,
            .surface_title => {
                try surface.setTitleOverride(if (text.len == 0) null else text);
            },
            .tab_title => {
                try surface.setTabTitleOverride(if (text.len == 0) null else text);
            },
            .tab_overview => {
                const requested = std.fmt.parseUnsigned(usize, text, 10) catch |err| {
                    log.warn("win32 tab overview invalid selection value={s} err={}", .{ text, err });
                    try self.setBanner(.err, "Enter a numeric tab index.");
                    return false;
                };
                if (requested == 0 or requested > self.tabs.items.len) {
                    const message = try std.fmt.allocPrint(self.app.core_app.alloc, "Tab index out of range. Valid range: 1 to {d}.", .{self.tabs.items.len});
                    defer self.app.core_app.alloc.free(message);
                    try self.setBanner(.err, message);
                    return false;
                }
                _ = self.activateTabIndex(requested - 1);
            },
            .confirm => {
                // Enter maps to Accept.
                self.invokeConfirmAccept();
                return true;
            },
        }

        self.hideOverlay();
        try self.layout();
        try self.setBanner(.none, null);
        return true;
    }

    pub fn shouldShowTabBar(self: *const Host) bool {
        return tabBarVisibleForConfig(self.app.config.@"window-show-tab-bar");
    }

    fn decorationVisibilityForChrome(self: *const Host) bool {
        return decorationVisibilityForChromeValue(
            if (self.activeSurface()) |surface| surface.decorations_visible else null,
            self.cached_decorations_visible,
        );
    }

    /// Host-local view of the integrated-titlebar state. The app
    /// carries the build/config floor, but host-side non-client
    /// handling must also respect whether this host is actually
    /// reserving a visible caption/tab row.
    pub fn usingIntegratedTitlebar(self: *const Host) bool {
        return usesIntegratedTitlebar(
            self.app.use_integrated_titlebar,
            self.shouldShowTabBar(),
            self.decorationVisibilityForChrome(),
        );
    }

    /// Height (96 DPI) of the caption row this host keeps inside its client
    /// area, owning `WM_NCCALCSIZE` and `WM_NCHITTEST`, or null when Windows
    /// owns the non-client area. The integrated titlebar paints its row
    /// there; an undecorated window that keeps its frame has a 0 px row, so
    /// the hit test finds only resize edges and client.
    pub fn clientCaptionHeight(self: *const Host) ?i32 {
        if (self.usingIntegratedTitlebar()) return host_caption_button_h;
        const fullscreen = if (self.activeSurface()) |surface| surface.fullscreen else false;
        if (undecoratedKeepsFrame(self.app.os_build, self.quick_terminal) and
            !self.decorationVisibilityForChrome() and
            !fullscreen) return 0;
        return null;
    }

    /// Whether a `WM_NCHITTEST` point is on a resize edge of this host with
    /// a 0 px caption row. Its top band lies inside the client area, where
    /// a terminal pane with no tab bar above it covers the band.
    pub fn resizesFrom(self: *Host, lParam: LPARAM) bool {
        const ht = self.zeroCaptionHitTest(lParam) orelse return false;
        return ht >= c.HTLEFT and ht <= c.HTBOTTOMRIGHT;
    }

    /// `resizesFrom` for the top band and its corners only, which the
    /// tab-strip buttons begin inside. The side strips are measured from the
    /// window rect, scaled linearly, while the client starts at DWP's frame,
    /// which is narrower above 96 DPI (13 vs 16 px at 192), so a side strip
    /// overlaps a button's outer columns there; the button keeps those.
    pub fn resizesFromTop(self: *Host, lParam: LPARAM) bool {
        const ht = self.zeroCaptionHitTest(lParam) orelse return false;
        return ht == c.HTTOP or ht == c.HTTOPLEFT or ht == c.HTTOPRIGHT;
    }

    /// The host's `WM_NCHITTEST` answer at `lParam` when it has a 0 px
    /// caption row, else null.
    fn zeroCaptionHitTest(self: *Host, lParam: LPARAM) ?LRESULT {
        if ((self.clientCaptionHeight() orelse return null) != 0) return null;
        return self.handleNcHitTest(self.hwnd orelse return null, lParam);
    }

    pub fn tabBarHeight(self: *Host) i32 {
        if (!self.shouldShowTabBar()) return 0;
        // Win11 integrated titlebar: tab row is 40 px tall so it
        // matches the caption-button row height — gives the
        // "tabs-in-caption" look. On Win10 / build < 22000 we keep
        // the compact 32 px height since the DWM caption still sits
        // above.
        const base = if (self.usingIntegratedTitlebar())
            host_tab_height_integrated
        else
            host_tab_height;
        return self.scaled(base);
    }

    pub fn tabsFlushWithTop(self: *const Host) bool {
        const hwnd = self.hwnd orelse return false;
        const fullscreen = if (self.activeSurface()) |surface| surface.fullscreen else false;
        return self.app.os_build >= c.OS_BUILD_WIN11_21H2 and
            !self.quick_terminal and self.shouldShowTabBar() and
            (fullscreen or ((self.usingIntegratedTitlebar() or self.clientCaptionHeight() == 0) and
                sys.IsZoomed(hwnd) != 0));
    }

    /// Keep tab content and its close affordance below the newly added cap.
    pub fn tabContentTopInset(self: *const Host) i32 {
        return if (self.tabsFlushWithTop()) self.scaled(3) else 0;
    }

    pub fn contentBands(
        self: *const Host,
        tab_bottom: i32,
        overlay_height: i32,
        inspector_height: i32,
    ) win32_nc_layout.ContentBands {
        const caption_bottom = if (self.usingIntegratedTitlebar())
            self.ncMetrics().caption_button_h
        else
            0;
        return win32_nc_layout.contentBands(
            tab_bottom,
            caption_bottom,
            overlay_height,
            inspector_height,
        );
    }

    fn ncMetrics(self: *const Host) win32_nc_layout.Metrics {
        return win32_nc_layout.metricsDefault(
            self.current_dpi,
            host_caption_button_h,
        );
    }

    pub fn rightButtonsWidth(self: *const Host) i32 {
        if (self.usingIntegratedTitlebar()) {
            return self.scaled(host_titlebar_action_button_size) * 2 + self.scaled(12);
        }
        return self.scaled(host_tab_small_button_width) + // new tab (+)
            self.scaled(host_tab_overflow_button_width) + // dropdown chevron (▾)
            self.scaled(12); // gap + margins
    }

    /// Pixels reserved for the 3 caption buttons (min / max / close)
    /// when the integrated titlebar is active. Returns 0 otherwise.
    /// Buttons are painted by `paintChrome`; this reservation keeps
    /// the [+][▾] cluster and tab strip from colliding with them.
    fn captionButtonsWidth(self: *const Host) i32 {
        if (!self.usingIntegratedTitlebar()) return 0;
        return self.ncMetrics().caption_button_w * 3;
    }

    /// Client-space rects of the three painted caption buttons, flush
    /// against the top-right of the client area. Painting, the UIA
    /// bounding rectangles and `WM_NCHITTEST` all resolve through
    /// `win32_nc_layout.captionButtonsRect`, so a reader cannot be told
    /// about a rect that is neither painted nor clickable.
    /// Null when the integrated titlebar is off or the row has no area,
    /// which is also when UIA must not expose the buttons at all.
    pub fn captionButtonRects(self: *const Host, client_rect: RECT) ?CaptionButtonRects {
        if (!self.usingIntegratedTitlebar()) return null;
        // A collapsed client area (a minimized window reports one) has no
        // painted row, so there is no rect to hand out.
        if (client_rect.right <= client_rect.left or client_rect.bottom <= client_rect.top) return null;
        const metrics = self.ncMetrics();
        if (metrics.caption_button_w <= 0 or metrics.caption_button_h <= 0) return null;
        const rects = win32_nc_layout.captionButtonsRect(win32RectToNc(client_rect), metrics);
        return .{
            .minimize = ncRectToWin32(rects.min),
            .maximize = ncRectToWin32(rects.max),
            .close = ncRectToWin32(rects.close),
        };
    }

    /// Live caption-button view handed to the UIA root provider. The
    /// buttons are painted inside the client area and own no HWND, so
    /// fragment children of the root are the only way a reader sees them.
    pub fn captionButtonsUiaState(self: *Host) win32_uia.CaptionButtonsState {
        return .{
            .ctx = @ptrCast(self),
            .painted = captionButtonsPaintedThunk,
            .bounds = captionButtonBoundsThunk,
            .zoomed = captionButtonZoomedThunk,
            .invoke = captionButtonInvokeThunk,
            .use_com_threading = self.app.com_initialized,
        };
    }

    /// Ask for a caption UIA re-check once the current message is done.
    ///
    /// The events below are delivered to listening clients while this
    /// thread waits, so raising them from inside `WM_SIZE` or a decoration
    /// change stalls the window's message loop at exactly the moment a
    /// reader is asking it questions. Posting moves them to a point where
    /// the loop is free.
    pub fn scheduleCaptionUiaSync(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        if (self.caption_sync_pending) return;
        self.caption_sync_pending = true;
        if (sys.PostMessageW(hwnd, c.WM_WINHOSTTY_UIA_CAPTION_SYNC, 0, 0) == 0) {
            // The queue is full or the window is going away. Falling back
            // to an inline raise is worse than skipping it: the next
            // transition re-checks the same state from scratch.
            self.caption_sync_pending = false;
            log.warn("win32 caption UIA sync post failed", .{});
        }
    }

    /// Keep UIA in step with the caption row. Two things move: the whole
    /// child set appears and disappears with the integrated titlebar (and
    /// with minimize / hide), and the middle button's name follows the
    /// zoomed state. Always reached through `scheduleCaptionUiaSync`.
    pub fn syncCaptionUiaState(self: *Host) void {
        self.caption_sync_pending = false;
        const provider = self.root_uia_provider orelse return;
        const painted = captionButtonsPaintedThunk(@ptrCast(self));
        if (self.caption_painted != painted) {
            self.caption_painted = painted;
            provider.raiseCaptionStructureChanged();
        }
        // Nothing is painted, so there is no name to correct, and a
        // minimized window reports not-zoomed while its restore target is
        // still maximized — announcing that would be a lie to take back.
        if (!painted) return;
        const hwnd = self.hwnd orelse return;
        const zoomed = sys.IsZoomed(hwnd) != 0;
        if (self.caption_zoomed == zoomed) return;
        self.caption_zoomed = zoomed;
        provider.raiseCaptionButtonNameChanged(.maximize);
    }

    pub fn scaled(self: *const Host, base: i32) i32 {
        return win32_chrome_state.scaled(base, self.current_dpi);
    }

    /// DPI-scale helper usable from free functions that lack a Host pointer.
    pub fn scaledBy(base: i32, dpi: u32) i32 {
        return win32_chrome_state.scaled(base, dpi);
    }

    pub fn contentRectFromClient(self: *Host, rect: RECT) RECT {
        const tab_offset: i32 = self.tabBarHeight();
        const overlay_offset: i32 = if (self.overlay_mode == .none) 0 else self.scaled(host_overlay_height);
        const inspector_offset: i32 = if (self.inspectorPanelVisible()) self.scaled(host_inspector_panel_height) else 0;
        const bands = self.contentBands(tab_offset, overlay_offset, inspector_offset);
        return .{
            .left = 0,
            .top = bands.content_top,
            .right = rect.right,
            .bottom = @max(bands.content_top + 1, rect.bottom),
        };
    }

    pub fn contentRect(self: *Host) !RECT {
        if (self.hwnd == null) return error.InvalidHost;
        const rect = (try self.layoutClientRect()) orelse return error.NoClientArea;
        return self.contentRectFromClient(rect);
    }

    /// The client rect to lay children out against. A minimized window
    /// reports 0x0, and this keeps the last rect that had an area instead,
    /// so minimizing never resizes a terminal (#262). Null only before the
    /// window has had a client area at all.
    fn layoutClientRect(self: *Host) !?RECT {
        const hwnd = self.hwnd orelse return null;
        var live: RECT = undefined;
        if (sys.GetClientRect(hwnd, &live) == 0) {
            return lastError();
        }
        const rect = hostLayoutClientRect(live, self.last_layout_client_rect) orelse return null;
        self.last_layout_client_rect = rect;
        return rect;
    }

    /// WM_CLOSE (the caption button, Alt+F4, the taskbar) and
    /// `close_window`. When a terminal in the window would lose a running
    /// process (`confirm-close-surface`), ask once for the whole window;
    /// its Close runs `closeConfirmed`. A sign-out never asks.
    pub fn close(self: *Host) void {
        const count = tabsCloseConfirmCount(self.tabs.items);
        if (count == 0 or self.app.session_ending) return self.closeConfirmed();
        self.askBeforeClosing(.window, count, &hostCloseConfirmAccept, self);
    }

    /// One prompt for a close that ends `count` terminals which
    /// `confirm-close-surface` asks about. The window comes up first, so a
    /// close from the taskbar or a quit never waits on a prompt nobody can
    /// see, and asking again keeps the prompt already open. If the prompt
    /// cannot open, nothing closes, as in `Surface.close`: closing anyway
    /// would defeat the setting, and the user can retry.
    pub fn askBeforeClosing(
        self: *Host,
        scope: CloseScope,
        count: usize,
        on_accept: *const fn (userdata: ?*anyopaque) void,
        userdata: *anyopaque,
    ) void {
        const raised = self.presentForPrompt();
        if (self.showsConfirm(on_accept, userdata)) {
            // Raising the window focused its terminal; the prompt keeps the keys.
            if (raised) if (self.overlay_accept_hwnd) |accept| {
                _ = sys.SetFocus(accept);
            };
            return;
        }
        var body: [256]u8 = undefined;
        var title: [32]u8 = undefined;
        var prompt = closeScopePrompt(scope, count, &body);
        // A tab closed from its button need not be the one in front, and
        // "this tab" would then name the wrong one.
        const named_body = if (scope == .this_tab)
            self.nameBackgroundTab(&prompt, count, @ptrCast(@alignCast(userdata)), &title)
        else
            null;
        defer if (named_body) |text| self.app.core_app.alloc.free(text);
        self.showConfirm(prompt, on_accept, null, userdata) catch |err| {
            log.warn("close confirm unavailable err={}; declining close to honour confirm-close-surface", .{err});
        };
    }

    /// Words the `.this_tab` prompt for the tab holding `surface` as the
    /// tab's number and title when another tab is in front, as the OSC 52
    /// prompt names the tab that asked. Returns the body it allocated, which
    /// `prompt` borrows; null leaves the prompt as it was (the tab in front,
    /// or no memory for the words).
    fn nameBackgroundTab(self: *Host, prompt: *ConfirmPrompt, count: usize, surface: *Surface, title_buf: *[32]u8) ?[]u8 {
        const index = self.backgroundTabIndex(surface) orelse return null;
        // The title needs no memory, so it names the tab even if the body cannot.
        prompt.title = labels.backgroundTabClosePromptTitle(title_buf, index + 1);
        const body = labels.buildBackgroundTabClosePromptBody(
            self.app.core_app.alloc,
            count,
            index + 1,
            surface.effectiveTitle(),
        ) catch return null;
        prompt.body = body;
        return body;
    }

    /// The same for the prompt of a terminal that closes by itself, which
    /// `Surface.close` raises whatever tab the terminal is in.
    pub fn nameBackgroundTerminal(self: *Host, prompt: *ConfirmPrompt, surface: *Surface, title_buf: *[32]u8) ?[]u8 {
        const index = self.backgroundTabIndex(surface) orelse return null;
        prompt.title = labels.backgroundTerminalClosePromptTitle(title_buf, index + 1);
        const body = labels.buildBackgroundTerminalClosePromptBody(
            self.app.core_app.alloc,
            index + 1,
            surface.effectiveTitle(),
            surface.core_initialized and surface.core_surface.child_exited,
        ) catch return null;
        prompt.body = body;
        return body;
    }

    /// The index of the tab of this window that holds `surface`, unless
    /// that tab is the one in front.
    fn backgroundTabIndex(self: *Host, surface: *Surface) ?usize {
        const found = Host.findTabForSurface(surface) orelse return null;
        if (found.host != self or found.index == self.active_tab) return null;
        return found.index;
    }

    /// Shown on screen, minimized included; a hidden quick terminal is not.
    pub fn isShown(self: *const Host) bool {
        const hwnd = self.hwnd orelse return false;
        return sys.IsWindowVisible(hwnd) != 0;
    }

    pub fn showsConfirm(self: *const Host, on_accept: *const fn (userdata: ?*anyopaque) void, userdata: *anyopaque) bool {
        const payload = self.confirm_payload orelse return false;
        return payload.on_accept == on_accept and payload.userdata == userdata;
    }

    /// Restore and raise the window for a prompt unless it is already the
    /// foreground window. Returns whether it did.
    fn presentForPrompt(self: *Host) bool {
        const hwnd = self.hwnd orelse return false;
        if (sys.GetForegroundWindow() == hwnd and sys.IsIconic(hwnd) == 0) return false;
        const surface = self.activeSurface() orelse return false;
        self.app.activateSurface(surface);
        return true;
    }

    /// Close every terminal in the window without asking.
    pub fn closeConfirmed(self: *Host) void {
        const alloc = self.app.core_app.alloc;
        const fallback_hwnd = self.hwnd;
        var surfaces: std.ArrayListUnmanaged(*Surface) = .empty;
        defer surfaces.deinit(alloc);

        for (self.tabs.items) |*tab| {
            var it = tab.tree.iterator();
            while (it.next()) |entry| surfaces.append(alloc, entry.view) catch {
                // Closing the parent HWND here would recursively destroy every
                // child surface without running confirmation or the native ↔
                // ShellState close preflight. An allocation failure must leave
                // the live session untouched; the user can retry the close.
                log.err("refusing host close: unable to stage surface list", .{});
                return;
            };
        }

        if (surfaces.items.len == 0) {
            self.clearStructuralHistory(.normal);
            if (fallback_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
            self.app.removeHost(self);
            return;
        }
        // The session's last window, whatever else is open: a quick terminal
        // or a window kept empty for undo is not part of the session.
        if (self.app.closingEndsSession(self)) self.app.saveSessionAsItEnds();
        for (surfaces.items) |surface| surface.close(false);
    }

    /// The tab and window title prompts are filled from the active surface
    /// and submit to whichever surface is active at Enter. The tab prompt's
    /// hint already follows the active tab ("Rename tab n/N"); when the
    /// active surface changes (a tab switch or focus moving to another split
    /// pane), refill the text with the new surface's title too, so submit
    /// never writes one surface's title onto another.
    fn syncOverlayTextToActiveSurface(self: *Host) !bool {
        const surface = self.activeSurface();
        if (!overlayTextNeedsRefill(self.overlay_mode, self.overlay_text_surface, surface)) return false;
        const text = self.overlayInitialText(self.overlay_mode) orelse return false;
        defer self.app.core_app.alloc.free(text);
        const changed = try self.setOverlayEditText(text);
        // Only after the text box really holds the new title: marking the
        // surface first would make a failed refill look done, and the next
        // refresh would never retry.
        self.overlay_text_surface = surface;
        return changed;
    }

    pub fn refreshChrome(self: *Host) !void {
        try self.refreshModeIndicator();
        var invalidate = self.chrome_repaint_dirty;
        _ = try self.syncWindowTitle();
        invalidate = (try self.syncTabButtons()) or invalidate;
        try self.syncChromeButtons();
        if (self.overlay_mode != .none) {
            invalidate = (try self.syncOverlayTextToActiveSurface()) or invalidate;
            invalidate = (try self.syncOverlayLabel()) or invalidate;
            invalidate = (try self.syncOverlayHint()) or invalidate;
            _ = try self.syncOverlayPreview();
            _ = try self.syncOverlayButtons();
        }
        if (invalidate) {
            self.invalidateTopChromeText();
        }
    }

    pub const repaintChrome = chrome_scene.HostScene.repaintChrome;

    const repaintFullHost = chrome_scene.HostScene.repaintFullHost;

    pub const invalidateChromeMask = chrome_scene.HostScene.invalidateChromeMask;

    pub const queueChromeRepaint = chrome_scene.HostScene.queueChromeRepaint;

    test "CHROME57 focused profile Open retains badge ink" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(profileFocusPaintTestBody);
    }

    fn profileFocusPaintTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        const button = try createTestChromeChild(window.parent, prompt_button_class);
        var profiles = [_]windows_shell.Profile{.{ .kind = .powershell, .key = "chrome57-profile", .label = "PowerShell", .command = .{ .shell = "pwsh" } }};
        host.profiles = &profiles;
        defer host.profiles = null;
        const key = try std.testing.allocator.dupeZ(u8, profiles[0].key);
        defer std.testing.allocator.free(key);
        app.launcher_quick_slot_keys[0] = key;
        defer app.launcher_quick_slot_keys[0] = null;
        host.overlay_mode = .profile;
        host.overlay_accept_hwnd = button;
        defer host.overlay_accept_hwnd = null;
        for ([_]u32{ 96, 144, 192 }) |dpi| {
            host.current_dpi = dpi;
            const width = host.scaled(120);
            const height = host.scaled(32);
            const canvas = try BannerTestCanvas.init(width, height);
            defer canvas.deinit();
            const draw: DRAWITEMSTRUCT = .{
                .CtlType = c.ODT_BUTTON,
                .CtlID = 2003,
                .itemID = 0,
                .itemAction = 0,
                .itemState = c.ODS_FOCUS,
                .hwndItem = button,
                .hDC = canvas.dc,
                .rcItem = .{ .left = 0, .top = 0, .right = width, .bottom = height },
                .itemData = 0,
            };
            const plain_canvas = try BannerTestCanvas.init(width, height);
            defer plain_canvas.deinit();
            var plain_draw = draw;
            plain_draw.hDC = plain_canvas.dc;
            plain_draw.itemState = 0;
            host.drawButton(&plain_draw);
            host.drawButton(&draw);
            _ = BannerTestCanvas.raw.GdiFlush();
            try std.testing.expectEqual(profileChromeStripeColor(.powershell, app.resolved_theme.is_dark, false, false, false, false), canvas.pixel(3, host.scaled(16)));
            const bg = applyProfileChromeAccent(buttonColorsFromTheme(&app.resolved_theme, false, true, false, false, false, true, false), .powershell, app.resolved_theme.is_dark, false, false, false, false).bg;
            const ring_x = @divTrunc(width, 2);
            const ring_y = height - host.scaled(2) - 2;
            try std.testing.expectEqual(profileKindFocusRingColor(.powershell, app.resolved_theme.is_dark), canvas.pixel(ring_x, ring_y));
            try std.testing.expect(canvas.pixel(ring_x, ring_y) != plain_canvas.pixel(ring_x, ring_y));
            // Preserve every badge ink pixel, including straight edges.
            // Rounded corners outside the badge may show the ring beneath.
            for ([_]RECT{
                .{ .left = width - host.scaled(15), .top = host.scaled(3), .right = width - host.scaled(4), .bottom = host.scaled(14) },
                .{ .left = width - host.scaled(13), .top = height - host.scaled(13), .right = width - host.scaled(3), .bottom = height - host.scaled(3) },
            }) |badge| {
                var y = badge.top;
                while (y < badge.bottom) : (y += 1) {
                    var x = badge.left;
                    while (x < badge.right) : (x += 1) {
                        const plain = plain_canvas.pixel(x, y);
                        if (plain != bg) try std.testing.expectEqual(plain, canvas.pixel(x, y));
                    }
                }
            }
            // Both badges carry text in the right lane. A background-filled
            // ring used to erase the entire lane before drawing the label.
            try std.testing.expect(canvas.inked(.{ .left = width - host.scaled(32), .top = host.scaled(8), .right = width - host.scaled(6), .bottom = height - host.scaled(8) }, bg) > 8);
        }
    }

    test "CHROME57 focus outline preserves profile stripe and badge interiors" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        for ([_]u32{ 96, 144, 192 }) |dpi| {
            const scale = win32_chrome_state.scaled;
            var canvas = try BannerTestCanvas.init(scale(120, dpi), scale(32, dpi));
            defer canvas.deinit();
            const rect = RECT{ .left = 0, .top = 0, .right = canvas.width, .bottom = canvas.height };
            fillSolidRect(canvas.dc, rect, rgb(20, 30, 40));
            const stripe = RECT{ .left = scale(3, dpi), .top = scale(8, dpi), .right = scale(5, dpi), .bottom = scale(24, dpi) };
            const badge = RECT{ .left = scale(100, dpi), .top = scale(10, dpi), .right = scale(114, dpi), .bottom = scale(22, dpi) };
            fillSolidRect(canvas.dc, stripe, rgb(10, 100, 200));
            fillSolidRect(canvas.dc, badge, rgb(200, 100, 10));
            gdi.drawRoundedOutline(canvas.dc, rectInset(rect, scale(2, dpi), scale(2, dpi)), rgb(100, 200, 100), scale(3, dpi));
            _ = BannerTestCanvas.raw.GdiFlush();
            try std.testing.expectEqual(rgb(10, 100, 200), canvas.pixel(scale(4, dpi), scale(16, dpi)));
            try std.testing.expectEqual(rgb(200, 100, 10), canvas.pixel(scale(106, dpi), scale(16, dpi)));
        }
    }

    test "the tab strip paints no accent and the active tab takes its terminal background" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(tabStripNoAccentTestBody);
    }

    fn tabStripNoAccentTestBody() !void {
        if (isHighContrastActive()) return error.SkipZigTest;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var first: Surface = undefined;
        var second: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
            .surfaces = &.{ .{ .storage = &first, .host = &host }, .{ .storage = &second, .host = &host } },
            .tabs = &.{ .{ .host = &host, .surface = &first, .id = 1 }, .{ .host = &host, .surface = &second, .id = 2 } },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        host.tabs.items[0].button_hwnd = try createTestChromeChild(window.parent, prompt_button_class);
        host.tabs.items[1].button_hwnd = try createTestChromeChild(window.parent, prompt_button_class);
        const client: RECT = .{ .left = 0, .top = 0, .right = 1000, .bottom = 300 };
        var changed = false;
        host.active_tab = 0;
        _ = host.layoutChromeForRect(client, &changed);
        // The terminals keep the config's default `background`.
        const terminal_bg = rgb(0x28, 0x2C, 0x34);
        const band_bottom = host.contentBands(host.tabBarHeight(), 0, 0).overlay_top;
        const theme = clientTitlebarTheme(&app.resolved_theme, app.shownConfig(), host.usingIntegratedTitlebar(), false);
        const active = host.tabs.items[0].button_placement.rect;
        const tabs_right = host.tabs.items[1].button_placement.rect.right;

        // The band under the tabs: the chrome background, the separator on
        // its last row, and the active tab's terminal background running
        // through both under the active tab. No accent anywhere.
        const canvas = try BannerTestCanvas.init(tabs_right, band_bottom);
        defer canvas.deinit();
        host.paintChromeTabBar(canvas.dc, client, host.tabBarHeight(), band_bottom, true, &app.resolved_theme);
        _ = BannerTestCanvas.raw.GdiFlush();
        var y: i32 = 0;
        while (y < band_bottom) : (y += 1) {
            var x: i32 = 0;
            while (x < tabs_right) : (x += 1) {
                const pixel = canvas.pixel(x, y);
                try std.testing.expect(pixel != theme.accent);
                if (y < active.bottom) continue;
                const joined = x > active.left and x < active.right - 1;
                const expected = if (joined)
                    terminal_bg
                else if (y == band_bottom - 1)
                    theme.chrome_border
                else
                    theme.chrome_bg;
                try std.testing.expectEqual(expected, pixel);
            }
        }

        // The active tab's own button: its terminal's background inside and
        // as its edge (no border), square lower corners meeting the band's
        // part, and the band showing only at its rounded upper corners.
        const width = active.right - active.left;
        const height = active.bottom - active.top;
        const tab_canvas = try BannerTestCanvas.init(width, height);
        defer tab_canvas.deinit();
        const draw: DRAWITEMSTRUCT = .{
            .CtlType = c.ODT_BUTTON,
            .CtlID = 1000,
            .itemID = 0,
            .itemAction = 0,
            .itemState = 0,
            .hwndItem = host.tabs.items[0].button_hwnd.?,
            .hDC = tab_canvas.dc,
            .rcItem = childRect(0, 0, width, height),
            .itemData = 0,
        };
        _ = sys.SetWindowTextW(draw.hwndItem, std.unicode.utf8ToUtf16LeStringLiteral("* 1: label"));
        host.drawButton(&draw);
        _ = BannerTestCanvas.raw.GdiFlush();
        try std.testing.expectEqual(terminal_bg, tab_canvas.pixel(@divTrunc(width, 2), 1));
        try std.testing.expectEqual(terminal_bg, tab_canvas.pixel(1, @divTrunc(height, 2)));
        try std.testing.expectEqual(terminal_bg, tab_canvas.pixel(1, height - 1));
        try std.testing.expectEqual(terminal_bg, tab_canvas.pixel(width - 2, height - 1));
        try std.testing.expectEqual(theme.chrome_bg, tab_canvas.pixel(0, 0));

        // The label over it reads at 4.5:1 under either window theme, in an
        // active and an inactive window, on the default dark terminal and on
        // the mid-tone and saturated ones where neither palette's label does
        // (`activeTabTheme`). The light theme's own label colours on the
        // default dark terminal reach 1.23:1 (active window) and about 2.2:1
        // (inactive); the light palette's on #777777, 3.85:1 and 1.40:1.
        // Inside the button's fill: its top row and side columns are the band's.
        const label_rect = childRect(@divTrunc(width, 4), 2, @divTrunc(width * 3, 8), height - 4);
        const backgrounds = [_]u32{ terminal_bg, rgb(0x77, 0x77, 0x77), rgb(0x80, 0x80, 0x80), rgb(0xFF, 0x00, 0x00), rgb(0x00, 0x78, 0xD4) };
        for ([_]ThemeColors{ win32.darkTheme(), win32.lightTheme() }) |band_theme| {
            app.resolved_theme = band_theme;
            for (backgrounds) |background| {
                first.tab_background = background;
                for ([_]bool{ true, false }) |window_active| {
                    host.window_active = window_active;
                    host.drawButton(&draw);
                    _ = BannerTestCanvas.raw.GdiFlush();
                    try std.testing.expect(tab_canvas.inked(label_rect, background) > 0);
                    var strongest: f64 = 1;
                    var y_label = label_rect.top;
                    while (y_label < label_rect.bottom) : (y_label += 1) {
                        var x_label = label_rect.left;
                        while (x_label < label_rect.right) : (x_label += 1) {
                            strongest = @max(strongest, testContrast(tab_canvas.pixel(x_label, y_label), background));
                        }
                    }
                    try std.testing.expect(strongest >= 4.5);
                }
            }
        }
    }

    /// WCAG contrast ratio between two COLORREFs.
    fn testContrast(a: u32, b: u32) f64 {
        const luminance = struct {
            fn channel(value: u32) f64 {
                const s = @as(f64, @floatFromInt(value & 0xFF)) / 255.0;
                return if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
            }
            fn of(color: u32) f64 {
                return 0.2126 * channel(color) + 0.7152 * channel(color >> 8) + 0.0722 * channel(color >> 16);
            }
        };
        const la = luminance.of(a);
        const lb = luminance.of(b);
        return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
    }

    test "the active tab's join follows the active tab and its terminal background" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(activeTabJoinTestBody);
    }

    fn activeTabJoinTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var first: Surface = undefined;
        var second: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
            .surfaces = &.{ .{ .storage = &first, .host = &host }, .{ .storage = &second, .host = &host } },
            .tabs = &.{ .{ .host = &host, .surface = &first, .id = 1 }, .{ .host = &host, .surface = &second, .id = 2 } },
        });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        first.tab_background = rgb(0x12, 0x34, 0x56);
        second.tab_background = rgb(0x65, 0x43, 0x21);
        host.tabs.items[0].button_hwnd = try createTestChromeChild(window.parent, prompt_button_class);
        const client: RECT = .{ .left = 0, .top = 0, .right = 1000, .bottom = 300 };
        var changed = false;

        // A tab whose button does not exist yet has nothing to join.
        host.active_tab = 1;
        _ = host.layoutChromeForRect(client, &changed);
        try std.testing.expect(host.tab_join == null);
        host.tabs.items[1].button_hwnd = try createTestChromeChild(window.parent, prompt_button_class);
        _ = host.layoutChromeForRect(client, &changed);
        if (isHighContrastActive()) {
            // High Contrast keeps the system highlight and no join.
            try std.testing.expect(host.tab_join == null);
            return;
        }
        const join = host.tab_join orelse return error.TestUnexpectedResult;
        const button = host.tabs.items[1].button_placement.rect;
        try std.testing.expectEqual(rgb(0x65, 0x43, 0x21), join.color);
        try std.testing.expectEqual(button.left + 1, join.rect.left);
        try std.testing.expectEqual(button.right - 1, join.rect.right);
        try std.testing.expectEqual(button.bottom, join.rect.top);
        try std.testing.expectEqual(host.contentBands(host.tabBarHeight(), 0, 0).overlay_top, join.rect.bottom);

        // Activating the other tab moves it there, and repaints both places:
        // the old one goes back to the band. (A hidden window has no update
        // region; this one is shown on the test's private desktop, and made
        // larger than `client` so no part of either rect is clipped away.)
        _ = sys.MoveWindow(window.parent, 0, 0, 1100, 400, 0);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        _ = sys.ValidateRect(window.parent, null);
        const old_join = join.rect;
        host.active_tab = 0;
        _ = host.layoutChromeForRect(client, &changed);
        try std.testing.expectEqual(rgb(0x12, 0x34, 0x56), host.tab_join.?.color);
        try std.testing.expectEqual(host.tabs.items[0].button_placement.rect.left + 1, host.tab_join.?.rect.left);
        const Region = struct {
            extern "user32" fn GetUpdateRgn(hwnd: HWND, rgn: *anyopaque, erase: BOOL) callconv(.winapi) i32;
            extern "gdi32" fn PtInRegion(rgn: *anyopaque, x: i32, y: i32) callconv(.winapi) BOOL;
        };
        const update = sys.CreateRectRgn(0, 0, 0, 0) orelse return error.SkipZigTest;
        defer _ = sys.DeleteObject(update);
        _ = Region.GetUpdateRgn(window.parent, update, 0);
        for ([_]RECT{ old_join, host.tab_join.?.rect }) |place| {
            try std.testing.expect(Region.PtInRegion(update, @divTrunc(place.left + place.right, 2), @divTrunc(place.top + place.bottom, 2)) != 0);
        }

        // A new terminal background for the active tab's terminal moves it
        // as well, and one for a terminal in another tab does not.
        second.setTabBackground(.{ .r = 0x01, .g = 0x02, .b = 0x03 });
        try std.testing.expectEqual(rgb(0x12, 0x34, 0x56), host.tab_join.?.color);
        first.setTabBackground(.{ .r = 0x0A, .g = 0x0B, .b = 0x0C });
        try std.testing.expectEqual(rgb(0x0A, 0x0B, 0x0C), host.tab_join.?.color);

        // With the tab bar hidden there is no join.
        app.config.@"window-show-tab-bar" = .never;
        _ = host.layoutChromeForRect(client, &changed);
        try std.testing.expect(host.tab_join == null);
    }

    test "TABLINE a pane focused by a click repaints its tab when its terminal background differs" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(clickFocusTabBackgroundTestBody);
    }

    fn clickFocusTabBackgroundTestBody() !void {
        if (isHighContrastActive()) return error.SkipZigTest;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host },
            },
            .tabs = &.{.{ .host = &host, .surface = &surface_a, .id = 1 }},
        });
        defer session.deinit();

        // One tab, [A | B] with A focused: one title, two backgrounds.
        const inserted = try SplitTreeSurface.init(std.testing.allocator, &surface_b);
        defer {
            var cleanup = inserted;
            cleanup.deinit();
        }
        const tab = &host.tabs.items[0];
        const next_tree = try tab.tree.split(std.testing.allocator, .root, .right, 0.5, &inserted);
        tab.tree.deinit();
        tab.tree = next_tree;
        tab.focused = tab.findHandle(&surface_a).?;
        surface_a.title = "pwsh";
        surface_b.title = "pwsh";
        surface_a.tab_background = rgb(0x12, 0x34, 0x56);
        surface_b.tab_background = rgb(0x65, 0x43, 0x21);

        // The host clips its children, as a real one does, so its own
        // repaints never reach the button. A hidden window has no update
        // region; this one is shown on the test's private desktop.
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        const style = sys.GetWindowLongPtrW(window.parent, c.GWL_STYLE);
        _ = sys.SetWindowLongPtrW(window.parent, c.GWL_STYLE, style | c.WS_CLIPCHILDREN);
        _ = sys.MoveWindow(window.parent, 0, 0, 1200, 300, 0);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);
        try host.refreshChrome();
        const button = tab.button_hwnd orelse return error.TestUnexpectedResult;
        const placed = tab.button_placement.rect;
        try std.testing.expectEqual(rgb(0x12, 0x34, 0x56), host.tab_join.?.color);
        _ = sys.ValidateRect(button, null);

        // A click focuses B: its WM_SETFOCUS runs `focusChanged`, and the
        // moved focus refreshes the chrome. The label and the button's place
        // stay as they were, so only the background says to repaint it.
        surface_b.focusChanged(true);
        try host.refreshChrome();
        try std.testing.expectEqual(tab.findHandle(&surface_b).?, tab.focused);
        try std.testing.expectEqual(placed, tab.button_placement.rect);
        try std.testing.expectEqual(rgb(0x65, 0x43, 0x21), host.tab_join.?.color);
        var update: RECT = undefined;
        try std.testing.expect(sys.GetUpdateRect(button, &update, 0) != 0);

        // Back to A, which now has B's background: the tab shows the same
        // color, and nothing repaints it.
        surface_a.tab_background = surface_b.tab_background;
        _ = sys.ValidateRect(button, null);
        surface_a.focusChanged(true);
        try host.refreshChrome();
        try std.testing.expectEqual(tab.findHandle(&surface_a).?, tab.focused);
        try std.testing.expectEqual(@as(BOOL, 0), sys.GetUpdateRect(button, &update, 0));
    }

    test "CHROME57 native activation updates only top chrome and its children" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(activationChromeTestBody);
    }

    fn activationChromeTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        setWindowData(window.parent, &host);
        defer setWindowData(window.parent, null);
        // A hidden child has no update region. Show these test HWNDs only
        // on the private desktop owned by runOnPrivateDesktop.
        const style = sys.GetWindowLongPtrW(window.parent, c.GWL_STYLE);
        _ = sys.SetWindowLongPtrW(window.parent, c.GWL_STYLE, style | c.WS_CLIPCHILDREN);
        _ = sys.MoveWindow(host.new_tab_hwnd.?, 0, 0, 32, 32, 0);
        _ = sys.ShowWindow(window.parent, c.SW_SHOWNOACTIVATE);
        _ = sys.ShowWindow(host.new_tab_hwnd.?, c.SW_SHOWNOACTIVATE);
        host.chrome_paint_mask = .{};
        _ = sys.ValidateRect(window.pane, null);
        _ = sys.ValidateRect(host.new_tab_hwnd.?, null);
        _ = hostWindowProc(window.parent, c.WM_NCACTIVATE, 1, 0);
        try std.testing.expect(host.window_active);
        try std.testing.expect(host.chrome_paint_mask.top);
        try std.testing.expect(!host.chrome_paint_mask.content);
        var update: RECT = undefined;
        try std.testing.expect(sys.GetUpdateRect(host.new_tab_hwnd.?, &update, 0) != 0);
        try std.testing.expectEqual(@as(BOOL, 0), sys.GetUpdateRect(window.pane, &update, 0));
        _ = hostWindowProc(window.parent, c.WM_NCACTIVATE, 0, 0);
        try std.testing.expect(!host.window_active);
        // Isolate our child invalidation from DefWindowProc's frame work.
        _ = sys.ValidateRect(host.new_tab_hwnd.?, null);
        host.setWindowActive(true);
        try std.testing.expect(sys.GetUpdateRect(host.new_tab_hwnd.?, &update, 0) != 0);
    }

    test "CHROME57 unchanged theme messages retry each failed font but keep search lazy" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(themeFontRetryTestBody);
    }

    fn themeFontRetryTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host, .register = true }} });
        defer session.deinit();
        defer {
            inline for (.{ "chrome_font", "preview_font", "titlebar_caption_icon_font", "titlebar_action_icon_font", "search_icon_font", "chrome_brush", "overlay_brush", "edit_brush" }) |name| {
                if (@field(host, name)) |object| _ = sys.DeleteObject(object);
            }
        }
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        app.reconfigureSystemTheme();
        // An unused search font is intentionally absent, not a failed resource.
        const applied = app.theme_rebuilds;
        try std.testing.expect(host.search_icon_font == null);
        try std.testing.expect(!host.search_icon_font_resolved);
        app.reconfigureSystemTheme();
        try std.testing.expectEqual(applied, app.theme_rebuilds);

        inline for (.{ "preview_font", "titlebar_caption_icon_font", "titlebar_action_icon_font", "chrome_font" }) |name| {
            // Null by design without an icon face that has the glyphs; the
            // geometric titlebar icons test retries those fonts instead.
            const by_design = comptime std.mem.startsWith(u8, name, "titlebar_");
            if (!(by_design and host.titlebar_icons_geometric)) {
                const slot = &@field(host, name);
                const font = slot.* orelse return error.FontCreateFailed;
                _ = sys.DeleteObject(font);
                slot.* = null;
                const before = app.theme_rebuilds;
                app.reconfigureSystemTheme();
                try std.testing.expectEqual(before + 1, app.theme_rebuilds);
                try std.testing.expect(slot.* != null);
                app.reconfigureSystemTheme();
                try std.testing.expectEqual(before + 1, app.theme_rebuilds);
            }
        }
        // A previous failed lazy search-font attempt must get another chance.
        host.search_icon_font_resolved = true;
        const before = app.theme_rebuilds;
        app.reconfigureSystemTheme();
        try std.testing.expectEqual(before + 1, app.theme_rebuilds);
        try std.testing.expect(!host.search_icon_font_resolved);
        app.reconfigureSystemTheme();
        try std.testing.expectEqual(before + 1, app.theme_rebuilds);
    }

    test "titlebar icons are drawn geometrically when no icon face has the glyphs, and a failed check is retried" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnPrivateDesktop(geometricTitlebarIconsTestBody);
    }

    /// The titlebar icon fonts as the default faces leave them on this
    /// machine: from `face`, the first icon face it has (Segoe MDL2 Assets
    /// where Segoe Fluent Icons is missing), or the geometric state when
    /// `face` is null.
    fn expectDefaultTitlebarIconFonts(self: *const Host, face: ?[*:0]const u16) !void {
        try std.testing.expectEqual(face == null, self.titlebar_icons_geometric);
        inline for (.{ "titlebar_caption_icon_font", "titlebar_action_icon_font" }) |name| {
            if (@field(self, name)) |font| {
                try std.testing.expect(try fontIsFaceForTest(font, face orelse return error.TestUnexpectedFont));
                try std.testing.expectEqual(GlyphCoverage.all, fontGlyphCoverage(font, &titlebar_icon_glyphs));
            } else try std.testing.expect(face == null);
        }
    }

    fn geometricTitlebarIconsTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host, .register = true }} });
        defer session.deinit();
        defer {
            inline for (.{ "chrome_font", "preview_font", "titlebar_caption_icon_font", "titlebar_action_icon_font", "search_icon_font", "chrome_brush", "overlay_brush", "edit_brush" }) |name| {
                if (@field(host, name)) |object| _ = sys.DeleteObject(object);
            }
        }
        const window = try BannerTestWindow.init(&host);
        defer window.deinit(&host);
        app.reconfigureSystemTheme();
        const installed_face = try installedTitlebarIconFaceForTest();
        try host.expectDefaultTitlebarIconFonts(installed_face);

        // Every face missing, as Segoe Fluent Icons is on Windows 10.
        host.recreateTitlebarIconFontsFrom(&.{icon_font_test_missing_face});
        try std.testing.expect(host.titlebar_caption_icon_font == null);
        try std.testing.expect(host.titlebar_action_icon_font == null);
        try std.testing.expect(host.titlebar_icons_geometric);

        // `win32_icons` draws the tab row's buttons and the caption buttons.
        const canvas = try BannerTestCanvas.init(32, 32);
        defer canvas.deinit();
        const rect: RECT = .{ .left = 0, .top = 0, .right = 32, .bottom = 32 };
        const background: u32 = 0x000000;
        for (std.enums.values(TitlebarGlyphKind)) |kind| {
            fillSolidRect(canvas.dc, rect, background);
            host.drawTitlebarGlyph(canvas.dc, rect, kind, 0xFFFFFF, kind != .new_tab and kind != .dropdown);
            _ = BannerTestCanvas.raw.GdiFlush();
            try std.testing.expect(canvas.inked(rect, background) > 0);
        }

        // Fonts absent by design are not a failed resource: an unchanged
        // theme message leaves them alone.
        const geometric_rebuilds = app.theme_rebuilds;
        app.reconfigureSystemTheme();
        try std.testing.expectEqual(geometric_rebuilds, app.theme_rebuilds);
        try std.testing.expect(host.titlebar_icons_geometric);

        // A glyph check GDI failed is no verdict: the fonts count as
        // missing, and the next unchanged theme message rebuilds them from
        // the default faces.
        {
            win32.test_glyph_check_fails = true;
            defer win32.test_glyph_check_fails = false;
            host.recreateTitlebarIconFonts();
        }
        try std.testing.expect(host.titlebar_caption_icon_font == null);
        try std.testing.expect(host.titlebar_action_icon_font == null);
        try std.testing.expect(!host.titlebar_icons_geometric);
        const failed_rebuilds = app.theme_rebuilds;
        app.reconfigureSystemTheme();
        try std.testing.expectEqual(failed_rebuilds + 1, app.theme_rebuilds);
        try host.expectDefaultTitlebarIconFonts(installed_face);
    }

    pub fn setWindowActive(self: *Host, active: bool) void {
        if (self.window_active == active) return;
        self.window_active = active;
        self.repaintTopChrome();
        // Parent invalidation does not repaint child owner-drawn buttons.
        for (self.tabs.items) |tab| {
            if (tab.button_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        }
        if (self.new_tab_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        if (self.overflow_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
    }

    pub const repaintTopChrome = chrome_scene.HostScene.repaintTopChrome;

    pub const repaintContentChrome = chrome_scene.HostScene.repaintContentChrome;

    pub const invalidateOverlayText = chrome_scene.HostScene.invalidateOverlayText;

    pub const invalidateTopChromeText = chrome_scene.HostScene.invalidateTopChromeText;

    pub const invalidateChrome = chrome_scene.HostScene.invalidateChrome;

    pub const shouldDeferSurfaceRepaints = surface_presentation.shouldDeferSurfaceRepaints;

    pub const flushDeferredVisibleSurfaceRepaints = surface_presentation.flushDeferredVisibleSurfaceRepaints;

    pub const flushDeferredVisibleSurfaceRepaintsWith = surface_presentation.flushDeferredVisibleSurfaceRepaintsWith;

    /// `MoveWindow` / `SetWindowPos` with repaint suppressed does not reliably
    /// queue `WM_PAINT` on child HWNDs. Owner-draw tab controls always repaint
    /// immediately; WGL child surfaces repaint immediately outside live resize
    /// and defer to an explicit post-resize flush while the user is dragging.
    fn invalidateChromeChildPaint(self: *Host) void {
        const controls = [_]?HWND{
            self.new_tab_hwnd,
            self.overflow_hwnd,
            self.overlay_label_hwnd,
            self.overlay_edit_hwnd,
            self.overlay_hint_hwnd,
            self.overlay_preview_hwnd,
            self.overlay_accept_hwnd,
            self.overlay_cancel_hwnd,
            self.palette_list_hwnd,
        };
        for (controls) |maybe_hwnd| {
            if (maybe_hwnd) |h| _ = sys.InvalidateRect(h, null, 0);
        }
        for (self.tabs.items) |*t| {
            if (t.button_hwnd) |h| {
                _ = sys.InvalidateRect(h, null, 0);
            }
        }
    }

    fn updateChromeChildPaintNow(self: *Host) void {
        const controls = [_]?HWND{
            self.new_tab_hwnd,
            self.overflow_hwnd,
            self.overlay_label_hwnd,
            self.overlay_edit_hwnd,
            self.overlay_hint_hwnd,
            self.overlay_preview_hwnd,
            self.overlay_accept_hwnd,
            self.overlay_cancel_hwnd,
            self.palette_list_hwnd,
        };
        for (controls) |maybe_hwnd| {
            if (maybe_hwnd) |h| {
                if (sys.IsWindowVisible(h) != 0) _ = sys.UpdateWindow(h);
            }
        }
        for (self.tabs.items) |*t| {
            if (t.button_hwnd) |h| {
                if (sys.IsWindowVisible(h) != 0) _ = sys.UpdateWindow(h);
            }
        }
    }

    fn redrawHostWindowNow(self: *Host) void {
        const hwnd = self.hwnd orelse return;
        const flags = hostCompositionRedrawFlags();
        if (sys.RedrawWindow(hwnd, null, null, flags) == 0) {
            _ = sys.UpdateWindow(hwnd);
        }
    }

    pub fn forceHostCompositionPaint(self: *Host) void {
        self.repaintFullHost();
        self.invalidateChromeChildPaint();
        self.redrawHostWindowNow();
        self.updateChromeChildPaintNow();
    }

    pub fn forceOverlayTransitionPaint(self: *Host) void {
        self.forceHostCompositionPaint();
    }

    pub const applyDpiChangeToVisibleSurfaces = surface_presentation.applyDpiChangeToVisibleSurfaces;

    pub const syncVisibleSurfaceCoreSizesFromClientRects = surface_presentation.syncVisibleSurfaceCoreSizesFromClientRects;

    pub const forceVisibleSurfaceRepaintsNow = surface_presentation.forceVisibleSurfaceRepaintsNow;

    pub const invalidateVisibleSurfaceChildPaint = surface_presentation.invalidateVisibleSurfaceChildPaint;

    pub const freeCachedChromeStrings = chrome_scene.HostScene.freeCachedChromeStrings;

    pub fn syncWindowTitle(self: *Host) !bool {
        const hwnd = self.hwnd orelse return false;
        const alloc = self.app.core_app.alloc;
        const surface = self.activeSurface();
        const host_base_title = try buildHostAwareBaseTitle(
            alloc,
            if (surface) |active|
                if (active.effectiveTitle()) |value| value else null
            else
                null,
            if (surface) |active|
                self.app.hostTabStatus(active)
            else
                .{ .index = 0, .total = 1 },
            self.app.is_elevated,
        );
        defer alloc.free(host_base_title);
        // The bell glyph is display only: `cached_window_title` stays the
        // title without it, which is what automation reports.
        const bell = if (self.activeTab()) |tab| tab.bellRinging() else false;
        if (!windowTitleSyncChanged(self.cached_window_title, host_base_title) and
            bell == self.caption_bell) return false;
        const caption = if (bell) try win32_bell.withTitleGlyph(alloc, host_base_title) else null;
        defer if (caption) |value| alloc.free(value);
        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, caption orelse host_base_title);
        defer alloc.free(title_w);
        // Everything that can fail has run: the caches below describe what
        // the caption shows only once it shows it, so a failure above leaves
        // the next sync to retry, glyph included.
        try appendOwnedString(alloc, &self.cached_window_title, host_base_title);
        self.caption_bell = bell;
        _ = sys.SetWindowTextW(hwnd, title_w.ptr);
        return true;
    }

    pub fn syncTabButtons(self: *Host) !bool {
        return self.syncTabButtonsWithLayout(true);
    }

    fn syncTabButtonsWithLayout(self: *Host, relayout: bool) !bool {
        const hwnd = self.hwnd orelse return false;
        try self.ensureChromeButtons();
        // Same rect `layout` uses, so a title change while minimized does not
        // cut every label down to a 0 px strip that survives the restore.
        const rect = (try self.layoutClientRect()) orelse return false;
        const button_width = self.tabStripGeometry(@max(0, rect.right - rect.left)).button_width;
        const label_max_width = hostTabLabelMaxWidth(button_width, self.current_dpi);
        var tooltip_title_changed = false;
        var button_created = false;
        // A pass that fails after making a button has still changed the list,
        // and the next pass has no new button to say so.
        errdefer if (button_created) self.notifyTabListUiaChanged();
        for (self.tabs.items, 0..) |*tab, i| {
            const surface = tab.focusedSurface() orelse continue;
            const title = if (surface.effectiveTitle()) |value| value else null;
            const active = i == self.active_tab;
            const bell = tab.bellRinging();
            const pane_count = tab.leafCount();
            const show_pane_count = shouldShowPaneCount(button_width, pane_count, self.current_dpi);
            // A program status badge takes its slot out of the label's room,
            // charged in cells after `hostTabLabelMaxWidth` has capped the
            // budget the way the layout caps the button.
            const tab_label_max_width = if (tab.status_indicator == .none)
                label_max_width
            else
                @max(tab_label_min_cells, label_max_width -| tab_status_badge_cells);
            const title_unchanged = if (title) |value|
                ownedStringEquals(tab.cached_button_title, value)
            else
                tab.cached_button_title == null;
            const label_inputs_unchanged = tab.button_hwnd != null and
                tab.button_label_cache_valid and
                title_unchanged and
                tab.cached_button_bell == bell and
                tab.cached_button_index == i and
                tab.cached_button_active == active and
                tab.cached_button_pane_count == pane_count and
                tab.cached_button_label_max_width == tab_label_max_width and
                tab.cached_button_show_pane_count == show_pane_count;
            if (label_inputs_unchanged) continue;
            // The UIA name is not the drawn label: it carries the tab's FULL
            // title and its pane count, and `shouldShowPaneCount` keeps the
            // count out of the label on a narrow tab. Splitting such a tab
            // moves the name from "1: pwsh" to "1: pwsh (2)" while the label
            // stays byte-identical, so the label comparison below cannot be
            // the only trigger for NameChanged or an event-driven reader keeps
            // announcing the stale name.
            const uia_name_changed = tab.button_label_cache_valid and
                labels.tabItemUiaNameChanged(
                    tab.cached_button_title,
                    tab.cached_button_index,
                    tab.cached_button_pane_count,
                    title,
                    i,
                    pane_count,
                );
            if (self.tab_tooltip_tab_id) |shown| {
                // The title or the width budget moved under the tooltip. It is
                // refreshed in place once the buttons are laid out below, since
                // the popup hangs off the button's final rect. Hiding it here
                // made an animated title flicker the popup: `refreshTabTooltip`.
                if (shown == tab.id) tooltip_title_changed = !title_unchanged;
            }
            // The glyph is in front of the drawn label, and its width comes out
            // of the label's budget; the cached title (tooltip, UIA name,
            // palette) and the pane's own title stay without it.
            const label = try win32_bell.tabLabel(
                self.app.core_app.alloc,
                title,
                bell,
                i,
                active,
                pane_count,
                tab_label_max_width,
                show_pane_count,
            );
            defer self.app.core_app.alloc.free(label);
            const is_new_button = tab.button_hwnd == null;
            const label_changed = is_new_button or
                !ownedStringEquals(tab.cached_button_label, label);
            if (is_new_button) {
                try appendOwnedString(self.app.core_app.alloc, &tab.cached_button_label, label);
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, label);
                defer self.app.core_app.alloc.free(label_w);
                tab.button_hwnd = sys.CreateWindowExW(
                    0,
                    prompt_button_class,
                    label_w.ptr,
                    c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_OWNERDRAW,
                    0,
                    0,
                    100,
                    host_tab_height - 8,
                    hwnd,
                    @ptrFromInt(1000 + i),
                    self.app.hinstance,
                    null,
                ) orelse return lastError();
                self.subclassButton(tab.button_hwnd.?, &tabButtonProc, &tab.button_prev_proc);
                tab.uia_provider = self.createChromeUiaProvider(tab.button_hwnd.?, self.tabItemUiaState(tab.id));
                button_created = true;
            } else if (label_changed) {
                try appendOwnedString(self.app.core_app.alloc, &tab.cached_button_label, label);
                const label_w = try std.unicode.utf8ToUtf16LeAllocZ(self.app.core_app.alloc, label);
                defer self.app.core_app.alloc.free(label_w);
                _ = sys.SetWindowTextW(tab.button_hwnd.?, label_w.ptr);
            }
            // Commit the cached name inputs BEFORE raising NameChanged.
            // `events.raiseCurrentStringPropertyChanged` queries the provider
            // for the property synchronously and publishes that string as the
            // event's `newValue`, and `tabItemUiaName` builds it from
            // `cached_button_title`, so raising first announced the PREVIOUS
            // title -- the one the rename was replacing.
            try appendOwnedString(self.app.core_app.alloc, &tab.cached_button_title, title);
            tab.cached_button_bell = bell;
            tab.cached_button_index = i;
            tab.cached_button_active = active;
            tab.cached_button_pane_count = pane_count;
            tab.cached_button_label_max_width = tab_label_max_width;
            tab.cached_button_show_pane_count = show_pane_count;
            tab.button_label_cache_valid = true;
            // A provider created above already reports the current name; only
            // an existing one needs the event. A hidden strip needs none of
            // them: its buttons are out of the UIA tree, and a reader that
            // cannot see the element has nothing to re-announce (#244). The
            // cached inputs above are still committed, so the labels are
            // correct the moment the strip comes back.
            if (!is_new_button and
                (label_changed or uia_name_changed) and
                self.shouldShowTabBar())
            {
                if (tab.uia_provider) |provider| provider.raiseNameChanged();
            }
        }
        var chrome_changed = false;
        if (relayout or button_created) _ = self.layoutChromeForRect(rect, &chrome_changed);
        // Every way a tab joins the strip (a new tab or window, a restored
        // session, an undo, a tab moved in) ends in a button made here, and
        // none of them has to change the selection. Told once, after the
        // layout, so the reader finds each button where it is.
        if (button_created) self.notifyTabListUiaChanged();
        // Refresh whenever a tooltip is up, not only when its own tab's label
        // was rebuilt: a tab that scrolls out of `visibleTabRange` because
        // ANOTHER tab was activated keeps every label input and is never
        // rebuilt, yet its button is now hidden and its slot belongs to a
        // different tab. `presentTabTooltip` re-checks the button and the
        // pointer and takes the popup down when either moved; a refresh that
        // changes nothing it shows is a no-op.
        if (self.tab_tooltip_tab_id != null) self.refreshTabTooltip(tooltip_title_changed);
        return chrome_changed;
    }

    fn syncChromeButtons(self: *Host) !void {
        try self.ensureChromeButtons();
    }

    const TabStripGeometry = struct {
        /// The tabs shown, as `visibleTabRange` picks them.
        start: usize,
        count: usize,
        button_width: i32,
    };

    /// Which tabs the strip shows in a client area `width` px wide, and how
    /// wide each tab button is. `syncTabButtons` budgets the labels to the
    /// same width `layoutChromeForRect` gives the buttons.
    fn tabStripGeometry(self: *const Host, width: i32) TabStripGeometry {
        // When integrated titlebar is active, reserve the rightmost
        // 3 × caption_button_w pixels for min/max/close so the
        // [+][▾] cluster and tab strip don't collide with them.
        const tab_area_width = @max(1, width - self.rightButtonsWidth() - self.captionButtonsWidth());
        const range = visibleTabRange(self.tabs.items.len, self.active_tab, tab_area_width, self.current_dpi);
        const visible_count = @max(@as(i32, 1), @as(i32, @intCast(range.count)));
        return .{
            .start = range.start,
            .count = range.count,
            .button_width = @min(@max(1, @divTrunc(tab_area_width, visible_count)), self.scaled(host_tab_max_button_width)),
        };
    }

    pub fn layoutChromeForRect(self: *Host, rect: RECT, changed: *bool) bool {
        const width = @max(0, rect.right - rect.left);
        const caption_buttons_w = self.captionButtonsWidth();
        const tab_strip = self.tabStripGeometry(width);
        const button_width = tab_strip.button_width;
        const tab_placement = chrome_layout.tabButtonPlacement(self.tabBarHeight(), self.current_dpi, self.tabsFlushWithTop());
        const button_y = tab_placement.top;
        const button_height = tab_placement.height;
        // `window-show-tab-bar = never` gives the strip zero height, but every
        // tab-strip child is a real HWND that keeps whatever visibility it was
        // created with, so laying them out unconditionally collapsed the tab
        // buttons and the [+] / [▾] cluster to `button_height == 1` at the top
        // of the client area, where they still painted their own background
        // and the active tab's border over the terminal (#244). Decide the
        // strip's visibility once and gate every child that belongs to it.
        const tab_strip_visible = self.shouldShowTabBar();
        if (!tab_strip_visible) self.tab_wheel_steps = .{};
        for (self.tabs.items, 0..) |*tab, i| {
            if (tab.button_hwnd) |button_hwnd| {
                if (tabStripChildVisible(
                    tab_strip_visible,
                    i >= tab_strip.start and i < tab_strip.start + tab_strip.count,
                )) {
                    const visible_index: i32 = @intCast(i - tab_strip.start);
                    const tab_left = visible_index * button_width;
                    changed.* = applyChromeChildRect(
                        button_hwnd,
                        &tab.button_placement,
                        childRect(
                            tab_left,
                            button_y,
                            button_width,
                            button_height,
                        ),
                    ) or changed.*;
                    changed.* = applyChildVisibility(button_hwnd, &tab.button_placement, true) or changed.*;
                } else {
                    changed.* = applyChildVisibility(button_hwnd, &tab.button_placement, false) or changed.*;
                }
            }
        }

        // The band paints the active tab's join to its terminal under the
        // button just placed. A hidden strip has none, so a tab switch with
        // the tab bar off repaints nothing in the band.
        self.syncTabJoin();

        // The tab-strip Selection container is an invisible, hit-transparent
        // child that exists only so UIA has one element to hang ControlType
        // Tab and the Selection pattern on (the tab buttons are siblings, not
        // children, of it — they stay parented to the host so layout, drag
        // and drop, and overflow are untouched). Give it the strip's real
        // rect so a screen reader reading by position lands on the tabs
        // rather than on a degenerate box at the window origin.
        if (self.tab_container_hwnd) |container_hwnd| {
            const visible_tabs: i32 = @intCast(tab_strip.count);
            if (tabStripChildVisible(tab_strip_visible, visible_tabs > 0)) {
                changed.* = applyChromeChildRect(
                    container_hwnd,
                    &self.tab_container_placement,
                    childRect(
                        0,
                        button_y,
                        visible_tabs * button_width,
                        button_height,
                    ),
                ) or changed.*;
                changed.* = applyChildVisibility(container_hwnd, &self.tab_container_placement, true) or changed.*;
            } else {
                changed.* = applyChildVisibility(container_hwnd, &self.tab_container_placement, false) or changed.*;
            }
        }

        // Right-side cluster: [+][▾] — new tab and dropdown chevron.
        // Shift left by the caption-buttons reservation (0 on Win10)
        // so the chevron doesn't land under the close button.
        const titlebar_actions = self.usingIntegratedTitlebar();
        const action_size = self.scaled(host_titlebar_action_button_size);
        const action_y = @max(0, @divTrunc(self.tabBarHeight() - action_size, 2));
        const compact_action = chrome_layout.tabButtonPlacement(self.tabBarHeight(), self.current_dpi, false);
        var button_x = width - self.scaled(if (titlebar_actions) 4 else 8) - caption_buttons_w;
        // Unlike a tab button, the cluster has no membership test of its own:
        // it belongs to the strip whenever the strip exists. Its rect is kept
        // current even while hidden, so `showOverflowMenu`, which anchors its
        // popup to `GetWindowRect(overflow_hwnd)`, never reads a rect from an
        // older window size.
        if (self.overflow_hwnd) |button_hwnd| {
            const overflow_width = if (titlebar_actions) action_size else self.scaled(host_tab_overflow_button_width);
            button_x -= overflow_width;
            changed.* = applyChromeChildRect(
                button_hwnd,
                &self.overflow_placement,
                childRect(
                    button_x,
                    if (titlebar_actions) action_y else compact_action.top,
                    overflow_width,
                    if (titlebar_actions) action_size else compact_action.height,
                ),
            ) or changed.*;
            changed.* = applyChildVisibility(
                button_hwnd,
                &self.overflow_placement,
                tabStripChildVisible(tab_strip_visible, true),
            ) or changed.*;
        }
        button_x -= self.scaled(4);
        if (self.new_tab_hwnd) |button_hwnd| {
            const new_tab_width = if (titlebar_actions) action_size else self.scaled(host_tab_small_button_width);
            button_x -= new_tab_width;
            changed.* = applyChromeChildRect(
                button_hwnd,
                &self.new_tab_placement,
                childRect(
                    button_x,
                    if (titlebar_actions) action_y else compact_action.top,
                    new_tab_width,
                    if (titlebar_actions) action_size else compact_action.height,
                ),
            ) or changed.*;
            changed.* = applyChildVisibility(
                button_hwnd,
                &self.new_tab_placement,
                tabStripChildVisible(tab_strip_visible, true),
            ) or changed.*;
        }

        if (self.overlay_mode != .none) {
            const edit_hwnd = self.overlay_edit_hwnd orelse return false;
            const accept_hwnd = self.overlay_accept_hwnd orelse return false;
            const cancel_hwnd = self.overlay_cancel_hwnd orelse return false;
            const bands = self.contentBands(
                self.tabBarHeight(),
                self.scaled(host_overlay_height),
                0,
            );
            const overlay_y = bands.overlay_top;
            const padding = self.scaled(host_overlay_padding);
            const label_w = self.scaled(host_overlay_label_width);
            const accept_button_w = self.scaled(host_overlay_accept_width);
            const cancel_button_w = self.scaled(host_overlay_cancel_width);
            const action_layout = overlayActionLayoutForWidth(
                self.overlay_mode,
                width,
                padding,
                cancel_button_w,
                accept_button_w,
                self.current_dpi,
            );
            const edit_frame = overlayEditFrameRect(
                width,
                overlay_y,
                padding,
                label_w,
                action_layout.cancel_width,
                action_layout.accept_reservation_width,
                self.scaled(host_overlay_row_height),
                self.current_dpi,
            );
            const edit_rect = overlayEditChildRectFromFrame(
                edit_frame,
                self.scaled(overlay_edit_child_inset_x_base),
                self.scaled(overlay_edit_child_inset_y_base),
            );
            changed.* = applyChromeChildRect(
                edit_hwnd,
                &self.overlay_edit_placement,
                edit_rect,
            ) or changed.*;

            // Confirm prompt title and body. Both are real STATICs only
            // in `.confirm` mode -- every other overlay paints its label
            // and feedback line as chrome text and keeps these two
            // hidden, where they still serve as the change detectors
            // `refreshChrome` reads.
            //
            // The rects are the ones chrome paint used for the same two
            // strings, so this is a move of ownership rather than a
            // relayout. Neither rect intersects the terminal Surface:
            // `contentBands` puts the surface at or below
            // `inspector_top`, which is the band's own bottom edge, so
            // unlike the preview pane these children do not need raising
            // above the topmost Surface sibling on the transition to
            // visible.
            const confirm_prompt = self.overlay_mode == .confirm;
            const overlay_bottom = overlay_y + self.scaled(host_overlay_height);
            const panel_interior = overlayPanelInterior(overlay_y, overlay_bottom, self.current_dpi);
            const title_text = if (confirm_prompt)
                confirmTextPlacement(confirmTitlePaintRect(
                    overlay_y,
                    padding + self.scaled(10),
                    edit_frame.right,
                    self.current_dpi,
                ), panel_interior)
            else
                empty_confirm_text_placement;
            const body_text = if (confirm_prompt)
                confirmTextPlacement(confirmBodyPaintRect(
                    width,
                    overlay_y,
                    overlay_bottom,
                    padding,
                    self.current_dpi,
                ), panel_interior)
            else
                empty_confirm_text_placement;
            // Each line stands on its own. The title's rect is bounded by
            // the query frame and collapses before the body's does on a
            // narrow window; gating both on the pair would answer that by
            // taking the body out of the UIA tree as well, leaving the
            // prompt unreachable at exactly the size where it is hardest
            // to read. Chrome paint's fallback is per line to match.
            const show_title = title_text.visible();
            const show_body = body_text.visible();
            if (show_title) self.overlay_label_text = title_text;
            if (show_body) self.overlay_hint_text = body_text;
            if (self.overlay_label_hwnd) |label_hwnd| {
                if (show_title) {
                    changed.* = applyChromeChildRect(
                        label_hwnd,
                        &self.overlay_label_placement,
                        title_text.child,
                    ) or changed.*;
                }
                changed.* = applyChildVisibility(
                    label_hwnd,
                    &self.overlay_label_placement,
                    show_title,
                ) or changed.*;
            }
            if (self.overlay_hint_hwnd) |hint_hwnd| {
                if (show_body) {
                    changed.* = applyChromeChildRect(
                        hint_hwnd,
                        &self.overlay_hint_placement,
                        body_text.child,
                    ) or changed.*;
                }
                changed.* = applyChildVisibility(
                    hint_hwnd,
                    &self.overlay_hint_placement,
                    show_body,
                ) or changed.*;
            }
            if (action_layout.accept_visible) {
                changed.* = applyChromeChildRect(
                    accept_hwnd,
                    &self.overlay_accept_placement,
                    childRect(
                        action_layout.accept_x,
                        overlay_y + self.scaled(4),
                        action_layout.accept_width,
                        self.scaled(host_overlay_row_height),
                    ),
                ) or changed.*;
                changed.* = applyChildVisibility(
                    accept_hwnd,
                    &self.overlay_accept_placement,
                    true,
                ) or changed.*;
            } else {
                changed.* = applyChildVisibility(
                    accept_hwnd,
                    &self.overlay_accept_placement,
                    false,
                ) or changed.*;
            }
            if (action_layout.cancel_visible) {
                changed.* = applyChromeChildRect(
                    cancel_hwnd,
                    &self.overlay_cancel_placement,
                    childRect(
                        action_layout.cancel_x,
                        overlay_y + self.scaled(4),
                        action_layout.cancel_width,
                        self.scaled(host_overlay_row_height),
                    ),
                ) or changed.*;
            }
            changed.* = applyChildVisibility(
                cancel_hwnd,
                &self.overlay_cancel_placement,
                action_layout.cancel_visible,
            ) or changed.*;

            if (self.overlay_mode == .command_palette) {
                if (self.palette_list_hwnd) |list_hwnd| {
                    // Anchor the list directly under the EDIT, left-
                    // aligned with it and right-aligned with the buttons
                    // so it reads as part of the same visual card.
                    const label_reservation = overlayLabelReservation(
                        width,
                        padding,
                        label_w,
                        action_layout.cancel_width,
                        0,
                        self.current_dpi,
                    );
                    const list_x = padding + label_reservation + self.scaled(8);
                    // Keep results below the complete overlay/feedback band.
                    // The old row-height + 12 anchor started at 36 px while
                    // feedback was still painting there and terminal content
                    // began at 58 px, producing the visible overlap reported
                    // in the palette theme screenshot.
                    const list_y = overlay_y + self.scaled(host_overlay_height);
                    const list_width_bounds = paletteListRect(width, list_x, padding, list_y, 0);
                    const has_list_width = paletteListWidthIsReadable(list_width_bounds, self.scaled(160));
                    const row_capacity = if (has_list_width)
                        paletteVisibleRowCapacity(
                            rect.bottom - list_y - self.scaled(8),
                            self.scaled(palette_row_height),
                        )
                    else
                        0;
                    const previous_visible_rows = self.palette_list_visible_rows;
                    self.palette_list_visible_rows = @min(
                        self.palette_list_ranked_count,
                        row_capacity,
                    );
                    const viewport = clampPaletteViewport(
                        self.palette_list_ranked_count,
                        self.palette_list_visible_rows,
                        self.palette_list_selected,
                        self.palette_list_scroll,
                    );
                    self.palette_list_selected = viewport.selected;
                    self.palette_list_scroll = viewport.scroll;
                    if (self.palette_list_visible_rows != previous_visible_rows) {
                        self.invalidateOverlayText();
                    }
                    const visible_rows: i32 = @intCast(self.palette_list_visible_rows);
                    const list_height = @max(
                        self.scaled(palette_row_height),
                        visible_rows * self.scaled(palette_row_height),
                    );
                    changed.* = applyChromeChildRect(
                        list_hwnd,
                        &self.palette_list_placement,
                        paletteListRect(width, list_x, padding, list_y, list_height),
                    ) or changed.*;
                    const show_list = self.palette_list_visible_rows > 0 and has_list_width;
                    if (!show_list) self.palette_wheel_steps = .{};
                    const list_visibility_changed = applyChildVisibility(
                        list_hwnd,
                        &self.palette_list_placement,
                        show_list,
                    );
                    changed.* = list_visibility_changed or changed.*;
                    // The list hangs over the terminal's top rows.
                    if (show_list and list_visibility_changed) {
                        if (self.hwnd) |parent| raiseChildToTop(parent, list_hwnd);
                    }
                }
            } else if (self.palette_list_hwnd) |list_hwnd| {
                self.palette_list_visible_rows = 0;
                self.palette_wheel_steps = .{};
                changed.* = applyChildVisibility(
                    list_hwnd,
                    &self.palette_list_placement,
                    false,
                ) or changed.*;
            }

            // Confirm preview. Anchored under the overlay band exactly like
            // the palette list, and like it the pane overlaps the terminal
            // rather than shrinking it: `contentBands` subtracts only the
            // band, and a confirm is a transient prompt that should not
            // reflow the surface underneath it.
            if (self.overlay_preview_hwnd) |preview_hwnd| {
                const preview_rect = if (self.confirmHasPreview())
                    confirmPreviewRect(
                        width,
                        rect.bottom,
                        overlay_y + self.scaled(host_overlay_height),
                        padding + self.scaled(10),
                        padding,
                        self.current_dpi,
                    )
                else
                    RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
                const show_preview = preview_rect.right > preview_rect.left and
                    preview_rect.bottom > preview_rect.top;
                if (show_preview) {
                    changed.* = applyChromeChildRect(
                        preview_hwnd,
                        &self.overlay_preview_placement,
                        preview_rect,
                    ) or changed.*;
                }
                // Like the palette list, the pane overlaps the terminal
                // (measured: Surface at index 0, this pane at 9), so it is
                // raised over it each time it is shown.
                const preview_visibility_changed = applyChildVisibility(
                    preview_hwnd,
                    &self.overlay_preview_placement,
                    show_preview,
                );
                changed.* = preview_visibility_changed or changed.*;
                if (show_preview and preview_visibility_changed) {
                    if (self.hwnd) |parent| raiseChildToTop(parent, preview_hwnd);
                }
            }
        } else {
            if (self.overlay_label_hwnd) |label_hwnd| {
                changed.* = applyChildVisibility(
                    label_hwnd,
                    &self.overlay_label_placement,
                    false,
                ) or changed.*;
            }
            if (self.overlay_hint_hwnd) |hint_hwnd| {
                changed.* = applyChildVisibility(
                    hint_hwnd,
                    &self.overlay_hint_placement,
                    false,
                ) or changed.*;
            }
            if (self.palette_list_hwnd) |list_hwnd| {
                self.palette_list_visible_rows = 0;
                self.palette_wheel_steps = .{};
                changed.* = applyChildVisibility(
                    list_hwnd,
                    &self.palette_list_placement,
                    false,
                ) or changed.*;
            }
        }

        return true;
    }

    /// Where `layout` puts the pane at `handle` while its tab is active
    /// and not zoomed.
    pub fn splitPanePlacement(
        self: *const Host,
        content_rect: RECT,
        spatial: SplitTreeSurface.Spatial,
        handle: SplitTreeSurface.Node.Handle,
        has_multi_panes: bool,
        search_visible: bool,
    ) win32_layout.SurfacePlacement {
        const slot = spatial.slots[handle.idx()];
        return win32_layout.splitSurfacePlacement(
            .{
                .left = content_rect.left,
                .top = content_rect.top,
                .right = content_rect.right,
                .bottom = content_rect.bottom,
            },
            .{
                .x = @floatCast(slot.x),
                .y = @floatCast(slot.y),
                .width = @floatCast(slot.width),
                .height = @floatCast(slot.height),
            },
            has_multi_panes,
            search_visible,
            self.scaled(host_search_bar_height),
        );
    }

    /// Put `surface` where `placement` says: its docked search frame (or
    /// none), its pane, then what a moved or newly shown pane needs
    /// (`surfaceLayoutRuntimeSync`). A search frame at the top of the
    /// content area pushes `banner_top` below it. Returns whether anything
    /// moved.
    fn applySurfacePlacement(
        surface: *Surface,
        placement: win32_layout.SurfacePlacement,
        content_top: i32,
        visibility_changed: bool,
        banner_top: *i32,
    ) !bool {
        var changed = false;
        if (placement.search_frame_rect) |search_frame_rect| {
            changed = try surface.layoutSearchBarControls(layoutRectToWin32(search_frame_rect), true);
            if (search_frame_rect.top == content_top) banner_top.* = @max(banner_top.*, search_frame_rect.bottom);
        } else {
            changed = surface.hideSearchBarControls();
        }
        var pane_rect_changed = false;
        if (surface.hwnd) |surface_hwnd| {
            pane_rect_changed = applyChildRect(surface_hwnd, &surface.placement, layoutRectToWin32(placement.pane_rect));
        }
        const runtime_sync = surfaceLayoutRuntimeSync(visibility_changed, pane_rect_changed);
        if (runtime_sync.scrollbar_refresh) try surface.refreshScrollbarWindow();
        if (runtime_sync.core_size_sync) surface.syncCoreSizeFromClientRect();
        return changed or pane_rect_changed;
    }

    /// Tell every pane whether the renderer dims it as an unfocused split
    /// (`win32_chrome_state.splitDimmed`), in every tab, so a background
    /// tab is right when it shows. It follows `tab.focused`, the split the
    /// tab has selected, not keyboard focus: an inactive window keeps its
    /// focused split undimmed, as upstream does. Called wherever
    /// `tab.focused` or the split tree changes (`layout`, the activation
    /// and focus funnels, `App.followShellFocus`) and from
    /// `App.reconfigureTheme` for High Contrast.
    pub fn syncSplitDim(self: *Host) void {
        const high_contrast = isHighContrastActive();
        for (self.tabs.items) |*tab| {
            const pane_count = tab.leafCount();
            var it = tab.tree.iterator();
            while (it.next()) |entry| {
                const selected = entry.handle == tab.focused or
                    (if (tab.tree.zoomed) |zoomed| entry.handle == zoomed else false);
                entry.view.setSplitDimmed(win32_chrome_state.splitDimmed(pane_count, selected, high_contrast));
            }
        }
    }

    test "only unfocused splits of a two-pane tab are dimmed" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        if (isHighContrastActive()) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface_a: Surface = undefined;
        var surface_b: Surface = undefined;
        var surface_c: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{
                .{ .storage = &surface_a, .host = &host, .register = true },
                .{ .storage = &surface_b, .host = &host },
                .{ .storage = &surface_c, .host = &host, .register = true },
            },
            .tabs = &.{.{ .host = &host, .surface = &surface_a, .id = 1 }},
        });
        defer session.deinit();

        // Tab 1 is [A | B] with A selected; tab 2 holds C alone.
        const inserted = try SplitTreeSurface.init(std.testing.allocator, &surface_b);
        defer {
            var cleanup = inserted;
            cleanup.deinit();
        }
        const next_tree = try host.tabs.items[0].tree.split(std.testing.allocator, .root, .right, 0.5, &inserted);
        host.tabs.items[0].tree.deinit();
        host.tabs.items[0].tree = next_tree;
        host.tabs.items[0].focused = host.tabs.items[0].findHandle(&surface_a).?;
        try host.tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &surface_c));

        host.syncSplitDim();
        try std.testing.expect(!surface_a.split_dimmed);
        try std.testing.expect(surface_b.split_dimmed);
        try std.testing.expect(!surface_c.split_dimmed);

        // Focus moving to B within the tab swaps them.
        _ = app.noteSurfaceFocused(&surface_b);
        try std.testing.expect(surface_a.split_dimmed);
        try std.testing.expect(!surface_b.split_dimmed);

        // The keyboard leaving (an inactive window) keeps B, the split the
        // tab has selected, undimmed.
        surface_b.focusChanged(false);
        try std.testing.expect(!surface_b.split_dimmed);

        // A no-focus activation, as a docked search edit taking focus does.
        app.activateSurfaceNoFocus(&surface_a);
        try std.testing.expect(!surface_a.split_dimmed);
        try std.testing.expect(surface_b.split_dimmed);

        // A zoomed pane shows alone and is never dimmed.
        host.tabs.items[0].tree.zoom(host.tabs.items[0].findHandle(&surface_b).?);
        host.syncSplitDim();
        try std.testing.expect(!surface_b.split_dimmed);
        host.tabs.items[0].tree.zoom(null);

        // One pane left: nothing to compare it with.
        const alone = try host.tabs.items[0].tree.remove(std.testing.allocator, host.tabs.items[0].findHandle(&surface_b).?);
        host.tabs.items[0].tree.deinit();
        host.tabs.items[0].tree = alone;
        host.tabs.items[0].focused = host.tabs.items[0].findHandle(&surface_a).?;
        surface_a.split_dimmed = true;
        host.syncSplitDim();
        try std.testing.expect(!surface_a.split_dimmed);
        // A surface without a started core tells no renderer yet.
        try std.testing.expect(!surface_b.split_dimmed_sent);
    }

    pub fn layout(self: *Host) !void {
        // Every structural change ends in a layout, including the ones that
        // fail or return before placing panes.
        defer self.syncSplitDim();
        const rect = (try self.layoutClientRect()) orelse return;
        var chrome_layout_changed = false;
        if (!self.layoutChromeForRect(rect, &chrome_layout_changed)) return;
        // Resize and DPI changes also change label truncation and tooltip policy.
        if (chrome_layout_changed) _ = chromeSyncOrLog("layout tab label sync failed", self.syncTabButtonsWithLayout(false));

        const content_rect = self.contentRectFromClient(rect);
        const layout_content_rect: win32_layout.Rect = .{
            .left = content_rect.left,
            .top = content_rect.top,
            .right = content_rect.right,
            .bottom = content_rect.bottom,
        };
        const search_bar_height = self.scaled(host_search_bar_height);
        // A host whose last tab is detached for undo still shows its banner.
        const active_tab = self.activeTab() orelse return self.layoutBanner(content_rect, content_rect.top);
        var content_layout_changed = false;
        // The banner goes below a docked search frame at the top of the
        // content area rather than over the search field.
        var banner_top = content_rect.top;

        // Hide non-active child GL surfaces before showing the active tab.
        // Briefly overlapping multiple WGL child windows under one host can
        // crash the NVIDIA present path when tabs are opened repeatedly.
        self.prepareActiveTabVisibility(self.active_tab);

        if (active_tab.tree.zoomed) |zoomed| {
            // The other panes go first, as the other tabs do above: moving the
            // zoom shows a pane that may come before the old one in the tree,
            // and two GL child windows must not overlap, even within this pass.
            var hiding = active_tab.tree.iterator();
            while (hiding.next()) |entry| {
                if (entry.handle == zoomed) continue;
                const visibility_changed = entry.view.window_visible;
                content_layout_changed = content_layout_changed or visibility_changed;
                entry.view.setVisible(false);
                content_layout_changed = entry.view.hideSearchBarControls() or content_layout_changed;
                if (visibility_changed) {
                    try entry.view.refreshScrollbarWindow();
                }
            }
            var it = active_tab.tree.iterator();
            while (it.next()) |entry| {
                if (entry.handle != zoomed) continue;
                const batch = entry.view.beginCoreResizeBatch();
                defer entry.view.endCoreResizeBatch(batch);
                const visibility_changed = !entry.view.window_visible;
                content_layout_changed = content_layout_changed or visibility_changed;
                entry.view.setVisible(true);
                const placement = win32_layout.zoomedSurfacePlacement(
                    layout_content_rect,
                    entry.view.search_bar.visible,
                    search_bar_height,
                );
                content_layout_changed = (try applySurfacePlacement(
                    entry.view,
                    placement,
                    content_rect.top,
                    visibility_changed,
                    &banner_top,
                )) or content_layout_changed;
                entry.view.syncContentScaleToHostDpi();
            }
        } else {
            var spatial = try active_tab.tree.spatial(self.app.core_app.alloc);
            defer spatial.deinit(self.app.core_app.alloc);
            const has_multi_panes = active_tab.leafCount() > 1;
            // Panes already on screen are placed before the hidden ones are
            // shown: leaving a zoom, the zoomed pane shrinks to its slot first,
            // so the others do not come up over it.
            for ([_]bool{ true, false }) |on_screen| {
                var it = active_tab.tree.iterator();
                while (it.next()) |entry| {
                    if (entry.view.window_visible != on_screen) continue;
                    const batch = entry.view.beginCoreResizeBatch();
                    defer entry.view.endCoreResizeBatch(batch);
                    const visibility_changed = !entry.view.window_visible;
                    content_layout_changed = content_layout_changed or visibility_changed;
                    if (entry.view.hwnd != null) {
                        const placement = self.splitPanePlacement(
                            content_rect,
                            spatial,
                            entry.handle,
                            has_multi_panes,
                            entry.view.search_bar.visible,
                        );
                        content_layout_changed = (try applySurfacePlacement(
                            entry.view,
                            placement,
                            content_rect.top,
                            visibility_changed,
                            &banner_top,
                        )) or content_layout_changed;
                    }
                    // In its slot first: shown at the rect it had before, a pane
                    // that came out of a zoom would cover its neighbours.
                    entry.view.setVisible(true);
                    entry.view.syncContentScaleToHostDpi();
                }
            }
        }
        self.layoutBanner(content_rect, banner_top);

        if (chrome_layout_changed or content_layout_changed) {
            // Batch-invalidate after actual positioning/visibility changes.
            self.repaintFullHost();
            const child_paint = layoutChildPaintPlan(chrome_layout_changed, content_layout_changed);
            if (child_paint.chrome) self.invalidateChromeChildPaint();
            if (child_paint.content or child_paint.native_content_controls) {
                self.invalidateVisibleSurfaceChildPaint(
                    child_paint.content,
                    child_paint.native_content_controls,
                );
            }
        }
    }

    pub const drawTitlebarGlyph = chrome_scene.HostScene.drawTitlebarGlyph;

    pub const paintCaptionButton = chrome_scene.HostScene.paintCaptionButton;

    pub const paintCaptionButtons = chrome_scene.HostScene.paintCaptionButtons;

    pub const paintChromeTabBar = chrome_scene.HostScene.paintChromeTabBar;

    pub const paintChromeOverlay = chrome_scene.HostScene.paintChromeOverlay;

    pub const paintChromeContentLane = chrome_scene.HostScene.paintChromeContentLane;

    pub const paintChromeInspectorPanel = chrome_scene.HostScene.paintChromeInspectorPanel;

    pub const paintChromePaneDividers = chrome_scene.HostScene.paintChromePaneDividers;

    pub const paintChrome = chrome_scene.HostScene.paintChrome;
};

test "win32 only a close in the window in front takes focus" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var host: Host = undefined;
    host.active_tab = 1;
    host.hwnd = null;
    try std.testing.expect(!tabSeenWithForeground(&host, 1, null));
    const hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(hwnd);
    host.hwnd = hwnd;
    try std.testing.expect(tabSeenWithForeground(&host, 1, hwnd));
    // A background tab, or a window that is not in front.
    try std.testing.expect(!tabSeenWithForeground(&host, 0, hwnd));
    try std.testing.expect(!tabSeenWithForeground(&host, 1, null));
    // A minimized window, even one Windows still calls the foreground
    // (the style bit is what IsIconic reads; the window is never shown).
    _ = sys.SetWindowLongPtrW(hwnd, c.GWL_STYLE, @bitCast(@as(usize, c.WS_POPUP | c.WS_MINIMIZE)));
    try std.testing.expect(!tabSeenWithForeground(&host, 1, hwnd));
}

test "win32 settings patch persists a palette theme selection" {
    const testing = std.testing;
    const ConfigKey = @import("../../config/key.zig").Key;
    var pending = try configpkg.Config.default(testing.allocator);
    defer pending.deinit();
    try Host.setConfigTheme(&pending, "0x96f");

    var edited: std.StaticBitSet(std.enums.values(ConfigKey).len) = .initEmpty();
    edited.set(@intFromEnum(ConfigKey.theme));
    var patched: std.ArrayListUnmanaged(u8) = .{};
    defer patched.deinit(testing.allocator);
    try patchOrAppendEdits(
        testing.allocator,
        "theme = Dracula\nwindow-save-state = never\n",
        &pending,
        edited,
        &patched,
    );
    try testing.expect(std.mem.indexOf(u8, patched.items, "theme = 0x96f") != null);
    try testing.expect(std.mem.indexOf(u8, patched.items, "window-save-state = never") != null);
}

/// Which `hostButtonProc` button the shared tooltip popup is up for, and which
/// one a click keeps it down for. It holds no windows, so the order of hovers,
/// clicks and leaves that decides whether a tooltip comes back can be tested
/// without the popup or the real cursor.
const ButtonTooltip = struct {
    /// The button the popup describes. At most one of this and
    /// `Host.tab_tooltip_tab_id` is set.
    shown: ?HWND = null,
    /// The last clicked button, whether or not its tooltip was up, until the
    /// pointer leaves it or it is hidden or destroyed. Its tooltip stays down
    /// meanwhile, as a stock Windows tooltip stays down after a click until
    /// the pointer leaves the tool.
    dismissed: ?HWND = null,

    const Effect = enum { none, present, hide };

    /// Record `action` on `button` and say what it does to the popup. The
    /// caller makes `shown` follow: presenting sets it, hiding clears it.
    pub fn apply(self: *ButtonTooltip, action: ButtonTooltipAction, button: HWND) Effect {
        switch (action) {
            .none => return .none,
            .show => {
                if (self.dismissed == button) return .none;
                // The hover timer re-arms on every pointer move inside the
                // button, so this fires repeatedly while the tooltip is up.
                if (self.shown == button) return .none;
                return .present;
            },
            .dismiss => self.dismissed = button,
            .hide => {
                if (self.dismissed == button) self.dismissed = null;
            },
        }
        return if (self.shown == button) .hide else .none;
    }
};

test "win32 a palette theme preview drops the startup launch-layout it parses again" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "preview-theme", .data = "background = #102030\n" });
    const theme = try tmp.dir.realpathAlloc(alloc, "preview-theme");
    defer alloc.free(theme);

    // What `loadPaletteThemeConfig` has before it finishes: the command line,
    // parsed again, with the startup `--launch-layout` in it.
    var preview = try configpkg.Config.default(alloc);
    defer preview.deinit();
    var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{
        .iterator = cli_args.sliceIterator(&.{"--launch-layout=shot"}),
    };
    try preview.loadIter(alloc, &args);
    var running = try configpkg.Config.default(alloc);
    defer running.deinit();
    try Host.finishPaletteThemeConfig(&preview, &running, theme);
    // The theme loaded, so `finalize` replayed the command line over it.
    try std.testing.expectEqual(@as(u8, 0x10), preview.background.r);
    // `swapRuntimeConfigFromPalette` installs this as the app config, which
    // a `new_window` clones while the preview is live.
    try testExpectNoLaunchLayout(&preview);
}

test "win32 a palette theme preview keeps the running profile definitions until a reload" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "preview-theme", .data = "background = #102030\n" });
    const theme = try tmp.dir.realpathAlloc(alloc, "preview-theme");
    defer alloc.free(theme);

    // The running config, which the hosts' lists were built from.
    var running = try configpkg.Config.default(alloc);
    defer running.deinit();
    var running_args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{
        .iterator = cli_args.sliceIterator(&.{ "--profile-command=x: old.exe", "--profile-env=x: MODE=old", "--ssh-config-hosts=false" }),
    };
    try running.loadIter(alloc, &running_args);
    try running.finalize();

    // The files read again for the preview, edited since.
    const edited = [_][]const u8{ "--profile-command=x: new.exe", "--profile-name=x: New", "--profile-env=x: MODE=new" };
    var preview = try configpkg.Config.default(alloc);
    defer preview.deinit();
    var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(&edited) };
    try preview.loadIter(alloc, &args);
    try Host.finishPaletteThemeConfig(&preview, &running, theme);

    // The theme changed; what the profile lists come from did not.
    try std.testing.expectEqual(@as(u8, 0x10), preview.background.r);
    try std.testing.expect(!preview.@"ssh-config-hosts");
    try std.testing.expect(!userProfileKeysChanged(&running, &preview));
    try std.testing.expectEqualStrings("old.exe", preview.@"profile-command".get("x").?);
    // And where they were read, which New Elevated Window decides by: the
    // running config's places, not the edited files' (the env line is the
    // second argument there, the third here).
    try std.testing.expectEqual(running.profilePlace("profile-env", "x").cli, preview.profilePlace("profile-env", "x").cli);

    // The next reload, which reads the edited files, sees the change and
    // drops the lists (the `config_change` path).
    var reloaded = try configpkg.Config.default(alloc);
    defer reloaded.deinit();
    var reload_args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(&edited) };
    try reloaded.loadIter(alloc, &reload_args);
    try reloaded.finalize();
    try std.testing.expect(userProfileKeysChanged(&preview, &reloaded));
}

test "win32 a palette theme preview keeps the default-profile launch until a reload" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "preview-theme", .data = "background = #102030\n" });
    const theme = try tmp.dir.realpathAlloc(alloc, "preview-theme");
    defer alloc.free(theme);

    const Launch = struct {
        fn expect(config: *const configpkg.Config, line: []const u8, mode: []const u8) !void {
            var clone = config.shallowClone(std.testing.allocator);
            defer clone.deinit();
            _ = (try applyDefaultProfileConfig(&clone)).?;
            try std.testing.expectEqualStrings(line, clone._profile_launch.?.command_line);
            try std.testing.expectEqualStrings(mode, clone.env.map.get("MODE").?);
        }
    };

    // The running config: `default-profile = py`, resolved.
    var running = try configpkg.Config.default(alloc);
    defer running.deinit();
    var running_args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{
        .iterator = cli_args.sliceIterator(&.{ "--profile-command=py: old.exe", "--profile-env=py: MODE=old", "--default-profile=py" }),
    };
    try running.loadIter(alloc, &running_args);
    try running.finalize();
    try Launch.expect(&running, "old.exe", "old");

    // The files read again for the preview: the same `default-profile`
    // with its profile edited since, and one that names another profile.
    inline for (.{
        &[_][]const u8{ "--profile-command=py: new.exe", "--profile-env=py: MODE=new", "--default-profile=py" },
        &[_][]const u8{ "--profile-command=py: old.exe", "--profile-env=py: MODE=old", "--profile-command=other: other.exe", "--default-profile=other" },
    }) |edited| {
        var preview = try configpkg.Config.default(alloc);
        defer preview.deinit();
        var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(edited) };
        try preview.loadIter(alloc, &args);
        try Host.finishPaletteThemeConfig(&preview, &running, theme);
        try std.testing.expectEqual(@as(u8, 0x10), preview.background.r);
        // A new tab runs the definition the lists hold: the running one.
        try std.testing.expectEqualStrings("old.exe", preview.@"profile-command".get("py").?);
        try std.testing.expectEqualStrings("py", preview.@"default-profile".?);
        try Launch.expect(&preview, "old.exe", "old");
        try std.testing.expect(!userProfileKeysChanged(&running, &preview));
    }

    // With no `default-profile` running, files that add one start nothing
    // new before the reload either.
    var plain = try configpkg.Config.default(alloc);
    defer plain.deinit();
    try plain.finalize();
    var added = try configpkg.Config.default(alloc);
    defer added.deinit();
    var added_args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{
        .iterator = cli_args.sliceIterator(&.{ "--profile-command=py: new.exe", "--default-profile=py" }),
    };
    try added.loadIter(alloc, &added_args);
    try Host.finishPaletteThemeConfig(&added, &plain, theme);
    try std.testing.expect(added._default_profile == null);
    try std.testing.expect(added.command == null);
    var clone = added.shallowClone(alloc);
    defer clone.deinit();
    try std.testing.expect(try applyDefaultProfileConfig(&clone) == null);

    // What Settings reads of the running value stays too: a command-line
    // value the lookup found nothing for, over the files' own, while the
    // files read again for the preview say nothing about it.
    try tmp.dir.writeFile(.{ .sub_path = "running.ghostty", .data = "default-profile = pwsh\n" });
    try tmp.dir.writeFile(.{ .sub_path = "reread.ghostty", .data = "font-size = 13\n" });
    const running_path = try tmp.dir.realpathAlloc(alloc, "running.ghostty");
    defer alloc.free(running_path);
    const reread_path = try tmp.dir.realpathAlloc(alloc, "reread.ghostty");
    defer alloc.free(reread_path);
    var missing = try configpkg.Config.default(alloc);
    defer missing.deinit();
    try missing.loadFile(alloc, running_path);
    var missing_args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(&.{"--default-profile=nosuch"}) };
    try missing.loadIter(alloc, &missing_args);
    try missing.finalize();
    try std.testing.expectEqual(configpkg.Config.DefaultProfileFailure.not_found, missing._default_profile_failure);
    try std.testing.expectEqualStrings("pwsh", missing.defaultProfileFromFiles().?);
    var reread = try configpkg.Config.default(alloc);
    defer reread.deinit();
    try reread.loadFile(alloc, reread_path);
    try Host.finishPaletteThemeConfig(&reread, &missing, theme);
    try std.testing.expectEqualStrings("nosuch", reread.@"default-profile".?);
    try std.testing.expectEqual(configpkg.Config.DefaultProfileFailure.not_found, reread._default_profile_failure);
    try std.testing.expectEqualStrings("pwsh", reread.defaultProfileFromFiles().?);
}

test "win32 failed cloned-host registration detaches the host reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var first: Host = undefined;
    var failed_clone: Host = undefined;
    var last: Host = undefined;
    var hosts: std.ArrayListUnmanaged(*Host) = .empty;
    defer hosts.deinit(std.testing.allocator);
    try hosts.append(std.testing.allocator, &first);
    try hosts.append(std.testing.allocator, &failed_clone);
    try hosts.append(std.testing.allocator, &last);

    try std.testing.expect(detachHostReference(&hosts, &failed_clone));
    try std.testing.expectEqual(@as(usize, 2), hosts.items.len);
    try std.testing.expect(std.mem.indexOfScalar(*Host, hosts.items, &failed_clone) == null);
    try std.testing.expect(std.mem.indexOfScalar(*Host, hosts.items, &first) != null);
    try std.testing.expect(std.mem.indexOfScalar(*Host, hosts.items, &last) != null);
    try std.testing.expect(!detachHostReference(&hosts, &failed_clone));
}

test "TABGAP GDI tab paint reaches row zero with active inactive and HC palettes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Palette = struct { background: u32, fill: u32, border: u32 };
    for ([_]Palette{
        .{ .background = rgb(24, 24, 28), .fill = rgb(42, 42, 50), .border = rgb(90, 160, 230) },
        .{ .background = rgb(240, 240, 240), .fill = rgb(252, 252, 252), .border = rgb(160, 160, 160) },
        .{ .background = rgb(10, 40, 70), .fill = rgb(28, 58, 92), .border = rgb(210, 180, 30) },
        // Inject system-like HC colors; never change the user's HC setting.
        .{ .background = rgb(0, 0, 0), .fill = rgb(0, 0, 0), .border = rgb(255, 255, 255) },
    }) |palette| {
        for ([_]u32{ 96, 144, 192, 288 }) |dpi| {
            const scale = win32_chrome_state.scaled;
            const width = scale(120, dpi);
            const bottom = scale(3, dpi) + scale(40, dpi) - scale(6, dpi);
            const canvas = try Host.BannerTestCanvas.init(width, scale(40, dpi));
            defer canvas.deinit();
            const full = childRect(0, 0, canvas.width, canvas.height);
            for ([_]bool{ false, true, false }) |flush| {
                fillSolidRect(canvas.dc, full, palette.background);
                fillSolidRect(canvas.dc, childRect(@divTrunc(width, 2), scale(8, dpi), 1, 1), rgb(255, 0, 255));
                gdi.drawTabButton(canvas.dc, childRect(0, 0, width, bottom), palette.fill, palette.border, scale(4, dpi), flush);
                _ = Host.BannerTestCanvas.raw.GdiFlush();
                const x = @divTrunc(width, 2);
                try std.testing.expectEqual(if (flush) palette.border else palette.background, canvas.pixel(x, 0));
                try std.testing.expectEqual(palette.fill, canvas.pixel(x, scale(8, dpi)));
                // Parent-owned underline and separator rows remain untouched.
                try std.testing.expectEqual(palette.background, canvas.pixel(x, scale(40, dpi) - scale(3, dpi)));
                try std.testing.expectEqual(palette.background, canvas.pixel(x, canvas.height - 1));
                // Compare the whole lower rounded region with the legacy painter,
                // and require at least one pixel a square replacement would cover.
                const reference = try Host.BannerTestCanvas.init(width, canvas.height);
                defer reference.deinit();
                fillSolidRect(reference.dc, full, palette.background);
                gdi.drawRoundedRect(reference.dc, childRect(0, 0, width, bottom), palette.fill, palette.border, scale(4, dpi));
                _ = Host.BannerTestCanvas.raw.GdiFlush();
                var rounded_pixels: usize = 0;
                var y = bottom - scale(4, dpi);
                while (y < bottom - 1) : (y += 1) {
                    var corner_x: i32 = 1;
                    while (corner_x < width - 1) : (corner_x += 1) {
                        try std.testing.expectEqual(reference.pixel(corner_x, y), canvas.pixel(corner_x, y));
                        if (palette.fill != palette.background and corner_x < scale(4, dpi) and reference.pixel(corner_x, y) == palette.background) rounded_pixels += 1;
                    }
                }
                if (palette.fill != palette.background) try std.testing.expect(rounded_pixels > 0);
            }
        }
    }
}

test "win32 closing a pane removes its toast" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var w: ToastTestWindow = .{};
    try w.init(false);
    defer w.deinit();

    // Undoing the split that made a pane puts that pane in redo history,
    // which is a close as far as its toast goes.
    const inserted = try toastTestSplit(&w);
    defer {
        var cleanup = inserted;
        cleanup.deinit();
    }
    try w.osc(&w.q, "", "x");
    var split_create: Host.SplitCreateUndo = .{
        .source_surface = &w.p,
        .created_surface = &w.q,
        .direction = .right,
    };
    try std.testing.expect(try w.host.undoSplitCreateEntry(&split_create));
    w.app.flushToastRemovals();
    var q_buf: [64]u8 = undefined;
    const q_removal = try expectedToastRemoval(&q_buf, 0x2003);
    try w.recorder.expectRemovals(&.{q_removal});

    try w.osc(&w.p, "", "x");
    try w.osc(&w.front, "", "x");
    w.app.windowDestroyed(&w.p);
    w.app.flushToastRemovals();
    var buf: [64]u8 = undefined;
    try w.recorder.expectRemovals(&.{ q_removal, try expectedToastRemoval(&buf, 0x2002) });
    try std.testing.expectEqual(@as(?u64, 0x1001), w.front.toast_outstanding);
}

test "win32 a toast shown while its tab is undo-closed is removed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var w: ToastTestWindow = .{};
    try w.init(false);
    defer w.deinit();

    // The show pumps the close of the pane's tab, which keeps the pane
    // alive in undo history, where its toast must not stay.
    const Close = struct {
        w: *ToastTestWindow,
        entry: ?Host.StructuralUndoEntry = null,
        fn run(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.entry = self.w.host.detachTabForUndo(1) orelse return error.TestExpectedTab;
        }
    };
    var close: Close = .{ .w = &w };
    defer if (close.entry) |*entry| {
        entry.dispose(&w.host, .host_destroy) catch {}; // Best-effort test teardown.
    };
    w.recorder.during_show = .{ .ctx = &close, .run = Close.run };
    try w.osc(&w.p, "", "newer");
    try std.testing.expect(Host.findTabForSurface(&w.p) == null);
    try std.testing.expectEqual(@as(?u64, null), w.p.toast_outstanding);
    w.app.flushToastRemovals();
    var buf: [64]u8 = undefined;
    try w.recorder.expectRemovals(&.{try expectedToastRemoval(&buf, 0x2002)});
}

test "win32 palette theme preview can restore original config clone" {
    var original = try configpkg.Config.default(std.testing.allocator);
    defer original.deinit();
    try Host.setConfigTheme(&original, "Original Theme");

    var preview = try original.clone(std.testing.allocator);
    defer preview.deinit();
    try Host.setConfigTheme(&preview, "Preview Theme");
    try std.testing.expectEqualStrings("Preview Theme", preview.theme.?.light);
    try std.testing.expectEqualStrings("Original Theme", original.theme.?.light);

    var restored = try original.clone(std.testing.allocator);
    defer restored.deinit();
    try std.testing.expectEqualStrings("Original Theme", restored.theme.?.light);
}

test "win32 palette theme commit mutates pending without losing rollback source" {
    var original = try configpkg.Config.default(std.testing.allocator);
    defer original.deinit();
    try Host.setConfigTheme(&original, "Original Theme");

    var pending = try original.clone(std.testing.allocator);
    defer pending.deinit();
    try Host.setConfigTheme(&pending, "Committed Theme");

    try std.testing.expectEqualStrings("Original Theme", original.theme.?.light);
    try std.testing.expectEqualStrings("Committed Theme", pending.theme.?.light);
}

test "win32 a clicked search button's tooltip stays down until the button is left, hidden or destroyed" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const find: HWND = @ptrFromInt(0x10);
    const next: HWND = @ptrFromInt(0x20);
    const send = struct {
        /// Deliver `msg` to `button` as `hostButtonProc` does, with `shown`
        /// standing in for the popup: presenting puts it up, hiding takes it
        /// down.
        fn send(tooltip: *ButtonTooltip, button: HWND, msg: UINT, wParam: WPARAM) ButtonTooltip.Effect {
            const effect = tooltip.apply(buttonTooltipAction(msg, wParam), button);
            switch (effect) {
                .none => {},
                .present => tooltip.shown = button,
                .hide => tooltip.shown = null,
            }
            return effect;
        }
    }.send;
    const expectEqual = std.testing.expectEqual;
    var tooltip: ButtonTooltip = .{};

    try expectEqual(.present, send(&tooltip, find, c.WM_MOUSEHOVER, 0));
    // The hover re-arms on every move inside the button.
    try expectEqual(.none, send(&tooltip, find, c.WM_MOUSEHOVER, 0));
    try expectEqual(.hide, send(&tooltip, find, c.WM_LBUTTONDOWN, 0));
    // The button-up, the WM_MOUSEMOVE the system sends after it under a still
    // pointer, and the hover that move re-arms leave the tooltip down.
    try expectEqual(.none, send(&tooltip, find, c.WM_LBUTTONUP, 0));
    try expectEqual(.none, send(&tooltip, find, c.WM_MOUSEMOVE, 0));
    try expectEqual(.none, send(&tooltip, find, c.WM_MOUSEHOVER, 0));
    // The click holds down only the button it landed on.
    try expectEqual(.present, send(&tooltip, next, c.WM_MOUSEHOVER, 0));
    try expectEqual(.hide, send(&tooltip, next, c.WM_MOUSELEAVE, 0));
    try expectEqual(.none, send(&tooltip, find, c.WM_MOUSEHOVER, 0));

    // Leaving the button ends the dismissal.
    try expectEqual(.none, send(&tooltip, find, c.WM_MOUSELEAVE, 0));
    try expectEqual(.present, send(&tooltip, find, c.WM_MOUSEHOVER, 0));

    // So does hiding it.
    try expectEqual(.hide, send(&tooltip, find, c.WM_RBUTTONDOWN, 0));
    try expectEqual(.none, send(&tooltip, find, c.WM_MOUSEHOVER, 0));
    try expectEqual(.none, send(&tooltip, find, c.WM_SHOWWINDOW, 0));
    try expectEqual(.present, send(&tooltip, find, c.WM_MOUSEHOVER, 0));

    // And destroying it, so a later window that reuses the handle starts
    // with nothing held down.
    try expectEqual(.hide, send(&tooltip, find, c.WM_MBUTTONDOWN, 0));
    try expectEqual(.none, send(&tooltip, find, c.WM_DESTROY, 0));
    try expectEqual(@as(?HWND, null), tooltip.dismissed);
    try expectEqual(.present, send(&tooltip, find, c.WM_MOUSEHOVER, 0));
}

test "win32 the [+] and [v] tooltips and UIA names are one table, and the hover tooltip routes cover them" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var buf: [32]u8 = undefined;
    const ctx: *anyopaque = @ptrFromInt(0x10);
    try std.testing.expectEqualStrings(labels.tabStripActionName(.new_tab), Host.hostActionUiaName(ctx, 0, &buf));
    try std.testing.expectEqualStrings(labels.tabStripActionName(.more_tabs), Host.hostActionUiaName(ctx, 1, &buf));

    // The same hover, click and leave rules govern [+] and [v]: a dwell
    // presents, a click keeps it down, leaving ends the dismissal.
    const new_tab: HWND = @ptrFromInt(0x30);
    var tooltip: ButtonTooltip = .{};
    try std.testing.expectEqual(ButtonTooltip.Effect.present, tooltip.apply(buttonTooltipAction(c.WM_MOUSEHOVER, 0), new_tab));
    tooltip.shown = new_tab;
    try std.testing.expectEqual(ButtonTooltip.Effect.hide, tooltip.apply(buttonTooltipAction(c.WM_LBUTTONDOWN, 0), new_tab));
    tooltip.shown = null;
    try std.testing.expectEqual(ButtonTooltip.Effect.none, tooltip.apply(buttonTooltipAction(c.WM_MOUSEHOVER, 0), new_tab));
    try std.testing.expectEqual(ButtonTooltip.Effect.none, tooltip.apply(buttonTooltipAction(c.WM_MOUSELEAVE, 0), new_tab));
    try std.testing.expectEqual(ButtonTooltip.Effect.present, tooltip.apply(buttonTooltipAction(c.WM_MOUSEHOVER, 0), new_tab));
}

test "win32 titlebar hover fade decays linearly and snaps at zero duration" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var fade: TitlebarHoverFade = .{};
    fade.start(1_000, titlebar_hover_fade_ms);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fade.alphaAt(1_000), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fade.alphaAt(1_075), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), fade.alphaAt(1_150), 0.001);
    try std.testing.expect(!fade.animating(1_150));

    fade.start(2_000, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), fade.alphaAt(2_000), 0.001);
    try std.testing.expect(!fade.animating(2_000));
}
