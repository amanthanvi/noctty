//! Win32 application lifecycle and coordination.
const win32 = @import("../win32.zig");
const ATOM = win32.ATOM;
const Allocator = win32.Allocator;
const AppDelivery = win32.AppDelivery;
const ClipboardSource = win32.ClipboardSource;
const CloseScope = confirm_text.CloseScope;
const ConfirmCancelReason = @import("overlay_session.zig").ConfirmCancelReason;
const CoreApp = @import("../../App.zig");
const DWORD = win32.DWORD;
const GlobalHotkeySpec = win32.GlobalHotkeySpec;
const HDC = win32.HDC;
const HGLRC = win32.HGLRC;
const HINSTANCE = win32.HINSTANCE;
const HWND = win32.HWND;
const Host = win32.Host;
const Registry = @import("registry.zig").Registry;
const HostBannerKind = win32.HostBannerKind;
const LPARAM = win32.LPARAM;
const LPCWSTR = win32.LPCWSTR;
const MSG = win32.MSG;
const NONCLIENTMETRICSW = win32.NONCLIENTMETRICSW;
const OpenGLStartupStep = win32.OpenGLStartupStep;
const OpenTarget = profile_pick.OpenTarget;
const PaletteCatalog = win32.PaletteCatalog;
const ProfileDiscoveryCompletion = win32.ProfileDiscoveryCompletion;
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
const UINT = win32.UINT;
const UINT_PTR = win32.UINT_PTR;
const UpdateCheckCompletion = win32.UpdateCheckCompletion;
const UpdateCheckRequest = win32.UpdateCheckRequest;
const UpdateNotice = win32.UpdateNotice;
const WNDCLASSEXW = win32.WNDCLASSEXW;
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
const confirm_text = @import("confirm_text.zig");
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
const notifications = @import("notifications.zig");
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
const profile_pick = @import("profile_pick.zig");
const ptypkg = @import("../../pty.zig");
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
const tab_label = @import("tab_label.zig");
const tab_tooltip_class_name = win32.tab_tooltip_class_name;
const tabsCloseConfirmCount = win32.tabsCloseConfirmCount;
const tabsCloseConfirmCountNoWait = win32.tabsCloseConfirmCountNoWait;
const toastActivatorSink = win32.toastActivatorSink;
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
const save_target = @import("save_target.zig");
const win32_shell = @import("../win32_shell.zig");
const win32_structural_history = @import("../win32_structural_history.zig");
const win32_taskbar_progress = @import("../win32_taskbar_progress.zig");
const win32_terminal_handoff = @import("../win32_terminal_handoff.zig");
const win32_toast_activation = @import("../win32_toast_activation.zig");
const win32_toast_activator = @import("../win32_toast_activator.zig");
const win32_toast_winrt = @import("../win32_toast_winrt.zig");
const win32_uia = @import("../win32_uia/mod.zig");
const windowNewTabInsertIndex = win32.windowNewTabInsertIndex;
const windowProc = win32.windowProc;
const window_state = @import("window_state.zig");
const window_start = @import("window_start.zig");
const tab_drag = @import("tab_drag.zig");
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
const InitialShow = window_state.InitialShow;
const POINT = win32.POINT;
const ToastTestWindow = win32.ToastTestWindow;
const toastTestSplit = win32.toastTestSplit;
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

/// A link or path the opener refused: missing, a program or script, or on the
/// network.
const open_refused_banner = "Not opened: only known link types and existing documents or folders can be opened.";

/// The banner for the last tab of a window being closed. It names the key bound
/// to `undo` (the first one found, in the way a hint is written: `Ctrl+Shift+Z`)
/// and falls back when `undo` is unbound or customization makes dispatch ambiguous.
/// With `undo-timeout = 0` nothing can be restored, so it offers nothing.
fn tabClosedMessage(set: *const input.Binding.Set, options: struct { has_modifier_remaps: bool = false, us_layout: bool = false, undo_available: bool = true }, buf: []u8) []const u8 {
    if (!options.undo_available) return "Tab closed.";
    const fallback = "Tab closed. Use undo to restore it.";
    if (options.has_modifier_remaps) return fallback;
    var it = set.bindings.iterator();
    const trigger = while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .leaf => |leaf| if (leaf.action == .undo) break entry.key_ptr.*,
            else => {},
        }
    } else return fallback;

    switch (trigger.key) {
        .unicode => |cp| {
            // Only the exact US layout establishes these physical/text
            // identities. Other layouts (including US-International and
            // Turkish Q) can produce this letter from a different key or
            // different shifted text, so use generic wording there.
            if (!options.us_layout) return fallback;
            if (cp < 'a' or cp > 'z') return fallback;
            var overrides = set.bindings.iterator();
            while (overrides.next()) |entry| {
                if (!entry.key_ptr.mods.binding().equal(trigger.mods.binding())) continue;
                switch (entry.key_ptr.key) {
                    .physical => |key| if (key == input.Key.fromASCII(@intCast(cp)).?) return fallback,
                    .unicode => |other| if (other == std.ascii.toUpper(@intCast(cp)) or
                        (trigger.mods.ctrl and other == (cp & 0x1f))) return fallback,
                    .catch_all => {},
                }
            }
        },
        .physical => |key| if (key.printable()) return fallback,
        .catch_all => return fallback,
    }

    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll("Tab closed. Press ") catch return fallback;
    const key_start = writer.end;
    writer.print("{f}", .{trigger}) catch return fallback;
    // `Trigger.format` writes the config spelling, `ctrl+shift+z`.
    for (buf[key_start..writer.end], key_start..) |*byte, i| {
        if (i == key_start or buf[i - 1] == '+') byte.* = std.ascii.toUpper(byte.*);
    }
    writer.writeAll(" to undo.") catch return fallback;
    return writer.buffered();
}

test "tabClosedMessage names the key bound to undo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [96]u8 = undefined;

    var set: input.Binding.Set = .{};
    try std.testing.expectEqualStrings(
        "Tab closed. Use undo to restore it.",
        tabClosedMessage(&set, .{ .us_layout = true }, &buf),
    );

    try set.put(arena.allocator(), .{ .key = .{ .unicode = 't' }, .mods = .{ .ctrl = true } }, .{ .new_tab = {} });
    try std.testing.expectEqualStrings(
        "Tab closed. Use undo to restore it.",
        tabClosedMessage(&set, .{ .us_layout = true }, &buf),
    );

    try set.putFlags(
        arena.allocator(),
        .{ .key = .{ .unicode = 'z' }, .mods = .{ .ctrl = true, .shift = true } },
        .{ .undo = {} },
        .{ .performable = true },
    );
    try std.testing.expectEqualStrings(
        "Tab closed. Press Ctrl+Shift+Z to undo.",
        tabClosedMessage(&set, .{ .us_layout = true }, &buf),
    );

    // `undo-timeout = 0`: bound or not, there is nothing to undo.
    try std.testing.expectEqualStrings(
        "Tab closed.",
        tabClosedMessage(&set, .{ .us_layout = true, .undo_available = false }, &buf),
    );
    var unbound: input.Binding.Set = .{};
    try std.testing.expectEqualStrings(
        "Tab closed.",
        tabClosedMessage(&unbound, .{ .undo_available = false }, &buf),
    );

    // A physical key, and a buffer too small for the hint.
    var other: input.Binding.Set = .{};
    try other.put(arena.allocator(), .{ .key = .{ .physical = .f9 }, .mods = .{ .alt = true } }, .{ .undo = {} });
    try std.testing.expectEqualStrings(
        "Tab closed. Press Alt+F9 to undo.",
        tabClosedMessage(&other, .{ .us_layout = true }, &buf),
    );
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Tab closed. Use undo to restore it.",
        tabClosedMessage(&other, .{ .us_layout = true }, &tiny),
    );
}

test "PKG32 tabClosedMessage does not advertise a shadowed or remapped undo chord" {
    var cfg = try @import("../../config.zig").Config.default(std.testing.allocator);
    defer cfg.deinit();
    var buf: [96]u8 = undefined;
    const fallback = "Tab closed. Use undo to restore it.";
    const set = &cfg.keybind.set;
    try set.put(cfg._arena.?.allocator(), .{
        .key = .{ .physical = .key_z },
        .mods = .{ .ctrl = true, .shift = true },
    }, .ignore);
    try std.testing.expectEqualStrings(fallback, tabClosedMessage(set, .{ .us_layout = true }, &buf));

    // Restore an unambiguous default, then introduce an actual modifier map.
    set.remove(cfg._arena.?.allocator(), .{ .key = .{ .physical = .key_z }, .mods = .{ .ctrl = true, .shift = true } });
    try std.testing.expectEqualStrings("Tab closed. Press Ctrl+Shift+Z to undo.", tabClosedMessage(set, .{ .us_layout = true }, &buf));
    for ([_]u21{ 'Z', 0x1a }) |cp| {
        const trigger: input.Binding.Trigger = .{ .key = .{ .unicode = cp }, .mods = .{ .ctrl = true, .shift = true } };
        try set.put(cfg._arena.?.allocator(), trigger, .ignore);
        try std.testing.expectEqualStrings(fallback, tabClosedMessage(set, .{ .us_layout = true }, &buf));
        set.remove(cfg._arena.?.allocator(), trigger);
    }
    try cfg.@"key-remap".parse(cfg._arena.?.allocator(), "ctrl=alt");
    try std.testing.expectEqualStrings(
        fallback,
        tabClosedMessage(set, .{ .us_layout = true, .has_modifier_remaps = cfg.@"key-remap".map.count() != 0 }, &buf),
    );
}

test "PKG32 tabClosedMessage falls back for layout-dependent physical and text overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var set: input.Binding.Set = .{};
    const mods: input.Mods = .{ .ctrl = true, .shift = true };
    try set.put(alloc, .{ .key = .{ .unicode = 'i' }, .mods = mods }, .undo);
    const physical: input.Binding.Trigger = .{ .key = .{ .physical = .quote }, .mods = mods };
    try set.put(alloc, physical, .ignore);
    // Turkish Q: the dotted i is VK_OEM_7 and its shifted text is U+0130.
    const event: input.KeyEvent = .{
        .action = .press,
        .key = .quote,
        .mods = mods,
        .unshifted_codepoint = 'i',
        .utf8 = "İ",
    };
    var buf: [96]u8 = undefined;
    const fallback = "Tab closed. Use undo to restore it.";
    try std.testing.expectEqual(input.Binding.Action.ignore, set.getEvent(event).?.value_ptr.leaf.action);
    try std.testing.expectEqualStrings(fallback, tabClosedMessage(&set, .{}, &buf));
    set.remove(alloc, physical);
    try set.put(alloc, .{ .key = .{ .unicode = 'İ' }, .mods = mods }, .ignore);
    try std.testing.expectEqual(input.Binding.Action.ignore, set.getEvent(event).?.value_ptr.leaf.action);
    try std.testing.expectEqualStrings(fallback, tabClosedMessage(&set, .{}, &buf));
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
    /// Set while a config change goes to every pane and then to the app
    /// (`updateCoreConfig`; the palette's theme swap,
    /// `Host.swapRuntimeConfigFromPalette`). A pane's `.surface`
    /// `config_change` then leaves the window half to the app-wide step,
    /// which applies it for every window once, after the theme's frame write
    /// (`window_state.applyConfig`).
    app_wide_config_change: bool = false,
    /// Set once an app-wide change reaches the `.app` arm's window pass, so
    /// `updateCoreConfig` knows whether an update that failed before it
    /// still owes the windows their half.
    app_wide_windows_applied: bool = false,
    resolved_theme: ThemeColors = darkTheme(),
    /// Completed `reconfigureTheme` passes; a test reads it to prove that a
    /// settings preview which cannot change the theme does not run one.
    theme_rebuilds: u32 = 0,
    system_theme_refresh: SystemThemeRefresh = .{},
    /// The system's own theme inputs at the last system theme message (or
    /// at `init`): a failed blur-behind tries again only when they changed.
    /// Set by `init` and `takeSystemInputs`, which a system theme message
    /// runs (`reconfigureSystemTheme`, and `systemColorSetChanged` before a
    /// light/dark reload). Unlike `system_theme_refresh`, no rebuild of the
    /// app's own (a reload, a Settings preview) moves it.
    system_inputs: ?window_state.SystemInputs = null,
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
    /// tab, shell and unwind steps around them run for real. A pane it made
    /// has no core to update a config of, so while it is set a config update
    /// (`updatePaneCoreConfig`, `updateCoreConfig`) gives each pane what
    /// core's update ends in for it: its `.surface` `config_change`.
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
    launcher_quick_slot_keys: [profile_pick.quick_slots]?[:0]const u8 = @splat(null),
    launcher_profile_target: OpenTarget = .tab,
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
    /// The label by the pointer while a tab is dragged out of its strip
    /// (`showTabDragFeedback`), made at the first such drag.
    tab_drag_preview_hwnd: ?HWND = null,
    /// Esc ended a tab drag; its key-up is taken too, so no terminal sees a
    /// release it never saw pressed.
    tab_drag_escape_down: bool = false,
    /// A tab left mid-drag while its button was down (`Host.destroyTabButton`,
    /// `Host.giveTab`): its release, which can land in any window now that
    /// the capture is gone, is taken by the pump (`takeHeldRelease`).
    held_release_pending: bool = false,
    /// The message the outer pump is dispatching now, or 0 while it waits
    /// (`noteTabMoveWake`).
    outer_dispatch_message: UINT = 0,
    /// The thread timer that wakes the pump again for a waiting tab move a
    /// nested loop took the wake of: one for the App, whichever windows the
    /// wakes went to (`noteTabMoveWake`).
    tab_move_wake_timer: ?UINT_PTR = null,
    /// Tab moves asked of windows, in order, one per tab, run by the outer
    /// message pump (`drainPendingTabMoves`), never from inside a handler or
    /// a nested modal loop: a move can free the window it was asked of. As
    /// many as there are tabs, since an `all:` binding queues each before the
    /// pump runs any.
    pending_tab_moves: std.ArrayListUnmanaged(PendingTabMove) = .empty,
    /// The label's UIA element (`live_text`): it says what a drop does.
    tab_drag_preview_uia_provider: ?*win32_uia.ChromeControlProvider = null,
    /// What a drop does, as the label says it (`tabDragLabelAction`).
    tab_drag_label_action: []const u8 = "",
    /// The label's whole text, which its UIA element reads.
    tab_drag_label_text: [256]u8 = undefined,
    tab_drag_label_len: usize = 0,
    tab_drag_preview_prev_proc: ?*const anyopaque = null,
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
    /// are owned by `core_app.alloc` and freed in `App.deinit`. The
    /// palette's hint names the newest when the query is empty
    /// (`overlay_view.compose`, through `Host.overlayFacts`).
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
    /// case `notifications` falls back to the in-app banner path. One
    /// notifier per App, released in `App.terminate`.
    winrt_toast: ?win32_toast_winrt.WinrtToast = null,
    /// What noctty tells the user through toasts, and when a toast leaves
    /// Action Center (`notifications.zig`), with `winrt_toast` as its sink
    /// once `init` has one.
    notifications: notifications.Notifications = .disabled,
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
    /// What the check before a Settings save (`settingsReconcileDisk`) read of
    /// the file the save writes, and whether that check may apply a changed
    /// file (the window's, which offers the choice) or only refuse (the
    /// palette's theme pick). The save takes it: an edit another program made
    /// in between is not written over (SETTINGS-SAVE-TOCTOU).
    settings_check: ?SettingsCheck = null,
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
    /// Started by COM for a click in Action Center (`win32_toast_activator`,
    /// argv `-ToastActivated -Embedding`): `run` waits for the launch string
    /// before deciding whether to forward it or start locally.
    toast_activated: bool = false,
    /// What a cold `-ToastActivated` start received, forwarded to the running
    /// instance in place of this process's argv
    /// (`ipc_server.tryForwardStartupToExistingInstance`).
    cold_toast_activation: ?win32_toast_activation.ActivationTarget = null,
    /// `run` has made its startup windows (or decided on none), so a toast
    /// click with no surface to present opens one
    /// (`openWindowForToastClick`).
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
        // host banner/log path in `notifications`.
        // MUST run AFTER `setProcessAumid` so `CreateToastNotifierWithId`
        // attributes toasts to our AUMID. A test build never creates one, so
        // no test can reach Action Center; tests give `notifications` a
        // recorder as its sink instead.
        const aumid_utf16 = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");
        self.winrt_toast = if (builtin.is_test) null else win32_toast_winrt.WinrtToast.init(core_app.alloc, aumid_utf16) catch |err| blk: {
            std.log.warn("winrt toast init failed err={}; falling back to host notifications", .{err});
            break :blk null;
        };
        const sink: ?notifications.ToastSink = if (self.winrt_toast) |*toast| .winrt(toast) else null;
        self.notifications = .init(core_app.alloc, sink, self.notificationPanes());
        // A `wgh://activate?...` argument on the command line. Windows never
        // starts noctty with one: a click in Action Center reaches a cold
        // start through COM (`-ToastActivated`, `awaitColdToastActivation`).
        // It is honored for a launch by hand or a script, and the same string
        // is what a cold start forwards to a running instance. Silent on
        // absence or malformed input.
        if (scanToastActivationArg(core_app.alloc)) |target| {
            log.info("toast activation received surface={?} tab={?} window={?} action={?}", .{
                target.surface_id,
                target.tab_id,
                target.window_id,
                target.action,
            });
            _ = self.notifications.click(.{ .start = target });
        }

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
        // The first system theme message compares with the theme the app
        // starts in, as later ones do with the last rebuild.
        const start_theme = SystemThemeSnapshot.capture(&self.config);
        self.system_theme_refresh.previous = start_theme;
        self.resolved_theme = start_theme.theme;
        self.system_inputs = window_state.SystemInputs.capture();
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
            .os_build = self.os_build,
            .openInEditor = &settingsOpenInEditorThunk,
            .copyText = &settingsCopyTextThunk,
            .currentConfig = &settingsCurrentConfigThunk,
            .saveAndReload = &settingsSaveAndReloadThunk,
            .configRevision = &settingsConfigRevisionThunk,
            .previewField = &settingsPreviewFieldThunk,
            .endPreviews = &settingsEndPreviewsThunk,
            .notifyConflict = &settingsNotifyConflictThunk,
            .reconcileDisk = &settingsReconcileDiskThunk,
            .failureDetail = &settingsFailureDetailThunk,
            .maskedKeys = &settingsMaskedKeysThunk,
            .saveTarget = &settingsSaveTargetThunk,
            .configSource = &settingsConfigSourceThunk,
            .configProblems = &settingsConfigProblemsThunk,
            .profileChoices = &settingsProfileChoicesThunk,
            .pageProfiles = &settingsProfileChoicesThunk,
            .findAllProfiles = &settingsFindAllProfiles,
            .profileListsForeign = &settingsProfileListsForeign,
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
            _ = self.notifications.click(.{ .start = activation });
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
            // Tab moves, with no window procedure on the stack.
            self.drainPendingTabMoves();
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
                if (self.takeTabMoveWakeTick(&msg)) continue;
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

            if (self.cancelTabDragForKey(&msg)) continue;
            if (self.takeHeldRelease(&msg)) continue;

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
            self.outer_dispatch_message = msg.message;
            _ = sys.DispatchMessageW(&msg);
            self.outer_dispatch_message = 0;

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
        win32.detachChromeControlProvider(self, &self.tab_drag_preview_uia_provider);
        self.pending_tab_moves.deinit(self.core_app.alloc);
        killThreadTimer(&self.tab_move_wake_timer);
        if (self.tab_drag_preview_hwnd) |preview| {
            setWindowData(preview, null);
            if (self.tab_drag_preview_prev_proc) |previous| _ = sys.SetWindowLongPtrW(preview, c.GWLP_WNDPROC, @bitCast(@intFromPtr(previous)));
            self.tab_drag_preview_prev_proc = null;
            _ = sys.DestroyWindow(preview);
            self.tab_drag_preview_hwnd = null;
        }
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
        self.settings_window.handle.endPreviews = null;
        self.settings_window.deinit();
        self.dropSettingsPreview();
        const uia_disconnect_hr = win32_uia.disconnectAllProviders();
        if (uia_disconnect_hr != 0) {
            log.warn("win32 UIA disconnect-all failed hr=0x{x}", .{@as(u32, @bitCast(uia_disconnect_hr))});
        }
        // After `destroyAllWindows`, whose closes left their panes' toasts:
        // one call removes them all, while the notifier is still alive.
        self.notifications.deinit();
        self.notifications = .disabled;
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

    pub const restoreSessionTab = session_module.restoreSessionTab;

    pub const restoreSessionPane = session_module.restoreSessionPane;

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

    /// `AppHandle.findAllProfiles`: the Profiles page needs the whole list to
    /// move or hide a profile, and no window has it (a discovery ended
    /// without it: a probe timed out, the SSH config was busy). The first
    /// window asks the discovery worker again, unless it is waiting for one;
    /// the list reaches the page through `profilesChanged`. A window that
    /// has the whole list already is read at once.
    fn settingsFindAllProfiles(ctx: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.registry.hosts.items) |host| if (host.profiles_complete and host.profiles != null) {
            return self.settings_window.profilesChanged();
        };
        if (self.registry.hosts.items.len == 0) return;
        const host = self.registry.hosts.items[0];
        if (!host.profiles_requested) host.requestProfiles();
    }

    /// `AppHandle.profileListsForeign`: whether another layer than the file a
    /// Save writes sets the profiles' order or visibility in the running
    /// config (`settings_patch.listsForeign`). A check that cannot be made
    /// (no memory, no path) counts as refused.
    fn settingsProfileListsForeign(ctx: *anyopaque) ?settings_patch.ListsForeign {
        const self: *App = @ptrCast(@alignCast(ctx));
        const alloc = self.core_app.alloc;
        // The path only: looking must not create the file or its folder.
        const target = self.settingsTargetPathForDisplay(alloc) catch return .unread;
        defer alloc.free(target);
        return settings_patch.listsForeign(&self.config, target, &settings_reference.samePath) catch .unread;
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
                        switch (self.notifications.click(.{ .target = activation })) {
                            .done => return true,
                            .needs_window => forwarded_arguments = null,
                        }
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
                    .window = .from(source, forwarded_arguments orelse &.{}),
                    .launch = launch,
                }) catch |err| {
                    // A request forwarded by another process was acknowledged
                    // when it was queued, so say here that nothing opened.
                    // The first host still shows a banner while its last tab
                    // is detached for undo, when it has no surface.
                    const banner_host: ?*Host = source orelse
                        if (self.registry.hosts.items.len > 0) self.registry.hosts.items[0] else null;
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
                        if (builtin.is_test and test_app_config_clone_fails) return error.OutOfMemory;
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
                        // config change supersedes that transaction: it ends
                        // (`updateCoreConfig` ended it already, before core
                        // gave the panes this config) with nothing shown of
                        // the baseline, which every pane and window would
                        // otherwise take after or before this config, and the
                        // palette is dismissed so it resets every borrowed
                        // catalog before the incoming config replaces the
                        // baseline. A later Escape can never resurrect the
                        // stale pre-reload config.
                        self.supersedePaletteThemePreviews();
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
                        self.reconfigureTheme(.caller_applies);
                        // Every value is stored before the first step that
                        // can fail, and the windows' decorations and opacity
                        // go before the panes' scrollbar refresh, as each
                        // pane's config change once ordered them. This is
                        // each window's one apply in a reload (the panes'
                        // `.surface` arms leave it here), a window kept empty
                        // for undo included, after the theme's frame write.
                        for (self.registry.windows.items) |surface| surface.takeRuntimeConfig(&self.config);
                        // Every window has its apply, past one that fails:
                        // the theme left the opacity to this loop, so a
                        // window it skipped would show none of the reload.
                        // Then every pane's scrollbar, past one that fails,
                        // after a window's failure too: the refresh, still
                        // after the window pass, does not need a window's
                        // opacity to have applied. The config is
                        // installed either way, so the steps after them run
                        // (Settings hears of it), and the first failure, a
                        // window's before a pane's, is returned last.
                        self.app_wide_windows_applied = true;
                        const windows_applied = self.applyWindowsConfig(&self.config);
                        var scrollbars: @TypeOf(Surface.refreshScrollbarWindow(undefined)) = {};
                        for (self.registry.windows.items) |surface| {
                            surface.refreshScrollbarWindow() catch |err| {
                                log.warn("win32 scrollbar refresh after a config change failed err={}", .{err});
                                if (scrollbars) |_| scrollbars = err else |_| {}
                            };
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
                        try windows_applied;
                        try scrollbars;
                    },
                    .surface => |core_surface| {
                        const surface = self.registry.findSurfaceByCore(core_surface) orelse return false;
                        // The pane stores its config first. A pane's own
                        // config change gives its window the config only from
                        // the pane the window shows, before the pane's
                        // fallible scrollbar refresh. One that is part of an
                        // app-wide change leaves the window to the app's
                        // step, which applies it for every window once.
                        surface.takeRuntimeConfig(value.config);
                        surface.setTabBackground(value.config.background);
                        if (!self.app_wide_config_change) if (surface.host) |host| if (host.activeSurface() == surface) try window_state.applyConfig(host, value.config);
                        try surface.refreshScrollbarWindow();
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
                        .app => try self.updateCoreConfig(&self.config),
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
                try self.updateCoreConfig(&config);
                // A reload that found problems says so, whatever
                // `app-notifications` allows: "reloaded" would be false.
                // The config in effect, not the one just read: the app
                // applies its conditional state (dark system, `theme =
                // light:A,dark:B`) before it installs it.
                // config_change already recorded this load, including its
                // font checks; explicitly re-announce without scanning twice.
                if (self.reportRecordedConfigProblems()) return true;
                if (self.config.@"app-notifications".@"config-reload") {
                    self.notifications.show(.app, "noctty", "Configuration reloaded");
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

            .move_tab_to_new_window => {
                // From the message loop: the move reparents the terminal
                // whose key binding asked for it, and shows a new window.
                const surface = self.registry.findSurfaceForTarget(target) orelse return false;
                const found = Host.findTabForSurface(surface) orelse return false;
                if (found.host.quick_terminal or found.host.tabs.items.len < 2) return false;
                return self.requestTabMove(found.host, found.tab.id, .{ .new_window = null });
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

            .toggle_maximize,
            .toggle_fullscreen,
            .toggle_window_decorations,
            .float_window,
            .toggle_background_opacity,
            .initial_size,
            .reset_window_size,
            .size_limit,
            => {
                const surface = self.registry.findSurfaceForTarget(target) orelse return false;
                const host = surface.host orelse return false;
                return window_state.perform(host, surface, action, value);
            },

            .cell_size => {
                if (self.registry.findSurfaceForTarget(target)) |surface| {
                    surface.metrics.cell_size_pixels = value;
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
                        _ = self.showHostBanner(target, .info, open_refused_banner) catch false;
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
                self.notifications.show(.of(target), value.title, value.body);
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
            if (opts.host_id == null) _ = self.notifications.click(.window_opened);
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
        const index = profile_pick.byKey(profiles, key) orelse return null;
        return &profiles[index];
    }

    pub fn createProfileSurface(
        self: *App,
        target: apprt.Target,
        profile: *const windows_shell.Profile,
        open_target: OpenTarget,
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
            .window = if (open_target == .window) .from(self.registry.newWindowSource(target), &.{}) else .fresh,
            .clone_state_from = if (open_target == .window) null else source,
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
            .window = .{ .adopted = adoptedInitialShow(pending.startup_flags, pending.show_window) },
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
                show = opts.window.adopted;
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

    /// Settings ends every preview at once (a close, Discard): one end, the
    /// theme before the opacity, so each window shows its opacity once, at
    /// the saved value (`endSettingsPreview`).
    fn settingsEndPreviewsThunk(ctx: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(ctx));
        app.endSettingsPreview();
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

    /// A system theme message (`WM_THEMECHANGED`, `WM_SYSCOLORCHANGE`, a
    /// `WM_SETTINGCHANGE` that can change the theme, "ImmersiveColorSet"
    /// among them): the message's part (`reconfigureSystemTheme`) and the
    /// light/dark reload (`syncSystemColorScheme`) as one change, whichever
    /// message of a light/dark change arrives first, so each window applies
    /// its opacity once, at the value it ends at. Where a reload follows, it
    /// rebuilds the theme and applies every window, so the message's part
    /// goes into it: the system's inputs are taken first, and where they
    /// changed every failed blur-behind is unlatched, so the reload's apply
    /// is its one try. The message after the reload then finds both
    /// baselines current (it still rebuilds a missing resource), after a
    /// reload that failed at a pane's step too (`updateCoreConfig` rebuilds
    /// the theme then). Without a reload the message runs as before, then
    /// the sync: where the light/dark state did not change, it changes
    /// nothing (a pane's `colorSchemeCallback` and core's `colorSchemeEvent`
    /// return at once on an unchanged scheme); in safe mode with a changed
    /// one, they still move each pane's and core's light/dark state, and
    /// only the reload core asks for does nothing (the `.reload_config` arm
    /// returns in safe mode), as on the "ImmersiveColorSet" path before.
    pub fn systemColorSetChanged(self: *App) void {
        const scheme: configpkg.ConditionalState.Theme = if (isSystemDarkMode()) .dark else .light;
        const reloads = !self.safe_mode and self.core_app.config_conditional_state.theme != scheme;
        if (reloads) {
            if (self.takeSystemInputs()) for (self.registry.hosts.items) |host| {
                host.blur_behind_failed = false;
            };
        } else self.reconfigureSystemTheme();
        self.syncSystemColorScheme() catch |err| {
            log.warn("win32 color scheme sync failed err={}", .{err});
        };
        if (reloads) self.reconfigureSystemTheme();
    }

    pub fn syncSystemColorScheme(self: *App) !void {
        const scheme: apprt.ColorScheme = if (isSystemDarkMode()) .dark else .light;

        // Surface state must change before the app-wide reload because
        // App.updateConfig applies each surface's own conditional state and
        // Termio reports mode 2031 only after installing that derived config.
        // (A test pane with no core has no state to change.)
        if (!(builtin.is_test and self.test_surface_init_stage != null)) for (self.registry.windows.items) |surface| {
            surface.core().colorSchemeCallback(scheme);
        };
        try self.core_app.colorSchemeEvent(self, scheme);
    }

    /// Every update of the app's config from here: core `App.updateConfig`,
    /// which updates each pane (its `.surface` `config_change`) and then the
    /// app (the `.app` one), as one app-wide change
    /// (`app_wide_config_change`), so each window applies its half once, in
    /// the app's step.
    ///
    /// A pane's step that fails ends core's update before the app's, which
    /// never installs `config`: the panes before the failing one took it,
    /// the others kept what they had (a palette preview the update ended,
    /// among them), and the panes left the windows to the app's step. And
    /// core's light/dark state may have moved already (a light/dark reload
    /// sets it first), while `app.config` is still in the state it was
    /// installed in. Then the update ends as a soft reload of the config
    /// the app keeps, in core's order, past a pane that fails: every pane
    /// takes `app.config` in its own light/dark state, and the app's step
    /// installs `app.config` replayed in the app's (its own config files
    /// as last read, nothing of the failed update), so the panes, the
    /// theme, Settings and every window, each once, agree on it, the arm
    /// telling Settings past a window or pane that fails; any open palette
    /// closes, as in every reload. A pane whose step fails again keeps what
    /// that step did not reach (its scrollbar refresh, say). Where the arm
    /// cannot take the config at all (its clone runs out of memory), every
    /// palette still closes and the theme and every window show `app.config`
    /// as it is, needing no other clone. The pane's error is returned.
    /// The system theme message a light/dark reload runs after it
    /// (`systemColorSetChanged`) finds the theme current and applies no
    /// window again.
    pub fn updateCoreConfig(self: *App, config: *const configpkg.Config) !void {
        // Before core reads `config`, which is the app config itself in a
        // soft reload: the reload starts from the config a preview replaced.
        self.supersedePaletteThemePreviews();
        const outer = self.app_wide_config_change;
        const outer_applied = self.app_wide_windows_applied;
        self.app_wide_config_change = true;
        self.app_wide_windows_applied = false;
        defer {
            self.app_wide_config_change = outer;
            self.app_wide_windows_applied = outer_applied;
        }
        self.coreConfigUpdate(config) catch |err| {
            if (!self.app_wide_windows_applied) self.reloadKeptConfig();
            return err;
        };
    }

    /// The `.app` `config_change` arm's clone of the config fails in a test,
    /// as it can when memory runs out.
    pub var test_app_config_clone_fails = false;

    /// `updateCoreConfig`'s end after an update that failed before the app's
    /// step: core's order with `app.config`, logging a step that fails and
    /// going on. Still inside the app-wide change, so each pane leaves its
    /// window to the app's step.
    fn reloadKeptConfig(self: *App) void {
        for (self.registry.windows.items) |pane| {
            self.updatePaneCoreConfig(pane, &self.config) catch |err| {
                log.warn("win32 pane config restore after a failed update failed err={}", .{err});
            };
        }
        // In the app's light/dark state, as core gives the app its config,
        // or as it is if that fails, as core goes on then. The arm clones
        // what it is given before it frees `app.config`.
        var kept_ = self.config.changeConditionalState(self.core_app.config_conditional_state) catch null;
        defer if (kept_) |*kept| kept.deinit();
        _ = self.performAction(.app, .config_change, .{ .config = if (kept_) |*kept| kept else &self.config }) catch |err| {
            log.warn("win32 app config restore after a failed update failed err={}", .{err});
        };
        // The arm ends before its window pass only where it could not take
        // the config (its clone ran out of memory), and then nothing shows
        // `app.config`: a palette preview the update ended stays on screen,
        // with no preview left for its palette to revert. Then every
        // palette still closes, and the theme and every window show
        // `app.config` as it is, once. None of it needs another clone or an
        // allocation to succeed: a palette's mode, catalog and preview are
        // reset first, and its layout and text, and a theme resource
        // rebuild, are best effort (each logs a failure and goes on).
        if (!self.app_wide_windows_applied) {
            for (self.registry.hosts.items) |host| {
                if (host.overlay_mode == .command_palette) host.hideOverlay();
            }
            self.reconfigureTheme(.caller_applies);
            self.applyWindowsConfig(&self.config) catch |err| {
                log.warn("win32 window config apply after a failed update failed err={}", .{err});
            };
        }
    }

    /// A reload replaces the app config: a palette's live theme preview
    /// ends without being reverted on screen
    /// (`Host.supersedePaletteThemePreview`), and the palette closes in the
    /// `.app` `config_change` arm.
    fn supersedePaletteThemePreviews(self: *App) void {
        for (self.registry.hosts.items) |host| host.supersedePaletteThemePreview();
    }

    /// `updateCoreConfig` without its window pass after a failure.
    fn coreConfigUpdate(self: *App, config: *const configpkg.Config) !void {
        if (builtin.is_test and self.test_surface_init_stage != null) {
            // Core's order, for panes with no core: each pane, then the app
            // in the app's light/dark state, as core puts it.
            for (self.core_app.surfaces.items) |pane| try self.updatePaneCoreConfig(pane, config);
            var applied_ = config.changeConditionalState(self.core_app.config_conditional_state) catch null;
            defer if (applied_) |*applied| applied.deinit();
            _ = try self.performAction(.app, .config_change, .{ .config = if (applied_) |*applied| applied else config });
            return;
        }
        try self.core_app.updateConfig(self, config);
    }

    /// The window half of an app-wide change (`window_state.applyConfig`)
    /// for every window, past one that fails: a later failure is logged, the
    /// first is returned once every window had its turn.
    fn applyWindowsConfig(self: *App, config: *const configpkg.Config) @TypeOf(window_state.applyConfig(undefined, undefined)) {
        var applied: @TypeOf(window_state.applyConfig(undefined, undefined)) = {};
        for (self.registry.hosts.items) |host| {
            window_state.applyConfig(host, config) catch |err| {
                if (applied) |_| {
                    applied = err;
                } else |_| log.warn("win32 window config apply failed err={}", .{err});
            };
        }
        return applied;
    }

    /// Core's config update of `pane` alone (`Surface.updateConfig`), which
    /// ends in its `.surface` `config_change`.
    pub fn updatePaneCoreConfig(self: *App, pane: *Surface, config: *const configpkg.Config) anyerror!void {
        if (builtin.is_test and self.test_surface_init_stage != null) {
            // In the pane's light/dark state, as core's `Surface.updateConfig`
            // puts it; `syncSystemColorScheme` makes that the app's.
            var applied_ = config.changeConditionalState(self.core_app.config_conditional_state) catch null;
            defer if (applied_) |*applied| applied.deinit();
            _ = try self.performAction(.{ .surface = pane.core() }, .config_change, .{ .config = if (applied_) |*applied| applied else config });
            return;
        }
        try pane.core().updateConfig(config);
    }

    /// Takes the system's own theme inputs as the baseline a system theme
    /// message compares with (`system_inputs`), and returns whether they
    /// changed since the last message took them.
    fn takeSystemInputs(self: *App) bool {
        const inputs = window_state.SystemInputs.capture();
        defer self.system_inputs = inputs;
        const last = self.system_inputs orelse return true;
        return !std.meta.eql(last, inputs);
    }

    pub fn reconfigureSystemTheme(self: *App) void {
        // A rebuild when the snapshot differs from the last rebuild's,
        // whatever made that one (each takes it again), or a resource is
        // missing.
        const snapshot = SystemThemeSnapshot.capture(self.shownConfig());
        const changed = self.system_theme_refresh.accept(snapshot) or !std.meta.eql(snapshot.theme, self.resolved_theme);
        const rebuild = changed or for (self.registry.hosts.items) |host| {
            if (host.hwnd != null and (host.chrome_brush == null or
                host.overlay_brush == null or host.edit_brush == null or
                host.chrome_font == null or host.preview_font == null or
                (!host.titlebar_icons_geometric and
                    (host.titlebar_caption_icon_font == null or host.titlebar_action_icon_font == null)) or
                // The search font stays lazy. Only a failed attempt, not
                // its intentionally unused state, needs another chance.
                (host.search_icon_font_resolved and host.search_icon_font == null))) break true;
        } else false;
        // A retry when the system's own inputs differ from the last system
        // theme message's. Not from the snapshot: a reload or a Settings
        // preview between a system change and its message rebuilds with the
        // change, and the message then finds the snapshot as it left it.
        // Resources a message finds missing are GDI's, not DWM's.
        const system_changed = self.takeSystemInputs();
        if (rebuild) {
            self.reconfigureTheme(if (system_changed) .retry else .refresh);
        } else if (system_changed) {
            // Nothing to rebuild: an app rebuild already took the change in,
            // or the change needs none (light/dark under a fixed
            // `window-theme`). Either way every window whose blur-behind had
            // not failed shows its opacity; only a failed one tries again.
            for (self.registry.hosts.items) |host| {
                if (host.blur_behind_failed) window_state.retryBackgroundOpacity(host);
            }
        }
    }

    /// Rebuilds every window's chrome, frame and DWM attributes for the
    /// theme and `window-show-tab-bar`; then, after the frame write, `opacity`:
    /// - `retry`: each window shows its opacity again, and one whose
    ///   blur-behind failed tries it once more;
    /// - `refresh`: each window shows its opacity again;
    /// - `caller_applies`: none does; the caller's `window_state.applyConfig`
    ///   applies it next, at the value it will show.
    pub fn reconfigureTheme(self: *App, opacity: enum { retry, refresh, caller_applies }) void {
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
        // What the next system theme message compares with to decide on a
        // rebuild is this rebuild, whatever asked for it (Settings' preview,
        // a reload, the palette's theme). Whether a failed blur-behind tries
        // again it decides from `system_inputs`, which this leaves alone.
        const snapshot = SystemThemeSnapshot.capture(shown);
        self.system_theme_refresh.previous = snapshot;
        self.resolved_theme = snapshot.theme;
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
                // High Contrast shows every window opaque, and a window that
                // had blur-behind asserts it again across the theme change,
                // after the frame write above, as fullscreen and the
                // decorations toggle do (not every frame write does: open
                // item (d) of the OPACITY-640-FOLLOWUPS log entry).
                switch (opacity) {
                    .retry => window_state.retryBackgroundOpacity(host),
                    .refresh => window_state.refreshBackgroundOpacity(host),
                    .caller_applies => {},
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
    /// (`window_state.applyConfig`): Settings' preview of it while one is
    /// shown, whatever `config` is, so neither a pane's own config change
    /// (its `.surface` `config_change` outside an app-wide change) nor a
    /// reload's app-wide step shows a window the saved value under a
    /// preview.
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
            .theme => self.reconfigureTheme(.refresh),
            .opacity => {
                for (self.registry.windows.items) |surface| {
                    surface.applyRuntimeConfig(&self.config) catch |err| {
                        log.warn("settings live preview apply failed err={}", .{err});
                    };
                }
                for (self.registry.hosts.items) |host| {
                    window_state.applyConfig(host, &self.config) catch |err| {
                        log.warn("settings live preview apply failed err={}", .{err});
                    };
                }
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
    /// window rolled its previews back (a close, Discard: its `endPreviews`
    /// hook, `settingsEndPreviewsThunk`, so a theme and an opacity reverted
    /// together show each window once). A save's reload shows no preview
    /// (`livePreviews` is empty while a save is in flight), so normally a
    /// save leaves nothing to end; a save without a reload (safe mode)
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
        // The theme before the opacity: `EnumSet` iterates in tag order,
        // which is `PreviewEffect`'s declaration order. An opacity that ends
        // with the theme is applied by the opacity's own `applyConfig`, for
        // every window, so the theme does not show the previewed opacity
        // first.
        comptime {
            if (@intFromEnum(win32_settings.PreviewEffect.theme) > @intFromEnum(win32_settings.PreviewEffect.opacity)) {
                @compileError("endSettingsPreview ends the theme before the opacity: PreviewEffect must declare .theme before .opacity");
            }
        }
        var effects = changed.iterator();
        while (effects.next()) |effect| {
            if (effect == .theme and changed.contains(.opacity)) {
                self.reconfigureTheme(.caller_applies);
            } else self.refreshSettingsPreview(effect);
        }
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
        return profile_pick.pinByKey(&self.launcher_quick_slot_keys, key);
    }

    pub fn setLauncherQuickSlotPreference(self: *App, slot_ordinal: usize, key: []const u8) !void {
        if (slot_ordinal >= self.launcher_quick_slot_keys.len) return;
        if (!launcherQuickSlotAssignmentNeedsChange(self.launcher_quick_slot_keys, slot_ordinal, key)) return;
        // The key is pinned in another slot, never this one (the guard above):
        // that slot takes this slot's key.
        if (profile_pick.pinByKey(&self.launcher_quick_slot_keys, key)) |index| {
            if (self.launcher_quick_slot_keys[slot_ordinal]) |current| {
                try appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[index], current);
            } else {
                runUiActionOrLog(
                    "quick slot deduplication failed",
                    appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[index], null),
                );
            }
        }

        try appendOwnedString(self.core_app.alloc, &self.launcher_quick_slot_keys[slot_ordinal], key);

        for (self.registry.hosts.items) |host| {
            runUiActionOrLog("quick slot profile refresh failed", host.reapplyLauncherProfilePreferences());
            host.refreshProfileChrome();
        }
        // The Profiles page keeps the pinned profiles first, as the picker
        // now shows them.
        self.settings_window.profilesChanged();
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
    /// `config`, started as `origin` says (`window_state.begin`): placed and
    /// decorated as that window's own config says, a forwarded launch's keys
    /// included, or as the window it is opened from.
    pub fn createHost(self: *App, title: LPCWSTR, config: *const configpkg.Config, origin: window_state.Origin) !*Host {
        const start = try window_state.begin(self, config, origin);
        try self.ensureHostWindowClass();
        try self.ensurePaletteListClass();
        try self.ensureScrollbarClass();

        const host = try self.core_app.alloc.create(Host);
        var host_registered = false;
        errdefer if (!host_registered) self.core_app.alloc.destroy(host);
        host.* = .{
            .app = self,
            .id = self.allocateHostId(),
            .quick_terminal = origin == .quick_terminal,
            .top_level = start.plan.top_level,
            .pending_start = start,
        };
        host.palette_catalog = try PaletteCatalog.init(
            &host.palette_catalog_items,
            &host.palette_catalog_payloads,
        );
        host.tween_sched.init(self.core_app.alloc);
        if (self.launcher_profile_key) |key| {
            try appendOwnedString(self.core_app.alloc, &host.selected_profile_key, key);
        }

        const hwnd = sys.CreateWindowExW(
            0,
            host_class_name,
            title,
            start.plan.style,
            if (start.plan.position) |at| at.x else c.CW_USEDEFAULT,
            if (start.plan.position) |at| at.y else c.CW_USEDEFAULT,
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
        host.current_dpi = sys.GetDpiForWindow(hwnd);
        if (host.current_dpi == 0) host.current_dpi = 96;
        host.chrome_font = host.createChromeFont();
        host.preview_font = host.createPreviewFont();
        host.recreateTitlebarIconFonts();
        errdefer if (!host_registered) {
            _ = sys.DestroyWindow(hwnd);
        };

        self.attachShellCompositorWindow(hwnd);

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
        // After the compositor attach: the hidden window's style is put back
        // over what `CreateWindowEx` gave it, and a copy is moved to where
        // it will show.
        try window_state.advance(host, .created);

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

    pub fn hostTabStatus(self: *App, surface: *const Surface) tab_label.TabStatus {
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
        const previous_tab_id = if (host.active_tab < host.tabs.items.len)
            host.tabs.items[host.active_tab].id
        else
            null;
        host.active_tab = tab_info.index;
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
        // Released already, with the window that kept it: a tab move took
        // the window's last tab and the model removed the window with its
        // retained panes before the history clear got here.
        if (!self.shell_runtime.state.pane_ids.isCurrent(pane_id)) return;
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

    /// A toast click with nothing to present (`initial-window = false`, or
    /// the last window closed under `quit-after-last-window-closed = false`)
    /// asks for a window the way a forwarded click does, and that window
    /// presents it (`Notifications.click(.window_opened)`), as a cold
    /// start's would.
    pub fn openWindowForToastClick(self: *App) void {
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
        var capture: notifications.ColdToastCapture = .{};
        win32_toast_activator.bind(capture.sink());
        // `startToastActivator` binds the App channel once it exists.
        defer win32_toast_activator.bind(null);
        win32_toast_activator.register() catch return .{};

        if (!notifications.pumpUntilColdToastActivation(&capture, cold_toast_activation_wait_ms))
            log.warn("toast activation start: no activation within {d} ms", .{cold_toast_activation_wait_ms});
        return capture.activation;
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

    pub fn removeHost(self: *App, host: *Host) void {
        if (!self.registry.detachHost(host)) return;
        host.deinit();
        self.core_app.alloc.destroy(host);
    }

    pub fn windowDestroyed(self: *App, surface: *Surface) void {
        self.registry.removeWindow(surface);
        // A closed pane's toast can no longer focus anything.
        self.notifications.panesChanged();
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
            if (host.tab_drag_index != null) self.endTabDragFeedback();
            host.tab_drag_index = null;
            host.tab_drag_active = false;
            host.tab_drag_target = .stay;
            host.tab_drag_origin_index = null;
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
            } else {
                // The last D3D11 pane may have closed. Not in a window that
                // closes whole (`Host.closing`), which would show a mode for
                // the moment before it goes.
                if (!self.quitting and !host.closing) window_state.refreshBackgroundOpacity(host);
                if (self.running) {
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

        // A window with nothing to show (kept empty for its undo history,
        // hidden after a tab move) is passed over.
        const count = host_ids.items.len;
        var step: usize = 1;
        while (step < count) : (step += 1) {
            const next_idx = switch (direction) {
                .next => (current_host_idx + step) % count,
                .previous => (current_host_idx + count - step) % count,
            };
            const next_surface = self.registry.activeSurfaceForHost(host_ids.items[next_idx]) orelse continue;
            self.activateSurface(next_surface);
            return true;
        }
        return false;
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
                host.setBanner(.info, tabClosedMessage(
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

    /// Runs on the window `moveTabToWindow` makes for a torn-off tab, before
    /// its first show: the shared fixtures give it the stand-in tab strip a
    /// pane's init gives a new window (`WindowStartTestApp.stage`), since the
    /// test executable cannot make the layered one.
    pub var test_tear_off_window_created: ?*const fn (*Host) anyerror!void = null;

    /// Runs while `moveTabToWindow` activates the moved tab in its window,
    /// with the window holding its size (`Host.hold_initial_size`), for the
    /// test of what a moved pane's font change does then.
    pub var test_tab_move_activating: ?*const fn (*Host, *Surface) anyerror!void = null;

    /// Runs before `moveTabToWindow`'s shell steps that can still fail after
    /// a history clear (`.retry_prepare`) or before it (`.commit`), and
    /// around the history clear after the commit (`.history`,
    /// `.after_history`), for the tests that make them fail.
    pub var test_tab_move_shell_step: ?*const fn (*App, TabMoveShellStep) void = null;
    pub const TabMoveShellStep = enum { retry_prepare, commit, history, source_history_retired, after_history };

    pub const PendingTabMove = struct { host_id: u32, request: Host.TabMoveRequest };

    /// How many moves wait for `host`'s tabs.
    pub fn pendingTabMoveCount(self: *const App, host: *const Host) usize {
        var count: usize = 0;
        for (self.pending_tab_moves.items) |pending| {
            if (pending.host_id == host.id) count += 1;
        }
        return count;
    }

    /// Where a tab leaving its window goes (`moveTabToWindow`).
    pub const TabMoveDest = union(enum) {
        /// A new window: where the tab was dropped, or (null, for
        /// `move_tab_to_new_window`) a cascade step off the source.
        new_window: ?window_start.Drop,
        /// Another window of this process, at `index` in its tab strip.
        host: struct { host: *Host, index: usize },
    };

    /// Asks `host` to move its tab `tab_id`, which the outer message pump
    /// does (`drainPendingTabMoves`): a drag asks from the tab button's own
    /// handler, whose button the move destroys (and with the window's last
    /// tab the window), `move_tab_to_new_window` from the terminal's key
    /// handling, and a nested modal loop (a menu, the system move loop) must
    /// never run a move under the handler that opened it. Requests queue in
    /// order, one per tab (a later one for the same tab replaces it), so an
    /// `all:` binding moves each tab it reaches; the only tab still stays.
    pub fn requestTabMove(self: *App, host: *Host, tab_id: u32, dest: Host.TabMoveRequest.Dest) bool {
        const hwnd = host.hwnd orelse return false;
        const slot = for (self.pending_tab_moves.items) |*pending| {
            if (pending.host_id == host.id and pending.request.tab_id == tab_id) break pending;
        } else self.pending_tab_moves.addOne(self.core_app.alloc) catch {
            log.warn("tab move declined: out of memory", .{});
            return false;
        };
        slot.* = .{ .host_id = host.id, .request = .{ .tab_id = tab_id, .dest = dest } };
        // A wake for the pump, which runs the queue before its next wait.
        if (sys.PostMessageW(hwnd, c.WM_WINHOSTTY_TAB_MOVE, 0, 0) == 0) {
            log.warn("tab move wake could not be posted err={}", .{windows.kernel32.GetLastError()});
        }
        return true;
    }

    /// A tab move's wake reached a window. Dispatched by the outer pump
    /// itself, its next turn runs the move. Taken by a nested loop instead (a
    /// menu, the system move loop, a sent message's loop while the pump waits
    /// in `GetMessage`), nothing would wake the pump once that loop ends: one
    /// thread timer, whichever window the wake went to, keeps waking until
    /// the outer pump retrieves a tick of it (a nested loop's dispatch drops
    /// a thread timer's message) or the queue is empty.
    pub fn noteTabMoveWake(self: *App, message: UINT) void {
        if (self.pending_tab_moves.items.len == 0 or self.outer_dispatch_message == message) {
            killThreadTimer(&self.tab_move_wake_timer);
            return;
        }
        if (self.tab_move_wake_timer != null) return;
        const id = sys.SetTimer(null, 0, 50, null);
        if (id == 0) {
            log.warn("tab move re-wake timer failed err={}", .{windows.kernel32.GetLastError()});
            return;
        }
        self.tab_move_wake_timer = id;
    }

    /// The pump's step for the release of a press a tab that left mid-drag
    /// held: taken wherever it lands, so no terminal in any window gets a
    /// release it never saw pressed, nor a tab's X a click (CodeRabbit
    /// r4510086531). The next press forgets it.
    fn takeHeldRelease(self: *App, msg: *const MSG) bool {
        switch (msg.message) {
            c.WM_LBUTTONDOWN, c.WM_NCLBUTTONDOWN => {
                self.held_release_pending = false;
                return false;
            },
            c.WM_LBUTTONUP, c.WM_NCLBUTTONUP => {
                if (!self.held_release_pending) return false;
                self.held_release_pending = false;
                return true;
            },
            else => return false,
        }
    }

    /// The outer pump retrieved a tick of the tab-move re-wake timer: it
    /// stops, and the pump's next turn runs the moves (`drainPendingTabMoves`).
    fn takeTabMoveWakeTick(self: *App, msg: *const MSG) bool {
        if (!threadTimerFired(msg, self.tab_move_wake_timer)) return false;
        killThreadTimer(&self.tab_move_wake_timer);
        return true;
    }

    /// Runs every waiting tab move, from the outer message pump, with no
    /// window procedure on the stack. A move can free the window it was asked
    /// of, so the windows are found again for each request.
    pub fn drainPendingTabMoves(self: *App) void {
        // Each run takes one request off the queue and adds none, so this ends.
        while (self.pending_tab_moves.items.len > 0) {
            const pending = self.pending_tab_moves.orderedRemove(0);
            // The window may have gone meanwhile (its last pane closed, or an
            // earlier move emptied it).
            const host = self.registry.findHostById(pending.host_id) orelse continue;
            self.runTabMove(host, pending.request);
        }
        self.pending_tab_moves.clearAndFree(self.core_app.alloc);
        // Nothing waits: no timer outlives the queue.
        killThreadTimer(&self.tab_move_wake_timer);
    }

    fn runTabMove(self: *App, host: *Host, request: Host.TabMoveRequest) void {
        // The tab may have closed, or the target window gone, meanwhile.
        const index = host.findTabIndexById(request.tab_id) orelse return;
        const dest: TabMoveDest = switch (request.dest) {
            .new_window => |drop| .{ .new_window = drop },
            .window => |over| .{ .host = .{
                .host = self.registry.findHostById(over.host_id) orelse return,
                .index = over.index,
            } },
        };
        _ = self.moveTabToWindow(host, index, dest) catch |err| {
            log.err("tab move failed err={}", .{err});
        };
    }

    /// Moves the tab at `index` of `source` into `dest` with its whole pane
    /// tree: its terminals keep their processes, scrollback, titles, split
    /// ratios and zoom, because the panes keep their windows and only change
    /// parent (`Host.giveTab`). The window it joins shows it in front with
    /// focus; the window it left keeps its other tabs and shows the tab
    /// beside it, or closes when that was its last tab. Undo history goes in
    /// both windows, as for a reorder (`moveTab`): its entries keep tab
    /// indices and panes of the window they were made in. Everything that
    /// can fail runs before anything moves, the shell model's commit last.
    /// False when there is nothing to do: the quick terminal keeps its tabs,
    /// a window's only tab is already alone, and only an ordinary window
    /// with a tab takes one.
    pub fn moveTabToWindow(self: *App, source: *Host, index: usize, dest: TabMoveDest) !bool {
        if (source.quick_terminal or index >= source.tabs.items.len) return false;
        switch (dest) {
            .new_window => if (source.tabs.items.len < 2) return false,
            .host => |to| if (to.host == source or to.host.quick_terminal or
                to.host.hwnd == null or to.host.tabs.items.len == 0) return false,
        }
        const tab_id = source.tabs.items[index].id;
        const source_id = source.id;
        var insert: usize = switch (dest) {
            .new_window => 0,
            .host => |to| @min(to.index, to.host.tabs.items.len),
        };

        // A torn-off tab's window, hidden and already where it will show,
        // and room for the tab: made before any undo history goes, so a
        // failure here loses none.
        var created: ?*Host = null;
        errdefer if (created) |host| self.discardUnusedHost(host);
        const target: *Host = switch (dest) {
            .new_window => |drop| target: {
                created = try self.createHost(default_title, &self.config, .{ .tear_off = .{ .source = source, .drop = drop } });
                if (builtin.is_test) {
                    if (test_tear_off_window_created) |hook| try hook(created.?);
                }
                break :target created.?;
            },
            .host => |to| to.host,
        };
        // Making the window ran its window procedures, whose code can close
        // the window the tab is leaving (council round 7, CodeRabbit review
        // 5823245522): it is found again by id before anything reads it.
        if (self.registry.findHostById(source_id) == null) {
            // Not an error, so the errdefer does not run.
            if (created) |host| self.discardUnusedHost(host);
            return false;
        }
        try target.tabs.ensureUnusedCapacity(self.core_app.alloc, 1);
        const target_id = target.id;
        // The tab is found again by id too, and a tab gone meanwhile is a
        // move with nothing to do.
        var at = source.findTabIndexById(tab_id) orelse {
            // Not an error, so the errdefer does not run.
            if (created) |host| self.discardUnusedHost(host);
            return false;
        };

        // The shell model's half. Undo history goes only once the model has
        // the move: the commit comes first (a stale one is rebuilt by
        // preparing again, which can run out of memory, with the history
        // still whole), the history clear after it. One rule for every
        // failure (TEAROFF-01): the model and the windows always agree, and
        // no closed tab the model keeps for undo is left without its window.
        // History that cannot be disposed stays with its window (below); it
        // is given up only where the model needs it gone first: it refuses
        // the move while a transfer in that history names the tab
        // (`InvalidTransfer`), so then the history goes before a second
        // prepare, which can still fail, and the move fails with it gone.
        var history_cleared = false;
        var shell_prepared: ?win32_shell.runtime.Prepared = null;
        var shell_tab: ?win32_shell.model.TabId = null;
        if (self.shell_runtime_initialized) {
            shell_tab = source.tabs.items[at].shell_id orelse return error.ShellStateOutOfSync;
            shell_prepared = self.shell_runtime.prepare(try moveTabIntent(shell_tab.?, dest, insert)) catch |err| switch (err) {
                error.InvalidTransfer => null,
                else => return err,
            };
            if (shell_prepared == null) {
                try self.clearMoveHistory(source_id, switch (dest) {
                    .new_window => null,
                    .host => target_id,
                });
                history_cleared = true;
                if (builtin.is_test) {
                    if (test_tab_move_shell_step) |hook| hook(self, .retry_prepare);
                }
                // The clear closed the windows that history kept, whose code
                // can close a tab or a whole window: both windows and the tab
                // are found again, and the move asked again of what is there
                // now (Greptile r4510568134). Gone, it is a move with nothing
                // to do.
                const still = self.registry.findHostById(source_id) != null and
                    self.registry.findHostById(target_id) != null;
                const now: ?usize = if (still) source.findTabIndexById(tab_id) else null;
                at = now orelse {
                    if (created) |host| self.discardUnusedHost(host);
                    return false;
                };
                insert = @min(insert, target.tabs.items.len);
                shell_tab = source.tabs.items[at].shell_id orelse return error.ShellStateOutOfSync;
                shell_prepared = try self.shell_runtime.prepare(try moveTabIntent(shell_tab.?, dest, insert));
            }
        }
        defer if (shell_prepared) |*prepared| prepared.deinit();

        if (shell_prepared) |*prepared| {
            if (builtin.is_test) {
                if (test_tab_move_shell_step) |hook| hook(self, .commit);
            }
            // A focus message between the prepare and here makes it stale:
            // it is prepared again on what is current.
            try prepared.commitRetryingStale(&self.shell_runtime);
            if (created) |host| host.shell_id = self.shell_runtime.state.tabConst(shell_tab.?).?.window;
        }
        source.tabs.items[at].clearRedoHistory();
        // The tab the destination showed starts a new branch too, as a
        // reorder's two tabs do: its panes' local redo goes.
        switch (dest) {
            .new_window => {},
            .host => |to| if (to.host.activeTab()) |front| front.clearRedoHistory(),
        }

        // Nothing fails from here on. The tab moves first, and nothing
        // between the commit and here runs a window's code: disposing undo
        // history closes windows, so the moving tab is never in flight then
        // (CodeRabbit review 5822445361). That window code closing a tab is
        // a defensive premise: no in-process path does today (UIA
        // disconnects are deferred, the one WinEvent hook is out of context
        // and watches cloaking only), but nothing here may rely on that.
        const new_window = created != null;
        created = null;
        // By id: what `giveTab` runs first (a confirm's cancel, the prompts it
        // hides, the drag it ends) can close a tab.
        const moved_id: ?u32 = if (source.giveTab(tab_id, target, insert)) |landed| target.tabs.items[landed].id else null;

        // Undo history goes in both windows, as for a reorder (`moveTab`):
        // its entries keep tab indices and panes of their window. After the
        // commit, which is then never stale from it, and after the transfer;
        // each disposal commits its own release and finds its panes by
        // identity, never by where the tab is. A disposal that cannot finish
        // (out of memory in its model discard) leaves its entry, and the
        // model the closed tab it names: both stay with their window, and
        // the undo prune disposes them later.
        if (builtin.is_test) {
            if (test_tab_move_shell_step) |hook| hook(self, .history);
        }
        if (!history_cleared) self.retireMoveHistory(source_id, switch (dest) {
            .new_window => null,
            .host => target_id,
        });
        if (builtin.is_test) {
            if (test_tab_move_shell_step) |hook| hook(self, .after_history);
        }
        // What that window code closed meanwhile, a tab or a whole window,
        // closed as any close does, in the model too: both windows and the
        // moved tab are found again by id.
        const source_live = self.registry.findHostById(source_id) != null;
        const target_live = self.registry.findHostById(target_id) != null;
        const source_emptied = source_live and source.tabs.items.len == 0;
        const target_emptied = target_live and target.tabs.items.len == 0;
        if (source_emptied) self.forgetEmptiedShellWindow(source);
        if (target_emptied) self.forgetEmptiedShellWindow(target);
        const landed_now: ?usize = if (target_live) if (moved_id) |id| target.findTabIndexById(id) else null else null;

        // Showing the tab puts the target's DPI's font into its panes, and
        // with `window-width`/`window-height` set the core then asks for its
        // window's size again (`recomputeInitialSize`): not of this window.
        // Let go at the end, before an emptied window is settled, which can
        // free it (Greptile r4510568141).
        if (target_live) target.hold_initial_size = true;
        // The panes stay in a live tab throughout; toasts follow them to
        // their new window.
        self.notifications.panesChanged();
        if (shell_prepared) |*prepared| self.applyShellEffects(prepared.effects(), .{ .focus = false });

        if (source_live and !source_emptied) {
            // The tab beside it comes to the front, without taking the
            // keyboard from the window the tab went to.
            window_state.refreshBackgroundOpacity(source);
            if (source.activeTab()) |front| if (front.focusedSurface()) |pane| self.activateSurfaceNoFocus(pane);
            runUiActionOrLog("tab move source layout failed", source.layout());
            // Its caption counts its tabs ("[2/2]"), and an activation that
            // keeps the pane in front skips the chrome sync that says so.
            runUiActionOrLog("tab move source chrome refresh failed", source.refreshChrome());
            source.refreshSearchTimerState();
        }
        // The moved tab, shown and focused in its window, unless it closed
        // while history was disposed.
        show: {
            const shown = self.registry.findHostById(target_id) orelse break :show;
            const landed_at = (if (landed_now != null) if (moved_id) |id| shown.findTabIndexById(id) else null else null) orelse break :show;
            self.showMovedTab(shown, landed_at, new_window);
        }

        // The end of the move, in one order, with no defer left to touch a
        // window after one is freed: the size hold goes, then each window
        // left with no tab settles, after the target took the foreground.
        // Found again by id: what ran since (activation, the show) is window
        // code too.
        if (self.registry.findHostById(target_id)) |host| {
            host.hold_initial_size = false;
            if (target_emptied and host.tabs.items.len == 0) self.settleEmptiedHost(host);
        }
        if (source_emptied) if (self.registry.findHostById(source_id)) |host| {
            if (host.tabs.items.len == 0) self.settleEmptiedHost(host);
        };
        self.auditShellNativeMapping("tab-move-window");
        return true;
    }

    /// `move_tab_to_window` for `tab` into `dest` at `insert`.
    fn moveTabIntent(tab: win32_shell.model.TabId, dest: TabMoveDest, insert: usize) !win32_shell.intent.Intent {
        const window: ?win32_shell.model.WindowId = switch (dest) {
            .new_window => null,
            .host => |to| to.host.shell_id orelse return error.ShellStateOutOfSync,
        };
        return .{ .move_tab_to_window = .{ .tab = tab, .window = window, .index = insert } };
    }

    /// The tab a move put at `landed_at` of `target`: shown in front, and in
    /// a new window, what `Surface.init` does for the window it creates.
    fn showMovedTab(self: *App, target: *Host, landed_at: usize, new_window: bool) void {
        target.refreshTabStatus(landed_at);
        // A pane may wait out a search debounce, which the target's timer
        // now ticks (the 2026-11-07 background-tab debounce entry in
        // search-scrollbar.md).
        target.refreshSearchTimerState();
        // A D3D11 pane arriving fades the target whole (OPACITY-640).
        window_state.refreshBackgroundOpacity(target);
        const pane = target.tabs.items[landed_at].focusedSurface() orelse return;
        if (new_window) {
            // What `Surface.init` does for the window it creates: the panes
            // shown, then the first show, then what the window takes after it.
            target.active_tab = landed_at;
            target.prepareActiveTabVisibility(landed_at);
            target.showTabPanes(&target.tabs.items[landed_at]);
            const presents = window_state.advance(target, .before_show) catch |err| presents: {
                log.warn("torn-off tab window first show failed err={}", .{err});
                break :presents true;
            };
            if (presents) pane.presentWindow();
            // Its live tab must not sit in a window nobody can reach.
            if (target.hwnd) |hwnd| if (sys.IsWindowVisible(hwnd) == 0) {
                _ = sys.ShowWindow(hwnd, c.SW_SHOW);
                pane.presentWindow();
            };
            window_state.advance(target, .after_show) catch |err| {
                log.warn("torn-off tab window start failed err={}", .{err});
            };
            // Hidden until now, the panes took the window's size before its
            // DPI's font; each takes both again as one resize (the
            // 2026-10-25 DPI-HIDDEN-TAB-BATCH-01 entry in window-frame.md).
            target.applyDpiChangeToVisibleSurfaces();
        }
        if (builtin.is_test) {
            if (test_tab_move_activating) |hook| hook(target, pane) catch |err| log.err("tab move test hook failed err={}", .{err});
        }
        self.activateSurface(pane);
        var it = target.tabs.items[landed_at].tree.iterator();
        while (it.next()) |entry| entry.view.requestRepaint() catch |err| {
            log.warn("moved pane repaint request failed err={}", .{err});
        };
    }

    /// A window a tab move left with no tab: the model removed its window
    /// with its last tab (`move_tab_to_window`), unless closed tabs it keeps
    /// for undo hold it.
    fn forgetEmptiedShellWindow(self: *App, host: *Host) void {
        const id = host.shell_id orelse return;
        if (!self.shell_runtime_initialized or self.shell_runtime.state.windowConst(id) == null) host.shell_id = null;
    }

    /// A window a tab move left with no tab goes, as the last pane's
    /// teardown closes one (`windowDestroyed`), unless undo history it could
    /// not dispose is left in it: the model then keeps its window for the
    /// closed tabs that history names, and this side keeps it too, hidden,
    /// until the undo prune disposes that history and closes it
    /// (`destroy_after_structural_dispose`), as a window whose last tab
    /// closed is kept. Nothing the user can reach is left in it, so a
    /// `toggle_visibility` that hid it while the move waited does not show
    /// it again either.
    fn settleEmptiedHost(self: *App, host: *Host) void {
        if (host.hasStructuralHistory()) {
            host.destroy_after_structural_dispose = true;
            host.hidden_by_toggle = false;
            if (host.hwnd) |hwnd| _ = sys.ShowWindow(hwnd, c.SW_HIDE);
            self.scheduleUndoPruneTimer();
            return;
        }
        if (host.hwnd) |hwnd| _ = sys.DestroyWindow(hwnd);
        self.removeHost(host);
    }

    /// After a tab move's commit: both windows' undo history goes, each
    /// window's whether or not the other's could. What a disposal cannot
    /// finish (out of memory in its model discard) stays whole, under a floor
    /// that keeps it from ever replaying (`Host.history_floor`): its entries
    /// keep tab indices and panes of the windows as they were before the
    /// move. An undo or redo that reaches one disposes it instead.
    ///
    /// By window id, each window found again before its clear: a disposal
    /// closes windows, whose code can close the other window (council round
    /// 7 M1b). And both windows' history is held from replay before either
    /// clear begins, not only after one fails: code a disposal in one window
    /// runs could otherwise undo in the other and put a tab back at an index
    /// from before the move (CodeRabbit review 5823245522). Like the rest of
    /// that premise, defensive: no in-process path runs such code today.
    fn retireMoveHistory(self: *App, source_id: u32, target_id: ?u32) void {
        const floor = self.next_undo_sequence;
        for ([_]?u32{ source_id, target_id }) |maybe| {
            const id = maybe orelse continue;
            const host = self.registry.findHostById(id) orelse continue;
            host.history_floor = @max(host.history_floor, floor);
        }
        if (self.registry.findHostById(source_id)) |host| retireHostHistory(host);
        if (builtin.is_test) {
            if (test_tab_move_shell_step) |hook| hook(self, .source_history_retired);
        }
        if (target_id) |id| if (self.registry.findHostById(id)) |host| retireHostHistory(host);
    }

    fn retireHostHistory(host: *Host) void {
        if (host.tryClearStructuralHistory(.normal)) return;
        log.warn("tab move left undo history it could not dispose; it will not replay", .{});
    }

    /// Before the move, for the `InvalidTransfer` retry only: a failure here
    /// aborts the move, so each window's history is still its own and the
    /// destination's is left whole, not cleared for a move that does not
    /// happen. After a commit, `retireMoveHistory` clears both.
    /// By window id, as `retireMoveHistory`: the source's clear can close
    /// the destination. A window gone is left to the caller, which finds
    /// both again.
    fn clearMoveHistory(self: *App, source_id: u32, target_id: ?u32) !void {
        if (self.registry.findHostById(source_id)) |host| {
            if (!host.tryClearStructuralHistory(.normal)) return error.HistoryDisposalDeferred;
        }
        if (target_id) |id| if (self.registry.findHostById(id)) |host| {
            if (!host.tryClearStructuralHistory(.normal)) return error.HistoryDisposalDeferred;
        };
    }

    /// A window `moveTabToWindow` made and could not use: still hidden,
    /// without a tab and not in the shell model.
    fn discardUnusedHost(self: *App, host: *Host) void {
        host.shell_id = null;
        if (host.hwnd) |hwnd| {
            if (sys.DestroyWindow(hwnd) == 0) self.detachShellCompositorWindow(hwnd);
        }
        self.removeHost(host);
    }

    /// Whether a drag's pointer at `screen` lands on top-level window
    /// `hwnd`: shown and under the point, not minimized, not click-through
    /// (as the drag's own label is) and not cloaked (on another virtual
    /// desktop, a suspended app), asked in that order, cheapest first.
    fn takesDragPointer(hwnd: HWND, screen: POINT) bool {
        if (sys.IsWindowVisible(hwnd) == 0) return false;
        var rect: RECT = undefined;
        if (sys.GetWindowRect(hwnd, &rect) == 0 or !pointInRect(screen, rect)) return false;
        if (sys.IsIconic(hwnd) != 0) return false;
        const ex_style: usize = @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE));
        const click_through: usize = c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT;
        if (ex_style & click_through == click_through) return false;
        return !(win32_power.queryCloaked(hwnd) orelse false);
    }

    /// Another window of this process whose tab strip is under `screen`, and
    /// where a tab dropped there goes. The topmost window under the point
    /// decides, `skip` (the window being dragged from) aside: another
    /// program's window there, another noctty process's included, takes no
    /// tab (the drop opens a new window instead), and neither does this
    /// process's quick terminal, a window kept empty for undo or a window
    /// whose strip is hidden or not under the point.
    /// `blocker` (the window a tab is dragged in) takes the point when it is
    /// the topmost there, so a window under it takes no tab, while one over
    /// it, an always-on-top window or one simply in front, does.
    pub fn tabStripTargetAt(self: *App, screen: POINT, skip: ?HWND, blocker: ?HWND) ?tab_drag.Over {
        var next = sys.GetTopWindow(null);
        var guard: usize = 0;
        while (next) |hwnd| : (next = sys.GetWindow(hwnd, c.GW_HWNDNEXT)) {
            guard += 1;
            if (guard > 4096) return null;
            if (skip) |skipped| if (hwnd == skipped) continue;
            if (self.tab_drag_preview_hwnd) |preview| if (hwnd == preview) continue;
            if (!takesDragPointer(hwnd, screen)) continue;
            if (blocker) |source| if (hwnd == source) return null;
            const host = self.registry.findHostByHwnd(hwnd) orelse return null;
            if (host.quick_terminal or host.tabs.items.len == 0) return null;
            // A window DWM could not say is on this desktop takes no tab: it
            // may be on another virtual desktop.
            if (win32_power.queryCloaked(hwnd) == null) return null;
            const strip = host.tabStripScreenRect() orelse return null;
            if (!pointInRect(screen, strip)) return null;
            return .{ .host_id = host.id, .index = host.tabInsertIndexAtScreenX(screen.x) };
        }
        return null;
    }

    fn pointInRect(point: POINT, rect: RECT) bool {
        return point.x >= rect.left and point.x < rect.right and point.y >= rect.top and point.y < rect.bottom;
    }

    /// What a tab drag shows once it left its strip: the label by the
    /// pointer saying what a drop does, and in the window a drop would join
    /// the bar where the tab goes.
    pub fn showTabDragFeedback(self: *App, source: *Host, drag_index: usize, target: tab_drag.Target, screen: POINT) void {
        for (self.registry.hosts.items) |host| switch (target) {
            .window => |over| if (over.host_id == host.id) host.showTabInsertMarker(over.index) else host.hideTabInsertMarker(),
            else => host.hideTabInsertMarker(),
        };
        switch (target) {
            .stay => self.hideTabDragPreview(),
            .new_window => self.showTabDragPreview(source, drag_index, screen, "New window"),
            .window => self.showTabDragPreview(source, drag_index, screen, "Move to this window"),
        }
    }

    /// What the drag label says a drop does: "New window", "Move to this
    /// window", or empty while no label shows.
    pub fn tabDragLabelAction(self: *const App) []const u8 {
        return self.tab_drag_label_action;
    }

    pub fn endTabDragFeedback(self: *App) void {
        for (self.registry.hosts.items) |host| host.hideTabInsertMarker();
        self.hideTabDragPreview();
    }

    fn hideTabDragPreview(self: *App) void {
        // The next label says what a drop does again.
        self.tab_drag_label_action = "";
        const preview = self.tab_drag_preview_hwnd orelse return;
        _ = sys.ShowWindow(preview, c.SW_HIDE);
    }

    fn tabDragLabelUiaName(ctx: *anyopaque, _: usize, buf: []u8) []const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        const len = @min(self.tab_drag_label_len, buf.len);
        @memcpy(buf[0..len], self.tab_drag_label_text[0..len]);
        return buf[0..len];
    }

    /// The label answers UIA with its live text element; the rest is the
    /// STATIC's.
    fn tabDragLabelProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
        const data: usize = @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
        const app: ?*App = if (data == 0) null else @ptrFromInt(data);
        if (app) |self| {
            if (msg == c.WM_GETOBJECT) if (self.tab_drag_preview_uia_provider) |provider| {
                if (win32_uia.returnChromeControlProvider(hwnd, wParam, lParam, provider)) |lr| return lr;
            };
            if (self.tab_drag_preview_prev_proc) |previous| return sys.CallWindowProcW(previous, hwnd, msg, wParam, lParam);
        }
        return sys.DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    /// The label by the pointer during a tab drag: what a drop does, and
    /// the tab's title. A click-through, never-activated popup, so it takes
    /// neither the pointer nor the keyboard (`takesDragPointer`).
    fn showTabDragPreview(self: *App, source: *Host, drag_index: usize, screen: POINT, action: []const u8) void {
        if (self.tab_drag_preview_hwnd == null) {
            const ex_style: u32 = c.WS_EX_LAYERED | c.WS_EX_TRANSPARENT | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE | 0x00000008; // WS_EX_TOPMOST
            self.tab_drag_preview_hwnd = sys.CreateWindowExW(
                ex_style,
                child_window.prompt_label_class,
                std.unicode.utf8ToUtf16LeStringLiteral(""),
                c.WS_POPUP | c.WS_BORDER | c.SS_CENTER | c.SS_CENTERIMAGE | c.SS_NOPREFIX | c.SS_ENDELLIPSIS,
                0,
                0,
                1,
                1,
                null,
                null,
                self.hinstance,
                null,
            );
            const preview = self.tab_drag_preview_hwnd orelse return;
            _ = sys.SetLayeredWindowAttributes(preview, 0, 235, c.LWA_ALPHA);
            // A UIA element of its own (accessibility.md 2026-04-16: every
            // new widget gets a provider), live text, so a screen reader
            // hears what a drop does when that changes.
            setWindowData(preview, self);
            const previous = sys.SetWindowLongPtrW(preview, c.GWLP_WNDPROC, @bitCast(@intFromPtr(&tabDragLabelProc)));
            self.tab_drag_preview_prev_proc = if (previous == 0) null else @ptrFromInt(@as(usize, @bitCast(previous)));
            if (self.com_initialized) {
                self.tab_drag_preview_uia_provider = win32_uia.ChromeControlProvider.create(std.heap.page_allocator, preview, .{
                    .ctx = @ptrCast(self),
                    .role = .live_text,
                    .name = &tabDragLabelUiaName,
                    .use_com_threading = true,
                }) catch |err| provider: {
                    log.warn("tab drag label UIA provider unavailable err={}", .{err});
                    break :provider null;
                };
            }
        }
        const preview = self.tab_drag_preview_hwnd orelse return;
        var utf8: [256]u8 = undefined;
        const title: []const u8 = title: {
            if (drag_index >= source.tabs.items.len) break :title "";
            const pane = source.tabs.items[drag_index].focusedSurface() orelse break :title "";
            break :title pane.effectiveTitle() orelse "";
        };
        var cut = @min(title.len, 160);
        while (cut > 0 and cut < title.len and (title[cut] & 0xC0) == 0x80) cut -= 1;
        const text = std.fmt.bufPrint(&utf8, "{s}: {s}", .{ action, title[0..cut] }) catch action;
        var utf16: [258]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(utf16[0 .. utf16.len - 1], text) catch
            std.unicode.utf8ToUtf16Le(utf16[0 .. utf16.len - 1], action) catch 0;
        utf16[units] = 0;
        _ = sys.SetWindowTextW(preview, @ptrCast(&utf16));
        const kept = @min(text.len, self.tab_drag_label_text.len);
        @memcpy(self.tab_drag_label_text[0..kept], text[0..kept]);
        self.tab_drag_label_len = kept;
        if (source.chrome_font) |font| _ = sys.SendMessageW(preview, c.WM_SETFONT, @intFromPtr(font), 0);
        _ = sys.SetWindowPos(
            preview,
            @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))), // HWND_TOPMOST
            screen.x + source.scaled(16),
            screen.y + source.scaled(20),
            source.scaled(280),
            source.scaled(30),
            c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
        );
        _ = sys.InvalidateRect(preview, null, 1);
        // Spoken when what a drop does changes, never per pointer move, and
        // only once the label is on screen: a reader drops a live region
        // whose element is offscreen (`IsOffscreen` while it is hidden), and
        // the first label of a drag is shown here.
        if (!std.mem.eql(u8, self.tab_drag_label_action, action)) {
            self.tab_drag_label_action = action;
            if (self.tab_drag_preview_uia_provider) |provider| {
                if (builtin.is_test) test_tab_drag_label_shown_when_spoken = sys.IsWindowVisible(preview) != 0;
                provider.raiseLiveRegionChanged();
            }
        }
    }

    /// Under test: whether the drag label was on screen when it last raised
    /// its live region.
    pub var test_tab_drag_label_shown_when_spoken: ?bool = null;

    /// The window move its only tab started ended (`WM_EXITSIZEMOVE`): over
    /// another window's tab strip, the tab joins it, and this window, now
    /// empty, closes. A move that ended where it began (Esc, or no move)
    /// does nothing.
    pub fn finishOnlyTabWindowMove(self: *App, host: *Host, started: Host.OnlyTabMove) void {
        const hwnd = host.hwnd orelse return;
        if (host.tabs.items.len != 1) return;
        var now: RECT = undefined;
        if (sys.GetWindowRect(hwnd, &now) == 0) return;
        var pointer: POINT = undefined;
        if (sys.GetCursorPos(&pointer) == 0) return;
        const over = self.tabStripTargetAt(pointer, hwnd, null);
        const was = started.rect;
        const start_size: tab_drag.Size = .{ .width = was.right - was.left, .height = was.bottom - was.top };
        const end_size: tab_drag.Size = .{ .width = now.right - now.left, .height = now.bottom - now.top };
        const end_dpi = sys.GetDpiForWindow(hwnd);
        // The size it moved at, on the monitor it started on.
        const kept = tab_drag.keptSize(started.moving orelse start_size, started.dpi, end_size, end_dpi, Host.scaledBy(12, end_dpi));
        if (!tab_drag.windowMoveMerges(.{
            .moved = now.left != was.left or now.top != was.top,
            .resized = tab_drag.moveResized(start_size, started.moving, end_size),
            .dpi_changed = end_dpi != started.dpi,
            .zoomed = sys.IsZoomed(hwnd) != 0,
            .arranged = tab_drag.snapped(windowArranged(hwnd), windowLooksSnapped(hwnd, now), kept, end_dpi != started.dpi),
            .over_strip = over != null,
        })) return;
        _ = self.requestTabMove(host, host.tabs.items[0].id, .{ .window = over.? });
    }

    /// `tab_drag.looksSnapped` against the work area of the window's monitor,
    /// with the frame's invisible border as slack.
    fn windowLooksSnapped(hwnd: HWND, rect: RECT) bool {
        const monitor = sys.MonitorFromWindow(hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return false;
        var info: sys.MONITORINFO = std.mem.zeroes(sys.MONITORINFO);
        info.cbSize = @sizeOf(sys.MONITORINFO);
        if (sys.GetMonitorInfoW(monitor, &info) == 0) return false;
        const slack = Host.scaledBy(12, sys.GetDpiForWindow(hwnd));
        return tab_drag.looksSnapped(
            .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.bottom },
            .{ .left = info.rcWork.left, .top = info.rcWork.top, .right = info.rcWork.right, .bottom = info.rcWork.bottom },
            slack,
        );
    }

    /// `IsWindowArranged`: the window is snapped. Windows 10 has it only in
    /// later builds, and the target floor is older, so it is looked up; a
    /// build without it says nothing, and a snap still shows as a resize.
    /// Null where `user32` has no `IsWindowArranged`.
    fn windowArranged(hwnd: HWND) ?bool {
        const IsWindowArranged = *const fn (HWND) callconv(.winapi) BOOL;
        const user32 = sys.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"));
        const proc = sys.GetProcAddress(@ptrCast(user32), "IsWindowArranged") orelse return null;
        const arranged: IsWindowArranged = @ptrCast(@alignCast(proc));
        return arranged(hwnd) != 0;
    }

    /// Esc during a tab drag ends it where it began (`Host.cancelTabDrag`).
    /// The keyboard stays with the terminal during the drag, so the key is
    /// taken here, before it reaches the terminal.
    fn cancelTabDragForKey(self: *App, msg: *const MSG) bool {
        if (msg.wParam != c.VK_ESCAPE) return false;
        if (msg.message == c.WM_KEYUP) {
            if (!self.tab_drag_escape_down) return false;
            self.tab_drag_escape_down = false;
            return true;
        }
        if (msg.message != c.WM_KEYDOWN) return false;
        // Esc held after it ended a drag repeats (lParam bit 30, "was down"):
        // taken too, up to its key-up. A fresh press clears a key-up flag
        // that focus loss left (its key-up never came).
        const repeat = (@as(usize, @bitCast(msg.lParam)) & (1 << 30)) != 0;
        if (repeat and self.tab_drag_escape_down) return true;
        self.tab_drag_escape_down = false;
        for (self.registry.hosts.items) |host| {
            // A button merely pressed is not a drag yet: Esc is the terminal's.
            if (host.tab_drag_index == null or !host.tab_drag_active) continue;
            host.cancelTabDrag();
            self.tab_drag_escape_down = true;
            return true;
        }
        return false;
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
        var words: confirm_text.Words = .{};
        defer words.deinit(alloc);
        const prompt = try words.link(alloc, .{ .url = link, .scheme = scheme, .handler = handler });
        try host.showConfirm(prompt, &linkConfirmAccept, &linkConfirmCancel, surface);
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
    fn linkHandlerName(alloc: Allocator, scheme: []const u8, comptime query: anytype) confirm_text.LinkHandler {
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
            try std.testing.expectEqualStrings(open_refused_banner, host.banner_text.?);
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
            try std.testing.expectEqualStrings(open_refused_banner, host.banner_text.?);
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
        surface.showQuickSelectNotice(Surface.quick_select_no_targets_banner);
        try std.testing.expectEqualStrings(Surface.quick_select_no_targets_banner, host.banner_text.?);
        surface.showQuickSelectNotice(Surface.quick_select_too_many_banner);
        try std.testing.expectEqualStrings(Surface.quick_select_too_many_banner, host.banner_text.?);
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
            var words: confirm_text.Words = .{};
            defer words.deinit(alloc);
            const asked = try words.link(alloc, .{ .url = link, .scheme = scheme, .handler = handler });
            try std.testing.expectEqualStrings(asked.body, payload.body);
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
        for ([_]struct { []const u16, u32, windows.HRESULT, confirm_text.LinkHandler }{
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
        // A baseline no group of which has followed the file since it was
        // read: each record is as `original` gives it.
        const baselines: settings_patch.Baselines = .of(original);
        return self.settingsSaveAndReloadFrom(pending, original, &baselines);
    }

    /// `settingsSaveAndReload`, with the draft's baseline for each group of
    /// profile keys (`baselines`, the Settings window's, which may have
    /// followed the file since `original` was read): the check for another
    /// program's change compares each with its own record
    /// (`settings_patch.changedUnder`).
    pub fn settingsSaveAndReloadFrom(self: *App, pending: *const configpkg.Config, original: *const configpkg.Config, baselines: *const settings_patch.Baselines) win32_settings.SaveError!void {
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
        // What the check before this save read of the file, taken here so a
        // later save without one compares nothing stale.
        var check: SettingsCheck = self.settings_check orelse .{ .read_as = null, .apply = true };
        self.settings_check = null;
        var checked_again = false;
        var profile_edits: []settings_patch.Edit = undefined;
        while (true) {
            _ = profile_arena.reset(.retain_capacity);
            profile_edits = settings_patch.editsForSave(profile_arena.allocator(), alloc, &.{&self.config}, state, original, pending, target_path, &settings_reference.samePath) catch |err|
                return settingsProfileEditsFailed(err);
            // Whether another file still names a removed profile decides a
            // tombstone or a deletion, and `self.config` is as of the last
            // reload: a file that gained the profile since, with no reload,
            // would be missed and the profile come back. With profile edits to
            // make, the layers are read from disk again
            // (`settingsProfileEditsFromDisk`), a check of their own: the file
            // is compared with what it held as they were read, unless the
            // check before the save read it first.
            if (profile_edits.len != 0) {
                if (check.read_as == null) check.read_as = try self.settingsDigest(alloc, target_path);
                // Every fresh read: the profile fields the draft changes
                // have no Keep mine / Use disk, so one another program
                // changed since Settings read the config stops the save
                // (before the save, or while it ran); an edit to anything
                // else is saved on top of, as an ordinary one is. Not in
                // recovery: its baseline is the recovery config, not the
                // file, so a repair would read as a change (the file's
                // digests are still compared).
                const compare: ?ProfileCompare = if (self.safe_mode) null else .{ .edits = profile_edits, .baselines = baselines };
                profile_edits = try settingsProfileEditsFromDisk(profile_arena.allocator(), alloc, &self.settings_failure_detail, self.loadConfigAtStartupCwd(), &self.config, state, original, pending, target_path, compare);
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
            persistSettings(alloc, target_path, pending, user_edited, profile_edits, &self.settings_failure_detail, check.read_as) catch |err| {
                if (err != error.DiskChanged or checked_again) return err;
                // In recovery there is no baseline from the file to check it
                // against (`settingsCheckDisk` skips recovery), so a retry
                // would write over the edit it just found. Nothing is
                // written; the person saves again to write over it.
                if (self.safe_mode) return err;
                // Another program edited the file after the check read it, and
                // nothing was written. It is checked again, as before the save:
                // an edit under an edited setting goes to the window's choice
                // (Keep mine or Use disk), or refuses the palette's pick, and
                // any other edit is kept by saving once more on top of it.
                log.info("settings save: the config file changed after the check; checking it again", .{});
                checked_again = true;
                if (try self.settingsCheckDisk(pending, original, check.apply)) return error.DiskChanged;
                check = self.settings_check orelse .{ .read_as = null, .apply = check.apply };
                self.settings_check = null;
                continue;
            };
            break;
        }

        // Saving can repair the config on disk, but recovery applies it only
        // after restart, as the safe-mode banner promises.
        if (self.safe_mode) return;

        // Mirror the `.reload_config` hard-reload path: re-read from disk and
        // push through CoreApp so every surface's next frame picks up the
        // new values.
        // The file is written: a reload that cannot be read (no memory)
        // applies nothing, and the save is done (`SavedNotApplied`).
        var reloaded = self.loadConfigAtStartupCwd() catch |err| return savedNotApplied("read", err);
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
        // The settings and profile fields as `updateConfig` will apply them,
        // in the app's light/dark state: a theme can set a key, or define a
        // profile, in one state only (a dark theme's `default-profile` takes
        // over when Automatic deletes the file's line).
        // One that cannot be put in that state (no memory) applies nothing:
        // the light reading is not what the app runs, and `updateConfig`
        // would read the theme again, unchecked. The file is written, so
        // the save is done, and the window says to reload
        // (`SavedNotApplied`).
        var reloaded_applied: ?configpkg.Config = reloaded.changeConditionalState(self.core_app.config_conditional_state) catch |err|
            return savedNotApplied("put in the app's light/dark state", err);
        defer if (reloaded_applied) |*value| value.deinit();
        const applied: *const configpkg.Config = if (reloaded_applied) |*value| value else &reloaded;
        // From here on as well, a failure is the save's outcome, never a
        // failed save: the file is written. Nothing is applied yet.
        postWriteStep(.masked_check);
        masked_text.writer.writeAll(settingsMaskedKeyNames(&masked_buf, user_edited, pending, applied)) catch |err|
            return savedNotApplied("checked for overridden settings", err);
        // A file the reload could not read whole: what it missed is no
        // override, and the save says that instead, naming the file.
        postWriteStep(.report);
        // A later layer's alias for a profile the save hid hides nothing
        // more: the windows' profiles tell (`settings_patch.listCheck`), when
        // a window has them all. A list that missed some cannot tell what an
        // alias names, so without the whole list that check is unavailable.
        const listed = self.settingsProfileList(false);
        for (profile_edits) |*edit| if (edit.field.isList()) {
            if (listed) |found| if (found.complete) {
                // With the profiles the save adds, which no window has yet.
                edit.profiles = settings_patch.withDraftProfiles(profile_arena.allocator(), found.profiles, pending) catch |err|
                    return savedNotApplied("checked for overridden settings", err);
                continue;
            };
            edit.profiles_complete = false;
        };
        const report = settings_patch.reloadReport(&masked_text.writer, profile_edits, applied, &reloaded, masked_text.written().len > 0) catch |err|
            return savedNotApplied("checked for overridden settings", err);
        switch (report) {
            .unread => |unread| {
                // Without the memory to name the file, the status says it
                // without the name.
                postWriteStep(.describe);
                if (unread.describe(alloc)) |text| {
                    defer alloc.free(text);
                    self.settings_failure_detail.set(alloc, text);
                } else |_| self.settings_failure_detail.clear(alloc);
                // The file is written, but the reload is partial: applied, it
                // would run the app without what it missed (keybinds, colors)
                // until the next reload. The running config stays, and the
                // status says to reload once the file can be read whole.
                log.warn("settings save: saved, but the reload could not read a config file whole; the running settings are kept", .{});
                return error.SavedButUnread;
            },
            .held, .masked, .unchecked => {},
        }
        const masked = masked_text.written();
        if (masked.len > 0) {
            std.log.warn("settings save: saved but masked by a later config-file layer: {s}", .{masked});
            self.settings_masked_keys.set(alloc, masked);
        }

        // The reading checked above, already in the app's light/dark state:
        // `updateConfig` installs it as it is. Handed the light reload, it
        // would put it in that state again, reading the theme again,
        // unchecked, and a theme that had become unreadable in between would
        // be installed partly read. It updates each terminal and then the
        // app (`SavedPartlyApplied` either way): a terminal's step that
        // fails leaves the running settings as they were (`updateCoreConfig`
        // reloads the app config in place), and a failure in the app's step
        // after the install leaves only the failing window's apply or pane's
        // scrollbar refresh undone (the step goes on past it and runs its
        // tail before it returns the failure).
        postWriteStep(.apply);
        self.updateCoreConfig(applied) catch |err| {
            log.warn("settings save: saved, but applying the reload failed; the running settings are the previous ones, or partly updated after a late failure err={}", .{err});
            return error.SavedPartlyApplied;
        };
        // The reload read the file again, so what is wrong in it is news.
        _ = self.reportRecordedConfigProblems();
        if (masked.len > 0) return error.SavedButMasked;
        // Nothing found masked, and a hidden list could not be checked.
        if (report == .unchecked) return error.SavedListsUnchecked;
    }

    /// Tests only: the hook before a step after the write
    /// (`settings_patch.test_post_write`).
    fn postWriteStep(step: settings_patch.PostWriteStep) void {
        if (builtin.is_test) if (settings_patch.test_post_write) |hook| hook(step);
    }

    /// A failure after the save wrote the file and before anything of its
    /// reload is applied (`what` failed; no memory): the save is done, and
    /// the running settings are kept (`SavedNotApplied`).
    fn savedNotApplied(comptime what: []const u8, err: anyerror) win32_settings.SaveError {
        log.warn("settings save: saved, but the reload could not be " ++ what ++ "; the running settings are kept err={}", .{err});
        return error.SavedNotApplied;
    }

    /// What the file the save writes holds now (`save_target.digestNow`), for
    /// the comparisons before the write. A read that fails stops the save:
    /// without it, an edit another program made later would be written over
    /// with nothing to compare (SETTINGS-SAVE-TOCTOU).
    fn settingsDigest(self: *App, alloc: Allocator, target_path: []const u8) win32_settings.SaveError!save_target.Digest {
        return save_target.digestNow(alloc, target_path) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.DanglingLink => error.DanglingLink,
            error.ReadFailed, error.TooLarge, error.Unstable => {
                log.warn("settings save: could not read the config file to check it for edits err={}", .{err});
                const text = std.fmt.allocPrint(alloc, "the config file {s}", .{target_path}) catch return error.OutOfMemory;
                defer alloc.free(text);
                self.settings_failure_detail.set(alloc, text);
                return error.FileUnopenable;
            },
        };
    }

    /// `settingsSaveAndReload` checking the file again: whether another
    /// program changed a profile field the draft changes (`edits`, and both
    /// lists when either is written), from `now`: the fresh reading in the
    /// app's light/dark state, already known to be whole,
    /// `settingsProfileEditsFromDisk` (one that missed a file would read what
    /// that file gives as changed). `settings_patch.changedUnder` compares it
    /// in the state the baseline was read in. One it did stops the save,
    /// naming the field (its key, profile and variable; never a value); a
    /// reading it could not put in that state stops it too.
    fn settingsProfilesUnchanged(
        alloc: Allocator,
        detail: *win32_settings.FailureDetail,
        now: *const configpkg.Config,
        pending: *const configpkg.Config,
        compare: ProfileCompare,
        target_path: []const u8,
    ) win32_settings.SaveError!void {
        const found = settings_patch.changedUnder(compare.edits, compare.baselines, pending, now, target_path, &settings_reference.samePath) catch |err|
            return settingsProfileEditsFailed(err);
        const edit = found orelse return;
        var name: std.Io.Writer.Allocating = .init(alloc);
        defer name.deinit();
        settings_patch.writeEditName(&name.writer, edit) catch return error.OutOfMemory;
        detail.set(alloc, name.written());
        log.warn("settings save: another program changed a profile field the draft changes; nothing saved", .{});
        return error.ProfileChanged;
    }

    /// What a save's check for another program's change compares
    /// (`settingsProfilesUnchanged`): the draft's profile edits, and the
    /// baseline of each group of keys they belong to.
    const ProfileCompare = struct {
        edits: []const settings_patch.Edit,
        baselines: *const settings_patch.Baselines,
    };

    /// The profile edits a save makes, worked out against the config layers
    /// read again from disk (`fresh`, the read's result, owned here) and
    /// against `held`, the config as last read, in `state`
    /// (`settings_patch.editsForSave`): a removal keeps its line when either
    /// shows another layer naming it, or could have missed one.
    ///
    /// The fresh read is held to the rule the disk check before an ordinary
    /// save holds it to (`settingsDiskVerdict`), and its reading in `state`
    /// to `settings_patch.unreadConfigFile`: a file it could not open, read
    /// whole or decode stops the save. Of the held config switched to `state`
    /// here, only what that switch read itself, its theme
    /// (`settings_patch.unreadTheme`), stops it; its config-file and include
    /// problems are from its last read, possibly repaired since, and keep a
    /// removed profile's tombstone instead (`referencedElsewhere`).
    ///
    /// With `compare` (the draft's edits and the baseline of each group of
    /// profile keys; null in recovery, whose baseline is not the file), a
    /// profile field they change that another program changed too stops the
    /// save (`settingsProfilesUnchanged`), judged on the reading in `state`
    /// this decides the edits from, once it is known to be whole, put in the
    /// state of the field's own baseline (`settings_patch.changedUnder`; a
    /// theme that switch cannot read stops the save). A read that fails stops
    /// the save. Nothing is written then, and `detail` names the file or the
    /// field.
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
        compare: ?ProfileCompare,
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
        // The fresh read, whole; and of the held config switched here, what
        // the switch read itself: its theme. The held config's other
        // problems are from its last read, and the files may have been
        // repaired since: they do not stop the save, but count as naming a
        // removed profile, which keeps its tombstone
        // (`settings_patch.referencedElsewhere`).
        for (readings[0..if (held_now != null) 2 else 1], 0..) |reading, i| {
            const found = if (i == 0) settings_patch.unreadConfigFile(reading) else settings_patch.unreadTheme(reading);
            if (found) |unread| {
                // A file the reading skipped as UTF-16 that does not decode
                // (the held config's theme, read again in `state`, is one):
                // named as the check before a save names one.
                const text = (if (unread.undecodable)
                    std.fmt.allocPrint(alloc, "the file {s}", .{unread.path})
                else
                    unread.describe(alloc)) catch return error.OutOfMemory;
                defer alloc.free(text);
                detail.set(alloc, text);
                return if (unread.undecodable) error.UnsupportedEncoding else error.FileUnopenable;
            }
        }
        // A move or a hide writes both lists into the file: not while
        // another layer sets them in the layers read now (the window checked
        // when it built the page; a reload since may have changed that).
        if (settings_patch.listsChanged(original, pending)) {
            const foreign = settings_patch.listsForeign(&disk, target_path, &settings_reference.samePath) catch |err| return settingsProfileEditsFailed(err);
            if (foreign) |why| {
                detail.set(alloc, why.text());
                log.warn("settings save: another layer sets the profile order or the hidden profiles ({t}); nothing saved", .{why});
                return error.ProfileListsForeign;
            }
        }
        if (compare) |what| try settingsProfilesUnchanged(alloc, detail, readings[0], pending, what, target_path);
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
        if (builtin.is_test) if (settings_patch.test_config_load) |load| return load(self.core_app.alloc);
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
        _ = try self.settingsCheckDisk(pending, original, apply);
    }

    /// What a check before a Settings save leaves for the save
    /// (`settings_check`).
    const SettingsCheck = struct { read_as: ?save_target.Digest, apply: bool };

    /// `settingsReconcileDisk`, saying whether the file changed under an
    /// edited setting (then applied, when `apply`). It leaves for the save
    /// that follows what it read of the file (`settings_check`), taken before
    /// the load it judges: an edit after that is a difference the save sees.
    fn settingsCheckDisk(
        self: *App,
        pending: *const configpkg.Config,
        original: *const configpkg.Config,
        apply: bool,
    ) win32_settings.SaveError!bool {
        self.settings_check = .{ .read_as = null, .apply = apply };
        // Recovery may repair the file, but must never apply its settings live,
        // including through conflict reconciliation before the save.
        if (self.safe_mode) return false;
        const alloc = self.core_app.alloc;
        self.settings_failure_detail.clear(alloc);
        const user_edited = settingsUserEditedKeys(original, pending);
        if (user_edited.count() == 0) return false;
        const target_path = try self.settingsTargetPath(alloc);
        defer alloc.free(target_path);
        try settingsFileOpenable(alloc, &self.settings_failure_detail, "the config file", target_path);
        const read_as = try self.settingsDigest(alloc, target_path);
        var disk = self.loadConfigAtStartupCwd() catch |err| {
            log.warn("settings save: could not read the config file to check it for edits err={}", .{err});
            return error.ReloadFailed;
        };
        defer disk.deinit();
        if (!try settingsDiskVerdict(alloc, &self.settings_failure_detail, original, pending, &disk, self.core_app.config_conditional_state, user_edited)) {
            self.settings_check = .{ .read_as = read_as, .apply = apply };
            return false;
        }
        if (!apply) return error.DiskChanged;
        log.info("settings save: the config file changed on disk under an edited setting; offering the choice", .{});
        self.updateCoreConfig(&disk) catch |err| {
            log.warn("settings save: applying the changed config file failed err={}", .{err});
            return error.ReloadFailed;
        };
        return true;
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
            try std.testing.expectError(error.FileUnopenable, App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, .{}, &held, &pending, path, null));
            const expected = try std.fmt.allocPrint(alloc, "the included file {s}", .{path});
            defer alloc.free(expected);
            try std.testing.expect(std.mem.eql(u8, expected, detail.text.?));
        }
        // A read that fails: the save stops.
        try std.testing.expectError(error.ReloadFailed, App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, error.AccessDenied, &held, .{}, &held, &pending, path, null));
        // A whole read: the edits, and nothing else names `py`, so its line goes.
        {
            var fresh = try configpkg.Config.default(alloc);
            errdefer fresh.deinit();
            try fresh.loadFile(alloc, path);
            const edits = try App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, .{}, &held, &pending, path, null);
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
            try std.testing.expectError(error.FileUnopenable, App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, dark_state, &held, &pending, path, null));
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
        const edits = try App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, dark_state, &held, &pending, path, null);
        for (edits) |e| if (e.field == .command) try std.testing.expect(e.op == .unset);
    }

    /// The App's Settings save over files in a scratch directory: the config
    /// loads from `files` in that order (`test_config_load`), the save writes
    /// `files`' last (`cli_config_override_path`), and nothing reaches the real
    /// profile. `hook` stands in for another program (`save_target`).
    const SaveTest = struct {
        threadlocal var files: []const []const u8 = &.{};
        /// What the other program writes into `hook_path`, appended or in
        /// place of what is there, just before the save compares the file.
        threadlocal var hook_path: []const u8 = "";
        threadlocal var hook_text: []const u8 = "";
        threadlocal var hook_append: bool = false;
        /// A file the other program holds locked from then on.
        threadlocal var lock_path: []const u8 = "";
        threadlocal var lock: ?std.fs.File = null;
        /// A lock taken while a read is under way (`lockDuringRead`), let go
        /// before the next load.
        threadlocal var brief_lock: ?std.fs.File = null;
        /// What happens to the load after the write (`starveNext` or
        /// `failNext`, set as `hook` is; `starvedLoad`): it is read whole and
        /// from then on its allocator has no memory, so a light/dark switch
        /// of it fails; or it fails itself.
        threadlocal var starve: enum { none, after_read, read, app_after_read } = .none;
        threadlocal var starving: std.testing.FailingAllocator = undefined;
        /// The App's allocator in a test of what follows the write (`.app_after_read`).
        threadlocal var fail_next: ?*FailNext = null;
        /// The step after the write whose first allocation fails
        /// (`failAt`, `settings_patch.test_post_write`).
        threadlocal var fail_step: ?settings_patch.PostWriteStep = null;

        fn failAt(step: settings_patch.PostWriteStep) void {
            if (fail_step != step) return;
            fail_step = null;
            if (fail_next) |failing| failing.armed = true;
        }

        /// An allocator that fails its next allocation once armed, and only
        /// that one; everything else goes to `parent`, so what it allocates
        /// is `parent`'s to free.
        const FailNext = struct {
            parent: Allocator,
            armed: bool = false,

            fn allocator(self: *FailNext) Allocator {
                return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
            }

            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
                const self: *FailNext = @ptrCast(@alignCast(ctx));
                if (self.armed) {
                    self.armed = false;
                    return null;
                }
                return self.parent.rawAlloc(len, alignment, ret_addr);
            }

            fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
                const self: *FailNext = @ptrCast(@alignCast(ctx));
                return self.parent.rawResize(memory, alignment, new_len, ret_addr);
            }

            fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                const self: *FailNext = @ptrCast(@alignCast(ctx));
                return self.parent.rawRemap(memory, alignment, new_len, ret_addr);
            }

            fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
                const self: *FailNext = @ptrCast(@alignCast(ctx));
                self.parent.rawFree(memory, alignment, ret_addr);
            }
        };

        fn load(alloc: Allocator) anyerror!configpkg.Config {
            if (brief_lock) |file| file.close();
            brief_lock = null;
            var cfg = try configpkg.Config.default(alloc);
            errdefer cfg.deinit();
            for (files) |file| try cfg.loadFile(alloc, file);
            try cfg.loadRecursiveFiles(alloc);
            try cfg.finalize();
            return cfg;
        }

        fn hook() void {
            save_target.test_before_compare = null;
            if (hook_path.len != 0) {
                const file = (if (hook_append) std.fs.openFileAbsolute(hook_path, .{ .mode = .read_write }) else std.fs.createFileAbsolute(hook_path, .{})) catch return;
                defer file.close();
                if (hook_append) file.seekFromEnd(0) catch return;
                file.writeAll(hook_text) catch return;
            }
            if (lock_path.len != 0) lock = std.fs.openFileAbsolute(lock_path, .{ .mode = .read_write, .lock = .exclusive }) catch null;
        }

        fn starveNext() void {
            save_target.test_before_compare = null;
            starve = .after_read;
        }

        fn failNext() void {
            save_target.test_before_compare = null;
            starve = .read;
        }

        fn failAppNext() void {
            save_target.test_before_compare = null;
            starve = .app_after_read;
        }

        fn starvedLoad(alloc: Allocator) anyerror!configpkg.Config {
            const how = starve;
            starve = .none;
            switch (how) {
                .none => return load(alloc),
                .read => return error.OutOfMemory,
                .app_after_read => {
                    const cfg = try load(alloc);
                    if (fail_next) |failing| failing.armed = true;
                    return cfg;
                },
                .after_read => {
                    starving = .init(alloc, .{});
                    const cfg = try load(starving.allocator());
                    starving.fail_index = starving.alloc_index;
                    return cfg;
                },
            }
        }

        fn lockDuringRead() void {
            save_target.test_during_read = null;
            brief_lock = std.fs.openFileAbsolute(lock_path, .{ .mode = .read_write, .lock = .exclusive }) catch null;
        }

        fn begin(app: *App, target: []const u8) !void {
            errdefer end(app);
            settings_patch.test_config_load = load;
            app.cli_config_override_path = @constCast(target);
            var loaded = try load(std.testing.allocator);
            defer loaded.deinit();
            try app.updateCoreConfig(&loaded);
        }

        fn end(app: *App) void {
            app.cli_config_override_path = null;
            app.settings_failure_detail.clear(std.testing.allocator);
            app.settings_masked_keys.clear(std.testing.allocator);
            save_target.test_before_compare = null;
            save_target.test_during_read = null;
            settings_patch.test_config_load = null;
            if (brief_lock) |file| file.close();
            brief_lock = null;
            starve = .none;
            fail_next = null;
            fail_step = null;
            settings_patch.test_post_write = null;
            files = &.{};
            hook_path = "";
            hook_text = "";
            hook_append = false;
            lock_path = "";
            if (lock) |file| file.close();
            lock = null;
        }

        fn read(path: []const u8) ![]u8 {
            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();
            return file.readToEndAlloc(std.testing.allocator, 1 << 20);
        }
    };

    test "win32 settings save does not write over an edit another program made after the check, and offers the choice" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = blk: {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" });
            break :blk try tmp.dir.realpathAlloc(alloc, "config");
        };
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);

        const Case = enum { between, before_write };
        for ([_]Case{ .between, .before_write }) |case| {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" });
            {
                var loaded = try SaveTest.load(alloc);
                defer loaded.deinit();
                try app.updateCoreConfig(&loaded);
            }
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            pending.@"font-size" = 15;
            // The check finds the file as the window last read it.
            try app.settingsReconcileDisk(&pending, &original, true);
            // Another program sets the same setting: between the check and
            // the save, or as the save is about to put its bytes in place.
            switch (case) {
                .between => try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 20\n" }),
                .before_write => {
                    SaveTest.hook_path = path;
                    SaveTest.hook_text = "font-size = 20\n";
                    save_target.test_before_compare = SaveTest.hook;
                },
            }
            // Nothing is written over it: the save stops, and the file is
            // applied as a reload, which hands the window its choice.
            try std.testing.expectError(error.DiskChanged, app.settingsSaveAndReload(&pending, &original));
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            try std.testing.expectEqualStrings("font-size = 20\n", after);
            try std.testing.expectEqual(@as(f32, 20), app.config.@"font-size");
        }

        // An edit to another setting is kept: the file is checked again, and
        // the save goes on top of it.
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" });
        {
            var loaded = try SaveTest.load(alloc);
            defer loaded.deinit();
            try app.updateCoreConfig(&loaded);
        }
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        pending.@"font-size" = 15;
        try app.settingsReconcileDisk(&pending, &original, true);
        SaveTest.hook_path = path;
        SaveTest.hook_text = "copy-on-select = true\n";
        SaveTest.hook_append = true;
        save_target.test_before_compare = SaveTest.hook;
        try app.settingsSaveAndReload(&pending, &original);
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expectEqualStrings("font-size = 15\ncopy-on-select = true\n", after);
        try std.testing.expectEqual(@as(f32, 15), app.config.@"font-size");
        try std.testing.expect(app.config.@"copy-on-select" == .true);
    }

    test "win32 settings save checking the file again stops on a profile field another program changed, and saves over one it did not" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const raw = "font-size = 12\nprofile-command = py: python.exe\nprofile-command = node: node.exe\n";
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = raw });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        const Case = struct { other: []const u8, refused: bool };
        for ([_]Case{
            // The same profile's command: refused.
            .{ .other = "font-size = 12\nprofile-command = py: python.exe -O\nprofile-command = node: node.exe\n", .refused = true },
            // Another profile's: saved over, the other edit kept.
            .{ .other = "font-size = 12\nprofile-command = py: python.exe\nprofile-command = node: node.exe --inspect\n", .refused = false },
        }) |case| {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = raw });
            {
                var loaded = try SaveTest.load(alloc);
                defer loaded.deinit();
                try app.updateCoreConfig(&loaded);
            }
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            pending.@"font-size" = 15;
            try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py: python.exe -X");
            try app.settingsReconcileDisk(&pending, &original, true);
            // Another program writes the file as the save is about to put
            // its bytes in place.
            SaveTest.hook_path = path;
            SaveTest.hook_text = case.other;
            SaveTest.hook_append = false;
            save_target.test_before_compare = SaveTest.hook;
            if (case.refused) {
                try std.testing.expectError(error.ProfileChanged, app.settingsSaveAndReload(&pending, &original));
                const after = try SaveTest.read(path);
                defer alloc.free(after);
                try std.testing.expect(std.mem.eql(u8, case.other, after));
                try std.testing.expect(std.mem.eql(u8, "profile-command py", app.settings_failure_detail.text orelse return error.TestExpectedDetail));
            } else {
                try app.settingsSaveAndReload(&pending, &original);
                const after = try SaveTest.read(path);
                defer alloc.free(after);
                try std.testing.expect(std.mem.eql(u8, "font-size = 15\nprofile-command = py: python.exe -X\nprofile-command = node: node.exe --inspect\n", after));
            }
        }
    }

    test "win32 settings profile save stops on a field another program changed before the save, and not on what a removal covers" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "# a file loaded first\n" });
        const lower = try tmp.dir.realpathAlloc(alloc, "lower.conf");
        defer alloc.free(lower);
        const raw = "font-size = 12\nprofile-command = py: python.exe\nprofile-env = py: Path=C:\\bin\n";
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = raw });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{ lower, path };
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        const Case = enum { same_field, lower_label, renamed_variable };
        for ([_]Case{ .same_field, .lower_label, .renamed_variable }) |case| {
            try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "# a file loaded first\n" });
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = raw });
            {
                var loaded = try SaveTest.load(alloc);
                defer loaded.deinit();
                try app.updateCoreConfig(&loaded);
            }
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            switch (case) {
                // The draft changes py's command line.
                .same_field => try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py: python.exe -X"),
                // The draft removes py.
                .lower_label, .renamed_variable => try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:"),
            }
            try app.settingsReconcileDisk(&pending, &original, true);
            // Before Save, another program edits the files.
            switch (case) {
                .same_field => try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\nprofile-command = py: python.exe -O\nprofile-env = py: Path=C:\\bin\n" }),
                .lower_label => try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "profile-name = py: Python\nprofile-env = py: MODE=1\n" }),
                .renamed_variable => try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\nprofile-command = py: python.exe\nprofile-env = py: PATH=C:\\bin\n" }),
            }
            const before = try SaveTest.read(path);
            defer alloc.free(before);
            switch (case) {
                // The field the draft changes: refused, the file as the other
                // program left it.
                .same_field => {
                    try std.testing.expectError(error.ProfileChanged, app.settingsSaveAndReload(&pending, &original));
                    const after = try SaveTest.read(path);
                    defer alloc.free(after);
                    try std.testing.expect(std.mem.eql(u8, before, after));
                    try std.testing.expect(std.mem.eql(u8, "profile-command py", app.settings_failure_detail.text orelse return error.TestExpectedDetail));
                },
                // A lower layer gives the removed profile a label and a
                // variable, and a variable's name changed case: none is a
                // field the draft changes. The removal is saved.
                .lower_label, .renamed_variable => {
                    app.settingsSaveAndReload(&pending, &original) catch |err| switch (err) {
                        error.SavedButMasked => {},
                        else => return err,
                    };
                    const after = try SaveTest.read(path);
                    defer alloc.free(after);
                    try std.testing.expect(std.mem.indexOf(u8, after, "python.exe") == null);
                    // The lower layer names `py` now: a tombstone, not a
                    // deletion, or `py` would come back from it.
                    if (case == .lower_label) try std.testing.expect(std.mem.indexOf(u8, after, "profile-command = py:\n") != null);
                },
            }
        }
    }

    test "win32 settings profile save names an include it could not read, not a change to the profile it defines" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "profile-command = py: python.exe\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py: python.exe -X");
        // Another program locks the include's bytes as the save reads the
        // layers again: `py` is missing from that reading, which is the
        // file's doing, not another program's edit of `py`.
        {
            var lock = try tmp.dir.openFile("more.conf", .{ .mode = .read_write, .lock = .exclusive });
            defer lock.close();
            try std.testing.expectError(error.FileUnopenable, app.settingsSaveAndReload(&pending, &original));
        }
        const expected = try std.fmt.allocPrint(alloc, "the included file {s}", .{more});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.eql(u8, expected, app.settings_failure_detail.text orelse return error.TestExpectedDetail));
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, text, after));
    }

    test "win32 settings profile save in recovery writes a repair, and does not apply it" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const raw = "profile-command = py: python.exe\n";
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = raw });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        // Recovery: the running config is the recovery one, not the file.
        app.safe_mode = true;
        try configpkg.pane_launch.useRecovery(&app.config);
        SaveTest.files = &.{path};
        settings_patch.test_config_load = SaveTest.load;
        app.cli_config_override_path = @constCast(path);
        defer SaveTest.end(&app);
        const revision = app.config_revision;
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        // The person repairs `py`, which the file already defines.
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py: python.exe -X");
        try app.settingsReconcileDisk(&pending, &original, true);
        try app.settingsSaveAndReload(&pending, &original);
        // Written,
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, "profile-command = py: python.exe -X\n", after));
        // and not applied: the running config is still the recovery one.
        try std.testing.expectEqual(revision, app.config_revision);
        try std.testing.expect(app.config.@"profile-command".get("py") == null);
    }

    test "win32 settings save in recovery does not write over a file another program changed while it saved" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        // Recovery: the running config is the recovery one, not the file.
        app.safe_mode = true;
        try configpkg.pane_launch.useRecovery(&app.config);
        SaveTest.files = &.{path};
        settings_patch.test_config_load = SaveTest.load;
        app.cli_config_override_path = @constCast(path);
        defer SaveTest.end(&app);
        const revision = app.config_revision;
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        pending.@"font-size" = 15;
        try app.settingsReconcileDisk(&pending, &original, true);
        // Another program sets the same setting as the save is about to put
        // its bytes in place.
        SaveTest.hook_path = path;
        SaveTest.hook_text = "font-size = 20\n";
        save_target.test_before_compare = SaveTest.hook;
        // There is no baseline from the file to decide by: nothing is
        // written, and nothing is applied.
        try std.testing.expectError(error.DiskChanged, app.settingsSaveAndReload(&pending, &original));
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expectEqualStrings("font-size = 20\n", after);
        try std.testing.expectEqual(revision, app.config_revision);
        try std.testing.expectEqual(@as(f32, 15), pending.@"font-size");
        // Saved again, it writes over the edit, knowingly.
        try app.settingsSaveAndReload(&pending, &original);
        const again = try SaveTest.read(path);
        defer alloc.free(again);
        try std.testing.expectEqualStrings("font-size = 15\n", again);
        try std.testing.expectEqual(revision, app.config_revision);
    }

    test "win32 settings save stops when its check cannot read the file it compares" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        pending.@"font-size" = 15;
        // Another program locks the file's bytes while the check reads it,
        // and lets go before the check's load: nothing to compare later.
        SaveTest.lock_path = path;
        save_target.test_during_read = SaveTest.lockDuringRead;
        try std.testing.expectError(error.FileUnopenable, app.settingsReconcileDisk(&pending, &original, true));
        const expected = try std.fmt.allocPrint(alloc, "the config file {s}", .{path});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.eql(u8, expected, app.settings_failure_detail.text orelse return error.TestExpectedDetail));
        // The check stopped before its load, which would have let go.
        if (SaveTest.brief_lock) |file| file.close();
        SaveTest.brief_lock = null;
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expectEqualStrings("font-size = 12\n", after);
    }

    test "win32 settings save whose reload skips an include that no longer decodes keeps the running settings" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "copy-on-select = true\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        pending.@"font-size" = 15;
        try app.settingsReconcileDisk(&pending, &original, true);
        // Another program rewrites the include as UTF-16 that does not
        // decode, after the check: the reload skips it whole.
        SaveTest.hook_path = more;
        SaveTest.hook_text = "\xff\xfe\x00\xd8a\x00";
        save_target.test_before_compare = SaveTest.hook;
        try std.testing.expectError(error.SavedButUnread, app.settingsSaveAndReload(&pending, &original));
        try std.testing.expectEqual(@as(f32, 12), app.config.@"font-size");
        try std.testing.expect(app.config.@"copy-on-select" == .true);
        const expected = try std.fmt.allocPrint(alloc, "the included file {s}", .{more});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.eql(u8, expected, app.settings_failure_detail.text orelse return error.TestExpectedDetail));
    }

    test "win32 palette theme pick whose reload reads a file only partly says so and keeps the running settings" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "copy-on-select = true\n" });
        try tmp.dir.writeFile(.{ .sub_path = "picked", .data = "font-size = 20\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const picked = try tmp.dir.realpathAlloc(alloc, "picked");
        defer alloc.free(picked);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        // Another program locks the include's bytes once the pick's check is
        // done: the save's reload reads part of it.
        SaveTest.lock_path = more;
        save_target.test_before_compare = SaveTest.hook;
        try host.commitPaletteTheme(picked);
        // Saved,
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.indexOf(u8, after, picked) != null);
        // the running settings kept, and the window says why.
        try std.testing.expect(app.config.@"copy-on-select" == .true);
        try std.testing.expectEqualStrings("Theme saved, but a config file could not be read whole. Reload the configuration once it can be read.", host.banner_text orelse return error.TestExpectedBanner);
    }

    test "win32 palette theme pick whose reload cannot be applied says it saved and keeps the running settings" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "picked", .data = "font-size = 20\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        const picked = try tmp.dir.realpathAlloc(alloc, "picked");
        defer alloc.free(picked);
        // An include names a light/dark pair, so the reload after the pick has
        // a switch to make; the app runs dark.
        const more_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\n", .{ light, dark });
        defer alloc.free(more_text);
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = more_text });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        app.core_app.config_conditional_state = .{ .theme = .dark };
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        // The reload after the write is read whole, and the switch to the
        // dark state runs out of memory.
        settings_patch.test_config_load = SaveTest.starvedLoad;
        save_target.test_before_compare = SaveTest.starveNext;
        try host.commitPaletteTheme(picked);
        // Saved,
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.indexOf(u8, after, picked) != null);
        // and the window says so, and to reload, rather than that the save
        // failed. (The running values cannot tell: the include's theme wins
        // over the pick whether the reload is applied, kept or rolled back.)
        try std.testing.expectEqualStrings("Theme saved, but the saved settings could not be applied. Reload the configuration to use them.", host.banner_text orelse return error.TestExpectedBanner);
    }

    test "settings save whose checks or apply fail after the write says it saved, never that it failed" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // The include overrides `font-size`, so a save of it has a masked
        // setting to name; `cursor-style` is overridden by nothing.
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "font-size = 20\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        // The App's allocator, which fails its next allocation once the
        // reload after the write is read.
        var fail_next: SaveTest.FailNext = .{ .parent = app.core_app.alloc };
        const real = app.core_app.alloc;
        app.core_app.alloc = fail_next.allocator();
        defer app.core_app.alloc = real;
        const Case = enum { masked_check, apply };
        for ([_]Case{ .masked_check, .apply }) |case| {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            SaveTest.fail_next = &fail_next;
            settings_patch.test_config_load = SaveTest.starvedLoad;
            save_target.test_before_compare = SaveTest.failAppNext;
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            // Naming the overridden setting is the first thing after the
            // read that allocates; with nothing overridden, it is
            // `updateConfig`, which may have updated some terminals.
            switch (case) {
                .masked_check => pending.@"font-size" = 15,
                .apply => pending.@"cursor-style" = .underline,
            }
            // The window shows a preview, as while a draft changes opacity.
            settingsPreviewFieldThunk(&app, .background_opacity, .{ .background_opacity = 0.5 });
            try std.testing.expect(app.settings_preview != null);
            // The save, as the window makes it: done, and said so.
            const result = settingsSaveAndReloadThunk(&app, &pending, &original, &.of(&original));
            try std.testing.expectError(switch (case) {
                .masked_check => error.SavedNotApplied,
                .apply => error.SavedPartlyApplied,
            }, result);
            try std.testing.expect(!fail_next.armed);
            try std.testing.expect(app.settings_preview == null);
            // Written.
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            try std.testing.expect(std.mem.indexOf(u8, after, switch (case) {
                .masked_check => "font-size = 15\n",
                .apply => "cursor-style = underline\n",
            }) != null);
        }
    }

    test "win32 palette theme pick whose checks fail after the write says it saved, rather than roll back" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "picked", .data = "font-size = 20\n" });
        try tmp.dir.writeFile(.{ .sub_path = "other", .data = "font-size = 14\n" });
        const picked = try tmp.dir.realpathAlloc(alloc, "picked");
        defer alloc.free(picked);
        const other = try tmp.dir.realpathAlloc(alloc, "other");
        defer alloc.free(other);
        // An include names another theme, so the pick is overridden and the
        // check after the write has a setting to name.
        const more_text = try std.fmt.allocPrint(alloc, "theme = {s}\n", .{other});
        defer alloc.free(more_text);
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = more_text });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var fail_next: SaveTest.FailNext = .{ .parent = app.core_app.alloc };
        const real = app.core_app.alloc;
        app.core_app.alloc = fail_next.allocator();
        defer app.core_app.alloc = real;
        SaveTest.fail_next = &fail_next;
        settings_patch.test_config_load = SaveTest.starvedLoad;
        save_target.test_before_compare = SaveTest.failAppNext;
        try host.commitPaletteTheme(picked);
        try std.testing.expect(!fail_next.armed);
        // Saved,
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.indexOf(u8, after, picked) != null);
        // and the window says so, and to reload, rather than that the save
        // failed.
        try std.testing.expectEqualStrings("Theme saved, but the saved settings could not be applied. Reload the configuration to use them.", host.banner_text orelse return error.TestExpectedBanner);
    }

    test "win32 palette theme pick whose write fails rolls back, and holds the config the palette lists from until the palette closes" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "picked", .data = "font-size = 20\n" });
        const picked = try tmp.dir.realpathAlloc(alloc, "picked");
        defer alloc.free(picked);
        const text = "font-size = 12\n";
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        const Case = enum { no_preview, preview };
        for ([_]Case{ .no_preview, .preview }) |case| {
            if (case == .preview) {
                try host.previewPaletteTheme(picked);
                try std.testing.expectEqual(@as(f32, 20), app.config.@"font-size");
            }
            // Another program locks the file's bytes as the save is about to
            // put its own in place: the save's last read of it fails, and
            // nothing is written.
            SaveTest.lock_path = path;
            save_target.test_before_compare = SaveTest.hook;
            try host.commitPaletteTheme(picked);
            if (SaveTest.lock) |file| file.close();
            SaveTest.lock = null;
            SaveTest.lock_path = "";
            // Rolled back: the config from before the pick (and its preview)
            // runs, and the file is as it was.
            try std.testing.expectEqual(@as(f32, 12), app.config.@"font-size");
            try std.testing.expectEqualStrings("Theme save failed; reverted preview.", host.banner_text orelse return error.TestExpectedBanner);
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            try std.testing.expectEqualStrings(text, after);
            // The palette stays open with the banner, and so keeps the config
            // its list was built from (`palette_catalog_retained_config`):
            // what a test that leaves it open reports as leaked. Closing the
            // palette releases it, as `Host.deinit` does for a window that
            // goes with the palette open.
            try std.testing.expect(host.palette_catalog_retained_config != null);
            host.hideOverlay();
            try std.testing.expect(host.palette_catalog_retained_config == null);
        }
    }

    test "win32 palette theme pick with a preview whose reload cannot be read keeps the preview running" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "picked", .data = "font-size = 20\n" });
        const picked = try tmp.dir.realpathAlloc(alloc, "picked");
        defer alloc.free(picked);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\n" });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        // The palette previews the theme: it runs.
        try host.previewPaletteTheme(picked);
        try std.testing.expectEqual(@as(f32, 20), app.config.@"font-size");
        // The pick is saved, and the reload after the write cannot be read.
        settings_patch.test_config_load = SaveTest.starvedLoad;
        save_target.test_before_compare = SaveTest.failNext;
        try host.commitPaletteTheme(picked);
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.indexOf(u8, after, picked) != null);
        // The previewed theme keeps running, rather than being rolled back
        // to the config from before the preview.
        try std.testing.expectEqual(@as(f32, 20), app.config.@"font-size");
        try std.testing.expectEqualStrings("Theme saved, but the saved settings could not be applied. Reload the configuration to use them.", host.banner_text orelse return error.TestExpectedBanner);
    }

    test "settings save whose report, file naming or apply fails after the write says it saved" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // The include overrides `font-size` and py's label.
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "font-size = 20\nprofile-name = py: Other\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nprofile-command = py: python.exe\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        // The App's allocator, which fails the first allocation of the step
        // a case names.
        var fail_next: SaveTest.FailNext = .{ .parent = app.core_app.alloc };
        const real = app.core_app.alloc;
        app.core_app.alloc = fail_next.allocator();
        defer app.core_app.alloc = real;
        const Case = enum { report, describe, apply };
        for ([_]Case{ .report, .describe, .apply }) |case| {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            SaveTest.fail_next = &fail_next;
            SaveTest.fail_step = switch (case) {
                .report => .report,
                .describe => .describe,
                .apply => .apply,
            };
            settings_patch.test_post_write = SaveTest.failAt;
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            switch (case) {
                // A profile label the include overrides: the report names
                // it, and that is the step's first allocation.
                .report => try pending.@"profile-name".parseCLI(pending._arena.?.allocator(), "py: Python"),
                // The include is locked as the save is about to put its
                // bytes in place: the reload reads it only partly, and the
                // file's name is the step's first allocation.
                .describe => {
                    pending.@"cursor-style" = .underline;
                    SaveTest.lock_path = more;
                    save_target.test_before_compare = SaveTest.hook;
                },
                // An overridden setting, and one that is not.
                .apply => {
                    pending.@"font-size" = 15;
                    pending.@"cursor-style" = .underline;
                },
            }
            const result = settingsSaveAndReloadThunk(&app, &pending, &original, &.of(&original));
            if (SaveTest.lock) |file| file.close();
            SaveTest.lock = null;
            SaveTest.lock_path = "";
            try std.testing.expect(!fail_next.armed);
            try std.testing.expect(SaveTest.fail_step == null);
            switch (case) {
                .report => try std.testing.expectError(error.SavedNotApplied, result),
                // Saved, and the status says the reload read a file only
                // partly, without its name.
                .describe => {
                    try std.testing.expectError(error.SavedButUnread, result);
                    try std.testing.expect(app.settings_failure_detail.text == null);
                },
                // Saved, maybe partly applied; the overridden setting is
                // named for the status, since a reload does not apply it.
                .apply => {
                    try std.testing.expectError(error.SavedPartlyApplied, result);
                    try std.testing.expectEqualStrings("font-size", app.settings_masked_keys.text orelse return error.TestExpectedMaskedKeys);
                },
            }
        }
    }

    test "win32 palette theme pick whose apply fails after the write says it may be only partly applied, and names a mask" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "picked", .data = "font-size = 20\n" });
        try tmp.dir.writeFile(.{ .sub_path = "other", .data = "font-size = 14\n" });
        const picked = try tmp.dir.realpathAlloc(alloc, "picked");
        defer alloc.free(picked);
        const other = try tmp.dir.realpathAlloc(alloc, "other");
        defer alloc.free(other);
        const more_text = try std.fmt.allocPrint(alloc, "theme = {s}\n", .{other});
        defer alloc.free(more_text);
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "font-size = 12\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        const path = blk: {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            break :blk try tmp.dir.realpathAlloc(alloc, "config");
        };
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var fail_next: SaveTest.FailNext = .{ .parent = app.core_app.alloc };
        const real = app.core_app.alloc;
        app.core_app.alloc = fail_next.allocator();
        defer app.core_app.alloc = real;
        const Case = enum { plain, masked };
        for ([_]Case{ .plain, .masked }) |case| {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            // The include names another theme, so it masks the pick.
            try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = if (case == .masked) more_text else "\n" });
            // The app runs the files as they are now, so the pick's check
            // finds no change on disk.
            {
                var loaded = try SaveTest.load(alloc);
                defer loaded.deinit();
                try app.updateCoreConfig(&loaded);
            }
            SaveTest.fail_next = &fail_next;
            SaveTest.fail_step = .apply;
            settings_patch.test_post_write = SaveTest.failAt;
            try host.commitPaletteTheme(picked);
            try std.testing.expect(SaveTest.fail_step == null);
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            try std.testing.expect(std.mem.indexOf(u8, after, picked) != null);
            try std.testing.expectEqualStrings(switch (case) {
                .plain => "Theme saved, but the saved settings may be only partly applied. Reload the configuration to apply all of them.",
                .masked => "Theme saved, but the saved settings may be only partly applied, and a later config layer masks the theme, so a reload does not apply it.",
            }, host.banner_text orelse return error.TestExpectedBanner);
        }
    }

    test "win32 settings save whose reload reads a file only partly keeps the running settings and names the file" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "copy-on-select = true\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const Case = enum { ordinary, profile };
        for ([_]Case{ .ordinary, .profile }) |case| {
            const text = try std.fmt.allocPrint(alloc, "font-size = 12\nprofile-command = py: python.exe\nconfig-file = {s}\n", .{more});
            defer alloc.free(text);
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            const path = try tmp.dir.realpathAlloc(alloc, "config");
            defer alloc.free(path);
            SaveTest.files = &.{path};
            try SaveTest.begin(&app, path);
            defer SaveTest.end(&app);
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            switch (case) {
                .ordinary => pending.@"font-size" = 15,
                .profile => try pending.@"profile-name".parseCLI(pending._arena.?.allocator(), "py: Python"),
            }
            // The window shows a preview of the opacity, as it does while a
            // draft changes it.
            if (case == .ordinary) {
                settingsPreviewFieldThunk(&app, .background_opacity, .{ .background_opacity = 0.5 });
                try std.testing.expect(app.settings_preview != null);
            }
            try app.settingsReconcileDisk(&pending, &original, true);
            // Another program locks the include's bytes once the check is
            // done: the save's reload opens it and reads part of it.
            SaveTest.lock_path = more;
            save_target.test_before_compare = SaveTest.hook;
            // The save, as the window makes it.
            try std.testing.expectError(error.SavedButUnread, settingsSaveAndReloadThunk(&app, &pending, &original, &.of(&original)));
            // The preview ends with it: the running settings are what show.
            try std.testing.expect(app.settings_preview == null);
            // Written,
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            switch (case) {
                .ordinary => try std.testing.expect(std.mem.indexOf(u8, after, "font-size = 15\n") != null),
                .profile => try std.testing.expect(std.mem.indexOf(u8, after, "profile-name = py: Python\n") != null),
            }
            // but the partial reload is not applied: the running settings,
            // the include's among them, stay as they were.
            try std.testing.expectEqual(@as(f32, 12), app.config.@"font-size");
            try std.testing.expect(app.config.@"copy-on-select" == .true);
            try std.testing.expect(app.config.@"profile-name".get("py") == null);
            // And the status names the file.
            const expected = try std.fmt.allocPrint(alloc, "the included file {s}", .{more});
            defer alloc.free(expected);
            try std.testing.expect(std.mem.eql(u8, expected, app.settings_failure_detail.text orelse return error.TestExpectedDetail));
        }
    }

    test "win32 settings save judges what overrides an ordinary setting in the app's light/dark state" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "# light\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "default-profile = pwsh.exe\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\ndefault-profile = cmd.exe\n", .{ light, dark });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        // The app runs dark.
        core_app.config_conditional_state = .{ .theme = .dark };
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        try std.testing.expectEqualStrings("cmd.exe", app.config.@"default-profile" orelse return error.TestExpectedProfile);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        // Automatic: the file's line goes, and in the dark state the dark
        // theme's value takes over, which the light reading does not see.
        pending.@"default-profile" = null;
        try std.testing.expectError(error.SavedButMasked, app.settingsSaveAndReload(&pending, &original));
        try std.testing.expectEqualStrings("default-profile", app.settings_masked_keys.text orelse return error.TestExpectedMasked);
        // In the light state nothing overrides it.
        app.settings_masked_keys.clear(alloc);
        core_app.config_conditional_state = .{};
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        {
            var loaded = try SaveTest.load(alloc);
            defer loaded.deinit();
            try app.updateCoreConfig(&loaded);
        }
        var light_original = try app.config.clone(alloc);
        defer light_original.deinit();
        var light_pending = try app.config.clone(alloc);
        defer light_pending.deinit();
        light_pending.@"default-profile" = null;
        try app.settingsSaveAndReload(&light_pending, &light_original);
        try std.testing.expect(app.settings_masked_keys.text == null);
    }

    test "settings save of the profiles' order and visibility writes both lists whole, which the app then picks by" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // A file loaded first orders and hides profiles of its own.
        try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "profile-order = cmd.exe\nprofile-hidden = pwsh.exe\n" });
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "profile-command = py: python.exe\n" });
        const lower = try tmp.dir.realpathAlloc(alloc, "lower.conf");
        defer alloc.free(lower);
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{ lower, path };
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        // The page's order: py, PowerShell, Command Prompt, with Command
        // Prompt hidden.
        try settings_profiles.setOrder(&pending, &.{ "user:py", "pwsh.exe", "cmd.exe" });
        try settings_profiles.setHidden(&pending, &.{"cmd.exe"});
        try app.settingsSaveAndReload(&pending, &original);
        // The file: its own line, then both lists whole, each after its clear.
        {
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            // Compared without printing: the file holds a command line.
            try std.testing.expect(std.mem.eql(u8, "profile-command = py: python.exe\n\nprofile-order =\nprofile-order = user:py\nprofile-order = pwsh.exe\nprofile-order = cmd.exe\n\nprofile-hidden =\nprofile-hidden = cmd.exe\n", after));
        }
        // The clears take what the lower file gave: the app's lists are the
        // page's, and picking by them gives the page's order.
        var profiles = [_]windows_shell.Profile{
            .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{} } },
            .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{} } },
            .{ .kind = .user, .key = "user:py", .label = "py", .command = .{ .direct = &.{} } },
        };
        var order: [8][]const u8 = undefined;
        var hidden: [8][]const u8 = undefined;
        for (app.config.@"profile-order".list.items, 0..) |value, at| order[at] = value;
        for (app.config.@"profile-hidden".list.items, 0..) |value, at| hidden[at] = value;
        windows_shell.arrangeProfiles(&profiles, order[0..app.config.@"profile-order".list.items.len], hidden[0..app.config.@"profile-hidden".list.items.len]);
        for ([_][]const u8{ "user:py", "pwsh.exe", "cmd.exe" }, profiles) |key, profile| try std.testing.expectEqualStrings(key, profile.key);
        try std.testing.expect(!profiles[0].hidden and !profiles[1].hidden and profiles[2].hidden);
    }

    test "settings save of the profiles' order that a later file comes to clear while it is saved says so, and one another program changed stops" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // An include, read after the file. Settings refuses to change the
        // lists while it sets one (`settings_patch.listsForeign`), so here it
        // comes to clear the order and give one of its own only while the
        // save runs, after that check.
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "# nothing yet\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        {
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            try settings_profiles.setOrder(&pending, &.{ "user:py", "cmd.exe" });
            SaveTest.hook_path = more;
            SaveTest.hook_text = "profile-order =\nprofile-order = cmd.exe\n";
            SaveTest.hook_append = false;
            save_target.test_before_compare = SaveTest.hook;
            // Saved, and the order said to be overridden.
            try std.testing.expectError(error.SavedButMasked, app.settingsSaveAndReload(&pending, &original));
            try std.testing.expect(std.mem.indexOf(u8, app.settings_masked_keys.text orelse return error.TestExpectedMaskedKeys, "profile-order") != null);
        }
        // Another program hides a profile while Settings has the page's
        // visibility changed: nothing is saved, and the status names the key.
        // The include sets no list again.
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "# nothing yet\n" });
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        {
            var loaded = try SaveTest.load(alloc);
            defer loaded.deinit();
            try app.updateCoreConfig(&loaded);
        }
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        try settings_profiles.setHidden(&pending, &.{"pwsh.exe"});
        const changed = try std.fmt.allocPrint(alloc, "{s}profile-hidden = wsl\n", .{text});
        defer alloc.free(changed);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = changed });
        try std.testing.expectError(error.ProfileChanged, app.settingsSaveAndReload(&pending, &original));
        try std.testing.expectEqualStrings("profile-hidden", app.settings_failure_detail.text orelse return error.TestExpectedDetail);
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, changed, after));
    }

    test "settings save of the hidden profiles checks a later file's alias only against a whole list of profiles, and says when it could not" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // An include, read after the file, comes to hide PowerShell by its
        // alias while the save runs (Settings refuses to change the lists
        // while a later file sets one, `settings_patch.listsForeign`).
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "# nothing yet\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        const path = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(path);
        const config_path = try std.fs.path.join(alloc, &.{ path, "config" });
        defer alloc.free(config_path);
        // The save hides PowerShell by its key, so the alias hides nothing
        // more, as a list with every profile tells; a list that missed some,
        // or none, cannot tell what `pwsh` names.
        const profiles = [_]windows_shell.Profile{
            .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{} } },
            .{ .kind = .cmd, .key = "cmd.exe", .label = "Command Prompt", .command = .{ .direct = &.{} } },
        };
        try app.registry.addHost(alloc, &host);
        defer _ = app.registry.detachHost(&host);
        const Case = enum { whole, partial, none };
        for ([_]Case{ .whole, .partial, .none }) |case| {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "# nothing yet\n" });
            SaveTest.files = &.{config_path};
            try SaveTest.begin(&app, config_path);
            defer SaveTest.end(&app);
            SaveTest.hook_path = more;
            SaveTest.hook_text = "profile-hidden = pwsh\n";
            SaveTest.hook_append = false;
            save_target.test_before_compare = SaveTest.hook;
            // The window's list, as discovery leaves it: a changed profile
            // setting drops it (`Host.invalidateProfiles`), the save's reload
            // too, after the check.
            host.profiles = try windows_shell.cloneProfiles(app.core_app.alloc, &profiles);
            defer if (host.profiles) |owned| {
                windows_shell.deinitProfiles(app.core_app.alloc, owned);
                host.profiles = null;
            };
            host.profiles_complete = case == .whole;
            if (case == .none) _ = app.registry.detachHost(&host);
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            try settings_profiles.setHidden(&pending, &.{"pwsh.exe"});
            const result = app.settingsSaveAndReload(&pending, &original);
            switch (case) {
                .whole => try result,
                .partial, .none => try std.testing.expectError(error.SavedListsUnchecked, result),
            }
            try std.testing.expect(app.settings_masked_keys.text == null);
        }
    }

    test "settings save checks each group of profile keys in the light/dark state of its own baseline, after the window followed a dark reload" {
        // The lists are refused when a theme gives them otherwise in the two
        // states (`settings_patch.listsForeign`); a theme's profile field is
        // not, and its record's state decides the check.
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // The dark theme labels py; the light one gives nothing.
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "# light\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "profile-name = py: Python (dark)\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, dark });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        // Settings reads the config while the app is light.
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        var baselines: settings_patch.Baselines = .of(&original);
        // The app goes dark, and the window follows its reload: the
        // profiles, and their record, are the dark ones now.
        app.core_app.config_conditional_state = .{ .theme = .dark };
        {
            var loaded = try SaveTest.load(alloc);
            defer loaded.deinit();
            var switched = (try loaded.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
            defer switched.deinit();
            try app.updateCoreConfig(&switched);
        }
        try settings_profiles.followFile(&original, &pending, &app.config, &baselines);
        try std.testing.expect(baselines.profiles.values.name.get("py") != null);
        try std.testing.expect(baselines.profiles.state.theme == .dark);
        // py's label: no file changed, so nothing stops the save.
        try pending.@"profile-name".parseCLI(pending._arena.?.allocator(), "py: Python 3");
        try app.settingsSaveAndReloadFrom(&pending, &original, &baselines);
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.indexOf(u8, after, "profile-name = py: Python 3\n") != null);
    }

    test "settings save of a move writes an earlier file's lists whole into a file that is empty, comments only or not there" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // A file read first defines py and orders the profiles.
        try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "profile-command = py: python.exe\nprofile-order = cmd.exe\n" });
        const lower = try tmp.dir.realpathAlloc(alloc, "lower.conf");
        defer alloc.free(lower);
        const dir = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(dir);
        const path = try std.fs.path.join(alloc, &.{ dir, "config" });
        defer alloc.free(path);
        // The layers as the app reads its default files: the file Settings
        // saves to gives nothing while it is empty or not there.
        const Layers = struct {
            threadlocal var lower_path: []const u8 = "";
            threadlocal var target_path: []const u8 = "";

            fn load(a: Allocator) anyerror!configpkg.Config {
                var cfg = try configpkg.Config.default(a);
                errdefer cfg.deinit();
                try cfg.loadFile(a, lower_path);
                cfg.loadFile(a, target_path) catch |err| {
                    if (err != error.FileNotFound and err != error.FileIsEmpty) return err;
                };
                try cfg.loadRecursiveFiles(a);
                try cfg.finalize();
                return cfg;
            }
        };
        Layers.lower_path = lower;
        Layers.target_path = path;
        const Target = enum { empty, comments, missing };
        for ([_]Target{ .empty, .comments, .missing }) |target| {
            tmp.dir.deleteFile("config") catch {};
            switch (target) {
                .empty => try tmp.dir.writeFile(.{ .sub_path = "config", .data = "" }),
                .comments => try tmp.dir.writeFile(.{ .sub_path = "config", .data = "# Settings saves here\n" }),
                .missing => {},
            }
            SaveTest.files = if (target == .comments) &.{ lower, path } else &.{lower};
            try SaveTest.begin(&app, path);
            defer SaveTest.end(&app);
            settings_patch.test_config_load = &Layers.load;
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            try settings_profiles.setOrder(&pending, &.{ "user:py", "cmd.exe" });
            try app.settingsSaveAndReload(&pending, &original);
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            try std.testing.expect(std.mem.indexOf(u8, after, "profile-order =\nprofile-order = user:py\nprofile-order = cmd.exe\n") != null);
        }
    }

    test "settings save of a move stops when an included file orders the profiles and then clears config-file, and says why" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // The file Settings saves to includes one that orders the profiles
        // and then clears `config-file` (Terra's case): it still loads after
        // the file, and would override a saved order on every launch.
        try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "profile-order =\nprofile-order = cmd.exe\nconfig-file =\n" });
        const later = try tmp.dir.realpathAlloc(alloc, "later.conf");
        defer alloc.free(later);
        const text = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nconfig-file = {s}\n", .{later});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        try settings_profiles.setOrder(&pending, &.{ "user:py", "cmd.exe" });
        try std.testing.expectError(error.ProfileListsForeign, app.settingsSaveAndReload(&pending, &original));
        try std.testing.expectEqualStrings(settings_patch.ListsForeign.unordered.text(), app.settings_failure_detail.text orelse return error.TestExpectedDetail);
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, text, after));
    }

    test "settings save of a move stops when a later config file sets the profile order, and says so" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "profile-command = py: python.exe\nprofile-hidden = cmd.exe\n" });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        try settings_profiles.setOrder(&pending, &.{ "user:py", "pwsh.exe" });
        // Since the page was built, the file has come to include one that
        // orders the profiles.
        try tmp.dir.writeFile(.{ .sub_path = "later.conf", .data = "profile-order = cmd.exe\n" });
        const later = try tmp.dir.realpathAlloc(alloc, "later.conf");
        defer alloc.free(later);
        const text = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nprofile-hidden = cmd.exe\nconfig-file = {s}\n", .{later});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        try std.testing.expectError(error.ProfileListsForeign, app.settingsSaveAndReload(&pending, &original));
        try std.testing.expectEqualStrings(settings_patch.ListsForeign.later_file.text(), app.settings_failure_detail.text orelse return error.TestExpectedDetail);
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, text, after));
    }

    test "settings save of a new profile hidden by its id is not called overridden by a later file's bare name for it" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var host: Host = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app, .hosts = &.{.{ .storage = &host }} });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // An include, read after the file, comes to hide `dev` by its bare
        // id while the save runs.
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "# nothing yet\n" });
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "profile-command = py: python.exe\nconfig-file = {s}\n", .{more});
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        // The window's whole list, from before the save: no `dev` in it.
        const profiles = [_]windows_shell.Profile{
            .{ .kind = .pwsh, .key = "pwsh.exe", .label = "PowerShell", .command = .{ .direct = &.{} } },
            .{ .kind = .user, .key = "user:py", .label = "py", .command = .{ .direct = &.{} } },
        };
        try app.registry.addHost(alloc, &host);
        defer _ = app.registry.detachHost(&host);
        host.profiles = try windows_shell.cloneProfiles(app.core_app.alloc, &profiles);
        defer if (host.profiles) |owned| {
            windows_shell.deinitProfiles(app.core_app.alloc, owned);
            host.profiles = null;
        };
        host.profiles_complete = true;
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        // The save adds `dev` and hides it by its key.
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "dev: dev.exe");
        try settings_profiles.setHidden(&pending, &.{"user:dev"});
        SaveTest.hook_path = more;
        SaveTest.hook_text = "profile-hidden = dev\n";
        SaveTest.hook_append = false;
        save_target.test_before_compare = SaveTest.hook;
        try app.settingsSaveAndReload(&pending, &original);
        try std.testing.expect(app.settings_masked_keys.text == null);
    }

    test "settings save of the profiles' order stops when another program hid a profile in a file loaded first, which the save's clear would show again" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        const settings_profiles = @import("../win32_settings_profiles.zig");
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "# a file loaded first\n" });
        const text = "profile-command = py: python.exe\n";
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const lower = try tmp.dir.realpathAlloc(alloc, "lower.conf");
        defer alloc.free(lower);
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{ lower, path };
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        // Only the order changes. Both lists are written, the hidden one
        // after a clear that drops what the lower file gives it.
        try settings_profiles.setOrder(&pending, &.{ "user:py", "pwsh.exe", "cmd.exe" });
        try std.testing.expect(pending.@"profile-hidden".equal(original.@"profile-hidden"));
        // Before Save, another program hides PowerShell in the lower file.
        const hides = "profile-hidden = pwsh.exe\n";
        try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = hides });
        try std.testing.expectError(error.ProfileChanged, app.settingsSaveAndReload(&pending, &original));
        try std.testing.expectEqualStrings("profile-hidden", app.settings_failure_detail.text orelse return error.TestExpectedDetail);
        // Nothing is written: both files are as they were left.
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, text, after));
        const lower_after = try SaveTest.read(lower);
        defer alloc.free(lower_after);
        try std.testing.expect(std.mem.eql(u8, hides, lower_after));
    }

    test "win32 settings save of a profile removal reads the layers again: a lower file that gained the profile keeps a tombstone" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "# a file loaded first\n" });
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = "font-size = 12\nprofile-command = py: python.exe\n" });
        const lower = try tmp.dir.realpathAlloc(alloc, "lower.conf");
        defer alloc.free(lower);
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{ lower, path };
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        // The draft removes `py`, which only the target file defines as the
        // app last read the files.
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
        // While Settings is open, the file loaded first gains `py`, with no
        // reload.
        try tmp.dir.writeFile(.{ .sub_path = "lower.conf", .data = "profile-command = py: other.exe\n" });
        try app.settingsSaveAndReload(&pending, &original);
        // Deleting the line would bring `py` back from the lower file: the
        // save read the layers again and wrote a tombstone.
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, "font-size = 12\nprofile-command = py:\n", after));
        try std.testing.expect(app.config.@"profile-command".get("py") == null);
    }

    test "settings profile save stops when the held config's theme, read again in the app's state, no longer decodes" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "old-dark", .data = "profile-command = py: python.exe -X dark\n" });
        try tmp.dir.writeFile(.{ .sub_path = "new-dark", .data = "\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const old_dark = try tmp.dir.realpathAlloc(alloc, "old-dark");
        defer alloc.free(old_dark);
        const new_dark = try tmp.dir.realpathAlloc(alloc, "new-dark");
        defer alloc.free(new_dark);
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
        // The config as last read (light), naming the old dark theme, which
        // defines `py`; the draft removes `py`.
        const held_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, old_dark });
        defer alloc.free(held_text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = held_text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        var held = try load(alloc, path);
        defer held.deinit();
        var pending = try held.clone(alloc);
        defer pending.deinit();
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
        // Since then the file names a new dark theme, and the old one is
        // UTF-16 that does not decode. The app runs dark.
        const fresh_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, new_dark });
        defer alloc.free(fresh_text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = fresh_text });
        try tmp.dir.writeFile(.{ .sub_path = "old-dark", .data = "\xff\xfe\x00\xd8a\x00" });
        var detail: win32_settings.FailureDetail = .{};
        defer detail.clear(alloc);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const fresh = try load(alloc, path);
        // The fresh reading is whole; the held one, read again dark, skips
        // its theme, and a removal decided from it could delete where the
        // old theme still defines `py`: nothing is worked out.
        try std.testing.expectError(error.UnsupportedEncoding, App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, .{ .theme = .dark }, &held, &pending, path, null));
        const expected = try std.fmt.allocPrint(alloc, "the file {s}", .{old_dark});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.eql(u8, expected, detail.text orelse return error.TestExpectedDetail));
        // The file is as it was.
        const after = try tmp.dir.readFileAlloc(alloc, "config", 1 << 16);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, fresh_text, after));
    }

    test "settings save stops when the held config's theme, read again in the app's state, no longer decodes, and writes nothing" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "old-dark", .data = "profile-command = py: python.exe -X dark\n" });
        try tmp.dir.writeFile(.{ .sub_path = "new-dark", .data = "\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const old_dark = try tmp.dir.realpathAlloc(alloc, "old-dark");
        defer alloc.free(old_dark);
        const new_dark = try tmp.dir.realpathAlloc(alloc, "new-dark");
        defer alloc.free(new_dark);
        // The config as the app last read it (light), naming the old dark
        // theme, which defines `py`; the draft removes `py`.
        const held_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, old_dark });
        defer alloc.free(held_text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = held_text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        var original = try app.config.clone(alloc);
        defer original.deinit();
        var pending = try app.config.clone(alloc);
        defer pending.deinit();
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
        // The app runs dark now, with the config as last read (a switch that
        // failed keeps it). Since then the file names a new dark theme, which
        // decodes, and the old one is UTF-16 that does not.
        app.core_app.config_conditional_state = .{ .theme = .dark };
        const fresh_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ light, new_dark });
        defer alloc.free(fresh_text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = fresh_text });
        try tmp.dir.writeFile(.{ .sub_path = "old-dark", .data = "\xff\xfe\x00\xd8a\x00" });
        // A removal decided from the held config read dark could delete the
        // line where the old theme still defines `py`: the save stops and
        // names that theme.
        try std.testing.expectError(error.UnsupportedEncoding, app.settingsSaveAndReload(&pending, &original));
        const expected = try std.fmt.allocPrint(alloc, "the file {s}", .{old_dark});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.eql(u8, expected, app.settings_failure_detail.text orelse return error.TestExpectedDetail));
        // The file is as it was.
        const after = try SaveTest.read(path);
        defer alloc.free(after);
        try std.testing.expect(std.mem.eql(u8, fresh_text, after));
    }

    test "settings save while the app runs dark is applied whole when only the light theme cannot be read" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "\n" });
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nfont-size = 12\n", .{ light, dark });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        app.core_app.config_conditional_state = .{ .theme = .dark };
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        const Case = enum { undecodable, unopenable };
        for ([_]Case{ .undecodable, .unopenable }, [_]f32{ 15, 16 }) |case, size| {
            // The light theme, which the app does not apply, cannot be read:
            // UTF-16 that does not decode, or held by another program with no
            // sharing. The dark theme reads whole.
            try tmp.dir.writeFile(.{ .sub_path = "light", .data = switch (case) {
                .undecodable => "\xff\xfe\x00\xd8a\x00",
                .unopenable => "\n",
            } });
            var held: ?std.os.windows.HANDLE = null;
            defer if (held) |handle| std.os.windows.CloseHandle(handle);
            if (case == .unopenable) {
                const wide = try std.os.windows.sliceToPrefixedFileW(null, light);
                const handle = std.os.windows.kernel32.CreateFileW(wide.span().ptr, std.os.windows.GENERIC_READ, 0, null, std.os.windows.OPEN_EXISTING, 0, null);
                if (handle == std.os.windows.INVALID_HANDLE_VALUE) return error.CouldNotHoldFile;
                held = handle;
            }
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            pending.@"font-size" = size;
            // The save, and its reload in the dark state, apply the edit.
            try app.settingsSaveAndReload(&pending, &original);
            try std.testing.expectEqual(size, app.config.@"font-size");
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            const line = try std.fmt.allocPrint(alloc, "font-size = {d}\n", .{size});
            defer alloc.free(line);
            try std.testing.expect(std.mem.indexOf(u8, after, line) != null);
        }
    }

    test "settings save whose reload cannot be put in the app's light/dark state applies nothing" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var core_app: CoreApp = undefined;
        var app: App = undefined;
        var session: TestSession = .{};
        try session.init(.{ .core_app = &core_app, .app = &app });
        defer session.deinit();
        defer testFreeConfigProblems(&app, alloc);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "\n" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nfont-size = 12\n", .{ light, dark });
        defer alloc.free(text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        app.core_app.config_conditional_state = .{ .theme = .dark };
        SaveTest.files = &.{path};
        try SaveTest.begin(&app, path);
        defer SaveTest.end(&app);
        const Case = enum { switch_fails, read_fails };
        for ([_]Case{ .switch_fails, .read_fails }, [_]f32{ 15, 16 }) |case, size| {
            try tmp.dir.writeFile(.{ .sub_path = "config", .data = text });
            // The reload after the write is read whole, and from then on its
            // allocator has no memory, so the switch to the dark state
            // fails; or the reload cannot be read at all.
            settings_patch.test_config_load = SaveTest.starvedLoad;
            save_target.test_before_compare = switch (case) {
                .switch_fails => SaveTest.starveNext,
                .read_fails => SaveTest.failNext,
            };
            var original = try app.config.clone(alloc);
            defer original.deinit();
            var pending = try app.config.clone(alloc);
            defer pending.deinit();
            pending.@"font-size" = size;
            // The window shows a preview of the opacity, as it does while a
            // draft changes it.
            settingsPreviewFieldThunk(&app, .background_opacity, .{ .background_opacity = 0.5 });
            try std.testing.expect(app.settings_preview != null);
            // The file is written; the running settings are kept, rather
            // than the light reading, or one `updateConfig` would switch
            // unchecked. The save is done: it says so, and the preview ends
            // with it.
            try std.testing.expectError(error.SavedNotApplied, settingsSaveAndReloadThunk(&app, &pending, &original, &.of(&original)));
            try std.testing.expect(app.settings_preview == null);
            try std.testing.expectEqual(@as(f32, 12), app.config.@"font-size");
            const after = try SaveTest.read(path);
            defer alloc.free(after);
            const line = try std.fmt.allocPrint(alloc, "font-size = {d}\n", .{size});
            defer alloc.free(line);
            try std.testing.expect(std.mem.indexOf(u8, after, line) != null);
        }
    }

    test "settings profile removal keeps a tombstone when the config as last read, already in the app's state, skipped a theme" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "old-light", .data = "\xff\xfe\x00\xd8a\x00" });
        try tmp.dir.writeFile(.{ .sub_path = "new-light", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "\n" });
        const old_light = try tmp.dir.realpathAlloc(alloc, "old-light");
        defer alloc.free(old_light);
        const new_light = try tmp.dir.realpathAlloc(alloc, "new-light");
        defer alloc.free(new_light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
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
        // The config as last read, in the light state the app runs in: its
        // light theme did not decode, so whatever that theme defined is
        // missing from it. The draft removes `py`.
        const held_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ old_light, dark });
        defer alloc.free(held_text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = held_text });
        const path = try tmp.dir.realpathAlloc(alloc, "config");
        defer alloc.free(path);
        var held = try load(alloc, path);
        defer held.deinit();
        try std.testing.expect(held._undecodable_theme != null);
        var pending = try held.clone(alloc);
        defer pending.deinit();
        try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
        // Since then the file names a readable light theme.
        const fresh_text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\n", .{ new_light, dark });
        defer alloc.free(fresh_text);
        try tmp.dir.writeFile(.{ .sub_path = "config", .data = fresh_text });
        var detail: win32_settings.FailureDetail = .{};
        defer detail.clear(alloc);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const fresh = try load(alloc, path);
        // Nothing names `py` in the fresh reading, but the held one could
        // not read everything, so it may have missed what does: the line
        // becomes a tombstone, not a deletion. The save is not refused for a
        // marker that may be stale.
        const edits = try App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, &held, .{}, &held, &pending, path, null);
        var command: ?settings_patch.Edit = null;
        for (edits) |e| if (e.field == .command and std.mem.eql(u8, "py", e.id)) {
            command = e;
        };
        try std.testing.expect((command orelse return error.TestExpectedEdit).op == .unset);
    }

    test "settings profile removal keeps a tombstone when the config as last read skipped an include, across a light/dark switch" {
        if (builtin.os.tag != .windows) return error.SkipZigTest;
        const alloc = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "light", .data = "\n" });
        try tmp.dir.writeFile(.{ .sub_path = "dark", .data = "\n" });
        // The include, as the app last read it: UTF-16 that does not decode,
        // so whatever it defined is missing from that reading.
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "\xff\xfe\x00\xd8a\x00" });
        const light = try tmp.dir.realpathAlloc(alloc, "light");
        defer alloc.free(light);
        const dark = try tmp.dir.realpathAlloc(alloc, "dark");
        defer alloc.free(dark);
        const more = try tmp.dir.realpathAlloc(alloc, "more.conf");
        defer alloc.free(more);
        const text = try std.fmt.allocPrint(alloc, "theme = light:{s},dark:{s}\nprofile-command = py: python.exe\nconfig-file = {s}\n", .{ light, dark, more });
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
        var loaded = try load(alloc, path);
        defer loaded.deinit();
        try std.testing.expect(loaded._undecodable_file != null);
        // The app config after a live switch to dark: that switch does not
        // carry the record of the skipped include.
        var live = (try loaded.changeConditionalState(.{ .theme = .dark })) orelse return error.TestExpectedSwitch;
        defer live.deinit();
        try std.testing.expect(live._undecodable_file == null);
        // Since then the include decodes, and names nothing.
        try tmp.dir.writeFile(.{ .sub_path = "more.conf", .data = "# repaired\n" });
        const Case = enum { switched_here, switched_live };
        for ([_]Case{ .switched_here, .switched_live }) |case| {
            // The held config: the light reading, switched to dark here; or
            // the app's, already switched live.
            const held: *const configpkg.Config = switch (case) {
                .switched_here => &loaded,
                .switched_live => &live,
            };
            var pending = try held.clone(alloc);
            defer pending.deinit();
            try pending.@"profile-command".parseCLI(pending._arena.?.allocator(), "py:");
            var detail: win32_settings.FailureDetail = .{};
            defer detail.clear(alloc);
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const fresh = try load(alloc, path);
            // Nothing names `py` in the fresh reading, but the held one may
            // have missed what the include named: the line becomes a
            // tombstone, not a deletion. Not refused: that record is from the
            // held config's last read, and the include decodes now.
            const edits = try App.settingsProfileEditsFromDisk(arena.allocator(), alloc, &detail, fresh, held, .{ .theme = .dark }, held, &pending, path, null);
            var command: ?settings_patch.Edit = null;
            for (edits) |e| if (e.field == .command and std.mem.eql(u8, "py", e.id)) {
                command = e;
            };
            try std.testing.expect((command orelse return error.TestExpectedEdit).op == .unset);
        }
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

    /// The App's side of `notifications.Panes`.
    pub fn notificationPanes(self: *App) notifications.Panes {
        return .{
            .ctx = self,
            .find = findNotificationPane,
            .present = presentNotificationTarget,
            .banner = notificationBanner,
            .wake = wakeNotificationFlush,
        };
    }

    /// Windows first, then the tabs' trees (`Registry.findSurfaceById`), and
    /// the tab through the pane's own host, so a pane in undo history, or
    /// one whose window already left the registry, has a window and no tab.
    fn findNotificationPane(ctx: *anyopaque, pane: u64) ?notifications.Pane {
        const self: *App = @ptrCast(@alignCast(ctx));
        const surface = self.registry.findSurfaceById(pane) orelse return null;
        const tab: ?notifications.Pane.Tab = if (Host.findTabForSurface(surface)) |found| .{
            .id = found.tab.id,
            .index = found.index,
            .name = toastTabName(found.tab, surface),
            .window = self.notificationWindow(found.host),
        } else null;
        return .{ .window_id = surface.host_id, .tab = tab };
    }

    fn presentNotificationTarget(ctx: *anyopaque, which: notifications.Present) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const surface = self.notificationTargetSurface(which) orelse return false;
        surface.present();
        return true;
    }

    /// The pane `which` names. Pane ids are looked up in the windows first,
    /// then the tabs' trees (`Registry.findSurfaceById`).
    fn notificationTargetSurface(self: *App, which: notifications.Present) ?*Surface {
        return switch (which) {
            .pane => |id| self.registry.findSurfaceById(id),
            .tab => |tab| if (self.registry.findHostById(tab.window)) |host| host.focusedSurfaceForTab(tab.tab) else null,
            .window => |id| if (self.registry.findHostById(id)) |host| host.activeSurface() else null,
            .primary => self.registry.primarySurface(),
        };
    }

    fn notificationBanner(ctx: *anyopaque, from: notifications.From, text: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const surface = switch (from) {
            .app => self.registry.primarySurface(),
            .pane => |id| self.registry.findSurfaceById(id),
        } orelse return false;
        const host = surface.host orelse return false;
        host.setBanner(.info, text) catch |err| {
            log.warn("notification banner failed err={}", .{err});
            return false;
        };
        return true;
    }

    /// No message window (before `run` creates it, after it closes at
    /// exit): the flush waits for the next chance, and exit takes the
    /// whole group.
    fn wakeNotificationFlush(ctx: *anyopaque) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const hwnd = self.registry.message_hwnd orelse return false;
        return sys.PostMessageW(hwnd, c.WM_WINHOSTTY_TOAST_REMOVALS, 0, 0) != 0;
    }

    /// What the user knows a tab by: the title of its focused pane.
    fn toastTabName(tab: *const Tab, surface: *Surface) []const u8 {
        const shown = tab.focusedSurface() orelse surface;
        return shown.effectiveTitle() orelse "noctty";
    }

    /// The window `host` is, as a toast from it names it. Every host but the
    /// quick terminal counts, a window kept empty for undo included, but not
    /// one a tab move left hidden only until its undo history is disposed
    /// (`destroy_after_structural_dispose` with no tab): no window the user
    /// sees, so the one they do is no "window 2" (CodeRabbit review
    /// 5822644219). A toast from that one names no window number.
    fn notificationWindow(self: *const App, host: *const Host) notifications.Window {
        if (host.quick_terminal) return .quick_terminal;
        var open: u32 = 0;
        var number: ?u32 = null;
        for (self.registry.hosts.items) |item| {
            if (item.quick_terminal) continue;
            if (item.destroy_after_structural_dispose and item.tabs.items.len == 0) continue;
            open += 1;
            if (item == host) number = open;
        }
        return .{ .ordinary = .{ .number = number, .open = open } };
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

        self.notifications.show(.{ .pane = surface.core().id }, "Command finished", body);
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
            // Its toasts have been seen too. Only marked here: this runs
            // inside WM_ACTIVATE and focus handling.
            self.notifications.seen(entry.view.core().id);
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
        self.notifications.show(.{ .pane = surface.core().id }, title.buffered(), body.buffered());
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

test "CHROME57 a system theme message that changed nothing since startup rebuilds nothing" {
    // Without a baseline, the first message after startup counted as a
    // change: a theme rebuild, and a retry of a failed blur-behind.
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.test_support.SafeModeAppFixture = .{};
            try fixture.init();
            defer fixture.deinit();
            const rebuilds = fixture.app.theme_rebuilds;
            fixture.app.reconfigureSystemTheme();
            try std.testing.expectEqual(rebuilds, fixture.app.theme_rebuilds);
        }
    }.body);
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

test "PKG-39 App.terminate takes both Settings preview hooks away before the window rolls its previews back, with both previews live" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            const core = try CoreApp.create(std.testing.allocator);
            defer core.destroy();
            var app: App = undefined;
            try app.init(core, .{ .safe_mode = true });
            const hinstance = app.hinstance;
            defer {
                _ = sys.UnregisterClassW(host_class_name, hinstance);
                _ = sys.UnregisterClassW(palette_list_class_name, hinstance);
                _ = sys.UnregisterClassW(scrollbar_class_name, hinstance);
            }
            const settings_class = std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.settings");
            const viewport_class = std.unicode.utf8ToUtf16LeStringLiteral("noctty.win32.settings.viewport");
            defer {
                _ = sys.UnregisterClassW(settings_class, hinstance);
                _ = sys.UnregisterClassW(viewport_class, hinstance);
            }
            // A step below that fails, the skip included, still tears the
            // app down, before its window classes go; the end of the test
            // terminates it once.
            var terminated = false;
            errdefer if (!terminated) app.terminate();
            if (!app.com_initialized) return error.SkipZigTest;
            try std.testing.expect(app.settings_window.handle.previewField != null);
            try std.testing.expect(app.settings_window.handle.endPreviews != null);

            // Settings open with an opacity and a theme preview, made through
            // its own controls, so its rollback has both to end.
            app.settings_window.handle.deferUiaDisconnect = null;
            try app.settings_window.open();
            _ = sys.SetWindowTextW(app.settings_window.fields.edit_bg_opacity.?, std.unicode.utf8ToUtf16LeStringLiteral("0.5"));
            const combo = app.settings_window.fields.combo_window_theme.?;
            const field_model = @import("../win32_settings_fields.zig");
            const cb_setcursel = 0x014E;
            const cbn_selchange = 1;
            _ = sys.SendMessageW(combo, cb_setcursel, field_model.Combo(.window_theme).toIndex(.light), 0);
            const id: usize = @intCast(sys.GetDlgCtrlID(combo));
            _ = sys.SendMessageW(app.settings_window.hwnd.?, c.WM_COMMAND, id | (@as(usize, cbn_selchange) << 16), @bitCast(@intFromPtr(combo)));
            try std.testing.expectEqual(@as(f64, 0.5), app.shownConfig().@"background-opacity");
            try std.testing.expect(app.shownConfig().@"window-theme" == .light);

            // `settings_window.deinit` rolls the previews back after the
            // hosts and windows a redraw walks are freed: neither a field's
            // revert nor the end of them all may reach the app. The hooks
            // count instead of reaching it, so a hook left in place shows as
            // a call, not as a redraw over freed hosts.
            const Calls = struct {
                var preview_field: usize = 0;
                var end_previews: usize = 0;
                fn previewField(_: *anyopaque, _: win32_settings.SettingField, _: win32_settings.SettingValue) void {
                    preview_field += 1;
                }
                fn endPreviews(_: *anyopaque) void {
                    end_previews += 1;
                }
            };
            Calls.preview_field = 0;
            Calls.end_previews = 0;
            app.settings_window.handle.previewField = &Calls.previewField;
            app.settings_window.handle.endPreviews = &Calls.endPreviews;
            terminated = true;
            app.terminate();
            try std.testing.expectEqual(@as(usize, 0), Calls.preview_field);
            try std.testing.expectEqual(@as(usize, 0), Calls.end_previews);
            try std.testing.expect(app.settings_window.handle.previewField == null);
            try std.testing.expect(app.settings_window.handle.endPreviews == null);
        }
    }.body);
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
    const host = try app.createHost(std.unicode.utf8ToUtf16LeStringLiteral(""), &app.config, .{ .quick_terminal = .activate });
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
    const host = try app.createHost(std.unicode.utf8ToUtf16LeStringLiteral(""), &app.config, .fresh);
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

test "win32 the notification panes adapter reports a pane's tab, name, window and reach, and finds what a click presents" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var w: ToastTestWindow = .{};
    try w.init(true);
    defer w.deinit();
    const panes = w.app.notificationPanes();
    const Find = struct {
        fn tab(from: notifications.Panes, id: u64) !notifications.Pane.Tab {
            const pane = from.find(from.ctx, id) orelse return error.TestExpectedPane;
            return pane.tab orelse error.TestExpectedTab;
        }
    };
    const first_of_two: notifications.Window = .{ .ordinary = .{ .number = 1, .open = 2 } };

    // A tab is known by its focused pane's title, also to another of its
    // panes.
    const inserted = try toastTestSplit(&w);
    defer {
        var cleanup = inserted;
        cleanup.deinit();
    }

    // What a click presents, through the real Registry and Host: a pane by
    // id, also a split pane only its tab's tree holds; a tab's focused pane,
    // not its window's active one; a window's active pane; the first
    // window's; nothing for an id no pane, tab or window has. Compared by
    // pane id, so a failure prints two numbers: printing a `*Surface`
    // against null formats the fixture's whole Surface, undefined fields
    // included, and ended the test process in a mutation run.
    const Presented = struct {
        fn id(app: *App, which: notifications.Present) ?u64 {
            const surface = app.notificationTargetSurface(which) orelse return null;
            return surface.core().id;
        }
    };
    w.app.registry.removeWindow(&w.q);
    try std.testing.expectEqual(@as(?u64, 0x2003), Presented.id(&w.app, .{ .pane = 0x2003 }));
    try w.app.registry.addWindow(std.testing.allocator, &w.q);
    try std.testing.expectEqual(@as(?u64, 0x2002), Presented.id(&w.app, .{ .tab = .{ .window = 7, .tab = 2 } }));
    try std.testing.expectEqual(@as(?u64, 0x1001), Presented.id(&w.app, .{ .window = 7 }));
    try std.testing.expectEqual(@as(?u64, 0x3003), Presented.id(&w.app, .{ .window = 8 }));
    try std.testing.expectEqual(@as(?u64, 0x1001), Presented.id(&w.app, .primary));
    for ([_]notifications.Present{
        .{ .pane = 0x9999 },
        .{ .tab = .{ .window = 7, .tab = 9 } },
        .{ .tab = .{ .window = 9, .tab = 2 } },
        .{ .window = 9 },
    }) |unknown| try std.testing.expectEqual(@as(?u64, null), Presented.id(&w.app, unknown));

    w.q.title = "vim";
    for ([_]u64{ 0x2002, 0x2003 }) |id| {
        try std.testing.expectEqual(@as(u32, 7), panes.find(panes.ctx, id).?.window_id);
        const tab = try Find.tab(panes, id);
        try std.testing.expectEqual(@as(u32, 2), tab.id);
        try std.testing.expectEqual(@as(usize, 1), tab.index);
        try std.testing.expectEqualStrings("cargo build", tab.name);
        try std.testing.expectEqual(first_of_two, tab.window);
    }
    // An untitled tab is "noctty"; the other window is the second, until
    // it is the quick terminal, which is named and not counted.
    const other = try Find.tab(panes, 0x3003);
    try std.testing.expectEqualStrings("noctty", other.name);
    try std.testing.expectEqual(notifications.Window{ .ordinary = .{ .number = 2, .open = 2 } }, other.window);
    w.other_host.quick_terminal = true;
    try std.testing.expectEqual(notifications.Window.quick_terminal, (try Find.tab(panes, 0x3003)).window);
    try std.testing.expectEqual(notifications.Window{ .ordinary = .{ .number = 1, .open = 1 } }, (try Find.tab(panes, 0x2002)).window);
    w.other_host.quick_terminal = false;

    // A window kept with no tab for undo still counts as one, and its pane
    // has a window but no tab.
    var other_entry = w.other_host.detachTabForUndo(0).?;
    defer other_entry.dispose(&w.other_host, .host_destroy) catch {}; // Best-effort test teardown.
    try std.testing.expectEqual(first_of_two, (try Find.tab(panes, 0x2002)).window);
    try std.testing.expectEqual(@as(u32, 8), panes.find(panes.ctx, 0x3003).?.window_id);
    try std.testing.expect(panes.find(panes.ctx, 0x3003).?.tab == null);

    // A pane whose split is undone waits in redo history with no tab, and
    // so do a closed tab's panes in undo history, until it is restored.
    var split_create: Host.SplitCreateUndo = .{
        .source_surface = &w.p,
        .created_surface = &w.q,
        .direction = .right,
    };
    try std.testing.expect(try w.host.undoSplitCreateEntry(&split_create));
    try std.testing.expect(panes.find(panes.ctx, 0x2003).?.tab == null);
    var entry = w.host.detachTabForUndo(1).?;
    defer entry.dispose(&w.host, .host_destroy) catch {}; // Best-effort test teardown.
    try std.testing.expect(panes.find(panes.ctx, 0x2002).?.tab == null);
    try std.testing.expect(try w.host.restoreClosedTabEntry(&entry.payload.close_tab));
    try std.testing.expectEqual(@as(u32, 2), (try Find.tab(panes, 0x2002)).id);

    // A closed pane is gone.
    w.app.windowDestroyed(&w.front);
    try std.testing.expect(panes.find(panes.ctx, 0x1001) == null);
}

test "win32 a notification with no memory for its banner goes to the log, and its action succeeds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var w: ToastTestWindow = .{};
    try w.init(false);
    defer w.deinit();
    // Windows refuses the toast, and the window cannot take the banner.
    w.recorder.refuse = error.NotifierDisabled;
    var no_memory: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&no_memory);
    const working = w.core_app.alloc;
    w.core_app.alloc = failing.allocator();
    defer w.core_app.alloc = working;

    try w.osc(&w.p, "deploy", "rolled out");
    try std.testing.expectEqual(@as(usize, 1), w.recorder.shown);
    try std.testing.expect(w.host.banner_text == null);
}

test "win32 App.terminate removes this process's toast group" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var line_buf: [32]u8 = undefined;
    const own_group = try std.fmt.bufPrint(&line_buf, "group noctty-{d}", .{sys.GetCurrentProcessId()});
    // Both outlive the App, whose terminate calls them.
    var recorder: notifications.testing.Recorder = .{};
    defer recorder.deinit();
    var panes: notifications.testing.FakePanes = .{};
    panes.put(0x2002, notifications.testing.inTab(2, 1, "cargo build"));

    var core = try CoreApp.create(std.testing.allocator);
    defer core.destroy();
    var app: App = undefined;
    try app.init(core, .{});
    app.notifications = .init(std.testing.allocator, recorder.sink(), panes.panes());
    app.notifications.show(.{ .pane = 0x2002 }, "", "x");
    try recorder.expectRemovals(&.{});
    app.terminate();
    try recorder.expectRemovals(&.{own_group});
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

/// A window of tabs for the tab move tests: the first window, then a tab
/// per entry of `more`, each split right when its entry is true, each
/// activated as the app activates what it opens.
const TabMoveFixture = struct {
    fixture: *win32.WindowStartTestApp,

    fn window(self: TabMoveFixture, tabs: usize, split_second: bool) !*Host {
        const app = &self.fixture.app;
        try app.createWindow(default_title);
        const first = self.fixture.newest();
        const host = first.host.?;
        var i: usize = 1;
        while (i < tabs) : (i += 1) {
            const tab = try app.createWindowSurface(&app.config, default_title, .{ .host_id = host.id });
            app.activateSurface(tab);
            if (i == 1 and split_second) {
                const found = Host.findTabForSurface(tab).?;
                const split = try app.createWindowSurface(&app.config, default_title, .{
                    .host_id = host.id,
                    .tab_id = found.tab.id,
                    .clone_state_from = tab,
                    .split_direction = .right,
                });
                app.activateSurface(split);
            }
        }
        return host;
    }

    /// The posted move, run as the message loop would run it.
    fn runPosted(host: *Host) void {
        var msg: MSG = undefined;
        if (host.hwnd) |hwnd| _ = sys.PeekMessageW(&msg, hwnd, c.WM_WINHOSTTY_TAB_MOVE, c.WM_WINHOSTTY_TAB_MOVE, c.PM_REMOVE);
        host.app.drainPendingTabMoves();
    }
};

test "win32 a tab torn off into a new window keeps its panes, split, zoom and windows, and the window it left fronts its neighbour" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            // A, B (split into B1 | B2, zoomed on B2, ratio 0.3), C.
            const source = try setup.window(3, true);
            try std.testing.expectEqual(@as(usize, 3), source.tabs.items.len);
            const tab_a = source.tabs.items[0].focusedSurface().?;
            const tab_c = source.tabs.items[2].focusedSurface().?;
            const moving = &source.tabs.items[1];
            try std.testing.expectEqual(@as(usize, 2), moving.leafCount());
            var leaves: [2]*Surface = undefined;
            var it = moving.tree.iterator();
            var n: usize = 0;
            while (it.next()) |entry| : (n += 1) leaves[n] = entry.view;
            const panes = [_]HWND{ leaves[0].hwnd.?, leaves[1].hwnd.? };
            // A ratio of its own, set as a drag of the divider leaves it.
            switch (@constCast(moving.tree.nodes)[0]) {
                .split => |*split| split.ratio = 0.3,
                .leaf => return error.TestExpectedSplit,
            }
            moving.tree.zoom(moving.findHandle(leaves[1]).?);
            moving.focused = moving.findHandle(leaves[1]).?;
            const shell_tab = moving.shell_id.?;
            _ = source.activateTabIndex(1);
            try app.validateShellNativeMapping();

            try std.testing.expect(try app.moveTabToWindow(source, 1, .{ .new_window = null }));

            // A new window, in front, holding B: the same panes and windows,
            // split as they were, zoomed as they were.
            try std.testing.expectEqual(@as(usize, 2), app.registry.hosts.items.len);
            const target = leaves[0].host.?;
            try std.testing.expect(target != source);
            try std.testing.expectEqual(target, leaves[1].host.?);
            try std.testing.expectEqual(@as(usize, 1), target.tabs.items.len);
            const moved = &target.tabs.items[0];
            try std.testing.expect(moved.shell_id.?.eql(shell_tab));
            try std.testing.expect(moved.findHandle(leaves[0]) != null and moved.findHandle(leaves[1]) != null);
            switch (moved.tree.nodes[0]) {
                .split => |split| try std.testing.expectApproxEqAbs(@as(f32, 0.3), @as(f32, split.ratio), 0.01),
                .leaf => return error.TestExpectedSplit,
            }
            try std.testing.expectEqual(moved.findHandle(leaves[1]), moved.tree.zoomed);
            try std.testing.expectEqual(leaves[1], moved.focusedSurface().?);
            for (panes, leaves) |pane, leaf| {
                try std.testing.expectEqual(pane, leaf.hwnd.?);
                try std.testing.expectEqual(target.hwnd.?, sys.GetParent(pane).?);
                try std.testing.expectEqual(target.id, leaf.host_id);
            }
            try std.testing.expect(sys.IsWindowVisible(target.hwnd.?) != 0);
            // Zoomed: only the zoomed pane shows.
            try std.testing.expect(leaves[1].window_visible);
            try std.testing.expect(!leaves[0].window_visible);
            // It took nothing of the config's maximize or fullscreen.
            try std.testing.expect(!target.top_level.isFullscreen());
            try std.testing.expect(sys.IsZoomed(target.hwnd.?) == 0);

            // The source keeps A and C, and C, beside B, is in front.
            try std.testing.expectEqual(@as(usize, 2), source.tabs.items.len);
            try std.testing.expectEqual(tab_a, source.tabs.items[0].focusedSurface().?);
            try std.testing.expectEqual(tab_c, source.tabs.items[1].focusedSurface().?);
            try std.testing.expectEqual(@as(usize, 1), source.active_tab);
            try std.testing.expect(tab_c.window_visible);
            try app.validateShellNativeMapping();

            // The session sees two windows: the source with two tabs, the
            // new one with B's two panes.
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const state = try app.buildSessionState(arena.allocator(), 0);
            try std.testing.expectEqual(@as(usize, 2), state.windows.len);
            var tabs_seen: usize = 0;
            for (state.windows) |saved| tabs_seen += saved.tabs.len;
            try std.testing.expectEqual(@as(usize, 3), tabs_seen);
        }
    }.body);
}

test "win32 a tab moved into another window lands at its place in front, and the window it emptied closes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const lone_host = try setup.window(1, false);
            const lone = lone_host.activeSurface().?;
            const lone_hwnd = lone.hwnd.?;
            const target = try setup.window(2, false);
            const x = target.tabs.items[0].focusedSurface().?;
            const y = target.tabs.items[1].focusedSurface().?;
            const lone_host_id = lone_host.id;

            // Not into the window it is in, and a tab drop never into the
            // quick terminal.
            try std.testing.expect(!try app.moveTabToWindow(lone_host, 0, .{ .host = .{ .host = lone_host, .index = 0 } }));
            // An only tab is already alone in its window.
            try std.testing.expect(!try app.moveTabToWindow(lone_host, 0, .{ .new_window = null }));

            try std.testing.expect(try app.moveTabToWindow(lone_host, 0, .{ .host = .{ .host = target, .index = 1 } }));
            try std.testing.expect(app.registry.findHostById(lone_host_id) == null);
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            try std.testing.expectEqual(@as(usize, 3), target.tabs.items.len);
            try std.testing.expectEqual(x, target.tabs.items[0].focusedSurface().?);
            try std.testing.expectEqual(lone, target.tabs.items[1].focusedSurface().?);
            try std.testing.expectEqual(y, target.tabs.items[2].focusedSurface().?);
            try std.testing.expectEqual(@as(usize, 1), target.active_tab);
            try std.testing.expectEqual(target, lone.host.?);
            try std.testing.expectEqual(lone_hwnd, lone.hwnd.?);
            try std.testing.expectEqual(target.hwnd.?, sys.GetParent(lone_hwnd).?);
            try std.testing.expect(lone.window_visible);
            try std.testing.expect(!x.window_visible and !y.window_visible);
            // Tab ids are the window's own: no two alike.
            try std.testing.expect(target.tabs.items[0].id != target.tabs.items[1].id and
                target.tabs.items[1].id != target.tabs.items[2].id and target.tabs.items[0].id != target.tabs.items[2].id);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 moving a tab clears both windows' undo history, so an undo after it brings nothing back" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            const target = try setup.window(2, false);
            // A closed tab in each window waits in undo history. The move
            // disposes them, and `destroy` unregisters only a surface whose
            // core it stopped (`WindowStartTestApp.closeWindow`).
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            fixture.core_app.deleteSurface(target.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            try std.testing.expect(try app.closeTabUndoable(target, 0));
            try std.testing.expect(source.hasStructuralHistory());
            try std.testing.expect(target.hasStructuralHistory());
            const windows_before = app.registry.windows.items.len;

            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 0 } }));
            // The closed tabs' terminals end now, as at their undo timeout.
            try std.testing.expect(!source.hasStructuralHistory());
            try std.testing.expect(!target.hasStructuralHistory());
            try std.testing.expectEqual(windows_before - 2, app.registry.windows.items.len);
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 2), target.tabs.items.len);
            // Undo has nothing structural to replay in either window.
            try std.testing.expect(source.peekStructuralUndo() == null and target.peekStructuralUndo() == null);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 move_tab_to_new_window moves the tab from the message loop, and does nothing for an only tab" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const lone_host = try setup.window(1, false);
            const lone = lone_host.activeSurface().?;
            try std.testing.expect(!try app.performAction(.{ .surface = lone.core() }, .move_tab_to_new_window, {}));
            try std.testing.expect(app.pendingTabMoveCount(lone_host) == 0);

            const source = try setup.window(2, false);
            // A window the fixture made after the first is a `CW_USEDEFAULT`
            // 1280x800, which on a small CI screen fills the work area, so a
            // cascade step had no room and the new window sat on its source
            // (CI run 42542639547). Put it where there is room to step.
            const monitor = sys.MonitorFromWindow(source.hwnd.?, c.MONITOR_DEFAULTTONEAREST) orelse return error.TestNoMonitor;
            var info: sys.MONITORINFO = std.mem.zeroes(sys.MONITORINFO);
            info.cbSize = @sizeOf(sys.MONITORINFO);
            try std.testing.expect(sys.GetMonitorInfoW(monitor, &info) != 0);
            const work = info.rcWork;
            try std.testing.expect(sys.SetWindowPos(source.hwnd.?, null, work.left + 100, work.top + 80, 480, 320, c.SWP_NOZORDER | c.SWP_NOACTIVATE) != 0);
            const front = source.activeSurface().?;
            try std.testing.expect(try app.performAction(.{ .surface = front.core() }, .move_tab_to_new_window, {}));
            // Nothing moves inside the key binding's call.
            try std.testing.expectEqual(source, front.host.?);
            try std.testing.expect(app.pendingTabMoveCount(source) != 0);
            TabMoveFixture.runPosted(source);
            try std.testing.expect(app.pendingTabMoveCount(source) == 0);
            try std.testing.expect(front.host.? != source);
            try std.testing.expectEqual(@as(usize, 3), app.registry.hosts.items.len);
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 1), front.host.?.tabs.items.len);
            // One cascade step off its source, at its size, as a new window
            // from it.
            var source_rect: RECT = undefined;
            var moved_rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source.hwnd.?, &source_rect) != 0);
            try std.testing.expect(sys.GetWindowRect(front.host.?.hwnd.?, &moved_rect) != 0);
            const step = window_start.cascadeStep(sys.GetDpiForWindow(source.hwnd.?));
            try std.testing.expectEqual(source_rect.left + step, moved_rect.left);
            try std.testing.expectEqual(source_rect.top + step, moved_rect.top);
            try std.testing.expectEqual(source_rect.right - source_rect.left, moved_rect.right - moved_rect.left);
            try std.testing.expectEqual(source_rect.bottom - source_rect.top, moved_rect.bottom - moved_rect.top);
            try app.validateShellNativeMapping();

            // A request whose tab has gone does nothing.
            _ = app.requestTabMove(source, 999, .{ .new_window = null });
            app.drainPendingTabMoves();
            try std.testing.expectEqual(@as(usize, 3), app.registry.hosts.items.len);
        }
    }.body);
}

test "win32 a tab dragged out of its window tears off where it is dropped, and Esc ends a drag where it began" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn post(button: HWND, msg: UINT, x: i32, y: i32) void {
            const lx: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
            const ly: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
            _ = sys.SendMessageW(button, msg, if (msg == c.WM_LBUTTONUP) 0 else 1, @bitCast(@as(usize, (ly << 16) | lx)));
        }

        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            try source.layout();
            const dragged = source.tabs.items[1].focusedSurface().?;
            const button = source.tabs.items[1].button_hwnd orelse return error.TestNoTabButton;
            var client: RECT = undefined;
            try std.testing.expect(sys.GetClientRect(source.hwnd.?, &client) != 0);

            // Esc: down on tab 2, out past the bottom of the window, Esc.
            post(button, c.WM_LBUTTONDOWN, 20, 10);
            post(button, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            try std.testing.expect(source.tab_drag_target == .new_window);
            const escape: MSG = .{ .hwnd = dragged.hwnd.?, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 0, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.cancelTabDragForKey(&escape));
            try std.testing.expect(source.tab_drag_index == null);
            try std.testing.expect(source.tab_drag_target == .stay);
            post(button, c.WM_LBUTTONUP, 20, client.bottom + 200);
            try std.testing.expect(app.pendingTabMoveCount(source) == 0);
            try std.testing.expectEqual(@as(usize, 3), source.tabs.items.len);
            try std.testing.expectEqual(source, dragged.host.?);
            // Esc with no drag is the terminal's.
            try std.testing.expect(!app.cancelTabDragForKey(&escape));

            // The same drag, released: a new window under the pointer.
            post(button, c.WM_LBUTTONDOWN, 20, 10);
            post(button, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            try std.testing.expect(source.tab_drag_target == .new_window);
            post(button, c.WM_LBUTTONUP, 20, client.bottom + 200);
            try std.testing.expect(app.pendingTabMoveCount(source) != 0);
            var drop_at: POINT = .{ .x = 20, .y = client.bottom + 200 };
            _ = sys.ClientToScreen(button, &drop_at);
            TabMoveFixture.runPosted(source);
            const target = dragged.host.?;
            try std.testing.expect(target != source);
            try std.testing.expectEqual(@as(usize, 2), source.tabs.items.len);
            var placed: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(target.hwnd.?, &placed) != 0);
            // Under the pointer, unless the work area pushed it in.
            const monitor = sys.MonitorFromPoint(drop_at, c.MONITOR_DEFAULTTONEAREST).?;
            var info: sys.MONITORINFO = std.mem.zeroes(sys.MONITORINFO);
            info.cbSize = @sizeOf(sys.MONITORINFO);
            try std.testing.expect(sys.GetMonitorInfoW(monitor, &info) != 0);
            if (drop_at.y + 1 < info.rcWork.bottom) {
                try std.testing.expect(placed.left <= drop_at.x and drop_at.x < placed.right);
                try std.testing.expect(placed.top <= drop_at.y and drop_at.y < placed.bottom);
            }
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a tab dragged onto another window's strip moves there at the pointer, with a bar showing where" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn post(button: HWND, msg: UINT, x: i32, y: i32) void {
            const lx: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
            const ly: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
            _ = sys.SendMessageW(button, msg, if (msg == c.WM_LBUTTONUP) 0 else 1, @bitCast(@as(usize, (ly << 16) | lx)));
        }

        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(2, false);
            // Side by side, so neither covers the other's strip.
            var source_rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source.hwnd.?, &source_rect) != 0);
            _ = sys.SetWindowPos(target.hwnd.?, null, source_rect.right + 40, source_rect.top, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            try source.layout();
            try target.layout();
            const dragged = source.tabs.items[0].focusedSurface().?;
            const button = source.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const strip = target.tabStripScreenRect() orelse return error.TestNoTabStrip;
            // Left of the target's first tab's middle: it goes first.
            const at: POINT = .{ .x = strip.left + 4, .y = strip.top + @divTrunc(strip.bottom - strip.top, 2) };
            var local = at;
            _ = sys.ScreenToClient(button, &local);

            post(button, c.WM_LBUTTONDOWN, 20, 10);
            post(button, c.WM_MOUSEMOVE, local.x, local.y);
            switch (source.tab_drag_target) {
                .window => |over| {
                    try std.testing.expectEqual(target.id, over.host_id);
                    try std.testing.expectEqual(@as(usize, 0), over.index);
                },
                else => return error.TestExpectedWindowTarget,
            }
            try std.testing.expect(target.tab_insert_marker_hwnd != null);
            try std.testing.expect(sys.IsWindowVisible(target.tab_insert_marker_hwnd.?) != 0);
            post(button, c.WM_LBUTTONUP, local.x, local.y);
            // The bar goes with the drag.
            try std.testing.expect(sys.IsWindowVisible(target.tab_insert_marker_hwnd.?) == 0);
            TabMoveFixture.runPosted(source);
            try std.testing.expectEqual(target, dragged.host.?);
            try std.testing.expectEqual(dragged, target.tabs.items[0].focusedSurface().?);
            try std.testing.expectEqual(@as(usize, 3), target.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

fn testWindowData(hwnd: HWND) usize {
    return @bitCast(sys.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA));
}

test "win32 a moved pane's search bar answers to its new window, and no child of it names the window it left" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        var freed: usize = 0;
        var named_freed: usize = 0;

        fn visit(child: HWND, _: LPARAM) callconv(.winapi) BOOL {
            if (testWindowData(child) == freed) named_freed += 1;
            return 1;
        }

        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const first = try setup.window(2, false);
            const target = try setup.window(2, false);
            // The search bar is made before the tab moves.
            const pane = first.activeSurface().?;
            try pane.ensureSearchBarControls();
            const edit = pane.search_bar_edit_hwnd.?;
            const buttons = [_]HWND{
                pane.search_bar_prev_hwnd.?, pane.search_bar_next_hwnd.?, pane.search_bar_regex_hwnd.?,
                pane.search_bar_case_hwnd.?, pane.search_bar_word_hwnd.?, pane.search_bar_close_hwnd.?,
            };
            const frame = pane.search_bar_bg_hwnd.?;
            const chip = pane.search_bar_results_hwnd.?;
            try std.testing.expectEqual(@intFromPtr(first), testWindowData(edit));

            // A tear-off: the controls answer to the new window.
            try std.testing.expect(try app.moveTabToWindow(first, first.active_tab, .{ .new_window = null }));
            const source = pane.host.?;
            try std.testing.expect(source != first);
            try std.testing.expectEqual(@intFromPtr(source), testWindowData(edit));
            for (buttons) |button| try std.testing.expectEqual(@intFromPtr(source), testWindowData(button));
            try std.testing.expectEqual(pane, source.searchControlSurface(edit).?);
            // The frame and the results chip name the pane, which moved with them.
            try std.testing.expectEqual(@intFromPtr(pane), testWindowData(frame));
            try std.testing.expectEqual(@intFromPtr(pane), testWindowData(chip));

            // Then the torn-off window's only tab joins the other window,
            // and the torn-off window is freed.
            freed = @intFromPtr(source);
            named_freed = 0;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 0 } }));
            try std.testing.expectEqual(target, pane.host.?);
            try std.testing.expectEqual(@intFromPtr(pane), testWindowData(frame));
            try std.testing.expectEqual(@intFromPtr(pane), testWindowData(chip));
            // The edit and the buttons find their pane through their window.
            try std.testing.expectEqual(@intFromPtr(target), testWindowData(edit));
            for (buttons) |button| try std.testing.expectEqual(@intFromPtr(target), testWindowData(button));
            try std.testing.expectEqual(pane, target.searchControlSurface(edit).?);
            for (buttons) |button| try std.testing.expectEqual(pane, target.searchControlSurface(button).?);
            // Nothing in the window names the freed one.
            _ = sys.EnumChildWindows(target.hwnd.?, &visit, 0);
            try std.testing.expectEqual(@as(usize, 0), named_freed);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a tab dragged over another window on top of its own goes to the one on top" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn post(button: HWND, msg: UINT, x: i32, y: i32) void {
            const lx: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
            const ly: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
            _ = sys.SendMessageW(button, msg, if (msg == c.WM_LBUTTONUP) 0 else 1, @bitCast(@as(usize, (ly << 16) | lx)));
        }

        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(2, false);
            var source_rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source.hwnd.?, &source_rect) != 0);
            // The target over the middle of the source, above it (an
            // always-on-top window, or simply one in front).
            _ = sys.SetWindowPos(target.hwnd.?, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))), source_rect.left + 120, source_rect.top + 160, 420, 260, c.SWP_NOACTIVATE);
            try source.layout();
            try target.layout();
            const button = source.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const strip = target.tabStripScreenRect() orelse return error.TestNoTabStrip;
            const at: POINT = .{ .x = strip.left + 4, .y = strip.top + @divTrunc(strip.bottom - strip.top, 2) };
            var local = at;
            _ = sys.ScreenToClient(button, &local);

            post(button, c.WM_LBUTTONDOWN, 20, 10);
            post(button, c.WM_MOUSEMOVE, local.x, local.y);
            switch (source.tab_drag_target) {
                .window => |over| try std.testing.expectEqual(target.id, over.host_id),
                else => return error.TestExpectedWindowTarget,
            }
            // The source over the target instead: the source covers that
            // strip, and the drag stays where it is.
            _ = sys.SetWindowPos(target.hwnd.?, @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))), 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
            _ = sys.SetWindowPos(target.hwnd.?, source.hwnd.?, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE);
            post(button, c.WM_MOUSEMOVE, local.x + 1, local.y);
            try std.testing.expect(source.tab_drag_target != .window);
            post(button, c.WM_LBUTTONUP, local.x + 1, local.y);
        }
    }.body);
}

test "win32 a torn-off window keeps its size while its moved pane's font changes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        var before: RECT = undefined;
        var after: RECT = undefined;
        var ran = false;

        /// What the core does as the moved pane takes the new window's DPI
        /// with `window-width`/`window-height` set: an `initial_size` from
        /// its new font (`Surface.recomputeInitialSize`).
        fn activating(host: *Host, pane: *Surface) anyerror!void {
            ran = true;
            if (sys.GetWindowRect(host.hwnd.?, &before) == 0) return error.TestNoRect;
            _ = try pane.app.performAction(.{ .surface = pane.core() }, .initial_size, .{ .width = 300, .height = 200 });
            if (sys.GetWindowRect(host.hwnd.?, &after) == 0) return error.TestNoRect;
        }

        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const pane = source.activeSurface().?;
            ran = false;
            App.test_tab_move_activating = &activating;
            defer App.test_tab_move_activating = null;
            try std.testing.expect(try app.moveTabToWindow(source, 1, .{ .new_window = null }));
            try std.testing.expect(ran);
            try std.testing.expectEqualDeep(before, after);
            // The size is still the pane's, for `reset_window_size`.
            try std.testing.expectEqual(@as(u32, 300), pane.metrics.default_client_size.?.width);
            // After the move it resizes its window again, as any pane does.
            var resized: RECT = undefined;
            _ = try app.performAction(.{ .surface = pane.core() }, .initial_size, .{ .width = 320, .height = 220 });
            try std.testing.expect(sys.GetWindowRect(pane.host.?.hwnd.?, &resized) != 0);
            try std.testing.expect(!std.meta.eql(resized, after));
        }
    }.body);
}

test "win32 a tab drag's label is a live UIA element that speaks when what a drop does changes, and the insert bar is decorative" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn post(button: HWND, msg: UINT, x: i32, y: i32) void {
            const lx: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
            const ly: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
            _ = sys.SendMessageW(button, msg, if (msg == c.WM_LBUTTONUP) 0 else 1, @bitCast(@as(usize, (ly << 16) | lx)));
        }

        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(2, false);
            var source_rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source.hwnd.?, &source_rect) != 0);
            _ = sys.SetWindowPos(target.hwnd.?, null, source_rect.right + 40, source_rect.top, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            try source.layout();
            try target.layout();
            const button = source.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const strip = target.tabStripScreenRect() orelse return error.TestNoTabStrip;
            var on_strip: POINT = .{ .x = strip.left + 4, .y = strip.top + @divTrunc(strip.bottom - strip.top, 2) };
            _ = sys.ScreenToClient(button, &on_strip);
            var client: RECT = undefined;
            try std.testing.expect(sys.GetClientRect(source.hwnd.?, &client) != 0);

            const spoken = win32_uia.events.testing_live_regions;
            App.test_tab_drag_label_shown_when_spoken = null;
            defer App.test_tab_drag_label_shown_when_spoken = null;
            post(button, c.WM_LBUTTONDOWN, 20, 10);
            // Out of the window: "New window", said once however far it goes,
            // and said with the label, made just now, already on screen.
            post(button, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            try std.testing.expectEqual(@as(?bool, true), App.test_tab_drag_label_shown_when_spoken);
            post(button, c.WM_MOUSEMOVE, 24, client.bottom + 210);
            post(button, c.WM_MOUSEMOVE, 28, client.bottom + 220);
            try std.testing.expectEqual(spoken + 1, win32_uia.events.testing_live_regions);
            try std.testing.expect(app.tab_drag_preview_uia_provider != null);
            try std.testing.expectEqualStrings("New window", app.tabDragLabelAction());
            // Over the other window's strip: "Move to this window", once.
            post(button, c.WM_MOUSEMOVE, on_strip.x, on_strip.y);
            post(button, c.WM_MOUSEMOVE, on_strip.x + 1, on_strip.y);
            try std.testing.expectEqual(spoken + 2, win32_uia.events.testing_live_regions);
            try std.testing.expectEqualStrings("Move to this window", app.tabDragLabelAction());
            try std.testing.expect(target.tab_insert_marker_uia_provider != null);
            // Back inside the window the label hides; out again, it is said
            // again, shown again first.
            App.test_tab_drag_label_shown_when_spoken = null;
            post(button, c.WM_MOUSEMOVE, 20, 10);
            try std.testing.expectEqual(spoken + 2, win32_uia.events.testing_live_regions);
            post(button, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            try std.testing.expectEqual(spoken + 3, win32_uia.events.testing_live_regions);
            try std.testing.expectEqual(@as(?bool, true), App.test_tab_drag_label_shown_when_spoken);
            post(button, c.WM_LBUTTONUP, 20, 10);
            TabMoveFixture.runPosted(source);
        }
    }.body);
}

fn testPostTabMouse(button: HWND, msg: UINT, x: i32, y: i32) void {
    const lx: u32 = @as(u16, @bitCast(@as(i16, @truncate(x))));
    const ly: u32 = @as(u16, @bitCast(@as(i16, @truncate(y))));
    _ = sys.SendMessageW(button, msg, if (msg == c.WM_LBUTTONUP) 0 else 1, @bitCast(@as(usize, (ly << 16) | lx)));
}

/// The middle of tab `index`'s button, in `from`'s client coordinates.
fn testTabMiddleIn(host: *Host, index: usize, from: HWND) !POINT {
    var rect: RECT = undefined;
    if (sys.GetWindowRect(host.tabs.items[index].button_hwnd orelse return error.TestNoTabButton, &rect) == 0) return error.TestNoRect;
    var at: POINT = .{ .x = rect.left + @divTrunc(rect.right - rect.left, 2), .y = rect.top + @divTrunc(rect.bottom - rect.top, 2) };
    _ = sys.ScreenToClient(from, &at);
    return at;
}

test "win32 Esc during a tab drag puts back a reorder made on the way, takes its key-up, and swallows the release" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const first = host.tabs.items[0].focusedSurface().?;
            const second = host.tabs.items[1].focusedSurface().?;
            const third = host.tabs.items[2].focusedSurface().?;
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const over_third = try testTabMiddleIn(host, 2, button);

            // Along the strip onto the third tab: the first moves there.
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_third.x, over_third.y);
            try std.testing.expectEqual(first, host.tabs.items[2].focusedSurface().?);
            try std.testing.expectEqual(@as(?usize, 2), host.tab_drag_index);

            const down: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            const up: MSG = .{ .hwnd = button, .message = c.WM_KEYUP, .wParam = c.VK_ESCAPE, .lParam = @bitCast(@as(usize, 0xC0000001)), .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.cancelTabDragForKey(&down));
            // The order it had.
            try std.testing.expectEqual(first, host.tabs.items[0].focusedSurface().?);
            try std.testing.expectEqual(second, host.tabs.items[1].focusedSurface().?);
            try std.testing.expectEqual(third, host.tabs.items[2].focusedSurface().?);
            // Its key-up is taken once; a later one is the terminal's.
            try std.testing.expect(app.cancelTabDragForKey(&up));
            try std.testing.expect(!app.cancelTabDragForKey(&up));
            // The release over the third tab neither reorders nor activates.
            const active = host.active_tab;
            try std.testing.expect(host.tab_drag_cancelled);
            testPostTabMouse(button, c.WM_LBUTTONUP, over_third.x, over_third.y);
            try std.testing.expect(!host.tab_drag_cancelled);
            try std.testing.expectEqual(active, host.active_tab);
            try std.testing.expectEqual(first, host.tabs.items[0].focusedSurface().?);

            // A key-up that never came does not take the next Esc's: that
            // Esc (no drag) is the terminal's, and so is its key-up.
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_third.x, over_third.y);
            try std.testing.expect(app.cancelTabDragForKey(&down));
            testPostTabMouse(button, c.WM_LBUTTONUP, over_third.x, over_third.y);
            try std.testing.expect(!app.cancelTabDragForKey(&down));
            try std.testing.expect(!app.cancelTabDragForKey(&up));
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a refused reorder during a tab drag leaves the drag on the tab it is on" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const first = host.tabs.items[0].focusedSurface().?;
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const over_second = try testTabMiddleIn(host, 1, button);
            // Every reorder is refused (each real refusal logs an error,
            // which fails a test, so the seam refuses quietly).
            Host.test_swap_refused = true;
            defer Host.test_swap_refused = false;
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_second.x, over_second.y);
            try std.testing.expectEqual(first, host.tabs.items[0].focusedSurface().?);
            try std.testing.expectEqual(@as(?usize, 0), host.tab_drag_index);
            const down: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.cancelTabDragForKey(&down));
            testPostTabMouse(button, c.WM_LBUTTONUP, over_second.x, over_second.y);
        }
    }.body);
}

test "win32 a title prompt about the tab in front closes when that tab moves away" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            // The front tab's rename prompt, then the tab leaves.
            try host.showOverlay(.tab_title, "renamed");
            try std.testing.expect(host.overlay_mode == .tab_title);
            try std.testing.expect(try app.moveTabToWindow(host, host.active_tab, .{ .new_window = null }));
            try std.testing.expect(host.overlay_mode == .none);
            // A tab behind the front one leaves the prompt alone.
            try host.showOverlay(.tab_title, "renamed");
            const behind: usize = if (host.active_tab == 0) 1 else 0;
            try std.testing.expect(try app.moveTabToWindow(host, behind, .{ .new_window = null }));
            try std.testing.expect(host.overlay_mode == .tab_title);
            host.hideOverlay();
        }
    }.body);
}

test "win32 the tab insert bar is subclassed once, however often its UIA element fails to be made" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(2, false);
            try host.layout();
            // No COM, so no UIA element: twice.
            const com = app.com_initialized;
            app.com_initialized = false;
            defer app.com_initialized = com;
            host.showTabInsertMarker(0);
            host.showTabInsertMarker(1);
            try std.testing.expect(host.tab_insert_marker_uia_provider == null);
            const marker = host.tab_insert_marker_hwnd orelse return error.TestNoMarker;
            const proc: usize = @bitCast(sys.GetWindowLongPtrW(marker, c.GWLP_WNDPROC));
            // Its previous procedure is the STATIC's, never itself, so a
            // forwarded message returns.
            try std.testing.expect(host.tab_insert_marker_prev_proc != null);
            try std.testing.expect(@intFromPtr(host.tab_insert_marker_prev_proc.?) != proc);
            _ = sys.SendMessageW(marker, 0x000E, 0, 0);
            // With COM back, the element is made on the next show, the
            // subclass untouched.
            app.com_initialized = com;
            host.showTabInsertMarker(0);
            try std.testing.expect(host.tab_insert_marker_uia_provider != null);
            try std.testing.expectEqual(proc, @as(usize, @bitCast(sys.GetWindowLongPtrW(marker, c.GWLP_WNDPROC))));
            _ = sys.SendMessageW(marker, 0x000E, 0, 0);
            host.hideTabInsertMarker();
        }
    }.body);
}

fn testWindowTitle(hwnd: HWND, buf: *[256]u8) []const u8 {
    var wide: [256]u16 = undefined;
    const len: usize = @intCast(@max(0, sys.GetWindowTextW(hwnd, &wide, wide.len)));
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch 0;
    return buf[0..n];
}

test "win32 a tab move a nested message loop dispatches waits for the outer pump" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const lone = try setup.window(1, false);
            const pane = lone.activeSurface().?;
            const target = try setup.window(2, false);
            // An only tab's merge waits, and a menu or the system move loop
            // pumps messages, the move's wake among them, while the handler
            // that opened it still holds `lone`.
            try std.testing.expect(app.requestTabMove(lone, lone.tabs.items[0].id, .{ .window = .{ .host_id = target.id, .index = 0 } }));
            var msg: MSG = undefined;
            while (sys.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
                _ = sys.TranslateMessage(&msg);
                _ = sys.DispatchMessageW(&msg);
            }
            // Nothing moved, and the window is still whole.
            try std.testing.expectEqual(lone, pane.host.?);
            try std.testing.expectEqual(@as(usize, 1), app.pendingTabMoveCount(lone));
            // The outer pump runs it.
            app.drainPendingTabMoves();
            try std.testing.expectEqual(target, pane.host.?);
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 an all: move_tab_to_new_window moves every tab it reaches but the last" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            const panes = [_]*Surface{ source.tabs.items[0].focusedSurface().?, source.tabs.items[1].focusedSurface().?, source.tabs.items[2].focusedSurface().? };
            // What `all:` does: the action for every surface.
            for (panes) |pane| _ = try app.performAction(.{ .surface = pane.core() }, .move_tab_to_new_window, {});
            try std.testing.expectEqual(@as(usize, 3), app.pendingTabMoveCount(source));
            app.drainPendingTabMoves();
            // Two moved, each into a window of its own; the last stays.
            try std.testing.expectEqual(@as(usize, 3), app.registry.hosts.items.len);
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try std.testing.expect(panes[0].host.? != source and panes[1].host.? != source and panes[0].host.? != panes[1].host.?);
            try std.testing.expectEqual(source, panes[2].host.?);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a tab move whose window cannot be made keeps both windows' undo history" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn fails(_: *Host) anyerror!void {
            return error.TestWindowCreateFailed;
        }

        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            // The closed tab stays in history after this test, so its stand-in
            // core is unregistered as `closeWindow` would.
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            try std.testing.expect(source.hasStructuralHistory());
            const hook = App.test_tear_off_window_created;
            App.test_tear_off_window_created = &fails;
            defer App.test_tear_off_window_created = hook;
            try std.testing.expectError(error.TestWindowCreateFailed, app.moveTabToWindow(source, 0, .{ .new_window = null }));
            // Nothing moved, no window is left over, and the closed tab can
            // still come back.
            try std.testing.expect(source.hasStructuralHistory());
            try std.testing.expectEqual(@as(usize, 2), source.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 moving a tab behind the front one recounts the window's caption" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            try std.testing.expectEqual(@as(usize, 2), source.active_tab);
            var buf: [256]u8 = undefined;
            try std.testing.expect(std.mem.startsWith(u8, testWindowTitle(source.hwnd.?, &buf), "[3/3]"));
            // A tab behind the front one leaves; the front pane stays in front.
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .new_window = null }));
            try std.testing.expect(std.mem.startsWith(u8, testWindowTitle(source.hwnd.?, &buf), "[2/2]"));
        }
    }.body);
}

test "win32 a held Esc that ended a tab drag is taken until it comes up" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            var client: RECT = undefined;
            try std.testing.expect(sys.GetClientRect(host.hwnd.?, &client) != 0);
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            const down: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            const held: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = @bitCast(@as(usize, 0x40000001)), .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            const up: MSG = .{ .hwnd = button, .message = c.WM_KEYUP, .wParam = c.VK_ESCAPE, .lParam = @bitCast(@as(usize, 0xC0000001)), .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.cancelTabDragForKey(&down));
            // Its repeats and its key-up are taken...
            try std.testing.expect(app.cancelTabDragForKey(&held));
            try std.testing.expect(app.cancelTabDragForKey(&held));
            try std.testing.expect(app.cancelTabDragForKey(&up));
            // ...and the next press, held or not, is the terminal's.
            try std.testing.expect(!app.cancelTabDragForKey(&down));
            try std.testing.expect(!app.cancelTabDragForKey(&held));
            try std.testing.expect(!app.cancelTabDragForKey(&up));
            testPostTabMouse(button, c.WM_LBUTTONUP, 20, client.bottom + 200);
            try std.testing.expectEqual(@as(usize, 0), app.pendingTabMoveCount(host));
        }
    }.body);
}

test "win32 a tab drag follows its own tab when a key binding changes the strip during it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(4, false);
            try host.layout();
            // Drag the third tab (C), out of the window.
            const dragged = host.tabs.items[2].focusedSurface().?;
            const before_it = host.tabs.items[3].focusedSurface().?;
            const button = host.tabs.items[2].button_hwnd orelse return error.TestNoTabButton;
            var client: RECT = undefined;
            try std.testing.expect(sys.GetClientRect(host.hwnd.?, &client) != 0);
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            // Meanwhile a key binding moves the first tab to a new window and
            // `move_tab` moves the last one to the front.
            try std.testing.expect(try app.moveTabToWindow(host, 0, .{ .new_window = null }));
            try std.testing.expect(try app.moveTab(.{ .surface = host.tabs.items[2].focusedSurface().?.core() }, .{ .amount = -2 }));
            // Esc puts C back before the tab it was before, D.
            const down: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.cancelTabDragForKey(&down));
            testPostTabMouse(button, c.WM_LBUTTONUP, 20, client.bottom + 200);
            const at = Host.findTabForSurface(dragged).?.index;
            try std.testing.expectEqual(before_it, host.tabs.items[at + 1].focusedSurface().?);
            // A new drag of C, dropped outside: C tears off, not the tab now
            // at C's old index.
            const at_now = Host.findTabForSurface(dragged).?.index;
            const button_now = host.tabs.items[at_now].button_hwnd.?;
            testPostTabMouse(button_now, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button_now, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            try std.testing.expect(try app.moveTabToWindow(host, if (at_now == 0) 1 else 0, .{ .new_window = null }));
            testPostTabMouse(button_now, c.WM_LBUTTONUP, 20, client.bottom + 200);
            app.drainPendingTabMoves();
            try std.testing.expect(dragged.host.? != host);
            try std.testing.expectEqual(@as(usize, 1), host.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a tab drop goes where the windows are at its release" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(2, false);
            var source_rect: RECT = undefined;
            try std.testing.expect(sys.GetWindowRect(source.hwnd.?, &source_rect) != 0);
            _ = sys.SetWindowPos(target.hwnd.?, null, source_rect.right + 40, source_rect.top, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            try source.layout();
            try target.layout();
            const dragged = source.tabs.items[0].focusedSurface().?;
            const button = source.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const strip = target.tabStripScreenRect() orelse return error.TestNoTabStrip;
            var at: POINT = .{ .x = strip.left + 4, .y = strip.top + @divTrunc(strip.bottom - strip.top, 2) };
            _ = sys.ScreenToClient(button, &at);
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, at.x, at.y);
            try std.testing.expect(source.tab_drag_target == .window);
            // The target window moves away before the release, with no
            // pointer move in between.
            _ = sys.SetWindowPos(target.hwnd.?, null, source_rect.right + 1400, source_rect.top + 600, 640, 480, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            testPostTabMouse(button, c.WM_LBUTTONUP, at.x, at.y);
            app.drainPendingTabMoves();
            // Nothing is under the release but the desktop: a new window.
            try std.testing.expect(dragged.host.? != source);
            try std.testing.expect(dragged.host.? != target);
            try std.testing.expectEqual(@as(usize, 2), target.tabs.items.len);
        }
    }.body);
}

test "win32 an all: move_tab_to_new_window in a window of 18 tabs moves every one but the last" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(18, false);
            try std.testing.expectEqual(@as(usize, 18), source.tabs.items.len);
            var panes: [18]*Surface = undefined;
            for (source.tabs.items, 0..) |*tab, i| panes[i] = tab.focusedSurface().?;
            for (panes) |pane| _ = try app.performAction(.{ .surface = pane.core() }, .move_tab_to_new_window, {});
            app.drainPendingTabMoves();
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 18), app.registry.hosts.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a dragged tab that leaves its window by a key binding ends the drag and its feedback" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const front = host.active_tab;
            const button = host.tabs.items[front].button_hwnd orelse return error.TestNoTabButton;
            var client: RECT = undefined;
            try std.testing.expect(sys.GetClientRect(host.hwnd.?, &client) != 0);
            // Dragged out of the window: the label is up.
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, 20, client.bottom + 200);
            try std.testing.expect(app.tab_drag_preview_hwnd != null and sys.IsWindowVisible(app.tab_drag_preview_hwnd.?) != 0);
            // `move_tab_to_new_window` moves the dragged tab meanwhile.
            try std.testing.expect(try app.moveTabToWindow(host, front, .{ .new_window = null }));
            // The drag is over: no label, no drag state, and the next Esc is
            // the terminal's.
            try std.testing.expect(host.tab_drag_index == null);
            try std.testing.expect(!host.tab_drag_active);
            try std.testing.expect(sys.IsWindowVisible(app.tab_drag_preview_hwnd.?) == 0);
            const down: MSG = .{ .hwnd = host.hwnd.?, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(!app.cancelTabDragForKey(&down));
            try app.validateShellNativeMapping();
        }
    }.body);
}

fn testAcceptNothing(_: ?*anyopaque) void {}

test "win32 a close prompt counting a window's terminals goes when a tab joins or leaves that window" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            const target = try setup.window(2, false);
            // "Close this window?" counting its two terminals, and "Close
            // the other tabs?" in the source.
            target.askBeforeClosing(.window, 2, &testAcceptNothing, @ptrCast(target));
            try std.testing.expect(target.confirm_payload != null);
            source.askBeforeClosing(.other_tabs, 2, &testAcceptNothing, @ptrCast(source));
            try std.testing.expect(source.confirm_payload != null);
            // A tab with a terminal of its own arrives: neither count holds.
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 0 } }));
            try std.testing.expect(target.confirm_payload == null);
            try std.testing.expect(source.confirm_payload == null);
            // Another kind of prompt (here the quit prompt, which counts every
            // window's terminals alike) stays.
            target.askBeforeClosing(.app, 4, &testAcceptNothing, @ptrCast(target));
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 0 } }));
            try std.testing.expect(target.confirm_payload != null);
            target.hideOverlay();
        }
    }.body);
}

test "win32 Esc whose put-back reorder is refused leaves the strip and the shell model in step" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const first = host.tabs.items[0].focusedSurface().?;
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const over_third = try testTabMiddleIn(host, 2, button);
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_third.x, over_third.y);
            try std.testing.expectEqual(first, host.tabs.items[2].focusedSurface().?);
            // The put-back is refused: the tab stays where the drag left it,
            // natively and in the model alike.
            Host.test_swap_refused = true;
            defer Host.test_swap_refused = false;
            const down: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.cancelTabDragForKey(&down));
            testPostTabMouse(button, c.WM_LBUTTONUP, over_third.x, over_third.y);
            try std.testing.expectEqual(first, host.tabs.items[2].focusedSurface().?);
            try app.validateShellNativeMapping();
        }
    }.body);
}
test "win32 a tab move whose wake a nested loop took wakes the pump again until the pump itself sees it" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            try std.testing.expect(app.requestTabMove(source, source.tabs.items[1].id, .{ .new_window = null }));
            // A menu's loop, inside `GetMessage` (the pump dispatches nothing),
            // takes the wake: a timer keeps waking.
            app.outer_dispatch_message = 0;
            var msg: MSG = undefined;
            while (sys.PeekMessageW(&msg, null, c.WM_WINHOSTTY_TAB_MOVE, c.WM_WINHOSTTY_TAB_MOVE, c.PM_REMOVE) != 0) {
                _ = sys.DispatchMessageW(&msg);
            }
            try std.testing.expect(app.tab_move_wake_timer != null);
            // A second wake a nested loop takes starts no second timer.
            const timer = app.tab_move_wake_timer;
            try std.testing.expect(app.requestTabMove(source, source.tabs.items[0].id, .{ .new_window = null }));
            testNestedLoopTakesTabMoveWakes(app);
            try std.testing.expectEqual(timer, app.tab_move_wake_timer);
            // With nothing else posted, the timer's own tick reaches the
            // pump, which takes it (`takeTabMoveWakeTick`) and runs the moves
            // on its next turn.
            const until = sys.GetTickCount64() + 1000;
            const ticked = tick: while (sys.GetTickCount64() < until) {
                while (sys.PeekMessageW(&msg, null, c.WM_TIMER, c.WM_TIMER, c.PM_REMOVE) != 0) {
                    if (app.takeTabMoveWakeTick(&msg)) break :tick true;
                    _ = sys.DispatchMessageW(&msg);
                }
                std.Thread.sleep(5 * std.time.ns_per_ms);
            } else false;
            try std.testing.expect(ticked);
            try std.testing.expect(app.tab_move_wake_timer == null);
            try std.testing.expectEqual(@as(usize, 2), source.tabs.items.len);
            app.drainPendingTabMoves();
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 0), app.pending_tab_moves.items.len);
        }
    }.body);
}

test "win32 a hover over a tab with no button down starts no drag, the only tab's window move least of all" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(1, false);
            try host.layout();
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            // Drag state left behind with no capture and no button down.
            host.tab_drag_index = 0;
            host.tab_drag_active = true;
            host.tab_drag_tab_id = host.tabs.items[0].id;
            try std.testing.expect(sys.GetCapture() == null);
            _ = sys.SendMessageW(button, c.WM_MOUSEMOVE, 0, @bitCast(@as(usize, (200 << 16) | 20)));
            try std.testing.expect(host.only_tab_window_move == null);
            try std.testing.expect(host.tab_drag_index == null);
            // No system move was asked for either.
            var msg: MSG = undefined;
            try std.testing.expect(sys.PeekMessageW(&msg, host.hwnd.?, c.WM_SYSCOMMAND, c.WM_SYSCOMMAND, c.PM_REMOVE) == 0);
        }
    }.body);
}

const TestShellStepFailure = struct {
    var failing: std.testing.FailingAllocator = undefined;
    var kept: std.mem.Allocator = undefined;
    var step_wanted: App.TabMoveShellStep = .commit;
    var refocus: ?win32_shell.model.PaneId = null;

    /// Makes the shell model's next allocation fail at `step_wanted`; at the
    /// commit, a focus change first makes the prepared move stale, so the
    /// commit prepares again.
    fn hook(app: *App, step: App.TabMoveShellStep) void {
        if (step != step_wanted) return;
        if (refocus) |pane| _ = app.shell_runtime.focusPane(pane) catch {};
        kept = app.shell_runtime.state.allocator;
        failing = std.testing.FailingAllocator.init(kept, .{ .fail_index = 0 });
        app.shell_runtime.state.allocator = failing.allocator();
    }

    fn restore(app: *App) void {
        app.shell_runtime.state.allocator = kept;
    }
};

test "win32 a tab move whose stale commit runs out of memory keeps both windows' undo history" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            try std.testing.expect(source.hasStructuralHistory());
            // A focus change makes the prepared move stale at its commit, and
            // preparing it again runs out of memory.
            const front = source.activeSurface().?;
            const other = source.tabs.items[0].focusedSurface().?;
            TestShellStepFailure.step_wanted = .commit;
            TestShellStepFailure.refocus = other.shell_id.?;
            App.test_tab_move_shell_step = &TestShellStepFailure.hook;
            defer App.test_tab_move_shell_step = null;
            const moved = app.moveTabToWindow(source, source.active_tab, .{ .new_window = null });
            TestShellStepFailure.restore(app);
            try std.testing.expectError(error.OutOfMemory, moved);
            // Nothing moved, the new window is gone, and the closed tab can
            // still come back.
            try std.testing.expect(source.hasStructuralHistory());
            try std.testing.expectEqual(@as(usize, 2), source.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            // The focus change the hook made is put back for the audit.
            _ = try app.shell_runtime.focusPane(front.shell_id.?);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a tab move a transfer in undo history names keeps it gone if its second prepare runs out of memory (TEAROFF-01)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            // The first tab dragged into a split of the front one: a transfer
            // in undo history names the front tab.
            host.tab_drop_operation = .split_right;
            host.tab_drop_target_surface = host.tabs.items[2].focusedSurface().?;
            try std.testing.expect(host.commitTabDropSplit(0));
            try std.testing.expect(host.hasStructuralHistory());
            TestShellStepFailure.step_wanted = .retry_prepare;
            TestShellStepFailure.refocus = null;
            App.test_tab_move_shell_step = &TestShellStepFailure.hook;
            const moved = app.moveTabToWindow(host, host.active_tab, .{ .new_window = null });
            TestShellStepFailure.restore(app);
            App.test_tab_move_shell_step = null;
            // The residual case: the model refuses the move while the
            // transfer names the tab, so the history went first, and the
            // move failed after it. Nothing moved and no window is left.
            try std.testing.expectError(error.OutOfMemory, moved);
            try std.testing.expect(!host.hasStructuralHistory());
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            try app.validateShellNativeMapping();
            // With memory, the same move goes through.
            try std.testing.expect(try app.moveTabToWindow(host, host.active_tab, .{ .new_window = null }));
            try std.testing.expectEqual(@as(usize, 2), app.registry.hosts.items.len);
        }
    }.body);
}

/// What a nested loop does with the tab-move wakes it takes: dispatches them
/// with the outer pump out of the way.
fn testNestedLoopTakesTabMoveWakes(app: *App) void {
    const outer = app.outer_dispatch_message;
    app.outer_dispatch_message = 0;
    defer app.outer_dispatch_message = outer;
    var msg: MSG = undefined;
    while (sys.PeekMessageW(&msg, null, c.WM_WINHOSTTY_TAB_MOVE, c.WM_WINHOSTTY_TAB_MOVE, c.PM_REMOVE) != 0) {
        _ = sys.DispatchMessageW(&msg);
    }
}

test "win32 tab-move wakes a nested loop took from two windows leave nothing waking the app once both moves ran" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const first = try setup.window(2, false);
            const second = try setup.window(2, false);
            // A menu's loop takes the wake of a move asked of each window.
            try std.testing.expect(app.requestTabMove(first, first.tabs.items[1].id, .{ .new_window = null }));
            testNestedLoopTakesTabMoveWakes(app);
            try std.testing.expect(app.requestTabMove(second, second.tabs.items[1].id, .{ .new_window = null }));
            testNestedLoopTakesTabMoveWakes(app);
            const timer = app.tab_move_wake_timer;
            try std.testing.expect(timer != null);
            // The pump's next turn runs both.
            app.drainPendingTabMoves();
            try std.testing.expect(app.tab_move_wake_timer == null);
            try std.testing.expectEqual(@as(usize, 1), first.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 1), second.tabs.items.len);
            // Then nothing wakes the app for them any more: the one move
            // timer is gone (round 4 had one per window, and the first kept
            // firing, 8 times in this wait). Other timers go on.
            var fired: usize = 0;
            const until = sys.GetTickCount64() + 250;
            var msg: MSG = undefined;
            while (sys.GetTickCount64() < until) {
                while (sys.PeekMessageW(&msg, null, c.WM_TIMER, c.WM_TIMER, c.PM_REMOVE) != 0) {
                    if (@intFromPtr(msg.hwnd) == 0 and msg.wParam == timer.?) {
                        fired += 1;
                        continue;
                    }
                    _ = sys.DispatchMessageW(&msg);
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
            try std.testing.expectEqual(@as(usize, 0), fired);
        }
    }.body);
}

const TestHistoryDisposalFailure = struct {
    var failing: std.testing.FailingAllocator = undefined;
    var kept: std.mem.Allocator = undefined;
    var armed = false;

    /// The history clear after a tab move's commit runs with every model
    /// allocation failing: the first, the clone `discard_detached_tab`'s
    /// prepare makes, fails it.
    fn hook(app: *App, step: App.TabMoveShellStep) void {
        switch (step) {
            .history => {
                kept = app.shell_runtime.state.allocator;
                failing = std.testing.FailingAllocator.init(kept, .{ .fail_index = 0 });
                app.shell_runtime.state.allocator = failing.allocator();
                armed = true;
            },
            .after_history => if (armed) {
                app.shell_runtime.state.allocator = kept;
                armed = false;
            },
            else => {},
        }
    }
};

test "win32 a tab move that empties its window keeps the window, hidden, while undo history it could not dispose names a closed tab (TEAROFF-01)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(1, false);
            // A closed tab kept for undo: the model keeps the source's window
            // for it when its live tab leaves.
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            const window = source.shell_id.?;
            // Its live tab joins the other window, and disposing the closed
            // one after the commit runs out of memory.
            App.test_tab_move_shell_step = &TestHistoryDisposalFailure.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(TestHistoryDisposalFailure.failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 2), target.tabs.items.len);
            // The source stays, empty and hidden, with the history and its
            // model window: nothing the model keeps is left without a window.
            try std.testing.expectEqual(@as(usize, 2), app.registry.hosts.items.len);
            try std.testing.expectEqual(@as(usize, 0), source.tabs.items.len);
            try std.testing.expect(source.hasStructuralHistory());
            try std.testing.expect(source.destroy_after_structural_dispose);
            try std.testing.expect(sys.IsWindowVisible(source.hwnd.?) == 0);
            try std.testing.expect(source.shell_id != null and source.shell_id.?.eql(window));
            try std.testing.expect(app.shell_runtime.state.windowConst(window) != null);
            try app.validateShellNativeMapping();
            // The undo prune disposes the history, and the window goes with
            // the model's.
            _ = app.pruneUndoHistoryBefore(std.math.maxInt(u64));
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            try std.testing.expect(app.shell_runtime.state.windowConst(window) == null);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a close X click works after Esc ended a drag whose tab a key binding then moved away (council round 4 L1)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const dragged = host.tabs.items[0].id;
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const over_second = try testTabMiddleIn(host, 1, button);
            // A drag, Esc with the button still down, then a key binding
            // moves the dragged tab away before the release.
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_second.x, over_second.y);
            const esc: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.cancelTabDragForKey(&esc));
            try std.testing.expect(try app.moveTabToWindow(host, host.findTabIndexById(dragged).?, .{ .new_window = null }));
            // The held button's release is still coming, and is swallowed.
            try std.testing.expect(host.tab_drag_cancelled);
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
            // The next click on a close X in that window closes its tab.
            const closing = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            var rect: RECT = undefined;
            _ = sys.GetClientRect(closing, &rect);
            const x = rect.right - 4;
            const y = @divTrunc(rect.bottom, 2);
            fixture.core_app.deleteSurface(host.tabs.items[0].focusedSurface().?);
            testPostTabMouse(closing, c.WM_LBUTTONDOWN, x, y);
            testPostTabMouse(closing, c.WM_LBUTTONUP, x, y);
            try std.testing.expectEqual(@as(usize, 1), host.tabs.items.len);
        }
    }.body);
}

test "win32 an only tab merged into another window while its window keeps a closed tab for undo takes both windows' history with it (council round 4)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(1, false);
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            const window = source.shell_id.?;
            // With memory, the clear disposes the closed tab, the model's
            // window goes with its last retained tab, and so does the native
            // one: the path the commit-before-history order reshaped.
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            try std.testing.expectEqual(@as(usize, 2), target.tabs.items.len);
            try std.testing.expect(app.shell_runtime.state.windowConst(window) == null);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a window a tab move keeps hidden for its undo history stays hidden through the toggle_visibility that hid it while the move waited" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(1, false);
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            // `toggle_visibility` hides it while its live tab's merge waits.
            try std.testing.expect(sys.IsWindowVisible(source.hwnd.?) != 0);
            source.hideForToggle();
            try std.testing.expect(source.hidden_by_toggle);
            // The merge runs, and disposing the closed tab runs out of memory:
            // the source stays, empty and hidden, for its history.
            App.test_tab_move_shell_step = &TestHistoryDisposalFailure.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(source.destroy_after_structural_dispose);
            // It is not the toggle's to show again.
            try std.testing.expect(!source.hidden_by_toggle);
            try source.showAfterToggle();
            try std.testing.expect(sys.IsWindowVisible(source.hwnd.?) == 0);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 undo history a tab move could not dispose never replays, in the window the tab left or the one it joined (CodeRabbit review 5821962511)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            const target = try setup.window(2, false);
            // A closed tab kept for undo in each window.
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            fixture.core_app.deleteSurface(target.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(target, 0));
            // A tab joins the other window, and every disposal after the
            // commit runs out of memory: both windows keep their entries.
            App.test_tab_move_shell_step = &TestHistoryDisposalFailure.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(source.hasStructuralHistory());
            try std.testing.expect(target.hasStructuralHistory());
            // Neither replays: they keep tab indices and panes of the windows
            // as they were. An undo disposes them instead.
            try std.testing.expect((try target.applyLatestStructuralUndo()) == null);
            try std.testing.expectEqual(@as(usize, 2), target.tabs.items.len);
            try std.testing.expect(!target.hasStructuralHistory());
            try std.testing.expect((try source.applyLatestStructuralUndo()) == null);
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try std.testing.expect(!source.hasStructuralHistory());
            try app.validateShellNativeMapping();
        }
    }.body);
}

/// The held button's release, landing on tab `index`'s close X with no press
/// there: what a release after the dragged tab left does.
fn testReleaseOnCloseX(host: *Host, index: usize) !void {
    const button = host.tabs.items[index].button_hwnd orelse return error.TestNoTabButton;
    var rect: RECT = undefined;
    _ = sys.GetClientRect(button, &rect);
    testPostTabMouse(button, c.WM_LBUTTONUP, rect.right - 4, @divTrunc(rect.bottom, 2));
}

test "win32 the held button's release closes nothing when the dragged tab left mid-drag (council round 5 M1)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const Case = enum { esc_then_key_move, key_move, closed };
    for ([_]Case{ .esc_then_key_move, .key_move, .closed }) |case| try runOnHiddenDesktopWith(case);
}

fn runOnHiddenDesktopWith(case: anytype) !void {
    const Body = struct {
        var which: @TypeOf(case) = undefined;
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const dragged = host.tabs.items[0].id;
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const over_second = try testTabMiddleIn(host, 1, button);
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_second.x, over_second.y);
            // The tab leaves while the button is still down.
            switch (which) {
                .esc_then_key_move => {
                    const esc: MSG = .{ .hwnd = button, .message = c.WM_KEYDOWN, .wParam = c.VK_ESCAPE, .lParam = 1, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
                    try std.testing.expect(app.cancelTabDragForKey(&esc));
                    try std.testing.expect(try app.moveTabToWindow(host, host.findTabIndexById(dragged).?, .{ .new_window = null }));
                },
                .key_move => try std.testing.expect(try app.moveTabToWindow(host, host.findTabIndexById(dragged).?, .{ .new_window = null })),
                .closed => {
                    const at = host.findTabIndexById(dragged).?;
                    fixture.core_app.deleteSurface(host.tabs.items[at].focusedSurface().?);
                    try std.testing.expect(host.closeTabInPlace(at));
                },
            }
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
            // Its release, over another tab's X, closes nothing.
            try testReleaseOnCloseX(host, 0);
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    };
    Body.which = case;
    try runOnHiddenDesktop(Body.body);
}

test "win32 a close X release closes its tab only after a press on that X (council round 5 M1)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            // A release whose press began elsewhere (another window, outside
            // noctty): nothing.
            try testReleaseOnCloseX(host, 0);
            try std.testing.expectEqual(@as(usize, 3), host.tabs.items.len);
            // A press on one tab's X and its release on another's: nothing.
            const first = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            var rect: RECT = undefined;
            _ = sys.GetClientRect(first, &rect);
            testPostTabMouse(first, c.WM_LBUTTONDOWN, rect.right - 4, @divTrunc(rect.bottom, 2));
            try testReleaseOnCloseX(host, 1);
            try std.testing.expectEqual(@as(usize, 3), host.tabs.items.len);
            // A press and its release on the same X closes that tab.
            fixture.core_app.deleteSurface(host.tabs.items[0].focusedSurface().?);
            testPostTabMouse(first, c.WM_LBUTTONDOWN, rect.right - 4, @divTrunc(rect.bottom, 2));
            testPostTabMouse(first, c.WM_LBUTTONUP, rect.right - 4, @divTrunc(rect.bottom, 2));
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
        }
    }.body);
}

const TestCloseMovingTab = struct {
    var surface: ?*Surface = null;
    var closed = false;

    /// While undo history is disposed, window code closes the moving tab,
    /// wherever it is then: what a WinEvent or UIA hook run by a disposal's
    /// window teardown could do.
    fn hook(_: *App, step: App.TabMoveShellStep) void {
        if (step != .history) return;
        const pane = surface orelse return;
        surface = null;
        const host = pane.host orelse return;
        for (host.tabs.items, 0..) |*tab, i| if (tab.findHandle(pane) != null) {
            closed = host.closeTabInPlace(i);
            return;
        };
    }
};

test "win32 a tab move whose moving tab closes while undo history is disposed finishes with the model and the windows in step (CodeRabbit review 5822445361)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(3, false);
            const target = try setup.window(1, false);
            const moving = source.tabs.items[0].focusedSurface().?;
            fixture.core_app.deleteSurface(moving);
            TestCloseMovingTab.surface = moving;
            TestCloseMovingTab.closed = false;
            App.test_tab_move_shell_step = &TestCloseMovingTab.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(TestCloseMovingTab.closed);
            // It closed where it had landed, as any close does: the target
            // keeps its own tab, the source its other two.
            try std.testing.expectEqual(@as(usize, 1), target.tabs.items.len);
            try std.testing.expectEqual(@as(usize, 2), source.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a close X press whose capture another window took closes nothing on its release (CodeRabbit r4510086520)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const first = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            var rect: RECT = undefined;
            _ = sys.GetClientRect(first, &rect);
            testPostTabMouse(first, c.WM_LBUTTONDOWN, rect.right - 4, @divTrunc(rect.bottom, 2));
            // Another window takes the capture and lets it go, and the
            // release comes back over the same X.
            _ = sys.SendMessageW(first, c.WM_CAPTURECHANGED, 0, @bitCast(@intFromPtr(host.hwnd.?)));
            testPostTabMouse(first, c.WM_LBUTTONUP, rect.right - 4, @divTrunc(rect.bottom, 2));
            try std.testing.expectEqual(@as(usize, 3), host.tabs.items.len);
        }
    }.body);
}

test "win32 window cycling passes over a window kept empty for its undo history (CodeRabbit review 5822445361)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(1, false);
            const third = try setup.window(1, false);
            const fourth = try setup.window(1, false);
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            App.test_tab_move_shell_step = &TestHistoryDisposalFailure.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(source.destroy_after_structural_dispose);
            // The windows in order: the kept source (nothing to show), the
            // target, the third, the fourth. Each step lands on the window
            // after or before, the source passed over.
            const Step = struct { from: *Host, direction: apprt.action.GotoWindow, to: *Host };
            for ([_]Step{
                .{ .from = fourth, .direction = .next, .to = target },
                .{ .from = target, .direction = .previous, .to = fourth },
                .{ .from = target, .direction = .next, .to = third },
                .{ .from = third, .direction = .previous, .to = target },
                .{ .from = third, .direction = .next, .to = fourth },
            }) |step| {
                try std.testing.expect(try app.gotoWindow(.{ .surface = step.from.activeSurface().?.core() }, step.direction));
                // The keyboard is in the window it landed on.
                try std.testing.expectEqual(step.to.activeSurface().?.hwnd, sys.GetFocus());
            }
        }
    }.body);
}

test "win32 the held release of a tab moved mid-drag is taken in whatever window it lands, once (CodeRabbit r4510086531)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const dragged = host.tabs.items[0].focusedSurface().?;
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const over_second = try testTabMiddleIn(host, 1, button);
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_second.x, over_second.y);
            // The dragged tab moves away by a key binding: its window is
            // another one now, and the release lands on its terminal there.
            const at = for (host.tabs.items, 0..) |*tab, i| {
                if (tab.findHandle(dragged) != null) break i;
            } else return error.TestNoDraggedTab;
            try std.testing.expect(try app.moveTabToWindow(host, at, .{ .new_window = null }));
            try std.testing.expect(app.held_release_pending);
            const pane_hwnd = dragged.hwnd orelse return error.TestNoPaneWindow;
            const up: MSG = .{ .hwnd = pane_hwnd, .message = c.WM_LBUTTONUP, .wParam = 0, .lParam = 0, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(app.takeHeldRelease(&up));
            // Once: the next release is the terminal's.
            try std.testing.expect(!app.takeHeldRelease(&up));
            // A press forgets one that never came.
            app.held_release_pending = true;
            const down: MSG = .{ .hwnd = pane_hwnd, .message = c.WM_LBUTTONDOWN, .wParam = 1, .lParam = 0, .time = 0, .pt = .{ .x = 0, .y = 0 }, .lPrivate = 0 };
            try std.testing.expect(!app.takeHeldRelease(&down));
            try std.testing.expect(!app.takeHeldRelease(&up));
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a caption Close release closes the window only after a press on Close (council round 6 L2)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            app.use_integrated_titlebar = true;
            const host = try setup.window(2, false);
            try std.testing.expect(host.usingIntegratedTitlebar());
            const hwnd = host.hwnd.?;
            // A release over Close whose press was not this window's (a tab
            // that left mid-drag held it, or it began elsewhere): nothing.
            _ = sys.SendMessageW(hwnd, c.WM_NCLBUTTONUP, @bitCast(@as(isize, c.HTCLOSE)), 0);
            try std.testing.expect(sys.IsWindow(hwnd) != 0);
            try std.testing.expectEqual(@as(usize, 1), app.registry.hosts.items.len);
            // A press elsewhere on the caption and a release over Close:
            // nothing either.
            _ = sys.SendMessageW(hwnd, c.WM_NCLBUTTONDOWN, @bitCast(@as(isize, c.HTCAPTION)), 0);
            _ = sys.SendMessageW(hwnd, c.WM_NCLBUTTONUP, @bitCast(@as(isize, c.HTCLOSE)), 0);
            try std.testing.expect(sys.IsWindow(hwnd) != 0);
        }
    }.body);
}

test "win32 the held button's release closes nothing when the dragged tab's pane is destroyed mid-drag (council round 6 L5)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            try host.layout();
            const dragged = host.tabs.items[0].focusedSurface().?;
            const button = host.tabs.items[0].button_hwnd orelse return error.TestNoTabButton;
            const over_second = try testTabMiddleIn(host, 1, button);
            testPostTabMouse(button, c.WM_LBUTTONDOWN, 20, 10);
            testPostTabMouse(button, c.WM_MOUSEMOVE, over_second.x, over_second.y);
            // Its shell exits: the pane closes as an exited one does
            // (`requestClose`), its window goes, and `windowDestroyed` takes
            // the tab with it.
            fixture.core_app.deleteSurface(dragged);
            dragged.close(false);
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
            try std.testing.expect(app.held_release_pending);
            // Its release, over another tab's X, closes nothing.
            try testReleaseOnCloseX(host, 0);
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

test "win32 a toast leaves a window kept only for its undo history's disposal out of the windows it counts (CodeRabbit review 5822644219)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(1, false);
            fixture.core_app.deleteSurface(source.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(source, 0));
            App.test_tab_move_shell_step = &TestHistoryDisposalFailure.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(source.destroy_after_structural_dispose);
            // The target is the one window open: no "window 2" for it.
            try std.testing.expectEqual(
                notifications.Window{ .ordinary = .{ .number = 1, .open = 1 } },
                app.notificationWindow(target),
            );
            // The hidden one is no window a toast names.
            try std.testing.expectEqual(
                notifications.Window{ .ordinary = .{ .number = null, .open = 1 } },
                app.notificationWindow(source),
            );
        }
    }.body);
}

test "win32 a redo from before a tab move whose history clear failed is disposed, never replayed (CodeRabbit review 5822644219)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(3, false);
            // The first tab dragged into a split of the third, then undone:
            // a redo of that transfer waits.
            const unrelated = host.tabs.items[1].focusedSurface().?;
            host.tab_drop_operation = .split_right;
            host.tab_drop_target_surface = host.tabs.items[2].focusedSurface().?;
            try std.testing.expect(host.commitTabDropSplit(0));
            try std.testing.expect((try host.applyLatestStructuralUndo()) != null);
            try std.testing.expectEqual(@as(usize, 3), host.tabs.items.len);
            try std.testing.expect(host.peekStructuralRedo() != null);
            // A tab the transfer does not name moves to a new window, and
            // disposing the history after the commit runs out of memory.
            const at = for (host.tabs.items, 0..) |*tab, i| {
                if (tab.findHandle(unrelated) != null) break i;
            } else return error.TestNoUnrelatedTab;
            App.test_tab_move_shell_step = &TestHistoryDisposalFailure.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(host, at, .{ .new_window = null }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(host.peekStructuralRedo() != null);
            // The redo is from before the move: disposed, not replayed.
            try std.testing.expect((try host.applyLatestStructuralRedo()) == null);
            try std.testing.expectEqual(@as(usize, 2), host.tabs.items.len);
            try std.testing.expect(host.peekStructuralRedo() == null);
            try app.validateShellNativeMapping();
        }
    }.body);
}

const TestCloseEarlierTab = struct {
    var host: ?*Host = null;
    var core: ?*CoreApp = null;

    /// While the history a transfer kept is cleared for the move's second
    /// prepare, window code closes the source's first tab, before the
    /// moving one.
    fn hook(_: *App, step: App.TabMoveShellStep) void {
        if (step != .retry_prepare) return;
        const source = host orelse return;
        host = null;
        core.?.deleteSurface(source.tabs.items[0].focusedSurface().?);
        _ = source.closeTabInPlace(0);
    }
};

test "win32 a tab move whose history clear closes an earlier tab moves the tab it was asked to (Greptile r4510568134)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(4, false);
            // The first tab dragged into a split of the third: a transfer in
            // undo history names the split tab, which then moves, so the
            // model asks for that history to go first.
            const split_pane = source.tabs.items[2].focusedSurface().?;
            // A drop splits the tab in front.
            try std.testing.expect(source.activateTabIndex(2));
            source.tab_drop_operation = .split_right;
            source.tab_drop_target_surface = split_pane;
            try std.testing.expect(source.commitTabDropSplit(0));
            const at = for (source.tabs.items, 0..) |*tab, i| {
                if (tab.findHandle(split_pane) != null) break i;
            } else return error.TestNoSplitTab;
            try std.testing.expectEqual(@as(usize, 1), at);
            TestCloseEarlierTab.host = source;
            TestCloseEarlierTab.core = &fixture.core_app;
            App.test_tab_move_shell_step = &TestCloseEarlierTab.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, at, .{ .new_window = null }));
            App.test_tab_move_shell_step = null;
            // The split tab is the one in the new window, and the source
            // keeps the other.
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try std.testing.expect(source.tabs.items[0].findHandle(split_pane) == null);
            const torn = app.registry.hosts.items[app.registry.hosts.items.len - 1];
            try std.testing.expect(torn != source);
            try std.testing.expectEqual(@as(usize, 1), torn.tabs.items.len);
            try std.testing.expect(torn.tabs.items[0].findHandle(split_pane) != null);
            try app.validateShellNativeMapping();
        }
    }.body);
}

const TestEmptyTarget = struct {
    var target: ?*Host = null;
    var core: ?*CoreApp = null;

    /// While undo history is disposed, window code closes every tab of the
    /// window the tab joined, the moved one included.
    fn hook(_: *App, step: App.TabMoveShellStep) void {
        if (step != .history) return;
        const host = target orelse return;
        target = null;
        while (host.tabs.items.len > 0) {
            core.?.deleteSurface(host.tabs.items[0].focusedSurface().?);
            if (!host.closeTabInPlace(0)) return;
        }
    }
};

test "win32 a tab move whose destination empties while history is disposed writes nothing to it once it is gone (Greptile r4510568141)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(1, false);
            const target_id = target.id;
            TestEmptyTarget.target = target;
            TestEmptyTarget.core = &fixture.core_app;
            App.test_tab_move_shell_step = &TestEmptyTarget.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            // The emptied destination went with its history; the source
            // keeps its other tab.
            try std.testing.expect(app.registry.findHostById(target_id) == null);
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

const TestExitTargetPanes = struct {
    var target: ?*Host = null;
    var core: ?*CoreApp = null;

    /// While undo history is disposed, every pane of the window the tab
    /// joined closes as an exited shell's does (`Surface.close`), and
    /// `windowDestroyed` frees that window.
    fn hook(_: *App, step: App.TabMoveShellStep) void {
        if (step != .history) return;
        const host = target orelse return;
        target = null;
        // The last pane's close frees the window: nothing reads it after.
        const app = host.app;
        const id = host.id;
        while (app.registry.findHostById(id)) |live| {
            if (live.tabs.items.len == 0) return;
            const before = live.tabs.items.len;
            const pane = live.tabs.items[0].focusedSurface().?;
            core.?.deleteSurface(pane);
            pane.close(false);
            const after = app.registry.findHostById(id) orelse return;
            if (after.tabs.items.len >= before) return;
        }
    }
};

test "win32 a tab move whose destination's panes all exit while history is disposed clears no history through the freed window (council round 7 M1b)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(1, false);
            const target_id = target.id;
            TestExitTargetPanes.target = target;
            TestExitTargetPanes.core = &fixture.core_app;
            App.test_tab_move_shell_step = &TestExitTargetPanes.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(app.registry.findHostById(target_id) == null);
            try std.testing.expectEqual(@as(usize, 1), source.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

const TestUndoInTargetMidRetire = struct {
    var target: ?*Host = null;
    var replayed: ?[]const u8 = null;
    var ran = false;

    /// Between the two windows' history clears, window code runs an undo in
    /// the window the tab joined: what a hook during the source's disposal
    /// could do.
    fn hook(_: *App, step: App.TabMoveShellStep) void {
        if (step != .source_history_retired) return;
        const host = target orelse return;
        target = null;
        ran = true;
        replayed = host.applyLatestStructuralUndo() catch null;
    }
};

test "win32 an undo in the destination while the source's history is retired replays nothing from before the move (CodeRabbit review 5823245522)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const target = try setup.window(2, false);
            // A closed tab kept for undo in the destination, from before the
            // move.
            fixture.core_app.deleteSurface(target.tabs.items[0].focusedSurface().?);
            try std.testing.expect(try app.closeTabUndoable(target, 0));
            try std.testing.expectEqual(@as(usize, 1), target.tabs.items.len);
            TestUndoInTargetMidRetire.target = target;
            TestUndoInTargetMidRetire.replayed = null;
            TestUndoInTargetMidRetire.ran = false;
            App.test_tab_move_shell_step = &TestUndoInTargetMidRetire.hook;
            defer App.test_tab_move_shell_step = null;
            try std.testing.expect(try app.moveTabToWindow(source, 0, .{ .host = .{ .host = target, .index = 1 } }));
            App.test_tab_move_shell_step = null;
            try std.testing.expect(TestUndoInTargetMidRetire.ran);
            // The closed tab did not come back at its index from before.
            try std.testing.expect(TestUndoInTargetMidRetire.replayed == null);
            try std.testing.expectEqual(@as(usize, 2), target.tabs.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

const TestCloseSourceWhileWindowIsMade = struct {
    var source: ?*Host = null;
    var core: ?*CoreApp = null;
    var stage: ?*const fn (*Host) anyerror!void = null;

    /// Making the torn-off tab's window runs window procedures; there, every
    /// pane of the window the tab is leaving exits, and that window goes.
    fn hook(created: *Host) anyerror!void {
        if (stage) |original| try original(created);
        const host = source orelse return;
        source = null;
        const id = host.id;
        while (created.app.registry.findHostById(id)) |live| {
            if (live.tabs.items.len == 0) return;
            const pane = live.tabs.items[0].focusedSurface().?;
            core.?.deleteSurface(pane);
            pane.close(false);
        }
    }
};

test "win32 a tab move whose source goes while its window is made does nothing, through no freed window (council round 7 pointer audit)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const source = try setup.window(2, false);
            const source_id = source.id;
            TestCloseSourceWhileWindowIsMade.source = source;
            TestCloseSourceWhileWindowIsMade.core = &fixture.core_app;
            TestCloseSourceWhileWindowIsMade.stage = App.test_tear_off_window_created;
            const original = App.test_tear_off_window_created;
            App.test_tear_off_window_created = &TestCloseSourceWhileWindowIsMade.hook;
            defer App.test_tear_off_window_created = original;
            try std.testing.expect(!(try app.moveTabToWindow(source, 0, .{ .new_window = null })));
            App.test_tear_off_window_created = original;
            try std.testing.expect(app.registry.findHostById(source_id) == null);
            // The window made for the move is gone too.
            try std.testing.expectEqual(@as(usize, 0), app.registry.hosts.items.len);
            try app.validateShellNativeMapping();
        }
    }.body);
}

/// A client point of `host` over its caption Close button, found by hit
/// testing along the caption row from the right.
fn testCaptionClosePoint(host: *Host) !POINT {
    const hwnd = host.hwnd orelse return error.TestNoWindow;
    var client: RECT = undefined;
    _ = sys.GetClientRect(hwnd, &client);
    var x: i32 = client.right - 1;
    while (x > client.right - 400) : (x -= 4) {
        var at: POINT = .{ .x = x, .y = 8 };
        _ = sys.ClientToScreen(hwnd, &at);
        const lx: u32 = @as(u16, @bitCast(@as(i16, @truncate(at.x))));
        const ly: u32 = @as(u16, @bitCast(@as(i16, @truncate(at.y))));
        const ht = sys.SendMessageW(hwnd, c.WM_NCHITTEST, 0, @bitCast(@as(usize, (ly << 16) | lx)));
        if (ht == c.HTCLOSE) return .{ .x = x, .y = 8 };
    }
    return error.TestNoCloseButton;
}

fn testClientMouse(hwnd: HWND, msg: UINT, at: POINT) void {
    const lx: u32 = @as(u16, @bitCast(@as(i16, @truncate(at.x))));
    const ly: u32 = @as(u16, @bitCast(@as(i16, @truncate(at.y))));
    _ = sys.SendMessageW(hwnd, msg, 0, @bitCast(@as(usize, (ly << 16) | lx)));
}

test "win32 a caption Close press closes the window on its release over Close, after the pointer left and came back (council round 7 L1, CodeRabbit review 5823245522)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try runOnHiddenDesktop(struct {
        fn body() !void {
            var fixture: win32.WindowStartTestApp = .{};
            try fixture.init();
            defer fixture.deinit();
            const app = &fixture.app;
            app.shell_runtime_initialized = true;
            app.use_integrated_titlebar = true;
            const setup: TabMoveFixture = .{ .fixture = &fixture };
            const host = try setup.window(2, false);
            try std.testing.expect(host.usingIntegratedTitlebar());
            const hwnd = host.hwnd.?;
            const close_at = try testCaptionClosePoint(host);
            // A press on Close and its release elsewhere on the caption, or a
            // press whose capture another window took: the window stays.
            _ = sys.SendMessageW(hwnd, c.WM_NCLBUTTONDOWN, @bitCast(@as(isize, c.HTCLOSE)), 0);
            testClientMouse(hwnd, c.WM_LBUTTONUP, .{ .x = close_at.x - 300, .y = 8 });
            try std.testing.expect(sys.IsWindow(hwnd) != 0);
            _ = sys.SendMessageW(hwnd, c.WM_NCLBUTTONDOWN, @bitCast(@as(isize, c.HTCLOSE)), 0);
            _ = sys.SendMessageW(hwnd, c.WM_CAPTURECHANGED, 0, 0);
            _ = sys.SendMessageW(hwnd, c.WM_NCLBUTTONUP, @bitCast(@as(isize, c.HTCLOSE)), 0);
            try std.testing.expect(sys.IsWindow(hwnd) != 0);
            // A press on Close, the pointer off the frame and back, and the
            // release over Close: the window closes, as a stock caption
            // button's does. Its panes leave the core first, as a closing
            // window's are torn down.
            for (host.tabs.items) |*tab| fixture.core_app.deleteSurface(tab.focusedSurface().?);
            _ = sys.SendMessageW(hwnd, c.WM_NCLBUTTONDOWN, @bitCast(@as(isize, c.HTCLOSE)), 0);
            _ = sys.SendMessageW(hwnd, c.WM_NCMOUSELEAVE, 0, 0);
            testClientMouse(hwnd, c.WM_LBUTTONUP, close_at);
            try std.testing.expect(sys.IsWindow(hwnd) == 0);
        }
    }.body);
}
