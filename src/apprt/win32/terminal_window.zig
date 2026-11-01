//! Win32 terminal child window.
const win32 = @import("../win32.zig");
const Allocator = win32.Allocator;
const App = win32.App;
const BYTE = win32.BYTE;
const BenchmarkMemoryStage = win32.BenchmarkMemoryStage;
const ChildPlacement = child_window.ChildPlacement;
const ClipboardContents = win32.ClipboardContents;
const ClipboardSource = win32.ClipboardSource;
const ConfirmPrompt = win32.ConfirmPrompt;
const CoreSurface = @import("../../Surface.zig");
const DeferredCharState = win32.DeferredCharState;
const FullscreenMonitor = win32.FullscreenMonitor;
const HDC = win32.HDC;
const HGDIOBJ = win32.HGDIOBJ;
const HGLRC = win32.HGLRC;
const HWND = win32.HWND;
const Host = win32.Host;
const HostOverlayMode = win32.HostOverlayMode;
const INTRESOURCE = win32.INTRESOURCE;
const LONG_PTR = win32.LONG_PTR;
const LPARAM = win32.LPARAM;
const LPCWSTR = win32.LPCWSTR;
const MemoryStageTrace = win32.MemoryStageTrace;
const NormalizedWheelScroll = win32.NormalizedWheelScroll;
const PAINTSTRUCT = win32.PAINTSTRUCT;
const POINT = win32.POINT;
const RECT = win32.RECT;
const RenderTrace = win32.RenderTrace;
const RestoredTerminalUndoState = win32.RestoredTerminalUndoState;
const ScrollbarPaintKey = win32.ScrollbarPaintKey;
const ScrollbarPolicy = win32.ScrollbarPolicy;
const ScrollbarProxyPoint = win32.ScrollbarProxyPoint;
const SplitSurfaceAttachRollback = win32.SplitSurfaceAttachRollback;
const SplitTreeSurface = win32.SplitTreeSurface;
const SurfaceInitOptions = win32.SurfaceInitOptions;
const TRACKMOUSEEVENT = win32.TRACKMOUSEEVENT;
const Tab = win32.Tab;
const UINT = win32.UINT;
const WINDOWPLACEMENT = win32.WINDOWPLACEMENT;
const WPARAM = win32.WPARAM;
const WheelNormalizationContext = win32.WheelNormalizationContext;
const WindowKeeps = win32.WindowKeeps;
const WindowStart = win32.WindowStart;
const adjustColor = win32.adjustColor;
const alphaByteForOpacity = win32.alphaByteForOpacity;
const anyVirtualKeyPressed = win32.anyVirtualKeyPressed;
const appendOwnedString = paint_text.appendOwnedString;
const appendSanitizedTitle = win32.appendSanitizedTitle;
const applyChildRect = child_window.applyChildRect;
const applyChildVisibility = child_window.applyChildVisibility;
const apprt = @import("../../apprt.zig");
const blendColorRGB = win32.blendColorRGB;
const build_config = @import("../../build_config.zig");
const c = @import("consts.zig");
const captureTerminalUndoStateBytes = win32.captureTerminalUndoStateBytes;
const childRect = win32.childRect;
const child_window = @import("child_window.zig");
const chromeSyncOrLog = win32.chromeSyncOrLog;
const class_name = win32.class_name;
const clipboardTextToUtf8 = win32.clipboardTextToUtf8;
const clipboard_write = @import("clipboard_write.zig");
const commitSplitSurfaceAttach = win32.commitSplitSurfaceAttach;
const configpkg = @import("../../config.zig");
const crlfLineEndings = win32.crlfLineEndings;
const cursorPosFromLParam = win32.cursorPosFromLParam;
const decorationsVisibleForConfig = win32.decorationsVisibleForConfig;
const detachChromeControlProvider = win32.detachChromeControlProvider;
const drawRoundedRect = win32.drawRoundedRect;
const fillSolidRect = win32.fillSolidRect;
const first_frame = @import("first_frame.zig");
const gl_startup = @import("gl_startup.zig");
const hostChromeNeedsFocusRepaint = win32.hostChromeNeedsFocusRepaint;
const imeWindowForms = win32.imeWindowForms;
const initialDecorationsVisibleForSource = win32.initialDecorationsVisibleForSource;
const input = @import("../../input.zig");
const inspectorBannerStateChanged = win32.inspectorBannerStateChanged;
const inspectorChromeVisible = win32.inspectorChromeVisible;
const internal_os = @import("../../os/main.zig");
const isAutomaticSshCommandTitle = win32.isAutomaticSshCommandTitle;
const isHighContrastActive = win32.isHighContrastActive;
const lParamBits = win32.lParamBits;
const labels = @import("labels.zig");
const lastError = child_window.lastError;
const layoutRectToWin32 = win32.layoutRectToWin32;
const lfLineEndings = win32.lfLineEndings;
const log = win32.log;
const mouseButtonFromMessage = win32.mouseButtonFromMessage;
const mouseButtonStateFromMessage = win32.mouseButtonStateFromMessage;
const mouseModsFromWParam = win32.mouseModsFromWParam;
const normalizedBackgroundOpacity = win32.normalizedBackgroundOpacity;
const openClipboard = win32.openClipboard;
const optionalOwnedStringEquals = paint_text.optionalOwnedStringEquals;
const ownedStringEquals = paint_text.ownedStringEquals;
const paint_text = @import("text.zig");
const paletteDisconnectThunk = win32.paletteDisconnectThunk;
const paletteReleaseThunk = win32.paletteReleaseThunk;
const pasteFilePayload = win32.pasteFilePayload;
const pixel_format = @import("pixel_format.zig");
const ptypkg = @import("../../pty.zig");
const quickSelectAsciiFromKey = win32.quickSelectAsciiFromKey;
const quickSelectCanActivate = win32.quickSelectCanActivate;
const quickSelectFocusedThunk = win32.quickSelectFocusedThunk;
const quickSelectInvokeRowThunk = win32.quickSelectInvokeRowThunk;
const quickSelectLabelDisplayUnit = win32.quickSelectLabelDisplayUnit;
const quickSelectNameThunk = win32.quickSelectNameThunk;
const quickSelectRowBoundsThunk = win32.quickSelectRowBoundsThunk;
const quickSelectRowCountThunk = win32.quickSelectRowCountThunk;
const quickSelectRowEnabledThunk = win32.quickSelectRowEnabledThunk;
const quickSelectRowIdThunk = win32.quickSelectRowIdThunk;
const quickSelectRowNameThunk = win32.quickSelectRowNameThunk;
const quickSelectSelectRowThunk = win32.quickSelectSelectRowThunk;
const quickSelectSelectedIndexThunk = win32.quickSelectSelectedIndexThunk;
const quick_select_class_name = win32.quick_select_class_name;
const recordOpenGLStartupError = win32.recordOpenGLStartupError;
const recordOpenGLStartupWin32Failure = win32.recordOpenGLStartupWin32Failure;
const render_trace = @import("render_trace.zig");
const rendererpkg = @import("../../renderer.zig");
const requestedTabInsertIndex = win32.requestedTabInsertIndex;
const resizeSplitFallbackDelta = win32.resizeSplitFallbackDelta;
const resolveWindowBaseTitle = win32.resolveWindowBaseTitle;
const restoreTerminalUndoState = win32.restoreTerminalUndoState;
const rollbackFailedSurfaceAttach = win32.rollbackFailedSurfaceAttach;
const runUiActionOrLog = win32.runUiActionOrLog;
const sanitizeTitleAlloc = win32.sanitizeTitleAlloc;
const scheduleDeferredUiaDisconnect = win32.scheduleDeferredUiaDisconnect;
const scrollbarNeedsHeartbeatForState = win32.scrollbarNeedsHeartbeatForState;
const scrollbarPaintKeyChanged = win32.scrollbarPaintKeyChanged;
const scrollbarProxyPointFromSurfaceCoords = win32.scrollbarProxyPointFromSurfaceCoords;
const scrollbarProxyPointFromSurfaceCursor = win32.scrollbarProxyPointFromSurfaceCursor;
const scrollbar_class_name = win32.scrollbar_class_name;
const searchBarDisplayStateChanged = win32.searchBarDisplayStateChanged;
const searchBarSearchedStateForSelected = win32.searchBarSearchedStateForSelected;
const searchBarSearchedStateForTotal = win32.searchBarSearchedStateForTotal;
const searchSelectedDisplayFromRaw = win32.searchSelectedDisplayFromRaw;
const searchSelectedRawFromCoreDisplay = win32.searchSelectedRawFromCoreDisplay;
const docked_search = @import("docked_search.zig");
const search_controls = @import("search_controls.zig");
const selectClipboardContents = win32.selectClipboardContents;
const session_module = @import("session.zig");
const setWindowData = child_window.setWindowData;
const sharesHostWindowState = win32.sharesHostWindowState;
const shouldAcceptCoreSearchUpdates = win32.shouldAcceptCoreSearchUpdates;
const shouldApplyConfigDecorations = win32.shouldApplyConfigDecorations;
const shouldDispatchOcclusion = win32.shouldDispatchOcclusion;
const shouldShowSurfaceImmediately = win32.shouldShowSurfaceImmediately;
const signedHighWord = win32.signedHighWord;
const signedLowWord = win32.signedLowWord;
const sshAliasFromLaunchKey = win32.sshAliasFromLaunchKey;
const stackChildAbove = win32.stackChildAbove;
const std = @import("std");
const stripHtmlTags = win32.stripHtmlTags;
const surfaceConfirmCloseAccept = win32.surfaceConfirmCloseAccept;
const surfaceConfirmPasteAccept = win32.surfaceConfirmPasteAccept;
const surfaceConfirmPasteCancel = win32.surfaceConfirmPasteCancel;
const surfaceConfirmWriteAccept = win32.surfaceConfirmWriteAccept;
const surfaceConfirmWriteCancel = win32.surfaceConfirmWriteCancel;
const surfaceDropPayloadCallback = win32.surfaceDropPayloadCallback;
const surfaceWindowStyle = win32.surfaceWindowStyle;
const surface_presentation = @import("surface_presentation.zig");
const sys = @import("sys.zig");
const terminal = @import("../../terminal/main.zig");
const terminalAccessibilityCapture = win32.terminalAccessibilityCapture;
const terminalAccessibilityDeferProviderRelease = win32.terminalAccessibilityDeferProviderRelease;
const terminalAccessibilityFocused = win32.terminalAccessibilityFocused;
const terminalAccessibilityHwnd = win32.terminalAccessibilityHwnd;
const terminalAccessibilityName = win32.terminalAccessibilityName;
const terminalAccessibilityOutputCallback = win32.terminalAccessibilityOutputCallback;
const terminalAccessibilityScroll = win32.terminalAccessibilityScroll;
const terminalAccessibilityViewport = win32.terminalAccessibilityViewport;
const win32_clipboard_html = @import("../win32_clipboard_html.zig");
const win32_hints = @import("../win32_hints.zig");
const win32_input = @import("input.zig");
const win32_ole = @import("../win32_ole.zig");
const win32_paste_protection = @import("../win32_paste_protection.zig");
const win32_program_status = @import("../win32_program_status.zig");
const win32_scrollbar_geometry = @import("../win32_scrollbar_geometry.zig");
const win32_shell = @import("../win32_shell.zig");
const win32_surface_drop_target = @import("../win32_surface_drop_target.zig");
const win32_taskbar_progress = @import("../win32_taskbar_progress.zig");
const win32_terminal_accessibility = @import("../win32_terminal_accessibility.zig");
const win32_theme = @import("../win32_theme.zig");
const win32_uia = @import("../win32_uia/mod.zig");
const win32_undo = @import("../win32_undo.zig");
const window_state = @import("window_state.zig");
const windows = win32.windows;
const windows_shell = @import("../../config/windows_shell.zig");
const writeImeWindowFormsTrace = win32.writeImeWindowFormsTrace;

// Test dependencies.
const CoreApp = @import("../../App.zig");
const MSG = win32.MSG;
const applyConsoleWindowVisibility = win32.applyConsoleWindowVisibility;
const win32_power = @import("../win32_power.zig");
const TestSession = win32.TestSession;
const createTestHostWindow = win32.createTestHostWindow;
const LRESULT = win32.LRESULT;
const SafeModeAppFixture = win32.SafeModeAppFixture;
const ToastTestWindow = win32.ToastTestWindow;
const WindowStartTestApp = win32.WindowStartTestApp;
const builtin = @import("builtin");
const createTestChromeChild = win32.createTestChromeChild;
const default_title = win32.default_title;
const expectedToastRemoval = win32.expectedToastRemoval;
const host_class_name = win32.host_class_name;
const palette_list_class_name = win32.palette_list_class_name;
const prompt_button_class = child_window.prompt_button_class;
const prompt_label_class = child_window.prompt_label_class;
const runOnHiddenDesktop = win32.runOnHiddenDesktop;
const toastTestSplit = win32.toastTestSplit;
const uninitializedInertStorage = win32.uninitializedInertStorage;

const scrollbar_transparent_key = win32_theme.rgb(0xFF, 0x00, 0xFF);

const host_banner_inspector_inactive = labels.host_banner_inspector_inactive;

/// Deep-copy of one `apprt.ClipboardContent` entry so it can survive an
/// async confirm-overlay roundtrip. Freed via `PendingClipboardOp.deinit`.
const OwnedClipboardContent = struct {
    mime: [:0]u8,
    data: [:0]u8,
};

/// A clipboard operation awaiting user confirmation via
/// `HostOverlayMode.confirm`. The owning `Surface` dupes all caller
/// payload bytes into `core_app.alloc` when queuing the op so the
/// confirm overlay's async callback sees valid data regardless of when
/// the original caller's buffers go out of scope.
const PendingClipboardOp = union(enum) {
    /// Deferred paste. `request` tells the core path to complete once
    /// the user accepts; `data` is the duplicated payload.
    paste: struct {
        request: apprt.ClipboardRequest,
        data: [:0]u8,
    },
    /// Deferred clipboard write (one or more mime/data pairs).
    write: struct {
        clipboard: apprt.Clipboard,
        contents: []OwnedClipboardContent,
    },

    pub fn deinit(self: *PendingClipboardOp, alloc: Allocator) void {
        switch (self.*) {
            .paste => |*p| alloc.free(p.data),
            .write => |*w| {
                for (w.contents) |*content| {
                    alloc.free(content.mime);
                    alloc.free(content.data);
                }
                alloc.free(w.contents);
            },
        }
    }
};

const QuickSelectSession = struct {
    const PendingAction = struct {
        trigger_vk: UINT,
        index: ?usize,
        ctrl: bool,
        alt: bool,
    };

    scan: win32_hints.Scan,
    labels: win32_hints.LabelSet,
    prefix: win32_hints.PrefixState = .{},
    pending_action: ?PendingAction = null,
    awaiting_composed_char: bool = false,
    suppress_until_opening_keys_released: bool = false,
    suppress_opening_left_button_up: bool = false,
    cell_width: i32,
    cell_height: i32,
    padding_left: i32,
    padding_top: i32,
    placed_rects: []RECT,
    placed_slots: []?usize,
    placed_count: usize = 0,
    placement_client: ?RECT = null,
    placement_metrics: ?win32_theme.ThemeMetrics = null,
    placement_dpi: UINT = 0,
    placement_complete: bool = false,

    fn deinit(self: *QuickSelectSession, alloc: Allocator) void {
        alloc.free(self.placed_slots);
        alloc.free(self.placed_rects);
        self.labels.deinit(alloc);
        self.scan.deinit(alloc);
        self.* = undefined;
    }
};

test "quick select label placement checks final positioned chips" {
    const client: RECT = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 };
    var comparisons_remaining: usize = Surface.quick_select_placement_comparison_budget;
    const occupied = [_]RECT{
        .{ .left = 0, .top = 0, .right = 20, .bottom = 10 },
        .{ .left = 10, .top = 10, .right = 30, .bottom = 20 },
    };
    const placed = Surface.quickSelectPositionLabel(
        .{ .left = 10, .top = 10, .right = 20, .bottom = 20 },
        client,
        &occupied,
        &comparisons_remaining,
    ).?;
    try std.testing.expectEqual(@as(i32, 20), placed.top);
    try std.testing.expectEqual(@as(i32, 30), placed.bottom);
}

test "quick select label placement uses the free global grid" {
    const client: RECT = .{ .left = 0, .top = 0, .right = 30, .bottom = 20 };
    var comparisons_remaining: usize = Surface.quick_select_placement_comparison_budget;
    const occupied = [_]RECT{
        .{ .left = 10, .top = 0, .right = 20, .bottom = 10 },
        .{ .left = 10, .top = 10, .right = 20, .bottom = 20 },
    };
    const placed = Surface.quickSelectPositionLabel(
        .{ .left = 10, .top = 0, .right = 20, .bottom = 10 },
        client,
        &occupied,
        &comparisons_remaining,
    ).?;
    try std.testing.expectEqual(@as(i32, 0), placed.left);
    try std.testing.expectEqual(@as(i32, 10), placed.right);
}

test "quick select label placement reports an exhausted viewport" {
    const client: RECT = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 };
    var comparisons_remaining: usize = Surface.quick_select_placement_comparison_budget;
    const occupied = [_]RECT{
        .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
        .{ .left = 10, .top = 0, .right = 20, .bottom = 10 },
        .{ .left = 0, .top = 10, .right = 10, .bottom = 20 },
        .{ .left = 10, .top = 10, .right = 20, .bottom = 20 },
    };
    try std.testing.expect(Surface.quickSelectPositionLabel(
        .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
        client,
        &occupied,
        &comparisons_remaining,
    ) == null);
}

test "quick select label placement stops at its comparison budget" {
    const client: RECT = .{ .left = 0, .top = 0, .right = 20, .bottom = 20 };
    const occupied = [_]RECT{.{ .left = 0, .top = 0, .right = 10, .bottom = 10 }};
    var comparisons_remaining: usize = 0;
    try std.testing.expect(Surface.quickSelectPositionLabel(
        .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
        client,
        &occupied,
        &comparisons_remaining,
    ) == null);
}

/// A config color as a GDI COLORREF.
fn colorRefFromConfig(color: configpkg.Config.Color) u32 {
    return win32_theme.rgb(color.r, color.g, color.b);
}

pub const Surface = struct {
    app: *App,
    shell_id: ?win32_shell.model.PaneId = null,
    shell_committed: bool = false,
    host: ?*Host = null,
    host_id: u32 = 0,
    host_active: bool = true,
    window_visible: bool = false,
    occlusion_visible: ?bool = null,
    hwnd: ?HWND = null,
    placement: ChildPlacement = .{},
    hdc: HDC = null,
    hglrc: HGLRC = null,
    /// The pixel format this window took, once `SetPixelFormat` succeeded.
    /// A window keeps its format for good, so a later OpenGL attempt (a
    /// fallback from D3D11 after an earlier one failed) must reuse it.
    gl_pixel_format: ?pixel_format.WglPixelFormatProvenance = null,
    core_surface: CoreSurface = undefined,
    core_initialized: bool = false,
    adopted_session: ?ptypkg.AdoptedSession = null,
    adopted_console: bool = false,
    /// Set once the core has asked for the pty's hosting window
    /// (`consoleOwner`); until then there is no console window to keep in step.
    console_window_attached: bool = false,
    console_window_visible: ?bool = null,
    destroy_on_wm_destroy: bool = false,
    content_scale: apprt.ContentScale = .{ .x = 1, .y = 1 },
    size: apprt.SurfaceSize = .{ .width = 800, .height = 600 },
    cursor_pos: apprt.CursorPos = .{ .x = -1, .y = -1 },
    right_press_consumed: bool = false,
    title: ?[:0]const u8 = null,
    title_override: ?[:0]const u8 = null,
    tab_title_override: ?[:0]const u8 = null,
    launch_profile_key: ?[:0]const u8 = null,
    /// Recorded from the resolved profile kind at launch, so nothing downstream
    /// has to re-derive "is this SSH?" from the key text.
    launched_ssh: bool = false,
    launch_command: ?configpkg.Command = null,
    /// The user profile's command line and environment entries this surface
    /// was launched with (`pane_launch.Stamp.user`), kept with
    /// `launch_command` so an inheriting tab or split runs the same launch.
    launch_user: ?windows_shell.UserLaunch = null,
    mouse_shape: terminal.MouseShape = .text,
    mouse_visible: bool = true,
    hovered_link: ?[:0]const u8 = null,
    window_focused: bool = false,
    /// This pane is an unfocused split, which the renderer dims
    /// (`Host.syncSplitDim`), and what the renderer was last told; the
    /// renderer starts undimmed.
    split_dimmed: bool = false,
    split_dimmed_sent: bool = false,
    /// The bell rang here while the user was not looking; the tab label and
    /// the window caption carry the glyph until `clearBell`.
    bell_ringing: bool = false,
    decorations_visible: bool = true,
    decorations_visible_overridden: bool = false,
    fullscreen: bool = false,
    topmost: bool = false,
    /// What `leaveFullscreen` returns the window to, captured by
    /// `enterFullscreen`: the window rect, and the placement for a window
    /// that was maximized.
    restore_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    restore_placement: WINDOWPLACEMENT = std.mem.zeroes(WINDOWPLACEMENT),
    restore_monitor: ?FullscreenMonitor = null,
    default_client_size: ?apprt.SurfaceSize = null,
    cell_size_pixels: apprt.action.CellSize = .{ .width = 0, .height = 0 },
    background_opacity_default: f64 = 1.0,
    background_opacity_force_opaque: bool = false,
    /// The configured terminal background (`background`, which a `theme`
    /// sets), as a COLORREF. The active tab takes it so it reads as the top
    /// of this terminal (`Host.tabBackground`). Only this terminal's own
    /// config sets it (`setTabBackground`); background colors a program sets
    /// at run time (OSC 11) are not followed.
    tab_background: u32 = colorRefFromConfig(std.meta.fieldInfo(configpkg.Config, .background).defaultValue().?),
    scrollbar_config: configpkg.Config.Scrollbar = .system,
    size_limit: apprt.action.SizeLimit = .{
        .min_width = 0,
        .min_height = 0,
        .max_width = 0,
        .max_height = 0,
    },
    secure_input: bool = false,
    secure_input_ever_engaged: bool = false,
    key_sequence_active: bool = false,
    key_sequence_since_ms: ?u64 = null,
    key_table_name: ?[:0]const u8 = null,
    key_table_copy_mode: bool = false,
    scrollbar: terminal.Scrollbar = .zero,
    scrollbar_state: win32_scrollbar_geometry.ScrollbarState = .{},
    scrollbar_hwnd: ?HWND = null,
    scrollbar_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    scrollbar_placement: ChildPlacement = .{},
    scrollbar_leave_armed: bool = false,
    scrollbar_leave_hwnd: ?HWND = null,
    scrollbar_drag_anchor_offset: f32 = 0,
    scrollbar_alpha_cache: BYTE = 0,
    scrollbar_markers: []const f32 = &.{},
    scrollbar_marker_revision: u64 = 0,
    scrollbar_marker_budget: usize = 0,
    scrollbar_paint_cache: ?ScrollbarPaintKey = null,
    quick_select_hwnd: ?HWND = null,
    quick_select_placement: ChildPlacement = .{},
    quick_select_session: ?QuickSelectSession = null,
    quick_select_uia_provider: ?*win32_uia.PaletteListProvider = null,
    pwd: ?[:0]const u8 = null,
    taskbar_progress: ?win32_taskbar_progress.ProgressReport = null,
    /// What this terminal's programs reported through OSC 7501.
    program_status: win32_program_status.Records = .{},
    /// When this surface last raised a program status notification, in
    /// `GetTickCount64` milliseconds.
    program_status_notified_ms: ?u64 = null,
    /// A notification the rate limit held back is waiting; see
    /// `App.flushProgramStatusNotifications`.
    program_status_notify_pending: bool = false,
    /// The tag (this pane's core surface id) of a toast this pane showed
    /// that may still be in Action Center; `null` once its removal is
    /// queued. Kept as the id itself because `windowDestroyed` runs after
    /// the core is gone. See `App.queueToastRemoval`.
    toast_outstanding: ?u64 = null,
    inspector_visible: bool = false,
    paint_pending: bool = false,
    live_resize_repaint_deferred: bool = false,
    renderer_gl_prepared: bool = false,
    /// OpenGL failed before core init (the eager WGL context or GL loading);
    /// renderer init falls back to the Direct3D 11 beta with this error,
    /// which it consumes.
    renderer_gl_error: ?anyerror = null,
    renderer_repaint_requested: std.atomic.Value(bool) = .init(false),
    renderer_repaint_retry_pending: std.atomic.Value(bool) = .init(false),
    /// One-shot post-show frame handshake for #224. Only ever touched from
    /// the UI thread (`WM_SHOWWINDOW`, `WM_WINDOWPOSCHANGED`, `WM_PAINT` and
    /// the `SwapBuffers` that `WM_PAINT` drives), so it needs no atomics.
    first_frame: first_frame.State = .{},
    draw_in_progress: bool = false,
    ime_composing: bool = false,
    deferred_char: DeferredCharState = .{},
    undo_capture_suspended: bool = false,
    render_trace: RenderTrace = .{},
    memory_stage_trace: MemoryStageTrace = .{},
    /// Per-surface bounded undo stack for terminal-local replayable
    /// actions (`clear_screen`, `reset`). Structural history that
    /// retains live tabs/surfaces lives on `Host` because it crosses
    /// pane boundaries and outlives the triggering surface.
    undo_stack: win32_undo.UndoStack = undefined,
    /// Per-pane docked search state (`docked_search.zig`); HWNDs below
    /// are the live child controls docked above the pane content. `init`
    /// gives it the app's allocator; until then it is empty, which is what
    /// a test's bare Surface reads (its match rows, for the scrollbar).
    docked_search: docked_search.DockedSearch = .{ .alloc = undefined },
    search_bar_frame_rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    search_bar_frame_visible: bool = false,
    search_bar_bg_hwnd: ?HWND = null,
    search_bar_bg_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    search_bar_bg_placement: ChildPlacement = .{},
    search_bar_edit_hwnd: ?HWND = null,
    search_bar_edit_prev_proc: ?*const anyopaque = null,
    search_bar_edit_uia_provider: ?*win32_uia.TerminalProvider = null,
    search_bar_edit_uia_selection: ?[2]u32 = null,
    search_bar_edit_placement: ChildPlacement = .{},
    search_bar_prev_hwnd: ?HWND = null,
    search_bar_next_hwnd: ?HWND = null,
    search_bar_regex_hwnd: ?HWND = null,
    search_bar_case_hwnd: ?HWND = null,
    search_bar_word_hwnd: ?HWND = null,
    search_bar_close_hwnd: ?HWND = null,
    search_bar_button_prev_procs: [6]?*const anyopaque = [_]?*const anyopaque{null} ** 6,
    search_bar_button_uia_providers: [6]?*win32_uia.ChromeControlProvider = [_]?*win32_uia.ChromeControlProvider{null} ** 6,
    search_bar_prev_placement: ChildPlacement = .{},
    search_bar_next_placement: ChildPlacement = .{},
    search_bar_regex_placement: ChildPlacement = .{},
    search_bar_case_placement: ChildPlacement = .{},
    search_bar_word_placement: ChildPlacement = .{},
    search_bar_close_placement: ChildPlacement = .{},
    search_bar_results_hwnd: ?HWND = null,
    search_bar_results_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    search_bar_label_prev_procs: [2]?*const anyopaque = .{ null, null },
    search_bar_results_placement: ChildPlacement = .{},
    search_bar_results_cache: ?[:0]const u8 = null,
    /// Surface's initial reference to an independently allocated OLE
    /// drop target. Detached and released during native-window teardown;
    /// retained COM references keep only the target alive after that.
    drop_target: ?*win32_surface_drop_target.DropTarget = null,
    drop_target_registered: bool = false,
    /// Clipboard operation parked on `HostOverlayMode.confirm` — the
    /// owning `Surface` holds deep-copied payload bytes so the async
    /// accept / cancel callback sees valid data regardless of the
    /// original caller's buffer lifetime. Non-null exactly while an
    /// overlay is pending. Drained by `surfaceConfirmPasteAccept` /
    /// `surfaceConfirmWriteAccept` / the matching cancel callbacks,
    /// and by `Surface.destroyWindow` so a close-while-pending doesn't
    /// leak.
    pending_clipboard_op: ?PendingClipboardOp = null,
    /// The checked link target this pane's open prompt is asking about
    /// (`App.askBeforeOpeningLink`), owned on the App allocator, the same way.
    pending_link_open: ?[]u8 = null,
    terminal_accessibility: ?*win32_terminal_accessibility.TerminalAccessibilitySession = null,
    /// Close preflight ownership. Normal close paths build both candidates
    /// before HWND/core teardown; `windowDestroyed` consumes them without
    /// allocating after the Surface is already dead.
    pending_close_tree: ?SplitTreeSurface = null,
    pending_shell_close: ?win32_shell.runtime.Prepared = null,

    pub const searchBarButtonHwnd = search_controls.SurfaceControls.searchBarButtonHwnd;

    pub fn decorativeUiaName(_: *anyopaque, _: usize, _: []u8) []const u8 {
        return "";
    }

    fn scrollbarUiaName(_: *anyopaque, _: usize, _: []u8) []const u8 {
        return "Terminal scrollbar";
    }

    fn scrollbarUiaRangeValue(value: terminal.Scrollbar) win32_uia.ChromeRangeValue {
        const maximum = value.total -| value.len;
        return .{
            .value = @floatFromInt(@min(value.offset, maximum)),
            .minimum = 0,
            .maximum = @floatFromInt(maximum),
            .large_change = @floatFromInt(value.len),
            .small_change = 1,
        };
    }

    fn scrollbarUiaRange(ctx: *anyopaque) win32_uia.ChromeRangeValue {
        const self: *Surface = @ptrCast(@alignCast(ctx));
        return scrollbarUiaRangeValue(self.scrollbar);
    }

    pub fn createChromeUiaProvider(
        self: *Surface,
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
            log.warn("surface chrome UIA provider unavailable err={}", .{err});
            return null;
        };
    }

    pub const searchLabelUiaProvider = search_controls.SurfaceControls.searchLabelUiaProvider;

    pub const searchLabelPrevProc = search_controls.SurfaceControls.searchLabelPrevProc;

    pub const searchEditUiaState = search_controls.SurfaceControls.searchEditUiaState;

    pub const raiseSearchEditSelectionChangedIfNeeded = search_controls.SurfaceControls.raiseSearchEditSelectionChangedIfNeeded;

    pub const searchBarButtonPlacement = search_controls.SurfaceControls.searchBarButtonPlacement;

    pub const searchBarButtonRole = search_controls.SurfaceControls.searchBarButtonRole;

    pub const searchBarButtonActive = search_controls.SurfaceControls.searchBarButtonActive;

    pub const ownsSearchBarControl = search_controls.SurfaceControls.ownsSearchBarControl;

    pub const searchBarButtonPrevProc = search_controls.SurfaceControls.searchBarButtonPrevProc;

    pub fn initialDecorationsVisible(config: *const configpkg.Config, opts: SurfaceInitOptions) bool {
        const keeps = WindowKeeps.forNewSurface(config, opts);
        return initialDecorationsVisibleForSource(config, if (keeps.decoration) null else opts.clone_state_from);
    }

    /// The `Surface.init` steps `App.test_surface_init_stage` stands in for.
    pub const InitStage = enum { gl_context, core_surface };

    pub fn init(
        self: *Surface,
        app: *App,
        title: LPCWSTR,
        config: *const configpkg.Config,
        opts: SurfaceInitOptions,
    ) !void {
        log.debug("surface.init begin", .{});
        const existing_host = if (opts.host_id) |host_id|
            app.registry.findHostById(host_id) orelse return error.InvalidHost
        else
            null;
        var shell_prepared = try app.prepareShellSurfaceCreate(existing_host, opts);
        defer if (shell_prepared) |*prepared| prepared.deinit();

        const host = existing_host orelse try app.createHost(title, config, opts);
        const created_host = existing_host == null;
        errdefer if (created_host) {
            // Its shell window was never committed. Clear it, or the focus
            // change while the window is destroyed audits this host as a
            // window the shell is missing.
            host.shell_id = null;
            // As `createHost` unwinds: the Host stays registered through
            // WM_DESTROY, which detaches its shell compositor.
            if (host.hwnd) |host_hwnd| {
                if (sys.DestroyWindow(host_hwnd) == 0) app.detachShellCompositorWindow(host_hwnd);
            }
            app.removeHost(host);
        };
        self.* = .{
            .app = app,
            .host = host,
            .adopted_session = if (opts.adopted_session) |pending| pending.takeAdopted() else null,
            .adopted_console = opts.adopted_session != null,
            .host_id = host.id,
            .host_active = true,
            .window_visible = false,
            .decorations_visible = initialDecorationsVisible(config, opts),
            .scrollbar_config = config.scrollbar,
            .render_trace = RenderTrace.init(app.core_app.alloc),
            // Unlike the render trace there is no single-claimant rule here:
            // the memory stage trace is JSONL and every surface appends its
            // own lifecycle records to the shared file, serialized by a
            // process-wide mutex in `bench_trace`.
            .memory_stage_trace = MemoryStageTrace.init(app.core_app.alloc),
            .undo_stack = win32_undo.UndoStack.init(app.core_app.alloc),
            .docked_search = docked_search.DockedSearch.init(app.core_app.alloc),
        };
        // `destroy` never runs for a Surface whose init fails, so free here
        // what it would: the strings, among them the launch command cloned
        // below and a title the core sets as it starts, and the traces.
        errdefer {
            self.freeOwnedStrings();
            self.render_trace.deinit(app.core_app.alloc);
            self.memory_stage_trace.deinit(app.core_app.alloc);
        }
        errdefer if (self.adopted_session) |*session| {
            session.pty.deinit();
            _ = windows.CloseHandle(session.client_process);
            self.adopted_session = null;
        };
        // The launch it runs, for the tabs and splits that repeat it. The
        // process's first surface with `initial-command` (`-e`) runs that
        // command, which is no profile's, so it records no profile line or
        // variables.
        const e_command = if (app.core_app.first) config.@"initial-command" else null;
        if (e_command orelse config.command) |command| self.launch_command = try command.clone(app.core_app.alloc);
        if (e_command == null) {
            if (opts.launch.user) |user| self.launch_user = try user.clone(app.core_app.alloc);
        }
        self.drop_target = try win32_surface_drop_target.DropTarget.create(
            app.core_app.alloc,
            @ptrCast(self),
            &surfaceDropPayloadCallback,
        );
        errdefer {
            self.drop_target.?.deinit();
            self.drop_target = null;
        }
        self.background_opacity_default = normalizedBackgroundOpacity(config.@"background-opacity");
        self.tab_background = colorRefFromConfig(config.background);
        // First memory-stage sample. Every later stage's private-bytes delta
        // is measured against this one, so it has to be the first thing that
        // happens after the trace field exists and before any window, DC,
        // GL or terminal allocation.
        self.noteBenchmarkMemoryStage(.surface_begin, null);

        const hwnd = sys.CreateWindowExW(
            0,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            surfaceWindowStyle(),
            0,
            0,
            10,
            10,
            host.hwnd,
            null,
            app.hinstance,
            self,
        ) orelse return lastError();
        errdefer _ = sys.DestroyWindow(hwnd);
        self.hwnd = hwnd;

        // Register the OLE drop target so Explorer / browser drops
        // land as typed input in the terminal. Failure is non-fatal:
        // the user loses the feature but the terminal still works.
        // Requires the STA apartment that `App.init` brought up via
        // `OleInitialize`.
        if (self.drop_target.?.register(hwnd)) {
            self.drop_target_registered = true;
        } else |err| {
            std.log.warn("drop target register failed hwnd={*} err={}", .{ hwnd, err });
        }
        errdefer if (self.drop_target_registered) {
            self.drop_target.?.revoke(hwnd);
            self.drop_target_registered = false;
        };

        const content_rect = host.contentRect() catch host.contentRectFromClient(.{
            .left = 0,
            .top = 0,
            .right = 1280,
            .bottom = 800,
        });
        _ = applyChildRect(hwnd, &self.placement, content_rect);
        self.placement.visible = false;
        self.placement.visible_known = true;
        log.debug("surface.init hwnd created", .{});
        self.noteBenchmarkMemoryStage(.child_hwnd_created, null);

        if (app.test_surface_init_stage) |stage| {
            try stage(self, .gl_context);
            self.noteBenchmarkMemoryStage(.gl_context_created, null);
        } else if (!build_config.d3d11 or (config.renderer == .opengl and !gl_startup.openGLUnavailable())) {
            // `ensureGLContext` publishes the pixel format before its stage
            // note, which only emits the wgl_* provenance fields after that.
            if (self.ensureGLContext()) |_| {
                log.debug("surface.init gl context created", .{});
            } else |err| {
                // Renderer init falls back to the Direct3D 11 beta.
                if (!build_config.d3d11) return err;
                self.renderer_gl_error = err;
            }
        }
        errdefer self.destroyGL();

        // `addSurface` below stops a running quit timer. If init then fails,
        // restart it once this Surface has left `windows`, or an app left
        // with no window would never quit.
        const quit_timer_was_running = app.quit_timer_id != null;
        try app.registry.addWindow(app.core_app.alloc, self);
        errdefer {
            app.registry.removeWindow(self);
            if (quit_timer_was_running) app.startQuitTimer();
        }
        log.debug("surface.init appended to app windows", .{});
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);
        log.debug("surface.init added to core app", .{});

        const prev_active_tab = host.active_tab;
        const prev_tab_count = host.tabs.items.len;
        var inserted_tab_index: ?usize = null;
        var split_rollback: ?SplitSurfaceAttachRollback = null;
        defer commitSplitSurfaceAttach(&split_rollback);
        if (opts.tab_id) |tab_id| {
            for (host.tabs.items) |*tab| {
                if (tab.id == tab_id) {
                    const inserted = try SplitTreeSurface.init(app.core_app.alloc, self);
                    defer {
                        var cleanup = inserted;
                        cleanup.deinit();
                    }
                    const focus_handle = tab.findHandle(@constCast(opts.clone_state_from.?)) orelse tab.focused;
                    const next_tree = try tab.tree.split(
                        app.core_app.alloc,
                        focus_handle,
                        opts.split_direction,
                        0.5,
                        &inserted,
                    );
                    const prev_tree = tab.tree;
                    const prev_focused = tab.focused;
                    tab.tree = next_tree;
                    tab.focused = tab.findHandle(self) orelse focus_handle;
                    split_rollback = .{
                        .tab = tab,
                        .tree = prev_tree,
                        .focused = prev_focused,
                    };
                    break;
                }
            } else return error.InvalidTab;
        } else {
            const tab_id = host.nextTabId();
            inserted_tab_index = requestedTabInsertIndex(opts.tab_insert_index, host.tabs.items.len);
            {
                var tab = try Tab.init(app.core_app.alloc, tab_id, self);
                errdefer tab.deinit();
                try host.tabs.insert(app.core_app.alloc, inserted_tab_index.?, tab);
            }
        }

        if (shell_prepared) |*prepared| {
            self.shell_id = prepared.created.pane;
            if (host.shell_id == null) host.shell_id = prepared.created.window;
            if (inserted_tab_index) |index| {
                host.tabs.items[index].shell_id = prepared.created.tab;
            }
        }
        // Rollback the tab entry if core_surface.init or later init steps fail.
        // Without this, a zombie tab with a dangling surface pointer would remain
        // in host.tabs, causing use-after-free on subsequent refreshChrome/layout.
        errdefer {
            // The chrome may have given the new tab a button and a UIA
            // provider, which the tab must not outlive (`Tab.deinit`), and a
            // reader was told about the button.
            var had_button = false;
            if (inserted_tab_index) |index| if (index < host.tabs.items.len) {
                had_button = host.tabs.items[index].button_hwnd != null;
                host.destroyTabButton(&host.tabs.items[index]);
            };
            rollbackFailedSurfaceAttach(
                &host.tabs,
                &host.active_tab,
                prev_active_tab,
                prev_tab_count,
                inserted_tab_index,
                &split_rollback,
            );
            if (had_button) host.notifyTabListUiaChanged();
            // The core's `set_title` may have relabelled a host that stays
            // for the tabs it had; `windowDestroyed` would refresh them.
            if (!created_host) runUiActionOrLog("failed surface chrome refresh failed", host.refreshChrome());
            // A layout during init may have dimmed the pane this split
            // came from, which is alone in its tab again.
            if (!created_host) host.syncSplitDim();
        }

        // The core opens the pty at the size read below. Give a new split its
        // pane's rect now, as `layout` will when activation shows it: the
        // split reset zoom, and the new pane, which the tab now focuses, has
        // no search bar. Otherwise the pty starts at the whole content size
        // and is resized ~40 ms after spawn, and a prompt drawn before that
        // resize is left with a misplaced cursor. The content rect is the
        // active tab's, so a split made in a background tab whose inspector
        // or decorations differ is still resized once on activation.
        if (split_rollback) |attach| {
            var spatial = try attach.tab.tree.spatial(app.core_app.alloc);
            defer spatial.deinit(app.core_app.alloc);
            const placement = host.splitPanePlacement(
                content_rect,
                spatial,
                attach.tab.focused,
                true,
                false,
            );
            _ = applyChildRect(hwnd, &self.placement, layoutRectToWin32(placement.pane_rect));
        }
        self.size = try app.clientSize(hwnd);
        log.debug("surface.init client size width={} height={}", .{ self.size.width, self.size.height });

        // Set initial content_scale from host DPI before core init
        self.content_scale = .{
            .x = @as(f32, @floatFromInt(host.current_dpi)) / 96.0,
            .y = @as(f32, @floatFromInt(host.current_dpi)) / 96.0,
        };

        if (opts.clone_state_from) |source| {
            if (sharesHostWindowState(self.host_id, source.host_id)) {
                self.copySharedWindowStateFrom(source, .{});
            }
        }

        if (app.test_surface_init_stage) |stage| try stage(self, .core_surface) else {
            try self.core_surface.init(
                app.core_app.alloc,
                config,
                app.core_app,
                app,
                self,
            );
            self.core_initialized = true;
            log.debug("surface.init core surface initialized", .{});
            // A pane made behind its tab's focus (a restored layout) was
            // marked dimmed before it had a renderer to tell.
            self.flushSplitDimmed();
            // The core read the child's size when its init began, and the
            // core's own init-time actions can lay the host out again before
            // it ends. `syncCoreSizeFromClientRect` recorded any such move in
            // `self.size` but could not forward it yet, and from here on it
            // compares against that record, so nothing would ever forward it.
            // The core ignores a size it already has.
            self.core_surface.sizeCallback(self.size) catch |err| {
                log.err("win32 size callback failed err={}", .{err});
            };
        }
        // Stop the core if a later step fails. This runs first, while the GL
        // context and the window its threads draw to are still alive.
        errdefer self.deinitCore();

        // Seed the dynamic title after core init's automatic command title,
        // but before any path can show the host. No UI mailbox has drained
        // yet, so later console title messages still win. A configured title
        // was already applied by the core and remains authoritative.
        if (opts.adopted_session) |pending| if (config.title == null) {
            self.setTitle(pending.title) catch |err| {
                log.warn("adopted window startup title failed err={}", .{err});
            };
        };

        // Same-host tabs/splits must stay hidden through init, but they still
        // need an initial occlusion sync so hidden child GL surfaces stop
        // rendering before activation ordering runs.
        const activate_during_init = shouldShowSurfaceImmediately(opts.host_id);
        const window_start = WindowStart.forNewSurface(config, opts);
        const keeps = WindowKeeps.forNewSurface(config, opts);
        self.setVisible(activate_during_init);
        sys.DragAcceptFiles(hwnd, 1);

        if (sys.GetFocus() == hwnd) {
            self.window_focused = true;
        }

        // Both the core and renderer default to focused, so always send the
        // actual state. Otherwise the first focus event may be ignored as
        // unchanged for a surface that started unfocused.
        self.focusChanged(self.window_focused);
        if (activate_during_init) {
            // Must stay ahead of every path below that can show the host
            // window (`SW_SHOWNOACTIVATE` / `presentWindow`): applying the
            // layered style to an already-visible window is what produces an
            // opaque-then-fade flash. No unit test observes that ordering
            // — see the doc comment on `applyInitialBackgroundOpacity`.
            self.applyInitialBackgroundOpacity(if (keeps.background_opacity) null else opts.clone_state_from);
            try host.refreshChrome();
            try host.layout();
            // `maximize` and `fullscreen` (#496), before the first show, so
            // the window first appears in that state. Core init has already
            // given it `window-width`/`window-height`, so that is the normal
            // rect it returns to. A clone takes them once it has the
            // source's state, below.
            if (opts.clone_state_from == null) self.applyWindowStart(window_start);
            // The top-level host was created hidden and stays hidden until GL
            // and core initialization have succeeded, so a startup failure
            // reaches the fatal dialog without first presenting a blank host
            // window. Same-host tabs and splits never take this path.
            if (opts.show.showCommand()) |show_command| {
                if (host.hwnd) |host_hwnd| {
                    _ = sys.ShowWindow(host_hwnd, show_command);
                    _ = sys.UpdateWindow(host_hwnd);
                }
            }
            if (opts.show.takesFocus()) self.presentWindow();
            if (app.update_startup_ready) {
                // The first window of a start that opened none (initial-window
                // off) is where the failed-install banner can first show.
                app.reportFailedInstallerApply();
                app.maybeScheduleAutomaticUpdateCheck();
            }
            try self.requestRepaint();
        }

        if (opts.clone_state_from) |source| {
            if (!sharesHostWindowState(self.host_id, source.host_id)) {
                try self.inheritWindowStateFrom(source, keeps);
                // After it: a normal source ends in SW_RESTORE.
                self.applyWindowStart(window_start);
            }
        }
        if (shell_prepared) |*prepared| {
            try prepared.commit(&app.shell_runtime);
            self.shell_committed = true;
            // The caller's activation shows and focuses the new pane, which
            // is the model's `focus_surface`.
            app.applyShellEffects(prepared.effects(), .{ .focus = false });
            if (self.window_focused) app.commitShellSurfaceFocus(self);
        }
        // Existing-host tab/split creation is intentionally provisional here:
        // the shell reducer selects the new entity before the caller activates
        // its native surface. The next activation performs the stable audit.
        if (opts.host_id == null)
            app.auditShellNativeMapping("surface-create")
        else
            app.shell_audit_after_activation = true;
        // Only now does WM_DESTROY own the Surface: it runs `destroy`, which
        // frees it. Set any earlier, a failed step above has its unwinding
        // DestroyWindow free the Surface under these errdefers, and then
        // `createWindowSurface` frees it again.
        self.destroy_on_wm_destroy = true;
        // A terminal opened after the session's last window went (quit-after-
        // last-window-closed = false, inside its delay, or while a quick
        // terminal or a window kept for undo stays) opens the session again.
        // Not before init commits: a failed one leaves no window, and the
        // snapshot must still stand. Nor for the quick terminal, which is
        // never part of the session.
        if (!host.quick_terminal) app.session_state_saved_before_last_host_close = false;
        // Any terminal the user opens after the startup restore, quick
        // terminal included, uses the session; the restore's own panes all
        // commit before `restoreSessionState` sets this.
        app.restored_session_untouched = false;
    }

    test "Surface.init that fails after the core starts is unwound once, by init" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var existing: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &.{.{ .storage = &existing, .host = &host }},
            .tabs = &.{.{ .host = &host, .surface = &existing, .id = 1 }},
            .shell_runtime_initialized = true,
        });
        defer session.deinit();
        // With COM, a tab button gets a UIA provider, as in the app.
        app.initComApartment();
        defer if (app.com_initialized) sys.OleUninitialize();
        try app.ensureWindowClass();
        defer _ = sys.UnregisterClassW(class_name, app.hinstance);
        const host_hwnd = try createTestHostWindow();
        defer _ = sys.DestroyWindow(host_hwnd);
        host.hwnd = host_hwnd;
        // The rollback's chrome refresh caches the window title, which
        // `Host.deinit` would free and the test session does not.
        defer if (host.cached_window_title) |value| std.testing.allocator.free(value);

        var shell_window = try app.shell_runtime.prepare(.create_window);
        defer shell_window.deinit();
        try shell_window.commit(&app.shell_runtime);
        host.shell_id = shell_window.created.window;

        const Stage = struct {
            var stale: bool = false;
            var surface_hwnd: ?HWND = null;

            fn run(surface: *Surface, stage: InitStage) anyerror!void {
                surface_hwnd = surface.hwnd;
                if (stage != .core_surface) return;
                // What the core's `set_title` leaves as it starts: the
                // title, and a button with a UIA provider for the new tab.
                // `syncTabButtons` cannot make the button here, since the
                // test executable has no manifest for the layered chrome.
                surface.title = try surface.app.core_app.alloc.dupeZ(u8, "PKG-05");
                const owner = surface.host.?;
                const tab = &owner.tabs.items[owner.tabs.items.len - 1];
                tab.button_hwnd = sys.CreateWindowExW(
                    0,
                    prompt_button_class,
                    std.unicode.utf8ToUtf16LeStringLiteral(""),
                    c.WS_CHILD,
                    0,
                    0,
                    1,
                    1,
                    owner.hwnd,
                    null,
                    surface.app.hinstance,
                    null,
                ) orelse return lastError();
                tab.uia_provider = owner.createChromeUiaProvider(tab.button_hwnd.?, owner.tabItemUiaState(tab.id));
                // Something commits to the shell runtime meanwhile, as an
                // interleaved focus change can, so the new tab's prepared
                // transaction no longer applies.
                if (stale) surface.app.shell_runtime.revision +%= 1;
            }
        };
        Stage.stale = true;
        Stage.surface_hwnd = null;
        app.test_surface_init_stage = &Stage.run;

        // The app has no window, and its quit timer is counting down.
        app.running = true;
        app.config.@"quit-after-last-window-closed-delay" = .{ .duration = 60 * std.time.ns_per_s };
        app.startQuitTimer();
        defer app.stopQuitTimer();
        try std.testing.expect(app.quit_timer_id != null);
        // The owner's last window already took the session's final snapshot.
        app.session_state_saved_before_last_host_close = true;
        // And the startup restore brought the session back, untouched since.
        app.restored_session_untouched = true;

        // A reader was told about the new tab's button, so it hears that the
        // button is gone again when init fails.
        const root = try win32_uia.RootProvider.create(std.testing.allocator, @ptrFromInt(0x1));
        defer _ = win32_uia.RootProvider.Release(&root.base);
        host.root_uia_provider = root;
        defer host.root_uia_provider = null;
        const announced = win32_uia.events.testing_structure_changes;

        // Before the fix, the unwinding DestroyWindow sent WM_DESTROY, which
        // freed the Surface; the errdefers then read it and
        // `createWindowSurface` freed it a second time. The title, the tab's
        // UIA provider (`Tab.deinit` asserts it is gone) and the quit timer
        // `addSurface` stopped are left for init's errdefers to undo.
        try std.testing.expectError(
            error.StaleRevision,
            app.createWindowSurface(&app.config, default_title, .{ .host_id = host.id }),
        );
        try std.testing.expectEqual(announced + 1, win32_uia.events.testing_structure_changes);
        app.running = false;
        try std.testing.expect(sys.IsWindow(Stage.surface_hwnd.?) == 0);
        try std.testing.expectEqual(@as(usize, 1), host.tabs.items.len);
        try std.testing.expectEqual(&existing, host.tabs.items[0].focusedSurface().?);
        try std.testing.expectEqual(@as(usize, 0), app.registry.windows.items.len);
        try std.testing.expectEqual(@as(usize, 0), core_app.surfaces.items.len);
        try std.testing.expect(app.quit_timer_id != null);
        // No terminal opened, so `terminate` must still keep that snapshot
        // rather than save the empty app over it, and nothing used the
        // restored session.
        try std.testing.expect(app.session_state_saved_before_last_host_close);
        try std.testing.expect(app.restored_session_untouched);

        // A tab the quick terminal opens is never part of the session, so the
        // snapshot stands (#497). Before, any committed init cleared it.
        Stage.stale = false;
        host.quick_terminal = true;
        const in_quick_terminal = try app.createWindowSurface(&app.config, default_title, .{ .host_id = host.id });
        host.quick_terminal = false;
        const snapshot_stood = app.session_state_saved_before_last_host_close;
        core_app.deleteSurface(in_quick_terminal);
        try std.testing.expect(sys.DestroyWindow(in_quick_terminal.hwnd.?) != 0);
        try std.testing.expectEqual(@as(usize, 1), host.tabs.items.len);
        try std.testing.expect(snapshot_stood);
        // But the user opened a terminal, so the restored session is used.
        try std.testing.expect(!app.restored_session_untouched);

        // Once init returns, the window owns the Surface: destroying it frees
        // the Surface once, and its tab and button with it.
        const created = try app.createWindowSurface(&app.config, default_title, .{ .host_id = host.id });
        try std.testing.expect(created.destroy_on_wm_destroy);
        // A terminal that did open is part of the session again.
        try std.testing.expect(!app.session_state_saved_before_last_host_close);
        try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
        // `destroy` unregisters the surfaces whose core it stops, and the
        // stub started none.
        core_app.deleteSurface(created);
        try std.testing.expect(sys.DestroyWindow(created.hwnd.?) != 0);
        try std.testing.expectEqual(@as(usize, 1), host.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 0), app.registry.windows.items.len);
    }

    test "Surface.init that fails before the core starts destroys the host window it created" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        const hinstance = app.hinstance;
        defer {
            // `createHost` registers its classes and nothing unregisters them.
            _ = sys.UnregisterClassW(class_name, hinstance);
            _ = sys.UnregisterClassW(host_class_name, hinstance);
            _ = sys.UnregisterClassW(palette_list_class_name, hinstance);
            _ = sys.UnregisterClassW(scrollbar_class_name, hinstance);
        }
        try app.ensureWindowClass();

        const Stage = struct {
            var host_hwnd: ?HWND = null;

            fn run(surface: *Surface, stage: InitStage) anyerror!void {
                std.debug.assert(stage == .gl_context);
                host_hwnd = surface.host.?.hwnd;
                // As a lost or below-floor GPU fails a new window.
                return error.TestGLContextFailed;
            }
        };
        Stage.host_hwnd = null;
        app.test_surface_init_stage = &Stage.run;
        // A new window forwarded in after the owner's last window closed
        // and took the session's final snapshot.
        app.session_state_saved_before_last_host_close = true;

        try std.testing.expectError(
            error.TestGLContextFailed,
            app.createWindowSurface(&app.config, default_title, .{}),
        );
        // No window opened, so that snapshot must stand: no checkpoint may
        // write over it until a terminal opens.
        try std.testing.expect(app.session_state_saved_before_last_host_close);
        const host_hwnd = Stage.host_hwnd.?;
        defer if (sys.IsWindow(host_hwnd) != 0) {
            _ = sys.DestroyWindow(host_hwnd);
        };
        // Before the fix the Host was freed and its hidden window left behind.
        try std.testing.expect(sys.IsWindow(host_hwnd) == 0);
        try std.testing.expectEqual(@as(usize, 0), app.registry.hosts.items.len);
    }

    pub fn deinit(self: *Surface) void {
        self.destroy();
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn takeAdoptedSession(self: *Surface) ?ptypkg.AdoptedSession {
        const result = self.adopted_session;
        self.adopted_session = null;
        return result;
    }

    pub fn ref(self: *Surface, alloc: Allocator) !*Surface {
        _ = alloc;
        return self;
    }

    pub fn unref(self: *Surface, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn eql(a: *const Surface, b: *const Surface) bool {
        return a == b;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_active: bool) void {
        // Core routes `process_active = true` here when
        // `config.confirm-close-surface` is set AND the terminal
        // cursor is not at a shell prompt — see
        // `Surface.needsConfirmQuit()`. Honour it with the non-modal
        // `HostOverlayMode.confirm` overlay: a chrome-themed Accept /
        // Cancel pair, focus trap, Esc cancels, Enter accepts. No
        // pump re-entry (unlike `MessageBoxW`).
        //
        // Cannot be `*const self` in practice: the overlay owns a
        // callback pointer back to this Surface for the accept
        // path, so we need the address. Zig lets us take `@constCast`
        // here — the stored pointer is only dereferenced back on the
        // UI thread, exactly where the core caller already ran.
        if (process_active) {
            const mutable: *Surface = @constCast(self);
            const host = mutable.host orelse {
                // No host = no overlay available = fall back to the
                // direct destroy. Shouldn't happen in practice; the
                // Win32 apprt always attaches a Host before close
                // paths fire.
                _ = mutable.requestClose();
                return;
            };
            // Not always the key that closed a terminal in front: a read-only
            // terminal whose program exits closes itself and asks, in
            // whichever tab it is.
            var title_buf: [32]u8 = undefined;
            var prompt: ConfirmPrompt = .{
                .title = "Close this terminal?",
                .body = "A process is still running. Closing this surface will terminate it.",
                .accept_label = "Close",
                .cancel_label = "Cancel",
                // Nothing to preview: this prompt is about a running
                // process, not about a payload.
            };
            const named_body = host.nameBackgroundTerminal(&prompt, mutable, &title_buf);
            defer if (named_body) |text| mutable.app.core_app.alloc.free(text);
            host.showConfirm(
                prompt,
                &surfaceConfirmCloseAccept,
                null,
                @ptrCast(mutable),
            ) catch |err| {
                // Cannot bypass the confirmation on overlay setup
                // failure — core asked us to protect a running
                // process, and unilaterally destroying the HWND here
                // would defeat `confirm-close-surface` every time
                // the overlay couldn't render. Leave the surface
                // alive; the user can retry the close action, and
                // if the overlay keeps failing that's a separate
                // (and loud) bug to file.
                std.log.warn("confirm overlay unavailable err={}; declining close to honour confirm-close-surface", .{err});
            };
            return;
        }
        const mutable: *Surface = @constCast(self);
        _ = mutable.requestClose();
    }

    /// Core's `confirm-close-surface` answer for this pane (a running
    /// process, `always`, or read-only mode), for a close that ends more
    /// than this pane. A pane whose core is not up has no process to lose.
    pub fn needsCloseConfirm(self: *Surface) bool {
        return self.core_initialized and self.core_surface.needsConfirmQuit();
    }

    /// `needsCloseConfirm` for a sent message (a Restart Manager query),
    /// which can arrive while this thread holds the renderer mutex: the core's
    /// copy path holds it across `EmptyClipboard`, which dispatches sent
    /// messages while it waits, and the mutex is not recursive. A mutex it
    /// cannot take counts as needing confirmation.
    pub fn needsCloseConfirmNoWait(self: *Surface) bool {
        return self.core_initialized and (self.core_surface.needsConfirmQuitNoWait() orelse true);
    }

    pub fn requestClose(self: *Surface) bool {
        const hwnd = self.hwnd orelse return false;
        if (self.pending_close_tree != null or self.pending_shell_close != null) return false;
        const found = Host.findTabForSurface(self) orelse {
            // Detached structural-history objects are deliberately outside
            // active ShellState and can be destroyed during history disposal.
            if (self.host) |host| if (host.structural_history_disposing) {
                return sys.DestroyWindow(hwnd) != 0;
            };
            log.err("refusing unpreflighted surface close: native tab mapping missing", .{});
            return false;
        };
        const handle = found.tab.findHandle(self) orelse return false;

        var next_tree: ?SplitTreeSurface = null;
        if (found.tab.tree.nodes.len > 1) {
            next_tree = found.tab.tree.remove(self.app.core_app.alloc, handle) catch |err| {
                log.warn("surface close preflight tree build failed err={}", .{err});
                return false;
            };
        }
        defer if (next_tree) |*tree| tree.deinit();

        if (!self.invalidateStructuralHistoryForClose()) return false;

        var shell_close: ?win32_shell.runtime.Prepared = null;
        if (self.app.shell_runtime_initialized) {
            const pane_id = self.shell_id orelse {
                log.err("refusing surface close: shell pane mapping missing", .{});
                return false;
            };
            const intent: win32_shell.intent.Intent = if (found.tab.tree.nodes.len > 1)
                .{ .close_pane = pane_id }
            else close_tab: {
                const tab_id = found.tab.shell_id orelse {
                    log.err("refusing surface close: shell tab mapping missing", .{});
                    return false;
                };
                break :close_tab .{ .close_tab = tab_id };
            };
            shell_close = self.app.shell_runtime.prepare(intent) catch |err| {
                log.err("surface close shell preflight rejected err={}", .{err});
                return false;
            };
        }
        defer if (shell_close) |*prepared| prepared.deinit();

        self.pending_close_tree = next_tree;
        next_tree = null;
        self.pending_shell_close = shell_close;
        shell_close = null;
        // The session's last pane (`close_surface`, its shell exiting): saved
        // now, while it is whole; `destroy` frees its strings first. Not
        // when its window's close (`closeConfirmed`) saved the whole window
        // and is closing its panes one by one.
        const saved_here = !self.app.session_state_saved_before_last_host_close and
            found.tab.tree.nodes.len == 1 and found.host.tabs.items.len == 1 and
            self.app.closingEndsSession(found.host);
        if (saved_here) self.app.saveSessionAsItEnds();
        if (sys.DestroyWindow(hwnd) != 0) return true;

        if (saved_here) self.app.session_state_saved_before_last_host_close = false;
        if (self.pending_close_tree) |*tree| tree.deinit();
        self.pending_close_tree = null;
        if (self.pending_shell_close) |*prepared| prepared.deinit();
        self.pending_shell_close = null;
        return false;
    }

    pub fn captureUndoClearScreen(self: *Surface) !void {
        try self.captureUndoTerminalState(.clear_screen);
    }

    pub fn captureUndoReset(self: *Surface) !void {
        try self.captureUndoTerminalState(.reset);
    }

    pub fn invalidateRedoForSnapshotlessLocalAction(self: *Surface) void {
        self.undo_stack.clearRedo();
        self.invalidateRedoForNewLocalAction();
    }

    pub fn invalidateRedoForNewLocalAction(self: *Surface) void {
        if (self.host) |host| _ = host.clearStructuralRedo();
    }

    pub fn invalidateRedoForUnsupportedStructuralAction(self: *Surface) void {
        self.undo_stack.clearRedo();
        if (self.host) |host| _ = host.clearStructuralRedo();
    }

    pub fn invalidateRedoForUnsupportedTabStructuralAction(self: *Surface) void {
        const found = Host.findTabForSurface(self) orelse {
            self.invalidateRedoForUnsupportedStructuralAction();
            return;
        };
        found.tab.clearRedoHistory();
        _ = found.host.clearStructuralRedo();
    }

    pub fn invalidateStructuralHistoryForClose(self: *Surface) bool {
        const found = Host.findTabForSurface(self) orelse return true;
        found.tab.clearRedoHistory();
        return found.host.tryClearStructuralHistory(.normal);
    }

    pub fn invalidateStructuralHistoryForDestroy(self: *Surface) void {
        const found = Host.findTabForSurface(self) orelse return;
        found.tab.clearRedoHistoryExcept(self);
        if (found.tab.tree.nodes.len == 1) {
            found.host.clearStructuralHistory(.normal);
            return;
        }
        _ = found.host.clearStructuralRedo();
    }

    pub fn pushUndoEntryAndInvalidateRedo(
        self: *Surface,
        entry: win32_undo.Entry,
    ) !void {
        // Redo invalidation must happen AFTER the new undo entry is
        // committed. If the push fails, the action is aborted and the
        // existing redo branch must remain reachable.
        try self.undo_stack.push(entry);
        self.invalidateRedoForNewLocalAction();
        self.app.scheduleUndoPruneTimer();
    }

    fn captureUndoTerminalState(self: *Surface, kind: win32_undo.Kind) !void {
        if (self.undo_capture_suspended) return;

        self.undo_stack.discardExpired(self.app.undoCutoffTimestampMs());
        const captured = captured: {
            self.core_surface.renderer_state.mutex.lock();
            defer self.core_surface.renderer_state.mutex.unlock();
            break :captured .{
                .bytes = try captureTerminalUndoStateBytes(
                    self.app.core_app.alloc,
                    self.core_surface.renderer_state.terminal,
                ),
                .generation = self.core_surface.io.pty_clear_generation,
            };
        };
        const state_bytes = captured.bytes;
        // Ownership moves into `entry` below.

        var entry: win32_undo.Entry = .{
            .kind = kind,
            .snapshot = switch (kind) {
                .clear_screen => .{ .clear_screen = .{ .state_bytes = state_bytes } },
                .reset => .{ .reset = .{ .state_bytes = state_bytes } },
            },
            .timestamp_ms = sys.GetTickCount64(),
            .sequence_id = self.app.nextUndoSequence(),
            .pty_clear_generation = captured.generation,
        };
        errdefer entry.deinit(self.app.core_app.alloc);
        try self.pushUndoEntryAndInvalidateRedo(entry);
    }

    pub const captureSessionScrollback = session_module.captureSessionScrollback;

    pub const restoreSessionScrollback = session_module.restoreSessionScrollback;

    fn restoreUndoSnapshot(self: *Surface, entry: *const win32_undo.Entry) void {
        const alloc = self.app.core_app.alloc;
        const state_bytes = switch (entry.snapshot) {
            .clear_screen => |value| value.state_bytes,
            .reset => |value| value.state_bytes,
        };
        var restored: RestoredTerminalUndoState = .{};

        {
            self.core_surface.renderer_state.mutex.lock();
            defer self.core_surface.renderer_state.mutex.unlock();
            restored = restoreTerminalUndoState(
                self.core_surface.renderer_state.terminal,
                state_bytes,
                entry.pty_clear_generation != self.core_surface.io.pty_clear_generation,
            );
        }

        // Undo snapshots are serialized terminal state and may predate the
        // normal title setters. Keep the title-report cache on the same
        // control-byte policy as live OSC and automation title updates.
        appendSanitizedTitle(alloc, &self.title, restored.title) catch |err| {
            log.warn("undo snapshot title cache sync failed err={}", .{err});
        };
        appendOwnedString(alloc, &self.pwd, restored.pwd) catch |err| {
            log.warn("undo snapshot pwd cache sync failed err={}", .{err});
        };
        self.setScrollbar(restored.scrollbar) catch |err| {
            log.warn("undo snapshot scrollbar sync failed err={}", .{err});
        };
        self.refreshWindowTitle() catch |err| {
            log.warn("undo snapshot window title refresh failed err={}", .{err});
        };
        self.requestRepaint() catch |err| {
            log.warn("undo snapshot repaint request failed err={}", .{err});
        };
    }

    fn applyLocalUndoEntry(
        self: *Surface,
        entry: *const win32_undo.Entry,
        mode: enum { undo, redo },
    ) ?[]const u8 {
        switch (mode) {
            .undo => {
                self.restoreUndoSnapshot(entry);
                return switch (entry.kind) {
                    .clear_screen => "Clear screen undone.",
                    .reset => "Terminal reset undone.",
                };
            },

            .redo => {
                self.undo_capture_suspended = true;
                defer self.undo_capture_suspended = false;

                if (!self.reapplyUndoableAction(entry.kind)) return null;
                return switch (entry.kind) {
                    .clear_screen => "Clear screen redone.",
                    .reset => "Terminal reset redone.",
                };
            },
        }
    }

    fn reapplyUndoableAction(self: *Surface, kind: win32_undo.Kind) bool {
        switch (kind) {
            .clear_screen => {
                {
                    self.core_surface.renderer_state.mutex.lock();
                    defer self.core_surface.renderer_state.mutex.unlock();
                    if (self.core_surface.io.terminal.screens.active_key == .alternate) return false;
                }
                self.core_surface.io.queueMessage(
                    .{ .clear_screen = .{ .history = true } },
                    .unlocked,
                );
                return true;
            },

            .reset => {
                // The reset action itself: it keeps the Win32 input mode
                // ConPTY asked for and clears ConPTY's buffer too. Capture is
                // suspended, so it records no undo entry of its own.
                _ = self.core_surface.performBindingAction(.reset) catch |err| {
                    log.warn("redo reset failed err={}", .{err});
                    return false;
                };
                var scrollbar: terminal.Scrollbar = .zero;
                {
                    self.core_surface.renderer_state.mutex.lock();
                    defer self.core_surface.renderer_state.mutex.unlock();
                    scrollbar = self.core_surface.renderer_state.terminal.screens.active.pages.scrollbar();
                }

                appendOwnedString(self.app.core_app.alloc, &self.title, null) catch |err| {
                    log.warn("redo reset title cache clear failed err={}", .{err});
                };
                appendOwnedString(self.app.core_app.alloc, &self.pwd, null) catch |err| {
                    log.warn("redo reset pwd cache clear failed err={}", .{err});
                };
                self.setScrollbar(scrollbar) catch |err| {
                    log.warn("redo reset scrollbar sync failed err={}", .{err});
                };
                self.refreshWindowTitle() catch |err| {
                    log.warn("redo reset window title refresh failed err={}", .{err});
                };
                self.requestRepaint() catch |err| {
                    log.warn("redo reset repaint request failed err={}", .{err});
                };
                return true;
            },
        }
    }

    fn canReapplyUndoableAction(self: *Surface, kind: win32_undo.Kind) bool {
        switch (kind) {
            .clear_screen => {
                self.core_surface.renderer_state.mutex.lock();
                defer self.core_surface.renderer_state.mutex.unlock();
                return self.core_surface.io.terminal.screens.active_key != .alternate;
            },
            .reset => return true,
        }
    }

    fn localRedoUnavailableMessage(kind: win32_undo.Kind) []const u8 {
        return switch (kind) {
            .clear_screen => "Redo unavailable in alternate screen.",
            .reset => unreachable,
        };
    }

    pub fn applyLatestLocalUndo(self: *Surface) !?[]const u8 {
        const entry = (try self.undo_stack.popForUndo()) orelse return null;
        return self.applyLocalUndoEntry(entry, .undo);
    }

    pub fn applyLatestLocalRedo(self: *Surface) !?[]const u8 {
        const next = self.undo_stack.peekRedo() orelse return null;
        if (!self.canReapplyUndoableAction(next.kind)) return localRedoUnavailableMessage(next.kind);

        const entry = (try self.undo_stack.popForRedo()) orelse return null;
        const kind = entry.kind;
        const message = self.applyLocalUndoEntry(entry, .redo);
        if (message == null) {
            self.undo_stack.restoreLastRedoPop();
            return localRedoUnavailableMessage(kind);
        }
        return message;
    }

    pub fn present(self: *Surface) void {
        self.app.activateSurface(self);
    }

    pub fn presentWindow(self: *Surface) void {
        if (self.host) |host| {
            host.present();
            if (self.hwnd) |hwnd| _ = sys.SetFocus(hwnd);
            return;
        }
        const hwnd = self.hwnd orelse return;
        _ = sys.ShowWindow(hwnd, c.SW_SHOW);
        _ = sys.SetForegroundWindow(hwnd);
        _ = sys.SetFocus(hwnd);
    }

    pub fn windowHwnd(self: *const Surface) ?HWND {
        if (self.host) |host| return host.hwnd;
        return self.hwnd;
    }

    /// Whether the top-level window carries `WS_SYSMENU`: fullscreen strips
    /// it, and so does `window-decoration = none` on a frameless window, on
    /// Windows 10 and for the quick terminal (`undecoratedKeepsFrame`).
    /// `SC_KEYMENU` on such a window has no menu to open.
    pub fn hasWindowMenu(self: *const Surface) bool {
        const top = self.windowHwnd() orelse return false;
        const style: usize = @bitCast(sys.GetWindowLongPtrW(top, c.GWL_STYLE));
        return (style & c.WS_SYSMENU) != 0;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.effectiveTitle();
    }

    pub fn terminalUiaProvider(self: *Surface) !*win32_uia.TerminalProvider {
        if (self.terminal_accessibility == null) {
            self.terminal_accessibility = try win32_terminal_accessibility.TerminalAccessibilitySession.create(
                std.heap.page_allocator,
                .{
                    .ctx = @ptrCast(self),
                    .hwnd = terminalAccessibilityHwnd,
                    .name = terminalAccessibilityName,
                    .focused = terminalAccessibilityFocused,
                    .capture = terminalAccessibilityCapture,
                    .scroll = terminalAccessibilityScroll,
                    .viewport = terminalAccessibilityViewport,
                    .defer_provider_release = terminalAccessibilityDeferProviderRelease,
                },
                c.WM_WINHOSTTY_UIA_QUERY_REFRESH,
                c.TERMINAL_UIA_TIMER_ID,
            );
        }
        const provider = try self.terminal_accessibility.?.acquireProvider();
        self.syncTerminalAccessibilityOutputInterest();
        return provider;
    }

    fn syncTerminalAccessibilityOutputInterest(self: *Surface) void {
        const interested = if (self.terminal_accessibility) |session|
            session.outputInterested()
        else
            false;
        if (!interested) {
            if (self.terminal_accessibility) |session| {
                session.resetSemanticOutputContinuity();
            }
        }
        self.core_surface.setTerminalOutputInterested(interested);
    }

    pub fn drainTerminalAccessibilityOutput(self: *Surface) void {
        self.syncTerminalAccessibilityOutputInterest();
        const session = self.terminal_accessibility orelse return;
        if (!session.outputInterested()) return;
        self.core_surface.drainTerminalOutput(
            @ptrCast(session),
            terminalAccessibilityOutputCallback,
        );
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return try App.resolveSurfaceSizeWithContext(
            self.app,
            self.size,
            self.hwnd,
            App.clientSize,
        );
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = self;
        return clipboard_type == .standard;
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        if (clipboard_type != .standard) return false;
        // A paste, from any key, menu or palette; a program's own read is not.
        if (state == .paste) self.noteProgramInput();
        // A program's read that would only be declined does not read the
        // clipboard first.
        if (state == .osc_52_read and self.core_surface.config.clipboard_read == .ask) {
            self.declineProgramRequest() catch |err| {
                log.info("clipboard read request declined err={}", .{err});
                return false;
            };
        }

        // Only a user's paste takes copied files; a program's read is text.
        const include_files = state == .paste;
        const contents = if (self.app.test_clipboard_source) |source|
            try selectClipboardContents(self.app.core_app.alloc, include_files, source)
        else
            try self.readClipboard(include_files);
        return self.completeClipboardRead(state, contents);
    }

    /// Finishes a clipboard request with what the clipboard held, owned by
    /// `core_app.alloc`.
    pub fn completeClipboardRead(
        self: *Surface,
        state: apprt.ClipboardRequest,
        contents: ClipboardContents,
    ) !bool {
        const text: ?[:0]u8 = switch (contents) {
            .none => null,
            .text => |held| held,
            .files => |paths| files: {
                defer self.app.core_app.alloc.free(paths);
                // Copied files (Explorer's Copy) paste as their paths, the
                // way a drop types them, after the same paste protection.
                // A program's OSC 52 read never sees a file name.
                if (state == .paste and paths.len > 0) {
                    pasteFilePayload(self, paths) catch |err| {
                        std.log.warn("clipboard file paths paste failed err={}", .{err});
                        return false;
                    };
                    return true;
                }
                break :files null;
            },
        };
        // `str` is always owned by `core_app.alloc`, so one defer covers both
        // clipboard reads and the synthesized empty-string fallback.
        const str: [:0]u8 = text orelse switch (state) {
            // A user's paste of a clipboard with no text (an image, say):
            // tell a program with bracketed paste on that a paste happened,
            // as Windows Terminal does. A program's OSC 52 read gets the
            // empty reply below and never an empty paste.
            .paste => return try self.core_surface.completeClipboardPasteWithoutText(),
            .osc_52_read => try self.app.core_app.alloc.dupeZ(u8, ""),
            .osc_52_write => unreachable,
        };
        defer self.app.core_app.alloc.free(str);

        // An empty text is no text to paste either; the core ignores it.
        if (state == .paste and str.len == 0) {
            return try self.core_surface.completeClipboardPasteWithoutText();
        }

        self.core_surface.completeClipboardRequest(
            state,
            str,
            false,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                // Defer to the non-modal confirm overlay; dupes
                // `str` into surface-owned storage so the local
                // `text` lifetime doesn't need to span the async
                // gap. On accept `surfaceConfirmPasteAccept` calls
                // `completeClipboardRequest(state, …, true)`.
                self.requestPasteConfirm(state, str) catch |inner| {
                    std.log.warn("paste confirm dispatch failed err={}", .{inner});
                    return false;
                };
            },

            else => return err,
        };

        return true;
    }

    pub fn setClipboard(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        if (clipboard_type != .standard) return;
        if (confirm) {
            // Non-modal confirm path: dup `contents` into surface-owned
            // storage + show the overlay. On accept
            // `surfaceConfirmWriteAccept` runs the same html-then-
            // plain branch as below; on cancel the dup is freed and
            // no write happens. Fire-and-forget from core's POV.
            self.requestWriteConfirm(clipboard_type, contents) catch |err| {
                std.log.warn("clipboard write confirm dispatch failed err={}", .{err});
            };
            return;
        }

        // Scan for text/html and text/plain. When both are offered
        // (e.g. `copy_to_clipboard = .html` emits both), write them
        // in a single OpenClipboard/EmptyClipboard/Close cycle so
        // consumers that understand CF_HTML (Word, WordPad, OneNote)
        // get the styled fragment and consumers that don't (Notepad,
        // cmd.exe) still get usable plain text.
        var html_content: ?[]const u8 = null;
        var plain_content: ?[]const u8 = null;
        for (contents) |content| {
            if (std.mem.eql(u8, content.mime, "text/html")) {
                html_content = content.data;
            } else if (std.mem.eql(u8, content.mime, "text/plain")) {
                plain_content = content.data;
            }
        }

        if (html_content) |html| {
            try self.writeClipboardHtml(html, plain_content);
            return;
        }
        if (plain_content) |plain| {
            try self.writeClipboardText(plain);
            return;
        }
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        var env = try internal_os.getEnvMap(self.app.core_app.alloc);
        errdefer env.deinit();

        if (env.get("USERPROFILE") == null) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (try internal_os.windows.knownFolderPathUtf8(
                &internal_os.windows.FOLDERID_Profile,
                &buf,
            )) |profile| {
                try env.put("USERPROFILE", profile);
            }
        }

        if (env.get("LOCALAPPDATA") == null) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            if (try internal_os.windows.knownFolderPathUtf8(
                &internal_os.windows.FOLDERID_LocalAppData,
                &buf,
            )) |local_appdata| {
                try env.put("LOCALAPPDATA", local_appdata);
            }
        }

        return env;
    }

    pub fn redrawInspector(self: *Surface) void {
        if (!self.inspector_visible) return;
        self.requestRepaint() catch |err| {
            log.err("win32 inspector repaint request failed err={}", .{err});
        };
    }

    pub fn noteBenchmarkMemoryStage(
        self: *Surface,
        stage: BenchmarkMemoryStage,
        surface_id: ?u64,
    ) void {
        _ = self.memory_stage_trace.note(
            stage,
            @intCast(@intFromPtr(self)),
            surface_id,
        );
    }

    pub fn publishBenchmarkMemorySurfaceId(self: *Surface, surface_id: u64) void {
        self.memory_stage_trace.publishSurfaceId(surface_id);
    }

    pub fn setBenchmarkMemoryGeometry(
        self: *Surface,
        surface_width_px: u32,
        surface_height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
        columns: u32,
        rows: u32,
    ) void {
        self.memory_stage_trace.setGeometry(
            surface_width_px,
            surface_height_px,
            cell_width_px,
            cell_height_px,
            columns,
            rows,
        );
    }

    pub fn noteBenchmarkIoReaderSpawned(self: *Surface, surface_id: u64) void {
        self.memory_stage_trace.noteIoReaderSpawned(@intCast(@intFromPtr(self)), surface_id);
    }

    pub fn noteBenchmarkRendererThreadSpawned(self: *Surface, surface_id: u64) void {
        self.memory_stage_trace.noteRendererThreadSpawned(@intCast(@intFromPtr(self)), surface_id);
    }

    pub fn noteBenchmarkIoThreadSpawned(self: *Surface, surface_id: u64) void {
        self.memory_stage_trace.noteIoThreadSpawned(@intCast(@intFromPtr(self)), surface_id);
    }

    fn setBenchmarkWglPixelFormat(
        self: *Surface,
        value: pixel_format.WglPixelFormatProvenance,
    ) void {
        self.memory_stage_trace.setWglPixelFormat(value);
    }

    pub const beginRendererFrameUpdate = surface_presentation.beginRendererFrameUpdate;

    pub const completeRendererRepaintCoalesce = surface_presentation.completeRendererRepaintCoalesce;

    pub const beginRendererRepaintRequest = surface_presentation.beginRendererRepaintRequest;

    pub const cancelRendererRepaintRequest = surface_presentation.cancelRendererRepaintRequest;

    pub const consumeRendererRepaintRetryPending = surface_presentation.consumeRendererRepaintRetryPending;

    pub const shouldDrawRendererPaintContent = surface_presentation.shouldDrawRendererPaintContent;

    pub const finishRendererRepaintRequest = surface_presentation.finishRendererRepaintRequest;

    pub const requestRendererFrameNow = surface_presentation.requestRendererFrameNow;

    pub const handleRendererHealth = surface_presentation.handleRendererHealth;

    pub const markLiveResizeRepaintDeferred = surface_presentation.markLiveResizeRepaintDeferred;

    pub const queuePaintRequest = surface_presentation.queuePaintRequest;

    pub const forcePaintRequestNow = surface_presentation.forcePaintRequestNow;

    pub const noteFirstFrame = surface_presentation.noteFirstFrame;

    pub const requestFirstFrame = surface_presentation.requestFirstFrame;

    pub const flushDeferredLiveResizeRepaint = surface_presentation.flushDeferredLiveResizeRepaint;

    pub const repaintHostedChild = surface_presentation.repaintHostedChild;

    pub const requestRepaintWithMode = surface_presentation.requestRepaintWithMode;

    pub const requestRepaint = surface_presentation.requestRepaint;

    pub fn redraw(self: *Surface) !void {
        if (!self.core_initialized) return;
        const hwnd = self.hwnd orelse return;
        if (sys.IsWindowVisible(hwnd) == 0) return;
        if (self.size.width == 0 or self.size.height == 0) return;
        if (!build_config.d3d11 and (self.hdc == null or self.hglrc == null)) return;
        if (self.draw_in_progress) return;
        self.draw_in_progress = true;
        defer self.draw_in_progress = false;
        if (self.hglrc != null) try self.makeGLContextCurrent();
        try self.core_surface.draw();
    }

    pub fn noteRendererDrawRequest(self: *Surface) void {
        self.render_trace.noteRendererDrawRequest();
    }

    /// `Surface.queueRender` looks for this declaration. Without it the
    /// `@hasDecl` guard was comptime-false and
    /// `renderer_core_wakeup_notify_count` could only ever report zero.
    /// Compared against `core_surface_wakeup_count` it also shows how many
    /// core notifies the wake primitive coalesced away.
    pub fn noteRendererCoreWakeupNotify(self: *Surface) void {
        self.render_trace.noteRendererCoreWakeupNotify();
    }

    pub fn noteRendererWakeupCallback(self: *Surface, wake_sources: u32) void {
        self.render_trace.noteRendererWakeupCallback(wake_sources);
    }

    pub fn noteRendererFollowupCallback(self: *Surface) void {
        self.render_trace.noteRendererFollowupCallback();
    }

    pub fn noteRendererUpdateFrame(
        self: *Surface,
        progress: ?rendererpkg.State.OutputProgress,
        cursor_blinking: bool,
    ) void {
        self.render_trace.noteRendererUpdateFrame(
            if (progress) |value| .{
                .generation = value.generation,
                .bytes = value.bytes,
                .tick_ms = value.tick_ms,
                .benchmark_end_marker_generation = value.benchmark_end_marker_generation,
                .benchmark_end_marker_output_bytes = value.benchmark_end_marker_output_bytes,
            } else null,
            cursor_blinking,
        );
    }

    /// UI-thread-only notice using the same banner as other host diagnostics.
    pub fn showRendererNotice(self: *Surface, message: []const u8) !void {
        const host = self.host orelse return error.NoHost;
        try host.setBanner(.info, message);
    }

    /// Lazily prepare WGL for an opted-in surface that needs OpenGL fallback.
    /// Called on the UI thread, before publishing the replacement renderer.
    pub fn ensureGLContext(self: *Surface) !void {
        if (self.hglrc != null) return;
        const hwnd = self.hwnd orelse return error.NoWindow;
        const gl_context = try self.app.createGLContext(hwnd, &self.gl_pixel_format);
        self.hdc = gl_context.hdc;
        self.hglrc = gl_context.hglrc;
        self.setBenchmarkWglPixelFormat(gl_context.provenance);
        self.noteBenchmarkMemoryStage(.gl_context_created, null);
    }

    pub fn makeGLContextCurrent(self: *Surface) !void {
        const hdc = self.hdc orelse {
            recordOpenGLStartupError(.make_current, error.NoDeviceContext);
            return error.NoDeviceContext;
        };
        const hglrc = self.hglrc orelse {
            recordOpenGLStartupError(.make_current, error.NoOpenGLContext);
            return error.NoOpenGLContext;
        };

        if (sys.wglGetCurrentContext() == hglrc and sys.wglGetCurrentDC() == hdc) {
            return;
        }

        if (sys.wglMakeCurrent(hdc, hglrc) == 0) {
            const err = windows.kernel32.GetLastError();
            recordOpenGLStartupWin32Failure(.make_current, err);
            return windows.unexpectedError(err);
        }
    }

    pub fn clearGLContextCurrent(self: *Surface) void {
        _ = self.clearGLContextCurrentChecked();
    }

    /// Unbind this surface's GL context from the calling thread and report
    /// whether the unbind boundary actually holds afterwards.
    ///
    /// Returns true only when the surface's context is provably not current
    /// on this thread: either nothing of ours was current here, or
    /// `wglMakeCurrent(null, null)` reported success. The benchmark memory
    /// trace records `wgl_context_unbound` from this result, so a discarded
    /// failure must never be reported as a completed unbind.
    ///
    /// The native actions taken are identical to the unchecked wrapper; only
    /// the outcome is reported.
    pub fn clearGLContextCurrentChecked(self: *Surface) bool {
        // Without a context of our own, nothing of ours can be current.
        const hglrc = self.hglrc orelse return true;
        if (sys.wglGetCurrentContext() != hglrc) return true;

        // Our context is current here, so it must be unbound. Preserve the
        // pairing requirement: only clear when the bound DC is also ours,
        // and report failure when we cannot establish that.
        const hdc = self.hdc orelse return false;
        if (sys.wglGetCurrentDC() != hdc) return false;

        if (sys.wglMakeCurrent(null, null) == 0) {
            log.warn(
                "win32 wglMakeCurrent(null, null) failed during GL teardown err={}",
                .{windows.kernel32.GetLastError()},
            );
            return false;
        }
        return true;
    }

    pub fn swapGLBuffers(self: *Surface) !void {
        const hdc = self.hdc orelse return error.NoDeviceContext;
        _ = self.hglrc orelse return error.NoOpenGLContext;

        if (sys.SwapBuffers(hdc) == 0) {
            const err = windows.kernel32.GetLastError();
            return windows.unexpectedError(err);
        }
        self.noteSuccessfulPresent();
    }

    /// Shared successful-content handshake for WGL and DXGI (S_OK only).
    pub fn noteSuccessfulPresent(self: *Surface) void {
        self.render_trace.noteSwapBuffers();
        // Real content reached the screen, so the post-show handshake is
        // finished for good and can never wake the renderer again.
        self.noteFirstFrame(.content_presented);
        // Only the first swap that actually returned non-zero; the claim is
        // idempotent so later swaps cost one atomic load.
        if (self.memory_stage_trace.claimFirstSwapObservation()) {
            self.noteBenchmarkMemoryStage(.first_successful_swap, null);
        }
    }

    /// Only an adopted console controls the host through ConPTY XTWINOPS.
    /// Match Windows Terminal: hide minimizes, show restores only an iconic
    /// window (preserving an already maximized or snapped window).
    pub fn requestWindowVisibility(self: *Surface, visible: bool) void {
        if (!self.adopted_console) return;
        const host = self.host orelse return;
        const hwnd = host.hwnd orelse return;
        // Check iconic state at delivery, not here: a PTY batch may queue
        // hide then show before either message has reached the native pump.
        _ = sys.PostMessageW(hwnd, c.WM_WINHOSTTY_CONSOLE_VISIBILITY, @intFromBool(visible), 0);
    }

    /// The core asks this as it creates the pty: the host owns the pseudo
    /// console's window, as in Windows Terminal, so a dialog a console program
    /// parents to `GetConsoleWindow()` belongs to this window instead of an
    /// unowned hidden one. A surface never moves to another host, so once is
    /// enough; visibility changes after that follow `syncConsoleVisibility`.
    /// The core asks this as it starts the pty: a user profile's command line,
    /// which Exec passes to CreateProcess as written while the argv it runs is
    /// still that line's split.
    pub fn launchCommandLine(self: *const Surface) ?[]const u8 {
        const launch = self.launch_user orelse return null;
        return launch.command_line;
    }

    pub fn consoleOwner(self: *Surface) ?*anyopaque {
        const hwnd = (self.host orelse return null).hwnd orelse return null;
        self.console_window_attached = true;
        return hwnd;
    }

    /// Every pseudo console's window, adopted or spawned, follows the host:
    /// a console program asks it whether the terminal is shown.
    pub fn syncConsoleVisibility(self: *Surface, visible: bool) void {
        if (!self.core_initialized or !self.console_window_attached) return;
        if (self.console_window_visible == visible) return;
        self.console_window_visible = visible;
        self.core_surface.ptyVisibilityCallback(visible);
    }

    test "adopted ConPTY visibility follows the host across background tabs" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try Host.runOnPrivateDesktop(adoptedVisibilityTestBody);
    }

    fn adoptedVisibilityTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var first: Surface = undefined;
        var background: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{ .{ .storage = &first, .host = &host }, .{ .storage = &background, .host = &host } },
            .tabs = &.{ .{ .host = &host, .surface = &first, .id = 1 }, .{ .host = &host, .surface = &background, .id = 2 } },
        });
        defer session.deinit();
        const hwnd = try createTestHostWindow();
        defer _ = sys.DestroyWindow(hwnd);
        host.hwnd = hwnd;
        const termio = @import("../../termio.zig");
        first.core_surface.io.mailbox = try termio.Mailbox.initSPSC(core_app.alloc);
        defer first.core_surface.io.mailbox.deinit(core_app.alloc);
        background.core_surface.io.mailbox = try termio.Mailbox.initSPSC(core_app.alloc);
        defer background.core_surface.io.mailbox.deinit(core_app.alloc);
        for ([_]*Surface{ &first, &background }) |surface| {
            surface.adopted_console = true;
            surface.console_window_attached = true;
            surface.core_initialized = true;
            surface.window_visible = false;
            surface.core_surface.readonly = false;
            surface.core_surface.rt_surface = surface;
        }
        defer {
            first.core_initialized = false;
            background.core_initialized = false;
        }
        const Check = struct {
            fn sync(owner: *Host, surfaces: []const *Surface, expected: bool) !void {
                // Keep rendering inert: only exercise the host-to-PTY path.
                owner.surfaces_visible = win32_power.queryHostVisibility(owner.hwnd.?, false, null).visible;
                owner.refreshSurfaceVisibility();
                for (surfaces) |surface| {
                    const queue = surface.core_surface.io.mailbox.spsc.queue;
                    const message = queue.pop() orelse return error.MissingVisibilitySignal;
                    try std.testing.expectEqual(expected, message.pty_visibility);
                    try std.testing.expect(queue.pop() == null);
                }
                owner.refreshSurfaceVisibility();
                for (surfaces) |surface| try std.testing.expect(surface.core_surface.io.mailbox.spsc.queue.pop() == null);
            }
            fn request(surface: *Surface, visible: bool) !void {
                try surface.core_surface.handleMessage(.{ .window_visibility = visible });
                var message: MSG = undefined;
                if (sys.PeekMessageW(&message, surface.host.?.hwnd, c.WM_WINHOSTTY_CONSOLE_VISIBILITY, c.WM_WINHOSTTY_CONSOLE_VISIBILITY, c.PM_REMOVE) == 0) return error.MissingVisibilityRequest;
                applyConsoleWindowVisibility(message.hwnd, message.wParam != 0);
            }
            fn drain(owner_hwnd: HWND) void {
                var message: MSG = undefined;
                while (sys.PeekMessageW(&message, owner_hwnd, c.WM_WINHOSTTY_CONSOLE_VISIBILITY, c.WM_WINHOSTTY_CONSOLE_VISIBILITY, c.PM_REMOVE) != 0) {
                    applyConsoleWindowVisibility(owner_hwnd, message.wParam != 0);
                }
            }
        };
        const surfaces = [_]*Surface{ &first, &background };
        try Check.sync(&host, &surfaces, false);
        _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
        try Check.sync(&host, &surfaces, true);
        // Even a background tab's adopted client controls the owning host.
        try Check.request(&background, false);
        try std.testing.expect(sys.IsIconic(hwnd) != 0);
        try Check.sync(&host, &surfaces, false);
        try Check.request(&background, true);
        try std.testing.expect(sys.IsIconic(hwnd) == 0);
        try Check.sync(&host, &surfaces, true);
        // One PTY batch can carry opposing requests before the UI dispatches
        // either native command. The last request must still win.
        try background.core_surface.handleMessage(.{ .window_visibility = false });
        try background.core_surface.handleMessage(.{ .window_visibility = true });
        Check.drain(hwnd);
        try std.testing.expect(sys.IsIconic(hwnd) == 0);
        _ = sys.ShowWindow(hwnd, c.SW_MINIMIZE);
        try background.core_surface.handleMessage(.{ .window_visibility = true });
        try background.core_surface.handleMessage(.{ .window_visibility = false });
        Check.drain(hwnd);
        try std.testing.expect(sys.IsIconic(hwnd) != 0);
        _ = sys.ShowWindow(hwnd, c.SW_MAXIMIZE);
        try Check.request(&background, true);
        try std.testing.expect(sys.IsZoomed(hwnd) != 0);
        // An ordinary surface cannot control host visibility this way.
        first.adopted_console = false;
        try first.core_surface.handleMessage(.{ .window_visibility = false });
        var message: MSG = undefined;
        try std.testing.expect(sys.PeekMessageW(&message, hwnd, c.WM_WINHOSTTY_CONSOLE_VISIBILITY, c.WM_WINHOSTTY_CONSOLE_VISIBILITY, c.PM_REMOVE) == 0);
    }

    test "a spawned pseudo console is owned by its host and follows its visibility" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try Host.runOnPrivateDesktop(spawnedConsoleWindowTestBody);
    }

    fn spawnedConsoleWindowTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var first: Surface = undefined;
        var later: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true }},
            .surfaces = &.{ .{ .storage = &first, .host = &host }, .{ .storage = &later, .host = &host } },
            .tabs = &.{ .{ .host = &host, .surface = &first, .id = 1 }, .{ .host = &host, .surface = &later, .id = 2 } },
        });
        defer session.deinit();
        const hwnd = try createTestHostWindow();
        defer _ = sys.DestroyWindow(hwnd);
        host.hwnd = hwnd;
        const termio = @import("../../termio.zig");
        const surfaces = [_]*Surface{ &first, &later };
        for (surfaces) |surface| {
            surface.core_surface.io.mailbox = try termio.Mailbox.initSPSC(core_app.alloc);
            surface.window_visible = false;
            surface.core_surface.rt_surface = surface;
        }
        defer for (surfaces) |surface| surface.core_surface.io.mailbox.deinit(core_app.alloc);
        defer {
            first.core_initialized = false;
            later.core_initialized = false;
        }
        const Queue = struct {
            fn expectNext(surface: *Surface) !termio.Message {
                return surface.core_surface.io.mailbox.spsc.queue.pop() orelse error.MissingPtyMessage;
            }
            fn expectEmpty(surface: *Surface) !void {
                try std.testing.expect(surface.core_surface.io.mailbox.spsc.queue.pop() == null);
            }
        };

        // The pty of a surface is created owned by its host, and hears the
        // host's visibility from then on.
        first.core_initialized = true;
        host.refreshSurfaceVisibility();
        try Queue.expectEmpty(&first);
        try std.testing.expectEqual(@as(?*anyopaque, hwnd), first.consoleOwner());
        _ = sys.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
        host.surfaces_visible = win32_power.queryHostVisibility(hwnd, false, null).visible;
        host.refreshSurfaceVisibility();
        try std.testing.expect((try Queue.expectNext(&first)).pty_visibility);
        try Queue.expectEmpty(&first);

        // So does a tab added to a host already on screen.
        try std.testing.expectEqual(@as(?*anyopaque, hwnd), later.consoleOwner());
        later.core_initialized = true;
        host.refreshSurfaceVisibility();
        try std.testing.expect((try Queue.expectNext(&later)).pty_visibility);
        try Queue.expectEmpty(&later);
        try Queue.expectEmpty(&first);

        // Every tab's pseudo console hears of a minimize, not only an
        // adopted one's.
        _ = sys.ShowWindow(hwnd, c.SW_SHOWMINNOACTIVE);
        host.refreshSurfaceVisibility();
        for (surfaces) |surface| {
            try std.testing.expect(!(try Queue.expectNext(surface)).pty_visibility);
            try Queue.expectEmpty(surface);
        }
    }

    pub fn setTitle(self: *Surface, title: []const u8) !void {
        const alloc = self.app.core_app.alloc;
        // Both the OSC 0/2 path and the automation IPC path
        // (`set_surface_title`) land here, and a stored title can be echoed
        // back to the pty by `title-report`. See `sanitizeTitleAlloc`.
        const sanitized = try sanitizeTitleAlloc(alloc, title);
        defer if (sanitized) |v| alloc.free(v);
        const value = sanitized orelse title;

        var changed = false;

        // Direct commands initially report argv[0] as their title. Keep an
        // SSH alias over that automatic value, then release it as soon as the
        // remote terminal supplies a different title.
        if (sshAliasFromLaunchKey(self.launched_ssh, self.launch_profile_key)) |alias| {
            if (self.tab_title_override) |override| {
                if (std.mem.eql(u8, override, alias) and !isAutomaticSshCommandTitle(value)) {
                    try appendOwnedString(alloc, &self.tab_title_override, null);
                    changed = true;
                }
            }
        }

        if (!ownedStringEquals(self.title, value)) {
            try appendOwnedString(alloc, &self.title, value);
            changed = true;
        }
        if (!changed) return;
        try self.refreshWindowTitle();
        self.notifyTerminalUiaNameChanged();
    }

    fn notifyTerminalUiaNameChanged(self: *Surface) void {
        if (self.terminal_accessibility) |session| session.nameChanged();
    }

    pub fn setTitleOverride(self: *Surface, title: ?[]const u8) !void {
        const alloc = self.app.core_app.alloc;
        const sanitized = if (title) |v| try sanitizeTitleAlloc(alloc, v) else null;
        defer if (sanitized) |v| alloc.free(v);
        const value: ?[]const u8 = if (sanitized) |v| v else title;

        if (optionalOwnedStringEquals(self.title_override, value)) return;
        try appendOwnedString(alloc, &self.title_override, value);
        try self.refreshWindowTitle();
        self.notifyTerminalUiaNameChanged();
    }

    pub fn setTabTitleOverride(self: *Surface, title: ?[]const u8) !void {
        const alloc = self.app.core_app.alloc;
        // `set_tab_title` is reachable over the automation IPC pipe and
        // `effectiveTitle` can surface this value to `title-report`, so it
        // gets the same sanitizing as `setTitle`.
        const sanitized = if (title) |v| try sanitizeTitleAlloc(alloc, v) else null;
        defer if (sanitized) |v| alloc.free(v);
        const value: ?[]const u8 = if (sanitized) |v| v else title;

        if (optionalOwnedStringEquals(self.tab_title_override, value)) return;
        try appendOwnedString(alloc, &self.tab_title_override, value);
        try self.refreshWindowTitle();
        self.notifyTerminalUiaNameChanged();
    }

    pub fn effectiveTitle(self: *const Surface) ?[:0]const u8 {
        return resolveWindowBaseTitle(self.title, self.title_override, self.tab_title_override);
    }

    /// Mark or unmark the terminal as alerted by the bell. Only the DISPLAY
    /// of the title changes (`syncWindowTitle`, `syncTabButtons`): the stored
    /// title, `effectiveTitle` and everything that reads it (`title-report`,
    /// sessions, automation, notifications) stay as the program set them.
    pub fn setBellRinging(self: *Surface, ringing: bool) void {
        if (self.bell_ringing == ringing) return;
        self.bell_ringing = ringing;
        self.refreshWindowTitle() catch |err| {
            log.warn("win32 bell title refresh failed err={}", .{err});
        };
        // The tab's UIA ItemStatus says "Bell" while it rings.
        if (Host.findTabForSurface(self)) |found| found.host.refreshTabStatus(found.index);
    }

    /// The user focused this terminal or typed into it: the bell has been
    /// answered.
    fn clearBell(self: *Surface) void {
        self.setBellRinging(false);
    }

    /// A reload that turns the title bell off takes the glyph already up
    /// away, instead of leaving it until this terminal is next focused.
    pub fn applyBellFeatures(self: *Surface, features: configpkg.Config.BellFeatures) void {
        if (!features.title) self.clearBell();
    }

    /// A screen reader is told "Bell" when it has this terminal's provider.
    pub fn announceBell(self: *Surface) void {
        if (self.terminal_accessibility) |session| session.announceBell();
    }

    pub fn promptTitle(self: *Surface, kind: apprt.action.PromptTitle) !void {
        const host = self.host orelse return;
        const mode: HostOverlayMode = switch (kind) {
            .surface => .surface_title,
            .tab => .tab_title,
        };
        if (host.overlay_mode == mode) {
            host.hideOverlay();
            try host.layout();
            return;
        }
        const initial = host.overlayInitialText(mode);
        defer if (initial) |value| self.app.core_app.alloc.free(value);
        host.hideOverlay();
        try host.showOverlay(mode, initial);
    }

    pub fn toggleCommandPalette(self: *Surface) !bool {
        const host = self.host orelse return false;
        if (host.overlay_mode == .command_palette) {
            host.hideOverlay();
            try host.layout();
            return true;
        }
        host.hideOverlay();
        try host.showOverlay(.command_palette, null);
        return true;
    }

    pub fn toggleTabOverview(self: *Surface) !bool {
        const host = self.host orelse return false;
        if (host.overlay_mode == .tab_overview) {
            host.hideOverlay();
            try host.layout();
            return true;
        }
        const initial = host.overlayInitialText(.tab_overview);
        defer if (initial) |value| self.app.core_app.alloc.free(value);
        try host.showOverlay(.tab_overview, initial);
        return true;
    }

    fn scrollbarPolicy(self: *const Surface) ScrollbarPolicy {
        return switch (self.scrollbar_config) {
            .never => .never,
            .system => if (isHighContrastActive() or !self.app.system_dynamic_scrollbars)
                .always
            else
                .dynamic,
        };
    }

    fn scrollbarScrollable(self: *const Surface) bool {
        return self.scrollbar.total > self.scrollbar.len and self.scrollbar.len > 0;
    }

    fn scrollbarAnimationsEnabled() bool {
        return Host.clientAnimationsEnabled() and !isHighContrastActive();
    }

    fn scrollbarHoverWidthPx(self: *const Surface) i32 {
        if (self.host) |host| return @max(1, host.scaled(10));
        return @max(1, @as(i32, @intFromFloat(@ceil(
            win32_scrollbar_geometry.track_width_hover_dp * self.content_scale.x,
        ))));
    }

    fn scrollbarMarkerBudgetForHeight(height: i32) usize {
        if (height <= 0) return 0;
        return @min(128, @max(8, @as(usize, @intCast(@max(1, @divTrunc(height, 4))))));
    }

    fn scrollbarChildRect(self: *const Surface, pane_rect: RECT) RECT {
        const width = self.scrollbarHoverWidthPx();
        return childRect(
            pane_rect.right - width,
            pane_rect.top,
            width,
            @max(1, pane_rect.bottom - pane_rect.top),
        );
    }

    fn scrollbarLocalLayout(self: *const Surface) ?win32_scrollbar_geometry.Layout {
        if (!self.scrollbar_placement.rect_known) return null;
        const rect = self.scrollbar_placement.rect;
        const width = @max(1, rect.right - rect.left);
        const height = @max(1, rect.bottom - rect.top);
        const max_top = if (self.scrollbar.total > self.scrollbar.len)
            self.scrollbar.total - self.scrollbar.len
        else
            0;
        return .{
            .pane = .{
                .left = 0,
                .top = 0,
                .right = @floatFromInt(width),
                .bottom = @floatFromInt(height),
            },
            .total_rows = self.scrollbar.total,
            .viewport_rows = self.scrollbar.len,
            .top_row = @min(self.scrollbar.offset, max_top),
            .dpi_scale = if (self.host) |host|
                @as(f32, @floatFromInt(host.current_dpi)) / 96.0
            else
                self.content_scale.x,
            .hovered = self.scrollbar_state.hovered,
            .dragging = self.scrollbar_state.dragging,
        };
    }

    fn scrollbarRectToRect(value: win32_scrollbar_geometry.Rect) RECT {
        const left: i32 = @intFromFloat(@floor(value.left));
        const top: i32 = @intFromFloat(@floor(value.top));
        const right: i32 = @max(left + 1, @as(i32, @intFromFloat(@ceil(value.right))));
        const bottom: i32 = @max(top + 1, @as(i32, @intFromFloat(@ceil(value.bottom))));
        return .{
            .left = left,
            .top = top,
            .right = right,
            .bottom = bottom,
        };
    }

    fn scrollbarPaintKey(self: *const Surface, rect: RECT) ScrollbarPaintKey {
        return .{
            .rect = rect,
            .total = self.scrollbar.total,
            .len = self.scrollbar.len,
            .offset = self.scrollbar.offset,
            .dpi = if (self.host) |host| host.current_dpi else 96,
            .hovered = self.scrollbar_state.hovered,
            .dragging = self.scrollbar_state.dragging,
            .marker_revision = self.scrollbar_marker_revision,
        };
    }

    fn clearScrollbarMarkers(self: *Surface) void {
        if (self.scrollbar_markers.len > 0) {
            self.app.core_app.alloc.free(self.scrollbar_markers);
            self.scrollbar_markers = &.{};
            self.scrollbar_marker_revision +%= 1;
        }
        self.scrollbar_marker_budget = 0;
    }

    fn rebuildScrollbarMarkers(self: *Surface, marker_budget: usize) !void {
        self.clearScrollbarMarkers();
        if (marker_budget == 0 or self.docked_search.match_rows.len == 0 or self.scrollbar.total == 0) return;

        const alloc = self.app.core_app.alloc;
        const rows = try alloc.alloc(usize, self.docked_search.match_rows.len);
        defer alloc.free(rows);
        for (self.docked_search.match_rows, 0..) |row, i| rows[i] = @intCast(row);

        self.scrollbar_markers = try win32_scrollbar_geometry.downsampleMarkers(
            alloc,
            rows,
            self.scrollbar.total,
            marker_budget,
        );
        self.scrollbar_marker_budget = marker_budget;
        self.scrollbar_marker_revision +%= 1;
    }

    pub fn ensureQuickSelectUiaProvider(self: *Surface) !void {
        if (!self.app.com_initialized or self.quick_select_uia_provider != null) return;
        self.quick_select_uia_provider = try win32_uia.PaletteListProvider.create(
            std.heap.page_allocator,
            self.quick_select_hwnd orelse return error.NoQuickSelectWindow,
            self.quickSelectUiaState(),
        );
    }

    fn quickSelectUiaState(self: *const Surface) win32_uia.PaletteListState {
        return .{
            .ctx = @ptrCast(@constCast(self)),
            .name = &quickSelectNameThunk,
            .localized_control_type = "quick select targets",
            .keyboard_focusable = true,
            .focused = &quickSelectFocusedThunk,
            .row_count = &quickSelectRowCountThunk,
            .selected_index = &quickSelectSelectedIndexThunk,
            .row_name = &quickSelectRowNameThunk,
            .row_enabled = &quickSelectRowEnabledThunk,
            .row_id = &quickSelectRowIdThunk,
            .select_row = &quickSelectSelectRowThunk,
            .invoke_row = &quickSelectInvokeRowThunk,
            .row_bounds = &quickSelectRowBoundsThunk,
            .use_com_threading = self.app.com_initialized,
        };
    }

    pub fn quickSelectLabelRect(
        self: *Surface,
        index: usize,
        client: RECT,
        metrics: win32_theme.ThemeMetrics,
        dpi: UINT,
    ) ?RECT {
        _ = self.ensureQuickSelectLabelRects(client, metrics, dpi);
        const session = if (self.quick_select_session) |*value| value else return null;
        if (index >= session.placed_slots.len) return null;
        const slot = session.placed_slots[index] orelse return null;
        return session.placed_rects[slot];
    }

    const quick_select_placement_comparison_budget = 262_144;

    fn quickSelectPositionLabel(
        raw: RECT,
        client: RECT,
        occupied: []const RECT,
        comparisons_remaining: *usize,
    ) ?RECT {
        const height = raw.bottom - raw.top;
        const width = raw.right - raw.left;
        if (height <= 0 or width <= 0) return null;
        const lane_count: usize = @intCast(@max(1, @divTrunc(client.bottom - client.top, height)));
        for (0..lane_count * 2 + 1) |attempt| {
            const magnitude: i32 = @intCast((attempt + 1) / 2);
            const lane: i32 = if (attempt == 0)
                0
            else if (attempt % 2 == 1)
                magnitude
            else
                -magnitude;
            var candidate = raw;
            candidate.top += lane * height;
            candidate.bottom += lane * height;
            if (candidate.top < client.top or candidate.bottom > client.bottom) continue;
            for (occupied) |previous| {
                if (comparisons_remaining.* == 0) return null;
                comparisons_remaining.* -= 1;
                if (candidate.left < previous.right and candidate.right > previous.left and
                    candidate.top < previous.bottom and candidate.bottom > previous.top)
                {
                    break;
                }
            } else return candidate;
        }

        // If every target-local lane is occupied, tile across the viewport.
        // Returning the known-overlapping raw rectangle would let a later
        // opaque chip hide an earlier label and make its key undiscoverable.
        var top = client.top;
        while (top + height <= client.bottom) : (top += height) {
            var left = client.left;
            while (left + width <= client.right) : (left += width) {
                const candidate: RECT = .{
                    .left = left,
                    .top = top,
                    .right = left + width,
                    .bottom = top + height,
                };
                for (occupied) |previous| {
                    if (comparisons_remaining.* == 0) return null;
                    comparisons_remaining.* -= 1;
                    if (candidate.left < previous.right and candidate.right > previous.left and
                        candidate.top < previous.bottom and candidate.bottom > previous.top)
                    {
                        break;
                    }
                } else return candidate;
            }
        }
        return null;
    }

    fn ensureQuickSelectLabelRects(
        self: *Surface,
        client: RECT,
        metrics: win32_theme.ThemeMetrics,
        dpi: UINT,
    ) bool {
        const session = if (self.quick_select_session) |*value| value else return false;
        if (session.placement_client) |previous_client| {
            if (session.placement_metrics) |previous_metrics| {
                if (std.meta.eql(previous_client, client) and
                    std.meta.eql(previous_metrics, metrics) and
                    session.placement_dpi == dpi)
                {
                    return session.placement_complete;
                }
            }
        }

        @memset(session.placed_slots, null);
        session.placed_count = 0;
        session.placement_complete = true;
        session.placement_client = client;
        session.placement_metrics = metrics;
        session.placement_dpi = dpi;
        var comparisons_remaining: usize = quick_select_placement_comparison_budget;
        for (session.scan.matches, 0..) |_, index| {
            if (!session.labels.startsWith(index, session.prefix.typed())) continue;
            const raw = self.quickSelectRawLabelRect(index, client, metrics, dpi) orelse {
                session.placement_complete = false;
                continue;
            };
            const positioned = quickSelectPositionLabel(
                raw,
                client,
                session.placed_rects[0..session.placed_count],
                &comparisons_remaining,
            ) orelse {
                session.placement_complete = false;
                if (comparisons_remaining == 0) break;
                continue;
            };
            session.placed_rects[session.placed_count] = positioned;
            session.placed_slots[index] = session.placed_count;
            session.placed_count += 1;
        }
        return session.placement_complete;
    }

    fn quickSelectRawLabelRect(
        self: *const Surface,
        index: usize,
        client: RECT,
        metrics: win32_theme.ThemeMetrics,
        dpi: UINT,
    ) ?RECT {
        const session = if (self.quick_select_session) |*value| value else return null;
        if (index >= session.scan.matches.len or index >= session.labels.count) return null;
        if (!session.labels.startsWith(index, session.prefix.typed())) return null;
        const matched = session.scan.matches[index];
        const placed = win32_hints.labelPlacement(.{
            .left = matched.first.x,
            .top = matched.first.y,
            .right = @as(u32, matched.first.x) + 1,
            .bottom = matched.first.y + 1,
        }, session.labels.get(index).len, .{
            .cell_width = session.cell_width,
            .cell_height = session.cell_height,
            .padding_left = session.padding_left,
            .padding_top = session.padding_top,
            .viewport_width = client.right,
            .viewport_height = client.bottom,
            .dpi = dpi,
            .logical_padding_x = metrics.space_1,
            .logical_stroke = metrics.stroke_hairline,
        }) orelse return null;
        return .{
            .left = placed.left,
            .top = placed.top,
            .right = placed.right,
            .bottom = placed.bottom,
        };
    }

    pub fn quickSelectFirstRemainingIndex(self: *const Surface) ?usize {
        const session = if (self.quick_select_session) |*value| value else return null;
        for (0..session.labels.count) |index| {
            if (session.labels.startsWith(index, session.prefix.typed())) return index;
        }
        return null;
    }

    pub fn buildQuickSelectName(self: *const Surface, buf: []u8) []const u8 {
        const session = if (self.quick_select_session) |*value| value else return std.fmt.bufPrint(buf, "Quick select, 0 targets", .{}) catch "Quick select";
        const count = session.labels.count;
        // Screen readers speak this verbatim, so "1 targets" is a real defect.
        const noun = if (count == 1) "target" else "targets";
        const typed = session.prefix.typed();
        if (typed.len == 0) {
            return std.fmt.bufPrint(
                buf,
                "Quick select, {d} {s}",
                .{ count, noun },
            ) catch "Quick select";
        }
        var spoken_typed_buf: [win32_hints.PrefixState.max_len * 6]u8 = undefined;
        const spoken_typed = win32_hints.accessibleLabelName(&spoken_typed_buf, typed);
        return std.fmt.bufPrint(
            buf,
            "Quick select, {d} {s}, typed {s}",
            .{ count, noun, spoken_typed },
        ) catch "Quick select";
    }

    pub fn toggleQuickSelect(self: *Surface) !bool {
        if (self.quick_select_session != null) {
            self.closeQuickSelect(true);
            return true;
        }
        const surface_hwnd = self.hwnd orelse return false;
        if (!quickSelectCanActivate(
            self.window_visible,
            sys.IsWindowVisible(surface_hwnd) != 0,
        )) return false;
        if (!self.core_initialized) return false;

        const alloc = self.app.core_app.alloc;
        var render_state: terminal.RenderState = .empty;
        defer render_state.deinit(alloc);
        self.core_surface.renderer_state.mutex.lock();
        render_state.update(
            alloc,
            self.core_surface.renderer_state.terminal,
        ) catch |err| {
            self.core_surface.renderer_state.mutex.unlock();
            return err;
        };
        const renderer_size = self.core_surface.size;
        self.core_surface.renderer_state.mutex.unlock();

        const configured = self.app.config.@"quick-select-patterns".list.items;
        const patterns: []const []const u8 = if (configured.len == 0)
            &win32_hints.default_patterns
        else
            configured;
        var scan = try win32_hints.scanRenderState(alloc, &render_state, patterns);
        errdefer scan.deinit(alloc);
        if (scan.matches.len == 0) {
            scan.deinit(alloc);
            self.showQuickSelectNotice(labels.quick_select_no_targets_banner);
            return true;
        }

        var label_set = try win32_hints.generateLabels(
            alloc,
            self.app.config.@"quick-select-alphabet".value,
            scan.matches.len,
        );
        errdefer label_set.deinit(alloc);
        const placed_rects = try alloc.alloc(RECT, label_set.count);
        errdefer alloc.free(placed_rects);
        const placed_slots = try alloc.alloc(?usize, label_set.count);
        errdefer alloc.free(placed_slots);

        try self.ensureQuickSelectWindow();
        self.quick_select_session = .{
            .scan = scan,
            .labels = label_set,
            .cell_width = @intCast(renderer_size.cell.width),
            .cell_height = @intCast(renderer_size.cell.height),
            .padding_left = @intCast(renderer_size.padding.left),
            .padding_top = @intCast(renderer_size.padding.top),
            .placed_rects = placed_rects,
            .placed_slots = placed_slots,
            .suppress_until_opening_keys_released = anyVirtualKeyPressed(),
            .suppress_opening_left_button_up = win32_input.keyPressed(c.VK_LBUTTON),
        };

        self.refreshQuickSelectPlacement();
        const hwnd = self.quick_select_hwnd.?;
        var client: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client) == 0) {
            log.warn("quick select client rect unavailable", .{});
            self.closeQuickSelect(false);
            return true;
        }
        const host = self.host orelse {
            log.warn("quick select host unavailable", .{});
            self.closeQuickSelect(false);
            return true;
        };
        const metrics: win32_theme.ThemeMetrics = if (isHighContrastActive())
            .highContrast()
        else
            .{};
        if (!self.ensureQuickSelectLabelRects(client, metrics, host.current_dpi)) {
            log.warn("quick select has more visible labels than fit without overlap", .{});
            self.closeQuickSelect(false);
            self.showQuickSelectNotice(labels.quick_select_too_many_banner);
            return true;
        }

        self.ensureQuickSelectUiaProvider() catch |err| {
            log.warn("quick select UIA provider unavailable err={}", .{err});
        };

        _ = applyChildVisibility(hwnd, &self.quick_select_placement, true);
        _ = sys.SetFocus(hwnd);
        // Color-keyed pixels are transparent to hit testing. Capture ensures
        // every click over the modal overlay reaches its dismissal handler
        // instead of leaking through to the terminal below.
        _ = sys.SetCapture(hwnd);
        _ = sys.InvalidateRect(hwnd, null, 0);
        return true;
    }

    /// Say why the key press did nothing. Call with no session open: the
    /// banner does not touch focus, and a closed overlay has nothing to free.
    pub fn showQuickSelectNotice(self: *Surface, message: []const u8) void {
        _ = self.app.showHostBanner(.{ .surface = self.core() }, .info, message) catch |err| {
            log.warn("quick select notice failed err={}", .{err});
            return;
        };
    }

    fn ensureQuickSelectWindow(self: *Surface) !void {
        if (self.quick_select_hwnd != null) return;
        try self.app.ensureQuickSelectClass();
        const parent = self.hwnd orelse return error.NoSurfaceWindow;
        var rect: RECT = undefined;
        if (sys.GetClientRect(parent, &rect) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }

        self.quick_select_hwnd = sys.CreateWindowExW(
            c.WS_EX_LAYERED,
            quick_select_class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD | c.WS_TABSTOP,
            0,
            0,
            @max(1, rect.right),
            @max(1, rect.bottom),
            parent,
            null,
            self.app.hinstance,
            null,
        ) orelse return windows.unexpectedError(windows.kernel32.GetLastError());
        const hwnd = self.quick_select_hwnd.?;
        _ = sys.SetWindowLongPtrW(
            hwnd,
            c.GWLP_USERDATA,
            @as(LONG_PTR, @intCast(@intFromPtr(self))),
        );
        if (sys.SetLayeredWindowAttributes(
            hwnd,
            scrollbar_transparent_key,
            255,
            c.LWA_ALPHA | c.LWA_COLORKEY,
        ) == 0) {
            _ = sys.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            _ = sys.DestroyWindow(hwnd);
            self.quick_select_hwnd = null;
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    fn refreshQuickSelectPlacement(self: *Surface) void {
        const overlay = self.quick_select_hwnd orelse return;
        const parent = self.hwnd orelse return;
        var rect: RECT = undefined;
        if (sys.GetClientRect(parent, &rect) == 0) return;
        _ = applyChildRect(overlay, &self.quick_select_placement, rect);
    }

    pub fn closeQuickSelect(self: *Surface, restore_focus: bool) void {
        // Callers include unconditional lifecycle hooks (resize, hide,
        // teardown), so closing when nothing is open must be a no-op —
        // otherwise `restore_focus` would steal focus on every resize.
        if (self.quick_select_hwnd == null and self.quick_select_session == null) return;

        const overlay = self.quick_select_hwnd;
        self.quick_select_hwnd = null;
        self.quick_select_placement = .{};

        if (self.quick_select_uia_provider) |provider| {
            self.quick_select_uia_provider = null;
            provider.raiseTeardown();
            provider.detach();
            scheduleDeferredUiaDisconnect(
                self.app,
                @ptrCast(provider),
                &paletteDisconnectThunk,
                &paletteReleaseThunk,
            );
        }
        if (overlay) |hwnd| {
            _ = sys.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            if (sys.GetCapture()) |capture| {
                if (capture == hwnd) _ = sys.ReleaseCapture();
            }
            _ = sys.DestroyWindow(hwnd);
        }
        if (self.quick_select_session) |*session| session.deinit(self.app.core_app.alloc);
        self.quick_select_session = null;

        if (restore_focus) {
            if (self.hwnd) |hwnd| _ = sys.SetFocus(hwnd);
        }
    }

    pub fn quickSelectPrefixChanged(self: *Surface) void {
        if (self.quick_select_session) |*session| session.placement_client = null;
        if (self.quick_select_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
        if (self.quick_select_uia_provider) |provider| {
            win32_uia.events.raiseNameChanged(&provider.base);
            win32_uia.events.raiseStructureChanged(
                &provider.base,
                .children_invalidated,
                null,
            );
            if (self.quickSelectFirstRemainingIndex()) |index| provider.raiseSelectionChanged(index);
        }
    }

    pub fn handleQuickSelectKey(self: *Surface, wParam: WPARAM, lParam: LPARAM) void {
        const session = if (self.quick_select_session) |*value| value else return;
        if (session.suppress_until_opening_keys_released) return;
        if (wParam == c.VK_ESCAPE) {
            session.pending_action = .{
                .trigger_vk = c.VK_ESCAPE,
                .index = null,
                .ctrl = false,
                .alt = false,
            };
            return;
        }
        if (session.pending_action != null) return;
        if (wParam == c.VK_BACK) {
            session.awaiting_composed_char = false;
            if (session.prefix.backspace()) self.quickSelectPrefixChanged();
            return;
        }

        const char = quickSelectAsciiFromKey(wParam, lParam) orelse {
            session.awaiting_composed_char = true;
            return;
        };
        session.awaiting_composed_char = false;
        self.inputQuickSelectChar(session, char, @intCast(wParam & 0xFFFF));
    }

    pub fn handleQuickSelectChar(self: *Surface, wParam: WPARAM) void {
        const session = if (self.quick_select_session) |*value| value else return;
        if (session.suppress_until_opening_keys_released) return;
        if (!session.awaiting_composed_char or session.pending_action != null) return;
        session.awaiting_composed_char = false;
        if (wParam < 0x20 or wParam >= 0x7F) return;
        self.inputQuickSelectChar(session, @intCast(wParam), 0);
    }

    fn inputQuickSelectChar(
        self: *Surface,
        session: *QuickSelectSession,
        char: u8,
        trigger_vk: UINT,
    ) void {
        const mods = win32_input.quickSelectActionMods();
        switch (session.prefix.input(&session.labels, char)) {
            .ignored => {},
            .narrowed => self.quickSelectPrefixChanged(),
            .complete => |index| session.pending_action = .{
                .trigger_vk = trigger_vk,
                .index = index,
                .ctrl = mods.ctrl,
                .alt = mods.alt,
            },
        }
    }

    pub fn handleQuickSelectKeyUp(self: *Surface) void {
        const session = if (self.quick_select_session) |*value| value else return;
        if (session.suppress_until_opening_keys_released) {
            session.suppress_until_opening_keys_released = anyVirtualKeyPressed();
            return;
        }
        const pending = session.pending_action orelse return;
        if ((pending.trigger_vk != 0 and win32_input.keyPressed(@intCast(pending.trigger_vk))) or
            win32_input.keyPressed(c.VK_SHIFT) or
            win32_input.keyPressed(c.VK_CONTROL) or
            win32_input.keyPressed(c.VK_MENU))
        {
            return;
        }
        session.pending_action = null;
        const index = pending.index orelse {
            self.closeQuickSelect(true);
            return;
        };
        self.fireQuickSelect(index, pending.ctrl, pending.alt) catch |err| {
            log.warn("quick select action failed err={}", .{err});
        };
    }

    /// Whether the cells a quick-select target occupies still hold the text
    /// that was scanned when the overlay opened. Fails closed: any error, or a
    /// span that no longer exists, counts as changed.
    fn quickSelectTargetUnchanged(
        self: *Surface,
        session: *const QuickSelectSession,
        index: usize,
    ) bool {
        if (!self.core_initialized) return false;
        const alloc = self.app.core_app.alloc;
        const matched = session.scan.matches[index];

        var render_state: terminal.RenderState = .empty;
        defer render_state.deinit(alloc);
        self.core_surface.renderer_state.mutex.lock();
        render_state.update(
            alloc,
            self.core_surface.renderer_state.terminal,
        ) catch {
            self.core_surface.renderer_state.mutex.unlock();
            return false;
        };
        self.core_surface.renderer_state.mutex.unlock();

        // Same builder as the open-time scan, wide-character spacers included,
        // or a target containing a wide character would never compare equal.
        var rendered = win32_hints.renderStateText(alloc, &render_state) catch return false;
        defer rendered.deinit(alloc);

        const current = win32_hints.spanTextRange(
            rendered.text,
            rendered.map,
            matched,
        ) orelse return false;
        return std.mem.eql(u8, current, session.scan.matchText(index));
    }

    pub fn fireQuickSelect(self: *Surface, index: usize, ctrl: bool, alt: bool) !void {
        const alloc = self.app.core_app.alloc;
        const session = if (self.quick_select_session) |*value| value else return;
        if (index >= session.scan.matches.len) return;
        const payload = try alloc.dupeZ(u8, session.scan.matchText(index));
        defer alloc.free(payload);

        // Re-verify against the LIVE viewport before acting.
        //
        // The overlay is colorkey-transparent, so the terminal keeps drawing
        // underneath a snapshot taken when quick select opened. A program that
        // rewrites the labeled region after the overlay is up would otherwise
        // let the user act on bytes that are no longer the bytes on screen.
        // Checking here, at the moment of use, is the only point where "what
        // the user sees" and "what we act on" can be compared.
        if (!self.quickSelectTargetUnchanged(session, index)) {
            log.warn("quick select target changed under the overlay; ignoring", .{});
            self.closeQuickSelect(true);
            return;
        }

        // Outside WSL, `/c/x` opens as `C:\x`, as a Ctrl+click on it does.
        const action = win32_hints.resolveAction(payload, ctrl, alt, self.core().launchesWsl());

        self.closeQuickSelect(true);
        if (action == .open) {
            // The same resolution a Ctrl+click gets: a relative path against
            // the pane's directory, and no line or column in the file name.
            try self.core().openLinkText(payload);
            return;
        }
        if (action == .paste) {
            self.noteProgramInput();
            // Defense-in-depth classifier pass, same as the drop path.
            //
            // Core's `isSafe` only flags newlines and bracketed-paste-end
            // sequences. A quick-select payload is attacker-rendered terminal
            // output, not something the user typed or copied, so a single-line
            // match like `https://x/$(payload)` or one carrying `%VAR%` would
            // otherwise reach the pty with no confirmation. Consult the full
            // verdict (control_chars, shell_metachar, mixed_content) and fire
            // the same confirm overlay as the core `.UnsafePaste` branch.
            if (self.app.config.@"clipboard-paste-protection") {
                const verdict = win32_paste_protection.inspect(payload);
                if (verdict.severity != .safe) {
                    log.info("quick select paste flagged severity={s} reason={s}", .{
                        @tagName(verdict.severity),
                        verdict.reason,
                    });
                    try self.requestPasteConfirm(.paste, payload);
                    return;
                }
            }
            self.core_surface.completeClipboardRequest(.paste, payload, false) catch |err| switch (err) {
                error.UnsafePaste, error.UnauthorizedPaste => try self.requestPasteConfirm(.paste, payload),
                else => return err,
            };
            return;
        }
        try self.writeClipboardText(payload);
    }

    pub fn paintQuickSelect(self: *Surface) void {
        const hwnd = self.quick_select_hwnd orelse return;
        var ps: PAINTSTRUCT = undefined;
        const hdc = sys.BeginPaint(hwnd, &ps);
        defer _ = sys.EndPaint(hwnd, &ps);
        var client: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client) == 0) return;
        fillSolidRect(hdc, client, scrollbar_transparent_key);

        const host = self.host orelse return;
        const theme = &self.app.resolved_theme;
        const metrics: win32_theme.ThemeMetrics = if (isHighContrastActive())
            .highContrast()
        else
            .{};
        _ = sys.SetBkMode(hdc, c.TRANSPARENT);
        _ = sys.SetTextColor(hdc, theme.button_active_fg);
        const previous_font: ?HGDIOBJ = if (host.chrome_font) |font| sys.SelectObject(hdc, font) else null;
        defer {
            if (previous_font) |font| _ = sys.SelectObject(hdc, font);
        }

        _ = self.ensureQuickSelectLabelRects(client, metrics, host.current_dpi);
        const session = if (self.quick_select_session) |*value| value else return;
        for (session.scan.matches, 0..) |_, index| {
            const label = session.labels.get(index);
            if (index >= session.placed_slots.len) continue;
            const slot = session.placed_slots[index] orelse continue;
            var chip = session.placed_rects[slot];
            drawRoundedRect(
                hdc,
                chip,
                theme.button_active_bg,
                theme.button_active_border,
                host.scaled(metrics.radius_md),
            );

            var utf16: [win32_hints.PrefixState.max_len]u16 = undefined;
            for (label, 0..) |byte, i| utf16[i] = quickSelectLabelDisplayUnit(byte);
            _ = sys.DrawTextW(
                hdc,
                @ptrCast(&utf16),
                @intCast(label.len),
                &chip,
                c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX,
            );
        }
    }

    fn ensureScrollbarWindow(self: *Surface) !void {
        if (self.scrollbar_hwnd != null) return;

        const host = self.host orelse return;
        const hwnd = host.hwnd orelse return;
        self.scrollbar_hwnd = sys.CreateWindowExW(
            // Drawn above its pane (`stackChildAbove`) but never hit: the
            // pane keeps every mouse message over the bar, and its
            // right-edge proxy (`scrollbarProxyPointFromSurfaceCursor`)
            // drives the bar. A hit-testable bar would take the wheel and
            // the right, middle and X buttons from the terminal, and the
            // pointer crossing between bar and pane would trade
            // `WM_MOUSELEAVE`s that clear the hover (measured with
            // `WindowFromPoint`: the thumb and track hit the bar without
            // this).
            c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT,
            scrollbar_class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            c.WS_CHILD,
            0,
            0,
            self.scrollbarHoverWidthPx(),
            32,
            hwnd,
            null,
            self.app.hinstance,
            null,
        ) orelse return lastError();

        const scrollbar_hwnd = self.scrollbar_hwnd.?;
        setWindowData(scrollbar_hwnd, self);
        if (sys.SetLayeredWindowAttributes(
            scrollbar_hwnd,
            scrollbar_transparent_key,
            0,
            c.LWA_ALPHA | c.LWA_COLORKEY,
        ) == 0) {
            return lastError();
        }
        self.scrollbar_uia_provider = self.createChromeUiaProvider(scrollbar_hwnd, .{
            .ctx = @ptrCast(self),
            .role = .scrollbar,
            .name = &scrollbarUiaName,
            .range_value = &scrollbarUiaRange,
        });
    }

    fn destroyScrollbarWindow(self: *Surface) void {
        if (self.scrollbar_state.dragging) _ = sys.ReleaseCapture();
        self.clearScrollbarMarkers();
        detachChromeControlProvider(self.app, &self.scrollbar_uia_provider);
        if (self.scrollbar_hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        self.scrollbar_hwnd = null;
        self.scrollbar_placement = .{};
        self.scrollbar_leave_armed = false;
        self.scrollbar_leave_hwnd = null;
        self.scrollbar_drag_anchor_offset = 0;
        self.scrollbar_alpha_cache = 0;
        self.scrollbar_paint_cache = null;
        self.scrollbar_state = .{};
    }

    pub fn invalidateScrollbarWindow(self: *Surface) void {
        if (self.scrollbar_hwnd) |hwnd| _ = sys.InvalidateRect(hwnd, null, 0);
    }

    fn settleReducedScrollbarState(self: *Surface, now_ms: u64) void {
        if (scrollbarAnimationsEnabled()) return;
        switch (self.scrollbar_state.visibility) {
            .fading_in, .fading_out => _ = self.scrollbar_state.tick(
                now_ms + win32_scrollbar_geometry.auto_hide_fade_ms,
            ),
            else => {},
        }
    }

    fn noteScrollbarActivity(self: *Surface, now_ms: u64) void {
        if (self.scrollbarPolicy() != .dynamic) return;
        self.scrollbar_state.onScrollActivity(now_ms);
        self.settleReducedScrollbarState(now_ms);
    }

    pub fn armScrollbarLeaveTracking(self: *Surface, hwnd: HWND) void {
        if (self.scrollbar_leave_armed and self.scrollbar_leave_hwnd == hwnd) return;
        var track: TRACKMOUSEEVENT = .{
            .cbSize = @sizeOf(TRACKMOUSEEVENT),
            .dwFlags = c.TME_LEAVE,
            .hwndTrack = hwnd,
            .dwHoverTime = 0,
        };
        if (sys.TrackMouseEvent(&track) == 0) return;
        self.scrollbar_leave_armed = true;
        self.scrollbar_leave_hwnd = hwnd;
    }

    fn updateScrollbarFromLocalCursor(
        self: *Surface,
        tracking_hwnd: ?HWND,
        x: f32,
        y: f32,
        now_ms: u64,
    ) bool {
        const layout = self.scrollbarLocalLayout() orelse return false;
        const over_track = win32_scrollbar_geometry.pointOverTrack(layout, x, y);

        if (tracking_hwnd) |value| self.armScrollbarLeaveTracking(value);
        self.setScrollbarHovered(over_track, now_ms);

        if (self.scrollbar_state.dragging) {
            self.noteScrollbarActivity(now_ms);
            self.scrollbarScrollToRow(win32_scrollbar_geometry.rowFromCursor(
                layout,
                y,
                self.scrollbar_drag_anchor_offset,
            )) catch |err| {
                log.warn("win32 scrollbar drag failed err={}", .{err});
            };
        }
        return over_track;
    }

    fn handleScrollbarMouseMoveLocal(self: *Surface, tracking_hwnd: HWND, x: f32, y: f32) void {
        const now_ms = sys.GetTickCount64();
        _ = self.updateScrollbarFromLocalCursor(tracking_hwnd, x, y, now_ms);
        self.syncScrollbarWindowNow(now_ms) catch |err| {
            log.warn("win32 scrollbar move failed err={}", .{err});
        };
    }

    fn handleScrollbarLeftButtonDownLocal(self: *Surface, hwnd: HWND, x: f32, y: f32) void {
        const layout = self.scrollbarLocalLayout() orelse return;
        const now_ms = sys.GetTickCount64();
        const thumb = win32_scrollbar_geometry.thumbRect(layout);
        self.setScrollbarHovered(true, now_ms);
        self.setScrollbarDragging(true, now_ms);
        self.noteScrollbarActivity(now_ms);
        self.scrollbar_drag_anchor_offset = if (win32_scrollbar_geometry.pointOverThumb(layout, x, y))
            std.math.clamp(y - thumb.top, 0.0, thumb.bottom - thumb.top)
        else
            @max(0.0, (thumb.bottom - thumb.top) / 2.0);
        _ = sys.SetCapture(hwnd);
        self.scrollbarScrollToRow(win32_scrollbar_geometry.rowFromCursor(
            layout,
            y,
            self.scrollbar_drag_anchor_offset,
        )) catch |err| {
            log.warn("win32 scrollbar click failed err={}", .{err});
        };
        self.syncScrollbarWindowNow(now_ms) catch |err| {
            log.warn("win32 scrollbar press failed err={}", .{err});
        };
    }

    fn handleScrollbarLeftButtonUpLocal(self: *Surface, x: f32, y: f32) void {
        const now_ms = sys.GetTickCount64();
        const layout = self.scrollbarLocalLayout();
        _ = sys.ReleaseCapture();
        self.setScrollbarDragging(false, now_ms);
        if (layout) |value| {
            self.setScrollbarHovered(
                win32_scrollbar_geometry.pointOverTrack(value, x, y),
                now_ms,
            );
        } else {
            self.setScrollbarHovered(false, now_ms);
        }
        self.syncScrollbarWindowNow(now_ms) catch |err| {
            log.warn("win32 scrollbar release failed err={}", .{err});
        };
    }

    fn setScrollbarHovered(self: *Surface, hovered: bool, now_ms: u64) void {
        if (self.scrollbar_state.hovered == hovered) return;
        self.scrollbar_state.setHovered(hovered, now_ms);
        self.settleReducedScrollbarState(now_ms);
    }

    fn setScrollbarDragging(self: *Surface, dragging: bool, now_ms: u64) void {
        if (self.scrollbar_state.dragging == dragging) return;
        self.scrollbar_state.setDragging(dragging, now_ms);
        self.settleReducedScrollbarState(now_ms);
    }

    pub fn syncScrollbarWindowNow(self: *Surface, now_ms: u64) !void {
        const host = self.host orelse return;
        // Callers change the state before they sync (output, the wheel, a
        // press), so a bar that needs the heartbeat starts it here; the
        // tick stops it once no bar needs it.
        defer if (self.scrollbarNeedsHeartbeat()) host.ensureScrollbarTimer();
        const policy = self.scrollbarPolicy();
        const should_exist = self.window_visible and self.scrollbarScrollable() and
            self.placement.rect_known and self.placement.visible;

        if (!should_exist or policy == .never) {
            if (self.scrollbar_state.dragging) _ = sys.ReleaseCapture();
            self.setScrollbarHovered(false, now_ms);
            self.setScrollbarDragging(false, now_ms);
            self.scrollbar_state.visibility = .hidden;
            self.scrollbar_alpha_cache = 0;
            self.scrollbar_paint_cache = null;
            if (self.scrollbar_hwnd) |hwnd| {
                _ = applyChildVisibility(hwnd, &self.scrollbar_placement, false);
            }
            return;
        }

        try self.ensureScrollbarWindow();
        const scrollbar_hwnd = self.scrollbar_hwnd.?;
        const child_rect = self.scrollbarChildRect(self.placement.rect);
        _ = applyChildRect(scrollbar_hwnd, &self.scrollbar_placement, child_rect);

        const marker_budget = scrollbarMarkerBudgetForHeight(child_rect.bottom - child_rect.top);
        if (marker_budget != self.scrollbar_marker_budget) {
            try self.rebuildScrollbarMarkers(marker_budget);
        }

        switch (policy) {
            .always => {
                self.scrollbar_state.visibility = .visible;
                self.scrollbar_state.last_activity_ms = now_ms;
                self.scrollbar_state.fade_started_ms = now_ms;
            },
            .dynamic => self.settleReducedScrollbarState(now_ms),
            .never => unreachable,
        }

        // Without animations the settled state is fully shown or hidden.
        const alpha = alphaByteForOpacity(self.scrollbar_state.alpha(now_ms));
        const paint_key = self.scrollbarPaintKey(child_rect);
        const paint_changed = scrollbarPaintKeyChanged(self.scrollbar_paint_cache, paint_key);
        if (alpha != self.scrollbar_alpha_cache) {
            if (sys.SetLayeredWindowAttributes(
                scrollbar_hwnd,
                scrollbar_transparent_key,
                alpha,
                c.LWA_ALPHA | c.LWA_COLORKEY,
            ) == 0) {
                return lastError();
            }
            self.scrollbar_alpha_cache = alpha;
        }
        // A hidden bar is a hidden window, not a transparent one over the
        // pane. Hover comes from the pane's right-edge proxy either way.
        const shown = self.scrollbar_state.visibility != .hidden;
        if (applyChildVisibility(scrollbar_hwnd, &self.scrollbar_placement, shown) and shown) {
            // Created after its pane, the bar starts below it, where the
            // pane hides it (measured: the bar at index 6, its pane at 0).
            if (self.hwnd) |pane| stackChildAbove(scrollbar_hwnd, pane);
        }

        if (paint_changed) {
            self.scrollbar_paint_cache = paint_key;
            self.invalidateScrollbarWindow();
        }
    }

    pub fn refreshScrollbarWindow(self: *Surface) !void {
        try self.syncScrollbarWindowNow(sys.GetTickCount64());
    }

    pub fn scrollbarNeedsHeartbeat(self: *const Surface) bool {
        return scrollbarNeedsHeartbeatForState(
            self.scrollbarPolicy(),
            self.window_visible,
            self.scrollbarScrollable(),
            self.scrollbar_state.visibility,
        );
    }

    pub fn tickScrollbar(self: *Surface, now_ms: u64) void {
        const prev_hovered = self.scrollbar_state.hovered;
        const prev_dragging = self.scrollbar_state.dragging;
        const prev_visibility = self.scrollbar_state.visibility;
        var over_scrollbar = false;
        if (self.hwnd) |hwnd| {
            over_scrollbar = self.updateScrollbarHoverFromScreenCursor(hwnd, now_ms);
        }
        if (self.scrollbarPolicy() == .dynamic and self.scrollbarScrollable()) {
            _ = self.scrollbar_state.tick(now_ms);
            self.settleReducedScrollbarState(now_ms);
        }
        if (!over_scrollbar and
            self.scrollbar_state.hovered == prev_hovered and
            self.scrollbar_state.dragging == prev_dragging and
            self.scrollbar_state.visibility == prev_visibility and
            self.scrollbar_state.visibility == .hidden)
        {
            return;
        }
        self.syncScrollbarWindowNow(now_ms) catch |err| {
            log.warn("win32 scrollbar tick failed err={}", .{err});
        };
    }

    fn scrollbarScrollToRow(self: *Surface, row: usize) !void {
        if (!self.core_initialized) return;
        self.app.activateSurfaceNoFocus(self);
        _ = try self.core_surface.performBindingAction(.{ .scroll_to_row = row });
    }

    pub fn handleScrollbarMouseMove(self: *Surface, hwnd: HWND, lParam: LPARAM) void {
        const x: f32 = @floatFromInt(signedLowWord(lParamBits(lParam)));
        const y: f32 = @floatFromInt(signedHighWord(lParamBits(lParam)));
        self.handleScrollbarMouseMoveLocal(hwnd, x, y);
    }

    pub fn handleScrollbarMouseLeave(self: *Surface) void {
        self.scrollbar_leave_armed = false;
        self.scrollbar_leave_hwnd = null;
        if (self.scrollbar_state.dragging) return;
        const now_ms = sys.GetTickCount64();
        self.setScrollbarHovered(false, now_ms);
        self.syncScrollbarWindowNow(now_ms) catch |err| {
            log.warn("win32 scrollbar leave failed err={}", .{err});
        };
    }

    pub fn handleScrollbarLeftButtonDown(self: *Surface, hwnd: HWND, lParam: LPARAM) void {
        const x: f32 = @floatFromInt(signedLowWord(lParamBits(lParam)));
        const y: f32 = @floatFromInt(signedHighWord(lParamBits(lParam)));
        self.handleScrollbarLeftButtonDownLocal(hwnd, x, y);
    }

    pub fn handleScrollbarLeftButtonUp(self: *Surface, lParam: LPARAM) void {
        const x: f32 = @floatFromInt(signedLowWord(lParamBits(lParam)));
        const y: f32 = @floatFromInt(signedHighWord(lParamBits(lParam)));
        self.handleScrollbarLeftButtonUpLocal(x, y);
    }

    fn scrollbarProxyPointFromScreenCursor(self: *const Surface, hwnd: HWND) ?ScrollbarProxyPoint {
        if (!self.window_visible or !self.scrollbarScrollable()) return null;
        if (self.scrollbarPolicy() == .never or !self.placement.rect_known) return null;

        var point: POINT = .{ .x = 0, .y = 0 };
        if (sys.GetCursorPos(&point) == 0) return null;
        if (sys.ScreenToClient(hwnd, &point) == 0) return null;

        return scrollbarProxyPointFromSurfaceCoords(
            self.placement.rect,
            self.scrollbarHoverWidthPx(),
            point.x,
            point.y,
        );
    }

    pub fn updateScrollbarHoverFromScreenCursor(self: *Surface, hwnd: HWND, now_ms: u64) bool {
        const proxy = self.scrollbarProxyPointFromScreenCursor(hwnd) orelse {
            if (self.scrollbar_state.hovered and !self.scrollbar_state.dragging) {
                self.setScrollbarHovered(false, now_ms);
            }
            return false;
        };

        if (proxy.over_band or self.scrollbar_state.dragging) {
            return self.updateScrollbarFromLocalCursor(
                null,
                proxy.local_x,
                proxy.local_y,
                now_ms,
            );
        }

        if (self.scrollbar_state.hovered) {
            self.setScrollbarHovered(false, now_ms);
        }
        return false;
    }

    pub fn handleScrollbarProxyMouseMove(self: *Surface, hwnd: HWND, lParam: LPARAM) bool {
        if (!self.window_visible or !self.scrollbarScrollable()) return false;
        if (self.scrollbarPolicy() == .never or !self.placement.rect_known) return false;

        const proxy = scrollbarProxyPointFromSurfaceCursor(
            self.placement.rect,
            self.scrollbarHoverWidthPx(),
            lParam,
        );
        if (proxy.over_band or self.scrollbar_state.dragging) {
            self.handleScrollbarMouseMoveLocal(hwnd, proxy.local_x, proxy.local_y);
            return true;
        }

        if (self.scrollbar_state.hovered) {
            const now_ms = sys.GetTickCount64();
            self.setScrollbarHovered(false, now_ms);
            self.syncScrollbarWindowNow(now_ms) catch |err| {
                log.warn("win32 scrollbar proxy leave failed err={}", .{err});
            };
        }
        return false;
    }

    pub fn handleScrollbarProxyButton(self: *Surface, hwnd: HWND, msg: UINT, lParam: LPARAM) bool {
        if (!self.window_visible or !self.scrollbarScrollable()) return false;
        if (self.scrollbarPolicy() == .never or !self.placement.rect_known) return false;

        const proxy = scrollbarProxyPointFromSurfaceCursor(
            self.placement.rect,
            self.scrollbarHoverWidthPx(),
            lParam,
        );
        return switch (msg) {
            c.WM_LBUTTONDOWN => blk: {
                if (!proxy.over_band) break :blk false;
                self.handleScrollbarLeftButtonDownLocal(hwnd, proxy.local_x, proxy.local_y);
                break :blk true;
            },
            c.WM_LBUTTONUP => blk: {
                if (!self.scrollbar_state.dragging and !proxy.over_band) break :blk false;
                self.handleScrollbarLeftButtonUpLocal(proxy.local_x, proxy.local_y);
                break :blk true;
            },
            else => false,
        };
    }

    pub fn handleScrollbarCaptureChanged(self: *Surface) void {
        if (!self.scrollbar_state.dragging) return;
        const now_ms = sys.GetTickCount64();
        self.setScrollbarDragging(false, now_ms);
        self.syncScrollbarWindowNow(now_ms) catch |err| {
            log.warn("win32 scrollbar capture reset failed err={}", .{err});
        };
    }

    pub fn paintScrollbar(self: *Surface) void {
        const hwnd = self.scrollbar_hwnd orelse return;
        var ps: PAINTSTRUCT = undefined;
        const hdc = sys.BeginPaint(hwnd, &ps) orelse return;
        defer _ = sys.EndPaint(hwnd, &ps);

        var client_rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client_rect) == 0) return;
        fillSolidRect(hdc, client_rect, scrollbar_transparent_key);
        if (!self.scrollbarScrollable()) return;

        const layout = self.scrollbarLocalLayout() orelse return;
        const theme = &self.app.resolved_theme;
        const is_hc = isHighContrastActive();
        const track = scrollbarRectToRect(win32_scrollbar_geometry.trackRect(layout));
        const thumb = scrollbarRectToRect(win32_scrollbar_geometry.thumbRect(layout));
        const track_bg = if (is_hc)
            theme.chrome_border
        else if (theme.is_dark)
            blendColorRGB(theme.chrome_bg, theme.chrome_border, 0.65)
        else
            blendColorRGB(theme.chrome_bg, theme.chrome_border, 0.35);
        const track_border = if (is_hc)
            theme.text_primary
        else if (theme.is_dark)
            adjustColor(track_bg, 20, 20, 24)
        else
            adjustColor(track_bg, -18, -18, -18);
        const thumb_bg = if (is_hc)
            theme.text_primary
        else if (self.scrollbar_state.dragging)
            theme.accent_hover
        else if (self.scrollbar_state.hovered)
            theme.accent
        else
            blendColorRGB(theme.text_secondary, theme.chrome_border, if (theme.is_dark) 0.30 else 0.45);
        const thumb_border = if (is_hc)
            theme.chrome_border
        else if (self.scrollbar_state.dragging or self.scrollbar_state.hovered)
            theme.accent_hover
        else if (theme.is_dark)
            adjustColor(thumb_bg, 16, 16, 18)
        else
            adjustColor(thumb_bg, -16, -16, -16);
        const marker_color = if (is_hc) theme.accent else blendColorRGB(theme.accent, thumb_bg, 0.20);
        const radius = if (is_hc) 0 else @max(2, @min(track.right - track.left, track.bottom - track.top));

        drawRoundedRect(hdc, track, track_bg, track_border, radius);

        const track_height = @max(1, track.bottom - track.top);
        const marker_height: i32 = if (is_hc) 3 else 2;
        const marker_left = track.left + 1;
        const marker_right = @max(marker_left + 1, track.right - 1);
        for (self.scrollbar_markers) |value| {
            const top = track.top + @as(i32, @intFromFloat(@round(
                value * @as(f32, @floatFromInt(@max(0, track_height - marker_height))),
            )));
            fillSolidRect(hdc, .{
                .left = marker_left,
                .top = top,
                .right = marker_right,
                .bottom = top + marker_height,
            }, marker_color);
        }

        drawRoundedRect(hdc, thumb, thumb_bg, thumb_border, radius);
    }

    pub const searchQueryOptions = search_controls.SurfaceControls.searchQueryOptions;

    pub const applySearchBarFont = search_controls.SurfaceControls.applySearchBarFont;

    pub const invalidateSearchButtons = search_controls.SurfaceControls.invalidateSearchButtons;

    pub const invalidateSearchBarChildPaint = search_controls.SurfaceControls.invalidateSearchBarChildPaint;

    pub const invalidateSearchBarFrameRect = search_controls.SurfaceControls.invalidateSearchBarFrameRect;

    pub const invalidateSearchBarFrame = search_controls.SurfaceControls.invalidateSearchBarFrame;

    pub const updateSearchBarFrameRect = search_controls.SurfaceControls.updateSearchBarFrameRect;

    pub const invalidateSearchBarLayoutCache = search_controls.SurfaceControls.invalidateSearchBarLayoutCache;

    pub const hideSearchBarControls = search_controls.SurfaceControls.hideSearchBarControls;

    pub const createSearchBarButton = search_controls.SurfaceControls.createSearchBarButton;

    pub const ensureSearchBarControls = search_controls.SurfaceControls.ensureSearchBarControls;

    pub const destroySearchBarControls = search_controls.SurfaceControls.destroySearchBarControls;

    pub const hideSearchBarButton = search_controls.SurfaceControls.hideSearchBarButton;

    pub const showSearchBarButton = search_controls.SurfaceControls.showSearchBarButton;

    pub const layoutSearchBarControls = search_controls.SurfaceControls.layoutSearchBarControls;

    const setSearchBarEditText = search_controls.SurfaceControls.setSearchBarEditText;

    pub const readSearchBarEditText = search_controls.SurfaceControls.readSearchBarEditText;

    pub const syncSearchBarResultsText = search_controls.SurfaceControls.syncSearchBarResultsText;

    pub const issueSearchNow = search_controls.SurfaceControls.issueSearchNow;

    pub const runPendingSearchNow = search_controls.SurfaceControls.runPendingSearchNow;

    pub const rerunSearchNow = search_controls.SurfaceControls.rerunSearchNow;

    pub const handleSearchBarEditChanged = search_controls.SurfaceControls.handleSearchBarEditChanged;

    pub const navigateDockedSearch = search_controls.SurfaceControls.navigateDockedSearch;

    pub const handleSearchToggleClick = search_controls.SurfaceControls.handleSearchToggleClick;

    pub fn closeDockedSearchBar(self: *Surface, stop_search: bool, refocus_terminal: bool) anyerror!void {
        if (stop_search) {
            _ = try self.core_surface.endSearch();
            if (refocus_terminal) {
                if (self.hwnd) |hwnd| _ = sys.SetFocus(hwnd);
            }
            return;
        }

        const host = self.host orelse return;
        self.docked_search.close();
        self.docked_search.total = null;
        self.docked_search.selected = null;
        try self.setSearchActive(false, "");
        _ = self.hideSearchBarControls();
        host.refreshSearchTimerState();
        try host.layout();
        host.forceHostCompositionPaint();
        if (refocus_terminal) {
            if (self.hwnd) |hwnd| _ = sys.SetFocus(hwnd);
        }
    }

    pub fn showSearchOverlay(self: *Surface, needle: []const u8) !void {
        const host = self.host orelse return;
        if (host.overlay_mode != .none) host.hideOverlay();

        try self.ensureSearchBarControls();
        self.docked_search.open();

        const initial = if (needle.len > 0)
            needle
        else if (self.docked_search.query.len > 0)
            self.docked_search.query
        else if (self.docked_search.needle) |value|
            value
        else
            "";
        const same_query = if (self.docked_search.needle) |value|
            std.mem.eql(u8, value, initial)
        else
            false;
        const restore_live_results = initial.len > 0 and self.docked_search.active and same_query;
        if (!std.mem.eql(u8, self.docked_search.query, initial)) {
            try self.docked_search.setQuery(initial, 0);
        }
        if (!restore_live_results) {
            self.docked_search.total = null;
            self.docked_search.selected = null;
        }
        self.docked_search.searched = initial.len == 0 or restore_live_results;
        self.docked_search.last_edit_ms = 0;

        _ = try self.setSearchBarEditText(initial);
        _ = try self.syncSearchBarResultsText();
        try host.layout();
        host.refreshSearchTimerState();
        host.forceHostCompositionPaint();

        if (self.search_bar_edit_hwnd) |edit_hwnd| {
            _ = sys.SetFocus(edit_hwnd);
            _ = sys.SendMessageW(edit_hwnd, c.EM_SETSEL, 0, -1);
        }

        if (initial.len > 0 and (!self.docked_search.active or !same_query)) {
            _ = try self.rerunSearchNow();
        }
    }

    pub fn setInspectorVisible(self: *Surface, visible: bool) !bool {
        if (visible == self.inspector_visible) return false;
        if (!self.core_initialized) return false;
        const host = self.host;
        const panel_was_visible = if (host) |h| h.inspectorPanelVisible() else false;

        if (visible) {
            try self.core_surface.activateInspector();
        } else {
            self.core_surface.deactivateInspector();
        }
        self.inspector_visible = visible;
        if (host) |h| {
            const panel_now_visible = h.inspectorPanelVisible();
            var chrome_invalidated = false;
            if (h.overlay_mode == .none) {
                chrome_invalidated = inspectorBannerStateChanged(
                    h.overlay_mode,
                    h.banner_kind,
                    h.banner_text,
                    visible,
                );
                if (visible) {
                    try h.setBanner(.none, null);
                } else if (!panel_now_visible) {
                    try h.setBanner(.info, host_banner_inspector_inactive);
                } else {
                    try h.setBanner(.none, null);
                }
            }
            if (!chrome_invalidated and inspectorChromeVisible(h.overlay_mode)) {
                h.invalidateTopChromeText();
            }
            if (panel_was_visible != panel_now_visible) {
                h.invalidateActiveSearchBarLayoutCaches();
                try h.layout();
                h.forceHostCompositionPaint();
            } else if (chrome_invalidated or inspectorChromeVisible(h.overlay_mode)) {
                h.forceHostCompositionPaint();
            }
        }
        try self.requestRepaint();
        try self.refreshWindowTitle();
        return true;
    }

    fn refreshWindowTitle(self: *Surface) !void {
        const host = self.host orelse return;

        // Two chrome elements show a surface title: the window caption,
        // synced by `syncWindowTitle`, and the tab strip, synced by
        // `syncTabButtons`. The latter is otherwise only reachable through
        // `refreshChrome`, which no title path calls, so a tab label kept
        // whatever title the shell emitted first until an unrelated event
        // (tab activation, focus change, tab reorder, split undo) refreshed
        // the whole chrome.
        //
        // Neither sync propagates: see `chromeSyncOrLog`. Both are reachable
        // only from title setters, which run under `App.tick`.
        const caption_changed = chromeSyncOrLog(
            "title window caption sync failed",
            host.syncWindowTitle(),
        );
        const tabs_changed = chromeSyncOrLog(
            "title tab label sync failed",
            host.syncTabButtons(),
        );

        if (caption_changed or tabs_changed) host.invalidateTopChromeText();
    }

    pub const toggleMaximize = window_state.toggleMaximize;

    pub fn applyRuntimeConfig(self: *Surface, config: *const configpkg.Config) !void {
        self.applyBellFeatures(config.@"bell-features");
        if (shouldApplyConfigDecorations(self.decorations_visible_overridden)) {
            self.setDecorationsVisible(decorationsVisibleForConfig(config.@"window-decoration")) catch |err| {
                log.warn("win32 decoration update failed during config reload err={}", .{err});
            };
        }
        self.background_opacity_default = normalizedBackgroundOpacity(self.app.shownBackgroundOpacity(config));
        self.scrollbar_config = config.scrollbar;
        if (self.background_opacity_default >= 0.999) {
            self.background_opacity_force_opaque = false;
        }
        try self.applyBackgroundOpacity();
        try self.refreshScrollbarWindow();
    }

    /// Take `color`, from this terminal's own config (its `config_change`),
    /// as the background its tab shows when active. Not from
    /// `applyRuntimeConfig`: the app's config reaches that for every
    /// window (a reload, a Settings opacity preview), and a window opened
    /// with a forwarded `--background` keeps its own.
    pub fn setTabBackground(self: *Surface, color: configpkg.Config.Color) void {
        const value = colorRefFromConfig(color);
        if (value == self.tab_background) return;
        self.tab_background = value;
        if (self.host) |host| host.syncTabJoin();
    }

    pub const toggleBackgroundOpacity = window_state.toggleBackgroundOpacity;

    fn resizeSplitFallback(self: *Surface, value: apprt.action.ResizeSplit) !bool {
        const hwnd = self.hwnd orelse return false;
        var client_rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &client_rect) == 0) {
            return lastError();
        }

        const delta = resizeSplitFallbackDelta(value);
        const current_width = client_rect.right - client_rect.left;
        const current_height = client_rect.bottom - client_rect.top;
        const next_width = @max(1, current_width + delta.width);
        const next_height = @max(1, current_height + delta.height);

        try self.resizeClientArea(@intCast(next_width), @intCast(next_height));
        return true;
    }

    pub const toggleFullscreen = window_state.toggleFullscreen;

    pub const toggleDecorations = window_state.toggleDecorations;

    pub const setInitialSize = window_state.setInitialSize;

    pub const hostSurfaceCount = window_state.hostSurfaceCount;

    pub const resetWindowSize = window_state.resetWindowSize;

    pub const setSizeLimit = window_state.setSizeLimit;

    pub fn setCellSize(self: *Surface, size: apprt.action.CellSize) void {
        self.cell_size_pixels = size;
    }

    pub const setFloatWindow = window_state.setFloatWindow;

    pub const applyWindowStart = window_state.applyWindowStart;

    pub const enterFullscreen = window_state.enterFullscreen;

    pub const FullscreenReturn = window_state.FullscreenReturn;

    pub const fullscreenReturn = window_state.fullscreenReturn;

    pub const leaveFullscreen = window_state.leaveFullscreen;

    pub const windowMonitor = window_state.windowMonitor;

    pub const screenRectToWorkspace = window_state.screenRectToWorkspace;

    pub const setDecorationsVisible = window_state.setDecorationsVisible;

    pub const rollbackDecorationsVisible = window_state.rollbackDecorationsVisible;

    pub const resizeClientArea = window_state.resizeClientArea;

    pub const copySharedWindowStateFrom = window_state.copySharedWindowStateFrom;

    pub const activeSharedHostWindowHwnd = window_state.activeSharedHostWindowHwnd;

    pub const syncSharedHostWindowState = window_state.syncSharedHostWindowState;

    pub const refreshSharedWindowFrame = window_state.refreshSharedWindowFrame;

    pub const inheritWindowStateFrom = window_state.inheritWindowStateFrom;

    pub const updateMinMaxInfo = window_state.updateMinMaxInfo;

    pub const keepsFrameUndecorated = window_state.keepsFrameUndecorated;

    pub const applyWindowStyle = window_state.applyWindowStyle;

    pub const applyInitialBackgroundOpacity = window_state.applyInitialBackgroundOpacity;

    pub const applyBackgroundOpacity = window_state.applyBackgroundOpacity;

    pub const applyTopmost = window_state.applyTopmost;

    pub const syncCoreSizeFromClientRect = surface_presentation.syncCoreSizeFromClientRect;

    pub const syncCoreSizeNow = surface_presentation.syncCoreSizeNow;

    pub const applyDpiChange = surface_presentation.applyDpiChange;

    pub const beginCoreResizeBatch = surface_presentation.beginCoreResizeBatch;

    pub const endCoreResizeBatch = surface_presentation.endCoreResizeBatch;

    pub const windowSizeChanged = surface_presentation.windowSizeChanged;

    pub fn setSplitDimmed(self: *Surface, dimmed: bool) void {
        self.split_dimmed = dimmed;
        self.flushSplitDimmed();
    }

    /// Tell the renderer about a change of `split_dimmed`. A surface whose
    /// core has not started has no renderer yet; `init` flushes once it has.
    fn flushSplitDimmed(self: *Surface) void {
        if (!self.core_initialized or self.split_dimmed_sent == self.split_dimmed) return;
        self.split_dimmed_sent = self.split_dimmed;
        self.core_surface.renderer_thread.send(.{ .split_dimmed = self.split_dimmed });
    }

    pub fn focusChanged(self: *Surface, focused: bool) void {
        self.window_focused = focused;
        // The idle benchmark invalidates a sample when focus moves during
        // the measurement. That guard was reading a counter nothing ever
        // incremented, so it could never fire.
        self.render_trace.noteSurfaceFocusChanged(focused);
        const focus_state_changed = if (focused) self.app.noteSurfaceFocused(self) else false;
        // After the tab is active, so the caption it rewrites is this tab's.
        if (focused) self.clearBell();
        if (!self.core_initialized) return;
        if (focused) self.app.core_app.focusSurface(self.core());
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("win32 focus callback failed err={}", .{err});
        };
        if (self.terminal_accessibility) |session| session.focusChanged(focused);
        self.syncTerminalAccessibilityOutputInterest();
        // Host chrome only changes for split-pane focus borders.
        if (self.host) |host| {
            const pane_count = if (host.activeTab()) |tab| tab.leafCount() else 0;
            if (hostChromeNeedsFocusRepaint(pane_count)) host.repaintContentChrome();
            if (focus_state_changed) {
                runUiActionOrLog("focus chrome refresh failed", host.refreshChrome());
            }
        }
        // A terminal gains focus when the user activates its window or
        // switches to its tab, which is the user looking at it.
        if (focused) {
            if (Host.findTabForSurface(self)) |found| self.app.acknowledgeTab(found.host, found.index);
        }
    }

    pub fn handleKeyMessage(
        self: *Surface,
        msg: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
        typed: *const win32_input.TypedChars,
    ) void {
        if (!self.core_initialized) return;
        // A press answers the bell; a release does not (it can belong to the
        // key that ran the command that rang it).
        if (msg == c.WM_KEYDOWN or msg == c.WM_SYSKEYDOWN) self.clearBell();

        // Under Kitty `report_all` the text must ride on the physical key
        // event so press and release keep one identity, and under Win32
        // input mode the key record carries the characters it typed; see
        // `win32_input.deferPlainTextToCharMessage`. Read at every key, as
        // the encoder does: the mode and the Kitty flags are the terminal's
        // live state.
        const encode_opts = encode_opts: {
            self.core_surface.renderer_state.mutex.lock();
            defer self.core_surface.renderer_state.mutex.unlock();
            break :encode_opts input.key_encode.Options.fromTerminal(
                self.core_surface.renderer_state.terminal,
            );
        };
        // An IME owns the keys it composes with; its result arrives as text.
        const win32_records = encode_opts.win32InputRecords() and !self.ime_composing;
        win32_input.dispatchKeyMessage(
            KeyTarget{ .surface = self },
            &self.deferred_char,
            msg,
            wParam,
            lParam,
            win32_input.deferPlainTextToCharMessage(
                encode_opts.kitty_flags.report_all or win32_records,
                self.ime_composing,
            ),
            self.ime_composing,
            win32_records,
            typed,
        );
    }

    pub fn handleCharMessage(self: *Surface, msg: UINT, wParam: WPARAM, lParam: LPARAM) void {
        if (!self.core_initialized) return;
        win32_input.dispatchCharMessage(
            KeyTarget{ .surface = self },
            &self.deferred_char,
            msg,
            wParam,
            lParam,
            self.ime_composing,
        );
    }

    /// Input for this terminal's program arrived: a key, a click, the wheel,
    /// a paste or drop, palette or automation text. While the program still
    /// runs, that uses the session (`App.restored_session_untouched`). Into
    /// a program that has already ended it does not: there it only closes
    /// the pane, and a restore that failed must not count as used for that.
    pub fn noteProgramInput(self: *Surface) void {
        if (self.core_initialized and !self.core_surface.child_exited) self.app.restored_session_untouched = false;
    }

    /// This terminal's program has ended, by itself or killed.
    pub fn programEnded(self: *const Surface) bool {
        return self.core_initialized and self.core_surface.child_exited;
    }

    /// Whether a key event is input meant for the program: not a release,
    /// whose press already counted, and not a modifier on its own (Alt as
    /// the user Alt+Tabs away, Shift for a screenshot).
    fn isProgramKeyInput(event: input.KeyEvent) bool {
        return event.action != .release and !event.key.modifier();
    }

    test "a key release or a modifier alone is not input for the program" {
        try std.testing.expect(isProgramKeyInput(.{ .action = .press, .key = .key_a }));
        try std.testing.expect(isProgramKeyInput(.{ .action = .repeat, .key = .arrow_down }));
        // An IME or character commit has no physical key.
        try std.testing.expect(isProgramKeyInput(.{ .action = .press, .key = .unidentified, .utf8 = "x" }));
        try std.testing.expect(!isProgramKeyInput(.{ .action = .release, .key = .key_a }));
        try std.testing.expect(!isProgramKeyInput(.{ .action = .press, .key = .alt_left }));
        try std.testing.expect(!isProgramKeyInput(.{ .action = .press, .key = .shift_right }));
    }

    /// What the keyboard and IME dispatch in `win32_input` needs from the
    /// surface.
    pub const KeyTarget = struct {
        surface: *Surface,

        pub fn keyCallback(self: KeyTarget, event: input.KeyEvent) !CoreSurface.InputEffect {
            if (isProgramKeyInput(event)) self.surface.noteProgramInput();
            return self.surface.core_surface.keyCallback(event);
        }

        pub fn noteInput(self: KeyTarget, utf8: []const u8) void {
            if (self.surface.terminal_accessibility) |session| session.noteInput(utf8);
        }

        pub fn preeditCallback(self: KeyTarget, preedit: ?[]const u8) void {
            self.surface.core_surface.preeditCallback(preedit) catch {};
        }

        pub fn preeditCaretCallback(
            self: KeyTarget,
            preedit: ?[]const u8,
            caret: ?usize,
            target: ?CoreSurface.PreeditTarget,
        ) void {
            self.surface.core_surface.preeditCaretCallback(preedit, caret, target) catch {};
        }
    };

    pub fn positionImeWindow(self: *Surface) void {
        if (!self.core_initialized) return;
        const ime_pos = self.core_surface.imePoint();
        const forms = imeWindowForms(ime_pos, self.content_scale);

        const surface_hwnd = self.hwnd orelse return;
        const himc = sys.ImmGetContext(surface_hwnd) orelse return;
        defer _ = sys.ImmReleaseContext(surface_hwnd, himc);

        const composition_set = sys.ImmSetCompositionWindow(himc, &forms.composition) != 0;
        const candidate_set = sys.ImmSetCandidateWindow(himc, &forms.candidate) != 0;
        if (composition_set and candidate_set) {
            writeImeWindowFormsTrace(self.app.core_app.alloc, ime_pos, self.content_scale, forms);
        }
    }

    /// Read one IME string (`GCS_RESULTSTR` or `GCS_COMPSTR`) as UTF-8, or
    /// null when there is none or it cannot be read. The input context is
    /// released before this returns, so nothing after it holds the window.
    fn readImeString(
        self: *Surface,
        alloc: std.mem.Allocator,
        which: u32,
        utf8_stack: []u8,
    ) ?win32_input.ImeText {
        const surface_hwnd = self.hwnd orelse return null;
        const himc = sys.ImmGetContext(surface_hwnd) orelse return null;
        var units_stack: [128]u16 = undefined;
        const units = readImeBuffer(u16, himc, alloc, which, &units_stack);
        _ = sys.ImmReleaseContext(surface_hwnd, himc);
        const read = units orelse return null;
        defer read.deinit(alloc);
        return win32_input.imeTextUtf8(alloc, read.items(), utf8_stack) catch null;
    }

    /// One part of the composition as `T` items (UTF-16 units for a string,
    /// bytes for its attributes), in the caller's `stack` when they fit there
    /// and on the heap otherwise.
    fn ImeBuffer(comptime T: type) type {
        return struct {
            buf: []T,
            len: usize,
            heap: bool,

            fn items(self: @This()) []const T {
                return self.buf[0..self.len];
            }

            fn deinit(self: @This(), alloc: std.mem.Allocator) void {
                if (self.heap) alloc.free(self.buf);
            }
        };
    }

    /// Read composition part `which` from `himc` as `T` items, or null when
    /// there is none or it cannot be read.
    fn readImeBuffer(
        comptime T: type,
        himc: *anyopaque,
        alloc: std.mem.Allocator,
        which: u32,
        stack: []T,
    ) ?ImeBuffer(T) {
        const byte_len = sys.ImmGetCompositionStringW(himc, which, null, 0);
        if (byte_len <= 0) return null;
        const count = @as(u32, @intCast(byte_len)) / @sizeOf(T);
        if (count == 0) return null;

        // Most IME strings are short; longer ones go to the heap.
        const heap = count > stack.len;
        const buf: []T = if (!heap)
            stack[0..count]
        else
            alloc.alloc(T, count) catch return null;

        // Never offer IMM more bytes than `buf` holds.
        const read = sys.ImmGetCompositionStringW(himc, which, buf.ptr, count * @sizeOf(T));
        if (read <= 0) {
            if (heap) alloc.free(buf);
            return null;
        }
        const actual_bytes: usize = @intCast(read);
        return .{ .buf = buf, .len = @min(actual_bytes / @sizeOf(T), buf.len), .heap = heap };
    }

    /// Commit the IME's result string. Returns the core's effect: committing
    /// into a pane whose child has exited closes the pane, and the close
    /// frees this surface before the commit returns.
    pub fn handleImeResult(self: *Surface) CoreSurface.InputEffect {
        if (!self.core_initialized) return .ignored;
        // Taken before the commit, which can free `self`.
        const alloc = self.app.core_app.alloc;
        var utf8_stack: [512]u8 = undefined;
        const text = self.readImeString(alloc, c.GCS_RESULTSTR, &utf8_stack) orelse return .ignored;
        defer text.deinit(alloc);
        return self.commitImeResult(KeyTarget{ .surface = self }, text.bytes);
    }

    pub fn commitImeResult(self: *Surface, target: anytype, utf8: []const u8) CoreSurface.InputEffect {
        if (utf8.len == 0) return .ignored;
        // An IME may commit without a physical key message. Answer the bell
        // before dispatch, which can close the pane and free this surface.
        self.clearBell();
        return win32_input.commitImeText(target, utf8);
    }

    pub fn handleImeComposition(self: *Surface) void {
        if (!self.core_initialized) return;
        const alloc = self.app.core_app.alloc;

        // The string, its caret and its clause attributes come from one
        // input context, released before the core sees them.
        var units_stack: [128]u16 = undefined;
        var attrs_stack: [128]u8 = undefined;
        const read: ?ImeBuffer(u16), const cursor: i32, const attrs: ?ImeBuffer(u8) = read: {
            const surface_hwnd = self.hwnd orelse break :read .{ null, -1, null };
            const himc = sys.ImmGetContext(surface_hwnd) orelse break :read .{ null, -1, null };
            defer _ = sys.ImmReleaseContext(surface_hwnd, himc);
            const units = readImeBuffer(u16, himc, alloc, c.GCS_COMPSTR, &units_stack) orelse
                break :read .{ null, -1, null };
            break :read .{
                units,
                // GCS_CURSORPOS comes back as the return value: UTF-16 units
                // before the caret, or negative when there is none.
                sys.ImmGetCompositionStringW(himc, c.GCS_CURSORPOS, null, 0),
                // One byte per unit; none (or a short read) only loses the
                // target clause.
                readImeBuffer(u8, himc, alloc, c.GCS_COMPATTR, &attrs_stack),
            };
        };
        defer if (attrs) |a| a.deinit(alloc);
        const units = read orelse {
            self.core_surface.preeditCallback(null) catch {};
            return;
        };
        defer units.deinit(alloc);

        // Update preedit display and reposition IME window
        var utf8_stack: [512]u8 = undefined;
        win32_input.applyImeComposition(
            KeyTarget{ .surface = self },
            alloc,
            units.items(),
            cursor,
            if (attrs) |a| a.items() else null,
            &utf8_stack,
        );
        self.positionImeWindow();
    }

    // Must route through formatFilePayload + surfaceDropPayloadCallback so paste protection applies.
    pub fn handleDropFiles(self: *Surface, wParam: WPARAM) void {
        // `WM_DROPFILES` transfers ownership of the `HDROP` to us on every
        // path, so claim it before any early return.
        const hDrop: *anyopaque = @ptrFromInt(wParam);
        defer sys.DragFinish(hDrop);

        if (!self.core_initialized) return;

        const alloc = self.app.core_app.alloc;
        const payload = win32_ole.extractHdrop(alloc, hDrop, .{}) catch |err| {
            log.warn("win32 drop files format failed err={}", .{err});
            return;
        };
        defer alloc.free(payload);
        if (payload.len == 0) return;

        surfaceDropPayloadCallback(self, payload);
    }

    pub fn handleMouseMove(self: *Surface, lParam: LPARAM, mods: input.Mods) void {
        if (!self.core_initialized) return;
        self.cursor_pos = cursorPosFromLParam(lParam);
        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("win32 cursor pos callback failed err={}", .{err});
        };
    }

    pub fn handleMouseLeave(self: *Surface) void {
        self.handleScrollbarMouseLeave();
        if (!self.core_initialized) return;
        // Captured drags keep reporting their real out-of-pane coordinates
        // for selection auto-scroll. The scrollbar child shares tracking.
        if (self.hwnd != null and sys.GetCapture() == self.hwnd) return;
        self.cursor_pos = .{ .x = -1, .y = -1 };
        self.core_surface.cursorPosCallback(self.cursor_pos, null) catch |err| {
            log.err("win32 cursor leave callback failed err={}", .{err});
        };
    }

    test "win32 pointer leave clears core link and renderer positions" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var mutex: std.Thread.Mutex = .{};
        var surface: Surface = .{ .app = undefined, .core_initialized = true };
        surface.core_surface.io.terminal = try terminal.Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 10 });
        defer surface.core_surface.io.terminal.deinit(std.testing.allocator);
        surface.core_surface.mouse = .{ .link_point = .{ .x = 4, .y = 4 } };
        surface.core_surface.renderer_state = .{
            .mutex = &mutex,
            .terminal = &surface.core_surface.io.terminal,
            .mouse = .{ .point = .{ .x = 4, .y = 4 } },
        };
        surface.core_surface.config.mouse_reporting = false;
        surface.core_surface.size = .{
            .screen = .{ .width = 100, .height = 100 },
            .cell = .{ .width = 10, .height = 10 },
            .padding = .{},
        };
        surface.core_surface.inspector = null;
        surface.core_surface.selection_scroll_active = false;
        surface.scrollbar_leave_armed = true;
        surface.handleMouseLeave();
        try std.testing.expect(!surface.scrollbar_leave_armed);
        try std.testing.expect(surface.core_surface.mouse.link_point == null);
        try std.testing.expect(surface.core_surface.renderer_state.mouse.point == null);
        try std.testing.expect(surface.core_surface.io.terminal.screens.active.dirty.hyperlink_hover);
        try std.testing.expectEqual(@as(f32, -1), surface.cursor_pos.x);
    }

    pub fn updateWheelCursorPos(self: *Surface, hwnd: HWND, lParam: LPARAM) void {
        // Wheel messages carry screen coordinates, including precision
        // pointer wheels. Updating only the cache avoids a spurious motion
        // report or hover/selection action before the wheel report.
        var point: POINT = .{
            .x = signedLowWord(lParamBits(lParam)),
            .y = signedHighWord(lParamBits(lParam)),
        };
        if (sys.ScreenToClient(hwnd, &point) == 0) return;
        self.cursor_pos = .{ .x = @floatFromInt(point.x), .y = @floatFromInt(point.y) };
    }

    test "win32 wheel position uses signed screen coordinates without mouse motion" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        // An unshown stock window needs no Surface/core setup and cannot
        // touch the clipboard. Use a negative origin to catch unsigned words.
        const hwnd = sys.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            0,
            -300,
            -200,
            500,
            400,
            null,
            null,
            sys.GetModuleHandleW(null),
            null,
        ) orelse return error.CreateWindowFailed;
        defer _ = sys.DestroyWindow(hwnd);
        var surface: Surface = .{ .app = undefined };
        var point: POINT = .{ .x = 40, .y = 60 };
        try std.testing.expect(sys.ClientToScreen(hwnd, &point) != 0);
        const bits: u32 = @as(u32, @as(u16, @bitCast(@as(i16, @intCast(point.x))))) |
            (@as(u32, @as(u16, @bitCast(@as(i16, @intCast(point.y))))) << 16);
        surface.updateWheelCursorPos(hwnd, @intCast(bits));
        try std.testing.expectEqual(@as(f32, 40), surface.cursor_pos.x);
        try std.testing.expectEqual(@as(f32, 60), surface.cursor_pos.y);
        try std.testing.expect(!surface.scrollbar_leave_armed);
    }

    pub fn handleMouseButton(self: *Surface, msg: UINT, wParam: WPARAM, lParam: LPARAM) bool {
        if (!self.core_initialized) return true;

        const button = mouseButtonFromMessage(msg) orelse return true;
        const state = mouseButtonStateFromMessage(msg) orelse return true;
        const mods = mouseModsFromWParam(wParam);

        self.cursor_pos = cursorPosFromLParam(lParam);
        if (state == .press) {
            self.noteProgramInput();
            // The pointer is driving again; the next chrome control to
            // take focus programmatically should not wear a ring.
            if (self.host) |host| host.noteChromePointerInput();
            if (self.hwnd) |hwnd| {
                _ = sys.SetFocus(hwnd);
                _ = sys.SetCapture(hwnd);
            }
        } else {
            _ = sys.ReleaseCapture();
        }

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("win32 cursor pos callback failed before button err={}", .{err});
        };
        return self.core_surface.mouseButtonCallback(state, button, mods) catch |err| {
            log.err("win32 mouse button callback failed err={} button={} state={}", .{
                err,
                button,
                state,
            });
            return true;
        };
    }

    pub fn handleXMouseButton(self: *Surface, msg: UINT, wParam: WPARAM, lParam: LPARAM) void {
        if (!self.core_initialized) return;

        const button = win32_input.xMouseButton(wParam) orelse return;
        const state: input.MouseButtonState = switch (msg) {
            c.WM_XBUTTONDOWN => .press,
            c.WM_XBUTTONUP => .release,
            else => return,
        };
        const mods = mouseModsFromWParam(wParam);

        self.cursor_pos = cursorPosFromLParam(lParam);
        if (state == .press) {
            self.noteProgramInput();
            if (self.hwnd) |h| {
                _ = sys.SetFocus(h);
                _ = sys.SetCapture(h);
            }
        } else {
            _ = sys.ReleaseCapture();
        }

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("win32 cursor pos callback failed before xbutton err={}", .{err});
        };
        _ = self.core_surface.mouseButtonCallback(state, button, mods) catch |err| {
            log.err("win32 xbutton callback failed err={} button={} state={}", .{ err, button, state });
        };
    }

    pub fn wheelNormalizationContext(self: *const Surface) WheelNormalizationContext {
        return .{
            .settings = self.app.wheel_settings,
            .cell_size = self.cell_size_pixels,
            .viewport = self.size,
        };
    }

    pub fn handleMouseWheel(self: *Surface, scroll: NormalizedWheelScroll) void {
        if (!self.core_initialized) return;
        self.noteProgramInput();
        if (self.scrollbarScrollable()) {
            const now_ms = sys.GetTickCount64();
            self.noteScrollbarActivity(now_ms);
            self.syncScrollbarWindowNow(now_ms) catch |err| {
                log.warn("win32 scrollbar wheel refresh failed err={}", .{err});
            };
        }
        self.core_surface.scrollCallback(scroll.xoff, scroll.yoff, scroll.mods) catch |err| {
            log.err("win32 scroll callback failed err={} xoff={} yoff={} mods={}", .{
                err,
                scroll.xoff,
                scroll.yoff,
                scroll.mods,
            });
        };
    }

    pub fn destroy(self: *Surface) void {
        const alloc = self.app.core_app.alloc;
        const own_hwnd = self.hwnd;
        self.noteBenchmarkMemoryStage(.destroy_begin, null);
        self.destroy_on_wm_destroy = false;
        self.deferred_char.clear();
        self.closeQuickSelect(false);

        if (self.terminal_accessibility) |session| {
            self.core_surface.setTerminalOutputInterested(false);
            self.terminal_accessibility = null;
            session.deinit();
        }

        // Revoke the drop target BEFORE destroying the HWND — Ole
        // would otherwise hold a dangling HWND reference until the
        // process exits. Idempotent on already-revoked targets.
        if (self.drop_target) |target| {
            self.drop_target = null;
            target.detach();
            if (self.drop_target_registered) {
                if (self.hwnd) |hwnd| target.revoke(hwnd);
                self.drop_target_registered = false;
            }
            target.deinit();
        }

        self.deinitCore();
        self.noteBenchmarkMemoryStage(.core_deinit_complete, null);

        // Drain the undo stack. Entries own scrollback / title bytes
        // allocated via `app.core_app.alloc`; `deinit` frees each.
        self.undo_stack.deinit();
        self.program_status.deinit(self.app.core_app.alloc);
        self.destroyScrollbarWindow();
        self.destroySearchBarControls();
        // Drain the search state's query, needle and match rows.
        self.docked_search.deinit();
        // Tear down any confirm overlay whose userdata points at
        // this Surface BEFORE we drain our own pending state. If we
        // skipped this, a user click on Accept / Cancel after the
        // Surface is freed would fire
        // `surfaceConfirmPasteAccept(&freed_surface)` → UAF. Hiding
        // the overlay here clears the Host's `confirm_payload`
        // entirely, so no later dispatch is possible.
        if (self.host) |host| host.cancelConfirmIfOwnedBy(@ptrCast(self));
        // Drop any pending clipboard-confirm op so a close-while-
        // pending doesn't leak the duplicated payload bytes.
        if (self.pending_clipboard_op) |*op| op.deinit(self.app.core_app.alloc);
        self.pending_clipboard_op = null;
        if (self.takePendingLinkOpen()) |link| self.app.core_app.alloc.free(link);
        self.render_trace.deinit(alloc);

        self.destroyGL();
        self.freeOwnedStrings();

        // App-level detachment is still per-pane teardown: `windowDestroyed`
        // removes this surface from `App.windows`, discards the structural
        // history entries referencing it, deinitializes the owning tab and
        // its split tree when this was the tab's last pane, drops any
        // prepared close tree, and reconciles pending shell state. Sampling
        // before that draws the private-memory boundary in the wrong place
        // and misattributes those still-held bytes to allocator or driver
        // behaviour.
        //
        // Safe to sample afterwards: `windowDestroyed` reads `self`
        // throughout but never frees it — `alloc.destroy(self)` below is the
        // sole owner-side free, so `self` and its trace are necessarily live
        // when the call returns.
        self.app.windowDestroyed(self);

        // The final stage, then the trace itself. `MemoryStageTrace.deinit`
        // clears `path`, after which `note` is a no-op — so this must stay
        // the last thing before the Surface is freed, and in particular
        // after `destroyGL` emits its teardown stages.
        //
        // The Surface and memory-stage trace path are both still live here
        // and are freed immediately below. Both predate `surface_begin`, so
        // stage deltas cancel them; the external pane-memory metric still
        // includes one trace-path allocation per traced surface.
        self.noteBenchmarkMemoryStage(.surface_destroy_complete, null);
        self.memory_stage_trace.deinit(alloc);
        // DestroyWindow still has messages to send after WM_DESTROY: a pane
        // that kept the keyboard focus gets its WM_KILLFOCUS only then, once
        // focus leaves the dying window. Those must not find this Surface.
        if (own_hwnd) |handle| setWindowData(handle, null);
        alloc.destroy(self);
    }

    /// Frees the strings this Surface owns. `init` calls it too when it fails,
    /// since the core can set some of them, such as the title, as it starts.
    fn freeOwnedStrings(self: *Surface) void {
        const alloc = self.app.core_app.alloc;
        if (self.title) |title| {
            alloc.free(title);
            self.title = null;
        }
        if (self.title_override) |value| {
            alloc.free(value);
            self.title_override = null;
        }
        if (self.tab_title_override) |value| {
            alloc.free(value);
            self.tab_title_override = null;
        }
        if (self.launch_profile_key) |value| {
            alloc.free(value);
            self.launch_profile_key = null;
        }
        if (self.launch_command) |*command| {
            command.deinit(alloc);
            self.launch_command = null;
        }
        if (self.launch_user) |*launch| {
            launch.deinit(alloc);
            self.launch_user = null;
        }
        if (self.key_table_name) |value| {
            alloc.free(value);
            self.key_table_name = null;
        }
        if (self.pwd) |value| {
            alloc.free(value);
            self.pwd = null;
        }
    }

    /// Joins the core's renderer and IO threads, so the GL context and window
    /// they use must still be alive.
    fn deinitCore(self: *Surface) void {
        if (!self.core_initialized) return;
        if (self.inspector_visible) {
            self.core_surface.deactivateInspector();
            self.inspector_visible = false;
        }
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
        self.core_initialized = false;
    }

    pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) void {
        self.mouse_shape = shape;
        _ = self.applyCursor();
    }

    pub fn setMouseVisibility(self: *Surface, visibility: apprt.action.MouseVisibility) void {
        self.mouse_visible = visibility == .visible;
        _ = self.applyCursor();
    }

    pub fn setVisible(self: *Surface, visible: bool) void {
        const visibility_changed = self.window_visible != visible;
        self.window_visible = visible;
        if (!visible) {
            self.deferred_char.clear();
            // A quick-select child cannot exist before the surface HWND.
            // Some structural tests deliberately use partial, HWND-less
            // surfaces, so do not inspect overlay state in that case.
            if (self.hwnd != null) self.closeQuickSelect(false);
        }

        const hwnd = self.hwnd orelse return;
        if (visible) self.syncContentScaleToHostDpi();
        const child_visibility_changed = applyChildVisibility(hwnd, &self.placement, visible);
        if (visibility_changed or child_visibility_changed) {
            self.refreshScrollbarWindow() catch |err| {
                log.warn("win32 scrollbar visibility refresh failed err={}", .{err});
            };
        }

        self.syncOcclusion();
    }

    /// Hidden tabs, zoomed panes and undo-retained surfaces catch up when
    /// shown, independently of layouts already completed by other panes.
    pub fn syncContentScaleToHostDpi(self: *Surface) void {
        // During a DPI change only `applyDpiChange` puts the font in, inside
        // the core's resize batch; a layout running in between would change
        // it outside the batch and send the old pixel size in the new cells.
        if (self.host) |host| if (host.dpi_change_pending) return;
        self.syncContentScaleToHostDpiNow();
    }

    pub fn syncContentScaleToHostDpiNow(self: *Surface) void {
        self.syncContentScaleToHostDpiWith(
            &self.core_surface,
            CoreSurface.contentScaleCallback,
        ) catch |err| {
            log.err("win32 content scale callback failed err={}", .{err});
        };
    }

    pub fn syncContentScaleToHostDpiWith(
        self: *Surface,
        callback_ctx: anytype,
        comptime callback: anytype,
    ) !void {
        const host = self.host orelse return;
        if (!self.window_visible or !host.surfaces_visible) return;
        const scale: f32 = @as(f32, @floatFromInt(host.current_dpi)) / 96.0;
        const next: apprt.ContentScale = .{ .x = scale, .y = scale };
        if (self.content_scale.x == next.x and self.content_scale.y == next.y) return;

        const previous = self.content_scale;
        self.content_scale = next;
        // Keep this surface eligible for retry on its next layout.
        errdefer self.content_scale = previous;
        if (self.core_initialized) {
            try callback(callback_ctx, next);
        }
    }

    pub fn syncOcclusion(self: *Surface) void {
        // Restoring a minimized or hidden host can make a pane visible
        // without changing the child's visibility or placement. Reconcile
        // its scale before waking the renderer, even in that path.
        if (self.hwnd != null) self.syncContentScaleToHostDpi();
        if (!self.core_initialized) return;
        const visible = self.window_visible and
            (if (self.host) |host| host.surfaces_visible else true);
        if (!shouldDispatchOcclusion(self.occlusion_visible, visible)) return;
        self.occlusion_visible = visible;
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("win32 occlusion callback failed err={} visible={}", .{ err, visible });
        };
    }

    pub fn setPwd(self: *Surface, pwd: []const u8) !void {
        if (ownedStringEquals(self.pwd, pwd)) return;
        const alloc = self.app.core_app.alloc;
        try appendOwnedString(alloc, &self.pwd, pwd);
    }

    pub fn setSecureInput(self: *Surface, value: apprt.action.SecureInput) !void {
        const next = switch (value) {
            .on => true,
            .off => false,
            .toggle => !self.secure_input,
        };
        if (next) self.secure_input_ever_engaged = true;
        if (self.secure_input == next) return;
        self.secure_input = next;
    }

    pub fn setKeySequenceActive(self: *Surface, active: bool) !void {
        if (self.key_sequence_active == active) return;
        self.key_sequence_active = active;
        self.key_sequence_since_ms = if (active) sys.GetTickCount64() else null;
        if (self.host) |host| try host.refreshModeIndicator();
    }

    pub fn setKeyTable(self: *Surface, value: apprt.action.KeyTable) !void {
        const next_name = switch (value) {
            .activate => |name| name,
            .deactivate => if (self.core_initialized) self.core_surface.activeKeyTableName() else null,
            .deactivate_all => null,
        };
        const alloc = self.app.core_app.alloc;
        try appendOwnedString(alloc, &self.key_table_name, next_name);
        self.key_table_copy_mode = copy_mode: {
            if (self.core_initialized) break :copy_mode self.core_surface.copy_mode_active;
            const name = next_name orelse break :copy_mode false;
            break :copy_mode std.mem.eql(u8, name, "copy_mode");
        };
        if (self.host) |host| try host.refreshModeIndicator();
    }

    test "chrome input mode banner follows key table enter and exit" {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host }},
            .surfaces = &.{.{ .storage = &surface, .host = &host }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();
        try surface.setKeyTable(.{ .activate = "resize" });
        try std.testing.expect(host.bannerShown());
        var buf: [256]u8 = undefined;
        try std.testing.expectEqualStrings("KEY TABLE: resize", Host.bannerUiaName(@ptrCast(&host), 0, &buf));
        try surface.setKeyTable(.deactivate_all);
        try std.testing.expect(!host.bannerShown());
        try surface.setKeyTable(.{ .activate = "copy_mode" });
        try std.testing.expect(host.bannerShown());
        try std.testing.expectEqualStrings("COPY MODE", Host.bannerUiaName(@ptrCast(&host), 0, &buf));
        try surface.setKeyTable(.deactivate);
        try std.testing.expect(!host.bannerShown());
    }

    pub fn setSearchActive(self: *Surface, active: bool, needle: []const u8) !void {
        const alloc = self.app.core_app.alloc;
        self.docked_search.active = active;
        self.docked_search.core_total = null;
        self.docked_search.selected_raw = null;
        self.docked_search.core_selected = null;
        self.docked_search.total = null;
        self.docked_search.selected = null;
        self.docked_search.invalid = false;
        if (!active) {
            self.docked_search.searched = self.docked_search.query.len == 0;
            self.docked_search.last_edit_ms = 0;
        } else if (needle.len > 0 and !std.mem.eql(u8, self.docked_search.query, needle)) {
            try self.docked_search.setQuery(needle, 0);
            self.docked_search.searched = true;
            self.docked_search.last_edit_ms = 0;
        }
        if (self.docked_search.match_rows.len > 0) {
            alloc.free(self.docked_search.match_rows);
            self.docked_search.match_rows = &.{};
        }
        self.clearScrollbarMarkers();
        if (active and needle.len > 0) {
            try appendOwnedString(alloc, &self.docked_search.needle, needle);
        } else if (!active) {
            try appendOwnedString(alloc, &self.docked_search.needle, null);
        }
        _ = try self.syncSearchBarResultsText();
        try self.refreshScrollbarWindow();
    }

    pub fn setSearchTotal(self: *Surface, total: ?usize, invalid: bool) !void {
        if (!shouldAcceptCoreSearchUpdates(&self.docked_search)) return;
        const selected = searchSelectedDisplayFromRaw(self.docked_search.selected_raw, total);
        const searched = searchBarSearchedStateForTotal(total);
        if (self.docked_search.core_total == total and
            self.docked_search.core_selected == selected and
            self.docked_search.invalid == invalid and
            !searchBarDisplayStateChanged(&self.docked_search, searched, total, selected))
        {
            return;
        }
        self.docked_search.core_total = total;
        self.docked_search.searched = searched;
        self.docked_search.total = total;
        self.docked_search.invalid = invalid;
        self.docked_search.core_selected = selected;
        self.docked_search.selected = selected;
        _ = try self.syncSearchBarResultsText();
    }

    pub fn setSearchSelected(self: *Surface, selected: ?usize) !void {
        if (!shouldAcceptCoreSearchUpdates(&self.docked_search)) return;
        const raw = searchSelectedRawFromCoreDisplay(selected);
        const display = searchSelectedDisplayFromRaw(raw, self.docked_search.core_total);
        const searched = searchBarSearchedStateForSelected(display, self.docked_search.core_total);
        if (self.docked_search.selected_raw == raw and
            self.docked_search.core_selected == display and
            !searchBarDisplayStateChanged(&self.docked_search, searched, self.docked_search.core_total, display))
        {
            return;
        }
        self.docked_search.selected_raw = raw;
        self.docked_search.core_selected = display;
        self.docked_search.searched = searched;
        self.docked_search.selected = display;
        _ = try self.syncSearchBarResultsText();
    }

    pub fn setSearchSelectedDisplay(self: *Surface, selected: ?usize) !void {
        const searched = searchBarSearchedStateForSelected(selected, self.docked_search.core_total);
        if (self.docked_search.core_selected == selected and
            !searchBarDisplayStateChanged(&self.docked_search, searched, self.docked_search.core_total, selected))
        {
            return;
        }
        self.docked_search.core_selected = selected;
        self.docked_search.searched = searched;
        self.docked_search.selected = selected;
        _ = try self.syncSearchBarResultsText();
    }

    pub fn setSearchMatchRows(self: *Surface, rows: []const u32) !void {
        if (!shouldAcceptCoreSearchUpdates(&self.docked_search)) return;
        if (std.mem.eql(u32, self.docked_search.match_rows, rows)) return;

        const alloc = self.app.core_app.alloc;
        if (self.docked_search.match_rows.len > 0) alloc.free(self.docked_search.match_rows);
        self.docked_search.match_rows = if (rows.len == 0)
            &.{}
        else
            try alloc.dupe(u32, rows);
        self.clearScrollbarMarkers();
        try self.refreshScrollbarWindow();
    }

    pub fn setScrollbar(self: *Surface, value: terminal.Scrollbar) !void {
        if (self.scrollbar.eql(value)) return;
        const old = self.scrollbar;
        const offset_changed = self.scrollbar.offset != value.offset;
        self.scrollbar = value;
        if (self.scrollbar_uia_provider) |provider| {
            provider.raiseRangeChanged(
                scrollbarUiaRangeValue(old),
                scrollbarUiaRangeValue(value),
            );
        }
        if (old.total != value.total or old.len != value.len) {
            self.clearScrollbarMarkers();
        }
        if (!self.scrollbarScrollable()) {
            self.scrollbar_state = .{};
        } else {
            const now_ms = sys.GetTickCount64();
            switch (self.scrollbarPolicy()) {
                .always => self.scrollbar_state.visibility = .visible,
                .dynamic => if (offset_changed) self.noteScrollbarActivity(now_ms),
                .never => {},
            }
        }
        try self.refreshScrollbarWindow();
    }

    pub fn setProgressReport(self: *Surface, value: terminal.osc.Command.ProgressReport) !void {
        self.taskbar_progress = if (value.state == .remove) null else value;
        self.app.syncTaskbarProgressForHost(self.host_id);
    }

    /// What the taskbar shows while this surface is its window's active
    /// one. Once a program has reported status (OSC 7501) since the last
    /// full reset, that is the root record, and OSC 9;4 no longer applies;
    /// `progress-style = false` turns the record's progress bar off like
    /// it does 9;4's.
    pub fn effectiveTaskbarProgress(self: *const Surface) ?win32_taskbar_progress.ProgressReport {
        if (!self.program_status.reported) return self.taskbar_progress;
        if (!self.core_surface.config.progress_style) return null;
        return win32_program_status.taskbarReport(self.program_status.root());
    }

    pub fn applyCursor(self: *Surface) bool {
        if (!self.mouse_visible) {
            _ = sys.SetCursor(null);
            return true;
        }

        const cursor_name: INTRESOURCE = switch (self.mouse_shape) {
            .default => c.IDC_ARROW,
            .help => @as(INTRESOURCE, @ptrFromInt(32651)),
            .pointer, .grab, .grabbing => @as(INTRESOURCE, @ptrFromInt(32649)),
            .progress => @as(INTRESOURCE, @ptrFromInt(32650)),
            .wait => @as(INTRESOURCE, @ptrFromInt(32514)),
            .crosshair => @as(INTRESOURCE, @ptrFromInt(32515)),
            .text, .vertical_text, .cell => @as(INTRESOURCE, @ptrFromInt(32513)),
            .move, .all_scroll => @as(INTRESOURCE, @ptrFromInt(32646)),
            .not_allowed, .no_drop => @as(INTRESOURCE, @ptrFromInt(32648)),
            .col_resize, .ew_resize, .e_resize, .w_resize => @as(INTRESOURCE, @ptrFromInt(32644)),
            .row_resize, .ns_resize, .n_resize, .s_resize => @as(INTRESOURCE, @ptrFromInt(32645)),
            .ne_resize, .sw_resize, .nesw_resize => @as(INTRESOURCE, @ptrFromInt(32643)),
            .nw_resize, .se_resize, .nwse_resize => @as(INTRESOURCE, @ptrFromInt(32642)),
            .context_menu,
            .alias,
            .copy,
            .zoom_in,
            .zoom_out,
            => c.IDC_ARROW,
        };

        _ = sys.SetCursor(sys.LoadCursorW(null, cursor_name));
        return true;
    }

    /// Queue a deferred clipboard-paste confirm. Dupes `data` into
    /// surface-owned storage, parks it as a `PendingClipboardOp.paste`,
    /// and shows the non-modal `HostOverlayMode.confirm` overlay. On
    /// accept `surfaceConfirmPasteAccept` completes the paste; on
    /// cancel `surfaceConfirmPasteCancel` frees the payload and, only for
    /// an explicit OSC 52 read cancellation, sends an empty response.
    ///
    /// Queues a non-modal clipboard confirmation.
    pub fn requestPasteConfirm(
        self: *Surface,
        request: apprt.ClipboardRequest,
        data: []const u8,
    ) !void {
        const host = self.host orelse return error.NoHost;
        const alloc = self.app.core_app.alloc;
        // The user's own paste (a keybinding, a drop, a quick-select
        // paste) or a program's OSC 52 read.
        const program_request = request == .osc_52_read;
        if (program_request) try self.declineProgramRequest();

        // Defensive: clear any leftover op before queuing a new one so
        // the destructor can't see a mixed state.
        if (self.pending_clipboard_op) |*old| old.deinit(alloc);
        self.pending_clipboard_op = null;

        const data_copy = try alloc.dupeZ(u8, data);
        // Single errdefer — if showConfirm fails we free the buffer
        // and leave `pending_clipboard_op` untouched (still null from
        // the defensive clear above). Committing the op BEFORE
        // showConfirm would produce a double-free if the operation
        // committed successfully and a later setup step failed.
        errdefer alloc.free(data_copy);

        const program_body = if (program_request) try self.programClipboardPromptBody(.read) else null;
        defer if (program_body) |body| alloc.free(body);
        try host.showConfirm(
            .{
                .title = if (program_request) labels.programClipboardPromptTitle(.read) else "Allow clipboard paste?",
                .body = program_body orelse "noctty needs confirmation before completing this clipboard paste.",
                .accept_label = "Allow",
                .cancel_label = "Cancel",
                // Preview the exact bytes the gate stopped. `data_copy`
                // is what Accept delivers; the preview is built from the
                // same bytes and capped for display only.
                .contents = data,
                .program_request = program_request,
            },
            surfaceConfirmPasteAccept,
            surfaceConfirmPasteCancel,
            self,
        );

        // showConfirm succeeded — the callback is registered and
        // fires async on user action (Enter / Esc / click), never
        // synchronously inside this call. Commit the pending op now
        // so the callback can pick it up.
        self.pending_clipboard_op = .{ .paste = .{
            .request = request,
            .data = data_copy,
        } };
    }

    /// Queue a deferred clipboard-write confirm. Dupes every
    /// `ClipboardContent` entry (mime + data both sentinel-terminated)
    /// into surface-owned storage. Same accept / cancel discipline as
    /// `requestPasteConfirm`.
    pub fn requestWriteConfirm(
        self: *Surface,
        clipboard: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
    ) !void {
        const host = self.host orelse return error.NoHost;
        const alloc = self.app.core_app.alloc;
        // Only a program's OSC 52 write asks first (`clipboard-write = ask`).
        try self.declineProgramRequest();

        if (self.pending_clipboard_op) |*old| old.deinit(alloc);
        self.pending_clipboard_op = null;

        const owned = try alloc.alloc(OwnedClipboardContent, contents.len);
        var filled: usize = 0;
        // Outer errdefer frees committed entries plus the backing slice.
        // Per-iteration errdefer covers the mime-only partial allocation
        // before `filled` advances.
        errdefer {
            var i: usize = 0;
            while (i < filled) : (i += 1) {
                alloc.free(owned[i].mime);
                alloc.free(owned[i].data);
            }
            alloc.free(owned);
        }
        for (contents) |content| {
            const mime_copy = try alloc.dupeZ(u8, content.mime);
            errdefer alloc.free(mime_copy);
            const data_copy = try alloc.dupeZ(u8, content.data);
            // Both dupes succeeded — commit atomically into owned[]
            // and advance filled. The per-iter mime errdefer goes
            // out of scope without firing.
            owned[filled] = .{ .mime = mime_copy, .data = data_copy };
            filled += 1;
        }

        // Preview the plain-text representation when the application
        // offered one, since that is what a later paste produces.
        // Otherwise fall back to the first representation so an
        // HTML-only or unknown-mime write is not approved blind.
        //
        // Today the only caller that reaches this confirm is the OSC 52
        // write path, which always sends exactly one `text/plain`
        // entry, so the previewed representation is the only one Accept
        // writes. The selection-copy path that pairs `text/html` with
        // `text/plain` never asks for confirmation. If a confirmed
        // multi-representation write is ever introduced, extend the
        // preview to show every representation rather than one.
        const preview_contents: ?[]const u8 = preview: {
            if (contents.len == 0) break :preview null;
            for (contents) |content| {
                if (std.mem.eql(u8, content.mime, "text/plain")) break :preview content.data;
            }
            break :preview contents[0].data;
        };

        const body = try self.programClipboardPromptBody(.write);
        defer alloc.free(body);
        try host.showConfirm(
            .{
                .title = labels.programClipboardPromptTitle(.write),
                .body = body,
                .accept_label = "Allow",
                .cancel_label = "Cancel",
                .contents = preview_contents,
                .program_request = true,
            },
            surfaceConfirmWriteAccept,
            surfaceConfirmWriteCancel,
            self,
        );

        // showConfirm succeeded — commit the pending op. The async
        // accept callback picks it up; same race-free rationale as
        // `requestPasteConfirm` (showConfirm does not invoke
        // callbacks synchronously).
        self.pending_clipboard_op = .{ .write = .{
            .clipboard = clipboard,
            .contents = owned,
        } };
    }

    /// A program's clipboard request that gets no prompt. It never
    /// replaces a prompt that is waiting for an answer: that hid the
    /// user's own paste or close prompt, or another pane's, behind one the
    /// program chose the moment of. And a terminal in no tab (one kept
    /// alive for close-tab undo still runs) has no tab the prompt could
    /// name. Checked before the requester touches its pending op, which
    /// may be what the open prompt delivers.
    fn declineProgramRequest(self: *Surface) !void {
        const host = self.host orelse return error.NoHost;
        if (host.overlay_mode == .confirm) return error.ConfirmPromptOpen;
        // Nor the palette, search or a rename the user is typing in.
        if (host.overlay_mode != .none) return error.OverlayOpen;
        if (Host.findTabForSurface(self) == null) return error.NotInATab;
    }

    fn programClipboardPromptBody(self: *Surface, request: labels.ProgramClipboardRequest) ![]u8 {
        return labels.buildProgramClipboardPromptBody(
            self.app.core_app.alloc,
            request,
            self.app.hostTabStatus(self).index + 1,
            self.effectiveTitle(),
        );
    }

    /// Keeps `link` (owned on the App allocator) for this pane's link
    /// prompt, freeing the one an earlier prompt left.
    pub fn setPendingLinkOpen(self: *Surface, link: []u8) void {
        if (self.takePendingLinkOpen()) |old| self.app.core_app.alloc.free(old);
        self.pending_link_open = link;
    }

    /// The link this pane's prompt was asking about, now the caller's to
    /// free, or null when no prompt holds one.
    pub fn takePendingLinkOpen(self: *Surface) ?[]u8 {
        const link = self.pending_link_open orelse return null;
        self.pending_link_open = null;
        return link;
    }

    /// What the clipboard holds: its text, else (for `include_files`) the
    /// paths of copied files, else nothing. An open failure is an error, never
    /// an empty clipboard.
    fn readClipboard(self: *Surface, include_files: bool) !ClipboardContents {
        if (!openClipboard(self.hwnd)) return lastError();
        defer _ = sys.CloseClipboard();

        return try selectClipboardContents(self.app.core_app.alloc, include_files, system_clipboard);
    }

    /// The open system clipboard, for `selectClipboardContents`.
    const system_clipboard: ClipboardSource = .{
        .text = &readOpenClipboardText,
        .hdrop = &readOpenClipboardHdrop,
    };

    fn readOpenClipboardHdrop() ?*anyopaque {
        if (sys.IsClipboardFormatAvailable(c.CF_HDROP) == 0) return null;
        // The clipboard owns this HDROP: borrow it, never `DragFinish` it.
        return sys.GetClipboardData(c.CF_HDROP);
    }

    fn readOpenClipboardText(alloc: std.mem.Allocator) anyerror!?[:0]u8 {
        if (sys.IsClipboardFormatAvailable(c.CF_UNICODETEXT) == 0) return null;

        const handle = sys.GetClipboardData(c.CF_UNICODETEXT) orelse return null;
        const locked = sys.GlobalLock(handle) orelse return null;
        defer _ = sys.GlobalUnlock(handle);

        const text_w: [*:0]const u16 = @ptrCast(@alignCast(locked));
        const slice_w = std.mem.sliceTo(text_w, 0);
        return try lfLineEndings(alloc, try clipboardTextToUtf8(alloc, slice_w));
    }

    /// `text` as CF_UNICODETEXT holds it: UTF-16 with CRLF line endings.
    fn clipboardTextUtf16(alloc: std.mem.Allocator, text: []const u8) ![:0]u16 {
        const crlf = try crlfLineEndings(alloc, text);
        defer if (crlf) |owned| alloc.free(owned);
        return std.unicode.utf8ToUtf16LeAllocZ(alloc, crlf orelse text);
    }

    pub fn writeClipboardText(self: *const Surface, text: []const u8) !void {
        writeClipboardTextWith(.{}, self.app.core_app.alloc, self.hwnd, text) catch |err| switch (err) {
            // A Win32 failure is reported as `lastError()`, as it always was.
            error.GlobalMemoryUnavailable, error.ClipboardUnavailable => return lastError(),
            else => |other| return other,
        };
    }

    /// `writeClipboardText` through `ops`, so a test can fail each native call
    /// without reaching the real clipboard. The text is made ready before the
    /// clipboard is opened and emptied (`clipboard_write.write`), so memory
    /// that cannot be had no longer wipes what the clipboard held.
    fn writeClipboardTextWith(ops: clipboard_write.Ops, alloc: std.mem.Allocator, owner: ?HWND, text: []const u8) !void {
        const text_w = try clipboardTextUtf16(alloc, text);
        defer alloc.free(text_w);
        try clipboard_write.write(ops, owner, &.{clipboard_write.unicodeText(text_w)});
    }

    /// Write both CF_HTML (styled fragment) and CF_UNICODETEXT
    /// (plain fallback) in a single clipboard cycle. CF_HTML
    /// consumers (Word / WordPad / OneNote) read the styled
    /// payload; plain-text consumers (Notepad / cmd / Terminal
    /// without HTML support) read the fallback.
    ///
    /// If `plain` is provided (core passes both `text/html` and
    /// `text/plain` when the action is, say, `copy_on_select`), we
    /// use it verbatim. Otherwise (e.g. explicit
    /// `copy_to_clipboard:html` which only provides `text/html`),
    /// we synthesize a plain fallback by stripping HTML tags so
    /// Notepad etc. get readable text instead of raw markup.
    pub fn writeClipboardHtml(self: *const Surface, html: []const u8, plain: ?[]const u8) !void {
        const cf_html = win32_ole.htmlFormat();
        if (cf_html == 0) return lastError();
        writeClipboardHtmlWith(.{}, self.app.core_app.alloc, self.hwnd, cf_html, html, plain) catch |err| switch (err) {
            error.GlobalMemoryUnavailable, error.ClipboardUnavailable => return lastError(),
            else => |other| return other,
        };
    }

    /// `writeClipboardHtml` through `ops`, with the CF_HTML format id already
    /// registered. Both formats are made ready before the clipboard is opened
    /// and emptied. A CF_UNICODETEXT that `SetClipboardData` refuses after
    /// CF_HTML was taken leaves the clipboard emptied and holding the HTML
    /// alone: no order avoids that, so the call reports the failure and frees
    /// the memory the clipboard did not take.
    fn writeClipboardHtmlWith(
        ops: clipboard_write.Ops,
        alloc: std.mem.Allocator,
        owner: ?HWND,
        cf_html: UINT,
        html: []const u8,
        plain: ?[]const u8,
    ) !void {
        const wrapped = try win32_clipboard_html.wrapFragment(alloc, html);
        defer alloc.free(wrapped);

        // Pick the plain-text payload. Caller-supplied wins; else
        // derive a readable approximation from the HTML by walking
        // through the bytes and dropping anything between `<` and
        // `>`. Allocation lifetime: the stripped copy is owned by
        // `alloc`; the caller-supplied slice is borrowed and we
        // don't free it. `plain_owned_for_free` tracks ownership.
        var plain_owned_for_free: ?[]u8 = null;
        defer if (plain_owned_for_free) |owned| alloc.free(owned);
        const plain_src: []const u8 = if (plain) |p| p else blk: {
            const stripped = try stripHtmlTags(alloc, html);
            plain_owned_for_free = stripped;
            break :blk stripped;
        };
        // CRLF for the plain fallback only: CF_HTML's header holds byte
        // offsets into the wrapped fragment.
        const plain_w = try clipboardTextUtf16(alloc, plain_src);
        defer alloc.free(plain_w);

        try clipboard_write.write(ops, owner, &.{
            .{ .id = cf_html, .data = wrapped, .nul_bytes = 1 },
            clipboard_write.unicodeText(plain_w),
        });
    }

    /// Release the surface's native GL resources. Also called when OpenGL
    /// failed for a surface that Direct3D 11 draws instead, so the failed
    /// context is not bound again for each frame (`redraw`).
    ///
    /// Each benchmark teardown stage is emitted only when the boundary it
    /// names actually holds. `Get-BenchMemoryStageSamples` validates stage
    /// presence alone, so emitting a stage whose native call failed would
    /// let a memory run report verified native teardown while the HGLRC or
    /// DC was never released. A missing stage fails the run closed, which is
    /// the intended outcome when cleanup did not happen.
    pub fn releaseGL(self: *Surface) void {
        if (self.hglrc) |hglrc| {
            if (self.clearGLContextCurrentChecked()) {
                self.noteBenchmarkMemoryStage(.wgl_context_unbound, null);
            }

            const deleted = sys.wglDeleteContext(hglrc) != 0;
            if (!deleted) {
                log.warn(
                    "win32 wglDeleteContext failed during surface teardown err={}",
                    .{windows.kernel32.GetLastError()},
                );
            }
            // Drop our reference either way. The Surface is freed moments
            // from now, so retaining a handle we failed to delete would only
            // strand it behind freed memory.
            self.hglrc = null;
            if (deleted) self.noteBenchmarkMemoryStage(.wgl_context_deleted, null);
        }

        if (self.hdc) |hdc| {
            // A private (CS_OWNDC) DC still reports success from ReleaseDC,
            // so requiring success does not weaken the normal path; it only
            // catches a release we never attempted or that genuinely failed.
            const released = if (self.hwnd) |hwnd| sys.ReleaseDC(hwnd, hdc) != 0 else false;
            if (!released) {
                log.warn(
                    "win32 ReleaseDC failed during surface teardown had_hwnd={} err={}",
                    .{ self.hwnd != null, windows.kernel32.GetLastError() },
                );
            }
            self.hdc = null;
            if (released) self.noteBenchmarkMemoryStage(.dc_released, null);
        }
        self.renderer_gl_prepared = false;
    }

    fn destroyGL(self: *Surface) void {
        self.releaseGL();
        self.hwnd = null;
    }
};

test "win32 a terminal text copy prepares its data before it empties the clipboard" {
    const Fake = clipboard_write.Fake;
    const alloc = std.testing.allocator;

    // Memory that cannot be had or locked: the clipboard is never opened, let
    // alone emptied, and what was allocated is freed.
    for ([_]Fake.Fail{ .alloc, .lock }) |how| {
        Fake.reset(how, 0);
        try std.testing.expectError(error.GlobalMemoryUnavailable, Surface.writeClipboardTextWith(Fake.ops, alloc, null, "a\nb"));
        try std.testing.expect(!Fake.did(.open) and !Fake.did(.empty) and !Fake.did(.set_data) and !Fake.did(.close));
        try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
        try std.testing.expectEqual(@as(usize, 0), Fake.taken());
    }

    // A clipboard that will not open, empty or take the text: the memory is
    // freed, and the clipboard closed only once it was opened.
    for ([_]Fake.Fail{ .open, .empty, .set_data }) |how| {
        Fake.reset(how, 0);
        try std.testing.expectError(error.ClipboardUnavailable, Surface.writeClipboardTextWith(Fake.ops, alloc, null, "a\nb"));
        try std.testing.expectEqual(how != .open, Fake.did(.close));
        try std.testing.expectEqual(how == .set_data, Fake.did(.set_data));
        try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
        try std.testing.expectEqual(@as(usize, 0), Fake.taken());
        try std.testing.expectEqual(@as(usize, 1), Fake.freed());
    }

    // A copy that works: the text is ready before the clipboard is opened,
    // with CRLF line endings, and the clipboard keeps the memory.
    const owner: HWND = @ptrFromInt(0x2000);
    Fake.reset(.none, 0);
    try Surface.writeClipboardTextWith(Fake.ops, alloc, owner, "a\nb");
    try std.testing.expectEqual(@as(?HWND, owner), Fake.openedFor());
    try std.testing.expectEqualSlices(Fake.Step, &.{ .alloc, .lock, .unlock, .open, .empty, .set_data, .close }, Fake.recorded());
    try std.testing.expectEqual(@as(usize, 1), Fake.taken());
    try std.testing.expectEqual(@as(usize, 0), Fake.leaked() + Fake.freed());
    try std.testing.expectEqual(@as(UINT, c.CF_UNICODETEXT), Fake.formatOf(0));
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb");
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected[0 .. expected.len + 1]), Fake.payload(0));
}

test "win32 a terminal html copy prepares both formats before it empties the clipboard" {
    const Fake = clipboard_write.Fake;
    const alloc = std.testing.allocator;
    const html = "<b>a</b>\nb";
    const cf_html: UINT = 0xC0A0;

    // Memory for either format that cannot be had or locked: the clipboard is
    // never opened, let alone emptied, and what was allocated is freed.
    for ([_]Fake.Fail{ .alloc, .lock }) |how| {
        for (0..2) |nth| {
            Fake.reset(how, nth);
            try std.testing.expectError(error.GlobalMemoryUnavailable, Surface.writeClipboardHtmlWith(Fake.ops, alloc, null, cf_html, html, null));
            try std.testing.expect(!Fake.did(.open) and !Fake.did(.empty) and !Fake.did(.set_data) and !Fake.did(.close));
            try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
            try std.testing.expectEqual(@as(usize, 0), Fake.taken());
        }
    }

    // A clipboard that will not open, empty or take CF_HTML: both blocks are
    // freed, and nothing was taken.
    for ([_]Fake.Fail{ .open, .empty, .set_data }) |how| {
        Fake.reset(how, 0);
        try std.testing.expectError(error.ClipboardUnavailable, Surface.writeClipboardHtmlWith(Fake.ops, alloc, null, cf_html, html, null));
        try std.testing.expectEqual(how != .open, Fake.did(.close));
        try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
        try std.testing.expectEqual(@as(usize, 0), Fake.taken());
        try std.testing.expectEqual(@as(usize, 2), Fake.freed());
    }

    // CF_HTML taken, CF_UNICODETEXT refused. The clipboard was already
    // emptied, so it holds the HTML alone and the old contents are gone: no
    // order avoids that. The call fails, and the block the clipboard did not
    // take is freed.
    Fake.reset(.set_data, 1);
    try std.testing.expectError(error.ClipboardUnavailable, Surface.writeClipboardHtmlWith(Fake.ops, alloc, null, cf_html, html, null));
    try std.testing.expect(Fake.did(.empty) and Fake.did(.close));
    try std.testing.expectEqual(@as(usize, 0), Fake.leaked());
    try std.testing.expectEqual(@as(usize, 1), Fake.taken());
    try std.testing.expectEqual(@as(usize, 1), Fake.freed());
    try std.testing.expectEqual(cf_html, Fake.formatOf(0));

    // Copies that work, with the plain text derived from the HTML and
    // supplied by the caller.
    const wrapped = try win32_clipboard_html.wrapFragment(alloc, html);
    defer alloc.free(wrapped);
    const owner: HWND = @ptrFromInt(0x2000);
    const Case = struct { plain: ?[]const u8, expected: [:0]const u16 };
    const cases = [_]Case{
        .{ .plain = null, .expected = std.unicode.utf8ToUtf16LeStringLiteral("a\r\nb") },
        .{ .plain = "x\ny", .expected = std.unicode.utf8ToUtf16LeStringLiteral("x\r\ny") },
    };
    for (cases) |case| {
        Fake.reset(.none, 0);
        try Surface.writeClipboardHtmlWith(Fake.ops, alloc, owner, cf_html, html, case.plain);
        try std.testing.expectEqual(@as(?HWND, owner), Fake.openedFor());
        try std.testing.expectEqualSlices(Fake.Step, &.{
            .alloc,    .lock,  .unlock,
            .alloc,    .lock,  .unlock,
            .open,     .empty, .set_data,
            .set_data, .close,
        }, Fake.recorded());
        try std.testing.expectEqual(@as(usize, 2), Fake.taken());
        try std.testing.expectEqual(@as(usize, 0), Fake.leaked() + Fake.freed());
        // CF_HTML: the wrapped fragment verbatim, offsets untouched by CRLF,
        // and a NUL.
        try std.testing.expectEqual(cf_html, Fake.formatOf(0));
        try std.testing.expectEqualSlices(u8, wrapped, Fake.payload(0)[0..wrapped.len]);
        try std.testing.expectEqual(@as(usize, wrapped.len + 1), Fake.payload(0).len);
        try std.testing.expectEqual(@as(u8, 0), Fake.payload(0)[wrapped.len]);
        // CF_UNICODETEXT: the plain fallback with CRLF.
        try std.testing.expectEqual(@as(UINT, c.CF_UNICODETEXT), Fake.formatOf(1));
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(case.expected[0 .. case.expected.len + 1]), Fake.payload(1));
    }
}

test "win32 scrollbar UIA range clamps value and exposes viewport bounds" {
    const range = Surface.scrollbarUiaRangeValue(.{
        .total = 100,
        .offset = 99,
        .len = 20,
    });
    try std.testing.expectEqual(@as(f64, 80), range.value);
    try std.testing.expectEqual(@as(f64, 80), range.maximum);
    try std.testing.expectEqual(@as(f64, 20), range.large_change);
    try std.testing.expectEqual(@as(f64, 1), range.small_change);
}

test "win32 a committed Restart Manager close keeps every window through WM_CLOSE and quits them from the message loop" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.running = true;
            app.recovery_ready_resolved = true;
            app.config.@"quit-after-last-window-closed" = false;
            try app.createWindow(default_title);
            const first = fixture.newest();
            try app.createWindow(default_title);
            const second = fixture.newest();

            // Nothing committed: the loop's step does nothing.
            try std.testing.expect(!try app.finishEndSessionClose());
            try std.testing.expectEqual(@as(usize, 2), app.registry.hosts.items.len);

            // Restart Manager's fallback WM_CLOSE closes nothing once the
            // close is committed: one window at a time would leave the
            // session with only the last.
            app.end_session_quit_pending = true;
            for ([_]*Surface{ first, second }) |surface| {
                try std.testing.expectEqual(@as(LRESULT, 0), sys.SendMessageW(surface.windowHwnd().?, c.WM_CLOSE, 0, 0));
            }
            try std.testing.expectEqual(@as(usize, 2), app.registry.hosts.items.len);
            try std.testing.expectEqual(@as(usize, 2), app.registry.windows.items.len);

            // The loop's step quits them all, though
            // quit-after-last-window-closed is off. The stand-in cores never
            // started, so `destroy` leaves them registered; the core's own
            // teardown would not.
            for (app.registry.windows.items) |surface| fixture.core_app.deleteSurface(surface);
            try std.testing.expect(try app.finishEndSessionClose());
            try std.testing.expect(!app.end_session_quit_pending);
            try std.testing.expect(!app.running);
            try std.testing.expectEqual(@as(usize, 0), app.registry.windows.items.len);
            try std.testing.expectEqual(@as(usize, 0), app.registry.hosts.items.len);
            var msg: MSG = undefined;
            try std.testing.expect(sys.PeekMessageW(&msg, null, c.WM_QUIT, c.WM_QUIT, c.PM_REMOVE) != 0);
        }
    }.body);
}

test "win32 a surface keeps its launch's line unless it is the first one and runs initial-command" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const cmd_argv = [_][:0]const u8{ "cmd.exe", "/k", "x" };
            const e_argv = [_][:0]const u8{"vim.exe"};
            app.config.command = .{ .direct = &cmd_argv };
            const launch: configpkg.pane_launch.Stamp = .{ .user = .{ .command_line = "cmd.exe /k x" } };

            // A profile launch keeps its line with the command, the first
            // surface or a later one.
            for ([_]bool{ true, false }) |first| {
                fixture.core_app.first = first;
                const surface = try app.createWindowSurface(&app.config, default_title, .{ .launch = launch });
                try std.testing.expectEqualStrings("cmd.exe", (surface.launch_command orelse return error.TestUnexpectedResult).direct[0]);
                try std.testing.expectEqualStrings("cmd.exe /k x", (surface.launch_user orelse return error.TestUnexpectedResult).command_line);
            }

            // `-e` runs on the first surface only, and is no profile's launch.
            app.config.@"initial-command" = .{ .direct = &e_argv };
            fixture.core_app.first = true;
            const first = try app.createWindowSurface(&app.config, default_title, .{ .launch = launch });
            try std.testing.expectEqualStrings("vim.exe", (first.launch_command orelse return error.TestUnexpectedResult).direct[0]);
            try std.testing.expect(first.launch_user == null);
            fixture.core_app.first = false;
            const later = try app.createWindowSurface(&app.config, default_title, .{ .launch = launch });
            try std.testing.expectEqualStrings("cmd.exe", (later.launch_command orelse return error.TestUnexpectedResult).direct[0]);
            try std.testing.expect(later.launch_user != null);
        }
    }.body);
}

test "win32 taskbar follows the program status root record once a program reports" {
    const alloc = std.testing.allocator;
    var surface: Surface = undefined;
    surface.taskbar_progress = .{ .state = .set, .progress = 30 };
    surface.program_status = .{};
    defer surface.program_status.deinit(alloc);
    surface.core_surface = undefined;
    surface.core_surface.config.progress_style = true;

    // Before any program status report, OSC 9;4 drives the taskbar.
    try std.testing.expectEqual(@as(?u8, 30), surface.effectiveTaskbarProgress().?.progress);

    var parser: terminal.osc.Parser = .init(alloc);
    defer parser.deinit();
    parser.nextSlice("7501;state=blocked:id=child");
    _ = try surface.program_status.apply(alloc, parser.end('\x1b').?.program_status.report);
    // From the first report on, the stale 9;4 no longer shows, even while
    // the root record is empty.
    try std.testing.expect(surface.effectiveTaskbarProgress() == null);

    parser.reset();
    parser.nextSlice("7501;state=blocked:progress=60");
    _ = try surface.program_status.apply(alloc, parser.end('\x1b').?.program_status.report);
    const blocked = surface.effectiveTaskbarProgress().?;
    try std.testing.expectEqual(win32_taskbar_progress.ProgressState.pause, blocked.state);
    try std.testing.expectEqual(@as(?u8, 60), blocked.progress);

    // `progress-style = false` hides it, as it hides 9;4.
    surface.core_surface.config.progress_style = false;
    try std.testing.expect(surface.effectiveTaskbarProgress() == null);
    surface.core_surface.config.progress_style = true;

    // A full reset hands the taskbar back to OSC 9;4.
    surface.program_status.reset(alloc);
    try std.testing.expectEqual(@as(?u8, 30), surface.effectiveTaskbarProgress().?.progress);
}

test "win32 untitled OSC 9 toast is titled by its tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var w: ToastTestWindow = .{};
    try w.init(false);
    defer w.deinit();

    try w.osc(&w.p, "", "tests passed");
    try w.recorder.expect(.title, "cargo build");

    // A title is shown without its bidi overrides and invisible
    // characters, with controls as spaces, and cut to 64 bytes on a
    // code point.
    w.p.title = "a\u{202E}<b>&\u{200B}\x07c";
    try w.osc(&w.p, "", "x");
    try w.recorder.expect(.title, "a<b>& c");
    try w.recorder.expect(.attribution, "Tab 2: a<b>& c");

    // U+FFFE and U+FFFF, which XML 1.0 cannot carry, so Windows would
    // refuse the toast.
    w.p.title = "x\u{FFFE}y\u{FFFF}z";
    try w.osc(&w.p, "", "x");
    try w.recorder.expect(.title, "x y z");
    try w.recorder.expect(.attribution, "Tab 2: x y z");

    w.p.title = "安" ** 30;
    try w.osc(&w.p, "", "x");
    // Cut on a code point: 21 three-byte characters fit in 64 bytes.
    try w.recorder.expect(.title, "安" ** 21 ++ "\u{2026}");
    try w.recorder.expect(.attribution, "Tab 2: " ++ "安" ** 21 ++ "\u{2026}");

    // A tab with no title at all.
    w.p.title = null;
    try w.osc(&w.p, "", "x");
    try w.recorder.expect(.title, "noctty");
    try w.recorder.expect(.attribution, "Tab 2: noctty");

    // The tab is known by its focused pane's title, also when another of
    // its panes sends the toast. That pane is still the one a click
    // focuses.
    w.p.title = "cargo build";
    w.q.title = "vim";
    const inserted = try SplitTreeSurface.init(std.testing.allocator, &w.q);
    defer {
        var cleanup = inserted;
        cleanup.deinit();
    }
    const tab = &w.host.tabs.items[1];
    var prev_tree = tab.tree;
    tab.tree = try prev_tree.split(std.testing.allocator, tab.focused, .right, 0.5, &inserted);
    prev_tree.deinit();
    // The split moved `p` behind the new split node and `q`.
    tab.focused = @enumFromInt(2);
    try std.testing.expectEqual(@as(?*Surface, &w.p), tab.focusedSurface());
    try w.osc(&w.q, "", "x");
    try w.recorder.expect(.title, "cargo build");
    try w.recorder.expect(.attribution, "Tab 2: cargo build");
    try w.recorder.expectLaunchFor(&w.q, 2);
}

test "win32 seeing a tab removes its panes' toasts" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var w: ToastTestWindow = .{};
    try w.init(true);
    defer w.deinit();
    const inserted = try toastTestSplit(&w);
    defer {
        var cleanup = inserted;
        cleanup.deinit();
    }
    const hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(hwnd);
    w.host.hwnd = hwnd;
    defer w.host.hwnd = null;

    for ([_]*Surface{ &w.p, &w.q, &w.front, &w.other }) |surface| try w.osc(surface, "", "x");

    // The window is in front with the first tab active: the second tab is
    // not seen yet.
    w.app.acknowledgeTabWithForeground(&w.host, 1, hwnd);
    try std.testing.expectEqual(@as(usize, 0), w.app.toast_removals.items.len);

    w.host.active_tab = 1;
    // A window that is not in front is not seen either.
    w.app.acknowledgeTabWithForeground(&w.host, 1, null);
    try std.testing.expectEqual(@as(usize, 0), w.app.toast_removals.items.len);

    w.app.acknowledgeTabWithForeground(&w.host, 1, hwnd);
    w.app.flushToastRemovals();
    var p_buf: [64]u8 = undefined;
    var q_buf: [64]u8 = undefined;
    // In the split tree's order.
    try w.recorder.expectRemovals(&.{
        try expectedToastRemoval(&q_buf, 0x2003),
        try expectedToastRemoval(&p_buf, 0x2002),
    });
    try std.testing.expectEqual(@as(?u64, null), w.p.toast_outstanding);
    try std.testing.expectEqual(@as(?u64, null), w.q.toast_outstanding);
    // The other tab's pane and the other window's keep theirs.
    try std.testing.expectEqual(@as(?u64, 0x1001), w.front.toast_outstanding);
    try std.testing.expectEqual(@as(?u64, 0x3003), w.other.toast_outstanding);
}

test "win32 rollbackFailedSurfaceAttach removes failed tab and restores active index" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var surface_a: Surface = undefined;
    var surface_b: Surface = undefined;
    var tabs: std.ArrayListUnmanaged(Tab) = .empty;
    defer {
        for (tabs.items) |*tab| tab.deinit();
        tabs.deinit(std.testing.allocator);
    }

    try tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &surface_a));
    const prev_tab_count = tabs.items.len;
    try tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &surface_b));

    var active_tab: usize = 1;
    var split_rollback: ?SplitSurfaceAttachRollback = null;
    rollbackFailedSurfaceAttach(&tabs, &active_tab, 0, prev_tab_count, 1, &split_rollback);

    try std.testing.expectEqual(@as(usize, 1), tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), active_tab);
    try std.testing.expectEqual(@as(?*Surface, &surface_a), tabs.items[0].focusedSurface());
}

test "win32 rollbackFailedSurfaceAttach removes a failed middle tab insertion" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var surface_a: Surface = undefined;
    var inserted_surface: Surface = undefined;
    var surface_b: Surface = undefined;
    var tabs: std.ArrayListUnmanaged(Tab) = .empty;
    defer {
        for (tabs.items) |*tab| tab.deinit();
        tabs.deinit(std.testing.allocator);
    }

    try tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &surface_a));
    try tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 2, &surface_b));
    const prev_tab_count = tabs.items.len;
    try tabs.insert(std.testing.allocator, 1, try Tab.init(std.testing.allocator, 3, &inserted_surface));

    var active_tab: usize = 1;
    var split_rollback: ?SplitSurfaceAttachRollback = null;
    rollbackFailedSurfaceAttach(&tabs, &active_tab, 0, prev_tab_count, 1, &split_rollback);

    try std.testing.expectEqual(@as(usize, 2), tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), active_tab);
    try std.testing.expectEqual(@as(u32, 1), tabs.items[0].id);
    try std.testing.expectEqual(@as(u32, 2), tabs.items[1].id);
}

test "win32 rollbackFailedSurfaceAttach restores split tree after failed attach" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var surface_a: Surface = undefined;
    var surface_b: Surface = undefined;
    var tabs: std.ArrayListUnmanaged(Tab) = .empty;
    defer {
        for (tabs.items) |*tab| tab.deinit();
        tabs.deinit(std.testing.allocator);
    }

    try tabs.append(std.testing.allocator, try Tab.init(std.testing.allocator, 1, &surface_a));
    const prev_tab_count = tabs.items.len;
    const prev_focused = tabs.items[0].focused;
    const prev_tree = tabs.items[0].tree;

    const inserted = try SplitTreeSurface.init(std.testing.allocator, &surface_b);
    defer {
        var cleanup = inserted;
        cleanup.deinit();
    }

    const next_tree = try prev_tree.split(
        std.testing.allocator,
        prev_focused,
        .right,
        0.5,
        &inserted,
    );
    tabs.items[0].tree = next_tree;
    tabs.items[0].focused = tabs.items[0].findHandle(&surface_b) orelse .root;

    var active_tab: usize = 0;
    var split_rollback: ?SplitSurfaceAttachRollback = .{
        .tab = &tabs.items[0],
        .tree = prev_tree,
        .focused = prev_focused,
    };
    rollbackFailedSurfaceAttach(&tabs, &active_tab, 0, prev_tab_count, null, &split_rollback);

    try std.testing.expectEqual(@as(usize, 1), tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), active_tab);
    try std.testing.expect(split_rollback == null);
    try std.testing.expectEqual(@as(?*Surface, &surface_a), tabs.items[0].focusedSurface());
    try std.testing.expectEqual(@as(?SplitTreeSurface.Node.Handle, null), tabs.items[0].findHandle(&surface_b));
}

test "win32 output starts the scrollbar's heartbeat, and a hidden bar hides its window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // High Contrast always shows the bar: no heartbeat and nothing to hide.
    if (isHighContrastActive()) return error.SkipZigTest;

    var fixture: SafeModeAppFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    // The dynamic policy whatever this machine's "Always show scrollbars".
    app.system_dynamic_scrollbars = true;
    // The host stays hidden, so the test never touches the foreground.
    const host = try app.createHost(std.unicode.utf8ToUtf16LeStringLiteral(""), &app.config, .{});
    var surface: Surface = .{
        .app = app,
        .host = host,
        .window_visible = true,
        .placement = .{ .rect = .{ .left = 0, .top = 0, .right = 400, .bottom = 300 }, .rect_known = true, .visible = true, .visible_known = true },
        .scrollbar = .{ .total = 100, .offset = 80, .len = 20 },
    };
    // The test binary has no manifest for layered child windows, so the
    // bar's own `CreateWindowEx` fails here. A plain child stands in, and
    // the alpha cache is primed with the alpha each sync computes, so the
    // stand-in is never asked for layered attributes.
    surface.scrollbar_hwnd = try createTestChromeChild(host.hwnd.?, prompt_label_class);
    defer surface.destroyScrollbarWindow();
    const bar = surface.scrollbar_hwnd.?;
    const style = struct {
        fn visible(hwnd: HWND) bool {
            return (@as(usize, @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_STYLE))) & c.WS_VISIBLE) != 0;
        }
    };
    const fade_ms = win32_scrollbar_geometry.auto_hide_fade_ms;

    // Output moved the viewport, before any timer runs: the state changes,
    // then the window is synced, in `setScrollbar`'s order (the wheel and a
    // press do the same). The heartbeat used to start only for a change
    // made inside the sync, so it never ran and the bar stayed on screen.
    // A fade's length later the bar is fully shown with or without
    // animations.
    var now_ms: u64 = 1_000_000;
    surface.noteScrollbarActivity(now_ms);
    surface.scrollbar_alpha_cache = 255;
    try surface.syncScrollbarWindowNow(now_ms + fade_ms);
    try std.testing.expect(host.scrollbar_timer_active);
    try std.testing.expect(style.visible(bar));

    // The heartbeat fades it out. Hidden, it is no window over the pane at
    // all, rather than a layered one left on screen at alpha 1 or 0.
    while (surface.scrollbar_state.visibility != .hidden) {
        now_ms += 2000;
        _ = surface.scrollbar_state.tick(now_ms);
    }
    surface.scrollbar_alpha_cache = 0;
    try surface.syncScrollbarWindowNow(now_ms);
    try std.testing.expect(!style.visible(bar));

    // With the heartbeat stopped (the tick stops it once nothing needs it),
    // the next scroll shows the bar and starts it again.
    host.killScrollbarTimer();
    now_ms += 2000;
    surface.noteScrollbarActivity(now_ms);
    surface.scrollbar_alpha_cache = 255;
    try surface.syncScrollbarWindowNow(now_ms + fade_ms);
    try std.testing.expect(host.scrollbar_timer_active);
    try std.testing.expect(style.visible(bar));
}

test "win32 destroyGL records a teardown stage only when the cleanup succeeded" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // `Get-BenchMemoryStageSamples` validates stage presence alone, so a
    // stage emitted after a failed native call would let a memory run report
    // verified teardown for an HGLRC or DC that was never released. Each
    // stage must therefore be gated on the call it names.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const surface = try alloc.create(Surface);
    defer alloc.destroy(surface);

    // A context handle the driver cannot delete, and a DC with no window to
    // release it against. Both cleanups fail, so neither completion stage
    // may appear. The unbind stage still appears: nothing of ours is current
    // on this thread, so that boundary genuinely holds.
    {
        const sub_path = "teardown-failed.jsonl";
        try tmp.dir.writeFile(.{ .sub_path = sub_path, .data = "" });
        const path = try tmp.dir.realpathAlloc(alloc, sub_path);
        defer alloc.free(path);

        surface.* = uninitializedInertStorage(Surface);
        surface.memory_stage_trace = .{ .path = path };
        surface.hwnd = null;
        surface.hdc = @ptrFromInt(0x1000);
        surface.hglrc = @ptrFromInt(0x1000);

        surface.destroyGL();

        const contents = try tmp.dir.readFileAlloc(alloc, sub_path, 16 * 1024);
        defer alloc.free(contents);
        try std.testing.expect(
            std.mem.indexOf(u8, contents, "\"stage\":\"wgl_context_unbound\"") != null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, contents, "\"stage\":\"wgl_context_deleted\"") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, contents, "\"stage\":\"dc_released\"") == null,
        );
        // The handles are dropped either way; only the claim is withheld.
        try std.testing.expectEqual(@as(HGLRC, null), surface.hglrc);
        try std.testing.expectEqual(@as(HDC, null), surface.hdc);
    }

    // A real window DC that ReleaseDC does release. The stage must appear,
    // so the fail-closed rule does not break the ordinary teardown path.
    {
        const sub_path = "teardown-released.jsonl";
        try tmp.dir.writeFile(.{ .sub_path = sub_path, .data = "" });
        const path = try tmp.dir.realpathAlloc(alloc, sub_path);
        defer alloc.free(path);

        const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
        const window_name = std.unicode.utf8ToUtf16LeStringLiteral("");
        const hwnd = sys.CreateWindowExW(
            0,
            class,
            window_name,
            c.WS_POPUP,
            0,
            0,
            1,
            1,
            null,
            null,
            sys.GetModuleHandleW(null),
            null,
        ) orelse return error.SkipZigTest;
        defer _ = sys.DestroyWindow(hwnd);
        const hdc = sys.GetDC(hwnd) orelse return error.SkipZigTest;

        surface.* = uninitializedInertStorage(Surface);
        surface.memory_stage_trace = .{ .path = path };
        surface.hwnd = hwnd;
        surface.hdc = hdc;
        surface.hglrc = null;

        surface.destroyGL();

        const contents = try tmp.dir.readFileAlloc(alloc, sub_path, 16 * 1024);
        defer alloc.free(contents);
        try std.testing.expect(
            std.mem.indexOf(u8, contents, "\"stage\":\"dc_released\"") != null,
        );
        try std.testing.expectEqual(@as(HDC, null), surface.hdc);
    }
}

test "win32 GL unbind reports the boundary it actually established" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const surface = try alloc.create(Surface);
    defer alloc.destroy(surface);

    // No context of ours exists, so nothing of ours can be current.
    surface.* = uninitializedInertStorage(Surface);
    surface.hglrc = null;
    surface.hdc = null;
    try std.testing.expect(surface.clearGLContextCurrentChecked());

    // A context that is not current on this thread is already unbound here,
    // so the boundary holds without calling wglMakeCurrent at all.
    surface.* = uninitializedInertStorage(Surface);
    surface.hglrc = @ptrFromInt(0x1000);
    surface.hdc = @ptrFromInt(0x2000);
    try std.testing.expect(sys.wglGetCurrentContext() != surface.hglrc);
    try std.testing.expect(surface.clearGLContextCurrentChecked());
}
