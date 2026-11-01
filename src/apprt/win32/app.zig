//! Win32 application lifecycle and coordination.
const win32 = @import("../win32.zig");
const ATOM = win32.ATOM;
const Allocator = win32.Allocator;
const AppDelivery = win32.AppDelivery;
const ClipboardSource = win32.ClipboardSource;
const CloseScope = win32.CloseScope;
const ColdToastCapture = win32.ColdToastCapture;
const ConfirmCancelReason = @import("overlay_session.zig").ConfirmCancelReason;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const DWORD = win32.DWORD;
const GlobalHotkeySpec = win32.GlobalHotkeySpec;
const HDC = win32.HDC;
const HGLRC = win32.HGLRC;
const HINSTANCE = win32.HINSTANCE;
const HWND = win32.HWND;
const Host = win32.Host;
const Registry = @import("registry.zig").Registry;
const HostBannerKind = win32.HostBannerKind;
const HostTabStatus = win32.HostTabStatus;
const LPARAM = win32.LPARAM;
const LPCWSTR = win32.LPCWSTR;
const MSG = win32.MSG;
const NONCLIENTMETRICSW = win32.NONCLIENTMETRICSW;
const OpenGLStartupStep = win32.OpenGLStartupStep;
const PaletteCatalog = win32.PaletteCatalog;
const ProfileDiscoveryCompletion = win32.ProfileDiscoveryCompletion;
const ProfileOpenTarget = win32.ProfileOpenTarget;
const RECT = win32.RECT;
const RecoveryLedgerLock = win32.RecoveryLedgerLock;
const RecoveryStartup = win32.RecoveryStartup;
const RegisteredGlobalHotkey = win32.RegisteredGlobalHotkey;
const SessionOwnerLock = win32.SessionOwnerLock;
const SplitTreeSurface = win32.SplitTreeSurface;
const Surface = win32.Surface;
const SurfaceInitOptions = win32.SurfaceInitOptions;
const SystemWheelSettings = win32.SystemWheelSettings;
const Tab = win32.Tab;
const ThemeColors = win32.ThemeColors;
const ToastRequest = win32.ToastRequest;
const ToastSink = win32.ToastSink;
const UINT = win32.UINT;
const UINT_PTR = win32.UINT_PTR;
const UpdateCheckCompletion = win32.UpdateCheckCompletion;
const UpdateCheckRequest = win32.UpdateCheckRequest;
const UpdateNotice = win32.UpdateNotice;
const WNDCLASSEXW = win32.WNDCLASSEXW;
const WindowKeeps = win32.WindowKeeps;
const activeTabAfterRemoval = win32.activeTabAfterRemoval;
const adoptedInitialShow = win32.adoptedInitialShow;
const appLifecycleWindowProc = win32.appLifecycleWindowProc;
const appMessageWindowProc = win32.appMessageWindowProc;
const appQuitConfirmAccept = win32.appQuitConfirmAccept;
const appendOwnedString = paint_text.appendOwnedString;
const applyAutomationWorkingDirectory = win32.applyAutomationWorkingDirectory;
const applyDwmThemeWithBuild = win32.applyDwmThemeWithBuild;
const applyNewWindowArguments = win32.applyNewWindowArguments;
const applyQuickSlotPreferenceOrder = win32.applyQuickSlotPreferenceOrder;
const applySplitWorkingDirectoryFromSource = win32.applySplitWorkingDirectoryFromSource;
const apprt = @import("../../apprt.zig");
const automationHostFocused = win32.automationHostFocused;
const automationTextAllowed = win32.automationTextAllowed;
const automationWorkingDirectoryAllowed = win32.automationWorkingDirectoryAllowed;
const beginOpenGLStartupDiagnostics = win32.beginOpenGLStartupDiagnostics;
const beginRecoveryStartup = win32.beginRecoveryStartup;
const bench_trace = @import("bench_trace.zig");
const buildInstallerApplyArgs = win32.buildInstallerApplyArgs;
const buildToastLaunchForSurface = win32.buildToastLaunchForSurface;
const build_config = @import("../../build_config.zig");
const builtin = @import("builtin");
const c = @import("consts.zig");
const child_window = @import("child_window.zig");
const claimSharedIdentity = win32.claimSharedIdentity;
const class_name = win32.class_name;
const cliClass = win32.cliClass;
const cliConfigFileOverride = win32.cliConfigFileOverride;
const cliVisualStudioProfilesArg = win32.cliVisualStudioProfilesArg;
const closeOtherTabsConfirmAccept = win32.closeOtherTabsConfirmAccept;
const closeRightTabsConfirmAccept = win32.closeRightTabsConfirmAccept;
const closeThisTabConfirmAccept = win32.closeThisTabConfirmAccept;
const config_edit = @import("../../config/edit.zig");
const config_file_load = @import("../../config/file_load.zig");
const configpkg = @import("../../config.zig");
const configuredHostWindowPosition = win32.configuredHostWindowPosition;
const currentInstallDir = win32.currentInstallDir;
const darkTheme = win32.darkTheme;
const default_title = win32.default_title;
const deinitImeWindowFormsTracePath = win32.deinitImeWindowFormsTracePath;
const desiredMoveIndex = win32.desiredMoveIndex;
const desiredTabIndex = win32.desiredTabIndex;
const detectDefaultProfileHint = win32.detectDefaultProfileHint;
const detectDefaultProfileTarget = win32.detectDefaultProfileTarget;
const detectExplicitStartupWorkingDirectory = win32.detectExplicitStartupWorkingDirectory;
const detectStartupProfilePicker = win32.detectStartupProfilePicker;
const docked_search = @import("docked_search.zig");
const elevatedProfileKey = win32.elevatedProfileKey;
const elevatesBySelector = win32.elevatesBySelector;
const findLauncherQuickSlotOrdinal = win32.findLauncherQuickSlotOrdinal;
const forwardedActivationExtraArgCount = win32.forwardedActivationExtraArgCount;
const forwardedArgvRejection = win32.forwardedArgvRejection;
const forwardedArgvSetsKey = win32.forwardedArgvSetsKey;
const gl_startup = @import("gl_startup.zig");
const hostWindowProc = win32.hostWindowProc;
const host_class_name = win32.host_class_name;
const hotkeyRegistrationFailureReason = win32.hotkeyRegistrationFailureReason;
const hotkeySpecEql = win32.hotkeySpecEql;
const hotkeySpecForTrigger = win32.hotkeySpecForTrigger;
const input = @import("../../input.zig");
const installTerminfo = win32.installTerminfo;
const installerRestartCommandLine = win32.installerRestartCommandLine;
const internal_os = @import("../../os/main.zig");
const ipc_server = @import("ipc_server.zig");
const isHighContrastActive = win32.isHighContrastActive;
const isLaunchArgumentDiagnostic = win32.isLaunchArgumentDiagnostic;
const isPortableModeActive = win32.isPortableModeActive;
const isSafeStartupCwd = win32.isSafeStartupCwd;
const isSystemDarkMode = win32.isSystemDarkMode;
const jumpListRebuildThreadMain = win32.jumpListRebuildThreadMain;
const labels = @import("labels.zig");
const lastError = child_window.lastError;
const launcherQuickSlotAssignmentNeedsChange = win32.launcherQuickSlotAssignmentNeedsChange;
const launcherQuickSlotPinsAlreadyClear = win32.launcherQuickSlotPinsAlreadyClear;
const layoutActionResult = win32.layoutActionResult;
const listProfilesForConfig = win32.listProfilesForConfig;
const loadAppIcon = win32.loadAppIcon;
const localAppDataPathAlloc = win32.localAppDataPathAlloc;
const log = win32.log;
const logBackgroundBlurUnsupported = win32.logBackgroundBlurUnsupported;
const logForwardedArgvRejection = win32.logForwardedArgvRejection;
const markRecoveryAttemptAtPath = win32.markRecoveryAttemptAtPath;
const onHostCloakEvent = win32.onHostCloakEvent;
const ownedBytesEquals = paint_text.ownedBytesEquals;
const paint_text = @import("text.zig");
const palette_controller = @import("palette_controller.zig");
const pane_launch = configpkg.pane_launch;
const persistMergedRecoveryReadyAtPath = win32.persistMergedRecoveryReadyAtPath;
const persistSettings = win32.persistSettings;
const pixel_format = @import("pixel_format.zig");
const probeWindowsBuild = win32.probeWindowsBuild;
const processDeferredUiaDisconnect = win32.processDeferredUiaDisconnect;
const profileDiscoveryThreadMain = win32.profileDiscoveryThreadMain;
const profileIndexByKey = win32.profileIndexByKey;
const ptypkg = @import("../../pty.zig");
const pumpUntilColdToastActivation = win32.pumpUntilColdToastActivation;
const queueTerminalHandoff = win32.queueTerminalHandoff;
const quickSelectProc = win32.quickSelectProc;
const quick_select_class_name = win32.quick_select_class_name;
const quick_terminal_host = @import("quick_terminal_host.zig");
const quitTimerDelayMs = win32.quitTimerDelayMs;
const readDynamicScrollbars = win32.readDynamicScrollbars;
const readRecoveryLedgerAlloc = win32.readRecoveryLedgerAlloc;
const readSystemWheelSetting = win32.readSystemWheelSetting;
const recordOpenGLStartupError = win32.recordOpenGLStartupError;
const recordOpenGLStartupWin32Failure = win32.recordOpenGLStartupWin32Failure;
const recordOpenUrlForTest = win32.recordOpenUrlForTest;
const recoveryFailurePolicy = win32.recoveryFailurePolicy;
const recoveryRetryDue = win32.recoveryRetryDue;
const recoverySafeModeNotice = win32.recoverySafeModeNotice;
const recoverySafeModeNoticeThread = win32.recoverySafeModeNoticeThread;
const recovery_ledger_lock_wait_ms = win32.recovery_ledger_lock_wait_ms;
const recovery_ready_retry_delay_ms = win32.recovery_ready_retry_delay_ms;
const releaseToastDelivery = win32.releaseToastDelivery;
const requestedTabInsertIndex = win32.requestedTabInsertIndex;
const resolveIpcPipeNameForTarget = win32.resolveIpcPipeNameForTarget;
const resolveTheme = win32.resolveTheme;
const restart_max_cmd_line = win32.restart_max_cmd_line;
const restoreRequestedHostWindowStyle = win32.restoreRequestedHostWindowStyle;
const retainToastDelivery = win32.retainToastDelivery;
const runUiActionOrLog = win32.runUiActionOrLog;
const scanForwardedToastActivation = win32.scanForwardedToastActivation;
const scanLaunchLayoutIpcArgument = win32.scanLaunchLayoutIpcArgument;
const scanToastActivationArg = win32.scanToastActivationArg;
const scrollbarProc = win32.scrollbarProc;
const scrollbar_class_name = win32.scrollbar_class_name;
const sendAutomationTextIpc = win32.sendAutomationTextIpc;
const sendFocusIpc = win32.sendFocusIpc;
const sendLaunchLayoutIpc = win32.sendLaunchLayoutIpc;
const sendListWindowsIpc = win32.sendListWindowsIpc;
const sendNewSplitIpc = win32.sendNewSplitIpc;
const sendNewTabIpc = win32.sendNewTabIpc;
const sendNewWindowIpc = win32.sendNewWindowIpc;
const sendPerformActionIpc = win32.sendPerformActionIpc;
const session_module = @import("session.zig");
const setWindowData = child_window.setWindowData;
const setWindowIcon = win32.setWindowIcon;
const settingsAppIconThunk = win32.settingsAppIconThunk;
const settingsChromeBgThunk = win32.settingsChromeBgThunk;
const settingsConfigProblemsThunk = win32.settingsConfigProblemsThunk;
const settingsConfigRevisionThunk = win32.settingsConfigRevisionThunk;
const settingsCurrentConfigThunk = win32.settingsCurrentConfigThunk;
const settingsCustomUiaProvidersEnabledThunk = win32.settingsCustomUiaProvidersEnabledThunk;
const settingsDeferUiaDisconnectThunk = win32.settingsDeferUiaDisconnectThunk;
const settingsDiskVerdict = win32.settingsDiskVerdict;
const settingsEndSessionThunk = win32.settingsEndSessionThunk;
const settingsFailureDetailThunk = win32.settingsFailureDetailThunk;
const settingsFileOpenable = win32.settingsFileOpenable;
const settingsHighContrastThunk = win32.settingsHighContrastThunk;
const settingsMaskedKeyNames = win32.settingsMaskedKeyNames;
const settingsMaskedKeysThunk = win32.settingsMaskedKeysThunk;
const settingsNotifyConflictThunk = win32.settingsNotifyConflictThunk;
const settingsNotifySuccessThunk = win32.settingsNotifySuccessThunk;
const settingsOnClosedThunk = win32.settingsOnClosedThunk;
const settingsOpenInEditorThunk = win32.settingsOpenInEditorThunk;
const settingsCopyTextThunk = win32.settingsCopyTextThunk;
const settingsOwnerWindowThunk = win32.settingsOwnerWindowThunk;
const settingsPreviewFieldThunk = win32.settingsPreviewFieldThunk;
const settingsPreviewShowsNothingNew = win32.settingsPreviewShowsNothingNew;
const settingsProfileChoicesThunk = win32.settingsProfileChoicesThunk;
const settingsQueryEndSessionThunk = win32.settingsQueryEndSessionThunk;
const settingsReconcileDiskThunk = win32.settingsReconcileDiskThunk;
const settingsSaveAndReloadThunk = win32.settingsSaveAndReloadThunk;
const settingsSaveTargetThunk = win32.settingsSaveTargetThunk;
const settingsConfigSourceThunk = win32.settingsConfigSourceThunk;
const settingsTextPrimaryThunk = win32.settingsTextPrimaryThunk;
const settingsThemeColorsThunk = win32.settingsThemeColorsThunk;
const settingsUserEditedKeys = win32.settingsUserEditedKeys;
const settings_masked_keys_capacity = win32.settings_masked_keys_capacity;
const shouldInheritSplitWorkingDirectory = win32.shouldInheritSplitWorkingDirectory;
const shouldResetNewTabWorkingDirectory = win32.shouldResetNewTabWorkingDirectory;
const shouldUseIntegratedTitlebar = win32.shouldUseIntegratedTitlebar;
const splitDirectionFromAction = win32.splitDirectionFromAction;
const splitTreeEquivalent = win32.splitTreeEquivalent;
const startupHostWindowStyle = win32.startupHostWindowStyle;
const std = @import("std");
const suppressStartupLoaderErrorDialogs = win32.suppressStartupLoaderErrorDialogs;
const surfaceActivationNeedsHostSync = win32.surfaceActivationNeedsHostSync;
const surfaceFocusStateChanged = win32.surfaceFocusStateChanged;
const surfaceFocusedActivationNeedsHostSync = win32.surfaceFocusedActivationNeedsHostSync;
const surface_presentation = @import("surface_presentation.zig");
const sys = @import("sys.zig");
const tabBarVisibleForConfig = win32.tabBarVisibleForConfig;
const tabSeenByUser = win32.tabSeenByUser;
const tabSeenWithForeground = win32.tabSeenWithForeground;
const tabStatusHeadline = win32.tabStatusHeadline;
const tabTooltipProc = win32.tabTooltipProc;
const tab_tooltip_class_name = win32.tab_tooltip_class_name;
const tabsCloseConfirmCount = win32.tabsCloseConfirmCount;
const tabsCloseConfirmCountNoWait = win32.tabsCloseConfirmCountNoWait;
const toastActivatorSink = win32.toastActivatorSink;
const toastGroup = win32.toastGroup;
const toastTag = win32.toastTag;
const toast_group_max = win32.toast_group_max;
const undecoratedKeepsFrame = win32.undecoratedKeepsFrame;
const unixMillis = win32.unixMillis;
const updateApplyConfirmAccept = win32.updateApplyConfirmAccept;
const updateApplyFailureMessage = win32.updateApplyFailureMessage;
const updateCheckThreadMain = win32.updateCheckThreadMain;
const updatepkg = @import("../../update/github_releases.zig");
const userProfileKeysChanged = win32.userProfileKeysChanged;
const warnPortableIgnoredLocalData = win32.warnPortableIgnoredLocalData;
const win32_aumid = @import("../win32_aumid.zig");
const win32_bell = @import("../win32_bell.zig");
const win32_compositor = @import("../win32_compositor.zig");
const win32_compositor_native = @import("../win32_compositor_native.zig");
const win32_config_problems = @import("config_problems.zig");
const win32_elevation = @import("../win32_elevation.zig");
const win32_jump_list = @import("../win32_jump_list.zig");
const win32_layouts = @import("../win32_layouts.zig");
const win32_link_preview = @import("../win32_link_preview.zig");
const win32_power = @import("../win32_power.zig");
const win32_powershell_install = @import("../win32_powershell_install.zig");
const win32_program_status = @import("../win32_program_status.zig");
const win32_recovery = @import("../win32_recovery.zig");
const win32_session_persistence = @import("../win32_session_persistence.zig");
const win32_session_state = @import("../win32_session_state.zig");
const win32_settings = @import("../win32_settings.zig");
const settings_reference = @import("../win32_settings_reference.zig");
const settings_patch = @import("settings_patch.zig");
const win32_shell = @import("../win32_shell.zig");
const win32_structural_history = @import("../win32_structural_history.zig");
const win32_taskbar_progress = @import("../win32_taskbar_progress.zig");
const win32_terminal_handoff = @import("../win32_terminal_handoff.zig");
const win32_theme = @import("../win32_theme.zig");
const win32_toast_activation = @import("../win32_toast_activation.zig");
const win32_toast_activator = @import("../win32_toast_activator.zig");
const win32_toast_winrt = @import("../win32_toast_winrt.zig");
const win32_uia = @import("../win32_uia/mod.zig");
const windowNewTabInsertIndex = win32.windowNewTabInsertIndex;
const windowProc = win32.windowProc;
const window_state = @import("window_state.zig");
const windows = win32.windows;
const windows_shell = @import("../../config/windows_shell.zig");
const winrtToastActivationCallback = win32.winrtToastActivationCallback;
const withoutAppWideArguments = win32.withoutAppWideArguments;
const writePersistentFileAlloc = win32.writePersistentFileAlloc;

// Test dependencies.
const LRESULT = win32.LRESULT;
const WPARAM = win32.WPARAM;
const palette_list_class_name = win32.palette_list_class_name;
const prompt_label_class = child_window.prompt_label_class;
const TestSession = win32.TestSession;
const createTestChromeChild = win32.createTestChromeChild;
const BOOL = win32.BOOL;
const InitialShow = win32.InitialShow;
const POINT = win32.POINT;
const TestToastRecorder = win32.TestToastRecorder;
const ToastTestWindow = win32.ToastTestWindow;
const cliConfigFileOverrideArgs = win32.cliConfigFileOverrideArgs;
const cli_args = @import("../../cli/args.zig");
const createTestHostWindow = win32.createTestHostWindow;
const lightTheme = win32.lightTheme;
const runOnHiddenDesktop = win32.runOnHiddenDesktop;
const settingChangeAffectsTheme = win32.settingChangeAffectsTheme;
const settingsDraftProfileLabel = win32.settingsDraftProfileLabel;
const terminalAccessibilityCapture = win32.terminalAccessibilityCapture;
const terminalAccessibilityDeferProviderRelease = win32.terminalAccessibilityDeferProviderRelease;
const terminalAccessibilityFocused = win32.terminalAccessibilityFocused;
const terminalAccessibilityHwnd = win32.terminalAccessibilityHwnd;
const terminalAccessibilityName = win32.terminalAccessibilityName;
const testExpectNoLaunchLayout = win32.testExpectNoLaunchLayout;
const testFreeConfigProblems = win32.testFreeConfigProblems;
const testHitTest = win32.testHitTest;
const testLoadStartupArgv = win32.testLoadStartupArgv;
const win32_terminal_accessibility = @import("../win32_terminal_accessibility.zig");

test "win32 safe mode reload keeps recovery without loading config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // No CoreApp or config is installed: recovery reload must return before
    // touching either, for hard and soft reloads alike.
    var app: App = undefined;
    app.safe_mode = true;
    try std.testing.expect(try app.performAction(.app, .reload_config, .{ .soft = false }));
    try std.testing.expect(try app.performAction(.app, .reload_config, .{ .soft = true }));
    var config: configpkg.Config = undefined;
    try app.settingsReconcileDisk(&config, &config, false);
    try app.settingsReconcileDisk(&config, &config, true);
}

const releases_url = updatepkg.releases_url;

const lifecycle_class_name = std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.lifecycle");

const shell_open: LPCWSTR = std.unicode.utf8ToUtf16LeStringLiteral("open");

const shell_runas: LPCWSTR = std.unicode.utf8ToUtf16LeStringLiteral("runas");

/// How often a running process asks the automatic check to run again. The
/// check's 24 hour throttle (`updatepkg.throttle_seconds`) decides whether a
/// request is actually made, so this only has to be shorter than the throttle
/// by a margin: six hours means a release is noticed within a day of the
/// throttle expiring, and an early tick just reads the saved state.
const update_recheck_interval_ms: u32 = 6 * 60 * 60 * 1000;

/// How many message-loop ticks may attempt the ready-marker write before the
/// launch is given up as unresolved.
const recovery_ready_persist_attempts: u8 = 3;

const shell_audit_warn_interval_ms: u64 = 60 * std.time.ms_per_s;

/// Longer than a discovery can take when it works (two 1.5 s wsl.exe
/// timeouts and the SSH config read budget).
const profile_discovery_abandon_ms: u64 = 10 * std.time.ms_per_s;

/// How long a cold `-ToastActivated` start waits for COM's `Activate`. COM
/// calls it as soon as the class object is registered; the wait only bounds
/// a start that never gets the call (run by hand, or COM gave up).
const cold_toast_activation_wait_ms = 5000;

/// RESTART_NO_CRASH | RESTART_NO_HANG | RESTART_NO_REBOOT: no restart after a
/// crash or a hang (Windows Error Reporting), nor after a reboot an update
/// forces. Nothing in the flags covers a sign-out, a reboot the user chose or
/// Windows' option to restart apps at sign-in: the registration lasts only
/// from an agreeing Restart Manager query until the process ends or the close
/// is called off, and a sign-out, shutdown or reboot takes it back
/// (`App.onQueryEndSession`, `App.onEndSession`). Not RESTART_NO_PATCH, which
/// is the flag that stops an installer's restart.
const restart_flags: DWORD = 0x1 | 0x2 | 0x8;

/// Retry budget for the ready marker, spent across message-loop ticks.
///
/// The ready marker is the only thing that breaks a failure streak, so a
/// transient write failure must not be latched as handled — that leaves the
/// launch unresolved on disk for the whole session and feeds the automatic
/// safe mode this branch exists to stop. Retries deliberately ride real
/// message-loop ticks rather than an in-line sleep loop: an earlier ~20 ms
/// three-attempt loop was removed because it could not outlast an anti-virus
/// or backup handle hold, whereas tick-spaced attempts can.
const RecoveryReadyRetry = struct {
    failures: u8 = 0,

    /// Records a failed attempt. Returns true when the launch should be
    /// treated as resolved and no later tick should try again.
    fn recordFailure(self: *RecoveryReadyRetry, err: anyerror) bool {
        self.failures +|= 1;
        // OutOfMemory will not clear by waiting and every retry allocates
        // again, so stop immediately rather than spending the budget.
        if (err == error.OutOfMemory) return true;
        return self.failures >= recovery_ready_persist_attempts;
    }
};

/// Sequencing for the safe-mode dialog.
///
/// The notice is armed at the initial-window boundary but released only once
/// the launch is resolved on disk, so a process terminated while the modal is
/// up has already broken the failure streak.
const RecoverySafeModeNotice = struct {
    armed: bool = false,
    released: bool = false,

    fn arm(self: *RecoverySafeModeNotice, decision: win32_recovery.Decision) void {
        if (decision != .normal) self.armed = true;
    }

    /// Returns true at most once, and only after the ledger write for this
    /// launch has succeeded or exhausted its retries.
    fn release(self: *RecoverySafeModeNotice, launch_resolved: bool) bool {
        if (!self.armed or self.released or !launch_resolved) return false;
        self.released = true;
        return true;
    }
};

/// How this copy of noctty gets updated. A setup-managed copy applies a
/// staged installer and a portable-marker copy a staged ZIP. Anything else
/// (Scoop, a ZIP extracted without its marker) was put there by someone else
/// and cannot apply either, so downloading a staged update for it is wasted
/// and its "ready to install" notice would be untrue.
const InstallKind = enum {
    installer,
    portable,
    other,

    fn classify(portable_marker: bool, installer_managed: bool) InstallKind {
        if (portable_marker) return .portable;
        return if (installer_managed) .installer else .other;
    }

    /// What to stage for this copy, or null when nothing can be applied.
    fn stagedKind(self: InstallKind) ?updatepkg.portable_apply.StagedKind {
        return switch (self) {
            .installer => .installer,
            .portable => .portable,
            .other => null,
        };
    }

    /// A failed probe is `.other`: refusing to stage is the safe answer.
    fn detect(alloc: Allocator) InstallKind {
        if (isPortableModeActive(alloc)) return .portable;
        const install_dir = currentInstallDir(alloc) catch return .other;
        defer alloc.free(install_dir);
        return classify(false, internal_os.windows.isInstallerManagedInstallDir(install_dir));
    }

    test "only setup-managed and portable-marker copies stage an update" {
        try std.testing.expectEqual(InstallKind.installer, classify(false, true));
        try std.testing.expectEqual(InstallKind.portable, classify(true, false));
        // A portable marker beside a setup-managed layout is still portable.
        try std.testing.expectEqual(InstallKind.portable, classify(true, true));
        try std.testing.expectEqual(InstallKind.other, classify(false, false));

        try std.testing.expectEqual(@as(?updatepkg.portable_apply.StagedKind, .installer), InstallKind.installer.stagedKind());
        try std.testing.expectEqual(@as(?updatepkg.portable_apply.StagedKind, .portable), InstallKind.portable.stagedKind());
        try std.testing.expectEqual(@as(?updatepkg.portable_apply.StagedKind, null), InstallKind.other.stagedKind());
    }
};

/// At most one warning per interval; the ones left out are counted and
/// reported with the next.
const RateLimitedWarning = struct {
    last_ms: ?u64 = null,
    suppressed: u32 = 0,

    /// The count left out since the last warning when one may be logged at
    /// `now`, else null.
    fn take(self: *RateLimitedWarning, now: u64, interval_ms: u64) ?u32 {
        if (self.last_ms) |last| if (now -% last < interval_ms) {
            self.suppressed +|= 1;
            return null;
        };
        const suppressed = self.suppressed;
        self.last_ms = now;
        self.suppressed = 0;
        return suppressed;
    }
};

test "a rate-limited warning logs once per interval and counts the rest" {
    var warning: RateLimitedWarning = .{};
    try std.testing.expectEqual(@as(?u32, 0), warning.take(1_000, 60_000));
    try std.testing.expectEqual(@as(?u32, null), warning.take(2_000, 60_000));
    try std.testing.expectEqual(@as(?u32, null), warning.take(60_999, 60_000));
    try std.testing.expectEqual(@as(?u32, 2), warning.take(61_000, 60_000));
    try std.testing.expectEqual(@as(?u32, null), warning.take(61_001, 60_000));
}

fn nextTabInspectorVisible(active_tab_has_inspector: bool, mode: apprt.action.Inspector) bool {
    return switch (mode) {
        .toggle => !active_tab_has_inspector,
        .show => true,
        .hide => false,
    };
}

test "win32 tab inspector toggle hides any active pane inspector" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(nextTabInspectorVisible(false, .toggle));
    try std.testing.expect(!nextTabInspectorVisible(true, .toggle));
    try std.testing.expect(nextTabInspectorVisible(false, .show));
    try std.testing.expect(nextTabInspectorVisible(true, .show));
    try std.testing.expect(!nextTabInspectorVisible(false, .hide));
    try std.testing.expect(!nextTabInspectorVisible(true, .hide));
}

pub const App = struct {
    pub const must_draw_from_app_thread = true;
    pub const renderer_pacing_clock = win32_power.renderer_clock;

    core_app: *CoreApp,
    config: configpkg.Config,
    /// What Settings previews and has not saved: a copy of `config` with the
    /// previewed drafts in it, null while it would equal `config`. The chrome
    /// theme and the windows' opacity are drawn from it (`shownConfig`).
    /// `config` keeps what the files say: new terminals, reloads (a Windows
    /// light/dark switch is one) and Settings' own snapshots read it, and an
    /// unsaved draft must reach none of them (PKG-39).
    settings_preview: ?configpkg.Config = null,
    /// Cached TokenElevation state. This scopes the title and IPC namespace
    /// consistently for the full lifetime of the process.
    is_elevated: bool = false,
    /// Session persistence is excluded for a genuine full split token, and
    /// for an elevated process whose elevation type could not be queried
    /// (unknown fails closed). UAC-off and built-in-Administrator tokens are
    /// elevated but default elevation type, so they keep normal session
    /// persistence.
    session_state_excluded_for_elevation: bool = false,
    config_revision: u64 = 1,
    resolved_theme: ThemeColors = darkTheme(),
    /// Completed `reconfigureTheme` passes; a test reads it to prove that a
    /// settings preview which cannot change the theme does not run one.
    theme_rebuilds: u32 = 0,
    system_theme_refresh: SystemThemeRefresh = .{},
    hinstance: HINSTANCE,
    class_atom: ATOM = 0,
    host_class_atom: ATOM = 0,
    palette_list_class_atom: ATOM = 0,
    tab_tooltip_class_atom: ATOM = 0,
    scrollbar_class_atom: ATOM = 0,
    quick_select_class_atom: ATOM = 0,
    registry: Registry = .{},
    /// Owned shell requests waiting for the top of the message loop;
    /// see `runDeferredOpens`.
    deferred_opens: std.ArrayListUnmanaged(DeferredOpen) = .empty,

    /// Internal test seam so action-path tests can drive real
    /// `performAction(.new_tab, ...)` logic without requiring HWND/GL
    /// surface bring-up.
    test_create_window_surface: ?*const fn (
        app: *App,
        config: *const configpkg.Config,
        title: LPCWSTR,
        opts: SurfaceInitOptions,
    ) anyerror!*Surface = null,
    /// Test-only seam that stands in for the GL context and the core surface
    /// in `Surface.init`, neither of which a unit test can create. The window,
    /// tab, shell and unwind steps around them run for real.
    test_surface_init_stage: ?*const fn (surface: *Surface, stage: Surface.InitStage) anyerror!void = null,
    /// Test-only seam for automation snapshots built without a live core
    /// surface. Returned strings are owned by the caller.
    test_automation_pwd: ?*const fn (Allocator, *Surface) anyerror!?[]const u8 = null,
    /// Test-only seam proving automation uses the protected paste encoder.
    test_automation_paste: ?*const fn (
        surface: *Surface,
        state: apprt.ClipboardRequest,
        text: [:0]const u8,
        confirmed: bool,
    ) anyerror!void = null,
    /// Test-only stand-in for the open system clipboard behind a paste or an
    /// OSC 52 read, so no test opens the real clipboard. The production
    /// choice between its text and its files (`selectClipboardContents`)
    /// still runs on what it offers.
    test_clipboard_source: ?ClipboardSource = null,
    /// Test-only interleaving seam for the focus revision race between a
    /// structural prepare and commit (a split undone, a tab closed again).
    /// `pane` is one whose focus the test moves.
    test_before_structural_shell_commit: ?*const fn (
        app: *App,
        pane: win32_shell.model.PaneId,
    ) anyerror!void = null,
    /// Test-only stand-in for `ShellExecuteW` on a checked open target, so a
    /// unit test never launches a real handler.
    test_open_target: ?*const fn (app: *App, target: []const u8) anyerror!void = null,
    /// Stand-in for the remaining shell launchers; tests never launch OSK,
    /// elevated windows or installers.
    test_shell_request: ?*const fn (app: *App, request: *const DeferredOpen) anyerror!void = null,
    next_host_id: u32 = 1,
    /// Window activations so far, which orders `Host.activated`.
    activations: u64 = 0,
    launcher_profile_key: ?[:0]const u8 = null,
    launcher_profile_hint: ?[:0]const u8 = null,
    launcher_quick_slot_keys: [3]?[:0]const u8 = .{ null, null, null },
    launcher_profile_target: ProfileOpenTarget = .tab,
    startup_profile_picker: bool = false,
    /// True when argv explicitly selects a working directory. Such cold-start
    /// flows must create their requested window rather than restore a saved
    /// session and discard the CLI destination.
    explicit_startup_working_directory: bool = false,
    wheel_settings: SystemWheelSettings = .{},
    system_dynamic_scrollbars: bool = true,
    ipc_pipe_name: ?[:0]const u16 = null,
    /// Effective sanitized namespace captured when the IPC server starts.
    ipc_namespace: ?[]const u8 = null,
    ipc_thread: ?std.Thread = null,
    /// Set to end the IPC server thread's waits; owned while it runs.
    ipc_stop_event: ?windows.HANDLE = null,
    ipc_stop_requested: std.atomic.Value(bool) = .init(false),
    global_hotkeys: std.ArrayListUnmanaged(RegisteredGlobalHotkey) = .empty,
    global_hotkeys_dirty: bool = false,
    ui_thread_id: DWORD = 0,
    /// Published before any producer starts; retained until producers stop.
    /// Detached update workers hold their own reference, without borrowing App.
    delivery: ?*AppDelivery = null,
    /// Bumped whenever a Host's profiles are replaced or dropped, so a
    /// discovery that finishes off the UI thread can tell it went stale.
    profiles_generation: u64 = 0,
    /// A discovery result from `startProfileDiscovery`, waiting for the top
    /// of the outer pump.
    pending_profile_discovery: ?*ProfileDiscoveryCompletion = null,
    /// When the running discovery started (GetTickCount64), so one that never
    /// finishes does not block every later attempt.
    profile_discovery_started_ms: u64 = 0,
    /// Fires once after a worker starts, unless its result arrived, to start
    /// another attempt: nothing else re-arms the jump list's timer when a
    /// worker hangs or cannot deliver.
    profile_discovery_watchdog_id: ?UINT_PTR = null,
    /// The host inside `Host.requestProfiles`. With no worker the discovery
    /// runs synchronously within that call, and the host re-checks its list
    /// itself instead of being called back from inside its own chrome sync.
    profiles_requesting_host: ?*Host = null,
    /// Numbers each worker, so a late result from an abandoned one leaves the
    /// running state and watchdog of the attempt that replaced it alone.
    profile_discovery_attempt: u64 = 0,
    /// The never-shown top-level window that answers end-session messages
    /// (`createLifecycleWindow`); null if it could not be made.
    lifecycle_hwnd: ?HWND = null,
    core_ticking: bool = false,
    quit_timer_id: ?UINT_PTR = null,
    terminal_handoff_idle_timer_id: ?UINT_PTR = null,
    terminal_handoff_server: ?*win32_terminal_handoff.Server = null,
    undo_prune_timer_id: ?UINT_PTR = null,
    /// Thread timer that delivers program status notifications the rate
    /// limit held back. Only runs while one is waiting.
    program_status_notify_timer_id: ?UINT_PTR = null,
    recovery_retry_timer_id: ?UINT_PTR = null,
    /// Monotonic `GetTickCount64` deadline before which no tick may spend a
    /// ready-marker attempt. Cleared by the retry timer, which is the tick
    /// the deadline was waiting for.
    recovery_retry_not_before_ms: ?u64 = null,
    next_undo_sequence: u64 = 1,
    // App-scoped bindings from an empty host must retain their origin even
    // when pruning expires (and destroys) that host during dispatch.
    empty_host_key_id: ?u32 = null,
    running: bool = false,
    /// The session's last window has gone and its snapshot was taken as it
    /// went (`saveSessionAsItEnds`), however it went: its close, its last tab
    /// or pane, its last shell exiting, a quit. Nothing replaces that
    /// snapshot until a window, tab or undo brings the session back, which
    /// clears this (`Surface.init`, `restoreClosedTabEntry`). Set even when
    /// the write failed (the file then keeps the previous snapshot), and when
    /// a restore that failed was moved aside instead (`setAsideFailedRestore`).
    session_state_saved_before_last_host_close: bool = false,
    /// The startup restore brought the saved session back, and nothing has
    /// used it since: no input reached a running program
    /// (`Surface.noteProgramInput`) and no terminal opened after it
    /// (`Surface.init`). While this holds and every program the session
    /// shows has ended by itself, the session is a restore that failed
    /// (`sessionIsFailedRestore`) and is never saved back.
    restored_session_untouched: bool = false,
    /// Tests only: how many times `saveSessionAsItEnds` saved. Under test no
    /// save reaches the disk, and the flag above cannot tell a save from a
    /// close that left an earlier one standing.
    test_session_saves_as_it_ends: if (builtin.is_test) u32 else void = if (builtin.is_test) 0 else {},
    /// Tests only: how many times a restore that failed was to be moved
    /// aside (`setAsideFailedRestore`, past its sign-out check).
    test_failed_restores_set_aside: if (builtin.is_test) u32 else void = if (builtin.is_test) 0 else {},
    /// Set only in the process that restored the saved session, or was
    /// eligible to and started with its first window instead. Only that
    /// process saves `session-state.json` or moves it aside: a launch that
    /// forwarded to the primary, an Explorer "Open noctty here" window, an
    /// `-Embedding` handoff server or a second `single-instance = false`
    /// instance never loaded it, so writing their own windows over it
    /// destroys the user's workspace.
    session_owner: ?SessionOwnerLock = null,
    /// The saved session is not this build's to replace: a newer build wrote
    /// it, or it is larger than any session this build writes. This process
    /// neither restores it nor takes ownership, so it never saves over it or
    /// moves it aside.
    session_state_left_alone: bool = false,
    /// Set once WM_ENDSESSION(TRUE) has saved for a sign-out, shutdown or
    /// reboot, or for a Restart Manager close noctty agreed to. That snapshot
    /// is final: shells the logoff kills afterwards close their panes, and the
    /// saves those closes would run must not shrink it or move it aside.
    session_ending: bool = false,
    /// This process agreed to a Restart Manager close (`ENDSESSION_CLOSEAPP`)
    /// and no WM_ENDSESSION has settled it yet. Restart Manager asks every
    /// top-level window, so the later queries of the round re-run the checks
    /// but do not save again (`onQueryEndSession`).
    end_session_prepared: bool = false,
    /// WM_ENDSESSION(TRUE, ENDSESSION_CLOSEAPP) committed the close: the
    /// session is saved and latched, and the message loop runs `quitConfirmed`
    /// at its next turn (`finishEndSessionClose`). Until then a host's
    /// WM_CLOSE closes nothing, so Restart Manager's fallback cannot close the
    /// windows one at a time.
    end_session_quit_pending: bool = false,
    /// A Restart Manager query revoked the `-Embedding` server's class object
    /// to agree (`releaseHandoffForEndSession`); a decline, or a close called
    /// off, registers it again (`retakeHandoffAfterEndSession`).
    end_session_handoff_revoked: bool = false,
    /// Set as `run` enters its message loop: the startup restore and the
    /// first window are done.
    message_loop_started: bool = false,
    /// `RegisterApplicationRestart` ran for the Restart Manager close this
    /// process agreed to (`registerInstallerRestart`).
    restart_registered: bool = false,
    restart_api: RestartApi = .{},
    /// `GetTickCount64` of the last `checkpointSessionState`.
    session_checkpoint_ms: ?u64 = null,
    /// Thread timer that saves the session once a burst of structural
    /// changes settles (`scheduleSessionCheckpoint`).
    session_checkpoint_timer_id: ?UINT_PTR = null,
    /// True only while the app is synchronously draining every host during
    /// shutdown. Child HWND teardown still repairs native split trees, but it
    /// must not diagnose the intentionally absent per-pane close preflight as
    /// an ordinary-close invariant failure.
    quitting: bool = false,
    /// Host currently undergoing allocation-free failed-restore teardown.
    /// Its child WM_DESTROY callbacks remove Surface ownership only; Host
    /// tree disposal happens once, after the native cascade completes.
    session_restore_rollback_host: ?*Host = null,
    windows_hidden: bool = false,
    quick_terminal_keyboard_diagnostic_logged: bool = false,
    update_notice: ?UpdateNotice = null,
    /// The host whose banner button started the running update action, so
    /// its feedback lands in the window the user is looking at. Set only for
    /// the length of that synchronous call (`Host.activateBannerButton`).
    update_action_host: ?*Host = null,
    update_auto_check_started: bool = false,
    /// Repeating thread timer that re-runs the automatic check in a process
    /// that stays open for days. See `update_recheck_interval_ms`.
    update_recheck_timer_id: ?UINT_PTR = null,
    /// Detected on first use: the install directory cannot change under a
    /// running process.
    install_kind: ?InstallKind = null,
    /// The last Install is looked at once per run, when a window can show the
    /// result (`reportFailedInstallerApply`).
    installer_apply_checked: bool = false,
    /// Set when Install starts applying, so a second press that gets in while
    /// `ShellExecuteW` pumps messages cannot start a second Setup.
    update_apply_in_flight: bool = false,
    /// Set from the confirm's answer until the loop takes the apply off the
    /// queue, so a second answer in between queues nothing.
    update_apply_queued: bool = false,
    update_startup_ready: bool = false,
    /// Most-recently-used command palette actions; newest first. Strings
    /// are owned by `core_app.alloc` and freed in `App.deinit`. Surfaced
    /// by `commandPaletteBannerText` when the query is empty so users
    /// see their own recent picks instead of the static onboarding hint.
    palette_mru: [5]?[:0]const u8 = .{null} ** 5,
    /// Singleton settings window. Lazily created by the `open_config`
    /// action; `App.terminate` destroys the HWND if still alive.
    settings_window: win32_settings.SettingsWindow = undefined,
    settings_open_trace: bench_trace.SettingsOpenTrace = .{},
    /// Stable core surface id that owned focus when Settings opened. Settings
    /// itself clears terminal focus flags, so close must not guess host zero.
    settings_restore_surface_id: ?u64 = null,
    /// Whether `OleInitialize` actually took responsibility for the
    /// apartment on this thread. `OleUninitialize` only pairs with a
    /// successful init (`S_OK` / `S_FALSE`) — `RPC_E_CHANGED_MODE`
    /// means another component already set up COM and we must not
    /// touch it on the way down.
    com_initialized: bool = false,
    /// Kernel build number from `RtlGetVersion`. 0 if probe failed.
    /// 22000 = Win11 21H2; 22621 = Win11 22H2 (the floor for
    /// `DWMWA_SYSTEMBACKDROP_TYPE`, which host windows always write as
    /// `DWMSBT_NONE` — see `applyDwmThemeWithBuild`).
    /// Future chrome gates read this directly; no runtime config flag,
    /// per §12 Q1.
    os_build: u32 = 0,
    /// Top-level switch for the integrated-titlebar path
    /// (`WM_NCCALCSIZE` / `WM_NCHITTEST` state machine). Derived
    /// from the Win11 build floor via `shouldUseIntegratedTitlebar`;
    /// false keeps the stock non-client caption path.
    use_integrated_titlebar: bool = false,
    /// Last applied `window-show-tab-bar` visibility. Only
    /// `reconfigureTheme` reads it, to notice a reload that turned the tab
    /// strip on or off: the chrome children that live in the strip are shown
    /// and hidden by `layoutChromeForRect`, which a reload otherwise reaches
    /// only when the frame mode flips too (never on Win10).
    tab_bar_visible: bool = true,
    // Live-resize state is tracked PER HOST (`Host.is_live_resize`),
    // not per App. Dragging window A must NOT freeze renderer
    // invalidations for unrelated background windows B/C.
    /// Whether the current core-app tick already spent its one synchronous
    /// renderer paint. See `rendererTickRepaintMode`.
    renderer_sync_paint_spent: bool = false,
    /// Hyperlink hover-dwell tracker, meant to be reset via `dismiss()`
    /// whenever focus leaves a surface or a click arrives.
    ///
    /// Not driven yet: initialized here and in a test, but nothing calls
    /// `onMouseMove`, `tick` or `dismiss` outside its own tests, and the
    /// core's `mouse_over_link` action is a no-op in `performAction`. There is
    /// no link-preview tooltip on Windows (docs/status.md, "Link previews");
    /// wiring one is the work this field waits for.
    link_hover_tracker: win32_link_preview.HoverTracker = undefined,
    /// Windows Action Center toast notifier. `null` when WinRT init
    /// fails (e.g. corporate lockdown, missing combase.dll), in which
    /// case `showToast` falls back to the in-app banner path. One
    /// notifier per App, released in `App.terminate`.
    winrt_toast: ?win32_toast_winrt.WinrtToast = null,
    /// Where `showToast` sends toasts: `winrt_toast` in the product, a
    /// recorder in tests, so no test can reach Action Center. `null`
    /// sends every notification to the banner fallback.
    toast_sink: ?ToastSink = null,
    /// Panes (core surface ids, never pointers) whose toast is to be taken
    /// out of Action Center, oldest first. Flushed from the posted
    /// `WM_WINHOSTTY_TOAST_REMOVALS`: a history call is a cross-process COM
    /// call that can pump messages, so it never runs inside the window
    /// activation, focus or close that queued it.
    toast_removals: std.ArrayListUnmanaged(u64) = .empty,
    /// `WM_WINHOSTTY_TOAST_REMOVALS` is posted and not yet handled.
    toast_removals_posted: bool = false,
    /// This process showed a tagged toast, so its group may hold toasts
    /// to remove at exit.
    toast_group_used: bool = false,
    /// Taskbar progress COM object. `null` when the taskbar API is
    /// unavailable, in which case progress continues to render only in
    /// the window title/status text.
    taskbar_progress: ?win32_taskbar_progress.TaskbarProgress = null,
    /// Rate limit for program status (OSC 7501) notifications across all
    /// windows; each surface keeps its own last notification time too.
    program_status_notify: win32_program_status.NotifyLimiter = .{},
    /// Persisted taskbar destinations and their debounced shell COM commit.
    /// `null` when the app-state path cannot be resolved or initialized.
    jump_list: ?win32_jump_list.JumpList = null,
    /// Absolute path supplied via `--config-file=<path>` on the CLI.
    /// Resolved ONCE against the startup cwd during `App.init` — that's
    /// important because `run()` later calls `sanitizeCurrentDirectory()`,
    /// which can reset cwd to `%USERPROFILE%`. If we resolved the
    /// relative path at save time, we'd end up writing to a different
    /// file than the one `Config.load()` used at launch.
    cli_config_override_path: ?[]u8 = null,
    /// The last `--visual-studio-profiles=` argument on noctty's command
    /// line, as written, which a Visual Studio shell's jump-list link passes
    /// on (`cliVisualStudioProfilesArg`). Null when the files decide it.
    cli_visual_studio_profiles_arg: ?[]u8 = null,
    /// The value of the launch argv's last `--class=`, read at `App.init`
    /// (`cliClass`), for the installer restart's command line.
    cli_class: ?[]u8 = null,
    /// The file the last failed Settings save names in its status line.
    settings_failure_detail: win32_settings.FailureDetail = .{},
    /// The config keys the last Settings save wrote that a later layer
    /// overrides, comma separated, for its status line and notification.
    settings_masked_keys: win32_settings.FailureDetail = .{},
    /// What the config last loaded (startup, reload, Settings save) found
    /// wrong, and the fonts it names that no installed font matches. Copies:
    /// the config that held the diagnostics is gone after a reload.
    config_problems: win32_config_problems.Problems = .{},
    /// The text of the banner raised for `config_problems`, so a reload that
    /// finds none can take that banner down, and only that one.
    config_problems_banner: ?[]u8 = null,
    /// Startup-time cwd snapshot. `Config.load()` resolves relative
    /// `--config-file` argv entries via realpath-against-cwd, so any
    /// reload that happens after `sanitizeCurrentDirectory()` would
    /// resolve those entries against the sanitized cwd and end up
    /// reading a different file than launch did. We `std.fs.cwd()`
    /// chdir back to this value around `settingsSaveAndReload`'s
    /// reload so argv-relative paths re-resolve identically.
    startup_cwd: ?[]u8 = null,
    /// A toast activation waiting for a window: the one a cold
    /// `-ToastActivated` start received (`awaitColdToastActivation`), a
    /// `wgh://activate?...` argument, or one that arrived while no surface
    /// existed. Consumed once after the first window spawns. Its ids are
    /// resolved only when its pid is this process's
    /// (`resolveToastActivationSurface`); otherwise the primary surface is
    /// presented.
    pending_toast_activation: ?win32_toast_activation.ActivationTarget = null,
    /// Started by COM for a click in Action Center (`win32_toast_activator`,
    /// argv `-ToastActivated -Embedding`): `run` waits for the launch string
    /// before deciding whether to forward it or start locally.
    toast_activated: bool = false,
    /// What a cold `-ToastActivated` start received, forwarded to the running
    /// instance in place of this process's argv
    /// (`ipc_server.tryForwardStartupToExistingInstance`).
    cold_toast_activation: ?win32_toast_activation.ActivationTarget = null,
    /// Drops the second delivery of one click (popup handler and COM).
    toast_click_filter: win32_toast_activation.RepeatFilter = .{},
    /// `run` has made its startup windows (or decided on none), so a toast
    /// click with no surface to present opens one
    /// (`receiveToastActivation`).
    startup_windows_opened: bool = false,
    /// The command line's one-shot `--launch-layout=<name>`, which `run`
    /// opens instead of the first window (or forwards to the running
    /// instance). `init` moves it here out of the app config
    /// (`claimStartupLaunchLayout`), because every app config change drops
    /// `launch-layout` as a request already honored, and on a dark system
    /// `init`'s own color-scheme sync is one.
    startup_launch_layout: StartupLaunchLayout = .none,
    /// Ephemeral recovery launch: default config, no saved workspace restore.
    safe_mode: bool = false,
    /// COM SCM activation for the Windows default-terminal handoff server.
    /// This process owns adopted sessions directly; raw HANDLE values are
    /// never forwarded through the serialized single-instance IPC channel.
    embedding_mode: bool = false,
    recovery_startup: RecoveryStartup = .{},
    /// True once this launch is recorded on disk as resolved — either the
    /// ready marker landed or its bounded retries were exhausted.
    recovery_ready_resolved: bool = false,
    recovery_ready_retry: RecoveryReadyRetry = .{},
    recovery_safe_mode_notice: RecoverySafeModeNotice = .{},
    /// Top-level shell composition only. Terminal child HWNDs retain their
    /// existing WGL/SwapBuffers ownership regardless of this backend state.
    shell_compositor_driver: win32_compositor_native.NativeDriver = undefined,
    shell_compositor: win32_compositor.Backend = undefined,
    shell_compositor_initialized: bool = false,
    shell_runtime: win32_shell.runtime.Runtime = undefined,
    shell_runtime_initialized: bool = false,
    /// Release builds warn about a shell/native divergence at most once per
    /// `shell_audit_warn_interval_ms`.
    shell_audit_warning: RateLimitedWarning = .{},
    /// A tab or split was created in an existing window; the activation
    /// that shows it audits the shell/native mapping (`Surface.init`).
    shell_audit_after_activation: bool = false,

    const DeferredOpen = union(enum) {
        target: []u8,
        text_editor: struct { path: []u8, from_settings: bool },
        on_screen_keyboard,
        /// Install or Apply, once it is confirmed: `applyStagedUpdate` reaches
        /// `ShellExecuteW`, so it runs from the loop like the opens do.
        apply_staged_update,
        elevated_window: struct { parameters: [:0]u8, cwd: ?[]const u8 },

        fn deinit(self: DeferredOpen, alloc: Allocator) void {
            switch (self) {
                .target => |target| alloc.free(target),
                .text_editor => |request| alloc.free(request.path),
                .elevated_window => |launch| {
                    alloc.free(launch.parameters);
                    if (launch.cwd) |cwd| alloc.free(cwd);
                },
                .on_screen_keyboard, .apply_staged_update => {},
            }
        }
    };

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        opts: struct { safe_mode: bool = false },
    ) !void {
        const com_start = ComStart.ofProcess(core_app.alloc);
        const toast_activated = com_start == .toast_activator;
        const embedding_mode = com_start == .terminal_handoff;
        const is_elevated = win32_elevation.isProcessElevated() catch |err| elevated: {
            log.warn(
                "failed to query TokenElevation; treating process as elevated for title and IPC isolation err={}",
                .{err},
            );
            break :elevated true;
        };
        const session_state_excluded_for_elevation = if (is_elevated) excluded: {
            const elevation_type = win32_elevation.processTokenElevationType() catch |err| {
                log.warn(
                    "failed to query TokenElevationType; disabling session state because an elevated process with an unknown elevation type must fail closed err={}",
                    .{err},
                );
                break :excluded win32_elevation.excludesSessionState(is_elevated, null);
            };
            break :excluded win32_elevation.excludesSessionState(
                is_elevated,
                elevation_type,
            );
        } else false;
        const recovery_startup = if (embedding_mode)
            RecoveryStartup{}
        else
            beginRecoveryStartup(core_app.alloc, session_state_excluded_for_elevation);
        const safe_mode = opts.safe_mode or recovery_startup.decision != .normal;
        self.* = .{
            .core_app = core_app,
            .config = if (safe_mode) config: {
                var config = try configpkg.Config.default(core_app.alloc);
                errdefer config.deinit();
                // Recovery runs `cmd /D`, which loads no profile and skips AutoRun,
                // and so needs no PATH search.
                try pane_launch.useRecovery(&config);
                try config.finalize();
                break :config config;
            } else try configpkg.Config.load(core_app.alloc),
            .is_elevated = is_elevated,
            .session_state_excluded_for_elevation = session_state_excluded_for_elevation,
            .safe_mode = safe_mode,
            .embedding_mode = embedding_mode,
            .toast_activated = toast_activated,
            .recovery_startup = recovery_startup,
            .hinstance = sys.GetModuleHandleW(null),
            .launcher_profile_hint = detectDefaultProfileHint(core_app.alloc),
            .launcher_profile_target = detectDefaultProfileTarget(core_app.alloc),
            .startup_profile_picker = detectStartupProfilePicker(core_app.alloc),
            .explicit_startup_working_directory = detectExplicitStartupWorkingDirectory(core_app.alloc),
        };
        // Install before any host window exists, so the very first
        // SetWinEventHook registration already has somewhere to deliver.
        win32.cloak_event_app = self;
        win32_power.setCloakEventHandler(&onHostCloakEvent);
        if (self.session_state_excluded_for_elevation and
            self.config.@"window-save-state" != .never)
        {
            log.info(
                "win32 session state disabled: elevated process whose token is TokenElevationTypeFull (split-token elevated) or whose elevation type could not be queried",
                .{},
            );
        }
        if (self.config.@"background-blur".win32BlurRequested()) logBackgroundBlurUnsupported();
        warnPortableIgnoredLocalData(core_app.alloc);
        // Snapshot the CLI --config-file override BEFORE any code has
        // a chance to chdir. See the field comment above.
        self.cli_config_override_path = cliConfigFileOverride(core_app.alloc) catch null;
        self.cli_visual_studio_profiles_arg = cliVisualStudioProfilesArg(core_app.alloc) catch null;
        self.cli_class = cliClass(core_app.alloc) catch null;
        // Snapshot the startup cwd for reload-time restoration.
        self.startup_cwd = std.process.getCwdAlloc(core_app.alloc) catch null;
        // A `wgh://activate?...` argument on the command line. Windows never
        // starts noctty with one: a click in Action Center reaches a cold
        // start through COM (`-ToastActivated`, `awaitColdToastActivation`).
        // It is honored for a launch by hand or a script, and the same string
        // is what a cold start forwards to a running instance. Silent on
        // absence or malformed input.
        self.pending_toast_activation = scanToastActivationArg(core_app.alloc);
        if (self.pending_toast_activation) |target| {
            log.info("toast activation received surface={?} tab={?} window={?} action={?}", .{
                target.surface_id,
                target.tab_id,
                target.window_id,
                target.action,
            });
        }
        // AUMID registration MUST precede any HWND creation so
        // taskbar-grouping / toast attribution picks up our identity
        // on the first window. Both swallow failures (warn +
        // continue) — toasts and taskbar grouping are non-essential
        // for basic terminal function.
        win32_aumid.setProcessAumid();
        {
            const state = localAppDataPathAlloc(core_app.alloc, win32_jump_list.state_filename);
            defer if (state) |path| core_app.alloc.free(path);
            // Not `isPortableModeActive`, which answers "installed" when
            // copying the root fails; this cached answer cannot fail.
            self.jump_list = claimSharedIdentity(
                core_app.alloc,
                internal_os.xdg.portableModeActive(),
                &win32_aumid.registerAumidDisplayName,
                state,
            );
        }

        // Be asked to end before the shells under it. Every process starts at
        // the default level 0x280, and Windows ends processes on one level
        // in no set order, so a sign-out could otherwise end the shells
        // first: each pane closes, and the last one's close would save a
        // shrunken snapshot (or move aside a restore nobody had used) before
        // WM_ENDSESSION could save the whole session. A higher level is
        // ended first.
        if (sys.SetProcessShutdownParameters(0x2FF, 0) == 0) {
            log.warn("win32 SetProcessShutdownParameters failed err={}", .{windows.GetLastError()});
        }

        // Boot the WinRT toast notifier. Failure falls back to the
        // host banner/log path in `showToast`.
        // MUST run AFTER `setProcessAumid` so `CreateToastNotifierWithId`
        // attributes toasts to our AUMID. A test build never creates one, so
        // no test can reach Action Center; tests install a recorder as
        // `toast_sink` instead.
        const aumid_utf16 = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");
        self.winrt_toast = if (builtin.is_test) null else win32_toast_winrt.WinrtToast.init(core_app.alloc, aumid_utf16) catch |err| blk: {
            std.log.warn("winrt toast init failed err={}; falling back to host notifications", .{err});
            break :blk null;
        };
        if (self.winrt_toast) |*toast| self.toast_sink = .winrt(toast);

        // Install the PowerShell shell-integration script into
        // %LOCALAPPDATA%\noctty\shell-integration\powershell\
        // if missing or the on-disk hash doesn't match the embedded
        // payload (forces updates when we ship a new version). This
        // keeps the manual `$PROFILE` fallback on a stable path even
        // though automatic injection now uses the resources-tree copy
        // for interactive PowerShell launches.
        //
        // Skipped in unit tests for the same reason `localAppDataPathAlloc`
        // is: a test that starts a real `App` would otherwise overwrite the
        // developer's own copy with whatever branch is under test, and that
        // copy is what a hand-written `$PROFILE` dot-source loads.
        if (!builtin.is_test) {
            if (win32_powershell_install.resolveInstallPath(core_app.alloc)) |ps1_path| {
                defer core_app.alloc.free(ps1_path);
                const result = win32_powershell_install.installIfStale(core_app.alloc, ps1_path);
                log.info("powershell integration install path={s} result={s}", .{ ps1_path, @tagName(result) });
            } else |err| {
                std.log.warn("powershell integration install path resolve failed err={}", .{err});
            }
        }

        // Install our compiled terminfo entry where Git for Windows' ncurses
        // tools find it, for TERM=xterm-ghostty (win32_terminfo.zig). Not in
        // portable mode, which leaves nothing on the host; not when `term`
        // names some other entry; and not in unit tests, which must not write
        // into the developer's profile.
        if (!builtin.is_test and !isPortableModeActive(core_app.alloc)) {
            installTerminfo(core_app.alloc, self.config.term);
        }

        // Windows version probe. Win11 build 22000+ enables the
        // integrated-titlebar path; older builds stay on the stock
        // non-client caption/buttons path.
        self.os_build = probeWindowsBuild();
        self.use_integrated_titlebar = shouldUseIntegratedTitlebar(
            self.os_build,
            self.config.@"window-show-tab-bar",
        );
        self.tab_bar_visible = tabBarVisibleForConfig(self.config.@"window-show-tab-bar");
        log.info("win32 os_build={d} integrated_titlebar={}", .{
            self.os_build,
            self.use_integrated_titlebar,
        });
        if (recovery_startup.decision != .normal and !opts.safe_mode) {
            log.warn("win32 recovery: repeated incomplete startups selected safe mode", .{});
        }

        self.initComApartment();
        self.taskbar_progress = win32_taskbar_progress.TaskbarProgress.init() catch |err| blk: {
            std.log.warn("taskbar progress init failed err={}; falling back to title-only progress", .{err});
            break :blk null;
        };
        self.refreshSystemWheelSettings();
        self.refreshSystemScrollbarPreference();
        self.resolved_theme = resolveTheme(&self.config);
        self.loadPaletteMru();
        self.settings_window = win32_settings.SettingsWindow.init(.{
            .ctx = @ptrCast(self),
            .alloc = core_app.alloc,
            .hinstance = self.hinstance,
            .ownerWindow = &settingsOwnerWindowThunk,
            .appIcon = &settingsAppIconThunk,
            .chromeBg = &settingsChromeBgThunk,
            .textPrimary = &settingsTextPrimaryThunk,
            .themeColors = &settingsThemeColorsThunk,
            .highContrast = &settingsHighContrastThunk,
            .openInEditor = &settingsOpenInEditorThunk,
            .copyText = &settingsCopyTextThunk,
            .currentConfig = &settingsCurrentConfigThunk,
            .saveAndReload = &settingsSaveAndReloadThunk,
            .configRevision = &settingsConfigRevisionThunk,
            .previewField = &settingsPreviewFieldThunk,
            .notifyConflict = &settingsNotifyConflictThunk,
            .reconcileDisk = &settingsReconcileDiskThunk,
            .failureDetail = &settingsFailureDetailThunk,
            .maskedKeys = &settingsMaskedKeysThunk,
            .saveTarget = &settingsSaveTargetThunk,
            .configSource = &settingsConfigSourceThunk,
            .configProblems = &settingsConfigProblemsThunk,
            .profileChoices = &settingsProfileChoicesThunk,
            .notifySuccess = &settingsNotifySuccessThunk,
            .customUiaProvidersEnabled = &settingsCustomUiaProvidersEnabledThunk,
            .deferUiaDisconnect = &settingsDeferUiaDisconnectThunk,
            .onClosed = &settingsOnClosedThunk,
            .queryEndSession = &settingsQueryEndSessionThunk,
            .endSession = &settingsEndSessionThunk,
        });
        self.link_hover_tracker = win32_link_preview.HoverTracker.init();
        // The D3D11/DirectComposition/DirectWrite shell compositor is not
        // started: the backend gets no driver and no capability probe, so it
        // stays in its fallback state and the attach, resize and render
        // helpers below are no-ops. Building its device graph here put a
        // hardware D3D11 device on the UI thread before the first window,
        // and kept about 80 driver threads and tens of MB alive, for
        // explicit banner text only (PKG-33). The device-graph code stays
        // until the D3D11 renderer decision settles whether it is reused.
        self.shell_compositor_driver = win32_compositor_native.NativeDriver.init(core_app.alloc);
        self.shell_compositor = win32_compositor.Backend.init(.{}, null);
        self.shell_compositor_initialized = true;
        self.shell_runtime = win32_shell.runtime.Runtime.init(core_app.alloc);
        self.shell_runtime_initialized = true;

        self.syncStartupConfig();
        self.settings_open_trace = bench_trace.SettingsOpenTrace.init(core_app.alloc);
    }

    /// The end of `init`. Core conditional configuration defaults to light,
    /// so it is synchronized with Windows before the first surface is
    /// created, and conditional themes and terminal color-scheme reports
    /// start on the right branch. No surfaces or hosts exist yet: the
    /// resulting app config change is intentionally valid before `run`, and
    /// its topology loops are empty. The command line's `launch-layout` is
    /// claimed first, because on a dark system that change drops it from the
    /// app config (`claimStartupLaunchLayout`). Nothing earlier in `init`
    /// installs an app config.
    fn syncStartupConfig(self: *App) void {
        self.claimStartupLaunchLayout();
        self.syncSystemColorScheme() catch |err| {
            log.warn("initial win32 color scheme sync failed err={}", .{err});
        };
    }

    /// Bring OLE and its STA apartment online for in-process COM consumers
    /// (settings path picker via `IFileOpenDialog`, WinRT toast setup,
    /// OLE drag-drop). Pair each successful call with OleUninitialize —
    /// `S_FALSE` means "already initialised in this mode", and
    /// `RPC_E_CHANGED_MODE` means "already initialised in a different
    /// mode" and leaves STA-only consumers disabled.
    pub fn initComApartment(self: *App) void {
        const hr = sys.OleInitialize(null);
        switch (hr) {
            0, 1 => self.com_initialized = true, // S_OK, S_FALSE
            c.RPC_E_CHANGED_MODE => {
                std.log.warn("COM apartment: already MTA on this thread; STA consumers may fail", .{});
            },
            else => {
                std.log.warn("COM apartment: OleInitialize failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            },
        }
    }

    pub const StartupLaunchLayout = union(enum) {
        none,
        /// Owned by `core_app.alloc`.
        name: []u8,
        /// Asked for, but the name could not be copied. Still a layout
        /// request: taken for none, it would make the launch restore and own
        /// the session, open nothing under `initial-window = false`, or
        /// forward as a plain new window.
        lost,
    };

    /// Move the command line's `launch-layout` out of the app config into
    /// `startup_launch_layout`, for `run`. Left in the config, it would not
    /// last until `run`: the `.app` `config_change` arm drops it from every
    /// config it installs (a reload parses the original argv again), and on
    /// a dark system the color-scheme sync at the end of `init` soft-reloads.
    pub fn claimStartupLaunchLayout(self: *App) void {
        const name = self.config.@"launch-layout" orelse return;
        self.startup_launch_layout = if (self.core_app.alloc.dupe(u8, name)) |owned|
            .{ .name = owned }
        else |err| lost: {
            log.warn("startup launch-layout name could not be kept err={}", .{err});
            break :lost .lost;
        };
        forgetLaunchLayout(&self.config);
    }

    /// Done with the startup layout request, tried or not.
    pub fn releaseStartupLaunchLayout(self: *App) void {
        switch (self.startup_launch_layout) {
            .name => |name| self.core_app.alloc.free(name),
            .none, .lost => {},
        }
        self.startup_launch_layout = .none;
    }

    /// Open the command line's layout as the first window, if it asked for
    /// one, and say whether it did. It is honored even when `initial-window`
    /// is disabled, because the user asked for this exact window, and it
    /// takes the place of session restore. It is also one-shot: `init` took
    /// it out of the app config, every config installed since drops it
    /// (`forgetLaunchLayout`), and it is released here once tried, so later
    /// ordinary new windows and reloads cannot replay it. A layout that
    /// cannot be opened, or whose name was lost, gets an ordinary window
    /// that says so.
    pub fn openStartupLaunchLayout(self: *App) !bool {
        const launched = switch (self.startup_launch_layout) {
            .none => return false,
            .name => |name| self.launchNamedLayout(name, null),
            .lost => false,
        };
        self.releaseStartupLaunchLayout();
        if (!launched) {
            // Handled, as for a skipped restore window.
            gl_startup.clearOpenGLStartupFailure();
            try self.createWindow(default_title);
            if (self.registry.primarySurface()) |surface| if (surface.host) |host| {
                host.setBanner(.err, "Layout could not be opened.") catch {};
            };
        }
        return true;
    }

    /// Drop a command-line `launch-layout` from `config`, which is about to
    /// be, or already is, the long-lived app config: the request is
    /// one-shot. The replay steps go too: `finalize` -> `loadTheme` and
    /// `changeConditionalState` replay `_replay_steps` through `loadIter`,
    /// and a per-window clone inherits that history, so a surviving step
    /// would turn a later ordinary new window into a layout launch.
    pub fn forgetLaunchLayout(config: *configpkg.Config) void {
        config.@"launch-layout" = null;
        _ = config.dropLaunchLayoutReplaySteps(0);
    }

    /// Whether the WM_TIMER `msg` is the tick of thread timer `timer_id`;
    /// call it only for WM_TIMER. A thread timer (`SetTimer(null, ...)`)
    /// posts with a null hwnd. Checking that keeps a window timer whose
    /// numeric id happens to collide from being taken.
    fn threadTimerFired(msg: *const MSG, timer_id: ?UINT_PTR) bool {
        const id = timer_id orelse return false;
        return @intFromPtr(msg.hwnd) == 0 and msg.wParam == id;
    }

    /// Kill the thread timer in `timer_id`, if one is armed, and forget it.
    pub fn killThreadTimer(timer_id: *?UINT_PTR) void {
        const id = timer_id.* orelse return;
        _ = sys.KillTimer(null, id);
        timer_id.* = null;
    }

    pub fn run(self: *App) !void {
        try self.sanitizeCurrentDirectory();
        const cwd = std.process.getCwdAlloc(self.core_app.alloc) catch null;
        defer if (cwd) |v| self.core_app.alloc.free(v);
        if (cwd) |v| {
            log.debug("win32 current directory cwd={f}", .{internal_os.redact.bytes(v)});
        }

        try self.ensureWindowClass();

        // Declared first so it runs last, after the message window (whose
        // channel the activator posts to) is closed.
        defer win32_toast_activator.revoke();
        if (self.toast_activated) {
            const activation = self.awaitColdToastActivation();
            self.cold_toast_activation = activation;
            // Forwarded below, or presented once the first window exists.
            self.pending_toast_activation = activation;
        }

        const forwarded = if (self.embedding_mode or self.safe_mode)
            false
        else
            ipc_server.tryForwardStartupToExistingInstance(self) catch |err| switch (err) {
                // A busy or rejecting primary must not turn this launch into
                // false crash-loop evidence. Continue as a local instance.
                error.IPCFailed => failed: {
                    log.warn("win32 startup forwarding failed; continuing locally", .{});
                    break :failed false;
                },
                else => return err,
            };
        if (forwarded) {
            // Forwarding is a successful startup outcome for this process.
            // Mark it ready so repeated new-window launches cannot accumulate
            // false crash-loop evidence and trigger automatic safe mode.
            // This process exits immediately, so there is no later tick to
            // retry on; the failure is logged and the attempt stays unresolved.
            self.markRecoveryReady() catch |err| {
                log.warn("win32 recovery: forwarded launch ready marker failed err={}", .{err});
            };
            return;
        }

        self.running = true;
        const ui_thread_id = sys.GetCurrentThreadId();
        ensureMessageQueue();
        try self.openAppWindows();
        @atomicStore(DWORD, &self.ui_thread_id, ui_thread_id, .release);
        // Nothing since the cold wait has pumped messages, so a second
        // `Activate` COM queued meanwhile is dispatched only after this binds
        // the App channel.
        self.startToastActivator();
        defer {
            self.stopUndoPruneTimer();
            self.stopQuitTimer();
            self.stopTerminalHandoffIdleTimer();
            self.stopRecoveryRetryTimer();
            self.stopProgramStatusNotifyTimer();
            self.stopUpdateRecheckTimer();
            self.stopProfileDiscoveryWatchdog();
            @atomicStore(DWORD, &self.ui_thread_id, 0, .release);
            if (self.pending_profile_discovery) |pending| pending.deinit();
            self.pending_profile_discovery = null;
            self.closeAppWindows();
            self.running = false;
        }

        var terminal_handoff_server: ?win32_terminal_handoff.Server = null;
        defer if (terminal_handoff_server) |*server| {
            self.terminal_handoff_server = null;
            _ = server.revoke();
            server.drainPending();
        };
        if (self.embedding_mode) {
            if (!self.com_initialized) return error.ComApartmentUnavailable;
            terminal_handoff_server = win32_terminal_handoff.Server.init(
                self.core_app.alloc,
                self,
                queueTerminalHandoff,
            );
            // Publish before registering: once the class object is live a
            // client can activate it, and the session queue has to be
            // reachable from the very first handoff.
            self.terminal_handoff_server = &terminal_handoff_server.?;
            try terminal_handoff_server.?.register();
            win32_terminal_handoff.appendHandoffMilestone(self.core_app.alloc, "server_registered");
            self.startTerminalHandoffIdleTimer();
        }

        // Safe mode is an isolated recovery process. It neither forwards into
        // the normal instance nor competes for that instance's IPC endpoint.
        if (!self.embedding_mode and !self.safe_mode and try ipc_server.startIpcServer(self)) {
            // Lost the first-instance race and the retry forward succeeded:
            // same successful-startup outcome as the forward above, and the
            // same reason the marker failure is only logged.
            self.markRecoveryReady() catch |err| {
                log.warn("win32 recovery: forwarded launch ready marker failed err={}", .{err});
            };
            return;
        }

        // A launch whose first window fails because OpenGL could not start is
        // not a crash, and safe mode starts the same renderer: three of them
        // must not strand the user there. Only this stretch: a later error
        // is no startup failure, and once the ready marker has merged other
        // instances' attempts, this one is no longer the last in memory.
        var initial_windows_created = false;
        errdefer if (!initial_windows_created) self.markRecoveryOpenGLUnavailable();
        if (self.embedding_mode) {
            // Every window comes from a terminal handoff.
        } else if (try self.openStartupLaunchLayout()) {
            // The command line's layout, or the window saying it failed.
        } else if (self.config.@"initial-window" or self.toast_activated) {
            // A toast click that started this process gets a window to bring
            // forward even under `initial-window = false`.
            // Ownership starts only once the first window exists: a launch
            // that fails here must not save over, on its way out, the session
            // it could not bring back, and a save while restore is half done
            // would keep only the windows restored so far.
            const owner_lock = if (self.sessionRestoreEligible()) self.acquireSessionOwnerLock() else null;
            errdefer if (owner_lock) |lock| lock.release();
            const restored = if (owner_lock != null) try self.restoreSessionState() else false;
            if (!restored) try self.createWindow(default_title);
            self.adoptSessionOwner(owner_lock);
            if (!restored and self.startup_profile_picker) {
                if (self.registry.primarySurface()) |surface| {
                    if (surface.host) |host| _ = host.toggleProfileOverlay();
                }
            }
        } else {
            log.info("initial-window is disabled; win32 runtime waiting without a window", .{});
        }
        initial_windows_created = true;
        self.startup_windows_opened = true;

        // Keep the banner text even without an initial window: every later
        // host receives its own copy when it is created.
        _ = self.reportConfigProblems(&self.config);

        // Armed here, released by `resolveRecoveryStartup` once the ready
        // marker is on disk. Spawning it here would let thread scheduling put
        // the modal on screen while the ledger still holds an unresolved
        // attempt, so killing the process at the dialog would preserve the
        // failure streak.
        self.recovery_safe_mode_notice.arm(self.recovery_startup.decision);

        if (!self.embedding_mode) self.initializeJumpList();
        if (!self.embedding_mode) self.scheduleGlobalHotkeySync();
        if (!self.embedding_mode and self.registry.windows.items.len == 0) {
            self.syncDirtyGlobalHotkeys();
            self.startQuitTimer();
        }

        // Initial window creation must not start a check until the swapped
        // build is healthy and authoritative. Later windows retain the usual
        // scheduling path through update_startup_ready.
        //
        // Updater bookkeeping must not be able to stop the terminal from
        // opening. Every failure here is about the state file, the stage
        // directory, or a lock — none of it says the running build is
        // unusable, and returning would exit before the message loop with no
        // window ever shown. Log it and continue; staging and apply both
        // re-check the transaction phase and fail closed on their own.
        updatepkg.confirmPortableUpdateStartup(
            self.core_app.alloc,
            build_config.version_string,
        ) catch |err| {
            log.warn("portable update startup confirmation failed err={}", .{err});
        };
        self.update_startup_ready = true;
        // Before the check below: staging compares the state it started from
        // with the state it finishes in, and this clears a field in it.
        if (self.registry.windows.items.len > 0) self.reportFailedInstallerApply();
        if (self.registry.windows.items.len > 0) self.maybeScheduleAutomaticUpdateCheck();
        const portable_failure = updatepkg.takePortableUpdateFailure(self.core_app.alloc) catch |err| failure: {
            log.warn("failed to read portable update failure err={}", .{err});
            break :failure null;
        };
        if (portable_failure) |message| {
            defer self.core_app.alloc.free(message);
            self.showUpdateInfo(.err, message) catch |err| {
                log.warn("failed to surface portable update failure err={}", .{err});
            };
        }

        // Guarantee the loop reaches at least one tick. Resolving this launch
        // in the ledger and releasing the safe-mode notice both hang off
        // `tickCoreApp`, so neither may depend on some other subsystem
        // happening to post a wake first.
        self.wakeup();

        var msg: MSG = undefined;
        self.message_loop_started = true;
        while (true) {
            // Opens queued while the previous message was handled run here,
            // with no window procedure on the stack.
            if (try self.drainDeferredOpens()) break;
            if (try self.finishEndSessionClose()) break;
            self.drainPendingHandoffs();
            self.applyPendingProfileDiscovery();

            const result = sys.GetMessageW(&msg, null, 0, 0);
            if (result == -1) return lastError();
            if (result == 0) break;
            self.showPendingConPtyFallbackBanner();

            if (msg.message == c.WM_TIMER) {
                if (self.recovery_retry_timer_id) |timer_id| {
                    if (msg.wParam == timer_id) {
                        self.onRecoveryRetryTimer();
                        continue;
                    }
                }
                if (self.terminal_handoff_idle_timer_id) |timer_id| {
                    if (msg.wParam == timer_id) {
                        self.stopTerminalHandoffIdleTimer();
                        self.drainPendingHandoffs();
                        if (self.embedding_mode and self.registry.windows.items.len == 0) {
                            if (self.exitEmbeddingServerIfIdle()) {
                                log.info("terminal handoff server idle timeout", .{});
                                self.running = false;
                                sys.PostQuitMessage(0);
                            } else {
                                self.startTerminalHandoffIdleTimer();
                            }
                        }
                        continue;
                    }
                }
                // Our timer is a thread timer (`SetTimer(null, ...)`), which
                // posts with a null hwnd. Checking that keeps us from
                // swallowing a window timer whose numeric id happens to
                // collide.
                if (self.jump_list) |*jump_list| {
                    if (@intFromPtr(msg.hwnd) == 0 and jump_list.handleTimer(msg.wParam)) {
                        // Profile discovery is app-wide, so any host will do —
                        // `initial-window=false` starts without a primary
                        // surface. The request stays pending until one exists.
                        if (self.registry.hosts.items.len > 0 and
                            jump_list.startupProfileDiscoveryPending())
                        {
                            const host = self.registry.hosts.items[0];
                            if (host.profiles != null and host.profiles_complete) {
                                jump_list.completeStartupProfileDiscovery();
                            } else {
                                self.startProfileDiscovery();
                            }
                        }
                        continue;
                    }
                }
                if (self.quit_timer_id) |timer_id| {
                    if (msg.wParam == timer_id) {
                        self.stopQuitTimer();
                        if (self.running and !self.hasLiveUiWindows() and self.config.@"quit-after-last-window-closed") {
                            self.running = false;
                            sys.PostQuitMessage(0);
                        }
                        continue;
                    }
                }
                if (self.undo_prune_timer_id) |timer_id| {
                    if (msg.wParam == timer_id) {
                        self.stopUndoPruneTimer();
                        self.pruneUndoHistoryNow();
                        continue;
                    }
                }
                if (threadTimerFired(&msg, self.program_status_notify_timer_id)) {
                    self.flushProgramStatusNotifications();
                    continue;
                }
                if (threadTimerFired(&msg, self.session_checkpoint_timer_id)) {
                    self.onSessionCheckpointTimer();
                    continue;
                }
                if (threadTimerFired(&msg, self.update_recheck_timer_id)) {
                    self.onUpdateRecheckTimer();
                    continue;
                }
                if (threadTimerFired(&msg, self.profile_discovery_watchdog_id)) {
                    self.stopProfileDiscoveryWatchdog();
                    const pending = if (self.jump_list) |*jump_list| jump_list.startupProfileDiscoveryPending() else false;
                    if ((pending or self.anyHostRequestedProfiles()) and self.registry.hosts.items.len > 0) self.startProfileDiscovery();
                    continue;
                }
            }

            if (msg.message == c.WM_HOTKEY) {
                self.handleGlobalHotkey(@intCast(msg.wParam));
                continue;
            }

            // The settings surface is a modeless native dialog. Route its
            // keyboard messages through the system dialog manager so Tab,
            // Shift+Tab, arrow-key radio navigation, and default buttons use
            // standard Win32 accessibility semantics.
            if (self.settings_window.hwnd) |settings_hwnd| {
                // The dialog manager consumes Tab and the arrow keys here and
                // never dispatches them to the control that gains focus, so
                // the settings window learns about keyboard navigation from
                // the pump, not from its controls.
                self.settings_window.noteInputMessage(msg.hwnd, msg.message, msg.wParam);
                // Ctrl+S is not a dialog-manager key; take it before the
                // manager sees it. Tab and the arrows still go to the manager.
                if (self.settings_window.handleAccelerator(msg.hwnd, msg.message, msg.wParam, msg.lParam)) {
                    try self.tickCoreApp();
                    continue;
                }
                if (sys.IsDialogMessageW(settings_hwnd, &msg) != 0) {
                    try self.tickCoreApp();
                    continue;
                }
            }

            _ = sys.TranslateMessage(&msg);
            _ = sys.DispatchMessageW(&msg);

            if (try self.finishLoopStep()) break;
        }
    }

    /// What the message loop does after it dispatched a message: sync the
    /// global hotkeys if they changed, then tick the core. Returns whether
    /// the loop should exit.
    fn finishLoopStep(self: *App) !bool {
        self.syncDirtyGlobalHotkeys();
        try self.tickCoreApp();
        return !self.running and self.registry.windows.items.len == 0;
    }

    pub fn terminate(self: *App) void {
        defer self.settings_open_trace.deinit();
        self.stopUndoPruneTimer();
        self.stopQuitTimer();
        self.stopTerminalHandoffIdleTimer();
        self.stopRecoveryRetryTimer();
        self.stopProgramStatusNotifyTimer();
        self.stopUpdateRecheckTimer();
        self.stopSessionCheckpointTimer();
        if (self.update_notice) |*notice| {
            notice.deinit(self.core_app.alloc);
            self.update_notice = null;
        }
        self.unregisterGlobalHotkeys();
        ipc_server.stopIpcServer(self);
        // Windows still open at exit. After a quit or the last window's own
        // close there are none: they saved as they went.
        if (self.hasSessionWindows()) self.saveSessionAsItEnds();
        self.releaseSessionOwnership();
        self.destroyAllWindows();
        if (self.shell_runtime_initialized) {
            self.shell_runtime.deinit();
            self.shell_runtime_initialized = false;
        }
        if (self.shell_compositor_initialized) {
            self.shell_compositor.deinit();
            self.shell_compositor_initialized = false;
        }
        // After destroyAllWindows: every Host has released its cloak-hook
        // reference by now, so no further callback can reach a freed App.
        win32_power.setCloakEventHandler(null);
        win32.cloak_event_app = null;
        self.registry.deinit(self.core_app.alloc);
        self.discardDeferredOpens();
        self.global_hotkeys.deinit(self.core_app.alloc);
        if (self.launcher_profile_key) |value| self.core_app.alloc.free(value);
        if (self.launcher_profile_hint) |value| self.core_app.alloc.free(value);
        for (self.launcher_quick_slot_keys) |value| {
            if (value) |owned| self.core_app.alloc.free(owned);
        }
        self.savePaletteMru();
        for (&self.palette_mru) |*slot| {
            if (slot.*) |owned| self.core_app.alloc.free(owned);
            slot.* = null;
        }
        // The window rolls its previews back as it goes, and the hosts and
        // windows a redraw walks are gone by now: nothing to show it to.
        self.settings_window.handle.previewField = null;
        self.settings_window.deinit();
        self.dropSettingsPreview();
        const uia_disconnect_hr = win32_uia.disconnectAllProviders();
        if (uia_disconnect_hr != 0) {
            log.warn("win32 UIA disconnect-all failed hr=0x{x}", .{@as(u32, @bitCast(uia_disconnect_hr))});
        }
        // After `destroyAllWindows`, whose closes queued their panes' toasts:
        // one call removes them all, while the notifier is still alive.
        self.removeOwnToasts();
        self.toast_sink = null;
        if (self.winrt_toast) |*toast| {
            toast.deinit();
            self.winrt_toast = null;
        }
        if (self.taskbar_progress) |*taskbar| {
            taskbar.deinit();
            self.taskbar_progress = null;
        }
        if (self.jump_list) |*jump_list| {
            jump_list.deinit();
            self.jump_list = null;
        }
        if (self.cli_config_override_path) |path| {
            self.core_app.alloc.free(path);
            self.cli_config_override_path = null;
        }
        if (self.cli_visual_studio_profiles_arg) |arg| {
            self.core_app.alloc.free(arg);
            self.cli_visual_studio_profiles_arg = null;
        }
        if (self.cli_class) |class| {
            self.core_app.alloc.free(class);
            self.cli_class = null;
        }
        self.settings_failure_detail.clear(self.core_app.alloc);
        self.settings_masked_keys.clear(self.core_app.alloc);
        self.config_problems.deinit(self.core_app.alloc);
        if (self.config_problems_banner) |text| {
            self.core_app.alloc.free(text);
            self.config_problems_banner = null;
        }
        if (self.startup_cwd) |path| {
            self.core_app.alloc.free(path);
            self.startup_cwd = null;
        }
        // Still set when `run` forwarded the launch or never got that far.
        self.releaseStartupLaunchLayout();
        deinitImeWindowFormsTracePath(self.core_app.alloc);
        self.config.deinit();
        if (self.com_initialized) {
            sys.OleUninitialize();
            self.com_initialized = false;
        }
        if (self.delivery) |delivery| {
            delivery.release();
            self.delivery = null;
        }
    }

    /// Resolve `%LOCALAPPDATA%\noctty\<name>`. Caller frees with
    /// `core_app.alloc`. Returns null if `LOCALAPPDATA` is unreadable
    /// or allocation fails.
    pub fn localAppDataPath(self: *const App, name: []const u8) ?[]u8 {
        return localAppDataPathAlloc(self.core_app.alloc, name);
    }

    fn initializeJumpList(self: *App) void {
        const jump_list = if (self.jump_list) |*value| value else return;
        if (self.delivery != null) jump_list.runner = .{ .ctx = self, .start = startJumpListRebuild };
        jump_list.startup();
    }

    /// The jump list's Shell commit, on a detached worker with an STA of
    /// its own. Like the profile discovery worker it borrows nothing from
    /// the App, so quitting never waits for it; the job comes back as
    /// WM_WINHOSTTY_JUMP_LIST.
    fn startJumpListRebuild(ctx: *anyopaque, job: *win32_jump_list.RebuildJob) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const delivery = self.delivery orelse return false;
        delivery.retain();
        // Windows' default stack: Zig's 16 MiB default is committed, not
        // just reserved, and a wedged commit keeps its thread.
        const thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, jumpListRebuildThreadMain, .{ delivery, job }) catch |err| {
            delivery.release();
            log.warn("jump list rebuild thread unavailable err={}", .{err});
            return false;
        };
        thread.detach();
        return true;
    }

    pub const paletteMruPath = palette_controller.AppControls.paletteMruPath;

    pub const sessionStatePath = session_module.sessionStatePath;

    /// Resolve `%LOCALAPPDATA%\noctty\startup-attempts.json`, the recovery
    /// ledger. Caller frees with `core_app.alloc`.
    pub fn recoveryLedgerPath(self: *const App) ?[]u8 {
        return self.localAppDataPath("startup-attempts.json");
    }

    fn namedLayoutPath(self: *const App, name: []const u8) ![]u8 {
        const relative = try win32_layouts.relativePathAlloc(self.core_app.alloc, name);
        defer self.core_app.alloc.free(relative);
        return self.localAppDataPath(relative) orelse error.LocalAppDataUnavailable;
    }

    pub fn namedLayoutsDirectoryPath(self: *const App) ?[]u8 {
        return self.localAppDataPath("layouts");
    }

    pub const sessionStateEnabled = session_module.sessionStateEnabled;

    pub const acquireSessionOwnerLock = session_module.acquireSessionOwnerLock;

    pub const adoptSessionOwner = session_module.adoptSessionOwner;

    pub const releaseSessionOwnership = session_module.releaseSessionOwnership;

    /// WM_QUERYENDSESSION, from any top-level window noctty owns (hosts, the
    /// quick terminal among them, Settings, and the lifecycle window that
    /// stands in when there is no other): true agrees to end. Without
    /// `ENDSESSION_CLOSEAPP` it is a sign-out, shutdown or reboot, which noctty
    /// never declines, and which takes back any restart registration an
    /// installer's close left, so that Windows' option to restart apps at the
    /// next sign-in never restarts noctty. With it, an installer asks through
    /// Restart Manager to close noctty so it can replace its files. noctty
    /// agrees only when a
    /// quit would ask nothing (`requestQuit`'s rules) and otherwise declines
    /// without a word, raising no prompt or window: nobody may be at the
    /// machine, and a declined close fails Setup safely (exit 5 under a
    /// package manager) with nothing lost. Nothing closes here; WM_ENDSESSION
    /// says whether the close goes ahead (`onEndSession`). Agreeing also
    /// registers for Setup's restart step (`registerInstallerRestart`).
    pub fn onQueryEndSession(self: *App, lParam: LPARAM) bool {
        if (!endSessionClosesApp(lParam)) {
            self.unregisterInstallerRestart();
            return true;
        }
        // A committed close keeps what it registered.
        if (self.session_ending) return true;
        // A quit or an update apply is under way: it has saved, or will, and
        // ends the process itself. Nothing restarts it: an update relaunches
        // through Setup's /RELAUNCH=1, which a restart would start twice.
        if (!self.running or self.quitting or
            self.update_apply_queued or self.update_apply_in_flight)
        {
            self.unregisterInstallerRestart();
            return true;
        }
        // First, so that a forced close after a decline still finds the
        // session as it is now. Unthrottled, unlike `checkpointSessionState`;
        // only an earlier query of this round that agreed stands in for it.
        const saved = self.end_session_prepared or self.snapshotForEndSession();
        // The handoff server is released last, only once everything else
        // agrees, since releasing it has to be undone after a decline.
        const agree = self.message_loop_started and
            !(self.settings_window.hwnd != null and self.settings_window.hasPendingChanges()) and
            !self.anyTerminalNeedsCloseConfirmNoWait() and
            saved and
            self.releaseHandoffForEndSession();
        self.end_session_prepared = agree;
        if (agree) {
            self.registerInstallerRestart();
        } else {
            self.retakeHandoffAfterEndSession();
            self.unregisterInstallerRestart();
        }
        return agree;
    }

    /// An `-Embedding` server agrees to close only once its class object is
    /// revoked with no client part way through a handoff
    /// (`exitEmbeddingServerIfIdle`, which takes it back itself when one
    /// arrived in between). Until WM_ENDSESSION settles the close, a client
    /// that asks for the class starts a new server.
    fn releaseHandoffForEndSession(self: *App) bool {
        if (self.terminal_handoff_server == null) return true;
        if (!self.exitEmbeddingServerIfIdle()) return false;
        self.end_session_handoff_revoked = true;
        return true;
    }

    /// The close a query revoked the handoff class object for was declined or
    /// called off: serve handoffs again.
    fn retakeHandoffAfterEndSession(self: *App) void {
        if (!self.end_session_handoff_revoked) return;
        self.end_session_handoff_revoked = false;
        const server = self.terminal_handoff_server orelse return;
        if (server.cookie != null) return;
        server.register() catch |err| {
            log.err("failed to re-register terminal handoff class object err={}", .{err});
        };
    }

    /// Lets Setup's restart step (Inno's RestartApplications, which calls
    /// RmRestart) start noctty again after the close it agreed to, so the
    /// saved session comes back. Only for the session's owner with windows to
    /// restore: any other process closes as a quit would and stays closed.
    /// Registered here and not at startup, and taken back when the close is
    /// called off or a sign-out, shutdown or reboot begins, so a reboot, a
    /// sign-in, a crash or the in-app update never restarts noctty. The
    /// relaunch is a plain start that replays only the launch argv's
    /// `--config-file` and `--class` (`installerRestartCommandLine`); Windows
    /// adds the executable.
    fn registerInstallerRestart(self: *App) void {
        // Both are asked before the once-per-round check, so that they also
        // take back a registration an earlier round left: this process may
        // have stopped qualifying since (its last restorable window closed,
        // or a reload turned saving off), or another noctty process's in-app
        // Install is running this Setup, which starts noctty through
        // /RELAUNCH=1, so a restart would be a second start.
        if (!self.sessionStateEnabled() or !self.hasSessionWindows() or
            self.restart_api.installer_apply_running(self.core_app.alloc))
        {
            return self.unregisterInstallerRestart();
        }
        if (self.restart_registered) return;
        const line = installerRestartCommandLine(
            self.core_app.alloc,
            self.cli_config_override_path,
            self.cli_class,
        ) catch |err| {
            log.warn("installer restart not registered err={}", .{err});
            return;
        } orelse {
            log.warn("installer restart not registered: the command line is over {d} characters", .{restart_max_cmd_line - 1});
            return;
        };
        defer self.core_app.alloc.free(line);
        const hr = self.restart_api.register(if (line.len == 0) null else line.ptr, restart_flags);
        if (hr != 0) {
            log.warn("RegisterApplicationRestart failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
            return;
        }
        self.restart_registered = true;
    }

    /// Undoes `registerInstallerRestart` when the close it was made for is
    /// declined or called off, or a sign-out, shutdown or reboot begins.
    fn unregisterInstallerRestart(self: *App) void {
        if (!self.restart_registered) return;
        self.restart_registered = false;
        const hr = self.restart_api.unregister();
        if (hr != 0) log.warn("UnregisterApplicationRestart failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
    }

    /// WM_ENDSESSION, from the same windows. `ending` false: the end was
    /// called off (this or another window declined), and since nothing
    /// closed, only the restart registration and the handoff class object an
    /// agreeing query revoked are undone. True without
    /// `ENDSESSION_CLOSEAPP`: a sign-out, shutdown or reboot
    /// (`saveForEndSession`), which also takes back a restart registration,
    /// even one a committed installer close kept. True with it:
    /// Restart Manager closes noctty. Every window is saved while it is whole,
    /// as a quit saves, and the snapshot is latched; the quit itself runs from
    /// the message loop (`finishEndSessionClose`), never inside this sent
    /// message, which may have arrived in the middle of other work, nor
    /// through a posted quit, which a nested pump (`ShellExecuteW`, a menu, a
    /// sizing loop) would run just the same. Once per process.
    pub fn onEndSession(self: *App, ending: bool, lParam: LPARAM) void {
        self.end_session_prepared = false;
        if (!ending) {
            self.retakeHandoffAfterEndSession();
            return self.unregisterInstallerRestart();
        }
        if (!endSessionClosesApp(lParam)) {
            self.unregisterInstallerRestart();
            return self.saveForEndSession();
        }
        // A quit under way has saved its windows and ends the process itself.
        if (self.session_ending or !self.running or self.quitting) return;
        self.savePaletteMru();
        if (self.hasSessionWindows()) self.saveSessionAsItEnds();
        self.session_ending = true;
        self.end_session_quit_pending = true;
        self.wakeup();
    }

    fn endSessionClosesApp(lParam: LPARAM) bool {
        return (@as(usize, @bitCast(lParam)) & c.ENDSESSION_CLOSEAPP) != 0;
    }

    /// The message loop's step for a Restart Manager close that WM_ENDSESSION
    /// committed (`onEndSession`): quit as a confirmed `quit` does, whatever
    /// `quit-after-last-window-closed` says, since an installer is waiting to
    /// replace the files. The session was saved and latched at the commit, so
    /// the quit saves nothing more. Returns whether the loop should exit.
    pub fn finishEndSessionClose(self: *App) !bool {
        if (!self.end_session_quit_pending) return false;
        self.quitConfirmed();
        self.end_session_quit_pending = false;
        return self.finishLoopStep();
    }

    /// The Restart Manager query's save (`onQueryEndSession`). False only when
    /// this process owns the saved session, has windows to put in it, and
    /// could not write them.
    fn snapshotForEndSession(self: *App) bool {
        if (!self.sessionStateEnabled()) return true;
        // Nothing to write over the file: the last window saved as it went,
        // no window holds the session, or it is a restore that failed.
        if (self.session_state_saved_before_last_host_close or
            !self.hasSessionWindows() or self.sessionIsFailedRestore()) return true;
        self.session_checkpoint_ms = sys.GetTickCount64();
        return self.saveSessionState(.checkpoint);
    }

    /// Whether a quit would ask about a terminal (`pendingCloseAsk`), without
    /// waiting for a renderer mutex (`Surface.needsCloseConfirmNoWait`).
    fn anyTerminalNeedsCloseConfirmNoWait(self: *const App) bool {
        for (self.registry.hosts.items) |host| {
            if (tabsCloseConfirmCountNoWait(host.tabs.items) > 0) return true;
        }
        return false;
    }

    /// A sign-out, shutdown or reboot (WM_ENDSESSION(TRUE) without
    /// `ENDSESSION_CLOSEAPP`): Windows may end the process once every window
    /// has returned, without `GetMessage` returning, so `terminate` never
    /// runs. Tear nothing down.
    fn saveForEndSession(self: *App) void {
        if (self.session_ending) return;
        self.savePaletteMru();
        // A checkpoint, never `.final`: the sign-out also ends the shells, so
        // an empty window list here says nothing about what the user closed.
        // Latched even when the save fails: any later save would come from
        // panes closing as their shells die, and could only shrink the
        // previous snapshot or move it aside as a restore nobody used.
        _ = self.saveSessionState(.checkpoint);
        self.session_ending = true;
    }

    pub const checkpointSessionState = session_module.checkpointSessionState;

    pub const scheduleSessionCheckpoint = session_module.scheduleSessionCheckpoint;

    pub const stopSessionCheckpointTimer = session_module.stopSessionCheckpointTimer;

    pub const onSessionCheckpointTimer = session_module.onSessionCheckpointTimer;

    pub const sessionRestoreEligible = session_module.sessionRestoreEligible;

    const loadPaletteMru = palette_controller.AppControls.loadPaletteMru;

    const savePaletteMru = palette_controller.AppControls.savePaletteMru;

    pub const loadSessionState = session_module.loadSessionState;

    pub const loadSessionStateAt = session_module.loadSessionStateAt;

    pub fn launchNamedLayout(self: *App, name: []const u8, preferred_banner_host: ?*Host) bool {
        const banner_host = preferred_banner_host orelse if (self.registry.primarySurface()) |surface|
            surface.host
        else
            null;
        win32_layouts.validateName(name) catch |err| {
            log.warn("named layout launch rejected invalid name name={s} err={}", .{ name, err });
            if (banner_host) |host| host.setBanner(.err, "Invalid layout name.") catch {};
            return false;
        };
        const path = self.namedLayoutPath(name) catch |err| {
            log.warn("named layout launch path resolution failed name={s} err={}", .{ name, err });
            if (banner_host) |host| host.setBanner(.err, "Layout path is unavailable.") catch {};
            return false;
        };
        defer self.core_app.alloc.free(path);

        var loaded = win32_session_persistence.loadLayoutAlloc(
            self.core_app.alloc,
            path,
            win32_session_persistence.default_max_state_bytes,
        );
        defer loaded.deinit();
        switch (loaded) {
            .missing => {
                log.warn("named layout launch file not found name={s} path={s}", .{ name, path });
                if (banner_host) |host| host.setBanner(.err, "Layout was not found.") catch {};
                return false;
            },
            .oversized => {
                log.warn("named layout launch file exceeds size limit name={s} path={s}", .{ name, path });
                if (banner_host) |host| host.setBanner(.err, "Layout file is too large.") catch {};
                return false;
            },
            .transient => |err| {
                log.warn("named layout launch read failed name={s} path={s} err={}", .{ name, path, err });
                if (banner_host) |host| host.setBanner(.err, "Layout could not be read.") catch {};
                return false;
            },
            .newer_schema => {
                log.warn("named layout launch file was written by a newer noctty name={s} path={s}", .{ name, path });
                if (banner_host) |host| host.setBanner(.err, "Layout was saved by a newer noctty.") catch {};
                return false;
            },
            .corrupt => |err| {
                const quarantined = self.quarantineInvalidNamedLayout(path, name, err);
                if (banner_host) |host| host.setBanner(
                    .err,
                    if (quarantined)
                        "Invalid layout was quarantined."
                    else
                        "Invalid layout could not be quarantined.",
                ) catch {};
                return false;
            },
            .loaded => |parsed| {
                if (parsed.value.windows.len != 1) {
                    const quarantined = self.quarantineInvalidNamedLayout(
                        path,
                        name,
                        error.InvalidWindowCount,
                    );
                    if (banner_host) |host| host.setBanner(
                        .err,
                        if (quarantined)
                            "Invalid layout was quarantined."
                        else
                            "Invalid layout could not be quarantined.",
                    ) catch {};
                    return false;
                }
                // A layout file can come from a synced or shared directory, and
                // materializing one spawns a shell per pane. Refuse oversized
                // documents instead of quarantining them: the file may well be
                // the user's own, just too large for one window.
                win32_layouts.validateLaunchSize(parsed.value.windows[0]) catch |err| {
                    log.warn("named layout launch rejected oversized document name={s} err={}", .{ name, err });
                    if (banner_host) |host| host.setBanner(.err, "Layout has too many tabs or panes.") catch {};
                    return false;
                };
                // A layout is a shape, not a placement: the save path omits
                // window geometry deliberately. Strip any a hand-authored or
                // synced file carries so it cannot place the new window
                // off-screen, resize it, or maximize it.
                var shape = parsed.value.windows[0];
                shape.x = null;
                shape.y = null;
                shape.width = null;
                shape.height = null;
                shape.state = null;
                shape.fullscreen_maximized = null;
                const surface = self.restoreSessionWindow(shape) catch |err| {
                    log.warn("named layout materialization failed name={s} err={}", .{ name, err });
                    if (banner_host) |host| host.setBanner(.err, "Layout could not be opened.") catch {};
                    return false;
                };
                self.activateSurface(surface);
                return true;
            },
        }
    }

    fn quarantineInvalidNamedLayout(
        self: *App,
        path: []const u8,
        name: []const u8,
        parse_error: anyerror,
    ) bool {
        const destination = win32_session_persistence.quarantineCorruptFileAlloc(
            self.core_app.alloc,
            path,
        ) catch |err| {
            log.warn("named layout quarantine failed name={s} path={s} parse_err={} move_err={}", .{ name, path, parse_error, err });
            return false;
        };
        defer self.core_app.alloc.free(destination);
        log.warn("named layout quarantined invalid file name={s} path={s} parse_err={}", .{ name, destination, parse_error });
        return true;
    }

    fn saveNamedLayout(self: *App, target: apprt.Target, name: []const u8) bool {
        const surface = self.registry.findSurfaceForTarget(target) orelse {
            log.warn("named layout save has no target surface name={s}", .{name});
            return false;
        };
        const host = surface.host orelse {
            log.warn("named layout save target has no host name={s}", .{name});
            return false;
        };
        win32_layouts.validateName(name) catch |err| {
            log.warn("named layout save rejected invalid name name={s} err={}", .{ name, err });
            host.setBanner(.err, "Invalid layout name.") catch {};
            return false;
        };
        const path = self.namedLayoutPath(name) catch |err| {
            log.warn("named layout save path resolution failed name={s} err={}", .{ name, err });
            host.setBanner(.err, "Layout path is unavailable.") catch {};
            return false;
        };
        defer self.core_app.alloc.free(path);

        var arena = std.heap.ArenaAllocator.init(self.core_app.alloc);
        defer arena.deinit();
        // Layout files never carry terminal contents: request zero lines so
        // the `.layout` arm has nothing to capture even if it ever grows one.
        var no_scrollback_budget: usize = 0;
        const window = buildSessionWindow(
            arena.allocator(),
            host,
            .layout,
            0,
            &no_scrollback_budget,
        ) catch |err| {
            log.warn("named layout save snapshot failed name={s} err={}", .{ name, err });
            host.setBanner(.err, "Layout could not be saved.") catch {};
            return false;
        };
        // Launch refuses documents above this cap, so refuse to write one.
        // Saving must not report success for a layout that can never open.
        win32_layouts.validateLaunchSize(window) catch |err| {
            log.warn("named layout save rejected oversized window name={s} err={}", .{ name, err });
            host.setBanner(.err, "Layout has too many tabs or panes.") catch {};
            return false;
        };
        const layout_windows = [_]win32_session_state.Window{window};
        const encoded = win32_session_state.encodeAlloc(
            self.core_app.alloc,
            .{ .windows = &layout_windows },
        ) catch |err| {
            log.warn("named layout save encode failed name={s} err={}", .{ name, err });
            host.setBanner(.err, "Layout could not be saved.") catch {};
            return false;
        };
        defer self.core_app.alloc.free(encoded);
        if (!namedLayoutEncodingFitsReadLimit(encoded.len)) {
            log.warn(
                "named layout save rejected oversized encoding name={s} bytes={d}",
                .{ name, encoded.len },
            );
            host.setBanner(.err, "Layout data is too large.") catch {};
            return false;
        }
        writePersistentFileAlloc(self.core_app.alloc, path, encoded) catch |err| {
            log.warn("named layout save write failed name={s} path={s} err={}", .{ name, path, err });
            host.setBanner(.err, "Layout could not be saved.") catch {};
            return false;
        };
        host.setBanner(.info, "Layout saved.") catch {};
        return true;
    }

    fn namedLayoutEncodingFitsReadLimit(bytes: usize) bool {
        return bytes <= win32_session_persistence.default_max_state_bytes;
    }

    pub const restoreSessionState = session_module.restoreSessionState;

    pub const quarantineInvalidSessionState = session_module.quarantineInvalidSessionState;

    fn tickCoreApp(self: *App) !void {
        self.renderer_sync_paint_spent = false;
        try self.core_app.tick(self);
        self.resolveRecoveryStartup();
    }

    pub fn tickCoreAppModal(self: *App) void {
        if (self.core_ticking) return;
        self.core_ticking = true;
        defer self.core_ticking = false;
        self.renderer_sync_paint_spent = false;
        self.core_app.tickModal(self) catch |err| {
            log.warn("modal mailbox tick failed err={}", .{err});
        };
    }

    pub fn createMessageWindow(self: *App) !void {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.app");
        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &appMessageWindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = name,
            .hIconSm = null,
        };
        if (sys.RegisterClassExW(&wc) == 0 and windows.kernel32.GetLastError() != .CLASS_ALREADY_EXISTS)
            return lastError(); // ERROR_CLASS_ALREADY_EXISTS is expected in tests.
        const delivery = try AppDelivery.create();
        errdefer delivery.release();
        const hwnd = sys.CreateWindowExW(
            0,
            name,
            name,
            0,
            0,
            0,
            0,
            0,
            @ptrFromInt(@as(usize, @bitCast(@as(isize, -3)))), // HWND_MESSAGE
            null,
            self.hinstance,
            null,
        ) orelse return lastError();
        setWindowData(hwnd, self);
        self.registry.message_hwnd = hwnd;
        self.delivery = delivery;
        if (self.winrt_toast) |*toast| {
            toast.setActivationCallback(delivery, winrtToastActivationCallback, .{
                .retain = retainToastDelivery,
                .release = releaseToastDelivery,
            });
        }
        delivery.publish(hwnd);
    }

    pub fn closeMessageWindow(self: *App) void {
        const delivery = self.delivery orelse return;
        delivery.close();
        while (delivery.pop()) |value| {
            var payload = value;
            switch (payload) {
                .uia_disconnect => |pending| processDeferredUiaDisconnect(null, pending),
                .jump_list => |job| {
                    // The Shell already reset its removed list for this
                    // commit; record the removals before the state is saved.
                    if (self.jump_list) |*jump_list| jump_list.completeRebuild(job);
                    payload.deinit();
                },
                else => payload.deinit(),
            }
        }
        delivery.update_running.store(false, .release);
        delivery.profiles_running.store(false, .release);
        delivery.toast_pending.store(false, .release);
        if (self.registry.message_hwnd) |hwnd| {
            setWindowData(hwnd, null);
            _ = sys.DestroyWindow(hwnd);
            self.registry.message_hwnd = null;
        }
    }

    /// A top-level window that is never shown, made in every mode beside the
    /// message window. Windows sends end-session messages only to top-level
    /// windows, never to a message-only one, so without it a process whose
    /// only window is the message window (`initial-window = false`, a
    /// Settings window just closed, an idle `-Embedding` server) cannot be
    /// asked to close: Restart Manager lists it as `RmUnknownApp` and a
    /// non-forced `RmShutdown` fails at once. It answers through the same
    /// controller as every other window (`onQueryEndSession`,
    /// `onEndSession`). Windows Terminal's coordinator window is top-level
    /// for the same reason. A tool window that refuses to show stays off the
    /// taskbar, Alt+Tab and UI Automation's top-level children. Failing to
    /// make it costs only that, so it is logged, not fatal.
    fn createLifecycleWindow(self: *App) void {
        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &appLifecycleWindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = lifecycle_class_name,
            .hIconSm = null,
        };
        if (sys.RegisterClassExW(&wc) == 0 and windows.kernel32.GetLastError() != .CLASS_ALREADY_EXISTS) {
            log.warn("failed to register the lifecycle window class err={}", .{windows.kernel32.GetLastError()});
            return;
        }
        const hwnd = sys.CreateWindowExW(
            c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
            lifecycle_class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("noctty"),
            c.WS_POPUP,
            0,
            0,
            0,
            0,
            null,
            null,
            self.hinstance,
            null,
        ) orelse {
            log.warn("failed to create the lifecycle window err={}", .{windows.kernel32.GetLastError()});
            return;
        };
        setWindowData(hwnd, self);
        self.lifecycle_hwnd = hwnd;
    }

    fn closeLifecycleWindow(self: *App) void {
        const hwnd = self.lifecycle_hwnd orelse return;
        setWindowData(hwnd, null);
        _ = sys.DestroyWindow(hwnd);
        self.lifecycle_hwnd = null;
    }

    /// The app's own windows, made by `run` in every mode (normal,
    /// `-Embedding`, safe mode, `initial-window = false`) before anything
    /// else: the message window that takes cross-thread deliveries, and the
    /// lifecycle window that takes end-session messages.
    pub fn openAppWindows(self: *App) !void {
        try self.createMessageWindow();
        self.createLifecycleWindow();
    }

    pub fn closeAppWindows(self: *App) void {
        self.closeLifecycleWindow();
        self.closeMessageWindow();
    }

    /// Called only by the outer pump, never while an owner WndProc is under
    /// a native modal loop. Taking oldest also recovers a lost notification.
    fn drainPendingHandoffs(self: *App) void {
        const server = self.terminal_handoff_server orelse return;
        while (server.pending.takeOldest()) |pending| {
            defer {
                pending.deinit();
                self.core_app.alloc.destroy(pending);
            }
            self.createAdoptedWindow(pending) catch |err| {
                win32_terminal_handoff.appendHandoffMilestone(self.core_app.alloc, "adopted_window_failed");
                log.err("terminal handoff surface creation failed err={}", .{err});
            };
            if (self.registry.windows.items.len == 0) self.startTerminalHandoffIdleTimer();
        }
    }

    fn syncDirtyGlobalHotkeys(self: *App) void {
        if (!self.global_hotkeys_dirty) return;
        self.global_hotkeys_dirty = false;
        self.syncGlobalHotkeys() catch |err| {
            log.err("failed to sync win32 global hotkeys err={}", .{err});
        };
    }

    pub const rendererRepaintModeThisTick = surface_presentation.rendererRepaintModeThisTick;

    /// The `render` action for one surface: request a repaint, drain the
    /// terminal output its accessibility session waits for, and tell that
    /// session the renderer updated.
    fn renderSurface(self: *App, surface: *Surface) !void {
        try surface.requestRepaintWithMode(self.rendererRepaintModeThisTick(surface.host));
        surface.drainTerminalAccessibilityOutput();
        if (surface.terminal_accessibility) |session| session.rendererUpdated();
    }

    test "a failed new window request leaves the app running and the mailbox draining" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &.{.{ .storage = &surface, .host = &host, .register = true }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();

        const Hook = struct {
            var calls: usize = 0;

            fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, _: SurfaceInitOptions) anyerror!*Surface {
                calls += 1;
                return error.TestWindowCreateFailed;
            }
        };
        Hook.calls = 0;
        app.test_create_window_surface = &Hook.createSurface;

        // Two `+new-window` requests forwarded by other processes, and no
        // window can be created for either. Before the fix the first error
        // left `App.run`, and every existing window closed with it.
        for (0..2) |_| {
            try std.testing.expect(core_app.mailbox.push(.{ .new_window = .{} }, .instant) != 0);
        }
        try core_app.tick(&app);
        try std.testing.expectEqual(@as(usize, 2), Hook.calls);
        try std.testing.expectEqual(HostBannerKind.err, host.banner_kind);
        try std.testing.expectEqualStrings("New window could not be opened.", host.banner_text.?);

        // With its last tab detached for undo, the host stays open but has
        // no surface to resolve it through, and still takes the banner.
        try host.setBanner(.none, null);
        var detached = host.tabs.orderedRemove(0);
        detached.deinit();
        try std.testing.expect(core_app.mailbox.push(.{ .new_window = .{} }, .instant) != 0);
        try core_app.tick(&app);
        try std.testing.expectEqual(@as(usize, 3), Hook.calls);
        try std.testing.expectEqual(HostBannerKind.err, host.banner_kind);
    }

    /// Record this launch as resolved in the startup ledger.
    ///
    /// A launch is unresolved until the outer Win32 message loop completes its
    /// first core-app tick. Renderer and PTY work that continues on other
    /// threads after this boundary is outside recovery accounting.
    ///
    /// The write is attempted again on later ticks while the retry budget
    /// lasts: latching "handled" on the first attempt would let one transient
    /// sharing violation leave the launch unresolved for the whole session,
    /// which is exactly the crash-loop evidence that selects safe mode.
    fn resolveRecoveryStartup(self: *App) void {
        if (!self.recovery_ready_resolved) {
            // An unrelated tick that beat the retry timer must not spend an
            // attempt; the armed timer will bring the loop back on time.
            if (!recoveryRetryDue(self.recovery_retry_not_before_ms, sys.GetTickCount64())) return;

            if (self.markRecoveryReady()) {
                self.recovery_ready_resolved = true;
                self.stopRecoveryRetryTimer();
                self.recovery_retry_not_before_ms = null;
            } else |err| {
                const exhausted = self.recovery_ready_retry.recordFailure(err);
                const scheduled = !exhausted and self.scheduleRecoveryRetry();
                switch (recoveryFailurePolicy(exhausted, scheduled)) {
                    .retry_scheduled => log.warn(
                        "win32 recovery: ready marker attempt {d} failed err={}; retrying in {d}ms",
                        .{ self.recovery_ready_retry.failures, err, recovery_ready_retry_delay_ms },
                    ),
                    .give_up_unschedulable => {
                        log.warn(
                            "win32 recovery: ready marker attempt {d} failed err={} and no retry could be scheduled; leaving the launch unresolved",
                            .{ self.recovery_ready_retry.failures, err },
                        );
                        self.recovery_ready_resolved = true;
                        self.recovery_retry_not_before_ms = null;
                    },
                    .give_up_exhausted => {
                        log.warn(
                            "win32 recovery: ready marker unresolved after {d} attempt(s) err={}",
                            .{ self.recovery_ready_retry.failures, err },
                        );
                        self.recovery_ready_resolved = true;
                        self.stopRecoveryRetryTimer();
                        self.recovery_retry_not_before_ms = null;
                    },
                }
            }
        }

        // Only now may the safe-mode dialog appear: killing the process while
        // that modal is up must not preserve the failure streak.
        if (self.recovery_safe_mode_notice.release(self.recovery_ready_resolved)) {
            if (recoverySafeModeNotice(self.recovery_startup.decision, self.recovery_startup.session_set_aside)) |text| {
                self.showRecoverySafeModeNotice(text);
            }
        }
    }

    /// Record on this launch's attempt that it is ending because OpenGL could
    /// not start (the failure the startup dialog then reports), so the next
    /// launch does not count it toward safe mode. Best effort, like the
    /// restore markers. A crash, inside any renderer, never gets here.
    fn markRecoveryOpenGLUnavailable(self: *App) void {
        if (!gl_startup.openGLStartupFailed()) return;
        const path = self.recoveryLedgerPath() orelse return;
        defer self.core_app.alloc.free(path);
        markRecoveryAttemptAtPath(self.core_app.alloc, path, &self.recovery_startup, .{ .opengl_unavailable = unixMillis() });
    }

    /// Errors are the retryable ones only: everything deterministic (no
    /// ledger, nothing to mark, an unmergeable record) returns normally so a
    /// caller's retry budget is not spent on a failure that cannot clear.
    fn markRecoveryReady(self: *App) !void {
        if (self.recovery_startup.count == 0) return;
        const memory_attempts = self.recovery_startup.attempts[0..self.recovery_startup.count];
        const target_started_at = memory_attempts[memory_attempts.len - 1].started_at_unix_ms;
        if (memory_attempts[memory_attempts.len - 1].ready_at_unix_ms != null) return;
        const path = self.recoveryLedgerPath() orelse return;
        defer self.core_app.alloc.free(path);

        // The disk read and the replace below are one transaction against
        // other instances' startups and ready markers. A busy lock is
        // transient in the same way a handle hold is, so it spends a retry
        // rather than resolving the launch.
        var lock = (try RecoveryLedgerLock.acquire(
            self.core_app.alloc,
            path,
            recovery_ledger_lock_wait_ms,
        )) orelse return error.RecoveryLedgerBusy;
        defer lock.release();

        var disk_record: win32_recovery.StartupAttemptRecord = .{};
        var ledger = readRecoveryLedgerAlloc(self.core_app.alloc, path, "ready merge");
        defer ledger.deinit();
        // Deterministic, so not an error that spends the caller's retries.
        if (ledger == .left_alone) return;
        // A transient failure is what that retry budget is for: dropping the
        // marker would leave this launch unresolved on disk, which the next
        // launch counts as a failed start.
        if (ledger == .unreadable) return error.RecoveryLedgerUnreadable;
        if (ledger == .record) disk_record = ledger.record.value;

        var merged_attempts: [win32_recovery.max_attempts]win32_recovery.StartupAttempt = undefined;
        const merged = win32_recovery.mergeMarkReady(
            disk_record,
            .{ .attempts = memory_attempts },
            target_started_at,
            unixMillis(),
            &merged_attempts,
        ) catch |err| {
            log.warn("win32 recovery: ready marker merge failed err={}", .{err});
            return;
        };
        persistMergedRecoveryReadyAtPath(
            self.core_app.alloc,
            path,
            &self.recovery_startup,
            merged,
        ) catch |err| {
            log.warn("win32 recovery: ready marker persist failed err={}", .{err});
            return err;
        };
    }

    pub const restoreSessionWindow = session_module.restoreSessionWindow;

    pub const syncRestoredHostWindowState = session_module.syncRestoredHostWindowState;

    pub const restoreSessionTab = session_module.restoreSessionTab;

    pub const restoreSessionPane = session_module.restoreSessionPane;

    pub const applyRestoredWindowPlacement = session_module.applyRestoredWindowPlacement;

    pub const hasSessionWindows = session_module.hasSessionWindows;

    pub const closingEndsSession = session_module.closingEndsSession;

    pub const saveSessionAsItEnds = session_module.saveSessionAsItEnds;

    pub const sessionIsFailedRestore = session_module.sessionIsFailedRestore;

    pub const setAsideFailedRestore = session_module.setAsideFailedRestore;

    pub const saveSessionState = session_module.saveSessionState;

    pub const writeSessionStateAt = session_module.writeSessionStateAt;

    pub const buildSessionState = session_module.buildSessionState;

    pub const SnapshotScope = session_module.SnapshotScope;

    pub const buildSessionWindow = session_module.buildSessionWindow;

    pub const buildSessionTab = session_module.buildSessionTab;

    pub const buildSessionLayout = session_module.buildSessionLayout;

    pub const sessionSnapshotPaneText = session_module.sessionSnapshotPaneText;

    pub const hostSessionTabs = session_module.hostSessionTabs;

    pub const firstSessionLayoutPane = session_module.firstSessionLayoutPane;

    pub const buildRestoredSessionSplitTree = session_module.buildRestoredSessionSplitTree;

    pub const sessionStateWindowRect = session_module.sessionStateWindowRect;

    pub const SessionWindowPlacement = session_module.SessionWindowPlacement;

    pub const sessionWindowPlacement = session_module.sessionWindowPlacement;

    pub const sessionWindowPlacementOn = session_module.sessionWindowPlacementOn;

    pub const sessionFullscreenWindowPlacement = session_module.sessionFullscreenWindowPlacement;

    pub const pushPaletteMru = palette_controller.AppControls.pushPaletteMru;

    pub const paletteMruSlice = palette_controller.AppControls.paletteMruSlice;

    fn unregisterGlobalHotkeys(self: *App) void {
        for (self.global_hotkeys.items) |hotkey| {
            _ = sys.UnregisterHotKey(null, hotkey.id);
        }
        self.global_hotkeys.clearRetainingCapacity();
    }

    fn syncGlobalHotkeys(self: *App) !void {
        self.unregisterGlobalHotkeys();

        var next_id: i32 = 1;
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            const generic = switch (entry.value_ptr.*) {
                .leader => continue,
                .leaf => |*leaf| leaf.generic(),
                .leaf_chained => |*leaf| leaf.generic(),
            };
            if (!generic.flags.global) continue;

            const spec = hotkeySpecForTrigger(entry.key_ptr.*) orelse {
                log.warn("skipping unsupported win32 global hotkey trigger={f}", .{entry.key_ptr.*});
                continue;
            };

            if (self.registeredGlobalHotkeyForSpec(spec)) |existing| {
                log.warn("skipping duplicate win32 global hotkey trigger={f} conflicts_with={f} mods=0x{x} vk=0x{x}", .{
                    entry.key_ptr.*,
                    existing.trigger,
                    spec.modifiers,
                    spec.vk,
                });
                continue;
            }

            if (sys.RegisterHotKey(null, next_id, spec.modifiers, spec.vk) == 0) {
                const err = windows.kernel32.GetLastError();
                log.warn("failed to register win32 global hotkey trigger={f} id={} mods=0x{x} vk=0x{x} err={} reason={s}", .{
                    entry.key_ptr.*,
                    next_id,
                    spec.modifiers,
                    spec.vk,
                    err,
                    hotkeyRegistrationFailureReason(err),
                });
                continue;
            }

            try self.global_hotkeys.append(self.core_app.alloc, .{
                .id = next_id,
                .trigger = entry.key_ptr.*,
                .spec = spec,
                .binding = entry.value_ptr,
            });
            next_id += 1;
        }
    }

    fn registeredGlobalHotkeyForSpec(self: *const App, spec: GlobalHotkeySpec) ?RegisteredGlobalHotkey {
        for (self.global_hotkeys.items) |hotkey| {
            if (hotkeySpecEql(hotkey.spec, spec)) return hotkey;
        }
        return null;
    }

    fn scheduleGlobalHotkeySync(self: *App) void {
        self.global_hotkeys_dirty = true;
        self.wakeup();
    }

    fn handleGlobalHotkey(self: *App, id: i32) void {
        for (self.global_hotkeys.items) |hotkey| {
            if (hotkey.id != id) continue;

            switch (hotkey.binding.*) {
                .leader => unreachable,
                .leaf => |*leaf| self.core_app.performAllChainedAction(self, leaf.generic().actionsSlice()),
                .leaf_chained => |*leaf| self.core_app.performAllChainedAction(self, leaf.generic().actionsSlice()),
            }
            return;
        }
    }

    pub fn wakeup(self: *App) void {
        if (@atomicLoad(DWORD, &self.ui_thread_id, .acquire) == 0) return;
        const delivery = self.delivery orelse return;
        _ = delivery.wake(c.WM_WINHOSTTY_WAKE);
    }

    fn automaticUpdateChecksEnabled(self: *const App) bool {
        return self.config.@"auto-update" != .off and
            self.config.@"auto-update-channel" == .stable and
            self.ui_thread_id != 0;
    }

    pub fn maybeScheduleAutomaticUpdateCheck(self: *App) void {
        if (self.update_auto_check_started) return;
        if (!self.automaticUpdateChecksEnabled()) return;

        self.update_auto_check_started = true;
        self.runAutomaticUpdateCheck();
        self.startUpdateRecheckTimer();
    }

    fn runAutomaticUpdateCheck(self: *App) void {
        self.scheduleUpdateCheck(.{
            .force = false,
            .manual = false,
            .respect_dismissal = true,
        }) catch |err| {
            log.warn("failed to start automatic update check err={}", .{err});
        };
    }

    /// A terminal that stays open for weeks would otherwise learn about a
    /// release only after a restart. The tick is cheap: the check's own
    /// 24 hour throttle answers from the saved state (no request, no
    /// download) until a day has passed, and a dismissed version stays
    /// dismissed because the check respects it. With no window open the tick
    /// does nothing, so an idle background process makes no request.
    fn startUpdateRecheckTimer(self: *App) void {
        if (self.update_recheck_timer_id != null) return;
        const timer_id = sys.SetTimer(null, 0, update_recheck_interval_ms, null);
        if (timer_id == 0) {
            log.warn("failed to start win32 update recheck timer err={}", .{windows.kernel32.GetLastError()});
            return;
        }
        self.update_recheck_timer_id = timer_id;
    }

    fn stopUpdateRecheckTimer(self: *App) void {
        killThreadTimer(&self.update_recheck_timer_id);
    }

    /// Applying a staged update sets `running = false` first; nothing is left
    /// to tell about a release then. A staged notice that is already up is
    /// left alone: the check would only re-verify it (and for a portable ZIP
    /// re-extract it) while the user may be about to press Install.
    fn updateRecheckWanted(self: *const App) bool {
        if (self.update_notice) |notice| if (notice.staged) return false;
        return self.running and self.registry.windows.items.len > 0 and self.automaticUpdateChecksEnabled();
    }

    test "the update recheck timer is armed once, stopped on request, and ticks only with a window" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .surfaces = &.{.{ .storage = &surface }},
        });
        defer session.deinit();

        app.startUpdateRecheckTimer();
        defer app.stopUpdateRecheckTimer();
        const timer_id = app.update_recheck_timer_id.?;
        app.startUpdateRecheckTimer();
        try std.testing.expectEqual(timer_id, app.update_recheck_timer_id.?);
        app.stopUpdateRecheckTimer();
        try std.testing.expectEqual(@as(?UINT_PTR, null), app.update_recheck_timer_id);

        // A tick asks for a check only while the app runs with a window and
        // automatic checks are on for the stable channel.
        app.config.@"auto-update" = .check;
        app.config.@"auto-update-channel" = .stable;
        app.ui_thread_id = 1;
        defer app.ui_thread_id = 0;
        app.running = true;
        try std.testing.expect(!app.updateRecheckWanted());
        try app.registry.addWindow(std.testing.allocator, &surface);
        defer app.registry.windows.clearAndFree(std.testing.allocator);
        try std.testing.expect(app.updateRecheckWanted());
        // A staged notice that is already up is left alone; an unstaged one
        // is not, since a newer release should replace it.
        app.update_notice = try UpdateNotice.init(std.testing.allocator, "1.3.200", "https://example.invalid/release", true);
        try std.testing.expect(!app.updateRecheckWanted());
        app.update_notice.?.staged = false;
        try std.testing.expect(app.updateRecheckWanted());
        app.update_notice.?.deinit(std.testing.allocator);
        app.update_notice = null;
        app.config.@"auto-update" = .off;
        try std.testing.expect(!app.updateRecheckWanted());
        app.config.@"auto-update" = .check;
        app.config.@"auto-update-channel" = .tip;
        try std.testing.expect(!app.updateRecheckWanted());
        app.config.@"auto-update-channel" = .stable;
        app.running = false;
        try std.testing.expect(!app.updateRecheckWanted());
    }

    fn onUpdateRecheckTimer(self: *App) void {
        if (self.updateRecheckWanted()) self.runAutomaticUpdateCheck();
    }

    fn installKind(self: *App) InstallKind {
        if (self.install_kind) |kind| return kind;
        const kind = InstallKind.detect(self.core_app.alloc);
        self.install_kind = kind;
        return kind;
    }

    /// What a check should download and stage, or null for a notice only:
    /// `auto-update = download` on a copy that can apply what it stages.
    fn updateStageKind(self: *App) ?updatepkg.portable_apply.StagedKind {
        if (self.config.@"auto-update" != .download) return null;
        return self.installKind().stagedKind();
    }

    test "a check stages only when auto-update is download and this copy can apply the result" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();

        const Staged = updatepkg.portable_apply.StagedKind;
        const cases = [_]struct { mode: configpkg.Config.AutoUpdate, kind: InstallKind, stages: ?Staged }{
            .{ .mode = .download, .kind = .installer, .stages = .installer },
            .{ .mode = .download, .kind = .portable, .stages = .portable },
            .{ .mode = .download, .kind = .other, .stages = null },
            .{ .mode = .check, .kind = .installer, .stages = null },
            .{ .mode = .off, .kind = .portable, .stages = null },
        };
        for (cases) |case| {
            app.config.@"auto-update" = case.mode;
            app.install_kind = case.kind;
            try std.testing.expectEqual(case.stages, app.updateStageKind());
        }
    }

    test "the first automatic check arms the recheck timer once" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();

        // The session has no delivery channel, so no check thread starts.
        app.config.@"auto-update" = .check;
        app.config.@"auto-update-channel" = .stable;
        app.ui_thread_id = 1;
        defer app.ui_thread_id = 0;
        defer app.stopUpdateRecheckTimer();
        app.maybeScheduleAutomaticUpdateCheck();
        try std.testing.expect(app.update_auto_check_started);
        const timer_id = app.update_recheck_timer_id.?;
        app.maybeScheduleAutomaticUpdateCheck();
        try std.testing.expectEqual(timer_id, app.update_recheck_timer_id.?);

        // Automatic checks off: no timer for a process that never checks.
        app.stopUpdateRecheckTimer();
        app.update_auto_check_started = false;
        app.config.@"auto-update" = .off;
        app.maybeScheduleAutomaticUpdateCheck();
        try std.testing.expect(!app.update_auto_check_started);
        try std.testing.expectEqual(@as(?UINT_PTR, null), app.update_recheck_timer_id);
    }

    fn scheduleUpdateCheck(
        self: *App,
        opts: struct {
            force: bool,
            manual: bool,
            respect_dismissal: bool,
        },
    ) !void {
        if (self.ui_thread_id == 0) return;

        const delivery = self.delivery orelse return;
        const current = delivery.update_running.cmpxchgStrong(false, true, .acq_rel, .acquire);
        if (current != null) {
            if (opts.manual) try self.showUpdateInfo(.info, "Update check already running.");
            return;
        }
        errdefer delivery.update_running.store(false, .release);

        const request = try std.heap.page_allocator.create(UpdateCheckRequest);
        errdefer std.heap.page_allocator.destroy(request);

        // The ignored-feed note has to come from the resolver, not from the
        // config value alone: NOCTTY_UPDATE_FEED_URL is also a feed source
        // and it is also dropped when it is not HTTPS.
        const resolved_feed = try updatepkg.resolveReleaseFeed(
            self.core_app.alloc,
            self.config.@"auto-update-feed-url",
        );
        const release_feed_url = resolved_feed.url;
        defer self.core_app.alloc.free(release_feed_url);
        // Only a copy that can apply a staged update gets one downloaded.
        // The notice for any other falls back to "Open Release".
        const stage_kind = self.updateStageKind();

        // The detached worker must not borrow the core allocator's lifetime.
        // Page allocator storage and a retained channel remain valid after UI exit.
        const state_path = try updatepkg.defaultStatePath(std.heap.page_allocator);
        errdefer std.heap.page_allocator.free(state_path);
        const current_version_string = try std.heap.page_allocator.dupe(u8, build_config.version_string);
        errdefer std.heap.page_allocator.free(current_version_string);
        const worker_feed = try std.heap.page_allocator.dupe(u8, release_feed_url);
        errdefer std.heap.page_allocator.free(worker_feed);

        request.* = .{
            .alloc = std.heap.page_allocator,
            .delivery = delivery,
            .state_path = state_path,
            .current_version = build_config.version,
            .current_version_string = current_version_string,
            .release_feed_url = worker_feed,
            .force = opts.force,
            .manual = opts.manual,
            .ignored_feed_source = resolved_feed.ignored_non_https,
            .respect_dismissal = opts.respect_dismissal,
            .download = stage_kind != null,
            .staged_kind = stage_kind orelse .installer,
        };

        delivery.retain();
        errdefer delivery.release();
        const thread = try std.Thread.spawn(.{}, updateCheckThreadMain, .{request});
        thread.detach();
    }

    /// Run the jump list's deferred startup profile discovery off the UI
    /// thread. Discovery starts `wsl.exe --status` and `wsl.exe -l -q` and
    /// waits for each (up to 1.5 s apiece), which held the UI thread about
    /// 90 ms half a second after start-up here. Like the update check, the
    /// worker is detached and borrows nothing from the App, so quitting never
    /// waits for it; its result arrives as WM_WINHOSTTY_PROFILES.
    pub fn startProfileDiscovery(self: *App) void {
        const delivery = self.delivery orelse return self.discoverStartupProfilesNow();
        const now_ms = sys.GetTickCount64();
        if (delivery.profiles_running.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            // Running, or its result is still queued. A worker can hang for
            // good: a shell spawned at the same moment can inherit the write
            // end of `wsl.exe -l -q`'s stdout pipe, and its drain then never
            // ends. Give up on it then; the generation keeps a late result
            // from doing harm.
            if (now_ms -| self.profile_discovery_started_ms < profile_discovery_abandon_ms) return;
            log.warn("profile discovery worker unfinished after {d} ms; starting another", .{profile_discovery_abandon_ms});
        }
        // The worker may outlive the App, so it gets its own copy of the
        // user profiles, from the allocator it frees them with.
        var user = windows_shell.UserProfiles.init(std.heap.page_allocator, &self.config) catch |err| {
            delivery.profiles_running.store(false, .release);
            log.warn("profile discovery thread unavailable; discovering on the UI thread err={}", .{err});
            return self.discoverStartupProfilesNow();
        };
        self.profile_discovery_started_ms = now_ms;
        self.profile_discovery_attempt +%= 1;
        delivery.retain();
        const thread = std.Thread.spawn(.{}, profileDiscoveryThreadMain, .{
            delivery,
            self.config.@"ssh-config-hosts",
            self.profiles_generation,
            self.profile_discovery_attempt,
            user,
        }) catch |err| {
            user.deinit();
            delivery.release();
            delivery.profiles_running.store(false, .release);
            log.warn("profile discovery thread unavailable; discovering on the UI thread err={}", .{err});
            return self.discoverStartupProfilesNow();
        };
        thread.detach();
        self.stopProfileDiscoveryWatchdog();
        const timer_id = sys.SetTimer(null, 0, @intCast(profile_discovery_abandon_ms + std.time.ms_per_s), null);
        if (timer_id != 0) self.profile_discovery_watchdog_id = timer_id;
    }

    fn stopProfileDiscoveryWatchdog(self: *App) void {
        killThreadTimer(&self.profile_discovery_watchdog_id);
    }

    fn applyPendingProfileDiscovery(self: *App) void {
        const pending = self.pending_profile_discovery orelse return;
        self.pending_profile_discovery = null;
        defer pending.deinit();
        if (pending.attempt == self.profile_discovery_attempt) {
            if (self.delivery) |delivery| delivery.profiles_running.store(false, .release);
            self.stopProfileDiscoveryWatchdog();
        }
        self.handleProfileDiscovery(pending);
    }

    /// A discovery's list goes to every host that asked for one (the
    /// picker, the palette) and, for the jump list, to the first host while
    /// its startup discovery is pending and that host has no complete list.
    pub fn handleProfileDiscovery(self: *App, completion: *const ProfileDiscoveryCompletion) void {
        // With no host, `scheduleIfStartupPending` re-arms when one appears.
        if (self.registry.hosts.items.len == 0) return;
        // Settings' Default profile dropdown reads the windows' lists.
        defer self.settings_window.profilesChanged();
        const primary = self.registry.hosts.items[0];
        const jump_list: ?*win32_jump_list.JumpList = if (self.jump_list) |*value|
            if (value.startupProfileDiscoveryPending()) value else null
        else
            null;
        defer if (jump_list) |list| {
            if (primary.profiles != null and primary.profiles_complete) {
                list.completeStartupProfileDiscovery();
            } else {
                list.retryStartupProfileDiscovery();
            }
        };
        const primary_wants = jump_list != null and !(primary.profiles != null and primary.profiles_complete);

        if (completion.generation != self.profiles_generation) {
            // A list was applied or dropped since this one started. The
            // jump list re-arms its timer; a host that asked starts over.
            if (self.anyHostRequestedProfiles()) self.startProfileDiscovery();
            return;
        }
        const discovery = completion.result catch |err| {
            log.warn("deferred profile discovery failed err={}", .{err});
            for (self.registry.hosts.items) |host| {
                if (!host.profiles_requested) continue;
                host.profiles_requested = false;
                if (host != self.profiles_requesting_host) host.profilesArrived(host.profiles != null);
            }
            return;
        };
        for (self.registry.hosts.items) |host| {
            if (!host.profiles_requested and !(host == primary and primary_wants)) continue;
            host.profiles_requested = false;
            const had_profiles = host.profiles != null;
            // An incomplete list (a probe timed out, the SSH config was
            // busy) does not replace a complete one.
            if (!discovery.complete and host.profiles_complete) {
                if (host != self.profiles_requesting_host) host.profilesArrived(had_profiles);
                continue;
            }
            const profiles = windows_shell.cloneProfiles(self.core_app.alloc, discovery.profiles) catch |err| {
                log.warn("deferred profile discovery failed err={}", .{err});
                continue;
            };
            _ = host.applyProfileDiscovery(.{ .profiles = profiles, .complete = discovery.complete }) catch |err| {
                log.warn("deferred profile discovery failed err={}", .{err});
            };
            if (host != self.profiles_requesting_host) host.profilesArrived(had_profiles);
        }
    }

    /// The profile list for Settings' Default profile dropdown: a window's
    /// complete list, else any window's list, else, when `ask`, the first
    /// window asks the discovery worker (never discovering on this thread
    /// when one can run) and `handleProfileDiscovery` tells Settings when the
    /// list arrives. That refill does not ask: after a failed discovery no
    /// window has a list, and asking again from there would start another at
    /// once, and another when it failed. Null with no window or no list.
    pub fn settingsProfileList(self: *App, ask: bool) ?struct { profiles: []const windows_shell.Profile, complete: bool } {
        for (self.registry.hosts.items) |host| if (host.profiles_complete) {
            if (host.profiles) |profiles| return .{ .profiles = profiles, .complete = true };
        };
        for (self.registry.hosts.items) |host| {
            if (host.profiles) |profiles| return .{ .profiles = profiles, .complete = false };
        }
        if (!ask or self.registry.hosts.items.len == 0) return null;
        const host = self.registry.hosts.items[0];
        _ = host.profilesForChrome();
        const profiles = host.profiles orelse return null;
        return .{ .profiles = profiles, .complete = host.profiles_complete };
    }

    fn anyHostRequestedProfiles(self: *const App) bool {
        for (self.registry.hosts.items) |host| {
            if (host.profiles_requested) return true;
        }
        return false;
    }

    /// The synchronous path, for when no thread can run it.
    fn discoverStartupProfilesNow(self: *App) void {
        var completion: ProfileDiscoveryCompletion = .{
            .arena = .init(self.core_app.alloc),
            .generation = self.profiles_generation,
        };
        defer completion.deinit();
        completion.result = discover: {
            var user = windows_shell.UserProfiles.init(completion.arena.allocator(), &self.config) catch |err|
                break :discover err;
            defer user.deinit();
            break :discover windows_shell.discoverProfiles(
                completion.arena.allocator(),
                self.config.@"ssh-config-hosts",
                &user,
            );
        };
        self.handleProfileDiscovery(&completion);
    }

    pub fn handleUpdateCheckCompletion(self: *App, completion: *UpdateCheckCompletion) void {
        if (self.delivery) |delivery| delivery.update_running.store(false, .release);

        // The old notice offers Install (staged installer from the old feed)
        // or Open Release (release URL from the old feed). Once the check
        // discarded that feed's state, neither action is still valid, so drop
        // the notice before anything below can raise a replacement.
        if (completion.clear_stale_notice) self.clearUpdateNotice();

        if (completion.release) |release| {
            self.setUpdateNotice(release.version_text, release.release_url, completion.staged) catch |err| {
                log.warn("failed to surface update notice err={}", .{err});
            };
        }
        if (completion.manual_message) |message| {
            self.showUpdateInfo(completion.manual_kind, message) catch |err| {
                log.warn("failed to show updater status message err={}", .{err});
            };
        }
    }

    fn setUpdateNotice(self: *App, version_text: []const u8, release_url: []const u8, staged: bool) !void {
        if (self.update_notice) |*notice| {
            if (ownedBytesEquals(notice.version_text, version_text) and
                ownedBytesEquals(notice.release_url, release_url) and
                notice.staged == staged)
            {
                return;
            }
            notice.deinit(self.core_app.alloc);
            self.update_notice = null;
        }

        self.update_notice = try UpdateNotice.init(self.core_app.alloc, version_text, release_url, staged);
        // Announce it once: in the window the user is in, else the first.
        const foreground = sys.GetForegroundWindow();
        var announcer: ?*Host = if (self.registry.hosts.items.len > 0) self.registry.hosts.items[0] else null;
        for (self.registry.hosts.items) |host| {
            if (host.hwnd != null and host.hwnd == foreground) announcer = host;
        }
        for (self.registry.hosts.items) |host| host.updateNoticeChanged(host == announcer);
    }

    fn clearUpdateNotice(self: *App) void {
        if (self.update_notice) |*notice| {
            notice.deinit(self.core_app.alloc);
            self.update_notice = null;
            for (self.registry.hosts.items) |host| host.updateNoticeChanged(false);
        }
    }

    pub fn openUpdateNotice(self: *App) !void {
        const notice = self.update_notice orelse return;
        if (notice.staged) {
            if (!self.canApplyStagedUpdate()) {
                if (isPortableModeActive(self.core_app.alloc)) {
                    try self.showUpdateInfo(.err, updateApplyFailureMessage(error.NoStagedPortableInstall));
                    return;
                }
                if (notice.release_url) |url| {
                    try self.openUrl(url);
                    return;
                }
            }
            try self.requestApplyStagedUpdate();
            return;
        }
        try self.openUrl(notice.release_url.?);
    }

    /// A staged notice is recorded too, or it would come back at every launch.
    /// Only the dismissal is written: the staged install stays on disk, so a
    /// manual check can offer it again without downloading.
    pub fn dismissUpdateNotice(self: *App) void {
        if (self.update_notice == null) return;
        const state_path = updatepkg.defaultStatePath(self.core_app.alloc) catch |err| {
            log.warn("failed to resolve updater state path err={}", .{err});
            self.clearUpdateNotice();
            return;
        };
        defer self.core_app.alloc.free(state_path);
        self.dismissUpdateNoticeAt(state_path);
    }

    fn dismissUpdateNoticeAt(self: *App, state_path: []const u8) void {
        const notice = self.update_notice orelse return;
        if (notice.version_text) |version_text| {
            updatepkg.recordDismissal(self.core_app.alloc, state_path, version_text) catch |err| {
                log.warn("failed to record updater dismissal err={}", .{err});
            };
        }
        self.clearUpdateNotice();
    }

    test "dismissing a staged update notice records the dismissal and keeps the staged install" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();

        const alloc = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(root);
        const state_path = try std.fs.path.join(alloc, &.{ root, "update-state.json" });
        defer alloc.free(state_path);
        var staged: updatepkg.State = .{
            .staged_version = try alloc.dupe(u8, "1.3.200"),
            .staged_kind = .installer,
            .staged_installer_path = try alloc.dupe(u8, "setup.exe"),
            .staged_sha256 = try alloc.dupe(u8, "00"),
        };
        defer staged.deinit(alloc);
        try updatepkg.saveState(state_path, &staged);

        for ([_]bool{ true, false }) |is_staged| {
            app.update_notice = try UpdateNotice.init(alloc, "1.3.200", "https://example.invalid/release", is_staged);
            app.dismissUpdateNoticeAt(state_path);
            try std.testing.expectEqual(@as(?UpdateNotice, null), app.update_notice);

            var after = try updatepkg.loadState(alloc, state_path);
            defer after.deinit(alloc);
            try std.testing.expectEqualStrings("1.3.200", after.dismissed_version.?);
            try std.testing.expectEqualStrings("1.3.200", after.staged_version.?);
            try updatepkg.clearDismissal(alloc, state_path);
        }
    }

    pub fn applyStagedUpdate(self: *App) !void {
        if (self.update_apply_in_flight) return;
        self.update_apply_in_flight = true;
        errdefer self.update_apply_in_flight = false;
        const state_path = try updatepkg.defaultStatePath(self.core_app.alloc);
        defer self.core_app.alloc.free(state_path);

        // Re-resolve the feed rather than trusting the staged metadata: a
        // staged installer only stays applicable while the feed that
        // produced it is still the effective one.
        const release_feed_url = try updatepkg.resolveReleaseFeedUrl(
            self.core_app.alloc,
            self.config.@"auto-update-feed-url",
        );
        defer self.core_app.alloc.free(release_feed_url);

        const expected_kind: updatepkg.portable_apply.StagedKind =
            if (isPortableModeActive(self.core_app.alloc)) .portable else .installer;

        var staged = updatepkg.verifyStagedWindowsInstall(
            self.core_app.alloc,
            state_path,
            release_feed_url,
            expected_kind,
        ) catch |err| {
            self.showUpdateApplyFailure(err);
            return err;
        };
        defer staged.deinit(self.core_app.alloc);

        const install_dir = currentInstallDir(self.core_app.alloc) catch |err| {
            self.showUpdateApplyFailure(err);
            return err;
        };
        defer self.core_app.alloc.free(install_dir);

        if (staged.kind == .portable) {
            updatepkg.recordPortableApplyPending(self.core_app.alloc, state_path, 0) catch |err| {
                self.showUpdateApplyFailure(err);
                return err;
            };
            self.quitConfirmed();
            return;
        }

        if (!internal_os.windows.isInstallerManagedInstallDir(install_dir)) {
            self.showUpdateApplyFailure(error.InvalidInstallPath);
            return error.InvalidInstallPath;
        }

        const stage_dir = std.fs.path.dirname(staged.artifact_path) orelse return error.InvalidStagedInstallerPath;
        const log_path = try updatepkg.applyLogPathAlloc(self.core_app.alloc, staged.artifact_path);
        defer self.core_app.alloc.free(log_path);
        try std.fs.cwd().makePath(std.fs.path.dirname(log_path).?);

        const params = try buildInstallerApplyArgs(self.core_app.alloc, install_dir, log_path);
        defer self.core_app.alloc.free(params);

        const installer_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, staged.artifact_path);
        defer self.core_app.alloc.free(installer_w);
        const params_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, params);
        defer self.core_app.alloc.free(params_w);
        const stage_dir_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, stage_dir);
        defer self.core_app.alloc.free(stage_dir_w);

        // Only App-owned state follows this call; the click handler returns without touching Host.
        const result = sys.ShellExecuteW(
            null,
            shell_runas,
            installer_w.ptr,
            params_w.ptr,
            stage_dir_w.ptr,
            c.SW_SHOW,
        );
        if (@intFromPtr(result) <= 32) {
            self.showUpdateApplyFailure(error.UpdateApplyLaunchFailed);
            return error.UpdateApplyLaunchFailed;
        }

        updatepkg.recordStagedApplyRequested(self.core_app.alloc, state_path, 0) catch |err| {
            log.warn("failed to record updater apply request after launch err={}", .{err});
        };

        self.quitConfirmed();
    }

    /// Say in the banner why Install or Apply could not go ahead.
    fn showUpdateApplyFailure(self: *App, err: anyerror) void {
        self.showUpdateInfo(.err, updateApplyFailureMessage(err)) catch |banner_err| {
            log.warn("failed to show updater apply failure err={}", .{banner_err});
        };
    }

    /// Install quits the app and nothing watches Setup, so the next start is
    /// where a setup that did not replace this build is found. Only a
    /// setup-managed copy can have started one: the update state is shared by
    /// every copy of the user's, and an older Scoop or dev build starting after
    /// a successful install must not report (and consume) the request. Needs
    /// a window for the banner; without one the request stays for the next
    /// start.
    pub fn reportFailedInstallerApply(self: *App) void {
        if (self.installer_apply_checked) return;
        self.installer_apply_checked = true;
        if (self.installKind() != .installer) return;
        const state_path = updatepkg.defaultStatePath(self.core_app.alloc) catch return;
        defer self.core_app.alloc.free(state_path);
        const message = updatepkg.takeFailedInstallerApply(
            self.core_app.alloc,
            state_path,
            build_config.version,
        ) catch |err| {
            log.warn("failed to check the last installer apply err={}", .{err});
            return;
        } orelse return;
        defer self.core_app.alloc.free(message);
        log.warn("{s}", .{message});
        self.showUpdateInfo(.err, message) catch |err| {
            log.warn("failed to surface installer apply failure err={}", .{err});
        };
    }

    fn canApplyStagedUpdate(self: *App) bool {
        const state_path = updatepkg.defaultStatePath(self.core_app.alloc) catch return false;
        defer self.core_app.alloc.free(state_path);
        if (isPortableModeActive(self.core_app.alloc)) {
            return updatepkg.hasStagedWindowsInstall(self.core_app.alloc, state_path, .portable);
        }
        const install_dir = currentInstallDir(self.core_app.alloc) catch return false;
        defer self.core_app.alloc.free(install_dir);
        return internal_os.windows.isInstallerManagedInstallDir(install_dir) and
            updatepkg.hasStagedWindowsInstall(self.core_app.alloc, state_path, .installer);
    }

    /// Updater feedback in the banner. A failure is `.err`, so it stays
    /// until dismissed instead of counting down like an `.info` message.
    fn showUpdateInfo(self: *App, kind: HostBannerKind, message: []const u8) !void {
        // The window whose button was pressed, else the primary one. A host
        // with no tab (its last one detached for undo) still shows a banner.
        // Opening the release can pump messages, so check that the pressing
        // window is still open before using it.
        const pressed_in: ?*Host = if (self.update_action_host) |pressed| for (self.registry.hosts.items) |live| {
            if (live == pressed) break pressed;
        } else null else null;
        const host: ?*Host = pressed_in orelse blk: {
            if (self.registry.primarySurface()) |surface| if (surface.host) |value| break :blk value;
            break :blk if (self.registry.hosts.items.len > 0) self.registry.hosts.items[0] else null;
        };
        if (host) |value| return value.setBanner(kind, message);
        try showInfoMessage(.app, "noctty", message);
    }

    test "showUpdateInfo answers in the window whose banner button was pressed" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var first: Host = undefined;
        var second: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{
                .{ .storage = &first, .id = 1, .register = true },
                .{ .storage = &second, .id = 2, .register = true },
            },
        });
        defer session.deinit();

        app.update_action_host = &second;
        try app.showUpdateInfo(.err, "Install failed.");
        try std.testing.expectEqual(@as(?[:0]const u8, null), first.banner_text);
        try std.testing.expectEqualStrings("Install failed.", second.banner_text.?);

        // A pressing window that has since closed is not used.
        _ = app.registry.hosts.swapRemove(1);
        try app.showUpdateInfo(.err, "Still failed.");
        try std.testing.expectEqualStrings("Still failed.", first.banner_text.?);

        // With no pressed window and no surface to find the primary window
        // by, the first window answers rather than only the log.
        app.update_action_host = null;
        try app.showUpdateInfo(.info, "Up to date.");
        try std.testing.expectEqualStrings("Up to date.", first.banner_text.?);
    }

    fn showRecoverySafeModeNotice(_: *App, text: [:0]const u16) void {
        var thread = std.Thread.spawn(.{}, recoverySafeModeNoticeThread, .{text.ptr}) catch |err| {
            log.warn("win32 recovery: safe-mode notice thread failed err={}", .{err});
            return;
        };
        thread.detach();
    }

    /// True when any user-facing top-level UI window is still alive —
    /// either a terminal Host or the settings window. The quit timer
    /// and message-loop exit check both use this so the app doesn't
    /// tear down while the settings window holds an unsaved pending
    /// draft. Palette / confirm overlays are owned by their Host and
    /// therefore don't need their own count.
    pub fn hasLiveUiWindows(self: *const App) bool {
        if (self.registry.windows.items.len != 0) return true;
        if (self.settings_window.hwnd != null) return true;
        return false;
    }

    pub fn startQuitTimer(self: *App) void {
        if (!self.running) return;
        if (self.hasLiveUiWindows()) {
            self.stopQuitTimer();
            return;
        }
        if (!self.config.@"quit-after-last-window-closed") {
            self.stopQuitTimer();
            return;
        }

        const delay = self.config.@"quit-after-last-window-closed-delay" orelse {
            self.stopQuitTimer();
            self.running = false;
            sys.PostQuitMessage(0);
            return;
        };

        self.stopQuitTimer();
        const delay_ms = quitTimerDelayMs(delay);
        const timer_id = sys.SetTimer(null, 0, delay_ms, null);
        if (timer_id == 0) {
            log.err("failed to start win32 quit timer delay_ms={} err={}", .{
                delay_ms,
                windows.kernel32.GetLastError(),
            });
            return;
        }
        self.quit_timer_id = timer_id;
    }

    pub fn stopQuitTimer(self: *App) void {
        killThreadTimer(&self.quit_timer_id);
    }

    fn startTerminalHandoffIdleTimer(self: *App) void {
        self.stopTerminalHandoffIdleTimer();
        const timer_id = sys.SetTimer(null, 0, 5000, null);
        if (timer_id == 0) {
            log.err("failed to start terminal handoff idle timer err={}", .{windows.kernel32.GetLastError()});
            return;
        }
        self.terminal_handoff_idle_timer_id = timer_id;
    }

    fn stopTerminalHandoffIdleTimer(self: *App) void {
        killThreadTimer(&self.terminal_handoff_idle_timer_id);
    }

    /// Decide whether the embedding-mode server may exit, and close the race
    /// against an in-flight activation while deciding.
    ///
    /// Returning true means the class object has been revoked and no client
    /// can still be mid-activation, so the caller may quit. Returning false
    /// means a client holds the class object or a handoff is already queued;
    /// the class object is left registered (or re-registered) and the caller
    /// must keep running.
    fn exitEmbeddingServerIfIdle(self: *App) bool {
        const server = self.terminal_handoff_server orelse return true;

        // A client between CoGetClassObject and CreateInstance holds a
        // LockServer reference, and a client that created an ITerminalHandoff3
        // without locking still owns a live object. Exiting under either one
        // would fail its activation.
        if (server.isBusy()) return false;

        // Revoke first, then re-check. After the revoke no new activation can
        // arrive, so anything observed now is everything that can exist.
        if (!server.revoke()) return false;
        if (!server.isBusy()) return true;

        // Something landed in the gap between the check and the revoke. Take
        // the class object back and keep serving.
        server.register() catch |err| {
            log.err("failed to re-register terminal handoff class object err={}", .{err});
        };
        return false;
    }

    /// Schedule the next ready-marker attempt.
    ///
    /// `GetMessageW` blocks, so an idle app generates no further ticks and the
    /// retry budget would never be spent — an `initial-window = false` launch
    /// in particular can reach its quit timer without another tick at all,
    /// leaving the attempt unresolved on disk and the safe-mode notice
    /// unreleased. The timer both guarantees the attempt and spaces it out;
    /// a bare wake would busy-retry and could not outlast a handle hold.
    ///
    /// Bounded by `RecoveryReadyRetry`: only a failure that has not exhausted
    /// the budget reaches here, so at most
    /// `recovery_ready_persist_attempts - 1` timers are ever armed.
    /// Returns false when no retry could be armed. There is deliberately no
    /// wake fallback: a wake re-ticks immediately, so the remaining attempts
    /// would run back to back and the delay that lets a handle hold clear
    /// would be gone exactly when `SetTimer` failing says the session is
    /// already degraded. The caller stops instead.
    fn scheduleRecoveryRetry(self: *App) bool {
        self.stopRecoveryRetryTimer();
        const timer_id = sys.SetTimer(null, 0, recovery_ready_retry_delay_ms, null);
        if (timer_id == 0) {
            log.warn("failed to start win32 recovery retry timer err={}", .{windows.kernel32.GetLastError()});
            return false;
        }
        self.recovery_retry_timer_id = timer_id;
        self.recovery_retry_not_before_ms = sys.GetTickCount64() +| recovery_ready_retry_delay_ms;
        return true;
    }

    fn stopRecoveryRetryTimer(self: *App) void {
        killThreadTimer(&self.recovery_retry_timer_id);
    }

    /// The retry timer fired: this is the tick the deadline was holding out
    /// for, so clear it rather than re-checking the clock. `SetTimer` may
    /// deliver marginally early, and refusing its own tick would leave nothing
    /// armed to come back.
    fn onRecoveryRetryTimer(self: *App) void {
        self.stopRecoveryRetryTimer();
        self.recovery_retry_not_before_ms = null;
        self.resolveRecoveryStartup();
    }

    fn stopUndoPruneTimer(self: *App) void {
        killThreadTimer(&self.undo_prune_timer_id);
    }

    fn undoTimeoutMs(self: *const App) u64 {
        return std.math.divCeil(
            u64,
            self.config.@"undo-timeout".duration,
            std.time.ns_per_ms,
        ) catch std.math.maxInt(u64);
    }

    /// `undo-timeout = 0`: the prune timer takes every entry the moment it
    /// fires, so nothing can be restored. Only exactly 0 counts; a nonzero
    /// timeout leaves a window, however short.
    fn undoOff(self: *const App) bool {
        return self.undoTimeoutMs() == 0;
    }

    pub fn nextUndoSequence(self: *App) u64 {
        const sequence = self.next_undo_sequence;
        self.next_undo_sequence +%= 1;
        if (self.next_undo_sequence == 0) self.next_undo_sequence = 1;
        return sequence;
    }

    pub fn oldestUndoTimestamp(self: *const App) ?u64 {
        var oldest: ?u64 = null;
        for (self.registry.windows.items) |surface| {
            if (surface.undo_stack.oldestTimestamp()) |timestamp| {
                if (oldest == null or timestamp < oldest.?) oldest = timestamp;
            }
        }
        for (self.registry.hosts.items) |host| {
            if (host.oldestStructuralTimestamp()) |timestamp| {
                if (oldest == null or timestamp < oldest.?) oldest = timestamp;
            }
        }
        return oldest;
    }

    pub fn scheduleUndoPruneTimer(self: *App) void {
        self.scheduleUndoPruneTimerWithMinimum(1);
    }

    fn scheduleUndoPruneTimerWithMinimum(self: *App, minimum_delay_ms: u64) void {
        if (!self.running) return;
        self.stopUndoPruneTimer();

        const oldest = self.oldestUndoTimestamp() orelse return;
        const now = sys.GetTickCount64();
        const expires_at = oldest +| self.undoTimeoutMs() +| 1;
        const delay_ms = @max(minimum_delay_ms, if (expires_at <= now) 1 else expires_at - now);
        const timer_id = sys.SetTimer(
            null,
            0,
            @intCast(@min(delay_ms, std.math.maxInt(UINT))),
            null,
        );
        if (timer_id == 0) {
            log.warn("failed to start win32 undo prune timer err={}", .{
                windows.kernel32.GetLastError(),
            });
            return;
        }
        self.undo_prune_timer_id = timer_id;
    }

    pub fn pruneUndoHistoryBefore(self: *App, min_timestamp_ms: u64) bool {
        var complete = true;
        for (self.registry.windows.items) |surface| {
            surface.undo_stack.discardExpired(min_timestamp_ms);
        }

        var i: usize = 0;
        while (i < self.registry.hosts.items.len) {
            const host = self.registry.hosts.items[i];
            if (!host.pruneStructuralHistoryBefore(min_timestamp_ms)) complete = false;
            if (host.destroy_after_structural_dispose and host.tabs.items.len == 0 and !host.hasStructuralHistory()) {
                if (host.hwnd) |hwnd| {
                    _ = sys.DestroyWindow(hwnd);
                    self.removeHost(host);
                    continue;
                }
                host.destroy_after_structural_dispose = false;
            }
            if (i < self.registry.hosts.items.len and self.registry.hosts.items[i] == host) {
                i += 1;
            }
        }
        return complete;
    }

    fn pruneUndoHistoryNow(self: *App) void {
        const complete = self.pruneUndoHistoryBefore(self.undoCutoffTimestampMs());
        if (complete)
            self.scheduleUndoPruneTimer()
        else
            self.scheduleUndoPruneTimerWithMinimum(1000);
        if (self.running and !self.hasLiveUiWindows()) self.startQuitTimer();
    }

    /// A core search action for the pane `target` names. `anyerror`: the
    /// pane's search calls the core, which reports back through here.
    fn dockedSearchFor(self: *App, target: apprt.Target, in: docked_search.Input) anyerror!bool {
        const surface = self.registry.findSurfaceForTarget(target) orelse return false;
        _ = try surface.dockedSearch(in);
        return true;
    }

    fn ensureMessageQueue() void {
        var msg: MSG = undefined;
        _ = sys.PeekMessageW(&msg, null, 0, 0, c.PM_NOREMOVE);
    }

    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .quit => {
                self.postQuit(target);
                return true;
            },

            .new_window => {
                var forwarded_arguments = value.arguments;
                switch (scanForwardedToastActivation(value.arguments)) {
                    .none => {},
                    .malformed => {
                        std.log.warn("dropping malformed forwarded toast activation argv", .{});
                        return true;
                    },
                    .activation => |activation| {
                        const dropped_args = forwardedActivationExtraArgCount(value.arguments);
                        if (dropped_args > 0) {
                            std.log.warn("dropping {d} forwarded argv item(s) bundled with toast activation", .{dropped_args});
                        }
                        // A cold start forwards a click this process may
                        // also have had from the toast's popup handler.
                        if (!self.admitToastActivation(activation)) return true;
                        if (self.handleToastActivation(activation)) return true;
                        self.pending_toast_activation = activation;
                        forwarded_arguments = null;
                    },
                }
                var config = try apprt.surface.newConfig(
                    self.core_app,
                    &self.config,
                    .window,
                );
                defer config.deinit();
                // The forwarded argv reaches us over the single-instance IPC
                // pipe, so it is only as trusted as any process running as
                // this user. Refuse the whole request unless every key is on
                // the presentation allowlist.
                if (forwarded_arguments) |argv| {
                    if (forwardedArgvRejection(argv)) |rejection| {
                        logForwardedArgvRejection(rejection);
                        return true;
                    }
                }
                applyNewWindowArguments(self.core_app.alloc, &config, forwarded_arguments) catch |err| switch (err) {
                    // Defense in depth: `applyNewWindowArguments` enforces
                    // the same filter independently. Treat a rejection as
                    // handled so it cannot abort the app tick. Logged here
                    // too so the rejection can never become silent if the
                    // pre-check above is ever refactored away.
                    error.ForbiddenForwardedArgument => {
                        log.err(
                            "refusing forwarded new-window argv: rejected by applyNewWindowArguments",
                            .{},
                        );
                        return true;
                    },
                    else => return err,
                };
                // The launch comes after the arguments: with a theme set,
                // their `finalize` builds the config again from its replay
                // steps, which would drop the profile's variables, line and
                // directory. That rebuild replays the files as they were last
                // read, which during a palette theme preview are newer than
                // the app config's profiles and launch, so those are put back
                // before it; the arguments cannot set any of them
                // (`forwardedKeyAllowed`).
                if (forwarded_arguments) |argv| if (argv.len > 0) try pane_launch.keepSources(&config, &self.config);
                const launch = try pane_launch.prepare(&config, .{ .fresh = .{
                    .named_directory = if (forwarded_arguments) |argv| forwardedArgvSetsKey(argv, "working-directory") else false,
                } }, self.launchContext(null));
                if (config.@"launch-layout") |name| {
                    const banner_host = if (self.registry.findSurfaceForTarget(target)) |source| source.host else null;
                    _ = self.launchNamedLayout(name, banner_host);
                    return true;
                }
                const source = self.registry.newWindowSource(target);
                _ = self.createWindowSurface(&config, default_title, .{
                    .clone_state_from = source,
                    .forwarded_arguments = forwarded_arguments,
                    .launch = launch,
                }) catch |err| {
                    // A request forwarded by another process was acknowledged
                    // when it was queued, so say here that nothing opened.
                    // The first host still shows a banner while its last tab
                    // is detached for undo, when it has no surface.
                    const banner_host: ?*Host = if (source) |surface|
                        surface.host
                    else if (self.registry.hosts.items.len > 0) self.registry.hosts.items[0] else null;
                    if (banner_host) |host| host.setBanner(.err, "New window could not be opened.") catch {};
                    return err;
                };
                return true;
            },

            .launch_layout => {
                const banner_host = if (self.registry.findSurfaceForTarget(target)) |source| source.host else null;
                return layoutActionResult(self.launchNamedLayout(value.name, banner_host));
            },

            .save_layout => {
                return layoutActionResult(self.saveNamedLayout(target, value.name));
            },

            .new_window_elevated => {
                const alloc = self.core_app.alloc;
                const source = self.registry.findSurfaceForTarget(target);

                const cwd = cwd: {
                    if (source) |surface| {
                        if (surface.core().pwd(alloc) catch null) |live_pwd| {
                            if (live_pwd.len > 0) break :cwd live_pwd;
                            alloc.free(live_pwd);
                        }
                        if (surface.pwd) |cached_pwd| {
                            if (cached_pwd.len > 0) break :cwd try alloc.dupe(u8, cached_pwd);
                        }
                    }
                    if (self.startup_cwd) |startup_cwd| {
                        if (startup_cwd.len > 0) break :cwd try alloc.dupe(u8, startup_cwd);
                    }
                    break :cwd try std.process.getCwdAlloc(alloc);
                };
                defer alloc.free(cwd);

                var relaunch: win32_elevation.RelaunchProfile = .none;
                var temporary_profiles: ?[]windows_shell.Profile = null;
                defer if (temporary_profiles) |profiles| {
                    windows_shell.deinitProfiles(alloc, profiles);
                };
                const profile_key = elevatedProfileKey(
                    value.profile_key,
                    if (source) |surface| surface.launch_profile_key else null,
                );
                if (profile_key) |key| {
                    const source_host: ?*Host = if (source) |surface|
                        surface.host
                    else
                        null;
                    const found = (try self.elevatedWindowProfile(source_host, key, &temporary_profiles)) orelse {
                        log.warn("elevated window profile not found key={s}", .{key});
                        return false;
                    };
                    // An unknown token passes the profile as arguments,
                    // which start it whichever account UAC uses.
                    const same_account = same: {
                        const token_type = win32_elevation.processTokenElevationType() catch break :same false;
                        const elevated = win32_elevation.isProcessElevated() catch break :same false;
                        break :same win32_elevation.elevationKeepsAccount(token_type, elevated);
                    };
                    relaunch = if (elevatesBySelector(&self.config, key, same_account))
                        .{ .selector = key }
                    else
                        .{
                            .command = .{
                                .command = found.command,
                                // The elevated process reads the same config
                                // files, so it has the global `env` already; a
                                // profile defined only on the command line gets
                                // its own variables on the elevated command line.
                                // Never logged.
                                .env = if (found.user) |launch| launch.env else &.{},
                            },
                        };
                }

                const process_argv = try std.process.argsAlloc(alloc);
                defer std.process.argsFree(alloc, process_argv);
                const argv = try alloc.alloc([]const u8, process_argv.len);
                defer alloc.free(argv);
                for (process_argv, 0..) |arg, i| argv[i] = arg;

                const parameters = try win32_elevation.buildRelaunchParameters(
                    alloc,
                    argv,
                    self.config.class,
                    cwd,
                    self.startup_cwd orelse cwd,
                    relaunch,
                );
                errdefer alloc.free(parameters);

                // The terminal keeps its pwd in --working-directory; the
                // elevated host must not search that directory for programs.
                const host_cwd = try win32_elevation.elevatedHostDirectory(alloc);
                errdefer alloc.free(host_cwd);

                try self.deferShellRequest(.{ .elevated_window = .{
                    .parameters = parameters,
                    .cwd = host_cwd,
                } });
                return true;
            },

            .new_tab => {
                const source = self.registry.findSurfaceForTarget(target);
                _ = try self.createNewTab(source, null, false, false);
                return true;
            },

            .new_split => {
                const source = self.registry.findSurfaceForTarget(target) orelse return false;
                _ = try self.createNewSplit(source, splitDirectionFromAction(value), null, false);
                return true;
            },

            .close_tab => {
                return try self.closeTab(target, value);
            },

            .close_all_windows => {
                // Closing every window quits, as `quit` does.
                self.postQuit(target);
                return true;
            },

            .close_window => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    if (surface.host) |host| host.close();
                    return true;
                }

                return false;
            },

            .config_change => {
                switch (target) {
                    .app => {
                        var config = try value.config.clone(self.core_app.alloc);
                        // Profile lists are built from these keys, so a change to
                        // any of them drops every list the hosts and the jump
                        // list hold, as a new `ssh-config-hosts` does.
                        const profiles_changed =
                            self.config.@"ssh-config-hosts" != config.@"ssh-config-hosts" or
                            userProfileKeysChanged(&self.config, &config);
                        // Warn on the transition, not on every reload: the
                        // Settings checkbox and an edited config file both
                        // arrive here, and that is the only notice a user who
                        // turns blur on after startup would ever get.
                        const background_blur_newly_requested =
                            config.@"background-blur".win32BlurRequested() and
                            !self.config.@"background-blur".win32BlurRequested();
                        // CLI launch-layout is a one-shot startup/new-window
                        // request. Config reload reparses the original argv, so
                        // strip it before installing the long-lived app config.
                        // The startup request itself is not here to lose:
                        // `init` moved it to `startup_launch_layout` before its
                        // color-scheme sync, the first change to arrive here.
                        forgetLaunchLayout(&config);
                        // Palette theme preview owns a reversible baseline
                        // around the app-global config. An external/settings
                        // config change supersedes that transaction: dismiss
                        // the palette first so it reverts and resets every
                        // borrowed catalog before the incoming config replaces
                        // the baseline. A later Escape can never resurrect the
                        // stale pre-reload config.
                        for (self.registry.hosts.items) |host| {
                            if (host.overlay_mode == .command_palette) host.hideOverlay();
                        }
                        self.unregisterGlobalHotkeys();
                        self.config.deinit();
                        self.config = config;
                        self.restoreSettingsPreview();
                        if (background_blur_newly_requested) logBackgroundBlurUnsupported();
                        self.config_revision +%= 1;
                        if (self.config_revision == 0) self.config_revision = 1;
                        // Also with no Host open: a discovery still running
                        // used the old setting.
                        if (profiles_changed) self.profiles_generation +%= 1;
                        const jump_list_profiles_pending = profiles_changed and self.jump_list != null;
                        if (jump_list_profiles_pending) self.jump_list.?.updateProfiles(&.{}, self.cli_visual_studio_profiles_arg);
                        // Drop every list before asking for a new one: each drop
                        // bumps the generation, which would make a discovery
                        // started in between stale.
                        if (profiles_changed) {
                            for (self.registry.hosts.items) |host| host.invalidateProfiles();
                        }
                        for (self.registry.hosts.items) |host| {
                            if (profiles_changed and host.overlay_mode == .profile) {
                                host.requestProfiles();
                                host.refreshProfileChrome();
                            }
                            if (host.overlay_mode == .command_palette) host.rebuildPaletteList();
                        }
                        if (jump_list_profiles_pending) {
                            self.jump_list.?.requestProfileDiscovery();
                        }
                        self.scheduleGlobalHotkeySync();
                        self.reconfigureTheme();
                        for (self.registry.windows.items) |surface| {
                            try surface.applyRuntimeConfig(&self.config);
                        }
                        // A reload that turns automatic checks on in a process
                        // that started with them off (or on another channel).
                        if (self.registry.windows.items.len > 0 and self.update_startup_ready) self.maybeScheduleAutomaticUpdateCheck();
                        self.settings_window.externalConfigChanged(&self.config, self.config_revision);
                        self.refreshConfigProblems();
                        if (self.registry.windows.items.len == 0) {
                            self.startQuitTimer();
                        } else {
                            self.stopQuitTimer();
                        }
                    },
                    .surface => |core_surface| {
                        const surface = self.registry.findSurfaceByCore(core_surface) orelse return false;
                        try surface.applyRuntimeConfig(value.config);
                        surface.setTabBackground(value.config.background);
                        try self.syncHostWindowState(surface);
                    },
                }
                return true;
            },

            .reload_config => {
                // Recovery keeps its default config and cmd /D until restart.
                // In particular, a hard reload must not run default discovery
                // or load the startup files that safe mode bypassed.
                if (self.safe_mode) return true;
                if (value.soft) {
                    switch (target) {
                        .app => try self.core_app.updateConfig(self, &self.config),
                        .surface => |core_surface| try core_surface.updateConfig(&self.config),
                    }
                    return true;
                }

                if (target != .app) return false;

                // Same startup-cwd restoration dance as
                // `settingsSaveAndReload`: `Config.load` calls
                // `loadCliArgs`, which realpaths `--config-file
                // <relative>` against current cwd. After
                // `sanitizeCurrentDirectory()` ran, relative overrides
                // would resolve to a different file than launch used,
                // silently swapping the config source on every manual
                // reload. Scoped to this path — non-reload code keeps
                // seeing the sanitized cwd.
                //
                // The restore is deferred so it fires even when
                // `Config.load` returns an error — otherwise a
                // broken include leaves the process pinned to
                // `startup_cwd` (same class of bug as the one
                // fixed in `settingsSaveAndReload`). Relative-path
                // lookups + child processes spawned after a failed
                // reload would inherit the wrong cwd. It runs at the
                // end of this arm, after the config is applied, as it
                // always has here.
                var startup_cwd = self.enterStartupCwd();
                defer startup_cwd.restore();

                var config = try configpkg.Config.load(self.core_app.alloc);
                defer config.deinit();
                try self.core_app.updateConfig(self, &config);
                // A reload that found problems says so, whatever
                // `app-notifications` allows: "reloaded" would be false.
                // The config in effect, not the one just read: the app
                // applies its conditional state (dark system, `theme =
                // light:A,dark:B`) before it installs it.
                // config_change already recorded this load, including its
                // font checks; explicitly re-announce without scanning twice.
                if (self.reportRecordedConfigProblems()) return true;
                if (self.config.@"app-notifications".@"config-reload") {
                    try self.showDesktopNotification(.app, "noctty", "Configuration reloaded");
                }
                return true;
            },

            .present_terminal, .color_change, .mouse_over_link => {
                if (action == .present_terminal) {
                    if (self.registry.findSurfaceForTarget(target)) |surface| {
                        surface.present();
                        return true;
                    }
                    return false;
                }
                return true;
            },

            .renderer_health => {
                const surface = self.registry.findSurfaceForTarget(target) orelse return false;
                return surface.handleRendererHealth(value);
            },

            .quit_timer => {
                if (target != .app) return false;
                switch (value) {
                    .start => self.startQuitTimer(),
                    .stop => self.stopQuitTimer(),
                }
                return true;
            },

            .toggle_visibility => {
                self.windows_hidden = !self.windows_hidden;
                if (self.windows_hidden) {
                    for (self.registry.hosts.items) |host| host.hideForToggle();
                } else {
                    for (self.registry.hosts.items) |host| try host.showAfterToggle();
                    // Focus goes to a window that is on screen: a quick
                    // terminal dismissed before the hide stays dismissed.
                    if (self.registry.shownSurfaceForTarget(target)) |surface| self.activateSurface(surface);
                }
                return true;
            },

            .toggle_background_opacity => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    const changed = try surface.toggleBackgroundOpacity();
                    if (!changed) return false;
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .goto_window => {
                return try self.gotoWindow(target, value);
            },

            .goto_split => {
                return try self.gotoSplitFallback(target, value);
            },

            .resize_split => {
                return try self.resizeSplitFallback(target, value);
            },

            .equalize_splits => {
                return try self.equalizeSplitsFallback(target);
            },

            .move_tab => {
                return try self.moveTab(target, value);
            },

            .goto_tab => {
                return try self.gotoTab(target, value);
            },

            .toggle_tab_overview => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    return try surface.toggleTabOverview();
                }
                return false;
            },

            .cycle_focus_region => {
                const surface = self.registry.findSurfaceForTarget(target) orelse return false;
                const host = surface.host orelse return false;
                return host.cycleFocusRegionFromCurrentFocus(switch (value) {
                    .previous => .previous,
                    .next => .next,
                });
            },

            .toggle_quick_terminal => {
                try self.toggleQuickTerminal();
                return true;
            },

            .toggle_maximize => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    surface.toggleMaximize();
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .toggle_fullscreen => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.toggleFullscreen(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .toggle_window_decorations => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.toggleDecorations();
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .float_window => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setFloatWindow(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .initial_size => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setInitialSize(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .reset_window_size => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.resetWindowSize();
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .size_limit => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    surface.setSizeLimit(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .cell_size => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    surface.setCellSize(value);
                    try self.syncHostWindowState(surface);
                    return true;
                }
                return false;
            },

            .toggle_split_zoom => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    const found = Host.findTabForSurface(surface) orelse return false;
                    const handle = found.tab.findHandle(surface) orelse found.tab.focused;
                    found.tab.tree.zoom(if (found.tab.tree.zoomed != null) null else handle);
                    surface.invalidateRedoForUnsupportedTabStructuralAction();
                    try found.host.layout();
                    return true;
                }
                return false;
            },

            .render => {
                return switch (target) {
                    .app => blk: {
                        for (self.registry.windows.items) |surface| try self.renderSurface(surface);
                        break :blk true;
                    },
                    .surface => if (self.registry.findSurfaceForTarget(target)) |surface| blk: {
                        try self.renderSurface(surface);
                        break :blk true;
                    } else false,
                };
            },

            .render_inspector => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    surface.redrawInspector();
                    return true;
                }

                return false;
            },

            .inspector => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    return try self.setInspectorActionForSurface(surface, value);
                }
                return false;
            },

            .show_gtk_inspector => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    return try self.setInspectorActionForSurface(surface, .show);
                }
                return false;
            },

            .set_title => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setTitle(value.title);
                    return true;
                }

                return false;
            },

            .set_tab_title => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setTabTitleOverride(if (value.title.len == 0) null else value.title);
                    return true;
                }

                return false;
            },

            .prompt_title => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.promptTitle(value);
                    return true;
                }

                return false;
            },

            .toggle_command_palette => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    return try surface.toggleCommandPalette();
                }
                return false;
            },

            .toggle_quick_select => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    return try surface.toggleQuickSelect();
                }
                return false;
            },

            .pwd => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setPwd(value.pwd);
                    if (self.jump_list) |*jump_list| jump_list.noteRecent(value.pwd);
                    return true;
                }

                return false;
            },

            .mouse_shape => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    surface.setMouseShape(value);
                    return true;
                }
                return false;
            },

            .mouse_visibility => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    surface.setMouseVisibility(value);
                    return true;
                }
                return false;
            },

            .progress_report => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setProgressReport(value);
                    return true;
                }
                return false;
            },

            .program_status => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try self.applyProgramStatus(surface, value);
                    return true;
                }
                return false;
            },

            .goto_attention => return try self.gotoAttention(target),

            .command_finished => {
                try self.showCommandFinished(target, value);
                return true;
            },

            .start_search => return try self.dockedSearchFor(target, .{ .open = value.needle }),

            .end_search => return try self.dockedSearchFor(target, .{ .core = .ended }),

            .search_total => return try self.dockedSearchFor(target, .{ .core = .{ .total = .{
                .total = value.total,
                .invalid = value.invalid,
            } } }),

            .search_selected => return try self.dockedSearchFor(target, .{ .core = .{ .selected = value.selected } }),

            .search_match_rows => return try self.dockedSearchFor(target, .{ .core = .{ .rows = value.rows } }),

            .secure_input => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setSecureInput(value);
                    return true;
                }
                return false;
            },

            // The core enforces read-only input. There is no separate chrome
            // indicator now that the dormant status bar has been removed.
            .readonly => return self.registry.findSurfaceForTarget(target) != null,

            .key_sequence => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setKeySequenceActive(switch (value) {
                        .trigger => true,
                        .end => false,
                    });
                    return true;
                }
                return false;
            },

            .key_table => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setKeyTable(value);
                    return true;
                }
                return false;
            },

            .scrollbar => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    try surface.setScrollbar(value);
                    return true;
                }
                return false;
            },

            .undo => {
                self.pruneUndoHistoryNow();
                const surface = self.undoRedoSurfaceForTarget(target) orelse {
                    const host = self.structuralUndoHostForTarget(target) orelse return false;
                    while (host.peekStructuralUndo() != null) {
                        const message = try host.applyLatestStructuralUndo() orelse continue;
                        try host.setBanner(.info, message);
                        return true;
                    }
                    try host.setBanner(.info, "Nothing to undo.");
                    return true;
                };

                while (true) {
                    const host_entry = if (surface.host) |host| host.peekStructuralUndo() else null;
                    const local_entry = surface.undo_stack.peekUndo();

                    if (host_entry == null and local_entry == null) break;
                    const use_host = host_entry != null and
                        (local_entry == null or win32_structural_history.sortsAfter(
                            host_entry.?.timestamp_ms,
                            host_entry.?.sequence_id,
                            local_entry.?.timestamp_ms,
                            local_entry.?.sequence_id,
                        ));

                    if (use_host) {
                        const host = surface.host orelse break;
                        const message = try host.applyLatestStructuralUndo() orelse continue;
                        _ = try self.showHostBanner(.{ .surface = surface.core() }, .info, message);
                        return true;
                    }

                    const message = try surface.applyLatestLocalUndo() orelse continue;
                    _ = try self.showHostBanner(.{ .surface = surface.core() }, .info, message);
                    return true;
                }

                // A key press on the pane and the palette both target the
                // surface. The default binding is performable, so report that
                // nothing was undone and the chord goes on to the program in
                // the pane (the palette says so itself, see invokePaletteRow).
                // An app-level request gets the banner.
                if (target == .surface) return false;
                _ = try self.showHostBanner(.{ .surface = surface.core() }, .info, "Nothing to undo.");
                return true;
            },

            .redo => {
                self.pruneUndoHistoryNow();
                const surface = self.undoRedoSurfaceForTarget(target) orelse {
                    const host = self.structuralRedoHostForTarget(target) orelse return false;
                    while (host.peekStructuralRedo() != null) {
                        const message = try host.applyLatestStructuralRedo() orelse continue;
                        try host.setBanner(.info, message);
                        return true;
                    }
                    try host.setBanner(.info, "Nothing to redo.");
                    return true;
                };

                while (true) {
                    const host_entry = if (surface.host) |host| host.peekStructuralRedo() else null;
                    const local_entry = surface.undo_stack.peekRedo();

                    if (host_entry == null and local_entry == null) break;
                    const use_host = host_entry != null and
                        (local_entry == null or win32_structural_history.sortsAfter(
                            host_entry.?.timestamp_ms,
                            host_entry.?.sequence_id,
                            local_entry.?.timestamp_ms,
                            local_entry.?.sequence_id,
                        ));

                    if (use_host) {
                        const host = surface.host orelse break;
                        const message = try host.applyLatestStructuralRedo() orelse continue;
                        _ = try self.showHostBanner(.{ .surface = surface.core() }, .info, message);
                        return true;
                    }

                    const message = try surface.applyLatestLocalRedo() orelse continue;
                    _ = try self.showHostBanner(.{ .surface = surface.core() }, .info, message);
                    return true;
                }

                // See undo: a surface-targeted request with nothing to redo
                // is not performed, so a performable binding lets the key through.
                if (target == .surface) return false;
                _ = try self.showHostBanner(.{ .surface = surface.core() }, .info, "Nothing to redo.");
                return true;
            },

            .check_for_updates => {
                if (self.config.@"auto-update-channel" != .stable) {
                    _ = try self.showHostBanner(target, .info, "Automatic prerelease update checks are not supported yet. Opening releases.");
                    try self.openUrl(releases_url);
                    return true;
                }

                try self.scheduleUpdateCheck(.{
                    .force = true,
                    .manual = true,
                    .respect_dismissal = false,
                });
                return true;
            },

            .open_url => {
                self.openLink(target, value.url) catch |err| {
                    // A click that does nothing reads as a broken terminal.
                    if (err == error.OpenUrlRejected) {
                        _ = self.showHostBanner(target, .info, labels.open_refused_banner) catch false;
                    }
                    return err;
                };
                return true;
            },

            .show_on_screen_keyboard => {
                try self.showOnScreenKeyboard();
                return true;
            },

            .open_config => {
                self.settings_open_trace.note(.open_config_action);
                try self.openConfig();
                return true;
            },

            .copy_title_to_clipboard => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    const title = surface.getTitle() orelse return false;
                    try surface.writeClipboardText(title);
                    return true;
                }
                return false;
            },

            .ring_bell => {
                self.ringBell(target);
                return true;
            },

            .desktop_notification => {
                try self.showDesktopNotification(target, value.title, value.body);
                return true;
            },

            .show_child_exited => {
                try self.showChildExited(target, value);
                return true;
            },
        }
    }

    pub fn performIpc(
        alloc: Allocator,
        target: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        value: apprt.ipc.Action.Value(action),
        response_timeout_ms: u64,
    ) !bool {
        switch (action) {
            .new_window => {
                const launch_layout = scanLaunchLayoutIpcArgument(value.arguments) catch |err| {
                    log.err("--launch-layout must be the only +new-window argument", .{});
                    return err;
                };

                const elevated = try win32_elevation.isProcessElevated();
                const pipe_name = try resolveIpcPipeNameForTarget(
                    alloc,
                    target,
                    elevated,
                );
                defer alloc.free(pipe_name);
                const forwarded = switch (launch_layout) {
                    .none => sent: {
                        // Settings the instance applies to every window are
                        // left out, so the request is not refused for them.
                        const arguments = try withoutAppWideArguments(alloc, value.arguments);
                        defer if (arguments) |argv| alloc.free(argv);
                        break :sent try sendNewWindowIpc(alloc, pipe_name, elevated, arguments, response_timeout_ms);
                    },
                    .name => |name| try sendLaunchLayoutIpc(alloc, pipe_name, elevated, name, response_timeout_ms),
                };
                if (forwarded) return true;
                return try spawnWindowProcess(alloc, target, value);
            },
        }
    }

    pub fn queryAutomationWindowList(
        alloc: Allocator,
        target: apprt.ipc.Target,
        response_timeout_ms: u64,
    ) !?[]u8 {
        const elevated = try win32_elevation.isProcessElevated();
        const pipe_name = try resolveIpcPipeNameForTarget(alloc, target, elevated);
        defer alloc.free(pipe_name);
        return try sendListWindowsIpc(alloc, pipe_name, elevated, response_timeout_ms);
    }

    pub fn performAutomationAction(
        alloc: Allocator,
        target: apprt.ipc.Target,
        action_target: apprt.ipc.AutomationActionTarget,
        action_text: []const u8,
        response_timeout_ms: u64,
    ) !bool {
        const elevated = try win32_elevation.isProcessElevated();
        const pipe_name = try resolveIpcPipeNameForTarget(alloc, target, elevated);
        defer alloc.free(pipe_name);
        return try sendPerformActionIpc(alloc, pipe_name, elevated, action_target, action_text, response_timeout_ms);
    }

    pub fn focusAutomationTarget(
        alloc: Allocator,
        instance_target: apprt.ipc.Target,
        automation_target: apprt.ipc.AutomationTarget,
        response_timeout_ms: u64,
    ) !bool {
        const elevated = try win32_elevation.isProcessElevated();
        const pipe_name = try resolveIpcPipeNameForTarget(alloc, instance_target, elevated);
        defer alloc.free(pipe_name);
        return try sendFocusIpc(alloc, pipe_name, elevated, automation_target, response_timeout_ms);
    }

    pub fn newAutomationTab(
        alloc: Allocator,
        instance_target: apprt.ipc.Target,
        automation_target: apprt.ipc.AutomationTarget,
        working_directory: ?[]const u8,
        response_timeout_ms: u64,
    ) !bool {
        const elevated = try win32_elevation.isProcessElevated();
        const pipe_name = try resolveIpcPipeNameForTarget(alloc, instance_target, elevated);
        defer alloc.free(pipe_name);
        return try sendNewTabIpc(
            alloc,
            pipe_name,
            elevated,
            automation_target,
            working_directory,
            response_timeout_ms,
        );
    }

    pub fn newAutomationSplit(
        alloc: Allocator,
        instance_target: apprt.ipc.Target,
        automation_target: apprt.ipc.AutomationTarget,
        direction: apprt.ipc.AutomationSplitDirection,
        working_directory: ?[]const u8,
        response_timeout_ms: u64,
    ) !bool {
        const elevated = try win32_elevation.isProcessElevated();
        const pipe_name = try resolveIpcPipeNameForTarget(alloc, instance_target, elevated);
        defer alloc.free(pipe_name);
        return try sendNewSplitIpc(
            alloc,
            pipe_name,
            elevated,
            automation_target,
            direction,
            working_directory,
            response_timeout_ms,
        );
    }

    pub fn sendAutomationText(
        alloc: Allocator,
        instance_target: apprt.ipc.Target,
        automation_target: apprt.ipc.AutomationTarget,
        text: []const u8,
        response_timeout_ms: u64,
    ) !bool {
        const elevated = try win32_elevation.isProcessElevated();
        const pipe_name = try resolveIpcPipeNameForTarget(alloc, instance_target, elevated);
        defer alloc.free(pipe_name);
        return try sendAutomationTextIpc(
            alloc,
            pipe_name,
            elevated,
            automation_target,
            text,
            response_timeout_ms,
        );
    }

    pub fn performAutomationCommand(self: *App, command: apprt.ipc.AutomationCommand) !void {
        switch (command) {
            .new_tab => |value| {
                if (value.working_directory) |cwd| {
                    if (!automationWorkingDirectoryAllowed(cwd)) return error.AutomationPolicyRefused;
                }
                const resolved: struct {
                    source: ?*Surface,
                    explicit_window_target: bool,
                } = switch (value.target) {
                    .focused => .{
                        .source = self.automationDefaultSurface(),
                        .explicit_window_target = false,
                    },
                    .window_id => |id| .{
                        .source = self.registry.activeSurfaceForHost(id),
                        .explicit_window_target = true,
                    },
                    .surface_id => return error.InvalidAutomationTarget,
                };
                const source = resolved.source orelse return error.AutomationTargetNotFound;
                _ = try self.createNewTab(
                    source,
                    value.working_directory,
                    resolved.explicit_window_target,
                    true,
                );
            },
            .new_split => |value| {
                if (value.working_directory) |cwd| {
                    if (!automationWorkingDirectoryAllowed(cwd)) return error.AutomationPolicyRefused;
                }
                const source = switch (value.target) {
                    .focused => self.automationDefaultSurface(),
                    .surface_id => |id| self.registry.findSurfaceById(id),
                    .window_id => return error.InvalidAutomationTarget,
                } orelse return error.AutomationTargetNotFound;
                const direction: SplitTreeSurface.Split.Direction = switch (value.direction) {
                    .left => .left,
                    .right => .right,
                    .up => .up,
                    .down => .down,
                };
                _ = try self.createNewSplit(source, direction, value.working_directory, true);
            },
            .focus => |target| {
                const surface = switch (target) {
                    .surface_id => |id| self.registry.findLiveSurfaceById(id),
                    .window_id => |id| self.registry.activeSurfaceForHost(id),
                    .focused => return error.InvalidAutomationTarget,
                } orelse return error.AutomationTargetNotFound;
                self.activateSurface(surface);
            },
            .send_text => |value| {
                const surface = switch (value.target) {
                    .surface_id => |id| self.registry.findLiveSurfaceById(id),
                    .focused, .window_id => return error.InvalidAutomationTarget,
                } orelse return error.AutomationTargetNotFound;
                if (!automationTextAllowed(value.text)) return error.AutomationPolicyRefused;
                surface.noteProgramInput();

                const text_z = try self.core_app.alloc.dupeZ(u8, value.text);
                defer self.core_app.alloc.free(text_z);
                if (self.test_automation_paste) |paste| {
                    paste(surface, .paste, text_z, false) catch |err| switch (err) {
                        error.UnsafePaste => return error.AutomationPolicyRefused,
                        else => return err,
                    };
                } else {
                    surface.core().completeClipboardRequest(.paste, text_z, false) catch |err| switch (err) {
                        error.UnsafePaste => return error.AutomationPolicyRefused,
                        else => return err,
                    };
                }
            },
        }
    }

    pub fn buildAutomationWindowListJson(
        self: *App,
        alloc: Allocator,
    ) ![]u8 {
        var snapshot = try self.buildAutomationWindowList(alloc);
        defer snapshot.deinit(alloc);

        var buf: std.Io.Writer.Allocating = .init(alloc);
        errdefer buf.deinit();
        try buf.writer.print("{f}", .{std.json.fmt(snapshot, .{})});
        return try buf.toOwnedSlice();
    }

    fn buildAutomationWindowList(
        self: *App,
        alloc: Allocator,
    ) !apprt.ipc.AutomationWindowList {
        const namespace = self.ipc_namespace orelse return error.IpcServerNotStarted;
        var instance: apprt.ipc.AutomationInstance = instance: {
            const version = try alloc.dupe(u8, build_config.version_string);
            errdefer alloc.free(version);
            const namespace_copy = try alloc.dupe(u8, namespace);
            break :instance .{
                .pid = sys.GetCurrentProcessId(),
                .version = version,
                .class = namespace_copy,
            };
        };
        errdefer instance.deinit(alloc);

        const window_entries = try alloc.alloc(apprt.ipc.AutomationWindow, self.automationWindowCount());
        var built: usize = 0;
        errdefer {
            for (window_entries[0..built]) |*window| window.deinit(alloc);
            alloc.free(window_entries);
        }

        for (self.registry.hosts.items) |host| {
            if (host.tabs.items.len == 0) continue;
            window_entries[built] = try self.buildAutomationWindow(alloc, host);
            built += 1;
        }

        return .{ .instance = instance, .windows = window_entries };
    }

    fn automationWindowCount(self: *const App) usize {
        var count: usize = 0;
        for (self.registry.hosts.items) |host| {
            if (host.tabs.items.len == 0) continue;
            count += 1;
        }
        return count;
    }

    fn buildAutomationWindow(
        self: *App,
        alloc: Allocator,
        host: *Host,
    ) !apprt.ipc.AutomationWindow {
        const tabs = try alloc.alloc(apprt.ipc.AutomationTab, host.tabs.items.len);
        var built: usize = 0;
        errdefer {
            for (tabs[0..built]) |*tab| tab.deinit(alloc);
            alloc.free(tabs);
        }

        var active_tab_id: ?u32 = null;
        for (host.tabs.items, 0..) |*tab, i| {
            const active = i == host.active_tab;
            tabs[i] = try self.buildAutomationTab(alloc, tab, active);
            if (active) active_tab_id = tab.id;
            built += 1;
        }

        const title = try alloc.dupe(u8, host.cached_window_title orelse "noctty");

        return .{
            .window_id = host.id,
            .title = title,
            // `GetForegroundWindow` returns the top-level host even when the
            // keyboard focus is in one of its child controls. Surface focus
            // alone would incorrectly report every host as unfocused then.
            .focused = automationHostFocused(
                host.hwnd,
                sys.GetForegroundWindow(),
                if (host.activeSurface()) |surface| surface.window_focused else false,
            ),
            .active_tab_id = active_tab_id,
            .tab_count = @intCast(tabs.len),
            .pane_count = automationPaneCount(tabs),
            .tabs = tabs,
        };
    }

    fn buildAutomationTab(
        self: *App,
        alloc: Allocator,
        tab: *const Tab,
        active: bool,
    ) !apprt.ipc.AutomationTab {
        var panes: std.ArrayList(apprt.ipc.AutomationPane) = .empty;
        // Registration order matters: `defer` and `errdefer` run LIFO, so the
        // per-pane string cleanup must be registered AFTER the list teardown
        // in order to run BEFORE it. The reverse order reads `panes.items`
        // after `deinit` has freed the backing buffer.
        defer panes.deinit(alloc);
        errdefer for (panes.items) |*pane| pane.deinit(alloc);

        const focused_surface = tab.focusedSurface();
        var it = tab.tree.iterator();
        while (it.next()) |entry| {
            const title = if (entry.view.effectiveTitle()) |value|
                try alloc.dupe(u8, value)
            else
                null;
            errdefer if (title) |value| alloc.free(value);
            const working_directory = if (self.test_automation_pwd) |query|
                try query(alloc, entry.view)
            else
                try entry.view.core().pwd(alloc);
            errdefer if (working_directory) |value| alloc.free(value);
            try panes.append(alloc, .{
                .surface_id = entry.view.core().id,
                .title = title,
                .working_directory = working_directory,
                .focused = if (focused_surface) |surface| surface == entry.view else false,
                // True only for the focused pane in the active tab, not every
                // tab-local focused pane.
                .active = active and (if (focused_surface) |surface| surface == entry.view else false),
            });
        }

        return .{
            .tab_id = tab.id,
            .active = active,
            .focused_surface_id = if (focused_surface) |surface| surface.core().id else null,
            .pane_count = @intCast(panes.items.len),
            .panes = try panes.toOwnedSlice(alloc),
        };
    }

    fn automationPaneCount(tabs: []const apprt.ipc.AutomationTab) u64 {
        var count: u64 = 0;
        for (tabs) |tab| count += @intCast(tab.panes.len);
        return count;
    }

    fn spawnWindowProcess(
        alloc: Allocator,
        target: apprt.ipc.Target,
        value: apprt.ipc.Action.NewWindow,
    ) !bool {
        const exe_path = try std.fs.selfExePathAlloc(alloc);
        defer alloc.free(exe_path);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);

        try argv.append(alloc, exe_path);
        if (target == .class) {
            const class_arg = try std.fmt.allocPrint(alloc, "--class={s}", .{target.class});
            defer alloc.free(class_arg);
            try argv.append(alloc, class_arg);
        }
        if (value.arguments) |arguments| {
            for (arguments) |arg| try argv.append(alloc, arg);
        }

        var child = std.process.Child.init(argv.items, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try internal_os.windows.spawnChildHoldingInheritLock(&child);
        return true;
    }

    pub fn ensureWindowClass(self: *App) !void {
        if (self.class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = c.CS_OWNDC,
            .lpfnWndProc = &windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = loadAppIcon(self.hinstance, false),
            .hCursor = sys.LoadCursorW(null, c.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = loadAppIcon(self.hinstance, true),
        };

        self.class_atom = sys.RegisterClassExW(&wc);
        if (self.class_atom == 0) {
            return lastError();
        }
    }

    fn ensureHostWindowClass(self: *App) !void {
        if (self.host_class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &hostWindowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = loadAppIcon(self.hinstance, false),
            .hCursor = sys.LoadCursorW(null, c.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = host_class_name,
            .hIconSm = loadAppIcon(self.hinstance, true),
        };

        self.host_class_atom = sys.RegisterClassExW(&wc);
        if (self.host_class_atom == 0) {
            return lastError();
        }
    }

    pub const ensurePaletteListClass = palette_controller.AppControls.ensurePaletteListClass;

    pub fn ensureTabTooltipClass(self: *App) !void {
        if (self.tab_tooltip_class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &tabTooltipProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = sys.LoadCursorW(null, c.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = tab_tooltip_class_name,
            .hIconSm = null,
        };

        self.tab_tooltip_class_atom = sys.RegisterClassExW(&wc);
        if (self.tab_tooltip_class_atom == 0) {
            return lastError();
        }
    }

    fn ensureScrollbarClass(self: *App) !void {
        if (self.scrollbar_class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &scrollbarProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = sys.LoadCursorW(null, c.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = scrollbar_class_name,
            .hIconSm = null,
        };

        self.scrollbar_class_atom = sys.RegisterClassExW(&wc);
        if (self.scrollbar_class_atom == 0) {
            return lastError();
        }
    }

    pub fn ensureQuickSelectClass(self: *App) !void {
        if (self.quick_select_class_atom != 0) return;

        var wc: WNDCLASSEXW = .{
            .cbSize = @sizeOf(WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = &quickSelectProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = null,
            .hCursor = sys.LoadCursorW(null, c.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = quick_select_class_name,
            .hIconSm = null,
        };

        self.quick_select_class_atom = sys.RegisterClassExW(&wc);
        if (self.quick_select_class_atom == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
    }

    pub fn createWindowSurface(
        self: *App,
        config: *const configpkg.Config,
        title: LPCWSTR,
        opts: SurfaceInitOptions,
    ) !*Surface {
        // What the surface keeps of its launch is copied before the surface
        // exists: once it does it is its window's, so nothing after it may
        // fail (a restore's transaction learns the window only from the
        // surface returned, and a forwarded new window says it could not be
        // opened when this fails).
        const alloc = self.core_app.alloc;
        const key = if (opts.launch.key) |value| try alloc.dupeZ(u8, value) else null;
        errdefer if (key) |value| alloc.free(value);
        const tab_title = if (opts.launch.title) |value| try alloc.dupeZ(u8, value) else null;
        errdefer if (tab_title) |value| alloc.free(value);
        const surface = if (self.test_create_window_surface) |hook|
            try hook(self, config, title, opts)
        else blk: {
            const created = try alloc.create(Surface);
            errdefer alloc.destroy(created);
            try created.init(self, title, config, opts);
            if (opts.host_id == null) self.consumePendingToastActivation();
            break :blk created;
        };
        recordLaunch(alloc, surface, key, opts.launch.ssh, tab_title);
        return surface;
    }

    /// What a surface keeps of its launch: the key that splits, session
    /// restore and elevation look its profile up by, whether it connects
    /// over SSH, and the SSH alias as its tab title. It takes `key` and
    /// `tab_title`, copies in `alloc`, and cannot fail.
    fn recordLaunch(alloc: Allocator, surface: *Surface, key: ?[:0]const u8, ssh: bool, tab_title: ?[:0]const u8) void {
        if (key) |value| adoptOwnedString(alloc, &surface.launch_profile_key, value);
        if (ssh) surface.launched_ssh = true;
        if (tab_title) |value| adoptOwnedString(alloc, &surface.tab_title_override, value);
    }

    /// Put `value`, allocated in `alloc`, in `target`, as `appendOwnedString`
    /// puts a copy: an equal string already there stays, and `value` is
    /// freed.
    fn adoptOwnedString(alloc: Allocator, target: *?[:0]const u8, value: [:0]const u8) void {
        if (target.*) |old| {
            if (std.mem.eql(u8, old, value)) return alloc.free(value);
            alloc.free(old);
        }
        target.* = value;
    }

    test "a surface's launch is copied before the surface exists, so a failure leaves no surface" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var created: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .surfaces = &.{.{ .storage = &created, .free_launch_profile_key_on_deinit = true }},
        });
        defer session.deinit();
        defer appendOwnedString(std.testing.allocator, &created.tab_title_override, null) catch unreachable;

        const Hook = struct {
            var surface: *Surface = undefined;
            var calls: usize = 0;

            fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, _: SurfaceInitOptions) anyerror!*Surface {
                calls += 1;
                return surface;
            }
        };
        Hook.surface = &created;
        Hook.calls = 0;
        app.test_create_window_surface = &Hook.createSurface;

        const launch: pane_launch.Stamp = .{ .key = "ssh:prod", .ssh = true, .title = "prod" };
        // The key's copy fails, then the title's: no surface is made, so a
        // restore's transaction never misses one, and nothing leaks.
        for (0..2) |fail_index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            core_app.alloc = failing.allocator();
            defer core_app.alloc = std.testing.allocator;
            try std.testing.expectError(error.OutOfMemory, app.createWindowSurface(&app.config, default_title, .{ .launch = launch }));
            try std.testing.expectEqual(@as(usize, 0), Hook.calls);
        }
        // Past the copies nothing allocates: a surface made is a whole one.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
        core_app.alloc = failing.allocator();
        defer core_app.alloc = std.testing.allocator;
        const surface = try app.createWindowSurface(&app.config, default_title, .{ .launch = launch });
        try std.testing.expectEqual(@as(usize, 1), Hook.calls);
        try std.testing.expectEqualStrings("ssh:prod", surface.launch_profile_key orelse "");
        try std.testing.expect(surface.launched_ssh);
        try std.testing.expectEqualStrings("prod", surface.tab_title_override orelse "");
    }

    /// What `pane_launch.prepare` asks of the app about a new pane.
    pub const LaunchContext = struct {
        app: *App,
        /// The window the pane opens in; null for a new one.
        host: ?*Host,
        /// The process's first pane, which runs `initial-command` (`-e`).
        first: bool,

        pub fn windowed(self: LaunchContext) bool {
            return self.host != null;
        }

        pub fn listed(self: LaunchContext, key: []const u8) !?*const windows_shell.Profile {
            const host = self.host orelse return null;
            return try host.profileForKey(key);
        }

        pub fn discover(self: LaunchContext, alloc: Allocator) ![]windows_shell.Profile {
            return try listProfilesForConfig(alloc, &self.app.config, windows_shell.listProfiles);
        }

        pub fn automatic(_: LaunchContext, alloc: Allocator) !configpkg.Command {
            return try windows_shell.defaultCommand(alloc);
        }
    };

    pub fn launchContext(self: *App, host: ?*Host) LaunchContext {
        return .{ .app = self, .host = host, .first = self.core_app.first };
    }

    /// What `surface` launched, for a pane that repeats its launch or starts
    /// its profile.
    fn launchSource(surface: *const Surface) pane_launch.Source {
        return .{
            .command = surface.launch_command,
            .user = surface.launch_user,
            .key = surface.launch_profile_key,
            .ssh = surface.launched_ssh,
        };
    }

    fn createNewTab(
        self: *App,
        source: ?*Surface,
        working_directory: ?[]const u8,
        explicit_window_target: bool,
        inherit_launch_config: bool,
    ) !*Surface {
        var config = try apprt.surface.newConfig(self.core_app, &self.config, .tab);
        defer config.deinit();

        if (shouldResetNewTabWorkingDirectory(
            explicit_window_target,
            inherit_launch_config,
            if (source) |surface| surface.launched_ssh else false,
        )) {
            // `newConfig(.tab)` consults the globally focused surface. Reset
            // and inherit from the explicitly requested host instead. An SSH
            // source also needs the reset because its live cwd is remote.
            config.@"working-directory" = self.config.@"working-directory";
        }
        // newConfig inherits only the focused surface's working directory;
        // Launch command selection is app-runtime state and must be
        // inherited from the source snapshot rather than re-resolved from
        // mutable global/profile configuration. It comes before the
        // explicit target's directory, which reads the command for its WSL
        // fallback.
        const inherited: ?*Surface = if (inherit_launch_config) source else null;
        var launch: pane_launch.Stamp = if (inherited) |surface|
            try pane_launch.prepare(&config, .{ .inherit = launchSource(surface) }, self.launchContext(surface.host))
        else
            .{};
        if (source) |surface| {
            if (explicit_window_target and shouldInheritSplitWorkingDirectory(surface.launched_ssh)) {
                const split_inherit = config.@"split-inherit-working-directory";
                {
                    defer config.@"split-inherit-working-directory" = split_inherit;
                    config.@"split-inherit-working-directory" = config.@"tab-inherit-working-directory";
                    _ = try applySplitWorkingDirectoryFromSource(self, &config, surface, self.startup_cwd);
                }
            }
        }
        // A tab that inherits no launch runs the default profile, if any.
        if (inherited == null) launch = try pane_launch.prepare(&config, .{ .fresh = .{} }, self.launchContext(null));
        if (working_directory) |cwd| try applyAutomationWorkingDirectory(&config, cwd);
        const surface = try self.createWindowSurface(&config, default_title, .{
            .host_id = if (source) |value| value.host_id else null,
            .tab_insert_index = if (source) |value| if (value.host) |host|
                windowNewTabInsertIndex(host, self.config.@"window-new-tab-position")
            else
                null else null,
            .clone_state_from = source,
            .launch = launch,
        });
        if (source) |value| value.invalidateRedoForUnsupportedTabStructuralAction();
        self.activateSurface(surface);
        return surface;
    }

    pub fn createNewSplit(
        self: *App,
        source: *Surface,
        direction: SplitTreeSurface.Split.Direction,
        working_directory: ?[]const u8,
        inherit_launch_config: bool,
    ) !*Surface {
        const tab_info = Host.findTabForSurface(source) orelse return error.AutomationTargetNotFound;
        var config = try apprt.surface.newConfig(self.core_app, &self.config, .split);
        defer config.deinit();
        config.@"working-directory" = self.config.@"working-directory";
        const origin: pane_launch.Origin = if (inherit_launch_config)
            .{ .inherit = launchSource(source) }
        else
            .{ .split = source.launch_profile_key };
        const launch = try pane_launch.prepare(&config, origin, self.launchContext(source.host));
        // An SSH launch keeps its hardened directory, an SSH default's too:
        // a local pane's directory means nothing to ssh.exe.
        if (shouldInheritSplitWorkingDirectory(source.launched_ssh or launch.ssh)) {
            _ = try applySplitWorkingDirectoryFromSource(self, &config, source, self.startup_cwd);
        }
        if (working_directory) |cwd| try applyAutomationWorkingDirectory(&config, cwd);
        const surface = try self.createWindowSurface(&config, default_title, .{
            .host_id = source.host_id,
            .tab_id = tab_info.tab.id,
            .clone_state_from = source,
            .split_direction = direction,
            .launch = launch,
        });
        tab_info.tab.clearRedoHistory();
        if (tab_info.host.pushStructuralUndo(.{
            .kind = .split_create,
            .timestamp_ms = sys.GetTickCount64(),
            .sequence_id = self.nextUndoSequence(),
            .payload = .{ .split_create = .{
                .source_surface = source,
                .created_surface = surface,
                .source_pane = source.shell_id,
                .created_pane = surface.shell_id,
                .direction = direction,
            } },
        })) |_| {} else |err| {
            log.warn("new_split undo snapshot failed err={}", .{err});
            _ = tab_info.host.clearStructuralRedo();
        }
        self.activateSurface(surface);
        return surface;
    }

    test "an automation tab or split repeats the source pane's launch as it started, before its directory" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var source: Surface = undefined;
        var created: [4]Surface = undefined;
        var surfaces: [1 + created.len]TestSession.SurfaceOptions = undefined;
        surfaces[0] = .{ .storage = &source, .host = &host, .register = true };
        for (&created, 1..) |*storage, index| surfaces[index] = .{
            .storage = storage,
            .host = &host,
            .window_visible = false,
            .host_active = false,
            .free_launch_profile_key_on_deinit = true,
        };
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &surfaces,
            .tabs = &.{.{ .host = &host, .surface = &source, .id = 1 }},
        });
        defer session.deinit();
        const alloc = app.core_app.alloc;

        // The definition after a reload changed it, which a split of the
        // source would start.
        const arena = app.config._arena.?.allocator();
        try app.config.@"profile-command".parseCLI(arena, "tool: new.exe");
        try app.config.@"profile-env".parseCLI(arena, "tool: MODE=new");
        app.config.@"tab-inherit-working-directory" = true;
        try app.config.finalize();
        // A live directory that is noctty's own start directory.
        var startup = "C:\\startup".*;
        app.startup_cwd = &startup;
        defer app.startup_cwd = null;

        const Seen = struct {
            program: []const u8,
            arg: []const u8,
            mode: []const u8,
            line: []const u8,
            integration: configpkg.Config.ShellIntegration,
            dir: []const u8,
        };
        const Hook = struct {
            var seen_arena: std.heap.ArenaAllocator = undefined;
            var seen: Seen = undefined;
            var storage: []Surface = undefined;
            var next: usize = 0;

            fn pwd(a: Allocator, _: *Surface) anyerror!?[]const u8 {
                return try a.dupe(u8, "C:\\startup");
            }

            fn createSurface(hook_app: *App, config: *const configpkg.Config, _: LPCWSTR, opts: SurfaceInitOptions) anyerror!*Surface {
                const a = seen_arena.allocator();
                const argv = switch (config.command orelse return error.TestUnexpectedResult) {
                    .direct => |words| words,
                    .shell => return error.TestUnexpectedResult,
                };
                seen = .{
                    .program = try a.dupe(u8, argv[0]),
                    .arg = if (argv.len > 1) try a.dupe(u8, argv[1]) else "",
                    .mode = if (config.env.map.get("MODE")) |value| try a.dupe(u8, value) else "",
                    .line = if (opts.launch.user) |launch| try a.dupe(u8, launch.command_line) else "",
                    .integration = config.@"shell-integration",
                    .dir = if (config.@"working-directory") |dir| switch (dir) {
                        .path => |path| try a.dupe(u8, path),
                        .home => "~",
                        .inherit => "",
                    } else "",
                };
                const surface = &storage[next];
                next += 1;
                const tab_host = hook_app.registry.findHostById(opts.host_id orelse return surface) orelse return surface;
                try hook_app.registry.addWindow(hook_app.core_app.alloc, surface);
                if (opts.tab_id != null) {
                    const found = Host.findTabForSurface(@constCast(opts.clone_state_from orelse return error.TestUnexpectedResult)) orelse return error.TestUnexpectedResult;
                    var inserted = try SplitTreeSurface.init(hook_app.core_app.alloc, surface);
                    defer inserted.deinit();
                    const tree = try found.tab.tree.split(hook_app.core_app.alloc, found.tab.focused, opts.split_direction, 0.5, &inserted);
                    found.tab.tree.deinit();
                    found.tab.tree = tree;
                } else {
                    try tab_host.tabs.insert(
                        hook_app.core_app.alloc,
                        opts.tab_insert_index orelse tab_host.tabs.items.len,
                        try Tab.init(hook_app.core_app.alloc, tab_host.nextTabId(), surface),
                    );
                }
                return surface;
            }
        };
        Hook.seen_arena = .init(std.testing.allocator);
        defer Hook.seen_arena.deinit();
        Hook.storage = &created;
        Hook.next = 0;
        app.test_create_window_surface = &Hook.createSurface;
        app.test_automation_pwd = &Hook.pwd;

        // What a user profile's pane started, line and variables with it:
        // `+new-tab --window-id` and `+new-split` run that, not `tool` as it
        // is now.
        const started = [_][:0]const u8{ "old.exe", "/x" };
        const started_env = [_]windows_shell.EnvEntry{.{ .key = "MODE", .value = "old" }};
        source.launch_command = .{ .direct = &started };
        source.launch_user = .{ .command_line = "old.exe /x", .env = &started_env };
        source.launch_profile_key = "user:tool";
        defer {
            source.launch_command = null;
            source.launch_user = null;
            source.launch_profile_key = null;
        }
        const Expect = struct {
            fn snapshot(surface: *const Surface) !void {
                try std.testing.expectEqualStrings("old.exe", Hook.seen.program);
                try std.testing.expectEqualStrings("/x", Hook.seen.arg);
                try std.testing.expectEqualStrings("old", Hook.seen.mode);
                try std.testing.expectEqualStrings("old.exe /x", Hook.seen.line);
                try std.testing.expectEqualStrings("user:tool", surface.launch_profile_key orelse "");
                try std.testing.expect(!surface.launched_ssh);
            }
        };
        _ = try app.createNewTab(&source, null, true, true);
        try Expect.snapshot(&created[0]);
        // The window's tab takes the pane's live directory.
        try std.testing.expectEqualStrings("C:\\startup", Hook.seen.dir);
        _ = try app.createNewSplit(&source, .right, null, true);
        try Expect.snapshot(&created[1]);

        // An SSH pane's: hardened again, and still SSH.
        const ssh = [_][:0]const u8{ "C:\\Windows\\System32\\OpenSSH\\ssh.exe", "prod" };
        source.launch_command = .{ .direct = &ssh };
        source.launch_user = null;
        source.launch_profile_key = "ssh:prod";
        source.launched_ssh = true;
        _ = try app.createNewTab(&source, null, true, true);
        try std.testing.expectEqualStrings("prod", Hook.seen.arg);
        try std.testing.expectEqual(configpkg.Config.ShellIntegration.none, Hook.seen.integration);
        try std.testing.expectEqualStrings("ssh:prod", created[2].launch_profile_key orelse "");
        try std.testing.expect(created[2].launched_ssh);

        // A WSL pane whose live directory is noctty's start directory: the
        // explicit target's directory step reads the inherited command, so
        // the tab falls back to the pane's last reported folder.
        const wsl = [_][:0]const u8{ "wsl.exe", "-d", "Ubuntu" };
        source.launch_command = .{ .direct = &wsl };
        source.launch_profile_key = "wsl:Ubuntu";
        source.launched_ssh = false;
        try appendOwnedString(alloc, &source.pwd, "C:\\cached");
        defer appendOwnedString(alloc, &source.pwd, null) catch unreachable;
        _ = try app.createNewTab(&source, null, true, true);
        try std.testing.expectEqualStrings("wsl.exe", Hook.seen.program);
        try std.testing.expectEqualStrings("C:\\cached", Hook.seen.dir);
        try std.testing.expectEqual(created.len, Hook.next);
    }

    /// The profile `new_window_elevated` runs for `key`: `default-profile`'s
    /// own when the key is its, else the one in the source window's list,
    /// else in a list built for the purpose, stored in `temporary` for the
    /// caller to free.
    pub fn elevatedWindowProfile(
        self: *App,
        source_host: ?*Host,
        key: []const u8,
        temporary: *?[]windows_shell.Profile,
    ) !?*const windows_shell.Profile {
        if (pane_launch.defaultProfileForKey(&self.config, key)) |profile| return profile;
        if (source_host) |host| return try host.profileForKey(key);
        const profiles = try listProfilesForConfig(self.core_app.alloc, &self.config, windows_shell.listProfiles);
        temporary.* = profiles;
        const index = profileIndexByKey(profiles, key) orelse return null;
        return &profiles[index];
    }

    pub fn createProfileSurface(
        self: *App,
        target: apprt.Target,
        profile: *const windows_shell.Profile,
        open_target: ProfileOpenTarget,
    ) !*Surface {
        const source = self.registry.findSurfaceForTarget(target);
        var config = try apprt.surface.newConfig(
            self.core_app,
            &self.config,
            switch (open_target) {
                .tab => .tab,
                .window => .window,
                .split => .split,
            },
        );
        defer config.deinit();
        const launch = try pane_launch.prepare(&config, .{ .chosen = profile }, self.launchContext(null));

        const tab_id = switch (open_target) {
            .split => blk: {
                const source_surface = source orelse return error.NoActiveSurface;
                const tab_info = Host.findTabForSurface(source_surface) orelse return error.NoActiveSurface;
                break :blk tab_info.tab.id;
            },
            else => null,
        };

        const surface_title = launch.title orelse profile.label;
        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, surface_title);
        defer self.core_app.alloc.free(title_w);
        return try self.createWindowSurface(&config, title_w.ptr, .{
            .host_id = if (open_target == .window) null else if (source) |v| v.host_id else null,
            .tab_insert_index = if (open_target == .tab and source != null and source.?.host != null)
                windowNewTabInsertIndex(source.?.host.?, self.config.@"window-new-tab-position")
            else
                null,
            .tab_id = tab_id,
            .clone_state_from = if (open_target == .window) self.registry.newWindowSource(target) else source,
            .launch = launch,
        });
    }

    pub fn createWindow(self: *App, title: LPCWSTR) !void {
        // The first window runs the app config itself, and a clone only when
        // a default profile's variables, line and directory go on it.
        if (!pane_launch.defaultApplies(&self.config, self.core_app.first)) {
            _ = try self.createWindowSurface(&self.config, title, .{});
            return;
        }
        var config = try apprt.surface.newConfig(self.core_app, &self.config, .window);
        defer config.deinit();
        // Explorer's "Open in noctty" and a jump-list folder start a first
        // window with `--working-directory=` when no instance runs.
        const launch = try pane_launch.prepare(&config, .{ .fresh = .{
            .named_directory = self.explicit_startup_working_directory,
        } }, self.launchContext(null));
        _ = try self.createWindowSurface(&config, title, .{ .launch = launch });
    }

    fn createAdoptedWindow(
        self: *App,
        pending: *win32_terminal_handoff.PendingSession,
    ) !void {
        // `config.title` is the static-title setting: the core would drop
        // every later title the console sets (cmd's `title`, a prompt, a
        // TUI) for as long as the surface lives. The client's title is only
        // where this one starts.
        var config = try apprt.surface.newConfig(self.core_app, &self.config, .window);
        defer config.deinit();
        const title_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, pending.title);
        defer self.core_app.alloc.free(title_w);
        _ = try self.createWindowSurface(&config, title_w.ptr, .{
            .adopted_session = pending,
            .show = adoptedInitialShow(pending.startup_flags, pending.show_window),
        });
        win32_terminal_handoff.appendHandoffMilestone(self.core_app.alloc, "adopted_window_created");
    }

    test "an adopted window starts with the client's title and show state, and pins neither" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var created: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &.{.{ .storage = &created, .host = &host, .register = true }},
        });
        defer session.deinit();
        defer appendOwnedString(core_app.alloc, &created.title, null) catch {};

        const Hook = struct {
            var created_ref: *Surface = undefined;
            var title_pinned: bool = true;
            var show: InitialShow = .activate;

            fn createSurface(
                _: *App,
                config: *const configpkg.Config,
                _: LPCWSTR,
                opts: SurfaceInitOptions,
            ) anyerror!*Surface {
                title_pinned = config.title != null;
                show = opts.show;
                return created_ref;
            }
        };
        Hook.created_ref = &created;
        app.test_create_window_surface = &Hook.createSurface;

        var pending: win32_terminal_handoff.PendingSession = .{
            .alloc = core_app.alloc,
            .adopted = null,
            .title = try core_app.alloc.dupe(u8, "C:\\Windows\\system32\\cmd.exe"),
            .startup_flags = win32_terminal_handoff.STARTF_USESHOWWINDOW,
            .show_window = c.SW_SHOWMINNOACTIVE,
        };
        defer pending.deinit();

        try app.createAdoptedWindow(&pending);

        // A set `config.title` is the static-title setting, which makes the
        // core drop every title the console sets afterwards.
        try std.testing.expect(!Hook.title_pinned);
        try std.testing.expectEqual(InitialShow.minimized, Hook.show);
        // The creation hook returns an inert surface; title installation
        // belongs to Surface.init, before its first show (tested below).
        try std.testing.expect(created.title == null);

        // A title the user configured is static and wins over the client's.
        try appendOwnedString(core_app.alloc, &created.title, null);
        app.config.title = "My Term";
        defer app.config.title = null;
        try app.createAdoptedWindow(&pending);
        try std.testing.expect(Hook.title_pinned);
        try std.testing.expect(created.title == null);
    }

    test "an adopted window has its startup caption at its first show" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try Host.runOnPrivateDesktop(adoptedFirstCaptionTestBody);
    }

    fn adoptedFirstCaptionTestBody() !void {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        const instance = app.hinstance;
        defer {
            _ = sys.UnregisterClassW(class_name, instance);
            _ = sys.UnregisterClassW(host_class_name, instance);
            _ = sys.UnregisterClassW(palette_list_class_name, instance);
            _ = sys.UnregisterClassW(scrollbar_class_name, instance);
        }
        try app.ensureWindowClass();
        const Observe = struct {
            var previous: ?*const anyopaque = null;
            var caption: [256]u16 = @splat(0);
            var shows: usize = 0;

            fn proc(hwnd: HWND, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(.winapi) LRESULT {
                if (msg == c.WM_SHOWWINDOW and wp != 0) {
                    _ = sys.GetWindowTextW(hwnd, &caption, caption.len);
                    shows += 1;
                }
                return sys.CallWindowProcW(previous, hwnd, msg, wp, lp);
            }

            fn stage(surface: *Surface, at: Surface.InitStage) anyerror!void {
                if (at == .gl_context) {
                    // The test executable has no layered-child manifest.
                    surface.host.?.tab_container_hwnd = try createTestChromeChild(surface.host.?.hwnd.?, prompt_label_class);
                    return;
                }
                if (at != .core_surface) return;
                if (surface.app.config.title) |title| try surface.setTitle(title);
                previous = @ptrFromInt(@as(usize, @bitCast(sys.SetWindowLongPtrW(
                    surface.host.?.hwnd.?,
                    c.GWLP_WNDPROC,
                    @bitCast(@intFromPtr(&proc)),
                ))));
            }
        };
        app.test_surface_init_stage = &Observe.stage;
        var pending: win32_terminal_handoff.PendingSession = .{
            .alloc = core_app.alloc,
            .adopted = null,
            .title = try core_app.alloc.dupe(u8, "SMALL-06 client caption"),
            .startup_flags = win32_terminal_handoff.STARTF_USESHOWWINDOW,
            .show_window = c.SW_SHOWNOACTIVATE,
        };
        defer pending.deinit();
        for ([_]?[:0]const u8{ null, "Configured caption" }) |configured| {
            // Real pipes and owned handles, but no process, COM or registry.
            var signal_read: windows.HANDLE = undefined;
            var signal_write: windows.HANDLE = undefined;
            try std.testing.expect(internal_os.windows.exp.kernel32.CreatePipe(&signal_read, &signal_write, null, 0) != 0);
            defer _ = windows.CloseHandle(signal_read);
            const Dup = struct {
                fn current() !windows.HANDLE {
                    var handle: windows.HANDLE = undefined;
                    const current_process = windows.GetCurrentProcess();
                    if (windows.kernel32.DuplicateHandle(current_process, current_process, current_process, &handle, 0, windows.FALSE, windows.DUPLICATE_SAME_ACCESS) == 0) return lastError();
                    return handle;
                }
            };
            pending.adopted = .{
                .pty = try ptypkg.Pty.openAdopted(.{}, signal_write, try Dup.current(), try Dup.current()),
                .client_process = try Dup.current(),
            };
            app.config.title = configured;
            Observe.caption = @splat(0);
            Observe.shows = 0;
            try app.createAdoptedWindow(&pending);
            const surface = app.registry.windows.items[app.registry.windows.items.len - 1];
            const host_hwnd = surface.host.?.hwnd.?;
            defer {
                core_app.deleteSurface(surface);
                _ = sys.DestroyWindow(host_hwnd);
            }
            const caption = try std.unicode.utf16LeToUtf8Alloc(core_app.alloc, std.mem.sliceTo(&Observe.caption, 0));
            defer core_app.alloc.free(caption);
            try std.testing.expectEqual(@as(usize, 1), Observe.shows);
            try std.testing.expectEqualStrings(configured orelse pending.title, caption);
            try std.testing.expectEqualStrings(configured orelse pending.title, surface.title.?);
            // A later console title still replaces the startup title.
            if (configured == null) {
                try surface.setTitle("Later console title");
                try std.testing.expectEqualStrings("Later console title", surface.title.?);
            }
        }
        app.config.title = null;
    }

    test "a handed-off console's show state maps to the host's first show" {
        const use = win32_terminal_handoff.STARTF_USESHOWWINDOW;
        // Ignored without STARTF_USESHOWWINDOW, whatever the client left in
        // `wShowWindow`.
        for ([_]u16{ c.SW_HIDE, c.SW_SHOWMINNOACTIVE, c.SW_MAXIMIZE, c.SW_SHOWNOACTIVATE }) |sw| {
            try std.testing.expectEqual(InitialShow.activate, adoptedInitialShow(0, sw));
            try std.testing.expectEqual(InitialShow.activate, adoptedInitialShow(0x100, sw));
        }
        const cases = [_]struct { u16, InitialShow }{
            .{ c.SW_SHOWNOACTIVATE, .no_activate },
            .{ c.SW_SHOWNA, .no_activate },
            .{ c.SW_SHOWMINIMIZED, .minimized },
            .{ c.SW_MINIMIZE, .minimized },
            .{ c.SW_SHOWMINNOACTIVE, .minimized },
            .{ c.SW_FORCEMINIMIZE, .minimized },
            .{ c.SW_HIDE, .minimized },
            .{ c.SW_MAXIMIZE, .maximized },
            // SW_SHOWNORMAL, SW_SHOW, SW_RESTORE, SW_SHOWDEFAULT, and a value
            // no one defined.
            .{ 1, .activate },
            .{ c.SW_SHOW, .activate },
            .{ c.SW_RESTORE, .activate },
            .{ 10, .activate },
            .{ 99, .activate },
        };
        for (cases) |case| {
            try std.testing.expectEqual(case[1], adoptedInitialShow(use, case[0]));
            // Other STARTF_ bits do not matter.
            try std.testing.expectEqual(case[1], adoptedInitialShow(use | 0x100, case[0]));
        }
        // Only a minimized host or a passive one stays out of the foreground.
        try std.testing.expect(InitialShow.activate.takesFocus());
        try std.testing.expect(InitialShow.maximized.takesFocus());
        try std.testing.expect(!InitialShow.no_activate.takesFocus());
        try std.testing.expect(!InitialShow.minimized.takesFocus());
        try std.testing.expectEqual(@as(?i32, null), InitialShow.activate.showCommand());
        try std.testing.expectEqual(@as(?i32, c.SW_SHOWMINNOACTIVE), InitialShow.minimized.showCommand());
    }

    pub fn refreshSystemWheelSettings(self: *App) void {
        self.wheel_settings = .{
            .lines = readSystemWheelSetting(c.SPI_GETWHEELSCROLLLINES, self.wheel_settings.lines),
            .chars = readSystemWheelSetting(c.SPI_GETWHEELSCROLLCHARS, self.wheel_settings.chars),
        };
    }

    pub fn refreshSystemScrollbarPreference(self: *App) void {
        self.system_dynamic_scrollbars = readDynamicScrollbars(self.system_dynamic_scrollbars);
        for (self.registry.windows.items) |surface| {
            surface.refreshScrollbarWindow() catch |err| {
                log.warn("win32 scrollbar refresh failed err={}", .{err});
            };
        }
    }

    pub fn syncSystemColorScheme(self: *App) !void {
        const scheme: apprt.ColorScheme = if (isSystemDarkMode()) .dark else .light;

        // Surface state must change before the app-wide reload because
        // App.updateConfig applies each surface's own conditional state and
        // Termio reports mode 2031 only after installing that derived config.
        for (self.registry.windows.items) |surface| {
            surface.core().colorSchemeCallback(scheme);
        }
        try self.core_app.colorSchemeEvent(self, scheme);
    }

    pub fn reconfigureSystemTheme(self: *App) void {
        const snapshot = SystemThemeSnapshot.capture(self.shownConfig());
        const changed = self.system_theme_refresh.accept(snapshot) or !std.meta.eql(snapshot.theme, self.resolved_theme);
        if (!changed) {
            const missing_resources = for (self.registry.hosts.items) |host| {
                if (host.hwnd != null and (host.chrome_brush == null or
                    host.overlay_brush == null or host.edit_brush == null or
                    host.chrome_font == null or host.preview_font == null or
                    (!host.titlebar_icons_geometric and
                        (host.titlebar_caption_icon_font == null or host.titlebar_action_icon_font == null)) or
                    // The search font stays lazy. Only a failed attempt, not
                    // its intentionally unused state, needs another chance.
                    (host.search_icon_font_resolved and host.search_icon_font == null))) break true;
            } else false;
            if (!missing_resources) return;
        }
        self.reconfigureTheme();
    }

    pub fn reconfigureTheme(self: *App) void {
        const previous_integrated_titlebar = self.use_integrated_titlebar;
        self.use_integrated_titlebar = shouldUseIntegratedTitlebar(
            self.os_build,
            self.config.@"window-show-tab-bar",
        );
        const frame_mode_changed = previous_integrated_titlebar != self.use_integrated_titlebar;
        const previous_tab_bar_visible = self.tab_bar_visible;
        self.tab_bar_visible = tabBarVisibleForConfig(self.config.@"window-show-tab-bar");
        // Showing or hiding the strip moves every chrome child in it, and on
        // Win10 the frame mode never flips, so the layout below cannot hang
        // off `frame_mode_changed` alone.
        const chrome_layout_changed = frame_mode_changed or
            previous_tab_bar_visible != self.tab_bar_visible;
        // The theme as Settings previews it.
        const shown = self.shownConfig();
        self.resolved_theme = resolveTheme(shown);
        for (self.registry.hosts.items) |host| {
            host.rebuildThemeBrushes();
            host.recreateChromeFont();
            // High Contrast turns the split dim off and back on.
            host.syncSplitDim();
            if (frame_mode_changed) {
                // A stock<->integrated frame flip can cancel the old
                // NC hover tracking without delivering
                // WM_NCMOUSELEAVE. Clear both fields eagerly so
                // re-enabling integrated chrome doesn't resurrect a
                // stale hovered button.
                host.handleNcMouseLeave();
            }
            if (host.hwnd) |hwnd| {
                applyDwmThemeWithBuild(hwnd, &self.resolved_theme, shown, self.os_build);
                if (frame_mode_changed) {
                    _ = sys.SetWindowPos(
                        hwnd,
                        null,
                        0,
                        0,
                        0,
                        0,
                        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
                    );
                    host.scheduleCaptionUiaSync();
                }
                if (chrome_layout_changed) {
                    runUiActionOrLog("theme update layout failed", host.layout());
                }
                // Theme resource replacement always invalidates the full host
                // chrome plus native child controls. A System->Dark swap does
                // not necessarily change frame mode, but every retained pixel
                // still belongs to the previous palette.
                host.invalidateChrome();
                _ = sys.RedrawWindow(
                    hwnd,
                    null,
                    null,
                    c.RDW_INVALIDATE | c.RDW_ERASE | c.RDW_FRAME | c.RDW_ALLCHILDREN,
                );
            }
        }
        for (self.registry.windows.items) |surface| surface.invalidateScrollbarWindow();
        self.theme_rebuilds +%= 1;
        self.settings_window.themeChanged();
    }

    /// The config the chrome is drawn from: `settings_preview` while Settings
    /// previews a draft, else `config`. The windows' opacity has its own
    /// (`shownBackgroundOpacity`); terminal configs, new ones too, come from
    /// `config`.
    pub fn shownConfig(self: *const App) *const configpkg.Config {
        return if (self.settings_preview) |*preview| preview else &self.config;
    }

    /// The opacity a window applies along with `config`
    /// (`Surface.applyRuntimeConfig`): Settings' preview of it while one is
    /// shown, whatever `config` is. A reload reaches each terminal's own
    /// config before the app's (`CoreApp.updateConfig`), so a window that
    /// took the saved value there would show it until the app's
    /// `config_change` put the preview back, a theme rebuild later.
    pub fn shownBackgroundOpacity(self: *const App, config: *const configpkg.Config) f64 {
        if (self.settings_preview) |*preview| {
            if (preview.@"background-opacity" != self.config.@"background-opacity") return preview.@"background-opacity";
        }
        return config.@"background-opacity";
    }

    /// Show `value` as Settings' preview of its field, leaving `config` alone.
    /// Returns whether what the windows show for the field changed.
    pub fn previewSetting(self: *App, value: win32_settings.SettingValue) bool {
        const field = std.meta.activeTag(value);
        if (std.meta.eql(win32_settings.settingValue(self.shownConfig(), field), value)) return false;
        if (self.settings_preview == null) {
            self.settings_preview = self.config.clone(self.core_app.alloc) catch |err| {
                log.warn("settings live preview copy failed field={} err={}", .{ field, err });
                return false;
            };
        }
        const preview = &self.settings_preview.?;
        win32_settings.setSettingValue(preview, value);
        if (settingsPreviewShowsNothingNew(preview, &self.config)) self.dropSettingsPreview();
        return true;
    }

    /// Redraw what a preview of a field with `effect` changes.
    pub fn refreshSettingsPreview(self: *App, effect: win32_settings.PreviewEffect) void {
        switch (effect) {
            .none => {},
            .theme => self.reconfigureTheme(),
            .opacity => for (self.registry.windows.items) |surface| {
                surface.applyRuntimeConfig(&self.config) catch |err| {
                    log.warn("settings live preview apply failed err={}", .{err});
                };
            },
        }
    }

    pub fn dropSettingsPreview(self: *App) void {
        if (self.settings_preview) |*preview| preview.deinit();
        self.settings_preview = null;
    }

    /// `config` was replaced. The preview sat on the config before it, so it
    /// is made again on the new one from the drafts Settings previews
    /// (`SettingsWindow.livePreviews`). The caller redraws. Settings says what
    /// is previewed, not the overlay: `previewSetting` drops a field that
    /// equals `config`, and a config that says the draft's value for a while
    /// (a palette theme that sets `window-theme`) would otherwise end a
    /// preview that cancelling the palette has to bring back.
    ///
    /// A reload's `config_change` does this before it redraws, so the chrome
    /// is not rebuilt from the bare config first; Settings then previews its
    /// drafts again (`externalConfigChanged`), which changes nothing. The
    /// palette's theme preview replaces `config` without telling Settings, so
    /// there this is all that keeps the drafts shown.
    pub fn restoreSettingsPreview(self: *App) void {
        self.dropSettingsPreview();
        var drafts: [win32_settings.setting_field_count]win32_settings.SettingValue = undefined;
        for (self.settings_window.livePreviews(&drafts)) |value| _ = self.previewSetting(value);
    }

    /// Settings previews nothing any more: a save wrote every draft, or the
    /// window closed. Normally nothing is left to end: a save's reload shows
    /// no preview (`livePreviews` is empty while a save is in flight) and a
    /// close rolls its previews back. A save without a reload (safe mode)
    /// leaves the overlay, and the transaction ends its previews at a save
    /// without a rollback effect, so the windows go to the saved config here.
    pub fn endSettingsPreview(self: *App) void {
        var previous = self.settings_preview orelse return;
        self.settings_preview = null;
        defer previous.deinit();
        var changed = std.EnumSet(win32_settings.PreviewEffect).initEmpty();
        for (std.enums.values(win32_settings.SettingField)) |field| {
            const effect = win32_settings.previewEffect(field);
            if (effect == .none) continue;
            if (!std.meta.eql(win32_settings.settingValue(&previous, field), win32_settings.settingValue(&self.config, field))) changed.insert(effect);
        }
        var effects = changed.iterator();
        while (effects.next()) |effect| self.refreshSettingsPreview(effect);
    }

    /// Where the picker starts when nothing was chosen or hinted: the profile
    /// that runs the shell the automatic default command picked. A `command`
    /// the user set leaves the choice to the caller.
    pub fn defaultShellProfileIndex(self: *const App, profiles: []const windows_shell.Profile) ?usize {
        // A `default-profile` the picker does not show (hidden) leaves the
        // choice to the caller rather than to its command's shell.
        if (pane_launch.defaultProfile(&self.config) != null) return null;
        return windows_shell.profileIndexForDefaultCommand(profiles, pane_launch.nocttyCommand(&self.config) orelse return null);
    }

    pub fn applyLauncherQuickSlotPreferences(self: *App, profiles: []windows_shell.Profile) void {
        applyQuickSlotPreferenceOrder(profiles, .{
            self.launcher_quick_slot_keys[0],
            self.launcher_quick_slot_keys[1],
            self.launcher_quick_slot_keys[2],
        });
    }

    pub fn launcherQuickSlotOrdinal(self: *const App, key: []const u8) ?usize {
        return findLauncherQuickSlotOrdinal(self.launcher_quick_slot_keys, key);
    }

    pub fn setLauncherQuickSlotPreference(self: *App, slot_ordinal: usize, key: []const u8) !void {
        if (slot_ordinal >= self.launcher_quick_slot_keys.len) return;
        if (!launcherQuickSlotAssignmentNeedsChange(self.launcher_quick_slot_keys, slot_ordinal, key)) return;
        var duplicate_slot: ?usize = null;
        for (self.launcher_quick_slot_keys, 0..) |existing, index| {
            if (existing) |value| {
                if (windows_shell.storedProfileKeyEquals(value, key)) {
                    duplicate_slot = index;
                    break;
                }
            }
        }

        if (duplicate_slot) |index| {
            if (index != slot_ordinal) {
                if (self.launcher_quick_slot_keys[slot_ordinal]) |current| {
                    try appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[index], current);
                } else {
                    runUiActionOrLog(
                        "quick slot deduplication failed",
                        appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[index], null),
                    );
                }
            }
        }

        try appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[slot_ordinal], key);

        for (self.registry.hosts.items) |host| {
            runUiActionOrLog("quick slot profile refresh failed", host.reapplyLauncherProfilePreferences());
            host.refreshProfileChrome();
        }
    }

    test "setLauncherQuickSlotPreference keeps the other slot's key when the copy fails" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        core_app.alloc = failing.allocator();
        defer core_app.alloc = std.testing.allocator;
        app.launcher_quick_slot_keys[0] = try std.testing.allocator.dupeZ(u8, "pwsh");
        app.launcher_quick_slot_keys[1] = try std.testing.allocator.dupeZ(u8, "cmd");
        defer for (app.launcher_quick_slot_keys) |value| {
            if (value) |key| std.testing.allocator.free(key);
        };
        // Slot 0 takes "cmd", so slot 1 is to receive a copy of "pwsh".
        failing.fail_index = failing.alloc_index;
        try std.testing.expectError(error.OutOfMemory, app.setLauncherQuickSlotPreference(0, "cmd"));
        try std.testing.expectEqualStrings("pwsh", app.launcher_quick_slot_keys[0].?);
        try std.testing.expectEqualStrings("cmd", app.launcher_quick_slot_keys[1].?);
    }

    pub fn clearLauncherQuickSlotPreferences(self: *App) void {
        if (launcherQuickSlotPinsAlreadyClear(self.launcher_quick_slot_keys)) return;
        for (&self.launcher_quick_slot_keys) |*value| {
            runUiActionOrLog("quick slot clear failed", appendOwnedString(self.core_app.alloc, value, null));
        }

        for (self.registry.hosts.items) |host| {
            // The pins reordered the list in place; a fresh one from the
            // discovery worker restores discovery order.
            if (host.profiles != null) host.requestProfiles();
            host.refreshProfileChrome();
        }
    }

    fn allocateHostId(self: *App) u32 {
        const id = self.next_host_id;
        self.next_host_id +%= 1;
        if (self.next_host_id == 0) self.next_host_id = 1;
        return id;
    }

    pub fn prepareShellSurfaceCreate(
        self: *App,
        existing_host: ?*Host,
        opts: SurfaceInitOptions,
    ) !?win32_shell.runtime.Prepared {
        if (!self.shell_runtime_initialized) return null;
        const host = existing_host orelse return try self.shell_runtime.prepare(.create_window);
        if (opts.tab_id == null) {
            const window_id = host.shell_id orelse return error.ShellStateOutOfSync;
            return try self.shell_runtime.prepare(.{ .create_tab = .{
                .window = window_id,
                .index = requestedTabInsertIndex(opts.tab_insert_index, host.tabs.items.len),
            } });
        }

        const source = opts.clone_state_from orelse return error.ShellStateOutOfSync;
        const pane_id = source.shell_id orelse return error.ShellStateOutOfSync;
        const direction: win32_shell.model.Direction = switch (opts.split_direction) {
            .left => .left,
            .right => .right,
            .up => .up,
            .down => .down,
        };
        return try self.shell_runtime.prepare(.{ .split_pane = .{
            .pane = pane_id,
            .direction = direction,
        } });
    }

    /// Checks the native windows against the shell model after a
    /// structural change, in every build: a divergence is where the wrong
    /// pane ends up focused. Debug builds log an error, which fails a test;
    /// release builds warn, rate-limited. Never per frame: only structural
    /// commits call it.
    pub fn auditShellNativeMapping(self: *App, context: []const u8) void {
        if (!self.shell_runtime_initialized) return;
        self.validateShellNativeMapping() catch |err| {
            if (comptime builtin.mode == .Debug) {
                log.err("shell/native invariant failed context={s} err={}", .{ context, err });
                return;
            }
            const suppressed = self.shell_audit_warning.take(sys.GetTickCount64(), shell_audit_warn_interval_ms) orelse return;
            log.warn("shell/native invariant failed context={s} err={} suppressed={d}", .{ context, err, suppressed });
        };
    }

    pub fn validateShellNativeMapping(self: *App) !void {
        const state = &self.shell_runtime.state;
        var mapped_hosts: usize = 0;
        for (self.registry.hosts.items) |host| {
            const window_id = host.shell_id orelse continue;
            mapped_hosts += 1;
            const window = state.windowConst(window_id) orelse return error.MissingShellWindow;
            if (window.tabs.items.len != host.tabs.items.len) return error.TabCountMismatch;
            if (host.tabs.items.len == 0) {
                if (window.active_tab != null) return error.ActiveTabMismatch;
                continue;
            }
            if (host.active_tab >= host.tabs.items.len) return error.ActiveTabMismatch;
            const native_active = host.tabs.items[host.active_tab].shell_id orelse
                return error.MissingShellTab;
            if (window.active_tab == null or !window.active_tab.?.eql(native_active))
                return error.ActiveTabMismatch;

            for (host.tabs.items, 0..) |*native_tab, index| {
                const tab_id = native_tab.shell_id orelse return error.MissingShellTab;
                if (!window.tabs.items[index].eql(tab_id)) return error.TabOrderMismatch;
                const tab = state.tabConst(tab_id) orelse return error.MissingShellTab;
                if (native_tab.tree.nodes.len == 0 or
                    !shellTopologyMatches(state, tab.root, &native_tab.tree, .root))
                    return error.TopologyMismatch;
                var native_panes: usize = 0;
                var focused_found = false;
                var it = native_tab.tree.iterator();
                while (it.next()) |entry| {
                    native_panes += 1;
                    const pane_id = entry.view.shell_id orelse return error.MissingShellPane;
                    const pane = state.paneConst(pane_id) orelse return error.MissingShellPane;
                    if (!pane.tab.eql(tab_id)) return error.PaneOwnerMismatch;
                    if (entry.handle == native_tab.focused and pane_id.eql(tab.focused_pane))
                        focused_found = true;
                }
                var model_panes: usize = 0;
                for (state.panes.items) |pane| if (pane.tab.eql(tab_id)) {
                    model_panes += 1;
                };
                if (native_panes != model_panes) return error.PaneCountMismatch;
                if (!focused_found) return error.FocusedPaneMismatch;
            }
        }
        if (mapped_hosts != state.windows.items.len) return error.WindowCountMismatch;
    }

    /// The native split tree has the model's shape: the same panes in the
    /// same places, split along the same axes. Ratios and zoom are native
    /// only; a resize does not go through the model.
    fn shellTopologyMatches(
        state: *const win32_shell.model.ShellState,
        node_id: win32_shell.model.NodeId,
        tree: *const SplitTreeSurface,
        handle: SplitTreeSurface.Node.Handle,
    ) bool {
        if (handle.idx() >= tree.nodes.len) return false;
        const node = state.nodeConst(node_id) orelse return false;
        return switch (tree.nodes[handle.idx()]) {
            .leaf => |view| switch (node.value) {
                .pane => |pane| if (view.shell_id) |id| id.eql(pane) else false,
                .split => false,
            },
            .split => |split| switch (node.value) {
                .pane => false,
                .split => |model_split| (model_split.axis == .horizontal) == (split.layout == .horizontal) and
                    shellTopologyMatches(state, model_split.first, tree, split.left) and
                    shellTopologyMatches(state, model_split.second, tree, split.right),
            },
        };
    }

    /// A hidden top-level window for the window `Surface.init` creates with
    /// `config` and `opts`: placed and decorated as that window's own config
    /// says (a forwarded launch's keys included, see `WindowKeeps`), or as
    /// the window it is opened from.
    pub fn createHost(self: *App, title: LPCWSTR, config: *const configpkg.Config, opts: SurfaceInitOptions) !*Host {
        const clone_state_from = opts.clone_state_from;
        const quick_terminal = opts.quick_terminal;
        const keeps = WindowKeeps.forNewSurface(config, opts);
        try self.ensureHostWindowClass();
        try self.ensurePaletteListClass();
        try self.ensureScrollbarClass();

        const host = try self.core_app.alloc.create(Host);
        var host_registered = false;
        errdefer if (!host_registered) self.core_app.alloc.destroy(host);
        host.* = .{
            .app = self,
            .id = self.allocateHostId(),
            .quick_terminal = quick_terminal,
        };
        host.palette_catalog = try PaletteCatalog.init(
            &host.palette_catalog_items,
            &host.palette_catalog_payloads,
        );
        host.tween_sched.init(self.core_app.alloc);
        if (self.launcher_profile_key) |key| {
            try appendOwnedString(self.core_app.alloc, &host.selected_profile_key, key);
        }

        const position = configuredHostWindowPosition(config);
        const startup_decorations_visible = Surface.initialDecorationsVisible(config, opts);
        host.cached_decorations_visible = startup_decorations_visible;
        // A window with a size of its own starts framed, so core init sizes
        // the window it leaves fullscreen to.
        const startup_fullscreen = if (clone_state_from) |source| source.fullscreen and !keeps.size else false;
        const keeps_frame = startup_decorations_visible or undecoratedKeepsFrame(self.os_build, quick_terminal);
        const startup_style = startupHostWindowStyle(keeps_frame, startup_fullscreen);

        const hwnd = sys.CreateWindowExW(
            0,
            host_class_name,
            title,
            startup_style,
            if (position) |v| v.x else c.CW_USEDEFAULT,
            if (position) |v| v.y else c.CW_USEDEFAULT,
            1280,
            800,
            null,
            null,
            self.hinstance,
            host,
        ) orelse return lastError();
        host.hwnd = hwnd;
        setWindowIcon(hwnd, self.hinstance);
        applyDwmThemeWithBuild(hwnd, &self.resolved_theme, self.shownConfig(), self.os_build);
        if (!startup_decorations_visible and keeps_frame) {
            win32_theme.WindowThemeAdapter.setHostBorderVisible(hwnd, false);
        }
        host.current_dpi = sys.GetDpiForWindow(hwnd);
        if (host.current_dpi == 0) host.current_dpi = 96;
        host.chrome_font = host.createChromeFont();
        host.preview_font = host.createPreviewFont();
        host.recreateTitlebarIconFonts();
        errdefer if (!host_registered) {
            _ = sys.DestroyWindow(hwnd);
        };

        self.attachShellCompositorWindow(hwnd);
        // On Windows 10, an undecorated host comes back from
        // `CreateWindowEx` with a caption it did not ask for. Take it off
        // while the host is still hidden and has no tabs. This goes after the
        // compositor attach because the frame change resizes the client area,
        // and the host's WM_SIZE resizes its compositor target (when a
        // compositor is running), which must exist by then.
        restoreRequestedHostWindowStyle(hwnd, startup_style);

        try self.registry.addHost(self.core_app.alloc, host);
        host_registered = true;
        errdefer {
            // Keep the registered Host and its GWLP_USERDATA alive through
            // WM_DESTROY so the normal compositor-detach path can find it.
            if (sys.DestroyWindow(hwnd) == 0) {
                // If teardown itself fails, WM_DESTROY did not provide the
                // normal detach. Do it explicitly before host deinit.
                self.detachShellCompositorWindow(hwnd);
            }
            self.removeHost(host);
        }
        if (self.jump_list) |*jump_list| jump_list.scheduleIfStartupPending();
        if (clone_state_from) |source| {
            if (source.host) |existing| try self.inheritHostWindowState(host, existing, keeps.position);
        }

        host.power_notifications = win32_power.Notifications.init(hwnd);

        self.presentConfigProblemsOnHost(host);

        // The host stays hidden here. `Surface.init` shows it only after GL
        // and core initialization succeed, so a below-floor GPU reaches the
        // startup dialog without first flashing a blank window.
        return host;
    }

    fn attachShellCompositorWindow(self: *App, hwnd: HWND) void {
        if (!self.shell_compositor_initialized) return;
        self.shell_compositor.attachWindow(@intFromPtr(hwnd)) catch |err| switch (err) {
            // The normal state: no driver was started, so no host has a target.
            error.FallbackOnly => return,
            error.DeviceLost => {
                self.shell_compositor.recover() catch |recover_err| {
                    log.warn("shell compositor recovery after attach failed err={}", .{recover_err});
                    return;
                };
                self.shell_compositor.attachWindow(@intFromPtr(hwnd)) catch |retry_err| {
                    log.warn("shell compositor attach retry failed err={}", .{retry_err});
                    return;
                };
            },
            else => {
                log.warn("shell compositor attach unavailable err={}", .{err});
                return;
            },
        };
        self.commitShellCompositor();
    }

    pub fn detachShellCompositorWindow(self: *App, hwnd: HWND) void {
        if (!self.shell_compositor_initialized) return;
        self.shell_compositor.detachWindow(@intFromPtr(hwnd)) catch |err| switch (err) {
            error.DeviceLost => {
                self.shell_compositor.recover() catch |recover_err| {
                    log.warn("shell compositor recovery before detach failed err={}", .{recover_err});
                    return;
                };
                self.shell_compositor.detachWindow(@intFromPtr(hwnd)) catch |retry_err| {
                    log.warn("shell compositor detach retry failed err={}", .{retry_err});
                    return;
                };
            },
            error.FallbackOnly, error.InvalidState => return,
            else => {
                log.warn("shell compositor detach failed err={}", .{err});
                return;
            },
        };
        if (self.shell_compositor.status().state == .active) self.commitShellCompositor();
    }

    pub fn resizeShellCompositorWindow(self: *App, hwnd: HWND) void {
        if (!self.shell_compositor_initialized or
            self.shell_compositor.status().state != .active) return;
        const changed = self.shell_compositor_driver.resizeWindow(@intFromPtr(hwnd)) catch |err| switch (err) {
            error.DeviceLost => {
                self.shell_compositor.markDeviceLost();
                self.shell_compositor.recover() catch |recover_err| {
                    log.warn("shell compositor resize recovery failed err={}", .{recover_err});
                    return;
                };
                const retry_changed = self.shell_compositor_driver.resizeWindow(@intFromPtr(hwnd)) catch |retry_err| {
                    if (retry_err == error.DeviceLost) self.shell_compositor.markDeviceLost();
                    log.warn("shell compositor resize retry failed err={}", .{retry_err});
                    return;
                };
                if (retry_changed) self.commitShellCompositor();
                return;
            },
            else => {
                log.warn("shell compositor resize unavailable err={}", .{err});
                return;
            },
        };
        if (changed) self.commitShellCompositor();
    }

    fn commitShellCompositor(self: *App) void {
        self.shell_compositor.commit() catch |err| switch (err) {
            error.DeviceLost => {
                self.shell_compositor.markDeviceLost();
                self.shell_compositor.recover() catch |recover_err| {
                    log.warn("shell compositor commit recovery failed err={}", .{recover_err});
                    return;
                };
                if (self.shell_compositor.status().state == .active) {
                    self.shell_compositor.commit() catch |retry_err| {
                        log.warn("shell compositor commit retry failed err={}", .{retry_err});
                    };
                }
            },
            else => log.warn("shell compositor commit unavailable err={}", .{err}),
        };
    }

    test "App.init leaves the shell compositor stopped so banners fall back to GDI" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core = try CoreApp.create(std.testing.allocator);
        defer core.destroy();

        var app: App = undefined;
        try app.init(core, .{});
        defer app.terminate();

        // Starting the native driver builds a hardware D3D11 device on the UI
        // thread and attaches a DirectComposition target to every host.
        try std.testing.expect(app.shell_compositor_initialized);
        try std.testing.expect(!app.shell_compositor_driver.isStarted());
        try std.testing.expectEqual(win32_compositor.State.fallback, app.shell_compositor.status().state);

        // A host that appears now gets no target. The banner child paints
        // itself with GDI (`Host.paintBanner`).
        const hwnd: HWND = @ptrFromInt(0x1000);
        app.attachShellCompositorWindow(hwnd);
        try std.testing.expect(!app.shell_compositor.status().compositionActive());
        try std.testing.expectEqual(@as(u32, 0), app.shell_compositor.status().active_target_count);
    }

    pub const inheritHostWindowState = window_state.inheritHostWindowState;

    pub fn automationDefaultSurface(self: *App) ?*Surface {
        if (self.core_app.focusedSurface()) |core_surface| {
            if (self.registry.findSurfaceByCore(core_surface)) |surface| return surface;
        }
        return self.registry.focusedSurfaceForUndoRedo() orelse self.registry.primarySurface();
    }

    pub fn emptyHostKeyEvent(self: *App, host_id: u32, event: input.KeyEvent) bool {
        const previous = self.empty_host_key_id;
        self.empty_host_key_id = host_id;
        defer self.empty_host_key_id = previous;
        return self.core_app.keyEvent(self, event);
    }

    fn undoRedoSurfaceForTarget(self: *App, target: apprt.Target) ?*Surface {
        return switch (target) {
            .app => if (self.empty_host_key_id) |id|
                if (self.registry.findHostById(id)) |host| host.activeSurface() else null
            else
                self.registry.focusedSurfaceForUndoRedo() orelse self.registry.primarySurface(),
            .surface => |core_surface| self.registry.findSurfaceByCore(core_surface),
        };
    }

    fn structuralUndoHostForTarget(self: *App, target: apprt.Target) ?*Host {
        if (target == .app) {
            if (self.empty_host_key_id) |id| return self.registry.findHostById(id);
        }
        if (self.undoRedoSurfaceForTarget(target)) |surface| {
            if (surface.host) |host| return host;
        }

        return switch (target) {
            .app => self.registry.hostWithNewestStructuralUndo() orelse if (self.registry.hosts.items.len > 0) self.registry.hosts.items[0] else null,
            .surface => null,
        };
    }

    fn structuralRedoHostForTarget(self: *App, target: apprt.Target) ?*Host {
        if (target == .app) {
            if (self.empty_host_key_id) |id| return self.registry.findHostById(id);
        }
        if (self.undoRedoSurfaceForTarget(target)) |surface| {
            if (surface.host) |host| return host;
        }

        return switch (target) {
            .app => self.registry.hostWithNewestStructuralRedo() orelse if (self.registry.hosts.items.len > 0) self.registry.hosts.items[0] else null,
            .surface => null,
        };
    }

    fn showPendingConPtyFallbackBanner(self: *App) void {
        if (!ptypkg.hasPendingConPtyFallbackBanner()) return;
        const surface = self.registry.primarySurface() orelse return;
        const host = surface.host orelse return;
        const text = ptypkg.takeConPtyFallbackBanner() orelse return;
        // Shown once per process and naming why output may be degraded, so
        // it stays until dismissed.
        host.setBanner(.err, text) catch |err| {
            log.warn("failed to show ConPTY fallback banner err={}", .{err});
        };
    }

    pub fn undoCutoffTimestampMs(self: *const App) u64 {
        return sys.GetTickCount64() -| self.undoTimeoutMs();
    }

    fn tabHasInspectorForSurface(self: *App, surface: *Surface) bool {
        _ = self;
        const found = Host.findTabForSurface(surface) orelse return surface.inspector_visible;
        var it = found.tab.tree.iterator();
        while (it.next()) |entry| {
            if (entry.view.inspector_visible) return true;
        }
        return false;
    }

    fn setTabInspectorVisibleForSurface(self: *App, surface: *Surface, visible: bool) !bool {
        _ = self;
        const found = Host.findTabForSurface(surface) orelse return try surface.setInspectorVisible(visible);
        var changed = false;
        var it = found.tab.tree.iterator();
        while (it.next()) |entry| {
            if (try entry.view.setInspectorVisible(visible)) changed = true;
        }
        return changed;
    }

    fn setInspectorActionForSurface(self: *App, surface: *Surface, mode: apprt.action.Inspector) !bool {
        return try self.setTabInspectorVisibleForSurface(
            surface,
            nextTabInspectorVisible(self.tabHasInspectorForSurface(surface), mode),
        );
    }

    pub fn toggleInspectorForSurface(self: *App, surface: *Surface) !bool {
        return try self.setInspectorActionForSurface(surface, .toggle);
    }

    pub fn hostTabStatus(self: *App, surface: *const Surface) HostTabStatus {
        _ = self;
        const host = surface.host orelse return .{};
        const total = host.tabs.items.len;
        var index: usize = 0;
        if (Host.findTabForSurface(@constCast(surface))) |found| index = found.index;
        return .{
            .index = index,
            .total = if (total == 0) 1 else total,
        };
    }

    pub fn showHostSurface(self: *App, surface: *Surface, focus: bool) void {
        _ = self;
        const host = surface.host orelse return;
        const tab_info = Host.findTabForSurface(surface) orelse return;
        const previous_surface = host.activeSurface();
        const previous_tab_id = if (host.active_tab < host.tabs.items.len)
            host.tabs.items[host.active_tab].id
        else
            null;
        host.active_tab = tab_info.index;
        surface.syncSharedHostWindowState(previous_surface);
        host.prepareActiveTabVisibility(tab_info.index);
        host.showTabPanes(tab_info.tab);
        // Same-host tab creation reaches this path before its first layout.
        // Raise selection only after the tab button/provider exists.
        host.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        runUiActionOrLog("tab activation chrome refresh failed", host.refreshChrome());
        if (focus) {
            surface.presentWindow();
        } else {
            surface.setVisible(true);
        }
    }

    pub fn activateSurface(self: *App, surface: *Surface) void {
        defer self.auditCreationAfterActivation();
        const was_windows_hidden = self.windows_hidden;
        self.windows_hidden = false;
        if (Host.findTabForSurface(surface)) |found| {
            const handle = found.tab.findHandle(surface) orelse found.tab.focused;
            const host_window_visible = if (found.host.hwnd) |hwnd|
                sys.IsWindowVisible(hwnd) != 0
            else
                false;
            const needs_host_sync = surfaceFocusedActivationNeedsHostSync(
                was_windows_hidden,
                host_window_visible,
                found.index,
                found.host.active_tab,
                surface.window_visible,
                surface.window_focused,
            );
            found.host.focusTabPane(found.tab, handle);
            found.host.syncSplitDim();
            if (!needs_host_sync) {
                surface.presentWindow();
                self.commitShellSurfaceFocus(surface);
                self.syncTaskbarProgressForHost(surface.host_id);
                return;
            }
        }
        self.showHostSurface(surface, true);
        self.commitShellSurfaceFocus(surface);
        self.syncTaskbarProgressForHost(surface.host_id);
    }

    pub fn commitShellSurfaceFocus(self: *App, surface: *Surface) void {
        self.commitShellSurfaceFocusIn(surface, true);
    }

    pub fn auditCreationAfterActivation(self: *App) void {
        if (!self.shell_audit_after_activation) return;
        self.shell_audit_after_activation = false;
        self.auditShellNativeMapping("surface-create");
    }

    /// For a surface shown without taking the keyboard: the window shows it,
    /// but is not recorded as the focused window.
    pub fn commitShellSurfaceActivation(self: *App, surface: *Surface) void {
        self.commitShellSurfaceFocusIn(surface, false);
    }

    fn commitShellSurfaceFocusIn(self: *App, surface: *Surface, take_window: bool) void {
        if (!self.shell_runtime_initialized) return;
        // Surface creation publishes provisional generational IDs before the
        // native HWND can receive its first focus message. Ignore that early
        // message until the prepared create transaction is authoritative.
        if (!surface.shell_committed) return;
        const pane_id = surface.shell_id orelse return;
        // No audit: a focus message can arrive between a structural
        // change's native half and its commit (hiding a closing tab's panes
        // moves the keyboard), where the two disagree by design. The
        // structural commit audits once both halves are in.
        _ = (if (take_window) self.shell_runtime.focusPane(pane_id) else self.shell_runtime.activatePane(pane_id)) catch |err| {
            log.err("shell focus transaction rejected pane={d}:{d} err={}", .{ pane_id.index, pane_id.generation, err });
            return;
        };
    }

    /// What a committed shell transaction asks of the platform (decision
    /// D7). `create_*` were read at prepare (`Prepared.created`), and the
    /// split-tree changes by the split history adapter that committed them
    /// (`Host.applyCommittedSplitHistory`). A creation leaves `focus_surface`
    /// to the caller, whose activation shows and focuses the new pane;
    /// `focus = false` says so.
    pub fn applyShellEffects(
        self: *App,
        effects: []const win32_shell.effect.Effect,
        opts: struct { focus: bool = true },
    ) void {
        for (effects) |effect| switch (effect) {
            .create_window, .create_surface, .attach_surface, .detach_surface => {},
            .focus_surface => |pane| if (opts.focus) self.followShellFocus(pane),
            .persist_session => self.scheduleSessionCheckpoint(),
        };
    }

    /// Releases a pane ID the shell model retained for a split's redo
    /// (`discard_detached_pane`), as far as it can: a failure is logged and
    /// leaves the ID retained by its window, which releases it when it
    /// closes. Nothing else names the ID by then.
    pub fn releaseRetainedShellPane(self: *App, pane_id: win32_shell.model.PaneId) void {
        var prepared = self.shell_runtime.prepare(.{ .discard_detached_pane = pane_id }) catch |err| {
            log.warn("split redo disposal kept shell pane={d}:{d} err={}", .{ pane_id.index, pane_id.generation, err });
            return;
        };
        defer prepared.deinit();
        prepared.commit(&self.shell_runtime) catch |err| {
            log.warn("split redo disposal kept shell pane={d}:{d} err={}", .{ pane_id.index, pane_id.generation, err });
        };
    }

    /// The shell model chose `pane_id` as its tab's focused pane, and maybe
    /// its tab as the window's active one: after a close the pane and tab
    /// that were survive, and when one of them closed, the first pane of the
    /// closed pane's sibling or the tab now at the closed tab's place takes
    /// over. Native focus follows, matched by stable ID, since a structural
    /// change renumbers split-tree handles and shifts tab indices. Nothing
    /// is shown or focused here; the caller activates what it shows.
    fn followShellFocus(self: *App, pane_id: win32_shell.model.PaneId) void {
        const state = &self.shell_runtime.state;
        const pane = state.paneConst(pane_id) orelse return;
        const model_tab = state.tabConst(pane.tab) orelse return;
        const window = state.windowConst(model_tab.window) orelse return;
        for (self.registry.hosts.items) |host| {
            const window_id = host.shell_id orelse continue;
            if (!window_id.eql(window.id)) continue;
            for (host.tabs.items, 0..) |*tab, index| {
                const tab_id = tab.shell_id orelse continue;
                if (!tab_id.eql(pane.tab)) continue;
                if (window.active_tab) |active| if (active.eql(tab_id)) {
                    host.active_tab = index;
                };
                var it = tab.tree.iterator();
                while (it.next()) |entry| {
                    const id = entry.view.shell_id orelse continue;
                    if (id.eql(pane_id)) host.focusTabPane(tab, entry.handle);
                }
                host.syncSplitDim();
                return;
            }
            return;
        }
    }

    pub fn syncTaskbarProgressForHost(self: *App, host_id: u32) void {
        const taskbar = if (self.taskbar_progress) |*value| value else return;
        const host = self.registry.findHostById(host_id) orelse return;
        const hwnd = host.hwnd orelse return;
        const report = if (self.registry.activeSurfaceForHost(host_id)) |surface|
            surface.effectiveTaskbarProgress()
        else
            null;
        const state_name = if (report) |value| @tagName(value.state) else "remove";
        std.log.debug("taskbar progress sync host_id={d} state={s}", .{ host_id, state_name });
        taskbar.apply(hwnd, report) catch |err| {
            std.log.warn("taskbar progress sync failed host_id={d} err={}; disabling native taskbar progress", .{ host_id, err });
            taskbar.deinit();
            self.taskbar_progress = null;
        };
    }

    fn handleToastActivation(self: *App, activation: win32_toast_activation.ActivationTarget) bool {
        if (activation.action) |action| switch (action) {
            .focus => {},
        };

        const surface = self.registry.resolveToastActivationSurface(activation) orelse return false;
        surface.present();
        return true;
    }

    /// Whether `activation` is a new click, not the second delivery of one
    /// (the popup's in-process handler and the COM activator both report a
    /// popup click when both exist).
    fn admitToastActivation(self: *App, activation: win32_toast_activation.ActivationTarget) bool {
        return self.toast_click_filter.admit(activation, std.time.milliTimestamp());
    }

    /// A click from the toast's popup handler or the COM activator. With no
    /// surface to present (`initial-window = false`, or the last window
    /// closed under `quit-after-last-window-closed = false`), it asks for a
    /// window the way a forwarded click does, and that window presents it
    /// (`consumePendingToastActivation`), as a cold start's would.
    pub fn receiveToastActivation(self: *App, activation: win32_toast_activation.ActivationTarget) void {
        if (!self.admitToastActivation(activation)) return;
        if (self.handleToastActivation(activation)) return;
        self.pending_toast_activation = activation;
        // Before the startup windows exist the first of them takes it, and a
        // terminal handoff server's windows come only from handoffs.
        if (!self.startup_windows_opened or self.embedding_mode) return;
        if (self.core_app.mailbox.push(.{ .new_window = .{} }, .instant) == 0)
            log.warn("toast activation: could not request a window", .{});
    }

    /// The installed copy's toast activator: registered once the App's
    /// message window exists, and posting to the same channel as the
    /// toast's own `Activated` handler. Never in a test build, a terminal
    /// handoff server or safe mode.
    fn toastActivatorWanted(self: *App) bool {
        if (builtin.is_test or self.embedding_mode or self.safe_mode or !self.com_initialized) return false;
        const kind = self.installKind();
        return win32_toast_activator.shouldRegister(kind == .installer, kind == .portable, self.is_elevated);
    }

    fn startToastActivator(self: *App) void {
        if (!self.toastActivatorWanted()) return;
        const delivery = self.delivery orelse return;
        // Bound before registering, so the first call has somewhere to go.
        win32_toast_activator.bind(toastActivatorSink(delivery));
        win32_toast_activator.register() catch {};
    }

    /// A cold start by COM for a click in Action Center. The launch string
    /// arrives in `Activate` only after the class object is registered, so
    /// register it, pump messages until the call (COM dispatches it to this
    /// STA) or `cold_toast_activation_wait_ms`, and return what came. A call
    /// that never came, or carried a launch noctty cannot read, yields the
    /// empty target, which presents the primary window: the user clicked a
    /// noctty toast either way, and nothing from it is applied as argv.
    fn awaitColdToastActivation(self: *App) win32_toast_activation.ActivationTarget {
        if (!self.toastActivatorWanted()) {
            log.info("toast activation start in a copy that registers no activator", .{});
            return .{};
        }
        var capture: ColdToastCapture = .{};
        win32_toast_activator.bind(capture.sink());
        // `startToastActivator` binds the App channel once it exists.
        defer win32_toast_activator.bind(null);
        win32_toast_activator.register() catch return .{};

        if (!pumpUntilColdToastActivation(&capture, cold_toast_activation_wait_ms))
            log.warn("toast activation start: no activation within {d} ms", .{cold_toast_activation_wait_ms});
        return capture.target();
    }

    fn consumePendingToastActivation(self: *App) void {
        const activation = self.pending_toast_activation orelse return;
        if (self.handleToastActivation(activation)) {
            self.pending_toast_activation = null;
        }
    }

    /// Like `activateSurface`, but neither shows, raises nor focuses the
    /// window, so windows hidden by `toggle_visibility` stay hidden and
    /// `windows_hidden` stays true.
    pub fn activateSurfaceNoFocus(self: *App, surface: *Surface) void {
        defer self.auditCreationAfterActivation();
        const was_windows_hidden = self.windows_hidden;
        if (Host.findTabForSurface(surface)) |found| {
            const handle = found.tab.findHandle(surface) orelse found.tab.focused;
            const host_window_visible = if (found.host.hwnd) |hwnd|
                sys.IsWindowVisible(hwnd) != 0
            else
                false;
            const needs_host_sync = surfaceActivationNeedsHostSync(
                was_windows_hidden,
                host_window_visible,
                found.index,
                found.host.active_tab,
                surface.window_visible,
            );
            found.host.focusTabPane(found.tab, handle);
            found.host.syncSplitDim();
            if (!needs_host_sync) {
                surface.setVisible(true);
                self.commitShellSurfaceActivation(surface);
                self.syncTaskbarProgressForHost(surface.host_id);
                runUiActionOrLog("input mode focus sync failed", found.host.refreshModeIndicator());
                return;
            }
        }
        self.showHostSurface(surface, false);
        self.commitShellSurfaceActivation(surface);
        self.syncTaskbarProgressForHost(surface.host_id);
    }

    pub fn noteSurfaceFocused(self: *App, surface: *Surface) bool {
        const found = Host.findTabForSurface(surface) orelse return false;
        const handle = found.tab.findHandle(surface) orelse return false;
        const previous_tab_id = if (found.host.active_tab < found.host.tabs.items.len)
            found.host.tabs.items[found.host.active_tab].id
        else
            null;
        const changed = surfaceFocusStateChanged(
            found.host.active_tab,
            found.tab.focused,
            found.index,
            handle,
        );
        found.host.active_tab = found.index;
        found.host.notifyActiveTabUiaSelectionChanged(previous_tab_id);
        found.host.focusTabPane(found.tab, handle);
        found.host.syncSplitDim();
        self.commitShellSurfaceFocus(surface);
        runUiActionOrLog("input mode focus sync failed", found.host.refreshModeIndicator());
        return changed;
    }

    const syncHostWindowState = window_state.syncHostWindowState;

    pub fn removeHost(self: *App, host: *Host) void {
        if (!self.registry.detachHost(host)) return;
        host.deinit();
        self.core_app.alloc.destroy(host);
    }

    pub fn windowDestroyed(self: *App, surface: *Surface) void {
        self.registry.removeWindow(surface);
        // A closed pane's toast can no longer focus anything.
        self.forgetSurfaceToast(surface);
        if (surface.host) |host| {
            if (self.session_restore_rollback_host == host) return;
            const previous_tab_id = if (host.active_tab < host.tabs.items.len)
                host.tabs.items[host.active_tab].id
            else
                null;
            // Only closing the pane the window shows as focused moves focus.
            const was_active_surface = host.activeSurface() == surface;
            surface.invalidateStructuralHistoryForDestroy();
            host.discardStructuralEntriesReferencing(surface);

            // Clear stale hover/drag state that may reference the destroyed surface's tab button
            host.setHoveredButton(null);
            host.tab_drag_index = null;
            host.tab_drag_active = false;
            if (host.tab_drop_target_surface == surface) {
                host.hideTabDropPreview();
            }

            var tab_removed = false;
            for (host.tabs.items, 0..) |*tab, i| {
                if (tab.findHandle(surface)) |handle| {
                    if (tab.tree.nodes.len == 1) {
                        // Remove first, then deinit the detached tab value. This
                        // avoids shifting the live array after poisoning the slot
                        // with `undefined` during Tab.deinit().
                        var removed = host.tabs.orderedRemove(i);
                        host.destroyTabButton(&removed);
                        removed.deinit();
                        host.active_tab = activeTabAfterRemoval(host.active_tab, i, host.tabs.items.len);
                        tab_removed = true;
                    } else {
                        const next_tree = if (surface.pending_close_tree) |prepared_tree| prepared: {
                            surface.pending_close_tree = null;
                            break :prepared prepared_tree;
                        } else emergency: {
                            if (!self.quitting) {
                                log.warn("surface destroyed without close-tree preflight; attempting emergency repair", .{});
                            }
                            break :emergency tab.tree.remove(self.core_app.alloc, handle) catch |err| {
                                log.err("emergency split removal failed after surface destruction err={}", .{err});
                                break;
                            };
                        };
                        const focused = tab.focusedSurface();
                        tab.tree.deinit();
                        tab.tree = next_tree;
                        // Focus stays on a pane that survives; the handles
                        // are renumbered, so find it again. When the focused
                        // pane itself closed, the shell model picks the next
                        // one (its `focus_surface`, applied below) and the
                        // first pane stands in until then.
                        var first = tab.tree.iterator();
                        tab.focused = (if (focused) |kept| tab.findHandle(kept) else null) orelse
                            first.next().?.handle;
                        // The closed split may have been what the tab's
                        // status badge was showing.
                        host.refreshTabStatus(i);
                    }
                    break;
                }
            }

            if (surface.pending_close_tree) |*unused_tree| {
                unused_tree.deinit();
                surface.pending_close_tree = null;
            }
            var shell_mapping_changed = false;
            if (surface.pending_shell_close) |*prepared| {
                const close_intent = prepared.intent;
                prepared.commitRetryingInterleavedFocus(&self.shell_runtime) catch |err| forced: {
                    log.err("shell close retry failed after native teardown err={}; forcing reconciliation", .{err});
                    var reduction = self.shell_runtime.forceClose(close_intent) catch |force_err| {
                        switch (force_err) {
                            error.StaleId, error.LastPane => {},
                            else => log.err("forced shell close reconciliation failed err={}", .{force_err}),
                        }
                        break :forced;
                    };
                    defer reduction.deinit(self.shell_runtime.state.allocator);
                    self.applyShellEffects(reduction.effects.items, .{});
                };
                // Native focus follows the model's choice before the
                // replacement below is activated.
                self.applyShellEffects(prepared.effects(), .{});
                prepared.deinit();
                surface.pending_shell_close = null;
                shell_mapping_changed = true;
            }
            host.notifyActiveTabUiaSelectionChanged(previous_tab_id);
            if (tab_removed) host.notifyTabListUiaChanged();

            var shell_mapping_stable = true;
            if (host.tabs.items.len == 0) {
                if (host.structural_history_disposing) {
                    host.destroy_after_structural_dispose = true;
                    shell_mapping_stable = false;
                } else {
                    if (host.hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
                    self.removeHost(host);
                }
            } else if (self.running) {
                // A close never restores, raises or takes focus from a
                // window the user is not looking at, and moves focus only
                // when the pane that had it closed.
                if (host.activeTab()) |tab| if (tab.focusedSurface()) |replacement| {
                    if (was_active_surface and tabSeenByUser(host, host.active_tab))
                        self.activateSurface(replacement)
                    else
                        self.activateSurfaceNoFocus(replacement);
                };
                // Relayout after tab removal because the chrome
                // reservation may have changed. In this fork,
                // `.auto` still shows the row since it carries the
                // essential host controls (+, overflow).
                runUiActionOrLog("surface close layout failed", host.layout());
            }
            if (shell_mapping_changed and shell_mapping_stable) {
                self.auditShellNativeMapping("surface-close");
            }
        }

        if (self.registry.windows.items.len == 0 and self.running) {
            if (self.embedding_mode) {
                if (self.exitEmbeddingServerIfIdle()) {
                    self.running = false;
                    sys.PostQuitMessage(0);
                } else {
                    self.startTerminalHandoffIdleTimer();
                }
            } else {
                self.startQuitTimer();
            }
        }
    }

    fn gotoWindow(self: *App, target: apprt.Target, direction: apprt.action.GotoWindow) !bool {
        var host_ids = try self.registry.collectHostIds(self.core_app.alloc);
        defer host_ids.deinit(self.core_app.alloc);
        if (host_ids.items.len <= 1) return false;

        const current = self.registry.findSurfaceForTarget(target) orelse self.registry.windows.items[0];
        var current_host_idx: usize = 0;
        for (host_ids.items, 0..) |host_id, i| {
            if (host_id == current.host_id) {
                current_host_idx = i;
                break;
            }
        }

        const next_idx = switch (direction) {
            .next => (current_host_idx + 1) % host_ids.items.len,
            .previous => (current_host_idx + host_ids.items.len - 1) % host_ids.items.len,
        };
        const next_surface = self.registry.activeSurfaceForHost(host_ids.items[next_idx]) orelse return false;
        self.activateSurface(next_surface);
        return true;
    }

    fn gotoSplitFallback(self: *App, target: apprt.Target, to: apprt.action.GotoSplit) !bool {
        const current = self.registry.findSurfaceForTarget(target) orelse return false;
        const found = Host.findTabForSurface(current) orelse return false;
        const from = found.tab.findHandle(current) orelse found.tab.focused;
        const goto: SplitTreeSurface.Goto = switch (to) {
            .previous => .previous_wrapped,
            .next => .next_wrapped,
            .left => .{ .spatial = .left },
            .right => .{ .spatial = .right },
            .up => .{ .spatial = .up },
            .down => .{ .spatial = .down },
        };
        const next_handle = (try found.tab.tree.goto(self.core_app.alloc, from, goto)) orelse return false;
        found.tab.focused = next_handle;
        // A zoomed tab shows only the zoomed pane, so moving away unzooms,
        // or with `split-preserve-zoom = navigation` zooms the pane moved
        // to. Lay out before focusing it, so it is visible when it gets focus.
        if (found.tab.tree.zoomed) |zoomed| {
            const next_zoom: ?SplitTreeSurface.Node.Handle =
                if (self.config.@"split-preserve-zoom".navigation) next_handle else null;
            if (next_zoom != zoomed) {
                found.tab.tree.zoom(next_zoom);
                current.invalidateRedoForUnsupportedTabStructuralAction();
                runUiActionOrLog("goto_split zoom layout failed", found.host.layout());
            }
        }
        const next_surface = found.tab.focusedSurface() orelse return false;
        self.activateSurface(next_surface);
        return true;
    }

    fn gotoSplitFallbackDirection(to: apprt.action.GotoSplit) ?apprt.action.GotoWindow {
        return switch (to) {
            .previous => .previous,
            .next => .next,
            .up, .down, .left, .right => null,
        };
    }

    pub fn resizeSplitFallback(self: *App, target: apprt.Target, value: apprt.action.ResizeSplit) !bool {
        const surface = self.registry.findSurfaceForTarget(target) orelse return false;
        const found = Host.findTabForSurface(surface) orelse return false;
        const handle = found.tab.findHandle(surface) orelse found.tab.focused;
        const layout: SplitTreeSurface.Split.Layout = switch (value.direction) {
            .left, .right => .horizontal,
            .up, .down => .vertical,
        };
        const delta_sign: f16 = switch (value.direction) {
            .left, .up => -1,
            .right, .down => 1,
        };
        const delta = std.math.clamp((@as(f16, @floatFromInt(value.amount)) / 100.0) * delta_sign, -1, 1);
        const next_tree = try found.tab.tree.resize(self.core_app.alloc, handle, layout, delta);
        if (splitTreeEquivalent(&found.tab.tree, &next_tree)) {
            var unchanged = next_tree;
            unchanged.deinit();
            return false;
        }
        if (!found.host.tryClearStructuralHistory(.normal)) {
            var rejected = next_tree;
            rejected.deinit();
            return error.HistoryDisposalDeferred;
        }
        found.tab.clearRedoHistory();
        found.tab.tree.deinit();
        found.tab.tree = next_tree;
        try found.host.layout();
        return true;
    }

    pub fn equalizeSplitsFallback(self: *App, target: apprt.Target) !bool {
        const surface = self.registry.findSurfaceForTarget(target) orelse return false;
        const found = Host.findTabForSurface(surface) orelse return false;
        const next_tree = try found.tab.tree.equalize(self.core_app.alloc);
        if (splitTreeEquivalent(&found.tab.tree, &next_tree)) {
            var unchanged = next_tree;
            unchanged.deinit();
            return false;
        }
        if (!found.host.tryClearStructuralHistory(.normal)) {
            var rejected = next_tree;
            rejected.deinit();
            return error.HistoryDisposalDeferred;
        }
        found.tab.clearRedoHistory();
        found.tab.tree.deinit();
        found.tab.tree = next_tree;
        try found.host.layout();
        return true;
    }

    pub fn closeTab(self: *App, target: apprt.Target, mode: apprt.action.CloseTabMode) !bool {
        const current = self.registry.findSurfaceForTarget(target) orelse return false;
        const found = Host.findTabForSurface(current) orelse return false;
        const host = found.host;
        const current_idx = found.index;

        switch (mode) {
            .this => {
                // With `undo-timeout = 0` the close cannot be taken back, so it
                // asks like the closes that are not undoable.
                if (self.undoOff()) {
                    const count = tabsCloseConfirmCount(host.tabs.items[current_idx..][0..1]);
                    if (count != 0) {
                        host.askBeforeClosing(.this_tab, count, &closeThisTabConfirmAccept, current);
                        return true;
                    }
                }
                return try self.closeTabUndoable(host, current_idx);
            },

            // Not undoable, unlike `.this`: ask first when a terminal in
            // the closing tabs would lose a running process.
            inline .other, .right => |beside| {
                const tabs = host.tabs.items;
                if (beside == .other and tabs.len <= 1) return false;
                if (beside == .right and current_idx + 1 >= tabs.len) return false;
                const count = if (beside == .other)
                    tabsCloseConfirmCount(tabs[0..current_idx]) + tabsCloseConfirmCount(tabs[current_idx + 1 ..])
                else
                    tabsCloseConfirmCount(tabs[current_idx + 1 ..]);
                if (count == 0) return try self.closeTabsBeside(current, beside);
                if (beside == .other)
                    host.askBeforeClosing(.other_tabs, count, &closeOtherTabsConfirmAccept, current)
                else
                    host.askBeforeClosing(.right_tabs, count, &closeRightTabsConfirmAccept, current);
                return true;
            },
        }
    }

    /// Detach tab `current_idx` into undo history and show what is left. Asks
    /// nothing: `closeTab` decides whether the close needs a prompt first.
    pub fn closeTabUndoable(self: *App, host: *Host, current_idx: usize) !bool {
        const previous_active = host.active_tab;
        // The session's last tab: saved now, as its window's close would save
        // it, and not left to the empty window's undo expiry. Undo history is
        // never saved; an undo reopens the session (`restoreClosedTabEntry`).
        const saved_here = host.tabs.items.len == 1 and self.closingEndsSession(host);
        if (saved_here) self.saveSessionAsItEnds();
        errdefer if (saved_here) {
            self.session_state_saved_before_last_host_close = false;
        };
        const entry = host.detachTabForUndo(current_idx) orelse {
            if (saved_here) self.session_state_saved_before_last_host_close = false;
            return false;
        };
        const stored_entry = host.pushStructuralUndo(entry) catch |err| {
            log.warn("close_tab undo snapshot failed err={}", .{err});
            var failed = entry;
            errdefer runUiActionOrLog("close tab rollback dispose failed", failed.dispose(host, .normal));
            try self.rollbackTabClose(host, &failed.payload.close_tab, previous_active);
            return err;
        };
        if (self.shell_runtime_initialized) shell: {
            const shell_tab_id = stored_entry.payload.close_tab.shell_id orelse {
                var failed = host.structural_undo_entries.pop().?;
                try self.rollbackTabClose(host, &failed.payload.close_tab, previous_active);
                return error.ShellStateOutOfSync;
            };
            var prepared = self.shell_runtime.prepare(.{ .detach_tab = shell_tab_id }) catch |err| {
                var failed = host.structural_undo_entries.pop().?;
                try self.rollbackTabClose(host, &failed.payload.close_tab, previous_active);
                return err;
            };
            defer prepared.deinit();
            prepared.commit(&self.shell_runtime) catch |err| {
                var failed = host.structural_undo_entries.pop().?;
                try self.rollbackTabClose(host, &failed.payload.close_tab, previous_active);
                return err;
            };
            self.applyShellEffects(prepared.effects(), .{});
            self.auditShellNativeMapping("tab-detach");
            break :shell;
        }
        // Only now: a close that rolled back above left the list as it was.
        host.notifyTabListUiaChanged();
        if (stored_entry.payload.close_tab.tab) |*tab| tab.clearRedoHistory();
        if (host.activeSurface()) |replacement| {
            if (current_idx != previous_active) {
                // A background tab closed from its button leaves
                // the active tab as it was: close the gap in the
                // strip here, since activation skips layout then,
                // and leave focus and window visibility alone.
                runUiActionOrLog("tab close layout failed", host.layout());
                runUiActionOrLog("tab close chrome refresh failed", host.refreshChrome());
                self.activateSurfaceNoFocus(replacement);
            } else self.activateSurface(replacement);
        } else {
            host.refocusHostWindow();
            runUiActionOrLog("tab close layout failed", host.layout());
            runUiActionOrLog("tab close chrome refresh failed", host.refreshChrome());
            var hint_buf: [96]u8 = undefined;
            runUiActionOrLog(
                "tab close banner failed",
                host.setBanner(.info, labels.tabClosedMessage(
                    &self.config.keybind.set,
                    .{
                        .has_modifier_remaps = self.config.@"key-remap".map.count() != 0,
                        .us_layout = sys.GetKeyboardLayout(0) == 0x04090409,
                        .undo_available = !self.undoOff(),
                    },
                    &hint_buf,
                )),
            );
        }
        return true;
    }

    /// Puts back a tab that `close_tab:this` detached when the close cannot
    /// finish, with the tab that was active before it in front again: a
    /// background tab closed from its button must not end up selected.
    fn rollbackTabClose(self: *App, host: *Host, entry: *Host.CloseTabUndo, previous_active: usize) !void {
        _ = try host.restoreClosedTabEntryNative(entry);
        if (previous_active < host.tabs.items.len) host.active_tab = previous_active;
        // The detach destroyed the tab's button, and activating an active
        // tab that did not change rebuilds no strip.
        runUiActionOrLog("tab close rollback chrome refresh failed", host.refreshChrome());
        runUiActionOrLog("tab close rollback layout failed", host.layout());
        if (host.activeSurface()) |restored| self.activateSurface(restored);
    }

    /// Close every tab beside `current`'s (`.other`), or the tabs to its
    /// right, without asking. Not undoable: the history goes first. The
    /// panes are listed before any of them closes, because each close
    /// replaces or removes its tab's split tree.
    pub fn closeTabsBeside(self: *App, current: *Surface, comptime beside: apprt.action.CloseTabMode) !bool {
        comptime std.debug.assert(beside != .this);
        const found = Host.findTabForSurface(current) orelse return false;
        const host = found.host;
        const keep = found.index;
        const alloc = self.core_app.alloc;
        var surfaces: std.ArrayListUnmanaged(*Surface) = .empty;
        defer surfaces.deinit(alloc);
        var i = host.tabs.items.len;
        while (i > 0) {
            i -= 1;
            if (i == keep or (beside == .right and i < keep)) continue;
            var it = host.tabs.items[i].tree.iterator();
            while (it.next()) |entry| try surfaces.append(alloc, entry.view);
        }
        if (surfaces.items.len == 0) return false;
        if (!host.tryClearStructuralHistory(.normal)) return error.HistoryDisposalDeferred;
        for (host.tabs.items, 0..) |*tab, index| {
            if (beside == .right and index < keep) continue;
            tab.clearRedoHistory();
        }
        for (surfaces.items) |surface| surface.close(false);
        self.activateSurface(current);
        return true;
    }

    fn gotoTab(self: *App, target: apprt.Target, goto: apprt.action.GotoTab) !bool {
        if (self.registry.windows.items.len == 0) return false;
        const current = self.registry.findSurfaceForTarget(target) orelse self.registry.windows.items[0];
        const found = Host.findTabForSurface(current) orelse return false;
        const desired = desiredTabIndex(found.host.tabs.items.len, found.index, goto) orelse return false;
        const current_idx = found.index;
        if (desired == current_idx) return false;
        const tab = &found.host.tabs.items[desired];
        const surface = tab.focusedSurface() orelse return false;
        self.activateSurface(surface);
        return true;
    }

    pub fn moveTab(self: *App, target: apprt.Target, move: apprt.action.MoveTab) !bool {
        if (self.registry.windows.items.len <= 1 or move.amount == 0) return false;
        const current = self.registry.findSurfaceForTarget(target) orelse return false;
        const found = Host.findTabForSurface(current) orelse return false;
        if (found.host.tabs.items.len <= 1) return false;
        const current_idx = found.index;
        const desired = desiredMoveIndex(found.host.tabs.items.len, current_idx, move.amount) orelse return false;
        if (desired == current_idx) return false;
        var shell_prepared: ?win32_shell.runtime.Prepared = null;
        if (self.shell_runtime_initialized) {
            const shell_id = found.tab.shell_id orelse return error.ShellStateOutOfSync;
            shell_prepared = try self.shell_runtime.prepare(.{ .reorder_tab = .{
                .tab = shell_id,
                .index = desired,
            } });
        }
        defer if (shell_prepared) |*prepared| prepared.deinit();
        if (!found.host.tryClearStructuralHistory(.normal)) return error.HistoryDisposalDeferred;
        found.tab.clearRedoHistory();
        const tab = found.host.tabs.orderedRemove(current_idx);
        found.host.tabs.insertAssumeCapacity(desired, tab);
        found.host.active_tab = desired;
        // Clearing the history can commit to the model (a detached tab or
        // pane it kept for undo is released), so the reorder is rebuilt on
        // top of that rather than failing as stale.
        if (shell_prepared) |*prepared| prepared.commitRetryingStale(&self.shell_runtime) catch |err| {
            const rollback = found.host.tabs.orderedRemove(desired);
            found.host.tabs.insertAssumeCapacity(current_idx, rollback);
            found.host.active_tab = current_idx;
            return err;
        };
        if (shell_prepared) |*prepared| self.applyShellEffects(prepared.effects(), .{});
        self.auditShellNativeMapping("tab-reorder");
        found.host.tab_buttons_dirty = true;
        const surface = found.host.tabs.items[desired].focusedSurface() orelse return false;
        self.activateSurface(surface);
        // An already-focused pane can skip host synchronization during activation.
        runUiActionOrLog("tab reorder layout failed", found.host.layout());
        return true;
    }

    pub const hideQuickTerminalHost = quick_terminal_host.hideQuickTerminalHost;

    pub const showQuickTerminalWindow = quick_terminal_host.showQuickTerminalWindow;

    pub const quickTerminalFocusPolicy = quick_terminal_host.quickTerminalFocusPolicy;

    pub const toggleQuickTerminal = quick_terminal_host.toggleQuickTerminal;

    pub const applyQuickTerminalGeometry = quick_terminal_host.applyQuickTerminalGeometry;

    fn showOnScreenKeyboard(self: *App) !void {
        try self.deferShellRequest(.on_screen_keyboard);
    }

    fn launchOnScreenKeyboard(self: *App) !void {
        const osk_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, "osk.exe");
        defer self.core_app.alloc.free(osk_w);
        const result = sys.ShellExecuteW(null, shell_open, osk_w.ptr, null, null, c.SW_SHOW);
        if (@intFromPtr(result) <= 32) return error.OpenUrlFailed;
    }

    /// `quit` and `close_all_windows` run from the message loop, through the
    /// target's window. Core does not count either as a closing action
    /// (`closingAction`) and goes on using the terminal whose key binding
    /// asked for it, so destroying the windows from inside that call freed
    /// the terminal under its own key handler: an access violation in
    /// `endKeySequence` in Debug builds.
    fn postQuit(self: *App, target: apprt.Target) void {
        // A quit from a terminal asks on its window. One from the app as a
        // whole (a global key, automation) asks on the focused window, if
        // any, else on a window with a running process.
        const near: ?*Surface = switch (target) {
            .app => self.registry.focusedSurfaceForUndoRedo(),
            .surface => |core_surface| self.registry.findSurfaceByCore(core_surface),
        };
        const post_host = (if (near) |surface| surface.host else null) orelse
            if (self.registry.hosts.items.len > 0) self.registry.hosts.items[0] else null;
        // A failed post declines the quit: running it here instead is the
        // teardown under the key handler that this function exists to avoid.
        if (post_host) |host| if (host.hwnd) |hwnd| {
            if (sys.PostMessageW(hwnd, c.WM_WINHOSTTY_QUIT, @intFromBool(near != null), 0) == 0) {
                log.warn("quit declined: could not post it to the message loop err={}", .{
                    windows.kernel32.GetLastError(),
                });
            }
            return;
        };
        self.requestQuit(near);
    }

    /// `quit` and `close_all_windows`. Unsaved Settings edits ask first, in
    /// the Settings window, which resumes the quit once they are saved or
    /// discarded (`settingsOnClosedThunk`). Then terminals that
    /// `confirm-close-surface` asks about get one prompt: the one already
    /// open, or on `near`'s window, or on a shown window with one of those
    /// terminals. Closed tabs kept for undo are not asked about.
    pub fn requestQuit(self: *App, near: ?*Surface) void {
        if (!self.session_ending) {
            if (self.settings_window.holdQuitForUnsavedChanges()) return;
            if (self.askBeforeAppClose(.app, &appQuitConfirmAccept, if (near) |surface| surface.host else null)) return;
        }
        self.quitConfirmed();
    }

    /// Install and Apply end every session the way a quit does, so they ask
    /// the same way, in the same place. The answer queues `applyStagedUpdate`.
    pub fn requestApplyStagedUpdate(self: *App) !void {
        // Before the prompt, so nobody is asked to close their sessions for an
        // install that then declines.
        if (self.settingsHoldInstall()) return;
        if (!self.session_ending) {
            if (self.askBeforeAppClose(.update, &updateApplyConfirmAccept, self.update_action_host)) return;
        }
        try self.queueApplyStagedUpdate();
    }

    /// Quit asks about unsaved Settings edits and resumes the quit once they
    /// are saved or discarded; nothing resumes an install, so it waits for the
    /// user to do that first. Checked again right before the apply runs
    /// (`dispatchDeferredOpen`), since Settings is a separate window that can
    /// be edited while the confirm is open. It fails closed: the edits are
    /// what an install would lose, so a banner that could not be shown does
    /// not let it through.
    pub fn settingsHoldInstall(self: *App) bool {
        if (self.settings_window.hwnd == null or !self.settings_window.hasPendingChanges()) return false;
        self.showUpdateInfo(.err, "Save or discard your Settings changes first, then press Install again.") catch |err| {
            log.warn("failed to show the unsaved Settings notice; install held anyway err={}", .{err});
        };
        return true;
    }

    /// `applyStagedUpdate` reaches `ShellExecuteW`, which dispatches window
    /// messages (see `runDeferredOpens`), and the confirm's answer arrives
    /// inside the overlay's own handlers, so the apply waits for the loop.
    /// While one is queued or under way, asking again does nothing.
    pub fn queueApplyStagedUpdate(self: *App) !void {
        if (self.update_apply_queued or self.update_apply_in_flight) return;
        try self.deferShellRequest(.apply_staged_update);
        self.update_apply_queued = true;
    }

    /// Where to ask, and about how many terminals, before an app-wide close
    /// that `on_accept` confirms: null when `confirm-close-surface` asks about
    /// none. The prompt already open comes first, then `near_host`'s window,
    /// then a shown window with such a terminal.
    pub fn pendingCloseAsk(
        self: *App,
        on_accept: *const fn (userdata: ?*anyopaque) void,
        near_host: ?*Host,
    ) ?struct { count: usize, host: *Host } {
        var count: usize = 0;
        var open: ?*Host = null;
        var busy: ?*Host = null;
        for (self.registry.hosts.items) |host| {
            if (host.showsConfirm(on_accept, self)) open = host;
            const host_count = tabsCloseConfirmCount(host.tabs.items);
            if (host_count == 0) continue;
            count += host_count;
            if (busy == null or (!busy.?.isShown() and host.isShown())) busy = host;
        }
        if (count == 0) return null;
        var prompt_host = open orelse busy.?;
        if (open == null) if (near_host) |host| {
            if (host.tabs.items.len > 0) prompt_host = host;
        };
        return .{ .count = count, .host = prompt_host };
    }

    /// Raise the prompt `pendingCloseAsk` finds for an app-wide close that
    /// `on_accept` resumes. False when no terminal needs asking about.
    fn askBeforeAppClose(
        self: *App,
        scope: CloseScope,
        on_accept: *const fn (userdata: ?*anyopaque) void,
        near_host: ?*Host,
    ) bool {
        const ask = self.pendingCloseAsk(on_accept, near_host) orelse return false;
        ask.host.askBeforeClosing(scope, ask.count, on_accept, self);
        return true;
    }

    pub fn quitConfirmed(self: *App) void {
        self.stopQuitTimer();
        self.running = false;
        // Quit, close_all_windows and an update install end the session with
        // its windows: save them while they are whole.
        if (self.hasSessionWindows()) self.saveSessionAsItEnds();
        self.destroyAllWindows();
        if (self.registry.windows.items.len == 0) sys.PostQuitMessage(0);
    }

    /// Each window goes a pane at a time, as closing it does: the last pane's
    /// teardown destroys and removes its host. Not through the host's own
    /// DestroyWindow while it has panes: a pane's teardown can destroy the
    /// window right below it (its tab's button, made after the pane), and
    /// Windows then sends WM_DESTROY to none of the host's other children.
    /// Those panes never ran `destroy`, kept their cores' threads and stayed
    /// in `windows`, so a quit with two tabs left the process running with
    /// no window.
    fn destroyAllWindows(self: *App) void {
        self.quitting = true;
        defer self.quitting = false;
        while (self.registry.hosts.items.len > 0) {
            const host = self.registry.hosts.items[self.registry.hosts.items.len - 1];
            const hwnd = host.hwnd orelse {
                self.removeHost(host);
                continue;
            };
            host.clearStructuralHistory(.normal);
            // Its last one may have taken the host with it.
            if (self.destroyPaneOf(host)) continue;
            _ = sys.DestroyWindow(hwnd);
        }
    }

    /// Destroys one of `host`'s panes through its own window. False when
    /// none is left that could be.
    fn destroyPaneOf(self: *App, host: *const Host) bool {
        for (self.registry.windows.items) |surface| {
            if (surface.host != host) continue;
            const pane = surface.hwnd orelse continue;
            if (sys.DestroyWindow(pane) != 0) return true;
        }
        return false;
    }

    pub const rollbackSessionRestoreHost = session_module.rollbackSessionRestoreHost;

    fn sanitizeCurrentDirectory(self: *App) !void {
        const cwd = std.process.getCwdAlloc(self.core_app.alloc) catch null;
        defer if (cwd) |v| self.core_app.alloc.free(v);

        if (cwd) |v| {
            if (isSafeStartupCwd(v)) return;
            log.warn("win32 current directory is unsafe, resetting cwd={f}", .{internal_os.redact.bytes(v)});
        } else {
            log.warn("win32 current directory unavailable, resetting to profile", .{});
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const profile = (try internal_os.windows.knownFolderPathUtf8(
            &internal_os.windows.FOLDERID_Profile,
            &buf,
        )) orelse return error.NoHomeDir;
        const profile_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, profile);
        defer self.core_app.alloc.free(profile_w);

        if (sys.SetCurrentDirectoryW(profile_w.ptr) == 0) {
            return lastError();
        }

        log.debug("win32 current directory reset cwd={f}", .{internal_os.redact.bytes(profile)});
    }

    pub fn clientSize(self: *App, hwnd: HWND) !apprt.SurfaceSize {
        _ = self;
        var rect: RECT = undefined;
        if (sys.GetClientRect(hwnd, &rect) == 0) {
            return lastError();
        }

        return .{
            .width = @max(0, rect.right - rect.left),
            .height = @max(0, rect.bottom - rect.top),
        };
    }

    pub fn resolveSurfaceSizeWithContext(
        ctx: anytype,
        fallback: apprt.SurfaceSize,
        hwnd: ?HWND,
        client_size_fn: anytype,
    ) !apprt.SurfaceSize {
        const live_hwnd = hwnd orelse return fallback;
        return try client_size_fn(ctx, live_hwnd);
    }

    /// `owned_format` is the window's record of the pixel format it set:
    /// filled in as soon as `SetPixelFormat` succeeds, so a later attempt on
    /// the same window reuses it after a context that failed to be created.
    pub fn createGLContext(self: *App, hwnd: HWND, owned_format: *?pixel_format.WglPixelFormatProvenance) !struct {
        hdc: HDC,
        hglrc: HGLRC,
        // Returned rather than logged-and-dropped so the caller can hand
        // the selected format to its benchmark memory-stage trace. Nothing
        // in the product path reads it.
        provenance: pixel_format.WglPixelFormatProvenance,
    } {
        if (self.core_app.first) beginOpenGLStartupDiagnostics();

        // GDI can load OPENGL32 by basename during pixel-format selection.
        // Pin our System32 module first, under the startup dialog suppression.
        {
            var suppression = suppressStartupLoaderErrorDialogs();
            defer suppression.restore();
            const loaded = loaded: {
                // Keep application build options out of the standalone WGL
                // module (also imported by native compositor tests).
                if (build_config.renderer_test_tools) {
                    const test_tools = struct {
                        extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: [*]u16, size: u32) callconv(.winapi) u32;
                    };
                    var value: [2]u16 = undefined;
                    if (test_tools.GetEnvironmentVariableW(
                        std.unicode.utf8ToUtf16LeStringLiteral("NOCTTY_TEST_OPENGL32_MISSING"),
                        &value,
                        value.len,
                    ) == 1 and value[0] == '1') {
                        // Exercise the real Windows loader's missing-module path.
                        break :loaded windows.kernel32.LoadLibraryExW(
                            std.unicode.utf8ToUtf16LeStringLiteral("noctty-opengl32-missing-test.dll"),
                            null,
                            0x00000800, // LOAD_LIBRARY_SEARCH_SYSTEM32
                        ) != null;
                    }
                }
                break :loaded @import("wgl.zig").ensureLoaded();
            };
            if (!loaded) return windows.unexpectedError(recordOpenGLStartupLastError(.load_opengl32));
        }

        const hdc = sys.GetDC(hwnd) orelse {
            recordOpenGLStartupWin32Failure(.get_dc, windows.kernel32.GetLastError());
            return error.GetDCFailed;
        };
        errdefer _ = sys.ReleaseDC(hwnd, hdc);

        const format_before = sys.GetPixelFormat(hdc);
        const plan = pixel_format.planPixelFormat(
            format_before,
            if (owned_format.*) |owned| owned.index else null,
        ) catch |err| {
            recordOpenGLStartupError(.set_pixel_format, err);
            return err;
        };
        const provenance = switch (plan) {
            .reuse => owned_format.*.?,
            .choose_and_set => set: {
                var selection = try pixel_format.chooseRealPixelFormat(self.hinstance, hwnd, hdc);
                log.debug(
                    "selected WGL pixel format index={} source={s} srgb_capable={} depth_bits={} stencil_bits={}",
                    .{
                        selection.provenance.index,
                        @tagName(selection.provenance.selection_source),
                        selection.provenance.srgb_capable,
                        selection.provenance.depth_bits,
                        selection.provenance.stencil_bits,
                    },
                );

                if (sys.SetPixelFormat(hdc, selection.pixel_format, &selection.descriptor) == 0)
                    return windows.unexpectedError(recordOpenGLStartupLastError(.set_pixel_format));
                pixel_format.validatePixelFormatSetTransition(
                    format_before,
                    selection.pixel_format,
                    sys.GetPixelFormat(hdc),
                ) catch |err| {
                    recordOpenGLStartupError(.set_pixel_format, err);
                    return err;
                };
                // The window keeps this format whatever happens next.
                owned_format.* = selection.provenance;
                break :set selection.provenance;
            },
        };

        const hglrc = sys.wglCreateContext(hdc) orelse
            return windows.unexpectedError(recordOpenGLStartupLastError(.create_context));
        errdefer _ = sys.wglDeleteContext(hglrc);

        if (sys.wglMakeCurrent(hdc, hglrc) == 0)
            return windows.unexpectedError(recordOpenGLStartupLastError(.initial_make_current));

        return .{
            .hdc = hdc,
            .hglrc = hglrc,
            .provenance = provenance,
        };
    }

    /// Record that OpenGL startup failed at `step` with the thread's last
    /// Win32 error, and return that error code. The caller turns it into
    /// `error.Unexpected` with `windows.unexpectedError`, so a Debug build's
    /// stack dump still starts at the failing call.
    fn recordOpenGLStartupLastError(step: OpenGLStartupStep) windows.Win32Error {
        const err = windows.kernel32.GetLastError();
        recordOpenGLStartupWin32Failure(step, err);
        return err;
    }

    /// Checks the target now, so a refused one still fails at the caller,
    /// and leaves the open itself to `runDeferredOpens`. It never asks:
    /// pass only a target noctty chose or the user already confirmed. A
    /// link from terminal output goes through `openLink`.
    fn openUrl(self: *App, url: []const u8) !void {
        return openWin32Target(self.core_app.alloc, self, url, deferOpenTarget);
    }

    fn deferOpenTarget(self: *App, target: []const u8) !void {
        const alloc = self.core_app.alloc;
        const owned = try alloc.dupe(u8, target);
        errdefer alloc.free(owned);
        try self.deferShellRequest(.{ .target = owned });
    }

    /// `openUrl` for a link opened in a terminal, whose text the terminal's
    /// output chose: a scheme past the web and mail ones opens only once the
    /// user confirms it in `target`'s window.
    fn openLink(self: *App, target: apprt.Target, url: []const u8) !void {
        return openWin32Target(self.core_app.alloc, LinkRequest{ .app = self, .target = target }, url, LinkRequest.open);
    }

    const LinkRequest = struct {
        app: *App,
        target: apprt.Target,

        fn open(self: LinkRequest, checked: []const u8) !void {
            const scheme = confirmedLinkScheme(checked) orelse return self.app.deferOpenTarget(checked);
            const surface = self.app.registry.findSurfaceForTarget(self.target) orelse return error.NoSurface;
            try askBeforeOpeningLink(surface, scheme, checked);
        }
    };

    /// Shows the checked `link` (so one line, the text as typed) in the
    /// preview pane and names the app its scheme opens in, as upstream's
    /// UntrustedURLAlert does. Cancel is the default there, so this is a
    /// `program_request` prompt: it opens on Cancel.
    fn askBeforeOpeningLink(surface: *Surface, scheme: []const u8, link: []const u8) !void {
        const host = surface.host orelse return error.NoHost;
        const alloc = surface.app.core_app.alloc;
        const owned = try alloc.dupe(u8, link);
        errdefer alloc.free(owned);
        const handler = linkHandlerName(alloc, scheme, internal_os.windows.AssocQueryStringW);
        defer if (handler == .app) alloc.free(handler.app);
        const body = try labels.linkPromptBody(alloc, handler, scheme);
        defer alloc.free(body);
        try host.showConfirm(.{
            .title = labels.link_prompt_title,
            .body = body,
            .accept_label = labels.link_prompt_accept_label,
            .cancel_label = "Cancel",
            .contents = link,
            .program_request = true,
        }, &linkConfirmAccept, &linkConfirmCancel, surface);
        // After showConfirm: replacing this pane's earlier prompt released
        // the link that one held.
        surface.setPendingLinkOpen(owned);
    }

    /// `userdata` is the Surface that asked; its destruction cancels the
    /// prompt (`cancelConfirmIfOwnedBy`). This runs inside the overlay's
    /// handlers, so `openUrl` checks the link again and only queues it.
    fn linkConfirmAccept(userdata: ?*anyopaque) void {
        const surface: *Surface = @ptrCast(@alignCast(userdata orelse return));
        const link = surface.takePendingLinkOpen() orelse return;
        const app = surface.app;
        defer app.core_app.alloc.free(link);
        app.openUrl(link) catch |err| log.warn("confirmed link open failed err={}", .{err});
    }

    fn linkConfirmCancel(userdata: ?*anyopaque, _: ConfirmCancelReason) void {
        const surface: *Surface = @ptrCast(@alignCast(userdata orelse return));
        const link = surface.takePendingLinkOpen() orelse return;
        surface.app.core_app.alloc.free(link);
    }

    /// UTF-16 units `linkHandlerName` takes, terminator included.
    const link_handler_name_cap = 128;

    /// The app Windows opens `scheme` links with for the verb
    /// `shellExecuteOpenTarget` uses, from its registration and its
    /// program's version resource (nothing is run). `.app` (owned on
    /// `alloc`) only for a name that is one whole line of plain text;
    /// `.none` when no app is set. Unlike ShellExecuteW it delivers no
    /// window messages (measured with posted and sent ones), so the
    /// click's window procedure may call it.
    fn linkHandlerName(alloc: Allocator, scheme: []const u8, comptime query: anytype) labels.LinkHandler {
        var scheme_w: [16:0]u16 = @splat(0);
        if (scheme.len > scheme_w.len) return .unnamed;
        for (scheme, 0..) |byte, i| scheme_w[i] = byte;
        var name: [link_handler_name_cap]u16 = undefined;
        var len: u32 = name.len;
        switch (query(c.ASSOCF_NOTRUNCATE | c.ASSOCF_INIT_IGNOREUNKNOWN, c.ASSOCSTR_FRIENDLYAPPNAME, &scheme_w, shell_open, &name, &len)) {
            0 => {},
            c.HRESULT_NO_ASSOCIATION => return .none,
            else => return .unnamed,
        }
        // The count includes the terminator.
        if (len < 2 or len > name.len or name[len - 1] != 0) return .unnamed;
        const text = std.unicode.utf16LeToUtf8Alloc(alloc, name[0 .. len - 1]) catch return .unnamed;
        if (!isSafeLinkText(text)) {
            alloc.free(text);
            return .unnamed;
        }
        return .{ .app = text };
    }

    /// Ownership transfers only after append succeeds; callers retain their
    /// errdefer cleanup on allocation failure.
    fn deferShellRequest(self: *App, request: DeferredOpen) !void {
        try self.deferred_opens.append(self.core_app.alloc, request);
    }

    fn dispatchDeferredOpen(self: *App, request: *const DeferredOpen) !void {
        // Checked again just before dispatch, as when URL opens ran in place.
        switch (request.*) {
            .target => |target| return openWin32Target(self.core_app.alloc, self, target, dispatchOpenTarget),
            .text_editor => |editor| {
                openWin32Target(self.core_app.alloc, self, editor.path, dispatchTextEditor) catch |err| {
                    if (editor.from_settings and self.settings_window.hwnd != null) {
                        self.settings_window.editorOpenFailed();
                    } else {
                        _ = self.showHostBanner(.app, .err, @import("../../os/windows_text_editor.zig").failure_message) catch false;
                    }
                    return err;
                };
                return;
            },
            // Off the queue now, so a later answer queues again if this one
            // is held or fails.
            .apply_staged_update => self.update_apply_queued = false,
            else => {},
        }
        if (self.test_shell_request) |hook| return hook(self, request);
        switch (request.*) {
            .target, .text_editor => unreachable,
            .apply_staged_update => {
                if (self.settingsHoldInstall()) return;
                try self.applyStagedUpdate();
            },
            .on_screen_keyboard => try self.launchOnScreenKeyboard(),
            .elevated_window => |launch| switch (try win32_elevation.launchElevated(self.core_app.alloc, launch.parameters, launch.cwd)) {
                .launched => {},
                .cancelled => log.info("win32 elevated launch cancelled by user", .{}),
            },
        }
    }

    /// Runs the queued opens, oldest first, including any queued while one
    /// runs. Returns whether any ran. Call only from the top of the message
    /// loop (`drainDeferredOpens`): `ShellExecuteW` dispatches window messages while it works
    /// (measured: a URL scheme open delivered posted WM_CLOSE and WM_KEYDOWN
    /// messages, and a cross-thread sent message, to a window on the calling
    /// thread), and one of them can destroy the Surface or Host whose window
    /// procedure asked for the open. Run from the loop, no such frame is left
    /// below the open to use the freed memory.
    fn runDeferredOpens(self: *App) bool {
        if (self.deferred_opens.items.len == 0) return false;
        const alloc = self.core_app.alloc;
        while (self.deferred_opens.items.len > 0) {
            const request = self.deferred_opens.orderedRemove(0);
            defer request.deinit(alloc);
            self.dispatchDeferredOpen(&request) catch |err| {
                log.warn("deferred shell request failed kind={s} err={}", .{ @tagName(request), err });
            };
        }
        return true;
    }

    /// The message loop's step for deferred opens: run them, then do what the
    /// loop does after a dispatched message, because the messages
    /// ShellExecuteW dispatched can include our own wake, which the window
    /// procedures swallow. Repeats while that tick queued more opens. Returns
    /// whether the loop should exit.
    fn drainDeferredOpens(self: *App) !bool {
        while (self.runDeferredOpens()) {
            if (try self.finishLoopStep()) return true;
        }
        return false;
    }

    pub fn discardDeferredOpens(self: *App) void {
        const alloc = self.core_app.alloc;
        for (self.deferred_opens.items) |request| request.deinit(alloc);
        self.deferred_opens.deinit(alloc);
        self.deferred_opens = .empty;
        self.update_apply_queued = false;
    }

    fn openWin32Target(
        alloc: Allocator,
        context: anytype,
        target: []const u8,
        comptime dispatch: anytype,
    ) !void {
        // Noctty fork hardening: the upstream Windows fallback dispatches any
        // target through FileProtocolHandler. ShellExecuteW must instead stay
        // inside the schemes and non-executable local files noctty produces.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const checked = try prepareWin32OpenTarget(arena.allocator(), target) orelse {
            log.warn("refusing unsafe Win32 open target len={}", .{target.len});
            return error.OpenUrlRejected;
        };

        try dispatch(context, checked);
    }

    fn dispatchOpenTarget(self: *App, target: []const u8) !void {
        if (self.test_open_target) |hook| return hook(self, target);
        if (builtin.mode == .Debug and
            try recordOpenUrlForTest(self.core_app.alloc, target)) return;

        return shellExecuteOpenTarget(self, target);
    }

    fn dispatchTextEditor(self: *App, path: []const u8) !void {
        if (self.test_open_target) |hook| return hook(self, path);
        if (builtin.mode == .Debug and
            try recordOpenUrlForTest(self.core_app.alloc, path)) return;
        try @import("../../os/windows_text_editor.zig").open(self.core_app.alloc, path);
    }

    fn shellExecuteOpenTarget(self: *App, target: []const u8) !void {
        const url_w = try std.unicode.utf8ToUtf16LeAllocZ(self.core_app.alloc, target);
        defer self.core_app.alloc.free(url_w);

        const result = sys.ShellExecuteW(null, shell_open, url_w.ptr, null, null, c.SW_SHOW);
        if (@intFromPtr(result) <= 32) return error.OpenUrlFailed;
    }

    test "a link open runs from the message loop, not inside the caller that asked for it" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();

        const Hook = struct {
            // Stands in for the window procedure that handled the click.
            var in_caller = false;
            var opened_in_caller: ?bool = null;
            var opened: [2][64]u8 = undefined;
            var opened_len: [2]usize = undefined;
            var count: usize = 0;

            fn open(app_: *App, target: []const u8) anyerror!void {
                opened_in_caller = in_caller;
                if (count >= opened.len) return error.TestUnexpectedOpen;
                @memcpy(opened[count][0..target.len], target);
                opened_len[count] = target.len;
                count += 1;
                // ShellExecuteW dispatches messages; one of them may be
                // another click on a link.
                if (count == 1) _ = try app_.performAction(.app, .open_url, .{
                    .kind = .unknown,
                    .url = "https://example.com/second",
                });
            }
        };
        Hook.in_caller = false;
        Hook.opened_in_caller = null;
        Hook.count = 0;
        app.test_open_target = &Hook.open;

        // Surface.processLinks reaches the opener through this action.
        Hook.in_caller = true;
        try std.testing.expect(try app.performAction(.app, .open_url, .{
            .kind = .unknown,
            .url = "https://example.com/first",
        }));
        Hook.in_caller = false;
        try std.testing.expectEqual(@as(?bool, null), Hook.opened_in_caller);

        // The message loop runs it, and the open it pumped, in order.
        try std.testing.expect(app.runDeferredOpens());
        try std.testing.expectEqual(@as(?bool, false), Hook.opened_in_caller);
        try std.testing.expectEqual(@as(usize, 2), Hook.count);
        try std.testing.expectEqualStrings("https://example.com/first", Hook.opened[0][0..Hook.opened_len[0]]);
        try std.testing.expectEqualStrings("https://example.com/second", Hook.opened[1][0..Hook.opened_len[1]]);
        try std.testing.expect(!app.runDeferredOpens());

        // A refused target still fails at the caller and queues nothing.
        try std.testing.expectError(error.OpenUrlRejected, app.performAction(.app, .open_url, .{
            .kind = .unknown,
            .url = "search-ms:query=*.exe",
        }));
        try std.testing.expectEqual(@as(usize, 0), app.deferred_opens.items.len);

        // The queued target is checked again right before dispatch.
        const unchecked = try std.testing.allocator.dupe(u8, "search-ms:query=*.exe");
        app.deferred_opens.append(std.testing.allocator, .{ .target = unchecked }) catch |err| {
            std.testing.allocator.free(unchecked);
            return err;
        };
        try std.testing.expect(app.runDeferredOpens());
        try std.testing.expectEqual(@as(usize, 2), Hook.count);
    }

    test "a refused link open says so in the window's banner" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &.{.{ .storage = &surface, .host = &host, .register = true }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();
        defer app.discardDeferredOpens();

        // A missing file, a program, a share and a device path never reach the
        // shell, and the click says so.
        for ([_][]const u8{
            "C:\\pkg42-missing-dir\\missing.txt",
            "C:\\Windows\\System32\\cmd.exe",
            "\\\\server\\share\\a.txt",
            "\\\\.\\pipe\\x",
            "search-ms:query=*.exe",
        }) |target| {
            try host.setBanner(.none, null);
            try std.testing.expectError(error.OpenUrlRejected, app.performAction(.app, .open_url, .{
                .kind = .unknown,
                .url = target,
            }));
            try std.testing.expectEqual(HostBannerKind.info, host.banner_kind);
            try std.testing.expectEqualStrings(labels.open_refused_banner, host.banner_text.?);
            try std.testing.expectEqual(@as(usize, 0), app.deferred_opens.items.len);
        }

        // So does a script's 8.3 alias, which link text such as `.\CMD~1`
        // resolves to unchanged (`internal_os.local_path.linkTarget`): it is refused by
        // the name its folder stores.
        var tmp = try internal_os.TempDir.init();
        defer tmp.deinit();
        try tmp.dir.writeFile(.{ .sub_path = ".cmd", .data = "fixture" });
        const script = try tmp.dir.realpathAlloc(std.testing.allocator, ".cmd");
        defer std.testing.allocator.free(script);
        const alias = try test_short_path.of(std.testing.allocator, script);
        defer std.testing.allocator.free(alias);
        if (std.mem.eql(u8, std.fs.path.basename(alias), ".cmd")) {
            std.log.warn("no 8.3 alias for .cmd; 8.3 names are off on this volume", .{});
        } else {
            try host.setBanner(.none, null);
            try std.testing.expectError(error.OpenUrlRejected, app.performAction(.app, .open_url, .{
                .kind = .unknown,
                .url = alias,
            }));
            try std.testing.expectEqual(HostBannerKind.info, host.banner_kind);
            try std.testing.expectEqualStrings(labels.open_refused_banner, host.banner_text.?);
            try std.testing.expectEqual(@as(usize, 0), app.deferred_opens.items.len);
        }

        // An accepted open leaves the banner alone.
        try host.setBanner(.none, null);
        try std.testing.expect(try app.performAction(.app, .open_url, .{
            .kind = .unknown,
            .url = "https://example.com/",
        }));
        try std.testing.expectEqual(HostBannerKind.none, host.banner_kind);
        try std.testing.expectEqual(@as(usize, 1), app.deferred_opens.items.len);

        // Quick select says why nothing happened, in the same banner.
        try host.setBanner(.none, null);
        surface.showQuickSelectNotice(labels.quick_select_no_targets_banner);
        try std.testing.expectEqualStrings(labels.quick_select_no_targets_banner, host.banner_text.?);
        surface.showQuickSelectNotice(labels.quick_select_too_many_banner);
        try std.testing.expectEqualStrings(labels.quick_select_too_many_banner, host.banner_text.?);
    }

    test "a link past the web and mail schemes opens only once its prompt is accepted" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &.{.{ .storage = &surface, .host = &host, .register = true }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();

        const Hook = struct {
            var count: usize = 0;
            var opened: [64]u8 = undefined;
            var opened_len: usize = 0;

            fn open(_: *App, target: []const u8) anyerror!void {
                count += 1;
                if (target.len > opened.len) return error.TestTargetTooLong;
                @memcpy(opened[0..target.len], target);
                opened_len = target.len;
            }
        };
        const Step = struct {
            /// What Surface.processLinks sends for a Ctrl+click in `pane`.
            fn click(a: *App, pane: *Surface, url: []const u8) !bool {
                return a.performAction(.{ .surface = pane.core() }, .open_url, .{ .kind = .unknown, .url = url });
            }

            /// Open acts at once, as for a user past the arming delay. Not
            /// `.?`: a panic would end the test binary and hide later tests.
            fn arm(h: *Host) !void {
                const payload = if (h.confirm_payload) |*open| open else return error.TestExpectedPrompt;
                payload.armed_at_ms = 0;
            }
        };
        app.test_open_target = &Hook.open;
        const alloc = core_app.alloc;
        const prompted = "ssh:user@host";

        // Each scheme past web and mail, spelled out as docs/windows.md
        // lists them, and two in another case.
        for ([_]struct { []const u8, []const u8 }{
            .{ "ftp://example.com/x", "ftp" },
            .{ prompted, "ssh" },
            .{ "git://example.com/repo.git", "git" },
            .{ "tel:+1555", "tel" },
            .{ "magnet:?xt=urn:btih:0123456789abcdef", "magnet" },
            .{ "ipfs://bafyexample", "ipfs" },
            .{ "ipns://example.com", "ipns" },
            .{ "gemini://x", "gemini" },
            .{ "gopher://example.com", "gopher" },
            .{ "news:comp.lang.zig", "news" },
            .{ "SSH:user@host", "ssh" },
            .{ "Magnet:?xt=urn:btih:0123456789abcdef", "magnet" },
        }) |case| {
            const link, const scheme = case;
            errdefer std.debug.print("link: {s}\n", .{link});
            Hook.count = 0;

            // The click asks in the pane's window, shows the exact link in
            // the preview pane, and queues nothing.
            try std.testing.expect(try Step.click(&app, &surface, link));
            try std.testing.expect(host.overlay_mode == .confirm);
            const payload = host.confirm_payload orelse return error.TestExpectedPrompt;
            const preview = payload.preview orelse return error.TestExpectedPreview;
            try std.testing.expectEqualStrings(link, preview.text);
            // The body is the one for its scheme and what Windows says
            // opens it now: a machine's handler is no fixed answer.
            const handler = linkHandlerName(alloc, scheme, internal_os.windows.AssocQueryStringW);
            defer if (handler == .app) alloc.free(handler.app);
            const body = try labels.linkPromptBody(alloc, handler, scheme);
            defer alloc.free(body);
            try std.testing.expectEqualStrings(body, payload.body);
            // As upstream's alert, it opens on Cancel.
            try std.testing.expect(payload.program_request);
            try std.testing.expect(!app.runDeferredOpens());

            // Cancel opens nothing.
            host.invokeConfirmCancel();
            try std.testing.expect(host.overlay_mode == .none);
            try std.testing.expect(!app.runDeferredOpens());
            try std.testing.expectEqual(@as(usize, 0), Hook.count);

            // Open queues it; the message loop opens it, once.
            try std.testing.expect(try Step.click(&app, &surface, link));
            try Step.arm(&host);
            host.invokeConfirmAccept();
            try std.testing.expect(host.overlay_mode == .none);
            try std.testing.expectEqual(@as(usize, 0), Hook.count);
            try std.testing.expect(app.runDeferredOpens());
            try std.testing.expectEqual(@as(usize, 1), Hook.count);
            try std.testing.expectEqualStrings(link, Hook.opened[0..Hook.opened_len]);
            host.invokeConfirmAccept();
            try std.testing.expect(!app.runDeferredOpens());
        }

        // Web and mail links still open on the click.
        for ([_][]const u8{ "https://example.com", "HTTPS://example.com", "mailto:a@b.c" }) |link| {
            Hook.count = 0;
            try std.testing.expect(try Step.click(&app, &surface, link));
            try std.testing.expect(host.overlay_mode == .none);
            try std.testing.expect(app.runDeferredOpens());
            try std.testing.expectEqual(@as(usize, 1), Hook.count);
            try std.testing.expectEqualStrings(link, Hook.opened[0..Hook.opened_len]);
        }

        // Open runs the gate again: a link it refuses is never queued.
        Hook.count = 0;
        try std.testing.expect(try Step.click(&app, &surface, prompted));
        alloc.free(surface.takePendingLinkOpen() orelse return error.TestExpectedPendingLink);
        surface.setPendingLinkOpen(try alloc.dupe(u8, "search-ms:query=*.exe"));
        try Step.arm(&host);
        host.invokeConfirmAccept();
        try std.testing.expect(surface.pending_link_open == null);
        try std.testing.expect(!app.runDeferredOpens());

        // A pane that closes first takes its prompt with it (`Surface.destroy`
        // cancels it, then frees the link), and a late Open does nothing.
        try std.testing.expect(try Step.click(&app, &surface, prompted));
        host.cancelConfirmIfOwnedBy(@ptrCast(&surface));
        try std.testing.expect(host.overlay_mode == .none);
        if (surface.takePendingLinkOpen()) |link| alloc.free(link);
        host.invokeConfirmAccept();
        try std.testing.expect(!app.runDeferredOpens());

        // So does its tab closing into undo history.
        try std.testing.expect(try Step.click(&app, &surface, prompted));
        var entry = host.detachTabForUndo(0) orelse return error.TestExpectedDetach;
        defer entry.dispose(&host, .host_destroy) catch {}; // Best-effort test teardown.
        try std.testing.expect(host.overlay_mode == .none);
        try std.testing.expect(surface.pending_link_open == null);
        host.invokeConfirmAccept();
        try std.testing.expect(!app.runDeferredOpens());
        try std.testing.expectEqual(@as(usize, 0), Hook.count);
        try std.testing.expect(try host.restoreClosedTabEntry(&entry.payload.close_tab));
    }

    test "a link asks first by the scheme before its first colon, in any case" {
        inline for (confirmed_link_schemes) |scheme| {
            try std.testing.expectEqualStrings(scheme, confirmedLinkScheme(scheme ++ ":x") orelse return error.TestExpectedScheme);
        }
        for ([_]struct { []const u8, []const u8 }{
            .{ "SSH:x", "ssh" },
            .{ "Magnet:?xt=urn:btih:0", "magnet" },
            .{ "GEMINI://x", "gemini" },
        }) |case| {
            try std.testing.expectEqualStrings(case[1], confirmedLinkScheme(case[0]) orelse return error.TestExpectedScheme);
        }
        // Web and mail URLs, local paths (`C:` is no scheme), and schemes
        // that only look like one of the list.
        for ([_][]const u8{ "https://a", "HTTP://a", "mailto:a@b.c", "C:\\x", "C:/x", "file:///C:/x", "ssh", "sshx:y", "ss:h", "x:ssh:y" }) |checked| {
            errdefer std.debug.print("checked: {s}\n", .{checked});
            try std.testing.expect(confirmedLinkScheme(checked) == null);
        }
    }

    test "a link prompt names the scheme's app only from one whole line of plain text" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const Fake = struct {
            var reply: []const u16 = &.{};
            var reply_len: u32 = 0;
            var hr: windows.HRESULT = 0;

            fn query(flags: u32, str: u32, assoc: [*:0]const u16, extra: ?[*:0]const u16, out: ?[*]u16, len: *u32) windows.HRESULT {
                if (flags != (c.ASSOCF_NOTRUNCATE | c.ASSOCF_INIT_IGNOREUNKNOWN) or
                    str != c.ASSOCSTR_FRIENDLYAPPNAME or len.* != link_handler_name_cap or extra == null or
                    !std.mem.eql(u16, std.mem.span(assoc), std.unicode.utf8ToUtf16LeStringLiteral("ssh")) or
                    !std.mem.eql(u16, std.mem.span(extra.?), std.mem.span(shell_open))) return 1;
                @memcpy(out.?[0..reply.len], reply);
                len.* = reply_len;
                return hr;
            }
        };
        const alloc = std.testing.allocator;
        const W = std.unicode.utf8ToUtf16LeStringLiteral;
        for ([_]struct { []const u16, u32, windows.HRESULT, labels.LinkHandler }{
            .{ W("PuTTY\x00"), 6, 0, .{ .app = "PuTTY" } },
            // No app is set (ERROR_NO_ASSOCIATION); S_FALSE names none.
            .{ W("PuTTY\x00"), 6, c.HRESULT_NO_ASSOCIATION, .none },
            .{ W("PuTTY\x00"), 6, 1, .unnamed },
            // No terminator, an empty name, a count past the buffer.
            .{ W("PuTTY"), 5, 0, .unnamed },
            .{ W("\x00"), 1, 0, .unnamed },
            .{ W("PuTTY\x00"), link_handler_name_cap + 1, 0, .unnamed },
            // Hidden or line-breaking characters, an embedded NUL.
            .{ W("Pu\u{202E}TTY\x00"), 7, 0, .unnamed },
            .{ W("Pu\nTTY\x00"), 7, 0, .unnamed },
            .{ W("Pu\x00TTY\x00"), 7, 0, .unnamed },
        }) |case| {
            Fake.reply = case[0];
            Fake.reply_len = case[1];
            Fake.hr = case[2];
            const handler = App.linkHandlerName(alloc, "ssh", Fake.query);
            defer if (handler == .app) alloc.free(handler.app);
            try std.testing.expectEqual(std.meta.activeTag(case[3]), std.meta.activeTag(handler));
            if (case[3] == .app) try std.testing.expectEqualStrings(case[3].app, handler.app);
        }
    }

    test "deferred shell requests own payloads and run after their callers return" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();

        const Hook = struct {
            var in_caller = false;
            var launched_in_caller = false;
            var count: usize = 0;
            var kinds: [3]std.meta.Tag(DeferredOpen) = undefined;
            var saw_elevation_payload = false;
            fn launch(app_: *App, request: *const DeferredOpen) anyerror!void {
                launched_in_caller = launched_in_caller or in_caller;
                if (count >= kinds.len) return error.TestUnexpectedLaunch;
                kinds[count] = std.meta.activeTag(request.*);
                count += 1;
                if (request.* == .elevated_window) {
                    saw_elevation_payload = request.elevated_window.parameters.len > 0;
                    if (request.elevated_window.cwd) |cwd| try std.testing.expect(cwd.len > 0);
                }
                // Stand in for a message pumped by the shell launcher.
                if (count == 1) try app_.showOnScreenKeyboard();
            }
        };
        Hook.in_caller = true;
        Hook.launched_in_caller = false;
        Hook.count = 0;
        Hook.saw_elevation_payload = false;
        app.test_shell_request = &Hook.launch;
        try std.testing.expect(try app.performAction(.app, .show_on_screen_keyboard, {}));
        try std.testing.expect(try app.performAction(.app, .new_window_elevated, .{ .profile_key = "" }));
        Hook.in_caller = false;
        try std.testing.expectEqual(@as(usize, 0), Hook.count);
        try std.testing.expect(app.runDeferredOpens());
        try std.testing.expect(!Hook.launched_in_caller);
        try std.testing.expect(Hook.saw_elevation_payload);
        try std.testing.expectEqual(@as(usize, 3), Hook.count);
        try std.testing.expectEqualSlices(std.meta.Tag(DeferredOpen), &.{ .on_screen_keyboard, .elevated_window, .on_screen_keyboard }, &Hook.kinds);
        try std.testing.expect(!app.runDeferredOpens());

        // Teardown owns pending payloads too; the testing allocator checks
        // both the successful dispatch and undispatched cleanup for leaks.
        {
            const parameters = try std.testing.allocator.dupeZ(u8, "--test-pending");
            errdefer std.testing.allocator.free(parameters);
            const cwd = try std.testing.allocator.dupe(u8, "C:\\pending");
            errdefer std.testing.allocator.free(cwd);
            try app.deferShellRequest(.{ .elevated_window = .{ .parameters = parameters, .cwd = cwd } });
        }
        app.discardDeferredOpens();
        try std.testing.expectEqual(@as(usize, 0), app.deferred_opens.items.len);
    }

    test "the message loop ticks the core after the opens it ran" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &.{.{ .storage = &surface, .host = &host, .register = true }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();

        const Hook = struct {
            var opens: usize = 0;
            var new_windows: usize = 0;

            fn open(_: *App, _: []const u8) anyerror!void {
                opens += 1;
            }

            fn createSurface(_: *App, _: *const configpkg.Config, _: LPCWSTR, _: SurfaceInitOptions) anyerror!*Surface {
                new_windows += 1;
                return error.TestWindowCreateFailed;
            }
        };
        Hook.opens = 0;
        Hook.new_windows = 0;
        app.test_open_target = &Hook.open;
        app.test_create_window_surface = &Hook.createSurface;
        app.running = true;
        app.recovery_ready_resolved = true;

        // Nothing queued: no tick, so the mailbox message waits.
        try std.testing.expect(core_app.mailbox.push(.{ .new_window = .{} }, .instant) != 0);
        try std.testing.expect(!try app.drainDeferredOpens());
        try std.testing.expectEqual(@as(usize, 0), Hook.new_windows);

        // A wake the open swallowed would have left that message waiting too.
        _ = try app.performAction(.app, .open_url, .{ .kind = .unknown, .url = "https://example.com/" });
        try std.testing.expect(!try app.drainDeferredOpens());
        try std.testing.expectEqual(@as(usize, 1), Hook.opens);
        try std.testing.expectEqual(@as(usize, 1), Hook.new_windows);
    }

    fn isAllowedWin32OpenTarget(alloc: Allocator, target: []const u8) !bool {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        return try prepareWin32OpenTarget(arena.allocator(), target) != null;
    }

    /// The returned local path is both checked and dispatched. In particular,
    /// never check a decoded file URI and then hand its raw spelling to ShellExecute.
    fn prepareWin32OpenTarget(alloc: Allocator, target: []const u8) !?[]const u8 {
        if (!isSafeLinkText(target)) return null;
        if (windows_shell.isDriveAbsolutePath(target)) {
            return try prepareWin32LocalFile(alloc, target);
        }
        if (isWin32UncOrDevicePath(target)) return null;

        const uri = std.Uri.parse(target) catch return null;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "file")) {
            return try prepareWin32FileUri(alloc, uri);
        }

        // ShellExecuteW writes the URL into its handler's registered command
        // line as it is: a quote ends a quoted "%1" and a space splits an
        // unquoted %1, so either can add arguments of the program's choosing.
        // A URI has neither unencoded; std.Uri.parse takes both.
        if (std.mem.indexOfAny(u8, target, " \"") != null) return null;
        // As upstream's UntrustedURL.decision: a web URL needs a host
        // (`https:x` and `https:///x` have none) and a mailto URL an address.
        if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
            if (uri.host == null or uri.host.?.isEmpty()) return null;
        }
        if (std.ascii.eqlIgnoreCase(uri.scheme, "mailto") and uri.path.isEmpty()) return null;
        for ([_][]const u8{ "http", "https", "mailto" } ++ confirmed_link_schemes) |scheme| {
            if (std.ascii.eqlIgnoreCase(uri.scheme, scheme)) return target;
        }
        return null;
    }

    /// The schemes past web and mail that the gate passes to their
    /// registered handler. A link with one opens only once the user
    /// confirms it (`askBeforeOpeningLink`), as upstream's
    /// UntrustedURL.decision confirms any scheme past web, mail and file.
    const confirmed_link_schemes = [_][]const u8{ "ftp", "ssh", "git", "tel", "magnet", "ipfs", "ipns", "gemini", "gopher", "news" };

    /// The `confirmed_link_schemes` entry a checked target opens with, or
    /// null for a web or mail URL or a local path (`C:` names no scheme).
    fn confirmedLinkScheme(checked: []const u8) ?[]const u8 {
        const colon = std.mem.indexOfScalar(u8, checked, ':') orelse return null;
        for (confirmed_link_schemes) |scheme| {
            if (std.ascii.eqlIgnoreCase(checked[0..colon], scheme)) return scheme;
        }
        return null;
    }

    fn prepareWin32FileUri(alloc: Allocator, uri: std.Uri) !?[]const u8 {
        if (uri.user != null or uri.password != null or uri.port != null or
            uri.query != null or uri.fragment != null) return null;

        if (uri.host) |_| {
            var host_buf: [std.Uri.host_name_max]u8 = undefined;
            const host = uri.getHost(&host_buf) catch return null;
            if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
        }

        const decoded_path = try uri.path.toRawMaybeAlloc(alloc);
        const local_path = if (decoded_path.len >= 4 and
            decoded_path[0] == '/' and
            windows_shell.isDriveAbsolutePath(decoded_path[1..]))
            decoded_path[1..]
        else
            decoded_path;
        return try prepareWin32LocalFile(alloc, local_path);
    }

    /// Upstream's UntrustedURL.isUnsafeCharacter set: controls, and the
    /// invisible, bidi and line-separator characters that can disguise part
    /// of a target. Check the raw target, before percent-encoding can hide
    /// them, and a decoded file path. Invalid UTF-8 is refused too.
    fn isSafeLinkText(text: []const u8) bool {
        const view = std.unicode.Utf8View.init(text) catch return false;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| switch (cp) {
            0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x2028...0x2029, 0x2060, 0xFEFF => return false,
            else => {},
        };
        return true;
    }

    fn prepareWin32LocalFile(alloc: Allocator, path: []const u8) !?[]const u8 {
        if (!isSafeLinkText(path) or
            !windows_shell.isDriveAbsolutePath(path) or
            isWin32UncOrDevicePath(path)) return null;

        // Reject NTFS alternate streams as another extension-dispatch bypass.
        if (std.mem.indexOfScalar(u8, path[2..], ':') != null) return null;

        // Win32 strips trailing dots/spaces from every component. Refuse those
        // aliases rather than inspect one filename and dispatch another.
        var components = std.mem.tokenizeAny(u8, path[3..], "/\\");
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) continue;
            if (component[component.len - 1] == '.' or component[component.len - 1] == ' ') return null;
        }
        // Resolve navigation only after rejecting ordinary component aliases.
        // Screen and dispatch the same basename, even for a terminal ".".
        const normalized = try std.fs.path.resolve(alloc, &.{path});
        const extension = handlerExtension(std.fs.path.basename(normalized));
        // Open local reparse targets through a bounded, handle-relative walk;
        // no unchecked ancestor or symlink target may reach a share or device.
        const found = switch (try internal_os.local_path.open(alloc, normalized, .{ .data = extension.len == 0 })) {
            .found => |hit| hit,
            .missing, .refused => return null,
        };
        defer found.deinit(alloc);
        const file = found.file;
        // The exact dispatched path had to exist for that open. Query its
        // handle: reopening the path here could follow a swapped junction.
        const stat = file.stat() catch return null;
        if (stat.kind == .directory) return normalized;
        // The open also takes a name's 8.3 alias (`CMD~1` for `.cmd`,
        // `PAYLOA~1.LIB` for `payload.library-ms`), which the shell namespace
        // types by its long name: screen that name too.
        const long_name = found.storedName(alloc) orelse return null;
        defer alloc.free(long_name);
        const long_extension = handlerExtension(long_name);
        if (extension.len == 0 or long_extension.len == 0) {
            // Fail closed for DOS/PE executable signatures, including renamed
            // binaries; short/empty extensionless documents remain viewable.
            // A file opened without its data (the spelled name has an
            // extension) cannot be read here, and is refused.
            var magic: [2]u8 = undefined;
            const count = file.readAll(&magic) catch return null;
            if (count >= 2 and std.mem.eql(u8, &magic, "MZ")) return null;
        }
        for ([_][]const u8{ extension, long_extension }) |screened| {
            if (screened.len != 0 and try isDangerousHandlerExtension(alloc, screened)) return null;
        }
        return normalized;
    }

    /// Windows associates even a leading-dot basename (".cmd"). Zig's
    /// extension helper treats those as Unix dotfiles with no extension.
    fn handlerExtension(basename: []const u8) []const u8 {
        return if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| basename[dot..] else "";
    }

    fn isDangerousHandlerExtension(alloc: Allocator, extension: []const u8) !bool {
        const extension_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, extension);
        defer alloc.free(extension_w);
        if (sys.AssocIsDangerous(extension_w.ptr) != 0) return true;
        const name = extension[1..];
        for ([_][]const u8{
            "exe",                "com",               "bat",         "cmd",       "ps1", "psm1",    "psd1",         "ps1xml",
            "psc1",               "psc2",              "vbs",         "vbe",       "js",  "jse",     "wsf",          "wsh",
            "hta",                "scr",               "cpl",         "msc",       "msi", "msp",     "mst",          "pif",
            "lnk",                "url",               "application", "appref-ms", "scf", "sct",     "reg",          "inf",
            "jar",                "py",                "pyw",         "rb",        "pl",  "chm",     "rdp",          "library-ms",
            "searchConnector-ms", "diagcab",           "iso",         "img",       "vhd", "vhdx",    "appinstaller", "msix",
            "appx",               "settingcontent-ms", "theme",       "themepack", "xll", "website", "jnlp",         "wsc",
            "search-ms",          "wsb",               "ica",         "wcx",
        }) |blocked| {
            if (std.ascii.eqlIgnoreCase(name, blocked)) return true;
        }
        return false;
    }

    fn isWin32UncOrDevicePath(path: []const u8) bool {
        return internal_os.path.isNetworkOrDevicePath(path);
    }

    fn openConfig(self: *App) !void {
        // Route to the in-app settings window. Users who prefer a text
        // editor can still reach `config.ghostty` via the Advanced
        // section's "Open in default editor" button.
        //
        // Fallback: if the settings window can't be brought up (e.g.
        // headless / service session with no desktop, `CreateWindowExW`
        // refusing window creation, etc.), fall back to the legacy
        // shell-out path so `open_config` never becomes a dead action.
        // Skipping the fallback would regress CI / sandboxed flows
        // that previously worked.
        self.settings_open_trace.note(.settings_open_enter);
        // The window's own steps, timed in memory and written after the
        // outcome so no file write lands inside the work being timed. They
        // are taken only while this runs: the trace covers this route alone.
        const stamps = &self.settings_window.creation_stamps;
        stamps.enabled = self.settings_open_trace.enabled();
        defer {
            self.settings_open_trace.noteCreation(stamps);
            stamps.enabled = false;
        }
        self.settings_window.open() catch |err| {
            self.settings_open_trace.note(.settings_open_error);
            std.log.warn("settings window unavailable (err={}); falling back to editor", .{err});
            try self.openConfigInEditor();
            return;
        };
        self.settings_open_trace.note(.settings_open_ok);
    }

    /// Patch the edited settings into the target file (`persistSettings`:
    /// a temp file beside the real file, then an atomic replace via
    /// `ReplaceFileW`, with `MoveFileExW` when the target is new). Finally
    /// re-load the config from disk and push it through
    /// `CoreApp.updateConfig` so every surface picks up the change on its
    /// next repaint.
    ///
    /// Returns on error; caller (settings window) is responsible for
    /// surfacing the failure. `pending` is borrowed, not consumed —
    /// the caller still owns its arena.
    pub fn settingsSaveAndReload(self: *App, pending: *const configpkg.Config, original: *const configpkg.Config) win32_settings.SaveError!void {
        const alloc = self.core_app.alloc;

        // Target file selection:
        //   1. If the process was started with `--config-file=<path>`
        //      on the CLI, write to THAT file. Writing to the default
        //      `ghostty.conf` when the user explicitly specified a
        //      custom config would either edit the wrong file or let
        //      the CLI-provided config mask the saved value on reload.
        //   2. Otherwise, fall back to the per-user default path
        //      (`config_edit.openPath`), which also handles the
        //      first-run "create the file" case.
        const target_path = try self.settingsTargetPath(alloc);
        defer alloc.free(target_path);

        // Diff pending against `original` (the snapshot from when
        // the settings window opened), NOT against the live
        // `self.config`. Otherwise a concurrent `reload_config` or
        // external file edit that happens while the window is open
        // would cause this save to silently revert the newer values
        // for every GUI-exposed field whose stale draft differs
        // from the refreshed runtime config.
        // Determine which fields the GUI user explicitly edited so
        // we can force-emit them below even when they happen to
        // equal `Config.default()`. Without this, resetting an
        // included `config-file`'s override back to the stock
        // default in Settings would NOT stick — FileFormatter's
        // default-drop would strip the reset line, and the include
        // would re-apply its non-default value on next reload.
        const user_edited = settingsUserEditedKeys(original, pending);
        // The profile editor's changes, by field (`settings_patch`): what the
        // file must hold for `pending`'s profiles, worked out against the
        // layers `original` was read from.
        var profile_arena: std.heap.ArenaAllocator = .init(alloc);
        defer profile_arena.deinit();
        // In the light/dark state the app applies now, which may have
        // changed since Settings opened (`settings_patch.editsForSave`).
        const state = self.core_app.config_conditional_state;
        var profile_edits = settings_patch.editsForSave(profile_arena.allocator(), alloc, &.{&self.config}, state, original, pending, target_path, &settings_reference.samePath) catch |err|
            return settingsProfileEditsFailed(err);
        // Whether another file still names a removed profile decides a
        // tombstone or a deletion, and `self.config` is as of the last reload:
        // a file that gained the profile since, with no reload, would be
        // missed and the profile come back. With profile edits to make, the
        // layers are read from disk again (`settingsProfileEditsFromDisk`).
        if (profile_edits.len != 0) {
            profile_edits = try settingsProfileEditsFromDisk(profile_arena.allocator(), alloc, &self.settings_failure_detail, self.loadConfigAtStartupCwd(), &self.config, state, original, pending, target_path);
        }
        // No-op short-circuit: if the user pressed Save without
        // changing anything, don't touch the filesystem. On a
        // first-run machine with no existing config file, the write
        // would otherwise create a zero-byte file that then fires
        // `error.FileIsEmpty` warnings on every subsequent load.
        // On an existing file, skipping also avoids an unnecessary
        // mtime bump.
        if (user_edited.count() == 0 and profile_edits.len == 0) return;

        self.settings_failure_detail.clear(alloc);
        try persistSettings(alloc, target_path, pending, user_edited, profile_edits, &self.settings_failure_detail);

        // Saving can repair the config on disk, but recovery applies it only
        // after restart, as the safe-mode banner promises.
        if (self.safe_mode) return;

        // Mirror the `.reload_config` hard-reload path: re-read from disk and
        // push through CoreApp so every surface's next frame picks up the
        // new values.
        var reloaded = self.loadConfigAtStartupCwd() catch return error.ReloadFailed;
        defer reloaded.deinit();

        // Post-save validation: detect fields the user GUI-edited
        // whose persisted value gets MASKED by a later layer on
        // reload (included `config-file` + subsequent CLI
        // `--config-file` flag + `--config-default-files=false`).
        // The persisted-on-disk value is correct, but the effective
        // runtime value doesn't match. Track whether ANY field is
        // masked so we can return a distinct error variant; the
        // settings-window caller surfaces this differently from a
        // generic write failure. The status line names the fields.
        self.settings_masked_keys.clear(alloc);
        var masked_buf: [settings_masked_keys_capacity]u8 = undefined;
        // The keys, then each profile field the reload does not hold, by
        // name only (`settings_patch.writeEditName`).
        var masked_text: std.Io.Writer.Allocating = .init(alloc);
        defer masked_text.deinit();
        masked_text.writer.writeAll(settingsMaskedKeyNames(&masked_buf, user_edited, pending, &reloaded)) catch return error.OutOfMemory;
        // The profile fields as `updateConfig` will apply them: a theme can
        // define a profile in one light/dark state only.
        var reloaded_applied: ?configpkg.Config = if (profile_edits.len == 0) null else reloaded.changeConditionalState(self.core_app.config_conditional_state) catch |err| applied: {
            log.warn("settings save: could not apply the light/dark state to the reload for its check err={}", .{err});
            break :applied null;
        };
        defer if (reloaded_applied) |*value| value.deinit();
        // A file the reload could not read whole: what it missed is no
        // override, and the save says that instead, naming the file.
        const report = settings_patch.reloadReport(&masked_text.writer, profile_edits, if (reloaded_applied) |*value| value else &reloaded, masked_text.written().len > 0) catch return error.OutOfMemory;
        switch (report) {
            .unread => |unread| {
                const text = unread.describe(alloc) catch return error.OutOfMemory;
                defer alloc.free(text);
                self.settings_failure_detail.set(alloc, text);
                log.warn("settings save: saved, but the reload could not read a config file whole, so the saved values may not all be in effect", .{});
                self.core_app.updateConfig(self, &reloaded) catch return error.ReloadFailed;
                _ = self.reportRecordedConfigProblems();
                return error.SavedButUnread;
            },
            .held, .masked => {},
        }
        const masked = masked_text.written();
        if (masked.len > 0) {
            std.log.warn("settings save: saved but masked by a later config-file layer: {s}", .{masked});
            self.settings_masked_keys.set(alloc, masked);
        }

        self.core_app.updateConfig(self, &reloaded) catch return error.ReloadFailed;
        // The reload read the file again, so what is wrong in it is news.
        _ = self.reportRecordedConfigProblems();
        if (masked.len > 0) return error.SavedButMasked;
    }

    /// The profile edits a save makes, worked out against the config layers
    /// read again from disk (`fresh`, the read's result, owned here) and
    /// against `held`, the config as last read, in `state`
    /// (`settings_patch.editsForSave`): a removal keeps its line when either
    /// shows another layer naming it. The fresh read is held to the rule the
    /// disk check before an ordinary save holds it to (`settingsDiskVerdict`):
    /// an included or theme file that is there and will not open, or does not
    /// decode, stops the save. So does a file a reading could not open or
    /// read whole (`settings_patch.unreadConfigFile`: an include that would
    /// not open, or one or a theme whose read failed partway through), judged
    /// on the reading in `state`, since switching to it reads the theme
    /// again; and a read that fails. Nothing is written then, and `detail`
    /// names the file.
    fn settingsProfileEditsFromDisk(
        arena: Allocator,
        alloc: Allocator,
        detail: *win32_settings.FailureDetail,
        fresh: anyerror!configpkg.Config,
        held: *const configpkg.Config,
        state: configpkg.ConditionalState,
        original: *const configpkg.Config,
        pending: *const configpkg.Config,
        target_path: []const u8,
    ) win32_settings.SaveError![]settings_patch.Edit {
        var disk = fresh catch |err| {
            log.warn("settings save: could not read the config files again for the profile edits err={}", .{err});
            return error.ReloadFailed;
        };
        defer disk.deinit();
        detail.clear(alloc);
        _ = try settingsDiskVerdict(alloc, detail, original, pending, &disk, state, .initEmpty());
        // Each reading in the app's state first: switching it reads the
        // selected theme again, and that read is what the removal is decided
        // from, so it is the one whose problems count. A reading already in
        // that state is used as it is.
        var disk_now = disk.changeConditionalState(state) catch |err| return settingsProfileEditsFailed(err);
        defer if (disk_now) |*value| value.deinit();
        var held_now = held.changeConditionalState(state) catch |err| return settingsProfileEditsFailed(err);
        defer if (held_now) |*value| value.deinit();
        const readings = [_]*const configpkg.Config{
            if (disk_now) |*value| value else &disk,
            if (held_now) |*value| value else held,
        };
        // The fresh read, and the held config if it was read again here.
        for (readings[0..if (held_now != null) 2 else 1]) |reading| {
            if (settings_patch.unreadConfigFile(reading)) |unread| {
                const text = unread.describe(alloc) catch return error.OutOfMemory;
                defer alloc.free(text);
                detail.set(alloc, text);
                return error.FileUnopenable;
            }
        }
        return settings_patch.editsForSave(arena, alloc, &readings, state, original, pending, target_path, &settings_reference.samePath) catch |err|
            settingsProfileEditsFailed(err);
    }

    /// The profile edits could not be worked out: no memory, or the layers
    /// could not be put in the app's light/dark state, which would decide a
    /// removal blind. Nothing is saved.
    fn settingsProfileEditsFailed(err: anyerror) win32_settings.SaveError {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        log.warn("settings save: the profile edits could not be worked out err={}", .{err});
        return error.ReloadFailed;
    }

    fn settingsTargetPath(self: *App, alloc: Allocator) win32_settings.SaveError![]const u8 {
        // Use the startup-time resolved override — never call
        // `cliConfigFileOverride` from here, because cwd may have
        // been reset by `sanitizeCurrentDirectory` and a relative
        // CLI path would resolve to the wrong absolute file.
        if (self.cli_config_override_path) |cli_path| return try alloc.dupe(u8, cli_path);
        return config_edit.openPath(alloc) catch error.PathResolveFailed;
    }

    /// The file a Save writes (`settingsTargetPath`), to show in Settings:
    /// looking must not create the file or its folder. Owned.
    pub fn settingsTargetPathForDisplay(self: *App, alloc: Allocator) ![]const u8 {
        if (self.cli_config_override_path) |cli_path| return try alloc.dupe(u8, cli_path);
        return config_file_load.preferredDefaultFilePath(alloc);
    }

    /// `Config.load` as the process started.
    ///
    /// `loadCliArgs` resolves relative `--config-file` argv entries
    /// via realpath-against-cwd; after `sanitizeCurrentDirectory()`
    /// ran, cwd is typically `%USERPROFILE%`, and a user who
    /// launched with `--config-file=custom.conf` would see the
    /// reload pick up `%USERPROFILE%\custom.conf` instead of the
    /// file we just wrote. Save lands correctly, but the live
    /// config would immediately diverge from disk — "my edits
    /// didn't take effect until restart" is exactly this bug.
    /// The sanitized cwd is put back afterwards: leaking a cwd change
    /// into the rest of process lifetime would change where other code
    /// resolves relative paths — for example, a subsequent surface spawn
    /// could inherit the wrong working directory.
    ///
    /// The restore is a `defer` (NOT an inline step after the load) so BOTH
    /// the happy path AND the error path run it. Earlier code had
    /// `Config.load catch return ...` followed by an inline restore; the
    /// return short-circuited the restore, leaving the process pinned to
    /// `startup_cwd` whenever a reload hit a broken config file.
    fn loadConfigAtStartupCwd(self: *App) !configpkg.Config {
        var startup_cwd = self.enterStartupCwd();
        defer startup_cwd.restore();
        return configpkg.Config.load(self.core_app.alloc);
    }

    /// The process cwd moved to `startup_cwd` until `restore` puts the
    /// sanitized cwd back, so a `Config.load` in between resolves relative
    /// `--config-file` entries as the launch did. Shared by
    /// `loadConfigAtStartupCwd` (Settings saves) and the `reload_config`
    /// action, which keeps it until the reloaded config is applied.
    ///
    /// A startup directory that no longer exists is not created again: the
    /// files under it went with it, so an empty directory in its place
    /// brings none of them back. The load then runs in the current
    /// directory, and the warning says the move failed.
    const StartupCwd = struct {
        alloc: Allocator,
        /// The cwd to go back to; null when it could not be read.
        before: ?[]u8,
        moved: bool,

        fn restore(self: *StartupCwd) void {
            defer if (self.before) |path| self.alloc.free(path);
            if (!self.moved) return;
            const cwd = self.before orelse return;
            std.process.changeCurDir(cwd) catch |err| {
                std.log.warn("config load: couldn't restore sanitized cwd path={f} err={}", .{ internal_os.redact.bytes(cwd), err });
            };
        }
    };

    fn enterStartupCwd(self: *const App) StartupCwd {
        var scope: StartupCwd = .{
            .alloc = self.core_app.alloc,
            .before = std.process.getCwdAlloc(self.core_app.alloc) catch null,
            .moved = false,
        };
        if (self.startup_cwd) |cwd| {
            if (std.process.changeCurDir(cwd)) |_| {
                scope.moved = true;
            } else |err| {
                std.log.warn("config load: couldn't restore startup cwd path={f} err={}", .{ internal_os.redact.bytes(cwd), err });
            }
        }
        return scope;
    }

    test "StartupCwd resolves a relative config-file in the startup directory and never creates a missing one" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;

        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();

        const alloc = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.makeDir("launch");
        try tmp.dir.makeDir("sanitized");
        try tmp.dir.writeFile(.{ .sub_path = "launch/custom.conf", .data = "font-size = 17\n" });
        const launch = try tmp.dir.realpathAlloc(alloc, "launch");
        defer alloc.free(launch);
        const sanitized = try tmp.dir.realpathAlloc(alloc, "sanitized");
        defer alloc.free(sanitized);
        const missing = try std.fs.path.join(alloc, &.{ launch, "deleted" });
        defer alloc.free(missing);

        // The test borrows the process cwd. It goes back before the
        // temporary directory, which Windows cannot delete while it is the
        // cwd, is cleaned up.
        const original_cwd = try std.process.getCwdAlloc(alloc);
        defer alloc.free(original_cwd);
        defer std.process.changeCurDir(original_cwd) catch |err| {
            std.debug.panic("could not restore the test's cwd err={}", .{err});
        };
        try std.process.changeCurDir(sanitized);
        defer app.startup_cwd = null;

        const Cases = struct {
            /// What `Config.load` does with `--config-file=custom.conf` on the
            /// command line, run inside the scope: `loadCliArgs` parses the
            /// argument, then expands it against `realpath(".")` (its private
            /// `expandPaths` calls the same `RepeatablePath.expand`), and
            /// `loadRecursiveFiles` reads the file.
            fn loadRelativeConfigFile(test_app: *App, load_alloc: Allocator, expected_cwd: []const u8) !configpkg.Config {
                var startup_cwd = test_app.enterStartupCwd();
                defer startup_cwd.restore();
                var config = try configpkg.Config.default(load_alloc);
                errdefer config.deinit();
                var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{
                    .iterator = cli_args.sliceIterator(&.{"--config-file=custom.conf"}),
                };
                try config.loadIter(load_alloc, &args);
                var base_buf: [std.fs.max_path_bytes]u8 = undefined;
                const base = try std.fs.cwd().realpath(".", &base_buf);
                try std.testing.expectEqualStrings(expected_cwd, base);
                try config.@"config-file".expand(config._arena.?.allocator(), base, &config._diagnostics);
                try config.loadRecursiveFiles(load_alloc);
                try config.finalize();
                return config;
            }

            /// An error injected inside the scope, as a load that fails.
            fn failInside(test_app: *App) !void {
                var startup_cwd = test_app.enterStartupCwd();
                defer startup_cwd.restore();
                return error.TestInjectedLoadFailure;
            }
        };

        // A relative config-file resolves in the startup directory, and the
        // sanitized cwd is back afterwards.
        app.startup_cwd = launch;
        {
            var config = try Cases.loadRelativeConfigFile(&app, alloc, launch);
            defer config.deinit();
            try std.testing.expectEqual(@as(f32, 17), config.@"font-size");
        }
        const after = try std.process.getCwdAlloc(alloc);
        defer alloc.free(after);
        try std.testing.expectEqualStrings(sanitized, after);

        // A startup directory that is gone stays gone: the scope stays in the
        // current directory, so the relative file is not found there, and the
        // current directory is as it was afterwards.
        app.startup_cwd = missing;
        {
            var config = try Cases.loadRelativeConfigFile(&app, alloc, sanitized);
            defer config.deinit();
            try std.testing.expectEqual(@as(f32, 12), config.@"font-size");
        }
        try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(missing, .{}));
        const after_missing = try std.process.getCwdAlloc(alloc);
        defer alloc.free(after_missing);
        try std.testing.expectEqualStrings(sanitized, after_missing);

        // A failure inside the scope still puts the sanitized cwd back.
        app.startup_cwd = launch;
        try std.testing.expectError(error.TestInjectedLoadFailure, Cases.failInside(&app));
        const after_failure = try std.process.getCwdAlloc(alloc);
        defer alloc.free(after_failure);
        try std.testing.expectEqualStrings(sanitized, after_failure);
    }

    /// Before a Settings save: has the config file been edited since the
    /// window last read it, in a setting that is also being edited there? The
    /// window only learns of an edit through a reload, so a save without one
    /// wrote its value over the other: the file's line was replaced and the
    /// edit was gone with no prompt.
    ///
    /// The file is read exactly as a reload reads it, and judged by the
    /// effective values, which is how the window itself decides what is a
    /// conflict (`externalConfigChanged`); an edit to an included file counts,
    /// an edit to another setting does not. When there is one, the file is
    /// applied as a reload applies it, which hands the window the conflict to
    /// resolve (Keep mine or Use disk); the window then stops the save. If the
    /// file cannot be read or applied, nothing is saved either: the save would
    /// write blind.
    ///
    /// `apply` is false for a caller with no conflict prompt of its own (the
    /// palette's theme pick): a conflict then comes back as `DiskChanged` and
    /// the file is not applied, since swapping the running config under a
    /// pick the person is making would be a surprise of its own.
    pub fn settingsReconcileDisk(
        self: *App,
        pending: *const configpkg.Config,
        original: *const configpkg.Config,
        apply: bool,
    ) win32_settings.SaveError!void {
        // Recovery may repair the file, but must never apply its settings live,
        // including through conflict reconciliation before the save.
        if (self.safe_mode) return;
        const alloc = self.core_app.alloc;
        self.settings_failure_detail.clear(alloc);
        const user_edited = settingsUserEditedKeys(original, pending);
        if (user_edited.count() == 0) return;
        const target_path = try self.settingsTargetPath(alloc);
        defer alloc.free(target_path);
        try settingsFileOpenable(alloc, &self.settings_failure_detail, "the config file", target_path);
        var disk = self.loadConfigAtStartupCwd() catch |err| {
            log.warn("settings save: could not read the config file to check it for edits err={}", .{err});
            return error.ReloadFailed;
        };
        defer disk.deinit();
        if (!try settingsDiskVerdict(alloc, &self.settings_failure_detail, original, pending, &disk, self.core_app.config_conditional_state, user_edited)) return;
        if (!apply) return error.DiskChanged;
        log.info("settings save: the config file changed on disk under an edited setting; offering the choice", .{});
        self.core_app.updateConfig(self, &disk) catch |err| {
            log.warn("settings save: applying the changed config file failed err={}", .{err});
            return error.ReloadFailed;
        };
    }

    /// Open the configuration as text. Kept alive for Advanced pane
    /// consumption and for users running `open_config` on CI / headless
    /// runs where the settings window is unreachable.
    pub fn openConfigInEditor(self: *App) !void {
        errdefer if (self.settings_window.hwnd == null) {
            _ = self.showHostBanner(.app, .err, @import("../../os/windows_text_editor.zig").failure_message) catch false;
        };
        // If the process was launched with `--config-file=<path>`,
        // that file is the one we Save to from the Settings UI and
        // the one that masks the per-user default on reload. Opening
        // the per-user default from the escape-hatch would let the
        // user edit a file they'd then see no effect from (the CLI
        // override still masks it), so route to the same file the
        // Save path targets.
        const path = blk: {
            if (self.cli_config_override_path) |cli_path|
                break :blk try self.core_app.alloc.dupe(u8, cli_path);
            break :blk try config_edit.openPath(self.core_app.alloc);
        };
        defer self.core_app.alloc.free(path);
        // Keep the existing local-file gates and repeat them at dispatch.
        // ShellExecuteExW can pump window messages, so the editor, like links,
        // must run from the message loop, outside the Settings callback.
        var arena = std.heap.ArenaAllocator.init(self.core_app.alloc);
        defer arena.deinit();
        const checked = try prepareWin32LocalFile(arena.allocator(), path) orelse return error.OpenUrlRejected;
        const owned = try self.core_app.alloc.dupe(u8, checked);
        errdefer self.core_app.alloc.free(owned);
        try self.deferShellRequest(.{ .text_editor = .{
            .path = owned,
            .from_settings = self.settings_window.hwnd != null,
        } });
    }

    test "settings a profile save's fresh read stops the save when a file was not read whole, and decides from it and the held config otherwise" {
        const alloc = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "profile-command = py: python.exe\n" });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        var held = try configpkg.Config.default(alloc);
        defer held.deinit();
        try held.loadFile(alloc, path);
        var pending = try held.clone(alloc);
        defer pending.deinit();
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
        var detail: win32_settings.FailureDetail = .{};
        defer detail.clear(alloc);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();

        // A file whose read fails partway through: the save stops, naming it.
        {
            var fresh = try configpkg.Config.default(alloc);
            errdefer fresh.deinit();
            var buf: [16]u8 = undefined;
            var failing = @import("../../cli/args.zig").TestFailingReader.init("profile-command = py: python.exe\nprofile-na", &buf);
            try fresh.loadReader(alloc, &failing.interface, path);
            try std.testing.expectError(error.FileUnopenable, App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, .{}, &held, &pending, path));
            const expected = try std.fmt.allocPrint(alloc, "the included file {s}", .{path});
            defer alloc.free(expected);
            try std.testing.expect(std.mem.eql(u8, expected, detail.text.?));
        }
        // A read that fails: the save stops.
        try std.testing.expectError(error.ReloadFailed, App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, error.AccessDenied, &held, .{}, &held, &pending, path));
        // A whole read: the edits, and nothing else names `py`, so its line goes.
        {
            var fresh = try configpkg.Config.default(alloc);
            errdefer fresh.deinit();
            try fresh.loadFile(alloc, path);
            const edits = try App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, .{}, &held, &pending, path);
            try std.testing.expectEqual(@as(usize, 4), edits.len);
            try std.testing.expect(edits[0].field == .command and edits[0].op == .delete);
        }
    }

    test "settings a profile save stops when the theme of the app's light/dark state cannot be read whole as that state is applied" {
        const alloc = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, dark });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        const load = struct {
            fn config(a: Allocator, file: []const u8) !configpkg.Config {
                var cfg = try configpkg.Config.default(a);
                errdefer cfg.deinit();
                try cfg.loadFile(a, file);
                try cfg.loadRecursiveFiles(a);
                try cfg.finalize();
                return cfg;
            }
        }.config;
        // The config as last read, in the dark state the app is in, from
        // before the dark theme defined `py`; the draft removes `py`.
        var loaded = try load(alloc, path);
        defer loaded.deinit();
        var held = (try loaded.changeConditionalState(.{ .theme = .dark })).?;
        defer held.deinit();
        var pending = try held.clone(alloc);
        defer pending.deinit();
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
        // The dark theme defines `py` now.
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "profile-command = py: python.exe -X dark\n" });
        const before = try tmp.dir.readFileAlloc(alloc, "config", 1 << 16);
        defer alloc.free(before);
        var detail: win32_settings.FailureDetail = .{};
        defer detail.clear(alloc);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const dark_state: configpkg.ConditionalState = .{ .theme = .dark };

        // Another program locks the dark theme's bytes: it opens, which the
        // disk check sees, and its read fails, which only applying the dark
        // state reads. The theme loader opens its file itself, so a reader
        // cannot be put in its place; std's `.lock` is the byte-range lock
        // that does this.
        {
            var lock = try tmp.dir.openFile("dark", .{ .mode = .read_write, .lock = .exclusive });
            defer lock.close();
            const fresh = try load(alloc, path);
            try std.testing.expectError(error.FileUnopenable, App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, dark_state, &held, &pending, path));
            const expected = try std.fmt.allocPrint(alloc, "the theme file {s}", .{dark});
            defer alloc.free(expected);
            try std.testing.expect(std.mem.eql(u8, expected, detail.text.?));
        }
        // Nothing was written.
        const after = try tmp.dir.readFileAlloc(alloc, "config", 1 << 16);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, before, after));
        // Read whole: the dark theme's `py` keeps the tombstone.
        const fresh = try load(alloc, path);
        const edits = try App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, dark_state, &held, &pending, path);
        for (edits) |e| if (e.field == .command) try std.testing.expect(e.op == .unset);
    }

    test "SET editor request stays deferred, rechecks safety and reports host failure" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var surface: Surface = undefined;
        var session: TestSession = .{};
        try session.init(.{
            .core_app = &core_app,
            .app = &app,
            .hosts = &.{.{ .storage = &host, .register = true, .next_tab_id = 2 }},
            .surfaces = &.{.{ .storage = &surface, .host = &host, .register = true }},
            .tabs = &.{.{ .host = &host, .surface = &surface, .id = 1 }},
        });
        defer session.deinit();
        const Hook = struct {
            var calls: usize = 0;
            var fail = false;
            var expected: []const u8 = "";
            fn open(_: *App, path: []const u8) !void {
                calls += 1;
                try std.testing.expectEqualStrings(expected, path);
                if (fail) return error.OpenConfigFailed;
            }
        };
        Hook.calls = 0;
        Hook.fail = false;
        app.test_open_target = &Hook.open;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" });
        const path = try tmp.dir.realpathAlloc(std.testing.allocator, "config");
        defer std.testing.allocator.free(path);
        app.cli_config_override_path = path;
        defer app.cli_config_override_path = null;
        Hook.expected = path;

        try app.openConfigInEditor();
        try std.testing.expectEqual(@as(usize, 0), Hook.calls);
        try std.testing.expectEqual(@as(usize, 1), app.deferred_opens.items.len);
        try std.testing.expect(app.deferred_opens.items[0] == .text_editor);
        try std.testing.expect(app.runDeferredOpens());
        try std.testing.expectEqual(@as(usize, 1), Hook.calls);

        Hook.fail = true;
        try app.openConfigInEditor();
        try std.testing.expect(app.runDeferredOpens());
        try std.testing.expectEqual(@as(usize, 2), Hook.calls);
        try std.testing.expectEqual(HostBannerKind.err, host.banner_kind);
        try std.testing.expect(std.mem.indexOf(u8, host.banner_text.?, "text editor") != null);
        try std.testing.expectEqual(@as(usize, 0), app.deferred_opens.items.len);

        // A queued document replaced by a PE must fail the same gate used by
        // the old URL path, before even reaching the test shell hook.
        try app.openConfigInEditor();
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "MZ\x00\x00" });
        try std.testing.expect(app.runDeferredOpens());
        try std.testing.expectEqual(@as(usize, 2), Hook.calls);
        try std.testing.expectError(error.OpenUrlRejected, app.openConfigInEditor());
    }

    test "SET deferred editor failure reaches Settings live status on a hidden desktop" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnHiddenDesktop(struct {
            fn body() !void {
                var core_app: CoreApp = undefined;
                var app: App = undefined;
                var session: TestSession = .{};
                try session.init(.{ .core_app = &core_app, .app = &app });
                defer session.deinit();
                app.initComApartment();
                if (!app.com_initialized) return error.SkipZigTest;
                defer sys.OleUninitialize();
                // This test has no app message loop to drain COM teardown.
                app.settings_window.handle.deferUiaDisconnect = null;
                const settings_class = comptime std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.settings");
                const viewport_class = comptime std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.settings.viewport");
                defer {
                    app.settings_window.deinit();
                    // Settings fixtures on later private desktops register
                    // their own classes with this same module instance.
                    _ = sys.UnregisterClassW(settings_class, app.settings_window.handle.hinstance);
                    _ = sys.UnregisterClassW(viewport_class, app.settings_window.handle.hinstance);
                }
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                try tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "font-size = 12\n" });
                const path = try tmp.dir.realpathAlloc(std.testing.allocator, "config.ghostty");
                defer std.testing.allocator.free(path);
                app.cli_config_override_path = path;
                defer app.cli_config_override_path = null;
                const Hook = struct {
                    var calls: usize = 0;
                    fn fail(_: *App, _: []const u8) !void {
                        calls += 1;
                        return error.OpenConfigFailed;
                    }
                };
                Hook.calls = 0;
                app.test_open_target = &Hook.fail;
                try app.settings_window.open();
                win32_uia.events.testing_live_regions = 0;
                // Exercise the real callback, queue, dispatch and status setter.
                settingsOpenInEditorThunk(&app);
                try std.testing.expectEqual(@as(usize, 0), Hook.calls);
                try std.testing.expect(app.runDeferredOpens());
                try std.testing.expectEqual(@as(usize, 1), Hook.calls);
                try std.testing.expectEqual(@as(usize, 1), win32_uia.events.testing_live_regions);
                var text: [256]u16 = undefined;
                const len = sys.GetWindowTextW(app.settings_window.text_status.?, &text, text.len);
                try std.testing.expect(len > 0);
                const actual = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, text[0..@intCast(len)]);
                defer std.testing.allocator.free(actual);
                try std.testing.expectEqualStrings(@import("../../os/windows_text_editor.zig").failure_message, actual);
            }
        }.body);
    }

    test "SET open_config writes creation steps only for the window it created" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        try runOnHiddenDesktop(struct {
            fn body() !void {
                var core_app: CoreApp = undefined;
                var app: App = undefined;
                var session: TestSession = .{};
                try session.init(.{ .core_app = &core_app, .app = &app });
                defer session.deinit();
                app.initComApartment();
                if (!app.com_initialized) return error.SkipZigTest;
                defer sys.OleUninitialize();
                app.settings_window.handle.deferUiaDisconnect = null;
                const settings_class = comptime std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.settings");
                const viewport_class = comptime std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.settings.viewport");
                defer {
                    app.settings_window.deinit();
                    _ = sys.UnregisterClassW(settings_class, app.settings_window.handle.hinstance);
                    _ = sys.UnregisterClassW(viewport_class, app.settings_window.handle.hinstance);
                }
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                try tmp.dir.writeFile(.{ .sub_path = "config.ghostty", .data = "font-size = 12\n" });
                const path = try tmp.dir.realpathAlloc(std.testing.allocator, "config.ghostty");
                defer std.testing.allocator.free(path);
                app.cli_config_override_path = path;
                defer app.cli_config_override_path = null;
                const Hook = struct {
                    var calls: usize = 0;
                    fn open(_: *App, _: []const u8) !void {
                        calls += 1;
                    }
                };
                Hook.calls = 0;
                app.test_open_target = &Hook.open;
                const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
                defer std.testing.allocator.free(dir);
                const trace_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "settings-open.jsonl" });
                defer std.testing.allocator.free(trace_path);
                app.settings_open_trace = .{ .file = try std.fs.createFileAbsolute(trace_path, .{ .exclusive = true }) };
                defer app.settings_open_trace.deinit();

                // open_config creates the window and writes its steps.
                try app.openConfig();
                try std.testing.expect(!app.settings_window.creation_stamps.enabled);
                _ = sys.DestroyWindow(app.settings_window.hwnd.?);
                // The palette's Settings rows create it without the trace.
                try app.settings_window.openField(.font_size);
                try std.testing.expectEqual(@as(usize, 0), app.settings_window.creation_stamps.len);
                // open_config only raises it now: no creation steps follow.
                try app.openConfig();
                try std.testing.expectEqual(@as(usize, 0), Hook.calls);

                const data = try tmp.dir.readFileAlloc(std.testing.allocator, "settings-open.jsonl", 64 * 1024);
                defer std.testing.allocator.free(data);
                try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, data, "\"stage\":\"settings_open_ok\""));
                try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, data, "\"stage\":\"create_begin\""));
                const raise = std.mem.lastIndexOf(u8, data, "\"stage\":\"settings_open_enter\"").?;
                try std.testing.expect(std.mem.indexOf(u8, data[raise..], "\"stage\":\"create_") == null);
            }
        }.body);
    }

    /// Ring the bell as `bell-features` says; see `win32_bell`. A surface
    /// target uses its own configuration, `.app` the app's, and only a
    /// surface target marks a terminal with the title glyph.
    fn ringBell(self: *App, target: apprt.Target) void {
        const surface = self.registry.findSurfaceForTarget(target);
        const alerted: ?*Surface = switch (target) {
            .surface => surface,
            .app => null,
        };
        const features: configpkg.Config.BellFeatures, const audio_path: ?configpkg.Path, const volume: f64 =
            if (alerted) |s| .{
                s.core().config.bell_features,
                s.core().config.bell_audio_path,
                s.core().config.bell_audio_volume,
            } else .{
                self.config.@"bell-features",
                self.config.@"bell-audio-path",
                self.config.@"bell-audio-volume",
            };

        const hwnd = if (surface) |s| s.windowHwnd() else null;
        const window_active = if (hwnd) |h|
            sys.GetForegroundWindow() == h and sys.IsIconic(h) == 0
        else
            false;
        const bell = win32_bell.plan(features, audio_path != null, .{
            .window_active = window_active,
            .window_visible = if (hwnd) |h| sys.IsWindowVisible(h) != 0 else false,
            .in_view = if (alerted) |s| window_active and s.host_active and s.window_focused else false,
        });

        if (bell.system) _ = sys.MessageBeep(c.MB_ICONINFORMATION);
        if (bell.audio) if (audio_path) |path| win32_bell.playFile(switch (path) {
            inline else => |value| value,
        }, volume);
        if (bell.flash) if (hwnd) |h| win32_bell.flashTaskbar(h);
        if (bell.announce) if (surface) |s| s.announceBell();
        if (bell.glyph) if (alerted) |s| s.setBellRinging(true);
    }

    test "app bell announces through its primary terminal without marking it" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
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

        const accessibility = try win32_terminal_accessibility.TerminalAccessibilitySession.create(
            std.testing.allocator,
            .{
                .ctx = &surface,
                .hwnd = terminalAccessibilityHwnd,
                .name = terminalAccessibilityName,
                .focused = terminalAccessibilityFocused,
                .capture = terminalAccessibilityCapture,
                .defer_provider_release = terminalAccessibilityDeferProviderRelease,
            },
            0,
            0,
        );
        defer accessibility.deinit();
        surface.terminal_accessibility = accessibility;
        defer surface.terminal_accessibility = null;

        // No HWND or CoreSurface is needed: app bells use app configuration,
        // and the test event sink counts notifications without invoking UIA.
        app.config.@"bell-features" = .{ .attention = false, .title = true };
        win32_uia.events.testing_bells = 0;
        app.ringBell(.app);
        try std.testing.expectEqual(@as(usize, 0), win32_uia.events.testing_bells);

        const provider = try win32_uia.TerminalProvider.create(std.testing.allocator, @ptrFromInt(0x1), .{
            .ctx = &surface,
            .name = terminalAccessibilityName,
            .focused = terminalAccessibilityFocused,
            .value = struct {
                fn value(_: *anyopaque, _: Allocator) ![]u8 {
                    unreachable; // Bell dispatch must not query terminal text.
                }
            }.value,
        });
        defer _ = win32_uia.TerminalProvider.Release(&provider.base);
        accessibility.provider = provider;
        defer accessibility.provider = null;
        app.ringBell(.app);
        try std.testing.expectEqual(@as(usize, 1), win32_uia.events.testing_bells);
        try std.testing.expect(!surface.bell_ringing);

        app.config.@"bell-features" = .{ .attention = false, .title = false };
        app.ringBell(.app);
        try std.testing.expectEqual(@as(usize, 1), win32_uia.events.testing_bells);
        try std.testing.expect(!surface.bell_ringing);
    }

    /// Show a toast; when none can be shown, a banner in the target's
    /// window; failing that, a log line. `sender_title` is the title the
    /// notification arrived with, which the banner uses: a toast titled by
    /// its tab names that tab in its attribution line already. Returns
    /// whether Windows took the toast.
    fn showToast(
        self: *App,
        target: apprt.Target,
        request: ToastRequest,
        sender_title: []const u8,
    ) !bool {
        var shown = request;
        if (shown.title.len == 0) shown.title = "noctty";

        // Primary path: an Action Center toast. It persists in Action
        // Center history and surfaces system-level badging. On success we
        // SKIP the in-app banner: showing both would double-notify on the
        // same event. A show error (notifications turned off for noctty or
        // for the user, the runtime unavailable, XML rejected) falls back
        // to the banner so the user still gets feedback. Under Focus Assist
        // (Do not disturb) Windows may instead accept the toast and file it
        // in Action Center without a popup, and then no banner appears;
        // which of the two it does has not been measured for noctty.
        if (self.toast_sink) |sink| {
            if (sink.show(sink.ctx, shown)) |_| {
                return true;
            } else |err| {
                // test/windows/interactive-win11-command-finish.ps1 matches
                // this line's opening words; keep them.
                std.log.warn("winrt toast show failed err={}; falling back to banner", .{err});
            }
        }

        var message: std.Io.Writer.Allocating = .init(self.core_app.alloc);
        defer message.deinit();
        composeToastFallback(&message.writer, sender_title, request.body, request.attribution) catch
            return error.OutOfMemory;
        if (try self.showHostBanner(target, .info, message.written())) return false;
        // Final local fallback: pass the composed message as the body so
        // notifications with an empty `body` (e.g. settings-save success,
        // where title alone carries the signal) still render something
        // readable.
        const caption = if (toastFallbackTitled(sender_title)) sender_title else "noctty";
        try showInfoMessage(target, caption, message.written());
        return false;
    }

    fn toastFallbackTitled(title: []const u8) bool {
        return title.len > 0 and !std.mem.eql(u8, title, "noctty");
    }

    /// The banner says what the toast would have: `<title>: <body>`, the
    /// body alone when the title is empty or just "noctty", and the tab
    /// the toast came from after a dash.
    fn composeToastFallback(
        writer: *std.Io.Writer,
        title: []const u8,
        body: []const u8,
        attribution: ?[]const u8,
    ) std.Io.Writer.Error!void {
        const titled = toastFallbackTitled(title);
        if (titled) try writer.writeAll(title);
        if (body.len > 0) {
            if (titled) try writer.writeAll(": ");
            try writer.writeAll(body);
        }
        if (attribution) |line| try writer.print(" \u{2014} {s}", .{line});
    }

    /// A notification a program asked for (OSC 9, OSC 777), one noctty
    /// shows about a pane (the core's clipboard-copy notices, titled
    /// "noctty"), or one noctty shows for itself (an `.app` target, such as
    /// a config reload). One from a pane names its tab and focuses the pane
    /// when clicked. The core sends both kinds a pane can cause the same
    /// way, so they are not told apart; by the title they could not be, as
    /// a program can send an OSC 777 titled "noctty" too.
    pub fn showDesktopNotification(
        self: *App,
        target: apprt.Target,
        title: []const u8,
        body: []const u8,
    ) !void {
        switch (target) {
            .app => {},
            .surface => if (self.registry.findSurfaceForTarget(target)) |surface| {
                return self.showSurfaceToast(surface, title, body);
            },
        }
        _ = try self.showToast(target, .{ .title = title, .body = body }, title);
    }

    /// The most of a tab's title a toast shows, in bytes, before the
    /// ellipsis.
    const toast_tab_title_max = 64;

    /// Show a toast from `surface` that says which tab it came from and
    /// focuses `surface` when clicked. An untitled one (OSC 9 has no title)
    /// is titled by its tab, as Windows Terminal does. Showing a toast is a
    /// cross-process COM call that can pump messages: callers must not
    /// touch `surface` after it.
    fn showSurfaceToast(
        self: *App,
        surface: *Surface,
        title: []const u8,
        body: []const u8,
    ) !void {
        var title_buf: [toast_tab_title_max + "\u{2026}".len]u8 = undefined;
        var tab_title: std.Io.Writer = .fixed(&title_buf);
        var context_buf: [160]u8 = undefined;
        var context: std.Io.Writer = .fixed(&context_buf);
        const attribution: ?[]const u8 = if (Host.findTabForSurface(surface)) |found| context: {
            const name = toastTabName(found.tab, surface);
            try self.writeToastContext(&context, found.host, found.index, name);
            if (title.len == 0) {
                try win32_program_status.writeSanitized(&tab_title, name, toast_tab_title_max);
            }
            break :context context.buffered();
        } else null;

        const launch = try buildToastLaunchForSurface(self.core_app.alloc, surface);
        defer self.core_app.alloc.free(launch);

        // Tagged by pane and grouped by process: a newer toast from this
        // pane replaces its older one in Action Center, and seeing the tab,
        // closing the pane or exiting takes it out (`queueToastRemoval`).
        const surface_id = surface.core().id;
        var tag_buf: [16]u8 = undefined;
        var group_buf: [toast_group_max]u8 = undefined;
        // A removal still queued for the pane's older toast would take this
        // one, which replaces it, away too. Taken off before the show, which
        // can pump messages that flush the queue; put back if Windows
        // refuses this toast, since the older one is then still there.
        const was_queued = self.cancelToastRemoval(surface_id);
        const shown = self.showToast(.{ .surface = surface.core() }, .{
            .title = if (title.len > 0) title else tab_title.buffered(),
            .body = body,
            .attribution = attribution,
            .launch = launch,
            .tag = toastTag(&tag_buf, surface_id),
            .group = toastGroup(&group_buf),
        }, title) catch |err| {
            if (was_queued) self.restoreToastRemoval(surface_id);
            return err;
        };
        if (shown) {
            // One queued while the show pumped messages (the tab seen) was
            // for the older toast too, which this one has replaced.
            _ = self.cancelToastRemoval(surface_id);
            self.noteToastShown(surface_id);
        } else if (was_queued) {
            self.restoreToastRemoval(surface_id);
        }
    }

    /// A toast tagged `surface_id` is in Action Center now. The show may
    /// have pumped messages that closed the pane or put its tab in undo
    /// history, so it is found again by id; a pane not in a live tab has
    /// its toast removed at once.
    fn noteToastShown(self: *App, surface_id: u64) void {
        self.toast_group_used = true;
        if (self.registry.findLiveSurfaceById(surface_id)) |surface| {
            surface.toast_outstanding = surface_id;
        } else {
            // Failing that, exit's group removal takes it.
            _ = self.queueToastRemoval(surface_id);
        }
    }

    /// The pane's toast, if it may still be in Action Center, is to be
    /// removed: its tab was seen, the pane closed, or the tab went into
    /// undo history. Queued by id and done from a posted message
    /// (`flushToastRemovals`), so nothing here calls into Windows.
    pub fn forgetSurfaceToast(self: *App, surface: *Surface) void {
        const surface_id = surface.toast_outstanding orelse return;
        if (self.queueToastRemoval(surface_id)) surface.toast_outstanding = null;
    }

    pub fn forgetTabToasts(self: *App, tab: *const Tab) void {
        var it = tab.tree.iterator();
        while (it.next()) |entry| self.forgetSurfaceToast(entry.view);
    }

    /// Returns false when the id could not be queued; the caller then keeps
    /// it outstanding, so a later chance retries.
    fn queueToastRemoval(self: *App, surface_id: u64) bool {
        if (std.mem.indexOfScalar(u64, self.toast_removals.items, surface_id) == null) {
            self.toast_removals.append(self.core_app.alloc, surface_id) catch {
                log.warn("toast removal not queued: out of memory", .{});
                return false;
            };
        }
        if (!self.toast_removals_posted) {
            // No message window (before `run` creates it, after it closes
            // at exit): exit's `removeOwnToasts` takes the whole group.
            if (self.registry.message_hwnd) |hwnd| {
                self.toast_removals_posted = sys.PostMessageW(hwnd, c.WM_WINHOSTTY_TOAST_REMOVALS, 0, 0) != 0;
            }
        }
        return true;
    }

    /// Returns whether a removal was queued for the pane.
    fn cancelToastRemoval(self: *App, surface_id: u64) bool {
        const i = std.mem.indexOfScalar(u64, self.toast_removals.items, surface_id) orelse return false;
        _ = self.toast_removals.orderedRemove(i);
        return true;
    }

    /// Queue again the removal a refused show took off (`showSurfaceToast`),
    /// by id only: the show may have pumped messages that closed the pane.
    /// A toast the pane showed meanwhile is outstanding and replaced the
    /// older one, so its removal waits for the next chance.
    fn restoreToastRemoval(self: *App, surface_id: u64) void {
        const surface = self.registry.findSurfaceById(surface_id);
        if (surface) |pane| if (pane.toast_outstanding != null) return;
        if (self.queueToastRemoval(surface_id)) return;
        // Out of memory: kept outstanding, so a later chance retries.
        if (surface) |pane| pane.toast_outstanding = surface_id;
    }

    /// Remove the queued panes' toasts from Action Center. Each id is taken
    /// off the live queue before its call: a history call can pump
    /// messages, and a toast shown meanwhile for a pane still queued takes
    /// that pane off the queue (`cancelToastRemoval`), so it survives.
    pub fn flushToastRemovals(self: *App) void {
        self.toast_removals_posted = false;
        const sink = self.toast_sink orelse {
            self.toast_removals.clearRetainingCapacity();
            return;
        };
        var group_buf: [toast_group_max]u8 = undefined;
        const group = toastGroup(&group_buf);
        while (self.toast_removals.items.len > 0) {
            const surface_id = self.toast_removals.orderedRemove(0);
            var tag_buf: [16]u8 = undefined;
            sink.remove_tag(sink.ctx, toastTag(&tag_buf, surface_id), group) catch |err| {
                log.warn("toast removal failed err={}", .{err});
            };
        }
    }

    /// At exit: take this process's toasts out of Action Center, all at
    /// once by its group, and never the other noctty processes'.
    fn removeOwnToasts(self: *App) void {
        self.toast_removals.clearAndFree(self.core_app.alloc);
        self.toast_removals_posted = false;
        if (!self.toast_group_used) return;
        self.toast_group_used = false;
        const sink = self.toast_sink orelse return;
        var group_buf: [toast_group_max]u8 = undefined;
        sink.remove_group(sink.ctx, toastGroup(&group_buf)) catch |err| {
            log.warn("toast group removal at exit failed err={}", .{err});
        };
    }

    /// What the user knows a tab by: the title of its focused pane.
    fn toastTabName(tab: *const Tab, surface: *Surface) []const u8 {
        const shown = tab.focusedSurface() orelse surface;
        return shown.effectiveTitle() orelse "noctty";
    }

    /// The line a toast from tab `index` of `host` carries, naming the
    /// tab: `Tab N: <title>`, `Tab N of window M: <title>` while more than
    /// one window is open, or `Tab N of the quick terminal: <title>`. The
    /// quick terminal is not counted as a window, so a window and an idle
    /// quick terminal don't number the window. The numbers are noctty's
    /// own, so a program can't pass for another tab; the title is
    /// sanitized and cut to `toast_tab_title_max` bytes.
    fn writeToastContext(
        self: *const App,
        writer: *std.Io.Writer,
        host: *const Host,
        index: usize,
        tab_name: []const u8,
    ) std.Io.Writer.Error!void {
        try writer.print("Tab {d}", .{index + 1});
        if (host.quick_terminal) {
            try writer.writeAll(" of the quick terminal");
        } else {
            var window_count: usize = 0;
            var number: ?usize = null;
            for (self.registry.hosts.items) |item| {
                if (item.quick_terminal) continue;
                window_count += 1;
                if (item == host) number = window_count;
            }
            if (window_count > 1) {
                if (number) |n| try writer.print(" of window {d}", .{n});
            }
        }
        try writer.writeAll(": ");
        try win32_program_status.writeSanitized(writer, tab_name, toast_tab_title_max);
    }

    fn showChildExited(
        self: *App,
        target: apprt.Target,
        exited: apprt.surface.Message.ChildExited,
    ) !void {
        const seconds = @as(f64, @floatFromInt(exited.runtime_ms)) / @as(f64, std.time.ms_per_s);
        const message = try std.fmt.allocPrint(
            self.core_app.alloc,
            "Child exited with code {d} | Runtime: {d:.2}s",
            .{ exited.exit_code, seconds },
        );
        defer self.core_app.alloc.free(message);
        if (try self.showHostBanner(target, .info, message)) return;
        try showInfoMessage(target, "noctty", message);
    }

    const CommandFinishPlan = struct {
        bell: bool = false,
        notify: bool = false,

        fn any(self: CommandFinishPlan) bool {
            return self.bell or self.notify;
        }
    };

    fn commandFinishPlan(
        notify_on_command_finish: configpkg.Config.NotifyOnCommandFinish,
        notify_on_command_finish_action: configpkg.Config.NotifyOnCommandFinishAction,
        desktop_notifications: bool,
        notify_on_command_finish_after: configpkg.Config.Duration,
        is_focused: bool,
        duration: configpkg.Config.Duration,
    ) CommandFinishPlan {
        if (duration.duration < notify_on_command_finish_after.duration) return .{};

        const allow = switch (notify_on_command_finish) {
            .never => false,
            .always => true,
            .unfocused => !is_focused,
        };
        if (!allow) return .{};

        return .{
            .bell = notify_on_command_finish_action.bell,
            .notify = notify_on_command_finish_action.notify and desktop_notifications,
        };
    }

    fn showCommandFinished(
        self: *App,
        target: apprt.Target,
        finished: apprt.action.CommandFinished,
    ) !void {
        const surface = self.registry.findSurfaceForTarget(target) orelse return;
        const config = &surface.core().config;
        const plan = commandFinishPlan(
            config.notify_on_command_finish,
            config.notify_on_command_finish_action,
            config.desktop_notifications,
            config.notify_on_command_finish_after,
            self.isSurfaceFocused(surface),
            finished.duration,
        );
        if (!plan.any()) return;

        if (plan.bell) self.ringBell(target);
        if (!plan.notify) return;

        const seconds = @as(f64, @floatFromInt(finished.duration.duration)) / @as(f64, std.time.ns_per_s);
        var code_buf: [apprt.action.CommandFinished.exit_code_text_max]u8 = undefined;
        const body = if (finished.exit_code) |code|
            try std.fmt.allocPrint(
                self.core_app.alloc,
                "Command finished with exit code {s} | Runtime: {d:.2}s",
                .{ apprt.action.CommandFinished.exitCodeText(&code_buf, code), seconds },
            )
        else
            try std.fmt.allocPrint(
                self.core_app.alloc,
                "Command finished | Runtime: {d:.2}s",
                .{seconds},
            );
        defer self.core_app.alloc.free(body);

        try self.showSurfaceToast(surface, "Command finished", body);
    }

    /// Apply a program status event (OSC 7501) to `surface`'s records, then
    /// update what its tab, the taskbar and notifications show.
    fn applyProgramStatus(
        self: *App,
        surface: *Surface,
        event: apprt.action.ProgramStatus,
    ) !void {
        const alloc = self.core_app.alloc;
        const taskbar_before = surface.effectiveTaskbarProgress();
        const news = switch (event) {
            .report => |report| try surface.program_status.apply(alloc, report),
            .program_ended => news: {
                _ = surface.program_status.programEnded(alloc);
                break :news null;
            },
            .reset => news: {
                surface.program_status.reset(alloc);
                // A full reset clears OSC 9;4 progress too. Termio's clear
                // follows, but the taskbar must not show the stale 9;4 for
                // the moment in between.
                surface.taskbar_progress = null;
                break :news null;
            },
        };
        const found = Host.findTabForSurface(surface) orelse return;
        const seen = tabSeenByUser(found.host, found.index);
        // The user is looking at this tab, so a program that finished or
        // failed has been seen the moment it says so.
        if (seen) _ = surface.program_status.acknowledge();
        found.host.refreshTabStatus(found.index);
        if (self.registry.activeSurfaceForHost(found.host.id) == surface and
            !std.meta.eql(taskbar_before, surface.effectiveTaskbarProgress()))
        {
            self.syncTaskbarProgressForHost(found.host.id);
        }
        // Last: showing a toast is a cross-process COM call that can pump
        // messages, and nothing here may touch the surface after it.
        if (!seen) if (news) |record| self.notifyProgramStatus(surface, found.host, found.index, record);
    }

    /// The user is looking at tab `index` of `host`: stop showing what its
    /// programs finished or failed, and let its next news notify at once.
    pub fn acknowledgeTab(self: *App, host: *Host, index: usize) void {
        self.acknowledgeTabWithForeground(host, index, sys.GetForegroundWindow());
    }

    /// `acknowledgeTab` with the foreground window passed in, for tests.
    pub fn acknowledgeTabWithForeground(self: *App, host: *Host, index: usize, foreground: ?HWND) void {
        if (index >= host.tabs.items.len or !tabSeenWithForeground(host, index, foreground)) return;
        var changed = false;
        var it = host.tabs.items[index].tree.iterator();
        while (it.next()) |entry| {
            entry.view.program_status_notified_ms = null;
            entry.view.program_status_notify_pending = false;
            if (entry.view.program_status.acknowledge()) changed = true;
            // Its toasts have been seen too. Only queued here: this runs
            // inside WM_ACTIVATE and focus handling.
            self.forgetSurfaceToast(entry.view);
        }
        if (!changed) return;
        host.refreshTabStatus(index);
        self.syncTaskbarProgressForHost(host.id);
    }

    /// Tell the user that a program in a tab they are not looking at is
    /// blocked on them, finished, or failed. Follows `desktop-notifications`
    /// like OSC 9 and 777 do. A notification the rate limit holds back is
    /// not lost: `flushProgramStatusNotifications` delivers what the pane
    /// then shows once the limit allows.
    fn notifyProgramStatus(
        self: *App,
        surface: *Surface,
        host: *Host,
        index: usize,
        record: *const win32_program_status.Record,
    ) void {
        if (!surface.core().config.desktop_notifications) {
            log.debug("program status notification skipped: desktop-notifications is off", .{});
            return;
        }
        if (!self.program_status_notify.allow(&surface.program_status_notified_ms, sys.GetTickCount64())) {
            log.debug("program status notification deferred by the rate limit", .{});
            surface.program_status_notify_pending = true;
            self.startProgramStatusNotifyTimer();
            return;
        }
        surface.program_status_notify_pending = false;
        self.showProgramStatusToast(surface, host, index, record) catch |err| {
            log.warn("program status notification failed err={}", .{err});
        };
    }

    pub fn showProgramStatusToast(
        self: *App,
        surface: *Surface,
        host: *Host,
        index: usize,
        record: *const win32_program_status.Record,
    ) !void {
        // The tab title is what the user knows the tab by. It names the
        // program when the record has no title or app. The toast's
        // attribution line says which tab and window this is, so a program
        // can't pass for another one.
        const tab_title = toastTabName(&host.tabs.items[index], surface);

        var title_buf: [256]u8 = undefined;
        var title: std.Io.Writer = .fixed(&title_buf);
        try win32_program_status.writeStatusLine(&title, &surface.program_status, record, tab_title, false);

        var body_buf: [win32_program_status.max_shown_text_bytes + "\u{2026}".len]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_buf);
        if (record.msg) |msg| {
            try win32_program_status.writeSanitized(&body, msg, win32_program_status.max_shown_text_bytes);
        }

        log.debug("program status notification tab={d} title={s}", .{ index + 1, title.buffered() });
        try self.showSurfaceToast(surface, title.buffered(), body.buffered());
    }

    /// Deliver program status notifications the rate limit held back: for
    /// each pane still waiting, what it shows now, if that still needs the
    /// user and its tab is still out of sight. Runs on a one-second thread
    /// timer that only exists while something waits.
    fn flushProgramStatusNotifications(self: *App) void {
        var waiting = false;
        for (self.registry.windows.items) |surface| {
            if (!surface.program_status_notify_pending) continue;
            const owed = self.owedProgramStatus(surface) orelse {
                surface.program_status_notify_pending = false;
                continue;
            };
            if (!self.program_status_notify.allow(&surface.program_status_notified_ms, sys.GetTickCount64())) {
                waiting = true;
                continue;
            }
            surface.program_status_notify_pending = false;
            self.showProgramStatusToast(surface, owed.host, owed.index, owed.record) catch |err| {
                log.warn("deferred program status notification failed err={}", .{err});
            };
            // The toast may have pumped messages that closed windows, so
            // the list is not walked any further this tick.
            waiting = true;
            break;
        }
        if (!waiting) self.stopProgramStatusNotifyTimer();
    }

    /// What `surface`'s held-back notification would say now, and about
    /// which tab, or null when it is no longer owed: notifications were
    /// turned off while it waited, the pane left its tab, it shows nothing
    /// that needs the user, or its tab is in sight.
    fn owedProgramStatus(self: *App, surface: *Surface) ?struct {
        host: *Host,
        index: usize,
        record: *const win32_program_status.Record,
    } {
        _ = self;
        if (!surface.core().config.desktop_notifications) return null;
        const found = Host.findTabForSurface(surface) orelse return null;
        const record = surface.program_status.headline() orelse return null;
        if (tabSeenByUser(found.host, found.index) or
            !win32_program_status.Indicator.of(record).needsUser()) return null;
        return .{ .host = found.host, .index = found.index, .record = record };
    }

    fn startProgramStatusNotifyTimer(self: *App) void {
        if (self.program_status_notify_timer_id != null) return;
        const timer_id = sys.SetTimer(null, 0, 1000, null);
        if (timer_id == 0) {
            log.warn("failed to start program status notification timer err={}", .{windows.kernel32.GetLastError()});
            return;
        }
        self.program_status_notify_timer_id = timer_id;
    }

    fn stopProgramStatusNotifyTimer(self: *App) void {
        killThreadTimer(&self.program_status_notify_timer_id);
    }

    /// Focus the next tab whose programs need the user; see
    /// `win32_program_status.nextNeedingUser` for the order. Tabs are taken
    /// window by window.
    fn gotoAttention(self: *App, target: apprt.Target) !bool {
        const alloc = self.core_app.alloc;
        const current = if (self.registry.findSurfaceForTarget(target)) |surface|
            Host.findTabForSurface(surface)
        else
            null;

        var indicators: std.ArrayListUnmanaged(win32_program_status.Indicator) = .empty;
        defer indicators.deinit(alloc);
        var surfaces: std.ArrayListUnmanaged(?*Surface) = .empty;
        defer surfaces.deinit(alloc);
        var current_index: ?usize = null;
        for (self.registry.hosts.items) |host| {
            for (host.tabs.items, 0..) |*tab, i| {
                if (current) |found| {
                    if (found.host == host and found.index == i) current_index = indicators.items.len;
                }
                const status = tabStatusHeadline(tab);
                try indicators.append(alloc, .of(if (status) |value| value.record else null));
                try surfaces.append(alloc, if (status) |value| value.surface else null);
            }
        }

        // Nothing to go to is a no-op, like `goto_window` with one window.
        const next = win32_program_status.nextNeedingUser(indicators.items, current_index) orelse return false;
        surfaces.items[next].?.present();
        return true;
    }

    pub fn isSurfaceFocused(self: *App, surface: *Surface) bool {
        return self.core_app.focused and
            surface.host_active and
            surface.window_focused and
            self.core_app.focusedSurface() == surface.core();
    }

    fn showInfoMessage(
        target: apprt.Target,
        title: []const u8,
        message: []const u8,
    ) !void {
        _ = target;
        // Final fallback for notification paths that cannot surface a
        // host banner. Keep failures observable without blocking the UI
        // thread.
        std.log.info("info notification (no visible target): {s} — {s}", .{ title, message });
    }

    pub fn showHostBanner(
        self: *App,
        target: apprt.Target,
        kind: HostBannerKind,
        message: []const u8,
    ) !bool {
        const surface = self.registry.findSurfaceForTarget(target) orelse return false;
        const host = surface.host orelse return false;
        try host.setBanner(kind, message);
        return true;
    }

    /// Keep a copy of what a config load found wrong, including configured
    /// font families, for the banner, the Settings page and the
    /// palette. The config's own diagnostics are freed with the config.
    fn recordConfigProblems(self: *App, config: *const configpkg.Config) void {
        const alloc = self.core_app.alloc;
        self.config_problems.clear(alloc);
        for (config._diagnostics.items()) |diag| {
            if (isLaunchArgumentDiagnostic(diag, self.safe_mode)) continue;
            self.config_problems.addDiagnostics(alloc, &.{diag}) catch |err| {
                log.warn("config problems: could not keep a diagnostic err={}", .{err});
            };
        }
        // Check the configured families once for the load, independently of
        // which tabs exist or which styles have already been drawn.
        if (self.core_app.font_grid_set.configuredMissingFamilies(alloc, config)) |families_value| {
            var families = families_value;
            defer families.deinit(alloc);
            for (families.reportable()) |family| {
                self.config_problems.addMissingFont(alloc, family) catch |err| {
                    log.warn("config problems: could not keep a missing font err={}", .{err});
                };
            }
        } else |err| {
            log.warn("config problems: could not check configured fonts err={}", .{err});
        }
        self.settings_window.configProblemsChanged();
    }

    /// The config in effect changed, whoever asked: a reload, a Save, or the
    /// system switching between light and dark under `theme =
    /// light:A,dark:B`, which installs the other half's problems. Keep the
    /// list current, and raise the banner only when what it says is news, so
    /// a banner the user closed does not come back at every switch.
    pub fn refreshConfigProblems(self: *App) void {
        const before = self.config_problems.fingerprint();
        self.recordConfigProblems(&self.config);
        if (self.config_problems.count() == 0) return self.clearConfigProblemsBanner();
        if (self.config_problems.fingerprint() != before) _ = self.showConfigProblemsBanner();
    }

    /// `recordConfigProblems`, then say so: an error banner with the count
    /// and the first problem, which stays until dismissed. A load that found
    /// none takes down the banner an earlier one raised. Returns whether
    /// there are problems.
    pub fn reportConfigProblems(self: *App, config: *const configpkg.Config) bool {
        self.recordConfigProblems(config);
        return self.reportRecordedConfigProblems();
    }

    fn reportRecordedConfigProblems(self: *App) bool {
        if (self.config_problems.count() == 0) {
            self.clearConfigProblemsBanner();
            return false;
        }
        _ = self.showConfigProblemsBanner();
        return true;
    }

    /// Keep the banner for `config_problems` and present it on every host.
    /// False when there is nothing to say or no window to say it on.
    pub fn showConfigProblemsBanner(self: *App) bool {
        const alloc = self.core_app.alloc;
        // First, and on every host: the primary window can change between
        // loads, an old banner on another window would no longer match the
        // text below, and one that cannot be replaced must not stay up stale.
        self.clearConfigProblemsBanner();
        const text = (self.config_problems.bannerText(alloc) catch null) orelse return false;
        // Kept so a later load that finds nothing can take down this banner,
        // and no other.
        self.config_problems_banner = text;
        for (self.registry.hosts.items) |host| self.presentConfigProblemsOnHost(host);
        return self.registry.hosts.items.len > 0;
    }

    pub fn presentConfigProblemsOnHost(self: *App, host: *Host) void {
        const text = self.config_problems_banner orelse return;
        host.setConfigProblemsBanner(text) catch |err| {
            log.warn("config problems: banner failed err={}", .{err});
        };
    }

    fn clearConfigProblemsBanner(self: *App) void {
        const alloc = self.core_app.alloc;
        const ours = self.config_problems_banner orelse return;
        defer {
            alloc.free(ours);
            self.config_problems_banner = null;
        }
        for (self.registry.hosts.items) |host| {
            // Remove a queued config banner as well, before clearing the
            // active one, so a clean load cannot resurrect stale problems.
            appendOwnedString(alloc, &host.config_problems_text, null) catch unreachable;
            const shown = host.banner_text orelse continue;
            if (host.banner_kind != .err or !std.mem.eql(u8, shown, ours)) continue;
            host.setBanner(.none, null) catch |err| {
                log.warn("config problems: could not take down the banner err={}", .{err});
            };
        }
    }
};

test "win32 Settings' profile choices follow what the loaded config made of the value" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const fixtures = pane_launch.fixtures;
    // No window, so no window's list at all.
    var app: App = undefined;
    app.registry.hosts = .empty;

    // Looked up and not found (the test machine has no ssh.exe): not found,
    // not "SSH: box".
    {
        app.config = try fixtures.load(alloc, .{ .file = "default-profile = ssh:box\n" });
        defer app.config.deinit();
        var failed = try settingsProfileChoicesThunk(&app, alloc, "ssh:box", null, false);
        defer failed.deinit(alloc);
        try std.testing.expect(failed.saved_label == null);
        try std.testing.expect(failed.saved_not_found);
    }

    // Visual Studio did not answer: apart from every row, and not missing.
    {
        app.config = try fixtures.loadWith(alloc, "default-profile = vs:newest:cmd\n", .{ .visual_studio_answers = false });
        defer app.config.deinit();
        var unavailable = try settingsProfileChoicesThunk(&app, alloc, "vs:newest:cmd", null, false);
        defer unavailable.deinit(alloc);
        try std.testing.expectEqual(@as(?usize, null), unavailable.selected);
        try std.testing.expect(unavailable.saved_label == null);
        try std.testing.expect(!unavailable.saved_not_found);
    }

    // Resolved: the label it starts under.
    {
        app.config = try fixtures.load(alloc, .{ .file = "profile-command = py: cmd.exe /k py.cmd\nprofile-name = py: Python\ndefault-profile = py\n" });
        defer app.config.deinit();
        var resolved = try settingsProfileChoicesThunk(&app, alloc, "py", null, false);
        defer resolved.deinit(alloc);
        try std.testing.expectEqualStrings("Python", resolved.saved_label orelse "");
        try std.testing.expect(!resolved.saved_not_found);
    }

    // The files' value in a window whose command line named another (which
    // the lookup found nothing for): the load did not look the files' value
    // up, so it gets the label it starts under.
    {
        app.config = try fixtures.load(alloc, .{ .file = "default-profile = ssh:box\n", .argv = &.{"--default-profile=user:py312"} });
        defer app.config.deinit();
        var untried = try settingsProfileChoicesThunk(&app, alloc, "ssh:box", null, false);
        defer untried.deinit(alloc);
        try std.testing.expectEqualStrings("SSH: box", untried.saved_label orelse "");
        try std.testing.expect(!untried.saved_not_found);
    }
}

test "win32 Settings names a staged ssh: profile the list left out by its label" {
    const alloc = std.testing.allocator;
    // A complete list with no SSH rows: a reload switched SSH config hosts
    // off after `ssh:box` was chosen.
    const items = [_]win32_settings.ProfileChoice{
        .{ .key = "pwsh.exe", .label = "PowerShell" },
        .{ .key = "ssh:Box", .label = "SSH: Box" },
    };
    const listed = items[0..1];
    for ([_]?[]const u8{ null, "pwsh.exe" }) |saved| {
        const label = (try settingsDraftProfileLabel(alloc, listed, saved, "ssh:box")) orelse return error.TestExpectedLabel;
        defer alloc.free(label);
        try std.testing.expectEqualStrings("SSH: box", label);
    }
    // No label where the row needs none (listed, the saved value, none) or
    // where the key starts nothing without the list.
    try std.testing.expect((try settingsDraftProfileLabel(alloc, &items, null, "ssh:Box")) == null);
    try std.testing.expect((try settingsDraftProfileLabel(alloc, listed, "ssh:box", "ssh:box")) == null);
    try std.testing.expect((try settingsDraftProfileLabel(alloc, listed, "pwsh.exe", null)) == null);
    try std.testing.expect((try settingsDraftProfileLabel(alloc, listed, null, "user:gone")) == null);
    try std.testing.expect((try settingsDraftProfileLabel(alloc, listed, null, "vs:6bb7cfd9:cmd")) == null);

    // Through the App, with no window's list: the saved value's answer and
    // the draft's label together, and every allocation can fail.
    var app: App = undefined;
    app.registry.hosts = .empty;
    app.config = try configpkg.Config.default(alloc);
    defer app.config.deinit();
    var choices = try settingsProfileChoicesThunk(&app, alloc, "user:gone", "ssh:box", false);
    defer choices.deinit(alloc);
    try std.testing.expectEqualStrings("SSH: box", choices.draft_label.?);
    try std.testing.expect(choices.saved_label == null);
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn run(a: Allocator, target: *App) !void {
            var both = try settingsProfileChoicesThunk(target, a, "ssh:saved", "ssh:box", false);
            both.deinit(a);
        }
    }.run, .{&app});
}

/// Every host receives a broadcast. Compare its resolved inputs so the first
/// recipient updates all hosts and the others do no resource rebuilds. Fonts
/// and motion policy belong here too: equal colours alone do not imply an
/// irrelevant WindowMetrics or accessibility change.
const SystemThemeSnapshot = struct {
    theme: ThemeColors,
    metrics: ?NONCLIENTMETRICSW = null,
    high_contrast: bool = false,
    animations: bool = true,

    fn capture(config: *const configpkg.Config) SystemThemeSnapshot {
        var metrics = std.mem.zeroes(NONCLIENTMETRICSW);
        metrics.cbSize = @sizeOf(NONCLIENTMETRICSW);
        return .{
            .theme = resolveTheme(config),
            .metrics = if (sys.SystemParametersInfoW(c.SPI_GETNONCLIENTMETRICS, @sizeOf(NONCLIENTMETRICSW), @ptrCast(&metrics), 0) != 0) metrics else null,
            .high_contrast = isHighContrastActive(),
            .animations = Host.clientAnimationsEnabled(),
        };
    }
};

const SystemThemeRefresh = struct {
    previous: ?SystemThemeSnapshot = null,

    fn accept(self: *SystemThemeRefresh, next: SystemThemeSnapshot) bool {
        if (self.previous) |previous| {
            if (std.meta.eql(previous, next)) return false;
        }
        self.previous = next;
        return true;
    }
};

test "CHROME57 system broadcasts rebuild once and retain font and accessibility changes" {
    var refresh: SystemThemeRefresh = .{};
    var next: SystemThemeSnapshot = .{ .theme = darkTheme() };
    try std.testing.expect(refresh.accept(next));
    for (0..4) |_| try std.testing.expect(!refresh.accept(next));
    next.theme = lightTheme();
    try std.testing.expect(refresh.accept(next));
    next.metrics = std.mem.zeroes(NONCLIENTMETRICSW);
    try std.testing.expect(refresh.accept(next));
    next.metrics.?.lfMessageFont.lfWeight = 700;
    try std.testing.expect(refresh.accept(next));
    next.high_contrast = true;
    try std.testing.expect(refresh.accept(next));
    next.animations = false;
    try std.testing.expect(refresh.accept(next));
    try std.testing.expect(!refresh.accept(next));
    try std.testing.expect(settingChangeAffectsTheme(0));
    inline for (.{ "ImmersiveColorSet", "WindowMetrics", "UnknownSetting" }) |name| {
        try std.testing.expect(settingChangeAffectsTheme(@bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral(name)))));
    }
    inline for (.{ "Environment", "intl", "Policy" }) |name| {
        try std.testing.expect(!settingChangeAffectsTheme(@bitCast(@intFromPtr(std.unicode.utf8ToUtf16LeStringLiteral(name)))));
    }
}

test "CHROME57 repeated host system messages apply the app theme only once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var session: TestSession = .{};
    try session.init(.{ .core_app = &core_app, .app = &app });
    defer session.deinit();
    app.reconfigureSystemTheme();
    const applied = app.theme_rebuilds;
    app.reconfigureSystemTheme();
    app.reconfigureSystemTheme();
    try std.testing.expectEqual(applied, app.theme_rebuilds);
    app.config.@"window-theme" = if (app.resolved_theme.is_dark) .light else .dark;
    // High Contrast intentionally overrides the requested palette.
    const expected = resolveTheme(&app.config);
    const changed = !std.meta.eql(expected, app.resolved_theme);
    app.reconfigureSystemTheme();
    app.reconfigureSystemTheme();
    try std.testing.expectEqual(applied + @as(u32, @intFromBool(changed)), app.theme_rebuilds);
}

test "PKG-39 a Settings preview is shown without reaching the config terminals and reloads read" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var session: TestSession = .{};
    try session.init(.{ .core_app = &core_app, .app = &app });
    defer session.deinit();
    defer testFreeConfigProblems(&app, alloc);
    app.config.@"window-theme" = .dark;
    const saved_font_size = app.config.@"font-size";

    // A field no open window shows is not previewed at all: written into the
    // config, it reached only the terminals opened before Save.
    const baseline = app.theme_rebuilds;
    settingsPreviewFieldThunk(&app, .font_size, .{ .font_size = saved_font_size + 2 });
    settingsPreviewFieldThunk(&app, .window_padding_x, .{ .window_padding_x = .{ .top_left = 4, .bottom_right = 4 } });
    settingsPreviewFieldThunk(&app, .cursor_style, .{ .cursor_style = .underline });
    try std.testing.expectEqual(saved_font_size, app.config.@"font-size");
    try std.testing.expect(app.settings_preview == null);
    try std.testing.expectEqual(baseline, app.theme_rebuilds);

    // Opacity and the window theme are shown from a copy of the config; only
    // the theme field rebuilds the theme, once per change.
    settingsPreviewFieldThunk(&app, .background_opacity, .{ .background_opacity = 0.5 });
    try std.testing.expectEqual(baseline, app.theme_rebuilds);
    settingsPreviewFieldThunk(&app, .window_theme, .{ .window_theme = .light });
    try std.testing.expectEqual(baseline + 1, app.theme_rebuilds);
    if (!isHighContrastActive()) try std.testing.expect(!app.resolved_theme.is_dark);
    settingsPreviewFieldThunk(&app, .window_theme, .{ .window_theme = .light });
    try std.testing.expectEqual(baseline + 1, app.theme_rebuilds);
    try std.testing.expectEqual(@as(f64, 0.5), app.shownConfig().@"background-opacity");
    try std.testing.expect(app.shownConfig().@"window-theme" == .light);
    try std.testing.expectEqual(@as(f64, 1), app.config.@"background-opacity");
    try std.testing.expect(app.config.@"window-theme" == .dark);
    // A window shows the previewed opacity whatever config it applies: in a
    // reload, a terminal's own config reaches its window before the app's.
    try std.testing.expectEqual(@as(f64, 0.5), app.shownBackgroundOpacity(&app.config));

    // A new tab starts from what is saved.
    {
        var tab = try apprt.surface.newConfig(&core_app, &app.config, .tab);
        defer tab.deinit();
        try std.testing.expectEqual(@as(f64, 1), tab.@"background-opacity");
        try std.testing.expect(tab.@"window-theme" == .dark);
    }

    // Back to the saved values, nothing is previewed.
    settingsPreviewFieldThunk(&app, .window_theme, .{ .window_theme = .dark });
    try std.testing.expect(app.settings_preview != null);
    settingsPreviewFieldThunk(&app, .background_opacity, .{ .background_opacity = 1 });
    try std.testing.expect(app.settings_preview == null);

    // What is previewed is the Settings window's to say: a reload, with no
    // window whose drafts it could show again, leaves no preview.
    settingsPreviewFieldThunk(&app, .background_opacity, .{ .background_opacity = 0.5 });
    {
        var reloaded = try app.config.clone(alloc);
        defer reloaded.deinit();
        reloaded.@"font-size" = saved_font_size + 3;
        try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &reloaded }));
    }
    try std.testing.expectEqual(saved_font_size + 3, app.config.@"font-size");
    try std.testing.expect(app.settings_preview == null);
    try std.testing.expectEqual(@as(f64, 1), app.shownBackgroundOpacity(&app.config));

    // A save ends the preview: where one is left (a save without a reload,
    // in safe mode), the windows go to the saved config, not the draft.
    settingsPreviewFieldThunk(&app, .window_theme, .{ .window_theme = .light });
    {
        // No opacity is previewed now, so a window keeps the one it applies.
        var own = try app.config.clone(alloc);
        defer own.deinit();
        own.@"background-opacity" = 0.7;
        try std.testing.expectEqual(@as(f64, 0.7), app.shownBackgroundOpacity(&own));
    }
    const rebuilds = app.theme_rebuilds;
    app.endSettingsPreview();
    try std.testing.expect(app.settings_preview == null);
    try std.testing.expectEqual(rebuilds + 1, app.theme_rebuilds);
    if (!isHighContrastActive()) try std.testing.expect(app.resolved_theme.is_dark);
    app.endSettingsPreview();
    try std.testing.expectEqual(rebuilds + 1, app.theme_rebuilds);
}

test "win32 a DPI change holds the terminal grid from WM_GETDPISCALEDSIZE to WM_DPICHANGED" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const core = try CoreApp.create(std.testing.allocator);
    defer core.destroy();
    var app: App = undefined;
    try app.init(core, .{ .safe_mode = true });
    const hinstance = app.hinstance;
    defer {
        app.terminate();
        _ = sys.UnregisterClassW(host_class_name, hinstance);
        _ = sys.UnregisterClassW(palette_list_class_name, hinstance);
        _ = sys.UnregisterClassW(scrollbar_class_name, hinstance);
    }
    const host = try app.createHost(std.unicode.utf8ToUtf16LeStringLiteral(""), &app.config, .{ .quick_terminal = true });
    const hwnd = host.hwnd.?;
    var size: extern struct { cx: i32, cy: i32 } = .{ .cx = 900, .cy = 600 };
    const size_param: LPARAM = @bitCast(@intFromPtr(&size));

    // FALSE keeps Windows' linear scaling and leaves the proposed size alone.
    try std.testing.expect(!host.dpi_change_pending);
    try std.testing.expectEqual(@as(LRESULT, 0), hostWindowProc(hwnd, c.WM_GETDPISCALEDSIZE, 144, size_param));
    try std.testing.expect(host.dpi_change_pending);
    try std.testing.expectEqual(@as(i32, 900), size.cx);

    // WM_DPICHANGED releases the hold once it has run.
    var rect: RECT = undefined;
    try std.testing.expect(sys.GetWindowRect(hwnd, &rect) != 0);
    _ = hostWindowProc(hwnd, c.WM_DPICHANGED, 0, @bitCast(@intFromPtr(&rect)));
    try std.testing.expect(!host.dpi_change_pending);

    // So does the end of a drag that never delivered one.
    _ = hostWindowProc(hwnd, c.WM_GETDPISCALEDSIZE, 144, size_param);
    _ = hostWindowProc(hwnd, c.WM_EXITSIZEMOVE, 0, 0);
    try std.testing.expect(!host.dpi_change_pending);
}

/// Which COM server, if any, started this process. COM appends -Embedding to
/// every `LocalServer32` command, the toast activator's
/// (`"noctty.exe" -ToastActivated`) included, so -Embedding alone does not
/// make a terminal handoff server.
const ComStart = enum {
    none,
    terminal_handoff,
    toast_activator,

    fn ofArgs(argv: []const []const u8) ComStart {
        if (win32_toast_activator.hasLaunchSwitch(argv)) return .toast_activator;
        if (win32_terminal_handoff.isEmbeddingArgs(argv)) return .terminal_handoff;
        return .none;
    }

    fn ofProcess(alloc: std.mem.Allocator) ComStart {
        const argv = std.process.argsAlloc(alloc) catch return .none;
        defer std.process.argsFree(alloc, argv);
        return ofArgs(argv);
    }
};

/// kernel32's restart registration, and whether another noctty's in-app
/// Install is running Setup. A test build defaults to stand-ins that register
/// nothing and look at no update stage, so no test makes the test runner
/// restartable or reads the user's profile.
const RestartApi = struct {
    register: *const fn (?LPCWSTR, DWORD) callconv(.winapi) windows.HRESULT =
        if (builtin.is_test) &inertRegisterRestart else &sys.RegisterApplicationRestart,
    unregister: *const fn () callconv(.winapi) windows.HRESULT =
        if (builtin.is_test) &inertUnregisterRestart else &sys.UnregisterApplicationRestart,
    installer_apply_running: *const fn (Allocator) bool =
        if (builtin.is_test) &inertApplyRunning else &stagedInstallerRunning,

    fn inertRegisterRestart(_: ?LPCWSTR, _: DWORD) callconv(.winapi) windows.HRESULT {
        return 0;
    }
    fn inertUnregisterRestart() callconv(.winapi) windows.HRESULT {
        return 0;
    }
    fn inertApplyRunning(_: Allocator) bool {
        return false;
    }
    fn stagedInstallerRunning(alloc: Allocator) bool {
        const state_path = updatepkg.defaultStatePath(alloc) catch return false;
        defer alloc.free(state_path);
        return updatepkg.stagedInstallerRunning(alloc, state_path);
    }
};

test "-ToastActivated is a launch argument, not a config diagnostic" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    // What COM starts: the installer's LocalServer32 command plus -Embedding.
    const command_line = "--font-size=13 -ToastActivated -Embedding";
    var cfg = try configpkg.Config.default(alloc);
    defer cfg.deinit();
    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, command_line);
    defer iter.deinit();
    try cli_args.parse(configpkg.Config, alloc, &cfg, &iter);
    try std.testing.expect(cfg._diagnostics.empty());
    try std.testing.expectEqual(@as(f32, 13), cfg.@"font-size");

    // It is a toast activation start, not a terminal handoff server, though
    // COM's -Embedding is there too.
    try std.testing.expectEqual(ComStart.toast_activator, ComStart.ofArgs(&.{ "noctty.exe", "--font-size=13", "-ToastActivated", "-Embedding" }));
    try std.testing.expectEqual(ComStart.terminal_handoff, ComStart.ofArgs(&.{ "noctty.exe", "-Embedding" }));
    try std.testing.expectEqual(ComStart.none, ComStart.ofArgs(&.{ "noctty.exe", "-e", "x.exe", "-ToastActivated", "-Embedding" }));
    try std.testing.expectEqual(ComStart.none, ComStart.ofArgs(&.{"noctty.exe"}));

    // The settings save target stops where the loader stops.
    const saved = try cliConfigFileOverrideArgs(alloc, &.{ "noctty.exe", "--config-file=C:\\a.conf", "-ToastActivated", "--config-file=C:\\b.conf" });
    defer if (saved) |path| alloc.free(path);
    try std.testing.expect(std.mem.endsWith(u8, saved.?, "a.conf"));
}

test "win32 the confirmed install is queued for the message loop and asked once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var session: TestSession = .{};
    try session.init(.{ .core_app = &core_app, .app = &app });
    defer session.deinit();

    // The hook stands in for the apply, which would act on whatever update the
    // real state directory has staged.
    const Hook = struct {
        var applies: usize = 0;
        fn launch(_: *App, request: *const App.DeferredOpen) anyerror!void {
            if (request.* == .apply_staged_update) applies += 1;
        }
    };
    Hook.applies = 0;
    app.test_shell_request = &Hook.launch;

    // The answer inside the overlay's handler only queues.
    updateApplyConfirmAccept(&app);
    try std.testing.expectEqual(@as(usize, 1), app.deferred_opens.items.len);
    try std.testing.expect(app.update_apply_queued);
    try std.testing.expectEqual(@as(usize, 0), Hook.applies);

    // A second answer while it is queued adds nothing.
    updateApplyConfirmAccept(&app);
    try std.testing.expectEqual(@as(usize, 1), app.deferred_opens.items.len);

    // The loop runs it once.
    try std.testing.expect(app.runDeferredOpens());
    try std.testing.expectEqual(@as(usize, 1), Hook.applies);
    try std.testing.expect(!app.update_apply_queued);
    try std.testing.expect(!app.runDeferredOpens());
    try std.testing.expectEqual(@as(usize, 1), Hook.applies);

    // One that was dispatched but not completed (held, or failed) can be asked
    // for again; one under way cannot.
    updateApplyConfirmAccept(&app);
    try std.testing.expectEqual(@as(usize, 1), app.deferred_opens.items.len);
    try std.testing.expect(app.runDeferredOpens());
    app.update_apply_in_flight = true;
    updateApplyConfirmAccept(&app);
    try std.testing.expectEqual(@as(usize, 0), app.deferred_opens.items.len);
    app.update_apply_in_flight = false;
}

test "win32 runtime can initialize config" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core = try CoreApp.create(std.testing.allocator);
    defer core.destroy();

    var app: App = undefined;
    try app.init(core, .{});
    defer app.terminate();

    try std.testing.expect(@intFromPtr(app.hinstance) != 0);
    // A test's App never holds the real toast notifier.
    try std.testing.expect(app.winrt_toast == null);
    try std.testing.expect(app.toast_sink == null);
}

test "win32 a command-line launch-layout outlasts the color-scheme sync that ends init" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const Case = struct { conditional: bool, scheme_changes: bool };
    // When the scheme changes, the sync's soft reload installs the app config
    // itself, or, when the config uses a conditional key, the replay of its
    // history. When it does not, no config change runs, and the claim alone
    // keeps the layout out of the app config.
    for ([_]Case{
        .{ .conditional = false, .scheme_changes = true },
        .{ .conditional = true, .scheme_changes = true },
        .{ .conditional = false, .scheme_changes = false },
    }) |case| {
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        defer app.releaseStartupLaunchLayout();

        try testLoadStartupArgv(&app, &.{"--launch-layout=shot"});
        if (case.conditional) app.config._conditional_set.insert(.theme);

        // Conditional state starts light and Windows was dark in the report.
        // Start from the scheme the system is not in, so the sync is a change
        // on any machine, or from the one it is in, so it is none.
        const system: configpkg.ConditionalState.Theme = if (isSystemDarkMode()) .dark else .light;
        const other: configpkg.ConditionalState.Theme = if (system == .dark) .light else .dark;
        const start = if (case.scheme_changes) other else system;
        core_app.config_conditional_state.theme = start;
        app.config._conditional_state.theme = start;
        const revision = app.config_revision;
        // What `init` ends with.
        app.syncStartupConfig();
        // When it changed, it reloaded, and the `.app` config change installed
        // a new config: the replay's, which carries the new state, when it
        // was conditional.
        try std.testing.expectEqual(case.scheme_changes, app.config_revision != revision);
        try std.testing.expectEqual(
            case.conditional and case.scheme_changes,
            app.config._conditional_state.theme != start,
        );

        // `run` still has the layout to open (before the fix it read the
        // app config, which had lost it here), and the config has nothing
        // of it for a reload or a window to bring back.
        switch (app.startup_launch_layout) {
            .name => |claimed| try std.testing.expectEqualStrings("shot", claimed),
            .none, .lost => return error.TestUnexpectedResult,
        }
        try testExpectNoLaunchLayout(&app.config);
    }
}

test "win32 a reload after run took the startup launch-layout does not bring it back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var core_app: CoreApp = undefined;
    var app: App = undefined;
    var session: TestSession = .{};
    try session.init(.{ .core_app = &core_app, .app = &app });
    defer session.deinit();
    defer testFreeConfigProblems(&app, alloc);
    defer app.releaseStartupLaunchLayout();

    const argv: []const []const u8 = &.{"--launch-layout=Project Alpha"};
    try testLoadStartupArgv(&app, argv);
    app.claimStartupLaunchLayout();
    try std.testing.expect(app.startup_launch_layout == .name);
    // As `run` does once it has tried the layout.
    app.releaseStartupLaunchLayout();

    // A hard reload or a Settings save parses the same command line again.
    var reloaded = try configpkg.Config.default(alloc);
    defer reloaded.deinit();
    var args: cli_args.ArgsIterator(cli_args.SliceIterator) = .{ .iterator = cli_args.sliceIterator(argv) };
    try reloaded.loadIter(alloc, &args);
    try reloaded.finalize();
    try std.testing.expectEqualStrings("Project Alpha", reloaded.@"launch-layout".?);
    try std.testing.expect(try app.performAction(.app, .config_change, .{ .config = &reloaded }));
    try std.testing.expect(app.startup_launch_layout == .none);
    try testExpectNoLaunchLayout(&app.config);

    // A theme change after it replays the installed config.
    app.config._conditional_set.insert(.theme);
    const scheme: apprt.ColorScheme = if (core_app.config_conditional_state.theme == .light) .dark else .light;
    try core_app.colorSchemeEvent(&app, scheme);
    try std.testing.expect(app.startup_launch_layout == .none);
    try testExpectNoLaunchLayout(&app.config);

    // A new window's config is a clone of the app config.
    var window = try apprt.surface.newConfig(&core_app, &app.config, .window);
    defer window.deinit();
    try testExpectNoLaunchLayout(&window);
}

test "win32 an OpenGL retry on a window reuses the pixel format it set" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var core = try CoreApp.create(std.testing.allocator);
    defer core.destroy();
    var app: App = undefined;
    try app.init(core, .{});
    defer app.terminate();

    const hwnd = try createTestHostWindow();
    defer _ = sys.DestroyWindow(hwnd);
    var owned: ?pixel_format.WglPixelFormatProvenance = null;
    // No usable WGL format here (a hosted runner without a GL driver).
    const first = app.createGLContext(hwnd, &owned) catch return error.SkipZigTest;
    try std.testing.expect(owned != null);

    // What a failed attempt leaves: the format set, no context.
    _ = sys.wglMakeCurrent(null, null);
    _ = sys.wglDeleteContext(first.hglrc);
    _ = sys.ReleaseDC(hwnd, first.hdc);

    // Its own format is reused, and the retry gets a context. (Refusing a
    // format the window did not record is `planPixelFormat`'s table test:
    // through here it logs an OpenGL startup error, which fails the run.)
    const second = try app.createGLContext(hwnd, &owned);
    defer {
        _ = sys.wglMakeCurrent(null, null);
        _ = sys.wglDeleteContext(second.hglrc);
        _ = sys.ReleaseDC(hwnd, second.hdc);
    }
    try std.testing.expectEqual(owned.?.index, second.provenance.index);
}

test "win32 runtime leaves the real profile alone when a test starts it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    // A portable root beside the test executable takes precedence over
    // LOCALAPPDATA for both the data directory and the PowerShell install,
    // so redirecting LOCALAPPDATA below could not observe a leak and this
    // test would pass without checking anything. Skip rather than pass.
    if (try internal_os.xdg.portableRoot(alloc)) |root| {
        alloc.free(root);
        return error.SkipZigTest;
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fake_local = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(fake_local);

    // Point LOCALAPPDATA at an empty directory for the length of this test,
    // then put the real value back.
    const saved: ?[:0]u8 = saved: {
        const value = std.process.getEnvVarOwned(alloc, "LOCALAPPDATA") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :saved null,
            else => return err,
        };
        defer alloc.free(value);
        break :saved try alloc.dupeZ(u8, value);
    };
    defer if (saved) |value| alloc.free(value);
    defer _ = if (saved) |value|
        internal_os.setenv("LOCALAPPDATA", value)
    else
        internal_os.unsetenv("LOCALAPPDATA");
    const fake_z = try alloc.dupeZ(u8, fake_local);
    defer alloc.free(fake_z);
    try std.testing.expectEqual(@as(c_int, 0), internal_os.setenv("LOCALAPPDATA", fake_z));

    {
        var core = try CoreApp.create(alloc);
        defer core.destroy();
        var app: App = undefined;
        try app.init(core, .{});
        defer app.terminate();
    }

    // Before the gates this left `noctty\startup-attempts.json` with an
    // unfinished launch in it, which is how repeated test runs put the
    // developer's next real launch into safe mode, and replaced the
    // installed PowerShell integration script with the one under test.
    var data_dir = tmp.dir.openDir(build_config.data_dir_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer data_dir.close();
    try std.testing.expectError(
        error.FileNotFound,
        data_dir.access("startup-attempts.json", .{}),
    );
    try std.testing.expectError(
        error.FileNotFound,
        data_dir.access("shell-integration", .{}),
    );
}

test "win32 named layout encoding uses the persistence read limit" {
    const limit = win32_session_persistence.default_max_state_bytes;
    try std.testing.expect(App.namedLayoutEncodingFitsReadLimit(limit));
    try std.testing.expect(!App.namedLayoutEncodingFitsReadLimit(limit + 1));
}

test "win32 new host starts with the client area its first frame change keeps" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    var core = try CoreApp.create(alloc);
    defer core.destroy();
    var app: App = undefined;
    // Safe mode starts from the default config rather than the developer's
    // own, whose tab bar or decoration settings could turn the integrated
    // titlebar off.
    try app.init(core, .{ .safe_mode = true });
    const hinstance = app.hinstance;
    defer {
        app.terminate();
        // `createHost` registers these and nothing unregisters them, so a
        // later test could not create a host of its own.
        _ = sys.UnregisterClassW(host_class_name, hinstance);
        _ = sys.UnregisterClassW(palette_list_class_name, hinstance);
        _ = sys.UnregisterClassW(scrollbar_class_name, hinstance);
    }
    // The Windows 11 caption row lives inside the client area. Force it on so
    // an older test machine takes the same path.
    app.use_integrated_titlebar = true;

    // The host stays hidden, so the test never touches the foreground.
    const host = try app.createHost(std.unicode.utf8ToUtf16LeStringLiteral(""), &app.config, .{});
    const hwnd = host.hwnd.?;
    try std.testing.expect(host.usingIntegratedTitlebar());
    try std.testing.expect(sys.IsWindowVisible(hwnd) == 0);

    var created: RECT = undefined;
    try std.testing.expect(sys.GetClientRect(hwnd, &created) != 0);
    const content_created = try host.contentRect();

    // The first surface of a new window reads its size from this content
    // rect. The core's init-time `size_limit` action then refreshes the
    // frame, and before the fix that grew the client by the stock caption's
    // height while the core kept the old size: a grid one row short.
    try std.testing.expect(sys.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE | c.SWP_FRAMECHANGED,
    ) != 0);
    var refreshed: RECT = undefined;
    try std.testing.expect(sys.GetClientRect(hwnd, &refreshed) != 0);
    try std.testing.expectEqual(created, refreshed);
    try std.testing.expectEqual(content_created, try host.contentRect());

    // And it is the integrated area: the client starts at the window's top
    // edge, where the stock caption would otherwise be.
    var window_rect: RECT = undefined;
    try std.testing.expect(sys.GetWindowRect(hwnd, &window_rect) != 0);
    var client_origin: POINT = .{ .x = 0, .y = 0 };
    try std.testing.expect(sys.ClientToScreen(hwnd, &client_origin) != 0);
    try std.testing.expectEqual(window_rect.top, client_origin.y);

    // Its hit test is the one an undecorated frame leaves alone: an 8 DIP
    // top band over a caption row as tall as the tab strip, and the caption
    // buttons at the row's right end.
    const mid_x = @divTrunc(window_rect.left + window_rect.right, 2);
    const edge = host.scaled(8);
    try std.testing.expectEqual(@as(LRESULT, c.HTTOP), testHitTest(hwnd, mid_x, window_rect.top + edge - 1));
    try std.testing.expectEqual(@as(LRESULT, c.HTCAPTION), testHitTest(hwnd, mid_x, window_rect.top + edge));
    try std.testing.expectEqual(@as(LRESULT, c.HTCAPTION), testHitTest(hwnd, mid_x, client_origin.y + host.tabBarHeight() - 1));
    try std.testing.expectEqual(@as(LRESULT, c.HTCLIENT), testHitTest(hwnd, mid_x, client_origin.y + host.tabBarHeight()));
    const caption_button_w = host.scaled(46);
    try std.testing.expectEqual(@as(LRESULT, c.HTMAXBUTTON), testHitTest(
        hwnd,
        client_origin.x + created.right - caption_button_w - @divTrunc(caption_button_w, 2),
        client_origin.y + @divTrunc(host.tabBarHeight(), 2),
    ));
}

test "security regression win32 link opener allows local junctions without PATHEXT retry" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("target");
    try tmp.dir.writeFile(.{ .sub_path = "target/safe.txt", .data = "safe" });
    try tmp.dir.writeFile(.{ .sub_path = "target/probe.cmd", .data = "@exit /b 0\r\n" });
    try tmp.dir.writeFile(.{ .sub_path = "target/binary", .data = "MZ\x00\x00" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const target = try std.fs.path.join(alloc, &.{ root, "target" });
    defer alloc.free(target);
    const junction = try std.fs.path.join(alloc, &.{ root, "junction" });
    defer alloc.free(junction);
    // Junction creation needs no symlink privilege or developer mode. Windows
    // need not live in C:\Windows, so take cmd.exe from SystemRoot.
    const system_root = try std.process.getEnvVarOwned(alloc, "SystemRoot");
    defer alloc.free(system_root);
    const cmd_exe = try std.fs.path.join(alloc, &.{ system_root, "System32", "cmd.exe" });
    defer alloc.free(cmd_exe);
    const result = try std.process.Child.run(.{ .allocator = alloc, .argv = &.{ cmd_exe, "/d", "/c", "mklink", "/J", junction, target } });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
    // Remove just our junction before tmpDir cleanup, never its target contents.
    defer tmp.dir.deleteDir("junction") catch {};
    var writer = try tmp.dir.createFile("target/active.log", .{ .read = true });
    defer writer.close();
    const active = try std.fs.path.join(alloc, &.{ junction, "active.log" });
    defer alloc.free(active);
    try std.testing.expect(try App.isAllowedWin32OpenTarget(alloc, active));
    for ([_][]const u8{ "safe.txt", "probe", "binary" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ junction, name });
        defer alloc.free(path);
        try std.testing.expectEqual(std.mem.eql(u8, name, "safe.txt"), try App.isAllowedWin32OpenTarget(alloc, path));
        if (std.mem.eql(u8, name, "safe.txt")) {
            const prepared = (try App.prepareWin32OpenTarget(alloc, path)).?;
            defer alloc.free(prepared);
            try std.testing.expectEqualStrings(path, prepared);
        }
    }
    try std.testing.expect(try App.isAllowedWin32OpenTarget(alloc, junction));
}

test "win32 link opener opens the Windows path of an MSYS2 link, never the text as written (#514)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("conf.d");
    try tmp.dir.writeFile(.{ .sub_path = "conf.d/config.fish", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "conf.d/run.cmd", .data = "@exit /b 0\r\n" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    if (!windows_shell.isDriveAbsolutePath(root)) return error.SkipZigTest;

    for ([_]struct { name: []const u8, allowed: bool }{
        .{ .name = "conf.d", .allowed = true },
        .{ .name = "conf.d\\config.fish", .allowed = true },
        // The opener's every other refusal holds for the Windows path.
        .{ .name = "conf.d\\run.cmd", .allowed = false },
        .{ .name = "conf.d\\missing.txt", .allowed = false },
    }) |case| {
        const windows_path = try std.fs.path.join(alloc, &.{ root, case.name });
        defer alloc.free(windows_path);
        for ([_][]const u8{ "", "/cygdrive" }) |prefix| {
            const text = try internal_os.local_path.testMsysPath(alloc, prefix, windows_path);
            defer alloc.free(text);
            const mapped = try internal_os.local_path.linkTarget(alloc, text, .{ .wsl = false }) orelse return error.TestUnexpectedResult;
            defer alloc.free(mapped);
            try std.testing.expectEqual(case.allowed, try App.isAllowedWin32OpenTarget(alloc, mapped));
            // What a Ctrl+click handed the opener before #514.
            try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, text));
        }
    }

    // A letter that is no drive here is refused without a lookup.
    for ("BHJKMNOPQRSTUVWY") |letter| {
        if (internal_os.windows.driveTypeForLetter(letter) != internal_os.windows.DRIVE_NO_ROOT_DIR) continue;
        const text = [_]u8{ '/', std.ascii.toLower(letter), '/', 'x' };
        const mapped = try internal_os.local_path.linkTarget(alloc, &text, .{ .wsl = false }) orelse return error.TestUnexpectedResult;
        defer alloc.free(mapped);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, mapped));
        break;
    }
}

test "security regression win32 link opener allows local symlinks" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "safe.txt", .data = "safe" });
    const target = try tmp.dir.realpathAlloc(alloc, "safe.txt");
    defer alloc.free(target);
    tmp.dir.symLink(target, "absolute.txt", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    try tmp.dir.symLink("safe.txt", "relative.txt", .{});
    try tmp.dir.makeDir("directory");
    try tmp.dir.writeFile(.{ .sub_path = "directory/safe.txt", .data = "safe" });
    try tmp.dir.symLink("directory", "folder", .{ .is_directory = true });
    try tmp.dir.symLink("cycle-b.txt", "cycle-a.txt", .{});
    try tmp.dir.symLink("cycle-a.txt", "cycle-b.txt", .{});
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    for ([_][]const u8{ "absolute.txt", "relative.txt", "folder/safe.txt", "folder" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        try std.testing.expect(try App.isAllowedWin32OpenTarget(alloc, path));
    }
    const cycle = try std.fs.path.join(alloc, &.{ root, "cycle-a.txt" });
    defer alloc.free(cycle);
    try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, cycle));
}

test "security regression win32 link opener refuses UNC symlinks and local chains to UNC" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.symLink("\\\\noctty-invalid-host.invalid\\share\\safe.txt", "network.txt", .{}) catch |err| switch (err) {
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const network = try std.fs.path.join(alloc, &.{ root, "network.txt" });
    defer alloc.free(network);
    try tmp.dir.symLink(network, "chain.txt", .{});
    for ([_][]const u8{ "network.txt", "chain.txt" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, path));
    }
}

test "security regression win32 link opener allows known schemes and safe local files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    for ([_][]const u8{
        "http://example.com",
        "https://example.com",
        // An encoded space is no argument break.
        "https://example.com/a%20b",
        "https://example.com/文档",
        "mailto:user@example.com",
        "mailto:a@b.c",
        "ftp://example.com/file.txt",
        "ssh:user@example.com",
        "git://example.com/repo",
        "tel:+15551234567",
        "magnet:?xt=urn:btih:0123456789abcdef",
        "ipfs://bafyexample",
        "ipns://example.com",
        "gemini://example.com",
        "gopher://example.com",
        "news:comp.security.misc",
    }) |target| {
        try std.testing.expect(try App.isAllowedWin32OpenTarget(std.testing.allocator, target));
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a b.txt", .data = "ordinary document" });
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "a b.txt");
    defer std.testing.allocator.free(path);
    try std.testing.expect(try App.isAllowedWin32OpenTarget(std.testing.allocator, path));
    try tmp.dir.makeDir("directory");
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    for ([_][]const u8{ "./a b.txt", "directory/../a b.txt" }) |relative| {
        const navigation = try std.fs.path.join(std.testing.allocator, &.{ root, relative });
        defer std.testing.allocator.free(navigation);
        try std.testing.expect(try App.isAllowedWin32OpenTarget(std.testing.allocator, navigation));
    }
    const uri = try std.fmt.allocPrint(std.testing.allocator, "file://localhost/{s}", .{path});
    defer std.testing.allocator.free(uri);
    try std.testing.expect(try App.isAllowedWin32OpenTarget(std.testing.allocator, uri));
}

test "security regression win32 link opener rejects PATHEXT siblings and path aliases" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "probe.cmd", .data = "@exit /b 0\r\n" });
    try tmp.dir.writeFile(.{ .sub_path = "safe.txt", .data = "safe" });
    try tmp.dir.makeDir("directory");
    try tmp.dir.writeFile(.{ .sub_path = "directory/safe.txt", .data = "safe" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    for ([_][]const u8{ "probe", "safe.txt.", "safe.txt ", "probe.cmd.", "probe.cmd ", "directory./safe.txt", "directory /safe.txt", "directory./../safe.txt" }) |name| {
        const path = try std.fs.path.join(alloc, &.{ root, name });
        defer alloc.free(path);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, path));
        std.mem.replaceScalar(u8, path, '\\', '/');
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, path));
        const uri = try std.fmt.allocPrint(alloc, "file:///{s}", .{path});
        defer alloc.free(uri);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, uri));
    }
}

test "security regression win32 link opener preserves directories and extensionless text but rejects PE" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("directory.exe");
    try tmp.dir.writeFile(.{ .sub_path = "README", .data = "plain text" });
    try tmp.dir.writeFile(.{ .sub_path = "empty", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "binary", .data = "MZ\x00\x00" });
    for ([_][]const u8{ "directory.exe", "README", "empty", "binary" }) |name| {
        const path = try tmp.dir.realpathAlloc(alloc, name);
        defer alloc.free(path);
        try std.testing.expectEqual(!std.mem.eql(u8, name, "binary"), try App.isAllowedWin32OpenTarget(alloc, path));
    }
}

test "security regression win32 link opener rejects dangerous handler files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "rdp",          "library-ms", "searchConnector-ms", "diagcab",           "iso",   "img",       "vhd",       "vhdx",
        "appinstaller", "msix",       "appx",               "settingcontent-ms", "theme", "themepack", "xll",       "website",
        "jnlp",         "wsc",        "exe",                "cmd",               "lnk",   "ps1",       "search-ms", "wsb",
        "ica",          "wcx",
    }) |extension| {
        const name = try std.fmt.allocPrint(alloc, "dangerous.{s}", .{extension});
        defer alloc.free(name);
        try tmp.dir.writeFile(.{ .sub_path = name, .data = "fixture" });
        const path = try tmp.dir.realpathAlloc(alloc, name);
        defer alloc.free(path);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, path));
    }
    // Windows treats the whole leading-dot basename as its extension, unlike
    // std.fs.path.extension, which is intended to preserve Unix dotfiles.
    for ([_][]const u8{ ".cmd", ".rdp", ".exe", ".lnk", ".ps1" }) |name| {
        try tmp.dir.writeFile(.{ .sub_path = name, .data = "fixture" });
        const path = try tmp.dir.realpathAlloc(alloc, name);
        defer alloc.free(path);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, path));
        std.mem.replaceScalar(u8, path, '\\', '/');
        const uri = try std.fmt.allocPrint(alloc, "file:///{s}", .{path});
        defer alloc.free(uri);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, uri));
    }
}

/// For tests: `long` as GetShortPathNameW spells it, every component that has
/// an 8.3 alias shortened (the parent folders too).
const test_short_path = struct {
    extern "kernel32" fn GetShortPathNameW(long: [*:0]const u16, short: [*]u16, len: u32) callconv(.winapi) u32;

    fn of(alloc: Allocator, long: []const u8) ![]u8 {
        const long_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, long);
        defer alloc.free(long_w);
        var short_w: [windows.PATH_MAX_WIDE]u16 = undefined;
        const len = GetShortPathNameW(long_w.ptr, &short_w, short_w.len);
        if (len == 0 or len >= short_w.len) return error.Unexpected;
        return std.unicode.utf16LeToUtf8Alloc(alloc, short_w[0..len]);
    }
};

test "security regression win32 link opener screens the long name behind an 8.3 alias" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    // In the temp folder: the checkout's drive may make no 8.3 names (a
    // ReFS Dev Drive, a CI work drive).
    var tmp = try internal_os.TempDir.init();
    defer tmp.deinit();
    for ([_]struct { name: []const u8, allowed: bool }{
        // A leading-dot name's alias has no extension at all.
        .{ .name = ".cmd", .allowed = false },
        .{ .name = ".bat", .allowed = false },
        .{ .name = ".lnk", .allowed = false },
        .{ .name = ".url", .allowed = false },
        .{ .name = ".msi", .allowed = false },
        .{ .name = ".chm", .allowed = false },
        .{ .name = ".hta", .allowed = false },
        .{ .name = ".vbs", .allowed = false },
        // A longer extension keeps its first three letters.
        .{ .name = "payload.library-ms", .allowed = false },
        .{ .name = "payload.searchConnector-ms", .allowed = false },
        .{ .name = "payload.settingcontent-ms", .allowed = false },
        .{ .name = "payload.themepack", .allowed = false },
        .{ .name = "payload.diagcab", .allowed = false },
        .{ .name = "payload.website", .allowed = false },
        .{ .name = "payload.jnlp", .allowed = false },
        .{ .name = "payload.psm1", .allowed = false },
        .{ .name = "payload.psc1", .allowed = false },
        // A document stays openable by either name.
        .{ .name = "photo.jpeg", .allowed = true },
        .{ .name = ".gitignore", .allowed = true },
    }) |case| {
        try tmp.dir.writeFile(.{ .sub_path = case.name, .data = "fixture" });
        const long = try tmp.dir.realpathAlloc(alloc, case.name);
        defer alloc.free(long);
        const short = try test_short_path.of(alloc, long);
        defer alloc.free(short);
        if (std.mem.eql(u8, std.fs.path.basename(short), case.name)) {
            std.log.warn("no 8.3 alias for {s}; 8.3 names are off on this volume", .{case.name});
            return error.SkipZigTest;
        }
        errdefer std.debug.print("{s} as {s}\n", .{ case.name, std.fs.path.basename(short) });
        try std.testing.expectEqual(case.allowed, try App.isAllowedWin32OpenTarget(alloc, long));
        try std.testing.expectEqual(case.allowed, try App.isAllowedWin32OpenTarget(alloc, short));
        std.mem.replaceScalar(u8, short, '\\', '/');
        const uri = try std.fmt.allocPrint(alloc, "file:///{s}", .{short});
        defer alloc.free(uri);
        try std.testing.expectEqual(case.allowed, try App.isAllowedWin32OpenTarget(alloc, uri));
    }
}

test "security regression win32 link opener screens normalized navigation targets" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "probe.cmd", .data = "@exit /b 0\r\n" });
    try tmp.dir.writeFile(.{ .sub_path = "binary", .data = "MZ\x00\x00" });
    for ([_][]const u8{ "probe.cmd", "binary" }) |name| {
        const path = try tmp.dir.realpathAlloc(alloc, name);
        defer alloc.free(path);
        const navigation = try std.fmt.allocPrint(alloc, "{s}\\.", .{path});
        defer alloc.free(navigation);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, navigation));
        std.mem.replaceScalar(u8, navigation, '\\', '/');
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, navigation));
        const uri = try std.fmt.allocPrint(alloc, "file:///{s}", .{navigation});
        defer alloc.free(uri);
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(alloc, uri));
    }
}

test "security regression win32 link opener rejects unsafe schemes and executable files" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    for ([_][]const u8{
        "search-ms:query=*.exe",
        "ms-settings:privacy",
        "foo:custom-handler",
        "\\\\server\\share\\readme.txt",
        "//server/share/readme.txt",
        "file://server/share/readme.txt",
        "file:///C:/tmp/x.exe",
        "file:///C:/tmp/x%2Eexe",
        "file:///C:/tmp/x.ExE",
        "file:///C:/tmp/x.exe%20",
        "file:///C:/tmp/x.lnk",
        "file:///C:/tmp/x.url",
        "file:///C:/tmp/x%2Echm",
        "file:///C:/tmp/x.msc",
        "file:///C:/tmp/a%00.txt",
        "C:\\tmp\\x.cmd",
        "C:\\tmp\\x.chm",
        "C:\\tmp\\safe.txt:payload.exe",
        "relative/readme.txt",
        // An OSC 8 target can hold what a printed URL cannot: arguments for
        // the scheme's handler.
        "magnet:?xt=a\" --x \"",
        "ssh:host -oProxyCommand=x",
        "https://example.com/a\"b",
        "tel:+1 555",
        // Hidden or reordering characters, and text that is not UTF-8.
        "https://example.com/\u{202E}gnp.exe",
        "https://example.com/a\u{85}b",
        "https://example.com/a\u{200B}b",
        "https://example.com/\xff",
        // No host, no address.
        "https:payload",
        "https:///path",
        "mailto:",
    }) |target| {
        errdefer std.debug.print("target: \"{f}\"\n", .{std.zig.fmtString(target)});
        try std.testing.expect(!try App.isAllowedWin32OpenTarget(std.testing.allocator, target));
    }
}

test "security regression win32 link opener refuses a hidden control decoded from a file URI" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Shown as "invoicetxt.doc"; the control file differs by one character.
    try tmp.dir.writeFile(.{ .sub_path = "invoice\u{202E}cod.txt", .data = "text" });
    try tmp.dir.writeFile(.{ .sub_path = "invoice\u{6587}cod.txt", .data = "text" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    for ([_]struct { []const u8, bool }{
        .{ "%E2%80%AE", false },
        .{ "%E6%96%87", true },
    }) |case| {
        const uri = try std.fmt.allocPrint(alloc, "file:///{s}/invoice{s}cod.txt", .{ root, case[0] });
        defer alloc.free(uri);
        errdefer std.debug.print("target: {s}\n", .{uri});
        try std.testing.expectEqual(case[1], try App.isAllowedWin32OpenTarget(alloc, uri));
    }
}

test "security regression win32 link opener rejects before shell dispatch" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const DispatchProbe = struct {
        called: bool = false,

        fn dispatch(self: *@This(), _: []const u8) !void {
            self.called = true;
        }
    };

    var rejected: DispatchProbe = .{};
    try std.testing.expectError(
        error.OpenUrlRejected,
        App.openWin32Target(
            std.testing.allocator,
            &rejected,
            "search-ms:query=*.exe",
            DispatchProbe.dispatch,
        ),
    );
    try std.testing.expect(!rejected.called);

    var allowed: DispatchProbe = .{};
    try App.openWin32Target(
        std.testing.allocator,
        &allowed,
        "https://example.com",
        DispatchProbe.dispatch,
    );
    try std.testing.expect(allowed.called);
}

test "security regression win32 link opener dispatches the exact decoded file URI path" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a b%.txt", .data = "document" });
    const path = try tmp.dir.realpathAlloc(alloc, "a b%.txt");
    defer alloc.free(path);
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    std.mem.replaceScalar(u8, root, '\\', '/');
    const uri = try std.fmt.allocPrint(alloc, "file://localhost/{s}/a%20b%25.txt", .{root});
    defer alloc.free(uri);
    const Probe = struct {
        expected: []const u8,
        called: bool = false,
        fn dispatch(self: *@This(), target: []const u8) !void {
            const normalized = try std.testing.allocator.dupe(u8, target);
            defer std.testing.allocator.free(normalized);
            std.mem.replaceScalar(u8, normalized, '/', '\\');
            try std.testing.expectEqualStrings(self.expected, normalized);
            try std.testing.expect(try App.isAllowedWin32OpenTarget(std.testing.allocator, target));
            self.called = true;
        }
    };
    var probe: Probe = .{ .expected = path };
    try App.openWin32Target(alloc, &probe, uri, Probe.dispatch);
    try std.testing.expect(probe.called);
    // Navigation must be resolved before both inspection and dispatch.
    const navigation_uri = try std.fmt.allocPrint(alloc, "file://localhost/{s}/./a%20b%25.txt", .{root});
    defer alloc.free(navigation_uri);
    probe.called = false;
    try App.openWin32Target(alloc, &probe, navigation_uri, Probe.dispatch);
    try std.testing.expect(probe.called);
    const navigation_path = try std.fmt.allocPrint(alloc, "{s}/./a b%.txt", .{root});
    defer alloc.free(navigation_path);
    probe.called = false;
    try App.openWin32Target(alloc, &probe, navigation_path, Probe.dispatch);
    try std.testing.expect(probe.called);
}

test "security regression win32 link opener PATHEXT live probe on hidden desktop" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const enabled = std.process.getEnvVarOwned(std.testing.allocator, "NOCTTY_RUN_LINK_PATHEXT_PROBE") catch return error.SkipZigTest;
    defer std.testing.allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return error.SkipZigTest;

    const Probe = struct {
        extern "user32" fn CreateDesktopW(name: [*:0]const u16, device: ?*anyopaque, mode: ?*anyopaque, flags: u32, access: u32, attributes: ?*anyopaque) callconv(.winapi) ?*anyopaque;
        extern "user32" fn SetThreadDesktop(desktop: *anyopaque) callconv(.winapi) BOOL;
        extern "user32" fn CloseDesktop(desktop: *anyopaque) callconv(.winapi) BOOL;

        calls: usize = 0,
        fn dispatch(self: *@This(), target: []const u8) !void {
            self.calls += 1;
            try shell(target);
        }
        fn shell(target: []const u8) !void {
            const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, target);
            defer std.testing.allocator.free(wide);
            const result = sys.ShellExecuteW(null, shell_open, wide.ptr, null, null, c.SW_HIDE);
            if (@intFromPtr(result) <= 32) return error.OpenUrlFailed;
        }
        /// Waits up to five seconds for `probe.cmd` to write its marker, then
        /// removes it for the next check.
        fn expectMarker(dir: std.fs.Dir) !void {
            var seen = false;
            for (0..100) |_| {
                dir.access("marker", .{}) catch {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    continue;
                };
                seen = true;
                break;
            }
            try std.testing.expect(seen);
            try dir.deleteFile("marker");
        }
        fn run(desktop: *anyopaque, result: *anyerror!void) void {
            result.* = body(desktop);
        }
        fn body(desktop: *anyopaque) !void {
            if (SetThreadDesktop(desktop) == 0) return lastError();
            const alloc = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            // This is the only executable supplied to ShellExecute: a harmless
            // marker command inside this test's own temporary directory.
            try tmp.dir.writeFile(.{ .sub_path = "probe.cmd", .data = "@echo off\r\necho ran>\"%~dp0marker\"\r\nexit /b 0\r\n" });
            const root = try tmp.dir.realpathAlloc(alloc, ".");
            defer alloc.free(root);
            const path = try std.fs.path.join(alloc, &.{ root, "probe" });
            defer alloc.free(path);
            for ([_]bool{ false, true }) |forward_slashes| {
                if (forward_slashes) std.mem.replaceScalar(u8, path, '\\', '/');
                // Positive control proves this host's ShellExecute really
                // retries the missing literal with probe.cmd, for both slashes.
                try shell(path);
                try expectMarker(tmp.dir);
                var probe: @This() = .{};
                try std.testing.expectError(error.OpenUrlRejected, App.openWin32Target(alloc, &probe, path, dispatch));
                try std.testing.expectEqual(@as(usize, 0), probe.calls);
                try std.testing.expectError(error.FileNotFound, tmp.dir.access("marker", .{}));
            }
            const uri = try std.fmt.allocPrint(alloc, "file:///{s}", .{path});
            defer alloc.free(uri);
            // Unlike a plain path, the raw file URI did not PATHEXT-retry.
            try std.testing.expectError(error.OpenUrlFailed, shell(uri));
            var probe: @This() = .{};
            try std.testing.expectError(error.OpenUrlRejected, App.openWin32Target(alloc, &probe, uri, dispatch));
            try std.testing.expectEqual(@as(usize, 0), probe.calls);
            try std.testing.expectError(error.FileNotFound, tmp.dir.access("marker", .{}));

            try tmp.dir.copyFile("probe.cmd", tmp.dir, ".cmd", .{});
            const dotfile = try std.fs.path.join(alloc, &.{ root, ".cmd" });
            defer alloc.free(dotfile);
            try shell(dotfile);
            try expectMarker(tmp.dir);
            probe = .{};
            try std.testing.expectError(error.OpenUrlRejected, App.openWin32Target(alloc, &probe, dotfile, dispatch));
            std.mem.replaceScalar(u8, dotfile, '\\', '/');
            const dotfile_uri = try std.fmt.allocPrint(alloc, "file:///{s}", .{dotfile});
            defer alloc.free(dotfile_uri);
            try std.testing.expectError(error.OpenUrlRejected, App.openWin32Target(alloc, &probe, dotfile_uri, dispatch));
            try std.testing.expectEqual(@as(usize, 0), probe.calls);
            try std.testing.expectError(error.FileNotFound, tmp.dir.access("marker", .{}));
        }
    };
    const name = try std.fmt.allocPrint(std.testing.allocator, "noctty-link-probe-{}", .{windows.GetCurrentProcessId()});
    defer std.testing.allocator.free(name);
    const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, name);
    defer std.testing.allocator.free(wide_name);
    const desktop = Probe.CreateDesktopW(wide_name.ptr, null, null, 0, 0x10000000, null) orelse return lastError();
    defer _ = Probe.CloseDesktop(desktop);
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{}, Probe.run, .{ desktop, &result });
    thread.join();
    try result;
    // A successful filtered build is not proof this named test ran. The
    // wrapper supplies a fresh receipt path and requires this final sentinel.
    const receipt_path = try std.process.getEnvVarOwned(std.testing.allocator, "NOCTTY_LINK_PATHEXT_PROBE_RECEIPT");
    defer std.testing.allocator.free(receipt_path);
    if (!windows_shell.isSafeWindowsPath(receipt_path) or
        !windows_shell.isDriveAbsolutePath(receipt_path) or
        internal_os.path.isNetworkOrDevicePath(receipt_path)) return error.UnsafeProbeReceiptPath;
    const receipt = try std.fs.createFileAbsolute(receipt_path, .{ .exclusive = true });
    defer receipt.close();
    try receipt.writeAll("NOCTTY_LINK_PATHEXT_PROBE_COMPLETE\n");
}

test "win32 recovery ready marker keeps retrying transient write failures" {
    // A failed attempt must not resolve the launch: latching on the first
    // failure is what leaves an unresolved attempt on disk for the whole
    // session and feeds a false safe-mode streak.
    var transient: RecoveryReadyRetry = .{};
    try std.testing.expect(!transient.recordFailure(error.AccessDenied));
    try std.testing.expect(!transient.recordFailure(error.Unexpected));
    try std.testing.expectEqual(@as(u8, 2), transient.failures);

    // The budget is bounded: the third failure gives up.
    try std.testing.expect(transient.recordFailure(error.AccessDenied));
    try std.testing.expectEqual(recovery_ready_persist_attempts, transient.failures);

    // OutOfMemory stops immediately without spending the budget.
    var oom: RecoveryReadyRetry = .{};
    try std.testing.expect(oom.recordFailure(error.OutOfMemory));
    try std.testing.expectEqual(@as(u8, 1), oom.failures);
}

test "win32 recovery ready marker schedules a bounded number of retries" {
    // `GetMessageW` blocks, so an attempt that is not scheduled simply never
    // runs; an unbounded schedule would spin the loop instead. Drive the same
    // decision `resolveRecoveryStartup` makes: arm another timer only while
    // the budget survives.
    var retry: RecoveryReadyRetry = .{};
    var attempts: u8 = 0;
    var scheduled: u8 = 0;
    while (true) {
        attempts += 1;
        if (retry.recordFailure(error.AccessDenied)) break;
        scheduled += 1;
        try std.testing.expect(scheduled < recovery_ready_persist_attempts);
    }
    try std.testing.expectEqual(recovery_ready_persist_attempts, attempts);
    try std.testing.expectEqual(recovery_ready_persist_attempts - 1, scheduled);

    // OutOfMemory resolves on the first failure, so it arms no timer at all.
    var oom: RecoveryReadyRetry = .{};
    try std.testing.expect(oom.recordFailure(error.OutOfMemory));
}

test "win32 safe mode notice waits for the launch to resolve on disk" {
    // Never armed outside safe mode.
    var normal: RecoverySafeModeNotice = .{};
    normal.arm(.normal);
    try std.testing.expect(!normal.release(true));
    var set_aside: RecoverySafeModeNotice = .{};
    set_aside.arm(.quarantine_session);
    try std.testing.expect(set_aside.release(true));

    var safe: RecoverySafeModeNotice = .{};
    safe.arm(.safe_mode);
    // Held back while the ledger still holds an unresolved attempt, so a
    // process killed at the dialog has already broken the failure streak.
    try std.testing.expect(!safe.release(false));
    try std.testing.expect(!safe.released);
    try std.testing.expect(safe.release(true));
    // Every later tick calls this; the dialog must spawn exactly once.
    try std.testing.expect(!safe.release(true));
}

test "win32 a refused toast becomes a banner that names its tab once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var w: ToastTestWindow = .{};
    try w.init(false);
    defer w.deinit();
    // As when notifications are turned off for noctty in Windows Settings.
    w.recorder.refuse = error.NotifierDisabled;

    // An untitled OSC 9 toast is titled by its tab, but the banner does not
    // repeat the tab's title before the tab line.
    try w.osc(&w.p, "", "tests passed");
    try w.recorder.expect(.title, "cargo build");
    try std.testing.expectEqual(HostBannerKind.info, w.host.banner_kind);
    try std.testing.expectEqualStrings("tests passed \u{2014} Tab 2: cargo build", w.host.banner_text.?);

    try w.osc(&w.p, "deploy", "rolled out");
    try std.testing.expectEqualStrings("deploy: rolled out \u{2014} Tab 2: cargo build", w.host.banner_text.?);

    // The core's clipboard-copy notice arrives from its pane exactly as an
    // OSC 777 titled "noctty" would, so it names its tab and focuses the
    // pane like any other toast from a pane.
    try w.osc(&w.front, "noctty", "Copied selection to clipboard");
    try w.recorder.expect(.title, "noctty");
    try w.recorder.expect(.attribution, "Tab 1: pwsh");
    try w.recorder.expectLaunchFor(&w.front, 1);
    try std.testing.expectEqualStrings("Copied selection to clipboard \u{2014} Tab 1: pwsh", w.host.banner_text.?);

    // An app notification names no tab; one with only a title (a Settings
    // save) is its title.
    try std.testing.expect(try w.app.performAction(.app, .desktop_notification, .{
        .title = "",
        .body = "Configuration reloaded",
    }));
    try std.testing.expectEqualStrings("Configuration reloaded", w.host.banner_text.?);
    try std.testing.expect(try w.app.performAction(.app, .desktop_notification, .{
        .title = "Settings saved",
        .body = "",
    }));
    try std.testing.expectEqualStrings("Settings saved", w.host.banner_text.?);
    try std.testing.expectEqual(@as(usize, 5), w.recorder.shown);

    // With no window to hold a banner the same text goes to the log.
    var line: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer line.deinit();
    try App.composeToastFallback(&line.writer, "claude is done", "", "Tab 2: cargo build");
    try std.testing.expectEqualStrings("claude is done \u{2014} Tab 2: cargo build", line.written());
}

test "win32 exit removes this process's group only" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var group_buf: [toast_group_max]u8 = undefined;
    var line_buf: [64]u8 = undefined;
    const own_group = try std.fmt.bufPrint(&line_buf, "group {s}", .{toastGroup(&group_buf)});

    var recorder: TestToastRecorder = .{};
    defer recorder.deinit();

    // A process that showed no toast makes no history call at exit.
    {
        var core = try CoreApp.create(std.testing.allocator);
        defer core.destroy();
        var app: App = undefined;
        try app.init(core, .{});
        app.toast_sink = recorder.sink();
        app.terminate();
        try recorder.expectRemovals(&.{});
    }

    // One that did removes its own group, in one call, and nothing else:
    // not one removal per pane, and never the AUMID-wide `Clear`, which
    // would take other noctty processes' toasts too.
    {
        var core = try CoreApp.create(std.testing.allocator);
        defer core.destroy();
        var app: App = undefined;
        try app.init(core, .{});
        app.toast_sink = recorder.sink();
        // As after a toast from a pane that has closed since: its removal
        // is queued, and exit makes it part of the group's.
        app.noteToastShown(0x2002);
        try std.testing.expectEqual(@as(usize, 1), app.toast_removals.items.len);
        app.terminate();
        try recorder.expectRemovals(&.{own_group});
    }
}

test "win32 commandFinishPlan enforces threshold and focus policy" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();
    cfg.@"notify-on-command-finish" = .unfocused;
    cfg.@"notify-on-command-finish-action" = .{ .bell = true, .notify = true };
    cfg.@"notify-on-command-finish-after" = .{ .duration = 5 * std.time.ns_per_s };

    const focused_plan = App.commandFinishPlan(cfg.@"notify-on-command-finish", cfg.@"notify-on-command-finish-action", cfg.@"desktop-notifications", cfg.@"notify-on-command-finish-after", true, .{
        .duration = 6 * std.time.ns_per_s,
    });
    try std.testing.expectEqual(false, focused_plan.bell);
    try std.testing.expectEqual(false, focused_plan.notify);

    const unfocused_plan = App.commandFinishPlan(cfg.@"notify-on-command-finish", cfg.@"notify-on-command-finish-action", cfg.@"desktop-notifications", cfg.@"notify-on-command-finish-after", false, .{
        .duration = 6 * std.time.ns_per_s,
    });
    try std.testing.expectEqual(true, unfocused_plan.bell);
    try std.testing.expectEqual(true, unfocused_plan.notify);

    const short_plan = App.commandFinishPlan(cfg.@"notify-on-command-finish", cfg.@"notify-on-command-finish-action", cfg.@"desktop-notifications", cfg.@"notify-on-command-finish-after", false, .{
        .duration = 4 * std.time.ns_per_s,
    });
    try std.testing.expectEqual(false, short_plan.bell);
    try std.testing.expectEqual(false, short_plan.notify);
}

test "win32 commandFinishPlan disables desktop notify when desktop notifications are off" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var cfg = try configpkg.Config.default(std.testing.allocator);
    defer cfg.deinit();
    cfg.@"notify-on-command-finish" = .always;
    cfg.@"notify-on-command-finish-action" = .{ .bell = true, .notify = true };
    cfg.@"desktop-notifications" = false;

    const plan = App.commandFinishPlan(cfg.@"notify-on-command-finish", cfg.@"notify-on-command-finish-action", cfg.@"desktop-notifications", cfg.@"notify-on-command-finish-after", false, .{
        .duration = 10 * std.time.ns_per_s,
    });
    try std.testing.expectEqual(true, plan.bell);
    try std.testing.expectEqual(false, plan.notify);
}

test "win32 gotoSplitFallback maps only previous and next" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try std.testing.expect(App.gotoSplitFallbackDirection(.previous) != null);
    try std.testing.expect(App.gotoSplitFallbackDirection(.next) != null);
    try std.testing.expect(App.gotoSplitFallbackDirection(.left) == null);
    try std.testing.expect(App.gotoSplitFallbackDirection(.right) == null);
}
